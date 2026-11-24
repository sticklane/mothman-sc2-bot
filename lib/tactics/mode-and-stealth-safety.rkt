#lang racket/base

;; =============================================================================
;; `lib/tactics/mode-and-stealth-safety.rkt`
;; Layer 2c Pure Tactical Mode-Toggle & Emergency Stealth Safety Leaf
;;
;; Layer Purity: L0 (`../sc2-game-constants.rkt`) + L3 (`../engine/arbiter.rkt`).
;; Zero imports of `bot-runtime.rkt`, `sc2-protobuf-ws.rkt`,
;; `priority-macro-brain.rkt`, `econ-ledger.rkt`, or `plan/*`.
;;
;; Encapsulates:
;;   - Section 12: Terran Supply Depot raise/lower hysteresis (with urgent
;;     friendly-transit multi-tag batch lower), Siege Tank auto-unsiege,
;;     Lurker auto-unburrow, and Widow Mine burrow/unburrow (`66f` clear window
;;     + TownHall mineral-line defense guard).
;;   - Section 12a: Pre-translation Emergency Mobile Detector Intercept
;;     (`Overseer 129`, `Observer 82`, unmorph `1912 -> 3745` / `1911 -> 3739`)
;;     and Emergency Terran OC Scanner Sweep (`399`) arbitrated through
;;     `arbiter-resolve!` so the wire codec blocks competing scout MOVE `16`
;;     and MULE `171` upfront with zero retroactive `raw-cmds` filtering.
;; =============================================================================

(require racket/list
         racket/math
         racket/set
         racket/flonum
         (only-in "../sc2-game-constants.rkt"
                  SC2-BUILD-COMPLETE-PROGRESS
                  sc2-canonical-order-ability
                  sc2-order-protection-class
                  unit-role-lease?
                  unit-role-lease-expires-frame)
         (only-in "../engine/arbiter.rkt"
                  make-proposal-claim
                  make-proposal-energy
                  make-proposal
                  proposal-action
                  make-arbiter-budget-snapshot
                  make-arbiter-ledger
                  reset-arbiter-ledger!
                  arbiter-ledger?
                  arbiter-ledger-role-leases
                  arbiter-resolve!
                  arbiter-result-accepted-proposals
                  arbiter-result-override-signals))

(provide
 (struct-out mode-stealth-state)
 make-mode-stealth-state
 reset-mode-stealth-state!
 clear-mode-stealth-depot-cooldown!
 (struct-out ms-unit-info)
 (struct-out ms-directive)
 (struct-out mode-stealth-plan)
 friendly-unit-on-depot-footprint-info?
 friendly-unit-requesting-depot-transit-info?
 plan-mode-and-stealth-safety!)

;; =============================================================================
;; Frozen Cross-Lane Struct Contracts (Loop 66 Section 2.2)
;; =============================================================================

