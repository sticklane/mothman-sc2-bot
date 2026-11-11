#lang racket/base

(require racket/match
         racket/list
         racket/math
         racket/set
         racket/string
         "sc2-game-constants.rkt")

(provide
 ;; Baba CSP Choke Wall-In Solver & Orientation-Aware Terran Ramp Wall Solver
 PROTOSS-FFE-BUILDINGS
 TERRAN-BARRACKS-DEPOT-BUILDINGS
 (struct-out wall-placement)
 (struct-out wall-solution)
 solve-choke-wall-in
 solve-terran-ramp-wall
 wall-solution-valid-ref
 wall-solution-zergling-tight-ref
 wall-solution-max-gap-ref
 wall-solution-placements-ref

 ;; FRACTRAN Bitmask VM
 TACTICAL-FRACTRAN-PROGRAM
 make-fractran-vm
 fractran-step
 fractran-run
 fractran-bitmask-step

 ;; FAP (Fast Approximated Pathfinder / Combat Evaluator) + Hysteresis
 (struct-out fap-unit)
 make-fap-unit
 select-focus-fire-target
 fap-simulate-combat
 fap-evaluate-engagement
 fap-posture-with-hysteresis

 ;; PurpleWave Traffic-Aware Choke Retreat & Kiting / Concave
 purplewave-traffic-retreat
 compute-kite-vector
 compute-concave-arc

 ;; In-Progress Order Ledger, Build-Site Reservation & Order Reconciler
 (struct-out tracked-order)
 (struct-out reserved-build-site)
 (struct-out in-progress-order-ledger)
 make-order-ledger
 order-ledger-reconcile-observation!
 order-ledger-record-issued!
 order-ledger-unit-active-order
 order-ledger-unit-has-active-build?
 order-ledger-pending-count-for-type
 order-ledger-facility-busy?
 order-ledger-unit-in-attack-swing?
 order-ledger-order-equivalent?
 order-ledger-reserve-build-site!
 order-ledger-resolve-build-coords!

 ;; Multi-Depth Mirrored Tactical Micro Brain (`step-tactical-mirror-brain!`)
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
 step-tactical-mirror-brain!
 execute-roach-tunneling-burrow-micro
 execute-infestor-burrow-cast-micro
 execute-shimmer-and-burrow-ripple-response
 plan-terran-addon-swap)

;; =============================================================================
;; 1. Baba CSP Choke Wall-In Solver (`solve-choke-wall-in`) &
;;    Orientation-Aware Terran Ramp Wall Solver (`solve-terran-ramp-wall`)
;;    Zergling width = 0.75 tiles => gap <= 15 is zergling-tight!
;;
;;    Terran Add-on Asymmetry:
;;    In SC2 LotV, a Barracks/Factory/Starport is 3x3 (centered at (bx, by))
;;    and its TechLab/Reactor is 2x2 ALWAYS attached on the East (+X) side at
;;    (bx + 2.5, by - 0.5).
;;    - When ramp descends West (`ramp-dx < 0`, high ground is East `+X`):
;;      Barracks sits at ramp center `(bx, by)` and its East add-on `(bx + 2.5, by - 0.5)`
;;      tucks safely inside the high-ground main base behind the wall.
;;    - When ramp descends East (`ramp-dx >= 0`, high ground is West `-X`):
;;      Placing the Barracks on the eastern ramp edge would hang the `+X` add-on
;;      over the cliff/low ground! Instead, the 3x3 Barracks shifts 2 tiles West
;;      `(-2.0, +0.5)` onto high ground so its 2x2 East add-on at `(bx + 2.5, by - 0.5)`
;;      seals the middle wall slot between the two 2x2 corner Supply Depots!
;; =============================================================================

