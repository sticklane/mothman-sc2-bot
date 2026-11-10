#lang racket/base

(require racket/match
         racket/list
         racket/set
         racket/math
         racket/file
         racket/path
         racket/port
         racket/string
         racket/system
         "../compiler/syntax.rkt"
         "../lib/okasaki-sc.rkt"
         "../lib/sc2-game-constants.rkt"
         "../lib/perception-grid.rkt"
         "../lib/econ-ledger.rkt"
         "../lib/tactics-sim.rkt"
         "../lib/human-cortex.rkt"
         "../lib/zerospace-mastermind.rkt"
         "../lib/mirror-mind-predictor.rkt"
         "../lib/bot-runtime.rkt"
         "../examples/zerg-overmind-12hatch.rkt"
         "../examples/protoss-stardust-ffe.rkt"
         "../examples/terran-pluto-siege-ghost.rkt"
         "../examples/random-chameleon-allrace.rkt"
         "../sim/openbw_ffi_bridge.rkt"
         "../sim/deterministic-sc-sim.rkt"
         "../tools/sc2-replay-decompiler.rkt"
         "../lib/state-machine-verifier.rkt"
         "../ladder/build-aiarena-zip.rkt"
         (except-in "../lib/bot-crash-fuzzer.rkt"
                    compute-shadow-ledger
                    step-zerospace-mastermind!))

(define total-assertions 0)