(struct mode-stealth-state
  ([last-loop #:mutable]
   depot-toggle-cooldown   ;; mutable hasheqv: tag -> ready-loop
   mode-toggle-cooldown    ;; mutable hasheqv: tag -> ready-loop
   mine-clear-since-loop   ;; mutable hasheqv: tag -> clear-start-loop
   mine-last-type          ;; mutable hasheqv: tag -> 498|500
   scan-cell-cooldown      ;; mutable hash: (list cx cy) -> ready-loop
   fallback-ledger)        ;; arbiter-ledger used when #:arbiter-ledger is #f
  #:transparent)

(define (make-mode-stealth-state)
  (mode-stealth-state
   -1
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)
   (make-hash)
   (make-arbiter-ledger)))

(define (reset-mode-stealth-state! st)
  (when (mode-stealth-state? st)
    (set-mode-stealth-state-last-loop! st -1)
    (hash-clear! (mode-stealth-state-depot-toggle-cooldown st))
    (hash-clear! (mode-stealth-state-mode-toggle-cooldown st))
    (hash-clear! (mode-stealth-state-mine-clear-since-loop st))
    (hash-clear! (mode-stealth-state-mine-last-type st))
    (hash-clear! (mode-stealth-state-scan-cell-cooldown st))
    (reset-arbiter-ledger! (mode-stealth-state-fallback-ledger st))))

(define (clear-mode-stealth-depot-cooldown! st [tag #f])
  (when (mode-stealth-state? st)
    (define ht (mode-stealth-state-depot-toggle-cooldown st))
    (cond
      [(not tag) (hash-clear! ht)]
      [(list? tag)
       (for ([t (in-list tag)])
         (hash-remove! ht t))]
      [else (hash-remove! ht tag)])))

;; Lightweight unit descriptor (ally or enemy)
(struct ms-unit-info
  (tag unit-type x y vx vy radius flying? burrowed? cloaked? detected?
   energy build-progress order-ability-id order-target-x order-target-y
   is-structure? is-worker? is-townhall? is-combat?)
  #:transparent)

;; Typed tactical mode/stealth directive translated 1:1 by wire codec:
;;   ability-id in '(556 558 390 2110 2095 2097 3745 3739 16 399)
;;   target-x/y = flonum or #f (point target for MOVE 16 / SCAN 399; #f for no-target toggles)
(struct ms-directive
  (ability-id unit-tags target-x target-y urgent? reason)
  #:transparent)

;; Pre-translation plan result so wire codec NEVER needs retroactive `(set! raw-cmds (filter-map ...))`!
(struct mode-stealth-plan
  (directives                 ;; (listof ms-directive?)
   claimed-detector-tags      ;; (seteqv of exact-integer?) -> block scout MOVE 16 upfront!
   claimed-scan-oc-tags       ;; (seteqv of exact-integer?) -> block MULE 171 upfront!
   claimed-mode-unit-tags     ;; (seteqv of exact-integer?) -> depots/tanks/lurkers/mines toggled
   uncovered-stealth-present? ;; boolean?
   arbiter-overrides)         ;; (listof override-signal?)
  #:transparent)

;; =============================================================================
;; Fast Flonum Geometry & Unit Classification Helpers
;; =============================================================================

(define-syntax-rule (to-fl x)
  (let ([v x])
    (if (flonum? v) v (exact->inexact v))))

(define (dist2d-fl ax ay bx by)
  (define dx (fl- ax bx))
  (define dy (fl- ay by))
  (flsqrt (fl+ (fl* dx dx) (fl* dy dy))))

(define (clamp-fl v lo hi)
  (flmax lo (flmin hi v)))

;; Fast-breach ground threats: Zergling(105), Baneling(9), Reaper(49), Hellion(53),
;; Hellbat(484), Adept(311), Zealot(73), DarkTemplar(76)
(define (fast-breach-type? ut)
  (or (memv ut '(105 9 49 53 484 311 73 76))
      (and (symbol? ut)
           (memq ut '(zergling baneling reaper hellion hellbat adept zealot dark-templar)))))

;; Creep Tumors (87, 137, 138) & ephemeral invulnerable shades/projectiles (801, 830, 733)
(define (non-combat-tumor-or-ephemeral? ut)
  (not (not (memv ut '(87 137 138 801 830 733)))))

;; Excluded from uncovered stealth threats: Creep Tumors (87, 137, 138) & Larva (151)
(define (stealth-ignored-type? ut)
  (not (not (memv ut '(87 137 138 151)))))

;; Ally detector unit types: Observer(82), ObserverSiege(1911), Overseer(129),
;; OverseerSiege(1912), Raven(56), MissileTurret(23), PhotonCannon(66), SporeCrawler(99)
(define (ally-detector-type? ut)
  (not (not (memv ut '(82 1911 129 1912 56 23 66 99)))))

(define (mobile-or-sieged-detector-type? ut)
  (not (not (memv ut '(129 82 1912 1911)))))

(define (active-raider-cloak-type? ut)
  (not (not (memv ut '(55 76 50)))))

(define (order-ability-transit-or-build? ab)
  (and (exact-integer? ab)
       (> ab 0)
       (not (= ab 18))
       (or (memv ab '(16 23 295 296 298 299 1183 1184 3666 3667))
           (eq? (sc2-order-protection-class (sc2-canonical-order-ability ab))
                'build-structure))))

;; =============================================================================
;; Depot Footprint & Transit Helpers (`ms-unit-info` pure analogs)
;; =============================================================================

(define (friendly-unit-on-depot-footprint-info? dx dy self-infos)
  (define fdx (to-fl dx))
  (define fdy (to-fl dy))
  (for/or ([u (in-list self-infos)])
    (and (not (ms-unit-info-is-structure? u))
         (not (ms-unit-info-flying? u))
         (fl<= (flabs (fl- (to-fl (ms-unit-info-x u)) fdx)) 1.40)
         (fl<= (flabs (fl- (to-fl (ms-unit-info-y u)) fdy)) 1.40))))

(define (friendly-unit-requesting-depot-transit-info?
         dx dy self-infos
         [builder-worker-tags (seteqv)]
         [commanded-combat-tags (seteqv)])
  (define fdx (to-fl dx))
  (define fdy (to-fl dy))
  (define (worker-active-non-hold-transit? u ux uy)
    (define ab (ms-unit-info-order-ability-id u))
    (and (order-ability-transit-or-build? ab)
         (let ([tx0 (ms-unit-info-order-target-x u)]
               [ty0 (ms-unit-info-order-target-y u)])
           (if (and (real? tx0) (real? ty0)
                    (not (and (= tx0 0.0) (= ty0 0.0))))
               (let ([tx (to-fl tx0)]
                     [ty (to-fl ty0)])
                 (or (fl> (dist2d-fl ux uy tx ty) 2.0)
                     (fl< (fl+ (fl* (fl- tx fdx) (fl- ux fdx))
                               (fl* (fl- ty fdy) (fl- uy fdy)))
                          0.0)))
               #t))))
  (for/or ([u (in-list self-infos)])
    (and (not (ms-unit-info-is-structure? u))
         (not (ms-unit-info-flying? u))
         (let* ([ux (to-fl (ms-unit-info-x u))]
                [uy (to-fl (ms-unit-info-y u))]
                [utag (ms-unit-info-tag u)]
                [ab (ms-unit-info-order-ability-id u)]
                [has-ord? (and (exact-integer? ab) (> ab 0))])
           (and (fl<= (dist2d-fl ux uy fdx fdy) 4.2)
                (or (and (fl<= (flabs (fl- ux fdx)) 1.45)
                         (fl<= (flabs (fl- uy fdy)) 1.45))
                    (and (ms-unit-info-is-worker? u)
                         (or (and (set? builder-worker-tags) (set-member? builder-worker-tags utag))
                             (and has-ord?
                                  (eq? (sc2-order-protection-class (sc2-canonical-order-ability ab))
                                       'build-structure))
                             (worker-active-non-hold-transit? u ux uy)))
                    (and (or (and (set? commanded-combat-tags) (set-member? commanded-combat-tags utag))
                             has-ord?)
                         (or (not has-ord?)
                             (not (= ab 18))))))))))

;; =============================================================================
;; Main Pre-Translation Planner (`plan-mode-and-stealth-safety!`)
;; =============================================================================

(define (plan-mode-and-stealth-safety!
         st
         #:loop cur-loop
         #:self-units self-infos                     ;; (listof ms-unit-info?)
         #:enemy-units enemy-infos                   ;; (listof ms-unit-info?)
         #:explicit-combat-tags [explicit-tags (seteqv)]
         #:explicit-scan-oc-tags [explicit-scan-ocs (seteqv)]
         #:explicit-depot-tags [explicit-depot-tags (seteqv)]
         #:role-leases [role-leases (hasheqv)]
         #:arbiter-ledger [ledger #f]
         #:depot-cooldown-ht [depot-cd-ht #f]        ;; optional shared hasheqv for legacy SC2-DEPOT-TOGGLE-COOLDOWN sync
         #:map-min-coord [map-min 2.0]
         #:map-max-coord [map-max 198.0]
         #:active-scan-pts [active-scan-pts '()]
         #:emitted-scan-pts [emitted-scan-pts '()]
         #:builder-worker-tags [builder-worker-tags (seteqv)]
         #:already-heading-pts [initial-heading-pts '()])
  (define fmin (to-fl map-min))
  (define fmax (to-fl map-max))
  (define prev-loop (mode-stealth-state-last-loop st))
  (when (and (>= prev-loop 0)
             (or (< cur-loop prev-loop)
                 (and (<= cur-loop 8) (> prev-loop 8))))
    (reset-mode-stealth-state! st)
    (when (and (hash? depot-cd-ht)
               (not (eq? depot-cd-ht (mode-stealth-state-depot-toggle-cooldown st))))
      (hash-clear! depot-cd-ht)))
  (set-mode-stealth-state-last-loop! st cur-loop)

  (define eff-depot-cd
    (if (hash? depot-cd-ht)
        depot-cd-ht
        (mode-stealth-state-depot-toggle-cooldown st)))
  (define mode-cd (mode-stealth-state-mode-toggle-cooldown st))
  (define mine-clear-since (mode-stealth-state-mine-clear-since-loop st))
  (define mine-last-type (mode-stealth-state-mine-last-type st))
  (define scan-cell-cd (mode-stealth-state-scan-cell-cooldown st))

  ;; Single-pass partition of `self-infos`
  (define self-mode-units '())
  (define self-ground-nonstruct '())
  (define workers '())
  (define townhalls '())
  (define combat-units '())
  (define ally-detectors '())
  (define mobile-or-sieged-detectors '())
  (define ready-scan-ocs '())
  (for ([u (in-list self-infos)])
    (define ut (ms-unit-info-unit-type u))
    (define complete? (fl>= (to-fl (ms-unit-info-build-progress u)) SC2-BUILD-COMPLETE-PROGRESS))
    (when (and (not (ms-unit-info-is-structure? u))
               (not (ms-unit-info-flying? u)))
      (set! self-ground-nonstruct (cons u self-ground-nonstruct)))
    (when (memv ut '(19 47 32 503 498 500))
      (set! self-mode-units (cons u self-mode-units)))
    (when (ms-unit-info-is-worker? u)
      (set! workers (cons u workers)))
    (when (ms-unit-info-is-townhall? u)
      (set! townhalls (cons u townhalls)))
    (when (ms-unit-info-is-combat? u)
      (set! combat-units (cons u combat-units)))
    (when (and complete? (ally-detector-type? ut))
      (set! ally-detectors (cons u ally-detectors))
      (when (mobile-or-sieged-detector-type? ut)
        (set! mobile-or-sieged-detectors (cons u mobile-or-sieged-detectors))))
    (when (and (= ut 132)
               complete?
               (not (ms-unit-info-flying? u))
               (fl>= (to-fl (ms-unit-info-energy u)) 50.0)
               (not (set-member? explicit-scan-ocs (ms-unit-info-tag u))))
      (set! ready-scan-ocs (cons u ready-scan-ocs))))

  ;; Single-pass partition of `enemy-infos`
  (define enemy-ground-units '())
  (define enemy-fast-breach-units '())
  (define raw-stealth-candidates '())
  (for ([e (in-list enemy-infos)])
    (define et (ms-unit-info-unit-type e))
    (when (and (not (ms-unit-info-flying? e))
               (not (non-combat-tumor-or-ephemeral? et)))
      (set! enemy-ground-units (cons e enemy-ground-units))
      (when (fast-breach-type? et)
        (set! enemy-fast-breach-units (cons e enemy-fast-breach-units))))
    (when (and (not (stealth-ignored-type? et))
               (or (and (ms-unit-info-cloaked? e) (not (ms-unit-info-detected? e)))
                   (and (ms-unit-info-burrowed? e) (not (ms-unit-info-detected? e)))))
      (set! raw-stealth-candidates (cons e raw-stealth-candidates))))

  ;; Filter stealth candidates: cloaked & undetected is always uncovered;
  ;; burrowed & undetected is uncovered unless within <= 10.5t (110.25 dist^2) of an ally detector.
  (define uncovered-stealth-enemies
    (if (null? raw-stealth-candidates)
        '()
        (filter
         (lambda (e)
           (if (and (ms-unit-info-cloaked? e) (not (ms-unit-info-detected? e)))
               #t
               (let ([ex (to-fl (ms-unit-info-x e))]
                     [ey (to-fl (ms-unit-info-y e))])
                 (not (for/or ([d (in-list ally-detectors)])
                        (define dx (fl- ex (to-fl (ms-unit-info-x d))))
                        (define dy (fl- ey (to-fl (ms-unit-info-y d))))
                        (and (fl<= (flabs dx) 10.5)
                             (fl<= (flabs dy) 10.5)
                             (fl<= (fl+ (fl* dx dx) (fl* dy dy)) 110.25)))))))
         raw-stealth-candidates)))
  (define uncovered-stealth-present? (pair? uncovered-stealth-enemies))

  ;; Early-exit fast path: zero mode-toggleable units and zero uncovered stealth!
  (if (and (null? self-mode-units) (not uncovered-stealth-present?))
      (mode-stealth-plan '() (seteqv) (seteqv) (seteqv) #f '())
      (let ()
        (define directives-rev '())
        (define mode-tags-acc (mutable-seteqv))
        (define det-tags-acc (mutable-seteqv))
        (define scan-oc-tags-acc (mutable-seteqv))

        ;; ---------------------------------------------------------------------
        ;; Section 12: Depot Hysteresis, Siege Tank Unsiege, Lurker Unburrow,
        ;;             and Widow Mine Burrow/Unburrow
        ;; ---------------------------------------------------------------------
        (define depot-lower-tags '())
        (define depot-lower-urgent? #f)
        (for ([u (in-list (reverse self-mode-units))])
          (define prog (to-fl (ms-unit-info-build-progress u)))
          (define ord-ab (ms-unit-info-order-ability-id u))
          (define idle? (or (not (exact-integer? ord-ab)) (<= ord-ab 0)))
          (when (and (fl>= prog SC2-BUILD-COMPLETE-PROGRESS) idle?)
            (define ut (ms-unit-info-unit-type u))
            (define utag (ms-unit-info-tag u))
            (define ux (to-fl (ms-unit-info-x u)))
            (define uy (to-fl (ms-unit-info-y u)))
            ;; (a) Supply Depot raised(19) / lowered(47)
            (when (and (or (= ut 19) (= ut 47))
                       (not (set-member? explicit-depot-tags utag))
                       (not (set-member? explicit-tags utag))
                       (>= cur-loop (hash-ref eff-depot-cd utag 0)))
              (define min-ground-enemy-dist
                (for/fold ([best +inf.0]) ([e (in-list enemy-ground-units)])
                  (flmin best (dist2d-fl ux uy (to-fl (ms-unit-info-x e)) (to-fl (ms-unit-info-y e))))))
              (define fast-breach-near?
                (for/or ([e (in-list enemy-fast-breach-units)])
                  (fl<= (dist2d-fl ux uy (to-fl (ms-unit-info-x e)) (to-fl (ms-unit-info-y e))) 17.0)))
              (define depot-raise-dist (if fast-breach-near? 16.0 14.0))
              (define depot-lower-clear-dist (if fast-breach-near? 17.5 15.5))
              (define friendly-on-footprint?
                (friendly-unit-on-depot-footprint-info? ux uy self-ground-nonstruct))
              (define friendly-transit?
                (friendly-unit-requesting-depot-transit-info?
                 ux uy self-ground-nonstruct builder-worker-tags explicit-tags))
              (cond
                [(and (= ut 19)
                      (fl> min-ground-enemy-dist depot-lower-clear-dist))
                 (hash-set! eff-depot-cd utag (+ cur-loop (if friendly-transit? 36 44)))
                 (set-add! mode-tags-acc utag)
                 (set! depot-lower-tags (cons utag depot-lower-tags))
                 (when friendly-transit?
                   (set! depot-lower-urgent? #t))]
                [(and (= ut 47)
                      (fl<= min-ground-enemy-dist depot-raise-dist)
                      (not friendly-on-footprint?)
                      (or (fl<= min-ground-enemy-dist 5.5) (not friendly-transit?)))
                 (hash-set! eff-depot-cd utag (+ cur-loop (if (fl<= min-ground-enemy-dist 5.5) 40 44)))
                 (set-add! mode-tags-acc utag)
                 (set! directives-rev
                       (cons (ms-directive 558 (list utag) #f #f #f 'depot-raise-enemy-near)
                             directives-rev))]))
            ;; (b) Siege Tank sieged (32 -> 390 unsiege when no enemy <= 15.5t)
            (when (and (= ut 32)
                       (not (set-member? explicit-tags utag))
                       (>= cur-loop (hash-ref mode-cd utag -1)))
              (define enemy-in-siege-range?
                (for/or ([e (in-list enemy-infos)])
                  (fl<= (dist2d-fl ux uy (to-fl (ms-unit-info-x e)) (to-fl (ms-unit-info-y e))) 15.5)))
              (unless enemy-in-siege-range?
                (hash-set! mode-cd utag (+ cur-loop 44))
                (set-add! mode-tags-acc utag)
                (set! directives-rev
                      (cons (ms-directive 390 (list utag) #f #f #f 'tank-unsiege-clear)
                            directives-rev))))
            ;; (c) Lurker burrowed (503 -> 2110 unburrow when no ground enemy <= 12.5t)
            (when (and (= ut 503)
                       (not (set-member? explicit-tags utag))
                       (>= cur-loop (hash-ref mode-cd utag -1)))
              (define ground-enemy-in-range?
                (for/or ([e (in-list enemy-ground-units)])
                  (fl<= (dist2d-fl ux uy (to-fl (ms-unit-info-x e)) (to-fl (ms-unit-info-y e))) 12.5)))
              (unless ground-enemy-in-range?
                (hash-set! mode-cd utag (+ cur-loop 44))
                (set-add! mode-tags-acc utag)
                (set! directives-rev
                      (cons (ms-directive 2110 (list utag) #f #f #f 'lurker-unburrow-clear)
                            directives-rev))))
            ;; (d) Widow Mine (498 -> 2095 burrow <= 11.0t; 500 -> 2097 unburrow > 15.5t for >= 66f & > 12.0t from TH)
            (when (or (= ut 498) (= ut 500))
              (define prev-mt (hash-ref mine-last-type utag #f))
              (hash-set! mine-last-type utag ut)
              (define min-enemy-dist
                (for/fold ([best +inf.0]) ([e (in-list enemy-infos)])
                  (flmin best (dist2d-fl ux uy (to-fl (ms-unit-info-x e)) (to-fl (ms-unit-info-y e))))))
              (when (and (= ut 500)
                         (or (fl<= min-enemy-dist 15.5)
                             (and (eqv? prev-mt 498)
                                  (not (hash-has-key? mine-clear-since utag)))))
                (hash-set! mine-clear-since utag cur-loop))
              (cond
                [(and (= ut 498)
                      (not (set-member? explicit-tags utag))
                      (>= cur-loop (hash-ref mode-cd utag -1))
                      (fl<= min-enemy-dist 11.0))
                 (hash-set! mode-cd utag (+ cur-loop 44))
                 (hash-set! mine-clear-since utag cur-loop)
                 (set-add! mode-tags-acc utag)
                 (set! directives-rev
                       (cons (ms-directive 2095 (list utag) #f #f #f 'widow-mine-burrow-enemy-near)
                             directives-rev))]
                [(and (= ut 500)
                      (not (set-member? explicit-tags utag))
                      (>= cur-loop (hash-ref mode-cd utag -1))
                      (fl> min-enemy-dist 15.5))
                 (define clear-since (hash-ref mine-clear-since utag #f))
                 (define clear-duration-ok? (or (not clear-since) (>= (- cur-loop clear-since) 66)))
                 (define defending-mineral-line?
                   (for/or ([th (in-list townhalls)])
                     (fl<= (dist2d-fl ux uy (to-fl (ms-unit-info-x th)) (to-fl (ms-unit-info-y th))) 12.0)))
                 (when (and clear-duration-ok? (not defending-mineral-line?))
                   (hash-set! mode-cd utag (+ cur-loop 44))
                   (hash-set! mine-clear-since utag cur-loop)
                   (set-add! mode-tags-acc utag)
                   (set! directives-rev
                         (cons (ms-directive 2097 (list utag) #f #f #f 'widow-mine-unburrow-clear)
                               directives-rev)))]))))

        ;; Emit batched multi-tag Supply Depot lower (`556`) once per step
        (when (pair? depot-lower-tags)
          (set! directives-rev
                (cons (ms-directive 556
                                    (reverse depot-lower-tags)
                                    #f #f
                                    depot-lower-urgent?
                                    (if depot-lower-urgent?
                                        'depot-lower-urgent-transit
                                        'depot-lower-clear))
                      directives-rev)))

        ;; ---------------------------------------------------------------------
        ;; Section 12a: Pre-Translation Emergency Detector Intercept & Terran
        ;;              OC Scanner Sweep (`399`) via `arbiter-resolve!`
        ;; ---------------------------------------------------------------------
        (define arbiter-overrides '())
        (when uncovered-stealth-present?
          (define det-proposals-rev '())
          (define scan-proposals '())
          (define pending-scan-cell-key #f)

          ;; (12a-i) Emergency Mobile Detector Intercept (`prio 960`, `'detector-escort`)
          (when (pair? mobile-or-sieged-detectors)
            (define already-heading-pts
              (for/fold ([pts initial-heading-pts]) ([d (in-list mobile-or-sieged-detectors)])
                (define dtag (ms-unit-info-tag d))
                (define ab (ms-unit-info-order-ability-id d))
                (define otx (ms-unit-info-order-target-x d))
                (define oty (ms-unit-info-order-target-y d))
                (if (and (set-member? explicit-tags dtag)
                         (eqv? ab 16)
                         (real? otx) (real? oty)
                         (not (and (= otx 0.0) (= oty 0.0))))
                    (cons (cons (to-fl otx) (to-fl oty)) pts)
                    pts)))
            (define assigned-det-tags (mutable-seteqv))
            (for ([d (in-list mobile-or-sieged-detectors)])
              (define dt (ms-unit-info-tag d))
              (when (set-member? explicit-tags dt)
                (set-add! assigned-det-tags dt)))

            (define (stealth-priority-dist se)
              (define ex (to-fl (ms-unit-info-x se)))
              (define ey (to-fl (ms-unit-info-y se)))
              (define th-d
                (for/fold ([best +inf.0]) ([th (in-list townhalls)])
                  (flmin best (dist2d-fl ex ey (to-fl (ms-unit-info-x th)) (to-fl (ms-unit-info-y th))))))
              (define army-d
                (for/fold ([best +inf.0]) ([cu (in-list combat-units)])
                  (flmin best (dist2d-fl ex ey (to-fl (ms-unit-info-x cu)) (to-fl (ms-unit-info-y cu))))))
              (define worker-d
                (for/fold ([best +inf.0]) ([w (in-list workers)])
                  (flmin best (dist2d-fl ex ey (to-fl (ms-unit-info-x w)) (to-fl (ms-unit-info-y w))))))
              (define se-ut (ms-unit-info-unit-type se))
              (define active-cloak-on-workers?
                (and (active-raider-cloak-type? se-ut)
                     (fl<= worker-d 12.0)))
              (fl- (flmin th-d (flmin army-d worker-d))
                   (cond
                     [active-cloak-on-workers? 10.0]
                     [(= se-ut 500) 4.0]
                     [else 0.0])))

            (define sorted-stealth
              (sort uncovered-stealth-enemies fl< #:key stealth-priority-dist))

            (for ([se (in-list sorted-stealth)])
              (define ex (to-fl (ms-unit-info-x se)))
              (define ey (to-fl (ms-unit-info-y se)))
              (define covered-by-heading?
                (for/or ([pt (in-list already-heading-pts)])
                  (fl<= (dist2d-fl ex ey (to-fl (car pt)) (to-fl (cdr pt))) 10.5)))
              (unless covered-by-heading?
                (define free-dets
                  (filter (lambda (d) (not (set-member? assigned-det-tags (ms-unit-info-tag d))))
                          mobile-or-sieged-detectors))
                (when (pair? free-dets)
                  (define chosen-det
                    (argmin (lambda (d)
                              (define base-d (dist2d-fl ex ey (to-fl (ms-unit-info-x d)) (to-fl (ms-unit-info-y d))))
                              (if (memv (ms-unit-info-unit-type d) '(129 82))
                                  base-d
                                  (fl+ base-d 15.0)))
                            free-dets))
                  (define dtag (ms-unit-info-tag chosen-det))
                  (define dutype (ms-unit-info-unit-type chosen-det))
                  (set-add! assigned-det-tags dtag)
                  (define-values (cand-dir dup-exec?)
                    (cond
                      [(= dutype 1912)
                       (set! already-heading-pts (cons (cons ex ey) already-heading-pts))
                       (values (ms-directive 3745 (list dtag) #f #f #t 'emergency-overseer-unmorph) #f)]
                      [(= dutype 1911)
                       (set! already-heading-pts (cons (cons ex ey) already-heading-pts))
                       (values (ms-directive 3739 (list dtag) #f #f #t 'emergency-observer-unmorph) #f)]
                      [else
                       (define cluster-members
                         (filter (lambda (o)
                                   (define ox (to-fl (ms-unit-info-x o)))
                                   (define oy (to-fl (ms-unit-info-y o)))
                                   (and (fl<= (dist2d-fl ex ey ox oy) 9.5)
                                        (not (for/or ([pt (in-list already-heading-pts)])
                                               (fl<= (dist2d-fl ox oy (to-fl (car pt)) (to-fl (cdr pt))) 10.5)))))
                                 sorted-stealth))
                       (define-values (aim-x aim-y)
                         (if (> (length cluster-members) 1)
                             (let* ([n (exact->inexact (length cluster-members))]
                                    [cx (fl/ (for/fold ([s 0.0]) ([o (in-list cluster-members)])
                                               (fl+ s (to-fl (ms-unit-info-x o))))
                                             n)]
                                    [cy (fl/ (for/fold ([s 0.0]) ([o (in-list cluster-members)])
                                               (fl+ s (to-fl (ms-unit-info-y o))))
                                             n)])
                               (if (for/and ([o (in-list cluster-members)])
                                     (fl<= (dist2d-fl cx cy (to-fl (ms-unit-info-x o)) (to-fl (ms-unit-info-y o))) 9.5))
                                   (values cx cy)
                                   (values ex ey)))
                             (values ex ey)))
                       (define near-ally
                         (for/fold ([best-u #f] [best-d 20.0] #:result best-u)
                                   ([cu (in-list combat-units)])
                           (define cd (dist2d-fl aim-x aim-y (to-fl (ms-unit-info-x cu)) (to-fl (ms-unit-info-y cu))))
                           (if (fl< cd best-d) (values cu cd) (values best-u best-d))))
                       (define-values (tx ty)
                         (if near-ally
                             (let* ([ax (to-fl (ms-unit-info-x near-ally))]
                                    [ay (to-fl (ms-unit-info-y near-ally))]
                                    [d (flmax 1.0 (dist2d-fl aim-x aim-y ax ay))]
                                    [pull (flmin 2.0 (fl* 0.4 d))]
                                    [px (clamp-fl (fl+ aim-x (fl* pull (fl/ (fl- ax aim-x) d))) fmin fmax)]
                                    [py (clamp-fl (fl+ aim-y (fl* pull (fl/ (fl- ay aim-y) d))) fmin fmax)])
                               (if (for/and ([o (in-list cluster-members)])
                                     (fl<= (dist2d-fl px py (to-fl (ms-unit-info-x o)) (to-fl (ms-unit-info-y o))) 10.0))
                                   (values px py)
                                   (values (clamp-fl aim-x fmin fmax) (clamp-fl aim-y fmin fmax))))
                             (values (clamp-fl aim-x fmin fmax) (clamp-fl aim-y fmin fmax))))
                       (set! already-heading-pts (cons (cons tx ty) already-heading-pts))
                       (define oab (ms-unit-info-order-ability-id chosen-det))
                       (define otx (ms-unit-info-order-target-x chosen-det))
                       (define oty (ms-unit-info-order-target-y chosen-det))
                       (define already-exec?
                         (and (eqv? oab 16)
                              (real? otx) (real? oty)
                              (not (and (= otx 0.0) (= oty 0.0)))
                              (fl<= (dist2d-fl (to-fl otx) (to-fl oty) tx ty) 1.5)))
                       (values (ms-directive 16 (list dtag) tx ty #t 'emergency-detector-intercept)
                               already-exec?)]))
                  (set! det-proposals-rev
                        (cons (make-proposal
                               (list 'emerg-detector-intercept dtag)
                               'mode-and-stealth-safety
                               'tactics
                               960.0
                               (list 'ms-det dtag cand-dir dup-exec?)
                               #:claim (make-proposal-claim (list dtag) #:role 'detector-escort #:lease-ttl 0)
                               #:attention-tier 0
                               #:rationale 'emergency-detector-intercept)
                              det-proposals-rev))))))

          ;; (12a-ii) Emergency Terran Orbital Command Scanner Sweep (`399`, `prio 980`, `50e`)
          (when (pair? ready-scan-ocs)
            (define sorted-ocs
              (sort ready-scan-ocs fl> #:key (lambda (u) (to-fl (ms-unit-info-energy u)))))
            (define threat-stealth
              (filter (lambda (se)
                        (define ex (to-fl (ms-unit-info-x se)))
                        (define ey (to-fl (ms-unit-info-y se)))
                        (and (for/or ([su (in-list self-infos)])
                               (fl<= (dist2d-fl ex ey (to-fl (ms-unit-info-x su)) (to-fl (ms-unit-info-y su))) 18.0))
                             (not (for/or ([pt (in-list active-scan-pts)])
                                    (fl<= (dist2d-fl ex ey (to-fl (car pt)) (to-fl (cdr pt))) 10.5)))
                             (not (for/or ([pt (in-list emitted-scan-pts)])
                                    (fl<= (dist2d-fl ex ey (to-fl (car pt)) (to-fl (cdr pt))) 10.0)))))
                      uncovered-stealth-enemies))
            (when (pair? threat-stealth)
              (define (scan-threat-weight se)
                (define se-ut (ms-unit-info-unit-type se))
                (define sx (to-fl (ms-unit-info-x se)))
                (define sy (to-fl (ms-unit-info-y se)))
                (define (near-worker?)
                  (for/or ([w (in-list workers)])
                    (fl<= (dist2d-fl sx sy (to-fl (ms-unit-info-x w)) (to-fl (ms-unit-info-y w))) 12.0)))
                (cond
                  [(and (active-raider-cloak-type? se-ut) (near-worker?)) 1.6]
                  [(= se-ut 500)
                   (if (or (near-worker?)
                           (>= (count (lambda (cu)
                                        (fl<= (dist2d-fl sx sy (to-fl (ms-unit-info-x cu)) (to-fl (ms-unit-info-y cu))) 12.0))
                                      combat-units)
                               3))
                       1.5
                       1.0)]
                  [else 1.0]))
              (define weighted-stealth
                (for/list ([se (in-list threat-stealth)])
                  (vector (to-fl (ms-unit-info-x se))
                          (to-fl (ms-unit-info-y se))
                          (scan-threat-weight se))))
              (define ref-units (if (pair? townhalls) townhalls self-infos))
              (define-values (best-cx best-cy _best-sc _best-d)
                (for/fold ([bcx 0.0] [bcy 0.0] [bsc -1.0] [bd +inf.0])
                          ([anchor (in-list weighted-stealth)])
                  (define ax (vector-ref anchor 0))
                  (define ay (vector-ref anchor 1))
                  (define raw-cl
                    (filter (lambda (v)
                              (fl<= (dist2d-fl ax ay (vector-ref v 0) (vector-ref v 1)) 11.0))
                            weighted-stealth))
                  (define wsum (for/fold ([s 0.0]) ([v (in-list raw-cl)]) (fl+ s (vector-ref v 2))))
                  (define cx (fl/ (for/fold ([s 0.0]) ([v (in-list raw-cl)])
                                    (fl+ s (fl* (vector-ref v 0) (vector-ref v 2))))
                                  (flmax 1e-6 wsum)))
                  (define cy (fl/ (for/fold ([s 0.0]) ([v (in-list raw-cl)])
                                    (fl+ s (fl* (vector-ref v 1) (vector-ref v 2))))
                                  (flmax 1e-6 wsum)))
                  (define in-cl
                    (filter (lambda (v)
                              (fl<= (dist2d-fl cx cy (vector-ref v 0) (vector-ref v 1)) 10.5))
                            raw-cl))
                  (define eff-cl (if (pair? in-cl) in-cl (list anchor)))
                  (define eff-wsum (for/fold ([s 0.0]) ([v (in-list eff-cl)]) (fl+ s (vector-ref v 2))))
                  (define ecx (fl/ (for/fold ([s 0.0]) ([v (in-list eff-cl)])
                                     (fl+ s (fl* (vector-ref v 0) (vector-ref v 2))))
                                   (flmax 1e-6 eff-wsum)))
                  (define ecy (fl/ (for/fold ([s 0.0]) ([v (in-list eff-cl)])
                                     (fl+ s (fl* (vector-ref v 1) (vector-ref v 2))))
                                   (flmax 1e-6 eff-wsum)))
                  (define near-d
                    (for/fold ([md +inf.0]) ([u (in-list ref-units)])
                      (flmin md (dist2d-fl ecx ecy (to-fl (ms-unit-info-x u)) (to-fl (ms-unit-info-y u))))))
                  (if (or (fl> eff-wsum bsc)
                          (and (fl= eff-wsum bsc) (fl< near-d bd)))
                      (values ecx ecy eff-wsum near-d)
                      (values bcx bcy bsc bd))))
              (define ex (clamp-fl best-cx fmin fmax))
              (define ey (clamp-fl best-cy fmin fmax))
              (define cell-key
                (list (quotient (inexact->exact (round ex)) 6)
                      (quotient (inexact->exact (round ey)) 6)))
              (when (>= cur-loop (hash-ref scan-cell-cd cell-key 0))
                (define chosen-oc-tag (ms-unit-info-tag (first sorted-ocs)))
                (set! pending-scan-cell-key cell-key)
                (set! scan-proposals
                      (list (make-proposal
                             (list 'emerg-scanner-sweep chosen-oc-tag)
                             'mode-and-stealth-safety
                             'tactics
                             980.0
                             (list 'ms-scan chosen-oc-tag
                                   (ms-directive 399 (list chosen-oc-tag) ex ey #t 'emergency-scanner-sweep))
                             #:claim (make-proposal-claim (list chosen-oc-tag) #:role 'detector-escort #:lease-ttl 0)
                             #:energy (make-proposal-energy chosen-oc-tag 'orbital-command 50.0)
                             #:attention-tier 0
                             #:rationale 'emergency-scanner-sweep))))))

          ;; (12a-iii) Resolve competing Scan (`980`) & Detector Intercept (`960`) via `arbiter-resolve!`
          (define all-stealth-proposals (append scan-proposals (reverse det-proposals-rev)))
          (when (pair? all-stealth-proposals)
            (define use-fallback? (not (arbiter-ledger? ledger)))
            (define eff-ledger
              (if use-fallback?
                  (mode-stealth-state-fallback-ledger st)
                  ledger))
            (when (and use-fallback? (hash? role-leases))
              (define fl-leases (arbiter-ledger-role-leases eff-ledger))
              (hash-clear! fl-leases)
              (for ([(t lease) (in-hash role-leases)]
                    #:when (and (unit-role-lease? lease)
                                (> (unit-role-lease-expires-frame lease) cur-loop)))
                (hash-set! fl-leases t lease)))
            (define oc-energy-ht
              (for/hasheqv ([oc (in-list ready-scan-ocs)])
                (values (ms-unit-info-tag oc) (to-fl (ms-unit-info-energy oc)))))
            (define budget-snap
              (make-arbiter-budget-snapshot
               #:caster-energy-by-tag oc-energy-ht))
            (define arb-res
              (arbiter-resolve! eff-ledger cur-loop budget-snap all-stealth-proposals))
            (set! arbiter-overrides (arbiter-result-override-signals arb-res))
            (for ([acc-p (in-list (arbiter-result-accepted-proposals arb-res))])
              (define payload (proposal-action acc-p))
              (when (pair? payload)
                (case (car payload)
                  [(ms-scan)
                   (define oc-tag (second payload))
                   (define sdir (third payload))
                   (when pending-scan-cell-key
                     (hash-set! scan-cell-cd pending-scan-cell-key (+ cur-loop 160)))
                   (set-add! scan-oc-tags-acc oc-tag)
                   (set! directives-rev (cons sdir directives-rev))]
                  [(ms-det)
                   (define dtag (second payload))
                   (define ddir (third payload))
                   (define dup-exec? (fourth payload))
                   (set-add! det-tags-acc dtag)
                   (unless dup-exec?
                     (set! directives-rev (cons ddir directives-rev)))])))))

        (mode-stealth-plan
         (reverse directives-rev)
         (for/seteqv ([t (in-set det-tags-acc)]) t)
         (for/seteqv ([t (in-set scan-oc-tags-acc)]) t)
         (for/seteqv ([t (in-set mode-tags-acc)]) t)
         uncovered-stealth-present?
         arbiter-overrides))))