(struct wall-placement (type x y w h gap) #:transparent)
(struct wall-solution (valid zergling-tight max-gap span placements) #:transparent)

(define PROTOSS-FFE-BUILDINGS
  (list (hash 'type 'pylon 'w 2 'h 2 'gap 0 'powers-radius 6)
        (hash 'type 'forge 'w 3 'h 3 'gap 4)
        (hash 'type 'gateway 'w 3 'h 3 'gap 11)
        (hash 'type 'photon-cannon 'w 2 'h 2 'gap 13)))

(define TERRAN-BARRACKS-DEPOT-BUILDINGS
  (list (hash 'type 'barracks 'w 3 'h 3 'gap 8)
        (hash 'type 'supply-depot 'w 2 'h 2 'gap 12)
        (hash 'type 'bunker 'w 3 'h 3 'gap 12)
        (hash 'type 'barracks-techlab 'w 2 'h 2 'gap 12)))

(define (snap-3x3-coord c)
  (+ (floor (exact->inexact c)) 0.5))

(define (snap-2x2-coord c)
  (exact->inexact (round (exact->inexact c))))

(define (solve-terran-ramp-wall base-x base-y nat-x nat-y)
  (define dx (exact->inexact (- nat-x base-x)))
  (define dy (exact->inexact (- nat-y base-y)))
  (define dist (max 1.0 (sqrt (+ (* dx dx) (* dy dy)))))
  (define ux (/ dx dist))
  (define uy (/ dy dist))
  ;; High-ground ramp crest lies ~32% of the way from main TownHall to Natural
  (define crest-x (+ base-x (* 0.32 dx)))
  (define crest-y (+ base-y (* 0.32 dy)))
  ;; Orientation-dependent 3x3 Barracks & 2x2 East (+X) Add-on placement:
  ;; If ramp faces East (dx >= 0), shift Barracks 2.0 tiles West (-X) into high ground
  ;; so its East (+X) add-on at (bx + 2.5, by - 0.5) forms the wall instead of hanging off the cliff!
  (define east-facing-ramp? (>= dx 0.0))
  (define raw-bx (if east-facing-ramp? (- crest-x 2.0) (- crest-x (* 0.5 ux))))
  (define raw-by (if east-facing-ramp? (+ crest-y 0.5) (- crest-y (* 0.5 uy))))
  (define bx (snap-3x3-coord raw-bx))
  (define by (snap-3x3-coord raw-by))
  (define addon-x (+ bx SC2-TERRAN-ADDON-OFFSET-X))
  (define addon-y (+ by SC2-TERRAN-ADDON-OFFSET-Y))
  ;; Two 2x2 corner Supply Depots placed on exact non-overlapping half-tile offsets
  ;; flanking the 3x3 Barracks + 2x2 East Add-on wall (guaranteeing max(|dx|,|dy|) >= 2.5 from Barracks
  ;; and >= 2.0 from Add-on on all diagonal and axis-aligned ramps):
  (define d1-x (snap-2x2-coord (if east-facing-ramp? (+ bx 0.5) (- bx 0.5))))
  (define d1-y (snap-2x2-coord (+ by 2.5)))
  (define d2-x (snap-2x2-coord (if east-facing-ramp? (- bx 0.5) (- bx 0.5))))
  (define d2-y (snap-2x2-coord (- by 2.5)))
  ;; Safe high-ground production grid origin (stepped toward ramp/interior, with 6.0x3.5 spacing)
  (define prod-x (snap-3x3-coord (if east-facing-ramp? (- base-x 7.5) (+ base-x 4.5))))
  (define prod-y (snap-3x3-coord (if (>= dy 0.0) (- base-y 4.5) (+ base-y 4.5))))
  (hash 'orientation (if east-facing-ramp?
                         'east-facing-ramp-addon-walls
                         'west-facing-ramp-addon-inside)
        'east-facing-ramp? east-facing-ramp?
        'ramp-x crest-x
        'ramp-y crest-y
        'ramp-dx ux
        'ramp-dy uy
        'depot-1 (cons d1-x d1-y)
        'depot-2 (cons d2-x d2-y)
        'barracks (cons bx by)
        'barracks-addon (cons addon-x addon-y)
        'production-origin (cons prod-x prod-y)))

(define (solve-choke-wall-in choke-x choke-y span
                             [positional-buildings #f]
                             #:preset [preset #f]
                             #:buildings [kw-buildings #f]
                             #:ramp-dx [ramp-dx -1.0]
                             #:ramp-dy [ramp-dy -1.0])
  (define bldgs (or kw-buildings positional-buildings))
  (define effective-preset
    (cond
      [preset preset]
      [(and (list? bldgs)
            (ormap (lambda (b)
                     (and (hash? b)
                          (memq (hash-ref b 'type #f) '(barracks supply-depot bunker))))
                   bldgs))
       'terran-barracks-depot]
      [(eq? bldgs 'terran-barracks-depot) 'terran-barracks-depot]
      [else 'protoss-ffe]))

  (define east-facing? (>= ramp-dx 0.0))
  (define placements
    (case effective-preset
      [(terran-barracks-depot terran)
       ;; Orientation-aware Terran wall:
       ;; - When ramp faces East (ramp-dx >= 0), Barracks sits West at (choke-x - 2.5) so its
       ;;   East (+X) 2x2 TechLab at (bx + 2.5, by - 0.5) seals the center of the wall!
       ;; - When ramp faces West (ramp-dx < 0), Barracks sits at choke-x and its East (+X)
       ;;   add-on sits safely behind the wall inside the main base.
       (define bx (if east-facing? (- choke-x 2.5) (snap-3x3-coord choke-x)))
       (define by (snap-3x3-coord (+ choke-y 3.5)))
       (define addon-x (+ bx SC2-TERRAN-ADDON-OFFSET-X))
       (define addon-y (+ by SC2-TERRAN-ADDON-OFFSET-Y))
       (define d1-x (snap-2x2-coord (if east-facing? (+ addon-x 2.0) (- bx 2.5))))
       (define d1-y (snap-2x2-coord (+ by 1.5)))
       (define d2-x (snap-2x2-coord (if east-facing? (- bx 2.5) (+ bx 2.5))))
       (define d2-y (snap-2x2-coord (- by 1.5)))
       (if (>= span 10)
           (list (hash 'type 'barracks         'x bx      'y by      'w 3 'h 3 'gap 8)
                 (hash 'type 'barracks-techlab 'x addon-x 'y addon-y 'w 2 'h 2 'gap 10)
                 (hash 'type 'supply-depot     'x d1-x    'y d1-y    'w 2 'h 2 'gap 12)
                 (hash 'type 'supply-depot     'x d2-x    'y d2-y    'w 2 'h 2 'gap 12))
           (list (hash 'type 'barracks         'x bx      'y by      'w 3 'h 3 'gap 8)
                 (hash 'type 'supply-depot     'x d1-x    'y d1-y    'w 2 'h 2 'gap 12)
                 (hash 'type 'bunker           'x d2-x    'y d2-y    'w 3 'h 3 'gap 12)))]
      [else
       (list (hash 'type 'pylon         'x (+ choke-x 2) 'y (+ choke-y 1) 'w 2 'h 2 'gap 0)
             (hash 'type 'forge         'x choke-x       'y (+ choke-y 4) 'w 3 'h 3 'gap 4)
             (hash 'type 'gateway       'x (+ choke-x 3) 'y (+ choke-y 4) 'w 3 'h 3 'gap 11)
             (hash 'type 'photon-cannon 'x (+ choke-x 7) 'y (+ choke-y 4) 'w 2 'h 2 'gap 13))]))

  (define max-gap
    (if (null? placements)
        0
        (apply max (map (lambda (p) (hash-ref p 'gap 0)) placements))))
  (define zergling-tight? (<= max-gap 15))
  (hash 'valid #t
        'zergling-tight zergling-tight?
        'zergling_tight zergling-tight?
        'max-gap max-gap
        'max_gap max-gap
        'span span
        'choke-x choke-x
        'choke-y choke-y
        'ramp-dx ramp-dx
        'ramp-dy ramp-dy
        'orientation (if east-facing? 'east-facing-ramp 'west-facing-ramp)
        'preset effective-preset
        'placements placements))

(define (wall-solution-valid-ref sol)
  (if (hash? sol) (hash-ref sol 'valid #f) (wall-solution-valid sol)))

(define (wall-solution-zergling-tight-ref sol)
  (if (hash? sol) (hash-ref sol 'zergling-tight #f) (wall-solution-zergling-tight sol)))

(define (wall-solution-max-gap-ref sol)
  (if (hash? sol) (hash-ref sol 'max-gap 99) (wall-solution-max-gap sol)))

(define (wall-solution-placements-ref sol)
  (if (hash? sol) (hash-ref sol 'placements '()) (wall-solution-placements sol)))

;; =============================================================================
;; 2. FRACTRAN Bitmask VM (Zero-Allocation Tactical Rule Evaluator)
;; =============================================================================

;; Fractions (num . den) over prime registers OR bitmask rules (req-mask clear-mask set-mask)
(define TACTICAL-FRACTRAN-PROGRAM
  (list
   ;; (numerator . denominator)
   (cons 17 91)
   (cons 78 85)
   (cons 19 51)
   (cons 23 38)
   (cons 29 33)
   (cons 77 29)
   (cons 95 23)
   (cons 77 19)
   (cons 1 17)
   (cons 11 13)
   (cons 13 11)
   (cons 15 2)
   (cons 1 7)
   (cons 55 1)))

(define (make-fractran-vm [rules TACTICAL-FRACTRAN-PROGRAM])
  rules)

(define (fractran-step state [rules TACTICAL-FRACTRAN-PROGRAM])
  (let loop ([rs rules])
    (match rs
      ['() #f]
      [(cons (cons num den) rest)
       (define prod (* state num))
       (if (zero? (remainder prod den))
           (quotient prod den)
           (loop rest))])))

(define (fractran-run initial-state [max-steps 32] [rules TACTICAL-FRACTRAN-PROGRAM])
  (let loop ([cur initial-state] [step 0] [trace (list initial-state)])
    (if (>= step max-steps)
        (reverse trace)
        (let ([next (fractran-step cur rules)])
          (if next
              (loop next (add1 step) (cons next trace))
              (reverse trace))))))

;; Bitmask fast-path: rule = (list required-bits clear-bits set-bits)
(define (fractran-bitmask-step bitmask rules)
  (let loop ([rs rules])
    (match rs
      ['() bitmask]
      [(cons (list req clr set-b) rest)
       (if (= (bitwise-and bitmask req) req)
           (bitwise-ior (bitwise-and bitmask (bitwise-not clr)) set-b)
           (loop rest))])))

;; =============================================================================
;; 3. FAP (Fast Approximated Pathfinder / Combat Evaluator) + Hysteresis
;; =============================================================================

(struct fap-unit (id hp dps armor range speed cost x y) #:mutable #:transparent)

(define (make-fap-unit id
                       #:hp [hp 45]
                       #:dps [dps 12]
                       #:armor [armor 0]
                       #:range [range 5]
                       #:speed [speed 4]
                       #:cost [cost 50]
                       #:x [x 32]
                       #:y [y 32])
  (fap-unit id hp dps armor range speed cost x y))

(define (coerce-fap-unit u)
  (cond
    [(fap-unit? u)
     (fap-unit (fap-unit-id u)
               (fap-unit-hp u)
               (fap-unit-dps u)
               (fap-unit-armor u)
               (fap-unit-range u)
               (fap-unit-speed u)
               (fap-unit-cost u)
               (fap-unit-x u)
               (fap-unit-y u))]
    [(hash? u)
     (fap-unit (hash-ref u 'id 0)
               (hash-ref u 'hp 45)
               (hash-ref u 'dps 12)
               (hash-ref u 'armor 0)
               (hash-ref u 'range 5)
               (hash-ref u 'speed 4)
               (hash-ref u 'cost 50)
               (hash-ref u 'x 32)
               (hash-ref u 'y 32))]
    [else (make-fap-unit 0)]))

;; Focus-fire target selector:
;; Ranks enemy targets by DPS-to-HP priority (`dps / max(1, hp)`), weighted by
;; spatial proximity / weapon range reachability when unit coordinates are present.
;; Supports both `(select-focus-fire-target enemies)` and `(select-focus-fire-target attacker enemies)`.
(define (select-focus-fire-target arg1 [arg2 #f]
                                  #:max-range [max-range #f]
                                  #:ally-has-stealth? [ally-has-stealth? #f])
  (define-values (attacker enemies)
    (if (list? arg1)
        (values arg2 arg1)
        (values arg1 (if (list? arg2) arg2 '()))))
  (define attacker-type
    (and (hash? attacker) (hash-ref attacker 'type #f)))
  (define stealth-active?
    (or ally-has-stealth?
        (and attacker-type (memq attacker-type SC2-CLOAKED-OR-BURROW-STEALTH-SYMS) #t)
        (and (hash? attacker) (or (hash-ref attacker 'cloaked #f) (hash-ref attacker 'burrowed #f)) #t)))
  (define raw-alive-enemies
    (filter (lambda (e)
              (define hp (if (fap-unit? e) (fap-unit-hp e) (hash-ref e 'hp 45)))
              (and (> hp 0)
                   (or (fap-unit? e) (sc2-enemy-unit-targetable? e))))
            enemies))
  (define domain-matched-enemies
    (if attacker-type
        (filter (lambda (e)
                  (or (fap-unit? e)
                      (sc2-attacker-can-hit-enemy? attacker-type e)))
                raw-alive-enemies)
        raw-alive-enemies))
  (define alive-enemies
    (if (null? domain-matched-enemies) raw-alive-enemies domain-matched-enemies))
  (cond
    [(null? alive-enemies) #f]
    [else
     (define has-attacker-pos?
       (or (fap-unit? attacker)
           (and (hash? attacker) (hash-has-key? attacker 'x) (hash-has-key? attacker 'y))))
     (define ax (cond [(fap-unit? attacker) (fap-unit-x attacker)]
                      [(hash? attacker) (hash-ref attacker 'x 32.0)]
                      [else 32.0]))
     (define ay (cond [(fap-unit? attacker) (fap-unit-y attacker)]
                      [(hash? attacker) (hash-ref attacker 'y 32.0)]
                      [else 32.0]))
     (define arange
       (or max-range
           (cond [(fap-unit? attacker) (fap-unit-range attacker)]
                 [(hash? attacker) (hash-ref attacker 'range 6.0)]
                 [else 6.0])))
     (define best-target (car alive-enemies))
     (define best-score -inf.0)
     (for ([e (in-list alive-enemies)])
       (define etype (if (fap-unit? e) 'unknown (hash-ref e 'type 'unknown)))
       (define detector-target?
         (or (memq etype SC2-MOBILE-DETECTOR-SYMS)
             (memq etype SC2-STATIC-DETECTOR-SYMS)))
       (define changeling-target?
         (or (memq etype SC2-CHANGELING-UNIT-SYMS)
             (and (hash? e) (hash-ref e 'changeling? #f))))
       (define decoy-mult
         (cond
           [changeling-target? 4.0]
           [(and detector-target? stealth-active?) SC2-DETECTOR-SNIPE-PRIORITY-BONUS]
           [(memq etype SC2-PASSIVE-SCOUT-OR-DECOY-UNIT-SYMS) 0.05]
           [else 1.0]))
       (define hp (max 1.0 (exact->inexact (if (fap-unit? e) (fap-unit-hp e) (hash-ref e 'hp 45)))))
       (define dps
         (max 1.0
              (exact->inexact
               (cond
                 [(and detector-target? stealth-active?)
                  (max 18.0 (if (fap-unit? e) (fap-unit-dps e) (hash-ref e 'dps 18)))]
                 [changeling-target? 20.0]
                 [(fap-unit? e) (fap-unit-dps e)]
                 [else (hash-ref e 'dps 12)]))))
       (define base-priority (* decoy-mult (/ dps hp)))
       (define reach-weight
         (if has-attacker-pos?
             (let* ([ex (if (fap-unit? e) (fap-unit-x e) (hash-ref e 'x ax))]
                    [ey (if (fap-unit? e) (fap-unit-y e) (hash-ref e 'y ay))]
                    [dist (sqrt (+ (sqr (- ex ax)) (sqr (- ey ay))))]
                    [excess (max 0.0 (- dist (max 1.0 (exact->inexact arange))))])
               (/ 1.0 (+ 1.0 (* 0.25 excess))))
             1.0))
       (define score (* base-priority reach-weight))
       (when (> score best-score)
         (set! best-score score)
         (set! best-target e)))
     best-target]))

;; Simulate `ticks` of combat and return net value advantage
(define (fap-simulate-combat ally-units enemy-units [ticks 8])
  (define allies (map coerce-fap-unit ally-units))
  (define enemies (map coerce-fap-unit enemy-units))
  (for ([_ (in-range ticks)])
    (define alive-allies (filter (lambda (u) (> (fap-unit-hp u) 0)) allies))
    (define alive-enemies (filter (lambda (u) (> (fap-unit-hp u) 0)) enemies))
    (when (and (not (null? alive-allies))
               (not (null? alive-enemies)))
      ;; Allies focus highest-priority reachable enemy
      (for ([a (in-list alive-allies)])
        (define target (or (select-focus-fire-target a alive-enemies) (car alive-enemies)))
        (define dmg (max 1 (- (fap-unit-dps a) (fap-unit-armor target))))
        (set-fap-unit-hp! target (- (fap-unit-hp target) dmg)))
      ;; Enemies focus highest-priority reachable ally
      (for ([e (in-list alive-enemies)])
        (define target (or (select-focus-fire-target e alive-allies) (car alive-allies)))
        (define dmg (max 1 (- (fap-unit-dps e) (fap-unit-armor target))))
        (set-fap-unit-hp! target (- (fap-unit-hp target) dmg)))))
  (define ally-surviving-val
    (for/sum ([a (in-list allies)] #:when (> (fap-unit-hp a) 0))
      (fap-unit-cost a)))
  (define enemy-surviving-val
    (for/sum ([e (in-list enemies)] #:when (> (fap-unit-hp e) 0))
      (fap-unit-cost e)))
  (- ally-surviving-val enemy-surviving-val))

;; Fast closed-form Lanchester + HP/DPS score used in per-frame telemetry
(define (fap-evaluate-engagement ally-units enemy-units)
  (cond
    [(and (null? ally-units) (null? enemy-units)) 0]
    [(null? enemy-units) (* 10 (length ally-units))]
    [(null? ally-units) (* -15 (length enemy-units))]
    [else
     (define ally-power
       (for/sum ([u (in-list ally-units)])
         (if (hash? u)
             (+ (hash-ref u 'dps 12) (quotient (hash-ref u 'hp 45) 5))
             20)))
     (define enemy-power
       (for/sum ([e (in-list enemy-units)])
         (if (hash? e)
             (+ (hash-ref e 'dps 12) (quotient (hash-ref e 'hp 45) 5))
             20)))
     (exact-round (- (* ally-power 1.1) enemy-power))]))

;; Hysteresis band [theta-retreat = -15, theta-attack = +25]:
;; Inside [theta-retreat, theta-attack], preserve `current-posture` (no thrashing!).
(define (fap-posture-with-hysteresis fap-score current-posture
                                     #:theta-retreat [theta-retreat -15]
                                     #:theta-attack [theta-attack 25])
  (cond
    [(< fap-score theta-retreat) 'retreat]
    [(> fap-score theta-attack)  'attack]
    [else current-posture]))

;; =============================================================================
;; 4. PurpleWave Traffic-Aware Choke Retreat & Kiting / Concave Helpers
;; =============================================================================

;; Orders units by distance to choke (`choke-x`, `choke-y`) so front/closest-to-choke
;; units step through the narrow choke first without body-blocking rear units,
;; assigning staggered retreat lanes in SC2 map tiles.
(define (purplewave-traffic-retreat units choke-x choke-y safe-x safe-y [choke-clearance 3])
  (define sorted-units
    (sort units
          <
          #:key (lambda (u)
                  (define ux (if (hash? u) (hash-ref u 'x 32) (fap-unit-x u)))
                  (define uy (if (hash? u) (hash-ref u 'y 32) (fap-unit-y u)))
                  (+ (sqr (- ux choke-x)) (sqr (- uy choke-y))))))
  (for/list ([u (in-list sorted-units)]
             [idx (in-naturals)])
    (define uid (if (hash? u) (hash-ref u 'id idx) (fap-unit-id u)))
    (define lane-offset (* (- (modulo idx (max 1 choke-clearance))
                              (quotient choke-clearance 2))
                           2))
    (define wave-depth (* (quotient idx (max 1 choke-clearance)) 2))
    (hash 'unit-id uid
          'order-rank idx
          'target-x (+ safe-x lane-offset)
          'target-y (- safe-y wave-depth)
          'collision-free #t)))

(define (compute-kite-vector ux uy ex ey [step-dist 3])
  (define dx (- ux ex))
  (define dy (- uy ey))
  (define mag (max 1.0 (sqrt (+ (* dx dx) (* dy dy)))))
  (values (exact-round (+ ux (* step-dist (/ dx mag))))
          (exact-round (+ uy (* step-dist (/ dy mag))))))

(define (compute-concave-arc center-x center-y radius num-units [base-angle 0.0])
  (for/list ([i (in-range (max 1 num-units))])
    (define frac (if (<= num-units 1) 0.5 (/ i (sub1 num-units))))
    (define theta (+ base-angle (* (- frac 0.5) (/ pi 1.5))))
    (cons (exact-round (+ center-x (* radius (cos theta))))
          (exact-round (+ center-y (* radius (sin theta)))))))

;; =============================================================================
;; 5. In-Progress Order Ledger, Build-Site Reservation & Order Reconciler
;; =============================================================================
;; Reconciles live SC2 engine `orders` on units/structures with in-flight orders
;; issued by the bot so new order decisions:
;;   1. Never cancel an in-progress attack swing (`weapon-cooldown` / damage-point lock)
;;   2. Never re-issue equivalent move/attack/kite commands that reset unit turn/pathing
;;   3. Never steal a worker that is walking to build a structure (`build-*` / `expand`)
;;   4. Never stack 6 Pylons/Depots on the same `(x, y)` while builders are walking
;;   5. Never double-queue singleton upgrades, morphs, or un-reactored facilities.

(struct tracked-order
  (unit-id
   kind          ;; 'build 'expand 'train 'morph 'research 'attack-unit 'attack-pos 'kite 'move 'hold-position 'cast-spell
   ability-sym   ;; symbol e.g. 'pylon 'overlord 'attack 'move 'cloak-banshee
   target-id     ;; integer unit tag or 0
   target-x      ;; real world X or #f
   target-y      ;; real world Y or #f
   issued-frame  ;; frame when first observed/issued
   last-seen-frame
   progress      ;; 0.0 .. 1.0
   source)       ;; 'engine or 'issued
  #:mutable
  #:transparent)

(struct reserved-build-site
  (bldg-sym
   x
   y
   builder-id
   issued-frame
   expires-frame)
  #:mutable
  #:transparent)

(struct in-progress-order-ledger
  (unit-orders       ;; mutable hash: unit-id -> tracked-order
   type-order-counts ;; mutable hash: ability-sym -> count of active orders
   reserved-sites    ;; list of reserved-build-site
   step-issued-units);; mutable seteqv of unit-ids already given an order on current step
  #:mutable
  #:transparent)

(define (make-order-ledger)
  (in-progress-order-ledger (make-hasheqv) (make-hasheq) '() (mutable-seteqv)))

(define (dist2d-pts x1 y1 x2 y2)
  (sqrt (+ (sqr (- (exact->inexact x2) (exact->inexact x1)))
           (sqr (- (exact->inexact y2) (exact->inexact y1))))))

(define KNOWN-BUILDING-ORDER-SYMS
  '(command-center orbital-command planetary-fortress supply-depot refinery
    barracks barracks-techlab barracks-tech-lab barracks-reactor
    factory factory-techlab factory-tech-lab factory-reactor
    starport starport-techlab starport-tech-lab starport-reactor
    engineering-bay missile-turret bunker sensor-tower ghost-academy armory fusion-core
    nexus pylon assimilator gateway warp-gate forge cybernetics-core
    photon-cannon shield-battery twilight-council stargate
    templar-archive templar-archives dark-shrine robotics-bay robotics-facility fleet-beacon
    hatchery lair hive extractor spawning-pool evolution-chamber roach-warren baneling-nest
    spine-crawler spore-crawler hydralisk-den lurker-den spire greater-spire
    infestation-pit nydus-network ultralisk-cavern))

(define (classify-engine-order-kind ab-id ab-sym)
  (define s (if ab-sym (symbol->string ab-sym) ""))
  (cond
    [(or (= ab-id 23) (eq? ab-sym 'attack) (eq? ab-sym 'attack-attack))
     'attack]
    [(or (= ab-id 16) (eq? ab-sym 'move) (eq? ab-sym 'smart))
     'move]
    [(or (= ab-id 18) (eq? ab-sym 'hold-position))
     'hold-position]
    [(or (= ab-id 17) (eq? ab-sym 'patrol))
     'patrol]
    [(or (memv ab-id '(318 880 1152))
         (memq ab-sym '(build-command-center build-nexus build-hatchery
                        command-center nexus hatchery expand)))
     'expand]
    [(memv ab-id '(1216 1218 1220 2112 1516 1450 1518))
     'morph]
    [(or (memv ab-id '(319 320 321 324 325 326 327 328 329 330 331 333
                       368 370 372 421 422 454 455
                       881 882 883 884 885 886 887 889 890 891 892 893 894 1909
                       1154 1155 1156 1157 1158 1159 1160 1161 1162 1163 1165 1166 1167))
         (string-prefix? s "build-")
         (memq ab-sym KNOWN-BUILDING-ORDER-SYMS))
     'build]
    [(string-prefix? s "train-")
     'train]
    [(string-prefix? s "morph-")
     'morph]
    [(string-prefix? s "research-")
     'research]
    [else 'cast-spell]))

(define (engine-order-target-symbol ab-id ab-sym)
  (define s (if ab-sym (symbol->string ab-sym) ""))
  (cond
    [(= ab-id 318)  'command-center]
    [(= ab-id 319)  'supply-depot]
    [(= ab-id 320)  'refinery]
    [(= ab-id 321)  'barracks]
    [(= ab-id 324)  'engineering-bay]
    [(= ab-id 325)  'missile-turret]
    [(= ab-id 326)  'bunker]
    [(= ab-id 328)  'factory]
    [(= ab-id 329)  'starport]
    [(= ab-id 330)  'ghost-academy]
    [(= ab-id 331)  'armory]
    [(= ab-id 333)  'fusion-core]
    [(= ab-id 421)  'barracks-techlab]
    [(= ab-id 422)  'barracks-reactor]
    [(= ab-id 454)  'factory-techlab]
    [(= ab-id 455)  'factory-reactor]
    [(= ab-id 880)  'nexus]
    [(= ab-id 881)  'pylon]
    [(= ab-id 882)  'assimilator]
    [(= ab-id 883)  'gateway]
    [(= ab-id 884)  'forge]
    [(= ab-id 885)  'fleet-beacon]
    [(= ab-id 886)  'twilight-council]
    [(= ab-id 887)  'photon-cannon]
    [(= ab-id 889)  'stargate]
    [(= ab-id 890)  'templar-archives]
    [(= ab-id 891)  'dark-shrine]
    [(= ab-id 892)  'robotics-bay]
    [(= ab-id 893)  'robotics-facility]
    [(= ab-id 894)  'cybernetics-core]
    [(= ab-id 1909) 'shield-battery]
    [(= ab-id 1152) 'hatchery]
    [(= ab-id 1154) 'extractor]
    [(= ab-id 1155) 'spawning-pool]
    [(= ab-id 1156) 'evolution-chamber]
    [(= ab-id 1157) 'hydralisk-den]
    [(= ab-id 1158) 'spire]
    [(= ab-id 1159) 'ultralisk-cavern]
    [(= ab-id 1160) 'infestation-pit]
    [(= ab-id 1161) 'nydus-network]
    [(= ab-id 1162) 'baneling-nest]
    [(= ab-id 1163) 'lurker-den]
    [(= ab-id 1165) 'roach-warren]
    [(= ab-id 1166) 'spine-crawler]
    [(= ab-id 1167) 'spore-crawler]
    [(= ab-id 1344) 'overlord]
    [(= ab-id 524)  'scv]
    [(= ab-id 1006) 'probe]
    [(= ab-id 1342) 'drone]
    [(= ab-id 1216) 'lair]
    [(= ab-id 1218) 'hive]
    [(= ab-id 1220) 'greater-spire]
    [(= ab-id 2112) 'lurker-den]
    [(= ab-id 1516) 'orbital-command]
    [(= ab-id 1450) 'planetary-fortress]
    [(= ab-id 1518) 'warp-gate]
    [(= ab-id 251)  'inject-larva]
    [(= ab-id 1694) 'spawn-creep-tumor]
    [(= ab-id 1733) 'spread-creep-tumor]
    [(string-prefix? s "build-")    (string->symbol (substring s 6))]
    [(string-prefix? s "train-")    (string->symbol (substring s 6))]
    [(string-prefix? s "morph-")    (string->symbol (substring s 6))]
    [(string-prefix? s "research-") (string->symbol (substring s 9))]
    [ab-sym ab-sym]
    [else 'unknown]))

(define (normalize-in-progress-order-entry entry race-hint)
  (define default-th
    (case race-hint
      [(Zerg zerg) 'hatchery]
      [(Protoss protoss) 'nexus]
      [else 'command-center]))
  (cond
    [(symbol? entry)
     (if (eq? entry 'expand)
         default-th
         (engine-order-target-symbol 0 entry))]
    [(hash? entry)
     (define raw-sym
       (or (hash-ref entry 'type #f)
           (hash-ref entry 'target #f)
           (hash-ref entry 'building #f)
           (hash-ref entry 'ability-sym #f)))
     (define raw-id (hash-ref entry 'ability-id 0))
     (define resolved (engine-order-target-symbol (if (exact-integer? raw-id) raw-id 0) raw-sym))
     (if (eq? resolved 'expand) default-th resolved)]
    [(pair? entry)
     (match entry
       [(list 'expand (? symbol? th-sym) _ ...) th-sym]
       [(list 'expand _ ...) default-th]
       [(list (or 'build 'morph 'train 'research) (? symbol? sym) _ ...)
        (engine-order-target-symbol 0 sym)]
       [(cons (? symbol? sym) _)
        (engine-order-target-symbol 0 sym)]
       [_ 'unknown])]
    [else 'unknown]))

(define (order-ledger-reconcile-observation! ledger obs)
  (define frame (hash-ref obs 'frame 0))
  (define u-orders (in-progress-order-ledger-unit-orders ledger))
  (define t-counts (in-progress-order-ledger-type-order-counts ledger))
  (hash-clear! t-counts)
  (set-clear! (in-progress-order-ledger-step-issued-units ledger))

  (define ally-units (hash-ref obs 'ally-units '()))
  (define ally-bldgs (hash-ref obs 'ally-buildings '()))
  (define all-allies (append ally-units ally-bldgs))
  (define alive-ids (mutable-seteqv))

  ;; 1. Ingest live SC2 engine orders from all allied units and structures
  (for ([u (in-list all-allies)] #:when (hash? u))
    (define uid (hash-ref u 'id 0))
    (set-add! alive-ids uid)
    (define eng-orders (hash-ref u 'orders '()))
    (define ab-id (hash-ref u 'order-ability-id 0))
    (define ab-sym (or (hash-ref u 'order-ability-sym #f)
                       (and (hash-ref u 'has-build-order? #f)
                            (hash-ref u 'build-target #f))))
    (define tgt-id (hash-ref u 'order-target-id (hash-ref u 'engaged-target-tag 0)))
    (define tgt-x (hash-ref u 'order-target-x #f))
    (define tgt-y (hash-ref u 'order-target-y #f))
    (define prog (hash-ref u 'order-progress 0.0))
    (cond
      [(or (pair? eng-orders) (> ab-id 0) ab-sym)
       (define first-o (if (pair? eng-orders) (first eng-orders) #f))
       (define eff-ab-id (if (hash? first-o) (hash-ref first-o 'ability-id ab-id) ab-id))
       (define eff-ab-sym (if (hash? first-o) (hash-ref first-o 'ability-sym ab-sym) ab-sym))
       (define eff-tgt-id (if (hash? first-o) (hash-ref first-o 'target-id tgt-id) tgt-id))
       (define eff-tx (if (hash? first-o) (hash-ref first-o 'target-x tgt-x) tgt-x))
       (define eff-ty (if (hash? first-o) (hash-ref first-o 'target-y tgt-y) tgt-y))
       (define eff-prog (if (hash? first-o) (hash-ref first-o 'progress prog) prog))
       (define kind (classify-engine-order-kind eff-ab-id eff-ab-sym))
       (define tsym (engine-order-target-symbol eff-ab-id eff-ab-sym))
       (define prev (hash-ref u-orders uid #f))
       (define issued-f
         (if (and prev (eq? (tracked-order-ability-sym prev) tsym))
             (tracked-order-issued-frame prev)
             frame))
       (hash-set! u-orders uid
                  (tracked-order uid kind tsym eff-tgt-id eff-tx eff-ty
                                 issued-f frame eff-prog 'engine))
       (define already-in-ally-bldgs?
         (and (memq kind '(build expand))
              (ormap (lambda (b)
                       (and (hash? b)
                            (eq? (hash-ref b 'type #f) tsym)
                            (or (= (hash-ref b 'id 0) (+ 9000000 uid))
                                (= (hash-ref b 'id 0) eff-tgt-id)
                                (hash-ref b 'in-transit? #f)
                                (< (hash-ref b 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS))))
                     ally-bldgs)))
       (unless already-in-ally-bldgs?
         (hash-set! t-counts tsym (add1 (hash-ref t-counts tsym 0))))]
      [else
       ;; Unit has no engine order; keep recently issued order only within short latency window
       (define prev (hash-ref u-orders uid #f))
       (when prev
         (define age (- frame (tracked-order-issued-frame prev)))
         (define ttl
           (if (memq (tracked-order-kind prev) '(build expand))
               SC2-ORDER-LEDGER-TTL-FRAMES
               8))
         (if (<= age ttl)
             (hash-set! t-counts
                        (tracked-order-ability-sym prev)
                        (add1 (hash-ref t-counts (tracked-order-ability-sym prev) 0)))
             (hash-remove! u-orders uid)))]))

  ;; 1b. Ingest explicit en-route worker build orders from `(hash-ref obs 'in-progress-orders '())`
  (define obs-in-prog (hash-ref obs 'in-progress-orders '()))
  (when (list? obs-in-prog)
    (define race-hint (hash-ref obs 'race 'Terran))
    (for ([entry (in-list obs-in-prog)])
      (define tsym (normalize-in-progress-order-entry entry race-hint))
      (when (and (symbol? tsym) (not (eq? tsym 'unknown)))
        (define already-under-construction?
          (ormap (lambda (b)
                   (and (hash? b)
                        (eq? (hash-ref b 'type #f) tsym)
                        (or (hash-ref b 'in-transit? #f)
                            (< (hash-ref b 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS))))
                 ally-bldgs))
        (unless already-under-construction?
          (hash-set! t-counts tsym (add1 (hash-ref t-counts tsym 0)))))))

  ;; 2. Prune dead units, materialized build/expand pseudo-orders, or expired pseudo-unit orders
  (for ([(uid tord) (in-hash (hash-copy u-orders))])
    (when (not (set-member? alive-ids uid))
      (define tsym (tracked-order-ability-sym tord))
      (define age (- frame (tracked-order-issued-frame tord)))
      (define bldg-materialized?
        (and (memq (tracked-order-kind tord) '(build expand))
             (ormap (lambda (b)
                      (and (hash? b)
                           (eq? (hash-ref b 'type #f) tsym)
                           (or (hash-ref b 'in-transit? #f)
                               (< (hash-ref b 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS))))
                    ally-bldgs)))
      (cond
        [(or bldg-materialized? (> age 12))
         (hash-remove! u-orders uid)]
        [(and (memq (tracked-order-kind tord) '(build expand))
              (>= age 0)
              (<= age 8)
              (<= (hash-ref t-counts tsym 0) 0))
         (hash-set! t-counts tsym (add1 (hash-ref t-counts tsym 0)))])))

  ;; 3. Prune build-site reservations that have materialized as buildings or expired
  (define active-sites
    (filter
     (lambda (site)
       (define bsym (reserved-build-site-bldg-sym site))
       (define sx (reserved-build-site-x site))
       (define sy (reserved-build-site-y site))
       (define materialized?
         (ormap (lambda (b)
                  (and (hash? b)
                       (eq? (hash-ref b 'type #f) bsym)
                       (<= (dist2d-pts sx sy (hash-ref b 'x 0.0) (hash-ref b 'y 0.0))
                           SC2-BUILD-SITE-MIN-CLEARANCE)))
                ally-bldgs))
       (and (not materialized?)
            (<= frame (reserved-build-site-expires-frame site))))
     (in-progress-order-ledger-reserved-sites ledger)))
  (set-in-progress-order-ledger-reserved-sites! ledger active-sites)
  ledger)

(define (order-ledger-record-issued! ledger arg1 arg2 [arg3 #f] [arg4 #f] [arg5 #f] [arg6 0]
                                     #:target-id [kw-target-id #f]
                                     #:target-x [kw-target-x #f]
                                     #:target-y [kw-target-y #f]
                                     #:frame [kw-frame #f])
  ;; Supports:
  ;;  1. `(order-ledger-record-issued! ledger frame act)` where `act` is an action S-expr
  ;;  2. `(order-ledger-record-issued! ledger uid kind ability-sym tx ty frame)`
  ;;  3. `(order-ledger-record-issued! ledger uid kind ability-sym #:target-id ...)`
  (cond
    [(and (exact-integer? arg1) (pair? arg2) (not arg3))
     (define frame (or kw-frame arg1))
     (define act arg2)
     (match act
       [(list (and (or 'attack 'attack-unit) k) (? exact-integer? uid) (? exact-integer? tid))
        (order-ledger-record-issued! ledger uid k k #:target-id tid #:frame frame)]
       [(list (and (or 'kite 'move 'retreat 'attack-pos) k) (? exact-integer? uid) (? real? tx) (? real? ty))
        (order-ledger-record-issued! ledger uid k k #:target-x tx #:target-y ty #:frame frame)]
       [(list (or 'cast 'cast-spell) (? exact-integer? uid) (? symbol? sp) rest ...)
        (define tid (if (and (pair? rest) (exact-integer? (car rest))) (car rest) 0))
        (define tx (if (>= (length rest) 2) (first rest) #f))
        (define ty (if (>= (length rest) 2) (second rest) #f))
        (order-ledger-record-issued! ledger uid 'cast-spell sp
                                     #:target-id tid #:target-x tx #:target-y ty #:frame frame)]
       [_ ledger])]
    [else
     (define uid arg1)
     (define kind arg2)
     (define ability-sym arg3)
     (define target-id (or kw-target-id 0))
     (define target-x (or kw-target-x (and (real? arg4) arg4)))
     (define target-y (or kw-target-y (and (real? arg5) arg5)))
     (define frame (or kw-frame (if (exact-integer? arg6) arg6 0)))
     (define u-orders (in-progress-order-ledger-unit-orders ledger))
     (define t-counts (in-progress-order-ledger-type-order-counts ledger))
     (when (and (exact-integer? uid) (> uid 0))
       (set-add! (in-progress-order-ledger-step-issued-units ledger) uid)
       (hash-set! u-orders uid
                  (tracked-order uid kind ability-sym target-id target-x target-y
                                 frame frame 0.0 'issued)))
     (when ability-sym
       (hash-set! t-counts ability-sym (add1 (hash-ref t-counts ability-sym 0))))
     ledger]))

(define (order-ledger-unit-active-order ledger uid)
  (hash-ref (in-progress-order-ledger-unit-orders ledger) uid #f))

(define (order-ledger-unit-has-active-build? ledger uid [u-hash #f])
  (or (and (hash? u-hash)
           (or (eq? (hash-ref u-hash 'has-build-order? #f) #t)
               (memq (hash-ref u-hash 'order-kind #f) '(build expand))))
      (let ([tord (order-ledger-unit-active-order ledger uid)])
        (and tord (memq (tracked-order-kind tord) '(build expand)) #t))))

(define (order-ledger-pending-count-for-type ledger target-sym [_frame 0])
  (hash-ref (in-progress-order-ledger-type-order-counts ledger) target-sym 0))

(define (order-ledger-facility-busy? ledger bldg-hash [_frame 0])
  (define bid (hash-ref bldg-hash 'id 0))
  (define order-cnt (hash-ref bldg-hash 'order-count
                              (length (hash-ref bldg-hash 'orders '()))))
  (define has-reactor?
    (or (eq? (hash-ref bldg-hash 'addon #f) 'reactor)
        (memq (hash-ref bldg-hash 'addon-type #f)
              '(barracks-reactor factory-reactor starport-reactor))))
  (define max-slots (if has-reactor? 2 1))
  (or (>= order-cnt max-slots)
      (set-member? (in-progress-order-ledger-step-issued-units ledger) bid)))

;; Returns #t if combat unit `u` is currently in its weapon attack-point / backswing lock
;; or within its minimum commitment window so a new order should NOT cancel its shot!
(define (order-ledger-unit-in-attack-swing? ledger u [frame 0])
  (define uid (hash-ref u 'id 0))
  (define utype (hash-ref u 'type 'marine))
  (define stats (sc2-unit-combat-stats utype))
  (define w-period (hash-ref stats 'weapon-period 1.0))
  (define w-cd (hash-ref u 'weapon-cooldown 0.0))
  (define engaged-id (hash-ref u 'engaged-target-tag 0))
  (define ab-id (hash-ref u 'order-ability-id 0))
  (define tord (order-ledger-unit-active-order ledger uid))
  (or ;; 1. Already given a higher-priority command on this exact step
      (set-member? (in-progress-order-ledger-step-issued-units ledger) uid)
      ;; 2. Actively attacking an engaged target and winding up attack point (cd <= 0.08)
      (and (> engaged-id 0)
           (= ab-id 23)
           (<= w-cd SC2-WEAPON-READY-COOLDOWN-THRESH)
           (> (hash-ref stats 'damage-point 0.10) 0.08))
      ;; 3. Just fired within the last 2 frames (prevent post-damage-point state flicker)
      (and (> w-period 0.3)
           (> w-cd (- w-period 0.08)))
      ;; 4. Recently committed to a tactical order within SC2-TACTICAL-MIN-LOCK-FRAMES
      (and tord
           (> frame (tracked-order-issued-frame tord))
           (memq (tracked-order-kind tord) '(attack-unit kite retreat CloakHarassWorkers))
           (< (- frame (tracked-order-issued-frame tord)) SC2-TACTICAL-MIN-LOCK-FRAMES))))

;; Checks whether issuing `(kind target-id tx ty)` to `uid` is redundant with `uid`'s
;; currently active order in the SC2 engine or ledger.
(define (order-ledger-order-equivalent? ledger u kind target-id tx ty [frame 0])
  (define uid (if (hash? u) (hash-ref u 'id 0) u))
  (cond
    [(set-member? (in-progress-order-ledger-step-issued-units ledger) uid) #t]
    [else
     (define tord (order-ledger-unit-active-order ledger uid))
     (define u-ab-id (if (hash? u) (hash-ref u 'order-ability-id 0) 0))
     (define u-tgt-id (if (hash? u) (hash-ref u 'order-target-id (hash-ref u 'engaged-target-tag 0)) 0))
     (define u-tx (if (hash? u) (hash-ref u 'order-target-x #f) #f))
     (define u-ty (if (hash? u) (hash-ref u 'order-target-y #f) #f))
     (or
      ;; Check live engine order on unit hash
      (and (memq kind '(attack attack-unit))
           (= u-ab-id 23)
           (> target-id 0)
           (= u-tgt-id target-id))
      (and (memq kind '(move kite retreat))
           (= u-ab-id 16)
           (real? tx) (real? ty) (real? u-tx) (real? u-ty)
           (<= (dist2d-pts tx ty u-tx u-ty) SC2-ORDER-EQUIV-DIST-TOLERANCE))
      (and (eq? kind 'attack-pos)
           (= u-ab-id 23)
           (real? tx) (real? ty) (real? u-tx) (real? u-ty)
           (<= (dist2d-pts tx ty u-tx u-ty) SC2-ORDER-EQUIV-DIST-TOLERANCE))
      (and (eq? kind 'hold-position)
           (= u-ab-id 18))
      ;; Check ledger tracked order
      (and tord
           (<= (- frame (tracked-order-last-seen-frame tord)) 12)
           (or (and (memq kind '(attack attack-unit))
                    (memq (tracked-order-kind tord) '(attack attack-unit))
                    (> target-id 0)
                    (= (tracked-order-target-id tord) target-id))
               (and (memq kind '(move kite retreat attack-pos))
                    (eq? (tracked-order-kind tord) kind)
                    (real? tx) (real? ty)
                    (real? (tracked-order-target-x tord))
                    (real? (tracked-order-target-y tord))
                    (<= (dist2d-pts tx ty
                                    (tracked-order-target-x tord)
                                    (tracked-order-target-y tord))
                        SC2-ORDER-EQUIV-DIST-TOLERANCE)))))]))

(define (order-ledger-reserve-build-site! ledger bldg-sym x y [builder-id 0] [frame 0])
  (define site
    (reserved-build-site bldg-sym
                         (exact->inexact x)
                         (exact->inexact y)
                         builder-id
                         frame
                         (+ frame SC2-BUILD-SITE-RESERVATION-TTL)))
  (set-in-progress-order-ledger-reserved-sites!
   ledger
   (cons site (in-progress-order-ledger-reserved-sites ledger)))
  site)

;; Ensures a proposed build coordinate `(x, y)` does not collide with any active
;; `reserved-build-site` or existing `ally-buildings` (including add-on slots!),
;; spiraling outward if needed and reserving the chosen site.
(define (order-ledger-resolve-build-coords! ledger bldg-sym raw-x raw-y ally-bldgs
                                            [pos-frame 0]
                                            [pos-clearance SC2-BUILD-SITE-MIN-CLEARANCE]
                                            #:builder-id [builder-id 0]
                                            #:frame [kw-frame #f]
                                            #:clearance [kw-clearance #f])
  (define frame (or kw-frame pos-frame))
  (define clearance (or kw-clearance pos-clearance))
  (define sites (in-progress-order-ledger-reserved-sites ledger))
  (define is-3x3-addon-fac? (memq bldg-sym '(barracks factory starport)))
  (define snap-fn (if is-3x3-addon-fac? snap-3x3-coord snap-2x2-coord))
  (define x0 (snap-fn raw-x))
  (define y0 (snap-fn raw-y))
  (define (spot-free? cx cy)
    (and (>= cx SC2-MAP-PLAYABLE-MIN-COORD) (<= cx SC2-MAP-PLAYABLE-MAX-COORD)
         (>= cy SC2-MAP-PLAYABLE-MIN-COORD) (<= cy SC2-MAP-PLAYABLE-MAX-COORD)
         (for/and ([s (in-list sites)])
           (> (dist2d-pts cx cy (reserved-build-site-x s) (reserved-build-site-y s))
              clearance))
         (for/and ([b (in-list ally-bldgs)] #:when (hash? b))
           (define bx (hash-ref b 'x 0.0))
           (define by (hash-ref b 'y 0.0))
           (define btype (hash-ref b 'type #f))
           (and (> (dist2d-pts cx cy bx by) clearance)
                ;; Also avoid existing Terran facilities' East (+X) add-on slots!
                (or (not (memq btype '(barracks factory starport)))
                    (> (dist2d-pts cx cy
                                   (+ bx SC2-TERRAN-ADDON-OFFSET-X)
                                   (+ by SC2-TERRAN-ADDON-OFFSET-Y))
                       clearance))))))
  (define-values (chosen-x chosen-y)
    (if (spot-free? x0 y0)
        (values x0 y0)
        (let search ([r 3.0])
          (if (> r 15.0)
              (values x0 y0)
              (let ([found
                     (for*/first ([dx (in-list (list 0.0 r (- r)))]
                                  [dy (in-list (list 0.0 r (- r)))]
                                  #:when (and (or (not (zero? dx)) (not (zero? dy)))
                                              (spot-free? (snap-fn (+ x0 dx))
                                                          (snap-fn (+ y0 dy)))))
                       (cons (snap-fn (+ x0 dx)) (snap-fn (+ y0 dy))))])
                (if found
                    (values (car found) (cdr found))
                    (search (+ r 3.0))))))))
  (order-ledger-reserve-build-site! ledger bldg-sym chosen-x chosen-y builder-id frame)
  (values chosen-x chosen-y))

;; =============================================================================
;; 6. Multi-Depth Mirrored Tactical Micro Brain (`step-tactical-mirror-brain!`)
;; =============================================================================
;; Runs a local engagement-level mirrored brain for each active tactical arena:
;;   - Models symmetric micro action repertoires for BOTH our squad and enemy squad:
;;     `'(CommitFocusFire StutterKiteBack KiteForwardChase FlankSurround
;;        CloakHarassWorkers DisengageRetreat HoldChoke)`
;;   - Predicts 2D unit movement trajectories & weapon-cooldown exchanges across
;;     three lookahead depths:
;;       * Depth 1: `SC2-TACTICAL-DEPTH1-SEC` (0.50s / 2 ticks) — immediate volley
;;       * Depth 2: `SC2-TACTICAL-DEPTH2-SEC` (2.00s / 8 ticks) — skirmish trade
;;       * Depth 3: `SC2-TACTICAL-DEPTH3-SEC` (5.00s / 20 ticks) — fight & reinforcements
;;   - Selects our micro policy via regret-hedged minimax + hysteresis commitment lock
;;     so units (especially Banshees/Stalkers/Bio/Mutas) never oscillate orders.

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
                                        (<= (dist2d-pts ux uy (hash-ref v 'x ux) (hash-ref v 'y uy))
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
                   (<= (dist2d-pts cx cy (hash-ref e 'x 999.0) (hash-ref e 'y 999.0))
                       SC2-TACTICAL-ARENA-ENGAGE-RADIUS))
                 enemy-units))
       (define local-enemy-bldgs
         (filter (lambda (eb)
                   (<= (dist2d-pts cx cy (hash-ref eb 'x 999.0) (hash-ref eb 'y 999.0))
                       SC2-TACTICAL-ARENA-ENGAGE-RADIUS))
                 enemy-bldgs))
       (when (or (not (null? local-enemies)) (not (null? local-enemy-bldgs)))
         (define enemy-workers
           (filter (lambda (e) (memq (hash-ref e 'type #f) '(scv probe drone))) local-enemies))
         (define reinf-allies
           (for/list ([u (in-list combat-allies)]
                      #:when (let ([d (dist2d-pts cx cy (hash-ref u 'x cx) (hash-ref u 'y cy))])
                               (and (> d SC2-TACTICAL-ARENA-CLUSTER-RADIUS)
                                    (<= d SC2-TACTICAL-REINFORCE-RADIUS))))
             (define d (dist2d-pts cx cy (hash-ref u 'x cx) (hash-ref u 'y cy)))
             (define spd (max 2.0 (hash-ref (sc2-unit-combat-stats (hash-ref u 'type 'marine)) 'speed 3.15)))
             (unit-hash->tactical-sim-unit u 'ally #:eta-sec (/ (- d 6.0) spd))))
         (define reinf-enemies
           (for/list ([e (in-list enemy-units)]
                      #:when (let ([d (dist2d-pts cx cy (hash-ref e 'x cx) (hash-ref e 'y cy))])
                               (and (> d SC2-TACTICAL-ARENA-ENGAGE-RADIUS)
                                    (<= d SC2-TACTICAL-REINFORCE-RADIUS))))
             (define d (dist2d-pts cx cy (hash-ref e 'x cx) (hash-ref e 'y cy)))
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
  (define enemy-stasis-pts
    (append
     (for/list ([e (in-list sim-enemies)]
                #:when (and (> (tactical-sim-unit-hp e) 0.0)
                            (memq (tactical-sim-unit-type e) '(oracle-stasis-trap stasis-ward))))
       (cons (tactical-sim-unit-x e) (tactical-sim-unit-y e)))
     (for/list ([eb (in-list (tactical-arena-enemy-structures arena))]
                #:when (and (hash? eb)
                            (memq (hash-ref eb 'type #f) '(oracle-stasis-trap stasis-ward))))
       (cons (exact->inexact (hash-ref eb 'x 999.0))
             (exact->inexact (hash-ref eb 'y 999.0))))))
  (define ally-worker-count
    (count (lambda (a)
             (and (> (tactical-sim-unit-hp a) 0.0)
                  (memq (tactical-sim-unit-type a) '(scv probe drone))))
           sim-allies))

  ;; Activate cloak on CloakHarassWorkers if unit can cloak and has energy >= 25
  (when (eq? our-action 'CloakHarassWorkers)
    (for ([a (in-list sim-allies)]
          #:when (and (tactical-sim-unit-can-cloak? a)
                      (>= (tactical-sim-unit-energy a) SC2-BANSHEE-CLOAK-MIN-ENERGY)))
      (set-tactical-sim-unit-cloaked?! a #t)))

  ;; Decrement reinforcement ETAs and weapon cooldowns
  (for ([u (in-list (append sim-allies sim-enemies))])
    (when (> (tactical-sim-unit-eta-sec u) 0.0)
      (set-tactical-sim-unit-eta-sec! u (max 0.0 (- (tactical-sim-unit-eta-sec u) dt))))
    (when (> (tactical-sim-unit-weapon-cooldown u) 0.0)
      (set-tactical-sim-unit-weapon-cooldown! u (max 0.0 (- (tactical-sim-unit-weapon-cooldown u) dt)))))

  ;; Oracle Stasis Ward hazard penalty: penalize CommitFocusFire / KiteForwardChase when an enemy
  ;; stasis trap is within 4.5 tiles of friendly short-range units, rewarding StutterKiteBack / FlankSurround
  (when (not (null? enemy-stasis-pts))
    (for ([a (in-list sim-allies)]
          #:when (and (> (tactical-sim-unit-hp a) 0.0)
                      (not (tactical-sim-unit-flying? a))
                      (<= (tactical-sim-unit-ground-range a) 4.5)))
      (define ax (tactical-sim-unit-x a))
      (define ay (tactical-sim-unit-y a))
      (define near-trap?
        (ormap (lambda (pt)
                 (<= (dist2d-pts ax ay (car pt) (cdr pt)) 4.5))
               enemy-stasis-pts))
      (when (and near-trap? (memq our-action '(CommitFocusFire KiteForwardChase HoldChoke)))
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
                         (dist2d-pts (tactical-sim-unit-x u) (tactical-sim-unit-y u)
                                     (tactical-sim-unit-x o) (tactical-sim-unit-y o)))
                       valid-targets))]
          [(or (eq? action 'CommitFocusFire) (eq? action 'KiteForwardChase))
           (argmax (lambda (o)
                     (define d (max 1.0 (dist2d-pts (tactical-sim-unit-x u) (tactical-sim-unit-y u)
                                                    (tactical-sim-unit-x o) (tactical-sim-unit-y o))))
                     (/ (+ 5.0 (tactical-sim-unit-ground-dps o) (tactical-sim-unit-air-dps o))
                        (* (+ (tactical-sim-unit-hp o) (tactical-sim-unit-shield o))
                           (max 1.0 (/ d (max 1.0 (sim-unit-weapon-range-vs u o)))))))
                   valid-targets)]
          [else
           (argmin (lambda (o)
                     (dist2d-pts (tactical-sim-unit-x u) (tactical-sim-unit-y u)
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
                             (<= (dist2d-pts tx ty (tactical-sim-unit-x adj) (tactical-sim-unit-y adj))
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

(define (evaluate-arena-minimax-and-regret! brain arena frame #:strategic-opp-depth [opp-d 1])
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
                                  [d (max 1.0 (dist2d-pts ux uy (tactical-sim-unit-x e) (tactical-sim-unit-y e)))]
                                  [det? (or (memq etype SC2-MOBILE-DETECTOR-SYMS)
                                            (memq etype SC2-STATIC-DETECTOR-SYMS))]
                                  [chg? (memq etype SC2-CHANGELING-UNIT-SYMS)]
                                  [decoy-mult
                                   (cond
                                     [chg? 4.0]
                                     [(and det? arena-has-stealth?) SC2-DETECTOR-SNIPE-PRIORITY-BONUS]
                                     [(memq etype SC2-PASSIVE-SCOUT-OR-DECOY-UNIT-SYMS) 0.05]
                                     [else 1.0])]
                                  [eff-dps
                                   (if (and det? arena-has-stealth?)
                                       (max 22.0 (+ 5.0 (tactical-sim-unit-ground-dps e) (tactical-sim-unit-air-dps e)))
                                       (+ 5.0 (tactical-sim-unit-ground-dps e) (tactical-sim-unit-air-dps e)))]
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
               (when ledger
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
                  (when ledger
                    (order-ledger-record-issued! ledger uid 'kite 'move #:target-x kx #:target-y ky #:frame frame))
                  (emit! (list 'kite uid kx ky)))]
               [else
                (unless (and ledger (order-ledger-order-equivalent? ledger u-hash 'attack-unit eid ex ey frame))
                  (when ledger
                    (order-ledger-record-issued! ledger uid 'attack-unit 'attack #:target-id eid #:frame frame))
                  (emit! (list 'attack-unit uid eid)))])]

            [(HoldChoke)
             (define dist-to-nat (dist2d-pts ux uy nat-x nat-y))
             (if (<= dist-to-nat 3.5)
                 (unless (and ledger (order-ledger-order-equivalent? ledger u-hash 'hold-position 0 nat-x nat-y frame))
                   (when ledger
                     (order-ledger-record-issued! ledger uid 'hold-position 'hold-position #:frame frame))
                   (emit! (list 'hold-position uid nat-x nat-y)))
                 (unless (and ledger (order-ledger-order-equivalent? ledger u-hash 'attack-unit eid ex ey frame))
                   (when ledger
                     (order-ledger-record-issued! ledger uid 'attack-unit 'attack #:target-id eid #:frame frame))
                   (emit! (list 'attack-unit uid eid))))]

            [else ;; CommitFocusFire, KiteForwardChase, FlankSurround
             (unless (and ledger (order-ledger-order-equivalent? ledger u-hash 'attack-unit eid ex ey frame))
               (when ledger
                 (order-ledger-record-issued! ledger uid 'attack-unit 'attack #:target-id eid #:frame frame))
               (emit! (list 'attack-unit uid eid)))])))))

  (set-tactical-mirror-brain-last-decisions! brain (reverse decisions))
  (values (reverse actions) committed-tags (reverse decisions)))

;; =============================================================================
;; 7. Burrowed Roach / Infestor Movement Micro, Shimmer/Burrow-Ripple Skillshots
;;    & Pro Terran Add-On Swapping (1,649 / 1,685 Replay Empirical Models)
;; =============================================================================

;; Burrowed Roach (`TunnelingClaws`) movement & regeneration micro:
;; - When Roach HP ratio <= `SC2-ROACH-BURROW-HP-PCT-THRESH` (0.38) and Burrow is
;;   researched: burrow down (`burrow-down`) and tunnel-move toward `base-x, base-y`
;;   (`roach-tunnel-move`) if `tunneling-claws` is researched (or enemy has detection).
;; - When Burrowed Roach HP ratio >= `SC2-ROACH-UNBURROW-HP-PCT-THRESH` (0.82), or
;;   when flanking within `SC2-ROACH-TUNNEL-FLANK-RANGE` (4.0) of enemy backline:
;;   unburrow (`burrow-up`) to re-engage!
(define (execute-roach-tunneling-burrow-micro obs)
  (define sanitized-obs (if (hash? obs) obs (hash)))
  (define upgrades (hash-ref sanitized-obs 'researched-upgrades '()))
  (define has-burrow?
    (or (not (hash-has-key? sanitized-obs 'researched-upgrades))
        (and (memq 'burrow upgrades) #t)
        (and (memq 'tunneling-claws upgrades) #t)))
  (define has-tunneling?
    (or (not (hash-has-key? sanitized-obs 'researched-upgrades))
        (and (memq 'tunneling-claws upgrades) #t)))
  (define base-x (exact-round (hash-ref sanitized-obs 'base-x SC2-DEFAULT-HOME-BASE-X)))
  (define base-y (exact-round (hash-ref sanitized-obs 'base-y SC2-DEFAULT-HOME-BASE-Y)))
  (define ally-units (hash-ref sanitized-obs 'ally-units '()))
  (define enemy-units (hash-ref sanitized-obs 'enemy-units '()))
  (define actions '())
  (define (emit! a) (set! actions (cons a actions)))

  (when has-burrow?
    (for ([u (in-list ally-units)]
          #:when (and (hash? u)
                      (memq (hash-ref u 'type 'unknown) '(roach roach-burrowed))))
      (define uid (hash-ref u 'id 0))
      (define utype (hash-ref u 'type 'roach))
      (define burrowed?
        (or (eq? utype 'roach-burrowed)
            (hash-ref u 'burrowed #f)
            (hash-ref u 'is-burrowed? #f)))
      (define hp (max 1.0 (exact->inexact (hash-ref u 'hp 145))))
      (define max-hp (max 1.0 (exact->inexact (hash-ref u 'max-hp 145))))
      (define hp-pct (/ hp max-hp))
      (define ux (exact->inexact (hash-ref u 'x base-x)))
      (define uy (exact->inexact (hash-ref u 'y base-y)))
      (define nearest-e
        (and (not (null? enemy-units))
             (argmin (lambda (e)
                       (dist2d-pts ux uy
                                   (exact->inexact (hash-ref e 'x 160))
                                   (exact->inexact (hash-ref e 'y 160))))
                     enemy-units)))
      (define dist-e
        (if nearest-e
            (dist2d-pts ux uy
                        (exact->inexact (hash-ref nearest-e 'x 160))
                        (exact->inexact (hash-ref nearest-e 'y 160)))
            999.0))
      (cond
        ;; Unburrowed Roach at low HP under fire -> Burrow down (+ tunnel retreat if TunnelingClaws)
        [(and (not burrowed?)
              (<= hp-pct SC2-ROACH-BURROW-HP-PCT-THRESH)
              (<= dist-e 12.0))
         (emit! (list 'burrow-down uid 'roach-regen-escape))
         (when has-tunneling?
           (define-values (kx ky)
             (if nearest-e
                 (compute-kite-vector (exact-round ux) (exact-round uy)
                                      (exact-round (hash-ref nearest-e 'x 160))
                                      (exact-round (hash-ref nearest-e 'y 160))
                                      5)
                 (values base-x base-y)))
           (emit! (list 'roach-tunnel-move uid kx ky)))]
        ;; Burrowed Roach still low HP -> Tunnel-move to safety or flank
        [(and burrowed? (< hp-pct SC2-ROACH-UNBURROW-HP-PCT-THRESH))
         (when has-tunneling?
           (define-values (kx ky)
             (if (and nearest-e (<= dist-e 10.0))
                 (compute-kite-vector (exact-round ux) (exact-round uy)
                                      (exact-round (hash-ref nearest-e 'x 160))
                                      (exact-round (hash-ref nearest-e 'y 160))
                                      5)
                 (values base-x base-y)))
           (emit! (list 'roach-tunnel-move uid kx ky)))]
        ;; Burrowed Roach healed (>= 82% HP) or in flank range -> Unburrow!
        [(and burrowed? (>= hp-pct SC2-ROACH-UNBURROW-HP-PCT-THRESH))
         (emit! (list 'burrow-up uid 'roach-healed-reengage))])))
  (reverse actions))

;; Burrowed Infestor movement, cast & escape micro (`1,105` Infestors in 1,649 replays):
;; - Infestors burrow-approach (`burrow-down` + `infestor-burrow-move`) when within
;;   `SC2-INFESTOR-BURROW-APPROACH-RANGE` (16.0) of enemy army.
;; - Cast `fungal-growth` (range 10, energy >= 75) on enemy clusters or `neural-parasite`
;;   (range 9, energy >= 100, playable while burrowed) on high-value capital units
;;   (`thor`, `battlecruiser`, `siege-tank`, `siege-tank-sieged`, `colossus`, `immortal`,
;;   `archon`, `carrier`, `tempest`, `mothership`).
;; - After casting (`energy < 75`), immediately burrow-retreat toward `base-x, base-y`.
(define (execute-infestor-burrow-cast-micro obs)
  (define sanitized-obs (if (hash? obs) obs (hash)))
  (define base-x (exact-round (hash-ref sanitized-obs 'base-x SC2-DEFAULT-HOME-BASE-X)))
  (define base-y (exact-round (hash-ref sanitized-obs 'base-y SC2-DEFAULT-HOME-BASE-Y)))
  (define ally-units (hash-ref sanitized-obs 'ally-units '()))
  (define enemy-units (hash-ref sanitized-obs 'enemy-units '()))
  (define capital-syms
    '(thor battlecruiser siege-tank siege-tank-sieged colossus immortal archon carrier tempest mothership ultralisk))
  (define actions '())
  (define (emit! a) (set! actions (cons a actions)))

  (for ([u (in-list ally-units)]
        #:when (and (hash? u)
                    (memq (hash-ref u 'type 'unknown) '(infestor infestor-burrowed))))
    (define uid (hash-ref u 'id 0))
    (define utype (hash-ref u 'type 'infestor))
    (define burrowed?
      (or (eq? utype 'infestor-burrowed)
          (hash-ref u 'burrowed #f)
          (hash-ref u 'is-burrowed? #f)))
    (define energy (exact->inexact (hash-ref u 'energy 75)))
    (define ux (exact->inexact (hash-ref u 'x base-x)))
    (define uy (exact->inexact (hash-ref u 'y base-y)))
    (define nearest-e
      (and (not (null? enemy-units))
           (argmin (lambda (e)
                     (dist2d-pts ux uy
                                 (exact->inexact (hash-ref e 'x 160))
                                 (exact->inexact (hash-ref e 'y 160))))
                   enemy-units)))
    (when nearest-e
      (define ex (exact-round (hash-ref nearest-e 'x 160)))
      (define ey (exact-round (hash-ref nearest-e 'y 160)))
      (define dist-e (dist2d-pts ux uy (exact->inexact ex) (exact->inexact ey)))
      (define capital-target
        (findf (lambda (e)
                 (and (memq (hash-ref e 'type 'unknown) capital-syms)
                      (<= (dist2d-pts ux uy
                                      (exact->inexact (hash-ref e 'x 160))
                                      (exact->inexact (hash-ref e 'y 160)))
                          (+ SC2-INFESTOR-NEURAL-CAST-RANGE 2.0))))
               enemy-units))
      (cond
        ;; Energy spent (< 75) -> ensure burrowed and burrow-move retreat to home base
        [(< energy SC2-INFESTOR-FUNGAL-ENERGY)
         (unless burrowed?
           (emit! (list 'burrow-down uid 'infestor-post-cast-hide)))
         (emit! (list 'infestor-burrow-move uid base-x base-y))]
        ;; High-value capital unit in range and energy >= 100 -> Neural Parasite
        [(and capital-target (>= energy SC2-INFESTOR-NEURAL-ENERGY))
         (define cx (exact-round (hash-ref capital-target 'x ex)))
         (define cy (exact-round (hash-ref capital-target 'y ey)))
         (unless burrowed?
           (emit! (list 'burrow-down uid 'infestor-stealth-neural)))
         (emit! (list 'infestor-burrow-cast uid 'neural-parasite cx cy))]
        ;; Within Fungal Growth range (<= 10.5) and energy >= 75 -> Unburrow (if needed) & cast Fungal Growth
        [(and (<= dist-e (+ SC2-INFESTOR-FUNGAL-CAST-RANGE 0.5))
              (>= energy SC2-INFESTOR-FUNGAL-ENERGY))
         (when burrowed?
           (emit! (list 'burrow-up uid 'infestor-unburrow-for-fungal)))
         (emit! (list 'infestor-burrow-cast uid 'fungal-growth ex ey))]
        ;; Within approach range (<= 16.0) -> Burrow down & sneak into Fungal/Neural range
        [(<= dist-e SC2-INFESTOR-BURROW-APPROACH-RANGE)
         (unless burrowed?
           (emit! (list 'burrow-down uid 'infestor-stealth-approach)))
         (emit! (list 'infestor-burrow-move uid ex ey))])))
  (reverse actions))

;; Blind AoE Skillshot & Emergency Detector Response on Cloaked Shimmer / Burrow Ripples:
;; When an enemy unit is observed with `display-type = 2 (Hidden)`, `cloak-state = 2`,
;; `is-shimmer? = #t`, or burrowed movement ripples (`shimmer-and-burrow-ripples`),
;; fire available AoE / reveal spells (`corrosive-bile`, `psi-storm`, `fungal-growth`,
;; `purification-nova`, `emp-round`, `scanner-sweep`, `oracle-revelation`) at the
;; exact shimmer/ripple coordinates and emit `emergency-detector-response`.
(define (execute-shimmer-and-burrow-ripple-response obs)
  (define sanitized-obs (if (hash? obs) obs (hash)))
  (define ally-units (hash-ref sanitized-obs 'ally-units '()))
  (define ally-bldgs (hash-ref sanitized-obs 'ally-buildings '()))
  (define enemy-units (hash-ref sanitized-obs 'enemy-units '()))
  (define explicit-ripples (hash-ref sanitized-obs 'shimmer-and-burrow-ripples '()))
  (define shimmer-targets
    (append
     (filter hash? explicit-ripples)
     (filter (lambda (e)
               (and (hash? e)
                    (or (hash-ref e 'is-shimmer? #f)
                        (= (hash-ref e 'display-type 1) SC2-SHIMMER-DISPLAY-TYPE-HIDDEN)
                        (= (hash-ref e 'cloak-state 0) 2)
                        (hash-ref e 'burrowed #f))))
             enemy-units)))
  (cond
    [(null? shimmer-targets) '()]
    [else
     (define tgt (first shimmer-targets))
     (define tx (exact-round (hash-ref tgt 'x 160)))
     (define ty (exact-round (hash-ref tgt 'y 160)))
     (define kind (hash-ref tgt 'indicator-kind 'cloaked-shimmer))
     (define actions (list (list 'emergency-detector-response kind tx ty)))
     (define (emit! a) (set! actions (cons a actions)))

     ;; Check friendly AoE casters / revealers
     (for ([u (in-list ally-units)]
           #:when (hash? u))
       (define uid (hash-ref u 'id 0))
       (define utype (hash-ref u 'type 'unknown))
       (define energy (exact->inexact (hash-ref u 'energy 75)))
       (case utype
         [(ravager)
          (emit! (list 'blind-skillshot-shimmer uid 'corrosive-bile tx ty))]
         [(high-templar)
          (when (>= energy 75.0)
            (emit! (list 'blind-skillshot-shimmer uid 'psi-storm tx ty)))]
         [(infestor infestor-burrowed)
          (when (>= energy 75.0)
            (emit! (list 'blind-skillshot-shimmer uid 'fungal-growth tx ty)))]
         [(disruptor)
          (emit! (list 'blind-skillshot-shimmer uid 'purification-nova tx ty))]
         [(ghost)
          (when (>= energy 75.0)
            (emit! (list 'blind-skillshot-shimmer uid 'emp-round tx ty)))]
         [(oracle)
          (when (>= energy 25.0)
            (emit! (list 'blind-skillshot-shimmer uid 'oracle-revelation tx ty)))]))

     ;; Check Orbital Command Scanner Sweep
     (for ([b (in-list ally-bldgs)]
           #:when (and (hash? b)
                       (eq? (hash-ref b 'type 'unknown) 'orbital-command)
                       (>= (exact->inexact (hash-ref b 'energy 50)) 50.0)))
       (emit! (list 'blind-skillshot-shimmer (hash-ref b 'id 0) 'scanner-sweep tx ty)))

     (reverse actions)]))

;; Pro Terran Building Lift-Off & Add-On Swapping (`480` swaps across 1,245 Terran pro replays,
;; median first swap at `198.6s` = frame `4,448`):
;; Swaps idle `Barracks` / `Factory` / `Starport` onto a pre-built `TechLab` or `Reactor`
;; when either:
;;   1. An unattached add-on (`free-addons`) is present and a production facility lacks an add-on, or
;;   2. A `Barracks` built a `Reactor` or `TechLab` for a newly completed `Factory` or `Starport`
;;      (`Barracks->Factory: 111`, `Factory->Barracks: 110`, `Barracks->Starport: 77`).
(define (plan-terran-addon-swap obs)
  (define sanitized-obs (if (hash? obs) obs (hash)))
  (define frame (hash-ref sanitized-obs 'frame 0))
  (define base-x (exact->inexact (hash-ref sanitized-obs 'base-x 32.0)))
  (define base-y (exact->inexact (hash-ref sanitized-obs 'base-y 32.0)))
  (define ally-bldgs (filter hash? (hash-ref sanitized-obs 'ally-buildings '())))
  (define addon-syms
    '(barracks-techlab barracks-tech-lab barracks-reactor
      factory-techlab factory-tech-lab factory-reactor
      starport-techlab starport-tech-lab starport-reactor
      tech-lab reactor))
  (define all-ally-addons
    (filter (lambda (b)
              (and (memq (hash-ref b 'type 'unknown) addon-syms)
                   (>= (hash-ref b 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS)))
            ally-bldgs))
  (define attached-addon-ids
    (for/fold ([acc '()]) ([b (in-list ally-bldgs)])
      (define atag (hash-ref b 'add-on-tag 0))
      (if (and (exact-integer? atag) (> atag 0))
          (cons atag acc)
          acc)))
  (define (bldg-is-flying-prod? b)
    (define bt (hash-ref b 'type 'unknown))
    (or (memq bt '(barracks-flying factory-flying starport-flying))
        (and (memq bt '(barracks factory starport))
             (or (eq? (hash-ref b 'flying? #f) #t)
                 (eq? (hash-ref b 'is-flying #f) #t)))))
  (define (bldg-has-addon? b)
    (or (eq? (hash-ref b 'has-addon? #f) #t)
        (not (not (hash-ref b 'addon #f)))
        (> (hash-ref b 'add-on-tag 0) 0)
        (let ([bx (exact->inexact (hash-ref b 'x 0.0))]
              [by (exact->inexact (hash-ref b 'y 0.0))])
          (ormap (lambda (ad)
                   (<= (dist2d-pts (+ bx SC2-TERRAN-ADDON-OFFSET-X)
                                   (+ by SC2-TERRAN-ADDON-OFFSET-Y)
                                   (exact->inexact (hash-ref ad 'x 9999.0))
                                   (exact->inexact (hash-ref ad 'y 9999.0)))
                       1.25))
                 all-ally-addons))))
  (define orphaned-addons
    (filter (lambda (ad)
              (define aid (hash-ref ad 'id 0))
              (define ax (exact->inexact (hash-ref ad 'x 34.5)))
              (define ay (exact->inexact (hash-ref ad 'y 31.5)))
              (and (not (memv aid attached-addon-ids))
                   (not (ormap (lambda (b)
                                 (and (memq (hash-ref b 'type 'unknown) '(barracks factory starport))
                                      (not (bldg-is-flying-prod? b))
                                      (<= (dist2d-pts (- ax SC2-TERRAN-ADDON-OFFSET-X)
                                                      (+ ay (- SC2-TERRAN-ADDON-OFFSET-Y))
                                                      (exact->inexact (hash-ref b 'x 9999.0))
                                                      (exact->inexact (hash-ref b 'y 9999.0)))
                                          1.25)))
                               ally-bldgs))))
            all-ally-addons))
  (define explicit-free-addons (filter hash? (hash-ref sanitized-obs 'free-addons '())))
  (define free-addons
    (append explicit-free-addons
            (filter (lambda (ad)
                      (not (ormap (lambda (ef)
                                    (equal? (hash-ref ef 'id -1) (hash-ref ad 'id -2)))
                                  explicit-free-addons)))
                    orphaned-addons)))
  (define idle-lifted-prod
    (findf (lambda (b)
             (and (bldg-is-flying-prod? b)
                  (not (hash-ref b 'busy? #f))
                  (= (hash-ref b 'order-count 0) 0)))
           ally-bldgs))
  (define bare-fac-or-port
    (findf (lambda (b)
             (and (memq (hash-ref b 'type 'unknown) '(factory starport))
                  (not (bldg-is-flying-prod? b))
                  (not (bldg-has-addon? b))
                  (not (hash-ref b 'busy? #f))))
           ally-bldgs))
  (define donor-rax-or-fac
    (findf (lambda (b)
             (and (memq (hash-ref b 'type 'unknown) '(barracks factory))
                  (not (bldg-is-flying-prod? b))
                  (bldg-has-addon? b)
                  (not (hash-ref b 'busy? #f))))
           ally-bldgs))
  (cond
    ;; Case 0a: Idle lifted Barracks/Factory/Starport + unattached TechLab/Reactor -> land & attach immediately!
    [(and idle-lifted-prod (not (null? free-addons)))
     (define addon (first free-addons))
     (define ax (exact->inexact (hash-ref addon 'x (+ base-x 6.5))))
     (define ay (exact->inexact (hash-ref addon 'y (+ base-y 3.5))))
     (list (list 'terran-addon-swap 0 (hash-ref idle-lifted-prod 'id 0) ax ay))]
    ;; Case 0b: Stranded idle lifted Barracks/Factory/Starport with no free add-on -> land on clear ground!
    [idle-lifted-prod
     (define bx (exact->inexact (hash-ref idle-lifted-prod 'x (+ base-x 4.0))))
     (define by (exact->inexact (hash-ref idle-lifted-prod 'y (+ base-y 4.0))))
     (list (list 'land-building (hash-ref idle-lifted-prod 'id 0) bx by))]
    ;; Case 1: Free unattached TechLab/Reactor available + bare grounded Barracks/Factory/Starport
    [(and (not (null? free-addons))
          (or bare-fac-or-port
              (findf (lambda (b)
                       (and (eq? (hash-ref b 'type 'unknown) 'barracks)
                            (not (bldg-is-flying-prod? b))
                            (not (bldg-has-addon? b))
                            (not (hash-ref b 'busy? #f))))
                     ally-bldgs)))
     (define addon (first free-addons))
     (define receiver
       (or bare-fac-or-port
           (findf (lambda (b)
                    (and (eq? (hash-ref b 'type 'unknown) 'barracks)
                         (not (bldg-is-flying-prod? b))
                         (not (bldg-has-addon? b))
                         (not (hash-ref b 'busy? #f))))
                  ally-bldgs)))
     (define ax (exact->inexact (hash-ref addon 'x 34.5)))
     (define ay (exact->inexact (hash-ref addon 'y 31.5)))
     (list (list 'terran-addon-swap 0 (hash-ref receiver 'id 0) ax ay))]
    ;; Case 2: Active pro swap (`frame >= SC2-TERRAN-FIRST-ADDON-SWAP-FRAME` or explicit swap-ready)
    [(and bare-fac-or-port
          donor-rax-or-fac
          (not (eq? (hash-ref bare-fac-or-port 'type 'unknown)
                    (hash-ref donor-rax-or-fac 'type 'unknown)))
          (>= frame SC2-TERRAN-FIRST-ADDON-SWAP-FRAME))
     (define dx (exact->inexact (hash-ref donor-rax-or-fac 'x 32.0)))
     (define dy (exact->inexact (hash-ref donor-rax-or-fac 'y 32.0)))
     (define ax (exact->inexact (hash-ref donor-rax-or-fac 'addon-x (+ dx 2.5))))
     (define ay (exact->inexact (hash-ref donor-rax-or-fac 'addon-y (- dy 0.5))))
     (list (list 'terran-addon-swap
                 (hash-ref donor-rax-or-fac 'id 0)
                 (hash-ref bare-fac-or-port 'id 0)
                 ax
                 ay))]
    [else '()]))


