#lang racket/base

(require racket/match
         racket/list
         racket/set
         racket/math
         "../compiler/syntax.rkt"
         "perception-grid.rkt"
         "econ-ledger.rkt"
         "tactics-sim.rkt"
         "human-cortex.rkt"
         "zerospace-mastermind.rkt"
         "mirror-mind-predictor.rkt")

(provide
 WORKER-AND-NONCOMBAT-SYMS
 PRO-CHRONO-11-STRUCTURES
 (struct-out live-bot-runtime)
 make-live-bot-runtime
 step-layer1-perception!
 step-layer1b-mastermind!
 step-layer1c-mirror-mind!
 step-layer2-economy!
 step-layer3-and-4-tactics!
 step-layer5-human-cortex!
 step-live-bot-runtime!
 parse-frame-state-sexp
 runtime-step-sexp!)

(define WORKER-AND-NONCOMBAT-SYMS
  '(drone probe scv overlord overseer queen larva egg mule observer
    creep-tumor creep-tumor-burrowed warp-prism shuttle medivac))

(define PRO-CHRONO-11-STRUCTURES
  '(robotics-facility
    stargate
    forge
    twilight-council
    templar-archive
    templar-archives
    cybernetics-core
    robotics-support-bay
    robotics-bay
    fleet-beacon
    dark-shrine
    gateway
    warp-gate
    nexus))

