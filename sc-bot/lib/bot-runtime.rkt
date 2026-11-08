#lang racket/base

(require racket/match
         racket/list
         racket/set
         racket/math
         "../compiler/syntax.rkt"
         "sc2-game-constants.rkt"
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
 (struct-out random-stealth-harass-plan)
 make-live-bot-runtime
 evaluate-random-stealth-harass-plan
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
    creep-tumor creep-tumor-burrowed warp-prism medivac overlord-transport))

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
   cooldown-tracker
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
   (make-symbiotic-ledger SC2-STARTING-MINERALS SC2-STARTING-GAS SC2-STARTING-WORKERS)
   (make-ability-cast-limiter #:max-per-frame 2 #:refractory-frames 16)
   (make-human-cortex #:profile prof-sym
                      #:cam-x SC2-DEFAULT-HOME-BASE-X
                      #:cam-y SC2-DEFAULT-HOME-BASE-Y
                      #:epm-cap epm-cap
                      #:max-tokens 32)
   (mutable-set)
   (make-refractory-cooldown-tracker)
   #f
   0
   (hash)))

(struct random-stealth-harass-plan
  (active?
   rolled-race
   doctrine-name
   stealth-phase
   deny-scout-choke?
   perimeter-flight-path?
   fake-normal-front?
   priority-tech-building
   priority-harass-units
   early-push-threshold)
  #:transparent)

(define (evaluate-random-stealth-harass-plan configured-race actual-race frame-num)
  (define is-random? (member configured-race '(Random random "Random" "random")))
  (define r-sym (normalize-race-sym actual-race))
  (define fn (if (and (number? frame-num) (real? frame-num) (not (nan? frame-num)) (not (infinite? frame-num)))
                 (max 0 (exact-round frame-num))
                 0))
  (cond
    [(not is-random?)
     (random-stealth-harass-plan #f r-sym 'standard-known-race 'none #f #f #f #f '() 28)]
    [(eq? r-sym 'Zerg)
     ;; Doctrine 1: Lambo / Serral 5-Roach + 1-Ravager Pressure (19-Drone Fake-Macro Natural)
     ;; Holds Overlord-1 off the direct center flight lane until 1:35 (loop 2128), shows standard
     ;; Hatchery-first at natural while hiding Roach Warren in back main mineral pocket.
     (random-stealth-harass-plan
      #t
      'Zerg
      'lambo-stealth-5-roach-ravager-pressure
      (if (< fn 2128) 'conceal-overlord-and-back-warren 'roach-ravager-wall-breaker)
      #t
      #t
      #t
      'roach-warren
      '(roach ravager zergling)
      14)]
    [(eq? r-sym 'Terran)
     ;; Doctrine 2: Maru / Clem Marine-First Ramp Denial -> 1-1-1 Widow Mine Drop / Cloaked Banshee
     ;; Skips Reaper (which reveals race at 1:25) in favor of 1st Marine on high-ground ramp to snipe
     ;; incoming Probe/SCV/Overlord scout before it sees the back-corner Factory + Starport.
     (random-stealth-harass-plan
      #t
      'Terran
      'maru-marine-first-scout-denial-111-harass
      (if (< fn 2464) 'ramp-marine-scout-denial 'widow-mine-banshee-harass)
      #t
      #t
      #t
      'factory
      '(marine marauder widow-mine medivac banshee)
      16)]
    [(eq? r-sym 'Protoss)
     ;; Doctrine 3: MaxPax / herO Fake-Normal Ramp Core -> Perimeter Stargate Oracle + Double-Adept Shade
     ;; Shows normal 14-Pylon + 16-Gateway + 20-Nexus + 20-CyberCore at main ramp, hides 2nd Pylon + Stargate
     ;; in back-corner of main, routes Oracle along map-edge dead-air + shades 2 Adepts into natural.
     (random-stealth-harass-plan
      #t
      'Protoss
      'maxpax-fake-normal-core-perimeter-oracle-adept
      (if (< fn 2464) 'fake-normal-ramp-hide-stargate 'perimeter-oracle-double-adept-pincer)
      #t
      #t
      #t
      'stargate
      '(adept stalker oracle)
      14)]
    [else
     (random-stealth-harass-plan #f r-sym 'standard-known-race 'none #f #f #f #f '() 28)]))


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

(define MAP-MAX-COORD 256.0)

(define (safe-coord v [default 32.5])
  (define raw (if (finite-real? v) v default))
  (define clamped (max 0.0 (min MAP-MAX-COORD (exact->inexact raw))))
  (define half-rounded (/ (round (* clamped 2.0)) 2.0))
  (if (and (exact-integer? raw) (= clamped (exact->inexact (exact-round half-rounded))))
      (exact-round half-rounded)
      half-rounded))

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

(define (sanitize-unit-record u [default-x 32.5] [default-y 32.5])
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

(define (sanitize-bldg-record b [default-x 32.5] [default-y 32.5])
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
           'x (safe-coord (hash-ref eff 'x 0.0) 0.0)
           'y (safe-coord (hash-ref eff 'y 0.0) 0.0))]
    [(and (list? eff) (= (length eff) 3))
     (hash 'type (if (symbol? (first eff)) (first eff) 'none)
           'x (safe-coord (second eff) 0.0)
           'y (safe-coord (third eff) 0.0))]
    [else
     (hash 'type 'none 'x 0.0 'y 0.0)]))

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
     (define base-x (safe-coord (hash-ref base-h 'base-x 32.5) 32.5))
     (define base-y (safe-coord (hash-ref base-h 'base-y 32.5) 32.5))
     (define enemy-x (safe-coord (hash-ref base-h 'enemy-x 160.5) 160.5))
     (define enemy-y (safe-coord (hash-ref base-h 'enemy-y 160.5) 160.5))
     (define-values (dir-ux dir-uy)
       (let* ([dx (exact->inexact (- enemy-x base-x))]
              [dy (exact->inexact (- enemy-y base-y))]
              [d  (max 1.0 (sqrt (+ (* dx dx) (* dy dy))))])
         (values (/ dx d) (/ dy d))))
     ;; Natural expansion: 18 tiles from (base-x, base-y) toward (enemy-x, enemy-y)
     (define default-nat-x (safe-coord (+ base-x (* 18.0 dir-ux)) 45.0))
     (define default-nat-y (safe-coord (+ base-y (* 18.0 dir-uy)) 45.0))
     ;; Third expansion: 28 tiles from (base-x, base-y) at an angle toward (enemy-x, enemy-y)
     (define default-third-x
       (safe-coord (+ base-x (* 24.25 dir-ux) (* -14.0 dir-uy)) 60.5))
     (define default-third-y
       (safe-coord (+ base-y (* 24.25 dir-uy) (* 14.0 dir-ux)) 40.5))
     ;; Enemy natural expansion: 18 tiles from (enemy-x, enemy-y) toward (base-x, base-y)
     (define default-enemy-exp-x
       (safe-coord (- enemy-x (* 18.0 dir-ux)) 148.0))
     (define default-enemy-exp-y
       (safe-coord (- enemy-y (* 18.0 dir-uy)) 148.0))
     (define nat-x (safe-coord (hash-ref base-h 'natural-x default-nat-x) default-nat-x))
     (define nat-y (safe-coord (hash-ref base-h 'natural-y default-nat-y) default-nat-y))
     (define third-x (safe-coord (hash-ref base-h 'third-x default-third-x) default-third-x))
     (define third-y (safe-coord (hash-ref base-h 'third-y default-third-y) default-third-y))
     (define enemy-exp-x
       (safe-coord (hash-ref base-h 'enemy-expand-x (hash-ref base-h 'enemy-exp-x default-enemy-exp-x))
                   default-enemy-exp-x))
     (define enemy-exp-y
       (safe-coord (hash-ref base-h 'enemy-expand-y (hash-ref base-h 'enemy-exp-y default-enemy-exp-y))
                   default-enemy-exp-y))
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
           (map (lambda (e) (sanitize-unit-record e nat-x nat-y)) raw-eu)
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
     (define pend-upgs
       (let ([pu (hash-ref base-h 'pending-upgrades '())])
         (if (list? pu) (filter symbol? pu) '())))
     (define nuke-alert
       (let ([na (hash-ref base-h 'nuke-alert #f)])
         (cond
           [(not na) #f]
           [(pair? na) (cons (safe-coord (car na) nat-x) (safe-coord (cdr na) nat-y))]
           [else (cons nat-x nat-y)])))
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
                  'enemy-expand-x enemy-exp-x
                  'enemy-exp-x enemy-exp-x
                  'enemy-expand-y enemy-exp-y
                  'enemy-exp-y enemy-exp-y
                  'ally-units ally-units
                  'ally-buildings ally-buildings
                  'enemy-units enemy-units
                  'enemy-buildings enemy-buildings
                  'effects effects
                  'visible-sectors vis-secs
                  'researched-upgrades res-upgs
                  'pending-upgrades pend-upgs
                  'nuke-alert nuke-alert))
     (define h2
       (if (hash-has-key? h1 'gas-workers)
           (hash-set h1 'gas-workers (safe-nonneg-int (hash-ref h1 'gas-workers 0) 0))
           h1))
     (define h3
       (if (hash-has-key? h2 'our-terrain-z)
           (hash-set h2 'our-terrain-z (safe-exact-int (hash-ref h2 'our-terrain-z 10) 10))
           h2))
     (define h4
       (if (hash-has-key? h3 'enemy-terrain-z)
           (hash-set h3 'enemy-terrain-z (safe-exact-int (hash-ref h3 'enemy-terrain-z 10) 10))
           h3))
     (define h5
       (for/fold ([acc h4])
                 ([k (in-list '(mineral-harvesters ideal-mineral-harvesters gas-harvesters ideal-gas-harvesters army-supply))])
         (if (hash-has-key? acc k)
             (hash-set acc k (safe-nonneg-int (hash-ref acc k 0) 0))
             acc)))
     h5]))

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
       [(ormap (lambda (t) (memq t '(probe nexus pylon gateway forge cybernetics-core zealot stalker adept sentry))) all-types)
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
  (define ally-units
    (map (lambda (u)
           (if (hash? u)
               (hash-set* u
                          'x (safe-nonneg-int (hash-ref u 'x 32) 32)
                          'y (safe-nonneg-int (hash-ref u 'y 32) 32))
               u))
         (hash-ref obs 'ally-units '())))
  (define enemy-units
    (map (lambda (u)
           (if (hash? u)
               (hash-set* u
                          'x (safe-nonneg-int (hash-ref u 'x 160) 160)
                          'y (safe-nonneg-int (hash-ref u 'y 160) 160))
               u))
         (hash-ref obs 'enemy-units '())))
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

(define (filter-rush-threat-enemies enemy-units [base-x 32.5] [base-y 32.5] [nat-x 45.0] [nat-y 45.0])
  (define rush-dist-thresh 45.0)
  (filter (lambda (e)
            (and (hash? e)
                 (let ([t (unit-type-sym e)]
                       [ex (safe-coord (hash-ref e 'x nat-x) nat-x)]
                       [ey (safe-coord (hash-ref e 'y nat-y) nat-y)])
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
  (define base-x (hash-ref obs 'base-x 32.5))
  (define base-y (hash-ref obs 'base-y 32.5))
  (define nat-x (hash-ref obs 'natural-x 45.0))
  (define nat-y (hash-ref obs 'natural-y 45.0))
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
  (define base-x (hash-ref obs 'base-x 32.5))
  (define base-y (hash-ref obs 'base-y 32.5))
  (define nat-x (hash-ref obs 'natural-x 45.0))
  (define nat-y (hash-ref obs 'natural-y 45.0))
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
  (sc2-supply-cost unit-sym 2))

(define (step-layer2-economy! rt raw-obs)
  (define obs (sanitize-obs-hash raw-obs))
  (define race (live-bot-runtime-actual-race rt))
  (define frame (hash-ref obs 'frame 0))
  (define minerals (hash-ref obs 'minerals 200))
  (define gas (hash-ref obs 'gas SC2-STARTING-GAS))
  (define supply-used (hash-ref obs 'supply-used SC2-STARTING-WORKERS))
  (define supply-cap (hash-ref obs 'supply-cap SC2-TOWN-HALL-SUPPLY-PROVIDED))
  (define pending-supply (hash-ref obs 'pending-supply 0))
  (define supply-left (hash-ref obs 'supply-left (- supply-cap supply-used)))
  (define ally-units (hash-ref obs 'ally-units '()))
  (define ally-bldgs (hash-ref obs 'ally-buildings '()))
  (define enemy-units (hash-ref obs 'enemy-units '()))
  (define enemy-bldgs (hash-ref obs 'enemy-buildings '()))
  (define base-x (hash-ref obs 'base-x SC2-DEFAULT-HOME-BASE-X))
  (define base-y (hash-ref obs 'base-y SC2-DEFAULT-HOME-BASE-Y))
  (define nat-x (hash-ref obs 'natural-x SC2-DEFAULT-NATURAL-X))
  (define nat-y (hash-ref obs 'natural-y SC2-DEFAULT-NATURAL-Y))
  (define third-x (hash-ref obs 'third-x SC2-DEFAULT-THIRD-X))
  (define third-y (hash-ref obs 'third-y SC2-DEFAULT-THIRD-Y))
  (define enemy-x (hash-ref obs 'enemy-x SC2-DEFAULT-ENEMY-BASE-X))
  (define enemy-y (hash-ref obs 'enemy-y SC2-DEFAULT-ENEMY-BASE-Y))

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
          (ormap (lambda (e)
                   (<= (dist2d bx by (hash-ref e 'x 9999) (hash-ref e 'y 9999))
                       SC2-BLDG-UNDER-ATTACK-RADIUS))
                 enemy-units)))
    (when (and (< prog 1.0)
               (or (< hp-pct SC2-DYING-BLDG-CANCEL-HP-PCT)
                   (< hp SC2-DYING-BLDG-CANCEL-MIN-HP))
               enemy-near?)
      (emit! (list 'cancel (hash-ref b 'id 701)))))

  (define cd-tracker (live-bot-runtime-cooldown-tracker rt))

  ;; ---------------------------------------------------------------------------
  ;; Adversarial Countermeasure #4: Halted Terran Building SCV Resume
  ;; (Refractory SC2-RESUME-BLDG-COOLDOWN-FRAMES per building tag + 1 SCV per halted building)
  ;; ---------------------------------------------------------------------------
  (when (eq? race 'Terran)
    (define assigned-resume-scvs (mutable-set))
    (for ([b (in-list ally-bldgs)])
      (define prog (hash-ref b 'build-progress 1.0))
      (define halted? (or (hash-ref b 'halted #f)
                          (and (< prog 1.0) (not (hash-ref b 'has-builder #t)))))
      (define bid (hash-ref b 'id 902))
      (define avail-scv
        (findf (lambda (w) (not (set-member? assigned-resume-scvs (hash-ref w 'id 10))))
               workers))
      (when (and halted?
                 avail-scv
                 (refractory-allow-action?! cd-tracker
                                            (list 'resume-halted-building bid)
                                            frame
                                            SC2-RESUME-BLDG-COOLDOWN-FRAMES))
        (define scv-id (hash-ref avail-scv 'id 10))
        (set-add! assigned-resume-scvs scv-id)
        (emit! (list 'resume-halted-building scv-id bid)))))

  ;; ---------------------------------------------------------------------------
  ;; Adversarial Countermeasure #3: Anti-Gas-Steal Detection & Focus-Fire
  ;; ---------------------------------------------------------------------------
  (define enemy-gas-steals
    (filter (lambda (eb)
              (and (memq (unit-type-sym eb) '(assimilator extractor refinery))
                   (<= (dist2d base-x base-y (hash-ref eb 'x 9999) (hash-ref eb 'y 9999))
                       SC2-GAS-STEAL-RADIUS)))
            enemy-bldgs))
  (for ([eg (in-list enemy-gas-steals)])
    (emit! (list 'clear-gas-steal
                 (hash-ref eg 'id 901)
                 (hash-ref eg 'x (safe-coord (+ base-x 3.0)))
                 (hash-ref eg 'y (safe-coord (+ base-y 3.0))))))

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
  (define cheese-dist-thresh SC2-CHEESE-RUSH-RADIUS)
  (define proxy-or-cheese-enemies
    (filter (lambda (e)
              (and (<= (dist2d base-x base-y (hash-ref e 'x 9999) (hash-ref e 'y 9999)) cheese-dist-thresh)
                   (or (< frame SC2-EARLY-CHEESE-MAX-FRAME)
                       (< (length (filter combat-unit-record? ally-units)) SC2-EARLY-CHEESE-MIN-DEFENDERS))))
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
      (filter (lambda (w) (>= (hash-ref w 'hp SC2-DRONE-MAX-HP) SC2-HEALTHY-WORKER-PULL-MIN-HP)) workers))
    (define pull-ids
      (map (lambda (w) (hash-ref w 'id 10))
           (take healthy-workers (min SC2-MAX-WORKER-PULL-COUNT (length healthy-workers)))))
    (define threat (car proxy-or-cheese-enemies))
    (define tx (hash-ref threat 'x (safe-coord (+ base-x 5.0))))
    (define ty (hash-ref threat 'y (safe-coord (+ base-y 5.0))))
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
  (define nat-block-thresh SC2-NATURAL-BLOCK-RADIUS)
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
        (when (>= minerals (sc2-min-cost 'command-center))
          (emit! (list 'build 'command-center (safe-coord (+ base-x 4.0)) base-y)))
        (when (>= minerals (sc2-min-cost 'hatchery))
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
                     (if (hash? b)
                         (safe-nonneg-int (hash-ref b 'ideal-harvesters SC2-IDEAL-WORKERS-PER-MINERAL-LINE)
                                          SC2-IDEAL-WORKERS-PER-MINERAL-LINE)
                         SC2-IDEAL-WORKERS-PER-MINERAL-LINE)))))
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
                     (if (hash? b)
                         (safe-nonneg-int (hash-ref b 'ideal-harvesters SC2-IDEAL-WORKERS-PER-GEYSER)
                                          SC2-IDEAL-WORKERS-PER-GEYSER)
                         SC2-IDEAL-WORKERS-PER-GEYSER)))))
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
  (define desired-bases
    (max SC2-MIN-DESIRED-BASES
         (min SC2-MAX-ACTIVE-BASES (coupled-macro-plan-desired-bases macro-plan))))
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
     #:current-gas-workers (hash-ref obs 'gas-workers (* SC2-IDEAL-WORKERS-PER-GEYSER (length gas-bldgs)))
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
  ;; Worker Mineral-Walk Escape (Pro Mechanic #5: 4.0 tiles) & Resource Harvesting
  ;; ---------------------------------------------------------------------------
  (for ([w (in-list workers)])
    (define whp (hash-ref w 'hp SC2-DRONE-MAX-HP))
    (define wmax (hash-ref w 'max-hp SC2-DRONE-MAX-HP))
    (define wx (hash-ref w 'x base-x))
    (define wy (hash-ref w 'y base-y))
    (define enemy-close?
      (ormap (lambda (e)
               (<= (dist2d wx wy (hash-ref e 'x 9999) (hash-ref e 'y 9999))
                   SC2-WORKER-ESCAPE-THREAT-RADIUS))
             enemy-units))
    (when (and (or (< whp SC2-WOUNDED-WORKER-MIN-HP)
                   (< (/ (exact->inexact whp) (max 1 wmax)) SC2-WOUNDED-WORKER-HP-PCT))
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
    (define patch-id (hash-ref obs 'mineral-patch-id SC2-SYNTHETIC-MINERAL-PATCH-ID))
    (emit! (list 'harvest-mineral (hash-ref (car workers) 'id 10) patch-id)))

  ;; Early Worker Scout / Harass (Pro Mechanic #5)
  (when (and (hash-ref obs 'enable-worker-harass #f) (not (null? workers)))
    (emit! (list 'worker-harass (hash-ref (last workers) 'id 10) enemy-x enemy-y)))

  ;; Mined-out / Depleting base detection (Scenario 3): auto-expand & transfer workers
  (when (and (or (hash-ref obs 'mined-out #f) (> depleting-bases 0))
             (not natural-blocked?)
             (not under-early-cheese?)
             (refractory-allow-action?! cd-tracker (list 'auto-expand race) frame SC2-EXPANSION-COOLDOWN-FRAMES))
    (emit! (list 'expand (if (>= active-bases 2) third-x nat-x)
                         (if (>= active-bases 2) third-y nat-y))))

  ;; ---------------------------------------------------------------------------
  ;; Zero-Supply-Block & Supply-At-Risk Preemption (Scenario 1: 8.0 tiles Overlord danger)
  ;; ---------------------------------------------------------------------------
  (define threatened-overlords
    (filter (lambda (u)
              (and (eq? (unit-type-sym u) 'overlord)
                   (or (< (hash-ref u 'hp SC2-OVERLORD-MAX-HP) SC2-OVERLORD-DAMAGED-HP-THRESH)
                       (hash-ref u 'under-attack #f)
                       (ormap (lambda (e)
                                (<= (dist2d (hash-ref u 'x base-x) (hash-ref u 'y base-y)
                                            (hash-ref e 'x 9999) (hash-ref e 'y 9999))
                                    SC2-OVERLORD-THREAT-RADIUS))
                              enemy-units))))
            ally-units))
  (for ([ov (in-list threatened-overlords)])
    (emit! (list 'kite (hash-ref ov 'id 102) base-x base-y)))

  ;; Only completed supply structures that are damaged (<65% HP+shields) or under attack
  ;; trigger supply-at-risk (prevents healthy 200-HP Pylons or under-construction Depots
  ;; from triggering infinite Pylon/Depot spam).
  (define threatened-supply-bldgs
    (filter (lambda (b)
              (and (memq (unit-type-sym b) '(supply-depot pylon))
                   (>= (hash-ref b 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS)
                   (or (< (hash-ref b 'hp-pct 1.0) SC2-SUPPLY-BLDG-DAMAGED-HP-PCT)
                       (and (not (hash-has-key? b 'hp-pct))
                            (< (hash-ref b 'hp SC2-PYLON-TOTAL-MAX-HP)
                               (if (eq? (unit-type-sym b) 'pylon)
                                   SC2-PYLON-DAMAGED-HULL-THRESH
                                   SC2-SUPPLY-DEPOT-DAMAGED-HP-THRESH)))
                       (hash-ref b 'under-attack #f))))
            ally-bldgs))

  (define supply-at-risk?
    (or (not (null? threatened-overlords))
        (not (null? threatened-supply-bldgs))
        (hash-ref obs 'supply-at-risk #f)))

  (define ready-bldgs
    (filter (lambda (b) (>= (hash-ref b 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS))
            ally-bldgs))
  (define ready-bldg-types
    (map unit-type-sym ready-bldgs))

  (define ally-combat-units (filter combat-unit-record? ally-units))
  (define rush-threat-enemies (filter-rush-threat-enemies enemy-units base-x base-y nat-x nat-y))
  (define live-army-supply
    (hash-ref obs 'army-supply
              (for/sum ([u (in-list ally-combat-units)])
                (unit-supply-cost (unit-type-sym u)))))
  (define live-enemy-threat-supply
    (for/sum ([e (in-list rush-threat-enemies)])
      (unit-supply-cost (unit-type-sym e))))

  (define pressure-metrics
    (compute-state-pressure-metrics
     #:race race
     #:frame frame
     #:minerals minerals
     #:gas gas
     #:supply-left supply-left
     #:supply-cap supply-cap
     #:pending-supply pending-supply
     #:workers total-workers
     #:target-workers target-workers
     #:active-bases active-bases
     #:desired-bases desired-bases
     #:production-facilities (max 1 (length prod-facilities))
     #:max-facilities (max 2 (* SC2-TERRAN-FACILITIES-PER-BASE active-bases))
     #:army-supply live-army-supply
     #:enemy-threat-supply live-enemy-threat-supply
     #:under-attack? under-early-cheese?
     #:requires-anti-air? (enemy-tech-observation-requires-anti-air? tech-obs)
     #:requires-detection? (enemy-tech-observation-requires-detection? tech-obs)
     #:supply-at-risk? supply-at-risk?))

  (define prio-candidates
    (generate-race-priority-candidates
     #:race race
     #:frame frame
     #:minerals minerals
     #:gas gas
     #:supply-left supply-left
     #:supply-cap supply-cap
     #:pending-supply pending-supply
     #:workers total-workers
     #:target-workers target-workers
     #:active-bases active-bases
     #:desired-bases desired-bases
     #:production-facilities (max 1 (length prod-facilities))
     #:max-facilities (max 2 (* SC2-TERRAN-FACILITIES-PER-BASE active-bases))
     #:army-supply live-army-supply
     #:enemy-threat-supply live-enemy-threat-supply
     #:under-attack? under-early-cheese?
     #:requires-anti-air? (enemy-tech-observation-requires-anti-air? tech-obs)
     #:requires-detection? (enemy-tech-observation-requires-detection? tech-obs)
     #:supply-at-risk? supply-at-risk?
     #:ally-buildings bldg-types
     #:ally-units unit-types
     #:researched-upgrades (hash-ref obs 'researched-upgrades '())
     #:base-x base-x
     #:base-y base-y
     #:nat-x nat-x
     #:nat-y nat-y
     #:third-x third-x
     #:third-y third-y))

  (define prio-sched
    (schedule-priority-candidates-with-ledger!
     prio-candidates
     #:minerals minerals
     #:gas gas
     #:supply-left supply-left
     #:supply-cap supply-cap
     #:escrow-eligible? (hash-ref pressure-metrics 'escrow-eligible? #f)))
  (define prio-scheduled-actions
    (priority-schedule-result-scheduled-actions prio-sched))

  (define supply-threshold
    (cond [(>= supply-cap SC2-MID-SUPPLY-CAP-THRESHOLD) SC2-MID-SUPPLY-BUFFER]
          [(>= supply-cap SC2-EARLY-SUPPLY-CAP-THRESHOLD) SC2-EARLY-SUPPLY-BUFFER]
          [else SC2-BASE-SUPPLY-BUFFER]))
  (define need-supply?
    (and (< supply-cap SC2-MAX-SUPPLY)
         (or (and supply-at-risk?
                  (or (<= pending-supply 0) (hash-ref obs 'supply-at-risk #f)))
             (and (> (hash-ref pressure-metrics 'supply-hazard 0.0) 0.0)
                  (<= pending-supply 1))
             (and (<= (+ supply-left (* SC2-SUPPLY-PER-PROVIDER pending-supply)) supply-threshold)
                  (>= minerals (sc2-min-cost 'overlord))))))

  (when (and need-supply? (>= minerals (sc2-min-cost 'overlord)))
    (case race
      [(Zerg)
       (emit! '(train overlord))
       (set! minerals (- minerals (sc2-min-cost 'overlord)))
       (set! pending-supply (add1 pending-supply))]
      [(Protoss)
       (emit! (list 'build 'pylon (safe-coord (+ base-x 4.0)) (safe-coord (+ base-y 4.0))))
       (set! minerals (- minerals (sc2-min-cost 'pylon)))
       (set! pending-supply (add1 pending-supply))]
      [(Terran)
       (emit! (list 'build 'supply-depot (safe-coord (+ base-x 4.0)) (safe-coord (- base-y 3.0))))
       (set! minerals (- minerals (sc2-min-cost 'supply-depot)))
       (set! pending-supply (add1 pending-supply))]))

  ;; Helper: check if we can spend `cost` supply without supply blocking
  ;; Also reserves supply floor if supply-at-risk and minerals < 150
  (define reserve-supply-floor?
    (and (or supply-at-risk? (<= supply-left SC2-CRITICAL-LOW-SUPPLY))
         (< minerals (+ (sc2-min-cost 'overlord) (sc2-min-cost 'drone)))))
  (define effective-free-supply
    (max 0 (+ supply-left (if (> pending-supply 0) SC2-PENDING-SUPPLY-CREDIT 0))))
  (define (can-spend-supply? cost)
    (and (not reserve-supply-floor?)
         (>= effective-free-supply cost)
         (> supply-left 0)))

  (define researched-upgs (hash-ref obs 'researched-upgrades '()))
  (define pending-upgs (hash-ref obs 'pending-upgrades '()))
  (define (upgrade-needed? upg-sym)
    (and (not (memq upg-sym researched-upgs))
         (not (memq upg-sym pending-upgs))))

  ;; ---------------------------------------------------------------------------
  ;; Race-Specific Macro Mechanics, Tech Trees, Upgrades & Unit Production
  ;; (100% Valid SC2 LotV Symbols + Pure SC2 Tile Offsets + Multi-Base Escrow)
  ;; ---------------------------------------------------------------------------
  (case race
    [(Zerg)
     ;; 1. Queen Inject Larva & Spawn Creep Tumor (Bug #15 & #16 fix:
     ;;    only inject ready hatcheries, and ALWAYS inject when not spawning a tumor on this frame!)
     (define queens (filter (lambda (u) (eq? (unit-type-sym u) 'queen)) ally-units))
     (define hatcheries
       (filter (lambda (b) (memq (unit-type-sym b) '(hatchery lair hive))) ally-bldgs))
     (define ready-hatcheries
       (filter (lambda (b) (memq (unit-type-sym b) '(hatchery lair hive))) ready-bldgs))
     (define inject-hatcheries
       (if (not (null? ready-hatcheries)) ready-hatcheries hatcheries))
     (define extractors
       (filter (lambda (b) (eq? (unit-type-sym b) 'extractor)) ally-bldgs))
     (define tumor-init-x (safe-coord (* 0.5 (+ base-x nat-x)) nat-x))
     (define tumor-init-y (safe-coord (* 0.5 (+ base-y nat-y)) nat-y))
     (for ([q (in-list queens)]
           [q-idx (in-naturals)])
       (define q-energy (hash-ref q 'energy SC2-QUEEN-INJECT-ENERGY))
       (define qid (hash-ref q 'id 120))
       (define target-hatch
         (and (not (null? inject-hatcheries))
              (list-ref inject-hatcheries (modulo q-idx (length inject-hatcheries)))))
       (cond
         [(and (>= q-energy SC2-QUEEN-TUMOR-SURPLUS-ENERGY)
               (refractory-allow-action?! cd-tracker
                                          (list 'queen-tumor qid)
                                          frame
                                          SC2-CREEP-TUMOR-COOLDOWN-FRAMES))
          (emit! (list 'cast-spell qid 'spawn-creep-tumor tumor-init-x tumor-init-y))]
         [(and (>= q-energy SC2-QUEEN-INJECT-ENERGY) target-hatch)
          (emit! (list 'cast-spell qid 'inject-larva (hash-ref target-hatch 'id 101)))]))

     ;; 2. Pro Mechanic #2: Active Creep Tumor Daisy-Chaining
     (define ready-tumors
       (filter (lambda (u)
                 (and (memq (unit-type-sym u) '(creep-tumor creep-tumor-burrowed))
                      (not (set-member? (live-bot-runtime-used-creep-tumors rt)
                                        (hash-ref u 'id 0)))))
               (append ally-units ready-bldgs)))
     (for ([t (in-list (take ready-tumors (min SC2-MAX-TUMOR-SPREADS-PER-FRAME (length ready-tumors))))])
       (define tid (hash-ref t 'id 702))
       (define tx (hash-ref t 'x base-x))
       (define ty (hash-ref t 'y base-y))
       (define dx (- enemy-x tx))
       (define dy (- enemy-y ty))
       (define d (max 1.0 (sqrt (+ (* dx dx) (* dy dy)))))
       (define target-x (safe-coord (+ tx (* SC2-CREEP-TUMOR-STEP-DISTANCE (/ dx d))) tx))
       (define target-y (safe-coord (+ ty (* SC2-CREEP-TUMOR-STEP-DISTANCE (/ dy d))) ty))
       (set-add! (live-bot-runtime-used-creep-tumors rt) tid)
       (emit! (list 'cast tid 'spread-creep-tumor target-x target-y)))

     ;; 3. Multi-Base Expansion Priority (2nd, 3rd, 4th+ bases with refractory cooldown & saturation gate)
     (when (and (>= minerals (sc2-min-cost 'hatchery))
                (not under-early-cheese?)
                (not natural-blocked?)
                (or (< (length hatcheries) SC2-MIN-DESIRED-BASES)
                    (and (< (length hatcheries) desired-bases)
                         (>= total-workers (* (length hatcheries) SC2-MIN-WORKERS-PER-BASE-FOR-EXPAND))
                         (or (coupled-macro-plan-should-expand? macro-plan)
                             (>= frame SC2-MACRO-EXPAND-FRAME-THRESHOLD))))
                (refractory-allow-action?! cd-tracker
                                           (list 'macro-expand 'Zerg)
                                           frame
                                           SC2-EXPANSION-COOLDOWN-FRAMES))
       (define exp-x (if (>= (length hatcheries) SC2-MIN-DESIRED-BASES) third-x nat-x))
       (define exp-y (if (>= (length hatcheries) SC2-MIN-DESIRED-BASES) third-y nat-y))
       (emit! (list 'expand exp-x exp-y))
       (set! minerals (- minerals (sc2-min-cost 'hatchery))))

     ;; 4. Zerg Tech Buildings & Morphs
     (when (and (not (memq 'spawning-pool bldg-types))
                (>= minerals (sc2-min-cost 'spawning-pool)))
       (emit! (list 'build 'spawning-pool (safe-coord (+ base-x 3.0)) (safe-coord (+ base-y 3.0))))
       (set! minerals (- minerals (sc2-min-cost 'spawning-pool))))

     (when (and (memq 'spawning-pool bldg-types)
                (< (length extractors)
                   (min (* SC2-GEYSERS-PER-BASE (length hatcheries))
                        (if (>= total-workers SC2-MIN-WORKERS-FOR-FOUR-GAS)
                            4
                            (if (>= total-workers (add1 SC2-MIN-WORKERS-FOR-GAS)) 1 0))))
                (>= minerals (sc2-min-cost 'gas-building-reserve)))
       (emit! (list 'build 'extractor (safe-coord (+ base-x 4.0)) (safe-coord (+ base-y 4.0))))
       (set! minerals (- minerals (sc2-min-cost 'gas-building-reserve))))

     (when (and (memq 'spawning-pool ready-bldg-types)
                (not (memq 'roach-warren bldg-types))
                (>= total-workers SC2-PRIORITY-WORKERS-PER-BASE)
                (>= minerals (sc2-min-cost 'roach-warren)))
       (emit! (list 'build 'roach-warren (safe-coord (+ base-x 4.0)) (safe-coord (- base-y 4.0))))
       (set! minerals (- minerals (sc2-min-cost 'roach-warren))))

     (when (and (memq 'spawning-pool ready-bldg-types)
                (< (length queens) (min SC2-MAX-QUEENS-CAP (+ 1 (length hatcheries))))
                (>= minerals (sc2-min-cost 'queen))
                (can-spend-supply? (sc2-supply-cost 'queen)))
       (emit! '(train queen))
       (set! minerals (- minerals (sc2-min-cost 'queen))))

     (when (and (memq 'roach-warren ready-bldg-types) (>= gas (sc2-gas-cost 'metabolic-boost)))
       (emit! '(morph ravager))
       (when (and (not (memq 'lair bldg-types))
                  (upgrade-needed? 'metabolic-boost))
         (emit! '(research metabolic-boost))))

     (when (and (memq 'spawning-pool ready-bldg-types)
                (>= minerals (sc2-min-cost 'lair))
                (>= gas (sc2-gas-cost 'lair))
                (not (memq 'lair bldg-types))
                (not (memq 'hive bldg-types)))
       (emit! '(morph lair))
       (set! minerals (- minerals (sc2-min-cost 'lair)))
       (set! gas (- gas (sc2-gas-cost 'lair))))

     (when (and (memq 'spawning-pool ready-bldg-types)
                (>= minerals (+ (sc2-min-cost 'spine-crawler) (sc2-min-cost 'roach-warren)))
                (not (memq 'spine-crawler bldg-types))
                (or under-early-cheese? (>= total-workers SC2-IDEAL-WORKERS-PER-BASE)))
       (emit! (list 'build 'spine-crawler nat-x nat-y)))

     (when (or (memq 'lair ready-bldg-types) (memq 'hive ready-bldg-types))
       (when (and (not (memq 'spire bldg-types))
                  (>= minerals (sc2-min-cost 'spire))
                  (>= gas (sc2-gas-cost 'spire)))
         (emit! (list 'build 'spire (safe-coord (+ base-x 5.0)) (safe-coord (+ base-y 4.0)))))
       (when (and (not (memq 'hydralisk-den bldg-types))
                  (>= minerals (sc2-min-cost 'hydralisk-den))
                  (>= gas (sc2-gas-cost 'hydralisk-den)))
         (emit! (list 'build 'hydralisk-den (safe-coord (+ base-x 4.0)) (safe-coord (+ base-y 5.0)))))
       (when (and (not (memq 'baneling-nest bldg-types))
                  (>= minerals (sc2-min-cost 'baneling-nest))
                  (>= gas (sc2-gas-cost 'baneling-nest)))
         (emit! (list 'build 'baneling-nest (safe-coord (+ base-x 3.0)) (safe-coord (- base-y 3.0)))))
       (when (and (memq 'hydralisk-den ready-bldg-types)
                  (>= gas (sc2-gas-cost 'adaptive-talons))
                  (upgrade-needed? 'adaptive-talons))
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
       (when (refractory-allow-action?! cd-tracker
                                        (list 'static-detector 'spore-crawler)
                                        frame
                                        SC2-STATIC-DETECTOR-COOLDOWN-FRAMES)
         (emit! (list 'build 'spore-crawler (safe-coord (+ base-x 3.0)) (safe-coord (+ base-y 3.0)))))
       (emit! '(morph overseer)))

     ;; Overseer Changeling scout (Pro Mechanic #5)
     (define overseers (filter (lambda (u) (eq? (unit-type-sym u) 'overseer)) ally-units))
     (for ([ov (in-list overseers)])
       (when (>= (hash-ref ov 'energy SC2-OVERSEER-CHANGELING-ENERGY) SC2-OVERSEER-CHANGELING-ENERGY)
         (emit! (list 'cast (hash-ref ov 'id 190) 'spawn-changeling enemy-x enemy-y))))

     (when (and (memq 'spire ready-bldg-types) (memq 'hydralisk-den ready-bldg-types))
       (emit! '(morph lurker))
       (emit! '(morph hive)))

     ;; 5. Zerg Worker Saturation Priority vs Combat Unit Training
     (define zerg-drone-priority?
       (and (< total-workers (min target-workers (* SC2-PRIORITY-WORKERS-PER-BASE (max 1 (length hatcheries)))))
            (>= minerals (sc2-min-cost 'drone))
            (can-spend-supply? (sc2-supply-cost 'drone))
            (not under-early-cheese?)
            (< (hash-ref pressure-metrics 'threat-pressure 0.0) 0.75)
            (< (hash-ref pressure-metrics 'gas-imbalance 0.0) 1.5)))
     (when zerg-drone-priority?
       (emit! '(train drone))
       (set! minerals (- minerals (sc2-min-cost 'drone))))

     ;; Zerg Combat Unit Training
     (cond
       [(and (memq 'spire ready-bldg-types)
             (>= minerals (sc2-min-cost 'corruptor))
             (>= gas (sc2-gas-cost 'corruptor))
             (can-spend-supply? (sc2-supply-cost 'corruptor)))
        (emit! '(train corruptor))
        (emit! '(train mutalisk))
        (when (memq 'hydralisk-den ready-bldg-types)
          (emit! '(train hydralisk))
          (emit! '(train lurker)))]
       [(and (memq 'hydralisk-den ready-bldg-types)
             (>= minerals (sc2-min-cost 'hydralisk))
             (>= gas (sc2-gas-cost 'hydralisk))
             (can-spend-supply? (sc2-supply-cost 'hydralisk)))
        (emit! '(train hydralisk))
        (when (memq 'roach-warren ready-bldg-types)
          (emit! '(train roach)))]
       [(and (or (memq 'roach-warren ready-bldg-types) (memq 'lair ready-bldg-types))
             (>= minerals (sc2-min-cost 'roach))
             (or (>= gas (sc2-gas-cost 'roach))
                 (and (memq 'lair ready-bldg-types) (>= minerals (sc2-min-cost 'queen))))
             (can-spend-supply? (sc2-supply-cost 'roach)))
        (emit! '(train roach))
        (when (and (>= minerals (+ (sc2-min-cost 'roach) (sc2-min-cost 'zergling)))
                   (memq 'spawning-pool ready-bldg-types))
          (emit! '(train zergling)))]
       [(and (memq 'spawning-pool ready-bldg-types)
             (>= minerals (sc2-min-cost 'zergling))
             (can-spend-supply? (sc2-supply-cost 'zergling))
             (or under-early-cheese?
                 (>= (hash-ref pressure-metrics 'threat-pressure 0.0) 0.35)
                 (>= total-workers (add1 SC2-PRIORITY-WORKERS-PER-BASE))
                 (< (length ally-combat-units) SC2-ATTACK-WAVE-MIN-COMBAT-UNITS)
                 (>= minerals (sc2-min-cost 'queen))))
        (when (and (memq 'baneling-nest ready-bldg-types) (>= gas (sc2-gas-cost 'baneling)))
          (emit! '(morph baneling))
          (emit! '(train baneling)))
        (emit! '(train zergling))])

     (when (and (not zerg-drone-priority?)
                (< total-workers target-workers)
                (>= minerals (sc2-min-cost 'drone))
                (can-spend-supply? (sc2-supply-cost 'drone))
                (or (member '(train drone) prio-scheduled-actions)
                    (and (< (hash-ref pressure-metrics 'threat-pressure 0.0) 1.0)
                         (< (hash-ref pressure-metrics 'gas-imbalance 0.0) 1.5))))
       (emit! '(train drone)))]

    [(Protoss)
     ;; 1. Pro Mechanic #6: Dynamic 11-Structure Chrono Boost Target Shifting (Bug #16 fix: only ready buildings)
     (define nexuses (filter (lambda (b) (eq? (unit-type-sym b) 'nexus)) ally-bldgs))
     (define ready-nexuses (filter (lambda (b) (eq? (unit-type-sym b) 'nexus)) ready-bldgs))
     (define assimilators (filter (lambda (b) (eq? (unit-type-sym b) 'assimilator)) ally-bldgs))
     (define gateways
       (filter (lambda (b) (memq (unit-type-sym b) '(gateway warp-gate))) ally-bldgs))
     (for ([nx (in-list ready-nexuses)])
       (when (>= (hash-ref nx 'energy SC2-NEXUS-CHRONO-BOOST-ENERGY) SC2-NEXUS-CHRONO-BOOST-ENERGY)
         (define nx-id (hash-ref nx 'id 201))
         (define chrono-target
           (if (and (< total-workers SC2-EARLY-CHRONO-MAX-WORKERS)
                    (< frame SC2-EARLY-CHRONO-NEXUS-MAX-FRAME))
               nx
               (or (for/or ([prio-type (in-list PRO-CHRONO-11-STRUCTURES)]
                            #:when (not (eq? prio-type 'nexus)))
                     (findf (lambda (b) (eq? (unit-type-sym b) prio-type)) ready-bldgs))
                   nx)))
         (emit! (list 'cast-spell nx-id 'chrono-boost (hash-ref chrono-target 'id nx-id)))))

     ;; 2. Pro Mechanic #3: Protoss 1-Tile Hold-Position Door Guard + Group Steal
     (define door-guards
       (filter (lambda (u) (memq (unit-type-sym u) '(zealot adept))) ally-units))
     (when (and (not (null? door-guards))
                (or (hash-ref obs 'door-guard #f)
                    (and (or (memq 'gateway bldg-types) (memq 'warp-gate bldg-types))
                         (< frame SC2-DOOR-GUARD-MAX-FRAME)
                         (not (null? enemy-units)))))
       (define dg (car door-guards))
       (define dg-id (hash-ref dg 'id 703))
       (emit! (list 'hold-position dg-id nat-x nat-y))
       (emit! (list 'control-group-steal 2 (list dg-id)))
       (cortex-steal-control-group! (live-bot-runtime-cortex rt) 2 (list dg-id)))

     ;; 3. Multi-Base Expansion Priority (2nd, 3rd, 4th+ bases with refractory cooldown & saturation gate)
     (when (and (>= minerals (sc2-min-cost 'nexus))
                (not under-early-cheese?)
                (not natural-blocked?)
                (or (< (length nexuses) SC2-MIN-DESIRED-BASES)
                    (and (< (length nexuses) desired-bases)
                         (>= total-workers (* (length nexuses) SC2-MIN-WORKERS-PER-BASE-FOR-EXPAND))
                         (or (coupled-macro-plan-should-expand? macro-plan)
                             (>= frame SC2-MACRO-EXPAND-FRAME-THRESHOLD))))
                (refractory-allow-action?! cd-tracker
                                           (list 'macro-expand 'Protoss)
                                           frame
                                           SC2-EXPANSION-COOLDOWN-FRAMES))
       (define exp-x (if (>= (length nexuses) SC2-MIN-DESIRED-BASES) third-x nat-x))
       (define exp-y (if (>= (length nexuses) SC2-MIN-DESIRED-BASES) third-y nat-y))
       (emit! (list 'expand exp-x exp-y))
       (set! minerals (- minerals (sc2-min-cost 'nexus))))

     ;; 4. Protoss Tech & Production Scaling
     (when (and (null? gateways) (>= minerals (sc2-min-cost 'gateway)))
       (emit! (list 'build 'gateway (safe-coord (+ base-x 4.0)) (safe-coord (+ base-y 4.0))))
       (set! minerals (- minerals (sc2-min-cost 'gateway))))

     (when (and (or (memq 'gateway bldg-types) (memq 'warp-gate bldg-types))
                (< (length assimilators)
                   (min (* SC2-GEYSERS-PER-BASE (length nexuses))
                        (if (>= total-workers SC2-MIN-WORKERS-FOR-SECOND-GAS) 4 2)))
                (>= minerals (sc2-min-cost 'assimilator)))
       (emit! (list 'build 'assimilator (safe-coord (+ base-x 4.0)) (safe-coord (+ base-y 4.0))))
       (set! minerals (- minerals (sc2-min-cost 'assimilator))))

     (when (and (or (memq 'gateway ready-bldg-types) (memq 'warp-gate ready-bldg-types))
                (not (memq 'cybernetics-core bldg-types))
                (>= minerals (sc2-min-cost 'cybernetics-core)))
       (emit! (list 'build 'cybernetics-core (safe-coord (+ base-x 6.0)) (safe-coord (+ base-y 4.0))))
       (set! minerals (- minerals (sc2-min-cost 'cybernetics-core))))

     (when (and (memq 'cybernetics-core ready-bldg-types)
                (not (memq 'robotics-facility bldg-types))
                (>= minerals (sc2-min-cost 'robotics-facility))
                (>= gas (sc2-gas-cost 'robotics-facility)))
       (emit! (list 'build 'robotics-facility (safe-coord (+ base-x 6.0)) (safe-coord (+ base-y 6.0))))
       (emit! '(morph warp-gate))
       (set! minerals (- minerals (sc2-min-cost 'robotics-facility)))
       (set! gas (- gas (sc2-gas-cost 'robotics-facility))))

     (define desired-gateways
       (min SC2-MAX-PRODUCTION-FACILITIES
            (max 1 (if (>= (length nexuses) SC2-MIN-DESIRED-BASES)
                       (* SC2-PROTOSS-FACILITIES-PER-BASE (length nexuses))
                       (if (memq 'cybernetics-core bldg-types) 2 1)))))
     (when (and (>= (length gateways) 1)
                (< (length gateways) desired-gateways)
                (or (memq 'cybernetics-core bldg-types)
                    (>= minerals SC2-SURPLUS-MINERAL-BANK-THRESHOLD))
                (>= minerals (sc2-min-cost 'gateway)))
       (define gw-idx (length gateways))
       (emit! (list 'build 'gateway
                    (safe-coord (+ base-x 4.0 (* 2.0 (modulo gw-idx 3))))
                    (safe-coord (+ base-y 4.0 (* 2.0 (quotient gw-idx 3))))))
       (set! minerals (- minerals (sc2-min-cost 'gateway))))

     (when (and (memq 'robotics-facility ready-bldg-types)
                (not (memq 'robotics-bay bldg-types))
                (not (memq 'robotics-support-bay bldg-types))
                (>= minerals (sc2-min-cost 'robotics-bay))
                (>= gas (sc2-gas-cost 'robotics-bay)))
       (emit! (list 'build 'robotics-bay (safe-coord (+ base-x 7.0)) (safe-coord (+ base-y 7.0))))
       (when (upgrade-needed? 'protoss-ground-weapons-1)
         (emit! '(research protoss-ground-weapons-1)))
       (when (refractory-allow-action?! cd-tracker
                                        (list 'static-detector 'photon-cannon)
                                        frame
                                        SC2-STATIC-DETECTOR-COOLDOWN-FRAMES)
         (emit! (list 'build 'photon-cannon nat-x nat-y))))

     ;; 5. Protoss Probe Saturation Priority + Combat Unit Training
     (define protoss-probe-priority?
       (and (< total-workers (min target-workers (* SC2-PRIORITY-WORKERS-PER-BASE (max 1 (length nexuses)))))
            (>= minerals (sc2-min-cost 'probe))
            (can-spend-supply? (sc2-supply-cost 'probe))
            (not under-early-cheese?)
            (< (hash-ref pressure-metrics 'threat-pressure 0.0) 0.85)
            (< (hash-ref pressure-metrics 'gas-imbalance 0.0) 1.5)))
     (when protoss-probe-priority?
       (emit! '(train probe))
       (set! minerals (- minerals (sc2-min-cost 'probe))))

     ;; Protoss Unit Training (combat priority first, then support/detection)
     (when (can-spend-supply? (sc2-supply-cost 'zealot))
       (cond
         [(memq 'robotics-facility ready-bldg-types)
          (when (and (or (memq 'robotics-bay ready-bldg-types)
                         (memq 'robotics-support-bay ready-bldg-types))
                     (>= minerals (sc2-min-cost 'colossus))
                     (>= gas (sc2-gas-cost 'colossus)))
            (emit! '(train colossus)))
          (when (and (>= minerals (sc2-min-cost 'immortal))
                     (>= gas (sc2-gas-cost 'immortal)))
            (emit! '(train immortal)))
          (when (and (>= minerals (sc2-min-cost 'stalker))
                     (>= gas (sc2-gas-cost 'stalker)))
            (emit! '(train stalker)))
          (when (and (>= minerals (sc2-min-cost 'zealot))
                     (< gas (sc2-gas-cost 'stalker)))
            (emit! '(train zealot)))
          (when (and (not (memq 'observer unit-types))
                     (>= minerals (sc2-min-cost 'observer))
                     (>= gas (sc2-gas-cost 'observer)))
            (emit! '(train observer)))]
         [(memq 'cybernetics-core ready-bldg-types)
          (when (and (>= minerals (sc2-min-cost 'stalker))
                     (>= gas (sc2-gas-cost 'stalker)))
            (emit! '(train stalker))
            (emit! '(train adept)))
          (when (and (>= minerals (sc2-min-cost 'sentry))
                     (>= gas (sc2-gas-cost 'sentry)))
            (emit! '(train sentry)))
          (when (>= minerals (sc2-min-cost 'zealot))
            (emit! '(train zealot)))]
         [(or (memq 'gateway ready-bldg-types) (memq 'warp-gate ready-bldg-types))
          (when (>= minerals (sc2-min-cost 'zealot))
            (emit! '(train zealot)))]))

     (when (and (not protoss-probe-priority?)
                (< total-workers target-workers)
                (>= minerals (sc2-min-cost 'probe))
                (can-spend-supply? (sc2-supply-cost 'probe))
                (or (member '(train probe) prio-scheduled-actions)
                    (and (< (hash-ref pressure-metrics 'threat-pressure 0.0) 1.0)
                         (< (hash-ref pressure-metrics 'gas-imbalance 0.0) 1.5))))
       (emit! '(train probe)))]

    [(Terran)
     ;; 1. Orbital Command Morph, MULE Calldown & Scanner Sweep (Bug #14 fix: real mineral-patch-id)
     (define ccs
       (filter (lambda (b) (memq (unit-type-sym b) '(command-center orbital-command planetary-fortress)))
               ally-bldgs))
     (define refineries
       (filter (lambda (b) (eq? (unit-type-sym b) 'refinery)) ally-bldgs))
     (define barracks-list
       (filter (lambda (b) (eq? (unit-type-sym b) 'barracks)) ally-bldgs))
     (define mule-patch-id (hash-ref obs 'mineral-patch-id SC2-SYNTHETIC-MINERAL-PATCH-ID))
     (for ([cc (in-list ccs)])
       (define ctype (unit-type-sym cc))
       (define cid (hash-ref cc 'id 301))
       (define cenergy (hash-ref cc 'energy SC2-ORBITAL-MULE-ENERGY))
       (cond
         [(and (eq? ctype 'command-center)
               (>= (hash-ref cc 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS)
               (memq 'barracks ready-bldg-types)
               (>= minerals (sc2-min-cost 'orbital-command)))
          (emit! (list 'morph cid 'orbital-command))]
         [(and (eq? ctype 'orbital-command)
               (>= (hash-ref cc 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS))
          (define cloaked-enemy
            (findf (lambda (e)
                     (or (hash-ref e 'cloaked #f)
                         (hash-ref e 'burrowed #f)
                         (memq (unit-type-sym e) '(lurker dark-templar banshee ghost))))
                   enemy-units))
          (if (and cloaked-enemy (>= cenergy SC2-ORBITAL-SCAN-ENERGY))
              (emit! (list 'cast-spell cid 'scanner-sweep
                           (safe-coord (hash-ref cloaked-enemy 'x nat-x) nat-x)
                           (safe-coord (hash-ref cloaked-enemy 'y nat-y) nat-y)))
              (when (>= cenergy SC2-ORBITAL-MULE-ENERGY)
                (emit! (list 'cast-spell cid 'calldown-mule mule-patch-id))))]))

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

     ;; 3. Multi-Base Expansion Priority (2nd, 3rd, 4th+ bases with refractory cooldown & saturation gate)
     (when (and (>= minerals (sc2-min-cost 'command-center))
                (not under-early-cheese?)
                (not natural-blocked?)
                (or (< (length ccs) SC2-MIN-DESIRED-BASES)
                    (and (< (length ccs) desired-bases)
                         (>= total-workers (* (length ccs) SC2-MIN-WORKERS-PER-BASE-FOR-EXPAND))
                         (or (coupled-macro-plan-should-expand? macro-plan)
                             (>= frame SC2-MACRO-EXPAND-FRAME-THRESHOLD))))
                (refractory-allow-action?! cd-tracker
                                           (list 'macro-expand 'Terran)
                                           frame
                                           SC2-EXPANSION-COOLDOWN-FRAMES))
       (define exp-x (if (>= (length ccs) SC2-MIN-DESIRED-BASES) third-x nat-x))
       (define exp-y (if (>= (length ccs) SC2-MIN-DESIRED-BASES) third-y nat-y))
       (emit! (list 'expand exp-x exp-y))
       (set! minerals (- minerals (sc2-min-cost 'command-center))))

     ;; 4. Terran Tech Buildings, Production Scaling & Upgrades (Bug #18 fix: check both barracks-techlab & barracks-tech-lab)
     (when (and (null? barracks-list) (>= minerals (sc2-min-cost 'barracks)))
       (emit! (list 'build 'barracks (safe-coord (+ base-x 4.0)) (safe-coord (+ base-y 4.0))))
       (set! minerals (- minerals (sc2-min-cost 'barracks))))

     (when (and (memq 'barracks bldg-types)
                (< (length refineries)
                   (min (* SC2-GEYSERS-PER-BASE (length ccs))
                        (if (>= total-workers SC2-MIN-WORKERS-FOR-SECOND-GAS) 4 2)))
                (>= minerals (sc2-min-cost 'refinery)))
       (emit! (list 'build 'refinery (safe-coord (+ base-x 3.0)) (safe-coord (+ base-y 5.0))))
       (set! minerals (- minerals (sc2-min-cost 'refinery))))

     (define has-rax-techlab?
       (or (memq 'barracks-techlab bldg-types)
           (memq 'barracks-tech-lab bldg-types)))
     (when (and (memq 'barracks ready-bldg-types)
                (not has-rax-techlab?)
                (>= minerals (sc2-min-cost 'barracks-techlab))
                (>= gas (sc2-gas-cost 'barracks-techlab)))
       (emit! (list 'build 'barracks-techlab (safe-coord (+ base-x 4.0)) (safe-coord (+ base-y 6.0)))))

     ;; Bug #18 fix: research Stimpack and Combat Shield at Barracks Tech Lab
     (when (and (or (memq 'barracks-techlab ready-bldg-types)
                    (memq 'barracks-tech-lab ready-bldg-types))
                (>= minerals (sc2-min-cost 'stimpack))
                (>= gas (sc2-gas-cost 'stimpack)))
       (cond
         [(upgrade-needed? 'stimpack)
          (emit! '(research stimpack))]
         [(upgrade-needed? 'combat-shield)
          (emit! '(research combat-shield))]))

     (when (and (memq 'barracks ready-bldg-types)
                (not (memq 'factory bldg-types))
                (>= minerals (sc2-min-cost 'factory))
                (>= gas (sc2-gas-cost 'factory)))
       (emit! (list 'build 'factory (safe-coord (+ base-x 6.0)) (safe-coord (+ base-y 4.0))))
       (set! minerals (- minerals (sc2-min-cost 'factory)))
       (set! gas (- gas (sc2-gas-cost 'factory))))

     (define desired-barracks
       (min SC2-MAX-PRODUCTION-FACILITIES
            (max 1 (if (>= (length ccs) SC2-MIN-DESIRED-BASES)
                       (* SC2-TERRAN-FACILITIES-PER-BASE (length ccs))
                       (if (memq 'factory bldg-types) 2 1)))))
     (when (and (>= (length barracks-list) 1)
                (< (length barracks-list) desired-barracks)
                (or (memq 'factory bldg-types)
                    (< gas (sc2-gas-cost 'factory))
                    (>= minerals SC2-SURPLUS-MINERAL-BANK-THRESHOLD))
                (>= minerals (sc2-min-cost 'barracks)))
       (define rax-idx (length barracks-list))
       (emit! (list 'build 'barracks
                    (safe-coord (+ base-x 4.0 (* 3.0 (modulo rax-idx 3))))
                    (safe-coord (+ base-y 4.0 (* 3.0 (quotient rax-idx 3))))))
       (set! minerals (- minerals (sc2-min-cost 'barracks))))

     (when (and (memq 'factory ready-bldg-types) (>= minerals (sc2-min-cost 'starport)))
       (when (and (not (or (memq 'factory-techlab bldg-types)
                           (memq 'factory-tech-lab bldg-types)))
                  (>= gas (sc2-gas-cost 'factory-techlab)))
         (emit! (list 'build 'factory-techlab (safe-coord (+ base-x 8.0)) (safe-coord (+ base-y 4.0)))))
       (when (and (not (memq 'armory bldg-types)) (>= gas (sc2-gas-cost 'armory)))
         (emit! (list 'build 'armory (safe-coord (+ base-x 6.0)) (safe-coord (+ base-y 4.0)))))
       (when (upgrade-needed? 'drilling-claws)
         (emit! '(research drilling-claws)))
       (when (and (not (memq 'starport bldg-types)) (>= gas (sc2-gas-cost 'starport)))
         (emit! (list 'build 'starport (safe-coord (+ base-x 6.0)) (safe-coord (+ base-y 7.0))))))

     (when (and (memq 'starport ready-bldg-types) (>= minerals (sc2-min-cost 'ghost-academy)))
       (when (not (or (memq 'starport-techlab bldg-types)
                      (memq 'starport-tech-lab bldg-types)))
         (emit! (list 'build 'starport-techlab (safe-coord (+ base-x 8.0)) (safe-coord (+ base-y 7.0)))))
       (when (and (not (memq 'ghost-academy bldg-types)) (>= gas (sc2-gas-cost 'ghost-academy)))
         (emit! (list 'build 'ghost-academy (safe-coord (+ base-x 9.0)) (safe-coord (+ base-y 6.0)))))
       (when (not (memq 'engineering-bay bldg-types))
         (emit! (list 'build 'engineering-bay (safe-coord (+ base-x 5.0)) (safe-coord (- base-y 3.0)))))
       (when (refractory-allow-action?! cd-tracker
                                        (list 'static-detector 'missile-turret)
                                        frame
                                        SC2-STATIC-DETECTOR-COOLDOWN-FRAMES)
         (emit! (list 'build 'missile-turret (safe-coord (+ base-x 3.0)) (safe-coord (+ base-y 3.0)))))
       (when (upgrade-needed? 'personal-cloaking)
         (emit! '(research personal-cloaking))))

     ;; 5. Terran SCV Saturation Priority + Combat Unit Training
     (define terran-scv-priority?
       (and (< total-workers (min target-workers (* SC2-PRIORITY-WORKERS-PER-BASE (max 1 (length ccs)))))
            (>= minerals (sc2-min-cost 'scv))
            (can-spend-supply? (sc2-supply-cost 'scv))
            (not under-early-cheese?)
            (< (hash-ref pressure-metrics 'threat-pressure 0.0) 0.85)
            (< (hash-ref pressure-metrics 'gas-imbalance 0.0) 1.5)))
     (when terran-scv-priority?
       (emit! '(train scv))
       (set! minerals (- minerals (sc2-min-cost 'scv))))

     ;; Terran Unit Training (including Widow Mine & Siege Tank & Bio)
     (when (can-spend-supply? (sc2-supply-cost 'marine))
       (cond
         [(memq 'starport ready-bldg-types)
          (when (and (>= minerals (sc2-min-cost 'siege-tank))
                     (>= gas (sc2-gas-cost 'siege-tank))
                     (can-spend-supply? (sc2-supply-cost 'siege-tank)))
            (emit! '(train siege-tank)))
          (when (and (>= minerals (sc2-min-cost 'medivac))
                     (>= gas (sc2-gas-cost 'medivac))
                     (can-spend-supply? (sc2-supply-cost 'medivac)))
            (emit! '(train viking))
            (emit! '(train medivac)))
          (when (and (>= minerals (sc2-min-cost 'widow-mine))
                     (>= gas (sc2-gas-cost 'widow-mine))
                     (can-spend-supply? (sc2-supply-cost 'widow-mine)))
            (emit! '(train widow-mine)))
          (when (and (>= minerals (sc2-min-cost 'marauder))
                     (>= gas (sc2-gas-cost 'marauder))
                     (can-spend-supply? (sc2-supply-cost 'marauder)))
            (emit! '(train marauder)))
          (when (>= minerals (sc2-min-cost 'marine))
            (emit! '(train marine)))]
         [(memq 'factory ready-bldg-types)
          (when (and (>= minerals (sc2-min-cost 'siege-tank))
                     (>= gas (sc2-gas-cost 'siege-tank))
                     (can-spend-supply? (sc2-supply-cost 'siege-tank)))
            (emit! '(train siege-tank)))
          (when (and (>= minerals (sc2-min-cost 'widow-mine))
                     (>= gas (sc2-gas-cost 'widow-mine))
                     (can-spend-supply? (sc2-supply-cost 'widow-mine)))
            (emit! '(train widow-mine)))
          (when (and (>= minerals (sc2-min-cost 'hellion))
                     (can-spend-supply? (sc2-supply-cost 'hellion)))
            (emit! '(train hellion)))
          (when (and (>= minerals (sc2-min-cost 'marauder))
                     (>= gas (sc2-gas-cost 'marauder))
                     (can-spend-supply? (sc2-supply-cost 'marauder)))
            (emit! '(train marauder)))
          (when (>= minerals (sc2-min-cost 'marine))
            (emit! '(train marine)))]
         [(memq 'barracks ready-bldg-types)
          (when (and (>= minerals (sc2-min-cost 'marauder))
                     (>= gas (sc2-gas-cost 'marauder))
                     (can-spend-supply? (sc2-supply-cost 'marauder)))
            (emit! '(train marauder)))
          (when (>= minerals (sc2-min-cost 'marine))
            (emit! '(train marine)))]))

     (when (and (not terran-scv-priority?)
                (< total-workers target-workers)
                (>= minerals (sc2-min-cost 'scv))
                (can-spend-supply? (sc2-supply-cost 'scv))
                (or (member '(train scv) prio-scheduled-actions)
                    (and (< (hash-ref pressure-metrics 'threat-pressure 0.0) 1.0)
                         (< (hash-ref pressure-metrics 'gas-imbalance 0.0) 1.5))))
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

;; Select the nearest enemy unit (or lowest HP enemy within engagement range)
(define (select-target-enemy-for-unit ux uy enemy-units)
  (let loop ([rem (cdr enemy-units)]
             [best (car enemy-units)]
             [best-score
              (let* ([e0 (car enemy-units)]
                     [d0 (dist2d ux uy (hash-ref e0 'x ux) (hash-ref e0 'y uy))]
                     [hp0 (safe-finite-real (hash-ref e0 'hp 100) 100.0)])
                (if (<= d0 SC2-ENGAGEMENT-FOCUS-FIRE-RADIUS)
                    (+ (* 2.0 d0) (* 0.05 hp0))
                    (+ 100.0 (* 4.0 d0) (* 0.02 hp0))))])
    (if (null? rem)
        best
        (let* ([e (car rem)]
               [d (dist2d ux uy (hash-ref e 'x ux) (hash-ref e 'y uy))]
               [hp (safe-finite-real (hash-ref e 'hp 100) 100.0)]
               [sc (if (<= d SC2-ENGAGEMENT-FOCUS-FIRE-RADIUS)
                       (+ (* 2.0 d) (* 0.05 hp))
                       (+ 100.0 (* 4.0 d) (* 0.02 hp)))])
          (if (< sc best-score)
              (loop (cdr rem) e sc)
              (loop (cdr rem) best best-score))))))

(define (step-layer3-and-4-tactics! rt raw-obs fap-score)
  (define obs (sanitize-obs-hash raw-obs))
  (define ally-units (hash-ref obs 'ally-units '()))
  (define enemy-units (hash-ref obs 'enemy-units '()))
  (define enemy-bldgs (hash-ref obs 'enemy-buildings '()))
  (define effects (hash-ref obs 'effects '()))
  (define base-x (hash-ref obs 'base-x SC2-DEFAULT-HOME-BASE-X))
  (define base-y (hash-ref obs 'base-y SC2-DEFAULT-HOME-BASE-Y))
  (define nat-x (hash-ref obs 'natural-x SC2-DEFAULT-NATURAL-X))
  (define nat-y (hash-ref obs 'natural-y SC2-DEFAULT-NATURAL-Y))
  (define third-x (hash-ref obs 'third-x SC2-DEFAULT-THIRD-X))
  (define third-y (hash-ref obs 'third-y SC2-DEFAULT-THIRD-Y))
  (define enemy-x (hash-ref obs 'enemy-x SC2-DEFAULT-ENEMY-BASE-X))
  (define enemy-y (hash-ref obs 'enemy-y SC2-DEFAULT-ENEMY-BASE-Y))
  (define enemy-exp-x (hash-ref obs 'enemy-expand-x SC2-DEFAULT-ENEMY-EXPAND-X))
  (define enemy-exp-y (hash-ref obs 'enemy-expand-y SC2-DEFAULT-ENEMY-EXPAND-Y))

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
  ;; Scenario 9: Nuclear Strike / Nuke Calldown Alert Evasion (10.0 tiles)
  ;; ---------------------------------------------------------------------------
  (define nuke-alert (hash-ref obs 'nuke-alert #f))
  (when nuke-alert
    (define nx (if (pair? nuke-alert) (car nuke-alert) nat-x))
    (define ny (if (pair? nuke-alert) (cdr nuke-alert) nat-y))
    (for ([u (in-list ally-units)])
      (when (<= (dist2d nx ny (hash-ref u 'x nx) (hash-ref u 'y ny)) SC2-NUKE-EVASION-RADIUS)
        (emit! (list 'kite (hash-ref u 'id 101) base-x base-y)))))

  ;; ---------------------------------------------------------------------------
  ;; Scenario 4: Hidden / Corner Flying Building Search when Enemy Base Cleared
  ;; ---------------------------------------------------------------------------
  (when (and (hash-ref obs 'enemy-main-cleared #f)
             (null? enemy-units)
             (null? enemy-bldgs)
             (not (null? combat-units)))
    (define corners '((16.0 . 16.0) (16.0 . 240.0) (240.0 . 16.0) (240.0 . 240.0)))
    (for ([u (in-list combat-units)]
          [idx (in-naturals)])
      (define c (list-ref corners (modulo idx (length corners))))
      (emit! (list 'attack-pos (hash-ref u 'id 101) (car c) (cdr c)))))

  ;; ---------------------------------------------------------------------------
  ;; Pro Mechanic #4: Active Transport Juggling (Load/Unload, 10.0 tiles) & Multi-Prong Drop
  ;; ---------------------------------------------------------------------------
  (define transports
    (filter (lambda (u) (memq (unit-type-sym u) '(warp-prism warp-prism-phasing medivac overlord-transport)))
            ally-units))
  (for ([tr (in-list transports)])
    (define tr-id (hash-ref tr 'id 706))
    (define tx (hash-ref tr 'x base-x))
    (define ty (hash-ref tr 'y base-y))
    (define wounded-passenger
      (findf (lambda (u)
               (and (combat-unit-record? u)
                    (<= (dist2d tx ty (hash-ref u 'x tx) (hash-ref u 'y ty)) SC2-TRANSPORT-JUGGLE-RADIUS)
                    (or (< (hash-ref u 'hp 100) SC2-WOUNDED-PASSENGER-MIN-HP)
                        (< (/ (exact->inexact (hash-ref u 'hp 100))
                              (max 1 (hash-ref u 'max-hp 100)))
                           SC2-WOUNDED-PASSENGER-HP-PCT))))
             combat-units))
    (if wounded-passenger
        (emit! (list 'transport-juggle tr-id (hash-ref wounded-passenger 'id 707) base-x base-y))
        (emit! (list 'multi-prong-drop tr-id enemy-x enemy-y))))

  ;; ---------------------------------------------------------------------------
  ;; Adversarial Countermeasure #5: Ramp Force-Field Corrosive-Bile Breaker
  ;; (Only step back units within SC2-FORCE-FIELD-STEPBACK-RADIUS of the Force Field!)
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
    (for ([u (in-list combat-units)])
      (define ux (hash-ref u 'x base-x))
      (define uy (hash-ref u 'y base-y))
      (when (and (not (eq? (unit-type-sym u) 'ravager))
                 (<= (dist2d ffx ffy ux uy) SC2-FORCE-FIELD-STEPBACK-RADIUS))
        (emit! (list 'kite (hash-ref u 'id 101) base-x base-y)))))

  ;; ---------------------------------------------------------------------------
  ;; Adversarial Countermeasure #5b: Anti-Kite Defensive Leash (16.0 tiles)
  ;; ---------------------------------------------------------------------------
  (define lone-kiter?
    (and (= (length enemy-units) 1)
         (memq (unit-type-sym (car enemy-units))
               '(reaper hellion adept stalker oracle phoenix mutalisk))
         (< (length combat-units) SC2-LONE-KITER-MAX-DEFENDERS)))
  (when lone-kiter?
    (for ([u (in-list combat-units)])
      (when (and (memq (unit-type-sym u) '(zealot zergling roach immortal))
                 (> (dist2d base-x base-y (hash-ref u 'x base-x) (hash-ref u 'y base-y))
                    SC2-ANTI-KITE-LEASH-RADIUS))
        (emit! (list 'kite (hash-ref u 'id 101) nat-x nat-y)))))

  ;; ---------------------------------------------------------------------------
  ;; Active Combat Spells & Engagement Micro
  ;; ---------------------------------------------------------------------------
  (when (not (null? enemy-units))
    ;; Queen transfusion on wounded ally
    (define queens (filter (lambda (u) (eq? (unit-type-sym u) 'queen)) ally-units))
    (define wounded-ally
      (findf (lambda (u) (< (hash-ref u 'hp 100) (hash-ref u 'max-hp 150))) combat-units))
    (for ([q (in-list queens)])
      (when (and wounded-ally (>= (hash-ref q 'energy SC2-QUEEN-TRANSFUSION-ENERGY) SC2-QUEEN-TRANSFUSION-ENERGY))
        (emit! (list 'cast-spell (hash-ref q 'id 120) 'transfusion (hash-ref wounded-ally 'id 141)))))

    (for ([u (in-list combat-units)])
      (define ut (unit-type-sym u))
      (define uid (hash-ref u 'id 101))
      (define ux (hash-ref u 'x base-x))
      (define uy (hash-ref u 'y base-y))
      (define u-hp (hash-ref u 'hp 100))
      (define target-enemy (select-target-enemy-for-unit ux uy enemy-units))
      (define eid (hash-ref target-enemy 'id 9001))
      (define ex (hash-ref target-enemy 'x nat-x))
      (define ey (hash-ref target-enemy 'y nat-y))
      (case ut
        [(ravager)
         (emit! (list 'cast-spell uid 'corrosive-bile ex ey))
         (emit! (list 'attack-unit uid eid))]
        [(lurker widow-mine)
         (emit! (list 'cast-spell uid 'burrow eid))
         (emit! (list 'attack-unit uid eid))]
        [(sentry)
         (if (>= (hash-ref u 'energy SC2-SENTRY-FORCE-FIELD-ENERGY) SC2-SENTRY-GUARDIAN-SHIELD-ENERGY)
             (emit! (list 'cast-spell uid 'guardian-shield eid))
             (emit! (list 'cast-spell uid 'force-field
                          (safe-coord (* 0.5 (+ nat-x ex)) nat-x)
                          (safe-coord (* 0.5 (+ nat-y ey)) nat-y))))
         (emit! (list 'attack-unit uid eid))]
        [(stalker)
         (when (< u-hp SC2-STALKER-BLINK-HP-THRESH)
           (define-values (kx ky) (compute-kite-vector ux uy ex ey SC2-KITE-STEP-DISTANCE))
           (emit! (list 'cast-spell uid 'blink (safe-coord kx ux) (safe-coord ky uy))))
         (emit! (list 'attack-unit uid eid))]
        [(adept)
         (emit! (list 'cast uid 'psionic-transfer ex ey))
         (emit! (list 'attack-unit uid eid))]
        [(siege-tank)
         ;; Hysteresis: siege when enemy within SC2-SIEGE-TANK-SIEGE-RANGE; unsiege only when > SC2-SIEGE-TANK-UNSIEGE-RANGE
         (define min-enemy-dist
           (for/fold ([best +inf.0]) ([e (in-list enemy-units)])
             (min best (dist2d ux uy (hash-ref e 'x ex) (hash-ref e 'y ey)))))
         (cond
           [(and (hash-ref u 'sieged #f) (> min-enemy-dist SC2-SIEGE-TANK-UNSIEGE-RANGE))
            (emit! (list 'cast-spell uid 'unsiege-mode uid))]
           [(and (not (hash-ref u 'sieged #f)) (<= min-enemy-dist SC2-SIEGE-TANK-SIEGE-RANGE))
            (emit! (list 'cast-spell uid 'siege-mode eid))])
         (emit! (list 'attack-unit uid eid))]
        [(ghost)
         (emit! (list 'cast-spell uid 'emp-round eid))
         (emit! (list 'cast-spell uid 'snipe eid))
         (emit! (list 'attack-unit uid eid))]
        [(marine marauder)
         (when (>= u-hp SC2-MARINE-STIM-MIN-HP)
           (emit! (list 'cast-spell uid 'stimpack eid)))
         (emit! (list 'attack-unit uid eid))]
        [(mutalisk)
         (if (< u-hp SC2-MUTALISK-KITE-HP-THRESH)
             (let-values ([(kx ky) (compute-kite-vector ux uy ex ey SC2-KITE-STEP-DISTANCE)])
               (emit! (list 'kite uid (safe-coord kx ux) (safe-coord ky uy))))
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
        (safe-coord (/ (for/sum ([u (in-list combat-units)])
                         (safe-finite-real (hash-ref u 'x nat-x) nat-x))
                       (max 1 (length combat-units)))
                    nat-x)))
  (define army-cy
    (if (null? combat-units)
        nat-y
        (safe-coord (/ (for/sum ([u (in-list combat-units)])
                         (safe-finite-real (hash-ref u 'y nat-y) nat-y))
                       (max 1 (length combat-units)))
                    nat-y)))
  (define target-ex
    (if (null? enemy-units)
        enemy-x
        (safe-coord (/ (for/sum ([e (in-list enemy-units)])
                         (safe-finite-real (hash-ref e 'x enemy-x) enemy-x))
                       (max 1 (length enemy-units)))
                    enemy-x)))
  (define target-ey
    (if (null? enemy-units)
        enemy-y
        (safe-coord (/ (for/sum ([e (in-list enemy-units)])
                         (safe-finite-real (hash-ref e 'y enemy-y) enemy-y))
                       (max 1 (length enemy-units)))
                    enemy-y)))

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

  ;; Pre-Split 3-Wing Formation & Concave Arc Formation (6.0 tiles wing-spread, 10.0 tiles arc radius)
  (when (or (not (null? enemy-units))
            (hash-ref obs 'pre-split-engage #f)
            (hash-ref obs 'form-concave #f))
    (define dx (- target-ex army-cx))
    (define dy (- target-ey army-cy))
    (define d (max 1.0 (sqrt (+ (* dx dx) (* dy dy)))))
    (define nx (/ (- dy) d))
    (define ny (/ dx d))
    (define wing-spread 6.0)
    (define mid-x (safe-coord (+ army-cx (* 0.5 dx)) army-cx))
    (define mid-y (safe-coord (+ army-cy (* 0.5 dy)) army-cy))
    (define left-x (safe-coord (+ mid-x (* wing-spread nx)) mid-x))
    (define left-y (safe-coord (+ mid-y (* wing-spread ny)) mid-y))
    (define right-x (safe-coord (- mid-x (* wing-spread nx)) mid-x))
    (define right-y (safe-coord (- mid-y (* wing-spread ny)) mid-y))
    (emit! (list 'pre-split-wings left-x left-y mid-x mid-y right-x right-y))
    (emit! (list 'form-concave-arc target-ex target-ey 10 120)))

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
     #:enemy-exp-x enemy-exp-x
     #:enemy-exp-y enemy-exp-y))
  (set-mirror-mind-state-last-reachability-model! mm-rt reach-m)
  (define sp-maneuver
    (enemy-army-reachability-model-recommended-spatial-maneuver reach-m))
  (define-values (sp-tx sp-ty)
    (case sp-maneuver
      [(backstab-undefended-enemy-expansion)
       (values enemy-exp-x enemy-exp-y)]
      [(surround-and-crush-isolated-enemy-cluster)
       (values target-ex target-ey)]
      [(pre-rotate-intercept-incoming-threat)
       (values nat-x nat-y)]
      [(safe-to-expand-enemy-pinned-far)
       (values third-x third-y)]
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
  (define nat-x (hash-ref obs 'natural-x 45.0))
  (define nat-y (hash-ref obs 'natural-y 45.0))

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
                                      (hash-ref (car enemy-units) 'x nat-x)
                                      (hash-ref (car enemy-units) 'y nat-y))))
       (define tx (safe-coord (hash-ref (car enemy-units) 'x nat-x) nat-x))
       (define ty (safe-coord (hash-ref (car enemy-units) 'y nat-y) nat-y))
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
  (define base-x (hash-ref obs 'base-x 32.5))
  (define base-y (hash-ref obs 'base-y 32.5))
  (define nat-x (hash-ref obs 'natural-x 45.0))
  (define nat-y (hash-ref obs 'natural-y 45.0))
  (define enemy-x (hash-ref obs 'enemy-x 160.5))
  (define enemy-y (hash-ref obs 'enemy-y 160.5))
  (define enemy-exp-x (hash-ref obs 'enemy-expand-x 148.0))
  (define enemy-exp-y (hash-ref obs 'enemy-expand-y 148.0))
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
           (values (safe-coord (* 0.5 (+ nat-x enemy-x)) nat-x)
                   (safe-coord (* 0.5 (+ nat-y enemy-y)) nat-y)))]
      [(harass-or-blocker-zone)
       (values enemy-exp-x enemy-exp-y)]
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
  (define rplan
    (evaluate-random-stealth-harass-plan
     (live-bot-runtime-configured-race rt)
     (live-bot-runtime-actual-race rt)
     (hash-ref obs 'frame 0)))

  (define telemetry
    (hash 'posture (live-bot-runtime-posture rt)
          'actual-race (live-bot-runtime-actual-race rt)
          'random-stealth-active? (random-stealth-harass-plan-active? rplan)
          'random-stealth-doctrine (random-stealth-harass-plan-doctrine-name rplan)
          'random-stealth-phase (random-stealth-harass-plan-stealth-phase rplan)
          'random-deny-scout-choke? (random-stealth-harass-plan-deny-scout-choke? rplan)
          'random-perimeter-flight? (random-stealth-harass-plan-perimeter-flight-path? rplan)
          'random-fake-normal-front? (random-stealth-harass-plan-fake-normal-front? rplan)
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
      32.5 32.5)]
    [(list id type x y hp)
     (sanitize-unit-record
      (hash 'id id 'type type 'x x 'y y 'hp hp)
      32.5 32.5)]
    [(? hash? h) (sanitize-unit-record h 32.5 32.5)]
    [_ (hash 'id 101 'type 'zergling 'x 32.5 'y 32.5 'hp 35)]))

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
      32.5 32.5)]
    [(list id type x y hp)
     (sanitize-bldg-record
      (hash 'id id 'type type 'x x 'y y 'hp hp)
      32.5 32.5)]
    [(? hash? h) (sanitize-bldg-record h 32.5 32.5)]
    [_ (hash 'id 201 'type 'hatchery 'x 32.5 'y 32.5 'hp 1500)]))

(define (parse-effect-tuple tup)
  (match tup
    [(list type x y)
     (sanitize-effect-record (hash 'type type 'x x 'y y))]
    [(? hash? h) (sanitize-effect-record h)]
    [_ (hash 'type 'none 'x 0.0 'y 0.0)]))

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
               (hash-set! h 'base-x (safe-coord (first v) 32.5))
               (hash-set! h 'base-y (safe-coord (second v) 32.5)))]
            [(natural-pos)
             (when (and (list? v) (>= (length v) 2))
               (hash-set! h 'natural-x (safe-coord (first v) 45.0))
               (hash-set! h 'natural-y (safe-coord (second v) 45.0)))]
            [(third-pos)
             (when (and (list? v) (>= (length v) 2))
               (hash-set! h 'third-x (safe-coord (first v) 60.5))
               (hash-set! h 'third-y (safe-coord (second v) 40.5)))]
            [(enemy-base)
             (when (and (list? v) (>= (length v) 2))
               (hash-set! h 'enemy-x (safe-coord (first v) 160.5))
               (hash-set! h 'enemy-y (safe-coord (second v) 160.5)))]
            [(enemy-expand-pos)
             (when (and (list? v) (>= (length v) 2))
               (hash-set! h 'enemy-expand-x (safe-coord (first v) 148.0))
               (hash-set! h 'enemy-expand-y (safe-coord (second v) 148.0)))]
            [(researched-upgrades)
             (hash-set! h 'researched-upgrades (if (list? v) (filter symbol? v) '()))]
            [(pending-upgrades)
             (hash-set! h 'pending-upgrades (if (list? v) (filter symbol? v) '()))]
            [(depleting-bases)
             (hash-set! h 'depleting-bases (safe-nonneg-int v 0))]
            [(mineral-harvesters)
             (hash-set! h 'mineral-harvesters (safe-nonneg-int v 0))]
            [(ideal-mineral-harvesters)
             (hash-set! h 'ideal-mineral-harvesters (safe-nonneg-int v 0))]
            [(gas-harvesters)
             (hash-set! h 'gas-harvesters (safe-nonneg-int v 0))]
            [(ideal-gas-harvesters)
             (hash-set! h 'ideal-gas-harvesters (safe-nonneg-int v 0))]
            [(busy-facilities)
             (hash-set! h 'busy-facilities (safe-nonneg-int v 0))]
            [(busy-townhalls)
             (hash-set! h 'busy-townhalls (safe-nonneg-int v 0))]
            [(army-supply)
             (hash-set! h 'army-supply (safe-nonneg-int v 0))]
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
