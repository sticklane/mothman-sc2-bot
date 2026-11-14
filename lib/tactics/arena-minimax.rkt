#lang racket/base

;; =============================================================================
;; `lib/tactics/arena-minimax.rkt`
;; Multi-Depth Mirrored Tactical Micro Brain (`step-tactical-mirror-brain!`):
;;   - Spatial single-linkage arena clustering (`cluster-tactical-arenas`)
;;   - 2D kinematic & weapon-cooldown mirrored rollout (`simulate-mirrored-arena-pair`)
;;   - Regret-hedged minimax & commitment hysteresis (`evaluate-arena-minimax-and-regret!`)
;;   - Per-unit command synthesis gated by `order-ledger`
;; =============================================================================

(require racket/match
         racket/list
         racket/math
         racket/set
         "../sc2-common.rkt"
         "../sc2-game-constants.rkt"
         "../sc2-combat-eval.rkt"
         "order-ledger.rkt")

(provide
 TACTICAL-MICRO-ACTION-SPACE
 (struct-out tactical-sim-unit)
 (struct-out tactical-arena)
 (struct-out tactical-horizon-eval)
 (struct-out mirrored-rollout-result)
 (struct-out arena-commitment-state)
 (struct-out tactical-mirror-brain)
 make-tactical-mirror-brain
 unit-hash->tactical-sim-unit
 sim-unit-weapon-dps-vs
 cluster-tactical-arenas
 simulate-mirrored-arena-pair
 evaluate-arena-minimax-and-regret!
 resolve-committed-micro-action!
 step-tactical-mirror-brain!)

(define TACTICAL-MICRO-ACTION-SPACE
  '(CommitFocusFire
    StutterKiteBack
    KiteForwardChase
    FlankSurround
    CloakHarassWorkers
    DisengageRetreat
    HoldChoke))

