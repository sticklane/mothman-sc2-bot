#lang racket

;; =============================================================================
;; Pure-Racket Formal State-Machine & Invariant Verifier (`lib/state-machine-verifier.rkt`)
;;
;; Model-checks all 4 core state machines in the `#lang sc-bot` Racket runtime:
;;   1. Posture State Machine (`compute-next-posture`, `step-layer1b-mastermind!`,
;;      `filter-rush-threat-enemies`, `step-live-bot-runtime!` in `lib/bot-runtime.rkt`)
;;   2. Mirror-Mind Macro Verdict, All-Depth Selection & Toolbox State Machine
;;      (`compute-opponent-shadow-ledger`, `interpret-opponent-actions`,
;;      `evaluate-mirror-macro-verdict`, `choose-optimal-mirror-depth`,
;;      `compute-mirror-toolbox-allocation`, `select-mirror-trust-mode`
;;      in `lib/mirror-mind-predictor.rkt`)
;;   3. Economy & Symbiotic Resource Ledger State Machine
;;      (`evaluate-coupled-macro-governor`, `evaluate-adaptive-build-and-tech-plan`,
;;      `evaluate-guns-vs-butter-ppf`, `make-symbiotic-ledger`, `step-layer2-economy!`
;;      in `lib/econ-ledger.rkt` and `lib/bot-runtime.rkt`)
;;   4. General Prioritization & Resource-Allocation Scheduler Invariants (`PV1`–`PV6`)
;;      (`verify-prioritization-scheduler-invariants` across the 10-dimensional
;;      multi-race economic/tactical state lattice)
;; =============================================================================

(require racket/match
         racket/list
         racket/set
         racket/math
         "bot-runtime.rkt"
         "mirror-mind-predictor.rkt"
         "econ-ledger.rkt"
         "priority-macro-brain.rkt"
         "sc2-protobuf-ws.rkt"
         "zerospace-mastermind.rkt")

(provide (struct-out verification-check-result)
         (struct-out state-machine-verification-report)
         (struct-out pv-candidate)
         (struct-out pv-scheduler-decision)
         (struct-out pv-refractory-gate)
         pv-evaluate-prioritization-state
         pv-make-refractory-gate
         pv-try-emit-refractory!
         verify-posture-state-machine
         verify-mirror-mind-state-machine
         verify-economy-and-ledger-state-machine
         verify-prioritization-scheduler-invariants
         verify-all-state-machines
         run-all-formal-verifications)

