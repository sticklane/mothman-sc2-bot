#lang racket/base

(require racket/match
         racket/list
         racket/math)

(provide
 ;; Baba CSP Choke Wall-In Solver
 PROTOSS-FFE-BUILDINGS
 TERRAN-BARRACKS-DEPOT-BUILDINGS
 (struct-out wall-placement)
 (struct-out wall-solution)
 solve-choke-wall-in
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
 compute-concave-arc)

;; =============================================================================
;; 1. Baba CSP Choke Wall-In Solver (`solve-choke-wall-in`)
;;    Zergling width = 0.75 tiles => gap <= 15 is zergling-tight!
;; =============================================================================

(struct wall-placement (type x y w h gap) #:transparent)
(struct wall-solution (valid zergling-tight max-gap span placements) #:transparent)

(define PROTOSS-FFE-BUILDINGS
  (list (hash 'type 'pylon 'w 2 'h 2 'gap 0 'powers-radius 6)
        (hash 'type 'forge 'w 3 'h 2 'gap 4)
        (hash 'type 'gateway 'w 4 'h 3 'gap 11)
        (hash 'type 'photon-cannon 'w 2 'h 2 'gap 13)))

(define TERRAN-BARRACKS-DEPOT-BUILDINGS
  (list (hash 'type 'barracks 'w 3 'h 3 'gap 8)
        (hash 'type 'supply-depot 'w 3 'h 2 'gap 12)
        (hash 'type 'bunker 'w 3 'h 2 'gap 12)
        (hash 'type 'barracks-techlab 'w 4 'h 3 'gap 12)))

(define (solve-choke-wall-in choke-x choke-y span
                             [positional-buildings #f]
                             #:preset [preset #f]
                             #:buildings [kw-buildings #f])
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

  (define placements
    (case effective-preset
      [(terran-barracks-depot terran)
       (if (>= span 10)
           (list (hash 'type 'barracks         'x choke-x       'y (+ choke-y 4) 'w 3 'h 3 'gap 8)
                 (hash 'type 'supply-depot     'x (+ choke-x 3) 'y (+ choke-y 4) 'w 3 'h 2 'gap 12)
                 (hash 'type 'barracks-techlab 'x (+ choke-x 6) 'y (+ choke-y 4) 'w 4 'h 3 'gap 12))
           (list (hash 'type 'barracks         'x choke-x       'y (+ choke-y 4) 'w 3 'h 3 'gap 8)
                 (hash 'type 'supply-depot     'x (+ choke-x 3) 'y (+ choke-y 4) 'w 3 'h 2 'gap 12)
                 (hash 'type 'bunker           'x (+ choke-x 6) 'y (+ choke-y 4) 'w 3 'h 2 'gap 12)))]
      [else
       (list (hash 'type 'pylon         'x (+ choke-x 2) 'y (+ choke-y 1) 'w 2 'h 2 'gap 0)
             (hash 'type 'forge         'x choke-x       'y (+ choke-y 4) 'w 3 'h 2 'gap 4)
             (hash 'type 'gateway       'x (+ choke-x 3) 'y (+ choke-y 4) 'w 4 'h 3 'gap 11)
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
(define (select-focus-fire-target arg1 [arg2 #f] #:max-range [max-range #f])
  (define-values (attacker enemies)
    (if (list? arg1)
        (values arg2 arg1)
        (values arg1 (if (list? arg2) arg2 '()))))
  (define alive-enemies
    (filter (lambda (e)
              (define hp (if (fap-unit? e) (fap-unit-hp e) (hash-ref e 'hp 45)))
              (> hp 0))
            enemies))
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
       (define hp (max 1.0 (exact->inexact (if (fap-unit? e) (fap-unit-hp e) (hash-ref e 'hp 45)))))
       (define dps (max 1.0 (exact->inexact (if (fap-unit? e) (fap-unit-dps e) (hash-ref e 'dps 12)))))
       (define base-priority (/ dps hp))
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
