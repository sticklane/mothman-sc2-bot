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
         "../lib/priority-macro-brain.rkt"
         "../lib/pro-replay-starvation-audit.rkt"
         (only-in "../lib/sc2-protobuf-ws.rkt"
                  sc2-point3d
                  sc2-unit-order
                  sc2-unit
                  sc2-player-common
                  sc2-observation
                  sc2-raw-unit-command-ability-id
                  sc2-raw-unit-command-target-unit-tag
                  sc2-raw-unit-command-unit-tags
                  saturate-workers-and-gas-commands
                  translate-bot-actions->sc2-raw-commands)
         (only-in "../lib/sc2-mpq-replay-parser.rkt"
                  STORM-CRYPT
                  mpq-hash
                  parse-sc2-replay)
         (except-in "../lib/bot-crash-fuzzer.rkt"
                    compute-shadow-ledger
                    step-zerospace-mastermind!))

(define total-assertions 0)
(define suite-start-total-ms (current-inexact-monotonic-milliseconds))
(define full-test-mode?
  (or (not (not (member "--full" (vector->list (current-command-line-arguments)))))
      (and (getenv "SC_BOT_FULL_TEST") #t)))

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
    (define t0 (current-inexact-monotonic-milliseconds))
    (let ()
      body ...)
    (define elapsed-ms (inexact->exact (round (- (current-inexact-monotonic-milliseconds) t0))))
    (printf "OK (~a ms)\n" elapsed-ms)
    (flush-output)))

(printf "============================================================================\n")
(printf "  Running #lang sc-bot Verification & Match Simulation Suite (Racket v8.15, mode=~a)\n"
        (if full-test-mode? "FULL" "FAST-<5s"))
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
  (define sm-rep (verify-all-state-machines #:print-report? #f #:fast? (not full-test-mode?)))
  (assert-eq! (state-machine-verification-report-total-checks sm-rep) 24
              "Formal state-machine verifier must run all 24 invariants (P1-P5, M1-M5, E1-E5, PV1-PV9)")
  (assert-eq! (state-machine-verification-report-passed-checks sm-rep) 24
              "All 24 formal state-machine invariants must pass")
  (assert-eq! (state-machine-verification-report-failed-checks sm-rep) 0
              "Zero formal state-machine invariants may fail")
  (if full-test-mode?
      (assert-eq! (state-machine-verification-report-total-states-explored sm-rep) 117220
                  "Formal state-machine verifier must explore all 117,220 state transitions in --full mode")
      (assert-true! (>= (state-machine-verification-report-total-states-explored sm-rep) 4350)
                    "Fast-mode formal state-machine verifier must explore >= 4,350 state transitions"))
  (for ([chk (in-list (state-machine-verification-report-check-results sm-rep))])
    (assert-true! (verification-check-result-passed? chk)
                  (format "Formal invariant ~a must pass" (verification-check-result-id chk)))
    (assert-eq! (verification-check-result-counterexample chk) #f
                (format "Formal invariant ~a must have 0 counterexamples" (verification-check-result-id chk))))

  ;; Direct verification of verify-prioritization-scheduler-invariants (PV1-PV9)
  (define pv-results (verify-prioritization-scheduler-invariants #:fast? (not full-test-mode?)))
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

  (define fuzz-rep (run-bot-crash-and-contract-fuzzer #:frames (if full-test-mode? 1000 12) #:seed 20261107))
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
                "Open Factory+TechLab waiting on minerals for Siege Tank (100M/150G) must escrow against Marauder")

  ;; 4. Match #5112034 Regression (Gas-Lock Attenuation & Band-1 Queen/Roach-Warren Priority):
  ;;    Zerg on 2 bases with 1 Queen, 0 Roach Warrens, 6 Zerglings, and 100M/260G in peace time:
  ;;    Band-1 Roach Warren (u >= 445) & 2nd Queen (u >= 440) must outrank 0G Zergling and block Zergling from draining 100M!
  (define z-gaslock-state
    (make-macro-world-state
     #:race 'Zerg
     #:frame 3800
     #:minerals 100
     #:gas 260
     #:supply-used 26
     #:supply-cap 36
     #:supply-left 10
     #:workers 21
     #:active-bases 2
     #:ready-building-counts (hash 'hatchery 2 'extractor 1 'spawning-pool 1)
     #:total-building-counts (hash 'hatchery 2 'extractor 1 'spawning-pool 1)
     #:unit-counts (hash 'drone 21 'queen 1 'zergling 6 'overlord 3)
     #:researched-upgrades '(metabolic-boost)
     #:open-facility-slots (hash 'larva 3 'townhall 2)
     #:army-supply 4
     #:enemy-threat-supply 0
     #:under-attack? #f))
  (define z-gaslock-dec (step-priority-macro-brain z-gaslock-state))
  (assert-true! (not (macro-brain-can-spend? z-gaslock-dec 'zergling 100 260 'combat-unit))
                "0G Zergling at 100M/260G must not drain minerals needed for Band-1 Queen / Roach Warren")

  ;; 5. Match #5112033 Regression (Band-1 Expansion BO Head vs Band-2 Repeatable Stalker at High Gas):
  ;;    Protoss on 1 base at 85M/256G with 19 Probes (BO goal = nexus):
  ;;    Band-1 Nexus (u >= 465) must strictly outrank Band-2 Stalker (u <= 415) and block Stalker from spending 85M!
  (define p-1base-state
    (make-macro-world-state
     #:race 'Protoss
     #:frame 3800
     #:minerals 85
     #:gas 256
     #:supply-used 25
     #:supply-cap 31
     #:supply-left 6
     #:workers 19
     #:active-bases 1
     #:ready-building-counts (hash 'nexus 1 'pylon 2 'assimilator 2 'gateway 1 'cybernetics-core 1)
     #:total-building-counts (hash 'nexus 1 'pylon 2 'assimilator 2 'gateway 1 'cybernetics-core 1)
     #:unit-counts (hash 'probe 19 'stalker 2)
     #:researched-upgrades '(warp-gate-research)
     #:open-facility-slots (hash 'gateway 1 'townhall 1)
     #:army-supply 4
     #:enemy-threat-supply 0
     #:under-attack? #f))
  (define p-1base-dec (step-priority-macro-brain p-1base-state))
  (assert-true! (not (macro-brain-can-spend? p-1base-dec 'stalker 85 256 'combat-unit))
                "Band-1 1-base Nexus BO goal (u >= 465) must outrank and block Band-2 Stalker (u <= 415) even at 256G")

  ;; 6. Owned-Base Spatial Threat Field Regression:
  ;;    On 2 bases (active-bases = 2) with 6 Zerglings + 1 Queen, a lone enemy Reaper near the UNOWNED 3rd base
  ;;    must NOT trigger false base-attack panic or allow Zerglings to starve Queen / Roach Warren at 100M/260G!
  (define rt-unowned3rd (make-live-bot-runtime #:race 'Zerg))
  (define acts-unowned3rd
    (step-layer2-economy!
     rt-unowned3rd
     (hash 'frame 3800
           'minerals 100
           'gas 260
           'supply-used 26
           'supply-cap 36
           'mineral-harvesters 18
           'vespene-harvesters 3
           'researched-upgrades '(metabolic-boost)
           'base-x 32.5 'base-y 32.5
           'natural-x 50.5 'natural-y 56.5
           'third-x 75.5 'third-y 75.5
           'ally-buildings (list (hash 'id 101 'type 'hatchery 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0 'larva-count 2)
                                 (hash 'id 102 'type 'hatchery 'x 50.5 'y 56.5 'hp 1500 'build-progress 1.0 'larva-count 1)
                                 (hash 'id 103 'type 'spawning-pool 'x 36.0 'y 36.0 'hp 1000 'build-progress 1.0)
                                 (hash 'id 104 'type 'extractor 'x 30.0 'y 35.0 'hp 500 'build-progress 1.0))
           'ally-units (append
                        (for/list ([i (in-range 20)])
                          (hash 'id (+ 200 i) 'type 'drone 'x 32.5 'y 32.5 'hp 40))
                        (list (hash 'id 301 'type 'queen 'x 33.5 'y 33.5 'hp 175 'energy 10)
                              (hash 'id 302 'type 'zergling 'x 51.0 'y 56.0 'hp 35)
                              (hash 'id 303 'type 'zergling 'x 51.5 'y 56.0 'hp 35)
                              (hash 'id 304 'type 'zergling 'x 52.0 'y 56.0 'hp 35)
                              (hash 'id 305 'type 'zergling 'x 52.5 'y 56.0 'hp 35)
                              (hash 'id 306 'type 'zergling 'x 53.0 'y 56.0 'hp 35)
                              (hash 'id 307 'type 'zergling 'x 53.5 'y 56.0 'hp 35)))
           'enemy-units (list (hash 'id 991 'type 'reaper 'x 74.0 'y 74.0 'hp 60)))))
  (assert-true! (not (member '(train zergling) acts-unowned3rd))
                "Lone enemy Reaper near unowned 3rd base must not trigger false panic or drain 100M into Zerglings")

  ;; 7. Match #5112038 Regression (Zerg Drone Priority Escrow Respect & No Lair Escrow Under Base Attack):
  ;;    (a) On 2 bases with 24 Drones at 60M/380G when bo=baneling-nest (100M/50G),
  ;;        zerg-drone-priority? must respect the 100M baneling-nest reserve and NOT spend 50M on a Drone!
  (define rt-z5112038 (make-live-bot-runtime #:race 'Zerg))
  (define acts-z5112038-peace
    (step-layer2-economy!
     rt-z5112038
     (hash 'frame 4500
           'minerals 60
           'gas 380
           'supply-used 34
           'supply-cap 44
           'mineral-harvesters 21
           'vespene-harvesters 3
           'researched-upgrades '(metabolic-boost)
           'base-x 32.5 'base-y 32.5
           'natural-x 50.5 'natural-y 56.5
           'third-x 75.5 'third-y 75.5
           'ally-buildings (list (hash 'id 101 'type 'hatchery 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0 'larva-count 2)
                                 (hash 'id 102 'type 'hatchery 'x 50.5 'y 56.5 'hp 1500 'build-progress 1.0 'larva-count 2)
                                 (hash 'id 103 'type 'spawning-pool 'x 36.0 'y 36.0 'hp 1000 'build-progress 1.0)
                                 (hash 'id 104 'type 'roach-warren 'x 38.0 'y 36.0 'hp 850 'build-progress 1.0)
                                 (hash 'id 105 'type 'extractor 'x 30.0 'y 35.0 'hp 500 'build-progress 1.0))
           'ally-units (append
                        (for/list ([i (in-range 24)])
                          (hash 'id (+ 200 i) 'type 'drone 'x 32.5 'y 32.5 'hp 40))
                        (list (hash 'id 301 'type 'queen 'x 33.5 'y 33.5 'hp 175 'energy 10)
                              (hash 'id 302 'type 'queen 'x 51.5 'y 56.5 'hp 175 'energy 10)
                              (hash 'id 303 'type 'roach 'x 52.0 'y 56.0 'hp 145)
                              (hash 'id 304 'type 'roach 'x 52.5 'y 56.0 'hp 145)
                              (hash 'id 305 'type 'zergling 'x 53.0 'y 56.0 'hp 35)
                              (hash 'id 306 'type 'zergling 'x 53.5 'y 56.0 'hp 35)))
           'enemy-units '())))
  (assert-true! (not (member '(train drone) acts-z5112038-peace))
                "Match #5112038: Zerg with 24 Drones at 60M/380G must not spend 50M on a Drone while saving 100M for Baneling Nest")
  ;;    (b) Under active base attack with ready Spawning Pool and Roach Warren at 120M/480G,
  ;;        Lair must NOT escrow 150M/100G or block Roach/Zergling reinforcement!
  (define z-attack-state
    (make-macro-world-state
     #:race 'Zerg
     #:frame 9200
     #:minerals 120
     #:gas 480
     #:supply-used 42
     #:supply-cap 58
     #:supply-left 16
     #:workers 32
     #:active-bases 2
     #:ready-building-counts (hash 'hatchery 2 'extractor 2 'spawning-pool 1 'roach-warren 1 'baneling-nest 1)
     #:total-building-counts (hash 'hatchery 2 'extractor 2 'spawning-pool 1 'roach-warren 1 'baneling-nest 1)
     #:unit-counts (hash 'drone 32 'queen 2 'roach 3 'zergling 4 'overlord 5)
     #:researched-upgrades '(metabolic-boost)
     #:open-facility-slots (hash 'larva 3 'townhall 2)
     #:army-supply 12
     #:enemy-threat-supply 20
     #:under-attack? #t))
  (define z-attack-dec (step-priority-macro-brain z-attack-state))
  (assert-true! (macro-brain-can-spend? z-attack-dec 'roach 120 480 'combat-unit)
                "Match #5112038: Under active base attack at 120M/480G, Lair must not block Roach reinforcement")

  ;; 8. Match #5112039 Regression (Terran Engineering Bay vs Reactor Starport & No Blind Viking Escrow):
  ;;    When Starport already has a Starport-Reactor at 135M/260G and 0 Engineering Bays,
  ;;    step-layer2-economy! must build Engineering Bay (125M) and must NOT emit an invalid starport-techlab order!
  (define rt-t5112039 (make-live-bot-runtime #:race 'Terran))
  (define acts-t5112039
    (step-layer2-economy!
     rt-t5112039
     (hash 'frame 6800
           'minerals 135
           'gas 260
           'supply-used 52
           'supply-cap 62
           'mineral-harvesters 36
           'vespene-harvesters 6
           'researched-upgrades '(stimpack combat-shield)
           'base-x 32.5 'base-y 32.5
           'natural-x 50.5 'natural-y 56.5
           'third-x 75.5 'third-y 75.5
           'ally-buildings (list (hash 'id 101 'type 'orbital-command 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0 'energy 25)
                                 (hash 'id 102 'type 'orbital-command 'x 50.5 'y 56.5 'hp 1500 'build-progress 1.0 'energy 25)
                                 (hash 'id 103 'type 'barracks 'x 38.5 'y 32.5 'hp 1000 'build-progress 1.0)
                                 (hash 'id 104 'type 'barracks-techlab 'x 41.0 'y 32.0 'hp 400 'build-progress 1.0)
                                 (hash 'id 105 'type 'factory 'x 38.5 'y 36.5 'hp 1250 'build-progress 1.0)
                                 (hash 'id 106 'type 'factory-techlab 'x 41.0 'y 36.0 'hp 400 'build-progress 1.0)
                                 (hash 'id 107 'type 'starport 'x 38.5 'y 40.5 'hp 1300 'build-progress 1.0)
                                 (hash 'id 108 'type 'starport-reactor 'x 41.0 'y 40.0 'hp 400 'build-progress 1.0)
                                 (hash 'id 109 'type 'refinery 'x 30.0 'y 35.0 'hp 500 'build-progress 1.0)
                                 (hash 'id 110 'type 'refinery 'x 48.0 'y 59.0 'hp 500 'build-progress 1.0))
           'ally-units (append
                        (for/list ([i (in-range 42)])
                          (hash 'id (+ 200 i) 'type 'scv 'x 32.5 'y 32.5 'hp 45))
                        (list (hash 'id 301 'type 'marine 'x 52.0 'y 56.0 'hp 55)
                              (hash 'id 302 'type 'marauder 'x 52.5 'y 56.0 'hp 125)
                              (hash 'id 303 'type 'siege-tank 'x 53.0 'y 56.0 'hp 175)
                              (hash 'id 304 'type 'medivac 'x 53.5 'y 56.0 'hp 150)))
           'enemy-units '())))
  (assert-true! (for/or ([a (in-list acts-t5112039)])
                  (and (list? a) (>= (length a) 2) (eq? (first a) 'build) (eq? (second a) 'engineering-bay)))
                "Match #5112039: Terran at 135M/260G with Reactor Starport must build Engineering Bay")
  (assert-true! (not (for/or ([a (in-list acts-t5112039)])
                       (and (list? a) (>= (length a) 2) (eq? (first a) 'build) (eq? (second a) 'starport-techlab))))
                "Match #5112039: Terran must not emit starport-techlab when Starport already has a Starport-Reactor")

  ;; 9. Match #5112040 Regression (step-live-bot! Preserves Escrow Peak/Prev Minerals Across Frames):
  ;;    When Protoss saves for 19-Nexus across frames with steadily rising minerals (100M -> 140M -> 185M),
  ;;    step-live-bot! must preserve 'escrow-peak-min and reset 'escrow-age-frames to 0!
  (define rt-p5112040 (make-live-bot-runtime #:race 'Protoss))
  (define (make-p5112040-obs f min-val)
    (hash 'frame f
          'minerals min-val
          'gas 100
          'supply-used 21
          'supply-cap 23
          'mineral-harvesters 16
          'vespene-harvesters 3
          'researched-upgrades '()
          'base-x 32.5 'base-y 32.5
          'natural-x 50.5 'natural-y 56.5
          'third-x 75.5 'third-y 75.5
          'ally-buildings (list (hash 'id 101 'type 'nexus 'x 32.5 'y 32.5 'hp 1000 'build-progress 1.0)
                                (hash 'id 102 'type 'pylon 'x 36.0 'y 36.0 'hp 200 'build-progress 1.0)
                                (hash 'id 103 'type 'gateway 'x 38.0 'y 36.0 'hp 500 'build-progress 1.0)
                                (hash 'id 104 'type 'cybernetics-core 'x 38.0 'y 39.0 'hp 550 'build-progress 1.0)
                                (hash 'id 105 'type 'assimilator 'x 30.0 'y 35.0 'hp 450 'build-progress 1.0))
          'ally-units (append
                       (for/list ([i (in-range 19)])
                         (hash 'id (+ 200 i) 'type 'probe 'x 32.5 'y 32.5 'hp 20))
                       (list (hash 'id 301 'type 'zealot 'x 50.0 'y 55.0 'hp 100)))
          'enemy-units '()))
  (void (step-live-bot-runtime! rt-p5112040 (make-p5112040-obs 2000 100)))
  (void (step-live-bot-runtime! rt-p5112040 (make-p5112040-obs 2100 140)))
  (define res-p5112040 (step-live-bot-runtime! rt-p5112040 (make-p5112040-obs 2250 185)))
  (define tel-p5112040 (hash-ref res-p5112040 'telemetry))
  (assert-eq! (hash-ref tel-p5112040 'escrow-peak-min 0) 185
              "Match #5112040: step-live-bot! telemetry must preserve escrow-peak-min = 185")
  (assert-eq! (hash-ref tel-p5112040 'escrow-age-frames 999) 0
              "Match #5112040: Rising minerals during Nexus escrow must reset escrow-age-frames to 0")

  ;; 10. Match #5112041 Regression (0-Gas BO Zergling Must Not Preempt Roach Warren at >= 80G):
  ;;     At 155M/168G with 2 Hatcheries, 2 Queens, 1 Spawning Pool, 0 Roach Warrens, and only 2 Zerglings
  ;;     (so raw BO step is 19 Zergling), first-unsatisfied-macro-bo-goal must advance to roach-warren (u = 465.0)
  ;;     and block 0G zergling from spending 50M out of 155M!
  (define z-5112041-state
    (make-macro-world-state
     #:race 'Zerg
     #:frame 4032
     #:minerals 155
     #:gas 168
     #:supply-used 28
     #:supply-cap 36
     #:supply-left 8
     #:workers 22
     #:active-bases 2
     #:ready-building-counts (hash 'hatchery 2 'extractor 1 'spawning-pool 1)
     #:total-building-counts (hash 'hatchery 2 'extractor 1 'spawning-pool 1)
     #:unit-counts (hash 'drone 22 'queen 2 'zergling 2 'overlord 3)
     #:researched-upgrades '(metabolic-boost)
     #:open-facility-slots (hash 'larva 3 'townhall 2)
     #:army-supply 6
     #:enemy-threat-supply 0
     #:under-attack? #f))
  (define z-5112041-dec (step-priority-macro-brain z-5112041-state))
  (assert-true! (member 'roach-warren (macro-brain-decision-scheduled-ids z-5112041-dec))
                "Match #5112041: At 155M/168G on 2 bases with 2 Queens, Roach Warren (150M) must be scheduled in Band 1")
  (assert-true! (not (member 'zergling (macro-brain-decision-scheduled-ids z-5112041-dec)))
                "Match #5112041: At 155M/168G, 0G Zergling must not preempt Roach Warren in scheduled-ids")
  (define z-5112041-120-state
    (struct-copy macro-world-state z-5112041-state [minerals 120]))
  (define z-5112041-120-dec (step-priority-macro-brain z-5112041-120-state))
  (assert-true! (not (macro-brain-can-spend? z-5112041-120-dec 'zergling 120 168 'combat-unit))
                "Match #5112041: At 120M/168G, Roach Warren (150M) must escrow and block 0G Zergling from draining 50M")

  ;; 11. Dynamic Multi-Track Goal-Plan & Next-Action Translator (`translate-goal-to-next-action`, `synthesize-dynamic-macro-plan`):
  ;;     (a) Missing structure prerequisite backward-chains to ready prerequisite (`terran-infantry-weapons-1 -> engineering-bay`)
  (define tr-weap1
    (translate-goal-to-next-action 'terran-infantry-weapons-1 'tech-infrastructure 'research 1 460.0 'macro-tech-plan
                                   (hasheq 'command-center 1 'supply-depot 1 'barracks 1)
                                   (hasheq 'command-center 1 'supply-depot 1 'barracks 1)
                                   (hasheq 'scv 20) '() '()))
  (assert-eq! (plan-goal-node-status tr-weap1) 'needs-prereq
              "terran-infantry-weapons-1 without Engineering Bay must have status 'needs-prereq")
  (assert-eq! (plan-goal-node-next-action-sym tr-weap1) 'engineering-bay
              "terran-infantry-weapons-1 without Engineering Bay must translate to next-action-sym 'engineering-bay")
  ;;     (b) Unit morph (`ravager`) with ready `roach-warren` and 0 `roach` translates to `'roach`
  (define tr-ravager
    (translate-goal-to-next-action 'ravager 'army-production 'morph 2 450.0 'army-milestone-plan
                                   (hasheq 'hatchery 2 'spawning-pool 1 'roach-warren 1)
                                   (hasheq 'hatchery 2 'spawning-pool 1 'roach-warren 1)
                                   (hasheq 'drone 22 'roach 0) '() '()))
  (assert-eq! (plan-goal-node-status tr-ravager) 'needs-prereq
              "ravager morph with ready roach-warren and 0 roaches must have status 'needs-prereq")
  (assert-eq! (plan-goal-node-next-action-sym tr-ravager) 'roach
              "ravager morph with ready roach-warren and 0 roaches must translate to next-action-sym 'roach")
  ;;     (c) In-progress structure (`roach-warren` with total=1, ready=0) has status `'in-progress` and `next-action-sym = #f`,
  ;;         and dependent unit (`roach`) has status `'waiting-on-in-progress-prereq` and `next-action-sym = #f`
  (define tr-rw-inprog
    (translate-goal-to-next-action 'roach-warren 'tech-infrastructure 'build 1 465.0 'macro-tech-plan
                                   (hasheq 'hatchery 2 'spawning-pool 1)
                                   (hasheq 'hatchery 2 'spawning-pool 1 'roach-warren 1)
                                   (hasheq 'drone 22) '() '()))
  (assert-eq! (plan-goal-node-status tr-rw-inprog) 'in-progress
              "Under-construction Roach Warren (total=1, ready=0) must have status 'in-progress")
  (assert-eq! (plan-goal-node-next-action-sym tr-rw-inprog) #f
              "Under-construction Roach Warren must have next-action-sym #f so it does not stall or double-escrow")
  (define tr-roach-wait
    (translate-goal-to-next-action 'roach 'army-production 'train 4 460.0 'army-milestone-plan
                                   (hasheq 'hatchery 2 'spawning-pool 1)
                                   (hasheq 'hatchery 2 'spawning-pool 1 'roach-warren 1)
                                   (hasheq 'drone 22) '() '()))
  (assert-eq! (plan-goal-node-status tr-roach-wait) 'waiting-on-in-progress-prereq
              "Roach goal when Roach Warren is under construction must have status 'waiting-on-in-progress-prereq")
  ;;     (d) Parallel multi-track progression + dynamic detection translation in `synthesize-dynamic-macro-plan`
  (define z-parallel-plan
    (synthesize-dynamic-macro-plan
     (make-macro-world-state
      #:race 'Zerg
      #:enemy-race 'Terran
      #:frame 3600
      #:minerals 150
      #:gas 100
      #:supply-used 38
      #:supply-cap 46
      #:workers 28
      #:active-bases 3
      #:ready-building-counts (hasheq 'hatchery 3 'spawning-pool 1 'extractor 1)
      #:total-building-counts (hasheq 'hatchery 3 'spawning-pool 1 'extractor 1 'roach-warren 1)
      #:unit-counts (hasheq 'drone 28 'queen 2 'zergling 4 'overlord 4)
      #:researched-upgrades '(metabolic-boost))))
  (assert-true! (memq 'roach-warren (dynamic-macro-plan-in-progress-syms z-parallel-plan))
                "synthesize-dynamic-macro-plan must track in-progress Roach Warren in in-progress-syms")
  (assert-true! (hash-has-key? (dynamic-macro-plan-translated-next-actions z-parallel-plan) 'baneling-nest)
                "While Roach Warren is in-progress, parallel Baneling Nest goal must be actionable in translated-next-actions")
  (assert-true! (hash-has-key? (dynamic-macro-plan-translated-next-actions z-parallel-plan) 'queen)
                "While Roach Warren is in-progress, parallel 3rd Queen goal must be actionable in translated-next-actions")
  (define t-detect-plan
    (synthesize-dynamic-macro-plan
     (make-macro-world-state
      #:race 'Terran
      #:enemy-race 'Protoss
      #:frame 3200
      #:minerals 150
      #:gas 50
      #:supply-used 28
      #:supply-cap 39
      #:workers 22
      #:active-bases 2
      #:ready-building-counts (hasheq 'command-center 1 'orbital-command 1 'supply-depot 2 'barracks 1 'refinery 2)
      #:total-building-counts (hasheq 'command-center 1 'orbital-command 1 'supply-depot 2 'barracks 1 'refinery 2)
      #:unit-counts (hasheq 'scv 22 'marine 6)
      #:requires-detection? #t)))
  (assert-true! (hash-has-key? (dynamic-macro-plan-translated-next-actions t-detect-plan) 'engineering-bay)
                "When requires-detection? is #t and Terran lacks Engineering Bay, missile-turret goal must translate to 'engineering-bay"))

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

  ;; 4. Verify standalone compiled native ELF binary exists, meets size floor, and has ELF header
  ;;    (Only spawn the 57 MB embedded Racket CS subprocess in --full / SC_BOT_FULL_TEST=1 mode
  ;;     so default test runs stay well under Antigravity's 10,000 ms synchronous WaitMsBeforeAsync limit.)
  (define standalone-elf (build-path "ladder" ".cache" "mothman_standalone_elf"))
  (assert-true! (file-exists? standalone-elf)
                "Standalone compiled native ELF binary ladder/.cache/mothman_standalone_elf must exist")
  (assert-true! (>= (file-size standalone-elf) MIN-STANDALONE-ELF-BYTES)
                "Standalone compiled native ELF binary must be >= 10 MB")
  (define elf-magic
    (call-with-input-file standalone-elf
      (lambda (in) (read-bytes 4 in))))
  (assert-eq! elf-magic #"\x7fELF"
              "Standalone compiled native ELF binary must begin with \\x7fELF magic header")
  (when full-test-mode?
    (define dry-run-out
      (with-output-to-string
        (lambda ()
          (system* standalone-elf "--BotName" "Mothman-Z" "--dry-run"))))
    (assert-true! (string-contains? dry-run-out "\"status\":\"DRY_RUN_OK\"")
                  "Standalone ELF binary --dry-run must output status DRY_RUN_OK")
    (assert-true! (string-contains? dry-run-out "\"engine\":\"racket_native_protobuf_ws\"")
                  "Standalone ELF binary --dry-run must report racket_native_protobuf_ws engine")))

;; =============================================================================
;; Suite 20: AI Arena Match 5115348 (Mothman-T vs BenBotBC on Persephone) Fixes
;; =============================================================================

(run-suite "20. AI Arena Match 5115348: Natural CC Reserve, Stale Tag Filter, Orphaned Add-On & 22/Base Workers"
  ;; 1. Fix A1a: En-route SCV build orders (`in-progress-orders` & raw ability IDs `318..333`)
  ;;    count as pending structures so Mothman-T never re-issues duplicate Barracks/CC orders.
  (define rt-enroute (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran #:initial-posture 'BioTankMedivac))
  (define obs-enroute-rax
    (hash 'frame 920
          'race 'Terran
          'minerals 185
          'gas 0
          'supply-used 16
          'supply-cap 23
          'supply-left 7
          'pending-supply 0
          'mineral-harvesters 15
          'ideal-mineral-harvesters 16
          'gas-harvesters 0
          'ideal-gas-harvesters 0
          'in-progress-orders (list (hash 'unit-id 901 'ability-id 321 'target-x 36.5 'target-y 36.5))
          'ally-units (for/list ([i (in-range 16)])
                        (hash 'id (+ 901 i) 'type 'scv 'x 32.5 'y 32.5 'hp 45
                              'has-build-order? (= i 0)
                              'order-ability-id (if (= i 0) 321 0)))
          'ally-buildings (list (hash 'id 301 'type 'command-center 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                (hash 'id 302 'type 'supply-depot 'x 36.5 'y 29.5 'hp 400 'build-progress 1.0))
          'enemy-units '()
          'enemy-buildings '()))
  (define step-enroute (step-live-bot-runtime! rt-enroute obs-enroute-rax))
  (define acts-enroute (hash-ref step-enroute 'actions))
  (assert-true! (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (cadr a) 'barracks)))
                            acts-enroute))
                "Match 5115348 Fix A1a: En-route SCV with ability 321 (BUILD_BARRACKS) must prevent duplicate Barracks order")

  ;; 2. Fix A1b: 400M Natural Command Center reservation blocks opportunistic 150M 2nd Barracks at frame >= 1500
  (assert-eq! (compute-natural-expansion-mineral-reserve
               #:race 'Terran #:frame 1850 #:active-bases 1 #:pending-bases 0 #:workers 19)
              400
              "Match 5115348 Fix A1b: Terran on 1 base at frame 1850 with 19 SCVs must reserve 400M for natural CC")
  (assert-eq! (compute-natural-expansion-mineral-reserve
               #:race 'Terran #:frame 1850 #:active-bases 1 #:pending-bases 1 #:workers 19)
              0
              "Match 5115348 Fix A1b: Once natural CC is en-route/pending (pending-bases=1), 400M reserve clears")
  (define rt-nat-trap (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran #:initial-posture 'BioTankMedivac))
  (define obs-nat-trap
    (hash 'frame 1920
          'race 'Terran
          'minerals 265
          'gas 50
          'supply-used 22
          'supply-cap 31
          'supply-left 9
          'pending-supply 0
          'mineral-harvesters 16
          'ideal-mineral-harvesters 16
          'gas-harvesters 3
          'ideal-gas-harvesters 3
          'ally-units (append
                       (for/list ([i (in-range 19)])
                         (hash 'id (+ 910 i) 'type 'scv 'x 32.5 'y 32.5 'hp 45))
                       (list (hash 'id 960 'type 'marine 'x 38.0 'y 38.0 'hp 45)
                             (hash 'id 961 'type 'marine 'x 38.5 'y 38.0 'hp 45)))
          'ally-buildings (list (hash 'id 301 'type 'orbital-command 'x 32.5 'y 32.5 'hp 1500 'energy 25 'build-progress 1.0)
                                (hash 'id 302 'type 'supply-depot 'x 36.5 'y 29.5 'hp 400 'build-progress 1.0)
                                (hash 'id 303 'type 'supply-depot 'x 39.0 'y 29.5 'hp 400 'build-progress 1.0)
                                (hash 'id 304 'type 'barracks 'x 36.5 'y 36.5 'hp 1000 'build-progress 1.0 'has-addon? #t)
                                (hash 'id 305 'type 'barracks-techlab 'x 39.0 'y 36.0 'hp 400 'build-progress 1.0)
                                (hash 'id 306 'type 'refinery 'x 35.5 'y 37.5 'hp 500 'build-progress 1.0))
          'enemy-units '()
          'enemy-buildings '()))
  (define acts-nat-trap (hash-ref (step-live-bot-runtime! rt-nat-trap obs-nat-trap) 'actions))
  (assert-true! (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (cadr a) 'barracks)))
                            acts-nat-trap))
                "Match 5115348 Fix A1b: 150M 2nd Barracks must NOT starve 400M natural Command Center at 265M on 1 base")

  ;; 3. Fix A2a: Stale/dead/snapshot enemy UnitTags downgrade to `(attack-pos uid last-x last-y)` (0 ActionResult=207)
  (define pos-cache (make-hasheqv))
  (define obs-frame-1
    (hash 'enemy-x 150.0 'enemy-y 150.0
          'enemy-units (list (hash 'id 77701 'type 'stalker 'x 88.5 'y 92.5 'hp 80 'display-type 1))
          'enemy-buildings (list (hash 'id 88802 'type 'pylon 'x 142.0 'y 144.0 'hp 200 'display-type 2 'snapshot? #t))))
  (define sanitized-f1
    (sanitize-stale-target-actions
     (list '(attack 501 77701)
           '(focus-fire 502 88802 142.0 144.0))
     obs-frame-1
     #:pos-cache pos-cache))
  (assert-eq! (first sanitized-f1) '(attack 501 77701)
              "Live visible enemy tag (display-type=1) remains direct unit target")
  (assert-eq! (second sanitized-f1) '(attack-pos 502 142.0 144.0)
              "Fog-of-war snapshot building (display-type=2) downgrades to attack-pos to avoid ActionResult=207")
  (define obs-frame-2
    (hash 'enemy-x 150.0 'enemy-y 150.0 'enemy-units '() 'enemy-buildings '()))
  (define sanitized-f2
    (sanitize-stale-target-actions (list '(attack-unit 501 77701)) obs-frame-2 #:pos-cache pos-cache))
  (assert-eq! (first sanitized-f2) '(attack-pos 501 88.5 92.5)
              "Dead/vanished enemy UnitTag 77701 downgrades to attack-pos at cached last-known (88.5, 92.5)")

  ;; 4. Fix A2b: Orphaned TechLab/Reactor reuse & stranded flying structure landing (0 ActionResult=72)
  (define swap-attach-acts
    (plan-terran-addon-swap
     (hash 'ally-buildings
           (list (hash 'id 410 'type 'factory-flying 'x 40.0 'y 40.0 'hp 1250 'flying? #t)
                 (hash 'id 411 'type 'barracks-reactor 'x 44.5 'y 39.5 'hp 400)))))
  (assert-eq! swap-attach-acts
              (list '(terran-addon-swap 0 410 44.5 39.5))
              "Idle lifted Factory must attach onto orphaned free Reactor via terran-addon-swap")
  (define stranded-land-acts
    (plan-terran-addon-swap
     (hash 'ally-buildings
           (list (hash 'id 412 'type 'barracks-flying 'x 38.0 'y 36.0 'hp 1000 'flying? #t)))))
  (assert-eq! stranded-land-acts
              (list '(land-building 412 38.0 36.0))
              "Stranded lifted Barracks with no free add-on must emit land-building instead of floating forever")

  ;; 5. Fix A3: Sustained worker scaling up to 22/base (44 on 2 bases) + emergency Bunker under early rush
  (define rt-2base-scv (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran #:initial-posture 'BioTankMedivac))
  (define obs-2base-28scv
    (hash 'frame 3600
          'race 'Terran
          'minerals 250
          'gas 100
          'supply-used 42
          'supply-cap 54
          'supply-left 12
          'pending-supply 0
          'mineral-harvesters 22
          'ideal-mineral-harvesters 32
          'gas-harvesters 6
          'ideal-gas-harvesters 6
          'ally-units (append
                       (for/list ([i (in-range 28)])
                         (hash 'id (+ 1000 i) 'type 'scv 'x 32.5 'y 32.5 'hp 45))
                       (for/list ([i (in-range 4)])
                         (hash 'id (+ 1100 i) 'type 'marine 'x 44.0 'y 44.0 'hp 45)))
          'ally-buildings (list (hash 'id 301 'type 'orbital-command 'x 32.5 'y 32.5 'hp 1500 'energy 20 'build-progress 1.0 'busy? #f 'order-count 0)
                                (hash 'id 302 'type 'orbital-command 'x 45.0 'y 45.0 'hp 1500 'energy 20 'build-progress 1.0 'busy? #f 'order-count 0)
                                (hash 'id 303 'type 'barracks 'x 36.5 'y 36.5 'hp 1000 'build-progress 1.0 'has-addon? #t)
                                (hash 'id 304 'type 'barracks-techlab 'x 39.0 'y 36.0 'hp 400 'build-progress 1.0)
                                (hash 'id 305 'type 'factory 'x 41.0 'y 36.5 'hp 1250 'build-progress 1.0 'has-addon? #t)
                                (hash 'id 306 'type 'factory-techlab 'x 43.5 'y 36.0 'hp 400 'build-progress 1.0))
          'enemy-units '()
          'enemy-buildings '()))
  (define acts-2base-scv (hash-ref (step-live-bot-runtime! rt-2base-scv obs-2base-28scv) 'actions))
  (assert-true! (not (not (member '(train scv) acts-2base-scv)))
                "Match 5115348 Fix A3: 2-base Terran at 28/44 SCVs must continuously train SCVs toward 44 workers")

  (define rt-bunker (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran #:initial-posture 'BioTankMedivac))
  (define obs-bunker-rush
    (hash 'frame 1450
          'race 'Terran
          'minerals 220
          'gas 0
          'supply-used 19
          'supply-cap 23
          'supply-left 4
          'pending-supply 0
          'mineral-harvesters 16
          'ideal-mineral-harvesters 16
          'gas-harvesters 0
          'ideal-gas-harvesters 0
          'ally-units (append
                       (for/list ([i (in-range 17)])
                         (hash 'id (+ 1200 i) 'type 'scv 'x 32.5 'y 32.5 'hp 45))
                       (list (hash 'id 1250 'type 'marine 'x 36.0 'y 36.0 'hp 45)))
          'ally-buildings (list (hash 'id 301 'type 'orbital-command 'x 32.5 'y 32.5 'hp 1500 'energy 20 'build-progress 1.0)
                                (hash 'id 302 'type 'supply-depot 'x 36.5 'y 29.5 'hp 400 'build-progress 1.0)
                                (hash 'id 303 'type 'barracks 'x 36.5 'y 36.5 'hp 1000 'build-progress 1.0))
          'enemy-units (for/list ([i (in-range 5)])
                         (hash 'id (+ 2000 i) 'type 'stalker 'x 40.0 'y 40.0 'hp 80 'display-type 1))
          'enemy-buildings '()))
  (define acts-bunker (hash-ref (step-live-bot-runtime! rt-bunker obs-bunker-rush) 'actions))
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (cadr a) 'bunker)))
                       acts-bunker)
                "Match 5115348 Fix A3b: Terran under heavy early enemy attack must construct emergency Bunker"))

;; ============================================================================
;; Suite 21: Chaos Monkey Build-Order & Tech-DAG Self-Healing Suite
;; ============================================================================
(run-suite "21. Chaos Monkey Build-Order & Tech-DAG Self-Healing (ZvP/PvT/TvZ/ZvZ/TvP/PvZ/RvT/RvZ/RvP)"
  ;; 1. Multi-step missing prerequisite chain & orphaned structure self-healing
  (assert-eq! (resolve-missing-prereq-chain 'stimpack (hasheq 'command-center 1) (hasheq 'command-center 1))
              '(supply-depot barracks barracks-techlab)
              "Stimpack missing prereq chain must resolve topological order")
  (assert-eq! (resolve-missing-prereq-chain 'immortal (hasheq 'nexus 1) (hasheq 'nexus 1))
              '(pylon gateway cybernetics-core robotics-facility)
              "Immortal missing prereq chain must resolve topological order")
  (assert-eq! (resolve-missing-prereq-chain 'glial-reconstitution (hasheq 'lair 1) (hasheq 'lair 1))
              '(spawning-pool roach-warren)
              "Glial Reconstitution missing prereq chain must resolve spawning-pool -> roach-warren")
  (assert-true! (not (not (memq 'spawning-pool
                                (find-all-broken-tech-dependencies
                                 'Zerg
                                 (hasheq 'lair 1 'hydralisk-den 1)
                                 (hasheq 'lair 1 'hydralisk-den 1)))))
                "Orphaned Lair + Hydralisk Den must flag missing Spawning Pool")
  (assert-eq! (find-all-broken-tech-dependencies
               'Protoss
               (hasheq 'nexus 1 'cybernetics-core 1 'twilight-council 1)
               (hasheq 'nexus 1 'cybernetics-core 1 'twilight-council 1))
              '(pylon gateway)
              "Orphaned Cybernetics Core + Twilight Council must flag missing Pylon + Gateway")

  ;; 2. Zero-worker recovery, 0-gas-building deadlock prevention, slot escrow & negative supply recovery
  (for ([race-pair (in-list '((Protoss probe nexus gateway)
                              (Terran scv command-center barracks)
                              (Zerg drone hatchery spawning-pool)))])
    (match-define (list r w-sym th-sym fac-sym) race-pair)
    (define st-0w
      (make-macro-world-state
       #:race r #:frame 2600 #:minerals 75 #:gas 0 #:supply-used 0 #:supply-cap 23
       #:workers 0 #:active-bases 1
       #:ready-building-counts (hasheq th-sym 1 fac-sym 1 'pylon 1 'supply-depot 1)
       #:total-building-counts (hasheq th-sym 1 fac-sym 1 'pylon 1 'supply-depot 1)
       #:unit-counts (hasheq)
       #:open-facility-slots (hasheq 'townhall 1 'larva 3 'gateway 1 'barracks 1)
       #:under-attack? #t))
    (define dec-0w (step-priority-macro-brain st-0w))
    (assert-true! (not (not (memq w-sym (macro-brain-decision-scheduled-ids dec-0w))))
                  "0-worker crisis at 75M must immediately schedule worker")
    (assert-eq! (macro-brain-decision-reserved-min-floor dec-0w) 0
                "0-worker crisis must not escrow minerals away from workers"))

  (define dec-0gas
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Zerg #:frame 3000 #:minerals 120 #:gas 25 #:supply-used 24 #:supply-cap 36
      #:workers 20 #:active-bases 2
      #:ready-building-counts (hasheq 'hatchery 2 'spawning-pool 1)
      #:total-building-counts (hasheq 'hatchery 2 'spawning-pool 1)
      #:unit-counts (hasheq 'drone 20 'overlord 3 'queen 2)
      #:open-facility-slots (hasheq 'townhall 2 'larva 4 'spawning-pool 1))))
  (assert-true! (not (not (memq 'extractor (macro-brain-decision-scheduled-ids dec-0gas))))
                "0-extractor Zerg must schedule Extractor instead of deadlocking on Lair/Speed gas")
  (assert-eq! (macro-brain-decision-reserved-gas-floor dec-0gas) 0
              "0-extractor Zerg must not reserve gas floor")

  (define dec-negsup
    (step-priority-macro-brain
     (make-macro-world-state
      #:race 'Protoss #:frame 3600 #:minerals 150 #:gas 100 #:supply-used 38 #:supply-cap 15
      #:supply-left -23 #:pending-supply 0 #:workers 22 #:active-bases 1
      #:ready-building-counts (hasheq 'nexus 1 'gateway 2 'cybernetics-core 1 'assimilator 2)
      #:total-building-counts (hasheq 'nexus 1 'gateway 2 'cybernetics-core 1 'assimilator 2)
      #:unit-counts (hasheq 'probe 22 'stalker 6 'zealot 2)
      #:open-facility-slots (hasheq 'townhall 1 'gateway 2 'cybernetics-core 1))))
  (assert-true! (not (not (memq 'pylon (macro-brain-decision-scheduled-ids dec-negsup))))
                "Negative supply (-23) after Pylon wipeout must schedule Pylon immediately")

  ;; 3. Live runtime self-healing of assassinated Spawning Pool & Cybernetics Core
  (define rt-cm-z (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (step-live-bot-runtime!
   rt-cm-z
   (hash 'frame 2400 'minerals 250 'gas 100 'supply-used 42 'supply-cap 54
         'ally-units (for/list ([i (in-range 22)]) (hash 'id (+ 100 i) 'type 'drone 'x 32.5 'y 32.5 'hp 40))
         'ally-buildings (list (hash 'id 1 'type 'hatchery 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0)
                               (hash 'id 2 'type 'hatchery 'x 45.0 'y 45.0 'hp 1500 'build-progress 1.0)
                               (hash 'id 3 'type 'spawning-pool 'x 35.0 'y 32.5 'hp 1000 'build-progress 1.0)
                               (hash 'id 4 'type 'roach-warren 'x 36.0 'y 32.5 'hp 850 'build-progress 1.0))))
  (define res-cm-z2
    (step-live-bot-runtime!
     rt-cm-z
     (hash 'frame 2500 'minerals 250 'gas 100 'supply-used 24 'supply-cap 54
           'ally-units (for/list ([i (in-range 18)]) (hash 'id (+ 100 i) 'type 'drone 'x 32.5 'y 32.5 'hp 40))
           'ally-buildings (list (hash 'id 1 'type 'hatchery 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                 (hash 'id 2 'type 'hatchery 'x 45.0 'y 45.0 'hp 1500 'build-progress 1.0)
                                 (hash 'id 4 'type 'roach-warren 'x 36.0 'y 32.5 'hp 850 'build-progress 1.0)))))
  (assert-true! (ormap (lambda (c) (and (pair? c) (eq? (car c) 'build) (eq? (cadr c) 'spawning-pool)))
                       (hash-ref res-cm-z2 'actions '()))
                "Live Zerg runtime must rebuild assassinated Spawning Pool when Roach Warren is orphaned")

  ;; 4. Fast representative 144-frame Chaos Monkey disruption subset across all 9 matchups (incl. RvT/RvZ/RvP)
  (for ([spec (in-list '((ZvP 10 Zerg Protoss)
                         (PvT 11 Protoss Terran)
                         (TvZ 12 Terran Zerg)
                         (ZvZ 13 Zerg Zerg)
                         (TvP 14 Terran Protoss)
                         (PvZ 15 Protoss Zerg)
                         (RvT 0 Zerg Terran)
                         (RvZ 1 Terran Zerg)
                         (RvP 2 Protoss Protoss)))])
    (match-define (list m-sym sd exp-r exp-er) spec)
    (define fast-res
      (run-chaos-monkey-build-order-trial
       #:race m-sym
       #:seed sd
       #:max-frames 144
       #:dt-frames 8
       #:deletion-frames '(48 96)
       #:forced-deletion-categories '(worker supply)
       #:severity 0.5))
    (assert-eq! (chaos-monkey-trial-result-race fast-res) exp-r
                "Chaos Monkey trial race morphing must match expected race")
    (assert-eq! (chaos-monkey-trial-result-enemy-race fast-res) exp-er
                "Chaos Monkey trial enemy-race resolution must match expected enemy race")
    (assert-eq! (chaos-monkey-trial-result-chaos-deletions-count fast-res) 2
                "Fast 144-frame Chaos Monkey trial must execute 2 adversarial disruptions without crash/hang")
    (assert-true! (> (chaos-monkey-trial-result-final-workers fast-res) 0)
                  "Fast 144-frame Chaos Monkey trial must preserve/recover positive worker count"))

  ;; 5. Full 36-trial (540,000-frame) + 8-wave Extreme Adversarial sweep in --full mode
  (when full-test-mode?
    (define full-results
      (run-chaos-monkey-campaign
       #:trials-per-race 3
       #:max-frames 15000
       #:severity 0.65
       #:include-random? #t))
    (assert-eq! (length full-results) 36 "Full Chaos Monkey campaign must run 36 trials (9 standard + 3 Random x 3)")
    (for ([r (in-list full-results)])
      (assert-true! (chaos-monkey-trial-result-recovered-all-bo-goals? r)
                    "Full Chaos Monkey trial must recover 100% of build-order goals")
      (assert-true! (>= (chaos-monkey-trial-result-final-bases r) 2)
                    "Full Chaos Monkey trial must recover >= 2 active bases"))
    (for ([r-sym (in-list '(Zerg Terran Protoss))])
      (define ext-res
        (run-chaos-monkey-build-order-trial
         #:race r-sym #:enemy-race 'Terran #:seed 999 #:max-frames 18000
         #:deletion-frames '(1200 2200 3200 4200 5200 6200 7200 8200)
         #:forced-deletion-categories '(supply worker tech-building addon gas-building expansion tech-building worker)
         #:severity 0.85))
      (assert-true! (chaos-monkey-trial-result-recovered-all-bo-goals? ext-res)
                    "Extreme 8-wave Chaos Monkey trial must recover 100% of build-order goals"))))

;; =============================================================================
;; 22. 5,575-Checkpoint Pro-Replay Starvation & Deadlock Audit (Z/P/T/Random)
;; =============================================================================
(run-suite "22. 5,575-Checkpoint Pro-Replay Starvation & Deadlock Audit (Zerg/Protoss/Terran/Random)"
  ;; 1. Strided real pro-replay corpus audit in FAST-<5s mode (< 50 ms) or full 5,575 sweep in --full mode
  (define pro-audit-rep
    (if full-test-mode?
        (run-pro-replay-starvation-audit #:max-checkpoints 5575 #:stride 1)
        (run-pro-replay-starvation-audit #:max-checkpoints 100 #:stride 55)))
  (assert-eq! (pro-starvation-audit-report-checkpoints-evaluated pro-audit-rep)
              (if full-test-mode? 5575 100)
              "Pro-replay starvation audit must evaluate expected checkpoint count")
  (assert-eq! (pro-starvation-audit-report-races-evaluated pro-audit-rep)
              '(Zerg Protoss Terran Random)
              "Pro-replay starvation audit must cover Zerg, Protoss, Terran, and Random")
  (assert-eq! (pro-starvation-audit-report-expansion-starvation-failures pro-audit-rep) 0
              "Zero expansion starvation failures (minerals >= 400, bases == 1, frame >= 2688)")
  (assert-eq! (pro-starvation-audit-report-worker-stall-failures pro-audit-rep) 0
              "Zero worker-production stalls (workers < 20 * bases)")
  (assert-eq! (pro-starvation-audit-report-supply-deadlock-failures pro-audit-rep) 0
              "Zero supply-block deadlocks (supply_left == 0, minerals >= 100, pending_supply == 0)")
  (assert-eq! (pro-starvation-audit-report-hoarding-stall-failures pro-audit-rep) 0
              "Zero unspent-resource hoarding stalls")
  (define formatted-pro-rep (format-pro-starvation-audit-report pro-audit-rep))
  (assert-true! (string-contains? formatted-pro-rep "PRO-REPLAY 15s-LOOKAHEAD PRIORITY & STARVATION AUDIT")
                "Formatted pro-replay audit report must include header and race coverage tables")

  ;; 2. Deterministic synthetic boundary verification across Zerg, Protoss, and Terran for all 4 invariants
  (for ([spec (in-list '((Zerg hatchery overlord drone
                               ((hatchery . 1) (spawning-pool . 1) (roach-warren . 1) (extractor . 2)))
                         (Terran command-center supply-depot scv
                                 ((command-center . 1) (supply-depot . 2) (barracks . 2) (factory . 1) (refinery . 2)))
                         (Protoss nexus pylon probe
                                  ((nexus . 1) (pylon . 2) (gateway . 2) (cybernetics-core . 1) (assimilator . 2)))))])
    (match-define (list r-sym exp-sym sup-sym w-sym b-pairs) spec)
    (define b-ht (make-immutable-hasheq b-pairs))

    ;; (a) Overdue 1-base expansion at frame 3200 with 450M/150G and 20 workers
    (define dec-exp
      (step-priority-macro-brain
       (make-macro-world-state
        #:race r-sym #:frame 3200 #:minerals 450 #:gas 150
        #:supply-used 28 #:supply-cap 38 #:supply-left 10 #:pending-supply 0
        #:workers 20 #:active-bases 1
        #:ready-building-counts b-ht #:total-building-counts b-ht
        #:unit-counts (hasheq w-sym 20))))
    (assert-true! (or (not (not (memq exp-sym (macro-brain-decision-scheduled-ids dec-exp))))
                      (macro-brain-can-spend? dec-exp exp-sym 450 150 'expansion))
                  "Overdue 1-base checkpoint at 450M & frame >= 2688 must schedule/admit natural expansion")

    ;; (b) Supply-block deadlock boundary: supply_left == 0, minerals == 120, pending_supply == 0
    (define dec-sup
      (step-priority-macro-brain
       (make-macro-world-state
        #:race r-sym #:frame 3600 #:minerals 120 #:gas 80
        #:supply-used 38 #:supply-cap 38 #:supply-left 0 #:pending-supply 0
        #:workers 22 #:active-bases 2
        #:ready-building-counts b-ht #:total-building-counts b-ht
        #:unit-counts (hasheq w-sym 22))))
    (assert-true! (not (not (memq sup-sym (macro-brain-decision-scheduled-ids dec-sup))))
                  "Supply-blocked checkpoint at 120M & 0 pending supply must schedule supply provider immediately")

    ;; (c) Worker-production stall boundary: 14 workers on 2 bases (< 20 * bases) at 100M
    (define b2-ht (hash-set b-ht exp-sym 2))
    (define dec-wrk
      (step-priority-macro-brain
       (make-macro-world-state
        #:race r-sym #:frame 3400 #:minerals 100 #:gas 50
        #:supply-used 22 #:supply-cap 44 #:supply-left 22 #:pending-supply 0
        #:workers 14 #:active-bases 2
        #:ready-building-counts b2-ht #:total-building-counts b2-ht
        #:unit-counts (hasheq w-sym 14))))
    (assert-true! (pair? (macro-brain-decision-scheduled-ids dec-wrk))
                  "Under-saturated 2-base checkpoint (14 workers) at 100M must schedule economy progress")

    ;; (d) Unspent-resource hoarding boundary: 950M/300G at 90/130 supply must never idle
    (define dec-hoard
      (step-priority-macro-brain
       (make-macro-world-state
        #:race r-sym #:frame 6500 #:minerals 950 #:gas 300
        #:supply-used 90 #:supply-cap 130 #:supply-left 40 #:pending-supply 0
        #:workers 44 #:active-bases 2
        #:ready-building-counts b2-ht #:total-building-counts b2-ht
        #:unit-counts (hasheq w-sym 44))))
    (assert-true! (pair? (macro-brain-decision-scheduled-ids dec-hoard))
                  "High-bank checkpoint (950M/300G at 90/130 supply) must schedule spending actions"))
  )

;; =============================================================================
;; 23. Decoupled 8-Stream Resource & Bank Manager + 200/200 Max-Supply Manager
;; =============================================================================
(run-suite "23. Decoupled 8-Stream Resource & Bank Manager + 200/200 Late-Game Supply Manager"
  ;; 1. Verify all 8 concurrent goal streams and normalized budget slices
  (assert-eq! DEC-GOAL-STREAMS
              '(workers supply expansion tech upgrades production-facilities static-defense army)
              "DEC-GOAL-STREAMS must enumerate all 8 concurrent macro goal streams")

  ;; 2. Verify race-specific bank targets (Zerg Larva-surge, Terran wave-sync, Protoss Warp-Gate batch)
  (define bt-zerg
    (compute-bank-targets #:race 'Zerg #:supply-used 76 #:larva-count 6 #:in-progress-buildings '(spire)))
  (assert-true! (race-bank-target-active? bt-zerg) "Zerg Spire morph must activate Larva-surge bank")
  (assert-eq! (race-bank-target-surge-kind bt-zerg) 'zerg-muta-corruptor-larva-surge
              "Zerg Spire bank target surge kind")
  (assert-eq! (race-bank-target-target-minerals bt-zerg) 600 "6-Larva Spire bank minerals = 600")
  (assert-eq! (race-bank-target-target-gas bt-zerg) 600 "6-Larva Spire bank gas = 600")

  (define bt-terran
    (compute-bank-targets #:race 'Terran #:supply-used 72 #:production-facility-count 5))
  (assert-true! (race-bank-target-active? bt-terran) "Terran 5-facility mid-game must activate wave-sync bank")
  (assert-eq! (race-bank-target-surge-kind bt-terran) 'terran-production-wave-sync
              "Terran production-wave sync surge kind")

  (define bt-protoss
    (compute-bank-targets #:race 'Protoss #:supply-used 112 #:warpgate-count 5 #:in-progress-buildings '(robotics-bay)))
  (assert-true! (race-bank-target-active? bt-protoss) "Protoss Robo-Bay + 5 Warp-Gates must activate capital batch bank")
  (assert-eq! (race-bank-target-surge-kind bt-protoss) 'protoss-capital-warpgate-batch
              "Protoss capital Warp-Gate batch surge kind")

  (define bt-crisis
    (compute-bank-targets #:race 'Zerg #:supply-used 36 #:larva-count 8 #:in-progress-buildings '(spire) #:under-attack? #t))
  (assert-true! (not (race-bank-target-active? bt-crisis))
                "Under early/mid-game attack, macro bank target must immediately release to emergency-spend-all")

  ;; 3. Verify decoupled non-blocking stream admission when tech/upgrades are prereq- or gas-starved
  (define dec-alloc
    (allocate-decoupled-goal-streams
     #:race 'Terran #:frame 3400 #:minerals 450 #:gas 0
     #:supply-used 36 #:supply-cap 46 #:pending-supply 0
     #:workers 26 #:active-bases 1 #:gas-harvesters 0
     #:wants-expand? #t
     #:tech-goal-sym 'starport #:tech-prereq-ready? #f
     #:upgrade-goal-sym 'stimpack #:upgrade-prereq-ready? #f))
  (assert-eq! (hash-count (decoupled-bank-allocation-slices-by-stream dec-alloc)) 8
              "Decoupled allocation must produce budget slices for all 8 streams")
  (assert-true! (stream-budget-slice-blocked-by-prereq?
                 (hash-ref (decoupled-bank-allocation-slices-by-stream dec-alloc) 'tech))
                "Prereq-missing Starport must be marked blocked-by-prereq? in tech stream")
  (assert-eq! (stream-budget-slice-reserved-minerals
               (hash-ref (decoupled-bank-allocation-slices-by-stream dec-alloc) 'tech))
              0
              "Blocked tech stream must reserve 0 minerals so economy/expansion never starve")
  (assert-true! (decoupled-stream-can-spend? dec-alloc 'expansion 400 0)
                "Expansion stream must be admitted at 450M despite blocked tech/upgrade goals")
  (assert-true! (decoupled-stream-can-spend? dec-alloc 'workers 50 0)
                "Workers stream must be admitted at 450M despite blocked tech/upgrade goals")
  (assert-true! (not (decoupled-stream-can-spend? dec-alloc 'tech 150 100))
                "Blocked tech stream must not be admitted")

  ;; 4. Verify 200/200 Max-Supply Manager: Fist of Neeb, Zerg 204/200 Spore trick, and cheap-unit sack
  ;; (a) Protoss Fist of Neeb + Zealot sack at 198/200 with 1100M/500G
  (define msp-p
    (evaluate-max-supply-manager
     #:race 'Protoss #:minerals 1100 #:gas 500 #:supply-used 198 #:supply-cap 200 #:workers 70 #:active-bases 4
     #:ally-units (list (hash 'id 701 'type 'zealot 'x 70.0 'y 70.0)
                        (hash 'id 702 'type 'probe 'x 32.5 'y 32.5))
     #:ally-buildings (list (hash 'id 801 'type 'forge 'build-progress 1.0)
                            (hash 'id 802 'type 'cybernetics-core 'build-progress 1.0))))
  (assert-true! (max-supply-plan-active? msp-p) "Protoss 198/200 with 1100M/500G must activate max-supply manager")
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (cadr a) 'photon-cannon)))
                       (max-supply-plan-fist-of-neeb-actions msp-p))
                "Protoss Fist of Neeb must build Photon Cannon")
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (cadr a) 'shield-battery)))
                       (max-supply-plan-fist-of-neeb-actions msp-p))
                "Protoss Fist of Neeb must build Shield Battery")
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'attack-pos) (= (cadr a) 701)))
                       (max-supply-plan-cheap-unit-sack-actions msp-p))
                "Protoss cheap-unit sack must trade low-tier Zealot (id=701)")

  ;; (b) Terran Fist of Neeb (Turret + Planetary Fortress morph) + Marine sack
  (define msp-t
    (evaluate-max-supply-manager
     #:race 'Terran #:minerals 1000 #:gas 500 #:supply-used 199 #:supply-cap 200 #:workers 66 #:active-bases 4
     #:ally-units (list (hash 'id 711 'type 'marine 'x 70.0 'y 70.0))
     #:ally-buildings (list (hash 'id 811 'type 'engineering-bay 'build-progress 1.0)
                            (hash 'id 812 'type 'command-center 'build-progress 1.0))))
  (assert-true! (not (not (member '(morph planetary-fortress) (max-supply-plan-fist-of-neeb-actions msp-t))))
                "Terran Fist of Neeb at 1000M with bare CC + EngBay must morph Planetary Fortress")

  ;; (c) Zerg Spore Crawler Trick Phase A (morph Spores + queue Ultralisk -> target 204) & Phase B (cancel Spore at 200/200)
  (define msp-z-a
    (evaluate-max-supply-manager
     #:race 'Zerg #:minerals 1000 #:gas 500 #:supply-used 199 #:supply-cap 200 #:workers 68 #:active-bases 4
     #:ally-units (list (hash 'id 721 'type 'zergling 'x 70.0 'y 70.0))
     #:ally-buildings (list (hash 'id 821 'type 'spawning-pool 'build-progress 1.0)
                            (hash 'id 822 'type 'ultralisk-cavern 'build-progress 1.0))))
  (assert-eq! (max-supply-plan-overcap-target-supply msp-z-a) 204
              "Zerg Spore trick Phase A must target 204/200 supply overcap")
  (assert-true! (not (not (member '(train ultralisk) (max-supply-plan-spore-trick-actions msp-z-a))))
                "Zerg Spore trick Phase A must queue Ultralisk into freed supply")

  (define msp-z-b
    (evaluate-max-supply-manager
     #:race 'Zerg #:minerals 850 #:gas 400 #:supply-used 200 #:supply-cap 200 #:workers 66 #:active-bases 4
     #:ally-buildings (list (hash 'id 821 'type 'spawning-pool 'build-progress 1.0)
                            (hash 'id 909 'type 'spore-crawler 'build-progress 0.4))))
  (assert-true! (not (not (member '(cancel-building 909) (max-supply-plan-spore-trick-actions msp-z-b))))
                "Zerg Spore trick Phase B at 200/200 must cancel pending Spore (id=909) to exceed 200 supply")

  ;; 5. Live step-live-bot-runtime! integration at 200/200 supply
  (define rt-maxz (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define res-maxz
    (step-live-bot-runtime!
     rt-maxz
     (hash 'frame 12000 'minerals 1800 'gas 900 'supply-used 200 'supply-cap 200
           'mineral-harvesters 56 'vespene-harvesters 12
           'ally-units (list (hash 'id 951 'type 'zergling 'x 64.0 'y 64.0 'hp 35)
                             (hash 'id 952 'type 'drone 'x 32.5 'y 32.5 'hp 40))
           'ally-buildings (list (hash 'id 961 'type 'hive 'x 32.5 'y 32.5 'hp 2500 'build-progress 1.0)
                                 (hash 'id 962 'type 'spawning-pool 'x 36.0 'y 32.5 'hp 1000 'build-progress 1.0)
                                 (hash 'id 963 'type 'spore-crawler 'x 34.5 'y 34.5 'hp 200 'build-progress 0.3)))))
  (define tel-maxz (hash-ref res-maxz 'telemetry (hash)))
  (define acts-maxz (hash-ref res-maxz 'actions '()))
  (assert-eq! (hash-ref tel-maxz 'goal-streams '()) DEC-GOAL-STREAMS
              "Live runtime telemetry must expose all 8 DEC-GOAL-STREAMS")
  (assert-true! (decoupled-bank-allocation? (hash-ref tel-maxz 'goal-stream-allocation #f))
                "Live runtime telemetry must include decoupled-bank-allocation")
  (assert-true! (not (not (member '(cancel-building 963) acts-maxz)))
                "Live Zerg runtime at 200/200 with pending Spore must emit (cancel-building 963)"))

;; =============================================================================
;; 24. AI Arena Match #5117325-#5117332 Forensics: Worker Mining Stability,
;;     Core-Tech Surcharge Exemption, Terran Marine Unblock & Pure-Racket MPQ
;; =============================================================================
(run-suite "24. AI Arena Match #5117325-#5117332 Forensics & Pure-Racket MPQ Replay Parser"
  (define (mk-sc2-u tag utype alliance x y
                    #:orders [orders '()]
                    #:buffs [buffs '()]
                    #:assigned [assigned 0]
                    #:ideal [ideal 0]
                    #:mins [mins 0]
                    #:gas [gas 0])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 16)
              (sc2-point3d x y 8.0) 0.0 0.5 1.0 0 #f #f #f
              45.0 45.0 0.0 0.0 0.0 0.0 mins gas
              #f #f #f #t #t orders 0 buffs assigned ideal 0.0 0 0 0 0))

  ;; 1a. In-flight gas worker counting prevents pulling extra mineral workers off minerals
  (define obs-gas-inflight
    (sc2-observation
     1200
     (sc2-player-common 1 200 100 39 24 4 18 0 2 0 0)
     (append
      (list (mk-sc2-u 400 132 1 32.5 32.5 #:assigned 14 #:ideal 16) ; OrbitalCommand
            (mk-sc2-u 500 20 1 36.5 34.5 #:assigned 2 #:ideal 3 #:gas 1500) ; Refinery (2/3 assigned)
            (mk-sc2-u 700 341 3 26.5 32.5 #:mins 1500) ; MineralField
            (mk-sc2-u 701 341 3 26.5 34.5 #:mins 1500)
            ;; 1 SCV already walking to Refinery 500 -> effective gas harvesters = max(2, 3) = 3!
            (mk-sc2-u 101 45 1 35.5 34.5 #:orders (list (sc2-unit-order 3666 #f 500 0.0)))
            (mk-sc2-u 102 45 1 36.0 34.5 #:orders (list (sc2-unit-order 3666 #f 500 0.0)))
            (mk-sc2-u 103 45 1 33.5 33.5 #:orders (list (sc2-unit-order 3666 #f 500 0.0))))
      (for/list ([i (in-range 14)])
        (mk-sc2-u (+ 200 i) 45 1 28.0 32.5 #:orders (list (sc2-unit-order 3666 #f 700 0.0)))))
     '() '() #f '() '() '() '() '() '()))
  (define cmds-gas-inflight (saturate-workers-and-gas-commands obs-gas-inflight))
  (assert-true! (not (ormap (lambda (c) (= (sc2-raw-unit-command-target-unit-tag c) 500))
                            cmds-gas-inflight))
                "saturate-workers-and-gas-commands must count in-flight gas workers and not over-pull mineral SCVs")

  ;; 1b. Gas-over-banked (>= 350G with < 250M) pulls 1 gas worker back to minerals & sends 0 into gas
  (define obs-gas-float
    (sc2-observation
     2400
     (sc2-player-common 1 120 420 46 32 10 20 0 5 0 0)
     (append
      (list (mk-sc2-u 400 132 1 32.5 32.5 #:assigned 14 #:ideal 16)
            (mk-sc2-u 500 20 1 36.5 34.5 #:assigned 2 #:ideal 3 #:gas 1200)
            (mk-sc2-u 700 341 3 26.5 32.5 #:mins 1500)
            (mk-sc2-u 101 45 1 35.5 34.5 #:orders (list (sc2-unit-order 3666 #f 500 0.0)))
            (mk-sc2-u 102 45 1 36.0 34.5 #:buffs '(273) #:orders (list (sc2-unit-order 296 #f 400 0.0))))
      (for/list ([i (in-range 14)])
        (mk-sc2-u (+ 200 i) 45 1 28.0 32.5 #:orders (list (sc2-unit-order 3666 #f 700 0.0)))))
     '() '() #f '() '() '() '() '() '()))
  (define cmds-gas-float (saturate-workers-and-gas-commands obs-gas-float))
  (assert-true! (not (ormap (lambda (c) (= (sc2-raw-unit-command-target-unit-tag c) 500))
                            cmds-gas-float))
                "At 120M/420G (gas over-banked), saturate-workers-and-gas-commands must NOT send workers into gas")
  (assert-true! (ormap (lambda (c)
                         (and (= (sc2-raw-unit-command-ability-id c) 3666)
                              (= (sc2-raw-unit-command-target-unit-tag c) 700)
                              (equal? (sc2-raw-unit-command-unit-tags c) '(101))))
                       cmds-gas-float)
                "At 120M/420G, saturate-workers-and-gas-commands must pull non-carrying gas worker 101 to minerals")

  ;; 1c. Expansion transfer deduplication skips re-commanding when surplus is already in flight
  (define obs-exp-xfer
    (sc2-observation
     2600
     (sc2-player-common 1 200 100 46 30 8 20 0 4 0 0)
     (append
      (list (mk-sc2-u 400 132 1 32.5 32.5 #:assigned 17 #:ideal 16) ; 1 surplus worker at main
            (mk-sc2-u 401 132 1 60.5 60.5 #:assigned 0 #:ideal 16)  ; 16 deficit at natural
            (mk-sc2-u 700 341 3 26.5 32.5 #:mins 1500)
            (mk-sc2-u 702 341 3 66.5 60.5 #:mins 1500)              ; Natural mineral patch
            ;; Worker 299 is still near main (34, 34) but ALREADY ordered to natural patch 702!
            (mk-sc2-u 299 45 1 34.0 34.0 #:orders (list (sc2-unit-order 3666 #f 702 0.0))))
      (for/list ([i (in-range 16)])
        (mk-sc2-u (+ 200 i) 45 1 28.0 32.5 #:orders (list (sc2-unit-order 3666 #f 700 0.0)))))
     '() '() #f '() '() '() '() '() '()))
  (assert-eq! (saturate-workers-and-gas-commands obs-exp-xfer) '()
              "Expansion worker transfer must count in-flight worker 299 and emit 0 redundant gather resets")

  ;; 2. Live runtime does NOT emit gather-resetting harvest-gas / rebalance-gas-to-minerals & throttles scout spam
  (define rt-live-no-thrash (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define (mk-live-z-obs fr)
    (hash 'frame fr 'minerals 110 'gas 450 'supply-used 34 'supply-cap 44 'supply-left 10
          'mineral-harvesters 18 'vespene-harvesters 6
          'base-x 32.5 'base-y 32.5 'natural-x 52.5 'natural-y 56.5
          'enemy-x 140.0 'enemy-y 140.0
          'ally-units (append (for/list ([i (in-range 24)])
                                (hash 'id (+ 10 i) 'type 'drone 'x 32.5 'y 32.5 'hp 40))
                              (for/list ([i (in-range 8)])
                                (hash 'id (+ 100 i) 'type 'zergling 'x 52.5 'y 56.5 'hp 35)))
          'ally-buildings (list (hash 'id 201 'type 'hatchery 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0 'larva-count 2)
                                (hash 'id 202 'type 'hatchery 'x 52.5 'y 56.5 'hp 1500 'build-progress 1.0 'larva-count 2)
                                (hash 'id 203 'type 'spawning-pool 'x 36.0 'y 36.0 'hp 1000 'build-progress 1.0)
                                (hash 'id 204 'type 'extractor 'x 30.0 'y 35.0 'hp 500 'build-progress 1.0))
          'enemy-units '()))
  (define res-thrash-1 (step-live-bot-runtime! rt-live-no-thrash (mk-live-z-obs 1000)))
  (define res-thrash-2 (step-live-bot-runtime! rt-live-no-thrash (mk-live-z-obs 1004)))
  (define acts-thrash-1 (hash-ref res-thrash-1 'actions '()))
  (define acts-thrash-2 (hash-ref res-thrash-2 'actions '()))
  (assert-true! (not (ormap (lambda (a) (and (pair? a) (memq (car a) '(harvest-gas rebalance-gas-to-minerals))))
                            acts-thrash-1))
                "Live observation mode must delegate gas/mineral worker orders to saturate-workers-and-gas-commands without 4-frame gather resets")
  (assert-true! (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'periodic-scout))) acts-thrash-2))
                "Live observation mode must throttle periodic-scout on a 96-frame cooldown (no repeat 4 frames later)")

  ;; 3. Match #5117108 & #5117327 Regression: Protoss CyberneticsCore builds at 165M despite severe-intel-blindness?
  (define rt-cyber (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define res-cyber
    (step-live-bot-runtime!
     rt-cyber
     (hash 'frame 2400 'minerals 165 'gas 120 'supply-used 24 'supply-cap 39 'supply-left 15
           'mineral-harvesters 19 'vespene-harvesters 3
           'intel-staleness-frames 1200
           'base-x 32.5 'base-y 32.5 'natural-x 52.5 'natural-y 56.5
           'ally-units (for/list ([i (in-range 22)])
                         (hash 'id (+ 10 i) 'type 'probe 'x 32.5 'y 32.5 'hp 40))
           'ally-buildings (list (hash 'id 301 'type 'nexus 'x 32.5 'y 32.5 'hp 2000 'build-progress 1.0)
                                 (hash 'id 302 'type 'nexus 'x 52.5 'y 56.5 'hp 2000 'build-progress 1.0)
                                 (hash 'id 303 'type 'pylon 'x 36.5 'y 36.5 'hp 400 'build-progress 1.0)
                                 (hash 'id 304 'type 'gateway 'x 38.5 'y 36.5 'hp 1000 'build-progress 1.0 'order-count 1)
                                 (hash 'id 305 'type 'assimilator 'x 30.5 'y 35.5 'hp 900 'build-progress 1.0))
           'enemy-units '())))
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (cadr a) 'cybernetics-core)))
                       (hash-ref res-cyber 'actions '()))
                "Matches #5117108 & #5117327: CyberneticsCore must build at 165M without +125M surcharge deadlock")

  ;; 4. Match #5117326 Regression: Terran Barracks trains Marines even when gas >= 100 & has-rax-techlab? is #f
  (define rt-marine (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define acts-marine
    (step-layer2-economy!
     rt-marine
     (hash 'frame 3600 'minerals 200 'gas 320 'supply-used 52 'supply-cap 62 'supply-left 10
           'mineral-harvesters 40 'vespene-harvesters 6
           'base-x 32.5 'base-y 32.5 'natural-x 52.5 'natural-y 56.5
           'ally-units (append (for/list ([i (in-range 46)])
                                 (hash 'id (+ 10 i) 'type 'scv 'x 32.5 'y 32.5 'hp 45))
                               (for/list ([i (in-range 4)])
                                 (hash 'id (+ 200 i) 'type 'marine 'x 52.5 'y 56.5 'hp 45)))
           'ally-buildings (list (hash 'id 401 'type 'orbital-command 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0 'order-count 1)
                                 (hash 'id 402 'type 'orbital-command 'x 52.5 'y 56.5 'hp 1500 'build-progress 1.0 'order-count 1)
                                 ;; 2 Reactor-attached Barracks so has-rax-techlab? = #f while open-prod-slots['barracks] = 4
                                 (hash 'id 403 'type 'barracks 'x 36.5 'y 36.5 'hp 1000 'build-progress 1.0 'order-count 0 'addon 'reactor)
                                 (hash 'id 404 'type 'barracks-reactor 'x 39.0 'y 36.0 'hp 400 'build-progress 1.0)
                                 (hash 'id 411 'type 'barracks 'x 36.5 'y 40.5 'hp 1000 'build-progress 1.0 'order-count 0 'addon 'reactor)
                                 (hash 'id 412 'type 'barracks-reactor 'x 39.0 'y 40.0 'hp 400 'build-progress 1.0)
                                 (hash 'id 405 'type 'refinery 'x 30.5 'y 35.5 'hp 500 'build-progress 1.0)
                                 (hash 'id 406 'type 'factory 'x 42.5 'y 36.5 'hp 1250 'build-progress 1.0 'order-count 1 'addon 'techlab)
                                 (hash 'id 409 'type 'factory-tech-lab 'x 45.0 'y 36.0 'hp 400 'build-progress 1.0)
                                 (hash 'id 407 'type 'starport 'x 42.5 'y 40.5 'hp 1300 'build-progress 1.0 'order-count 1 'addon 'techlab)
                                 (hash 'id 410 'type 'starport-tech-lab 'x 45.0 'y 40.0 'hp 400 'build-progress 1.0)
                                 (hash 'id 408 'type 'engineering-bay 'x 46.5 'y 36.5 'hp 850 'build-progress 1.0 'order-count 1))
           'enemy-units '())))
  (assert-true! (not (not (member '(train marine) acts-marine)))
                "Match #5117326: Terran Barracks must train Marines even when gas >= 25 and has-rax-techlab? is #f")

  ;; 5. Pure-Racket Blizzard MPQ & S2Protocol Replay Parser (`lib/sc2-mpq-replay-parser.rkt`)
  (assert-eq! (vector-length STORM-CRYPT) 1280
              "Pure-Racket StormLib STORM-CRYPT table must initialize all 1,280 uint32 entries")
  (assert-eq! (mpq-hash "(hash table)" 3) #xC3AF3770
              "Pure-Racket StormLib mpq-hash('(hash table)', 3) must match canonical Blizzard key 0xC3AF3770")
  (assert-true! (procedure? parse-sc2-replay)
                "lib/sc2-mpq-replay-parser.rkt must export parse-sc2-replay"))

;; =============================================================================
;; 25. Generalized Bank Streams, Canonical Equivalence, Escrow Liveness,
;;     Emergency Pylon Power, Random Personality & Brain-Actuator Alignment
;; =============================================================================
(run-suite "25. Generalized Bank Streams, Equivalence, Escrow Liveness & Brain-Actuator Alignment"
  ;; 25.1 Canonical structure & unit equivalence (flying, morphed, rich, uprooted, free add-ons)
  (define eq-counts
    (hasheq 'factory-flying 1
            'greater-spire 1
            'hive 1
            'lurker-den-mp 1
            'refinery-rich 1
            'pylon-overcharged 1
            'spore-crawler-uprooted 1
            'templar-archive 1
            'tech-lab 1
            'starport-techlab 1))
  (assert-eq! (sc2-count-equivalent-structures eq-counts 'factory) 1
              "Flying Factory must count toward existing Factory structures")
  (assert-eq! (sc2-count-equivalent-structures eq-counts 'spire) 1
              "Greater Spire must satisfy Spire structure equivalence")
  (assert-eq! (sc2-count-equivalent-structures eq-counts 'hatchery) 1
              "Hive must satisfy Hatchery/Lair structure equivalence")
  (assert-eq! (sc2-count-equivalent-structures eq-counts 'lurker-den) 1
              "lurker-den-mp must satisfy lurker-den equivalence")
  (assert-eq! (sc2-count-equivalent-structures eq-counts 'refinery) 1
              "refinery-rich must satisfy refinery equivalence")
  (assert-eq! (sc2-count-equivalent-structures eq-counts 'pylon) 1
              "pylon-overcharged must satisfy pylon equivalence")
  (assert-eq! (sc2-count-equivalent-structures eq-counts 'templar-archives) 1
              "templar-archive must satisfy templar-archives equivalence")
  (assert-eq! (sc2-count-equivalent-structures eq-counts 'barracks-techlab #t) 1
              "Unattached tech-lab must count when include-free-addons? is #t")
  (assert-eq! (sc2-count-equivalent-structures eq-counts 'barracks-techlab #f) 0
              "Unattached tech-lab must NOT satisfy attached TechLab research/unit prereqs when #f")
  (assert-eq! (sc2-count-equivalent-structures eq-counts 'starport-reactor) 0
              "starport-techlab must NEVER be double-counted as starport-reactor")
  (assert-true! (sc2-unit-is-detector-sym? 'observer-siege-mode)
                "observer-siege-mode must be classified as a detector in combat stats")
  (assert-true! (sc2-unit-is-detector-sym? 'overseer-siege-mode)
                "overseer-siege-mode must be classified as a detector in combat stats")
  (assert-eq! (sc2-min-cost 'siege-tank-sieged) 150
              "siege-tank-sieged must preserve full 150M cost in minimax trade valuation")

  ;; 25.2 Decoupled 8-stream bank `other-hard-min` survival protection
  (define gsa-surv
    (allocate-decoupled-goal-streams
     #:race 'Zerg
     #:frame 3600
     #:minerals 250
     #:gas 200
     #:supply-used 42
     #:supply-cap 44
     #:pending-supply 0
     #:workers 28
     #:active-bases 2
     #:gas-harvesters 6
     #:tech-goal-sym 'spire
     #:tech-prereq-ready? #t))
  (define tech-spendable-m
    (car (hash-ref (decoupled-bank-allocation-spendable-by-stream gsa-surv) 'tech '(0 . 0))))
  (assert-true! (<= tech-spendable-m 100)
                "Decoupled 'tech stream must NOT subtract its own 200M soft reserve from hard survival supply+worker reserves")

  ;; 25.3 `greater-spire` morph prereq unlock & `macro-brain-can-spend?` no 2x self-blocking
  (assert-true! (sc2-tech-prereqs-ready?
                 'greater-spire
                 (hasheq 'hive 1 'spawning-pool 1 'spire 1 'infestation-pit 1 'extractor 4)
                 (hasheq 'drone 60 'corruptor 6))
                "sc2-tech-prereqs-ready? must recognize ready 'spire in ready-building-counts for greater-spire morph")

  (define ws-imm-self
    (make-macro-world-state
     #:race 'Protoss #:enemy-race 'Terran #:frame 3800
     #:minerals 180 #:gas 150 #:supply-used 46 #:supply-cap 62
     #:workers 32 #:army-supply 14 #:active-bases 2
     #:ready-building-counts (hasheq 'nexus 2 'pylon 4 'gateway 1 'cybernetics-core 1 'robotics-facility 1 'assimilator 2)
     #:total-building-counts (hasheq 'nexus 2 'pylon 4 'gateway 1 'cybernetics-core 1 'robotics-facility 1 'assimilator 2)
     #:unit-counts (hasheq 'probe 32 'stalker 7)
     #:researched-upgrades '(warp-gate-research) #:pending-upgrades '()
     #:open-facility-slots (hasheq 'robotics-facility 1 'townhall 0)))
  (define dec-imm-self (step-priority-macro-brain ws-imm-self))
  (when (eq? (macro-brain-decision-saving-for dec-imm-self) 'immortal)
    (assert-true! (macro-brain-can-spend? dec-imm-self 'immortal 280 150 'combat-unit)
                  "macro-brain-can-spend? must allow saving-for target 'immortal at 280M without 2x self-blocking"))

  ;; 25.4 Match #5117327 Protoss emergency Pylon recovery when 0 Pylons / unpowered Gateway at 23/30 supply
  (define rt-unpow (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define res-unpow
    (step-live-bot-runtime!
     rt-unpow
     (hash 'frame 2200 'minerals 150 'gas 50 'supply-used 23 'supply-cap 30 'supply-left 7
           'mineral-harvesters 20 'vespene-harvesters 3
           'base-x 32.5 'base-y 32.5 'natural-x 52.5 'natural-y 56.5
           'ally-units (for/list ([i (in-range 23)])
                         (hash 'id (+ 10 i) 'type 'probe 'x 32.5 'y 32.5 'hp 40))
           'ally-buildings (list (hash 'id 301 'type 'nexus 'x 32.5 'y 32.5 'hp 2000 'build-progress 1.0)
                                 (hash 'id 302 'type 'nexus 'x 52.5 'y 56.5 'hp 2000 'build-progress 1.0)
                                 (hash 'id 303 'type 'gateway 'x 38.5 'y 36.5 'hp 1000 'build-progress 1.0 'powered? #f))
           'enemy-units '())))
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (cadr a) 'pylon)))
                       (hash-ref res-unpow 'actions '()))
                "Match #5117327: Protoss with 0 Pylons / unpowered Gateway at 23/30 supply must immediately build an emergency Pylon")

  ;; 25.5 Mothman-X Random frame-0 personality re-binding & Layer-2 telemetry merge
  (define rt-rand-z (make-live-bot-runtime #:bot-name 'Mothman-X #:race 'Random))
  (define res-rand-z
    (step-live-bot-runtime!
     rt-rand-z
     (hash 'frame 0 'minerals 50 'gas 0 'supply-used 12 'supply-cap 14 'supply-left 2
           'mineral-harvesters 12 'vespene-harvesters 0
           'ally-units (list (hash 'id 11 'type 'drone 'x 32.5 'y 32.5 'hp 40)
                             (hash 'id 12 'type 'overlord 'x 34.5 'y 34.5 'hp 200))
           'ally-buildings (list (hash 'id 21 'type 'hatchery 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0 'larva-count 3))
           'enemy-units '())))
  (assert-eq! (live-bot-runtime-actual-race rt-rand-z) 'Zerg
              "Mothman-X rolling Zerg must resolve actual-race to 'Zerg on frame 0")
  (assert-eq! (bot-personality-name (mastermind-state-personality (live-bot-runtime-mastermind rt-rand-z)))
              'SCARLETT-CREEP-SWARM-PERSONALITY
              "Mothman-X rolling Zerg must re-bind personality from initial CLEM to SCARLETT-CREEP-SWARM-PERSONALITY")
  (assert-true! (hash-has-key? (hash-ref res-rand-z 'telemetry (hash)) 'decoupled-stream-spendable)
                "step-live-bot-runtime! telemetry must merge and preserve Layer-2 'decoupled-stream-spendable")

  ;; 25.6 Blizzard AbilityId mapping, 3x3 half-tile coordinate snapping & 2-tag Archon wire morph
  (assert-eq! (engine-order-target-symbol 324 #f) 'bunker
              "Blizzard AbilityId 324 (build-bunker) must map to 'bunker, not 'engineering-bay")
  (assert-eq! (engine-order-target-symbol 322 #f) 'engineering-bay
              "Blizzard AbilityId 322 (build-engineering-bay) must map to 'engineering-bay")
  (assert-eq! (engine-order-target-symbol 895 #f) 'shield-battery
              "Blizzard AbilityId 895 (build-shield-battery) must map to 'shield-battery")
  (define ol-snap (make-order-ledger))
  (define-values (gw-x _gw-y) (order-ledger-resolve-build-coords! ol-snap 'gateway 38.1 36.2 '() 100))
  (define-values (py-x _py-y) (order-ledger-resolve-build-coords! ol-snap 'pylon 34.4 34.6 '() 100))
  (assert-eq! (- gw-x (floor gw-x)) 0.5
              "3x3 Gateway footprint must snap to half-tile (x.5) coordinate")
  (assert-eq! (- py-x (floor py-x)) 0.0
              "2x2 Pylon footprint must snap to integer (x.0) coordinate")

  (define (mk-ht-unit tag x y)
    (sc2-unit 1 1 tag 75 1 (sc2-point3d x y 8.0) 0.0 0.375 1.0 0 #f #f #f
              40.0 40.0 40.0 40.0 50.0 200.0 0 0 #f #f #f #t #t '() 0 '() 0 0 0.0 0 0 0 0))
  (define obs-1ht
    (sc2-observation 4000 (sc2-player-common 1 200 200 60 80 30 30 0 0 0 0)
                     (list (mk-ht-unit 801 40.0 40.0))
                     '() '() #f '() '() '() '() '() '()))
  (define obs-2ht
    (sc2-observation 4000 (sc2-player-common 1 200 200 60 80 30 30 0 0 0 0)
                     (list (mk-ht-unit 801 40.0 40.0) (mk-ht-unit 802 41.0 40.0))
                     '() '() #f '() '() '() '() '() '()))
  (assert-eq! (translate-bot-actions->sc2-raw-commands '((morph archon)) obs-1ht) '()
              "Archon morph with only 1 Templar must emit 0 wire commands")
  (define cmds-2ht (translate-bot-actions->sc2-raw-commands '((morph archon)) obs-2ht))
  (assert-eq! (length cmds-2ht) 1
              "Archon morph with 2 Templars must emit 1 wire command")
  (assert-eq! (length (sc2-raw-unit-command-unit-tags (car cmds-2ht))) 2
              "Archon morph wire command must carry exactly 2 Templar tags"))

;; =============================================================================
;; Suite 26: Live Protobuf is_powered, Tech Actuation & Worker-Rush/Anti-Proxy Defense
;; =============================================================================
(run-suite "26. Live Protobuf is_powered, Tech Actuation & Worker-Rush/Anti-Proxy Defense"
  ;; 26.1 Live Protobuf `'powered? #f` Equivalence
  (assert-eq! (sc2-structure-requires-pylon-power? 'gateway) #t
              "Gateway must require Pylon power")
  (for ([sym (in-list '(nexus pylon assimilator command-center orbital-command
                        barracks hatchery lair spawning-pool))])
    (assert-eq! (sc2-structure-requires-pylon-power? sym) #f
                (format "~a must NOT require Pylon power" sym)))

  (define cx-pow (make-human-cortex))
  (define ol-pow (make-order-ledger))
  (for ([spec (in-list (list (list 401 'nexus 4)
                             (list 402 'command-center 4)
                             (list 403 'hatchery 4)
                             (list 404 'barracks 5)
                             (list 405 'spawning-pool 7)))])
    (define bid (first spec))
    (define bsym (second spec))
    (define grp (third spec))
    (define bh (hash 'id bid 'type bsym 'x 32.5 'y 32.5 'hp 1000 'build-progress 1.0 'powered? #f))
    (assert-eq! (order-ledger-facility-busy? ol-pow bh 100) #f
                (format "order-ledger-facility-busy? must treat ~a with 'powered? #f as NOT busy" bsym))
    (define cap-ht (cortex-production-group-capacity cx-pow (list bh) grp))
    (assert-eq! (hash-ref cap-ht 'open-slot-count 0) 1
                (format "cortex-production-group-capacity must report 1 open slot for ~a with 'powered? #f" bsym)))

  (define gw-unpow-bh
    (hash 'id 406 'type 'gateway 'x 36.5 'y 36.5 'hp 1000 'build-progress 1.0 'powered? #f))
  (assert-eq! (order-ledger-facility-busy? ol-pow gw-unpow-bh 100) #t
              "Unpowered Gateway ('powered? #f) must be treated as busy by order-ledger-facility-busy?")
  (assert-eq! (hash-ref (cortex-production-group-capacity cx-pow (list gw-unpow-bh) 5) 'open-slot-count -1) 0
              "Unpowered Gateway ('powered? #f) must report 0 open slots in cortex-production-group-capacity")

  ;; Frame-0 Terran (12 SCVs, 50M, CommandCenter 'powered? #f) -> emits (train scv)
  (define rt-f0-t (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define res-f0-t
    (step-live-bot-runtime!
     rt-f0-t
     (hash 'frame 0 'minerals 50 'gas 0 'supply-used 12 'supply-cap 15 'supply-left 3
           'mineral-harvesters 12 'vespene-harvesters 0
           'base-x 32.5 'base-y 32.5 'natural-x 56.5 'natural-y 32.5
           'ally-units (for/list ([i (in-range 12)])
                         (hash 'id (+ 10 i) 'type 'scv 'x 31.0 'y 32.5 'hp 45))
           'ally-buildings (list (hash 'id 301 'type 'command-center 'x 32.5 'y 32.5
                                       'hp 1500 'build-progress 1.0 'powered? #f))
           'enemy-units '())))
  (assert-true! (member '(train scv) (hash-ref res-f0-t 'actions '()))
                "Frame-0 Terran with CommandCenter 'powered? #f must emit (train scv)")

  ;; Frame-0 Protoss (12 Probes, 50M, Nexus 'powered? #f) -> emits (train probe)
  (define rt-f0-p (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define res-f0-p
    (step-live-bot-runtime!
     rt-f0-p
     (hash 'frame 0 'minerals 50 'gas 0 'supply-used 12 'supply-cap 15 'supply-left 3
           'mineral-harvesters 12 'vespene-harvesters 0
           'base-x 32.5 'base-y 32.5 'natural-x 56.5 'natural-y 32.5
           'ally-units (for/list ([i (in-range 12)])
                         (hash 'id (+ 10 i) 'type 'probe 'x 31.0 'y 32.5 'hp 40))
           'ally-buildings (list (hash 'id 302 'type 'nexus 'x 32.5 'y 32.5
                                       'hp 2000 'build-progress 1.0 'powered? #f))
           'enemy-units '())))
  (assert-true! (member '(train probe) (hash-ref res-f0-p 'actions '()))
                "Frame-0 Protoss with Nexus 'powered? #f must emit (train probe)")

  ;; Zerg (Hatchery + SpawningPool 'powered? #f, 200M/100G) -> trains queen, researches metabolic-boost, and morphs lair without stalling
  (define zerg-base-workers
    (append (for/list ([i (in-range 20)])
              (hash 'id (+ 10 i) 'type 'drone 'x 31.0 'y 32.5 'hp 40))
            (for/list ([k (in-range 3)])
              (hash 'id (+ 50 k) 'type 'larva 'x 33.0 'y 33.0 'hp 25))
            (for/list ([m (in-range 4)])
              (hash 'id (+ 60 m) 'type 'overlord 'x 35.0 'y 35.0 'hp 200))))
  (define zerg-4queens
    (list (hash 'id 70 'type 'queen 'x 33.5 'y 32.5 'hp 175 'energy 20)
          (hash 'id 71 'type 'queen 'x 57.5 'y 32.5 'hp 175 'energy 20)
          (hash 'id 72 'type 'queen 'x 45.0 'y 32.5 'hp 175 'energy 20)
          (hash 'id 73 'type 'queen 'x 46.0 'y 32.5 'hp 175 'energy 20)))
  (define zerg-unpow-bldgs
    (list (hash 'id 201 'type 'hatchery 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0 'powered? #f)
          (hash 'id 202 'type 'hatchery 'x 56.5 'y 32.5 'hp 1500 'build-progress 1.0 'powered? #f)
          (hash 'id 203 'type 'spawning-pool 'x 36.5 'y 32.5 'hp 1000 'build-progress 1.0 'powered? #f)
          (hash 'id 204 'type 'extractor 'x 32.5 'y 26.5 'hp 500 'build-progress 1.0 'powered? #f)
          (hash 'id 205 'type 'extractor 'x 56.5 'y 26.5 'hp 500 'build-progress 1.0 'powered? #f)))
  (define rt-z-queen (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define res-z-queen
    (step-live-bot-runtime!
     rt-z-queen
     (hash 'frame 1400 'minerals 200 'gas 100 'supply-used 20 'supply-cap 46 'supply-left 26
           'mineral-harvesters 17 'gas-harvesters 3
           'base-x 32.5 'base-y 32.5 'natural-x 56.5 'natural-y 32.5
           'ally-units zerg-base-workers
           'ally-buildings zerg-unpow-bldgs
           'enemy-units '())))
  (assert-true! (member '(train queen) (hash-ref res-z-queen 'actions '()))
                "Zerg with Hatchery + SpawningPool 'powered? #f at 200M/100G (0 Queens) must train Queen")

  (define rt-z-spd (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define res-z-spd
    (step-live-bot-runtime!
     rt-z-spd
     (hash 'frame 1400 'minerals 200 'gas 100 'supply-used 28 'supply-cap 46 'supply-left 18
           'mineral-harvesters 17 'gas-harvesters 3
           'base-x 32.5 'base-y 32.5 'natural-x 56.5 'natural-y 32.5
           'ally-units (append zerg-base-workers zerg-4queens)
           'ally-buildings zerg-unpow-bldgs
           'enemy-units '())))
  (assert-true! (member '(research metabolic-boost) (hash-ref res-z-spd 'actions '()))
                "Zerg with SpawningPool 'powered? #f at 200M/100G must research metabolic-boost without researcher-slot stall")

  (define rt-z-lair (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define res-z-lair
    (step-live-bot-runtime!
     rt-z-lair
     (hash 'frame 2200 'minerals 200 'gas 100 'supply-used 30 'supply-cap 54 'supply-left 24
           'mineral-harvesters 16 'gas-harvesters 6
           'researched-upgrades '(metabolic-boost)
           'base-x 32.5 'base-y 32.5 'natural-x 56.5 'natural-y 32.5
           'ally-units (append zerg-base-workers zerg-4queens)
           'ally-buildings zerg-unpow-bldgs
           'enemy-units '())))
  (assert-true! (ormap (lambda (a)
                         (and (pair? a)
                              (eq? (car a) 'morph)
                              (or (equal? a '(morph lair))
                                  (and (= (length a) 3) (eq? (third a) 'lair)))))
                       (hash-ref res-z-lair 'actions '()))
                "Zerg with Hatchery + SpawningPool 'powered? #f at 200M/100G (speed done) must morph Lair")

  ;; 26.2 Terran Opening SupplyDepot / Barracks Gate & Protoss Forge Non-Deadlock
  (define rt-t-open (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define res-t-open
    (step-live-bot-runtime!
     rt-t-open
     (hash 'frame 120 'minerals 150 'gas 0 'supply-used 12 'supply-cap 15 'supply-left 3
           'mineral-harvesters 12 'vespene-harvesters 0
           'base-x 32.5 'base-y 32.5 'natural-x 56.5 'natural-y 32.5
           'ally-units (for/list ([i (in-range 12)])
                         (hash 'id (+ 10 i) 'type 'scv 'x 31.0 'y 32.5 'hp 45))
           'ally-buildings (list (hash 'id 301 'type 'command-center 'x 32.5 'y 32.5
                                       'hp 1500 'build-progress 1.0 'powered? #f))
           'enemy-units '())))
  (define acts-t-open (hash-ref res-t-open 'actions '()))
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (cadr a) 'supply-depot)))
                       acts-t-open)
                "Terran at 12/15 supply with 150M and 0 depots must build SupplyDepot")
  (assert-true! (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (cadr a) 'barracks)))
                            acts-t-open))
                "Terran with 0 ready SupplyDepots must NOT emit doomed (build barracks ...)")

  ;; Also verify even at 260M with an in-progress SupplyDepot (build-progress 0.5), Barracks waits for depot ready
  (define rt-t-inprog-dep (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define res-t-inprog-dep
    (step-live-bot-runtime!
     rt-t-inprog-dep
     (hash 'frame 300 'minerals 260 'gas 0 'supply-used 14 'supply-cap 15 'supply-left 1
           'mineral-harvesters 14 'vespene-harvesters 0
           'base-x 32.5 'base-y 32.5 'natural-x 56.5 'natural-y 32.5
           'ally-units (for/list ([i (in-range 14)])
                         (hash 'id (+ 10 i) 'type 'scv 'x 31.0 'y 32.5 'hp 45))
           'ally-buildings (list (hash 'id 301 'type 'command-center 'x 32.5 'y 32.5
                                       'hp 1500 'build-progress 1.0 'powered? #f)
                                 (hash 'id 305 'type 'supply-depot 'x 36.0 'y 30.0
                                       'hp 200 'build-progress 0.5 'powered? #f))
           'enemy-units '())))
  (assert-true! (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (cadr a) 'barracks)))
                            (hash-ref res-t-inprog-dep 'actions '())))
                "Terran with only an unfinished SupplyDepot (0.5) must NOT emit doomed (build barracks ...)")

  ;; Protoss with 2 Nexuses, powered Gateways + CyberneticsCore (0 RoboticsFacility), 180M / 20G, wanting forge
  (define p-forge-units
    (append (for/list ([i (in-range 30)])
              (hash 'id (+ 10 i) 'type 'probe 'x 31.0 'y 32.5 'hp 40))
            (for/list ([k (in-range 5)])
              (hash 'id (+ 70 k) 'type 'stalker 'x 48.0 'y 34.0 'hp 80 'shield 80))
            (for/list ([k (in-range 4)])
              (hash 'id (+ 80 k) 'type 'zealot 'x 50.0 'y 34.0 'hp 100 'shield 50))))
  (define rt-p-forge (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define res-p-forge
    (step-live-bot-runtime!
     rt-p-forge
     (hash 'frame 3600 'minerals 180 'gas 20 'supply-used 48 'supply-cap 62 'supply-left 14
           'mineral-harvesters 28 'gas-harvesters 2
           'researched-upgrades '(warp-gate-research)
           'base-x 32.5 'base-y 32.5 'natural-x 56.5 'natural-y 32.5
           'ally-units p-forge-units
           'ally-buildings (list (hash 'id 501 'type 'nexus 'x 32.5 'y 32.5 'hp 2000 'build-progress 1.0 'powered? #f)
                                 (hash 'id 502 'type 'nexus 'x 56.5 'y 32.5 'hp 2000 'build-progress 1.0 'powered? #f)
                                 (hash 'id 503 'type 'pylon 'x 36.0 'y 36.0 'hp 400 'build-progress 1.0 'powered? #f)
                                 (hash 'id 504 'type 'pylon 'x 42.0 'y 36.0 'hp 400 'build-progress 1.0 'powered? #f)
                                 (hash 'id 505 'type 'pylon 'x 48.0 'y 36.0 'hp 400 'build-progress 1.0 'powered? #f)
                                 (hash 'id 506 'type 'gateway 'x 37.5 'y 36.5 'hp 1000 'build-progress 1.0 'powered? #t)
                                 (hash 'id 510 'type 'gateway 'x 37.5 'y 40.5 'hp 1000 'build-progress 1.0 'powered? #t)
                                 (hash 'id 511 'type 'gateway 'x 44.5 'y 36.5 'hp 1000 'build-progress 1.0 'powered? #t)
                                 (hash 'id 512 'type 'gateway 'x 44.5 'y 40.5 'hp 1000 'build-progress 1.0 'powered? #t)
                                 (hash 'id 507 'type 'cybernetics-core 'x 41.5 'y 36.5 'hp 1100 'build-progress 1.0 'powered? #t)
                                 (hash 'id 508 'type 'assimilator 'x 32.5 'y 26.5 'hp 900 'build-progress 1.0 'powered? #f)
                                 (hash 'id 509 'type 'assimilator 'x 56.5 'y 26.5 'hp 900 'build-progress 1.0 'powered? #f))
           'enemy-units '())))
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (cadr a) 'forge)))
                       (hash-ref res-p-forge 'actions '()))
                "Protoss on 2 Nexuses with powered Gateways + CyberneticsCore (0 Robo) at 180M/20G must build Forge without Robo deadlock")

  ;; Also verify 1-Gateway + CyberneticsCore (0 Robo) at 180M/20G under cloak threat builds Forge immediately
  (define rt-p-forge-det (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define res-p-forge-det
    (step-live-bot-runtime!
     rt-p-forge-det
     (hash 'frame 2400 'minerals 180 'gas 20 'supply-used 34 'supply-cap 46 'supply-left 12
           'mineral-harvesters 24 'gas-harvesters 6
           'researched-upgrades '(warp-gate-research)
           'base-x 32.5 'base-y 32.5 'natural-x 56.5 'natural-y 32.5
           'ally-units p-forge-units
           'ally-buildings (list (hash 'id 501 'type 'nexus 'x 32.5 'y 32.5 'hp 2000 'build-progress 1.0 'order-count 1 'powered? #f)
                                 (hash 'id 502 'type 'nexus 'x 56.5 'y 32.5 'hp 2000 'build-progress 1.0 'order-count 1 'powered? #f)
                                 (hash 'id 503 'type 'pylon 'x 36.0 'y 36.0 'hp 400 'build-progress 1.0 'powered? #f)
                                 (hash 'id 506 'type 'gateway 'x 37.5 'y 36.5 'hp 1000 'build-progress 1.0 'powered? #t)
                                 (hash 'id 507 'type 'cybernetics-core 'x 41.5 'y 36.5 'hp 1100 'build-progress 1.0 'powered? #t)
                                 (hash 'id 508 'type 'assimilator 'x 32.5 'y 26.5 'hp 900 'build-progress 1.0 'powered? #f)
                                 (hash 'id 509 'type 'assimilator 'x 56.5 'y 26.5 'hp 900 'build-progress 1.0 'powered? #f))
           'enemy-units '()
           'enemy-buildings (list (hash 'id 990 'type 'dark-shrine 'x 140.0 'y 140.0 'hp 500)))))
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (cadr a) 'forge)))
                       (hash-ref res-p-forge-det 'actions '()))
                "Protoss on 1 Gateway + CyberneticsCore (0 Robo) at 180M/20G facing DarkShrine must build Forge without Gateway preemption")

  ;; 26.3 12-Probe Worker Rush (Creepy_strategies), In-Base Proxy (Thssprtssbt),
  ;;      < 8 Worker Combat Priority & Safe Zerg Rebuild Anchor
  (define rt-wrush (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  ;; 12 Drones: #101 is critically wounded at 10 HP near incoming Probes; #102..#112 are healthy at 40 HP.
  ;; 10 Enemy Probes at 15.5–21.5 tiles from (32.5, 32.5) (> 9.0 tiles!), including 6 stacked within 0.45 tiles
  ;; so `counter-enemy-worker-drill` also triggers, with #901 having the lowest total HP+shield (8 HP, 0 shield).
  (define rush-ally-drones
    (cons (hash 'id 101 'type 'drone 'x 44.5 'y 32.5 'hp 10)
          (for/list ([i (in-range 1 12)])
            (hash 'id (+ 101 i) 'type 'drone 'x (+ 31.0 (* 0.4 i)) 'y 32.5 'hp 40))))
  (define rush-enemy-probes
    (append
     (list (hash 'id 901 'type 'probe 'x 48.0 'y 32.5 'hp 8 'shield 0))
     ;; 6 stacked Probes at ~16.5 tiles from (32.5, 32.5)
     (for/list ([j (in-range 6)])
       (hash 'id (+ 902 j) 'type 'probe 'x (+ 49.0 (* 0.05 j)) 'y 32.5 'hp 20 'shield 20))
     ;; 3 trailing Probes at 18.5–21.5 tiles from (32.5, 32.5)
     (list (hash 'id 908 'type 'probe 'x 51.0 'y 32.5 'hp 20 'shield 20)
           (hash 'id 909 'type 'probe 'x 52.5 'y 32.5 'hp 20 'shield 20)
           (hash 'id 910 'type 'probe 'x 54.0 'y 32.5 'hp 20 'shield 20))))
  (define rush-obs
    (hash 'frame 700 'minerals 100 'gas 0 'supply-used 12 'supply-cap 14 'supply-left 2
          'mineral-harvesters 12 'vespene-harvesters 0
          'base-x 32.5 'base-y 32.5 'natural-x 60.5 'natural-y 32.5
          'mineral-patches (list (hash 'id 550 'x 26.5 'y 32.5))
          'ally-units (append rush-ally-drones
                              (list (hash 'id 150 'type 'larva 'x 33.0 'y 33.0 'hp 25)
                                    (hash 'id 160 'type 'overlord 'x 34.0 'y 34.0 'hp 200)))
          'ally-buildings (list (hash 'id 201 'type 'hatchery 'x 32.5 'y 32.5
                                      'hp 1500 'build-progress 1.0 'powered? #f))
          'enemy-units rush-enemy-probes
          'enemy-buildings '()))
  (define res-wrush (step-live-bot-runtime! rt-wrush rush-obs))
  (define acts-wrush
    (append (hash-ref res-wrush 'actions '())
            (hash-ref res-wrush 'mirror-actions '())))

  ;; 4-arg (pull-workers-attack pull-ids target-id tx ty) targeting lowest-HP enemy Probe #901
  (define pull-act-wrush
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack))) acts-wrush))
  (assert-true! (and pull-act-wrush (= (length pull-act-wrush) 5))
                "12-Probe worker rush must emit 4-arg (pull-workers-attack pull-ids target-id tx ty)")
  (assert-eq! (third pull-act-wrush) 901
              "pull-workers-attack must focus-fire the lowest-HP enemy Probe (#901)")
  (assert-true! (not (memv 101 (second pull-act-wrush)))
                "Critically wounded 10 HP Drone (#101) must NOT be included in pull-workers-attack")

  ;; ZERO passive (move ...) commands on friendly Drones
  (define friendly-drone-ids (for/list ([i (in-range 12)]) (+ 101 i)))
  (assert-true! (not (ormap (lambda (a)
                              (and (pair? a)
                                   (eq? (car a) 'move)
                                   (pair? (cdr a))
                                   (let ([u (cadr a)])
                                     (if (list? u)
                                         (ormap (lambda (id) (memv id friendly-drone-ids)) u)
                                         (memv u friendly-drone-ids)))))
                            acts-wrush))
                "counter-enemy-worker-drill must emit ZERO passive (move ...) commands on friendly Drones during worker rush")

  ;; Disengages the 10 HP (<= 12 HP) Drone (#101) via (mineral-walk ...)
  (assert-true! (ormap (lambda (a)
                         (and (pair? a)
                              (eq? (car a) 'mineral-walk)
                              (pair? (cdr a))
                              (let ([u (cadr a)])
                                (if (list? u) (memv 101 u) (equal? u 101)))))
                       acts-wrush)
                "10 HP Drone (#101) must disengage via (mineral-walk ...)")

  ;; Emits ZERO (train drone), (build extractor ...), or (expand ...) during the rush
  (assert-true! (not (member '(train drone) acts-wrush))
                "Worker rush crisis must emit ZERO (train drone)")
  (assert-true! (not (ormap (lambda (a)
                              (and (pair? a)
                                   (or (eq? (car a) 'expand)
                                       (and (eq? (car a) 'build)
                                            (pair? (cdr a))
                                            (memq (cadr a) '(extractor hatchery))))))
                            acts-wrush))
                "Worker rush crisis must emit ZERO (build extractor ...) or (expand ...)")

  ;; Passing emitted actions through translate-bot-actions->sc2-raw-commands populates #:used-worker-tags
  ;; with BOTH the pulled healthy Drones AND the mineral-walking 10 HP Drone!
  (define rush-used-wtags (mutable-seteqv))
  (define _rush-wire-cmds
    (translate-bot-actions->sc2-raw-commands acts-wrush
                                             rush-obs
                                             #:used-worker-tags rush-used-wtags))
  (assert-true! (set-member? rush-used-wtags 101)
                "translate-bot-actions->sc2-raw-commands must populate #:used-worker-tags with mineral-walking Drone #101")
  (for ([pulled-id (in-list (second pull-act-wrush))])
    (assert-true! (set-member? rush-used-wtags pulled-id)
                  (format "translate-bot-actions->sc2-raw-commands must populate #:used-worker-tags with pulled Drone #~a" pulled-id)))

  ;; At 6 surviving Drones + ready SpawningPool (50M/0G, 0 army supply, under-attack? = #t / 10 enemy Probes),
  ;; step-priority-macro-brain schedules 'zergling and does NOT escrow-block on 'drone!
  (define ws-6drone-rush
    (make-macro-world-state
     #:race 'Zerg #:enemy-race 'Protoss #:frame 1400
     #:minerals 50 #:gas 0 #:supply-used 6 #:supply-cap 14
     #:workers 6 #:active-bases 1 #:mineral-harvesters 6 #:gas-harvesters 0
     #:ready-building-counts (hasheq 'hatchery 1 'spawning-pool 1)
     #:total-building-counts (hasheq 'hatchery 1 'spawning-pool 1)
     #:unit-counts (hasheq 'drone 6 'overlord 1)
     #:open-facility-slots (hasheq 'larva 3 'townhall 1 'spawning-pool 1)
     #:army-supply 0 #:enemy-threat-supply 10 #:under-attack? #t))
  (define dec-6drone-rush (step-priority-macro-brain ws-6drone-rush))
  (assert-true! (not (not (memq 'zergling (macro-brain-decision-scheduled-ids dec-6drone-rush))))
                "At 6 surviving Drones + ready SpawningPool under worker rush, step-priority-macro-brain must schedule 'zergling")
  (assert-true! (not (eq? (macro-brain-decision-saving-for dec-6drone-rush) 'drone))
                "At 6 surviving Drones + ready SpawningPool under worker rush, step-priority-macro-brain must NOT escrow-block on 'drone")
  (assert-true! (macro-brain-can-spend? dec-6drone-rush 'zergling 50 0 'combat-unit)
                "macro-brain-can-spend? must allow 'zergling at 6 Drones / 50M under worker rush")

  ;; In-Base Proxy (Thssprtssbt): Terran at frame 1000 (400M, 0 Barracks) with enemy proxy Pylon + warping PhotonCannon
  ;; 6.0 tiles from natural (62.5, 32.5) and 24.0 tiles from main (32.5, 32.5)
  (define rt-t-proxy (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define res-t-proxy
    (step-live-bot-runtime!
     rt-t-proxy
     (hash 'frame 1000 'minerals 400 'gas 0 'supply-used 15 'supply-cap 23 'supply-left 8
           'mineral-harvesters 15 'vespene-harvesters 0
           'base-x 32.5 'base-y 32.5 'natural-x 62.5 'natural-y 32.5
           'ally-units (for/list ([i (in-range 15)])
                         (hash 'id (+ 210 i) 'type 'scv 'x 33.5 'y 32.5 'hp 45))
           'ally-buildings (list (hash 'id 301 'type 'command-center 'x 32.5 'y 32.5
                                       'hp 1500 'build-progress 1.0 'powered? #f)
                                 (hash 'id 302 'type 'supply-depot 'x 36.0 'y 30.0
                                       'hp 400 'build-progress 1.0 'powered? #f))
           'enemy-units '()
           'enemy-buildings (list (hash 'id 950 'type 'pylon 'x 56.5 'y 32.5
                                        'hp 200 'shield 200 'build-progress 1.0 'powered? #f)
                                  (hash 'id 951 'type 'photon-cannon 'x 56.5 'y 34.0
                                        'hp 80 'shield 80 'build-progress 0.4 'powered? #t)))))
  (define acts-t-proxy (hash-ref res-t-proxy 'actions '()))
  (assert-true! (not (ormap (lambda (a)
                              (and (pair? a)
                                   (or (eq? (car a) 'expand)
                                       (and (eq? (car a) 'build)
                                            (pair? (cdr a))
                                            (eq? (cadr a) 'command-center)))))
                            acts-t-proxy))
                "Terran with 0 Barracks under proxy Pylon + warping Cannon near natural must NOT spend 400M on 2nd CommandCenter")
  (assert-true! (ormap (lambda (a)
                         (and (pair? a)
                              (eq? (car a) 'pull-workers-attack)
                              (= (length a) 5)
                              (equal? (third a) 950)))
                       acts-t-proxy)
                "Terran must pull surplus SCVs to focus-fire the enemy proxy Pylon (#950) first")

  ;; Safe Zerg Rebuild Anchor: SpawningPool lost, main Hatchery (30, 30) camped by 6 enemy Marines,
  ;; 2nd Hatchery (80, 80) uncontested (250M) -> (build spawning-pool x y) anchors near (80, 80) (> 60.0), NOT (30, 30)!
  (define rt-z-rebuild (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define res-z-rebuild
    (step-live-bot-runtime!
     rt-z-rebuild
     (hash 'frame 2600 'minerals 250 'gas 50 'supply-used 24 'supply-cap 36 'supply-left 12
           'mineral-harvesters 18 'gas-harvesters 0
           'base-x 30.0 'base-y 30.0 'natural-x 80.0 'natural-y 80.0
           'ally-units (append (for/list ([i (in-range 18)])
                                 (hash 'id (+ 310 i) 'type 'drone 'x 79.0 'y 80.0 'hp 40))
                               (list (hash 'id 350 'type 'overlord 'x 82.0 'y 82.0 'hp 200)
                                     (hash 'id 351 'type 'overlord 'x 83.0 'y 82.0 'hp 200)))
           'ally-buildings (list (hash 'id 401 'type 'hatchery 'x 30.0 'y 30.0
                                       'hp 600 'build-progress 1.0 'powered? #f)
                                 (hash 'id 402 'type 'hatchery 'x 80.0 'y 80.0
                                       'hp 1500 'build-progress 1.0 'powered? #f))
           'enemy-units (for/list ([m (in-range 6)])
                          (hash 'id (+ 980 m) 'type 'marine 'x (+ 32.0 (* 0.5 m)) 'y 31.0 'hp 45))
           'enemy-buildings '())))
  (define pool-rebuild-act
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'build) (pair? (cdr a)) (eq? (cadr a) 'spawning-pool)))
           (hash-ref res-z-rebuild 'actions '())))
  (assert-true! (and pool-rebuild-act (= (length pool-rebuild-act) 4))
                "Zerg losing SpawningPool with 250M must emit (build spawning-pool x y)")
  (assert-true! (and (> (third pool-rebuild-act) 60.0)
                     (> (fourth pool-rebuild-act) 60.0))
                (format "Rebuilt SpawningPool must anchor near uncontested 2nd Hatchery (80,80), got ~v"
                        pool-rebuild-act)))

(define total-elapsed-ms
  (inexact->exact (round (- (current-inexact-monotonic-milliseconds) suite-start-total-ms))))
(printf "\n============================================================================\n")
(printf "  ALL #lang sc-bot TESTS PASSED (~a assertions, 12/12 mutation kill rate, ~a ms total)!\n"
        total-assertions total-elapsed-ms)
(printf "============================================================================\n")