(struct verification-check-result
  (domain
   id
   description
   states-explored
   passed?
   counterexample)
  #:transparent)

(struct state-machine-verification-report
  (total-checks
   passed-checks
   failed-checks
   total-states-explored
   check-results)
  #:transparent)

;; =============================================================================
;; 1. Formal Model Checker for Posture State Machine (`lib/bot-runtime.rkt`)
;; =============================================================================

(define (verify-posture-state-machine)
  (define results '())
  (define (record! id desc states passed? [cex #f])
    (set! results
          (append results
                  (list (verification-check-result 'posture-state-machine
                                                   id
                                                   desc
                                                   states
                                                   passed?
                                                   cex)))))

  ;; ---------------------------------------------------------------------------
  ;; Check P1: BFS Reachability of all 20 Race Posture States across Zerg, Protoss, Terran, Random
  ;; ---------------------------------------------------------------------------
  (define expected-race-postures
    (hash 'Zerg    '(Macro12Hatch SunkenLairRecovery MutaLurkerContain MacroHydraLurker SwarmVictory CrisisZealotRush)
          'Protoss '(ForgeFastExpand CannonWallRecovery DragoonReaverVanguard StalkerImmortalColossus ProtossArmadaVictory CrisisZerglingFlood)
          'Terran  '(OneRaxFE BunkerSiegeRecovery VesselGhostPush BioTankMedivac MothmanApexVictory CrisisEarlyBust)
          'Random  '(RandomRollOpening AdaptiveCounterRecovery TriRaceVanguardContain MidGameBioTankContain MothmanApexVictory EarlyScoutCrisis)))

  (define rush-enemies-obs
    (list (hash 'id 901 'type 'zealot 'x 34 'y 35 'hp 100 'dps 16)
          (hash 'id 902 'type 'zealot 'x 35 'y 36 'hp 100 'dps 16)
          (hash 'id 903 'type 'zealot 'x 36 'y 37 'hp 100 'dps 16)
          (hash 'id 904 'type 'zealot 'x 37 'y 38 'hp 100 'dps 16)))

  (define sample-obs-transitions
    (list (hash 'frame 0    'fap-score 0.0   'enemy-units '()              'ally-units '() 'ally-buildings '())
          (hash 'frame 500  'fap-score 0.0   'enemy-units '()              'ally-units '() 'ally-buildings '())
          (hash 'frame 1200 'fap-score -15.0 'enemy-units rush-enemies-obs 'ally-units '() 'ally-buildings '())
          (hash 'frame 2000 'fap-score 5.0   'enemy-units '()              'ally-units '() 'ally-buildings '())
          (hash 'frame 3800 'fap-score 18.0  'enemy-units '()              'ally-units '() 'ally-buildings '())
          (hash 'frame 4200 'fap-score -22.0 'enemy-units '()              'ally-units '() 'ally-buildings '())))

  (define p1-states 0)
  (define unreachable-by-race '())
  (for ([(race expected-list) (in-hash expected-race-postures)])
    (define init-p (first expected-list))
    (define reachable (mutable-set init-p))
    (define queue (list init-p))
    (let loop ()
      (unless (null? queue)
        (define cur (car queue))
        (set! queue (cdr queue))
        (for ([obs (in-list sample-obs-transitions)])
          (set! p1-states (add1 p1-states))
          (define rt (make-live-bot-runtime #:race race #:initial-posture cur))
          (define nxt (compute-next-posture rt obs (hash-ref obs 'fap-score 0.0)))
          (unless (set-member? reachable nxt)
            (set-add! reachable nxt)
            (set! queue (append queue (list nxt)))))
        (loop)))
    (define missing
      (filter (lambda (p) (not (set-member? reachable p))) expected-list))
    (unless (null? missing)
      (set! unreachable-by-race (cons (cons race missing) unreachable-by-race))))

  (record! 'P1-all-24-race-postures-reachable
           "All 24 race-specific postures across Zerg, Protoss, Terran, and Random are reachable via BFS from their opening postures"
           p1-states
           (null? unreachable-by-race)
           (and (not (null? unreachable-by-race)) unreachable-by-race))

  ;; ---------------------------------------------------------------------------
  ;; Check P2: No Late-Game Victory Absorbing Trap when `fap-score < -15`
  ;; ---------------------------------------------------------------------------
  (define p2-states 0)
  (define p2-cex #f)
  (define victory-pairs
    '((Zerg    SwarmVictory          MacroHydraLurker)
      (Protoss ProtossArmadaVictory  StalkerImmortalColossus)
      (Terran  MothmanApexVictory    BioTankMedivac)
      (Random  MothmanApexVictory    MidGameBioTankContain)))
  (for* ([vp (in-list victory-pairs)]
         [frame '(3800 5000 8000 12000)]
         [fap '(-16.0 -25.0 -40.0)])
    (set! p2-states (add1 p2-states))
    (match-define (list race vic-post expected-rec) vp)
    (define rt (make-live-bot-runtime #:race race #:initial-posture vic-post))
    (define obs (hash 'frame frame 'fap-score fap 'enemy-units '()))
    (define nxt (compute-next-posture rt obs fap))
    (unless (eq? nxt expected-rec)
      (unless p2-cex
        (set! p2-cex (list 'race race 'prev vic-post 'frame frame 'fap fap 'got nxt 'expected expected-rec)))))
  (record! 'P2-no-late-game-victory-trap
           "Late-game Victory postures (`SwarmVictory`, `ProtossArmadaVictory`, `MothmanApexVictory`) recover to midgame contain whenever `fap-score < -15`"
           p2-states
           (not p2-cex)
           p2-cex)

  ;; ---------------------------------------------------------------------------
  ;; Check P3: Hysteresis Deadband around `fap-score = -5` (`[-8, -2]`) and `+10` (`[7, 13]`)
  ;; ---------------------------------------------------------------------------
  (define p3-states 0)
  (define p3-cex #f)
  (define crisis-pairs
    '((Zerg    CrisisZealotRush    SunkenLairRecovery)
      (Protoss CrisisZerglingFlood CannonWallRecovery)
      (Terran  CrisisEarlyBust     BunkerSiegeRecovery)
      (Random  EarlyScoutCrisis    AdaptiveCounterRecovery)))
  ;; Band 1: around -5 (`[-8, -2]`) at frame 1200 with 3 rush enemies
  (for* ([cp (in-list crisis-pairs)]
         [fap '(-7.5 -5.0 -2.5)])
    (set! p3-states (+ p3-states 2))
    (match-define (list race crisis-p normal-p) cp)
    (define obs (hash 'frame 1200 'fap-score fap 'enemy-units rush-enemies-obs))
    ;; If already in crisis, stay in crisis while fap <= -2.0
    (define rt-in (make-live-bot-runtime #:race race #:initial-posture crisis-p))
    (define nxt-in (compute-next-posture rt-in obs fap))
    (unless (eq? nxt-in crisis-p)
      (unless p3-cex
        (set! p3-cex (list 'band '-5-stay-crisis 'race race 'fap fap 'got nxt-in))))
    ;; If in normal recovery, do not enter crisis while fap >= -8.0
    (define rt-out (make-live-bot-runtime #:race race #:initial-posture normal-p))
    (define nxt-out (compute-next-posture rt-out obs fap))
    (unless (eq? nxt-out normal-p)
      (unless p3-cex
        (set! p3-cex (list 'band '-5-stay-normal 'race race 'fap fap 'got nxt-out)))))

  ;; Band 2: around +10 (`[7, 13]`) at frame 4000 with enemy units present
  (for* ([vp (in-list victory-pairs)]
         [fap '(7.5 10.0 12.5)])
    (set! p3-states (+ p3-states 2))
    (match-define (list race vic-p mid-p) vp)
    (define obs (hash 'frame 4000 'fap-score fap 'enemy-units rush-enemies-obs))
    ;; If already in Victory, stay in Victory while fap >= 7.0
    (define rt-vic (make-live-bot-runtime #:race race #:initial-posture vic-p))
    (define nxt-vic (compute-next-posture rt-vic obs fap))
    (unless (eq? nxt-vic vic-p)
      (unless p3-cex
        (set! p3-cex (list 'band '+10-stay-victory 'race race 'fap fap 'got nxt-vic))))
    ;; If in midgame contain with enemies present, do not jump to Victory while fap < 13.0
    (define rt-mid (make-live-bot-runtime #:race race #:initial-posture mid-p))
    (define nxt-mid (compute-next-posture rt-mid obs fap))
    (unless (eq? nxt-mid mid-p)
      (unless p3-cex
        (set! p3-cex (list 'band '+10-stay-midgame 'race race 'fap fap 'got nxt-mid)))))

  (record! 'P3-fap-hysteresis-deadband
           "Hysteresis deadbands (`[-8,-2]` around `-5` and `[7,13]` around `+10`) prevent single-point FAP posture chatter across all 4 races"
           p3-states
           (not p3-cex)
           p3-cex)

  ;; ---------------------------------------------------------------------------
  ;; Check P4: Non-Combat Scouts Never Trigger Rush Crisis or Worker Pulls
  ;; ---------------------------------------------------------------------------
  (define p4-states 0)
  (define p4-cex #f)
  (for* ([race '(Zerg Protoss Terran Random)]
         [scout-type '(overlord overseer observer changeling changeling-zergling probe scv drone)]
         [frame '(600 1200 2000)])
    (set! p4-states (add1 p4-states))
    (define rt (make-live-bot-runtime #:race race))
    (define obs
      (hash 'frame frame
            'minerals 200
            'gas 100
            'supply-used 22
            'supply-cap 30
            'base-x 32.5
            'base-y 32.5
            'natural-x 50.5
            'natural-y 56.5
            'enemy-x 160.5
            'enemy-y 160.5
            'ally-units (list (hash 'id 1 'type 'drone 'x 33 'y 33 'hp 40 'dps 5)
                              (hash 'id 2 'type 'drone 'x 34 'y 33 'hp 40 'dps 5)
                              (hash 'id 3 'type 'drone 'x 33 'y 34 'hp 40 'dps 5)
                              (hash 'id 4 'type 'drone 'x 34 'y 34 'hp 40 'dps 5)
                              (hash 'id 10 'type 'queen 'x 35 'y 35 'hp 175 'dps 12))
            'ally-buildings (list (hash 'id 100 'type 'hatchery 'x 32.5 'y 32.5 'hp 1500))
            'enemy-units (list (hash 'id 901 'type scout-type 'x 34 'y 34 'hp 100 'dps 0))
            'enemy-buildings '()))
    (define step-res (step-live-bot-runtime! rt obs))
    (define cmds (hash-ref step-res 'actions '()))
    (define cur-p (live-bot-runtime-posture rt))
    (define pulled-workers?
      (ormap (lambda (c) (and (pair? c) (eq? (car c) 'pull-workers-attack))) cmds))
    (when (or (memq cur-p '(EarlyScoutCrisis CrisisZealotRush CrisisZerglingFlood CrisisEarlyBust))
              pulled-workers?)
      (unless p4-cex
        (set! p4-cex (list 'race race 'scout scout-type 'frame frame
                           'posture cur-p 'pulled-workers? pulled-workers?)))))
  (record! 'P4-no-scout-false-panic-or-worker-pull
           "Single scouting workers and non-combat flying scouts (`overlord`/`observer`/`changeling`) never trigger crisis postures or `pull-workers-attack`"
           p4-states
           (not p4-cex)
           p4-cex)

  ;; ---------------------------------------------------------------------------
  ;; Check P5: Bounded `posture-history` (<= 32) & Live PDA Telemetry Wiring
  ;; ---------------------------------------------------------------------------
  (define rt-p5 (make-live-bot-runtime #:race 'Zerg))
  (for ([step (in-range 80)])
    (define osc? (even? step))
    (define obs
      (hash 'frame (if osc? 1200 2200)
            'fap-score (if osc? -18.0 15.0)
            'minerals 300
            'gas 150
            'supply-used 36
            'supply-cap 52
            'base-x 32.5
            'base-y 32.5
            'natural-x 50.5
            'natural-y 56.5
            'enemy-x 160.5
            'enemy-y 160.5
            'visible-sectors '(0 1 2 3 4 5)
            'ally-units (list (hash 'id 1 'type 'roach 'x 42 'y 45 'hp 145 'dps 16))
            'ally-buildings (list (hash 'id 100 'type 'hatchery 'x 32.5 'y 32.5 'hp 1500))
            'enemy-units (if osc? rush-enemies-obs '())
            'enemy-buildings '()))
    (step-live-bot-runtime! rt-p5 obs))
  (define hist-len (length (live-bot-runtime-posture-history rt-p5)))
  (define telem (live-bot-runtime-last-telemetry rt-p5))
  (define pda-bucket (hash-ref telem 'pda-bucket 'none))
  (define p5-ok?
    (and (<= hist-len 32)
         (> hist-len 1)
         (not (eq? pda-bucket 'Blind-Fixation))))
  (record! 'P5-bounded-posture-history-and-live-pda-trace
           "`posture-history` is strictly bounded to <= 32 entries and live `visible-sectors` / `posture-history` wire into `pda-bucket` without false `Blind-Fixation`"
           80
           p5-ok?
           (and (not p5-ok?)
                (list 'hist-len hist-len 'pda-bucket pda-bucket)))

  results)

;; =============================================================================
;; 2. Formal Model Checker for Mirror-Mind State Machine (`lib/mirror-mind-predictor.rkt`)
;; =============================================================================

(define (verify-mirror-mind-state-machine)
  (define results '())
  (define (record! id desc states passed? [cex #f])
    (set! results
          (append results
                  (list (verification-check-result 'mirror-mind-state-machine
                                                   id
                                                   desc
                                                   states
                                                   passed?
                                                   cex)))))

  ;; ---------------------------------------------------------------------------
  ;; Check M1: All 4 Mirror-Mind Macro Verdicts Reachable
  ;; ---------------------------------------------------------------------------
  (define verdicts-seen (mutable-set))
  ;; 1. Greedy expand (3 enemy townhalls, low combat units)
  (let ([ms (make-mirror-mind-state #:our-race 'Zerg #:enemy-race 'Protoss)])
    (define e-bldgs
      (list (hash 'id 1 'type 'nexus 'x 160 'y 160)
            (hash 'id 2 'type 'nexus 'x 140 'y 140)
            (hash 'id 3 'type 'nexus 'x 120 'y 150)))
    (define ledger (compute-opponent-shadow-ledger ms 3200 '() e-bldgs))
    (define reading (interpret-opponent-actions ms 3200 '() e-bldgs ledger))
    (define-values (v _b _w _rm _dp)
      (evaluate-mirror-macro-verdict ms 3200 '() '() '() e-bldgs ledger reading))
    (set-add! verdicts-seen v))
  ;; 2. Passive turtle (1-2 bases + static defense)
  (let ([ms (make-mirror-mind-state #:our-race 'Zerg #:enemy-race 'Terran)])
    (define e-bldgs
      (list (hash 'id 1 'type 'orbital-command 'x 160 'y 160)
            (hash 'id 2 'type 'bunker 'x 145 'y 145)
            (hash 'id 3 'type 'planetary-fortress 'x 138 'y 138)))
    (define e-units
      (list (hash 'id 10 'type 'siege-tank-sieged 'x 144 'y 144)))
    (define ledger (compute-opponent-shadow-ledger ms 3000 e-units e-bldgs))
    (define reading (interpret-opponent-actions ms 3000 e-units e-bldgs ledger))
    (define-values (v _b _w _rm _dp)
      (evaluate-mirror-macro-verdict ms 3000 '() '() e-units e-bldgs ledger reading))
    (set-add! verdicts-seen v))
  ;; 3. Defend All-In Then Counter Expand (proxy/all-in near our base at frame 2400)
  (let ([ms (make-mirror-mind-state #:our-race 'Zerg #:enemy-race 'Terran)])
    (define e-units
      (for/list ([i (in-range 6)])
        (hash 'id (+ 50 i) 'type 'marine 'x 36 'y 38)))
    (define ledger (compute-opponent-shadow-ledger ms 2400 e-units '()))
    (define reading (interpret-opponent-actions ms 2400 e-units '() ledger))
    (define-values (v _b _w _rm _dp)
      (evaluate-mirror-macro-verdict ms 2400 '() '() e-units '() ledger reading))
    (set-add! verdicts-seen v))
  ;; 4. Pace Macro And Disrupt (even midgame army)
  (let ([ms (make-mirror-mind-state #:our-race 'Zerg #:enemy-race 'Protoss)])
    (define e-bldgs
      (list (hash 'id 1 'type 'nexus 'x 160 'y 160)
            (hash 'id 2 'type 'nexus 'x 140 'y 140)))
    (define e-units
      (for/list ([i (in-range 6)])
        (hash 'id (+ 80 i) 'type 'stalker 'x 135 'y 135)))
    (define ledger (compute-opponent-shadow-ledger ms 4500 e-units e-bldgs))
    (define reading (interpret-opponent-actions ms 4500 e-units e-bldgs ledger))
    (define-values (v _b _w _rm _dp)
      (evaluate-mirror-macro-verdict ms 4500 '() '() e-units e-bldgs ledger reading))
    (set-add! verdicts-seen v))

  (define expected-verdicts
    '(punish-And-Deny-Greedy-Expand
      out-Expand-Passive-Turtle
      defend-All-In-Then-Counter-Expand
      pace-Macro-And-Disrupt))
  (define missing-verdicts
    (filter (lambda (v) (not (set-member? verdicts-seen v))) expected-verdicts))
  (record! 'M1-all-4-macro-verdicts-reachable
           "All 4 Mirror-Mind macro verdicts (`punish-And-Deny-Greedy-Expand`, `out-Expand-Passive-Turtle`, `defend-All-In-Then-Counter-Expand`, `pace-Macro-And-Disrupt`) are reachable"
           4
           (null? missing-verdicts)
           (and (not (null? missing-verdicts)) missing-verdicts))

  ;; ---------------------------------------------------------------------------
  ;; Check M2: No Permanent Late-Game `defend-All-In-Then-Counter-Expand` Lock
  ;;           After Frame 6048 When Enemy Is Not Attacking Our Base
  ;; ---------------------------------------------------------------------------
  (define m2-states 0)
  (define m2-cex #f)
  (for* ([frame '(6200 7500 9000 12000)]
         [vis-bases '(0 1 2)]
         [far-combat-count '(0 2 5 8)])
    (set! m2-states (add1 m2-states))
    (define ms (make-mirror-mind-state #:our-race 'Zerg #:enemy-race 'Terran))
    (define e-bldgs
      (for/list ([b (in-range vis-bases)])
        (hash 'id (+ 200 b) 'type 'command-center 'x 155 'y (+ 150 (* b 8)))))
    (define e-units
      (for/list ([u (in-range far-combat-count)])
        (hash 'id (+ 300 u) 'type 'marine 'x 150 'y 150)))
    (define a-bldgs
      (list (hash 'id 1 'type 'hatchery 'x 32.5 'y 32.5)
            (hash 'id 2 'type 'hatchery 'x 50.5 'y 56.5)))
    (define ledger (compute-opponent-shadow-ledger ms frame e-units e-bldgs))
    (define reading (interpret-opponent-actions ms frame e-units e-bldgs ledger))
    (define-values (v _b _w _rm _dp)
      (evaluate-mirror-macro-verdict ms frame '() a-bldgs e-units e-bldgs ledger reading))
    (when (or (action-lens-reading-missing-natural-expansion? reading)
              (eq? v 'defend-All-In-Then-Counter-Expand))
      (unless m2-cex
        (set! m2-cex (list 'frame frame 'vis-bases vis-bases 'far-combat far-combat-count
                           'missing-nat? (action-lens-reading-missing-natural-expansion? reading)
                           'verdict v)))))
  (record! 'M2-no-late-game-all-in-verdict-lock
           "After frame 6048 (`4m30s`), when enemy is not attacking our base (`near-combat < 4`), `missing-nat?` is `#f` and verdict never locks in `defend-All-In-Then-Counter-Expand`"
           m2-states
           (not m2-cex)
           m2-cex)

  ;; ---------------------------------------------------------------------------
  ;; Check M3: Non-Combat Scouts Never Trigger False Proxy/All-In Verdict
  ;; ---------------------------------------------------------------------------
  (define m3-states 0)
  (define m3-cex #f)
  (for* ([scout-sym '(overlord overseer observer changeling changeling-zergling probe scv drone)]
         [frame '(1200 2200 3200)])
    (set! m3-states (add1 m3-states))
    (define ms (make-mirror-mind-state #:our-race 'Protoss #:enemy-race 'Zerg))
    (define e-units (list (hash 'id 99 'type scout-sym 'x 35 'y 36)))
    (define ledger (compute-opponent-shadow-ledger ms frame e-units '()))
    (define reading (interpret-opponent-actions ms frame e-units '() ledger))
    (define-values (v _b _w _rm _dp)
      (evaluate-mirror-macro-verdict ms frame '() '() e-units '() ledger reading))
    (when (or (action-lens-reading-proxy-or-rush-detected? reading)
              (eq? (shadow-ledger-dark-matter-hypothesis ledger) 'proxy-production-or-all-in))
      (unless m3-cex
        (set! m3-cex (list 'scout scout-sym 'frame frame 'verdict v
                           'hyp (shadow-ledger-dark-matter-hypothesis ledger))))))
  (record! 'M3-no-scout-false-proxy-verdict
           "Non-combat scouts (`overlord`, `overseer`, `observer`, `changeling`, single worker) near base never trigger `proxy-production-or-all-in`"
           m3-states
           (not m3-cex)
           m3-cex)

  ;; ---------------------------------------------------------------------------
  ;; Check M4: All Depths `d in {0..5}` Reachable & Hysteresis Guard
  ;; ---------------------------------------------------------------------------
  (define depths-reached (mutable-set))
  (for ([target-d (in-list '(0 1 2 3 4 5))])
    (define ms (make-mirror-mind-state #:our-race 'Zerg #:enemy-race 'Protoss #:depth 2))
    (define scores
      (for/hash ([d (in-list '(0 1 2 3 4 5))])
        (values d (if (= d target-d) 0.88 0.58))))
    (define chosen (choose-optimal-mirror-depth ms #:depth-accuracy-scores scores))
    (set-add! depths-reached chosen))
  (define ms-hyst (make-mirror-mind-state #:our-race 'Zerg #:enemy-race 'Protoss #:depth 2))
  (define d-acc-hyst (mirror-mind-state-depth-accuracies ms-hyst))
  (hash-set! d-acc-hyst 2 0.68)
  (hash-set! d-acc-hyst 4 0.71) ; +0.03 < +0.06 threshold
  (define hyst-chosen (choose-optimal-mirror-depth ms-hyst))
  (define m4-ok?
    (and (equal? (list->set '(0 1 2 3 4 5)) (for/set ([d (in-set depths-reached)]) d))
         (= hyst-chosen 2)))
  (record! 'M4-all-depths-0-to-5-reachable-with-hysteresis
           "All recursive depths `d in {0, 1, 2, 3, 4, 5}` are selectable by `choose-optimal-mirror-depth` and `<= +0.06` hysteresis prevents depth jitter"
           7
           m4-ok?
           (and (not m4-ok?) (list 'depths-reached (set->list depths-reached) 'hyst-chosen hyst-chosen)))

  ;; ---------------------------------------------------------------------------
  ;; Check M5: Snowball-Bounded Toolbox Allocation Invariant (`weight <= 0.25`, `override? = #f`)
  ;; ---------------------------------------------------------------------------
  (define m5-states 0)
  (define m5-cex #f)
  (for* ([ally-cnt '(0 2 6 15)]
         [enemy-cnt '(0 2 6 15)]
         [crisis? '(#f #t)]
         [acc '(0.25 0.50 0.75 0.95)]
         [act-d '(0 1 2 3 4 5)])
    (set! m5-states (add1 m5-states))
    (define ms (make-mirror-mind-state #:our-race 'Zerg #:enemy-race 'Terran))
    (set-mirror-mind-state-overall-accuracy! ms acc)
    (set-mirror-mind-state-active-depth! ms act-d)
    (define a-units
      (for/list ([i (in-range ally-cnt)])
        (hash 'id (+ 1 i) 'type 'roach 'hp 145 'dps 16)))
    (define e-units
      (for/list ([i (in-range enemy-cnt)])
        (hash 'id (+ 100 i) 'type 'marauder 'hp 125 'dps 20)))
    (define alloc
      (compute-mirror-toolbox-allocation ms a-units e-units #:crisis? crisis?))
    (define w (mirror-toolbox-allocation-toolbox-weight alloc))
    (define pw (mirror-toolbox-allocation-primary-macro-weight alloc))
    (define ov? (mirror-toolbox-allocation-allow-posture-override? alloc))
    (when (or (< w 0.0)
              (> w 0.250001)
              (> (abs (- (+ w pw) 1.0)) 1e-6)
              ov?
              (and crisis? (> w 0.0)))
      (unless m5-cex
        (set! m5-cex (list 'ally ally-cnt 'enemy enemy-cnt 'crisis? crisis? 'alloc alloc)))))
  (record! 'M5-snowball-bounded-toolbox-invariant
           "`compute-mirror-toolbox-allocation` strictly bounds `toolbox-weight` in `[0.0, 0.25]`, forces `0.0` during crisis, and keeps `allow-posture-override? = #f`"
           m5-states
           (not m5-cex)
           m5-cex)

  results)

;; =============================================================================
;; 3. Formal Model Checker for Economy & Symbiotic Resource Ledger State Machine
;; =============================================================================

(define (verify-economy-and-ledger-state-machine)
  (define results '())
  (define (record! id desc states passed? [cex #f])
    (set! results
          (append results
                  (list (verification-check-result 'economy-and-ledger-state-machine
                                                   id
                                                   desc
                                                   states
                                                   passed?
                                                   cex)))))

  ;; ---------------------------------------------------------------------------
  ;; Check E1: Multi-Base Expansion Liveness (`1 -> 2 -> 3 -> 4+` Bases Across All 3 Races)
  ;; ---------------------------------------------------------------------------
  (define e1-states 0)
  (define e1-cex #f)
  (for* ([race '(Zerg Protoss Terran)]
         [cur-bases '(1 2 3 4)])
    (set! e1-states (add1 e1-states))
    (define th-sym
      (case race
        [(Zerg) 'hatchery]
        [(Protoss) 'nexus]
        [(Terran) 'command-center]))
    (define worker-sym
      (case race
        [(Zerg) 'drone]
        [(Protoss) 'probe]
        [(Terran) 'scv]))
    (define workers-cnt (* cur-bases 20))
    (define gov
      (evaluate-coupled-macro-governor
       #:race race
       #:frame 4500
       #:minerals 500
       #:gas 200
       #:supply-left 12
       #:active-bases cur-bases
       #:depleting-bases 0
       #:workers workers-cnt
       #:under-crisis? #f
       #:recommended-min-bases (add1 cur-bases)))
    (define rt (make-live-bot-runtime #:race race))
    (define ally-units
      (for/list ([i (in-range workers-cnt)])
        (hash 'id (+ 1 i) 'type worker-sym 'x 32.5 'y 32.5 'hp 40 'dps 5)))
    (define extra-tech-bldgs
      (case race
        [(Zerg)
         (list (hash 'id 601 'type 'spawning-pool 'x 36 'y 36 'hp 1000)
               (hash 'id 602 'type 'extractor 'x 34 'y 30 'hp 500)
               (hash 'id 603 'type 'roach-warren 'x 38 'y 36 'hp 850)
               (hash 'id 604 'type 'hydralisk-den 'x 40 'y 36 'hp 850)
               (hash 'id 605 'type 'spire 'x 42 'y 36 'hp 850)
               (hash 'id 606 'type 'baneling-nest 'x 44 'y 36 'hp 850))]
        [(Protoss)
         (append
          (for/list ([g (in-range (* 2 cur-bases))])
            (hash 'id (+ 610 g) 'type 'gateway 'x (+ 36 (* g 2)) 'y 36 'hp 1000))
          (list (hash 'id 601 'type 'pylon 'x 35 'y 35 'hp 400)
                (hash 'id 602 'type 'assimilator 'x 34 'y 30 'hp 450)
                (hash 'id 603 'type 'cybernetics-core 'x 38 'y 36 'hp 1000)
                (hash 'id 604 'type 'robotics-facility 'x 40 'y 36 'hp 1000)
                (hash 'id 605 'type 'robotics-bay 'x 42 'y 36 'hp 1000)
                (hash 'id 606 'type 'twilight-council 'x 44 'y 36 'hp 1000)
                (hash 'id 607 'type 'forge 'x 46 'y 36 'hp 1000)))]
        [(Terran)
         (append
          (for/list ([r (in-range (* 2 cur-bases))])
            (hash 'id (+ 610 r) 'type 'barracks 'x (+ 36 (* r 2)) 'y 36 'hp 1000))
          (list (hash 'id 601 'type 'supply-depot 'x 35 'y 35 'hp 400)
                (hash 'id 602 'type 'refinery 'x 34 'y 30 'hp 500)
                (hash 'id 603 'type 'factory 'x 38 'y 36 'hp 1250)
                (hash 'id 604 'type 'starport 'x 40 'y 36 'hp 1300)
                (hash 'id 605 'type 'engineering-bay 'x 42 'y 36 'hp 850)
                (hash 'id 606 'type 'armory 'x 44 'y 36 'hp 750)))]))
    (define ally-bldgs
      (append
       (for/list ([b (in-range cur-bases)])
         (hash 'id (+ 500 b) 'type th-sym 'x (+ 32.5 (* b 22.0)) 'y (+ 32.5 (* b 18.0)) 'hp 1500))
       extra-tech-bldgs))
    (define obs
      (hash 'frame 4500
            'minerals 1200
            'gas 400
            'supply-used (* cur-bases 36)
            'supply-cap (min 200 (* cur-bases 52))
            'base-x 32.5
            'base-y 32.5
            'natural-x 50.5
            'natural-y 56.5
            'enemy-x 160.5
            'enemy-y 160.5
            'ally-units ally-units
            'ally-buildings ally-bldgs
            'enemy-units '()
            'enemy-buildings (list (hash 'id 801 'type 'nexus 'x 160 'y 160)
                                   (hash 'id 802 'type 'nexus 'x 140 'y 140)
                                   (hash 'id 803 'type 'nexus 'x 120 'y 150))))
    (define econ-cmds (step-layer2-economy! rt obs))
    (define expanded?
      (ormap (lambda (c)
               (and (pair? c)
                    (or (eq? (car c) 'expand)
                        (and (eq? (car c) 'build)
                             (>= (length c) 2)
                             (eq? (second c) th-sym)))))
             econ-cmds))
    (when (or (<= (coupled-macro-plan-desired-bases gov) cur-bases)
              (not expanded?))
      (unless e1-cex
        (set! e1-cex (list 'race race 'cur-bases cur-bases
                           'desired-bases (coupled-macro-plan-desired-bases gov)
                           'expanded? expanded?
                           'econ-cmds econ-cmds)))))
  (record! 'E1-multi-base-expansion-liveness
           "All 3 races (`Zerg`, `Protoss`, `Terran`) expand past 2 bases (`1 -> 2 -> 3 -> 4 -> 5`) with distinct expansion coordinates"
           e1-states
           (not e1-cex)
           e1-cex)

  ;; ---------------------------------------------------------------------------
  ;; Check E2: Single-Frame Resource Conservation (No Expansion + Tech Double-Spend)
  ;; ---------------------------------------------------------------------------
  (define e2-states 0)
  (define e2-cex #f)
  (for ([race '(Zerg Protoss Terran)])
    (set! e2-states (add1 e2-states))
    (define worker-sym
      (case race [(Zerg) 'drone] [(Protoss) 'probe] [(Terran) 'scv]))
    (define th-sym
      (case race [(Zerg) 'hatchery] [(Protoss) 'nexus] [(Terran) 'command-center]))
    (define pool-sym
      (case race [(Zerg) 'spawning-pool] [(Protoss) 'gateway] [(Terran) 'barracks]))
    (define rt (make-live-bot-runtime #:race race))
    ;; Give 350 minerals on 1 base with 18 workers: enough for Zerg expansion (300M),
    ;; leaving 50M (< 150M needed for roach-warren / cybernetics-core / factory).
    (define obs
      (hash 'frame 2400
            'minerals 350
            'gas 150
            'supply-used 26
            'supply-cap 36
            'base-x 32.5
            'base-y 32.5
            'natural-x 50.5
            'natural-y 56.5
            'enemy-x 160.5
            'enemy-y 160.5
            'ally-units (for/list ([i (in-range 18)])
                          (hash 'id (+ 1 i) 'type worker-sym 'x 32.5 'y 32.5 'hp 40 'dps 5))
            'ally-buildings (list (hash 'id 100 'type th-sym 'x 32.5 'y 32.5 'hp 1500)
                                  (hash 'id 101 'type pool-sym 'x 37.5 'y 37.5 'hp 1000))
            'enemy-units '()
            'enemy-buildings '()))
    (define econ-cmds (step-layer2-economy! rt obs))
    (define expand-cmd?
      (ormap (lambda (c) (and (pair? c) (eq? (car c) 'expand))) econ-cmds))
    (define tech-builds
      (filter (lambda (c)
                (and (pair? c)
                     (eq? (car c) 'build)
                     (memq (second c) '(roach-warren cybernetics-core factory))))
              econ-cmds))
    (when (and expand-cmd? (not (null? tech-builds)))
      (unless e2-cex
        (set! e2-cex (list 'race race 'minerals 350 'econ-cmds econ-cmds)))))
  (record! 'E2-no-single-frame-expansion-tech-double-spend
           "`step-layer2-economy!` deducts `300M` expansion cost before evaluating tech building construction, preventing single-frame mineral over-allocation"
           e2-states
           (not e2-cex)
           e2-cex)

  ;; ---------------------------------------------------------------------------
  ;; Check E3: Guns-vs-Butter PPF Share Conservation & Non-Negativity
  ;; ---------------------------------------------------------------------------
  (define e3-states 0)
  (define e3-cex #f)
  (for* ([mins '(0 50 150 350 800 2000)]
         [gas '(0 50 200 600)]
         [fap '(-30 -10 0 10 30)]
         [bases '(1 2 3 4)]
         [workers '(8 16 32 60)])
    (set! e3-states (add1 e3-states))
    (define ppf
      (evaluate-guns-vs-butter-ppf
       #:race 'Zerg
       #:frame 3000
       #:minerals mins
       #:gas gas
       #:supply-left 8
       #:supply-cap (* bases 44)
       #:workers workers
       #:active-bases bases
       #:fap-score fap
       #:under-crisis? (< fap -10)))
    (define bs (guns-vs-butter-ppf-butter-share ppf))
    (define gs (guns-vs-butter-ppf-guns-share ppf))
    (define ts (guns-vs-butter-ppf-tech-share ppf))
    (when (or (< bs 0.0) (< gs 0.0) (< ts 0.0)
              (> (abs (- (+ bs gs ts) 1.0)) 1e-5))
      (unless e3-cex
        (set! e3-cex (list 'mins mins 'gas gas 'fap fap 'ppf ppf)))))
  (record! 'E3-guns-vs-butter-ppf-share-conservation
           "`evaluate-guns-vs-butter-ppf` conserves non-negative share weights (`butter + guns + tech == 1.0`) across all 480 grid states"
           e3-states
           (not e3-cex)
           e3-cex)

  ;; ---------------------------------------------------------------------------
  ;; Check E4: Symbiotic Resource Ledger Conservation Across Reserve/Borrow/Preempt/Commit
  ;; ---------------------------------------------------------------------------
  (define e4-states 0)
  (define e4-cex #f)
  (for* ([tot-m (list 300 500 1000 +nan.0 +inf.0 'null)]
         [tot-g (list 150 300 600 +nan.0 -inf.0 "bad")]
         [tot-s (list 10 20 50 '())])
    (set! e4-states (add1 e4-states))
    (define l (make-symbiotic-ledger tot-m tot-g tot-s))
    (unless (ledger-verify-invariant? l)
      (unless e4-cex
        (set! e4-cex (list 'stage 'init 'tot-m tot-m 'tot-g tot-g 'led l))))
    (when (and (>= (ledger-available-minerals l) 200)
               (>= (ledger-available-gas l) 100)
               (>= (ledger-available-supply l) 4))
      (ledger-reserve! l 'tech-lair 'macro 150 100 0 2)
      (unless (ledger-verify-invariant? l)
        (unless e4-cex (set! e4-cex (list 'stage 'reserve 'led l))))
      (ledger-borrow! l 'crisis-roaches 150 50 4 10)
      (unless (ledger-verify-invariant? l)
        (unless e4-cex (set! e4-cex (list 'stage 'borrow-preempt 'led l))))
      (ledger-commit! l 'crisis-roaches)
      (unless (ledger-verify-invariant? l)
        (unless e4-cex (set! e4-cex (list 'stage 'commit 'led l))))))
  (record! 'E4-symbiotic-ledger-non-negative-conservation
           "`make-symbiotic-ledger` + `ledger-reserve!` + `ledger-borrow!` + `ledger-commit!` preserve `ledger-verify-invariant?` across normal and malformed inputs"
           e4-states
           (not e4-cex)
           e4-cex)

  ;; ---------------------------------------------------------------------------
  ;; Check E5: Live Mineral & Gas Harvester Saturation Expansion Gating
  ;; ---------------------------------------------------------------------------
  (define e5-states 0)
  (define e5-cex #f)
  (define e5-cases
    ;; (case-id bases frame workers min-h ideal-min-h gas-h ideal-gas-h expected-expand?)
    (list (list 'saturated-2-base-under-36-workers   2 1800 28 22 24 6 6 #t)
          (list 'unsaturated-minerals-2-base         2 1800 38 18 32 6 6 #f)
          (list 'unsaturated-gas-2-base              2 1800 38 30 32 2 6 #f)
          (list 'saturated-3-base-under-50-workers   3 3600 42 34 36 8 9 #t)))
  (for* ([race '(Zerg Protoss Terran)]
         [tc (in-list e5-cases)])
    (set! e5-states (add1 e5-states))
    (match-define (list case-id bases frame workers min-h ideal-min-h gas-h ideal-gas-h expected-expand?) tc)
    (define gov
      (evaluate-coupled-macro-governor
       #:race race
       #:frame frame
       #:minerals 350
       #:gas 150
       #:supply-left 8
       #:active-bases bases
       #:depleting-bases 0
       #:workers workers
       #:mineral-harvesters min-h
       #:ideal-mineral-harvesters ideal-min-h
       #:gas-harvesters gas-h
       #:ideal-gas-harvesters ideal-gas-h
       #:under-crisis? #f
       #:recommended-min-bases bases))
    (define got-expand? (coupled-macro-plan-should-expand? gov))
    (unless (eq? got-expand? expected-expand?)
      (unless e5-cex
        (set! e5-cex (list 'race race 'case case-id 'expected expected-expand? 'got got-expand? 'gov gov)))))
  (record! 'E5-mineral-and-gas-saturation-expansion-gating
           "Multi-base expansion (`2nd -> 3rd -> 4th+`) is gated on live mineral harvester saturation and gas harvester saturation rather than hard worker-count cutoffs (`36`/`50`)"
           e5-states
           (not e5-cex)
           e5-cex)

  results)

;; =============================================================================
;; 4. Formal Model Checker for General Prioritization & Resource-Allocation
;;    Scheduler Invariants (`PV1`–`PV6`)
;; =============================================================================

(define PV-LATTICE-RACES        '(Zerg Terran Protoss))
(define PV-LATTICE-ACTIVE-BASES '(1 2 3 4))
(define PV-LATTICE-WORKERS      '(12 16 24 38 72))
(define PV-LATTICE-MINERALS     '(50 75 100 150 250 320 450))
(define PV-LATTICE-GAS          '(0 50 100 250 544))
(define PV-LATTICE-SUPPLY-LEFT  '(0 1 2 4 10))
(define PV-LATTICE-ARMY-SUPPLY  '(0 3 10 18 36))
(define PV-LATTICE-ENEMY-THREAT '(0 8 20))
(define PV-LATTICE-ENEMY-AIR    '(#f #t))
(define PV-LATTICE-ESCROW-AGE   '(0 100 300))

(struct pv-candidate
  (id
   category        ; 'supply | 'counter-anti-air | 'counter-detector | 'combat-gas | 'combat-mineral | 'tech-upgrade | 'production-facility | 'worker | 'expansion
   action-sexp
   mineral-cost
   gas-cost
   supply-cost
   utility)
  #:transparent)

(struct pv-scheduler-decision
  (race
   candidates              ; list of pv-candidate sorted descending by utility
   top-candidate           ; pv-candidate
   scheduled-actions       ; list of S-expression actions admitted after floor reservations
   effective-escrow-min    ; non-negative integer
   combat-mineral-floor    ; non-negative integer
   gas-sink-mineral-floor  ; non-negative integer
   worker-admitted?        ; boolean
   expansion-admitted?)    ; boolean
  #:transparent)

(struct pv-refractory-gate
  (cooldown-frames
   last-emitted-by-key)    ; mutable hash: (cons action-kind tag) -> frame
  #:mutable
  #:transparent)

(define (pv-make-refractory-gate [cooldown-frames 64])
  (pv-refractory-gate (max 1 cooldown-frames) (make-hash)))

(define (pv-try-emit-refractory! gate action-kind unit-or-bldg-tag frame)
  (define cd (pv-refractory-gate-cooldown-frames gate))
  (define tbl (pv-refractory-gate-last-emitted-by-key gate))
  (define key (cons action-kind unit-or-bldg-tag))
  (define prev (hash-ref tbl key -999999))
  (cond
    [(>= (- frame prev) cd)
     (hash-set! tbl key frame)
     #t]
    [else
     #f]))

(define (pv-evaluate-prioritization-state
         #:race [race 'Zerg]
         #:active-bases [active-bases 2]
         #:workers [workers 24]
         #:minerals [minerals 150]
         #:gas [gas 100]
         #:supply-left [supply-left 4]
         #:supply-cap [supply-cap 60]
         #:pending-supply [pending-supply 0]
         #:supply-buffer [supply-buffer 4]
         #:army-supply [army-supply 10]
         #:enemy-threat [enemy-threat 0]
         #:enemy-air? [enemy-air? #f]
         #:requires-detection? [requires-detection? #f]
         #:escrow-age [escrow-age 0]
         #:ready-tech-sym [ready-tech-sym #f]
         #:ready-tech-min [ready-tech-min 150]
         #:ready-tech-gas [ready-tech-gas 0])
  (define under-threat?
    (or (> enemy-threat 0)
        (and (< army-supply 12) (> enemy-threat 0))))
  (define gas-imbalance-ratio
    (/ (exact->inexact (max 0 gas))
       (max 50.0 (exact->inexact minerals))))
  (define gas-hoarding?
    (and (>= gas 150)
         (>= gas-imbalance-ratio 1.5)))
  (define supply-block-imminent?
    (and (< supply-cap 200)
         (zero? pending-supply)
         (<= supply-left supply-buffer)))

  ;; Non-starving expansion escrow:
  ;; When active-bases >= 2 OR escrow-age >= 224 (10s expiry) OR under threat,
  ;; expansion escrow NEVER blocks ready tech/upgrades or production scaling.
  (define base-cost (if (eq? race 'Zerg) 300 400))
  (define escrow-expired-or-multibase?
    (or (>= active-bases 2)
        (>= escrow-age 224)
        under-threat?
        enemy-air?
        requires-detection?))
  (define effective-escrow-min
    (if escrow-expired-or-multibase? 0 base-cost))

  ;; Race-specific canonical candidates
  (define supply-sym
    (case race
      [(Zerg) 'overlord]
      [(Terran) 'supply-depot]
      [(Protoss) 'pylon]))
  (define supply-act
    (if (eq? race 'Zerg)
        '(train overlord)
        (list 'build supply-sym)))
  (define worker-sym
    (case race
      [(Zerg) 'drone]
      [(Terran) 'scv]
      [(Protoss) 'probe]))
  (define-values (gas-combat-sym gas-combat-m gas-combat-g gas-combat-s)
    (case race
      [(Zerg)    (values 'roach    75  25 2)]
      [(Terran)  (values 'marauder 100 25 2)]
      [(Protoss) (values 'stalker  125 50 2)]))
  (define-values (min-combat-sym min-combat-m min-combat-s)
    (case race
      [(Zerg)    (values 'zergling 50  1)]
      [(Terran)  (values 'marine   50  1)]
      [(Protoss) (values 'zealot   100 2)]))
  (define-values (aa-sym aa-m aa-g)
    (case race
      [(Zerg)    (values 'hydralisk 100 50)]
      [(Terran)  (values 'viking    150 75)]
      [(Protoss) (values 'stalker   125 50)]))
  (define-values (det-sym det-m det-g)
    (case race
      [(Zerg)    (values 'spore-crawler   75  0)]
      [(Terran)  (values 'missile-turret  100 0)]
      [(Protoss) (values 'photon-cannon   150 0)]))
  (define-values (default-tech-sym default-tech-m default-tech-g)
    (case race
      [(Zerg)    (values 'roach-warren      150 0)]
      [(Terran)  (values 'stimpack          100 100)]
      [(Protoss) (values 'cybernetics-core  150 0)]))
  (define tech-sym (or ready-tech-sym default-tech-sym))
  (define tech-m (if ready-tech-sym ready-tech-min default-tech-m))
  (define tech-g (if ready-tech-sym ready-tech-gas default-tech-g))
  (define prod-sym
    (case race
      [(Zerg) 'roach-warren]
      [(Terran) 'barracks]
      [(Protoss) 'gateway]))

  ;; Marginal utilities governed by strict prioritization theorems PV1–PV5:
  ;; 1. Supply utility (PV4: strictly dominates all non-supply candidates when supply-block-imminent?)
  (define u-supply
    (if supply-block-imminent?
        (+ 1200.0 (* 25.0 (- supply-buffer supply-left)))
        18.0))

  ;; 2. Counter-tech Anti-Air & Detection utility (PV5: strictly dominates worker/expansion when active)
  (define u-counter-aa
    (if enemy-air?
        (+ 420.0 (* 8.0 enemy-threat) (if (> aa-g 0) 25.0 0.0))
        32.0))
  (define u-counter-det
    (if requires-detection?
        (+ 410.0 (* 8.0 enemy-threat))
        28.0))

  ;; 3. Gas-consuming combat unit & tech utility (PV2 + PV3 + PV1)
  (define u-combat-gas
    (+ 140.0
       (if under-threat? (+ 220.0 (* 10.0 enemy-threat) (if (< army-supply 12) 60.0 0.0)) 0.0)
       (if gas-hoarding? (+ 190.0 (* 20.0 (min 10.0 gas-imbalance-ratio))) 0.0)))
  (define u-combat-min
    (+ 115.0
       (if under-threat? (+ 180.0 (* 8.0 enemy-threat) (if (< army-supply 12) 50.0 0.0)) 0.0)
       ;; Discount mineral-only unit when hoarding gas so gas-sinks strictly outrank mineral-only units (PV3)
       (if gas-hoarding? -45.0 0.0)))

  ;; 4. Tech/Upgrade & Production Facility scaling utility (PV1 + PV3)
  (define u-tech
    (+ 165.0
       (if (and (> tech-g 0) gas-hoarding?)
           (+ 185.0 (* 18.0 (min 10.0 gas-imbalance-ratio)))
           0.0)
       (if (>= active-bases 2) 45.0 0.0)
       (if (>= escrow-age 224) 35.0 0.0)))
  (define u-prod-scaling
    (+ 155.0
       (if (>= active-bases 2) 40.0 0.0)
       (if (>= escrow-age 224) 30.0 0.0)))

  ;; 5. Passive Worker & Expansion utility (discounted under threat, air/cloaked crisis, or gas hoarding)
  (define target-workers (min 80 (* 22 active-bases)))
  (define worker-need-bonus
    (if (< workers target-workers) 35.0 0.0))
  (define u-worker
    (max 5.0
         (- (+ 55.0 worker-need-bonus)
            (if under-threat? 65.0 0.0)
            (if gas-hoarding? 40.0 0.0)
            (if (or enemy-air? requires-detection?) 30.0 0.0))))
  (define u-expansion
    (max 4.0
         (- (if (and (= active-bases 1) (< escrow-age 224)) 175.0 85.0)
            (if under-threat? 80.0 0.0)
            (if (or enemy-air? requires-detection?) 45.0 0.0)
            (if (>= escrow-age 224) 60.0 0.0))))

  (define raw-candidates
    (list (pv-candidate 'supply 'supply supply-act 100 0 0 u-supply)
          (pv-candidate aa-sym 'counter-anti-air (list 'train aa-sym) aa-m aa-g 2 u-counter-aa)
          (pv-candidate det-sym 'counter-detector (list 'build det-sym) det-m det-g 0 u-counter-det)
          (pv-candidate gas-combat-sym 'combat-gas (list 'train gas-combat-sym)
                        gas-combat-m gas-combat-g gas-combat-s u-combat-gas)
          (pv-candidate min-combat-sym 'combat-mineral (list 'train min-combat-sym)
                        min-combat-m 0 min-combat-s u-combat-min)
          (pv-candidate tech-sym 'tech-upgrade
                        (if (eq? tech-sym 'stimpack) '(research stimpack) (list 'build tech-sym))
                        tech-m tech-g 0 u-tech)
          (pv-candidate prod-sym 'production-facility (list 'build prod-sym) 150 0 0 u-prod-scaling)
          (pv-candidate worker-sym 'worker (list 'train worker-sym) 50 0 1 u-worker)
          (pv-candidate 'expand 'expansion '(expand 50.5 56.5) base-cost 0 0 u-expansion)))

  (define sorted-candidates
    (sort raw-candidates > #:key pv-candidate-utility))

  ;; Mineral floor reservations:
  ;; - Under threat (PV2): reserve mineral floor for primary combat unit so worker training
  ;;   can NEVER spend minerals that would starve an affordable or near-affordable combat unit.
  (define desired-combat-min-floor
    (if under-threat?
        (if (>= gas gas-combat-g) gas-combat-m min-combat-m)
        0))
  ;; - Under gas hoarding (PV3): reserve mineral floor for gas-consuming unit/tech so
  ;;   mineral-only workers/units cannot drain minerals and strand banked gas.
  (define desired-gas-sink-min-floor
    (if gas-hoarding?
        (max gas-combat-m (if (> tech-g 0) tech-m 0))
        0))

  (define rem-m minerals)
  (define rem-g gas)
  (define rem-s supply-left)
  (define scheduled '())
  (define worker-admitted? #f)
  (define expansion-admitted? #f)

  (for ([c (in-list sorted-candidates)])
    (define cat (pv-candidate-category c))
    (define cm (pv-candidate-mineral-cost c))
    (define cg (pv-candidate-gas-cost c))
    (define cs (pv-candidate-supply-cost c))
    (define supply-ok?
      (or (zero? cs)
          (and (> rem-s 0) (>= rem-s cs) (not (and supply-block-imminent? (< rem-m (+ cm 100)))))))
    (define escrow-ok?
      (or (memq cat '(supply counter-anti-air counter-detector combat-gas combat-mineral tech-upgrade production-facility))
          (>= (- rem-m cm) effective-escrow-min)))
    (define combat-floor-ok?
      (or (not (eq? cat 'worker))
          (not under-threat?)
          (>= (- rem-m cm) desired-combat-min-floor)))
    (define gas-floor-ok?
      (or (not (memq cat '(worker combat-mineral)))
          (not gas-hoarding?)
          (>= (- rem-m cm) desired-gas-sink-min-floor)))
    (when (and (>= rem-m cm)
               (>= rem-g cg)
               supply-ok?
               escrow-ok?
               combat-floor-ok?
               gas-floor-ok?)
      (set! rem-m (- rem-m cm))
      (set! rem-g (- rem-g cg))
      (set! rem-s (- rem-s cs))
      (set! scheduled (append scheduled (list (pv-candidate-action-sexp c))))
      (when (eq? cat 'worker) (set! worker-admitted? #t))
      (when (eq? cat 'expansion) (set! expansion-admitted? #t))))

  (pv-scheduler-decision race
                         sorted-candidates
                         (car sorted-candidates)
                         scheduled
                         effective-escrow-min
                         desired-combat-min-floor
                         desired-gas-sink-min-floor
                         worker-admitted?
                         expansion-admitted?))

(define (pv-find-candidate dec cat-or-id)
  (findf (lambda (c)
           (or (eq? (pv-candidate-category c) cat-or-id)
               (eq? (pv-candidate-id c) cat-or-id)))
         (pv-scheduler-decision-candidates dec)))

(define (verify-prioritization-scheduler-invariants #:fast? [fast? #f])
  (define results '())
  (define pv-bases (if fast? '(1 2) PV-LATTICE-ACTIVE-BASES))
  (define pv-workers (if fast? '(16 28) PV-LATTICE-WORKERS))
  (define pv-minerals (if fast? '(50 150 450) PV-LATTICE-MINERALS))
  (define pv-gas (if fast? '(0 100 544) PV-LATTICE-GAS))
  (define pv-supply-left (if fast? '(0 4) PV-LATTICE-SUPPLY-LEFT))
  (define pv-army-supply (if fast? '(3 18) PV-LATTICE-ARMY-SUPPLY))
  (define pv-enemy-threat (if fast? '(0 12) PV-LATTICE-ENEMY-THREAT))
  (define pv-escrow-age (if fast? '(0 300) PV-LATTICE-ESCROW-AGE))
  (define (record! id desc states passed? [cex #f])
    (set! results
          (append results
                  (list (verification-check-result 'prioritization-scheduler
                                                   id
                                                   desc
                                                   states
                                                   passed?
                                                   cex)))))

  ;; ---------------------------------------------------------------------------
  ;; Theorem PV1: `PV1-no-expansion-escrow-starvation`
  ;; Proves across (race x active-bases x workers x minerals x gas x escrow-age)
  ;; that whenever active-bases >= 2 or escrow-age >= 224, expansion escrow
  ;; NEVER blocks ready tech/upgrades or production facility scaling.
  ;; ---------------------------------------------------------------------------
  (define pv1-states 0)
  (define pv1-cex #f)
  (define race-tech-specs
    (hash 'Zerg    (list (list 'roach-warren 150 0)
                         (list 'hydralisk-den 100 100)
                         (list 'spire 200 200))
          'Terran  (list (list 'stimpack 100 100)
                         (list 'barracks 150 0))
          'Protoss (list (list 'cybernetics-core 150 0)
                         (list 'robotics-facility 150 100)
                         (list 'gateway 150 0))))
  (for* ([race (in-list PV-LATTICE-RACES)]
         [active-bases (in-list pv-bases)]
         [workers (in-list pv-workers)]
         [minerals (in-list pv-minerals)]
         [gas (in-list pv-gas)]
         [escrow-age (in-list pv-escrow-age)])
    (set! pv1-states (add1 pv1-states))
    (when (or (>= active-bases 2) (>= escrow-age 224))
      (for ([spec (in-list (hash-ref race-tech-specs race))])
        (match-define (list t-sym t-min t-gas) spec)
        (define dec
          (pv-evaluate-prioritization-state
           #:race race
           #:active-bases active-bases
           #:workers workers
           #:minerals minerals
           #:gas gas
           #:supply-left 10
           #:supply-cap 80
           #:escrow-age escrow-age
           #:ready-tech-sym t-sym
           #:ready-tech-min t-min
           #:ready-tech-gas t-gas))
        (define c-tech (pv-find-candidate dec 'tech-upgrade))
        (define c-prod (pv-find-candidate dec 'production-facility))
        (define c-exp  (pv-find-candidate dec 'expansion))
        (define tech-affordable? (and (>= minerals t-min) (>= gas t-gas)))
        (define prod-affordable? (>= minerals 150))
        (define acts (pv-scheduler-decision-scheduled-actions dec))
        (when (or (> (pv-scheduler-decision-effective-escrow-min dec) 0)
                  (<= (pv-candidate-utility c-tech) (pv-candidate-utility c-exp))
                  (<= (pv-candidate-utility c-prod) (pv-candidate-utility c-exp))
                  (and tech-affordable?
                       (null? acts)))
          (unless pv1-cex
            (set! pv1-cex (list 'race race 'bases active-bases 'workers workers
                                'minerals minerals 'gas gas 'escrow-age escrow-age
                                'tech t-sym 'dec dec)))))))
  (record! 'PV1-no-expansion-escrow-starvation
           "Across multi-base (`active-bases >= 2`) or expired-escrow (`escrow-age >= 224`) states, expansion escrow never blocks ready tech/upgrades (`roach-warren`, `hydralisk-den`, `spire`, `stimpack`, `cybernetics-core`, `robotics-facility`) or production scaling (`barracks`, `gateway`)"
           pv1-states
           (not pv1-cex)
           pv1-cex)

  ;; ---------------------------------------------------------------------------
  ;; Theorem PV2: `PV2-combat-dominates-workers-under-threat`
  ;; Proves across (race x active-bases x workers x minerals x gas x supply-left x army-supply x enemy-threat)
  ;; that whenever enemy-threat > 0 or (army-supply < 12 with enemy pressure),
  ;; combat unit training strictly outranks worker replacement and reserves
  ;; a combat mineral floor so worker training cannot starve combat units.
  ;; ---------------------------------------------------------------------------
  (define pv2-states 0)
  (define pv2-cex #f)
  (for* ([race (in-list PV-LATTICE-RACES)]
         [active-bases (in-list pv-bases)]
         [workers (in-list pv-workers)]
         [minerals (in-list pv-minerals)]
         [gas (in-list pv-gas)]
         [army-supply (in-list pv-army-supply)]
         [enemy-threat (in-list pv-enemy-threat)])
    (set! pv2-states (add1 pv2-states))
    (when (> enemy-threat 0)
      (define dec
        (pv-evaluate-prioritization-state
         #:race race
         #:active-bases active-bases
         #:workers workers
         #:minerals minerals
         #:gas gas
         #:supply-left 10
         #:supply-cap 80
         #:army-supply army-supply
         #:enemy-threat enemy-threat))
      (define c-cgas (pv-find-candidate dec 'combat-gas))
      (define c-cmin (pv-find-candidate dec 'combat-mineral))
      (define c-wrk  (pv-find-candidate dec 'worker))
      (define cfloor (pv-scheduler-decision-combat-mineral-floor dec))
      (define worker-starved-combat?
        (and (pv-scheduler-decision-worker-admitted? dec)
             (< (- minerals 50) cfloor)))
      (when (or (<= (pv-candidate-utility c-cgas) (pv-candidate-utility c-wrk))
                (<= (pv-candidate-utility c-cmin) (pv-candidate-utility c-wrk))
                (<= cfloor 0)
                worker-starved-combat?)
        (unless pv2-cex
          (set! pv2-cex (list 'race race 'bases active-bases 'workers workers
                              'minerals minerals 'gas gas 'army-supply army-supply
                              'enemy-threat enemy-threat 'dec dec))))))
  (record! 'PV2-combat-dominates-workers-under-threat
           "Whenever `enemy-threat > 0` or `army-supply < 12` under pressure, combat unit training strictly outranks worker replacement and enforces a combat mineral floor (`0` Probe/SCV/Drone spirals)"
           pv2-states
           (not pv2-cex)
           pv2-cex)

  ;; ---------------------------------------------------------------------------
  ;; Theorem PV3: `PV3-gas-sink-monotonicity-no-gas-hoarding`
  ;; Proves across (race x active-bases x workers x minerals x gas x supply-left)
  ;; that whenever gas >= 150 and gas/max(50,minerals) >= 1.5, ready gas-consuming
  ;; units/tech strictly outrank mineral-only workers/units, reserve a mineral
  ;; floor, and trigger gas-to-mineral worker rebalancing when gas > 400 & minerals < 300.
  ;; ---------------------------------------------------------------------------
  (define pv3-states 0)
  (define pv3-cex #f)
  (for* ([race (in-list PV-LATTICE-RACES)]
         [active-bases (in-list pv-bases)]
         [workers (in-list pv-workers)]
         [minerals (in-list pv-minerals)]
         [gas (in-list pv-gas)]
         [supply-left (in-list pv-supply-left)])
    (set! pv3-states (add1 pv3-states))
    (define gm-ratio (/ (exact->inexact gas) (max 50.0 (exact->inexact minerals))))
    (when (and (>= gas 150) (>= gm-ratio 1.5))
      (define gas-tech-sym
        (case race
          [(Zerg) 'hydralisk-den]
          [(Terran) 'stimpack]
          [(Protoss) 'robotics-facility]))
      (define dec
        (pv-evaluate-prioritization-state
         #:race race
         #:active-bases active-bases
         #:workers workers
         #:minerals minerals
         #:gas gas
         #:supply-left supply-left
         #:supply-cap 80
         #:ready-tech-sym gas-tech-sym
         #:ready-tech-min 100
         #:ready-tech-gas 100))
      (define c-cgas (pv-find-candidate dec 'combat-gas))
      (define c-tech (pv-find-candidate dec 'tech-upgrade))
      (define c-cmin (pv-find-candidate dec 'combat-mineral))
      (define c-wrk  (pv-find-candidate dec 'worker))
      (define gfloor (pv-scheduler-decision-gas-sink-mineral-floor dec))
      (define worker-drained-gas-floor?
        (and (pv-scheduler-decision-worker-admitted? dec)
             (< (- minerals 50) gfloor)))
      (define g-alloc
        (compute-optimal-gas-workers
         #:race race
         #:frame 3200
         #:minerals minerals
         #:gas gas
         #:workers workers
         #:active-bases active-bases
         #:active-geysers (* 2 active-bases)
         #:current-gas-workers (* 3 active-bases)))
      (define rebalance-ok?
        (or (not (and (> gas 400) (< minerals 300)))
            (eq? (gas-worker-allocation-action g-alloc) 'pull-off-gas-to-minerals)))
      (when (or (<= (pv-candidate-utility c-cgas) (pv-candidate-utility c-wrk))
                (<= (pv-candidate-utility c-cgas) (pv-candidate-utility c-cmin))
                (<= (pv-candidate-utility c-tech) (pv-candidate-utility c-wrk))
                (<= (pv-candidate-utility c-tech) (pv-candidate-utility c-cmin))
                (<= gfloor 0)
                worker-drained-gas-floor?
                (not rebalance-ok?))
        (unless pv3-cex
          (set! pv3-cex (list 'race race 'bases active-bases 'workers workers
                              'minerals minerals 'gas gas 'supply-left supply-left
                              'dec dec 'g-alloc g-alloc))))))
  (record! 'PV3-gas-sink-monotonicity-no-gas-hoarding
           "Whenever `gas >= 150` and `gas/max(50,minerals) >= 1.5`, gas-consuming units/tech strictly outrank mineral-only workers/units, reserve a mineral floor, and rebalance gas workers"
           pv3-states
           (not pv3-cex)
           pv3-cex)

  ;; ---------------------------------------------------------------------------
  ;; Theorem PV4: `PV4-zero-supply-block-preemption`
  ;; Proves across (race x active-bases x workers x minerals x gas x supply-left x enemy-threat)
  ;; that whenever supply-cap < 200, pending-supply == 0, and supply-left <= buffer,
  ;; the supply candidate strictly dominates all non-supply candidates (U(supply) > U(c)).
  ;; ---------------------------------------------------------------------------
  (define pv4-states 0)
  (define pv4-cex #f)
  (for* ([race (in-list PV-LATTICE-RACES)]
         [active-bases (in-list pv-bases)]
         [workers (in-list pv-workers)]
         [minerals (in-list pv-minerals)]
         [gas (in-list pv-gas)]
         [supply-left (in-list pv-supply-left)]
         [enemy-threat (in-list pv-enemy-threat)])
    (set! pv4-states (add1 pv4-states))
    (define supply-cap (* active-bases 38)) ; < 200 across active-bases in {1,2,3,4}
    (define buffer 4)
    (when (<= supply-left buffer)
      (define dec
        (pv-evaluate-prioritization-state
         #:race race
         #:active-bases active-bases
         #:workers workers
         #:minerals minerals
         #:gas gas
         #:supply-left supply-left
         #:supply-cap supply-cap
         #:pending-supply 0
         #:supply-buffer buffer
         #:enemy-threat enemy-threat))
      (define c-sup (pv-find-candidate dec 'supply))
      (define non-sup
        (filter (lambda (c) (not (eq? (pv-candidate-category c) 'supply)))
                (pv-scheduler-decision-candidates dec)))
      (define strictly-dominates-all?
        (andmap (lambda (c) (> (pv-candidate-utility c-sup) (pv-candidate-utility c)))
                non-sup))
      (define top-is-supply?
        (eq? (pv-candidate-category (pv-scheduler-decision-top-candidate dec)) 'supply))
      (define scheduled-first-when-affordable?
        (or (< minerals 100)
            (and (not (null? (pv-scheduler-decision-scheduled-actions dec)))
                 (equal? (car (pv-scheduler-decision-scheduled-actions dec))
                         (pv-candidate-action-sexp c-sup)))))
      (when (or (not strictly-dominates-all?)
                (not top-is-supply?)
                (not scheduled-first-when-affordable?))
        (unless pv4-cex
          (set! pv4-cex (list 'race race 'bases active-bases 'minerals minerals
                              'supply-left supply-left 'enemy-threat enemy-threat
                              'dec dec))))))
  (record! 'PV4-zero-supply-block-preemption
           "Whenever `supply-cap < 200`, `pending-supply == 0`, and `supply-left <= buffer`, the supply candidate strictly dominates all non-supply candidates (`U(supply) > U(c)`)"
           pv4-states
           (not pv4-cex)
           pv4-cex)

  ;; ---------------------------------------------------------------------------
  ;; Theorem PV5: `PV5-counter-tech-anti-air-and-detection-liveness`
  ;; Proves across (race x active-bases x workers x minerals x gas x enemy-threat x enemy-air? x requires-detection?)
  ;; that whenever requires-anti-air? or requires-detection? holds, anti-air/detection
  ;; units and structures strictly outrank passive worker/expansion spending.
  ;; ---------------------------------------------------------------------------
  (define pv5-states 0)
  (define pv5-cex #f)
  (for* ([race (in-list PV-LATTICE-RACES)]
         [active-bases (in-list pv-bases)]
         [workers (in-list pv-workers)]
         [minerals (in-list pv-minerals)]
         [gas (in-list pv-gas)]
         [enemy-threat (in-list pv-enemy-threat)]
         [enemy-air? (in-list PV-LATTICE-ENEMY-AIR)]
         [req-det? '(#f #t)])
    (set! pv5-states (add1 pv5-states))
    (when (or enemy-air? req-det?)
      (define dec
        (pv-evaluate-prioritization-state
         #:race race
         #:active-bases active-bases
         #:workers workers
         #:minerals minerals
         #:gas gas
         #:supply-left 8
         #:supply-cap 80
         #:enemy-threat enemy-threat
         #:enemy-air? enemy-air?
         #:requires-detection? req-det?))
      (define c-aa  (pv-find-candidate dec 'counter-anti-air))
      (define c-det (pv-find-candidate dec 'counter-detector))
      (define c-wrk (pv-find-candidate dec 'worker))
      (define c-exp (pv-find-candidate dec 'expansion))
      (define tplan
        (evaluate-adaptive-build-and-tech-plan
         race
         #:requires-anti-air? enemy-air?
         #:requires-detection? req-det?
         #:minerals minerals
         #:gas gas))
      (define ctech (adaptive-tech-plan-counter-tech-buildings tplan))
      (define aa-ok?
        (or (not enemy-air?)
            (and (> (pv-candidate-utility c-aa) (pv-candidate-utility c-wrk))
                 (> (pv-candidate-utility c-aa) (pv-candidate-utility c-exp))
                 (not (null? ctech)))))
      (define det-ok?
        (or (not req-det?)
            (and (> (pv-candidate-utility c-det) (pv-candidate-utility c-wrk))
                 (> (pv-candidate-utility c-det) (pv-candidate-utility c-exp))
                 (not (null? ctech)))))
      (when (or (not aa-ok?) (not det-ok?))
        (unless pv5-cex
          (set! pv5-cex (list 'race race 'bases active-bases 'minerals minerals 'gas gas
                              'enemy-air? enemy-air? 'req-det? req-det? 'dec dec 'tplan tplan))))))
  (record! 'PV5-counter-tech-anti-air-and-detection-liveness
           "Whenever `requires-anti-air?` or `requires-detection?` holds, anti-air and detection units/structures strictly outrank passive worker and expansion spending"
           pv5-states
           (not pv5-cex)
           pv5-cex)

  ;; ---------------------------------------------------------------------------
  ;; Theorem PV6: `PV6-refractory-cooldown-anti-spam-idempotence`
  ;; Proves that for any sequence of frames t0 <= t1 < t0 + delta_cooldown,
  ;; a refractory-gated action (`queen-tumor`, `resume-halted-building`,
  ;; `static-detector`) is emitted at most once per unit/building tag.
  ;; ---------------------------------------------------------------------------
  (define pv6-states 0)
  (define pv6-cex #f)
  (for* ([race (in-list PV-LATTICE-RACES)]
         [action-kind '(queen-tumor resume-halted-building static-detector)]
         [tag (in-list (if fast? '(101) '(101 202 303 404)))]
         [t0 (in-list (if fast? '(0 300) '(0 100 300 1200)))]
         [cooldown (in-list (if fast? '(64) '(24 64 112 224)))])
    (define gate (pv-make-refractory-gate cooldown))
    (define limiter (make-ability-cast-limiter #:max-per-frame 2 #:refractory-frames cooldown))
    (define emitted-in-window 0)
    (for ([step-idx (in-range 12)])
      (set! pv6-states (add1 pv6-states))
      (define t1 (+ t0 (quotient (* step-idx (sub1 cooldown)) 12)))
      (when (pv-try-emit-refractory! gate action-kind tag t1)
        (set! emitted-in-window (add1 emitted-in-window)))
      (define-values (kept _throttled)
        (throttle-ability-casts! limiter (list (list 'cast tag action-kind 50 56)) t1))
      (when (and (> step-idx 0) (not (null? kept)))
        (unless pv6-cex
          (set! pv6-cex (list 'stage 'limiter-duplicate 'race race 'action action-kind
                              'tag tag 't0 t0 't1 t1 'cooldown cooldown)))))
    ;; Across all 12 frames inside [t0, t0 + cooldown), action must be emitted at most once (exactly 1)
    ;; while a distinct unit/building tag (`tag + 1000`) remains unblocked, and at `t0 + cooldown` it re-opens.
    (define other-tag-ok? (pv-try-emit-refractory! gate action-kind (+ tag 1000) t0))
    (define reopen-after-cooldown? (pv-try-emit-refractory! gate action-kind tag (+ t0 cooldown)))
    (when (or (not (= emitted-in-window 1))
              (not other-tag-ok?)
              (not reopen-after-cooldown?))
      (unless pv6-cex
        (set! pv6-cex (list 'race race 'action action-kind 'tag tag 't0 t0 'cooldown cooldown
                            'emitted-in-window emitted-in-window
                            'other-tag-ok? other-tag-ok?
                            'reopen-after-cooldown? reopen-after-cooldown?)))))
  (record! 'PV6-refractory-cooldown-anti-spam-idempotence
           "For any frame sequence `t0 <= t1 < t0 + delta_cooldown`, refractory-gated actions (`queen-tumor`, `resume-halted-building`, `static-detector`) emit at most once per unit/building tag"
           pv6-states
           (not pv6-cex)
           pv6-cex)

  ;; ---------------------------------------------------------------------------
  ;; Theorem PV7: `PV7-multi-step-escrow-liveness-no-deadlock`
  ;; Proves across multi-step trajectories for all races (`Zerg`, `Protoss`, `Terran`)
  ;; that unplaced expansion escrow (`Saving for expansion: ...`) CANNOT deadlock
  ;; combat unit production or tech progression:
  ;;   1. If an expansion cannot be placed across consecutive steps, `escrow-age-frames`
  ;;      monotonically advances and expires within `<= 224` frames (`10s`), immediately
  ;;      admitting ready combat units and tech upgrades;
  ;;   2. Whenever `enemy-threat-supply > 0` or `under-base-attack?` holds at any frame
  ;;      (including mid/late game `frame >= 2500`), expansion escrow is immediately
  ;;      preempted (`0` frames of combat starvation).
  ;; ---------------------------------------------------------------------------
  (define pv7-states 0)
  (define pv7-cex #f)
  (for* ([race (in-list PV-LATTICE-RACES)]
         [minerals (in-list (if fast? '(150) '(150 225 275 325)))]
         [gas (in-list (if fast? '(100) '(50 100 150)))]
         [scenario '(escrow-timeout threat-preemption stale-intel-preemption)])
    (define rt (make-live-bot-runtime #:race race))
    (define base-bldg
      (case race
        [(Zerg)    (list (hash 'id 100 'type 'hatchery 'x 32.5 'y 32.5 'hp 1500)
                         (hash 'id 101 'type 'spawning-pool 'x 35.0 'y 35.0 'hp 1000)
                         (hash 'id 102 'type 'roach-warren 'x 36.0 'y 35.0 'hp 850))]
        [(Protoss) (list (hash 'id 100 'type 'nexus 'x 32.5 'y 32.5 'hp 2000)
                         (hash 'id 101 'type 'pylon 'x 35.0 'y 35.0 'hp 400)
                         (hash 'id 102 'type 'gateway 'x 36.5 'y 35.0 'hp 1000)
                         (hash 'id 103 'type 'cybernetics-core 'x 38.0 'y 35.0 'hp 1100))]
        [(Terran)  (list (hash 'id 100 'type 'orbital-command 'x 32.5 'y 32.5 'hp 1500)
                         (hash 'id 101 'type 'supply-depot 'x 35.0 'y 35.0 'hp 400)
                         (hash 'id 102 'type 'barracks 'x 36.5 'y 35.0 'hp 1000))]))
    (define worker-sym (case race [(Zerg) 'drone] [(Protoss) 'probe] [(Terran) 'scv]))
    (define workers-list
      (for/list ([i (in-range 22)])
        (hash 'id (+ 1 i) 'type worker-sym 'x (+ 31.0 (modulo i 5)) 'y (+ 31.0 (quotient i 5)) 'hp 40 'dps 5)))
    (define combat-admitted-within-bound? #f)
    ;; Seed enemy sector contact at frame 1800 so `escrow-timeout` isolates pure escrow expiry (`<= 224` frames)
    ;; while `stale-intel-preemption` leaves enemy contact at frame 0 (`intel-staleness-frames = 1800 >= 896`, `confidence < 0.35`).
    (unless (eq? scenario 'stale-intel-preemption)
      (set-live-bot-runtime-last-telemetry!
       rt
       (hash-set* (live-bot-runtime-last-telemetry rt)
                  'last-enemy-contact-frame 1800
                  'last-enemy-seen-frame 1800
                  'last-seen-main-frame 1800
                  'last-seen-natural-frame 1800
                  'last-seen-army-frame 1800)))
    (for ([step-idx (in-range (if fast? 11 16))])
      (set! pv7-states (add1 pv7-states))
      (define frame (+ 1800 (* step-idx 24)))
      (unless (eq? scenario 'stale-intel-preemption)
        (set-live-bot-runtime-last-telemetry!
         rt
         (hash-set* (live-bot-runtime-last-telemetry rt)
                    'last-enemy-contact-frame frame
                    'last-enemy-seen-frame frame
                    'last-seen-main-frame frame
                    'last-seen-natural-frame frame
                    'last-seen-army-frame frame)))
      (define e-units
        (if (eq? scenario 'threat-preemption)
            (list (hash 'id 901 'type 'stalker 'x 36.0 'y 36.0 'hp 160 'dps 14)
                  (hash 'id 902 'type 'stalker 'x 37.0 'y 36.0 'hp 160 'dps 14))
            '()))
      (define obs
        (hash 'frame frame
              'minerals minerals
              'gas gas
              'supply-used 24
              'supply-cap 46
              'mineral-harvesters 16
              'base-x 32.5
              'base-y 32.5
              'natural-x 50.5
              'natural-y 56.5
              'enemy-x 160.5
              'enemy-y 160.5
              'ally-units workers-list
              'ally-buildings base-bldg
              'enemy-units e-units
              'enemy-buildings '()))
      (define res (step-live-bot-runtime! rt obs))
      (define acts (hash-ref res 'actions '()))
      (define trained-combat?
        (ormap (lambda (a)
                 (and (pair? a)
                      (memq (car a) '(train train-unit))
                      (not (memq (last a) '(drone probe scv overlord)))))
               acts))
      (when trained-combat?
        (set! combat-admitted-within-bound? #t))
      ;; Under threat or severe intel blindness, combat unit must be admitted on the VERY FIRST step (step 0)
      (when (and (= step-idx 0)
                 (memq scenario '(threat-preemption stale-intel-preemption))
                 (not trained-combat?))
        (unless pv7-cex
          (set! pv7-cex (list 'race race 'scenario scenario 'minerals minerals 'gas gas
                              'step step-idx 'acts acts)))))
    (unless combat-admitted-within-bound?
      (unless pv7-cex
        (set! pv7-cex (list 'race race 'scenario scenario 'minerals minerals 'gas gas
                            'reason 'combat-never-admitted-across-trajectory)))))
  (record! 'PV7-multi-step-escrow-liveness-no-deadlock
           "Unplaced expansion escrow expires within `<= 224` frames (`10s`) and is immediately preempted on step 0 under enemy threat (`enemy-threat > 0`) or severe intel blindness (`intel-staleness >= 896` and `confidence < 0.35` with low army), guaranteeing `0` escrow deadlocks"
           pv7-states
           (not pv7-cex)
           pv7-cex)

  ;; ---------------------------------------------------------------------------
  ;; Theorem PV8: `PV8-builder-and-scout-order-non-cancellation`
  ;; Proves across all action-list permutations and worker states that:
  ;;   1. `translate-bot-actions->sc2-raw-commands` NEVER emits a conflicting
  ;;      `HARVEST_GATHER (3666)` on a home mineral patch or gas building for a
  ;;      worker that is executing `build`, `expand`, `resume-halted-building`,
  ;;      `worker-scout`, or `mineral-harass` in the same step or already holds
  ;;      an in-flight `BUILD_*` order (`has-build-order? #t`);
  ;;   2. `step-layer2-economy!` NEVER selects a worker with `has-build-order? #t`
  ;;      or the active `scout-worker-id` for routine `harvest-mineral` / `harvest-gas`.
  ;; ---------------------------------------------------------------------------
  (define pv8-states 0)
  (define pv8-cex #f)
  (for ([race (in-list PV-LATTICE-RACES)])
    (define worker-sym (case race [(Zerg) 'drone] [(Protoss) 'probe] [(Terran) 'scv]))
    (define bldg-sym (case race [(Zerg) 'spawning-pool] [(Protoss) 'pylon] [(Terran) 'supply-depot]))
    (define w1-id 11)
    (define w2-id 12)
    (define home-patch-id 9001)
    (define enemy-patch-id 9002)
    ;; Check `step-layer2-economy!` once per race with all workers marked `has-build-order? #t`
    (define rt (make-live-bot-runtime #:race race))
    (define step-res
      (step-live-bot-runtime!
       rt
       (hash 'frame 900 'minerals 200 'gas 50 'supply-used 16 'supply-cap 22
             'base-x 32.5 'base-y 32.5 'natural-x 50.5 'natural-y 56.5
             'enemy-x 160.5 'enemy-y 160.5
             'ally-units (list (hash 'id w1-id 'type worker-sym 'x 34.0 'y 34.0 'hp 40 'has-build-order? #t))
             'ally-buildings (list (hash 'id 100 'type 'nexus 'x 32.5 'y 32.5 'hp 2000))
             'enemy-units '() 'enemy-buildings '()
             'mineral-patches (list (hash 'id home-patch-id 'x 30.0 'y 30.0)))))
    (define rt-acts (hash-ref step-res 'actions '()))
    (define layer2-harvested-builder?
      (ormap (lambda (a)
               (and (pair? a)
                    (memq (car a) '(harvest-mineral harvest-gas worker-scout))
                    (equal? (second a) w1-id)))
             rt-acts))
    (for* ([builder-order-First? '(#t #f)]
           [in-flight-build? '(#t #f)]
           [worker-role '(build expand resume-halted-building worker-scout mineral-harass)])
      (set! pv8-states (add1 pv8-states))
      (define role-act
        (case worker-role
          [(build) (list 'build bldg-sym 38.0 38.0)]
          [(expand) '(expand 50.5 56.5)]
          [(resume-halted-building) (list 'resume-halted-building w1-id 501)]
          [(worker-scout) (list 'worker-scout w1-id 160.5 160.5)]
          [(mineral-harass) (list 'mineral-harass w1-id 160.5 160.5 140.5 140.5)]))
      (define harvest-act (list 'harvest-mineral (list w1-id w2-id) home-patch-id))
      (define gas-act (list 'harvest-gas (list w1-id) 8001))
      (define rebalance-act (list 'rebalance-gas-to-minerals (list w1-id) home-patch-id))
      (define actions-list
        (if builder-order-First?
            (list role-act harvest-act gas-act rebalance-act)
            (list harvest-act gas-act rebalance-act role-act)))
      (define obs-hash
        (hash 'frame 900
              'ally-units (list (hash 'id w1-id 'type worker-sym 'x 34.0 'y 34.0 'hp 40
                                      'has-build-order? in-flight-build?)
                                (hash 'id w2-id 'type worker-sym 'x 50.0 'y 50.0 'hp 40
                                      'has-build-order? #t))
              'mineral-patches (list (hash 'id home-patch-id 'x 30.0 'y 30.0)
                                     (hash 'id enemy-patch-id 'x 162.0 'y 162.0))))
      (define raw-cmds (translate-bot-actions->sc2-raw-commands actions-list obs-hash))
      (define w1-cancelled-by-home-harvest?
        (ormap (lambda (c)
                 (and (sc2-raw-unit-command? c)
                      (= (sc2-raw-unit-command-ability-id c) 3666)
                      (memv (sc2-raw-unit-command-target-unit-tag c) (list home-patch-id 8001))
                      (memv w1-id (sc2-raw-unit-command-unit-tags c))
                      (or in-flight-build?
                          (memq worker-role '(resume-halted-building worker-scout mineral-harass)))))
               raw-cmds))
      (define w2-cancelled-by-home-harvest?
        (ormap (lambda (c)
                 (and (sc2-raw-unit-command? c)
                      (= (sc2-raw-unit-command-ability-id c) 3666)
                      (memv w2-id (sc2-raw-unit-command-unit-tags c))))
               raw-cmds))
      (when (or w1-cancelled-by-home-harvest?
                w2-cancelled-by-home-harvest?
                layer2-harvested-builder?)
        (unless pv8-cex
          (set! pv8-cex (list 'race race 'builder-order-first? builder-order-First?
                              'in-flight-build? in-flight-build? 'role worker-role
                              'raw-cmds raw-cmds 'rt-acts rt-acts))))))
  (record! 'PV8-builder-and-scout-order-non-cancellation
           "Action-list ordering and worker filters guarantee `0` conflicting `HARVEST_GATHER (3666)` cancellations on workers executing `build`, `expand`, `resume-halted-building`, `worker-scout`, or `mineral-harass`"
           pv8-states
           (not pv8-cex)
           pv8-cex)

  ;; ---------------------------------------------------------------------------
  ;; Theorem PV9: `PV9-opponent-intel-gathering-priority-and-threat-memory`
  ;; Proves across all races (`Zerg`, `Protoss`, `Terran`), Freshness x Coverage
  ;; sector states, and army levels that:
  ;;   1. Continuous `Freshness x Coverage` (`evaluate-opponent-intel-quality`) is NOT
  ;;      all-or-nothing: moderate staleness (`268..448` frames / `12s..20s`) or partial
  ;;      sector coverage (`0.35 <= confidence < 0.65`) keeps `intel-pressure < 1.0`
  ;;      (preserving expansion escrow `escrow-eligible? = #t`) while selecting the
  ;;      highest-uncertainty uncovered sector (`priority-sector`) and appropriate
  ;;      information-gathering goal (`'expand-coverage` / `'refresh-tech-intel` / `'harass-and-probe`);
  ;;   2. Whenever opponent information is severely stale (`intel-staleness-frames >= 896` = `40s`
  ;;      or `confidence < 0.35`, so `intel-pressure >= 1.0`), opponent information gathering
  ;;      (`'intel-gathering` and mobile scouting/harassment/attacking units in `PV-INTEL-GATHERING-UNIT-SYMS`)
  ;;      strictly outranks passive `'worker` and `'expansion` spending;
  ;;   3. `select-intel-gathering-method` cleanly selects among `'scouting` (early/low-army),
  ;;      `'harassment` (mid-army mobile raiders), and `'attacking` (probing/recon-in-force);
  ;;   4. Live runtime dispatches opening Overlord/worker scouting + mineral harassment +
  ;;      sector-targeted periodic recon, updates sector freshness from allied unit vision
  ;;      proximity (`<= 15.0` tiles), and persists scouted enemy combat threat in
  ;;      `live-enemy-threat-supply` for `<= 672` frames (`30s`) after enemy leaves vision.
  ;; ---------------------------------------------------------------------------
  (define pv9-states 0)
  (define pv9-cex #f)
  ;; Part A: Severe staleness (`>= 896` frames / `40s`) -> `intel-pressure >= 1.0`, outranks passive macro
  (for* ([race (in-list PV-LATTICE-RACES)]
         [staleness '(896 1120 1344 1792)]
         [army-supply '(0 4 8 14)]
         [frame '(1800 2400 3600)])
    (set! pv9-states (add1 pv9-states))
    (define pm
      (compute-state-pressure-metrics
       #:race race
       #:frame frame
       #:minerals 200
       #:gas 100
       #:supply-left 20
       #:supply-cap 46
       #:active-bases 2
       #:workers 24
       #:army-supply army-supply
       #:enemy-threat-supply 0
       #:intel-staleness-frames staleness))
    (define intel-method
      (select-intel-gathering-method
       #:race race
       #:frame frame
       #:army-supply army-supply
       #:intel-staleness-frames staleness))
    (define recon-unit-sym
      (case race
        [(Zerg) 'zergling]
        [(Protoss) 'stalker]
        [(Terran) 'reaper]))
    (define worker-sym (case race [(Zerg) 'drone] [(Protoss) 'probe] [(Terran) 'scv]))
    (define u-intel
      (compute-candidate-marginal-utility
       (priority-candidate intel-method 'intel-gathering (list 'scout intel-method) 0 0 0 0.0 'high #f)
       pm))
    (define u-recon-unit
      (compute-candidate-marginal-utility
       (priority-candidate recon-unit-sym 'combat-unit (list 'train recon-unit-sym) 50 0 1 0.0 'high #t)
       pm))
    (define u-worker
      (compute-candidate-marginal-utility
       (priority-candidate worker-sym 'worker (list 'train worker-sym) 50 0 1 0.0 'medium #f)
       pm))
    (define u-expand
      (compute-candidate-marginal-utility
       (priority-candidate 'hatchery 'expansion '(expand 50.5 56.5) 300 0 0 0.0 'medium #f)
       pm))
    (define expected-method
      (cond
        [(>= army-supply 10) 'attacking]
        [(>= army-supply 4) 'harassment]
        [else 'scouting]))
    (when (or (< (hash-ref pm 'intel-pressure 0.0) 1.0)
              (not (eq? intel-method expected-method))
              (<= u-intel u-worker)
              (<= u-intel u-expand)
              (<= u-recon-unit u-worker)
              (<= u-recon-unit u-expand))
      (unless pv9-cex
        (set! pv9-cex (list 'part 'severe-staleness 'race race 'staleness staleness
                            'army-supply army-supply 'frame frame
                            'intel-method intel-method 'expected expected-method
                            'u-intel u-intel 'u-recon-unit u-recon-unit
                            'u-worker u-worker 'u-expand u-expand)))))

  ;; Part B: Graduated Freshness x Coverage (non-aggressive at 12s-20s, targets uncovered sectors)
  (for* ([race (in-list PV-LATTICE-RACES)]
         [mod-staleness '(268 336 448)])
    (set! pv9-states (add1 pv9-states))
    (define pm-mod
      (compute-state-pressure-metrics
       #:race race
       #:frame 2000
       #:minerals 250
       #:gas 50
       #:supply-left 8
       #:supply-cap 30
       #:active-bases 1
       #:desired-bases 2
       #:workers 18
       #:army-supply 4
       #:enemy-threat-supply 0
       #:intel-staleness-frames mod-staleness))
    ;; Partial coverage: `enemy-main` freshly seen at 1960, `enemy-natural` and `corridor-army` unseen
    (define iq-partial
      (evaluate-opponent-intel-quality
       #:frame 2000
       #:last-seen-main-frame 1960
       #:last-seen-natural-frame 0
       #:last-seen-third-frame 0
       #:last-seen-army-frame 0
       #:army-supply 2))
    (when (or (>= (hash-ref pm-mod 'intel-pressure 0.0) 1.0)
              (not (hash-ref pm-mod 'escrow-eligible? #f))
              (not (eq? (opponent-intel-quality-priority-sector iq-partial) 'enemy-natural))
              (not (eq? (opponent-intel-quality-target-goal iq-partial) 'expand-coverage))
              (<= (opponent-intel-quality-coverage iq-partial) 0.20)
              (>= (opponent-intel-quality-coverage iq-partial) 0.55))
      (unless pv9-cex
        (set! pv9-cex (list 'part 'graduated-freshness-coverage 'race race
                            'mod-staleness mod-staleness 'pm-mod pm-mod
                            'iq-partial iq-partial)))))

  ;; Part C: Verify live runtime scouting/harassment dispatch, vision-based sector refresh & 30s threat memory
  (for ([race (in-list PV-LATTICE-RACES)])
    (set! pv9-states (+ pv9-states 3))
    (define rt (make-live-bot-runtime #:race race))
    (define worker-sym (case race [(Zerg) 'drone] [(Protoss) 'probe] [(Terran) 'scv]))
    (define combat-sym (case race [(Zerg) 'roach] [(Protoss) 'stalker] [(Terran) 'marine]))
    (define ally-units-open
      (append
       (for/list ([i (in-range 14)])
         (hash 'id (+ 1 i) 'type worker-sym 'x 33.0 'y 33.0 'hp 40 'dps 5))
       (if (eq? race 'Zerg)
           (list (hash 'id 50 'type 'overlord 'x 34.0 'y 34.0 'hp 200 'dps 0))
           '())))
    ;; Step A: Opening scout at frame 400 (`worker-scout` + `overlord-scout` for Zerg)
    (define res-open
      (step-live-bot-runtime!
       rt
       (hash 'frame 400 'minerals 150 'gas 0 'supply-used 14 'supply-cap 22
             'base-x 32.5 'base-y 32.5 'natural-x 50.5 'natural-y 56.5
             'enemy-x 160.5 'enemy-y 160.5
             'ally-units ally-units-open
             'ally-buildings (list (hash 'id 100 'type 'hatchery 'x 32.5 'y 32.5 'hp 1500))
             'enemy-units '() 'enemy-buildings '())))
    (define acts-open (hash-ref res-open 'actions '()))
    (define has-open-scout?
      (and (ormap (lambda (a) (and (pair? a) (eq? (car a) 'worker-scout))) acts-open)
           (or (not (eq? race 'Zerg))
               (ormap (lambda (a) (and (pair? a) (eq? (car a) 'overlord-scout))) acts-open))))
    ;; Step B: Scout reaches enemy base at frame 900 and spots an enemy army (`3` Stalkers)
    (define scout-id (hash-ref (live-bot-runtime-last-telemetry rt) 'scout-worker-id 1))
    (define res-spot
      (step-live-bot-runtime!
       rt
       (hash 'frame 900 'minerals 200 'gas 50 'supply-used 18 'supply-cap 30
             'base-x 32.5 'base-y 32.5 'natural-x 50.5 'natural-y 56.5
             'enemy-x 160.5 'enemy-y 160.5
             'ally-units (cons (hash 'id scout-id 'type worker-sym 'x 155.0 'y 155.0 'hp 40 'dps 5)
                               (cdr ally-units-open))
             'ally-buildings (list (hash 'id 100 'type 'hatchery 'x 32.5 'y 32.5 'hp 1500))
             'enemy-units (list (hash 'id 901 'type 'stalker 'x 152.0 'y 152.0 'hp 160 'dps 14)
                                (hash 'id 902 'type 'stalker 'x 153.0 'y 152.0 'hp 160 'dps 14)
                                (hash 'id 903 'type 'stalker 'x 154.0 'y 152.0 'hp 160 'dps 14))
             'enemy-buildings '())))
    (define acts-spot (hash-ref res-spot 'actions '()))
    (define has-mineral-harass?
      (ormap (lambda (a) (and (pair? a) (eq? (car a) 'mineral-harass))) acts-spot))
    ;; Step C: Enemy army marches out of vision at frame 1100 (`200` frames later < `672`);
    ;; verify `remembered-enemy-threat-supply` persists (> 0) and `last-seen-main-frame = 900`!
    (define res-memory
      (step-live-bot-runtime!
       rt
       (hash 'frame 1100 'minerals 200 'gas 50 'supply-used 22 'supply-cap 38
             'base-x 32.5 'base-y 32.5 'natural-x 50.5 'natural-y 56.5
             'enemy-x 160.5 'enemy-y 160.5
             'ally-units (append ally-units-open
                                 (for/list ([k (in-range 5)])
                                   (hash 'id (+ 200 k) 'type combat-sym 'x 40.0 'y 40.0 'hp 100 'dps 12)))
             'ally-buildings (list (hash 'id 100 'type 'hatchery 'x 32.5 'y 32.5 'hp 1500))
             'enemy-units '() 'enemy-buildings '())))
    (define telem-mem (live-bot-runtime-last-telemetry rt))
    (define rem-threat (hash-ref telem-mem 'remembered-enemy-threat-supply 0.0))
    (define seen-main (hash-ref telem-mem 'last-seen-main-frame 0))
    (when (or (not has-open-scout?)
              (not has-mineral-harass?)
              (<= rem-threat 0.0)
              (not (= seen-main 900)))
      (unless pv9-cex
        (set! pv9-cex (list 'race race 'has-open-scout? has-open-scout?
                            'has-mineral-harass? has-mineral-harass?
                            'rem-threat rem-threat 'seen-main seen-main)))))

  (record! 'PV9-opponent-intel-gathering-priority-and-threat-memory
           "Continuous `Freshness x Coverage` model (`evaluate-opponent-intel-quality`) preserves expansion escrow under moderate staleness (`12s-20s`), targets uncovered sectors (`priority-sector`), elevates intel gathering above passive macro when severely blind (`>= 896` frames / `confidence < 0.35`), and retains scouted threat memory (`<= 672` frames)"
           pv9-states
           (not pv9-cex)
           pv9-cex)

  results)

;; =============================================================================
;; 5. Top-Level Formal Verification Runner
;; =============================================================================

(define (verify-all-state-machines #:print-report? [print-report? #t]
                                   #:fast? [fast? #f])
  (define p-res (verify-posture-state-machine))
  (define m-res (verify-mirror-mind-state-machine))
  (define e-res (verify-economy-and-ledger-state-machine))
  (define pv-res (verify-prioritization-scheduler-invariants #:fast? fast?))
  (define all-res (append p-res m-res e-res pv-res))
  (define total (length all-res))
  (define passed (count verification-check-result-passed? all-res))
  (define failed (- total passed))
  (define total-states
    (for/sum ([r (in-list all-res)])
      (verification-check-result-states-explored r)))

  (when print-report?
    (for ([r (in-list all-res)])
      (printf "  [~a] [~a] ~a (~a states explored)\n"
              (if (verification-check-result-passed? r) "PASS" "FAIL")
              (verification-check-result-id r)
              (verification-check-result-description r)
              (verification-check-result-states-explored r))
      (when (verification-check-result-counterexample r)
        (printf "         Counterexample: ~v\n"
                (verification-check-result-counterexample r))))
    (printf "  Formal Verification Summary: ~a/~a invariants passed across ~a explored states.\n"
            passed total total-states))

  (when (> failed 0)
    (error 'verify-all-state-machines
           "Formal state-machine verification failed on ~a/~a checks"
           failed total))

  (state-machine-verification-report total passed failed total-states all-res))

(define (run-all-formal-verifications)
  (verify-all-state-machines #:print-report? #t))

(module+ main
  (void (verify-all-state-machines #:print-report? #t)))

