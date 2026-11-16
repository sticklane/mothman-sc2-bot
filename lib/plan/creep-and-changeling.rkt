#lang typed/racket/base

;; =============================================================================
;; `lib/plan/creep-and-changeling.rkt`
;; Multi-Highway Creep Spread, Counter-Creep Clearing, Changeling Free-Unit
;; Saturation/Body-Blocking/Shot-Baiting, and 1:1 Counter-Changeling Snipe:
;;   - 3-highway creep network (Primary, Flank A, Flank B) with Queen-local
;;     3.2-4.8 tile anchoring (`dist <= 5.0 < 6.8`), monotonically advancing
;;     angle rotation `(0, +25, -25, +50, -50, +75, -75 deg)`, and 15-angle
;;     frontier fan + 360-degree fallback ring for burrowed tumors
;;   - Detector-paired (`<= 6.0` or >= 100 energy scan) 2-4 ranged tumor clear
;;   - Unthrottled Overseer Changeling spawning (`181`), ramp `HoldPosition` (`18`)
;;     body-blocking, shot-baiting (`6.0-8.5` tiles), and expansion spotting
;;   - Zero-overkill 1-light-unit counter-Changeling ramp/defense snipe
;; =============================================================================

(require racket/list
         racket/math
         typed/racket/unsafe
         "../sc2-types.rkt"
         "../sc2-geometry.rkt"
         (except-in "../sc2-game-constants.rkt" aabb-overlaps?))

