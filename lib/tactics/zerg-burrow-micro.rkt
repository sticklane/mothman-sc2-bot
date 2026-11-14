#lang typed/racket/base

;; =============================================================================
;; `lib/tactics/zerg-burrow-micro.rkt`
;; Zerg Burrow & Unburrow Micro Logic (Typed Racket):
;;   - Roach `TunnelingClaws` low-HP burrow regeneration & tunnel-kite escape
;;   - Infestor burrow-approach, Neural Parasite / Fungal Growth cast & retreat
;;   - Lurker burrow-range siege & unburrow repositioning helpers
;;   - Drone harass-evade burrow & safe unburrow helpers
;; =============================================================================

(require racket/list
         racket/math
         typed/racket/unsafe
         "../sc2-types.rkt"
         "../sc2-game-constants.rkt"
         "../sc2-combat-eval.rkt")

(module dyn-hash-ops racket/base
  (provide dyn-hash-ref
           dyn-hash-has-key?)
  (define (dyn-hash-ref h k default)
    (if (hash? h)
        (hash-ref h k (lambda () default))
        default))
  (define (dyn-hash-has-key? h k)
    (and (hash? h) (hash-has-key? h k))))

(unsafe-require/typed (submod "." dyn-hash-ops)
  [dyn-hash-ref (-> Any Any Any Any)]
  [dyn-hash-has-key? (-> Any Any Boolean)])

(provide
 zerg-unit-burrowed?
 execute-roach-tunneling-burrow-micro
 execute-infestor-burrow-cast-micro
 lurker-burrow-action
 drone-evade-burrow-action)

