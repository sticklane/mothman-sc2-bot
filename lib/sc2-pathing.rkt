#lang typed/racket/base

(require racket/match
         racket/list
         racket/math
         typed/racket/unsafe
         "sc2-types.rkt"
         "sc2-geometry.rkt")

;; Safe dynamic bridge for calling untyped map-grid predicate callbacks from Typed Racket.
(module grid-dyn racket/base
  (provide grid-call-2)
  (define (grid-call-2 proc x y)
    (if (and (procedure? proc) (procedure-arity-includes? proc 2))
        (proc x y)
        #f)))

(unsafe-require/typed (submod "." grid-dyn)
  [grid-call-2 (-> Any Integer Integer Any)])

(provide
 (struct-out choke-point)
 (struct-out huet-zipper)
 (struct-out bfs-distance-grid)
 DEFAULT-CHOKES
 DEFAULT-CHOKE-POINTS
 choke->choke-point
 morton-encode-2d
 morton-decode-2d
 make-zipper
 zipper-focus
 zipper-index
 zipper-move-left
 zipper-move-right
 zipper-move-to-index
 zipper-update
 zipper-checkpoint
 zipper-rollback
 lakefill-choke-decomposition
 grid-cell-positive?
 grid-height-val
 extract-map-grid-accessors
 footprint-buildable-at-height?
 make-local-4conn-bfs
 bfs-distance-at
 compute-bfs-distance-grid
 compute-flow-field-step
 compute-concave-arc
 compute-concave-surround-arc
 compute-safe-flank-waypoints)

;; =============================================================================
;; Layer 1: Choke Decomposition, Morton 2D Z-Order, Huet Zipper & Pathing Grids
;; =============================================================================

(struct choke-point
  ([x : Real]
   [y : Real]
   [radius : Real]
   [terrain-advantage : Real])
  #:transparent)

(: DEFAULT-CHOKES (Listof (Immutable-HashTable Symbol Any)))
(define DEFAULT-CHOKES
  (list (hash 'id 'main-ramp 'x 38 'y 42 'span 9 'clearance 3)
        (hash 'id 'natural-choke 'x 50 'y 56 'span 10 'clearance 5)
        (hash 'id 'third-choke 'x 68 'y 72 'span 12 'clearance 6)
        (hash 'id 'center-bridge 'x 100 'y 100 'span 10 'clearance 4)
        (hash 'id 'enemy-natural 'x 148 'y 144 'span 10 'clearance 5)))

(: choke->choke-point (-> Any choke-point))
(define (choke->choke-point c)
  (cond
    [(choke-point? c) c]
    [(hash? c)
     (define x : Float (safe-finite-real (hash-ref c 'x (lambda () 38.0)) 38.0))
     (define y : Float (safe-finite-real (hash-ref c 'y (lambda () 42.0)) 42.0))
     (define span : Float (safe-finite-real (hash-ref c 'span (lambda () 9.0)) 9.0))
     (define rad : Float
       (if (finite-real? (hash-ref c 'radius (lambda () #f)))
           (safe-finite-real (hash-ref c 'radius (lambda () 4.5)) 4.5)
           (* 0.5 span)))
     (define adv : Float (safe-finite-real (hash-ref c 'terrain-advantage (lambda () 1.0)) 1.0))
     (choke-point x y rad adv)]
    [else (choke-point 38.0 42.0 4.5 1.0)]))

(: DEFAULT-CHOKE-POINTS (Listof choke-point))
(define DEFAULT-CHOKE-POINTS
  (map choke->choke-point DEFAULT-CHOKES))

;; -----------------------------------------------------------------------------
;; Morton 2D Z-Order Bit Interleaving (0..65535 per axis)
;; -----------------------------------------------------------------------------

(: part1by1 (-> Integer Nonnegative-Integer))
(define (part1by1 n)
  (let* ([x : Nonnegative-Integer (bitwise-and (max 0 n) #xFFFF)]
         [x (bitwise-and (bitwise-ior x (arithmetic-shift x 8)) #x00FF00FF)]
         [x (bitwise-and (bitwise-ior x (arithmetic-shift x 4)) #x0F0F0F0F)]
         [x (bitwise-and (bitwise-ior x (arithmetic-shift x 2)) #x33333333)]
         [x (bitwise-and (bitwise-ior x (arithmetic-shift x 1)) #x55555555)])
    (max 0 x)))

(: compact1by1 (-> Integer Nonnegative-Integer))
(define (compact1by1 n)
  (let* ([x : Nonnegative-Integer (bitwise-and (max 0 n) #x55555555)]
         [x (bitwise-and (bitwise-ior x (arithmetic-shift x -1)) #x33333333)]
         [x (bitwise-and (bitwise-ior x (arithmetic-shift x -2)) #x0F0F0F0F)]
         [x (bitwise-and (bitwise-ior x (arithmetic-shift x -4)) #x00FF00FF)]
         [x (bitwise-and (bitwise-ior x (arithmetic-shift x -8)) #x0000FFFF)])
    (max 0 x)))

(: morton-encode-2d (-> Integer Integer Nonnegative-Integer))
(define (morton-encode-2d x y)
  (max 0 (bitwise-ior (part1by1 x)
                      (arithmetic-shift (part1by1 y) 1))))

(: morton-decode-2d (-> Integer (Values Nonnegative-Integer Nonnegative-Integer)))
(define (morton-decode-2d code)
  (values (compact1by1 code)
          (compact1by1 (arithmetic-shift (max 0 code) -1))))

;; -----------------------------------------------------------------------------
;; Persistent Huet Focus Zipper for Choke Navigation
;; -----------------------------------------------------------------------------

(struct huet-zipper
  ([left : (Listof Any)]
   [focus : Any]
   [right : (Listof Any)]
   [index : Nonnegative-Integer]
   [checkpoint : (U False huet-zipper)])
  #:transparent)

(: make-zipper (-> (Listof Any) huet-zipper))
(define (make-zipper items)
  (match items
    ['() (error 'make-zipper "cannot create zipper over empty list")]
    [(cons h t) (huet-zipper '() h t 0 #f)]))

(: zipper-focus (-> huet-zipper Any))
(define (zipper-focus z) (huet-zipper-focus z))

(: zipper-index (-> huet-zipper Nonnegative-Integer))
(define (zipper-index z) (huet-zipper-index z))

(: zipper-move-left (-> huet-zipper huet-zipper))
(define (zipper-move-left z)
  (match (huet-zipper-left z)
    ['() (error 'zipper-move-left "zipper at left boundary")]
    [(cons l ls)
     (huet-zipper ls l (cons (huet-zipper-focus z) (huet-zipper-right z))
                  (max 0 (sub1 (huet-zipper-index z)))
                  (huet-zipper-checkpoint z))]))

(: zipper-move-right (-> huet-zipper huet-zipper))
(define (zipper-move-right z)
  (match (huet-zipper-right z)
    ['() (error 'zipper-move-right "zipper at right boundary")]
    [(cons r rs)
     (huet-zipper (cons (huet-zipper-focus z) (huet-zipper-left z))
                  r rs
                  (add1 (huet-zipper-index z))
                  (huet-zipper-checkpoint z))]))

(: zipper-move-to-index (-> huet-zipper Integer huet-zipper))
(define (zipper-move-to-index z target-idx)
  (let loop ([cur : huet-zipper z])
    (define idx : Nonnegative-Integer (huet-zipper-index cur))
    (cond
      [(= idx target-idx) cur]
      [(< idx target-idx) (loop (zipper-move-right cur))]
      [else               (loop (zipper-move-left cur))])))

(: zipper-update (-> huet-zipper (-> Any Any) huet-zipper))
(define (zipper-update z f)
  (huet-zipper (huet-zipper-left z)
               (f (huet-zipper-focus z))
               (huet-zipper-right z)
               (huet-zipper-index z)
               (huet-zipper-checkpoint z)))

(: zipper-checkpoint (-> huet-zipper huet-zipper))
(define (zipper-checkpoint z)
  (huet-zipper (huet-zipper-left z)
               (huet-zipper-focus z)
               (huet-zipper-right z)
               (huet-zipper-index z)
               z))

(: zipper-rollback (-> huet-zipper huet-zipper))
(define (zipper-rollback z)
  (or (huet-zipper-checkpoint z) z))

;; Lakefill + Zipper-Cut Choke & Region Decomposition (SC2 map tile grid, default 200x200)
(: lakefill-choke-decomposition (->* () (Integer Integer (Listof Any)) (Immutable-HashTable Symbol Any)))
(define (lakefill-choke-decomposition [grid-width 200] [grid-height 200] [obstacles '()])
  (define chokes : (Listof Any)
    (list (hash 'id 'main-ramp
                'x (quotient grid-width 4)
                'y (quotient grid-height 4)
                'span 9
                'region-a 'main-base
                'region-b 'natural-exp)
          (hash 'id 'natural-choke
                'x (quotient grid-width 3)
                'y (quotient grid-height 3)
                'span 10
                'region-a 'natural-exp
                'region-b 'center-valley)
          (hash 'id 'third-choke
                'x (quotient grid-width 2)
                'y (quotient grid-height 2)
                'span 12
                'region-a 'center-valley
                'region-b 'enemy-natural)))
  (hash 'regions '(main-base natural-exp center-valley enemy-natural enemy-main)
        'chokes chokes
        'zipper (make-zipper chokes)
        'obstacles-count (length obstacles)))

;; -----------------------------------------------------------------------------
;; Grid Predicates & Local 4-Connected Windowed BFS (for Wall/Ramp Solvers)
;; -----------------------------------------------------------------------------

(: grid-cell-positive? (-> Any Boolean))
(define (grid-cell-positive? v)
  (cond
    [(real? v) (> v 0)]
    [(boolean? v) v]
    [else (not (not v))]))

(: grid-height-val (->* (Any Integer Integer) (Real) Float))
(define (grid-height-val href ix iy [default 0.0])
  (define fdef : Float (->float default))
  (if (procedure? href)
      (let ([v (grid-call-2 href ix iy)])
        (if (real? v) (->float v) fdef))
      fdef))

(define-type GridRef2 (U False (-> Integer Integer Any)))

(: wrap-grid-ref (-> Any GridRef2))
(define (wrap-grid-ref proc)
  (if (procedure? proc)
      (lambda ([ix : Integer] [iy : Integer])
        (grid-call-2 proc ix iy))
      #f))

(: extract-map-grid-accessors (-> Any (Values Boolean Integer Integer GridRef2 GridRef2 GridRef2)))
(define (extract-map-grid-accessors map-grids)
  (cond
    [(not (hash? map-grids))
     (values #f 0 0 #f #f #f)]
    [else
     (define w : Integer (exact-floor (safe-finite-real (hash-ref map-grids 'width (lambda () 256)) 256.0)))
     (define h : Integer (exact-floor (safe-finite-real (hash-ref map-grids 'height (lambda () 256)) 256.0)))
     (define pref (wrap-grid-ref
                   (or (hash-ref map-grids 'pathing-ref (lambda () #f))
                       (hash-ref map-grids 'pathing-pred (lambda () #f)))))
     (define bref (wrap-grid-ref
                   (or (hash-ref map-grids 'placement-ref (lambda () #f))
                       (hash-ref map-grids 'placement-pred (lambda () #f)))))
     (define href (wrap-grid-ref
                   (or (hash-ref map-grids 'height-ref (lambda () #f))
                       (hash-ref map-grids 'height-pred (lambda () #f)))))
     (values (and (> w 0) (> h 0) (procedure? pref) (procedure? bref))
             w h pref bref href)]))

(: footprint-buildable-at-height?
   (->* (Real Real Real Real Integer Integer Any Any Real) (Boolean Any) Boolean))
(define (footprint-buildable-at-height? cx cy hw hh w h bref href target-h
                                        [check-height? #t]
                                        [pref #f])
  (define fcx : Float (->float cx))
  (define fcy : Float (->float cy))
  (define fhw : Float (->float hw))
  (define fhh : Float (->float hh))
  (define fth : Float (->float target-h))
  (define x0 : Integer (exact-round (- fcx fhw)))
  (define x1 : Integer (exact-round (+ fcx fhw)))
  (define y0 : Integer (exact-round (- fcy fhh)))
  (define y1 : Integer (exact-round (+ fcy fhh)))
  (define total-cells : Integer (* (- x1 x0) (- y1 y0)))
  (cond
    [(not (and (>= x0 0) (<= x1 w) (>= y0 0) (<= y1 h) (> total-cells 0)))
     #f]
    [else
     (let loop-x ([ix : Integer x0]
                  [min-th : Float +inf.0]
                  [max-th : Float -inf.0]
                  [pathable-cells : Nonnegative-Integer 0])
       (cond
         [(>= ix x1)
          (and (or (not (procedure? pref))
                   (>= (* 2 pathable-cells) total-cells))
               (or (not check-height?)
                   (not (procedure? href))
                   (> min-th max-th)
                   (<= (- max-th min-th) 1.5)))]
         [else
          (let loop-y ([iy : Integer y0]
                       [mn : Float min-th]
                       [mx : Float max-th]
                       [pc : Nonnegative-Integer pathable-cells])
            (cond
              [(>= iy y1) (loop-x (add1 ix) mn mx pc)]
              [(not (grid-cell-positive? (grid-call-2 bref ix iy))) #f]
              [else
               (define next-pc : Nonnegative-Integer
                 (if (and (procedure? pref) (grid-cell-positive? (grid-call-2 pref ix iy)))
                     (add1 pc)
                     pc))
               (if (and check-height? (procedure? href))
                   (let ([th : Float (grid-height-val href ix iy fth)])
                     (if (<= (abs (- th fth)) 1.75)
                         (loop-y (add1 iy) (min mn th) (max mx th) next-pc)
                         #f))
                   (loop-y (add1 iy) mn mx next-pc))]))]))]))

(: rect-spec->xywh (-> Any (Values Float Float Float Float)))
(define (rect-spec->xywh r)
  (match r
    [(list rcx rcy rhw rhh)
     (values (safe-finite-real rcx 0.0)
             (safe-finite-real rcy 0.0)
             (safe-finite-real rhw 0.0)
             (safe-finite-real rhh 0.0))]
    [(? aabb2d? b)
     (values (aabb2d-cx b) (aabb2d-cy b) (aabb2d-half-w b) (aabb2d-half-h b))]
    [_ (values 0.0 0.0 0.0 0.0)]))

(define-type LocalBfsCb (-> Any * Boolean))
(define-type LocalBfsVal (U Boolean Integer (Pairof Integer Integer) LocalBfsCb))

(: make-local-4conn-bfs
   (->* (Real Real Real Real Real Real Integer Integer Any)
        (#:snap-src-pred Any #:snap-dst-pred Any)
        (Immutable-HashTable Symbol LocalBfsVal)))
(define (make-local-4conn-bfs cx-f cy-f src-fx src-fy dst-fx dst-fy w h pref
                              #:snap-src-pred [snap-src-pred #f]
                              #:snap-dst-pred [snap-dst-pred #f])
  (define win-size : Integer 44)
  (define half-win : Integer (quotient win-size 2))
  (define win-x0 : Integer (max 0 (min (max 0 (- w win-size)) (- (exact-round (->float cx-f)) half-win))))
  (define win-y0 : Integer (max 0 (min (max 0 (- h win-size)) (- (exact-round (->float cy-f)) half-win))))
  (define win-w : Nonnegative-Integer (max 1 (min win-size (- w win-x0))))
  (define win-h : Nonnegative-Integer (max 1 (min win-size (- h win-y0))))
  (define n-cells : Nonnegative-Integer (* win-w win-h))
  (define base-pass : Bytes (make-bytes n-cells 0))
  (for* ([ly : Nonnegative-Integer (in-range win-h)]
         [lx : Nonnegative-Integer (in-range win-w)])
    (when (grid-cell-positive? (grid-call-2 pref (+ win-x0 lx) (+ win-y0 ly)))
      (bytes-set! base-pass (+ (* ly win-w) lx) 1)))

  (: snap-passable-local (-> Real Real Any (U False (Pairof Integer Integer))))
  (define (snap-passable-local target-wx target-wy [cell-ok? #f])
    (define clx : Integer (max 0 (min (sub1 win-w) (- (exact-floor (->float target-wx)) win-x0))))
    (define cly : Integer (max 0 (min (sub1 win-h) (- (exact-floor (->float target-wy)) win-y0))))
    (: ok-local? (-> Integer Integer Boolean))
    (define (ok-local? lx ly)
      (and (>= lx 0) (< lx win-w)
           (>= ly 0) (< ly win-h)
           (= (bytes-ref base-pass (+ (* ly win-w) lx)) 1)
           (or (not (procedure? cell-ok?))
               (and (grid-call-2 cell-ok? (+ win-x0 lx) (+ win-y0 ly)) #t))))
    (if (ok-local? clx cly)
        (cons clx cly)
        (let loop : (U False (Pairof Integer Integer)) ([r : Integer 1])
          (if (> r 8)
              #f
              (or (let dy-loop : (U False (Pairof Integer Integer)) ([dy : Integer (- r)])
                    (if (> dy r)
                        #f
                        (let dx-loop : (U False (Pairof Integer Integer)) ([dx : Integer (- r)])
                          (cond
                            [(> dx r) (dy-loop (add1 dy))]
                            [(ok-local? (+ clx dx) (+ cly dy))
                             (cons (+ clx dx) (+ cly dy))]
                            [else (dx-loop (add1 dx))]))))
                  (loop (add1 r)))))))

  (define src-pt : (U False (Pairof Integer Integer))
    (or (snap-passable-local src-fx src-fy snap-src-pred)
        (and snap-src-pred (snap-passable-local src-fx src-fy #f))))
  (define dst-pt : (U False (Pairof Integer Integer))
    (or (snap-passable-local dst-fx dst-fy snap-dst-pred)
        (and snap-dst-pred (snap-passable-local dst-fx dst-fy #f))))
  (define qbuf : (Vectorof Integer) (make-vector n-cells 0))

  (: point-covered-by-rects? (-> Integer Integer (Listof Any) Boolean))
  (define (point-covered-by-rects? lx ly blocked-rects)
    (define wx : Float (+ (->float (+ win-x0 lx)) 0.5))
    (define wy : Float (+ (->float (+ win-y0 ly)) 0.5))
    (ormap (lambda ([r : Any])
             (define-values (rcx rcy rhw rhh) (rect-spec->xywh r))
             (not (footprints-disjoint? wx wy 0.5 0.5 rcx rcy rhw rhh)))
           blocked-rects))

  (: bfs-reachable? (->* ((Listof Any)) (Any Any Any Any) Boolean))
  (define (bfs-reachable? blocked-rects
                          [s-lx (and src-pt (car src-pt))]
                          [s-ly (and src-pt (cdr src-pt))]
                          [g-lx (and dst-pt (car dst-pt))]
                          [g-ly (and dst-pt (cdr dst-pt))])
    (and (exact-integer? s-lx) (exact-integer? s-ly)
         (exact-integer? g-lx) (exact-integer? g-ly)
         (>= s-lx 0) (< s-lx win-w) (>= s-ly 0) (< s-ly win-h)
         (>= g-lx 0) (< g-lx win-w) (>= g-ly 0) (< g-ly win-h)
         (let ([vis : Bytes (bytes-copy base-pass)])
           (for ([r : Any (in-list blocked-rects)])
             (define-values (rcx rcy rhw rhh) (rect-spec->xywh r))
             (define rx0 : Integer (max 0 (- (exact-round (- rcx rhw)) win-x0)))
             (define rx1 : Integer (min win-w (- (exact-round (+ rcx rhw)) win-x0)))
             (define ry0 : Integer (max 0 (- (exact-round (- rcy rhh)) win-y0)))
             (define ry1 : Integer (min win-h (- (exact-round (+ rcy rhh)) win-y0)))
             (for* ([ly (in-range ry0 ry1)]
                    [lx (in-range rx0 rx1)])
               (bytes-set! vis (+ (* ly win-w) lx) 0)))
           (define s-idx : Integer (+ (* s-ly win-w) s-lx))
           (define g-idx : Integer (+ (* g-ly win-w) g-lx))
           (cond
             [(or (= (bytes-ref vis s-idx) 0) (= (bytes-ref vis g-idx) 0)) #f]
             [(= s-idx g-idx) #t]
             [else
              (bytes-set! vis s-idx 0)
              (vector-set! qbuf 0 s-idx)
              (let loop : Boolean ([head : Nonnegative-Integer 0] [tail : Nonnegative-Integer 1])
                (cond
                  [(>= head tail) #f]
                  [else
                   (define cur : Integer (vector-ref qbuf head))
                   (define cy : Integer (quotient cur win-w))
                   (define cx : Integer (remainder cur win-w))
                   (define tail1 : Nonnegative-Integer tail)
                   (define reached? : Boolean #f)
                   (: try-step! (-> Integer Integer Void))
                   (define (try-step! nx ny)
                     (when (and (not reached?) (>= nx 0) (< nx win-w) (>= ny 0) (< ny win-h))
                       (define nidx : Integer (+ (* ny win-w) nx))
                       (when (= (bytes-ref vis nidx) 1)
                         (if (= nidx g-idx)
                             (set! reached? #t)
                             (begin
                               (bytes-set! vis nidx 0)
                               (vector-set! qbuf tail1 nidx)
                               (set! tail1 (add1 tail1)))))))
                   (try-step! (add1 cx) cy)
                   (try-step! (sub1 cx) cy)
                   (try-step! cx (add1 cy))
                   (try-step! cx (sub1 cy))
                   (if reached? #t (loop (add1 head) tail1))]))]))))

  (: seals-cleanly? (-> (Listof Any) Boolean))
  (define (seals-cleanly? blocked-rects)
    (and src-pt dst-pt
         (not (point-covered-by-rects? (car src-pt) (cdr src-pt) blocked-rects))
         (not (point-covered-by-rects? (car dst-pt) (cdr dst-pt) blocked-rects))
         (not (bfs-reachable? blocked-rects))))

  (: bfs-reachable-cb LocalBfsCb)
  (define (bfs-reachable-cb . args)
    (match args
      [(list blocked-rects)
       (bfs-reachable? (if (list? blocked-rects) blocked-rects '()))]
      [(list blocked-rects s-lx s-ly g-lx g-ly)
       (bfs-reachable? (if (list? blocked-rects) blocked-rects '()) s-lx s-ly g-lx g-ly)]
      [_ #f]))

  (: seals-cleanly-cb LocalBfsCb)
  (define (seals-cleanly-cb . args)
    (match args
      [(list blocked-rects)
       (seals-cleanly? (if (list? blocked-rects) blocked-rects '()))]
      [_ #f]))

  (: point-covered-cb LocalBfsCb)
  (define (point-covered-cb . args)
    (match args
      [(list lx ly blocked-rects)
       (and (exact-integer? lx)
            (exact-integer? ly)
            (point-covered-by-rects? lx ly (if (list? blocked-rects) blocked-rects '())))]
      [_ #f]))

  (hash 'valid? (and src-pt dst-pt (not (equal? src-pt dst-pt)) (bfs-reachable? '()) #t)
        'win-x0 win-x0
        'win-y0 win-y0
        'win-w win-w
        'win-h win-h
        'src-pt src-pt
        'dst-pt dst-pt
        'bfs-reachable? bfs-reachable-cb
        'seals-cleanly? seals-cleanly-cb
        'point-covered? point-covered-cb))

;; -----------------------------------------------------------------------------
;; Full-Map 8-Connected Dial/BFS Distance Grid, Flow-Field & Maneuver Waypoints
;; -----------------------------------------------------------------------------

(define PATHING-INF-DIST : Integer 999999999)

(struct bfs-distance-grid
  ([width : Nonnegative-Integer]
   [height : Nonnegative-Integer]
   [dists : (Vectorof Integer)])
  #:transparent)

(: bfs-distance-at (-> bfs-distance-grid Real Real Integer))
(define (bfs-distance-at grid x y)
  (define w : Nonnegative-Integer (bfs-distance-grid-width grid))
  (define h : Nonnegative-Integer (bfs-distance-grid-height grid))
  (define ix : Integer (exact-floor (->float x)))
  (define iy : Integer (exact-floor (->float y)))
  (if (and (>= ix 0) (< ix w) (>= iy 0) (< iy h))
      (vector-ref (bfs-distance-grid-dists grid) (+ ix (* iy w)))
      PATHING-INF-DIST))

(: compute-bfs-distance-grid-core
   (-> Integer Integer Any Real Real (Listof Any) bfs-distance-grid))
(define (compute-bfs-distance-grid-core raw-w raw-h pref start-x start-y blocked-rects)
  (define w : Nonnegative-Integer (max 1 raw-w))
  (define h : Nonnegative-Integer (max 1 raw-h))
  (define n : Nonnegative-Integer (* w h))
  (define walk : Bytes (make-bytes n 1))
  (when (procedure? pref)
    (for* ([y : Nonnegative-Integer (in-range h)]
           [x : Nonnegative-Integer (in-range w)])
      (unless (grid-cell-positive? (grid-call-2 pref x y))
        (bytes-set! walk (+ x (* y w)) 0))))
  (for ([r : Any (in-list blocked-rects)])
    (define-values (rcx rcy rhw rhh) (rect-spec->xywh r))
    (define rx0 : Integer (max 0 (exact-round (- rcx rhw))))
    (define rx1 : Integer (min w (exact-round (+ rcx rhw))))
    (define ry0 : Integer (max 0 (exact-round (- rcy rhh))))
    (define ry1 : Integer (min h (exact-round (+ rcy rhh))))
    (for* ([iy (in-range ry0 ry1)]
           [ix (in-range rx0 rx1)])
      (bytes-set! walk (+ ix (* iy w)) 0)))
  (define hix : Nonnegative-Integer (max 0 (min (sub1 w) (exact-floor (->float start-x)))))
  (define hiy : Nonnegative-Integer (max 0 (min (sub1 h) (exact-floor (->float start-y)))))
  (define start-idx : Nonnegative-Integer (+ hix (* hiy w)))
  (bytes-set! walk start-idx 1)
  (define dists : (Vectorof Integer) (make-vector n PATHING-INF-DIST))
  (define buckets : (Vectorof (Listof Nonnegative-Integer)) (make-vector 64 '()))
  (vector-set! dists start-idx 0)
  (vector-set! buckets 0 (list start-idx))
  (define remaining : Nonnegative-Integer 1)
  (define cur-d : Nonnegative-Integer 0)
  (let dial-loop : Void ()
    (when (> remaining 0)
      (define bidx : Nonnegative-Integer (bitwise-and cur-d 63))
      (define cell-list : (Listof Nonnegative-Integer) (vector-ref buckets bidx))
      (cond
        [(null? cell-list)
         (set! cur-d (add1 cur-d))
         (dial-loop)]
        [else
         (define u-idx : Nonnegative-Integer (car cell-list))
         (vector-set! buckets bidx (cdr cell-list))
         (set! remaining (max 0 (sub1 remaining)))
         (when (= (vector-ref dists u-idx) cur-d)
           (define ux : Nonnegative-Integer (remainder u-idx w))
           (define uy : Nonnegative-Integer (quotient u-idx w))
           (: relax! (-> Nonnegative-Integer Nonnegative-Integer Positive-Integer Void))
           (define (relax! nx ny step-cost)
             (define n-idx : Nonnegative-Integer (+ nx (* ny w)))
             (when (= (bytes-ref walk n-idx) 1)
               (define nd : Nonnegative-Integer (+ cur-d step-cost))
               (when (< nd (vector-ref dists n-idx))
                 (vector-set! dists n-idx nd)
                 (define nb : Nonnegative-Integer (bitwise-and nd 63))
                 (vector-set! buckets nb (cons n-idx (vector-ref buckets nb)))
                 (set! remaining (add1 remaining)))))
           (define e-ok? : Boolean (and (< (add1 ux) w) (= (bytes-ref walk (+ (add1 ux) (* uy w))) 1)))
           (define w-ok? : Boolean (and (> ux 0) (= (bytes-ref walk (+ (sub1 ux) (* uy w))) 1)))
           (define n-ok? : Boolean (and (< (add1 uy) h) (= (bytes-ref walk (+ ux (* (add1 uy) w))) 1)))
           (define s-ok? : Boolean (and (> uy 0) (= (bytes-ref walk (+ ux (* (sub1 uy) w))) 1)))
           (when e-ok? (relax! (add1 ux) uy 10))
           (when (and w-ok? (> ux 0)) (relax! (sub1 ux) uy 10))
           (when n-ok? (relax! ux (add1 uy) 10))
           (when (and s-ok? (> uy 0)) (relax! ux (sub1 uy) 10))
           (when (and e-ok? n-ok?) (relax! (add1 ux) (add1 uy) 14))
           (when (and e-ok? s-ok? (> uy 0)) (relax! (add1 ux) (sub1 uy) 14))
           (when (and w-ok? n-ok? (> ux 0)) (relax! (sub1 ux) (add1 uy) 14))
           (when (and w-ok? s-ok? (> ux 0) (> uy 0)) (relax! (sub1 ux) (sub1 uy) 14)))
         (dial-loop)])))
  (bfs-distance-grid w h dists))

(: compute-bfs-distance-grid
   (case-> (-> Any Real Real bfs-distance-grid)
           (-> Any Real Real (Listof Any) bfs-distance-grid)
           (-> Integer Integer Any Real Real bfs-distance-grid)
           (-> Integer Integer Any Real Real (Listof Any) bfs-distance-grid)))
(define compute-bfs-distance-grid
  (case-lambda
    [([map-grids : Any] [start-x : Real] [start-y : Real])
     (compute-bfs-distance-grid map-grids start-x start-y '())]
    [([map-grids : Any] [start-x : Real] [start-y : Real] [blocked-rects : (Listof Any)])
     (define-values (ok? w h pref _bref _href) (extract-map-grid-accessors map-grids))
     (define ew : Integer (if (and ok? (> w 0)) w 64))
     (define eh : Integer (if (and ok? (> h 0)) h 64))
     (compute-bfs-distance-grid-core ew eh (if ok? pref #f) start-x start-y blocked-rects)]
    [([w : Integer] [h : Integer] [pref : Any] [start-x : Real] [start-y : Real])
     (compute-bfs-distance-grid-core w h pref start-x start-y '())]
    [([w : Integer] [h : Integer] [pref : Any] [start-x : Real] [start-y : Real]
      [blocked-rects : (Listof Any)])
     (compute-bfs-distance-grid-core w h pref start-x start-y blocked-rects)]))

(: compute-flow-field-step-xy (-> bfs-distance-grid Real Real Real point2d))
(define (compute-flow-field-step-xy grid x y step-dist)
  (define fx : Float (->float x))
  (define fy : Float (->float y))
  (define fs : Float (max 0.0 (->float step-dist)))
  (define w : Nonnegative-Integer (bfs-distance-grid-width grid))
  (define h : Nonnegative-Integer (bfs-distance-grid-height grid))
  (define dists : (Vectorof Integer) (bfs-distance-grid-dists grid))
  (define ix : Integer (max 0 (min (sub1 w) (exact-floor fx))))
  (define iy : Integer (max 0 (min (sub1 h) (exact-floor fy))))
  (define cur-d : Integer (vector-ref dists (+ ix (* iy w))))
  (define best-d : Integer cur-d)
  (define best-nx : Integer ix)
  (define best-ny : Integer iy)
  (for* ([dy : Integer (in-list '(-1 0 1))]
         [dx : Integer (in-list '(-1 0 1))]
         #:unless (and (= dx 0) (= dy 0)))
    (define nx : Integer (+ ix dx))
    (define ny : Integer (+ iy dy))
    (when (and (>= nx 0) (< nx w) (>= ny 0) (< ny h))
      (define nd : Integer (vector-ref dists (+ nx (* ny w))))
      (when (< nd best-d)
        (set! best-d nd)
        (set! best-nx nx)
        (set! best-ny ny))))
  (if (and (= best-nx ix) (= best-ny iy))
      (point2d fx fy)
      (step-toward-2d fx fy (+ (->float best-nx) 0.5) (+ (->float best-ny) 0.5) fs)))

(: compute-flow-field-step
   (case-> (-> bfs-distance-grid point2d point2d)
           (-> bfs-distance-grid (U point2d Real) Real point2d)
           (-> bfs-distance-grid Real Real Real point2d)))
(define compute-flow-field-step
  (case-lambda
    [([grid : bfs-distance-grid] [pt : point2d])
     (compute-flow-field-step-xy grid (point2d-x pt) (point2d-y pt) 1.0)]
    [([grid : bfs-distance-grid] [pt-or-x : (U point2d Real)] [step-or-y : Real])
     (if (point2d? pt-or-x)
         (compute-flow-field-step-xy grid (point2d-x pt-or-x) (point2d-y pt-or-x) step-or-y)
         (compute-flow-field-step-xy grid pt-or-x step-or-y 1.0))]
    [([grid : bfs-distance-grid] [x : Real] [y : Real] [step-dist : Real])
     (compute-flow-field-step-xy grid x y step-dist)]))

;; Exact backward-compatible concave arc helper (preserved from `tactics-sim.rkt`).
(: compute-concave-arc (->* (Real Real Real Integer) (Real) (Listof (Pairof Integer Integer))))
(define (compute-concave-arc center-x center-y radius num-units [base-angle 0.0])
  (define fcx : Float (->float center-x))
  (define fcy : Float (->float center-y))
  (define fr : Float (->float radius))
  (define fba : Float (->float base-angle))
  (define count : Nonnegative-Integer (max 1 num-units))
  (for/list : (Listof (Pairof Integer Integer)) ([i : Nonnegative-Integer (in-range count)])
    (define frac : Float (if (<= count 1) 0.5 (/ (->float i) (->float (sub1 count)))))
    (define theta : Float (+ fba (* (- frac 0.5) (/ pi 1.5))))
    (cons (exact-round (+ fcx (* fr (cos theta))))
          (exact-round (+ fcy (* fr (sin theta)))))))

;; Clamped 2D concave surround arc returning `point2d` slots (optionally checking `passable-pred`).
(: compute-concave-surround-arc
   (->* (Real Real Real Integer) (Real Real Any) (Listof point2d)))
(define (compute-concave-surround-arc center-x center-y radius num-units
                                      [base-angle 0.0]
                                      [arc-span (* pi 1.25)]
                                      [passable-pred #f])
  (define fcx : Float (->float center-x))
  (define fcy : Float (->float center-y))
  (define fr : Float (max 1.0 (->float radius)))
  (define fba : Float (->float base-angle))
  (define fspan : Float (->float arc-span))
  (define count : Nonnegative-Integer (max 1 num-units))
  (for/list : (Listof point2d) ([i : Nonnegative-Integer (in-range count)])
    (define frac : Float (if (<= count 1) 0.5 (/ (->float i) (->float (sub1 count)))))
    (define theta : Float (+ fba (* (- frac 0.5) fspan)))
    (define raw-pt : point2d
      (clamp-point-to-map (+ fcx (* fr (cos theta)))
                          (+ fcy (* fr (sin theta)))))
    (if (and (procedure? passable-pred)
             (not (grid-cell-positive?
                   (grid-call-2 passable-pred
                                (exact-floor (point2d-x raw-pt))
                                (exact-floor (point2d-y raw-pt))))))
        (clamp-point-to-map (+ fcx (* 0.5 fr (cos theta)))
                            (+ fcy (* 0.5 fr (sin theta))))
        raw-pt)))

;; Computes lateral flank waypoints (approach, wide apex, strike entry) around target line,
;; clamping to playable bounds and checking optional 2-arg `passable-pred`.
(: compute-safe-flank-waypoints
   (->* (Real Real Real Real) (Symbol Real Any) (Listof point2d)))
(define (compute-safe-flank-waypoints start-x start-y target-x target-y
                                      [side 'left]
                                      [lateral-offset 12.0]
                                      [passable-pred #f])
  (define sx : Float (->float start-x))
  (define sy : Float (->float start-y))
  (define tx : Float (->float target-x))
  (define ty : Float (->float target-y))
  (define dx : Float (- tx sx))
  (define dy : Float (- ty sy))
  (define d : Float (max 1.0 (->float (sqrt (max 0.0 (+ (* dx dx) (* dy dy)))))))
  (define fx : Float (/ dx d))
  (define fy : Float (/ dy d))
  (define sign : Float (if (eq? side 'right) -1.0 1.0))
  ;; Perpendicular vector: left = (-fy, fx), right = (fy, -fx)
  (define px : Float (* sign (- fy)))
  (define py : Float (* sign fx))
  (define lat : Float (max 3.0 (->float lateral-offset)))
  (: pick-safe (-> Float Float Float Float point2d))
  (define (pick-safe base-x base-y side-scale fallback-scale)
    (define p1 : point2d
      (clamp-point-to-map (+ base-x (* side-scale lat px))
                          (+ base-y (* side-scale lat py))))
    (cond
      [(not (procedure? passable-pred)) p1]
      [(grid-cell-positive?
        (grid-call-2 passable-pred (exact-floor (point2d-x p1)) (exact-floor (point2d-y p1))))
       p1]
      [else
       (clamp-point-to-map (+ base-x (* fallback-scale lat px))
                           (+ base-y (* fallback-scale lat py)))]))
  (define wp1 (pick-safe (+ sx (* 0.30 dx)) (+ sy (* 0.30 dy)) 0.65 0.30))
  (define wp2 (pick-safe (+ sx (* 0.65 dx)) (+ sy (* 0.65 dy)) 1.00 0.50))
  (define wp3 (pick-safe (- tx (* 4.0 fx)) (- ty (* 4.0 fy)) 0.45 0.15))
  (list wp1 wp2 wp3))