(module dyn-hash-ops racket/base
  (provide dyn-hash-ref
           dyn-hash-has-key?
           fast-units-have-any-type?
           fast-units-have-changeling?
           fast-scan-ally-ov-or-ch
           fast-units-have-dropper-or-queen?
           fast-units-have-overseer?)
  (define (dyn-hash-ref h k default)
    (if (hash? h)
        (if (procedure? default)
            (hash-ref h k (lambda () default))
            (hash-ref h k default))
        default))
  (define (dyn-hash-has-key? h k)
    (and (hash? h) (hash-has-key? h k)))
  (define (fast-units-have-any-type? units syms)
    (for/or ([u (in-list units)])
      (and (hash? u) (not (not (memq (hash-ref u 'type 'unknown) syms))))))
  (define (unit-ch? u ch-syms)
    (let ([ut (hash-ref u 'type 'unknown)])
      (or (not (not (memq ut ch-syms)))
          (and (or (not (symbol? ut)) (eq? ut 'unknown))
               (let ([tid (hash-ref u 'unit-type 0)])
                 (and (exact-integer? tid) (>= tid 12) (<= tid 17))))
          (not (not (hash-ref u 'is-changeling? #f))))))
  (define (fast-units-have-changeling? units ch-syms)
    (for/or ([u (in-list units)])
      (and (hash? u) (unit-ch? u ch-syms))))
  (define (fast-scan-ally-ov-or-ch units ch-syms)
    (define ov? #f)
    (define ch? #f)
    (let loop ([us units])
      (unless (or (null? us) (and ov? ch?))
        (define u (car us))
        (when (hash? u)
          (define ut (hash-ref u 'type 'unknown))
          (when (or (eq? ut 'overseer) (eq? ut 'overseer-siege-mode))
            (set! ov? #t))
          (when (and (not ch?) (unit-ch? u ch-syms))
            (set! ch? #t)))
        (loop (cdr us))))
    (values ov? ch?))
  (define (fast-units-have-dropper-or-queen? units queen-syms)
    (for/or ([u (in-list units)])
      (and (hash? u)
           (let ([ut (hash-ref u 'type 'unknown)])
             (or (not (not (memq ut queen-syms)))
                 (not (not (memq ut '(overlord-transport dropperlord overlord-ventral))))
                 (and (or (not (symbol? ut)) (eq? ut 'unknown) (eq? ut 'overlord))
                      (eqv? (hash-ref u 'unit-type 0) 893)))))))
  (define (fast-units-have-overseer? units)
    (for/or ([u (in-list units)])
      (and (hash? u)
           (let ([ut (hash-ref u 'type 'unknown)])
             (or (eq? ut 'overseer)
                 (eq? ut 'overseer-siege-mode)
                 (and (or (not (symbol? ut)) (eq? ut 'unknown) (eq? ut 'overlord))
                      (let ([tid (hash-ref u 'unit-type 0)])
                        (or (eqv? tid 129) (eqv? tid 1912))))))))))

(unsafe-require/typed (submod "." dyn-hash-ops)
  [dyn-hash-ref (-> Any Any Any Any)]
  [dyn-hash-has-key? (-> Any Any Boolean)]
  [fast-units-have-any-type? (-> (Listof Any) (Listof Symbol) Boolean)]
  [fast-units-have-changeling? (-> (Listof Any) (Listof Symbol) Boolean)]
  [fast-scan-ally-ov-or-ch (-> (Listof Any) (Listof Symbol) (Values Boolean Boolean))]
  [fast-units-have-dropper-or-queen? (-> (Listof Any) (Listof Symbol) Boolean)]
  [fast-units-have-overseer? (-> (Listof Any) Boolean)])

(provide
 CREEP-QUEEN-ANCHOR-DIST-MIN
 CREEP-QUEEN-ANCHOR-DIST-MAX
 CREEP-TUMOR-FRONTIER-ANGLES-DEG
 CREEP-TUMOR-FALLBACK-ANGLES-DEG
 (struct-out creep-spread-tracker)
 make-creep-spread-tracker
 compute-multi-highway-waypoints
 plan-multi-highway-creep-spread
 plan-counter-creep-clearing
 plan-changeling-free-unit-tactics
 plan-counter-changeling-defense
 plan-dropperlord-queen-creep-expedition
 plan-overseer-contaminate-disruption)

;; =============================================================================
;; Constants & Helpers
;; =============================================================================

(: CREEP-QUEEN-ANCHOR-DIST-MIN Flonum)
(define CREEP-QUEEN-ANCHOR-DIST-MIN 3.2)

(: CREEP-QUEEN-ANCHOR-DIST-MAX Flonum)
(define CREEP-QUEEN-ANCHOR-DIST-MAX 4.8)

(: CREEP-QUEEN-ROTATION-RADS (Listof Flonum))
(define CREEP-QUEEN-ROTATION-RADS
  (list 0.0
        (->float (degrees->radians 25.0))
        (->float (degrees->radians -25.0))
        (->float (degrees->radians 50.0))
        (->float (degrees->radians -50.0))
        (->float (degrees->radians 75.0))
        (->float (degrees->radians -75.0))))

(: CREEP-TUMOR-FRONTIER-ANGLES-DEG (Listof Flonum))
(define CREEP-TUMOR-FRONTIER-ANGLES-DEG
  '(0.0 15.0 -15.0 30.0 -30.0 45.0 -45.0 60.0 -60.0 75.0 -75.0 90.0 -90.0 105.0 -105.0))

(: CREEP-TUMOR-FALLBACK-ANGLES-DEG (Listof Flonum))
(define CREEP-TUMOR-FALLBACK-ANGLES-DEG
  '(120.0 -120.0 135.0 -135.0 150.0 -150.0 165.0 -165.0 180.0))

(: CREEP-TUMOR-TYPE-SYMS (Listof Symbol))
(define CREEP-TUMOR-TYPE-SYMS
  '(creep-tumor creep-tumor-burrowed creep-tumor-queen))

(: CREEP-CLEARING-RANGED-SYMS (Listof Symbol))
(define CREEP-CLEARING-RANGED-SYMS
  '(hydralisk roach queen marine marauder hellion banshee stalker adept immortal colossus))

(: CHANGELING-SHOT-BAIT-TARGETS (Listof Symbol))
(define CHANGELING-SHOT-BAIT-TARGETS
  '(siege-tank-sieged immortal stalker thor thor-ap colossus))

(: COUNTER-CHANGELING-LIGHT-SNIPERS (Listof Symbol))
(define COUNTER-CHANGELING-LIGHT-SNIPERS
  '(marine zergling queen zealot adept sentry stalker reaper hellion hydralisk))

(: COUNTER-CHANGELING-EXCLUDED-HEAVY (Listof Symbol))
(define COUNTER-CHANGELING-EXCLUDED-HEAVY
  '(siege-tank siege-tank-sieged immortal colossus thor thor-ap disruptor))

(struct creep-spread-tracker
  ([last-frame : Integer]
   [queen-attempts : (HashTable Integer Integer)]
   [tumor-attempts : (HashTable Integer Integer)])
  #:mutable #:transparent)

(: make-creep-spread-tracker (-> creep-spread-tracker))
(define (make-creep-spread-tracker)
  (creep-spread-tracker -1 (make-hasheqv) (make-hasheqv)))

(: DEFAULT-CREEP-TRACKER creep-spread-tracker)
(define DEFAULT-CREEP-TRACKER (make-creep-spread-tracker))

(: dyn-symbol (-> Any Symbol Symbol))
(define (dyn-symbol v fallback)
  (if (symbol? v) v fallback))

(: dyn-list (-> Any (Listof Any)))
(define (dyn-list v)
  (if (list? v) v '()))

(: clamp-map-coord (-> Flonum Flonum))
(define (clamp-map-coord v)
  (max SC2-MAP-PLAYABLE-MIN-COORD (min SC2-MAP-PLAYABLE-MAX-COORD v)))

(: sync-creep-tracker! (-> creep-spread-tracker Integer Void))
(define (sync-creep-tracker! tr frame)
  (when (or (< frame (creep-spread-tracker-last-frame tr))
            (and (= frame 0) (> (creep-spread-tracker-last-frame tr) 0)))
    (hash-clear! (creep-spread-tracker-queen-attempts tr))
    (hash-clear! (creep-spread-tracker-tumor-attempts tr)))
  (set-creep-spread-tracker-last-frame! tr frame))

(: point->pair (-> Any Flonum Flonum (Option (Pairof Flonum Flonum))))
(define (point->pair p fx fy)
  (cond
    [(and (pair? p) (real? (car p)) (real? (cdr p)))
     (cons (safe-real (car p) fx) (safe-real (cdr p) fy))]
    [(and (pair? p) (real? (car p)) (pair? (cdr p)) (real? (cadr p)))
     (cons (safe-real (car p) fx) (safe-real (cadr p) fy))]
    [(hash? p)
     (cons (safe-real (dyn-hash-ref p 'x fx) fx)
           (safe-real (dyn-hash-ref p 'y fy) fy))]
    [else #f]))

(: changeling-unit? (-> Any Boolean))
(define (changeling-unit? u)
  (and (hash? u)
       (let ([ut (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown)]
             [tid (safe-exact-int (dyn-hash-ref u 'unit-type 0) 0)])
         (or (not (not (memq ut SC2-CHANGELING-UNIT-SYMS)))
             (and (>= tid 12) (<= tid 17))
             (not (not (dyn-hash-ref u 'is-changeling? #f)))))))

(: units-have-any-type? (-> (Listof Any) (Listof Symbol) Boolean))
(define (units-have-any-type? units syms)
  (fast-units-have-any-type? units syms))

(: obs-has-unit-type? (-> Any Symbol (Listof Any) (Listof Symbol) Boolean))
(define (obs-has-unit-type? obs by-type-key units syms)
  (define by-type (dyn-hash-ref obs by-type-key #f))
  (if (and (hash? by-type) (> (hash-count by-type) 0))
      (for/or : Boolean ([s (in-list syms)])
        (define v (dyn-hash-ref by-type s #f))
        (or (pair? v) (and (real? v) (> v 0))))
      (units-have-any-type? units syms)))

;; =============================================================================
;; 1. Multi-Highway Creep Spread (3 Highways + Queen-Local Anchor Fix)
;; =============================================================================

;; Builds 3 distinct creep highway waypoint chains:
;;   - `'primary`: Main -> Natural -> 3rd -> Map Center -> Enemy Natural
;;   - `'flank-a`: 3rd -> 4th -> Enemy 3rd (+90 deg flank corridor)
;;   - `'flank-b`: Natural -> Counter-Corridor -> Enemy Flank (-90 deg corridor)
(: compute-multi-highway-waypoints
   (->* (Real Real Real Real Real Real Real Real Real Real)
        ((Option Real) (Option Real))
        (Listof (Pairof Symbol (Listof (Pairof Flonum Flonum))))))
(define (compute-multi-highway-waypoints
         base-x base-y nat-x nat-y third-x third-y
         enemy-x enemy-y enemy-nat-x enemy-nat-y
         [fourth-x-opt #f] [fourth-y-opt #f])
  (define bx (->float base-x))
  (define by (->float base-y))
  (define nx (->float nat-x))
  (define ny (->float nat-y))
  (define tx (->float third-x))
  (define ty (->float third-y))
  (define ex (->float enemy-x))
  (define ey (->float enemy-y))
  (define enx (->float enemy-nat-x))
  (define eny (->float enemy-nat-y))
  (define cx (* 0.5 (+ bx ex)))
  (define cy (* 0.5 (+ by ey)))
  (define vx (- ex bx))
  (define vy (- ey by))
  (define vlen (max 1.0 (dist2d 0.0 0.0 vx vy)))
  (define ux (/ vx vlen))
  (define uy (/ vy vlen))
  ;; Perpendicular flank unit vectors
  (define px (- uy))
  (define py ux)
  (define fx4 (if (real? fourth-x-opt) (->float fourth-x-opt) (clamp-map-coord (+ tx (* 18.0 px)))))
  (define fy4 (if (real? fourth-y-opt) (->float fourth-y-opt) (clamp-map-coord (+ ty (* 18.0 py)))))
  (define e3x (clamp-map-coord (+ enx (* 18.0 px))))
  (define e3y (clamp-map-coord (+ eny (* 18.0 py))))
  (define corr-bx (clamp-map-coord (+ cx (* -20.0 px))))
  (define corr-by (clamp-map-coord (+ cy (* -20.0 py))))
  (define eflank-x (clamp-map-coord (+ enx (* -18.0 px))))
  (define eflank-y (clamp-map-coord (+ eny (* -18.0 py))))
  (list
   (cons 'primary (list (cons nx ny) (cons tx ty) (cons cx cy) (cons enx eny)))
   (cons 'flank-a (list (cons tx ty) (cons fx4 fy4) (cons e3x e3y)))
   (cons 'flank-b (list (cons nx ny) (cons corr-bx corr-by) (cons eflank-x eflank-y)))))

(: point-blocked-by-pads-or-bldgs?
   (-> Flonum Flonum (Listof (Pairof Flonum Flonum)) (Listof Any) Boolean))
(define (point-blocked-by-pads-or-bldgs? tx ty pads bldgs)
  (or (< tx SC2-MAP-PLAYABLE-MIN-COORD) (> tx SC2-MAP-PLAYABLE-MAX-COORD)
      (< ty SC2-MAP-PLAYABLE-MIN-COORD) (> ty SC2-MAP-PLAYABLE-MAX-COORD)
      (for/or : Boolean ([p (in-list pads)])
        (< (max (abs (- tx (car p))) (abs (- ty (cdr p)))) 4.4))
      (for/or : Boolean ([b (in-list bldgs)])
        (and (hash? b)
             (not (memq (dyn-symbol (dyn-hash-ref b 'type 'unknown) 'unknown)
                        CREEP-TUMOR-TYPE-SYMS))
             (<= (dist2d tx ty
                         (safe-real (dyn-hash-ref b 'x -999.0) -999.0)
                         (safe-real (dyn-hash-ref b 'y -999.0) -999.0))
                 2.2)))))

(: nearest-uncrept-highway-wp
   (-> Flonum Flonum (Listof (Pairof Flonum Flonum)) (Listof Any) (Pairof Flonum Flonum)))
(define (nearest-uncrept-highway-wp ux uy wps existing-tumors)
  (define uncrept : (Option (Pairof Flonum Flonum))
    (findf (lambda ([wp : (Pairof Flonum Flonum)])
             (and (> (dist2d ux uy (car wp) (cdr wp)) 4.5)
                  (not (ormap (lambda ([t : Any])
                                (and (hash? t)
                                     (<= (dist2d (car wp) (cdr wp)
                                                 (safe-real (dyn-hash-ref t 'x -999.0) -999.0)
                                                 (safe-real (dyn-hash-ref t 'y -999.0) -999.0))
                                         6.0)))
                              existing-tumors))))
           wps))
  (or uncrept
      (findf (lambda ([wp : (Pairof Flonum Flonum)])
               (> (dist2d ux uy (car wp) (cdr wp)) 4.5))
             wps)
      (if (pair? wps) (last wps) (cons ux uy))))

(: find-rotated-creep-point
   (-> Flonum Flonum Flonum (Listof Flonum) (Listof Flonum) Integer
       (Listof Any) Any Flonum (Listof (Pairof Flonum Flonum)) (Listof Any)
       (Option (Pairof Flonum Flonum))))
(define (find-rotated-creep-point ox oy base-ang radii angles-rad att-idx
                                  existing-tumors skip-id tumor-clear pads ally-bldgs)
  (define n-ang (length angles-rad))
  (define start-idx (max 0 att-idx))
  (if (<= n-ang 0)
      #f
      (let rloop ([rs : (Listof Flonum) radii])
        (cond
          [(null? rs) #f]
          [else
           (define r (car rs))
           (define found : (Option (Pairof Flonum Flonum))
             (let aloop ([k : Exact-Nonnegative-Integer 0])
               (cond
                 [(>= k n-ang) #f]
                 [else
                  (define ang (+ base-ang (list-ref angles-rad (modulo (+ start-idx k) n-ang))))
                  (define cx (clamp-map-coord (+ ox (* r (->float (cos ang))))))
                  (define cy (clamp-map-coord (+ oy (* r (->float (sin ang))))))
                  (define ok?
                    (and (not (point-blocked-by-pads-or-bldgs? cx cy pads ally-bldgs))
                         (or (<= tumor-clear 0.0)
                             (not (ormap (lambda ([t : Any])
                                           (and (hash? t)
                                                (not (equal? (dyn-hash-ref t 'id 0) skip-id))
                                                (<= (dist2d cx cy
                                                            (safe-real (dyn-hash-ref t 'x -999.0) -999.0)
                                                            (safe-real (dyn-hash-ref t 'y -999.0) -999.0))
                                                    tumor-clear)))
                                         existing-tumors)))))
                  (if ok? (cons cx cy) (aloop (add1 k)))])))
           (or found (rloop (cdr rs)))]))))

(: CREEP-TUMOR-FRONTIER-RADS (Listof Flonum))
(define CREEP-TUMOR-FRONTIER-RADS
  (map (lambda ([d : Flonum]) (->float (degrees->radians d)))
       CREEP-TUMOR-FRONTIER-ANGLES-DEG))

(: CREEP-TUMOR-FALLBACK-RADS (Listof Flonum))
(define CREEP-TUMOR-FALLBACK-RADS
  (map (lambda ([d : Flonum]) (->float (degrees->radians d)))
       CREEP-TUMOR-FALLBACK-ANGLES-DEG))

;; Plans multi-highway creep spread for Queens (anchored `3.2-4.8` tiles directly
;; from the Queen's `(qx, qy)` with monotonic angle rotation so `dist <= 5.0 < 6.8`)
;; and mature `creep-tumor-burrowed` tumors (15-angle frontier fan + 360-deg fallback ring).
(: plan-multi-highway-creep-spread
   (->* (Any) (#:tracker (Option creep-spread-tracker)) (Listof (Listof Any))))
(define (plan-multi-highway-creep-spread obs #:tracker [opt-tr #f])
  (define sanitized-obs : Any (if (hash? obs) obs (hash)))
  (define ally-units (dyn-list (dyn-hash-ref sanitized-obs 'ally-units '())))
  (define ally-bldgs (dyn-list (dyn-hash-ref sanitized-obs 'ally-buildings '())))
  (define has-creep-source? : Boolean
    (or (obs-has-unit-type? sanitized-obs 'ally-by-type ally-units
                            '(queen creep-tumor creep-tumor-burrowed creep-tumor-queen))
        (units-have-any-type? ally-bldgs CREEP-TUMOR-TYPE-SYMS)))
  (cond
    [(not has-creep-source?) '()]
    [else
     (define tr : creep-spread-tracker (or opt-tr DEFAULT-CREEP-TRACKER))
     (define frame (safe-exact-int (dyn-hash-ref sanitized-obs 'frame 0) 0))
     (sync-creep-tracker! tr frame)

     (define base-x (safe-real (dyn-hash-ref sanitized-obs 'base-x SC2-DEFAULT-HOME-BASE-X) 32.0))
     (define base-y (safe-real (dyn-hash-ref sanitized-obs 'base-y SC2-DEFAULT-HOME-BASE-Y) 32.0))
     (define nat-x (safe-real (dyn-hash-ref sanitized-obs 'natural-x SC2-DEFAULT-NATURAL-X) 48.0))
     (define nat-y (safe-real (dyn-hash-ref sanitized-obs 'natural-y SC2-DEFAULT-NATURAL-Y) 48.0))
     (define third-x (safe-real (dyn-hash-ref sanitized-obs 'third-x SC2-DEFAULT-THIRD-X) 68.0))
     (define third-y (safe-real (dyn-hash-ref sanitized-obs 'third-y SC2-DEFAULT-THIRD-Y) 42.0))
     (define enemy-x (safe-real (dyn-hash-ref sanitized-obs 'enemy-x SC2-DEFAULT-ENEMY-BASE-X) 160.0))
     (define enemy-y (safe-real (dyn-hash-ref sanitized-obs 'enemy-y SC2-DEFAULT-ENEMY-BASE-Y) 160.0))
     (define enemy-nat-x (safe-real (dyn-hash-ref sanitized-obs 'enemy-natural-x (- enemy-x 16.0)) (- enemy-x 16.0)))
     (define enemy-nat-y (safe-real (dyn-hash-ref sanitized-obs 'enemy-natural-y (- enemy-y 16.0)) (- enemy-y 16.0)))
     (define fourth-x-opt (let ([v (dyn-hash-ref sanitized-obs 'fourth-x #f)]) (and (real? v) v)))
     (define fourth-y-opt (let ([v (dyn-hash-ref sanitized-obs 'fourth-y #f)]) (and (real? v) v)))

     (define enemy-units (dyn-list (dyn-hash-ref sanitized-obs 'enemy-units '())))

     (define pads : (Listof (Pairof Flonum Flonum))
       (append (list (cons base-x base-y) (cons nat-x nat-y) (cons third-x third-y))
               (filter-map (lambda ([p : Any]) (point->pair p third-x third-y))
                           (dyn-list (dyn-hash-ref sanitized-obs 'expansion-pads '())))))

     (define highways
       (compute-multi-highway-waypoints
        base-x base-y nat-x nat-y third-x third-y
        enemy-x enemy-y enemy-nat-x enemy-nat-y
        fourth-x-opt fourth-y-opt))
     (define nhw (length highways))

     (define existing-tumors : (Listof Any)
       (append
        (filter (lambda ([u : Any])
                  (and (hash? u)
                       (not (not (memq (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown)
                                       CREEP-TUMOR-TYPE-SYMS)))))
                ally-units)
        (filter (lambda ([u : Any])
                  (and (hash? u)
                       (not (not (memq (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown)
                                       CREEP-TUMOR-TYPE-SYMS)))))
                ally-bldgs)))

  (define actions : (Listof (Listof Any)) '())
  (: emit! (-> (Listof Any) Void))
  (define (emit! a) (set! actions (cons a actions)))

  ;; 1. Queens: cast `spawn-creep-tumor` anchored `3.2-4.8` tiles directly from `(qx, qy)`
  (define queen-tbl (creep-spread-tracker-queen-attempts tr))
  (define queens : (Listof Any)
    (filter (lambda ([u : Any])
              (and (hash? u)
                   (eq? (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown) 'queen)
                   (>= (safe-real (dyn-hash-ref u 'energy 25.0) 25.0) 25.0)
                   (not (for/or : Boolean ([e (in-list enemy-units)])
                          (and (hash? e)
                               (not (memq (dyn-symbol (dyn-hash-ref e 'type 'unknown) 'unknown)
                                          '(larva egg probe scv drone)))
                               (<= (dist2d (safe-real (dyn-hash-ref u 'x base-x) base-x)
                                           (safe-real (dyn-hash-ref u 'y base-y) base-y)
                                           (safe-real (dyn-hash-ref e 'x 9999.0) 9999.0)
                                           (safe-real (dyn-hash-ref e 'y 9999.0) 9999.0))
                                   6.5))))))
            ally-units))

  (for ([q (in-list queens)]
        [qi (in-naturals)])
    (define raw-qid (dyn-hash-ref q 'id 0))
    (define qid (safe-exact-int raw-qid 0))
    (define qx (safe-real (dyn-hash-ref q 'x base-x) base-x))
    (define qy (safe-real (dyn-hash-ref q 'y base-y) base-y))
    (define hw-entry (list-ref highways (modulo qi nhw)))
    (define wp (nearest-uncrept-highway-wp qx qy (cdr hw-entry) existing-tumors))
    (define dx (- (car wp) qx))
    (define dy (- (cdr wp) qy))
    (define base-ang (if (< (+ (* dx dx) (* dy dy)) 0.04) 0.0 (->float (atan dy dx))))
    ;; Monotonic increment every call so rotated offsets advance cleanly
    (define att-idx (hash-ref queen-tbl qid (lambda () 0)))
    (hash-set! queen-tbl qid (add1 att-idx))
    (define n-rot (length CREEP-QUEEN-ROTATION-RADS))
    (define chosen-pt : (Option (Pairof Flonum Flonum))
      (find-rotated-creep-point qx qy base-ang '(4.0 4.6 3.4) CREEP-QUEEN-ROTATION-RADS
                                att-idx existing-tumors #f 2.2 pads ally-bldgs))
    (define fallback-ang (+ base-ang (list-ref CREEP-QUEEN-ROTATION-RADS (modulo att-idx n-rot))))
    (define-values (tx ty)
      (if chosen-pt
          (values (car chosen-pt) (cdr chosen-pt))
          (values (clamp-map-coord (+ qx (* 4.0 (->float (cos fallback-ang)))))
                  (clamp-map-coord (+ qy (* 4.0 (->float (sin fallback-ang))))))))
    ;; Guarantee Queen-local anchoring distance strictly <= 4.8 (never > 6.8 walk bug!)
    (define d-qt (dist2d qx qy tx ty))
    (define-values (fx fy)
      (if (and (>= d-qt CREEP-QUEEN-ANCHOR-DIST-MIN)
               (<= d-qt CREEP-QUEEN-ANCHOR-DIST-MAX))
          (values tx ty)
          (let* ([fx-dx (- tx qx)]
                 [fx-dy (- ty qy)]
                 [fd (max 0.001 (dist2d 0.0 0.0 fx-dx fx-dy))]
                 [clamped-r (max CREEP-QUEEN-ANCHOR-DIST-MIN
                                 (min CREEP-QUEEN-ANCHOR-DIST-MAX d-qt))])
            (values (clamp-map-coord (+ qx (* clamped-r (/ fx-dx fd))))
                    (clamp-map-coord (+ qy (* clamped-r (/ fx-dy fd))))))))
    (emit! (list 'cast-spell raw-qid 'spawn-creep-tumor fx fy)))

  ;; 2. Active `creep-tumor-burrowed` (and mature tumors): 15-angle frontier fan + 360-deg fallback ring
  (define tumor-tbl (creep-spread-tracker-tumor-attempts tr))
  (define active-tumors : (Listof Any)
    (filter (lambda ([t : Any])
              (and (hash? t)
                   (not (not (memq (dyn-symbol (dyn-hash-ref t 'type 'unknown) 'unknown)
                                   CREEP-TUMOR-TYPE-SYMS)))
                   (>= (safe-real (dyn-hash-ref t 'build-progress 1.0) 1.0)
                       SC2-BUILD-COMPLETE-PROGRESS)
                   (not (dyn-hash-ref t 'used? #f))
                   (>= frame (safe-exact-int (dyn-hash-ref t 'ready-frame frame) frame))))
            existing-tumors))

  (for ([t (in-list active-tumors)]
        [ti (in-naturals)])
    (define raw-tid (dyn-hash-ref t 'id 0))
    (define tid (safe-exact-int raw-tid 0))
    (define tx (safe-real (dyn-hash-ref t 'x base-x) base-x))
    (define ty (safe-real (dyn-hash-ref t 'y base-y) base-y))
    (define hw-entry (list-ref highways (modulo ti nhw)))
    (define wp (nearest-uncrept-highway-wp tx ty (cdr hw-entry) existing-tumors))
    (define dx (- (car wp) tx))
    (define dy (- (cdr wp) ty))
    (define base-ang (if (< (+ (* dx dx) (* dy dy)) 0.04) 0.0 (->float (atan dy dx))))
    (define att-idx (hash-ref tumor-tbl tid (lambda () 0)))
    (hash-set! tumor-tbl tid (add1 att-idx))
    (define frontier-pt : (Option (Pairof Flonum Flonum))
      (find-rotated-creep-point tx ty base-ang '(8.8 7.5 6.2) CREEP-TUMOR-FRONTIER-RADS
                                att-idx existing-tumors raw-tid 3.5 pads ally-bldgs))
    (define ring-pt : (Option (Pairof Flonum Flonum))
      (or frontier-pt
          (find-rotated-creep-point tx ty base-ang '(8.5 7.0 5.5) CREEP-TUMOR-FALLBACK-RADS
                                    0 existing-tumors raw-tid 0.0 pads ally-bldgs)))
    (when ring-pt
      (emit! (list 'cast-spell raw-tid 'spread-creep-tumor (car ring-pt) (cdr ring-pt)))))

  (reverse actions)]))

;; =============================================================================
;; 2. Active Enemy Creep Clearing (Detector + 2-4 Ranged Focus Fire)
;; =============================================================================

;; Pairs mobile detection (`<= 6.0` tiles, or `orbital-command` `scanner-sweep`
;; when energy `>= 100`) with 2-4 ranged attackers to clear enemy Creep Tumors
;; before main forces advance onto enemy creep.
(: plan-counter-creep-clearing (-> Any (Listof (Listof Any))))
(define (plan-counter-creep-clearing obs)
  (define sanitized-obs : Any (if (hash? obs) obs (hash)))
  (define enemy-units (dyn-list (dyn-hash-ref sanitized-obs 'enemy-units '())))
  (define enemy-bldgs (dyn-list (dyn-hash-ref sanitized-obs 'enemy-buildings '())))
  (define explicit-tumors (dyn-list (dyn-hash-ref sanitized-obs 'enemy-tumors '())))
  (define has-enemy-tumors? : Boolean
    (or (pair? explicit-tumors)
        (obs-has-unit-type? sanitized-obs 'enemy-by-type enemy-units CREEP-TUMOR-TYPE-SYMS)
        (units-have-any-type? enemy-bldgs CREEP-TUMOR-TYPE-SYMS)))
  (define enemy-tumors : (Listof Any)
    (if has-enemy-tumors?
        (append
         (filter (lambda ([t : Any])
                   (and (hash? t)
                        (not (not (memq (dyn-symbol (dyn-hash-ref t 'type 'unknown) 'unknown)
                                        CREEP-TUMOR-TYPE-SYMS)))))
                 explicit-tumors)
         (filter (lambda ([t : Any])
                   (and (hash? t)
                        (not (not (memq (dyn-symbol (dyn-hash-ref t 'type 'unknown) 'unknown)
                                        CREEP-TUMOR-TYPE-SYMS)))))
                 enemy-units)
         (filter (lambda ([t : Any])
                   (and (hash? t)
                        (not (not (memq (dyn-symbol (dyn-hash-ref t 'type 'unknown) 'unknown)
                                        CREEP-TUMOR-TYPE-SYMS)))))
                 enemy-bldgs))
        '()))

  (cond
    [(null? enemy-tumors) '()]
    [else
     (define base-x (safe-real (dyn-hash-ref sanitized-obs 'base-x SC2-DEFAULT-HOME-BASE-X) 32.0))
     (define base-y (safe-real (dyn-hash-ref sanitized-obs 'base-y SC2-DEFAULT-HOME-BASE-Y) 32.0))
     (define ally-units (dyn-list (dyn-hash-ref sanitized-obs 'ally-units '())))
     (define ally-bldgs (dyn-list (dyn-hash-ref sanitized-obs 'ally-buildings '())))
     (define mobile-dets : (Listof Any)
       (filter (lambda ([u : Any])
                 (and (hash? u)
                      (not (not (memq (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown)
                                      SC2-MOBILE-DETECTOR-SYMS)))))
               ally-units))
     (define ranged-pool : (Listof Any)
       (filter (lambda ([u : Any])
                 (and (hash? u)
                      (not (not (memq (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown)
                                      CREEP-CLEARING-RANGED-SYMS)))
                      (not (dyn-hash-ref u 'is-hallucination #f))))
               ally-units))
     (define sorted-tumors : (Listof Any)
       (sort enemy-tumors
             (lambda ([a : Any] [b : Any])
               (< (dist2d base-x base-y
                          (safe-real (dyn-hash-ref a 'x 9999.0) 9999.0)
                          (safe-real (dyn-hash-ref a 'y 9999.0) 9999.0))
                  (dist2d base-x base-y
                          (safe-real (dyn-hash-ref b 'x 9999.0) 9999.0)
                          (safe-real (dyn-hash-ref b 'y 9999.0) 9999.0))))))
     (define used-units : (HashTable Any Boolean) (make-hasheq))
     (define used-oc : (HashTable Any Boolean) (make-hasheq))
     (define actions : (Listof (Listof Any)) '())
     (: emit! (-> (Listof Any) Void))
     (define (emit! a) (set! actions (cons a actions)))

     (for ([tumor (in-list (take sorted-tumors (min 3 (length sorted-tumors))))])
       (define raw-tid (dyn-hash-ref tumor 'id 0))
       (define tx (safe-real (dyn-hash-ref tumor 'x base-x) base-x))
       (define ty (safe-real (dyn-hash-ref tumor 'y base-y) base-y))
       (define det-already-near? : Boolean
         (for/or : Boolean ([d (in-list mobile-dets)])
           (<= (dist2d tx ty
                       (safe-real (dyn-hash-ref d 'x 9999.0) 9999.0)
                       (safe-real (dyn-hash-ref d 'y 9999.0) 9999.0))
               6.0)))
       (define det-moved? : Boolean det-already-near?)
       (unless det-already-near?
         (define free-dets : (Listof Any)
           (filter (lambda ([d : Any]) (not (hash-ref used-units (dyn-hash-ref d 'id 0) #f)))
                   mobile-dets))
         (unless (null? free-dets)
           (define best-det
             (argmin (lambda ([d : Any])
                       (dist2d tx ty
                               (safe-real (dyn-hash-ref d 'x base-x) base-x)
                               (safe-real (dyn-hash-ref d 'y base-y) base-y)))
                     free-dets))
           (define did (dyn-hash-ref best-det 'id 0))
           (hash-set! used-units did #t)
           (set! det-moved? #t)
           (emit! (list 'move did tx ty))))
       (when (not det-moved?)
         (define-values (best-oc _best-en)
           (for/fold ([best : Any #f] [best-en : Flonum 99.9])
                     ([b (in-list ally-bldgs)]
                      #:when (and (hash? b)
                                  (eq? (dyn-symbol (dyn-hash-ref b 'type 'unknown) 'unknown)
                                       'orbital-command)
                                  (not (hash-ref used-oc (dyn-hash-ref b 'id 0) #f))
                                  (>= (safe-real (dyn-hash-ref b 'build-progress 1.0) 1.0)
                                      SC2-BUILD-COMPLETE-PROGRESS)))
             (define en (safe-real (dyn-hash-ref b 'energy 0.0) 0.0))
             (if (> en best-en) (values b en) (values best best-en))))
         (when (hash? best-oc)
           (define ocid (dyn-hash-ref best-oc 'id 0))
           (hash-set! used-oc ocid #t)
           (emit! (list 'cast-spell ocid 'scanner-sweep tx ty))))
       ;; Assign 2-4 ranged attackers to clear tumor
       (define avail-ranged : (Listof Any)
         (sort (filter (lambda ([u : Any]) (not (hash-ref used-units (dyn-hash-ref u 'id 0) #f)))
                       ranged-pool)
               (lambda ([a : Any] [b : Any])
                 (< (dist2d tx ty
                            (safe-real (dyn-hash-ref a 'x base-x) base-x)
                            (safe-real (dyn-hash-ref a 'y base-y) base-y))
                    (dist2d tx ty
                            (safe-real (dyn-hash-ref b 'x base-x) base-x)
                            (safe-real (dyn-hash-ref b 'y base-y) base-y))))))
       (define squad (take avail-ranged (min 4 (length avail-ranged))))
       (when (>= (length squad) 1)
         (for ([u (in-list squad)])
           (define uid (dyn-hash-ref u 'id 0))
           (hash-set! used-units uid #t)
           (if (and (exact-integer? raw-tid) (> raw-tid 0))
               (emit! (list 'attack uid raw-tid))
               (emit! (list 'attack-pos uid tx ty))))))
     (reverse actions)]))

;; =============================================================================
;; 3. Changeling Free-Unit Tactics (Unthrottled Spawn + Body-Block + Shot-Bait)
;; =============================================================================

;; Unthrottled Overseer Changeling spawning (every Overseer with energy >= 50 casts
;; `spawn-changeling` `181` with zero global cooldown), plus active Changeling
;; assignment: `'ramp-body-block` (`hold-position` `18` within `<= 1.2` tiles of
;; enemy ramp choke), `'shot-bait-distractor` (`6.0-8.5` tiles in front of heavy
;; enemy siege/capital units), and `'expansion-spotter`.
(: plan-changeling-free-unit-tactics (-> Any (Listof (Listof Any))))
(define (plan-changeling-free-unit-tactics obs)
  (define sanitized-obs : Any (if (hash? obs) obs (hash)))
  (define ally-units (dyn-list (dyn-hash-ref sanitized-obs 'ally-units '())))
  (define by-type (dyn-hash-ref sanitized-obs 'ally-by-type #f))
  (define-values (has-ov? has-ch?)
    (if (and (hash? by-type) (> (hash-count by-type) 0))
        (values (obs-has-unit-type? sanitized-obs 'ally-by-type ally-units
                                    '(overseer overseer-siege-mode))
                (obs-has-unit-type? sanitized-obs 'ally-by-type ally-units
                                    SC2-CHANGELING-UNIT-SYMS))
        (fast-scan-ally-ov-or-ch ally-units SC2-CHANGELING-UNIT-SYMS)))
  (cond
    [(and (not has-ov?) (not has-ch?)) '()]
    [else
     (define base-x (safe-real (dyn-hash-ref sanitized-obs 'base-x SC2-DEFAULT-HOME-BASE-X) 32.0))
     (define base-y (safe-real (dyn-hash-ref sanitized-obs 'base-y SC2-DEFAULT-HOME-BASE-Y) 32.0))
     (define enemy-x (safe-real (dyn-hash-ref sanitized-obs 'enemy-x SC2-DEFAULT-ENEMY-BASE-X) 160.0))
     (define enemy-y (safe-real (dyn-hash-ref sanitized-obs 'enemy-y SC2-DEFAULT-ENEMY-BASE-Y) 160.0))
     (define enemy-nat-x (safe-real (dyn-hash-ref sanitized-obs 'enemy-natural-x (- enemy-x 16.0)) (- enemy-x 16.0)))
     (define enemy-nat-y (safe-real (dyn-hash-ref sanitized-obs 'enemy-natural-y (- enemy-y 16.0)) (- enemy-y 16.0)))
     (define enemy-units (if has-ch? (dyn-list (dyn-hash-ref sanitized-obs 'enemy-units '())) '()))

     (define actions : (Listof (Listof Any)) '())
     (: emit! (-> (Listof Any) Void))
     (define (emit! a) (set! actions (cons a actions)))

     ;; 1. Zero global multi-Overseer throttle: EVERY Overseer >= 50 energy spawns Changeling
     (when has-ov?
       (for ([u (in-list ally-units)]
             #:when (and (hash? u)
                         (memq (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown)
                               '(overseer overseer-siege-mode))
                         (>= (safe-real (dyn-hash-ref u 'energy 0.0) 0.0) 50.0)))
         (emit! (list 'cast-spell (dyn-hash-ref u 'id 0) 'spawn-changeling))))

     ;; 2. Assign active Changelings (`12..17`) across body-block, shot-bait & spotter roles
     (define changelings : (Listof Any)
       (if has-ch? (filter changeling-unit? ally-units) '()))
  (unless (null? changelings)
    (define enemy-chokes : (Listof (Pairof Flonum Flonum))
      (let ([raw-chokes (dyn-list (dyn-hash-ref sanitized-obs 'enemy-chokes '()))]
            [eramp (point->pair (dyn-hash-ref sanitized-obs 'enemy-ramp #f)
                                (* 0.5 (+ enemy-x enemy-nat-x))
                                (* 0.5 (+ enemy-y enemy-nat-y)))])
        (define parsed (filter-map (lambda ([c : Any]) (point->pair c enemy-x enemy-y)) raw-chokes))
        (cond
          [(not (null? parsed)) parsed]
          [eramp (list eramp (cons enemy-nat-x enemy-nat-y))]
          [else (list (cons (* 0.5 (+ enemy-x enemy-nat-x))
                            (* 0.5 (+ enemy-y enemy-nat-y))))])))
    (define heavy-enemies : (Listof Any)
      (filter (lambda ([e : Any])
                (and (hash? e)
                     (not (not (memq (dyn-symbol (dyn-hash-ref e 'type 'unknown) 'unknown)
                                     CHANGELING-SHOT-BAIT-TARGETS)))))
              enemy-units))
    (define exp-spots : (Listof (Pairof Flonum Flonum))
      (let ([raw-exps (filter-map (lambda ([p : Any]) (point->pair p enemy-nat-x enemy-nat-y))
                                  (dyn-list (dyn-hash-ref sanitized-obs 'expansion-pads '())))])
        (append (list (cons enemy-nat-x enemy-nat-y))
                (filter (lambda ([pt : (Pairof Flonum Flonum)])
                          (< (dist2d (car pt) (cdr pt) enemy-x enemy-y)
                             (dist2d (car pt) (cdr pt) base-x base-y)))
                        raw-exps))))

    (define n-chokes (length enemy-chokes))
    (define n-heavy (length heavy-enemies))
    (define n-spots (max 1 (length exp-spots)))
    (for ([c (in-list changelings)]
          [ci (in-naturals)])
      (define cid (dyn-hash-ref c 'id 0))
      (define cx (safe-real (dyn-hash-ref c 'x base-x) base-x))
      (define cy (safe-real (dyn-hash-ref c 'y base-y) base-y))
      (cond
        [(< ci n-chokes)
         ;; `'ramp-body-block`
         (define choke-pt (list-ref enemy-chokes ci))
         (define kx (car choke-pt))
         (define ky (cdr choke-pt))
         (if (<= (dist2d cx cy kx ky) 1.2)
             (emit! (list 'hold-position cid))
             (emit! (list 'move cid kx ky)))]
        [(< (- ci n-chokes) n-heavy)
         ;; `'shot-bait-distractor` (`6.0-8.5` tiles in front of heavy enemy unit)
         (define he (list-ref heavy-enemies (- ci n-chokes)))
         (define hx (safe-real (dyn-hash-ref he 'x enemy-x) enemy-x))
         (define hy (safe-real (dyn-hash-ref he 'y enemy-y) enemy-y))
         (define vx (- cx hx))
         (define vy (- cy hy))
         (define d (dist2d 0.0 0.0 vx vy))
         (define-values (ux uy)
           (if (> d 0.1)
               (values (/ vx d) (/ vy d))
               (let* ([bx (- base-x hx)]
                      [by (- base-y hy)]
                      [bl (max 1.0 (dist2d 0.0 0.0 bx by))])
                 (values (/ bx bl) (/ by bl)))))
         (define bait-x (clamp-map-coord (+ hx (* 7.2 ux))))
         (define bait-y (clamp-map-coord (+ hy (* 7.2 uy))))
         (emit! (list 'move cid bait-x bait-y))]
        [else
         ;; `'expansion-spotter`
         (define spot (list-ref exp-spots (modulo (- ci n-chokes n-heavy) n-spots)))
         (emit! (list 'move cid (car spot) (cdr spot)))])))

  (reverse actions)]))

;; =============================================================================
;; 4. Counter-Changeling Zero-Overkill 1:1 Snipe
;; =============================================================================

;; Assigns strictly AT MOST 1 fast light unit (`marine`, `zergling`, `queen`,
;; `zealot`, `adept`, `sentry`, `stalker`, or 1 worker fallback if 0 army) per
;; enemy Changeling — explicitly excluding SiegeTank/Immortal/Colossus/Thor/Disruptor
;; — and prioritizes Changelings within 5.0 tiles of our ramp/choke first.
(: plan-counter-changeling-defense (-> Any (Listof (Listof Any))))
(define (plan-counter-changeling-defense obs)
  (define sanitized-obs : Any (if (hash? obs) obs (hash)))
  (define enemy-units (dyn-list (dyn-hash-ref sanitized-obs 'enemy-units '())))
  (define e-by-type (dyn-hash-ref sanitized-obs 'enemy-by-type #f))
  (define has-enemy-ch? : Boolean
    (if (and (hash? e-by-type) (> (hash-count e-by-type) 0))
        (obs-has-unit-type? sanitized-obs 'enemy-by-type enemy-units SC2-CHANGELING-UNIT-SYMS)
        (fast-units-have-changeling? enemy-units SC2-CHANGELING-UNIT-SYMS)))
  (define enemy-changelings : (Listof Any)
    (if has-enemy-ch? (filter changeling-unit? enemy-units) '()))

  (cond
    [(null? enemy-changelings) '()]
    [else
     (define base-x (safe-real (dyn-hash-ref sanitized-obs 'base-x SC2-DEFAULT-HOME-BASE-X) 32.0))
     (define base-y (safe-real (dyn-hash-ref sanitized-obs 'base-y SC2-DEFAULT-HOME-BASE-Y) 32.0))
     (define nat-x (safe-real (dyn-hash-ref sanitized-obs 'natural-x SC2-DEFAULT-NATURAL-X) 48.0))
     (define nat-y (safe-real (dyn-hash-ref sanitized-obs 'natural-y SC2-DEFAULT-NATURAL-Y) 48.0))
     (define ramp-pt : (Pairof Flonum Flonum)
       (or (point->pair (or (dyn-hash-ref sanitized-obs 'wall-door #f)
                            (dyn-hash-ref sanitized-obs 'our-ramp #f)
                            (dyn-hash-ref sanitized-obs 'ramp #f))
                        (* 0.5 (+ base-x nat-x))
                        (* 0.5 (+ base-y nat-y)))
           (cons (safe-real (dyn-hash-ref sanitized-obs 'door-x (* 0.5 (+ base-x nat-x)))
                            (* 0.5 (+ base-x nat-x)))
                 (safe-real (dyn-hash-ref sanitized-obs 'door-y (* 0.5 (+ base-y nat-y)))
                            (* 0.5 (+ base-y nat-y))))))
     (define rx (car ramp-pt))
     (define ry (cdr ramp-pt))
     (define ally-units (dyn-list (dyn-hash-ref sanitized-obs 'ally-units '())))
     (define sorted-changelings : (Listof Any)
       (sort enemy-changelings
             (lambda ([a : Any] [b : Any])
               (define da (dist2d rx ry
                                  (safe-real (dyn-hash-ref a 'x 9999.0) 9999.0)
                                  (safe-real (dyn-hash-ref a 'y 9999.0) 9999.0)))
               (define db (dist2d rx ry
                                  (safe-real (dyn-hash-ref b 'x 9999.0) 9999.0)
                                  (safe-real (dyn-hash-ref b 'y 9999.0) 9999.0)))
               (define a-ramp? (<= da 5.0))
               (define b-ramp? (<= db 5.0))
               (cond
                 [(and a-ramp? (not b-ramp?)) #t]
                 [(and (not a-ramp?) b-ramp?) #f]
                 [else (< da db)]))))
     (define fast-light-snipers : (Listof Any)
       (filter (lambda ([u : Any])
                 (and (hash? u)
                      (let ([ut (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown)])
                        (and (not (memq ut COUNTER-CHANGELING-EXCLUDED-HEAVY))
                             (not (not (memq ut COUNTER-CHANGELING-LIGHT-SNIPERS)))
                             (not (dyn-hash-ref u 'is-hallucination #f))))))
               ally-units))
     (define workers : (Listof Any)
       (filter (lambda ([u : Any])
                 (and (hash? u)
                      (not (not (memq (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown)
                                      '(scv probe drone))))))
               ally-units))
     (define sniper-pool : (Listof Any)
       (if (not (null? fast-light-snipers)) fast-light-snipers workers))
     (define used-snipers : (HashTable Any Boolean) (make-hasheq))
     (define actions : (Listof (Listof Any)) '())
     (for ([ch (in-list sorted-changelings)])
       (define ch-id (dyn-hash-ref ch 'id 0))
       (define cx (safe-real (dyn-hash-ref ch 'x rx) rx))
       (define cy (safe-real (dyn-hash-ref ch 'y ry) ry))
       (define avail : (Listof Any)
         (filter (lambda ([s : Any]) (not (hash-ref used-snipers (dyn-hash-ref s 'id 0) #f)))
                 sniper-pool))
       (unless (null? avail)
         (define best-sniper
           (argmin (lambda ([s : Any])
                     (dist2d cx cy
                             (safe-real (dyn-hash-ref s 'x base-x) base-x)
                             (safe-real (dyn-hash-ref s 'y base-y) base-y)))
                   avail))
         (define sid (dyn-hash-ref best-sniper 'id 0))
         (hash-set! used-snipers sid #t)
         (set! actions (cons (list 'attack sid ch-id) actions))))
     (reverse actions)]))

;; =============================================================================
;; 5. Dropperlord + Queen Creep Expeditions & Symmetric Counter
;; =============================================================================

(: EXPEDITION-AA-ATTACKER-SYMS (Listof Symbol))
(define EXPEDITION-AA-ATTACKER-SYMS
  '(marine stalker hydralisk queen cyclone viking-fighter corruptor phoenix mutalisk
    thor thor-ap ghost high-templar void-ray sentry))

(: EXPEDITION-TOWNHALL-SYMS (Listof Symbol))
(define EXPEDITION-TOWNHALL-SYMS
  '(hatchery lair hive nexus command-center orbital-command planetary-fortress))

(: dropperlord-unit? (-> Any Boolean))
(define (dropperlord-unit? u)
  (and (hash? u)
       (or (not (not (memq (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown)
                           '(overlord-transport dropperlord overlord-ventral))))
           (= (safe-exact-int (dyn-hash-ref u 'unit-type 0) 0) 893))))

(: tumor-or-townhall-within? (-> Flonum Flonum Flonum (Listof Any) (Listof Any) Boolean))
(define (tumor-or-townhall-within? tx ty radius units bldgs)
  (or (for/or : Boolean ([u (in-list units)])
        (and (hash? u)
             (let ([ut (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown)])
               (or (not (not (memq ut CREEP-TUMOR-TYPE-SYMS)))
                   (not (not (memq ut EXPEDITION-TOWNHALL-SYMS)))))
             (<= (dist2d tx ty
                         (safe-real (dyn-hash-ref u 'x -999.0) -999.0)
                         (safe-real (dyn-hash-ref u 'y -999.0) -999.0))
                 radius)))
      (for/or : Boolean ([u (in-list bldgs)])
        (and (hash? u)
             (let ([ut (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown)])
               (or (not (not (memq ut CREEP-TUMOR-TYPE-SYMS)))
                   (not (not (memq ut EXPEDITION-TOWNHALL-SYMS)))))
             (<= (dist2d tx ty
                         (safe-real (dyn-hash-ref u 'x -999.0) -999.0)
                         (safe-real (dyn-hash-ref u 'y -999.0) -999.0))
                 radius)))))

(: point-has-aa-danger? (-> Flonum Flonum (Listof Any) Boolean))
(define (point-has-aa-danger? tx ty enemy-units)
  (define aa-cnt : Integer
    (for/fold ([cnt : Integer 0]) ([e (in-list enemy-units)])
      (if (and (hash? e)
               (memq (dyn-symbol (dyn-hash-ref e 'type 'unknown) 'unknown)
                     EXPEDITION-AA-ATTACKER-SYMS)
               (<= (dist2d tx ty
                           (safe-real (dyn-hash-ref e 'x 9999.0) 9999.0)
                           (safe-real (dyn-hash-ref e 'y 9999.0) 9999.0))
                   10.0))
          (add1 cnt)
          cnt)))
  (>= aa-cnt 2))

(: collect-expedition-creep-targets
   (-> Any Flonum Flonum Flonum Flonum Flonum Flonum Flonum Flonum
       (Listof Any) (Listof Any) (Listof Any) (Listof (Pairof Flonum Flonum))))
(define (collect-expedition-creep-targets
         sanitized-obs base-x base-y nat-x nat-y third-x third-y enemy-x enemy-y
         ally-units ally-bldgs enemy-units)
  (define exp-pads : (Listof (Pairof Flonum Flonum))
    (filter-map (lambda ([p : Any]) (point->pair p third-x third-y))
                (dyn-list (dyn-hash-ref sanitized-obs 'expansion-pads '()))))
  (define far-pads : (Listof (Pairof Flonum Flonum))
    (sort (filter (lambda ([pt : (Pairof Flonum Flonum)])
                    (define px (car pt))
                    (define py (cdr pt))
                    (and (> (dist2d px py base-x base-y) 24.0)
                         (> (dist2d px py nat-x nat-y) 16.0)
                         (> (dist2d px py enemy-x enemy-y) 18.0)))
                  exp-pads)
          (lambda ([a : (Pairof Flonum Flonum)] [b : (Pairof Flonum Flonum)])
            (< (dist2d (car a) (cdr a) base-x base-y)
               (dist2d (car b) (cdr b) base-x base-y)))))
  (define hw-anchors : (Listof (Pairof Flonum Flonum))
    (let ([hws (compute-multi-highway-waypoints
                base-x base-y nat-x nat-y third-x third-y
                enemy-x enemy-y (- enemy-x 16.0) (- enemy-y 16.0))])
      (append
       (let ([fa (assq 'flank-a hws)]) (if (and fa (>= (length (cdr fa)) 2)) (list (cadr fa)) '()))
       (let ([fb (assq 'flank-b hws)]) (if (and fb (>= (length (cdr fb)) 2)) (list (cadr fb)) '())))))
  (define combined (append far-pads hw-anchors))
  (filter (lambda ([pt : (Pairof Flonum Flonum)])
            (and (not (tumor-or-townhall-within? (car pt) (cdr pt) 8.5 ally-units ally-bldgs))
                 (not (point-has-aa-danger? (car pt) (cdr pt) enemy-units))))
          combined))

;; Dropperlord (`893`) + Creep Queen (`energy >= 25`) expedition planner:
;;   1. Offense: pairs an `overlord-transport` (`893`) with a ready Creep Queen (`energy >= 25`)
;;      to ferry her to uncrept 4th/5th expansion pads or flank highway anchors, unload via
;;      `transport-juggle`, toggle `overlord-generate-creep` (`1882`), and immediately cast
;;      `(cast-spell qid 'spawn-creep-tumor tx ty)` (`1694`).
;;   2. Symmetric counter: intercepts enemy Dropperlords (`overlord-transport`) and snipes
;;      remote Creep Queens operating > 14.0 tiles outside enemy bases.
(: plan-dropperlord-queen-creep-expedition
   (->* (Any) (#:tracker (Option creep-spread-tracker)) (Listof (Listof Any))))
(define (plan-dropperlord-queen-creep-expedition obs #:tracker [opt-tr #f])
  (define sanitized-obs : Any (if (hash? obs) obs (hash)))
  (define ally-units (dyn-list (dyn-hash-ref sanitized-obs 'ally-units '())))
  (define enemy-units (dyn-list (dyn-hash-ref sanitized-obs 'enemy-units '())))
  (define a-by-type (dyn-hash-ref sanitized-obs 'ally-by-type #f))
  (define e-by-type (dyn-hash-ref sanitized-obs 'enemy-by-type #f))
  (define has-ally-exp? : Boolean
    (if (and (hash? a-by-type) (> (hash-count a-by-type) 0))
        (obs-has-unit-type? sanitized-obs 'ally-by-type ally-units
                            '(overlord-transport dropperlord overlord-ventral queen))
        (fast-units-have-dropper-or-queen? ally-units '(queen))))
  (define has-enemy-exp? : Boolean
    (if (and (hash? e-by-type) (> (hash-count e-by-type) 0))
        (obs-has-unit-type? sanitized-obs 'enemy-by-type enemy-units
                            '(overlord-transport dropperlord overlord-ventral queen queen-burrowed))
        (fast-units-have-dropper-or-queen? enemy-units '(queen queen-burrowed))))
  (cond
    [(and (not has-ally-exp?) (not has-enemy-exp?)) '()]
    [else
     (define tr : creep-spread-tracker (or opt-tr DEFAULT-CREEP-TRACKER))
     (sync-creep-tracker! tr (safe-exact-int (dyn-hash-ref sanitized-obs 'frame 0) 0))
     (define base-x (safe-real (dyn-hash-ref sanitized-obs 'base-x SC2-DEFAULT-HOME-BASE-X) 32.0))
     (define base-y (safe-real (dyn-hash-ref sanitized-obs 'base-y SC2-DEFAULT-HOME-BASE-Y) 32.0))
     (define nat-x (safe-real (dyn-hash-ref sanitized-obs 'natural-x SC2-DEFAULT-NATURAL-X) 48.0))
     (define nat-y (safe-real (dyn-hash-ref sanitized-obs 'natural-y SC2-DEFAULT-NATURAL-Y) 48.0))
     (define third-x (safe-real (dyn-hash-ref sanitized-obs 'third-x SC2-DEFAULT-THIRD-X) 68.0))
     (define third-y (safe-real (dyn-hash-ref sanitized-obs 'third-y SC2-DEFAULT-THIRD-Y) 42.0))
     (define enemy-x (safe-real (dyn-hash-ref sanitized-obs 'enemy-x SC2-DEFAULT-ENEMY-BASE-X) 160.0))
     (define enemy-y (safe-real (dyn-hash-ref sanitized-obs 'enemy-y SC2-DEFAULT-ENEMY-BASE-Y) 160.0))
     (define ally-bldgs (if has-ally-exp? (dyn-list (dyn-hash-ref sanitized-obs 'ally-buildings '())) '()))
     (define enemy-bldgs (if has-enemy-exp? (dyn-list (dyn-hash-ref sanitized-obs 'enemy-buildings '())) '()))

     (define actions : (Listof (Listof Any)) '())
     (define used-ids : (HashTable Any Boolean) (make-hash))
     (: emit! (-> (Listof Any) Void))
     (define (emit! a) (set! actions (cons a actions)))

     ;; 1. Offense: Dropperlord (`893`) + Creep Queen (`energy >= 25`)
     (define droppers (if has-ally-exp? (filter dropperlord-unit? ally-units) '()))
     (define ready-queens : (Listof Any)
       (if has-ally-exp?
           (filter (lambda ([u : Any])
                     (and (hash? u)
                          (eq? (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown) 'queen)
                          (>= (safe-real (dyn-hash-ref u 'energy 0.0) 0.0) 25.0)))
                   ally-units)
           '()))
     (define targets : (Listof (Pairof Flonum Flonum))
       (if (and has-ally-exp? (or (pair? droppers) (pair? ready-queens)))
           (collect-expedition-creep-targets
            sanitized-obs base-x base-y nat-x nat-y third-x third-y enemy-x enemy-y
            ally-units ally-bldgs enemy-units)
           '()))

  (when (not (null? targets))
    ;; Any Queen already on-site (`<= 6.0` tiles of an expedition target) with creep nearby plants tumor immediately
    (for ([q (in-list ready-queens)])
      (define qid (dyn-hash-ref q 'id 0))
      (define qx (safe-real (dyn-hash-ref q 'x base-x) base-x))
      (define qy (safe-real (dyn-hash-ref q 'y base-y) base-y))
      (define near-tgt : (Option (Pairof Flonum Flonum))
        (findf (lambda ([pt : (Pairof Flonum Flonum)])
                 (<= (dist2d qx qy (car pt) (cdr pt)) 6.0))
               targets))
      (when (and near-tgt (not (hash-ref used-ids qid #f)))
        (define near-dropper?
          (for/or : Boolean ([d (in-list droppers)])
            (<= (dist2d qx qy
                        (safe-real (dyn-hash-ref d 'x -999.0) -999.0)
                        (safe-real (dyn-hash-ref d 'y -999.0) -999.0))
                5.0)))
        (when (or (dyn-hash-ref q 'on-creep? #f) near-dropper?)
          (define tx (car near-tgt))
          (define ty (cdr near-tgt))
          (define dx (- tx qx))
          (define dy (- ty qy))
          (define d (dist2d 0.0 0.0 dx dy))
          (define-values (fx fy)
            (if (<= d 4.6)
                (values tx ty)
                (values (clamp-map-coord (+ qx (* 4.0 (/ dx (max 0.001 d)))))
                        (clamp-map-coord (+ qy (* 4.0 (/ dy (max 0.001 d))))))))
          (hash-set! used-ids qid #t)
          (emit! (list 'cast-spell qid 'spawn-creep-tumor fx fy)))))

    ;; Pair available Dropperlords (`893`) with Creep Queens
    (for ([ovl (in-list droppers)]
          [ti (in-naturals)])
      (define ovl-id (dyn-hash-ref ovl 'id 0))
      (define ox (safe-real (dyn-hash-ref ovl 'x base-x) base-x))
      (define oy (safe-real (dyn-hash-ref ovl 'y base-y) base-y))
      (define cargo-ids (dyn-list (dyn-hash-ref ovl 'cargo-tags
                                                (dyn-hash-ref ovl 'passengers '()))))
      (define cargo-cnt (max (length cargo-ids)
                             (safe-exact-int (dyn-hash-ref ovl 'cargo-space-taken 0) 0)))
      (define tgt (list-ref targets (modulo ti (length targets))))
      (define tx (car tgt))
      (define ty (cdr tgt))
      (define d-tgt (dist2d ox oy tx ty))
      (define gen-creep?
        (or (not (not (dyn-hash-ref ovl 'generating-creep? #f)))
            (not (not (memq 'overlord-generate-creep
                            (dyn-list (dyn-hash-ref ovl 'buffs '())))))))
      (cond
        [(> cargo-cnt 0)
         (hash-set! used-ids ovl-id #t)
         (cond
           [(<= d-tgt 3.5)
            (emit! (list 'transport-juggle ovl-id tx ty))
            (unless gen-creep?
              (emit! (list 'cast-spell ovl-id 'overlord-generate-creep)))
            (for ([pid (in-list cargo-ids)])
              (hash-set! used-ids pid #t)
              (emit! (list 'cast-spell pid 'spawn-creep-tumor tx ty)))]
           [else
            (emit! (list 'move ovl-id tx ty))])]
        [(<= d-tgt 4.0)
         ;; Just dropped Queen off: maintain Generate Creep for immediate tumor cast
         (unless gen-creep?
           (hash-set! used-ids ovl-id #t)
           (emit! (list 'cast-spell ovl-id 'overlord-generate-creep)))]
        [else
         (define free-queens : (Listof Any)
           (filter (lambda ([q : Any]) (not (hash-ref used-ids (dyn-hash-ref q 'id 0) #f)))
                   ready-queens))
         (when (not (null? free-queens))
           (define best-q
             (argmin (lambda ([q : Any])
                       (dist2d ox oy
                               (safe-real (dyn-hash-ref q 'x base-x) base-x)
                               (safe-real (dyn-hash-ref q 'y base-y) base-y)))
                     free-queens))
           (define qid (dyn-hash-ref best-q 'id 0))
           (hash-set! used-ids ovl-id #t)
           (hash-set! used-ids qid #t)
           (emit! (list 'transport-juggle ovl-id (list qid) tx ty)))])))

  ;; 2. Symmetric Counter: intercept enemy Dropperlords (`893`) & snipe remote Creep Queens
  (define enemy-bases : (Listof (Pairof Flonum Flonum))
    (if has-enemy-exp?
        (cons (cons enemy-x enemy-y)
              (filter-map
               (lambda ([b : Any])
                 (and (hash? b)
                      (memq (dyn-symbol (dyn-hash-ref b 'type 'unknown) 'unknown)
                            EXPEDITION-TOWNHALL-SYMS)
                      (cons (safe-real (dyn-hash-ref b 'x enemy-x) enemy-x)
                            (safe-real (dyn-hash-ref b 'y enemy-y) enemy-y))))
               enemy-bldgs))
        '()))
  (define enemy-threats : (Listof (Pairof Symbol Any))
    (if has-enemy-exp?
        (filter-map
         (lambda ([e : Any])
           (and (hash? e)
                (let ([ut (dyn-symbol (dyn-hash-ref e 'type 'unknown) 'unknown)]
                      [ex (safe-real (dyn-hash-ref e 'x 9999.0) 9999.0)]
                      [ey (safe-real (dyn-hash-ref e 'y 9999.0) 9999.0)])
                  (cond
                    [(dropperlord-unit? e) (cons 'dropperlord e)]
                    [(and (memq ut '(queen queen-burrowed))
                          (not (ormap (lambda ([bp : (Pairof Flonum Flonum)])
                                        (<= (dist2d ex ey (car bp) (cdr bp)) 14.0))
                                      enemy-bases)))
                     (cons 'remote-queen e)]
                    [else #f]))))
         enemy-units)
        '()))
  (define need-aa? : Boolean
    (ormap (lambda ([tp : (Pairof Symbol Any)]) (eq? (car tp) 'dropperlord)) enemy-threats))
  (define need-ground? : Boolean
    (ormap (lambda ([tp : (Pairof Symbol Any)]) (eq? (car tp) 'remote-queen)) enemy-threats))
  (define aa-defenders : (Listof Any)
    (if need-aa?
        (filter (lambda ([u : Any])
                  (and (hash? u)
                       (not (hash-ref used-ids (dyn-hash-ref u 'id 0) #f))
                       (not (not (memq (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown)
                                       EXPEDITION-AA-ATTACKER-SYMS)))))
                ally-units)
        '()))
  (define ground-defenders : (Listof Any)
    (if need-ground?
        (filter (lambda ([u : Any])
                  (and (hash? u)
                       (not (hash-ref used-ids (dyn-hash-ref u 'id 0) #f))
                       (let ([ut (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown)])
                         (and (not (memq ut '(scv probe drone drone-burrowed overlord larva egg mule)))
                              (not (memq ut SC2-MOBILE-DETECTOR-SYMS))
                              (not (sc2-non-combat-or-summon-sym? ut))))))
                ally-units)
        '()))

  (for ([tp (in-list enemy-threats)])
    (define kind (car tp))
    (define e (cdr tp))
    (define eid (dyn-hash-ref e 'id 0))
    (define ex (safe-real (dyn-hash-ref e 'x base-x) base-x))
    (define ey (safe-real (dyn-hash-ref e 'y base-y) base-y))
    (define pool
      (filter (lambda ([u : Any]) (not (hash-ref used-ids (dyn-hash-ref u 'id 0) #f)))
              (if (eq? kind 'dropperlord) aa-defenders ground-defenders)))
    (define sorted-pool
      (sort pool
            (lambda ([a : Any] [b : Any])
              (< (dist2d ex ey (safe-real (dyn-hash-ref a 'x base-x) base-x)
                         (safe-real (dyn-hash-ref a 'y base-y) base-y))
                 (dist2d ex ey (safe-real (dyn-hash-ref b 'x base-x) base-x)
                         (safe-real (dyn-hash-ref b 'y base-y) base-y))))))
    (for ([df (in-list (take sorted-pool (min 2 (length sorted-pool))))])
      (define did (dyn-hash-ref df 'id 0))
      (hash-set! used-ids did #t)
      (if (and (exact-integer? eid) (> eid 0))
          (emit! (list 'attack did eid))
          (emit! (list 'attack-pos did ex ey)))))

  (reverse actions)]))

;; =============================================================================
;; 6. Overseer Contaminate (`1825`) Disruption & Counter (`>= 90` Energy Snipe)
;; =============================================================================

(: CONTAMINATE-PRIORITY-UPGRADE-SYMS (Listof Symbol))
(define CONTAMINATE-PRIORITY-UPGRADE-SYMS
  '(twilight-council forge cybernetics-core robotics-bay templar-archive templar-archives
    dark-shrine fleet-beacon engineering-bay armory fusion-core ghost-academy
    barracks-techlab factory-techlab starport-techlab techlab
    evolution-chamber spire greater-spire hydralisk-den lurker-den lurker-den-mp
    baneling-nest roach-warren infestation-pit ultralisk-cavern))

(: CONTAMINATE-PRIORITY-PROD-SYMS (Listof Symbol))
(define CONTAMINATE-PRIORITY-PROD-SYMS
  '(robotics-facility stargate starport factory barracks gateway warp-gate))

(: overseer-unit? (-> Any Boolean))
(define (overseer-unit? u)
  (and (hash? u)
       (or (not (not (memq (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown)
                           '(overseer overseer-siege-mode))))
           (not (not (memv (safe-exact-int (dyn-hash-ref u 'unit-type 0) 0) '(129 1912)))))))

(: building-contaminated? (-> Any Boolean))
(define (building-contaminated? b)
  (or (not (not (dyn-hash-ref b 'contaminated? #f)))
      (for/or : Boolean ([bf (in-list (dyn-list (dyn-hash-ref b 'buffs '())))])
        (or (eq? bf 'contaminate) (eq? bf 'contaminated)
            (and (exact-integer? bf) (= bf 46))))))

(: contaminate-target-score (-> Any Flonum Flonum Flonum))
(define (contaminate-target-score b ox oy)
  (define bt (dyn-symbol (dyn-hash-ref b 'type 'unknown) 'unknown))
  (define active-bonus : Flonum
    (if (or (dyn-hash-ref b 'active? #f)
            (dyn-hash-ref b 'researching? #f)
            (not (null? (dyn-list (dyn-hash-ref b 'orders '())))))
        50.0
        0.0))
  (define base-prio : Flonum
    (cond
      [(memq bt CONTAMINATE-PRIORITY-UPGRADE-SYMS) (+ 200.0 active-bonus)]
      [(memq bt CONTAMINATE-PRIORITY-PROD-SYMS) (+ 100.0 active-bonus)]
      [else -1.0]))
  (if (< base-prio 0.0)
      -1.0
      (- base-prio (* 0.25 (dist2d ox oy
                                   (safe-real (dyn-hash-ref b 'x 9999.0) 9999.0)
                                   (safe-real (dyn-hash-ref b 'y 9999.0) 9999.0))))))

;; Overseer Contaminate (`1825`, range 5, 30s/672f freeze) research & production disruption
;; plus symmetric counter (zone/snipe `>= 90` energy enemy Overseers).
(: plan-overseer-contaminate-disruption (-> Any (Listof (Listof Any))))
(define (plan-overseer-contaminate-disruption obs)
  (define sanitized-obs : Any (if (hash? obs) obs (hash)))
  (define ally-units (dyn-list (dyn-hash-ref sanitized-obs 'ally-units '())))
  (define enemy-units (dyn-list (dyn-hash-ref sanitized-obs 'enemy-units '())))
  (define enemy-bldgs (dyn-list (dyn-hash-ref sanitized-obs 'enemy-buildings '())))
  (define a-by-type (dyn-hash-ref sanitized-obs 'ally-by-type #f))
  (define e-by-type (dyn-hash-ref sanitized-obs 'enemy-by-type #f))
  (define has-ally-ov? : Boolean
    (and (pair? enemy-bldgs)
         (if (and (hash? a-by-type) (> (hash-count a-by-type) 0))
             (obs-has-unit-type? sanitized-obs 'ally-by-type ally-units
                                 '(overseer overseer-siege-mode))
             (fast-units-have-overseer? ally-units))))
  (define has-enemy-ov? : Boolean
    (if (and (hash? e-by-type) (> (hash-count e-by-type) 0))
        (obs-has-unit-type? sanitized-obs 'enemy-by-type enemy-units
                            '(overseer overseer-siege-mode))
        (fast-units-have-overseer? enemy-units)))
  (cond
    [(and (not has-ally-ov?) (not has-enemy-ov?)) '()]
    [else
     (define base-x (safe-real (dyn-hash-ref sanitized-obs 'base-x SC2-DEFAULT-HOME-BASE-X) 32.0))
     (define base-y (safe-real (dyn-hash-ref sanitized-obs 'base-y SC2-DEFAULT-HOME-BASE-Y) 32.0))
     (define enemy-x (safe-real (dyn-hash-ref sanitized-obs 'enemy-x SC2-DEFAULT-ENEMY-BASE-X) 160.0))
     (define enemy-y (safe-real (dyn-hash-ref sanitized-obs 'enemy-y SC2-DEFAULT-ENEMY-BASE-Y) 160.0))

     (define actions : (Listof (Listof Any)) '())
     (define used-ids : (HashTable Any Boolean) (make-hash))
     (define used-enemy-bldgs : (HashTable Any Boolean) (make-hash))
     (: emit! (-> (Listof Any) Void))
     (define (emit! a) (set! actions (cons a actions)))

     ;; 1. Offense: Overseers with energy >= 125 (or >= 95 approaching enemy base)
     (when has-ally-ov?
       (define cand-bldgs : (Listof Any)
         (filter (lambda ([b : Any])
                   (and (hash? b)
                        (>= (safe-real (dyn-hash-ref b 'build-progress 1.0) 1.0)
                            SC2-BUILD-COMPLETE-PROGRESS)
                        (not (building-contaminated? b))
                        (>= (contaminate-target-score b enemy-x enemy-y) 0.0)))
                 enemy-bldgs))

       (for ([ovs (in-list ally-units)]
             #:when (overseer-unit? ovs))
         (define oid (dyn-hash-ref ovs 'id 0))
         (define ox (safe-real (dyn-hash-ref ovs 'x base-x) base-x))
         (define oy (safe-real (dyn-hash-ref ovs 'y base-y) base-y))
         (define en (safe-real (dyn-hash-ref ovs 'energy 0.0) 0.0))
         (define d-ebase (dist2d ox oy enemy-x enemy-y))
         (define avail-bldgs
           (filter (lambda ([b : Any]) (not (hash-ref used-enemy-bldgs (dyn-hash-ref b 'id 0) #f)))
                   cand-bldgs))
         (define approaching? (and (>= en 95.0)
                                   (or (<= d-ebase 28.0)
                                       (for/or : Boolean ([b (in-list avail-bldgs)])
                                         (<= (dist2d ox oy
                                                     (safe-real (dyn-hash-ref b 'x enemy-x) enemy-x)
                                                     (safe-real (dyn-hash-ref b 'y enemy-y) enemy-y))
                                             20.0)))))
         (when (and (not (null? avail-bldgs)) (or (>= en 125.0) approaching?))
           (define best-b
             (argmax (lambda ([b : Any]) (contaminate-target-score b ox oy))
                     avail-bldgs))
           (define bid (dyn-hash-ref best-b 'id 0))
           (define bx (safe-real (dyn-hash-ref best-b 'x enemy-x) enemy-x))
           (define by (safe-real (dyn-hash-ref best-b 'y enemy-y) enemy-y))
           (define d-b (dist2d ox oy bx by))
           (define ut (dyn-symbol (dyn-hash-ref ovs 'type 'unknown) 'unknown))
           (hash-set! used-ids oid #t)
           (hash-set! used-enemy-bldgs bid #t)
           (cond
             [(and (>= en 125.0) (<= d-b 5.0) (exact-integer? bid) (> bid 0))
              (emit! (list 'cast-spell oid 'contaminate bid))]
             [(eq? ut 'overseer-siege-mode)
              (emit! (list 'cast-spell oid 'morph-overseer-mode))
              (emit! (list 'move oid bx by))]
             [else
              (emit! (list 'move oid bx by))]))))

     ;; 2. Symmetric Counter: zone/snipe enemy Overseers with `energy >= 90`
     (define high-en-enemy-ovs : (Listof Any)
       (if has-enemy-ov?
           (filter (lambda ([e : Any])
                     (and (overseer-unit? e)
                          (>= (safe-real (dyn-hash-ref e 'energy 0.0) 0.0) 90.0)))
                   enemy-units)
           '()))
     (unless (null? high-en-enemy-ovs)
       (define aa-pool : (Listof Any)
         (filter (lambda ([u : Any])
                   (and (hash? u)
                        (not (hash-ref used-ids (dyn-hash-ref u 'id 0) #f))
                        (not (not (memq (dyn-symbol (dyn-hash-ref u 'type 'unknown) 'unknown)
                                        EXPEDITION-AA-ATTACKER-SYMS)))))
                 ally-units))
       (for ([eovs (in-list high-en-enemy-ovs)])
         (define eid (dyn-hash-ref eovs 'id 0))
         (define ex (safe-real (dyn-hash-ref eovs 'x base-x) base-x))
         (define ey (safe-real (dyn-hash-ref eovs 'y base-y) base-y))
         (define avail-aa
           (filter (lambda ([u : Any]) (not (hash-ref used-ids (dyn-hash-ref u 'id 0) #f)))
                   aa-pool))
         (define sorted-aa
           (sort avail-aa
                 (lambda ([a : Any] [b : Any])
                   (< (dist2d ex ey (safe-real (dyn-hash-ref a 'x base-x) base-x)
                              (safe-real (dyn-hash-ref a 'y base-y) base-y))
                      (dist2d ex ey (safe-real (dyn-hash-ref b 'x base-x) base-x)
                              (safe-real (dyn-hash-ref b 'y base-y) base-y))))))
         (for ([u (in-list (take sorted-aa (min 2 (length sorted-aa))))])
           (define uid (dyn-hash-ref u 'id 0))
           (hash-set! used-ids uid #t)
           (if (and (exact-integer? eid) (> eid 0))
               (emit! (list 'attack uid eid))
               (emit! (list 'attack-pos uid ex ey))))))

     (reverse actions)]))
