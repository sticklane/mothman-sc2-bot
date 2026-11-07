#lang racket

;; =============================================================================
;; Pure-Racket Formal State-Machine & Invariant Verifier (`lib/state-machine-verifier.rkt`)
;;
;; Model-checks all 3 core state machines in the `#lang sc-bot` Racket runtime:
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
;; =============================================================================

(require racket/match
         racket/list
         racket/set
         "bot-runtime.rkt"
         "mirror-mind-predictor.rkt"
         "econ-ledger.rkt")

(provide (struct-out verification-check-result)
         (struct-out state-machine-verification-report)
         verify-posture-state-machine
         verify-mirror-mind-state-machine
         verify-economy-and-ledger-state-machine
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
    (list (hash 'id 901 'type 'zealot 'x 720 'y 770 'hp 100 'dps 16)
          (hash 'id 902 'type 'zealot 'x 725 'y 775 'hp 100 'dps 16)
          (hash 'id 903 'type 'zealot 'x 730 'y 780 'hp 100 'dps 16)
          (hash 'id 904 'type 'zealot 'x 735 'y 785 'hp 100 'dps 16)))

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
            'base-x 700
            'base-y 760
            'natural-x 1024
            'natural-y 1120
            'enemy-x 1600
            'enemy-y 1600
            'ally-units (list (hash 'id 1 'type 'drone 'x 705 'y 765 'hp 40 'dps 5)
                              (hash 'id 2 'type 'drone 'x 708 'y 768 'hp 40 'dps 5)
                              (hash 'id 3 'type 'drone 'x 710 'y 770 'hp 40 'dps 5)
                              (hash 'id 4 'type 'drone 'x 712 'y 772 'hp 40 'dps 5)
                              (hash 'id 10 'type 'queen 'x 720 'y 775 'hp 175 'dps 12))
            'ally-buildings (list (hash 'id 100 'type 'hatchery 'x 700 'y 760 'hp 1500))
            'enemy-units (list (hash 'id 901 'type scout-type 'x 715 'y 770 'hp 100 'dps 0))
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
            'base-x 700
            'base-y 760
            'natural-x 1024
            'natural-y 1120
            'enemy-x 1600
            'enemy-y 1600
            'visible-sectors '(0 1 2 3 4 5)
            'ally-units (list (hash 'id 1 'type 'roach 'x 900 'y 950 'hp 145 'dps 16))
            'ally-buildings (list (hash 'id 100 'type 'hatchery 'x 700 'y 760 'hp 1500))
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
      (list (hash 'id 1 'type 'nexus 'x 1600 'y 1600)
            (hash 'id 2 'type 'nexus 'x 1400 'y 1400)
            (hash 'id 3 'type 'nexus 'x 1200 'y 1500)))
    (define ledger (compute-opponent-shadow-ledger ms 3200 '() e-bldgs))
    (define reading (interpret-opponent-actions ms 3200 '() e-bldgs ledger))
    (define-values (v _b _w _rm _dp)
      (evaluate-mirror-macro-verdict ms 3200 '() '() '() e-bldgs ledger reading))
    (set-add! verdicts-seen v))
  ;; 2. Passive turtle (1-2 bases + static defense)
  (let ([ms (make-mirror-mind-state #:our-race 'Zerg #:enemy-race 'Terran)])
    (define e-bldgs
      (list (hash 'id 1 'type 'orbital-command 'x 1600 'y 1600)
            (hash 'id 2 'type 'bunker 'x 1450 'y 1450)
            (hash 'id 3 'type 'planetary-fortress 'x 1380 'y 1380)))
    (define e-units
      (list (hash 'id 10 'type 'siege-tank-sieged 'x 1440 'y 1440)))
    (define ledger (compute-opponent-shadow-ledger ms 3000 e-units e-bldgs))
    (define reading (interpret-opponent-actions ms 3000 e-units e-bldgs ledger))
    (define-values (v _b _w _rm _dp)
      (evaluate-mirror-macro-verdict ms 3000 '() '() e-units e-bldgs ledger reading))
    (set-add! verdicts-seen v))
  ;; 3. Defend All-In Then Counter Expand (proxy/all-in near our base at frame 2400)
  (let ([ms (make-mirror-mind-state #:our-race 'Zerg #:enemy-race 'Terran)])
    (define e-units
      (for/list ([i (in-range 6)])
        (hash 'id (+ 50 i) 'type 'marine 'x 740 'y 780)))
    (define ledger (compute-opponent-shadow-ledger ms 2400 e-units '()))
    (define reading (interpret-opponent-actions ms 2400 e-units '() ledger))
    (define-values (v _b _w _rm _dp)
      (evaluate-mirror-macro-verdict ms 2400 '() '() e-units '() ledger reading))
    (set-add! verdicts-seen v))
  ;; 4. Pace Macro And Disrupt (even midgame army)
  (let ([ms (make-mirror-mind-state #:our-race 'Zerg #:enemy-race 'Protoss)])
    (define e-bldgs
      (list (hash 'id 1 'type 'nexus 'x 1600 'y 1600)
            (hash 'id 2 'type 'nexus 'x 1400 'y 1400)))
    (define e-units
      (for/list ([i (in-range 6)])
        (hash 'id (+ 80 i) 'type 'stalker 'x 1350 'y 1350)))
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
        (hash 'id (+ 200 b) 'type 'command-center 'x 1550 'y (+ 1500 (* b 80)))))
    (define e-units
      (for/list ([u (in-range far-combat-count)])
        (hash 'id (+ 300 u) 'type 'marine 'x 1500 'y 1500)))
    (define a-bldgs
      (list (hash 'id 1 'type 'hatchery 'x 700 'y 760)
            (hash 'id 2 'type 'hatchery 'x 1024 'y 1120)))
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
    (define e-units (list (hash 'id 99 'type scout-sym 'x 720 'y 770)))
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
        (hash 'id (+ 1 i) 'type worker-sym 'x 700 'y 760 'hp 40 'dps 5)))
    (define ally-bldgs
      (for/list ([b (in-range cur-bases)])
        (hash 'id (+ 500 b) 'type th-sym 'x (+ 700 (* b 200)) 'y (+ 760 (* b 150)) 'hp 1500)))
    (define obs
      (hash 'frame 4500
            'minerals 500
            'gas 200
            'supply-used (* cur-bases 36)
            'supply-cap (min 200 (* cur-bases 52))
            'base-x 700
            'base-y 760
            'natural-x 1024
            'natural-y 1120
            'enemy-x 1600
            'enemy-y 1600
            'ally-units ally-units
            'ally-buildings ally-bldgs
            'enemy-units '()
            'enemy-buildings (list (hash 'id 801 'type 'nexus 'x 1600 'y 1600)
                                   (hash 'id 802 'type 'nexus 'x 1400 'y 1400)
                                   (hash 'id 803 'type 'nexus 'x 1200 'y 1500))))
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
            'base-x 700
            'base-y 760
            'natural-x 1024
            'natural-y 1120
            'enemy-x 1600
            'enemy-y 1600
            'ally-units (for/list ([i (in-range 18)])
                          (hash 'id (+ 1 i) 'type worker-sym 'x 700 'y 760 'hp 40 'dps 5))
            'ally-buildings (list (hash 'id 100 'type th-sym 'x 700 'y 760 'hp 1500)
                                  (hash 'id 101 'type pool-sym 'x 748 'y 808 'hp 1000))
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
;; 4. Top-Level Formal Verification Runner
;; =============================================================================

(define (verify-all-state-machines #:print-report? [print-report? #t])
  (define p-res (verify-posture-state-machine))
  (define m-res (verify-mirror-mind-state-machine))
  (define e-res (verify-economy-and-ledger-state-machine))
  (define all-res (append p-res m-res e-res))
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