(struct live-bot-runtime
  (bot-name
   configured-race
   actual-race
   posture
   posture-history
   perception
   mastermind
   mirror-mind
   doctrine
   ledger
   cast-limiter
   cortex
   used-creep-tumors
   bookmarks-initialized?
   step-count
   last-telemetry)
  #:mutable
  #:transparent)

(define (default-posture-for-race race)
  (case race
    [(Zerg zerg)       'Macro12Hatch]
    [(Protoss protoss) 'ForgeFastExpand]
    [(Terran terran)   'OneRaxFE]
    [(Random random)   'RandomRollOpening]
    [else              'Macro12Hatch]))

(define (default-personality-for-race race)
  (case race
    [(Zerg zerg)       SCARLETT-CREEP-SWARM-PERSONALITY]
    [(Protoss protoss) MARV-MACRO-OPEN-PERSONALITY]
    [(Terran terran)   CLEM-TEMPO-MULTITASK-PERSONALITY]
    [else              CLEM-TEMPO-MULTITASK-PERSONALITY]))

(define (normalize-race-sym r)
  (case r
    [(Zerg zerg "Zerg" "zerg") 'Zerg]
    [(Protoss protoss "Protoss" "protoss") 'Protoss]
    [(Terran terran "Terran" "terran") 'Terran]
    [(Random random "Random" "random") 'Random]
    [else 'Zerg]))

(define (make-live-bot-runtime #:bot-name [bot-name 'mothman-bot]
                               #:race [race 'Zerg]
                               #:personality [personality #f]
                               #:build-order [_build-order #f]
                               #:cortex-profile [cortex-profile 'Serral]
                               #:postures [_postures '()]
                               #:squads [_squads '()]
                               #:state-machine [_sm #f]
                               #:doctrine [doctrine #f]
                               #:epm-cap [epm-cap 360]
                               #:initial-posture [init-posture #f])
  (define norm-race (normalize-race-sym race))
  (define eff-race (if (eq? norm-race 'Random) 'Zerg norm-race))
  (define pers (or personality (default-personality-for-race norm-race)))
  (define post (or init-posture (default-posture-for-race norm-race)))
  (define prof-sym
    (cond
      [(symbol? cortex-profile) cortex-profile]
      [else 'Serral]))
  (live-bot-runtime
   bot-name
   norm-race
   eff-race
   post
   (list post)
   (make-perception-grid)
   (make-mastermind-state eff-race pers)
   (make-mirror-mind-state #:our-race eff-race)
   doctrine
   (make-symbiotic-ledger 50 0 12)
   (make-ability-cast-limiter #:max-per-frame 2 #:refractory-frames 16)
   (make-human-cortex #:profile prof-sym #:cam-x 600 #:cam-y 700 #:epm-cap epm-cap #:max-tokens 24)
   (mutable-set)
   #f
   0
   (hash)))

;; =============================================================================
;; Helper: Distance & Unit Inspection
;; =============================================================================

(define (dist2d x1 y1 x2 y2)
  (sqrt (+ (sqr (- x2 x1)) (sqr (- y2 y1)))))

(define (unit-type-sym u)
  (define raw (hash-ref u 'type 'unknown))
  (if (string? raw) (string->symbol (string-downcase raw)) raw))

(define (combat-unit-record? u)
  (not (memq (unit-type-sym u) WORKER-AND-NONCOMBAT-SYMS)))

(define (detect-actual-race-from-obs obs fallback-race)
  (define obs-race (hash-ref obs 'actual-race (hash-ref obs 'race #f)))
  (cond
    [(and obs-race (not (memq obs-race '(Random random "Random" "random"))))
     (normalize-race-sym obs-race)]
    [else
     (define all-types
       (append (map unit-type-sym (hash-ref obs 'ally-units '()))
               (map unit-type-sym (hash-ref obs 'ally-buildings '()))))
     (cond
       [(ormap (lambda (t) (memq t '(drone overlord hatchery lair hive spawning-pool zergling roach queen))) all-types)
        'Zerg]
       [(ormap (lambda (t) (memq t '(probe nexus pylon gateway forge cybernetics-core zealot stalker dragoon))) all-types)
        'Protoss]
       [(ormap (lambda (t) (memq t '(scv command-center orbital-command supply-depot barracks marine marauder siege-tank))) all-types)
        'Terran]
       [else fallback-race])]))

;; =============================================================================
;; Layer 1: Spatial Perception & Frame-0 Random Race Resolution
;; =============================================================================

(define (step-layer1-perception! rt obs)
  (define frame (hash-ref obs 'frame 0))
  (define resolved-race (detect-actual-race-from-obs obs (live-bot-runtime-actual-race rt)))
  (set-live-bot-runtime-actual-race! rt resolved-race)
  (set-mastermind-state-race! (live-bot-runtime-mastermind rt) resolved-race)
  (set-mirror-mind-state-our-race! (live-bot-runtime-mirror-mind rt) resolved-race)
  (when (and (eq? (live-bot-runtime-configured-race rt) 'Random)
             (eq? (bot-personality-name (mastermind-state-personality (live-bot-runtime-mastermind rt)))
                  'SCARLETT-CREEP-SWARM-PERSONALITY))
    (set-mastermind-state-personality! (live-bot-runtime-mastermind rt)
                                       (default-personality-for-race resolved-race)))
  (define ally-units (hash-ref obs 'ally-units '()))
  (define enemy-units (hash-ref obs 'enemy-units '()))
  (define visible-sectors (hash-ref obs 'visible-sectors '(0 1 2 3)))
  (perception-grid-ingest-frame!
   (live-bot-runtime-perception rt)
   frame
   ally-units
   enemy-units
   visible-sectors))

;; =============================================================================
;; Layer 1b: ZeroSpace Mastermind & Posture State Machine
;; =============================================================================

(define (compute-next-posture rt obs fap-score)
  (define frame (hash-ref obs 'frame 0))
  (define cfg-race (live-bot-runtime-configured-race rt))
  (define act-race (live-bot-runtime-actual-race rt))
  (define cur (live-bot-runtime-posture rt))
  (define enemy-units (hash-ref obs 'enemy-units '()))
  (define ally-bldgs (map unit-type-sym (hash-ref obs 'ally-buildings '())))
  (define rush-threat?
    (and (< frame 2500)
         (>= (length enemy-units) 3)
         (< fap-score -5)))
  (cond
    [(eq? cfg-race 'Random)
     (cond
       [rush-threat? 'EarlyScoutCrisis]
       [(or (>= frame 3500)
            (memq 'ghost (map unit-type-sym (hash-ref obs 'ally-units '())))
            (memq 'colossus (map unit-type-sym (hash-ref obs 'ally-units '())))
            (memq 'corruptor (map unit-type-sym (hash-ref obs 'ally-units '()))))
        'MothmanApexVictory]
       [(or (>= frame 1800)
            (memq 'starport ally-bldgs)
            (memq 'spire ally-bldgs)
            (memq 'robotics-facility ally-bldgs))
        'TriRaceVanguardContain]
       [(>= frame 350) 'AdaptiveCounterRecovery]
       [else 'RandomRollOpening])]
    [(eq? act-race 'Zerg)
     (cond
       [rush-threat? 'CrisisZealotRush]
       [(or (>= frame 3200) (memq 'hive ally-bldgs) (memq 'corruptor (map unit-type-sym (hash-ref obs 'ally-units '()))))
        'SwarmVictory]
       [(or (memq 'lair ally-bldgs) (memq 'spire ally-bldgs))
        'MutaLurkerContain]
       [(or (>= frame 300) (memq 'spawning-pool ally-bldgs))
        'SunkenLairRecovery]
       [else 'Macro12Hatch])]
    [(eq? act-race 'Protoss)
     (cond
       [rush-threat? 'CrisisZerglingFlood]
       [(or (>= frame 2600)
            (memq 'stalker (map unit-type-sym (hash-ref obs 'ally-units '())))
            (memq 'colossus (map unit-type-sym (hash-ref obs 'ally-units '()))))
        'ProtossArmadaVictory]
       [(or (memq 'cybernetics-core ally-bldgs) (memq 'robotics-facility ally-bldgs))
        'DragoonReaverVanguard]
       [(or (>= frame 300) (memq 'gateway ally-bldgs) (memq 'forge ally-bldgs))
        'CannonWallRecovery]
       [else 'ForgeFastExpand])]
    [else ;; Terran
     (cond
       [rush-threat? 'CrisisEarlyBust]
       [(or (>= frame 3200) (memq 'ghost (map unit-type-sym (hash-ref obs 'ally-units '()))))
        'MothmanApexVictory]
       [(or (memq 'starport ally-bldgs) (memq 'siege-tank (map unit-type-sym (hash-ref obs 'ally-units '()))))
        'VesselGhostPush]
       [(or (>= frame 300) (memq 'barracks ally-bldgs))
        'BunkerSiegeRecovery]
       [else 'OneRaxFE])]))

(define (step-layer1b-mastermind! rt obs)
  (define ally-units (hash-ref obs 'ally-units '()))
  (define enemy-units (hash-ref obs 'enemy-units '()))
  (define ally-combat (filter combat-unit-record? ally-units))
  (define fap-score (fap-evaluate-engagement ally-combat enemy-units))
  (define ally-bldgs (map unit-type-sym (hash-ref obs 'ally-buildings '())))
  (define workers
    (filter (lambda (u) (memq (unit-type-sym u) '(drone probe scv))) ally-units))
  (define mstate (live-bot-runtime-mastermind rt))
  (step-double-reaction! mstate
                         #:fap-score fap-score
                         #:enemy-units enemy-units
                         #:ally-buildings ally-bldgs
                         #:self-workers (max 12 (length workers))
                         #:enemy-workers 14
                         #:self-army (* 50 (length ally-combat))
                         #:enemy-army (* 50 (length enemy-units)))
  (when (live-bot-runtime-doctrine rt)
    (define new-p (step-doctrine-loadout! (live-bot-runtime-doctrine rt)
                                          #:fap-score fap-score
                                          #:under-rush? (< fap-score -20)))
    (set-mastermind-state-personality! mstate new-p))
  (define next-posture (compute-next-posture rt obs fap-score))
  (define old-posture (live-bot-runtime-posture rt))
  (define posture-actions
    (if (not (eq? next-posture old-posture))
        (begin
          (set-live-bot-runtime-posture! rt next-posture)
          (set-live-bot-runtime-posture-history!
           rt (append (live-bot-runtime-posture-history rt) (list next-posture)))
          (list (list 'posture-transition next-posture)))
        '()))
  (values posture-actions fap-score))

;; =============================================================================
;; Layer 1c: Adaptive Mirror-Mind Opponent Prediction Layer
;; =============================================================================

(define (step-layer1c-mirror-mind! rt obs)
  (define mmstate (live-bot-runtime-mirror-mind rt))
  (step-mirror-mind-predictor! mmstate obs))

;; =============================================================================
;; Layer 2: Economy, Zero-Supply-Block Macro, Pro Mechanics & Anti-Cheese
;; =============================================================================

(define (unit-supply-cost unit-sym)
  (case unit-sym
    [(overlord observer creep-tumor) 0]
    [(drone probe scv zergling baneling marine) 1]
    [(roach ravager hydralisk mutalisk corruptor queen zealot stalker dragoon sentry adept
      high-templar dark-templar warp-prism shuttle marauder reaper ghost hellion widow-mine
      medic medivac viking science-vessel) 2]
    [(lurker siege-tank) 3]
    [(immortal reaver colossus archon ultralisk brood-lord thor battlecruiser carrier) 4]
    [else 2]))

(define (step-layer2-economy! rt obs)
  (define race (live-bot-runtime-actual-race rt))
  (define frame (hash-ref obs 'frame 0))
  (define minerals (hash-ref obs 'minerals 200))
  (define gas (hash-ref obs 'gas 0))
  (define supply-used (hash-ref obs 'supply-used 12))
  (define supply-cap (hash-ref obs 'supply-cap 15))
  (define pending-supply (hash-ref obs 'pending-supply 0))
  (define supply-left (hash-ref obs 'supply-left (- supply-cap supply-used)))
  (define ally-units (hash-ref obs 'ally-units '()))
  (define ally-bldgs (hash-ref obs 'ally-buildings '()))
  (define enemy-units (hash-ref obs 'enemy-units '()))
  (define enemy-bldgs (hash-ref obs 'enemy-buildings '()))
  (define base-x (hash-ref obs 'base-x 700))
  (define base-y (hash-ref obs 'base-y 760))
  (define nat-x (hash-ref obs 'natural-x 1024))
  (define nat-y (hash-ref obs 'natural-y 1120))
  (define third-x (hash-ref obs 'third-x 1280))
  (define third-y (hash-ref obs 'third-y 1280))
  (define enemy-x (hash-ref obs 'enemy-x 1600))
  (define enemy-y (hash-ref obs 'enemy-y 1600))

  (define actions '())
  (define (emit! act)
    (set! actions (cons act actions)))

  (define bldg-types (map unit-type-sym ally-bldgs))
  (define unit-types (map unit-type-sym ally-units))
  (define workers
    (filter (lambda (u) (memq (unit-type-sym u) '(drone probe scv))) ally-units))
  (define pending-workers (hash-ref obs 'pending-workers 0))
  (define total-workers (+ (length workers) pending-workers))

  ;; ---------------------------------------------------------------------------
  ;; Pro Signature Mechanic #1: Tactical Building Save-Cancel (<18% HP or <50 HP)
  ;; ---------------------------------------------------------------------------
  (for ([b (in-list ally-bldgs)])
    (define prog (hash-ref b 'build-progress (if (hash-ref b 'under-construction #f) 0.5 1.0)))
    (define hp (hash-ref b 'hp 100))
    (define max-hp (hash-ref b 'max-hp 500))
    (define hp-pct (hash-ref b 'hp-pct (/ (exact->inexact hp) (max 1 max-hp))))
    (define bx (hash-ref b 'x base-x))
    (define by (hash-ref b 'y base-y))
    (define enemy-near?
      (or (hash-ref b 'under-attack #f)
          (ormap (lambda (e) (<= (dist2d bx by (hash-ref e 'x 9999) (hash-ref e 'y 9999)) 240))
                 enemy-units)))
    (when (and (< prog 1.0)
               (or (< hp-pct 0.18) (< hp 50))
               enemy-near?)
      (emit! (list 'cancel (hash-ref b 'id 701)))))

  ;; ---------------------------------------------------------------------------
  ;; Adversarial Countermeasure #4: Halted Terran Building SCV Resume
  ;; ---------------------------------------------------------------------------
  (when (eq? race 'Terran)
    (for ([b (in-list ally-bldgs)])
      (define prog (hash-ref b 'build-progress 1.0))
      (define halted? (or (hash-ref b 'halted #f)
                          (and (< prog 1.0) (not (hash-ref b 'has-builder #t)))))
      (when (and halted? (not (null? workers)))
        (define scv-id (hash-ref (car workers) 'id 10))
        (emit! (list 'resume-halted-building scv-id (hash-ref b 'id 902))))))

  ;; ---------------------------------------------------------------------------
  ;; Adversarial Countermeasure #3: Anti-Gas-Steal Detection & Focus-Fire
  ;; ---------------------------------------------------------------------------
  (define enemy-gas-steals
    (filter (lambda (eb)
              (and (memq (unit-type-sym eb) '(assimilator extractor refinery))
                   (<= (dist2d base-x base-y (hash-ref eb 'x 9999) (hash-ref eb 'y 9999)) 260)))
            enemy-bldgs))
  (for ([eg (in-list enemy-gas-steals)])
    (emit! (list 'clear-gas-steal
                 (hash-ref eg 'id 901)
                 (hash-ref eg 'x (+ base-x 48))
                 (hash-ref eg 'y (+ base-y 48)))))

  ;; ---------------------------------------------------------------------------
  ;; Adversarial Countermeasure #1: Early Cheese / Cannon / Proxy / Worker Rush
  ;; ---------------------------------------------------------------------------
  (define proxy-or-cheese-enemies
    (filter (lambda (e)
              (and (<= (dist2d base-x base-y (hash-ref e 'x 9999) (hash-ref e 'y 9999)) 320)
                   (or (< frame 3200) (< (length (filter combat-unit-record? ally-units)) 4))))
            (append enemy-units enemy-bldgs)))
  (define under-early-cheese?
    (or (hash-ref obs 'under-cheese-rush #f)
        (and (not (null? proxy-or-cheese-enemies))
             (or (ormap (lambda (e) (memq (unit-type-sym e) '(photon-cannon pylon bunker spine-crawler barracks)))
                        enemy-bldgs)
                 (>= (length proxy-or-cheese-enemies) 2)))))
  (when (and under-early-cheese? (not (null? workers)))
    (define healthy-workers
      (filter (lambda (w) (>= (hash-ref w 'hp 40) 18)) workers))
    (define pull-ids
      (map (lambda (w) (hash-ref w 'id 10))
           (take healthy-workers (min 6 (length healthy-workers)))))
    (define threat (car proxy-or-cheese-enemies))
    (define tx (hash-ref threat 'x (+ base-x 80)))
    (define ty (hash-ref threat 'y (+ base-y 80)))
    (unless (null? pull-ids)
      (emit! (list 'pull-workers-attack pull-ids tx ty)))
    ;; Harass enemy proxy builder if present
    (define enemy-builder
      (findf (lambda (e) (memq (unit-type-sym e) '(probe scv drone))) enemy-units))
    (when (and enemy-builder (not (null? healthy-workers)))
      (emit! (list 'worker-harass
                   (hash-ref (car healthy-workers) 'id 10)
                   (hash-ref enemy-builder 'x tx)
                   (hash-ref enemy-builder 'y ty)))))

  ;; ---------------------------------------------------------------------------
  ;; Adversarial Countermeasure #2: Blocked Natural Expansion Site
  ;; ---------------------------------------------------------------------------
  (define natural-blockers
    (filter (lambda (e)
              (<= (dist2d nat-x nat-y (hash-ref e 'x 9999) (hash-ref e 'y 9999)) 96))
            (append enemy-units enemy-bldgs)))
  (define natural-blocked?
    (or (hash-ref obs 'natural-blocked #f)
        (not (null? natural-blockers))))
  (when natural-blocked?
    (emit! (list 'clear-expansion-block nat-x nat-y))
    (if (eq? race 'Terran)
        (when (>= minerals 400)
          (emit! (list 'build 'command-center (+ base-x 64) base-y)))
        (when (>= minerals 300)
          (emit! (list 'expand third-x third-y)))))

  ;; ---------------------------------------------------------------------------
  ;; Worker Mineral-Walk Escape (Pro Mechanic #5) & Resource Harvesting
  ;; ---------------------------------------------------------------------------
  (for ([w (in-list workers)])
    (define whp (hash-ref w 'hp 40))
    (define wmax (hash-ref w 'max-hp 40))
    (define wx (hash-ref w 'x base-x))
    (define wy (hash-ref w 'y base-y))
    (define enemy-close?
      (ormap (lambda (e) (<= (dist2d wx wy (hash-ref e 'x 9999) (hash-ref e 'y 9999)) 128))
             enemy-units))
    (when (and (or (< whp 25) (< (/ (exact->inexact whp) (max 1 wmax)) 0.60))
               enemy-close?)
      (emit! (list 'mineral-walk (hash-ref w 'id 10) base-x base-y))))

  ;; Standard Gas & Mineral Harvesting
  (define gas-bldg
    (findf (lambda (b) (memq (unit-type-sym b) '(extractor assimilator refinery)))
           ally-bldgs))
  (when (and gas-bldg (not (null? workers)))
    (emit! (list 'harvest-gas (hash-ref (car workers) 'id 10) (hash-ref gas-bldg 'id 103))))
  (when (not (null? workers))
    (define patch-id (hash-ref obs 'mineral-patch-id 504))
    (emit! (list 'harvest-mineral (hash-ref (car workers) 'id 10) patch-id)))

  ;; Early Worker Scout / Harass (Pro Mechanic #5)
  (when (and (hash-ref obs 'enable-worker-harass #f) (not (null? workers)))
    (emit! (list 'worker-harass (hash-ref (last workers) 'id 10) enemy-x enemy-y)))

  ;; Mined-out base detection (Scenario 3): auto-expand & transfer workers
  (when (and (hash-ref obs 'mined-out #f) (not natural-blocked?) (not under-early-cheese?))
    (emit! (list 'expand nat-x nat-y)))

  ;; ---------------------------------------------------------------------------
  ;; Zero-Supply-Block & Supply-At-Risk Preemption (Scenario 1)
  ;; ---------------------------------------------------------------------------
  (define threatened-overlords
    (filter (lambda (u)
              (and (eq? (unit-type-sym u) 'overlord)
                   (or (< (hash-ref u 'hp 200) 150)
                       (hash-ref u 'under-attack #f)
                       (ormap (lambda (e)
                                (<= (dist2d (hash-ref u 'x base-x) (hash-ref u 'y base-y)
                                            (hash-ref e 'x 9999) (hash-ref e 'y 9999))
                                    256))
                              enemy-units))))
            ally-units))
  (for ([ov (in-list threatened-overlords)])
    (emit! (list 'kite (hash-ref ov 'id 102) base-x base-y)))

  (define threatened-supply-bldgs
    (filter (lambda (b)
              (and (memq (unit-type-sym b) '(supply-depot pylon))
                   (or (< (hash-ref b 'hp 400) 250)
                       (< (hash-ref b 'hp-pct 1.0) 0.65)
                       (hash-ref b 'under-attack #f))))
            ally-bldgs))

  (define supply-at-risk?
    (or (not (null? threatened-overlords))
        (not (null? threatened-supply-bldgs))
        (hash-ref obs 'supply-at-risk #f)))

  (define supply-threshold (if (>= supply-cap 30) 6 4))
  (define need-supply?
    (and (< supply-cap 200)
         (or supply-at-risk?
             (and (<= (+ supply-left (* 8 pending-supply)) supply-threshold)
                  (>= minerals 100)))))

  (when (and need-supply? (>= minerals 100))
    (case race
      [(Zerg)
       (emit! '(train overlord))
       (set! minerals (- minerals 100))
       (set! pending-supply (add1 pending-supply))]
      [(Protoss)
       (emit! (list 'build 'pylon (+ base-x 64) (+ base-y 64)))
       (set! minerals (- minerals 100))
       (set! pending-supply (add1 pending-supply))]
      [(Terran)
       (emit! (list 'build 'supply-depot (+ base-x 64) (- base-y 48)))
       (set! minerals (- minerals 100))
       (set! pending-supply (add1 pending-supply))]))

  ;; Helper: check if we can spend `cost` supply without supply blocking
  ;; Also reserves supply floor if supply-at-risk and minerals < 150
  (define reserve-supply-floor?
    (and (or supply-at-risk? (<= supply-left 2))
         (< minerals 150)))
  (define effective-free-supply
    (max 0 (+ supply-left (if (> pending-supply 0) 2 0))))
  (define (can-spend-supply? cost)
    (and (not reserve-supply-floor?)
         (>= effective-free-supply cost)
         (> supply-left 0)))

  ;; ---------------------------------------------------------------------------
  ;; Race-Specific Macro Mechanics, Tech Trees, Upgrades & Unit Production
  ;; ---------------------------------------------------------------------------
  (case race
    [(Zerg)
     ;; 1. Queen Inject Larva & Spawn Creep Tumor
     (define queens (filter (lambda (u) (eq? (unit-type-sym u) 'queen)) ally-units))
     (define hatcheries
       (filter (lambda (b) (memq (unit-type-sym b) '(hatchery lair hive))) ally-bldgs))
     (for ([q (in-list queens)])
       (define q-energy (hash-ref q 'energy 25))
       (define qid (hash-ref q 'id 120))
       (cond
         [(and (>= q-energy 25) (< q-energy 45) (not (null? hatcheries)))
          (emit! (list 'cast-spell qid 'inject-larva (hash-ref (car hatcheries) 'id 101)))]
         [(>= q-energy 45)
          (emit! (list 'cast-spell qid 'spawn-creep-tumor 943 1030))]))

     ;; 2. Pro Mechanic #2: Active Creep Tumor Daisy-Chaining (capped at 2/frame)
     (define ready-tumors
       (filter (lambda (u)
                 (and (memq (unit-type-sym u) '(creep-tumor creep-tumor-burrowed))
                      (not (set-member? (live-bot-runtime-used-creep-tumors rt)
                                        (hash-ref u 'id 0)))))
               (append ally-units ally-bldgs)))
     (for ([t (in-list (take ready-tumors (min 2 (length ready-tumors))))])
       (define tid (hash-ref t 'id 702))
       (define tx (hash-ref t 'x base-x))
       (define ty (hash-ref t 'y base-y))
       (define dx (- enemy-x tx))
       (define dy (- enemy-y ty))
       (define d (max 1.0 (sqrt (+ (* dx dx) (* dy dy)))))
       (define target-x (exact-round (+ tx (* 144.0 (/ dx d)))))
       (define target-y (exact-round (+ ty (* 144.0 (/ dy d)))))
       (set-add! (live-bot-runtime-used-creep-tumors rt) tid)
       (emit! (list 'cast tid 'spread-creep-tumor target-x target-y)))

     ;; 3. Zerg Tech Buildings & Morphs
     (when (and (not (memq 'spawning-pool bldg-types)) (>= minerals 150))
       (emit! (list 'build 'spawning-pool (+ base-x 48) (+ base-y 48)))
       (set! minerals (- minerals 150)))

     (when (and (memq 'spawning-pool bldg-types)
                (not (memq 'extractor bldg-types))
                (>= minerals 75))
       (emit! (list 'build 'extractor (+ base-x 64) (+ base-y 64)))
       (set! minerals (- minerals 75)))

     (when (and (memq 'spawning-pool bldg-types)
                (not (memq 'roach-warren bldg-types))
                (>= minerals 150))
       (emit! (list 'build 'roach-warren (+ base-x 56) (- base-y 56)))
       (set! minerals (- minerals 150)))

     (when (and (memq 'spawning-pool bldg-types)
                (null? queens)
                (>= minerals 150)
                (can-spend-supply? 2))
       (emit! '(train queen))
       (set! minerals (- minerals 150)))

     (when (and (memq 'roach-warren bldg-types) (>= gas 100))
       (emit! '(morph ravager))
       (when (not (memq 'lair bldg-types))
         (emit! '(research zergling-speed))))

     (when (and (>= minerals 300)
                (not under-early-cheese?)
                (not natural-blocked?)
                (< (length hatcheries) 2))
       (emit! (list 'expand nat-x nat-y)))

     (when (and (memq 'spawning-pool bldg-types)
                (>= minerals 250)
                (not (memq 'lair bldg-types)))
       (emit! (list 'build 'sunken-colony nat-x nat-y))
       (emit! '(morph lair)))

     (when (memq 'lair bldg-types)
       (when (not (memq 'spire bldg-types))
         (emit! (list 'build 'spire (+ base-x 80) (+ base-y 60))))
       (when (not (memq 'hydralisk-den bldg-types))
         (emit! (list 'build 'hydralisk-den (+ base-x 60) (+ base-y 80))))
       (when (not (memq 'baneling-nest bldg-types))
         (emit! (list 'build 'baneling-nest (+ base-x 40) (- base-y 40))))
       (when (and (memq 'hydralisk-den bldg-types) (>= gas 150))
         (emit! '(research lurker-aspect))))

     ;; Cloaked / Air / Spore defense & Overseer morph
     (define enemy-cloaked-or-air?
       (ormap (lambda (e)
                (or (hash-ref e 'cloaked #f)
                    (hash-ref e 'burrowed #f)
                    (memq (unit-type-sym e)
                          '(banshee dark-templar ghost lurker mutalisk void-ray carrier oracle))))
              enemy-units))
     (when (or enemy-cloaked-or-air? (memq 'spire bldg-types))
       (emit! (list 'build 'spore-crawler (+ base-x 32) (+ base-y 32)))
       (emit! '(morph overseer)))

     ;; Overseer Changeling scout (Pro Mechanic #5)
     (define overseers (filter (lambda (u) (eq? (unit-type-sym u) 'overseer)) ally-units))
     (for ([ov (in-list overseers)])
       (when (>= (hash-ref ov 'energy 50) 50)
         (emit! (list 'cast (hash-ref ov 'id 190) 'spawn-changeling enemy-x enemy-y))))

     (when (and (memq 'spire bldg-types) (memq 'hydralisk-den bldg-types))
       (emit! '(morph lurker))
       (emit! '(morph hive)))

     ;; Zerg Unit Training
     (cond
       [(and (memq 'spire bldg-types) (>= minerals 150) (>= gas 100) (can-spend-supply? 2))
        (emit! '(train corruptor))
        (emit! '(train mutalisk))
        (when (memq 'hydralisk-den bldg-types)
          (emit! '(train hydralisk))
          (emit! '(train lurker)))]
       [(and (memq 'lair bldg-types) (>= minerals 150) (can-spend-supply? 2))
        (emit! '(train roach))]
       [(and (memq 'spawning-pool bldg-types) (>= minerals 50) (can-spend-supply? 1))
        (when (or (memq 'baneling-nest bldg-types) (>= gas 25))
          (emit! '(morph baneling))
          (emit! '(train baneling)))
        (emit! '(train zergling))])

     (when (and (< total-workers 22) (>= minerals 50) (can-spend-supply? 1))
       (emit! '(train drone)))]

    [(Protoss)
     ;; 1. Pro Mechanic #6: Dynamic 11-Structure Chrono Boost Target Shifting
     (define nexuses (filter (lambda (b) (eq? (unit-type-sym b) 'nexus)) ally-bldgs))
     (for ([nx (in-list nexuses)])
       (when (>= (hash-ref nx 'energy 50) 50)
         (define nx-id (hash-ref nx 'id 201))
         ;; If early game (< 18 workers and < 1500 frame), chrono Nexus; otherwise shift to highest priority structure
         (define chrono-target
           (if (and (< total-workers 18) (< frame 1500))
               nx
               (or (for/or ([prio-type (in-list PRO-CHRONO-11-STRUCTURES)]
                            #:when (not (eq? prio-type 'nexus)))
                     (findf (lambda (b) (eq? (unit-type-sym b) prio-type)) ally-bldgs))
                   nx)))
         (emit! (list 'cast-spell nx-id 'chrono-boost (hash-ref chrono-target 'id nx-id)))))

     ;; 2. Pro Mechanic #3: Protoss 1-Tile Hold-Position Door Guard + Group Steal
     (define door-guards
       (filter (lambda (u) (memq (unit-type-sym u) '(zealot adept))) ally-units))
     (when (and (not (null? door-guards))
                (or (hash-ref obs 'door-guard #f)
                    (and (memq 'gateway bldg-types) (< frame 3000) (not (null? enemy-units)))))
       (define dg (car door-guards))
       (define dg-id (hash-ref dg 'id 703))
       (emit! (list 'hold-position dg-id nat-x nat-y))
       (emit! (list 'control-group-steal 2 (list dg-id)))
       (cortex-steal-control-group! (live-bot-runtime-cortex rt) 2 (list dg-id)))

     ;; 3. Protoss Tech & Wall-Off Buildings
     (when (and (not (memq 'gateway bldg-types)) (>= minerals 150))
       (emit! (list 'build 'gateway (+ base-x 64) (+ base-y 64)))
       (set! minerals (- minerals 150)))

     (when (and (memq 'gateway bldg-types)
                (not (memq 'cybernetics-core bldg-types))
                (>= minerals 150))
       (emit! (list 'build 'cybernetics-core (+ base-x 96) (+ base-y 64)))
       (emit! (list 'build 'assimilator (+ base-x 64) (+ base-y 64))))

     (when (and (memq 'cybernetics-core bldg-types)
                (not (memq 'robotics-facility bldg-types))
                (>= minerals 200))
       (emit! (list 'build 'robotics-facility (+ base-x 96) (+ base-y 96)))
       (emit! '(morph warpgate)))

     (when (and (memq 'robotics-facility bldg-types)
                (not (memq 'robotics-support-bay bldg-types))
                (>= minerals 200))
       (emit! (list 'build 'robotics-support-bay (+ base-x 100) (+ base-y 100)))
       (emit! '(research ground-weapons-1))
       (emit! (list 'build 'photon-cannon nat-x nat-y)))

     (when (and (>= minerals 400)
                (not under-early-cheese?)
                (not natural-blocked?)
                (< (length nexuses) 2))
       (emit! (list 'expand nat-x nat-y)))

     ;; Protoss Unit Training
     (when (can-spend-supply? 2)
       (cond
         [(memq 'robotics-facility bldg-types)
          (emit! '(train observer))
          (emit! '(train immortal))
          (emit! '(train reaver))
          (emit! '(train colossus))
          (emit! '(train shuttle))
          (emit! '(train sentry))
          (emit! '(train dragoon))]
         [(memq 'cybernetics-core bldg-types)
          (emit! '(train stalker))
          (emit! '(train sentry))
          (emit! '(train dragoon))
          (emit! '(train zealot))]
         [(memq 'gateway bldg-types)
          (emit! '(train zealot))]))

     (when (and (< total-workers 22) (>= minerals 50) (can-spend-supply? 1))
       (emit! '(train probe)))]

    [(Terran)
     ;; 1. Orbital Command Morph, MULE Calldown & Scanner Sweep
     (define ccs
       (filter (lambda (b) (memq (unit-type-sym b) '(command-center orbital-command planetary-fortress)))
               ally-bldgs))
     (for ([cc (in-list ccs)])
       (define ctype (unit-type-sym cc))
       (define cid (hash-ref cc 'id 301))
       (define cenergy (hash-ref cc 'energy 50))
       (cond
         [(and (eq? ctype 'command-center) (memq 'barracks bldg-types))
          (emit! (list 'morph cid 'orbital-command))]
         [(eq? ctype 'orbital-command)
          (define enemy-cloaked?
            (ormap (lambda (e)
                     (or (hash-ref e 'cloaked #f)
                         (hash-ref e 'burrowed #f)
                         (memq (unit-type-sym e) '(lurker dark-templar banshee ghost))))
                   enemy-units))
          (if (and enemy-cloaked? (>= cenergy 50))
              (emit! (list 'cast-spell cid 'scanner-sweep 1040 1120))
              (when (>= cenergy 50)
                (emit! (list 'cast-spell cid 'calldown-mule 504))))]))

     ;; 2. Pro Mechanic #3: Terran Addon Swap (Barracks Reactor -> Factory)
     (define rax-with-reactor
       (findf (lambda (b)
                (or (eq? (unit-type-sym b) 'barracks-reactor)
                    (and (eq? (unit-type-sym b) 'barracks)
                         (eq? (hash-ref b 'addon #f) 'reactor))))
              ally-bldgs))
     (define fac-needing-addon
       (findf (lambda (b)
                (and (eq? (unit-type-sym b) 'factory)
                     (not (hash-ref b 'addon #f))))
              ally-bldgs))
     (when (and rax-with-reactor fac-needing-addon)
       (emit! (list 'swap-addon
                    (hash-ref rax-with-reactor 'id 704)
                    (hash-ref fac-needing-addon 'id 705))))

     ;; 3. Terran Tech Buildings & Upgrades
     (when (and (not (memq 'barracks bldg-types)) (>= minerals 150))
       (emit! (list 'build 'barracks (+ base-x 64) (+ base-y 64)))
       (set! minerals (- minerals 150)))

     (when (and (memq 'barracks bldg-types)
                (not (memq 'refinery bldg-types))
                (>= minerals 75))
       (emit! (list 'build 'refinery (+ base-x 48) (+ base-y 80)))
       (emit! (list 'build 'factory (+ base-x 96) (+ base-y 64)))
       (emit! (list 'build 'barracks-techlab (+ base-x 64) (+ base-y 96))))

     (when (and (memq 'factory bldg-types) (>= minerals 150))
       (emit! (list 'build 'factory-techlab (+ base-x 128) (+ base-y 64)))
       (emit! (list 'build 'machine-shop (+ base-x 100) (+ base-y 60)))
       (emit! '(research siege-mode))
       (when (not (memq 'starport bldg-types))
         (emit! (list 'build 'starport (+ base-x 96) (+ base-y 112)))))

     (when (and (memq 'starport bldg-types) (>= minerals 150))
       (emit! (list 'build 'science-facility (+ base-x 120) (+ base-y 100)))
       (emit! (list 'build 'covert-ops (+ base-x 150) (+ base-y 100)))
       (emit! (list 'build 'engineering-bay (+ base-x 80) (- base-y 48)))
       (emit! (list 'build 'missile-turret (+ base-x 32) (+ base-y 32)))
       (emit! '(research lockdown)))

     (when (and (>= minerals 400)
                (not under-early-cheese?)
                (not natural-blocked?)
                (< (length ccs) 2))
       (emit! (list 'expand nat-x nat-y)))

     ;; Terran Unit Training (including Widow Mine & Siege Tank & Bio)
     (when (can-spend-supply? 2)
       (cond
         [(memq 'starport bldg-types)
          (emit! '(train siege-tank))
          (emit! '(train science-vessel))
          (emit! '(train viking))
          (emit! '(train ghost))
          (emit! '(train widow-mine))
          (emit! '(train marauder))
          (emit! '(train medic))
          (emit! '(train marine))]
         [(memq 'factory bldg-types)
          (emit! '(train siege-tank))
          (emit! '(train widow-mine))
          (emit! '(train hellion))
          (emit! '(train vulture))
          (emit! '(train marauder))
          (emit! '(train marine))]
         [(memq 'barracks bldg-types)
          (emit! '(train marine))]))

     (when (and (< total-workers 22) (>= minerals 50) (can-spend-supply? 1))
       (emit! '(train scv)))])

  ;; ---------------------------------------------------------------------------
  ;; Pro Mechanic #7: Camera Bookmark Save (Slot 1 = Main Base)
  ;; ---------------------------------------------------------------------------
  (unless (live-bot-runtime-bookmarks-initialized? rt)
    (set-live-bot-runtime-bookmarks-initialized?! rt #t)
    (cortex-save-camera-bookmark! (live-bot-runtime-cortex rt) 1 base-x base-y)
    (emit! (list 'camera-bookmark-save 1 base-x base-y)))

  (reverse actions))

;; =============================================================================
;; Layer 3 & 4: Squad Split (Monoidal Finger Tree), Tactical Micro, Spells,
;;              Transport Juggle & Adversarial Anti-ForceField / Anti-Kite Leash
;; =============================================================================

(define (step-layer3-and-4-tactics! rt obs fap-score)
  (define ally-units (hash-ref obs 'ally-units '()))
  (define enemy-units (hash-ref obs 'enemy-units '()))
  (define enemy-bldgs (hash-ref obs 'enemy-buildings '()))
  (define effects (hash-ref obs 'effects '()))
  (define base-x (hash-ref obs 'base-x 700))
  (define base-y (hash-ref obs 'base-y 760))
  (define nat-x (hash-ref obs 'natural-x 1024))
  (define nat-y (hash-ref obs 'natural-y 1120))
  (define enemy-x (hash-ref obs 'enemy-x 1600))
  (define enemy-y (hash-ref obs 'enemy-y 1600))

  (define combat-units (filter combat-unit-record? ally-units))
  (define ft (perception-grid-squad-finger-tree (live-bot-runtime-perception rt)))
  (define total-dps (combat-measure-dps (ft-measure ft)))
  (define-values (vanguard-ft reserve-ft)
    (split-by-dps ft (exact-ceiling (* 0.70 total-dps))))
  (define vanguard-count (combat-measure-count (ft-measure vanguard-ft)))
  (define reserve-count (combat-measure-count (ft-measure reserve-ft)))

  (define actions '())
  (define (emit! act)
    (set! actions (cons act actions)))

  ;; ---------------------------------------------------------------------------
  ;; Scenario 9: Nuclear Strike / Nuke Calldown Alert Evasion
  ;; ---------------------------------------------------------------------------
  (define nuke-alert (hash-ref obs 'nuke-alert #f))
  (when nuke-alert
    (define nx (if (pair? nuke-alert) (car nuke-alert) 1024))
    (define ny (if (pair? nuke-alert) (cdr nuke-alert) 1120))
    (for ([u (in-list ally-units)])
      (when (<= (dist2d nx ny (hash-ref u 'x nx) (hash-ref u 'y ny)) 256)
        (emit! (list 'kite (hash-ref u 'id 101) base-x base-y)))))

  ;; ---------------------------------------------------------------------------
  ;; Scenario 4: Hidden / Corner Flying Building Search when Enemy Base Cleared
  ;; ---------------------------------------------------------------------------
  (when (and (hash-ref obs 'enemy-main-cleared #f)
             (null? enemy-units)
             (null? enemy-bldgs)
             (not (null? combat-units)))
    (define corners '((160 . 160) (160 . 1880) (1880 . 160) (1880 . 1880)))
    (for ([u (in-list combat-units)]
          [idx (in-naturals)])
      (define c (list-ref corners (modulo idx (length corners))))
      (emit! (list 'attack-pos (hash-ref u 'id 101) (car c) (cdr c)))))

  ;; ---------------------------------------------------------------------------
  ;; Pro Mechanic #4: Active Transport Juggling (Load/Unload) & Multi-Prong Drop
  ;; ---------------------------------------------------------------------------
  (define transports
    (filter (lambda (u) (memq (unit-type-sym u) '(warp-prism shuttle medivac overlord-transport)))
            ally-units))
  (for ([tr (in-list transports)])
    (define tr-id (hash-ref tr 'id 706))
    (define tx (hash-ref tr 'x base-x))
    (define ty (hash-ref tr 'y base-y))
    (define wounded-passenger
      (findf (lambda (u)
               (and (combat-unit-record? u)
                    (<= (dist2d tx ty (hash-ref u 'x tx) (hash-ref u 'y ty)) 160)
                    (or (< (hash-ref u 'hp 100) 55)
                        (< (/ (exact->inexact (hash-ref u 'hp 100))
                              (max 1 (hash-ref u 'max-hp 100)))
                           0.45))))
             combat-units))
    (if wounded-passenger
        (emit! (list 'transport-juggle tr-id (hash-ref wounded-passenger 'id 707) base-x base-y))
        (emit! (list 'multi-prong-drop tr-id enemy-x enemy-y))))

  ;; ---------------------------------------------------------------------------
  ;; Adversarial Countermeasure #5: Ramp Force-Field Corrosive-Bile Breaker
  ;; ---------------------------------------------------------------------------
  (define force-fields
    (append
     (filter (lambda (eff) (eq? (hash-ref eff 'type 'none) 'force-field)) effects)
     (filter (lambda (e) (eq? (unit-type-sym e) 'force-field)) enemy-units)))
  (when (not (null? force-fields))
    (define ff (car force-fields))
    (define ffx (hash-ref ff 'x nat-x))
    (define ffy (hash-ref ff 'y nat-y))
    (define ravagers (filter (lambda (u) (eq? (unit-type-sym u) 'ravager)) ally-units))
    (for ([rav (in-list ravagers)])
      (emit! (list 'cast-spell (hash-ref rav 'id 140) 'corrosive-bile ffx ffy)))
    ;; Pull back trapped ground units behind ramp
    (for ([u (in-list combat-units)])
      (when (not (eq? (unit-type-sym u) 'ravager))
        (emit! (list 'kite (hash-ref u 'id 101) base-x base-y)))))

  ;; ---------------------------------------------------------------------------
  ;; Adversarial Countermeasure #5b: Anti-Kite Defensive Leash
  ;; ---------------------------------------------------------------------------
  (define lone-kiter?
    (and (= (length enemy-units) 1)
         (memq (unit-type-sym (car enemy-units))
               '(reaper hellion adept stalker oracle phoenix mutalisk))
         (< (length combat-units) 6)))
  (when lone-kiter?
    (for ([u (in-list combat-units)])
      (when (and (memq (unit-type-sym u) '(zealot zergling roach immortal))
                 (> (dist2d base-x base-y (hash-ref u 'x base-x) (hash-ref u 'y base-y)) 260))
        (emit! (list 'kite (hash-ref u 'id 101) nat-x nat-y)))))

  ;; ---------------------------------------------------------------------------
  ;; Active Combat Spells & Engagement Micro
  ;; ---------------------------------------------------------------------------
  (when (not (null? enemy-units))
    (define primary-enemy (car enemy-units))
    (define eid (hash-ref primary-enemy 'id 9001))
    (define ex (hash-ref primary-enemy 'x 1040))
    (define ey (hash-ref primary-enemy 'y 1120))

    ;; Queen transfusion on wounded ally
    (define queens (filter (lambda (u) (eq? (unit-type-sym u) 'queen)) ally-units))
    (define wounded-ally
      (findf (lambda (u) (< (hash-ref u 'hp 100) (hash-ref u 'max-hp 150))) combat-units))
    (for ([q (in-list queens)])
      (when (and wounded-ally (>= (hash-ref q 'energy 50) 50))
        (emit! (list 'cast-spell (hash-ref q 'id 120) 'transfusion (hash-ref wounded-ally 'id 141)))))

    (for ([u (in-list combat-units)])
      (define ut (unit-type-sym u))
      (define uid (hash-ref u 'id 101))
      (define ux (hash-ref u 'x base-x))
      (define uy (hash-ref u 'y base-y))
      (define u-hp (hash-ref u 'hp 100))
      (case ut
        [(ravager)
         (emit! (list 'cast-spell uid 'corrosive-bile ex ey))
         (emit! (list 'attack-unit uid eid))]
        [(lurker widow-mine)
         (emit! (list 'cast-spell uid 'burrow eid))
         (emit! (list 'attack-unit uid eid))]
        [(sentry)
         (if (>= (hash-ref u 'energy 50) 75)
             (emit! (list 'cast-spell uid 'guardian-shield eid))
             (emit! (list 'cast-spell uid 'force-field 1015 1105)))
         (emit! (list 'attack-unit uid eid))]
        [(stalker)
         (when (< u-hp 80)
           (define-values (kx ky) (compute-kite-vector ux uy ex ey 64))
           (emit! (list 'cast-spell uid 'blink kx ky)))
         (emit! (list 'attack-unit uid eid))]
        [(adept)
         (emit! (list 'cast uid 'psionic-transfer ex ey))
         (emit! (list 'attack-unit uid eid))]
        [(siege-tank)
         (if (hash-ref u 'sieged #f)
             (emit! (list 'cast-spell uid 'unsiege-mode uid))
             (emit! (list 'cast-spell uid 'siege-mode eid)))
         (emit! (list 'attack-unit uid eid))]
        [(ghost)
         (emit! (list 'cast-spell uid 'emp-round eid))
         (emit! (list 'cast-spell uid 'snipe eid))
         (emit! (list 'attack-unit uid eid))]
        [(marine marauder)
         (when (>= u-hp 40)
           (emit! (list 'cast-spell uid 'stimpack eid)))
         (emit! (list 'attack-unit uid eid))]
        [(mutalisk)
         (if (< u-hp 60)
             (let-values ([(kx ky) (compute-kite-vector ux uy ex ey 64)])
               (emit! (list 'kite uid kx ky)))
             (emit! (list 'attack-unit uid eid)))]
        [else
         (emit! (list 'attack-unit uid eid))])))

  (when (and (null? enemy-units) (>= (length combat-units) 2))
    (for ([u (in-list (take combat-units 2))])
      (emit! (list 'attack-pos (hash-ref u 'id 110) nat-x nat-y))))

  (values (reverse actions) vanguard-count reserve-count))

;; =============================================================================
;; Layer 5: Human Cortex Camera Saccades, Ability Throttling & Token Filtering
;; =============================================================================

(define (step-layer5-human-cortex! rt raw-actions obs)
  (define frame (hash-ref obs 'frame 0))
  (define limiter (live-bot-runtime-cast-limiter rt))
  (define cortex (live-bot-runtime-cortex rt))

  ;; 1. Refractory ability cast limiter
  (define-values (unthrottled-actions spell-throttled)
    (throttle-ability-casts! limiter raw-actions frame))

  ;; 2. Check if camera needs to saccade to combat/target focal point
  (define enemy-units (hash-ref obs 'enemy-units '()))
  (define cam-actions
    (cond
      [(and (not (null? enemy-units))
            (not (in-camera-viewport? (human-cortex-cam-x cortex)
                                      (human-cortex-cam-y cortex)
                                      (hash-ref (car enemy-units) 'x 600)
                                      (hash-ref (car enemy-units) 'y 700))))
       (define tx (hash-ref (car enemy-units) 'x 600))
       (define ty (hash-ref (car enemy-units) 'y 700))
       (cortex-move-camera! cortex tx ty)
       (list (list 'move-camera tx ty))]
      [else
       (cortex-move-camera! cortex
                            (human-cortex-cam-x cortex)
                            (human-cortex-cam-y cortex))
       '()]))

  (define combined (append cam-actions unthrottled-actions))
  (define-values (accepted dropped)
    (cortex-filter-actions! cortex combined))
  (values accepted dropped spell-throttled))

;; =============================================================================
;; Top-Level 5-Layer Step (`step-live-bot-runtime!`)
;; =============================================================================

(define (step-live-bot-runtime! rt [obs-or-sexp (hash)])
  (define obs
    (cond
      [(hash? obs-or-sexp) obs-or-sexp]
      [(pair? obs-or-sexp) (parse-frame-state-sexp obs-or-sexp)]
      [(string? obs-or-sexp) (parse-frame-state-sexp (read (open-input-string obs-or-sexp)))]
      [else (hash)]))

  (set-live-bot-runtime-step-count! rt (add1 (live-bot-runtime-step-count rt)))

  ;; Layer 1
  (step-layer1-perception! rt obs)
  ;; Layer 1b
  (define-values (posture-acts fap-score) (step-layer1b-mastermind! rt obs))
  ;; Layer 1c (Generic k-Level Mirror-Mind Opponent Prediction Layer)
  (define mirror-acts (step-layer1c-mirror-mind! rt obs))
  ;; Layer 2
  (define econ-acts (step-layer2-economy! rt obs))
  ;; Layer 3 & 4
  (define-values (tactic-acts vanguard-cnt reserve-cnt)
    (step-layer3-and-4-tactics! rt obs fap-score))

  (define raw-actions (append posture-acts econ-acts tactic-acts))

  ;; Layer 5
  (define-values (accepted dropped spell-throttled)
    (step-layer5-human-cortex! rt raw-actions obs))

  (define cortex (live-bot-runtime-cortex rt))
  (define mstate (live-bot-runtime-mastermind rt))
  (define mmstate (live-bot-runtime-mirror-mind rt))
  (define mmledger (mirror-mind-state-last-shadow-ledger mmstate))
  (define mmalloc (mirror-mind-state-toolbox-allocation mmstate))
  (define pda
    (make-pda-trace #:scouted-sectors 8
                    #:posture-switches 1
                    #:actions-emitted (+ (length accepted) dropped spell-throttled)
                    #:actions-dropped (+ dropped spell-throttled)))

  (define telemetry
    (hash 'posture (live-bot-runtime-posture rt)
          'actual-race (live-bot-runtime-actual-race rt)
          'epm (* 71 (human-cortex-accepted-count cortex))
          'accepted (length accepted)
          'dropped dropped
          'spell-throttled spell-throttled
          'cam-x (human-cortex-cam-x cortex)
          'cam-y (human-cortex-cam-y cortex)
          'fixation (human-cortex-fixation-frames cortex)
          'fap-score fap-score
          'fap-posture (fap-posture-with-hysteresis fap-score 'hold)
          'enemy-archetype (mastermind-state-enemy-archetype mstate)
          'mastermind-unit (mastermind-state-selected-unit mstate)
          'mastermind-directive (mastermind-state-directive mstate)
          'double-reactions (mastermind-state-double-reactions mstate)
          'flank-angle-idx (mastermind-state-flank-angle-idx mstate)
          'compounding-dominant (mastermind-state-compounding-dominant mstate)
          'mirror-active-depth (mirror-mind-state-active-depth mmstate)
          'mirror-inferred-opponent-depth (mirror-mind-state-inferred-opponent-depth mmstate)
          'mirror-last-probe-response (mirror-mind-state-last-probe-response mmstate)
          'mirror-toolbox-weight (mirror-toolbox-allocation-toolbox-weight mmalloc)
          'mirror-primary-macro-weight (mirror-toolbox-allocation-primary-macro-weight mmalloc)
          'mirror-toolbox-role (mirror-toolbox-allocation-toolbox-role mmalloc)
          'mirror-allow-unit-hedge? (mirror-toolbox-allocation-allow-unit-hedge? mmalloc)
          'mirror-allow-posture-override? (mirror-toolbox-allocation-allow-posture-override? mmalloc)
          'mirror-opp-belief-about-us (mirror-mind-state-opp-belief-about-us mmstate)
          'mirror-strategic-hypothesis (mirror-mind-state-strategic-hypothesis mmstate)
          'mirror-tactical-target (mirror-mind-state-tactical-target mmstate)
          'mirror-predicted-enemy-unit (mirror-mind-state-predicted-enemy-unit mmstate)
          'mirror-preemptive-unit (mirror-mind-state-preemptive-counter-unit mmstate)
          'mirror-strategic-accuracy (mirror-mind-state-strategic-accuracy mmstate)
          'mirror-tactical-accuracy (mirror-mind-state-tactical-accuracy mmstate)
          'mirror-overall-accuracy (mirror-mind-state-overall-accuracy mmstate)
          'mirror-trust-mode (mirror-mind-state-trust-mode mmstate)
          'mirror-unaccounted-minerals (shadow-ledger-unaccounted-minerals mmledger)
          'mirror-unaccounted-gas (shadow-ledger-unaccounted-gas mmledger)
          'vanguard-count vanguard-cnt
          'reserve-count reserve-cnt
          'personality (bot-personality-name (mastermind-state-personality mstate))
          'pda-bucket (diagnose-bot-anomaly pda)))

  (set-live-bot-runtime-last-telemetry! rt telemetry)
  (hash 'actions accepted
        'mirror-actions mirror-acts
        'telemetry telemetry
        'posture (live-bot-runtime-posture rt)
        'actual-race (live-bot-runtime-actual-race rt)))

;; =============================================================================
;; S-Expression Wire Parser for `sim/racket_sc2_ipc_bot.rkt`
;; =============================================================================

(define (parse-unit-tuple tup)
  (match tup
    [(list id type x y hp energy)
     (hash 'id id 'type type 'x (exact-round x) 'y (exact-round y) 'hp hp 'energy energy)]
    [(list id type x y hp)
     (hash 'id id 'type type 'x (exact-round x) 'y (exact-round y) 'hp hp)]
    [(? hash? h) h]
    [_ (hash 'id 101 'type 'zergling 'x 600 'y 700 'hp 35)]))

(define (parse-bldg-tuple tup)
  (match tup
    [(list id type x y hp-pct build-prog halted-flag)
     (hash 'id id
           'type type
           'x (exact-round x)
           'y (exact-round y)
           'hp (exact-round (* 500 hp-pct))
           'hp-pct hp-pct
           'build-progress build-prog
           'halted (eq? halted-flag #t))]
    [(list id type x y hp)
     (hash 'id id 'type type 'x (exact-round x) 'y (exact-round y) 'hp hp)]
    [(? hash? h) h]
    [_ (hash 'id 201 'type 'hatchery 'x 700 'y 760 'hp 1500)]))

(define (parse-effect-tuple tup)
  (match tup
    [(list type x y)
     (hash 'type type 'x (exact-round x) 'y (exact-round y))]
    [(? hash? h) h]
    [_ (hash 'type 'none 'x 0 'y 0)]))

(define (parse-frame-state-sexp sexp)
  (match sexp
    [(cons 'frame-state kvs)
     (define h (make-hash))
     (let loop ([rem kvs])
       (match rem
         [(list* k v rest)
          (define key-str (if (keyword? k) (keyword->string k) (format "~a" k)))
          (case (string->symbol key-str)
            [(frame)          (hash-set! h 'frame v)]
            [(race)           (hash-set! h 'race v)]
            [(minerals)       (hash-set! h 'minerals v)]
            [(gas)            (hash-set! h 'gas v)]
            [(supply-used)    (hash-set! h 'supply-used v)]
            [(supply-cap)     (hash-set! h 'supply-cap v)]
            [(supply-left)    (hash-set! h 'supply-left v)]
            [(pending-supply) (hash-set! h 'pending-supply v)]
            [(start-pos)
             (when (and (list? v) (= (length v) 2))
               (hash-set! h 'base-x (exact-round (first v)))
               (hash-set! h 'base-y (exact-round (second v))))]
            [(enemy-base)
             (when (and (list? v) (= (length v) 2))
               (hash-set! h 'enemy-x (exact-round (first v)))
               (hash-set! h 'enemy-y (exact-round (second v))))]
            [(my-units)       (hash-set! h 'ally-units (map parse-unit-tuple v))]
            [(my-buildings)   (hash-set! h 'ally-buildings (map parse-bldg-tuple v))]
            [(enemy-units)    (hash-set! h 'enemy-units (map parse-unit-tuple v))]
            [(enemy-buildings)(hash-set! h 'enemy-buildings (map parse-bldg-tuple v))]
            [(effects)        (hash-set! h 'effects (map parse-effect-tuple v))])
          (loop rest)]
         [_ (void)]))
     h]
    [_ (hash)]))

(define (runtime-step-sexp! rt sexp)
  (define res (step-live-bot-runtime! rt sexp))
  (append (hash-ref res 'mirror-actions '())
          (hash-ref res 'actions '())))