(: zerg-unit-burrowed? (-> Any Symbol Boolean))
(define (zerg-unit-burrowed? u burrowed-type)
  (define utype (dyn-hash-ref u 'type 'unknown))
  (not (not (or (eq? utype burrowed-type)
                (dyn-hash-ref u 'burrowed #f)
                (dyn-hash-ref u 'is-burrowed? #f)))))

(: nearest-enemy-and-dist (-> Flonum Flonum (Listof Any) (Values Any Flonum)))
(define (nearest-enemy-and-dist ux uy enemy-units)
  (for/fold ([best-e : Any #f]
             [best-d : Flonum 999.0])
            ([e (in-list enemy-units)]
             #:when (hash? e))
    (define ex (safe-real (dyn-hash-ref e 'x 160.0) 160.0))
    (define ey (safe-real (dyn-hash-ref e 'y 160.0) 160.0))
    (define d (dist2d ux uy ex ey))
    (if (< d best-d)
        (values e d)
        (values best-e best-d))))

;; Burrowed Roach (`TunnelingClaws`) movement & regeneration micro:
;; - When Roach HP ratio <= `SC2-ROACH-BURROW-HP-PCT-THRESH` (0.38) and Burrow is
;;   researched: burrow down (`burrow-down`) and tunnel-move toward `base-x, base-y`
;;   (`roach-tunnel-move`) if `tunneling-claws` is researched.
;; - When Burrowed Roach HP ratio >= `SC2-ROACH-UNBURROW-HP-PCT-THRESH` (0.82):
;;   unburrow (`burrow-up`) to re-engage.
(: execute-roach-tunneling-burrow-micro (-> Any (Listof (Listof Any))))
(define (execute-roach-tunneling-burrow-micro obs)
  (define sanitized-obs : Any (if (hash? obs) obs (hash)))
  (define upgrades-raw (dyn-hash-ref sanitized-obs 'researched-upgrades '()))
  (define upgrades : (Listof Any) (if (list? upgrades-raw) upgrades-raw '()))
  (define has-burrow? : Boolean
    (or (not (dyn-hash-has-key? sanitized-obs 'researched-upgrades))
        (not (not (or (memq 'burrow upgrades)
                      (memq 'tunneling-claws upgrades))))))
  (define has-tunneling? : Boolean
    (or (not (dyn-hash-has-key? sanitized-obs 'researched-upgrades))
        (not (not (memq 'tunneling-claws upgrades)))))
  (define base-x (safe-exact-int (dyn-hash-ref sanitized-obs 'base-x SC2-DEFAULT-HOME-BASE-X) 32))
  (define base-y (safe-exact-int (dyn-hash-ref sanitized-obs 'base-y SC2-DEFAULT-HOME-BASE-Y) 32))
  (define ally-raw (dyn-hash-ref sanitized-obs 'ally-units '()))
  (define enemy-raw (dyn-hash-ref sanitized-obs 'enemy-units '()))
  (define ally-units : (Listof Any) (if (list? ally-raw) ally-raw '()))
  (define enemy-units : (Listof Any) (if (list? enemy-raw) enemy-raw '()))
  (define actions : (Listof (Listof Any)) '())
  (: emit! (-> (Listof Any) Void))
  (define (emit! a) (set! actions (cons a actions)))

  (when has-burrow?
    (for ([u (in-list ally-units)]
          #:when (and (hash? u)
                      (memq (dyn-hash-ref u 'type 'unknown) '(roach roach-burrowed))))
      (define uid (dyn-hash-ref u 'id 0))
      (define burrowed? (zerg-unit-burrowed? u 'roach-burrowed))
      (define hp (max 1.0 (safe-real (dyn-hash-ref u 'hp 145.0) 145.0)))
      (define max-hp (max 1.0 (safe-real (dyn-hash-ref u 'max-hp 145.0) 145.0)))
      (define hp-pct (/ hp max-hp))
      (define ux (safe-real (dyn-hash-ref u 'x base-x) base-x))
      (define uy (safe-real (dyn-hash-ref u 'y base-y) base-y))
      (define-values (nearest-e dist-e) (nearest-enemy-and-dist ux uy enemy-units))
      (cond
        [(and (not burrowed?)
              (<= hp-pct SC2-ROACH-BURROW-HP-PCT-THRESH)
              (<= dist-e 12.0))
         (emit! (list 'burrow-down uid 'roach-regen-escape))
         (when has-tunneling?
           (define-values (kx ky)
             (if nearest-e
                 (compute-kite-vector (exact-round ux) (exact-round uy)
                                      (safe-exact-int (dyn-hash-ref nearest-e 'x 160) 160)
                                      (safe-exact-int (dyn-hash-ref nearest-e 'y 160) 160)
                                      5)
                 (values base-x base-y)))
           (emit! (list 'roach-tunnel-move uid kx ky)))]
        [(and burrowed? (< hp-pct SC2-ROACH-UNBURROW-HP-PCT-THRESH))
         (when has-tunneling?
           (define-values (kx ky)
             (if (and nearest-e (<= dist-e 10.0))
                 (compute-kite-vector (exact-round ux) (exact-round uy)
                                      (safe-exact-int (dyn-hash-ref nearest-e 'x 160) 160)
                                      (safe-exact-int (dyn-hash-ref nearest-e 'y 160) 160)
                                      5)
                 (values base-x base-y)))
           (emit! (list 'roach-tunnel-move uid kx ky)))]
        [(and burrowed? (>= hp-pct SC2-ROACH-UNBURROW-HP-PCT-THRESH))
         (emit! (list 'burrow-up uid 'roach-healed-reengage))])))
  (reverse actions))

;; Burrowed Infestor movement, cast & escape micro:
;; - Burrow-approach when within `SC2-INFESTOR-BURROW-APPROACH-RANGE` (16.0).
;; - Cast `neural-parasite` on capital targets when energy >= `SC2-INFESTOR-NEURAL-ENERGY`.
;; - Unburrow & cast `fungal-growth` within `SC2-INFESTOR-FUNGAL-CAST-RANGE` when energy >= 75.
;; - Burrow-retreat home when energy < `SC2-INFESTOR-FUNGAL-ENERGY`.
(: execute-infestor-burrow-cast-micro (-> Any (Listof (Listof Any))))
(define (execute-infestor-burrow-cast-micro obs)
  (define sanitized-obs : Any (if (hash? obs) obs (hash)))
  (define base-x (safe-exact-int (dyn-hash-ref sanitized-obs 'base-x SC2-DEFAULT-HOME-BASE-X) 32))
  (define base-y (safe-exact-int (dyn-hash-ref sanitized-obs 'base-y SC2-DEFAULT-HOME-BASE-Y) 32))
  (define ally-raw (dyn-hash-ref sanitized-obs 'ally-units '()))
  (define enemy-raw (dyn-hash-ref sanitized-obs 'enemy-units '()))
  (define ally-units : (Listof Any) (if (list? ally-raw) ally-raw '()))
  (define enemy-units : (Listof Any) (if (list? enemy-raw) enemy-raw '()))
  (define capital-syms : (Listof Symbol)
    '(thor battlecruiser siege-tank siege-tank-sieged colossus immortal archon
           carrier tempest mothership ultralisk))
  (define actions : (Listof (Listof Any)) '())
  (: emit! (-> (Listof Any) Void))
  (define (emit! a) (set! actions (cons a actions)))

  (for ([u (in-list ally-units)]
        #:when (and (hash? u)
                    (memq (dyn-hash-ref u 'type 'unknown) '(infestor infestor-burrowed))))
    (define uid (dyn-hash-ref u 'id 0))
    (define burrowed? (zerg-unit-burrowed? u 'infestor-burrowed))
    (define energy (safe-real (dyn-hash-ref u 'energy 75.0) 75.0))
    (define ux (safe-real (dyn-hash-ref u 'x base-x) base-x))
    (define uy (safe-real (dyn-hash-ref u 'y base-y) base-y))
    (define-values (nearest-e dist-e) (nearest-enemy-and-dist ux uy enemy-units))
    (when nearest-e
      (define ex (safe-exact-int (dyn-hash-ref nearest-e 'x 160) 160))
      (define ey (safe-exact-int (dyn-hash-ref nearest-e 'y 160) 160))
      (define capital-target : Any
        (findf (lambda ([e : Any])
                 (and (hash? e)
                      (memq (dyn-hash-ref e 'type 'unknown) capital-syms)
                      (<= (dist2d ux uy
                                  (safe-real (dyn-hash-ref e 'x 160.0) 160.0)
                                  (safe-real (dyn-hash-ref e 'y 160.0) 160.0))
                          (+ SC2-INFESTOR-NEURAL-CAST-RANGE 2.0))))
               enemy-units))
      (cond
        [(< energy SC2-INFESTOR-FUNGAL-ENERGY)
         (unless burrowed?
           (emit! (list 'burrow-down uid 'infestor-post-cast-hide)))
         (emit! (list 'move uid base-x base-y))]
        [(and capital-target (>= energy SC2-INFESTOR-NEURAL-ENERGY))
         (define ctag (dyn-hash-ref capital-target 'id 0))
         (define cx (safe-exact-int (dyn-hash-ref capital-target 'x ex) ex))
         (define cy (safe-exact-int (dyn-hash-ref capital-target 'y ey) ey))
         (unless burrowed?
           (emit! (list 'burrow-down uid 'infestor-stealth-neural)))
         (if (and (exact-integer? ctag) (> ctag 0))
             (emit! (list 'cast-spell uid 'neural-parasite ctag))
             (emit! (list 'cast-spell uid 'fungal-growth cx cy)))]
        [(and (<= dist-e (+ SC2-INFESTOR-FUNGAL-CAST-RANGE 0.5))
              (>= energy SC2-INFESTOR-FUNGAL-ENERGY))
         (when burrowed?
           (emit! (list 'burrow-up uid 'infestor-unburrow-for-fungal)))
         (emit! (list 'cast-spell uid 'fungal-growth ex ey))]
        [(<= dist-e SC2-INFESTOR-BURROW-APPROACH-RANGE)
         (unless burrowed?
           (emit! (list 'burrow-down uid 'infestor-stealth-approach)))
         (emit! (list 'move uid ex ey))])))
  (reverse actions))

;; Pure Lurker burrow/unburrow decision (`'burrow-down`, `'burrow-up`, or `'hold`).
(: lurker-burrow-action (-> Boolean Real Symbol))
(define (lurker-burrow-action currently-burrowed? min-ground-enemy-dist)
  (define d (safe-finite-real min-ground-enemy-dist 999.0))
  (cond
    [(and currently-burrowed? (> d 10.5)) 'burrow-up]
    [(and (not currently-burrowed?) (<= d 9.0)) 'burrow-down]
    [else 'hold]))

;; Pure Drone harass-evade burrow decision (`'burrow-down`, `'burrow-up`, or `'hold`).
(: drone-evade-burrow-action (-> Boolean Real Real Boolean Symbol))
(define (drone-evade-burrow-action currently-burrowed? hp-pct nearest-threat-dist enemy-has-detection?)
  (define pct (safe-finite-real hp-pct 1.0))
  (define d (safe-finite-real nearest-threat-dist 999.0))
  (cond
    [(and currently-burrowed? (or enemy-has-detection? (> d 10.0))) 'burrow-up]
    [(and (not currently-burrowed?) (not enemy-has-detection?) (<= pct 0.45) (<= d 6.0)) 'burrow-down]
    [else 'hold]))