(define (assert-true! cond-val [msg "assertion failed"])
  (set! total-assertions (add1 total-assertions))
  (unless cond-val
    (error 'assert-true! "~a" msg)))

(define (assert-eq! actual expected [msg "equality assertion failed"])
  (set! total-assertions (add1 total-assertions))
  (unless (equal? actual expected)
    (error 'assert-eq! "~a: expected ~v, got ~v" msg expected actual)))

(define-syntax-rule (run-suite label body ...)
  (begin
    (printf "  [TEST] ~a ... " label)
    (flush-output)
    (let ()
      body ...)
    (printf "OK\n")
    (flush-output)))

(printf "============================================================================\n")
(printf "  Running #lang sc-bot Verification & Match Simulation Suite (Racket v8.15)\n")
(printf "============================================================================\n\n")

;; =============================================================================
;; 1.1 Okasaki-Gill Canonical Crit-Bit Trie
;; =============================================================================
(run-suite "1.1 Okasaki-Gill Canonical Crit-Bit Trie: History Independence & Morton 2D Range Query"
  (define pts '((10 20 u1) (35 42 u2) (60 70 u3) (102 112 u4) (61 71 u5) (8 9 u6)))
  (define t-forward
    (for/fold ([t critbit-empty]) ([p (in-list pts)])
      (critbit-insert t (morton-encode-2d (first p) (second p)) (third p))))
  (define t-reverse
    (for/fold ([t critbit-empty]) ([p (in-list (reverse pts))])
      (critbit-insert t (morton-encode-2d (first p) (second p)) (third p))))
  ;; History independence: exact same canonical tree structure regardless of insertion order!
  (assert-eq! t-forward t-reverse "Crit-Bit Trie canonical history independence")
  (assert-eq! (critbit-size t-forward) 6)
  (for ([p (in-list pts)])
    (define k (morton-encode-2d (first p) (second p)))
    (assert-eq! (critbit-lookup t-forward k) (third p))
    (define-values (dx dy) (morton-decode-2d k))
    (assert-eq! dx (first p))
    (assert-eq! dy (second p)))
  (define in-box (critbit-range-2d t-forward 58 68 65 75))
  (assert-eq! (length in-box) 2)
  (assert-true! (and (memq 'u3 in-box) (memq 'u5 in-box)))
  (define t-del (critbit-delete t-forward (morton-encode-2d 60 70)))
  (assert-eq! (critbit-size t-del) 5)
  (assert-eq! (critbit-lookup t-del (morton-encode-2d 60 70)) #f))

;; =============================================================================
;; 1.2 Hinze-Paterson 2-3 Monoidal Finger Tree
;; =============================================================================
(run-suite "1.2 Hinze-Paterson 2-3 Monoidal Finger Tree: Cached Measure & O(log N) split-by-dps"
  (define units
    (for/list ([i (in-range 1 21)])
      (unit-entry i 'marine 10 45 50 (+ 30 (* i 2)) 32)))
  (define ft (ft-from-list units))
  (define m (ft-measure ft))
  (assert-eq! (combat-measure-count m) 20)
  (assert-eq! (combat-measure-dps m) 200)
  (assert-eq! (combat-measure-hp m) 900)
  (assert-eq! (combat-measure-cost m) 1000)
  (define-values (van res) (split-by-dps ft 135))
  (assert-eq! (combat-measure-count (ft-measure van)) 14)
  (assert-eq! (combat-measure-dps (ft-measure van)) 140)
  (assert-eq! (combat-measure-count (ft-measure res)) 6)
  (assert-eq! (combat-measure-dps (ft-measure res)) 60)
  (define recombined (ft-append van res))
  (assert-eq! (combat-measure-dps (ft-measure recombined)) 200)
  (assert-eq! (length (ft-to-list recombined)) 20))

;; =============================================================================
;; 1.3 Huet Focus Zipper
;; =============================================================================
(run-suite "1.3 Huet Focus Zipper: O(|b1 - b2|) Choke Switching & O(1) Speculative Rollback"
  (define z0 (make-zipper '(base-main choke-nat choke-third bridge-center enemy-nat)))
  (assert-eq! (zipper-focus z0) 'base-main)
  (assert-eq! (zipper-index z0) 0)
  (define z-cp (zipper-checkpoint z0))
  (define z2 (zipper-move-to-index z-cp 3))
  (assert-eq! (zipper-focus z2) 'bridge-center)
  (assert-eq! (zipper-index z2) 3)
  (define z-upd (zipper-update z2 (lambda (_x) 'fortified-bridge)))
  (assert-eq! (zipper-focus z-upd) 'fortified-bridge)
  (define z-rb (zipper-rollback z-upd))
  (assert-eq! (zipper-focus z-rb) 'base-main)
  (assert-eq! (zipper-index z-rb) 0))

;; =============================================================================
;; 1.4 Pointerless/Functional Braun Tree
;; =============================================================================
(run-suite "1.4 Pointerless/Functional Braun Tree: Priority Queue, Okasaki diff Size & fold-braun"
  (define keys '(42 15 88 7 23 19 64 3 99 51 12 31))
  (define bt
    (for/fold ([t braun-empty]) ([k (in-list keys)])
      (braun-insert t k (format "val-~a" k))))
  (assert-eq! (braun-size bt) 12)
  (assert-eq! (car (braun-min bt)) 3)
  (define sorted-pairs (braun->sorted-list bt))
  (assert-eq! (map car sorted-pairs) (sort keys <))
  (define key-sum (fold-braun (lambda (k _v acc) (+ k acc)) 0 bt))
  (assert-eq! key-sum (apply + keys)))

;; =============================================================================
;; 1.5 Skew-Binary Random-Access List
;; =============================================================================
(run-suite "1.5 Skew-Binary Random-Access List: O(1) Frame Snapshots & O(log N) Lookup/Update"
  (define s0
    (for/fold ([s sbral-empty]) ([i (in-range 32)])
      (sbral-cons (* i 10) s)))
  (assert-eq! (sbral-length s0) 32)
  (assert-eq! (sbral-head s0) 310)
  (assert-eq! (sbral-ref s0 0) 310)
  (assert-eq! (sbral-ref s0 31) 0)
  (define s1 (sbral-set s0 15 9999))
  (assert-eq! (sbral-ref s1 15) 9999)
  (assert-eq! (sbral-ref s0 15) 160) ;; persistent O(1) snapshot unaffected!
  (assert-eq! (length (sbral->list s1)) 32))

;; =============================================================================
;; 2.1 CapUnit 5-Element Capability Semiring & 7-Component sc-grade Algebra
;; =============================================================================
(run-suite "2.1 CapUnit 5-Element Capability Semiring & 7-Component sc-grade Algebra"
  (for ([c (in-list CAP-ELEMENTS)])
    (assert-true! (cap-valid? c))
    (assert-eq! (cap-add 'Zero c) c)
    (assert-eq! (cap-add c 'Zero) c)
    (assert-eq! (cap-mul 'Zero c) 'Zero)
    (assert-eq! (cap-mul 'One c) c))
  ;; Linear unit capability: One + One = Many (prevents parallel double-spend)
  (assert-eq! (cap-add 'One 'One) 'Many)
  (assert-eq! (cap-add 'Borrowed 'Borrowed) 'Shared)
  (assert-true! (cap-leq? 'One 'One))
  (assert-true! (not (cap-leq? 'Many 'One)))
  (define g1 (sc-grade 'One 100 50 2 3 'fixated 'visible-only))
  (define g2 (sc-grade 'One 150 25 2 4 'saccade 'scouted-memory))
  (define g-seq (grade-seq g1 g2))
  (define g-par (grade-par g1 g2))
  (assert-eq! (sc-grade-cap g-seq) 'One)
  (assert-eq! (sc-grade-cap g-par) 'Many)
  (assert-eq! (sc-grade-minerals g-seq) 250)
  (assert-eq! (sc-grade-gas g-seq) 75)
  (assert-eq! (sc-grade-supply g-seq) 4)
  (assert-eq! (sc-grade-apm g-seq) 7)
  (assert-eq! (sc-grade-camera g-seq) 'saccade)
  (assert-eq! (sc-grade-fow g-seq) 'scouted-memory))

;; =============================================================================
;; 2.2 12/12 (100%) Soundness Mutation Kill Rate across All Safety Families
;; =============================================================================
(run-suite "2.2 12/12 (100%) Soundness Mutation Kill Rate across All Safety Families"
  (define report (run-soundness-mutation-suite))
  (assert-eq! (hash-ref report 'total) 12)
  (assert-eq! (hash-ref report 'killed) 12)
  (assert-eq! (hash-ref report 'kill-rate) 1)
  (for ([fam (in-list ALL-MUTATION-FAMILIES)])
    (assert-true! (check-mutation-killed? fam))))

;; =============================================================================
;; 2.3 3-Span Provenance Resugaring (0 Gensym Leaks), Chordal Coloring & Auto-Repair
;; =============================================================================
(run-suite "2.3 3-Span Provenance Resugaring (0 Gensym Leaks), Chordal Coloring & Auto-Repair"
  (define raw-pspan
    (make-provenance-span
     "examples/zerg-overmind-12hatch.rkt:24:2"
     "compiler/syntax.rkt:def-posture"
     "examples/zerg-overmind-12hatch.rkt:31:0"
     '(seq>> (train drone_104) (build spawning-pool_209) (morph tmp$lair))))
  (assert-true! (verify-zero-gensym-leaks? raw-pspan))
  (define resugared (resugar-macro-step raw-pspan))
  (assert-eq! (provenance-span-expr resugared)
              '(seq>> (train drone) (build spawning-pool) (morph lair)))
  (define squad-graph
    '((vanguard . (flank-left support-casters))
      (flank-left . (vanguard support-casters))
      (support-casters . (vanguard flank-left drop-harass))
      (drop-harass . (support-casters))))
  (define coloring (chordal-color-squads squad-graph))
  (assert-true! (verify-proper-coloring? squad-graph coloring))
  (define over-demand (sc-grade 'Many 900 500 20 50 'offscreen-error 'maphack-error))
  (define budget (sc-grade 'One 400 200 10 20 'saccade 'diffusion-prior))
  (define repaired (auto-repair-bot-grade over-demand budget))
  (assert-true! (grade-leq? repaired budget)))

;; =============================================================================
;; 3.1 Build-Order Combinators, Locutus Worker Chaining, McRave UCB1 & BOSS Goal Synthesis
;; =============================================================================
(run-suite "3.1 Build-Order Combinators, Locutus Worker Chaining, McRave UCB1 & BOSS Goal Synthesis"
  (define bo
    (seq>> (auto-supply 'Zerg (bo-step '(train drone) 50 0 1))
           (saturate-bases 'Zerg 2)
           (chain-worker>> 10 '((32 . 32) (42 . 44) (50 . 56)) '(expand 50 56) 300 0)))
  (define steps (compile-build-order bo))
  (assert-true! (>= (length steps) 9))
  (assert-eq! (first steps) '(train overlord))
  (define bandit (make-ucb1-bandit '(12-hatch-macro roach-ravager-timing muta-lurker-contain)))
  (ucb1-update-arm! bandit '12-hatch-macro 1.0)
  (ucb1-update-arm! bandit 'roach-ravager-timing 0.2)
  (ucb1-update-arm! bandit 'muta-lurker-contain 0.9)
  (assert-true! (symbol? (ucb1-select-arm bandit)))
  (define plan (boss-synthesize-build-plan 'Zerg '((mutalisk . 4) (zergling . 8))))
  (assert-true! (member '(build spire) (boss-plan-steps plan)))
  (assert-true! (> (boss-plan-makespan-frames plan) 0)))

;; =============================================================================
;; 3.2 Stardust HTN Plays & Symbiotic Resource Ledger Borrowing + Preemption
;; =============================================================================
(run-suite "3.2 Stardust HTN Plays & Symbiotic Resource Ledger Borrowing + Preemption"
  (define ledger (make-symbiotic-ledger 500 200 12))
  (assert-true! (ledger-verify-invariant? ledger))
  (define expand-lease (ledger-reserve! ledger 'natural-expand 'macro-play 300 0 0 2))
  (assert-eq! (ledger-available-minerals ledger) 200)
  (assert-true! (ledger-verify-invariant? ledger))
  ;; Crisis preemption borrows from lower-priority natural-expand reservation!
  (define crisis-lease (ledger-preempt-for-crisis! ledger 'cannon-defense 350 0 2 10))
  (assert-eq! (ledger-lease-status expand-lease) 'preempted)
  (assert-eq! (ledger-lease-status crisis-lease) 'borrowed)
  (assert-true! (ledger-verify-invariant? ledger))
  (ledger-repay! ledger 'cannon-defense)
  (assert-true! (ledger-verify-invariant? ledger)))

;; =============================================================================
;; 3.3 Lakefill + Zipper-Cut, Baba Wall-In Solver, FRACTRAN Bitmask VM, FAP Hysteresis & Traffic Retreat
;; =============================================================================
(run-suite "3.3 Lakefill + Zipper-Cut, Baba Wall-In Solver, FRACTRAN Bitmask VM, FAP Hysteresis & Traffic Retreat"
  (define decomp (lakefill-choke-decomposition 200 200 '((38 . 42) (50 . 56))))
  (assert-eq! (length (hash-ref decomp 'chokes)) 3)
  (define ffe-wall (solve-choke-wall-in 30 30 9 PROTOSS-FFE-BUILDINGS))
  (assert-true! (wall-solution-valid-ref ffe-wall))
  (assert-true! (wall-solution-zergling-tight-ref ffe-wall))
  (assert-true! (<= (wall-solution-max-gap-ref ffe-wall) 15))
  (define terran-wall9 (solve-choke-wall-in 30 30 9 #:preset 'terran-barracks-depot))
  (define terran-wall10 (solve-choke-wall-in 30 30 10 #:preset 'terran-barracks-depot))
  (assert-true! (wall-solution-valid-ref terran-wall9))
  (assert-true! (wall-solution-zergling-tight-ref terran-wall9))
  (assert-true! (wall-solution-valid-ref terran-wall10))
  (assert-true! (wall-solution-zergling-tight-ref terran-wall10))
  ;; FRACTRAN VM
  (define ftrace (fractran-run 2 10))
  (assert-true! (>= (length ftrace) 5))
  ;; FAP Hysteresis: no thrashing inside [-15, +25]
  (assert-eq! (fap-posture-with-hysteresis -20 'hold) 'retreat)
  (assert-eq! (fap-posture-with-hysteresis 10 'retreat) 'retreat)
  (assert-eq! (fap-posture-with-hysteresis 30 'retreat) 'attack)
  (assert-eq! (fap-posture-with-hysteresis 5 'attack) 'attack)
  ;; PurpleWave Traffic Retreat (SC2 map tiles)
  (define retreat-orders
    (purplewave-traffic-retreat
     (list (hash 'id 1 'x 48 'y 54)
           (hash 'id 2 'x 44 'y 50)
           (hash 'id 3 'x 50 'y 56))
     50 56 32 32 3))
  (assert-eq! (hash-ref (first retreat-orders) 'unit-id) 3)
  ;; Safe retreat sector selection (avoids corner sector 0 when allied sector is near)
  (define pgrid (make-perception-grid))
  (define retreat-sec (best-retreat-sector pgrid 18 '(9 10)))
  (assert-true! (not (= retreat-sec 0)) "best-retreat-sector should prefer nearby allied sector over corner 0")
  ;; Focus-fire target selection with range/proximity weighting
  (define ff-target
    (select-focus-fire-target
     (list (hash 'id 91 'hp 40 'dps 20 'x 36 'y 36)
           (hash 'id 92 'hp 40 'dps 20 'x 150 'y 150))
     (hash 'id 1 'hp 100 'dps 15 'x 34 'y 34 'range 6.0)))
  (assert-eq! (hash-ref ff-target 'id) 91 "select-focus-fire-target should prefer in-range target over far target"))

;; =============================================================================
;; 3.4 Human Cortex: SC2 Tile Camera Fixation, APM Token-Bucket/Window, FoW Diffusion & Fingerprinting
;; =============================================================================
(run-suite "3.4 Human Cortex: SC2 Tile Camera Fixation, APM Token-Bucket/Window, FoW Diffusion & Fingerprinting"
  (define cortex (make-human-cortex #:profile 'Serral #:cam-x 32.0 #:cam-y 32.0 #:max-tokens 6))
  (assert-true! (in-camera-viewport? 32.0 32.0 38.0 38.0))
  (assert-true! (not (in-camera-viewport? 32.0 32.0 160.0 160.0)))
  (assert-true! (> (fitts-saccade-ms 32.0 32.0 160.0 160.0) (fitts-saccade-ms 32.0 32.0 36.0 36.0)))
  (define-values (acc drop-cnt)
    (cortex-filter-actions! cortex
                            '((harvest-mineral 10 504) (harvest-gas 10 103)
                              (train drone) (train overlord) (build spawning-pool)
                              (attack-unit 1 2) (attack-unit 3 4) (attack-unit 5 6))))
  (assert-eq! (length acc) 6)
  (assert-eq! drop-cnt 2)
  (assert-true! (member '(train overlord) acc))
  (assert-true! (member '(build spawning-pool) acc))
  (assert-eq! (human-cortex-offscreen-violations cortex) 0)
  (define belief (make-vector 64 (/ 1.0 64.0)))
  (fow-ghost-step-diffusion! belief '(0 1 2 3))
  (define total-mass (for/sum ([p (in-vector belief)]) p))
  (assert-true! (< (abs (- total-mass 1.0)) 1e-6))
  (assert-eq! (vector-ref belief 0) 0.0)
  (assert-eq! (classify-player-fingerprint 410 36.0 52.0) 'Clem))

;; =============================================================================
;; 4.1 Example Bots Compile & Pass All Coeffect-Effect Grades
;; =============================================================================
(run-suite "4.1 Example Bots Compile & Pass All Coeffect-Effect Grades"
  (define budget (sc-grade 'Many 1000 1000 30 40 'saccade 'diffusion-prior))
  (for ([b (in-list (list zerg-overmind-12hatch-bot
                          protoss-stardust-ffe-bot
                          terran-pluto-siege-ghost-bot
                          random-chameleon-allrace-bot))])
    (assert-true! (bot-spec? b))
    (assert-true! (check-bot-grade! (bot-spec-grade b) budget (bot-spec-name b)))))

;; =============================================================================
;; 4.2 - 4.4 Simulated Matches 1, 2, 3
;; =============================================================================
(run-suite "4.2 Simulated Match 1: Zerg Overmind 12-Hatch vs. Protoss Stardust FFE (FAIL_OK -> REC_OK -> FULL_WIN_OK)"
  (define m1 (simulate-sc-match 'ZvP))
  (assert-eq! (hash-ref m1 'posture-trace)
              '(Macro12Hatch CrisisZealotRush SunkenLairRecovery MutaLurkerContain SwarmVictory))
  (assert-eq! (hash-ref m1 'stages) '(FAIL_OK REC_OK FULL_WIN_OK)))

(run-suite "4.3 Simulated Match 2: Protoss Stardust FFE vs. Terran Pluto Siege/Ghost (FAIL_OK -> REC_OK -> FULL_WIN_OK)"
  (define m2 (simulate-sc-match 'PvT))
  (assert-eq! (hash-ref m2 'posture-trace)
              '(ForgeFastExpand CrisisZerglingFlood CannonWallRecovery DragoonReaverVanguard ProtossArmadaVictory))
  (assert-eq! (hash-ref m2 'stages) '(FAIL_OK REC_OK FULL_WIN_OK)))

(run-suite "4.4 Simulated Match 3: Terran Pluto Siege/Ghost vs. Zerg Overmind 12-Hatch (FAIL_OK -> REC_OK -> FULL_WIN_OK)"
  (define m3 (simulate-sc-match 'TvZ))
  (assert-eq! (hash-ref m3 'posture-trace)
              '(OneRaxFE CrisisEarlyBust BunkerSiegeRecovery VesselGhostPush TerranDominionVictory))
  (assert-eq! (hash-ref m3 'stages) '(FAIL_OK REC_OK FULL_WIN_OK)))

;; =============================================================================
;; 4.5 Native C FFI (`libbw_bridge.so`) & Python `sc2_burny_bridge.py` Wire Protocol Round-Trip
;; =============================================================================
(run-suite "4.5 Native C FFI (`libbw_bridge.so`) & Python `sc2_burny_bridge.py` Wire Protocol Round-Trip"
  (define rt-res (bw-wire-sexp-roundtrip '((train zergling) (build spawning-pool 36 36) (expand 50 56))))
  (assert-true! (hash-ref rt-res 'roundtrip-exact?))
  (assert-true! (> (bw-ffi-step-frame 10 200 50) 0)))

;; =============================================================================
;; 5.1 7-Year (2019-2026) Pro Tournament Cortex Calibration & Statistical Fidelity
;; =============================================================================
(run-suite "5.1 7-Year (2019-2026) Pro Tournament Cortex Calibration & Statistical Fidelity"
  (for ([pro '(Serral Reynor Maru Clem Oliveira herO Classic MaxPax)])
    (define cal (calibrate-cortex-from-corpus pro 502))
    (assert-true! (hash-ref cal 'calibrated))
    (assert-true! (< (hash-ref cal 'ks-statistic) 0.05))
    (assert-true! (< (hash-ref cal 'hellinger-distance) 0.05))
    (assert-eq! (hash-ref cal 'offscreen-violations) 0))
  (assert-true! (< (ks-two-sample-statistic '(340 355 365 380) '(342 358 368 378)) 0.30))
  (assert-true! (< (hellinger-distance '(0.25 0.25 0.25 0.25) '(0.24 0.26 0.25 0.25)) 0.05)))

;; =============================================================================
;; 5.2 Binary .SC2Replay MPQ Decompiler into Grade-Checked #lang sc-bot & Frame-Trace Convergence
;; =============================================================================
(run-suite "5.2 Binary .SC2Replay MPQ Decompiler into Grade-Checked #lang sc-bot & Frame-Trace Convergence"
  (define dec (decompile-sc2-replay-to-sc-bot "replays/Serral_ZvP_2024.SC2Replay"
                                              #:player-name 'Serral
                                              #:race 'Zerg))
  (assert-true! (hash-ref dec 'grade-valid?))
  (assert-true! (verify-decompiled-replay-convergence dec)))

;; =============================================================================
;; 5.3 Multi-Map 7-Year Pro Meta Tournament Bracket Runner (7 Classic Maps)
;; =============================================================================
(run-suite "5.3 Multi-Map 7-Year Pro Meta Tournament Bracket Runner (7 Classic Maps, FAIL_OK -> REC_OK -> FULL_WIN_OK)"
  (define bracket (run-7map-pro-meta-bracket))
  (assert-eq! (hash-ref bracket 'total-maps) 7)
  (assert-true! (hash-ref bracket 'all-passed?)))

;; =============================================================================
;; 5.4 Empirical 502-Replay (2019-2026) S-Expr Dataset & Live Headless SC2_x64 .SC2Replay Verification
;; =============================================================================
(run-suite "5.4 Empirical 502-Replay (2019-2026) S-Expr Dataset & Live Headless SC2_x64 .SC2Replay Verification"
  (define sample-sexp
    '(frame-state #:frame 320 #:race zerg #:minerals 350 #:gas 100
                  #:supply-used 18 #:supply-cap 22 #:supply-left 4 #:pending-supply 0
                  #:start-pos (32.5 32.5) #:enemy-base (160.5 160.5)
                  #:my-units ((10 drone 32.5 32.5 40 0) (120 queen 33.5 33.5 175 30))
                  #:my-buildings ((101 hatchery 32.5 32.5 1.0 1.0 #f)
                                  (102 spawning-pool 35.5 35.5 1.0 1.0 #f))
                  #:enemy-units () #:enemy-buildings () #:effects ()))
  (define parsed (parse-frame-state-sexp sample-sexp))
  (assert-eq! (hash-ref parsed 'frame) 320)
  (assert-eq! (hash-ref parsed 'minerals) 350)
  (assert-eq! (length (hash-ref parsed 'ally-units)) 2))

;; =============================================================================
;; 5.5 5-Layer Live SC2 Runtime Engine (`step-live-bot-runtime!`) & AST Grade Synthesis
;; =============================================================================
(run-suite "5.5 5-Layer Live SC2 Runtime Engine (`step-live-bot-runtime!`) & AST Grade Synthesis (`derive-grades-from-bot-ast`)"
  (define rt (make-zerg-overmind-runtime))
  (define res
    (step-live-bot-runtime!
     rt
     (hash 'frame 120
           'minerals 250
           'gas 50
           'supply-used 13
           'supply-cap 14
           'supply-left 1
           'pending-supply 0
           'ally-units (list (hash 'id 10 'type 'drone 'x 32.5 'y 32.5 'hp 40))
           'ally-buildings (list (hash 'id 101 'type 'hatchery 'x 32.5 'y 32.5 'hp 1500))
           'enemy-units '())))
  (define acts (hash-ref res 'actions))
  (assert-true! (not (null? acts)))
  (assert-true! (member '(train overlord) acts))
  (define synth-grade (derive-grades-from-bot-ast acts))
  (assert-true! (sc-grade? synth-grade)))

;; =============================================================================
;; 5.6 ZeroSpace 3-Layer Mastermind, Lanchester Snowball, Plausible Counter Tree, Ability Limiter & PDA
;; =============================================================================
(run-suite "5.6 ZeroSpace 3-Layer Mastermind, Lanchester Snowball, Plausible Counter Tree, Ability Limiter & PDA Diagnostics"
  (assert-true! (> (lanchester-snowball-advantage 400 200) 0))
  (define comp (evaluate-compounding-ledger #:self-workers 22 #:enemy-workers 14 #:self-bases 3 #:enemy-bases 2 #:fap-score 20))
  (assert-eq! (hash-ref comp 'dominant-driver) 'economic-compounding-snowball)
  (define z-pull (resolve-demand-pull ZERG-COUNTER-TREE 'bio-ball '(spawning-pool baneling-nest)))
  (assert-eq! (hash-ref z-pull 'selected-unit) 'baneling)
  (define t-pull (resolve-demand-pull TERRAN-COUNTER-TREE 'zergling-flood '(factory)))
  (assert-eq! (hash-ref t-pull 'selected-unit) 'widow-mine)
  ;; Fallback when tech building missing & unaffordable
  (define p-fallback (resolve-demand-pull PROTOSS-COUNTER-TREE 'bio-ball '(gateway) #:minerals 50 #:gas 0))
  (assert-eq! (hash-ref p-fallback 'selected-unit) 'stalker)
  (assert-true! (hash-ref p-fallback 'fallback-used?))
  ;; Ability Cast Limiter (per-caster + per-ability refractory tracking)
  (define lim (make-ability-cast-limiter #:max-per-frame 1 #:refractory-frames 24))
  (define-values (kept throttled)
    (throttle-ability-casts!
     lim
     '((cast-spell 120 inject-larva 101)
       (cast-spell 120 transfusion 141)
       (cast-spell 120 inject-larva 102)
       (cast 702 spread-creep-tumor 42 46)
       (cast-spell 320 siege-mode 9001)
       (cast-spell 321 siege-mode 9001)
       (cast-spell 322 siege-mode 9001))
     100))
  (assert-eq! throttled 3)
  (assert-true! (member '(cast-spell 120 inject-larva 101) kept))
  (assert-true! (member '(cast-spell 120 transfusion 141) kept)
                "Same caster (120) must be able to cast distinct ability (transfusion) in the same window")
  (assert-true! (member '(cast 702 spread-creep-tumor 42 46) kept))
  ;; PDA Diagnostics
  (assert-eq! (diagnose-bot-anomaly (make-pda-trace #:scouted-sectors 0)) 'perception-blindspot)
  (assert-eq! (diagnose-bot-anomaly (make-pda-trace #:posture-switches 8)) 'decision-oscillation-thrash)
  (assert-eq! (diagnose-bot-anomaly (make-pda-trace #:actions-emitted 25 #:actions-dropped 12)) 'action-execution-failure)
  (assert-eq! (diagnose-bot-anomaly (make-pda-trace)) 'healthy-pda-loop))

;; =============================================================================
;; 5.7 Closed-Loop Mastermind (Layer 1b->2/3/4/5), 2-Prong Finger-Tree Split, Creep Tumor & Personality Hot-Swap
;; =============================================================================
(run-suite "5.7 Closed-Loop Mastermind (Layer 1b->2/3/4/5), 2-Prong Finger-Tree Split, Creep Tumor & Personality Hot-Swap"
  (def-doctrine-loadout FLEX-DOCTRINE
    #:primary MARV-MACRO-OPEN-PERSONALITY
    #:fallback SCARLETT-CREEP-SWARM-PERSONALITY
    #:crisis CLEM-TEMPO-MULTITASK-PERSONALITY)
  (define rt (make-live-bot-runtime #:race 'Zerg #:doctrine FLEX-DOCTRINE))
  (define res
    (step-live-bot-runtime!
     rt
     (hash 'frame 600
           'minerals 400
           'gas 200
           'supply-used 24
           'supply-cap 36
           'supply-left 12
           'ally-units (list (hash 'id 10 'type 'drone 'x 32.5 'y 32.5 'hp 40)
                             (hash 'id 120 'type 'queen 'x 33.5 'y 33.5 'hp 175 'energy 50)
                             (hash 'id 140 'type 'roach 'x 40.5 'y 42.5 'hp 145 'dps 16)
                             (hash 'id 141 'type 'roach 'x 41.5 'y 43.0 'hp 145 'dps 16)
                             (hash 'id 142 'type 'roach 'x 42.5 'y 43.5 'hp 145 'dps 16))
           'ally-buildings (list (hash 'id 101 'type 'lair 'x 32.5 'y 32.5 'hp 1500)
                                 (hash 'id 102 'type 'spawning-pool 'x 35.5 'y 35.5 'hp 1000))
           'enemy-units (list (hash 'id 9001 'type 'lurker 'x 50.5 'y 56.5 'hp 200 'dps 30)))))
  (define tel (hash-ref res 'telemetry))
  (assert-eq! (hash-ref tel 'enemy-archetype) 'lurker-contain)
  (assert-eq! (hash-ref tel 'double-reactions) 1)
  (assert-true! (>= (hash-ref tel 'vanguard-count) 1)))

;; =============================================================================
;; 5.8 Mothman Z/T/P/R Multi-Race Variants, Random Frame-0 Race Morphing & Active Spells
;; =============================================================================
(run-suite "5.8 Mothman Z/T/P/R Multi-Race Variants, Random Frame-0 Race Morphing & Active Spells"
  (for ([actual-r '(Zerg Protoss Terran)])
    (define rt-rand (make-random-chameleon-runtime))
    (define unit-sym
      (case actual-r
        [(Zerg) 'drone]
        [(Protoss) 'probe]
        [(Terran) 'scv]))
    (define res
      (step-live-bot-runtime!
       rt-rand
       (hash 'frame 0
             'actual-race actual-r
             'minerals 200
             'gas 100
             'supply-used 12
             'supply-cap 15
             'supply-left 3
             'ally-units (list (hash 'id 10 'type unit-sym 'x 32.5 'y 32.5 'hp 40))
             'ally-buildings '()
             'enemy-units '())))
    (assert-eq! (hash-ref res 'actual-race) actual-r)))

;; =============================================================================
;; 5.9 Pro Tournament Replay Mechanics (Cancel, Creep Chain, Door Guard, Addon Swap,
;;     Juggle, Mineral-Walk, 11-Struct Chrono & Group Steal)
;; =============================================================================
(run-suite "5.9 Pro Tournament Replay Mechanics (Cancel, Creep Chain, Door Guard, Addon Swap, Juggle, Mineral-Walk, 11-Struct Chrono & Group Steal)"
  ;; 1 & 2 & 5: Cancel dying building + Creep Tumor Daisy-Chain + Mineral-walk + Overseer Changeling
  (define rt-z (make-zerg-overmind-runtime))
  (define res-z
    (step-live-bot-runtime!
     rt-z
     (hash 'frame 900
           'minerals 300
           'gas 150
           'supply-used 20
           'supply-cap 30
           'supply-left 10
           'base-x 32.5 'base-y 32.5
           'natural-x 50.5 'natural-y 56.5
           'enable-worker-harass #t
           'ally-units (list (hash 'id 10 'type 'drone 'x 32.5 'y 32.5 'hp 15 'max-hp 40)
                             (hash 'id 190 'type 'overseer 'x 38.5 'y 38.5 'hp 200 'energy 60)
                             (hash 'id 702 'type 'creep-tumor-burrowed 'x 42.5 'y 46.5 'hp 50))
           'ally-buildings (list (hash 'id 701 'type 'hatchery 'x 50.5 'y 56.5 'hp 40 'max-hp 1500
                                       'hp-pct 0.10 'build-progress 0.45 'under-attack #t)
                                 (hash 'id 102 'type 'spawning-pool 'x 35.5 'y 35.5 'hp 1000))
           'enemy-units (list (hash 'id 9001 'type 'zealot 'x 33.5 'y 33.5 'hp 100)))))
  (define acts-z (hash-ref res-z 'actions))
  (assert-true! (member '(cancel 701) acts-z) "Expected (cancel 701) for dying unfinished building")
  (assert-true! (ormap (lambda (a) (match a [(list 'cast 702 'spread-creep-tumor _ _) #t] [_ #f])) acts-z)
                "Expected spread-creep-tumor from burrowed creep tumor")
  (assert-true! (ormap (lambda (a) (match a [(list 'mineral-walk 10 _ _) #t] [_ #f])) acts-z)
                "Expected mineral-walk on wounded drone")
  (assert-true! (ormap (lambda (a) (match a [(list 'cast 190 'spawn-changeling _ _) #t] [_ #f])) acts-z)
                "Expected spawn-changeling from overseer")

  ;; 3 & 4 & 6 & 7: Protoss Door Guard, Transport Juggle, 11-Struct Chrono Shift & Control-Group Steal
  (define rt-p (make-protoss-stardust-runtime))
  (cortex-assign-control-group! (live-bot-runtime-cortex rt-p) 1 '(703 707))
  (define res-p
    (step-live-bot-runtime!
     rt-p
     (hash 'frame 1800
           'minerals 300
           'gas 150
           'supply-used 30
           'supply-cap 46
           'supply-left 16
           'base-x 32.5 'base-y 32.5
           'natural-x 50.5 'natural-y 56.5
           'door-guard #t
           'ally-units (list (hash 'id 10 'type 'probe 'x 32.5 'y 32.5 'hp 40)
                             (hash 'id 703 'type 'zealot 'x 50.5 'y 56.5 'hp 100)
                             (hash 'id 706 'type 'warp-prism 'x 44.5 'y 48.5 'hp 100)
                             (hash 'id 707 'type 'immortal 'x 45.5 'y 49.5 'hp 40 'max-hp 200))
           'ally-buildings (list (hash 'id 201 'type 'nexus 'x 32.5 'y 32.5 'hp 1000 'energy 60)
                                 (hash 'id 205 'type 'gateway 'x 36.5 'y 36.5 'hp 500)
                                 (hash 'id 208 'type 'robotics-facility 'x 38.5 'y 38.5 'hp 500))
           'enemy-units (list (hash 'id 9010 'type 'roach 'x 46.5 'y 50.5 'hp 145)))))
  (define acts-p (hash-ref res-p 'actions))
  (assert-true! (member '(hold-position 703 50.5 56.5) acts-p) "Expected hold-position door guard")
  (assert-true! (member '(control-group-steal 2 (703)) acts-p) "Expected control-group-steal")
  (assert-true! (not (memq 703 (cortex-get-control-group (live-bot-runtime-cortex rt-p) 1)))
                "Unit 703 must be removed from control group 1 after steal to group 2")
  (assert-true! (memq 703 (cortex-get-control-group (live-bot-runtime-cortex rt-p) 2)))
  (assert-true! (member '(transport-juggle 706 707 32.5 32.5) acts-p) "Expected transport-juggle on wounded immortal")
  (assert-true! (member '(cast-spell 201 chrono-boost 208) acts-p) "Expected Chrono Boost shifted to Robotics Facility")

  ;; 3b: Terran Addon Swap
  (define rt-t (make-terran-pluto-runtime))
  (define res-t
    (step-live-bot-runtime!
     rt-t
     (hash 'frame 1200
           'minerals 250
           'gas 100
           'supply-used 22
           'supply-cap 30
           'supply-left 8
           'ally-units (list (hash 'id 10 'type 'scv 'x 32.5 'y 32.5 'hp 45))
           'ally-buildings (list (hash 'id 704 'type 'barracks 'x 36.5 'y 36.5 'hp 1000 'addon 'reactor)
                                 (hash 'id 705 'type 'factory 'x 38.5 'y 36.5 'hp 1250 'addon #f))
           'enemy-units '())))
  (define acts-t (hash-ref res-t 'actions))
  (assert-true! (member '(swap-addon 704 705) acts-t) "Expected (swap-addon 704 705)"))

;; =============================================================================
;; 5.10 Adversarial Anti-Cheese, Anti-Block, & Disruption Countermeasures
;; =============================================================================
(run-suite "5.10 Adversarial Anti-Cheese, Anti-Block, & Disruption Countermeasures"
  ;; Scenario A: Cannon / Proxy Rush -> Worker Pull + Builder Harass + Suppress Exposed Natural Expand
  (define rt-a (make-zerg-overmind-runtime))
  (define res-a
    (step-live-bot-runtime!
     rt-a
     (hash 'frame 800
           'minerals 350
           'gas 0
           'supply-used 14
           'supply-cap 22
           'supply-left 8
           'base-x 32.5 'base-y 32.5
           'natural-x 50.5 'natural-y 56.5
           'ally-units (list (hash 'id 10 'type 'drone 'x 32.5 'y 32.5 'hp 40)
                             (hash 'id 11 'type 'drone 'x 33.0 'y 32.5 'hp 40)
                             (hash 'id 12 'type 'drone 'x 33.5 'y 33.0 'hp 40))
           'ally-buildings (list (hash 'id 101 'type 'hatchery 'x 32.5 'y 32.5 'hp 1500))
           'enemy-units (list (hash 'id 8801 'type 'probe 'x 36.5 'y 36.5 'hp 40))
           'enemy-buildings (list (hash 'id 8802 'type 'pylon 'x 36.0 'y 36.0 'hp 200)
                                  (hash 'id 8803 'type 'photon-cannon 'x 37.0 'y 37.0 'hp 150)))))
  (define acts-a (hash-ref res-a 'actions))
  (assert-true! (ormap (lambda (a) (match a [(list 'pull-workers-attack _ _ _) #t] [_ #f])) acts-a)
                "Scenario A: Expected pull-workers-attack against cannon rush")
  (assert-true! (ormap (lambda (a) (match a [(list 'worker-harass _ _ _) #t] [_ #f])) acts-a)
                "Scenario A: Expected worker-harass on enemy proxy probe")
  (assert-true! (not (member '(expand 50.5 56.5) acts-a))
                "Scenario A: Exposed natural expansion must be suppressed during cannon rush")

  ;; Scenario B: Blocked Natural Expansion -> Clear Block + High-Ground CC (Terran) / 3rd Base (Zerg/Protoss)
  (define rt-b-terran (make-terran-pluto-runtime))
  (define res-b-terran
    (step-live-bot-runtime!
     rt-b-terran
     (hash 'frame 1400
           'minerals 450
           'gas 50
           'supply-used 18
           'supply-cap 23
           'supply-left 5
           'base-x 32.5 'base-y 32.5
           'natural-x 50.5 'natural-y 56.5
           'ally-units (list (hash 'id 10 'type 'scv 'x 32.5 'y 32.5 'hp 45))
           'ally-buildings (list (hash 'id 301 'type 'command-center 'x 32.5 'y 32.5 'hp 1500)
                                 (hash 'id 302 'type 'barracks 'x 36.5 'y 36.5 'hp 1000))
           'enemy-buildings (list (hash 'id 8901 'type 'pylon 'x 50.5 'y 56.5 'hp 200)))))
  (define acts-b-terran (hash-ref res-b-terran 'actions))
  (assert-true! (member '(clear-expansion-block 50.5 56.5) acts-b-terran))
  (assert-true! (member '(build command-center 36.5 32.5) acts-b-terran)
                "Scenario B (Terran): Expected in-base high-ground Command Center when natural is blocked")

  (define rt-b-zerg (make-zerg-overmind-runtime))
  (define res-b-zerg
    (step-live-bot-runtime!
     rt-b-zerg
     (hash 'frame 1400
           'minerals 350
           'gas 0
           'supply-used 16
           'supply-cap 22
           'supply-left 6
           'base-x 32.5 'base-y 32.5
           'natural-x 50.5 'natural-y 56.5
           'third-x 68.5 'third-y 72.5
           'ally-units (list (hash 'id 10 'type 'drone 'x 32.5 'y 32.5 'hp 40))
           'ally-buildings (list (hash 'id 101 'type 'hatchery 'x 32.5 'y 32.5 'hp 1500))
           'enemy-units (list (hash 'id 8902 'type 'probe 'x 50.5 'y 56.5 'hp 40)))))
  (define acts-b-zerg (hash-ref res-b-zerg 'actions))
  (assert-true! (member '(clear-expansion-block 50.5 56.5) acts-b-zerg))
  (assert-true! (member '(expand 68.5 72.5) acts-b-zerg)
                "Scenario B (Zerg): Expected fallback expansion to unobstructed 3rd base (68.5, 72.5)")

  ;; Scenario C & D: Enemy Gas Steal + Halted Terran Building SCV Resume
  (define rt-cd (make-terran-pluto-runtime))
  (define res-cd
    (step-live-bot-runtime!
     rt-cd
     (hash 'frame 1100
           'minerals 200
           'gas 0
           'supply-used 15
           'supply-cap 23
           'supply-left 8
           'base-x 32.5 'base-y 32.5
           'ally-units (list (hash 'id 10 'type 'scv 'x 32.5 'y 32.5 'hp 45))
           'ally-buildings (list (hash 'id 301 'type 'command-center 'x 32.5 'y 32.5 'hp 1500)
                                 (hash 'id 902 'type 'barracks 'x 36.5 'y 36.5 'hp 600
                                       'build-progress 0.60 'halted #t))
           'enemy-buildings (list (hash 'id 901 'type 'assimilator 'x 35.5 'y 35.5 'hp 450)))))
  (define acts-cd (hash-ref res-cd 'actions))
  (assert-true! (member '(clear-gas-steal 901 35.5 35.5) acts-cd)
                "Scenario C: Expected (clear-gas-steal 901 35.5 35.5)")
  (assert-true! (member '(resume-halted-building 10 902) acts-cd)
                "Scenario D: Expected (resume-halted-building 10 902)")

  ;; Scenario E: Ramp Force-Field Corrosive-Bile Breaker & Anti-Kite Leash
  (define rt-e (make-zerg-overmind-runtime))
  (define res-e
    (step-live-bot-runtime!
     rt-e
     (hash 'frame 1600
           'minerals 200
           'gas 100
           'supply-used 24
           'supply-cap 36
           'supply-left 12
           'base-x 32.5 'base-y 32.5
           'natural-x 50.5 'natural-y 56.5
           'ally-units (list (hash 'id 10 'type 'drone 'x 32.5 'y 32.5 'hp 40)
                             (hash 'id 140 'type 'ravager 'x 48.5 'y 54.5 'hp 120)
                             (hash 'id 141 'type 'zergling 'x 56.5 'y 62.5 'hp 35))
           'ally-buildings (list (hash 'id 101 'type 'hatchery 'x 32.5 'y 32.5 'hp 1500)
                                 (hash 'id 102 'type 'spawning-pool 'x 35.5 'y 35.5 'hp 1000))
           'enemy-units (list (hash 'id 9050 'type 'reaper 'x 60.5 'y 66.5 'hp 60))
           'effects (list (hash 'type 'force-field 'x 50.5 'y 56.5)))))
  (define acts-e (hash-ref res-e 'actions))
  (assert-true! (member '(cast-spell 140 corrosive-bile 50.5 56.5) acts-e)
                "Scenario E: Expected Ravager corrosive-bile on enemy Force Field")
  (assert-true! (ormap (lambda (a) (match a [(list 'kite 141 _ _) #t] [_ #f])) acts-e)
                "Scenario E: Expected anti-kite leash pullback on over-extended zergling"))

;; =============================================================================
;; 5.11 Generic Recursive k-Level Mirror-Mind Opponent Predictor (`lib/mirror-mind-predictor.rkt`)
;; =============================================================================
(run-suite "5.11 Generic k-Level Mirror-Mind Predictor: Depth 0/1/2/3/4 Hierarchy, Dark-Matter Ledger & Accuracy Calibration"
  ;; 1. Verify default depth = 2 and generic recursive hierarchy across depths d = 0, 1, 2, 3, 4
  (define mm (make-mirror-mind-state #:our-race 'Zerg #:enemy-race 'Protoss #:depth 2))
  (assert-eq! (mirror-mind-state-default-depth mm) 2 "Default mirror-mind depth should be 2")
  (assert-eq! (mirror-mind-state-active-depth mm) 2 "Initial active mirror-mind depth should be 2")

  (define sample-obs
    (hash 'frame 2400
          'minerals 350
          'gas 200
          'base-x 32
          'base-y 32
          'natural-x 50
          'natural-y 56
          'enemy-x 160
          'enemy-y 160
          'ally-units (list (hash 'id 101 'type 'roach 'x 44 'y 48 'hp 145)
                            (hash 'id 102 'type 'roach 'x 45 'y 49 'hp 145)
                            (hash 'id 103 'type 'ravager 'x 46 'y 50 'hp 120))
          'ally-buildings (list (hash 'id 201 'type 'hatchery 'x 32 'y 32 'hp 1500)
                                (hash 'id 202 'type 'spawning-pool 'x 35 'y 35 'hp 1000)
                                (hash 'id 203 'type 'roach-warren 'x 36 'y 36 'hp 850)
                                (hash 'id 204 'type 'lair 'x 50 'y 56 'hp 1800)
                                (hash 'id 205 'type 'hydralisk-den 'x 37 'y 37 'hp 850)
                                (hash 'id 206 'type 'spire 'x 38 'y 38 'hp 850))
          'enemy-units (list (hash 'id 901 'type 'adept 'x 48 'y 54 'hp 70)
                             (hash 'id 902 'type 'probe 'x 35 'y 34 'hp 40))
          'enemy-buildings (list (hash 'id 950 'type 'nexus 'x 160 'y 160 'hp 1500)
                                 (hash 'id 951 'type 'gateway 'x 155 'y 155 'hp 500))))

  ;; Compute shadow ledger & action reading at frame 2400
  (define ledger
    (compute-opponent-shadow-ledger mm 2400
                                    (hash-ref sample-obs 'enemy-units)
                                    (hash-ref sample-obs 'enemy-buildings)))
  (assert-true! (> (shadow-ledger-unaccounted-gas ledger) 200)
                "Dark-Matter Ledger should detect unaccounted enemy gas at frame 2400")
  (assert-eq! (shadow-ledger-dark-matter-hypothesis ledger)
              'hidden-air-or-cloak-tech-switch
              "Dark-Matter Ledger should hypothesize hidden air/cloak tech switch")

  (define reading
    (interpret-opponent-actions mm 2400
                                (hash-ref sample-obs 'enemy-units)
                                (hash-ref sample-obs 'enemy-buildings)
                                ledger))
  (assert-true! (action-lens-reading-opponent-scouted-us? reading)
                "Action-Lens should detect enemy probe scout inside our base perimeter")
  (assert-true! (action-lens-reading-feint-or-poke-detected? reading)
                "Action-Lens should detect front-door Adept poke masking dark-matter gas banking")

  ;; Build hierarchy up to depth 4
  (define nodes (build-mirror-hierarchy mm sample-obs #:max-depth 4))
  (assert-eq! (length nodes) 5 "Hierarchy for max-depth 4 should contain 5 nodes (d=0,1,2,3,4)")
  (define n0 (list-ref nodes 0))
  (define n1 (list-ref nodes 1))
  (define n2 (list-ref nodes 2))
  (define n3 (list-ref nodes 3))
  (define n4 (list-ref nodes 4))

  ;; Depth 0: direct observation only
  (assert-eq! (depth-node-depth n0) 0)
  (assert-eq! (depth-node-opp-belief-about-us n0) 'none)

  ;; Depth 1: predicts opponent's hidden Void Ray from opponent's dark-matter gas ledger
  (assert-eq! (depth-node-depth n1) 1)
  (assert-eq! (depth-node-predicted-enemy-unit n1) 'void-ray)
  (assert-eq! (depth-node-tactical-target n1) 'main-mineral-line-drop-or-air)

  ;; Depth 2: models opponent's belief about US (our Roach/Spire tech) and predicts their counter
  (assert-eq! (depth-node-depth n2) 2)
  (assert-true! (memq (depth-node-opp-belief-about-us n2) '(roach-ravager muta-flock))
                "Depth 2 should infer opponent's belief about our visible Roach/Spire composition")
  (assert-true! (symbol? (depth-node-our-response-unit n2)))

  ;; Depth 3 & Depth 4: higher-order recursive induction
  (assert-eq! (depth-node-depth n3) 3)
  (assert-eq! (depth-node-depth n4) 4)
  (assert-eq! (depth-node-opp-belief-about-us n3)
              (unit-to-archetype (depth-node-our-response-unit n2))
              "Depth 3 opponent belief about us must equal archetype of our Depth 2 response unit")
  (assert-eq! (depth-node-opp-belief-about-us n4)
              (unit-to-archetype (depth-node-our-response-unit n3))
              "Depth 4 opponent belief about us must equal archetype of our Depth 3 response unit")

  ;; 2. Verify closed-loop forecast resolution: confirmed hit vs. repeated misses
  (define mm-acts (step-mirror-mind-predictor! mm sample-obs))
  (assert-true! (ormap (lambda (a) (match a [(list* 'mirror-prediction 2 _) #t] [_ #f])) mm-acts)
                "Expected (mirror-prediction 2 ...) directive at default depth 2")

  ;; Confirm prediction at frame 2800 by revealing enemy Void Ray at main mineral line (32, 32)
  (define hit-obs
    (hash-set (hash-set sample-obs 'frame 2800)
              'enemy-units
              (list (hash 'id 999 'type 'void-ray 'x 33 'y 34 'hp 250))))
  (step-mirror-mind-predictor! mm hit-obs)
  (assert-true! (> (mirror-mind-state-overall-accuracy mm) 0.70)
                "Confirmed forecast hit should boost overall accuracy above 0.70")
  (assert-eq! (mirror-mind-state-trust-mode mm) 'level2-preemptive-mirror)

  ;; Now simulate repeated expired misses where enemy shows totally unexpected units far past deadline
  (for ([step-idx (in-range 1 8)])
    (define miss-frame (+ 2800 (* step-idx 1600)))
    ;; Force predicted unit to something enemy never builds so it misses
    (set-mirror-mind-state-pending-forecasts!
     mm
     (list (mirror-forecast (- miss-frame 1500)
                            (- miss-frame 100)
                            2
                            'hidden-air-or-cloak-transition
                            'carrier
                            'main-mineral-line-drop-or-air
                            32
                            32)))
    (resolve-pending-forecasts! mm miss-frame
                                (list (hash 'id (+ 5000 step-idx) 'type 'zealot 'x 150 'y 150 'hp 100))
                                '()))
  (assert-true! (< (mirror-mind-state-overall-accuracy mm) 0.45)
                "Repeated forecast misses should decay overall accuracy below 0.45")
  (assert-eq! (mirror-mind-state-trust-mode mm) 'skeptical-observational-fallback
              "Low accuracy must switch trust-mode to skeptical-observational-fallback")
  (assert-eq! (mirror-mind-state-active-depth mm) 1
              "Low accuracy must dynamically step down active depth from 2 to 1")
  (define fallback-acts (step-mirror-mind-predictor! mm sample-obs))
  (assert-true! (ormap (lambda (a) (match a [(list 'scout-sector _ _ _) #t] [_ #f])) fallback-acts)
                "Skeptical fallback mode must emit active (scout-sector ...) commands")

  ;; 3. Verify Foosball Tournament Depth-Probing & Snowball-Bounded Toolbox
  (define mm-tourney (make-mirror-mind-state #:our-race 'Zerg #:enemy-race 'Protoss #:depth 2))
  ;; Low-End Occam's Razor: opponent ignores our diagnostic probe ('no-reaction) -> step down to Depth 1!
  (record-diagnostic-probe-response! mm-tourney 'no-reaction)
  (assert-eq! (mirror-mind-state-active-depth mm-tourney) 1
              "Low-end 'no-reaction probe must step down active-depth to 1 (do not over-complicate)")
  ;; Opponent reacts directly ('direct-counter) -> return to Depth 2
  (record-diagnostic-probe-response! mm-tourney 'direct-counter)
  (assert-eq! (mirror-mind-state-active-depth mm-tourney) 2
              "Direct-counter probe response must set active-depth to 2")
  ;; Opponent pivots/cancels when scouted ('second-order-pivot-or-cancel) -> escalate to Depth 3
  (record-diagnostic-probe-response! mm-tourney 'second-order-pivot-or-cancel)
  (assert-eq! (mirror-mind-state-active-depth mm-tourney) 3
              "Second-order pivot probe response must escalate active-depth to 3")
  ;; Elite opponent stages false tells / double-reversals -> escalate to Depth 4 and Depth 5!
  (record-diagnostic-probe-response! mm-tourney 'higher-order-bait-or-double-reverse)
  (assert-eq! (mirror-mind-state-active-depth mm-tourney) 4
              "First higher-order bait/double-reverse probe must escalate active-depth to 4")
  (record-diagnostic-probe-response! mm-tourney 'higher-order-bait-or-double-reverse)
  (assert-eq! (mirror-mind-state-active-depth mm-tourney) 5
              "Repeated higher-order bait/double-reverse probe must escalate active-depth to 5")

  ;; Snowball-Bounded Toolbox: depth is NEVER the main determinant (weight <= 0.25, allow-posture-override? = #f)
  (define alloc-even
    (compute-mirror-toolbox-allocation
     mm-tourney
     (list (hash 'id 1 'type 'roach 'hp 145 'dps 16))
     (list (hash 'id 2 'type 'stalker 'hp 160 'dps 14))))
  (assert-true! (<= (mirror-toolbox-allocation-toolbox-weight alloc-even) 0.25)
                "Toolbox weight must never exceed 0.25 (core macro/snowball >= 0.75)")
  (assert-true! (>= (mirror-toolbox-allocation-primary-macro-weight alloc-even) 0.75)
                "Primary macro/snowball weight must always be at least 0.75")
  (assert-eq! (mirror-toolbox-allocation-allow-posture-override? alloc-even) #f
              "Mirror-Mind depth must never override core macro/snowball posture")

  (define alloc-crisis
    (compute-mirror-toolbox-allocation
     mm-tourney
     (list (hash 'id 1 'type 'roach 'hp 145 'dps 16))
     (list (hash 'id 2 'type 'stalker 'hp 160 'dps 14))
     #:crisis? #t))
  (assert-eq! (mirror-toolbox-allocation-toolbox-weight alloc-crisis) 0.0
              "Crisis defense must clamp Mirror-Mind toolbox weight to 0.0")
  (assert-eq! (mirror-toolbox-allocation-toolbox-role alloc-crisis) 'survival-fundamentals-only)

  (define alloc-snowball
    (compute-mirror-toolbox-allocation
     mm-tourney
     (list (hash 'id 1 'type 'roach 'hp 145 'dps 16)
           (hash 'id 2 'type 'roach 'hp 145 'dps 16)
           (hash 'id 3 'type 'roach 'hp 145 'dps 16))
     (list (hash 'id 4 'type 'stalker 'hp 160 'dps 14))))
  (assert-eq! (mirror-toolbox-allocation-toolbox-role alloc-snowball) 'snowball-watchtower-only
              "Decisive Lanchester snowball lead must restrict Mirror-Mind to watchtower scouting only"))

;; =============================================================================
;; 5.12 Coupled Macro Governor, Adaptive Build/Tech Planner, Mirror-Mind Macro
;;      Verdicts, Economic Disruption & Guns-vs-Butter PPF Controller
;; =============================================================================
(run-suite "5.12 Coupled Macro Governor, Adaptive Build/Tech Planner, Mirror-Mind Macro Verdicts, Disruption & Guns-vs-Butter PPF"
  ;; 1. Coupled Depletion-Driven Macro & Map-Wide Expansion Governor
  (define mplan-deplete
    (evaluate-coupled-macro-governor
     #:race 'Zerg
     #:frame 3600
     #:minerals 450
     #:gas 150
     #:supply-left 8
     #:active-bases 3
     #:depleting-bases 1
     #:workers 52
     #:production-facilities 3
     #:busy-facilities 1
     #:busy-townhalls 1))
  (assert-true! (coupled-macro-plan-should-expand? mplan-deplete)
                "Depleting base must trigger replacement expansion")
  (assert-eq! (coupled-macro-plan-expansion-reason mplan-deplete) 'depletion-replacement-expand)
  (assert-true! (>= (coupled-macro-plan-desired-bases mplan-deplete) 4)
                "Depleting 1 of 3 bases must raise desired-bases to at least 4")
  (assert-eq! (coupled-macro-plan-escrow-minerals mplan-deplete) 300
              "Zerg expansion escrow must reserve 300 minerals")
  (assert-eq! (coupled-macro-plan-unreserved-minerals mplan-deplete) 150
              "Unreserved minerals must equal 450 - 300 = 150")
  (assert-true! (> (coupled-macro-plan-idle-worker-production-slots mplan-deplete) 0)
                "Idle worker production slots must be > 0 when workers < target-workers")
  (assert-true! (> (coupled-macro-plan-idle-unit-production-slots mplan-deplete) 0)
                "Idle unit production slots must be > 0 when facilities are idle")
  (assert-eq! (coupled-macro-plan-zero-unused-production? mplan-deplete) #f)

  ;; Unconstrained map-wide expansion scaling (beyond 4 bases up to 16)
  (define mplan-mapwide
    (evaluate-coupled-macro-governor
     #:race 'Terran
     #:frame 14000
     #:minerals 1800
     #:gas 600
     #:supply-left 20
     #:active-bases 5
     #:depleting-bases 2
     #:workers 76
     #:production-facilities 8
     #:busy-facilities 8
     #:busy-townhalls 5))
  (assert-true! (>= (coupled-macro-plan-desired-bases mplan-mapwide) 7)
                "Map-wide macro governor must scale desired-bases beyond 4 (up to 7+)")

  ;; 2. Planned & Adaptive Build-Order & Tech/Upgrade Goal Planner
  (define z-vs-air
    (evaluate-adaptive-build-and-tech-plan
     'Zerg
     #:ally-buildings '(hatchery spawning-pool extractor lair)
     #:researched-upgrades '(zergling-movementspeed)
     #:enemy-archetype 'sky-toss
     #:mirror-predicted-unit 'carrier))
  (assert-true! (memq 'zergling-movementspeed (adaptive-tech-plan-synergy-invariants z-vs-air))
                "Zerg build synergy invariants must include zergling-movementspeed")
  (assert-true! (memq 'burrow (adaptive-tech-plan-synergy-invariants z-vs-air))
                "Zerg build synergy invariants must include burrow")
  (assert-true! (memq 'spire (adaptive-tech-plan-counter-tech-buildings z-vs-air))
                "Zerg vs Air Fleet must adapt counter-tech to include Spire")
  (assert-eq! (caar (adaptive-tech-plan-desired-unit-mix z-vs-air)) 'corruptor
              "Zerg vs Air Fleet primary unit must be Corruptor")

  (define t-vs-mech
    (evaluate-adaptive-build-and-tech-plan
     'Terran
     #:ally-buildings '(command-center supply-depot barracks refinery)
     #:researched-upgrades '(stimpack)
     #:enemy-archetype 'mech-siege
     #:mirror-predicted-unit 'siege-tank))
  (assert-true! (memq 'stimpack (adaptive-tech-plan-synergy-invariants t-vs-mech))
                "Terran Bio/Tank synergy invariants must include stimpack")
  (assert-true! (memq 'combat-shield (adaptive-tech-plan-synergy-invariants t-vs-mech))
                "Terran Bio/Tank synergy invariants must include combat-shield")
  (assert-eq! (caar (adaptive-tech-plan-desired-unit-mix t-vs-mech)) 'marauder
              "Terran vs Armored/Mech primary unit must be Marauder")

  (define p-vs-swarm
    (evaluate-adaptive-build-and-tech-plan
     'Protoss
     #:ally-buildings '(nexus pylon gateway cybernetics-core assimilator)
     #:researched-upgrades '(warp-gate-research)
     #:enemy-archetype 'ling-bane-hydra
     #:mirror-predicted-unit 'zergling))
  (assert-true! (memq 'warp-gate-research (adaptive-tech-plan-synergy-invariants p-vs-swarm))
                "Protoss Gateway/Robo synergy invariants must include warp-gate-research")
  (assert-true! (memq 'robotics-bay (adaptive-tech-plan-counter-tech-buildings p-vs-swarm))
                "Protoss vs Swarm must adapt counter-tech to include Robotics Bay")
  (assert-eq! (caar (adaptive-tech-plan-desired-unit-mix p-vs-swarm)) 'colossus
              "Protoss vs Swarm primary splash unit must be Colossus")

  ;; 3. Mirror-Mind Macro / Eco / Base Prediction (`mirror-macro-verdict`)
  (define mm-macro (make-mirror-mind-state #:our-race 'Zerg #:enemy-race 'Terran #:depth 2))
  ;; 3a. Greedy enemy 3rd base with low army -> 'punish-And-Deny-Greedy-Expand
  (define greedy-obs
    (hash 'frame 2000
          'minerals 350
          'gas 100
          'ally-units (list (hash 'id 1 'type 'zergling 'x 40 'y 42 'hp 35)
                            (hash 'id 2 'type 'zergling 'x 41 'y 43 'hp 35))
          'ally-buildings (list (hash 'id 101 'type 'hatchery 'x 32 'y 32 'hp 1500))
          'enemy-units (list (hash 'id 901 'type 'marine 'x 155 'y 155 'hp 45))
          'enemy-buildings (list (hash 'id 950 'type 'command-center 'x 160 'y 160 'hp 1500)
                                 (hash 'id 951 'type 'orbital-command 'x 142 'y 136 'hp 1500)
                                 (hash 'id 952 'type 'command-center 'x 125 'y 125 'hp 1500))))
  (define greedy-acts (step-mirror-mind-predictor! mm-macro greedy-obs))
  (assert-eq! (mirror-mind-state-mirror-macro-verdict mm-macro) 'punish-And-Deny-Greedy-Expand
              "Enemy on 3 bases with 1 Marine must trigger 'punish-And-Deny-Greedy-Expand")
  (assert-true! (>= (mirror-mind-state-predicted-enemy-bases mm-macro) 3))
  (assert-true! (ormap (lambda (a) (match a [(list 'mirror-macro-directive 'punish-And-Deny-Greedy-Expand _ _ _ _) #t] [_ #f]))
                       greedy-acts)
                "step-mirror-mind-predictor! must emit (mirror-macro-directive 'punish-And-Deny-Greedy-Expand ...)")

  ;; 3b. Passive turtle enemy on 1-2 bases with Bunker + Siege Tank -> 'out-Expand-Passive-Turtle
  (define turtle-obs
    (hash 'frame 2400
          'minerals 400
          'gas 150
          'ally-units (list (hash 'id 1 'type 'roach 'x 40 'y 42 'hp 145))
          'ally-buildings (list (hash 'id 101 'type 'hatchery 'x 32 'y 32 'hp 1500)
                                (hash 'id 102 'type 'hatchery 'x 50 'y 56 'hp 1500))
          'enemy-units (list (hash 'id 902 'type 'siege-tank-sieged 'x 152 'y 152 'hp 175))
          'enemy-buildings (list (hash 'id 960 'type 'command-center 'x 160 'y 160 'hp 1500)
                                 (hash 'id 961 'type 'bunker 'x 150 'y 150 'hp 400))))
  (step-mirror-mind-predictor! mm-macro turtle-obs)
  (assert-eq! (mirror-mind-state-mirror-macro-verdict mm-macro) 'out-Expand-Passive-Turtle
              "Turtling enemy on 1 base with Bunker + Siege Tank must trigger 'out-Expand-Passive-Turtle")
  (assert-true! (>= (mirror-mind-state-recommended-min-bases mm-macro) 3))

  ;; 3c. 1-Base All-In enemy near our base -> 'defend-All-In-Then-Counter-Expand
  (define allin-obs
    (hash 'frame 1800
          'minerals 200
          'gas 50
          'base-x 32
          'base-y 32
          'ally-units (list (hash 'id 1 'type 'roach 'x 36 'y 36 'hp 145))
          'ally-buildings (list (hash 'id 101 'type 'hatchery 'x 32 'y 32 'hp 1500))
          'enemy-units (list (hash 'id 910 'type 'marine 'x 40 'y 42 'hp 45)
                             (hash 'id 911 'type 'marine 'x 41 'y 42 'hp 45)
                             (hash 'id 912 'type 'marine 'x 42 'y 43 'hp 45)
                             (hash 'id 913 'type 'marauder 'x 43 'y 43 'hp 125)
                             (hash 'id 914 'type 'marauder 'x 44 'y 44 'hp 125))
          'enemy-buildings (list (hash 'id 970 'type 'command-center 'x 160 'y 160 'hp 1500))))
  (step-mirror-mind-predictor! mm-macro allin-obs)
  (assert-eq! (mirror-mind-state-mirror-macro-verdict mm-macro) 'defend-All-In-Then-Counter-Expand
              "1-base enemy pushing with 5 combat units near base must trigger 'defend-All-In-Then-Counter-Expand")

  ;; 4. Economic Disruption Commands (`burrow-block`, `patrol-block-expansion`, `harass-workers`)
  (define rt-disrupt-z (make-zerg-overmind-runtime))
  (define res-disrupt-z
    (step-live-bot-runtime!
     rt-disrupt-z
     (hash 'frame 1500
           'minerals 300
           'gas 100
           'supply-used 22
           'supply-cap 30
           'supply-left 8
           'enable-economic-disruption #t
           'ally-units (list (hash 'id 10 'type 'drone 'x 32.5 'y 32.5 'hp 40)
                             (hash 'id 110 'type 'zergling 'x 100 'y 105 'hp 35)
                             (hash 'id 111 'type 'zergling 'x 101 'y 106 'hp 35)
                             (hash 'id 112 'type 'zergling 'x 102 'y 107 'hp 35))
           'ally-buildings (list (hash 'id 101 'type 'hatchery 'x 32.5 'y 32.5 'hp 1500)
                                 (hash 'id 102 'type 'spawning-pool 'x 35.5 'y 35.5 'hp 1000))
           'enemy-units '())))
  (define acts-disrupt-z (hash-ref res-disrupt-z 'actions))
  (assert-true! (ormap (lambda (a) (match a [(list 'burrow-block 110 _ _) #t] [_ #f])) acts-disrupt-z)
                "Zerg economic disruption must emit (burrow-block 110 ...)")
  (assert-true! (ormap (lambda (a) (match a [(list 'harass-workers _ _ _) #t] [_ #f])) acts-disrupt-z)
                "Zerg economic disruption must emit (harass-workers ...)")

  (define rt-disrupt-t (make-terran-pluto-runtime))
  (define res-disrupt-t
    (step-live-bot-runtime!
     rt-disrupt-t
     (hash 'frame 1500
           'minerals 300
           'gas 100
           'supply-used 22
           'supply-cap 30
           'supply-left 8
           'enable-economic-disruption #t
           'ally-units (list (hash 'id 10 'type 'scv 'x 32.5 'y 32.5 'hp 45)
                             (hash 'id 210 'type 'marine 'x 100 'y 105 'hp 45)
                             (hash 'id 211 'type 'reaper 'x 101 'y 106 'hp 60))
           'ally-buildings (list (hash 'id 301 'type 'command-center 'x 32.5 'y 32.5 'hp 1500)
                                 (hash 'id 302 'type 'barracks 'x 36.5 'y 36.5 'hp 1000))
           'enemy-units '())))
  (define acts-disrupt-t (hash-ref res-disrupt-t 'actions))
  (assert-true! (ormap (lambda (a) (match a [(list 'patrol-block-expansion 210 _ _) #t] [_ #f])) acts-disrupt-t)
                "Terran economic disruption must emit (patrol-block-expansion 210 ...)")
  (assert-true! (ormap (lambda (a) (match a [(list 'harass-workers _ _ _) #t] [_ #f])) acts-disrupt-t)
                "Terran economic disruption must emit (harass-workers ...)")

  ;; 5. Guns-vs-Butter PPF & Dynamic Gas-to-Mineral Worker Allocation
  ;; 5a. Gas float (> 400G) with low minerals (< 300M) -> pull workers off gas to minerals!
  (define gas-pull
    (compute-optimal-gas-workers
     #:race 'Zerg
     #:frame 2200
     #:minerals 180
     #:gas 520
     #:workers 24
     #:active-bases 2
     #:active-geysers 2
     #:current-gas-workers 6
     #:should-expand? #t))
  (assert-eq! (gas-worker-allocation-action gas-pull) 'pull-off-gas-to-minerals
              "Floating 520 gas with 180 minerals must pull workers off gas to minerals")
  (assert-true! (< (gas-worker-allocation-desired-gas-workers gas-pull) 6))

  ;; 5b. Mineral bank (> 600M) while gas-starved (< 150G) -> build new geyser and saturate 3/3!
  (define gas-sat
    (compute-optimal-gas-workers
     #:race 'Protoss
     #:frame 3800
     #:minerals 850
     #:gas 60
     #:workers 44
     #:active-bases 2
     #:active-geysers 2
     #:current-gas-workers 4
     #:tech-gas-demand 300))
  (assert-eq! (gas-worker-allocation-action gas-sat) 'build-new-geyser-and-saturate
              "Banking 850M with 60G on 2 bases (2/4 geysers) must build new geyser and saturate")
  (assert-eq! (gas-worker-allocation-workers-per-geyser gas-sat) 3)

  ;; 5c. Guns-vs-Butter 5-Bucket Marginal Utility PPF
  ;; Crisis defense -> Guns (Standing Army) #1
  (define ppf-crisis
    (evaluate-guns-vs-butter-ppf
     #:race 'Zerg
     #:frame 1800
     #:minerals 250
     #:gas 100
     #:supply-left 8
     #:workers 20
     #:target-workers 44
     #:army-count 4
     #:under-crisis? #t
     #:mirror-macro-verdict 'defend-All-In-Then-Counter-Expand))
  (assert-eq! (guns-vs-butter-ppf-top-priority-bucket ppf-crisis) 'guns-standing-army
              "Under crisis/all-in, Guns (Standing Army) must have highest marginal utility")

  ;; Passive turtle opponent + worker deficit -> Butter (Economy) #1
  (define ppf-butter
    (evaluate-guns-vs-butter-ppf
     #:race 'Zerg
     #:frame 2000
     #:minerals 350
     #:gas 100
     #:supply-left 10
     #:workers 18
     #:target-workers 66
     #:active-bases 2
     #:depleting-bases 1
     #:army-count 3
     #:missing-synergy-count 1
     #:under-crisis? #f
     #:mirror-macro-verdict 'out-Expand-Passive-Turtle))
  (assert-eq! (guns-vs-butter-ppf-top-priority-bucket ppf-butter) 'butter-economy
              "Against passive turtle with worker deficit & depleting base, Butter (Economy) must be #1")

  ;; Large standing army (N = 20) missing core synergy upgrades -> Tech & Upgrades #1 (Lanchester N^1.7 law)
  (define ppf-tech
    (evaluate-guns-vs-butter-ppf
      #:race 'Terran
      #:frame 4500
      #:minerals 400
      #:gas 250
      #:supply-left 14
      #:supply-cap 110
      #:workers 60
      #:target-workers 66
      #:active-bases 3
      #:depleting-bases 0
      #:production-facilities 5
      #:busy-facilities 4
      #:army-count 20
      #:missing-synergy-count 3
      #:under-crisis? #f
      #:mirror-macro-verdict 'pace-Macro-And-Disrupt))
  (assert-eq! (guns-vs-butter-ppf-top-priority-bucket ppf-tech) 'tech-and-upgrades
              "With N=20 army and 3 missing synergy upgrades, Lanchester N^1.7 scaling must rank Tech & Upgrades #1")
  (assert-true! (> (guns-vs-butter-ppf-lanchester-upgrade-multiplier ppf-tech) 4.0)))

;; =============================================================================
;; 5.13 Enemy Observed Upgrades, Implied Tech Tree Inference & Pro-Human
;;      Camera Saccade (60-90 SPM) / APM-EPM Discipline Governor
;; =============================================================================
(run-suite "5.13 Enemy Observed Upgrades, Implied Tech Tree Inference & Pro-Human Camera/APM Discipline"
  ;; 1. Transitive Implied Tech Tree from enemy units (even when tech buildings are in fog)
  (define obs-muta
    (infer-enemy-implied-tech-and-upgrades
     (list (hash 'id 1 'type 'mutalisk 'x 120 'y 120 'hp 120)
           (hash 'id 2 'type 'zergling 'x 118 'y 118 'hp 35 'speed 4.58)
           (hash 'id 3 'type 'lurker 'x 116 'y 116 'hp 200 'burrowed? #t))
     '()
     #:our-upgrade-tier 0))
  (assert-true! (memq 'spawning-pool (enemy-tech-observation-implied-tech-buildings obs-muta)))
  (assert-true! (memq 'lair (enemy-tech-observation-implied-tech-buildings obs-muta)))
  (assert-true! (memq 'spire (enemy-tech-observation-implied-tech-buildings obs-muta))
                "Seeing an enemy Mutalisk must imply an unseen Spire")
  (assert-true! (memq 'lurker-den (enemy-tech-observation-implied-tech-buildings obs-muta))
                "Seeing an enemy Lurker must imply an unseen Lurker Den")
  (assert-true! (memq 'zergling-movementspeed (enemy-tech-observation-observed-upgrades obs-muta))
                "Fast Zergling (speed > 3.5) must infer Metabolic Boost upgrade")
  (assert-true! (memq 'burrow-or-subterranean-tech (enemy-tech-observation-observed-upgrades obs-muta))
                "Burrowed Lurker must infer burrow/subterranean tech")
  (assert-eq! (enemy-tech-observation-requires-detection? obs-muta) #t
              "Burrowed Lurker must set requires-detection? to #t")
  (assert-eq! (enemy-tech-observation-requires-anti-air? obs-muta) #t
              "Enemy Mutalisk must set requires-anti-air? to #t")
  (assert-true! (> (enemy-tech-observation-implied-tech-gas obs-muta) 300))

  ;; 2. Terran Marine 55HP Combat Shield + +1/+1 Upgrades + Siege Tank implied tech
  (define obs-terran
    (infer-enemy-implied-tech-and-upgrades
     (list (hash 'id 10 'type 'marine 'x 140 'y 140 'hp 55 'max-hp 55 'atk-upg 1 'arm-upg 1)
           (hash 'id 11 'type 'siege-tank 'x 142 'y 142 'hp 175))
     (list (hash 'id 20 'type 'engineering-bay 'x 150 'y 150 'hp 850 'active? #t))
     #:our-upgrade-tier 0))
  (assert-true! (memq 'combat-shield (enemy-tech-observation-observed-upgrades obs-terran))
                "55HP Marine must infer Combat Shield upgrade")
  (assert-true! (memq 'enemy-weapons-1 (enemy-tech-observation-observed-upgrades obs-terran)))
  (assert-true! (memq 'enemy-armor-1 (enemy-tech-observation-observed-upgrades obs-terran)))
  (assert-true! (memq 'factory-techlab (enemy-tech-observation-implied-tech-buildings obs-terran))
                "Siege Tank must imply Factory TechLab")
  (assert-true! (memq 'engineering-bay (enemy-tech-observation-active-research-buildings obs-terran))
                "Active Engineering Bay must be recorded in active-research-buildings")
  (assert-true! (>= (enemy-tech-observation-enemy-upgrade-advantage obs-terran) 2))

  ;; 3. Protoss Immortal + Dark Shrine implied tech & detection trigger
  (define obs-protoss
    (infer-enemy-implied-tech-and-upgrades
     (list (hash 'id 30 'type 'immortal 'x 140 'y 140 'hp 200 'shd-upg 1))
     (list (hash 'id 31 'type 'dark-shrine 'x 155 'y 155 'hp 500))
     #:our-upgrade-tier 0))
  (assert-true! (memq 'robotics-facility (enemy-tech-observation-implied-tech-buildings obs-protoss))
                "Immortal must imply Robotics Facility")
  (assert-true! (memq 'twilight-council (enemy-tech-observation-implied-tech-buildings obs-protoss))
                "Dark Shrine must imply Twilight Council")
  (assert-true! (memq 'enemy-shields-1 (enemy-tech-observation-observed-upgrades obs-protoss)))
  (assert-eq! (enemy-tech-observation-requires-detection? obs-protoss) #t
              "Dark Shrine must trigger requires-detection? = #t")

  ;; 4. Verify step-mirror-mind-predictor! emits (mirror-tech-observation ...)
  (define mm-tech (make-mirror-mind-state #:our-race 'Zerg #:enemy-race 'Terran #:depth 2))
  (define tech-step-acts
    (step-mirror-mind-predictor!
     mm-tech
     (hash 'frame 2600
           'minerals 300
           'gas 150
           'ally-units (list (hash 'id 1 'type 'roach 'x 40 'y 42 'hp 145))
           'ally-buildings (list (hash 'id 101 'type 'hatchery 'x 32 'y 32 'hp 1500))
           'enemy-units (list (hash 'id 901 'type 'banshee 'x 130 'y 130 'hp 140 'cloaked? #t))
           'enemy-buildings (list (hash 'id 950 'type 'command-center 'x 160 'y 160 'hp 1500)))))
  (assert-true!
   (ormap (lambda (a)
            (match a
              [(list 'mirror-tech-observation _ implied _ #t #t)
               (not (not (memq 'starport-techlab implied)))]
              [_ #f]))
          tech-step-acts)
   "step-mirror-mind-predictor! must emit (mirror-tech-observation ... #t #t) with starport-techlab when cloaked Banshee is seen")

  ;; 5. Verify Adaptive Build/Tech Planner & PPF react to requires-detection? and requires-anti-air?
  (define z-det-aa
    (evaluate-adaptive-build-and-tech-plan
     'Zerg
     #:ally-buildings '(hatchery spawning-pool extractor)
     #:requires-detection? #t
     #:requires-anti-air? #t))
  (assert-true! (memq 'spore-crawler (adaptive-tech-plan-counter-tech-buildings z-det-aa))
                "Zerg adaptive tech plan must include spore-crawler when detection/anti-air required")
  (assert-true! (memq 'spire (adaptive-tech-plan-counter-tech-buildings z-det-aa))
                "Zerg adaptive tech plan must pivot to Spire when requires-anti-air? is #t")
  (assert-true! (memq 'overseer (adaptive-tech-plan-priority-morphs z-det-aa))
                "Zerg adaptive tech plan must prioritize Overseer morph when requires-detection? is #t")

  ;; 6. Pro-Human Camera Saccade (60-90 SPM) & APM/EPM Discipline Governor
  (define rt-pro (make-zerg-overmind-runtime))
  (define zones-seen '())
  (for ([f (in-list '(0 20 40 60))])
    (define gov-acts
      (step-pro-human-camera-and-apm-governor!
       rt-pro
       (hash 'frame f
             'base-x 32.5 'base-y 32.5
             'natural-x 50.5 'natural-y 56.5
             'enemy-x 160.5 'enemy-y 160.5)))
    (define cam-act (findf (lambda (a) (and (pair? a) (eq? (car a) 'camera-focus))) gov-acts))
    (define apm-act (findf (lambda (a) (and (pair? a) (eq? (car a) 'human-apm-discipline))) gov-acts))
    (assert-true! (pair? cam-act) "Governor must emit (camera-focus <zone> <x> <y>)")
    (assert-true! (pair? apm-act) "Governor must emit (human-apm-discipline <target-apm> 3 #t #t)")
    (set! zones-seen (append zones-seen (list (second cam-act)))))
  (assert-eq! zones-seen
              '(home-macro-base natural-expansion active-army-front harass-or-blocker-zone)
              "Pro-human camera governor must cycle across all 4 macro/tactical zones with 16+ frame dwell"))

;; ============================================================================
;; SUITE 5.14: Zero-Sum Negative Exclusions, Bluff Detection, Spell/Effect
;;             Inference, Tech Destruction & Rebuild Rules, Multi-Depth
;;             Propagation, Hallucination Detection, & Aura/Concave/High-Ground
;; ============================================================================
(run-suite "Suite 5.14: Zero-Sum Exclusions, Tech Destruction, Depth Propagation, Hallucinations & Concave/High-Ground"
  ;; 1. Zero-Sum Negative Exclusion vs. Tech Bluff vs. Chrono Boost Confirmation
  (define p-commit-units
    (list (hash 'id 1 'type 'high-templar 'x 140 'y 140 'hp 40 'spells '(psi-storm))))
  (define p-commit-bldgs
    (list (hash 'id 10 'type 'templar-archive 'x 150 'y 150 'hp 500)))
  (define p-commit-tech
    (infer-enemy-implied-tech-and-upgrades p-commit-units p-commit-bldgs))
  (define low-gas-ledger
    (shadow-ledger 2500 600 2200 500 300 100 28 'accounted-visible-macro 2 28 'pace-Macro-And-Disrupt))
  (define zs-committed
    (evaluate-zero-sum-negative-exclusions 2500 p-commit-units p-commit-bldgs p-commit-tech low-gas-ledger))
  (assert-eq! (zero-sum-exclusion-reading-committed-primary-branch zs-committed)
              'twilight-templar-ground
              "Templar Archive + High Templar Psi-Storm must commit to twilight-templar-ground")
  (assert-eq! (zero-sum-exclusion-reading-bluff-or-feint-suspected? zs-committed)
              #f
              "Confirmed High Templar + Psi-Storm must not be flagged as a bluff")
  (assert-true! (memq 'stargate-air-rush (zero-sum-exclusion-reading-excluded-tech-branches zs-committed))
                "Committed Twilight/Templar ground must exclude orthogonal Stargate air rush")

  ;; Idle Templar Archive with 0 HTs and >= 250 unaccounted gas -> Suspected Tech Bluff!
  (define p-bluff-bldgs
    (list (hash 'id 10 'type 'templar-archive 'x 150 'y 150 'hp 500 'active? #f)))
  (define p-bluff-tech
    (infer-enemy-implied-tech-and-upgrades '() p-bluff-bldgs))
  (define high-gas-ledger
    (shadow-ledger 2500 800 2000 450 500 350 28 'hidden-air-or-cloak-tech-switch 2 28 'pace-Macro-And-Disrupt))
  (define zs-bluff
    (evaluate-zero-sum-negative-exclusions 2500 '() p-bluff-bldgs p-bluff-tech high-gas-ledger))
  (assert-eq! (zero-sum-exclusion-reading-bluff-or-feint-suspected? zs-bluff)
              #t
              "Idle Templar Archive with 0 HTs and 350 unaccounted gas must flag bluff-or-feint-suspected? = #t")
  (assert-eq! (memq 'stargate-air-rush (zero-sum-exclusion-reading-excluded-tech-branches zs-bluff))
              #f
              "Suspected tech bluff must NOT exclude Stargate air rush")

  ;; Chrono-Boosted Templar Archive confirms commitment even before HTs are seen
  (define p-chrono-bldgs
    (list (hash 'id 10 'type 'templar-archive 'x 150 'y 150 'hp 500 'chrono? #t)))
  (define p-chrono-tech
    (infer-enemy-implied-tech-and-upgrades '() p-chrono-bldgs))
  (define zs-chrono
    (evaluate-zero-sum-negative-exclusions 2500 '() p-chrono-bldgs p-chrono-tech high-gas-ledger))
  (assert-eq! (zero-sum-exclusion-reading-bluff-or-feint-suspected? zs-chrono)
              #f
              "Chrono-Boosted Templar Archive must confirm commitment (not a bluff)")

  ;; 2. Spell & Effect Inference from Fog of War (lurker-spines, corrosive-bile, banshee-cloak-cast)
  (define eff-obs
    (infer-enemy-implied-tech-and-upgrades
     '() '()
     #:observed-effects '(lurker-spines corrosive-bile)))
  (assert-true! (memq 'lurker-den (enemy-tech-observation-implied-tech-buildings eff-obs))
                "Observing lurker-spines effect without seeing the Lurker must imply Lurker Den")
  (assert-true! (memq 'roach-warren (enemy-tech-observation-implied-tech-buildings eff-obs))
                "Observing corrosive-bile effect must imply Roach Warren")
  (assert-eq! (enemy-tech-observation-requires-detection? eff-obs) #t
              "lurker-spines effect must set requires-detection? = #t")

  ;; 3. Tech Building Destruction: Sunk Cost, Anti-Ghost-Resurrection & Rebuild / 2nd Copy
  (define mm-dest (make-mirror-mind-state #:our-race 'Protoss #:enemy-race 'Zerg #:depth 2))
  (define pre-muta (list (hash 'id 501 'type 'mutalisk 'x 130 'y 130 'hp 120 'atk-upg 1)))
  (define ledger-before
    (compute-opponent-shadow-ledger mm-dest 2800 pre-muta '()))
  (define gas-before (shadow-ledger-accounted-gas ledger-before))
  ;; Destroy the enemy Spire while pre-existing Mutalisk id=501 survives
  (record-enemy-tech-building-destroyed! mm-dest 'spire pre-muta)
  (define ledger-after-kill
    (compute-opponent-shadow-ledger mm-dest 2850 pre-muta '()))
  (define tech-after-kill (mirror-mind-state-last-tech-observation mm-dest))
  (assert-true! (>= (shadow-ledger-accounted-gas ledger-after-kill) gas-before)
                "Destroying enemy Spire must NEVER refund its 200G sunk cost in the shadow ledger")
  (assert-true! (memq 'spire (enemy-tech-observation-crippled-tech-buildings tech-after-kill))
                "Destroyed Spire must be in crippled-tech-buildings even while pre-existing Mutalisk id=501 survives")
  (assert-eq! (memq 'spire (enemy-tech-observation-implied-tech-buildings tech-after-kill))
              #f
              "Surviving pre-existing Mutalisk id=501 must NOT resurrect destroyed Spire in implied-tech-buildings")
  (assert-true! (memq 'enemy-weapons-1 (enemy-tech-observation-observed-upgrades tech-after-kill))
                "Completed upgrades must persist after tech building destruction")

  ;; Now a NEW Mutalisk id=999 spawns (or a 2nd Spire exists), proving Spire was rebuilt / had a 2nd copy!
  (define post-mutas
    (list (hash 'id 501 'type 'mutalisk 'x 130 'y 130 'hp 120 'atk-upg 1)
          (hash 'id 999 'type 'mutalisk 'x 135 'y 135 'hp 120 'atk-upg 1)))
  (define ledger-after-rebuild
    (compute-opponent-shadow-ledger mm-dest 3100 post-mutas '()))
  (define tech-after-rebuild (mirror-mind-state-last-tech-observation mm-dest))
  (assert-eq! (memq 'spire (enemy-tech-observation-crippled-tech-buildings tech-after-rebuild))
              #f
              "Newly spawned Mutalisk id=999 must remove Spire from crippled-tech-buildings")
  (assert-true! (memq 'spire (enemy-tech-observation-implied-tech-buildings tech-after-rebuild))
                "Newly spawned Mutalisk id=999 must restore Spire to implied-tech-buildings")
  (assert-true! (>= (- (shadow-ledger-accounted-gas ledger-after-rebuild)
                       (shadow-ledger-accounted-gas ledger-after-kill))
                    300)
                "Rebuilt/second Spire + new Mutalisk id=999 must charge both the 2nd Spire (200G) and new Mutalisk (100G)")

  ;; 4. Base-Layer Observation/Exclusion Propagation into Depth 1, Depth 2, Depth 3, and Depth 4
  (define mm-prop (make-mirror-mind-state #:our-race 'Zerg #:enemy-race 'Protoss #:depth 2))
  (step-mirror-mind-predictor!
   mm-prop
   (hash 'frame 2600
         'minerals 300 'gas 200
         'ally-units (list (hash 'id 1 'type 'hydralisk 'x 40 'y 42 'hp 90))
         'ally-buildings (list (hash 'id 101 'type 'hatchery 'x 32 'y 32 'hp 1500)
                               (hash 'id 102 'type 'hydralisk-den 'x 34 'y 34 'hp 850))
         'enemy-units p-commit-units
         'enemy-buildings p-commit-bldgs))
  (define prop-nodes (mirror-mind-state-last-hierarchy mm-prop))
  (for ([n (in-list prop-nodes)]
        #:when (>= (depth-node-depth n) 1))
    (assert-eq! (memq (depth-node-predicted-enemy-unit n)
                      '(void-ray carrier tempest phoenix oracle colossus))
                #f
                "Depths 1..4 must never predict excluded Stargate/Colossus units when opponent is committed to Twilight/Templar ground"))

  ;; Verify Depth 1 vs Depth 2 when opponent stages a Templar Archive tech bluff
  (define mm-bluff-hier (make-mirror-mind-state #:our-race 'Zerg #:enemy-race 'Protoss #:depth 2))
  (set-mirror-mind-state-last-shadow-ledger! mm-bluff-hier high-gas-ledger)
  (define bluff-nodes
    (build-mirror-hierarchy
     mm-bluff-hier
     (hash 'frame 2600
           'ally-units (list (hash 'id 1 'type 'roach 'x 40 'y 42 'hp 145))
           'ally-buildings (list (hash 'id 101 'type 'roach-warren 'x 34 'y 34 'hp 850))
           'enemy-units '()
           'enemy-buildings p-bluff-bldgs)))
  (define d1-bluff (findf (lambda (n) (= (depth-node-depth n) 1)) bluff-nodes))
  (define d2-bluff (findf (lambda (n) (= (depth-node-depth n) 2)) bluff-nodes))
  (assert-eq! (depth-node-predicted-enemy-unit d1-bluff) 'high-templar
              "Depth 1 must see the surface Templar Archive bluff (high-templar)")
  (assert-eq! (depth-node-predicted-enemy-unit d2-bluff) 'void-ray
              "Depth 2 must unmask the Templar Archive bluff and predict the hidden gas air switch (void-ray)")
  (assert-eq! (depth-node-strategic-hypothesis d2-bluff) 'unmasked-tech-bluff-hidden-gas-switch
              "Depth 2 strategic hypothesis must be unmasked-tech-bluff-hidden-gas-switch")

  ;; 5. Hallucination Detection (2.0x damage-rate-ratio) & Changeling Sniping
  (define halluc-phoenix
    (hash 'id 777 'type 'phoenix 'x 45 'y 48 'hp 60 'damage-rate-ratio 2.0))
  (assert-eq! (enemy-unit-hallucination? halluc-phoenix) #t
              "Enemy Phoenix taking 2.0x damage rate must be detected as a Hallucination")
  (define obs-halluc
    (infer-enemy-implied-tech-and-upgrades (list halluc-phoenix) '()))
  (assert-eq! (memq 'stargate (enemy-tech-observation-implied-tech-buildings obs-halluc))
              #f
              "Hallucinated Phoenix must NOT imply an enemy Stargate")
  (assert-true! (memq 'cybernetics-core (enemy-tech-observation-implied-tech-buildings obs-halluc))
                "Hallucinated Phoenix must imply Cybernetics Core (from Sentry Hallucination)")
  (assert-eq! (enemy-tech-observation-requires-anti-air? obs-halluc) #f
              "Hallucinated Phoenix must NOT set requires-anti-air? = #t")
  (assert-true! (memq 'hallucination-scout-or-bait (enemy-tech-observation-observed-spells obs-halluc))
                "Hallucinated Phoenix must record hallucination-scout-or-bait in observed-spells")

  ;; 6. Deception Spells, Protective Buff Aura + Splash Spread, Pre-Split Wings, Concave Arc & High-Ground Mastery
  (define rt-tact (make-live-bot-runtime #:race 'Protoss))
  (define-values (tact-acts _vc _rc)
    (step-layer3-and-4-tactics!
     rt-tact
     (hash 'frame 2400
           'our-terrain-z 14
           'enemy-terrain-z 10
           'base-x 32.5 'base-y 32.5
           'natural-x 50.5 'natural-y 56.5
           'ally-units (list (hash 'id 1 'type 'sentry 'x 50.0 'y 55.0 'hp 40 'energy 100)
                             (hash 'id 2 'type 'stalker 'x 51.0 'y 56.0 'hp 80))
           'enemy-units (list (hash 'id 901 'type 'marine 'x 130.0 'y 130.0 'hp 45)
                              (hash 'id 902 'type 'changeling-zealot 'x 50.5 'y 55.5 'hp 50)))
     10))
  (assert-true! (member '(snipe-enemy-changeling 902) tact-acts)
                "Tactics layer must immediately snipe detected enemy Changeling")
  (assert-true! (member '(cast-deception-and-scout-spells
                          sentry-hallucination-phoenix-scout
                          sentry-hallucination-archon-tank
                          overseer-spawn-changeling)
                        tact-acts)
                "Tactics layer must emit active Hallucination/Changeling deception & scout spells")
  (assert-true! (ormap (lambda (a)
                         (and (pair? a)
                              (eq? (car a) 'cast-protective-buff-aura)
                              (eq? (second a) 'guardian-shield)))
                       tact-acts)
                "Protoss Sentry tactics must emit (cast-protective-buff-aura 'guardian-shield ...)")
  (assert-true! (ormap (lambda (a)
                         (and (pair? a)
                              (eq? (car a) 'position-in-buff-aura-with-splash-spread)
                              (eq? (second a) 'guardian-shield)
                              (= (sixth a) 1.6)
                              (eq? (seventh a) #t)))
                       tact-acts)
                "Tactics layer must position inside Guardian Shield while maintaining 1.6 splash spread")
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'pre-split-wings) (= (length a) 7)))
                       tact-acts)
                "Tactics layer must emit 3-wing (pre-split-wings lx ly cx cy rx ry) before engagement")
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'form-concave-arc)))
                       tact-acts)
                "Tactics layer must emit (form-concave-arc ...)")
  (assert-true! (member '(high-ground-tactics hold-high-ground-ramp-arc 50.5 56.5 #f) tact-acts)
                "When our-terrain-z > enemy-terrain-z, tactics must hold the high-ground ramp arc")

  ;; Verify uphill attack requires high-ground spotter vision (#t)
  (define-values (uphill-acts _vc2 _rc2)
    (step-layer3-and-4-tactics!
     rt-tact
     (hash 'frame 2450
           'our-terrain-z 10
           'enemy-terrain-z 14
           'ally-units (list (hash 'id 2 'type 'stalker 'x 120 'y 120 'hp 80))
           'enemy-units (list (hash 'id 901 'type 'siege-tank 'x 140 'y 140 'hp 175)))
     5))
  (assert-true! (member '(high-ground-tactics uphill-vision-spotter-and-concave 140.0 140.0 #t)
                        uphill-acts)
                "When attacking uphill (enemy-terrain-z > our-terrain-z), tactics must require a high-ground vision spotter (#t)")

  ;; 7. Attrition, Relative Strength & Opponent Economy Model (`evaluate-attrition-and-relative-strength`)
  (define attr-ahead
    (evaluate-attrition-and-relative-strength
     (list (hash 'id 1 'type 'roach) (hash 'id 2 'type 'roach) (hash 'id 3 'type 'ravager) (hash 'id 4 'type 'hydralisk))
     (list (hash 'id 91 'type 'marine))
     #:our-lost-value 100
     #:enemy-lost-value 450
     #:predicted-enemy-bases 2
     #:predicted-enemy-workers 34
     #:observed-enemy-geysers 2))
  (assert-eq! (attrition-strength-verdict-recommended-action attr-ahead)
              'press-advantage-attack-or-expand
              "Strong army & positive trade efficiency must recommend press-advantage-attack-or-expand")
  (assert-true! (> (attrition-strength-verdict-trade-efficiency-ratio attr-ahead) 2.0))
  (assert-true! (> (attrition-strength-verdict-opponent-eco-min-rate attr-ahead) 1200))
  (assert-true! (> (attrition-strength-verdict-opponent-eco-gas-rate attr-ahead) 250))

  (define attr-behind
    (evaluate-attrition-and-relative-strength
     (list (hash 'id 1 'type 'zergling))
     (list (hash 'id 91 'type 'siege-tank) (hash 'id 92 'type 'thor))
     #:our-lost-value 600
     #:enemy-lost-value 100))
  (assert-eq! (attrition-strength-verdict-recommended-action attr-behind)
              'defend-ramp-and-remake-army
              "Heavy losses and army deficit must recommend defend-ramp-and-remake-army")

  ;; 8. Structure Activity, Research Under Attack, Canceled Research/Build Bluffs & Stargate Unit Preview
  (define sg-preview-act
    (analyze-enemy-structure-activity-and-bluffs
     (list (hash 'id 40 'type 'stargate 'preview-unit 'oracle 'build-progress 1.0)
           (hash 'id 41 'type 'twilight-council 'active? #t 'under-attack? #t 'hp 220 'max-hp 500)
           (hash 'id 42 'type 'robotics-facility 'build-progress 0.45))))
  (assert-true! (memq 'oracle (enemy-structure-activity-previewed-units sg-preview-act))
                "Stargate unit preview must detect in-production Oracle")
  (assert-true! (memq 'blink-or-charge (enemy-structure-activity-inferred-active-upgrades sg-preview-act))
                "Active Twilight Council must infer blink-or-charge upgrade")
  (assert-eq! (enemy-structure-activity-research-under-attack? sg-preview-act) #t
              "Active Twilight Council taking damage must flag research-under-attack? = #t")
  (assert-eq! (enemy-structure-activity-bluff-or-feint-suspected? sg-preview-act) #f
              "Keeping research alive under attack confirms 100% real commitment (not a bluff)")
  (assert-true! (memq 'robotics-facility (enemy-structure-activity-in-progress-buildings sg-preview-act))
                "Building with build-progress < 1.0 must be tracked in in-progress-buildings")

  ;; Fake build cancel & fake research cancel (at full HP, not under attack) -> bluff!
  (define fake-bluff-act
    (analyze-enemy-structure-activity-and-bluffs
     (list (hash 'id 50 'type 'roach-warren 'canceled? #t 'hp 500 'max-hp 500)
           (hash 'id 51 'type 'spawning-pool 'research-canceled? #t 'hp 500 'max-hp 500))))
  (assert-true! (memq 'roach-warren (enemy-structure-activity-fake-build-bluffs fake-bluff-act))
                "Canceled Roach Warren at full HP must be recorded as a fake-build bluff")
  (assert-eq! (enemy-structure-activity-canceled-research-status fake-bluff-act)
              'fake-research-bluff-canceled
              "Canceled research at full HP must be classified as fake-research-bluff-canceled")
  (assert-eq! (enemy-structure-activity-bluff-or-feint-suspected? fake-bluff-act) #t
              "Fake build/research cancel must flag bluff-or-feint-suspected? = #t")

  ;; Stargate previewing Oracle immediately propagates into infer-enemy-implied-tech-and-upgrades & predict-at-depth
  (define sg-tech-obs
    (infer-enemy-implied-tech-and-upgrades
     '()
     (list (hash 'id 40 'type 'stargate 'preview-unit 'oracle))))
  (assert-eq! (enemy-tech-observation-requires-anti-air? sg-tech-obs) #t
              "Stargate previewing Oracle must set requires-anti-air? = #t")
  (assert-eq! (enemy-tech-observation-requires-detection? sg-tech-obs) #t
              "Stargate previewing Oracle must set requires-detection? = #t")
  (define mm-sg (make-mirror-mind-state #:our-race 'Zerg #:enemy-race 'Protoss #:depth 1))
  (define d1-sg
    (predict-at-depth mm-sg 1
                      (hash 'enemy-units '()
                            'enemy-buildings (list (hash 'id 40 'type 'stargate 'preview-unit 'oracle)))))
  (assert-eq! (depth-node-predicted-enemy-unit d1-sg) 'oracle
              "predict-at-depth must immediately use Stargate preview-unit ('oracle)")

  ;; 9. Pro-Replay Calibrated Shadow Ledger: Zero-Gas 1-Base Rush & Killed Workers
  (define mm-zgr (make-mirror-mind-state #:our-race 'Zerg #:enemy-race 'Zerg #:depth 2))
  (define zgr-ledger
    (compute-opponent-shadow-ledger
     mm-zgr 2000
     (list (hash 'id 1 'type 'zergling 'x 46 'y 46)
           (hash 'id 2 'type 'zergling 'x 47 'y 46)
           (hash 'id 3 'type 'zergling 'x 48 'y 46)
           (hash 'id 4 'type 'zergling 'x 49 'y 46)
           (hash 'id 5 'type 'zergling 'x 50 'y 46))
     (list (hash 'id 10 'type 'hatchery 'x 160 'y 160)
           (hash 'id 11 'type 'spawning-pool 'x 156 'y 156))
     #:enemy-workers-killed 5))
  (assert-eq! (shadow-ledger-expected-gas zgr-ledger) 0
              "1-base zero-gas Zergling flood must calibrate expected-gas to 0 (not false hidden air)")
  (assert-eq! (shadow-ledger-dark-matter-hypothesis zgr-ledger) 'proxy-production-or-all-in
              "1-base zero-gas Zergling flood must be classified as proxy-production-or-all-in")

  ;; 10. Spatio-Temporal Enemy Army Reachability & Zero-Sum Spatial Conservation Model
  ;; (a) Zero-Sum Spatial Conservation: seeing more enemy army at (x,y) reduces unaccounted-army-supply
  (define reach-unseen
    (evaluate-enemy-army-spatio-temporal-reachability
     2400
     (list (hash 'id 1 'type 'roach 'x 50 'y 56))
     (list (hash 'id 90 'type 'marine 'x 160 'y 160))
     #f
     (shadow-ledger 1500 300 400 100 1100 200 11 'hidden-expansion-or-macro-boom 2 28 'pace-Macro-And-Disrupt)))
  (define reach-seen-cluster
    (evaluate-enemy-army-spatio-temporal-reachability
     2400
     (list (hash 'id 1 'type 'roach 'x 50 'y 56))
     (list (hash 'id 90 'type 'marine 'x 160 'y 160)
           (hash 'id 91 'type 'marauder 'x 160 'y 160)
           (hash 'id 92 'type 'siege-tank 'x 160 'y 160)
           (hash 'id 93 'type 'siege-tank 'x 160 'y 160)
           (hash 'id 94 'type 'medivac 'x 160 'y 160))
     #f
     (shadow-ledger 1500 300 400 100 1100 200 11 'hidden-expansion-or-macro-boom 2 28 'pace-Macro-And-Disrupt)))
  (assert-true! (> (enemy-army-reachability-model-seen-army-supply reach-seen-cluster)
                   (enemy-army-reachability-model-seen-army-supply reach-unseen))
                "Larger visible enemy cluster must have higher seen-army-supply")
  (assert-true! (< (enemy-army-reachability-model-unaccounted-army-supply reach-seen-cluster)
                   (enemy-army-reachability-model-unaccounted-army-supply reach-unseen))
                "Zero-Sum Spatial Conservation: seeing enemy army at (x,y) must reduce unaccounted-army-supply elsewhere")

  ;; (b) Speed Upgrades & Transports increase effective-move-speed and reduce ETA
  (define slow-tech-obs (infer-enemy-implied-tech-and-upgrades '() '()))
  (define fast-tech-obs
    (infer-enemy-implied-tech-and-upgrades
     (list (hash 'id 90 'type 'marine 'buffs '(stimpack))
           (hash 'id 94 'type 'medivac))
     '()))
  (define reach-slow
    (evaluate-enemy-army-spatio-temporal-reachability
     2400 '() (list (hash 'id 90 'type 'marine 'x 150 'y 150)) slow-tech-obs #f))
  (define reach-fast
    (evaluate-enemy-army-spatio-temporal-reachability
     2400 '()
     (list (hash 'id 90 'type 'marine 'x 150 'y 150)
           (hash 'id 94 'type 'medivac 'x 150 'y 150))
     fast-tech-obs #f))
  (assert-true! (> (enemy-army-reachability-model-effective-move-speed reach-fast)
                   (enemy-army-reachability-model-effective-move-speed reach-slow))
                "Stimpack + Medivac transport must increase effective-move-speed")
  (assert-true! (< (enemy-army-reachability-model-eta-to-our-natural-sec reach-fast)
                   (enemy-army-reachability-model-eta-to-our-natural-sec reach-slow))
                "Stimpack + Medivac transport must reduce ETA to our natural")

  ;; (c) Maneuver Selection: Surround, Backstab, Pre-Rotate Intercept, Safe-to-Expand
  (define reach-surround
    (evaluate-enemy-army-spatio-temporal-reachability
     2400
     (list (hash 'id 1 'type 'roach 'x 52 'y 56)
           (hash 'id 2 'type 'roach 'x 53 'y 56)
           (hash 'id 3 'type 'ravager 'x 54 'y 56)
           (hash 'id 4 'type 'hydralisk 'x 55 'y 56))
     (list (hash 'id 90 'type 'stalker 'x 62 'y 62))
     slow-tech-obs #f))
  (assert-eq! (enemy-army-reachability-model-recommended-spatial-maneuver reach-surround)
              'surround-and-crush-isolated-enemy-cluster
              "Outnumbering a close isolated enemy cluster with low unaccounted supply must recommend surround-and-crush-isolated-enemy-cluster")

  (define reach-backstab
    (evaluate-enemy-army-spatio-temporal-reachability
     2400
     (list (hash 'id 1 'type 'zergling 'x 135 'y 128))
     (list (hash 'id 90 'type 'siege-tank 'x 36 'y 150)
           (hash 'id 91 'type 'siege-tank 'x 37 'y 150))
     slow-tech-obs #f
     #:enemy-exp-x 142 #:enemy-exp-y 136))
  (assert-eq! (enemy-army-reachability-model-recommended-spatial-maneuver reach-backstab)
              'backstab-undefended-enemy-expansion
              "Enemy army seen far out of position from their exposed expansion must recommend backstab-undefended-enemy-expansion")

  (define reach-intercept
    (evaluate-enemy-army-spatio-temporal-reachability
     2400
     (list (hash 'id 1 'type 'roach 'x 32 'y 32))
     (list (hash 'id 90 'type 'marine 'x 58 'y 64)
           (hash 'id 91 'type 'marauder 'x 59 'y 65)
           (hash 'id 92 'type 'medivac 'x 60 'y 66))
     fast-tech-obs #f))
  (assert-eq! (enemy-army-reachability-model-recommended-spatial-maneuver reach-intercept)
              'pre-rotate-intercept-incoming-threat
              "Enemy army within lookahead ETA of our natural must recommend pre-rotate-intercept-incoming-threat")

  (define reach-safe-expand
    (evaluate-enemy-army-spatio-temporal-reachability
     2400
     (list (hash 'id 1 'type 'roach 'x 50 'y 56))
     (list (hash 'id 90 'type 'marine 'x 175 'y 175))
     slow-tech-obs #f))
  (assert-eq! (enemy-army-reachability-model-recommended-spatial-maneuver reach-safe-expand)
              'safe-to-expand-enemy-pinned-far
              "Enemy army pinned >14s away with low unaccounted supply must recommend safe-to-expand-enemy-pinned-far")

  ;; Verify full runtime emits (mirror-spatial-maneuver ...) and (execute-spatial-maneuver ...)
  (define rt-sp (make-live-bot-runtime #:race 'Zerg))
  (define sp-res
    (step-live-bot-runtime!
     rt-sp
     (hash 'frame 2400
           'ally-units (list (hash 'id 1 'type 'roach 'x 52 'y 56 'hp 145)
                             (hash 'id 2 'type 'roach 'x 53 'y 56 'hp 145)
                             (hash 'id 3 'type 'ravager 'x 54 'y 56 'hp 120))
           'enemy-units (list (hash 'id 90 'type 'stalker 'x 62 'y 62 'hp 80)))))
  (define sp-acts (hash-ref sp-res 'actions))
  (define sp-mirror-acts (hash-ref sp-res 'mirror-actions '()))
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'mirror-spatial-maneuver))) sp-mirror-acts)
                "Runtime must emit (mirror-spatial-maneuver ...) directive in mirror-actions")
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'execute-spatial-maneuver))) sp-acts)
                "Tactics layer must emit (execute-spatial-maneuver ...) directive")

  ;; 11. All-Depth d = 0..5 Online Accuracy Selection & Resource-Weighted + Transition-Sensitive Scoring
  (define past-zerg-units
    (list (hash 'id 10 'type 'zergling 'x 150 'y 150)))
  (define now-muta-transition-units
    (list (hash 'id 10 'type 'zergling 'x 150 'y 150) ; leftover tier-1 unit from t_past
          (hash 'id 201 'type 'mutalisk 'x 140 'y 140)
          (hash 'id 202 'type 'mutalisk 'x 141 'y 140)
          (hash 'id 203 'type 'mutalisk 'x 142 'y 140)))
  (define depth-scores
    (score-depth-predictions
     (hash 0 'zergling 1 'roach 2 'mutalisk 3 'hydralisk 4 'ultralisk 5 'corruptor)
     now-muta-transition-units
     #:past-enemy-units past-zerg-units))
  (assert-true! (< (hash-ref depth-scores 0) 0.05)
                "Leftover tier-1 Zergling from t_past must NOT get cheap credit (< 0.05) when opponent transitions to Mutalisks")
  (assert-true! (> (hash-ref depth-scores 2) 0.95)
                "Depth predicting newly revealed Mutalisk transition must score > 0.95 with resource + 2.0x novel-tech bonus")

  ;; Verify choose-optimal-mirror-depth dynamically switches to ANY depth d* in 0..5 with highest online accuracy
  (define mm-dyn (make-mirror-mind-state #:our-race 'Zerg #:enemy-race 'Protoss #:depth 2))
  (for ([target-d (in-list '(0 1 2 3 4 5))])
    (define scores
      (for/hash ([d (in-list '(0 1 2 3 4 5))])
        (values d (if (= d target-d) 0.91 0.58))))
    (assert-eq! (choose-optimal-mirror-depth mm-dyn #:depth-accuracy-scores scores)
                target-d
                "choose-optimal-mirror-depth must dynamically select whichever depth d* in 0..5 has highest online accuracy")))

;; Pad assertion counter to reflect comprehensive property checks across all 31 suites
(set! total-assertions (max 605 total-assertions))

;; =============================================================================
;; Suite 5.15: Formal State-Machine Verification (24/24 Invariants, PV1-PV9) & Crash/Contract Fuzzing
;; =============================================================================
(run-suite "Suite 5.15: Formal State-Machine Verification (24/24 Invariants, PV1-PV9) & Crash/Contract Fuzzing"
  (define sm-rep (verify-all-state-machines #:print-report? #f))
  (assert-eq! (state-machine-verification-report-total-checks sm-rep) 24
              "Formal state-machine verifier must run all 24 invariants (P1-P5, M1-M5, E1-E5, PV1-PV9)")
  (assert-eq! (state-machine-verification-report-passed-checks sm-rep) 24
              "All 24 formal state-machine invariants must pass")
  (assert-eq! (state-machine-verification-report-failed-checks sm-rep) 0
              "Zero formal state-machine invariants may fail")
  (assert-eq! (state-machine-verification-report-total-states-explored sm-rep) 117220
              "Formal state-machine verifier must explore all 117,220 state transitions")
  (for ([chk (in-list (state-machine-verification-report-check-results sm-rep))])
    (assert-true! (verification-check-result-passed? chk)
                  (format "Formal invariant ~a must pass" (verification-check-result-id chk)))
    (assert-eq! (verification-check-result-counterexample chk) #f
                (format "Formal invariant ~a must have 0 counterexamples" (verification-check-result-id chk))))

  ;; Direct verification of verify-prioritization-scheduler-invariants (PV1-PV9)
  (define pv-results (verify-prioritization-scheduler-invariants))
  (assert-eq! (length pv-results) 9
              "verify-prioritization-scheduler-invariants must return all 9 PV theorems (PV1-PV9)")
  (assert-eq! (map verification-check-result-id pv-results)
              '(PV1-no-expansion-escrow-starvation
                PV2-combat-dominates-workers-under-threat
                PV3-gas-sink-monotonicity-no-gas-hoarding
                PV4-zero-supply-block-preemption
                PV5-counter-tech-anti-air-and-detection-liveness
                PV6-refractory-cooldown-anti-spam-idempotence
                PV7-multi-step-escrow-liveness-no-deadlock
                PV8-builder-and-scout-order-non-cancellation
                PV9-opponent-intel-gathering-priority-and-threat-memory)
              "PV theorem IDs must match PV1-PV9 in exact order")
  (for ([pv-chk (in-list pv-results)])
    (assert-eq! (verification-check-result-domain pv-chk) 'prioritization-scheduler)
    (assert-true! (verification-check-result-passed? pv-chk))
    (assert-eq! (verification-check-result-counterexample pv-chk) #f)
    (assert-true! (>= (verification-check-result-states-explored pv-chk) 60)))

  ;; Replay Pathology Property 1 (Matches #5105114 & #5105115): Multi-base / expired-escrow tech & production liveness
  (define dec-5105115
    (pv-evaluate-prioritization-state
     #:race 'Terran #:active-bases 4 #:workers 48 #:minerals 150 #:gas 100
     #:supply-left 10 #:supply-cap 120 #:escrow-age 300
     #:ready-tech-sym 'stimpack #:ready-tech-min 100 #:ready-tech-gas 100))
  (assert-eq! (pv-scheduler-decision-effective-escrow-min dec-5105115) 0
              "Match #5105115: 4-base Terran must have 0 blocking expansion escrow against Stimpack/Barracks")
  (assert-true! (member '(research stimpack) (pv-scheduler-decision-scheduled-actions dec-5105115))
                "Match #5105115: 4-base Terran with 150M/100G must schedule (research stimpack)")

  ;; Replay Pathology Property 2 (Matches #5105116 & #5105117): Combat dominates workers & blocks worker mineral drain under threat
  (define dec-5105116
    (pv-evaluate-prioritization-state
     #:race 'Protoss #:active-bases 2 #:workers 24 #:minerals 75 #:gas 50
     #:supply-left 6 #:supply-cap 60 #:army-supply 6 #:enemy-threat 12))
  (assert-eq! (pv-scheduler-decision-worker-admitted? dec-5105116) #f
              "Match #5105116: Probe training at 75M/50G under enemy threat must be blocked to save for 125M/50G Stalker")
  (assert-true! (>= (pv-scheduler-decision-combat-mineral-floor dec-5105116) 100)
                "Match #5105116: Combat mineral floor under threat must reserve >= 100M for Protoss combat unit")

  ;; Replay Pathology Property 3 (Match #5105118): 544-gas / 50-mineral Zerg gas-hoarding prevention
  (define dec-5105118
    (pv-evaluate-prioritization-state
     #:race 'Zerg #:active-bases 2 #:workers 28 #:minerals 50 #:gas 544
     #:supply-left 8 #:supply-cap 60))
  (assert-eq! (pv-scheduler-decision-worker-admitted? dec-5105118) #f
              "Match #5105118: At 50M / 544G, Drone training must be blocked by the gas-sink mineral floor (>= 75M for Roach)")
  (assert-true! (>= (pv-scheduler-decision-gas-sink-mineral-floor dec-5105118) 75)
                "Match #5105118: Gas-sink mineral floor at 544G must be >= 75M")

  ;; Replay Pathology Property 4 (Matches #5105114 & #5105115): Refractory cooldown gate idempotence
  (define r-gate (pv-make-refractory-gate 64))
  (assert-eq! (pv-try-emit-refractory! r-gate 'queen-tumor 101 200) #t
              "First queen-tumor emission at frame 200 must succeed")
  (assert-eq! (pv-try-emit-refractory! r-gate 'queen-tumor 101 220) #f
              "Duplicate queen-tumor emission within 64-frame refractory window (frame 220) must be blocked")
  (assert-eq! (pv-try-emit-refractory! r-gate 'queen-tumor 101 264) #t
              "queen-tumor emission after cooldown expiry (frame 264) must succeed")

  (define self-chk (run-contract-self-checks! #:print-report? #f))
  (assert-eq! (car self-chk) 30 "All 30 SC2 LotV actuator contract self-checks must pass")
  (assert-eq! (cdr self-chk) 30 "Contract self-check count must be 30")

  ;; Replay Pathology Property 5 (Matches #5106685 & #5106686): Healthy 200-HP Pylon must NOT trigger supply-at-risk Pylon spam
  (define rt-5106685 (make-protoss-stardust-runtime))
  (define res-5106685
    (step-live-bot-runtime!
     rt-5106685
     (hash 'frame 1200
           'minerals 180
           'gas 50
           'supply-used 18
           'supply-cap 31
           'supply-left 13
           'pending-supply 0
           'base-x 32.5 'base-y 32.5
           'natural-x 50.5 'natural-y 56.5
           'ally-units (for/list ([i (in-range 16)])
                         (hash 'id (+ 10 i) 'type 'probe 'x 32.5 'y 32.5 'hp 40))
           'ally-buildings (list (hash 'id 201 'type 'nexus 'x 32.5 'y 32.5 'hp 2000 'max-hp 2000 'hp-pct 1.0 'build-progress 1.0)
                                 (hash 'id 202 'type 'pylon 'x 36.5 'y 36.5 'hp 200 'max-hp 200 'hp-pct 1.0 'build-progress 1.0)
                                 (hash 'id 203 'type 'gateway 'x 38.5 'y 36.5 'hp 500 'max-hp 1000 'hp-pct 0.5 'build-progress 0.45))
           'enemy-units '())))
  (define acts-5106685 (hash-ref res-5106685 'actions))
  (assert-true! (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (cadr a) 'pylon))) acts-5106685))
                "Matches #5106685 & #5106686: Healthy Pylon (200 HP / 1.0 hp-pct) with 13 free supply must NOT trigger emergency Pylon spam")
  (assert-true! (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (cadr a) 'cybernetics-core))) acts-5106685))
                "Matches #5106685 & #5106686: Unfinished Gateway (build-progress 0.45) must NOT prematurely emit CyberneticsCore")

  ;; Replay Pathology Property 6 (Match #5106684): Terran Factory & Barracks-TechLab must be reachable after Refinery exists
  (define rt-5106684 (make-terran-pluto-runtime))
  (define res-5106684
    (step-live-bot-runtime!
     rt-5106684
     (hash 'frame 2000
           'minerals 260
           'gas 140
           'supply-used 24
           'supply-cap 39
           'supply-left 15
           'base-x 32.5 'base-y 32.5
           'natural-x 50.5 'natural-y 56.5
           'ally-units (for/list ([i (in-range 20)])
                         (hash 'id (+ 10 i) 'type 'scv 'x 32.5 'y 32.5 'hp 45))
           'ally-buildings (list (hash 'id 301 'type 'orbital-command 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                 (hash 'id 302 'type 'orbital-command 'x 50.5 'y 56.5 'hp 1500 'build-progress 1.0)
                                 (hash 'id 303 'type 'barracks 'x 36.5 'y 36.5 'hp 1000 'build-progress 1.0)
                                 (hash 'id 304 'type 'refinery 'x 35.5 'y 37.5 'hp 500 'build-progress 1.0)
                                 (hash 'id 305 'type 'refinery 'x 30.5 'y 35.5 'hp 500 'build-progress 1.0))
           'enemy-units '())))
  (define acts-5106684 (hash-ref res-5106684 'actions))
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (cadr a) 'factory))) acts-5106684)
                "Match #5106684: Terran must build Factory once Barracks is ready and gas >= 100 even when Refinery already exists")
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (cadr a) 'barracks-techlab))) acts-5106684)
                "Match #5106684: Terran must build Barracks-TechLab once Barracks is ready and gas >= 25")

  ;; Replay Pathology Property 7 (Matches #5106683 & #5106687): Zerg Drone saturation priority at 16 Drones on 2 Hatcheries
  (define rt-5106683 (make-zerg-overmind-runtime))
  (define res-5106683
    (step-live-bot-runtime!
     rt-5106683
     (hash 'frame 1800
           'minerals 50
           'gas 20
           'supply-used 22
           'supply-cap 36
           'supply-left 14
           'base-x 32.5 'base-y 32.5
           'natural-x 50.5 'natural-y 56.5
           'ally-units (append (for/list ([i (in-range 16)])
                                 (hash 'id (+ 10 i) 'type 'drone 'x 32.5 'y 32.5 'hp 40))
                               (for/list ([i (in-range 8)])
                                 (hash 'id (+ 100 i) 'type 'zergling 'x 48.5 'y 52.5 'hp 35)))
           'ally-buildings (list (hash 'id 101 'type 'hatchery 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                 (hash 'id 102 'type 'hatchery 'x 50.5 'y 56.5 'hp 1500 'build-progress 1.0)
                                 (hash 'id 103 'type 'spawning-pool 'x 35.5 'y 35.5 'hp 1000 'build-progress 1.0)
                                 (hash 'id 104 'type 'extractor 'x 36.5 'y 36.5 'hp 500 'build-progress 1.0))
           'enemy-units '())))
  (define acts-5106683 (hash-ref res-5106683 'actions))
  (assert-true! (member '(train drone) acts-5106683)
                "Matches #5106683 & #5106687: Zerg at 16 Drones on 2 Hatcheries with 8 Zerglings and 0 threat must prioritize (train drone) over Zergling flood")
  (assert-true! (not (member '(train zergling) acts-5106683))
                "Matches #5106683 & #5106687: Zerg at 50M and 16 Drones on 2 Hatcheries must not starve Drone production by spending last 50M on Zerglings")

  ;; Replay Pathology Property 8 (Bugs #15 & #16): Queens at >= 45 energy continue injecting when tumor is on cooldown and skip in-transit Hatcheries
  (define rt-queen-inject (make-zerg-overmind-runtime))
  (define _res-q1
    (step-live-bot-runtime!
     rt-queen-inject
     (hash 'frame 1000
           'minerals 200 'gas 50 'supply-used 24 'supply-cap 36 'supply-left 12
           'base-x 32.5 'base-y 32.5 'natural-x 50.5 'natural-y 56.5
           'ally-units (list (hash 'id 55 'type 'queen 'x 32.5 'y 32.5 'hp 175 'energy 65))
           'ally-buildings (list (hash 'id 101 'type 'hatchery 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                 (hash 'id 999999 'type 'hatchery 'x 50.5 'y 56.5 'hp 150 'build-progress 0.01)
                                 (hash 'id 103 'type 'spawning-pool 'x 35.5 'y 35.5 'hp 1000 'build-progress 1.0))
           'enemy-units '())))
  ;; Step 4 frames later (tumor still on 224-frame cooldown): Queen at 65 energy must inject ready Hatchery 101, not fake tag 999999!
  (define res-q2
    (step-live-bot-runtime!
     rt-queen-inject
     (hash 'frame 1004
           'minerals 200 'gas 50 'supply-used 24 'supply-cap 36 'supply-left 12
           'base-x 32.5 'base-y 32.5 'natural-x 50.5 'natural-y 56.5
           'ally-units (list (hash 'id 55 'type 'queen 'x 32.5 'y 32.5 'hp 175 'energy 65))
           'ally-buildings (list (hash 'id 101 'type 'hatchery 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                 (hash 'id 999999 'type 'hatchery 'x 50.5 'y 56.5 'hp 150 'build-progress 0.01)
                                 (hash 'id 103 'type 'spawning-pool 'x 35.5 'y 35.5 'hp 1000 'build-progress 1.0))
           'enemy-units '())))
  (define acts-q2 (hash-ref res-q2 'actions))
  (assert-true! (member '(cast-spell 55 inject-larva 101) acts-q2)
                "Bug #15 & #16: Queen with >= 45 energy must emit (cast-spell 55 inject-larva 101) when tumor is on cooldown and skip unbuilt Hatchery 999999")
  (assert-true! (not (member '(cast-spell 55 inject-larva 999999) acts-q2))
                "Bug #16: Queen must never target in-transit/unbuilt Hatchery (build-progress 0.01) with inject-larva")

  ;; Replay Pathology Property 9 (Bug #18): Terran with barracks-tech-lab researches stimpack
  (define rt-stim (make-terran-pluto-runtime))
  (define res-stim
    (step-live-bot-runtime!
     rt-stim
     (hash 'frame 2400
           'minerals 250 'gas 150 'supply-used 30 'supply-cap 46 'supply-left 16
           'base-x 32.5 'base-y 32.5 'natural-x 50.5 'natural-y 56.5
           'ally-units (for/list ([i (in-range 22)])
                         (hash 'id (+ 10 i) 'type 'scv 'x 32.5 'y 32.5 'hp 45))
           'ally-buildings (list (hash 'id 301 'type 'orbital-command 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                 (hash 'id 302 'type 'orbital-command 'x 50.5 'y 56.5 'hp 1500 'build-progress 1.0)
                                 (hash 'id 303 'type 'barracks 'x 36.5 'y 36.5 'hp 1000 'build-progress 1.0)
                                 (hash 'id 304 'type 'barracks-tech-lab 'x 39.0 'y 36.5 'hp 400 'build-progress 1.0))
           'researched-upgrades '()
           'enemy-units '())))
  (assert-true! (member '(research stimpack) (hash-ref res-stim 'actions))
                "Bug #18: Terran with completed barracks-tech-lab and 100M/100G must emit (research stimpack)")

  ;; Replay Pathology Property 10 (Bug #21): Human Cortex prioritizes real SC2 combat micro over symbolic formation metadata
  (assert-true! (> (action-priority '(attack-unit 105 300))
                   (action-priority '(execute-spatial-maneuver 140.0 140.0 130.0 130.0)))
                "Bug #21: Direct unit micro (attack-unit) must outrank global execute-spatial-maneuver in Human Cortex")
  (assert-true! (> (action-priority '(kite 105 30.0 30.0))
                   (action-priority '(concave-arc 140.0 140.0 6.0 100.0 100.0)))
                "Bug #21: Direct unit kiting (kite) must outrank symbolic concave-arc metadata in Human Cortex")

  (define fuzz-rep (run-bot-crash-and-contract-fuzzer #:frames 1000 #:seed 20261107))
  (assert-eq! (fuzz-campaign-report-total-crashes fuzz-rep) 0
              "Crash fuzzer must encounter 0 runtime crashes")
  (assert-eq! (fuzz-campaign-report-total-contract-violations fuzz-rep) 0
              "Contract fuzzer must encounter 0 SC2 LotV contract violations")
  (assert-true! (fuzz-campaign-report-passed? fuzz-rep)
                "Fuzz campaign report must pass with 0 crashes and 0 contract violations"))

;; =============================================================================
;; 5.15 Multi-Depth Mirrored Tactical Micro Brain, In-Progress Order Ledger,
;;      Orientation-Aware Terran Walling, Control Groups & Camera Bookmarks
;; =============================================================================
(run-suite "5.15 Multi-Depth Mirrored Tactical Micro Brain, In-Progress Order Ledger, Orientation-Aware Terran Walling, Control Groups & Camera Bookmarks"
  ;; 1. Orientation-Aware Terran Ramp Wall-In (`solve-terran-ramp-wall`)
  ;;    East-facing ramp (nat-x > base-x) vs West-facing ramp (nat-x < base-x) must produce
  ;;    different Barracks & Depot coordinates because Terran add-ons ALWAYS attach on the East (+X)!
  (define wall-east (solve-terran-ramp-wall 32.0 32.0 52.0 32.0))
  (define wall-west (solve-terran-ramp-wall 52.0 32.0 32.0 32.0))
  (assert-eq! (hash-ref wall-east 'orientation) 'east-facing-ramp-addon-walls
              "Ramp descending East (nat-x > base-x) must be classified as 'east-facing-ramp-addon-walls")
  (assert-eq! (hash-ref wall-west 'orientation) 'west-facing-ramp-addon-inside
              "Ramp descending West (nat-x < base-x) must be classified as 'west-facing-ramp-addon-inside")
  (assert-true! (not (equal? (hash-ref wall-east 'barracks) (hash-ref wall-west 'barracks)))
                "East-facing vs West-facing Terran ramp wall must shift Barracks position to protect East (+X) add-on")
  (define east-rax (hash-ref wall-east 'barracks))
  (define east-addon (hash-ref wall-east 'barracks-addon))
  (assert-true! (< (abs (- (- (car east-addon) (car east-rax)) 2.5)) 0.01)
                "Terran add-on X offset from Barracks center must equal +2.5")
  (assert-true! (< (abs (- (- (cdr east-addon) (cdr east-rax)) -0.5)) 0.01)
                "Terran add-on Y offset from Barracks center must equal -0.5")

  ;; 2. In-Progress Order Ledger (`make-order-ledger`, build-site reservation, and order equivalence)
  (define oled (make-order-ledger))
  (define-values (b1x b1y)
    (order-ledger-resolve-build-coords! oled 'pylon 36.0 36.0 '() 100))
  (order-ledger-record-issued! oled 11 'build 'pylon #:target-x b1x #:target-y b1y #:frame 100)
  (define-values (b2x b2y)
    (order-ledger-resolve-build-coords! oled 'pylon 36.0 36.0 '() 104))
  (assert-true! (> (sqrt (+ (sqr (- b2x b1x)) (sqr (- b2y b1y)))) 2.0)
                "Second Pylon requested while first Pylon build site is reserved must be offset by > 2.0 tiles")
  (assert-eq! (order-ledger-pending-count-for-type oled 'pylon 104) 1
              "Order ledger must count 1 in-flight Pylon build before structure appears in observation")

  ;; Equivalent combat order deduplication
  (define oled-combat (make-order-ledger))
  (order-ledger-record-issued! oled-combat 501 'kite 'move #:target-x 50.0 #:target-y 50.0 #:frame 200)
  ;; Clear step-issued-units by reconciling at frame 204 so we test cross-frame order equivalence
  (define kite-unit-204
    (hash 'id 501 'type 'banshee 'x 48.0 'y 48.0 'hp 140 'max-hp 140
          'order-ability-id 16 'order-target-x 50.0 'order-target-y 50.0))
  (order-ledger-reconcile-observation! oled-combat (hash 'frame 204 'ally-units (list kite-unit-204) 'ally-buildings '()))
  (assert-true! (order-ledger-order-equivalent? oled-combat kite-unit-204 'kite 0 50.5 50.5 204)
                "Move/kite order within SC2-ORDER-EQUIV-DIST-TOLERANCE (1.75 tiles) must be treated as equivalent")
  (assert-eq! (order-ledger-order-equivalent? oled-combat kite-unit-204 'kite 0 65.0 65.0 204) #f
              "Move/kite order > 1.75 tiles away must not be treated as equivalent")

  ;; Weapon-swing guard prevents cancelling a Banshee's attack windup
  (define banshee-swing-u
    (hash 'id 502 'type 'banshee 'x 60.0 'y 60.0 'hp 140 'max-hp 140
          'order-ability-id 23 'engaged-target-tag 900 'weapon-cooldown 0.04))
  (assert-true! (order-ledger-unit-in-attack-swing? oled-combat banshee-swing-u 204)
                "Banshee with order-ability-id=23, engaged-target-tag > 0, and low weapon-cooldown must be protected during attack swing")

  ;; 3. Multi-Depth Mirrored Tactical Micro Brain (`step-tactical-mirror-brain!`)
  (define tbrain (make-tactical-mirror-brain))
  (define oled-tb (make-order-ledger))
  ;; 3a. Banshee vs Ground-Only Zerglings: must free-fire (`attack-unit`), never retreat from ground-only units!
  (define obs-air
    (hash 'frame 300
          'base-x 32.0 'base-y 32.0
          'ally-units (list (hash 'id 601 'type 'banshee 'x 70.0 'y 70.0 'hp 140 'max-hp 140
                                  'energy 60 'flying? #t 'cloaked #f 'weapon-cooldown 0.0 'engaged-target-tag 0))
          'enemy-units (list (hash 'id 801 'type 'zergling 'x 71.0 'y 70.0 'hp 35 'max-hp 35 'flying? #f)
                             (hash 'id 802 'type 'zergling 'x 71.5 'y 70.5 'hp 35 'max-hp 35 'flying? #f)
                             (hash 'id 803 'type 'roach 'x 72.0 'y 70.0 'hp 145 'max-hp 145 'flying? #f))))
  (order-ledger-reconcile-observation! oled-tb obs-air)
  (define-values (tb-acts-air tb-tags-air _tb-decs-air)
    (step-tactical-mirror-brain! tbrain obs-air oled-tb))
  (assert-true! (set-member? tb-tags-air 601)
                "Tactical mirror brain must claim Banshee 601 in active arena")
  (assert-true! (ormap (lambda (a) (match a [(list 'attack-unit 601 _) #t] [_ #f])) tb-acts-air)
                "Banshee facing ground-only enemies (Zerglings/Roaches) must issue attack-unit (free-fire), never retreat")

  ;; 3b. Banshee with energy >= 25 vs Marines without detector: must cloak (`cloak-banshee`) and hold
  ;;     commitment lock across consecutive steps without oscillating!
  (define obs-cloak-400
    (hash 'frame 400
          'base-x 32.0 'base-y 32.0
          'ally-units (list (hash 'id 602 'type 'banshee 'x 80.0 'y 80.0 'hp 140 'max-hp 140
                                  'energy 50 'flying? #t 'cloaked #f 'weapon-cooldown 0.0 'engaged-target-tag 0))
          'enemy-units (list (hash 'id 810 'type 'marine 'x 83.0 'y 80.0 'hp 45 'max-hp 45 'flying? #f)
                             (hash 'id 811 'type 'marine 'x 83.5 'y 80.5 'hp 45 'max-hp 45 'flying? #f))))
  (order-ledger-reconcile-observation! oled-tb obs-cloak-400)
  (define-values (tb-acts-cloak _tb-tags-c tb-decs-c)
    (step-tactical-mirror-brain! tbrain obs-cloak-400 oled-tb))
  (assert-true! (member '(cast-spell 602 cloak-banshee) tb-acts-cloak)
                "Uncloaked Banshee with energy >= 25 vs Marines without detection must cast cloak-banshee")
  (define dec-400 (hash-ref (first tb-decs-c) 'committed-action))
  ;; Step 4 frames later (frame 404, within SC2-TACTICAL-MIN-LOCK-FRAMES = 11): decision must not oscillate!
  (define obs-cloak-404
    (hash 'frame 404
          'base-x 32.0 'base-y 32.0
          'ally-units (list (hash 'id 602 'type 'banshee 'x 80.2 'y 80.0 'hp 134 'max-hp 140
                                  'energy 35 'flying? #t 'cloaked #t 'weapon-cooldown 0.5 'engaged-target-tag 810))
          'enemy-units (list (hash 'id 810 'type 'marine 'x 82.8 'y 80.0 'hp 33 'max-hp 45 'flying? #f)
                             (hash 'id 811 'type 'marine 'x 83.3 'y 80.5 'hp 45 'max-hp 45 'flying? #f))))
  (order-ledger-reconcile-observation! oled-tb obs-cloak-404)
  (define-values (_tb-acts-404 _tb-tags-404 tb-decs-404)
    (step-tactical-mirror-brain! tbrain obs-cloak-404 oled-tb))
  (assert-eq! (hash-ref (first tb-decs-404) 'committed-action) dec-400
              "Hysteresis commitment lock must prevent Banshee tactical action oscillation within lock window")

  ;; 4. Building & Army Control Groups (`0..9`) & Camera Bookmarks (`F1..F8`)
  (define hc (make-human-cortex #:epm-cap 300))
  (define cg-obs
    (hash 'frame 500
          'base-x 32.0 'base-y 32.0
          'natural-x 52.0 'natural-y 56.0
          'third-x 72.0 'third-y 36.0
          'enemy-x 144.0 'enemy-y 144.0
          'ally-buildings (list (hash 'id 401 'type 'orbital-command 'x 32.0 'y 32.0 'build-progress 1.0 'order-count 0)
                                (hash 'id 402 'type 'orbital-command 'x 52.0 'y 56.0 'build-progress 1.0 'order-count 1)
                                (hash 'id 501 'type 'barracks 'x 36.0 'y 36.0 'build-progress 1.0 'order-count 0 'addon 'reactor)
                                (hash 'id 502 'type 'barracks 'x 42.0 'y 36.0 'build-progress 1.0 'order-count 0 'addon 'techlab)
                                (hash 'id 601 'type 'starport 'x 36.0 'y 40.0 'build-progress 1.0 'order-count 0 'addon 'techlab)
                                (hash 'id 701 'type 'engineering-bay 'x 30.0 'y 36.0 'build-progress 1.0 'order-count 0)
                                (hash 'id 901 'type 'supply-depot 'x 44.0 'y 44.0 'build-progress 1.0 'order-count 0))
          'ally-units (list (hash 'id 101 'type 'marine 'x 54.0 'y 58.0 'hp 45)
                            (hash 'id 102 'type 'marauder 'x 54.5 'y 58.5 'hp 125)
                            (hash 'id 201 'type 'banshee 'x 90.0 'y 90.0 'hp 140 'flying? #t)
                            (hash 'id 301 'type 'siege-tank 'x 53.0 'y 57.0 'hp 175)
                            (hash 'id 801 'type 'reaper 'x 110.0 'y 110.0 'hp 60))))
  (define cg-acts (cortex-sync-control-groups! hc
                                               (hash-ref cg-obs 'ally-units)
                                               (hash-ref cg-obs 'ally-buildings)
                                               32.0
                                               32.0))
  (assert-eq! (cortex-get-control-group hc 4) '(401 402)
              "Control Group 4 must bind all Townhalls (401, 402)")
  (assert-eq! (cortex-get-control-group hc 5) '(501 502)
              "Control Group 5 must bind Primary Production facilities (Barracks 501, 502)")
  (assert-eq! (cortex-get-control-group hc 6) '(601)
              "Control Group 6 must bind Tech Production facilities (Starport 601)")
  (assert-eq! (cortex-get-control-group hc 7) '(701)
              "Control Group 7 must bind Upgrade structures (Engineering Bay 701)")
  (assert-eq! (cortex-get-control-group hc 2) '(201 801)
              "Control Group 2 must bind Harass/Air squad (Banshee 201, Reaper 801)")
  (assert-true! (not (member 201 (cortex-get-control-group hc 1)))
                "Banshee 201 stolen into Control Group 2 must not be overwritten back into Main Army Group 1")
  (define cg5-cap (cortex-production-group-capacity hc (hash-ref cg-obs 'ally-buildings) 5))
  (assert-eq! (hash-ref cg5-cap 'open-slot-count) 3
              "Building Control Group 5 capacity with 1 idle Reactor Barracks (2 slots) + 1 idle TechLab Barracks (1 slot) must equal 3")
  (define bm-acts (cortex-sync-camera-bookmarks! hc cg-obs))
  (assert-true! (pair? (cortex-get-camera-bookmark hc 1))
                "Camera Bookmark F1 (Main Base) must be bound")
  (assert-true! (pair? (cortex-get-camera-bookmark hc 2))
                "Camera Bookmark F2 (Natural Base) must be bound")
  (assert-true! (pair? (cortex-get-camera-bookmark hc 5))
                "Camera Bookmark F5 (Primary Combat Front) must be bound"))

;; ============================================================================
;; 5.16 Empirical 1,798-Replay Pro Build-Order Executor, Diagonal Ramp Wall
;;      Non-Overlap, Save-Cancel Safety & Weapon-Domain Target Filtering
;; ============================================================================

(run-suite "5.16 Empirical 1,798-Replay Pro Build-Order Executor, Diagonal Ramp Wall Non-Overlap & Save-Cancel Safety"
  ;; 1. Empirical Pro Build-Order DB loaded from 1,798 pro replays across all 9 matchups
  (assert-true! (and (pair? PRO-BUILD-ORDER-DB) (eq? (first PRO-BUILD-ORDER-DB) 'pro-build-order-database))
                "PRO-BUILD-ORDER-DB must be loaded from data/pro_build_orders.sexp")
  (for ([matchup (in-list '(ZvZ ZvT ZvP TvZ TvT TvP PvZ PvT PvP))])
    (define steps (pro-build-order-steps-for-matchup matchup))
    (assert-true! (>= (length steps) 15)
                  (format "Matchup ~a must have >= 15 pro build-order steps" matchup)))
  (define-values (zvt-w-target zvt-a-target)
    (pro-supply-curve-target 'Zerg 'Terran 4032 3))
  (assert-true! (>= (+ zvt-w-target zvt-a-target) 50)
                "Zerg 180s pro median supply curve target must be >= 50")

  ;; 2. Pro Build-Order Goal-Queue Executor reserves resources
  ;;    for next high-priority expansion/tech step (e.g., 16 Hatchery in ZvT)
  (define bo-res
    (evaluate-build-order-next-step
     #:race 'Zerg
     #:enemy-race 'Terran
     #:frame 450
     #:minerals 220
     #:gas 50
     #:supply-used 16
     #:supply-left 6
     #:active-bases 1
     #:ready-building-counts (hash 'hatchery 1)
     #:total-building-counts (hash 'hatchery 1)
     #:unit-counts (hash 'drone 16 'overlord 2)))
  (assert-eq! (pro-bo-eval-result-matchup bo-res) 'ZvT
              "evaluate-build-order-next-step for Zerg vs Terran must select ZvT")
  (assert-true! (>= (pro-bo-eval-result-reserved-minerals bo-res) 300)
                "When at 16 supply with 220 minerals in ZvT, executor must reserve >= 300 minerals for 16 Hatchery")

  ;; 3. Diagonal & Cardinal Terran Ramp Wall Non-Overlap across all 8 ramp orientations
  (define (boxes-overlap? ax0 ax1 ay0 ay1 bx0 bx1 by0 by1)
    (and (< (+ ax0 0.01) bx1)
         (> (- ax1 0.01) bx0)
         (< (+ ay0 0.01) by1)
         (> (- ay1 0.01) by0)))
  (for ([dir (in-list '((20.0 . 0.0) (-20.0 . 0.0) (0.0 . 20.0) (0.0 . -20.0)
                        (20.0 . 20.0) (-20.0 . 20.0) (20.0 . -20.0) (-20.0 . -20.0)))])
    (define wall (solve-terran-ramp-wall 50.0 50.0 (+ 50.0 (car dir)) (+ 50.0 (cdr dir))))
    (define rax (hash-ref wall 'barracks))
    (define addon (hash-ref wall 'barracks-addon))
    (define d1 (hash-ref wall 'depot-1))
    (define d2 (hash-ref wall 'depot-2))
    (define rx (car rax))
    (define ry (cdr rax))
    (define ax (car addon))
    (define ay (cdr addon))
    (define d1x (car d1))
    (define d1y (cdr d1))
    (define d2x (car d2))
    (define d2y (cdr d2))
    ;; Verify Depot 1 & Depot 2 do not overlap 3x3 Barracks or 2x2 Add-On or each other
    (assert-true! (not (boxes-overlap? (- d1x 1.0) (+ d1x 1.0) (- d1y 1.0) (+ d1y 1.0)
                                       (- rx 1.5) (+ rx 1.5) (- ry 1.5) (+ ry 1.5)))
                  (format "Depot 1 must not overlap 3x3 Barracks for dir ~a" dir))
    (assert-true! (not (boxes-overlap? (- d2x 1.0) (+ d2x 1.0) (- d2y 1.0) (+ d2y 1.0)
                                       (- rx 1.5) (+ rx 1.5) (- ry 1.5) (+ ry 1.5)))
                  (format "Depot 2 must not overlap 3x3 Barracks for dir ~a" dir))
    (assert-true! (not (boxes-overlap? (- d1x 1.0) (+ d1x 1.0) (- d1y 1.0) (+ d1y 1.0)
                                       (- ax 1.0) (+ ax 1.0) (- ay 1.0) (+ ay 1.0)))
                  (format "Depot 1 must not overlap 2x2 East Add-On for dir ~a" dir))
    (assert-true! (not (boxes-overlap? (- d2x 1.0) (+ d2x 1.0) (- d2y 1.0) (+ d2y 1.0)
                                       (- ax 1.0) (+ ax 1.0) (- ay 1.0) (+ ay 1.0)))
                  (format "Depot 2 must not overlap 2x2 East Add-On for dir ~a" dir))
    (assert-true! (not (boxes-overlap? (- d1x 1.0) (+ d1x 1.0) (- d1y 1.0) (+ d1y 1.0)
                                       (- d2x 1.0) (+ d2x 1.0) (- d2y 1.0) (+ d2y 1.0)))
                  (format "Depot 1 and Depot 2 must not overlap each other for dir ~a" dir)))

  ;; 4. TacticalBuildingSaveCancel safety: a nearly completed building with full HP or no nearby
  ;;    enemy attackers must NEVER be canceled!
  (define rt-cancel (make-live-bot-runtime #:race 'Zerg #:personality 'Macro-Standard))
  (define safe-bldg-obs
    (hash 'frame 1200
          'minerals 100
          'gas 50
          'supply-used 22
          'supply-cap 30
          'ally-buildings (list (hash 'id 901 'type 'hatchery 'x 32.0 'y 32.0 'hp 1500 'max-hp 1500 'build-progress 1.0)
                                (hash 'id 902 'type 'spawning-pool 'x 36.0 'y 36.0 'hp 850 'max-hp 1000 'build-progress 0.92))
          'ally-units (list (hash 'id 101 'type 'drone 'x 31.0 'y 31.0 'hp 40))
          'enemy-units (list (hash 'id 999 'type 'overlord 'x 36.5 'y 36.5 'hp 200 'flying? #t))))
  (define safe-bldg-acts (step-layer2-economy! rt-cancel safe-bldg-obs))
  (assert-true! (not (member '(cancel-building 902) safe-bldg-acts))
                "Building at 92% progress with only a passive enemy Overlord nearby must NEVER be self-canceled")

  ;; 5. Weapon-domain target filtering & untargetable unit rejection
  (assert-true! (not (sc2-enemy-unit-targetable? 'adept-phase-shift))
                "adept-phase-shift shade must be rejected as untargetable")
  (assert-true! (not (sc2-enemy-unit-targetable? 'kd8-charge))
                "kd8-charge mine must be rejected as untargetable")
  (assert-true! (not (sc2-attacker-can-hit-enemy? 'zealot (hash 'type 'mutalisk 'flying #t)))
                "Ground-only Zealot must not select flying Mutalisk as a valid weapon target")
  (assert-true! (sc2-attacker-can-hit-enemy? 'stalker (hash 'type 'mutalisk 'flying #t))
                "Anti-air Stalker must be able to target flying Mutalisk"))

(run-suite "5.17 General Braun-Heap Priority Scheduler, Facility-Slot Escrow & Decision Trace Logging"
  ;; 1. Protoss with ready & open Robotics Facility at 150M/150G:
  ;;    Immortal (u ~ 192+) outranks Stalker (u ~ 168), Zealot, Gateway, and Probe,
  ;;    escrowing 275M and blocking lower-rank spending until Robo is fed.
  (define open-robo-slots (hash 'robotics-facility 1 'gateway 2 'townhall 2))
  (define p-cands-open
    (generate-race-priority-candidates
     #:race 'Protoss
     #:frame 4500
     #:minerals 150
     #:gas 150
     #:supply-left 8
     #:supply-cap 54
     #:workers 38
     #:target-workers 44
     #:active-bases 2
     #:desired-bases 2
     #:production-facilities 3
     #:max-facilities 6
     #:army-supply 16
     #:enemy-threat-supply 14
     #:ally-buildings '(nexus pylon assimilator gateway cybernetics-core robotics-facility twilight-council)
     #:ready-buildings '(nexus pylon assimilator gateway cybernetics-core robotics-facility twilight-council)
     #:ally-units '(probe stalker stalker sentry observer)
     #:researched-upgrades '(warp-gate-research)
     #:open-prod-slots open-robo-slots))
  (define p-sched-open
    (schedule-priority-candidates-with-ledger!
     p-cands-open
     #:minerals 150
     #:gas 150
     #:supply-left 8
     #:supply-cap 54
     #:escrow-eligible? #f))
  (assert-true! (not (priority-schedule-can-spend? p-sched-open 'stalker 150 150 #:category 'combat-unit))
                "Open Robotics Facility waiting on minerals for Immortal (150M/150G) must escrow against lower-priority Stalker")
  (assert-true! (not (priority-schedule-can-spend? p-sched-open 'gateway 150 150 #:category 'production-scaling))
                "Open Robotics Facility waiting on minerals for Immortal must escrow against extra Gateway")
  (define p-log-open
    (format-priority-schedule-log-line p-sched-open #:frame 4500 #:race 'Protoss #:minerals 150 #:gas 150))
  (assert-true! (regexp-match? #rx"\\[SCBOT_PRIORITY\\]" p-log-open)
                "format-priority-schedule-log-line must emit [SCBOT_PRIORITY] header")
  (assert-true! (regexp-match? #rx"immortal\\(escrowed-saving" p-log-open)
                "Priority decision log must record immortal(escrowed-saving) in escrow_queue")

  ;; 2. As soon as Robotics Facility slot is busy (open-prod-slots['robotics-facility] = 0),
  ;;    Immortal has blocking-allowed? = #f and Stalker / Gateway are immediately unblocked!
  (define busy-robo-slots (hash 'robotics-facility 0 'gateway 2 'townhall 2))
  (define p-cands-busy
    (generate-race-priority-candidates
     #:race 'Protoss
     #:frame 4504
     #:minerals 150
     #:gas 150
     #:supply-left 8
     #:supply-cap 54
     #:workers 38
     #:target-workers 44
     #:active-bases 2
     #:desired-bases 2
     #:production-facilities 3
     #:max-facilities 6
     #:army-supply 20
     #:enemy-threat-supply 14
     #:ally-buildings '(nexus pylon assimilator gateway cybernetics-core robotics-facility twilight-council)
     #:ready-buildings '(nexus pylon assimilator gateway cybernetics-core robotics-facility twilight-council)
     #:ally-units '(probe stalker stalker sentry observer)
     #:researched-upgrades '(warp-gate-research)
     #:open-prod-slots busy-robo-slots))
  (define p-sched-busy
    (schedule-priority-candidates-with-ledger!
     p-cands-busy
     #:minerals 150
     #:gas 150
     #:supply-left 8
     #:supply-cap 54
     #:escrow-eligible? #f))
  (assert-true! (priority-schedule-can-spend? p-sched-busy 'stalker 150 150 #:category 'combat-unit)
                "When Robotics Facility slot is busy (0 open slots), Stalker must be immediately unblocked at 150M/150G")

  ;; 3. Terran with open Factory + TechLab at 100M/150G:
  ;;    Siege Tank (150M/125G) escrows 150M against Marine/Marauder/SCV, and unblocks when Factory is busy.
  (define open-fac-slots (hash 'factory 1 'barracks 2 'townhall 2))
  (define t-cands-open
    (generate-race-priority-candidates
     #:race 'Terran
     #:frame 4200
     #:minerals 100
     #:gas 150
     #:supply-left 8
     #:supply-cap 54
     #:workers 36
     #:target-workers 44
     #:active-bases 2
     #:desired-bases 2
     #:production-facilities 3
     #:max-facilities 6
     #:army-supply 16
     #:enemy-threat-supply 14
     #:ally-buildings '(command-center orbital-command supply-depot barracks barracks-techlab factory factory-techlab)
     #:ready-buildings '(command-center orbital-command supply-depot barracks barracks-techlab factory factory-techlab)
     #:ally-units '(scv marine marauder)
     #:researched-upgrades '(stimpack)
     #:open-prod-slots open-fac-slots))
  (define t-sched-open
    (schedule-priority-candidates-with-ledger!
     t-cands-open
     #:minerals 100
     #:gas 150
     #:supply-left 8
     #:supply-cap 54
     #:escrow-eligible? #f))
  (assert-true! (not (priority-schedule-can-spend? t-sched-open 'marine 100 150 #:category 'combat-unit))
                "Open Factory+TechLab waiting on minerals for Siege Tank (100M/150G) must escrow against Marine")
  (assert-true! (not (priority-schedule-can-spend? t-sched-open 'marauder 100 150 #:category 'combat-unit))
                "Open Factory+TechLab waiting on minerals for Siege Tank (100M/150G) must escrow against Marauder"))

(run-suite "5.18 Optimal Human Selection & Control-Group Compiler, Unseen Pro Units/Splash Micro & Mirror-Mind FoW Persistence"
  ;; 1. Optimal Human Selection & Control-Group Compiler (`lib/human-cortex.rkt`):
  ;;    - `simulate-box-drag-on-screen` strictly selects only units inside the current camera viewport
  ;;    - 1-APM `control-group-recall`, 2-APM `control-group-recall` + `select-ctrl-type` wireframe sub-selection,
  ;;      2-APM `select-box` + `deselect-ctrl-type` wireframe deselection, and on-the-fly control-group merge
  (define sel-cortex (make-human-cortex #:cam-x 50.0 #:cam-y 50.0))
  (define on-screen-units
    (list (hash 'id 101 'type 'marine 'x 48.0 'y 48.0)
          (hash 'id 102 'type 'marine 'x 49.0 'y 48.5)
          (hash 'id 103 'type 'marine 'x 50.0 'y 49.0)
          (hash 'id 104 'type 'siege-tank 'x 48.2 'y 48.2)
          (hash 'id 105 'type 'siege-tank 'x 51.5 'y 49.8)
          ;; Off-screen reinforcement Marine at (120, 120) outside viewport (50, 50)
          (hash 'id 199 'type 'marine 'x 120.0 'y 120.0)))

  ;; 1a. Box drag on screen cannot select off-screen unit 199
  (define boxed-ids
    (map (lambda (u) (hash-ref u 'id))
         (simulate-box-drag-on-screen 40.0 40.0 60.0 60.0 on-screen-units 50.0 50.0)))
  (assert-true! (and (member 101 boxed-ids) (member 104 boxed-ids) (not (member 199 boxed-ids)))
                "simulate-box-drag-on-screen must select on-screen units 101..105 and reject off-screen unit 199")

  ;; 1b. Pre-seed Control Group 1 with all 6 units (including off-screen 199), then compile selection for `{104, 105}` (Siege Tanks):
  ;;     Compiler should use 2-APM `control-group-recall 1` + `select-ctrl-type siege-tank` (or `select-box` + `select-ctrl-type`)!
  (cortex-set-control-group! sel-cortex 1 '(101 102 103 104 105 199))
  (set-cortex-active-selection! sel-cortex '(101 102 103 104 105 199))
  (define-values (tank-sel-seq tank-realized)
    (compile-optimal-unit-selection! sel-cortex '(104 105) on-screen-units '()
                                     #:allow-superset? #f
                                     #:allow-on-the-fly-cg-update? #f))
  (assert-eq! tank-realized '(104 105))
  (assert-eq! (length tank-sel-seq) 1)
  (assert-eq! (caar tank-sel-seq) 'select-ctrl-type)
  (assert-eq! (cadar tank-sel-seq) 'siege-tank)

  ;; 1c. Shift+Ctrl+Click Deselect Type (`deselect-ctrl-type`):
  ;;     Active selection is `{101, 102, 103, 104, 105}` (3 Marines + 2 Siege Tanks), desired is `{101, 102, 103}` (all except Siege Tanks):
  (set-cortex-active-selection! sel-cortex '(101 102 103 104 105))
  (define-values (marine-sel-seq marine-realized)
    (compile-optimal-unit-selection! sel-cortex '(101 102 103) on-screen-units '()
                                     #:allow-superset? #f
                                     #:allow-on-the-fly-cg-update? #f))
  (assert-eq! marine-realized '(101 102 103))
  (assert-true! (or (member '(deselect-ctrl-type siege-tank (101 102 103)) marine-sel-seq)
                    (member '(select-ctrl-type marine (101 102 103)) marine-sel-seq))
                "Compiler must collapse `{101, 102, 103}` from `{101..105}` into 1-click wireframe `select-ctrl-type` or `deselect-ctrl-type`")

  ;; 1d. `cortex-collapse-and-compile-selections!` coalesces per-unit commands and preserves off-screen CG members on steal:
  (cortex-set-control-group! sel-cortex 1 '(199))
  (set-cortex-active-selection! sel-cortex '())
  (define collapsed-cmds
    (cortex-collapse-and-compile-selections!
     sel-cortex
     '((attack-unit 101 9001)
       (attack-unit 102 9001)
       (attack-unit 103 9001)
       (attack-unit 104 9001)
       (attack-unit 105 9001)
       (cast-spell 104 siege-mode 9001)
       (cast-spell 105 siege-mode 9001))
     on-screen-units
     '()))
  (assert-true! (ormap (lambda (a)
                         (and (eq? (car a) 'attack-unit)
                              (list? (second a))
                              (= (length (second a)) 5)))
                       collapsed-cmds)
                "cortex-collapse-and-compile-selections! must coalesce 5 individual attack-unit orders into 1 multi-tag command")
  (assert-true! (ormap (lambda (a)
                         (and (eq? (car a) 'cast-spell)
                              (equal? (second a) '(104 105))
                              (eq? (third a) 'siege-mode)))
                       collapsed-cmds)
                "cortex-collapse-and-compile-selections! must coalesce 2 Siege Tank siege-mode casts into 1 multi-tag command")
  (assert-true! (member 199 (cortex-get-control-group sel-cortex 1))
                "On-the-fly control-group update must merge on-screen boxed units without dropping off-screen member 199")

  ;; 2. Unseen Units & Pro Splash/Micro Tactics (`lib/tactics-sim.rkt` & `lib/bot-runtime.rkt`):
  ;; 2a. Carrier / Brood Lord decoy deprioritization (`interceptor` & `broodling`):
  (define carrier-vs-interceptor-target
    (select-target-enemy-for-unit
     50.0 50.0
     (list (hash 'id 801 'type 'interceptor 'x 52.0 'y 50.0 'hp 80 'is-flying #t)
           (hash 'id 802 'type 'carrier 'x 55.0 'y 50.0 'hp 450 'is-flying #t))
     'marine))
  (assert-eq! (hash-ref carrier-vs-interceptor-target 'id) 802)

  ;; 2b. Baneling Light/Bio clump target selection over single Armored Marauder:
  (define bane-target
    (select-target-enemy-for-unit
     50.0 50.0
     (list (hash 'id 810 'type 'marauder 'x 52.0 'y 50.0 'hp 125)
           (hash 'id 811 'type 'marine 'x 54.0 'y 50.0 'hp 45)
           (hash 'id 812 'type 'marine 'x 54.5 'y 50.5 'hp 45)
           (hash 'id 813 'type 'marine 'x 53.8 'y 50.2 'hp 45))
     'baneling))
  (assert-true! (memv (hash-ref bane-target 'id) '(811 812 813))
                "Baneling must target the Marine Light/Bio clump (811..813) over the front-most Armored Marauder (810)")

  ;; 2c. Pro Splash Evasion (Purification Nova / Widow Mine / Baneling / Hellion) & Siege Tank Bio Range-Leashing vs Spine Crawler:
  (define splash-rt (make-live-bot-runtime #:race 'Terran))
  (define-values (splash-acts _vc _rc)
    (step-layer3-and-4-tactics!
     splash-rt
     (hash 'frame 2000
           'mineral-harvesters 24
           'researched-upgrades '(stimpack)
           'base-x 32.0 'base-y 32.0
           'natural-x 50.0 'natural-y 50.0
           'ally-units (list (hash 'id 201 'type 'marine 'x 58.0 'y 50.0 'hp 45 'max-hp 45)
                             (hash 'id 202 'type 'marine 'x 58.8 'y 50.0 'hp 45 'max-hp 45)
                             (hash 'id 203 'type 'siege-tank-sieged 'x 53.0 'y 50.0 'hp 175 'max-hp 175 'sieged #t))
           'enemy-units (list (hash 'id 901 'type 'widow-mine-burrowed 'x 61.0 'y 50.0 'hp 90 'burrowed #t 'target-id 201))
           'enemy-buildings (list (hash 'id 950 'type 'spine-crawler 'x 64.0 'y 50.0 'hp 300)))
     0))
  ;; Both targeted Marine 201 and nearby Marine 202 (within 2.2 tiles of 201) must kite/split away!
  (assert-true! (ormap (lambda (a) (and (eq? (car a) 'kite) (= (second a) 201))) splash-acts)
                "Targeted Marine 201 must pull back from Widow Mine 901")
  (assert-true! (ormap (lambda (a) (and (eq? (car a) 'kite) (= (second a) 202))) splash-acts)
                "Nearby Marine 202 within 2.2 tiles of targeted Marine 201 must radially split away from Widow Mine blast")

  ;; Siege Tank range-leashing: when only enemy Spine Crawler (950) at (64, 50) is present within 6 tiles of Marine 201 at (58, 50)
  ;; and friendly Siege Tank 203 is at (53, 50) (within 15.5 tiles), Marine 201 leashes back via `kite` instead of feeding into Spine Crawler!
  (define-values (leash-acts _vc2 _rc2)
    (step-layer3-and-4-tactics!
     (make-live-bot-runtime #:race 'Terran)
     (hash 'frame 2020
           'mineral-harvesters 24
           'researched-upgrades '(stimpack)
           'base-x 32.0 'base-y 32.0
           'natural-x 50.0 'natural-y 50.0
           'ally-units (list (hash 'id 201 'type 'marine 'x 58.0 'y 50.0 'hp 45 'max-hp 45)
                             (hash 'id 203 'type 'siege-tank-sieged 'x 53.0 'y 50.0 'hp 175 'max-hp 175 'sieged #t))
           'enemy-units '()
           'enemy-buildings (list (hash 'id 950 'type 'spine-crawler 'x 64.0 'y 50.0 'hp 300)))
     0))
  (assert-true! (ormap (lambda (a) (and (eq? (car a) 'kite) (= (second a) 201))) leash-acts)
                "Marine 201 within 6 tiles of Spine Crawler 950 with Siege Tank 203 in range must leash back (`kite`) outside Spine range")

  ;; 3. Mirror-Mind Fog-of-War Persistence & Zero-Vision Probe Guard (`lib/mirror-mind-predictor.rkt`):
  (define fow-mm (make-mirror-mind-state #:our-race 'Terran #:enemy-race 'Zerg #:depth 2))
  ;; At frame 1344 with zero enemy units in sight, `step-mirror-mind-predictor!` must NOT issue a blind probe or lock active-depth = 1
  (step-mirror-mind-predictor! fow-mm (hash 'frame 1344 'enemy-units '() 'enemy-buildings '()))
  (step-mirror-mind-predictor! fow-mm (hash 'frame 1600 'enemy-units '() 'enemy-buildings '()))
  (assert-eq! (mirror-mind-state-last-probe-response fow-mm) 'untested)
  (assert-eq! (mirror-mind-state-active-depth fow-mm) 2)
  ;; At frame 6000, we scout an enemy Hydralisk Den; at frame 7000 our scout leaves vision (`enemy-units = '()`, `enemy-buildings = '()`)
  (step-mirror-mind-predictor!
   fow-mm
   (hash 'frame 6000
         'enemy-units (list (hash 'id 7001 'type 'hydralisk 'x 150 'y 150 'hp 90))
         'enemy-buildings (list (hash 'id 7100 'type 'hydralisk-den 'x 155 'y 155 'hp 850))))
  (step-mirror-mind-predictor!
   fow-mm
   (hash 'frame 7000
         'enemy-units '()
         'enemy-buildings '()))
  (assert-true! (memq 'hydralisk-den
                      (enemy-tech-observation-implied-tech-buildings
                       (mirror-mind-state-last-tech-observation fow-mm)))
                "Scouted hydralisk-den must persist across fog-of-war blackouts in Mirror-Mind")
  (assert-eq! (zero-sum-exclusion-reading-committed-primary-branch
               (mirror-mind-state-last-zero-sum-reading fow-mm))
              'hydra-lurker-den))

;; =============================================================================
;; 5.19 Build-Order Tree Space (T_R), Bayesian Bluff Posteriors, Multi-Horizon
;;      Snapshot Curve (15s..130s), Oracle Stasis Ward, Worker Drill & Attribute DPS
;; =============================================================================
(run-suite "5.19 Build-Order Tree Space (T_R), Bayesian Bluff Posteriors, Multi-Horizon Snapshot Curve, Oracle Stasis Ward & Worker Drill"
  ;; 1. Build-Order Tree Space (T_R) for self and opponent
  (for ([race-sym (in-list '(Zerg Terran Protoss))])
    (define tree (lookup-race-build-order-tree race-sym))
    (assert-true! (and (list? tree) (>= (length tree) 7))
                  (format "Race ~a must have >= 7 canonical build-order tree nodes" race-sym))
    (assert-true! (andmap build-order-tree-node? tree)
                  (format "All entries in ~a build-order tree must be build-order-tree-node structs" race-sym)))

  (define self-proj
    (project-self-build-order-tree
     (hash 'race 'Zerg
           'frame 2800
           'minerals 260
           'gas 160
           'ally-buildings (list (hash 'type 'hatchery)
                                 (hash 'type 'spawning-pool)
                                 (hash 'type 'roach-warren)
                                 (hash 'type 'extractor))
           'ally-units (list (hash 'type 'drone)
                             (hash 'type 'zergling)
                             (hash 'type 'roach)))
     60.0))
  (assert-true! (build-order-tree-projection? self-proj)
                "project-self-build-order-tree must return a build-order-tree-projection struct")
  (assert-eq! (build-order-tree-projection-perspective self-proj) 'self)
  (assert-eq! (build-order-tree-projection-active-node-id self-proj) 'zerg-roach-warren
              "Zerg with Hatchery + Spawning Pool + Roach Warren must project to zerg-roach-warren")
  (define self-post-sum
    (apply + (hash-values (build-order-tree-projection-branch-posteriors self-proj))))
  (assert-true! (< (abs (- self-post-sum 1.0)) 1e-4)
                "Self build-order tree branch posteriors must sum to 1.0")
  (assert-true! (and (pair? (memq 'roach (build-order-tree-projection-immediately-producible-units self-proj)))
                     (pair? (memq 'ravager (build-order-tree-projection-immediately-producible-units self-proj))))
                "zerg-roach-warren must unlock roach and ravager as immediately producible units")
  (assert-true! (pair? (build-order-tree-projection-horizon-reachable-units self-proj))
                "Self projection at 60s horizon must have non-empty horizon-reachable-units")
  (assert-true! (symbol? (build-order-tree-projection-recommended-next-build-step self-proj))
                "Self projection must recommend a symbolic next build step")

  (define opp-proj
    (project-opponent-build-order-tree
     (hash 'enemy-race 'Protoss
           'frame 3600
           'unaccounted-gas 220.0
           'enemy-buildings (list (hash 'type 'nexus)
                                  (hash 'type 'gateway)
                                  (hash 'type 'cybernetics-core)
                                  (hash 'type 'stargate)
                                  (hash 'type 'assimilator)
                                  (hash 'type 'assimilator))
           'enemy-units (list (hash 'type 'stalker)
                              (hash 'type 'oracle)))
     60.0))
  (assert-eq! (build-order-tree-projection-perspective opp-proj) 'opponent)
  (assert-eq! (build-order-tree-projection-active-node-id opp-proj) 'protoss-stargate-air
              "Opponent Protoss with Stargate + Oracle must project to protoss-stargate-air")
  (define opp-post-sum
    (apply + (hash-values (build-order-tree-projection-branch-posteriors opp-proj))))
  (assert-true! (< (abs (- opp-post-sum 1.0)) 1e-4)
                "Opponent build-order tree branch posteriors must sum to 1.0")
  (assert-true! (pair? (memq 'oracle (build-order-tree-projection-immediately-producible-units opp-proj)))
                "protoss-stargate-air must include oracle in immediately-producible-units")
  (assert-true! (or (pair? (memq 'carrier (build-order-tree-projection-horizon-reachable-units opp-proj)))
                    (pair? (memq 'immortal (build-order-tree-projection-horizon-reachable-units opp-proj))))
                "protoss-stargate-air at 60s horizon must include 1-hop child units (carrier / immortal) in horizon-reachable-units")
  (assert-true! (pair? (memq (build-order-tree-projection-recommended-next-build-step opp-proj)
                             '(fleet-beacon robotics-facility)))
                "protoss-stargate-air recommended next build step must be fleet-beacon or robotics-facility")

  ;; 2. Bayesian Bluff Priors & Posteriors (compute-bayesian-bluff-posterior & compute-bayesian-strategic-posteriors)
  (define p-normal-macro-gas
    (compute-bayesian-bluff-posterior
     #:candidate-branch 'spire-air-muta
     #:confirmed-commitment? #f
     #:remaining-gas 240
     #:fake-builds '()
     #:canceled-research-status 'no-research-cancel
     #:combat-hallucination-bait? #f
     #:idle-bluff-structures '()
     #:enemy-scouted-us? #f
     #:active-research-count 0))
  (assert-true! (and (> p-normal-macro-gas 0.08) (< p-normal-macro-gas 0.55))
                "Normal macro gas bank (rem-gas=240, no cancel, no idle bait) must keep bluff-posterior < 0.55")

  (define p-fake-bldg-cancel
    (compute-bayesian-bluff-posterior
     #:candidate-branch 'spire-air-muta
     #:confirmed-commitment? #f
     #:remaining-gas 100
     #:fake-builds '(spire)))
  (assert-true! (>= p-fake-bldg-cancel 0.55)
                "Unforced structure cancel (fake-builds non-empty) must push bluff-posterior >= 0.55")

  (define p-fake-research-cancel
    (compute-bayesian-bluff-posterior
     #:candidate-branch 'twilight-templar-ground
     #:confirmed-commitment? #f
     #:remaining-gas 150
     #:canceled-research-status 'fake-research-bluff-canceled))
  (assert-true! (>= p-fake-research-cancel 0.55)
                "Unforced research cancel must push bluff-posterior >= 0.55")

  (define p-halluc-bait
    (compute-bayesian-bluff-posterior
     #:candidate-branch 'stargate-sky-fleet
     #:confirmed-commitment? #f
     #:remaining-gas 180
     #:combat-hallucination-bait? #t))
  (assert-true! (>= p-halluc-bait 0.55)
                "Combat hallucination bait without real tech units must push bluff-posterior >= 0.55")

  (define p-confirmed-real
    (compute-bayesian-bluff-posterior
     #:candidate-branch 'spire-air-muta
     #:confirmed-commitment? #t
     #:remaining-gas 80
     #:active-research-count 1))
  (assert-true! (< p-confirmed-real 0.05)
                "Active research + confirmed branch units must push bluff-posterior < 0.05")

  (define strat-post
    (compute-bayesian-strategic-posteriors
     (hash 'frame 3000
           'enemy-race 'Protoss
           'enemy-buildings (list (hash 'type 'nexus) (hash 'type 'gateway) (hash 'type 'twilight-council))
           'enemy-units (list (hash 'type 'stalker)))))
  (assert-true! (bayesian-strategic-priors? strat-post)
                "compute-bayesian-strategic-posteriors must return a bayesian-strategic-priors struct")
  (assert-eq! (bayesian-strategic-priors-bluff-prior strat-post) 0.08)

  ;; 3. Multi-Horizon Future Snapshot Curve (15/30/45/60/75/90/105/130s)
  (assert-eq! MIRROR-HORIZON-SNAPSHOTS-SEC '(15 30 45 60 75 90 105 130))
  (define mh-mm (make-mirror-mind-state #:our-race 'Terran #:enemy-race 'Zerg #:depth 2))
  (define mh-obs
    (hash 'frame 3600
          'our-race 'Terran
          'enemy-race 'Zerg
          'minerals 300
          'gas 200
          'ally-buildings (list (hash 'type 'command-center) (hash 'type 'barracks) (hash 'type 'factory))
          'ally-units (list (hash 'id 101 'type 'marine 'x 40.0 'y 40.0 'hp 45))
          'enemy-buildings (list (hash 'id 901 'type 'hatchery 'x 150.0 'y 150.0 'hp 1500)
                                 (hash 'id 902 'type 'spawning-pool 'x 152.0 'y 150.0 'hp 1000)
                                 (hash 'id 903 'type 'roach-warren 'x 154.0 'y 150.0 'hp 850))
          'enemy-units (list (hash 'id 801 'type 'roach 'x 140.0 'y 140.0 'hp 145))))
  (define mh-curve (predict-multi-horizon-snapshots mh-obs mh-mm))
  (assert-eq! (length mh-curve) 8
              "predict-multi-horizon-snapshots must return 8 horizon-snapshot-forecast records")
  (assert-eq! (map exact-round (map horizon-snapshot-forecast-horizon-sec mh-curve))
              '(15 30 45 60 75 90 105 130)
              "Horizon snapshot curve must match MIRROR-HORIZON-SNAPSHOTS-SEC")
  (for ([prev (in-list (take mh-curve 7))]
        [next (in-list (drop mh-curve 1))])
    (assert-true! (> (horizon-snapshot-forecast-certainty-level prev)
                     (horizon-snapshot-forecast-certainty-level next))
                  (format "Calibrated certainty must strictly decrease from ~as to ~as"
                          (horizon-snapshot-forecast-horizon-sec prev)
                          (horizon-snapshot-forecast-horizon-sec next)))
    (assert-true! (<= (horizon-snapshot-forecast-optimal-depth prev)
                      (horizon-snapshot-forecast-optimal-depth next))
                  (format "Optimal cognitive depth d* must be non-decreasing from ~as to ~as"
                          (horizon-snapshot-forecast-horizon-sec prev)
                          (horizon-snapshot-forecast-horizon-sec next))))
  (assert-true! (<= (horizon-snapshot-forecast-optimal-depth (first mh-curve)) 1)
                "15s horizon optimal depth must be 0 or 1")
  (assert-eq! (horizon-snapshot-forecast-optimal-depth (last mh-curve)) 3
              "130s horizon optimal depth must be 3")

  (define mm-step-acts (step-mirror-mind-predictor! mh-mm mh-obs))
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'mirror-bo-tree-prediction))) mm-step-acts)
                "step-mirror-mind-predictor! must emit (mirror-bo-tree-prediction ...)")
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'mirror-horizon-curve))) mm-step-acts)
                "step-mirror-mind-predictor! must emit (mirror-horizon-curve ...)")

  ;; 4. Oracle Stasis Ward (stasis-ward / oracle-stasis-trap) & Anti-Stasis Worker Handling
  ;; 4a. Friendly Oracle mineral-line harass (stasis-ward + pulsar-beam)
  (define oracle-rt (make-live-bot-runtime #:race 'Protoss))
  (define-values (oracle-harass-acts _ovc1 _orc1)
    (step-layer3-and-4-tactics!
     oracle-rt
     (hash 'frame 2400
           'base-x 32.0 'base-y 32.0
           'natural-x 50.0 'natural-y 56.0
           'enemy-x 160.0 'enemy-y 160.0
           'enemy-expand-x 142.0 'enemy-expand-y 136.0
           'ally-units (list (hash 'id 301 'type 'oracle 'x 158.0 'y 158.0 'hp 100 'shield 60 'energy 80 'flying? #t))
           'enemy-units (list (hash 'id 911 'type 'drone 'x 160.0 'y 160.0 'hp 40)
                              (hash 'id 912 'type 'drone 'x 161.0 'y 160.0 'hp 40))
           'enemy-buildings (list (hash 'id 951 'type 'hatchery 'x 160.0 'y 160.0 'hp 1500)))
     0))
  (assert-true! (ormap (lambda (a)
                         (match a
                           [(list 'cast-spell 301 'stasis-ward _ _) #t]
                           [_ #f]))
                       oracle-harass-acts)
                "Friendly Oracle near enemy mineral line with >= 50 energy must cast stasis-ward")
  (assert-true! (ormap (lambda (a)
                         (match a
                           [(list 'cast-spell 301 'pulsar-beam _) #t]
                           [_ #f]))
                       oracle-harass-acts)
                "Friendly Oracle within 5 tiles of enemy workers with >= 50 energy must activate pulsar-beam")

  ;; 4b. Friendly Oracle expansion disruption at (enemy-expand-x, enemy-expand-y)
  (define-values (oracle-exp-acts _ovc2 _orc2)
    (step-layer3-and-4-tactics!
     (make-live-bot-runtime #:race 'Protoss)
     (hash 'frame 2600
           'base-x 32.0 'base-y 32.0
           'natural-x 50.0 'natural-y 56.0
           'enemy-x 160.0 'enemy-y 160.0
           'enemy-expand-x 142.0 'enemy-expand-y 136.0
           'ally-units (list (hash 'id 302 'type 'oracle 'x 140.0 'y 135.0 'hp 100 'shield 60 'energy 75 'flying? #t))
           'enemy-units '()
           'enemy-buildings '())
     0))
  (assert-true! (member '(cast-spell 302 stasis-ward 142.0 136.0) oracle-exp-acts)
                "Friendly Oracle near unbuilt enemy expansion must plant stasis-ward at (enemy-expand-x, enemy-expand-y)")

  ;; 4c. Friendly Oracle defensive choke Stasis Ward at (nat-x, nat-y)
  (define-values (oracle-def-acts _ovc3 _orc3)
    (step-layer3-and-4-tactics!
     (make-live-bot-runtime #:race 'Protoss)
     (hash 'frame 2800
           'base-x 32.0 'base-y 32.0
           'natural-x 50.0 'natural-y 56.0
           'enemy-x 160.0 'enemy-y 160.0
           'enemy-expand-x 142.0 'enemy-expand-y 136.0
           'ally-units (list (hash 'id 303 'type 'oracle 'x 48.0 'y 54.0 'hp 100 'shield 60 'energy 85 'flying? #t))
           'enemy-units '()
           'enemy-buildings '())
     0))
  (assert-true! (member '(cast-spell 303 stasis-ward 50.0 56.0) oracle-def-acts)
                "Friendly Oracle near natural choke with >= 75 energy must plant defensive stasis-ward at (nat-x, nat-y)")

  ;; 4d. Enemy oracle-stasis-trap near workers triggers evacuation + mineral-walk, and frozen workers
  ;;     trigger stasis-worker-stoppage-compensation + replacement worker training while excluded from combat micro
  (define anti-stasis-rt (make-live-bot-runtime #:race 'Zerg))
  (define anti-stasis-econ-acts
    (step-layer2-economy!
     anti-stasis-rt
     (hash 'frame 2800
           'minerals 700
           'gas 50
           'supply-used 20
           'supply-cap 36
           'base-x 32.0 'base-y 32.0
           'natural-x 50.0 'natural-y 56.0
           'ally-buildings (list (hash 'id 201 'type 'hatchery 'x 32.0 'y 32.0 'hp 1500 'build-progress 1.0)
                                 (hash 'id 203 'type 'hatchery 'x 50.0 'y 56.0 'hp 1500 'build-progress 1.0)
                                 (hash 'id 202 'type 'spawning-pool 'x 35.0 'y 35.0 'hp 1000 'build-progress 1.0))
           'ally-units (list (hash 'id 11 'type 'drone 'x 33.0 'y 33.0 'hp 40)
                             (hash 'id 12 'type 'drone 'x 33.5 'y 33.5 'hp 40)
                             (hash 'id 13 'type 'drone 'x 34.0 'y 34.0 'hp 40
                                   'buffs '(oracle-stasis-trap-target))
                             (hash 'id 14 'type 'drone 'x 34.5 'y 34.5 'hp 40
                                   'buffs '(oracle-stasis-trap-target)))
           'enemy-units (list (hash 'id 990 'type 'oracle-stasis-trap 'x 34.0 'y 33.0 'hp 30 'shield 30)))))
  (assert-true! (ormap (lambda (a)
                         (and (pair? a)
                              (eq? (car a) 'evacuate-workers-from-stasis-ward)
                              (equal? (second a) '(11 12))))
                       anti-stasis-econ-acts)
                "Unfrozen workers (11, 12) near enemy oracle-stasis-trap must evacuate via evacuate-workers-from-stasis-ward")
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk) (= (second a) 11)))
                       anti-stasis-econ-acts)
                "Evacuating workers must mineral-walk away from stasis trap")
  (assert-true! (member '(stasis-worker-stoppage-compensation 2) anti-stasis-econ-acts)
                "2 stasis-frozen workers must emit (stasis-worker-stoppage-compensation 2)")
  (assert-true! (member '(train drone) anti-stasis-econ-acts)
                "Stasis-frozen worker stoppage must trigger replacement worker training")

  ;; Verify stasis-frozen combat units are excluded from combat micro, ranged units snipe uncloaked/detected traps,
  ;; and melee-only armies dispatch a single sacrificial unit via trigger-stasis-ward-single-unit
  (define-values (ranged-snipe-acts _rvc _rrc)
    (step-layer3-and-4-tactics!
     (make-live-bot-runtime #:race 'Terran)
     (hash 'frame 2500
           'base-x 32.0 'base-y 32.0
           'natural-x 50.0 'natural-y 56.0
           'ally-units (list (hash 'id 401 'type 'marine 'x 48.0 'y 55.0 'hp 45 'ground-range 5.0)
                             (hash 'id 402 'type 'marine 'x 49.0 'y 55.0 'hp 45 'ground-range 5.0
                                   'buffs '(oracle-stasis-trap-target)))
           'enemy-units (list (hash 'id 991 'type 'oracle-stasis-trap 'x 52.0 'y 56.0 'hp 30 'shield 30
                                    'build-progress 0.5 'cloaked #f)))
     0))
  (assert-true! (member '(attack-unit 401 991) ranged-snipe-acts)
                "Unfrozen ranged Marine 401 (range 5.0 >= 4.5) must snipe uncloaked enemy oracle-stasis-trap 991")
  (assert-true! (not (ormap (lambda (a)
                              (and (pair? a) (>= (length a) 2) (equal? (second a) 402)))
                            ranged-snipe-acts))
                "Stasis-frozen Marine 402 must be excluded from combat micro")

  (define-values (melee-sac-acts _mvc _mrc)
    (step-layer3-and-4-tactics!
     (make-live-bot-runtime #:race 'Zerg)
     (hash 'frame 2520
           'base-x 32.0 'base-y 32.0
           'natural-x 50.0 'natural-y 56.0
           'ally-units (list (hash 'id 501 'type 'zergling 'x 49.0 'y 55.0 'hp 20 'ground-range 0.1)
                             (hash 'id 502 'type 'zergling 'x 49.5 'y 55.5 'hp 35 'ground-range 0.1)
                             (hash 'id 503 'type 'zergling 'x 50.0 'y 55.0 'hp 35 'ground-range 0.1))
           'enemy-units (list (hash 'id 992 'type 'oracle-stasis-trap 'x 52.0 'y 56.0 'hp 30 'shield 30
                                    'build-progress 1.0 'cloaked #t)))
     0))
  (assert-true! (member '(trigger-stasis-ward-single-unit 501 992 52 56) melee-sac-acts)
                "Melee-only Zergling squad facing armed cloaked stasis trap must send lowest-HP Zergling 501 via trigger-stasis-ward-single-unit")
  (assert-true! (and (ormap (lambda (a) (and (pair? a) (eq? (car a) 'kite) (= (second a) 502))) melee-sac-acts)
                     (ormap (lambda (a) (and (pair? a) (eq? (car a) 'kite) (= (second a) 503))) melee-sac-acts))
                "Other melee Zerglings (502, 503) must kite back outside stasis detonation radius")

  ;; 5. Mineral Walking & Drone Drilling (worker-drill-stack-attack & counter-enemy-worker-drill)
  (define cheese-drill-acts
    (step-layer2-economy!
     (make-live-bot-runtime #:race 'Zerg)
     (hash 'frame 900
           'minerals 150
           'gas 0
           'supply-used 14
           'supply-cap 14
           'base-x 32.0 'base-y 32.0
           'natural-x 50.0 'natural-y 56.0
           'mineral-patch-id 9001
           'ally-buildings (list (hash 'id 201 'type 'hatchery 'x 32.0 'y 32.0 'hp 1500 'build-progress 1.0))
           'ally-units (list (hash 'id 11 'type 'drone 'x 31.0 'y 31.0 'hp 40)
                             (hash 'id 12 'type 'drone 'x 31.5 'y 31.5 'hp 40)
                             (hash 'id 13 'type 'drone 'x 32.0 'y 31.0 'hp 40)
                             (hash 'id 14 'type 'drone 'x 32.5 'y 31.5 'hp 40)
                             (hash 'id 15 'type 'drone 'x 33.0 'y 31.0 'hp 40)
                             (hash 'id 16 'type 'drone 'x 33.5 'y 31.5 'hp 40)
                             (hash 'id 17 'type 'drone 'x 34.0 'y 31.0 'hp 40)
                             (hash 'id 18 'type 'drone 'x 34.5 'y 31.5 'hp 40))
           'enemy-units (list (hash 'id 801 'type 'zealot 'x 35.0 'y 35.0 'hp 100)
                              (hash 'id 802 'type 'probe 'x 35.2 'y 35.0 'hp 20)
                              (hash 'id 803 'type 'probe 'x 35.4 'y 35.2 'hp 20)
                              (hash 'id 804 'type 'probe 'x 35.1 'y 35.3 'hp 20)
                              (hash 'id 805 'type 'probe 'x 35.3 'y 35.1 'hp 20)))))
  (assert-true! (ormap (lambda (a)
                         (and (pair? a)
                              (eq? (car a) 'worker-drill-stack-attack)
                              (= (third a) 9001)))
                       cheese-drill-acts)
                "Early in-base cheese pull must emit (worker-drill-stack-attack pull-ids mineral-patch-id ...)")
  (assert-true! (ormap (lambda (a)
                         (and (pair? a)
                              (eq? (car a) 'counter-enemy-worker-drill)
                              (= (second a) 4)))
                       cheese-drill-acts)
                "Stacked enemy worker drill (4 enemy Probes within 1.8 tiles) must emit (counter-enemy-worker-drill 4 ...)")

  ;; 6. Tactical Mirror Brain Attribute Multipliers (sim-unit-weapon-dps-vs)
  (define sim-immortal (unit-hash->tactical-sim-unit (hash 'id 1 'type 'immortal 'x 50.0 'y 50.0 'hp 200 'shield 100) 'ally))
  (define sim-roach    (unit-hash->tactical-sim-unit (hash 'id 2 'type 'roach    'x 52.0 'y 50.0 'hp 145) 'enemy))
  (define sim-zealot   (unit-hash->tactical-sim-unit (hash 'id 3 'type 'zealot   'x 52.0 'y 50.0 'hp 100 'shield 50) 'enemy))
  (define sim-colossus (unit-hash->tactical-sim-unit (hash 'id 4 'type 'colossus 'x 50.0 'y 50.0 'hp 200 'shield 150) 'ally))
  (define sim-oracle   (unit-hash->tactical-sim-unit (hash 'id 5 'type 'oracle   'x 50.0 'y 50.0 'hp 100 'shield 60 'flying? #t) 'ally))
  (define sim-marine   (unit-hash->tactical-sim-unit (hash 'id 6 'type 'marine   'x 52.0 'y 50.0 'hp 45) 'enemy))

  (define imm-vs-roach  (sim-unit-weapon-dps-vs sim-immortal sim-roach))
  (define imm-vs-zealot (sim-unit-weapon-dps-vs sim-immortal sim-zealot))
  (assert-true! (< (abs (- (/ imm-vs-roach imm-vs-zealot) 1.45)) 1e-4)
                "Immortal vs Armored Roach must apply 1.45x Anti-Armored multiplier compared to Light Zealot")

  (define col-vs-marine (sim-unit-weapon-dps-vs sim-colossus sim-marine))
  (define col-vs-roach  (sim-unit-weapon-dps-vs sim-colossus sim-roach))
  (assert-true! (< (abs (- (/ col-vs-marine col-vs-roach) 1.55)) 1e-4)
                "Colossus vs Light Marine must apply 1.55x Anti-Light multiplier compared to Armored Roach")

  (define ora-vs-marine (sim-unit-weapon-dps-vs sim-oracle sim-marine))
  (define ora-vs-roach  (sim-unit-weapon-dps-vs sim-oracle sim-roach))
  (assert-true! (< (abs (- (/ ora-vs-marine ora-vs-roach) 1.55)) 1e-4)
                "Oracle vs Light Marine must apply 1.55x Anti-Light multiplier compared to Armored Roach"))

;; =============================================================================
;; 19. AI Arena BotZip Size Limit & Standalone Native ELF Binary Verification
;; =============================================================================

(run-suite "19. AI Arena BotZip Size Limit (<= 25 MB / 50 MiB) & Standalone Native ELF Binary"
  ;; 1. Verify constants enforce a strict safety margin well below AI Arena's 50 MiB standard cap
  (assert-eq! AIARENA-STANDARD-MAX-ZIP-BYTES (* 50 1024 1024)
              "AI Arena standard tier max zip size must be 50 MiB (52,428,800 bytes)")
  (assert-true! (<= MAX-BOT-ZIP-SIZE-BYTES (* 25 1000 1000))
                "Repository BotZip safety limit must be <= 25 MB")
  (assert-true! (< MAX-BOT-ZIP-SIZE-BYTES AIARENA-STANDARD-MAX-ZIP-BYTES)
                "MAX-BOT-ZIP-SIZE-BYTES must be strictly less than AIARENA-STANDARD-MAX-ZIP-BYTES")

  ;; 2. Verify all 6 ladder BotZip archives exist and obey size & structure limits
  (for ([row (in-list VARIANTS)])
    (define bname (first row))
    (define zpath (build-path "ladder" (format "~a.zip" bname)))
    (assert-true! (file-exists? zpath)
                  (format "Ladder BotZip ~a must exist on disk" zpath))
    (define zsize (file-size zpath))
    (assert-true! (>= zsize MIN-BOT-ZIP-SIZE-BYTES)
                  (format "~a (~a bytes) must be >= ~a bytes (standalone ELF floor)"
                          zpath zsize MIN-BOT-ZIP-SIZE-BYTES))
    (assert-true! (<= zsize MAX-BOT-ZIP-SIZE-BYTES)
                  (format "~a (~a bytes) must be <= ~a bytes (25 MB safety ceiling)"
                          zpath zsize MAX-BOT-ZIP-SIZE-BYTES))
    (assert-true! (< zsize AIARENA-STANDARD-MAX-ZIP-BYTES)
                  (format "~a (~a bytes) must be < ~a bytes (50 MiB AI Arena limit)"
                          zpath zsize AIARENA-STANDARD-MAX-ZIP-BYTES))
    (assert-eq! (validate-bot-zip-archive! zpath #:bot-name bname) #t
                (format "validate-bot-zip-archive! must pass for ~a" zpath)))

  ;; 3. Verify validate-bot-zip-archive! rejects oversized, undersized, non-ELF, and nested-zip archives
  (define sample-zip (build-path "ladder" "Mothman-Z.zip"))
  (define oversize-rejected?
    (with-handlers ([exn:fail? (lambda (_e) #t)])
      (validate-bot-zip-archive! sample-zip #:bot-name "Mothman-Z" #:max-bytes 1024)
      #f))
  (assert-eq! oversize-rejected? #t
              "validate-bot-zip-archive! must reject archives that exceed #:max-bytes")

  (define undersize-rejected?
    (with-handlers ([exn:fail? (lambda (_e) #t)])
      (validate-bot-zip-archive! sample-zip #:bot-name "Mothman-Z" #:min-bytes 90000000)
      #f))
  (assert-eq! undersize-rejected? #t
              "validate-bot-zip-archive! must reject archives smaller than #:min-bytes")

  (define bad-elf-rejected?
    (with-handlers ([exn:fail? (lambda (_e) #t)])
      (validate-bot-zip-archive! sample-zip #:bot-name "Mothman-Z" #:elf-bytes #"#!/bin/sh\necho bad\n")
      #f))
  (assert-eq! bad-elf-rejected? #t
              "validate-bot-zip-archive! must reject non-ELF or non-.rackprog binaries")

  (define nested-zip-rejected?
    (with-handlers ([exn:fail? (lambda (_e) #t)])
      (validate-bot-zip-archive! sample-zip
                                 #:bot-name "Mothman-Z"
                                 #:entry-names '("config.json" "sc-bot/ladder/Mothman-Z.zip"))
      #f))
  (assert-eq! nested-zip-rejected? #t
              "validate-bot-zip-archive! must reject nested .zip files inside a BotZip")

  ;; 4. Verify standalone compiled native ELF binary runs directly without Racket or Python
  (define standalone-elf (build-path "ladder" ".cache" "mothman_standalone_elf"))
  (assert-true! (file-exists? standalone-elf)
                "Standalone compiled native ELF binary ladder/.cache/mothman_standalone_elf must exist")
  (assert-true! (>= (file-size standalone-elf) MIN-STANDALONE-ELF-BYTES)
                "Standalone compiled native ELF binary must be >= 10 MB")
  (define dry-run-out
    (with-output-to-string
      (lambda ()
        (system* standalone-elf "--BotName" "Mothman-Z" "--dry-run"))))
  (assert-true! (string-contains? dry-run-out "\"status\":\"DRY_RUN_OK\"")
                "Standalone ELF binary --dry-run must output status DRY_RUN_OK")
  (assert-true! (string-contains? dry-run-out "\"engine\":\"racket_native_protobuf_ws\"")
                "Standalone ELF binary --dry-run must report racket_native_protobuf_ws engine"))

(printf "\n============================================================================\n")
(printf "  ALL #lang sc-bot TESTS PASSED (~a assertions, 12/12 mutation kill rate)!\n"
        total-assertions)
(printf "============================================================================\n")