(struct tactical-sim-unit
  (id
   type
   side            ;; 'ally or 'enemy
   hp
   max-hp
   shield
   armor
   speed
   ground-dps
   air-dps
   ground-range
   air-range
   weapon-period
   damage-point
   weapon-cooldown
   splash-radius
   flying?
   detector?
   cloaked?
   can-cloak?
   energy
   cost
   x
   y
   radius
   eta-sec)        ;; 0.0 if already in arena, > 0.0 for arriving reinforcements
  #:mutable
  #:transparent)

(struct tactical-arena
  (id
   center-x
   center-y
   ally-units
   enemy-units
   enemy-workers
   enemy-structures
   reinforcing-allies
   reinforcing-enemies
   choke-x
   choke-y
   choke-span
   our-z
   enemy-z
   ally-has-detection?
   enemy-has-detection?)
  #:transparent)

(struct tactical-horizon-eval
  (depth-sec
   ally-surviving-cost
   enemy-surviving-cost
   ally-hp-ratio
   enemy-hp-ratio
   workers-killed
   hero-units-lost
   net-value)
  #:transparent)

(struct mirrored-rollout-result
  (our-action
   enemy-action
   d1-eval
   d2-eval
   d3-eval
   combined-value)
  #:transparent)

(struct arena-commitment-state
  (arena-id
   committed-action
   predicted-enemy-action
   focus-target-id
   committed-since-frame
   lock-until-frame
   enemy-action-regrets  ;; hash: action-sym -> cumulative score
   last-enemy-cx
   last-enemy-cy)
  #:mutable
  #:transparent)

(struct tactical-mirror-brain
  (arena-states          ;; mutable hash: arena-id -> arena-commitment-state
   active-arenas         ;; list of tactical-arena from latest step
   last-decisions)       ;; list of decision hashes from latest step
  #:mutable
  #:transparent)

(define (make-tactical-mirror-brain)
  (tactical-mirror-brain (make-hash) '() '()))

(define (unit-hash->tactical-sim-unit u [side 'ally] #:eta-sec [eta-sec 0.0])
  (define utype (hash-ref u 'type 'marine))
  (define stats (sc2-unit-combat-stats utype))
  (define m-cost (sc2-min-cost utype 50))
  (define g-cost (sc2-gas-cost utype 0))
  (define unit-val (+ m-cost (* 1.5 g-cost)))
  (define max-hp (max 1.0 (exact->inexact (hash-ref u 'max-hp (hash-ref stats 'max-hp 80)))))
  (define hp (max 1.0 (exact->inexact (hash-ref u 'hp max-hp))))
  (define shd (max 0.0 (exact->inexact (hash-ref u 'shield (hash-ref stats 'max-shield 0)))))
  (tactical-sim-unit
   (hash-ref u 'id 0)
   utype
   side
   hp
   max-hp
   shd
   (exact->inexact (hash-ref stats 'armor 0))
   (exact->inexact (hash-ref u 'speed (hash-ref stats 'speed 3.15)))
   (exact->inexact (hash-ref stats 'ground-dps 10.0))
   (exact->inexact (hash-ref stats 'air-dps 0.0))
   (exact->inexact (hash-ref stats 'ground-range 5.0))
   (exact->inexact (hash-ref stats 'air-range 0.0))
   (max 0.16 (exact->inexact (hash-ref stats 'weapon-period 1.0)))
   (exact->inexact (hash-ref stats 'damage-point 0.10))
   (max 0.0 (exact->inexact (hash-ref u 'weapon-cooldown 0.0)))
   (exact->inexact (hash-ref stats 'splash-radius 0.0))
   (eq? (hash-ref u 'flying? (hash-ref stats 'flying? #f)) #t)
   (eq? (hash-ref stats 'detector? #f) #t)
   (or (eq? (hash-ref u 'cloaked #f) #t)
       (eq? (hash-ref u 'burrowed #f) #t))
   (eq? (hash-ref stats 'can-cloak? #f) #t)
   (exact->inexact (hash-ref u 'energy 0))
   (exact->inexact unit-val)
   (exact->inexact (hash-ref u 'x 32.5))
   (exact->inexact (hash-ref u 'y 32.5))
   (exact->inexact (hash-ref u 'radius (hash-ref stats 'radius 0.5)))
   (exact->inexact eta-sec)))

(define (clone-tactical-sim-unit su)
  (struct-copy tactical-sim-unit su))

(define (cluster-tactical-arenas ally-units raw-enemy-units enemy-bldgs
                                 #:chokes [chokes '()]
                                 #:our-z [our-z 10]
                                 #:enemy-z [enemy-z 10])
  (define enemy-units
    (filter sc2-enemy-unit-targetable? raw-enemy-units))
  (define combat-allies
    (filter (lambda (u)
              (and (hash? u)
                   (not (memq (hash-ref u 'type #f)
                              '(drone scv probe larva egg overlord mule)))))
            ally-units))
  (cond
    [(or (null? combat-allies) (and (null? enemy-units) (null? enemy-bldgs)))
     '()]
    [else
     ;; Single-linkage squad clustering within SC2-TACTICAL-ARENA-CLUSTER-RADIUS
     (define visited (mutable-seteqv))
     (define squads '())
     (for ([u (in-list combat-allies)])
       (define uid (hash-ref u 'id 0))
       (unless (set-member? visited uid)
         (set-add! visited uid)
         (define ux (hash-ref u 'x 32.5))
         (define uy (hash-ref u 'y 32.5))
         (define cluster
           (cons u
                 (for/list ([v (in-list combat-allies)]
                            #:when (and (not (set-member? visited (hash-ref v 'id 0)))
                                        (<= (dist2d ux uy (hash-ref v 'x ux) (hash-ref v 'y uy))
                                            SC2-TACTICAL-ARENA-CLUSTER-RADIUS)))
                   (set-add! visited (hash-ref v 'id 0))
                   v)))
         (set! squads (cons cluster squads))))

     (define arenas '())
     (for ([sq (in-list (reverse squads))])
       (define n (max 1 (length sq)))
       (define cx (/ (for/sum ([u (in-list sq)]) (exact->inexact (hash-ref u 'x 32.5))) n))
       (define cy (/ (for/sum ([u (in-list sq)]) (exact->inexact (hash-ref u 'y 32.5))) n))
       (define local-enemies
         (filter (lambda (e)
                   (<= (dist2d cx cy (hash-ref e 'x 999.0) (hash-ref e 'y 999.0))
                       SC2-TACTICAL-ARENA-ENGAGE-RADIUS))
                 enemy-units))
       (define local-enemy-bldgs
         (filter (lambda (eb)
                   (<= (dist2d cx cy (hash-ref eb 'x 999.0) (hash-ref eb 'y 999.0))
                       SC2-TACTICAL-ARENA-ENGAGE-RADIUS))
                 enemy-bldgs))
       (when (or (not (null? local-enemies)) (not (null? local-enemy-bldgs)))
         (define enemy-workers
           (filter (lambda (e) (memq (hash-ref e 'type #f) '(scv probe drone))) local-enemies))
         (define reinf-allies
           (for/list ([u (in-list combat-allies)]
                      #:when (let ([d (dist2d cx cy (hash-ref u 'x cx) (hash-ref u 'y cy))])
                               (and (> d SC2-TACTICAL-ARENA-CLUSTER-RADIUS)
                                    (<= d SC2-TACTICAL-REINFORCE-RADIUS))))
             (define d (dist2d cx cy (hash-ref u 'x cx) (hash-ref u 'y cy)))
             (define spd (max 2.0 (hash-ref (sc2-unit-combat-stats (hash-ref u 'type 'marine)) 'speed 3.15)))
             (unit-hash->tactical-sim-unit u 'ally #:eta-sec (/ (- d 6.0) spd))))
         (define reinf-enemies
           (for/list ([e (in-list enemy-units)]
                      #:when (let ([d (dist2d cx cy (hash-ref e 'x cx) (hash-ref e 'y cy))])
                               (and (> d SC2-TACTICAL-ARENA-ENGAGE-RADIUS)
                                    (<= d SC2-TACTICAL-REINFORCE-RADIUS))))
             (define d (dist2d cx cy (hash-ref e 'x cx) (hash-ref e 'y cy)))
             (define spd (max 2.0 (hash-ref (sc2-unit-combat-stats (hash-ref e 'type 'marine)) 'speed 3.15)))
             (unit-hash->tactical-sim-unit e 'enemy #:eta-sec (/ (- d 6.0) spd))))
         (define ally-det?
           (ormap (lambda (u) (sc2-unit-is-detector-sym? (hash-ref u 'type 'marine))) sq))
         (define enemy-det?
           (or (ormap (lambda (e) (sc2-unit-is-detector-sym? (hash-ref e 'type 'marine))) local-enemies)
               (ormap (lambda (eb) (sc2-unit-is-detector-sym? (hash-ref eb 'type 'pylon))) local-enemy-bldgs)))
         (define sector-id
           (+ (* 100 (exact-floor (/ cx 16.0)))
              (exact-floor (/ cy 16.0))))
         (set! arenas
               (cons (tactical-arena
                      sector-id
                      cx cy
                      (map (lambda (u) (unit-hash->tactical-sim-unit u 'ally)) sq)
                      (map (lambda (e) (unit-hash->tactical-sim-unit e 'enemy)) local-enemies)
                      enemy-workers
                      local-enemy-bldgs
                      reinf-allies
                      reinf-enemies
                      cx cy 10.0
                      our-z enemy-z
                      ally-det? enemy-det?)
                     arenas))))
     (reverse arenas)]))

(define (sim-unit-weapon-dps-vs attacker target)
  (define base-dps
    (if (tactical-sim-unit-flying? target)
        (tactical-sim-unit-air-dps attacker)
        (tactical-sim-unit-ground-dps attacker)))
  (define atype (tactical-sim-unit-type attacker))
  (define ttype (tactical-sim-unit-type target))
  (define attr-mult
    (cond
      [(and (memq atype '(immortal marauder stalker siege-tank siege-tank-sieged
                          lurker-mp-burrowed lurker lurker-burrowed void-ray
                          corruptor viking ultralisk))
            (memq ttype '(roach marauder stalker immortal siege-tank siege-tank-sieged
                          thor ultralisk colossus lurker-mp-burrowed lurker lurker-burrowed
                          viking void-ray corruptor battlecruiser carrier tempest)))
       1.45]
      [(and (memq atype '(baneling hellion hellbat colossus oracle archon
                          adept reaper phoenix mutalisk))
            (memq ttype '(zergling baneling hydralisk marine reaper hellion
                          zealot adept high-templar dark-templar sentry
                          drone scv probe mutalisk phoenix oracle)))
       1.55]
      [else 1.0]))
  (* base-dps attr-mult))

(define (sim-unit-weapon-range-vs attacker target)
  (if (tactical-sim-unit-flying? target)
      (tactical-sim-unit-air-range attacker)
      (tactical-sim-unit-ground-range attacker)))

(define (sim-unit-can-target? attacker target opp-has-detection?)
  (and (> (+ (tactical-sim-unit-hp target) (tactical-sim-unit-shield target)) 0.0)
       (<= (tactical-sim-unit-eta-sec attacker) 0.0)
       (<= (tactical-sim-unit-eta-sec target) 0.0)
       (or (not (tactical-sim-unit-cloaked? target)) opp-has-detection?)
       (> (sim-unit-weapon-dps-vs attacker target) 0.0)))

(define (step-kinematic-and-combat-tick! sim-allies sim-enemies
                                         our-action enemy-action
                                         arena dt)
  (define ally-det? (tactical-arena-ally-has-detection? arena))
  (define enemy-det? (tactical-arena-enemy-has-detection? arena))
  (define our-z (exact->inexact (tactical-arena-our-z arena)))
  (define enemy-z (exact->inexact (tactical-arena-enemy-z arena)))
  (define ally-worker-count
    (for/sum ([a (in-list sim-allies)]
              #:when (and (> (tactical-sim-unit-hp a) 0.0)
                          (memq (tactical-sim-unit-type a) '(scv probe drone))))
      1))

  ;; Activate cloak on CloakHarassWorkers if unit can cloak and has energy >= 25
  (when (eq? our-action 'CloakHarassWorkers)
    (for ([a (in-list sim-allies)]
          #:when (and (tactical-sim-unit-can-cloak? a)
                      (>= (tactical-sim-unit-energy a) SC2-BANSHEE-CLOAK-MIN-ENERGY)))
      (set-tactical-sim-unit-cloaked?! a #t)))

  ;; Decrement reinforcement ETAs and weapon cooldowns
  (define (tick-unit-cooldowns! u)
    (when (> (tactical-sim-unit-eta-sec u) 0.0)
      (set-tactical-sim-unit-eta-sec! u (max 0.0 (- (tactical-sim-unit-eta-sec u) dt))))
    (when (> (tactical-sim-unit-weapon-cooldown u) 0.0)
      (set-tactical-sim-unit-weapon-cooldown! u (max 0.0 (- (tactical-sim-unit-weapon-cooldown u) dt)))))
  (for-each tick-unit-cooldowns! sim-allies)
  (for-each tick-unit-cooldowns! sim-enemies)

  ;; Oracle Stasis Ward hazard penalty: penalize CommitFocusFire / KiteForwardChase when an enemy
  ;; stasis trap is within 4.5 tiles of friendly short-range units, rewarding StutterKiteBack / FlankSurround
  (when (and (memq our-action '(CommitFocusFire KiteForwardChase HoldChoke))
             (or (for/or ([e (in-list sim-enemies)])
                   (and (> (tactical-sim-unit-hp e) 0.0)
                        (memq (tactical-sim-unit-type e) '(oracle-stasis-trap stasis-ward))))
                 (for/or ([eb (in-list (tactical-arena-enemy-structures arena))])
                   (and (hash? eb)
                        (memq (hash-ref eb 'type #f) '(oracle-stasis-trap stasis-ward))))))
    (for ([a (in-list sim-allies)]
          #:when (and (> (tactical-sim-unit-hp a) 0.0)
                      (not (tactical-sim-unit-flying? a))
                      (<= (tactical-sim-unit-ground-range a) 4.5)))
      (define ax (tactical-sim-unit-x a))
      (define ay (tactical-sim-unit-y a))
      (define near-trap?
        (or (for/or ([e (in-list sim-enemies)])
              (and (> (tactical-sim-unit-hp e) 0.0)
                   (memq (tactical-sim-unit-type e) '(oracle-stasis-trap stasis-ward))
                   (<= (dist2d ax ay (tactical-sim-unit-x e) (tactical-sim-unit-y e)) 4.5)))
            (for/or ([eb (in-list (tactical-arena-enemy-structures arena))])
              (and (hash? eb)
                   (memq (hash-ref eb 'type #f) '(oracle-stasis-trap stasis-ward))
                   (<= (dist2d ax ay
                               (exact->inexact (hash-ref eb 'x 999.0))
                               (exact->inexact (hash-ref eb 'y 999.0)))
                       4.5)))))
      (when near-trap?
        (set-tactical-sim-unit-hp! a (max 1.0 (- (tactical-sim-unit-hp a) (* 18.0 dt)))))))

  ;; Step movement & weapon fire for one side against the other
  (define (step-side! actors opponents action opp-det? side-z opp-z ally-side?)
    (define elev-mult
      (cond
        [(> side-z (+ opp-z 0.5)) 1.15]
        [(< side-z (- opp-z 0.5)) 0.85]
        [else 1.0]))
    (define alive-opps
      (filter (lambda (o)
                (and (> (tactical-sim-unit-hp o) 0.0)
                     (<= (tactical-sim-unit-eta-sec o) 0.0)))
              opponents))
    (for ([u (in-list actors)]
          #:when (and (> (tactical-sim-unit-hp u) 0.0)
                      (<= (tactical-sim-unit-eta-sec u) 0.0)
                      (not (null? alive-opps))))
      ;; Choose target according to micro action policy
      (define valid-targets
        (filter (lambda (o) (sim-unit-can-target? u o opp-det?)) alive-opps))
      (define target
        (cond
          [(null? valid-targets) (first alive-opps)]
          [(eq? action 'CloakHarassWorkers)
           (define workers
             (filter (lambda (o) (memq (tactical-sim-unit-type o) '(scv probe drone)))
                     valid-targets))
           (if (not (null? workers))
               (argmin (lambda (w) (+ (tactical-sim-unit-hp w) (tactical-sim-unit-shield w))) workers)
               (argmin (lambda (o)
                         (dist2d (tactical-sim-unit-x u) (tactical-sim-unit-y u)
                                 (tactical-sim-unit-x o) (tactical-sim-unit-y o)))
                       valid-targets))]
          [(or (eq? action 'CommitFocusFire) (eq? action 'KiteForwardChase))
           (argmax (lambda (o)
                     (define d (max 1.0 (dist2d (tactical-sim-unit-x u) (tactical-sim-unit-y u)
                                                (tactical-sim-unit-x o) (tactical-sim-unit-y o))))
                     (score-arena-focus-target
                      (+ (tactical-sim-unit-ground-dps o) (tactical-sim-unit-air-dps o))
                      (+ (tactical-sim-unit-hp o) (tactical-sim-unit-shield o))
                      d
                      (sim-unit-weapon-range-vs u o)))
                   valid-targets)]
          [else
           (argmin (lambda (o)
                     (dist2d (tactical-sim-unit-x u) (tactical-sim-unit-y u)
                             (tactical-sim-unit-x o) (tactical-sim-unit-y o)))
                   valid-targets)]))

      (define ux (tactical-sim-unit-x u))
      (define uy (tactical-sim-unit-y u))
      (define tx (tactical-sim-unit-x target))
      (define ty (tactical-sim-unit-y target))
      (define dx (- tx ux))
      (define dy (- ty uy))
      (define dist (max 0.25 (sqrt (+ (* dx dx) (* dy dy)))))
      (define nx (/ dx dist))
      (define ny (/ dy dist))
      (define wrange (* elev-mult
                        (+ (sim-unit-weapon-range-vs u target)
                           (tactical-sim-unit-radius u)
                           (tactical-sim-unit-radius target))))
      (define spd (tactical-sim-unit-speed u))
      (define cd (tactical-sim-unit-weapon-cooldown u))
      (define can-hit? (sim-unit-can-target? u target opp-det?))
      (define drill-mult
        (if (and ally-side?
                 (>= ally-worker-count 3)
                 (memq (tactical-sim-unit-type u) '(scv probe drone))
                 (<= dist 4.0))
            1.35
            1.0))

      (cond
        ;; Pure retreat: 100% movement away from threat, no stopping to fire
        [(eq? action 'DisengageRetreat)
         (set-tactical-sim-unit-x! u (- ux (* spd dt nx)))
         (set-tactical-sim-unit-y! u (- uy (* spd dt ny)))]

        ;; Weapon ready & in range: fire volley!
        [(and can-hit? (<= dist wrange) (<= cd 0.0))
         (define burst-dmg
           (* elev-mult
              drill-mult
              (sim-unit-weapon-dps-vs u target)
              (tactical-sim-unit-weapon-period u)))
         (define eff-dmg (max 1.0 (- burst-dmg (tactical-sim-unit-armor target))))
         (define shd (tactical-sim-unit-shield target))
         (cond
           [(>= shd eff-dmg)
            (set-tactical-sim-unit-shield! target (- shd eff-dmg))]
           [else
            (set-tactical-sim-unit-shield! target 0.0)
            (set-tactical-sim-unit-hp! target (- (tactical-sim-unit-hp target) (- eff-dmg shd)))])
         ;; Splash damage bonus (penalized if opponent is spreading via FlankSurround)
         (when (> (tactical-sim-unit-splash-radius u) 0.5)
           (define splash-mult (if (eq? action 'FlankSurround) 0.25 0.50))
           (for ([adj (in-list valid-targets)]
                 #:when (and (not (eq? adj target))
                             (<= (dist2d tx ty (tactical-sim-unit-x adj) (tactical-sim-unit-y adj))
                                 (tactical-sim-unit-splash-radius u))))
             (set-tactical-sim-unit-hp! adj (- (tactical-sim-unit-hp adj) (* splash-mult eff-dmg)))))
         (set-tactical-sim-unit-weapon-cooldown! u (tactical-sim-unit-weapon-period u))
         ;; Post-shot movement during remaining sub-step after damage point
         (define move-dt (max 0.0 (- dt (tactical-sim-unit-damage-point u))))
         (when (and (> move-dt 0.0)
                    (memq action '(StutterKiteBack CloakHarassWorkers)))
           (set-tactical-sim-unit-x! u (- ux (* spd move-dt nx)))
           (set-tactical-sim-unit-y! u (- uy (* spd move-dt ny))))]

        ;; Weapon on cooldown: execute kinematic policy (kite back, chase forward, or flank)
        [(> cd 0.0)
         (case action
           [(StutterKiteBack CloakHarassWorkers)
            (set-tactical-sim-unit-x! u (- ux (* spd dt nx)))
            (set-tactical-sim-unit-y! u (- uy (* spd dt ny)))]
           [(KiteForwardChase CommitFocusFire)
            (when (> dist (* 0.80 wrange))
              (set-tactical-sim-unit-x! u (+ ux (* spd dt nx)))
              (set-tactical-sim-unit-y! u (+ uy (* spd dt ny))))]
           [(FlankSurround)
            ;; Move tangentially around enemy to spread concave and maintain optimal range
            (set-tactical-sim-unit-x! u (+ ux (* 0.70 spd dt (- ny))))
            (set-tactical-sim-unit-y! u (+ uy (* 0.70 spd dt nx)))]
           [else (void)])]

        ;; Out of range and weapon ready: close distance to weapon range (unless HoldChoke)
        [(not (eq? action 'HoldChoke))
         (set-tactical-sim-unit-x! u (+ ux (* spd dt nx)))
         (set-tactical-sim-unit-y! u (+ uy (* spd dt ny)))])))

  (step-side! sim-allies sim-enemies our-action enemy-det? our-z enemy-z #t)
  (step-side! sim-enemies sim-allies enemy-action ally-det? enemy-z our-z #f))

(define (evaluate-arena-horizon-state depth-sec init-allies init-enemies sim-allies sim-enemies)
  (define init-ally-cost (for/sum ([a (in-list init-allies)]) (tactical-sim-unit-cost a)))
  (define init-enemy-cost (for/sum ([e (in-list init-enemies)]) (tactical-sim-unit-cost e)))
  (define surv-ally-cost
    (for/sum ([a (in-list sim-allies)] #:when (> (tactical-sim-unit-hp a) 0.0))
      (tactical-sim-unit-cost a)))
  (define surv-enemy-cost
    (for/sum ([e (in-list sim-enemies)] #:when (> (tactical-sim-unit-hp e) 0.0))
      (tactical-sim-unit-cost e)))
  (define ally-eff-hp-val
    (for/sum ([a (in-list sim-allies)] #:when (> (tactical-sim-unit-hp a) 0.0))
      (* (tactical-sim-unit-cost a)
         (/ (+ (tactical-sim-unit-hp a) (tactical-sim-unit-shield a))
            (max 1.0 (+ (tactical-sim-unit-max-hp a) (tactical-sim-unit-shield a)))))))
  (define enemy-eff-hp-val
    (for/sum ([e (in-list sim-enemies)] #:when (> (tactical-sim-unit-hp e) 0.0))
      (* (tactical-sim-unit-cost e)
         (/ (+ (tactical-sim-unit-hp e) (tactical-sim-unit-shield e))
            (max 1.0 (+ (tactical-sim-unit-max-hp e) (tactical-sim-unit-shield e)))))))
  (define workers-killed
    (for/sum ([e (in-list sim-enemies)]
              #:when (and (memq (tactical-sim-unit-type e) '(scv probe drone))
                          (<= (tactical-sim-unit-hp e) 0.0)))
      1))
  (define hero-units-lost
    (for/sum ([a (in-list sim-allies)]
              #:when (and (memq (tactical-sim-unit-type a)
                                '(banshee oracle mutalisk medivac warp-prism immortal siege-tank siege-tank-sieged colossus))
                          (<= (tactical-sim-unit-hp a) 0.0)))
      1))
  (define trade-delta
    (- (- init-enemy-cost surv-enemy-cost)
       (- init-ally-cost surv-ally-cost)))
  (define hp-val-delta
    (* 0.45 (- ally-eff-hp-val enemy-eff-hp-val)))
  (define net-val
    (+ trade-delta
       hp-val-delta
       (* SC2-WORKER-KILL-ECONOMIC-VALUE workers-killed)
       (- (* SC2-HERO-UNIT-LOSS-PENALTY hero-units-lost))))
  (tactical-horizon-eval
   depth-sec
   surv-ally-cost
   surv-enemy-cost
   (/ ally-eff-hp-val (max 1.0 init-ally-cost))
   (/ enemy-eff-hp-val (max 1.0 init-enemy-cost))
   workers-killed
   hero-units-lost
   net-val))

(define (compress-arena-sim-units units [max-rep 4])
  (define n (length units))
  (if (<= n max-rep)
      units
      (let ([scale (/ (exact->inexact n) (exact->inexact max-rep))])
        (for/list ([u (in-list (take units max-rep))])
          (struct-copy tactical-sim-unit u
                       [hp (* scale (tactical-sim-unit-hp u))]
                       [max-hp (* scale (tactical-sim-unit-max-hp u))]
                       [shield (* scale (tactical-sim-unit-shield u))]
                       [ground-dps (* scale (tactical-sim-unit-ground-dps u))]
                       [air-dps (* scale (tactical-sim-unit-air-dps u))]
                       [cost (* scale (tactical-sim-unit-cost u))])))))

(define (simulate-mirrored-arena-pair arena our-action enemy-action
                                      #:init-allies [given-init-allies #f]
                                      #:init-enemies [given-init-enemies #f])
  (define init-allies
    (or given-init-allies
        (compress-arena-sim-units
         (append (tactical-arena-ally-units arena)
                 (tactical-arena-reinforcing-allies arena)))))
  (define init-enemies
    (or given-init-enemies
        (compress-arena-sim-units
         (append (tactical-arena-enemy-units arena)
                 (tactical-arena-reinforcing-enemies arena)))))
  (define sim-allies (map clone-tactical-sim-unit init-allies))
  (define sim-enemies (map clone-tactical-sim-unit init-enemies))
  (define dt (* 2.0 SC2-TACTICAL-SIM-DT-SEC))
  (define d1-ticks (max 1 (exact-round (/ SC2-TACTICAL-DEPTH1-SEC dt)))) ;; 1 tick (0.5s)
  (define d2-ticks (max 2 (exact-round (/ SC2-TACTICAL-DEPTH2-SEC dt)))) ;; 4 ticks (2.0s)
  (define d3-ticks (max 4 (exact-round (/ SC2-TACTICAL-DEPTH3-SEC dt)))) ;; 10 ticks (5.0s)

  (define d1-eval #f)
  (define d2-eval #f)
  (for ([tick (in-range 1 (add1 d3-ticks))])
    (step-kinematic-and-combat-tick! sim-allies sim-enemies our-action enemy-action arena dt)
    (when (= tick d1-ticks)
      (set! d1-eval (evaluate-arena-horizon-state SC2-TACTICAL-DEPTH1-SEC
                                                  init-allies init-enemies sim-allies sim-enemies)))
    (when (= tick d2-ticks)
      (set! d2-eval (evaluate-arena-horizon-state SC2-TACTICAL-DEPTH2-SEC
                                                  init-allies init-enemies sim-allies sim-enemies))))
  (define d3-eval
    (evaluate-arena-horizon-state SC2-TACTICAL-DEPTH3-SEC
                                  init-allies init-enemies sim-allies sim-enemies))
  (define eff-d1 (or d1-eval d3-eval))
  (define eff-d2 (or d2-eval d3-eval))
  (define combined
    (+ (* SC2-TACTICAL-DEPTH1-WEIGHT (tactical-horizon-eval-net-value eff-d1))
       (* SC2-TACTICAL-DEPTH2-WEIGHT (tactical-horizon-eval-net-value eff-d2))
       (* SC2-TACTICAL-DEPTH3-WEIGHT (tactical-horizon-eval-net-value d3-eval))))
  (mirrored-rollout-result our-action enemy-action eff-d1 eff-d2 d3-eval combined))

(define (candidate-actions-for-arena arena)
  (define has-cloak-or-harass?
    (ormap (lambda (a)
             (or (tactical-sim-unit-can-cloak? a)
                 (tactical-sim-unit-flying? a)
                 (memq (tactical-sim-unit-type a) '(banshee oracle mutalisk reaper adept))))
           (tactical-arena-ally-units arena)))
  (if (and has-cloak-or-harass? (not (null? (tactical-arena-enemy-workers arena))))
      TACTICAL-MICRO-ACTION-SPACE
      (remq 'CloakHarassWorkers TACTICAL-MICRO-ACTION-SPACE)))

(define (evaluate-arena-minimax-and-regret! brain arena frame #:strategic-opp-depth [_opp-d 1])
  (define aid (tactical-arena-id arena))
  (define states (tactical-mirror-brain-arena-states brain))
  (define cur-state (hash-ref states aid #f))
  (define our-cands (candidate-actions-for-arena arena))
  (define enemy-cands '(CommitFocusFire StutterKiteBack KiteForwardChase FlankSurround DisengageRetreat))
  (define init-allies
    (compress-arena-sim-units
     (append (tactical-arena-ally-units arena)
             (tactical-arena-reinforcing-allies arena))))
  (define init-enemies
    (compress-arena-sim-units
     (append (tactical-arena-enemy-units arena)
             (tactical-arena-reinforcing-enemies arena))))

  ;; Evaluate mirrored payoff matrix U(a_self, a_opp) across all 3 lookahead depths
  (define rollout-table (make-hash))
  (for* ([oa (in-list our-cands)]
         [ea (in-list enemy-cands)])
    (hash-set! rollout-table (cons oa ea)
               (simulate-mirrored-arena-pair arena oa ea
                                             #:init-allies init-allies
                                             #:init-enemies init-enemies)))

  ;; Level-0 naive enemy action = CommitFocusFire; Level-1 enemy best response against our naive attack
  (define pred-enemy-action
    (argmin (lambda (ea)
              (mirrored-rollout-result-combined-value
               (hash-ref rollout-table (cons (first our-cands) ea))))
            enemy-cands))

  ;; Score each of our candidate micro actions via regret-hedged minimax:
  ;; (1 - lambda) * U(oa, pred-enemy-action) + lambda * min_{ea} U(oa, ea)
  (define (score-our-action oa)
    (define vs-pred
      (mirrored-rollout-result-combined-value
       (hash-ref rollout-table (cons oa pred-enemy-action))))
    (define worst-case
      (apply min
             (for/list ([ea (in-list enemy-cands)])
               (mirrored-rollout-result-combined-value
                (hash-ref rollout-table (cons oa ea))))))
    (+ (* (- 1.0 SC2-TACTICAL-MINIMAX-LAMBDA) vs-pred)
       (* SC2-TACTICAL-MINIMAX-LAMBDA worst-case)))

  (define best-oa (argmax score-our-action our-cands))
  (define best-val (score-our-action best-oa))
  (define cur-committed-oa
    (if (and cur-state (memq (arena-commitment-state-committed-action cur-state) our-cands))
        (arena-commitment-state-committed-action cur-state)
        best-oa))
  (define cur-val (score-our-action cur-committed-oa))
  (define best-rollout (hash-ref rollout-table (cons best-oa pred-enemy-action)))
  (values best-oa pred-enemy-action best-val cur-val best-rollout))

(define (resolve-committed-micro-action! brain arena frame
                                         raw-best-action pred-enemy-action
                                         best-val cur-val)
  (define aid (tactical-arena-id arena))
  (define states (tactical-mirror-brain-arena-states brain))
  (define prev (hash-ref states aid #f))
  (cond
    [(not prev)
     (define lock-dur
       (if (memq raw-best-action '(DisengageRetreat CloakHarassWorkers))
           SC2-TACTICAL-RETREAT-LOCK-FRAMES
           SC2-TACTICAL-MIN-LOCK-FRAMES))
     (define st
       (arena-commitment-state aid raw-best-action pred-enemy-action 0
                               frame (+ frame lock-dur) (make-hasheq)
                               (tactical-arena-center-x arena)
                               (tactical-arena-center-y arena)))
     (hash-set! states aid st)
     (values raw-best-action #f)]
    [else
     (define prev-act (arena-commitment-state-committed-action prev))
     (define lock-until (arena-commitment-state-lock-until-frame prev))
     (define in-lock? (< frame lock-until))
     (define req-margin
       (if in-lock?
           (* SC2-TACTICAL-PREEMPT-MULTIPLIER SC2-TACTICAL-HYSTERESIS-BONUS)
           SC2-TACTICAL-HYSTERESIS-BONUS))
     (cond
       [(or (eq? raw-best-action prev-act)
            (<= (- best-val cur-val) req-margin))
        ;; Maintain current commitment (no order oscillation!)
        (set-arena-commitment-state-predicted-enemy-action! prev pred-enemy-action)
        (values prev-act #t)]
       [else
        ;; Genuine tactical shift exceeding hysteresis threshold
        (define lock-dur
          (if (memq raw-best-action '(DisengageRetreat CloakHarassWorkers))
              SC2-TACTICAL-RETREAT-LOCK-FRAMES
              SC2-TACTICAL-MIN-LOCK-FRAMES))
        (set-arena-commitment-state-committed-action! prev raw-best-action)
        (set-arena-commitment-state-predicted-enemy-action! prev pred-enemy-action)
        (set-arena-commitment-state-committed-since-frame! prev frame)
        (set-arena-commitment-state-lock-until-frame! prev (+ frame lock-dur))
        (values raw-best-action #f)])]))

(define (step-tactical-mirror-brain! brain arg1 [arg2 #f]
                                     #:order-ledger [kw-ledger #f]
                                     #:record-ledger? [record-ledger? #t]
                                     #:chokes [chokes '()]
                                     #:strategic-opp-depth [opp-d 1])
  (define-values (obs ledger)
    (if (hash? arg1)
        (values arg1 (or kw-ledger arg2))
        (values (if (hash? arg2) arg2 (hash)) (or kw-ledger arg1))))
  (define frame (hash-ref obs 'frame 0))
  (define base-x (hash-ref obs 'base-x SC2-DEFAULT-HOME-BASE-X))
  (define base-y (hash-ref obs 'base-y SC2-DEFAULT-HOME-BASE-Y))
  (define nat-x (hash-ref obs 'natural-x SC2-DEFAULT-NATURAL-X))
  (define nat-y (hash-ref obs 'natural-y SC2-DEFAULT-NATURAL-Y))
  (define ally-units (hash-ref obs 'ally-units '()))
  (define enemy-units (hash-ref obs 'enemy-units '()))
  (define enemy-bldgs (hash-ref obs 'enemy-buildings '()))
  (define our-z (hash-ref obs 'our-terrain-z 10))
  (define enemy-z (hash-ref obs 'enemy-terrain-z 10))

  (define arenas
    (cluster-tactical-arenas ally-units enemy-units enemy-bldgs
                             #:chokes chokes #:our-z our-z #:enemy-z enemy-z))
  (set-tactical-mirror-brain-active-arenas! brain arenas)

  (define actions '())
  (define committed-tags (mutable-seteqv))
  (define decisions '())
  (define (emit! act) (set! actions (cons act actions)))
  (define ally-by-id
    (for/hasheqv ([u (in-list ally-units)])
      (values (hash-ref u 'id -1) u)))
  (define has-banshee-cloak?
    (if (hash-has-key? obs 'researched-upgrades)
        (and (memq 'banshee-cloak (hash-ref obs 'researched-upgrades '())) #t)
        #t))

  (for ([arena (in-list arenas)])
    (define-values (raw-best pred-enemy best-val cur-val rollout)
      (evaluate-arena-minimax-and-regret! brain arena frame #:strategic-opp-depth opp-d))
    (define-values (committed-act locked?)
      (resolve-committed-micro-action! brain arena frame raw-best pred-enemy best-val cur-val))
    (define d1-val (tactical-horizon-eval-net-value (mirrored-rollout-result-d1-eval rollout)))
    (define d2-val (tactical-horizon-eval-net-value (mirrored-rollout-result-d2-eval rollout)))
    (define d3-val (tactical-horizon-eval-net-value (mirrored-rollout-result-d3-eval rollout)))

    (set! decisions
          (cons (hash 'arena-id (tactical-arena-id arena)
                      'committed-action committed-act
                      'predicted-enemy-action pred-enemy
                      'd1-value d1-val
                      'd2-value d2-val
                      'd3-value d3-val
                      'combined-value (mirrored-rollout-result-combined-value rollout)
                      'locked? locked?)
                decisions))

    ;; Translate winning arena micro action into per-unit commands with cooldown & order-equivalence gating
    (define arena-enemies (tactical-arena-enemy-units arena))
    (define arena-workers (tactical-arena-enemy-workers arena))
    (define enemy-has-aa?
      (ormap (lambda (e) (> (tactical-sim-unit-air-dps e) 0.0)) arena-enemies))
    (define arena-has-stealth?
      (ormap (lambda (a)
               (or (tactical-sim-unit-cloaked? a)
                   (memq (tactical-sim-unit-type a) SC2-CLOAKED-OR-BURROW-STEALTH-SYMS)))
             (tactical-arena-ally-units arena)))
    (for ([su (in-list (tactical-arena-ally-units arena))])
      (define uid (tactical-sim-unit-id su))
      (define utype (tactical-sim-unit-type su))
      (define ux (tactical-sim-unit-x su))
      (define uy (tactical-sim-unit-y su))
      (define w-cd (tactical-sim-unit-weapon-cooldown su))
      (set-add! committed-tags uid)

      ;; Find live unit hash for order-equivalence and backswing lock check
      (define u-hash
        (hash-ref ally-by-id uid
                  (lambda () (hash 'id uid 'type utype 'x ux 'y uy 'weapon-cooldown w-cd))))
      (define in-swing?
        (and ledger (order-ledger-unit-in-attack-swing? ledger u-hash frame)))

      ;; Trigger Banshee cloak when researched (or in synthetic test without researched-upgrades key),
      ;; facing anti-air without detection, and energy >= 25
      (when (and (eq? utype 'banshee)
                 has-banshee-cloak?
                 (not (tactical-sim-unit-cloaked? su))
                 (>= (tactical-sim-unit-energy su) SC2-BANSHEE-CLOAK-MIN-ENERGY)
                 (or (eq? committed-act 'CloakHarassWorkers)
                     (and enemy-has-aa? (not (tactical-arena-enemy-has-detection? arena)))))
        (emit! (list 'cast-spell uid 'cloak-banshee)))

      (unless in-swing?
        (define target-su
          (cond
            [(and (eq? committed-act 'CloakHarassWorkers)
                  (not (null? arena-workers))
                  (> (tactical-sim-unit-ground-dps su) 0.0))
             (define best-w
               (argmin (lambda (w) (+ (hash-ref w 'hp 40) (hash-ref w 'shield 0))) arena-workers))
             (unit-hash->tactical-sim-unit best-w 'enemy)]
            [else
             (define best-hittable
               (let loop ([rem arena-enemies]
                          [best #f]
                          [best-sc -inf.0])
                 (if (null? rem)
                     best
                     (let ([e (car rem)])
                       (if (> (sim-unit-weapon-dps-vs su e) 0.0)
                           (let* ([etype (tactical-sim-unit-type e)]
                                  [d (max 1.0 (dist2d ux uy (tactical-sim-unit-x e) (tactical-sim-unit-y e)))]
                                  [det? (sc2-unit-is-detector-sym? etype)]
                                  [decoy-mult (sc2-target-priority-multiplier etype arena-has-stealth?)]
                                  [base-dps (+ 5.0 (tactical-sim-unit-ground-dps e) (tactical-sim-unit-air-dps e))]
                                  [eff-dps (if (and det? arena-has-stealth?) (max 22.0 base-dps) base-dps)]
                                  [sc (* decoy-mult
                                         (/ eff-dps
                                            (* (+ (tactical-sim-unit-hp e) (tactical-sim-unit-shield e)) d)))])
                             (if (> sc best-sc)
                                 (loop (cdr rem) e sc)
                                 (loop (cdr rem) best best-sc)))
                           (loop (cdr rem) best best-sc))))))
             (cond
               [best-hittable best-hittable]
               [(and (eq? committed-act 'DisengageRetreat) (not (null? arena-enemies)))
                (first arena-enemies)]
               [else #f])]))

        (when target-su
          (define eid (tactical-sim-unit-id target-su))
          (define ex (tactical-sim-unit-x target-su))
          (define ey (tactical-sim-unit-y target-su))
          (case committed-act
            [(DisengageRetreat)
             (unless (and ledger (order-ledger-order-equivalent? ledger u-hash 'kite 0 base-x base-y frame))
               (when (and ledger record-ledger?)
                 (order-ledger-record-issued! ledger uid 'kite 'move #:target-x base-x #:target-y base-y #:frame frame))
               (emit! (list 'kite uid base-x base-y)))]

            [(StutterKiteBack CloakHarassWorkers)
             ;; Phase-locked stutter-step micro:
             ;; - Weapon on cooldown (> 0.15s) and not suicide Baneling: glide to standoff kite vector
             ;; - Weapon ready (<= 0.15s) or Baneling: fire/advance at high-priority target
             (cond
               [(and (not (eq? utype 'baneling))
                     (> w-cd SC2-WEAPON-KITE-COOLDOWN-THRESH))
                (define-values (kx ky) (compute-kite-vector ux uy ex ey SC2-KITE-STEP-DISTANCE))
                (unless (and ledger (order-ledger-order-equivalent? ledger u-hash 'kite 0 kx ky frame))
                  (when (and ledger record-ledger?)
                    (order-ledger-record-issued! ledger uid 'kite 'move #:target-x kx #:target-y ky #:frame frame))
                  (emit! (list 'kite uid kx ky)))]
               [else
                (unless (and ledger (order-ledger-order-equivalent? ledger u-hash 'attack-unit eid ex ey frame))
                  (when (and ledger record-ledger?)
                    (order-ledger-record-issued! ledger uid 'attack-unit 'attack #:target-id eid #:frame frame))
                  (emit! (list 'attack-unit uid eid)))])]

            [(HoldChoke)
             (define dist-to-nat (dist2d ux uy nat-x nat-y))
             (if (<= dist-to-nat 3.5)
                 (unless (and ledger (order-ledger-order-equivalent? ledger u-hash 'hold-position 0 nat-x nat-y frame))
                   (when (and ledger record-ledger?)
                     (order-ledger-record-issued! ledger uid 'hold-position 'hold-position #:frame frame))
                   (emit! (list 'hold-position uid nat-x nat-y)))
                 (unless (and ledger (order-ledger-order-equivalent? ledger u-hash 'attack-unit eid ex ey frame))
                   (when (and ledger record-ledger?)
                     (order-ledger-record-issued! ledger uid 'attack-unit 'attack #:target-id eid #:frame frame))
                   (emit! (list 'attack-unit uid eid))))]

            [else ;; CommitFocusFire, KiteForwardChase, FlankSurround
             (unless (and ledger (order-ledger-order-equivalent? ledger u-hash 'attack-unit eid ex ey frame))
               (when (and ledger record-ledger?)
                 (order-ledger-record-issued! ledger uid 'attack-unit 'attack #:target-id eid #:frame frame))
               (emit! (list 'attack-unit uid eid)))])))))

  (set-tactical-mirror-brain-last-decisions! brain (reverse decisions))
  (values (reverse actions) committed-tags (reverse decisions)))
