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
         "mirror-mind-predictor.rkt"
         "priority-macro-brain.rkt")

(provide
 WORKER-AND-NONCOMBAT-SYMS
 PRO-CHRONO-11-STRUCTURES
 (struct-out live-bot-runtime)
 (struct-out random-stealth-harass-plan)
 (struct-out sc2-tech-node)
 (struct-out plan-goal-node)
 (struct-out dynamic-macro-plan)
 (struct-out macro-world-state)
 (struct-out macro-brain-decision)
 SC2-TECH-GRAPH
 lookup-sc2-tech-node
 find-all-broken-tech-dependencies
 translate-goal-to-next-action
 synthesize-dynamic-macro-plan
 macro-brain-decision-dynamic-plan
 make-macro-world-state
 obs-hash->macro-world-state
 step-priority-macro-brain
 macro-brain-can-spend?
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
 sanitize-stale-target-actions
 filter-rush-threat-enemies
 select-target-enemy-for-unit
 compute-next-posture)

;; Per-runtime weak map caching last-known `(cons x y)` coordinates for enemy UnitTags
;; so stale/dead/snapshot target tags (`ActionResult=207 Error_CantTargetThatUnit`) downgrade
;; cleanly to `(attack-pos uid last-x last-y)` instead of failing in SC2!
(define WEAK-RT-ENEMY-POS-CACHE (make-weak-hasheq))

