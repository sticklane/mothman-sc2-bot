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
 step-pro-human-camera-and-apm-governor!
 step-live-bot-runtime!
 parse-frame-state-sexp
 runtime-step-sexp!
 filter-rush-threat-enemies
 compute-next-posture)

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
;; Total Numeric, Coordinate, and Observation Sanitizers
;; =============================================================================

(define (finite-real? v)
  (and (number? v) (real? v) (not (nan? v)) (not (infinite? v))))

(define (safe-finite-real v [default 0.0])
  (if (finite-real? v) (exact->inexact v) default))

(define (safe-exact-int v [default 0])
  (if (finite-real? v) (exact-round v) default))

(define (safe-nonneg-int v [default 0])
  (max 0 (safe-exact-int v default)))

(define (safe-coord v [default 700])
  (min 16383 (max 0 (safe-exact-int v default))))

(define (dist2d x1 y1 x2 y2)
  (define sx1 (safe-finite-real x1 0.0))
  (define sy1 (safe-finite-real y1 0.0))
  (define sx2 (safe-finite-real x2 0.0))
  (define sy2 (safe-finite-real y2 0.0))
  (sqrt (+ (sqr (- sx2 sx1)) (sqr (- sy2 sy1)))))

(define (unit-type-sym u)
  (cond
    [(hash? u)
     (define raw (hash-ref u 'type 'unknown))
     (cond
       [(symbol? raw) raw]
       [(string? raw) (string->symbol (string-downcase raw))]
       [else 'unknown])]
    [(symbol? u) u]
    [(string? u) (string->symbol (string-downcase u))]
    [else 'unknown]))

(define NON-COMBAT-AND-SCOUT-ENEMY-SYMS
  '(overlord overseer observer overlord-transport overseer-siege-mode observer-siege-mode
    changeling changeling-zealot changeling-marine changeling-marine-shield
    changeling-zergling changeling-zergling-wings
    larva egg cocoon overlord-cocoon baneling-cocoon ravager-cocoon
    brood-lord-cocoon lurker-mp-egg mule
    adept-phase-shift disruptor-phased kd8-charge parasitic-bomb-dummy))

(define NON-WORKER-PULL-ENEMY-UNIT-SYMS
  (append NON-COMBAT-AND-SCOUT-ENEMY-SYMS
          '(mutalisk corruptor brood-lord broodlord viper
            phoenix oracle void-ray voidray carrier tempest mothership mothership-core
            warp-prism warp-prism-phasing interceptor
            viking viking-fighter medivac liberator liberator-ag banshee raven
            battlecruiser point-defense-drone)))

(define (combat-unit-record? u)
  (and (hash? u)
       (not (memq (unit-type-sym u) WORKER-AND-NONCOMBAT-SYMS))
       (not (memq (unit-type-sym u) NON-COMBAT-AND-SCOUT-ENEMY-SYMS))))

(define (sanitize-unit-record u [default-x 700] [default-y 760])
  (cond
    [(hash? u)
     (define base-h (for/hash ([(k v) (in-hash u)]) (values k v)))
     (define id (safe-nonneg-int (hash-ref base-h 'id 101) 101))
     (define utype (unit-type-sym base-h))
     (define x (safe-coord (hash-ref base-h 'x default-x) default-x))
     (define y (safe-coord (hash-ref base-h 'y default-y) default-y))
     (define hp (max 1 (safe-nonneg-int (hash-ref base-h 'hp 45) 45)))
     (define h1 (hash-set* base-h 'id id 'type utype 'x x 'y y 'hp hp))
     (define h2
       (if (hash-has-key? h1 'max-hp)
           (hash-set h1 'max-hp (max 1 (safe-nonneg-int (hash-ref h1 'max-hp hp) hp)))
           h1))
     (define h3
       (if (hash-has-key? h2 'hp-pct)
           (hash-set h2 'hp-pct (max 0.0 (min 1.0 (safe-finite-real (hash-ref h2 'hp-pct 1.0) 1.0))))
           h2))
     (define h4
       (if (hash-has-key? h3 'shield)
           (hash-set h3 'shield (safe-nonneg-int (hash-ref h3 'shield 0) 0))
           h3))
     (define h5
       (if (hash-has-key? h4 'energy)
           (hash-set h4 'energy (safe-nonneg-int (hash-ref h4 'energy 0) 0))
           h4))
     (define h6
       (if (hash-has-key? h5 'dps)
           (hash-set h5 'dps (safe-nonneg-int (hash-ref h5 'dps 12) 12))
           h5))
     (define h7
       (if (hash-has-key? h6 'z)
           (hash-set h6 'z (safe-exact-int (hash-ref h6 'z 10) 10))
           h6))
     (define h8
       (if (hash-has-key? h7 'speed)
           (hash-set h7 'speed (max 0.0 (safe-finite-real (hash-ref h7 'speed 3.0) 3.0)))
           h7))
     (define h9
       (if (hash-has-key? h8 'atk-upg)
           (hash-set h8 'atk-upg (safe-nonneg-int (hash-ref h8 'atk-upg 0) 0))
           h8))
     (define h10
       (if (hash-has-key? h9 'arm-upg)
           (hash-set h9 'arm-upg (safe-nonneg-int (hash-ref h9 'arm-upg 0) 0))
           h9))
     (define h11
       (if (hash-has-key? h10 'shd-upg)
           (hash-set h10 'shd-upg (safe-nonneg-int (hash-ref h10 'shd-upg 0) 0))
           h10))
     (define h12
       (if (hash-has-key? h11 'damage-rate-ratio)
           (hash-set h11 'damage-rate-ratio (max 0.0 (safe-finite-real (hash-ref h11 'damage-rate-ratio 1.0) 1.0)))
           h11))
     (define h13
       (if (hash-has-key? h12 'damage-taken-multiplier)
           (hash-set h12 'damage-taken-multiplier (max 0.0 (safe-finite-real (hash-ref h12 'damage-taken-multiplier 1.0) 1.0)))
           h12))
     h13]
    [else
     (hash 'id 101 'type 'zergling 'x default-x 'y default-y 'hp 35)]))

(define (sanitize-bldg-record b [default-x 700] [default-y 760])
  (cond
    [(hash? b)
     (define u-san (sanitize-unit-record b default-x default-y))
     (define hp (hash-ref u-san 'hp 500))
     (define max-hp (max 1 (safe-nonneg-int (hash-ref u-san 'max-hp (max 500 hp)) (max 500 hp))))
     (define hp-pct
       (max 0.0 (min 1.0 (safe-finite-real (hash-ref u-san 'hp-pct (/ (exact->inexact hp) (exact->inexact max-hp))) 1.0))))
     (define prog
       (max 0.0 (min 1.0 (safe-finite-real (hash-ref u-san 'build-progress (if (hash-ref u-san 'under-construction #f) 0.5 1.0)) 1.0))))
     (define b1
       (hash-set* u-san
                  'max-hp max-hp
                  'hp-pct hp-pct
                  'build-progress prog))
     (define b2
       (if (hash-has-key? b1 'ideal-harvesters)
           (hash-set b1 'ideal-harvesters (safe-nonneg-int (hash-ref b1 'ideal-harvesters 16) 16))
           b1))
     (define b3
       (if (hash-has-key? b2 'assigned-harvesters)
           (hash-set b2 'assigned-harvesters (safe-nonneg-int (hash-ref b2 'assigned-harvesters 16) 16))
           b2))
     b3]
    [else
     (hash 'id 201 'type 'hatchery 'x default-x 'y default-y 'hp 1500 'max-hp 1500 'hp-pct 1.0 'build-progress 1.0)]))

(define (sanitize-effect-record eff)
  (cond
    [(hash? eff)
     (define raw-t (hash-ref eff 'type 'none))
     (define t (if (symbol? raw-t) raw-t 'none))
     (hash 'type t
           'x (safe-coord (hash-ref eff 'x 0) 0)
           'y (safe-coord (hash-ref eff 'y 0) 0))]
    [(and (list? eff) (= (length eff) 3))
     (hash 'type (if (symbol? (first eff)) (first eff) 'none)
           'x (safe-coord (second eff) 0)
           'y (safe-coord (third eff) 0))]
    [else
     (hash 'type 'none 'x 0 'y 0)]))

(define (sanitize-obs-hash obs)
  (cond
    [(not (hash? obs)) (sanitize-obs-hash (hash))]
    [else
     (define base-h (for/hash ([(k v) (in-hash obs)]) (values k v)))
     (define frame (safe-nonneg-int (hash-ref base-h 'frame 0) 0))
     (define minerals (safe-nonneg-int (hash-ref base-h 'minerals 200) 0))
     (define gas (safe-nonneg-int (hash-ref base-h 'gas 0) 0))
     (define supply-used (safe-nonneg-int (hash-ref base-h 'supply-used 12) 12))
     (define supply-cap (min 200 (safe-nonneg-int (hash-ref base-h 'supply-cap 15) 15)))
     (define supply-left
       (max 0 (safe-exact-int (hash-ref base-h 'supply-left (- supply-cap supply-used))
                              (max 0 (- supply-cap supply-used)))))
     (define pending-supply (safe-nonneg-int (hash-ref base-h 'pending-supply 0) 0))
     (define pending-workers (safe-nonneg-int (hash-ref base-h 'pending-workers 0) 0))
     (define depleting-bases
       (safe-nonneg-int (hash-ref base-h 'depleting-bases
                                  (if (or (eq? (hash-ref base-h 'mined-out #f) #t)
                                          (eq? (hash-ref base-h 'mined-out? #f) #t))
                                      1
                                      0))
                        0))
     (define busy-facilities (safe-nonneg-int (hash-ref base-h 'busy-facilities 0) 0))
     (define busy-townhalls (safe-nonneg-int (hash-ref base-h 'busy-townhalls 0) 0))
     (define enemy-workers-killed (safe-nonneg-int (hash-ref base-h 'enemy-workers-killed 0) 0))
     (define mineral-patch-id (safe-nonneg-int (hash-ref base-h 'mineral-patch-id 504) 504))
     (define base-x (safe-coord (hash-ref base-h 'base-x 700) 700))
     (define base-y (safe-coord (hash-ref base-h 'base-y 760) 760))
     (define nat-x (safe-coord (hash-ref base-h 'natural-x 1024) 1024))
     (define nat-y (safe-coord (hash-ref base-h 'natural-y 1120) 1120))
     (define third-x (safe-coord (hash-ref base-h 'third-x 1280) 1280))
     (define third-y (safe-coord (hash-ref base-h 'third-y 1280) 1280))
     (define enemy-x (safe-coord (hash-ref base-h 'enemy-x 1600) 1600))
     (define enemy-y (safe-coord (hash-ref base-h 'enemy-y 1600) 1600))
     (define raw-au (hash-ref base-h 'ally-units '()))
     (define raw-ab (hash-ref base-h 'ally-buildings '()))
     (define raw-eu (hash-ref base-h 'enemy-units '()))
     (define raw-eb (hash-ref base-h 'enemy-buildings '()))
     (define raw-eff (hash-ref base-h 'effects '()))
     (define ally-units
       (if (list? raw-au)
           (map (lambda (u) (sanitize-unit-record u base-x base-y)) raw-au)
           '()))
     (define ally-buildings
       (if (list? raw-ab)
           (map (lambda (b) (sanitize-bldg-record b base-x base-y)) raw-ab)
           '()))
     (define enemy-units
       (if (list? raw-eu)
           (map (lambda (e) (sanitize-unit-record e 1200 1200)) raw-eu)
           '()))
     (define enemy-buildings
       (if (list? raw-eb)
           (map (lambda (b) (sanitize-bldg-record b enemy-x enemy-y)) raw-eb)
           '()))
     (define effects
       (if (list? raw-eff)
           (map sanitize-effect-record raw-eff)
           '()))
     (define vis-secs
       (let ([vs (hash-ref base-h 'visible-sectors '(0 1 2 3))])
         (if (list? vs)
             (filter (lambda (idx) (and (exact-integer? idx) (>= idx 0) (< idx 64)))
                     (map (lambda (idx) (safe-exact-int idx -1)) vs))
             '(0 1 2 3))))
     (define res-upgs
       (let ([ru (hash-ref base-h 'researched-upgrades '())])
         (if (list? ru) (filter symbol? ru) '())))
     (define nuke-alert
       (let ([na (hash-ref base-h 'nuke-alert #f)])
         (cond
           [(not na) #f]
           [(pair? na) (cons (safe-coord (car na) 1024) (safe-coord (cdr na) 1120))]
           [else (cons 1024 1120)])))
     (define h1
       (hash-set* base-h
                  'frame frame
                  'minerals minerals
                  'gas gas
                  'supply-used supply-used
                  'supply-cap supply-cap
                  'supply-left supply-left
                  'pending-supply pending-supply
                  'pending-workers pending-workers
                  'depleting-bases depleting-bases
                  'busy-facilities busy-facilities
                  'busy-townhalls busy-townhalls
                  'enemy-workers-killed enemy-workers-killed
                  'mineral-patch-id mineral-patch-id
                  'base-x base-x
                  'base-y base-y
                  'natural-x nat-x
                  'natural-y nat-y
                  'third-x third-x
                  'third-y third-y
                  'enemy-x enemy-x
                  'enemy-y enemy-y
                  'ally-units ally-units
                  'ally-buildings ally-buildings
                  'enemy-units enemy-units
                  'enemy-buildings enemy-buildings
                  'effects effects
                  'visible-sectors vis-secs
                  'researched-upgrades res-upgs
                  'nuke-alert nuke-alert))
     (define h2
       (if (hash-has-key? h1 'gas-workers)
           (hash-set h1 'gas-workers (safe-nonneg-int (hash-ref h1 'gas-workers 0) 0))
           h1))
     (define h3
       (if (hash-has-key? h2 'enemy-expand-x)
           (hash-set h2 'enemy-expand-x (safe-coord (hash-ref h2 'enemy-expand-x (- enemy-x 180)) (- enemy-x 180)))
           h2))
     (define h4
       (if (hash-has-key? h3 'enemy-expand-y)
           (hash-set h3 'enemy-expand-y (safe-coord (hash-ref h3 'enemy-expand-y (- enemy-y 140)) (- enemy-y 140)))
           h3))
     (define h5
       (if (hash-has-key? h4 'our-terrain-z)
           (hash-set h4 'our-terrain-z (safe-exact-int (hash-ref h4 'our-terrain-z 10) 10))
           h4))
     (define h6
       (if (hash-has-key? h5 'enemy-terrain-z)
           (hash-set h5 'enemy-terrain-z (safe-exact-int (hash-ref h5 'enemy-terrain-z 10) 10))
           h5))
     h6]))

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

(define (step-layer1-perception! rt raw-obs)
  (define obs (sanitize-obs-hash raw-obs))
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

(define (tile-coord-space? base-x base-y)
  (and (real? base-x) (real? base-y)
       (<= base-x 256) (<= base-y 256)))

(define (coord-dist-threshold px-thresh base-x base-y)
  (if (tile-coord-space? base-x base-y)
      (* (exact->inexact px-thresh) (/ 1.0 16.0))
      (exact->inexact px-thresh)))

(define (filter-rush-threat-enemies enemy-units base-x base-y nat-x nat-y)
  (define rush-dist-thresh (coord-dist-threshold 750 base-x base-y))
  (filter (lambda (e)
            (and (hash? e)
                 (let ([t (unit-type-sym e)]
                       [ex (safe-coord (hash-ref e 'x 1024) 1024)]
                       [ey (safe-coord (hash-ref e 'y 1120) 1120)])
                   (define scout-or-dummy?
                     (or (memq t NON-COMBAT-AND-SCOUT-ENEMY-SYMS)
                         (eq? (hash-ref e 'changeling? #f) #t)
                         (eq? (hash-ref e 'hallucination? #f) #t)
                         (eq? (hash-ref e 'hallucination #f) #t)))
                   (define distant-worker?
                     (and (memq t '(drone probe scv))
                          (> (dist2d base-x base-y ex ey) rush-dist-thresh)
                          (> (dist2d nat-x nat-y ex ey) rush-dist-thresh)))
                   (and (not scout-or-dummy?)
                        (not distant-worker?)))))
          (if (list? enemy-units) enemy-units '())))

(define (compute-next-posture rt raw-obs [raw-fap-score 0])
  (define obs (sanitize-obs-hash raw-obs))
  (define fap-score (safe-finite-real (hash-ref obs 'fap-score raw-fap-score) 0.0))
  (define frame (hash-ref obs 'frame 0))
  (define cfg-race (live-bot-runtime-configured-race rt))
  (define act-race (live-bot-runtime-actual-race rt))
  (define cur (live-bot-runtime-posture rt))
  (define base-x (hash-ref obs 'base-x 700))
  (define base-y (hash-ref obs 'base-y 760))
  (define nat-x (hash-ref obs 'natural-x 1024))
  (define nat-y (hash-ref obs 'natural-y 1120))
  (define enemy-units (hash-ref obs 'enemy-units '()))
  (define rush-enemies (filter-rush-threat-enemies enemy-units base-x base-y nat-x nat-y))
  (define ally-unit-types (map unit-type-sym (hash-ref obs 'ally-units '())))
  (define ally-bldgs (map unit-type-sym (hash-ref obs 'ally-buildings '())))

  (define in-crisis?
    (not (not (memq cur '(EarlyScoutCrisis CrisisZealotRush CrisisZerglingFlood CrisisEarlyBust)))))
  (define in-victory?
    (not (not (memq cur '(MothmanApexVictory SwarmVictory ProtossArmadaVictory
                          TerranDominionVictory ChameleonSupremeVictory)))))
  (define in-midgame-recovery-or-contain?
    (not (not (memq cur '(StalkerImmortalColossus MacroHydraLurker BioTankMedivac
                          MidGameBioTankContain DragoonReaverVanguard MutaLurkerContain
                          VesselGhostPush TriRaceVanguardContain)))))

  ;; Hysteresis band [-8, -2] (±3 around -5) for crisis entry/exit
  (define rush-fap-threat?
    (if in-crisis?
        (<= fap-score -2.0)
        (< fap-score -8.0)))

  (define rush-threat?
    (and (< frame 2500)
         (>= (length rush-enemies) 3)
         rush-fap-threat?))

  ;; Hysteresis band [7, 13] (±3 around 10) for victory transition + catastrophic exit (< -15)
  (define catastrophic-deficit? (< fap-score -15.0))
  (define victory-fap-ok?
    (cond
      [catastrophic-deficit? #f]
      [in-victory?           (>= fap-score 7.0)]
      [in-midgame-recovery-or-contain?
       (or (null? rush-enemies) (>= fap-score 13.0))]
      [else
       (or (null? rush-enemies) (>= fap-score 13.0))]))

  (cond
    [(eq? cfg-race 'Random)
     (define victory-ready?
       (or (>= frame 3500)
           (memq 'ghost ally-unit-types)
           (memq 'colossus ally-unit-types)
           (memq 'corruptor ally-unit-types)
           in-victory?))
     (cond
       [rush-threat? 'EarlyScoutCrisis]
       [(and victory-ready? victory-fap-ok?)
        'MothmanApexVictory]
       [(and victory-ready? catastrophic-deficit?)
        'MidGameBioTankContain]
       [(and victory-ready? (eq? cur 'MidGameBioTankContain))
        'MidGameBioTankContain]
       [(or (>= frame 1800)
            (memq 'starport ally-bldgs)
            (memq 'spire ally-bldgs)
            (memq 'robotics-facility ally-bldgs))
        'TriRaceVanguardContain]
       [(>= frame 350) 'AdaptiveCounterRecovery]
       [else 'RandomRollOpening])]
    [(eq? act-race 'Zerg)
     (define victory-ready?
       (or (>= frame 3200)
           (memq 'hive ally-bldgs)
           (memq 'corruptor ally-unit-types)
           in-victory?))
     (cond
       [rush-threat? 'CrisisZealotRush]
       [(and victory-ready? victory-fap-ok?)
        'SwarmVictory]
       [(and victory-ready? catastrophic-deficit?)
        'MacroHydraLurker]
       [(and victory-ready? (eq? cur 'MacroHydraLurker))
        'MacroHydraLurker]
       [(or (memq 'lair ally-bldgs) (memq 'spire ally-bldgs) (>= frame 1800))
        'MutaLurkerContain]
       [(or (>= frame 300) (memq 'spawning-pool ally-bldgs))
        'SunkenLairRecovery]
       [else 'Macro12Hatch])]
    [(eq? act-race 'Protoss)
     (define victory-ready?
       (or (>= frame 2600)
           (memq 'stalker ally-unit-types)
           (memq 'colossus ally-unit-types)
           in-victory?))
     (cond
       [rush-threat? 'CrisisZerglingFlood]
       [(and victory-ready? victory-fap-ok?)
        'ProtossArmadaVictory]
       [(and victory-ready? catastrophic-deficit?)
        'StalkerImmortalColossus]
       [(and victory-ready? (eq? cur 'StalkerImmortalColossus))
        'StalkerImmortalColossus]
       [(or (memq 'cybernetics-core ally-bldgs) (memq 'robotics-facility ally-bldgs) (>= frame 1800))
        'DragoonReaverVanguard]
       [(or (>= frame 300) (memq 'gateway ally-bldgs) (memq 'warp-gate ally-bldgs) (memq 'forge ally-bldgs))
        'CannonWallRecovery]
       [else 'ForgeFastExpand])]
    [else ;; Terran
     (define victory-ready?
       (or (>= frame 3200)
           (memq 'ghost ally-unit-types)
           in-victory?))
     (cond
       [rush-threat? 'CrisisEarlyBust]
       [(and victory-ready? victory-fap-ok?)
        'MothmanApexVictory]
       [(and victory-ready? catastrophic-deficit?)
        'BioTankMedivac]
       [(and victory-ready? (eq? cur 'BioTankMedivac))
        'BioTankMedivac]
       [(or (memq 'starport ally-bldgs) (memq 'siege-tank ally-unit-types) (>= frame 1800))
        'VesselGhostPush]
       [(or (>= frame 300) (memq 'barracks ally-bldgs))
        'BunkerSiegeRecovery]
       [else 'OneRaxFE])]))

(define (step-layer1b-mastermind! rt raw-obs)
  (define obs (sanitize-obs-hash raw-obs))
  (define ally-units (hash-ref obs 'ally-units '()))
  (define enemy-units (hash-ref obs 'enemy-units '()))
  (define base-x (hash-ref obs 'base-x 700))
  (define base-y (hash-ref obs 'base-y 760))
  (define nat-x (hash-ref obs 'natural-x 1024))
  (define nat-y (hash-ref obs 'natural-y 1120))
  (define ally-combat (filter combat-unit-record? ally-units))
  (define enemy-combat (filter-rush-threat-enemies enemy-units base-x base-y nat-x nat-y))
  (define fap-score
    (let ([ov (hash-ref obs 'fap-score #f)])
      (if (finite-real? ov)
          (safe-finite-real ov 0.0)
          (fap-evaluate-engagement ally-combat enemy-combat))))
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
                         #:enemy-army (* 50 (length enemy-combat)))
  (when (live-bot-runtime-doctrine rt)
    (define new-p (step-doctrine-loadout! (live-bot-runtime-doctrine rt)
                                          #:fap-score fap-score
                                          #:under-rush? (< fap-score -20)))
    (set-mastermind-state-personality! mstate new-p))
  (define next-posture (compute-next-posture rt obs fap-score))
  (define old-posture (live-bot-runtime-posture rt))
  (define posture-actions
    (if (not (eq? next-posture old-posture))
        (let* ([new-hist (append (live-bot-runtime-posture-history rt) (list next-posture))]
               [capped-hist (if (> (length new-hist) 32)
                                (drop new-hist (- (length new-hist) 32))
                                new-hist)])
          (set-live-bot-runtime-posture! rt next-posture)
          (set-live-bot-runtime-posture-history! rt capped-hist)
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

(define (step-layer2-economy! rt raw-obs)
  (define obs (sanitize-obs-hash raw-obs))
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
    (define save-cancel-thresh (coord-dist-threshold 240 base-x base-y))
    (define enemy-near?
      (or (hash-ref b 'under-attack #f)
          (ormap (lambda (e) (<= (dist2d bx by (hash-ref e 'x 9999) (hash-ref e 'y 9999)) save-cancel-thresh))
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
  (define gas-steal-thresh (coord-dist-threshold 260 base-x base-y))
  (define enemy-gas-steals
    (filter (lambda (eb)
              (and (memq (unit-type-sym eb) '(assimilator extractor refinery))
                   (<= (dist2d base-x base-y (hash-ref eb 'x 9999) (hash-ref eb 'y 9999)) gas-steal-thresh)))
            enemy-bldgs))
  (for ([eg (in-list enemy-gas-steals)])
    (emit! (list 'clear-gas-steal
                 (hash-ref eg 'id 901)
                 (hash-ref eg 'x (+ base-x 48))
                 (hash-ref eg 'y (+ base-y 48)))))

  ;; ---------------------------------------------------------------------------
  ;; Adversarial Countermeasure #1: Early Cheese / Cannon / Proxy / Worker Rush
  ;; (Ground threats only — never pull ground workers against flying scouts!)
  ;; ---------------------------------------------------------------------------
  (define ground-enemy-units-for-cheese
    (filter (lambda (e)
              (and (not (memq (unit-type-sym e) NON-WORKER-PULL-ENEMY-UNIT-SYMS))
                   (not (eq? (hash-ref e 'changeling? #f) #t))
                   (not (eq? (hash-ref e 'hallucination? #f) #t))
                   (not (eq? (hash-ref e 'hallucination #f) #t))
                   (not (eq? (hash-ref e 'flying? #f) #t))))
            enemy-units))
  (define cheese-dist-thresh (coord-dist-threshold 320 base-x base-y))
  (define proxy-or-cheese-enemies
    (filter (lambda (e)
              (and (<= (dist2d base-x base-y (hash-ref e 'x 9999) (hash-ref e 'y 9999)) cheese-dist-thresh)
                   (or (< frame 3200) (< (length (filter combat-unit-record? ally-units)) 4))))
            (append ground-enemy-units-for-cheese enemy-bldgs)))
  (define under-early-cheese?
    (and (not (null? proxy-or-cheese-enemies))
         (or (hash-ref obs 'under-cheese-rush #f)
             (ormap (lambda (e)
                      (and (<= (dist2d base-x base-y (hash-ref e 'x 9999) (hash-ref e 'y 9999)) cheese-dist-thresh)
                           (memq (unit-type-sym e) '(photon-cannon pylon bunker spine-crawler barracks))))
                    enemy-bldgs)
             (>= (length proxy-or-cheese-enemies) 2))))
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
      (findf (lambda (e)
               (and (memq (unit-type-sym e) '(probe scv drone))
                    (<= (dist2d base-x base-y (hash-ref e 'x 9999) (hash-ref e 'y 9999)) cheese-dist-thresh)))
             ground-enemy-units-for-cheese))
    (when (and enemy-builder (not (null? healthy-workers)))
      (emit! (list 'worker-harass
                   (hash-ref (car healthy-workers) 'id 10)
                   (hash-ref enemy-builder 'x tx)
                   (hash-ref enemy-builder 'y ty)))))

  ;; ---------------------------------------------------------------------------
  ;; Adversarial Countermeasure #2: Blocked Natural Expansion Site
  ;; ---------------------------------------------------------------------------
  (define nat-block-thresh (coord-dist-threshold 96 base-x base-y))
  (define natural-blockers
    (filter (lambda (e)
              (<= (dist2d nat-x nat-y (hash-ref e 'x 9999) (hash-ref e 'y 9999)) nat-block-thresh))
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
  ;; Coupled Macro Governor, Adaptive Build/Tech Planner & Guns-vs-Butter PPF
  ;; ---------------------------------------------------------------------------
  (define townhalls
    (filter (lambda (b)
              (memq (unit-type-sym b)
                    '(hatchery lair hive nexus command-center orbital-command planetary-fortress)))
            ally-bldgs))
  (define active-bases (max 1 (length townhalls)))
  (define depleting-bases
    (hash-ref obs 'depleting-bases (if (hash-ref obs 'mined-out #f) 1 0)))
  (define prod-facilities
    (filter (lambda (b)
              (memq (unit-type-sym b)
                    '(hatchery lair hive gateway warp-gate warpgate robotics-facility stargate
                      barracks factory starport)))
            ally-bldgs))
  (define gas-bldgs
    (filter (lambda (b) (memq (unit-type-sym b) '(extractor assimilator refinery)))
            ally-bldgs))
  (define mmstate (live-bot-runtime-mirror-mind rt))
  (define mstate (live-bot-runtime-mastermind rt))
  (define tech-obs
    (or (mirror-mind-state-last-tech-observation mmstate)
        (infer-enemy-implied-tech-and-upgrades enemy-units enemy-bldgs)))
  (define has-th-harvesters?
    (or (hash-has-key? obs 'mineral-harvesters)
        (hash-has-key? obs 'ideal-mineral-harvesters)
        (ormap (lambda (b) (and (hash? b) (hash-has-key? b 'assigned-harvesters))) townhalls)))
  (define live-min-harvesters
    (and has-th-harvesters?
         (hash-ref obs 'mineral-harvesters
                   (for/sum ([b (in-list townhalls)])
                     (if (hash? b) (safe-nonneg-int (hash-ref b 'assigned-harvesters 0) 0) 0)))))
  (define live-ideal-min-harvesters
    (and has-th-harvesters?
         (hash-ref obs 'ideal-mineral-harvesters
                   (for/sum ([b (in-list townhalls)])
                     (if (hash? b) (safe-nonneg-int (hash-ref b 'ideal-harvesters 16) 16) 16)))))
  (define has-gas-harvesters?
    (or (hash-has-key? obs 'gas-harvesters)
        (hash-has-key? obs 'ideal-gas-harvesters)
        (ormap (lambda (b) (and (hash? b) (hash-has-key? b 'assigned-harvesters))) gas-bldgs)))
  (define live-gas-harvesters
    (and has-gas-harvesters?
         (hash-ref obs 'gas-harvesters
                   (for/sum ([b (in-list gas-bldgs)])
                     (if (hash? b) (safe-nonneg-int (hash-ref b 'assigned-harvesters 0) 0) 0)))))
  (define live-ideal-gas-harvesters
    (and has-gas-harvesters?
         (hash-ref obs 'ideal-gas-harvesters
                   (for/sum ([b (in-list gas-bldgs)])
                     (if (hash? b) (safe-nonneg-int (hash-ref b 'ideal-harvesters 3) 3) 3)))))
  (define macro-plan
    (evaluate-coupled-macro-governor
     #:race race
     #:frame frame
     #:minerals minerals
     #:gas gas
     #:supply-left supply-left
     #:active-bases active-bases
     #:depleting-bases depleting-bases
     #:workers (length workers)
     #:pending-workers pending-workers
     #:mineral-harvesters live-min-harvesters
     #:ideal-mineral-harvesters live-ideal-min-harvesters
     #:gas-harvesters live-gas-harvesters
     #:ideal-gas-harvesters live-ideal-gas-harvesters
     #:production-facilities (max 1 (length prod-facilities))
     #:busy-facilities (hash-ref obs 'busy-facilities 0)
     #:busy-townhalls (hash-ref obs 'busy-townhalls 0)
     #:under-crisis? under-early-cheese?
     #:recommended-min-bases (mirror-mind-state-recommended-min-bases mmstate)))
  (define target-workers (coupled-macro-plan-target-workers macro-plan))
  (define desired-bases (max 2 (min 6 (coupled-macro-plan-desired-bases macro-plan))))
  (define tech-plan
    (evaluate-adaptive-build-and-tech-plan
     race
     #:ally-buildings bldg-types
     #:ally-units unit-types
     #:researched-upgrades (hash-ref obs 'researched-upgrades '())
     #:enemy-archetype (mastermind-state-enemy-archetype mstate)
     #:mirror-predicted-unit (mirror-mind-state-predicted-enemy-unit mmstate)
     #:mirror-macro-verdict (mirror-mind-state-mirror-macro-verdict mmstate)
     #:requires-detection? (enemy-tech-observation-requires-detection? tech-obs)
     #:requires-anti-air? (enemy-tech-observation-requires-anti-air? tech-obs)
     #:enemy-upgrade-advantage (enemy-tech-observation-enemy-upgrade-advantage tech-obs)
     #:minerals minerals
     #:gas gas))
  (define ppf
    (evaluate-guns-vs-butter-ppf
     #:race race
     #:frame frame
     #:minerals minerals
     #:gas gas
     #:supply-left supply-left
     #:supply-cap supply-cap
     #:workers total-workers
     #:target-workers target-workers
     #:active-bases active-bases
     #:depleting-bases depleting-bases
     #:active-geysers (length gas-bldgs)
     #:current-gas-workers (hash-ref obs 'gas-workers (* 3 (length gas-bldgs)))
     #:production-facilities (max 1 (length prod-facilities))
     #:busy-facilities (hash-ref obs 'busy-facilities 0)
     #:army-count (length (filter combat-unit-record? ally-units))
     #:missing-synergy-count (length (adaptive-tech-plan-missing-synergy-reqs tech-plan))
     #:under-crisis? under-early-cheese?
     #:mirror-macro-verdict (mirror-mind-state-mirror-macro-verdict mmstate)
     #:enemy-upgrade-advantage (enemy-tech-observation-enemy-upgrade-advantage tech-obs)
     #:enemy-active-research-count (length (enemy-tech-observation-active-research-buildings tech-obs))
     #:requires-detection? (enemy-tech-observation-requires-detection? tech-obs)
     #:requires-anti-air? (enemy-tech-observation-requires-anti-air? tech-obs)))
  (define gas-alloc (guns-vs-butter-ppf-recommended-gas-allocation ppf))

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

  ;; Standard Gas & Mineral Harvesting (governed by Guns-vs-Butter Gas Allocation)
  (define gas-bldg
    (findf (lambda (b) (memq (unit-type-sym b) '(extractor assimilator refinery)))
           ally-bldgs))
  (when (and gas-bldg
             (not (null? workers))
             (> (gas-worker-allocation-desired-gas-workers gas-alloc) 0))
    (emit! (list 'harvest-gas (hash-ref (car workers) 'id 10) (hash-ref gas-bldg 'id 103))))
  (when (not (null? workers))
    (define patch-id (hash-ref obs 'mineral-patch-id 504))
    (emit! (list 'harvest-mineral (hash-ref (car workers) 'id 10) patch-id)))

  ;; Early Worker Scout / Harass (Pro Mechanic #5)
  (when (and (hash-ref obs 'enable-worker-harass #f) (not (null? workers)))
    (emit! (list 'worker-harass (hash-ref (last workers) 'id 10) enemy-x enemy-y)))

  ;; Mined-out / Depleting base detection (Scenario 3): auto-expand & transfer workers
  (when (and (or (hash-ref obs 'mined-out #f) (> depleting-bases 0))
             (not natural-blocked?)
             (not under-early-cheese?))
    (emit! (list 'expand (if (>= active-bases 2) third-x nat-x)
                         (if (>= active-bases 2) third-y nat-y))))

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
  ;; (100% Valid SC2 LotV Symbols + Multi-Base Expansion Escrow)
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
       (define target-x (safe-coord (+ tx (* 144.0 (/ dx d))) tx))
       (define target-y (safe-coord (+ ty (* 144.0 (/ dy d))) ty))
       (set-add! (live-bot-runtime-used-creep-tumors rt) tid)
       (emit! (list 'cast tid 'spread-creep-tumor target-x target-y)))

     ;; 3. Multi-Base Expansion Priority (2nd, 3rd, 4th+ bases when should-expand? or < desired-bases)
     (when (and (>= minerals 300)
                (not under-early-cheese?)
                (not natural-blocked?)
                (or (< (length hatcheries) 2)
                    (and (< (length hatcheries) desired-bases)
                         (or (coupled-macro-plan-should-expand? macro-plan)
                             (>= frame 2200)))))
       (define exp-x (if (>= (length hatcheries) 2) third-x nat-x))
       (define exp-y (if (>= (length hatcheries) 2) third-y nat-y))
       (emit! (list 'expand exp-x exp-y))
       (set! minerals (- minerals 300)))

     ;; 4. Zerg Tech Buildings & Morphs
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
         (emit! '(research metabolic-boost))))

     (when (and (memq 'spawning-pool bldg-types)
                (>= minerals 250)
                (not (memq 'lair bldg-types)))
       (emit! (list 'build 'spine-crawler nat-x nat-y))
       (emit! '(morph lair)))

     (when (memq 'lair bldg-types)
       (when (not (memq 'spire bldg-types))
         (emit! (list 'build 'spire (+ base-x 80) (+ base-y 60))))
       (when (not (memq 'hydralisk-den bldg-types))
         (emit! (list 'build 'hydralisk-den (+ base-x 60) (+ base-y 80))))
       (when (not (memq 'baneling-nest bldg-types))
         (emit! (list 'build 'baneling-nest (+ base-x 40) (- base-y 40))))
       (when (and (memq 'hydralisk-den bldg-types) (>= gas 150))
         (emit! '(research adaptive-talons))))

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

     (when (and (< total-workers target-workers) (>= minerals 50) (can-spend-supply? 1))
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
                    (and (or (memq 'gateway bldg-types) (memq 'warp-gate bldg-types))
                         (< frame 3000)
                         (not (null? enemy-units)))))
       (define dg (car door-guards))
       (define dg-id (hash-ref dg 'id 703))
       (emit! (list 'hold-position dg-id nat-x nat-y))
       (emit! (list 'control-group-steal 2 (list dg-id)))
       (cortex-steal-control-group! (live-bot-runtime-cortex rt) 2 (list dg-id)))

     ;; 3. Multi-Base Expansion Priority (2nd, 3rd, 4th+ bases)
     (when (and (>= minerals 400)
                (not under-early-cheese?)
                (not natural-blocked?)
                (or (< (length nexuses) 2)
                    (and (< (length nexuses) desired-bases)
                         (or (coupled-macro-plan-should-expand? macro-plan)
                             (>= frame 2200)))))
       (define exp-x (if (>= (length nexuses) 2) third-x nat-x))
       (define exp-y (if (>= (length nexuses) 2) third-y nat-y))
       (emit! (list 'expand exp-x exp-y))
       (set! minerals (- minerals 400)))

     ;; 4. Protoss Tech & Wall-Off Buildings (SC2 LotV canonical symbols)
     (when (and (not (memq 'gateway bldg-types))
                (not (memq 'warp-gate bldg-types))
                (>= minerals 150))
       (emit! (list 'build 'gateway (+ base-x 64) (+ base-y 64)))
       (set! minerals (- minerals 150)))

     (when (and (or (memq 'gateway bldg-types) (memq 'warp-gate bldg-types))
                (not (memq 'cybernetics-core bldg-types))
                (>= minerals 150))
       (emit! (list 'build 'cybernetics-core (+ base-x 96) (+ base-y 64)))
       (emit! (list 'build 'assimilator (+ base-x 64) (+ base-y 64))))

     (when (and (memq 'cybernetics-core bldg-types)
                (not (memq 'robotics-facility bldg-types))
                (>= minerals 200))
       (emit! (list 'build 'robotics-facility (+ base-x 96) (+ base-y 96)))
       (emit! '(morph warp-gate)))

     (when (and (memq 'robotics-facility bldg-types)
                (not (memq 'robotics-bay bldg-types))
                (not (memq 'robotics-support-bay bldg-types))
                (>= minerals 200))
       (emit! (list 'build 'robotics-bay (+ base-x 100) (+ base-y 100)))
       (emit! '(research protoss-ground-weapons-1))
       (emit! (list 'build 'photon-cannon nat-x nat-y)))

     ;; Protoss Unit Training (combat priority first, then support/detection)
     (when (can-spend-supply? 2)
       (cond
         [(memq 'robotics-facility bldg-types)
          (emit! '(train colossus))
          (emit! '(train immortal))
          (emit! '(train stalker))
          (emit! '(train disruptor))
          (emit! '(train sentry))
          (emit! '(train observer))
          (emit! '(train warp-prism))]
         [(memq 'cybernetics-core bldg-types)
          (emit! '(train stalker))
          (emit! '(train adept))
          (emit! '(train sentry))
          (emit! '(train zealot))]
         [(or (memq 'gateway bldg-types) (memq 'warp-gate bldg-types))
          (emit! '(train zealot))]))

     (when (and (< total-workers target-workers) (>= minerals 50) (can-spend-supply? 1))
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

     ;; 3. Multi-Base Expansion Priority (2nd, 3rd, 4th+ bases)
     (when (and (>= minerals 400)
                (not under-early-cheese?)
                (not natural-blocked?)
                (or (< (length ccs) 2)
                    (and (< (length ccs) desired-bases)
                         (or (coupled-macro-plan-should-expand? macro-plan)
                             (>= frame 2200)))))
       (define exp-x (if (>= (length ccs) 2) third-x nat-x))
       (define exp-y (if (>= (length ccs) 2) third-y nat-y))
       (emit! (list 'expand exp-x exp-y))
       (set! minerals (- minerals 400)))

     ;; 4. Terran Tech Buildings & Upgrades (SC2 LotV canonical symbols)
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
       (emit! (list 'build 'armory (+ base-x 100) (+ base-y 60)))
       (emit! '(research drilling-claws))
       (when (not (memq 'starport bldg-types))
         (emit! (list 'build 'starport (+ base-x 96) (+ base-y 112)))))

     (when (and (memq 'starport bldg-types) (>= minerals 150))
       (emit! (list 'build 'starport-techlab (+ base-x 120) (+ base-y 100)))
       (emit! (list 'build 'ghost-academy (+ base-x 150) (+ base-y 100)))
       (emit! (list 'build 'engineering-bay (+ base-x 80) (- base-y 48)))
       (emit! (list 'build 'missile-turret (+ base-x 32) (+ base-y 32)))
       (emit! '(research personal-cloaking)))

     ;; Terran Unit Training (including Widow Mine & Siege Tank & Bio)
     (when (can-spend-supply? 2)
       (cond
         [(memq 'starport bldg-types)
          (emit! '(train siege-tank))
          (emit! '(train raven))
          (emit! '(train viking))
          (emit! '(train ghost))
          (emit! '(train widow-mine))
          (emit! '(train marauder))
          (emit! '(train medivac))
          (emit! '(train marine))]
         [(memq 'factory bldg-types)
          (emit! '(train siege-tank))
          (emit! '(train widow-mine))
          (emit! '(train hellion))
          (emit! '(train cyclone))
          (emit! '(train marauder))
          (emit! '(train marine))]
         [(memq 'barracks bldg-types)
          (emit! '(train marine))]))

     (when (and (< total-workers target-workers) (>= minerals 50) (can-spend-supply? 1))
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

  ;; ---------------------------------------------------------------------------
  ;; Pro Mechanic #8: Burrowed Zergling Base-Blocker, Cheap Patrol Expansion
  ;;                  Blocker, & Peripheral Economic Harassment Raider Squad
  ;; ---------------------------------------------------------------------------
  (define cheap-blockers
    (filter (lambda (u) (memq (unit-type-sym u) '(zergling marine zealot reaper adept)))
            combat-units))
  (define mm-verdict
    (mirror-mind-state-mirror-macro-verdict (live-bot-runtime-mirror-mind rt)))
  (when (and (not (null? cheap-blockers))
             (or (hash-ref obs 'enable-economic-disruption #f)
                 (eq? mm-verdict 'punish-And-Deny-Greedy-Expand)
                 (and (null? enemy-units) (>= (length cheap-blockers) 3))))
    (define blocker (car cheap-blockers))
    (define bid (hash-ref blocker 'id 110))
    (define enemy-exp-x (hash-ref obs 'enemy-expand-x (- enemy-x 180)))
    (define enemy-exp-y (hash-ref obs 'enemy-expand-y (- enemy-y 140)))
    (if (eq? (unit-type-sym blocker) 'zergling)
        (emit! (list 'burrow-block bid enemy-exp-x enemy-exp-y))
        (emit! (list 'patrol-block-expansion bid enemy-exp-x enemy-exp-y)))
    (when (>= (length cheap-blockers) 2)
      (define raider-ids
        (map (lambda (u) (hash-ref u 'id 111))
             (take (cdr cheap-blockers) (min 3 (length (cdr cheap-blockers))))))
      (emit! (list 'harass-workers raider-ids enemy-x enemy-y))))

  (when (and (null? enemy-units) (>= (length combat-units) 2))
    (for ([u (in-list (take combat-units 2))])
      (emit! (list 'attack-pos (hash-ref u 'id 110) nat-x nat-y))))

  ;; ---------------------------------------------------------------------------
  ;; Pro Mechanic #9: Enemy Changeling Sniping & Active Deception/Scout Spells
  ;;                  (Sentry Hallucination Phoenix/Archon + Overseer Changeling)
  ;; ---------------------------------------------------------------------------
  (define enemy-changelings
    (filter (lambda (e)
              (or (eq? (hash-ref e 'changeling? #f) #t)
                  (memq (unit-type-sym e)
                        '(changeling changeling-zealot changeling-marine
                          changeling-marine-shield changeling-zergling
                          changeling-zergling-wings))))
            enemy-units))
  (for ([ec (in-list enemy-changelings)])
    (emit! (list 'snipe-enemy-changeling (hash-ref ec 'id 9099))))

  (define ally-sentries
    (filter (lambda (u) (eq? (unit-type-sym u) 'sentry)) ally-units))
  (define ally-overseers
    (filter (lambda (u) (eq? (unit-type-sym u) 'overseer)) ally-units))
  (define ally-infestors
    (filter (lambda (u) (eq? (unit-type-sym u) 'infestor)) ally-units))

  (when (or (hash-ref obs 'enable-deception-and-buffs #f)
            (not (null? ally-sentries))
            (not (null? ally-overseers)))
    (emit! '(cast-deception-and-scout-spells
             sentry-hallucination-phoenix-scout
             sentry-hallucination-archon-tank
             overseer-spawn-changeling)))

  ;; ---------------------------------------------------------------------------
  ;; Pro Mechanic #10: Protective Buff Aura (Guardian Shield / Microbial Shroud)
  ;;                   + Inside-Aura Positioning with Anti-Splash Spreading,
  ;;                   Pre-Split 3-Wing Squads, Concave Arc, & High-Ground Mastery
  ;; ---------------------------------------------------------------------------
  (define army-cx
    (if (null? combat-units)
        nat-x
        (quotient (for/sum ([u (in-list combat-units)]) (hash-ref u 'x nat-x))
                  (length combat-units))))
  (define army-cy
    (if (null? combat-units)
        nat-y
        (quotient (for/sum ([u (in-list combat-units)]) (hash-ref u 'y nat-y))
                  (length combat-units))))
  (define target-ex
    (if (null? enemy-units)
        enemy-x
        (quotient (for/sum ([e (in-list enemy-units)]) (hash-ref e 'x enemy-x))
                  (length enemy-units))))
  (define target-ey
    (if (null? enemy-units)
        enemy-y
        (quotient (for/sum ([e (in-list enemy-units)]) (hash-ref e 'y enemy-y))
                  (length enemy-units))))

  (when (or (hash-ref obs 'enable-deception-and-buffs #f)
            (not (null? ally-sentries))
            (not (null? ally-infestors))
            (and (not (null? enemy-units)) (not (null? combat-units))))
    (define use-shroud?
      (or (not (null? ally-infestors))
          (eq? (live-bot-runtime-actual-race rt) 'Zerg)))
    (define aura-type (if use-shroud? 'microbial-shroud 'guardian-shield))
    (define aura-radius (if use-shroud? 3.5 4.5))
    (emit! (list 'cast-protective-buff-aura aura-type army-cx army-cy aura-radius))
    (emit! (list 'position-in-buff-aura-with-splash-spread
                 aura-type army-cx army-cy aura-radius 1.6 #t)))

  ;; Pre-Split 3-Wing Formation & Concave Arc Formation
  (when (or (not (null? enemy-units))
            (hash-ref obs 'pre-split-engage #f)
            (hash-ref obs 'form-concave #f))
    (define dx (- target-ex army-cx))
    (define dy (- target-ey army-cy))
    (define d (max 1.0 (sqrt (+ (* dx dx) (* dy dy)))))
    (define nx (/ (- dy) d))
    (define ny (/ dx d))
    (define wing-spread 96.0)
    (define mid-x (exact-round (+ army-cx (* 0.5 dx))))
    (define mid-y (exact-round (+ army-cy (* 0.5 dy))))
    (define left-x (exact-round (+ mid-x (* wing-spread nx))))
    (define left-y (exact-round (+ mid-y (* wing-spread ny))))
    (define right-x (exact-round (- mid-x (* wing-spread nx))))
    (define right-y (exact-round (- mid-y (* wing-spread ny))))
    (emit! (list 'pre-split-wings left-x left-y mid-x mid-y right-x right-y))
    (emit! (list 'form-concave-arc target-ex target-ey 160 120)))

  ;; High-Ground Terrain & Vision Mastery
  (define our-z
    (hash-ref obs 'our-terrain-z
              (if (not (null? combat-units))
                  (hash-ref (car combat-units) 'z 10)
                  10)))
  (define enemy-z
    (hash-ref obs 'enemy-terrain-z
              (if (not (null? enemy-units))
                  (hash-ref (car enemy-units) 'z 10)
                  10)))
  (when (or (not (= our-z enemy-z))
            (not (null? enemy-units))
            (hash-ref obs 'high-ground-check #f))
    (cond
      [(> our-z enemy-z)
       (emit! (list 'high-ground-tactics 'hold-high-ground-ramp-arc nat-x nat-y #f))]
      [(> enemy-z our-z)
       (emit! (list 'high-ground-tactics 'uphill-vision-spotter-and-concave target-ex target-ey #t))]
      [else
       (emit! (list 'high-ground-tactics 'contest-high-ground-control nat-x nat-y #f))]))

  ;; Spatio-Temporal Enemy Army Reachability & Counter-Positioning / Backstab / Surround Maneuver
  (define mm-rt (live-bot-runtime-mirror-mind rt))
  (define reach-m
    (evaluate-enemy-army-spatio-temporal-reachability
     (hash-ref obs 'frame 0)
     ally-units
     enemy-units
     (mirror-mind-state-last-tech-observation mm-rt)
     (mirror-mind-state-last-shadow-ledger mm-rt)
     #:our-base-x base-x #:our-base-y base-y
     #:our-nat-x nat-x #:our-nat-y nat-y
     #:enemy-exp-x (hash-ref obs 'enemy-expand-x 1450)
     #:enemy-exp-y (hash-ref obs 'enemy-expand-y 1350)))
  (set-mirror-mind-state-last-reachability-model! mm-rt reach-m)
  (define sp-maneuver
    (enemy-army-reachability-model-recommended-spatial-maneuver reach-m))
  (define-values (sp-tx sp-ty)
    (case sp-maneuver
      [(backstab-undefended-enemy-expansion)
       (values (hash-ref obs 'enemy-expand-x 1450)
               (hash-ref obs 'enemy-expand-y 1350))]
      [(surround-and-crush-isolated-enemy-cluster)
       (values target-ex target-ey)]
      [(pre-rotate-intercept-incoming-threat)
       (values nat-x nat-y)]
      [(safe-to-expand-enemy-pinned-far)
       (values (hash-ref obs 'third-x 1280)
               (hash-ref obs 'third-y 1280))]
      [else
       (values target-ex target-ey)]))
  (emit! (list 'execute-spatial-maneuver sp-maneuver sp-tx sp-ty))

  (values (reverse actions) vanguard-count reserve-count))

;; =============================================================================
;; Layer 5: Human Cortex Camera Saccades, Ability Throttling & Token Filtering
;; =============================================================================

(define (step-layer5-human-cortex! rt raw-actions raw-obs)
  (define obs (sanitize-obs-hash raw-obs))
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
       (define tx (safe-coord (hash-ref (car enemy-units) 'x 600) 600))
       (define ty (safe-coord (hash-ref (car enemy-units) 'y 700) 700))
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
;; Layer 5b: Pro-Human Camera Saccade (60-90 SPM) & APM/EPM Discipline Governor
;; =============================================================================

(define PRO-CAMERA-SACCADE-ZONES
  '(home-macro-base
    natural-expansion
    active-army-front
    harass-or-blocker-zone))

(define (step-pro-human-camera-and-apm-governor! rt [raw-obs (hash)])
  (define obs (sanitize-obs-hash raw-obs))
  (define frame (hash-ref obs 'frame 0))
  (define cortex (live-bot-runtime-cortex rt))
  (define bmarks (human-cortex-camera-bookmarks cortex))
  (define base-x (hash-ref obs 'base-x 700))
  (define base-y (hash-ref obs 'base-y 760))
  (define nat-x (hash-ref obs 'natural-x 1024))
  (define nat-y (hash-ref obs 'natural-y 1120))
  (define enemy-x (hash-ref obs 'enemy-x 1600))
  (define enemy-y (hash-ref obs 'enemy-y 1600))
  (define enemy-units (hash-ref obs 'enemy-units '()))

  (define last-frame (hash-ref bmarks 'last-saccade-frame #f))
  (define cur-idx (safe-nonneg-int (hash-ref bmarks 'saccade-zone-idx 0) 0))
  ;; Pro humans dwell ~16-22 frames (~0.75s = 60-90 SPM) per camera zone before saccading
  (define next-idx
    (cond
      [(not (exact-integer? last-frame)) 0]
      [(or (= frame last-frame) (>= (abs (- frame last-frame)) 16))
       (modulo (add1 cur-idx) (length PRO-CAMERA-SACCADE-ZONES))]
      [else (modulo cur-idx (length PRO-CAMERA-SACCADE-ZONES))]))
  (hash-set! bmarks 'last-saccade-frame frame)
  (hash-set! bmarks 'saccade-zone-idx next-idx)

  (define zone (list-ref PRO-CAMERA-SACCADE-ZONES next-idx))
  (define-values (zx zy)
    (case zone
      [(home-macro-base)
       (values base-x base-y)]
      [(natural-expansion)
       (values nat-x nat-y)]
      [(active-army-front)
       (if (not (null? enemy-units))
           (values (safe-coord (hash-ref (car enemy-units) 'x nat-x) nat-x)
                   (safe-coord (hash-ref (car enemy-units) 'y nat-y) nat-y))
           (values (quotient (+ nat-x enemy-x) 2)
                   (quotient (+ nat-y enemy-y) 2)))]
      [(harass-or-blocker-zone)
       (values (safe-coord (hash-ref obs 'enemy-expand-x (- enemy-x 180)) (- enemy-x 180))
               (safe-coord (hash-ref obs 'enemy-expand-y (- enemy-y 140)) (- enemy-y 140)))]
      [else
       (values base-x base-y)]))

  (define prof (get-pro-cortex-profile (human-cortex-profile-name cortex)))
  (define target-apm (safe-nonneg-int (hash-ref prof 'mean-epm 350) 350))
  (list (list 'camera-focus zone zx zy)
        (list 'human-apm-discipline target-apm 3 #t #t)))

;; =============================================================================
;; Top-Level 5-Layer Step (`step-live-bot-runtime!`)
;; =============================================================================

(define (step-live-bot-runtime! rt [obs-or-sexp (hash)])
  (define raw-obs
    (cond
      [(hash? obs-or-sexp) obs-or-sexp]
      [(pair? obs-or-sexp) (parse-frame-state-sexp obs-or-sexp)]
      [(string? obs-or-sexp)
       (with-handlers ([exn:fail? (lambda (_e) (hash))])
         (parse-frame-state-sexp (read (open-input-string obs-or-sexp))))]
      [else (hash)]))
  (define obs (sanitize-obs-hash raw-obs))

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
  ;; Layer 5b: Pro-Human Camera Saccade (60-90 SPM) & APM/EPM Discipline Governor
  (define pro-apm-acts
    (step-pro-human-camera-and-apm-governor! rt obs))
  (define preserved-tactical-directives
    (filter (lambda (a)
              (and (pair? a)
                   (memq (car a)
                         '(snipe-enemy-changeling
                           cast-deception-and-scout-spells
                           cast-protective-buff-aura
                           position-in-buff-aura-with-splash-spread
                           pre-split-wings
                           form-concave-arc
                           high-ground-tactics
                           execute-spatial-maneuver))
                   (not (member a accepted))))
            tactic-acts))

  (define cortex (live-bot-runtime-cortex rt))
  (define mstate (live-bot-runtime-mastermind rt))
  (define mmstate (live-bot-runtime-mirror-mind rt))
  (define mmledger (mirror-mind-state-last-shadow-ledger mmstate))
  (define mmalloc (mirror-mind-state-toolbox-allocation mmstate))
  (define mmtech (mirror-mind-state-last-tech-observation mmstate))
  (define mmzs (mirror-mind-state-last-zero-sum-reading mmstate))
  (define scouted-sec-cnt
    (max 1 (length (hash-ref obs 'visible-sectors '(0 1 2 3)))))
  (define hist (live-bot-runtime-posture-history rt))
  (define recent-switches
    (max 1 (min 7 (sub1 (max 1 (length hist))))))
  (define pda
    (make-pda-trace #:scouted-sectors scouted-sec-cnt
                    #:posture-switches recent-switches
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
          'mirror-predicted-enemy-bases (mirror-mind-state-predicted-enemy-bases mmstate)
          'mirror-predicted-enemy-workers (mirror-mind-state-predicted-enemy-workers mmstate)
          'mirror-macro-verdict (mirror-mind-state-mirror-macro-verdict mmstate)
          'mirror-recommended-min-bases (mirror-mind-state-recommended-min-bases mmstate)
          'mirror-disruption-priority (mirror-mind-state-disruption-priority mmstate)
          'mirror-observed-upgrades (enemy-tech-observation-observed-upgrades mmtech)
          'mirror-implied-tech-buildings (enemy-tech-observation-implied-tech-buildings mmtech)
          'mirror-enemy-upgrade-advantage (enemy-tech-observation-enemy-upgrade-advantage mmtech)
          'mirror-requires-detection? (enemy-tech-observation-requires-detection? mmtech)
          'mirror-requires-anti-air? (enemy-tech-observation-requires-anti-air? mmtech)
          'mirror-observed-spells (enemy-tech-observation-observed-spells mmtech)
          'mirror-crippled-tech-buildings (enemy-tech-observation-crippled-tech-buildings mmtech)
          'mirror-committed-branch (zero-sum-exclusion-reading-committed-primary-branch mmzs)
          'mirror-excluded-branches (zero-sum-exclusion-reading-excluded-tech-branches mmzs)
          'mirror-bluff-suspected? (zero-sum-exclusion-reading-bluff-or-feint-suspected? mmzs)
          'vanguard-count vanguard-cnt
          'reserve-count reserve-cnt
          'personality (bot-personality-name (mastermind-state-personality mstate))
          'pda-bucket (diagnose-bot-anomaly pda)))

  (set-live-bot-runtime-last-telemetry! rt telemetry)
  (hash 'actions (append accepted preserved-tactical-directives pro-apm-acts)
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
     (sanitize-unit-record
      (hash 'id id 'type type 'x x 'y y 'hp hp 'energy energy)
      600 700)]
    [(list id type x y hp)
     (sanitize-unit-record
      (hash 'id id 'type type 'x x 'y y 'hp hp)
      600 700)]
    [(? hash? h) (sanitize-unit-record h 600 700)]
    [_ (hash 'id 101 'type 'zergling 'x 600 'y 700 'hp 35)]))

(define (parse-bldg-tuple tup)
  (match tup
    [(list id type x y hp-pct build-prog halted-flag)
     (define spct (max 0.0 (min 1.0 (safe-finite-real hp-pct 1.0))))
     (sanitize-bldg-record
      (hash 'id id
            'type type
            'x x
            'y y
            'hp (max 1 (safe-exact-int (* 500.0 spct) 500))
            'hp-pct spct
            'build-progress (max 0.0 (min 1.0 (safe-finite-real build-prog 1.0)))
            'halted (eq? halted-flag #t))
      700 760)]
    [(list id type x y hp)
     (sanitize-bldg-record
      (hash 'id id 'type type 'x x 'y y 'hp hp)
      700 760)]
    [(? hash? h) (sanitize-bldg-record h 700 760)]
    [_ (hash 'id 201 'type 'hatchery 'x 700 'y 760 'hp 1500)]))

(define (parse-effect-tuple tup)
  (match tup
    [(list type x y)
     (sanitize-effect-record (hash 'type type 'x x 'y y))]
    [(? hash? h) (sanitize-effect-record h)]
    [_ (hash 'type 'none 'x 0 'y 0)]))

(define (parse-frame-state-sexp sexp)
  (match sexp
    [(cons 'frame-state kvs)
     (define h (make-hash))
     (let loop ([rem (if (list? kvs) kvs '())])
       (match rem
         [(list* k v rest)
          (define key-str (if (keyword? k) (keyword->string k) (format "~a" k)))
          (case (string->symbol key-str)
            [(frame)          (hash-set! h 'frame (safe-nonneg-int v 0))]
            [(race)           (hash-set! h 'race v)]
            [(minerals)       (hash-set! h 'minerals (safe-nonneg-int v 0))]
            [(gas)            (hash-set! h 'gas (safe-nonneg-int v 0))]
            [(supply-used)    (hash-set! h 'supply-used (safe-nonneg-int v 12))]
            [(supply-cap)     (hash-set! h 'supply-cap (min 200 (safe-nonneg-int v 15)))]
            [(supply-left)    (hash-set! h 'supply-left (safe-nonneg-int v 0))]
            [(pending-supply) (hash-set! h 'pending-supply (safe-nonneg-int v 0))]
            [(start-pos)
             (when (and (list? v) (>= (length v) 2))
               (hash-set! h 'base-x (safe-coord (first v) 700))
               (hash-set! h 'base-y (safe-coord (second v) 760)))]
            [(enemy-base)
             (when (and (list? v) (>= (length v) 2))
               (hash-set! h 'enemy-x (safe-coord (first v) 1600))
               (hash-set! h 'enemy-y (safe-coord (second v) 1600)))]
            [(my-units)       (hash-set! h 'ally-units (if (list? v) (map parse-unit-tuple v) '()))]
            [(my-buildings)   (hash-set! h 'ally-buildings (if (list? v) (map parse-bldg-tuple v) '()))]
            [(enemy-units)    (hash-set! h 'enemy-units (if (list? v) (map parse-unit-tuple v) '()))]
            [(enemy-buildings)(hash-set! h 'enemy-buildings (if (list? v) (map parse-bldg-tuple v) '()))]
            [(effects)        (hash-set! h 'effects (if (list? v) (map parse-effect-tuple v) '()))])
          (loop rest)]
         [_ (void)]))
     (sanitize-obs-hash h)]
    [_ (sanitize-obs-hash (hash))]))

(define (runtime-step-sexp! rt sexp)
  (define res (step-live-bot-runtime! rt sexp))
  (append (hash-ref res 'mirror-actions '())
          (hash-ref res 'actions '())))
