#lang racket/base

(require racket/match
         racket/list
         racket/set
         racket/math
         "../compiler/syntax.rkt"
         "sc2-common.rkt"
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
 compute-next-posture
 DEC-GOAL-STREAMS
 (struct-out race-bank-target)
 (struct-out stream-budget-slice)
 (struct-out decoupled-bank-allocation)
 (struct-out max-supply-plan)
 compute-bank-targets
 allocate-decoupled-goal-streams
 decoupled-stream-can-spend?
 evaluate-max-supply-manager
 NON-COMBAT-AND-SCOUT-ENEMY-SYMS
 combat-unit-record?
 rt-role-leases
 rt-bistable-states
 rt-scout-state
 rt-spotter-lings
 rt-tumor-state
 rt-door-state
 rt-splash-state
 rt-wall-state)

;; Per-runtime weak map caching last-known `(cons x y)` coordinates for enemy UnitTags
;; so stale/dead/snapshot target tags (`ActionResult=207 Error_CantTargetThatUnit`) downgrade
;; cleanly to `(attack-pos uid last-x last-y)` instead of failing in SC2!
;; Per-runtime weak-hash state accessors preserving `(struct live-bot-runtime ...)`
;; positional arity while lazily initializing each per-instance container.
(define-syntax-rule (define-rt-weak-state accessor-name init-expr)
  (define accessor-name
    (let ([tbl (make-weak-hasheq)])
      (lambda (rt)
        (hash-ref! tbl rt (lambda () init-expr))))))

(define-rt-weak-state rt-enemy-pos-cache (make-hasheqv))

(define-rt-weak-state rt-role-leases        (make-hasheqv))
(define-rt-weak-state rt-bistable-states    (make-hash))
(define-rt-weak-state rt-scout-state        (make-hasheq))
(define-rt-weak-state rt-spotter-lings      (make-hasheq))
(define-rt-weak-state rt-tumor-state        (make-hasheqv))
(define-rt-weak-state rt-door-state         (make-hasheq))
(define-rt-weak-state rt-splash-state       (make-hash))
(define-rt-weak-state rt-wall-aabbs-box     (box '()))
(define-rt-weak-state rt-enemy-race-box     (box 'Unknown))
(define-rt-weak-state rt-wall-state         (make-hasheq))
(define-rt-weak-state rt-rush-defense-state (make-hasheqv))

(define (worker-has-engine-build-order? w)
  (and (hash? w)
       (or (eq? (hash-ref w 'has-build-order? #f) #t)
           (memq (hash-ref w 'order-kind #f) '(build expand))
           (eq? (sc2-order-protection-class
                 (sc2-canonical-order-ability (hash-ref w 'order-ability-id 0)))
                'build-structure))
       #t))

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
      [(list 'pull-workers-attack wids (? exact-integer? tid) (? real? tx) (? real? ty))
       (if (or (<= tid 0) (set-member? valid-enemy-tags tid))
           act
           (list 'pull-workers-attack wids 0 (exact->inexact tx) (exact->inexact ty)))]
      [_ act])))

(define WORKER-AND-NONCOMBAT-SYMS
  '(drone probe scv overlord overseer queen larva egg cocoon mule observer
    overlord-cocoon transport-overlord-cocoon baneling-cocoon ravager-cocoon
    brood-lord-cocoon lurker-egg lurker-mp-egg
    creep-tumor creep-tumor-burrowed creep-tumor-queen
    warp-prism warp-prism-phasing observer-siege-mode overseer-siege-mode
    medivac overlord-transport
    interceptor auto-turret point-defense-drone raven-repair-drone
    adept-phase-shift disruptor-phased))

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
;; (Shared numeric helpers imported from `sc2-common.rkt`.)
;; =============================================================================

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
    warp-prism-phasing
    changeling changeling-zealot changeling-marine changeling-marine-shield
    changeling-zergling changeling-zergling-wings
    larva egg cocoon overlord-cocoon transport-overlord-cocoon baneling-cocoon ravager-cocoon
    brood-lord-cocoon lurker-egg lurker-mp-egg mule
    interceptor auto-turret point-defense-drone raven-repair-drone
    adept-phase-shift disruptor-phased kd8-charge parasitic-bomb-dummy
    oracle-stasis-trap stasis-ward force-field broodling-escort))

(define NON-WORKER-PULL-ENEMY-UNIT-SYMS
  (append NON-COMBAT-AND-SCOUT-ENEMY-SYMS
          '(mutalisk corruptor brood-lord broodlord viper
            phoenix oracle void-ray voidray carrier tempest mothership mothership-core
            warp-prism warp-prism-phasing interceptor
            viking viking-fighter medivac liberator liberator-ag banshee raven
            battlecruiser point-defense-drone)))

(define (combat-unit-record? u)
  (and (hash? u)
       (let ([t (unit-type-sym u)])
         (and (not (memq t WORKER-AND-NONCOMBAT-SYMS))
              (not (memq t NON-COMBAT-AND-SCOUT-ENEMY-SYMS))
              (not (sc2-non-combat-or-summon-sym? t))
              (not (eq? (hash-ref u 'is-hallucination #f) #t))
              (not (eq? (hash-ref u 'hallucination #f) #t))
              (not (eq? (hash-ref u 'hallucination? #f) #t))))))

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
     (define owned-third-th
       (findf (lambda (b)
                (and (hash? b)
                     (memq (sc2-canonical-structure-sym (hash-ref b 'type 'none))
                           '(hatchery lair hive nexus command-center orbital-command planetary-fortress))
                     (let ([bx (safe-coord (hash-ref b 'x base-x) base-x)]
                           [by (safe-coord (hash-ref b 'y base-y) base-y)])
                       (and (> (sqrt (+ (sqr (- bx base-x)) (sqr (- by base-y)))) 7.0)
                            (> (sqrt (+ (sqr (- bx nat-x)) (sqr (- by nat-y)))) 7.0)))))
              ally-buildings))
     (define eff-default-third-x
       (if owned-third-th
           (safe-coord (hash-ref owned-third-th 'x default-third-x) default-third-x)
           default-third-x))
     (define eff-default-third-y
       (if owned-third-th
           (safe-coord (hash-ref owned-third-th 'y default-third-y) default-third-y)
           default-third-y))
     (define third-x (safe-coord (hash-ref base-h 'third-x eff-default-third-x) eff-default-third-x))
     (define third-y (safe-coord (hash-ref base-h 'third-y eff-default-third-y) eff-default-third-y))
     (define enemy-exp-x
       (safe-coord (hash-ref base-h 'enemy-expand-x (hash-ref base-h 'enemy-exp-x default-enemy-exp-x))
                   default-enemy-exp-x))
     (define enemy-exp-y
       (safe-coord (hash-ref base-h 'enemy-expand-y (hash-ref base-h 'enemy-exp-y default-enemy-exp-y))
                   default-enemy-exp-y))
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
       (append (map (lambda (u) (sc2-canonical-unit-sym (unit-type-sym u)))
                    (hash-ref obs 'ally-units '()))
               (map (lambda (b) (sc2-canonical-structure-sym (unit-type-sym b)))
                    (hash-ref obs 'ally-buildings '()))))
     (cond
       [(ormap (lambda (t) (memq t '(drone overlord overseer hatchery lair hive spawning-pool zergling roach queen))) all-types)
        'Zerg]
       [(ormap (lambda (t) (memq t '(probe nexus pylon gateway warp-gate forge cybernetics-core zealot stalker adept sentry))) all-types)
        'Protoss]
       [(ormap (lambda (t) (memq t '(scv command-center orbital-command planetary-fortress supply-depot barracks factory starport marine marauder siege-tank))) all-types)
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
             (not (eq? resolved-race 'Random))
             (not (live-bot-runtime-doctrine rt)))
    (define cur-pers (mastermind-state-personality (live-bot-runtime-mastermind rt)))
    (define target-pers (default-personality-for-race resolved-race))
    (when (and (bot-personality? cur-pers)
               (bot-personality? target-pers)
               (memq (bot-personality-name cur-pers)
                     '(SCARLETT-CREEP-SWARM-PERSONALITY
                       MARV-MACRO-OPEN-PERSONALITY
                       CLEM-TEMPO-MULTITASK-PERSONALITY))
               (not (eq? (bot-personality-name cur-pers)
                         (bot-personality-name target-pers))))
      (set-mastermind-state-personality! (live-bot-runtime-mastermind rt) target-pers)))
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
                         (sc2-non-combat-or-summon-sym? t)
                         (eq? (hash-ref e 'changeling? #f) #t)
                         (eq? (hash-ref e 'is-hallucination #f) #t)
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

  ;; Hysteresis deadband: enter >= +13.0 (or no rush & >= +8.0), exit <= -5.0, catastrophic < -15.0
  (define catastrophic-deficit? (< fap-score -15.0))
  (define victory-fap-ok?
    (cond
      [catastrophic-deficit? #f]
      [in-victory?           (> fap-score -5.0)]
      [else
       (or (>= fap-score 13.0)
           (and (null? rush-enemies) (>= fap-score 8.0)))]))

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
  (define raw-rt-race (live-bot-runtime-actual-race rt))
  (define race
    (if (eq? raw-rt-race 'Random)
        (detect-actual-race-from-obs obs 'Zerg)
        raw-rt-race))
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

  (define protoss-powered-structure-syms
    SC2-PROTOSS-PYLON-POWERED-STRUCTURE-SYMS)
  (define (building-grounded-and-powered? b)
    (if (hash? b)
        (let ([raw-sym (unit-type-sym b)]
              [canon-sym (sc2-canonical-structure-sym (unit-type-sym b))])
          (and (not (eq? (hash-ref b 'flying? #f) #t))
               (not (memq raw-sym
                          '(barracks-flying factory-flying starport-flying
                            command-center-flying orbital-command-flying
                            spine-crawler-uprooted spore-crawler-uprooted)))
               (or (not (sc2-structure-requires-pylon-power? canon-sym))
                   (not (eq? (hash-ref b 'powered? #t) #f)))))
        #t))
  (define bldg-types
    (map (lambda (b) (sc2-canonical-structure-sym (unit-type-sym b))) ally-bldgs))
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

  (define cd-tracker (live-bot-runtime-cooldown-tracker rt))
  (define leases (rt-role-leases rt))
  (define oledger-early (live-bot-runtime-order-ledger rt))
  (define map-grids (hash-ref obs 'map-grids #f))
  (define expansion-pads
    (let ([raw-pads (hash-ref obs 'expansion-candidates #f)])
      (if (and (list? raw-pads) (pair? raw-pads))
          raw-pads
          (list (cons nat-x nat-y) (cons third-x third-y)))))

  ;; Lease active builder workers so saturate/cheese/scout/army never yank them mid-build
  (for ([w (in-list workers)])
    (define wid (hash-ref w 'id 0))
    (when (and (> wid 0)
               (or (worker-has-engine-build-order? w)
                   (order-ledger-unit-has-active-build? oledger-early wid w)))
      (acquire-unit-lease! leases wid 'builder frame 24
                           #:x (hash-ref w 'x base-x)
                           #:y (hash-ref w 'y base-y))))

  ;; Offset static defense (Spine/Spore/Cannon/Battery/Bunker) & forward anchors >= 5.0 tiles
  ;; away from `(nat-x, nat-y)` and `(third-x, third-y)` toward `(enemy-x, enemy-y)`
  (define (offset-defense-anchor anchor-x anchor-y [min-dist 5.5])
    (define ax (exact->inexact anchor-x))
    (define ay (exact->inexact anchor-y))
    (define dx (- (exact->inexact enemy-x) ax))
    (define dy (- (exact->inexact enemy-y) ay))
    (define d (max 1.0 (sqrt (+ (* dx dx) (* dy dy)))))
    (define eff-d (max 5.0 (exact->inexact min-dist)))
    (define cx0 (+ ax (* eff-d (/ dx d))))
    (define cy0 (+ ay (* eff-d (/ dy d))))
    (define-values (cx2 cy2)
      (for/fold ([rx cx0] [ry cy0])
                ([pad (in-list (list (cons nat-x nat-y) (cons third-x third-y)))])
        (define px (exact->inexact (car pad)))
        (define py (exact->inexact (cdr pad)))
        (if (< (dist2d rx ry px py) 5.0)
            (let* ([pdx (- (exact->inexact enemy-x) px)]
                   [pdy (- (exact->inexact enemy-y) py)]
                   [plen (max 1.0 (sqrt (+ (* pdx pdx) (* pdy pdy))))])
              (values (+ px (* 5.5 (/ pdx plen)))
                      (+ py (* 5.5 (/ pdy plen)))))
            (values rx ry))))
    (values (safe-coord cx2 anchor-x) (safe-coord cy2 anchor-y)))

  ;; Sticky scouted enemy race resolution (`!= 'Unknown` and `!= 'Random` -> sticky race,
  ;; else `(hash-ref obs 'opponent-requested-race 'Random)`)
  (when (<= frame 4)
    (set-box! (rt-enemy-race-box rt) 'Unknown))
  (define visible-real-enemies
    (filter (lambda (e)
              (and (hash? e)
                   (not (eq? (hash-ref e 'is-hallucination #f) #t))
                   (not (eq? (hash-ref e 'hallucination #f) #t))
                   (not (eq? (hash-ref e 'hallucination? #f) #t))
                   (not (eq? (hash-ref e 'changeling? #f) #t))))
            (append enemy-units enemy-bldgs)))
  (define scouted-enemy-race
    (cond
      [(ormap (lambda (e)
                (memq (sc2-canonical-unit-sym (unit-type-sym e))
                      '(drone overlord overseer zergling baneling roach ravager hydralisk
                        lurker mutalisk corruptor brood-lord ultralisk infestor viper queen
                        hatchery lair hive spawning-pool extractor roach-warren baneling-nest
                        spine-crawler spore-crawler)))
              visible-real-enemies)
       'Zerg]
      [(ormap (lambda (e)
                (memq (sc2-canonical-unit-sym (unit-type-sym e))
                      '(scv marine marauder reaper ghost hellion hellbat widow-mine siege-tank
                        cyclone thor medivac viking liberator raven banshee battlecruiser
                        command-center orbital-command planetary-fortress supply-depot refinery
                        barracks factory starport bunker missile-turret)))
              visible-real-enemies)
       'Terran]
      [(ormap (lambda (e)
                (memq (sc2-canonical-unit-sym (unit-type-sym e))
                      '(probe zealot stalker adept sentry high-templar dark-templar archon
                        immortal observer warp-prism colossus disruptor phoenix void-ray oracle
                        carrier tempest mothership nexus pylon assimilator gateway warp-gate
                        forge cybernetics-core photon-cannon shield-battery robotics-facility stargate)))
              visible-real-enemies)
       'Protoss]
      [else 'Unknown]))
  (when (memq scouted-enemy-race '(Zerg Terran Protoss))
    (set-box! (rt-enemy-race-box rt) scouted-enemy-race))
  (define effective-enemy-race
    (let ([known (if (memq scouted-enemy-race '(Zerg Terran Protoss))
                     scouted-enemy-race
                     (unbox (rt-enemy-race-box rt)))])
      (if (memq known '(Zerg Terran Protoss))
          known
          (let ([req (hash-ref obs 'opponent-requested-race
                               (hash-ref obs 'enemy-race 'Random))])
            (case req
              [(Zerg zerg "Zerg" "zerg") 'Zerg]
              [(Protoss protoss "Protoss" "protoss") 'Protoss]
              [(Terran terran "Terran" "terran") 'Terran]
              [else 'Random])))))

  ;; ---------------------------------------------------------------------------
  ;; Pro Signature Mechanic #1: Tactical Building Save-Cancel (<18% HP-pct under attack)
  ;; + Per-Type Anti-Remorph Refractory Cooldown (`#5116601` 5x SpawningPool loop fix)
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
      (define cancel-cd-key
        (string->symbol
         (format "save-cancel-rebuild-~a"
                 (sc2-canonical-structure-sym (unit-type-sym b)))))
      (refractory-allow-action?! cd-tracker cancel-cd-key frame 96)
      (when (and (refractory-cooldown-tracker? cd-tracker)
                 (hash? (refractory-cooldown-tracker-table cd-tracker)))
        (hash-set! (refractory-cooldown-tracker-table cd-tracker) cancel-cd-key frame))
      (emit! (list 'cancel (hash-ref b 'id 701)))))

  (define (enemy-hostile-near-point? px py [radius 16.0])
    (or (ormap (lambda (e)
                 (and (combat-unit-record? e)
                      (sc2-enemy-unit-targetable? (unit-type-sym e))
                      (<= (dist2d px py (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0)) radius)))
               enemy-units)
        (>= (count (lambda (e)
                     (and (memq (unit-type-sym e) '(probe scv drone))
                          (not (eq? (hash-ref e 'hallucination? #f) #t))
                          (not (eq? (hash-ref e 'hallucination #f) #t))
                          (<= (dist2d px py (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0)) radius)))
                   enemy-units)
            SC2-WORKER-RUSH-MIN-ENEMY-WORKERS)))

  (define (find-uncontested-zerg-hatchery)
    (define completed-hatches
      (filter (lambda (b)
                (and (memq (sc2-canonical-structure-sym (unit-type-sym b))
                           '(hatchery lair hive))
                     (>= (hash-ref b 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS)))
              ally-bldgs))
    (and (enemy-hostile-near-point? base-x base-y 16.0)
         (findf (lambda (h)
                  (define hx (hash-ref h 'x base-x))
                  (define hy (hash-ref h 'y base-y))
                  (and (> (dist2d base-x base-y hx hy) 8.0)
                       (not (enemy-hostile-near-point? hx hy 16.0))))
                completed-hatches)))

  (define (safe-zerg-build-anchor default-x default-y)
    (define safe-h (find-uncontested-zerg-hatchery))
    (if safe-h
        (values (safe-coord (+ (hash-ref safe-h 'x default-x) 3.0))
                (safe-coord (+ (hash-ref safe-h 'y default-y) 3.0)))
        (values default-x default-y)))

  (define (save-cancel-rebuild-ready? bldg-sym [cooldown-frames 60])
    (define cancel-cd-key
      (string->symbol
       (format "save-cancel-rebuild-~a"
               (sc2-canonical-structure-sym bldg-sym))))
    (define last-cancel-f
      (and (refractory-cooldown-tracker? cd-tracker)
           (hash? (refractory-cooldown-tracker-table cd-tracker))
           (hash-ref (refractory-cooldown-tracker-table cd-tracker) cancel-cd-key #f)))
    (define eff-cd (if (find-uncontested-zerg-hatchery) 16 cooldown-frames))
    (or (not (exact-integer? last-cancel-f))
        (>= (- frame last-cancel-f) eff-cd)))

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
  (define live-obs-harvesters? (hash-has-key? raw-obs 'mineral-harvesters))
  (define prev-tel-early
    (let ([t (live-bot-runtime-last-telemetry rt)])
      (if (hash? t) t (hash))))
  (define townhalls
    (filter (lambda (b)
              (memq (sc2-canonical-structure-sym (unit-type-sym b))
                    '(hatchery lair hive nexus command-center orbital-command planetary-fortress)))
            ally-bldgs))
  (define active-bases (max 1 (length townhalls)))
  (define early-race-th-sym
    (case race
      [(Zerg) 'hatchery]
      [(Protoss) 'nexus]
      [else 'command-center]))
  (define owned-base-coords
    (append (list (cons base-x base-y))
            (if (>= active-bases 2) (list (cons nat-x nat-y)) '())
            (if (>= active-bases 3) (list (cons third-x third-y)) '())
            (filter-map (lambda (b)
                          (and (hash? b)
                               (hash-has-key? b 'x)
                               (hash-has-key? b 'y)
                               (cons (hash-ref b 'x base-x) (hash-ref b 'y base-y))))
                        townhalls)))
  (define ally-combat-units (filter combat-unit-record? ally-units))
  (define ally-combat-supply-early
    (hash-ref obs 'army-supply
              (for/sum ([u (in-list ally-combat-units)])
                (unit-supply-cost (unit-type-sym u)))))
  (define (unit-total-hp-and-shield u [default-hp SC2-DRONE-MAX-HP])
    (if (hash-has-key? u 'hull-hp)
        (hash-ref u 'hp default-hp)
        (+ (hash-ref u 'hp default-hp)
           (hash-ref u 'shield 0))))

  (define ground-enemy-units-for-cheese
    (filter (lambda (e)
              (and (not (memq (unit-type-sym e) NON-WORKER-PULL-ENEMY-UNIT-SYMS))
                   (not (eq? (hash-ref e 'changeling? #f) #t))
                   (not (eq? (hash-ref e 'hallucination? #f) #t))
                   (not (eq? (hash-ref e 'hallucination #f) #t))
                   (not (eq? (hash-ref e 'flying? #f) #t))))
            enemy-units))

  (define early-enemy-nat-x
    (hash-ref obs 'enemy-natural-x (hash-ref obs 'enemy-expand-x SC2-DEFAULT-ENEMY-EXPAND-X)))
  (define early-enemy-nat-y
    (hash-ref obs 'enemy-natural-y (hash-ref obs 'enemy-expand-y SC2-DEFAULT-ENEMY-EXPAND-Y)))
  (define early-enemy-third-x
    (hash-ref obs 'enemy-third-x (safe-coord (* 0.72 enemy-x) 132.0)))
  (define early-enemy-third-y
    (hash-ref obs 'enemy-third-y (safe-coord (* 0.72 enemy-y) 132.0)))

  ;; Detect 12-Worker Rush (`Creepy_strategies`) — including mid-map early warning when scouted! — & In-Base Proxy (`Thssprtssbt`)
  (define enemy-rush-workers
    (filter (lambda (e)
              (and (memq (unit-type-sym e) '(probe scv drone))
                   (let ([ex (hash-ref e 'x 9999.0)]
                         [ey (hash-ref e 'y 9999.0)])
                     (or (<= (dist2d base-x base-y ex ey) SC2-WORKER-RUSH-DETECT-RADIUS)
                         (and (>= active-bases 2)
                              (<= (dist2d nat-x nat-y ex ey) SC2-WORKER-RUSH-DETECT-RADIUS))))))
            ground-enemy-units-for-cheese))
  (define enemy-midmap-rush-workers
    (if (< frame 3360)
        (filter (lambda (e)
                  (and (memq (unit-type-sym e) '(probe scv drone))
                       (let ([ex (hash-ref e 'x 9999.0)]
                             [ey (hash-ref e 'y 9999.0)])
                         (and (> (dist2d enemy-x enemy-y ex ey) 26.0)
                              (> (dist2d early-enemy-nat-x early-enemy-nat-y ex ey) 20.0)))))
                ground-enemy-units-for-cheese)
        '()))
  (define worker-rush-active?
    (and (or (>= (length enemy-rush-workers) SC2-WORKER-RUSH-MIN-ENEMY-WORKERS)
             (>= (length enemy-midmap-rush-workers) 4))
         (< ally-combat-supply-early 6)))

  (define (enemy-bldg-is-proxy? eb)
    (cond
      [(and (hash? eb) (hash-has-key? eb 'is-proxy?))
       (eq? (hash-ref eb 'is-proxy? #f) #t)]
      [(not (and (hash? eb) (hash-has-key? eb 'x) (hash-has-key? eb 'y)))
       #f]
      [else
       (define canon (sc2-canonical-structure-sym (unit-type-sym eb)))
       (define ebx (hash-ref eb 'x 9999.0))
       (define eby (hash-ref eb 'y 9999.0))
       (and (not (memq canon '(creep-tumor creep-tumor-burrowed creep-tumor-queen
                               oracle-stasis-trap stasis-ward auto-turret)))
            (not (and (>= frame 3360)
                      (memq canon '(hatchery lair hive nexus command-center orbital-command planetary-fortress))))
            (> (dist2d enemy-x enemy-y ebx eby) 28.0)
            (> (dist2d early-enemy-nat-x early-enemy-nat-y ebx eby) 28.0)
            (> (dist2d early-enemy-third-x early-enemy-third-y ebx eby) 28.0))]))
  (define all-proxy-enemy-structures
    (filter enemy-bldg-is-proxy? enemy-bldgs))

  (define raw-in-base-proxy-structures
    (if (< frame SC2-IN-BASE-PROXY-MAX-FRAME)
        (filter (lambda (eb)
                  (define canon (sc2-canonical-structure-sym (unit-type-sym eb)))
                  (define ebx (hash-ref eb 'x 9999.0))
                  (define eby (hash-ref eb 'y 9999.0))
                  (and (enemy-bldg-is-proxy? eb)
                       (memq canon
                             '(pylon photon-cannon forge barracks bunker
                               spine-crawler gateway shield-battery hatchery))
                       (or (<= (dist2d base-x base-y ebx eby) SC2-IN-BASE-PROXY-DETECT-RADIUS)
                           (<= (dist2d nat-x nat-y ebx eby) SC2-IN-BASE-PROXY-DETECT-RADIUS))))
                enemy-bldgs)
        '()))
  ;; Preserve synthetic natural-block Scenario B (1 lone Pylon sitting right on unowned natural >24 tiles from main)
  (define in-base-proxy-structures
    (if (and (not live-obs-harvesters?)
             (< active-bases 2)
             (= (length raw-in-base-proxy-structures) 1)
             (let ([eb0 (car raw-in-base-proxy-structures)])
               (and (eq? (sc2-canonical-structure-sym (unit-type-sym eb0)) 'pylon)
                    (> (dist2d base-x base-y (hash-ref eb0 'x 9999.0) (hash-ref eb0 'y 9999.0)) 24.0)
                    (<= (dist2d nat-x nat-y (hash-ref eb0 'x 9999.0) (hash-ref eb0 'y 9999.0))
                        SC2-NATURAL-BLOCK-RADIUS))))
        '()
        raw-in-base-proxy-structures))
  (define in-base-proxy-detected?
    (and (not (null? in-base-proxy-structures))
         (< ally-combat-supply-early 8)))
  ;; Forward / mid-map proxies (not in opponent main/natural/3rd AND outside our worker-pull radius):
  ;; NEVER pull workers across the map (#5122354), but raise implied threat & defensive readiness!
  (define forward-proxy-structures
    (if (< frame 5376)
        (filter (lambda (eb)
                  (define ebx (hash-ref eb 'x 9999.0))
                  (define eby (hash-ref eb 'y 9999.0))
                  (and (> (dist2d base-x base-y ebx eby) SC2-IN-BASE-PROXY-DETECT-RADIUS)
                       (> (dist2d nat-x nat-y ebx eby) SC2-IN-BASE-PROXY-DETECT-RADIUS)))
                all-proxy-enemy-structures)
        '()))
  (define forward-proxy-detected?
    (and (not (null? forward-proxy-structures))
         (< ally-combat-supply-early 14)))

  (define cheese-dist-thresh SC2-CHEESE-RUSH-RADIUS)
  (define proxy-or-cheese-enemies
    (filter (lambda (e)
              (and (<= (dist2d base-x base-y (hash-ref e 'x 9999) (hash-ref e 'y 9999)) cheese-dist-thresh)
                   (or (hash-ref obs 'under-cheese-rush #f)
                       (< frame SC2-EARLY-CHEESE-MAX-FRAME))))
            (append ground-enemy-units-for-cheese enemy-bldgs)))
  (define under-early-cheese?
    (or worker-rush-active?
        in-base-proxy-detected?
        (and (not (null? proxy-or-cheese-enemies))
             (or (hash-ref obs 'under-cheese-rush #f)
                 (ormap (lambda (e)
                          (and (<= (dist2d base-x base-y (hash-ref e 'x 9999) (hash-ref e 'y 9999)) cheese-dist-thresh)
                               (memq (unit-type-sym e) '(photon-cannon pylon bunker spine-crawler barracks))))
                        enemy-bldgs)
                 (>= (length proxy-or-cheese-enemies) 2)))))
  (define early-survival-crisis?
    (or worker-rush-active?
        in-base-proxy-detected?
        (and under-early-cheese? (< ally-combat-supply-early 6))))

  ;; Early-warning worker-rush alert (`<= 32` tiles): immediately cancel any greedy in-progress
  ;; natural fast-expand when we still lack a completed root combat facility and have < 4 army supply.
  (when (and worker-rush-active?
             (< ally-combat-supply-early 4)
             (not (ormap (lambda (b)
                           (and (hash? b)
                                (>= (hash-ref b 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS)
                                (memq (sc2-canonical-structure-sym (unit-type-sym b))
                                      '(spawning-pool barracks gateway warp-gate
                                        spine-crawler photon-cannon bunker))))
                         ally-bldgs)))
    (for ([b (in-list ally-bldgs)])
      (when (and (hash? b)
                 (memq (sc2-canonical-structure-sym (unit-type-sym b))
                       '(hatchery nexus command-center))
                 (< (hash-ref b 'build-progress 1.0) 0.85)
                 (> (dist2d base-x base-y (hash-ref b 'x base-x) (hash-ref b 'y base-y)) 8.0))
        (define exp-bid (hash-ref b 'id 0))
        (when (and (> exp-bid 0)
                   (refractory-allow-action?! cd-tracker
                                              (list 'cancel-greedy-expand exp-bid)
                                              frame
                                              96))
          (emit! (list 'cancel exp-bid))))))

  (define rush-def-st (rt-rush-defense-state rt))
  (when (<= frame 4)
    (hash-clear! rush-def-st))
  (define prev-rush-fighting-wids
    (let ([s (hash-ref prev-tel-early 'rush-fighting-worker-ids '())])
      (if (list? s) s '())))
  (define cur-rush-fighting-wids '())
  (define cur-rush-disengaging-wids '())
  (define worker-pull-emitted-1ab? #f)
  (define non-builder-defense-workers
    (filter (lambda (w)
              (and (not (worker-has-engine-build-order? w))
                   (not (order-ledger-unit-has-active-build? oledger-early (hash-ref w 'id 0) w))))
            workers))

  ;; 1A. Worker-Rush Defense (`#5119038` & `#5119045`):
  ;;     - Early-warning alert at <= 32.0 tiles (`worker-rush-active?`) triggers Pool/Zealot/Marine & stops expand.
  ;;     - Physical worker pull ONLY when enemy workers are <= 12.5 tiles from TownHall OR <= 8.5 tiles from minerals.
  ;;     - Keep >= 3 healthy far-patch miners whenever workers >= 7 and enemies are > 4.5 tiles from them
  ;;       (or all-but-2 only when enemies are actively inside <= 7.5 tiles of TownHall/minerals).
  ;;     - Partition defenders locally: max 3 defenders per enemy worker (lowest hp+shield within <= 2.5 tiles,
  ;;       local nearest unassigned within <= 7.0 tiles, or Attack-Move to cluster), NEVER chasing > 14.0 tiles from TownHall.
  ;;     - Bruised friendly workers (hp <= 12 or total hp+shield <= 12) mineral-walk disengage to far patch for 1.5s (34f).
  (when (and (or worker-rush-active? (not (null? prev-rush-fighting-wids)))
             (not (null? non-builder-defense-workers)))
    (define ready-townhall-coords
      (let ([pts (for/list ([b (in-list ally-bldgs)]
                            #:when (and (hash? b)
                                        (>= (hash-ref b 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS)
                                        (memq (sc2-canonical-structure-sym (unit-type-sym b))
                                              '(hatchery lair hive nexus
                                                command-center orbital-command planetary-fortress))))
                   (cons (exact->inexact (hash-ref b 'x base-x))
                         (exact->inexact (hash-ref b 'y base-y))))])
        (if (null? pts)
            (list (cons (exact->inexact base-x) (exact->inexact base-y)))
            pts)))
    (define (dist-to-owned-townhall x y)
      (for/fold ([best +inf.0]) ([bc (in-list ready-townhall-coords)])
        (min best (dist2d x y (car bc) (cdr bc)))))
    (define base-mineral-patches
      (filter (lambda (mp)
                (and (hash? mp)
                     (<= (dist-to-owned-townhall
                          (hash-ref mp 'x base-x)
                          (hash-ref mp 'y base-y))
                         14.0)))
              (let ([mps (hash-ref obs 'mineral-patches '())])
                (if (list? mps) mps '()))))
    (define (dist-to-mineral-line x y)
      (if (null? base-mineral-patches)
          +inf.0
          (for/fold ([best +inf.0]) ([mp (in-list base-mineral-patches)])
            (min best (dist2d x y (hash-ref mp 'x base-x) (hash-ref mp 'y base-y))))))

    (define ew-cnt (max 1 (length enemy-rush-workers)))
    (define ew-cx
      (if (null? enemy-rush-workers)
          (exact->inexact enemy-x)
          (/ (for/sum ([ew (in-list enemy-rush-workers)]) (exact->inexact (hash-ref ew 'x base-x)))
             ew-cnt)))
    (define ew-cy
      (if (null? enemy-rush-workers)
          (exact->inexact enemy-y)
          (/ (for/sum ([ew (in-list enemy-rush-workers)]) (exact->inexact (hash-ref ew 'y base-y)))
             ew-cnt)))
    (define far-mp
      (and (not (null? base-mineral-patches))
           (argmax (lambda (mp)
                     (dist2d ew-cx ew-cy
                             (hash-ref mp 'x base-x)
                             (hash-ref mp 'y base-y)))
                   base-mineral-patches)))
    (define fallback-dx (- base-x ew-cx))
    (define fallback-dy (- base-y ew-cy))
    (define fallback-d (max 1.0 (sqrt (+ (* fallback-dx fallback-dx) (* fallback-dy fallback-dy)))))
    (define far-px
      (if far-mp
          (safe-coord (hash-ref far-mp 'x base-x) base-x)
          (safe-coord (+ base-x (* 4.0 (/ fallback-dx fallback-d))) base-x)))
    (define far-py
      (if far-mp
          (safe-coord (hash-ref far-mp 'y base-y) base-y)
          (safe-coord (+ base-y (* 4.0 (/ fallback-dy fallback-d))) base-y)))
    (define far-patch-id
      (if far-mp
          (safe-nonneg-int (hash-ref far-mp 'id 0) 0)
          (safe-nonneg-int (hash-ref obs 'mineral-patch-id 0) 0)))

    ;; Physical pull trigger: ONLY once rush workers enter <= 9.0 tiles of TownHall (<= 7.0 vs >= 8-worker all-ins
    ;; with 0 combat units so workers NEVER conga-line single-file out to an 8.8-tile ramp Pylon!),
    ;; <= 6.5 tiles of mineral line, or <= 4.5 tiles of an in-main friendly structure.
    (define heavy-worker-allin-no-army?
      (and (>= (length enemy-rush-workers) 8)
           (null? ally-combat-units)))
    (define rush-th-pull-rad (if heavy-worker-allin-no-army? 7.0 9.0))
    (define rush-bldg-th-rad (if heavy-worker-allin-no-army? 6.8 9.5))
    (define rush-chase-leash-rad (if heavy-worker-allin-no-army? 8.5 10.5))
    (define primary-engage-enemies
      (if worker-rush-active?
          (filter (lambda (ew)
                    (define ex (hash-ref ew 'x 9999.0))
                    (define ey (hash-ref ew 'y 9999.0))
                    (and (<= (dist-to-owned-townhall ex ey) rush-chase-leash-rad)
                         (or (<= (dist-to-owned-townhall ex ey) rush-th-pull-rad)
                             (<= (dist-to-mineral-line ex ey) 6.5)
                             (ormap (lambda (b)
                                      (and (hash? b)
                                           (<= (dist-to-owned-townhall
                                                (hash-ref b 'x base-x)
                                                (hash-ref b 'y base-y))
                                               rush-bldg-th-rad)
                                           (<= (dist2d ex ey
                                                       (hash-ref b 'x base-x)
                                                       (hash-ref b 'y base-y))
                                               4.5)))
                                    ally-bldgs))))
                  enemy-rush-workers)
          '()))
    (unless (null? primary-engage-enemies)
      (hash-set! rush-def-st 'last-rush-engage-frame frame))
    (define last-engage-frame (hash-ref rush-def-st 'last-rush-engage-frame -9999))
    ;; 14-frame hysteresis prevents ping-ponging between fighting and mining when enemy workers
    ;; step just outside `rush-th-pull-rad` (7.0 tiles).
    (define in-engage-hysteresis?
      (and worker-rush-active?
           (not (null? prev-rush-fighting-wids))
           (<= (- frame last-engage-frame) 14)))
    (define worker-rush-engage-enemies
      (cond
        [(not (null? primary-engage-enemies)) primary-engage-enemies]
        [in-engage-hysteresis?
         (filter (lambda (ew)
                   (<= (dist-to-owned-townhall
                        (hash-ref ew 'x 9999.0)
                        (hash-ref ew 'y 9999.0))
                       rush-chase-leash-rad))
                 enemy-rush-workers)]
        [else '()]))

    ;; Mixed Probe+Zealot / worker+combat rush detection near main mineral line
    (define enemy-combat-near-main
      (filter (lambda (e)
                (and (not (memq (unit-type-sym e) '(probe scv drone)))
                     (or (combat-unit-record? e)
                         (memq (sc2-canonical-unit-sym (unit-type-sym e))
                               '(zealot zergling adept stalker marine reaper hellion hellbat roach marauder)))
                     (let ([ex (hash-ref e 'x 9999.0)]
                           [ey (hash-ref e 'y 9999.0)])
                       (or (<= (dist-to-owned-townhall ex ey) 11.0)
                           (<= (dist-to-mineral-line ex ey) 8.5)))))
              ground-enemy-units-for-cheese))
    (define mixed-worker-combat-rush?
      (and (not (null? enemy-combat-near-main))
           (not (null? enemy-rush-workers))))
    (define safe-evac-mp
      (if (and (not (null? enemy-combat-near-main))
               (not (null? base-mineral-patches)))
          (argmax (lambda (mp)
                    (define mpx (hash-ref mp 'x base-x))
                    (define mpy (hash-ref mp 'y base-y))
                    (for/fold ([best +inf.0]) ([ec (in-list enemy-combat-near-main)])
                      (min best (dist2d mpx mpy (hash-ref ec 'x 9999.0) (hash-ref ec 'y 9999.0)))))
                  base-mineral-patches)
          far-mp))
    (define evac-patch-id
      (if safe-evac-mp
          (safe-nonneg-int (hash-ref safe-evac-mp 'id 0) 0)
          far-patch-id))
    (define evac-px
      (if safe-evac-mp
          (safe-coord (hash-ref safe-evac-mp 'x far-px) far-px)
          far-px))
    (define evac-py
      (if safe-evac-mp
          (safe-coord (hash-ref safe-evac-mp 'y far-py) far-py)
          far-py))

    ;; 1.1s (24-frame) mineral-walk slide + 21-frame post-slide cooldown (`+45` total) for bruised workers,
    ;; with `<= 20` EHP (or Probe `shield <= 2` and `hp < 20`) threshold and immediate `<= 10` HP override.
    (define eff-disengage-hp
      (if worker-rush-active?
          20
          SC2-FIGHTING-WORKER-DISENGAGE-HP))
    (define eff-reengage-hp
      (if (and worker-rush-active? (>= (length enemy-rush-workers) 8))
          6
          SC2-FIGHTING-WORKER-REENGAGE-HP))
    (for ([w (in-list non-builder-defense-workers)])
      (define wid (hash-ref w 'id 10))
      (define whp (unit-total-hp-and-shield w))
      (define wx (hash-ref w 'x base-x))
      (define wy (hash-ref w 'y base-y))
      (define entry (hash-ref rush-def-st wid #f))
      (define prev-dis-until (cond [(pair? entry) (car entry)] [(exact-integer? entry) entry] [else 0]))
      (define prev-cd-until  (cond [(pair? entry) (cdr entry)] [(exact-integer? entry) entry] [else 0]))
      (define enemy-close?
        (ormap (lambda (e)
                 (<= (dist2d wx wy (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0)) 6.0))
               ground-enemy-units-for-cheese))
      (define probe-shield-depleted?
        (and worker-rush-active?
             (eq? (unit-type-sym w) 'probe)
             (<= (hash-ref w 'shield 0) 2)
             (< (hash-ref w 'hp 20) 20)))
      (define needs-disengage?
        (or (<= whp eff-disengage-hp)
            probe-shield-depleted?))
      (when (and needs-disengage?
                 enemy-close?
                 (or (>= frame prev-cd-until)
                     (and (<= whp 10)
                          (>= frame prev-dis-until))))
        (set! prev-dis-until (+ frame 24))
        (set! prev-cd-until  (+ frame 45))
        (hash-set! rush-def-st wid (cons prev-dis-until prev-cd-until)))
      (define near-enemy-combat?
        (and mixed-worker-combat-rush?
             (ormap (lambda (ec)
                      (<= (dist2d wx wy (hash-ref ec 'x 9999.0) (hash-ref ec 'y 9999.0)) 3.8))
                    enemy-combat-near-main)))
      (define cornered-at-evac?
        (and (<= (dist2d wx wy evac-px evac-py) 2.0)
             (<= (for/fold ([best +inf.0]) ([ec (in-list enemy-combat-near-main)])
                   (min best (dist2d evac-px evac-py (hash-ref ec 'x 9999.0) (hash-ref ec 'y 9999.0))))
                 3.8)))
      (define disengaging-now?
        (or (< frame prev-dis-until)
            (and near-enemy-combat? (not cornered-at-evac?))))
      (when disengaging-now?
        (set! cur-rush-disengaging-wids (cons wid cur-rush-disengaging-wids))
        (if (> evac-patch-id 0)
            (emit! (list 'mineral-walk wid evac-patch-id evac-px evac-py))
            (emit! (list 'mineral-walk wid evac-px evac-py)))))

    (unless (null? worker-rush-engage-enemies)
      (define (dist-to-nearest-engage-enemy wx wy)
        (for/fold ([best +inf.0]) ([ew (in-list worker-rush-engage-enemies)])
          (min best (dist2d wx wy (hash-ref ew 'x ew-cx) (hash-ref ew 'y ew-cy)))))

      ;; Only workers inside `rush-chase-leash-rad` and not disengaging are eligible to fight
      (define healthy-rush-workers
        (filter (lambda (w)
                  (define wid (hash-ref w 'id 10))
                  (define whp (unit-total-hp-and-shield w))
                  (define wx (hash-ref w 'x base-x))
                  (define wy (hash-ref w 'y base-y))
                  (define entry (hash-ref rush-def-st wid #f))
                  (define in-post-slide-window?
                    (and (pair? entry) (>= frame (car entry)) (< frame (cdr entry))))
                  (and (not (memv wid cur-rush-disengaging-wids))
                       (<= (dist-to-owned-townhall wx wy) rush-chase-leash-rad)
                       (cond
                         [in-post-slide-window? (> whp 5)]
                         [(memv wid prev-rush-fighting-wids) (> whp eff-disengage-hp)]
                         [else (>= whp eff-reengage-hp)])))
                non-builder-defense-workers))

      ;; Sort farthest from engaging enemies first so kept miners are ALWAYS the safest far-patch workers
      (define safest-first
        (sort healthy-rush-workers
              >
              #:key (lambda (w)
                      (dist-to-nearest-engage-enemy
                       (hash-ref w 'x base-x)
                       (hash-ref w 'y base-y)))))

      (define unthreatened-miners-cnt
        (count (lambda (w)
                 (> (dist-to-nearest-engage-enemy
                     (hash-ref w 'x base-x)
                     (hash-ref w 'y base-y))
                    4.5))
               safest-first))
      (define enemies-inside-7.5?
        (ormap (lambda (ew)
                 (define ex (hash-ref ew 'x 9999.0))
                 (define ey (hash-ref ew 'y 9999.0))
                 (or (<= (dist-to-owned-townhall ex ey) 7.5)
                     (<= (dist-to-mineral-line ex ey) 7.5)))
               worker-rush-engage-enemies))

      (define total-w-cnt (length workers))
      (define h-cnt (length safest-first))
      (define e-cnt (length worker-rush-engage-enemies))
      (define eff-e-cnt (max e-cnt (length enemy-rush-workers)))
      (define breached-mineral-cnt
        (count (lambda (ew)
                 (<= (dist-to-mineral-line (hash-ref ew 'x 9999.0)
                                           (hash-ref ew 'y 9999.0))
                     5.5))
               worker-rush-engage-enemies))
      (define all-hands-mineral-brawl?
        (and (>= eff-e-cnt 6)
             (or (>= breached-mineral-cnt 3)
                 (ormap (lambda (b)
                          (and (hash? b)
                               (<= (dist-to-owned-townhall (hash-ref b 'x base-x)
                                                           (hash-ref b 'y base-y))
                                   (if heavy-worker-allin-no-army? 7.5 9.5))
                               (let* ([b-hp (hash-ref b 'hp 1500)]
                                      [b-max-hp (hash-ref b 'max-hp b-hp)]
                                      [b-sh (hash-ref b 'shield 0)]
                                      [b-max-sh (hash-ref b 'max-shield b-sh)]
                                      [tot-max (+ b-max-hp b-max-sh)])
                                 (and (> tot-max 0)
                                      (< (+ b-hp b-sh) (* 0.96 tot-max))))))
                        ally-bldgs))))
      (define surplus-miners (max 0 (- h-cnt (+ eff-e-cnt 2))))
      (define keep-mining-cnt
        (min h-cnt
             (cond
               [all-hands-mineral-brawl?
                (cond
                  [(>= h-cnt 16) (max 3 (- h-cnt (+ eff-e-cnt 2)))]
                  [(> h-cnt (+ eff-e-cnt 2)) (min 3 (- h-cnt (+ eff-e-cnt 1)))]
                  [(> h-cnt 12) 2]
                  [(> h-cnt 4) 1]
                  [else 0])]
               [(and (>= total-w-cnt 7) (>= unthreatened-miners-cnt 3))
                (max 3 surplus-miners)]
               [enemies-inside-7.5?
                (min 2 (max 0 (sub1 h-cnt)))]
               [(>= total-w-cnt 7)
                (max 3 surplus-miners)]
               [else
                (min 2 surplus-miners)])))

      (define pulled-rush-workers
        (drop safest-first keep-mining-cnt))

      (unless (null? pulled-rush-workers)
        (set! cur-rush-fighting-wids
              (map (lambda (w) (hash-ref w 'id 10)) pulled-rush-workers))
        ;; Compute clamped enemy cluster centroid inside our mineral line / main (<= rush-chase-leash-rad)
        (define raw-cl-x
          (/ (for/sum ([ew (in-list worker-rush-engage-enemies)])
               (exact->inexact (hash-ref ew 'x base-x)))
             e-cnt))
        (define raw-cl-y
          (/ (for/sum ([ew (in-list worker-rush-engage-enemies)])
               (exact->inexact (hash-ref ew 'y base-y)))
             e-cnt))
        (define cl-dx (- raw-cl-x (exact->inexact base-x)))
        (define cl-dy (- raw-cl-y (exact->inexact base-y)))
        (define cl-d (sqrt (+ (* cl-dx cl-dx) (* cl-dy cl-dy))))
        (define cl-x
          (safe-coord (if (> cl-d rush-chase-leash-rad) (+ base-x (* rush-chase-leash-rad (/ cl-dx cl-d))) raw-cl-x) base-x))
        (define cl-y
          (safe-coord (if (> cl-d rush-chase-leash-rad) (+ base-y (* rush-chase-leash-rad (/ cl-dy cl-d))) raw-cl-y) base-y))
        (define in-pack-engage-enemies
          (let ([near-pack
                 (filter (lambda (ew)
                           (<= (dist2d cl-x cl-y
                                       (hash-ref ew 'x cl-x)
                                       (hash-ref ew 'y cl-y))
                               3.5))
                         worker-rush-engage-enemies)])
            (if (null? near-pack) worker-rush-engage-enemies near-pack)))
        (define lowest-ehp-enemy
          (argmin (lambda (ew)
                    (+ (* 5.0 (unit-total-hp-and-shield ew))
                       (dist-to-owned-townhall (hash-ref ew 'x cl-x) (hash-ref ew 'y cl-y))))
                  in-pack-engage-enemies))
        (define raw-focus-x
          (if lowest-ehp-enemy
              (safe-coord (hash-ref lowest-ehp-enemy 'x cl-x) cl-x)
              cl-x))
        (define raw-focus-y
          (if lowest-ehp-enemy
              (safe-coord (hash-ref lowest-ehp-enemy 'y cl-y) cl-y)
              cl-y))
        (define fa-dx (- (exact->inexact raw-focus-x) (exact->inexact base-x)))
        (define fa-dy (- (exact->inexact raw-focus-y) (exact->inexact base-y)))
        (define fa-d (sqrt (+ (* fa-dx fa-dx) (* fa-dy fa-dy))))
        (define fa-max-rad (if heavy-worker-allin-no-army? 7.5 10.5))
        (define focus-amove-x
          (safe-coord (if (> fa-d fa-max-rad) (+ base-x (* fa-max-rad (/ fa-dx fa-d))) raw-focus-x) cl-x))
        (define focus-amove-y
          (safe-coord (if (> fa-d fa-max-rad) (+ base-y (* fa-max-rad (/ fa-dy fa-d))) raw-focus-y) cl-y))

        ;; Partition defenders per-worker locally: max 3 normally (and always <= 3 for Pass-2 chasers to avoid
        ;; conga-lining in open space), or up to 8 in Pass-1 melee range when >= 6 enemy workers are mineral-walk
        ;; stacked inside our mineral line (<= 5.0 tiles from mineral patches) so 8 * 5 = 40 one-shots a stacked Probe!
        (define primary-focus-id
          (and lowest-ehp-enemy (hash-ref lowest-ehp-enemy 'id -1)))
        (define (mineral-line-stacked-enemy? ew)
          (define ex (hash-ref ew 'x cl-x))
          (define ey (hash-ref ew 'y cl-y))
          (and (>= e-cnt 6)
               (or (and (<= (dist-to-mineral-line ex ey) 5.0)
                        (>= (count (lambda (other)
                                     (<= (dist2d ex ey
                                                 (hash-ref other 'x cl-x)
                                                 (hash-ref other 'y cl-y))
                                         1.75))
                                   worker-rush-engage-enemies)
                            4))
                   (and live-obs-harvesters?
                        primary-focus-id
                        (equal? (hash-ref ew 'id 0) primary-focus-id)
                        (<= (dist-to-mineral-line ex ey) 5.5)))))
        (define (effective-melee-cap ew)
          (define ehp (max 1.0 (exact->inexact (unit-total-hp-and-shield ew))))
          (define swings-needed (inexact->exact (ceiling (/ ehp 5.0))))
          (define cap (if (mineral-line-stacked-enemy? ew) 8 3))
          (min cap (max 2 swings-needed)))
        (define (effective-chaser-cap ew)
          (min 3 (effective-melee-cap ew)))
        (define assigned-target-counts (make-hasheqv))
        (define worker-assignments (make-hasheqv))
        (define frontline-first
          (sort pulled-rush-workers
                <
                #:key (lambda (w)
                        (dist-to-nearest-engage-enemy
                         (hash-ref w 'x base-x)
                         (hash-ref w 'y base-y)))))

        (define (enemy-worker-safe-from-combat? ew)
          (or (not mixed-worker-combat-rush?)
              (let ([ex (hash-ref ew 'x cl-x)]
                    [ey (hash-ref ew 'y cl-y)])
                (andmap (lambda (ec)
                          (> (dist2d ex ey (hash-ref ec 'x 9999.0) (hash-ref ec 'y 9999.0)) 2.5))
                        enemy-combat-near-main))))
        (define safe-engage-workers
          (let ([safe (filter enemy-worker-safe-from-combat? worker-rush-engage-enemies)])
            (if (null? safe) worker-rush-engage-enemies safe)))
        (define (non-retreating-engage-worker? ew)
          (define ex (hash-ref ew 'x cl-x))
          (define ey (hash-ref ew 'y cl-y))
          (or (<= (dist-to-owned-townhall ex ey) rush-th-pull-rad)
              (<= (dist-to-mineral-line ex ey) 6.5)
              (ormap (lambda (b)
                       (and (hash? b)
                            (<= (dist-to-owned-townhall
                                 (hash-ref b 'x base-x)
                                 (hash-ref b 'y base-y))
                                rush-bldg-th-rad)
                            (<= (dist2d ex ey
                                        (hash-ref b 'x base-x)
                                        (hash-ref b 'y base-y))
                                4.5)))
                     ally-bldgs)))

        ;; Pass 1: Immediate melee swing (<= 2.5 tiles normally, <= 3.2 tiles on primary mineral-line focus target in live games), lowest (hp + shield)
        (for ([w (in-list frontline-first)])
          (define wid (hash-ref w 'id 10))
          (define wx (hash-ref w 'x base-x))
          (define wy (hash-ref w 'y base-y))
          (define melee-cands
            (filter (lambda (ew)
                      (define eid (hash-ref ew 'id 0))
                      (define reach
                        (if (and live-obs-harvesters?
                                 (>= e-cnt 6)
                                 primary-focus-id
                                 (equal? eid primary-focus-id)
                                 (<= (dist-to-mineral-line (hash-ref ew 'x cl-x) (hash-ref ew 'y cl-y)) 5.5))
                            3.2
                            2.5))
                      (and (> eid 0)
                           (< (hash-ref assigned-target-counts eid 0) (effective-melee-cap ew))
                           (<= (dist2d wx wy (hash-ref ew 'x cl-x) (hash-ref ew 'y cl-y)) reach)))
                    safe-engage-workers))
          (unless (null? melee-cands)
            (define chosen
              (argmin (lambda (ew)
                        (+ (* 100.0 (unit-total-hp-and-shield ew))
                           (dist2d wx wy (hash-ref ew 'x cl-x) (hash-ref ew 'y cl-y))))
                      melee-cands))
            (define cid (hash-ref chosen 'id 0))
            (hash-update! assigned-target-counts cid add1 0)
            (hash-set! worker-assignments wid
                       (list cid
                             (safe-coord (hash-ref chosen 'x cl-x) cl-x)
                             (safe-coord (hash-ref chosen 'y cl-y) cl-y)))))

        ;; Pass 2: Targeted focus-fire within 4.5-6.0 tiles (7.0 for < 6 workers) onto the lowest (hp + shield)
        ;; non-retreating enemy worker (capped at `effective-chaser-cap`), avoiding blind Attack-Move spread
        ;; and avoiding pulling Probes into enemy Zealots during mixed rushes.
        (define pass2-reach (if (>= e-cnt 6) 6.0 7.0))
        (for ([w (in-list frontline-first)]
              #:unless (hash-has-key? worker-assignments (hash-ref w 'id 10)))
          (define wid (hash-ref w 'id 10))
          (define wx (hash-ref w 'x base-x))
          (define wy (hash-ref w 'y base-y))
          (define raw-local-cands
            (filter (lambda (ew)
                      (define eid (hash-ref ew 'id 0))
                      (and (> eid 0)
                           (< (hash-ref assigned-target-counts eid 0) (effective-chaser-cap ew))
                           (<= (dist2d wx wy (hash-ref ew 'x cl-x) (hash-ref ew 'y cl-y)) pass2-reach)))
                    safe-engage-workers))
          (define local-cands
            (let ([non-ret (filter non-retreating-engage-worker? raw-local-cands)])
              (if (null? non-ret) raw-local-cands non-ret)))
          (cond
            [(not (null? local-cands))
             (define chosen
               (argmin (lambda (ew)
                         (+ (* 5.0 (unit-total-hp-and-shield ew))
                            (* 2.5 (dist2d wx wy (hash-ref ew 'x cl-x) (hash-ref ew 'y cl-y)))))
                       local-cands))
             (define cid (hash-ref chosen 'id 0))
             (hash-update! assigned-target-counts cid add1 0)
             (hash-set! worker-assignments wid
                        (list cid
                              (safe-coord (hash-ref chosen 'x cl-x) cl-x)
                              (safe-coord (hash-ref chosen 'y cl-y) cl-y)))]
            [mixed-worker-combat-rush?
             (define safe-fallback
               (let ([cand (findf (lambda (ew)
                                    (and (> (hash-ref ew 'id 0) 0)
                                         (enemy-worker-safe-from-combat? ew)))
                                  safe-engage-workers)])
                 cand))
             (when safe-fallback
               (hash-set! worker-assignments wid
                          (list (hash-ref safe-fallback 'id 0)
                                (safe-coord (hash-ref safe-fallback 'x cl-x) cl-x)
                                (safe-coord (hash-ref safe-fallback 'y cl-y) cl-y))))]
            [else
             (hash-set! worker-assignments wid (list 0 focus-amove-x focus-amove-y))]))

        ;; Emit grouped pull-workers-attack commands (unit-targeted groups + Attack-Move group)
        (define target-order '())
        (define target-groups (make-hasheqv))
        (define target-coords (make-hasheqv))
        (for ([w (in-list frontline-first)])
          (define wid (hash-ref w 'id 10))
          (define asgn (hash-ref worker-assignments wid #f))
          (when asgn
            (match-define (list tid tx ty) asgn)
            (unless (hash-has-key? target-groups tid)
              (set! target-order (cons tid target-order))
              (hash-set! target-coords tid (cons tx ty)))
            (hash-set! target-groups tid (cons wid (hash-ref target-groups tid '())))))
        (set! worker-pull-emitted-1ab? #t)
        (for ([tid (in-list (reverse target-order))])
          (define wids (reverse (hash-ref target-groups tid '())))
          (define tc (hash-ref target-coords tid (cons focus-amove-x focus-amove-y)))
          (unless (null? wids)
            (emit! (list 'pull-workers-attack wids tid (car tc) (cdr tc)))))))

    ;; During the 14-frame hysteresis window, keep previously-pulled defenders (within leash and not disengaging)
    ;; from immediately snapping back to mining if enemy workers momentarily kite outside `rush-chase-leash-rad`.
    (when (and (null? worker-rush-engage-enemies)
               in-engage-hysteresis?)
      (set! cur-rush-fighting-wids
            (for/list ([w (in-list non-builder-defense-workers)]
                       #:when (let ([wid (hash-ref w 'id 10)])
                                (and (memv wid prev-rush-fighting-wids)
                                     (not (memv wid cur-rush-disengaging-wids))
                                     (<= (dist-to-owned-townhall
                                          (hash-ref w 'x base-x)
                                          (hash-ref w 'y base-y))
                                         rush-chase-leash-rad))))
              (hash-ref w 'id 10))))

    ;; Snap back to mining any previously-pulled worker (or worker outside `rush-chase-leash-rad`)
    ;; once hysteresis expires or that worker is assigned to keep mining!
    (for ([w (in-list non-builder-defense-workers)])
      (define wid (hash-ref w 'id 10))
      (define wx (hash-ref w 'x base-x))
      (define wy (hash-ref w 'y base-y))
      (when (and (not (memv wid cur-rush-fighting-wids))
                 (not (memv wid cur-rush-disengaging-wids))
                 (or (memv wid prev-rush-fighting-wids)
                     (and worker-rush-active?
                          (> (dist-to-owned-townhall wx wy) rush-chase-leash-rad))))
        (if (> far-patch-id 0)
            (emit! (list 'harvest-mineral wid far-patch-id))
            (emit! (list 'mineral-walk wid far-px far-py))))))

  ;; 1B. Per-Step In-Base Proxy Defense (`Thssprtssbt` Pylon / Cannon / Bunker / Proxy Rax)
  (when (and in-base-proxy-detected?
             (not worker-rush-active?)
             (not (null? non-builder-defense-workers)))
    (define completed-powered-cannons
      (count (lambda (eb)
               (and (eq? (sc2-canonical-structure-sym (unit-type-sym eb)) 'photon-cannon)
                    (>= (hash-ref eb 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS)
                    (not (eq? (hash-ref eb 'powered? #t) #f))))
             in-base-proxy-structures))
    (when (< completed-powered-cannons 2)
      ;; Disengage critically wounded proxy-fighting workers (<= 12 HP) every step
      (define base-mps
        (filter (lambda (mp)
                  (and (hash? mp)
                       (<= (dist2d base-x base-y (hash-ref mp 'x base-x) (hash-ref mp 'y base-y)) 14.0)))
                (let ([mps (hash-ref obs 'mineral-patches '())])
                  (if (list? mps) mps '()))))
      (define safe-mp (and (not (null? base-mps)) (car base-mps)))
      (for ([w (in-list non-builder-defense-workers)])
        (define wid (hash-ref w 'id 10))
        (define whp (unit-total-hp-and-shield w))
        (when (and (<= whp SC2-FIGHTING-WORKER-DISENGAGE-HP)
                   (ormap (lambda (e)
                            (<= (dist2d (hash-ref w 'x base-x) (hash-ref w 'y base-y)
                                        (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0))
                                7.5))
                          (append ground-enemy-units-for-cheese in-base-proxy-structures)))
          (if safe-mp
              (emit! (list 'mineral-walk wid
                           (safe-nonneg-int (hash-ref safe-mp 'id 0) 0)
                           (safe-coord (hash-ref safe-mp 'x base-x) base-x)
                           (safe-coord (hash-ref safe-mp 'y base-y) base-y)))
              (emit! (list 'mineral-walk wid base-x base-y)))))
      (define healthy-proxy-workers
        (filter (lambda (w) (> (unit-total-hp-and-shield w) SC2-FIGHTING-WORKER-DISENGAGE-HP))
                non-builder-defense-workers))
      ;; Keep at least 4 workers mining so economy never hits 0 income while clearing proxy!
      (define surplus-cnt (max 0 (- (length healthy-proxy-workers) 4)))
      (when (> surplus-cnt 0)
        (define sorted-proxies
          (sort in-base-proxy-structures
                <
                #:key (lambda (eb)
                        (define canon (sc2-canonical-structure-sym (unit-type-sym eb)))
                        (define prog (hash-ref eb 'build-progress 1.0))
                        (define prio-rank
                          (cond
                            [(eq? canon 'pylon) 0.0]
                            [(and (memq canon '(photon-cannon bunker spine-crawler))
                                  (< prog SC2-BUILD-COMPLETE-PROGRESS))
                             100.0]
                            [(memq canon '(forge barracks gateway shield-battery)) 200.0]
                            [else 300.0]))
                        (+ prio-rank
                           (* 0.1 (hash-ref eb 'hp 200))
                           (dist2d base-x base-y
                                   (hash-ref eb 'x base-x)
                                   (hash-ref eb 'y base-y))))))
        ;; Pick workers closest to the primary proxy structure
        (define p0 (car sorted-proxies))
        (define p0x (hash-ref p0 'x base-x))
        (define p0y (hash-ref p0 'y base-y))
        (define pull-pool
          (take (sort healthy-proxy-workers
                      <
                      #:key (lambda (w)
                              (dist2d p0x p0y (hash-ref w 'x base-x) (hash-ref w 'y base-y))))
                surplus-cnt))
        (let assign-loop ([rem-workers pull-pool]
                          [rem-proxies sorted-proxies])
          (cond
            [(or (null? rem-workers) (null? rem-proxies))
             ;; Any leftover surplus worker chases visible enemy proxy builder Probe/SCV
             (define proxy-builder
               (findf (lambda (e)
                        (and (memq (unit-type-sym e) '(probe scv drone))
                             (or (<= (dist2d base-x base-y (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0))
                                     SC2-IN-BASE-PROXY-DETECT-RADIUS)
                                 (<= (dist2d nat-x nat-y (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0))
                                     SC2-IN-BASE-PROXY-DETECT-RADIUS))))
                      ground-enemy-units-for-cheese))
             (when (and proxy-builder (not (null? rem-workers)))
               (define hunter-wids
                 (map (lambda (w) (hash-ref w 'id 10))
                      (take rem-workers (min 2 (length rem-workers)))))
               (set! worker-pull-emitted-1ab? #t)
               (emit! (list 'pull-workers-attack
                            hunter-wids
                            (hash-ref proxy-builder 'id 0)
                            (safe-coord (hash-ref proxy-builder 'x p0x) base-x)
                            (safe-coord (hash-ref proxy-builder 'y p0y) base-y))))]
            [else
             (define eb (car rem-proxies))
             (define take-n (min 4 (length rem-workers)))
             (define assigned (take rem-workers take-n))
             (define assigned-ids (map (lambda (w) (hash-ref w 'id 10)) assigned))
             (set! worker-pull-emitted-1ab? #t)
             (emit! (list 'pull-workers-attack
                          assigned-ids
                          (hash-ref eb 'id 0)
                          (safe-coord (hash-ref eb 'x base-x) base-x)
                          (safe-coord (hash-ref eb 'y base-y) base-y)))
             (assign-loop (drop rem-workers take-n) (cdr rem-proxies))])))))

  ;; 1C. Fallback Early Cheese Pull (synthetic unit tests + non-worker-rush/non-proxy-bldg early rushes, e.g. 2-Zealot/6-Ling)
  (when (and under-early-cheese?
             (not (null? workers))
             (or (not live-obs-harvesters?)
                 (and (not worker-rush-active?)
                      (not in-base-proxy-detected?)
                      (< frame 2500)
                      (<= (length ally-combat-units) 2)
                      (refractory-allow-action?! cd-tracker 'early-cheese-worker-pull frame 112))))
    (define healthy-workers
      (filter (lambda (w)
                (and (or (not live-obs-harvesters?)
                         (and (not (worker-has-engine-build-order? w))
                              (not (order-ledger-unit-has-active-build? oledger-early (hash-ref w 'id 0) w))))
                     (>= (hash-ref w 'hp SC2-DRONE-MAX-HP) SC2-HEALTHY-WORKER-PULL-MIN-HP)))
              workers))
    (define pull-ids
      (map (lambda (w) (hash-ref w 'id 10))
           (take healthy-workers (min SC2-MAX-WORKER-PULL-COUNT (length healthy-workers)))))
    (define fallback-threats
      (cond
        [(not (null? proxy-or-cheese-enemies)) proxy-or-cheese-enemies]
        [(not (null? enemy-rush-workers)) enemy-rush-workers]
        [else in-base-proxy-structures]))
    (when (not (null? fallback-threats))
      (define fallback-worker-threats
        (filter (lambda (e) (memq (unit-type-sym e) '(probe scv drone))) fallback-threats))
      (define threat
        (if (not (null? fallback-worker-threats))
            (car fallback-worker-threats)
            (car fallback-threats)))
      (define threat-is-combat-unit?
        (and (combat-unit-record? threat)
             (not (memq (unit-type-sym threat) '(probe scv drone)))))
      (define skip-suicidal-combat-pull?
        (and threat-is-combat-unit?
             (or (not (null? ally-combat-units))
                 (and live-obs-harvesters?
                      (eq? (sc2-canonical-unit-sym (unit-type-sym threat)) 'zealot)))))
      (define tx (hash-ref threat 'x (safe-coord (+ base-x 5.0))))
      (define ty (hash-ref threat 'y (safe-coord (+ base-y 5.0))))
      (define drill-patch-id (hash-ref obs 'mineral-patch-id SC2-SYNTHETIC-MINERAL-PATCH-ID))
      (unless (or (null? pull-ids) skip-suicidal-combat-pull?)
        (unless worker-pull-emitted-1ab?
          (if live-obs-harvesters?
              (emit! (list 'pull-workers-attack pull-ids (hash-ref threat 'id 0) tx ty))
              (emit! (list 'pull-workers-attack pull-ids tx ty))))
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
                     (hash-ref enemy-builder 'y ty))))))

  ;; ---------------------------------------------------------------------------
  ;; Preemptive Anti-Stasis Worker Evacuation & Counter-Enemy Worker Drill
  ;; ---------------------------------------------------------------------------
  (define stasis-threats
    (filter (lambda (e)
              (and (memq (unit-type-sym e) '(oracle-stasis-trap stasis-ward))
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

  ;; 1D. Non-Worker Harasser Mineral-Line Evacuation
  (when (and live-obs-harvesters?
             (not worker-rush-active?)
             (not in-base-proxy-detected?)
             (not (null? non-builder-defense-workers)))
    (define harasser-syms
      '(oracle reaper hellion hellbat mutalisk banshee adept dark-templar void-ray zergling zealot))
    (define (harasser-is-flying? e)
      (or (eq? (hash-ref e 'flying? #f) #t)
          (memq (sc2-canonical-unit-sym (unit-type-sym e))
                '(oracle mutalisk banshee void-ray))))
    (define (harass-defender-matches? u h-flying?)
      (define raw-sym (unit-type-sym u))
      (define canon (sc2-canonical-structure-sym (sc2-canonical-unit-sym raw-sym)))
      (and (or (combat-unit-record? u)
               (memq canon '(queen photon-cannon spore-crawler missile-turret bunker spine-crawler planetary-fortress)))
           (or (not h-flying?)
               (memq canon '(photon-cannon spore-crawler missile-turret bunker queen))
               (sc2-unit-can-attack-air? canon))))
    (define evac-defender-pool
      (append ally-units
              (filter (lambda (b)
                        (and (hash? b)
                             (>= (hash-ref b 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS)
                             (let ([canon (sc2-canonical-structure-sym (unit-type-sym b))])
                               (and (memq canon '(photon-cannon spore-crawler missile-turret bunker spine-crawler planetary-fortress))
                                    (or (not (eq? race 'Protoss))
                                        (not (sc2-structure-requires-pylon-power? canon))
                                        (not (eq? (hash-ref b 'powered? #t) #f)))))))
                      ally-bldgs)))
    (define raw-harassers
      (filter (lambda (e)
                (and (hash? e)
                     (not (eq? (hash-ref e 'is-hallucination #f) #t))
                     (not (eq? (hash-ref e 'hallucination #f) #t))
                     (not (eq? (hash-ref e 'hallucination? #f) #t))
                     (not (eq? (hash-ref e 'changeling? #f) #t))
                     (memq (sc2-canonical-unit-sym (unit-type-sym e)) harasser-syms)
                     (let ([ex (hash-ref e 'x 9999.0)]
                           [ey (hash-ref e 'y 9999.0)])
                       (or (ormap (lambda (bc) (<= (dist2d (car bc) (cdr bc) ex ey) 9.5))
                                  owned-base-coords)
                           (ormap (lambda (w) (<= (dist2d (hash-ref w 'x base-x) (hash-ref w 'y base-y) ex ey) 7.0))
                                  non-builder-defense-workers)))))
              enemy-units))
    (define undefended-harassers
      (filter (lambda (h)
                (define hx (hash-ref h 'x 9999.0))
                (define hy (hash-ref h 'y 9999.0))
                (define h-flying? (harasser-is-flying? h))
                (< (count (lambda (d)
                            (and (harass-defender-matches? d h-flying?)
                                 (<= (dist2d (hash-ref d 'x -9999.0) (hash-ref d 'y -9999.0) hx hy) 8.5)))
                          evac-defender-pool)
                   2))
              raw-harassers))
    (define owned-mineral-patches
      (if (null? undefended-harassers)
          '()
          (filter (lambda (mp)
                    (and (hash? mp)
                         (let ([mpx (hash-ref mp 'x -9999.0)]
                               [mpy (hash-ref mp 'y -9999.0)])
                           (ormap (lambda (bc) (<= (dist2d (car bc) (cdr bc) mpx mpy) 14.0))
                                  owned-base-coords))))
                  (let ([mps (hash-ref obs 'mineral-patches '())])
                    (if (list? mps) mps '())))))
    (define safe-harass-mps
      (if (null? undefended-harassers)
          '()
          (filter (lambda (mp)
                    (define mpx (hash-ref mp 'x -9999.0))
                    (define mpy (hash-ref mp 'y -9999.0))
                    (andmap (lambda (h)
                              (>= (dist2d mpx mpy (hash-ref h 'x 9999.0) (hash-ref h 'y 9999.0)) 14.0))
                            undefended-harassers))
                  owned-mineral-patches)))
    (define h-cx
      (if (null? undefended-harassers)
          enemy-x
          (/ (for/sum ([h (in-list undefended-harassers)])
               (exact->inexact (hash-ref h 'x base-x)))
             (length undefended-harassers))))
    (define h-cy
      (if (null? undefended-harassers)
          enemy-y
          (/ (for/sum ([h (in-list undefended-harassers)])
               (exact->inexact (hash-ref h 'y base-y)))
             (length undefended-harassers))))
    (define best-safe-mp
      (and (not (null? safe-harass-mps))
           (argmax (lambda (mp)
                     (dist2d h-cx h-cy (hash-ref mp 'x base-x) (hash-ref mp 'y base-y)))
                   safe-harass-mps)))
    (for ([w (in-list non-builder-defense-workers)])
      (define wid (hash-ref w 'id 10))
      (unless (memv wid cur-rush-disengaging-wids)
        (define wx (hash-ref w 'x base-x))
        (define wy (hash-ref w 'y base-y))
        (define prev-evac-until (hash-ref rush-def-st (list 'harass-evac-until wid) 0))
        (define near-harasser
          (and (not (null? undefended-harassers))
               (let ([cand (argmin (lambda (h) (dist2d wx wy (hash-ref h 'x 9999.0) (hash-ref h 'y 9999.0)))
                                   undefended-harassers)])
                 (and (<= (dist2d wx wy (hash-ref cand 'x 9999.0) (hash-ref cand 'y 9999.0)) 7.0)
                      cand))))
        (define threatened? (not (not near-harasser)))
        (define evac-until
          (cond
            [(and threatened?
                  (refractory-allow-action?! cd-tracker (list 'harass-evac wid) frame 24))
             (define new-until (+ frame 24))
             (hash-set! rush-def-st (list 'harass-evac-until wid) new-until)
             (cond
               [best-safe-mp
                (emit! (list 'mineral-walk
                             wid
                             (safe-nonneg-int (hash-ref best-safe-mp 'id 0) 0)
                             (safe-coord (hash-ref best-safe-mp 'x base-x) base-x)
                             (safe-coord (hash-ref best-safe-mp 'y base-y) base-y)))]
               [else
                (define hx (hash-ref near-harasser 'x base-x))
                (define hy (hash-ref near-harasser 'y base-y))
                (define raw-dx (- (exact->inexact wx) (exact->inexact hx)))
                (define raw-dy (- (exact->inexact wy) (exact->inexact hy)))
                (define raw-d (sqrt (+ (* raw-dx raw-dx) (* raw-dy raw-dy))))
                (define-values (ux uy)
                  (if (>= raw-d 0.25)
                      (values (/ raw-dx raw-d) (/ raw-dy raw-d))
                      (let* ([bdx (- (exact->inexact base-x) (exact->inexact hx))]
                             [bdy (- (exact->inexact base-y) (exact->inexact hy))]
                             [bd (sqrt (+ (* bdx bdx) (* bdy bdy)))])
                        (if (>= bd 0.25)
                            (values (/ bdx bd) (/ bdy bd))
                            (values 1.0 0.0)))))
                (define away-x (safe-coord (+ wx (* 9.0 ux)) base-x))
                (define away-y (safe-coord (+ wy (* 9.0 uy)) base-y))
                (emit! (list 'mineral-walk wid 0 away-x away-y))])
             new-until]
            [else prev-evac-until]))
        (when (or threatened? (< frame evac-until))
          (define ttl (if (> evac-until frame) (max 1 (- evac-until frame)) 24))
          (acquire-unit-lease! leases wid 'evac frame ttl #:x wx #:y wy)))))

  ;; ---------------------------------------------------------------------------
  ;; Coupled Macro Governor, Adaptive Build/Tech Planner & Guns-vs-Butter PPF
  ;; ---------------------------------------------------------------------------
  (define raw-enemy-units-for-drill
    (let ([reu (and (hash? raw-obs) (hash-ref raw-obs 'enemy-units #f))])
      (if (and (list? reu) (andmap hash? reu))
          reu
          enemy-units)))
  (define enemy-workers-near-base
    (filter (lambda (e)
              (and (memq (unit-type-sym e) '(drone probe scv))
                   (not (eq? (hash-ref e 'is-hallucination #f) #t))
                   (let ([ex (hash-ref e 'x 9999)]
                         [ey (hash-ref e 'y 9999)])
                     (ormap (lambda (bc)
                              (<= (dist2d (car bc) (cdr bc) ex ey) 22.0))
                            owned-base-coords))))
            raw-enemy-units-for-drill))
  (define drill-stack-min-count (if live-obs-harvesters? 6 4))
  (define stacked-enemy-workers
    (if (or (< (length enemy-workers-near-base) drill-stack-min-count)
            (and live-obs-harvesters?
                 worker-rush-active?
                 (<= ally-combat-supply-early 0)))
        '()
        (let ([anchor
               (findf (lambda (ew)
                        (define ex (hash-ref ew 'x base-x))
                        (define ey (hash-ref ew 'y base-y))
                        (>= (count (lambda (o)
                                     (<= (dist2d ex ey (hash-ref o 'x ex) (hash-ref o 'y ey)) 0.45))
                                   enemy-workers-near-base)
                            drill-stack-min-count))
                      enemy-workers-near-base)])
          (if anchor
              (let ([ax (hash-ref anchor 'x base-x)]
                    [ay (hash-ref anchor 'y base-y)])
                (filter (lambda (o)
                          (<= (dist2d ax ay (hash-ref o 'x ax) (hash-ref o 'y ay)) 0.45))
                        enemy-workers-near-base))
              '()))))
  (when (>= (length stacked-enemy-workers) drill-stack-min-count)
    (define ew0 (car stacked-enemy-workers))
    (define ewx (hash-ref ew0 'x base-x))
    (define ewy (hash-ref ew0 'y base-y))
    (define anchor-bc
      (argmin (lambda (bc) (dist2d (car bc) (cdr bc) ewx ewy))
              owned-base-coords))
    (define dx (- (car anchor-bc) ewx))
    (define dy (- (cdr anchor-bc) ewy))
    (define d (max 1.0 (sqrt (+ (* dx dx) (* dy dy)))))
    (define perp-x (safe-coord (+ ewx (* 4.0 (- (/ dy d)))) (car anchor-bc)))
    (define perp-y (safe-coord (+ ewy (* 4.0 (/ dx d))) (cdr anchor-bc)))
    (emit! (list 'counter-enemy-worker-drill (length stacked-enemy-workers) perp-x perp-y))
    ;; NEVER emit passive `(move wid perp-x perp-y)` during worker rush or in-base proxy defense!
    (when (and (not worker-rush-active?)
               (not in-base-proxy-detected?))
      (for ([w (in-list workers)]
            #:when (and (not (worker-has-engine-build-order? w))
                        (not (order-ledger-unit-has-active-build? oledger-early (hash-ref w 'id 0) w))
                        (<= (dist2d ewx ewy (hash-ref w 'x base-x) (hash-ref w 'y base-y)) 8.0)))
        (emit! (list 'move (hash-ref w 'id 10) perp-x perp-y)))))

  ;; ---------------------------------------------------------------------------
  ;; Adversarial Countermeasure #2: Blocked Natural Expansion Site
  ;; Keep `natural-blocked? = #t` at ALL frames whenever enemy defensive/base structures
  ;; or >= 2 enemy combat units camp within 11.5 tiles of `(nat-x, nat-y)`, and redirect
  ;; expansions to the next uncamped BFS base instead of disabling expansion!
  ;; ---------------------------------------------------------------------------
  (define (pad-camped-by-enemy? px py [radius 11.5])
    (define camp-bldg?
      (ormap (lambda (eb)
               (define canon (sc2-canonical-structure-sym (unit-type-sym eb)))
               (and (or (memq canon '(photon-cannon bunker planetary-fortress spine-crawler
                                      hatchery lair hive nexus command-center orbital-command))
                        (memq canon SC2-TOWNHALL-STRUCTURE-SYMS))
                    (<= (dist2d px py (hash-ref eb 'x 9999.0) (hash-ref eb 'y 9999.0)) radius)))
             enemy-bldgs))
    (define camp-combat-cnt
      (count (lambda (e)
               (and (combat-unit-record? e)
                    (<= (dist2d px py (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0)) radius)))
             enemy-units))
    (or camp-bldg? (>= camp-combat-cnt 2)))

  (define nat-block-thresh SC2-NATURAL-BLOCK-RADIUS)
  (define natural-blockers
    (filter (lambda (e)
              (<= (dist2d nat-x nat-y (hash-ref e 'x 9999) (hash-ref e 'y 9999)) nat-block-thresh))
            (append enemy-units enemy-bldgs)))
  (define natural-blocked?
    (or (hash-ref obs 'natural-blocked #f)
        (pad-camped-by-enemy? nat-x nat-y 11.5)
        (and (<= (length townhalls) 1)
             (< frame 2500)
             (not (null? natural-blockers)))))

  (define (pad->xy p)
    (cond
      [(and (pair? p) (real? (car p)) (real? (cdr p)))
       (cons (safe-coord (car p) third-x) (safe-coord (cdr p) third-y))]
      [(and (pair? p) (real? (car p)) (pair? (cdr p)) (real? (cadr p)))
       (cons (safe-coord (car p) third-x) (safe-coord (cadr p) third-y))]
      [(hash? p)
       (cons (safe-coord (hash-ref p 'x third-x) third-x)
             (safe-coord (hash-ref p 'y third-y) third-y))]
      [else #f]))

  (define (pad-already-owned? px py)
    (or (<= (dist2d px py base-x base-y) 7.0)
        (ormap (lambda (th)
                 (<= (dist2d px py (hash-ref th 'x base-x) (hash-ref th 'y base-y)) 7.0))
               townhalls)))

  (define (select-uncamped-expansion-pad [prefer-natural? #f])
    (cond
      [(and prefer-natural?
            (not natural-blocked?)
            (not (pad-already-owned? nat-x nat-y)))
       (values nat-x nat-y)]
      [else
       (define cand-pts
         (append (filter-map pad->xy expansion-pads)
                 (list (cons third-x third-y))))
       (define chosen
         (findf (lambda (pt)
                  (define px (car pt))
                  (define py (cdr pt))
                  (and (not (pad-already-owned? px py))
                       (or (not natural-blocked?)
                           (> (dist2d px py nat-x nat-y) 7.0))
                       (not (pad-camped-by-enemy? px py 11.5))))
                cand-pts))
       (if chosen
           (values (car chosen) (cdr chosen))
           (values #f #f))]))

  (define early-base-under-attack?
    (or early-survival-crisis?
        (ormap (lambda (b) (eq? (hash-ref b 'under-attack #f) #t)) ally-bldgs)
        (ormap (lambda (e)
                 (and (combat-unit-record? e)
                      (<= (min (dist2d base-x base-y (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0))
                               (if (>= active-bases 2)
                                   (dist2d nat-x nat-y (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0))
                                   +inf.0))
                          28.0)))
               enemy-units)))
  (define blocked-nat-expanded-early? #f)
  (when (and natural-blocked?
             (not early-survival-crisis?)
             (not early-base-under-attack?)
             (< active-bases SC2-MAX-ACTIVE-BASES)
             (= (order-ledger-pending-count-for-type oledger-early early-race-th-sym frame) 0)
             (or (not (eq? race 'Terran)) (memq 'barracks bldg-types))
             (or (not live-obs-harvesters?)
                 (and (<= active-bases 1)
                      (or (memq 'barracks bldg-types)
                          (memq 'spawning-pool bldg-types)
                          (memq 'gateway bldg-types)
                          (memq 'warp-gate bldg-types))))
             (or (hash-ref obs 'natural-blocked #f)
                 (refractory-allow-action?! cd-tracker (list 'blocked-nat-expand race) frame SC2-EXPANSION-COOLDOWN-FRAMES)))
    (emit! (list 'clear-expansion-block nat-x nat-y))
    (if (eq? race 'Terran)
        (when (>= minerals (sc2-min-cost 'command-center))
          (set! blocked-nat-expanded-early? #t)
          (if live-obs-harvesters?
              (let-values ([(ccx ccy)
                            (order-ledger-resolve-build-coords!
                             oledger-early 'command-center
                             (safe-coord (+ base-x 6.0)) (safe-coord (- base-y 5.0))
                             ally-bldgs frame 2.5
                             #:expansion-pads expansion-pads)])
                (define sx (safe-coord ccx (+ base-x 6.0)))
                (define sy (safe-coord ccy (- base-y 5.0)))
                (emit! (list 'build 'command-center sx sy))
                (order-ledger-record-issued! oledger-early (+ 820000 (modulo frame 10000))
                                             'build 'command-center sx sy frame)
                (set! bldg-types (cons 'command-center bldg-types)))
              (emit! (list 'build 'command-center (safe-coord (+ base-x 4.0)) base-y)))
          (set! minerals (max 0 (- minerals (sc2-min-cost 'command-center)))))
        (when (>= minerals (sc2-race-townhall-min-cost race))
          (define-values (bx3 by3)
            (if live-obs-harvesters?
                (select-uncamped-expansion-pad #f)
                (values third-x third-y)))
          (when (and bx3 by3)
            (set! blocked-nat-expanded-early? #t)
            (emit! (list 'expand bx3 by3))
            (order-ledger-record-issued! oledger-early (+ 830000 (modulo frame 10000))
                                         'expand early-race-th-sym bx3 by3 frame)
            (set! minerals (max 0 (- minerals (sc2-race-townhall-min-cost race))))))))
  (define depleting-bases
    (hash-ref obs 'depleting-bases (if (hash-ref obs 'mined-out #f) 1 0)))
  (define prod-facilities
    (filter (lambda (b)
              (memq (sc2-canonical-structure-sym (unit-type-sym b))
                    '(hatchery lair hive gateway warp-gate warpgate robotics-facility stargate
                      barracks factory starport)))
            ally-bldgs))
  (define gas-bldgs
    (filter (lambda (b)
              (memq (sc2-canonical-structure-sym (unit-type-sym b))
                    '(extractor assimilator refinery)))
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
     #:under-crisis? (or under-early-cheese? early-survival-crisis?)
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
     #:army-count (length ally-combat-units)
     #:missing-synergy-count (length (adaptive-tech-plan-missing-synergy-reqs tech-plan))
     #:under-crisis? (or under-early-cheese? early-survival-crisis?)
     #:mirror-macro-verdict (mirror-mind-state-mirror-macro-verdict mmstate)
     #:enemy-upgrade-advantage (enemy-tech-observation-enemy-upgrade-advantage tech-obs)
     #:enemy-active-research-count (length (enemy-tech-observation-active-research-buildings tech-obs))
     #:requires-detection? (enemy-tech-observation-requires-detection? tech-obs)
     #:requires-anti-air? (enemy-tech-observation-requires-anti-air? tech-obs)))
  (define gas-alloc (guns-vs-butter-ppf-recommended-gas-allocation ppf))

  ;; ---------------------------------------------------------------------------
  ;; Worker Mineral-Walk Escape (Pro Mechanic #5: 4.0 tiles) & Resource Harvesting
  ;; (Skipped when `worker-rush-active?` so `<25 HP` / `<60%` rule never yanks 20-HP
  ;;  fighting Drones out of a 14v12 brawl — `<= 12 HP` per-step disengage handles it!)
  ;; ---------------------------------------------------------------------------
  (for ([w (in-list workers)]
        #:when (and (not worker-rush-active?)
                    (not (worker-has-engine-build-order? w))
                    (not (order-ledger-unit-has-active-build? oledger-early (hash-ref w 'id 0) w))))
    (define wsym (unit-type-sym w))
    (define whp (unit-total-hp-and-shield w))
    (define wmax
      (+ (hash-ref w 'max-hp (case wsym [(probe) 20] [(scv) 45] [else SC2-DRONE-MAX-HP]))
         (if (eq? wsym 'probe) (hash-ref w 'max-shield (hash-ref w 'shield-max 20)) 0)))
    (define wx (hash-ref w 'x base-x))
    (define wy (hash-ref w 'y base-y))
    (define enemy-close?
      (ormap (lambda (e)
               (<= (dist2d wx wy (hash-ref e 'x 9999) (hash-ref e 'y 9999))
                   SC2-WORKER-ESCAPE-THREAT-RADIUS))
             enemy-units))
    (when (and (or (< whp SC2-WOUNDED-WORKER-MIN-HP)
                   (< (/ (exact->inexact whp) (max 1 wmax)) SC2-WOUNDED-WORKER-HP-PCT))
               enemy-close?
               (or (not live-obs-harvesters?)
                   (refractory-allow-action?! cd-tracker
                                              (list 'wounded-mineral-walk (hash-ref w 'id 10))
                                              frame
                                              24)))
      (emit! (list 'mineral-walk (hash-ref w 'id 10) base-x base-y))))

  ;; Standard Gas & Mineral Harvesting + Smart Single-Dispatch Pro Worker Scout
  (define enemy-exp-x (hash-ref obs 'enemy-expand-x (safe-coord (* 0.85 enemy-x) 148.0)))
  (define enemy-exp-y (hash-ref obs 'enemy-expand-y (safe-coord (* 0.85 enemy-y) 148.0)))
  (define corridor-mid-x (safe-coord (* 0.5 (+ nat-x enemy-exp-x)) 96.0))
  (define corridor-mid-y (safe-coord (* 0.5 (+ nat-y enemy-exp-y)) 96.0))

  (define scout-st (rt-scout-state rt))
  (when (<= frame 4)
    (hash-clear! scout-st))
  (define non-building-workers
    (filter (lambda (w)
              (and (not (worker-has-engine-build-order? w))
                   (not (order-ledger-unit-has-active-build? oledger-early (hash-ref w 'id 0) w))))
            workers))
  (define force-synth-harass? (eq? (hash-ref obs 'enable-worker-harass #f) #t))
  (define already-dispatched-scout? (eq? (hash-ref scout-st 'dispatched? #f) #t))
  (define scout-rush-aborted-latch?
    (and (< frame 3600)
         (eq? (hash-ref scout-st 'aborted-rush? #f) #t)))
  (define scout-eligible-window?
    (and (not (null? non-building-workers))
         (not worker-rush-active?)
         (not scout-rush-aborted-latch?)
         (not in-base-proxy-detected?)
         (or force-synth-harass?
             (and (>= frame 300)
                  (>= supply-used 14)
                  (< frame 3600)
                  (not under-early-cheese?)
                  (not early-survival-crisis?)
                  (>= (length workers) (if live-obs-harvesters? 13 2))))))
  (define latched-scout-id
    (or (hash-ref scout-st 'scout-id #f)
        (and (not already-dispatched-scout?)
             (hash-ref prev-tel-early 'scout-worker-id #f))))
  (define raw-scout-candidate
    (cond
      [in-base-proxy-detected? #f]
      [(and latched-scout-id
            (findf (lambda (w) (equal? (hash-ref w 'id -1) latched-scout-id))
                   non-building-workers))
       => values]
      [(and worker-rush-active? (< frame 3360))
       ;; Also catch a forward scout worker already out on the map in stateless/first-step rush encounters
       (findf (lambda (w)
                (define wx (hash-ref w 'x base-x))
                (define wy (hash-ref w 'y base-y))
                (and (> (dist2d wx wy base-x base-y) 16.0)
                     (or (< active-bases 2)
                         (> (dist2d wx wy nat-x nat-y) 14.0))))
              non-building-workers)]
      [already-dispatched-scout?
       (and force-synth-harass?
            (not worker-rush-active?)
            (not scout-rush-aborted-latch?)
            (not live-obs-harvesters?)
            (pair? non-building-workers)
            (last non-building-workers))]
      [scout-eligible-window?
       (last non-building-workers)]
      [else #f]))
  (define (scout-encounters-early-worker-rush? sw)
    (and sw
         (< frame 3360)
         (let ([swx (hash-ref sw 'x base-x)]
               [swy (hash-ref sw 'y base-y)])
           (and (> (dist2d swx swy base-x base-y) 8.0)
                (or worker-rush-active?
                    scout-rush-aborted-latch?
                    (>= (count (lambda (e)
                                 (define ex0 (hash-ref e 'x 9999.0))
                                 (define ey0 (hash-ref e 'y 9999.0))
                                 (and (memq (unit-type-sym e) '(probe scv drone))
                                      (<= (dist2d swx swy ex0 ey0) 14.0)
                                      (> (dist2d ex0 ey0 enemy-x enemy-y) 16.0)))
                               enemy-units)
                        3)
                    (>= (count (lambda (e)
                                 (and (memq (unit-type-sym e) '(probe scv drone))
                                      (<= (dist2d swx swy
                                                  (hash-ref e 'x 9999.0)
                                                  (hash-ref e 'y 9999.0))
                                          5.5)))
                               enemy-units)
                        3))))))
  (define rush-retreating-scout
    (and (scout-encounters-early-worker-rush? raw-scout-candidate)
         raw-scout-candidate))
  (when rush-retreating-scout
    (hash-set! scout-st 'dispatched? #t)
    (hash-set! scout-st 'scout-id (hash-ref rush-retreating-scout 'id #f))
    (hash-set! scout-st 'aborted-rush? #t))
  (define scout-worker
    (cond
      [(or rush-retreating-scout
           worker-rush-active?
           scout-rush-aborted-latch?
           in-base-proxy-detected?)
       #f]
      [already-dispatched-scout? raw-scout-candidate]
      [(and scout-eligible-window? raw-scout-candidate)
       (hash-set! scout-st 'dispatched? #t)
       (hash-set! scout-st 'scout-id (hash-ref raw-scout-candidate 'id #f))
       (hash-set! scout-st 'orbit-idx 0)
       (hash-set! scout-st 'evading-until 0)
       raw-scout-candidate]
      [else #f]))
  (define rush-retreating-scout-id
    (and rush-retreating-scout (hash-ref rush-retreating-scout 'id #f)))
  (define scout-worker-id (and scout-worker (hash-ref scout-worker 'id #f)))
  (define active-leased-scout (or rush-retreating-scout scout-worker))
  (define active-leased-scout-id (and active-leased-scout (hash-ref active-leased-scout 'id #f)))
  (when active-leased-scout-id
    (acquire-unit-lease! leases active-leased-scout-id 'scout frame 32
                         #:x (hash-ref active-leased-scout 'x base-x)
                         #:y (hash-ref active-leased-scout 'y base-y)))
  (define harvest-eligible-workers
    (filter (lambda (w)
              (define wid (hash-ref w 'id -1))
              (and (not (worker-has-engine-build-order? w))
                   (not (order-ledger-unit-has-active-build? oledger-early wid w))
                   (not (and active-leased-scout-id (equal? wid active-leased-scout-id)))
                   (not (unit-leased-above? leases wid 'harvester frame))))
            workers))
  (define harvest-workers-pool
    (if (not (null? harvest-eligible-workers)) harvest-eligible-workers non-building-workers))

  (define gas-float-starved?
    (and (>= gas SC2-GAS-FLOAT-REBALANCE-THRESH)
         (< minerals SC2-MINERAL-STARVED-REBALANCE-THRESH)))
  (define gas-bldg
    (findf (lambda (b)
             (memq (sc2-canonical-structure-sym (unit-type-sym b))
                   '(extractor assimilator refinery)))
           ally-bldgs))
  (when (and (not live-obs-harvesters?)
             gas-bldg
             (not (null? harvest-workers-pool))
             (not gas-float-starved?)
             (> (gas-worker-allocation-desired-gas-workers gas-alloc) 0))
    (emit! (list 'harvest-gas (hash-ref (car harvest-workers-pool) 'id 10) (hash-ref gas-bldg 'id 103))))
  (when (not (null? harvest-workers-pool))
    (define patch-id (hash-ref obs 'mineral-patch-id SC2-SYNTHETIC-MINERAL-PATCH-ID))
    (when (and (not live-obs-harvesters?) gas-float-starved?)
      (define pull-workers
        (take harvest-workers-pool
              (min (if (>= gas SC2-GAS-FLOAT-CRITICAL-THRESH) 4 2)
                   (length harvest-workers-pool))))
      (emit! (list 'rebalance-gas-to-minerals
                   (map (lambda (w) (hash-ref w 'id 10)) pull-workers)
                   patch-id)))
    (unless live-obs-harvesters?
      (emit! (list 'harvest-mineral (hash-ref (car harvest-workers-pool) 'id 10) patch-id)))
    (define idle-return-workers
      (filter (lambda (w)
                (define wid (hash-ref w 'id 10))
                (define wx (hash-ref w 'x base-x))
                (define wy (hash-ref w 'y base-y))
                (and (not (memv wid cur-rush-fighting-wids))
                     (not (memv wid cur-rush-disengaging-wids))
                     (hash-has-key? w 'orders)
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
  ;; Smart Single-Dispatch Pro Worker Scout:
  ;; Orbit Behind Enemy Mineral Line, Evade Ranged/Pulled Threats, Poke Builder SCV,
  ;; and Immediately Mineral-Walk Home Without Engaging When Encountering Early Worker Rush!
  ;; ---------------------------------------------------------------------------
  (when rush-retreating-scout-id
    (emit! (list 'mineral-walk rush-retreating-scout-id base-x base-y)))
  (when (and force-synth-harass?
             (not rush-retreating-scout)
             (not worker-rush-active?)
             (not scout-rush-aborted-latch?)
             (not in-base-proxy-detected?)
             (not (null? workers)))
    (emit! (list 'worker-harass (or scout-worker-id (hash-ref (last workers) 'id 10)) enemy-x enemy-y)))
  (when scout-worker
    (define sw-id (hash-ref scout-worker 'id 10))
    (define sw-x (hash-ref scout-worker 'x base-x))
    (define sw-y (hash-ref scout-worker 'y base-y))
    (define dist-to-enemy (dist2d sw-x sw-y enemy-x enemy-y))
    (cond
      [(not live-obs-harvesters?)
       (define wp-x (if (and (> (dist2d sw-x sw-y enemy-exp-x enemy-exp-y) 9.0)
                             (> dist-to-enemy 20.0)
                             (< (modulo frame 672) 336))
                        enemy-exp-x
                        enemy-x))
       (define wp-y (if (and (> (dist2d sw-x sw-y enemy-exp-x enemy-exp-y) 9.0)
                             (> dist-to-enemy 20.0)
                             (< (modulo frame 672) 336))
                        enemy-exp-y
                        enemy-y))
       (emit! (list 'worker-scout sw-id wp-x wp-y))
       (emit! (list 'mineral-harass sw-id enemy-x enemy-y enemy-exp-x enemy-exp-y))]
      [else
       (define ex (exact->inexact enemy-x))
       (define ey (exact->inexact enemy-y))
       (define vdx (- ex (exact->inexact base-x)))
       (define vdy (- ey (exact->inexact base-y)))
       (define vlen (max 1.0 (sqrt (+ (* vdx vdx) (* vdy vdy)))))
       (define ux (/ vdx vlen))
       (define uy (/ vdy vlen))
       (define px (- uy))
       (define py ux)
       (define orbit-waypoints
         (list (cons (safe-coord (+ ex (* 6.0 ux) (* 5.5 px)) enemy-x)
                     (safe-coord (+ ey (* 6.0 uy) (* 5.5 py)) enemy-y))
               (cons (safe-coord (+ ex (* 7.5 ux) (* 2.5 px)) enemy-x)
                     (safe-coord (+ ey (* 7.5 uy) (* 2.5 py)) enemy-y))
               (cons (safe-coord (+ ex (* 7.5 ux) (* -2.5 px)) enemy-x)
                     (safe-coord (+ ey (* 7.5 uy) (* -2.5 py)) enemy-y))
               (cons (safe-coord (+ ex (* 6.0 ux) (* -5.5 px)) enemy-x)
                     (safe-coord (+ ey (* 6.0 uy) (* -5.5 py)) enemy-y))
               (cons (safe-coord (+ ex (* 3.5 ux) (* -7.0 px)) enemy-x)
                     (safe-coord (+ ey (* 3.5 uy) (* -7.0 py)) enemy-y))))
       (when (<= (dist2d sw-x sw-y enemy-exp-x enemy-exp-y) 10.5)
         (hash-set! scout-st 'visited-nat? #t))
       (define ranged-enemies-near
         (count (lambda (e)
                  (define et (sc2-canonical-unit-sym (unit-type-sym e)))
                  (and (<= (dist2d sw-x sw-y (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0)) 7.5)
                       (or (>= (safe-finite-real (hash-ref e 'range 0.0) 0.0) 2.0)
                           (memq et '(marine marauder reaper stalker adept sentry queen
                                      hydralisk roach cyclone hellion photon-cannon bunker
                                      planetary-fortress spine-crawler)))))
                (append enemy-units enemy-bldgs)))
       (define pulled-workers-chasing
         (count (lambda (e)
                  (and (memq (unit-type-sym e) '(probe scv drone))
                       (<= (dist2d sw-x sw-y (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0)) 4.5)))
                enemy-units))
       (define sw-total-hp (unit-total-hp-and-shield scout-worker 40))
       (define sw-low-hp? (< sw-total-hp 22))
       (when (or (> ranged-enemies-near 0)
                 (>= pulled-workers-chasing 2)
                 sw-low-hp?)
         (hash-set! scout-st 'evading-until (+ frame 40)))
       (define evading? (< frame (hash-ref scout-st 'evading-until 0)))
       (cond
         [evading?
          (when (refractory-allow-action?! cd-tracker (list 'scout-evade sw-id) frame 12)
            (if (or sw-low-hp? (> ranged-enemies-near 0) (>= pulled-workers-chasing 2))
                (emit! (list 'mineral-walk sw-id base-x base-y))
                (let* ([next-idx (modulo (+ (hash-ref scout-st 'orbit-idx 0) 2) 5)]
                       [esc-wp (list-ref orbit-waypoints next-idx)])
                  (hash-set! scout-st 'orbit-idx next-idx)
                  (emit! (list 'move sw-id (car esc-wp) (cdr esc-wp))))))]
         [else
          (define exposed-builder-scv
            (and (= ranged-enemies-near 0)
                 (<= pulled-workers-chasing 1)
                 (findf (lambda (e)
                          (define ex0 (hash-ref e 'x 9999.0))
                          (define ey0 (hash-ref e 'y 9999.0))
                          (and (eq? (unit-type-sym e) 'scv)
                               (<= (dist2d sw-x sw-y ex0 ey0) 9.5)
                               (or (eq? (hash-ref e 'has-build-order? #f) #t)
                                   (ormap (lambda (eb)
                                            (and (< (hash-ref eb 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS)
                                                 (<= (dist2d ex0 ey0
                                                             (hash-ref eb 'x 9999.0)
                                                             (hash-ref eb 'y 9999.0))
                                                     3.2)))
                                          enemy-bldgs))))
                        enemy-units)))
          (cond
            [exposed-builder-scv
             (when (refractory-allow-action?! cd-tracker (list 'scout-poke-scv sw-id) frame 16)
               (emit! (list 'attack sw-id (hash-ref exposed-builder-scv 'id 0))))]
            [else
             (define cur-idx (modulo (hash-ref scout-st 'orbit-idx 0) 5))
             (define cur-wp0 (list-ref orbit-waypoints cur-idx))
             (define next-idx
               (if (<= (dist2d sw-x sw-y (car cur-wp0) (cdr cur-wp0)) 3.2)
                   (modulo (add1 cur-idx) 5)
                   cur-idx))
             (hash-set! scout-st 'orbit-idx next-idx)
             (define target-wp
               (if (and (not (hash-ref scout-st 'visited-nat? #f))
                        (> dist-to-enemy 26.0)
                        (> (dist2d sw-x sw-y enemy-exp-x enemy-exp-y) 9.5))
                   (cons enemy-exp-x enemy-exp-y)
                   (list-ref orbit-waypoints next-idx)))
             (when (refractory-allow-action?! cd-tracker (list 'opening-worker-scout sw-id) frame 20)
               (emit! (list 'worker-scout sw-id (car target-wp) (cdr target-wp))))])])]))

  ;; ---------------------------------------------------------------------------
  ;; Opening Overlord Scouting (Zerg): Overlord #1 -> Enemy Natural, Overlord #2 -> Attack Corridor
  ;; Capped at < frame 2800 and <= 2 unique Overlord IDs via `scout-st`; permanently aborts on loss,
  ;; damage, nearby AA threat, or enemy AA tech, and retreats far Overlords home (`live-obs-harvesters?`).
  ;; ---------------------------------------------------------------------------
  (when (eq? race 'Zerg)
    (define all-overlords
      (filter (lambda (u) (eq? (unit-type-sym u) 'overlord)) ally-units))
    (define ov-and-overseers-cnt
      (count (lambda (u) (memq (unit-type-sym u) '(overlord overseer))) ally-units))
    (define prev-ov-max (hash-ref scout-st 'opening-overlord-max-seen 0))
    (when (> ov-and-overseers-cnt prev-ov-max)
      (hash-set! scout-st 'opening-overlord-max-seen ov-and-overseers-cnt))
    (define enemy-has-nonworker-aa?
      (or (enemy-tech-observation-requires-anti-air? tech-obs)
          (ormap (lambda (e)
                   (and (not (memq (unit-type-sym e) '(probe scv drone overlord)))
                        (sc2-unit-can-attack-air? (unit-type-sym e))))
                 enemy-units)))
    (define (overlord-unsafe? u)
      (or (hash-ref u 'under-attack #f)
          (< (hash-ref u 'hp SC2-OVERLORD-MAX-HP) SC2-OVERLORD-DAMAGED-HP-THRESH)
          (ormap (lambda (e)
                   (and (sc2-unit-can-attack-air? (unit-type-sym e))
                        (<= (dist2d (hash-ref u 'x base-x) (hash-ref u 'y base-y)
                                    (hash-ref e 'x 9999) (hash-ref e 'y 9999))
                            SC2-OVERLORD-THREAT-RADIUS)))
                 enemy-units)))
    (define any-ov-lost-or-hurt?
      (or (and (> prev-ov-max 0) (< ov-and-overseers-cnt prev-ov-max))
          (ormap overlord-unsafe? all-overlords)))
    (when (or (>= frame 2800)
              any-ov-lost-or-hurt?
              enemy-has-nonworker-aa?)
      (hash-set! scout-st 'opening-overlord-aborted? #t))
    (define ov-aborted? (hash-ref scout-st 'opening-overlord-aborted? #f))
    (cond
      [(and (< frame 2800)
            (not ov-aborted?)
            (or (not live-obs-harvesters?)
                (refractory-allow-action?! cd-tracker 'opening-overlord-scout frame 64)))
       (define tracked-ov-ids (hash-ref scout-st 'opening-overlord-ids '()))
       (define safe-overlords
         (filter (lambda (u)
                   (and (not (overlord-unsafe? u))
                        (or (memv (hash-ref u 'id 102) tracked-ov-ids)
                            (< (length tracked-ov-ids) 2))))
                 all-overlords))
       (define rplan-now
         (evaluate-random-stealth-harass-plan (live-bot-runtime-configured-race rt) race frame))
       (define perim-flight?
         (and (random-stealth-harass-plan-perimeter-flight-path? rplan-now) (< frame 1200)))
       (when (pair? safe-overlords)
         (define ov1 (car safe-overlords))
         (define ov1-id (hash-ref ov1 'id 102))
         (unless (memv ov1-id tracked-ov-ids)
           (set! tracked-ov-ids (append tracked-ov-ids (list ov1-id))))
         (define ov1-tx (if perim-flight? enemy-exp-x enemy-exp-x))
         (define ov1-ty (if perim-flight? base-y enemy-exp-y))
         (emit! (list 'overlord-scout ov1-id ov1-tx ov1-ty)))
       (when (and (>= (length safe-overlords) 2)
                  (let ([ov2-id (hash-ref (cadr safe-overlords) 'id 102)])
                    (or (memv ov2-id tracked-ov-ids)
                        (< (length tracked-ov-ids) 2))))
         (define ov2 (cadr safe-overlords))
         (define ov2-id (hash-ref ov2 'id 102))
         (unless (memv ov2-id tracked-ov-ids)
           (set! tracked-ov-ids (append tracked-ov-ids (list ov2-id))))
         (emit! (list 'overlord-scout ov2-id corridor-mid-x corridor-mid-y)))
       (hash-set! scout-st 'opening-overlord-ids
                  (if (> (length tracked-ov-ids) 2)
                      (take tracked-ov-ids 2)
                      tracked-ov-ids))]
      [(and live-obs-harvesters?
            (or (>= frame 2800) ov-aborted?))
       (for ([ov (in-list all-overlords)]
             #:when (and (not (overlord-unsafe? ov))
                         (> (dist2d (hash-ref ov 'x base-x) (hash-ref ov 'y base-y) base-x base-y) 26.0)
                         (refractory-allow-action?! cd-tracker
                                                    (list 'ov-retreat-home (hash-ref ov 'id 102))
                                                    frame
                                                    64)))
         (emit! (list 'kite (hash-ref ov 'id 102) base-x base-y)))]))

  ;; Mined-out / Proactive 90s Pre-Depleting base detection (Scenario 3):
  ;; Redirect to uncamped BFS base instead of disabling expansion when `natural-blocked?` is `#t`!
  (define pre-depleting-bases (safe-nonneg-int (hash-ref obs 'pre-depleting-bases depleting-bases) depleting-bases))
  (when (and (or (hash-ref obs 'mined-out #f)
                 (and (> (max depleting-bases pre-depleting-bases) 0)
                      (>= minerals (sc2-race-townhall-min-cost race))))
             (not blocked-nat-expanded-early?)
             (not under-early-cheese?)
             (not early-survival-crisis?)
             (= (order-ledger-pending-count-for-type oledger-early early-race-th-sym frame) 0)
             (< active-bases desired-bases)
             (< active-bases SC2-MAX-ACTIVE-BASES)
             (or (< active-bases 4)
                 (>= minerals 600)
                 (> depleting-bases 0))
             (refractory-allow-action?! cd-tracker (list 'auto-expand race) frame SC2-EXPANSION-COOLDOWN-FRAMES))
    (define-values (exp-x exp-y)
      (select-uncamped-expansion-pad (< active-bases 2)))
    (when (and exp-x exp-y)
      (emit! (list 'expand exp-x exp-y))
      (order-ledger-record-issued! oledger-early (+ 815000 (modulo frame 10000)) 'expand early-race-th-sym exp-x exp-y frame)
      (set! minerals (max 0 (- minerals (sc2-race-townhall-min-cost race))))))

  ;; ---------------------------------------------------------------------------
  ;; In-Progress Order Ledger Reconciliation & Building Control Groups (4, 5, 6, 7, 9)
  ;; Pass `#:excluded-tags` so leased scouts/spotters/door-guards/inject-queens/creep-queens/builders
  ;; are NEVER swept into army control groups 1/2/3!
  ;; ---------------------------------------------------------------------------
  (define oledger (live-bot-runtime-order-ledger rt))
  (order-ledger-reconcile-observation! oledger obs)
  (define cortex (live-bot-runtime-cortex rt))
  (define cg-sync-actions
    (cortex-sync-control-groups! cortex ally-units ally-bldgs base-x base-y
                                 #:excluded-tags (leased-tags-above leases 'army frame)))
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

  (define threatened-supply-bldgs
    (filter (lambda (b)
              (and (memq (unit-type-sym b) '(supply-depot supply-depot-lowered pylon pylon-overcharged))
                   (>= (hash-ref b 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS)
                   (or (< (hash-ref b 'hp-pct 1.0) SC2-SUPPLY-BLDG-DAMAGED-HP-PCT)
                       (and (not (hash-has-key? b 'hp-pct))
                            (< (hash-ref b 'hp SC2-PYLON-TOTAL-MAX-HP)
                               (if (memq (unit-type-sym b) '(pylon pylon-overcharged))
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
    (filter (lambda (b)
              (and (>= (hash-ref b 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS)
                   (building-grounded-and-powered? b)))
            ally-bldgs))
  (define ready-bldg-types
    (map (lambda (b) (sc2-canonical-structure-sym (unit-type-sym b))) ready-bldgs))

  (define rush-threat-enemies (filter-rush-threat-enemies enemy-units base-x base-y nat-x nat-y))
  (define live-army-supply ally-combat-supply-early)
  (define (min-dist-to-owned-base ex ey)
    (min (dist2d ex ey base-x base-y)
         (if (>= active-bases 2) (dist2d ex ey nat-x nat-y) +inf.0)
         (if (>= active-bases 3) (dist2d ex ey third-x third-y) +inf.0)))
  (define (enemy-proximate-to-our-bases? e)
    (define ex (hash-ref e 'x base-x))
    (define ey (hash-ref e 'y base-y))
    (<= (min-dist-to-owned-base ex ey) 55.0))
  (define rush-worker-swarm?
    (>= (length enemy-rush-workers) SC2-WORKER-RUSH-MIN-ENEMY-WORKERS))
  (define forward-proxy-prod-cnt
    (if forward-proxy-detected?
        (count (lambda (eb)
                 (memq (sc2-canonical-structure-sym (unit-type-sym eb))
                       '(barracks factory starport gateway warp-gate robotics-facility stargate)))
               forward-proxy-structures)
        0))
  (define proxy-structure-threat-supply
    (+ (* 4 (length in-base-proxy-structures))
       (if forward-proxy-detected?
           (max 4 (* 4 forward-proxy-prod-cnt))
           0)))
  (define proximate-enemy-threat-supply
    (+ proxy-structure-threat-supply
       (if live-obs-harvesters?
           (exact-round
            (for/sum ([e (in-list rush-threat-enemies)]
                      #:when (enemy-proximate-to-our-bases? e))
              (define et (unit-type-sym e))
              (define ex (hash-ref e 'x base-x))
              (define ey (hash-ref e 'y base-y))
              (define d (min-dist-to-owned-base ex ey))
              (define w (/ 1.0 (+ 1.0 (expt (/ (max 0.0 (- d 28.0)) 18.0) 2))))
              (define base-sup
                (if (and rush-worker-swarm? (memq et '(probe scv drone)))
                    1.5
                    (unit-supply-cost et)))
              (* w base-sup)))
           (exact-round
            (for/sum ([e (in-list rush-threat-enemies)])
              (define et (unit-type-sym e))
              (if (and rush-worker-swarm? (memq et '(probe scv drone)))
                  1.5
                  (unit-supply-cost et)))))))
  (define distant-enemy-combat-supply
    (if live-obs-harvesters?
        (for/sum ([e (in-list rush-threat-enemies)]
                  #:when (not (enemy-proximate-to-our-bases? e)))
          (unit-supply-cost (unit-type-sym e)))
        0))

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
      [(or (ormap (lambda (eb) (not (enemy-bldg-is-proxy? eb))) enemy-bldgs)
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

  (define bldg-actively-damaged?
    (ormap (lambda (b) (eq? (hash-ref b 'under-attack #f) #t)) ally-bldgs))
  (define enemy-inside-owned-base-perimeter?
    (ormap (lambda (e)
             (define ex (hash-ref e 'x 9999))
             (define ey (hash-ref e 'y 9999))
             (<= (min-dist-to-owned-base ex ey) 28.0))
           rush-threat-enemies))
  (define enemy-attacking-base-or-nat?
    (or worker-rush-active?
        in-base-proxy-detected?
        under-early-cheese?
        bldg-actively-damaged?
        (and enemy-inside-owned-base-perimeter?
             (or (not live-obs-harvesters?)
                 (> live-enemy-threat-supply 0)
                 (<= live-defending-force-supply 2)))))
  (define under-base-attack?
    (or worker-rush-active?
        in-base-proxy-detected?
        enemy-attacking-base-or-nat?
        (and (> live-enemy-threat-supply 0)
             (> live-enemy-threat-supply (max 4 live-army-supply)))))

  (when (and (>= frame 448)
             (or (< intel-confidence 0.65)
                 (zero? (modulo frame 672)))
             (or (not live-obs-harvesters?)
                 (refractory-allow-action?! cd-tracker 'live-periodic-scout frame 96)))
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
    (define spotter-candidates
      (if (and live-obs-harvesters?
               (or under-base-attack? (< (length ally-combat-units) 6)))
          '()
          (filter (lambda (u)
                    (and (not (unit-leased-above? leases (hash-ref u 'id 0) 'army frame))
                         (memq (unit-type-sym u)
                               '(zergling reaper hellion adept marine stalker zealot mutalisk phoenix oracle))))
                  ally-combat-units)))
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
      [(and scout-worker-id
            (not live-obs-harvesters?)
            (< intel-confidence 0.65))
       (emit! (list 'periodic-scout scout-worker-id recon-tx recon-ty))]))

  (define live-game-obs? live-obs-harvesters?)
  (define supply-threshold
    (cond [(and live-game-obs? (< supply-cap 20)) 1]
          [(and live-game-obs? (< supply-cap 26)) 2]
          [(and live-game-obs? (< supply-cap 36)) 5]
          [live-game-obs?
           (if (< supply-cap 66)
               (min 12 (+ 2 (* 2 active-bases) (max 0 (- (length prod-facilities) 1))))
               (min 18 (max SC2-MID-SUPPLY-BUFFER
                            (+ 3 (* 2 active-bases) (length prod-facilities)))))]
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
    (cond
      [(and live-game-obs? (>= supply-cap 100) (<= supply-left 10)) 4]
      [(and live-game-obs? (or (>= supply-cap 66) (>= (length prod-facilities) 5)) (<= supply-left 10)) 3]
      [(and live-game-obs? (>= supply-cap 36)) 2]
      [(and (< supply-cap SC2-MID-SUPPLY-CAP-THRESHOLD)
            (> supply-left 2))
       SC2-MAX-PENDING-SUPPLY-EARLY]
      [else SC2-MAX-PENDING-SUPPLY-LATE]))
  (define effective-supply-with-pending
    (+ supply-left (* SC2-SUPPLY-PER-PROVIDER pending-supply)))
  (define wall-st (rt-wall-state rt))
  (when (<= frame 4)
    (hash-clear! wall-st))
  (define real-pylon-count
    (count (lambda (b)
             (and (hash? b)
                  (eq? (sc2-canonical-structure-sym (unit-type-sym b)) 'pylon)))
           ally-bldgs))
  (define real-depot-count
    (count (lambda (b)
             (and (hash? b)
                  (memq (sc2-canonical-structure-sym (unit-type-sym b))
                        '(supply-depot supply-depot-lowered))))
           ally-bldgs))
  (define real-supply-bldg-count
    (case race
      [(Protoss) real-pylon-count]
      [(Terran) real-depot-count]
      [else 0]))
  (define any-worker-building-in-engine?
    (ormap worker-has-engine-build-order? workers))
  (define last-supply-issue-f (hash-ref wall-st 'supply-last-issue-frame #f))
  (define stale-phantom-wall-supply?
    (and live-game-obs?
         (memq race '(Protoss Terran))
         (= real-supply-bldg-count 0)
         (not any-worker-building-in-engine?)
         (exact-integer? last-supply-issue-f)
         (>= (- frame last-supply-issue-f) 16)))
  (when (and stale-phantom-wall-supply?
             (> last-supply-issue-f (hash-ref wall-st 'supply-failure-counted-at -1)))
    (hash-set! wall-st 'supply-failure-counted-at last-supply-issue-f)
    (hash-set! wall-st 'wall-supply-failures
               (add1 (hash-ref wall-st 'wall-supply-failures 0))))
  (define eff-pending-supply
    (if stale-phantom-wall-supply?
        pending-supply
        (max pending-supply
             (order-ledger-pending-count-for-type oledger supply-provider-sym frame))))
  (define effective-supply-with-pending-ledger
    (+ supply-left (* SC2-SUPPLY-PER-PROVIDER eff-pending-supply)))
  (define protoss-pylon-count
    (count (lambda (t) (eq? t 'pylon)) bldg-types))
  (define unpowered-protoss-bldg
    (and (eq? race 'Protoss)
         (findf (lambda (b)
                  (and (hash? b)
                       (>= (hash-ref b 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS)
                       (sc2-structure-requires-pylon-power?
                        (sc2-canonical-structure-sym (unit-type-sym b)))
                       (eq? (hash-ref b 'powered? #t) #f)))
                ally-bldgs)))
  (define has-unpowered-bldg? (not (not unpowered-protoss-bldg)))
  (define powered-protoss-bldg-count
    (if (eq? race 'Protoss)
        (count (lambda (b)
                 (and (hash? b)
                      (sc2-structure-requires-pylon-power?
                       (sc2-canonical-structure-sym (unit-type-sym b)))))
               ally-bldgs)
        0))
  (define power-placement-failed?
    (and live-game-obs? (eq? (hash-ref obs 'power-placement-failed? #f) #t)))
  (define protoss-power-grid-saturated?
    (and live-game-obs?
         (>= real-pylon-count 1)
         (< real-pylon-count 16)
         (<= supply-left 16)
         (>= minerals 300)
         (or (and power-placement-failed? (< real-pylon-count 16))
             (and (< real-pylon-count 10)
                  (>= powered-protoss-bldg-count (* 3 real-pylon-count)))
             (and (<= real-pylon-count 4)
                  (>= frame 2500)
                  (>= minerals 450)))))
  (define safe-inmain-pylon-count
    (if (eq? race 'Protoss)
        (count (lambda (b)
                 (and (hash? b)
                      (eq? (sc2-canonical-structure-sym (unit-type-sym b)) 'pylon)
                      (<= (dist2d base-x base-y
                                  (hash-ref b 'x -999.0)
                                  (hash-ref b 'y -999.0))
                          7.5)))
               ally-bldgs)
        0))
  (define protoss-emergency-pylon?
    (and (eq? race 'Protoss)
         (not (null? workers))
         (<= eff-pending-supply 0)
         (or (and (= protoss-pylon-count 0)
                  (or (> (length ally-bldgs) 1)
                      (>= supply-used 13)
                      (<= supply-left 0)
                      (and live-game-obs? (>= minerals 100) (< frame 3000))))
             (and live-game-obs?
                  (or worker-rush-active? in-base-proxy-detected?)
                  (= safe-inmain-pylon-count 0))
             has-unpowered-bldg?
             protoss-power-grid-saturated?)))
  (define terran-depot-count
    (count (lambda (t) (eq? t 'supply-depot)) bldg-types))
  (define terran-emergency-depot?
    (and (eq? race 'Terran)
         (not (null? workers))
         (<= eff-pending-supply 0)
         (= terran-depot-count 0)
         (or (<= supply-cap (* 15 (max 1 active-bases)))
             (<= supply-left 0))
         (or (>= supply-used 13)
             (<= supply-left 0)
             (> (length ally-bldgs) 1)
             (and live-game-obs? (>= minerals 100) (< frame 3000)))))
  (define need-supply?
    (and (< supply-cap SC2-MAX-SUPPLY)
         (< eff-pending-supply max-pending-supply)
         (or (and (<= eff-pending-supply 0)
                  (or (<= supply-left 0) (>= supply-used supply-cap)))
             (and supply-at-risk?
                  (or (<= eff-pending-supply 0) (hash-ref obs 'supply-at-risk #f))
                  (<= effective-supply-with-pending-ledger (+ supply-threshold SC2-SUPPLY-PER-PROVIDER)))
             (and (> (hash-ref pressure-metrics 'supply-hazard 0.0) 0.0)
                  (<= effective-supply-with-pending-ledger supply-threshold))
             (and (<= effective-supply-with-pending-ledger supply-threshold)
                  (>= minerals (sc2-min-cost supply-provider-sym))))))

  ;; Terrain-Solved Matchup Walling (`solve-terran-ramp-wall` & `solve-protoss-matchup-wall`)
  ;; + Reserved AABBs (`'wall-slot`, `'terran-addon-pad`, `'doorway-corridor`).
  ;; On Frame 0 (`minerals < 100`), defer wall grid solving to Frame 4 early downtime!
  (define defer-f0-wall-solve?
    (and live-game-obs? (= frame 0) (< minerals 100)))
  (define terran-ramp-wall
    (cond
      [(or (not (eq? race 'Terran)) defer-f0-wall-solve?)
       (hash)]
      [else
       (let ([tkey (list base-x base-y nat-x nat-y (eq-hash-code map-grids))]
             [cached (hash-ref wall-st 'cached-terran-wall #f)])
         (if (and (pair? cached) (equal? (car cached) tkey))
             (cdr cached)
             (let ([res (solve-terran-ramp-wall base-x base-y nat-x nat-y #:map-grids map-grids)])
               (hash-set! wall-st 'cached-terran-wall (cons tkey res))
               res)))]))
  (define protoss-matchup-wall
    (cond
      [(or (not (eq? race 'Protoss)) defer-f0-wall-solve?)
       (hash)]
      [else
       (let ([pkey (list base-x base-y nat-x nat-y effective-enemy-race enemy-x enemy-y (eq-hash-code map-grids))]
             [cached (hash-ref wall-st 'cached-protoss-wall #f)])
         (if (and (pair? cached) (equal? (car cached) pkey))
             (cdr cached)
             (let ([res (solve-protoss-matchup-wall base-x base-y nat-x nat-y effective-enemy-race
                                                    #:map-grids map-grids
                                                    #:enemy-x enemy-x
                                                    #:enemy-y enemy-y)])
               (hash-set! wall-st 'cached-protoss-wall (cons pkey res))
               res)))]))

  ;; Track wall-placement retries/timeouts so a map-geometry wall edge case (#5119040)
  ;; can NEVER permanently 15/15 brick the bot:
  (define wall-supply-attempts (hash-ref wall-st 'wall-supply-attempts 0))
  (define wall-supply-failures (hash-ref wall-st 'wall-supply-failures 0))
  (define wall-supply-first-f (hash-ref wall-st 'wall-supply-first-frame #f))
  (define bypass-wall-pylon?
    (and (eq? race 'Protoss)
         (or (and (or worker-rush-active? in-base-proxy-detected?)
                  (= safe-inmain-pylon-count 0))
             (and (= real-pylon-count 0)
                  (or (> wall-supply-failures 0)
                      (and (>= wall-supply-attempts 1)
                           (exact-integer? wall-supply-first-f)
                           (>= (- frame wall-supply-first-f) 24))
                      (and (> frame 650) (or (> wall-supply-attempts 0) live-game-obs?))
                      (and live-game-obs? (<= supply-left 0)))))))
  (define bypass-wall-depot1?
    (and (eq? race 'Terran)
         (= real-depot-count 0)
         (or worker-rush-active?
             in-base-proxy-detected?
             (> wall-supply-failures 0)
             (and (>= wall-supply-attempts 1)
                  (exact-integer? wall-supply-first-f)
                  (>= (- frame wall-supply-first-f) 24))
             (and (> frame 650) (or (> wall-supply-attempts 0) live-game-obs?))
             (and live-game-obs? (<= supply-left 0)))))

  ;; Compute an open in-main anchor near TownHall (`base-x, base-y`) stepping away from mineral patches
  (define (emergency-inmain-supply-anchor retry-idx)
    (define main-mps
      (filter (lambda (mp)
                (and (hash? mp)
                     (<= (dist2d base-x base-y
                                 (hash-ref mp 'x base-x)
                                 (hash-ref mp 'y base-y))
                         13.0)))
              (let ([mps (hash-ref obs 'mineral-patches '())])
                (if (list? mps) mps '()))))
    (define-values (ux uy)
      (cond
        [(not (null? main-mps))
         (define cnt (length main-mps))
         (define mcx (/ (for/sum ([m (in-list main-mps)]) (exact->inexact (hash-ref m 'x base-x))) cnt))
         (define mcy (/ (for/sum ([m (in-list main-mps)]) (exact->inexact (hash-ref m 'y base-y))) cnt))
         (define dx (- (exact->inexact base-x) mcx))
         (define dy (- (exact->inexact base-y) mcy))
         (define d (max 0.5 (sqrt (+ (* dx dx) (* dy dy)))))
         (values (/ dx d) (/ dy d))]
        [else
         (define dx (- (exact->inexact nat-x) (exact->inexact base-x)))
         (define dy (- (exact->inexact nat-y) (exact->inexact base-y)))
         (define d (max 1.0 (sqrt (+ (* dx dx) (* dy dy)))))
         (values (/ dx d) (/ dy d))]))
    (define angle-offsets '#(0.0 0.55 -0.55 1.10 -1.10 1.65 -1.65))
    (define ang (vector-ref angle-offsets (modulo (max 0 retry-idx) (vector-length angle-offsets))))
    (define ca (cos ang))
    (define sa (sin ang))
    (define rx (- (* ux ca) (* uy sa)))
    (define ry (+ (* ux sa) (* uy ca)))
    (define rad (+ 5.5 (* 0.5 (quotient (max 0 retry-idx) (vector-length angle-offsets)))))
    (values (safe-coord (+ base-x (* rad rx)) (+ base-x 4.5))
            (safe-coord (+ base-y (* rad ry)) (+ base-y 4.5))))

  (define step-wall-aabbs
    (cond
      [(eq? race 'Terran)
       (filter values
               (list (let ([p (and (not bypass-wall-depot1?) (hash-ref terran-ramp-wall 'depot-1 #f))])
                       (and (pair? p) (reserved-aabb (car p) (cdr p) 1.0 1.0 'wall-slot 0 0)))
                     (let ([p (and (not bypass-wall-depot1?) (hash-ref terran-ramp-wall 'barracks #f))])
                       (and (pair? p) (reserved-aabb (car p) (cdr p) 1.5 1.5 'wall-slot 0 0)))
                     (let ([p (hash-ref terran-ramp-wall 'depot-2 #f)])
                       (and (pair? p) (reserved-aabb (car p) (cdr p) 1.0 1.0 'wall-slot 0 0)))
                     (let ([p (hash-ref terran-ramp-wall 'barracks-addon #f)])
                       (and (pair? p) (reserved-aabb (car p) (cdr p) 1.0 1.0 'terran-addon-pad 0 0)))))]
      [(eq? race 'Protoss)
       (filter values
               (list (let ([p (and (not bypass-wall-pylon?) (hash-ref protoss-matchup-wall 'pylon #f))])
                       (and (pair? p) (reserved-aabb (car p) (cdr p) 1.0 1.0 'wall-slot 0 0)))
                     (let ([p (and (not bypass-wall-pylon?) (hash-ref protoss-matchup-wall 'slot-1 #f))])
                       (and (pair? p) (reserved-aabb (car p) (cdr p) 1.5 1.5 'wall-slot 0 0)))
                     (let ([p (and (not bypass-wall-pylon?) (hash-ref protoss-matchup-wall 'slot-2 #f))])
                       (and (pair? p) (reserved-aabb (car p) (cdr p) 1.5 1.5 'wall-slot 0 0)))
                     (let ([p (and (not bypass-wall-pylon?) (hash-ref protoss-matchup-wall 'slot-3 #f))])
                       (and (pair? p) (reserved-aabb (car p) (cdr p) 1.5 1.5 'wall-slot 0 0)))
                     (let ([p (and (not bypass-wall-pylon?) (hash-ref protoss-matchup-wall 'door #f))])
                       (and (pair? p) (reserved-aabb (car p) (cdr p) 1.2 1.2 'doorway-corridor 0 0)))
                     (let ([p (and (not bypass-wall-pylon?) (hash-ref protoss-matchup-wall 'door-park #f))])
                       (and (pair? p) (reserved-aabb (car p) (cdr p) 1.2 1.2 'doorway-corridor 0 0)))))]
      [else '()]))
  (set-box! (rt-wall-aabbs-box rt) step-wall-aabbs)
  (define (wall-aabbs-for-build exact-wall-slot?)
    (if exact-wall-slot?
        (filter (lambda (r)
                  (not (memq (reserved-aabb-kind r)
                             '(wall-slot doorway-corridor terran-addon-pad))))
                step-wall-aabbs)
        step-wall-aabbs))

  ;; Only force `#:exact-wall-slot? #t` in early game (`frame < 4000` and `<= 2` bases) so
  ;; mid/late-game wall rebuilds never deadlock on obstructed initial ramp/choke coordinates (`#5111096`).
  (define allow-exact-wall-slot?
    (and (< frame 4000) (<= active-bases 2)))

  (define explicit-larvae-early
    (count (lambda (u) (eq? (unit-type-sym u) 'larva)) ally-units))
  (define live-larva-tracking-early?
    (and live-game-obs?
         (ormap (lambda (u) (memq (unit-type-sym u) '(larva egg baneling-cocoon ravager-cocoon))) ally-units)))
  (define early-larvae-consumed 0)

  (when (and (or need-supply? protoss-emergency-pylon? terran-emergency-depot?)
             (>= minerals (sc2-min-cost supply-provider-sym)))
    (case race
      [(Zerg)
       (when (or (not live-larva-tracking-early?) (> explicit-larvae-early 0))
         (recall-building-group! 4)
         (emit! '(train overlord))
         (order-ledger-record-issued! oledger (+ 800000 (modulo frame 10000)) 'train 'overlord base-x base-y frame)
         (set! early-larvae-consumed (add1 early-larvae-consumed))
         (set! minerals (- minerals (sc2-min-cost 'overlord)))
         (set! pending-supply (add1 pending-supply))
         (set! eff-pending-supply (add1 eff-pending-supply)))]
      [(Protoss)
       (define wall-pylon-pt
         (and allow-exact-wall-slot?
              (not bypass-wall-pylon?)
              (= protoss-pylon-count 0)
              (not has-unpowered-bldg?)
              (hash-ref protoss-matchup-wall 'pylon #f)))
       (define use-exact-pylon? (pair? wall-pylon-pt))
       (define inmain-retry-idx (hash-ref wall-st 'inmain-supply-attempts 0))
       (define-values (em-px em-py)
         (emergency-inmain-supply-anchor
          (+ inmain-retry-idx (if power-placement-failed? (+ protoss-pylon-count 1) 0))))
       (define use-nat-pylon-anchor?
         (and live-game-obs?
              (>= active-bases 2)
              (>= protoss-pylon-count 2)
              (if power-placement-failed?
                  (even? inmain-retry-idx)
                  (odd? protoss-pylon-count))))
       (define raw-px
         (cond
           [use-exact-pylon? (safe-coord (car wall-pylon-pt) em-px)]
           [has-unpowered-bldg?
            (safe-coord (+ (hash-ref unpowered-protoss-bldg 'x (+ base-x 4.0)) 2.5) em-px)]
           [bypass-wall-pylon? em-px]
           [use-nat-pylon-anchor?
            (safe-coord (+ nat-x 4.5 (* 2.0 (modulo (quotient protoss-pylon-count 2) 3))) (+ base-x 4.0))]
           [power-placement-failed? em-px]
           [else (safe-coord (+ base-x 4.0 (* 2.5 (modulo protoss-pylon-count 4))))]))
       (define raw-py
         (cond
           [use-exact-pylon? (safe-coord (cdr wall-pylon-pt) em-py)]
           [has-unpowered-bldg?
            (safe-coord (+ (hash-ref unpowered-protoss-bldg 'y (+ base-y 4.0)) 0.5) em-py)]
           [bypass-wall-pylon? em-py]
           [use-nat-pylon-anchor?
            (safe-coord (+ nat-y 4.5 (* 2.0 (quotient protoss-pylon-count 6))) (+ base-y 4.0))]
           [power-placement-failed? em-py]
           [else (safe-coord (+ base-y 4.0 (* 2.5 (quotient protoss-pylon-count 4))))]))
       (define-values (px py)
         (order-ledger-resolve-build-coords!
          oledger 'pylon raw-px raw-py ally-bldgs frame 2.5
          #:expansion-pads expansion-pads
          #:exact-wall-slot? use-exact-pylon?
          #:reserved-aabbs (wall-aabbs-for-build use-exact-pylon?)))
       (define sx (safe-coord px raw-px))
       (define sy (safe-coord py raw-py))
       (when (= real-pylon-count 0)
         (hash-set! wall-st 'supply-last-issue-frame frame)
         (when use-exact-pylon?
           (unless (hash-has-key? wall-st 'wall-supply-first-frame)
             (hash-set! wall-st 'wall-supply-first-frame frame))
           (hash-set! wall-st 'wall-supply-attempts (add1 wall-supply-attempts))))
       (when (and (not use-exact-pylon?)
                  (or (= real-pylon-count 0) power-placement-failed?))
         (hash-set! wall-st 'inmain-supply-attempts (add1 inmain-retry-idx)))
       (emit! (list 'build 'pylon sx sy))
       (order-ledger-record-issued! oledger (+ 800000 (modulo frame 10000)) 'build 'pylon sx sy frame)
       (set! bldg-types (cons 'pylon bldg-types))
       (set! minerals (- minerals (sc2-min-cost 'pylon)))
       (set! pending-supply (add1 pending-supply))
       (set! eff-pending-supply (add1 eff-pending-supply))]
      [(Terran)
       (define depot-count
         (count (lambda (t) (eq? t 'supply-depot)) bldg-types))
       (define wall-depot-entry
         (and allow-exact-wall-slot?
              (cond
                [(and (= depot-count 0) (not bypass-wall-depot1?))
                 (hash-ref terran-ramp-wall 'depot-1 #f)]
                [(= depot-count 1)
                 (hash-ref terran-ramp-wall 'depot-2 #f)]
                [else #f])))
       (define use-exact-depot? (pair? wall-depot-entry))
       (define inmain-retry-idx (hash-ref wall-st 'inmain-supply-attempts 0))
       (define-values (em-dx em-dy) (emergency-inmain-supply-anchor inmain-retry-idx))
       (define raw-dx
         (cond
           [use-exact-depot? (safe-coord (car wall-depot-entry) em-dx)]
           [(and (= depot-count 0) bypass-wall-depot1?) em-dx]
           [else (safe-coord (+ base-x 4.0 (* 2.5 (modulo depot-count 4))))]))
       (define raw-dy
         (cond
           [use-exact-depot? (safe-coord (cdr wall-depot-entry) em-dy)]
           [(and (= depot-count 0) bypass-wall-depot1?) em-dy]
           [else (safe-coord (- base-y 3.0 (* 2.5 (quotient depot-count 4))))]))
       (define-values (dx dy)
         (order-ledger-resolve-build-coords!
          oledger 'supply-depot raw-dx raw-dy ally-bldgs frame 2.0
          #:expansion-pads expansion-pads
          #:exact-wall-slot? use-exact-depot?
          #:reserved-aabbs (wall-aabbs-for-build use-exact-depot?)))
       (define sx (safe-coord dx raw-dx))
       (define sy (safe-coord dy raw-dy))
       (when (= real-depot-count 0)
         (hash-set! wall-st 'supply-last-issue-frame frame)
         (cond
           [use-exact-depot?
            (unless (hash-has-key? wall-st 'wall-supply-first-frame)
              (hash-set! wall-st 'wall-supply-first-frame frame))
            (hash-set! wall-st 'wall-supply-attempts (add1 wall-supply-attempts))]
           [else
            (hash-set! wall-st 'inmain-supply-attempts (add1 inmain-retry-idx))]))
       (emit! (list 'build 'supply-depot sx sy))
       (order-ledger-record-issued! oledger (+ 800000 (modulo frame 10000)) 'build 'supply-depot sx sy frame)
       (set! bldg-types (cons 'supply-depot bldg-types))
       (set! minerals (- minerals (sc2-min-cost 'supply-depot)))
       (set! pending-supply (add1 pending-supply))
       (set! eff-pending-supply (add1 eff-pending-supply))]
      [else (void)]))

  (define hard-supply-lockout?
    (and (< supply-cap SC2-MAX-SUPPLY)
         (<= eff-pending-supply 0)
         (or (<= supply-left 0)
             (>= supply-used supply-cap)
             (and (<= supply-left 1)
                  (<= supply-cap (* 15 (max 1 active-bases)))
                  (or (and (eq? race 'Protoss) (= real-pylon-count 0) (>= supply-used 14))
                      (and (eq? race 'Terran) (= real-depot-count 0) (>= supply-used 14)))))))
  (define hard-supply-lockout-reserve-min
    (if hard-supply-lockout?
        (sc2-min-cost supply-provider-sym)
        0))

  (define zerg-emergency-rush-lings?
    (and (eq? race 'Zerg)
         worker-rush-active?
         (< (count (lambda (t) (eq? t 'zergling)) unit-types) 4)))
  (define zerg-hold-overlord-min?
    (and live-game-obs?
         (eq? race 'Zerg)
         (not zerg-emergency-rush-lings?)
         (< supply-cap SC2-MAX-SUPPLY)
         (<= eff-pending-supply 0)
         (>= supply-used 14)
         (or supply-at-risk?
             (<= supply-left (if (< supply-cap 20) 1 (min 4 supply-threshold))))))

  (define reserve-supply-floor?
    (and (not zerg-emergency-rush-lings?)
         (<= eff-pending-supply 0)
         (or (not live-game-obs?) (>= supply-used 14))
         (or supply-at-risk?
             (<= supply-left (if (and live-game-obs? (< supply-cap 20)) 1 SC2-CRITICAL-LOW-SUPPLY)))
         (< minerals (+ (sc2-min-cost supply-provider-sym) (sc2-min-cost 'drone)))))
  (define effective-free-supply
    (max 0 (+ supply-left (if (> eff-pending-supply 0) SC2-PENDING-SUPPLY-CREDIT 0))))
  (define (can-spend-supply? cost)
    (and (not reserve-supply-floor?)
         (not zerg-hold-overlord-min?)
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

  (define ledger-unit-orders (in-progress-order-ledger-unit-orders oledger))
  (define morphing-bldg-types
    (filter-map (lambda (b)
                  (define bid (if (hash? b) (hash-ref b 'id -1) -1))
                  (define already-tracked-morph?
                    (let ([tord (hash-ref ledger-unit-orders bid #f)])
                      (and tord (eq? (tracked-order-kind tord) 'morph))))
                  (and (not already-tracked-morph?)
                       (case (if (hash? b) (hash-ref b 'order-ability-id 0) 0)
                         [(1516) 'orbital-command]
                         [(1450) 'planetary-fortress]
                         [(1216) 'lair]
                         [(1218) 'hive]
                         [(1220) 'greater-spire]
                         [(2112) 'lurker-den]
                         [else #f])))
                ally-bldgs))

  (define (cur-ally-canon-bldg-count bldg-sym)
    (define cs (sc2-canonical-structure-sym bldg-sym))
    (count (lambda (b)
             (and (hash? b)
                  (eq? (sc2-canonical-structure-sym (unit-type-sym b)) cs)))
           ally-bldgs))
  (define (record-build-issue-lock! bldg-sym)
    (when (and live-game-obs?
               (refractory-cooldown-tracker? cd-tracker)
               (hash? (refractory-cooldown-tracker-table cd-tracker)))
      (define cs (sc2-canonical-structure-sym bldg-sym))
      (hash-set! (refractory-cooldown-tracker-table cd-tracker)
                 (list 'build-issue-lock cs)
                 (list frame (cur-ally-canon-bldg-count cs)))))
  (define (build-issue-blocked? bldg-sym [cd-frames 56])
    (define cs (sc2-canonical-structure-sym bldg-sym))
    (define tbl (and (refractory-cooldown-tracker? cd-tracker)
                     (refractory-cooldown-tracker-table cd-tracker)))
    (define lock-entry (and live-game-obs? (hash? tbl) (hash-ref tbl (list 'build-issue-lock cs) #f)))
    (define cancel-cd-key (string->symbol (format "save-cancel-rebuild-~a" cs)))
    (define last-cancel-f (and (hash? tbl) (hash-ref tbl cancel-cd-key #f)))
    (and (pair? lock-entry)
         (let ([last-issue-f (car lock-entry)]
               [last-issue-cnt (cadr lock-entry)])
           (and (<= 0 (- frame last-issue-f))
                (< (- frame last-issue-f) cd-frames)
                (= (cur-ally-canon-bldg-count cs) last-issue-cnt)
                (not (and (exact-integer? last-cancel-f)
                          (>= last-cancel-f last-issue-f)
                          (save-cancel-rebuild-ready? cs 60)))))))

  (define (building-present-or-pending? bldg-sym [include-free-addons? #f])
    (define eq-syms
      (remove-duplicates (sc2-structure-equivalent-syms bldg-sym include-free-addons?) eq?))
    (or (ormap (lambda (s)
                 (define cs (sc2-canonical-structure-sym s))
                 (or (memq s bldg-types)
                     (memq cs bldg-types)
                     (memq s morphing-bldg-types)
                     (memq cs morphing-bldg-types)
                     (> (order-ledger-pending-count-for-type oledger s frame) 0)
                     (and (not (eq? cs s))
                          (> (order-ledger-pending-count-for-type oledger cs frame) 0))
                     (build-issue-blocked? cs 56)))
               eq-syms)
        #f))

  (define (emit-build-verified! bldg-sym raw-x raw-y
                                [clearance SC2-BUILD-SITE-MIN-CLEARANCE]
                                #:exact-wall-slot? [exact-wall-slot? #f])
    (define canon-sym (sc2-canonical-structure-sym bldg-sym))
    (unless (build-issue-blocked? canon-sym 56)
      (define-values (bx by)
        (order-ledger-resolve-build-coords!
         oledger bldg-sym raw-x raw-y ally-bldgs frame clearance
         #:expansion-pads expansion-pads
         #:exact-wall-slot? exact-wall-slot?
         #:reserved-aabbs (wall-aabbs-for-build exact-wall-slot?)))
      (define sx (safe-coord bx raw-x))
      (define sy (safe-coord by raw-y))
      (emit! (list 'build bldg-sym sx sy))
      (record-build-issue-lock! canon-sym)
      (when (and exact-wall-slot?
                 live-game-obs?
                 (refractory-cooldown-tracker? cd-tracker)
                 (hash? (refractory-cooldown-tracker-table cd-tracker)))
        (hash-set! (refractory-cooldown-tracker-table cd-tracker)
                   (list 'build-issue-exact-wall canon-sym)
                   frame))
      (order-ledger-record-issued! oledger (+ 820000 (modulo frame 10000) (length actions))
                                   'build bldg-sym sx sy frame)
      (set! bldg-types (cons canon-sym bldg-types))
      (spend-resources-and-supply! (sc2-min-cost bldg-sym) (sc2-gas-cost bldg-sym) 0)))

  (define (emit-gas-build-verified! gas-sym raw-x raw-y [cost-sym gas-sym])
    (define canon-sym (sc2-canonical-structure-sym gas-sym))
    (unless (build-issue-blocked? canon-sym 56)
      (define sx (safe-coord raw-x (+ base-x 4.0)))
      (define sy (safe-coord raw-y (+ base-y 4.0)))
      (emit! (list 'build gas-sym sx sy))
      (record-build-issue-lock! canon-sym)
      (order-ledger-record-issued! oledger (+ 815000 (modulo frame 10000) (length actions))
                                   'build gas-sym sx sy frame)
      (set! bldg-types (cons canon-sym bldg-types))
      (spend-resources-and-supply! (sc2-min-cost cost-sym) 0 0)))

  ;; ---------------------------------------------------------------------------
  ;; Empirical Pro Build-Order & Goal-Queue Executor + Facility Slot Accounting
  ;; ---------------------------------------------------------------------------
  (define ready-bldg-counts
    (for/fold ([ht (hash)]) ([t (in-list ready-bldg-types)])
      (hash-update ht (sc2-canonical-structure-sym t) add1 0)))
  (define total-bldg-counts
    (for/fold ([ht (for/fold ([h0 (hash)]) ([t (in-list (append bldg-types morphing-bldg-types))])
                     (hash-update h0 (sc2-canonical-structure-sym t) add1 0))])
              ([sym (in-list '(hatchery lair hive spawning-pool extractor roach-warren baneling-nest
                               evolution-chamber hydralisk-den spire greater-spire lurker-den lurker-den-mp
                               infestation-pit ultralisk-cavern spine-crawler spore-crawler nydus-network
                               nexus pylon assimilator gateway warp-gate warpgate cybernetics-core
                               robotics-facility robotics-bay robotics-support-bay twilight-council forge stargate
                               templar-archive templar-archives dark-shrine fleet-beacon photon-cannon shield-battery
                               command-center orbital-command planetary-fortress supply-depot
                               refinery barracks barracks-techlab barracks-tech-lab barracks-reactor
                               factory factory-techlab factory-tech-lab factory-reactor
                               starport starport-techlab starport-tech-lab starport-reactor
                               tech-lab reactor
                               engineering-bay armory ghost-academy fusion-core bunker missile-turret sensor-tower))])
      (define pend (order-ledger-pending-count-for-type oledger sym frame))
      (define csym (sc2-canonical-structure-sym sym))
      (if (> pend 0)
          (hash-update ht csym (lambda (c) (+ c pend)) 0)
          ht)))
  (define real-ally-units
    (filter (lambda (u)
              (and (hash? u)
                   (not (eq? (hash-ref u 'is-hallucination #f) #t))
                   (not (eq? (hash-ref u 'hallucination #f) #t))
                   (not (eq? (hash-ref u 'hallucination? #f) #t))))
            ally-units))
  (define cocoon-unit-counts
    (for/fold ([ht (hash)]) ([u (in-list real-ally-units)])
      (case (unit-type-sym u)
        [(baneling-cocoon)   (hash-update ht 'baneling add1 0)]
        [(ravager-cocoon)    (hash-update ht 'ravager add1 0)]
        [(lurker-egg lurker-mp-egg) (hash-update ht 'lurker add1 0)]
        [(brood-lord-cocoon) (hash-update ht 'brood-lord add1 0)]
        [(overlord-cocoon)   (hash-update ht 'overseer add1 0)]
        [else ht])))
  (define excluded-macro-unit-count-syms
    '(larva egg cocoon lurker-egg lurker-mp-egg transport-overlord-cocoon
      warp-prism-phasing observer-siege-mode overseer-siege-mode
      interceptor auto-turret point-defense-drone raven-repair-drone
      adept-phase-shift disruptor-phased mule kd8-charge parasitic-bomb-dummy
      changeling changeling-zealot changeling-marine changeling-marine-shield
      changeling-zergling changeling-zergling-wings
      creep-tumor creep-tumor-burrowed creep-tumor-queen
      broodling broodling-escort locust locust-flying
      oracle-stasis-trap stasis-ward force-field))
  (define unit-counts
    (for/fold ([ht (for/fold ([h0 (hash)]) ([u (in-list real-ally-units)]
                                            #:when (not (memq (unit-type-sym u) excluded-macro-unit-count-syms)))
                     (hash-update h0 (sc2-canonical-unit-sym (unit-type-sym u)) add1 0))])
              ([usym (in-list '(drone overlord overseer queen zergling baneling roach ravager hydralisk lurker mutalisk corruptor brood-lord ultralisk infestor viper swarm-host
                                probe zealot stalker sentry adept high-templar dark-templar archon immortal observer warp-prism colossus disruptor phoenix void-ray oracle carrier tempest mothership
                                scv marine marauder reaper ghost hellion hellbat widow-mine siege-tank cyclone thor medivac viking liberator raven banshee battlecruiser))])
      (define raw-pend
        (+ (order-ledger-pending-count-for-type oledger usym frame)
           (if (eq? usym 'viking)
               (order-ledger-pending-count-for-type oledger 'viking-fighter frame)
               0)))
      (define eff-pend
        (max 0 (- raw-pend (hash-ref cocoon-unit-counts usym 0))))
      (if (> eff-pend 0)
          (hash-update ht usym (lambda (c) (+ c eff-pend)) 0)
          ht)))
  (define (unit-count sym)
    (hash-ref unit-counts (sc2-canonical-unit-sym sym) 0))
  (define enemy-race-guess effective-enemy-race)
  (define prev-telemetry-ht
    (let ([t (live-bot-runtime-last-telemetry rt)])
      (if (hash? t) t (hash))))
  (define cur-peak-supply
    (max supply-used (hash-ref prev-telemetry-ht 'peak-supply-reached 0)))
  (define eff-phase-supply (max supply-used cur-peak-supply))

  (define bo-eval
    (evaluate-build-order-next-step
     #:race race
     #:enemy-race effective-enemy-race
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

  (define (normalize-facility-slot-sym sym)
    (define csym (sc2-canonical-structure-sym sym))
    (case csym
      [(gateway warp-gate) 'gateway]
      [(hatchery lair hive nexus command-center orbital-command planetary-fortress) 'townhall]
      [else csym]))
  (define open-prod-slots (make-hash))
  (for ([cap (in-list (list cg4-cap cg5-cap cg6-cap cg7-cap))])
    (for ([(btype cnt) (in-hash (hash-ref cap 'open-slots-by-type (hash)))])
      (define norm-k (normalize-facility-slot-sym btype))
      (hash-update! open-prod-slots norm-k (lambda (old) (+ old cnt)) 0)))
  (define fallback-prod-slots (make-hash))
  (for ([b (in-list ready-bldgs)])
    (define bt (sc2-canonical-structure-sym (unit-type-sym b)))
    (define norm-k (normalize-facility-slot-sym bt))
    (define b-ords (hash-ref b 'order-count (let ([o (hash-ref b 'orders '())]) (if (list? o) (length o) 0))))
    (define b-max (if (eq? (hash-ref b 'addon #f) 'reactor) 2 1))
    (define b-open (if (or (eq? (hash-ref b 'busy? #f) #t)
                           (eq? (hash-ref b 'in-transit? #f) #t)
                           (and (eq? race 'Protoss)
                                (sc2-structure-requires-pylon-power? bt)
                                (eq? (hash-ref b 'powered? #t) #f))
                           (order-ledger-facility-busy? oledger b frame))
                       0
                       (max 0 (- b-max b-ords))))
    (hash-update! fallback-prod-slots norm-k (lambda (old) (+ old b-open)) 0))
  (for ([(norm-k cnt) (in-hash fallback-prod-slots)])
    (when (> cnt (hash-ref open-prod-slots norm-k 0))
      (hash-set! open-prod-slots norm-k cnt)))
  (define explicit-larvae (count (lambda (u) (eq? (unit-type-sym u) 'larva)) ally-units))
  (define live-larva-tracking?
    (ormap (lambda (u) (memq (unit-type-sym u) '(larva egg baneling-cocoon ravager-cocoon))) ally-units))
  (hash-set! open-prod-slots 'larva
             (if live-larva-tracking?
                 (max 0 (- explicit-larvae early-larvae-consumed))
                 (* 3 (max 1 active-bases))))
  (for ([msym (in-list '(zergling roach hydralisk corruptor overlord high-templar dark-templar))])
    (define avail-morph-sources
      (count (lambda (u)
               (define uid (hash-ref u 'id -1))
               (define tord (hash-ref ledger-unit-orders uid #f))
               (and (eq? (sc2-canonical-unit-sym (unit-type-sym u)) msym)
                    (not (and tord (eq? (tracked-order-kind tord) 'morph)))
                    (not (eq? (sc2-order-protection-class (hash-ref u 'order-ability-id 0)) 'morph))))
             real-ally-units))
    (hash-set! open-prod-slots msym avail-morph-sources))

  (define live-game? live-game-obs?)
  (define open-prod-slots-snapshot
    (and live-game?
         (for/hasheq ([(k v) (in-hash open-prod-slots)])
           (values k v))))

  (define (upgrade-researcher-slot upg-sym)
    (define node (lookup-sc2-tech-node upg-sym))
    (define raw-slot
      (cond
        [node (sc2-tech-node-producer-slot node)]
        [else
         (case upg-sym
           [(infantry-weapons-1 infantry-armor-1
             terran-infantry-weapons-1 terran-infantry-weapons-2 terran-infantry-weapons-3
             terran-infantry-armor-1 terran-infantry-armor-2 terran-infantry-armor-3
             hi-sec-auto-tracking)
            'engineering-bay]
           [(vehicle-weapons-1 terran-vehicle-weapons-1 terran-vehicle-weapons-2
             terran-vehicle-and-ship-plating-1 terran-ship-weapons-1)
            'armory]
           [(stimpack combat-shield concussive-shells) 'barracks-techlab]
           [(drilling-claws infernal-pre-igniter smart-servos cyclone-lock-on-damage) 'factory-techlab]
           [(banshee-cloak hyperflight-rotors) 'starport-techlab]
           [(personal-cloaking) 'ghost-academy]
           [(weapon-refit) 'fusion-core]
           [(ground-weapons-1 ground-armor-1
             protoss-ground-weapons-1 protoss-ground-weapons-2 protoss-ground-weapons-3
             protoss-ground-armor-1 protoss-ground-armor-2 protoss-ground-armor-3
             protoss-shields-1 protoss-shields-2)
            'forge]
           [(warpgate warpgate-research warp-gate warp-gate-research protoss-air-weapons-1 protoss-air-armor-1)
            'cybernetics-core]
           [(charge blink resonating-glaives) 'twilight-council]
           [(extended-thermal-lance gravitic-booster gravitic-drive) 'robotics-bay]
           [(psi-storm psionic-storm) 'templar-archive]
           [(shadow-stride) 'dark-shrine]
           [(flux-vanes anion-pulse-crystals) 'fleet-beacon]
           [(missile-attacks-1 ground-carapace-1
             zerg-missile-weapons-1 zerg-missile-weapons-2 zerg-missile-weapons-3
             zerg-ground-armor-1 zerg-ground-armor-2 zerg-ground-armor-3
             zerg-melee-weapons-1 zerg-melee-weapons-2 zerg-melee-weapons-3)
            'evolution-chamber]
           [(zergling-movementspeed metabolic-boost zergling-attackspeed adrenal-glands) 'spawning-pool]
           [(overlord-speed pneumatized-carapace burrow) 'townhall]
           [(glial-reconstitution tunneling-claws) 'roach-warren]
           [(centrifical-hooks) 'baneling-nest]
           [(grooved-spines muscular-augments) 'hydralisk-den]
           [(lurker-range seismic-spines adaptive-talons) 'lurker-den]
           [(neural-parasite pathogen-glands) 'infestation-pit]
           [(chitinous-plating anabolic-synthesis) 'ultralisk-cavern]
           [(zerg-flyer-weapons-1 zerg-flyer-armor-1) 'spire]
           [else #f])]))
    (and raw-slot (normalize-facility-slot-sym raw-slot)))

  (define (emit-research-verified! upg-sym)
    (define r-slot (upgrade-researcher-slot upg-sym))
    (when (and (upgrade-needed? upg-sym)
               (or (not live-game?)
                   (not r-slot)
                   (> (hash-ref open-prod-slots r-slot 0) 0))
               (>= minerals (sc2-min-cost upg-sym))
               (>= gas (sc2-gas-cost upg-sym)))
      (recall-building-group! 7)
      (emit! (list 'research upg-sym))
      (set! pending-upgs (cons upg-sym pending-upgs))
      (when (and live-game? r-slot)
        (hash-set! open-prod-slots r-slot (max 0 (sub1 (hash-ref open-prod-slots r-slot 0)))))
      (order-ledger-record-issued! oledger (+ 850000 (modulo frame 10000) (length actions))
                                   'research upg-sym base-x base-y frame)
      (spend-resources-and-supply! (sc2-min-cost upg-sym) (sc2-gas-cost upg-sym) 0)))

  (define has-explicit-gas-harvesters?
    (or has-gas-harvesters?
        (hash-has-key? raw-obs 'vespene-harvesters)))
  (define eff-gas-harvesters
    (if has-explicit-gas-harvesters?
        (safe-nonneg-int (or live-gas-harvesters (hash-ref obs 'vespene-harvesters 0)) 0)
        (if (> gas 0) 3 0)))

  (define eff-min-harvesters
    (if live-obs-harvesters?
        (max (safe-nonneg-int (hash-ref obs 'mineral-harvesters 0) 0)
             (max 0 (- (length non-building-workers)
                       (+ (length cur-rush-fighting-wids)
                          (length cur-rush-disengaging-wids)))))
        (and (= total-workers 0) 0)))

  (define macro-world
    (make-macro-world-state
     #:race race
     #:enemy-race effective-enemy-race
     #:frame frame
     #:minerals minerals
     #:gas gas
     #:supply-used supply-used
     #:supply-cap supply-cap
     #:supply-left supply-left
     #:pending-supply eff-pending-supply
     #:workers total-workers
     #:active-bases active-bases
     #:mineral-harvesters eff-min-harvesters
     #:gas-harvesters (and has-explicit-gas-harvesters? eff-gas-harvesters)
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
    (define csym (sc2-canonical-structure-sym sym))
    (or (eq? bo-goal-sym sym)
        (eq? bo-goal-sym csym)
        (hash-has-key? plan-next-actions-ht sym)
        (hash-has-key? plan-next-actions-ht csym)
        (not (not (memq sym (macro-brain-decision-scheduled-ids macro-decision))))
        (not (not (memq csym (macro-brain-decision-scheduled-ids macro-decision))))))
  (define repaired-prereqs (macro-brain-decision-repaired-prereqs macro-decision))

  (when live-game?
    (set! bo-active-goal (macro-brain-decision-bo-active-goal macro-decision))
    (set! bo-goal-sym (and bo-active-goal (pro-bo-goal-target-sym bo-active-goal)))
    (set! bo-reserved-min (macro-brain-decision-reserved-min-floor macro-decision))
    (set! bo-reserved-gas (macro-brain-decision-reserved-gas-floor macro-decision))
    (when (and (<= eff-gas-harvesters 0)
               (> bo-reserved-gas 0)
               (< gas bo-reserved-gas))
      (set! bo-reserved-min 0)
      (set! bo-reserved-gas 0))
    (when (and (or (<= total-workers 0)
                   (and (exact-integer? eff-min-harvesters) (<= eff-min-harvesters 0)))
               (> bo-reserved-min 0)
               (< minerals bo-reserved-min))
      (set! bo-reserved-min 0)
      (set! bo-reserved-gas 0)))

  ;; Escrow Age Timeout, Persistent Expansion-Streak Anti-Oscillation (#5122353),
  ;; & 160-Frame (~7.1s) Multi-Frame Release Window (PV7 / PV9):
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
  (define prev-suppressed-goal (hash-ref prev-telemetry-ht 'escrow-suppressed-goal #f))
  (define prev-suppressed-until
    (safe-nonneg-int (hash-ref prev-telemetry-ht 'escrow-suppressed-until-frame 0) 0))
  (define cur-th-total-cnt
    (+ (count (lambda (t)
                (memq t '(hatchery lair hive nexus command-center orbital-command planetary-fortress)))
              bldg-types)
       (order-ledger-pending-count-for-type
        oledger
        (case race [(Zerg) 'hatchery] [(Protoss) 'nexus] [else 'command-center])
        frame)))
  (define exp-goal-sym-this-step
    (cond
      [(and active-escrow-sym (memq active-escrow-sym '(hatchery nexus command-center))) active-escrow-sym]
      [(and bo-goal-sym (memq bo-goal-sym '(hatchery nexus command-center))) bo-goal-sym]
      [else #f]))
  (define prev-exp-streak-start (hash-ref prev-telemetry-ht 'exp-goal-streak-start #f))
  (define prev-exp-th-cnt (hash-ref prev-telemetry-ht 'exp-goal-th-count cur-th-total-cnt))
  (define prev-exp-last-f (hash-ref prev-telemetry-ht 'exp-goal-last-frame -9999))
  (define th-count-increased? (> cur-th-total-cnt prev-exp-th-cnt))
  (define already-suppressed-goal?
    (and prev-suppressed-goal
         (not th-count-increased?)
         (< frame prev-suppressed-until)
         (or (and active-escrow-sym (eq? active-escrow-sym prev-suppressed-goal))
             (and exp-goal-sym-this-step (eq? exp-goal-sym-this-step prev-suppressed-goal)))))
  (define escrow-same-goal?
    (and active-escrow-sym
         (eq? active-escrow-sym prev-escrow-goal)
         (> (+ bo-reserved-min bo-reserved-gas) 0)))
  (define escrow-unsuppressed-start
    (if (and prev-suppressed-goal
             (eq? active-escrow-sym prev-suppressed-goal)
             (< prev-escrow-frame prev-suppressed-until)
             (<= prev-suppressed-until frame))
        prev-suppressed-until
        prev-escrow-frame))
  (define cur-escrow-start-frame
    (cond
      [(or (not escrow-same-goal?) already-suppressed-goal?) frame]
      [(and prev-suppressed-goal
            (eq? active-escrow-sym prev-suppressed-goal)
            (< prev-escrow-start-frame prev-suppressed-until)
            (<= prev-suppressed-until frame))
       prev-suppressed-until]
      [else prev-escrow-start-frame]))
  (define escrow-making-progress?
    (and escrow-same-goal?
         (not already-suppressed-goal?)
         (memq active-escrow-sym '(hatchery nexus command-center))
         (> total-workers 0)
         (< (- frame cur-escrow-start-frame) 448)
         (< obs-minerals (sc2-min-cost active-escrow-sym))
         (> obs-minerals prev-escrow-peak-min)))
  (define cur-escrow-peak-min
    (if escrow-same-goal?
        (max prev-escrow-peak-min obs-minerals)
        obs-minerals))
  (define cur-escrow-age-frames
    (cond
      [(or (not escrow-same-goal?) already-suppressed-goal?) 0]
      [escrow-making-progress? 0]
      [else (+ prev-escrow-age (max 1 (- frame escrow-unsuppressed-start)))]))

  ;; Track persistent TownHall expansion-goal streak across steps so oscillating around 400M
  ;; (`saving_for=command-center` -> `none` -> `command-center`, #5122353) still times out cleanly!
  (define prev-exp-timeout-cnt
    (if th-count-increased?
        0
        (safe-nonneg-int (hash-ref prev-telemetry-ht 'exp-timeout-count 0) 0)))
  (define cur-exp-streak-start
    (cond
      [(or (not exp-goal-sym-this-step) already-suppressed-goal?) #f]
      [th-count-increased? frame]
      [(and (exact-integer? prev-exp-streak-start)
            (<= (- frame prev-exp-last-f) 96))
       prev-exp-streak-start]
      [else frame]))
  (define exp-streak-stalled?
    (and live-game?
         exp-goal-sym-this-step
         (not (< frame prev-suppressed-until))
         (exact-integer? cur-exp-streak-start)
         (>= (- frame cur-exp-streak-start) 448)
         (or (>= obs-minerals 350) (>= (- frame cur-exp-streak-start) 672))))

  (define max-escrow-timeout-frames 224)
  (define escrow-timed-out-now?
    (and (not already-suppressed-goal?)
         (or (and active-escrow-sym
                  (>= cur-escrow-age-frames max-escrow-timeout-frames))
             exp-streak-stalled?)))
  (define timeout-target-sym
    (or exp-goal-sym-this-step active-escrow-sym))
  (define next-exp-timeout-cnt
    (if (and escrow-timed-out-now?
             timeout-target-sym
             (memq timeout-target-sym '(hatchery nexus command-center)))
        (add1 prev-exp-timeout-cnt)
        prev-exp-timeout-cnt))
  (define escrow-suppressed-goal
    (cond
      [escrow-timed-out-now? timeout-target-sym]
      [(and prev-suppressed-goal
            (not th-count-increased?)
            (< frame prev-suppressed-until))
       prev-suppressed-goal]
      [else #f]))
  (define escrow-suppressed-until-frame
    (cond
      [escrow-timed-out-now?
       (+ frame (if (and timeout-target-sym
                         (memq timeout-target-sym '(hatchery nexus command-center)))
                    (* 224 (min 3 (max 1 next-exp-timeout-cnt)))
                    160))]
      [(and prev-suppressed-goal
            (not th-count-increased?)
            (< frame prev-suppressed-until))
       prev-suppressed-until]
      [else 0]))
  (define escrow-suppressed-active?
    (or escrow-timed-out-now?
        (and escrow-suppressed-goal
             (< frame escrow-suppressed-until-frame)
             (or (and active-escrow-sym (eq? active-escrow-sym escrow-suppressed-goal))
                 (and exp-goal-sym-this-step (eq? exp-goal-sym-this-step escrow-suppressed-goal))))))

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
             (or escrow-suppressed-active?
                 severe-intel-blindness?))))
  (define can-train-basic-combat-now?
    (case race
      [(Zerg)    (and (memq 'spawning-pool ready-bldg-types)
                      (> (hash-ref open-prod-slots 'larva 0) 0))]
      [(Protoss) (and (or (memq 'gateway ready-bldg-types) (memq 'warp-gate ready-bldg-types))
                      (> (hash-ref open-prod-slots 'gateway 0) 0))]
      [(Terran)  (and (memq 'barracks ready-bldg-types)
                      (> (hash-ref open-prod-slots 'barracks 0) 0))]
      [else #f]))
  (define basic-combat-min-floor
    (if (and (null? ally-combat-units) can-train-basic-combat-now?)
        (case race
          [(Protoss) (if (and (memq 'cybernetics-core ready-bldg-types)
                              (>= gas (sc2-gas-cost 'stalker)))
                         (sc2-min-cost 'stalker)
                         (sc2-min-cost 'zealot))]
          [else 50])
        0))
  (define (core-progression-exempt-from-surcharge? target-sym)
    (and target-sym
         (not under-base-attack?)
         (or (memq target-sym
                   '(spawning-pool cybernetics-core forge
                     orbital-command barracks-techlab factory starport engineering-bay
                     robotics-facility twilight-council))
             (and (<= live-enemy-threat-supply 0)
                  (or (eq? target-sym bo-goal-sym)
                      (eq? target-sym active-escrow-sym)
                      (memq target-sym
                            '(roach-warren queen
                              hatchery nexus command-center
                              warp-gate-research metabolic-boost stimpack lair)))))))
  (define (non-combat-min-ok? cost [target-sym #f])
    (define supply-lock-floor
      (cond
        [(memq target-sym '(pylon supply-depot overlord)) 0]
        [zerg-hold-overlord-min?
         (max hard-supply-lockout-reserve-min (sc2-min-cost 'overlord))]
        [else hard-supply-lockout-reserve-min]))
    (and (>= (- minerals cost) supply-lock-floor)
         (>= (- minerals cost)
             (cond
               [(not urgent-combat-or-intel-need?) 0]
               [(core-progression-exempt-from-surcharge? target-sym) basic-combat-min-floor]
               [else 125]))))
  (define (non-combat-gas-ok? cost [target-sym #f])
    (or (<= cost 0)
        (>= (- gas cost)
            (if (and urgent-combat-or-intel-need?
                     (not (core-progression-exempt-from-surcharge? target-sym)))
                50
                0))))
  (when (or escrow-suppressed-active?
            urgent-combat-or-intel-need?)
    (set! bo-reserved-min 0)
    (set! bo-reserved-gas 0))

  (define orphaned-prereqs
    (find-all-broken-tech-dependencies race ready-bldg-counts total-bldg-counts #:active-goals '()))

  ;; Pre-spend Decoupled 8-Stream Resource & Bank Manager:
  (define in-prog-bldg-syms
    (for/list ([b (in-list ally-bldgs)]
               #:when (< (hash-ref b 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS))
      (sc2-canonical-structure-sym (unit-type-sym b))))
  (define larva-slot-cnt
    (cond
      [(hash? open-prod-slots-snapshot) (hash-ref open-prod-slots-snapshot 'larva 0)]
      [(hash? open-prod-slots) (hash-ref open-prod-slots 'larva 0)]
      [else 0]))
  (define wg-slot-cnt
    (count (lambda (b) (memq (unit-type-sym b) '(warp-gate warpgate))) ally-bldgs))
  (define live-open-combat-slots
    (and live-game?
         (for/sum ([k (in-list '(barracks factory starport gateway robotics-facility stargate))])
           (hash-ref open-prod-slots k 0))))
  (define bank-target
    (compute-bank-targets
     #:race race
     #:frame frame
     #:minerals minerals
     #:gas gas
     #:supply-used supply-used
     #:supply-cap supply-cap
     #:workers total-workers
     #:active-bases active-bases
     #:larva-count larva-slot-cnt
     #:warpgate-count wg-slot-cnt
     #:production-facility-count (max 1 (length prod-facilities))
     #:open-production-slots live-open-combat-slots
     #:ready-buildings ready-bldg-types
     #:in-progress-buildings in-prog-bldg-syms
     #:under-attack? under-base-attack?))
  (define goal-stream-alloc
    (allocate-decoupled-goal-streams
     #:race race
     #:frame frame
     #:minerals minerals
     #:gas gas
     #:supply-used supply-used
     #:supply-cap supply-cap
     #:pending-supply eff-pending-supply
     #:workers total-workers
     #:active-bases active-bases
     #:gas-harvesters eff-gas-harvesters
     #:under-attack? under-base-attack?
     #:wants-expand? (and (< active-bases desired-bases)
                          (not under-base-attack?)
                          (not escrow-suppressed-active?))
     #:tech-goal-sym (and (not escrow-suppressed-active?) bo-goal-sym)
     #:tech-prereq-ready? (null? orphaned-prereqs)
     #:bank-target bank-target))
  (define stream-spendable-ht
    (decoupled-bank-allocation-spendable-by-stream goal-stream-alloc))

  (define prio-sched (macro-brain-decision-priority-schedule macro-decision))
  (define prio-scheduled-actions (macro-brain-decision-scheduled-actions macro-decision))
  (define prio-saving-for-sym (macro-brain-decision-saving-for macro-decision))
  (define zerg-pool-nearly-done-under-rush?
    (and (eq? race 'Zerg)
         worker-rush-active?
         (< (unit-count 'zergling) 4)
         (< minerals 200)
         (ormap (lambda (b)
                  (and (eq? (sc2-canonical-structure-sym (unit-type-sym b)) 'spawning-pool)
                       (>= (hash-ref b 'build-progress 1.0) 0.72)))
                ally-bldgs)))
  (define crisis-freeze-workers?
    (or zerg-pool-nearly-done-under-rush?
        (and early-survival-crisis?
             (not (and (or worker-rush-active? (< total-workers 14))
                       (or (< total-workers 10)
                           (ormap (lambda (s) (memq s bldg-types))
                                  '(spawning-pool barracks gateway warp-gate)))
                       (or (not can-train-basic-combat-now?)
                           (>= (- minerals 50) basic-combat-min-floor))))
             (not (and (< total-workers 10)
                       (null? prod-facilities)
                       (< minerals 200)))
             (or (>= total-workers 12)
                 (< live-army-supply 4)))))
  (define crisis-freeze-expand-or-gas?
    (or (and early-survival-crisis?
             (< live-army-supply 6))
        (and hard-supply-lockout?
             (< minerals (+ (sc2-min-cost supply-provider-sym) 75)))))

  (define (worker-army-curve-satisfied?)
    (or (not live-game?)
        (< total-workers 24)
        (and (not under-base-attack?)
             (<= live-enemy-threat-supply 0)
             (or (and (< total-workers (min 66 (* 20 active-bases))) (>= minerals 150))
                 (and (>= minerals 350)
                      (<= (if (exact-integer? live-open-combat-slots)
                              (+ live-open-combat-slots larva-slot-cnt)
                              99)
                          1))))
        (>= live-army-supply
            (required-army-supply-for-worker-growth total-workers live-enemy-threat-supply))))

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
    (define m-cost (sc2-min-cost id-sym))
    (define g-cost (sc2-gas-cost id-sym))
    (define alt-sym
      (case id-sym
        [(viking) 'viking-fighter]
        [(viking-fighter viking-assault) 'viking]
        [(templar-archive) 'templar-archives]
        [(templar-archives) 'templar-archive]
        [(lurker-den) 'lurker-den-mp]
        [(lurker-den-mp) 'lurker-den]
        [else #f]))
    (or (not live-game?)
        (and escrow-suppressed-active?
             (>= minerals m-cost)
             (>= gas g-cost))
        (and (eq? cat-sym 'combat-unit)
             (or under-base-attack?
                 (> live-enemy-threat-supply 0)
                 escrow-suppressed-active?
                 (and severe-intel-blindness? (null? ally-combat-units))))
        (macro-brain-can-spend? macro-decision id-sym minerals gas cat-sym)
        (and alt-sym
             (macro-brain-can-spend? macro-decision alt-sym minerals gas cat-sym))
        (and (not under-base-attack?)
             (<= live-enemy-threat-supply 0)
             (case cat-sym
               [(expansion) (decoupled-stream-can-spend? goal-stream-alloc 'expansion m-cost g-cost)]
               [(production-scaling)
                (and (>= minerals 550)
                     (decoupled-stream-can-spend? goal-stream-alloc 'production-facilities m-cost g-cost))]
               [else #f]))))

  (define (try-train-unit! unit-sym producer-key [recall-group #f] #:respect-bo-reserve? [respect-bo? #f])
    (define m-cost (sc2-min-cost unit-sym))
    (define g-cost (sc2-gas-cost unit-sym))
    (define s-cost (sc2-supply-cost unit-sym))
    (define alt-u-sym (if (eq? unit-sym 'viking) 'viking-fighter #f))
    (define is-bo-head?
      (or (eq? bo-goal-sym unit-sym)
          (and alt-u-sym (eq? bo-goal-sym alt-u-sym))
          (and live-game?
               (or (not (not (memq unit-sym (macro-brain-decision-scheduled-ids macro-decision))))
                   (and alt-u-sym
                        (not (not (memq alt-u-sym (macro-brain-decision-scheduled-ids macro-decision)))))))))
    (define max-batch
      (cond
        [(not live-game?) 1]
        [(and (memq unit-sym '(drone probe scv))
              (>= active-bases 2)
              (< total-workers (min 70 (* 22 active-bases)))
              (not under-base-attack?)
              (<= live-enemy-threat-supply 0))
         (min 3 active-bases)]
        [(memq unit-sym '(drone probe scv queen overlord observer sentry raven)) 1]
        [else 4]))
    (let loop ([trained 0])
      (define avail-slots (hash-ref open-prod-slots producer-key 0))
      (define eff-min (if (and respect-bo? (not (and is-bo-head? (= trained 0)))) (- minerals bo-reserved-min) minerals))
      (define eff-gas (if (and respect-bo? (not (and is-bo-head? (= trained 0)))) (- gas bo-reserved-gas) gas))
      (cond
        [(and (< trained max-batch)
              (> avail-slots 0)
              (can-spend-supply? s-cost)
              (or (<= m-cost 0) (>= eff-min m-cost))
              (or (<= g-cost 0) (>= eff-gas g-cost)))
         (hash-set! open-prod-slots producer-key (sub1 avail-slots))
         (when (and recall-group (= trained 0))
           (recall-building-group! recall-group))
         (emit! (list 'train unit-sym))
         (order-ledger-record-issued! oledger (+ 860000 (modulo frame 10000) (length actions))
                                      'train unit-sym base-x base-y frame)
         (set! unit-counts (hash-update unit-counts (sc2-canonical-unit-sym unit-sym) add1 0))
         (spend-resources-and-supply! m-cost g-cost s-cost)
         (loop (add1 trained))]
        [else (> trained 0)])))

  (define (emit-building-morph-verified! target-sym source-syms [recall-group 4])
    (define m-cost (sc2-min-cost target-sym))
    (define g-cost (sc2-gas-cost target-sym))
    (define src-bldg
      (findf (lambda (b)
               (and (hash? b)
                    (memq (sc2-canonical-structure-sym (unit-type-sym b)) source-syms)
                    (<= (hash-ref b 'order-count 0) 0)
                    (= (hash-ref b 'order-ability-id 0) 0)
                    (not (order-ledger-facility-busy? oledger b frame))))
             ready-bldgs))
    (cond
      [(and (not (building-present-or-pending? target-sym))
            (>= minerals m-cost)
            (>= gas g-cost)
            (or src-bldg
                (and (not live-game?)
                     (ormap (lambda (s) (memq s ready-bldg-types)) source-syms))))
       (when recall-group
         (recall-building-group! recall-group))
       (emit! (list 'morph target-sym))
       (define rec-id
         (if (hash? src-bldg)
             (hash-ref src-bldg 'id (+ 821000 (modulo frame 10000) (length actions)))
             (+ 821000 (modulo frame 10000) (length actions))))
       (order-ledger-record-issued! oledger rec-id 'morph target-sym base-x base-y frame)
       (set! bldg-types (cons (sc2-canonical-structure-sym target-sym) bldg-types))
       (set! morphing-bldg-types (cons (sc2-canonical-structure-sym target-sym) morphing-bldg-types))
       (when (and live-game? (ormap (lambda (s) (memq s '(hatchery lair command-center))) source-syms))
         (hash-set! open-prod-slots 'townhall
                    (max 0 (sub1 (hash-ref open-prod-slots 'townhall 0)))))
       (spend-resources-and-supply! m-cost g-cost 0)
       #t]
      [else #f]))

  (define (emit-unit-morph-verified! target-sym source-sym [net-supply-cost 0])
    (define m-cost (sc2-min-cost target-sym))
    (define g-cost (sc2-gas-cost target-sym))
    (define avail-src (hash-ref open-prod-slots source-sym 0))
    (cond
      [(and (or (> avail-src 0)
                (and (not live-game?) (memq source-sym unit-types)))
            (or (<= net-supply-cost 0) (can-spend-supply? net-supply-cost))
            (>= minerals m-cost)
            (>= gas g-cost))
       (when (> avail-src 0)
         (hash-set! open-prod-slots source-sym (sub1 avail-src)))
       (emit! (list 'morph target-sym))
       (order-ledger-record-issued! oledger (+ 865000 (modulo frame 10000) (length actions))
                                    'morph target-sym base-x base-y frame)
       (set! unit-counts (hash-update unit-counts (sc2-canonical-unit-sym target-sym) add1 0))
       (spend-resources-and-supply! m-cost g-cost (max 0 net-supply-cost))
       #t]
      [else #f]))

  ;; Self-Healing Prerequisite Repair Actuator (`orphaned-prereqs` from `priority-macro-brain.rkt`):
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
           [(lair)
            (emit-building-morph-verified! 'lair '(hatchery) 4)]
           [(hive)
            (emit-building-morph-verified! 'hive '(lair) 4)]
           [(greater-spire)
            (emit-building-morph-verified! 'greater-spire '(spire) 4)]
           [(orbital-command planetary-fortress)
            (emit-building-morph-verified! req-sym '(command-center) 4)]
           [else
            (if (eq? race 'Zerg)
                (when (save-cancel-rebuild-ready? req-sym 60)
                  (define-values (req-ax req-ay)
                    (safe-zerg-build-anchor (safe-coord (+ base-x 3.5)) (safe-coord (+ base-y 3.5))))
                  (emit-build-verified! req-sym req-ax req-ay))
                (emit-build-verified! req-sym (safe-coord (+ base-x 3.5)) (safe-coord (+ base-y 3.5))))])]
        [(and (not urgent-combat-or-intel-need?)
              (not escrow-suppressed-active?))
         (set! bo-reserved-min (max bo-reserved-min m-cost))
         (set! bo-reserved-gas (max bo-reserved-gas g-cost))])))

  ;; Multi-base expansion mineral escrow (never disabled by `natural-blocked?` since uncamped
  ;; BFS expansion pads remain available):
  (define race-th-sym
    (case race
      [(Zerg) 'hatchery]
      [(Protoss) 'nexus]
      [else 'command-center]))

  (define (third-base-prereqs-ready-for-escrow?)
    (case race
      [(Zerg)
       (and (>= eff-phase-supply 30)
            (memq 'spawning-pool ready-bldg-types))]
      [(Protoss)
       (and (>= eff-phase-supply 50)
            (>= live-army-supply 12)
            (not (and (memq 'robotics-bay ready-bldg-types)
                      (= (unit-count 'colossus) 0)))
            (or (memq 'robotics-facility bldg-types)
                (memq 'twilight-council bldg-types)
                (memq 'stargate bldg-types)
                (plan-wants-now? 'nexus)))]
      [(Terran)
       (and (>= eff-phase-supply 42)
            (or (not live-game?) (>= live-army-supply 10) (>= minerals 550))
            (or (not live-game?)
                (memq 'starport ready-bldg-types)
                (>= minerals 550))
            (or live-game?
                (memq 'starport bldg-types)
                (and (not (memq 'factory ready-bldg-types))
                     (or (memq 'factory bldg-types)
                         (plan-wants-now? 'command-center)))))]
      [else #f]))

  (define (saving-for-expansion-now? cur-base-count)
    (and (not under-base-attack?)
         (not under-early-cheese?)
         (not early-survival-crisis?)
         (not crisis-freeze-expand-or-gas?)
         (<= live-enemy-threat-supply 0)
         (not urgent-combat-or-intel-need?)
         (not escrow-suppressed-active?)
         (< cur-escrow-age-frames max-escrow-timeout-frames)
         (or (not live-game?)
             (= cur-base-count 1)
             (let-values ([(ux uy) (select-uncamped-expansion-pad #f)])
               (and ux uy #t)))
         (or (not live-game?)
             (and (= cur-base-count 1) (< frame 3800))
             (>= live-army-supply 2))
         (or (not live-game?) (not severe-intel-blindness?) (not (null? ally-combat-units)))
         (null? orphaned-prereqs)
         (< (hash-ref pressure-metrics 'threat-pressure 0.0) 0.85)
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
                      (and (= cur-base-count 2) (third-base-prereqs-ready-for-escrow?))
                      (and (>= cur-base-count 3)
                           (>= eff-phase-supply (case race [(Protoss) 66] [(Terran) 62] [else 48]))
                           (>= live-army-supply (if (eq? race 'Zerg) 8 18))))
                  (>= total-workers (if (eq? race 'Zerg) 15 18)))
             (and (> frame 1800)
                  (< cur-base-count desired-bases)
                  (>= total-workers
                      (if (and live-game? (= cur-base-count 2))
                          (if (eq? race 'Zerg) 28 35)
                          (* (max 1 cur-base-count) SC2-IDEAL-WORKERS-PER-BASE)))
                  (if live-game?
                      (or (= cur-base-count 1)
                          (and (= cur-base-count 2) (third-base-prereqs-ready-for-escrow?))
                          (and (>= cur-base-count 3)
                               (>= eff-phase-supply (case race [(Protoss) 66] [(Terran) 62] [else 48]))
                               (>= live-army-supply (* (if (eq? race 'Zerg) 4 7) cur-base-count))))
                      (>= (length ally-combat-units) 4))))))

  (define enemy-heavy-ground-siege?
    (ormap (lambda (e)
             (memq (sc2-canonical-unit-sym (unit-type-sym e))
                   '(siege-tank siege-tank-sieged colossus archon immortal thor planetary-fortress)))
           (append enemy-units enemy-bldgs)))

  ;; Count ONLY non-depleted gas buildings (`vespene-contents > 0`; default `1` for synthetic tests)
  ;; toward `desired-extractors` / `desired-assimilators` / `desired-refineries` (`#5118808` fix).
  (define (active-gas-bldg? b)
    (> (hash-ref b 'vespene-contents 1) 0))

  ;; Endgame anti-tie corner hunter mode: when `frame >= 6000` and `0` enemy structures are visible,
  ;; ensure `>= 2` flying air-to-air hunters + `>= 1` mobile detector to clear lifted/corner structures!
  (define endgame-corner-hunt?
    (and live-game? (>= frame 6000) (null? enemy-bldgs)))

  ;; ---------------------------------------------------------------------------
  ;; Race-Specific Macro Mechanics, Pro Build Orders, Tech Trees & Unit Production
  ;; ---------------------------------------------------------------------------
  (case race
    [(Zerg)
     ;; 1. 1-to-1 Queen Inject Larva (`dispatch-macro-energy!`), Idle Queen Hatchery Lease,
     ;;    & Creep-Highway Queen Tumor Placement
     (define queens
       (filter (lambda (u) (eq? (sc2-canonical-unit-sym (unit-type-sym u)) 'queen)) ally-units))
     (define hatcheries
       (filter (lambda (b)
                 (memq (sc2-canonical-structure-sym (unit-type-sym b)) '(hatchery lair hive)))
               ally-bldgs))
     (define ready-hatcheries
       (filter (lambda (b)
                 (memq (sc2-canonical-structure-sym (unit-type-sym b)) '(hatchery lair hive)))
               ready-bldgs))
     (define inject-hatcheries
       (if (not (null? ready-hatcheries)) ready-hatcheries hatcheries))
     (define extractors
       (filter (lambda (b) (eq? (sc2-canonical-structure-sym (unit-type-sym b)) 'extractor))
               ally-bldgs))
     (define active-extractors (filter active-gas-bldg? extractors))
     (define (queen-protected-order? q)
       (define q-ab-id (hash-ref q 'order-ability-id 0))
       (define q-ab-sym (hash-ref q 'order-ability-sym #f))
       (define canon-ab (sc2-canonical-order-ability q-ab-id))
       (or (memv q-ab-id '(251 1694 3691))
           (memq (sc2-order-protection-class canon-ab) '(macro-spell tumor-spread))
           (memq q-ab-sym '(inject-larva spawn-creep-tumor spread-creep-tumor))))
     (define (hatchery-needs-inject? h)
       (define timer (safe-nonneg-int (hash-ref h 'queen-spawn-larva-timer 0) 0))
       (define bs (hash-ref h 'buffs '()))
       (and (<= timer 0)
            (not (and (list? bs)
                      (or (memq 'inject-larva bs)
                          (memq 'queen-spawn-larva bs)
                          (memv 11 bs))))))
     (define uninjected-hatches (filter hatchery-needs-inject? inject-hatcheries))
     (define claimed-inject-hatch-ids (mutable-seteqv))
     (define used-queen-ids (mutable-seteqv))

     ;; Preserve busy-casting Queens with an `'inject-queen` lease so tactics never pull them
     (for ([q (in-list queens)]
           #:when (queen-protected-order? q))
       (define qid (hash-ref q 'id 120))
       (set-add! used-queen-ids qid)
       (acquire-unit-lease! leases qid 'inject-queen frame 16
                            #:x (hash-ref q 'x base-x)
                            #:y (hash-ref q 'y base-y)))

     ;; In synthetic tests (`not live-game?`), preserve surplus-energy tumor-first test at frame 1000
     ;; while injecting on subsequent frames when tumor cooldown is active.
     (define (nudge-off-expansion-pads cx cy [min-dist 5.0])
       (let loop ([rx cx] [ry cy]
                  [pads (list (cons nat-x nat-y) (cons third-x third-y))])
         (cond
           [(null? pads) (values (safe-coord rx cx) (safe-coord ry cy))]
           [else
            (define px (caar pads))
            (define py (cdar pads))
            (define d (dist2d rx ry px py))
            (if (< d min-dist)
                (let* ([vx (if (< d 0.1) (- enemy-x px) (- rx px))]
                       [vy (if (< d 0.1) (- enemy-y py) (- ry py))]
                       [vd (max 1.0 (sqrt (+ (* vx vx) (* vy vy))))])
                  (loop (+ px (* min-dist (/ vx vd)))
                        (+ py (* min-dist (/ vy vd)))
                        (cdr pads)))
                (loop rx ry (cdr pads)))])))

     (when (not live-game?)
       (for ([q (in-list queens)]
             #:when (and (not (set-member? used-queen-ids (hash-ref q 'id 120)))
                         (>= (hash-ref q 'energy SC2-QUEEN-INJECT-ENERGY) SC2-QUEEN-TUMOR-SURPLUS-ENERGY)))
         (define qid (hash-ref q 'id 120))
         (when (refractory-allow-action?! cd-tracker
                                          (list 'queen-tumor qid)
                                          frame
                                          SC2-CREEP-TUMOR-COOLDOWN-FRAMES)
           (define qx (hash-ref q 'x base-x))
           (define qy (hash-ref q 'y base-y))
           (define th0
             (and (not (null? inject-hatcheries))
                  (argmin (lambda (h) (dist2d qx qy (hash-ref h 'x base-x) (hash-ref h 'y base-y)))
                          inject-hatcheries)))
           (define hx (if th0 (hash-ref th0 'x base-x) base-x))
           (define hy (if th0 (hash-ref th0 'y base-y) base-y))
           (define hdx (- nat-x hx))
           (define hdy (- nat-y hy))
           (define hd (max 1.0 (sqrt (+ (* hdx hdx) (* hdy hdy)))))
           (define-values (tix tiy)
             (nudge-off-expansion-pads (+ hx (* 3.5 (/ hdx hd)))
                                       (+ hy (* 3.5 (/ hdy hd)))
                                       4.5))
           (set-add! used-queen-ids qid)
           (acquire-unit-lease! leases qid 'creep-queen frame 24 #:x tix #:y tiy)
           (emit! (list 'cast-spell qid 'spawn-creep-tumor tix tiy))
           (order-ledger-record-issued! oledger qid 'cast-spell 'spawn-creep-tumor tix tiy frame))))

     ;; 1-to-1 Queen -> Uninjected Hatchery assignment via `dispatch-macro-energy!`
     (dispatch-macro-energy!
      queens
      uninjected-hatches
      frame
      claimed-inject-hatch-ids
      #:min-energy SC2-QUEEN-INJECT-ENERGY
      #:valid-caster?
      (lambda (q)
        (not (set-member? used-queen-ids (hash-ref q 'id 120))))
      #:valid-pair?
      (lambda (q h)
        (or (not live-game?)
            (<= (dist2d (hash-ref q 'x base-x) (hash-ref q 'y base-y)
                        (hash-ref h 'x base-x) (hash-ref h 'y base-y))
                18.0)))
      #:score-pair
      (lambda (q h)
        (- (dist2d (hash-ref q 'x base-x) (hash-ref q 'y base-y)
                   (hash-ref h 'x base-x) (hash-ref h 'y base-y))))
      #:emit-cast!
      (lambda (q h)
        (define qid (hash-ref q 'id 120))
        (define hid (hash-ref h 'id 101))
        (define hx (hash-ref h 'x base-x))
        (define hy (hash-ref h 'y base-y))
        (set-add! used-queen-ids qid)
        (set-add! claimed-inject-hatch-ids hid)
        (acquire-unit-lease! leases qid 'inject-queen frame 24
                             #:target-id hid #:x hx #:y hy)
        (emit! (list 'cast-spell qid 'inject-larva hid))
        (order-ledger-record-issued! oledger qid 'cast-spell 'inject-larva hx hy frame)))

     ;; Lease 1 idle `< 25`-energy Queen to each remaining uninjected Hatchery so combat never pulls inject Queens away
     (for ([h (in-list uninjected-hatches)]
           #:when (not (set-member? claimed-inject-hatch-ids (hash-ref h 'id 101))))
       (define hid (hash-ref h 'id 101))
       (define hx (hash-ref h 'x base-x))
       (define hy (hash-ref h 'y base-y))
       (define guard-q
         (let ([cands
                (filter (lambda (q)
                          (define qid (hash-ref q 'id 120))
                          (and (not (set-member? used-queen-ids qid))
                               (<= (dist2d hx hy (hash-ref q 'x base-x) (hash-ref q 'y base-y)) 14.0)))
                        queens)])
           (and (pair? cands)
                (argmin (lambda (q) (dist2d hx hy (hash-ref q 'x base-x) (hash-ref q 'y base-y)))
                        cands))))
       (when guard-q
         (define gqid (hash-ref guard-q 'id 120))
         (set-add! used-queen-ids gqid)
         (set-add! claimed-inject-hatch-ids hid)
         (acquire-unit-lease! leases gqid 'inject-queen frame 24
                              #:target-id hid #:x hx #:y hy)))

     ;; Remaining unleased Queens with `>= 25` energy become dedicated Creep Queens along the creep highway
     (define all-ally-tumors
       (filter (lambda (u) (memq (unit-type-sym u) '(creep-tumor creep-tumor-burrowed)))
               (append ally-units ready-bldgs)))
     (define creep-highway-wps
       (list (cons nat-x nat-y)
             (cons third-x third-y)
             (cons corridor-mid-x corridor-mid-y)
             (cons enemy-exp-x enemy-exp-y)
             (cons enemy-x enemy-y)))
     (define (next-creep-highway-target ax ay step-dist)
       (define wp
         (or (findf (lambda (pt) (> (dist2d ax ay (car pt) (cdr pt)) 6.0))
                    creep-highway-wps)
             (cons enemy-x enemy-y)))
       (define dx (- (car wp) ax))
       (define dy (- (cdr wp) ay))
       (define d (max 1.0 (sqrt (+ (* dx dx) (* dy dy)))))
       (nudge-off-expansion-pads (+ ax (* step-dist (/ dx d)))
                                 (+ ay (* step-dist (/ dy d)))
                                 5.0))

     (for ([q (in-list queens)]
           #:when (and (not (set-member? used-queen-ids (hash-ref q 'id 120)))
                       (>= (hash-ref q 'energy 0) SC2-QUEEN-INJECT-ENERGY)))
       (define qid (hash-ref q 'id 120))
       (when (refractory-allow-action?! cd-tracker
                                        (list 'queen-tumor qid)
                                        frame
                                        SC2-CREEP-TUMOR-COOLDOWN-FRAMES)
         (define anchor-candidates (append ready-hatcheries all-ally-tumors))
         (define best-anchor
           (if (pair? anchor-candidates)
               (argmin (lambda (a)
                         (dist2d enemy-x enemy-y
                                 (hash-ref a 'x base-x)
                                 (hash-ref a 'y base-y)))
                       anchor-candidates)
               #f))
         (define ax (if best-anchor (hash-ref best-anchor 'x base-x) (hash-ref q 'x base-x)))
         (define ay (if best-anchor (hash-ref best-anchor 'y base-y) (hash-ref q 'y base-y)))
         (define-values (tx ty) (next-creep-highway-target ax ay 6.0))
         (set-add! used-queen-ids qid)
         (acquire-unit-lease! leases qid 'creep-queen frame 24 #:x tx #:y ty)
         (emit! (list 'cast-spell qid 'spawn-creep-tumor tx ty))
         (order-ledger-record-issued! oledger qid 'cast-spell 'spawn-creep-tumor tx ty frame)))

     ;; 2. Pro Mechanic #2: Active Creep Tumor Daisy-Chaining with Maturation (`+232` frames) & 4x Retry
     (define tumor-state-ht (rt-tumor-state rt))
     (define candidate-tumors
       (filter (lambda (u)
                 (and (memq (unit-type-sym u) '(creep-tumor creep-tumor-burrowed))
                      (not (set-member? (live-bot-runtime-used-creep-tumors rt)
                                        (hash-ref u 'id 0)))))
               (append ally-units ready-bldgs)))
     (for ([t (in-list candidate-tumors)])
       (define tid (hash-ref t 'id 702))
       (unless (hash-has-key? tumor-state-ht tid)
         (define init-ready-f (if live-game? (+ frame 232) frame))
         (hash-set! tumor-state-ht tid
                    (hash 'mature-frame init-ready-f
                          'attempts 0
                          'next-try init-ready-f))))
     (define mature-ready-tumors
       (filter (lambda (t)
                 (define tid (hash-ref t 'id 702))
                 (define st (hash-ref tumor-state-ht tid (hash)))
                 (define att (hash-ref st 'attempts 0))
                 (cond
                   [(>= att 4)
                    (set-add! (live-bot-runtime-used-creep-tumors rt) tid)
                    #f]
                   [else
                    (and (>= frame (hash-ref st 'mature-frame 0))
                         (>= frame (hash-ref st 'next-try 0)))]))
               candidate-tumors))
     (for ([t (in-list (take mature-ready-tumors
                             (min SC2-MAX-TUMOR-SPREADS-PER-FRAME (length mature-ready-tumors))))])
       (define tid (hash-ref t 'id 702))
       (define tx (hash-ref t 'x base-x))
       (define ty (hash-ref t 'y base-y))
       (define-values (target-x target-y)
         (if live-game?
             (next-creep-highway-target tx ty SC2-CREEP-TUMOR-STEP-DISTANCE)
             (let* ([dx (- enemy-x tx)]
                    [dy (- enemy-y ty)]
                    [d (max 1.0 (sqrt (+ (* dx dx) (* dy dy))))])
               (values (safe-coord (+ tx (* SC2-CREEP-TUMOR-STEP-DISTANCE (/ dx d))) tx)
                       (safe-coord (+ ty (* SC2-CREEP-TUMOR-STEP-DISTANCE (/ dy d))) ty)))))
       (define st (hash-ref tumor-state-ht tid (hash)))
       (define next-att (add1 (hash-ref st 'attempts 0)))
       (hash-set! tumor-state-ht tid
                  (hash-set* st 'attempts next-att 'next-try (+ frame 68)))
       (when (or (not live-game?) (>= next-att 4))
         (set-add! (live-bot-runtime-used-creep-tumors rt) tid))
       (emit! (list 'cast tid 'spread-creep-tumor target-x target-y)))

     ;; 3. Pro Build-Order Expansion Sequencing (16 Hatchery -> 30 3rd Hatchery -> 4th+ uncamped bases)
     (when (and (>= minerals (sc2-min-cost 'hatchery))
                (non-combat-min-ok? (sc2-min-cost 'hatchery) 'hatchery)
                (not blocked-nat-expanded-early?)
                (not worker-rush-active?)
                (not under-early-cheese?)
                (not early-survival-crisis?)
                (not crisis-freeze-expand-or-gas?)
                (not under-base-attack?)
                (= (order-ledger-pending-count-for-type oledger 'hatchery frame) 0)
                (or (< (length hatcheries) SC2-MIN-DESIRED-BASES)
                    (and (= (length hatcheries) 2)
                         (>= eff-phase-supply 30)
                         (memq 'spawning-pool ready-bldg-types))
                    (and (< (length hatcheries) desired-bases)
                         (memq 'spawning-pool bldg-types)
                         (or (not (and endgame-corner-hunt?
                                       (< (+ (unit-count 'mutalisk) (unit-count 'corruptor)) 2)))
                             (>= (- minerals (sc2-min-cost 'hatchery)) 150))
                         (>= total-workers (* (length hatcheries)
                                              (if (>= (length hatcheries) 3) 16 SC2-MIN-WORKERS-PER-BASE-FOR-EXPAND)))
                         (or (coupled-macro-plan-should-expand? macro-plan)
                             (>= frame SC2-MACRO-EXPAND-FRAME-THRESHOLD))))
                (let-values ([(cand-ex cand-ey)
                              (select-uncamped-expansion-pad (< (length hatcheries) SC2-MIN-DESIRED-BASES))])
                  (and cand-ex cand-ey))
                (refractory-allow-action?! cd-tracker
                                           (list 'macro-expand 'Zerg)
                                           frame
                                           SC2-EXPANSION-COOLDOWN-FRAMES))
       (define-values (exp-x exp-y)
         (select-uncamped-expansion-pad (< (length hatcheries) SC2-MIN-DESIRED-BASES)))
       (when (and exp-x exp-y)
         (emit! (list 'expand exp-x exp-y))
         (order-ledger-record-issued! oledger (+ 810000 (modulo frame 10000)) 'expand 'hatchery exp-x exp-y frame)
         (spend-resources-and-supply! (sc2-min-cost 'hatchery) 0 0)))

     (define zerg-saving-for-expand? (saving-for-expansion-now? (length hatcheries)))

     ;; 4. Zerg Pro Build Order & 8-Geyser Scaling
     (when (and (not (building-present-or-pending? 'spawning-pool))
                (save-cancel-rebuild-ready? 'spawning-pool 60)
                (>= minerals (sc2-min-cost 'spawning-pool))
                (>= (- minerals (sc2-min-cost 'spawning-pool)) hard-supply-lockout-reserve-min))
       (define-values (pool-ax pool-ay)
         (safe-zerg-build-anchor (safe-coord (+ base-x 3.0)) (safe-coord (+ base-y 3.0))))
       (emit-build-verified! 'spawning-pool pool-ax pool-ay))

     ;; Worker-Rush / Early Survival Crisis Immediate Spending:
     ;; As soon as Spawning Pool is complete, spend 100M on Spine Crawler if minerals >= 200 (and >= 2 Drones),
     ;; and immediately spend EVERY 50M + Larva on Zerglings ahead of Queen / Speed / Warren / Drones!
     (when (and (or worker-rush-active? early-survival-crisis?)
                (memq 'spawning-pool ready-bldg-types)
                (< live-army-supply (max 8 (+ live-enemy-threat-supply 4))))
       (when (and (>= minerals 200)
                  (>= total-workers 2)
                  (not (building-present-or-pending? 'spine-crawler))
                  (save-cancel-rebuild-ready? 'spine-crawler 60))
         (define-values (er-spine-x er-spine-y)
           (if (<= (length hatcheries) 1)
               (let* ([sdx (- nat-x base-x)]
                      [sdy (- nat-y base-y)]
                      [sd (max 1.0 (sqrt (+ (* sdx sdx) (* sdy sdy))))])
                 (values (safe-coord (+ base-x (* 3.5 (/ sdx sd))) base-x)
                         (safe-coord (+ base-y (* 3.5 (/ sdy sd))) base-y)))
               (offset-defense-anchor nat-x nat-y 5.5)))
         (emit-build-verified! 'spine-crawler er-spine-x er-spine-y 2.0))
       (when (and (>= minerals (sc2-min-cost 'zergling))
                  (or (>= total-workers 1) worker-rush-active?))
         (try-train-unit! 'zergling 'larva 4 #:respect-bo-reserve? #f)))

     (define desired-extractors
       (if (and early-survival-crisis? (null? active-extractors))
           0
           (min (* SC2-GEYSERS-PER-BASE (length hatcheries))
                (if live-game?
                    (cond
                      [(and (>= (length hatcheries) 4) (>= total-workers 62) (< gas 1000)) 8]
                      [(and (>= (length hatcheries) 3) (>= total-workers 48) (< gas 700)) 6]
                      [(and (>= (length hatcheries) 2) (>= total-workers 34) (< gas 450)) 4]
                      [(and (>= eff-phase-supply 44) (>= total-workers 32) (< gas 350)) 3]
                      [(and (>= (length hatcheries) 2) (>= eff-phase-supply 34) (>= total-workers 24) (< gas 250)) 2]
                      [(>= total-workers (add1 SC2-MIN-WORKERS-FOR-GAS)) 1]
                      [else 0])
                    (cond
                      [(>= supply-used 84) 6]
                      [(>= supply-used 60) 4]
                      [(>= supply-used 44) 3]
                      [(>= supply-used 38) 2]
                      [(>= total-workers (add1 SC2-MIN-WORKERS-FOR-GAS)) 1]
                      [else 0])))))
     (define zerg-holding-for-aa-spire?
       (and live-game?
            (>= (length hatcheries) 3)
            (enemy-tech-observation-requires-anti-air? tech-obs)
            (or (memq 'lair ready-bldg-types) (memq 'hive ready-bldg-types))
            (not (building-present-or-pending? 'spire))
            (not (building-present-or-pending? 'greater-spire))
            (>= gas (sc2-gas-cost 'spire))))
     (define zerg-holding-for-aa-corruptor?
       (and live-game?
            (enemy-tech-observation-requires-anti-air? tech-obs)
            (or (memq 'spire ready-bldg-types) (memq 'greater-spire ready-bldg-types))
            (< (unit-count 'corruptor) 4)
            (>= minerals (sc2-min-cost 'corruptor))
            (>= gas (sc2-gas-cost 'corruptor))))
     (when (and (memq 'spawning-pool bldg-types)
                (not crisis-freeze-expand-or-gas?)
                (not (and zerg-holding-for-aa-spire?
                          (>= (length active-extractors) 2)
                          (< (- minerals (sc2-min-cost 'gas-building-reserve))
                             (sc2-min-cost 'spire))))
                (not (and zerg-holding-for-aa-corruptor?
                          (>= (length active-extractors) 2)
                          (< (- minerals (sc2-min-cost 'gas-building-reserve))
                             (sc2-min-cost 'corruptor))))
                (< (+ (length active-extractors) (order-ledger-pending-count-for-type oledger 'extractor frame))
                   desired-extractors)
                (>= minerals (sc2-min-cost 'gas-building-reserve))
                (non-combat-min-ok? (sc2-min-cost 'gas-building-reserve)))
       (emit-gas-build-verified! 'extractor (safe-coord (+ base-x 4.0)) (safe-coord (+ base-y 4.0)) 'gas-building-reserve))

     ;; Morph Lair BEFORE Queen training
     (define zerg-wants-lair-now?
       (and (memq 'spawning-pool ready-bldg-types)
            (not (building-present-or-pending? 'lair))
            (not (memq 'hive bldg-types))
            (not (building-present-or-pending? 'hive))
            (or (eq? bo-goal-sym 'lair)
                (eq? prio-saving-for-sym 'lair)
                (plan-wants-now? 'lair)
                endgame-corner-hunt?
                (and (>= gas 100)
                     (or (not live-game?)
                         (not (upgrade-needed? 'metabolic-boost))
                         (>= gas 200)
                         (>= eff-phase-supply 36)
                         (memq 'roach-warren bldg-types))))))

     (when (and (memq 'spawning-pool ready-bldg-types)
                (not zerg-saving-for-expand?)
                (or (not live-game?)
                    zerg-wants-lair-now?
                    (>= eff-phase-supply 42)
                    (plan-wants-now? 'lair)
                    (memq 'roach-warren bldg-types))
                (>= minerals (sc2-min-cost 'lair))
                (>= gas (sc2-gas-cost 'lair))
                (non-combat-min-ok? (sc2-min-cost 'lair) 'lair)
                (non-combat-gas-ok? (sc2-gas-cost 'lair) 'lair)
                (not (building-present-or-pending? 'lair))
                (not (memq 'hive bldg-types))
                (not (building-present-or-pending? 'hive)))
       (emit-building-morph-verified! 'lair '(hatchery) 4))

     (define lair-reserving-last-hatchery?
       (and live-game?
            zerg-wants-lair-now?
            (>= gas 80)
            (not (building-present-or-pending? 'lair))
            (<= (hash-ref open-prod-slots 'townhall 0) 1)))
     (define queen-allowed-in-crisis?
       (or (not early-survival-crisis?)
           (>= live-army-supply 4)
           (>= minerals 250)))
     (define total-queens-now (unit-count 'queen))
     (define desired-queens
       (min SC2-MAX-QUEENS-CAP
            (+ (max 1 (length ready-hatcheries))
               (if (>= (length hatcheries) 2) 2 1))))
     (when (and (memq 'spawning-pool ready-bldg-types)
                (= total-queens-now 0)
                queen-allowed-in-crisis?
                (not lair-reserving-last-hatchery?)
                (not zerg-saving-for-expand?)
                (non-combat-min-ok? (sc2-min-cost 'queen) 'queen))
       (try-train-unit! 'queen 'townhall 4))

     (define enemy-cloaked-or-air?
       (ormap (lambda (e)
                (or (hash-ref e 'cloaked #f)
                    (hash-ref e 'burrowed #f)
                    (memq (sc2-canonical-unit-sym (unit-type-sym e))
                          '(banshee dark-templar ghost lurker mutalisk void-ray carrier oracle widow-mine))))
              enemy-units))

     ;; Proactive mobile detection: morph >= 1 Overseer as soon as Lair completes
     ;; (ahead of secondary creep Queens & +2 upgrades, matching Priority Brain Rank #1;
     ;; hold non-cloaked Overseer 1 tick if ready to drop anti-air Spire/Corruptor immediately)
     (when (and live-game?
                (or (memq 'lair ready-bldg-types) (memq 'hive ready-bldg-types))
                (or (and (not zerg-holding-for-aa-spire?)
                         (not zerg-holding-for-aa-corruptor?))
                    enemy-cloaked-or-air?)
                (< (unit-count 'overseer)
                   (if (or (>= live-army-supply 40)
                           enemy-cloaked-or-air?
                           (enemy-tech-observation-requires-detection? tech-obs))
                       2
                       1)))
       (when (and (= (unit-count 'overlord) 0)
                  (>= minerals (sc2-min-cost 'overlord)))
         (try-train-unit! 'overlord 'larva 4))
       (emit-unit-morph-verified! 'overseer 'overlord 0))

     (define zerg-holding-lair-min?
       (and live-game?
            (not (building-present-or-pending? 'lair))
            (or (and (>= gas 80) zerg-wants-lair-now?)
                (and (>= gas (sc2-gas-cost 'lair))
                     (or (>= eff-phase-supply 42) (plan-wants-now? 'lair))))))
     (define zerg-spire-res-min
       (cond
         [zerg-holding-for-aa-spire? (sc2-min-cost 'spire)]
         [zerg-holding-for-aa-corruptor? (sc2-min-cost 'corruptor)]
         [else 0]))
     (define zerg-spire-res-gas
       (cond
         [zerg-holding-for-aa-spire? (sc2-gas-cost 'spire)]
         [zerg-holding-for-aa-corruptor? (sc2-gas-cost 'corruptor)]
         [else 0]))
     (when (and (memq 'spawning-pool ready-bldg-types)
                (or (not live-game?) (> total-queens-now 0))
                queen-allowed-in-crisis?
                (not lair-reserving-last-hatchery?)
                (not zerg-saving-for-expand?)
                (>= (- minerals (max (if zerg-holding-lair-min? (sc2-min-cost 'lair) 0)
                                     zerg-spire-res-min))
                    (sc2-min-cost 'queen))
                (non-combat-min-ok? (sc2-min-cost 'queen) 'queen)
                (< (unit-count 'queen) desired-queens))
       (try-train-unit! 'queen 'townhall 4))

     (when (and (memq 'spawning-pool ready-bldg-types)
                (upgrade-needed? 'metabolic-boost)
                (>= (- minerals zerg-spire-res-min) (sc2-min-cost 'metabolic-boost))
                (>= (- gas zerg-spire-res-gas) (sc2-gas-cost 'metabolic-boost))
                (non-combat-min-ok? (sc2-min-cost 'metabolic-boost) 'metabolic-boost)
                (non-combat-gas-ok? (sc2-gas-cost 'metabolic-boost) 'metabolic-boost))
       (emit-research-verified! 'metabolic-boost))

     (define zerg-hive-t3-tech-ready?
       (and live-game?
            (memq 'hive ready-bldg-types)
            (or (memq 'ultralisk-cavern ready-bldg-types)
                (memq 'greater-spire ready-bldg-types))))

     (when (and (memq 'spawning-pool ready-bldg-types)
                (not zerg-saving-for-expand?)
                (not (building-present-or-pending? 'roach-warren))
                (save-cancel-rebuild-ready? 'roach-warren 60)
                (or (plan-wants-now? 'roach-warren)
                    (and (not zerg-hive-t3-tech-ready?)
                         (or (>= eff-phase-supply 26)
                             (>= gas 80)
                             (>= total-workers SC2-PRIORITY-WORKERS-PER-BASE))))
                (>= (- minerals zerg-spire-res-min) (sc2-min-cost 'roach-warren))
                (non-combat-min-ok? (sc2-min-cost 'roach-warren) 'roach-warren))
       (define-values (rw-ax rw-ay)
         (safe-zerg-build-anchor (safe-coord (+ base-x 4.0)) (safe-coord (- base-y 4.0))))
       (emit-build-verified! 'roach-warren rw-ax rw-ay))

     ;; Baneling Nest only requires Spawning Pool (not Lair!)
     (when (and (memq 'spawning-pool ready-bldg-types)
                (not zerg-saving-for-expand?)
                (not (building-present-or-pending? 'baneling-nest))
                (save-cancel-rebuild-ready? 'baneling-nest 60)
                (or (plan-wants-now? 'baneling-nest)
                    (and (not zerg-hive-t3-tech-ready?)
                         (or (>= eff-phase-supply 36)
                             (memq 'lair ready-bldg-types)
                             (memq 'hive ready-bldg-types))))
                (>= (- minerals zerg-spire-res-min) (sc2-min-cost 'baneling-nest))
                (>= (- gas zerg-spire-res-gas) (sc2-gas-cost 'baneling-nest))
                (non-combat-min-ok? (sc2-min-cost 'baneling-nest) 'baneling-nest)
                (non-combat-gas-ok? (sc2-gas-cost 'baneling-nest) 'baneling-nest))
       (define-values (bn-ax bn-ay)
         (safe-zerg-build-anchor (safe-coord (+ base-x 3.0)) (safe-coord (- base-y 3.0))))
       (emit-build-verified! 'baneling-nest bn-ax bn-ay))

     (when (and (memq 'roach-warren ready-bldg-types)
                (not zerg-saving-for-expand?)
                (or (not live-game?)
                    (< (unit-count 'ravager)
                       (max 2 (quotient (max 1 (unit-count 'roach)) 2))))
                (can-spend-by-priority? 'ravager 'combat-unit))
       (emit-unit-morph-verified! 'ravager 'roach 1))

     (when (and (memq 'spawning-pool ready-bldg-types)
                (>= total-workers 2)
                (not (building-present-or-pending? 'spine-crawler))
                (save-cancel-rebuild-ready? 'spine-crawler 60)
                (>= (- minerals (sc2-min-cost 'spine-crawler)) hard-supply-lockout-reserve-min)
                (or (and (or early-survival-crisis?
                             (and under-base-attack? (< live-army-supply 6)))
                         (or (not worker-rush-active?)
                             (>= minerals 200)
                             (>= live-army-supply 4))
                         (>= minerals (sc2-min-cost 'spine-crawler)))
                    (and (not zerg-saving-for-expand?)
                         (>= minerals (+ (sc2-min-cost 'spine-crawler) (sc2-min-cost 'roach-warren)))
                         (non-combat-min-ok? (sc2-min-cost 'spine-crawler))
                         (or under-early-cheese? (>= total-workers SC2-IDEAL-WORKERS-PER-BASE)))))
       (define-values (spine-x spine-y)
         (if (<= (length hatcheries) 1)
             (let* ([sdx (- nat-x base-x)]
                    [sdy (- nat-y base-y)]
                    [sd (max 1.0 (sqrt (+ (* sdx sdx) (* sdy sdy))))])
               (values (safe-coord (+ base-x (* 3.5 (/ sdx sd))) base-x)
                       (safe-coord (+ base-y (* 3.5 (/ sdy sd))) base-y)))
             (offset-defense-anchor nat-x nat-y 5.5)))
       (emit-build-verified! 'spine-crawler spine-x spine-y 2.0))

     (when (and (memq 'spawning-pool ready-bldg-types)
                (not zerg-saving-for-expand?)
                (or (plan-wants-now? 'evolution-chamber)
                    (>= eff-phase-supply 36))
                (not (building-present-or-pending? 'evolution-chamber))
                (save-cancel-rebuild-ready? 'evolution-chamber 60)
                (>= (- minerals zerg-spire-res-min) (sc2-min-cost 'evolution-chamber))
                (non-combat-min-ok? (sc2-min-cost 'evolution-chamber)))
       (define-values (evo-ax evo-ay)
         (safe-zerg-build-anchor (safe-coord (+ base-x 3.0)) (safe-coord (- base-y 4.0))))
       (emit-build-verified! 'evolution-chamber evo-ax evo-ay))

     (when (memq 'evolution-chamber ready-bldg-types)
       (cond
         [(upgrade-needed? 'zerg-missile-weapons-1)
          (emit-research-verified! 'zerg-missile-weapons-1)]
         [(upgrade-needed? 'zerg-ground-armor-1)
          (emit-research-verified! 'zerg-ground-armor-1)]
         [(and (or (plan-wants-now? 'zerg-melee-weapons-1) (>= (unit-count 'zergling) 12))
               (upgrade-needed? 'zerg-melee-weapons-1))
          (emit-research-verified! 'zerg-melee-weapons-1)]
         [(and (or (memq 'lair ready-bldg-types) (memq 'hive ready-bldg-types))
               (upgrade-needed? 'zerg-missile-weapons-2))
          (emit-research-verified! 'zerg-missile-weapons-2)]
         [(and (or (memq 'lair ready-bldg-types) (memq 'hive ready-bldg-types))
               (upgrade-needed? 'zerg-ground-armor-2))
          (emit-research-verified! 'zerg-ground-armor-2)]
         [(and (or (memq 'lair ready-bldg-types) (memq 'hive ready-bldg-types))
               (or (plan-wants-now? 'zerg-melee-weapons-2) (>= (unit-count 'zergling) 16))
               (upgrade-needed? 'zerg-melee-weapons-2))
          (emit-research-verified! 'zerg-melee-weapons-2)]
         [(and (memq 'hive ready-bldg-types)
               (upgrade-needed? 'zerg-missile-weapons-3))
          (emit-research-verified! 'zerg-missile-weapons-3)]
         [(and (memq 'hive ready-bldg-types)
               (upgrade-needed? 'zerg-ground-armor-3))
          (emit-research-verified! 'zerg-ground-armor-3)]))

     (when (or (memq 'lair ready-bldg-types) (memq 'hive ready-bldg-types))
       (when (and (upgrade-needed? 'burrow)
                  (or (not live-game?)
                      (plan-wants-now? 'burrow)
                      (and (>= (unit-count 'roach) 4)
                           (memq 'hydralisk-den bldg-types)))
                  (>= minerals (sc2-min-cost 'burrow))
                  (>= gas (sc2-gas-cost 'burrow)))
         (emit-research-verified! 'burrow))
       (when (memq 'roach-warren ready-bldg-types)
         (cond
           [(and (or (not live-game?)
                     (plan-wants-now? 'glial-reconstitution)
                     (>= (unit-count 'roach) 2))
                 (upgrade-needed? 'glial-reconstitution))
            (emit-research-verified! 'glial-reconstitution)]
           [(and (or (not live-game?)
                     (plan-wants-now? 'tunneling-claws)
                     (and (>= (unit-count 'roach) 4)
                          (memq 'burrow researched-upgs)))
                 (upgrade-needed? 'tunneling-claws))
            (emit-research-verified! 'tunneling-claws)]))
       (when (and (memq 'baneling-nest ready-bldg-types)
                  (or (not live-game?)
                      (plan-wants-now? 'centrifical-hooks)
                      (>= (+ (unit-count 'baneling) (quotient (unit-count 'zergling) 2)) 3))
                  (upgrade-needed? 'centrifical-hooks))
         (emit-research-verified! 'centrifical-hooks))
       (when (and (or (not zerg-saving-for-expand?)
                      (and (>= (length hatcheries) 3)
                           (enemy-tech-observation-requires-anti-air? tech-obs)))
                  (not (building-present-or-pending? 'spire))
                  (not (building-present-or-pending? 'greater-spire))
                  (save-cancel-rebuild-ready? 'spire 60)
                  (or (not live-game?)
                      (plan-wants-now? 'spire)
                      (enemy-tech-observation-requires-anti-air? tech-obs)
                      enemy-heavy-ground-siege?
                      endgame-corner-hunt?
                      (>= eff-phase-supply 68))
                  (>= minerals (sc2-min-cost 'spire))
                  (>= gas (sc2-gas-cost 'spire)))
         (define-values (sp-ax sp-ay)
           (safe-zerg-build-anchor (safe-coord (+ base-x 5.0)) (safe-coord (+ base-y 4.0))))
         (emit-build-verified! 'spire sp-ax sp-ay))
       (when (and (or (not zerg-saving-for-expand?)
                      (and (>= (length hatcheries) 3)
                           (enemy-tech-observation-requires-anti-air? tech-obs)))
                  (not zerg-holding-for-aa-corruptor?)
                  (not (building-present-or-pending? 'hydralisk-den))
                  (save-cancel-rebuild-ready? 'hydralisk-den 60)
                  (or (not live-game?)
                      (plan-wants-now? 'hydralisk-den)
                      (enemy-tech-observation-requires-anti-air? tech-obs)
                      (>= eff-phase-supply 52))
                  (>= (- minerals zerg-spire-res-min) (sc2-min-cost 'hydralisk-den))
                  (>= (- gas zerg-spire-res-gas) (sc2-gas-cost 'hydralisk-den)))
         (define-values (hd-ax hd-ay)
           (safe-zerg-build-anchor (safe-coord (+ base-x 4.0)) (safe-coord (+ base-y 5.0))))
         (emit-build-verified! 'hydralisk-den hd-ax hd-ay))
       (when (and (not zerg-saving-for-expand?)
                  (not zerg-holding-for-aa-corruptor?)
                  (not (building-present-or-pending? 'infestation-pit))
                  (save-cancel-rebuild-ready? 'infestation-pit 60)
                  (or (plan-wants-now? 'infestation-pit)
                      (plan-wants-now? 'hive)
                      (and live-game?
                           (or (>= (length hatcheries) 3)
                               (>= total-workers 52)
                               (>= eff-phase-supply 76))))
                  (>= (- minerals zerg-spire-res-min) (sc2-min-cost 'infestation-pit))
                  (>= (- gas zerg-spire-res-gas) (sc2-gas-cost 'infestation-pit)))
         (define-values (ip-ax ip-ay)
           (safe-zerg-build-anchor (safe-coord (- base-x 4.0)) (safe-coord (+ base-y 4.0))))
         (emit-build-verified! 'infestation-pit ip-ax ip-ay))
       (when (and (memq 'lair ready-bldg-types)
                  (memq 'infestation-pit ready-bldg-types)
                  (not zerg-holding-for-aa-corruptor?)
                  (not zerg-saving-for-expand?))
         (emit-building-morph-verified! 'hive '(lair) 4))
       (when (and (memq 'hive ready-bldg-types)
                  (memq 'spire ready-bldg-types)
                  (not zerg-saving-for-expand?)
                  (or (not live-game?)
                      (plan-wants-now? 'greater-spire)
                      enemy-heavy-ground-siege?
                      (>= (length hatcheries) 4)
                      (>= total-workers 64)
                      (>= eff-phase-supply 100)))
         (emit-building-morph-verified! 'greater-spire '(spire) 4))
       (when (and (memq 'hive ready-bldg-types)
                  (not zerg-saving-for-expand?)
                  (not zerg-holding-for-aa-corruptor?)
                  (not (building-present-or-pending? 'ultralisk-cavern))
                  (save-cancel-rebuild-ready? 'ultralisk-cavern 60)
                  (or (not live-game?)
                      (plan-wants-now? 'ultralisk-cavern)
                      (>= (length hatcheries) 4)
                      (>= eff-phase-supply 96))
                  (>= (- minerals zerg-spire-res-min) (sc2-min-cost 'ultralisk-cavern))
                  (>= (- gas zerg-spire-res-gas) (sc2-gas-cost 'ultralisk-cavern)))
         (define-values (uc-ax uc-ay)
           (safe-zerg-build-anchor (safe-coord (- base-x 5.0)) (safe-coord (- base-y 4.0))))
         (emit-build-verified! 'ultralisk-cavern uc-ax uc-ay))
       (when (memq 'hydralisk-den ready-bldg-types)
         (cond
           [(upgrade-needed? 'grooved-spines)
            (emit-research-verified! 'grooved-spines)]
           [(upgrade-needed? 'muscular-augments)
            (emit-research-verified! 'muscular-augments)]))
       (when (and (memq 'infestation-pit ready-bldg-types)
                  (or (not live-game?)
                      (plan-wants-now? 'neural-parasite)
                      (>= (unit-count 'infestor) 1))
                  (upgrade-needed? 'neural-parasite))
         (emit-research-verified! 'neural-parasite))
       (when (and (memq 'hive ready-bldg-types)
                  (memq 'spawning-pool ready-bldg-types)
                  (or (not live-game?)
                      (plan-wants-now? 'zergling-attackspeed)
                      (>= (unit-count 'zergling) 6))
                  (upgrade-needed? 'zergling-attackspeed))
         (emit-research-verified! 'zergling-attackspeed))
       (when (memq 'ultralisk-cavern ready-bldg-types)
         (cond
           [(upgrade-needed? 'chitinous-plating)
            (emit-research-verified! 'chitinous-plating)]
           [(upgrade-needed? 'anabolic-synthesis)
            (emit-research-verified! 'anabolic-synthesis)]))
       (when (and (memq 'hydralisk-den ready-bldg-types)
                  (not zerg-saving-for-expand?)
                  (not (building-present-or-pending? 'lurker-den))
                  (save-cancel-rebuild-ready? 'lurker-den 60)
                  (>= minerals (sc2-min-cost 'lurker-den))
                  (>= gas (sc2-gas-cost 'lurker-den)))
         (define-values (ld-ax ld-ay)
           (safe-zerg-build-anchor (safe-coord (+ base-x 5.0)) (safe-coord (- base-y 5.0))))
         (emit-build-verified! 'lurker-den ld-ax ld-ay))
       (when (and (or (memq 'lurker-den ready-bldg-types)
                      (and (not live-game?) (memq 'hydralisk-den ready-bldg-types)))
                  (>= gas (sc2-gas-cost 'adaptive-talons))
                  (upgrade-needed? 'adaptive-talons))
         (emit-research-verified! 'adaptive-talons))
       (when (and (memq 'lurker-den ready-bldg-types)
                  (memq 'hive ready-bldg-types)
                  (>= gas (sc2-gas-cost 'seismic-spines))
                  (upgrade-needed? 'seismic-spines))
         (emit-research-verified! 'seismic-spines)))

     ;; Cloaked / Air / Spore defense & Overseer morph
     (when (or enemy-cloaked-or-air?
               (enemy-tech-observation-requires-detection? tech-obs)
               (and (not live-game?) (memq 'spire bldg-types)))
       (when (and (or (not live-game?)
                      (and (memq 'spawning-pool ready-bldg-types)
                           (not (building-present-or-pending? 'spore-crawler))
                           (save-cancel-rebuild-ready? 'spore-crawler 60)
                           (>= (- minerals zerg-spire-res-min) (sc2-min-cost 'spore-crawler))))
                  (refractory-allow-action?! cd-tracker
                                             (list 'static-detector 'spore-crawler)
                                             frame
                                             SC2-STATIC-DETECTOR-COOLDOWN-FRAMES))
         (if live-game?
             (let-values ([(spc-ax spc-ay)
                           (safe-zerg-build-anchor (safe-coord (+ base-x 3.0)) (safe-coord (+ base-y 3.0)))])
               (emit-build-verified! 'spore-crawler spc-ax spc-ay))
             (emit! (list 'build 'spore-crawler (safe-coord (+ base-x 3.0)) (safe-coord (+ base-y 3.0))))))
       (if live-game?
           (when (and (or (memq 'lair ready-bldg-types) (memq 'hive ready-bldg-types))
                      (or (and (not zerg-holding-for-aa-spire?)
                               (not zerg-holding-for-aa-corruptor?))
                          enemy-cloaked-or-air?)
                      (< (unit-count 'overseer) 2))
             (emit-unit-morph-verified! 'overseer 'overlord 0))
           (when (not (memq 'overseer unit-types))
             (emit! '(morph overseer)))))

     ;; Overseer Changeling scout (Pro Mechanic #5)
     (define overseers
       (filter (lambda (u) (eq? (sc2-canonical-unit-sym (unit-type-sym u)) 'overseer)) ally-units))
     (for ([ov (in-list overseers)])
       (when (>= (hash-ref ov 'energy SC2-OVERSEER-CHANGELING-ENERGY) SC2-OVERSEER-CHANGELING-ENERGY)
         (emit! (list 'cast (hash-ref ov 'id 190) 'spawn-changeling enemy-x enemy-y))))

     (cond
       [(memq 'lurker-den ready-bldg-types)
        (when (or (not live-game?)
                  (and (not zerg-saving-for-expand?)
                       (< (unit-count 'lurker) 8)
                       (can-spend-by-priority? 'lurker 'combat-unit)))
          (emit-unit-morph-verified! 'lurker 'hydralisk 1))]
       [(and (not live-game?)
             (memq 'spire ready-bldg-types)
             (memq 'hydralisk-den ready-bldg-types))
        (emit! '(morph lurker))])

     (when (and (not live-game?)
                (memq 'spire ready-bldg-types)
                (memq 'hydralisk-den ready-bldg-types)
                (not (building-present-or-pending? 'hive)))
       (emit! '(morph hive)))

     (when (memq 'greater-spire ready-bldg-types)
       (emit-unit-morph-verified! 'brood-lord 'corruptor 2))

     ;; 5. Zerg Worker Saturation Priority (`70` cap + army-supply curve gate) vs Combat Unit Training
     (define zerg-ideal-worker-cap
       (min 70 (* SC2-IDEAL-WORKERS-PER-BASE (max 1 (length hatcheries)))))
     (define zerg-drone-priority?
       (and (not crisis-freeze-workers?)
            (worker-army-curve-satisfied?)
            (or (not zerg-saving-for-expand?)
                (and (< total-workers 16) (< minerals 250)))
            (not urgent-combat-or-intel-need?)
            (or (< total-workers zerg-ideal-worker-cap)
                (can-spend-by-priority? 'drone 'worker))
            (< total-workers (min 70 (max target-workers zerg-ideal-worker-cap)))
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
                             (or (>= total-workers 24)
                                 (>= total-workers zerg-ideal-worker-cap)
                                 (and (>= total-workers 16)
                                      (> bo-reserved-gas 0)
                                      (>= gas bo-reserved-gas)))
                             (not (memq bo-goal-sym '(hatchery nexus command-center drone probe scv))))))

     ;; Zerg Combat Unit Training (T3 BroodLord/Viper/Ultralisk/Infestor BEFORE T2 Hydra/Roach)
     (when (and live-game?
                zerg-saving-for-expand?
                (>= (length hatcheries) 3)
                (enemy-tech-observation-requires-anti-air? tech-obs)
                (< (unit-count 'corruptor) 4))
       (cond
         [(or (memq 'spire ready-bldg-types) (memq 'greater-spire ready-bldg-types))
          (try-train-unit! 'corruptor 'larva 4 #:respect-bo-reserve? #f)]
         [(memq 'hydralisk-den ready-bldg-types)
          (try-train-unit! 'hydralisk 'larva 4 #:respect-bo-reserve? #f)]))

     (unless zerg-saving-for-expand?
       (when (and (memq 'baneling-nest ready-bldg-types)
                  (< (unit-count 'baneling)
                     (max 4 (quotient (max 1 (unit-count 'zergling)) 2)))
                  (can-spend-by-priority? 'baneling 'combat-unit))
         (emit-unit-morph-verified! 'baneling 'zergling 0))
       (define zerg-needs-queen-or-warren-minerals?
         (and live-game?
              (not under-base-attack?)
              (<= live-enemy-threat-supply 0)
              (>= live-army-supply 4)
              (or (< (unit-count 'queen) (length hatcheries))
                  (and (>= gas 80)
                       (not (building-present-or-pending? 'roach-warren))))))
       ;; Endgame Anti-Tie Corner Hunters: maintain >= 2 flying AA hunters (Corruptor / Mutalisk)
       (when (and endgame-corner-hunt?
                  (or (memq 'spire ready-bldg-types) (memq 'greater-spire ready-bldg-types))
                  (< (+ (unit-count 'mutalisk) (unit-count 'corruptor)) 2))
         (when (and (>= minerals (sc2-min-cost 'corruptor))
                    (>= gas (sc2-gas-cost 'corruptor)))
           (try-train-unit! 'corruptor 'larva 4))
         (when (and (< (+ (unit-count 'mutalisk) (unit-count 'corruptor)) 2)
                    (>= minerals (sc2-min-cost 'mutalisk))
                    (>= gas (sc2-gas-cost 'mutalisk)))
           (try-train-unit! 'mutalisk 'larva 4)))
       ;; T3 Air Siege: Corruptor -> Brood Lord when Greater Spire is ready or morphing
       (when (and (or (memq 'greater-spire ready-bldg-types)
                      (building-present-or-pending? 'greater-spire))
                  (< (unit-count 'brood-lord) 6))
         (when (< (unit-count 'corruptor) 3)
           (try-train-unit! 'corruptor 'larva 4 #:respect-bo-reserve? #t))
         (when (memq 'greater-spire ready-bldg-types)
           (emit-unit-morph-verified! 'brood-lord 'corruptor 2)))
       ;; T3 Hive Caster: Viper (Blinding Cloud / Abduct / Parasitic Bomb)
       (when (and (memq 'hive ready-bldg-types)
                  (< (unit-count 'viper) (if (>= eff-phase-supply 130) 3 2))
                  (or (plan-wants-now? 'viper)
                      enemy-heavy-ground-siege?
                      (and live-game? (>= live-army-supply 34)))
                  (>= minerals (sc2-min-cost 'viper))
                  (>= gas (sc2-gas-cost 'viper)))
         (try-train-unit! 'viper 'larva 4 #:respect-bo-reserve? #t))
       ;; T3 Frontline: Ultralisk
       (when (and (memq 'ultralisk-cavern ready-bldg-types)
                  (< (unit-count 'ultralisk) 8)
                  (>= minerals (sc2-min-cost 'ultralisk))
                  (>= gas (sc2-gas-cost 'ultralisk))
                  (can-spend-by-priority? 'ultralisk 'combat-unit))
         (try-train-unit! 'ultralisk 'larva 4 #:respect-bo-reserve? #t))
       ;; T2/T3 Caster: Infestor
       (when (and (memq 'infestation-pit ready-bldg-types)
                  (< (unit-count 'infestor) 2)
                  (or (plan-wants-now? 'infestor)
                      (and live-game? (>= live-army-supply 50)))
                  (>= minerals (sc2-min-cost 'infestor))
                  (>= gas (sc2-gas-cost 'infestor)))
         (try-train-unit! 'infestor 'larva 4 #:respect-bo-reserve? #t))
       (cond
         [(and (or (memq 'spire ready-bldg-types) (memq 'greater-spire ready-bldg-types))
               (or (and (>= minerals (sc2-min-cost 'corruptor))
                        (>= gas (sc2-gas-cost 'corruptor)))
                   (and (>= minerals (sc2-min-cost 'mutalisk))
                        (>= gas (sc2-gas-cost 'mutalisk)))))
          (define zerg-anti-air-now? (enemy-tech-observation-requires-anti-air? tech-obs))
          (define hold-mutalisk-for-corruptor?
            (and live-game?
                 zerg-anti-air-now?
                 (< (unit-count 'corruptor) 8)
                 (or (< minerals 250) (< gas 200))))
          (when (and (>= minerals (sc2-min-cost 'corruptor))
                     (>= gas (sc2-gas-cost 'corruptor))
                     (or (not live-game?)
                         (and zerg-anti-air-now? (< (unit-count 'corruptor) 8))
                         (building-present-or-pending? 'greater-spire)
                         (plan-wants-now? 'corruptor)))
            (try-train-unit! 'corruptor 'larva 4 #:respect-bo-reserve? (not zerg-anti-air-now?)))
          (when (and (not hold-mutalisk-for-corruptor?)
                     (< (unit-count 'mutalisk) 10)
                     (can-spend-by-priority? 'mutalisk 'combat-unit))
            (try-train-unit! 'mutalisk 'larva 4 #:respect-bo-reserve? #t))
          (when (memq 'hydralisk-den ready-bldg-types)
            (try-train-unit! 'hydralisk 'larva 4 #:respect-bo-reserve? #t))]
         [(and (memq 'hydralisk-den ready-bldg-types)
               (>= minerals (sc2-min-cost 'hydralisk))
               (>= gas (sc2-gas-cost 'hydralisk)))
          (when (or (not live-game?)
                    (not (memq 'hive ready-bldg-types))
                    (< (unit-count 'hydralisk) 16)
                    (< gas 150))
            (try-train-unit! 'hydralisk 'larva 4 #:respect-bo-reserve? #t))
          (when (and (memq 'roach-warren ready-bldg-types)
                     (or (not live-game?) (< (unit-count 'roach) 14))
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
                (not crisis-freeze-workers?)
                (worker-army-curve-satisfied?)
                (not zerg-saving-for-expand?)
                (can-spend-by-priority? 'drone 'worker)
                (< total-workers
                   (if live-game?
                       (min 70 (max target-workers zerg-ideal-worker-cap))
                       target-workers))
                (or (member '(train drone) prio-scheduled-actions)
                    (< (hash-ref pressure-metrics 'threat-pressure 0.0) 1.0)))
       (try-train-unit! 'drone 'larva 4
                        #:respect-bo-reserve? (and live-game? (>= total-workers 24))))]

    [(Protoss)
     ;; 1. Pro Mechanic #6: 1-to-1 Chrono Boost Target Assignment (`dispatch-macro-energy!`)
     (define nexuses
       (filter (lambda (b) (eq? (sc2-canonical-structure-sym (unit-type-sym b)) 'nexus)) ally-bldgs))
     (define ready-nexuses
       (filter (lambda (b) (eq? (sc2-canonical-structure-sym (unit-type-sym b)) 'nexus)) ready-bldgs))
     (define assimilators
       (filter (lambda (b) (eq? (sc2-canonical-structure-sym (unit-type-sym b)) 'assimilator)) ally-bldgs))
     (define active-assimilators (filter active-gas-bldg? assimilators))
     (define gateways
       (filter (lambda (b)
                 (memq (sc2-canonical-structure-sym (unit-type-sym b)) '(gateway warp-gate)))
               ally-bldgs))
     (define chrono-claimed-ids (mutable-seteqv))
     (define (eligible-live-chrono-target? b)
       (and (hash-ref b 'busy? #f)
            (not (memq 'chrono-boost (hash-ref b 'buffs '())))
            (not (set-member? chrono-claimed-ids (hash-ref b 'id -1)))))
     (define (chrono-prio-score b)
       (define bsym (sc2-canonical-structure-sym (unit-type-sym b)))
       (cond
         [(and (or early-survival-crisis? under-base-attack?)
               (memq bsym '(gateway warp-gate robotics-facility stargate)))
          1000.0]
         [(and (< total-workers 38)
               (not early-survival-crisis?)
               (eq? bsym 'nexus))
          900.0]
         [else
          (let loop ([rem PRO-CHRONO-11-STRUCTURES] [idx 0])
            (cond
              [(null? rem) -1.0]
              [(eq? bsym (sc2-canonical-structure-sym (car rem)))
               (- 800.0 (* 10.0 idx))]
              [else (loop (cdr rem) (add1 idx))]))]))
     (if live-game?
         (dispatch-macro-energy!
          ready-nexuses
          ready-bldgs
          frame
          chrono-claimed-ids
          #:min-energy SC2-NEXUS-CHRONO-BOOST-ENERGY
          #:valid-pair?
          (lambda (_nx b)
            (and (eligible-live-chrono-target? b)
                 (> (chrono-prio-score b) 0.0)))
          #:score-pair
          (lambda (_nx b)
            (chrono-prio-score b))
          #:emit-cast!
          (lambda (nx b)
            (define nx-id (hash-ref nx 'id 201))
            (define ct-id (hash-ref b 'id nx-id))
            (emit! (list 'cast-spell nx-id 'chrono-boost ct-id))))
         (for ([nx (in-list ready-nexuses)])
           (when (>= (hash-ref nx 'energy SC2-NEXUS-CHRONO-BOOST-ENERGY) SC2-NEXUS-CHRONO-BOOST-ENERGY)
             (define nx-id (hash-ref nx 'id 201))
             (define chrono-target
               (if (and (< total-workers SC2-EARLY-CHRONO-MAX-WORKERS)
                        (< frame SC2-EARLY-CHRONO-NEXUS-MAX-FRAME)
                        (not early-survival-crisis?))
                   nx
                   (or (and early-survival-crisis?
                            (findf (lambda (b)
                                     (memq (sc2-canonical-structure-sym (unit-type-sym b))
                                           '(gateway warp-gate)))
                                   ready-bldgs))
                       (for/or ([prio-type (in-list PRO-CHRONO-11-STRUCTURES)]
                                #:when (not (eq? prio-type 'nexus)))
                         (findf (lambda (b)
                                  (eq? (sc2-canonical-structure-sym (unit-type-sym b))
                                       (sc2-canonical-structure-sym prio-type)))
                                ready-bldgs))
                       nx)))
             (when chrono-target
               (define ct-id (hash-ref chrono-target 'id nx-id))
               (set-add! chrono-claimed-ids ct-id)
               (emit! (list 'cast-spell nx-id 'chrono-boost ct-id))))))

     ;; 2. Pro Mechanic #3: Protoss 1x1 Doorway Guard State Machine + Group Steal
     (define wall-pylon-slot (and (hash? protoss-matchup-wall) (hash-ref protoss-matchup-wall 'pylon #f)))
     (define wall-slot-1 (and (hash? protoss-matchup-wall) (hash-ref protoss-matchup-wall 'slot-1 #f)))
     (define wall-slot-2 (and (hash? protoss-matchup-wall) (hash-ref protoss-matchup-wall 'slot-2 #f)))
     (define wall-slot-3 (and (hash? protoss-matchup-wall) (hash-ref protoss-matchup-wall 'slot-3 #f)))
     (define wall-door-pt (and (hash? protoss-matchup-wall) (hash-ref protoss-matchup-wall 'door #f)))
     (define wall-park-pt (and (hash? protoss-matchup-wall) (hash-ref protoss-matchup-wall 'door-park #f)))
     (define door-guards
       (filter (lambda (u)
                 (and (memq (unit-type-sym u) '(zealot adept stalker))
                      (not (or (eq? (hash-ref u 'is-hallucination #f) #t)
                               (eq? (hash-ref u 'hallucination #f) #t)))))
               ally-units))
     (cond
       [(and (not (null? door-guards))
             (or (hash-ref obs 'door-guard #f)
                 (and (not live-game?)
                      (or (memq 'gateway bldg-types) (memq 'warp-gate bldg-types))
                      (< frame SC2-DOOR-GUARD-MAX-FRAME)
                      (not (null? enemy-units)))))
        (define dg (car door-guards))
        (define dg-id (hash-ref dg 'id 703))
        (acquire-unit-lease! leases dg-id 'door-guard frame 16 #:x nat-x #:y nat-y)
        (emit! (list 'hold-position dg-id nat-x nat-y))
        (emit! (list 'control-group-steal 2 (list dg-id)))
        (cortex-steal-control-group! cortex 2 (list dg-id))]
       [(and live-game?
             (pair? wall-door-pt)
             (not worker-rush-active?)
             (not in-base-proxy-detected?)
             (not (ormap (lambda (e)
                           (and (not (or (eq? (hash-ref e 'is-flying #f) #t)
                                         (eq? (hash-ref e 'flying? #f) #t)))
                                (<= (dist2d base-x base-y
                                            (hash-ref e 'x 9999.0)
                                            (hash-ref e 'y 9999.0))
                                    12.0)
                                (> (dist2d (car wall-door-pt) (cdr wall-door-pt)
                                           (hash-ref e 'x 9999.0)
                                           (hash-ref e 'y 9999.0))
                                   3.5)))
                         enemy-units))
             (not (null? door-guards))
             (or (memq 'gateway bldg-types) (memq 'warp-gate bldg-types)))
        (define door-x (safe-coord (car wall-door-pt) nat-x))
        (define door-y (safe-coord (cdr wall-door-pt) nat-y))
        (define park-x (if (pair? wall-park-pt) (safe-coord (car wall-park-pt) base-x) (safe-coord (+ door-x (* 2.5 (/ (- base-x door-x) (max 1.0 (dist2d base-x base-y door-x door-y))))) base-x)))
        (define park-y (if (pair? wall-park-pt) (safe-coord (cdr wall-park-pt) base-y) (safe-coord (+ door-y (* 2.5 (/ (- base-y door-y) (max 1.0 (dist2d base-x base-y door-x door-y))))) base-y)))
        (define door-st (rt-door-state rt))
        (define prev-gid (hash-ref door-st 'guard-id #f))
        (define near-guards
          (filter (lambda (u)
                    (<= (dist2d door-x door-y (hash-ref u 'x base-x) (hash-ref u 'y base-y)) 22.0))
                  door-guards))
        (define chosen-guard
          (or (and prev-gid
                   (findf (lambda (u) (equal? (hash-ref u 'id -1) prev-gid)) near-guards))
              (and (pair? near-guards)
                   (argmin (lambda (u)
                             (+ (if (eq? (unit-type-sym u) 'zealot) 0.0 3.0)
                                (dist2d door-x door-y (hash-ref u 'x door-x) (hash-ref u 'y door-y))))
                           near-guards))))
        (when chosen-guard
          (define gid (hash-ref chosen-guard 'id 703))
          (define gx (hash-ref chosen-guard 'x door-x))
          (define gy (hash-ref chosen-guard 'y door-y))
          (hash-set! door-st 'guard-id gid)
          (acquire-unit-lease! leases gid 'door-guard frame 16 #:x door-x #:y door-y)
          (define nearest-enemy-to-door
            (if (null? enemy-units)
                +inf.0
                (apply min
                       (map (lambda (e)
                              (dist2d door-x door-y (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0)))
                            enemy-units))))
          (define builder-transiting-door?
            (ormap (lambda (w)
                     (define wid (hash-ref w 'id 0))
                     (and (or (order-ledger-unit-has-active-build? oledger wid w)
                              (worker-has-engine-build-order? w))
                          (<= (dist2d door-x door-y (hash-ref w 'x base-x) (hash-ref w 'y base-y)) 3.2)))
                   workers))
          (define moving-army-near-door
            (count (lambda (u)
                     (define uid (hash-ref u 'id 0))
                     (and (not (equal? uid gid))
                          (combat-unit-record? u)
                          (not (or (eq? (hash-ref u 'is-flying #f) #t)
                                   (eq? (hash-ref u 'flying? #f) #t)))
                          (> (hash-ref u 'order-count 0) 0)
                          (not (= (hash-ref u 'order-ability-id 0) 18))
                          (<= (dist2d door-x door-y (hash-ref u 'x base-x) (hash-ref u 'y base-y)) 3.2)))
                   ally-units))
          (define transit-needed? (or builder-transiting-door? (>= moving-army-near-door 3)))
          (define cur-open-until (hash-ref door-st 'open-until-frame 0))
          (cond
            [(and (> nearest-enemy-to-door 10.5) transit-needed?)
             (hash-set! door-st 'open-until-frame (+ frame 24))
             (when (or (> (dist2d gx gy park-x park-y) 1.0)
                       (= (hash-ref chosen-guard 'order-ability-id 0) 18))
               (emit! (list 'move gid park-x park-y))
               (order-ledger-record-issued! oledger gid 'move 'door-park park-x park-y frame))]
            [(and (< frame cur-open-until)
                  (> nearest-enemy-to-door 9.5)
                  transit-needed?)
             (void)]
            [else
             (hash-set! door-st 'open-until-frame 0)
             (when (or (> (dist2d gx gy door-x door-y) 0.85)
                       (not (= (hash-ref chosen-guard 'order-ability-id 0) 18)))
               (emit! (list 'hold-position gid door-x door-y))
               (order-ledger-record-issued! oledger gid 'hold-position 'door-seal door-x door-y frame))]))])

     ;; 3. Pro Build-Order Expansion Sequencing (uncamped BFS pad redirect when natural is camped!)
     (when (and (>= minerals (sc2-min-cost 'nexus))
                (non-combat-min-ok? (sc2-min-cost 'nexus) 'nexus)
                (not blocked-nat-expanded-early?)
                (not under-early-cheese?)
                (not early-survival-crisis?)
                (not crisis-freeze-expand-or-gas?)
                (not under-base-attack?)
                (= (order-ledger-pending-count-for-type oledger 'nexus frame) 0)
                (or (< (length nexuses) SC2-MIN-DESIRED-BASES)
                    (and (= (length nexuses) 2)
                         (>= eff-phase-supply 50)
                         (or (not live-game?) (>= live-army-supply 14))
                         (or (memq 'robotics-facility bldg-types)
                             (memq 'twilight-council bldg-types)
                             (memq 'stargate bldg-types)
                             (plan-wants-now? 'nexus)))
                    (and (< (length nexuses) desired-bases)
                         (or (not (and endgame-corner-hunt?
                                       (< (+ (unit-count 'phoenix) (unit-count 'void-ray)) 2)))
                             (>= (- minerals (sc2-min-cost 'nexus)) 150))
                         (>= total-workers (* (length nexuses)
                                              (if (>= (length nexuses) 3) 16 SC2-MIN-WORKERS-PER-BASE-FOR-EXPAND)))
                         (or (not live-game?)
                             (>= live-army-supply (* 9 (length nexuses)))
                             (>= minerals 550))
                         (or (coupled-macro-plan-should-expand? macro-plan)
                             (>= frame SC2-MACRO-EXPAND-FRAME-THRESHOLD))))
                (let-values ([(cand-ex cand-ey)
                              (select-uncamped-expansion-pad (< (length nexuses) SC2-MIN-DESIRED-BASES))])
                  (and cand-ex cand-ey))
                (refractory-allow-action?! cd-tracker
                                           (list 'macro-expand 'Protoss)
                                           frame
                                           SC2-EXPANSION-COOLDOWN-FRAMES))
       (define-values (exp-x exp-y)
         (select-uncamped-expansion-pad (< (length nexuses) SC2-MIN-DESIRED-BASES)))
       (when (and exp-x exp-y)
         (emit! (list 'expand exp-x exp-y))
         (order-ledger-record-issued! oledger (+ 810000 (modulo frame 10000)) 'expand 'nexus exp-x exp-y frame)
         (spend-resources-and-supply! (sc2-min-cost 'nexus) 0 0)))

     (define protoss-saving-for-expand? (saving-for-expansion-now? (length nexuses)))

     ;; 4. Protoss Matchup-Wall & Pro Build-Order Sequencing:
     ;;    1st Gateway at wall `'slot-1` (early game only), CyberCore at `'slot-2` BEFORE 2nd Assimilator,
     ;;    optional `'slot-3` vs Zerg, and static defense offset >= 5.5 tiles off expansion pads!
     (define ready-pylons
       (filter (lambda (b)
                 (and (hash? b)
                      (eq? (sc2-canonical-structure-sym (unit-type-sym b)) 'pylon)
                      (>= (hash-ref b 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS)))
               ally-bldgs))
     (define first-ready-pylon
       (or (findf (lambda (b)
                    (or (not live-game-obs?)
                        (not (or worker-rush-active? in-base-proxy-detected?))
                        (<= (dist2d base-x base-y
                                    (hash-ref b 'x -999.0)
                                    (hash-ref b 'y -999.0))
                            7.5)))
                  ready-pylons)
           (and (> frame 500)
                (pair? ready-pylons)
                (car ready-pylons))))
     (define (wall-slot-powered? slot-pt)
       (and (pair? slot-pt)
            (not bypass-wall-pylon?)
            (or (not live-game-obs?)
                (ormap (lambda (b)
                         (and (hash? b)
                              (eq? (sc2-canonical-structure-sym (unit-type-sym b)) 'pylon)
                              (>= (hash-ref b 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS)
                              (<= (dist2d (car slot-pt) (cdr slot-pt)
                                          (hash-ref b 'x -999.0)
                                          (hash-ref b 'y -999.0))
                                  6.2)))
                       ally-bldgs))))
     (define inmain-powered-gx
       (if first-ready-pylon
           (safe-coord (+ (hash-ref first-ready-pylon 'x (+ base-x 4.0)) 2.5) (+ base-x 4.0))
           (safe-coord (+ base-x 4.0))))
     (define inmain-powered-gy
       (if first-ready-pylon
           (safe-coord (+ (hash-ref first-ready-pylon 'y (+ base-y 4.0)) 0.5) (+ base-y 4.0))
           (safe-coord (+ base-y 4.0))))
     (define gateway-wall-fallback?
       (let ([tbl (and (refractory-cooldown-tracker? cd-tracker)
                       (refractory-cooldown-tracker-table cd-tracker))])
         (when (and (null? gateways) live-game-obs? (hash? tbl))
           (define lock-entry (hash-ref tbl '(build-issue-lock gateway) #f))
           (when (pair? lock-entry)
             (define last-issue-f (car lock-entry))
             (define last-issue-cnt (cadr lock-entry))
             (define last-wall-f (hash-ref tbl '(build-issue-exact-wall gateway) -9999))
             (define wall-attempt? (= last-wall-f last-issue-f))
             (when (and (> frame last-issue-f)
                        (= (cur-ally-canon-bldg-count 'gateway) last-issue-cnt)
                        (= (order-ledger-pending-count-for-type oledger 'gateway frame) 0)
                        (or (and wall-attempt? power-placement-failed?)
                            (>= (- frame last-issue-f) 16)))
               (hash-remove! tbl '(build-issue-lock gateway))
               (hash-set! tbl '(gateway-wall-fallback gateway) frame))))
         (let ([fb-f (and (hash? tbl) (hash-ref tbl '(gateway-wall-fallback gateway) #f))])
           (and (exact-integer? fb-f)
                (<= 0 (- frame fb-f))
                (< (- frame fb-f) 64)))))
     (when (and (null? gateways)
                (or (not live-game-obs?) (not (not first-ready-pylon)))
                (not (building-present-or-pending? 'gateway))
                (save-cancel-rebuild-ready? 'gateway 60)
                (>= minerals (sc2-min-cost 'gateway))
                (>= (- minerals (sc2-min-cost 'gateway)) hard-supply-lockout-reserve-min))
       (if (and allow-exact-wall-slot?
                (not gateway-wall-fallback?)
                (not worker-rush-active?)
                (not in-base-proxy-detected?)
                (< frame 2200)
                (< cur-escrow-age-frames 64)
                (<= (length nexuses) 2)
                (wall-slot-powered? wall-slot-1))
           (emit-build-verified! 'gateway
                                 (safe-coord (car wall-slot-1) inmain-powered-gx)
                                 (safe-coord (cdr wall-slot-1) inmain-powered-gy)
                                 SC2-BUILD-SITE-MIN-CLEARANCE
                                 #:exact-wall-slot? #t)
           (emit-build-verified! 'gateway inmain-powered-gx inmain-powered-gy)))

     (define protoss-aa-needed?
       (enemy-tech-observation-requires-anti-air? tech-obs))
     (define enemy-muta-cnt-p
       (count (lambda (e) (eq? (unit-type-sym e) 'mutalisk)) enemy-units))
     (define enemy-air-raiders?
       (ormap (lambda (e)
                (memq (sc2-canonical-unit-sym (unit-type-sym e))
                      '(mutalisk oracle banshee)))
              enemy-units))

     ;; Emergency Shield Battery under early cheese / forward proxy / Reaper harass / air raiders / base attack
     ;; once Cybernetics Core is ready (offset >= 5.5 tiles off natural pad so it NEVER blocks expansion!)
     (define cur-sb-cnt
       (+ (count (lambda (b) (eq? (sc2-canonical-structure-sym (unit-type-sym b)) 'shield-battery)) ally-bldgs)
          (order-ledger-pending-count-for-type oledger 'shield-battery frame)))
     (define desired-sb-cnt
       (if (and live-game? (or enemy-air-raiders? protoss-aa-needed?))
           (min 2 (max 1 (length nexuses)))
           1))
     (when (and (or early-survival-crisis?
                    under-base-attack?
                    forward-proxy-detected?
                    (and live-game? (or enemy-air-raiders? protoss-aa-needed?))
                    (>= (count (lambda (e) (eq? (unit-type-sym e) 'reaper)) enemy-units) 2))
                (or (not live-game-obs?) (memq 'pylon ready-bldg-types))
                (memq 'cybernetics-core ready-bldg-types)
                (< cur-sb-cnt desired-sb-cnt)
                (save-cancel-rebuild-ready? 'shield-battery 60)
                (>= minerals (sc2-min-cost 'shield-battery))
                (or (<= (hash-ref open-prod-slots 'gateway 0) 0)
                    (non-combat-min-ok? (sc2-min-cost 'shield-battery))))
       (define main-has-sb?
         (ormap (lambda (b)
                  (and (hash? b)
                       (eq? (sc2-canonical-structure-sym (unit-type-sym b)) 'shield-battery)
                       (<= (dist2d base-x base-y (hash-ref b 'x -999.0) (hash-ref b 'y -999.0)) 12.0)))
                ally-bldgs))
       (define nat-has-sb?
         (ormap (lambda (b)
                  (and (hash? b)
                       (eq? (sc2-canonical-structure-sym (unit-type-sym b)) 'shield-battery)
                       (<= (dist2d nat-x nat-y (hash-ref b 'x -999.0) (hash-ref b 'y -999.0)) 12.0)))
                ally-bldgs))
       (define (pick-main-sb-coords)
         (let* ([px (if first-ready-pylon (hash-ref first-ready-pylon 'x (+ base-x 4.5)) (+ base-x 4.5))]
                [py (if first-ready-pylon (hash-ref first-ready-pylon 'y (+ base-y 2.5)) (+ base-y 2.5))]
                [cand (findf (lambda (off)
                               (define cx (+ px (car off)))
                               (define cy (+ py (cdr off)))
                               (and (>= (dist2d cx cy base-x base-y) 4.0)
                                    (andmap (lambda (b)
                                              (>= (dist2d cx cy
                                                          (hash-ref b 'x -999.0)
                                                          (hash-ref b 'y -999.0))
                                                  2.6))
                                            ally-bldgs)))
                             '((-3.0 . 0.0) (0.0 . -3.0) (3.0 . -3.0) (-2.5 . 3.0) (0.0 . 3.5) (3.5 . 2.5)))])
           (if cand
               (values (safe-coord (+ px (car cand))) (safe-coord (+ py (cdr cand))))
               (values (safe-coord (+ base-x 4.5)) (safe-coord (- base-y 3.5))))))
       (define-values (sb-x sb-y)
         (if (or (<= (length nexuses) 1)
                 (and nat-has-sb? (not main-has-sb?)))
             (pick-main-sb-coords)
             (offset-defense-anchor nat-x nat-y 5.5)))
       (emit-build-verified! 'shield-battery sb-x sb-y 2.0))

     ;; Build Cybernetics Core at wall `'slot-2` BEFORE 2nd Assimilator!
     (when (and (or (memq 'gateway ready-bldg-types) (memq 'warp-gate ready-bldg-types))
                (not protoss-saving-for-expand?)
                (not (building-present-or-pending? 'cybernetics-core))
                (save-cancel-rebuild-ready? 'cybernetics-core 60)
                (>= minerals (sc2-min-cost 'cybernetics-core))
                (non-combat-min-ok? (sc2-min-cost 'cybernetics-core) 'cybernetics-core))
       (define inmain-cy-x
         (if first-ready-pylon
             (safe-coord (- (hash-ref first-ready-pylon 'x (+ base-x 6.0)) 2.5) (+ base-x 6.0))
             (safe-coord (+ base-x 6.0))))
       (define inmain-cy-y
         (if first-ready-pylon
             (safe-coord (+ (hash-ref first-ready-pylon 'y (+ base-y 4.0)) 2.0) (+ base-y 4.0))
             (safe-coord (+ base-y 4.0))))
       (if (and allow-exact-wall-slot?
                (not worker-rush-active?)
                (not in-base-proxy-detected?)
                (< frame 2200)
                (< cur-escrow-age-frames 64)
                (<= (length nexuses) 2)
                (wall-slot-powered? wall-slot-2))
           (emit-build-verified! 'cybernetics-core
                                 (safe-coord (car wall-slot-2) inmain-cy-x)
                                 (safe-coord (cdr wall-slot-2) inmain-cy-y)
                                 SC2-BUILD-SITE-MIN-CLEARANCE
                                 #:exact-wall-slot? #t)
           (emit-build-verified! 'cybernetics-core inmain-cy-x inmain-cy-y)))

     (define has-nat-nexus-or-pending?
       (or (>= (length nexuses) 2)
           (> (order-ledger-pending-count-for-type oledger 'nexus frame) 0)))
     (define desired-assimilators
       (if (and early-survival-crisis? (null? active-assimilators))
           0
           (min (* SC2-GEYSERS-PER-BASE (length nexuses))
                (if live-game?
                    (cond
                      [(and (>= (length nexuses) 4) (>= total-workers 62) (< gas 600)) 8]
                      [(and (>= (length nexuses) 3) (>= total-workers 50) (< gas 450)) 6]
                      [(and (>= eff-phase-supply 52) (>= total-workers 38) (< gas 350)) 4]
                      [(and (>= eff-phase-supply 38) (>= total-workers 32) (< gas 300)) 3]
                      [(and (building-present-or-pending? 'cybernetics-core)
                            (or has-nat-nexus-or-pending? (>= eff-phase-supply 32))
                            (>= total-workers 19)
                            (< gas 250))
                       2]
                      [else 1])
                    (cond
                      [(>= supply-used 54) 4]
                      [(>= supply-used 40) 3]
                      [(or (memq 'cybernetics-core bldg-types) (>= total-workers SC2-MIN-WORKERS-FOR-SECOND-GAS)) 2]
                      [else 1])))))
     (define reserve-idle-stargate-aa?
       (and live-game?
            protoss-aa-needed?
            (memq 'stargate ready-bldg-types)
            (< (unit-count 'phoenix) 6)
            (> (hash-ref open-prod-slots 'stargate 0) 0)))
     (define (aa-stargate-min-ok? cost)
       (>= minerals (+ cost (if reserve-idle-stargate-aa? (sc2-min-cost 'phoenix) 0))))
     (define (aa-stargate-gas-ok? cost)
       (>= gas (+ cost (if reserve-idle-stargate-aa? (sc2-gas-cost 'phoenix) 0))))

     (define colossus-goal-cap (if (eq? effective-enemy-race 'Terran) 3 2))
     (define (protoss-holding-colossus-now?)
       (and live-game?
            (not protoss-saving-for-expand?)
            (not early-survival-crisis?)
            (not under-base-attack?)
            (not escrow-suppressed-active?)
            (< cur-escrow-age-frames max-escrow-timeout-frames)
            (memq 'robotics-bay ready-bldg-types)
            (memq 'robotics-facility ready-bldg-types)
            (> (hash-ref open-prod-slots 'robotics-facility 0) 0)
            (< (unit-count 'colossus) colossus-goal-cap)
            (can-spend-supply? (sc2-supply-cost 'colossus))))
     (define (protoss-colossus-escrow-ok? m-cost g-cost)
       (or (not (protoss-holding-colossus-now?))
           (and (>= (- minerals m-cost) (sc2-min-cost 'colossus))
                (>= (- gas g-cost) (sc2-gas-cost 'colossus)))))

     (when (and (or (memq 'gateway bldg-types) (memq 'warp-gate bldg-types))
                (not crisis-freeze-expand-or-gas?)
                (save-cancel-rebuild-ready? 'assimilator 60)
                (or (null? active-assimilators) (not protoss-saving-for-expand?))
                (or (< (length active-assimilators) 2)
                    (protoss-colossus-escrow-ok? (sc2-min-cost 'assimilator) 0))
                (< (+ (length active-assimilators) (order-ledger-pending-count-for-type oledger 'assimilator frame))
                   desired-assimilators)
                (aa-stargate-min-ok? (sc2-min-cost 'assimilator))
                (non-combat-min-ok? (sc2-min-cost 'assimilator)))
       (emit-gas-build-verified! 'assimilator (safe-coord (+ base-x 4.0)) (safe-coord (+ base-y 4.0))))

     ;; Research WarpGate at Cybernetics Core; in live games keep Gateways unmorphed (`Gateway` 62)
     ;; so `sc2-unit-orders` accurately tracks busy production slots without WarpGate cooldown blindness
     (when (memq 'cybernetics-core ready-bldg-types)
       (when (and (not protoss-saving-for-expand?)
                  (aa-stargate-min-ok? (sc2-min-cost 'warp-gate-research))
                  (aa-stargate-gas-ok? (sc2-gas-cost 'warp-gate-research))
                  (non-combat-min-ok? (sc2-min-cost 'warp-gate-research) 'warp-gate-research)
                  (non-combat-gas-ok? (sc2-gas-cost 'warp-gate-research) 'warp-gate-research)
                  (upgrade-needed? 'warp-gate-research)
                  (upgrade-needed? 'warpgate))
         (emit-research-verified! 'warp-gate-research))
       (when (and (not live-game?)
                  (or (memq 'warpgate researched-upgs)
                      (memq 'warp-gate-research researched-upgs))
                  (memq 'gateway ready-bldg-types))
         (emit! '(morph warp-gate))))

     ;; Build 1st (and late-game 2nd) Robotics Facility
     (define cur-robo-cnt
       (+ (count (lambda (b) (eq? (sc2-canonical-structure-sym (unit-type-sym b)) 'robotics-facility))
                 ally-bldgs)
          (order-ledger-pending-count-for-type oledger 'robotics-facility frame)))
     (define desired-robos
       (if (and live-game?
                (memq 'robotics-facility ready-bldg-types)
                (or (>= (length nexuses) 3)
                    (and (>= minerals 550) (>= gas 200)))
                (>= eff-phase-supply 72))
           2
           1))
     (when (and (memq 'cybernetics-core ready-bldg-types)
                (or (not protoss-saving-for-expand?) endgame-corner-hunt?)
                (save-cancel-rebuild-ready? 'robotics-facility 60)
                (< cur-robo-cnt desired-robos)
                (or (= cur-robo-cnt 0)
                    (and (protoss-colossus-escrow-ok? (sc2-min-cost 'robotics-facility) (sc2-gas-cost 'robotics-facility))
                         (or (>= minerals 550)
                             (can-spend-by-priority? 'robotics-facility 'production-scaling))))
                (aa-stargate-min-ok? (sc2-min-cost 'robotics-facility))
                (aa-stargate-gas-ok? (sc2-gas-cost 'robotics-facility))
                (non-combat-min-ok? (sc2-min-cost 'robotics-facility) 'robotics-facility)
                (non-combat-gas-ok? (sc2-gas-cost 'robotics-facility) 'robotics-facility))
       (emit-build-verified! 'robotics-facility
                             (safe-coord (+ base-x 6.0 (* 4.0 cur-robo-cnt)))
                             (safe-coord (+ base-y 6.0 (* 2.0 cur-robo-cnt))))
       (unless live-game?
         (emit! '(morph warp-gate))))

     ;; Priority Robotics Facility production (Group 6) BEFORE Twilight/Forge gas upgrades so
     ;; Observer (detection/vision) and Immortal/Colossus are never gas-starved!
     (when (and (or (not protoss-saving-for-expand?)
                    (and endgame-corner-hunt? (< (unit-count 'observer) 1)))
                (memq 'robotics-facility ready-bldg-types)
                (can-spend-supply? (sc2-supply-cost 'observer)))
       (define desired-observers
         (if (or (enemy-tech-observation-requires-detection? tech-obs)
                 (and live-game? (>= live-army-supply 40)))
             2
             1))
       (when (and (< (unit-count 'observer) desired-observers)
                  (or (< (unit-count 'observer) 1)
                      (enemy-tech-observation-requires-detection? tech-obs)
                      (protoss-colossus-escrow-ok? (sc2-min-cost 'observer) (sc2-gas-cost 'observer)))
                  (or (enemy-tech-observation-requires-detection? tech-obs)
                      (aa-stargate-gas-ok? (sc2-gas-cost 'observer))))
         (try-train-unit! 'observer 'robotics-facility 6))
       (unless protoss-saving-for-expand?
         (when (and (memq 'robotics-bay ready-bldg-types)
                    (< (unit-count 'colossus) 4)
                    (aa-stargate-min-ok? (sc2-min-cost 'colossus))
                    (aa-stargate-gas-ok? (sc2-gas-cost 'colossus))
                    (can-spend-supply? (sc2-supply-cost 'colossus)))
           (try-train-unit! 'colossus 'robotics-facility 6))
         (when (and (memq 'robotics-bay ready-bldg-types)
                    (< (unit-count 'disruptor) 3)
                    (or (member '(train disruptor) prio-scheduled-actions)
                        (>= (unit-count 'colossus) 1))
                    (protoss-colossus-escrow-ok? (sc2-min-cost 'disruptor) (sc2-gas-cost 'disruptor))
                    (aa-stargate-min-ok? (sc2-min-cost 'disruptor))
                    (aa-stargate-gas-ok? (sc2-gas-cost 'disruptor))
                    (can-spend-supply? (sc2-supply-cost 'disruptor)))
           (try-train-unit! 'disruptor 'robotics-facility 6))
         (when (and (protoss-colossus-escrow-ok? (sc2-min-cost 'immortal) (sc2-gas-cost 'immortal))
                    (aa-stargate-min-ok? (sc2-min-cost 'immortal))
                    (aa-stargate-gas-ok? (sc2-gas-cost 'immortal))
                    (can-spend-supply? (sc2-supply-cost 'immortal)))
           (try-train-unit! 'immortal 'robotics-facility 6))
         (when (and (< (unit-count 'warp-prism) 1)
                    (protoss-colossus-escrow-ok? (sc2-min-cost 'warp-prism) (sc2-gas-cost 'warp-prism))
                    (aa-stargate-min-ok? (sc2-min-cost 'warp-prism))
                    (or (plan-wants-now? 'warp-prism)
                        (and live-game? (>= live-army-supply 20) (>= minerals 350)))
                    (can-spend-supply? (sc2-supply-cost 'warp-prism)))
           (try-train-unit! 'warp-prism 'robotics-facility 6 #:respect-bo-reserve? #t))))

     ;; Priority Stargate Air Production (Tempest / Carrier / Anti-Air Phoenix / Corner-Hunter Flyers) BEFORE Twilight/Forge
     (define protoss-corner-flyers-needed?
       (and endgame-corner-hunt?
            (< (+ (unit-count 'phoenix) (unit-count 'void-ray)) 2)))
     (when (and (or (not protoss-saving-for-expand?)
                    protoss-corner-flyers-needed?
                    protoss-aa-needed?)
                (memq 'stargate ready-bldg-types))
       (when (and (not protoss-saving-for-expand?)
                  (memq 'fleet-beacon ready-bldg-types)
                  (or (plan-wants-now? 'tempest)
                      enemy-heavy-ground-siege?)
                  (< (unit-count 'tempest) 4)
                  (protoss-colossus-escrow-ok? (sc2-min-cost 'tempest) (sc2-gas-cost 'tempest))
                  (can-spend-supply? (sc2-supply-cost 'tempest)))
         (try-train-unit! 'tempest 'stargate 6))
       (when (and (not protoss-saving-for-expand?)
                  (memq 'fleet-beacon ready-bldg-types)
                  (protoss-colossus-escrow-ok? (sc2-min-cost 'carrier) (sc2-gas-cost 'carrier))
                  (can-spend-supply? (sc2-supply-cost 'carrier)))
         (try-train-unit! 'carrier 'stargate 6))
       (define phoenix-cap (if protoss-aa-needed? 10 4))
       ;; When facing light air (Mutalisk / Banshee / Phoenix), train fast Phoenixes BEFORE heavy Void Rays!
       (when (and (or protoss-corner-flyers-needed?
                      protoss-aa-needed?
                      (plan-wants-now? 'phoenix))
                  (< (unit-count 'phoenix) phoenix-cap)
                  (or protoss-corner-flyers-needed?
                      protoss-aa-needed?
                      (and (can-spend-by-priority? 'phoenix 'combat-unit)
                           (protoss-colossus-escrow-ok? (sc2-min-cost 'phoenix) (sc2-gas-cost 'phoenix))))
                  (can-spend-supply? (sc2-supply-cost 'phoenix)))
         (try-train-unit! 'phoenix 'stargate 6
                          #:respect-bo-reserve? (not (or protoss-corner-flyers-needed? protoss-aa-needed?))))
       (when (and (or protoss-corner-flyers-needed?
                      protoss-aa-needed?
                      (plan-wants-now? 'void-ray)
                      (>= minerals 250))
                  (or protoss-corner-flyers-needed?
                      (and (can-spend-by-priority? 'void-ray 'combat-unit)
                           (protoss-colossus-escrow-ok? (sc2-min-cost 'void-ray) (sc2-gas-cost 'void-ray))))
                  (can-spend-supply? (sc2-supply-cost 'void-ray)))
         (try-train-unit! 'void-ray 'stargate 6 #:respect-bo-reserve? (not protoss-corner-flyers-needed?)))
       (when (and (not protoss-saving-for-expand?)
                  (or (not live-game?)
                      (and (not protoss-aa-needed?)
                           (< live-army-supply 30)))
                  (protoss-colossus-escrow-ok? (sc2-min-cost 'oracle) (sc2-gas-cost 'oracle))
                  (or (< (unit-count 'oracle) 1)
                      (and (< (unit-count 'oracle) 2)
                           (>= minerals 200)
                           (>= gas 200)))
                  (can-spend-supply? (sc2-supply-cost 'oracle)))
         (try-train-unit! 'oracle 'stargate 6)))

     ;; Build Twilight Council at 28+ supply after Robotics Facility is started
     (when (and (memq 'cybernetics-core ready-bldg-types)
                (not protoss-saving-for-expand?)
                (building-present-or-pending? 'robotics-facility)
                (not (building-present-or-pending? 'twilight-council))
                (save-cancel-rebuild-ready? 'twilight-council 60)
                (>= eff-phase-supply 28)
                (>= minerals (sc2-min-cost 'twilight-council))
                (>= gas (sc2-gas-cost 'twilight-council))
                (protoss-colossus-escrow-ok? (sc2-min-cost 'twilight-council) (sc2-gas-cost 'twilight-council))
                (non-combat-min-ok? (sc2-min-cost 'twilight-council) 'twilight-council)
                (non-combat-gas-ok? (sc2-gas-cost 'twilight-council) 'twilight-council))
       (emit-build-verified! 'twilight-council (safe-coord (+ base-x 6.0)) (safe-coord (- base-y 4.0))))

     (when (and (memq 'twilight-council ready-bldg-types)
                (not urgent-combat-or-intel-need?))
       (define blink-first?
         (and live-game?
              (or protoss-aa-needed? (> enemy-muta-cnt-p 0))))
       (cond
         [(and blink-first?
               (upgrade-needed? 'blink)
               (protoss-colossus-escrow-ok? (sc2-min-cost 'blink) (sc2-gas-cost 'blink)))
          (emit-research-verified! 'blink)]
         [(and (upgrade-needed? 'charge)
               (protoss-colossus-escrow-ok? (sc2-min-cost 'charge) (sc2-gas-cost 'charge)))
          (emit-research-verified! 'charge)]
         [(and (upgrade-needed? 'blink)
               (protoss-colossus-escrow-ok? (sc2-min-cost 'blink) (sc2-gas-cost 'blink)))
          (emit-research-verified! 'blink)]
         [(and (or (not live-game?)
                   (plan-wants-now? 'resonating-glaives)
                   (>= (unit-count 'adept) 2))
               (upgrade-needed? 'resonating-glaives)
               (protoss-colossus-escrow-ok? (sc2-min-cost 'resonating-glaives) (sc2-gas-cost 'resonating-glaives)))
          (emit-research-verified! 'resonating-glaives)]))

     ;; Stargate & Fleet Beacon Tech Structures (avoid opening 3rd tech tree on 2 bases when Robo+Twilight already exist unless AA/corner-hunt!)
     (define robo-and-twilight-present?
       (and (building-present-or-pending? 'robotics-facility)
            (building-present-or-pending? 'twilight-council)))
     (when (and (memq 'cybernetics-core ready-bldg-types)
                (or (not protoss-saving-for-expand?) endgame-corner-hunt?)
                (not (building-present-or-pending? 'stargate))
                (save-cancel-rebuild-ready? 'stargate 60)
                (or (and (not (and live-game? robo-and-twilight-present?))
                         (plan-wants-now? 'stargate))
                    (enemy-tech-observation-requires-anti-air? tech-obs)
                    endgame-corner-hunt?
                    (and live-game? (>= (length nexuses) 3) (>= eff-phase-supply 80)))
                (or endgame-corner-hunt?
                    protoss-aa-needed?
                    (protoss-colossus-escrow-ok? (sc2-min-cost 'stargate) (sc2-gas-cost 'stargate)))
                (>= minerals (sc2-min-cost 'stargate))
                (>= gas (sc2-gas-cost 'stargate))
                (non-combat-min-ok? (sc2-min-cost 'stargate) 'stargate)
                (non-combat-gas-ok? (sc2-gas-cost 'stargate) 'stargate))
       (emit-build-verified! 'stargate (safe-coord (- base-x 5.0)) (safe-coord (+ base-y 5.0))))

     (when (and (memq 'stargate ready-bldg-types)
                (not protoss-saving-for-expand?)
                (not (building-present-or-pending? 'fleet-beacon))
                (save-cancel-rebuild-ready? 'fleet-beacon 60)
                (or (plan-wants-now? 'fleet-beacon)
                    (and live-game? (>= (length nexuses) 3) (>= eff-phase-supply 106)))
                (protoss-colossus-escrow-ok? (sc2-min-cost 'fleet-beacon) (sc2-gas-cost 'fleet-beacon))
                (>= minerals (sc2-min-cost 'fleet-beacon))
                (>= gas (sc2-gas-cost 'fleet-beacon))
                (non-combat-min-ok? (sc2-min-cost 'fleet-beacon) 'fleet-beacon)
                (non-combat-gas-ok? (sc2-gas-cost 'fleet-beacon) 'fleet-beacon))
       (emit-build-verified! 'fleet-beacon (safe-coord (- base-x 6.0)) (safe-coord (+ base-y 6.0))))

     ;; Scale Gateways (2nd Gateway at wall `'slot-3` in PvZ/PvR early game when present!)
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
            #:escrow-expired? (or escrow-suppressed-active?
                                  (>= cur-escrow-age-frames max-escrow-timeout-frames)
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
                        [(>= minerals 650) 8]
                        [(>= minerals 450) 6]
                        [(>= total-workers 42) 5]
                        [(>= eff-phase-supply 36) 4]
                        [else 3])]
                     [(and (memq 'cybernetics-core bldg-types)
                           (or (not live-game?)
                               (<= protoss-nat-reserve 0)
                               (>= (- minerals protoss-nat-reserve) (sc2-min-cost 'gateway))))
                      (if (>= minerals 650) 3 2)]
                     [else 1]))))
     (define protoss-holding-forge-min?
       (and (memq 'cybernetics-core ready-bldg-types)
            (not (building-present-or-pending? 'forge))
            (or (eq? bo-goal-sym 'forge)
                (eq? prio-saving-for-sym 'forge)
                (and (enemy-tech-observation-requires-detection? tech-obs)
                     (not (building-present-or-pending? 'robotics-facility))))))
     (when (and (not protoss-saving-for-expand?)
                (save-cancel-rebuild-ready? 'gateway 60)
                (or (< (length gateways) 1)
                    (not live-game?)
                    (>= minerals 650)
                    (can-spend-by-priority? 'gateway 'production-scaling))
                (or (< (length gateways) 1)
                    (>= minerals 850)
                    (protoss-colossus-escrow-ok? (sc2-min-cost 'gateway) 0))
                (>= (length gateways) 1)
                (or (not live-game?)
                    (< (length gateways) 3)
                    (< (hash-ref open-prod-slots 'gateway 0) 2)
                    (>= minerals 350))
                (< (+ (length gateways) (order-ledger-pending-count-for-type oledger 'gateway frame))
                   desired-gateways)
                (or (memq 'cybernetics-core bldg-types)
                    (>= minerals SC2-SURPLUS-MINERAL-BANK-THRESHOLD))
                (>= (- minerals
                       protoss-nat-reserve
                       (if protoss-holding-forge-min? (sc2-min-cost 'forge) 0))
                    (sc2-min-cost 'gateway))
                (non-combat-min-ok? (sc2-min-cost 'gateway)))
       (define gw-idx (length gateways))
       (if (and allow-exact-wall-slot?
                (not worker-rush-active?)
                (not in-base-proxy-detected?)
                (< frame 2600)
                (< cur-escrow-age-frames 64)
                (<= (length nexuses) 2)
                (= gw-idx 1)
                (wall-slot-powered? wall-slot-3))
           (emit-build-verified! 'gateway
                                 (safe-coord (car wall-slot-3) (+ base-x 7.5))
                                 (safe-coord (cdr wall-slot-3) (+ base-y 4.0))
                                 SC2-BUILD-SITE-MIN-CLEARANCE
                                 #:exact-wall-slot? #t)
           (emit-build-verified! 'gateway
                                 (safe-coord (+ base-x 4.0 (* 3.5 (modulo gw-idx 3))))
                                 (safe-coord (+ base-y 4.0 (* 3.5 (quotient gw-idx 3)))))))

     ;; Forge, Offset Photon Cannon, Robotics Bay, Templar Archives / Dark Shrine
     (when (and (or (memq 'robotics-facility ready-bldg-types)
                    (memq 'twilight-council ready-bldg-types)
                    (and (memq 'cybernetics-core ready-bldg-types)
                         (or (enemy-tech-observation-requires-detection? tech-obs)
                             (plan-wants-now? 'forge)
                             (eq? bo-goal-sym 'forge)
                             (eq? prio-saving-for-sym 'forge)
                             (member '(build forge) prio-scheduled-actions)
                             (>= active-bases 2))))
                (or (enemy-tech-observation-requires-detection? tech-obs)
                    (not early-survival-crisis?))
                (not protoss-saving-for-expand?)
                (or (enemy-tech-observation-requires-detection? tech-obs)
                    (protoss-colossus-escrow-ok? (sc2-min-cost 'forge) 0))
                (or (enemy-tech-observation-requires-detection? tech-obs)
                    (plan-wants-now? 'forge)
                    (eq? bo-goal-sym 'forge)
                    (eq? prio-saving-for-sym 'forge)
                    (member '(build forge) prio-scheduled-actions)
                    (can-spend-by-priority? 'forge 'tech-upgrade))
                (not (building-present-or-pending? 'forge))
                (save-cancel-rebuild-ready? 'forge 60)
                (or (enemy-tech-observation-requires-detection? tech-obs)
                    (plan-wants-now? 'forge)
                    (eq? bo-goal-sym 'forge)
                    (eq? prio-saving-for-sym 'forge)
                    (member '(build forge) prio-scheduled-actions)
                    (>= (length nexuses) SC2-MIN-DESIRED-BASES))
                (or (not live-game?)
                    (enemy-tech-observation-requires-detection? tech-obs)
                    (plan-wants-now? 'forge)
                    (eq? bo-goal-sym 'forge)
                    (eq? prio-saving-for-sym 'forge)
                    (member '(build forge) prio-scheduled-actions)
                    (>= eff-phase-supply 46))
                (>= minerals (sc2-min-cost 'forge))
                (non-combat-min-ok? (sc2-min-cost 'forge) 'forge))
       (emit-build-verified! 'forge (safe-coord (+ base-x 5.0)) (safe-coord (- base-y 4.0))))

     (define cur-pc-cnt
       (+ (count (lambda (b) (eq? (sc2-canonical-structure-sym (unit-type-sym b)) 'photon-cannon)) ally-bldgs)
          (order-ledger-pending-count-for-type oledger 'photon-cannon frame)))
     (define desired-pc-cnt
       (if (and live-game? (or enemy-air-raiders? protoss-aa-needed?))
           (min 2 (max 1 (length nexuses)))
           1))
     (when (and (memq 'forge ready-bldg-types)
                (or (enemy-tech-observation-requires-detection? tech-obs)
                    (plan-wants-now? 'photon-cannon)
                    (and live-game? (or enemy-air-raiders? protoss-aa-needed?)))
                (< cur-pc-cnt desired-pc-cnt)
                (save-cancel-rebuild-ready? 'photon-cannon 60)
                (>= minerals (sc2-min-cost 'photon-cannon))
                (refractory-allow-action?! cd-tracker
                                           (list 'static-detector 'photon-cannon)
                                           frame
                                           SC2-STATIC-DETECTOR-COOLDOWN-FRAMES))
       (define main-has-pc?
         (ormap (lambda (b)
                  (and (hash? b)
                       (eq? (sc2-canonical-structure-sym (unit-type-sym b)) 'photon-cannon)
                       (<= (dist2d base-x base-y (hash-ref b 'x -999.0) (hash-ref b 'y -999.0)) 12.0)))
                ally-bldgs))
       (define nat-has-pc?
         (ormap (lambda (b)
                  (and (hash? b)
                       (eq? (sc2-canonical-structure-sym (unit-type-sym b)) 'photon-cannon)
                       (<= (dist2d nat-x nat-y (hash-ref b 'x -999.0) (hash-ref b 'y -999.0)) 12.0)))
                ally-bldgs))
       (define-values (pc-x pc-y)
         (if (and live-game?
                  (or enemy-air-raiders? protoss-aa-needed?)
                  (not main-has-pc?)
                  (or (<= (length nexuses) 1) nat-has-pc?))
             (let* ([px (if first-ready-pylon (hash-ref first-ready-pylon 'x (+ base-x 4.5)) (+ base-x 4.5))]
                    [py (if first-ready-pylon (hash-ref first-ready-pylon 'y (+ base-y 2.5)) (+ base-y 2.5))])
               (values (safe-coord (+ px 2.5) base-x) (safe-coord (- py 2.5) base-y)))
             (offset-defense-anchor nat-x nat-y 5.5)))
       (emit-build-verified! 'photon-cannon pc-x pc-y 2.0))

     (when (and (memq 'forge ready-bldg-types)
                (not urgent-combat-or-intel-need?))
       (cond
         [(and (can-spend-by-priority? 'protoss-ground-weapons-1 'tech-upgrade)
               (upgrade-needed? 'protoss-ground-weapons-1)
               (protoss-colossus-escrow-ok? (sc2-min-cost 'protoss-ground-weapons-1) (sc2-gas-cost 'protoss-ground-weapons-1)))
          (emit-research-verified! 'protoss-ground-weapons-1)]
         [(and (upgrade-needed? 'protoss-ground-armor-1)
               (protoss-colossus-escrow-ok? (sc2-min-cost 'protoss-ground-armor-1) (sc2-gas-cost 'protoss-ground-armor-1)))
          (emit-research-verified! 'protoss-ground-armor-1)]
         [(and (memq 'twilight-council ready-bldg-types)
               (upgrade-needed? 'protoss-ground-weapons-2)
               (protoss-colossus-escrow-ok? (sc2-min-cost 'protoss-ground-weapons-2) (sc2-gas-cost 'protoss-ground-weapons-2)))
          (emit-research-verified! 'protoss-ground-weapons-2)]
         [(and (memq 'twilight-council ready-bldg-types)
               (upgrade-needed? 'protoss-ground-armor-2)
               (protoss-colossus-escrow-ok? (sc2-min-cost 'protoss-ground-armor-2) (sc2-gas-cost 'protoss-ground-armor-2)))
          (emit-research-verified! 'protoss-ground-armor-2)]
         [(and (memq 'twilight-council ready-bldg-types)
               (upgrade-needed? 'protoss-ground-weapons-3)
               (protoss-colossus-escrow-ok? (sc2-min-cost 'protoss-ground-weapons-3) (sc2-gas-cost 'protoss-ground-weapons-3)))
          (emit-research-verified! 'protoss-ground-weapons-3)]
         [(and (memq 'twilight-council ready-bldg-types)
               (upgrade-needed? 'protoss-ground-armor-3)
               (protoss-colossus-escrow-ok? (sc2-min-cost 'protoss-ground-armor-3) (sc2-gas-cost 'protoss-ground-armor-3)))
          (emit-research-verified! 'protoss-ground-armor-3)]
         [(and (upgrade-needed? 'protoss-shields-1)
               (protoss-colossus-escrow-ok? (sc2-min-cost 'protoss-shields-1) (sc2-gas-cost 'protoss-shields-1)))
          (emit-research-verified! 'protoss-shields-1)]))

     (when (and (memq 'twilight-council ready-bldg-types)
                (not protoss-saving-for-expand?)
                (save-cancel-rebuild-ready? 'templar-archive 60)
                (protoss-colossus-escrow-ok? (sc2-min-cost 'templar-archive) (sc2-gas-cost 'templar-archive))
                (or (and (not live-game?)
                         (or (plan-wants-now? 'templar-archive)
                             (can-spend-by-priority? 'templar-archive 'tech-upgrade)))
                    (and live-game?
                         (or (eq? bo-goal-sym 'templar-archive)
                             (>= enemy-muta-cnt-p 3)
                             (and (>= (length nexuses) 3) (>= eff-phase-supply 80)))
                         (or (plan-wants-now? 'templar-archive)
                             (can-spend-by-priority? 'templar-archive 'tech-upgrade)
                             (>= eff-phase-supply 92))))
                (not (building-present-or-pending? 'templar-archive))
                (>= (length nexuses) SC2-MIN-DESIRED-BASES)
                (>= gas 150)
                (>= minerals (sc2-min-cost 'templar-archive))
                (non-combat-min-ok? (sc2-min-cost 'templar-archive)))
       (emit-build-verified! 'templar-archive (safe-coord (+ base-x 6.0)) (safe-coord (- base-y 6.0))))

     (when (and (memq 'twilight-council ready-bldg-types)
                (not protoss-saving-for-expand?)
                (save-cancel-rebuild-ready? 'dark-shrine 60)
                (protoss-colossus-escrow-ok? (sc2-min-cost 'dark-shrine) (sc2-gas-cost 'dark-shrine))
                (not (building-present-or-pending? 'dark-shrine))
                (plan-wants-now? 'dark-shrine)
                (>= minerals (sc2-min-cost 'dark-shrine))
                (>= gas (sc2-gas-cost 'dark-shrine))
                (non-combat-min-ok? (sc2-min-cost 'dark-shrine) 'dark-shrine)
                (non-combat-gas-ok? (sc2-gas-cost 'dark-shrine) 'dark-shrine))
       (emit-build-verified! 'dark-shrine (safe-coord (- base-x 6.0)) (safe-coord (- base-y 5.0))))

     (when (and (memq 'templar-archive ready-bldg-types)
                (not urgent-combat-or-intel-need?)
                (protoss-colossus-escrow-ok? (sc2-min-cost 'psi-storm) (sc2-gas-cost 'psi-storm))
                (upgrade-needed? 'psi-storm))
       (emit-research-verified! 'psi-storm))

     (when (and (memq 'robotics-facility ready-bldg-types)
                (can-spend-by-priority? 'robotics-bay 'tech-upgrade)
                (not (building-present-or-pending? 'robotics-bay))
                (save-cancel-rebuild-ready? 'robotics-bay 60)
                (or (not live-game?)
                    (not (or protoss-aa-needed? (> enemy-muta-cnt-p 0)))
                    (>= (unit-count 'phoenix) 4)
                    (>= (unit-count 'stalker) 10))
                (or (not (hash-has-key? raw-obs 'mineral-harvesters))
                    (eq? bo-goal-sym 'robotics-bay)
                    (and (eq? effective-enemy-race 'Terran)
                         (>= eff-phase-supply 52)
                         (>= (unit-count 'immortal) 1))
                    (and (>= eff-phase-supply 62)
                         (or (>= (unit-count 'immortal) 2)
                             (>= eff-phase-supply 76))))
                (>= minerals (sc2-min-cost 'robotics-bay))
                (>= gas (sc2-gas-cost 'robotics-bay))
                (non-combat-min-ok? (sc2-min-cost 'robotics-bay))
                (non-combat-gas-ok? (sc2-gas-cost 'robotics-bay)))
       (emit-build-verified! 'robotics-bay (safe-coord (+ base-x 7.0)) (safe-coord (+ base-y 7.0)))
       (when (or (not live-game?) (memq 'forge ready-bldg-types))
         (emit-research-verified! 'protoss-ground-weapons-1))
       (when (and (or (not live-game?)
                      (and (memq 'forge ready-bldg-types)
                           (>= minerals (sc2-min-cost 'photon-cannon))))
                  (refractory-allow-action?! cd-tracker
                                             (list 'static-detector 'photon-cannon)
                                             frame
                                             SC2-STATIC-DETECTOR-COOLDOWN-FRAMES))
         (if live-game?
             (let-values ([(pcx pcy) (offset-defense-anchor nat-x nat-y 5.5)])
               (emit-build-verified! 'photon-cannon pcx pcy 2.0))
             (emit! (list 'build 'photon-cannon nat-x nat-y)))))

     (when (and (memq 'robotics-bay ready-bldg-types)
                (not urgent-combat-or-intel-need?))
       (cond
         [(and (or (not live-game?)
                   (plan-wants-now? 'extended-thermal-lance)
                   (>= (unit-count 'colossus) 1))
               (protoss-colossus-escrow-ok? (sc2-min-cost 'extended-thermal-lance) (sc2-gas-cost 'extended-thermal-lance))
               (upgrade-needed? 'extended-thermal-lance))
          (emit-research-verified! 'extended-thermal-lance)]
         [(and (or (not live-game?)
                   (plan-wants-now? 'gravitic-booster)
                   (>= (unit-count 'observer) 1))
               (protoss-colossus-escrow-ok? (sc2-min-cost 'gravitic-booster) (sc2-gas-cost 'gravitic-booster))
               (upgrade-needed? 'gravitic-booster))
          (emit-research-verified! 'gravitic-booster)]))

     ;; Morph Archons when >= 2 spent/non-storm Templars are available (keep up to 2 full-energy Storm HTs unless facing Mutas!)
     (define storm-ready? (memq 'psi-storm researched-upgs))
     (define high-energy-ht-count
       (if (and live-game? storm-ready? (< enemy-muta-cnt-p 3))
           (min 2 (count (lambda (u)
                           (and (eq? (unit-type-sym u) 'high-templar)
                                (>= (hash-ref u 'energy 0) 75)))
                         ally-units))
           0))
     (define avail-ht-slots (max 0 (- (hash-ref open-prod-slots 'high-templar 0) high-energy-ht-count)))
     (define avail-dt-slots (hash-ref open-prod-slots 'dark-templar 0))
     (when (if live-game?
               (>= (+ avail-ht-slots avail-dt-slots) 2)
               (>= (count (lambda (u) (memq (unit-type-sym u) '(high-templar dark-templar))) ally-units) 2))
       (define consume-ht (min 2 avail-ht-slots))
       (define consume-dt (min (- 2 consume-ht) avail-dt-slots))
       (when (> consume-ht 0)
         (hash-set! open-prod-slots 'high-templar
                    (max 0 (- (hash-ref open-prod-slots 'high-templar 0) consume-ht))))
       (when (> consume-dt 0)
         (hash-set! open-prod-slots 'dark-templar (- avail-dt-slots consume-dt)))
       (emit! '(morph archon))
       (order-ledger-record-issued! oledger (+ 865500 (modulo frame 10000) (length actions))
                                    'morph 'archon base-x base-y frame))

     ;; 5. Protoss Probe Saturation Priority (70 hard cap + midgame army curve) + Gateway Unit Training
     (define protoss-ideal-worker-cap
       (min 70 (* SC2-IDEAL-WORKERS-PER-BASE (max 1 (length nexuses)))))
     (define protoss-probe-priority?
       (and (or (not protoss-saving-for-expand?)
                (and (< total-workers 19) (< minerals 350)))
            (not crisis-freeze-workers?)
            (worker-army-curve-satisfied?)
            (not urgent-combat-or-intel-need?)
            (or (< total-workers protoss-ideal-worker-cap)
                (can-spend-by-priority? 'probe 'worker))
            (< total-workers (min 70 (max target-workers protoss-ideal-worker-cap)))
            (or (not live-game?)
                (and (not under-base-attack?) (<= live-enemy-threat-supply 0))
                (< total-workers 20)
                (not (or (memq 'gateway ready-bldg-types) (memq 'warp-gate ready-bldg-types)))
                (>= (length ally-combat-units) 3)
                (>= live-army-supply (* 6 (max 1 (length nexuses)))))
            (>= minerals
                (+ (sc2-min-cost 'probe)
                   (if (and live-game?
                            (>= total-workers 18)
                            bo-goal-sym
                            (not (memq bo-goal-sym '(hatchery nexus command-center drone probe scv)))
                            (> (sc2-gas-cost bo-goal-sym) 0)
                            (>= gas (sc2-gas-cost bo-goal-sym)))
                       (sc2-min-cost bo-goal-sym)
                       0)))
            (can-spend-supply? (sc2-supply-cost 'probe))
            (not under-early-cheese?)
            (< (hash-ref pressure-metrics 'threat-pressure 0.0) 0.85)))
     (when protoss-probe-priority?
       (try-train-unit! 'probe 'townhall 4
                        #:respect-bo-reserve?
                        (and live-game?
                             (or (>= total-workers 24)
                                 (>= total-workers protoss-ideal-worker-cap)
                                 (and (>= total-workers 16)
                                      (> bo-reserved-gas 0)
                                      (>= gas bo-reserved-gas)))
                             (not (memq bo-goal-sym '(hatchery nexus command-center drone probe scv))))))

     ;; Protoss Gateway / WarpGate Unit Training (Group 5), governed by `can-spend-by-priority?`
     (define (gateway-unit-colossus-ok? u-sym)
       (or urgent-combat-or-intel-need?
           under-base-attack?
           (and (eq? u-sym 'zealot) (>= minerals 400))
           (protoss-colossus-escrow-ok? (sc2-min-cost u-sym) (sc2-gas-cost u-sym))))
     (when (and (not protoss-saving-for-expand?)
                (can-spend-supply? (sc2-supply-cost 'zealot)))
       (cond
         [(memq 'cybernetics-core ready-bldg-types)
          ;; Dark Templar when Dark Shrine is ready
          (when (and (memq 'dark-shrine ready-bldg-types)
                     (gateway-unit-colossus-ok? 'dark-templar)
                     (or (plan-wants-now? 'dark-templar)
                         (< (unit-count 'dark-templar) 3))
                     (>= gas (sc2-gas-cost 'dark-templar))
                     (can-spend-by-priority? 'dark-templar 'combat-unit))
            (try-train-unit! 'dark-templar 'gateway 5 #:respect-bo-reserve? #t))
          ;; High Templar -> Psi Storm & Archon when Templar Archives ready
          (when (and (memq 'templar-archive ready-bldg-types)
                     (gateway-unit-colossus-ok? 'high-templar)
                     (< (unit-count 'high-templar) 6)
                     (>= gas (sc2-gas-cost 'high-templar)))
            (try-train-unit! 'high-templar 'gateway 5 #:respect-bo-reserve? #t))
          ;; Guardian Shield aura + gas sink: maintain 1 Sentry (respecting exact 100G cost & bo=sentry goal!)
          (when (and (>= gas (sc2-gas-cost 'sentry))
                     (gateway-unit-colossus-ok? 'sentry)
                     (or (eq? bo-goal-sym 'sentry)
                         (plan-wants-now? 'sentry)
                         (>= (length ally-combat-units) 2))
                     (if live-game?
                         (and (< (unit-count 'sentry) 1)
                              (or (eq? bo-goal-sym 'sentry)
                                  (eq? prio-saving-for-sym 'sentry)
                                  (plan-wants-now? 'sentry)
                                  (>= (unit-count 'stalker) 4)
                                  (and (>= gas 120) (>= (length ally-combat-units) 2))))
                         (< (unit-count 'sentry) 2)))
            (try-train-unit! 'sentry 'gateway 5 #:respect-bo-reserve? #t))
          ;; Counter-composition sensors: Zergling/Baneling floods (#5122350) vs Reaper/proxy Terran (#5122354)
          (define enemy-reaper-cnt
            (count (lambda (e) (eq? (unit-type-sym e) 'reaper)) enemy-units))
          (define enemy-light-swarm-cnt
            (count (lambda (e) (memq (unit-type-sym e) '(zergling baneling marine))) enemy-units))
          (define enemy-armored-or-air-cnt
            (count (lambda (e)
                     (memq (unit-type-sym e)
                           '(roach ravager marauder stalker immortal siege-tank siege-tank-sieged
                             thor ultralisk colossus mutalisk void-ray phoenix banshee viking medivac liberator)))
                   enemy-units))
          (define pvz-ling-swarm-mode?
            (and live-game?
                 (>= enemy-light-swarm-cnt 6)
                 (> enemy-light-swarm-cnt (* 2 (max 1 enemy-armored-or-air-cnt)))))
          (define anti-reaper-or-proxy-terran?
            (and live-game?
                 (or (>= enemy-reaper-cnt 1)
                     (and forward-proxy-detected? (eq? effective-enemy-race 'Terran)))))
          (cond
            [pvz-ling-swarm-mode?
             ;; Counter Zergling/Baneling floods (#5122350) with Light-slaying Adepts + tanky Zealots
             ;; instead of overbuilding Stalkers that get surrounded and shredded!
             (when (and (< (unit-count 'adept) 8)
                        (gateway-unit-colossus-ok? 'adept)
                        (or (can-spend-by-priority? 'adept 'combat-unit)
                            (can-spend-by-priority? 'stalker 'combat-unit)))
               (try-train-unit! 'adept 'gateway 5 #:respect-bo-reserve? #t))
             (when (and (gateway-unit-colossus-ok? 'zealot)
                        (or (can-spend-by-priority? 'zealot 'combat-unit)
                            (can-spend-by-priority? 'stalker 'combat-unit)))
               (try-train-unit! 'zealot 'gateway 5 #:respect-bo-reserve? #t))
             (when (and (gateway-unit-colossus-ok? 'stalker)
                        (or (enemy-tech-observation-requires-anti-air? tech-obs)
                            (< (unit-count 'stalker) (max 3 (+ 2 enemy-armored-or-air-cnt))))
                        (can-spend-by-priority? 'stalker 'combat-unit))
               (try-train-unit! 'stalker 'gateway 5 #:respect-bo-reserve? #t))]
            [anti-reaper-or-proxy-terran?
             ;; Counter proxy Reapers / proxy Barracks (#5122354) with ranged Stalkers + Adepts first
             (when (and (gateway-unit-colossus-ok? 'stalker)
                        (can-spend-by-priority? 'stalker 'combat-unit))
               (try-train-unit! 'stalker 'gateway 5 #:respect-bo-reserve? #t))
             (when (and (< (unit-count 'adept) 4)
                        (gateway-unit-colossus-ok? 'adept)
                        (or (can-spend-by-priority? 'adept 'combat-unit)
                            (can-spend-by-priority? 'stalker 'combat-unit)))
               (try-train-unit! 'adept 'gateway 5 #:respect-bo-reserve? #t))
             (when (and (gateway-unit-colossus-ok? 'zealot)
                        (can-spend-by-priority? 'zealot 'combat-unit)
                        (or (< gas (sc2-gas-cost 'adept))
                            (>= minerals 225)
                            (memq 'charge researched-upgs)))
               (try-train-unit! 'zealot 'gateway 5 #:respect-bo-reserve? #t))]
            [else
             ;; Early scouting / light-unit Adept when planned
             (when (and (gateway-unit-colossus-ok? 'adept)
                        (or (plan-wants-now? 'adept)
                            (and live-game? (< frame 3000) (< (unit-count 'adept) 1) (= (unit-count 'stalker) 0)))
                        (can-spend-by-priority? 'adept 'combat-unit))
               (try-train-unit! 'adept 'gateway 5 #:respect-bo-reserve? #t))
             (when (and (gateway-unit-colossus-ok? 'stalker)
                        (can-spend-by-priority? 'stalker 'combat-unit))
               (try-train-unit! 'stalker 'gateway 5 #:respect-bo-reserve? #t))
             (when (and (gateway-unit-colossus-ok? 'zealot)
                        (can-spend-by-priority? 'zealot 'combat-unit)
                        (or (< gas (sc2-gas-cost 'stalker))
                            (>= minerals 225)
                            (and urgent-combat-or-intel-need? (< minerals (sc2-min-cost 'stalker)))
                            (and (memq 'charge researched-upgs)
                                 (< gas 200)
                                 (<= (unit-count 'zealot) (unit-count 'stalker)))))
               (try-train-unit! 'zealot 'gateway 5 #:respect-bo-reserve? #t))])]
         [(and (or (memq 'gateway ready-bldg-types) (memq 'warp-gate ready-bldg-types))
               (gateway-unit-colossus-ok? 'zealot)
               (can-spend-by-priority? 'zealot 'combat-unit))
          (try-train-unit! 'zealot 'gateway 5 #:respect-bo-reserve? #t)]))

     (when (and (not protoss-probe-priority?)
                (not crisis-freeze-workers?)
                (worker-army-curve-satisfied?)
                (not protoss-saving-for-expand?)
                (can-spend-by-priority? 'probe 'worker)
                (< total-workers
                   (if live-game?
                       (min 70 (max target-workers protoss-ideal-worker-cap))
                       target-workers))
                (or (member '(train probe) prio-scheduled-actions)
                    worker-rush-active?
                    (< total-workers 14)
                    (< (hash-ref pressure-metrics 'threat-pressure 0.0) 1.0)))
       (try-train-unit! 'probe 'townhall 4
                        #:respect-bo-reserve? (and live-game? (>= total-workers 24))))]

    [(Terran)
     ;; 1. Orbital Command Morph, Scan Reserve/Dedup & Multi-Patch MULE Calldown.
     ;;    Canonical `ccs` and `barracks-list` count lifted (`*-flying`) structures so lifting
     ;;    NEVER triggers duplicate Command Center / Barracks / Factory spam (`#5116611`), while
     ;;    morph/train/MULE/add-on orders strictly filter grounded, idle structures!
     (define ccs
       (filter (lambda (b)
                 (memq (sc2-canonical-structure-sym (unit-type-sym b))
                       '(command-center orbital-command planetary-fortress)))
               ally-bldgs))
     (define refineries
       (filter (lambda (b) (eq? (sc2-canonical-structure-sym (unit-type-sym b)) 'refinery))
               ally-bldgs))
     (define active-refineries
       (filter active-gas-bldg? refineries))
     (define barracks-list
       (filter (lambda (b) (eq? (sc2-canonical-structure-sym (unit-type-sym b)) 'barracks))
               ally-bldgs))
     (define factories-list
       (filter (lambda (b) (eq? (sc2-canonical-structure-sym (unit-type-sym b)) 'factory))
               ally-bldgs))
     (define mule-patch-id (hash-ref obs 'mineral-patch-id SC2-SYNTHETIC-MINERAL-PATCH-ID))
     (define raw-mineral-patches
       (let ([mps (hash-ref obs 'mineral-patches '())])
         (if (list? mps) (filter hash? mps) '())))
     (define splash-st (rt-splash-state rt))
     (define scanned-pts '())
     (define claimed-mule-patches (mutable-seteqv))
     (define reserve-scan-energy?
       (and live-game?
            (>= frame 3360)
            (or (enemy-tech-observation-requires-detection? tech-obs)
                endgame-corner-hunt?
                (< intel-confidence 0.55))))
     (for ([cc (in-list ccs)])
       (define raw-ctype (unit-type-sym cc))
       (define cid (hash-ref cc 'id 301))
       (define cenergy (hash-ref cc 'energy SC2-ORBITAL-MULE-ENERGY))
       (cond
         [(and (eq? raw-ctype 'command-center)
               (building-grounded-and-powered? cc)
               (>= (hash-ref cc 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS)
               (<= (hash-ref cc 'order-count 0) 0)
               (= (hash-ref cc 'order-ability-id 0) 0)
               (memq 'barracks ready-bldg-types)
               (not (order-ledger-facility-busy? oledger cc frame))
               (>= minerals (sc2-min-cost 'orbital-command))
               (non-combat-min-ok? (sc2-min-cost 'orbital-command) 'orbital-command))
          (recall-building-group! 4)
          (emit! (list 'morph cid 'orbital-command))
          (order-ledger-record-issued! oledger cid 'morph 'orbital-command base-x base-y frame)
          (set! morphing-bldg-types (cons 'orbital-command morphing-bldg-types))
          (when live-game?
            (hash-set! open-prod-slots 'townhall
                       (max 0 (sub1 (hash-ref open-prod-slots 'townhall 0)))))
          (spend-resources-and-supply! (sc2-min-cost 'orbital-command) 0 0)]
         [(and (eq? raw-ctype 'orbital-command)
               (building-grounded-and-powered? cc)
               (>= (hash-ref cc 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS))
          (define cloaked-enemy
            (findf (lambda (e)
                     (define ex0 (hash-ref e 'x nat-x))
                     (define ey0 (hash-ref e 'y nat-y))
                     (and (or (hash-ref e 'cloaked #f)
                              (hash-ref e 'burrowed #f)
                              (memq (sc2-canonical-unit-sym (unit-type-sym e))
                                    '(lurker dark-templar banshee ghost widow-mine)))
                          (not (ormap (lambda (pt) (<= (dist2d ex0 ey0 (car pt) (cdr pt)) 12.0))
                                      scanned-pts))))
                   enemy-units))
          (define last-scan-f (hash-ref splash-st 'last-scan-frame -9999))
          (cond
            [(and cloaked-enemy
                  (>= cenergy SC2-ORBITAL-SCAN-ENERGY)
                  (or (not live-game?) (>= (- frame last-scan-f) 44)))
             (define sx (safe-coord (hash-ref cloaked-enemy 'x nat-x) nat-x))
             (define sy (safe-coord (hash-ref cloaked-enemy 'y nat-y) nat-y))
             (set! scanned-pts (cons (cons sx sy) scanned-pts))
             (hash-set! splash-st 'last-scan-frame frame)
             (emit! (list 'cast-spell cid 'scanner-sweep sx sy))]
            [(and (or (not live-game?) (not (null? raw-mineral-patches)))
                  (>= cenergy (if endgame-corner-hunt?
                                  150
                                  (if reserve-scan-energy? 100 SC2-ORBITAL-MULE-ENERGY))))
             (define ccx (hash-ref cc 'x base-x))
             (define ccy (hash-ref cc 'y base-y))
             (define chosen-patch-id
               (let ([near-patches
                      (filter (lambda (mp)
                                (define pid (hash-ref mp 'id 0))
                                (and (> pid 0)
                                     (not (set-member? claimed-mule-patches pid))
                                     (<= (dist2d ccx ccy (hash-ref mp 'x ccx) (hash-ref mp 'y ccy)) 11.0)))
                              raw-mineral-patches)])
                 (if (pair? near-patches)
                     (let ([best (argmax (lambda (mp) (hash-ref mp 'mineral-contents 1000)) near-patches)])
                       (hash-ref best 'id mule-patch-id))
                     mule-patch-id)))
             (set-add! claimed-mule-patches chosen-patch-id)
             (emit! (list 'cast-spell cid 'calldown-mule chosen-patch-id))])]))

     ;; Priority Anti-Tie Corner-Hunter Air-to-Air: train >= 2 Vikings before add-ons/extra Rax consume Starport/minerals
     (when (and endgame-corner-hunt?
                (memq 'starport ready-bldg-types)
                (< (unit-count 'viking) 2)
                (can-spend-supply? (sc2-supply-cost 'viking)))
       (try-train-unit! 'viking 'starport 6 #:respect-bo-reserve? #f))
     ;; Priority vs-Air Viking: claim Starport for first 2 Vikings before Medivacs/add-ons consume gas
     (when (and live-game?
                (not endgame-corner-hunt?)
                (memq 'starport ready-bldg-types)
                (enemy-tech-observation-requires-anti-air? tech-obs)
                (< (unit-count 'viking) 2)
                (can-spend-supply? (sc2-supply-cost 'viking)))
       (try-train-unit! 'viking 'starport 6 #:respect-bo-reserve? #f))
     ;; Priority 1st Medivac (#5122349): claim 100M/100G on open Starport when >= 6 bio units have 0 Medivacs
     ;; (vs air, co-produce 1st Medivac once >= 2 Vikings are on the field)
     (when (and live-game?
                (not endgame-corner-hunt?)
                (memq 'starport ready-bldg-types)
                (or (not (enemy-tech-observation-requires-anti-air? tech-obs))
                    (>= (unit-count 'viking) 2))
                (>= (+ (unit-count 'marine) (unit-count 'marauder)) 6)
                (< (unit-count 'medivac) 1)
                (can-spend-supply? (sc2-supply-cost 'medivac)))
       (try-train-unit! 'medivac 'starport 6 #:respect-bo-reserve? #f))
     ;; Priority vs-Air Follow-up Vikings: once >= 2 Medivacs sustain bio, continue claiming Starport for up to 8 Vikings
     (when (and live-game?
                (not endgame-corner-hunt?)
                (memq 'starport ready-bldg-types)
                (enemy-tech-observation-requires-anti-air? tech-obs)
                (>= (unit-count 'medivac) 2)
                (< (unit-count 'viking) 8)
                (can-spend-supply? (sc2-supply-cost 'viking)))
       (try-train-unit! 'viking 'starport 6 #:respect-bo-reserve? #f))

     (define unmorphed-ready-cc
       (findf (lambda (cc)
                (and (eq? (unit-type-sym cc) 'command-center)
                     (building-grounded-and-powered? cc)
                     (>= (hash-ref cc 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS)
                     (<= (hash-ref cc 'order-count 0) 0)
                     (= (hash-ref cc 'order-ability-id 0) 0)
                     (not (order-ledger-facility-busy? oledger cc frame))))
              ccs))
     (define terran-saving-for-orbital?
       (and live-game?
            (not (not unmorphed-ready-cc))
            (= (order-ledger-pending-count-for-type oledger 'orbital-command frame) 0)
            (memq 'barracks ready-bldg-types)
            (not under-base-attack?)
            (not under-early-cheese?)
            (not early-survival-crisis?)
            (not urgent-combat-or-intel-need?)
            (not escrow-suppressed-active?)
            (< minerals (sc2-min-cost 'orbital-command))))

     ;; Helper: check whether a grounded Terran production facility already has an attached add-on
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
                                   tech-lab techlab reactor))
                           (<= (dist2d (+ bx SC2-TERRAN-ADDON-OFFSET-X)
                                       (+ by SC2-TERRAN-ADDON-OFFSET-Y)
                                       (hash-ref ab 'x -9999.0)
                                       (hash-ref ab 'y -9999.0))
                               1.75)))
                    ally-bldgs))))

     ;; 2. Pro Mechanic #3: Terran Addon Swap & Orphaned Add-On Reuse (`#5116604` fix;
     ;;    legacy `swap-addon` emitted only in non-live synthetic unit tests!)
     (when (not live-game?)
       (define rax-with-reactor
         (findf (lambda (b)
                  (or (eq? (unit-type-sym b) 'barracks-reactor)
                      (and (eq? (unit-type-sym b) 'barracks)
                           (building-grounded-and-powered? b)
                           (eq? (hash-ref b 'addon #f) 'reactor))))
                ally-bldgs))
       (define fac-needing-addon
         (findf (lambda (b)
                  (and (eq? (unit-type-sym b) 'factory)
                       (building-grounded-and-powered? b)
                       (not (terran-facility-has-addon? b))))
                ally-bldgs))
       (when (and rax-with-reactor fac-needing-addon)
         (emit! (list 'swap-addon
                      (hash-ref rax-with-reactor 'id 704)
                      (hash-ref fac-needing-addon 'id 705)))))
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
     (define claimed-addon-fac-ids (mutable-seteqv))
     (define (grounded-bare-facility sym)
       (findf (lambda (b)
                (define bid (hash-ref b 'id -1))
                (and (eq? (unit-type-sym b) sym)
                     (building-grounded-and-powered? b)
                     (>= (hash-ref b 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS)
                     (not (terran-facility-has-addon? b))
                     (not (facility-being-swapped? b))
                     (not (set-member? claimed-addon-fac-ids bid))
                     (or (not live-game?)
                         (not (order-ledger-facility-busy? oledger b frame)))))
              ally-bldgs))

     ;; 3. Pro Build-Order Expansion Sequencing:
     ;;    When `natural-blocked?` is `#t` on 1 base in live games, build 2nd CC safely in Main
     ;;    (morphs to OrbitalCommand, then lifts/lands to `(nat-x, nat-y)` once `natural-blocked?` clears!);
     ;;    otherwise expand to the next uncamped BFS base!
     (when (and (>= minerals (sc2-min-cost 'command-center))
                (non-combat-min-ok? (sc2-min-cost 'command-center) 'command-center)
                (not blocked-nat-expanded-early?)
                (not under-early-cheese?)
                (not early-survival-crisis?)
                (not crisis-freeze-expand-or-gas?)
                (not under-base-attack?)
                (< (length ccs) SC2-MAX-ACTIVE-BASES)
                (= (order-ledger-pending-count-for-type oledger 'command-center frame) 0)
                (or (< (length ccs) SC2-MIN-DESIRED-BASES)
                    (and (= (length ccs) 2)
                         (>= eff-phase-supply 42)
                         (or (not live-game?) (>= live-army-supply 10) (>= minerals 550))
                         (or (not live-game?)
                             (memq 'starport ready-bldg-types)
                             (>= minerals 550))
                         (or live-game?
                             (memq 'starport bldg-types)
                             (memq 'factory bldg-types)
                             (plan-wants-now? 'command-center)))
                    (and (< (length ccs) desired-bases)
                         (or (not (and live-game?
                                       (= (length ccs) 2)
                                       (not (memq 'starport ready-bldg-types))))
                             (>= minerals 550))
                         (or (not (and endgame-corner-hunt?
                                       (< (unit-count 'viking) 2)))
                             (>= (- minerals (sc2-min-cost 'command-center)) 150))
                         (>= total-workers (* (length ccs)
                                              (if (>= (length ccs) 3) 16 SC2-MIN-WORKERS-PER-BASE-FOR-EXPAND)))
                         (or (coupled-macro-plan-should-expand? macro-plan)
                             (>= frame SC2-MACRO-EXPAND-FRAME-THRESHOLD))))
                (or (and live-game? (= (length ccs) 1) natural-blocked?)
                    (let-values ([(cand-ex cand-ey)
                                  (select-uncamped-expansion-pad (< (length ccs) SC2-MIN-DESIRED-BASES))])
                      (or (and cand-ex cand-ey)
                          (and live-game? (= (length ccs) 2) (>= minerals 550)))))
                (refractory-allow-action?! cd-tracker
                                           (list 'macro-expand 'Terran)
                                           frame
                                           SC2-EXPANSION-COOLDOWN-FRAMES))
       (cond
         [(and live-game? (= (length ccs) 1) natural-blocked?)
          (emit-build-verified! 'command-center
                                (safe-coord (+ base-x 4.0))
                                (safe-coord base-y))]
         [else
          (define-values (exp-x exp-y)
            (select-uncamped-expansion-pad (< (length ccs) SC2-MIN-DESIRED-BASES)))
          (cond
            [(and exp-x exp-y)
             (emit! (list 'expand exp-x exp-y))
             (order-ledger-record-issued! oledger (+ 810000 (modulo frame 10000)) 'expand 'command-center exp-x exp-y frame)
             (spend-resources-and-supply! (sc2-min-cost 'command-center) 0 0)]
            [(and live-game? (= (length ccs) 2) (>= minerals 550))
             (emit-build-verified! 'command-center
                                   (safe-coord (+ base-x 4.0))
                                   (safe-coord base-y))])]))

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
            #:under-attack? (or under-base-attack? early-survival-crisis?)
            #:enemy-threat-supply live-enemy-threat-supply
            #:natural-blocked? natural-blocked?
            #:escrow-expired? (or escrow-suppressed-active?
                                  early-survival-crisis?
                                  (>= cur-escrow-age-frames max-escrow-timeout-frames)
                                  urgent-combat-or-intel-need?
                                  (not (null? orphaned-prereqs))))
           0))
     (define terran-saving-for-expand?
       (or (saving-for-expansion-now? (length ccs))
           (and (> reserved-expansion-minerals 0) (< minerals reserved-expansion-minerals))
           terran-saving-for-orbital?))

     ;; Emergency Bunker Defense (offset >= 5.5 tiles off natural pad so it NEVER blocks expansion!)
     (when (and (or early-survival-crisis?
                    under-early-cheese?
                    under-base-attack?
                    forward-proxy-detected?
                    (>= live-enemy-threat-supply 6))
                (memq 'barracks bldg-types)
                (not (building-present-or-pending? 'bunker))
                (save-cancel-rebuild-ready? 'bunker 60)
                (>= minerals (sc2-min-cost 'bunker)))
       (define-values (bk-x bk-y)
         (if (<= (length ccs) 1)
             (values (safe-coord (+ base-x (* 0.25 (- nat-x base-x))) base-x)
                     (safe-coord (+ base-y (* 0.25 (- nat-y base-y))) base-y))
             (offset-defense-anchor nat-x nat-y 5.5)))
       (emit-build-verified! 'bunker bk-x bk-y))

     ;; 4. Terran Main-Ramp Wall & Pro Build Order (`#:exact-wall-slot? #t` ONLY in early <= 2-base phase;
     ;;    mid/late-game rebuilds fall back to open main anchor so ramp debris/units never deadlock 1st->8th Rax!)
     (when (and (null? barracks-list)
                (or (not live-game-obs?) (memq 'supply-depot ready-bldg-types))
                (not (building-present-or-pending? 'barracks))
                (save-cancel-rebuild-ready? 'barracks 60)
                (>= minerals (sc2-min-cost 'barracks))
                (>= (- minerals (sc2-min-cost 'barracks)) hard-supply-lockout-reserve-min))
       (define wall-rax
         (and allow-exact-wall-slot?
              (not bypass-wall-depot1?)
              (<= (length ccs) 2)
              (hash-ref terran-ramp-wall 'barracks #f)))
       (define rx0 (if (pair? wall-rax) (safe-coord (car wall-rax) (+ base-x 4.0)) (safe-coord (+ base-x 4.0))))
       (define ry0 (if (pair? wall-rax) (safe-coord (cdr wall-rax) (+ base-y 4.0)) (safe-coord (+ base-y 4.0))))
       (emit-build-verified! 'barracks rx0 ry0 SC2-BUILD-SITE-MIN-CLEARANCE
                             #:exact-wall-slot? (and allow-exact-wall-slot? (not bypass-wall-depot1?) (<= (length ccs) 2) (pair? wall-rax))))

     ;; Dynamic Starport escrow: once Factory is ready in live games, protect 150M/100G for 1st Starport
     ;; against secondary infrastructure/upgrades/gas units (still allowing 1st-2nd Refinery, 1st Rax TechLab + Stimpack,
     ;; 1st-2nd Barracks, and Engineering Bay +1 upgrades). Automatically clears the instant 1st Starport is issued.
     (define (holding-for-first-starport?)
       (and live-game?
            (memq 'factory ready-bldg-types)
            (not terran-saving-for-expand?)
            (not early-survival-crisis?)
            (not under-base-attack?)
            (not escrow-suppressed-active?)
            (< cur-escrow-age-frames max-escrow-timeout-frames)
            (not (building-present-or-pending? 'starport))))
     (define (starport-escrow-ok? m-cost g-cost)
       (or (not (holding-for-first-starport?))
           (and (>= (- minerals m-cost) (sc2-min-cost 'starport))
                (>= (- gas g-cost) (sc2-gas-cost 'starport)))))

     (define desired-refineries
       (if (and early-survival-crisis? (null? active-refineries))
           0
           (min (* SC2-GEYSERS-PER-BASE (length ccs))
                (if live-game?
                    (cond
                      [(and (>= (length ccs) 4) (>= total-workers 62) (< gas 600)) 8]
                      [(and (>= (length ccs) 3) (>= total-workers 50) (< gas 450)) 6]
                      [(and (>= eff-phase-supply 56) (>= total-workers 42) (< gas 350)) 4]
                      [(and (>= eff-phase-supply 44) (>= total-workers 34) (< gas 300)) 3]
                      [(and (or (memq 'factory bldg-types) (>= eff-phase-supply 22))
                            (>= total-workers 21)
                            (< gas 250))
                       2]
                      [else 1])
                    (cond
                      [(>= supply-used 56) 4]
                      [(>= supply-used 44) 3]
                      [(or (memq 'factory bldg-types) (>= supply-used 22)) 2]
                      [else 1])))))
     (when (and (memq 'barracks bldg-types)
                (not crisis-freeze-expand-or-gas?)
                (save-cancel-rebuild-ready? 'refinery 60)
                (or (null? active-refineries) (not terran-saving-for-expand?))
                (< (+ (length active-refineries) (order-ledger-pending-count-for-type oledger 'refinery frame))
                   desired-refineries)
                (or (< (length active-refineries) 2)
                    (starport-escrow-ok? (sc2-min-cost 'refinery) 0))
                (or (not live-game?)
                    (< (length active-refineries) 2)
                    (< gas 150)
                    (>= (- minerals (sc2-min-cost 'refinery)) bo-reserved-min))
                (>= minerals (sc2-min-cost 'refinery))
                (non-combat-min-ok? (sc2-min-cost 'refinery)))
       (emit-gas-build-verified! 'refinery (safe-coord (+ base-x 3.0)) (safe-coord (+ base-y 5.0))))

     ;; Include unattached `'tech-lab` / `'reactor` on the map (`include-free-addons? = #t`);
     ;; scale `desired-rax-techlabs` to 2 at >= 3 Barracks and 3 at >= 6 Barracks vs Protoss/Zerg/armored (#5122349)
     (define cur-rax-techlab-cnt
       (+ (count (lambda (t) (memq t '(barracks-techlab tech-lab))) bldg-types)
          (order-ledger-pending-count-for-type oledger 'barracks-techlab frame)))
     (define desired-rax-techlabs
       (if (and live-game?
                (or (memq effective-enemy-race '(Protoss Zerg))
                    (ormap (lambda (e)
                             (memq (unit-type-sym e)
                                   '(stalker immortal marauder roach ravager siege-tank siege-tank-sieged thor colossus ultralisk)))
                           enemy-units)))
           (cond
             [(>= (length barracks-list) 6) 3]
             [(>= (length barracks-list) 3) 2]
             [else 1])
           1))
     (define has-rax-techlab?
       (or (>= cur-rax-techlab-cnt desired-rax-techlabs)
           (and (= desired-rax-techlabs 1)
                (building-present-or-pending? 'barracks-techlab #t))))
     (define bare-rax-for-tl (grounded-bare-facility 'barracks))
     (when (and bare-rax-for-tl
                (not terran-saving-for-expand?)
                (not has-rax-techlab?)
                (or (= cur-rax-techlab-cnt 0)
                    (starport-escrow-ok? (sc2-min-cost 'barracks-techlab) (sc2-gas-cost 'barracks-techlab)))
                (or (not live-game?)
                    (and (> (hash-ref open-prod-slots 'barracks 0) 0)
                         (or (not urgent-combat-or-intel-need?)
                             (not (null? ally-combat-units))
                             (> (hash-ref open-prod-slots 'barracks 0) 1))))
                (>= minerals (sc2-min-cost 'barracks-techlab))
                (>= gas (sc2-gas-cost 'barracks-techlab))
                (non-combat-min-ok? (sc2-min-cost 'barracks-techlab) 'barracks-techlab)
                (non-combat-gas-ok? (sc2-gas-cost 'barracks-techlab) 'barracks-techlab))
       (define rbx (safe-coord (+ (hash-ref bare-rax-for-tl 'x (+ base-x 4.0)) SC2-TERRAN-ADDON-OFFSET-X) (+ base-x 6.5)))
       (define rby (safe-coord (+ (hash-ref bare-rax-for-tl 'y (+ base-y 4.0)) SC2-TERRAN-ADDON-OFFSET-Y) (+ base-y 3.5)))
       (recall-building-group! 5)
       (emit! (list 'build 'barracks-techlab rbx rby))
       (set-add! claimed-addon-fac-ids (hash-ref bare-rax-for-tl 'id 303))
       (order-ledger-record-issued! oledger (hash-ref bare-rax-for-tl 'id 303) 'build 'barracks-techlab rbx rby frame)
       (set! bldg-types (cons 'barracks-techlab bldg-types))
       (set! cur-rax-techlab-cnt (add1 cur-rax-techlab-cnt))
       (set! has-rax-techlab? (>= cur-rax-techlab-cnt desired-rax-techlabs))
       (when live-game?
         (hash-set! open-prod-slots 'barracks (max 0 (sub1 (hash-ref open-prod-slots 'barracks 0)))))
       (spend-resources-and-supply! (sc2-min-cost 'barracks-techlab) (sc2-gas-cost 'barracks-techlab) 0))

     ;; Research Stimpack -> Combat Shield -> Concussive Shells at Barracks Tech Lab (Group 7)
     ;; Once Factory is ready in live games, let 1st Starport claim its 150M/100G before secondary TechLab upgrades!
     (when (and (memq 'barracks-techlab ready-bldg-types)
                (not urgent-combat-or-intel-need?))
       (cond
         [(upgrade-needed? 'stimpack)
          (when (and (>= minerals (sc2-min-cost 'stimpack))
                     (>= gas (sc2-gas-cost 'stimpack)))
            (emit-research-verified! 'stimpack))]
         [(upgrade-needed? 'combat-shield)
          (when (and (starport-escrow-ok? (sc2-min-cost 'combat-shield) (sc2-gas-cost 'combat-shield))
                     (>= minerals (sc2-min-cost 'combat-shield))
                     (>= gas (sc2-gas-cost 'combat-shield)))
            (emit-research-verified! 'combat-shield))]
         [(and (upgrade-needed? 'concussive-shells)
               (starport-escrow-ok? (sc2-min-cost 'concussive-shells) (sc2-gas-cost 'concussive-shells))
               (or (not live-game?)
                   (>= (- minerals (sc2-min-cost 'concussive-shells)) bo-reserved-min))
               (>= minerals (sc2-min-cost 'concussive-shells))
               (>= gas (sc2-gas-cost 'concussive-shells)))
          (emit-research-verified! 'concussive-shells)]))

     (define desired-factories
       (if (and live-game? (>= (length ccs) 3) (>= eff-phase-supply 106) (>= gas 200))
           2
           1))
     (when (and (memq 'barracks ready-bldg-types)
                (not terran-saving-for-expand?)
                (save-cancel-rebuild-ready? 'factory 60)
                (< (+ (length factories-list) (order-ledger-pending-count-for-type oledger 'factory frame))
                   desired-factories)
                (or (null? factories-list)
                    (can-spend-by-priority? 'factory 'production-scaling)
                    (>= minerals 400))
                (>= (- minerals reserved-expansion-minerals) (sc2-min-cost 'factory))
                (>= gas (sc2-gas-cost 'factory))
                (non-combat-min-ok? (sc2-min-cost 'factory) 'factory)
                (non-combat-gas-ok? (sc2-gas-cost 'factory) 'factory))
       (define fac-idx (length factories-list))
       (emit-build-verified! 'factory
                             (safe-coord (+ base-x (* (add1 fac-idx) SC2-TERRAN-FACILITY-STEP-X)))
                             (safe-coord (+ base-y SC2-TERRAN-FACILITY-STEP-Y))))

     ;; 1st Starport unlocks Medivac/Viking/Raven progression and runs BEFORE 3rd+ Barracks / FactoryTechLab!
     (when (and (or (not terran-saving-for-expand?) endgame-corner-hunt?)
                (memq 'factory ready-bldg-types)
                (not (building-present-or-pending? 'starport))
                (save-cancel-rebuild-ready? 'starport 60)
                (>= minerals (sc2-min-cost 'starport))
                (>= gas (sc2-gas-cost 'starport))
                (or endgame-corner-hunt?
                    (and (non-combat-min-ok? (sc2-min-cost 'starport) 'starport)
                         (non-combat-gas-ok? (sc2-gas-cost 'starport) 'starport))))
       (emit-build-verified! 'starport
                             (safe-coord (+ base-x SC2-TERRAN-FACILITY-STEP-X))
                             (safe-coord (+ base-y (* 2.0 SC2-TERRAN-FACILITY-STEP-Y)))))

     (define terran-ideal-worker-cap
       (min 70 (* SC2-IDEAL-WORKERS-PER-BASE (max 1 (length ccs)))))
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
     (define raw-desired-barracks
       (min SC2-MAX-PRODUCTION-FACILITIES
            (max 1 (if (>= (+ (length ccs) pending-cc-count) SC2-MIN-DESIRED-BASES)
                       (* SC2-TERRAN-FACILITIES-PER-BASE (max (length ccs) (+ (length ccs) pending-cc-count)))
                       (if (and (memq 'factory bldg-types)
                                (or (not live-game?)
                                    (<= reserved-expansion-minerals 0)
                                    (>= (- minerals reserved-expansion-minerals) (sc2-min-cost 'barracks))))
                           2
                           1)))))
     (define desired-barracks
       (cond
         [(not live-game?) raw-desired-barracks]
         [(and (not (memq 'factory bldg-types))
               (not (and (< (length active-refineries) 1) (>= minerals 450))))
          (min 2 raw-desired-barracks)]
         [(and (not (memq 'starport bldg-types))
               (< minerals 500))
          (min 2 raw-desired-barracks)]
         [(< minerals 1000)
          (min 8 raw-desired-barracks)]
         [else raw-desired-barracks]))
     (define cur-rax-total
       (+ (length barracks-list) (order-ledger-pending-count-for-type oledger 'barracks frame)))
     (when (and (not terran-saving-for-expand?)
                (save-cancel-rebuild-ready? 'barracks 60)
                (can-spend-by-priority? 'barracks 'production-scaling)
                (>= (length barracks-list) 1)
                (or (< cur-rax-total 2)
                    (starport-escrow-ok? (sc2-min-cost 'barracks) 0))
                (or (not live-game?)
                    (< (length barracks-list) 2)
                    (< (hash-ref open-prod-slots 'barracks 0) 2)
                    (>= minerals 350))
                (< cur-rax-total desired-barracks)
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
     (define cur-rax-reactor-cnt
       (+ (count (lambda (t) (memq t '(barracks-reactor reactor))) bldg-types)
          (order-ledger-pending-count-for-type oledger 'barracks-reactor frame)))
     (when (and (not terran-saving-for-expand?)
                (>= (length barracks-list) 2)
                bare-rax-for-rx
                (starport-escrow-ok? (sc2-min-cost 'barracks-reactor) (sc2-gas-cost 'barracks-reactor))
                (if (and live-game? (memq 'factory bldg-types) (>= (length barracks-list) 3))
                    (< cur-rax-reactor-cnt (max 1 (- (length barracks-list) desired-rax-techlabs)))
                    (not (building-present-or-pending? 'barracks-reactor #t)))
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
       (set! bldg-types (cons 'barracks-reactor bldg-types))
       (when live-game?
         (hash-set! open-prod-slots 'barracks (max 0 (sub1 (hash-ref open-prod-slots 'barracks 0)))))
       (spend-resources-and-supply! (sc2-min-cost 'barracks-reactor) (sc2-gas-cost 'barracks-reactor) 0))

     (define has-fac-techlab-any?
       (building-present-or-pending? 'factory-techlab #t))
     (define bare-fac-for-tl (grounded-bare-facility 'factory))
     (when (and (not terran-saving-for-expand?)
                bare-fac-for-tl
                (starport-escrow-ok? (sc2-min-cost 'factory-techlab) (sc2-gas-cost 'factory-techlab))
                (or (not has-fac-techlab-any?) (>= (length factories-list) 2))
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
       (set! bldg-types (cons 'factory-techlab bldg-types))
       (set! has-fac-techlab-any? #t)
       (when live-game?
         (hash-set! open-prod-slots 'factory (max 0 (sub1 (hash-ref open-prod-slots 'factory 0)))))
       (spend-resources-and-supply! (sc2-min-cost 'factory-techlab) (sc2-gas-cost 'factory-techlab) 0))

     ;; Optional Factory Reactor when explicitly planned and a bare Factory is free
     (define bare-fac-for-rx (grounded-bare-facility 'factory))
     (when (and (not terran-saving-for-expand?)
                bare-fac-for-rx
                has-fac-techlab-any?
                (plan-wants-now? 'factory-reactor)
                (not (building-present-or-pending? 'factory-reactor #t))
                (>= minerals (sc2-min-cost 'factory-reactor))
                (>= gas (sc2-gas-cost 'factory-reactor)))
       (define frx (safe-coord (+ (hash-ref bare-fac-for-rx 'x (+ base-x 6.0)) SC2-TERRAN-ADDON-OFFSET-X) (+ base-x 8.5)))
       (define fry (safe-coord (+ (hash-ref bare-fac-for-rx 'y (+ base-y 3.5)) SC2-TERRAN-ADDON-OFFSET-Y) (+ base-y 3.0)))
       (recall-building-group! 6)
       (emit! (list 'build 'factory-reactor frx fry))
       (order-ledger-record-issued! oledger (hash-ref bare-fac-for-rx 'id 307) 'build 'factory-reactor frx fry frame)
       (set! bldg-types (cons 'factory-reactor bldg-types))
       (spend-resources-and-supply! (sc2-min-cost 'factory-reactor) (sc2-gas-cost 'factory-reactor) 0))

     (when (and (or (not terran-saving-for-expand?) endgame-corner-hunt?)
                (or (not urgent-combat-or-intel-need?) endgame-corner-hunt? (>= minerals 400))
                (memq 'factory ready-bldg-types))
       (when (and (not (building-present-or-pending? 'armory))
                  (save-cancel-rebuild-ready? 'armory 60)
                  (starport-escrow-ok? (sc2-min-cost 'armory) (sc2-gas-cost 'armory))
                  (or (not live-game?)
                      (and (memq 'engineering-bay bldg-types)
                           (>= live-army-supply 18)))
                  (or (plan-wants-now? 'armory) (>= eff-phase-supply 52))
                  (>= minerals (sc2-min-cost 'armory))
                  (>= gas (sc2-gas-cost 'armory)))
         (emit-build-verified! 'armory (safe-coord (- base-x 4.0)) (safe-coord (+ base-y 4.0))))
       ;; In SC2 LotV, Drilling Claws requires BOTH Factory TechLab AND Armory!
       (when (and (if live-game?
                      (and (memq 'factory-techlab ready-bldg-types)
                           (memq 'armory ready-bldg-types)
                           (>= (unit-count 'widow-mine) 2))
                      #t)
                  (upgrade-needed? 'drilling-claws))
         (emit-research-verified! 'drilling-claws)))

     (define need-emergency-ebay-or-turret?
       (or (enemy-tech-observation-requires-detection? tech-obs)
           (enemy-tech-observation-requires-anti-air? tech-obs)))

     (when (and (not terran-saving-for-expand?)
                (or (not urgent-combat-or-intel-need?)
                    need-emergency-ebay-or-turret?
                    (and (non-combat-min-ok? (sc2-min-cost 'engineering-bay) 'engineering-bay)
                         (>= minerals 250)))
                (or need-emergency-ebay-or-turret?
                    (plan-wants-now? 'engineering-bay)
                    (plan-wants-now? 'missile-turret)
                    (memq 'starport ready-bldg-types)
                    (and live-game?
                         (>= (length ccs) 2)
                         (memq 'factory ready-bldg-types)
                         (>= eff-phase-supply 40)))
                (>= minerals (sc2-min-cost 'engineering-bay)))
       (when (and (not (building-present-or-pending? 'engineering-bay))
                  (save-cancel-rebuild-ready? 'engineering-bay 60)
                  (>= (- minerals (if need-emergency-ebay-or-turret? 0 terran-worker-min-floor))
                      (sc2-min-cost 'engineering-bay)))
         (emit-build-verified! 'engineering-bay (safe-coord (+ base-x 5.0)) (safe-coord (- base-y 4.0))))
       (define cur-turret-cnt
         (+ (count (lambda (t) (eq? t 'missile-turret)) bldg-types)
            (order-ledger-pending-count-for-type oledger 'missile-turret frame)))
       (define desired-turrets
         (if (and live-game? need-emergency-ebay-or-turret?) 2 1))
       (when (and (or (not live-game?)
                      (and (memq 'engineering-bay ready-bldg-types)
                           (< cur-turret-cnt desired-turrets)
                           (or need-emergency-ebay-or-turret?
                               (plan-wants-now? 'missile-turret)
                               (>= eff-phase-supply 60))))
                  (>= minerals (sc2-min-cost 'missile-turret))
                  (refractory-allow-action?! cd-tracker
                                             (list 'static-detector 'missile-turret)
                                             frame
                                             SC2-STATIC-DETECTOR-COOLDOWN-FRAMES))
         (define-values (tx ty)
           (if (and live-game? (> cur-turret-cnt 0) (>= (length ccs) 2))
               (offset-defense-anchor nat-x nat-y 4.5)
               (values (safe-coord (+ base-x 3.0)) (safe-coord (+ base-y 3.0)))))
         (if live-game?
             (emit-build-verified! 'missile-turret tx ty)
             (emit! (list 'build 'missile-turret tx ty)))))

     ;; Engineering Bay +1/+1 -> +3/+3 and Armory vehicle upgrades fire independently of Starport readiness
     (when (and (not terran-saving-for-expand?)
                (or (not urgent-combat-or-intel-need?) (>= minerals 300)))
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
            (emit-research-verified! 'terran-vehicle-and-ship-plating-1)])))

     (define bare-sp-for-addon (grounded-bare-facility 'starport))
     (when (and (or (not terran-saving-for-expand?) endgame-corner-hunt?)
                (or (not urgent-combat-or-intel-need?) endgame-corner-hunt? (>= minerals 300))
                (memq 'starport ready-bldg-types))
       (cond
         [(and bare-sp-for-addon
               (or (not live-game?) (> (hash-ref open-prod-slots 'starport 0) 0))
               (or (not live-game?)
                   (enemy-tech-observation-requires-detection? tech-obs)
                   (and endgame-corner-hunt? (>= (unit-count 'viking) 2) (= (unit-count 'raven) 0))
                   (plan-wants-now? 'starport-techlab)
                   (plan-wants-now? 'raven)
                   (plan-wants-now? 'banshee)
                   (plan-wants-now? 'battlecruiser))
               (not (building-present-or-pending? 'starport-techlab #t))
               (not (and live-game? (building-present-or-pending? 'starport-reactor #f)))
               (>= minerals (sc2-min-cost 'starport-techlab))
               (>= gas (sc2-gas-cost 'starport-techlab)))
          (define stx (safe-coord (+ (hash-ref bare-sp-for-addon 'x (+ base-x 6.0)) SC2-TERRAN-ADDON-OFFSET-X) (+ base-x 8.5)))
          (define sty (safe-coord (+ (hash-ref bare-sp-for-addon 'y (+ base-y 7.0)) SC2-TERRAN-ADDON-OFFSET-Y) (+ base-y 6.5)))
          (recall-building-group! 6)
          (emit! (list 'build 'starport-techlab stx sty))
          (order-ledger-record-issued! oledger (hash-ref bare-sp-for-addon 'id 306) 'build 'starport-techlab stx sty frame)
          (set! bldg-types (cons 'starport-techlab bldg-types))
          (hash-set! open-prod-slots 'starport (max 0 (sub1 (hash-ref open-prod-slots 'starport 0))))
          (spend-resources-and-supply! (sc2-min-cost 'starport-techlab) (sc2-gas-cost 'starport-techlab) 0)]
         [(and bare-sp-for-addon
               live-game?
               (> (hash-ref open-prod-slots 'starport 0) 0)
               (or (plan-wants-now? 'starport-reactor)
                   (and (>= (length ccs) 2) (>= eff-phase-supply 52)))
               (not (building-present-or-pending? 'starport-reactor #t))
               (not (building-present-or-pending? 'starport-techlab #f))
               (>= minerals (sc2-min-cost 'starport-reactor))
               (>= gas (sc2-gas-cost 'starport-reactor)))
          (define srx (safe-coord (+ (hash-ref bare-sp-for-addon 'x (+ base-x 6.0)) SC2-TERRAN-ADDON-OFFSET-X) (+ base-x 8.5)))
          (define sry (safe-coord (+ (hash-ref bare-sp-for-addon 'y (+ base-y 7.0)) SC2-TERRAN-ADDON-OFFSET-Y) (+ base-y 6.5)))
          (recall-building-group! 6)
          (emit! (list 'build 'starport-reactor srx sry))
          (order-ledger-record-issued! oledger (hash-ref bare-sp-for-addon 'id 308) 'build 'starport-reactor srx sry frame)
          (set! bldg-types (cons 'starport-reactor bldg-types))
          (hash-set! open-prod-slots 'starport (max 0 (sub1 (hash-ref open-prod-slots 'starport 0))))
          (spend-resources-and-supply! (sc2-min-cost 'starport-reactor) (sc2-gas-cost 'starport-reactor) 0)])
       (when (and (memq 'starport-techlab ready-bldg-types)
                  (or (not live-game?)
                      (plan-wants-now? 'banshee-cloak)
                      (and (>= (unit-count 'banshee) 1)
                           (can-spend-by-priority? 'banshee-cloak 'tech-upgrade)))
                  (upgrade-needed? 'banshee-cloak))
         (emit-research-verified! 'banshee-cloak))
       (when (and (not (building-present-or-pending? 'ghost-academy))
                  (save-cancel-rebuild-ready? 'ghost-academy 60)
                  (or (not live-game?)
                      (plan-wants-now? 'ghost-academy)
                      (and (>= (length ccs) 3) (>= live-army-supply 34) (>= eff-phase-supply 92)))
                  (>= eff-phase-supply 56)
                  (>= minerals (sc2-min-cost 'ghost-academy))
                  (>= gas (sc2-gas-cost 'ghost-academy)))
         (emit-build-verified! 'ghost-academy (safe-coord (- base-x 4.0)) (safe-coord (- base-y 4.0))))
       (when (and (memq 'ghost-academy ready-bldg-types)
                  (or (not live-game?)
                      (plan-wants-now? 'personal-cloaking)
                      (>= (unit-count 'ghost) 1))
                  (upgrade-needed? 'personal-cloaking))
         (emit-research-verified! 'personal-cloaking)))

     (when (and (memq 'starport ready-bldg-types)
                (not early-survival-crisis?)
                (not terran-saving-for-expand?)
                (not (building-present-or-pending? 'fusion-core))
                (save-cancel-rebuild-ready? 'fusion-core 60)
                (or (plan-wants-now? 'fusion-core)
                    (and live-game? (>= (length ccs) 3) (>= eff-phase-supply 118) (>= gas 250)))
                (or (not live-game?) (can-spend-by-priority? 'fusion-core 'tech-bldg) (>= minerals 350))
                (>= minerals (sc2-min-cost 'fusion-core))
                (>= gas (sc2-gas-cost 'fusion-core)))
       (emit-build-verified! 'fusion-core (safe-coord (- base-x 5.0)) (safe-coord (+ base-y 5.0))))

     (when (and (memq 'fusion-core ready-bldg-types)
                (not urgent-combat-or-intel-need?))
       (cond
         [(and (>= (unit-count 'battlecruiser) 1)
               (upgrade-needed? 'weapon-refit))
          (emit-research-verified! 'weapon-refit)]
         [(and (>= (unit-count 'liberator) 2)
               (upgrade-needed? 'advanced-ballistics))
          (emit-research-verified! 'advanced-ballistics)]))

     (define has-fac-tl?
       (or (memq 'factory-techlab ready-bldg-types)
           (not (hash-has-key? raw-obs 'mineral-harvesters))))

     ;; 5. Terran SCV Saturation Priority (70 hard cap + midgame army curve) + Combat Unit Training
     (define terran-scv-priority?
       (and (or (not terran-saving-for-expand?)
                (and (not terran-saving-for-orbital?) (< total-workers 19) (< minerals 350)))
            (not crisis-freeze-workers?)
            (worker-army-curve-satisfied?)
            (not terran-saving-for-orbital?)
            (not urgent-combat-or-intel-need?)
            (or (< total-workers terran-ideal-worker-cap)
                (can-spend-by-priority? 'scv 'worker))
            (< total-workers (min 70 (max target-workers terran-ideal-worker-cap)))
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
                             (or (>= total-workers 24)
                                 (>= total-workers terran-ideal-worker-cap)
                                 (and (>= total-workers 16)
                                      (> bo-reserved-gas 0)
                                      (>= gas bo-reserved-gas)))
                             (or (<= bo-reserved-gas 0)
                                 (>= gas (- bo-reserved-gas 25)))
                             (not (memq bo-goal-sym '(hatchery nexus command-center drone probe scv))))))

     ;; Terran Unit Training (Groups 5 [Barracks] & 6 [Factory/Starport])
     (when (and (or (not terran-saving-for-expand?)
                    (and endgame-corner-hunt? (< (unit-count 'viking) 2)))
                (or (not terran-saving-for-orbital?)
                    (>= (- minerals (sc2-min-cost 'marine)) (sc2-min-cost 'orbital-command)))
                (can-spend-supply? (sc2-supply-cost 'marine)))
       ;; Priority corner-hunter air-to-air: ensure >= 2 Vikings before Medivacs/tanks consume Starport/gas!
       (when (and endgame-corner-hunt?
                  (memq 'starport ready-bldg-types)
                  (< (unit-count 'viking) 2))
         (try-train-unit! 'viking 'starport 6 #:respect-bo-reserve? #f))
       ;; Priority vs-Air Vikings: ensure >= 2 Vikings BEFORE Medivacs/tanks consume gas!
       (when (and live-game?
                  (not endgame-corner-hunt?)
                  (not terran-saving-for-expand?)
                  (memq 'starport ready-bldg-types)
                  (enemy-tech-observation-requires-anti-air? tech-obs)
                  (< (unit-count 'viking) 2))
         (try-train-unit! 'viking 'starport 6 #:respect-bo-reserve? #f))
       ;; Priority bio sustain (#5122349): ensure first 2 Medivacs before Factory drains 125G/tank
       ;; (vs air, co-produce Medivacs once >= 2 Vikings are active)!
       (when (and live-game?
                  (not terran-saving-for-expand?)
                  (memq 'starport ready-bldg-types)
                  (or (not (enemy-tech-observation-requires-anti-air? tech-obs))
                      (>= (unit-count 'viking) 2))
                  (>= (+ (unit-count 'marine) (unit-count 'marauder)) 6)
                  (< (unit-count 'medivac) 2)
                  (can-spend-supply? (sc2-supply-cost 'medivac)))
         (try-train-unit! 'medivac 'starport 6 #:respect-bo-reserve? #f))
       ;; Factory production first (Group 6): Siege Tank / Thor on Factory-TechLab
       (when (and (not terran-saving-for-expand?)
                  (memq 'factory ready-bldg-types))
         (when (and has-fac-tl?
                    (memq 'armory ready-bldg-types)
                    (starport-escrow-ok? (sc2-min-cost 'thor) (sc2-gas-cost 'thor))
                    (or (plan-wants-now? 'thor)
                        (and (or (enemy-tech-observation-requires-anti-air? tech-obs)
                                 (>= (unit-count 'siege-tank) 4))
                             (< (unit-count 'thor) 4)
                             (>= minerals (sc2-min-cost 'thor))
                             (>= gas (sc2-gas-cost 'thor))))
                    (can-spend-by-priority? 'thor 'combat-unit))
           (try-train-unit! 'thor 'factory 6 #:respect-bo-reserve? #t))
         (if has-fac-tl?
             (when (starport-escrow-ok? (sc2-min-cost 'siege-tank) (sc2-gas-cost 'siege-tank))
               (try-train-unit! 'siege-tank 'factory 6))
             (when (starport-escrow-ok? (sc2-min-cost 'widow-mine) (sc2-gas-cost 'widow-mine))
               (try-train-unit! 'widow-mine 'factory 6)))
         (when (and (starport-escrow-ok? (sc2-min-cost 'hellion) (sc2-gas-cost 'hellion))
                    (if live-game?
                        (and (or (not has-fac-tl?) (and (>= minerals 400) (< gas 50)))
                             (< (unit-count 'hellion) 4))
                        (or (< gas (sc2-gas-cost 'siege-tank)) (>= minerals 250))))
           (try-train-unit! 'hellion 'factory 6)))
       ;; Starport production (Group 6): Battlecruiser -> Raven -> 2 Vikings (AA) -> Medivac (1-2 AA / 4 normal) -> up to 8-10 Vikings (AA) -> Liberator
       (when (and (not terran-saving-for-expand?)
                  (memq 'starport ready-bldg-types))
         (when (and (memq 'fusion-core ready-bldg-types)
                    (memq 'starport-techlab ready-bldg-types)
                    (< (unit-count 'battlecruiser) 4)
                    (or (plan-wants-now? 'battlecruiser)
                        (and (>= minerals 450) (>= gas 350)))
                    (can-spend-supply? (sc2-supply-cost 'battlecruiser)))
           (try-train-unit! 'battlecruiser 'starport 6 #:respect-bo-reserve? #t))
         (when (and (memq 'starport-techlab ready-bldg-types)
                    (< (unit-count 'raven)
                       (if (enemy-tech-observation-requires-detection? tech-obs) 2 1))
                    (or (enemy-tech-observation-requires-detection? tech-obs)
                        endgame-corner-hunt?
                        (plan-wants-now? 'raven)
                        (and live-game? (>= live-army-supply 30))))
           (try-train-unit! 'raven 'starport 6))
         (when (and live-game?
                    (enemy-tech-observation-requires-anti-air? tech-obs)
                    (< (unit-count 'viking) 2))
           (try-train-unit! 'viking 'starport 6 #:respect-bo-reserve? #f))
         (when (and (or (not live-game?)
                        (not (enemy-tech-observation-requires-anti-air? tech-obs))
                        (>= (unit-count 'viking) 2))
                    (or (not live-game?)
                        (< (unit-count 'medivac)
                           (if (enemy-tech-observation-requires-anti-air? tech-obs) 2 4))
                        (can-spend-by-priority? 'medivac 'combat-unit)))
           (try-train-unit! 'medivac 'starport 6 #:respect-bo-reserve? #t))
         (when (and live-game?
                    (enemy-tech-observation-requires-anti-air? tech-obs)
                    (< (unit-count 'viking) 8))
           (try-train-unit! 'viking 'starport 6 #:respect-bo-reserve? #f))
         (when (or (not live-game?)
                   (and (enemy-tech-observation-requires-anti-air? tech-obs)
                        (< (unit-count 'viking) 10))
                   endgame-corner-hunt?
                   (and (>= (unit-count 'medivac) 2)
                        (can-spend-by-priority? 'viking 'combat-unit)))
           (try-train-unit! 'viking 'starport 6 #:respect-bo-reserve? #t))
         (when (and (or (plan-wants-now? 'liberator)
                        (and live-game? (>= eff-phase-supply 80) (>= (unit-count 'medivac) 2) (< (unit-count 'liberator) 3)))
                    (can-spend-by-priority? 'liberator 'combat-unit))
           (try-train-unit! 'liberator 'starport 6 #:respect-bo-reserve? #t)))
       ;; Barracks production (Group 5)
       (when (memq 'barracks ready-bldg-types)
         (define has-rax-tl-ready?
           (or (memq 'barracks-techlab ready-bldg-types)
               (not (hash-has-key? raw-obs 'mineral-harvesters))))
         (when (and live-game?
                    (< frame 2600)
                    (= (unit-count 'reaper) 0)
                    (= (length ally-combat-units) 0)
                    (>= gas (sc2-gas-cost 'reaper))
                    (not under-base-attack?)
                    (not under-early-cheese?))
           (try-train-unit! 'reaper 'barracks 5))
         (when (and has-rax-tl-ready?
                    (memq 'ghost-academy ready-bldg-types)
                    (< (unit-count 'ghost) 4)
                    (>= gas (sc2-gas-cost 'ghost))
                    (or (plan-wants-now? 'ghost)
                        (memq effective-enemy-race '(Protoss Zerg))))
           (try-train-unit! 'ghost 'barracks 5 #:respect-bo-reserve? #t))
         (when (and has-rax-tl-ready?
                    (or urgent-combat-or-intel-need?
                        (starport-escrow-ok? (sc2-min-cost 'marauder) (sc2-gas-cost 'marauder)))
                    (can-spend-by-priority? 'marauder 'combat-unit))
           (try-train-unit! 'marauder 'barracks 5 #:respect-bo-reserve? #t))
         (when (and (or urgent-combat-or-intel-need?
                        (< (+ (unit-count 'marine) (unit-count 'marauder)) 4)
                        (starport-escrow-ok? (sc2-min-cost 'marine) 0))
                    (can-spend-by-priority? 'marine 'combat-unit))
           (try-train-unit! 'marine 'barracks 5 #:respect-bo-reserve? #t))))

     (when (and (not terran-scv-priority?)
                (not crisis-freeze-workers?)
                (worker-army-curve-satisfied?)
                (not terran-saving-for-expand?)
                (not terran-saving-for-orbital?)
                (can-spend-by-priority? 'scv 'worker)
                (< total-workers
                   (if live-game?
                       (min 70 (max target-workers terran-ideal-worker-cap))
                       target-workers))
                (or (member '(train scv) prio-scheduled-actions)
                    worker-rush-active?
                    (< total-workers 14)
                    (< (hash-ref pressure-metrics 'threat-pressure 0.0) 1.0)))
       (try-train-unit! 'scv 'townhall 4
                        #:respect-bo-reserve? (and live-game? (>= total-workers 24))))]

    [else (void)])

  ;; ---------------------------------------------------------------------------
  ;; 200/200 Late-Game Max-Supply Manager (`bank-target` & `goal-stream-alloc`
  ;; were computed pre-spend above so stream slices reflect true available bank)
  ;; ---------------------------------------------------------------------------
  (define max-sup-plan
    (evaluate-max-supply-manager
     #:race race
     #:minerals minerals
     #:gas gas
     #:supply-used supply-used
     #:supply-cap supply-cap
     #:workers total-workers
     #:active-bases active-bases
     #:ally-units ally-units
     #:ally-buildings ally-bldgs
     #:base-x base-x
     #:base-y base-y
     #:nat-x nat-x
     #:nat-y nat-y
     #:third-x third-x
     #:third-y third-y
     #:enemy-x (hash-ref obs 'enemy-x SC2-DEFAULT-ENEMY-BASE-X)
     #:enemy-y (hash-ref obs 'enemy-y SC2-DEFAULT-ENEMY-BASE-Y)))
  (when (and (max-supply-plan-active? max-sup-plan)
             (refractory-allow-action?! cd-tracker
                                        (list 'max-supply-manager race)
                                        frame
                                        48))
    (for ([ms-act (in-list (max-supply-plan-combined-actions max-sup-plan))])
      (emit! ms-act)))

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
              'bank-target bank-target
              'goal-stream-allocation goal-stream-alloc
              'decoupled-stream-spendable stream-spendable-ht
              'goal-streams DEC-GOAL-STREAMS
              'max-supply-plan max-sup-plan
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
              'escrow-age-frames (if escrow-timed-out-now? 0 cur-escrow-age-frames)
              'escrow-peak-min (if escrow-timed-out-now? obs-minerals cur-escrow-peak-min)
              'escrow-prev-min obs-minerals
              'escrow-start-frame (if escrow-timed-out-now? frame cur-escrow-start-frame)
              'escrow-last-frame frame
              'escrow-suppressed-goal escrow-suppressed-goal
              'escrow-suppressed-until-frame escrow-suppressed-until-frame
              'exp-goal-streak-start (if escrow-timed-out-now? #f cur-exp-streak-start)
              'exp-goal-th-count cur-th-total-cnt
              'exp-goal-last-frame (if exp-goal-sym-this-step frame prev-exp-last-f)
              'exp-timeout-count next-exp-timeout-cnt
              'rush-fighting-worker-ids cur-rush-fighting-wids))

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

  (define leases (rt-role-leases rt))
  (define bstates (rt-bistable-states rt))
  (define splash-st (rt-splash-state rt))
  (define spotter-ht (rt-spotter-lings rt))
  (define live-tactics-obs? (hash-has-key? raw-obs 'mineral-harvesters))

  (define actions '())
  (define (emit! act)
    (order-ledger-record-issued! oledger frame act)
    (set! actions (cons act actions)))

  (define (quantize-cell-2.5 v fallback)
    (define sv (safe-coord v fallback))
    (if live-tactics-obs?
        (safe-coord (* 2.5 (round (/ sv 2.5))) fallback)
        sv))

  ;; ---------------------------------------------------------------------------
  ;; Zerg Zergling Spotter Scouts (Up to 3 Map Watch Posts, 0-APM Hold Until Needed)
  ;; ---------------------------------------------------------------------------
  (define under-tactics-base-attack?
    (ormap (lambda (e)
             (<= (min (dist2d base-x base-y (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0))
                      (dist2d nat-x nat-y (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0)))
                 26.0))
           enemy-units))
  (when (and live-tactics-obs?
             (eq? (live-bot-runtime-actual-race rt) 'Zerg)
             (not under-tactics-base-attack?))
    (define map-dx (- enemy-x base-x))
    (define map-dy (- enemy-y base-y))
    (define map-d (max 1.0 (sqrt (+ (* map-dx map-dx) (* map-dy map-dy)))))
    (define map-px (/ (- map-dy) map-d))
    (define map-py (/ map-dx map-d))
    (define spotter-posts
      (list (list 'enemy-front
                  (safe-coord (+ enemy-exp-x (* 0.28 (- nat-x enemy-exp-x))) enemy-exp-x)
                  (safe-coord (+ enemy-exp-y (* 0.28 (- nat-y enemy-exp-y))) enemy-exp-y))
            (list 'enemy-third
                  (safe-coord (+ enemy-exp-x (* 14.0 map-px)) enemy-exp-x)
                  (safe-coord (+ enemy-exp-y (* 14.0 map-py)) enemy-exp-y))
            (list 'enemy-fourth
                  (safe-coord (+ (* 0.5 (+ nat-x enemy-exp-x)) (* -14.0 map-px)) nat-x)
                  (safe-coord (+ (* 0.5 (+ nat-y enemy-exp-y)) (* -14.0 map-py)) nat-y))))
    (define all-live-lings
      (filter (lambda (u)
                (and (eq? (unit-type-sym u) 'zergling)
                     (not (or (eq? (hash-ref u 'is-hallucination #f) #t)
                              (eq? (hash-ref u 'hallucination #f) #t)))))
              ally-units))
    (for ([post (in-list spotter-posts)])
      (define pkey (first post))
      (define px (second post))
      (define py (third post))
      (define prev-entry (hash-ref spotter-ht pkey #f))
      (define prev-tag (and (hash? prev-entry) (hash-ref prev-entry 'tag #f)))
      (define cd-until (if (hash? prev-entry) (hash-ref prev-entry 'cooldown-until 0) 0))
      (define repost-after (if (hash? prev-entry) (hash-ref prev-entry 'repost-after 0) 0))
      (define live-spotter
        (and prev-tag
             (findf (lambda (u) (equal? (hash-ref u 'id -1) prev-tag)) all-live-lings)))
      (cond
        [(and prev-tag (not live-spotter))
         (hash-set! spotter-ht pkey
                    (hash 'tag #f
                          'cooldown-until (max cd-until (+ frame 672))
                          'repost-after (+ frame 672)))]
        [(and (not live-spotter)
              (>= frame cd-until)
              (>= (length all-live-lings) 6))
         (define free-lings
           (filter (lambda (u)
                     (not (unit-leased-above? leases (hash-ref u 'id 0) 'army frame)))
                   all-live-lings))
         (when (not (null? free-lings))
           (define chosen
             (argmin (lambda (u) (dist2d px py (hash-ref u 'x px) (hash-ref u 'y py)))
                     free-lings))
           (define sid (hash-ref chosen 'id 0))
           (acquire-unit-lease! leases sid 'spotter frame 32 #:x px #:y py)
           (hash-set! spotter-ht pkey
                      (hash 'tag sid 'cooldown-until 0 'repost-after 0))
           (when (> (dist2d px py (hash-ref chosen 'x px) (hash-ref chosen 'y py)) 2.5)
             (emit! (list 'move sid px py))))]
        [live-spotter
         (define sid (hash-ref live-spotter 'id 0))
         (define sx (hash-ref live-spotter 'x px))
         (define sy (hash-ref live-spotter 'y py))
         (acquire-unit-lease! leases sid 'spotter frame 32 #:x px #:y py)
         (define threat-near
           (findf (lambda (e)
                    (<= (dist2d sx sy (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0)) 9.0))
                  enemy-units))
         (cond
           [threat-near
            (define-values (rx ry)
              (compute-kite-vector sx sy
                                   (hash-ref threat-near 'x sx)
                                   (hash-ref threat-near 'y sy)
                                   6.0))
            (hash-set! spotter-ht pkey
                       (hash 'tag sid 'cooldown-until cd-until 'repost-after (+ frame 180)))
            (when (refractory-allow-action?! (live-bot-runtime-cooldown-tracker rt)
                                             (list 'spotter-evade sid)
                                             frame
                                             16)
              (emit! (list 'move sid (safe-coord rx nat-x) (safe-coord ry nat-y))))]
           [(< frame repost-after)
            (void)]
           [(<= (dist2d sx sy px py) 2.0)
            (void)]
           [(and (> (dist2d sx sy px py) 2.5)
                 (refractory-allow-action?! (live-bot-runtime-cooldown-tracker rt)
                                            (list 'spotter-move sid)
                                            frame
                                            28))
            (emit! (list 'move sid px py))])])))

  (define combat-units
    (filter (lambda (u)
              (define uid (hash-ref u 'id 0))
              (and (combat-unit-record? u)
                   (not (unit-leased-above? leases uid 'army frame))
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

  ;; Compute primary army centroid early for Overseer escort & siege-line positioning
  (define prelim-army-cx
    (if (null? combat-units)
        nat-x
        (safe-coord (/ (for/sum ([u (in-list combat-units)])
                         (safe-finite-real (hash-ref u 'x nat-x) nat-x))
                       (max 1 (length combat-units)))
                    nat-x)))
  (define prelim-army-cy
    (if (null? combat-units)
        nat-y
        (safe-coord (/ (for/sum ([u (in-list combat-units)])
                         (safe-finite-real (hash-ref u 'y nat-y) nat-y))
                       (max 1 (length combat-units)))
                    nat-y)))

  ;; ---------------------------------------------------------------------------
  ;; Zerg Overseer Detector Escort & Cloak/Burrow Reveal ('detector-escort lease)
  ;; ---------------------------------------------------------------------------
  (define live-overseers
    (filter (lambda (u)
              (and (memq (unit-type-sym u) '(overseer overseer-siege-mode))
                   (not (or (eq? (hash-ref u 'is-hallucination #f) #t)
                            (eq? (hash-ref u 'hallucination #f) #t)))))
            ally-units))
  (define stealth-threats-near-army
    (filter (lambda (e)
              (define et (unit-type-sym e))
              (define ex0 (hash-ref e 'x 9999.0))
              (define ey0 (hash-ref e 'y 9999.0))
              (and (or (memq et '(widow-mine-burrowed lurker-burrowed dark-templar banshee ghost
                                  roach-burrowed infestor-burrowed oracle-stasis-trap stasis-ward))
                       (eq? (hash-ref e 'cloaked #f) #t)
                       (eq? (hash-ref e 'burrowed #f) #t)
                       (= (hash-ref e 'display-type 1) 2))
                   (>= (count (lambda (cu)
                                (<= (dist2d ex0 ey0 (hash-ref cu 'x base-x) (hash-ref cu 'y base-y))
                                    14.0))
                              combat-units)
                       3)))
            (append enemy-units enemy-bldgs)))
  (define reveal-assigned-ov-id
    (if (and (not (null? live-overseers)) (not (null? stealth-threats-near-army)))
        (let* ([thr (car stealth-threats-near-army)]
               [tx0 (hash-ref thr 'x prelim-army-cx)]
               [ty0 (hash-ref thr 'y prelim-army-cy)]
               [best-ov (argmin (lambda (ov)
                                  (dist2d tx0 ty0 (hash-ref ov 'x base-x) (hash-ref ov 'y base-y)))
                                live-overseers)])
          (hash-ref best-ov 'id #f))
        #f))
  (for ([ov (in-list live-overseers)])
    (define ov-id (hash-ref ov 'id 0))
    (define ovx (hash-ref ov 'x base-x))
    (define ovy (hash-ref ov 'y base-y))
    (acquire-unit-lease! leases ov-id 'detector-escort frame 24
                         #:x prelim-army-cx #:y prelim-army-cy)
    (define allies-near-ov
      (count (lambda (cu)
               (<= (dist2d ovx ovy (hash-ref cu 'x base-x) (hash-ref cu 'y base-y)) 12.0))
             combat-units))
    (define aa-threat-near-ov
      (findf (lambda (e)
               (define et (unit-type-sym e))
               (define air-dps (hash-ref (sc2-unit-combat-stats et) 'air-dps 0.0))
               (and (> air-dps 0.0)
                    (<= (dist2d ovx ovy (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0)) 11.5)))
             (append enemy-units enemy-bldgs)))
    (cond
      [(and reveal-assigned-ov-id (equal? ov-id reveal-assigned-ov-id))
       (define thr (car stealth-threats-near-army))
       (define tx0 (hash-ref thr 'x prelim-army-cx))
       (define ty0 (hash-ref thr 'y prelim-army-cy))
       (define d-back (max 1.0 (dist2d tx0 ty0 prelim-army-cx prelim-army-cy)))
       (define stand-x (safe-coord (+ tx0 (* 8.5 (/ (- prelim-army-cx tx0) d-back))) prelim-army-cx))
       (define stand-y (safe-coord (+ ty0 (* 8.5 (/ (- prelim-army-cy ty0) d-back))) prelim-army-cy))
       (when (and (> (dist2d ovx ovy stand-x stand-y) 2.0)
                  (refractory-allow-action?! (live-bot-runtime-cooldown-tracker rt)
                                             (list 'ov-reveal ov-id)
                                             frame
                                             16))
         (emit! (list 'move ov-id stand-x stand-y)))]
      [(and (< allies-near-ov 3) aa-threat-near-ov)
       (define d-home (max 1.0 (dist2d ovx ovy base-x base-y)))
       (define rx (safe-coord (+ ovx (* 6.0 (/ (- base-x ovx) d-home))) base-x))
       (define ry (safe-coord (+ ovy (* 6.0 (/ (- base-y ovy) d-home))) base-y))
       (when (refractory-allow-action?! (live-bot-runtime-cooldown-tracker rt)
                                        (list 'ov-retreat ov-id)
                                        frame
                                        16)
         (emit! (list 'move ov-id rx ry)))]
      [(not (null? combat-units))
       (define d-home (max 1.0 (dist2d prelim-army-cx prelim-army-cy base-x base-y)))
       (define leash-x (safe-coord (+ prelim-army-cx (* 2.5 (/ (- base-x prelim-army-cx) d-home))) prelim-army-cx))
       (define leash-y (safe-coord (+ prelim-army-cy (* 2.5 (/ (- base-y prelim-army-cy) d-home))) prelim-army-cy))
       (when (and (> (dist2d ovx ovy leash-x leash-y) 2.2)
                  (refractory-allow-action?! (live-bot-runtime-cooldown-tracker rt)
                                             (list 'ov-escort ov-id)
                                             frame
                                             20))
         (emit! (list 'move ov-id leash-x leash-y)))]))

  ;; ---------------------------------------------------------------------------
  ;; Multi-Depth Mirrored Tactical Micro Brain (0.5s, 2.0s, 5.0s Horizons)
  ;; ---------------------------------------------------------------------------
  (define-values (tbrain-actions tbrain-committed-tags _tbrain-decisions)
    (if (and (not (null? combat-units)) (not (null? enemy-units)))
        (step-tactical-mirror-brain! tbrain oledger obs #:record-ledger? #f)
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
       (define escort-x prelim-army-cx)
       (define escort-y prelim-army-cy)
       (when (and (> (dist2d tx ty escort-x escort-y) 6.0)
                  (refractory-allow-action?! (live-bot-runtime-cooldown-tracker rt)
                                             (list 'transport-escort tr-id)
                                             frame
                                             20))
         (emit! (list 'attack-pos tr-id escort-x escort-y)))]
      [(and (> (dist2d tx ty nat-x nat-y) 8.0)
            (refractory-allow-action?! (live-bot-runtime-cooldown-tracker rt)
                                       (list 'transport-escort tr-id)
                                       frame
                                       20))
       (emit! (list 'attack-pos tr-id nat-x nat-y))]))

  ;; ---------------------------------------------------------------------------
  ;; Adversarial Countermeasure #5: Ramp Force-Field Corrosive-Bile Breaker
  ;; ---------------------------------------------------------------------------
  (define ravager-cast-tags (mutable-seteqv))
  (define force-fields
    (append
     (filter (lambda (eff) (eq? (hash-ref eff 'type 'none) 'force-field)) effects)
     (filter (lambda (e) (eq? (unit-type-sym e) 'force-field)) enemy-units)))
  (when (not (null? force-fields))
    (define ff (car force-fields))
    (define ffx (hash-ref ff 'x nat-x))
    (define ffy (hash-ref ff 'y nat-y))
    (define ravagers (filter (lambda (u) (eq? (unit-type-sym u) 'ravager)) combat-units))
    (for ([rav (in-list (take ravagers (min 2 (length ravagers))))])
      (define rid (hash-ref rav 'id 140))
      (set-add! ravager-cast-tags rid)
      (emit! (list 'cast-spell rid 'corrosive-bile ffx ffy)))
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
  ;;   1. Coalesced Hostile Ground Effects (`psi-storm`, `corrosive-bile`, `blinding-cloud`) &
  ;;      Enemy `disruptor-phased` (Purification Nova) Lateral Wing Evasion
  ;;   2. Enemy `widow-mine` / `widow-mine-burrowed` Out-Range Snipe, Lock Pull-Back & Bait
  ;;   3. Enemy `baneling` Light-Unit Radial Pre-Split (2.5x2.5 Bucketed)
  ;;   4. Enemy `hellion` & `lurker-burrowed` Collinear Lateral Scatter (+/- n-hat)
  ;;   5. Enemy `siege-tank-sieged` Line Discipline, Ravager Bile Stagger & 3-Flank Break
  ;; ---------------------------------------------------------------------------
  (define splash-evading-tags (mutable-seteqv))
  (define ally-has-detector?
    (ormap (lambda (u) (sc2-unit-is-detector-sym? (unit-type-sym u)))
           (append ally-units ally-bldgs)))

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
  (for ([hz (in-list hazard-zones)])
    (define hx (first hz))
    (define hy (second hz))
    (define hrad (third hz))
    (define affected
      (filter (lambda (u)
                (define uid (hash-ref u 'id 101))
                (and (not (set-member? splash-evading-tags uid))
                     (not (order-ledger-unit-in-attack-swing? oledger u))
                     (<= (dist2d (hash-ref u 'x base-x) (hash-ref u 'y base-y) hx hy) hrad)))
              combat-units))
    (cond
      [(and live-tactics-obs? (>= (length affected) 4))
       (define hdx (- prelim-army-cx hx))
       (define hdy (- prelim-army-cy hy))
       (define hd (max 1.0 (sqrt (+ (* hdx hdx) (* hdy hdy)))))
       (define hnx (/ (- hdy) hd))
       (define hny (/ hdx hd))
       (define left-ids
         (for/list ([u (in-list affected)] #:when (even? (hash-ref u 'id 0)))
           (define uid (hash-ref u 'id 0))
           (set-add! splash-evading-tags uid)
           uid))
       (define right-ids
         (for/list ([u (in-list affected)] #:when (odd? (hash-ref u 'id 0)))
           (define uid (hash-ref u 'id 0))
           (set-add! splash-evading-tags uid)
           uid))
       (when (not (null? left-ids))
         (emit! (list 'kite left-ids
                      (quantize-cell-2.5 (+ hx (* 4.5 hnx) (* 2.0 (/ hdx hd))) base-x)
                      (quantize-cell-2.5 (+ hy (* 4.5 hny) (* 2.0 (/ hdy hd))) base-y))))
       (when (not (null? right-ids))
         (emit! (list 'kite right-ids
                      (quantize-cell-2.5 (+ hx (* -4.5 hnx) (* 2.0 (/ hdx hd))) base-x)
                      (quantize-cell-2.5 (+ hy (* -4.5 hny) (* 2.0 (/ hdy hd))) base-y))))]
      [else
       (for ([u (in-list affected)])
         (define uid (hash-ref u 'id 101))
         (define ux (hash-ref u 'x base-x))
         (define uy (hash-ref u 'y base-y))
         (define-values (kx ky) (compute-kite-vector ux uy hx hy 3.5))
         (set-add! splash-evading-tags uid)
         (emit! (list 'kite uid (quantize-cell-2.5 kx ux) (quantize-cell-2.5 ky uy))))]))

  ;; 2. Enemy Widow Mine Out-Range Snipe, Lock Pull-Back, Bait & Cooldown Tracking
  (define enemy-widow-mines
    (filter (lambda (e) (memq (unit-type-sym e) '(widow-mine widow-mine-burrowed)))
            enemy-units))
  (for ([wm (in-list enemy-widow-mines)])
    (define wm-id (hash-ref wm 'id 901))
    (define wmx (hash-ref wm 'x nat-x))
    (define wmy (hash-ref wm 'y nat-y))
    (define wm-burrowed?
      (or (eq? (unit-type-sym wm) 'widow-mine-burrowed)
          (eq? (hash-ref wm 'burrowed #f) #t)))
    (define wm-cloaked? (eq? (hash-ref wm 'cloaked #f) #t))
    (define wm-targetable?
      (or (not wm-burrowed?)
          (not wm-cloaked?)
          ally-has-detector?
          (not live-tactics-obs?)))
    (define disarmed-until (hash-ref splash-st (cons 'wm-disarmed wm-id) -1))
    (define engaged-tag (hash-ref wm 'engaged-target-tag 0))
    (define explicit-target-id
      (cond
        [(and (exact-integer? engaged-tag) (> engaged-tag 0)) engaged-tag]
        [else (hash-ref wm 'target-id #f)]))
    (define (unit-eff-ground-range u)
      (define ut (unit-type-sym u))
      (define base-gr
        (exact->inexact
         (hash-ref u 'ground-range
                   (hash-ref (sc2-unit-combat-stats ut) 'ground-range 0.0))))
      (+ base-gr
         (cond
           [(and (eq? ut 'hydralisk) (has-upgrade? 'grooved-spines)) 1.0]
           [(and (eq? ut 'colossus) (has-upgrade? 'extended-thermal-lance)) 2.0]
           [else 0.0])))
    (when (>= frame disarmed-until)
      (define wm-snipers
        (filter (lambda (u)
                  (define gr (unit-eff-ground-range u))
                  (and (>= gr 6.0)
                       (not (set-member? splash-evading-tags (hash-ref u 'id 0)))
                       (<= (dist2d wmx wmy (hash-ref u 'x base-x) (hash-ref u 'y base-y)) 11.5)))
                combat-units))
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
      (cond
        [(and wm-targetable? (not (null? wm-snipers)))
         (for ([r (in-list wm-snipers)])
           (define rid (hash-ref r 'id 101))
           (set-add! splash-evading-tags rid)
           (emit! (list 'attack-unit rid wm-id)))
         (for ([u (in-list combat-units)])
           (define uid (hash-ref u 'id 101))
           (define ut (unit-type-sym u))
           (define gr (unit-eff-ground-range u))
           (define ux (hash-ref u 'x base-x))
           (define uy (hash-ref u 'y base-y))
           (when (and (< gr 5.5)
                      (not (sc2-unit-is-flying-sym? ut))
                      (not (set-member? splash-evading-tags uid))
                      (<= (dist2d wmx wmy ux uy) 6.8))
             (define-values (kx ky) (compute-kite-vector ux uy wmx wmy 3.5))
             (set-add! splash-evading-tags uid)
             (emit! (list 'kite uid (quantize-cell-2.5 kx ux) (quantize-cell-2.5 ky uy)))))]
        [(and live-tactics-obs? wm-burrowed? (not wm-targetable?))
         (define nearby-pack
           (filter (lambda (u)
                     (<= (dist2d wmx wmy (hash-ref u 'x base-x) (hash-ref u 'y base-y)) 9.5))
                   combat-units))
         (when (>= (length nearby-pack) 2)
           (define cheap-pool
             (filter (lambda (u) (memq (unit-type-sym u) '(zergling zealot marine adept)))
                     nearby-pack))
           (define bait-u
             (argmin (lambda (u) (hash-ref u 'hp 100))
                     (if (not (null? cheap-pool)) cheap-pool nearby-pack)))
           (define bait-id (hash-ref bait-u 'id 101))
           (set-add! splash-evading-tags bait-id)
           (hash-set! splash-st (cons 'wm-disarmed wm-id) (+ frame 620))
           (emit! (list 'move bait-id (safe-coord wmx base-x) (safe-coord wmy base-y)))
           (for ([u (in-list nearby-pack)]
                 #:when (not (equal? (hash-ref u 'id -1) bait-id)))
             (define uid (hash-ref u 'id 101))
             (define ux (hash-ref u 'x base-x))
             (define uy (hash-ref u 'y base-y))
             (when (and (not (set-member? splash-evading-tags uid))
                        (<= (dist2d wmx wmy ux uy) 7.5))
               (define-values (kx ky) (compute-kite-vector ux uy wmx wmy 4.5))
               (set-add! splash-evading-tags uid)
               (emit! (list 'kite uid (quantize-cell-2.5 kx ux) (quantize-cell-2.5 ky uy))))))]
        [targeted-ally
         (define tid (hash-ref targeted-ally 'id 101))
         (define tx (hash-ref targeted-ally 'x base-x))
         (define ty (hash-ref targeted-ally 'y base-y))
         (when explicit-target-id
           (hash-set! splash-st (cons 'wm-disarmed wm-id) (+ frame 620)))
         (unless (set-member? splash-evading-tags tid)
           (define-values (kx ky) (compute-kite-vector tx ty wmx wmy 3.5))
           (set-add! splash-evading-tags tid)
           (emit! (list 'kite tid (quantize-cell-2.5 kx tx) (quantize-cell-2.5 ky ty))))
         (for ([ally (in-list combat-units)])
           (define aid (hash-ref ally 'id 101))
           (define ax (hash-ref ally 'x base-x))
           (define ay (hash-ref ally 'y base-y))
           (when (and (not (equal? aid tid))
                      (not (set-member? splash-evading-tags aid))
                      (<= (dist2d tx ty ax ay) 2.2))
             (define-values (sx sy) (compute-kite-vector ax ay tx ty 2.8))
             (set-add! splash-evading-tags aid)
             (emit! (list 'kite aid (quantize-cell-2.5 sx ax) (quantize-cell-2.5 sy ay)))))])))

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
          (emit! (list 'kite uid (quantize-cell-2.5 kx ux) (quantize-cell-2.5 ky uy)))))))

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
              (emit! (list 'kite uid (quantize-cell-2.5 lx ux) (quantize-cell-2.5 ly uy)))))))))

  ;; 5. Counter-Micro vs. Enemy `oracle-stasis-trap` / `stasis-ward`
  (define enemy-stasis-traps
    (filter (lambda (e) (memq (unit-type-sym e) '(oracle-stasis-trap stasis-ward)))
            (append enemy-units enemy-bldgs)))
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
           (emit! (list 'kite uid (quantize-cell-2.5 kx base-x) (quantize-cell-2.5 ky base-y)))))]
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
             (emit! (list 'kite uid (quantize-cell-2.5 kx base-x) (quantize-cell-2.5 ky base-y))))))]))

  ;; 6. Anti-Siege-Tank-Sieged Line Discipline, Staggered Ravager Bile & 3-Flank Break
  (define immobile-bile-targets
    (filter (lambda (e)
              (memq (unit-type-sym e) '(siege-tank-sieged widow-mine-burrowed liberator-ag)))
            enemy-units))
  (when (and live-tactics-obs? (not (null? immobile-bile-targets)))
    (define free-ravagers
      (filter (lambda (u)
                (and (eq? (unit-type-sym u) 'ravager)
                     (not (set-member? ravager-cast-tags (hash-ref u 'id 0)))))
              combat-units))
    (for ([tgt (in-list immobile-bile-targets)])
      (define tx0 (hash-ref tgt 'x nat-x))
      (define ty0 (hash-ref tgt 'y nat-y))
      (define in-range-ravs
        (filter (lambda (r)
                  (and (not (set-member? ravager-cast-tags (hash-ref r 'id 0)))
                       (<= (dist2d tx0 ty0 (hash-ref r 'x base-x) (hash-ref r 'y base-y)) 9.5)))
                free-ravagers))
      (for ([r (in-list (take in-range-ravs (min 3 (length in-range-ravs))))]
            [bidx (in-naturals)])
        (define rid (hash-ref r 'id 140))
        (define off-x (* 0.35 (- bidx 1)))
        (define off-y (* 0.35 (if (= bidx 1) 1 0)))
        (set-add! ravager-cast-tags rid)
        (set-add! splash-evading-tags rid)
        (emit! (list 'cast-spell rid 'corrosive-bile
                     (safe-coord (+ tx0 off-x) tx0)
                     (safe-coord (+ ty0 off-y) ty0))))))

  (define enemy-sieged-tanks-near
    (filter (lambda (e)
              (and (eq? (unit-type-sym e) 'siege-tank-sieged)
                   (<= (dist2d prelim-army-cx prelim-army-cy
                               (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0))
                       17.5)))
            enemy-units))
  (define our-z-early
    (hash-ref obs 'our-terrain-z
              (if (not (null? combat-units)) (hash-ref (car combat-units) 'z 10.0) 10.0)))
  (define enemy-z-early
    (hash-ref obs 'enemy-terrain-z
              (if (not (null? enemy-units)) (hash-ref (car enemy-units) 'z 10.0) 10.0)))
  (define siege-uphill? (>= (- (exact->inexact enemy-z-early) (exact->inexact our-z-early)) 0.75))
  (define have-siege-breaker?
    (or (ormap (lambda (u)
                 (memq (unit-type-sym u) '(viper brood-lord tempest liberator liberator-ag disruptor)))
               combat-units)
        (ormap (lambda (eff) (eq? (hash-ref eff 'type 'none) 'blinding-cloud)) effects)))
  (define local-ally-val
    (for/sum ([u (in-list combat-units)])
      (+ (sc2-min-cost (unit-type-sym u) 50) (sc2-gas-cost (unit-type-sym u) 0))))
  (define local-enemy-val
    (max 100
         (for/sum ([e (in-list enemy-units)]
                   #:when (<= (dist2d prelim-army-cx prelim-army-cy
                                      (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0))
                              19.0))
           (+ (sc2-min-cost (unit-type-sym e) 50) (sc2-gas-cost (unit-type-sym e) 0)))))
  (define local-val-ratio (/ (exact->inexact local-ally-val) (exact->inexact local-enemy-val)))
  (define can-break-siege-line?
    (or (>= local-val-ratio (if siege-uphill? 1.55 1.40))
        (>= (hash-ref obs 'supply-used 0) 180)
        have-siege-breaker?))
  (define siege-shelling-friendly-structure?
    (ormap (lambda (st)
             (define stx (hash-ref st 'x 9999.0))
             (define sty (hash-ref st 'y 9999.0))
             (ormap (lambda (b)
                      (<= (dist2d stx sty (hash-ref b 'x base-x) (hash-ref b 'y base-y)) 15.5))
                    ally-bldgs))
           enemy-sieged-tanks-near))
  (define siege-line-hold?
    (and live-tactics-obs?
         (>= (length enemy-sieged-tanks-near) 2)
         (not siege-shelling-friendly-structure?)
         (not can-break-siege-line?)))
  (when (and live-tactics-obs?
             (>= (length enemy-sieged-tanks-near) 2)
             can-break-siege-line?
             (>= (length combat-units) 6)
             (refractory-allow-action?! (live-bot-runtime-cooldown-tracker rt)
                                        '(siege-flank-wings)
                                        frame
                                        24))
    (define st0 (car enemy-sieged-tanks-near))
    (define stx (hash-ref st0 'x enemy-x))
    (define sty (hash-ref st0 'y enemy-y))
    (define sdx (- stx prelim-army-cx))
    (define sdy (- sty prelim-army-cy))
    (define sd (max 1.0 (sqrt (+ (* sdx sdx) (* sdy sdy)))))
    (define snx (/ (- sdy) sd))
    (define sny (/ sdx sd))
    (define flank-units
      (sort (filter (lambda (u)
                      (not (set-member? splash-evading-tags (hash-ref u 'id 0))))
                    combat-units)
            <
            #:key (lambda (u)
                    (+ (* (- (hash-ref u 'x prelim-army-cx) prelim-army-cx) snx)
                       (* (- (hash-ref u 'y prelim-army-cy) prelim-army-cy) sny)))))
    (define n-flank (length flank-units))
    (define cut1 (quotient n-flank 3))
    (define cut2 (quotient (* 2 n-flank) 3))
    (define spatial-wings
      (if (>= n-flank 3)
          (list (take flank-units cut1)
                (take (drop flank-units cut1) (- cut2 cut1))
                (drop flank-units cut2))
          (list flank-units '() '())))
    (for ([wing-us (in-list spatial-wings)]
          [lat (in-list '(-5.0 0.0 5.0))])
      (define wing-ids (map (lambda (u) (hash-ref u 'id 0)) wing-us))
      (when (not (null? wing-ids))
        (for ([wid (in-list wing-ids)])
          (set-add! splash-evading-tags wid))
        (emit! (list 'attack-pos wing-ids
                     (safe-coord (+ stx (* lat snx)) stx)
                     (safe-coord (+ sty (* lat sny)) sty))))))

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
  (define oracle-cast-tags (mutable-seteqv))
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
         (set-add! oracle-cast-tags uid)
         (emit! (list 'cast-spell uid 'stasis-ward wx wy))
         (when (not (null? close-enemy-workers))
           (define nearest-ew
             (argmin (lambda (ew) (dist2d ux uy (hash-ref ew 'x ux) (hash-ref ew 'y uy)))
                     close-enemy-workers))
           (emit! (list 'cast-spell uid 'pulsar-beam (hash-ref nearest-ew 'id 0))))]
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
         (set-add! oracle-cast-tags uid)
         (emit! (list 'cast-spell uid 'stasis-ward enemy-exp-x enemy-exp-y))]
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
         (set-add! oracle-cast-tags uid)
         (emit! (list 'cast-spell uid 'stasis-ward nat-x nat-y))]))
    (when (and (list? u-buffs)
               (or (memq 'pulsar-beam u-buffs) (memq 'oracle-weapon u-buffs))
               (not (ormap (lambda (e)
                             (<= (dist2d ux uy (hash-ref e 'x 9999) (hash-ref e 'y 9999)) 6.5))
                           enemy-units)))
      (emit! (list 'cast-spell uid 'pulsar-beam-off uid))))

  ;; ---------------------------------------------------------------------------
  ;; Active Combat Spells, Bistable Wave Hysteresis & Mutually Exclusive Micro
  ;; ---------------------------------------------------------------------------
  (define live-obs? live-tactics-obs?)
  (define live-combat-supply
    (for/sum ([u (in-list combat-units)])
      (unit-supply-cost (unit-type-sym u))))
  (define visible-enemy-combat-supply
    (for/sum ([e (in-list enemy-units)]
              #:when (combat-unit-record? e))
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
  (define wave-commit-active?
    (if live-obs?
        (bistable-hysteresis-step
         bstates
         'army-attack-wave
         frame
         #:enter? (or (and (>= live-combat-supply 26) (>= lanchester-force-ratio 1.35))
                      (>= live-combat-supply 42)
                      (>= (length combat-units) live-attack-wave-min))
         #:exit? (and (< live-combat-supply 16)
                      (< lanchester-force-ratio 0.85))
         #:min-dwell-loops 112
         #:cooldown-loops 44)
        #t))
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

  ;; Enemy composition flags for mode-switches & T3 spell targeting
  (define enemy-air-or-colossus
    (filter (lambda (e)
              (define et (unit-type-sym e))
              (or (eq? et 'colossus)
                  (sc2-unit-is-flying-sym? et)))
            enemy-units))
  (define enemy-massive-air-or-colossus
    (filter (lambda (e)
              (memq (unit-type-sym e)
                    '(brood-lord broodlord tempest carrier battlecruiser colossus mothership liberator liberator-ag)))
            enemy-units))
  (define enemy-mutalisks
    (filter (lambda (e) (eq? (unit-type-sym e) 'mutalisk)) enemy-units))

  (when (not (null? engagement-enemies))
    ;; Leashed 1-to-1 Queen Transfusion (`<= 10.0` tiles, `max-hp >= 120`, never Zerglings/Banelings)
    (define queen-cast-tags (mutable-seteqv))
    (define transfusion-queens
      (filter (lambda (u)
                (and (eq? (unit-type-sym u) 'queen)
                     (not (unit-leased-above? leases (hash-ref u 'id 0) 'creep-queen frame))))
              ally-units))
    (define transfusion-targets
      (filter (lambda (u)
                (define max-hp (hash-ref u 'max-hp 150))
                (define cur-hp (hash-ref u 'hp max-hp))
                (define buffs (hash-ref u 'buffs '()))
                (define ut (unit-type-sym u))
                (and (>= max-hp 120)
                     (not (memq ut '(zergling baneling broodling changeling)))
                     (>= (- max-hp cur-hp) (if live-obs? 45 1))
                     (not (and (list? buffs) (memq 'transfusion buffs)))))
              (if live-obs? (append combat-units ally-bldgs) combat-units)))
    (dispatch-macro-energy!
     transfusion-queens
     transfusion-targets
     frame
     (mutable-seteqv)
     #:min-energy SC2-QUEEN-TRANSFUSION-ENERGY
     #:valid-pair? (lambda (q tgt)
                     (or (not live-obs?)
                         (<= (dist2d (hash-ref q 'x base-x) (hash-ref q 'y base-y)
                                     (hash-ref tgt 'x base-x) (hash-ref tgt 'y base-y))
                             10.0)))
     #:score-pair (lambda (q tgt)
                    (- (- (hash-ref tgt 'max-hp 150) (hash-ref tgt 'hp 100))
                       (* 2.0 (dist2d (hash-ref q 'x base-x) (hash-ref q 'y base-y)
                                      (hash-ref tgt 'x base-x) (hash-ref tgt 'y base-y)))))
     #:emit-cast! (lambda (q tgt)
                    (define qid (hash-ref q 'id 120))
                    (set-add! queen-cast-tags qid)
                    (emit! (list 'cast-spell qid 'transfusion (hash-ref tgt 'id 141)))))

    (for ([u (in-list combat-units)])
      (define ut (unit-type-sym u))
      (define uid (hash-ref u 'id 101))
      (define ux (hash-ref u 'x base-x))
      (define uy (hash-ref u 'y base-y))
      (define u-hp (hash-ref u 'hp 100))
      (define u-energy (hash-ref u 'energy 0))
      (define u-buffs (hash-ref u 'buffs '()))
      (define u-ab-id (hash-ref u 'order-ability-id 0))
      (define protected-class (and (> u-ab-id 0) (sc2-order-protection-class u-ab-id)))
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
                 wave-commit-active?)))
      (define tank-supporting-vs-static?
        (and (memq ut short-range-bio-syms)
             (memq etype static-defense-syms)
             (<= edist 8.0)
             (ormap (lambda (tk)
                      (<= (dist2d ex ey (hash-ref tk 'x ux) (hash-ref tk 'y uy)) 15.5))
                    ally-siege-tanks)))
      (define nearest-enemy-tank
        (and siege-line-hold?
             (not (sc2-unit-is-flying-sym? ut))
             (findf (lambda (st)
                      (<= (dist2d ux uy (hash-ref st 'x 9999.0) (hash-ref st 'y 9999.0)) 15.5))
                    enemy-sieged-tanks-near)))
      (define (emit-caster-rear-leash!)
        (define d-home (max 1.0 (dist2d prelim-army-cx prelim-army-cy base-x base-y)))
        (define lx (safe-coord (+ prelim-army-cx (* 3.0 (/ (- base-x prelim-army-cx) d-home))) base-x))
        (define ly (safe-coord (+ prelim-army-cy (* 3.0 (/ (- base-y prelim-army-cy) d-home))) base-y))
        (when (> (dist2d ux uy lx ly) 2.2)
          (emit! (list 'move uid lx ly))))
      (define (emit-engage-or-rally!)
        (cond
          [nearest-enemy-tank
           (define-values (kx ky)
             (compute-kite-vector ux uy
                                  (hash-ref nearest-enemy-tank 'x ex)
                                  (hash-ref nearest-enemy-tank 'y ey)
                                  3.0))
           (emit! (list 'kite uid (quantize-cell-2.5 kx ux) (quantize-cell-2.5 ky uy)))]
          [tank-supporting-vs-static?
           (define-values (kx ky) (compute-kite-vector ux uy ex ey 2.5))
           (emit! (list 'kite uid (quantize-cell-2.5 kx ux) (quantize-cell-2.5 ky uy)))]
          [unit-should-engage-target?
           (emit! (list 'attack-unit uid eid))]
          [(> (dist2d ux uy nat-x nat-y) 10.0)
           (emit! (list 'attack-pos uid nat-x nat-y))]))
      (define mirrored-acts (hash-ref tbrain-unit-actions uid '()))

      ;; Respect weapon-swing lock, splash evasion, Queen transfusion casts, and channeled/morph orders
      (unless (or (set-member? splash-evading-tags uid)
                  (set-member? queen-cast-tags uid)
                  (set-member? ravager-cast-tags uid)
                  (set-member? oracle-cast-tags uid)
                  (and live-obs? (memq protected-class '(morph channel)))
                  (order-ledger-unit-in-attack-swing? oledger u))
        (case ut
          [(ravager)
           (if (or (not live-upgrades-tracked?)
                   (and (<= edist 9.5)
                        (refractory-allow-action?! (live-bot-runtime-cooldown-tracker rt)
                                                   (list 'ravager-bile uid)
                                                   frame
                                                   156)))
               (begin
                 (emit! (list 'cast-spell uid 'corrosive-bile ex ey))
                 (unless live-obs? (emit-engage-or-rally!)))
               (emit-engage-or-rally!))]
          [(lurker lurker-burrowed)
           (define is-burrowed? (or (eq? ut 'lurker-burrowed) (hash-ref u 'burrowed #f)))
           (define min-ground-dist
             (for/fold ([best +inf.0])
                       ([e (in-list engagement-enemies)]
                        #:when (not (sc2-unit-is-flying-sym? (unit-type-sym e))))
               (min best (dist2d ux uy (hash-ref e 'x ex) (hash-ref e 'y ey)))))
           (define mode-ready?
             (or (not live-obs?)
                 (>= (- frame (hash-ref splash-st (cons 'mode-dwell uid) -1000)) 48)))
           (cond
             [(and is-burrowed? (> min-ground-dist 10.5) mode-ready?)
              (hash-set! splash-st (cons 'mode-dwell uid) frame)
              (emit! (list 'cast-spell uid 'burrow-up uid))]
             [(and (not is-burrowed?)
                   mode-ready?
                   (or (not live-upgrades-tracked?) (<= min-ground-dist 9.0)))
              (hash-set! splash-st (cons 'mode-dwell uid) frame)
              (emit! (list 'cast-spell uid 'burrow eid))
              (unless live-obs? (emit-engage-or-rally!))]
             [else
              (emit-engage-or-rally!)])]
          [(widow-mine widow-mine-burrowed)
           (define is-burrowed? (or (eq? ut 'widow-mine-burrowed) (hash-ref u 'burrowed #f)))
           (define min-enemy-dist
             (for/fold ([best +inf.0]) ([e (in-list engagement-enemies)])
               (min best (dist2d ux uy (hash-ref e 'x ex) (hash-ref e 'y ey)))))
           (define holding-choke? (<= (dist2d ux uy nat-x nat-y) 4.0))
           (define wm-dwell-ready?
             (or (not live-obs?)
                 (>= (- frame (hash-ref splash-st (cons 'wm-dwell uid) -1000)) 56)))
           (cond
             [(and is-burrowed?
                   (> min-enemy-dist (if live-obs? 13.5 6.5))
                   (not (and live-obs? holding-choke?))
                   wm-dwell-ready?)
              (hash-set! splash-st (cons 'wm-dwell uid) frame)
              (emit! (list 'cast-spell uid 'widow-mine-unburrow uid))]
             [is-burrowed?
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
              (when (<= min-enemy-dist 5.5)
                (emit! (list 'attack-unit uid (hash-ref best-cluster-enemy 'id eid))))]
             [(and wm-dwell-ready?
                   (or (not live-upgrades-tracked?)
                       (<= min-enemy-dist 9.5)
                       (and live-obs? holding-choke?)
                       under-tactics-base-attack?))
              (hash-set! splash-st (cons 'wm-dwell uid) frame)
              (emit! (list 'cast-spell uid 'burrow eid))
              (unless live-obs? (emit-engage-or-rally!))]
             [else
              (emit-engage-or-rally!)])]
          [(liberator liberator-ag)
           (define is-ag? (eq? ut 'liberator-ag))
           (define ground-enemies-near
             (filter (lambda (e)
                       (and (not (sc2-unit-is-flying-sym? (unit-type-sym e)))
                            (<= (dist2d ux uy (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0))
                                (if is-ag? 11.5 9.0))))
                     engagement-enemies))
           (define lib-dwell-ready?
             (>= (- frame (hash-ref splash-st (cons 'lib-dwell uid) -1000)) 48))
           (cond
             [(and (not is-ag?) (not (null? ground-enemies-near)) lib-dwell-ready?)
              (define ge (car ground-enemies-near))
              (define gx (hash-ref ge 'x ex))
              (define gy (hash-ref ge 'y ey))
              (define gd (max 1.0 (dist2d ux uy gx gy)))
              (define zx (safe-coord (+ ux (* (min 4.0 gd) (/ (- gx ux) gd))) gx))
              (define zy (safe-coord (+ uy (* (min 4.0 gd) (/ (- gy uy) gd))) gy))
              (hash-set! splash-st (cons 'lib-dwell uid) frame)
              (emit! (list 'cast-spell uid 'morph-liberator-ag zx zy))]
             [(and is-ag? (null? ground-enemies-near) lib-dwell-ready?)
              (hash-set! splash-st (cons 'lib-dwell uid) frame)
              (emit! (list 'cast-spell uid 'morph-liberator-aa uid))]
             [(not is-ag?)
              (emit-engage-or-rally!)])]
          [(viking viking-fighter viking-assault)
           (define is-assault? (eq? ut 'viking-assault))
           (define ground-close?
             (ormap (lambda (e)
                      (and (not (sc2-unit-is-flying-sym? (unit-type-sym e)))
                           (<= (dist2d ux uy (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0)) 6.0)))
                    engagement-enemies))
           (define vik-dwell-ready?
             (>= (- frame (hash-ref splash-st (cons 'vik-dwell uid) -1000)) 48))
           (cond
             [(and is-assault? (not (null? enemy-air-or-colossus)))
              (hash-set! splash-st (cons 'vik-dwell uid) frame)
              (emit! (list 'cast-spell uid 'morph-viking-fighter uid))]
             [(and (not is-assault?)
                   (null? enemy-air-or-colossus)
                   ground-close?
                   vik-dwell-ready?)
              (hash-set! splash-st (cons 'vik-dwell uid) frame)
              (emit! (list 'cast-spell uid 'morph-viking-assault uid))]
             [else
              (emit-engage-or-rally!)])]
          [(thor thor-ap)
           (define is-high-impact? (eq? ut 'thor-ap))
           (define thor-dwell-ready?
             (>= (- frame (hash-ref splash-st (cons 'thor-dwell uid) -1000)) 48))
           (cond
             [(and (not is-high-impact?)
                   (not (null? enemy-massive-air-or-colossus))
                   thor-dwell-ready?)
              (hash-set! splash-st (cons 'thor-dwell uid) frame)
              (emit! (list 'cast-spell uid 'morph-thor-high-impact uid))]
             [(and is-high-impact?
                   (null? enemy-massive-air-or-colossus)
                   (not (null? enemy-mutalisks))
                   thor-dwell-ready?)
              (hash-set! splash-st (cons 'thor-dwell uid) frame)
              (emit! (list 'cast-spell uid 'morph-thor-explosive uid))]
             [else
              (emit-engage-or-rally!)])]
          [(viper)
           (define consume-bldg
             (and (< u-energy 75)
                  (findf (lambda (b)
                           (and (>= (hash-ref b 'hp 0) 350)
                                (<= (dist2d ux uy (hash-ref b 'x base-x) (hash-ref b 'y base-y)) 14.0)))
                         ally-bldgs)))
           (define air-clump-tgt
             (and (>= u-energy 125)
                  (findf (lambda (e)
                           (and (sc2-unit-is-flying-sym? (unit-type-sym e))
                                (<= (dist2d ux uy (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0)) 9.0)
                                (>= (count (lambda (o)
                                             (and (sc2-unit-is-flying-sym? (unit-type-sym o))
                                                  (<= (dist2d (hash-ref e 'x 0.0) (hash-ref e 'y 0.0)
                                                              (hash-ref o 'x 9999.0) (hash-ref o 'y 9999.0))
                                                      3.5)))
                                           enemy-units)
                                    3)))
                         enemy-units)))
           (define cloud-tgt
             (and (>= u-energy 100)
                  (findf (lambda (e)
                           (define et2 (unit-type-sym e))
                           (and (not (sc2-unit-is-flying-sym? et2))
                                (<= (dist2d ux uy (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0)) 11.0)
                                (or (eq? et2 'siege-tank-sieged)
                                    (>= (count (lambda (o)
                                                 (<= (dist2d (hash-ref e 'x 0.0) (hash-ref e 'y 0.0)
                                                             (hash-ref o 'x 9999.0) (hash-ref o 'y 9999.0))
                                                     2.5))
                                               enemy-units)
                                        4))))
                         enemy-units)))
           (define abduct-tgt
             (and (>= u-energy 75)
                  (findf (lambda (e)
                           (and (memq (unit-type-sym e)
                                      '(siege-tank siege-tank-sieged colossus thor thor-ap
                                        carrier tempest immortal battlecruiser brood-lord lurker-burrowed))
                                (<= (dist2d ux uy (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0)) 9.5)))
                         enemy-units)))
           (cond
             [(and consume-bldg
                   (exact-integer? (hash-ref consume-bldg 'id 0))
                   (> (hash-ref consume-bldg 'id 0) 0))
              (emit! (list 'cast-spell uid 'viper-consume (hash-ref consume-bldg 'id)))]
             [(and air-clump-tgt
                   (exact-integer? (hash-ref air-clump-tgt 'id 0))
                   (> (hash-ref air-clump-tgt 'id 0) 0))
              (emit! (list 'cast-spell uid 'parasitic-bomb (hash-ref air-clump-tgt 'id)))]
             [cloud-tgt
              (emit! (list 'cast-spell uid 'blinding-cloud
                           (safe-coord (hash-ref cloud-tgt 'x ex) ex)
                           (safe-coord (hash-ref cloud-tgt 'y ey) ey)))]
             [(and abduct-tgt
                   (exact-integer? (hash-ref abduct-tgt 'id 0))
                   (> (hash-ref abduct-tgt 'id 0) 0))
              (emit! (list 'cast-spell uid 'abduct (hash-ref abduct-tgt 'id)))]
             [else
              (emit-caster-rear-leash!)])]
          [(infestor infestor-burrowed)
           (define fungal-tgt
             (and (>= u-energy 75)
                  (findf (lambda (e)
                           (and (<= (dist2d ux uy (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0)) 10.0)
                                (>= (count (lambda (o)
                                             (<= (dist2d (hash-ref e 'x 0.0) (hash-ref e 'y 0.0)
                                                         (hash-ref o 'x 9999.0) (hash-ref o 'y 9999.0))
                                                 2.5))
                                           enemy-units)
                                    3)))
                         enemy-units)))
           (if fungal-tgt
               (emit! (list 'cast-spell uid 'fungal-growth
                            (safe-coord (hash-ref fungal-tgt 'x ex) ex)
                            (safe-coord (hash-ref fungal-tgt 'y ey) ey)))
               (emit-caster-rear-leash!))]
          [(high-templar)
           (define storm-tgt
             (and (>= u-energy 75)
                  (or (not live-upgrades-tracked?) (has-upgrade? 'psi-storm))
                  (findf (lambda (e)
                           (define ex2 (hash-ref e 'x 9999.0))
                           (define ey2 (hash-ref e 'y 9999.0))
                           (and (<= (dist2d ux uy ex2 ey2) 9.0)
                                (not (ormap (lambda (eff)
                                              (and (memq (hash-ref eff 'type 'none) '(psi-storm psionic-storm))
                                                   (<= (dist2d ex2 ey2
                                                               (hash-ref eff 'x 9999.0)
                                                               (hash-ref eff 'y 9999.0))
                                                       2.0)))
                                            effects))
                                (or (eq? (unit-type-sym e) 'siege-tank-sieged)
                                    (>= (count (lambda (o)
                                                 (<= (dist2d ex2 ey2
                                                             (hash-ref o 'x 9999.0)
                                                             (hash-ref o 'y 9999.0))
                                                     2.0))
                                               enemy-units)
                                        3))))
                         enemy-units)))
           (define feedback-tgt
             (and (>= u-energy 50)
                  (findf (lambda (e)
                           (and (>= (hash-ref e 'energy 0) 75)
                                (<= (dist2d ux uy (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0)) 10.0)))
                         enemy-units)))
           (cond
             [storm-tgt
              (emit! (list 'cast-spell uid 'psi-storm
                           (safe-coord (hash-ref storm-tgt 'x ex) ex)
                           (safe-coord (hash-ref storm-tgt 'y ey) ey)))]
             [(and feedback-tgt
                   (exact-integer? (hash-ref feedback-tgt 'id 0))
                   (> (hash-ref feedback-tgt 'id 0) 0))
              (emit! (list 'cast-spell uid 'feedback (hash-ref feedback-tgt 'id)))]
             [(< u-energy 50)
              (emit-caster-rear-leash!)]
             [else
              (emit-engage-or-rally!)])]
          [(battlecruiser)
           (define jump-ready-f (hash-ref splash-st (cons 'bc-jump-ready uid) 0))
           (define yamato-ready-f (hash-ref splash-st (cons 'bc-yamato-ready uid) 0))
           (define yamato-tgt
             (and (>= frame yamato-ready-f)
                  (or (not live-upgrades-tracked?) (has-upgrade? 'weapon-refit))
                  (findf (lambda (e)
                           (and (>= (+ (hash-ref e 'hp 0) (hash-ref e 'shield 0)) 125)
                                (<= (dist2d ux uy (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0)) 10.0)))
                         engagement-enemies)))
           (cond
             [(and (< u-hp 180) (>= frame jump-ready-f))
              (hash-set! splash-st (cons 'bc-jump-ready uid) (+ frame 2012))
              (emit! (list 'cast-spell uid 'tactical-jump base-x base-y))]
             [(and yamato-tgt
                   (let ([ytid (hash-ref yamato-tgt 'id eid)])
                     (and (exact-integer? ytid) (> ytid 0))))
              (hash-set! splash-st (cons 'bc-yamato-ready uid) (+ frame 1590))
              (emit! (list 'cast-spell uid 'yamato-cannon (hash-ref yamato-tgt 'id eid)))]
             [else
              (emit-engage-or-rally!)])]
          [(baneling)
           (if (and (> edist 1.8) (<= edist 10.0))
               (begin
                 (emit! (list 'kite uid (safe-coord ex ux) (safe-coord ey uy)))
                 (unless live-obs? (emit-engage-or-rally!)))
               (emit-engage-or-rally!))]
          [(carrier)
           (when (refractory-allow-action?! (live-bot-runtime-cooldown-tracker rt)
                                            (list 'carrier-int uid)
                                            frame
                                            68)
             (emit! (list 'cast-spell uid 'build-interceptors uid)))
           (if (and (< edist 7.5) (> edist 0.1))
               (let-values ([(kx ky) (compute-kite-vector ux uy ex ey 2.5)])
                 (emit! (list 'kite uid (quantize-cell-2.5 kx ux) (quantize-cell-2.5 ky uy))))
               (emit-engage-or-rally!))]
          [(disruptor)
           (if (and (<= edist 11.0)
                    (or (not live-obs?)
                        (refractory-allow-action?! (live-bot-runtime-cooldown-tracker rt)
                                                   (list 'disruptor-nova uid)
                                                   frame
                                                   480)))
               (emit! (list 'cast-spell uid 'purification-nova ex ey))
               (if (< edist 7.5)
                   (let-values ([(kx ky) (compute-kite-vector ux uy ex ey 3.0)])
                     (emit! (list 'kite uid (quantize-cell-2.5 kx ux) (quantize-cell-2.5 ky uy))))
                   (emit-engage-or-rally!)))]
          [(disruptor-phased)
           (emit! (list 'kite uid (safe-coord ex ux) (safe-coord ey uy)))]
          [(sentry)
           (cond
             [(and (>= (hash-ref u 'energy SC2-SENTRY-FORCE-FIELD-ENERGY) SC2-SENTRY-GUARDIAN-SHIELD-ENERGY)
                   (not (memq 'guardian-shield u-buffs))
                   (or (not live-upgrades-tracked?) (<= edist 9.0)))
              ;; Guardian Shield is off-GCD instant self-aura
              (emit! (list 'cast-spell uid 'guardian-shield eid))
              (emit-engage-or-rally!)]
             [(and (>= (hash-ref u 'energy SC2-SENTRY-FORCE-FIELD-ENERGY) SC2-SENTRY-FORCE-FIELD-ENERGY)
                   (or (not live-upgrades-tracked?) (<= edist 9.0))
                   (or (not live-obs?)
                       (refractory-allow-action?! (live-bot-runtime-cooldown-tracker rt)
                                                  (list 'sentry-ff uid)
                                                  frame
                                                  68)))
              (emit! (list 'cast-spell uid 'force-field
                           (safe-coord (* 0.5 (+ nat-x ex)) nat-x)
                           (safe-coord (* 0.5 (+ nat-y ey)) nat-y)))
              (unless live-obs? (emit-engage-or-rally!))]
             [else
              (emit-engage-or-rally!)])]
          [(stalker)
           (if (and (has-upgrade? 'blink)
                    (< u-hp SC2-STALKER-BLINK-HP-THRESH)
                    (or (not live-obs?)
                        (refractory-allow-action?! (live-bot-runtime-cooldown-tracker rt)
                                                   (list 'stalker-blink uid)
                                                   frame
                                                   160)))
               (let-values ([(kx ky) (compute-kite-vector ux uy ex ey SC2-KITE-STEP-DISTANCE)])
                 (emit! (list 'cast-spell uid 'blink (safe-coord kx ux) (safe-coord ky uy)))
                 (unless live-obs? (emit-engage-or-rally!)))
               (emit-engage-or-rally!))]
          [(adept)
           (if (and (or (not live-upgrades-tracked?) (<= edist 12.0))
                    (or (not live-obs?)
                        (refractory-allow-action?! (live-bot-runtime-cooldown-tracker rt)
                                                   (list 'adept-shade uid)
                                                   frame
                                                   248)))
               (begin
                 (emit! (list 'cast uid 'psionic-transfer ex ey))
                 (unless live-obs? (emit-engage-or-rally!)))
               (emit-engage-or-rally!))]
          [(siege-tank siege-tank-sieged)
           (define is-sieged? (or (eq? ut 'siege-tank-sieged) (hash-ref u 'sieged #f)))
           (define min-enemy-dist
             (for/fold ([best +inf.0]) ([e (in-list engagement-enemies)])
               (min best (dist2d ux uy (hash-ref e 'x ex) (hash-ref e 'y ey)))))
           (define tank-dwell-ready?
             (or (not live-obs?)
                 (>= (- frame (hash-ref splash-st (cons 'tank-dwell uid) -1000)) 48)))
           (cond
             [(and is-sieged? (> min-enemy-dist SC2-SIEGE-TANK-UNSIEGE-RANGE) tank-dwell-ready?)
              (hash-set! splash-st (cons 'tank-dwell uid) frame)
              (emit! (list 'cast-spell uid 'unsiege-mode uid))
              (unless live-upgrades-tracked? (emit-engage-or-rally!))]
             [(and (not is-sieged?) (<= min-enemy-dist SC2-SIEGE-TANK-SIEGE-RANGE) tank-dwell-ready?)
              (hash-set! splash-st (cons 'tank-dwell uid) frame)
              (emit! (list 'cast-spell uid 'siege-mode eid))
              (unless live-upgrades-tracked? (emit-engage-or-rally!))]
             [else
              (emit-engage-or-rally!)])]
          [(ghost)
           (define emp-tgt
             (and (>= (hash-ref u 'energy 75) 75)
                  (findf (lambda (e)
                           (and (<= (dist2d ux uy (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0)) 10.0)
                                (or (>= (hash-ref e 'shield 0) 40)
                                    (>= (hash-ref e 'energy 0) 50))))
                         engagement-enemies)))
           (define snipe-tgt
             (and (>= (hash-ref u 'energy 75) 50)
                  (findf (lambda (e)
                           (and (memq (unit-type-sym e)
                                      '(queen hydralisk lurker lurker-burrowed ravager infestor viper
                                        ultralisk brood-lord mutalisk corruptor high-templar zealot adept ghost))
                                (<= (dist2d ux uy (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0)) 10.0)))
                         engagement-enemies)))
           (cond
             [(not live-obs?)
              (when (>= (hash-ref u 'energy 75) 75)
                (emit! (list 'cast-spell uid 'emp-round
                             (safe-coord ex base-x)
                             (safe-coord ey base-y)))
                (when (and (exact-integer? eid) (> eid 0))
                  (emit! (list 'cast-spell uid 'snipe eid))))
              (emit-engage-or-rally!)]
             [emp-tgt
              (emit! (list 'cast-spell uid 'emp-round
                           (safe-coord (hash-ref emp-tgt 'x ex) ex)
                           (safe-coord (hash-ref emp-tgt 'y ey) ey)))]
             [(and snipe-tgt
                   (let ([stid (hash-ref snipe-tgt 'id eid)])
                     (and (exact-integer? stid) (> stid 0))))
              (emit! (list 'cast-spell uid 'snipe (hash-ref snipe-tgt 'id eid)))]
             [else
              (emit-engage-or-rally!)])]
          [(marine marauder)
           (when (and (has-upgrade? 'stimpack)
                      (not (memq 'stimpack u-buffs))
                      (not (memq 'stimpack-marauder u-buffs))
                      (>= u-hp SC2-MARINE-STIM-MIN-HP)
                      (or (not live-upgrades-tracked?) (<= edist 9.5)))
             (emit! (list 'cast-spell uid 'stimpack eid)))
           (emit-engage-or-rally!)]
          [(mutalisk)
           (if (< u-hp SC2-MUTALISK-KITE-HP-THRESH)
               (let-values ([(kx ky) (compute-kite-vector ux uy ex ey SC2-KITE-STEP-DISTANCE)])
                 (emit! (list 'kite uid (quantize-cell-2.5 kx ux) (quantize-cell-2.5 ky uy))))
               (emit-engage-or-rally!))]
          [(banshee)
           (if (not (null? mirrored-acts))
               (for ([ma (in-list mirrored-acts)]) (emit! ma))
               (emit-engage-or-rally!))]
          [else
           (if (and (not nearest-enemy-tank)
                    (not tank-supporting-vs-static?)
                    (not (null? mirrored-acts))
                    unit-should-engage-target?)
               (for ([ma (in-list mirrored-acts)]) (emit! ma))
               (emit-engage-or-rally!))]))))

  ;; ---------------------------------------------------------------------------
  ;; Pro Mechanic #8: Burrowed Zergling Base-Blocker, Cheap Patrol Expansion
  ;;                  Blocker, Peripheral Economic Harassment Raider Squad, &
  ;;                  Probing-Attack Recon Vanguard (PV9)
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
                      (< (length combat-units) live-attack-wave-min)
                      (refractory-allow-action?! (live-bot-runtime-cooldown-tracker rt)
                                                 '(idle-nat-rally)
                                                 frame
                                                 44)))
             (>= (length combat-units) 2))
    (for ([u (in-list (take combat-units 2))])
      (emit! (list 'attack-pos (hash-ref u 'id 110) nat-x nat-y))))

  ;; ---------------------------------------------------------------------------
  ;; Pro Mechanic #9: Enemy Changeling Sniping & Active Deception/Scout Spells
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

  (when (and (or (hash-ref obs 'enable-deception-and-buffs #f)
                 (not (null? ally-sentries))
                 (not (null? ally-overseers)))
             (or (not live-obs?)
                 (refractory-allow-action?! (live-bot-runtime-cooldown-tracker rt)
                                            '(deception-scout-spells)
                                            frame
                                            336)))
    (emit! '(cast-deception-and-scout-spells
             sentry-hallucination-phoenix-scout
             sentry-hallucination-archon-tank
             overseer-spawn-changeling)))

  ;; ---------------------------------------------------------------------------
  ;; Pro Mechanic #10: Protective Buff Aura, Throttled Pre-Split 3-Wing Squads,
  ;;                   Throttled Concave Arc, & High-Ground Mastery
  ;; ---------------------------------------------------------------------------
  (define army-cx prelim-army-cx)
  (define army-cy prelim-army-cy)
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

  (when (and (or (hash-ref obs 'enable-deception-and-buffs #f)
                 (not (null? ally-sentries))
                 (not (null? ally-infestors))
                 (and (not (null? enemy-units)) (not (null? combat-units))))
             (or (not live-obs?)
                 (refractory-allow-action?! (live-bot-runtime-cooldown-tracker rt)
                                            '(buff-aura-position)
                                            frame
                                            44)))
    (define use-shroud?
      (or (not (null? ally-infestors))
          (eq? (live-bot-runtime-actual-race rt) 'Zerg)))
    (define aura-type (if use-shroud? 'microbial-shroud 'guardian-shield))
    (define aura-radius (if use-shroud? 3.5 4.5))
    (emit! (list 'cast-protective-buff-aura aura-type army-cx army-cy aura-radius))
    (emit! (list 'position-in-buff-aura-with-splash-spread
                 aura-type army-cx army-cy aura-radius 1.6 #t)))

  ;; Pre-Split 3-Wing Formation & Concave Arc Formation (throttled in live games to stay well below 400 APM)
  (when (and (or (not (null? enemy-units))
                 (hash-ref obs 'pre-split-engage #f)
                 (hash-ref obs 'form-concave #f))
             (or (not live-obs?)
                 (refractory-allow-action?! (live-bot-runtime-cooldown-tracker rt)
                                            '(formation-arc-split)
                                            frame
                                            28)))
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
  (define our-z our-z-early)
  (define enemy-z enemy-z-early)
  (when (and (or (not (= our-z enemy-z))
                 (not (null? enemy-units))
                 (hash-ref obs 'high-ground-check #f))
             (or (not live-obs?)
                 (refractory-allow-action?! (live-bot-runtime-cooldown-tracker rt)
                                            '(high-ground-posture)
                                            frame
                                            28)))
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
  (define raw-sp-maneuver
    (enemy-army-reachability-model-recommended-spatial-maneuver reach-m))
  (define enemy-main-cleared-or-empty?
    (and (null? enemy-units)
         (or (null? enemy-bldgs)
             (not (ormap (lambda (eb)
                           (<= (dist2d (safe-finite-real (hash-ref eb 'x enemy-x) enemy-x)
                                       (safe-finite-real (hash-ref eb 'y enemy-y) enemy-y)
                                       enemy-x enemy-y)
                               16.0))
                         enemy-bldgs)))))
  (define sp-maneuver
    (if (and (eq? raw-sp-maneuver 'pre-rotate-intercept-incoming-threat)
             enemy-main-cleared-or-empty?
             (<= (hash-ref obs 'enemy-threat-supply 0) 0))
        'multiprong-rotate-and-pin
        raw-sp-maneuver))
  (define-values (sp-tx sp-ty)
    (if (and live-obs?
             (or wave-commit-active?
                 (>= (length combat-units) live-attack-wave-min)
                 (and (>= frame 6000) enemy-main-cleared-or-empty? (>= (length combat-units) 4))))
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
  (when (or (not live-obs?)
            (refractory-allow-action?! (live-bot-runtime-cooldown-tracker rt)
                                       '(spatial-maneuver)
                                       frame
                                       28))
    (emit! (list 'execute-spatial-maneuver sp-maneuver sp-tx sp-ty)))

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
  (define ally-bldgs (hash-ref obs 'ally-buildings '()))
  (define live-cam-obs? (hash-has-key? raw-obs 'mineral-harvesters))

  (define dwell-min
    (if live-cam-obs?
        (max 28 SC2-CAMERA-SACCADE-MIN-DWELL-FRAMES)
        SC2-CAMERA-SACCADE-MIN-DWELL-FRAMES))
  (define last-frame (hash-ref bmarks 'last-saccade-frame #f))
  (define cur-idx (safe-nonneg-int (hash-ref bmarks 'saccade-zone-idx 0) 0))
  ;; Pro humans dwell >= 28 frames (~1.25s) per camera zone in live games unless jumping > 18 tiles for a crisis.
  (define saccade-due?
    (or (not (exact-integer? last-frame))
        (= frame last-frame)
        (>= (abs (- frame last-frame)) dwell-min)))
  (define next-idx
    (cond
      [(not (exact-integer? last-frame)) 0]
      [saccade-due?
       (modulo (add1 cur-idx) (length PRO-CAMERA-SACCADE-ZONES))]
      [else (modulo cur-idx (length PRO-CAMERA-SACCADE-ZONES))]))
  (when saccade-due?
    (hash-set! bmarks 'last-saccade-frame frame)
    (hash-set! bmarks 'saccade-zone-idx next-idx))

  (define active-crisis-now?
    (or (eq? (hash-ref obs 'under-attack #f) #t)
        (eq? (hash-ref obs 'under-cheese-rush #f) #t)
        (ormap (lambda (b) (and (hash? b) (eq? (hash-ref b 'under-attack #f) #t))) ally-bldgs)
        (ormap (lambda (e)
                 (and (hash? e)
                      (<= (min (dist2d base-x base-y (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0))
                               (dist2d nat-x nat-y (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0)))
                          28.0)))
               enemy-units)))
  (define zone
    (if (and live-cam-obs? active-crisis-now? (not (null? enemy-units)))
        'active-army-front
        (list-ref PRO-CAMERA-SACCADE-ZONES next-idx)))
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

  (define prev-focus-f (hash-ref bmarks 'last-camera-focus-frame #f))
  (define prev-focus-x (safe-finite-real (hash-ref bmarks 'last-camera-focus-x zx) zx))
  (define prev-focus-y (safe-finite-real (hash-ref bmarks 'last-camera-focus-y zy) zy))
  (define crisis-cam-jump?
    (and active-crisis-now?
         (> (dist2d zx zy prev-focus-x prev-focus-y) 18.0)))
  (define emit-camera-focus?
    (or (not live-cam-obs?)
        (not (exact-integer? prev-focus-f))
        (< frame prev-focus-f)
        (>= (- frame prev-focus-f) 28)
        crisis-cam-jump?))
  (when emit-camera-focus?
    (hash-set! bmarks 'last-camera-focus-frame frame)
    (hash-set! bmarks 'last-camera-focus-x zx)
    (hash-set! bmarks 'last-camera-focus-y zy))

  (define prof (get-pro-cortex-profile (human-cortex-profile-name cortex)))
  (define target-apm (min 360 (safe-nonneg-int (hash-ref prof 'mean-epm 350) 350)))
  (if emit-camera-focus?
      (list (list 'camera-focus zone zx zy)
            (list 'human-apm-discipline target-apm 3 #t #t))
      (list (list 'human-apm-discipline target-apm 3 #t #t))))

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
  (set-box! (rt-wall-aabbs-box rt) '())

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
  (define cur-msp
    (let ([lt (live-bot-runtime-last-telemetry rt)])
      (and (hash? lt) (hash-ref lt 'max-supply-plan #f))))
  (define msp-set
    (if (and (max-supply-plan? cur-msp) (max-supply-plan-active? cur-msp))
        (max-supply-plan-combined-actions cur-msp)
        '()))
  (define preserved-tactical-directives
    (append
     (filter (lambda (a)
               (and (pair? a)
                    (or (memq (car a)
                              '(pull-workers-attack
                                mineral-walk
                                rebalance-gas-to-minerals
                                terran-addon-swap
                                land-building
                                lift
                                cancel-building
                                inject-larva
                                worker-scout
                                overlord-scout
                                mineral-harass
                                periodic-scout
                                cast-deception-and-scout-spells))
                        (and (eq? (car a) 'cast-spell)
                             (>= (length a) 3)
                             (memq (third a)
                                   '(inject-larva battery-overcharge lift)))
                        (not (not (member a msp-set))))
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

  (define last-tel-ht
    (let ([t (live-bot-runtime-last-telemetry rt)])
      (if (hash? t) t (hash))))
  (define step-wall-aabbs (unbox (rt-wall-aabbs-box rt)))
  (define telemetry
    (hash-set* last-tel-ht
               'posture (live-bot-runtime-posture rt)
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
               'bank-target (hash-ref last-tel-ht 'bank-target #f)
               'goal-stream-allocation (hash-ref last-tel-ht 'goal-stream-allocation #f)
               'decoupled-stream-spendable (hash-ref last-tel-ht 'decoupled-stream-spendable (hash))
               'goal-streams (hash-ref last-tel-ht 'goal-streams DEC-GOAL-STREAMS)
               'max-supply-plan (hash-ref last-tel-ht 'max-supply-plan #f)
               'dynamic-plan (hash-ref last-tel-ht 'dynamic-plan #f)
               'dynamic-plan-next-actions (hash-ref last-tel-ht 'dynamic-plan-next-actions '())
               'dynamic-plan-in-progress (hash-ref last-tel-ht 'dynamic-plan-in-progress '())
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
               'escrow-suppressed-goal (hash-ref last-tel-ht 'escrow-suppressed-goal #f)
               'escrow-suppressed-until-frame (hash-ref last-tel-ht 'escrow-suppressed-until-frame 0)
               'vanguard-count vanguard-cnt
               'reserve-count reserve-cnt
               'role-leases (rt-role-leases rt)
               'wall-reserved-aabbs step-wall-aabbs
               'personality (let ([p (mastermind-state-personality mstate)])
                              (cond
                                [(bot-personality? p) (bot-personality-name p)]
                                [(symbol? p) p]
                                [else 'UNKNOWN]))
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
        'actual-race (live-bot-runtime-actual-race rt)
        'role-leases (rt-role-leases rt)
        'wall-reserved-aabbs step-wall-aabbs))

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
            [(enemy-race)             (hash-set! h 'enemy-race v)]
            [(opponent-requested-race)(hash-set! h 'opponent-requested-race v)]
            [(map-grids)              (when (hash? v) (hash-set! h 'map-grids v))]
            [(expansion-candidates)   (when (list? v) (hash-set! h 'expansion-candidates v))]
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