(define (rt-enemy-pos-cache rt)
  (or (hash-ref WEAK-RT-ENEMY-POS-CACHE rt #f)
      (let ([ht (make-hasheqv)])
        (hash-set! WEAK-RT-ENEMY-POS-CACHE rt ht)
        ht)))

(define (sanitize-stale-target-actions actions obs #:pos-cache [pos-cache #f])
  (define sanitized-obs (if (hash? obs) obs (hash)))
  (define fallback-ex (exact->inexact (hash-ref sanitized-obs 'enemy-x 140.0)))
  (define fallback-ey (exact->inexact (hash-ref sanitized-obs 'enemy-y 140.0)))
  (define enemy-units (filter hash? (hash-ref sanitized-obs 'enemy-units '())))
  (define enemy-bldgs (filter hash? (hash-ref sanitized-obs 'enemy-buildings '())))
  (define all-enemies (append enemy-units enemy-bldgs))
  (define valid-enemy-tags (mutable-seteqv))
  (define step-pos-map (make-hasheqv))
  (for ([e (in-list all-enemies)])
    (define eid (hash-ref e 'id 0))
    (when (and (exact-integer? eid) (> eid 0))
      (define ex (hash-ref e 'x #f))
      (define ey (hash-ref e 'y #f))
      (when (and (real? ex) (real? ey))
        (define pt (cons (exact->inexact ex) (exact->inexact ey)))
        (hash-set! step-pos-map eid pt)
        (when (hash? pos-cache)
          (hash-set! pos-cache eid pt)))
      (define disp-type (hash-ref e 'display-type 1))
      (define snapshot? (eq? (hash-ref e 'snapshot? #f) #t))
      (define ehp (hash-ref e 'hp 1))
      (when (and (real? ehp) (> ehp 0) (not snapshot?) (= disp-type 1))
        (set-add! valid-enemy-tags eid))))
  (define (resolve-last-known-pos tid [def-x fallback-ex] [def-y fallback-ey])
    (define pt (or (hash-ref step-pos-map tid #f)
                   (and (hash? pos-cache) (hash-ref pos-cache tid #f))))
    (if (pair? pt)
        (values (car pt) (cdr pt))
        (values def-x def-y)))
  (for/list ([act (in-list (if (list? actions) actions '()))])
    (match act
      [(list (or 'attack 'attack-unit) uid (? exact-integer? tid))
       (if (set-member? valid-enemy-tags tid)
           act
           (let-values ([(lx ly) (resolve-last-known-pos tid)])
             (list 'attack-pos uid lx ly)))]
      [(list 'focus-fire uid (? exact-integer? tid) rest ...)
       (if (set-member? valid-enemy-tags tid)
           act
           (let-values ([(lx ly)
                         (if (and (>= (length rest) 2) (real? (first rest)) (real? (second rest)))
                             (resolve-last-known-pos tid
                                                     (exact->inexact (first rest))
                                                     (exact->inexact (second rest)))
                             (resolve-last-known-pos tid))])
             (list 'attack-pos uid lx ly)))]
      [(list 'clear-gas-steal (? exact-integer? tid) (? real? gx) (? real? gy))
       (if (set-member? valid-enemy-tags tid)
           act
           (list 'clear-gas-steal 0 (exact->inexact gx) (exact->inexact gy)))]
      [_ act])))

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
   last-telemetry
   order-ledger
   tactical-brain)
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
   (hash)
   (make-order-ledger)
   (make-tactical-mirror-brain)))

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
     (define base-h (if (immutable? u) u (for/hash ([(k v) (in-hash u)]) (values k v))))
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
    [(and (immutable? obs) (eq? (hash-ref obs '__sanitized? #f) #t)) obs]
    [else
     (define base-h (if (immutable? obs) obs (for/hash ([(k v) (in-hash obs)]) (values k v))))
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
                  'nuke-alert nuke-alert
                  '__sanitized? #t))
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
    [(and (eq? cfg-race 'Random)
          (or (eq? act-race 'Random)
              (not (hash-has-key? raw-obs 'mineral-harvesters))))
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
  (define (unit-stasis-frozen? u)
    (define b (hash-ref u 'buffs '()))
    (and (list? b)
         (or (memq 'oracle-stasis-trap-target b)
             (memq 'stasis-ward-target b))))
  (define raw-workers
    (filter (lambda (u) (memq (unit-type-sym u) '(drone probe scv))) ally-units))
  (define workers
    (filter (lambda (w) (not (unit-stasis-frozen? w))) raw-workers))
  (define frozen-worker-count
    (max (count unit-stasis-frozen? raw-workers)
         (safe-nonneg-int (hash-ref obs 'stasis-frozen-worker-count 0) 0)))
  (define active-worker-count
    (max 0 (- (length raw-workers) frozen-worker-count)))
  (define pending-workers (hash-ref obs 'pending-workers 0))
  (define total-workers (+ active-worker-count pending-workers))
  (when (> frozen-worker-count 0)
    (emit! (list 'stasis-worker-stoppage-compensation frozen-worker-count)))

  ;; ---------------------------------------------------------------------------
  ;; Pro Signature Mechanic #1: Tactical Building Save-Cancel (<18% HP-pct under attack)
  ;; ---------------------------------------------------------------------------
  (for ([b (in-list ally-bldgs)])
    (define prog (hash-ref b 'build-progress (if (hash-ref b 'under-construction #f) 0.5 1.0)))
    (define hp (hash-ref b 'hp 100))
    (define max-hp (hash-ref b 'max-hp 500))
    (define hp-pct (hash-ref b 'hp-pct (/ (exact->inexact hp) (max 1 max-hp))))
    (define bx (hash-ref b 'x base-x))
    (define by (hash-ref b 'y base-y))
    (define enemy-near?
      (or (eq? (hash-ref b 'under-attack #f) #t)
          (ormap (lambda (e)
                   (define et (unit-type-sym e))
                   (and (sc2-enemy-unit-targetable? et)
                        (not (memq et NON-COMBAT-AND-SCOUT-ENEMY-SYMS))
                        (<= (dist2d bx by (hash-ref e 'x 9999) (hash-ref e 'y 9999))
                            SC2-BLDG-UNDER-ATTACK-RADIUS)))
                 enemy-units)))
    (when (and (< prog SC2-BUILD-COMPLETE-PROGRESS)
               (< hp-pct SC2-DYING-BLDG-CANCEL-HP-PCT)
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
                   (or (hash-ref obs 'under-cheese-rush #f)
                       (< frame SC2-EARLY-CHEESE-MAX-FRAME))))
            (append ground-enemy-units-for-cheese enemy-bldgs)))
  (define under-early-cheese?
    (and (not (null? proxy-or-cheese-enemies))
         (or (hash-ref obs 'under-cheese-rush #f)
             (ormap (lambda (e)
                      (and (<= (dist2d base-x base-y (hash-ref e 'x 9999) (hash-ref e 'y 9999)) cheese-dist-thresh)
                           (memq (unit-type-sym e) '(photon-cannon pylon bunker spine-crawler barracks))))
                    enemy-bldgs)
             (>= (length proxy-or-cheese-enemies) 2))))
  (when (and under-early-cheese?
             (not (null? workers))
             (or (not (hash-has-key? raw-obs 'mineral-harvesters))
                 (and (< frame 2500)
                      (<= (length (filter combat-unit-record? ally-units)) 2)
                      (refractory-allow-action?! cd-tracker 'early-cheese-worker-pull frame 112))))
    (define healthy-workers
      (filter (lambda (w) (>= (hash-ref w 'hp SC2-DRONE-MAX-HP) SC2-HEALTHY-WORKER-PULL-MIN-HP)) workers))
    (define pull-ids
      (map (lambda (w) (hash-ref w 'id 10))
           (take healthy-workers (min SC2-MAX-WORKER-PULL-COUNT (length healthy-workers)))))
    (define threat (car proxy-or-cheese-enemies))
    (define tx (hash-ref threat 'x (safe-coord (+ base-x 5.0))))
    (define ty (hash-ref threat 'y (safe-coord (+ base-y 5.0))))
    (define drill-patch-id (hash-ref obs 'mineral-patch-id SC2-SYNTHETIC-MINERAL-PATCH-ID))
    (unless (null? pull-ids)
      (emit! (list 'pull-workers-attack pull-ids tx ty))
      (emit! (list 'worker-drill-stack-attack
                   pull-ids
                   drill-patch-id
                   (hash-ref threat 'id 0)
                   (exact-round tx)
                   (exact-round ty))))
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
  ;; Preemptive Anti-Stasis Worker Evacuation & Counter-Enemy Worker Drill
  ;; ---------------------------------------------------------------------------
  (define stasis-threats
    (filter (lambda (e)
              (and (memq (unit-type-sym e) '(oracle-stasis-trap stasis-ward oracle))
                   (let ([ex (hash-ref e 'x 9999)]
                         [ey (hash-ref e 'y 9999)])
                     (or (<= (dist2d base-x base-y ex ey) 7.5)
                         (ormap (lambda (w)
                                  (<= (dist2d (hash-ref w 'x base-x) (hash-ref w 'y base-y) ex ey) 7.5))
                                workers)))))
            (append enemy-units enemy-bldgs)))
  (when (and (not (null? stasis-threats)) (not (null? workers)))
    (define st (car stasis-threats))
    (define stx (hash-ref st 'x base-x))
    (define sty (hash-ref st 'y base-y))
    (define evac-workers
      (filter (lambda (w)
                (<= (dist2d stx sty (hash-ref w 'x base-x) (hash-ref w 'y base-y)) 6.5))
              workers))
    (when (not (null? evac-workers))
      (define ref-x (if (> (dist2d stx sty base-x base-y) 1.0) base-x nat-x))
      (define ref-y (if (> (dist2d stx sty base-x base-y) 1.0) base-y nat-y))
      (define dx (- ref-x stx))
      (define dy (- ref-y sty))
      (define d (max 1.0 (sqrt (+ (* dx dx) (* dy dy)))))
      (define safe-x (safe-coord (+ stx (* 8.5 (/ dx d))) base-x))
      (define safe-y (safe-coord (+ sty (* 8.5 (/ dy d))) base-y))
      (define evac-ids (map (lambda (w) (hash-ref w 'id 10)) evac-workers))
      (emit! (list 'evacuate-workers-from-stasis-ward evac-ids safe-x safe-y))
      (for ([wid (in-list evac-ids)])
        (emit! (list 'mineral-walk wid safe-x safe-y)))))

  (define enemy-workers-near-base
    (filter (lambda (e)
              (and (memq (unit-type-sym e) '(drone probe scv))
                   (let ([ex (hash-ref e 'x 9999)]
                         [ey (hash-ref e 'y 9999)])
                     (or (<= (dist2d base-x base-y ex ey) 20.0)
                         (ormap (lambda (u)
                                  (<= (dist2d (hash-ref u 'x base-x) (hash-ref u 'y base-y) ex ey) 10.0))
                                ally-units)))))
            enemy-units))
  (define stacked-enemy-workers
    (if (< (length enemy-workers-near-base) 4)
        '()
        (let ([anchor
               (findf (lambda (ew)
                        (define ex (hash-ref ew 'x base-x))
                        (define ey (hash-ref ew 'y base-y))
                        (>= (count (lambda (o)
                                     (<= (dist2d ex ey (hash-ref o 'x ex) (hash-ref o 'y ey)) 1.8))
                                   enemy-workers-near-base)
                            4))
                      enemy-workers-near-base)])
          (if anchor
              (let ([ax (hash-ref anchor 'x base-x)]
                    [ay (hash-ref anchor 'y base-y)])
                (filter (lambda (o)
                          (<= (dist2d ax ay (hash-ref o 'x ax) (hash-ref o 'y ay)) 1.8))
                        enemy-workers-near-base))
              '()))))
  (when (>= (length stacked-enemy-workers) 4)
    (define ew0 (car stacked-enemy-workers))
    (define ewx (hash-ref ew0 'x base-x))
    (define ewy (hash-ref ew0 'y base-y))
    (define dx (- base-x ewx))
    (define dy (- base-y ewy))
    (define d (max 1.0 (sqrt (+ (* dx dx) (* dy dy)))))
    (define perp-x (safe-coord (+ ewx (* 4.0 (- (/ dy d)))) base-x))
    (define perp-y (safe-coord (+ ewy (* 4.0 (/ dx d))) base-y))
    (emit! (list 'counter-enemy-worker-drill (length stacked-enemy-workers) perp-x perp-y))
    (for ([w (in-list workers)]
          #:when (<= (dist2d ewx ewy (hash-ref w 'x base-x) (hash-ref w 'y base-y)) 8.0))
      (emit! (list 'move (hash-ref w 'id 10) perp-x perp-y))))

  ;; ---------------------------------------------------------------------------
  ;; Coupled Macro Governor, Adaptive Build/Tech Planner & Guns-vs-Butter PPF
  ;; ---------------------------------------------------------------------------
  (define townhalls
    (filter (lambda (b)
              (memq (unit-type-sym b)
                    '(hatchery lair hive nexus command-center orbital-command planetary-fortress)))
            ally-bldgs))
  (define active-bases (max 1 (length townhalls)))

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
        (and (<= (length townhalls) 1)
             (< frame 2500)
             (not (null? natural-blockers)))))
  (when (and natural-blocked?
             (or (hash-ref obs 'natural-blocked #f)
                 (refractory-allow-action?! cd-tracker (list 'blocked-nat-expand race) frame SC2-EXPANSION-COOLDOWN-FRAMES)))
    (emit! (list 'clear-expansion-block nat-x nat-y))
    (if (eq? race 'Terran)
        (when (>= minerals (sc2-min-cost 'command-center))
          (emit! (list 'build 'command-center (safe-coord (+ base-x 4.0)) base-y))
          (set! minerals (max 0 (- minerals (sc2-min-cost 'command-center)))))
        (when (>= minerals (sc2-min-cost 'hatchery))
          (emit! (list 'expand third-x third-y))
          (set! minerals (max 0 (- minerals (sc2-race-townhall-min-cost race)))))))
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
     #:workers active-worker-count
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
  (for ([w (in-list workers)]
        #:when (not (hash-ref w 'has-build-order? #f)))
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

  ;; Standard Gas & Mineral Harvesting (governed by Guns-vs-Butter Gas Allocation
  ;; + Pro Gas-Float Harvester Rebalancing when gas >= 350 and minerals < 180)
  ;; Builder & Scout Hygiene (PV8): never emit harvest-mineral / harvest-gas on a worker
  ;; that has an active build order (`has-build-order?`) or is the designated scout/harasser!
  (define prev-tel-early
    (let ([t (live-bot-runtime-last-telemetry rt)])
      (if (hash? t) t (hash))))
  (define enemy-exp-x (hash-ref obs 'enemy-expand-x (safe-coord (* 0.85 enemy-x) 148.0)))
  (define enemy-exp-y (hash-ref obs 'enemy-expand-y (safe-coord (* 0.85 enemy-y) 148.0)))
  (define corridor-mid-x (safe-coord (* 0.5 (+ nat-x enemy-exp-x)) 96.0))
  (define corridor-mid-y (safe-coord (* 0.5 (+ nat-y enemy-exp-y)) 96.0))
  (define live-obs-harvesters? (hash-has-key? raw-obs 'mineral-harvesters))

  ;; Designate 1 persistent opening Scout / Mineral-Harasser worker (at supply >= 14 or enable-worker-harass)
  (define want-worker-scout?
    (and (not (null? workers))
         (or (hash-ref obs 'enable-worker-harass #f)
             (and (>= supply-used 14)
                  (< frame 3600)
                  (not under-early-cheese?)
                  (>= (length workers) (if live-obs-harvesters? 13 2))))))
  (define prev-scout-wid (hash-ref prev-tel-early 'scout-worker-id #f))
  (define non-building-workers
    (filter (lambda (w) (not (hash-ref w 'has-build-order? #f))) workers))
  (define scout-worker
    (and want-worker-scout?
         (not (null? non-building-workers))
         (or (and prev-scout-wid
                  (findf (lambda (w) (equal? (hash-ref w 'id -1) prev-scout-wid))
                         non-building-workers))
             (last non-building-workers))))
  (define scout-worker-id (and scout-worker (hash-ref scout-worker 'id #f)))
  (define harvest-eligible-workers
    (filter (lambda (w)
              (and (not (hash-ref w 'has-build-order? #f))
                   (not (and scout-worker-id (equal? (hash-ref w 'id -1) scout-worker-id)))))
            workers))
  (define harvest-workers-pool
    (if (not (null? harvest-eligible-workers)) harvest-eligible-workers non-building-workers))

  (define gas-float-starved?
    (and (>= gas SC2-GAS-FLOAT-REBALANCE-THRESH)
         (< minerals SC2-MINERAL-STARVED-REBALANCE-THRESH)))
  (define gas-bldg
    (findf (lambda (b) (memq (unit-type-sym b) '(extractor assimilator refinery)))
           ally-bldgs))
  (when (and gas-bldg
             (not (null? harvest-workers-pool))
             (not gas-float-starved?)
             (> (gas-worker-allocation-desired-gas-workers gas-alloc) 0))
    (emit! (list 'harvest-gas (hash-ref (car harvest-workers-pool) 'id 10) (hash-ref gas-bldg 'id 103))))
  (when (not (null? harvest-workers-pool))
    (define patch-id (hash-ref obs 'mineral-patch-id SC2-SYNTHETIC-MINERAL-PATCH-ID))
    (when gas-float-starved?
      (define pull-workers
        (take harvest-workers-pool
              (min (if (>= gas SC2-GAS-FLOAT-CRITICAL-THRESH) 4 2)
                   (length harvest-workers-pool))))
      (emit! (list 'rebalance-gas-to-minerals
                   (map (lambda (w) (hash-ref w 'id 10)) pull-workers)
                   patch-id)))
    ;; In synthetic tests (no live mineral-harvesters field), emit harvest-mineral for (car harvest-workers-pool);
    ;; in live SC2 games, never spam harvest-mineral on busy/building workers every frame!
    (unless live-obs-harvesters?
      (emit! (list 'harvest-mineral (hash-ref (car harvest-workers-pool) 'id 10) patch-id)))
    (define idle-return-workers
      (filter (lambda (w)
                (define wx (hash-ref w 'x base-x))
                (define wy (hash-ref w 'y base-y))
                (and (hash-has-key? w 'orders)
                     (let ([ords (hash-ref w 'orders '())])
                       (or (null? ords) (equal? ords '(idle))))
                     (not (ormap (lambda (e)
                                   (<= (dist2d wx wy (hash-ref e 'x 9999) (hash-ref e 'y 9999)) 6.5))
                                 (append enemy-units enemy-bldgs)))))
              harvest-workers-pool))
    (when (not (null? idle-return-workers))
      (define idle-ids (map (lambda (w) (hash-ref w 'id 10)) idle-return-workers))
      (emit! (list 'return-workers-to-gather idle-ids))
      (for ([wid (in-list idle-ids)]
            #:unless (and (not live-obs-harvesters?)
                          (equal? wid (hash-ref (car harvest-workers-pool) 'id 10))))
        (emit! (list 'harvest-mineral wid patch-id)))))

  ;; ---------------------------------------------------------------------------
  ;; Opening Probe / SCV / Drone Scout & Pro-Style Mineral-Patch Harassment
  ;; ---------------------------------------------------------------------------
  (when (and (hash-ref obs 'enable-worker-harass #f) (not (null? workers)))
    (emit! (list 'worker-harass (or scout-worker-id (hash-ref (last workers) 'id 10)) enemy-x enemy-y)))
  (when scout-worker
    (define sw-id (hash-ref scout-worker 'id 10))
    (define sw-x (hash-ref scout-worker 'x base-x))
    (define sw-y (hash-ref scout-worker 'y base-y))
    ;; Route through enemy natural expansion first to check/block expansion, then into enemy main mineral line
    (define wp-x (if (and (> (dist2d sw-x sw-y enemy-exp-x enemy-exp-y) 9.0)
                          (> (dist2d sw-x sw-y enemy-x enemy-y) 20.0)
                          (< (modulo frame 672) 336))
                     enemy-exp-x
                     enemy-x))
    (define wp-y (if (and (> (dist2d sw-x sw-y enemy-exp-x enemy-exp-y) 9.0)
                          (> (dist2d sw-x sw-y enemy-x enemy-y) 20.0)
                          (< (modulo frame 672) 336))
                     enemy-exp-y
                     enemy-y))
    (emit! (list 'worker-scout sw-id wp-x wp-y))
    (emit! (list 'mineral-harass sw-id enemy-x enemy-y enemy-exp-x enemy-exp-y)))

  ;; ---------------------------------------------------------------------------
  ;; Opening Overlord Scouting (Zerg): Overlord #1 -> Enemy Natural, Overlord #2 -> Attack Corridor
  ;; ---------------------------------------------------------------------------
  (when (eq? race 'Zerg)
    (define safe-overlords
      (filter (lambda (u)
                (and (eq? (unit-type-sym u) 'overlord)
                     (not (hash-ref u 'under-attack #f))
                     (>= (hash-ref u 'hp SC2-OVERLORD-MAX-HP) SC2-OVERLORD-DAMAGED-HP-THRESH)
                     (not (ormap (lambda (e)
                                   (and (sc2-unit-can-attack-air? (unit-type-sym e))
                                        (<= (dist2d (hash-ref u 'x base-x) (hash-ref u 'y base-y)
                                                    (hash-ref e 'x 9999) (hash-ref e 'y 9999))
                                            11.0)))
                                 enemy-units))))
              ally-units))
    (define rplan-now
      (evaluate-random-stealth-harass-plan (live-bot-runtime-configured-race rt) race frame))
    (define perim-flight?
      (and (random-stealth-harass-plan-perimeter-flight-path? rplan-now) (< frame 1200)))
    (when (pair? safe-overlords)
      (define ov1 (car safe-overlords))
      (define ov1-tx (if perim-flight? enemy-exp-x enemy-exp-x))
      (define ov1-ty (if perim-flight? base-y enemy-exp-y))
      (emit! (list 'overlord-scout (hash-ref ov1 'id 102) ov1-tx ov1-ty)))
    (when (>= (length safe-overlords) 2)
      (define ov2 (cadr safe-overlords))
      (emit! (list 'overlord-scout (hash-ref ov2 'id 102) corridor-mid-x corridor-mid-y))))

  ;; Mined-out / Proactive 90s Pre-Depleting base detection (Scenario 3): auto-expand & transfer workers
  (define pre-depleting-bases (safe-nonneg-int (hash-ref obs 'pre-depleting-bases depleting-bases) depleting-bases))
  (when (and (or (hash-ref obs 'mined-out #f)
                 (and (> (max depleting-bases pre-depleting-bases) 0)
                      (>= minerals (sc2-race-townhall-min-cost race))))
             (not natural-blocked?)
             (not under-early-cheese?)
             (refractory-allow-action?! cd-tracker (list 'auto-expand race) frame SC2-EXPANSION-COOLDOWN-FRAMES))
    (emit! (list 'expand (if (>= active-bases 2) third-x nat-x)
                         (if (>= active-bases 2) third-y nat-y)))
    (set! minerals (max 0 (- minerals (sc2-race-townhall-min-cost race)))))

  ;; ---------------------------------------------------------------------------
  ;; In-Progress Order Ledger Reconciliation & Building Control Groups (4, 5, 6, 7, 9)
  ;; ---------------------------------------------------------------------------
  (define oledger (live-bot-runtime-order-ledger rt))
  (order-ledger-reconcile-observation! oledger obs)
  (define cortex (live-bot-runtime-cortex rt))
  (define cg-sync-actions
    (cortex-sync-control-groups! cortex ally-units ally-bldgs base-x base-y))
  (for ([cga (in-list cg-sync-actions)])
    (emit! cga))
  (define cg4-cap (cortex-production-group-capacity cortex ally-bldgs 4))
  (define cg5-cap (cortex-production-group-capacity cortex ally-bldgs 5))
  (define cg6-cap (cortex-production-group-capacity cortex ally-bldgs 6))
  (define cg7-cap (cortex-production-group-capacity cortex ally-bldgs 7))
  (define recalled-groups (mutable-set))
  (define (recall-building-group! g)
    (when (and (not (set-member? recalled-groups g))
               (not (null? (hash-ref (case g
                                       [(4) cg4-cap]
                                       [(5) cg5-cap]
                                       [(6) cg6-cap]
                                       [(7) cg7-cap]
                                       [else (hash)])
                                     'ready-tags '())))
               (not (in-camera-viewport? (human-cortex-cam-x cortex)
                                         (human-cortex-cam-y cortex)
                                         base-x base-y)))
      (set-add! recalled-groups g)
      (emit! (list 'control-group-recall g))))

  ;; ---------------------------------------------------------------------------
  ;; Zero-Supply-Block & Supply-At-Risk Preemption (Scenario 1: 8.0 tiles Overlord danger)
  ;; Only enemies capable of attacking AIR (`sc2-unit-can-attack-air?`) or active attack
  ;; threaten Overlords — ground-only Zerglings/Zealots/Roaches/Workers never trigger Overlord spam!
  ;; ---------------------------------------------------------------------------
  (define any-enemy-can-attack-air?
    (or (null? enemy-units)
        (ormap (lambda (e) (sc2-unit-can-attack-air? (unit-type-sym e))) enemy-units)))
  (define threatened-overlords
    (filter (lambda (u)
              (and (eq? (unit-type-sym u) 'overlord)
                   (or (hash-ref u 'under-attack #f)
                       (and (< (hash-ref u 'hp SC2-OVERLORD-MAX-HP) SC2-OVERLORD-DAMAGED-HP-THRESH)
                            any-enemy-can-attack-air?)
                       (ormap (lambda (e)
                                (and (sc2-unit-can-attack-air? (unit-type-sym e))
                                     (<= (dist2d (hash-ref u 'x base-x) (hash-ref u 'y base-y)
                                                 (hash-ref e 'x 9999) (hash-ref e 'y 9999))
                                         SC2-OVERLORD-THREAT-RADIUS)))
                              enemy-units))))
            ally-units))
  (for ([ov (in-list threatened-overlords)])
    (emit! (list 'kite (hash-ref ov 'id 102) base-x base-y)))

  ;; Only completed supply structures that are damaged (<65% HP+shields) or under attack
  ;; trigger supply-at-risk (prevents healthy 200-HP Pylons or under-construction Depots
  ;; from triggering infinite Pylon/Depot spam).
  (define threatened-supply-bldgs
    (filter (lambda (b)
              (and (memq (unit-type-sym b) '(supply-depot supply-depot-lowered pylon))
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

  (define supply-provider-sym
    (case race
      [(Zerg) 'overlord]
      [(Protoss) 'pylon]
      [(Terran) 'supply-depot]
      [else 'overlord]))
  (set! pending-supply
        (max pending-supply
             (order-ledger-pending-count-for-type oledger supply-provider-sym frame)))

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
  ;; Layer 1: Owned-Base Spatial Threat & Net Force-Deficit Field
  ;; Measure enemy proximity ONLY relative to bases we currently own (`base` always,
  ;; `nat` when `active-bases >= 2`, `third` when `active-bases >= 3`) using smooth
  ;; inverse-square spatial attenuation w(d) = 1 / (1 + (max(0, d - 28) / 18)^2),
  ;; and compute `live-enemy-threat-supply` as the Net Force Deficit relative to our
  ;; defending force (`live-defending-force-supply`) so a lone scout/harasser near an
  ;; unowned 3rd base never triggers a false macro crisis while real pushes immediately
  ;; preempt passive greed.
  (define (min-dist-to-owned-base ex ey)
    (min (dist2d ex ey base-x base-y)
         (if (>= active-bases 2) (dist2d ex ey nat-x nat-y) +inf.0)
         (if (>= active-bases 3) (dist2d ex ey third-x third-y) +inf.0)))
  (define (enemy-proximate-to-our-bases? e)
    (define ex (hash-ref e 'x base-x))
    (define ey (hash-ref e 'y base-y))
    (<= (min-dist-to-owned-base ex ey) 55.0))
  (define proximate-enemy-threat-supply
    (if live-obs-harvesters?
        (exact-round
         (for/sum ([e (in-list rush-threat-enemies)]
                   #:when (enemy-proximate-to-our-bases? e))
           (define ex (hash-ref e 'x base-x))
           (define ey (hash-ref e 'y base-y))
           (define d (min-dist-to-owned-base ex ey))
           (define w (/ 1.0 (+ 1.0 (expt (/ (max 0.0 (- d 28.0)) 18.0) 2))))
           (* w (unit-supply-cost (unit-type-sym e)))))
        (for/sum ([e (in-list rush-threat-enemies)])
          (unit-supply-cost (unit-type-sym e)))))
  (define distant-enemy-combat-supply
    (if live-obs-harvesters?
        (for/sum ([e (in-list rush-threat-enemies)]
                  #:when (not (enemy-proximate-to-our-bases? e)))
          (unit-supply-cost (unit-type-sym e)))
        0))

  ;; Persistent Scouted Threat Memory & Implied Production Threat (PV9):
  ;; When a forward scout / Overlord / Hallucination / Changeling / Scanner Sweep spots an enemy
  ;; army or multiple combat production facilities, retain the scouted threat level across fog-of-war
  ;; transit so the macro brain ramps up defense BEFORE an overwhelming enemy army arrives at our base,
  ;; without treating normal passive enemy home units/buildings as an active base-attack crisis!
  (define enemy-prod-bldgs
    (filter (lambda (eb)
              (memq (unit-type-sym eb)
                    '(barracks factory starport gateway warp-gate robotics-facility stargate
                      roach-warren hydralisk-den baneling-nest spire)))
            enemy-bldgs))
  (define implied-prod-threat-supply
    (if live-obs-harvesters?
        (* 2 (max 0 (- (length enemy-prod-bldgs) (+ 1 (* 2 (max 1 active-bases))))))
        (if (>= (length enemy-prod-bldgs) 2)
            (* 2 (length enemy-prod-bldgs))
            0)))
  (define live-defending-force-supply
    (+ live-army-supply
       (* 2 (count (lambda (u) (eq? (unit-type-sym u) 'queen)) ally-units))
       (* 2 (count (lambda (b)
                     (memq (unit-type-sym b)
                           '(spine-crawler photon-cannon bunker planetary-fortress)))
                   ready-bldgs))))
  (define distant-excess-threat
    (if live-obs-harvesters?
        (max 0 (- (max distant-enemy-combat-supply implied-prod-threat-supply)
                  (+ live-defending-force-supply 8)))
        implied-prod-threat-supply))
  (define visible-enemy-threat-supply
    (+ proximate-enemy-threat-supply
       (if live-obs-harvesters? distant-excess-threat 0)))
  (define prev-rem-threat (hash-ref prev-tel-early 'remembered-enemy-threat-supply 0))
  (define prev-rem-frame (hash-ref prev-tel-early 'remembered-enemy-threat-frame -9999))
  (define rem-window-frames (if live-obs-harvesters? 224 672))
  (define cur-visible-or-implied-threat
    (if live-obs-harvesters?
        visible-enemy-threat-supply
        (max visible-enemy-threat-supply implied-prod-threat-supply)))
  (define-values (remembered-enemy-threat-supply remembered-enemy-threat-frame)
    (cond
      [(> cur-visible-or-implied-threat 0)
       (values (if (<= (- frame prev-rem-frame) rem-window-frames)
                   (max cur-visible-or-implied-threat prev-rem-threat)
                   cur-visible-or-implied-threat)
               frame)]
      [(and (> prev-rem-threat 0) (<= (- frame prev-rem-frame) rem-window-frames))
       (values prev-rem-threat prev-rem-frame)]
      [else
       (values 0 prev-rem-frame)]))
  (define raw-enemy-threat-supply
    (max visible-enemy-threat-supply remembered-enemy-threat-supply))
  (define live-enemy-threat-supply
    (if (and live-obs-harvesters?
             (not (hash-ref obs 'under-attack #f)))
        (max 0 (exact-round (- raw-enemy-threat-supply (* 0.85 live-defending-force-supply))))
        raw-enemy-threat-supply))

  ;; Track opponent intel Freshness x Coverage across 4 sectors (`enemy-main`, `enemy-natural`,
  ;; `enemy-third`, `corridor-army`) via `evaluate-opponent-intel-quality` (PV9).
  ;; Sector timestamps update whenever an enemy unit/building is seen in that sector OR an
  ;; allied scout/Overlord/unit has live vision proximity (<= 15.0 tiles) to that sector!
  (define enemy-third-x (hash-ref obs 'enemy-third-x (safe-coord (* 0.72 enemy-x) 132.0)))
  (define enemy-third-y (hash-ref obs 'enemy-third-y (safe-coord (* 0.72 enemy-y) 132.0)))
  (define all-visible-enemies (append enemy-units enemy-bldgs))
  (define (ally-has-vision-of? sx sy)
    (ormap (lambda (u)
             (and (hash-has-key? u 'x)
                  (hash-has-key? u 'y)
                  (<= (dist2d (hash-ref u 'x base-x) (hash-ref u 'y base-y) sx sy) 15.0)))
           ally-units))
  (define (enemy-seen-near? sx sy radius)
    (ormap (lambda (e)
             (and (hash-has-key? e 'x)
                  (hash-has-key? e 'y)
                  (<= (dist2d (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0) sx sy) radius)))
           all-visible-enemies))
  (define last-seen-main-frame
    (cond
      [(hash-has-key? obs 'last-seen-main-frame)
       (hash-ref obs 'last-seen-main-frame 0)]
      [(or (not (null? enemy-bldgs))
           (enemy-seen-near? enemy-x enemy-y 28.0)
           (ally-has-vision-of? enemy-x enemy-y))
       frame]
      [else
       (hash-ref prev-tel-early 'last-seen-main-frame 0)]))
  (define last-seen-natural-frame
    (cond
      [(hash-has-key? obs 'last-seen-natural-frame)
       (hash-ref obs 'last-seen-natural-frame 0)]
      [(or (enemy-seen-near? enemy-exp-x enemy-exp-y 22.0)
           (ally-has-vision-of? enemy-exp-x enemy-exp-y))
       frame]
      [else
       (hash-ref prev-tel-early 'last-seen-natural-frame 0)]))
  (define last-seen-third-frame
    (cond
      [(hash-has-key? obs 'last-seen-third-frame)
       (hash-ref obs 'last-seen-third-frame 0)]
      [(or (enemy-seen-near? enemy-third-x enemy-third-y 22.0)
           (ally-has-vision-of? enemy-third-x enemy-third-y))
       frame]
      [else
       (hash-ref prev-tel-early 'last-seen-third-frame 0)]))
  (define last-seen-army-frame
    (cond
      [(hash-has-key? obs 'last-seen-army-frame)
       (hash-ref obs 'last-seen-army-frame 0)]
      [(or (not (null? enemy-units))
           (enemy-seen-near? corridor-mid-x corridor-mid-y 25.0)
           (and (>= frame 336) (ally-has-vision-of? corridor-mid-x corridor-mid-y)))
       frame]
      [else
       (hash-ref prev-tel-early 'last-seen-army-frame 0)]))
  (define last-enemy-seen-frame
    (if (hash-has-key? obs 'last-enemy-seen-frame)
        (hash-ref obs 'last-enemy-seen-frame 0)
        (max last-seen-main-frame
             last-seen-natural-frame
             last-seen-third-frame
             last-seen-army-frame
             (if (or (not (null? enemy-units)) (not (null? enemy-bldgs)))
                 frame
                 (hash-ref prev-tel-early 'last-enemy-seen-frame 0)))))
  (define intel-staleness-frames (max 0 (- frame last-enemy-seen-frame)))
  (define intel-qual
    (evaluate-opponent-intel-quality
     #:frame frame
     #:last-seen-main-frame last-seen-main-frame
     #:last-seen-natural-frame last-seen-natural-frame
     #:last-seen-third-frame last-seen-third-frame
     #:last-seen-army-frame last-seen-army-frame
     #:intel-staleness-frames (if (and (<= last-seen-main-frame 0)
                                       (<= last-seen-natural-frame 0)
                                       (<= last-seen-army-frame 0))
                                  intel-staleness-frames
                                  #f)
     #:army-supply live-army-supply
     #:ally-units ally-combat-units))
  (define intel-freshness (opponent-intel-quality-freshness intel-qual))
  (define intel-coverage (opponent-intel-quality-coverage intel-qual))
  (define intel-confidence (opponent-intel-quality-confidence intel-qual))
  (define intel-deficit (opponent-intel-quality-deficit intel-qual))
  (define intel-priority-sector (opponent-intel-quality-priority-sector intel-qual))
  (define intel-target-goal (opponent-intel-quality-target-goal intel-qual))

  (when (and (>= frame 448)
             (or (< intel-confidence 0.65)
                 (zero? (modulo frame 672))))
    (define recon-tx
      (case intel-priority-sector
        [(enemy-natural) enemy-exp-x]
        [(enemy-main)    enemy-x]
        [(enemy-third)   enemy-third-x]
        [else            corridor-mid-x]))
    (define recon-ty
      (case intel-priority-sector
        [(enemy-natural) enemy-exp-y]
        [(enemy-main)    enemy-y]
        [(enemy-third)   enemy-third-y]
        [else            corridor-mid-y]))
    ;; 1. Zero-risk spell / detector recon (Hallucinated Phoenix, Changeling, Observer, Orbital Scan)
    (case race
      [(Protoss)
       (define obs-unit (findf (lambda (u) (eq? (unit-type-sym u) 'observer)) ally-units))
       (when obs-unit
         (emit! (list 'periodic-scout (hash-ref obs-unit 'id 191) recon-tx recon-ty)))
       (define sentry-caster
         (findf (lambda (u)
                  (and (eq? (unit-type-sym u) 'sentry)
                       (>= (hash-ref u 'energy 0) 75)))
                ally-units))
       (when (and sentry-caster
                  (< intel-confidence 0.65)
                  (refractory-allow-action?! cd-tracker 'periodic-hallucination-scout frame 448))
         (emit! (list 'cast-deception-and-scout-spells
                      'sentry-hallucination-phoenix-scout
                      (hash-ref sentry-caster 'id 180)
                      recon-tx recon-ty)))]
      [(Zerg)
       (define ovs-caster
         (findf (lambda (u)
                  (and (eq? (unit-type-sym u) 'overseer)
                       (>= (hash-ref u 'energy 0) 50)))
                ally-units))
       (when (and ovs-caster
                  (refractory-allow-action?! cd-tracker 'periodic-changeling-scout frame 336))
         (emit! (list 'cast (hash-ref ovs-caster 'id 190) 'spawn-changeling recon-tx recon-ty)))]
      [(Terran)
       (define scan-oc
         (findf (lambda (b)
                  (and (eq? (unit-type-sym b) 'orbital-command)
                       (>= (hash-ref b 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS)
                       (>= (hash-ref b 'energy 0) (if (>= frame 3000) 50 75))))
                ally-bldgs))
       (when (and scan-oc
                  (< intel-confidence 0.50)
                  (refractory-allow-action?! cd-tracker 'periodic-scanner-sweep frame 672))
         (emit! (list 'cast-spell (hash-ref scan-oc 'id 301) 'scanner-sweep recon-tx recon-ty)))])
    ;; 2. Fast spotter unit recon toward `intel-priority-sector`
    (define spotter-candidates
      (filter (lambda (u)
                (memq (unit-type-sym u)
                      '(zergling reaper hellion adept marine stalker zealot mutalisk phoenix oracle)))
              ally-combat-units))
    (define chosen-spotter
      (and (not (null? spotter-candidates))
           (argmin (lambda (u)
                     (dist2d recon-tx recon-ty
                             (hash-ref u 'x base-x)
                             (hash-ref u 'y base-y)))
                   spotter-candidates)))
    (cond
      [chosen-spotter
       (emit! (list 'periodic-scout (hash-ref chosen-spotter 'id 101) recon-tx recon-ty))]
      [(and scout-worker-id (< intel-confidence 0.65))
       (emit! (list 'periodic-scout scout-worker-id recon-tx recon-ty))]))

  ;; Full-game owned-base attack & incoming-army threat detection (never expires at frame 2500!)
  (define bldg-actively-damaged?
    (ormap (lambda (b) (eq? (hash-ref b 'under-attack #f) #t)) ally-bldgs))
  (define enemy-inside-owned-base-perimeter?
    (ormap (lambda (e)
             (define ex (hash-ref e 'x 9999))
             (define ey (hash-ref e 'y 9999))
             (<= (min-dist-to-owned-base ex ey) 28.0))
           rush-threat-enemies))
  (define enemy-attacking-base-or-nat?
    (or under-early-cheese?
        bldg-actively-damaged?
        (and enemy-inside-owned-base-perimeter?
             (or (not live-obs-harvesters?)
                 (> live-enemy-threat-supply 0)
                 (<= live-defending-force-supply 2)))))
  (define under-base-attack?
    (or enemy-attacking-base-or-nat?
        (and (> live-enemy-threat-supply 0)
             (> live-enemy-threat-supply (max 4 live-army-supply)))))

  (define live-game-obs? (hash-has-key? raw-obs 'mineral-harvesters))
  (define supply-threshold
    (cond [(and live-game-obs? (< supply-cap 20)) 1]  ;; 14/15 Pylon/Depot, 13/14 Overlord
          [(and live-game-obs? (< supply-cap 26)) 2]  ;; 21/23 2nd Pylon/Depot (after 19 Nexus / 20 CC)
          [(>= supply-cap SC2-MID-SUPPLY-CAP-THRESHOLD) SC2-MID-SUPPLY-BUFFER]
          [(>= supply-cap SC2-EARLY-SUPPLY-CAP-THRESHOLD) SC2-EARLY-SUPPLY-BUFFER]
          [else SC2-BASE-SUPPLY-BUFFER]))

  (define active-intel-method
    (select-intel-gathering-method
     #:race race
     #:frame frame
     #:army-supply live-army-supply
     #:ally-units ally-combat-units
     #:intel-staleness-frames intel-staleness-frames))

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
     #:under-attack? under-base-attack?
     #:requires-anti-air? (enemy-tech-observation-requires-anti-air? tech-obs)
     #:requires-detection? (enemy-tech-observation-requires-detection? tech-obs)
     #:intel-staleness-frames intel-staleness-frames
     #:intel-freshness intel-freshness
     #:intel-coverage intel-coverage
     #:intel-confidence intel-confidence
     #:supply-at-risk? supply-at-risk?
     #:supply-buffer (and live-game-obs? supply-threshold)))
  (define max-pending-supply
    (if (and (< supply-cap SC2-MID-SUPPLY-CAP-THRESHOLD)
             (> supply-left 2))
        SC2-MAX-PENDING-SUPPLY-EARLY
        SC2-MAX-PENDING-SUPPLY-LATE))
  (define effective-supply-with-pending
    (+ supply-left (* SC2-SUPPLY-PER-PROVIDER pending-supply)))
  (define need-supply?
    (and (< supply-cap SC2-MAX-SUPPLY)
          (< pending-supply max-pending-supply)
          (or (and supply-at-risk?
                   (or (<= pending-supply 0) (hash-ref obs 'supply-at-risk #f))
                   (<= effective-supply-with-pending (+ supply-threshold SC2-SUPPLY-PER-PROVIDER)))
              (and (> (hash-ref pressure-metrics 'supply-hazard 0.0) 0.0)
                   (<= effective-supply-with-pending supply-threshold))
              (and (<= effective-supply-with-pending supply-threshold)
                   (>= minerals (sc2-min-cost 'overlord))))))

  ;; Orientation-aware Terran ramp wall solver (`depot-1`, `depot-2`, `barracks` with East +X add-on clearance)
  (define terran-ramp-wall
    (solve-terran-ramp-wall base-x base-y nat-x nat-y))

  (when (and need-supply? (>= minerals (sc2-min-cost 'overlord)))
    (case race
      [(Zerg)
       (recall-building-group! 4)
       (emit! '(train overlord))
       (order-ledger-record-issued! oledger (+ 800000 (modulo frame 10000)) 'train 'overlord base-x base-y frame)
       (set! minerals (- minerals (sc2-min-cost 'overlord)))
       (set! pending-supply (add1 pending-supply))]
      [(Protoss)
       (define pylon-count
          (count (lambda (t) (eq? t 'pylon)) bldg-types))
       (define raw-px (safe-coord (+ base-x 4.0 (* 2.5 (modulo pylon-count 4)))))
       (define raw-py (safe-coord (+ base-y 4.0 (* 2.5 (quotient pylon-count 4)))))
       (define-values (px py)
         (order-ledger-resolve-build-coords! oledger 'pylon raw-px raw-py ally-bldgs frame 2.5))
       (emit! (list 'build 'pylon (safe-coord px raw-px) (safe-coord py raw-py)))
       (set! minerals (- minerals (sc2-min-cost 'pylon)))
       (set! pending-supply (add1 pending-supply))]
      [(Terran)
       (define depot-count
         (count (lambda (t) (memq t '(supply-depot supply-depot-lowered))) bldg-types))
       (define wall-depot-entry
         (cond
           [(= depot-count 0) (hash-ref terran-ramp-wall 'depot-1 #f)]
           [(= depot-count 1) (hash-ref terran-ramp-wall 'depot-2 #f)]
           [else #f]))
       (define raw-dx
         (if (pair? wall-depot-entry)
             (safe-coord (car wall-depot-entry) (+ base-x 4.0))
             (safe-coord (+ base-x 4.0 (* 2.5 (modulo depot-count 4))))))
       (define raw-dy
         (if (pair? wall-depot-entry)
             (safe-coord (cdr wall-depot-entry) (- base-y 3.0))
             (safe-coord (- base-y 3.0 (* 2.5 (quotient depot-count 4))))))
       (define-values (dx dy)
         (order-ledger-resolve-build-coords! oledger 'supply-depot raw-dx raw-dy ally-bldgs frame 2.0))
       (emit! (list 'build 'supply-depot (safe-coord dx raw-dx) (safe-coord dy raw-dy)))
       (set! minerals (- minerals (sc2-min-cost 'supply-depot)))
       (set! pending-supply (add1 pending-supply))]))

  ;; Helper: check if we can spend `cost` supply without supply blocking
  ;; Also reserves supply floor if supply-at-risk and minerals < 150 (only when no supply provider is already pending)
  (define reserve-supply-floor?
    (and (<= pending-supply 0)
         (or (not live-game-obs?) (>= supply-used 14))
         (or supply-at-risk?
             (<= supply-left (if (and live-game-obs? (< supply-cap 20)) 1 SC2-CRITICAL-LOW-SUPPLY)))
         (< minerals (+ (sc2-min-cost 'overlord) (sc2-min-cost 'drone)))))
  (define effective-free-supply
    (max 0 (+ supply-left (if (> pending-supply 0) SC2-PENDING-SUPPLY-CREDIT 0))))
  (define (can-spend-supply? cost)
    (and (not reserve-supply-floor?)
         (>= effective-free-supply cost)
         (> supply-left 0)))

  (define (spend-resources-and-supply! m-cost g-cost s-cost)
    (set! minerals (max 0 (- minerals m-cost)))
    (set! gas (max 0 (- gas g-cost)))
    (when (> s-cost 0)
      (set! supply-left (max 0 (- supply-left s-cost)))
      (set! effective-free-supply (max 0 (- effective-free-supply s-cost)))))

  (define researched-upgs (hash-ref obs 'researched-upgrades '()))
  (define pending-upgs (hash-ref obs 'pending-upgrades '()))
  (define (upgrade-needed? upg-sym)
    (and (not (memq upg-sym researched-upgs))
         (not (memq upg-sym pending-upgs))
         (= (order-ledger-pending-count-for-type oledger upg-sym frame) 0)))

  (define morphing-bldg-types
    (filter-map (lambda (b)
                  (case (hash-ref b 'order-ability-id 0)
                    [(1516) 'orbital-command]
                    [(1450) 'planetary-fortress]
                    [(1216) 'lair]
                    [(1218) 'hive]
                    [(1220) 'greater-spire]
                    [(1506) 'lurker-den]
                    [else #f]))
                ally-bldgs))

  (define (building-present-or-pending? bldg-sym)
    (or (memq bldg-sym bldg-types)
        (memq bldg-sym morphing-bldg-types)
        (> (order-ledger-pending-count-for-type oledger bldg-sym frame) 0)))

  (define (emit-build-verified! bldg-sym raw-x raw-y [clearance SC2-BUILD-SITE-MIN-CLEARANCE])
    (define-values (bx by)
      (order-ledger-resolve-build-coords! oledger bldg-sym raw-x raw-y ally-bldgs frame clearance))
    (define sx (safe-coord bx raw-x))
    (define sy (safe-coord by raw-y))
    (emit! (list 'build bldg-sym sx sy))
    (order-ledger-record-issued! oledger (+ 820000 (modulo frame 10000) (length actions))
                                 'build bldg-sym sx sy frame)
    (set! bldg-types (cons bldg-sym bldg-types))
    (spend-resources-and-supply! (sc2-min-cost bldg-sym) (sc2-gas-cost bldg-sym) 0))

  (define (emit-gas-build-verified! gas-sym raw-x raw-y [cost-sym gas-sym])
    (define sx (safe-coord raw-x (+ base-x 4.0)))
    (define sy (safe-coord raw-y (+ base-y 4.0)))
    (emit! (list 'build gas-sym sx sy))
    (order-ledger-record-issued! oledger (+ 815000 (modulo frame 10000) (length actions))
                                 'build gas-sym sx sy frame)
    (spend-resources-and-supply! (sc2-min-cost cost-sym) 0 0))

  (define (emit-research-verified! upg-sym)
    (when (and (upgrade-needed? upg-sym)
               (>= minerals (sc2-min-cost upg-sym))
               (>= gas (sc2-gas-cost upg-sym)))
      (recall-building-group! 7)
      (emit! (list 'research upg-sym))
      (set! pending-upgs (cons upg-sym pending-upgs))
      (order-ledger-record-issued! oledger (+ 850000 (modulo frame 10000) (length actions))
                                   'research upg-sym base-x base-y frame)
      (spend-resources-and-supply! (sc2-min-cost upg-sym) (sc2-gas-cost upg-sym) 0)))

  ;; ---------------------------------------------------------------------------
  ;; Empirical Pro Build-Order & Goal-Queue Executor + Facility Slot Accounting
  ;; ---------------------------------------------------------------------------
  (define ready-bldg-counts
    (for/fold ([ht (hash)]) ([t (in-list ready-bldg-types)])
      (hash-update ht t add1 0)))
  (define total-bldg-counts
    (for/fold ([ht (for/fold ([h0 (hash)]) ([t (in-list (append bldg-types morphing-bldg-types))])
                     (hash-update h0 t add1 0))])
              ([sym (in-list '(hatchery lair hive spawning-pool extractor roach-warren baneling-nest
                               evolution-chamber hydralisk-den spire lurker-den infestation-pit
                               ultralisk-cavern spine-crawler spore-crawler
                               nexus pylon assimilator gateway warp-gate cybernetics-core
                               robotics-facility robotics-bay twilight-council forge stargate
                               templar-archives dark-shrine fleet-beacon photon-cannon shield-battery
                               command-center orbital-command planetary-fortress supply-depot
                               refinery barracks barracks-techlab barracks-reactor
                               factory factory-techlab factory-reactor
                               starport starport-techlab starport-reactor
                               engineering-bay armory ghost-academy fusion-core bunker missile-turret))])
      (define pend (order-ledger-pending-count-for-type oledger sym frame))
      (if (> pend 0)
          (hash-update ht sym (lambda (c) (+ c pend)) 0)
          ht)))
  (define (normalize-unit-count-sym t)
    (case t
      [(baneling-cocoon) 'baneling]
      [(ravager-cocoon) 'ravager]
      [(lurker-egg lurker-mp-egg lurker-mp lurker-burrowed lurker-mp-burrowed) 'lurker]
      [(brood-lord-cocoon broodlord) 'brood-lord]
      [(overlord-cocoon overseer-siege-mode) 'overseer]
      [(widow-mine-burrowed) 'widow-mine]
      [(siege-tank-sieged) 'siege-tank]
      [(disruptor-phased) 'disruptor]
      [else t]))
  (define unit-counts
    (for/fold ([ht (for/fold ([h0 (hash)]) ([t (in-list unit-types)])
                     (hash-update h0 (normalize-unit-count-sym t) add1 0))])
              ([usym (in-list '(drone overlord overseer queen zergling baneling roach ravager hydralisk lurker mutalisk corruptor brood-lord ultralisk infestor viper
                                probe zealot stalker sentry adept high-templar dark-templar archon immortal observer warp-prism colossus disruptor phoenix void-ray oracle carrier tempest
                                scv marine marauder reaper ghost hellion hellbat widow-mine siege-tank cyclone thor medivac viking liberator raven banshee battlecruiser))])
      (define pend (order-ledger-pending-count-for-type oledger usym frame))
      (if (> pend 0)
          (hash-update ht usym (lambda (c) (+ c pend)) 0)
          ht)))
  (define enemy-race-guess
    (cond
      [(ormap (lambda (e) (memq (unit-type-sym e) '(drone overlord zergling roach hydralisk mutalisk queen hatchery lair)))
              (append enemy-units enemy-bldgs)) 'Zerg]
      [(ormap (lambda (e) (memq (unit-type-sym e) '(scv marine marauder reaper siege-tank medivac command-center barracks)))
              (append enemy-units enemy-bldgs)) 'Terran]
      [(ormap (lambda (e) (memq (unit-type-sym e) '(probe zealot stalker adept sentry immortal nexus pylon gateway)))
              (append enemy-units enemy-bldgs)) 'Protoss]
      [else 'Unknown]))
  (define prev-telemetry-ht
    (let ([t (live-bot-runtime-last-telemetry rt)])
      (if (hash? t) t (hash))))
  (define cur-peak-supply
    (max supply-used (hash-ref prev-telemetry-ht 'peak-supply-reached 0)))
  (define eff-phase-supply (max supply-used cur-peak-supply))

  (define bo-eval
    (evaluate-build-order-next-step
     #:race race
     #:enemy-race enemy-race-guess
     #:frame frame
     #:minerals minerals
     #:gas gas
     #:supply-used eff-phase-supply
     #:supply-left supply-left
     #:active-bases active-bases
     #:ready-building-counts ready-bldg-counts
     #:total-building-counts total-bldg-counts
     #:unit-counts unit-counts
     #:researched-upgrades researched-upgs
     #:pending-upgrades pending-upgs
     #:base-x base-x #:base-y base-y
     #:nat-x nat-x #:nat-y nat-y
     #:third-x third-x #:third-y third-y))
  (define bo-active-goal (pro-bo-eval-result-active-goal bo-eval))
  (define bo-goal-sym (and bo-active-goal (pro-bo-goal-target-sym bo-active-goal)))
  (define bo-reserved-min (pro-bo-eval-result-reserved-minerals bo-eval))
  (define bo-reserved-gas (pro-bo-eval-result-reserved-gas bo-eval))
  (set! target-workers (max target-workers (pro-bo-eval-result-target-workers bo-eval)))

  ;; Track mutable open production slots per facility category in the current frame
  ;; so `(train unit)` is NEVER emitted or charged when all facilities of that type are busy!
  (define open-prod-slots (make-hash))
  (for ([cap (in-list (list cg4-cap cg5-cap cg6-cap))])
    (for ([(btype cnt) (in-hash (hash-ref cap 'open-slots-by-type (hash)))])
      (define norm-k
        (case btype
          [(gateway warp-gate warpgate) 'gateway]
          [(hatchery lair hive nexus command-center orbital-command planetary-fortress) 'townhall]
          [(barracks-tech-lab barracks-techlab) 'barracks-techlab]
          [(factory-tech-lab factory-techlab) 'factory-techlab]
          [(starport-tech-lab starport-techlab) 'starport-techlab]
          [(templar-archive templar-archives) 'templar-archive]
          [(lurker-den lurker-den-mp) 'lurker-den]
          [else btype]))
      (hash-update! open-prod-slots norm-k (lambda (old) (+ old cnt)) 0)))
  ;; Fallback for synthetic tests where buildings might not yet be synced in control groups
  (define fallback-prod-slots (make-hash))
  (for ([b (in-list ready-bldgs)])
    (define bt (unit-type-sym b))
    (define norm-k
      (case bt
        [(gateway warp-gate warpgate) 'gateway]
        [(hatchery lair hive nexus command-center orbital-command planetary-fortress) 'townhall]
        [(barracks-tech-lab barracks-techlab) 'barracks-techlab]
        [(factory-tech-lab factory-techlab) 'factory-techlab]
        [(starport-tech-lab starport-techlab) 'starport-techlab]
        [(templar-archive templar-archives) 'templar-archive]
        [(lurker-den lurker-den-mp) 'lurker-den]
        [else bt]))
    (define b-ords (hash-ref b 'order-count (let ([o (hash-ref b 'orders '())]) (if (list? o) (length o) 0))))
    (define b-max (if (eq? (hash-ref b 'addon #f) 'reactor) 2 1))
    (define b-open (if (or (eq? (hash-ref b 'busy? #f) #t) (order-ledger-facility-busy? oledger b frame))
                       0
                       (max 0 (- b-max b-ords))))
    (hash-update! fallback-prod-slots norm-k (lambda (old) (+ old b-open)) 0))
  (for ([(norm-k cnt) (in-hash fallback-prod-slots)])
    (when (> cnt (hash-ref open-prod-slots norm-k 0))
      (hash-set! open-prod-slots norm-k cnt)))
  ;; Zerg larva accounting: use explicit larva count in live SC2 observations, or 3 per Hatchery in synthetic tests
  (define explicit-larvae (count (lambda (u) (eq? (unit-type-sym u) 'larva)) ally-units))
  (define live-larva-tracking?
    (ormap (lambda (u) (memq (unit-type-sym u) '(larva egg baneling-cocoon ravager-cocoon))) ally-units))
  (hash-set! open-prod-slots 'larva
             (if live-larva-tracking?
                 explicit-larvae
                 (* 3 (max 1 active-bases))))
  ;; Zerg unit-morph producer slots (`zergling -> baneling`, `roach -> ravager`,
  ;; `hydralisk -> lurker`, `corruptor -> brood-lord`, `overlord -> overseer`):
  (for ([msym (in-list '(zergling roach hydralisk corruptor overlord))])
    (define avail-morph-sources
      (count (lambda (u)
               (and (eq? (unit-type-sym u) msym)
                    (not (order-ledger-facility-busy? oledger u frame))))
             ally-units))
    (hash-set! open-prod-slots msym avail-morph-sources))

  (define live-game? live-game-obs?)
  (define open-prod-slots-snapshot
    (and live-game?
         (for/hasheq ([(k v) (in-hash open-prod-slots)])
           (values k v))))

  ;; Decoupled Priority Macro Brain (`lib/priority-macro-brain.rkt`):
  ;; Single source of truth for recursive SC2-TECH-GRAPH prerequisite self-healing,
  ;; effective-phase-supply watermark progression, dual-resource (min + gas) escrow,
  ;; and Okasaki Braun-heap marginal-utility scheduling.
  (define macro-world
    (make-macro-world-state
     #:race race
     #:enemy-race enemy-race-guess
     #:frame frame
     #:minerals minerals
     #:gas gas
     #:supply-used supply-used
     #:supply-cap supply-cap
     #:supply-left supply-left
     #:pending-supply pending-supply
     #:workers total-workers
     #:active-bases active-bases
     #:ready-building-counts ready-bldg-counts
     #:total-building-counts total-bldg-counts
     #:unit-counts unit-counts
     #:researched-upgrades researched-upgs
     #:pending-upgrades pending-upgs
     #:open-facility-slots open-prod-slots-snapshot
     #:army-supply live-army-supply
     #:enemy-threat-supply live-enemy-threat-supply
     #:under-attack? under-base-attack?
     #:requires-anti-air? (enemy-tech-observation-requires-anti-air? tech-obs)
     #:requires-detection? (enemy-tech-observation-requires-detection? tech-obs)
     #:supply-at-risk? supply-at-risk?
     #:peak-supply-reached cur-peak-supply
     #:base-x base-x #:base-y base-y
     #:nat-x nat-x #:nat-y nat-y
     #:third-x third-x #:third-y third-y))
  (define macro-decision (step-priority-macro-brain macro-world))
  (define dyn-plan (macro-brain-decision-dynamic-plan macro-decision))
  (define plan-next-actions-ht
    (if (dynamic-macro-plan? dyn-plan)
        (dynamic-macro-plan-translated-next-actions dyn-plan)
        (hasheq)))
  (define (plan-wants-now? sym)
    (or (eq? bo-goal-sym sym)
        (hash-has-key? plan-next-actions-ht sym)
        (not (not (memq sym (macro-brain-decision-scheduled-ids macro-decision))))))
  (define repaired-prereqs (macro-brain-decision-repaired-prereqs macro-decision))
  (when (and live-game? (macro-brain-decision-bo-active-goal macro-decision))
    (set! bo-active-goal (macro-brain-decision-bo-active-goal macro-decision))
    (set! bo-goal-sym (and bo-active-goal (pro-bo-goal-target-sym bo-active-goal)))
    (set! bo-reserved-min (max bo-reserved-min (macro-brain-decision-reserved-min-floor macro-decision)))
    (set! bo-reserved-gas (max bo-reserved-gas (macro-brain-decision-reserved-gas-floor macro-decision))))

  ;; Escrow Age Timeout & Anti-Deadlock Preemption (PV7 / PV9):
  ;; If an expansion goal (`hatchery`, `nexus`, `command-center`) has been escrowing resources
  ;; for >= 224 frames (10s) without placement, OR we are under base attack / enemy threat,
  ;; OR we are past frame 1800 with < 4 army supply, OR opponent intel is stale (>= 268 frames)
  ;; and we lack army (< 8 supply) to probe/harass, release the expansion escrow immediately so
  ;; combat units and scouting/harassment raiders are never deadlocked!
  (define active-escrow-sym
    (let ([sf (macro-brain-decision-saving-for macro-decision)])
      (if (and sf (not (eq? sf 'none)))
          sf
          bo-goal-sym)))
  (define obs-minerals (safe-nonneg-int (hash-ref obs 'minerals 0)))
  (define prev-escrow-goal (hash-ref prev-telemetry-ht 'escrow-goal-sym #f))
  (define prev-escrow-age (hash-ref prev-telemetry-ht 'escrow-age-frames 0))
  (define prev-escrow-frame (hash-ref prev-telemetry-ht 'escrow-last-frame frame))
  (define prev-escrow-peak-min (hash-ref prev-telemetry-ht 'escrow-peak-min obs-minerals))
  (define prev-escrow-min (hash-ref prev-telemetry-ht 'escrow-prev-min obs-minerals))
  (define prev-escrow-start-frame (hash-ref prev-telemetry-ht 'escrow-start-frame frame))
  (define escrow-same-goal?
    (and active-escrow-sym
         (eq? active-escrow-sym prev-escrow-goal)
         (> (+ bo-reserved-min bo-reserved-gas) 0)))
  (define cur-escrow-start-frame
    (if escrow-same-goal? prev-escrow-start-frame frame))
  (define escrow-making-progress?
    (and escrow-same-goal?
         (memq active-escrow-sym '(hatchery nexus command-center))
         (> total-workers 0)
         (not natural-blocked?)
         (< (- frame cur-escrow-start-frame) 896)
         (> obs-minerals prev-escrow-peak-min)))
  (define cur-escrow-peak-min
    (if escrow-same-goal?
        (max prev-escrow-peak-min obs-minerals)
        obs-minerals))
  (define cur-escrow-age-frames
    (cond
      [(not escrow-same-goal?) 0]
      [escrow-making-progress? 0]
      [else (+ prev-escrow-age (max 1 (- frame prev-escrow-frame)))]))
  (define max-escrow-timeout-frames 224)
  (define severe-intel-blindness?
    (and (>= frame 1800)
         (or (>= supply-used 22) (>= frame 2240) (>= active-bases 2))
         (>= intel-staleness-frames 896)
         (< intel-confidence 0.35)))
  (define urgent-combat-or-intel-need?
    (or (and (< live-army-supply 8)
             (or under-base-attack?
                 (> live-enemy-threat-supply 0)))
        (and live-game?
             (null? ally-combat-units)
             (or (>= cur-escrow-age-frames max-escrow-timeout-frames)
                 severe-intel-blindness?))))
  (define (non-combat-min-ok? cost)
    (>= (- minerals cost) (if urgent-combat-or-intel-need? 125 0)))
  (define (non-combat-gas-ok? cost)
    (or (<= cost 0)
        (>= (- gas cost) (if urgent-combat-or-intel-need? 50 0))))
  (when (or (>= cur-escrow-age-frames max-escrow-timeout-frames)
            urgent-combat-or-intel-need?)
    (set! bo-reserved-min 0)
    (set! bo-reserved-gas 0))

  (define prio-sched (macro-brain-decision-priority-schedule macro-decision))
  (define prio-scheduled-actions (macro-brain-decision-scheduled-actions macro-decision))

  (define prio-summary
    (priority-schedule-summary-hash
     prio-sched
     #:frame frame
     #:race race
     #:minerals minerals
     #:gas gas
     #:supply-used supply-used
     #:supply-cap supply-cap
     #:bo-goal-sym bo-goal-sym
     #:bo-reserved-min bo-reserved-min
     #:bo-reserved-gas bo-reserved-gas))
  (define prio-log-line (macro-brain-decision-log-line macro-decision))

  (define (can-spend-by-priority? id-sym [cat-sym 'combat-unit])
    (or (not live-game?)
        (and (eq? cat-sym 'combat-unit)
             (or under-base-attack?
                 (> live-enemy-threat-supply 0)
                 (>= cur-escrow-age-frames max-escrow-timeout-frames)
                 (and severe-intel-blindness? (null? ally-combat-units))))
        (macro-brain-can-spend? macro-decision id-sym minerals gas cat-sym)))

  (define (try-train-unit! unit-sym producer-key [recall-group #f] #:respect-bo-reserve? [respect-bo? #f])
    (define m-cost (sc2-min-cost unit-sym))
    (define g-cost (sc2-gas-cost unit-sym))
    (define s-cost (sc2-supply-cost unit-sym))
    (define is-bo-head?
      (or (eq? bo-goal-sym unit-sym)
          (and live-game?
               (not (not (memq unit-sym (macro-brain-decision-scheduled-ids macro-decision)))))))
    (define max-batch
      (cond
        [(not live-game?) 1]
        [(and (memq unit-sym '(drone probe scv))
              (>= active-bases 2)
              (< total-workers (min 80 (* 22 active-bases)))
              (not under-base-attack?)
              (<= live-enemy-threat-supply 0))
         (min 3 active-bases)]
        [(memq unit-sym '(drone probe scv overlord observer sentry)) 1]
        [else 4]))
    (let loop ([trained 0])
      (define avail-slots (hash-ref open-prod-slots producer-key 0))
      (define eff-min (if (and respect-bo? (not (and is-bo-head? (= trained 0)))) (- minerals bo-reserved-min) minerals))
      (define eff-gas (if (and respect-bo? (not (and is-bo-head? (= trained 0)))) (- gas bo-reserved-gas) gas))
      (cond
        [(and (< trained max-batch)
              (> avail-slots 0)
              (can-spend-supply? s-cost)
              (>= eff-min m-cost)
              (>= eff-gas g-cost))
         (hash-set! open-prod-slots producer-key (sub1 avail-slots))
         (when (and recall-group (= trained 0))
           (recall-building-group! recall-group))
         (emit! (list 'train unit-sym))
         (order-ledger-record-issued! oledger (+ 860000 (modulo frame 10000) (length actions))
                                      'train unit-sym base-x base-y frame)
         (spend-resources-and-supply! m-cost g-cost s-cost)
         (loop (add1 trained))]
        [else (> trained 0)])))

  ;; Self-Healing Prerequisite Repair Actuator (`orphaned-prereqs` from `priority-macro-brain.rkt`):
  ;; When `find-all-broken-tech-dependencies` detects that an upstream prerequisite of an
  ;; ALREADY-EXISTING mid/late-game tech structure was destroyed (e.g. Cybernetics Core sniped
  ;; while Twilight Council is alive, Factory sniped while Starport is alive, or Spawning Pool
  ;; sniped while Roach Warren is alive), rebuild the missing prerequisite(s) in topological
  ;; order BEFORE routine unit/expansion spending.
  (define orphaned-prereqs
    (find-all-broken-tech-dependencies race ready-bldg-counts total-bldg-counts #:active-goals '()))
  (for ([req-sym (in-list orphaned-prereqs)])
    (when (and (not (building-present-or-pending? req-sym))
               (not (memq req-sym '(hatchery nexus command-center extractor assimilator refinery
                                    supply-depot overlord)))
               (not (and (eq? req-sym 'pylon) (not live-game?) (>= supply-left 8))))
      (define m-cost (sc2-min-cost req-sym))
      (define g-cost (sc2-gas-cost req-sym))
      (cond
        [(and (>= minerals m-cost) (>= gas g-cost))
         (case req-sym
           [(lair hive orbital-command planetary-fortress greater-spire)
            (recall-building-group! 4)
            (emit! (list 'morph req-sym))
            (set! bldg-types (cons req-sym bldg-types))
            (order-ledger-record-issued! oledger (+ 821000 (modulo frame 10000) (length actions))
                                         'morph req-sym base-x base-y frame)
            (spend-resources-and-supply! m-cost g-cost 0)]
           [else
            (emit-build-verified! req-sym (safe-coord (+ base-x 3.5)) (safe-coord (+ base-y 3.5)))])]
        [(not urgent-combat-or-intel-need?)
         (set! bo-reserved-min (max bo-reserved-min m-cost))
         (set! bo-reserved-gas (max bo-reserved-gas g-cost))])))

  ;; Multi-base expansion mineral escrow:
  ;; When the Pro Build Order (`evaluate-build-order-next-step`) reaches an expansion goal
  ;; (`16 Hatchery`, `19 Nexus`, `20 Command Center`, or `3rd Base`) or when current bases
  ;; are saturated AND our 3rd-base supply/army thresholds are met, hold mineral spending
  ;; until we reach `(sc2-min-cost race-th-sym)` (300M Zerg / 400M Protoss & Terran).
  ;; Dynamic threat, severe-intel-blindness & tech-repair preemption: never lock minerals for expansion
  ;; if under attack, if enemy threat is active, if escrow age >= max-escrow-timeout-frames, if intel is severely
  ;; blind (>= 896 frames stale and confidence < 0.35) without probing units, or if a prerequisite
  ;; in our SC2-TECH-GRAPH (`repaired-prereqs`) was destroyed!
  (define race-th-sym
    (case race
      [(Zerg) 'hatchery]
      [(Protoss) 'nexus]
      [else 'command-center]))

  (define (saving-for-expansion-now? cur-base-count)
    (and (not under-base-attack?)
         (<= live-enemy-threat-supply 0)
         (not urgent-combat-or-intel-need?)
         (< cur-escrow-age-frames max-escrow-timeout-frames)
         (or (not live-game?)
             (and (= cur-base-count 1) (< frame 3800))
             (>= live-army-supply 2))
         (or (not live-game?) (not severe-intel-blindness?) (not (null? ally-combat-units)))
         (null? orphaned-prereqs)
         (< (hash-ref pressure-metrics 'threat-pressure 0.0) 0.85)
         (not natural-blocked?)
         (= (order-ledger-pending-count-for-type oledger race-th-sym frame) 0)
         (< minerals (sc2-min-cost race-th-sym))
         (or (and live-game?
                  (= cur-base-count 1)
                  (case race
                    [(Zerg) (>= total-workers 15)]
                    [(Protoss) (and (>= total-workers 17)
                                    (or (memq 'gateway bldg-types) (memq 'warp-gate bldg-types))
                                    (memq 'assimilator bldg-types))]
                    [(Terran) (and (>= total-workers 18)
                                   (memq 'barracks bldg-types)
                                   (memq 'refinery bldg-types)
                                   (building-present-or-pending? 'orbital-command))]
                    [else #f]))
             (and live-game?
                  (eq? bo-goal-sym race-th-sym)
                  (or (= cur-base-count 1)
                      (and (>= eff-phase-supply (case race [(Protoss) 50] [(Terran) 46] [else 30]))
                           (>= live-army-supply (if (eq? race 'Zerg) 2 14))))
                  (>= total-workers (if (eq? race 'Zerg) 15 18)))
             (and (> frame 1800)
                  (< cur-base-count desired-bases)
                  (>= total-workers
                      (if (and live-game? (= cur-base-count 2))
                          (if (eq? race 'Zerg) 28 35)
                          (* (max 1 cur-base-count) SC2-IDEAL-WORKERS-PER-BASE)))
                  (if live-game?
                      (or (= cur-base-count 1)
                          (and (>= eff-phase-supply (case race [(Protoss) 50] [(Terran) 46] [else 30]))
                               (>= live-army-supply (* (if (eq? race 'Zerg) 4 7) cur-base-count))))
                      (>= (length ally-combat-units) 4))))))

  ;; ---------------------------------------------------------------------------
  ;; Race-Specific Macro Mechanics, Pro Build Orders, Tech Trees & Unit Production
  ;; (100% Valid SC2 LotV Symbols + Pro Replay Build Orders + Facility Slot Gating
  ;;  + Building Control Groups 4/5/6/7 Production & Research Orchestration)
  ;; ---------------------------------------------------------------------------
  (case race
    [(Zerg)
     ;; 1. Queen Inject Larva & Spawn Creep Tumor (Bug #15, #16, #21 fix:
     ;;    never interrupt a Queen already executing Inject Larva (251) or Spawn Creep Tumor (1694),
     ;;    pair each Queen with its closest ready Hatchery, and anchor initial creep tumors 3.5 tiles
     ;;    from the Hatchery toward the natural so they are guaranteed to be on creep!)
     (define queens (filter (lambda (u) (eq? (unit-type-sym u) 'queen)) ally-units))
     (define hatcheries
       (filter (lambda (b) (memq (unit-type-sym b) '(hatchery lair hive))) ally-bldgs))
     (define ready-hatcheries
       (filter (lambda (b) (memq (unit-type-sym b) '(hatchery lair hive))) ready-bldgs))
     (define inject-hatcheries
       (if (not (null? ready-hatcheries)) ready-hatcheries hatcheries))
     (define extractors
       (filter (lambda (b) (eq? (unit-type-sym b) 'extractor)) ally-bldgs))
     (for ([q (in-list queens)]
           [q-idx (in-naturals)])
       (define q-energy (hash-ref q 'energy SC2-QUEEN-INJECT-ENERGY))
       (define qid (hash-ref q 'id 120))
       (define qx (hash-ref q 'x base-x))
       (define qy (hash-ref q 'y base-y))
       (define q-ab-id (hash-ref q 'order-ability-id 0))
       (define q-ab-sym (hash-ref q 'order-ability-sym #f))
       (define q-busy-casting?
         (or (memv q-ab-id '(251 1694))
             (memq q-ab-sym '(inject-larva spawn-creep-tumor spread-creep-tumor))))
       (define target-hatch
         (and (not (null? inject-hatcheries))
              (argmin (lambda (h)
                        (define hx (hash-ref h 'x base-x))
                        (define hy (hash-ref h 'y base-y))
                        (+ (sqr (- qx hx)) (sqr (- qy hy))))
                      inject-hatcheries)))
       (define hx (if target-hatch (hash-ref target-hatch 'x base-x) base-x))
       (define hy (if target-hatch (hash-ref target-hatch 'y base-y) base-y))
       (define hdx (- nat-x hx))
       (define hdy (- nat-y hy))
       (define hd (max 1.0 (sqrt (+ (* hdx hdx) (* hdy hdy)))))
       (define tumor-init-x (safe-coord (+ hx (* 3.5 (/ hdx hd))) hx))
       (define tumor-init-y (safe-coord (+ hy (* 3.5 (/ hdy hd))) hy))
       (unless q-busy-casting?
         (cond
           [(and (>= q-energy SC2-QUEEN-TUMOR-SURPLUS-ENERGY)
                 (refractory-allow-action?! cd-tracker
                                            (list 'queen-tumor qid)
                                            frame
                                            SC2-CREEP-TUMOR-COOLDOWN-FRAMES))
            (emit! (list 'cast-spell qid 'spawn-creep-tumor tumor-init-x tumor-init-y))
            (order-ledger-record-issued! oledger qid 'cast-spell 'spawn-creep-tumor tumor-init-x tumor-init-y frame)]
           [(and (>= q-energy SC2-QUEEN-INJECT-ENERGY) target-hatch)
            (emit! (list 'cast-spell qid 'inject-larva (hash-ref target-hatch 'id 101)))
            (order-ledger-record-issued! oledger qid 'cast-spell 'inject-larva hx hy frame)])))

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

     ;; 3. Pro Build-Order Expansion Sequencing (16 Hatchery -> 30 3rd Hatchery -> 4th+ bases)
     (when (and (>= minerals (sc2-min-cost 'hatchery))
                (non-combat-min-ok? (sc2-min-cost 'hatchery))
                (not under-early-cheese?)
                (not under-base-attack?)
                (not natural-blocked?)
                (= (order-ledger-pending-count-for-type oledger 'hatchery frame) 0)
                (or (< (length hatcheries) SC2-MIN-DESIRED-BASES)
                    (and (= (length hatcheries) 2)
                         (>= supply-used 30)
                         (memq 'spawning-pool ready-bldg-types))
                    (and (< (length hatcheries) desired-bases)
                         (>= total-workers (* (length hatcheries)
                                              (if (>= (length hatcheries) 3) 18 SC2-MIN-WORKERS-PER-BASE-FOR-EXPAND)))
                         (or (coupled-macro-plan-should-expand? macro-plan)
                             (>= frame SC2-MACRO-EXPAND-FRAME-THRESHOLD))))
                (refractory-allow-action?! cd-tracker
                                           (list 'macro-expand 'Zerg)
                                           frame
                                           SC2-EXPANSION-COOLDOWN-FRAMES))
       (define exp-x (if (>= (length hatcheries) SC2-MIN-DESIRED-BASES) third-x nat-x))
       (define exp-y (if (>= (length hatcheries) SC2-MIN-DESIRED-BASES) third-y nat-y))
       (emit! (list 'expand exp-x exp-y))
       (order-ledger-record-issued! oledger (+ 810000 (modulo frame 10000)) 'expand 'hatchery exp-x exp-y frame)
       (spend-resources-and-supply! (sc2-min-cost 'hatchery) 0 0))

     (define zerg-saving-for-expand? (saving-for-expansion-now? (length hatcheries)))

     ;; 4. Zerg Pro Build Order: 17 Pool -> 17 Extractor -> 20 Queens -> 22 Metabolic Boost
     ;;    -> 36 Roach Warren -> 38 Baneling Nest -> 40 2nd & 3rd Extractor -> 46 Lair -> 48 Evo -> 62 Hydra Den
     (when (and (not (building-present-or-pending? 'spawning-pool))
                (>= minerals (sc2-min-cost 'spawning-pool)))
       (emit-build-verified! 'spawning-pool (safe-coord (+ base-x 3.0)) (safe-coord (+ base-y 3.0))))

     (define desired-extractors
       (min (* SC2-GEYSERS-PER-BASE (length hatcheries))
            (cond
              [(>= supply-used 60) 4]
              [(>= supply-used 44) 3]
              [(>= supply-used 38) 2]
              [(>= total-workers (add1 SC2-MIN-WORKERS-FOR-GAS)) 1]
              [else 0])))
     (when (and (memq 'spawning-pool bldg-types)
                (< (+ (length extractors) (order-ledger-pending-count-for-type oledger 'extractor frame))
                   desired-extractors)
                (>= minerals (sc2-min-cost 'gas-building-reserve))
                (non-combat-min-ok? (sc2-min-cost 'gas-building-reserve)))
       (emit-gas-build-verified! 'extractor (safe-coord (+ base-x 4.0)) (safe-coord (+ base-y 4.0)) 'gas-building-reserve))

     (when (and (memq 'spawning-pool ready-bldg-types)
                (not zerg-saving-for-expand?)
                (non-combat-min-ok? (sc2-min-cost 'queen))
                (< (+ (length queens) (order-ledger-pending-count-for-type oledger 'queen frame))
                   (min SC2-MAX-QUEENS-CAP (+ 1 (length hatcheries)))))
       (try-train-unit! 'queen 'townhall 4))

     (when (and (memq 'spawning-pool ready-bldg-types)
                (upgrade-needed? 'metabolic-boost)
                (>= minerals (sc2-min-cost 'metabolic-boost))
                (>= gas (sc2-gas-cost 'metabolic-boost))
                (non-combat-min-ok? (sc2-min-cost 'metabolic-boost))
                (non-combat-gas-ok? (sc2-gas-cost 'metabolic-boost)))
       (emit-research-verified! 'metabolic-boost))

     (when (and (memq 'spawning-pool ready-bldg-types)
                (not zerg-saving-for-expand?)
                (not (building-present-or-pending? 'roach-warren))
                (or (plan-wants-now? 'roach-warren)
                    (>= supply-used 26)
                    (>= gas 80)
                    (>= total-workers SC2-PRIORITY-WORKERS-PER-BASE))
                (>= minerals (sc2-min-cost 'roach-warren))
                (non-combat-min-ok? (sc2-min-cost 'roach-warren)))
       (emit-build-verified! 'roach-warren (safe-coord (+ base-x 4.0)) (safe-coord (- base-y 4.0))))

     ;; Baneling Nest only requires Spawning Pool (not Lair!)
     (when (and (memq 'spawning-pool ready-bldg-types)
                (not zerg-saving-for-expand?)
                (not (building-present-or-pending? 'baneling-nest))
                (or (plan-wants-now? 'baneling-nest)
                    (>= supply-used 36)
                    (memq 'lair ready-bldg-types)
                    (memq 'hive ready-bldg-types))
                (>= minerals (sc2-min-cost 'baneling-nest))
                (>= gas (sc2-gas-cost 'baneling-nest))
                (non-combat-min-ok? (sc2-min-cost 'baneling-nest))
                (non-combat-gas-ok? (sc2-gas-cost 'baneling-nest)))
       (emit-build-verified! 'baneling-nest (safe-coord (+ base-x 3.0)) (safe-coord (- base-y 3.0))))

     (when (and (memq 'roach-warren ready-bldg-types)
                (memq 'roach unit-types)
                (not zerg-saving-for-expand?)
                (or (not live-game?)
                    (< (hash-ref unit-counts 'ravager 0)
                       (max 2 (quotient (max 1 (hash-ref unit-counts 'roach 0)) 2))))
                (can-spend-by-priority? 'ravager 'combat-unit)
                (>= minerals (sc2-min-cost 'ravager))
                (>= gas (sc2-gas-cost 'ravager)))
       (emit! '(morph ravager))
       (spend-resources-and-supply! (sc2-min-cost 'ravager) (sc2-gas-cost 'ravager) 0))

     (when (and (memq 'spawning-pool ready-bldg-types)
                (not zerg-saving-for-expand?)
                (or (not live-game?)
                    (>= supply-used 42)
                    (plan-wants-now? 'lair)
                    (memq 'roach-warren bldg-types))
                (>= minerals (sc2-min-cost 'lair))
                (>= gas (sc2-gas-cost 'lair))
                (non-combat-min-ok? (sc2-min-cost 'lair))
                (non-combat-gas-ok? (sc2-gas-cost 'lair))
                (not (building-present-or-pending? 'lair))
                (not (building-present-or-pending? 'hive)))
       (recall-building-group! 4)
       (emit! '(morph lair))
       (order-ledger-record-issued! oledger (+ 820000 (modulo frame 10000)) 'morph 'lair base-x base-y frame)
       (spend-resources-and-supply! (sc2-min-cost 'lair) (sc2-gas-cost 'lair) 0))

     (when (and (memq 'spawning-pool ready-bldg-types)
                (not zerg-saving-for-expand?)
                (>= minerals (+ (sc2-min-cost 'spine-crawler) (sc2-min-cost 'roach-warren)))
                (non-combat-min-ok? (sc2-min-cost 'spine-crawler))
                (not (building-present-or-pending? 'spine-crawler))
                (or under-early-cheese? (>= total-workers SC2-IDEAL-WORKERS-PER-BASE)))
       (emit-build-verified! 'spine-crawler nat-x nat-y 2.0))

     (when (and (memq 'spawning-pool ready-bldg-types)
                (not zerg-saving-for-expand?)
                (or (plan-wants-now? 'evolution-chamber)
                    (>= supply-used 36))
                (not (building-present-or-pending? 'evolution-chamber))
                (>= minerals (sc2-min-cost 'evolution-chamber))
                (non-combat-min-ok? (sc2-min-cost 'evolution-chamber)))
       (emit-build-verified! 'evolution-chamber (safe-coord (+ base-x 3.0)) (safe-coord (- base-y 4.0))))

     (when (memq 'evolution-chamber ready-bldg-types)
       (cond
         [(upgrade-needed? 'zerg-missile-weapons-1)
          (emit-research-verified! 'zerg-missile-weapons-1)]
         [(upgrade-needed? 'zerg-ground-armor-1)
          (emit-research-verified! 'zerg-ground-armor-1)]
         [(and (or (memq 'lair ready-bldg-types) (memq 'hive ready-bldg-types))
               (upgrade-needed? 'zerg-missile-weapons-2))
          (emit-research-verified! 'zerg-missile-weapons-2)]
         [(and (or (memq 'lair ready-bldg-types) (memq 'hive ready-bldg-types))
               (upgrade-needed? 'zerg-ground-armor-2))
          (emit-research-verified! 'zerg-ground-armor-2)]
         [(and (memq 'hive ready-bldg-types)
               (upgrade-needed? 'zerg-missile-weapons-3))
          (emit-research-verified! 'zerg-missile-weapons-3)]
         [(and (memq 'hive ready-bldg-types)
               (upgrade-needed? 'zerg-ground-armor-3))
          (emit-research-verified! 'zerg-ground-armor-3)]))

     (when (or (memq 'lair ready-bldg-types) (memq 'hive ready-bldg-types))
       (when (and (upgrade-needed? 'burrow)
                  (>= minerals (sc2-min-cost 'burrow))
                  (>= gas (sc2-gas-cost 'burrow)))
         (emit-research-verified! 'burrow))
       (when (memq 'roach-warren ready-bldg-types)
         (cond
           [(upgrade-needed? 'glial-reconstitution)
            (emit-research-verified! 'glial-reconstitution)]
           [(upgrade-needed? 'tunneling-claws)
            (emit-research-verified! 'tunneling-claws)]))
       (when (and (memq 'baneling-nest ready-bldg-types)
                  (upgrade-needed? 'centrifical-hooks))
         (emit-research-verified! 'centrifical-hooks))
       (when (and (not (building-present-or-pending? 'spire))
                  (>= minerals (sc2-min-cost 'spire))
                  (>= gas (sc2-gas-cost 'spire)))
         (emit-build-verified! 'spire (safe-coord (+ base-x 5.0)) (safe-coord (+ base-y 4.0))))
       (when (and (not (building-present-or-pending? 'hydralisk-den))
                  (>= minerals (sc2-min-cost 'hydralisk-den))
                  (>= gas (sc2-gas-cost 'hydralisk-den)))
         (emit-build-verified! 'hydralisk-den (safe-coord (+ base-x 4.0)) (safe-coord (+ base-y 5.0))))
       (when (memq 'hydralisk-den ready-bldg-types)
         (cond
           [(upgrade-needed? 'grooved-spines)
            (emit-research-verified! 'grooved-spines)]
           [(upgrade-needed? 'muscular-augments)
            (emit-research-verified! 'muscular-augments)]))
       (when (and (memq 'infestation-pit ready-bldg-types)
                  (upgrade-needed? 'neural-parasite))
         (emit-research-verified! 'neural-parasite))
       (when (and (memq 'hive ready-bldg-types)
                  (memq 'spawning-pool ready-bldg-types)
                  (upgrade-needed? 'zergling-attackspeed))
         (emit-research-verified! 'zergling-attackspeed))
       (when (and (memq 'ultralisk-cavern ready-bldg-types)
                  (upgrade-needed? 'chitinous-plating))
         (emit-research-verified! 'chitinous-plating))
       (when (and (memq 'hydralisk-den ready-bldg-types)
                  (not (building-present-or-pending? 'lurker-den))
                  (not (memq 'lurker-den-mp bldg-types))
                  (>= minerals (sc2-min-cost 'lurker-den))
                  (>= gas (sc2-gas-cost 'lurker-den)))
         (emit-build-verified! 'lurker-den (safe-coord (+ base-x 5.0)) (safe-coord (- base-y 5.0))))
       (when (and (or (memq 'lurker-den ready-bldg-types)
                      (memq 'lurker-den-mp ready-bldg-types)
                      (and (not live-game?) (memq 'hydralisk-den ready-bldg-types)))
                  (>= gas (sc2-gas-cost 'adaptive-talons))
                  (upgrade-needed? 'adaptive-talons))
         (emit-research-verified! 'adaptive-talons))
       (when (and (or (memq 'lurker-den ready-bldg-types)
                      (memq 'lurker-den-mp ready-bldg-types))
                  (memq 'hive ready-bldg-types)
                  (>= gas (sc2-gas-cost 'seismic-spines))
                  (upgrade-needed? 'seismic-spines))
         (emit-research-verified! 'seismic-spines)))

     ;; Cloaked / Air / Spore defense & Overseer morph
     (define enemy-cloaked-or-air?
       (ormap (lambda (e)
                (or (hash-ref e 'cloaked #f)
                    (hash-ref e 'burrowed #f)
                    (memq (unit-type-sym e)
                          '(banshee dark-templar ghost lurker mutalisk void-ray carrier oracle))))
              enemy-units))
     (when (or enemy-cloaked-or-air? (and (not live-game?) (memq 'spire bldg-types)))
       (when (and (or (not live-game?) (not (building-present-or-pending? 'spore-crawler)))
                  (refractory-allow-action?! cd-tracker
                                             (list 'static-detector 'spore-crawler)
                                             frame
                                             SC2-STATIC-DETECTOR-COOLDOWN-FRAMES))
         (if live-game?
             (emit-build-verified! 'spore-crawler (safe-coord (+ base-x 3.0)) (safe-coord (+ base-y 3.0)))
             (emit! (list 'build 'spore-crawler (safe-coord (+ base-x 3.0)) (safe-coord (+ base-y 3.0))))))
       (when (or (not live-game?) (not (memq 'overseer unit-types)))
         (emit! '(morph overseer))))

     ;; Overseer Changeling scout (Pro Mechanic #5)
     (define overseers (filter (lambda (u) (eq? (unit-type-sym u) 'overseer)) ally-units))
     (for ([ov (in-list overseers)])
       (when (>= (hash-ref ov 'energy SC2-OVERSEER-CHANGELING-ENERGY) SC2-OVERSEER-CHANGELING-ENERGY)
         (emit! (list 'cast (hash-ref ov 'id 190) 'spawn-changeling enemy-x enemy-y))))

     (when (or (and (memq 'spire ready-bldg-types) (memq 'hydralisk-den ready-bldg-types))
               (and (or (memq 'lurker-den ready-bldg-types) (memq 'lurker-den-mp ready-bldg-types))
                    (memq 'hydralisk unit-types)
                    (>= minerals (sc2-min-cost 'lurker))
                    (>= gas (sc2-gas-cost 'lurker))))
       (emit! '(morph lurker)))
     (when (and (memq 'spire ready-bldg-types) (memq 'hydralisk-den ready-bldg-types))
       (emit! '(morph hive)))
     (when (and (memq 'greater-spire ready-bldg-types)
                (memq 'corruptor unit-types)
                (>= minerals (sc2-min-cost 'brood-lord))
                (>= gas (sc2-gas-cost 'brood-lord)))
       (emit! '(morph brood-lord)))

     ;; 5. Zerg Worker Saturation Priority vs Combat Unit Training (via Control Group 4 Larvae)
     (define zerg-ideal-worker-cap
       (min 80 (* SC2-IDEAL-WORKERS-PER-BASE (max 1 (length hatcheries)))))
     (define zerg-drone-priority?
       (and (or (not zerg-saving-for-expand?)
                (and (< total-workers 16) (< minerals 250)))
            (not urgent-combat-or-intel-need?)
            (or (< total-workers zerg-ideal-worker-cap)
                (can-spend-by-priority? 'drone 'worker))
            (< total-workers (min 80 (max target-workers zerg-ideal-worker-cap)))
            (or (not live-game?)
                (and (not under-base-attack?) (<= live-enemy-threat-supply 0))
                (< total-workers 19)
                (not (memq 'spawning-pool ready-bldg-types))
                (>= (length ally-combat-units) 4)
                (>= live-army-supply (* 6 (max 1 (length hatcheries)))))
            (>= minerals (sc2-min-cost 'drone))
            (can-spend-supply? (sc2-supply-cost 'drone))
            (not under-early-cheese?)
            (< (hash-ref pressure-metrics 'threat-pressure 0.0) 0.75)))
     (when zerg-drone-priority?
       (try-train-unit! 'drone 'larva 4
                        #:respect-bo-reserve?
                        (and live-game?
                             (or (>= total-workers zerg-ideal-worker-cap)
                                 (and (>= total-workers 16)
                                      (> bo-reserved-gas 0)
                                      (>= gas bo-reserved-gas)))
                             (not (memq bo-goal-sym '(hatchery nexus command-center drone probe scv))))))

     ;; Zerg Combat Unit Training (via Control Group 4 Townhalls / Larvae, gated by `open-prod-slots`)
     (unless zerg-saving-for-expand?
       ;; Decoupled Baneling morph: morph Zerglings into Banelings whenever Baneling Nest is ready,
       ;; even after Roach Warren, Hydralisk Den, or Spire is completed.
       (when (and (memq 'baneling-nest ready-bldg-types)
                  (memq 'zergling unit-types)
                  (< (hash-ref unit-counts 'baneling 0)
                     (max 4 (quotient (max 1 (hash-ref unit-counts 'zergling 0)) 2)))
                  (>= minerals (sc2-min-cost 'baneling))
                  (>= gas (sc2-gas-cost 'baneling)))
         (emit! '(morph baneling))
         (spend-resources-and-supply! (sc2-min-cost 'baneling) (sc2-gas-cost 'baneling) 0))
       (define zerg-needs-queen-or-warren-minerals?
         (and live-game?
              (not under-base-attack?)
              (<= live-enemy-threat-supply 0)
              (>= live-army-supply 4)
              (or (< (+ (length queens) (order-ledger-pending-count-for-type oledger 'queen frame))
                     (length hatcheries))
                  (and (>= gas 80)
                       (not (building-present-or-pending? 'roach-warren))))))
       (cond
         [(and (memq 'spire ready-bldg-types)
               (>= minerals (sc2-min-cost 'corruptor))
               (>= gas (sc2-gas-cost 'corruptor)))
          (try-train-unit! 'corruptor 'larva 4 #:respect-bo-reserve? #t)
          (try-train-unit! 'mutalisk 'larva 4 #:respect-bo-reserve? #t)
          (when (memq 'hydralisk-den ready-bldg-types)
            (try-train-unit! 'hydralisk 'larva 4 #:respect-bo-reserve? #t))]
         [(and (memq 'hydralisk-den ready-bldg-types)
               (>= minerals (sc2-min-cost 'hydralisk))
               (>= gas (sc2-gas-cost 'hydralisk)))
          (try-train-unit! 'hydralisk 'larva 4 #:respect-bo-reserve? #t)
          (when (and (memq 'roach-warren ready-bldg-types)
                     (can-spend-by-priority? 'roach 'combat-unit))
            (try-train-unit! 'roach 'larva 4 #:respect-bo-reserve? #t))]
         [(and (memq 'roach-warren ready-bldg-types)
               (>= minerals (sc2-min-cost 'roach))
               (>= gas (sc2-gas-cost 'roach)))
          (try-train-unit! 'roach 'larva 4 #:respect-bo-reserve? #t)
          (when (and (memq 'spawning-pool ready-bldg-types)
                     (not zerg-needs-queen-or-warren-minerals?)
                     (or (< gas (sc2-gas-cost 'roach)) (>= minerals 200))
                     (can-spend-by-priority? 'zergling 'combat-unit))
            (try-train-unit! 'zergling 'larva 4 #:respect-bo-reserve? #t))]
         [(and (memq 'spawning-pool ready-bldg-types)
               (or (not zerg-needs-queen-or-warren-minerals?)
                   (>= minerals (+ (sc2-min-cost 'queen) (sc2-min-cost 'zergling))))
               (can-spend-by-priority? 'zergling 'combat-unit)
               (>= minerals (sc2-min-cost 'zergling))
               (or under-early-cheese?
                   urgent-combat-or-intel-need?
                   (>= (hash-ref pressure-metrics 'threat-pressure 0.0) 0.35)
                   (>= total-workers (add1 SC2-PRIORITY-WORKERS-PER-BASE))
                   (< (length ally-combat-units) SC2-ATTACK-WAVE-MIN-COMBAT-UNITS)
                   (>= minerals (sc2-min-cost 'queen))))
          (try-train-unit! 'zergling 'larva 4 #:respect-bo-reserve? #t)]))

     (when (and (not zerg-drone-priority?)
                (not zerg-saving-for-expand?)
                (can-spend-by-priority? 'drone 'worker)
                (< total-workers
                   (if live-game?
                       (min 80 (max target-workers zerg-ideal-worker-cap))
                       target-workers))
                (or (member '(train drone) prio-scheduled-actions)
                    (< (hash-ref pressure-metrics 'threat-pressure 0.0) 1.0)))
       (try-train-unit! 'drone 'larva 4))]

    [(Protoss)
     ;; 1. Pro Mechanic #6: Dynamic 11-Structure Chrono Boost Target Shifting (only ready buildings)
     (define nexuses (filter (lambda (b) (eq? (unit-type-sym b) 'nexus)) ally-bldgs))
     (define ready-nexuses (filter (lambda (b) (eq? (unit-type-sym b) 'nexus)) ready-bldgs))
     (define assimilators (filter (lambda (b) (eq? (unit-type-sym b) 'assimilator)) ally-bldgs))
     (define gateways
       (filter (lambda (b) (memq (unit-type-sym b) '(gateway warp-gate))) ally-bldgs))
     (define chrono-claimed-ids (mutable-seteqv))
     (define (eligible-live-chrono-target? b)
       (and (hash-ref b 'busy? #f)
            (not (memq 'chrono-boost (hash-ref b 'buffs '())))
            (not (set-member? chrono-claimed-ids (hash-ref b 'id -1)))))
     (for ([nx (in-list ready-nexuses)])
       (when (>= (hash-ref nx 'energy SC2-NEXUS-CHRONO-BOOST-ENERGY) SC2-NEXUS-CHRONO-BOOST-ENERGY)
         (define nx-id (hash-ref nx 'id 201))
         (define chrono-target
           (if live-game?
               (or (and (< total-workers 38)
                        (findf eligible-live-chrono-target? ready-nexuses))
                   (for/or ([prio-type (in-list PRO-CHRONO-11-STRUCTURES)])
                     (findf (lambda (b)
                              (and (eq? (unit-type-sym b) prio-type)
                                   (eligible-live-chrono-target? b)))
                            ready-bldgs)))
               (if (and (< total-workers SC2-EARLY-CHRONO-MAX-WORKERS)
                        (< frame SC2-EARLY-CHRONO-NEXUS-MAX-FRAME))
                   nx
                   (or (for/or ([prio-type (in-list PRO-CHRONO-11-STRUCTURES)]
                                #:when (not (eq? prio-type 'nexus)))
                         (findf (lambda (b) (eq? (unit-type-sym b) prio-type)) ready-bldgs))
                       nx))))
         (when chrono-target
           (define ct-id (hash-ref chrono-target 'id nx-id))
           (set-add! chrono-claimed-ids ct-id)
           (emit! (list 'cast-spell nx-id 'chrono-boost ct-id)))))

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
       (cortex-steal-control-group! cortex 2 (list dg-id)))

     ;; 3. Pro Build-Order Expansion Sequencing (19 Nexus -> 60 3rd Nexus -> 4th+ Nexus)
     (when (and (>= minerals (sc2-min-cost 'nexus))
                (non-combat-min-ok? (sc2-min-cost 'nexus))
                (not under-early-cheese?)
                (not under-base-attack?)
                (not natural-blocked?)
                (= (order-ledger-pending-count-for-type oledger 'nexus frame) 0)
                (or (< (length nexuses) SC2-MIN-DESIRED-BASES)
                    (and (= (length nexuses) 2)
                         (>= supply-used 60)
                         (or (not live-game?) (>= live-army-supply 20))
                         (memq 'robotics-facility bldg-types))
                    (and (< (length nexuses) desired-bases)
                         (>= total-workers (* (length nexuses)
                                              (if (>= (length nexuses) 3) 18 SC2-MIN-WORKERS-PER-BASE-FOR-EXPAND)))
                         (or (not live-game?) (>= live-army-supply (* 10 (length nexuses))))
                         (or (coupled-macro-plan-should-expand? macro-plan)
                             (>= frame SC2-MACRO-EXPAND-FRAME-THRESHOLD))))
                (refractory-allow-action?! cd-tracker
                                           (list 'macro-expand 'Protoss)
                                           frame
                                           SC2-EXPANSION-COOLDOWN-FRAMES))
       (define exp-x (if (>= (length nexuses) SC2-MIN-DESIRED-BASES) third-x nat-x))
       (define exp-y (if (>= (length nexuses) SC2-MIN-DESIRED-BASES) third-y nat-y))
       (emit! (list 'expand exp-x exp-y))
       (order-ledger-record-issued! oledger (+ 810000 (modulo frame 10000)) 'expand 'nexus exp-x exp-y frame)
       (spend-resources-and-supply! (sc2-min-cost 'nexus) 0 0))

     (define protoss-saving-for-expand? (saving-for-expansion-now? (length nexuses)))

     ;; 4. Protoss Pro Build-Order Sequencing:
     ;;    14 Pylon -> 16 Gateway -> 16 Assimilator -> 19 Nexus -> 19 CyberCore -> 21 2nd Assimilator
     ;;    -> 22 WarpGate Research -> 23 2x Stalker -> 26 Robotics Facility -> 28 Twilight Council
     ;;    -> 30 2nd & 3rd Gateway -> 34 Immortal + Observer -> 38 Charge -> 48 Forge -> 52 +1 Weapons
     ;;    -> 56 Robotics Bay -> 60 3rd Nexus -> 64 Extended Thermal Lance
     (when (and (null? gateways)
                (not (building-present-or-pending? 'gateway))
                (>= minerals (sc2-min-cost 'gateway)))
       (emit-build-verified! 'gateway (safe-coord (+ base-x 4.0)) (safe-coord (+ base-y 4.0))))

     (define desired-assimilators
       (min (* SC2-GEYSERS-PER-BASE (length nexuses))
            (cond
              [(>= supply-used 54) 4]
              [(>= supply-used 40) 3]
              [(or (memq 'cybernetics-core bldg-types) (>= total-workers SC2-MIN-WORKERS-FOR-SECOND-GAS)) 2]
              [else 1])))
     (when (and (or (memq 'gateway bldg-types) (memq 'warp-gate bldg-types))
                (or (null? assimilators) (not protoss-saving-for-expand?))
                (< (+ (length assimilators) (order-ledger-pending-count-for-type oledger 'assimilator frame))
                   desired-assimilators)
                (>= minerals (sc2-min-cost 'assimilator))
                (non-combat-min-ok? (sc2-min-cost 'assimilator)))
       (emit-gas-build-verified! 'assimilator (safe-coord (+ base-x 4.0)) (safe-coord (+ base-y 4.0))))

     (when (and (or (memq 'gateway ready-bldg-types) (memq 'warp-gate ready-bldg-types))
                (not protoss-saving-for-expand?)
                (not (building-present-or-pending? 'cybernetics-core))
                (>= minerals (sc2-min-cost 'cybernetics-core))
                (non-combat-min-ok? (sc2-min-cost 'cybernetics-core)))
       (emit-build-verified! 'cybernetics-core (safe-coord (+ base-x 6.0)) (safe-coord (+ base-y 4.0))))

     ;; Research WarpGate at Cybernetics Core; in live games keep Gateways unmorphed (`Gateway` 62)
     ;; so `sc2-unit-orders` accurately tracks busy production slots without WarpGate cooldown blindness
     (when (memq 'cybernetics-core ready-bldg-types)
       (when (and (not protoss-saving-for-expand?)
                  (non-combat-min-ok? (sc2-min-cost 'warp-gate-research))
                  (non-combat-gas-ok? (sc2-gas-cost 'warp-gate-research))
                  (upgrade-needed? 'warp-gate-research)
                  (upgrade-needed? 'warpgate))
         (emit-research-verified! 'warp-gate-research))
       (when (and (not live-game?)
                  (or (memq 'warpgate researched-upgs)
                      (memq 'warp-gate-research researched-upgs))
                  (memq 'gateway ready-bldg-types))
         (emit! '(morph warp-gate))))

     ;; Build Robotics Facility at 26+ supply (or once CyberCore is ready and not saving for expansion)
     (when (and (memq 'cybernetics-core ready-bldg-types)
                (not protoss-saving-for-expand?)
                (not (building-present-or-pending? 'robotics-facility))
                (>= minerals (sc2-min-cost 'robotics-facility))
                (>= gas (sc2-gas-cost 'robotics-facility))
                (non-combat-min-ok? (sc2-min-cost 'robotics-facility))
                (non-combat-gas-ok? (sc2-gas-cost 'robotics-facility)))
       (emit-build-verified! 'robotics-facility (safe-coord (+ base-x 6.0)) (safe-coord (+ base-y 6.0)))
       (unless live-game?
         (emit! '(morph warp-gate))))

     ;; Build Twilight Council at 28+ supply after Robotics Facility is started (Pro Build Order step 11)
     (when (and (memq 'cybernetics-core ready-bldg-types)
                (not protoss-saving-for-expand?)
                (building-present-or-pending? 'robotics-facility)
                (not (building-present-or-pending? 'twilight-council))
                (>= supply-used 28)
                (>= minerals (sc2-min-cost 'twilight-council))
                (>= gas (sc2-gas-cost 'twilight-council))
                (non-combat-min-ok? (sc2-min-cost 'twilight-council))
                (non-combat-gas-ok? (sc2-gas-cost 'twilight-council)))
       (emit-build-verified! 'twilight-council (safe-coord (+ base-x 6.0)) (safe-coord (- base-y 4.0))))

     (when (and (memq 'twilight-council ready-bldg-types)
                (not urgent-combat-or-intel-need?))
       (cond
         [(upgrade-needed? 'charge)
          (emit-research-verified! 'charge)]
         [(upgrade-needed? 'blink)
          (emit-research-verified! 'blink)]
         [(upgrade-needed? 'resonating-glaives)
          (emit-research-verified! 'resonating-glaives)]))

     ;; Priority Robotics Facility production (Group 6): First Immortal -> Observer (if none) -> Colossus / Disruptor -> Immortal
     (when (and (not protoss-saving-for-expand?)
                (memq 'robotics-facility ready-bldg-types)
                (can-spend-supply? (sc2-supply-cost 'observer)))
       (when (and (not (memq 'observer unit-types))
                  (= (order-ledger-pending-count-for-type oledger 'observer frame) 0)
                  (or (not live-game?) (memq 'immortal unit-types)))
         (try-train-unit! 'observer 'robotics-facility 6))
       (when (and (or (memq 'robotics-bay ready-bldg-types)
                      (memq 'robotics-support-bay ready-bldg-types))
                  (can-spend-supply? (sc2-supply-cost 'colossus)))
         (try-train-unit! 'colossus 'robotics-facility 6))
       (when (and (or (memq 'robotics-bay ready-bldg-types)
                      (memq 'robotics-support-bay ready-bldg-types))
                  (< (hash-ref unit-counts 'disruptor 0) 2)
                  (or (member '(train disruptor) prio-scheduled-actions)
                      (>= (hash-ref unit-counts 'colossus 0) 1))
                  (can-spend-supply? (sc2-supply-cost 'disruptor)))
         (try-train-unit! 'disruptor 'robotics-facility 6))
       (when (can-spend-supply? (sc2-supply-cost 'immortal))
         (try-train-unit! 'immortal 'robotics-facility 6)))

     ;; Stargate + Fleet Beacon Carrier & Oracle production (Group 5)
     (when (and (not protoss-saving-for-expand?)
                (memq 'stargate ready-bldg-types))
       (when (and (memq 'fleet-beacon ready-bldg-types)
                  (can-spend-supply? (sc2-supply-cost 'carrier)))
         (try-train-unit! 'carrier 'stargate 5))
       (when (and (or (< (hash-ref unit-counts 'oracle 0) 1)
                      (and (< (hash-ref unit-counts 'oracle 0) 2)
                           (>= minerals 200)
                           (>= gas 200)))
                  (can-spend-supply? (sc2-supply-cost 'oracle)))
         (try-train-unit! 'oracle 'stargate 5)))

     ;; Scale Gateways according to Pro Build Order (3->5 Gateways on 2 bases after CyberCore, up to 8 on 3+ bases),
     ;; governed by the general Braun-heap priority scheduler (`can-spend-by-priority?`) and natural Nexus reserve.
     (define pending-nexus-count
       (order-ledger-pending-count-for-type oledger 'nexus frame))
     (define protoss-nat-reserve
       (if live-game?
           (compute-natural-expansion-mineral-reserve
            #:race 'Protoss
            #:frame frame
            #:active-bases (length nexuses)
            #:pending-bases pending-nexus-count
            #:workers total-workers
            #:under-attack? under-base-attack?
            #:enemy-threat-supply live-enemy-threat-supply
            #:natural-blocked? natural-blocked?
            #:escrow-expired? (or (>= cur-escrow-age-frames max-escrow-timeout-frames)
                                  urgent-combat-or-intel-need?
                                  (not (null? orphaned-prereqs))))
           0))
     (define desired-gateways
       (min SC2-MAX-PRODUCTION-FACILITIES
            (max 1 (cond
                     [(>= (length nexuses) 3)
                      (* SC2-PROTOSS-FACILITIES-PER-BASE (length nexuses))]
                     [(= (length nexuses) 2)
                      (cond
                        [(>= total-workers 42) 5]
                        [(>= supply-used 36) 4]
                        [else 3])]
                     [(and (memq 'cybernetics-core bldg-types)
                           (or (not live-game?)
                               (<= protoss-nat-reserve 0)
                               (>= (- minerals protoss-nat-reserve) (sc2-min-cost 'gateway))))
                      2]
                     [else 1]))))
     (when (and (not protoss-saving-for-expand?)
                (or (< (length gateways) 1)
                    (not live-game?)
                    (can-spend-by-priority? 'gateway 'production-scaling))
                (>= (length gateways) 1)
                (< (+ (length gateways) (order-ledger-pending-count-for-type oledger 'gateway frame))
                   desired-gateways)
                (or (memq 'cybernetics-core bldg-types)
                    (>= minerals SC2-SURPLUS-MINERAL-BANK-THRESHOLD))
                (>= (- minerals protoss-nat-reserve) (sc2-min-cost 'gateway))
                (non-combat-min-ok? (sc2-min-cost 'gateway)))
       (define gw-idx (length gateways))
       (emit-build-verified! 'gateway
                             (safe-coord (+ base-x 4.0 (* 3.5 (modulo gw-idx 3))))
                             (safe-coord (+ base-y 4.0 (* 3.5 (quotient gw-idx 3))))))

     ;; Pro Build Order Step 19-22: Forge at >= 46 supply, Robotics Bay at >= 54 supply, Templar Archives when gas >= 250
     (when (and (memq 'robotics-facility ready-bldg-types)
                (not protoss-saving-for-expand?)
                (can-spend-by-priority? 'forge 'tech-upgrade)
                (not (building-present-or-pending? 'forge))
                (>= (length nexuses) SC2-MIN-DESIRED-BASES)
                (or (not live-game?) (>= supply-used 46))
                (>= minerals (sc2-min-cost 'forge))
                (non-combat-min-ok? (sc2-min-cost 'forge)))
       (emit-build-verified! 'forge (safe-coord (+ base-x 5.0)) (safe-coord (- base-y 4.0))))

     (when (and (memq 'forge ready-bldg-types)
                (not urgent-combat-or-intel-need?))
       (cond
         [(and (can-spend-by-priority? 'protoss-ground-weapons-1 'tech-upgrade)
               (upgrade-needed? 'protoss-ground-weapons-1))
          (emit-research-verified! 'protoss-ground-weapons-1)]
         [(upgrade-needed? 'protoss-ground-armor-1)
          (emit-research-verified! 'protoss-ground-armor-1)]
         [(and (memq 'twilight-council ready-bldg-types)
               (upgrade-needed? 'protoss-ground-weapons-2))
          (emit-research-verified! 'protoss-ground-weapons-2)]
         [(and (memq 'twilight-council ready-bldg-types)
               (upgrade-needed? 'protoss-ground-armor-2))
          (emit-research-verified! 'protoss-ground-armor-2)]
         [(upgrade-needed? 'protoss-shields-1)
          (emit-research-verified! 'protoss-shields-1)]))

     (when (and (memq 'twilight-council ready-bldg-types)
                (not protoss-saving-for-expand?)
                (can-spend-by-priority? 'templar-archive 'tech-upgrade)
                (not (building-present-or-pending? 'templar-archive))
                (not (memq 'templar-archives bldg-types))
                (>= (length nexuses) SC2-MIN-DESIRED-BASES)
                (>= gas 250)
                (>= minerals (sc2-min-cost 'templar-archive))
                (non-combat-min-ok? (sc2-min-cost 'templar-archive)))
       (emit-build-verified! 'templar-archive (safe-coord (+ base-x 6.0)) (safe-coord (- base-y 6.0))))

     (when (and (or (memq 'templar-archive ready-bldg-types)
                    (memq 'templar-archives ready-bldg-types))
                (not urgent-combat-or-intel-need?)
                (upgrade-needed? 'psi-storm))
       (emit-research-verified! 'psi-storm))

     (when (and (memq 'robotics-facility ready-bldg-types)
                (can-spend-by-priority? 'robotics-bay 'tech-upgrade)
                (not (building-present-or-pending? 'robotics-bay))
                (not (memq 'robotics-support-bay bldg-types))
                (or (>= supply-used 54)
                    (not (hash-has-key? raw-obs 'mineral-harvesters)))
                (>= minerals (sc2-min-cost 'robotics-bay))
                (>= gas (sc2-gas-cost 'robotics-bay))
                (non-combat-min-ok? (sc2-min-cost 'robotics-bay))
                (non-combat-gas-ok? (sc2-gas-cost 'robotics-bay)))
       (emit-build-verified! 'robotics-bay (safe-coord (+ base-x 7.0)) (safe-coord (+ base-y 7.0)))
       (emit-research-verified! 'protoss-ground-weapons-1)
       (when (refractory-allow-action?! cd-tracker
                                        (list 'static-detector 'photon-cannon)
                                        frame
                                        SC2-STATIC-DETECTOR-COOLDOWN-FRAMES)
         (emit! (list 'build 'photon-cannon nat-x nat-y))))

     (when (and (or (memq 'robotics-bay ready-bldg-types)
                    (memq 'robotics-support-bay ready-bldg-types))
                (not urgent-combat-or-intel-need?))
       (cond
         [(upgrade-needed? 'extended-thermal-lance)
          (emit-research-verified! 'extended-thermal-lance)]
         [(upgrade-needed? 'gravitic-booster)
          (emit-research-verified! 'gravitic-booster)]))

     ;; Morph Archons whenever >= 2 Templars are on the field
     (when (>= (count (lambda (u) (memq (unit-type-sym u) '(high-templar dark-templar))) ally-units) 2)
       (emit! '(morph archon)))

     ;; 5. Protoss Probe Saturation Priority + Facility-Slot-Aware Combat Unit Training
     (define protoss-ideal-worker-cap
       (min 80 (* SC2-IDEAL-WORKERS-PER-BASE (max 1 (length nexuses)))))
     (define protoss-probe-priority?
       (and (or (not protoss-saving-for-expand?)
                (and (< total-workers 19) (< minerals 350)))
            (not urgent-combat-or-intel-need?)
            (or (< total-workers protoss-ideal-worker-cap)
                (can-spend-by-priority? 'probe 'worker))
            (< total-workers (min 80 (max target-workers protoss-ideal-worker-cap)))
            (or (not live-game?)
                (and (not under-base-attack?) (<= live-enemy-threat-supply 0))
                (< total-workers 20)
                (not (or (memq 'gateway ready-bldg-types) (memq 'warp-gate ready-bldg-types)))
                (>= (length ally-combat-units) 3)
                (>= live-army-supply (* 6 (max 1 (length nexuses)))))
            (>= minerals (sc2-min-cost 'probe))
            (can-spend-supply? (sc2-supply-cost 'probe))
            (not under-early-cheese?)
            (< (hash-ref pressure-metrics 'threat-pressure 0.0) 0.85)))
     (when protoss-probe-priority?
       (try-train-unit! 'probe 'townhall 4
                        #:respect-bo-reserve?
                        (and live-game?
                             (or (>= total-workers protoss-ideal-worker-cap)
                                 (and (>= total-workers 16)
                                      (> bo-reserved-gas 0)
                                      (>= gas bo-reserved-gas)))
                             (not (memq bo-goal-sym '(hatchery nexus command-center drone probe scv))))))

     ;; Protoss Gateway / WarpGate Unit Training (Group 5), governed by `can-spend-by-priority?`
     (when (and (not protoss-saving-for-expand?)
                (can-spend-supply? (sc2-supply-cost 'zealot)))
       (cond
         [(memq 'cybernetics-core ready-bldg-types)
          ;; High-gas dump: High Templar -> Archon when Templar Archives ready and floating >= 150 gas
          (when (and (or (memq 'templar-archive ready-bldg-types)
                         (memq 'templar-archives ready-bldg-types))
                     (>= gas (sc2-gas-cost 'high-templar)))
            (try-train-unit! 'high-templar 'gateway 5 #:respect-bo-reserve? #t))
          ;; Guardian Shield aura + gas sink: maintain 1 Sentry after >= 5 Stalkers in live games (up to 2 in tests)
          (when (and (>= gas 125)
                     (>= (length ally-combat-units) 2)
                     (if live-game?
                         (and (>= (count (lambda (u) (eq? (unit-type-sym u) 'stalker)) ally-units) 5)
                              (< (count (lambda (u) (eq? (unit-type-sym u) 'sentry)) ally-units) 1))
                         (< (count (lambda (u) (eq? (unit-type-sym u) 'sentry)) ally-units) 2)))
            (try-train-unit! 'sentry 'gateway 5 #:respect-bo-reserve? #t))
          (when (can-spend-by-priority? 'stalker 'combat-unit)
            (try-train-unit! 'stalker 'gateway 5 #:respect-bo-reserve? #t))
          (when (and (can-spend-by-priority? 'zealot 'combat-unit)
                     (or (< gas (sc2-gas-cost 'stalker))
                         (>= minerals 225)
                         (and (memq 'charge researched-upgs)
                              (< gas 200)
                              (<= (count (lambda (u) (eq? (unit-type-sym u) 'zealot)) ally-units)
                                  (count (lambda (u) (eq? (unit-type-sym u) 'stalker)) ally-units)))))
            (try-train-unit! 'zealot 'gateway 5 #:respect-bo-reserve? #t))]
         [(and (or (memq 'gateway ready-bldg-types) (memq 'warp-gate ready-bldg-types))
               (can-spend-by-priority? 'zealot 'combat-unit))
          (try-train-unit! 'zealot 'gateway 5 #:respect-bo-reserve? #t)]))

     (when (and (not protoss-probe-priority?)
                (not protoss-saving-for-expand?)
                (can-spend-by-priority? 'probe 'worker)
                (< total-workers
                   (if live-game?
                       (min 80 (max target-workers protoss-ideal-worker-cap))
                       target-workers))
                (or (member '(train probe) prio-scheduled-actions)
                    (< (hash-ref pressure-metrics 'threat-pressure 0.0) 1.0)))
       (try-train-unit! 'probe 'townhall 4))]

    [(Terran)
     ;; 1. Orbital Command Morph, MULE Calldown & Scanner Sweep (real mineral-patch-id)
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
               (not (order-ledger-facility-busy? oledger cc frame))
               (>= minerals (sc2-min-cost 'orbital-command))
               (non-combat-min-ok? (sc2-min-cost 'orbital-command)))
          (recall-building-group! 4)
          (emit! (list 'morph cid 'orbital-command))
          (order-ledger-record-issued! oledger cid 'morph 'orbital-command base-x base-y frame)
          (spend-resources-and-supply! (sc2-min-cost 'orbital-command) 0 0)]
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

     (define unmorphed-ready-cc
       (findf (lambda (cc)
                (and (eq? (unit-type-sym cc) 'command-center)
                     (>= (hash-ref cc 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS)
                     (not (= (hash-ref cc 'order-ability-id 0) 1516))
                     (not (order-ledger-facility-busy? oledger cc frame))))
              ccs))
     (define any-unmorphed-ready-cc
       (findf (lambda (cc)
                (and (eq? (unit-type-sym cc) 'command-center)
                     (>= (hash-ref cc 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS)
                     (not (= (hash-ref cc 'order-ability-id 0) 1516))))
              ccs))
     (define terran-saving-for-orbital?
       (and live-game?
            (not (not any-unmorphed-ready-cc))
            (memq 'barracks ready-bldg-types)
            (not under-early-cheese?)
            (not urgent-combat-or-intel-need?)))

     ;; Helper: check whether a grounded Terran production facility already has an attached add-on
     ;; (`has-addon?`, `addon`, `add-on-tag`, or spatial add-on within 1.75 tiles of `(x+2.5, y-0.5)`).
     (define (terran-facility-has-addon? b)
       (or (eq? (hash-ref b 'has-addon? #f) #t)
           (not (not (hash-ref b 'addon #f)))
           (> (hash-ref b 'add-on-tag 0) 0)
           (let ([bx (hash-ref b 'x -999.0)]
                 [by (hash-ref b 'y -999.0)])
             (ormap (lambda (ab)
                      (and (memq (unit-type-sym ab)
                                 '(barracks-techlab barracks-tech-lab barracks-reactor
                                   factory-techlab factory-tech-lab factory-reactor
                                   starport-techlab starport-tech-lab starport-reactor
                                   tech-lab reactor))
                           (<= (dist2d (+ bx SC2-TERRAN-ADDON-OFFSET-X)
                                       (+ by SC2-TERRAN-ADDON-OFFSET-Y)
                                       (hash-ref ab 'x -9999.0)
                                       (hash-ref ab 'y -9999.0))
                               1.75)))
                    ally-bldgs))))

     ;; 2. Pro Mechanic #3: Terran Addon Swap & Orphaned Add-On Reuse (`ActionResult=72` fix)
     (define rax-with-reactor
       (findf (lambda (b)
                (or (eq? (unit-type-sym b) 'barracks-reactor)
                    (and (eq? (unit-type-sym b) 'barracks)
                         (eq? (hash-ref b 'addon #f) 'reactor))))
              ally-bldgs))
     (define fac-needing-addon
       (findf (lambda (b)
                (and (eq? (unit-type-sym b) 'factory)
                     (not (terran-facility-has-addon? b))))
              ally-bldgs))
     (when (and rax-with-reactor fac-needing-addon)
       (emit! (list 'swap-addon
                    (hash-ref rax-with-reactor 'id 704)
                    (hash-ref fac-needing-addon 'id 705))))
     (define addon-swap-acts (plan-terran-addon-swap obs))
     (for ([swap-act (in-list addon-swap-acts)])
       (emit! swap-act))
     (define (facility-being-swapped? b)
       (define bid (hash-ref b 'id -1))
       (ormap (lambda (a)
                (and (pair? a)
                     (eq? (car a) 'terran-addon-swap)
                     (>= (length a) 3)
                     (or (equal? (second a) bid)
                         (equal? (third a) bid))))
              addon-swap-acts))
     (define (grounded-bare-facility sym)
       (findf (lambda (b)
                (and (eq? (unit-type-sym b) sym)
                     (>= (hash-ref b 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS)
                     (not (eq? (hash-ref b 'flying? #f) #t))
                     (not (terran-facility-has-addon? b))
                     (not (facility-being-swapped? b))))
              ally-bldgs))

     ;; 3. Pro Build-Order Expansion Sequencing (20 Command Center -> 52 3rd Command Center -> 4th+ CC)
     (when (and (>= minerals (sc2-min-cost 'command-center))
                (non-combat-min-ok? (sc2-min-cost 'command-center))
                (not under-early-cheese?)
                (not under-base-attack?)
                (not natural-blocked?)
                (= (order-ledger-pending-count-for-type oledger 'command-center frame) 0)
                (or (< (length ccs) SC2-MIN-DESIRED-BASES)
                    (and (= (length ccs) 2)
                         (>= supply-used 50)
                         (memq 'starport bldg-types))
                    (and (< (length ccs) desired-bases)
                         (>= total-workers (* (length ccs)
                                              (if (>= (length ccs) 3) 18 SC2-MIN-WORKERS-PER-BASE-FOR-EXPAND)))
                         (or (coupled-macro-plan-should-expand? macro-plan)
                             (>= frame SC2-MACRO-EXPAND-FRAME-THRESHOLD))))
                (refractory-allow-action?! cd-tracker
                                           (list 'macro-expand 'Terran)
                                           frame
                                           SC2-EXPANSION-COOLDOWN-FRAMES))
       (define exp-x (if (>= (length ccs) SC2-MIN-DESIRED-BASES) third-x nat-x))
       (define exp-y (if (>= (length ccs) SC2-MIN-DESIRED-BASES) third-y nat-y))
       (emit! (list 'expand exp-x exp-y))
       (order-ledger-record-issued! oledger (+ 810000 (modulo frame 10000)) 'expand 'command-center exp-x exp-y frame)
       (spend-resources-and-supply! (sc2-min-cost 'command-center) 0 0))

     (define pending-cc-count
       (order-ledger-pending-count-for-type oledger 'command-center frame))
     (define reserved-expansion-minerals
       (if live-game?
           (compute-natural-expansion-mineral-reserve
            #:race 'Terran
            #:frame frame
            #:active-bases (length ccs)
            #:pending-bases pending-cc-count
            #:workers total-workers
            #:under-attack? under-base-attack?
            #:enemy-threat-supply live-enemy-threat-supply
            #:natural-blocked? natural-blocked?
            #:escrow-expired? (or (>= cur-escrow-age-frames max-escrow-timeout-frames)
                                  urgent-combat-or-intel-need?
                                  (not (null? orphaned-prereqs))))
           0))
     (define terran-saving-for-expand?
       (or (saving-for-expansion-now? (length ccs))
           (and (> reserved-expansion-minerals 0) (< minerals reserved-expansion-minerals))
           (and terran-saving-for-orbital? (< minerals (sc2-min-cost 'orbital-command)))))

     ;; Emergency Bunker Defense under early cheese / heavy base attack (`Match 5115348` Fix A3b)
     (when (and (or under-early-cheese?
                    under-base-attack?
                    (>= live-enemy-threat-supply 6))
                (memq 'barracks bldg-types)
                (not (building-present-or-pending? 'bunker))
                (>= minerals (sc2-min-cost 'bunker)))
       (emit-build-verified! 'bunker
                             (safe-coord (* 0.5 (+ base-x nat-x)) nat-x)
                             (safe-coord (* 0.5 (+ base-y nat-y)) nat-y)))

     ;; 4. Terran Pro Build Order (14 Depot -> 16 Barracks -> 16 Refinery -> 19 Orbital -> 20 CC
     ;;    -> 21 Barracks-TechLab + Factory + Stimpack -> 22 2nd Refinery -> 28 Starport
     ;;    -> 30 Factory-TechLab -> 32 2nd & 3rd Barracks -> 40 Combat Shield -> 44 EngBay -> 48 +1 Weapons)
     (when (and (null? barracks-list)
                (not (building-present-or-pending? 'barracks))
                (>= minerals (sc2-min-cost 'barracks)))
       (define wall-rax (hash-ref terran-ramp-wall 'barracks #f))
       (define rx0 (if (pair? wall-rax) (safe-coord (car wall-rax) (+ base-x 4.0)) (safe-coord (+ base-x 4.0))))
       (define ry0 (if (pair? wall-rax) (safe-coord (cdr wall-rax) (+ base-y 4.0)) (safe-coord (+ base-y 4.0))))
       (emit-build-verified! 'barracks rx0 ry0))

     (define desired-refineries
       (min (* SC2-GEYSERS-PER-BASE (length ccs))
            (cond
              [(>= supply-used 56) 4]
              [(>= supply-used 44) 3]
              [(or (memq 'factory bldg-types) (>= supply-used 22)) 2]
              [else 1])))
     (when (and (memq 'barracks bldg-types)
                (or (null? refineries) (not terran-saving-for-expand?))
                (< (+ (length refineries) (order-ledger-pending-count-for-type oledger 'refinery frame))
                   desired-refineries)
                (or (not live-game?)
                    (< (length refineries) 2)
                    (< gas 150)
                    (>= (- minerals (sc2-min-cost 'refinery)) bo-reserved-min))
                (>= minerals (sc2-min-cost 'refinery))
                (non-combat-min-ok? (sc2-min-cost 'refinery)))
       (emit-gas-build-verified! 'refinery (safe-coord (+ base-x 3.0)) (safe-coord (+ base-y 5.0))))

     (define has-rax-techlab?
       (or (memq 'barracks-techlab bldg-types)
           (memq 'barracks-tech-lab bldg-types)
           (> (order-ledger-pending-count-for-type oledger 'barracks-techlab frame) 0)))
     (define bare-rax-for-tl (grounded-bare-facility 'barracks))
     (when (and bare-rax-for-tl
                (not terran-saving-for-expand?)
                (not has-rax-techlab?)
                (or (not live-game?) (> (hash-ref open-prod-slots 'barracks 0) 0))
                (>= minerals (sc2-min-cost 'barracks-techlab))
                (>= gas (sc2-gas-cost 'barracks-techlab))
                (non-combat-min-ok? (sc2-min-cost 'barracks-techlab))
                (non-combat-gas-ok? (sc2-gas-cost 'barracks-techlab)))
       (define rbx (safe-coord (+ (hash-ref bare-rax-for-tl 'x (+ base-x 4.0)) SC2-TERRAN-ADDON-OFFSET-X) (+ base-x 6.5)))
       (define rby (safe-coord (+ (hash-ref bare-rax-for-tl 'y (+ base-y 4.0)) SC2-TERRAN-ADDON-OFFSET-Y) (+ base-y 3.5)))
       (recall-building-group! 5)
       (emit! (list 'build 'barracks-techlab rbx rby))
       (order-ledger-record-issued! oledger (hash-ref bare-rax-for-tl 'id 303) 'build 'barracks-techlab rbx rby frame)
       (spend-resources-and-supply! (sc2-min-cost 'barracks-techlab) (sc2-gas-cost 'barracks-techlab) 0))

     ;; Research Stimpack -> Combat Shield -> Concussive Shells at Barracks Tech Lab (Group 7)
     ;; Never let Concussive Shells (50G) steal gas or lock the TechLab slot when Stimpack or Combat Shield (100G) is still needed!
     (when (and (or (memq 'barracks-techlab ready-bldg-types)
                    (memq 'barracks-tech-lab ready-bldg-types))
                (not urgent-combat-or-intel-need?))
       (cond
         [(upgrade-needed? 'stimpack)
          (when (and (>= minerals (sc2-min-cost 'stimpack))
                     (>= gas (sc2-gas-cost 'stimpack)))
            (emit-research-verified! 'stimpack))]
         [(upgrade-needed? 'combat-shield)
          (when (and (>= minerals (sc2-min-cost 'combat-shield))
                     (>= gas (sc2-gas-cost 'combat-shield)))
            (emit-research-verified! 'combat-shield))]
         [(and (upgrade-needed? 'concussive-shells)
               (or (not live-game?)
                   (>= (- minerals (sc2-min-cost 'concussive-shells)) bo-reserved-min))
               (>= minerals (sc2-min-cost 'concussive-shells))
               (>= gas (sc2-gas-cost 'concussive-shells)))
          (emit-research-verified! 'concussive-shells)]))

     (when (and (memq 'barracks ready-bldg-types)
                (not terran-saving-for-expand?)
                (not (building-present-or-pending? 'factory))
                (>= (- minerals reserved-expansion-minerals) (sc2-min-cost 'factory))
                (>= gas (sc2-gas-cost 'factory))
                (non-combat-min-ok? (sc2-min-cost 'factory))
                (non-combat-gas-ok? (sc2-gas-cost 'factory)))
       (emit-build-verified! 'factory
                             (safe-coord (+ base-x SC2-TERRAN-FACILITY-STEP-X))
                             (safe-coord (+ base-y SC2-TERRAN-FACILITY-STEP-Y))))

     (define terran-ideal-worker-cap
       (min 80 (* SC2-IDEAL-WORKERS-PER-BASE (max 1 (length ccs)))))
     (define terran-worker-min-floor
       (if (and live-game?
                (>= (length ccs) 2)
                (< total-workers (* 18 (length ccs)))
                (< gas 200)
                (> (hash-ref open-prod-slots 'townhall 0) 0)
                (not under-base-attack?)
                (<= live-enemy-threat-supply 0)
                (not under-early-cheese?)
                (not terran-saving-for-orbital?))
           (sc2-min-cost 'scv)
           0))
     (define desired-barracks
       (min SC2-MAX-PRODUCTION-FACILITIES
            (max 1 (if (>= (+ (length ccs) pending-cc-count) SC2-MIN-DESIRED-BASES)
                       (* SC2-TERRAN-FACILITIES-PER-BASE (max (length ccs) (+ (length ccs) pending-cc-count)))
                       (if (and (memq 'factory bldg-types)
                                (or (not live-game?)
                                    (<= reserved-expansion-minerals 0)
                                    (>= (- minerals reserved-expansion-minerals) (sc2-min-cost 'barracks))))
                           2
                           1)))))
     (when (and (not terran-saving-for-expand?)
                (can-spend-by-priority? 'barracks 'production-scaling)
                (>= (length barracks-list) 1)
                (< (+ (length barracks-list) (order-ledger-pending-count-for-type oledger 'barracks frame))
                   desired-barracks)
                (or (memq 'factory bldg-types)
                    (< gas (sc2-gas-cost 'factory))
                    (>= minerals SC2-SURPLUS-MINERAL-BANK-THRESHOLD))
                (>= (- minerals (+ reserved-expansion-minerals terran-worker-min-floor)) (sc2-min-cost 'barracks))
                (non-combat-min-ok? (sc2-min-cost 'barracks)))
       (define rax-idx (length barracks-list))
       (emit-build-verified! 'barracks
                             (safe-coord (+ base-x 4.0 (* SC2-TERRAN-FACILITY-STEP-X (modulo rax-idx 2))))
                             (safe-coord (+ base-y 4.0 (* SC2-TERRAN-FACILITY-STEP-Y (quotient rax-idx 2))))))

     ;; Build Barracks Reactor on 2nd+ grounded bare Barracks for double Marine production
     (define bare-rax-for-rx (grounded-bare-facility 'barracks))
     (when (and (not terran-saving-for-expand?)
                (>= (length barracks-list) 2)
                bare-rax-for-rx
                (not (building-present-or-pending? 'barracks-reactor))
                (or (not live-game?) (> (hash-ref open-prod-slots 'barracks 0) 0))
                (>= minerals (sc2-min-cost 'barracks-reactor))
                (>= gas (sc2-gas-cost 'barracks-reactor))
                (non-combat-min-ok? (sc2-min-cost 'barracks-reactor))
                (non-combat-gas-ok? (sc2-gas-cost 'barracks-reactor)))
       (define rrx (safe-coord (+ (hash-ref bare-rax-for-rx 'x (+ base-x 8.5)) SC2-TERRAN-ADDON-OFFSET-X) (+ base-x 11.0)))
       (define rry (safe-coord (+ (hash-ref bare-rax-for-rx 'y (+ base-y 4.0)) SC2-TERRAN-ADDON-OFFSET-Y) (+ base-y 3.5)))
       (recall-building-group! 5)
       (emit! (list 'build 'barracks-reactor rrx rry))
       (order-ledger-record-issued! oledger (hash-ref bare-rax-for-rx 'id 304) 'build 'barracks-reactor rrx rry frame)
       (spend-resources-and-supply! (sc2-min-cost 'barracks-reactor) (sc2-gas-cost 'barracks-reactor) 0))

     (define has-fac-techlab-any?
       (or (memq 'factory-techlab bldg-types)
           (memq 'factory-tech-lab bldg-types)
           (> (order-ledger-pending-count-for-type oledger 'factory-techlab frame) 0)))
     (define bare-fac-for-tl (grounded-bare-facility 'factory))
     (when (and (not terran-saving-for-expand?)
                bare-fac-for-tl
                (not has-fac-techlab-any?)
                (or (not live-game?) (> (hash-ref open-prod-slots 'factory 0) 0))
                (>= minerals (sc2-min-cost 'factory-techlab))
                (>= gas (sc2-gas-cost 'factory-techlab))
                (non-combat-min-ok? (sc2-min-cost 'factory-techlab))
                (non-combat-gas-ok? (sc2-gas-cost 'factory-techlab)))
       (define ftx (safe-coord (+ (hash-ref bare-fac-for-tl 'x (+ base-x 6.0)) SC2-TERRAN-ADDON-OFFSET-X) (+ base-x 8.5)))
       (define fty (safe-coord (+ (hash-ref bare-fac-for-tl 'y (+ base-y 3.5)) SC2-TERRAN-ADDON-OFFSET-Y) (+ base-y 3.0)))
       (recall-building-group! 6)
       (emit! (list 'build 'factory-techlab ftx fty))
       (order-ledger-record-issued! oledger (hash-ref bare-fac-for-tl 'id 305) 'build 'factory-techlab ftx fty frame)
       (spend-resources-and-supply! (sc2-min-cost 'factory-techlab) (sc2-gas-cost 'factory-techlab) 0))

     (when (and (not terran-saving-for-expand?)
                (not urgent-combat-or-intel-need?)
                (memq 'factory ready-bldg-types)
                (>= minerals (sc2-min-cost 'starport)))
       (when (and (not (building-present-or-pending? 'starport))
                  (>= minerals (sc2-min-cost 'starport))
                  (>= gas (sc2-gas-cost 'starport)))
         (emit-build-verified! 'starport
                               (safe-coord (+ base-x SC2-TERRAN-FACILITY-STEP-X))
                               (safe-coord (+ base-y (* 2.0 SC2-TERRAN-FACILITY-STEP-Y)))))
       (when (and (not (building-present-or-pending? 'armory))
                  (or (not live-game?) (memq 'engineering-bay bldg-types))
                  (or (plan-wants-now? 'armory) (>= supply-used 52))
                  (>= minerals (sc2-min-cost 'armory))
                  (>= gas (sc2-gas-cost 'armory)))
         (emit-build-verified! 'armory (safe-coord (- base-x 4.0)) (safe-coord (+ base-y 4.0))))
       (when (and (or (not live-game?) (memq 'widow-mine unit-types))
                  (upgrade-needed? 'drilling-claws))
         (emit-research-verified! 'drilling-claws)))

     (define bare-sp-for-tl (grounded-bare-facility 'starport))
     (when (and (not terran-saving-for-expand?)
                (not urgent-combat-or-intel-need?)
                (or (plan-wants-now? 'engineering-bay)
                    (plan-wants-now? 'missile-turret)
                    (memq 'starport ready-bldg-types))
                (>= minerals (sc2-min-cost 'engineering-bay)))
       (when (and (not (building-present-or-pending? 'engineering-bay))
                  (>= minerals (sc2-min-cost 'engineering-bay)))
         (emit-build-verified! 'engineering-bay (safe-coord (+ base-x 5.0)) (safe-coord (- base-y 4.0))))
       (when (and bare-sp-for-tl
                  (not (or (memq 'starport-techlab bldg-types)
                           (memq 'starport-tech-lab bldg-types)
                           (and live-game? (memq 'starport-reactor bldg-types))
                           (> (order-ledger-pending-count-for-type oledger 'starport-techlab frame) 0)))
                  (>= minerals (sc2-min-cost 'starport-techlab))
                  (>= gas (sc2-gas-cost 'starport-techlab)))
         (define stx (safe-coord (+ (hash-ref bare-sp-for-tl 'x (+ base-x 6.0)) SC2-TERRAN-ADDON-OFFSET-X) (+ base-x 8.5)))
         (define sty (safe-coord (+ (hash-ref bare-sp-for-tl 'y (+ base-y 7.0)) SC2-TERRAN-ADDON-OFFSET-Y) (+ base-y 6.5)))
         (recall-building-group! 6)
         (emit! (list 'build 'starport-techlab stx sty))
         (order-ledger-record-issued! oledger (hash-ref bare-sp-for-tl 'id 306) 'build 'starport-techlab stx sty frame)
         (spend-resources-and-supply! (sc2-min-cost 'starport-techlab) (sc2-gas-cost 'starport-techlab) 0))
       (when (memq 'engineering-bay ready-bldg-types)
         (cond
           [(upgrade-needed? 'terran-infantry-weapons-1)
            (emit-research-verified! 'terran-infantry-weapons-1)]
           [(upgrade-needed? 'terran-infantry-armor-1)
            (emit-research-verified! 'terran-infantry-armor-1)]
           [(and (memq 'armory ready-bldg-types)
                 (upgrade-needed? 'terran-infantry-weapons-2))
            (emit-research-verified! 'terran-infantry-weapons-2)]
           [(and (memq 'armory ready-bldg-types)
                 (upgrade-needed? 'terran-infantry-armor-2))
            (emit-research-verified! 'terran-infantry-armor-2)]
           [(and (memq 'armory ready-bldg-types)
                 (upgrade-needed? 'terran-infantry-weapons-3))
            (emit-research-verified! 'terran-infantry-weapons-3)]
           [(and (memq 'armory ready-bldg-types)
                 (upgrade-needed? 'terran-infantry-armor-3))
            (emit-research-verified! 'terran-infantry-armor-3)]))
       (when (memq 'armory ready-bldg-types)
         (cond
           [(upgrade-needed? 'terran-vehicle-weapons-1)
            (emit-research-verified! 'terran-vehicle-weapons-1)]
           [(upgrade-needed? 'terran-vehicle-and-ship-plating-1)
            (emit-research-verified! 'terran-vehicle-and-ship-plating-1)]))
       (when (and (or (memq 'starport-techlab ready-bldg-types)
                      (memq 'starport-tech-lab ready-bldg-types))
                  (upgrade-needed? 'banshee-cloak))
         (emit-research-verified! 'banshee-cloak))
       (when (and (not (building-present-or-pending? 'ghost-academy))
                  (>= supply-used 56)
                  (>= minerals (sc2-min-cost 'ghost-academy))
                  (>= gas (sc2-gas-cost 'ghost-academy)))
         (emit-build-verified! 'ghost-academy (safe-coord (- base-x 4.0)) (safe-coord (- base-y 4.0))))
       (when (and (or (not live-game?)
                      (and (memq 'engineering-bay ready-bldg-types)
                           (not (building-present-or-pending? 'missile-turret))
                           (or (plan-wants-now? 'missile-turret) (>= supply-used 60))))
                  (refractory-allow-action?! cd-tracker
                                             (list 'static-detector 'missile-turret)
                                             frame
                                             SC2-STATIC-DETECTOR-COOLDOWN-FRAMES))
         (if live-game?
             (emit-build-verified! 'missile-turret (safe-coord (+ base-x 3.0)) (safe-coord (+ base-y 3.0)))
             (emit! (list 'build 'missile-turret (safe-coord (+ base-x 3.0)) (safe-coord (+ base-y 3.0))))))
       (when (and (memq 'ghost-academy ready-bldg-types)
                  (upgrade-needed? 'personal-cloaking))
         (emit-research-verified! 'personal-cloaking)))

     (define has-fac-tl?
       (or (memq 'factory-techlab ready-bldg-types)
           (memq 'factory-tech-lab ready-bldg-types)
           (not (hash-has-key? raw-obs 'mineral-harvesters))))

     ;; 5. Terran SCV Saturation Priority + Facility-Slot-Aware Combat Unit Training,
     ;;    governed by the general Braun-heap priority scheduler (`can-spend-by-priority?`).
     (define terran-scv-priority?
       (and (or (not terran-saving-for-expand?)
                (and (not terran-saving-for-orbital?) (< total-workers 19) (< minerals 350)))
            (not terran-saving-for-orbital?)
            (not urgent-combat-or-intel-need?)
            (or (< total-workers terran-ideal-worker-cap)
                (can-spend-by-priority? 'scv 'worker))
            (< total-workers (min 80 (max target-workers terran-ideal-worker-cap)))
            (or (not live-game?)
                (and (not under-base-attack?) (<= live-enemy-threat-supply 0))
                (< total-workers 20)
                (not (memq 'barracks ready-bldg-types))
                (>= (length ally-combat-units) 3)
                (>= live-army-supply (* 6 (max 1 (length ccs)))))
            (>= minerals (sc2-min-cost 'scv))
            (can-spend-supply? (sc2-supply-cost 'scv))
            (not under-early-cheese?)
            (< (hash-ref pressure-metrics 'threat-pressure 0.0) 0.85)))
     (when terran-scv-priority?
       (try-train-unit! 'scv 'townhall 4
                        #:respect-bo-reserve?
                        (and live-game?
                             (or (>= total-workers terran-ideal-worker-cap)
                                 (and (>= total-workers 16)
                                      (> bo-reserved-gas 0)
                                      (>= gas bo-reserved-gas)))
                             (not (memq bo-goal-sym '(hatchery nexus command-center drone probe scv))))))

     ;; Terran Unit Training (dispatched via Building Control Groups 5 [Barracks] & 6 [Factory/Starport],
     ;; gated by `open-prod-slots`, `can-spend-by-priority?`, Orbital 150M reserve, and Pro Build-Order sequence)
     (when (and (not terran-saving-for-expand?)
                (or (not terran-saving-for-orbital?)
                    (>= (- minerals (sc2-min-cost 'marine)) (sc2-min-cost 'orbital-command)))
                (can-spend-supply? (sc2-supply-cost 'marine)))
       ;; Factory production first (Group 6): ensure Siege Tank on Factory-TechLab is never starved or
       ;; slot-locked by Starport Viking or 0G Hellion!
       (when (and (memq 'factory ready-bldg-types)
                  (or (not live-game?) has-fac-techlab-any? (< gas (sc2-gas-cost 'factory-techlab))))
         (if has-fac-tl?
             (try-train-unit! 'siege-tank 'factory 6)
             (try-train-unit! 'widow-mine 'factory 6))
         (when (if live-game?
                   (and (or (not has-fac-tl?) (and (>= minerals 400) (< gas 50)))
                        (< (hash-ref unit-counts 'hellion 0) 4))
                   (or (< gas (sc2-gas-cost 'siege-tank)) (>= minerals 250)))
           (try-train-unit! 'hellion 'factory 6)))
       ;; Starport production (Group 6)
       (when (memq 'starport ready-bldg-types)
         (when (or (not live-game?)
                   (< (hash-ref unit-counts 'medivac 0) 4)
                   (can-spend-by-priority? 'medivac 'combat-unit))
           (try-train-unit! 'medivac 'starport 6 #:respect-bo-reserve? #t))
         (when (or (not live-game?)
                   (enemy-tech-observation-requires-anti-air? tech-obs)
                   (and (>= (hash-ref unit-counts 'medivac 0) 2)
                        (can-spend-by-priority? 'viking 'combat-unit)))
           (try-train-unit! 'viking 'starport 6 #:respect-bo-reserve? #t)))
       ;; Barracks production (Group 5)
       (when (and (memq 'barracks ready-bldg-types)
                  (or (not live-game?) urgent-combat-or-intel-need? has-rax-techlab? (< gas (sc2-gas-cost 'barracks-techlab))))
         (define has-rax-tl-ready?
           (or (memq 'barracks-techlab ready-bldg-types)
               (memq 'barracks-tech-lab ready-bldg-types)
               (not (hash-has-key? raw-obs 'mineral-harvesters))))
         (when (and has-rax-tl-ready? (can-spend-by-priority? 'marauder 'combat-unit))
           (try-train-unit! 'marauder 'barracks 5 #:respect-bo-reserve? #t))
         (when (can-spend-by-priority? 'marine 'combat-unit)
           (try-train-unit! 'marine 'barracks 5 #:respect-bo-reserve? #t))))

     (when (and (not terran-scv-priority?)
                (not terran-saving-for-expand?)
                (not terran-saving-for-orbital?)
                (can-spend-by-priority? 'scv 'worker)
                (< total-workers
                   (if live-game?
                       (min 80 (max target-workers terran-ideal-worker-cap))
                       target-workers))
                (or (member '(train scv) prio-scheduled-actions)
                    (< (hash-ref pressure-metrics 'threat-pressure 0.0) 1.0)))
       (try-train-unit! 'scv 'townhall 4))])

  ;; ---------------------------------------------------------------------------
  ;; Pro Mechanic #7: Camera Bookmark Save (Slots F1..F8 = 1..8)
  ;; ---------------------------------------------------------------------------
  (define cam-bmark-save-acts
    (cortex-sync-camera-bookmarks! cortex obs))
  (for ([ca (in-list cam-bmark-save-acts)])
    (emit! ca))
  (unless (live-bot-runtime-bookmarks-initialized? rt)
    (set-live-bot-runtime-bookmarks-initialized?! rt #t)
    (when (null? cam-bmark-save-acts)
      (cortex-save-camera-bookmark! cortex 1 base-x base-y)
      (emit! (list 'camera-bookmark-save 1 base-x base-y))))

  (define prev-tel (live-bot-runtime-last-telemetry rt))
  (set-live-bot-runtime-last-telemetry!
   rt
   (hash-set* (if (hash? prev-tel) prev-tel (hash))
              'priority-summary prio-summary
              'priority-log-line prio-log-line
              'dynamic-plan dyn-plan
              'dynamic-plan-next-actions
              (if (dynamic-macro-plan? dyn-plan)
                  (map plan-goal-node-next-action-sym (dynamic-macro-plan-actionable-goals dyn-plan))
                  '())
              'dynamic-plan-in-progress
              (if (dynamic-macro-plan? dyn-plan)
                  (dynamic-macro-plan-in-progress-syms dyn-plan)
                  '())
              'peak-supply-reached cur-peak-supply
              'repaired-prereqs repaired-prereqs
              'priority-repaired-prereqs repaired-prereqs
              'scout-worker-id scout-worker-id
              'last-enemy-seen-frame last-enemy-seen-frame
              'last-seen-main-frame last-seen-main-frame
              'last-seen-natural-frame last-seen-natural-frame
              'last-seen-third-frame last-seen-third-frame
              'last-seen-army-frame last-seen-army-frame
              'intel-staleness-frames intel-staleness-frames
              'intel-freshness intel-freshness
              'intel-coverage intel-coverage
              'intel-confidence intel-confidence
              'intel-deficit intel-deficit
              'intel-priority-sector intel-priority-sector
              'intel-target-goal intel-target-goal
              'intel-pressure (hash-ref pressure-metrics 'intel-pressure 0.0)
              'intel-gathering-method active-intel-method
              'remembered-enemy-threat-supply remembered-enemy-threat-supply
              'remembered-enemy-threat-frame remembered-enemy-threat-frame
              'escrow-goal-sym active-escrow-sym
              'escrow-age-frames (if (>= cur-escrow-age-frames max-escrow-timeout-frames) 0 cur-escrow-age-frames)
              'escrow-peak-min (if (>= cur-escrow-age-frames max-escrow-timeout-frames) obs-minerals cur-escrow-peak-min)
              'escrow-prev-min obs-minerals
              'escrow-start-frame (if (>= cur-escrow-age-frames max-escrow-timeout-frames) frame cur-escrow-start-frame)
              'escrow-last-frame frame))

  (reverse actions))

;; =============================================================================
;; Layer 3 & 4: Squad Split (Monoidal Finger Tree), Tactical Micro, Spells,
;;              Transport Juggle & Adversarial Anti-ForceField / Anti-Kite Leash
;; =============================================================================

;; Select the best targetable enemy unit for `attacker-type` within weapon domain
;; (filters out untargetable projectiles/larva/eggs, enforces air/ground weapon
;; domain matching, de-prioritizes passive scouts/decoys/interceptors/broodlings
;; when real threats exist, and prioritizes Light/Bio clumps for Banelings).
(define (select-target-enemy-for-unit ux uy enemy-units [attacker-type 'marine] [ally-has-stealth? #f])
  (define baneling-attacker? (eq? attacker-type 'baneling))
  (define stealth-active?
    (or ally-has-stealth?
        (and (memq attacker-type SC2-CLOAKED-OR-BURROW-STEALTH-SYMS) #t)))
  (define light-bio-syms
    '(marine zergling zealot adept hydralisk probe scv drone reaper hellion sentry high-templar ghost))
  (define armored-syms
    '(marauder roach stalker immortal siege-tank siege-tank-sieged thor ultralisk colossus))
  (let loop ([rem enemy-units]
             [best-valid #f]
             [best-valid-sc +inf.0]
             [best-any (if (null? enemy-units) #f (car enemy-units))]
             [best-any-sc +inf.0])
    (if (null? rem)
        (or best-valid best-any)
        (let* ([e (car rem)]
               [et (unit-type-sym e)]
               [ex (hash-ref e 'x ux)]
               [ey (hash-ref e 'y uy)]
               [eflying? (or (and (hash-ref e 'is-flying #f) #t)
                             (and (hash-ref e 'flying? #f) #t)
                             (and (hash-ref e 'flying #f) #t))]
               [valid? (and (sc2-enemy-unit-targetable? e)
                            (sc2-attacker-can-hit-enemy? attacker-type e eflying?))]
               [changeling-or-detector-adj
                (+ (if (or (memq et SC2-CHANGELING-UNIT-SYMS)
                           (eq? (hash-ref e 'changeling? #f) #t))
                       -220.0
                       0.0)
                   (if (and stealth-active?
                            (or (memq et SC2-MOBILE-DETECTOR-SYMS)
                                (memq et SC2-STATIC-DETECTOR-SYMS)))
                       -180.0
                       0.0))]
               [bane-adj
                (if baneling-attacker?
                    (cond
                      [(memq et light-bio-syms)
                       (define nearby-light
                         (count (lambda (o)
                                  (and (memq (unit-type-sym o) light-bio-syms)
                                       (<= (dist2d ex ey (hash-ref o 'x ex) (hash-ref o 'y ey)) 2.2)))
                                enemy-units))
                       (- (+ 45.0 (* 12.0 nearby-light)))]
                      [(or (memq et armored-syms) (memq et SC2-ALL-STRUCTURE-SYMS))
                       80.0]
                      [else 0.0])
                    0.0)])
          (cond
            [valid?
             (define d (dist2d ux uy ex ey))
             (define hp (safe-finite-real (hash-ref e 'hp 100) 100.0))
             (define passive-penalty
               (+ (if (and (memq et SC2-PASSIVE-SCOUT-OR-DECOY-UNIT-SYMS)
                           (not (and stealth-active? (memq et SC2-MOBILE-DETECTOR-SYMS))))
                      250.0
                      0.0)
                  (if (memq et SC2-ALL-STRUCTURE-SYMS) 30.0 0.0)
                  changeling-or-detector-adj
                  bane-adj))
             (define sc
               (+ passive-penalty
                  (if (<= d SC2-ENGAGEMENT-FOCUS-FIRE-RADIUS)
                      (+ (* 2.0 d) (* 0.05 hp))
                      (+ 100.0 (* 4.0 d) (* 0.02 hp)))))
             (if (< sc best-valid-sc)
                 (loop (cdr rem) e sc best-any best-any-sc)
                 (loop (cdr rem) best-valid best-valid-sc best-any best-any-sc))]
            [(not best-valid)
             (define d (dist2d ux uy ex ey))
             (define hp (safe-finite-real (hash-ref e 'hp 100) 100.0))
             (define passive-penalty
               (+ (if (and (memq et SC2-PASSIVE-SCOUT-OR-DECOY-UNIT-SYMS)
                           (not (and stealth-active? (memq et SC2-MOBILE-DETECTOR-SYMS))))
                      250.0
                      0.0)
                  (if (memq et SC2-ALL-STRUCTURE-SYMS) 30.0 0.0)
                  changeling-or-detector-adj
                  bane-adj))
             (define sc
               (+ passive-penalty
                  (if (<= d SC2-ENGAGEMENT-FOCUS-FIRE-RADIUS)
                      (+ (* 2.0 d) (* 0.05 hp))
                      (+ 100.0 (* 4.0 d) (* 0.02 hp)))))
             (if (< sc best-any-sc)
                 (loop (cdr rem) best-valid best-valid-sc e sc)
                 (loop (cdr rem) best-valid best-valid-sc best-any best-any-sc))]
            [else
             (loop (cdr rem) best-valid best-valid-sc best-any best-any-sc)])))))

(define (step-layer3-and-4-tactics! rt raw-obs fap-score)
  (define obs (sanitize-obs-hash raw-obs))
  (define frame (hash-ref obs 'frame 0))
  (define oledger (live-bot-runtime-order-ledger rt))
  (define tbrain (live-bot-runtime-tactical-brain rt))
  (define ally-units (hash-ref obs 'ally-units '()))
  (define ally-bldgs (hash-ref obs 'ally-buildings '()))
  (define enemy-units (hash-ref obs 'enemy-units '()))
  (define enemy-bldgs (hash-ref obs 'enemy-buildings '()))
  (define effects (hash-ref obs 'effects '()))
  (define live-upgrades-tracked? (hash-has-key? raw-obs 'researched-upgrades))
  (define researched-upgs (hash-ref obs 'researched-upgrades '()))
  (define (has-upgrade? upg-sym)
    (or (not live-upgrades-tracked?)
        (and (memq upg-sym researched-upgs) #t)))
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

  (define combat-units
    (filter (lambda (u)
              (and (combat-unit-record? u)
                   (let ([b (hash-ref u 'buffs '())])
                     (not (and (list? b)
                               (or (memq 'oracle-stasis-trap-target b)
                                   (memq 'stasis-ward-target b)))))))
            ally-units))
  (define ft (perception-grid-squad-finger-tree (live-bot-runtime-perception rt)))
  (define total-dps (combat-measure-dps (ft-measure ft)))
  (define-values (vanguard-ft reserve-ft)
    (split-by-dps ft (exact-ceiling (* 0.70 total-dps))))
  (define vanguard-count (combat-measure-count (ft-measure vanguard-ft)))
  (define reserve-count (combat-measure-count (ft-measure reserve-ft)))

  (define actions '())
  (define (emit! act)
    (order-ledger-record-issued! oledger frame act)
    (set! actions (cons act actions)))

  ;; ---------------------------------------------------------------------------
  ;; Multi-Depth Mirrored Tactical Micro Brain (0.5s, 2.0s, 5.0s Horizons)
  ;; ---------------------------------------------------------------------------
  (define-values (tbrain-actions tbrain-committed-tags _tbrain-decisions)
    (if (and (not (null? combat-units)) (not (null? enemy-units)))
        (step-tactical-mirror-brain! tbrain oledger obs)
        (values '() (set) '())))
  (define tbrain-unit-actions (make-hash))
  (for ([ta (in-list tbrain-actions)])
    (when (and (pair? ta) (>= (length ta) 2) (exact-integer? (second ta)))
      (define uid (second ta))
      (hash-set! tbrain-unit-actions uid
                 (append (hash-ref tbrain-unit-actions uid '()) (list ta)))))

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
  (define live-tactics-obs? (hash-has-key? raw-obs 'mineral-harvesters))
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
    (cond
      [wounded-passenger
       (emit! (list 'transport-juggle tr-id (hash-ref wounded-passenger 'id 707) base-x base-y))]
      [(not live-tactics-obs?)
       (emit! (list 'multi-prong-drop tr-id enemy-x enemy-y))]
      [(not (null? combat-units))
       (define n-cu (length combat-units))
       (define escort-x
         (safe-coord (/ (for/sum ([u (in-list combat-units)]) (hash-ref u 'x nat-x)) n-cu) nat-x))
       (define escort-y
         (safe-coord (/ (for/sum ([u (in-list combat-units)]) (hash-ref u 'y nat-y)) n-cu) nat-y))
       (when (> (dist2d tx ty escort-x escort-y) 6.0)
         (emit! (list 'attack-pos tr-id escort-x escort-y)))]
      [(> (dist2d tx ty nat-x nat-y) 8.0)
       (emit! (list 'attack-pos tr-id nat-x nat-y))]))

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
  ;; Pro Splash & Micro Countermeasures:
  ;;   1. Hostile Ground Effects (`psi-storm`, `corrosive-bile`, `blinding-cloud`) &
  ;;      Enemy `disruptor-phased` (Purification Nova) Emergency Radial Evasion
  ;;   2. Enemy `widow-mine` / `widow-mine-burrowed` Target Pull-Back & Ally Split
  ;;   3. Enemy `baneling` Light-Unit Radial Pre-Split (Armored units hold & fire)
  ;;   4. Enemy `hellion` & `lurker-burrowed` Collinear Lateral Scatter (+/- n-hat)
  ;; ---------------------------------------------------------------------------
  (define splash-evading-tags (mutable-seteqv))

  ;; 1. Emergency Ground-Effect & Purification Nova (`disruptor-phased`) Evasion
  (define hazard-zones
    (append
     (for/list ([eff (in-list effects)]
                #:when (and (hash? eff)
                            (memq (hash-ref eff 'type 'none)
                                  '(psi-storm psionic-storm corrosive-bile blinding-cloud nuke-persistent))))
       (list (hash-ref eff 'x nat-x)
             (hash-ref eff 'y nat-y)
             (safe-finite-real (hash-ref eff 'radius 3.0) 3.0)))
     (for/list ([e (in-list enemy-units)]
                #:when (eq? (unit-type-sym e) 'disruptor-phased))
       (list (hash-ref e 'x nat-x)
             (hash-ref e 'y nat-y)
             4.5))))
  (when (not (null? hazard-zones))
    (for ([u (in-list combat-units)])
      (define uid (hash-ref u 'id 101))
      (define ux (hash-ref u 'x base-x))
      (define uy (hash-ref u 'y base-y))
      (unless (order-ledger-unit-in-attack-swing? oledger u)
        (for ([hz (in-list hazard-zones)]
              #:unless (set-member? splash-evading-tags uid))
          (define hx (first hz))
          (define hy (second hz))
          (define hrad (third hz))
          (when (<= (dist2d ux uy hx hy) hrad)
            (define-values (kx ky) (compute-kite-vector ux uy hx hy 3.5))
            (set-add! splash-evading-tags uid)
            (emit! (list 'kite uid (safe-coord kx ux) (safe-coord ky uy))))))))

  ;; 2. Enemy Widow Mine Target Pull-Back & Nearby Ally Radial Split
  (define enemy-widow-mines
    (filter (lambda (e) (memq (unit-type-sym e) '(widow-mine widow-mine-burrowed)))
            enemy-units))
  (for ([wm (in-list enemy-widow-mines)])
    (define wmx (hash-ref wm 'x nat-x))
    (define wmy (hash-ref wm 'y nat-y))
    (define explicit-target-id (hash-ref wm 'target-id #f))
    (define targeted-ally
      (or (and explicit-target-id
               (findf (lambda (u) (equal? (hash-ref u 'id -1) explicit-target-id)) ally-units))
          (let loop ([rem ally-units] [best-u #f] [best-d 5.3])
            (if (null? rem)
                best-u
                (let* ([u (car rem)]
                       [d (dist2d wmx wmy (hash-ref u 'x base-x) (hash-ref u 'y base-y))])
                  (if (< d best-d)
                      (loop (cdr rem) u d)
                      (loop (cdr rem) best-u best-d)))))))
    (when targeted-ally
      (define tid (hash-ref targeted-ally 'id 101))
      (define tx (hash-ref targeted-ally 'x base-x))
      (define ty (hash-ref targeted-ally 'y base-y))
      (unless (set-member? splash-evading-tags tid)
        (define-values (kx ky) (compute-kite-vector tx ty wmx wmy 3.5))
        (set-add! splash-evading-tags tid)
        (emit! (list 'kite tid (safe-coord kx tx) (safe-coord ky ty))))
      ;; Split nearby allies within 2.2 tiles of the targeted unit away from the blast radius
      (for ([ally (in-list combat-units)])
        (define aid (hash-ref ally 'id 101))
        (define ax (hash-ref ally 'x base-x))
        (define ay (hash-ref ally 'y base-y))
        (when (and (not (equal? aid tid))
                   (not (set-member? splash-evading-tags aid))
                   (<= (dist2d tx ty ax ay) 2.2))
          (define-values (sx sy) (compute-kite-vector ax ay tx ty 2.8))
          (set-add! splash-evading-tags aid)
          (emit! (list 'kite aid (safe-coord sx ax) (safe-coord sy ay)))))))

  ;; 3. Enemy Baneling Light-Unit Radial Pre-Split (Armored units hold & focus-fire)
  (define enemy-banelings
    (filter (lambda (e) (eq? (unit-type-sym e) 'baneling)) enemy-units))
  (define light-split-syms
    '(marine zergling zealot adept hydralisk reaper ghost sentry high-templar))
  (when (not (null? enemy-banelings))
    (for ([u (in-list combat-units)])
      (define uid (hash-ref u 'id 101))
      (define ut (unit-type-sym u))
      (define ux (hash-ref u 'x base-x))
      (define uy (hash-ref u 'y base-y))
      (when (and (memq ut light-split-syms)
                 (not (set-member? splash-evading-tags uid))
                 (not (order-ledger-unit-in-attack-swing? oledger u)))
        (define closest-bane
          (let loop ([rem enemy-banelings] [best-b #f] [best-d 4.5])
            (if (null? rem)
                best-b
                (let* ([b (car rem)]
                       [d (dist2d ux uy (hash-ref b 'x nat-x) (hash-ref b 'y nat-y))])
                  (if (<= d best-d)
                      (loop (cdr rem) b d)
                      (loop (cdr rem) best-b best-d))))))
        (when closest-bane
          (define bx (hash-ref closest-bane 'x nat-x))
          (define by (hash-ref closest-bane 'y nat-y))
          (define-values (kx ky) (compute-kite-vector ux uy bx by 3.0))
          (set-add! splash-evading-tags uid)
          (emit! (list 'kite uid (safe-coord kx ux) (safe-coord ky uy)))))))

  ;; 4. Enemy Hellion & Burrowed Lurker Linear Splash Lateral Scatter (+/- perpendicular n-hat)
  (define linear-splash-enemies
    (filter (lambda (e)
              (or (eq? (unit-type-sym e) 'hellion)
                  (eq? (unit-type-sym e) 'lurker-burrowed)
                  (and (eq? (unit-type-sym e) 'lurker)
                       (or (hash-ref e 'burrowed #f) (hash-ref e 'burrowed? #f)))))
            enemy-units))
  (when (and (not (null? linear-splash-enemies)) (>= (length combat-units) 2))
    (for ([u (in-list combat-units)])
      (define uid (hash-ref u 'id 101))
      (define ux (hash-ref u 'x base-x))
      (define uy (hash-ref u 'y base-y))
      (when (and (not (sc2-unit-is-flying-sym? (unit-type-sym u)))
                 (not (set-member? splash-evading-tags uid))
                 (not (order-ledger-unit-in-attack-swing? oledger u)))
        (for ([le (in-list linear-splash-enemies)]
              #:unless (set-member? splash-evading-tags uid))
          (define lex (hash-ref le 'x nat-x))
          (define ley (hash-ref le 'y nat-y))
          (define max-line-range (if (eq? (unit-type-sym le) 'hellion) 6.5 9.5))
          (define d (dist2d ux uy lex ley))
          (when (and (> d 0.25) (<= d max-line-range))
            (define vx (/ (- ux lex) d))
            (define vy (/ (- uy ley) d))
            ;; Check if any other ground ally lies close to the same line-of-fire ray
            (define collinear-ally?
              (for/or ([o (in-list combat-units)]
                       #:when (not (equal? (hash-ref o 'id -1) uid)))
                (define ox (hash-ref o 'x base-x))
                (define oy (hash-ref o 'y base-y))
                (define odx (- ox lex))
                (define ody (- oy ley))
                (define proj (+ (* odx vx) (* ody vy)))
                (define perp (abs (- (* odx vy) (* ody vx))))
                (and (> proj 0.5) (<= proj (+ max-line-range 1.0)) (<= perp 1.1))))
            (when collinear-ally?
              (define sign (if (even? uid) 1.0 -1.0))
              (define nx (* sign (- vy)))
              (define ny (* sign vx))
              (define lx (+ ux (* 2.5 nx)))
              (define ly (+ uy (* 2.5 ny)))
              (set-add! splash-evading-tags uid)
              (emit! (list 'kite uid (safe-coord lx ux) (safe-coord ly uy)))))))))

  ;; 5. Counter-Micro vs. Enemy `oracle-stasis-trap` / `stasis-ward`
  (define enemy-stasis-traps
    (filter (lambda (e) (memq (unit-type-sym e) '(oracle-stasis-trap stasis-ward)))
            (append enemy-units enemy-bldgs)))
  (define ally-has-detector?
    (ormap (lambda (u) (sc2-unit-is-detector-sym? (unit-type-sym u)))
           (append ally-units ally-bldgs)))
  (for ([trap (in-list enemy-stasis-traps)])
    (define trap-id (hash-ref trap 'id 9001))
    (define tx (hash-ref trap 'x nat-x))
    (define ty (hash-ref trap 'y nat-y))
    (define trap-prog (exact->inexact (hash-ref trap 'build-progress 1.0)))
    (define trap-cloaked? (eq? (hash-ref trap 'cloaked #f) #t))
    (define trap-targetable?
      (or (< trap-prog 1.0)
          (not trap-cloaked?)
          ally-has-detector?))
    (define ranged-snipers
      (filter (lambda (u)
                (define ut (unit-type-sym u))
                (define gr (exact->inexact
                            (hash-ref u 'ground-range
                                      (hash-ref (sc2-unit-combat-stats ut) 'ground-range 0.0))))
                (and (>= gr 4.5)
                     (<= (dist2d tx ty (hash-ref u 'x base-x) (hash-ref u 'y base-y)) 11.0)))
              combat-units))
    (cond
      [(and trap-targetable? (not (null? ranged-snipers)))
       (for ([r (in-list ranged-snipers)])
         (define rid (hash-ref r 'id 101))
         (set-add! splash-evading-tags rid)
         (emit! (list 'attack-unit rid trap-id)))
       (for ([u (in-list combat-units)])
         (define uid (hash-ref u 'id 101))
         (define ut (unit-type-sym u))
         (define gr (exact->inexact
                     (hash-ref u 'ground-range
                               (hash-ref (sc2-unit-combat-stats ut) 'ground-range 0.0))))
         (define ux (hash-ref u 'x base-x))
         (define uy (hash-ref u 'y base-y))
         (when (and (< gr 4.5)
                    (not (sc2-unit-is-flying-sym? ut))
                    (<= (dist2d tx ty ux uy) 6.0))
           (define-values (kx ky) (compute-kite-vector ux uy tx ty 6.8))
           (set-add! splash-evading-tags uid)
           (emit! (list 'kite uid (safe-coord kx base-x) (safe-coord ky base-y)))))]
      [(>= trap-prog 1.0)
       (define nearby-ground
         (filter (lambda (u)
                   (and (not (sc2-unit-is-flying-sym? (unit-type-sym u)))
                        (<= (dist2d tx ty (hash-ref u 'x base-x) (hash-ref u 'y base-y)) 12.0)))
                 combat-units))
       (when (not (null? nearby-ground))
         (define cheap-cands
           (filter (lambda (u) (memq (unit-type-sym u) '(zergling marine zealot adept)))
                   nearby-ground))
         (define sac-unit
           (argmin (lambda (u) (hash-ref u 'hp 100))
                   (if (not (null? cheap-cands)) cheap-cands nearby-ground)))
         (define sac-id (hash-ref sac-unit 'id 101))
         (set-add! splash-evading-tags sac-id)
         (emit! (list 'trigger-stasis-ward-single-unit
                      sac-id trap-id (exact-round tx) (exact-round ty)))
         (emit! (list 'move sac-id (exact-round tx) (exact-round ty)))
         (for ([u (in-list nearby-ground)]
               #:when (not (equal? (hash-ref u 'id -1) sac-id)))
           (define uid (hash-ref u 'id 101))
           (define ux (hash-ref u 'x base-x))
           (define uy (hash-ref u 'y base-y))
           (when (<= (dist2d tx ty ux uy) 6.5)
             (define-values (kx ky) (compute-kite-vector ux uy tx ty 6.8))
             (set-add! splash-evading-tags uid)
             (emit! (list 'kite uid (safe-coord kx base-x) (safe-coord ky base-y))))))]))

  ;; ---------------------------------------------------------------------------
  ;; Friendly Oracle Spell Micro (`stasis-ward` & `pulsar-beam`)
  ;; ---------------------------------------------------------------------------
  (define friendly-stasis-traps
    (filter (lambda (u) (memq (unit-type-sym u) '(oracle-stasis-trap stasis-ward)))
            (append ally-units ally-bldgs)))
  (define enemy-townhalls
    (filter (lambda (eb)
              (memq (unit-type-sym eb)
                    '(hatchery lair hive nexus command-center orbital-command planetary-fortress)))
            enemy-bldgs))
  (for ([u (in-list combat-units)]
        #:when (eq? (unit-type-sym u) 'oracle))
    (define uid (hash-ref u 'id 101))
    (define ux (hash-ref u 'x base-x))
    (define uy (hash-ref u 'y base-y))
    (define u-energy (hash-ref u 'energy 0))
    (define u-buffs (hash-ref u 'buffs '()))
    (define nearby-enemy-workers
      (filter (lambda (e)
                (and (memq (unit-type-sym e) '(drone scv probe))
                     (<= (dist2d ux uy (hash-ref e 'x 9999) (hash-ref e 'y 9999)) 10.0)))
              enemy-units))
    (define nearby-enemy-th
      (findf (lambda (th)
               (<= (dist2d ux uy (hash-ref th 'x 9999) (hash-ref th 'y 9999)) 10.0))
             enemy-townhalls))
    (define close-enemy-workers
      (filter (lambda (ew)
                (<= (dist2d ux uy (hash-ref ew 'x 9999) (hash-ref ew 'y 9999)) 5.0))
              nearby-enemy-workers))
    (when (>= u-energy 50)
      (cond
        ;; 1. Mineral-line Stasis Harass
        [(or (>= (length nearby-enemy-workers) 2) nearby-enemy-th)
         (define-values (wx wy)
           (if (not (null? nearby-enemy-workers))
               (let ([n (length nearby-enemy-workers)])
                 (values (exact-round (/ (for/sum ([w (in-list nearby-enemy-workers)])
                                           (hash-ref w 'x ux))
                                         n))
                         (exact-round (/ (for/sum ([w (in-list nearby-enemy-workers)])
                                           (hash-ref w 'y uy))
                                         n))))
               (values (exact-round (hash-ref nearby-enemy-th 'x ux))
                       (exact-round (hash-ref nearby-enemy-th 'y uy)))))
         (emit! (list 'cast-spell uid 'stasis-ward wx wy))
         (when (not (null? close-enemy-workers))
           (define nearest-ew
             (argmin (lambda (ew) (dist2d ux uy (hash-ref ew 'x ux) (hash-ref ew 'y uy)))
                     close-enemy-workers))
           (emit! (list 'cast-spell uid 'pulsar-beam (hash-ref nearest-ew 'id 0))))]
        ;; 2. Expansion Disruption
        [(and (<= (dist2d ux uy enemy-exp-x enemy-exp-y) 15.0)
              (not (ormap (lambda (th)
                            (<= (dist2d enemy-exp-x enemy-exp-y
                                        (hash-ref th 'x 9999) (hash-ref th 'y 9999))
                                5.0))
                          enemy-townhalls))
              (not (ormap (lambda (ft)
                            (<= (dist2d enemy-exp-x enemy-exp-y
                                        (hash-ref ft 'x 9999) (hash-ref ft 'y 9999))
                                5.0))
                          friendly-stasis-traps)))
         (emit! (list 'cast-spell uid 'stasis-ward enemy-exp-x enemy-exp-y))]
        ;; 3. Defensive Choke Stasis Ward
        [(and (<= (dist2d ux uy nat-x nat-y) 15.0)
              (not (ormap (lambda (ft)
                            (<= (dist2d nat-x nat-y
                                        (hash-ref ft 'x 9999) (hash-ref ft 'y 9999))
                                5.0))
                          friendly-stasis-traps))
              (or (>= u-energy 75)
                  (ormap (lambda (e)
                           (<= (dist2d ux uy (hash-ref e 'x 9999) (hash-ref e 'y 9999)) 18.0))
                         enemy-units)))
         (emit! (list 'cast-spell uid 'stasis-ward nat-x nat-y))]))
    ;; Deactivate Pulsar Beam if active and no enemy within 6.5 tiles
    (when (and (list? u-buffs)
               (or (memq 'pulsar-beam u-buffs) (memq 'oracle-weapon u-buffs))
               (not (ormap (lambda (e)
                             (<= (dist2d ux uy (hash-ref e 'x 9999) (hash-ref e 'y 9999)) 6.5))
                           enemy-units)))
      (emit! (list 'cast-spell uid 'pulsar-beam-off uid))))

  ;; ---------------------------------------------------------------------------
  ;; Active Combat Spells & Engagement Micro (Protected by Weapon-Swing Lock
  ;; & Guided by Multi-Depth Mirrored Tactical Micro Brain)
  ;; ---------------------------------------------------------------------------
  (define live-obs? (hash-has-key? raw-obs 'mineral-harvesters))
  (define live-combat-supply
    (for/sum ([u (in-list combat-units)])
      (unit-supply-cost (unit-type-sym u))))
  (define visible-enemy-combat-supply
    (for/sum ([e (in-list enemy-units)])
      (unit-supply-cost (unit-type-sym e))))
  (define lanchester-force-ratio
    (/ (exact->inexact live-combat-supply)
       (max 8.0 (exact->inexact visible-enemy-combat-supply))))
  (define live-owned-townhalls
    (count (lambda (b)
             (memq (unit-type-sym b)
                   '(hatchery lair hive nexus command-center orbital-command planetary-fortress)))
           ally-bldgs))
  (define live-attack-wave-min
    (if live-obs?
        22
        SC2-ATTACK-WAVE-MIN-COMBAT-UNITS))
  (define engagement-enemies
    (if live-obs?
        (append enemy-units enemy-bldgs)
        enemy-units))
  (define ally-siege-tanks
    (filter (lambda (u) (memq (unit-type-sym u) '(siege-tank siege-tank-sieged)))
            combat-units))
  (define static-defense-syms
    '(spine-crawler photon-cannon bunker planetary-fortress))
  (define short-range-bio-syms
    '(marine marauder zergling roach hydralisk zealot stalker adept))

  (define ally-has-stealth?
    (ormap (lambda (u)
             (or (and (memq (unit-type-sym u) SC2-CLOAKED-OR-BURROW-STEALTH-SYMS) #t)
                 (and (hash-ref u 'cloaked #f) #t)
                 (and (hash-ref u 'burrowed #f) #t)))
           combat-units))

  (when (not (null? engagement-enemies))
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
      (define u-buffs (hash-ref u 'buffs '()))
      (define target-enemy (select-target-enemy-for-unit ux uy engagement-enemies ut ally-has-stealth?))
      (define eid (hash-ref target-enemy 'id 9001))
      (define etype (unit-type-sym target-enemy))
      (define ex (hash-ref target-enemy 'x nat-x))
      (define ey (hash-ref target-enemy 'y nat-y))
      (define edist (dist2d ux uy ex ey))
      (define can-hit-target?
        (or (not live-obs?)
            (sc2-attacker-can-hit-enemy? ut target-enemy)))
      (define enemy-near-our-territory?
        (<= (min (dist2d ex ey base-x base-y)
                 (dist2d ex ey nat-x nat-y)
                 (if (>= live-owned-townhalls 3) (dist2d ex ey third-x third-y) +inf.0))
            36.0))
      (define unit-should-engage-target?
        (and can-hit-target?
             (or (not live-obs?)
                 (<= edist 22.0)
                 enemy-near-our-territory?
                 (and (>= live-combat-supply 26) (>= lanchester-force-ratio 1.35))
                 (>= live-combat-supply 40)
                 (>= (length combat-units) live-attack-wave-min))))
      ;; Siege Tank Range-Leashing for Bio vs Static Defense (Spine Crawler / Cannon / Bunker):
      ;; When a friendly Siege Tank is within 15.5 tiles of an enemy static defense structure,
      ;; hold short-range bio outside the static defense's 7.0 range (at 8.5 tiles) so the
      ;; Siege Tank (range 13) shells it down without feeding Marines/Roaches into Spine Crawlers!
      (define tank-supporting-vs-static?
        (and (memq ut short-range-bio-syms)
             (memq etype static-defense-syms)
             (<= edist 8.0)
             (ormap (lambda (tk)
                      (<= (dist2d ex ey (hash-ref tk 'x ux) (hash-ref tk 'y uy)) 15.5))
                    ally-siege-tanks)))
      (define (emit-engage-or-rally!)
        (cond
          [tank-supporting-vs-static?
           (define-values (kx ky) (compute-kite-vector ux uy ex ey 2.5))
           (emit! (list 'kite uid (safe-coord kx ux) (safe-coord ky uy)))]
          [unit-should-engage-target?
           (emit! (list 'attack-unit uid eid))]
          [(> (dist2d ux uy nat-x nat-y) 10.0)
           (emit! (list 'attack-pos uid nat-x nat-y))]))
      (define mirrored-acts (hash-ref tbrain-unit-actions uid '()))
      ;; Weapon-swing phase lock: never interrupt a unit in the middle of its attack windup
      (unless (order-ledger-unit-in-attack-swing? oledger u)
        (case ut
          [(ravager)
           (when (or (not live-upgrades-tracked?) (<= edist 9.5))
             (emit! (list 'cast-spell uid 'corrosive-bile ex ey)))
           (emit-engage-or-rally!)]
          [(lurker lurker-burrowed)
           (define is-burrowed? (or (eq? ut 'lurker-burrowed) (hash-ref u 'burrowed #f)))
           (define min-ground-dist
             (for/fold ([best +inf.0])
                       ([e (in-list engagement-enemies)]
                        #:when (not (sc2-unit-is-flying-sym? (unit-type-sym e))))
               (min best (dist2d ux uy (hash-ref e 'x ex) (hash-ref e 'y ey)))))
           (cond
             [(and is-burrowed? (> min-ground-dist 10.5))
              (emit! (list 'cast-spell uid 'burrow-up uid))]
             [(and (not is-burrowed?)
                   (or (not live-upgrades-tracked?) (<= min-ground-dist 9.0)))
              (emit! (list 'cast-spell uid 'burrow eid))
              (emit-engage-or-rally!)]
             [else
              (emit-engage-or-rally!)])]
          [(widow-mine widow-mine-burrowed)
           (define is-burrowed? (or (eq? ut 'widow-mine-burrowed) (hash-ref u 'burrowed #f)))
           (define min-enemy-dist
             (for/fold ([best +inf.0]) ([e (in-list engagement-enemies)])
               (min best (dist2d ux uy (hash-ref e 'x ex) (hash-ref e 'y ey)))))
           (cond
             [(and is-burrowed? (> min-enemy-dist 6.5))
              (emit! (list 'cast-spell uid 'widow-mine-unburrow uid))]
             [is-burrowed?
              ;; Active Widow Mine retargeting: aim Sentinel Missile at the enemy with the most
              ;; nearby non-decoy allies within 1.75 splash radius
              (define best-cluster-enemy
                (let loop ([rem engagement-enemies] [best-e target-enemy] [best-cnt -1])
                  (if (null? rem)
                      best-e
                      (let* ([e (car rem)]
                             [et2 (unit-type-sym e)]
                             [ex2 (hash-ref e 'x ex)]
                             [ey2 (hash-ref e 'y ey)]
                             [d2 (dist2d ux uy ex2 ey2)])
                        (if (and (<= d2 5.0)
                                 (not (memq et2 SC2-PASSIVE-SCOUT-OR-DECOY-UNIT-SYMS)))
                            (let ([cnt (count (lambda (o)
                                                (<= (dist2d ex2 ey2 (hash-ref o 'x ex2) (hash-ref o 'y ey2)) 1.75))
                                              engagement-enemies)])
                              (if (> cnt best-cnt)
                                  (loop (cdr rem) e cnt)
                                  (loop (cdr rem) best-e best-cnt)))
                            (loop (cdr rem) best-e best-cnt))))))
              (emit! (list 'attack-unit uid (hash-ref best-cluster-enemy 'id eid)))]
             [(or (not live-upgrades-tracked?) (<= min-enemy-dist 5.5))
              (emit! (list 'cast-spell uid 'burrow eid))
              (emit-engage-or-rally!)]
             [else
              (emit-engage-or-rally!)])]
          [(baneling)
           ;; Banelings roll directly through the center of Light/Bio clumps before detonating
           (when (and (> edist 1.8) (<= edist 10.0))
             (emit! (list 'kite uid (safe-coord ex ux) (safe-coord ey uy))))
           (emit-engage-or-rally!)]
          [(carrier)
           (emit! (list 'cast-spell uid 'build-interceptors uid))
           (if (and (< edist 7.5) (> edist 0.1))
               (let-values ([(kx ky) (compute-kite-vector ux uy ex ey 2.5)])
                 (emit! (list 'kite uid (safe-coord kx ux) (safe-coord ky uy))))
               (emit-engage-or-rally!))]
          [(disruptor)
           (when (<= edist 11.0)
             (emit! (list 'cast-spell uid 'purification-nova ex ey)))
           (if (< edist 7.5)
               (let-values ([(kx ky) (compute-kite-vector ux uy ex ey 3.0)])
                 (emit! (list 'kite uid (safe-coord kx ux) (safe-coord ky uy))))
               (emit-engage-or-rally!))]
          [(disruptor-phased)
           (emit! (list 'kite uid (safe-coord ex ux) (safe-coord ey uy)))]
          [(sentry)
           (cond
             [(and (>= (hash-ref u 'energy SC2-SENTRY-FORCE-FIELD-ENERGY) SC2-SENTRY-GUARDIAN-SHIELD-ENERGY)
                   (not (memq 'guardian-shield u-buffs))
                   (or (not live-upgrades-tracked?) (<= edist 9.0)))
              (emit! (list 'cast-spell uid 'guardian-shield eid))]
             [(and (>= (hash-ref u 'energy SC2-SENTRY-FORCE-FIELD-ENERGY) SC2-SENTRY-FORCE-FIELD-ENERGY)
                   (or (not live-upgrades-tracked?) (<= edist 9.0)))
              (emit! (list 'cast-spell uid 'force-field
                           (safe-coord (* 0.5 (+ nat-x ex)) nat-x)
                           (safe-coord (* 0.5 (+ nat-y ey)) nat-y)))])
           (emit-engage-or-rally!)]
          [(stalker)
           (when (and (has-upgrade? 'blink)
                      (< u-hp SC2-STALKER-BLINK-HP-THRESH))
             (define-values (kx ky) (compute-kite-vector ux uy ex ey SC2-KITE-STEP-DISTANCE))
             (emit! (list 'cast-spell uid 'blink (safe-coord kx ux) (safe-coord ky uy))))
           (emit-engage-or-rally!)]
          [(adept)
           (when (or (not live-upgrades-tracked?) (<= edist 12.0))
             (emit! (list 'cast uid 'psionic-transfer ex ey)))
           (emit-engage-or-rally!)]
          [(siege-tank siege-tank-sieged)
           ;; Hysteresis: siege when enemy within SC2-SIEGE-TANK-SIEGE-RANGE; unsiege only when > SC2-SIEGE-TANK-UNSIEGE-RANGE
           (define is-sieged? (or (eq? ut 'siege-tank-sieged) (hash-ref u 'sieged #f)))
           (define min-enemy-dist
             (for/fold ([best +inf.0]) ([e (in-list engagement-enemies)])
               (min best (dist2d ux uy (hash-ref e 'x ex) (hash-ref e 'y ey)))))
           (cond
             [(and is-sieged? (> min-enemy-dist SC2-SIEGE-TANK-UNSIEGE-RANGE))
              (emit! (list 'cast-spell uid 'unsiege-mode uid))
              (unless live-upgrades-tracked?
                (emit-engage-or-rally!))]
             [(and (not is-sieged?) (<= min-enemy-dist SC2-SIEGE-TANK-SIEGE-RANGE))
              (emit! (list 'cast-spell uid 'siege-mode eid))
              (unless live-upgrades-tracked?
                (emit-engage-or-rally!))]
             [else
              (emit-engage-or-rally!)])]
          [(ghost)
           (when (>= (hash-ref u 'energy 75) 75)
             (emit! (list 'cast-spell uid 'emp-round eid))
             (emit! (list 'cast-spell uid 'snipe eid)))
           (emit-engage-or-rally!)]
          [(marine marauder)
           (when (and (has-upgrade? 'stimpack)
                      (not (memq 'stimpack u-buffs))
                      (not (memq 'stimpack-marauder u-buffs))
                      (>= u-hp SC2-MARINE-STIM-MIN-HP)
                      (or (not live-upgrades-tracked?) (<= edist 9.5)))
             (emit! (list 'cast-spell uid 'stimpack eid)))
           (unless (set-member? splash-evading-tags uid)
             (emit-engage-or-rally!))]
          [(mutalisk)
           (if (< u-hp SC2-MUTALISK-KITE-HP-THRESH)
               (let-values ([(kx ky) (compute-kite-vector ux uy ex ey SC2-KITE-STEP-DISTANCE)])
                 (emit! (list 'kite uid (safe-coord kx ux) (safe-coord ky uy))))
               (emit-engage-or-rally!))]
          [(banshee)
           ;; Banshee uses Multi-Depth Mirrored Tactical Micro Brain (with Cloak + Hysteresis + Cooldown Phase-Lock)
           (if (not (null? mirrored-acts))
               (for ([ma (in-list mirrored-acts)]) (emit! ma))
               (emit-engage-or-rally!))]
          [else
           (unless (set-member? splash-evading-tags uid)
             (if (and (not (null? mirrored-acts)) unit-should-engage-target?)
                 (for ([ma (in-list mirrored-acts)]) (emit! ma))
                 (emit-engage-or-rally!)))]))))

  ;; ---------------------------------------------------------------------------
  ;; Pro Mechanic #8: Burrowed Zergling Base-Blocker, Cheap Patrol Expansion
  ;;                  Blocker, Peripheral Economic Harassment Raider Squad, &
  ;;                  Probing-Attack Recon Vanguard (Gathering Opponent Info via
  ;;                  Scouting, Harassment, or Attacking — PV9)
  ;; ---------------------------------------------------------------------------
  (define cur-tel-ht
    (let ([t (live-bot-runtime-last-telemetry rt)])
      (if (hash? t) t (hash))))
  (define cur-intel-staleness
    (hash-ref cur-tel-ht 'intel-staleness-frames
              (if (and (null? enemy-units) (null? enemy-bldgs)) frame 0)))
  (define cheap-blockers
    (filter (lambda (u)
              (and (memq (unit-type-sym u) '(zergling marine zealot reaper adept hellion oracle phoenix mutalisk banshee))
                   (not (set-member? tbrain-committed-tags (hash-ref u 'id -1)))))
            combat-units))
  (define mm-verdict
    (mirror-mind-state-mirror-macro-verdict (live-bot-runtime-mirror-mind rt)))
  (define allow-harass-raid?
    (if live-obs?
        (or (hash-ref obs 'enable-economic-disruption #f)
            (and (>= live-combat-supply 28)
                 (>= (length cheap-blockers) 4)
                 (refractory-allow-action?! (live-bot-runtime-cooldown-tracker rt)
                                            (list 'live-harass-raid)
                                            frame
                                            672)))
        (or (hash-ref obs 'enable-economic-disruption #f)
            (and (>= cur-intel-staleness 224)
                 (>= (length combat-units) 4)
                 (>= (length cheap-blockers) 2))
            (and (eq? mm-verdict 'punish-And-Deny-Greedy-Expand)
                 (>= (length combat-units) (min 6 live-attack-wave-min)))
            (and (null? enemy-units)
                 (>= (length combat-units) (min 6 live-attack-wave-min))
                 (>= (length cheap-blockers) 3)))))
  (when (and (not (null? cheap-blockers)) allow-harass-raid?)
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

  (when (and (null? enemy-units)
             (or (not live-obs?)
                 (and (null? enemy-bldgs)
                      (< (length combat-units) live-attack-wave-min)))
             (>= (length combat-units) 2))
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

  ;; Pro Mechanic #9b: Burrowed Roach Tunneling Claws micro, Burrowed Infestor
  ;;                   Fungal/Neural/Shroud micro, & Shimmer / Burrow-Ripple AoE skillshots
  (for ([ba (in-list (execute-roach-tunneling-burrow-micro obs))])
    (emit! ba))
  (for ([ia (in-list (execute-infestor-burrow-cast-micro obs))])
    (emit! ia))
  (for ([sa (in-list (execute-shimmer-and-burrow-ripple-response obs))])
    (emit! sa))

  (define ally-sentries
    (filter (lambda (u) (eq? (unit-type-sym u) 'sentry)) ally-units))
  (define ally-overseers
    (filter (lambda (u) (eq? (unit-type-sym u) 'overseer)) ally-units))
  (define ally-infestors
    (filter (lambda (u) (memq (unit-type-sym u) '(infestor infestor-burrowed))) ally-units))

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
  (define visible-enemies-for-target
    (if (and live-obs? (null? enemy-units))
        enemy-bldgs
        enemy-units))
  (define target-ex
    (if (null? visible-enemies-for-target)
        enemy-x
        (safe-coord (/ (for/sum ([e (in-list visible-enemies-for-target)])
                         (safe-finite-real (hash-ref e 'x enemy-x) enemy-x))
                       (max 1 (length visible-enemies-for-target)))
                    enemy-x)))
  (define target-ey
    (if (null? visible-enemies-for-target)
        enemy-y
        (safe-coord (/ (for/sum ([e (in-list visible-enemies-for-target)])
                         (safe-finite-real (hash-ref e 'y enemy-y) enemy-y))
                       (max 1 (length visible-enemies-for-target)))
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
    (if (and live-obs? (>= (length combat-units) live-attack-wave-min))
        (case sp-maneuver
          [(pre-rotate-intercept-incoming-threat)
           (values nat-x nat-y)]
          [(backstab-undefended-enemy-expansion)
           (if (null? visible-enemies-for-target)
               (values enemy-exp-x enemy-exp-y)
               (values target-ex target-ey))]
          [else
           (values target-ex target-ey)])
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
           (values target-ex target-ey)])))
  (emit! (list 'execute-spatial-maneuver sp-maneuver sp-tx sp-ty))

  (define sanitized-tactic-actions
    (sanitize-stale-target-actions (reverse actions) obs #:pos-cache (rt-enemy-pos-cache rt)))
  (values sanitized-tactic-actions vanguard-count reserve-count))

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

  ;; 3. Optimal Human Selection & Control-Group Compiler:
  ;;    Coalesce per-unit commands into multi-tag squad orders and compile raw desired
  ;;    unit selections into minimal-APM combinations of `control-group-recall`,
  ;;    on-screen `select-box`, `select-ctrl-type`, `deselect-ctrl-type`, and on-the-fly
  ;;    control-group updates.
  (define selection-compiled-actions
    (if (or (hash-has-key? raw-obs 'mineral-harvesters)
            (hash-ref raw-obs 'compile-human-selections? #f))
        (cortex-collapse-and-compile-selections!
         cortex
         unthrottled-actions
         (hash-ref obs 'ally-units '())
         (hash-ref obs 'ally-buildings '()))
        unthrottled-actions))

  (define combined (append cam-actions selection-compiled-actions))
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
  ;; Pro humans dwell ~16-22 frames (~0.75s = 60-90 SPM) per camera zone before saccading.
  ;; Only update last-saccade-frame when a saccade actually occurs so sub-16-frame step_sizes
  ;; accumulate elapsed frames properly instead of resetting the dwell timer every step.
  (define saccade-due?
    (or (not (exact-integer? last-frame))
        (= frame last-frame)
        (>= (abs (- frame last-frame)) SC2-CAMERA-SACCADE-MIN-DWELL-FRAMES)))
  (define next-idx
    (cond
      [(not (exact-integer? last-frame)) 0]
      [saccade-due?
       (modulo (add1 cur-idx) (length PRO-CAMERA-SACCADE-ZONES))]
      [else (modulo cur-idx (length PRO-CAMERA-SACCADE-ZONES))]))
  (when saccade-due?
    (hash-set! bmarks 'last-saccade-frame frame)
    (hash-set! bmarks 'saccade-zone-idx next-idx))

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

  (define all-layer-actions (append posture-acts econ-acts tactic-acts))
  (define extended-stasis-and-drill-heads
    '(worker-drill-stack-attack
      evacuate-workers-from-stasis-ward
      trigger-stasis-ward-single-unit
      counter-enemy-worker-drill
      stasis-worker-stoppage-compensation
      return-workers-to-gather))
  (define stasis-and-drill-actions
    (filter (lambda (a)
              (and (pair? a) (memq (car a) extended-stasis-and-drill-heads)))
            all-layer-actions))
  (define raw-actions
    (if (and (hash? raw-obs)
             (or (hash-has-key? raw-obs 'raw-mineral-harvesters)
                 (hash-ref raw-obs 'include-extended-drill-actions? #f)))
        all-layer-actions
        (filter (lambda (a)
                  (not (and (pair? a) (memq (car a) extended-stasis-and-drill-heads))))
                all-layer-actions)))

  ;; Layer 5
  (define-values (accepted dropped spell-throttled)
    (step-layer5-human-cortex! rt raw-actions obs))
  ;; Layer 5b: Pro-Human Camera Saccade (60-90 SPM) & APM/EPM Discipline Governor
  (define pro-apm-acts
    (step-pro-human-camera-and-apm-governor! rt obs))
  (define preserved-tactical-directives
    (append
     (filter (lambda (a)
               (and (pair? a)
                    (memq (car a)
                          '(rebalance-gas-to-minerals
                            terran-addon-swap
                            land-building
                            worker-scout
                            overlord-scout
                            mineral-harass
                            periodic-scout
                            cast-deception-and-scout-spells))
                    (not (member a accepted))))
             econ-acts)
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
                            execute-spatial-maneuver
                            burrow-down
                            burrow-up
                            burrow-block
                            patrol-block-expansion
                            harass-workers
                            periodic-scout
                            roach-tunnel-move
                            infestor-burrow-move
                            infestor-burrow-cast
                            blind-skillshot-shimmer
                            emergency-detector-response))
                    (not (member a accepted))))
             tactic-acts)))

  (define cortex (live-bot-runtime-cortex rt))
  (define mstate (live-bot-runtime-mastermind rt))
  (define mmstate (live-bot-runtime-mirror-mind rt))
  (define tbrain (live-bot-runtime-tactical-brain rt))
  (define oledger (live-bot-runtime-order-ledger rt))
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

  (define last-tel-ht (live-bot-runtime-last-telemetry rt))
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
          'tactical-arenas (length (tactical-mirror-brain-active-arenas tbrain))
          'tactical-decisions (tactical-mirror-brain-last-decisions tbrain)
          'active-orders-tracked (hash-count (in-progress-order-ledger-unit-orders oledger))
          'priority-summary (hash-ref last-tel-ht 'priority-summary (hash))
          'priority-log-line (hash-ref last-tel-ht 'priority-log-line "")
          'peak-supply-reached (hash-ref last-tel-ht 'peak-supply-reached 0)
          'repaired-prereqs (hash-ref last-tel-ht 'priority-repaired-prereqs '())
          'priority-repaired-prereqs (hash-ref last-tel-ht 'priority-repaired-prereqs '())
          'scout-worker-id (hash-ref last-tel-ht 'scout-worker-id #f)
          'last-enemy-seen-frame (hash-ref last-tel-ht 'last-enemy-seen-frame 0)
          'last-seen-main-frame (hash-ref last-tel-ht 'last-seen-main-frame 0)
          'last-seen-natural-frame (hash-ref last-tel-ht 'last-seen-natural-frame 0)
          'last-seen-third-frame (hash-ref last-tel-ht 'last-seen-third-frame 0)
          'last-seen-army-frame (hash-ref last-tel-ht 'last-seen-army-frame 0)
          'intel-staleness-frames (hash-ref last-tel-ht 'intel-staleness-frames 0)
          'intel-freshness (hash-ref last-tel-ht 'intel-freshness 1.0)
          'intel-coverage (hash-ref last-tel-ht 'intel-coverage 1.0)
          'intel-confidence (hash-ref last-tel-ht 'intel-confidence 1.0)
          'intel-deficit (hash-ref last-tel-ht 'intel-deficit 0.0)
          'intel-priority-sector (hash-ref last-tel-ht 'intel-priority-sector 'enemy-natural)
          'intel-target-goal (hash-ref last-tel-ht 'intel-target-goal 'maintain-vision)
          'intel-pressure (hash-ref last-tel-ht 'intel-pressure 0.0)
          'intel-gathering-method (hash-ref last-tel-ht 'intel-gathering-method 'scouting)
          'remembered-enemy-threat-supply (hash-ref last-tel-ht 'remembered-enemy-threat-supply 0)
          'remembered-enemy-threat-frame (hash-ref last-tel-ht 'remembered-enemy-threat-frame -9999)
          'escrow-goal-sym (hash-ref last-tel-ht 'escrow-goal-sym #f)
          'escrow-age-frames (hash-ref last-tel-ht 'escrow-age-frames 0)
          'escrow-peak-min (hash-ref last-tel-ht 'escrow-peak-min 0)
          'escrow-prev-min (hash-ref last-tel-ht 'escrow-prev-min 0)
          'escrow-start-frame (hash-ref last-tel-ht 'escrow-start-frame 0)
          'escrow-last-frame (hash-ref last-tel-ht 'escrow-last-frame 0)
          'vanguard-count vanguard-cnt
          'reserve-count reserve-cnt
          'personality (bot-personality-name (mastermind-state-personality mstate))
          'pda-bucket (diagnose-bot-anomaly pda)))

  (set-live-bot-runtime-last-telemetry! rt telemetry)
  (define rt-pos-cache (rt-enemy-pos-cache rt))
  (define final-actions
    (sanitize-stale-target-actions
     (append accepted preserved-tactical-directives pro-apm-acts)
     obs
     #:pos-cache rt-pos-cache))
  (define final-mirror-actions
    (sanitize-stale-target-actions mirror-acts obs #:pos-cache rt-pos-cache))
  (hash 'actions final-actions
        'mirror-actions final-mirror-actions
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

(define (parse-order-tuple tup)
  (match tup
    [(list uid ab-id tx ty)
     (hash 'unit-id uid 'ability-id ab-id 'target-x tx 'target-y ty)]
    [(list uid ab-id)
     (hash 'unit-id uid 'ability-id ab-id)]
    [(? hash? h) h]
    [_ (hash)]))

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
            [(in-progress-orders)
             (hash-set! h 'in-progress-orders (if (list? v) (map parse-order-tuple v) '()))]
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
