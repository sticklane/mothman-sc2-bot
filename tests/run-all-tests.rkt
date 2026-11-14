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
         "../lib/sc2-typed-commands.rkt"
         (only-in "../lib/sc2-protobuf-ws.rkt"
                  sc2-ws-conn
                  sc2-ws-close!
                  mask-ws-payload
                  encode-int32
                  encode-uint32
                  encode-bytes-field
                  encode-submessage-field
                  decode-protobuf-message
                  make-request-action
                  encode-sc2-action
                  legacy-wire-action->typed-sc2-action
                  get-last-bot-action-rejects
                  get-total-bot-action-reject-count
                  get-total-wire-action-drop-count
                  reset-typed-command-gate-stats!
                  sc2-point2d
                  sc2-point2d?
                  sc2-point2d-x
                  sc2-point2d-y
                  sc2-point3d
                  sc2-unit-order
                  sc2-unit
                  sc2-player-common
                  sc2-observation
                  sc2-power-source
                  sc2-image-grid
                  sc2-game-info
                  sc2-raw-unit-command
                  sc2-raw-unit-command?
                  sc2-raw-unit-command-ability-id
                  sc2-raw-unit-command-target-pos
                  sc2-raw-unit-command-target-unit-tag
                  sc2-raw-unit-command-unit-tags
                  sc2-raw-camera-move
                  sc2-raw-camera-move?
                  sc2-raw-camera-move-x
                  sc2-raw-camera-move-y
                  sc2-chat-action
                  sc2-ui-control-group
                  sc2-ui-control-group?
                  decode-image-grid-bytes
                  sc2-grid-ref
                  solve-exact-townhall-pad
                  compute-ground-bfs-distances
                  solve-all-map-expansion-bases
                  order-expansions-from-origin
                  find-spiral-building-placement
                  select-producer-tags-for-unit
                  frame0-pro-worker-split-commands
                  pick-safe-mule-mineral-patch
                  saturate-workers-and-gas-commands
                  translate-bot-actions->sc2-raw-commands
                  sc2-observation->runtime-obs-hash
                  result-enum->symbol
                  make-wire-apm-governor
                  govern-sc2-wire-actions!
                  make-request-step
                  make-request-query-placement
                  make-request-ping
                  encode-float32
                  decode-sc2-response
                  sc2-response-game-info
                  sc2-image-grid-y-flip?
                  sc2-image-grid-lsb-first?
                  sc2-game-info-placement-grid
                  sc2-game-info-pathing-grid
                  collect-spiral-candidates
                  find-verified-building-placement
                  interleave-lists
                  SC2-PLACEMENT-NEG-COOLDOWN
                  SC2-WARPGATE-LAST-LOOP
                  enemy-structure-is-proxy?
                  placement-preserves-base-exit-and-spawn?
                  mark-urgent-survival-cmd!
                  urgent-survival-cmd?
                  mark-framing-camera-cmd!
                  framing-camera-cmd?
                  friendly-unit-on-depot-footprint?
                  friendly-unit-requesting-depot-transit?
                  wire-cmd-priority-tier)
         (only-in "../lib/sc2-mpq-replay-parser.rkt"
                  STORM-CRYPT
                  mpq-hash
                  parse-sc2-replay
                  is-morph-death?
                  compute-swarmy-win-chance
                  compute-turning-points
                  cluster-combat-engagements)
         (except-in "../lib/bot-crash-fuzzer.rkt"
                    compute-shadow-ledger
                    step-zerospace-mastermind!)
         "../lib/sc2-proto-wire-verifier.rkt"
         "../tools/fuzz-sc2-protobuf-output.rkt")

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
;; 3.3 Lakefill + Zipper-Cut, Baba Wall-In Solver, FAP Hysteresis & Traffic Retreat
;; =============================================================================
(run-suite "3.3 Lakefill + Zipper-Cut, Baba Wall-In Solver, FAP Hysteresis & Traffic Retreat"
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

(run-suite "19. AI Arena BotZip Size Limit (<= 35 MB / 50 MiB) & Standalone Native ELF Binary"
  ;; 1. Verify constants enforce a strict safety margin well below AI Arena's 50 MiB standard cap
  (assert-eq! AIARENA-STANDARD-MAX-ZIP-BYTES (* 50 1024 1024)
              "AI Arena standard tier max zip size must be 50 MiB (52,428,800 bytes)")
  (assert-true! (<= MAX-BOT-ZIP-SIZE-BYTES (* 35 1000 1000))
                "Repository BotZip safety limit must be <= 35 MB")
  (assert-true! (< MAX-BOT-ZIP-SIZE-BYTES AIARENA-STANDARD-MAX-ZIP-BYTES)
                "MAX-BOT-ZIP-SIZE-BYTES must be strictly less than AIARENA-STANDARD-MAX-ZIP-BYTES")

  ;; 2. Verify all 4 ladder BotZip archives exist and obey size & structure limits
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
                  (format "~a (~a bytes) must be <= ~a bytes (35 MB safety ceiling)"
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
  ;; (a) Early-warning phase: 10 Enemy Probes at x = 48.0..54.0 (15.5–21.5 tiles from TownHall 32.5, > 12.5 tiles!)
  ;; Triggers macro alert (zero Drone/Extractor/Expand greed + mineral-walk disengage for 10 HP Drone #101)
  ;; WITHOUT prematurely pulling healthy Drones off minerals!
  (define rush-ally-drones-warn
    (cons (hash 'id 101 'type 'drone 'x 44.5 'y 32.5 'hp 10)
          (for/list ([i (in-range 1 12)])
            (hash 'id (+ 101 i) 'type 'drone 'x (+ 31.0 (* 0.4 i)) 'y 32.5 'hp 40))))
  (define rush-enemy-probes-warn
    (append
     (list (hash 'id 901 'type 'probe 'x 48.0 'y 32.5 'hp 8 'shield 0))
     (for/list ([j (in-range 6)])
       (hash 'id (+ 902 j) 'type 'probe 'x (+ 49.0 (* 0.05 j)) 'y 32.5 'hp 20 'shield 20))
     (list (hash 'id 908 'type 'probe 'x 51.0 'y 32.5 'hp 20 'shield 20)
           (hash 'id 909 'type 'probe 'x 52.5 'y 32.5 'hp 20 'shield 20)
           (hash 'id 910 'type 'probe 'x 54.0 'y 32.5 'hp 20 'shield 20))))
  (define rush-obs-warn
    (hash 'frame 700 'minerals 100 'gas 0 'supply-used 12 'supply-cap 14 'supply-left 2
          'mineral-harvesters 12 'vespene-harvesters 0
          'base-x 32.5 'base-y 32.5 'natural-x 60.5 'natural-y 32.5
          'mineral-patches (list (hash 'id 550 'x 26.5 'y 32.5))
          'ally-units (append rush-ally-drones-warn
                              (list (hash 'id 150 'type 'larva 'x 33.0 'y 33.0 'hp 25)
                                    (hash 'id 160 'type 'overlord 'x 34.0 'y 34.0 'hp 200)))
          'ally-buildings (list (hash 'id 201 'type 'hatchery 'x 32.5 'y 32.5
                                      'hp 1500 'build-progress 1.0 'powered? #f))
          'enemy-units rush-enemy-probes-warn
          'enemy-buildings '()))
  (define res-wrush-warn (step-live-bot-runtime! rt-wrush rush-obs-warn))
  (define acts-wrush-warn
    (append (hash-ref res-wrush-warn 'actions '())
            (hash-ref res-wrush-warn 'mirror-actions '())))
  (define friendly-drone-ids (for/list ([i (in-range 12)]) (+ 101 i)))

  (assert-true! (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack))) acts-wrush-warn))
                "Early-warning enemy Probes at x = 48.0..54.0 (15.5-21.5 tiles) must NOT prematurely pull workers off minerals")
  (assert-true! (not (member '(train drone) acts-wrush-warn))
                "Early-warning worker rush must freeze (train drone)")
  (assert-true! (not (ormap (lambda (a)
                              (and (pair? a)
                                   (or (eq? (car a) 'expand)
                                       (and (eq? (car a) 'build)
                                            (pair? (cdr a))
                                            (memq (cadr a) '(extractor hatchery))))))
                            acts-wrush-warn))
                "Early-warning worker rush must freeze (build extractor ...) and (expand ...)")
  (assert-true! (ormap (lambda (a)
                         (and (pair? a)
                              (eq? (car a) 'mineral-walk)
                              (pair? (cdr a))
                              (let ([u (cadr a)])
                                (if (list? u) (memv 101 u) (equal? u 101)))))
                       acts-wrush-warn)
                "Early-warning worker rush must disengage 10 HP Drone (#101) via (mineral-walk ...)")

  ;; (b) Breach phase: 10 Enemy Probes breaching at x = 35.0..41.0 (<= 12.5 tiles from TownHall 32.5),
  ;; with #901 at (35.0, 32.5) having lowest HP+shield (8 HP, 0 shield), 4 healthy far-patch miners (#102..#105)
  ;; at (26.0..26.9, 32.5) (> 8 tiles from enemies), 7 frontline healthy Drones (#106..#112) at (32.6..35.0, 32.5),
  ;; and wounded 10 HP Drone #101 at (35.5, 32.5).
  (define rt-wrush-breach (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define rush-ally-drones
    (append
     (list (hash 'id 101 'type 'drone 'x 35.5 'y 32.5 'hp 10))
     (for/list ([i (in-range 4)])
       (hash 'id (+ 102 i) 'type 'drone 'x (+ 26.0 (* 0.3 i)) 'y 32.5 'hp 40))
     (for/list ([k (in-range 7)])
       (hash 'id (+ 106 k) 'type 'drone 'x (+ 32.6 (* 0.4 k)) 'y 32.5 'hp 40))))
  (define rush-enemy-probes
    (append
     (list (hash 'id 901 'type 'probe 'x 35.0 'y 32.5 'hp 8 'shield 0))
     ;; 6 stacked Probes at ~4.0 tiles from (32.5, 32.5)
     (for/list ([j (in-range 6)])
       (hash 'id (+ 902 j) 'type 'probe 'x (+ 36.5 (* 0.05 j)) 'y 32.5 'hp 20 'shield 20))
     ;; 3 trailing Probes at 5.5–8.5 tiles from (32.5, 32.5)
     (list (hash 'id 908 'type 'probe 'x 38.0 'y 32.5 'hp 20 'shield 20)
           (hash 'id 909 'type 'probe 'x 39.5 'y 32.5 'hp 20 'shield 20)
           (hash 'id 910 'type 'probe 'x 41.0 'y 32.5 'hp 20 'shield 20))))
  (define rush-obs
    (hash 'frame 720 'minerals 100 'gas 0 'supply-used 12 'supply-cap 14 'supply-left 2
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
  (define res-wrush (step-live-bot-runtime! rt-wrush-breach rush-obs))
  (define acts-wrush
    (append (hash-ref res-wrush 'actions '())
            (hash-ref res-wrush 'mirror-actions '())))

  ;; Distributed local 3-cap 4-arg (pull-workers-attack pull-ids target-id tx ty) groups
  (define pull-acts-wrush
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack))) acts-wrush))
  (define pull-act-901
    (findf (lambda (a) (and (= (length a) 5) (equal? (third a) 901))) pull-acts-wrush))
  (define all-pulled-wids
    (remove-duplicates (append* (map second pull-acts-wrush))))
  (assert-true! (and (pair? pull-acts-wrush)
                     (andmap (lambda (a) (= (length a) 5)) pull-acts-wrush))
                "Breaching 10-Probe rush at x = 35.0..41.0 must emit 4-arg (pull-workers-attack pull-ids target-id tx ty)")
  (assert-true! (and pull-act-901 (<= (length (second pull-act-901)) 3))
                "pull-workers-attack must locally focus-fire lowest-HP Probe (#901) with <= 3 defenders (no conga-line)")
  (assert-true! (andmap (lambda (a)
                          (or (<= (third a) 0)
                              (<= (length (second a)) 3)))
                        pull-acts-wrush)
                "Every unit-targeted pull-workers-attack group must obey the local 3-defender cap")
  (assert-true! (not (memv 101 all-pulled-wids))
                "Critically wounded 10 HP Drone (#101) must NOT be included in pull-workers-attack")
  (assert-true! (>= (- 11 (length all-pulled-wids)) 3)
                (format "Breach worker-rush defense must keep >= 3 far miners harvesting (pulled ~a of 11 healthy)"
                        (length all-pulled-wids)))

  ;; ZERO passive (move ...) commands on friendly Drones
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
  (for ([pulled-id (in-list all-pulled-wids)])
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

;; =============================================================================
;; Suite 27: <500 APM Wire Governor, Grid Ramp/Choke Walls, BFS Exact Expansions,
;;           Pro Splits/Scout/Creep/Splash Micro & Generalized T3 Transitions
;; =============================================================================
(run-suite "27. <500 APM Wire Governor, Grid Ramp/Choke Walls, BFS Expansions, Pro Micro & T3 Transitions"
  (define (mk-s27-unit tag utype x y
                       #:alliance [alliance 1]
                       #:display-type [display-type 1]
                       #:radius [radius 0.5]
                       #:progress [progress 1.0]
                       #:cloak [cloak 0]
                       #:hp [hp 100.0]
                       #:hp-max [hp-max 100.0]
                       #:shield [shield 0.0]
                       #:shield-max [shield-max 0.0]
                       #:energy [energy 0.0]
                       #:energy-max [energy-max 0.0]
                       #:mins [mins 0]
                       #:vesp [vesp 0]
                       #:flying? [flying? #f]
                       #:burrowed? [burrowed? #f]
                       #:powered? [powered? #t]
                       #:orders [orders '()]
                       #:addon-tag [addon-tag 0]
                       #:buffs [buffs '()]
                       #:assigned [assigned 0]
                       #:ideal [ideal 0]
                       #:engaged-tag [engaged-tag 0])
    (sc2-unit display-type alliance tag utype (if (= alliance 1) 1 2)
              (sc2-point3d x y 8.0) 0.0 radius progress cloak #f #f #f
              hp hp-max shield shield-max energy energy-max mins vesp
              flying? burrowed? #f powered? #t orders addon-tag buffs
              assigned ideal 0.0 engaged-tag 0 0 0))

  (define (mk-s27-obs loop units #:mins [mins 200] #:vesp [vesp 100] #:used [used 24] #:cap [cap 38])
    (sc2-observation loop
                     (sc2-player-common 1 mins vesp cap used 10 14 0 5 0 3)
                     units
                     '() '() #f '() '() '() '() '() '()))

  ;; ---------------------------------------------------------------------------
  ;; 27.1 Canonical Order Ability Equivalence & Protected Burrow/Morph Lock
  ;; ---------------------------------------------------------------------------
  (for ([gid (in-list '(3666 295 298 1183 166))])
    (assert-eq! (sc2-canonical-order-ability gid) 'harvest-gather
                (format "Harvest gather ability ~a must canonicalize to 'harvest-gather" gid)))
  (for ([rid (in-list '(3667 296 299 1184 167))])
    (assert-eq! (sc2-canonical-order-ability rid) 'harvest-return
                (format "Harvest return ability ~a must canonicalize to 'harvest-return" rid)))
  (assert-eq! (sc2-canonical-order-ability 3691) (sc2-canonical-order-ability 1694)
              "Queen spawn creep tumor 3691 and 1694 must share canonical ability")
  (assert-eq! (sc2-canonical-order-ability 1662) (sc2-canonical-order-ability 1733)
              "Queen/Tumor creep tumor 1662 and 1733 must share canonical ability")
  (assert-true! (not (eq? (sc2-canonical-order-ability 3692) 'spawn-creep-tumor))
                "3692 (RESEARCH_PROTOSSAIRARMOR) must NOT be misclassified as 'spawn-creep-tumor")
  (for ([lid (in-list '(3679 417 1522 452 485 518))])
    (assert-eq! (sc2-canonical-order-ability lid) 'lift
                (format "Lift ability ~a must canonicalize to 'lift" lid)))
  (for ([land-id (in-list '(3678 419 1524 520 522 554))])
    (assert-eq! (sc2-canonical-order-ability land-id) 'land
                (format "Land ability ~a must canonicalize to 'land" land-id)))
  (for ([bd-id (in-list '(3661 2095 2108 1390 1386 1433 1444))])
    (assert-eq! (sc2-canonical-order-ability bd-id) 'burrow-down
                (format "Burrow-down ability ~a must canonicalize to 'burrow-down" bd-id)))
  (for ([bu-id (in-list '(3662 2097 2110 1392 1446))])
    (assert-eq! (sc2-canonical-order-ability bu-id) 'burrow-up
                (format "Burrow-up ability ~a must canonicalize to 'burrow-up" bu-id)))

  ;; Protected classes across WidowMine (2095), SiegeTank (388), Lurker (2108), Liberator (2558),
  ;; Viking (403/405), Thor (2362/2364), Ghost Steady Targeting (2714), Battlecruiser Yamato/Jump (401/2358)
  (for ([ab (in-list '(2095 388 2108 2558 403 405 2362 2364 2714 401 2358 251 1694 1733))])
    (assert-true! (not (not (sc2-order-protection-class ab)))
                  (format "Ability ~a must carry a non-#f order protection class" ab)))

  ;; Unburrowed WidowMine (unit-type 498, tag 7101) actively executing BurrowDown (2095)
  ;; MUST NOT be cancelled/overwritten by generic attack-pos / attack-unit!
  (define obs-wm-burrow
    (mk-s27-obs
     900
     (list (mk-s27-unit 7101 498 44.0 44.0
                        #:hp 90.0 #:hp-max 90.0
                        #:orders (list (sc2-unit-order 2095 #f 0 0.3)))
           (mk-s27-unit 7102 48 45.0 44.0 #:hp 45.0 #:hp-max 45.0)
           (mk-s27-unit 9901 105 52.0 44.0 #:alliance 4 #:hp 35.0 #:hp-max 35.0))))
  (define cmds-wm-burrow
    (translate-bot-actions->sc2-raw-commands
     '((attack-pos 7101 52.0 44.0)
       (attack-unit 7101 9901)
       (attack-pos 7102 52.0 44.0))
     obs-wm-burrow))
  (assert-true! (not (ormap (lambda (c)
                              (and (sc2-raw-unit-command? c)
                                   (memv 7101 (sc2-raw-unit-command-unit-tags c))))
                            cmds-wm-burrow))
                "WidowMine (498) actively burrowing (2095) must NOT have its burrow cancelled by attack!")
  (assert-true! (ormap (lambda (c)
                         (and (sc2-raw-unit-command? c)
                              (memv 7102 (sc2-raw-unit-command-unit-tags c))))
                       cmds-wm-burrow)
                "Normal Marine (7102) without protected order must still receive attack command")

  ;; ---------------------------------------------------------------------------
  ;; 27.2 Wire APM Governor (`govern-sc2-wire-actions!`): <= 485 Replay APM & 100% P0
  ;; ---------------------------------------------------------------------------
  (define gov (make-wire-apm-governor #:target-apm 410.0 #:hard-cap-apm 485.0))
  (define p0-injected-count 0)
  (define p0-emitted-count 0)
  (define leaked-cg-count 0)
  (define emitted-cam-loops '())
  (define sim-prev-sel #f)
  (define sim-replay-events 0)

  ;; Simulate 336 steps x 4 loops = 1,344 game loops (1.00 Faster SC2 minute)
  ;; with ~3,000 raw commands/min spam (2 UI control-group + 2 camera + 5 P3 + 2 P2 + periodic P0)
  (for ([step-idx (in-range 336)])
    (define gl (* step-idx 4))
    (define inject-p0? (zero? (modulo step-idx 17))) ;; 20 P0 survival/macro commands across the minute
    (when inject-p0?
      (set! p0-injected-count (add1 p0-injected-count)))
    (define p0-cmd
      (sc2-raw-unit-command 251 #f 3001 (list (+ 9000 step-idx)) #f)) ;; InjectLarva (251) = P0
    (define raw-batch
      (append
       (if inject-p0? (list p0-cmd) '())
       (list (sc2-ui-control-group 1 1)
             (sc2-ui-control-group 0 4)
             (sc2-raw-camera-move 40.0 40.0 0.0)
             (sc2-raw-camera-move 80.0 80.0 0.0)
             (sc2-raw-unit-command 23 (sc2-point2d 90.0 90.0) 0 (list (+ 2000 (modulo step-idx 12))) #f)
             (sc2-raw-unit-command 16 (sc2-point2d 60.0 60.0) 0 (list (+ 3000 (modulo step-idx 16))) #f)
             (sc2-raw-unit-command 3666 #f 501 (list (+ 101 (modulo step-idx 12))) #f)
             (sc2-raw-unit-command 3666 #f 502 (list (+ 121 (modulo step-idx 12))) #f)
             (sc2-raw-unit-command 3666 #f 503 (list (+ 141 (modulo step-idx 12))) #f)
             (sc2-raw-unit-command 298 #f 504 (list (+ 400 (modulo step-idx 4))) #f))))
    (define out-cmds (govern-sc2-wire-actions! gov raw-batch gl))
    (for ([c (in-list out-cmds)])
      (cond
        [(sc2-ui-control-group? c)
         (set! leaked-cg-count (add1 leaked-cg-count))]
        [(sc2-raw-camera-move? c)
         (set! emitted-cam-loops (cons gl emitted-cam-loops))
         (set! sim-replay-events (add1 sim-replay-events))]
        [(sc2-raw-unit-command? c)
         (when (= (sc2-raw-unit-command-ability-id c) 251)
           (set! p0-emitted-count (add1 p0-emitted-count)))
         (define tags (sc2-raw-unit-command-unit-tags c))
         (if (and sim-prev-sel (equal? tags sim-prev-sel))
             (set! sim-replay-events (+ sim-replay-events 1))
             (begin
               (set! sim-prev-sel tags)
               (set! sim-replay-events (+ sim-replay-events 2))))])))

  (assert-eq! leaked-cg-count 0
              "Wire APM governor must strip 100% of Raw-mode no-op sc2-ui-control-group commands")
  (assert-eq! p0-emitted-count p0-injected-count
              "Wire APM governor must preserve 100% of P0 survival/macro commands under heavy spam")
  (assert-true! (and (> sim-replay-events 200) (<= sim-replay-events 485))
                (format "Simulated 3,000/min spam over 1,344 loops must stay <= 485 replay APM (got ~a)"
                        sim-replay-events))
  (define chron-cam-loops (reverse emitted-cam-loops))
  (for ([l1 (in-list chron-cam-loops)]
        [l2 (in-list (if (null? chron-cam-loops) '() (cdr chron-cam-loops)))])
    (assert-true! (>= (- l2 l1) 28)
                  (format "Governed camera moves must be >= 28 game loops apart (~a -> ~a)" l1 l2)))

  ;; ---------------------------------------------------------------------------
  ;; 27.3 Frame-0 12-Worker Pro Split (4x2 + 4x1 = 8 cmds), MULE Exclusion & Safe MULE Patch
  ;; ---------------------------------------------------------------------------
  (define f0-th (mk-s27-unit 1001 18 32.5 32.5 #:radius 2.75 #:hp 1500.0 #:hp-max 1500.0 #:ideal 16))
  (define f0-close-mins
    (for/list ([i (in-range 4)])
      (mk-s27-unit (+ 501 i) 341 26.5 (+ 29.5 (* 2.0 i))
                   #:alliance 3 #:radius 1.125 #:mins 1800)))
  (define f0-far-mins
    (for/list ([i (in-range 4)])
      (mk-s27-unit (+ 505 i) 341 25.5 (+ 29.5 (* 2.0 i))
                   #:alliance 3 #:radius 1.125 #:mins 900)))
  (define f0-workers
    (for/list ([i (in-range 12)])
      (mk-s27-unit (+ 101 i) 45 29.5 (+ 28.0 (* 0.8 i)) #:hp 45.0 #:hp-max 45.0)))
  (define f0-cmds
    (frame0-pro-worker-split-commands
     (mk-s27-obs 0 (append (list f0-th) f0-close-mins f0-far-mins f0-workers))))
  (assert-eq! (length f0-cmds) 8
              "Frame-0 12-worker pro split must emit exactly 8 coalesced HARVEST_GATHER commands")
  (assert-true! (for/and ([c (in-list f0-cmds)])
                  (= (sc2-raw-unit-command-ability-id c) 3666))
                "All Frame-0 split commands must use canonical HARVEST_GATHER (3666)")
  (define f0-tag-counts
    (sort (map (lambda (c) (length (sc2-raw-unit-command-unit-tags c))) f0-cmds) >))
  (assert-eq! f0-tag-counts '(2 2 2 2 1 1 1 1)
              "Frame-0 12-worker split must assign 4 close patches x 2 workers and 4 far patches x 1 worker")
  (define f0-all-wtags
    (sort (remove-duplicates (append* (map sc2-raw-unit-command-unit-tags f0-cmds))) <))
  (assert-eq! f0-all-wtags '(101 102 103 104 105 106 107 108 109 110 111 112)
              "Frame-0 12-worker split must cover all 12 unique worker tags without duplicates")

  ;; MULE (unit-type 268, 'mule) non-combat exclusion & safe MULE mineral patch selection
  (assert-true! (sc2-non-combat-or-summon-sym? 'mule)
                "MULE ('mule) must be classified as non-combat/summon so army never marches MULEs across map")
  (assert-true! (not (combat-unit-record? (hash 'id 801 'type 'mule 'x 32.0 'y 32.0 'hp 60)))
                "combat-unit-record? must return #f for MULE")
  (define rt-mule-chk (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define res-mule-chk
    (step-live-bot-runtime!
     rt-mule-chk
     (hash 'frame 2400 'minerals 100 'gas 50 'supply-used 28 'supply-cap 39 'supply-left 11
           'mineral-harvesters 18 'vespene-harvesters 3
           'base-x 32.5 'base-y 32.5 'natural-x 56.5 'natural-y 32.5
           'ally-units (list (hash 'id 801 'type 'mule 'x 31.0 'y 32.5 'hp 60)
                             (hash 'id 802 'type 'marine 'x 48.0 'y 32.5 'hp 45)
                             (hash 'id 803 'type 'marine 'x 49.0 'y 32.5 'hp 45))
           'ally-buildings (list (hash 'id 301 'type 'orbital-command 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0))
           'enemy-units (list (hash 'id 991 'type 'stalker 'x 54.0 'y 32.5 'hp 80 'shield 80)))))
  (assert-true! (not (ormap (lambda (a)
                              (and (pair? a)
                                   (memq (car a) '(attack attack-pos attack-unit kite))
                                   (pair? (cdr a))
                                   (let ([u (cadr a)])
                                     (if (list? u) (memv 801 u) (equal? u 801)))))
                            (hash-ref res-mule-chk 'actions '())))
                "MULE (#801) must receive ZERO combat attack/kite orders")

  (define safe-oc (mk-s27-unit 1301 132 32.5 32.5 #:radius 2.75 #:hp 1500.0 #:hp-max 1500.0))
  (define camped-cc (mk-s27-unit 1302 18 80.5 32.5 #:radius 2.75 #:hp 1500.0 #:hp-max 1500.0))
  (define fog-snap-min (mk-s27-unit 601 341 26.5 32.5 #:alliance 3 #:display-type 2 #:mins 1800))
  (define enemy-base-min (mk-s27-unit 602 341 160.5 160.5 #:alliance 3 #:display-type 1 #:mins 1800))
  (define camped-nat-min (mk-s27-unit 603 341 74.5 32.5 #:alliance 3 #:display-type 1 #:mins 1800))
  (define valid-safe-min (mk-s27-unit 604 341 26.5 34.5 #:alliance 3 #:display-type 1 #:mins 1500))
  (define camp-tank (mk-s27-unit 9601 33 78.0 32.5 #:alliance 4 #:hp 175.0 #:hp-max 175.0))
  (assert-eq! (pick-safe-mule-mineral-patch safe-oc
                                            (list safe-oc camped-cc)
                                            (list fog-snap-min enemy-base-min camped-nat-min)
                                            (list camp-tank))
              0
              "pick-safe-mule-mineral-patch must reject fog snapshots (display-type=2), enemy bases, and camped bases")
  (assert-eq! (pick-safe-mule-mineral-patch safe-oc
                                            (list safe-oc camped-cc)
                                            (list fog-snap-min enemy-base-min camped-nat-min valid-safe-min)
                                            (list camp-tank))
              604
              "pick-safe-mule-mineral-patch must select live (display-type=1) mineral patch at safe owned Orbital")

  ;; ---------------------------------------------------------------------------
  ;; 27.4 StartRaw ImageData Decode, Beveled 5x5 Pad, Torches AIE Mineral-Wall Skip,
  ;;      Chebyshev AABB Reservation & Friendly Builder Pad Evacuation
  ;; ---------------------------------------------------------------------------
  ;; Protobuf ImageData decode for both 1-bpp and 8-bpp grids
  (define raw-1bpp-pb
    (bytes-append
     (encode-int32 1 1)
     (encode-submessage-field 2 (bytes-append (encode-int32 1 8) (encode-int32 2 2)))
     ;; Row 0 = 1010_0001 (#xA1), Row 1 = 0100_1000 (#x48)
     (encode-bytes-field 3 (bytes #xA1 #x48))))
  (define grid-1bpp (decode-image-grid-bytes raw-1bpp-pb))
  (assert-true! (and grid-1bpp (= (sc2-grid-ref grid-1bpp 0 0) 1) (= (sc2-grid-ref grid-1bpp 1 0) 0)
                     (= (sc2-grid-ref grid-1bpp 2 0) 1) (= (sc2-grid-ref grid-1bpp 7 0) 1)
                     (= (sc2-grid-ref grid-1bpp 1 1) 1) (= (sc2-grid-ref grid-1bpp 4 1) 1))
                "1-bpp StartRaw ImageData protobuf decode + sc2-grid-ref must extract exact bit coordinates")

  (define raw-8bpp-pb
    (bytes-append
     (encode-int32 1 8)
     (encode-submessage-field 2 (bytes-append (encode-int32 1 4) (encode-int32 2 2)))
     (encode-bytes-field 3 (bytes 112 128 144 160 10 20 30 40))))
  (define grid-8bpp (decode-image-grid-bytes raw-8bpp-pb))
  (assert-eq! (list (sc2-grid-ref grid-8bpp 0 0) (sc2-grid-ref grid-8bpp 2 0) (sc2-grid-ref grid-8bpp 3 1))
              '(112 144 40)
              "8-bpp StartRaw ImageData protobuf decode + sc2-grid-ref must read exact terrain height bytes")

  ;; Synthetic 96x96 Torches AIE-style map:
  ;; - Main base at (20.5, 20.5)
  ;; - Mineral-walled pocket base at (35.5, 20.5) (Euclidean dist = 15.0 tiles! Sealed by cliff + MineralField450 (1996)!)
  ;; - True Natural base at (20.5, 52.5) (Euclidean dist = 32.0 tiles, open 8-connected ground path!)
  (define gw-t 96)
  (define gh-t 96)
  (define t-path-bytes (make-bytes (* gw-t gh-t) 1))
  (define t-plac-bytes (make-bytes (* gw-t gh-t) 1))
  (define t-hgt-bytes  (make-bytes (* gw-t gh-t) 128))
  ;; Surround pocket [30..44] x [12..28] with unwalkable cliff except a 2-tile doorway at x=30, y=20..21
  (for* ([ix (in-range 30 45)]
         [iy (in-range 12 29)]
         #:when (or (= ix 30) (= ix 44) (= iy 12) (= iy 28)))
    (unless (and (= ix 30) (or (= iy 20) (= iy 21)))
      (bytes-set! t-path-bytes (+ ix (* iy gw-t)) 0)
      (bytes-set! t-plac-bytes (+ ix (* iy gw-t)) 0)))
  (define torches-path-grid (sc2-image-grid 8 gw-t gh-t t-path-bytes #f #f))
  (define torches-plac-grid (sc2-image-grid 8 gw-t gh-t t-plac-bytes #f #f))
  (define torches-hgt-grid  (sc2-image-grid 8 gw-t gh-t t-hgt-bytes #f #f))
  (define torches-ginfo
    (sc2-game-info "TorchesAIE-Synthetic" "" '() (cons gw-t gh-t) (list 0 0 gw-t gh-t)
                   (list (sc2-point2d 20.5 20.5) (sc2-point2d 76.5 76.5))
                   torches-path-grid torches-hgt-grid torches-plac-grid))

  ;; Helper to build an exact SC2 L-shaped base cluster around half-integer TownHall pad (px, py):
  ;; 6 minerals West at (px - 6.5, py - 2.5 .. py + 2.5) + 2 geysers North/South at (px, py +/- 6.5)
  (define (mk-base-resources tag-base px py)
    (append
     (for/list ([k (in-range 6)])
       (mk-s27-unit (+ tag-base k) 341 (- px 6.5) (+ (- py 2.5) (* 1.0 k))
                    #:alliance 3 #:radius 1.125 #:mins 1500))
     (list (mk-s27-unit (+ tag-base 10) 342 px (- py 7.0) #:alliance 3 #:radius 1.5 #:vesp 2250)
           (mk-s27-unit (+ tag-base 11) 342 px (+ py 7.0) #:alliance 3 #:radius 1.5 #:vesp 2250))))

  ;; Stamp MineralField450 (unit-type 1996, 2x1 footprint) sealing the 2-tile doorway x=30, y=20..21!
  (define mineral-wall-blockers
    (list (mk-s27-unit 9101 1996 30.0 20.5 #:alliance 3 #:radius 1.125 #:mins 450)
          (mk-s27-unit 9102 1996 30.0 21.5 #:alliance 3 #:radius 1.125 #:mins 450)))
  (define torches-neutrals
    (append (mk-base-resources 8100 20.5 20.5)
            (mk-base-resources 8200 38.5 20.5)
            (mk-base-resources 8300 20.5 52.5)
            mineral-wall-blockers))

  (define solved-nat-pad
    (solve-exact-townhall-pad (take (mk-base-resources 8300 20.5 52.5) 6)
                              (drop (mk-base-resources 8300 20.5 52.5) 6)
                              #:placement-grid torches-plac-grid
                              #:terrain-height torches-hgt-grid))
  (assert-true! (and solved-nat-pad
                     (= (- (sc2-point2d-x solved-nat-pad) (floor (sc2-point2d-x solved-nat-pad))) 0.5)
                     (= (- (sc2-point2d-y solved-nat-pad) (floor (sc2-point2d-y solved-nat-pad))) 0.5)
                     (<= (abs (- (sc2-point2d-x solved-nat-pad) 20.5)) 1.0)
                     (<= (abs (- (sc2-point2d-y solved-nat-pad) 52.5)) 1.0))
                (format "solve-exact-townhall-pad must solve exact half-integer 5x5 pad near (20.5, 52.5), got ~v"
                        solved-nat-pad))

  (define torches-bfs (compute-ground-bfs-distances torches-path-grid 20.5 20.5 torches-neutrals))
  (assert-eq! (torches-bfs 38.5 20.5 2) +inf.0
              "Ground BFS with stamped MineralField450 wall must report +inf.0 for sealed pocket base")
  (assert-true! (< (torches-bfs 20.5 52.5 2) 60.0)
                "Ground BFS must report finite ground distance to open true Natural")

  (define torches-bases (solve-all-map-expansion-bases torches-neutrals torches-ginfo))
  (define ordered-torches (order-expansions-from-origin torches-bases 20.5 20.5 torches-path-grid torches-neutrals))
  (assert-true! (and (pair? ordered-torches)
                     (> (hash-ref (first ordered-torches) 'y) 45.0))
                (format "order-expansions-from-origin must skip sealed pocket and rank true Natural (~a,~a) #1"
                        (hash-ref (first ordered-torches) 'x)
                        (hash-ref (first ordered-torches) 'y)))

  ;; Chebyshev expansion pad & Terran add-on AABB reservation exclusion in find-spiral-building-placement
  (define addon-box (reserved-aabb 41.0 48.0 1.0 1.0 'terran-addon-pad 301 0))
  (define placed-dep-on-addon
    (find-spiral-building-placement 41.0 48.0 '()
                                    #:reserved-aabbs (list addon-box)
                                    #:expansion-pads (list (cons 52.5 48.5))
                                    #:bldg-sym 'supply-depot))
  (assert-true! (not (aabb-overlaps? (sc2-point2d-x placed-dep-on-addon)
                                     (sc2-point2d-y placed-dep-on-addon)
                                     1.0 1.0 addon-box))
                "find-spiral-building-placement must keep SupplyDepot off reserved Terran add-on AABB")
  (define placed-dep-on-exp
    (find-spiral-building-placement 52.5 48.5 '()
                                    #:reserved-aabbs '()
                                    #:expansion-pads (list (cons 52.5 48.5))
                                    #:bldg-sym 'supply-depot))
  (assert-true! (>= (max (abs (- (sc2-point2d-x placed-dep-on-exp) 52.5))
                         (abs (- (sc2-point2d-y placed-dep-on-exp) 48.5)))
                    3.5)
                "find-spiral-building-placement must keep SupplyDepot outside 5x5 Chebyshev expansion pad")

  ;; Friendly non-builder ground unit evacuation when builder approaches expansion pad
  (define obs-pad-evac
    (mk-s27-obs
     1800
     (list (mk-s27-unit 1001 18 24.5 48.5 #:radius 2.75 #:hp 1500.0 #:hp-max 1500.0)
           ;; Builder SCV #201 within 12 tiles with active BUILD_COMMANDCENTER (318) at (52.5, 48.5)
           (mk-s27-unit 201 45 47.0 48.5 #:hp 45.0 #:hp-max 45.0
                        #:orders (list (sc2-unit-order 318 (sc2-point3d 52.5 48.5 8.0) 0 0.0)))
           ;; Friendly Marine #202 standing on the expansion pad (Chebyshev 0.5 <= 3.5)
           (mk-s27-unit 202 48 53.0 48.5 #:hp 45.0 #:hp-max 45.0))))
  (define cmds-pad-evac (translate-bot-actions->sc2-raw-commands '() obs-pad-evac))
  (define evac-cmd
    (findf (lambda (c)
             (and (sc2-raw-unit-command? c)
                  (= (sc2-raw-unit-command-ability-id c) 16)
                  (memv 202 (sc2-raw-unit-command-unit-tags c))))
           cmds-pad-evac))
  (assert-true! (and evac-cmd
                     (sc2-raw-unit-command-target-pos evac-cmd)
                     (>= (sqrt (+ (sqr (- (sc2-point2d-x (sc2-raw-unit-command-target-pos evac-cmd)) 52.5))
                                  (sqr (- (sc2-point2d-y (sc2-raw-unit-command-target-pos evac-cmd)) 48.5))))
                         4.5))
                "Friendly ground unit standing on active expansion pad must evacuate >= 4.5 tiles outward")
  (assert-true! (not (ormap (lambda (c)
                              (and (sc2-raw-unit-command? c)
                                   (memv 201 (sc2-raw-unit-command-unit-tags c))))
                            cmds-pad-evac))
                "Approaching expansion builder SCV (#201) must NOT be evacuated or interrupted")

  ;; ---------------------------------------------------------------------------
  ;; 27.5 Grid-Solved Terran & Protoss Walls, Depot 10.5/14.5 Hysteresis,
  ;;      1x1 Doorway Guard & Terran Add-On Swap Anti-Thrash
  ;; ---------------------------------------------------------------------------
  ;; Build 96x96 synthetic high-ground ramp + low-ground natural choke map-grids:
  ;; - Main plateau: x in [10..35], y in [28..68], height = 144, pathing = 1, placement = 1
  ;; - Main 5-tile ramp: x in [36..38], y in [46..50], height = 128, pathing = 1, placement = 0
  ;;   (cliff at x in [36..38], y < 46 or y > 50: pathing = 0, placement = 0)
  ;; - Natural basin: x in [39..59], y in [28..68], height = 112, pathing = 1, placement = 1
  ;; - Natural 7-tile choke: x in [60..62], y in [45..51], height = 112, pathing = 1, placement = 1
  ;;   (cliff walls at x in [60..62], y < 45 or y > 51: pathing = 0, placement = 0)
  ;; - Outer map: x in [63..90], y in [28..68], height = 112, pathing = 1, placement = 1
  (define rw 96)
  (define rh 96)
  (define r-path (make-bytes (* rw rh) 0))
  (define r-plac (make-bytes (* rw rh) 0))
  (define r-hgt  (make-bytes (* rw rh) 112))
  (for* ([ix (in-range 10 91)]
         [iy (in-range 28 69)])
    (cond
      [(<= ix 35)
       (bytes-set! r-path (+ ix (* iy rw)) 1)
       (bytes-set! r-plac (+ ix (* iy rw)) 1)
       (bytes-set! r-hgt  (+ ix (* iy rw)) 144)]
      [(<= ix 38)
       (bytes-set! r-hgt (+ ix (* iy rw)) 128)
       (when (and (>= iy 46) (<= iy 50))
         (bytes-set! r-path (+ ix (* iy rw)) 1)
         (bytes-set! r-plac (+ ix (* iy rw)) 0))]
      [(<= ix 59)
       (bytes-set! r-path (+ ix (* iy rw)) 1)
       (bytes-set! r-plac (+ ix (* iy rw)) 1)
       (bytes-set! r-hgt  (+ ix (* iy rw)) 112)]
      [(<= ix 62)
       (bytes-set! r-hgt (+ ix (* iy rw)) 112)
       (when (and (>= iy 45) (<= iy 51))
         (bytes-set! r-path (+ ix (* iy rw)) 1)
         (bytes-set! r-plac (+ ix (* iy rw)) 1))]
      [else
       (bytes-set! r-path (+ ix (* iy rw)) 1)
       (bytes-set! r-plac (+ ix (* iy rw)) 1)
       (bytes-set! r-hgt  (+ ix (* iy rw)) 112)]))
  (define ramp-map-grids
    (hash 'width rw
          'height rh
          'pathing-ref (lambda (ix iy) (bytes-ref r-path (+ ix (* iy rw))))
          'placement-ref (lambda (ix iy) (bytes-ref r-plac (+ ix (* iy rw))))
          'height-ref (lambda (ix iy) (bytes-ref r-hgt (+ ix (* iy rw))))))

  (define twall (solve-terran-ramp-wall 24.5 48.5 52.5 48.5 #:map-grids ramp-map-grids))
  (assert-eq! (hash-ref twall 'grid-solved? #f) #t
              "solve-terran-ramp-wall must produce grid-solved? = #t 4-connected BFS cut on synthetic ramp")
  (define td1 (hash-ref twall 'depot-1))
  (define td2 (hash-ref twall 'depot-2))
  (define trax (hash-ref twall 'barracks))
  (assert-true! (and (not (aabb-overlaps? (car td1) (cdr td1) 1.0 1.0
                                          (reserved-aabb (car trax) (cdr trax) 1.5 1.5 'wall-slot 0 0)))
                     (not (aabb-overlaps? (car td2) (cdr td2) 1.0 1.0
                                          (reserved-aabb (car trax) (cdr trax) 1.5 1.5 'wall-slot 0 0)))
                     (not (aabb-overlaps? (car td1) (cdr td1) 1.0 1.0
                                          (reserved-aabb (car td2) (cdr td2) 1.0 1.0 'wall-slot 0 0))))
                "Grid-solved Terran wall Depot1, Barracks, and Depot2 footprints must be strictly disjoint")

  ;; Supply Depot 10.5 / 14.5 hysteresis
  (define cmds-dep-raise
    (translate-bot-actions->sc2-raw-commands
     '()
     (mk-s27-obs 2000 (list (mk-s27-unit 4101 47 35.0 46.0 #:radius 1.25 #:hp 400.0 #:hp-max 400.0)
                            (mk-s27-unit 9201 105 44.0 46.0 #:alliance 4 #:hp 35.0 #:hp-max 35.0)))))
  (assert-true! (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 558)))
                       cmds-dep-raise)
                "Lowered SupplyDepot (47) with ground enemy at 9.0 tiles (<= 10.5) must emit Raise (558)")

  (define cmds-dep-deadband
    (translate-bot-actions->sc2-raw-commands
     '()
     (mk-s27-obs 2040 (list (mk-s27-unit 4101 19 35.0 46.0 #:radius 1.25 #:hp 400.0 #:hp-max 400.0)
                            (mk-s27-unit 9201 105 47.5 46.0 #:alliance 4 #:hp 35.0 #:hp-max 35.0)))))
  (assert-true! (not (ormap (lambda (c)
                              (and (sc2-raw-unit-command? c)
                                   (memv (sc2-raw-unit-command-ability-id c) '(556 558))))
                            cmds-dep-deadband))
                "Raised SupplyDepot (19) with ground enemy at 12.5 tiles (in [10.5, 14.5] hysteresis deadband) must NOT toggle")

  (define cmds-dep-lower
    (translate-bot-actions->sc2-raw-commands
     '()
     (mk-s27-obs 2080 (list (mk-s27-unit 4101 19 35.0 46.0 #:radius 1.25 #:hp 400.0 #:hp-max 400.0)
                            (mk-s27-unit 9201 105 53.0 46.0 #:alliance 4 #:hp 35.0 #:hp-max 35.0)))))
  (assert-true! (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 556)))
                       cmds-dep-lower)
                "Raised SupplyDepot (19) with ground enemy at 18.0 tiles (> 14.5) must emit Lower (556)")

  ;; Protoss matchup wall: PvT/PvP main-ramp vs PvZ natural-choke + runtime 1x1 doorway HoldPosition/step-aside
  (define pwall-pvt
    (solve-protoss-matchup-wall 24.5 48.5 52.5 48.5 'Terran
                                #:map-grids ramp-map-grids #:enemy-x 84.5 #:enemy-y 48.5))
  (define pwall-pvp
    (solve-protoss-matchup-wall 24.5 48.5 52.5 48.5 'Protoss
                                #:map-grids ramp-map-grids #:enemy-x 84.5 #:enemy-y 48.5))
  (define pwall-pvz
    (solve-protoss-matchup-wall 24.5 48.5 52.5 48.5 'Zerg
                                #:map-grids ramp-map-grids #:enemy-x 84.5 #:enemy-y 48.5))
  (assert-eq! (hash-ref pwall-pvt 'locus #f) 'main-ramp
              "Protoss PvT wall must anchor at 'main-ramp")
  (assert-eq! (hash-ref pwall-pvp 'locus #f) 'main-ramp
              "Protoss PvP wall must anchor at 'main-ramp")
  (assert-eq! (hash-ref pwall-pvz 'locus #f) 'natural-choke
              "Protoss PvZ wall must anchor at 'natural-choke")
  (assert-true! (and (pair? (hash-ref pwall-pvz 'door #f))
                     (pair? (hash-ref pwall-pvz 'door-park #f))
                     (pair? (hash-ref pwall-pvz 'pylon #f))
                     (pair? (hash-ref pwall-pvz 'slot-1 #f))
                     (pair? (hash-ref pwall-pvz 'slot-2 #f)))
                "Protoss PvZ wall must return door, door-park, pylon, slot-1, and slot-2 coordinates")

  ;; Runtime 1x1 doorway guard: HoldPosition seal vs friendly builder step-aside to door-park
  (define door-pt (hash-ref pwall-pvz 'door))
  (define park-pt (hash-ref pwall-pvz 'door-park))
  (define ps1 (hash-ref pwall-pvz 'slot-1))
  (define ps2 (hash-ref pwall-pvz 'slot-2))
  (define ppy (hash-ref pwall-pvz 'pylon))
  (define pvz-wall-bldgs
    (list (hash 'id 501 'type 'nexus 'x 24.5 'y 48.5 'hp 2000 'build-progress 1.0 'powered? #f)
          (hash 'id 502 'type 'nexus 'x 52.5 'y 48.5 'hp 2000 'build-progress 1.0 'powered? #f)
          (hash 'id 503 'type 'pylon 'x (car ppy) 'y (cdr ppy) 'hp 400 'build-progress 1.0 'powered? #f)
          (hash 'id 504 'type 'gateway 'x (car ps1) 'y (cdr ps1) 'hp 1000 'build-progress 1.0 'powered? #t)
          (hash 'id 505 'type 'cybernetics-core 'x (car ps2) 'y (cdr ps2) 'hp 1100 'build-progress 1.0 'powered? #t)))
  (define rt-p-door (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define res-door-seal
    (step-live-bot-runtime!
     rt-p-door
     (hash 'frame 2200 'minerals 50 'gas 50 'supply-used 28 'supply-cap 38 'supply-left 10
           'mineral-harvesters 20 'gas-harvesters 3 'enemy-race 'Zerg
           'map-grids ramp-map-grids
           'base-x 24.5 'base-y 48.5 'natural-x 52.5 'natural-y 48.5 'enemy-x 84.5 'enemy-y 48.5
           'ally-units (list (hash 'id 601 'type 'probe 'x 23.0 'y 48.5 'hp 40)
                             (hash 'id 610 'type 'zealot 'x (+ (car door-pt) 1.5) 'y (cdr door-pt)
                                   'hp 100 'shield 50 'order-ability-id 0))
           'ally-buildings pvz-wall-bldgs
           'enemy-units (list (hash 'id 9301 'type 'zergling 'x (+ (car door-pt) 6.0) 'y (cdr door-pt) 'hp 35)))))
  (assert-true! (ormap (lambda (a)
                         (and (pair? a) (eq? (car a) 'hold-position) (equal? (second a) 610)))
                       (hash-ref res-door-seal 'actions '()))
                "Protoss doorway guard Zealot (#610) must HoldPosition in 1x1 gap when Zergling approaches")

  (define res-door-stepaside
    (step-live-bot-runtime!
     rt-p-door
     (hash 'frame 2230 'minerals 50 'gas 50 'supply-used 28 'supply-cap 38 'supply-left 10
           'mineral-harvesters 20 'gas-harvesters 3 'enemy-race 'Zerg
           'map-grids ramp-map-grids
           'base-x 24.5 'base-y 48.5 'natural-x 52.5 'natural-y 48.5 'enemy-x 84.5 'enemy-y 48.5
           'ally-units (list ;; Friendly Probe #601 with active build order transiting <= 3.2 tiles from doorway
                             (hash 'id 601 'type 'probe 'x (+ (car door-pt) 1.0) 'y (cdr door-pt)
                                   'hp 40 'has-build-order? #t 'order-ability-id 880)
                             (hash 'id 610 'type 'zealot 'x (car door-pt) 'y (cdr door-pt)
                                   'hp 100 'shield 50 'order-ability-id 18))
           'ally-buildings pvz-wall-bldgs
           'enemy-units '())))
  (assert-true! (ormap (lambda (a)
                         (and (pair? a)
                              (eq? (car a) 'move)
                              (equal? (second a) 610)
                              (<= (sqrt (+ (sqr (- (third a) (car park-pt)))
                                           (sqr (- (fourth a) (cdr park-pt)))))
                                  0.5)))
                       (hash-ref res-door-stepaside 'actions '()))
                "Protoss doorway guard Zealot (#610) must step aside to door-park when friendly builder Probe transits")

  ;; plan-terran-addon-swap anti-thrash (aborts under <= 18-tile enemy threat + 448-loop relift cooldown)
  (define swap-bldgs
    (list (hash 'id 310 'type 'barracks 'x 30.5 'y 32.5 'build-progress 1.0 'order-count 0 'add-on-tag 311)
          (hash 'id 311 'type 'barracks-techlab 'x 33.0 'y 32.0 'build-progress 1.0)
          (hash 'id 312 'type 'factory 'x 30.5 'y 37.5 'build-progress 1.0 'order-count 0 'add-on-tag 0)))
  (assert-eq! (plan-terran-addon-swap
               (hash 'frame 5000 'base-x 32.0 'base-y 32.0
                     'ally-buildings swap-bldgs
                     'enemy-units (list (hash 'id 9401 'type 'stalker 'x 42.0 'y 32.0 'hp 80))))
              '()
              "plan-terran-addon-swap must abort ('()) when enemy combat unit is within 18 tiles of base")
  (define swap-acts-1
    (plan-terran-addon-swap
     (hash 'frame 5010 'base-x 32.0 'base-y 32.0 'ally-buildings swap-bldgs 'enemy-units '())))
  (assert-true! (pair? swap-acts-1)
                "plan-terran-addon-swap must emit swap actions when donor Barracks+TechLab and bare Factory are idle & safe")
  (define swap-acts-2
    (plan-terran-addon-swap
     (hash 'frame 5030 'base-x 32.0 'base-y 32.0 'ally-buildings swap-bldgs 'enemy-units '())))
  (assert-eq! swap-acts-2 '()
              "plan-terran-addon-swap must enforce 448-loop relift cooldown / claim lock without immediate re-lift thrash")

  ;; ---------------------------------------------------------------------------
  ;; 27.6 Pro Single-Scout, Worker-Rush 3-Cap, Zerg Queens/Inject/CreepTumor/Spotters/Overseer,
  ;;      Anti-SiegeTank/WidowMine Splash Micro & Z/T/P T3 Endgame Transitions
  ;; ---------------------------------------------------------------------------
  ;; Single-dispatch pro worker scout: mineral-walk home when pinched & NO 2nd worker pulled after scout dies
  (define rt-scout (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define scout-probes-f1
    (for/list ([i (in-range 14)])
      (hash 'id (+ 10 i) 'type 'probe 'x 31.0 'y 32.5 'hp 20 'shield 20)))
  (define res-scout-1
    (step-live-bot-runtime!
     rt-scout
     (hash 'frame 320 'minerals 100 'gas 0 'supply-used 14 'supply-cap 15 'supply-left 1
           'mineral-harvesters 14 'vespene-harvesters 0
           'base-x 32.5 'base-y 32.5 'natural-x 56.5 'natural-y 32.5 'enemy-x 160.5 'enemy-y 160.5
           'ally-units scout-probes-f1
           'ally-buildings (list (hash 'id 501 'type 'nexus 'x 32.5 'y 32.5 'hp 2000 'build-progress 1.0)
                                 (hash 'id 502 'type 'pylon 'x 36.0 'y 36.0 'hp 400 'build-progress 1.0))
           'enemy-units '())))
  (define sw-id (hash-ref (live-bot-runtime-last-telemetry rt-scout) 'scout-worker-id #f))
  (assert-true! (and (exact-integer? sw-id) (ormap (lambda (a) (and (pair? a) (eq? (car a) 'worker-scout)))
                                                   (hash-ref res-scout-1 'actions '())))
                "Opening Protoss step must dispatch exactly 1 scout worker")

  ;; Pinch that scout at enemy base with low HP (10 HP, 5 shield < 22) + ranged enemy Marine -> mineral-walk home!
  (define scout-probes-pinched
    (for/list ([p (in-list scout-probes-f1)])
      (if (= (hash-ref p 'id) sw-id)
          (hash 'id sw-id 'type 'probe 'x 156.0 'y 160.0 'hp 10 'shield 5)
          p)))
  (define res-scout-pinch
    (step-live-bot-runtime!
     rt-scout
     (hash 'frame 600 'minerals 100 'gas 0 'supply-used 14 'supply-cap 23 'supply-left 9
           'mineral-harvesters 13 'vespene-harvesters 0
           'base-x 32.5 'base-y 32.5 'natural-x 56.5 'natural-y 32.5 'enemy-x 160.5 'enemy-y 160.5
           'ally-units scout-probes-pinched
           'ally-buildings (list (hash 'id 501 'type 'nexus 'x 32.5 'y 32.5 'hp 2000 'build-progress 1.0)
                                 (hash 'id 502 'type 'pylon 'x 36.0 'y 36.0 'hp 400 'build-progress 1.0))
           'enemy-units (list (hash 'id 9501 'type 'marine 'x 158.0 'y 160.0 'hp 45)))))
  (assert-true! (ormap (lambda (a)
                         (and (pair? a) (eq? (car a) 'mineral-walk) (equal? (second a) sw-id)))
                       (hash-ref res-scout-pinch 'actions '()))
                "Pinched low-HP scout worker facing ranged threat must mineral-walk to HOME mineral patch")

  ;; Scout dies (removed from ally-units) -> NO 2nd worker scout is ever pulled!
  (define res-scout-dead
    (step-live-bot-runtime!
     rt-scout
     (hash 'frame 700 'minerals 100 'gas 0 'supply-used 13 'supply-cap 23 'supply-left 10
           'mineral-harvesters 13 'vespene-harvesters 0
           'base-x 32.5 'base-y 32.5 'natural-x 56.5 'natural-y 32.5 'enemy-x 160.5 'enemy-y 160.5
           'ally-units (filter (lambda (p) (not (= (hash-ref p 'id) sw-id))) scout-probes-f1)
           'ally-buildings (list (hash 'id 501 'type 'nexus 'x 32.5 'y 32.5 'hp 2000 'build-progress 1.0)
                                 (hash 'id 502 'type 'pylon 'x 36.0 'y 36.0 'hp 400 'build-progress 1.0))
           'enemy-units '())))
  (assert-true! (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'worker-scout)))
                            (hash-ref res-scout-dead 'actions '())))
                "After opening worker scout dies, bot must NEVER pull a 2nd worker off mining to scout")

  ;; Zerg InjectLarva (buff 11 skipped), matured +232-loop CreepTumor single-spread, Spotters & proactive Overseer
  (define rt-z-macro (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define z-spotter-lings
    (for/list ([i (in-range 8)])
      (hash 'id (+ 400 i) 'type 'zergling 'x (+ 48.0 (* 0.5 i)) 'y 32.5 'hp 35)))
  (define z-drones-24
    (for/list ([i (in-range 24)])
      (hash 'id (+ 200 i) 'type 'drone 'x 31.0 'y 32.5 'hp 40)))
  (define z-macro-bldgs
    (list ;; Hatchery #301 ALREADY injected (buff 11) -> must NOT be re-injected!
          (hash 'id 301 'type 'lair 'x 32.5 'y 32.5 'hp 1800 'build-progress 1.0 'buffs '(11) 'powered? #f)
          ;; Hatchery #302 UNINJECTED -> must receive inject-larva!
          (hash 'id 302 'type 'hatchery 'x 56.5 'y 32.5 'hp 1500 'build-progress 1.0 'buffs '() 'powered? #f)
          (hash 'id 303 'type 'spawning-pool 'x 36.5 'y 32.5 'hp 1000 'build-progress 1.0 'powered? #f)
          (hash 'id 304 'type 'extractor 'x 28.5 'y 35.5 'hp 500 'build-progress 1.0 'vespene-contents 1500 'powered? #f)
          (hash 'id 305 'type 'roach-warren 'x 36.5 'y 28.5 'hp 850 'build-progress 1.0 'powered? #f)
          (hash 'id 306 'type 'evolution-chamber 'x 30.5 'y 28.5 'hp 750 'build-progress 1.0 'powered? #f)
          ;; Newly spawned burrowed CreepTumor #7701 at frame 1000 -> must wait +232 frames!
          (hash 'id 7701 'type 'creep-tumor-burrowed 'x 60.5 'y 32.5 'hp 50 'build-progress 1.0 'powered? #f)))
  (define res-z-f1000
    (step-live-bot-runtime!
     rt-z-macro
     (hash 'frame 1000 'minerals 250 'gas 200 'supply-used 40 'supply-cap 54 'supply-left 14
           'mineral-harvesters 20 'gas-harvesters 4
           'researched-upgrades '(metabolic-boost zerg-missile-weapons-1 zerg-ground-armor-1)
           'base-x 32.5 'base-y 32.5 'natural-x 56.5 'natural-y 32.5 'enemy-x 160.5 'enemy-y 160.5
           'ally-units (append z-drones-24
                               z-spotter-lings
                               (list (hash 'id 510 'type 'queen 'x 33.5 'y 32.5 'hp 175 'energy 30)
                                     (hash 'id 511 'type 'queen 'x 57.5 'y 32.5 'hp 175 'energy 30)
                                     (hash 'id 520 'type 'overlord 'x 35.0 'y 35.0 'hp 200)
                                     (hash 'id 521 'type 'larva 'x 33.0 'y 31.0 'hp 25)))
           'ally-buildings z-macro-bldgs
           'enemy-units '())))
  (define acts-z-f1000 (hash-ref res-z-f1000 'actions '()))
  (assert-true! (ormap (lambda (a) (equal? a '(cast-spell 511 inject-larva 302))) acts-z-f1000)
                "Uninjected Hatchery (#302) must receive (cast-spell 511 inject-larva 302)")
  (assert-true! (not (ormap (lambda (a)
                              (and (pair? a) (eq? (car a) 'cast-spell) (>= (length a) 4)
                                   (eq? (third a) 'inject-larva) (equal? (fourth a) 301)))
                            acts-z-f1000))
                "Already-injected Lair (#301 with buff 11) must NOT receive duplicate inject-larva")
  (assert-true! (not (ormap (lambda (a)
                              (and (pair? a) (eq? (car a) 'cast) (equal? (second a) 7701)))
                            acts-z-f1000))
                "Newly spawned CreepTumor (#7701) at frame 1000 must NOT spread before +232 maturation")
  (assert-true! (not (set-member? (live-bot-runtime-used-creep-tumors rt-z-macro) 7701))
                "Unmatured CreepTumor (#7701) must NOT be prematurely blacklisted on first sight")
  (assert-true! (ormap (lambda (a) (equal? a '(morph overseer))) acts-z-f1000)
                "Zerg with ready Lair and 0 Overseers must proactively emit (morph overseer)")
  ;; Verify Zergling spotters assigned to watch posts
  (assert-true! (>= (hash-count (rt-spotter-lings rt-z-macro)) 2)
                "Zerg with >= 6 Zerglings in live game must assign 2-3 Zergling watch-post spotter scouts")

  ;; Advance to frame 1236 (>= 1000 + 232): matured CreepTumor #7701 now spreads!
  (define res-z-f1236
    (step-live-bot-runtime!
     rt-z-macro
     (hash 'frame 1236 'minerals 200 'gas 150 'supply-used 40 'supply-cap 54 'supply-left 14
           'mineral-harvesters 20 'gas-harvesters 4
           'base-x 32.5 'base-y 32.5 'natural-x 56.5 'natural-y 32.5 'enemy-x 160.5 'enemy-y 160.5
           'ally-units (append z-drones-24
                               z-spotter-lings
                               (list (hash 'id 510 'type 'queen 'x 33.5 'y 32.5 'hp 175 'energy 10)
                                     (hash 'id 511 'type 'queen 'x 57.5 'y 32.5 'hp 175 'energy 10)
                                     (hash 'id 525 'type 'overseer 'x 50.0 'y 32.5 'hp 200)))
           'ally-buildings z-macro-bldgs
           'enemy-units '())))
  (assert-true! (ormap (lambda (a)
                         (and (pair? a) (eq? (car a) 'cast) (equal? (second a) 7701)
                              (eq? (third a) 'spread-creep-tumor)))
                       (hash-ref res-z-f1236 'actions '()))
                "Matured (+232 frames) CreepTumor (#7701) must emit (cast 7701 spread-creep-tumor ...)")

  ;; Anti-Splash vs SiegeTank: < 1.40x staging pullback vs >= 1.40x 3-wing flank + staggered Corrosive Bile
  (define rt-vs-tank (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define three-sieged-tanks
    (list (hash 'id 9701 'type 'siege-tank-sieged 'x 80.0 'y 48.0 'hp 175)
          (hash 'id 9702 'type 'siege-tank-sieged 'x 81.5 'y 50.0 'hp 175)
          (hash 'id 9703 'type 'siege-tank-sieged 'x 81.5 'y 46.0 'hp 175)))
  (define res-tank-hold
    (step-live-bot-runtime!
     rt-vs-tank
     (hash 'frame 3000 'minerals 100 'gas 50 'supply-used 36 'supply-cap 54 'supply-left 18
           'mineral-harvesters 24 'gas-harvesters 3
           'base-x 32.5 'base-y 48.0 'natural-x 56.5 'natural-y 48.0 'enemy-x 140.0 'enemy-y 48.0
           'ally-units (list ;; Small outnumbered pack (< 1.40x value vs 3 Sieged Tanks) within 15 tiles
                             (hash 'id 701 'type 'roach 'x 69.0 'y 48.0 'hp 145)
                             (hash 'id 702 'type 'roach 'x 69.5 'y 49.0 'hp 145))
           'ally-buildings (list (hash 'id 301 'type 'hatchery 'x 32.5 'y 48.0 'hp 1500 'build-progress 1.0))
           'enemy-units three-sieged-tanks)))
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'kite)))
                       (hash-ref res-tank-hold 'actions '()))
                "Under-strength ground squad (< 1.40x) facing >= 2 Sieged Tanks must kite/stage back instead of trickling")

  (define overwhelming-roach-ravager
    (append (for/list ([i (in-range 10)])
              (hash 'id (+ 710 i) 'type 'roach 'x (+ 71.0 (* 0.3 i)) 'y (+ 46.5 (* 0.3 i)) 'hp 145))
            (for/list ([j (in-range 3)])
              (hash 'id (+ 730 j) 'type 'ravager 'x 72.5 'y (+ 47.0 (* 1.0 j)) 'hp 120))))
  (define res-tank-break
    (step-live-bot-runtime!
     rt-vs-tank
     (hash 'frame 3100 'minerals 100 'gas 50 'supply-used 68 'supply-cap 84 'supply-left 16
           'mineral-harvesters 36 'gas-harvesters 6
           'base-x 32.5 'base-y 48.0 'natural-x 56.5 'natural-y 48.0 'enemy-x 140.0 'enemy-y 48.0
           'ally-units overwhelming-roach-ravager
           'ally-buildings (list (hash 'id 301 'type 'hatchery 'x 32.5 'y 48.0 'hp 1500 'build-progress 1.0))
           'enemy-units three-sieged-tanks)))
  (define acts-tank-break (hash-ref res-tank-break 'actions '()))
  (define bile-casts
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (third a) 'corrosive-bile)))
            acts-tank-break))
  (assert-true! (>= (length bile-casts) 2)
                "Ravagers in range of Sieged Tank line must fire staggered Corrosive Bile casts")
  (assert-true! (ormap (lambda (a)
                         (and (pair? a) (eq? (car a) 'attack-pos) (list? (second a))))
                       acts-tank-break)
                ">= 1.40x overwhelming squad vs Sieged Tanks must execute 3-wing lateral flank (attack-pos wing-ids ...)")

  ;; Anti-Splash vs WidowMine: 1-unit sacrificial bait + pack pullback without detector,
  ;; and range-6+ sniper focus-fire + short-range pullback WITH detector!
  (define rt-vs-wm (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define cloaked-wm
    (list (hash 'id 9801 'type 'widow-mine-burrowed 'x 70.0 'y 48.0 'hp 90 'cloaked #t 'burrowed #t)))
  (define res-wm-nodet
    (step-live-bot-runtime!
     rt-vs-wm
     (hash 'frame 3200 'minerals 100 'gas 50 'supply-used 30 'supply-cap 46 'supply-left 16
           'mineral-harvesters 20 'gas-harvesters 3
           'base-x 32.5 'base-y 48.0 'natural-x 56.5 'natural-y 48.0 'enemy-x 140.0 'enemy-y 48.0
           'ally-units (list (hash 'id 751 'type 'zergling 'x 65.5 'y 48.0 'hp 35)
                             (hash 'id 752 'type 'roach 'x 65.0 'y 48.5 'hp 145)
                             (hash 'id 753 'type 'roach 'x 65.0 'y 47.5 'hp 145)
                             (hash 'id 754 'type 'roach 'x 64.5 'y 48.0 'hp 145))
           'ally-buildings (list (hash 'id 301 'type 'hatchery 'x 32.5 'y 48.0 'hp 1500 'build-progress 1.0))
           'enemy-units cloaked-wm)))
  (define acts-wm-nodet (hash-ref res-wm-nodet 'actions '()))
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'move) (equal? (second a) 751)))
                       acts-wm-nodet)
                "Without detection vs burrowed WidowMine, 1 cheapest unit (Zergling #751) must bait")
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'kite) (memv (second a) '(752 753 754))))
                       acts-wm-nodet)
                "Without detection vs burrowed WidowMine, remaining pack (#752..#754) must kite back")

  (define res-wm-det
    (step-live-bot-runtime!
     rt-vs-wm
     (hash 'frame 3300 'minerals 100 'gas 50 'supply-used 34 'supply-cap 46 'supply-left 12
           'mineral-harvesters 20 'gas-harvesters 3
           'researched-upgrades '(grooved-spines)
           'base-x 32.5 'base-y 48.0 'natural-x 56.5 'natural-y 48.0 'enemy-x 140.0 'enemy-y 48.0
           'ally-units (list (hash 'id 760 'type 'overseer 'x 66.0 'y 48.0 'hp 200)
                             (hash 'id 761 'type 'hydralisk 'x 64.5 'y 48.0 'hp 90)
                             (hash 'id 762 'type 'zergling 'x 65.5 'y 48.0 'hp 35))
           'ally-buildings (list (hash 'id 301 'type 'lair 'x 32.5 'y 48.0 'hp 1800 'build-progress 1.0))
           'enemy-units (list (hash 'id 9802 'type 'widow-mine-burrowed 'x 70.0 'y 48.0 'hp 90
                                    'cloaked #f 'burrowed #t)))))
  (define acts-wm-det (hash-ref res-wm-det 'actions '()))
  (assert-true! (ormap (lambda (a) (equal? a '(attack-unit 761 9802))) acts-wm-det)
                "With Overseer detection, range-6 Hydralisk (#761) must out-range snipe WidowMine (#9802)")
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'kite) (equal? (second a) 762))) acts-wm-det)
                "With Overseer detection, melee Zergling (#762) within splash radius must pull back")

  ;; Generalized Economy Scaling (70-worker cap, army-for-worker curve, 6-8 geysers) & Z/T/P T3 Endgame Transitions
  (assert-true! (<= (required-army-supply-for-worker-growth 20 0.0) 0.0)
                "Below 24 workers in peace, required-army-supply-for-worker-growth must allow pure opening saturation")
  (assert-true! (>= (required-army-supply-for-worker-growth 50 0.0) 14.0)
                "At 50 workers on 3 bases, required-army-supply-for-worker-growth must require meaningful standing army")

  ;; Zerg T3 Endgame (4 bases, 64 workers, Hive + UltraliskCavern + GreaterSpire + InfestationPit, 700M/600G):
  ;; scales to 6-8 Extractors and produces Ultralisk / Viper / BroodLord / Infestor!
  (define rt-z-t3 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define z-t3-units
    (append (for/list ([i (in-range 64)])
              (hash 'id (+ 1100 i) 'type 'drone 'x 32.5 'y 32.5 'hp 40))
            (for/list ([k (in-range 10)])
              (hash 'id (+ 1200 k) 'type 'hydralisk 'x 56.5 'y 32.5 'hp 90))
            (list (hash 'id 1250 'type 'corruptor 'x 56.5 'y 34.0 'hp 200)
                  (hash 'id 1251 'type 'corruptor 'x 57.5 'y 34.0 'hp 200)
                  (hash 'id 1260 'type 'overseer 'x 56.5 'y 32.5 'hp 200))
            (for/list ([l (in-range 8)])
              (hash 'id (+ 1280 l) 'type 'larva 'x 33.0 'y 33.0 'hp 25))))
  (define z-t3-bldgs
    (list (hash 'id 1301 'type 'hive 'x 32.5 'y 32.5 'hp 2500 'build-progress 1.0 'buffs '(11) 'powered? #f)
          (hash 'id 1302 'type 'hatchery 'x 56.5 'y 32.5 'hp 1500 'build-progress 1.0 'buffs '(11) 'powered? #f)
          (hash 'id 1303 'type 'hatchery 'x 32.5 'y 64.5 'hp 1500 'build-progress 1.0 'buffs '(11) 'powered? #f)
          (hash 'id 1304 'type 'hatchery 'x 64.5 'y 64.5 'hp 1500 'build-progress 1.0 'buffs '(11) 'powered? #f)
          (hash 'id 1305 'type 'spawning-pool 'x 36.5 'y 32.5 'hp 1000 'build-progress 1.0 'powered? #f)
          (hash 'id 1306 'type 'hydralisk-den 'x 36.5 'y 36.5 'hp 850 'build-progress 1.0 'powered? #f)
          (hash 'id 1307 'type 'infestation-pit 'x 40.5 'y 32.5 'hp 850 'build-progress 1.0 'powered? #f)
          (hash 'id 1308 'type 'ultralisk-cavern 'x 40.5 'y 36.5 'hp 850 'build-progress 1.0 'powered? #f)
          (hash 'id 1309 'type 'greater-spire 'x 44.5 'y 32.5 'hp 1000 'build-progress 1.0 'powered? #f)
          ;; 5 Extractors on 4 bases (< 8 desired at 64 workers / < 1000 gas!) -> scales toward 6-8 geysers!
          (hash 'id 1310 'type 'extractor 'x 32.5 'y 25.5 'hp 500 'build-progress 1.0 'powered? #f)
          (hash 'id 1311 'type 'extractor 'x 32.5 'y 39.5 'hp 500 'build-progress 1.0 'powered? #f)
          (hash 'id 1312 'type 'extractor 'x 56.5 'y 25.5 'hp 500 'build-progress 1.0 'powered? #f)
          (hash 'id 1313 'type 'extractor 'x 56.5 'y 39.5 'hp 500 'build-progress 1.0 'powered? #f)
          (hash 'id 1314 'type 'extractor 'x 32.5 'y 57.5 'hp 500 'build-progress 1.0 'powered? #f)))
  (define res-z-t3
    (step-live-bot-runtime!
     rt-z-t3
     (hash 'frame 9600 'minerals 900 'gas 700 'supply-used 118 'supply-cap 160 'supply-left 42
           'mineral-harvesters 49 'gas-harvesters 15
           'researched-upgrades '(metabolic-boost grooved-spines muscular-augments chitinous-plating anabolic-synthesis)
           'base-x 32.5 'base-y 32.5 'natural-x 56.5 'natural-y 32.5 'third-x 32.5 'third-y 64.5
           'ally-units z-t3-units
           'ally-buildings z-t3-bldgs
           'enemy-units (list (hash 'id 9910 'type 'siege-tank-sieged 'x 130.0 'y 130.0 'hp 175)))))
  (define acts-z-t3 (hash-ref res-z-t3 'actions '()))
  (assert-true! (ormap (lambda (a)
                         (or (equal? a '(train ultralisk))
                             (equal? a '(train viper))
                             (equal? a '(morph brood-lord))
                             (equal? a '(train infestor))))
                       acts-z-t3)
                "Zerg on 4 bases with Hive + UltraliskCavern + GreaterSpire must produce T3 units (Ultralisk/Viper/BroodLord/Infestor)")
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (cadr a) 'extractor)))
                       acts-z-t3)
                "Zerg on 4 bases (64 workers, 5 Extractors) must scale toward 6-8 gas geysers")

  ;; Terran T3 Endgame (3 bases, 62 workers, GhostAcademy + Armory + StarportTechLab + FusionCore):
  ;; trains Battlecruiser / Ghost / Thor / Liberator!
  (define rt-t-t3 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define t-t3-units
    (append (for/list ([i (in-range 62)])
              (hash 'id (+ 2100 i) 'type 'scv 'x 32.5 'y 32.5 'hp 45))
            (for/list ([k (in-range 12)])
              (hash 'id (+ 2200 k) 'type 'marine 'x 56.5 'y 32.5 'hp 45))
            (for/list ([t (in-range 4)])
              (hash 'id (+ 2230 t) 'type 'siege-tank 'x 55.5 'y 32.5 'hp 175))
            (list (hash 'id 2240 'type 'medivac 'x 56.5 'y 32.5 'hp 150)
                  (hash 'id 2241 'type 'medivac 'x 57.5 'y 32.5 'hp 150)
                  (hash 'id 2242 'type 'raven 'x 56.5 'y 33.5 'hp 140))))
  (define t-t3-bldgs
    (list (hash 'id 2301 'type 'orbital-command 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0 'order-count 0)
          (hash 'id 2302 'type 'orbital-command 'x 56.5 'y 32.5 'hp 1500 'build-progress 1.0 'order-count 0)
          (hash 'id 2303 'type 'planetary-fortress 'x 32.5 'y 64.5 'hp 1500 'build-progress 1.0 'order-count 0)
          (hash 'id 2304 'type 'barracks 'x 38.5 'y 32.5 'hp 1000 'build-progress 1.0 'order-count 0 'addon 'techlab)
          (hash 'id 2305 'type 'barracks-techlab 'x 41.0 'y 32.0 'hp 400 'build-progress 1.0)
          (hash 'id 2306 'type 'factory 'x 38.5 'y 37.5 'hp 1250 'build-progress 1.0 'order-count 0 'addon 'techlab)
          (hash 'id 2307 'type 'factory-techlab 'x 41.0 'y 37.0 'hp 400 'build-progress 1.0)
          (hash 'id 2308 'type 'starport 'x 38.5 'y 42.5 'hp 1300 'build-progress 1.0 'order-count 0 'addon 'techlab)
          (hash 'id 2309 'type 'starport-techlab 'x 41.0 'y 42.0 'hp 400 'build-progress 1.0)
          (hash 'id 2310 'type 'starport 'x 45.5 'y 42.5 'hp 1300 'build-progress 1.0 'order-count 0 'addon 'reactor)
          (hash 'id 2311 'type 'starport-reactor 'x 48.0 'y 42.0 'hp 400 'build-progress 1.0)
          (hash 'id 2312 'type 'engineering-bay 'x 34.5 'y 27.5 'hp 850 'build-progress 1.0)
          (hash 'id 2313 'type 'armory 'x 38.5 'y 27.5 'hp 750 'build-progress 1.0)
          (hash 'id 2314 'type 'ghost-academy 'x 42.5 'y 27.5 'hp 1250 'build-progress 1.0)
          (hash 'id 2315 'type 'fusion-core 'x 46.5 'y 27.5 'hp 750 'build-progress 1.0)))
  (define res-t-t3
    (step-live-bot-runtime!
     rt-t-t3
     (hash 'frame 9600 'minerals 900 'gas 700 'supply-used 116 'supply-cap 160 'supply-left 44
           'mineral-harvesters 44 'vespene-harvesters 18 'enemy-race 'Protoss
           'researched-upgrades '(stimpack combat-shield concussive-shells)
           'base-x 32.5 'base-y 32.5 'natural-x 56.5 'natural-y 32.5 'third-x 32.5 'third-y 64.5
           'ally-units t-t3-units
           'ally-buildings t-t3-bldgs
           'enemy-units (list (hash 'id 9920 'type 'colossus 'x 130.0 'y 130.0 'hp 200 'shield 150)))))
  (define acts-t-t3 (hash-ref res-t-t3 'actions '()))
  (assert-true! (ormap (lambda (a)
                         (or (equal? a '(train battlecruiser))
                             (equal? a '(train thor))
                             (equal? a '(train ghost))
                             (equal? a '(train liberator))
                             (equal? a '(train viking))))
                       acts-t-t3)
                "Terran on 3 bases with FusionCore + GhostAcademy + Armory must train T3 units (BC/Thor/Ghost/Liberator/Viking)")

  ;; Protoss T3 Endgame: Colossus/Carrier/Tempest + HighTemplar PsiStorm (>= 75 energy protected from Archon)
  ;; -> spent-energy (< 75 energy) HighTemplar Archon fusion!
  (define storm-ht-a (mk-s27-unit 8101 75 50.0 50.0 #:hp 40.0 #:hp-max 40.0 #:shield 40.0 #:shield-max 40.0
                                  #:energy 85.0 #:energy-max 200.0))
  (define storm-ht-b (mk-s27-unit 8102 75 51.0 50.0 #:hp 40.0 #:hp-max 40.0 #:shield 40.0 #:shield-max 40.0
                                  #:energy 80.0 #:energy-max 200.0))
  (define spent-ht-a (mk-s27-unit 8103 75 52.0 50.0 #:hp 40.0 #:hp-max 40.0 #:shield 40.0 #:shield-max 40.0
                                  #:energy 25.0 #:energy-max 200.0))
  (define spent-ht-b (mk-s27-unit 8104 75 53.0 50.0 #:hp 40.0 #:hp-max 40.0 #:shield 40.0 #:shield-max 40.0
                                  #:energy 30.0 #:energy-max 200.0))
  (assert-eq! (select-producer-tags-for-unit 'archon (list storm-ht-a storm-ht-b))
              '()
              "Storm-ready High Templars (>= 75 energy) must NEVER be consumed for Archon fusion")
  (assert-eq! (sort (select-producer-tags-for-unit 'archon (list storm-ht-a storm-ht-b spent-ht-a spent-ht-b)) <)
              '(8103 8104)
              "Archon fusion must select only spent (< 75 energy) High Templars (#8103, #8104)")

  (define rt-p-t3 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define p-t3-units
    (append (for/list ([i (in-range 64)])
              (hash 'id (+ 3100 i) 'type 'probe 'x 32.5 'y 32.5 'hp 20 'shield 20))
            (for/list ([k (in-range 8)])
              (hash 'id (+ 3200 k) 'type 'stalker 'x 68.0 'y 48.0 'hp 80 'shield 80))
            ;; 1 full-energy Storm HT (#3250, 90 energy) near clumped enemy bio + 2 spent HTs (#3251, #3252, 20 energy)
            (list (hash 'id 3250 'type 'high-templar 'x 67.0 'y 48.0 'hp 40 'shield 40 'energy 90)
                  (hash 'id 3251 'type 'high-templar 'x 35.0 'y 35.0 'hp 40 'shield 40 'energy 20)
                  (hash 'id 3252 'type 'high-templar 'x 36.0 'y 35.0 'hp 40 'shield 40 'energy 20))))
  (define p-t3-bldgs
    (list (hash 'id 3301 'type 'nexus 'x 32.5 'y 32.5 'hp 2000 'build-progress 1.0 'order-count 0 'powered? #f)
          (hash 'id 3302 'type 'nexus 'x 56.5 'y 32.5 'hp 2000 'build-progress 1.0 'order-count 0 'powered? #f)
          (hash 'id 3303 'type 'nexus 'x 32.5 'y 64.5 'hp 2000 'build-progress 1.0 'order-count 0 'powered? #f)
          (hash 'id 3304 'type 'pylon 'x 38.0 'y 36.0 'hp 400 'build-progress 1.0 'powered? #f)
          (hash 'id 3305 'type 'gateway 'x 38.5 'y 32.5 'hp 1000 'build-progress 1.0 'order-count 0 'powered? #t)
          (hash 'id 3306 'type 'cybernetics-core 'x 42.5 'y 32.5 'hp 1100 'build-progress 1.0 'powered? #t)
          (hash 'id 3307 'type 'twilight-council 'x 42.5 'y 36.5 'hp 1000 'build-progress 1.0 'powered? #t)
          (hash 'id 3308 'type 'templar-archive 'x 46.5 'y 36.5 'hp 1000 'build-progress 1.0 'powered? #t)
          (hash 'id 3309 'type 'robotics-facility 'x 38.5 'y 40.5 'hp 1000 'build-progress 1.0 'order-count 0 'powered? #t)
          (hash 'id 3310 'type 'robotics-bay 'x 42.5 'y 40.5 'hp 1000 'build-progress 1.0 'powered? #t)
          (hash 'id 3311 'type 'stargate 'x 46.5 'y 40.5 'hp 1200 'build-progress 1.0 'order-count 0 'powered? #t)
          (hash 'id 3312 'type 'fleet-beacon 'x 50.5 'y 40.5 'hp 1000 'build-progress 1.0 'powered? #t)))
  (define clumped-enemy-bio
    (for/list ([m (in-range 6)])
      (hash 'id (+ 9950 m) 'type 'marine 'x (+ 73.0 (* 0.4 m)) 'y 48.0 'hp 45)))
  (define res-p-t3
    (step-live-bot-runtime!
     rt-p-t3
     (hash 'frame 9600 'minerals 900 'gas 700 'supply-used 112 'supply-cap 160 'supply-left 48
           'mineral-harvesters 46 'gas-harvesters 18 'enemy-race 'Terran
           'researched-upgrades '(warp-gate-research charge blink psi-storm extended-thermal-lance)
           'base-x 32.5 'base-y 32.5 'natural-x 56.5 'natural-y 32.5 'third-x 32.5 'third-y 64.5
           'ally-units p-t3-units
           'ally-buildings p-t3-bldgs
           'enemy-units clumped-enemy-bio)))
  (define acts-p-t3 (hash-ref res-p-t3 'actions '()))
  (assert-true! (ormap (lambda (a)
                         (and (pair? a) (eq? (car a) 'cast-spell)
                              (equal? (second a) 3250) (eq? (third a) 'psi-storm)))
                       acts-p-t3)
                "90-energy High Templar (#3250) facing clumped enemy Marines must cast Psi Storm")
  (assert-true! (ormap (lambda (a) (equal? a '(morph archon))) acts-p-t3)
                "Spent (< 75 energy) High Templar pair (#3251, #3252) must fuse into Archon")
  (assert-true! (ormap (lambda (a)
                         (or (equal? a '(train colossus))
                             (equal? a '(train disruptor))
                             (equal? a '(train carrier))
                             (equal? a '(train tempest))))
                       acts-p-t3)
                "Protoss on 3 bases with RoboticsBay + FleetBeacon must train T3 units (Colossus/Disruptor/Carrier/Tempest)")

  ;; Verify 70-worker hard cap & < 196 combat supply ceiling
  (define rt-cap-chk (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define res-cap-chk
    (step-live-bot-runtime!
     rt-cap-chk
     (hash 'frame 12000 'minerals 1500 'gas 1000 'supply-used 198 'supply-cap 200 'supply-left 2
           'mineral-harvesters 56 'gas-harvesters 16
           'base-x 32.5 'base-y 32.5 'natural-x 56.5 'natural-y 32.5
           'ally-units (append (for/list ([i (in-range 72)])
                                 (hash 'id (+ 4100 i) 'type 'drone 'x 32.5 'y 32.5 'hp 40))
                               (for/list ([r (in-range 63)])
                                 (hash 'id (+ 4300 r) 'type 'roach 'x 56.5 'y 32.5 'hp 145))
                               (list (hash 'id 4500 'type 'larva 'x 33.0 'y 33.0 'hp 25)))
           'ally-buildings z-t3-bldgs
           'enemy-units '())))
  (assert-true! (not (member '(train drone) (hash-ref res-cap-chk 'actions '())))
                "At >= 70 workers (72 Drones), bot must strictly enforce the 70-worker hard cap")

  ;; ---------------------------------------------------------------------------
  ;; 27.7 Anti-Tie Forensics Fixes (Mined-Out Fan-Out Sweep, Orbital Corner Scan,
  ;;      7-Immortal Push Gate, Non-Depleted Gas, Static-Def Cap, cancel-building,
  ;;      Mid/Late-Game Wall Fallback, Corner-Hunter Flyers & Result=3 Tie Enum)
  ;; ---------------------------------------------------------------------------
  (define sweep-ginfo
    (sc2-game-info "MinedOutSweep-Synthetic" "" '() (cons 176 176) (list 8 8 168 168)
                   (list (sc2-point2d 32.5 32.5) (sc2-point2d 143.5 143.5))
                   #f #f #f))
  ;; Frame 4: populate cached map base clusters from initial neutral mineral fields
  (void
   (translate-bot-actions->sc2-raw-commands
    '()
    (mk-s27-obs 4 (list (mk-s27-unit 5901 132 32.5 32.5 #:energy 50.0 #:energy-max 200.0)
                        (mk-s27-unit 9501 341 26.0 32.5 #:alliance 3 #:mins 1500)
                        (mk-s27-unit 9502 341 56.0 32.5 #:alliance 3 #:mins 1500)
                        (mk-s27-unit 9503 341 149.0 143.5 #:alliance 3 #:mins 1500)))
    #:game-info sweep-ginfo
    #:enemy-base '(143.5 143.5)))
  ;; Frame 3200 (< 6000): 7 Immortals (unit-type 83, 28 supply >= 20, < 14 headcount) must push immediately!
  (define seven-immortal-push-cmds
    (translate-bot-actions->sc2-raw-commands
     '((execute-spatial-maneuver multiprong-rotate-and-pin 143.5 143.5))
     (mk-s27-obs 3200
                 (cons (mk-s27-unit 5900 59 32.5 32.5 #:hp 1000.0 #:shield 1000.0)
                       (for/list ([i (in-range 7)])
                         (mk-s27-unit (+ 5920 i) 83 (+ 38.0 i) 34.0 #:hp 200.0 #:shield 100.0))))
     #:game-info sweep-ginfo
     #:enemy-base '(143.5 143.5)))
  (assert-true! (ormap (lambda (c)
                         (and (sc2-raw-unit-command? c)
                              (= (sc2-raw-unit-command-ability-id c) 23)))
                       seven-immortal-push-cmds)
                "7 Immortals (28 combat supply >= 20, < 14 headcount) at loop 3200 must push across map immediately (#5111119 fix)")
  ;; Frame 8000: ALL mineral fields mined out (`'()`), 0 enemy units visible,
  ;; 5 Immortals (20 supply) + 2 Phoenixes (4 supply, flying) = 7 units (< 14 headcount, 24 >= 20 supply!)
  ;; plus 1 Orbital Command at 110 energy -> must ignore phantom pullback, scan corner (399), and fan out!
  (define mined-out-sweep-cmds
    (translate-bot-actions->sc2-raw-commands
     '((execute-spatial-maneuver pre-rotate-intercept-incoming-threat 56.5 32.5))
     (mk-s27-obs 8000
                 (list (mk-s27-unit 5901 132 32.5 32.5 #:energy 110.0 #:energy-max 200.0)
                       (mk-s27-unit 5911 83 38.0 34.0 #:hp 200.0 #:shield 100.0)
                       (mk-s27-unit 5912 83 39.0 34.0 #:hp 200.0 #:shield 100.0)
                       (mk-s27-unit 5913 83 40.0 34.0 #:hp 200.0 #:shield 100.0)
                       (mk-s27-unit 5914 83 41.0 34.0 #:hp 200.0 #:shield 100.0)
                       (mk-s27-unit 5915 83 42.0 34.0 #:hp 200.0 #:shield 100.0)
                       (mk-s27-unit 5916 78 40.0 36.0 #:hp 120.0 #:shield 60.0 #:flying? #t)
                       (mk-s27-unit 5917 78 41.0 36.0 #:hp 120.0 #:shield 60.0 #:flying? #t)))
     #:game-info sweep-ginfo
     #:enemy-base '(143.5 143.5)))
  (assert-true! (ormap (lambda (c)
                         (and (sc2-raw-unit-command? c)
                              (= (sc2-raw-unit-command-ability-id c) 399)
                              (equal? (sc2-raw-unit-command-unit-tags c) '(5901))))
                       mined-out-sweep-cmds)
                "Orbital Command (#5901) at >= 100 energy during mined-out endgame sweep must cast scanner-sweep (399) on unvisited corner")
  (define sweep-attack-pts
    (remove-duplicates
     (for/list ([c (in-list mined-out-sweep-cmds)]
                #:when (and (sc2-raw-unit-command? c)
                            (= (sc2-raw-unit-command-ability-id c) 23)
                            (sc2-point2d? (sc2-raw-unit-command-target-pos c))))
       (define p (sc2-raw-unit-command-target-pos c))
       (cons (sc2-point2d-x p) (sc2-point2d-y p)))))
  (assert-true! (>= (length sweep-attack-pts) 3)
                "7-unit (24-supply) army on mined-out map must fan out across >= 3 distinct sweep waypoints instead of stalling or pulling back")
  (assert-true! (for/and ([pt (in-list sweep-attack-pts)])
                  (and (>= (car pt) 11.0) (<= (car pt) 165.0)
                       (>= (cdr pt) 11.0) (<= (cdr pt) 165.0)))
                "Endgame sweep waypoints must stay strictly inside playable-area [8..168] inset bounds (never hardcoded 240.0)")

  ;; Non-depleted gas-building accounting + direct Protoss Tempest vs heavy ground siege
  (define gas-obs-h
    (sc2-observation->runtime-obs-hash
     (mk-s27-obs 3600
                 (list (mk-s27-unit 6001 59 32.5 32.5 #:hp 1000.0 #:shield 1000.0)
                       (mk-s27-unit 6010 61 28.5 35.5 #:hp 450.0 #:shield 450.0 #:vesp 0)
                       (mk-s27-unit 6011 61 36.5 29.5 #:hp 450.0 #:shield 450.0 #:vesp 1200)))))
  (define gas-bldgs-h (hash-ref gas-obs-h 'ally-buildings '()))
  (assert-eq! (hash-ref (findf (lambda (b) (= (hash-ref b 'id 0) 6010)) gas-bldgs-h) 'vespene-contents -1)
              0
              "sc2-observation->runtime-obs-hash must preserve vespene-contents=0 on depleted Assimilator")
  (define rt-dep-gas (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define res-dep-gas
    (step-live-bot-runtime!
     rt-dep-gas
     (hash 'frame 4500 'minerals 500 'gas 50 'supply-used 68 'supply-cap 94 'supply-left 26
           'mineral-harvesters 32 'gas-harvesters 0
           'base-x 32.5 'base-y 32.5 'natural-x 56.5 'natural-y 32.5
           'ally-units (append (for/list ([i (in-range 38)])
                                 (hash 'id (+ 6100 i) 'type 'probe 'x 32.5 'y 32.5 'hp 20 'shields 20))
                               (for/list ([s (in-range 10)])
                                 (hash 'id (+ 6200 s) 'type 'stalker 'x 56.5 'y 32.5 'hp 80 'shields 80)))
           'ally-buildings (list (hash 'id 6001 'type 'nexus 'x 32.5 'y 32.5 'hp 1000 'build-progress 1.0)
                                 (hash 'id 6002 'type 'nexus 'x 56.5 'y 32.5 'hp 1000 'build-progress 1.0)
                                 (hash 'id 6003 'type 'pylon 'x 36.0 'y 36.0 'hp 200 'build-progress 1.0)
                                 (hash 'id 6004 'type 'gateway 'x 38.5 'y 36.5 'hp 500 'build-progress 1.0 'powered? #t)
                                 (hash 'id 6005 'type 'cybernetics-core 'x 35.5 'y 38.5 'hp 550 'build-progress 1.0 'powered? #t)
                                 ;; 2 depleted Assimilators (vespene-contents = 0) on Main -> Natural geysers must still be taken!
                                 (hash 'id 6010 'type 'assimilator 'x 28.5 'y 35.5 'hp 450 'build-progress 1.0 'vespene-contents 0)
                                 (hash 'id 6011 'type 'assimilator 'x 36.5 'y 29.5 'hp 450 'build-progress 1.0 'vespene-contents 0))
           'enemy-units '())))
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'assimilator)))
                       (hash-ref res-dep-gas 'actions '()))
                "Depleted Assimilators (vespene-contents=0) must NOT block building fresh Assimilators on active bases")

  (define rt-tempest-direct (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define res-tempest-direct
    (step-live-bot-runtime!
     rt-tempest-direct
     (hash 'frame 6200 'minerals 550 'gas 400 'supply-used 110 'supply-cap 140 'supply-left 30
           'mineral-harvesters 48 'gas-harvesters 12
           'base-x 32.5 'base-y 32.5 'natural-x 56.5 'natural-y 32.5
           'ally-units (append (for/list ([i (in-range 60)])
                                 (hash 'id (+ 6300 i) 'type 'probe 'x 32.5 'y 32.5 'hp 20 'shields 20))
                               (for/list ([s (in-range 20)])
                                 (hash 'id (+ 6400 s) 'type 'stalker 'x 56.5 'y 32.5 'hp 80 'shields 80)))
           'ally-buildings (list (hash 'id 6301 'type 'nexus 'x 32.5 'y 32.5 'hp 1000 'build-progress 1.0)
                                 (hash 'id 6302 'type 'nexus 'x 56.5 'y 32.5 'hp 1000 'build-progress 1.0)
                                 (hash 'id 6303 'type 'nexus 'x 32.5 'y 68.5 'hp 1000 'build-progress 1.0)
                                 (hash 'id 6304 'type 'pylon 'x 36.0 'y 36.0 'hp 200 'build-progress 1.0)
                                 (hash 'id 6305 'type 'gateway 'x 38.5 'y 36.5 'hp 500 'build-progress 1.0 'powered? #t)
                                 (hash 'id 6306 'type 'cybernetics-core 'x 35.5 'y 38.5 'hp 550 'build-progress 1.0 'powered? #t)
                                 (hash 'id 6307 'type 'stargate 'x 42.5 'y 36.5 'hp 600 'build-progress 1.0 'powered? #t)
                                 (hash 'id 6308 'type 'fleet-beacon 'x 42.5 'y 40.5 'hp 500 'build-progress 1.0 'powered? #t))
           'enemy-units (list (hash 'id 9601 'type 'siege-tank-sieged 'x 96.0 'y 96.0 'hp 175)))))
  (assert-true! (member '(train tempest) (hash-ref res-tempest-direct 'actions '()))
                "Protoss with FleetBeacon facing siege-tank-sieged must train Tempest directly without requiring 2 Carriers first")

  ;; Max-supply static-defense spam cap (`<= (min 12 (* 2 active-bases))`) + `198`-supply `cancel-building` -> wire `314`
  (define max-sup-capped
    (evaluate-max-supply-manager
     #:race 'Protoss #:minerals 2500 #:gas 800 #:supply-used 200 #:supply-cap 200
     #:workers 66 #:active-bases 5
     #:ally-buildings (append (list (hash 'id 6500 'type 'forge 'build-progress 1.0 'powered? #t)
                                    (hash 'id 6501 'type 'cybernetics-core 'build-progress 1.0 'powered? #t))
                              (for/list ([i (in-range 10)])
                                (hash 'id (+ 6510 i) 'type 'photon-cannon 'build-progress 1.0 'powered? #t)))))
  (assert-eq! (max-supply-plan-fist-of-neeb-actions max-sup-capped) '()
              "evaluate-max-supply-manager must cap max-supply static defense at (min 12 (* 2 active-bases)) = 10 on 5 bases")
  (define max-sup-spore-cancel
    (evaluate-max-supply-manager
     #:race 'Zerg #:minerals 400 #:gas 200 #:supply-used 198 #:supply-cap 200
     #:workers 60 #:active-bases 4
     #:ally-buildings (list (hash 'id 6590 'type 'spawning-pool 'build-progress 1.0)
                            (hash 'id 6599 'type 'spore-crawler 'build-progress 0.35))))
  (assert-true! (member '(cancel-building 6599) (max-supply-plan-combined-actions max-sup-spore-cancel))
                "Zerg at >= 198 supply with morphing Spore Crawler (#6599) must emit (cancel-building 6599)")
  (define cancel-bldg-wire
    (translate-bot-actions->sc2-raw-commands
     '((cancel-building 6599))
     (mk-s27-obs 9000 (list (mk-s27-unit 6599 98 40.0 40.0 #:progress 0.35)))))
  (assert-true! (ormap (lambda (c)
                         (and (sc2-raw-unit-command? c)
                              (= (sc2-raw-unit-command-ability-id c) 314)
                              (equal? (sc2-raw-unit-command-unit-tags c) '(6599))))
                       cancel-bldg-wire)
                "(cancel-building 6599) must translate to SC2 raw CANCEL_BUILDINPROGRESS (314)")

  ;; Mid/late-game (`frame >= 4000`) Terran 1st Barracks rebuild fallback (not locked to exact ramp wall slot)
  (define rt-late-rax (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define res-late-rax
    (step-live-bot-runtime!
     rt-late-rax
     (hash 'frame 6500 'minerals 600 'gas 200 'supply-used 64 'supply-cap 94 'supply-left 30
           'mineral-harvesters 42 'gas-harvesters 6
           'base-x 32.5 'base-y 32.5 'natural-x 62.5 'natural-y 32.5
           'terran-ramp-wall (hash 'depot-1 (cons 50.0 42.0) 'barracks (cons 52.5 44.5) 'depot-2 (cons 55.0 46.0))
           'ally-units (for/list ([i (in-range 48)])
                         (hash 'id (+ 6600 i) 'type 'scv 'x 32.5 'y 32.5 'hp 45))
           'ally-buildings (list (hash 'id 6650 'type 'orbital-command 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                 (hash 'id 6651 'type 'orbital-command 'x 62.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                 (hash 'id 6652 'type 'orbital-command 'x 32.5 'y 68.5 'hp 1500 'build-progress 1.0)
                                 (hash 'id 6653 'type 'supply-depot-lowered 'x 50.0 'y 42.0 'hp 400 'build-progress 1.0))
           'enemy-units '())))
  (define late-rax-act
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'barracks)))
           (hash-ref res-late-rax 'actions '())))
  (assert-true! (and late-rax-act
                     (< (sqrt (+ (sqr (- (third late-rax-act) 36.5))
                                 (sqr (- (fourth late-rax-act) 36.5))))
                        8.0))
                "At frame >= 4000, rebuilding 1st Barracks must fall back to open main-base anchor instead of exact ramp wall slot")

  ;; `'flying?` / `*-flying` anti-air detection, `frame >= 6000` corner-hunter Viking + no phantom pullback, & Result=3 -> 'Tie
  (define ws-lifted
    (obs-hash->macro-world-state
     (hash 'race 'Terran 'frame 7000 'minerals 300 'gas 200 'supply-used 80 'supply-cap 110
           'ally-units '() 'ally-buildings '() 'enemy-units '()
           'enemy-buildings (list (hash 'id 9701 'type 'barracks-flying 'x 160.0 'y 160.0)))))
  (define ws-flying-key
    (obs-hash->macro-world-state
     (hash 'race 'Zerg 'frame 5000 'minerals 300 'gas 200 'supply-used 80 'supply-cap 110
           'ally-units '() 'ally-buildings '()
           'enemy-units (list (hash 'id 9702 'type 'banshee 'flying? #t 'cloaked? #t 'x 120.0 'y 120.0)))))
  (assert-true! (macro-world-state-requires-anti-air? ws-lifted)
                "Lifted enemy Terran structure (barracks-flying) in enemy-buildings must set requires-anti-air?=#t")
  (assert-true! (and (macro-world-state-requires-anti-air? ws-flying-key)
                     (macro-world-state-requires-detection? ws-flying-key))
                "Enemy unit with flying?=#t and cloaked?=#t must set requires-anti-air?=#t and requires-detection?=#t")

  (define rt-corner-t (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define res-corner-t
    (step-live-bot-runtime!
     rt-corner-t
     (hash 'frame 7200 'minerals 400 'gas 250 'supply-used 90 'supply-cap 126 'supply-left 36
           'mineral-harvesters 40 'gas-harvesters 8
           'base-x 32.5 'base-y 32.5 'natural-x 56.5 'natural-y 32.5 'enemy-x 144.0 'enemy-y 144.0
           'ally-units (append (for/list ([i (in-range 48)])
                                 (hash 'id (+ 6700 i) 'type 'scv 'x 32.5 'y 32.5 'hp 45))
                               (for/list ([m (in-range 16)])
                                 (hash 'id (+ 6760 m) 'type 'marine 'x 90.0 'y 90.0 'hp 45)))
           'ally-buildings (list (hash 'id 6801 'type 'orbital-command 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0 'energy 60)
                                 (hash 'id 6802 'type 'orbital-command 'x 56.5 'y 32.5 'hp 1500 'build-progress 1.0 'energy 60)
                                 (hash 'id 6803 'type 'orbital-command 'x 32.5 'y 68.5 'hp 1500 'build-progress 1.0 'energy 60)
                                 (hash 'id 6804 'type 'barracks 'x 38.5 'y 36.5 'hp 1000 'build-progress 1.0)
                                 (hash 'id 6805 'type 'factory 'x 44.5 'y 36.5 'hp 1250 'build-progress 1.0)
                                 (hash 'id 6806 'type 'starport 'x 44.5 'y 42.5 'hp 1300 'build-progress 1.0))
           'enemy-units '()
           'enemy-buildings '())))
  (define corner-t-acts (hash-ref res-corner-t 'actions '()))
  (assert-true! (member '(train viking) corner-t-acts)
                "At frame >= 6000 with 0 visible enemy structures, Terran with Starport must train corner-hunter Viking")
  (assert-true! (not (ormap (lambda (a)
                              (and (pair? a)
                                   (eq? (car a) 'execute-spatial-maneuver)
                                   (eq? (second a) 'pre-rotate-intercept-incoming-threat)))
                            corner-t-acts))
                "When 0 enemies and 0 enemy structures are visible, bot must never emit phantom pre-rotate-intercept-incoming-threat pullback")
  (assert-eq! (list (result-enum->symbol 1) (result-enum->symbol 2) (result-enum->symbol 3) (result-enum->symbol 4))
              '(Victory Defeat Tie Undecided)
              "s2clientprotocol Result enum must map 1->Victory, 2->Defeat, 3->Tie, 4->Undecided"))

;; =============================================================================
;; Suite 28: Static Typed Command Witnesses, Live Loopback Expand, <5ms 16-Base
;;           Cached Latency, PvZ/East-Ramp Walls, 15/15 Pylon Recovery & 0-Reject Pipeline
;; =============================================================================
(run-suite "28. Static Typed Command Witnesses, Loopback Expand, <5ms 16-Base Cache, Walls & 0-Reject Wire Pipeline"
  (define (mk-s28-unit tag utype x y
                       #:alliance [alliance 1]
                       #:radius [radius 0.5]
                       #:progress [progress 1.0]
                       #:hp [hp 100.0]
                       #:hp-max [hp-max 100.0]
                       #:shield [shield 0.0]
                       #:shield-max [shield-max 0.0]
                       #:energy [energy 0.0]
                       #:energy-max [energy-max 0.0]
                       #:mins [mins 0]
                       #:vesp [vesp 0]
                       #:flying? [flying? #f]
                       #:burrowed? [burrowed? #f]
                       #:powered? [powered? #t]
                       #:orders [orders '()]
                       #:addon-tag [addon-tag 0])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 2)
              (sc2-point3d x y 8.0) 0.0 radius progress 0 #f #f #f
              hp hp-max shield shield-max energy energy-max mins vesp
              flying? burrowed? #f powered? #t orders addon-tag '()
              0 0 0.0 0 0 0 0))

  (define (mk-s28-obs loop units #:mins [mins 400] #:vesp [vesp 200] #:used [used 30] #:cap [cap 46])
    (sc2-observation loop
                     (sc2-player-common 1 mins vesp cap used 12 18 0 5 0 3)
                     units
                     '() '() #f '() '() '() '() '() '()))

  ;; ---------------------------------------------------------------------------
  ;; 28.1 Typed Racket Witness Enforcement, Wire Round-Trip & Rejection of Illegal Commands
  ;; ---------------------------------------------------------------------------
  (assert-true! (and (NoTargetAbility? (lookup-no-target-ability 32))
                     (NoTargetAbility? (lookup-no-target-ability 3692))
                     (not (lookup-point-target-ability 3692))
                     (not (lookup-point-target-ability 197))
                     (PointTargetAbility? (lookup-point-target-ability 1628))
                     (PointTargetAbility? (lookup-point-target-ability 2146))
                     (PointTargetAbility? (lookup-point-target-ability 1768))
                     (PointTargetAbility? (lookup-point-target-ability 2545)))
                "Ground-truth ability target-mode witnesses must enforce 32/3692=NoTarget, 1628/2146/1768/2545=PointTarget, 197=#f")

  ;; Round-trip encode-typed-sc2-action -> decode-typed-sc2-action across all wire variants
  (define tags-701 (make-non-empty-unit-tags '(701 702)))
  (define pt-48-52 (make-world-point2d 48.5 52.5))
  (assert-true! (and (NonEmptyUnitTags? tags-701) (WorldPoint2D? pt-48-52))
                "make-non-empty-unit-tags and make-world-point2d must construct sealed witnesses")
  (for ([t-act (in-list
                (list (WireCmdNone (or (lookup-no-target-ability 388) (error "388")) tags-701 #f)
                      (WireCmdPoint (or (lookup-point-target-ability 1628) (error "1628")) tags-701 pt-48-52 #t)
                      (or (make-wire-cmd-unit (or (lookup-unit-target-ability 251) (error "251")) tags-701 8001 #f)
                          (error "251u"))
                      (or (make-wire-cmd-archon 701 702 #f) (error "1766"))
                      (or (make-wire-camera-move 48.5 52.5 0.0) (error "cam"))
                      (or (make-wire-chat #f "glhf") (error "chat"))))])
    (define wire-b (encode-typed-sc2-action t-act))
    (define dec-act (decode-typed-sc2-action wire-b))
    (assert-true! (and (> (bytes-length wire-b) 0)
                       (TypedSc2WireAction? dec-act)
                       (equal? (encode-typed-sc2-action dec-act) wire-b))
                  (format "encode-typed-sc2-action -> decode-typed-sc2-action must round-trip ~v" t-act)))

  ;; Explicit rejection of illegal wire commands & illegal high-level S-expressions
  (reset-typed-command-gate-stats!)
  ;; 1. 320 (TERRANBUILD_REFINERY = UnitTarget) given Point2D
  (assert-eq! (validate-legacy-wire-command 320 #t 40.5 42.5 0 '(501) #f) #f
              "320 (Refinery) with Point2D must be rejected by validate-legacy-wire-command")
  (assert-eq! (encode-sc2-action (sc2-raw-unit-command 320 (sc2-point2d 40.5 42.5) 0 '(501) #f)) #""
              "encode-sc2-action must drop illegal 320 Refinery with Point2D")
  ;; 2. 251 (EFFECT_INJECTLARVA = UnitTarget) given TargetNone
  (assert-eq! (validate-legacy-wire-command 251 #f 0.0 0.0 0 '(501) #f) #f
              "251 (Inject Larva) with TargetNone must be rejected")
  (assert-eq! (encode-sc2-action (sc2-raw-unit-command 251 #f 0 '(501) #f)) #""
              "encode-sc2-action must drop illegal 251 Inject with TargetNone")
  ;; 3. 1766 (MORPH_ARCHON) with 1 tag or duplicate tags
  (assert-eq! (make-wire-cmd-archon 501 501 #f) #f
              "1766 (Archon) with duplicate Templar tag must be rejected")
  (assert-eq! (validate-legacy-wire-command 1766 #f 0.0 0.0 0 '(501) #f) #f
              "1766 (Archon) with only 1 unit tag must be rejected")
  (assert-eq! (encode-sc2-action (sc2-raw-unit-command 1766 #f 0 '(501) #f)) #""
              "encode-sc2-action must drop 1-tag Archon merge")
  ;; 4. Empty unit_tags list (raw_affects_selection wipe bug)
  (assert-eq! (make-non-empty-unit-tags '()) #f
              "Empty unit_tags list must be unrepresentable in NonEmptyUnitTags")
  (assert-eq! (validate-legacy-wire-command 23 #t 50.0 50.0 0 '() #f) #f
              "Empty unit_tags wire command must be rejected")
  (assert-eq! (encode-sc2-action (sc2-raw-unit-command 23 (sc2-point2d 50.0 50.0) 0 '() #f)) #""
              "encode-sc2-action must drop empty unit_tags command")
  ;; 5. NaN / Inf / out-of-bounds Point2D
  (assert-eq! (make-world-point2d +nan.0 32.0) #f
              "NaN coordinate must be rejected by make-world-point2d")
  (assert-eq! (make-world-point2d +inf.0 32.0) #f
              "Inf coordinate must be rejected by make-world-point2d")
  (assert-eq! (validate-legacy-wire-command 16 #t +nan.0 32.0 0 '(501) #f) #f
              "NaN point wire command must be rejected")
  (assert-true! (>= (get-total-wire-action-drop-count) 4)
                "Dropped illegal wire commands must increment wire-action-drop-count")
  ;; 6. 1-arg 'emp-round & 2-coord 'neural-parasite S-expression rejections
  (assert-true! (BotActionReject? (parse-bot-action-sexp '(cast-spell 701 emp-round 999)))
                "1-arg (cast-spell uid emp-round eid) Self-EMP bug must be rejected as BotActionReject")
  (assert-true! (BotActionReject? (parse-bot-action-sexp '(cast-spell 702 neural-parasite 55.0 60.0)))
                "2-coord (cast-spell uid neural-parasite cx cy) must be rejected as BotActionReject")

  ;; Translator fixes: Nydus Worm (1768 -> NydusNetwork 95 ONLY), EMP=1628, OracleRevelation=2146,
  ;; deleted Case E TargetNone fallback, NeuralParasite=249 TargetUnit, and newly translated gameplay intents!
  (define obs-trans-s28
    (mk-s28-obs
     2400
     (list ;; Hatchery #700 (86), Idle Drone #710 (104), Ready NydusNetwork #711 (95)
           (mk-s28-unit 700 86 32.5 32.5 #:radius 2.75 #:hp 1500.0 #:hp-max 1500.0)
           (mk-s28-unit 710 104 34.5 32.5 #:hp 40.0 #:hp-max 40.0)
           (mk-s28-unit 711 95 38.5 36.5 #:radius 1.5 #:hp 850.0 #:hp-max 850.0)
           ;; Queen #712 (126), Burrowed Infestor #713 (127), Ghost #714 (50), Oracle #715 (495)
           (mk-s28-unit 712 126 35.0 33.0 #:energy 75.0 #:energy-max 200.0)
           (mk-s28-unit 713 127 52.0 58.0 #:burrowed? #t #:energy 125.0 #:energy-max 200.0)
           (mk-s28-unit 714 50 50.0 58.0 #:energy 100.0 #:energy-max 200.0)
           (mk-s28-unit 715 495 50.0 62.0 #:flying? #t #:energy 100.0 #:energy-max 200.0)
           ;; Medivac #720 (54) + Marine #721 (48)
           (mk-s28-unit 720 54 48.0 48.0 #:flying? #t #:hp 150.0 #:hp-max 150.0)
           (mk-s28-unit 721 48 48.5 48.0 #:hp 45.0 #:hp-max 45.0)
           ;; Sentry #730 (77) + Infestor #731 (111) + Stalker #740 (74)
           (mk-s28-unit 730 77 46.0 50.0 #:energy 100.0 #:energy-max 200.0)
           (mk-s28-unit 731 111 47.0 50.0 #:energy 125.0 #:energy-max 200.0)
           (mk-s28-unit 740 74 44.0 46.0 #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0)
           ;; Barracks #750 (21, with Reactor #760) + Factory #751 (27, no addon)
           (mk-s28-unit 750 21 26.5 40.5 #:radius 1.5 #:addon-tag 760)
           (mk-s28-unit 760 6 29.0 40.0 #:radius 1.0)
           (mk-s28-unit 751 27 26.5 45.5 #:radius 1.5 #:addon-tag 0)
           ;; Enemy SiegeTank #999 (33) + Destructible Rock / Enemy Blocker #998 (110)
           (mk-s28-unit 999 33 55.0 60.0 #:alliance 4 #:hp 175.0 #:hp-max 175.0)
           (mk-s28-unit 998 110 52.5 48.5 #:alliance 4 #:hp 145.0 #:hp-max 145.0))))
  (define cmds-s28
    (translate-bot-actions->sc2-raw-commands
     '((build nydus-worm 95.0 105.0)
       (cast-spell 714 emp-round 55.0 60.0)
       (cast-spell 715 oracle-revelation 55.0 60.0)
       (infestor-burrow-cast 713 neural-parasite 999)
       (transport-juggle 720 721 46.0 46.0)
       (clear-expansion-block 998 52.5 48.5)
       (scout-sector 90.0 110.0)
       (cast-protective-buff-aura guardian-shield 46.0 50.0 4.5)
       (cast-protective-buff-aura microbial-shroud 47.0 50.0 3.5)
       (high-ground-tactics hold-high-ground 44.0 48.0 #t)
       (swap-addon 750 751)
       ;; Also verify invalid 1-arg emp-round is filtered cleanly at high-level gate:
       (cast-spell 714 emp-round 999))
     obs-trans-s28))
  (assert-eq! (length (get-last-bot-action-rejects)) 1
              "High-level filter-valid-bot-actions gate must catch the single injected 1-arg emp-round reject")
  (assert-true! (ormap (lambda (c)
                         (and (sc2-raw-unit-command? c)
                              (= (sc2-raw-unit-command-ability-id c) 1768)
                              (equal? (sc2-raw-unit-command-unit-tags c) '(711))
                              (sc2-point2d? (sc2-raw-unit-command-target-pos c))))
                       cmds-s28)
                "Nydus Worm (1768) must be dispatched to NydusNetwork (#711, unit-type 95), NEVER Drone (#710)")
  (assert-true! (not (ormap (lambda (c)
                              (and (sc2-raw-unit-command? c)
                                   (= (sc2-raw-unit-command-ability-id c) 1768)
                                   (memv 710 (sc2-raw-unit-command-unit-tags c))))
                            cmds-s28))
                "Worker Drone (#710) must NEVER receive ability 1768 (BUILD_NYDUSWORM)")
  (assert-true! (ormap (lambda (c)
                         (and (sc2-raw-unit-command? c)
                              (= (sc2-raw-unit-command-ability-id c) 1628)
                              (equal? (sc2-raw-unit-command-unit-tags c) '(714))
                              (sc2-point2d? (sc2-raw-unit-command-target-pos c))))
                       cmds-s28)
                "Ghost emp-round must emit LotV EFFECT_EMP = 1628 PointTarget")
  (assert-true! (ormap (lambda (c)
                         (and (sc2-raw-unit-command? c)
                              (= (sc2-raw-unit-command-ability-id c) 2146)
                              (equal? (sc2-raw-unit-command-unit-tags c) '(715))
                              (sc2-point2d? (sc2-raw-unit-command-target-pos c))))
                       cmds-s28)
                "Oracle oracle-revelation must emit LotV EFFECT_ORACLEREVELATION = 2146 PointTarget (NOT 1632 TRAIN_QUEEN)")
  (assert-true! (ormap (lambda (c)
                         (and (sc2-raw-unit-command? c)
                              (= (sc2-raw-unit-command-ability-id c) 249)
                              (equal? (sc2-raw-unit-command-unit-tags c) '(713))
                              (= (sc2-raw-unit-command-target-unit-tag c) 999)
                              (not (sc2-raw-unit-command-target-pos c))))
                       cmds-s28)
                "infestor-burrow-cast neural-parasite must emit 249 TargetUnit on #999 (never Point2D)")
  (assert-true! (ormap (lambda (c)
                         (and (sc2-raw-unit-command? c)
                              (= (sc2-raw-unit-command-ability-id c) 3668)
                              (equal? (sc2-raw-unit-command-unit-tags c) '(720))
                              (= (sc2-raw-unit-command-target-unit-tag c) 721)))
                       cmds-s28)
                "transport-juggle must emit LOAD_TRANSPORT (3668) TargetUnit on passenger #721")
  (assert-true! (ormap (lambda (c)
                         (and (sc2-raw-unit-command? c)
                              (= (sc2-raw-unit-command-ability-id c) 76)
                              (equal? (sc2-raw-unit-command-unit-tags c) '(730))))
                       cmds-s28)
                "cast-protective-buff-aura on Sentry must emit GuardianShield (76)")
  (assert-true! (ormap (lambda (c)
                         (and (sc2-raw-unit-command? c)
                              (= (sc2-raw-unit-command-ability-id c) 2545)
                              (equal? (sc2-raw-unit-command-unit-tags c) '(731))
                              (sc2-point2d? (sc2-raw-unit-command-target-pos c))))
                       cmds-s28)
                "cast-protective-buff-aura on Infestor must emit MicrobialShroud (2545) PointTarget")
  (assert-true! (and (ormap (lambda (c)
                              (and (sc2-raw-unit-command? c)
                                   (memv (sc2-raw-unit-command-ability-id c) '(452 3679))
                                   (memv 750 (sc2-raw-unit-command-unit-tags c))))
                            cmds-s28)
                     (ormap (lambda (c)
                              (and (sc2-raw-unit-command? c)
                                   (memv (sc2-raw-unit-command-ability-id c) '(485 3679))
                                   (memv 751 (sc2-raw-unit-command-unit-tags c))))
                            cmds-s28))
                "swap-addon must lift both grounded Barracks (#750) and Factory (#751) via LIFT (3679/452/485)")

  ;; ---------------------------------------------------------------------------
  ;; 28.2 Full 8-Mineral + 2-Geyser Live Loopback ws-conn (expand ...) Test
  ;;      & Cached 200x200 16-Base (< 5.0 ms/step) Latency
  ;; ---------------------------------------------------------------------------
  ;; Helper for full SC2 8-mineral (4 far + 4 close in L-arc) + 2-geyser base cluster around (px, py)
  (define (mk-8m2g-cluster tag0 px py)
    (append
     ;; 4 far minerals + 4 close minerals West of (px, py) at legal >= 6.5 / >= 7.5 offsets
     (list (mk-s28-unit (+ tag0 0) 341 (- px 7.5) (- py 3.5) #:alliance 3 #:radius 1.125 #:mins 1800)
           (mk-s28-unit (+ tag0 1) 483 (- px 6.5) (- py 2.5) #:alliance 3 #:radius 1.125 #:mins 900)
           (mk-s28-unit (+ tag0 2) 341 (- px 7.5) (- py 1.5) #:alliance 3 #:radius 1.125 #:mins 1800)
           (mk-s28-unit (+ tag0 3) 483 (- px 6.5) (- py 0.5) #:alliance 3 #:radius 1.125 #:mins 900)
           (mk-s28-unit (+ tag0 4) 483 (- px 6.5) (+ py 0.5) #:alliance 3 #:radius 1.125 #:mins 900)
           (mk-s28-unit (+ tag0 5) 341 (- px 7.5) (+ py 1.5) #:alliance 3 #:radius 1.125 #:mins 1800)
           (mk-s28-unit (+ tag0 6) 483 (- px 6.5) (+ py 2.5) #:alliance 3 #:radius 1.125 #:mins 900)
           (mk-s28-unit (+ tag0 7) 341 (- px 7.5) (+ py 3.5) #:alliance 3 #:radius 1.125 #:mins 1800))
     ;; 2 Vespene Geysers North & South of (px, py)
     (list (mk-s28-unit (+ tag0 8) 342 px (- py 7.0) #:alliance 3 #:radius 1.5 #:vesp 2250)
           (mk-s28-unit (+ tag0 9) 342 px (+ py 7.0) #:alliance 3 #:radius 1.5 #:vesp 2250))))

  (define-values (c-in s-out) (make-pipe))
  (define-values (s-in c-out) (make-pipe))
  (define loop-ws (sc2-ws-conn "127.0.0.1" 0 "/sc2api" c-in c-out #f 1))
  (define query-batch-sizes '())
  (define loop-srv-thd
    (thread
     (lambda ()
       (let srv-loop ()
         (define hdr2 (read-bytes 2 s-in))
         (unless (eof-object? hdr2)
           (define b0 (bytes-ref hdr2 0))
           (define b1 (bytes-ref hdr2 1))
           (define opcode (bitwise-and b0 #x0F))
           (define masked? (not (zero? (bitwise-and b1 #x80))))
           (define len7 (bitwise-and b1 #x7F))
           (define plen
             (cond [(< len7 126) len7]
                   [(= len7 126) (integer-bytes->integer (read-bytes 2 s-in) #f #t)]
                   [else (integer-bytes->integer (read-bytes 8 s-in) #f #t)]))
           (define mkey (if masked? (read-bytes 4 s-in) #f))
           (define raw (read-bytes plen s-in))
           (define payload (if masked? (mask-ws-payload raw mkey) raw))
           (when (= opcode 2)
             (define req-f (decode-protobuf-message payload))
             (define req-id-p (assoc 97 req-f))
             (define id-b (if req-id-p (encode-uint32 97 (third req-id-p)) #""))
             (define q-p (assoc 14 req-f))
             (when q-p
               (define qf (decode-protobuf-message (third q-p)))
               (define p-items (filter (lambda (e) (= (first e) 3)) qf))
               (set! query-batch-sizes (cons (length p-items) query-batch-sizes))
               ;; Reject candidate #0 (2 = CantBuildLocationInvalid) and accept candidate #1+ (1 = Success)
               ;; so pad-candidates-for-base's octagon fallback candidates are verified end-to-end!
               (define res-b
                 (apply bytes-append
                        (for/list ([_it (in-list p-items)]
                                   [idx (in-naturals)])
                          (encode-submessage-field 3 (encode-int32 1 (if (= idx 0) 2 1))))))
               (define resp (bytes-append (encode-submessage-field 14 res-b) id-b (encode-int32 99 3)))
               (define rlen (bytes-length resp))
               (define rhdr
                 (cond [(< rlen 126) (bytes #x82 rlen)]
                       [(<= rlen 65535) (bytes-append (bytes #x82 126) (integer->integer-bytes rlen 2 #f #t))]
                       [else (bytes-append (bytes #x82 127) (integer->integer-bytes rlen 8 #f #t))]))
               (write-bytes rhdr s-out)
               (write-bytes resp s-out)
               (flush-output s-out))
             (srv-loop)))))))

  (define obs-loop-exp
    (mk-s28-obs
     1600
     (append (list (mk-s28-unit 800 86 24.5 24.5 #:radius 2.75 #:hp 1500.0 #:hp-max 1500.0)
                   (mk-s28-unit 801 104 26.5 24.5 #:hp 40.0 #:hp-max 40.0))
             (mk-8m2g-cluster 8100 24.5 24.5)
             (mk-8m2g-cluster 8200 24.5 56.5))))
  (define cmds-loop-exp
    (translate-bot-actions->sc2-raw-commands '((expand 24.5 56.5)) obs-loop-exp #:ws-conn loop-ws))
  (close-output-port c-out)
  (close-input-port c-in)
  (thread-wait loop-srv-thd)
  (define exp-hatch-cmd
    (findf (lambda (c)
             (and (sc2-raw-unit-command? c)
                  (= (sc2-raw-unit-command-ability-id c) 1152)
                  (equal? (sc2-raw-unit-command-unit-tags c) '(801))))
           cmds-loop-exp))
  (assert-true! (and (pair? query-batch-sizes) (>= (first query-batch-sizes) 2))
                "Loopback ws-conn (expand ...) must send multi-candidate pad-candidates-for-base QueryPlacement batch")
  (assert-true! (and exp-hatch-cmd
                     (sc2-point2d? (sc2-raw-unit-command-target-pos exp-hatch-cmd))
                     (let ([pt (sc2-raw-unit-command-target-pos exp-hatch-cmd)])
                       (and (= (- (sc2-point2d-x pt) (floor (sc2-point2d-x pt))) 0.5)
                            (= (- (sc2-point2d-y pt) (floor (sc2-point2d-y pt))) 0.5)
                            (not (and (= (sc2-point2d-x pt) 24.5) (= (sc2-point2d-y pt) 56.5))))))
                "Loopback ws-conn (expand ...) must pick confirmed (#2) half-integer 5x5 pad when #1 is rejected")

  ;; Cached 200x200 16-base (obs + translate) latency assertion (< 5.0 ms/step)
  (define g200-w 200)
  (define g200-h 200)
  (define g200-path (sc2-image-grid 8 g200-w g200-h (make-bytes (* g200-w g200-h) 1) #f #f))
  (define g200-plac (sc2-image-grid 8 g200-w g200-h (make-bytes (* g200-w g200-h) 1) #f #f))
  (define g200-hgt  (sc2-image-grid 8 g200-w g200-h (make-bytes (* g200-w g200-h) 128) #f #f))
  (define g200-info
    (sc2-game-info "Synthetic200x200-16Base" "" '() (cons g200-w g200-h) (list 0 0 g200-w g200-h)
                   (list (sc2-point2d 24.5 24.5) (sc2-point2d 150.5 150.5))
                   g200-path g200-hgt g200-plac))
  (define bases-16-neutrals
    (append*
     (for*/list ([ix (in-range 4)]
                 [iy (in-range 4)])
       (mk-8m2g-cluster (+ 10000 (* 100 (+ (* ix 4) iy)))
                        (+ 24.5 (* 42.0 ix))
                        (+ 24.5 (* 42.0 iy))))))
  (define units-16-base
    (append (list (mk-s28-unit 900 86 24.5 24.5 #:radius 2.75 #:hp 1500.0 #:hp-max 1500.0))
            (for/list ([i (in-range 16)])
              (mk-s28-unit (+ 901 i) 104 (+ 22.0 (* 0.25 i)) 24.5 #:hp 40.0 #:hp-max 40.0))
            (for/list ([z (in-range 8)])
              (mk-s28-unit (+ 930 z) 105 (+ 40.0 (* 0.5 z)) 40.0 #:hp 35.0 #:hp-max 35.0))
            (list (mk-s28-unit 9901 48 120.0 120.0 #:alliance 4 #:hp 45.0 #:hp-max 45.0))
            bases-16-neutrals))
  ;; Warm per-map cache on step 0
  (void (sc2-observation->runtime-obs-hash (mk-s28-obs 400 units-16-base) #:game-info g200-info))
  (define lat-t0 (current-inexact-monotonic-milliseconds))
  (for ([step-k (in-range 1 9)])
    (define obs-k (mk-s28-obs (* step-k 8) units-16-base))
    (define rt-hash-k (sc2-observation->runtime-obs-hash obs-k #:game-info g200-info))
    (assert-true! (>= (length (hash-ref rt-hash-k 'expansion-candidates '())) 14)
                  "Cached 200x200 16-base converter must expose solved expansion-candidates")
    (void (translate-bot-actions->sc2-raw-commands
           '((train zergling) (attack-pos (930 931 932 933) 120.0 120.0))
           obs-k
           #:game-info g200-info)))
  (define avg-16base-step-ms (/ (- (current-inexact-monotonic-milliseconds) lat-t0) 8.0))
  (assert-true! (< avg-16base-step-ms 5.0)
                (format "Cached 200x200 16-base (obs + translate) must run in < 5.0 ms/step, got ~a ms/step"
                        avg-16base-step-ms))

  ;; ---------------------------------------------------------------------------
  ;; 28.3 Torches AIE PvZ Natural-Choke BFS Wall + Pylon AIE East-Ramp Wall
  ;;      + 15/15 Supply-Lockout Emergency In-Main Pylon Recovery
  ;; ---------------------------------------------------------------------------
  ;; Build 96x96 Torches AIE-style PvZ natural-choke + ramp grid
  (define w96 96)
  (define h96 96)
  (define pvz-path (make-bytes (* w96 h96) 0))
  (define pvz-plac (make-bytes (* w96 h96) 0))
  (define pvz-hgt  (make-bytes (* w96 h96) 112))
  (for* ([ix (in-range 10 90)]
         [iy (in-range 28 69)])
    (cond
      [(<= ix 35)
       (bytes-set! pvz-path (+ ix (* iy w96)) 1)
       (bytes-set! pvz-plac (+ ix (* iy w96)) 1)
       (bytes-set! pvz-hgt  (+ ix (* iy w96)) 144)]
      [(<= ix 38)
       (bytes-set! pvz-hgt (+ ix (* iy w96)) 128)
       (when (and (>= iy 46) (<= iy 50))
         (bytes-set! pvz-path (+ ix (* iy w96)) 1)
         (bytes-set! pvz-plac (+ ix (* iy w96)) 0))]
      [(<= ix 59)
       (bytes-set! pvz-path (+ ix (* iy w96)) 1)
       (bytes-set! pvz-plac (+ ix (* iy w96)) 1)
       (bytes-set! pvz-hgt  (+ ix (* iy w96)) 112)]
      [(<= ix 62)
       (bytes-set! pvz-hgt (+ ix (* iy w96)) 112)
       (when (and (>= iy 45) (<= iy 51))
         (bytes-set! pvz-path (+ ix (* iy w96)) 1)
         (bytes-set! pvz-plac (+ ix (* iy w96)) 1))]
      [else
       (bytes-set! pvz-path (+ ix (* iy w96)) 1)
       (bytes-set! pvz-plac (+ ix (* iy w96)) 1)
       (bytes-set! pvz-hgt  (+ ix (* iy w96)) 112)]))
  (define torches-pvz-grids
    (hash 'width w96 'height h96
          'pathing-ref (lambda (ix iy) (bytes-ref pvz-path (+ ix (* iy w96))))
          'placement-ref (lambda (ix iy) (bytes-ref pvz-plac (+ ix (* iy w96))))
          'height-ref (lambda (ix iy) (bytes-ref pvz-hgt (+ ix (* iy w96))))))
  (define wall-torches-pvz
    (solve-protoss-matchup-wall 24.5 48.5 52.5 48.5 'Zerg
                                #:map-grids torches-pvz-grids
                                #:enemy-x 84.5 #:enemy-y 48.5))
  (assert-eq! (hash-ref wall-torches-pvz 'locus #f) 'natural-choke
              "Torches AIE PvZ wall must solve at 'natural-choke")
  (assert-eq! (hash-ref wall-torches-pvz 'grid-solved? #f) #t
              "Torches AIE PvZ natural-choke wall must be grid-solved? = #t via BFS choke cut")
  (define tpvz-s1 (hash-ref wall-torches-pvz 'slot-1))
  (define tpvz-s2 (hash-ref wall-torches-pvz 'slot-2))
  (define tpvz-pyl (hash-ref wall-torches-pvz 'pylon))
  (define tpvz-door (hash-ref wall-torches-pvz 'door))
  (assert-true! (and (pair? tpvz-s1) (pair? tpvz-s2) (pair? tpvz-pyl) (pair? tpvz-door)
                     (> (car tpvz-pyl) 45.0)
                     (not (aabb-overlaps? (car tpvz-s1) (cdr tpvz-s1) 1.5 1.5
                                          (reserved-aabb (car tpvz-s2) (cdr tpvz-s2) 1.5 1.5 'wall-slot 0 0))))
                "Torches AIE PvZ natural-choke wall must place disjoint 3x3 slots + rear Pylon + 1x1 door near choke")

  ;; Pylon AIE East-facing main ramp wall (Main plateau [12..34]x[14..42] h=144 -> East ramp [35..38]x[26..30] h=128 -> Natural East (50.5, 28.5))
  (define er-path (make-bytes (* w96 h96) 0))
  (define er-plac (make-bytes (* w96 h96) 0))
  (define er-hgt  (make-bytes (* w96 h96) 112))
  (for* ([ix (in-range 12 88)]
         [iy (in-range 14 43)])
    (cond
      [(<= ix 34)
       (bytes-set! er-path (+ ix (* iy w96)) 1)
       (bytes-set! er-plac (+ ix (* iy w96)) 1)
       (bytes-set! er-hgt  (+ ix (* iy w96)) 144)]
      [(<= ix 38)
       (bytes-set! er-hgt (+ ix (* iy w96)) 128)
       (when (and (>= iy 26) (<= iy 30))
         (bytes-set! er-path (+ ix (* iy w96)) 1)
         (bytes-set! er-plac (+ ix (* iy w96)) 0))]
      [else
       (bytes-set! er-path (+ ix (* iy w96)) 1)
       (bytes-set! er-plac (+ ix (* iy w96)) 1)
       (bytes-set! er-hgt  (+ ix (* iy w96)) 112)]))
  (define pylon-east-ramp-grids
    (hash 'width w96 'height h96
          'pathing-ref (lambda (ix iy) (bytes-ref er-path (+ ix (* iy w96))))
          'placement-ref (lambda (ix iy) (bytes-ref er-plac (+ ix (* iy w96))))
          'height-ref (lambda (ix iy) (bytes-ref er-hgt (+ ix (* iy w96))))))
  (define wall-pylon-east
    (solve-protoss-matchup-wall 24.5 28.5 50.5 28.5 'Terran
                                #:map-grids pylon-east-ramp-grids
                                #:enemy-x 82.5 #:enemy-y 28.5))
  (assert-eq! (hash-ref wall-pylon-east 'locus #f) 'main-ramp
              "Pylon AIE East-ramp PvT wall must anchor at 'main-ramp")
  (assert-eq! (hash-ref wall-pylon-east 'grid-solved? #f) #t
              "Pylon AIE East-ramp wall must be grid-solved? = #t")
  (define per-pyl (hash-ref wall-pylon-east 'pylon))
  (define per-s1 (hash-ref wall-pylon-east 'slot-1))
  (define per-s2 (hash-ref wall-pylon-east 'slot-2))
  (assert-true! (and (pair? per-pyl) (pair? per-s1) (pair? per-s2)
                     (< (car per-pyl) 35.0)
                     (< (car per-s1) 35.0)
                     (< (car per-s2) 35.0))
                "Pylon AIE East-ramp wall slots and rear Pylon must sit on high-ground plateau (x < 35.0)")

  ;; 15/15 Supply-Lockout Emergency In-Main Pylon Recovery (#5119040):
  ;; At 15/15 supply-used/supply-cap (supply-left = 0) with 0 real Pylons in a live match vs Zerg,
  ;; Protoss must bypass the distant natural-choke wall Pylon and place an emergency in-main Pylon near Nexus!
  (define rt-p-15lock (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define res-p-15lock
    (step-live-bot-runtime!
     rt-p-15lock
     (hash 'frame 420 'minerals 150 'gas 0 'supply-used 15 'supply-cap 15 'supply-left 0
           'mineral-harvesters 15 'vespene-harvesters 0
           'opponent-requested-race 'Zerg
           'base-x 24.5 'base-y 48.5 'natural-x 52.5 'natural-y 48.5
           'enemy-x 84.5 'enemy-y 48.5
           'map-grids torches-pvz-grids
           'mineral-patches (list (hash 'id 601 'x 18.0 'y 48.5))
           'ally-units (for/list ([i (in-range 15)])
                         (hash 'id (+ 8400 i) 'type 'probe 'x 22.0 'y 48.5 'hp 20 'shield 20))
           'ally-buildings (list (hash 'id 8500 'type 'nexus 'x 24.5 'y 48.5
                                       'hp 1000 'shield 1000 'build-progress 1.0 'powered? #f))
           'enemy-units '()
           'enemy-buildings '())))
  (define pyl-15lock-act
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'build) (pair? (cdr a)) (eq? (cadr a) 'pylon)))
           (hash-ref res-p-15lock 'actions '())))
  (assert-true! (and pyl-15lock-act (= (length pyl-15lock-act) 4))
                "Protoss at 15/15 supply lockout with 0 Pylons must immediately emit (build pylon x y)")
  (assert-true! (<= (sqrt (+ (sqr (- (third pyl-15lock-act) 24.5))
                             (sqr (- (fourth pyl-15lock-act) 48.5))))
                    9.5)
                (format "15/15 supply-lockout recovery Pylon must anchor open in-main near Nexus (24.5, 48.5), got ~v"
                        pyl-15lock-act))

  ;; ---------------------------------------------------------------------------
  ;; 28.4 Multi-Race (Z, T, P, R) Live-Runtime -> filter-valid-bot-actions ->
  ;;      translate-bot-actions->sc2-raw-commands -> encode-typed-sc2-action
  ;;      Zero-Reject & 100% Typed Wire Verification
  ;; ---------------------------------------------------------------------------
  (reset-typed-command-gate-stats!)

  (define z-pipe-obs-rt
    (hash 'frame 3600 'minerals 500 'gas 350 'supply-used 76 'supply-cap 100 'supply-left 24
          'mineral-harvesters 32 'vespene-harvesters 6
          'base-x 32.5 'base-y 32.5 'natural-x 56.5 'natural-y 32.5 'enemy-x 144.5 'enemy-y 144.5
          'ally-units (list (hash 'id 9101 'type 'drone 'x 33.5 'y 32.5 'hp 40)
                            (hash 'id 9102 'type 'queen 'x 34.0 'y 33.0 'hp 175 'energy 75)
                            (hash 'id 9103 'type 'roach 'x 80.0 'y 80.0 'hp 145)
                            (hash 'id 9104 'type 'ravager 'x 81.0 'y 80.0 'hp 120)
                            (hash 'id 9105 'type 'infestor 'x 79.0 'y 80.0 'hp 90 'energy 120)
                            (hash 'id 9106 'type 'viper 'x 78.0 'y 80.0 'hp 150 'energy 125 'flying? #t))
          'ally-buildings (list (hash 'id 9120 'type 'lair 'x 32.5 'y 32.5 'hp 2000 'build-progress 1.0)
                                (hash 'id 9121 'type 'hatchery 'x 56.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                (hash 'id 9122 'type 'spawning-pool 'x 36.5 'y 36.5 'hp 1000 'build-progress 1.0)
                                (hash 'id 9123 'type 'roach-warren 'x 38.5 'y 36.5 'hp 850 'build-progress 1.0)
                                (hash 'id 9124 'type 'infestation-pit 'x 40.5 'y 36.5 'hp 850 'build-progress 1.0)
                                (hash 'id 9125 'type 'nydus-network 'x 42.5 'y 36.5 'hp 850 'build-progress 1.0))
          'enemy-units (list (hash 'id 9801 'type 'siege-tank-sieged 'x 86.0 'y 84.0 'hp 175)
                             (hash 'id 9802 'type 'marine 'x 85.0 'y 83.0 'hp 45)
                             (hash 'id 9803 'type 'marine 'x 85.5 'y 83.5 'hp 45)
                             (hash 'id 9804 'type 'marine 'x 86.0 'y 83.0 'hp 45))
          'enemy-buildings (list (hash 'id 9810 'type 'command-center 'x 144.5 'y 144.5 'hp 1500))))
  (define z-pipe-obs-wire
    (mk-s28-obs 3600
                (list (mk-s28-unit 9120 100 32.5 32.5 #:radius 2.75 #:hp 2000.0 #:hp-max 2000.0)
                      (mk-s28-unit 9121 86 56.5 32.5 #:radius 2.75 #:hp 1500.0 #:hp-max 1500.0)
                      (mk-s28-unit 9122 89 36.5 36.5 #:radius 1.5)
                      (mk-s28-unit 9123 97 38.5 36.5 #:radius 1.5)
                      (mk-s28-unit 9124 94 40.5 36.5 #:radius 1.5)
                      (mk-s28-unit 9125 95 42.5 36.5 #:radius 1.5)
                      (mk-s28-unit 9101 104 33.5 32.5 #:hp 40.0 #:hp-max 40.0)
                      (mk-s28-unit 9102 126 34.0 33.0 #:hp 175.0 #:hp-max 175.0 #:energy 75.0 #:energy-max 200.0)
                      (mk-s28-unit 9103 110 80.0 80.0 #:hp 145.0 #:hp-max 145.0)
                      (mk-s28-unit 9104 688 81.0 80.0 #:hp 120.0 #:hp-max 120.0)
                      (mk-s28-unit 9105 111 79.0 80.0 #:hp 90.0 #:hp-max 90.0 #:energy 120.0 #:energy-max 200.0)
                      (mk-s28-unit 9106 499 78.0 80.0 #:flying? #t #:hp 150.0 #:hp-max 150.0 #:energy 125.0 #:energy-max 200.0)
                      (mk-s28-unit 9130 151 33.0 31.0 #:hp 25.0 #:hp-max 25.0)
                      (mk-s28-unit 9801 32 86.0 84.0 #:alliance 4 #:hp 175.0 #:hp-max 175.0)
                      (mk-s28-unit 9802 48 85.0 83.0 #:alliance 4 #:hp 45.0 #:hp-max 45.0)
                      (mk-s28-unit 9803 48 85.5 83.5 #:alliance 4 #:hp 45.0 #:hp-max 45.0)
                      (mk-s28-unit 9804 48 86.0 83.0 #:alliance 4 #:hp 45.0 #:hp-max 45.0)
                      (mk-s28-unit 9810 18 144.5 144.5 #:alliance 4 #:radius 2.75 #:hp 1500.0 #:hp-max 1500.0))))

  (define t-pipe-obs-rt
    (hash 'frame 3600 'minerals 450 'gas 300 'supply-used 78 'supply-cap 102 'supply-left 24
          'mineral-harvesters 32 'vespene-harvesters 6
          'base-x 32.5 'base-y 32.5 'natural-x 56.5 'natural-y 32.5 'enemy-x 144.5 'enemy-y 144.5
          'ally-units (list (hash 'id 9201 'type 'scv 'x 33.5 'y 32.5 'hp 45)
                            (hash 'id 9202 'type 'marine 'x 80.0 'y 80.0 'hp 45)
                            (hash 'id 9203 'type 'marauder 'x 80.5 'y 80.0 'hp 125)
                            (hash 'id 9204 'type 'ghost 'x 79.5 'y 80.0 'hp 100 'energy 100)
                            (hash 'id 9205 'type 'siege-tank 'x 78.5 'y 80.0 'hp 175)
                            (hash 'id 9206 'type 'medivac 'x 78.0 'y 80.0 'hp 150 'energy 80 'flying? #t))
          'ally-buildings (list (hash 'id 9220 'type 'orbital-command 'x 32.5 'y 32.5 'hp 1500 'energy 75 'build-progress 1.0)
                                (hash 'id 9221 'type 'orbital-command 'x 56.5 'y 32.5 'hp 1500 'energy 55 'build-progress 1.0)
                                (hash 'id 9222 'type 'barracks 'x 38.5 'y 36.5 'hp 1000 'build-progress 1.0)
                                (hash 'id 9223 'type 'factory 'x 42.5 'y 36.5 'hp 1250 'build-progress 1.0)
                                (hash 'id 9224 'type 'starport 'x 46.5 'y 36.5 'hp 1300 'build-progress 1.0))
          'enemy-units (list (hash 'id 9821 'type 'archon 'x 86.0 'y 84.0 'hp 10 'shield 350)
                             (hash 'id 9822 'type 'high-templar 'x 86.5 'y 84.5 'hp 40 'shield 40 'energy 100)
                             (hash 'id 9823 'type 'zealot 'x 84.0 'y 82.0 'hp 100 'shield 50))
          'enemy-buildings (list (hash 'id 9830 'type 'nexus 'x 144.5 'y 144.5 'hp 1000 'shield 1000))))
  (define t-pipe-obs-wire
    (mk-s28-obs 3600
                (list (mk-s28-unit 9220 132 32.5 32.5 #:radius 2.75 #:hp 1500.0 #:hp-max 1500.0 #:energy 75.0 #:energy-max 200.0)
                      (mk-s28-unit 9221 132 56.5 32.5 #:radius 2.75 #:hp 1500.0 #:hp-max 1500.0 #:energy 55.0 #:energy-max 200.0)
                      (mk-s28-unit 9222 21 38.5 36.5 #:radius 1.5)
                      (mk-s28-unit 9223 27 42.5 36.5 #:radius 1.5)
                      (mk-s28-unit 9224 28 46.5 36.5 #:radius 1.5)
                      (mk-s28-unit 9201 45 33.5 32.5 #:hp 45.0 #:hp-max 45.0)
                      (mk-s28-unit 9202 48 80.0 80.0 #:hp 45.0 #:hp-max 45.0)
                      (mk-s28-unit 9203 51 80.5 80.0 #:hp 125.0 #:hp-max 125.0)
                      (mk-s28-unit 9204 50 79.5 80.0 #:hp 100.0 #:hp-max 100.0 #:energy 100.0 #:energy-max 200.0)
                      (mk-s28-unit 9205 33 78.5 80.0 #:hp 175.0 #:hp-max 175.0)
                      (mk-s28-unit 9206 54 78.0 80.0 #:flying? #t #:hp 150.0 #:hp-max 150.0 #:energy 80.0 #:energy-max 200.0)
                      (mk-s28-unit 9821 141 86.0 84.0 #:alliance 4 #:hp 10.0 #:hp-max 10.0 #:shield 350.0 #:shield-max 350.0)
                      (mk-s28-unit 9822 75 86.5 84.5 #:alliance 4 #:hp 40.0 #:hp-max 40.0 #:shield 40.0 #:shield-max 40.0 #:energy 100.0 #:energy-max 200.0)
                      (mk-s28-unit 9823 73 84.0 82.0 #:alliance 4 #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0)
                      (mk-s28-unit 9830 59 144.5 144.5 #:alliance 4 #:radius 2.75))))

  (define p-pipe-obs-rt
    (hash 'frame 3600 'minerals 450 'gas 300 'supply-used 78 'supply-cap 102 'supply-left 24
          'mineral-harvesters 32 'vespene-harvesters 6
          'base-x 32.5 'base-y 32.5 'natural-x 56.5 'natural-y 32.5 'enemy-x 144.5 'enemy-y 144.5
          'ally-units (list (hash 'id 9301 'type 'probe 'x 33.5 'y 32.5 'hp 20 'shield 20)
                            (hash 'id 9302 'type 'stalker 'x 80.0 'y 80.0 'hp 80 'shield 80)
                            (hash 'id 9303 'type 'sentry 'x 79.5 'y 80.0 'hp 40 'shield 40 'energy 100)
                            (hash 'id 9304 'type 'high-templar 'x 78.5 'y 80.0 'hp 40 'shield 40 'energy 120)
                            (hash 'id 9305 'type 'oracle 'x 78.0 'y 82.0 'hp 100 'shield 60 'energy 90 'flying? #t))
          'ally-buildings (list (hash 'id 9320 'type 'nexus 'x 32.5 'y 32.5 'hp 1000 'shield 1000 'energy 60 'build-progress 1.0)
                                (hash 'id 9321 'type 'nexus 'x 56.5 'y 32.5 'hp 1000 'shield 1000 'energy 60 'build-progress 1.0)
                                (hash 'id 9322 'type 'pylon 'x 37.0 'y 36.0 'hp 200 'shield 200 'build-progress 1.0)
                                (hash 'id 9323 'type 'gateway 'x 38.5 'y 36.5 'hp 500 'shield 500 'build-progress 1.0 'powered? #t)
                                (hash 'id 9324 'type 'cybernetics-core 'x 41.5 'y 36.5 'hp 550 'shield 550 'build-progress 1.0 'powered? #t)
                                (hash 'id 9325 'type 'robotics-facility 'x 44.5 'y 36.5 'hp 450 'shield 450 'build-progress 1.0 'powered? #t))
          'enemy-units (list (hash 'id 9841 'type 'hydralisk 'x 85.0 'y 83.0 'hp 90)
                             (hash 'id 9842 'type 'hydralisk 'x 85.5 'y 83.5 'hp 90)
                             (hash 'id 9843 'type 'lurker-burrowed 'x 86.0 'y 84.0 'hp 200 'cloaked #t 'is-burrowed #t)
                             (hash 'id 9844 'type 'infestor 'x 87.0 'y 84.0 'hp 90 'energy 100))
          'enemy-buildings (list (hash 'id 9850 'type 'lair 'x 144.5 'y 144.5 'hp 2000))))
  (define p-pipe-obs-wire
    (mk-s28-obs 3600
                (list (mk-s28-unit 9320 59 32.5 32.5 #:radius 2.75 #:energy 60.0 #:energy-max 200.0)
                      (mk-s28-unit 9321 59 56.5 32.5 #:radius 2.75 #:energy 60.0 #:energy-max 200.0)
                      (mk-s28-unit 9322 60 37.0 36.0 #:radius 1.0)
                      (mk-s28-unit 9323 62 38.5 36.5 #:radius 1.5 #:powered? #t)
                      (mk-s28-unit 9324 72 41.5 36.5 #:radius 1.5 #:powered? #t)
                      (mk-s28-unit 9325 71 44.5 36.5 #:radius 1.5 #:powered? #t)
                      (mk-s28-unit 9301 84 33.5 32.5 #:hp 20.0 #:hp-max 20.0 #:shield 20.0 #:shield-max 20.0)
                      (mk-s28-unit 9302 74 80.0 80.0 #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0)
                      (mk-s28-unit 9303 77 79.5 80.0 #:hp 40.0 #:hp-max 40.0 #:shield 40.0 #:shield-max 40.0 #:energy 100.0 #:energy-max 200.0)
                      (mk-s28-unit 9304 75 78.5 80.0 #:hp 40.0 #:hp-max 40.0 #:shield 40.0 #:shield-max 40.0 #:energy 120.0 #:energy-max 200.0)
                      (mk-s28-unit 9305 495 78.0 82.0 #:flying? #t #:hp 100.0 #:hp-max 100.0 #:shield 60.0 #:shield-max 60.0 #:energy 90.0 #:energy-max 200.0)
                      (mk-s28-unit 9841 107 85.0 83.0 #:alliance 4 #:hp 90.0 #:hp-max 90.0)
                      (mk-s28-unit 9842 107 85.5 83.5 #:alliance 4 #:hp 90.0 #:hp-max 90.0)
                      (mk-s28-unit 9843 503 86.0 84.0 #:alliance 4 #:burrowed? #t #:hp 200.0 #:hp-max 200.0)
                      (mk-s28-unit 9844 111 87.0 84.0 #:alliance 4 #:hp 90.0 #:hp-max 90.0 #:energy 100.0 #:energy-max 200.0)
                      (mk-s28-unit 9850 100 144.5 144.5 #:alliance 4 #:radius 2.75))))

  (define total-verified-wire-actions 0)
  (for ([cfg (in-list (list (list 'Mothman-Z 'Zerg z-pipe-obs-rt z-pipe-obs-wire)
                            (list 'Mothman-T 'Terran t-pipe-obs-rt t-pipe-obs-wire)
                            (list 'Mothman-P 'Protoss p-pipe-obs-rt p-pipe-obs-wire)
                            (list 'Mothman-R 'Random t-pipe-obs-rt t-pipe-obs-wire)
                            (list 'Mothman-R 'Random p-pipe-obs-rt p-pipe-obs-wire)))])
    (match-define (list bname brace obs-rt obs-w) cfg)
    (define rt-inst (make-live-bot-runtime #:bot-name bname #:race brace))
    (define step-res (step-live-bot-runtime! rt-inst obs-rt))
    (define all-step-acts
      (append (hash-ref step-res 'actions '())
              (hash-ref step-res 'mirror-actions '())))
    (define-values (valid-sexps rejects) (filter-valid-bot-actions all-step-acts))
    (assert-eq! rejects '()
                (format "~a (~a) live runtime must produce 0 BotActionRejects, got ~v"
                        bname brace rejects))
    (define wire-cmds (translate-bot-actions->sc2-raw-commands valid-sexps obs-w))
    (assert-true! (pair? wire-cmds)
                  (format "~a (~a) live runtime must translate > 0 wire commands" bname brace))
    (for ([wc (in-list wire-cmds)])
      (define typed-wc (legacy-wire-action->typed-sc2-action wc))
      (assert-true! (TypedSc2WireAction? typed-wc)
                    (format "~a (~a) wire command ~v must validate as TypedSc2WireAction" bname brace wc))
      (define wb (encode-typed-sc2-action typed-wc))
      (define rt-wc (decode-typed-sc2-action wb))
      (assert-true! (and (> (bytes-length wb) 0)
                         (TypedSc2WireAction? rt-wc)
                         (equal? (encode-sc2-action wc) wb))
                    (format "~a (~a) wire command ~v must serialize identically via encode-typed-sc2-action and round-trip"
                            bname brace wc))
      (set! total-verified-wire-actions (add1 total-verified-wire-actions)))
    (define req-act-bytes (make-request-action wire-cmds #:id 42))
    (assert-true! (> (bytes-length req-act-bytes) 0)
                  (format "~a (~a) make-request-action must serialize non-empty RequestAction packet" bname brace)))

  (assert-eq! (get-total-bot-action-reject-count) 0
              "Multi-race (Z, T, P, R) live pipeline must finish with 0 total BotActionRejects")
  (assert-eq! (get-total-wire-action-drop-count) 0
              "Multi-race (Z, T, P, R) live pipeline must finish with 0 dropped wire commands")
  (assert-true! (>= total-verified-wire-actions 15)
                "Multi-race (Z, T, P, R) live pipeline must verify >= 15 TypedSc2WireAction wire packets"))

;; =============================================================================
;; Suite 29: Adversarial Protobuf Output Differential & Schema Fuzzer (3,000 cases)
;; =============================================================================
(run-suite "29.1 Protobuf Output Differential & Schema Fuzzer (3,000 cases across C1-C4 + Wire Verifier)"
  ;; Direct wire-verifier sanity checks on clean vs hostile binary protos
  (define-values (step-ok? step-dec) (verify-sc2-request-bytes (make-request-step 4 #:id 7)))
  (assert-true! (and step-ok? (equal? step-dec '(request 12 7 (request-step 4))))
                "verify-sc2-request-bytes must accept valid RequestStep")
  (define-values (qp-ok? qp-dec)
    (verify-sc2-request-bytes
     (make-request-query-placement (list (list 1154 64.5 92.25 99)) #:id 8)))
  (assert-true! (and qp-ok? (list? qp-dec) (eq? (car qp-dec) 'request) (= (cadr qp-dec) 14))
                "verify-sc2-request-bytes must accept valid RequestQuery placement")
  (define-values (empty-req-ok? _empty-reason) (verify-sc2-request-bytes #""))
  (assert-true! (not empty-req-ok?)
                "verify-sc2-request-bytes must reject empty Request (0 oneof fields)")
  (define-values (dual-oneof-ok? _dual-reason)
    (verify-sc2-request-bytes (bytes-append (make-request-step 2) (make-request-ping))))
  (assert-true! (not dual-oneof-ok?)
                "verify-sc2-request-bytes must reject Request with 2 oneof payloads")

  ;; Deterministic 3,000-case slice across Campaigns 1-4 in < 300 ms
  (define fuzz-sum
    (run-protobuf-output-fuzz-campaigns
     #:seed #x5C2F022026
     #:c1-iters 1200
     #:c2-iters 960
     #:c3-steps 40
     #:c4-iters 800
     #:quiet? #t))
  (assert-eq! (+ (proto-fuzz-summary-c1-cases fuzz-sum)
                 (proto-fuzz-summary-c2-cases fuzz-sum)
                 (proto-fuzz-summary-c3-steps fuzz-sum)
                 (proto-fuzz-summary-c4-cases fuzz-sum))
              3000
              "Suite 29 must execute exact 3,000 deterministic fuzz cases across C1-C4")
  (assert-true! (> (proto-fuzz-summary-c1-valid-frames fuzz-sum) 1000)
                "Campaign 1 slice must verify > 1,000 non-empty valid Request/Action/Point wire frames")
  (assert-eq! (proto-fuzz-summary-c3-brain-rejects fuzz-sum) 0
              "Campaign 3 live Z/T/P/R chaos slice must emit 0 BotActionRejects")
  (assert-eq! (proto-fuzz-summary-c3-wire-drops fuzz-sum) 0
              "Campaign 3 live Z/T/P/R chaos slice must drop 0 wire commands")
  (assert-true! (> (proto-fuzz-summary-c3-valid-requests fuzz-sum) 15)
                "Campaign 3 live Z/T/P/R chaos slice must emit verified RequestAction frames")
  (assert-eq! (proto-fuzz-summary-c4-rejected fuzz-sum) 800
              "Campaign 4 negative binary mutation slice must reject 800/800 corrupted protos")
  (assert-true! (< (proto-fuzz-summary-elapsed-ms fuzz-sum) 300.0)
                (format "Suite 29 3,000-case fuzz slice must complete in < 300 ms, took ~a ms"
                        (proto-fuzz-summary-elapsed-ms fuzz-sum))))

;; ============================================================================
;; 30. Post-31ec9b5 AI Arena Forensics (#5120539-#5120546):
;;     Bugs A/B/C/D Regression Suite (Grid Calibration, 2x2/3x3 Snapping,
;;     #f Placement Lease Guard, Z/P/T Tech Progression & 12-Probe Rush Hold)
;; ============================================================================
(run-suite "30. Post-31ec9b5 Forensics: Grid Orientation, 2x2/3x3 Snapping, Z/P/T Tech & 12-Probe Rush"
  ;; 30.1 Bugs A/B/C: StartRaw 1-bpp y-flip=#t grid calibration when start_locations has
  ;;      placement_grid=1 AND pathing_grid=0 on the 5x5 TownHall pad (Magannatha/Pylon AIE)
  (define gw30 176)
  (define gh30 176)
  (define (mk-1bpp-grid-proto set-bit?)
    (define nbytes (quotient (* gw30 gh30) 8))
    (define bstr (make-bytes nbytes 0))
    ;; Encode with y-flip=#t (row = gh30 - 1 - iy) and MSB-first (lsb-first=#f)
    (for* ([iy (in-range gh30)]
           [ix (in-range gw30)]
           #:when (set-bit? ix iy))
      (define row (- gh30 1 iy))
      (define bit-idx (+ (* row gw30) ix))
      (define byte-idx (quotient bit-idx 8))
      (define bit-off (- 7 (modulo bit-idx 8)))
      (bytes-set! bstr byte-idx
                  (bitwise-ior (bytes-ref bstr byte-idx)
                               (arithmetic-shift 1 bit-off))))
    (encode-submessage-field
     1 ;; dummy wrapper stripped by caller
     (bytes-append (encode-int32 1 1)
                   (encode-submessage-field 2 (bytes-append (encode-int32 1 gw30) (encode-int32 2 gh30)))
                   (encode-bytes-field 3 bstr))))
  (define (strip-tag1 b)
    (third (first (decode-protobuf-message b))))
  ;; Main plateau [128..152] x [28..48] is buildable & walkable EXCEPT 5x5 TownHall pad [139..143] x [36..40]
  ;; where pathing_grid=0; meanwhile the unflipped mirror [128..152] x [127..147] has ambient walkable grass
  ;; around (141, 137) so naive pathing_grid 1-bit maximization at start_locations would invert y-flip!
  (define plac-img-b
    (strip-tag1
     (mk-1bpp-grid-proto
      (lambda (ix iy)
        (and (>= ix 128) (<= ix 152) (>= iy 28) (<= iy 48))))))
  (define path-img-b
    (strip-tag1
     (mk-1bpp-grid-proto
      (lambda (ix iy)
        (or (and (>= ix 128) (<= ix 152) (>= iy 28) (<= iy 48)
                 (not (and (>= ix 139) (<= ix 143) (>= iy 36) (<= iy 40))))
            ;; Unflipped mirror has 1s on [139..143] x [135..139] that previously tricked pathing_grid!
            (and (>= ix 139) (<= ix 143) (>= iy 135) (<= iy 139)))))))
  (define start-pt-b
    (bytes-append (encode-float32 1 141.5) (encode-float32 2 38.5)))
  (define start-raw-b
    (bytes-append
     (encode-submessage-field 1 (bytes-append (encode-int32 1 gw30) (encode-int32 2 gh30)))
     (encode-submessage-field 2 path-img-b)
     (encode-submessage-field 4 plac-img-b)
     (encode-submessage-field 6 start-pt-b)))
  (define resp-ginfo-b
    (bytes-append
     (encode-submessage-field 9 (encode-submessage-field 4 start-raw-b))
     (encode-int32 99 3)))
  (define ginfo30 (sc2-response-game-info (decode-sc2-response resp-ginfo-b)))
  (assert-true! (and (sc2-image-grid-y-flip? (sc2-game-info-placement-grid ginfo30))
                     (sc2-image-grid-y-flip? (sc2-game-info-pathing-grid ginfo30))
                     (eq? (sc2-image-grid-lsb-first? (sc2-game-info-placement-grid ginfo30))
                          (sc2-image-grid-lsb-first? (sc2-game-info-pathing-grid ginfo30))))
                "pathing-grid must inherit calibrated orientation from placement-grid instead of inverting on TownHall pathing_grid=0 pads")
  (assert-eq! (sc2-grid-ref (sc2-game-info-pathing-grid ginfo30) 135 38) 1
              "Main plateau tile (135, 38) adjacent to TownHall (141.5, 38.5) must decode as walkable (1)")
  (define bfs30
    (compute-ground-bfs-distances (sc2-game-info-pathing-grid ginfo30) 141.5 38.5))
  (assert-true! (and bfs30 (< (bfs30 133.5 38.5) 16.0))
                "compute-ground-bfs-distances must escape friendly 5x5 TownHall pathing_grid=0 pad (< 16 tiles, not +inf.0)")

  ;; 30.2 Bugs A/B/C: 3x3 (.5) & 2x2 (.0) spiral snapping + QueryPlacement=#f worker-lease guard
  (define cy-cands
    (collect-spiral-candidates 138.0 34.0 '() #:min-spacing 2.0 #:max-radius 8.0 #:step 1.0 #:bldg-sym 'cybernetics-core))
  (define py-cands
    (collect-spiral-candidates 141.5 38.5 '() #:min-spacing 2.0 #:max-radius 8.0 #:step 1.0 #:bldg-sym 'pylon))
  (define pool-cands
    (collect-spiral-candidates 141.5 38.5 '() #:min-spacing 2.0 #:max-radius 8.0 #:step 1.0 #:bldg-sym 'spawning-pool))
  (assert-true! (and (pair? cy-cands)
                     (for/and ([pt (in-list cy-cands)])
                       (and (= (- (sc2-point2d-x pt) (floor (sc2-point2d-x pt))) 0.5)
                            (= (- (sc2-point2d-y pt) (floor (sc2-point2d-y pt))) 0.5))))
                "3x3 CyberneticsCore candidates around integer Pylon (138.0, 34.0) must snap strictly to .5 centers")
  (assert-true! (and (pair? pool-cands)
                     (for/and ([pt (in-list pool-cands)])
                       (and (= (- (sc2-point2d-x pt) (floor (sc2-point2d-x pt))) 0.5)
                            (= (- (sc2-point2d-y pt) (floor (sc2-point2d-y pt))) 0.5))))
                "3x3 SpawningPool candidates around (141.5, 38.5) must snap strictly to .5 centers")
  (assert-true! (and (pair? py-cands)
                     (for/and ([pt (in-list py-cands)])
                       (and (= (- (sc2-point2d-x pt) (floor (sc2-point2d-x pt))) 0.0)
                            (= (- (sc2-point2d-y pt) (floor (sc2-point2d-y pt))) 0.0))))
                "2x2 Pylon candidates around half-integer TownHall (141.5, 38.5) must snap strictly to .0 centers")

  ;; Loopback ws-conn returning all 2 (CantBuildLocationInvalid): must return #f, emit 0 build cmds, and lease 0 workers!
  (define-values (c30-in s30-out) (make-pipe))
  (define-values (s30-in c30-out) (make-pipe))
  (define ws30-reject (sc2-ws-conn "127.0.0.1" 0 "/sc2api" c30-in c30-out #f 1))
  (define srv30-thd
    (thread
     (lambda ()
       (let lp ()
         (define hdr2 (read-bytes 2 s30-in))
         (unless (eof-object? hdr2)
           (define b0 (bytes-ref hdr2 0))
           (define b1 (bytes-ref hdr2 1))
           (define opcode (bitwise-and b0 #x0F))
           (define masked? (not (zero? (bitwise-and b1 #x80))))
           (define len7 (bitwise-and b1 #x7F))
           (define plen
             (cond [(< len7 126) len7]
                   [(= len7 126) (integer-bytes->integer (read-bytes 2 s30-in) #f #t)]
                   [else (integer-bytes->integer (read-bytes 8 s30-in) #f #t)]))
           (define mkey (if masked? (read-bytes 4 s30-in) #f))
           (define raw (read-bytes plen s30-in))
           (define payload (if masked? (mask-ws-payload raw mkey) raw))
           (when (= opcode 2)
             (define req-f (decode-protobuf-message payload))
             (define req-id-p (assoc 97 req-f))
             (define id-b (if req-id-p (encode-uint32 97 (third req-id-p)) #""))
             (define q-p (assoc 14 req-f))
             (when q-p
               (define qf (decode-protobuf-message (third q-p)))
               (define p-items (filter (lambda (e) (= (first e) 3)) qf))
               (define res-b
                 (apply bytes-append
                        (for/list ([_it (in-list p-items)])
                          (encode-submessage-field 3 (encode-int32 1 2)))))
               (define resp (bytes-append (encode-submessage-field 14 res-b) id-b (encode-int32 99 3)))
               (define rlen (bytes-length resp))
               (define rhdr
                 (cond [(< rlen 126) (bytes #x82 rlen)]
                       [(<= rlen 65535) (bytes-append (bytes #x82 126) (integer->integer-bytes rlen 2 #f #t))]
                       [else (bytes-append (bytes #x82 127) (integer->integer-bytes rlen 8 #f #t))]))
               (write-bytes rhdr s30-out)
               (write-bytes resp s30-out)
               (flush-output s30-out))
             (lp)))))))
  (define leases30 (make-hasheqv))
  (define obs30-z
    (sc2-observation
     1200
     (sc2-player-common 1 300 0 22 16 0 16 0 0 0 0)
     (list (sc2-unit 1 1 9001 86 1 (sc2-point3d 141.5 38.5 10.0) 0.0 2.75 1.0 0 #f #f #f
                     1500.0 1500.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #t '() 0 '() 0 16 0.0 0 0 0 0)
           (sc2-unit 1 1 9002 104 1 (sc2-point3d 139.5 38.5 10.0) 0.0 0.375 1.0 0 #f #f #f
                     40.0 40.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #t '() 0 '() 0 0 0.0 0 0 0 0))
     '() '() #f '() '() '() '() '() '()))
  (define cmds30-rej
    (translate-bot-actions->sc2-raw-commands
     '((build spawning-pool 137.5 38.5))
     obs30-z
     #:ws-conn ws30-reject
     #:role-leases leases30))
  (close-output-port c30-out)
  (close-input-port c30-in)
  (thread-wait srv30-thd)
  (assert-eq! (length (filter (lambda (c)
                                (and (sc2-raw-unit-command? c)
                                     (= (sc2-raw-unit-command-ability-id c) 1155)))
                              cmds30-rej))
              0
              "All-rejected QueryPlacement must NOT emit unverified TownHall-center BUILD_SPAWNINGPOOL (1155)")
  (assert-true! (not (unit-leased-above? leases30 9002 'harvester 1200))
                "Failed QueryPlacement (#f) must NOT leak a 224-loop 'builder lease onto Drone #9002")

  ;; 30.3 Bug C: Terran Add-On Swap Cap, 100G Starport Surcharge Exemption & Pre-Starport EngineeringBay +1
  (define live-addon-obs-techlab
    (hash 'frame 5000 'race 'Terran 'minerals 400 'gas 200 'mineral-harvesters 28
          'ally-buildings (list (hash 'id 401 'type 'barracks 'x 40.5 'y 40.5 'addon 'barracks-techlab
                                      'build-progress 1.0 'busy? #f)
                                (hash 'id 402 'type 'factory 'x 40.5 'y 45.5 'addon 'none
                                      'build-progress 1.0 'busy? #f))
          'free-addons '()))
  (assert-eq! (plan-terran-addon-swap live-addon-obs-techlab) '()
              "Live games must NEVER strip barracks-techlab off Barracks (preserving Stim/CombatShield & avoiding TechLab spam)")
  (define live-addon-obs-free
    (hash 'frame 5000 'race 'Terran 'minerals 400 'gas 200 'mineral-harvesters 28
          'ally-buildings (list (hash 'id 401 'type 'barracks 'x 40.5 'y 40.5 'addon 'barracks-reactor
                                      'build-progress 1.0 'busy? #f)
                                (hash 'id 402 'type 'factory 'x 40.5 'y 45.5 'addon 'none
                                      'build-progress 1.0 'busy? #f))
          'free-addons (list (hash 'id 499 'type 'reactor 'x 46.0 'y 40.0))))
  (assert-eq! (plan-terran-addon-swap live-addon-obs-free) '()
              "plan-terran-addon-swap must NOT lift another donor while unattached free-addons already sit on the ground")

  (define rt-t-sp (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define res-t-sp
    (step-live-bot-runtime!
     rt-t-sp
     (hash 'frame 5400 'minerals 220 'gas 110 'supply-used 42 'supply-cap 62 'supply-left 20
           'mineral-harvesters 28 'vespene-harvesters 6 'enemy-race 'Protoss
           'researched-upgrades '(stimpack)
           'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5
           'ally-units (append (for/list ([i (in-range 34)])
                                 (hash 'id (+ 5100 i) 'type 'scv 'x 32.5 'y 32.5 'hp 45))
                               (for/list ([m (in-range 6)])
                                 (hash 'id (+ 5200 m) 'type 'marine 'x 54.0 'y 32.5 'hp 45)))
           'ally-buildings (list (hash 'id 5301 'type 'orbital-command 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                 (hash 'id 5302 'type 'orbital-command 'x 58.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                 (hash 'id 5303 'type 'supply-depot 'x 36.0 'y 36.0 'hp 400 'build-progress 1.0)
                                 (hash 'id 5310 'type 'refinery 'x 29.5 'y 35.5 'hp 500 'build-progress 1.0 'vespene-contents 1200)
                                 (hash 'id 5311 'type 'refinery 'x 29.5 'y 29.5 'hp 500 'build-progress 1.0 'vespene-contents 1200)
                                 (hash 'id 5312 'type 'bunker 'x 53.0 'y 32.5 'hp 400 'build-progress 1.0)
                                 (hash 'id 5304 'type 'barracks 'x 38.5 'y 32.5 'hp 1000 'build-progress 1.0
                                       'addon 'techlab 'busy? #t 'order-count 1)
                                 (hash 'id 5305 'type 'barracks-techlab 'x 41.0 'y 32.0 'hp 400 'build-progress 1.0
                                       'busy? #f 'order-count 0)
                                 (hash 'id 5306 'type 'barracks 'x 38.5 'y 36.5 'hp 1000 'build-progress 1.0
                                       'addon 'reactor 'busy? #t 'order-count 2)
                                 (hash 'id 5307 'type 'barracks-reactor 'x 41.0 'y 36.0 'hp 400 'build-progress 1.0)
                                 (hash 'id 5308 'type 'factory 'x 44.5 'y 32.5 'hp 1250 'build-progress 1.0
                                       'busy? #f 'order-count 0)
                                 (hash 'id 5309 'type 'engineering-bay 'x 34.5 'y 28.5 'hp 850 'build-progress 1.0
                                       'busy? #f 'order-count 0))
           ;; Distant enemy army (>40 tiles away: not under-base-attack?, but live-enemy-threat-supply > 0!)
           'enemy-units (list (hash 'id 9501 'type 'stalker 'x 120.0 'y 120.0 'hp 80 'shield 80)
                              (hash 'id 9502 'type 'stalker 'x 121.0 'y 120.0 'hp 80 'shield 80)
                              (hash 'id 9503 'type 'zealot 'x 122.0 'y 120.0 'hp 100 'shield 50)))))
  (define acts-t-sp (hash-ref res-t-sp 'actions '()))
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'starport))) acts-t-sp)
                "Terran with ready Factory and 220M/110G (<150G surcharge) must immediately build 1st Starport (#5120540 fix)")
  (assert-true! (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'barracks))) acts-t-sp))
                "Terran with 2 Barracks and 0 Starports must NOT spam 3rd+ Barracks before Starport (#5119235 fix)")

  (define rt-t-upg (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define res-t-upg
    (step-live-bot-runtime!
     rt-t-upg
     (hash 'frame 5600 'minerals 200 'gas 200 'supply-used 46 'supply-cap 62 'supply-left 16
           'mineral-harvesters 30 'vespene-harvesters 6 'enemy-race 'Zerg
           'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5
           'ally-units (append (for/list ([i (in-range 34)])
                                 (hash 'id (+ 6100 i) 'type 'scv 'x 32.5 'y 32.5 'hp 45))
                               (for/list ([m (in-range 12)])
                                 (hash 'id (+ 6200 m) 'type 'marine 'x 54.0 'y 32.5 'hp 45)))
           'ally-buildings (list (hash 'id 6301 'type 'orbital-command 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                 (hash 'id 6302 'type 'orbital-command 'x 58.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                 (hash 'id 6304 'type 'barracks 'x 38.5 'y 32.5 'hp 1000 'build-progress 1.0
                                       'busy? #t 'order-count 1)
                                 (hash 'id 6308 'type 'factory 'x 44.5 'y 32.5 'hp 1250 'build-progress 1.0
                                       'busy? #t 'order-count 1)
                                 (hash 'id 6309 'type 'engineering-bay 'x 34.5 'y 28.5 'hp 850 'build-progress 1.0
                                       'busy? #f 'order-count 0))
           'enemy-units '())))
  (assert-true! (ormap (lambda (a) (equal? a '(research terran-infantry-weapons-1)))
                       (hash-ref res-t-upg 'actions '()))
                "EngineeringBay must start +1 Infantry Weapons without waiting for a Starport to exist")

  ;; 30.4 Bug D: 12-Probe Worker-Rush Defense (#5120539 & #5120546 vs Creepy_strategies)
  ;; (a) 12 Probes holding at ramp (11.5 tiles from TownHall, 17.5 tiles from minerals):
  ;;     NO trickle worker pull, Protoss places 1st Pylon in-main near Nexus!
  (define rt-p-ramp (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define ramp-12-probes
    (for/list ([i (in-range 12)])
      (hash 'id (+ 9600 i) 'type 'probe 'x (+ 44.0 (* 0.1 i)) 'y 32.5 'hp 20 'shield 20)))
  (define res-p-ramp
    (step-live-bot-runtime!
     rt-p-ramp
     (hash 'frame 620 'minerals 120 'gas 0 'supply-used 14 'supply-cap 15 'supply-left 1
           'mineral-harvesters 14 'vespene-harvesters 0
           'base-x 32.5 'base-y 32.5 'natural-x 60.5 'natural-y 32.5
           'mineral-patches (list (hash 'id 550 'x 26.5 'y 32.5))
           'ally-units (for/list ([i (in-range 14)])
                         (hash 'id (+ 7100 i) 'type 'probe 'x (+ 27.5 (* 0.3 i)) 'y 32.5 'hp 20 'shield 20))
           'ally-buildings (list (hash 'id 7001 'type 'nexus 'x 32.5 'y 32.5
                                       'hp 1000 'max-hp 1000 'shield 1000 'max-shield 1000
                                       'build-progress 1.0 'powered? #f))
           'enemy-units ramp-12-probes
           'enemy-buildings '())))
  (define acts-p-ramp (hash-ref res-p-ramp 'actions '()))
  (assert-true! (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack))) acts-p-ramp))
                "12 enemy Probes at ramp (11.5 tiles from TownHall) must NOT bait trickle worker pulls (#5120539/#5120546 fix)")
  (define pylon-act-ramp
    (findf (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'pylon))) acts-p-ramp))
  (assert-true! (and pylon-act-ramp
                     (<= (sqrt (+ (sqr (- (third pylon-act-ramp) 32.5))
                                  (sqr (- (fourth pylon-act-ramp) 32.5))))
                         9.0))
                "Under worker-rush-active?, Protoss 1st Pylon must anchor safely in-main <= 9 tiles from Nexus (never natural wall)")

  ;; (b) 12 Probes breaching mineral line (<= 5.5 tiles from patch (26.5, 32.5)), with wounded #9700 (6 HP, 0 Shield),
  ;;     shield-regenerated friendly Probe #7200 (10 HP + 20 Shield = 30 EHP), and spawned Zealot #7300:
  (define rt-p-brawl (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define brawl-12-probes
    (cons (hash 'id 9700 'type 'probe 'x 30.0 'y 32.5 'hp 6 'shield 0)
          (for/list ([i (in-range 11)])
            (hash 'id (+ 9701 i) 'type 'probe 'x (+ 29.0 (* 0.2 i)) 'y 33.0 'hp 20 'shield 20))))
  (define brawl-ally-probes
    (cons (hash 'id 7200 'type 'probe 'x 29.5 'y 32.5 'hp 10 'shield 20) ;; 30 EHP shield-regenerated Probe!
          (for/list ([i (in-range 13)])
            (hash 'id (+ 7201 i) 'type 'probe 'x (+ 27.0 (* 0.35 i)) 'y 32.5 'hp 20 'shield 20))))
  (define res-p-brawl
    (step-live-bot-runtime!
     rt-p-brawl
     (hash 'frame 1950 'minerals 100 'gas 0 'supply-used 16 'supply-cap 23 'supply-left 7
           'mineral-harvesters 14 'vespene-harvesters 0
           'base-x 32.5 'base-y 32.5 'natural-x 60.5 'natural-y 32.5
           'mineral-patches (list (hash 'id 550 'x 26.5 'y 32.5))
           'ally-units (append brawl-ally-probes
                               (list (hash 'id 7300 'type 'zealot 'x 34.0 'y 32.5 'hp 100 'shield 50)))
           'ally-buildings (list (hash 'id 7001 'type 'nexus 'x 32.5 'y 32.5
                                       'hp 1000 'max-hp 1000 'shield 900 'max-shield 1000
                                       'build-progress 1.0 'powered? #f)
                                 (hash 'id 7002 'type 'pylon 'x 35.0 'y 35.0 'hp 200 'shield 200 'build-progress 1.0)
                                 (hash 'id 7003 'type 'gateway 'x 35.5 'y 32.5 'hp 500 'shield 500
                                       'build-progress 1.0 'powered? #t))
           'enemy-units brawl-12-probes
           'enemy-buildings '())))
  (define acts-p-brawl
    (append (hash-ref res-p-brawl 'actions '())
            (hash-ref res-p-brawl 'mirror-actions '())))
  (define pulls-brawl
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack))) acts-p-brawl))
  (define pulled-brawl-ids
    (remove-duplicates (append* (map second pulls-brawl))))
  (assert-true! (memv 7200 pulled-brawl-ids)
                "Shield-regenerated Protoss Probe #7200 (10 HP + 20 Shield = 30 EHP) must re-engage in worker-rush defense")
  (assert-true! (>= (length pulled-brawl-ids) 12)
                (format "12-Probe mineral-line breach must pull >= 12 of 14 Probes simultaneously (pulled ~a)"
                        (length pulled-brawl-ids)))
  (define group-9700 (findf (lambda (a) (equal? (third a) 9700)) pulls-brawl))
  (assert-true! (and group-9700
                     (<= (length (second group-9700)) 3)
                     (andmap (lambda (a) (or (<= (third a) 0) (<= (length (second a)) 8))) pulls-brawl))
                "Mineral-line brawl must cap overkill on 6-HP Probe #9700 at <= 3 while allowing up to 8 burst swings on 40-EHP stacked Probes")
  (assert-true! (not (ormap (lambda (a)
                              (and (pair? a)
                                   (eq? (car a) 'hold-position)
                                   (equal? (second a) 7300)))
                            acts-p-brawl))
                "Spawned Zealot #7300 must NEVER lock onto distant door-guard hold-position during an in-main worker rush (#5120546 fix)")

  ;; (c) While 1st Gateway is still warping in (build-progress 0.40) under a 12-Probe rush (minerals 140, 10 Probes),
  ;;     2nd Gateway must NOT escrow 150M over replacement Probes and Nexus must train '(train probe)!
  (define rt-p-warping-gw (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define res-p-warping-gw
    (step-live-bot-runtime!
     rt-p-warping-gw
     (hash 'frame 1200 'minerals 140 'gas 0 'supply-used 10 'supply-cap 23 'supply-left 13
           'mineral-harvesters 10 'vespene-harvesters 0
           'base-x 32.5 'base-y 32.5 'natural-x 60.5 'natural-y 32.5
           'mineral-patches (list (hash 'id 550 'x 26.5 'y 32.5))
           'ally-units (for/list ([i (in-range 10)])
                         (hash 'id (+ 7400 i) 'type 'probe 'x (+ 27.5 (* 0.3 i)) 'y 32.5 'hp 20 'shield 20))
           'ally-buildings (list (hash 'id 7001 'type 'nexus 'x 32.5 'y 32.5
                                       'hp 1000 'max-hp 1000 'shield 1000 'max-shield 1000
                                       'build-progress 1.0 'powered? #f 'busy? #f 'order-count 0)
                                 (hash 'id 7002 'type 'pylon 'x 35.0 'y 35.0 'hp 200 'shield 200 'build-progress 1.0)
                                 (hash 'id 7003 'type 'gateway 'x 35.5 'y 32.5 'hp 200 'shield 200
                                       'build-progress 0.40 'powered? #t))
           'enemy-units brawl-12-probes
           'enemy-buildings '())))
  (assert-true! (member '(train probe) (hash-ref res-p-warping-gw 'actions '()))
                "Protoss with warping-in 1st Gateway and 140M under 12-Probe rush must train replacement Probe without 2nd-Gateway escrow deadlock"))

;; ============================================================================
;; 31. s2protocol-rs & Swarmy Replay Forensics (Morph Filter, Win-Chance & Battles)
;; ============================================================================
(run-suite "31. s2protocol-rs & Swarmy Replay Forensics (Morph Filter, Win-Chance & Battles)"
  ;; (a) Morph-death filter prevents Drone -> Structure and Templar -> Archon false-positive casualties
  (assert-true! (is-morph-death? "Drone" #f)
                "Drone death with killerPlayerId=#f must be classified as morph into structure")
  (assert-true! (is-morph-death? "HighTemplar" #f)
                "HighTemplar death with killerPlayerId=#f must be classified as Archon merge")
  (assert-true! (is-morph-death? "DarkTemplar" #f)
                "DarkTemplar death with killerPlayerId=#f must be classified as Archon merge")
  (assert-eq! (is-morph-death? "Drone" 2) #f
              "Drone killed by enemy player 2 is a real casualty, not a morph")
  (assert-eq! (is-morph-death? "Marine" #f) #f
              "Non-morphing unit death without killerPlayerId is not a morph")

  ;; (b) Swarmy 4-factor logistic win-chance curve (symmetry + monotonic advantage)
  (define wc-even
    (compute-swarmy-win-chance 300
                               #:p1-army 1200 #:p2-army 1200
                               #:p1-income 1400 #:p2-income 1400
                               #:p1-workers 48 #:p2-workers 48
                               #:p1-killed 600 #:p2-killed 600))
  (assert-eq! wc-even 0.5
              "Symmetric army/income/workers/trades must yield exact 0.500 win chance")
  (define wc-p1-lead
    (compute-swarmy-win-chance 600
                               #:p1-army 3800 #:p2-army 800
                               #:p1-income 2500 #:p2-income 1100
                               #:p1-workers 68 #:p2-workers 34
                               #:p1-killed 3200 #:p2-killed 900))
  (define wc-p2-lead
    (compute-swarmy-win-chance 600
                               #:p1-army 800 #:p2-army 3800
                               #:p1-income 1100 #:p2-income 2500
                               #:p1-workers 34 #:p2-workers 68
                               #:p1-killed 900 #:p2-killed 3200))
  (assert-true! (> wc-p1-lead 0.85)
                (format "Decisive P1 macro+army+trade lead at 10m must exceed 0.85 win chance (got ~a)" wc-p1-lead))
  (assert-true! (< (abs (- (+ wc-p1-lead wc-p2-lead) 1.0)) 0.002)
                "Swarmy logistic win-chance curve must be antisymmetric (P1 + P2 == 1.0)")

  ;; (c) Combat engagement clustering (<= 12s gap, <= 60s span, >= 400 resource threshold)
  (define sample-deaths
    (list
     ;; Minor 100-cost skirmish at 90s -> filtered out (< 400)
     (list 90.0 1 "Zergling" 40 40 25)
     (list 92.0 2 "Probe" 42 40 50)
     ;; Major battle 180s..191s (total 650 >= 400) -> 1 engagement
     (list 180.0 1 "Stalker" 80 80 175)
     (list 184.5 1 "Stalker" 82 80 175)
     (list 191.0 2 "Roach" 84 80 100)
     (list 195.0 2 "Ravager" 82 80 200)
     ;; Separate battle >12s later at 220s..224s (total 500 >= 400) -> 2nd engagement
     (list 220.0 1 "Immortal" 100 60 375)
     (list 224.0 2 "Hydralisk" 102 60 150)))
  (define clustered (cluster-combat-engagements sample-deaths))
  (assert-eq! (length clustered) 2
              "cluster-combat-engagements must drop <400 skirmishes and split >12s gaps into 2 battles")
  (assert-eq! (hash-ref (first clustered) 'p1_lost) 350
              "First clustered battle P1 resource loss")
  (assert-eq! (hash-ref (first clustered) 'p2_lost) 300
              "First clustered battle P2 resource loss")
  (assert-eq! (hash-ref (second clustered) 'p1_lost) 375
              "Second clustered battle P1 resource loss")

  ;; (d) Turning-point detector (>= 0.15 swing sorted by magnitude)
  (define tps
    (compute-turning-points
     (list (hasheq 'sec 120 'p1_chance 0.50)
           (hasheq 'sec 180 'p1_chance 0.54) ; +0.04 noise -> ignored
           (hasheq 'sec 240 'p1_chance 0.28) ; -0.26 swing -> #2
           (hasheq 'sec 300 'p1_chance 0.71)))) ; +0.43 swing -> #1
  (assert-eq! (length tps) 2
              "compute-turning-points must emit only >= 0.15 win-chance swings")
  (assert-eq! (hash-ref (first tps) 'delta_p1_chance) 0.43
              "Largest win-chance swing must rank first"))

;; ============================================================================
;; 32. Wave 3: Frame-0 Fast Path, Anti-Trap/Wall-Off Layouts, 3-Base Proxy & Priority Curves
;; ============================================================================
(run-suite "32. Frame-0 Fast Path, Anti-Trap/Wall-Off Layouts, 3-Base Proxy Detection & Counter-Compositions"
  (define (mk-w3-unit tag utype alliance x y [min-c 0] [radius 0.5])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 2)
              (sc2-point3d x y 10.0) 0.0 radius 1.0 0 #f #t #f
              100.0 100.0 0.0 0.0 0.0 0.0 min-c 0
              #f #f #f #t #f '() 0 '() 0 16 0.0 0 0 0 0))

  ;; 32.1 Frame-0 #:defer-expansions? #t fast path + worker split vs Frame-4 solved expansions
  (define f0-open-bytes (make-bytes (* 96 96) 1))
  (define f0-grid (sc2-image-grid 8 96 96 f0-open-bytes #f #f))
  (define f0-gi
    (sc2-game-info "Wave3Map" "" '() '(96 96) '(4 4 92 92)
                   (list (sc2-point2d 76.5 76.5))
                   f0-grid #f f0-grid))
  (define f0-units
    (append
     (list (mk-w3-unit 1001 86 1 20.5 20.5 0 2.75)) ;; Hatchery
     (for/list ([i (in-range 12)])
       (mk-w3-unit (+ 1100 i) 104 1 (+ 19.0 (* 0.25 i)) 18.0 0 0.375)) ;; 12 Drones
     (for/list ([i (in-range 8)])
       (mk-w3-unit (+ 2100 i) 341 3 (+ 15.0 (* 1.5 (modulo i 4))) (+ 14.5 (* 1.5 (quotient i 4))) 1500 1.0)) ;; Main minerals
     (for/list ([i (in-range 8)])
       (mk-w3-unit (+ 2200 i) 341 3 (+ 46.0 (* 1.5 (modulo i 4))) (+ 20.5 (* 1.5 (quotient i 4))) 1500 1.0)))) ;; Natural minerals
  (define obs-f0
    (sc2-observation 0 (sc2-player-common 1 50 0 14 12 0 12 0 0 0 3)
                     f0-units '() '() (sc2-point3d 20.5 20.5 10.0) '() '() '() '() '() '()))
  (define split-cmds-f0 (frame0-pro-worker-split-commands obs-f0))
  (assert-true! (and (pair? split-cmds-f0) (<= (length split-cmds-f0) 8))
                "Frame-0 pro worker split must immediately emit <= 8 coalesced HARVEST_GATHER commands")
  (define h-f0-deferred
    (sc2-observation->runtime-obs-hash obs-f0 #:game-info f0-gi #:defer-expansions? #t))
  (assert-true! (null? (hash-ref h-f0-deferred 'expansion-candidates '()))
                "Frame-0 #:defer-expansions? #t must skip heavy map-wide expansion pad solving")
  (define obs-f4
    (sc2-observation 4 (sc2-player-common 1 50 0 14 13 0 13 0 0 0 2)
                     f0-units '() '() (sc2-point3d 20.5 20.5 10.0) '() '() '() '() '() '()))
  (define h-f4-solved
    (sc2-observation->runtime-obs-hash obs-f4 #:game-info f0-gi #:defer-expansions? #f))
  (assert-true! (pair? (hash-ref h-f4-solved 'expansion-candidates '()))
                "Frame-4 early downtime (#:defer-expansions? #f) must solve and populate expansion-candidates")

  ;; 32.2 Exact 3-Base Proxy Detection (`not in opponent main or natural or 3rd`)
  (assert-true! (not (enemy-structure-is-proxy? 'gateway 140.0 140.0 140.0 140.0 140.0 112.0 112.0 140.0))
                "Building inside opponent main (<= 22 tiles) must NOT be classified as proxy")
  (assert-true! (not (enemy-structure-is-proxy? 'barracks 138.0 114.0 140.0 140.0 140.0 112.0 112.0 140.0))
                "Building inside opponent natural (<= 22 tiles) must NOT be classified as proxy")
  (assert-true! (not (enemy-structure-is-proxy? 'hatchery 115.0 138.0 140.0 140.0 140.0 112.0 112.0 140.0))
                "Building inside opponent 3rd base (<= 22 tiles) must NOT be classified as proxy")
  (assert-true! (enemy-structure-is-proxy? 'barracks 88.0 88.0 140.0 140.0 140.0 112.0 112.0 140.0)
                "Forward mid-map Barracks (> 22 tiles from opponent main/nat/3rd) MUST be classified as proxy")
  (assert-true! (enemy-structure-is-proxy? 'pylon 56.0 32.0 140.0 140.0 140.0 112.0 112.0 140.0)
                "Proxy Pylon near our natural (> 22 tiles from opponent main/nat/3rd) MUST be classified as proxy")
  (assert-true! (not (enemy-structure-is-proxy? 'creep-tumor-burrowed 88.0 88.0 140.0 140.0 140.0 112.0 112.0 140.0))
                "Creep Tumor must NOT be classified as a proxy building")

  ;; Forward mid-map proxy (> 34 tiles from our bases, > 22 tiles from enemy's 3 bases):
  ;; ZERO cross-map worker pull, unspoofed last-seen-main-frame, ShieldBattery + Stalker/Adept response!
  (define rt-fwd-proxy (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define res-fwd-proxy
    (step-live-bot-runtime!
     rt-fwd-proxy
     (hash 'frame 2100 'minerals 340 'gas 100 'supply-used 24 'supply-cap 31 'supply-left 7
           'mineral-harvesters 18 'vespene-harvesters 3 'enemy-race 'Terran
           'base-x 30.5 'base-y 30.5 'natural-x 56.5 'natural-y 30.5 'third-x 30.5 'third-y 58.5
           'enemy-x 145.5 'enemy-y 145.5 'enemy-natural-x 119.5 'enemy-natural-y 145.5
           'enemy-third-x 145.5 'enemy-third-y 117.5
           'ally-units (for/list ([i (in-range 21)])
                         (hash 'id (+ 8100 i) 'type 'probe 'x 30.5 'y 30.5 'hp 20 'shield 20))
           'ally-buildings (list (hash 'id 8001 'type 'nexus 'x 30.5 'y 30.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                 (hash 'id 8002 'type 'pylon 'x 35.0 'y 33.0 'hp 200 'shield 200 'build-progress 1.0)
                                 (hash 'id 8005 'type 'pylon 'x 35.0 'y 38.5 'hp 200 'shield 200 'build-progress 1.0)
                                 (hash 'id 8003 'type 'gateway 'x 36.5 'y 30.5 'hp 500 'shield 500
                                       'build-progress 1.0 'powered? #t 'busy? #f 'order-count 0)
                                 (hash 'id 8004 'type 'cybernetics-core 'x 36.5 'y 34.5 'hp 550 'shield 550
                                       'build-progress 1.0 'powered? #t 'busy? #f 'order-count 0))
           'enemy-units '()
           'enemy-buildings (list (hash 'id 9910 'type 'barracks 'x 92.5 'y 92.5 'hp 1000 'build-progress 1.0)))))
  (define acts-fwd-proxy (hash-ref res-fwd-proxy 'actions '()))
  (define tel-fwd-proxy (live-bot-runtime-last-telemetry rt-fwd-proxy))
  (assert-true! (<= (hash-ref tel-fwd-proxy 'last-seen-main-frame 0) 0)
                "Forward mid-map proxy Barracks must NOT spoof last-seen-main-frame")
  (assert-true! (not (ormap (lambda (a) (and (pair? a) (memq (car a) '(pull-workers-attack clear-expansion-block))))
                            acts-fwd-proxy))
                "Forward proxy (> 34 tiles away) must NEVER pull workers across the map")
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'shield-battery)))
                       acts-fwd-proxy)
                "Protoss with ready CyberCore must drop defensive ShieldBattery upon detecting forward proxy")
  (assert-true! (or (member '(train stalker) acts-fwd-proxy)
                    (member '(train adept) acts-fwd-proxy))
                "Protoss facing forward Terran proxy must train ranged Stalker/Adept ahead of uncharged Zealot")

  ;; 32.3 Anti-Trap & Anti-Wall-Off Building Layouts (`placement-preserves-base-exit-and-spawn?`)
  ;; Build a 32x32 grid where Main (4..17, 4..20) exits ONLY through a 3-tile choke (x=18..20, y=10..12) to exterior (21..29, 4..28)
  (define layout-path-bytes (make-bytes (* 32 32) 0))
  (define layout-pl-bytes (make-bytes (* 32 32) 0))
  (define (open-rect! x0 x1 y0 y1)
    (for* ([iy (in-range y0 (add1 y1))]
           [ix (in-range x0 (add1 x1))])
      (bytes-set! layout-path-bytes (+ ix (* iy 32)) 1)
      (bytes-set! layout-pl-bytes (+ ix (* iy 32)) 1)))
  (open-rect! 4 17 4 20)   ;; Main interior
  (open-rect! 18 20 10 12) ;; 3-tile-wide base exit corridor
  (open-rect! 21 29 4 28)  ;; Exterior natural/map space
  ;; Also carve a 3x3 cliff-surrounded pocket at (5..7, 23..25) with only a 1x1 doorway at (8, 24)
  (open-rect! 5 7 23 25)
  (open-rect! 8 8 24 24)
  (define layout-pgrid (sc2-image-grid 8 32 32 layout-path-bytes #f #f))
  (define layout-plgrid (sc2-image-grid 8 32 32 layout-pl-bytes #f #f))
  (define layout-gi
    (sc2-game-info "CorridorMap" "" '() '(32 32) '(2 2 30 30)
                   (list (sc2-point2d 26.5 24.5))
                   layout-pgrid #f layout-plgrid))
  (define layout-units
    (list (mk-w3-unit 3001 59 1 10.5 10.5 0 2.75)       ;; Nexus at (10.5, 10.5)
          (mk-w3-unit 3010 341 3 10.0 4.5 1500 1.0)))   ;; Mineral field at (10.0, 4.5)
  (assert-true! (not (placement-preserves-base-exit-and-spawn?
                      19.5 11.5 'gateway layout-units #:game-info layout-gi #:base-x 10.5 #:base-y 10.5))
                "Placing 3x3 Gateway in 3-wide base exit choke (19.5, 11.5) must be REJECTED (walls off base exit!)")
  (assert-true! (not (placement-preserves-base-exit-and-spawn?
                      6.5 24.5 'gateway layout-units #:game-info layout-gi #:base-x 10.5 #:base-y 10.5))
                "Placing 3x3 Gateway in cliff pocket with no 2x2 spawn exit (6.5, 24.5) must be REJECTED (traps spawned units!)")
  (assert-true! (not (placement-preserves-base-exit-and-spawn?
                      10.0 7.0 'pylon layout-units #:game-info layout-gi #:base-x 10.5 #:base-y 10.5))
                "Placing 2x2 Pylon directly inside worker mineral-mining lane (10.0, 7.0) must be REJECTED")
  (assert-true! (placement-preserves-base-exit-and-spawn?
                 14.5 16.5 'gateway layout-units #:game-info layout-gi #:base-x 10.5 #:base-y 10.5)
                "Placing 3x3 Gateway in open main interior (14.5, 16.5) with 2x2 exit and clear base corridor must be ACCEPTED")

  ;; 32.4 Counter-Compositions: PvZ Zergling Swarm (`Adept`+`Zealot` over `Stalker`) & Terran Priority `Medivac` + 2nd `Barracks-TechLab`
  (define rt-pvz-swarm (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define res-pvz-swarm
    (step-live-bot-runtime!
     rt-pvz-swarm
     (hash 'frame 3200 'minerals 260 'gas 75 'supply-used 34 'supply-cap 47 'supply-left 13
           'mineral-harvesters 26 'vespene-harvesters 3 'enemy-race 'Zerg
           'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5
           'ally-units (append (for/list ([i (in-range 26)])
                                 (hash 'id (+ 8300 i) 'type 'probe 'x 32.5 'y 32.5 'hp 20 'shield 20))
                               (for/list ([s (in-range 3)])
                                 (hash 'id (+ 8400 s) 'type 'stalker 'x 54.0 'y 32.5 'hp 80 'shield 80)))
           'ally-buildings (list (hash 'id 8201 'type 'nexus 'x 32.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                 (hash 'id 8202 'type 'nexus 'x 58.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                 (hash 'id 8203 'type 'pylon 'x 36.0 'y 35.0 'hp 200 'shield 200 'build-progress 1.0)
                                 (hash 'id 8204 'type 'cybernetics-core 'x 36.5 'y 38.5 'hp 550 'shield 550
                                       'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                 (hash 'id 8205 'type 'gateway 'x 36.5 'y 32.5 'hp 500 'shield 500
                                       'build-progress 1.0 'powered? #t 'busy? #f 'order-count 0)
                                 (hash 'id 8206 'type 'gateway 'x 40.5 'y 32.5 'hp 500 'shield 500
                                       'build-progress 1.0 'powered? #t 'busy? #f 'order-count 0))
           'enemy-units (for/list ([z (in-range 10)])
                          (hash 'id (+ 9800 z) 'type 'zergling 'x (+ 68.0 (* 0.5 z)) 'y 32.5 'hp 35))
           'enemy-buildings '())))
  (define acts-pvz-swarm (hash-ref res-pvz-swarm 'actions '()))
  (assert-true! (or (member '(train adept) acts-pvz-swarm)
                    (member '(train zealot) acts-pvz-swarm))
                "PvZ facing >= 6 Zerglings must train Light-slaying Adepts and/or Zealots (#5122350 fix)")
  (assert-true! (not (member '(train stalker) acts-pvz-swarm))
                "PvZ facing pure Zergling flood with 3 Stalkers already out must cap Stalkers in favor of Adepts/Zealots")

  (define rt-tvp-med (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define res-tvp-med
    (step-live-bot-runtime!
     rt-tvp-med
     (hash 'frame 5200 'minerals 320 'gas 130 'supply-used 54 'supply-cap 70 'supply-left 16
           'mineral-harvesters 34 'vespene-harvesters 6 'enemy-race 'Protoss
           'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5 'third-x 32.5 'third-y 62.5
           'ally-units (append (for/list ([i (in-range 36)])
                                 (hash 'id (+ 8500 i) 'type 'scv 'x 32.5 'y 32.5 'hp 45))
                               (for/list ([m (in-range 8)])
                                 (hash 'id (+ 8600 m) 'type 'marine 'x 54.0 'y 32.5 'hp 45)))
           'ally-buildings (list (hash 'id 8701 'type 'orbital-command 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                 (hash 'id 8702 'type 'orbital-command 'x 58.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                 (hash 'id 8703 'type 'barracks 'x 38.5 'y 32.5 'hp 1000 'build-progress 1.0
                                       'addon 'tech-lab 'busy? #t 'order-count 1)
                                 (hash 'id 8704 'type 'barracks-techlab 'x 41.0 'y 32.0 'hp 400 'build-progress 1.0
                                       'busy? #t 'order-count 1)
                                 (hash 'id 8705 'type 'barracks 'x 38.5 'y 36.5 'hp 1000 'build-progress 1.0
                                       'busy? #f 'order-count 0)
                                 (hash 'id 8706 'type 'barracks 'x 38.5 'y 40.5 'hp 1000 'build-progress 1.0
                                       'busy? #f 'order-count 0)
                                 (hash 'id 8707 'type 'factory 'x 44.5 'y 32.5 'hp 1250 'build-progress 1.0
                                       'addon 'tech-lab 'busy? #f 'order-count 0)
                                 (hash 'id 8708 'type 'factory-techlab 'x 47.0 'y 32.0 'hp 400 'build-progress 1.0)
                                 (hash 'id 8709 'type 'starport 'x 44.5 'y 36.5 'hp 1300 'build-progress 1.0
                                       'busy? #f 'order-count 0))
           'enemy-units (list (hash 'id 9850 'type 'stalker 'x 110.0 'y 110.0 'hp 80 'shield 80))
           'enemy-buildings '())))
  (define acts-tvp-med (hash-ref res-tvp-med 'actions '()))
  (assert-true! (member '(train medivac) acts-tvp-med)
                "Terran with >= 6 bio units, 0 Medivacs, and 130G must prioritize Medivac before Factory drains 125G on Siege Tank (#5122349 fix)")
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'barracks-techlab)))
                       acts-tvp-med)
                "Terran with 3 Barracks vs Protoss must build a 2nd Barracks-TechLab for Marauder scaling (#5122349 fix)"))

;; ============================================================================
;; 33. Wave 4: Scout Mineral-Walk Home on Worker Rush, P0 Survival Governor,
;;             Multi-Pylon Placement Perf, Moving-Templar Archon & Macro Fixes
;; ============================================================================
(run-suite "33. Scout Mineral-Walk Home on Worker Rush, P0 Survival Governor, Placement Perf & Archon/Macro Fixes"
  (define (mk-w4-unit tag utype alliance x y
                      #:hp [hp 100.0] #:shield [sh 0.0] #:energy [en 0.0]
                      #:min-c [min-c 0] #:radius [radius 0.5] #:orders [orders '()])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 2)
              (sc2-point3d x y 10.0) 0.0 radius 1.0 0 #f #t #f
              hp hp sh sh en (if (> en 0.0) 200.0 0.0) min-c 0
              #f #f #f #t #f orders 0 '() 0 16 0.0 0 0 0 0))

  ;; 33.1 Scout worker encountering an early worker rush MUST immediately mineral-walk home (zero engagement!)
  (define rt-scout-rush (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define base-probes-14
    (for/list ([i (in-range 14)])
      (hash 'id (+ 9100 i) 'type 'probe 'x 31.0 'y 32.5 'hp 20 'shield 20)))
  (define res-sr-open
    (step-live-bot-runtime!
     rt-scout-rush
     (hash 'frame 320 'minerals 100 'gas 0 'supply-used 14 'supply-cap 15 'supply-left 1
           'mineral-harvesters 14 'vespene-harvesters 0
           'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5 'enemy-x 160.5 'enemy-y 160.5
           'ally-units base-probes-14
           'ally-buildings (list (hash 'id 9001 'type 'nexus 'x 32.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                 (hash 'id 9002 'type 'pylon 'x 36.0 'y 36.0 'hp 200 'shield 200 'build-progress 1.0))
           'enemy-units '())))
  (define sr-id (hash-ref (live-bot-runtime-last-telemetry rt-scout-rush) 'scout-worker-id #f))
  (assert-true! (exact-integer? sr-id) "Opening Protoss runtime must latch scout-worker-id")

  ;; Mid-map encounter at (85.0, 85.0) against 6 oncoming enemy rush Probes -> immediate mineral-walk home!
  (define probes-scout-midmap
    (for/list ([p (in-list base-probes-14)])
      (if (= (hash-ref p 'id) sr-id)
          (hash 'id sr-id 'type 'probe 'x 85.0 'y 85.0 'hp 20 'shield 20)
          p)))
  (define oncoming-6-probes
    (for/list ([i (in-range 6)])
      (hash 'id (+ 9900 i) 'type 'probe 'x (+ 88.0 (* 0.3 i)) 'y 85.0 'hp 20 'shield 20)))
  (define res-sr-contact
    (step-live-bot-runtime!
     rt-scout-rush
     (hash 'frame 520 'minerals 100 'gas 0 'supply-used 14 'supply-cap 23 'supply-left 9
           'mineral-harvesters 13 'vespene-harvesters 0
           'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5 'enemy-x 160.5 'enemy-y 160.5
           'ally-units probes-scout-midmap
           'ally-buildings (list (hash 'id 9001 'type 'nexus 'x 32.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                 (hash 'id 9002 'type 'pylon 'x 36.0 'y 36.0 'hp 200 'shield 200 'build-progress 1.0))
           'enemy-units oncoming-6-probes)))
  (define acts-sr-contact
    (append (hash-ref res-sr-contact 'actions '())
            (hash-ref res-sr-contact 'mirror-actions '())))
  (assert-true! (member (list 'mineral-walk sr-id 32.5 32.5) acts-sr-contact)
                "Scout worker encountering oncoming early worker rush must immediately emit (mineral-walk sw-id base-x base-y)")
  (assert-true! (not (ormap (lambda (a)
                              (and (pair? a)
                                   (or (and (memq (car a) '(worker-scout worker-harass mineral-harass attack attack-unit move))
                                            (or (equal? (second a) sr-id)
                                                (and (list? (second a)) (memv sr-id (second a)))))
                                       (and (eq? (car a) 'pull-workers-attack)
                                            (list? (second a))
                                            (memv sr-id (second a))))))
                            acts-sr-contact))
                "Retreating scout worker must NEVER emit scout, harass, move, or attack orders against the worker rush")

  ;; Even when oncoming rush leaves fog-of-war on the next step while scout is still returning at (55.0, 55.0),
  ;; aborted-rush? latch keeps scout mineral-walking home without turning back around!
  (define probes-scout-returning
    (for/list ([p (in-list base-probes-14)])
      (if (= (hash-ref p 'id) sr-id)
          (hash 'id sr-id 'type 'probe 'x 55.0 'y 55.0 'hp 20 'shield 20)
          p)))
  (define res-sr-latch
    (step-live-bot-runtime!
     rt-scout-rush
     (hash 'frame 580 'minerals 100 'gas 0 'supply-used 14 'supply-cap 23 'supply-left 9
           'mineral-harvesters 13 'vespene-harvesters 0
           'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5 'enemy-x 160.5 'enemy-y 160.5
           'ally-units probes-scout-returning
           'ally-buildings (list (hash 'id 9001 'type 'nexus 'x 32.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                 (hash 'id 9002 'type 'pylon 'x 36.0 'y 36.0 'hp 200 'shield 200 'build-progress 1.0))
           'enemy-units '())))
  (assert-true! (member (list 'mineral-walk sr-id 32.5 32.5) (hash-ref res-sr-latch 'actions '()))
                "Latched rush-aborted scout must keep mineral-walking home across fog-of-war until <= 8 tiles from main")

  ;; 3 chasing enemy workers within 5.5 tiles (below global 4-worker threshold) also trigger immediate mineral-walk home!
  (define rt-scout-3chase (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (void
   (step-live-bot-runtime!
    rt-scout-3chase
    (hash 'frame 320 'minerals 100 'gas 0 'supply-used 14 'supply-cap 15 'supply-left 1
          'mineral-harvesters 14 'vespene-harvesters 0
          'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5 'enemy-x 160.5 'enemy-y 160.5
          'ally-units base-probes-14
          'ally-buildings (list (hash 'id 9001 'type 'nexus 'x 32.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                (hash 'id 9002 'type 'pylon 'x 36.0 'y 36.0 'hp 200 'shield 200 'build-progress 1.0))
          'enemy-units '())))
  (define sc3-id (hash-ref (live-bot-runtime-last-telemetry rt-scout-3chase) 'scout-worker-id #f))
  (define res-sc3
    (step-live-bot-runtime!
     rt-scout-3chase
     (hash 'frame 480 'minerals 100 'gas 0 'supply-used 14 'supply-cap 23 'supply-left 9
           'mineral-harvesters 13 'vespene-harvesters 0
           'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5 'enemy-x 160.5 'enemy-y 160.5
           'ally-units (for/list ([p (in-list base-probes-14)])
                         (if (= (hash-ref p 'id) sc3-id)
                             (hash 'id sc3-id 'type 'probe 'x 120.0 'y 120.0 'hp 20 'shield 20)
                             p))
           'ally-buildings (list (hash 'id 9001 'type 'nexus 'x 32.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                 (hash 'id 9002 'type 'pylon 'x 36.0 'y 36.0 'hp 200 'shield 200 'build-progress 1.0))
           'enemy-units (list (hash 'id 9931 'type 'scv 'x 123.0 'y 120.0 'hp 45)
                              (hash 'id 9932 'type 'scv 'x 123.5 'y 120.5 'hp 45)
                              (hash 'id 9933 'type 'scv 'x 124.0 'y 119.5 'hp 45)))))
  (assert-true! (member (list 'mineral-walk sc3-id 32.5 32.5) (hash-ref res-sc3 'actions '()))
                "Scout surrounded/chased by >= 3 enemy workers outside enemy main must immediately mineral-walk home")

  ;; 33.2 Urgent survival `mineral-walk` wire priority (`P0`) preserved across coalescer & APM governor
  (define mw-obs
    (sc2-observation
     640
     (sc2-player-common 1 100 0 23 14 0 14 0 0 0 0)
     (list (mk-w4-unit 9001 59 1 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:radius 2.75)
           (mk-w4-unit 701 84 1 30.0 32.5 #:hp 8.0 #:shield 0.0 #:radius 0.375)
           (mk-w4-unit 702 84 1 30.4 32.5 #:hp 10.0 #:shield 0.0 #:radius 0.375)
           (mk-w4-unit 703 84 1 34.0 32.5 #:hp 20.0 #:shield 20.0 #:radius 0.375)
           (mk-w4-unit 550 341 3 26.5 32.5 #:min-c 1500 #:radius 1.0)
           (mk-w4-unit 551 341 3 26.5 35.5 #:min-c 1500 #:radius 1.0))
     '() '() (sc2-point3d 32.5 32.5 10.0) '() '() '() '() '() '()))
  (define mw-raw-cmds
    (translate-bot-actions->sc2-raw-commands
     '((mineral-walk 701 550 26.5 32.5)
       (mineral-walk 702 550 26.5 32.5)
       (harvest-mineral 703 551))
     mw-obs))
  (define mw-surv-cmd
    (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-target-unit-tag c) 550)))
           mw-raw-cmds))
  (define mw-rout-cmd
    (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-target-unit-tag c) 551)))
           mw-raw-cmds))
  (assert-true! (and mw-surv-cmd (urgent-survival-cmd? mw-surv-cmd) (= (wire-cmd-priority-tier mw-surv-cmd) 0))
                "Coalesced mineral-walk command must retain urgent-survival-cmd?=#t and Tier P0 (0)")
  (assert-true! (and mw-rout-cmd (not (urgent-survival-cmd? mw-rout-cmd)) (= (wire-cmd-priority-tier mw-rout-cmd) 3))
                "Routine harvest-mineral command must remain Tier P3 (3)")
  (define test-gov (make-wire-apm-governor))
  ;; Drain governor from 24.0 tokens down to P2 floor (4.0 tokens) at loop 640
  (void
   (govern-sc2-wire-actions!
    test-gov
    (for/list ([i (in-range 10)])
      (sc2-raw-unit-command 16 (sc2-point2d (+ 40.0 i) 40.0) 0 (list (+ 900 i)) #f))
    640))
  (define gov-out
    (govern-sc2-wire-actions! test-gov (list mw-rout-cmd mw-surv-cmd) 640))
  (assert-true! (ormap (lambda (c)
                         (and (sc2-raw-unit-command? c)
                              (= (sc2-raw-unit-command-target-unit-tag c) 550)
                              (equal? (sc2-raw-unit-command-unit-tags c) '(701 702))))
                       gov-out)
                "APM governor at 4.0 tokens must emit P0 survival mineral-walk command for '(701 702)")
  (assert-true! (not (ormap (lambda (c)
                              (and (sc2-raw-unit-command? c)
                                   (= (sc2-raw-unit-command-target-unit-tag c) 551)))
                            gov-out))
                "APM governor at 4.0 tokens (< 8.0 P3 floor) must throttle routine P3 harvest-mineral command")

  ;; 33.3 Multi-Pylon `find-verified-building-placement` performance (< 50 ms on 200x200 grid with 8 Pylons)
  (define g200-bytes (make-bytes (* 200 200) 1))
  (define g200-img (sc2-image-grid 8 200 200 g200-bytes #f #f))
  (define g200-info
    (sc2-game-info "PerfGrid200" "" '() '(200 200) '(8 8 192 192)
                   (list (sc2-point2d 160.5 160.5))
                   g200-img #f g200-img))
  (define eight-pylon-anchors
    (for/list ([i (in-range 8)])
      (cons (+ 34.0 (* 5.0 (modulo i 4)))
            (+ 34.0 (* 5.0 (quotient i 4))))))
  (define eight-pylon-units
    (cons (mk-w4-unit 8001 59 1 30.5 30.5 #:radius 2.75)
          (for/list ([ap (in-list eight-pylon-anchors)] [i (in-naturals)])
            (mk-w4-unit (+ 8010 i) 60 1 (car ap) (cdr ap) #:radius 1.0))))
  (define t0-pl (current-inexact-monotonic-milliseconds))
  (define gw-pt
    (find-verified-building-placement #f 883 34.0 34.0 eight-pylon-units
                                      #:anchor-points eight-pylon-anchors
                                      #:bldg-sym 'gateway
                                      #:game-info g200-info))
  (define dt-pl (- (current-inexact-monotonic-milliseconds) t0-pl))
  (assert-true! (sc2-point2d? gw-pt)
                "find-verified-building-placement must find a valid 3x3 Gateway placement across 8 Pylons")
  (assert-true! (< dt-pl 60.0)
                (format "8-Pylon 200x200 placement must finish in < 60 ms (took ~a ms; #5122389 590ms spike fix)" dt-pl))

  ;; 33.4 Moving-Templar `Archon` fusion & >= 3 Mutalisk Storm-reserve override (#5122388 fix)
  (define moving-spent-ht-1
    (mk-w4-unit 8201 75 1 60.0 60.0 #:hp 40.0 #:shield 40.0 #:energy 25.0
                #:orders (list (sc2-unit-order 23 #f 0 0.0))))
  (define moving-spent-ht-2
    (mk-w4-unit 8202 75 1 61.0 60.0 #:hp 40.0 #:shield 40.0 #:energy 30.0
                #:orders (list (sc2-unit-order 16 (sc2-point2d 65.0 60.0) 0 0.0))))
  (assert-eq! (sort (select-producer-tags-for-unit 'archon (list moving-spent-ht-1 moving-spent-ht-2)) <)
              '(8201 8202)
              "Moving/attacking spent High Templars (n-orders = 1) MUST be selected for Archon fusion (#5122388 fix)")
  (define moving-storm-ht-1
    (mk-w4-unit 8203 75 1 60.0 62.0 #:hp 40.0 #:shield 40.0 #:energy 90.0
                #:orders (list (sc2-unit-order 23 #f 0 0.0))))
  (define moving-storm-ht-2
    (mk-w4-unit 8204 75 1 61.0 62.0 #:hp 40.0 #:shield 40.0 #:energy 85.0
                #:orders (list (sc2-unit-order 23 #f 0 0.0))))
  (define three-enemy-mutas
    (for/list ([i (in-range 3)])
      (mk-w4-unit (+ 9800 i) 108 4 (+ 68.0 i) 62.0 #:hp 120.0)))
  (assert-eq! (sort (select-producer-tags-for-unit 'archon
                                                   (list moving-storm-ht-1 moving-storm-ht-2)
                                                   three-enemy-mutas)
                    <)
              '(8203 8204)
              "Facing >= 3 enemy Mutalisks, >= 75-energy High Templars must override Storm reserve and fuse into AA Archon")

  ;; 33.5 Protoss 2-base PvZ Sentry unblock (only 2 Stalkers < 4, 340M/220G), Phoenix-over-Oracle vs AA, & Zerg Pool >= 72% rush bank
  (define rt-p-sentry (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define res-p-sentry
    (step-live-bot-runtime!
     rt-p-sentry
     (hash 'frame 2400 'minerals 340 'gas 220 'supply-used 34 'supply-cap 55 'supply-left 21
           'mineral-harvesters 22 'vespene-harvesters 6 'enemy-race 'Zerg
           'researched-upgrades '(warp-gate-research charge blink)
           'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5
           'ally-units (append (for/list ([i (in-range 26)])
                                 (hash 'id (+ 8400 i) 'type 'probe 'x 32.5 'y 32.5 'hp 20 'shield 20))
                               (list (hash 'id 8450 'type 'stalker 'x 54.0 'y 32.5 'hp 80 'shield 80)
                                     (hash 'id 8451 'type 'stalker 'x 55.0 'y 32.5 'hp 80 'shield 80)))
           'ally-buildings (list (hash 'id 8301 'type 'nexus 'x 32.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                 (hash 'id 8305 'type 'nexus 'x 58.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                 (hash 'id 8302 'type 'pylon 'x 36.0 'y 35.0 'hp 200 'shield 200 'build-progress 1.0)
                                 (hash 'id 8306 'type 'pylon 'x 54.0 'y 35.0 'hp 200 'shield 200 'build-progress 1.0)
                                 (hash 'id 8309 'type 'pylon 'x 40.0 'y 35.0 'hp 200 'shield 200 'build-progress 1.0)
                                 (hash 'id 8310 'type 'pylon 'x 44.0 'y 35.0 'hp 200 'shield 200 'build-progress 1.0)
                                 (hash 'id 8307 'type 'assimilator 'x 28.5 'y 35.5 'hp 450 'shield 450 'build-progress 1.0)
                                 (hash 'id 8308 'type 'assimilator 'x 28.5 'y 29.5 'hp 450 'shield 450 'build-progress 1.0)
                                 (hash 'id 8303 'type 'gateway 'x 36.5 'y 32.5 'hp 500 'shield 500
                                       'build-progress 1.0 'powered? #t 'busy? #f 'order-count 0)
                                 (hash 'id 8320 'type 'gateway 'x 36.5 'y 36.5 'hp 500 'shield 500
                                       'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                 (hash 'id 8323 'type 'gateway 'x 36.5 'y 40.5 'hp 500 'shield 500
                                       'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                 (hash 'id 8304 'type 'cybernetics-core 'x 40.5 'y 32.5 'hp 550 'shield 550
                                       'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                 (hash 'id 8321 'type 'twilight-council 'x 40.5 'y 36.5 'hp 500 'shield 500
                                       'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                 (hash 'id 8322 'type 'robotics-facility 'x 44.5 'y 32.5 'hp 500 'shield 500
                                       'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1))
           'enemy-units '())))
  (assert-true! (member '(train sentry) (hash-ref res-p-sentry 'actions '()))
                "Protoss on 2 bases with 340M/220G and only 2 Stalkers (< 4) must train Sentry without deadlocking (#5122382/#5122388 fix)")

  (define rt-p-phx (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define res-p-phx
    (step-live-bot-runtime!
     rt-p-phx
     (hash 'frame 4800 'minerals 360 'gas 180 'supply-used 52 'supply-cap 70 'supply-left 18
           'mineral-harvesters 32 'vespene-harvesters 6 'enemy-race 'Zerg
           'researched-upgrades '(warp-gate-research)
           'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5
           'ally-units (append (for/list ([i (in-range 34)])
                                 (hash 'id (+ 8500 i) 'type 'probe 'x 32.5 'y 32.5 'hp 20 'shield 20))
                               (for/list ([s (in-range 4)])
                                 (hash 'id (+ 8550 s) 'type 'stalker 'x 54.0 'y 32.5 'hp 80 'shield 80)))
           'ally-buildings (list (hash 'id 8311 'type 'nexus 'x 32.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                 (hash 'id 8312 'type 'nexus 'x 58.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                 (hash 'id 8313 'type 'pylon 'x 36.0 'y 35.0 'hp 200 'shield 200 'build-progress 1.0)
                                 (hash 'id 8316 'type 'assimilator 'x 28.5 'y 35.5 'hp 450 'shield 450 'build-progress 1.0)
                                 (hash 'id 8317 'type 'assimilator 'x 28.5 'y 29.5 'hp 450 'shield 450 'build-progress 1.0)
                                 (hash 'id 8318 'type 'gateway 'x 36.5 'y 32.5 'hp 500 'shield 500
                                       'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                 (hash 'id 8314 'type 'cybernetics-core 'x 40.5 'y 32.5 'hp 550 'shield 550
                                       'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                 (hash 'id 8315 'type 'stargate 'x 40.5 'y 36.5 'hp 600 'shield 600
                                       'build-progress 1.0 'powered? #t 'busy? #f 'order-count 0))
           'enemy-units (for/list ([m (in-range 4)])
                          (hash 'id (+ 9820 m) 'type 'mutalisk 'x (+ 90.0 m) 'y 90.0 'hp 120)))))
  (define acts-p-phx (hash-ref res-p-phx 'actions '()))
  (assert-true! (and (member '(train phoenix) acts-p-phx)
                     (not (member '(train oracle) acts-p-phx)))
                "Protoss Stargate facing Mutalisks must train Phoenix ahead of VoidRay and NEVER train Oracle (#5122388 fix)")

  (define rt-z-poolbank (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define res-z-poolbank
    (step-live-bot-runtime!
     rt-z-poolbank
     (hash 'frame 920 'minerals 100 'gas 0 'supply-used 13 'supply-cap 14 'supply-left 1
           'mineral-harvesters 12 'vespene-harvesters 0 'enemy-race 'Protoss
           'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5
           'ally-units (append (for/list ([i (in-range 12)])
                                 (hash 'id (+ 8600 i) 'type 'drone 'x 30.0 'y 32.5 'hp 40))
                               (list (hash 'id 8650 'type 'overlord 'x 34.0 'y 34.0 'hp 200)
                                     (hash 'id 8660 'type 'larva 'x 33.0 'y 31.0 'hp 25)
                                     (hash 'id 8661 'type 'larva 'x 33.5 'y 31.0 'hp 25)))
           'ally-buildings (list (hash 'id 8690 'type 'hatchery 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                 (hash 'id 8691 'type 'spawning-pool 'x 36.5 'y 32.5 'hp 800 'build-progress 0.80))
           'enemy-units (for/list ([p (in-range 8)])
                          (hash 'id (+ 9860 p) 'type 'probe 'x (+ 43.0 (* 0.2 p)) 'y 32.5 'hp 20 'shield 20)))))
  (assert-true! (not (member '(train drone) (hash-ref res-z-poolbank 'actions '())))
                "Zerg under worker rush with SpawningPool >= 72% complete and < 200M must bank larvae/minerals for Zerglings (#5122384 fix)")

  ;; 33.6 28.0-tile natural-wall non-proxy & post-2:30 (frame > 3360) enemy 4th-base TownHall non-proxy
  (assert-true! (not (enemy-structure-is-proxy? 'forge 140.0 115.5 140.0 140.0 112.0 140.0 140.0 84.0))
                "Enemy natural-wall Forge at 24.5 tiles from enemy main (<= 28.0) must NOT be misclassified as proxy")
  (define post230-obs
    (sc2-observation
     4000
     (sc2-player-common 1 300 100 54 44 0 38 0 0 0 0)
     (list (mk-w4-unit 8801 59 1 32.5 32.5 #:radius 2.75)
           ;; Enemy main Nexus at (140, 140)
           (mk-w4-unit 9980 59 4 140.0 140.0 #:radius 2.75)
           ;; Distant 4th-base enemy Nexus (> 28 tiles from main/nat/3rd) at loop 4000 (> 3360) -> NOT a proxy!
           (mk-w4-unit 9981 59 4 80.0 140.0 #:radius 2.75)
           ;; Forward mid-map enemy Barracks (> 28 tiles from main/nat/3rd) -> IS a proxy!
           (mk-w4-unit 9982 21 4 88.0 88.0 #:radius 1.75))
     '() '() (sc2-point3d 32.5 32.5 10.0) '() '() '() '() '() '()))
  (define post230-h
    (sc2-observation->runtime-obs-hash post230-obs #:defer-expansions? #t))
  (define post230-ebldgs (hash-ref post230-h 'enemy-buildings '()))
  (define eb-nexus (findf (lambda (b) (= (hash-ref b 'id 0) 9981)) post230-ebldgs))
  (define eb-rax   (findf (lambda (b) (= (hash-ref b 'id 0) 9982)) post230-ebldgs))
  (assert-eq! (hash-ref eb-nexus 'is-proxy? 'missing) #f
              "Post-2:30 (loop > 3360) enemy 4th-base Nexus expansion must NOT be flagged as proxy (#5122382/#5122389 fix)")
  (assert-eq! (hash-ref eb-rax 'is-proxy? 'missing) #t
              "Forward mid-map enemy Barracks (> 28 tiles from enemy bases) must still be flagged as proxy"))

(run-suite
  "34. Wave 5 Fixes: Zerg Pool r=4.0 Pad Clearance, Worker-Rush Leash, Overlord Scout Cap, Colossus/Starport Escrow & Anti-BC"
  ;; 34.1 Loopback WS: Zerg SpawningPool on tight main creep (valid ONLY at Chebyshev dist 3.95..4.5 from Hatchery)
  ;; MUST reject r >= 4.5 (code 2) and fall back to tight-pad-clearance r=4.0 (code 1), emitting BUILD_SPAWNINGPOOL (1155)!
  (define-values (c34-in s34-out) (make-pipe))
  (define-values (s34-in c34-out) (make-pipe))
  (define ws34-tight (sc2-ws-conn "127.0.0.1" 0 "/sc2api" c34-in c34-out #f 1))
  (define srv34-thd
    (thread
     (lambda ()
       (let lp ()
         (define hdr2 (read-bytes 2 s34-in))
         (unless (eof-object? hdr2)
           (define b0 (bytes-ref hdr2 0))
           (define b1 (bytes-ref hdr2 1))
           (define opcode (bitwise-and b0 #x0F))
           (define masked? (not (zero? (bitwise-and b1 #x80))))
           (define len7 (bitwise-and b1 #x7F))
           (define plen
             (cond [(< len7 126) len7]
                   [(= len7 126) (integer-bytes->integer (read-bytes 2 s34-in) #f #t)]
                   [else (integer-bytes->integer (read-bytes 8 s34-in) #f #t)]))
           (define mkey (if masked? (read-bytes 4 s34-in) #f))
           (define raw (read-bytes plen s34-in))
           (define payload (if masked? (mask-ws-payload raw mkey) raw))
           (when (= opcode 2)
             (define req-f (decode-protobuf-message payload))
             (define req-id-p (assoc 97 req-f))
             (define id-b (if req-id-p (encode-uint32 97 (third req-id-p)) #""))
             (define q-p (assoc 14 req-f))
             (when q-p
               (define qf (decode-protobuf-message (third q-p)))
               (define p-items (filter (lambda (e) (= (first e) 3)) qf))
               (define res-b
                 (apply bytes-append
                        (for/list ([it (in-list p-items)])
                          (define bf (decode-protobuf-message (third it)))
                          (define pos-p (assoc 2 bf))
                          (define pf (if pos-p (decode-protobuf-message (third pos-p)) '()))
                          (define xp (assoc 1 pf))
                          (define yp (assoc 2 pf))
                          (define tx (if xp (floating-point-bytes->real (third xp) #f) 0.0))
                          (define ty (if yp (floating-point-bytes->real (third yp) #f) 0.0))
                          (define cheb (max (abs (- tx 141.5)) (abs (- ty 38.5))))
                          (define code (if (and (>= cheb 3.95) (< cheb 4.5)) 1 2))
                          (encode-submessage-field 3 (encode-int32 1 code)))))
               (define resp (bytes-append (encode-submessage-field 14 res-b) id-b (encode-int32 99 3)))
               (define rlen (bytes-length resp))
               (define rhdr
                 (cond [(< rlen 126) (bytes #x82 rlen)]
                       [(<= rlen 65535) (bytes-append (bytes #x82 126) (integer->integer-bytes rlen 2 #f #t))]
                       [else (bytes-append (bytes #x82 127) (integer->integer-bytes rlen 8 #f #t))]))
               (write-bytes rhdr s34-out)
               (write-bytes resp s34-out)
               (flush-output s34-out))
             (lp)))))))
  (define leases34 (make-hasheqv))
  (define obs34-z
    (sc2-observation
     1200
     (sc2-player-common 1 300 0 22 16 0 16 0 0 0 0)
     (list (sc2-unit 1 1 9011 86 1 (sc2-point3d 141.5 38.5 10.0) 0.0 2.75 1.0 0 #f #f #f
                     1500.0 1500.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #t '() 0 '() 0 16 0.0 0 0 0 0)
           (sc2-unit 1 1 9012 104 1 (sc2-point3d 139.5 38.5 10.0) 0.0 0.375 1.0 0 #f #f #f
                     40.0 40.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #t '() 0 '() 0 0 0.0 0 0 0 0))
     '() '() #f '() '() '() '() '() '()))
  (define cmds34-pool
    (translate-bot-actions->sc2-raw-commands
     '((build spawning-pool 137.5 38.5))
     obs34-z
     #:ws-conn ws34-tight
     #:role-leases leases34))
  (close-output-port c34-out)
  (close-input-port c34-in)
  (thread-wait srv34-thd)
  (define pool-cmds34
    (filter (lambda (c)
              (and (sc2-raw-unit-command? c)
                   (= (sc2-raw-unit-command-ability-id c) 1155)))
            cmds34-pool))
  (assert-true! (and (= (length pool-cmds34) 1)
                     (let ([pt (sc2-raw-unit-command-target-pos (first pool-cmds34))])
                       (and (sc2-point2d? pt)
                            (>= (max (abs (- (sc2-point2d-x pt) 141.5))
                                     (abs (- (sc2-point2d-y pt) 38.5)))
                                3.95)
                            (< (max (abs (- (sc2-point2d-x pt) 141.5))
                                    (abs (- (sc2-point2d-y pt) 38.5)))
                               4.5))))
                "Tight Hatchery-adjacent Zerg SpawningPool (Chebyshev 3.95..4.5) must recover from r>=4.5 rejection and emit BUILD_SPAWNINGPOOL (1155)")

  ;; 34.2 Worker-rush over-pull collapse (#5122399):
  ;; (a) 12 Probes hovering at 8.8 tiles (> 8.5 leash, > 5.5 from mineral line, no damaged building) must NOT trigger worker pull!
  (define rt-p-hover (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define res-p-hover
    (step-live-bot-runtime!
     rt-p-hover
     (hash 'frame 1250 'minerals 100 'gas 0 'supply-used 16 'supply-cap 23 'supply-left 7
           'mineral-harvesters 16 'vespene-harvesters 0
           'base-x 32.5 'base-y 32.5 'natural-x 60.5 'natural-y 32.5
           'mineral-patches (list (hash 'id 550 'x 26.5 'y 32.5))
           'ally-units (for/list ([i (in-range 16)])
                         (hash 'id (+ 7400 i) 'type 'probe 'x (+ 27.5 (* 0.3 i)) 'y 32.5 'hp 20 'shield 20))
           'ally-buildings (list (hash 'id 7011 'type 'nexus 'x 32.5 'y 32.5
                                       'hp 1000 'max-hp 1000 'shield 1000 'max-shield 1000
                                       'build-progress 1.0 'powered? #f))
           'enemy-units (for/list ([i (in-range 12)])
                          (hash 'id (+ 9750 i) 'type 'probe 'x 41.3 'y (+ 32.0 (* 0.1 i)) 'hp 20 'shield 20)))))
  (assert-true! (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack)))
                            (hash-ref res-p-hover 'actions '())))
                "12 Probes hovering at 8.8 tiles (> 8.5 leash, zero mineral breach/building damage) must NOT pull miners")
  ;; (b) With 16 healthy Probes on mineral-line breach, keep >= 3 miners harvesting!
  (define rt-p-keep3 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define res-p-keep3
    (step-live-bot-runtime!
     rt-p-keep3
     (hash 'frame 1950 'minerals 100 'gas 0 'supply-used 16 'supply-cap 23 'supply-left 7
           'mineral-harvesters 16 'vespene-harvesters 0
           'base-x 32.5 'base-y 32.5 'natural-x 60.5 'natural-y 32.5
           'mineral-patches (list (hash 'id 550 'x 26.5 'y 32.5))
           'ally-units (for/list ([i (in-range 16)])
                         (hash 'id (+ 7450 i) 'type 'probe 'x (+ 27.0 (* 0.3 i)) 'y 32.5 'hp 20 'shield 20))
           'ally-buildings (list (hash 'id 7012 'type 'nexus 'x 32.5 'y 32.5
                                       'hp 1000 'max-hp 1000 'shield 1000 'max-shield 1000
                                       'build-progress 1.0 'powered? #f))
           'enemy-units (for/list ([i (in-range 12)])
                          (hash 'id (+ 9770 i) 'type 'probe 'x (+ 29.0 (* 0.2 i)) 'y 33.0 'hp 20 'shield 20)))))
  (define pulls-keep3
    (filter (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack)))
            (append (hash-ref res-p-keep3 'actions '())
                    (hash-ref res-p-keep3 'mirror-actions '()))))
  (define pulled-keep3-ids (remove-duplicates (append* (map second pulls-keep3))))
  (assert-true! (and (>= (length pulled-keep3-ids) 11)
                     (<= (length pulled-keep3-ids) 13))
                (format "16-Probe mineral breach must pull defenders while keeping >= 3 miners home (pulled ~a of 16)"
                        (length pulled-keep3-ids)))

  ;; 34.3 Zerg opening-overlord-scout cap (< 2800f, <= 2 Overlord IDs) & permanent abort + retreat on AA/loss (#5122396)
  (define rt-ov (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (define (mk-ov-obs frm #:ovies ovs #:enemies [ens '()])
    (hash 'frame frm 'minerals 200 'gas 0 'supply-used 14 'supply-cap 22 'supply-left 8
          'mineral-harvesters 14 'vespene-harvesters 0 'enemy-race 'Terran
          'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5
          'enemy-x 140.0 'enemy-y 140.0
          'ally-units (append (for/list ([i (in-range 14)])
                                (hash 'id (+ 1100 i) 'type 'drone 'x 30.0 'y 32.5 'hp 40))
                              ovs)
          'ally-buildings (list (hash 'id 1001 'type 'hatchery 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0))
          'enemy-units ens))
  ;; Tick 1 & 2 (frames 400 & 900) with 3 Overlords available: can send <= 2 unique IDs
  (void (step-live-bot-runtime! rt-ov
          (mk-ov-obs 400 #:ovies (list (hash 'id 2001 'type 'overlord 'x 34.0 'y 34.0 'hp 200 'max-hp 200)
                                       (hash 'id 2002 'type 'overlord 'x 35.0 'y 34.0 'hp 200 'max-hp 200)
                                       (hash 'id 2003 'type 'overlord 'x 36.0 'y 34.0 'hp 200 'max-hp 200)))))
  (void (step-live-bot-runtime! rt-ov
          (mk-ov-obs 900 #:ovies (list (hash 'id 2001 'type 'overlord 'x 60.0 'y 60.0 'hp 200 'max-hp 200)
                                       (hash 'id 2002 'type 'overlord 'x 35.0 'y 34.0 'hp 200 'max-hp 200)
                                       (hash 'id 2003 'type 'overlord 'x 36.0 'y 34.0 'hp 200 'max-hp 200)))))
  (define ov-ids-before (hash-ref (rt-scout-state rt-ov) 'opening-overlord-ids '()))
  (assert-true! (<= (length ov-ids-before) 2)
                (format "opening-overlord-scout must cap dispatches to <= 2 unique Overlord IDs (got ~a)" ov-ids-before))
  ;; Tick 3 (frame 1400): enemy Marine spots far Overlord -> must abort opening-overlord-scout & retreat Overlord #2001 (> 26 tiles) home via kite!
  (define res-ov-retreat
    (step-live-bot-runtime!
     rt-ov
     (mk-ov-obs 1400
                #:ovies (list (hash 'id 2001 'type 'overlord 'x 110.0 'y 110.0 'hp 170 'max-hp 200)
                              (hash 'id 2002 'type 'overlord 'x 35.0 'y 34.0 'hp 200 'max-hp 200))
                #:enemies (list (hash 'id 9901 'type 'marine 'x 116.0 'y 116.0 'hp 45)))))
  (define ov-acts3
    (append (hash-ref res-ov-retreat 'actions '())
            (hash-ref res-ov-retreat 'mirror-actions '())))
  (assert-true! (hash-ref (rt-scout-state rt-ov) 'opening-overlord-aborted? #f)
                "Enemy AA / Overlord loss/damage must permanently set opening-overlord-aborted? #t")
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'kite) (equal? (second a) 2001))) ov-acts3)
                "Aborted far Overlord #2001 (> 26 tiles from home) must retreat toward base via 'kite")
  ;; Tick 4 (frame 2900 >= 2800): even on fresh runtime, frame >= 2800 must not emit forward scout moves
  (define rt-ov-late (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
  (void (step-live-bot-runtime!
         rt-ov-late
         (mk-ov-obs 2900
                    #:ovies (list (hash 'id 2011 'type 'overlord 'x 34.0 'y 34.0 'hp 200 'max-hp 200)))))
  (assert-eq! (length (hash-ref (rt-scout-state rt-ov-late) 'opening-overlord-ids '()))
              0
              "Zerg opening-overlord-scout must NEVER dispatch new Overlords after frame 2800")

  ;; 34.4 Protoss Colossus escrow (#5122398), 2-base 700M Gateway + 2nd Robo scaling, & earlier vs-Terran RoboticsBay
  ;; (a) 260M/160G with ready RoboticsBay & open Robo slot holds over Immortal/Stalker/Twilight; trains Colossus at 310M/210G
  (define (mk-p-col-obs frm mins gas-amt #:twilight? [tw? #f])
    (hash 'frame frm 'minerals mins 'gas gas-amt 'supply-used 64 'supply-cap 86 'supply-left 22
          'mineral-harvesters 36 'vespene-harvesters 12 'enemy-race 'Terran
          'researched-upgrades '(warp-gate-research)
          'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5
          'ally-units (append (for/list ([i (in-range 40)])
                                (hash 'id (+ 8700 i) 'type 'probe 'x 32.5 'y 32.5 'hp 20 'shield 20))
                              (for/list ([s (in-range 6)])
                                (hash 'id (+ 8760 s) 'type 'stalker 'x 54.0 'y 32.5 'hp 80 'shield 80))
                              (list (hash 'id 8780 'type 'observer 'x 55.0 'y 32.5 'hp 40 'shield 20)))
          'ally-buildings (append
                           (list (hash 'id 8701 'type 'nexus 'x 32.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                 (hash 'id 8702 'type 'nexus 'x 58.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                 (hash 'id 8703 'type 'pylon 'x 36.0 'y 35.0 'hp 200 'shield 200 'build-progress 1.0)
                                 (hash 'id 8704 'type 'assimilator 'x 28.5 'y 35.5 'hp 450 'shield 450 'build-progress 1.0)
                                 (hash 'id 8705 'type 'assimilator 'x 28.5 'y 29.5 'hp 450 'shield 450 'build-progress 1.0)
                                 (hash 'id 8706 'type 'gateway 'x 36.5 'y 32.5 'hp 500 'shield 500 'build-progress 1.0 'powered? #t 'busy? #f 'order-count 0)
                                 (hash 'id 8707 'type 'gateway 'x 36.5 'y 36.5 'hp 500 'shield 500 'build-progress 1.0 'powered? #t 'busy? #f 'order-count 0)
                                 (hash 'id 8708 'type 'gateway 'x 36.5 'y 40.5 'hp 500 'shield 500 'build-progress 1.0 'powered? #t 'busy? #f 'order-count 0)
                                 (hash 'id 8709 'type 'gateway 'x 36.5 'y 44.5 'hp 500 'shield 500 'build-progress 1.0 'powered? #t 'busy? #f 'order-count 0)
                                 (hash 'id 8710 'type 'cybernetics-core 'x 40.5 'y 32.5 'hp 550 'shield 550 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                 (hash 'id 8711 'type 'robotics-facility 'x 44.5 'y 32.5 'hp 500 'shield 500 'build-progress 1.0 'powered? #t 'busy? #f 'order-count 0)
                                 (hash 'id 8712 'type 'robotics-bay 'x 48.5 'y 32.5 'hp 500 'shield 500 'build-progress 1.0 'powered? #t 'busy? #f 'order-count 0))
                           (if tw? (list (hash 'id 8713 'type 'twilight-council 'x 40.5 'y 36.5 'hp 500 'shield 500 'build-progress 1.0 'powered? #t 'busy? #f 'order-count 0)) '()))
          'enemy-units '()))
  (define rt-p-col (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define res-p-hold (step-live-bot-runtime! rt-p-col (mk-p-col-obs 6200 260 160)))
  (define acts-p-hold (hash-ref res-p-hold 'actions '()))
  (assert-true! (and (not (member '(train immortal) acts-p-hold))
                     (not (member '(train stalker) acts-p-hold))
                     (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'twilight-council))) acts-p-hold)))
                "Protoss with RoboticsBay ready at 260M/160G must hold 300M/200G for Colossus (#5122398 fix)")
  (define res-p-col (step-live-bot-runtime! rt-p-col (mk-p-col-obs 6216 310 210)))
  (assert-true! (member '(train colossus) (hash-ref res-p-col 'actions '()))
                "Protoss reaching 310M/210G with open RoboticsFacility + RoboticsBay must train Colossus")
  ;; (b) 2-base Protoss at 750M/250G (with 3rd Nexus already warping in) & eff-phase-supply 76 builds extra Gateway AND 2nd RoboticsFacility
  (define rt-p-float (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define (mk-p-float-obs frm mins gas-amt)
    (hash 'frame frm 'minerals mins 'gas gas-amt 'supply-used 76 'supply-cap 102 'supply-left 26
          'mineral-harvesters 36 'vespene-harvesters 12 'enemy-race 'Terran
          'researched-upgrades '(warp-gate-research extended-thermal-lance)
          'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5
          'ally-units (append (for/list ([i (in-range 40)])
                                (hash 'id (+ 8800 i) 'type 'probe 'x 32.5 'y 32.5 'hp 20 'shield 20))
                              (for/list ([s (in-range 8)])
                                (hash 'id (+ 8860 s) 'type 'stalker 'x 54.0 'y 32.5 'hp 80 'shield 80))
                              (list (hash 'id 8880 'type 'observer 'x 55.0 'y 32.5 'hp 40 'shield 20)))
          'ally-buildings (list (hash 'id 8801 'type 'nexus 'x 32.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                (hash 'id 8802 'type 'nexus 'x 58.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                (hash 'id 8803 'type 'pylon 'x 36.0 'y 35.0 'hp 200 'shield 200 'build-progress 1.0)
                                (hash 'id 8804 'type 'assimilator 'x 28.5 'y 35.5 'hp 450 'shield 450 'build-progress 1.0)
                                (hash 'id 8805 'type 'assimilator 'x 28.5 'y 29.5 'hp 450 'shield 450 'build-progress 1.0)
                                (hash 'id 8806 'type 'gateway 'x 36.5 'y 32.5 'hp 500 'shield 500 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                (hash 'id 8807 'type 'gateway 'x 36.5 'y 36.5 'hp 500 'shield 500 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                (hash 'id 8808 'type 'gateway 'x 36.5 'y 40.5 'hp 500 'shield 500 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                (hash 'id 8809 'type 'cybernetics-core 'x 40.5 'y 32.5 'hp 550 'shield 550 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                (hash 'id 8810 'type 'robotics-facility 'x 44.5 'y 32.5 'hp 500 'shield 500 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                (hash 'id 8811 'type 'twilight-council 'x 40.5 'y 36.5 'hp 500 'shield 500 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 0))
          'enemy-units '()))
  (void (step-live-bot-runtime! rt-p-float (mk-p-float-obs 6580 420 50)))
  (define res-p-float
    (step-live-bot-runtime! rt-p-float (mk-p-float-obs 6600 750 250)))
  (define acts-p-float (hash-ref res-p-float 'actions '()))
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'gateway))) acts-p-float)
                "2-base Protoss floating 750M with 3 Gateways must scale extra Gateways toward 8")
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'robotics-facility))) acts-p-float)
                "Protoss floating 750M/250G at >= 72 supply must build 2nd RoboticsFacility")
  ;; (c) Earlier vs-Terran RoboticsBay at 54 supply & 1 Immortal
  (define rt-p-bay (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define res-p-bay
    (step-live-bot-runtime!
     rt-p-bay
     (hash 'frame 5000 'minerals 300 'gas 200 'supply-used 54 'supply-cap 78 'supply-left 24
           'mineral-harvesters 32 'vespene-harvesters 10 'enemy-race 'Terran
           'researched-upgrades '(warp-gate-research)
           'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5
           'ally-units (append (for/list ([i (in-range 36)])
                                 (hash 'id (+ 8900 i) 'type 'probe 'x 32.5 'y 32.5 'hp 20 'shield 20))
                               (for/list ([s (in-range 4)])
                                 (hash 'id (+ 8950 s) 'type 'stalker 'x 54.0 'y 32.5 'hp 80 'shield 80))
                               (list (hash 'id 8970 'type 'immortal 'x 54.5 'y 32.5 'hp 200 'shield 100)
                                     (hash 'id 8971 'type 'observer 'x 55.0 'y 32.5 'hp 40 'shield 20)))
           'ally-buildings (list (hash 'id 8901 'type 'nexus 'x 32.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                 (hash 'id 8902 'type 'nexus 'x 58.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                 (hash 'id 8903 'type 'pylon 'x 36.0 'y 35.0 'hp 200 'shield 200 'build-progress 1.0)
                                 (hash 'id 8904 'type 'assimilator 'x 28.5 'y 35.5 'hp 450 'shield 450 'build-progress 1.0)
                                 (hash 'id 8905 'type 'assimilator 'x 28.5 'y 29.5 'hp 450 'shield 450 'build-progress 1.0)
                                 (hash 'id 8906 'type 'gateway 'x 36.5 'y 32.5 'hp 500 'shield 500 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                 (hash 'id 8907 'type 'gateway 'x 36.5 'y 36.5 'hp 500 'shield 500 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                 (hash 'id 8908 'type 'gateway 'x 36.5 'y 40.5 'hp 500 'shield 500 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                 (hash 'id 8909 'type 'cybernetics-core 'x 40.5 'y 32.5 'hp 550 'shield 550 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                 (hash 'id 8910 'type 'robotics-facility 'x 44.5 'y 32.5 'hp 500 'shield 500 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1))
           'enemy-units '())))
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'robotics-bay)))
                       (hash-ref res-p-bay 'actions '()))
                "Protoss vs Terran at 54 supply with 1 Immortal must start RoboticsBay earlier")

  ;; 34.5 Terran Starport escrow, vs-air Viking/Medivac co-production, & SC2-MAX-ACTIVE-BASES auto-expand cap
  ;; (a) Ready Factory at 160M/80G holds for Starport over FactoryTechLab / BarracksReactor / SiegeTank / CombatShield / 3rd CC
  (define rt-t-escrow (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define res-t-escrow
    (step-live-bot-runtime!
     rt-t-escrow
     (hash 'frame 4800 'minerals 160 'gas 80 'supply-used 46 'supply-cap 62 'supply-left 16
           'mineral-harvesters 30 'vespene-harvesters 6 'enemy-race 'Terran
           'researched-upgrades '(stimpack)
           'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5
           'ally-units (append (for/list ([i (in-range 34)])
                                 (hash 'id (+ 14100 i) 'type 'scv 'x 32.5 'y 32.5 'hp 45))
                               (for/list ([m (in-range 6)])
                                 (hash 'id (+ 14200 m) 'type 'marine 'x 54.0 'y 32.5 'hp 45)))
           'ally-buildings (list (hash 'id 14301 'type 'orbital-command 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                 (hash 'id 14302 'type 'orbital-command 'x 58.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                 (hash 'id 14303 'type 'supply-depot 'x 36.0 'y 36.0 'hp 400 'build-progress 1.0)
                                 (hash 'id 14310 'type 'refinery 'x 29.5 'y 35.5 'hp 500 'build-progress 1.0 'vespene-contents 1200)
                                 (hash 'id 14311 'type 'refinery 'x 29.5 'y 29.5 'hp 500 'build-progress 1.0 'vespene-contents 1200)
                                 (hash 'id 14304 'type 'barracks 'x 38.5 'y 32.5 'hp 1000 'build-progress 1.0
                                       'addon 'techlab 'busy? #t 'order-count 1)
                                 (hash 'id 14305 'type 'barracks-techlab 'x 41.0 'y 32.0 'hp 400 'build-progress 1.0
                                       'busy? #f 'order-count 0)
                                 (hash 'id 14306 'type 'barracks 'x 38.5 'y 36.5 'hp 1000 'build-progress 1.0
                                       'busy? #f 'order-count 0)
                                 (hash 'id 14308 'type 'factory 'x 44.5 'y 32.5 'hp 1250 'build-progress 1.0
                                       'busy? #f 'order-count 0))
           'enemy-units '())))
  (define acts-t-escrow (hash-ref res-t-escrow 'actions '()))
  (assert-true! (and (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'factory-techlab))) acts-t-escrow))
                     (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'barracks-reactor))) acts-t-escrow))
                     (not (equal? (findf (lambda (a) (equal? a '(research combat-shield))) acts-t-escrow)
                                  '(research combat-shield)))
                     (not (member '(train siege-tank) acts-t-escrow))
                     (not (member '(train widow-mine) acts-t-escrow))
                     (not (ormap (lambda (a) (eq? (car a) 'expand)) acts-t-escrow)))
                "Terran with ready Factory & 160M/80G must hold 150M/100G for 1st Starport (no FactoryTechLab/Reactor/CombatShield/Tank/3rd CC)")
  ;; (b) Vs air with ready Starport: 0 Vikings trains Viking first; 2 Vikings + 0 Medivacs co-produces Medivac; 2 Vikings + 2 Medivacs continues Vikings!
  (define (mk-t-aa-obs vik-cnt med-cnt)
    (hash 'frame 6200 'minerals 300 'gas 200 'supply-used 60 'supply-cap 90 'supply-left 30
          'mineral-harvesters 34 'vespene-harvesters 6 'enemy-race 'Terran
          'researched-upgrades '(stimpack combat-shield)
          'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5
          'ally-units (append (for/list ([i (in-range 36)])
                                (hash 'id (+ 15100 i) 'type 'scv 'x 32.5 'y 32.5 'hp 45))
                              (for/list ([m (in-range 8)])
                                (hash 'id (+ 15200 m) 'type 'marine 'x 54.0 'y 32.5 'hp 45))
                              (for/list ([v (in-range vik-cnt)])
                                (hash 'id (+ 15300 v) 'type 'viking-fighter 'x 54.0 'y 34.0 'hp 135))
                              (for/list ([md (in-range med-cnt)])
                                (hash 'id (+ 15400 md) 'type 'medivac 'x 53.0 'y 32.5 'hp 150)))
          'ally-buildings (list (hash 'id 15001 'type 'orbital-command 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                (hash 'id 15002 'type 'orbital-command 'x 58.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                (hash 'id 15003 'type 'barracks 'x 38.5 'y 32.5 'hp 1000 'build-progress 1.0 'busy? #t 'order-count 1)
                                (hash 'id 15004 'type 'factory 'x 44.5 'y 32.5 'hp 1250 'build-progress 1.0 'busy? #t 'order-count 1)
                                (hash 'id 15005 'type 'starport 'x 44.5 'y 36.5 'hp 1300 'build-progress 1.0 'busy? #f 'order-count 0))
          'enemy-buildings (list (hash 'id 15999 'type 'command-center 'x 130.0 'y 130.0 'hp 1500 'build-progress 1.0))
          'enemy-units (list (hash 'id 15901 'type 'battlecruiser 'x 110.0 'y 110.0 'hp 550)
                             (hash 'id 15902 'type 'viking-fighter 'x 112.0 'y 110.0 'hp 135))))
  (define acts-t-aa0 (hash-ref (step-live-bot-runtime! (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran) (mk-t-aa-obs 0 0)) 'actions '()))
  (define acts-t-aa2 (hash-ref (step-live-bot-runtime! (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran) (mk-t-aa-obs 2 0)) 'actions '()))
  (define acts-t-aa22 (hash-ref (step-live-bot-runtime! (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran) (mk-t-aa-obs 2 2)) 'actions '()))
  (assert-true! (and (member '(train viking) acts-t-aa0)
                     (not (member '(train medivac) acts-t-aa0)))
                "Terran vs air with 0 Vikings must train Viking BEFORE Medivac")
  (assert-true! (member '(train medivac) acts-t-aa2)
                "Terran vs air once >= 2 Vikings exist must co-produce 1-2 Medivacs for bio sustain")
  (assert-true! (member '(train viking) acts-t-aa22)
                "Terran vs air once >= 2 Medivacs exist must continue building Vikings up to 8-10")
  ;; (c) auto-expand must stop once active-bases reaches SC2-MAX-ACTIVE-BASES (6)
  (define rt-max-bases (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define res-max-bases
    (step-live-bot-runtime!
     rt-max-bases
     (hash 'frame 14000 'minerals 900 'gas 400 'supply-used 140 'supply-cap 180 'supply-left 40
           'mineral-harvesters 66 'vespene-harvesters 12 'enemy-race 'Terran 'mined-out #t 'depleting-bases 1
           'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5
           'expansion-candidates (list '(84.5 . 32.5) '(32.5 . 62.5) '(84.5 . 62.5) '(110.5 . 32.5) '(110.5 . 62.5))
           'ally-units (for/list ([i (in-range 66)])
                         (hash 'id (+ 16100 i) 'type 'scv 'x 32.5 'y 32.5 'hp 45))
           'ally-buildings (list (hash 'id 16001 'type 'orbital-command 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                 (hash 'id 16002 'type 'orbital-command 'x 58.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                 (hash 'id 16003 'type 'orbital-command 'x 84.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                 (hash 'id 16004 'type 'orbital-command 'x 32.5 'y 62.5 'hp 1500 'build-progress 1.0)
                                 (hash 'id 16005 'type 'orbital-command 'x 58.5 'y 62.5 'hp 1500 'build-progress 1.0)
                                 (hash 'id 16006 'type 'orbital-command 'x 84.5 'y 62.5 'hp 1500 'build-progress 1.0)
                                 (hash 'id 16010 'type 'starport 'x 38.5 'y 36.5 'hp 1300 'build-progress 1.0 'busy? #t 'order-count 1)
                                 (hash 'id 16011 'type 'factory 'x 38.5 'y 32.5 'hp 1250 'build-progress 1.0 'busy? #t 'order-count 1)
                                 (hash 'id 16012 'type 'barracks 'x 38.5 'y 28.5 'hp 1000 'build-progress 1.0 'busy? #t 'order-count 1))
           'enemy-units '())))
  (assert-true! (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'expand)))
                            (hash-ref res-max-bases 'actions '())))
                "auto-expand must never expand above SC2-MAX-ACTIVE-BASES (6)")

  ;; 34.6 Zerg Spire/Corruptor anti-BC unblock on >= 3 bases:
  ;; At 120M/150G vs Battlecruiser with ready Spire, must hold 100M/100G Mutalisk for 150M/100G Corruptor; at 160M/120G trains Corruptor!
  (define (mk-z-bc-obs mins gas-amt spire?)
    (hash 'frame 8400 'minerals mins 'gas gas-amt 'supply-used 76 'supply-cap 102 'supply-left 26
          'mineral-harvesters 48 'vespene-harvesters 12 'enemy-race 'Terran
          'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5
          'ally-units (append (for/list ([i (in-range 52)])
                                (hash 'id (+ 17100 i) 'type 'drone 'x 32.5 'y 32.5 'hp 40))
                              (for/list ([q (in-range 2)])
                                (hash 'id (+ 17170 q) 'type 'queen 'x 33.5 'y 32.5 'hp 175 'energy 10))
                              (for/list ([ov (in-range 4)])
                                (hash 'id (+ 17180 ov) 'type 'overlord 'x 32.5 'y 32.5 'hp 200))
                              (for/list ([z (in-range 10)])
                                (hash 'id (+ 17200 z) 'type 'zergling 'x 54.0 'y 32.5 'hp 35))
                              (list (hash 'id 17301 'type 'larva 'x 33.0 'y 31.0 'hp 25)
                                    (hash 'id 17302 'type 'larva 'x 33.5 'y 31.0 'hp 25)))
          'ally-buildings (append
                           (list (hash 'id 17001 'type 'lair 'x 32.5 'y 32.5 'hp 2000 'build-progress 1.0)
                                 (hash 'id 17002 'type 'hatchery 'x 58.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                 (hash 'id 17003 'type 'hatchery 'x 84.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                 (hash 'id 17004 'type 'spawning-pool 'x 36.5 'y 32.5 'hp 1000 'build-progress 1.0)
                                 (hash 'id 17006 'type 'extractor 'x 29.5 'y 35.5 'hp 500 'build-progress 1.0 'vespene-contents 1200)
                                 (hash 'id 17007 'type 'extractor 'x 29.5 'y 29.5 'hp 500 'build-progress 1.0 'vespene-contents 1200))
                           (if spire?
                               (list (hash 'id 17005 'type 'spire 'x 36.5 'y 36.5 'hp 850 'build-progress 1.0))
                               '()))
          'enemy-buildings (list (hash 'id 17999 'type 'command-center 'x 130.0 'y 130.0 'hp 1500 'build-progress 1.0))
          'enemy-units (list (hash 'id 17901 'type 'battlecruiser 'x 110.0 'y 110.0 'hp 550))))
  (define acts-z-spire (hash-ref (step-live-bot-runtime! (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg) (mk-z-bc-obs 220 220 #f)) 'actions '()))
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'spire))) acts-z-spire)
                "Zerg on >= 3 bases facing Battlecruiser with ready Lair must build Spire even if expand escrow would hold")
  (define acts-z-hold-muta (hash-ref (step-live-bot-runtime! (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg) (mk-z-bc-obs 120 150 #t)) 'actions '()))
  (assert-true! (not (member '(train mutalisk) acts-z-hold-muta))
                "Zerg with ready Spire facing Battlecruiser at 120M/150G must hold Mutalisk and save for 150M/100G Corruptor")
  (define acts-z-corr (hash-ref (step-live-bot-runtime! (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg) (mk-z-bc-obs 160 120 #t)) 'actions '()))
  (assert-true! (member '(train corruptor) acts-z-corr)
                "Zerg with ready Spire facing Battlecruiser at 160M/120G must train Corruptor ahead of Mutalisk"))

  ;; =========================================================================
  ;; SUITE 35: Ladder Forensics & Live Execution Regression Tests
  ;; =========================================================================
  (run-suite "35. Ladder Forensics: Zero-Larva Overlord, Build Cooldown, Power-Fail Pylon, Exp Backoff & Harass Evac"
    ;; 35.1 Zerg zero-Larva Overlord skip + 100M Overlord floor (exempt for early Zergling rush < 4 lings)
    (define (mk-z-ov-obs frm mins larva-cnt pool? enemy-probes)
      (hash 'frame frm 'minerals mins 'gas 0 'supply-used 14 'supply-cap 16 'supply-left 1
            'mineral-harvesters 14 'vespene-harvesters 0 'enemy-race 'Protoss
            'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5
            'ally-units (append (for/list ([i (in-range 14)])
                                  (hash 'id (+ 18100 i) 'type 'drone 'x 32.5 'y 32.5 'hp 40))
                                (list (hash 'id 18201 'type 'overlord 'x 32.5 'y 32.5 'hp 200)
                                      (hash 'id 18202 'type 'egg 'x 33.0 'y 31.0 'hp 200))
                                (for/list ([k (in-range larva-cnt)])
                                  (hash 'id (+ 18300 k) 'type 'larva 'x 33.5 'y 31.0 'hp 25)))
            'ally-buildings (append
                             (list (hash 'id 18001 'type 'hatchery 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0))
                             (if pool?
                                 (list (hash 'id 18002 'type 'spawning-pool 'x 36.5 'y 32.5 'hp 1000 'build-progress 1.0))
                                 '()))
            'enemy-units enemy-probes))
    (define acts-z-nolarva
      (hash-ref (step-live-bot-runtime! (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg)
                                        (mk-z-ov-obs 900 180 0 #t '()))
                'actions '()))
    (assert-true! (and (not (member '(train overlord) acts-z-nolarva))
                       (not (member '(train drone) acts-z-nolarva))
                       (not (member '(train zergling) acts-z-nolarva))
                       (not (member '(train queen) acts-z-nolarva)))
                  "Zerg with 0 explicit larvae and supply-left=1 must skip (train overlord) AND hold 100M/supply against Queen/Drone/Zergling")
    (define acts-z-haslarva
      (hash-ref (step-live-bot-runtime! (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg)
                                        (mk-z-ov-obs 900 180 1 #t '()))
                'actions '()))
    (assert-true! (member '(train overlord) acts-z-haslarva)
                  "Zerg with explicit larva >= 1 and supply-left=1 must train Overlord")
    (define rush-probes
      (for/list ([i (in-range 6)])
        (hash 'id (+ 18900 i) 'type 'probe 'x (+ 34.0 (* 0.4 i)) 'y 33.0 'hp 20 'shield 20)))
    (define acts-z-rush-exempt
      (hash-ref (step-live-bot-runtime! (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg)
                                        (mk-z-ov-obs 900 150 1 #t rush-probes))
                'actions '()))
    (assert-true! (or (member '(train zergling) acts-z-rush-exempt)
                      (member '(train overlord) acts-z-rush-exempt))
                  "Zerg emergency rush-ling exemption allows Zergling or Overlord training without stalling")
    (define acts-z-rush-lings-only
      (hash-ref (step-live-bot-runtime!
                 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg)
                 (hash 'frame 900 'minerals 75 'gas 0 'supply-used 15 'supply-cap 16 'supply-left 1
                       'mineral-harvesters 14 'vespene-harvesters 0 'enemy-race 'Protoss
                       'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5
                       'ally-units (list (hash 'id 18401 'type 'drone 'x 32.5 'y 32.5 'hp 40)
                                         (hash 'id 18402 'type 'larva 'x 33.5 'y 31.0 'hp 25))
                       'ally-buildings (list (hash 'id 18410 'type 'hatchery 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                             (hash 'id 18411 'type 'spawning-pool 'x 36.5 'y 32.5 'hp 1000 'build-progress 1.0))
                       'enemy-units rush-probes))
                'actions '()))
    (assert-true! (member '(train zergling) acts-z-rush-lings-only)
                  "Under worker rush with < 4 zerglings at 75M/1 supply-left, Zerg emergency-rush-lings? exempts 100M Overlord floor to train Zergling")

    ;; 35.2 Live duplicate-structure build cooldown (56f) & cancel-rebuild immediate unblock (60f)
    (define (clear-oledger! ol)
      (hash-clear! (in-progress-order-ledger-unit-orders ol))
      (hash-clear! (in-progress-order-ledger-type-order-counts ol))
      (set-in-progress-order-ledger-reserved-sites! ol '()))
    ;; (a) Protoss RoboticsBay cooldown + cancel unblock
    (define rt-cd-p (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
    (define (mk-p-bay-cd-obs frm)
      (hash 'frame frm 'minerals 300 'gas 200 'supply-used 54 'supply-cap 78 'supply-left 24
            'mineral-harvesters 32 'vespene-harvesters 10 'enemy-race 'Terran
            'researched-upgrades '(warp-gate-research)
            'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5
            'ally-units (append (for/list ([i (in-range 36)])
                                  (hash 'id (+ 18500 i) 'type 'probe 'x 32.5 'y 32.5 'hp 20 'shield 20))
                                (for/list ([s (in-range 4)])
                                  (hash 'id (+ 18550 s) 'type 'stalker 'x 54.0 'y 32.5 'hp 80 'shield 80))
                                (list (hash 'id 18570 'type 'immortal 'x 54.5 'y 32.5 'hp 200 'shield 100)
                                      (hash 'id 18571 'type 'observer 'x 55.0 'y 32.5 'hp 40 'shield 20)))
            'ally-buildings (list (hash 'id 18581 'type 'nexus 'x 32.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                  (hash 'id 18582 'type 'nexus 'x 58.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                  (hash 'id 18583 'type 'pylon 'x 36.0 'y 35.0 'hp 200 'shield 200 'build-progress 1.0)
                                  (hash 'id 18584 'type 'assimilator 'x 28.5 'y 35.5 'hp 450 'shield 450 'build-progress 1.0)
                                  (hash 'id 18585 'type 'assimilator 'x 28.5 'y 29.5 'hp 450 'shield 450 'build-progress 1.0)
                                  (hash 'id 18586 'type 'gateway 'x 36.5 'y 32.5 'hp 500 'shield 500 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                  (hash 'id 18587 'type 'gateway 'x 36.5 'y 36.5 'hp 500 'shield 500 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                  (hash 'id 18588 'type 'gateway 'x 36.5 'y 40.5 'hp 500 'shield 500 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                  (hash 'id 18589 'type 'cybernetics-core 'x 40.5 'y 32.5 'hp 550 'shield 550 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                  (hash 'id 18590 'type 'robotics-facility 'x 44.5 'y 32.5 'hp 500 'shield 500 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1))
            'enemy-units '()))
    (define acts-cd-p1 (hash-ref (step-live-bot-runtime! rt-cd-p (mk-p-bay-cd-obs 5000)) 'actions '()))
    (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'robotics-bay))) acts-cd-p1)
                  "Step 1 must issue (build robotics-bay)")
    ;; Clear pending order ledger to isolate the 56f duplicate build-issue lock
    (clear-oledger! (live-bot-runtime-order-ledger rt-cd-p))
    (define acts-cd-p2 (hash-ref (step-live-bot-runtime! rt-cd-p (mk-p-bay-cd-obs 5024)) 'actions '()))
    (assert-true! (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'robotics-bay))) acts-cd-p2))
                  "Within 56 frames and unchanged count, build-issue-blocked? must suppress duplicate (build robotics-bay)")
    ;; Simulate save-cancel on frame 5032 -> stays held while within 60f save-cancel cooldown (5040),
    ;; then unblocks once >= 60f past save-cancel (5094); also test pure 56f build-issue-lock expiry on fresh runtime.
    (hash-set! (refractory-cooldown-tracker-table (live-bot-runtime-cooldown-tracker rt-cd-p))
               'save-cancel-rebuild-robotics-bay 5032)
    (define acts-cd-p3-held (hash-ref (step-live-bot-runtime! rt-cd-p (mk-p-bay-cd-obs 5040)) 'actions '()))
    (assert-true! (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'robotics-bay))) acts-cd-p3-held))
                  "Within 60f of save-cancel-rebuild-robotics-bay (5040 vs 5032), rebuild must remain held")
    (define acts-cd-p4 (hash-ref (step-live-bot-runtime! rt-cd-p (mk-p-bay-cd-obs 5094)) 'actions '()))
    (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'robotics-bay))) acts-cd-p4)
                  "Once save-cancel-rebuild cooldown expires (>= 60f), robotics-bay rebuild must resume immediately")
    (define rt-cd-p-exp (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
    (void (step-live-bot-runtime! rt-cd-p-exp (mk-p-bay-cd-obs 5000)))
    (clear-oledger! (live-bot-runtime-order-ledger rt-cd-p-exp))
    (define acts-cd-p-exp
      (hash-ref (step-live-bot-runtime! rt-cd-p-exp (mk-p-bay-cd-obs 5058)) 'actions '()))
    (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'robotics-bay))) acts-cd-p-exp)
                  "After 56f build-issue-blocked? cooldown expires without save-cancel, robotics-bay retry is allowed")

    ;; (b) Zerg BanelingNest + Terran Bunker 56f duplicate-issue lock
    (define rt-cd-z (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
    (define (mk-z-bn-obs frm)
      (hash 'frame frm 'minerals 500 'gas 200 'supply-used 44 'supply-cap 60 'supply-left 16
            'mineral-harvesters 28 'vespene-harvesters 6 'enemy-race 'Terran
            'researched-upgrades '(metabolic-boost zergling-movementspeed)
            'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5
            'ally-units (append (for/list ([i (in-range 28)])
                                  (hash 'id (+ 18600 i) 'type 'drone 'x 32.5 'y 32.5 'hp 40))
                                (for/list ([z (in-range 8)])
                                  (hash 'id (+ 18640 z) 'type 'zergling 'x 50.0 'y 32.5 'hp 35))
                                (list (hash 'id 18660 'type 'larva 'x 33.0 'y 31.0 'hp 25)
                                      (hash 'id 18661 'type 'queen 'x 32.5 'y 32.5 'hp 175)
                                      (hash 'id 18662 'type 'queen 'x 58.5 'y 32.5 'hp 175)
                                      (hash 'id 18663 'type 'overseer 'x 32.5 'y 32.5 'hp 200)))
            'ally-buildings (list (hash 'id 18681 'type 'lair 'x 32.5 'y 32.5 'hp 2000 'build-progress 1.0)
                                  (hash 'id 18682 'type 'hatchery 'x 58.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                  (hash 'id 18683 'type 'hatchery 'x 84.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                  (hash 'id 18684 'type 'spawning-pool 'x 36.5 'y 32.5 'hp 1000 'build-progress 1.0)
                                  (hash 'id 18685 'type 'extractor 'x 29.5 'y 35.5 'hp 500 'build-progress 1.0 'vespene-contents 1200)
                                  (hash 'id 18686 'type 'extractor 'x 29.5 'y 29.5 'hp 500 'build-progress 1.0 'vespene-contents 1200)
                                  (hash 'id 18687 'type 'extractor 'x 55.5 'y 35.5 'hp 500 'build-progress 1.0 'vespene-contents 1200)
                                  (hash 'id 18688 'type 'roach-warren 'x 40.5 'y 32.5 'hp 850 'build-progress 1.0))
            'enemy-units (for/list ([m (in-range 8)])
                           (hash 'id (+ 18690 m) 'type 'marine 'x 110.0 'y 110.0 'hp 45))))
    (define acts-cd-z1 (hash-ref (step-live-bot-runtime! rt-cd-z (mk-z-bn-obs 3600)) 'actions '()))
    (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'baneling-nest))) acts-cd-z1)
                  "Step 1 Zerg must issue (build baneling-nest)")
    (clear-oledger! (live-bot-runtime-order-ledger rt-cd-z))
    (define acts-cd-z2 (hash-ref (step-live-bot-runtime! rt-cd-z (mk-z-bn-obs 3624)) 'actions '()))
    (assert-true! (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'baneling-nest))) acts-cd-z2))
                  "Within 56 frames, build-issue-blocked? must suppress duplicate (build baneling-nest)")

    (define rt-cd-t (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
    (define (mk-t-bnk-obs frm)
      (hash 'frame frm 'minerals 200 'gas 50 'supply-used 28 'supply-cap 46 'supply-left 18
            'mineral-harvesters 20 'vespene-harvesters 3 'enemy-race 'Zerg
            'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5
            'ally-units (append (for/list ([i (in-range 20)])
                                  (hash 'id (+ 18700 i) 'type 'scv 'x 32.5 'y 32.5 'hp 45))
                                (for/list ([m (in-range 4)])
                                  (hash 'id (+ 18740 m) 'type 'marine 'x 54.0 'y 32.5 'hp 45)))
            'ally-buildings (list (hash 'id 18781 'type 'orbital-command 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                  (hash 'id 18782 'type 'command-center 'x 58.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                  (hash 'id 18783 'type 'supply-depot 'x 36.0 'y 36.0 'hp 400 'build-progress 1.0)
                                  (hash 'id 18784 'type 'barracks 'x 38.5 'y 32.5 'hp 1000 'build-progress 1.0 'busy? #t 'order-count 1)
                                  (hash 'id 18785 'type 'refinery 'x 29.5 'y 35.5 'hp 500 'build-progress 1.0 'vespene-contents 1200))
            'enemy-units (for/list ([z (in-range 8)])
                           (hash 'id (+ 18790 z) 'type 'zergling 'x 72.0 'y 32.5 'hp 35))))
    (define acts-cd-t1 (hash-ref (step-live-bot-runtime! rt-cd-t (mk-t-bnk-obs 2800)) 'actions '()))
    (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'bunker))) acts-cd-t1)
                  "Step 1 Terran facing threat must issue (build bunker)")
    (clear-oledger! (live-bot-runtime-order-ledger rt-cd-t))
    (define acts-cd-t2 (hash-ref (step-live-bot-runtime! rt-cd-t (mk-t-bnk-obs 2824)) 'actions '()))
    (assert-true! (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'bunker))) acts-cd-t2))
                  "Within 56 frames, build-issue-blocked? must suppress duplicate (build bunker)")

    ;; 35.3 Protoss power-placement-failed?, interleave-lists, negative placement cooldown (32 loops + signature invalidation) & vs Mutalisk
    (assert-eq! (interleave-lists '((a1 a2 a3) (b1 b2) (c1)))
                   '(a1 b1 c1 a2 b2 a3)
                   "interleave-lists must round-robin candidates across multi-anchor placement lists")
    (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
    (define prev-wg-loop (unbox SC2-WARPGATE-LAST-LOOP))
    (set-box! SC2-WARPGATE-LAST-LOOP 200)
    (define-values (c35-in s35-out) (make-pipe))
    (define-values (s35-in c35-out) (make-pipe))
    (define mock-ws (sc2-ws-conn "127.0.0.1" 0 "/sc2api" c35-in c35-out #f 1))
    (define ws35-rpc-count 0)
    (define srv35-thd
      (thread
       (lambda ()
         (let lp ()
           (define hdr2 (read-bytes 2 s35-in))
           (unless (eof-object? hdr2)
             (define b0 (bytes-ref hdr2 0))
             (define b1 (bytes-ref hdr2 1))
             (define opcode (bitwise-and b0 #x0F))
             (define masked? (not (zero? (bitwise-and b1 #x80))))
             (define len7 (bitwise-and b1 #x7F))
             (define plen
               (cond [(< len7 126) len7]
                     [(= len7 126) (integer-bytes->integer (read-bytes 2 s35-in) #f #t)]
                     [else (integer-bytes->integer (read-bytes 8 s35-in) #f #t)]))
             (define mkey (if masked? (read-bytes 4 s35-in) #f))
             (define raw (read-bytes plen s35-in))
             (define payload (if masked? (mask-ws-payload raw mkey) raw))
             (when (= opcode 2)
               (set! ws35-rpc-count (add1 ws35-rpc-count))
               (define req-f (decode-protobuf-message payload))
               (define req-id-p (assoc 97 req-f))
               (define id-b (if req-id-p (encode-uint32 97 (third req-id-p)) #""))
               (define q-p (assoc 14 req-f))
               (when q-p
                 (define qf (decode-protobuf-message (third q-p)))
                 (define p-items (filter (lambda (e) (= (first e) 3)) qf))
                 (define res-b
                   (apply bytes-append
                          (for/list ([_it (in-list p-items)])
                            (encode-submessage-field 3 (encode-int32 1 2)))))
                 (define resp (bytes-append (encode-submessage-field 14 res-b) id-b (encode-int32 99 3)))
                 (define rlen (bytes-length resp))
                 (define rhdr
                   (cond [(< rlen 126) (bytes #x82 rlen)]
                         [(<= rlen 65535) (bytes-append (bytes #x82 126) (integer->integer-bytes rlen 2 #f #t))]
                         [else (bytes-append (bytes #x82 127) (integer->integer-bytes rlen 8 #f #t))]))
                 (write-bytes rhdr s35-out)
                 (write-bytes resp s35-out)
                 (flush-output s35-out))
               (lp)))))))
    (define zero-grid
      (sc2-image-grid 8 16 16 (make-bytes 256 0) #f #f))
    (define full-path-grid
      (sc2-image-grid 8 16 16 (make-bytes 256 1) #f #f))
    (define mock-gi
      (sc2-game-info "TestMap" "" '() '(16 16) '(0 0 16 16)
                     (list (sc2-point2d 12.0 12.0))
                     full-path-grid #f zero-grid))
    (define (mk-s35-pylon tag x y)
      (sc2-unit 1 1 tag 60 1
                (sc2-point3d x y 10.0) 0.0 1.0 1.0 0 #f #t #f
                200.0 200.0 200.0 200.0 0.0 0.0 0 0
                #f #f #f #t #f '() 0 '() 0 16 0.0 0 0 0 0))
    (define pylon-1 (mk-s35-pylon 1 8.0 8.0))
    (define res-neg-1
      (find-verified-building-placement mock-ws 882 8.0 8.0 (list pylon-1) #:bldg-sym 'gateway #:game-info mock-gi))
    (define rpcs-after-1 ws35-rpc-count)
    (assert-true! (and (not res-neg-1)
                       (> rpcs-after-1 0)
                       (= (hash-ref SC2-PLACEMENT-NEG-COOLDOWN '(gateway 8 8) -1) 200))
                  "Failed placement under active WS must record loop 200 in SC2-PLACEMENT-NEG-COOLDOWN")
    (set-box! SC2-WARPGATE-LAST-LOOP 210)
    (define res-neg-2
      (find-verified-building-placement mock-ws 882 8.0 8.0 (list pylon-1) #:bldg-sym 'gateway #:game-info mock-gi))
    (assert-true! (and (not res-neg-2)
                       (= ws35-rpc-count rpcs-after-1)
                       (= (hash-ref SC2-PLACEMENT-NEG-COOLDOWN '(gateway 8 8) -1) 200))
                  "Within 32 loops with unchanged Pylon/TH/Tumor signature, neg cooldown hits and skips recompute")
    (define pylon-2 (mk-s35-pylon 2 12.0 8.0))
    (void (find-verified-building-placement mock-ws 882 8.0 8.0 (list pylon-1 pylon-2) #:bldg-sym 'gateway #:game-info mock-gi))
    (assert-true! (and (> ws35-rpc-count rpcs-after-1)
                       (= (hash-ref SC2-PLACEMENT-NEG-COOLDOWN '(gateway 8 8) -1) 210))
                  "Adding a Pylon invalidates placement cache signature and updates failure timestamp to 210")
    (kill-thread srv35-thd)
    (close-output-port c35-out)
    (close-input-port c35-in)
    (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
    (set-box! SC2-WARPGATE-LAST-LOOP prev-wg-loop)

    ;; Protoss 'power-placement-failed? triggers Pylon + rotates quadrant
    (define rt-ppfail (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
    (define (mk-ppfail-obs frm)
      (hash 'frame frm 'minerals 340 'gas 50 'supply-used 36 'supply-cap 46 'supply-left 10
            'mineral-harvesters 28 'vespene-harvesters 6 'enemy-race 'Terran
            'power-placement-failed? #t
            'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5
            'ally-units (for/list ([i (in-range 28)])
                          (hash 'id (+ 18800 i) 'type 'probe 'x 32.5 'y 32.5 'hp 20 'shield 20))
            'ally-buildings (list (hash 'id 18881 'type 'nexus 'x 32.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                  (hash 'id 18882 'type 'nexus 'x 58.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                  (hash 'id 18883 'type 'pylon 'x 36.0 'y 35.0 'hp 200 'shield 200 'build-progress 1.0)
                                  (hash 'id 18884 'type 'pylon 'x 40.0 'y 35.0 'hp 200 'shield 200 'build-progress 1.0)
                                  (hash 'id 18885 'type 'gateway 'x 36.5 'y 32.5 'hp 500 'shield 500 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1))
            'enemy-units '()))
    (define acts-ppf1 (hash-ref (step-live-bot-runtime! rt-ppfail (mk-ppfail-obs 3000)) 'actions '()))
    (define py-act1 (findf (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'pylon))) acts-ppf1))
    (assert-true! (and py-act1 (= (hash-ref (rt-wall-state rt-ppfail) 'inmain-supply-attempts 0) 1))
                  "power-placement-failed? #t must trigger emergency Pylon and increment inmain-supply-attempts")
    (define acts-ppf2 (hash-ref (step-live-bot-runtime! rt-ppfail (mk-ppfail-obs 3030)) 'actions '()))
    (define py-act2 (findf (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'pylon))) acts-ppf2))
    (assert-true! (and py-act2
                       (= (hash-ref (rt-wall-state rt-ppfail) 'inmain-supply-attempts 0) 2)
                       (not (and (= (third py-act1) (third py-act2))
                                 (= (fourth py-act1) (fourth py-act2)))))
                  "Subsequent power-placement-failed? step must rotate emergency Pylon placement anchor")

    ;; Protoss vs Mutalisks: Twilight researches Blink before Charge, defers RoboticsBay, builds ShieldBattery & PhotonCannon
    (define acts-p-muta
      (hash-ref (step-live-bot-runtime!
                 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss)
                 (hash 'frame 5400 'minerals 750 'gas 300 'supply-used 60 'supply-cap 90 'supply-left 30
                       'mineral-harvesters 34 'vespene-harvesters 10 'enemy-race 'Zerg
                       'researched-upgrades '(warp-gate-research)
                       'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5
                       'ally-units (append (for/list ([i (in-range 36)])
                                             (hash 'id (+ 19100 i) 'type 'probe 'x 32.5 'y 32.5 'hp 20 'shield 20))
                                           (for/list ([s (in-range 4)])
                                             (hash 'id (+ 19150 s) 'type 'stalker 'x 54.0 'y 32.5 'hp 80 'shield 80))
                                           (list (hash 'id 19170 'type 'immortal 'x 54.5 'y 32.5 'hp 200 'shield 100)))
                       'ally-buildings (list (hash 'id 19001 'type 'nexus 'x 32.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                             (hash 'id 19002 'type 'nexus 'x 58.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                             (hash 'id 19014 'type 'nexus 'x 84.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                             (hash 'id 19003 'type 'pylon 'x 36.0 'y 35.0 'hp 200 'shield 200 'build-progress 1.0)
                                             (hash 'id 19004 'type 'assimilator 'x 28.5 'y 35.5 'hp 450 'shield 450 'build-progress 1.0)
                                             (hash 'id 19005 'type 'assimilator 'x 28.5 'y 29.5 'hp 450 'shield 450 'build-progress 1.0)
                                             (hash 'id 19006 'type 'gateway 'x 36.5 'y 32.5 'hp 500 'shield 500 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                             (hash 'id 19012 'type 'gateway 'x 36.5 'y 36.5 'hp 500 'shield 500 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                             (hash 'id 19013 'type 'gateway 'x 36.5 'y 40.5 'hp 500 'shield 500 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                             (hash 'id 19007 'type 'cybernetics-core 'x 40.5 'y 32.5 'hp 550 'shield 550 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                             (hash 'id 19008 'type 'forge 'x 40.5 'y 28.5 'hp 550 'shield 550 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                             (hash 'id 19009 'type 'robotics-facility 'x 44.5 'y 32.5 'hp 500 'shield 500 'build-progress 1.0 'powered? #t 'busy? #t 'order-count 1)
                                             (hash 'id 19010 'type 'twilight-council 'x 40.5 'y 36.5 'hp 500 'shield 500 'build-progress 1.0 'powered? #t 'busy? #f 'order-count 0))
                       'enemy-buildings (list (hash 'id 19999 'type 'hatchery 'x 130.0 'y 130.0 'hp 1500 'build-progress 1.0)
                                              (hash 'id 19998 'type 'spire 'x 134.0 'y 130.0 'hp 850 'build-progress 1.0))
                       'enemy-units (for/list ([m (in-range 4)])
                                      (hash 'id (+ 19900 m) 'type 'mutalisk 'x 90.0 'y 90.0 'hp 120 'flying? #t))))
                'actions '()))
    (assert-true! (and (member '(research blink) acts-p-muta)
                       (not (member '(research charge) acts-p-muta))
                       (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'robotics-bay))) acts-p-muta))
                       (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'shield-battery))) acts-p-muta)
                       (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'photon-cannon))) acts-p-muta))
                  "Protoss facing Mutalisks with < 10 Stalkers must research Blink before Charge, defer RoboticsBay, and build ShieldBattery + PhotonCannon")

    ;; 35.4 Terran exp-timeout-count exponential backoff (224 -> 448 -> 672, reset on new TH) & Starport/550M 3rd-CC escrow gate
    (define rt-t-3cc (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
    (define (mk-t-3cc-obs frm mins starport? th-cnt)
      (hash 'frame frm 'minerals mins 'gas 40 'supply-used 60 'supply-cap 90 'supply-left 30
            'mineral-harvesters 38 'vespene-harvesters 6 'enemy-race 'Terran
            'researched-upgrades '(stimpack combat-shield)
            'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5
            'expansion-candidates (list '(84.5 . 32.5) '(32.5 . 62.5))
            'ally-units (append (for/list ([i (in-range 42)])
                                  (hash 'id (+ 19200 i) 'type 'scv 'x 32.5 'y 32.5 'hp 45))
                                (for/list ([m (in-range 11)])
                                  (hash 'id (+ 19260 m) 'type 'marine 'x 54.0 'y 32.5 'hp 45)))
            'ally-buildings (append
                             (list (hash 'id 19301 'type 'orbital-command 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                   (hash 'id 19302 'type 'orbital-command 'x 58.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                   (hash 'id 19303 'type 'supply-depot 'x 36.0 'y 36.0 'hp 400 'build-progress 1.0)
                                   (hash 'id 19304 'type 'barracks 'x 38.5 'y 32.5 'hp 1000 'build-progress 1.0 'busy? #t 'order-count 1)
                                   (hash 'id 19305 'type 'barracks 'x 38.5 'y 36.5 'hp 1000 'build-progress 1.0 'busy? #t 'order-count 1)
                                   (hash 'id 19306 'type 'factory 'x 44.5 'y 32.5 'hp 1250 'build-progress 1.0 'busy? #t 'order-count 1)
                                   (hash 'id 19309 'type 'engineering-bay 'x 37.5 'y 28.5 'hp 850 'build-progress 1.0 'busy? #t 'order-count 1)
                                   (hash 'id 19310 'type 'refinery 'x 29.5 'y 35.5 'hp 500 'build-progress 1.0 'vespene-contents 1200)
                                   (hash 'id 19311 'type 'refinery 'x 29.5 'y 29.5 'hp 500 'build-progress 1.0 'vespene-contents 1200))
                             (if (>= th-cnt 3)
                                 (list (hash 'id 19307 'type 'command-center 'x 84.5 'y 32.5 'hp 1500 'build-progress 0.2))
                                 '())
                             (if starport?
                                 (list (hash 'id 19308 'type 'starport 'x 44.5 'y 36.5 'hp 1300 'build-progress 1.0 'busy? #t 'order-count 1))
                                 '()))
            'enemy-units '()))
    (define res-t-3cc-blocked (step-live-bot-runtime! rt-t-3cc (mk-t-3cc-obs 6200 450 #f 2)))
    (assert-true! (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'expand))) (hash-ref res-t-3cc-blocked 'actions '())))
                  "Live 2-base Terran at 450M without ready Starport must NOT expand 3rd CC before Starport")
    (define res-t-3cc-sp (step-live-bot-runtime! (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran)
                                                 (mk-t-3cc-obs 6200 450 #t 2)))
    (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'expand))) (hash-ref res-t-3cc-sp 'actions '()))
                  "Live 2-base Terran at 450M WITH ready Starport is unlocked to expand 3rd CC")

    ;; Exponential exp-timeout-count backoff: 224f -> 448f -> 672f -> resets to 0 on new TH
    (define rt-backoff (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
    (define (mk-t-stalled-escrow-obs frm th-cnt)
      (hash 'frame frm 'minerals 350 'gas 0 'supply-used 22 'supply-cap 30 'supply-left 8
            'mineral-harvesters 18 'vespene-harvesters 0 'enemy-race 'Terran
            'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5
            'expansion-candidates (list '(58.5 . 32.5))
            'ally-units (append (for/list ([i (in-range 19)])
                                  (hash 'id (+ 19400 i) 'type 'scv 'x 32.5 'y 32.5 'hp 45))
                                (list (hash 'id 19460 'type 'marine 'x 35.0 'y 32.5 'hp 45)))
            'ally-buildings (append
                             (list (hash 'id 19501 'type 'orbital-command 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                   (hash 'id 19503 'type 'supply-depot 'x 36.0 'y 36.0 'hp 400 'build-progress 1.0)
                                   (hash 'id 19504 'type 'barracks 'x 38.5 'y 32.5 'hp 1000 'build-progress 1.0 'busy? #t 'order-count 1)
                                   (hash 'id 19510 'type 'refinery 'x 29.5 'y 35.5 'hp 500 'build-progress 1.0 'vespene-contents 1200))
                             (if (>= th-cnt 2)
                                 (list (hash 'id 19506 'type 'command-center 'x 58.5 'y 32.5 'hp 1500 'build-progress 0.2))
                                 '()))
            'enemy-units '()))
    (void (step-live-bot-runtime! rt-backoff (mk-t-stalled-escrow-obs 1500 1)))
    (void (step-live-bot-runtime! rt-backoff (mk-t-stalled-escrow-obs 1730 1)))
    (define tel-bo-1 (live-bot-runtime-last-telemetry rt-backoff))
    (assert-eq! (hash-ref tel-bo-1 'exp-timeout-count -1) 1
                   "First 224f stalled CC escrow timeout increments exp-timeout-count to 1 and suppresses 224f")
    (assert-eq! (hash-ref tel-bo-1 'escrow-suppressed-until-frame 0) (+ 1730 224)
                   "Timeout #1 suppresses CC escrow for exactly 224 frames")
    ;; Advance past 1954, re-arm escrow and stall another 224f -> timeout #2 suppresses 448f, timeout #3 caps at 672f!
    (void (step-live-bot-runtime! rt-backoff (mk-t-stalled-escrow-obs 1960 1)))
    (void (step-live-bot-runtime! rt-backoff (mk-t-stalled-escrow-obs 2190 1)))
    (define tel-bo-2 (live-bot-runtime-last-telemetry rt-backoff))
    (assert-eq! (hash-ref tel-bo-2 'exp-timeout-count -1) 2
                   "Second CC escrow timeout increments exp-timeout-count to 2")
    (assert-eq! (hash-ref tel-bo-2 'escrow-suppressed-until-frame 0) (+ 2190 448)
                   "Timeout #2 exponentially doubles suppression window to 448 frames")
    ;; Stepping mid-suppression (2500 < 2638) must NOT increment timeout count
    (void (step-live-bot-runtime! rt-backoff (mk-t-stalled-escrow-obs 2500 1)))
    (assert-eq! (hash-ref (live-bot-runtime-last-telemetry rt-backoff) 'exp-timeout-count -1) 2
                   "Stepping during active suppression must not increment exp-timeout-count")
    ;; Advance past 2638 and stall another 224f -> timeout #3 reaches 672-frame cap
    (void (step-live-bot-runtime! rt-backoff (mk-t-stalled-escrow-obs 2650 1)))
    (void (step-live-bot-runtime! rt-backoff (mk-t-stalled-escrow-obs 2880 1)))
    (define tel-bo-3 (live-bot-runtime-last-telemetry rt-backoff))
    (assert-eq! (hash-ref tel-bo-3 'exp-timeout-count -1) 3
                   "Third CC escrow timeout increments exp-timeout-count to 3")
    (assert-eq! (hash-ref tel-bo-3 'escrow-suppressed-until-frame 0) (+ 2880 672)
                   "Timeout #3 reaches 672-frame cap")
    ;; Adding new TownHall resets exp-timeout-count back to 0
    (void (step-live-bot-runtime! rt-backoff (mk-t-stalled-escrow-obs 2890 2)))
    (assert-eq! (hash-ref (live-bot-runtime-last-telemetry rt-backoff) 'exp-timeout-count -1) 0
                   "Adding a new TownHall resets exp-timeout-count back to 0")

    ;; 35.5 Non-worker harasser mineral-line evacuation (mineral-walk + 'evac lease when < 2 AA defenders; suppressed when >= 2 AA defenders)
    (define main-mp (hash 'id 19701 'type 'mineral-field 'x 26.0 'y 32.5))
    (define nat-safe-mp (hash 'id 19702 'type 'mineral-field 'x 58.5 'y 25.5))
    (define rt-evac-nat (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
    (define acts-evac-nat
      (hash-ref (step-live-bot-runtime!
                 rt-evac-nat
                 (hash 'frame 3200 'minerals 100 'gas 50 'supply-used 34 'supply-cap 46 'supply-left 12
                       'mineral-harvesters 18 'vespene-harvesters 3 'enemy-race 'Protoss
                       'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5
                       'mineral-patches (list main-mp nat-safe-mp)
                       'ally-units (list (hash 'id 19801 'type 'probe 'x 27.5 'y 32.5 'hp 20 'shield 20)
                                         (hash 'id 19802 'type 'probe 'x 28.0 'y 33.5 'hp 20 'shield 20)
                                         (hash 'id 19803 'type 'zealot 'x 28.0 'y 32.5 'hp 100 'shield 50)
                                         (hash 'id 19804 'type 'zealot 'x 29.0 'y 32.5 'hp 100 'shield 50))
                       'ally-buildings (list (hash 'id 19881 'type 'nexus 'x 32.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                             (hash 'id 19882 'type 'nexus 'x 58.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                             (hash 'id 19883 'type 'pylon 'x 36.0 'y 35.0 'hp 200 'shield 200 'build-progress 1.0))
                       'enemy-units (list (hash 'id 19950 'type 'oracle 'x 28.5 'y 32.5 'hp 100 'shield 60 'flying? #t))))
                'actions '()))
    (assert-true! (and (member '(mineral-walk 19801 19702 58.5 25.5) acts-evac-nat)
                       (unit-leased-above? (rt-role-leases rt-evac-nat) 19801 'harvester 3200)
                       (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'return-workers-to-gather))) acts-evac-nat)))
                  "Oracle with only Zealots (0 AA defenders) must evacuate probes via mineral-walk to safe natural patch + 'evac lease")

    ;; 1-base Oracle (no safe far mineral patch >= 14.0 away) emits mineral-walk MOVE (patch-id=0)
    (define rt-evac-1base (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
    (define acts-evac-1base
      (hash-ref (step-live-bot-runtime!
                 rt-evac-1base
                 (hash 'frame 3200 'minerals 100 'gas 50 'supply-used 24 'supply-cap 38 'supply-left 14
                       'mineral-harvesters 14 'vespene-harvesters 3 'enemy-race 'Protoss
                       'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5
                       'mineral-patches (list main-mp)
                       'ally-units (list (hash 'id 19811 'type 'scv 'x 27.5 'y 32.5 'hp 45))
                       'ally-buildings (list (hash 'id 19891 'type 'command-center 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0))
                       'enemy-units (list (hash 'id 19951 'type 'oracle 'x 29.0 'y 32.5 'hp 100 'shield 60 'flying? #t))))
                'actions '()))
    (assert-true! (ormap (lambda (a)
                           (and (pair? a)
                                (eq? (car a) 'mineral-walk)
                                (= (second a) 19811)
                                (= (third a) 0)))
                         acts-evac-1base)
                  "1-base Oracle without far safe mineral patch must emit (mineral-walk wid 0 away-x away-y)")

    ;; >= 2 matching AA defenders (2 Stalkers) suppress mineral-line evacuation
    (define rt-evac-def (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
    (define acts-evac-def
      (hash-ref (step-live-bot-runtime!
                 rt-evac-def
                 (hash 'frame 3200 'minerals 100 'gas 50 'supply-used 34 'supply-cap 46 'supply-left 12
                       'mineral-harvesters 18 'vespene-harvesters 3 'enemy-race 'Protoss
                       'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5
                       'mineral-patches (list main-mp nat-safe-mp)
                       'ally-units (list (hash 'id 19821 'type 'probe 'x 27.5 'y 32.5 'hp 20 'shield 20)
                                         (hash 'id 19822 'type 'stalker 'x 29.0 'y 32.5 'hp 80 'shield 80)
                                         (hash 'id 19823 'type 'stalker 'x 30.0 'y 32.5 'hp 80 'shield 80))
                       'ally-buildings (list (hash 'id 19886 'type 'nexus 'x 32.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                             (hash 'id 19887 'type 'nexus 'x 58.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0))
                       'enemy-units (list (hash 'id 19952 'type 'oracle 'x 28.5 'y 32.5 'hp 100 'shield 60 'flying? #t))))
                'actions '()))
    (assert-true! (and (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk))) acts-evac-def))
                       (not (unit-leased-above? (rt-role-leases rt-evac-def) 19821 'harvester 3200)))
                  "Oracle with >= 2 nearby AA defenders (Stalkers) must NOT trigger unnecessary worker evacuation"))

(run-suite
 "36. Wave 6 Track 1: Worker-Rush Focus-Fire, Disengage & Mixed Probe+Zealot Micro"
   (define base-mp (hash 'id 20550 'type 'mineral-field 'x 26.5 'y 32.5))
   (define base-nexus (hash 'id 20001 'type 'nexus 'x 32.5 'y 32.5
                            'hp 1000 'max-hp 1000 'shield 1000 'max-shield 1000
                            'build-progress 1.0 'powered? #f))

   ;; 36.1 Bruised-worker disengage (<= 20 EHP / Probe shield <= 2 & hp < 20), +45f cooldown, <= 10 HP override
   (define rt-dis (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
   (define (mk-dis-obs frame p1-hp p1-sh)
     (hash 'frame frame 'minerals 100 'gas 0 'supply-used 14 'supply-cap 15 'supply-left 1
           'mineral-harvesters 12 'vespene-harvesters 0
           'base-x 32.5 'base-y 32.5 'natural-x 60.5 'natural-y 32.5
           'mineral-patches (list base-mp)
           'ally-units (cons (hash 'id 20101 'type 'probe 'x 34.5 'y 32.5 'hp p1-hp 'shield p1-sh)
                             (for/list ([i (in-range 1 12)])
                               (hash 'id (+ 20101 i) 'type 'probe 'x (+ 27.0 (* 0.4 i)) 'y 32.5 'hp 20 'shield 20)))
           'ally-buildings (list base-nexus)
           'enemy-units (for/list ([j (in-range 8)])
                          (hash 'id (+ 20901 j) 'type 'probe 'x (+ 35.5 (* 0.2 j)) 'y 32.5 'hp 20 'shield 20))
           'enemy-buildings '()))
   ;; Frame 700: Probe #20101 at 19 HP + 1 Shield (20 EHP) disengages via mineral-walk
   (define acts-dis-1 (hash-ref (step-live-bot-runtime! rt-dis (mk-dis-obs 700 19 1)) 'actions '()))
   (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk) (equal? (second a) 20101)))
                        acts-dis-1)
                 "Probe at 19 HP + 1 Shield (<= 20 EHP) must disengage via mineral-walk")
   ;; Frame 730 (inside +45f cooldown [724..745]): at 15 HP (> 10), does NOT re-trigger mineral-walk
   (define acts-dis-mid (hash-ref (step-live-bot-runtime! rt-dis (mk-dis-obs 730 15 0)) 'actions '()))
   (assert-true! (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk) (equal? (second a) 20101)))
                             acts-dis-mid))
                 "Probe at 15 HP during post-slide cooldown [724..745) must not re-trigger mineral-walk")
   ;; Frame 732 (still < 745): at 10 HP (<= 10), immediate re-disengage override triggers mineral-walk!
   (define acts-dis-low (hash-ref (step-live-bot-runtime! rt-dis (mk-dis-obs 732 10 0)) 'actions '()))
   (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk) (equal? (second a) 20101)))
                        acts-dis-low)
                 "Critically bruised Probe at <= 10 HP must override cooldown and immediately re-disengage")
   ;; Frame 778 (>= 732 + 45 = 777, well before old +92f = 824): Probe at 18 HP re-disengages
   (define acts-dis-cd (hash-ref (step-live-bot-runtime! rt-dis (mk-dis-obs 778 18 0)) 'actions '()))
   (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk) (equal? (second a) 20101)))
                        acts-dis-cd)
                 "Bruised Probe at 18 HP must re-disengage after 45-frame cooldown (before old 92-frame lockout)")

   ;; 36.2 Pass-2 targeted focus-fire in live >= 6-worker brawl (no blind Attack-Move spread)
   (define rt-p2 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
   (define p2-ally-probes
     (for/list ([i (in-range 12)])
       ;; Placed 4.5-5.5 tiles from enemy Probes at x=34.0..35.0 so Pass-2 handles them
       (hash 'id (+ 21101 i) 'type 'probe 'x (+ 28.5 (* 0.1 i)) 'y 32.5 'hp 20 'shield 20)))
   (define p2-enemy-probes
     (cons (hash 'id 21901 'type 'probe 'x 34.0 'y 32.5 'hp 10 'shield 0)
           (for/list ([j (in-range 1 10)])
             (hash 'id (+ 21901 j) 'type 'probe 'x (+ 34.2 (* 0.15 j)) 'y 32.5 'hp 20 'shield 20))))
   (define acts-p2
     (hash-ref (step-live-bot-runtime!
                rt-p2
                (hash 'frame 800 'minerals 100 'gas 0 'supply-used 12 'supply-cap 15 'supply-left 3
                      'mineral-harvesters 12 'vespene-harvesters 0
                      'base-x 32.5 'base-y 32.5 'natural-x 60.5 'natural-y 32.5
                      'mineral-patches (list base-mp)
                      'ally-units p2-ally-probes
                      'ally-buildings (list base-nexus)
                      'enemy-units p2-enemy-probes
                      'enemy-buildings '()))
               'actions '()))
   (define pulls-p2
     (filter (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack))) acts-p2))
   (assert-true! (and (pair? pulls-p2)
                      (ormap (lambda (a) (equal? (third a) 21901)) pulls-p2))
                 "Pass-2 in live >= 6-worker brawl must focus-fire lowest-EHP enemy Probe #21901 by unit ID")
   (assert-true! (not (ormap (lambda (a) (= (third a) 0)) pulls-p2))
                 "Pass-2 workers within 6.0 tiles must use unit-targeted focus-fire instead of blind Attack-Move (tid=0)")

   ;; 36.3 14-frame hysteresis prevents snap-back when enemies step just outside 7.0 tiles
   (define rt-hys (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
   (define (mk-hys-obs frame enemy-x)
     (hash 'frame frame 'minerals 100 'gas 0 'supply-used 12 'supply-cap 15 'supply-left 3
           'mineral-harvesters 12 'vespene-harvesters 0
           'base-x 32.5 'base-y 32.5 'natural-x 60.5 'natural-y 32.5
           'mineral-patches (list base-mp)
           'ally-units (for/list ([i (in-range 12)])
                         (hash 'id (+ 22101 i) 'type 'probe 'x (+ 31.0 (* 0.2 i)) 'y 32.5 'hp 20 'shield 20))
           'ally-buildings (list base-nexus)
           'enemy-units (for/list ([j (in-range 10)])
                          (hash 'id (+ 22901 j) 'type 'probe 'x (+ enemy-x (* 0.05 j)) 'y 32.5 'hp 20 'shield 20))
           'enemy-buildings '()))
   ;; Frame 900: enemy at 6.5 tiles (x=39.0) -> pull-workers-attack
   (define acts-hys-1 (hash-ref (step-live-bot-runtime! rt-hys (mk-hys-obs 900 39.0)) 'actions '()))
   (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack))) acts-hys-1)
                 "Enemies inside 7.0 tiles (x=39.0) must trigger pull-workers-attack")
   ;; Frame 908 (8 frames later): enemy kites to 7.8 tiles (x=40.3, > 7.0, <= 8.5) -> stays engaged, zero harvest-mineral snap-back
   (define acts-hys-2 (hash-ref (step-live-bot-runtime! rt-hys (mk-hys-obs 908 40.3)) 'actions '()))
   (assert-true! (and (ormap (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack))) acts-hys-2)
                      (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'harvest-mineral))) acts-hys-2)))
                 "Within 14-frame hysteresis, enemies kiting to 7.8 tiles must not snap defenders back to harvest-mineral")
   ;; Frame 920 (20 frames later): enemy still outside 7.0 tiles (at 9.0 tiles, x=41.5) -> hysteresis expires, snaps back to harvest-mineral
   (define acts-hys-3 (hash-ref (step-live-bot-runtime! rt-hys (mk-hys-obs 920 41.5)) 'actions '()))
   (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'harvest-mineral))) acts-hys-3)
                 "After 14-frame hysteresis expires, defenders must snap back to harvest-mineral")

   ;; 36.4 Mixed Probe+Zealot rush: Probes avoid Zealots via mineral-walk and focus enemy Probes
   (define rt-mix (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
   (define mix-far-mp (hash 'id 23551 'type 'mineral-field 'x 26.5 'y 38.0))
   (define mix-obs
     (hash 'frame 1400 'minerals 100 'gas 0 'supply-used 16 'supply-cap 23 'supply-left 7
           'mineral-harvesters 12 'vespene-harvesters 0
           'base-x 32.5 'base-y 32.5 'natural-x 60.5 'natural-y 32.5
           'mineral-patches (list base-mp mix-far-mp)
           'ally-units (append
                        (list (hash 'id 23101 'type 'probe 'x 34.0 'y 32.5 'hp 20 'shield 20) ;; right next to enemy Zealot!
                              (hash 'id 23300 'type 'zealot 'x 33.5 'y 32.5 'hp 100 'shield 50))
                        (for/list ([i (in-range 1 12)])
                          (hash 'id (+ 23101 i) 'type 'probe 'x (+ 27.5 (* 0.3 i)) 'y 35.5 'hp 20 'shield 20)))
           'ally-buildings (list base-nexus)
           'enemy-units (append
                         (list (hash 'id 23950 'type 'zealot 'x 35.0 'y 32.5 'hp 100 'shield 50))
                         (for/list ([j (in-range 6)])
                           (hash 'id (+ 23901 j) 'type 'probe 'x (+ 29.0 (* 0.2 j)) 'y 36.5 'hp 20 'shield 20)))
           'enemy-buildings '()))
   (define acts-mix (hash-ref (step-live-bot-runtime! rt-mix mix-obs) 'actions '()))
   (define pulls-mix (filter (lambda (a) (and (pair? a) (eq? (car a) 'pull-workers-attack))) acts-mix))
   (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'mineral-walk) (equal? (second a) 23101)))
                        acts-mix)
                 "Probe #23101 adjacent to enemy Zealot in mixed rush must mineral-walk away")
   (assert-true! (not (ormap (lambda (a) (or (= (third a) 23950) (= (third a) 0))) pulls-mix))
                 "Mixed Probe+Zealot rush must NEVER target enemy Zealot (#23950) or emit blind Attack-Move (tid=0) for Probes")
   (assert-true! (ormap (lambda (a) (and (>= (third a) 23901) (<= (third a) 23906))) pulls-mix)
                 "Mixed Probe+Zealot rush must prioritize pulling Probes onto enemy Probes away from the Zealot"))
  (run-suite "37. Wave 6 Track 2: Protoss Early Gateway Placement, Anchor Preservation, Lockout Fallback & Early Pylon"
    (define (clear-oledger36! ol)
      (hash-clear! (in-progress-order-ledger-unit-orders ol))
      (hash-clear! (in-progress-order-ledger-type-order-counts ol))
      (set-in-progress-order-ledger-reserved-sites! ol '()))
    ;; 36.1 Primary anchor preservation in sc2-protobuf-ws.rkt:
    ;; Powered wall-slot (44.5, 36.5) with Pylon at (41.0, 34.0) and wall-slot AABB at (44.5, 36.5)
    ;; must place Gateway at (44.5, 36.5) instead of overwriting anchor with Pylon's (41.0, 34.0).
    (define obs36-gw
      (sc2-observation
       550
       (sc2-player-common 1 200 0 16 23 0 16 0 0 0 0)
       (list (sc2-unit 1 1 20001 59 1 (sc2-point3d 32.5 32.5 10.0) 0.0 2.5 1.0 0 #f #f #f
                       1000.0 1000.0 1000.0 1000.0 0.0 0.0 0 0 #f #f #f #t #t '() 0 '() 0 16 0.0 0 0 0 0)
             (sc2-unit 1 1 20002 60 1 (sc2-point3d 41.0 34.0 10.0) 0.0 1.0 1.0 0 #f #f #f
                       200.0 200.0 200.0 200.0 0.0 0.0 0 0 #f #f #f #t #t '() 0 '() 0 0 0.0 0 0 0 0)
             (sc2-unit 1 1 20003 84 1 (sc2-point3d 42.0 35.0 10.0) 0.0 0.375 1.0 0 #f #f #f
                       20.0 20.0 20.0 20.0 0.0 0.0 0 0 #f #f #f #t #t '() 0 '() 0 0 0.0 0 0 0 0))
       '()
       (list (sc2-power-source (sc2-point3d 41.0 34.0 10.0) 6.5 20002))
       #f '() '() '() '() '() '()))
    (define cmds36-gw
      (translate-bot-actions->sc2-raw-commands
       '((build gateway 44.5 36.5))
       obs36-gw
       #:reserved-aabbs (list (reserved-aabb 44.5 36.5 1.5 1.5 'wall-slot 0 0))))
    (define gw-cmd36
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 883)))
             cmds36-gw))
    (assert-true! (and (sc2-raw-unit-command? gw-cmd36)
                       (sc2-point2d? (sc2-raw-unit-command-target-pos gw-cmd36))
                       (< (abs (- (sc2-point2d-x (sc2-raw-unit-command-target-pos gw-cmd36)) 44.5)) 0.1)
                       (< (abs (- (sc2-point2d-y (sc2-raw-unit-command-target-pos gw-cmd36)) 36.5)) 0.1))
                  "Powered wall-slot (44.5, 36.5) must preserve req-x/req-y as primary anchor and strip wall-slot AABB")

    ;; 36.2 power-placement-failed? immediate fallback & 16-frame oledger fallback to inmain-powered-gx/gy
    (define (mk-p-gw-obs frm #:power-fail? [pf? #f] #:pylon-x [px 43.0] #:pylon-y [py 32.5]
                           #:enemy-probes [ep-cnt 0])
      (hash 'frame frm 'minerals 280 'gas 0 'supply-used 15 'supply-cap 31 'supply-left 16
            'mineral-harvesters 15 'vespene-harvesters 0 'enemy-race 'Protoss
            'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5
            'power-placement-failed? pf?
            'ally-units (for/list ([i (in-range 15)])
                          (hash 'id (+ 20100 i) 'type 'probe 'x 30.0 'y 32.5 'hp 20 'shield 20))
            'ally-buildings (list (hash 'id 20181 'type 'nexus 'x 32.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                  (hash 'id 20182 'type 'pylon 'x px 'y py 'hp 200 'shield 200 'build-progress 1.0))
            'enemy-units (for/list ([i (in-range ep-cnt)])
                           (hash 'id (+ 20200 i) 'type 'probe 'x (+ 31.0 (* 0.4 i)) 'y 32.5 'hp 20 'shield 20))))

    (define rt36-pf (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
    (define acts36-pf1 (hash-ref (step-live-bot-runtime! rt36-pf (mk-p-gw-obs 550)) 'actions '()))
    (define gw-act36-pf1 (findf (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'gateway))) acts36-pf1))
    (assert-true! (and gw-act36-pf1
                       (< (abs (- (third gw-act36-pf1) 40.5)) 0.1)
                       (< (abs (- (fourth gw-act36-pf1) 30.5)) 0.1))
                  "Step 1 must try exact wall-slot-1 (40.5, 30.5) for 1st Gateway")
    (clear-oledger36! (live-bot-runtime-order-ledger rt36-pf))
    (define acts36-pf2 (hash-ref (step-live-bot-runtime! rt36-pf (mk-p-gw-obs 551 #:power-fail? #t)) 'actions '()))
    (define gw-act36-pf2 (findf (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'gateway))) acts36-pf2))
    (assert-true! (and gw-act36-pf2
                       (>= (+ (abs (- (third gw-act36-pf2) 40.5))
                              (abs (- (fourth gw-act36-pf2) 30.5)))
                           1.0)
                       (<= (sqrt (+ (sqr (- (third gw-act36-pf2) 43.0))
                                    (sqr (- (fourth gw-act36-pf2) 32.5))))
                           6.2))
                  "power-placement-failed? #t must clear 56f lock and immediately retry Gateway in Pylon power field")

    (define rt36-16f (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
    (void (step-live-bot-runtime! rt36-16f (mk-p-gw-obs 550)))
    (clear-oledger36! (live-bot-runtime-order-ledger rt36-16f))
    (define acts36-16f (hash-ref (step-live-bot-runtime! rt36-16f (mk-p-gw-obs 566 #:power-fail? #f)) 'actions '()))
    (define gw-act36-16f (findf (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'gateway))) acts36-16f))
    (assert-true! (and gw-act36-16f
                       (>= (+ (abs (- (third gw-act36-16f) 40.5))
                              (abs (- (fourth gw-act36-16f) 30.5)))
                           1.0)
                       (<= (sqrt (+ (sqr (- (third gw-act36-16f) 43.0))
                                    (sqr (- (fourth gw-act36-16f) 32.5))))
                           6.2))
                  "No active Gateway build order in oledger after 16 frames must clear 56f lock and retry in Pylon power field")

    ;; 36.3 first-ready-pylon alignment under worker-rush-active? when frame > 500
    (define rt36-rush (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
    (define acts36-rush
      (hash-ref (step-live-bot-runtime! rt36-rush (mk-p-gw-obs 550 #:pylon-x 42.5 #:pylon-y 32.5 #:enemy-probes 6))
                'actions '()))
    (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'gateway))) acts36-rush)
                  "Under worker-rush-active? at frame > 500, any ready Pylon (> 7.5 tiles) must allow placing 1st Gateway")

    ;; 36.4 Earlier 1st Pylon (supply-used >= 13 or minerals >= 100 at frame < 3000)
    (define rt36-py13 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
    (define acts36-py13
      (hash-ref (step-live-bot-runtime!
                 rt36-py13
                 (hash 'frame 300 'minerals 105 'gas 0 'supply-used 13 'supply-cap 15 'supply-left 2
                       'mineral-harvesters 13 'vespene-harvesters 0 'enemy-race 'Protoss
                       'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5
                       'ally-units (for/list ([i (in-range 13)])
                                     (hash 'id (+ 20300 i) 'type 'probe 'x 30.0 'y 32.5 'hp 20 'shield 20))
                       'ally-buildings (list (hash 'id 20381 'type 'nexus 'x 32.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0))
                       'enemy-units '()))
                'actions '()))
    (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (second a) 'pylon))) acts36-py13)
                  "Protoss emergency Pylon must trigger at supply-used >= 13 / minerals >= 100 (< frame 3000)"))
(run-suite
 "38. Wave 6 Track 3: Protoss Robo Prerequisite Escrow, Surcharge Exemption & Gas Reserve"
   ;; 36.1 Unbuilt-prerequisite resolution:
   ;;      At supply-used=34 with 0 robotics-facility, evaluate-build-order-next-step and step-priority-macro-brain
   ;;      must resolve saving_for / bo-goal to 'robotics-facility (never 'immortal) and escrow 150M/100G.
   (define bo-eval-robo
     (evaluate-build-order-next-step
      #:race 'Protoss
      #:enemy-race 'Protoss
      #:frame 3600
      #:minerals 100
      #:gas 50
      #:supply-used 34
      #:supply-left 12
      #:active-bases 2
      #:ready-building-counts (hash 'nexus 2 'pylon 2 'gateway 2 'assimilator 2 'cybernetics-core 1)
      #:total-building-counts (hash 'nexus 2 'pylon 2 'gateway 2 'assimilator 2 'cybernetics-core 1)
      #:unit-counts (hash 'probe 22 'stalker 2 'sentry 1)
      #:researched-upgrades '(warp-gate-research)))
   (define bo-goal-robo (pro-bo-eval-result-active-goal bo-eval-robo))
   (assert-true! (and (pro-bo-goal? bo-goal-robo)
                      (eq? (pro-bo-goal-target-sym bo-goal-robo) 'robotics-facility))
                 "evaluate-build-order-next-step must resolve to robotics-facility when 0 robo built at 34 supply")
   (assert-true! (not (and (pro-bo-goal? bo-goal-robo)
                           (eq? (pro-bo-goal-target-sym bo-goal-robo) 'immortal)))
                 "evaluate-build-order-next-step must never select immortal when robotics-facility == 0")

   ;; 36.2 tech-under-attack-escrow-ok? exempts 1st robotics-facility when cybernetics-core is ready and workers >= 20
   (define p-robo-under-attack-state
     (make-macro-world-state
      #:race 'Protoss
      #:enemy-race 'Protoss
      #:frame 3600
      #:minerals 110
      #:gas 60
      #:supply-used 34
      #:supply-cap 46
      #:supply-left 12
      #:workers 22
      #:mineral-harvesters 16
      #:gas-harvesters 6
      #:army-supply 8
      #:active-bases 2
      #:under-attack? #t
      #:enemy-threat-supply 6
      #:open-facility-slots (hash 'gateway 0)
      #:ready-building-counts (hash 'nexus 2 'pylon 2 'gateway 2 'assimilator 2 'cybernetics-core 1)
      #:total-building-counts (hash 'nexus 2 'pylon 2 'gateway 2 'assimilator 2 'cybernetics-core 1)
      #:unit-counts (hash 'probe 22 'stalker 3 'sentry 1 'zealot 1)
      #:researched-upgrades '(warp-gate-research)))
   (define p-robo-dec (step-priority-macro-brain p-robo-under-attack-state))
   (assert-eq! (macro-brain-decision-saving-for p-robo-dec) 'robotics-facility
               "1st robotics-facility must be escrowed under attack when cybernetics-core is ready and workers >= 20")
   (assert-true! (>= (macro-brain-decision-reserved-gas-floor p-robo-dec) 100)
                 "1st robotics-facility escrow under attack must reserve >= 100G")
   (assert-true! (not (eq? (macro-brain-decision-saving-for p-robo-dec) 'immortal))
                 "saving_for must never be immortal when robotics-facility == 0")

   ;; 36.3 Pending Robo 100G reserve blocks Stalker gas drain when supply >= 34, cyber ready, ally-combat-units >= 4
   (define rt-robo-reserve (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
   (define acts-robo-reserve
     (hash-ref (step-live-bot-runtime!
                rt-robo-reserve
                (hash 'frame 3600 'minerals 140 'gas 75 'supply-used 34 'supply-cap 46 'supply-left 12
                      'mineral-harvesters 16 'vespene-harvesters 6 'enemy-race 'Protoss
                      'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5
                      'ally-units (list (hash 'id 20101 'type 'probe 'x 27.5 'y 32.5 'hp 20 'shield 20)
                                        (hash 'id 20102 'type 'stalker 'x 40.0 'y 32.5 'hp 80 'shield 80)
                                        (hash 'id 20103 'type 'stalker 'x 41.0 'y 32.5 'hp 80 'shield 80)
                                        (hash 'id 20104 'type 'zealot 'x 42.0 'y 32.5 'hp 100 'shield 50)
                                        (hash 'id 20105 'type 'zealot 'x 43.0 'y 32.5 'hp 100 'shield 50))
                      'ally-buildings (list (hash 'id 20201 'type 'nexus 'x 32.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                            (hash 'id 20202 'type 'nexus 'x 58.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                            (hash 'id 20203 'type 'pylon 'x 36.0 'y 35.0 'hp 200 'shield 200 'build-progress 1.0 'is-powered #t)
                                            (hash 'id 20204 'type 'gateway 'x 38.0 'y 35.0 'hp 500 'shield 500 'build-progress 1.0 'is-powered #t)
                                            (hash 'id 20205 'type 'cybernetics-core 'x 35.0 'y 38.0 'hp 550 'shield 550 'build-progress 1.0 'is-powered #t)
                                            (hash 'id 20206 'type 'assimilator 'x 29.0 'y 38.0 'hp 450 'shield 450 'build-progress 1.0)
                                            (hash 'id 20207 'type 'assimilator 'x 36.0 'y 27.0 'hp 450 'shield 450 'build-progress 1.0))
                      'enemy-units (list (hash 'id 20301 'type 'stalker 'x 75.0 'y 75.0 'hp 80 'shield 80))))
               'actions '()))
   (assert-true! (not (ormap (lambda (a) (equal? a '(train stalker))) acts-robo-reserve))
                 "At 140M/75G with 0 robo, cyber ready, supply >= 34, 4 combat units, Stalker must NOT drain gas needed for Robo")

   ;; 36.4 1st robotics-facility surcharge exemption & aa-stargate-gas-ok? exemption when no enemy air threat is present
   (define rt-robo-build (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
   (define acts-robo-build
     (hash-ref (step-live-bot-runtime!
                rt-robo-build
                (hash 'frame 3600 'minerals 275 'gas 105 'supply-used 34 'supply-cap 54 'supply-left 20
                      'mineral-harvesters 16 'vespene-harvesters 6 'enemy-race 'Protoss
                      'researched-upgrades '(warp-gate-research)
                      'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5
                      'ally-units (list (hash 'id 20401 'type 'probe 'x 27.5 'y 32.5 'hp 20 'shield 20)
                                        (hash 'id 20402 'type 'stalker 'x 40.0 'y 32.5 'hp 80 'shield 80)
                                        (hash 'id 20403 'type 'stalker 'x 41.0 'y 32.5 'hp 80 'shield 80)
                                        (hash 'id 20404 'type 'zealot 'x 42.0 'y 32.5 'hp 100 'shield 50)
                                        (hash 'id 20405 'type 'zealot 'x 43.0 'y 32.5 'hp 100 'shield 50))
                      'ally-buildings (list (hash 'id 20501 'type 'nexus 'x 32.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                            (hash 'id 20502 'type 'nexus 'x 58.5 'y 32.5 'hp 1000 'shield 1000 'build-progress 1.0)
                                            (hash 'id 20503 'type 'pylon 'x 36.0 'y 35.0 'hp 200 'shield 200 'build-progress 1.0 'is-powered #t)
                                            (hash 'id 20509 'type 'pylon 'x 55.0 'y 35.0 'hp 200 'shield 200 'build-progress 1.0 'is-powered #t)
                                            (hash 'id 20512 'type 'pylon 'x 52.0 'y 38.0 'hp 200 'shield 200 'build-progress 1.0 'is-powered #t)
                                            (hash 'id 20504 'type 'gateway 'x 38.0 'y 35.0 'hp 500 'shield 500 'build-progress 1.0 'is-powered #t)
                                            (hash 'id 20510 'type 'gateway 'x 41.0 'y 35.0 'hp 500 'shield 500 'build-progress 1.0 'is-powered #t)
                                            (hash 'id 20505 'type 'cybernetics-core 'x 35.0 'y 38.0 'hp 550 'shield 550 'build-progress 1.0 'is-powered #t)
                                            (hash 'id 20506 'type 'stargate 'x 35.0 'y 42.0 'hp 600 'shield 600 'build-progress 1.0 'is-powered #t)
                                            (hash 'id 20511 'type 'shield-battery 'x 55.0 'y 32.5 'hp 200 'shield 200 'build-progress 1.0 'is-powered #t)
                                            (hash 'id 20507 'type 'assimilator 'x 29.0 'y 38.0 'hp 450 'shield 450 'build-progress 1.0)
                                            (hash 'id 20508 'type 'assimilator 'x 36.0 'y 27.0 'hp 450 'shield 450 'build-progress 1.0))
                      'enemy-units (list (hash 'id 20601 'type 'zealot 'x 35.0 'y 34.0 'hp 100 'shield 50))))
               'actions '()))
   (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'build) (eq? (cadr a) 'robotics-facility)))
                        acts-robo-build)
                 "1st robotics-facility at 165M/105G, supply=34 must build without 275M/150G surcharge or stargate AA gas block"))
  ;; =========================================================================
  ;; SUITE 36: Wave 6 Track 4 - Zerg 35-Drone Cap, Supply Blocks & Mothman-R Cleanup
  ;; =========================================================================
  (run-suite "39. Wave 6 Track 4: Zerg Drone Saturation, Pending Overlord Discount & Mothman-R Cleanup"
    ;; 36.1 Smoothed worker-growth curve & worker utility floor under passive threat
    (assert-true! (<= (required-army-supply-for-worker-growth 35 0.0) 8.0)
                  "At 35 workers in peace, required-army-supply-for-worker-growth must not cliff-jump to 14.0")
    (define pm-z-passive
      (compute-state-pressure-metrics
       #:race 'Zerg #:frame 5400 #:minerals 120 #:gas 40
       #:supply-left 14 #:supply-cap 62 #:pending-supply 0
       #:workers 35 #:target-workers 66 #:active-bases 4 #:desired-bases 4
       #:production-facilities 4 #:max-facilities 8
       #:army-supply 8.0 #:enemy-threat-supply 6.0 #:under-attack? #f))
    (define c-z-drone-u
      (compute-candidate-marginal-utility
       (priority-candidate 'drone 'worker '(train drone) 50 0 1 0.0 'normal #f)
       pm-z-passive))
    (assert-true! (>= c-z-drone-u 60.0)
                  (format "Zerg worker utility on 4 bases at 35 Drones with passive threat must stay >= 60.0 (got ~a)"
                          c-z-drone-u))

    ;; 36.2 4-Hatchery Zerg at 35 Drones, 4 Queens, passive Marines across map -> trains Drone (not 5th Queen / stall)
    (define rt-z35 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
    (define res-z35
      (step-live-bot-runtime!
       rt-z35
       (hash 'frame 5600 'minerals 200 'gas 40 'supply-used 48 'supply-cap 66 'supply-left 18
             'mineral-harvesters 31 'vespene-harvesters 4 'enemy-race 'Terran
             'researched-upgrades '(metabolic-boost zergling-movementspeed)
             'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5
             'ally-units (append (for/list ([i (in-range 35)])
                                   (hash 'id (+ 21100 i) 'type 'drone 'x 32.5 'y 32.5 'hp 40))
                                 (for/list ([q (in-range 4)])
                                   (hash 'id (+ 21200 q) 'type 'queen 'x (+ 32.5 (* 10 q)) 'y 32.5 'hp 175 'energy 10))
                                 (for/list ([ov (in-range 5)])
                                   (hash 'id (+ 21250 ov) 'type 'overlord 'x 34.0 'y 34.0 'hp 200))
                                 (list (hash 'id 21260 'type 'overseer 'x 34.0 'y 34.0 'hp 200))
                                 (for/list ([z (in-range 8)])
                                   (hash 'id (+ 21300 z) 'type 'zergling 'x 50.0 'y 32.5 'hp 35))
                                 (list (hash 'id 21401 'type 'roach 'x 51.0 'y 32.5 'hp 145)
                                       (hash 'id 21402 'type 'roach 'x 52.0 'y 32.5 'hp 145)
                                       (hash 'id 21501 'type 'larva 'x 33.0 'y 31.0 'hp 25)
                                       (hash 'id 21502 'type 'larva 'x 33.5 'y 31.0 'hp 25)))
             'ally-buildings (list (hash 'id 21001 'type 'lair 'x 32.5 'y 32.5 'hp 2000 'build-progress 1.0)
                                   (hash 'id 21002 'type 'hatchery 'x 58.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                   (hash 'id 21003 'type 'hatchery 'x 84.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                   (hash 'id 21004 'type 'hatchery 'x 32.5 'y 62.5 'hp 1500 'build-progress 1.0)
                                   (hash 'id 21005 'type 'spawning-pool 'x 36.5 'y 32.5 'hp 1000 'build-progress 1.0)
                                   (hash 'id 21006 'type 'roach-warren 'x 40.5 'y 32.5 'hp 850 'build-progress 1.0)
                                   (hash 'id 21007 'type 'extractor 'x 29.5 'y 35.5 'hp 500 'build-progress 1.0 'vespene-contents 1200)
                                   (hash 'id 21008 'type 'extractor 'x 29.5 'y 29.5 'hp 500 'build-progress 1.0 'vespene-contents 1200)
                                   (hash 'id 21009 'type 'extractor 'x 55.5 'y 35.5 'hp 500 'build-progress 1.0 'vespene-contents 1200)
                                   (hash 'id 21010 'type 'baneling-nest 'x 40.5 'y 36.5 'hp 850 'build-progress 1.0)
                                   (hash 'id 21011 'type 'evolution-chamber 'x 36.5 'y 28.5 'hp 750 'build-progress 1.0))
             'enemy-units (for/list ([m (in-range 6)])
                            (hash 'id (+ 21900 m) 'type 'marine 'x 130.0 'y 130.0 'hp 45)))))
    (define acts-z35 (hash-ref res-z35 'actions '()))
    (assert-true! (member '(train drone) acts-z35)
                  "4-Hatchery Zerg at 35 Drones, 4 Queens & passive enemy threat must continue training Drones")
    (assert-true! (not (member '(train queen) acts-z35))
                  "4-Hatchery Zerg with 4 Queens & 35 Drones must defer 5th Queen below Drone saturation")

    ;; 36.3 Discounted pending Overlords & 2nd Overlord emission on >= 3 Hatcheries
    (define pm-z-ov
      (compute-state-pressure-metrics
       #:race 'Zerg #:frame 5800 #:minerals 150 #:gas 40
       #:supply-left 4 #:supply-cap 54 #:pending-supply 1
       #:workers 38 #:target-workers 66 #:active-bases 4 #:desired-bases 4
       #:production-facilities 4 #:max-facilities 8
       #:army-supply 12.0 #:enemy-threat-supply 0.0 #:under-attack? #f
       #:supply-buffer 10.0))
    (assert-true! (> (hash-ref pm-z-ov 'supply-hazard 0.0) 0.0)
                  "On 4 Hatcheries with supply-left=4 and pending-supply=1, Zerg supply-hazard must stay > 0.0")
    (define rt-z-ov2 (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg))
    (define acts-z-ov2
      (hash-ref (step-live-bot-runtime!
                 rt-z-ov2
                 (hash 'frame 5800 'minerals 150 'gas 40 'supply-used 50 'supply-cap 54 'supply-left 4
                       'pending-supply 1
                       'mineral-harvesters 34 'vespene-harvesters 4 'enemy-race 'Terran
                       'base-x 32.5 'base-y 32.5 'natural-x 58.5 'natural-y 32.5
                       'ally-units (append (for/list ([i (in-range 38)])
                                             (hash 'id (+ 22100 i) 'type 'drone 'x 32.5 'y 32.5 'hp 40))
                                           (for/list ([q (in-range 4)])
                                             (hash 'id (+ 22200 q) 'type 'queen 'x 32.5 'y 32.5 'hp 175))
                                           (list (hash 'id 22301 'type 'overlord 'x 34.0 'y 34.0 'hp 200)
                                                 (hash 'id 22302 'type 'larva 'x 33.0 'y 31.0 'hp 25)))
                       'ally-buildings (list (hash 'id 22001 'type 'lair 'x 32.5 'y 32.5 'hp 2000 'build-progress 1.0)
                                             (hash 'id 22002 'type 'hatchery 'x 58.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                             (hash 'id 22003 'type 'hatchery 'x 84.5 'y 32.5 'hp 1500 'build-progress 1.0)
                                             (hash 'id 22004 'type 'hatchery 'x 32.5 'y 62.5 'hp 1500 'build-progress 1.0)
                                             (hash 'id 22005 'type 'spawning-pool 'x 36.5 'y 32.5 'hp 1000 'build-progress 1.0))
                       'enemy-units '()))
                'actions '()))
    (assert-true! (member '(train overlord) acts-z-ov2)
                  "4-Hatchery Zerg at supply-left=4 with 1 pending Overlord must queue a 2nd Overlord")

    ;; 36.4 Retired legacy Mothman / Mothman-R build variants
    (define variant-names (map first VARIANTS))
    (assert-true! (and (not (member "Mothman" variant-names))
                       (not (member "Mothman-R" variant-names))
                       (equal? variant-names '("Mothman-X" "Mothman-Z" "Mothman-T" "Mothman-P")))
                  (format "VARIANTS must exclude retired Mothman and Mothman-R (got ~a)" variant-names)))

;; =============================================================================
;; Suite 40: Terran Depot Front-Door, Protoss Wall Door-Guard & Framing Camera
;; =============================================================================
(run-suite "40. Terran Supply Depot Door, Protoss HoldPosition Door-Guard & Framing Camera"
  (define (s40-dist x1 y1 x2 y2)
    (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))
  (define (mk-s40-unit tag utype x y
                       #:alliance [alliance 1]
                       #:radius [radius 0.5]
                       #:hp [hp 45.0]
                       #:hp-max [hp-max 45.0]
                       #:flying? [flying? #f]
                       #:orders [orders '()])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 2)
              (sc2-point3d x y 8.0) 0.0 radius 1.0 0 #f #f #f
              hp hp-max 0.0 0.0 0.0 0.0 0 0
              flying? #f #f #t #t orders 0 '()
              0 0 0.0 0 0 0 0))
  (define (mk-s40-obs loop units #:cam [cam #f])
    (sc2-observation loop
                     (sc2-player-common 1 200 100 38 24 10 14 0 5 0 3)
                     units
                     '() '() cam '() '() '() '() '() '()))

  ;; 40.1 Terran Supply Depot Front-Door Management (1A)
  (assert-eq! (wire-cmd-priority-tier (sc2-raw-unit-command 556 #f 0 '(4201) #f)) 0
              "Supply Depot Lower (556) must be Tier 0 (P0) alongside Raise (558)")
  (assert-eq! (wire-cmd-priority-tier (sc2-raw-unit-command 558 #f 0 '(4201) #f)) 0
              "Supply Depot Raise (558) must be Tier 0 (P0)")

  ;; Reset wire state with low loop=2: enemy at 8.0 tiles (> 5.5) + friendly unit <= 3.5 requesting transit -> lower (556)
  (define dep-lower-units
    (list (mk-s40-unit 4201 19 35.0 46.0 #:radius 1.25 #:hp 400.0 #:hp-max 400.0)
          (mk-s40-unit 4210 48 33.0 46.0
                       #:orders (list (sc2-unit-order 16 (sc2-point3d 45.0 46.0 8.0) 0 0.0)))
          (mk-s40-unit 9210 105 43.0 46.0 #:alliance 4 #:hp 35.0 #:hp-max 35.0)))
  (assert-true! (friendly-unit-requesting-depot-transit? 35.0 46.0 dep-lower-units)
                "Moving Marine within 3.5 tiles of depot must register as requesting depot transit")
  (define cmds-40-lower
    (translate-bot-actions->sc2-raw-commands '() (mk-s40-obs 2 dep-lower-units)))
  (assert-true! (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 556)))
                       cmds-40-lower)
                "Raised depot (19) with enemy at 8.0 tiles (> 5.5) and transiting friendly unit <= 3.5 must emit Lower (556)")

  ;; Lowered depot refuses to Raise (558) while a friendly ground unit stands on 2x2 footprint (max(|dx|,|dy|) <= 1.3)
  (define dep-block-units
    (list (mk-s40-unit 4202 47 35.0 46.0 #:radius 1.25 #:hp 400.0 #:hp-max 400.0)
          (mk-s40-unit 4211 45 36.2 47.2)
          (mk-s40-unit 9211 105 39.0 46.0 #:alliance 4 #:hp 35.0 #:hp-max 35.0)))
  (assert-true! (friendly-unit-on-depot-footprint? 35.0 46.0 dep-block-units)
                "SCV at (36.2, 47.2) relative to depot (35.0, 46.0) must be detected on depot footprint")
  (define cmds-40-blocked
    (translate-bot-actions->sc2-raw-commands '() (mk-s40-obs 42 dep-block-units)))
  (assert-true! (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 558)))
                            cmds-40-blocked))
                "Lowered depot (47) must refuse to Raise (558) while a friendly ground unit stands on footprint")

  ;; Once footprint clears and enemy is at 4.0 tiles (<= 5.5), emergency Raise (558) fires immediately
  (define dep-clear-units
    (list (mk-s40-unit 4202 47 35.0 46.0 #:radius 1.25 #:hp 400.0 #:hp-max 400.0)
          (mk-s40-unit 4211 45 30.0 46.0)
          (mk-s40-unit 9211 105 39.0 46.0 #:alliance 4 #:hp 35.0 #:hp-max 35.0)))
  (define cmds-40-clear-raise
    (translate-bot-actions->sc2-raw-commands '() (mk-s40-obs 43 dep-clear-units)))
  (assert-true! (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 558)))
                       cmds-40-clear-raise)
                "Lowered depot (47) must Raise (558) once friendly unit clears footprint and enemy <= 5.5")

  ;; Terran rt-door-state tracking & unstick move after >= 2 stuck steps
  (define rt-t40 (make-live-bot-runtime #:bot-name 'Mothman-T #:race 'Terran))
  (define (terran-door-obs fr depot-type marine-order-ab)
    (hash 'frame fr 'minerals 100 'gas 0 'supply-used 20 'supply-cap 23 'supply-left 3
          'mineral-harvesters 16 'gas-harvesters 0 'enemy-race 'Zerg
          'base-x 24.5 'base-y 48.5 'natural-x 52.5 'natural-y 48.5
          'ally-units (list (hash 'id 4221 'type 'marine 'x 33.0 'y 46.0 'hp 45 'order-ability-id marine-order-ab 'order-count (if (= marine-order-ab 0) 0 1)))
          'ally-buildings (list (hash 'id 4200 'type 'command-center 'x 24.5 'y 48.5 'hp 1500 'build-progress 1.0)
                                (hash 'id 4220 'type depot-type 'x 35.0 'y 46.0 'hp 400 'build-progress 1.0))
          'enemy-units '()))
  (void (step-live-bot-runtime! rt-t40 (terran-door-obs 1000 'supply-depot 16)))
  (define res-t40-2 (step-live-bot-runtime! rt-t40 (terran-door-obs 1008 'supply-depot 16)))
  (assert-eq! (hash-ref (rt-door-state rt-t40) 'state #f) 'closed
              "Terran raised front depot with stuck Marine must track rt-door-state = 'closed")
  (assert-true! (and (member 4221 (hash-ref (rt-door-state rt-t40) 'transiting-tags '()))
                     (ormap (lambda (a) (and (pair? a) (eq? (car a) 'move) (equal? (second a) 4221)))
                            (hash-ref res-t40-2 'actions '())))
                "Terran Marine stuck <= 3.5 tiles near raised depot for >= 2 steps must get unstick move")
  (void (step-live-bot-runtime! rt-t40 (terran-door-obs 1016 'supply-depot-lowered 0)))
  (assert-eq! (hash-ref (rt-door-state rt-t40) 'state #f) 'open
              "Terran lowered front depot with no stuck units must track rt-door-state = 'open")

  ;; 40.2 Protoss HoldPosition Wall Door-Guard Management (1B)
  (define r40w 96)
  (define r40h 96)
  (define r40-path (make-bytes (* r40w r40h) 0))
  (define r40-plac (make-bytes (* r40w r40h) 0))
  (define r40-hgt  (make-bytes (* r40w r40h) 112))
  (for* ([ix (in-range 10 91)]
         [iy (in-range 28 69)])
    (cond
      [(<= ix 35)
       (bytes-set! r40-path (+ ix (* iy r40w)) 1)
       (bytes-set! r40-plac (+ ix (* iy r40w)) 1)
       (bytes-set! r40-hgt  (+ ix (* iy r40w)) 144)]
      [(<= ix 38)
       (bytes-set! r40-hgt (+ ix (* iy r40w)) 128)
       (when (and (>= iy 46) (<= iy 50))
         (bytes-set! r40-path (+ ix (* iy r40w)) 1))]
      [(<= ix 59)
       (bytes-set! r40-path (+ ix (* iy r40w)) 1)
       (bytes-set! r40-plac (+ ix (* iy r40w)) 1)
       (bytes-set! r40-hgt  (+ ix (* iy r40w)) 112)]
      [(<= ix 62)
       (bytes-set! r40-hgt (+ ix (* iy r40w)) 112)
       (when (and (>= iy 45) (<= iy 51))
         (bytes-set! r40-path (+ ix (* iy r40w)) 1)
         (bytes-set! r40-plac (+ ix (* iy r40w)) 1))]
      [else
       (bytes-set! r40-path (+ ix (* iy r40w)) 1)
       (bytes-set! r40-plac (+ ix (* iy r40w)) 1)
       (bytes-set! r40-hgt  (+ ix (* iy r40w)) 112)]))
  (define r40-grids
    (hash 'width r40w 'height r40h
          'pathing-ref (lambda (ix iy) (bytes-ref r40-path (+ ix (* iy r40w))))
          'placement-ref (lambda (ix iy) (bytes-ref r40-plac (+ ix (* iy r40w))))
          'height-ref (lambda (ix iy) (bytes-ref r40-hgt (+ ix (* iy r40w))))))
  (define pw40 (solve-protoss-matchup-wall 24.5 48.5 52.5 48.5 'Zerg
                                           #:map-grids r40-grids #:enemy-x 84.5 #:enemy-y 48.5))
  (define d40-pt (hash-ref pw40 'door))
  (define p40-pt (hash-ref pw40 'door-park))
  (define pw40-bldgs
    (list (hash 'id 4501 'type 'nexus 'x 24.5 'y 48.5 'hp 2000 'build-progress 1.0 'powered? #f)
          (hash 'id 4502 'type 'nexus 'x 52.5 'y 48.5 'hp 2000 'build-progress 1.0 'powered? #f)
          (hash 'id 4503 'type 'pylon 'x (car (hash-ref pw40 'pylon)) 'y (cdr (hash-ref pw40 'pylon)) 'hp 400 'build-progress 1.0 'powered? #f)
          (hash 'id 4504 'type 'gateway 'x (car (hash-ref pw40 'slot-1)) 'y (cdr (hash-ref pw40 'slot-1)) 'hp 1000 'build-progress 1.0 'powered? #t)
          (hash 'id 4505 'type 'cybernetics-core 'x (car (hash-ref pw40 'slot-2)) 'y (cdr (hash-ref pw40 'slot-2)) 'hp 1100 'build-progress 1.0 'powered? #t)))
  (define rt-p40 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define (protoss-door-obs fr units enemies)
    (hash 'frame fr 'minerals 50 'gas 50 'supply-used 28 'supply-cap 38 'supply-left 10
          'mineral-harvesters 20 'gas-harvesters 3 'enemy-race 'Zerg
          'map-grids r40-grids
          'base-x 24.5 'base-y 48.5 'natural-x 52.5 'natural-y 48.5 'enemy-x 84.5 'enemy-y 48.5
          'ally-units units 'ally-buildings pw40-bldgs 'enemy-units enemies))

  ;; 1 trapped idle combat unit on main side + enemy at 9.0 tiles (> 6.5) -> open, park, and nudge trapped unit
  (define res-p40-army
    (step-live-bot-runtime!
     rt-p40
     (protoss-door-obs
      2200
      (list (hash 'id 4601 'type 'probe 'x 23.0 'y 48.5 'hp 40)
            (hash 'id 4610 'type 'zealot 'x (car d40-pt) 'y (cdr d40-pt) 'hp 100 'shield 50 'order-ability-id 18)
            (hash 'id 4620 'type 'stalker 'x (- (car d40-pt) 2.2) 'y (cdr d40-pt) 'hp 80 'shield 80 'order-count 0 'order-ability-id 0))
      (list (hash 'id 9401 'type 'zergling 'x (+ (car d40-pt) 9.0) 'y (cdr d40-pt) 'hp 35)))))
  (assert-eq! (hash-ref (rt-door-state rt-p40) 'state #f) 'open
              "Protoss door guard must open ('open) for 1 trapped/transiting combat unit when enemy > 6.5 tiles")
  (assert-true! (ormap (lambda (a)
                         (and (pair? a) (eq? (car a) 'move) (equal? (second a) 4610)
                              (<= (s40-dist (third a) (fourth a) (car p40-pt) (cdr p40-pt)) 0.5)))
                       (hash-ref res-p40-army 'actions '()))
                "Protoss door guard Zealot (#4610) must move to (park-x, park-y) when 1 combat unit needs transit")
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'move) (equal? (second a) 4620)))
                       (hash-ref res-p40-army 'actions '()))
                "Trapped idle Stalker (#4620) within 3.2 tiles of closed door must be nudged across doorway")

  ;; Re-seal immediately once cleared
  (define res-p40-clear
    (step-live-bot-runtime!
     rt-p40
     (protoss-door-obs
      2216
      (list (hash 'id 4601 'type 'probe 'x 23.0 'y 48.5 'hp 40)
            (hash 'id 4610 'type 'zealot 'x (car p40-pt) 'y (cdr p40-pt) 'hp 100 'shield 50 'order-ability-id 0))
      '())))
  (assert-eq! (hash-ref (rt-door-state rt-p40) 'state #f) 'closed
              "Protoss door guard must re-seal ('closed) immediately once doorway clears")
  (assert-true! (ormap (lambda (a)
                         (and (pair? a) (eq? (car a) 'hold-position) (equal? (second a) 4610)))
                       (hash-ref res-p40-clear 'actions '()))
                "Protoss door guard Zealot (#4610) must re-seal with (hold-position gid door-x door-y)")

  ;; Scout probe requesting transit (> 6.5 enemy dist) opens door; enemy <= 6.5 forces immediate re-seal
  (hash-set! (rt-scout-state rt-p40) 'scout-id 4601)
  (define res-p40-scout
    (step-live-bot-runtime!
     rt-p40
     (protoss-door-obs
      2224
      (list (hash 'id 4601 'type 'probe 'x (+ (car d40-pt) 1.5) 'y (cdr d40-pt) 'hp 40)
            (hash 'id 4610 'type 'zealot 'x (car d40-pt) 'y (cdr d40-pt) 'hp 100 'shield 50 'order-ability-id 18))
      (list (hash 'id 9402 'type 'zergling 'x (+ (car d40-pt) 8.5) 'y (cdr d40-pt) 'hp 35)))))
  (assert-eq! (hash-ref (rt-door-state rt-p40) 'state #f) 'open
              "Protoss door guard must open ('open) for transiting scout Probe when enemy > 6.5 tiles")
  (define res-p40-danger
    (step-live-bot-runtime!
     rt-p40
     (protoss-door-obs
      2232
      (list (hash 'id 4601 'type 'probe 'x (+ (car d40-pt) 1.5) 'y (cdr d40-pt) 'hp 40)
            (hash 'id 4610 'type 'zealot 'x (car p40-pt) 'y (cdr p40-pt) 'hp 100 'shield 50 'order-ability-id 0))
      (list (hash 'id 9402 'type 'zergling 'x (+ (car d40-pt) 5.5) 'y (cdr d40-pt) 'hp 35)))))
  (assert-eq! (hash-ref (rt-door-state rt-p40) 'state #f) 'closed
              "Protoss door guard must force re-seal ('closed) when enemy closes to <= 6.5 tiles")
  (assert-true! (ormap (lambda (a) (and (pair? a) (eq? (car a) 'hold-position) (equal? (second a) 4610)))
                       (hash-ref res-p40-danger 'actions '()))
                "Protoss door guard Zealot (#4610) must emit (hold-position) immediately when enemy <= 6.5 tiles")

  ;; 40.3 Camera Management on Un-Control-Grouped Units (1C)
  (define rt-c40 (make-live-bot-runtime #:bot-name 'Mothman-P #:race 'Protoss))
  (define ctx-c40 (live-bot-runtime-cortex rt-c40))
  (cortex-set-control-group! ctx-c40 1 '(701))
  (cortex-move-camera! ctx-c40 32.5 32.5)
  (define c40-units
    (list (hash 'id 701 'type 'zealot 'x 34.0 'y 34.0 'hp 100)
          (hash 'id 702 'type 'probe 'x 120.0 'y 118.0 'hp 40)))
  (define c40-pos-map (hasheqv 701 '(34.0 . 34.0) 702 '(120.0 . 118.0)))
  (assert-eq! (action-requires-camera-focus '(attack-pos 701 36.0 36.0) (seteqv 701) c40-pos-map 32.5 32.5)
              #f
              "Command to control-grouped unit (#701) must NOT force camera focus switch")
  (assert-eq! (action-requires-camera-focus '(move 702 124.0 120.0) (seteqv 701) c40-pos-map 32.5 32.5)
              '(120.0 . 118.0)
              "Command to un-control-grouped unit (#702) must return unit focus coords for camera framing")
  (define-values (c40-mixed-sel _c40-realized)
    (compile-optimal-unit-selection! ctx-c40 '(701 702) c40-units '()))
  (assert-true! (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'control-group-recall))) c40-mixed-sel))
                "compile-optimal-unit-selection! must NOT emit control-group-recall when desired list contains ungrouped unit #702")
  (define-values (c40-accepted _c40-drop _c40-sthr)
    (step-layer5-human-cortex!
     rt-c40
     '((move 702 124.0 120.0))
     (hash 'frame 400 'base-x 32.5 'base-y 32.5 'natural-x 52.5 'natural-y 32.5
           'ally-units c40-units 'ally-buildings '() 'enemy-units '())))
  (define c40-cam-idx
    (index-where c40-accepted (lambda (a) (and (pair? a) (eq? (car a) 'move-camera)))))
  (define c40-mov-idx
    (index-where c40-accepted (lambda (a) (and (pair? a) (eq? (car a) 'move) (equal? (second a) 702)))))
  (assert-true! (and c40-cam-idx c40-mov-idx (< c40-cam-idx c40-mov-idx))
                "step-layer5-human-cortex! must emit (move-camera ...) BEFORE ungrouped (move 702 ...) outside viewport")

  ;; Wire translator + governor framing camera move, Tier 1 preservation, and 6-loop large jump cooldown
  (define obs-c40-wire
    (mk-s40-obs 2
                (list (mk-s40-unit 8001 59 32.5 32.5 #:radius 2.75 #:hp 1500.0 #:hp-max 1500.0)
                      (mk-s40-unit 8101 73 95.0 95.0 #:hp 100.0 #:hp-max 100.0)
                      (mk-s40-unit 8102 73 98.0 95.0 #:hp 100.0 #:hp-max 100.0))
                #:cam (sc2-point3d 32.5 32.5 0.0)))
  (define cmds-c40-wire
    (translate-bot-actions->sc2-raw-commands
     '((control-group-set 1 (8102))
       (attack-pos 8101 98.0 98.0))
     obs-c40-wire))
  (define cam-idx-w
    (index-where cmds-c40-wire
                 (lambda (c) (and (framing-camera-cmd? c)
                                  (<= (s40-dist (sc2-raw-camera-move-x c) (sc2-raw-camera-move-y c) 95.0 95.0) 1.0)))))
  (define atk-idx-w
    (index-where cmds-c40-wire
                 (lambda (c) (and (sc2-raw-unit-command? c)
                                  (= (sc2-raw-unit-command-ability-id c) 23)
                                  (memv 8101 (sc2-raw-unit-command-unit-tags c))))))
  (assert-true! (and cam-idx-w atk-idx-w (< cam-idx-w atk-idx-w))
                "Wire translator must emit framing sc2-raw-camera-move BEFORE command to ungrouped unit #8101")
  (define obs-c40-grp
    (mk-s40-obs 14
                (list (mk-s40-unit 8001 59 32.5 32.5 #:radius 2.75 #:hp 1500.0 #:hp-max 1500.0)
                      (mk-s40-unit 8101 73 95.0 95.0 #:hp 100.0 #:hp-max 100.0)
                      (mk-s40-unit 8102 73 140.0 140.0 #:hp 100.0 #:hp-max 100.0))
                #:cam (sc2-point3d 32.5 32.5 0.0)))
  (define cmds-c40-grp
    (translate-bot-actions->sc2-raw-commands '((attack-pos 8102 142.0 142.0)) obs-c40-grp))
  (assert-true! (not (ormap framing-camera-cmd? cmds-c40-grp))
                "Wire translator must NOT emit framing sc2-raw-camera-move for control-grouped unit #8102")
  (assert-eq! (wire-cmd-priority-tier (list-ref cmds-c40-wire cam-idx-w)) 1
              "Framing sc2-raw-camera-move must have priority Tier 1 (P1), not Tier 4")
  (assert-eq! (wire-cmd-priority-tier (sc2-raw-camera-move 50.0 50.0 0.0)) 4
              "Routine non-framing sc2-raw-camera-move must remain priority Tier 4 (P4)")

  (define gov40 (make-wire-apm-governor #:target-apm 410.0 #:hard-cap-apm 485.0))
  (void (govern-sc2-wire-actions! gov40 (list (sc2-raw-camera-move 32.5 32.5 0.0)) 99))
  (define p0-burn-40
    (for/list ([i (in-range 8)])
      (sc2-raw-unit-command 251 #f 3001 (list (+ 8500 i)) #f)))
  (void (govern-sc2-wire-actions! gov40 p0-burn-40 100)) ;; tokens now ~8.5 (< 10.0 floor for Tier 4)
  (define frame-cam-40 (mark-framing-camera-cmd! (sc2-raw-camera-move 95.0 95.0 0.0) 88.4))
  (define target-uc-40 (sc2-raw-unit-command 23 (sc2-point2d 98.0 98.0) 0 '(8101) #f))
  (define out-40-gov
    (govern-sc2-wire-actions!
     gov40
     (list (sc2-raw-camera-move 120.0 120.0 0.0) frame-cam-40 target-uc-40)
     105)) ;; dloop = 105 - 99 = 6 loops
  (define gov-cam-idx (index-where out-40-gov framing-camera-cmd?))
  (define gov-uc-idx
    (index-where out-40-gov
                 (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 23)))))
  (assert-true! (and gov-cam-idx gov-uc-idx (< gov-cam-idx gov-uc-idx))
                "Governor must keep framing sc2-raw-camera-move at 6-loop cooldown & <10 tokens immediately before target unit command")
  (assert-true! (not (ormap (lambda (c) (and (sc2-raw-camera-move? c) (not (framing-camera-cmd? c))))
                            out-40-gov))
                "Routine Tier 4 camera move must still be dropped at dloop=6 and tokens < 10.0"))

;; =============================================================================
;; Suite 41: General Bayesian Inference & Production-Coupled Supply Buffer
;; =============================================================================
(run-suite "41. General Bayesian Inference & Production-Coupled Supply Buffer"
  ;; 41.1 Generic Bayesian likelihood updater
  (assert-true! (< (abs (- (bayesian-posterior-from-likelihoods 0.20 '((#f . 10.0))) 0.20)) 1e-6)
                "bayesian-posterior-from-likelihoods with no active evidence must preserve prior")
  (assert-true! (>= (bayesian-posterior-from-likelihoods 0.12 '((#t . 14.0))) 0.55)
                "bayesian-posterior-from-likelihoods with LR=14.0 on 0.12 prior must exceed 0.55")

  ;; 41.2 Pad-camped Bayesian posterior from hard observational inputs
  (define p-pad-clear
    (compute-bayesian-pad-camped-posterior
     #:camp-building-observed? #f
     #:enemy-combat-count 0
     #:ally-defender-count 2
     #:total-ally-combat-count 6
     #:live-obs? #t))
  (assert-true! (< p-pad-clear 0.15)
                (format "Clear expansion pad with defenders must have posterior < 0.15 (got ~a)" p-pad-clear))

  (define p-pad-cannon
    (compute-bayesian-pad-camped-posterior
     #:camp-building-observed? #t
     #:enemy-combat-count 0
     #:ally-defender-count 0
     #:live-obs? #t))
  (assert-true! (>= p-pad-cannon 0.55)
                (format "Expansion pad with observed enemy static defense/base must have posterior >= 0.55 (got ~a)" p-pad-cannon))

  (define p-pad-2units
    (compute-bayesian-pad-camped-posterior
     #:camp-building-observed? #f
     #:enemy-combat-count 2
     #:ally-defender-count 1
     #:total-ally-combat-count 4
     #:live-obs? #t))
  (assert-true! (>= p-pad-2units 0.55)
                (format "Expansion pad with >= 2 enemy combat units must have posterior >= 0.55 (got ~a)" p-pad-2units))

  (define p-pad-1unit-unescorted
    (compute-bayesian-pad-camped-posterior
     #:camp-building-observed? #f
     #:enemy-combat-count 1
     #:ally-defender-count 0
     #:total-ally-combat-count 1
     #:live-obs? #t))
  (assert-true! (>= p-pad-1unit-unescorted 0.55)
                (format "Live pad with 1 enemy combat unit and no defenders/army must have posterior >= 0.55 (got ~a)" p-pad-1unit-unescorted))

  (define p-pad-1unit-defended
    (compute-bayesian-pad-camped-posterior
     #:camp-building-observed? #f
     #:enemy-combat-count 1
     #:ally-defender-count 4
     #:total-ally-combat-count 8
     #:live-obs? #t))
  (assert-true! (< p-pad-1unit-defended 0.55)
                (format "Well-defended pad with 1 transient enemy must remain < 0.55 (got ~a)" p-pad-1unit-defended))

  ;; 41.3 Smooth production-and-build-coupled supply curve (monotonic with production/workers)
  (define sb-open-1base
    (compute-production-coupled-supply-buffer #:active-bases 1 #:production-facilities 1 #:workers 12 #:target-workers 44))
  (define sb-early-nat
    (compute-production-coupled-supply-buffer #:active-bases 2 #:production-facilities 2 #:workers 22 #:target-workers 44))
  (define sb-mid-4base
    (compute-production-coupled-supply-buffer #:active-bases 4 #:production-facilities 4 #:workers 35 #:target-workers 66))
  (define sb-late-max
    (compute-production-coupled-supply-buffer #:active-bases 4 #:production-facilities 8 #:workers 66 #:target-workers 66))
  (assert-true! (and (<= 2 sb-open-1base)
                     (<= sb-open-1base sb-early-nat)
                     (< sb-early-nat sb-mid-4base)
                     (<= sb-mid-4base sb-late-max)
                     (<= sb-late-max 18))
                (format "Supply buffer must scale monotonically with production (~a <= ~a < ~a <= ~a <= 18)"
                        sb-open-1base sb-early-nat sb-mid-4base sb-late-max)))

(define total-elapsed-ms
  (inexact->exact (round (- (current-inexact-monotonic-milliseconds) suite-start-total-ms))))
(printf "\n============================================================================\n")
(printf "  ALL #lang sc-bot TESTS PASSED (~a assertions, 12/12 mutation kill rate, ~a ms total)!\n"
        total-assertions total-elapsed-ms)
(printf "============================================================================\n")

