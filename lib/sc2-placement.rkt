#lang racket/base

;; =============================================================================
;; `lib/sc2-placement.rkt`
;; Structure Placement, Wall-In Solvers, Footprint Reservation, Pylon Power,
;; Creep Highway Anchoring, and Bayesian Uncamped Expansion Pad Selection.
;; =============================================================================

(require racket/match
         racket/list
         racket/math
         racket/set
         "sc2-types.rkt"
         (except-in "sc2-geometry.rkt" aabb-overlaps?)
         (except-in "sc2-pathing.rkt"
                    grid-cell-positive?
                    grid-height-val
                    extract-map-grid-accessors
                    footprint-buildable-at-height?)
         "sc2-bayesian.rkt"
         "sc2-game-constants.rkt")

(provide
 ;; Baba CSP Choke Wall-In Solver, Terrain-Grid Main-Ramp & Matchup Wall Solvers
 PROTOSS-FFE-BUILDINGS
 TERRAN-BARRACKS-DEPOT-BUILDINGS
 (struct-out wall-placement)
 (struct-out wall-solution)
 wall-grid-fingerprint
 find-main-ramp-geometry
 solve-terran-ramp-wall-analytical
 solve-terran-ramp-wall
 compute-natural-exit-direction
 solve-protoss-matchup-wall-analytical
 find-natural-choke-candidates
 protoss-wall-valid-on-grids?
 solve-protoss-wall-candidate-on-grids
 solve-protoss-main-ramp-on-grids
 should-wall-main-ramp-vs-random?
 solve-protoss-matchup-wall
 solve-choke-wall-in
 wall-solution-valid-ref
 wall-solution-zergling-tight-ref
 wall-solution-max-gap-ref
 wall-solution-placements-ref

 ;; Off-Path Stealth Proxy Placement
 compute-off-path-proxy-candidates
 compute-off-path-proxy-site

 ;; Footprint Reservation, Terran Add-on Clearance & Spiral Build-Site Placement
 terran-addon-pad-pos
 terran-addon-pad-aabb
 terran-facility-has-addon?
 make-wall-reserved-aabbs
 wall-aabbs-for-build
 make-build-site-aabb
 prune-expired-aabbs
 collect-placement-blocking-aabbs
 placement-point-overlaps-expansion-pad?
 placement-in-playable-bounds?
 placement-site-free?
 solve-spiral-placement
 solve-pro-simcity-layout-placement
 select-worker-drill-stack-mineral-patch

 ;; Pylon Power & Protoss Placement Anchors
 pylon-powers-point?
 find-unpowered-structures
 emergency-inmain-supply-anchor
 select-pylon-power-anchor

 ;; Zerg Creep Highway & Safe Build Anchors
 nudge-off-expansion-pads
 next-creep-highway-target
 safe-zerg-build-anchor

 ;; Bayesian Expansion Pad Scoring & Uncamped Pad Selection
 pad->xy
 pad-already-owned?
 pad-camped-posterior
 pad-camped-by-enemy?
 select-uncamped-expansion-pad)

(define safe-coord safe-tile-coord)

;; Untyped zero-contract grid helpers avoiding Typed/Untyped `wrap-grid-ref` chaperones.
(define (grid-cell-positive? v)
  (cond
    [(real? v) (> v 0)]
    [(boolean? v) v]
    [else (not (not v))]))

(define (grid-height-val href ix iy [default 0.0])
  (if (procedure? href)
      (let ([v (href ix iy)])
        (exact->inexact (if (real? v) v default)))
      (exact->inexact default)))

(define (extract-map-grid-accessors map-grids)
  (define (valid-ref2 proc)
    (and (procedure? proc) (procedure-arity-includes? proc 2) proc))
  (cond
    [(not (hash? map-grids))
     (values #f 0 0 #f #f #f)]
    [else
     (define rw (hash-ref map-grids 'width 256))
     (define rh (hash-ref map-grids 'height 256))
     (define w (exact-floor (if (and (real? rw) (rational? rw)) rw 256.0)))
     (define h (exact-floor (if (and (real? rh) (rational? rh)) rh 256.0)))
     (define pref (valid-ref2 (or (hash-ref map-grids 'pathing-ref #f)
                                  (hash-ref map-grids 'pathing-pred #f))))
     (define bref (valid-ref2 (or (hash-ref map-grids 'placement-ref #f)
                                  (hash-ref map-grids 'placement-pred #f))))
     (define href (valid-ref2 (or (hash-ref map-grids 'height-ref #f)
                                  (hash-ref map-grids 'height-pred #f))))
     (values (and (> w 0) (> h 0) (procedure? pref) (procedure? bref))
             w h pref bref href)]))

(define (footprint-buildable-at-height? cx cy hw hh w h bref href target-h
                                        [check-height? #t]
                                        [pref #f])
  (define fcx (exact->inexact cx))
  (define fcy (exact->inexact cy))
  (define fhw (exact->inexact hw))
  (define fhh (exact->inexact hh))
  (define fth (exact->inexact target-h))
  (define x0 (exact-round (- fcx fhw)))
  (define x1 (exact-round (+ fcx fhw)))
  (define y0 (exact-round (- fcy fhh)))
  (define y1 (exact-round (+ fcy fhh)))
  (define total-cells (* (- x1 x0) (- y1 y0)))
  (define bref-ok? (and (procedure? bref) (procedure-arity-includes? bref 2)))
  (define pref-ok? (and (procedure? pref) (procedure-arity-includes? pref 2)))
  (define href-ok? (and check-height? (procedure? href) (procedure-arity-includes? href 2)))
  (cond
    [(not (and bref-ok? (>= x0 0) (<= x1 w) (>= y0 0) (<= y1 h) (> total-cells 0)))
     #f]
    [else
     (let loop-x ([ix x0] [min-th +inf.0] [max-th -inf.0] [pathable-cells 0])
       (cond
         [(>= ix x1)
          (and (or (not pref-ok?) (>= (* 2 pathable-cells) total-cells))
               (or (not check-height?)
                   (not href-ok?)
                   (> min-th max-th)
                   (<= (- max-th min-th) 1.5)))]
         [else
          (let loop-y ([iy y0] [mn min-th] [mx max-th] [pc pathable-cells])
            (cond
              [(>= iy y1) (loop-x (add1 ix) mn mx pc)]
              [(not (grid-cell-positive? (bref ix iy))) #f]
              [else
               (define next-pc (if (and pref-ok? (grid-cell-positive? (pref ix iy))) (add1 pc) pc))
               (if href-ok?
                   (let* ([v (href ix iy)]
                          [th (if (real? v) (exact->inexact v) fth)])
                     (if (<= (abs (- th fth)) 1.75)
                         (loop-y (add1 iy) (min mn th) (max mx th) next-pc)
                         #f))
                   (loop-y (add1 iy) mn mx next-pc))]))]))]))

;; =============================================================================
;; 1. Baba CSP Choke Wall-In Solver & Orientation-Aware Ramp/Choke Solvers
;;    Zergling width = 0.75 tiles => gap <= 15 is zergling-tight!
;;
;;    Terran Add-on Asymmetry:
;;    In SC2 LotV, a Barracks/Factory/Starport is 3x3 (centered at (bx, by))
;;    and its TechLab/Reactor is 2x2 ALWAYS attached on the East (+X) side at
;;    (bx + 2.5, by - 0.5).
;;    - When ramp descends West (ramp-dx < 0, high ground is East +X):
;;      Barracks sits at ramp center and its East add-on tucks safely inside
;;      the high-ground main base behind the wall.
;;    - When ramp descends East (ramp-dx >= 0, high ground is West -X):
;;      Barracks shifts West onto high ground so its East add-on seals the
;;      middle wall slot between the two 2x2 corner Supply Depots.
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

;; Computes a cache key fingerprint from map-grid samples around main and natural bases.
(define (wall-grid-fingerprint map-grids base-x base-y nat-x nat-y)
  (define-values (ok? w h pref bref href) (extract-map-grid-accessors map-grids))
  (cond
    [(not (hash? map-grids)) #f]
    [else
     (define eff-w (if (> w 0) w (exact-floor (exact->inexact (hash-ref map-grids 'width 256)))))
     (define eff-h (if (> h 0) h (exact-floor (exact->inexact (hash-ref map-grids 'height 256)))))
     (define (sample fx fy)
       (define ix (max 0 (min (sub1 (max 1 eff-w)) (exact-floor (exact->inexact fx)))))
       (define iy (max 0 (min (sub1 (max 1 eff-h)) (exact-floor (exact->inexact fy)))))
       (list (and ok? (grid-cell-positive? (pref ix iy)))
             (and ok? (grid-cell-positive? (bref ix iy)))
             (round (grid-height-val href ix iy 0.0))))
     (define (cell-sig fx fy)
       (define ix (max 0 (min (sub1 (max 1 eff-w)) (exact-floor (exact->inexact fx)))))
       (define iy (max 0 (min (sub1 (max 1 eff-h)) (exact-floor (exact->inexact fy)))))
       (bitwise-ior (if (and ok? (grid-cell-positive? (pref ix iy))) 1 0)
                    (if (and ok? (grid-cell-positive? (bref ix iy))) 2 0)))
     (define nat-mask
       (let ()
         (define acc 0)
         (define-syntax-rule (push-pt! fx fy)
           (set! acc (+ (* acc 4) (cell-sig fx fy))))
         (for ([off (in-range -12 13)])
           (push-pt! (+ nat-x off) nat-y)
           (push-pt! (+ nat-x off) (+ nat-y 6.0))
           (push-pt! (+ nat-x off) (+ nat-y 8.0))
           (push-pt! (+ nat-x off) (+ nat-y 10.0))
           (push-pt! (+ nat-x off) (- nat-y 8.0))
           (push-pt! nat-x (+ nat-y off))
           (push-pt! (+ nat-x 6.0) (+ nat-y off))
           (push-pt! (+ nat-x 8.0) (+ nat-y off))
           (push-pt! (+ nat-x 10.0) (+ nat-y off))
           (push-pt! (- nat-x 8.0) (+ nat-y off))
           (push-pt! (+ nat-x off) (+ nat-y off))
           (push-pt! (+ nat-x off) (- nat-y off)))
         acc))
     (define mx (+ base-x (* 0.35 (- nat-x base-x))))
     (define my (+ base-y (* 0.35 (- nat-y base-y))))
     (list eff-w eff-h
           nat-mask
           (sample base-x base-y)
           (sample nat-x nat-y)
           (sample mx my)
           (sample (+ mx 2.0) (- my 2.0))
           (sample (+ nat-x 8.0) nat-y)
           (sample (- nat-x 8.0) (- nat-y 4.0))
           (sample nat-x (+ nat-y 8.0))
           (sample (+ base-x 15.0) (- base-y 8.0)))]))

;; Identifies main ramp center, outward ramp direction, top plateau tiles, and BFS anchors.
(define (find-main-ramp-geometry base-x base-y nat-x nat-y [map-grids #f])
  (define bx-f (exact->inexact base-x))
  (define by-f (exact->inexact base-y))
  (define nx-f (exact->inexact nat-x))
  (define ny-f (exact->inexact nat-y))
  (define dx (- nx-f bx-f))
  (define dy (- ny-f by-f))
  (define dist (max 1.0 (sqrt (+ (* dx dx) (* dy dy)))))
  (define ux (/ dx dist))
  (define uy (/ dy dist))
  (define fallback-rx (+ bx-f (* 0.32 dx)))
  (define fallback-ry (+ by-f (* 0.32 dy)))
  (define-values (grids-ok? w h pref bref href) (extract-map-grid-accessors map-grids))
  (cond
    [grids-ok?
     (define b-ix (max 0 (min (sub1 (max 1 w)) (exact-floor bx-f))))
     (define b-iy (max 0 (min (sub1 (max 1 h)) (exact-floor by-f))))
     (define n-ix (max 0 (min (sub1 (max 1 w)) (exact-floor nx-f))))
     (define n-iy (max 0 (min (sub1 (max 1 h)) (exact-floor ny-f))))
     (define h-main (grid-height-val href b-ix b-iy 128.0))
     (define h-nat  (grid-height-val href n-ix n-iy 112.0))
     (define h-lo   (min h-main h-nat))
     (define h-hi   (max h-main h-nat))
     (define mid-x  (+ bx-f (* 0.35 dx)))
     (define mid-y  (+ by-f (* 0.35 dy)))
     (define sx0 (max 1 (min (- (exact-round bx-f) 26) (- (exact-round mid-x) 20))))
     (define sx1 (min (- w 1) (max (+ (exact-round bx-f) 26) (+ (exact-round mid-x) 20))))
     (define sy0 (max 1 (min (- (exact-round by-f) 26) (- (exact-round mid-y) 20))))
     (define sy1 (min (- h 1) (max (+ (exact-round by-f) 26) (+ (exact-round mid-y) 20))))
     (define sw (max 1 (- sx1 sx0)))
     (define sh (max 1 (- sy1 sy0)))
     (define sn (* sw sh))
     (define b-dist (make-vector sn -1))
     (define hg-plat (make-bytes sn 0))
     (define qbuf (make-vector sn 0))

     (define seed-pt
       (let ([slx (max 0 (min (sub1 sw) (- b-ix sx0)))]
             [sly (max 0 (min (sub1 sh) (- b-iy sy0)))])
         (if (grid-cell-positive? (pref (+ sx0 slx) (+ sy0 sly)))
             (cons slx sly)
             (for*/first ([r (in-range 1 5)]
                          [dy-i (in-range (- r) (add1 r))]
                          [dx-i (in-range (- r) (add1 r))]
                          #:do [(define lx (+ slx dx-i))
                                (define ly (+ sly dy-i))]
                          #:when (and (>= lx 0) (< lx sw) (>= ly 0) (< ly sh)
                                      (grid-cell-positive? (pref (+ sx0 lx) (+ sy0 ly)))))
               (cons lx ly)))))

     (when seed-pt
       (define sidx (+ (* (cdr seed-pt) sw) (car seed-pt)))
       (vector-set! b-dist sidx 0)
       (bytes-set! hg-plat sidx 1)
       (vector-set! qbuf 0 sidx)
       (let loop ([head 0] [tail 1])
         (when (< head tail)
           (define cur (vector-ref qbuf head))
           (define d0 (vector-ref b-dist cur))
           (define cy (quotient cur sw))
           (define cx (remainder cur sw))
           (define cur-hg? (= (bytes-ref hg-plat cur) 1))
           (define tail1 tail)
           (when (< d0 38)
             (define-syntax-rule (step! nx ny)
               (when (and (>= nx 0) (< nx sw) (>= ny 0) (< ny sh))
                 (define nidx (+ (* ny sw) nx))
                 (define gx (+ sx0 nx))
                 (define gy (+ sy0 ny))
                 (when (and (= (vector-ref b-dist nidx) -1)
                            (grid-cell-positive? (pref gx gy)))
                   (vector-set! b-dist nidx (add1 d0))
                   (when (and cur-hg?
                              (grid-cell-positive? (bref gx gy))
                              (or (not (procedure? href))
                                  (<= (- h-hi h-lo) 2.0)
                                  (<= (abs (- (grid-height-val href gx gy h-main) h-main)) 1.75)))
                     (bytes-set! hg-plat nidx 1))
                   (vector-set! qbuf tail1 nidx)
                   (set! tail1 (add1 tail1)))))
             (step! (add1 cx) cy)
             (step! (sub1 cx) cy)
             (step! cx (add1 cy))
             (step! cx (sub1 cy)))
           (loop (add1 head) tail1))))

     (define (borders-hg-plateau? gx gy)
       (for*/or ([dy-i (in-range -2 3)]
                 [dx-i (in-range -2 3)])
         (define lx (- (+ gx dx-i) sx0))
         (define ly (- (+ gy dy-i) sy0))
         (and (>= lx 0) (< lx sw) (>= ly 0) (< ly sh)
              (= (bytes-ref hg-plat (+ (* ly sw) lx)) 1))))

     (define (reachable-from-main? gx gy)
       (define lx (- gx sx0))
       (define ly (- gy sy0))
       (and (>= lx 0) (< lx sw) (>= ly 0) (< ly sh)
            (>= (vector-ref b-dist (+ (* ly sw) lx)) 0)))

     (define strict-ramp-candidates
       (if (> (- h-hi h-lo) 1.0)
           (for*/list ([iy (in-range sy0 sy1)]
                       [ix (in-range sx0 sx1)]
                       #:when (and (grid-cell-positive? (pref ix iy))
                                   (not (grid-cell-positive? (bref ix iy)))
                                   (or (not seed-pt) (reachable-from-main? ix iy))
                                   (let ([th (grid-height-val href ix iy h-lo)])
                                     (and (> th (+ h-lo 0.25))
                                          (< th (- h-hi 0.25))))))
             (cons ix iy))
           '()))
     (define hg-bordered-strict
       (filter (lambda (pt) (borders-hg-plateau? (car pt) (cdr pt))) strict-ramp-candidates))
     (define raw-ramp-candidates
       (cond
         [(pair? hg-bordered-strict) hg-bordered-strict]
         [(pair? strict-ramp-candidates) strict-ramp-candidates]
         [else
          (for*/list ([iy (in-range sy0 sy1)]
                      [ix (in-range sx0 sx1)]
                      #:when (and (grid-cell-positive? (pref ix iy))
                                  (not (grid-cell-positive? (bref ix iy)))
                                  (or (not seed-pt) (borders-hg-plateau? ix iy))
                                  (<= (dist2d (+ ix 0.5) (+ iy 0.5) bx-f by-f) 24.0)))
            (cons ix iy))]))
     (define nearest-ramp-seed
       (and (pair? raw-ramp-candidates)
            (argmin (lambda (pt)
                      (define lx (- (car pt) sx0))
                      (define ly (- (cdr pt) sy0))
                      (define bd (if (and (>= lx 0) (< lx sw) (>= ly 0) (< ly sh))
                                     (max 0 (vector-ref b-dist (+ (* ly sw) lx)))
                                     30))
                      (+ (* 0.6 bd)
                         (* 0.4 (dist2d (+ (car pt) 0.5) (+ (cdr pt) 0.5) mid-x mid-y))))
                    raw-ramp-candidates)))
     (define ramp-tiles
       (if nearest-ramp-seed
           (filter (lambda (pt)
                     (<= (dist2d (car pt) (cdr pt)
                                 (car nearest-ramp-seed) (cdr nearest-ramp-seed))
                         8.5))
                   raw-ramp-candidates)
           '()))
     (define top-tiles
       (if (pair? ramp-tiles)
           (for*/list ([iy (in-range sy0 sy1)]
                       [ix (in-range sx0 sx1)]
                       #:when (and (grid-cell-positive? (bref ix iy))
                                   (grid-cell-positive? (pref ix iy))
                                   (or (not seed-pt)
                                       (= (bytes-ref hg-plat (+ (* (- iy sy0) sw) (- ix sx0))) 1))
                                   (or (not (procedure? href))
                                       (<= (abs (- (grid-height-val href ix iy h-main) h-main)) 1.75))
                                   (ormap (lambda (rt)
                                            (and (<= (abs (- ix (car rt))) 2)
                                                 (<= (abs (- iy (cdr rt))) 2)))
                                          ramp-tiles)))
             (cons ix iy))
           '()))
     (cond
       [(and (pair? ramp-tiles) (pair? top-tiles))
        (define n-r (length ramp-tiles))
        (define rx (/ (for/sum ([pt (in-list ramp-tiles)]) (+ (car pt) 0.5)) n-r))
        (define ry (/ (for/sum ([pt (in-list ramp-tiles)]) (+ (cdr pt) 0.5)) n-r))
        (define n-t (length top-tiles))
        (define tcx (/ (for/sum ([pt (in-list top-tiles)]) (+ (car pt) 0.5)) n-t))
        (define tcy (/ (for/sum ([pt (in-list top-tiles)]) (+ (cdr pt) 0.5)) n-t))
        (define vdx (- rx tcx))
        (define vdy (- ry tcy))
        (define vmag (sqrt (+ (* vdx vdx) (* vdy vdy))))
        (define rdx (if (>= vmag 0.2) (/ vdx vmag) ux))
        (define rdy (if (>= vmag 0.2) (/ vdy vmag) uy))

        (define hg-src
          (or (and (>= (dist2d bx-f by-f rx ry) 7.5)
                   (<= (dist2d bx-f by-f rx ry) 18.0)
                   (cons (+ b-ix 0.5) (+ b-iy 0.5)))
              (let ([best-hg #f]
                    [best-hg-sc -1e9])
                (for* ([ly (in-range sh)]
                       [lx (in-range sw)]
                       #:when (= (bytes-ref hg-plat (+ (* ly sw) lx)) 1))
                  (define wx (+ sx0 lx 0.5))
                  (define wy (+ sy0 ly 0.5))
                  (define dr (dist2d wx wy rx ry))
                  (when (and (>= dr 7.5) (<= dr 14.5))
                    (define sc (- 50.0 (abs (- dr 9.5)) (* 0.25 (dist2d wx wy bx-f by-f))))
                    (when (> sc best-hg-sc)
                      (set! best-hg-sc sc)
                      (set! best-hg (cons wx wy)))))
                best-hg)
              (cons (- rx (* 9.0 rdx)) (- ry (* 9.0 rdy)))))

        (define lg-dst
          (let ([best-lg #f]
                [best-lg-sc -1e9])
            (for* ([ly (in-range sh)]
                   [lx (in-range sw)])
              (define idx (+ (* ly sw) lx))
              (define gx (+ sx0 lx))
              (define gy (+ sy0 ly))
              (when (and (>= (vector-ref b-dist idx) 0)
                         (= (bytes-ref hg-plat idx) 0)
                         (grid-cell-positive? (pref gx gy))
                         (or (not (procedure? href))
                             (<= (- h-hi h-lo) 2.0)
                             (<= (abs (- (grid-height-val href gx gy h-nat) h-nat)) 2.0)))
                (define wx (+ gx 0.5))
                (define wy (+ gy 0.5))
                (define dr (dist2d wx wy rx ry))
                (define proj (+ (* (- wx rx) rdx) (* (- wy ry) rdy)))
                (when (and (>= dr 5.5) (<= dr 13.5) (>= proj 2.5))
                  (define sc (+ (if (grid-cell-positive? (bref gx gy)) 20.0 0.0)
                                (- 40.0 (abs (- dr 7.5)))))
                  (when (> sc best-lg-sc)
                    (set! best-lg-sc sc)
                    (set! best-lg (cons wx wy))))))
            (or best-lg (cons (+ rx (* 7.5 rdx)) (+ ry (* 7.5 rdy))))))

        (hash 'ramp-x rx
              'ramp-y ry
              'ramp-dx rdx
              'ramp-dy rdy
              'hg-src hg-src
              'lg-dst lg-dst
              'top-tiles top-tiles
              'ramp-tiles ramp-tiles
              'h-main h-main
              'h-nat h-nat
              'grid-solved? #t)]
       [else
        (hash 'ramp-x fallback-rx
              'ramp-y fallback-ry
              'ramp-dx ux
              'ramp-dy uy
              'top-tiles '()
              'ramp-tiles '()
              'h-main h-main
              'h-nat h-nat
              'grid-solved? #f)])]
    [else
     (hash 'ramp-x fallback-rx
           'ramp-y fallback-ry
           'ramp-dx ux
           'ramp-dy uy
           'top-tiles '()
           'ramp-tiles '()
           'h-main 0.0
           'h-nat 0.0
           'grid-solved? #f)]))

(define TERRAN-RAMP-WALL-CACHE (make-hash))

;; Computes an analytical Barracks + 2 Supply Depot ramp wall layout when grids are absent.
(define (solve-terran-ramp-wall-analytical base-x base-y nat-x nat-y)
  (define dx (exact->inexact (- nat-x base-x)))
  (define dy (exact->inexact (- nat-y base-y)))
  (define dist (max 1.0 (sqrt (+ (* dx dx) (* dy dy)))))
  (define ux (/ dx dist))
  (define uy (/ dy dist))
  (define crest-x (+ base-x (* 0.32 dx)))
  (define crest-y (+ base-y (* 0.32 dy)))
  (define east-facing-ramp? (>= dx 0.0))
  (define raw-bx (if east-facing-ramp? (- crest-x 2.0) (- crest-x (* 0.5 ux))))
  (define raw-by (if east-facing-ramp? (+ crest-y 0.5) (- crest-y (* 0.5 uy))))
  (define bx (snap-3x3-coord raw-bx))
  (define by (snap-3x3-coord raw-by))
  (define addon-x (+ bx SC2-TERRAN-ADDON-OFFSET-X))
  (define addon-y (+ by SC2-TERRAN-ADDON-OFFSET-Y))
  (define d1-x (snap-2x2-coord (if east-facing-ramp? (+ bx 0.5) (- bx 0.5))))
  (define d1-y (snap-2x2-coord (+ by 2.5)))
  (define d2-x (snap-2x2-coord (- bx 0.5)))
  (define d2-y (snap-2x2-coord (- by 2.5)))
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
        'production-origin (cons prod-x prod-y)
        'grid-solved? #f))

;; Solves an orientation-aware Terran Barracks + 2 Depot wall using map grids with analytical fallback.
(define (solve-terran-ramp-wall base-x base-y nat-x nat-y #:map-grids [map-grids #f])
  (define cache-key
    (list 'terran
          (round base-x) (round base-y)
          (round nat-x) (round nat-y)
          (wall-grid-fingerprint map-grids base-x base-y nat-x nat-y)))
  (cond
    [(hash-ref TERRAN-RAMP-WALL-CACHE cache-key #f) => values]
    [else
     (define-values (grids-ok? w h pref bref href) (extract-map-grid-accessors map-grids))
     (define result
       (cond
         [(not grids-ok?)
          (solve-terran-ramp-wall-analytical base-x base-y nat-x nat-y)]
         [else
          (define rgeom (find-main-ramp-geometry base-x base-y nat-x nat-y map-grids))
          (cond
            [(not (hash-ref rgeom 'grid-solved? #f))
             (solve-terran-ramp-wall-analytical base-x base-y nat-x nat-y)]
            [else
             (define rx (hash-ref rgeom 'ramp-x))
             (define ry (hash-ref rgeom 'ramp-y))
             (define rdx (hash-ref rgeom 'ramp-dx))
             (define rdy (hash-ref rgeom 'ramp-dy))
             (define h-main (hash-ref rgeom 'h-main))
             (define h-nat (hash-ref rgeom 'h-nat))
             (define top-tiles (hash-ref rgeom 'top-tiles '()))
             (define ramp-tiles (hash-ref rgeom 'ramp-tiles '()))
             (define ramp-tile-set (for/set ([rt (in-list ramp-tiles)]) rt))
             (define hg-src (hash-ref rgeom 'hg-src (cons (- rx (* 9.0 rdx)) (- ry (* 9.0 rdy)))))
             (define lg-dst (hash-ref rgeom 'lg-dst (cons (+ rx (* 7.5 rdx)) (+ ry (* 7.5 rdy)))))
             (define (hg-cell-ok? ix iy)
               (and (grid-cell-positive? (bref ix iy))
                    (not (set-member? ramp-tile-set (cons ix iy)))
                    (or (not (procedure? href))
                        (<= (abs (- (grid-height-val href ix iy h-main) h-main)) 1.75))))
             (define (lg-cell-ok? ix iy)
               (and (not (set-member? ramp-tile-set (cons ix iy)))
                    (or (not (procedure? href))
                        (<= (abs (- h-main h-nat)) 2.0)
                        (<= (abs (- (grid-height-val href ix iy h-nat) h-nat)) 2.0))))
             (define bfs-ctx
               (make-local-4conn-bfs rx ry
                                     (car hg-src) (cdr hg-src)
                                     (car lg-dst) (cdr lg-dst)
                                     w h pref
                                     #:snap-src-pred hg-cell-ok?
                                     #:snap-dst-pred lg-cell-ok?))
             (cond
               [(not (hash-ref bfs-ctx 'valid? #f))
                (solve-terran-ramp-wall-analytical base-x base-y nat-x nat-y)]
               [else
                (define seals-cleanly? (hash-ref bfs-ctx 'seals-cleanly?))
                (define (strict-hg-footprint? cx cy hw hh)
                  (and (footprint-buildable-at-height? cx cy hw hh w h bref href h-main #t pref)
                       (let ([x0 (exact-round (- cx hw))]
                             [x1 (exact-round (+ cx hw))]
                             [y0 (exact-round (- cy hh))]
                             [y1 (exact-round (+ cy hh))])
                         (for*/and ([ix (in-range x0 x1)]
                                    [iy (in-range y0 y1)])
                           (not (set-member? ramp-tile-set (cons ix iy)))))))
                (define (near-top-tile? cx cy max-d)
                  (ormap (lambda (pt)
                           (<= (dist2d cx cy (+ (car pt) 0.5) (+ (cdr pt) 0.5)) max-d))
                         top-tiles))
                (define tang-x (- rdy))
                (define tang-y rdx)
                (define (tangent-proj cx cy)
                  (+ (* (- cx rx) tang-x) (* (- cy ry) tang-y)))

                (define rax-cands
                  (for*/list ([dy-i (in-range -7 8)]
                              [dx-i (in-range -7 8)]
                              #:do [(define bx (+ (floor rx) dx-i 0.5))
                                    (define by (+ (floor ry) dy-i 0.5))
                                    (define ax (+ bx SC2-TERRAN-ADDON-OFFSET-X))
                                    (define ay (+ by SC2-TERRAN-ADDON-OFFSET-Y))
                                    (define addon-hg?
                                      (and (footprints-disjoint? ax ay 1.0 1.0 base-x base-y 2.5 2.5)
                                           (strict-hg-footprint? ax ay 1.0 1.0)))]
                              #:when (and (or (near-top-tile? bx by 3.6)
                                              (and addon-hg? (near-top-tile? ax ay 2.6)))
                                          (footprints-disjoint? bx by 1.5 1.5 base-x base-y 2.5 2.5)
                                          (strict-hg-footprint? bx by 1.5 1.5)))
                    (list bx by ax ay addon-hg? (tangent-proj bx by))))

                (define depot-cands
                  (for*/list ([dy-i (in-range -7 8)]
                              [dx-i (in-range -7 8)]
                              #:do [(define dx0 (exact->inexact (+ (exact-round rx) dx-i)))
                                    (define dy0 (exact->inexact (+ (exact-round ry) dy-i)))]
                              #:when (and (near-top-tile? dx0 dy0 3.6)
                                          (footprints-disjoint? dx0 dy0 1.0 1.0 base-x base-y 2.5 2.5)
                                          (strict-hg-footprint? dx0 dy0 1.0 1.0)))
                    (list dx0 dy0 (tangent-proj dx0 dy0))))

                (define best-score -1e9)
                (define best-sol #f)
                (for ([rc (in-list rax-cands)])
                  (match-define (list bx by ax ay addon-hg? r-proj) rc)
                  (define left-depots
                    (filter (lambda (dc)
                              (match-define (list d1x d1y d1-proj) dc)
                              (and (< d1-proj (- r-proj 0.25))
                                   (<= (dist2d d1x d1y bx by) 5.6)
                                   (footprints-disjoint? d1x d1y 1.0 1.0 bx by 1.5 1.5)))
                            depot-cands))
                  (define right-depots
                    (filter (lambda (dc)
                              (match-define (list d2x d2y d2-proj) dc)
                              (and (> d2-proj (+ r-proj 0.25))
                                   (<= (dist2d d2x d2y bx by) 5.6)
                                   (footprints-disjoint? d2x d2y 1.0 1.0 bx by 1.5 1.5)))
                            depot-cands))
                  (for* ([d1 (in-list left-depots)]
                         [d2 (in-list right-depots)])
                    (match-define (list d1x d1y _) d1)
                    (match-define (list d2x d2y _) d2)
                    (when (footprints-disjoint? d1x d1y 1.0 1.0 d2x d2y 1.0 1.0)
                      (define addon-clear?
                        (and addon-hg?
                             (footprints-disjoint? d1x d1y 1.0 1.0 ax ay 1.0 1.0)
                             (footprints-disjoint? d2x d2y 1.0 1.0 ax ay 1.0 1.0)))
                      (define d1-touches-rax?
                        (<= (footprints-touch-gap d1x d1y 1.0 1.0 bx by 1.5 1.5) 0.05))
                      (define d2-touches-rax?
                        (<= (footprints-touch-gap d2x d2y 1.0 1.0 bx by 1.5 1.5) 0.05))
                      (define d1-touches-addon?
                        (and addon-clear?
                             (<= (footprints-touch-gap d1x d1y 1.0 1.0 ax ay 1.0 1.0) 0.05)))
                      (define d2-touches-addon?
                        (and addon-clear?
                             (<= (footprints-touch-gap d2x d2y 1.0 1.0 ax ay 1.0 1.0) 0.05)))
                      (define bare-rects
                        (list (list d1x d1y 1.0 1.0)
                              (list bx by 1.5 1.5)
                              (list d2x d2y 1.0 1.0)))
                      (define seals-bare?
                        (and d1-touches-rax?
                             d2-touches-rax?
                             (seals-cleanly? bare-rects)))
                      (define seals-with-addon?
                        (and (not seals-bare?)
                             addon-clear?
                             (>= rdx 0.0)
                             (or d1-touches-rax? d1-touches-addon?)
                             (or d2-touches-rax? d2-touches-addon?)
                             (seals-cleanly? (cons (list ax ay 1.0 1.0) bare-rects))))
                      (when (or seals-bare? seals-with-addon?)
                        (define edge-bonus
                          (+ (if (footprints-share-edge? d1x d1y 1.0 1.0 bx by 1.5 1.5) 60.0 0.0)
                             (if (footprints-share-edge? d2x d2y 1.0 1.0 bx by 1.5 1.5) 60.0 0.0)))
                        (define dist-pen
                          (+ (dist2d bx by rx ry)
                             (* 0.65 (dist2d d1x d1y rx ry))
                             (* 0.65 (dist2d d2x d2y rx ry))))
                        (define tier-bonus
                          (cond
                            [(and seals-bare? addon-clear?) 2000.0]
                            [seals-bare?                    1200.0]
                            [else                            400.0]))
                        (define sc
                          (+ tier-bonus
                             edge-bonus
                             (- (* 10.0 dist-pen))))
                        (when (> sc best-score)
                          (set! best-score sc)
                          (set! best-sol (list d1x d1y d2x d2y bx by ax ay addon-clear? seals-with-addon?)))))))

                (cond
                  [best-sol
                   (match-define (list d1x d1y d2x d2y bx by ax ay addon-clear? seals-with-addon?) best-sol)
                   (define east-facing? (or (>= rdx 0.0) seals-with-addon?))
                   (define dy-tot (exact->inexact (- nat-y base-y)))
                   (define prod-x (snap-3x3-coord (if east-facing? (- base-x 7.5) (+ base-x 4.5))))
                   (define prod-y (snap-3x3-coord (if (>= dy-tot 0.0) (- base-y 4.5) (+ base-y 4.5))))
                   (hash 'orientation (if east-facing?
                                          'east-facing-ramp-addon-walls
                                          'west-facing-ramp-addon-inside)
                         'east-facing-ramp? east-facing?
                         'addon-clear? addon-clear?
                         'ramp-x rx
                         'ramp-y ry
                         'ramp-dx rdx
                         'ramp-dy rdy
                         'depot-1 (cons d1x d1y)
                         'depot-2 (cons d2x d2y)
                         'barracks (cons bx by)
                         'barracks-addon (cons ax ay)
                         'production-origin (cons prod-x prod-y)
                         'grid-solved? #t)]
                  [else
                   (solve-terran-ramp-wall-analytical base-x base-y nat-x nat-y)])])])]))
     (hash-set! TERRAN-RAMP-WALL-CACHE cache-key result)
     result]))

(define PROTOSS-MATCHUP-WALL-CACHE (make-hash))

;; Computes natural exit direction unit vector biased outward from main toward enemy/center.
(define (compute-natural-exit-direction bx-f by-f nx-f ny-f ex-f ey-f [map-w 200.0] [map-h 200.0])
  (define mdx (- nx-f bx-f))
  (define mdy (- ny-f by-f))
  (define mdist (sqrt (+ (* mdx mdx) (* mdy mdy))))
  (define edx (- ex-f nx-f))
  (define edy (- ey-f ny-f))
  (define edist (max 1.0 (sqrt (+ (* edx edx) (* edy edy)))))
  (define eux (/ edx edist))
  (define euy (/ edy edist))
  (cond
    [(< mdist 1.0)
     (values eux euy)]
    [else
     (define mux (/ mdx mdist))
     (define muy (/ mdy mdist))
     (define dot-me (+ (* mux eux) (* muy euy)))
     (cond
       [(< dot-me -0.25)
        (values mux muy)]
       [else
        (define mcx (* 0.5 (exact->inexact map-w)))
        (define mcy (* 0.5 (exact->inexact map-h)))
        (define cdx (- mcx nx-f))
        (define cdy (- mcy ny-f))
        (define cdist (max 1.0 (sqrt (+ (* cdx cdx) (* cdy cdy)))))
        (define h-raw-x (+ (* 0.75 eux) (* 0.25 (/ cdx cdist))))
        (define h-raw-y (+ (* 0.75 euy) (* 0.25 (/ cdy cdist))))
        (define h-back (min 0.0 (+ (* h-raw-x mux) (* h-raw-y muy))))
        (define hx (- h-raw-x (* h-back mux)))
        (define hy (- h-raw-y (* h-back muy)))
        (define hmag (sqrt (+ (* hx hx) (* hy hy))))
        (define rx (+ (* 0.72 mux) (if (> hmag 1e-6) (* 0.28 (/ hx hmag)) 0.0)))
        (define ry (+ (* 0.72 muy) (if (> hmag 1e-6) (* 0.28 (/ hy hmag)) 0.0)))
        (define rmag (max 1e-6 (sqrt (+ (* rx rx) (* ry ry)))))
        (values (/ rx rmag) (/ ry rmag))])]))

;; Computes an analytical Protoss matchup wall (main ramp vs natural choke) without map grids.
(define (solve-protoss-matchup-wall-analytical base-x base-y nat-x nat-y locus enemy-x enemy-y
                                               [map-w 200.0] [map-h 200.0])
  (define bx-f (exact->inexact base-x))
  (define by-f (exact->inexact base-y))
  (define nx-f (exact->inexact nat-x))
  (define ny-f (exact->inexact nat-y))
  (define ex-f (exact->inexact enemy-x))
  (define ey-f (exact->inexact enemy-y))
  (cond
    [(eq? locus 'natural-choke)
     (define-values (out-ux out-uy)
       (compute-natural-exit-direction bx-f by-f nx-f ny-f ex-f ey-f map-w map-h))
     (cond
       [(>= (abs out-uy) (abs out-ux))
        (define sy (if (>= out-uy 0.0) 1.0 -1.0))
        (define door-x (snap-3x3-coord (+ nx-f (* 9.0 out-ux))))
        (define door-y (snap-3x3-coord (+ ny-f (* 9.0 out-uy))))
        (define s1 (cons (- door-x 2.0) door-y))
        (define s2 (cons (+ door-x 2.0) door-y))
        (define px (snap-2x2-coord (+ door-x 0.5)))
        (define py (snap-2x2-coord (- door-y (* 3.5 sy))))
        (define park-x (- door-x (* 2.2 out-ux)))
        (define park-y (- door-y (* 2.2 sy)))
        (hash 'locus 'natural-choke
              'door (cons door-x door-y)
              'door-x door-x
              'door-y door-y
              'door-park (cons park-x park-y)
              'pylon (cons px py)
              'slot-1 s1
              'slot-2 s2
              'slot-3 #f
              'grid-solved? #f)]
       [else
        (define sx (if (>= out-ux 0.0) 1.0 -1.0))
        (define door-x (snap-3x3-coord (+ nx-f (* 9.0 out-ux))))
        (define door-y (snap-3x3-coord (+ ny-f (* 9.0 out-uy))))
        (define s1 (cons door-x (- door-y 2.0)))
        (define s2 (cons door-x (+ door-y 2.0)))
        (define px (snap-2x2-coord (- door-x (* 3.5 sx))))
        (define py (snap-2x2-coord (+ door-y 0.5)))
        (define park-x (- door-x (* 2.2 sx)))
        (define park-y (- door-y (* 2.2 out-uy)))
        (hash 'locus 'natural-choke
              'door (cons door-x door-y)
              'door-x door-x
              'door-y door-y
              'door-park (cons park-x park-y)
              'pylon (cons px py)
              'slot-1 s1
              'slot-2 s2
              'slot-3 #f
              'grid-solved? #f)])]
    [else
     (define dx (- nx-f bx-f))
     (define dy (- ny-f by-f))
     (define dist (max 1.0 (sqrt (+ (* dx dx) (* dy dy)))))
     (define ux (/ dx dist))
     (define uy (/ dy dist))
     (define crest-x (+ bx-f (* 0.32 dx)))
     (define crest-y (+ by-f (* 0.32 dy)))
     (define door-x (snap-3x3-coord crest-x))
     (define door-y (snap-3x3-coord crest-y))
     (cond
       [(>= (abs uy) (abs ux))
        (define sy (if (>= uy 0.0) 1.0 -1.0))
        (define s1 (cons (- door-x 2.0) door-y))
        (define s2 (cons (+ door-x 2.0) door-y))
        (define px (snap-2x2-coord (- door-x 0.5)))
        (define py (snap-2x2-coord (- door-y (* 3.5 sy))))
        (hash 'locus 'main-ramp
              'door (cons door-x door-y)
              'door-x door-x
              'door-y door-y
              'door-park (cons (- door-x (* 2.2 ux)) (- door-y (* 2.2 uy)))
              'pylon (cons px py)
              'slot-1 s1
              'slot-2 s2
              'slot-3 #f
              'grid-solved? #f)]
       [else
        (define sx (if (>= ux 0.0) 1.0 -1.0))
        (define s1 (cons door-x (- door-y 2.0)))
        (define s2 (cons door-x (+ door-y 2.0)))
        (define px (snap-2x2-coord (- door-x (* 3.5 sx))))
        (define py (snap-2x2-coord (- door-y 0.5)))
        (hash 'locus 'main-ramp
              'door (cons door-x door-y)
              'door-x door-x
              'door-y door-y
              'door-park (cons (- door-x (* 2.2 ux)) (- door-y (* 2.2 uy)))
              'pylon (cons px py)
              'slot-1 s1
              'slot-2 s2
              'slot-3 #f
              'grid-solved? #f)])]))

;; Traces walkable + buildable natural exit choke candidates via outward BFS and DAG backprop.
(define (find-natural-choke-candidates bx-f by-f nx-f ny-f ex-f ey-f w h pref bref href)
  (define b-ix (max 0 (min (sub1 w) (exact-floor bx-f))))
  (define b-iy (max 0 (min (sub1 h) (exact-floor by-f))))
  (define n-ix0 (max 0 (min (sub1 w) (exact-floor nx-f))))
  (define n-iy0 (max 0 (min (sub1 h) (exact-floor ny-f))))
  (define h-main (grid-height-val href b-ix b-iy 128.0))
  (define h-nat  (grid-height-val href n-ix0 n-iy0 112.0))
  (define mdist  (dist2d bx-f by-f nx-f ny-f))
  (define mux    (if (>= mdist 1.0) (/ (- nx-f bx-f) mdist) 1.0))
  (define muy    (if (>= mdist 1.0) (/ (- ny-f by-f) mdist) 0.0))
  (define-values (prior-ux prior-uy)
    (compute-natural-exit-direction bx-f by-f nx-f ny-f ex-f ey-f w h))

  (define win-r 28)
  (define sx0 (max 0 (- (exact-round nx-f) win-r)))
  (define sx1 (min w (+ (exact-round nx-f) win-r)))
  (define sy0 (max 0 (- (exact-round ny-f) win-r)))
  (define sy1 (min h (+ (exact-round ny-f) win-r)))
  (define sw (max 1 (- sx1 sx0)))
  (define sh (max 1 (- sy1 sy0)))
  (define sn (* sw sh))
  (define dist-v (make-vector sn -1))
  (define flat-nat? (make-bytes sn 0))
  (define qbuf (make-vector sn 0))

  (define (main-side-cell? gx gy)
    (define wx (+ gx 0.5))
    (define wy (+ gy 0.5))
    (define dm (dist2d wx wy bx-f by-f))
    (or (and (>= mdist 12.0) (<= dm 10.0))
        (and (> (abs (- h-main h-nat)) 3.0)
             (procedure? href)
             (<= (abs (- (grid-height-val href gx gy h-nat) h-main)) 2.0)
             (< dm (dist2d wx wy nx-f ny-f)))))

  (define seed-pt
    (let ([slx (max 0 (min (sub1 sw) (- n-ix0 sx0)))]
          [sly (max 0 (min (sub1 sh) (- n-iy0 sy0)))])
      (if (grid-cell-positive? (pref (+ sx0 slx) (+ sy0 sly)))
          (cons slx sly)
          (for*/first ([r (in-range 1 5)]
                       [dy-i (in-range (- r) (add1 r))]
                       [dx-i (in-range (- r) (add1 r))]
                       #:do [(define lx (+ slx dx-i))
                             (define ly (+ sly dy-i))]
                       #:when (and (>= lx 0) (< lx sw) (>= ly 0) (< ly sh)
                                   (grid-cell-positive? (pref (+ sx0 lx) (+ sy0 ly)))))
            (cons lx ly)))))

  (cond
    [(not seed-pt) '()]
    [else
     (define sidx (+ (* (cdr seed-pt) sw) (car seed-pt)))
     (vector-set! dist-v sidx 0)
     (bytes-set! flat-nat? sidx 1)
     (vector-set! qbuf 0 sidx)
     (define bfs-tail
       (let loop ([head 0] [tail 1])
         (if (>= head tail)
             tail
             (let* ([cur (vector-ref qbuf head)]
                    [d0 (vector-ref dist-v cur)]
                    [cy (quotient cur sw)]
                    [cx (remainder cur sw)]
                    [cgx (+ sx0 cx)]
                    [cgy (+ sy0 cy)]
                    [cur-th (grid-height-val href cgx cgy h-nat)]
                    [cur-flat? (= (bytes-ref flat-nat? cur) 1)]
                    [tail1 tail])
               (when (< d0 34)
                 (define-syntax-rule (step! nx ny)
                   (when (and (>= nx 0) (< nx sw) (>= ny 0) (< ny sh))
                     (define nidx (+ (* ny sw) nx))
                     (define ngx (+ sx0 nx))
                     (define ngy (+ sy0 ny))
                     (when (and (= (vector-ref dist-v nidx) -1)
                                (grid-cell-positive? (pref ngx ngy))
                                (not (main-side-cell? ngx ngy)))
                       (define nth (grid-height-val href ngx ngy h-nat))
                       (when (or (not (procedure? href))
                                 (<= (abs (- nth cur-th)) 16.5))
                         (vector-set! dist-v nidx (add1 d0))
                         (when (and cur-flat?
                                    (or (not (procedure? href))
                                        (<= (abs (- nth h-nat)) 1.75)))
                           (bytes-set! flat-nat? nidx 1))
                         (vector-set! qbuf tail1 nidx)
                         (set! tail1 (add1 tail1))))))
                 (step! (add1 cx) cy)
                 (step! (sub1 cx) cy)
                 (step! cx (add1 cy))
                 (step! cx (sub1 cy)))
               (loop (add1 head) tail1)))))

     (define reaches-outer (make-bytes sn 0))
     (define next-out-idx (make-vector sn -1))
     (for ([k (in-range bfs-tail)])
       (define idx (vector-ref qbuf k))
       (define d (vector-ref dist-v idx))
       (when (>= d 17)
         (define gx (+ sx0 (remainder idx sw)))
         (define gy (+ sy0 (quotient idx sw)))
         (define wx (+ gx 0.5))
         (define wy (+ gy 0.5))
         (when (and (>= (dist2d wx wy nx-f ny-f) 13.5)
                    (grid-cell-positive? (bref gx gy))
                    (or (< mdist 10.0)
                        (>= (dist2d wx wy bx-f by-f) (- mdist 1.0))))
           (bytes-set! reaches-outer idx 1)
           (vector-set! next-out-idx idx idx))))

     (for ([k (in-range (sub1 bfs-tail) -1 -1)])
       (define u (vector-ref qbuf k))
       (when (= (bytes-ref reaches-outer u) 0)
         (define du (vector-ref dist-v u))
         (define uy-l (quotient u sw))
         (define ux-l (remainder u sw))
         (define-syntax-rule (check-out! vx vy)
           (when (and (= (bytes-ref reaches-outer u) 0)
                      (>= vx 0) (< vx sw) (>= vy 0) (< vy sh))
             (define v (+ (* vy sw) vx))
             (when (and (= (vector-ref dist-v v) (add1 du))
                        (= (bytes-ref reaches-outer v) 1))
               (define vgx (+ sx0 vx))
               (define vgy (+ sy0 vy))
               (define flat-unbuildable-plug?
                 (and (>= du 5)
                      (not (grid-cell-positive? (bref vgx vgy)))
                      (let ([vth (grid-height-val href vgx vgy h-nat)])
                        (not
                         (and (procedure? href)
                              (or (> (abs (- vth h-nat)) 1.75)
                                  (for*/or ([rdy-i (in-range -2 3)]
                                            [rdx-i (in-range -2 3)]
                                            #:do [(define rgx (+ vgx rdx-i))
                                                  (define rgy (+ vgy rdy-i))]
                                            #:when (and (>= rgx 0) (< rgx w) (>= rgy 0) (< rgy h)
                                                        (grid-cell-positive? (pref rgx rgy))))
                                    (> (abs (- (grid-height-val href rgx rgy h-nat) h-nat)) 2.5))))))))
               (unless flat-unbuildable-plug?
                 (bytes-set! reaches-outer u 1)
                 (vector-set! next-out-idx u v)))))
         (check-out! (add1 ux-l) uy-l)
         (check-out! (sub1 ux-l) uy-l)
         (check-out! ux-l (add1 uy-l))
         (check-out! ux-l (sub1 uy-l))))

     (define (walk-outward start-idx steps)
       (let loop ([cur start-idx] [s 0])
         (define nxt (vector-ref next-out-idx cur))
         (if (or (>= s steps) (< nxt 0) (= nxt cur))
             cur
             (loop nxt (add1 s)))))

     (define scored-cands '())
     (for ([k (in-range bfs-tail)])
       (define idx (vector-ref qbuf k))
       (define d (vector-ref dist-v idx))
       (when (and (>= d 6) (<= d 15)
                  (= (bytes-ref flat-nat? idx) 1)
                  (= (bytes-ref reaches-outer idx) 1))
         (define lx (remainder idx sw))
         (define ly (quotient idx sw))
         (define gx (+ sx0 lx))
         (define gy (+ sy0 ly))
         (define cx0 (+ gx 0.5))
         (define cy0 (+ gy 0.5))
         (when (and (grid-cell-positive? (bref gx gy))
                    (>= (max (abs (- cx0 nx-f)) (abs (- cy0 ny-f))) 5.0)
                    (or (< mdist 10.0)
                        (and (>= (dist2d cx0 cy0 bx-f by-f) (- mdist 1.0))
                             (>= (+ (* (/ (- cx0 nx-f) (max 1.0 (dist2d cx0 cy0 nx-f ny-f))) mux)
                                    (* (/ (- cy0 ny-f) (max 1.0 (dist2d cx0 cy0 nx-f ny-f))) muy))
                                 -0.25))))
           (define out-idx (walk-outward idx 7))
           (define dst-wx (+ sx0 (remainder out-idx sw) 0.5))
           (define dst-wy (+ sy0 (quotient out-idx sw) 0.5))
           (when (>= (dist2d dst-wx dst-wy cx0 cy0) 4.0)
             (define fdx (- dst-wx nx-f))
             (define fdy (- dst-wy ny-f))
             (define fmag (max 1.0 (sqrt (+ (* fdx fdx) (* fdy fdy)))))
             (define fl-ux (/ fdx fmag))
             (define fl-uy (/ fdy fmag))
             (define tx (- fl-uy))
             (define ty fl-ux)
             (define pos-span
               (let sloop ([m 1])
                 (define kx (exact-floor (+ cx0 (* m tx))))
                 (define ky (exact-floor (+ cy0 (* m ty))))
                 (if (and (<= m 14) (>= kx 0) (< kx w) (>= ky 0) (< ky h)
                          (grid-cell-positive? (pref kx ky)))
                     (sloop (add1 m))
                     (sub1 m))))
             (define neg-span
               (let sloop ([m 1])
                 (define kx (exact-floor (- cx0 (* m tx))))
                 (define ky (exact-floor (- cy0 (* m ty))))
                 (if (and (<= m 14) (>= kx 0) (< kx w) (>= ky 0) (< ky h)
                          (grid-cell-positive? (pref kx ky)))
                     (sloop (add1 m))
                     (sub1 m))))
             (define span (+ 1 pos-span neg-span))
             (when (and (>= span 3) (<= span 13))
               (define mid-cx (+ cx0 (* 0.5 (- pos-span neg-span) tx)))
               (define mid-cy (+ cy0 (* 0.5 (- pos-span neg-span) ty)))
               (define mid-ix (max 0 (min (sub1 w) (exact-floor mid-cx))))
               (define mid-iy (max 0 (min (sub1 h) (exact-floor mid-cy))))
               (when (and (grid-cell-positive? (pref mid-ix mid-iy))
                          (>= (max (abs (- mid-cx nx-f)) (abs (- mid-cy ny-f))) 5.0))
                 (define buildable-cnt
                   (for*/sum ([dy-i (in-range -3 4)]
                              [dx-i (in-range -3 4)]
                              #:do [(define bx-i (+ mid-ix dx-i))
                                    (define by-i (+ mid-iy dy-i))]
                              #:when (and (>= bx-i 0) (< bx-i w) (>= by-i 0) (< by-i h)
                                          (grid-cell-positive? (bref bx-i by-i))
                                          (or (not (procedure? href))
                                              (<= (abs (- (grid-height-val href bx-i by-i h-nat) h-nat)) 1.75))))
                     1))
                 (when (>= buildable-cnt 10)
                   (define dir-x (/ (- mid-cx nx-f) (max 1.0 (dist2d mid-cx mid-cy nx-f ny-f))))
                   (define dir-y (/ (- mid-cy ny-f) (max 1.0 (dist2d mid-cx mid-cy nx-f ny-f))))
                   (define align (+ (* dir-x prior-ux) (* dir-y prior-uy)))
                   (define sc
                     (+ (* -12.0 span)
                        (* 25.0 align)
                        (* -2.5 (abs (- d 9.0)))
                        (* 0.4 (min 30 buildable-cnt))))
                   (set! scored-cands
                         (cons (list sc mid-cx mid-cy fl-ux fl-uy dst-wx dst-wy h-nat)
                               scored-cands)))))))))

     (define sorted (sort scored-cands > #:key car))
     (let dedup ([rem sorted] [acc '()])
       (cond
         [(or (null? rem) (>= (length acc) 4)) (reverse acc)]
         [else
          (define c (car rem))
          (define cx (second c))
          (define cy (third c))
          (if (ormap (lambda (prev) (<= (dist2d cx cy (first prev) (second prev)) 3.0)) acc)
              (dedup (cdr rem) acc)
              (dedup (cdr rem) (cons (cdr c) acc)))]))]))

;; Verifies every Protoss wall building, doorway, and park position on live map grids.
(define (protoss-wall-valid-on-grids? wall bx-f by-f nx-f ny-f map-grids)
  (define-values (grids-ok? w h pref bref href) (extract-map-grid-accessors map-grids))
  (cond
    [(not (and (hash? wall) grids-ok?)) #f]
    [else
     (define w-locus (hash-ref wall 'locus 'main-ramp))
     (define pyl (hash-ref wall 'pylon #f))
     (define s1  (hash-ref wall 'slot-1 #f))
     (define s2  (hash-ref wall 'slot-2 #f))
     (define s3  (hash-ref wall 'slot-3 #f))
     (define door (hash-ref wall 'door #f))
     (define park (hash-ref wall 'door-park #f))
     (define (valid-pt? p)
       (and (pair? p) (finite-real? (car p)) (finite-real? (cdr p))))
     (and (valid-pt? pyl) (valid-pt? s1) (valid-pt? s2)
          (or (not s3) (valid-pt? s3))
          (valid-pt? door) (valid-pt? park)
          (let* ([orig-x (if (eq? w-locus 'natural-choke) nx-f bx-f)]
                 [orig-y (if (eq? w-locus 'natural-choke) ny-f by-f)]
                 [max-steps (if (eq? w-locus 'natural-choke) 32 28)]
                 [o-ix (max 0 (min (sub1 w) (exact-floor orig-x)))]
                 [o-iy (max 0 (min (sub1 h) (exact-floor orig-y)))]
                 [target-h (grid-height-val href o-ix o-iy 112.0)]
                 [bldg-specs
                  (append (list (list (car pyl) (cdr pyl) 1.0 1.0)
                                (list (car s1)  (cdr s1)  1.5 1.5)
                                (list (car s2)  (cdr s2)  1.5 1.5))
                          (if s3 (list (list (car s3) (cdr s3) 1.5 1.5)) '()))]
                 [slot-pts (append (list s1 s2) (if s3 (list s3) '()))]
                 [door-ix (exact-floor (car door))]
                 [door-iy (exact-floor (cdr door))]
                 [park-ix (exact-floor (car park))]
                 [park-iy (exact-floor (cdr park))])
            (and (>= door-ix 0) (< door-ix w) (>= door-iy 0) (< door-iy h)
                 (>= park-ix 0) (< park-ix w) (>= park-iy 0) (< park-iy h)
                 (grid-cell-positive? (pref door-ix door-iy))
                 (grid-cell-positive? (pref park-ix park-iy))
                 (for/and ([sp (in-list bldg-specs)])
                   (match-define (list cx cy hw hh) sp)
                   (and (footprints-disjoint? cx cy hw hh bx-f by-f 2.5 2.5)
                        (footprints-disjoint? cx cy hw hh nx-f ny-f 2.5 2.5)
                        (footprints-disjoint? cx cy hw hh (car door) (cdr door) 0.5 0.5)
                        (footprint-buildable-at-height? cx cy hw hh w h bref href target-h #t pref)))
                 (for*/and ([i (in-range (length bldg-specs))]
                            [j (in-range (add1 i) (length bldg-specs))])
                   (match-define (list x1 y1 hw1 hh1) (list-ref bldg-specs i))
                   (match-define (list x2 y2 hw2 hh2) (list-ref bldg-specs j))
                   (footprints-disjoint? x1 y1 hw1 hh1 x2 y2 hw2 hh2))
                 (for/and ([s (in-list slot-pts)])
                   (<= (dist2d (car pyl) (cdr pyl) (car s) (cdr s)) 6.5))
                 (let* ([mid-wx (* 0.5 (+ orig-x (car door)))]
                        [mid-wy (* 0.5 (+ orig-y (cdr door)))]
                        [win-r 30]
                        [wx0 (max 0 (- (exact-round mid-wx) win-r))]
                        [wx1 (min w (+ (exact-round mid-wx) win-r))]
                        [wy0 (max 0 (- (exact-round mid-wy) win-r))]
                        [wy1 (min h (+ (exact-round mid-wy) win-r))]
                        [ww (max 1 (- wx1 wx0))]
                        [wh (max 1 (- wy1 wy0))]
                        [wn (* ww wh)]
                        [q (make-vector wn 0)])
                   (define (run-bounded-bfs blocked-rects step-cap)
                     (define dvec (make-vector wn -1))
                     (for ([r (in-list blocked-rects)])
                       (match-define (list rcx rcy rhw rhh) r)
                       (define rx0 (max 0 (- (exact-round (- rcx rhw)) wx0)))
                       (define rx1 (min ww (- (exact-round (+ rcx rhw)) wx0)))
                       (define ry0 (max 0 (- (exact-round (- rcy rhh)) wy0)))
                       (define ry1 (min wh (- (exact-round (+ rcy rhh)) wy0)))
                       (for* ([ly (in-range ry0 ry1)]
                              [lx (in-range rx0 rx1)])
                         (vector-set! dvec (+ (* ly ww) lx) -2)))
                     (define slx0 (max 0 (min (sub1 ww) (- o-ix wx0))))
                     (define sly0 (max 0 (min (sub1 wh) (- o-iy wy0))))
                     (define seed
                       (if (and (= (vector-ref dvec (+ (* sly0 ww) slx0)) -1)
                                (grid-cell-positive? (pref (+ wx0 slx0) (+ wy0 sly0))))
                           (cons slx0 sly0)
                           (for*/first ([rad (in-range 1 5)]
                                        [dy-i (in-range (- rad) (add1 rad))]
                                        [dx-i (in-range (- rad) (add1 rad))]
                                        #:do [(define lx (+ slx0 dx-i))
                                              (define ly (+ sly0 dy-i))]
                                        #:when (and (>= lx 0) (< lx ww) (>= ly 0) (< ly wh)
                                                    (= (vector-ref dvec (+ (* ly ww) lx)) -1)
                                                    (grid-cell-positive? (pref (+ wx0 lx) (+ wy0 ly)))))
                             (cons lx ly))))
                     (when seed
                       (define sidx (+ (* (cdr seed) ww) (car seed)))
                       (vector-set! dvec sidx 0)
                       (vector-set! q 0 sidx)
                       (let loop ([head 0] [tail 1])
                         (when (< head tail)
                           (define cur (vector-ref q head))
                           (define cd (vector-ref dvec cur))
                           (define cy (quotient cur ww))
                           (define cx (remainder cur ww))
                           (define tail1 tail)
                           (when (< cd step-cap)
                             (define-syntax-rule (bstep! nx ny)
                               (when (and (>= nx 0) (< nx ww) (>= ny 0) (< ny wh))
                                 (define nidx (+ (* ny ww) nx))
                                 (when (and (= (vector-ref dvec nidx) -1)
                                            (grid-cell-positive? (pref (+ wx0 nx) (+ wy0 ny))))
                                   (vector-set! dvec nidx (add1 cd))
                                   (vector-set! q tail1 nidx)
                                   (set! tail1 (add1 tail1)))))
                             (bstep! (add1 cx) cy)
                             (bstep! (sub1 cx) cy)
                             (bstep! cx (add1 cy))
                             (bstep! cx (sub1 cy)))
                           (loop (add1 head) tail1))))
                     dvec)

                   (define (cell-reached? dvec gx gy)
                     (define lx (- gx wx0))
                     (define ly (- gy wy0))
                     (and (>= lx 0) (< lx ww) (>= ly 0) (< ly wh)
                          (>= (vector-ref dvec (+ (* ly ww) lx)) 0)))

                   (define (footprint-perimeter-reached? dvec sp)
                     (match-define (list cx cy hw hh) sp)
                     (define x0 (exact-round (- cx hw)))
                     (define x1 (exact-round (+ cx hw)))
                     (define y0 (exact-round (- cy hh)))
                     (define y1 (exact-round (+ cy hh)))
                     (or (for/or ([ix (in-range x0 x1)])
                           (or (cell-reached? dvec ix (sub1 y0))
                               (cell-reached? dvec ix y1)))
                         (for/or ([iy (in-range y0 y1)])
                           (or (cell-reached? dvec (sub1 x0) iy)
                               (cell-reached? dvec x1 iy)))))

                   (define dvec-empty (run-bounded-bfs '() max-steps))
                   (define dvec-built (run-bounded-bfs bldg-specs (+ max-steps 6)))
                   (and (cell-reached? dvec-empty door-ix door-iy)
                        (for/and ([sp (in-list bldg-specs)])
                          (footprint-perimeter-reached? dvec-empty sp))
                        (cell-reached? dvec-built door-ix door-iy)
                        (cell-reached? dvec-built park-ix park-iy)
                        (for/and ([sp (in-list bldg-specs)])
                          (footprint-perimeter-reached? dvec-built sp)))))))]))

;; Solves a grid-validated Protoss wall around a ramp or natural choke center.
(define (solve-protoss-wall-candidate-on-grids bx-f by-f nx-f ny-f target-locus
                                               center-x center-y out-dx out-dy
                                               src-fx src-fy dst-fx dst-fy target-h
                                               w h pref bref href map-grids
                                               [forbid-tiles-set (set)])
  (define (outside-nexus-pads? cx cy hw hh)
    (and (footprints-disjoint? cx cy hw hh bx-f by-f 2.5 2.5)
         (footprints-disjoint? cx cy hw hh nx-f ny-f 2.5 2.5)
         (or (not (eq? target-locus 'natural-choke))
             (>= (max (abs (- cx nx-f)) (abs (- cy ny-f))) 4.5))))
  (define (strict-slot-buildable? cx cy hw hh)
    (and (footprint-buildable-at-height? cx cy hw hh w h bref href target-h #t pref)
         (or (set-empty? forbid-tiles-set)
             (let ([x0 (exact-round (- cx hw))]
                   [x1 (exact-round (+ cx hw))]
                   [y0 (exact-round (- cy hh))]
                   [y1 (exact-round (+ cy hh))])
               (for*/and ([ix (in-range x0 x1)]
                          [iy (in-range y0 y1)])
                 (not (set-member? forbid-tiles-set (cons ix iy))))))))
  (define (src-cell-ok? ix iy)
    (and (not (set-member? forbid-tiles-set (cons ix iy)))
         (or (not (procedure? href))
             (<= (abs (- (grid-height-val href ix iy target-h) target-h)) 2.0))))

  (define bfs-ctx
    (make-local-4conn-bfs center-x center-y src-fx src-fy dst-fx dst-fy w h pref
                          #:snap-src-pred src-cell-ok?))
  (cond
    [(not (hash-ref bfs-ctx 'valid? #f)) #f]
    [else
     (define bfs-reach? (hash-ref bfs-ctx 'bfs-reachable?))
     (define seals-cleanly? (hash-ref bfs-ctx 'seals-cleanly?))
     (define win-x0 (hash-ref bfs-ctx 'win-x0))
     (define win-y0 (hash-ref bfs-ctx 'win-y0))
     (define src-pt (hash-ref bfs-ctx 'src-pt))
     (define dst-pt (hash-ref bfs-ctx 'dst-pt))
     (define slot3x3-cands
       (for*/list ([dy-i (in-range -8 9)]
                   [dx-i (in-range -8 9)]
                   #:do [(define sx (+ (floor center-x) dx-i 0.5))
                         (define sy (+ (floor center-y) dy-i 0.5))]
                   #:when (and (<= (dist2d sx sy center-x center-y) 7.5)
                               (outside-nexus-pads? sx sy 1.5 1.5)
                               (strict-slot-buildable? sx sy 1.5 1.5)))
         (cons sx sy)))
     (define door-cands-raw
       (for*/list ([dy-i (in-range -6 7)]
                   [dx-i (in-range -6 7)]
                   #:do [(define ix (+ (exact-floor center-x) dx-i))
                         (define iy (+ (exact-floor center-y) dy-i))
                         (define dx0 (+ ix 0.5))
                         (define dy0 (+ iy 0.5))]
                   #:when (and (>= ix 0) (< ix w) (>= iy 0) (< iy h)
                               (<= (dist2d dx0 dy0 center-x center-y) 6.0)
                               (outside-nexus-pads? dx0 dy0 0.5 0.5)
                               (not (set-member? forbid-tiles-set (cons ix iy)))
                               (grid-cell-positive? (pref ix iy))))
         (list dx0 dy0 (- ix win-x0) (- iy win-y0))))
     (define door-cands
       (sort door-cands-raw <
             #:key (lambda (dc) (dist2d (first dc) (second dc) center-x center-y))))

     (define (build-and-validate-wall s1 s2 s3 door-x door-y pyl w-rects)
       (define all-rects (cons (list (car pyl) (cdr pyl) 1.0 1.0) w-rects))
       (define park (compute-door-park door-x door-y all-rects))
       (define cand-ht
         (hash 'locus target-locus
               'door (cons door-x door-y)
               'door-x door-x
               'door-y door-y
               'door-park park
               'pylon pyl
               'slot-1 s1
               'slot-2 s2
               'slot-3 s3
               'grid-solved? #t))
       (and (protoss-wall-valid-on-grids? cand-ht bx-f by-f nx-f ny-f map-grids)
            cand-ht))

     (define (find-rear-pylon wall-slots door-x door-y dlx dly w-rects)
       (define wcx (/ (for/sum ([s (in-list wall-slots)]) (car s)) (max 1 (length wall-slots))))
       (define wcy (/ (for/sum ([s (in-list wall-slots)]) (cdr s)) (max 1 (length wall-slots))))
       (define best-p #f)
       (define best-psc -1e9)
       (for* ([dy-i (in-range -6 7)]
              [dx-i (in-range -6 7)])
         (define px (exact->inexact (+ (exact-round wcx) dx-i)))
         (define py (exact->inexact (+ (exact-round wcy) dy-i)))
         (define rear-proj (- (+ (* (- px wcx) out-dx) (* (- py wcy) out-dy))))
         (define rear-dist (dist2d px py wcx wcy))
         (define ideal-band? (and (>= rear-dist 3.2) (<= rear-dist 5.0)))
         (define psc
           (+ (if ideal-band? 200.0 0.0)
              (* 10.0 rear-proj)
              (- (* 4.0 (abs (- rear-dist 4.0))))))
         (when (and (> psc best-psc)
                    (>= rear-proj 1.5)
                    (>= rear-dist 2.5)
                    (<= rear-dist 5.5)
                    (outside-nexus-pads? px py 1.0 1.0)
                    (footprints-disjoint? px py 1.0 1.0 door-x door-y 0.5 0.5)
                    (andmap (lambda (s)
                              (and (footprints-disjoint? px py 1.0 1.0 (car s) (cdr s) 1.5 1.5)
                                   (<= (dist2d px py (car s) (cdr s)) 6.2)))
                            wall-slots)
                    (strict-slot-buildable? px py 1.0 1.0)
                    (let ([rects-with-pyl (cons (list px py 1.0 1.0) w-rects)])
                      (and (bfs-reach? rects-with-pyl (car src-pt) (cdr src-pt) dlx dly)
                           (bfs-reach? rects-with-pyl dlx dly (car dst-pt) (cdr dst-pt)))))
           (set! best-psc psc)
           (set! best-p (cons px py))))
       best-p)

     (define (compute-door-park door-x door-y all-rects)
       (define raw-px (- door-x (* 2.2 out-dx)))
       (define raw-py (- door-y (* 2.2 out-dy)))
       (define (walkable-unblocked? wx wy)
         (define ix (exact-floor wx))
         (define iy (exact-floor wy))
         (and (>= ix 0) (< ix w) (>= iy 0) (< iy h)
              (grid-cell-positive? (pref ix iy))
              (andmap (lambda (r)
                        (footprints-disjoint? (+ ix 0.5) (+ iy 0.5) 0.5 0.5
                                              (first r) (second r) (third r) (fourth r)))
                      all-rects)))
       (if (walkable-unblocked? raw-px raw-py)
           (cons raw-px raw-py)
           (or (for*/first ([r (in-list '(0.5 1.0 1.5 2.0))]
                            [ang (in-list '(0.0 0.785 -0.785 1.57 -1.57 2.356 -2.356 3.14))]
                            #:do [(define wx (+ raw-px (* r (cos ang))))
                                  (define wy (+ raw-py (* r (sin ang))))]
                            #:when (walkable-unblocked? wx wy))
                 (cons wx wy))
               (cons raw-px raw-py))))

     ;; 1a. Try 2x 3x3 slots + 1x1 doorway with rear 2x2 Pylon
     (define best-wall #f)
     (define best-wsc -1e9)
     (for ([dc (in-list door-cands)]
           #:break (<= (+ 620.0 (* -8.0 (dist2d (first dc) (second dc) center-x center-y))) best-wsc))
       (match-define (list door-x door-y dlx dly) dc)
       (define near-s
         (filter (lambda (s)
                   (and (footprints-disjoint? (car s) (cdr s) 1.5 1.5 door-x door-y 0.5 0.5)
                        (<= (dist2d (car s) (cdr s) door-x door-y) 5.0)))
                 slot3x3-cands))
       (for* ([i (in-range (length near-s))]
              [j (in-range (add1 i) (length near-s))])
         (define s1 (list-ref near-s i))
         (define s2 (list-ref near-s j))
         (define s1-edge-door? (footprints-share-edge? (car s1) (cdr s1) 1.5 1.5 door-x door-y 0.5 0.5))
         (define s2-edge-door? (footprints-share-edge? (car s2) (cdr s2) 1.5 1.5 door-x door-y 0.5 0.5))
         (define s1-adj-door?  (<= (footprints-touch-gap (car s1) (cdr s1) 1.5 1.5 door-x door-y 0.5 0.5) 0.05))
         (define s2-adj-door?  (<= (footprints-touch-gap (car s2) (cdr s2) 1.5 1.5 door-x door-y 0.5 0.5) 0.05))
         (define s1-adj-s2?    (<= (footprints-touch-gap (car s1) (cdr s1) 1.5 1.5 (car s2) (cdr s2) 1.5 1.5) 0.05))
         (when (and (footprints-disjoint? (car s1) (cdr s1) 1.5 1.5 (car s2) (cdr s2) 1.5 1.5)
                    (or s1-edge-door? s2-edge-door?)
                    (or (and s1-adj-door? s2-adj-door?)
                        (and (or s1-adj-door? s2-adj-door?) s1-adj-s2?)))
           (define sandwich-bonus (if (and s1-edge-door? s2-edge-door?) 120.0 0.0))
           (define sc
             (+ 500.0
                sandwich-bonus
                (- (* 8.0 (+ (dist2d (car s1) (cdr s1) center-x center-y)
                             (dist2d (car s2) (cdr s2) center-x center-y)
                             (dist2d door-x door-y center-x center-y))))))
           (when (> sc best-wsc)
             (define w-rects
               (list (list (car s1) (cdr s1) 1.5 1.5)
                     (list (car s2) (cdr s2) 1.5 1.5)))
             (when (and (seals-cleanly? (cons (list door-x door-y 0.5 0.5) w-rects))
                        (bfs-reach? w-rects (car src-pt) (cdr src-pt) dlx dly)
                        (bfs-reach? w-rects dlx dly (car dst-pt) (cdr dst-pt)))
               (define pyl (find-rear-pylon (list s1 s2) door-x door-y dlx dly w-rects))
               (when (and pyl
                          (build-and-validate-wall s1 s2 #f door-x door-y pyl w-rects))
                 (set! best-wsc sc)
                 (set! best-wall (list s1 s2 #f door-x door-y pyl w-rects))))))))

     ;; 1b. Natural choke 8-9 tile sealing: 2x 3x3 + 1x1 door + 2x2 rear-flank Wall Pylon -> 'slot-3 #f
     (when (and (not best-wall) (eq? target-locus 'natural-choke))
       (define pylon2x2-cands
         (for*/list ([dy-i (in-range -7 8)]
                     [dx-i (in-range -7 8)]
                     #:do [(define px (exact->inexact (+ (exact-floor center-x) dx-i)))
                           (define py (exact->inexact (+ (exact-floor center-y) dy-i)))]
                     #:when (and (<= (dist2d px py center-x center-y) 7.0)
                                 (outside-nexus-pads? px py 1.0 1.0)
                                 (strict-slot-buildable? px py 1.0 1.0)))
           (cons px py)))
       (define door-cands-1b
         (if (> (length door-cands) 40) (take door-cands 40) door-cands))
       (for ([dc (in-list door-cands-1b)])
         (match-define (list door-x door-y dlx dly) dc)
         (define near-s
           (filter (lambda (s)
                     (and (footprints-disjoint? (car s) (cdr s) 1.5 1.5 door-x door-y 0.5 0.5)
                          (<= (dist2d (car s) (cdr s) door-x door-y) 7.2)))
                   slot3x3-cands))
         (define near-p
           (filter (lambda (p)
                     (and (footprints-disjoint? (car p) (cdr p) 1.0 1.0 door-x door-y 0.5 0.5)
                          (<= (dist2d (car p) (cdr p) door-x door-y) 5.5)))
                   pylon2x2-cands))
         (for* ([s1 (in-list near-s)]
                [pyl (in-list near-p)]
                #:when (and (footprints-disjoint? (car pyl) (cdr pyl) 1.0 1.0 (car s1) (cdr s1) 1.5 1.5)
                            (<= (dist2d (car pyl) (cdr pyl) (car s1) (cdr s1)) 6.45)))
           (define s1-touch-door? (<= (footprints-touch-gap (car s1) (cdr s1) 1.5 1.5 door-x door-y 0.5 0.5) 0.05))
           (define pyl-touch-door? (<= (footprints-touch-gap (car pyl) (cdr pyl) 1.0 1.0 door-x door-y 0.5 0.5) 0.05))
           (define pyl-touch-s1? (<= (footprints-touch-gap (car pyl) (cdr pyl) 1.0 1.0 (car s1) (cdr s1) 1.5 1.5) 0.05))
           (when (or s1-touch-door? (and pyl-touch-door? pyl-touch-s1?))
             (for ([s2 (in-list near-s)]
                   #:when (and (not (equal? s1 s2))
                               (footprints-disjoint? (car s1) (cdr s1) 1.5 1.5 (car s2) (cdr s2) 1.5 1.5)
                               (footprints-disjoint? (car pyl) (cdr pyl) 1.0 1.0 (car s2) (cdr s2) 1.5 1.5)
                               (<= (dist2d (car pyl) (cdr pyl) (car s2) (cdr s2)) 6.45)))
               (define wcx (* 0.5 (+ (car s1) (car s2))))
               (define wcy (* 0.5 (+ (cdr s1) (cdr s2))))
               (define rear-proj (- (+ (* (- (car pyl) wcx) out-dx) (* (- (cdr pyl) wcy) out-dy))))
               (define pyl-touch-s2? (<= (footprints-touch-gap (car pyl) (cdr pyl) 1.0 1.0 (car s2) (cdr s2) 1.5 1.5) 0.05))
               (define s2-touch-door? (<= (footprints-touch-gap (car s2) (cdr s2) 1.5 1.5 door-x door-y 0.5 0.5) 0.05))
               (define s2-touch-s1? (<= (footprints-touch-gap (car s2) (cdr s2) 1.5 1.5 (car s1) (cdr s1) 1.5 1.5) 0.05))
               (when (and (>= rear-proj 0.5)
                          (or pyl-touch-s1? pyl-touch-s2?)
                          (or s2-touch-door? pyl-touch-s2? s2-touch-s1?))
                 (define sc
                   (+ 420.0
                      (* 12.0 (min 3.0 rear-proj))
                      (if s1-touch-door? 30.0 0.0)
                      (if s2-touch-door? 30.0 0.0)
                      (- (* 7.0 (+ (dist2d (car s1) (cdr s1) center-x center-y)
                                   (dist2d (car s2) (cdr s2) center-x center-y)
                                   (dist2d door-x door-y center-x center-y))))))
                 (when (> sc best-wsc)
                   (define w-rects
                     (list (list (car s1) (cdr s1) 1.5 1.5)
                           (list (car s2) (cdr s2) 1.5 1.5)))
                   (define all-rects (cons (list (car pyl) (cdr pyl) 1.0 1.0) w-rects))
                   (when (and (seals-cleanly? (cons (list door-x door-y 0.5 0.5) all-rects))
                              (bfs-reach? all-rects (car src-pt) (cdr src-pt) dlx dly)
                              (bfs-reach? all-rects dlx dly (car dst-pt) (cdr dst-pt))
                              (build-and-validate-wall s1 s2 #f door-x door-y pyl w-rects))
                     (set! best-wsc sc)
                     (set! best-wall (list s1 s2 #f door-x door-y pyl w-rects))))))))))

     ;; 1c. Natural choke 9-10 tile / open synthetic fallback: 2x 3x3 flanking door tightly -> 'slot-3 #f
     (when (and (not best-wall) (eq? target-locus 'natural-choke))
       (define (slot-cliff-edge-cnt cx cy)
         (define x0 (sub1 (exact-round (- cx 1.5))))
         (define x1 (exact-round (+ cx 1.5)))
         (define y0 (sub1 (exact-round (- cy 1.5))))
         (define y1 (exact-round (+ cy 1.5)))
         (+ (for/sum ([ix (in-range (add1 x0) x1)])
              (+ (if (or (< y0 0) (not (grid-cell-positive? (bref ix y0)))) 1 0)
                 (if (or (>= y1 h) (not (grid-cell-positive? (bref ix y1)))) 1 0)))
            (for/sum ([iy (in-range (add1 y0) y1)])
              (+ (if (or (< x0 0) (not (grid-cell-positive? (bref x0 iy)))) 1 0)
                 (if (or (>= x1 w) (not (grid-cell-positive? (bref x1 iy)))) 1 0)))))
       (define door-cands-1c
         (if (> (length door-cands) 16) (take door-cands 16) door-cands))
       (define scored-triples
         (for*/list ([dc (in-list door-cands-1c)]
                     #:do [(define door-x (first dc))
                           (define door-y (second dc))
                           (define dlx (third dc))
                           (define dly (fourth dc))
                           (define flank-s
                             (filter (lambda (s)
                                       (define dd (dist2d (car s) (cdr s) door-x door-y))
                                       (and (>= dd 1.95)
                                            (<= dd 2.55)
                                            (footprints-disjoint? (car s) (cdr s) 1.5 1.5 door-x door-y 0.5 0.5)))
                                     slot3x3-cands))]
                     [i (in-range (length flank-s))]
                     [j (in-range (add1 i) (length flank-s))]
                     #:do [(define s1 (list-ref flank-s i))
                           (define s2 (list-ref flank-s j))
                           (define d1x (- (car s1) door-x))
                           (define d1y (- (cdr s1) door-y))
                           (define d2x (- (car s2) door-x))
                           (define d2y (- (cdr s2) door-y))
                           (define d1 (dist2d (car s1) (cdr s1) door-x door-y))
                           (define d2 (dist2d (car s2) (cdr s2) door-x door-y))
                           (define opp-dot (/ (+ (* d1x d2x) (* d1y d2y)) (max 1.0 (* d1 d2))))]
                     #:when (and (<= opp-dot -0.5)
                                 (footprints-disjoint? (car s1) (cdr s1) 1.5 1.5 (car s2) (cdr s2) 1.5 1.5)))
           (define ax (- (car s2) (car s1)))
           (define ay (- (cdr s2) (cdr s1)))
           (define amag (max 1.0 (sqrt (+ (* ax ax) (* ay ay)))))
           (define align-out (abs (+ (* (/ ax amag) out-dx) (* (/ ay amag) out-dy))))
           (define cliff-b (* 12.0 (min 4 (+ (slot-cliff-edge-cnt (car s1) (cdr s1))
                                             (slot-cliff-edge-cnt (car s2) (cdr s2))))))
           (define sc
             (+ 250.0
                cliff-b
                (* 40.0 (- 1.0 align-out))
                (- (* 10.0 (abs (- d1 d2))))
                (- (* 8.0 (+ (dist2d (car s1) (cdr s1) center-x center-y)
                             (dist2d (car s2) (cdr s2) center-x center-y)
                             (dist2d door-x door-y center-x center-y))))))
           (list sc s1 s2 door-x door-y dlx dly)))
       (for/or ([tr (in-list (sort scored-triples > #:key car))]
                [_cnt (in-range 40)])
         (match-define (list sc s1 s2 door-x door-y dlx dly) tr)
         (define w-rects
           (list (list (car s1) (cdr s1) 1.5 1.5)
                 (list (car s2) (cdr s2) 1.5 1.5)))
         (define pyl (find-rear-pylon (list s1 s2) door-x door-y dlx dly w-rects))
         (and pyl
              (let ([all-rects (cons (list (car pyl) (cdr pyl) 1.0 1.0) w-rects)])
                (and (bfs-reach? all-rects (car src-pt) (cdr src-pt) dlx dly)
                     (bfs-reach? all-rects dlx dly (car dst-pt) (cdr dst-pt))
                     (build-and-validate-wall s1 s2 #f door-x door-y pyl w-rects)
                     (begin
                       (set! best-wsc sc)
                       (set! best-wall (list s1 s2 #f door-x door-y pyl w-rects))
                       #t))))))

     ;; 2. If 2x 3x3 did not seal (wide main ramp or >10 tile choke), try 3x 3x3 slots + 1x1 doorway
     (when (not best-wall)
       (define door-cands-2
         (filter (lambda (dc) (<= (dist2d (first dc) (second dc) center-x center-y) 4.6))
                 door-cands))
       (for ([dc (in-list door-cands-2)])
         (match-define (list door-x door-y dlx dly) dc)
         (define adj-s
           (filter (lambda (s)
                     (and (footprints-disjoint? (car s) (cdr s) 1.5 1.5 door-x door-y 0.5 0.5)
                          (footprints-share-edge? (car s) (cdr s) 1.5 1.5 door-x door-y 0.5 0.5)))
                   slot3x3-cands))
         (define other-s
           (filter (lambda (s)
                     (and (footprints-disjoint? (car s) (cdr s) 1.5 1.5 door-x door-y 0.5 0.5)
                          (<= (dist2d (car s) (cdr s) door-x door-y) 6.5)))
                   slot3x3-cands))
         (for* ([s1 (in-list adj-s)]
                [i (in-range (length other-s))]
                #:do [(define s2 (list-ref other-s i))]
                #:when (and (not (equal? s1 s2))
                            (footprints-disjoint? (car s1) (cdr s1) 1.5 1.5 (car s2) (cdr s2) 1.5 1.5))
                [j (in-range (add1 i) (length other-s))]
                #:do [(define s3 (list-ref other-s j))]
                #:when (and (not (equal? s1 s3))
                            (footprints-disjoint? (car s1) (cdr s1) 1.5 1.5 (car s3) (cdr s3) 1.5 1.5)
                            (footprints-disjoint? (car s2) (cdr s2) 1.5 1.5 (car s3) (cdr s3) 1.5 1.5)
                            (or (<= (footprints-touch-gap (car s2) (cdr s2) 1.5 1.5 door-x door-y 0.5 0.5) 0.05)
                                (<= (footprints-touch-gap (car s2) (cdr s2) 1.5 1.5 (car s1) (cdr s1) 1.5 1.5) 0.05)
                                (<= (footprints-touch-gap (car s2) (cdr s2) 1.5 1.5 (car s3) (cdr s3) 1.5 1.5) 0.05))
                            (or (<= (footprints-touch-gap (car s3) (cdr s3) 1.5 1.5 door-x door-y 0.5 0.5) 0.05)
                                (<= (footprints-touch-gap (car s3) (cdr s3) 1.5 1.5 (car s1) (cdr s1) 1.5 1.5) 0.05)
                                (<= (footprints-touch-gap (car s3) (cdr s3) 1.5 1.5 (car s2) (cdr s2) 1.5 1.5) 0.05))))
           (define sc
             (- 350.0
                (* 6.0 (+ (dist2d (car s1) (cdr s1) center-x center-y)
                          (dist2d (car s2) (cdr s2) center-x center-y)
                          (dist2d (car s3) (cdr s3) center-x center-y)))))
           (when (> sc best-wsc)
             (define w-rects
               (list (list (car s1) (cdr s1) 1.5 1.5)
                     (list (car s2) (cdr s2) 1.5 1.5)
                     (list (car s3) (cdr s3) 1.5 1.5)))
             (when (and (seals-cleanly? (cons (list door-x door-y 0.5 0.5) w-rects))
                        (bfs-reach? w-rects (car src-pt) (cdr src-pt) dlx dly)
                        (bfs-reach? w-rects dlx dly (car dst-pt) (cdr dst-pt)))
               (define pyl (find-rear-pylon (list s1 s2 s3) door-x door-y dlx dly w-rects))
               (when pyl
                 (set! best-wsc sc)
                 (set! best-wall (list s1 s2 s3 door-x door-y pyl w-rects))))))))

     (and best-wall
          (let ()
            (match-define (list s1 s2 s3 door-x door-y pyl w-rects) best-wall)
            (define all-rects (cons (list (car pyl) (cdr pyl) 1.0 1.0) w-rects))
            (define park (compute-door-park door-x door-y all-rects))
            (define candidate-ht
              (hash 'locus target-locus
                    'door (cons door-x door-y)
                    'door-x door-x
                    'door-y door-y
                    'door-park park
                    'pylon pyl
                    'slot-1 s1
                    'slot-2 s2
                    'slot-3 s3
                    'grid-solved? #t))
            (and (protoss-wall-valid-on-grids? candidate-ht bx-f by-f nx-f ny-f map-grids)
                 candidate-ht)))]))

;; Solves a Protoss main-ramp wall on map grids with analytical and local high-ground fallbacks.
(define (solve-protoss-main-ramp-on-grids bx-f by-f nx-f ny-f ex-f ey-f w h pref bref href map-grids)
  (define rgeom (find-main-ramp-geometry bx-f by-f nx-f ny-f map-grids))
  (or (and (hash-ref rgeom 'grid-solved? #f)
           (let* ([rx (hash-ref rgeom 'ramp-x)]
                  [ry (hash-ref rgeom 'ramp-y)]
                  [rdx (hash-ref rgeom 'ramp-dx)]
                  [rdy (hash-ref rgeom 'ramp-dy)]
                  [hg-src (hash-ref rgeom 'hg-src (cons (- rx (* 9.0 rdx)) (- ry (* 9.0 rdy))))]
                  [lg-dst (hash-ref rgeom 'lg-dst (cons (+ rx (* 7.5 rdx)) (+ ry (* 7.5 rdy))))]
                  [ramp-set (for/set ([rt (in-list (hash-ref rgeom 'ramp-tiles '()))]) rt)])
             (solve-protoss-wall-candidate-on-grids
              bx-f by-f nx-f ny-f 'main-ramp
              rx ry rdx rdy
              (car hg-src) (cdr hg-src)
              (car lg-dst) (cdr lg-dst)
              (hash-ref rgeom 'h-main)
              w h pref bref href map-grids ramp-set)))
      (let ([ana (solve-protoss-matchup-wall-analytical bx-f by-f nx-f ny-f 'main-ramp ex-f ey-f w h)])
        (if (protoss-wall-valid-on-grids? ana bx-f by-f nx-f ny-f map-grids)
            ana
            (let* ([dx (- nx-f bx-f)]
                   [dy (- ny-f by-f)]
                   [dmag (max 1.0 (sqrt (+ (* dx dx) (* dy dy))))]
                   [ux (/ dx dmag)]
                   [uy (/ dy dmag)])
              (or (for*/first ([dist-d (in-list '(7.0 8.5 6.0 10.0))]
                               [lat-d (in-list '(0.0 2.5 -2.5 5.0 -5.0))]
                               #:do [(define cx (+ bx-f (* dist-d ux) (* lat-d (- uy))))
                                     (define cy (+ by-f (* dist-d uy) (* lat-d ux)))
                                     (define door-x (snap-3x3-coord cx))
                                     (define door-y (snap-3x3-coord cy))
                                     (define cand
                                       (if (>= (abs uy) (abs ux))
                                           (let ([sy (if (>= uy 0.0) 1.0 -1.0)])
                                             (hash 'locus 'main-ramp
                                                   'door (cons door-x door-y)
                                                   'door-x door-x
                                                   'door-y door-y
                                                   'door-park (cons (- door-x (* 2.0 ux)) (- door-y (* 2.0 sy)))
                                                   'pylon (cons (snap-2x2-coord (- door-x 0.5))
                                                                (snap-2x2-coord (- door-y (* 3.5 sy))))
                                                   'slot-1 (cons (- door-x 2.0) door-y)
                                                   'slot-2 (cons (+ door-x 2.0) door-y)
                                                   'slot-3 #f
                                                   'grid-solved? #f))
                                           (let ([sx (if (>= ux 0.0) 1.0 -1.0)])
                                             (hash 'locus 'main-ramp
                                                   'door (cons door-x door-y)
                                                   'door-x door-x
                                                   'door-y door-y
                                                   'door-park (cons (- door-x (* 2.0 sx)) (- door-y (* 2.0 uy)))
                                                   'pylon (cons (snap-2x2-coord (- door-x (* 3.5 sx)))
                                                                (snap-2x2-coord (- door-y 0.5)))
                                                   'slot-1 (cons door-x (- door-y 2.0))
                                                   'slot-2 (cons door-x (+ door-y 2.0))
                                                   'slot-3 #f
                                                   'grid-solved? #f))))]
                               #:when (protoss-wall-valid-on-grids? cand bx-f by-f nx-f ny-f map-grids))
                    cand)
                  ana))))))

;; Returns #t when Terran or Protoss faces a Random or still-unknown opponent race,
;; ensuring walls lock to the main-base ramp rather than risking an exposed natural wall.
(define (should-wall-main-ramp-vs-random? our-race enemy-race [initial-enemy-race enemy-race])
  (define (race-match? r syms str)
    (or (and (memq r syms) #t)
        (and (string? r) (string-ci=? r str))))
  (define (random-or-unknown? r)
    (or (race-match? r '(Random random RANDOM) "random")
        (race-match? r '(Unknown unknown UNKNOWN) "unknown")))
  (and (or (race-match? our-race '(Protoss protoss PROTOSS) "protoss")
           (race-match? our-race '(Terran terran TERRAN) "terran"))
       (or (random-or-unknown? enemy-race)
           (random-or-unknown? initial-enemy-race))
       #t))

;; Selects and caches a matchup-specific Protoss wall (natural choke vs non-Random Zerg,
;; main ramp vs Terran/Protoss/Random or when `initial-enemy-race` was Random/`force-main-ramp?` is set).
(define (solve-protoss-matchup-wall base-x base-y nat-x nat-y enemy-race
                                    #:map-grids [map-grids #f]
                                    #:enemy-x [enemy-x 160.5]
                                    #:enemy-y [enemy-y 160.5]
                                    #:initial-enemy-race [initial-enemy-race enemy-race]
                                    #:force-main-ramp? [force-main-ramp? #f]
                                    #:force-natural-choke? [force-natural-choke? #f])
  (define vs-zerg?
    (or (memq enemy-race '(Zerg zerg ZERG))
        (and (string? enemy-race) (string-ci=? enemy-race "zerg"))))
  (define lock-main-ramp?
    (and (not force-natural-choke?)
         (or force-main-ramp?
             (should-wall-main-ramp-vs-random? 'Protoss enemy-race initial-enemy-race))))
  (define locus
    (cond
      [force-natural-choke? 'natural-choke]
      [(or lock-main-ramp? (not vs-zerg?)) 'main-ramp]
      [else 'natural-choke]))
  (define cache-key
    (list 'protoss
          (round base-x) (round base-y)
          (round nat-x) (round nat-y)
          locus
          initial-enemy-race
          (and force-main-ramp? #t)
          (and force-natural-choke? #t)
          (round enemy-x) (round enemy-y)
          (wall-grid-fingerprint map-grids base-x base-y nat-x nat-y)))
  (cond
    [(hash-ref PROTOSS-MATCHUP-WALL-CACHE cache-key #f) => values]
    [else
     (define-values (grids-ok? w h pref bref href) (extract-map-grid-accessors map-grids))
     (define result
       (cond
         [(not grids-ok?)
          (solve-protoss-matchup-wall-analytical base-x base-y nat-x nat-y locus enemy-x enemy-y)]
         [else
          (define bx-f (exact->inexact base-x))
          (define by-f (exact->inexact base-y))
          (define nx-f (exact->inexact nat-x))
          (define ny-f (exact->inexact nat-y))
          (define ex-f (exact->inexact enemy-x))
          (define ey-f (exact->inexact enemy-y))
          (cond
            [(eq? locus 'main-ramp)
             (solve-protoss-main-ramp-on-grids bx-f by-f nx-f ny-f ex-f ey-f w h pref bref href map-grids)]
            [else
             (define nat-cands
               (find-natural-choke-candidates bx-f by-f nx-f ny-f ex-f ey-f w h pref bref href))
             (or (for/or ([nc (in-list nat-cands)])
                   (match-define (list cx cy out-dx out-dy dst-x dst-y h-nat) nc)
                   (solve-protoss-wall-candidate-on-grids
                    bx-f by-f nx-f ny-f 'natural-choke
                    cx cy out-dx out-dy
                    nx-f ny-f dst-x dst-y h-nat
                    w h pref bref href map-grids))
                 (let-values ([(out-ux out-uy)
                               (compute-natural-exit-direction bx-f by-f nx-f ny-f ex-f ey-f w h)])
                   (define o-ix (max 0 (min (sub1 w) (exact-floor nx-f))))
                   (define o-iy (max 0 (min (sub1 h) (exact-floor ny-f))))
                   (define h-nat (grid-height-val href o-ix o-iy 112.0))
                   (for/or ([step-d (in-list '(8.5 7.0 10.0))])
                     (define raw-cx (+ nx-f (* step-d out-ux)))
                     (define raw-cy (+ ny-f (* step-d out-uy)))
                     (define cx (max 4.5 (min (- w 4.5) raw-cx)))
                     (define cy (max 4.5 (min (- h 4.5) raw-cy)))
                     (define dst-x (max 1.5 (min (- w 1.5) (+ cx (* 6.5 out-ux)))))
                     (define dst-y (max 1.5 (min (- h 1.5) (+ cy (* 6.5 out-uy)))))
                     (solve-protoss-wall-candidate-on-grids
                      bx-f by-f nx-f ny-f 'natural-choke
                      cx cy out-ux out-uy
                      nx-f ny-f dst-x dst-y h-nat
                      w h pref bref href map-grids)))
                 (and force-natural-choke?
                      (solve-protoss-matchup-wall-analytical bx-f by-f nx-f ny-f 'natural-choke ex-f ey-f w h))
                 (solve-protoss-main-ramp-on-grids
                  bx-f by-f nx-f ny-f ex-f ey-f w h pref bref href map-grids))])]))
     (hash-set! PROTOSS-MATCHUP-WALL-CACHE cache-key result)
     result]))

;; Solves a generic CSP choke wall-in for Terran or Protoss building presets.
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
;; 2. Footprint Reservation, Terran Add-on Clearance & Spiral Build Solver
;; =============================================================================

;; Returns the world `(values ax ay)` center of the East (+X) add-on slot for a 3x3 facility.
(define (terran-addon-pad-pos bx by)
  (values (+ (exact->inexact bx) SC2-TERRAN-ADDON-OFFSET-X)
          (+ (exact->inexact by) SC2-TERRAN-ADDON-OFFSET-Y)))

;; Builds a `reserved-aabb` guarding the East (+X) 2x2 add-on pad of a 3x3 facility.
(define (terran-addon-pad-aabb bx by [owner-tag 0] [expires-frame 0])
  (define-values (ax ay) (terran-addon-pad-pos bx by))
  (reserved-aabb ax ay 1.0 1.0 'addon-pad owner-tag expires-frame))

;; Checks whether a Terran production facility hash already has an attached or adjacent add-on.
(define (terran-facility-has-addon? b [ally-bldgs '()])
  (and (hash? b)
       (or (eq? (hash-ref b 'has-addon? #f) #t)
           (not (not (hash-ref b 'addon #f)))
           (> (hash-ref b 'add-on-tag 0) 0)
           (let ([bx (hash-ref b 'x -999.0)]
                 [by (hash-ref b 'y -999.0)])
             (ormap (lambda (ab)
                      (and (hash? ab)
                           (memq (unit-type-sym ab)
                                 '(barracks-techlab barracks-tech-lab barracks-reactor
                                   factory-techlab factory-tech-lab factory-reactor
                                   starport-techlab starport-tech-lab starport-reactor
                                   tech-lab techlab reactor))
                           (<= (dist2d (+ bx SC2-TERRAN-ADDON-OFFSET-X)
                                       (+ by SC2-TERRAN-ADDON-OFFSET-Y)
                                       (hash-ref ab 'x -9999.0)
                                       (hash-ref ab 'y -9999.0))
                               1.75)))
                    (if (list? ally-bldgs) ally-bldgs '()))))))

;; Builds reserved AABBs for wall-in slots, doorway corridor, and ramp add-on pad.
(define (make-wall-reserved-aabbs race
                                  #:terran-ramp-wall [terran-ramp-wall #f]
                                  #:protoss-matchup-wall [protoss-matchup-wall #f]
                                  #:bypass-wall-depot1? [bypass-wall-depot1? #f]
                                  #:bypass-wall-pylon? [bypass-wall-pylon? #f])
  (define (pt->aabb pt hw hh kind)
    (and (pair? pt)
         (real? (car pt))
         (real? (cdr pt))
         (reserved-aabb (exact->inexact (car pt))
                        (exact->inexact (cdr pt))
                        hw hh kind 0 0)))
  (cond
    [(and (eq? race 'Terran) (hash? terran-ramp-wall))
     (filter values
             (list (and (not bypass-wall-depot1?)
                        (pt->aabb (hash-ref terran-ramp-wall 'depot-1 #f) 1.0 1.0 'wall-slot))
                   (and (not bypass-wall-depot1?)
                        (pt->aabb (hash-ref terran-ramp-wall 'barracks #f) 1.5 1.5 'wall-slot))
                   (pt->aabb (hash-ref terran-ramp-wall 'depot-2 #f) 1.0 1.0 'wall-slot)
                   (pt->aabb (hash-ref terran-ramp-wall 'barracks-addon #f) 1.0 1.0 'terran-addon-pad)))]
    [(and (eq? race 'Protoss) (hash? protoss-matchup-wall))
     (filter values
             (list (and (not bypass-wall-pylon?)
                        (pt->aabb (hash-ref protoss-matchup-wall 'pylon #f) 1.0 1.0 'wall-slot))
                   (and (not bypass-wall-pylon?)
                        (pt->aabb (hash-ref protoss-matchup-wall 'slot-1 #f) 1.5 1.5 'wall-slot))
                   (and (not bypass-wall-pylon?)
                        (pt->aabb (hash-ref protoss-matchup-wall 'slot-2 #f) 1.5 1.5 'wall-slot))
                   (and (not bypass-wall-pylon?)
                        (pt->aabb (hash-ref protoss-matchup-wall 'slot-3 #f) 1.5 1.5 'wall-slot))
                   (and (not bypass-wall-pylon?)
                        (pt->aabb (hash-ref protoss-matchup-wall 'door #f) 1.2 1.2 'doorway-corridor))
                   (and (not bypass-wall-pylon?)
                        (pt->aabb (hash-ref protoss-matchup-wall 'door-park #f) 1.2 1.2 'doorway-corridor))))]
    [else '()]))

;; Filters wall AABBs when placing into an exact designated wall slot vs general macro construction.
(define (wall-aabbs-for-build step-wall-aabbs exact-wall-slot?)
  (if exact-wall-slot?
      (filter (lambda (r)
                (not (and (reserved-aabb? r)
                          (memq (reserved-aabb-kind r)
                                '(wall-slot doorway-corridor terran-addon-pad)))))
              (if (list? step-wall-aabbs) step-wall-aabbs '()))
      (if (list? step-wall-aabbs) step-wall-aabbs '())))

;; Constructs a `reserved-aabb` sized for `bldg-sym` at `(x, y)` expiring at `expires-frame`.
(define (make-build-site-aabb bldg-sym x y [owner-tag 0] [expires-frame SC2-BUILD-SITE-RESERVATION-TTL] [kind 'reserved-site])
  (define canon (if (symbol? bldg-sym) (sc2-canonical-structure-sym bldg-sym) bldg-sym))
  (define-values (hw hh) (if (symbol? canon) (sc2-structure-half-dims canon) (values 1.5 1.5)))
  (reserved-aabb (exact->inexact x) (exact->inexact y) hw hh kind owner-tag expires-frame))

;; Drops expired positive-expiry `reserved-aabb` records relative to `frame`.
(define (prune-expired-aabbs aabbs frame)
  (filter (lambda (r)
            (and (reserved-aabb? r)
                 (or (<= (reserved-aabb-expires-frame r) 0)
                     (> (reserved-aabb-expires-frame r) frame))))
          (if (list? aabbs) aabbs '())))

;; Partitions active physical footprints vs Terran add-on pads from AABBs, site hashes, and buildings.
(define (collect-placement-blocking-aabbs #:reserved-aabbs [reserved-aabbs '()]
                                          #:reserved-sites [reserved-sites '()]
                                          #:ally-bldgs [ally-bldgs '()]
                                          #:frame [frame 0])
  (define physical-aabbs '())
  (define addon-pad-aabbs '())
  (define (push-phys! box) (set! physical-aabbs (cons box physical-aabbs)))
  (define (push-addon! box) (set! addon-pad-aabbs (cons box addon-pad-aabbs)))

  (for ([r (in-list (prune-expired-aabbs reserved-aabbs frame))])
    (if (eq? (reserved-aabb-kind r) 'addon-pad)
        (push-addon! r)
        (push-phys! r)))

  (for ([s (in-list (if (list? reserved-sites) reserved-sites '()))])
    (cond
      [(reserved-aabb? s)
       (when (or (<= (reserved-aabb-expires-frame s) 0)
                 (> (reserved-aabb-expires-frame s) frame))
         (if (eq? (reserved-aabb-kind s) 'addon-pad)
             (push-addon! s)
             (push-phys! s)))]
      [(hash? s)
       (define sx (exact->inexact (hash-ref s 'x 0.0)))
       (define sy (exact->inexact (hash-ref s 'y 0.0)))
       (define raw-st (hash-ref s 'bldg-sym (hash-ref s 'type #f)))
       (define stype (if (symbol? raw-st) (sc2-canonical-structure-sym raw-st) raw-st))
       (define-values (shw shh)
         (if (symbol? stype) (sc2-structure-half-dims stype) (values 1.5 1.5)))
       (define owner (hash-ref s 'builder-id (hash-ref s 'owner-tag 0)))
       (define exp-f (hash-ref s 'expires-frame 0))
       (when (or (<= exp-f 0) (<= frame exp-f))
         (push-phys! (reserved-aabb sx sy shw shh 'reserved-site owner exp-f))
         (when (memq stype '(barracks factory starport))
           (push-addon! (terran-addon-pad-aabb sx sy owner exp-f))))]))

  (for ([b (in-list (if (list? ally-bldgs) ally-bldgs '()))]
        #:when (hash? b))
    (define raw-bt (hash-ref b 'type #f))
    (define flying?
      (or (memq raw-bt '(barracks-flying factory-flying starport-flying
                         command-center-flying orbital-command-flying
                         spine-crawler-uprooted spore-crawler-uprooted))
          (eq? (hash-ref b 'flying? #f) #t)
          (eq? (hash-ref b 'is-flying #f) #t)))
    (unless flying?
      (define bx (exact->inexact (hash-ref b 'x 0.0)))
      (define by (exact->inexact (hash-ref b 'y 0.0)))
      (define btype (if (symbol? raw-bt) (sc2-canonical-structure-sym raw-bt) raw-bt))
      (define-values (bhw bhh)
        (if (symbol? btype) (sc2-structure-half-dims btype) (values 1.5 1.5)))
      (define bid (hash-ref b 'id 0))
      (push-phys! (reserved-aabb bx by bhw bhh 'ally-bldg bid 0))
      (when (memq btype '(barracks factory starport))
        (push-addon! (terran-addon-pad-aabb bx by bid 0)))))

  (values physical-aabbs addon-pad-aabbs))

;; Returns #t if `(cx, cy)` encroaches within 4.5 Chebyshev tiles of any non-townhall expansion pad.
(define (placement-point-overlaps-expansion-pad? cx cy expansion-pads [is-townhall? #f])
  (and (not is-townhall?)
       (list? expansion-pads)
       (ormap (lambda (p)
                (define-values (ok? px py)
                  (cond
                    [(and (pair? p) (real? (car p)) (real? (cdr p)))
                     (values #t (exact->inexact (car p)) (exact->inexact (cdr p)))]
                    [(and (pair? p) (real? (car p)) (pair? (cdr p)) (real? (cadr p)))
                     (values #t (exact->inexact (car p)) (exact->inexact (cadr p)))]
                    [(hash? p)
                     (values #t
                             (exact->inexact (hash-ref p 'x -999.0))
                             (exact->inexact (hash-ref p 'y -999.0)))]
                    [(reserved-aabb? p)
                     (values #t (reserved-aabb-cx p) (reserved-aabb-cy p))]
                    [else (values #f 0.0 0.0)]))
                (and ok?
                     (< (max (abs (- cx px)) (abs (- cy py))) 4.5)))
              expansion-pads)))

;; Checks playable coordinate bounds defined by `SC2-MAP-PLAYABLE-*`.
(define (placement-in-playable-bounds? cx cy)
  (and (>= cx SC2-MAP-PLAYABLE-MIN-COORD) (<= cx SC2-MAP-PLAYABLE-MAX-COORD)
       (>= cy SC2-MAP-PLAYABLE-MIN-COORD) (<= cy SC2-MAP-PLAYABLE-MAX-COORD)))

;; Checks whether `bldg-sym` fits cleanly at `(cx, cy)` including its East add-on slot if Terran.
(define (placement-site-free? bldg-sym cx cy physical-aabbs addon-pad-aabbs
                              [expansion-pads '()]
                              [exact-wall-slot? #f])
  (define canon (if (symbol? bldg-sym) (sc2-canonical-structure-sym bldg-sym) bldg-sym))
  (define-values (cand-hw cand-hh) (if (symbol? canon) (sc2-structure-half-dims canon) (values 1.5 1.5)))
  (define is-townhall?
    (or (memq bldg-sym SC2-TOWNHALL-STRUCTURE-SYMS)
        (memq canon SC2-TOWNHALL-STRUCTURE-SYMS)))
  (define is-3x3-addon-fac? (memq canon '(barracks factory starport)))
  (define-values (new-ax new-ay) (terran-addon-pad-pos cx cy))
  (and (placement-in-playable-bounds? cx cy)
       (not (placement-point-overlaps-expansion-pad? cx cy expansion-pads is-townhall?))
       (not (ormap (lambda (b) (aabb-overlaps? cx cy cand-hw cand-hh b)) physical-aabbs))
       (not (ormap (lambda (b) (aabb-overlaps? cx cy cand-hw cand-hh b)) addon-pad-aabbs))
       (or (not is-3x3-addon-fac?)
           exact-wall-slot?
           (and (placement-in-playable-bounds? new-ax new-ay)
                (not (placement-point-overlaps-expansion-pad? new-ax new-ay expansion-pads #f))
                (not (ormap (lambda (b) (aabb-overlaps? new-ax new-ay 1.0 1.0 b)) physical-aabbs))
                (not (ormap (lambda (b) (aabb-overlaps? new-ax new-ay 1.0 1.0 b)) addon-pad-aabbs))))))

;; Searches 3-tile concentric snapped lattice rings around `(raw-x, raw-y)` for a collision-free site.
(define (spiral-search-free-point bldg-sym raw-x raw-y physical-aabbs addon-pad-aabbs expansion-pads
                                  [exact-wall-slot? #f]
                                  [extra-ok? (lambda (_cx _cy) #t)])
  (define canon (if (symbol? bldg-sym) (sc2-canonical-structure-sym bldg-sym) bldg-sym))
  (define snap-fn (if (sc2-odd-footprint-structure? canon) snap-3x3-coord snap-2x2-coord))
  (define x0 (snap-fn raw-x))
  (define y0 (snap-fn raw-y))
  (define (ok? cx cy)
    (and (placement-site-free? canon cx cy physical-aabbs addon-pad-aabbs expansion-pads exact-wall-slot?)
         (extra-ok? cx cy)))
  (if (ok? x0 y0)
      (values x0 y0)
      (let search ([r 3.0])
        (if (> r 18.0)
            (values x0 y0)
            (let ([found
                   (for*/first ([dx (in-list (list 0.0 r (- r)))]
                                [dy (in-list (list 0.0 r (- r)))]
                                #:when (and (or (not (zero? dx)) (not (zero? dy)))
                                            (ok? (snap-fn (+ x0 dx)) (snap-fn (+ y0 dy)))))
                     (cons (snap-fn (+ x0 dx)) (snap-fn (+ y0 dy))))])
              (if found
                  (values (car found) (cdr found))
                  (search (+ r 3.0))))))))

;; Resolves a collision-free build coordinate `(values x y)` via optional Pro SimCity or 3-tile spiral search.
(define (solve-spiral-placement bldg-sym raw-x raw-y
                                #:ally-bldgs [ally-bldgs '()]
                                #:reserved-sites [reserved-sites '()]
                                #:reserved-aabbs [reserved-aabbs '()]
                                #:expansion-pads [expansion-pads '()]
                                #:frame [frame 0]
                                #:exact-wall-slot? [exact-wall-slot? #f]
                                #:race [race #f]
                                #:base-x [base-x #f]
                                #:base-y [base-y #f]
                                #:nat-x [nat-x #f]
                                #:nat-y [nat-y #f]
                                #:enemy-x [enemy-x SC2-DEFAULT-ENEMY-BASE-X]
                                #:enemy-y [enemy-y SC2-DEFAULT-ENEMY-BASE-Y]
                                #:mineral-patches [mineral-patches '()]
                                #:geysers [geysers '()]
                                #:map-grids [map-grids #f]
                                #:use-simcity? [use-simcity? #t])
  (define canon (if (symbol? bldg-sym) (sc2-canonical-structure-sym bldg-sym) bldg-sym))
  (define-values (cand-hw cand-hh) (if (symbol? canon) (sc2-structure-half-dims canon) (values 1.5 1.5)))
  (define is-townhall?
    (or (memq bldg-sym SC2-TOWNHALL-STRUCTURE-SYMS)
        (memq canon SC2-TOWNHALL-STRUCTURE-SYMS)))
  (cond
    [exact-wall-slot?
     (define-values (physical-aabbs addon-pad-aabbs)
       (collect-placement-blocking-aabbs #:reserved-aabbs reserved-aabbs
                                         #:reserved-sites reserved-sites
                                         #:ally-bldgs ally-bldgs
                                         #:frame frame))
     (if (and (placement-in-playable-bounds? raw-x raw-y)
              (not (placement-point-overlaps-expansion-pad? (exact->inexact raw-x) (exact->inexact raw-y) expansion-pads is-townhall?))
              (not (ormap (lambda (b) (aabb-overlaps? raw-x raw-y cand-hw cand-hh b)) physical-aabbs)))
         (values raw-x raw-y)
         (spiral-search-free-point canon raw-x raw-y physical-aabbs addon-pad-aabbs expansion-pads #t))]
    [(and use-simcity? race (real? base-x) (real? base-y))
     (solve-pro-simcity-layout-placement bldg-sym race base-x base-y
                                         (if (real? nat-x) nat-x (+ base-x 24.0))
                                         (if (real? nat-y) nat-y (+ base-y 4.0))
                                         #:enemy-x enemy-x
                                         #:enemy-y enemy-y
                                         #:ally-bldgs ally-bldgs
                                         #:mineral-patches mineral-patches
                                         #:geysers geysers
                                         #:reserved-sites reserved-sites
                                         #:reserved-aabbs reserved-aabbs
                                         #:expansion-pads expansion-pads
                                         #:map-grids map-grids
                                         #:frame frame)]
    [else
     (define-values (physical-aabbs addon-pad-aabbs)
       (collect-placement-blocking-aabbs #:reserved-aabbs reserved-aabbs
                                         #:reserved-sites reserved-sites
                                         #:ally-bldgs ally-bldgs
                                         #:frame frame))
     (spiral-search-free-point canon raw-x raw-y physical-aabbs addon-pad-aabbs expansion-pads #f)]))

;; =============================================================================
;; 3. Pylon Power & Protoss Placement Anchors
;; =============================================================================

;; Returns #t if `(px, py)` lies within `power-radius` of a ready Pylon or Warp Prism Phasing.
(define (pylon-powers-point? px py ally-bldgs [power-radius 6.2] [require-complete? #t])
  (ormap (lambda (b)
           (and (hash? b)
                (memq (sc2-canonical-structure-sym (unit-type-sym b))
                      '(pylon pylon-overcharged warp-prism-phasing))
                (or (not require-complete?)
                    (>= (hash-ref b 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS))
                (<= (dist2d px py
                            (hash-ref b 'x -9999.0)
                            (hash-ref b 'y -9999.0))
                    power-radius)))
         (if (list? ally-bldgs) ally-bldgs '())))

;; Returns ally Protoss buildings that need Pylon power and are currently unpowered.
(define (find-unpowered-structures ally-bldgs [power-radius 6.5])
  (define bldgs (if (list? ally-bldgs) ally-bldgs '()))
  (filter (lambda (b)
            (and (hash? b)
                 (let ([canon (sc2-canonical-structure-sym (unit-type-sym b))])
                   (and (sc2-structure-requires-pylon-power? canon)
                        (or (eq? (hash-ref b 'powered? #t) #f)
                            (not (pylon-powers-point? (hash-ref b 'x -9999.0)
                                                      (hash-ref b 'y -9999.0)
                                                      bldgs
                                                      power-radius
                                                      #t)))))))
          bldgs))

;; Computes an open in-main anchor near `(base-x, base-y)` stepping away from mineral patches.
(define (emergency-inmain-supply-anchor base-x base-y nat-x nat-y retry-idx [mineral-patches '()])
  (define main-mps
    (filter (lambda (mp)
              (and (hash? mp)
                   (<= (dist2d base-x base-y
                               (hash-ref mp 'x base-x)
                               (hash-ref mp 'y base-y))
                       13.0)))
            (if (list? mineral-patches) mineral-patches '())))
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

;; Chooses `(values raw-px raw-py use-exact-wall?)` for the next Protoss Pylon placement.
(define (select-pylon-power-anchor #:base-x base-x
                                   #:base-y base-y
                                   #:nat-x nat-x
                                   #:nat-y nat-y
                                   #:protoss-pylon-count [pylon-cnt 0]
                                   #:protoss-matchup-wall [wall #f]
                                   #:unpowered-bldg [unpowered-bldg #f]
                                   #:allow-exact-wall-slot? [allow-wall? #t]
                                   #:bypass-wall-pylon? [bypass-wall? #f]
                                   #:power-placement-failed? [failed? #f]
                                   #:live-game? [live-game? #t]
                                   #:active-bases [active-bases 1]
                                   #:inmain-retry-idx [retry-idx 0]
                                   #:mineral-patches [mineral-patches '()])
  (define has-unpowered? (hash? unpowered-bldg))
  (define wall-pylon-pt
    (and allow-wall?
         (not bypass-wall?)
         (= pylon-cnt 0)
         (not has-unpowered?)
         (hash? wall)
         (hash-ref wall 'pylon #f)))
  (define use-exact-pylon? (pair? wall-pylon-pt))
  (define-values (em-px em-py)
    (emergency-inmain-supply-anchor
     base-x base-y nat-x nat-y
     (+ retry-idx (if failed? (+ pylon-cnt 1) 0))
     mineral-patches))
  (define use-nat-anchor?
    (and live-game?
         (>= active-bases 2)
         (>= pylon-cnt 2)
         (if failed? (even? retry-idx) (odd? pylon-cnt))))
  (define raw-px
    (cond
      [use-exact-pylon? (safe-coord (car wall-pylon-pt) em-px)]
      [has-unpowered?
       (safe-coord (+ (hash-ref unpowered-bldg 'x (+ base-x 4.0)) 2.5) em-px)]
      [bypass-wall? em-px]
      [use-nat-anchor?
       (safe-coord (+ nat-x 4.5 (* 2.0 (modulo (quotient pylon-cnt 2) 3))) (+ base-x 4.0))]
      [failed? em-px]
      [else (safe-coord (+ base-x 4.0 (* 2.5 (modulo pylon-cnt 4))))]))
  (define raw-py
    (cond
      [use-exact-pylon? (safe-coord (cdr wall-pylon-pt) em-py)]
      [has-unpowered?
       (safe-coord (+ (hash-ref unpowered-bldg 'y (+ base-y 4.0)) 0.5) em-py)]
      [bypass-wall? em-py]
      [use-nat-anchor?
       (safe-coord (+ nat-y 4.5 (* 2.0 (quotient pylon-cnt 6))) (+ base-y 4.0))]
      [failed? em-py]
      [else (safe-coord (+ base-y 4.0 (* 2.5 (quotient pylon-cnt 4))))]))
  (values raw-px raw-py use-exact-pylon?))

;; =============================================================================
;; 4. Zerg Creep Highway & Safe Build Anchors
;; =============================================================================

;; Pushes `(cx, cy)` outside `min-dist` of expansion pads in `pad-pts` toward `(away-x, away-y)`.
(define (nudge-off-expansion-pads cx cy pad-pts
                                  [min-dist 5.0]
                                  [away-x SC2-DEFAULT-ENEMY-BASE-X]
                                  [away-y SC2-DEFAULT-ENEMY-BASE-Y])
  (let loop ([rx cx] [ry cy] [pads (if (list? pad-pts) pad-pts '())])
    (cond
      [(null? pads) (values (safe-coord rx cx) (safe-coord ry cy))]
      [else
       (define p (car pads))
       (define px (cond [(pair? p) (car p)] [(hash? p) (hash-ref p 'x rx)] [else rx]))
       (define py (cond [(pair? p) (cdr p)] [(hash? p) (hash-ref p 'y ry)] [else ry]))
       (define d (dist2d rx ry px py))
       (if (< d min-dist)
           (let* ([use-away? (< d 0.1)]
                  [vx0 (if use-away? (- away-x px) (- rx px))]
                  [vy0 (if use-away? (- away-y py) (- ry py))]
                  [len0 (sqrt (+ (* vx0 vx0) (* vy0 vy0)))]
                  [vx (if (<= len0 1e-6) 1.0 (/ vx0 len0))]
                  [vy (if (<= len0 1e-6) 0.0 (/ vy0 len0))])
             (loop (+ px (* min-dist vx))
                   (+ py (* min-dist vy))
                   (cdr pads)))
           (loop rx ry (cdr pads)))])))

;; Steps `step-dist` from `(ax, ay)` toward the next unreached highway waypoint, avoiding pads.
(define (next-creep-highway-target ax ay
                                   [step-dist SC2-CREEP-TUMOR-STEP-DISTANCE]
                                   #:waypoints [waypoints '()]
                                   #:avoid-pads [avoid-pads '()]
                                   #:enemy-x [enemy-x SC2-DEFAULT-ENEMY-BASE-X]
                                   #:enemy-y [enemy-y SC2-DEFAULT-ENEMY-BASE-Y])
  (define wp
    (or (findf (lambda (pt)
                 (and (pair? pt) (> (dist2d ax ay (car pt) (cdr pt)) 6.0)))
               (if (list? waypoints) waypoints '()))
        (cons enemy-x enemy-y)))
  (define dx (- (car wp) ax))
  (define dy (- (cdr wp) ay))
  (define d (max 1.0 (sqrt (+ (* dx dx) (* dy dy)))))
  (nudge-off-expansion-pads (+ ax (* step-dist (/ dx d)))
                            (+ ay (* step-dist (/ dy d)))
                            avoid-pads
                            5.0
                            enemy-x
                            enemy-y))

;; Chooses an uncontested completed Hatchery/Lair/Hive away from main as a Zerg build anchor.
(define (safe-zerg-build-anchor base-x base-y ally-bldgs
                                [enemy-units '()]
                                [enemy-bldgs '()]
                                [default-x (safe-coord (+ base-x 3.0))]
                                [default-y (safe-coord (+ base-y 3.0))])
  (define enemies (append (if (list? enemy-units) enemy-units '())
                          (if (list? enemy-bldgs) enemy-bldgs '())))
  (define (hostile-near? hx hy [rad 16.0])
    (ormap (lambda (e)
             (and (hash? e)
                  (<= (dist2d hx hy (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0)) rad)))
           enemies))
  (define safe-h
    (findf (lambda (h)
             (and (hash? h)
                  (memq (sc2-canonical-structure-sym (unit-type-sym h))
                        '(hatchery lair hive))
                  (>= (hash-ref h 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS)
                  (let ([hx (hash-ref h 'x base-x)]
                        [hy (hash-ref h 'y base-y)])
                    (and (> (dist2d base-x base-y hx hy) 8.0)
                         (not (hostile-near? hx hy 16.0))))))
           (if (list? ally-bldgs) ally-bldgs '())))
  (if safe-h
      (values (safe-coord (+ (hash-ref safe-h 'x default-x) 3.0))
              (safe-coord (+ (hash-ref safe-h 'y default-y) 3.0)))
      (values default-x default-y)))

;; Computes candidate 6x6-clear off-path stealth proxy sites `(Listof (Pairof Float Float))`
;; at 32%-48% of the `enemy-main -> our-main` vector, displaced 24.0-38.0 tiles perpendicular
;; (+90 deg / -90 deg) off both the main<->main and nat<->nat scouting corridors, >= 9.0 tiles
;; from all expansion pads, and verified buildable/flat on `map-grids` when provided.
(define (compute-off-path-proxy-candidates
         our-main-x our-main-y our-nat-x our-nat-y
         enemy-main-x enemy-main-y enemy-nat-x enemy-nat-y
         #:map-grids [map-grids #f]
         #:variant-idx [variant-idx 0]
         #:expansion-pads [expansion-pads '()])
  (define omx (exact->inexact our-main-x))
  (define omy (exact->inexact our-main-y))
  (define onx (exact->inexact our-nat-x))
  (define ony (exact->inexact our-nat-y))
  (define emx (exact->inexact enemy-main-x))
  (define emy (exact->inexact enemy-main-y))
  (define enx (exact->inexact enemy-nat-x))
  (define eny (exact->inexact enemy-nat-y))
  (define center-x (* 0.5 (+ omx emx)))
  (define center-y (* 0.5 (+ omy emy)))
  (define vx (- omx emx))
  (define vy (- omy emy))
  (define axis-len (max 1.0 (sqrt (+ (* vx vx) (* vy vy)))))
  (define ux (/ vx axis-len))
  (define uy (/ vy axis-len))
  ;; Perpendicular basis vectors (+90 deg and -90 deg)
  (define px-pos (- uy))
  (define py-pos ux)
  (define-values (grids-ok? w h pref bref href) (extract-map-grid-accessors map-grids))
  (define min-x (if grids-ok? 8.0 SC2-MAP-PLAYABLE-MIN-COORD))
  (define min-y (if grids-ok? 8.0 SC2-MAP-PLAYABLE-MIN-COORD))
  (define max-x (if grids-ok? (max 16.0 (- (exact->inexact w) 8.0)) SC2-MAP-PLAYABLE-MAX-COORD))
  (define max-y (if grids-ok? (max 16.0 (- (exact->inexact h) 8.0)) SC2-MAP-PLAYABLE-MAX-COORD))
  (define all-pads
    (append (list (cons omx omy) (cons onx ony) (cons emx emy) (cons enx eny))
            (filter-map (lambda (p) (pad->xy p center-x center-y))
                        (if (list? expansion-pads) expansion-pads '()))))
  (define (pad-clear? cx cy)
    (for/and ([ep (in-list all-pads)])
      (>= (dist-2d cx cy (car ep) (cdr ep)) 9.0)))
  (define (in-map-bounds? cx cy)
    (and (>= cx min-x) (<= cx max-x)
         (>= cy min-y) (<= cy max-y)))
  (define (buildable-6x6? cx cy)
    (or (not grids-ok?)
        (let* ([raw-h (and (procedure? href) (href (exact-round cx) (exact-round cy)))]
               [target-h (if (real? raw-h) (exact->inexact raw-h) 10.0)])
          (footprint-buildable-at-height? cx cy 3.0 3.0 w h bref href target-h #t pref))))
  (define strict-cands '())
  (define relaxed-cands '())
  (define seen-keys (mutable-set))
  ;; Interleave +90 deg / -90 deg across forward fractions and lateral displacements
  (for* ([t (in-list '(0.38 0.44 0.34 0.48 0.32))]
         [d-perp (in-list '(28.0 32.0 36.0 24.0 38.0))]
         [sign (in-list '(1.0 -1.0))])
    (define raw-x (+ emx (* t vx) (* sign d-perp px-pos)))
    (define raw-y (+ emy (* t vy) (* sign d-perp py-pos)))
    (define cx (snap-3x3-coord raw-x))
    (define cy (snap-3x3-coord raw-y))
    (define key (cons (exact-round cx) (exact-round cy)))
    (when (and (not (set-member? seen-keys key))
               (in-map-bounds? cx cy)
               (pad-clear? cx cy)
               (buildable-6x6? cx cy))
      (set-add! seen-keys key)
      (define d-main (point-to-segment-dist cx cy omx omy emx emy))
      (define d-nat (point-to-segment-dist cx cy onx ony enx eny))
      (define d-ctr (dist-2d cx cy center-x center-y))
      (define min-corridor-d (min d-main d-nat))
      (cond
        [(and (>= d-main 24.0) (<= d-main 42.0) (>= d-nat 24.0))
         (set! strict-cands
               (cons (list cx cy min-corridor-d d-ctr) strict-cands))]
        [(>= min-corridor-d 16.0)
         (set! relaxed-cands
               (cons (list cx cy min-corridor-d d-ctr) relaxed-cands))])))
  (define scored
    (if (not (null? strict-cands))
        (reverse strict-cands)
        (sort (reverse relaxed-cands)
              (lambda (a b) (> (caddr a) (caddr b))))))
  (cond
    [(not (null? scored))
     (map (lambda (entry) (cons (car entry) (cadr entry))) scored)]
    [else
     ;; Playable fallback off-axis point clamped to bounds
     (define fb-x (max min-x (min max-x (snap-3x3-coord (+ emx (* 0.40 vx) (* 26.0 px-pos))))))
     (define fb-y (max min-y (min max-y (snap-3x3-coord (+ emy (* 0.40 vy) (* 26.0 py-pos))))))
     (list (cons fb-x fb-y))]))

;; Selects the `variant-idx`-th 6x6-clear off-path stealth proxy coordinate `(values px py)`.
(define (compute-off-path-proxy-site
         our-main-x our-main-y our-nat-x our-nat-y
         enemy-main-x enemy-main-y enemy-nat-x enemy-nat-y
         #:map-grids [map-grids #f]
         #:variant-idx [variant-idx 0]
         #:expansion-pads [expansion-pads '()])
  (define cands
    (compute-off-path-proxy-candidates
     our-main-x our-main-y our-nat-x our-nat-y
     enemy-main-x enemy-main-y enemy-nat-x enemy-nat-y
     #:map-grids map-grids
     #:variant-idx variant-idx
     #:expansion-pads expansion-pads))
  (define idx
    (if (null? cands)
        0
        (modulo (max 0 (inexact->exact (truncate variant-idx))) (length cands))))
  (define chosen (list-ref cands idx))
  (values (car chosen) (cdr chosen)))

;; =============================================================================
;; 5. Bayesian Expansion Pad Scoring & Uncamped Pad Selection
;; =============================================================================

(define NONCOMBAT-PLACEMENT-SYM-SET
  (list->seteq
   '(drone probe scv overlord overseer queen larva egg cocoon mule observer
     overlord-cocoon transport-overlord-cocoon baneling-cocoon ravager-cocoon
     brood-lord-cocoon lurker-egg lurker-mp-egg
     creep-tumor creep-tumor-burrowed creep-tumor-queen
     warp-prism warp-prism-phasing observer-siege-mode overseer-siege-mode
     medivac overlord-transport
     interceptor auto-turret point-defense-drone raven-repair-drone
     adept-phase-shift disruptor-phased)))

(define (placement-combat-unit-record? u)
  (and (hash? u)
       (let ([t (unit-type-sym u)])
         (and (not (set-member? NONCOMBAT-PLACEMENT-SYM-SET t))
              (not (sc2-non-combat-or-summon-sym? t))
              (not (eq? (hash-ref u 'is-hallucination #f) #t))
              (not (eq? (hash-ref u 'hallucination #f) #t))
              (not (eq? (hash-ref u 'hallucination? #f) #t))))))

;; Converts pair, 2-element list, or `x`/`y` hash into a clamped `(cons x y)` or `#f`.
(define (pad->xy p [fallback-x SC2-DEFAULT-THIRD-X] [fallback-y SC2-DEFAULT-THIRD-Y])
  (cond
    [(and (pair? p) (real? (car p)) (real? (cdr p)))
     (cons (safe-coord (car p) fallback-x) (safe-coord (cdr p) fallback-y))]
    [(and (pair? p) (real? (car p)) (pair? (cdr p)) (real? (cadr p)))
     (cons (safe-coord (car p) fallback-x) (safe-coord (cadr p) fallback-y))]
    [(hash? p)
     (cons (safe-coord (hash-ref p 'x fallback-x) fallback-x)
           (safe-coord (hash-ref p 'y fallback-y) fallback-y))]
    [else #f]))

;; Returns #t if `(px, py)` is within 7.0 tiles of `(base-x, base-y)` or an existing townhall.
(define (pad-already-owned? px py base-x base-y [townhalls '()])
  (or (<= (dist2d px py base-x base-y) 7.0)
      (ormap (lambda (th)
               (and (hash? th)
                    (<= (dist2d px py (hash-ref th 'x base-x) (hash-ref th 'y base-y)) 7.0)))
             (if (list? townhalls) townhalls '()))))

;; Computes Bayesian posterior P(pad is camped by enemy) for candidate expansion `(px, py)`.
(define (pad-camped-posterior px py
                              [radius 11.5]
                              #:base-x [base-x SC2-DEFAULT-HOME-BASE-X]
                              #:base-y [base-y SC2-DEFAULT-HOME-BASE-Y]
                              #:enemy-x [enemy-x SC2-DEFAULT-ENEMY-BASE-X]
                              #:enemy-y [enemy-y SC2-DEFAULT-ENEMY-BASE-Y]
                              #:enemy-units [enemy-units '()]
                              #:enemy-bldgs [enemy-bldgs '()]
                              #:ally-combat-units [ally-combat-units '()]
                              #:live-obs? [live-obs? #f]
                              #:rush-posterior [rush-post 0.12])
  (define camp-bldg?
    (ormap (lambda (eb)
             (and (hash? eb)
                  (let ([canon (sc2-canonical-structure-sym (unit-type-sym eb))])
                    (and (or (memq canon '(photon-cannon bunker planetary-fortress spine-crawler
                                           hatchery lair hive nexus command-center orbital-command))
                             (memq canon SC2-TOWNHALL-STRUCTURE-SYMS))
                         (<= (dist2d px py (hash-ref eb 'x 9999.0) (hash-ref eb 'y 9999.0)) radius)))))
           (if (list? enemy-bldgs) enemy-bldgs '())))
  (define camp-combat-cnt
    (count (lambda (e)
             (and (placement-combat-unit-record? e)
                  (<= (dist2d px py (hash-ref e 'x 9999.0) (hash-ref e 'y 9999.0)) radius)))
           (if (list? enemy-units) enemy-units '())))
  (define ally-near-cnt
    (count (lambda (a)
             (and (hash? a)
                  (<= (dist2d px py (hash-ref a 'x base-x) (hash-ref a 'y base-y)) 14.0)))
           (if (list? ally-combat-units) ally-combat-units '())))
  (compute-bayesian-pad-camped-posterior
   #:camp-building-observed? camp-bldg?
   #:enemy-combat-count camp-combat-cnt
   #:ally-defender-count ally-near-cnt
   #:total-ally-combat-count (if (list? ally-combat-units) (length ally-combat-units) 0)
   #:live-obs? live-obs?
   #:dist-to-our-base (dist2d px py base-x base-y)
   #:dist-to-enemy-base (dist2d px py enemy-x enemy-y)
   #:rush-posterior rush-post))

;; Returns #t when Bayesian camp posterior at `(px, py)` reaches `>= 0.55`.
(define (pad-camped-by-enemy? px py
                              [radius 11.5]
                              #:base-x [base-x SC2-DEFAULT-HOME-BASE-X]
                              #:base-y [base-y SC2-DEFAULT-HOME-BASE-Y]
                              #:enemy-x [enemy-x SC2-DEFAULT-ENEMY-BASE-X]
                              #:enemy-y [enemy-y SC2-DEFAULT-ENEMY-BASE-Y]
                              #:enemy-units [enemy-units '()]
                              #:enemy-bldgs [enemy-bldgs '()]
                              #:ally-combat-units [ally-combat-units '()]
                              #:live-obs? [live-obs? #f]
                              #:rush-posterior [rush-post 0.12])
  (>= (pad-camped-posterior px py radius
                            #:base-x base-x
                            #:base-y base-y
                            #:enemy-x enemy-x
                            #:enemy-y enemy-y
                            #:enemy-units enemy-units
                            #:enemy-bldgs enemy-bldgs
                            #:ally-combat-units ally-combat-units
                            #:live-obs? live-obs?
                            #:rush-posterior rush-post)
      0.55))

;; Selects an unowned, uncamped expansion pad `(values x y)` avoiding proxy-blocked natural or enemy side.
(define (select-uncamped-expansion-pad expansion-pads
                                       [prefer-natural? #f]
                                       #:base-x [base-x SC2-DEFAULT-HOME-BASE-X]
                                       #:base-y [base-y SC2-DEFAULT-HOME-BASE-Y]
                                       #:nat-x [nat-x SC2-DEFAULT-NATURAL-X]
                                       #:nat-y [nat-y SC2-DEFAULT-NATURAL-Y]
                                       #:third-x [third-x SC2-DEFAULT-THIRD-X]
                                       #:third-y [third-y SC2-DEFAULT-THIRD-Y]
                                       #:enemy-x [enemy-x SC2-DEFAULT-ENEMY-BASE-X]
                                       #:enemy-y [enemy-y SC2-DEFAULT-ENEMY-BASE-Y]
                                       #:townhalls [townhalls '()]
                                       #:enemy-units [enemy-units '()]
                                       #:enemy-bldgs [enemy-bldgs '()]
                                       #:ally-combat-units [ally-combat-units '()]
                                       #:natural-blocked? [obs-natural-blocked? #f]
                                       #:live-obs? [live-obs? #f]
                                       #:active-bases [active-bases (if (list? townhalls) (length townhalls) 1)]
                                       #:frame [frame 0]
                                       #:rush-posterior [rush-post 0.12])
  (define e-units (if (list? enemy-units) enemy-units '()))
  (define e-bldgs (if (list? enemy-bldgs) enemy-bldgs '()))
  (define a-combat (if (list? ally-combat-units) ally-combat-units '()))
  (define ths (if (list? townhalls) townhalls '()))
  (define (camped-post px py)
    (pad-camped-posterior px py 11.5
                          #:base-x base-x
                          #:base-y base-y
                          #:enemy-x enemy-x
                          #:enemy-y enemy-y
                          #:enemy-units e-units
                          #:enemy-bldgs e-bldgs
                          #:ally-combat-units a-combat
                          #:live-obs? live-obs?
                          #:rush-posterior rush-post))
  (define natural-blockers
    (filter (lambda (e)
              (and (hash? e)
                   (<= (dist2d nat-x nat-y (hash-ref e 'x 9999) (hash-ref e 'y 9999))
                       SC2-NATURAL-BLOCK-RADIUS)))
            (append e-units e-bldgs)))
  (define natural-blocked?
    (or obs-natural-blocked?
        (>= (camped-post nat-x nat-y) 0.55)
        (and (<= (length ths) 1)
             (< frame 2500)
             (not (null? natural-blockers)))))
  (cond
    [(and prefer-natural?
          (not natural-blocked?)
          (not (pad-already-owned? nat-x nat-y base-x base-y ths)))
     (values nat-x nat-y)]
    [else
     (define cand-pts
       (append (filter-map (lambda (p) (pad->xy p third-x third-y))
                           (if (list? expansion-pads) expansion-pads '()))
               (list (cons third-x third-y))))
     (define valid-pts
       (filter (lambda (pt)
                 (define px (car pt))
                 (define py (cdr pt))
                 (and (not (pad-already-owned? px py base-x base-y ths))
                      (or (not natural-blocked?)
                          (> (dist2d px py nat-x nat-y) 7.0))
                      (or (not live-obs?)
                          (>= active-bases 4)
                          (not (and (< (dist2d px py enemy-x enemy-y) 42.0)
                                    (> (dist2d px py base-x base-y)
                                       (dist2d px py enemy-x enemy-y)))))
                      (< (camped-post px py) 0.55)))
               cand-pts))
     (define chosen
       (or (findf (lambda (pt) (< (camped-post (car pt) (cdr pt)) 0.30)) valid-pts)
           (and (pair? valid-pts)
                (argmin (lambda (pt) (camped-post (car pt) (cdr pt))) valid-pts))))
     (if chosen
         (values (car chosen) (cdr chosen))
         (values #f #f))]))

;; =============================================================================
;; 7. Pro Base Layouts, Advanced SimCity & Worker Speed-Mining / Drill Geometry
;; =============================================================================

;; Extracts `(values ok? fx fy)` from a hash, `point2d`, pair, or 2-element list record.
(define (simcity-record->xy rec)
  (cond
    [(point2d? rec)
     (values #t (exact->inexact (point2d-x rec)) (exact->inexact (point2d-y rec)))]
    [(hash? rec)
     (define pos (hash-ref rec 'pos #f))
     (define rx (or (hash-ref rec 'x #f)
                    (and (hash? pos) (hash-ref pos 'x #f))
                    (and (point2d? pos) (point2d-x pos))))
     (define ry (or (hash-ref rec 'y #f)
                    (and (hash? pos) (hash-ref pos 'y #f))
                    (and (point2d? pos) (point2d-y pos))))
     (if (and (real? rx) (real? ry))
         (values #t (exact->inexact rx) (exact->inexact ry))
         (values #f 0.0 0.0))]
    [(and (pair? rec) (real? (car rec)) (real? (cdr rec)))
     (values #t (exact->inexact (car rec)) (exact->inexact (cdr rec)))]
    [(and (pair? rec) (real? (car rec)) (pair? (cdr rec)) (real? (cadr rec)))
     (values #t (exact->inexact (car rec)) (exact->inexact (cadr rec)))]
    [else (values #f 0.0 0.0)]))

;; Normalizes `race` (`'Terran` / `'Protoss` / `'Zerg`), inferring from structure if ambiguous.
(define (normalize-simcity-race race canon)
  (define s
    (cond
      [(symbol? race) (string-downcase (symbol->string race))]
      [(string? race) (string-downcase race)]
      [else ""]))
  (cond
    [(or (string=? s "terran") (string=? s "t")) 'Terran]
    [(or (string=? s "protoss") (string=? s "p")) 'Protoss]
    [(or (string=? s "zerg") (string=? s "z")) 'Zerg]
    [(memq canon '(barracks factory starport supply-depot bunker missile-turret
                   sensor-tower engineering-bay armory fusion-core ghost-academy
                   command-center orbital-command planetary-fortress))
     'Terran]
    [(memq canon '(pylon gateway warp-gate cybernetics-core forge photon-cannon
                   shield-battery robotics-facility robotics-bay robotics-support-bay
                   twilight-council stargate fleet-beacon templar-archive dark-shrine nexus))
     'Protoss]
    [else 'Zerg]))

;; Returns minimum Euclidean distance from `(px, py)` to line segment `(ax, ay)-(bx, by)`.
(define (point-to-segment-dist2d px py ax ay bx by)
  (define vx (- bx ax))
  (define vy (- by ay))
  (define len2 (+ (* vx vx) (* vy vy)))
  (cond
    [(<= len2 1e-6) (dist2d px py ax ay)]
    [else
     (define t (max 0.0 (min 1.0 (/ (+ (* (- px ax) vx) (* (- py ay) vy)) len2))))
     (dist2d px py (+ ax (* t vx)) (+ ay (* t vy)))]))

;; Collects resource avoidance AABBs and `(x . y)` point lists for mineral patches and geysers.
(define (collect-simcity-resource-geometry mineral-patches geysers)
  (define aabbs '())
  (define min-pts '())
  (define geyser-pts '())
  (for ([m (in-list (if (list? mineral-patches) mineral-patches '()))])
    (define-values (ok? mx my) (simcity-record->xy m))
    (when ok?
      (set! min-pts (cons (cons mx my) min-pts))
      (set! aabbs (cons (reserved-aabb mx my 1.15 0.90 'mineral-patch 0 0) aabbs))))
  (for ([g (in-list (if (list? geysers) geysers '()))])
    (define-values (ok? gx gy) (simcity-record->xy g))
    (when ok?
      (set! geyser-pts (cons (cons gx gy) geyser-pts))
      (set! aabbs (cons (reserved-aabb gx gy 1.65 1.65 'geyser 0 0) aabbs))))
  (values aabbs (reverse min-pts) (reverse geyser-pts)))

;; Computes local mineral/geyser centroid and unit away-from-minerals vector `(away-ux, away-uy)` at a base.
(define (compute-base-mineral-geometry bx-f by-f min-pts geyser-pts fallback-ux fallback-uy)
  (define local-mins (filter (lambda (p) (<= (dist2d bx-f by-f (car p) (cdr p)) 13.0)) min-pts))
  (define local-geysers (filter (lambda (p) (<= (dist2d bx-f by-f (car p) (cdr p)) 13.5)) geyser-pts))
  (cond
    [(not (null? local-mins))
     (define n (length local-mins))
     (define mcx (/ (for/sum ([p (in-list local-mins)]) (car p)) n))
     (define mcy (/ (for/sum ([p (in-list local-mins)]) (cdr p)) n))
     (define dx (- bx-f mcx))
     (define dy (- by-f mcy))
     (define d (sqrt (+ (* dx dx) (* dy dy))))
     (define-values (aux auy)
       (if (> d 0.5) (values (/ dx d) (/ dy d)) (values fallback-ux fallback-uy)))
     (values #t mcx mcy aux auy local-mins local-geysers)]
    [else
     (define fx (- bx-f (* 6.5 fallback-ux)))
     (define fy (- by-f (* 6.5 fallback-uy)))
     (values #f fx fy fallback-ux fallback-uy '() local-geysers)]))

;; Queries `href` via `grid-height-val` with a numeric sentinel and returns `fallback` (`#f` or real) if unavailable.
(define (simcity-grid-height-or-false href ix iy [fallback #f])
  (cond
    [(not (procedure? href)) (if (real? fallback) (exact->inexact fallback) #f)]
    [else
     (define sentinel -999999.0)
     (define h (grid-height-val href ix iy sentinel))
     (if (= h sentinel)
         (if (real? fallback) (exact->inexact fallback) #f)
         h)]))

;; Estimates minimum distance from `(cx, cy)` to any cliff / unpathable cell on `map-grids`.
(define (simcity-cliff-edge-dist cx cy base-h grids-ok? w h pref href)
  (if (not grids-ok?)
      99.0
      (or (for*/first ([r (in-list '(1.5 2.5 3.5 4.5 6.0))]
                       [dxy (in-list (list (cons r 0.0) (cons (- r) 0.0)
                                           (cons 0.0 r) (cons 0.0 (- r))
                                           (cons (* 0.707 r) (* 0.707 r))
                                           (cons (* -0.707 r) (* 0.707 r))
                                           (cons (* 0.707 r) (* -0.707 r))
                                           (cons (* -0.707 r) (* -0.707 r))))]
                       #:do [(define ix (exact-floor (+ cx (car dxy))))
                             (define iy (exact-floor (+ cy (cdr dxy))))]
                       #:when (or (< ix 0) (>= ix w) (< iy 0) (>= iy h)
                                  (not (grid-cell-positive? (pref ix iy)))
                                  (and (real? base-h)
                                       (> (abs (- (grid-height-val href ix iy base-h) base-h)) 1.5))))
            r)
          8.0)))

;; Checks site clearance against AABBs, resources, mining lanes, exclusions, and optional terrain grids.
(define (simcity-site-valid? canon cx cy phys-aabbs addon-aabbs res-aabbs exp-pads
                             grids-ok? w h pref bref href target-h
                             #:disallow-aabbs [disallow-aabbs '()]
                             #:corridors [corridors '()]
                             #:corridor-min-dist [corridor-min-dist 2.0]
                             #:require-terrain? [require-terrain? #t]
                             #:allow-addon-overlap? [allow-addon-overlap? #f])
  (define-values (hw hh) (if (symbol? canon) (sc2-structure-half-dims canon) (values 1.5 1.5)))
  (define addon-fac? (and (not allow-addon-overlap?) (memq canon '(barracks factory starport))))
  ;; When addon overlap fallback is explicitly enabled for 3x3 Terran production, skip East addon clearance while preserving 3x3 footprint.
  (define free-canon (if (and allow-addon-overlap? (memq canon '(barracks factory starport))) 'engineering-bay canon))
  (define eff-addon-aabbs (if allow-addon-overlap? '() addon-aabbs))
  (define-values (ax ay) (terran-addon-pad-pos cx cy))
  (and (placement-site-free? free-canon cx cy phys-aabbs eff-addon-aabbs exp-pads #f)
       (not (ormap (lambda (b) (aabb-overlaps? cx cy hw hh b)) res-aabbs))
       (not (ormap (lambda (b) (aabb-overlaps? cx cy hw hh b)) disallow-aabbs))
       (or (not addon-fac?)
           (and (not (ormap (lambda (b) (aabb-overlaps? ax ay 1.0 1.0 b)) res-aabbs))
                (not (ormap (lambda (b) (aabb-overlaps? ax ay 1.0 1.0 b)) disallow-aabbs))))
       (or (not require-terrain?)
           (not grids-ok?)
           (and (footprint-buildable-at-height? cx cy hw hh w h bref href (if (real? target-h) target-h 0.0) (real? target-h) pref)
                (or (not addon-fac?)
                    (footprint-buildable-at-height? ax ay 1.0 1.0 w h bref href (if (real? target-h) target-h 0.0) (real? target-h) pref))))
       (not (ormap (lambda (seg)
                     (< (point-to-segment-dist2d cx cy (car seg) (cadr seg) (caddr seg) (cadddr seg))
                        corridor-min-dist))
                   corridors))))

;; Builds Drone/SCV/Probe mining-lane segments around townhalls and local minerals/geysers.
(define (collect-mining-corridors base-x base-y min-pts geyser-pts [extra-townhalls '()])
  (define hubs (cons (cons (exact->inexact base-x) (exact->inexact base-y)) extra-townhalls))
  (define res (append min-pts geyser-pts))
  (for*/list ([h (in-list hubs)]
              [r (in-list res)]
              #:when (<= (dist2d (car h) (cdr h) (car r) (cdr r)) 12.5))
    (list (car h) (cdr h) (car r) (cdr r))))

;; Returns existing non-flying `ally-bldgs` filtered by canonical structure symbols.
(define (filter-ally-structures-by-syms ally-bldgs sym-set)
  (filter (lambda (b)
            (and (hash? b)
                 (not (eq? (hash-ref b 'flying? #f) #t))
                 (not (eq? (hash-ref b 'is-flying #f) #t))
                 (memq (sc2-canonical-structure-sym (unit-type-sym b)) sym-set)))
          (if (list? ally-bldgs) ally-bldgs '())))

;; Chooses active expansion anchor `(values tx ty is-third?)` preferring Natural until guarded or 3rd owned.
(define (select-simcity-expansion-locus bx-f by-f nx-f ny-f ally-bldgs expansion-pads def-cnt-nat townhall-syms)
  (define ths (filter-ally-structures-by-syms ally-bldgs townhall-syms))
  (define extra-ths
    (sort
     (filter (lambda (b)
               (define x (exact->inexact (hash-ref b 'x bx-f)))
               (define y (exact->inexact (hash-ref b 'y by-f)))
               (and (> (dist2d x y bx-f by-f) 10.0)
                    (> (dist2d x y nx-f ny-f) 10.0)))
             ths)
     <
     #:key (lambda (b) (dist2d (hash-ref b 'x bx-f) (hash-ref b 'y by-f) bx-f by-f))))
  (define third-pt
    (cond
      [(not (null? extra-ths))
       (cons (exact->inexact (hash-ref (car extra-ths) 'x nx-f))
             (exact->inexact (hash-ref (car extra-ths) 'y ny-f)))]
      [(>= def-cnt-nat 2)
       (define cand-pads
         (filter-map (lambda (p)
                       (define-values (ok? px py) (simcity-record->xy p))
                       (and ok?
                            (> (dist2d px py bx-f by-f) 10.0)
                            (> (dist2d px py nx-f ny-f) 10.0)
                            (cons px py)))
                     (if (list? expansion-pads) expansion-pads '())))
       (and (not (null? cand-pads))
            (argmin (lambda (p) (dist2d (car p) (cdr p) bx-f by-f)) cand-pads))]
      [else #f]))
  (if (and third-pt (>= def-cnt-nat 2))
      (values (car third-pt) (cdr third-pt) #t)
      (values nx-f ny-f #f)))

(define *resolve-choke-frame-cache* (make-hash))

(define (choke-frame-grid-sig bx-f by-f tx-f ty-f is-third? grids-ok? w h pref bref href main-h nat-h)
  (cond
    [(not grids-ok?) #f]
    [is-third?
     (define h-tx (simcity-grid-height-or-false
                   href (max 0 (min (sub1 w) (exact-floor tx-f)))
                   (max 0 (min (sub1 h) (exact-floor ty-f)))
                   (or nat-h main-h)))
     (and (real? h-tx) (exact-round (* 10.0 h-tx)))]
    [else
     (define (clamp-x fx) (max 0 (min (sub1 w) (exact-floor fx))))
     (define (clamp-y fy) (max 0 (min (sub1 h) (exact-floor fy))))
     (define mask 0)
     (define h-acc 0)
     (define-syntax-rule (sample-pt! fx fy)
       (let ([ix (clamp-x fx)]
             [iy (clamp-y fy)])
         (set! mask (+ (* mask 4)
                       (bitwise-ior (if (grid-cell-positive? (pref ix iy)) 1 0)
                                    (if (grid-cell-positive? (bref ix iy)) 2 0))))
         (when (procedure? href)
           (set! h-acc (+ (* h-acc 31)
                          (exact-round (* 2.0 (grid-height-val href ix iy 0.0))))))))
     (for ([dxy (in-list '((0.0 . 0.0) (4.0 . 0.0) (-4.0 . 0.0) (0.0 . 4.0) (0.0 . -4.0)
                           (8.0 . 0.0) (-8.0 . 0.0) (0.0 . 8.0) (0.0 . -8.0)
                           (12.0 . 0.0) (-12.0 . 0.0) (0.0 . 12.0) (0.0 . -12.0)
                           (6.0 . 6.0) (-6.0 . 6.0) (6.0 . -6.0) (-6.0 . -6.0)))])
       (sample-pt! (+ tx-f (car dxy)) (+ ty-f (cdr dxy))))
     (sample-pt! bx-f by-f)
     (sample-pt! (* 0.5 (+ bx-f tx-f)) (* 0.5 (+ by-f ty-f)))
     (cons mask h-acc)]))

;; Resolves `(values choke-x choke-y perp-ux perp-uy out-ux out-uy target-h)` for Natural or 3rd choke.
(define (resolve-choke-frame bx-f by-f tx-f ty-f ex-f ey-f is-third? grids-ok? w h pref bref href main-h nat-h)
  (define cache-key
    (list (exact-round (* 2.0 bx-f))
          (exact-round (* 2.0 by-f))
          (exact-round (* 2.0 tx-f))
          (exact-round (* 2.0 ty-f))
          (exact-round (* 2.0 ex-f))
          (exact-round (* 2.0 ey-f))
          (not (not is-third?))
          (not (not grids-ok?))
          w
          h
          (and (real? main-h) (exact-round (* 10.0 main-h)))
          (and (real? nat-h) (exact-round (* 10.0 nat-h)))
          (choke-frame-grid-sig bx-f by-f tx-f ty-f is-third? grids-ok? w h pref bref href main-h nat-h)))
  (define cached (hash-ref *resolve-choke-frame-cache* cache-key #f))
  (cond
    [cached (apply values cached)]
    [else
     (define res
       (let ()
         (define-values (out-ux out-uy)
           (compute-natural-exit-direction bx-f by-f tx-f ty-f ex-f ey-f
                                           (if grids-ok? w 200.0)
                                           (if grids-ok? h 200.0)))
         (define choke-cands
           (if (and grids-ok? (not is-third?))
               (find-natural-choke-candidates bx-f by-f tx-f ty-f ex-f ey-f w h pref bref href)
               '()))
         (cond
           [(not (null? choke-cands))
            (define best (car choke-cands))
            (list (exact->inexact (first best))
                  (exact->inexact (second best))
                  (exact->inexact (third best))
                  (exact->inexact (fourth best))
                  out-ux
                  out-uy
                  (if (real? (seventh best)) (seventh best) nat-h))]
           [else
            (define tgt-h (if grids-ok?
                              (simcity-grid-height-or-false
                               href (max 0 (min (sub1 w) (exact-floor tx-f)))
                               (max 0 (min (sub1 h) (exact-floor ty-f)))
                               (or nat-h main-h))
                              nat-h))
            (list (+ tx-f (* 7.5 out-ux))
                  (+ ty-f (* 7.5 out-uy))
                  (- out-uy)
                  out-ux
                  out-ux
                  out-uy
                  tgt-h)])))
     (when (>= (hash-count *resolve-choke-frame-cache*) 128)
       (hash-clear! *resolve-choke-frame-cache*))
     (hash-set! *resolve-choke-frame-cache* cache-key res)
     (apply values res)]))

;; Selects Terran `2x5` Production Matrix origin `(values ox oy col-step row-step)` (`dx=7.0`, `dy=5.0`).
(define (resolve-terran-2x5-matrix-frame bx-f by-f away-ux away-uy rampx rampy ramp-wall
                                         ally-bldgs phys-aabbs addon-aabbs res-aabbs exp-pads
                                         grids-ok? w h pref bref href main-h corridors)
  (define wall-bx (and (hash? ramp-wall) (pair? (hash-ref ramp-wall 'barracks #f))
                       (car (hash-ref ramp-wall 'barracks #f))))
  (define wall-by (and (hash? ramp-wall) (pair? (hash-ref ramp-wall 'barracks #f))
                       (cdr (hash-ref ramp-wall 'barracks #f))))
  (define existing-prod
    (filter (lambda (b)
              (define x (exact->inexact (hash-ref b 'x bx-f)))
              (define y (exact->inexact (hash-ref b 'y by-f)))
              (and (<= (dist2d x y bx-f by-f) 28.0)
                   (or (not (real? wall-bx)) (> (dist2d x y wall-bx wall-by) 3.5))
                   (> (dist2d x y rampx rampy) 4.0)))
            (filter-ally-structures-by-syms ally-bldgs '(barracks factory starport))))
  (define perp-ux (- away-uy))
  (define perp-uy away-ux)
  (define def-col-dir (if (>= away-ux -0.15) 7.0 -7.0))
  (define def-row-dir (if (>= away-uy -0.15) 5.0 -5.0))
  (define (make-dir-cands)
    (list (cons def-col-dir def-row-dir)
          (cons def-col-dir (- def-row-dir))
          (cons (- def-col-dir) def-row-dir)
          (cons (- def-col-dir) (- def-row-dir))))
  (cond
    [(not (null? existing-prod))
     ;; Anchor strictly to existing interior production building lattice (`dx=7.0`, `dy=5.0`).
     (define anchor (argmin (lambda (b) (dist2d (hash-ref b 'x bx-f) (hash-ref b 'y by-f) bx-f by-f))
                            existing-prod))
     (define ax (snap-3x3-coord (hash-ref anchor 'x bx-f)))
     (define ay (snap-3x3-coord (hash-ref anchor 'y by-f)))
     (define-values (_best-vc best-cd best-rd)
       (for/fold ([bvc -1] [bcd def-col-dir] [brd def-row-dir])
                 ([dr (in-list (make-dir-cands))]
                  #:break (= bvc 10))
         (define vc
           (for*/sum ([c (in-range 5)]
                      [r (in-range 2)]
                      #:do [(define sx (+ ax (* c (car dr))))
                            (define sy (+ ay (* r (cdr dr))))]
                      #:when (and (placement-in-playable-bounds? sx sy)
                                  (<= (dist2d sx sy bx-f by-f) 22.0)
                                  (or (not grids-ok?)
                                      (footprint-buildable-at-height? sx sy 1.5 1.5 w h bref href (if (real? main-h) main-h 0.0) (real? main-h) pref))))
             1))
         (if (> vc bvc)
             (values vc (car dr) (cdr dr))
             (values bvc bcd brd))))
     (values ax ay best-cd best-rd)]
    [else
     ;; Exact branch-and-bound in descending geometric-score order: max valid-cnt is 10 (+250.0),
     ;; with per-call half-tile memoization and inner remaining-slot pruning.
     (define slot-cache (make-hasheq))
     (define (matrix-slot-valid? sx sy)
       (and (placement-in-playable-bounds? sx sy)
            (let* ([kx (inexact->exact (round (* 2.0 sx)))]
                   [ky (inexact->exact (round (* 2.0 sy)))]
                   [k (+ (* kx 4096) ky)]
                   [cached (hash-ref slot-cache k 'miss)])
              (if (not (eq? cached 'miss))
                  cached
                  (let ([v (simcity-site-valid? 'barracks sx sy phys-aabbs addon-aabbs res-aabbs exp-pads
                                                grids-ok? w h pref bref href main-h
                                                #:corridors corridors
                                                #:corridor-min-dist 2.3)])
                    (hash-set! slot-cache k v)
                    v)))))
     (define slot-coords
       '((4 . 1) (4 . 0) (3 . 1) (3 . 0) (2 . 1) (2 . 0) (1 . 1) (1 . 0) (0 . 1) (0 . 0)))
     (define geo-cands
       (sort
        (for*/list ([side (in-list '(1.0 -1.0))]
                    [fwd (in-list '(6.5 9.5 12.5 3.5))]
                    [lat (in-list '(6.0 9.0 3.0 12.0))]
                    #:do [(define ox (snap-3x3-coord (+ bx-f (* fwd away-ux) (* side lat perp-ux))))
                          (define oy (snap-3x3-coord (+ by-f (* fwd away-uy) (* side lat perp-uy))))
                          (define d-base (dist2d ox oy bx-f by-f))
                          (define d-ramp (dist2d ox oy rampx rampy))
                          (define geo (- (- (* 0.65 (abs (- d-base 10.0))))
                                         (if (< d-ramp 6.5) 18.0 0.0)))])
          (list geo ox oy))
        > #:key first))
     (define dir-cands (make-dir-cands))
     (define-values (_best-sc best-ox best-oy best-cd best-rd)
       (for/fold ([bsc -inf.0] [box bx-f] [boy by-f] [bcd def-col-dir] [brd def-row-dir])
                 ([gc (in-list geo-cands)]
                  #:break (>= bsc (+ 250.0 (first gc))))
         (define geo (first gc))
         (define ox (second gc))
         (define oy (third gc))
         (for/fold ([bsc2 bsc] [box2 box] [boy2 boy] [bcd2 bcd] [brd2 brd])
                   ([dr (in-list dir-cands)]
                    #:break (>= bsc2 (+ 250.0 geo)))
           (define cd (car dr))
           (define rd (cdr dr))
           (define-values (valid-cnt _rem)
             (for/fold ([vc 0] [rem 10])
                       ([cr (in-list slot-coords)]
                        #:break (<= (+ (* 25.0 (+ vc rem)) geo) bsc2))
               (define sx (+ ox (* (car cr) cd)))
               (define sy (+ oy (* (cdr cr) rd)))
               (values (if (matrix-slot-valid? sx sy) (+ vc 1) vc)
                       (- rem 1))))
           (define sc (+ (* 25.0 valid-cnt) geo))
           (if (> sc bsc2)
               (values sc ox oy cd rd)
               (values bsc2 box2 boy2 bcd2 brd2)))))
     (values best-ox best-oy best-cd best-rd)]))

;; Builds reserved AABB bounding the entire Terran `2x5` Production Matrix (+ AddOn pads & lanes).
(define (make-terran-matrix-exclusion-aabb ox oy cd rd)
  (define x-end (+ ox (* 4.0 cd)))
  (define y-end (+ oy (* 1.0 rd)))
  (define min-x (- (min ox x-end) 2.0))
  (define max-x (+ (max ox x-end) 4.0))
  (define min-y (- (min oy y-end) 2.0))
  (define max-y (+ (max oy y-end) 2.0))
  (reserved-aabb (* 0.5 (+ min-x max-x))
                 (* 0.5 (+ min-y max-y))
                 (* 0.5 (- max-x min-x))
                 (* 0.5 (- max-y min-y))
                 'terran-prod-matrix 0 0))

;; Terran Pro SimCity placement (`2x5` matrix for production; ramp/cliff-perimeter vision ring for depots).
(define (simcity-point-list bldgs def-x def-y)
  (for/list ([b (in-list (if (list? bldgs) bldgs '()))])
    (cons (exact->inexact (hash-ref b 'x def-x))
          (exact->inexact (hash-ref b 'y def-y)))))

(define (simcity-locus-covered? lx ly def-pts radius)
  (for/or ([dp (in-list def-pts)])
    (<= (dist2d lx ly (car dp) (cdr dp)) radius)))

(define (simcity-active-base-mineral-loci ally-bldgs th-syms min-pts geyser-pts
                                          bx-f by-f nx-f ny-f grids-ok? w h href main-h)
  (define raw-ths (filter-ally-structures-by-syms ally-bldgs th-syms))
  (define ths
    (if (null? raw-ths)
        (list (hasheq 'x bx-f 'y by-f))
        (sort raw-ths < #:key (lambda (b)
                                (dist2d (hash-ref b 'x bx-f) (hash-ref b 'y by-f) bx-f by-f)))))
  (define dx-n (- nx-f bx-f))
  (define dy-n (- ny-f by-f))
  (define dn (max 1.0 (sqrt (+ (* dx-n dx-n) (* dy-n dy-n)))))
  (define fb-ux (/ dx-n dn))
  (define fb-uy (/ dy-n dn))
  (for/list ([th (in-list ths)])
    (define tx (exact->inexact (hash-ref th 'x bx-f)))
    (define ty (exact->inexact (hash-ref th 'y by-f)))
    (define-values (_has-mins? mcx mcy aux auy _lm _lg)
      (compute-base-mineral-geometry tx ty min-pts geyser-pts fb-ux fb-uy))
    (define th-h
      (if grids-ok?
          (simcity-grid-height-or-false href
                                        (max 0 (min (sub1 w) (exact-floor tx)))
                                        (max 0 (min (sub1 h) (exact-floor ty)))
                                        main-h)
          main-h))
    (list mcx mcy aux auy th-h tx ty)))

(define (simcity-critical-infra-anchors ally-bldgs infra-syms grids-ok? w h href default-h)
  (define ranked '())
  (for ([b (in-list (if (list? ally-bldgs) ally-bldgs '()))])
    (define atyp (sc2-canonical-structure-sym (unit-type-sym b)))
    (define tail (memq atyp infra-syms))
    (when tail
      (define bx (exact->inexact (hash-ref b 'x 0.0)))
      (define by (exact->inexact (hash-ref b 'y 0.0)))
      (define ah
        (if grids-ok?
            (simcity-grid-height-or-false href
                                          (max 0 (min (sub1 w) (exact-floor bx)))
                                          (max 0 (min (sub1 h) (exact-floor by)))
                                          default-h)
            default-h))
      ;; Prioritize earlier symbols in `infra-syms` (longer tail => earlier index)
      (set! ranked (cons (list (- (length tail)) bx by ah) ranked))))
  (map cdr (sort ranked < #:key car)))

;; Generates mineral-line defense candidates strictly within `9.0` tiles of `(mcx, mcy)` after snapping.
(define (simcity-mineral-line-def-cands mcx mcy aux auy [tx #f] [ty #f])
  (define rear-cands
    (for*/list ([depth (in-list '(2.5 4.0 1.5 -2.0 5.5 -3.5))]
                [lat (in-list '(0.0 3.0 -3.0 5.5 -5.5 7.0 -7.0))]
                #:when (<= (+ (* depth depth) (* lat lat)) 56.0))
      (cons (+ mcx (* (- depth) aux) (* lat (- auy)))
            (+ mcy (* (- depth) auy) (* lat aux)))))
  (define th-ring
    (if (and (real? tx) (real? ty))
        (filter (lambda (pt) (<= (dist2d (car pt) (cdr pt) mcx mcy) 7.8))
                (for*/list ([r (in-list '(4.2 5.5))]
                            [k (in-range 8)])
                  (define ang (* k (/ (* 2.0 pi) 8.0)))
                  (cons (+ tx (* r (cos ang))) (+ ty (* r (sin ang))))))
        '()))
  (define locus-ring
    (for*/list ([r (in-list '(3.5 5.0 6.5 7.5))]
                [k (in-range 8)])
      (define ang (* k (/ (* 2.0 pi) 8.0)))
      (cons (+ mcx (* r (cos ang))) (+ mcy (* r (sin ang))))))
  (append rear-cands th-ring locus-ring))

;; Generates defense candidates around critical infrastructure anchors within `9.5` tiles.
(define (simcity-anchor-def-cands ax ay)
  (for*/list ([r (in-list '(3.5 4.5 6.0 7.5))]
              [k (in-range 8)])
    (define ang (* k (/ (* 2.0 pi) 8.0)))
    (cons (+ ax (* r (cos ang))) (+ ay (* r (sin ang))))))

;; Bounded radial buildable-terrain fallback for SimCity solvers when strict slots are full/blocked.
;; Caps spiral evaluations at `max-evals` and validates buildable terrain before any gridless fallback.
(define (simcity-buildable-spiral-fallback canon anchors phys-aabbs addon-aabbs res-aabbs exp-pads
                                          grids-ok? w h pref bref href
                                          #:fallback-pt [fallback-pt #f]
                                          #:max-evals [max-evals 64]
                                          #:allow-addon-fallback? [allow-addon-fallback? #t])
  (define snap-fn (if (sc2-odd-footprint-structure? canon) snap-3x3-coord snap-2x2-coord))
  (define is-addon-fac? (memq canon '(barracks factory starport)))
  (define (search-pass allow-addon? req-terr? eval-cap)
    (define evals 0)
    (define seen (make-hash))
    (for*/first ([anc (in-list anchors)]
                 #:break (>= evals eval-cap)
                 [r (in-list '(3.0 4.5 6.0 7.5 9.0 11.5 14.0))]
                 #:break (>= evals eval-cap)
                 [k (in-range 8)]
                 #:break (>= evals eval-cap)
                 #:do [(define ang (* k (/ (* 2.0 pi) 8.0)))
                       (define sx (snap-fn (+ (car anc) (* r (cos ang)))))
                       (define sy (snap-fn (+ (cdr anc) (* r (sin ang)))))
                       (define sk (cons sx sy))]
                 #:unless (hash-has-key? seen sk)
                 #:do [(hash-set! seen sk #t)
                       (set! evals (add1 evals))]
                 #:when (simcity-site-valid? canon sx sy phys-aabbs addon-aabbs res-aabbs exp-pads
                                             grids-ok? w h pref bref href #f
                                             #:disallow-aabbs '()
                                             #:corridors '()
                                             #:require-terrain? req-terr?
                                             #:allow-addon-overlap? allow-addon?))
      (cons sx sy)))
  (define found
    (or (search-pass #f grids-ok? max-evals)
        (and allow-addon-fallback? is-addon-fac?
             (search-pass #t grids-ok? (max 32 (quotient max-evals 2))))))
  (cond
    [found (values (car found) (cdr found))]
    [else
     (define fb (or fallback-pt (and (pair? anchors) (car anchors)) (cons 64.0 64.0)))
     (spiral-search-free-point canon (car fb) (cdr fb)
                               phys-aabbs (if (and allow-addon-fallback? is-addon-fac?) '() addon-aabbs)
                               exp-pads #f)]))

(define (solve-terran-pro-simcity canon bx-f by-f nx-f ny-f ex-f ey-f
                                  ally-bldgs phys-aabbs addon-aabbs res-aabbs exp-pads
                                  min-pts geyser-pts grids-ok? w h pref bref href main-h nat-h map-grids corridors)
  (define-values (has-mins? min-cx min-cy away-ux away-uy _lm _lg)
    (compute-base-mineral-geometry bx-f by-f min-pts geyser-pts
                                   (/ (- nx-f bx-f) (max 1.0 (dist2d bx-f by-f nx-f ny-f)))
                                   (/ (- ny-f by-f) (max 1.0 (dist2d bx-f by-f nx-f ny-f)))))
  (define ramp-wall (solve-terran-ramp-wall bx-f by-f nx-f ny-f #:map-grids map-grids))
  (define ramp-pt (and (hash? ramp-wall) (hash-ref ramp-wall 'barracks #f)))
  (define rampx (if (pair? ramp-pt) (car ramp-pt) (+ bx-f (* 0.35 (- nx-f bx-f)))))
  (define rampy (if (pair? ramp-pt) (cdr ramp-pt) (+ by-f (* 0.35 (- ny-f by-f)))))
  (define-values (mx0 my0 cd rd)
    (resolve-terran-2x5-matrix-frame bx-f by-f away-ux away-uy rampx rampy ramp-wall
                                     ally-bldgs phys-aabbs addon-aabbs res-aabbs exp-pads
                                     grids-ok? w h pref bref href main-h corridors))
  (define matrix-aabb (make-terran-matrix-exclusion-aabb mx0 my0 cd rd))
  (define snap-fn (if (sc2-odd-footprint-structure? canon) snap-3x3-coord snap-2x2-coord))
  (define (first-valid cands [tgt-h main-h] [disallow '()] [req-terr? #t])
    (for/first ([pt (in-list cands)]
                #:do [(define sx (snap-fn (car pt)))
                      (define sy (snap-fn (cdr pt)))]
                #:when (simcity-site-valid? canon sx sy phys-aabbs addon-aabbs res-aabbs exp-pads
                                            grids-ok? w h pref bref href tgt-h
                                            #:disallow-aabbs disallow
                                            #:corridors corridors
                                            #:require-terrain? req-terr?))
      (cons sx sy)))
  (define picked
    (cond
      ;; 1. 2x5 Production Matrix (`dx=7.0`, `dy=5.0` aligned, AddOns & 2-tile egress guaranteed)
      [(memq canon '(barracks factory starport))
       (define (slot-in-base-or-nat? pt)
         (or (<= (dist2d (car pt) (cdr pt) bx-f by-f) 22.0)
             (<= (dist2d (car pt) (cdr pt) nx-f ny-f) 15.0)))
       (define primary-slots
         (filter slot-in-base-or-nat?
                 (for*/list ([c (in-range 5)]
                             [r (in-range 2)])
                   (cons (+ mx0 (* c cd)) (+ my0 (* r rd))))))
       (define overflow-slots
         (filter slot-in-base-or-nat?
                 (for*/list ([c (in-list '(-1 5 -2 6))]
                             [r (in-list '(0 1 -1 2))])
                   (cons (+ mx0 (* c cd)) (+ my0 (* r rd))))))
       (or (first-valid primary-slots main-h)
           (first-valid overflow-slots main-h)
           (first-valid (append primary-slots overflow-slots) nat-h)
           (for*/first ([allow-addon? (in-list '(#f #t))]
                        [pt (in-list (append primary-slots overflow-slots))]
                        #:do [(define sx (snap-fn (car pt)))
                              (define sy (snap-fn (cdr pt)))]
                        #:when (simcity-site-valid? canon sx sy phys-aabbs addon-aabbs res-aabbs exp-pads
                                                    grids-ok? w h pref bref href
                                                    (if (<= (dist2d sx sy bx-f by-f) 22.0) main-h nat-h)
                                                    #:disallow-aabbs '()
                                                    #:corridors '()
                                                    #:require-terrain? grids-ok?
                                                    #:allow-addon-overlap? allow-addon?))
             (cons sx sy)))]
      ;; 2. SupplyDepot: ramp wall slots first, then outer cliff perimeter vision ring (never inside matrix)
      [(eq? canon 'supply-depot)
       (define wall-depots
         (filter pair?
                 (list (and (hash? ramp-wall) (hash-ref ramp-wall 'depot-1 #f))
                       (and (hash? ramp-wall) (hash-ref ramp-wall 'depot-2 #f)))))
       (or (first-valid wall-depots main-h (list matrix-aabb))
           (let ()
             (define existing-depots (filter-ally-structures-by-syms ally-bldgs '(supply-depot)))
             (define ring-cands
               (sort
                (for*/list ([rad (in-list '(13.0 15.0 11.5 17.5))]
                            [k (in-range 0 16)])
                  (define ang (* k (/ (* 2.0 pi) 16.0)))
                  (define rx (snap-2x2-coord (+ bx-f (* rad (cos ang)))))
                  (define ry (snap-2x2-coord (+ by-f (* rad (sin ang)))))
                  (define valid?
                    (simcity-site-valid? 'supply-depot rx ry phys-aabbs addon-aabbs res-aabbs exp-pads
                                         grids-ok? w h pref bref href main-h
                                         #:disallow-aabbs (list matrix-aabb)
                                         #:corridors corridors))
                  (define sc
                    (if (not valid?)
                        -99999.0
                        (let ([cdist (simcity-cliff-edge-dist rx ry main-h grids-ok? w h pref href)]
                              [sep-score
                               (for/sum ([ed (in-list existing-depots)])
                                 (define d (dist2d rx ry (hash-ref ed 'x bx-f) (hash-ref ed 'y by-f)))
                                 (if (< d 4.5) (* -25.0 (- 4.5 d)) (min 8.0 d)))])
                          (+ (* -12.0 cdist)
                             (* 1.2 (min 18.0 rad))
                             (* 0.3 sep-score)
                             (if (and has-mins? (> (dist2d rx ry min-cx min-cy) 4.0)) 6.0 0.0)))))
                  (list sc rx ry))
                > #:key first))
             (or (let ([best-ring (findf (lambda (c) (> (first c) -9000.0)) ring-cands)])
                   (and best-ring (cons (second best-ring) (third best-ring))))
                 (first-valid (map (lambda (c) (cons (second c) (third c))) ring-cands) #f (list matrix-aabb) #f))))]
      ;; 3. Bunkers at Natural/3rd choke
      [(eq? canon 'bunker)
       (define existing-bunkers (filter-ally-structures-by-syms ally-bldgs '(bunker)))
       (define bunker-pts (simcity-point-list existing-bunkers bx-f by-f))
       (define bcnt-nat (length existing-bunkers))
       (define-values (tx-f ty-f is-3rd?)
         (select-simcity-expansion-locus bx-f by-f nx-f ny-f ally-bldgs exp-pads bcnt-nat '(command-center orbital-command planetary-fortress)))
       (define-values (cx cy px py ox oy tgt-h)
         (resolve-choke-frame bx-f by-f tx-f ty-f ex-f ey-f is-3rd? grids-ok? w h pref bref href main-h nat-h))
       (define choke-cands
         (for*/list ([back (in-list '(0.0 -2.0 -3.5 1.5))]
                     [lat (in-list '(0.0 3.5 -3.5 6.0 -6.0))])
           (cons (+ cx (* back ox) (* lat px)) (+ cy (* back oy) (* lat py)))))
       (define choke-bunkers
         (count (lambda (dp) (<= (dist2d cx cy (car dp) (cdr dp)) 11.0)) bunker-pts))
       (define (pick-choke-bunker)
         (or (first-valid choke-cands tgt-h (list matrix-aabb))
             (first-valid choke-cands #f (list matrix-aabb) #f)))
       (define (pick-mineral-bunker)
         (define base-loci
           (simcity-active-base-mineral-loci ally-bldgs '(command-center orbital-command planetary-fortress)
                                             min-pts geyser-pts bx-f by-f nx-f ny-f grids-ok? w h href main-h))
         (for/or ([locus (in-list base-loci)])
           (define mcx0 (list-ref locus 0))
           (define mcy0 (list-ref locus 1))
           (define aux0 (list-ref locus 2))
           (define auy0 (list-ref locus 3))
           (define th-h (list-ref locus 4))
           (define tx0 (list-ref locus 5))
           (define ty0 (list-ref locus 6))
           (and (not (simcity-locus-covered? mcx0 mcy0 bunker-pts 9.0))
                (let ([mc (simcity-mineral-line-def-cands mcx0 mcy0 aux0 auy0 tx0 ty0)])
                  (or (first-valid mc th-h (list matrix-aabb))
                      (first-valid mc #f (list matrix-aabb) #f))))))
       (define (pick-infra-bunker)
         (define anchors
           (simcity-critical-infra-anchors ally-bldgs '(starport fusion-core armory factory barracks engineering-bay)
                                           grids-ok? w h href main-h))
         (for/or ([anc (in-list anchors)])
           (define ax0 (car anc))
           (define ay0 (cadr anc))
           (define ah0 (caddr anc))
           (and (not (simcity-locus-covered? ax0 ay0 bunker-pts 9.5))
                (let ([ac (simcity-anchor-def-cands ax0 ay0)])
                  (or (first-valid ac ah0 (list matrix-aabb))
                      (first-valid ac #f (list matrix-aabb) #f))))))
       ;; Keep 1-2 Bunkers at Natural/3rd choke first, then uncoverd mineral lines, then critical infrastructure
       (if (and (< choke-bunkers 2) (< (length existing-bunkers) 2))
           (or (pick-choke-bunker) (pick-mineral-bunker) (pick-infra-bunker))
           (or (pick-mineral-bunker) (pick-infra-bunker) (pick-choke-bunker)))]
      ;; 4. Missile Turret covering all active mineral lines (<= 9.0 tiles), then critical tech/production anchors (<= 9.5 tiles)
      [(eq? canon 'missile-turret)
       (define existing-turrets (filter-ally-structures-by-syms ally-bldgs '(missile-turret)))
       (define turret-pts (simcity-point-list existing-turrets bx-f by-f))
       (define base-loci
         (simcity-active-base-mineral-loci ally-bldgs '(command-center orbital-command planetary-fortress)
                                           min-pts geyser-pts bx-f by-f nx-f ny-f grids-ok? w h href main-h))
       (define anchors
         (simcity-critical-infra-anchors ally-bldgs '(starport fusion-core armory factory barracks engineering-bay)
                                         grids-ok? w h href main-h))
       (or (for/or ([locus (in-list base-loci)])
             (define mcx0 (list-ref locus 0))
             (define mcy0 (list-ref locus 1))
             (define aux0 (list-ref locus 2))
             (define auy0 (list-ref locus 3))
             (define th-h (list-ref locus 4))
             (define tx0 (list-ref locus 5))
             (define ty0 (list-ref locus 6))
             (and (not (simcity-locus-covered? mcx0 mcy0 turret-pts 9.0))
                  (let ([mc (simcity-mineral-line-def-cands mcx0 mcy0 aux0 auy0 tx0 ty0)])
                    (or (first-valid mc th-h (list matrix-aabb))
                        (first-valid mc #f (list matrix-aabb) #f)))))
           (for/or ([anc (in-list anchors)])
             (define ax0 (car anc))
             (define ay0 (cadr anc))
             (define ah0 (caddr anc))
             (and (not (simcity-locus-covered? ax0 ay0 turret-pts 9.5))
                  (let ([ac (simcity-anchor-def-cands ax0 ay0)])
                    (or (first-valid ac ah0 (list matrix-aabb))
                        (first-valid ac #f (list matrix-aabb) #f)))))
           (let ([fb (simcity-mineral-line-def-cands min-cx min-cy away-ux away-uy bx-f by-f)])
             (or (first-valid fb main-h (list matrix-aabb))
                 (first-valid fb #f (list matrix-aabb) #f))))]
      ;; 5. Tech buildings (Engineering Bay, Armory, Fusion Core, Ghost Academy) alongside main pocket outside matrix
      [else
       (define cands
         (for*/list ([k (in-range 12)]
                     [r (in-list '(7.5 10.0 12.5))])
           (define ang (* k (/ (* 2.0 pi) 12.0)))
           (cons (+ bx-f (* r (cos ang))) (+ by-f (* r (sin ang))))))
       (define nat-cands
         (for*/list ([k (in-range 8)]
                     [r (in-list '(6.5 9.0 11.5))])
           (define ang (* k (/ (* 2.0 pi) 8.0)))
           (cons (+ nx-f (* r (cos ang))) (+ ny-f (* r (sin ang))))))
       (or (first-valid cands main-h (list matrix-aabb))
           (first-valid cands #f (list matrix-aabb) grids-ok?)
           (first-valid cands #f '() grids-ok?)
           (first-valid nat-cands nat-h '() grids-ok?)
           (first-valid nat-cands #f '() grids-ok?))]))
  (if picked
      (values (car picked) (cdr picked))
      (let ([fb-anchors (if (memq canon '(bunker missile-turret))
                            (list (cons nx-f ny-f)
                                  (cons bx-f by-f)
                                  (cons (+ bx-f (* 8.0 away-ux)) (+ by-f (* 8.0 away-uy))))
                            (list (cons (+ bx-f (* 8.0 away-ux)) (+ by-f (* 8.0 away-uy)))
                                  (cons bx-f by-f)
                                  (cons nx-f ny-f)))])
        (simcity-buildable-spiral-fallback
         canon fb-anchors phys-aabbs addon-aabbs res-aabbs exp-pads
         grids-ok? w h pref bref href
         #:fallback-pt (cons (+ bx-f (* 8.0 away-ux)) (+ by-f (* 8.0 away-uy)))))))

;; Protoss Pro SimCity (`Dual-Pylon` power matrix, Natural/Third 1-tile anti-runby wedge, rear mineral shadow tech).
(define (solve-protoss-pro-simcity canon bx-f by-f nx-f ny-f ex-f ey-f
                                   ally-bldgs phys-aabbs addon-aabbs res-aabbs exp-pads
                                   min-pts geyser-pts grids-ok? w h pref bref href main-h nat-h corridors)
  (define-values (_has-mins? min-cx min-cy away-ux away-uy _lm _lg)
    (compute-base-mineral-geometry bx-f by-f min-pts geyser-pts
                                   (/ (- nx-f bx-f) (max 1.0 (dist2d bx-f by-f nx-f ny-f)))
                                   (/ (- ny-f by-f) (max 1.0 (dist2d bx-f by-f nx-f ny-f)))))
  (define perp-ux (- away-uy))
  (define perp-uy away-ux)
  (define pylons (filter-ally-structures-by-syms ally-bldgs '(pylon)))
  (define pow-bldgs
    (filter (lambda (b) (sc2-structure-requires-pylon-power? (unit-type-sym b)))
            (filter-ally-structures-by-syms ally-bldgs
                                            '(gateway warp-gate cybernetics-core forge robotics-facility
                                              robotics-bay robotics-support-bay twilight-council stargate
                                              fleet-beacon templar-archive dark-shrine photon-cannon shield-battery))))
  (define (pylon-count-at x y)
    (count (lambda (p)
             (<= (dist2d x y (hash-ref p 'x -9999.0) (hash-ref p 'y -9999.0)) 6.2))
           pylons))
  ;; Dual-Pylon power spine centered in open main plateau: consecutive Pylons spaced `4.0` tiles apart,
  ;; flanking `3x3` Gateway/Tech columns spaced `4.5` tiles laterally with `2.0`-tile street egress lanes.
  (define raw-hub-x (snap-2x2-coord (+ bx-f (* 8.5 away-ux) (* 5.0 perp-ux))))
  (define raw-hub-y (snap-2x2-coord (+ by-f (* 8.5 away-uy) (* 5.0 perp-uy))))
  (define existing-main-pylon
    (findf (lambda (p) (<= (dist2d bx-f by-f (hash-ref p 'x 9999.0) (hash-ref p 'y 9999.0)) 18.0))
           pylons))
  (define spine-x (if existing-main-pylon (snap-2x2-coord (hash-ref existing-main-pylon 'x raw-hub-x)) raw-hub-x))
  (define spine-y (if existing-main-pylon (snap-2x2-coord (hash-ref existing-main-pylon 'y raw-hub-y)) raw-hub-y))
  (define spine-pylon-cands
    (for*/list ([col (in-list '(0.0 13.0 -13.0))]
                [dy (in-list '(0.0 4.0 -4.0 8.0 -8.0))])
      (cons (+ spine-x col) (+ spine-y dy))))
  (define matrix-3x3-slots
    (for*/list ([col (in-list '(0.0 13.0 -13.0))]
                [pair-dy (in-list '(2.5 -2.5 7.5 -7.5 12.5))]
                [side (in-list '(-4.5 4.5))])
      (cons (+ spine-x col side) (+ spine-y pair-dy))))
  (define snap-fn (if (sc2-odd-footprint-structure? canon) snap-3x3-coord snap-2x2-coord))
  (define (first-valid cands [tgt-h main-h] [req-terr? #t])
    (for/first ([pt (in-list cands)]
                #:do [(define sx (snap-fn (car pt)))
                      (define sy (snap-fn (cdr pt)))]
                #:when (simcity-site-valid? canon sx sy phys-aabbs addon-aabbs res-aabbs exp-pads
                                            grids-ok? w h pref bref href tgt-h
                                            #:corridors corridors
                                            #:require-terrain? req-terr?))
      (cons sx sy)))
  ;; Resolve Natural/3rd choke frame lazily only for flank/wall structures (never Pylon or hidden tech).
  (define (resolve-protoss-choke-context target-sym)
    (define nat-def-cnt
      (count (lambda (b)
               (<= (dist2d nx-f ny-f (hash-ref b 'x bx-f) (hash-ref b 'y by-f)) 15.0))
             (filter-ally-structures-by-syms ally-bldgs '(gateway warp-gate cybernetics-core forge shield-battery photon-cannon))))
    (define-values (tx-f ty-f is-3rd?)
      (select-simcity-expansion-locus bx-f by-f nx-f ny-f ally-bldgs exp-pads nat-def-cnt '(nexus)))
    (define-values (cx cy px py ox oy exp-h)
      (resolve-choke-frame bx-f by-f tx-f ty-f ex-f ey-f is-3rd? grids-ok? w h pref bref href main-h nat-h))
    (define (flank-anchor-rank b)
      (define atyp (sc2-canonical-structure-sym (unit-type-sym b)))
      (cond [(memq atyp '(gateway warp-gate cybernetics-core forge)) 0]
            [(memq atyp '(shield-battery photon-cannon)) 1]
            [else 2]))
    (define exp-flank-anchors
      (sort
       (filter (lambda (b)
                 (<= (dist2d tx-f ty-f (hash-ref b 'x bx-f) (hash-ref b 'y by-f)) 15.0))
               (filter-ally-structures-by-syms ally-bldgs '(gateway warp-gate cybernetics-core forge shield-battery photon-cannon nexus)))
       < #:key flank-anchor-rank))
    ;; Exact SC2 1.0-tile wedge gap: 3x3+3x3 = center delta 4.0; 3x3+2x2 = delta 3.5; 2x2+2x2 = delta 3.0.
    (define is-2x2? (not (sc2-odd-footprint-structure? target-sym)))
    (define anchor-wedged
      (append-map
       (lambda (a)
         (define ax (exact->inexact (hash-ref a 'x cx)))
         (define ay (exact->inexact (hash-ref a 'y cy)))
         (define atyp (sc2-canonical-structure-sym (unit-type-sym a)))
         (define anchor-5x5? (eq? atyp 'nexus))
         (define anchor-2x2? (memq atyp '(shield-battery photon-cannon)))
         (define step (cond [anchor-5x5? (if is-2x2? 4.5 5.0)]
                            [(and (not is-2x2?) (not anchor-2x2?)) 4.0]
                            [(and is-2x2? anchor-2x2?) 3.0]
                            [else 3.5]))
         (sort
          (list (cons (+ ax (* step px)) (+ ay (* step py)))
                (cons (- ax (* step px)) (- ay (* step py)))
                (cons (+ ax (* step ox)) (+ ay (* step oy)))
                (cons (- ax (* step ox)) (- ay (* step oy))))
          < #:key (lambda (pt) (dist2d (car pt) (cdr pt) cx cy))))
       exp-flank-anchors))
    (define choke-wedged
      (for*/list ([back (in-list '(-1.5 -3.0 0.0 -4.5))]
                  [lat (in-list '(0.0 3.5 -3.5 4.0 -4.0 7.0 -7.0))])
        (cons (+ cx (* back ox) (* lat px)) (+ cy (* back oy) (* lat py)))))
    (values (append anchor-wedged choke-wedged) exp-h nat-def-cnt is-3rd?))
  (define picked
    (cond
      ;; 1. Pylons: cover unpowered first, then pair single-Pylon "Artosis" risks at 4.0-5.0 tiles, else Dual-Pylon spine
      [(eq? canon 'pylon)
       (define unpowered-b
         (findf (lambda (b) (= (pylon-count-at (hash-ref b 'x 0.0) (hash-ref b 'y 0.0)) 0))
                pow-bldgs))
       (define lone-artosis-pair
         (for*/first ([b (in-list pow-bldgs)]
                      #:do [(define bxp (exact->inexact (hash-ref b 'x bx-f)))
                            (define byp (exact->inexact (hash-ref b 'y by-f)))]
                      #:when (= (pylon-count-at bxp byp) 1)
                      [p (in-list pylons)]
                      #:do [(define pxp (exact->inexact (hash-ref p 'x -9999.0)))
                            (define pyp (exact->inexact (hash-ref p 'y -9999.0)))]
                      #:when (<= (dist2d bxp byp pxp pyp) 6.2))
           (cons p b)))
       (cond
         [unpowered-b
          (define ux (exact->inexact (hash-ref unpowered-b 'x bx-f)))
          (define uy (exact->inexact (hash-ref unpowered-b 'y by-f)))
          (define cands (list (cons (+ ux 3.5) (+ uy 0.5)) (cons (- ux 3.5) (+ uy 0.5))
                              (cons (+ ux 0.5) (+ uy 3.5)) (cons (+ ux 0.5) (- uy 3.5))))
          (or (first-valid cands main-h) (first-valid spine-pylon-cands main-h))]
         [lone-artosis-pair
          (define p (car lone-artosis-pair))
          (define b (cdr lone-artosis-pair))
          (define px0 (snap-2x2-coord (hash-ref p 'x bx-f)))
          (define py0 (snap-2x2-coord (hash-ref p 'y by-f)))
          (define bxp (exact->inexact (hash-ref b 'x bx-f)))
          (define byp (exact->inexact (hash-ref b 'y by-f)))
          (define pair-offsets
            '((4.0 . 0.0) (-4.0 . 0.0) (0.0 . 4.0) (0.0 . -4.0)
              (4.0 . 2.0) (-4.0 . 2.0) (4.0 . -2.0) (-4.0 . -2.0)
              (2.0 . 4.0) (-2.0 . 4.0) (2.0 . -4.0) (-2.0 . -4.0)))
          (define dual-cands
            (sort
             (filter (lambda (pt)
                       (and (simcity-site-valid? 'pylon (car pt) (cdr pt) phys-aabbs addon-aabbs res-aabbs exp-pads
                                                 grids-ok? w h pref bref href main-h #:corridors corridors)
                            (<= (dist2d (car pt) (cdr pt) bxp byp) 6.2)))
                     (map (lambda (d) (cons (+ px0 (car d)) (+ py0 (cdr d)))) pair-offsets))
             < #:key (lambda (pt) (dist2d (car pt) (cdr pt) bxp byp))))
          (or (and (not (null? dual-cands)) (car dual-cands))
              (first-valid (map (lambda (d) (cons (+ px0 (car d)) (+ py0 (cdr d)))) pair-offsets) main-h)
              (first-valid spine-pylon-cands main-h))]
         [else
          (or (first-valid spine-pylon-cands main-h)
              (first-valid spine-pylon-cands #f #f))])]
      ;; 2. Hidden / High-Value Tech (`DarkShrine`, `TemplarArchive`, `Stargate`, `FleetBeacon`, `RoboticsBay`):
      ;;    Hide in the rear mineral-line shadow away from cliff edges.
      [(memq canon '(dark-shrine templar-archive stargate fleet-beacon robotics-bay robotics-support-bay))
       (define rear-ux (- away-ux))
       (define rear-uy (- away-uy))
       (define raw-shadow
         (for*/list ([depth (in-list '(7.5 9.5 11.5 6.0))]
                     [lat (in-list '(0.0 3.5 -3.5 6.0 -6.0 8.5 -8.5))])
           (cons (+ bx-f (* depth rear-ux) (* lat perp-ux))
                 (+ by-f (* depth rear-uy) (* lat perp-uy)))))
       (define scored-shadow
         (sort
          (filter-map
           (lambda (pt)
             (define sx (snap-fn (car pt)))
             (define sy (snap-fn (cdr pt)))
             (and (simcity-site-valid? canon sx sy phys-aabbs addon-aabbs res-aabbs exp-pads
                                       grids-ok? w h pref bref href main-h
                                       #:corridors corridors)
                  (let* ([p-cnt (pylon-count-at sx sy)]
                         [cdist (simcity-cliff-edge-dist sx sy main-h grids-ok? w h pref href)]
                         [shadow-dot (+ (* (- sx bx-f) rear-ux) (* (- sy by-f) rear-uy))]
                         [sc (+ (if (> p-cnt 0) 40.0 0.0)
                                (* 6.0 (min 5.0 cdist))
                                (* 3.0 shadow-dot)
                                (if (< cdist 2.5) -30.0 0.0)
                                (* -1.5 (dist2d sx sy min-cx min-cy)))])
                    (list sc sx sy))))
           raw-shadow)
          > #:key first))
       (and (not (null? scored-shadow))
            (cons (second (car scored-shadow)) (third (car scored-shadow))))]
      ;; 3. ShieldBattery & PhotonCannon: Natural/3rd flank wedge narrowing runby paths to 1 tile
      ;; 3. ShieldBattery & PhotonCannon: keep 1 Battery + 1 Cannon at Natural/3rd choke first,
      ;;    then cover all active Nexus mineral lines (<= 9.0 tiles, Pylon-powered), then critical infrastructure (<= 9.5 tiles)
      [(memq canon '(shield-battery photon-cannon))
       (define existing-defs (filter-ally-structures-by-syms ally-bldgs (list canon)))
       (define def-pts (simcity-point-list existing-defs bx-f by-f))
       (define-values (choke-cands exp-h _nat-def-cnt _is-3rd?) (resolve-protoss-choke-context canon))
       (define (only-powered cands)
         (filter (lambda (pt) (>= (pylon-count-at (snap-fn (car pt)) (snap-fn (cdr pt))) 1)) cands))
       (define choke-anchor (if (pair? choke-cands) (car choke-cands) (cons nx-f ny-f)))
       (define choke-needs-this?
         (not (simcity-locus-covered? (car choke-anchor) (cdr choke-anchor) def-pts 12.0)))
       (define powered-choke-cands (only-powered choke-cands))
       (define base-loci
         (simcity-active-base-mineral-loci ally-bldgs '(nexus)
                                           min-pts geyser-pts bx-f by-f nx-f ny-f grids-ok? w h href main-h))
       (define anchors
         (simcity-critical-infra-anchors ally-bldgs '(stargate fleet-beacon robotics-facility twilight-council forge cybernetics-core gateway)
                                         grids-ok? w h href main-h))
       (define (pick-mineral-line require-power?)
         (for/or ([locus (in-list base-loci)])
           (define mcx0 (list-ref locus 0))
           (define mcy0 (list-ref locus 1))
           (define aux0 (list-ref locus 2))
           (define auy0 (list-ref locus 3))
           (define th-h (list-ref locus 4))
           (define tx0 (list-ref locus 5))
           (define ty0 (list-ref locus 6))
           (and (not (simcity-locus-covered? mcx0 mcy0 def-pts 9.0))
                (let* ([raw-cands (simcity-mineral-line-def-cands mcx0 mcy0 aux0 auy0 tx0 ty0)]
                       [cands (if require-power? (only-powered raw-cands) raw-cands)])
                  (or (first-valid cands th-h)
                      (first-valid cands #f #f))))))
       (define (pick-infra require-power?)
         (for/or ([anc (in-list anchors)])
           (define ax0 (car anc))
           (define ay0 (cadr anc))
           (define ah0 (caddr anc))
           (and (not (simcity-locus-covered? ax0 ay0 def-pts 9.5))
                (let* ([raw-cands (simcity-anchor-def-cands ax0 ay0)]
                       [cands (if require-power? (only-powered raw-cands) raw-cands)])
                  (or (first-valid cands ah0)
                      (first-valid cands #f #f))))))
       (define completed-pylons
         (filter (lambda (p)
                   (define bp (hash-ref p 'build-progress #f))
                   (or (not (real? bp)) (>= bp 0.999)))
                 pylons))
       (define (only-ready-powered cands)
         (define eff-pylons (if (pair? completed-pylons) completed-pylons pylons))
         (filter (lambda (pt)
                   (define sx (snap-fn (car pt)))
                   (define sy (snap-fn (cdr pt)))
                   (for/or ([p (in-list eff-pylons)])
                     (<= (dist2d sx sy (hash-ref p 'x -9999.0) (hash-ref p 'y -9999.0)) 6.2)))
                 cands))
       (define pylon-ring-cands
         (if (null? pylons)
             '()
             (sort
              (for*/list ([p (in-list (if (pair? completed-pylons) completed-pylons pylons))]
                          #:do [(define px0 (exact->inexact (hash-ref p 'x bx-f)))
                                (define py0 (exact->inexact (hash-ref p 'y by-f)))]
                          [r (in-list '(3.5 5.0))]
                          [k (in-range 8)])
                (define ang (* k (/ (* 2.0 pi) 8.0)))
                (cons (+ px0 (* r (cos ang))) (+ py0 (* r (sin ang)))))
              < #:key (lambda (pt) (dist2d (car pt) (cdr pt) (car choke-anchor) (cdr choke-anchor))))))
       (or (and choke-needs-this? (first-valid (only-ready-powered choke-cands) exp-h))
           (and choke-needs-this? (first-valid powered-choke-cands exp-h))
           (pick-mineral-line #t)
           (pick-infra #t)
           (first-valid (only-ready-powered choke-cands) exp-h)
           (first-valid powered-choke-cands exp-h)
           (and (eq? canon 'photon-cannon) (pair? pylon-ring-cands)
                (or (first-valid (only-ready-powered pylon-ring-cands) exp-h)
                    (first-valid (only-ready-powered pylon-ring-cands) main-h)
                    (first-valid (only-ready-powered pylon-ring-cands) #f grids-ok?)))
           (and choke-needs-this? (or (first-valid choke-cands exp-h) (first-valid choke-cands #f #f)))
           (pick-mineral-line #f)
           (pick-infra #f)
           (first-valid choke-cands exp-h)
           (first-valid choke-cands #f #f))]
      ;; 4. Gateway, CyberneticsCore, Forge, RoboticsFacility, TwilightCouncil:
      ;;    Dual-Pylon Matrix (`>= 2` pylons, `2.0`-tile lanes) + Natural/3rd flank wedge narrowing runbys to 1 tile
      [(memq canon '(gateway warp-gate cybernetics-core forge robotics-facility twilight-council))
       (define-values (flank-cands exp-h nat-def-cnt is-3rd?) (resolve-protoss-choke-context canon))
       (define dual-powered-slots
         (filter (lambda (pt) (>= (pylon-count-at (snap-fn (car pt)) (snap-fn (cdr pt))) 2)) matrix-3x3-slots))
       (define single-powered-slots
         (filter (lambda (pt) (>= (pylon-count-at (snap-fn (car pt)) (snap-fn (cdr pt))) 1)) matrix-3x3-slots))
       (define main-prod-cnt
         (count (lambda (b) (<= (dist2d bx-f by-f (hash-ref b 'x 9999.0) (hash-ref b 'y 9999.0)) 20.0))
                (filter-ally-structures-by-syms ally-bldgs '(gateway warp-gate cybernetics-core robotics-facility twilight-council))))
       (define want-flank? (or (eq? canon 'forge) (and (>= main-prod-cnt 2) (< nat-def-cnt 2)) is-3rd?))
       (define flank-powered (filter (lambda (pt) (>= (pylon-count-at (snap-fn (car pt)) (snap-fn (cdr pt))) 1)) flank-cands))
       (or (and want-flank? (first-valid flank-powered exp-h))
           (and want-flank? (first-valid flank-cands exp-h))
           (first-valid dual-powered-slots main-h)
           (first-valid single-powered-slots main-h)
           (first-valid matrix-3x3-slots main-h)
           (first-valid flank-cands exp-h)
           (first-valid matrix-3x3-slots #f grids-ok?))]
      [else
       (or (first-valid matrix-3x3-slots main-h)
           (first-valid matrix-3x3-slots #f grids-ok?))]))
  (if picked
      (values (car picked) (cdr picked))
      (simcity-buildable-spiral-fallback
       canon
       (list (cons (+ bx-f (* 8.0 away-ux)) (+ by-f (* 8.0 away-uy)))
             (cons bx-f by-f)
             (cons nx-f ny-f))
       phys-aabbs addon-aabbs res-aabbs exp-pads
       grids-ok? w h pref bref href
       #:fallback-pt (cons (+ bx-f (* 8.0 away-ux)) (+ by-f (* 8.0 away-uy))))))

;; Zerg Pro SimCity (Mineral-Pocket tech tuck, Natural/Third choke Evo/Roach semi-wall, Spine behind semi-wall).
(define (solve-zerg-pro-simcity canon bx-f by-f nx-f ny-f ex-f ey-f
                                ally-bldgs phys-aabbs addon-aabbs res-aabbs exp-pads
                                min-pts geyser-pts grids-ok? w h pref bref href main-h nat-h corridors)
  (define-values (_has-mins? min-cx min-cy away-ux away-uy _local-mins local-geysers)
    (compute-base-mineral-geometry bx-f by-f min-pts geyser-pts
                                   (/ (- nx-f bx-f) (max 1.0 (dist2d bx-f by-f nx-f ny-f)))
                                   (/ (- ny-f by-f) (max 1.0 (dist2d bx-f by-f nx-f ny-f)))))
  (define rear-ux (- away-ux))
  (define rear-uy (- away-uy))
  (define snap-fn (if (sc2-odd-footprint-structure? canon) snap-3x3-coord snap-2x2-coord))
  (define (first-valid cands [tgt-h main-h] [req-terr? #t])
    (for/first ([pt (in-list cands)]
                #:do [(define sx (snap-fn (car pt)))
                      (define sy (snap-fn (cdr pt)))]
                #:when (simcity-site-valid? canon sx sy phys-aabbs addon-aabbs res-aabbs exp-pads
                                            grids-ok? w h pref bref href tgt-h
                                            #:corridors corridors
                                            #:corridor-min-dist 2.1
                                            #:require-terrain? req-terr?))
      (cons sx sy)))
  ;; Resolve Natural/3rd choke frame strictly in the choke/spine branches that actually use it.
  (define (resolve-zerg-choke)
    (define choke-wall-cnt
      (count (lambda (b) (<= (dist2d nx-f ny-f (hash-ref b 'x bx-f) (hash-ref b 'y by-f)) 15.5))
             (filter-ally-structures-by-syms ally-bldgs '(evolution-chamber roach-warren))))
    (define-values (tx-f ty-f is-3rd?)
      (select-simcity-expansion-locus bx-f by-f nx-f ny-f ally-bldgs exp-pads choke-wall-cnt '(hatchery lair hive)))
    (define-values (cx cy px py ox oy exp-h)
      (resolve-choke-frame bx-f by-f tx-f ty-f ex-f ey-f is-3rd? grids-ok? w h pref bref href main-h nat-h))
    (values tx-f ty-f cx cy px py ox oy exp-h))
  (define picked
    (cond
      ;; 1. Mineral-Pocket Tech Tuck (Pool, BanelingNest, HydraDen, LurkerDen, Spire, InfestationPit, UltraCavern)
      [(memq canon '(spawning-pool baneling-nest hydralisk-den lurker-den spire greater-spire infestation-pit ultralisk-cavern))
       (define pocket-pts (append (list (cons bx-f by-f) (cons min-cx min-cy)) local-geysers))
       (define pocket-x (/ (for/sum ([p (in-list pocket-pts)]) (car p)) (length pocket-pts)))
       (define pocket-y (/ (for/sum ([p (in-list pocket-pts)]) (cdr p)) (length pocket-pts)))
       ;; Score and sort purely by lightweight geometry first; validate grid/AABB clearance lazily.
       (define pocket-cands
         (sort
          (for*/list ([dx (in-range -11.0 12.0 1.0)]
                      [dy (in-range -11.0 12.0 1.0)]
                      #:do [(define sx (snap-fn (+ bx-f dx)))
                            (define sy (snap-fn (+ by-f dy)))
                            (define dh (dist2d sx sy bx-f by-f))
                            (define dot-rear (+ (* (- sx bx-f) rear-ux) (* (- sy by-f) rear-uy)))]
                      #:when (and (>= dh 4.5) (<= dh 11.5)
                                  (>= dot-rear -1.5)
                                  (placement-in-playable-bounds? sx sy)))
            (define d-min-ctr (dist2d sx sy min-cx min-cy))
            (define d-geyser
              (if (null? local-geysers)
                  (dist2d sx sy pocket-x pocket-y)
                  (for/fold ([mg +inf.0]) ([g (in-list local-geysers)])
                    (min mg (dist2d sx sy (car g) (cdr g))))))
            (define d-nat (dist2d sx sy nx-f ny-f))
            (define sc
              (+ (* -2.0 dh)
                 (* -1.6 (dist2d sx sy pocket-x pocket-y))
                 (* -0.8 d-min-ctr)
                 (* -0.8 d-geyser)
                 (* 0.35 d-nat)))
            (list sc sx sy))
          > #:key first))
       (for/first ([cand (in-list pocket-cands)]
                   #:do [(define sx (second cand))
                         (define sy (third cand))]
                   #:when (simcity-site-valid? canon sx sy phys-aabbs addon-aabbs res-aabbs exp-pads
                                               grids-ok? w h pref bref href main-h
                                               #:corridors corridors
                                               #:corridor-min-dist 2.1))
         (cons sx sy))]
      ;; 2. EvolutionChamber & RoachWarren: Natural / 3rd Choke Anti-Runby Semi-Wall
      [(memq canon '(evolution-chamber roach-warren))
       (define-values (_tx _ty cx cy px py ox oy exp-h) (resolve-zerg-choke))
       (define semi-wall-cands
         (for*/list ([lat (in-list '(0.0 4.0 -4.0 3.0 -3.0 8.0 -8.0 5.0 -5.0))]
                     [back (in-list '(0.0 -1.5 -3.0 1.5))])
           (cons (+ cx (* lat px) (* back ox))
                 (+ cy (* lat py) (* back oy)))))
       (or (first-valid semi-wall-cands exp-h)
           (first-valid semi-wall-cands #f #f))]
      ;; 3. SpineCrawler: defensive slots strictly behind the Natural / 3rd Choke Semi-Wall
      [(eq? canon 'spine-crawler)
       (define existing-spines (filter-ally-structures-by-syms ally-bldgs '(spine-crawler)))
       (define spine-pts (simcity-point-list existing-spines bx-f by-f))
       (define-values (tx-f ty-f cx cy px py ox oy exp-h) (resolve-zerg-choke))
       (define wall-bldgs
         (filter (lambda (b) (<= (dist2d tx-f ty-f (hash-ref b 'x bx-f) (hash-ref b 'y by-f)) 15.5))
                 (filter-ally-structures-by-syms ally-bldgs '(evolution-chamber roach-warren))))
       (define behind-wall-cands
         (append-map
          (lambda (wb)
            (define wx (exact->inexact (hash-ref wb 'x cx)))
            (define wy (exact->inexact (hash-ref wb 'y cy)))
            (for*/list ([back (in-list '(-3.0 -4.0 -2.5))]
                        [lat (in-list '(0.0 2.0 -2.0))])
              (cons (+ wx (* back ox) (* lat px))
                    (+ wy (* back oy) (* lat py)))))
          wall-bldgs))
       (define fallback-choke-behind
         (for*/list ([back (in-list '(-3.5 -4.5 -2.5))]
                     [lat (in-list '(0.0 2.5 -2.5 5.0 -5.0))])
           (cons (+ cx (* back ox) (* lat px))
                 (+ cy (* back oy) (* lat py)))))
       (define choke-spines
         (count (lambda (dp) (<= (dist2d cx cy (car dp) (cdr dp)) 11.5)) spine-pts))
       (define (pick-choke-spine)
         (or (first-valid behind-wall-cands exp-h)
             (first-valid fallback-choke-behind exp-h)
             (first-valid fallback-choke-behind #f #f)))
       (define (pick-mineral-spine)
         (define base-loci
           (simcity-active-base-mineral-loci ally-bldgs '(hatchery lair hive)
                                             min-pts geyser-pts bx-f by-f nx-f ny-f grids-ok? w h href main-h))
         (for/or ([locus (in-list base-loci)])
           (define mcx0 (list-ref locus 0))
           (define mcy0 (list-ref locus 1))
           (define aux0 (list-ref locus 2))
           (define auy0 (list-ref locus 3))
           (define th-h (list-ref locus 4))
           (define tx0 (list-ref locus 5))
           (define ty0 (list-ref locus 6))
           (and (not (simcity-locus-covered? mcx0 mcy0 spine-pts 9.0))
                (let ([mc (simcity-mineral-line-def-cands mcx0 mcy0 aux0 auy0 tx0 ty0)])
                  (or (first-valid mc th-h)
                      (first-valid mc #f #f))))))
       (define (pick-infra-spine)
         (define anchors
           (simcity-critical-infra-anchors ally-bldgs '(spire greater-spire hive lair hydralisk-den roach-warren infestation-pit spawning-pool evolution-chamber)
                                           grids-ok? w h href main-h))
         (for/or ([anc (in-list anchors)])
           (define ax0 (car anc))
           (define ay0 (cadr anc))
           (define ah0 (caddr anc))
           (and (not (simcity-locus-covered? ax0 ay0 spine-pts 9.5))
                (let ([ac (simcity-anchor-def-cands ax0 ay0)])
                  (or (first-valid ac ah0)
                      (first-valid ac #f #f))))))
       (if (and (< choke-spines 2) (< (length existing-spines) 2))
           (or (pick-choke-spine) (pick-mineral-spine) (pick-infra-spine))
           (or (pick-mineral-spine) (pick-infra-spine) (pick-choke-spine)))]
      ;; 4. SporeCrawler covering all active Hatchery/Lair/Hive mineral lines (<= 9.0 tiles),
      ;;    then critical tech/production anchors (<= 9.5 tiles)
      [(eq? canon 'spore-crawler)
       (define existing-spores (filter-ally-structures-by-syms ally-bldgs '(spore-crawler)))
       (define spore-pts (simcity-point-list existing-spores bx-f by-f))
       (define base-loci
         (simcity-active-base-mineral-loci ally-bldgs '(hatchery lair hive)
                                           min-pts geyser-pts bx-f by-f nx-f ny-f grids-ok? w h href main-h))
       (define anchors
         (simcity-critical-infra-anchors ally-bldgs '(spire greater-spire hive lair hydralisk-den roach-warren infestation-pit spawning-pool evolution-chamber)
                                         grids-ok? w h href main-h))
       (or (for/or ([locus (in-list base-loci)])
             (define mcx0 (list-ref locus 0))
             (define mcy0 (list-ref locus 1))
             (define aux0 (list-ref locus 2))
             (define auy0 (list-ref locus 3))
             (define th-h (list-ref locus 4))
             (define tx0 (list-ref locus 5))
             (define ty0 (list-ref locus 6))
             (and (not (simcity-locus-covered? mcx0 mcy0 spore-pts 9.0))
                  (let ([mc (simcity-mineral-line-def-cands mcx0 mcy0 aux0 auy0 tx0 ty0)])
                    (or (first-valid mc th-h)
                        (first-valid mc #f #f)))))
           (for/or ([anc (in-list anchors)])
             (define ax0 (car anc))
             (define ay0 (cadr anc))
             (define ah0 (caddr anc))
             (and (not (simcity-locus-covered? ax0 ay0 spore-pts 9.5))
                  (let ([ac (simcity-anchor-def-cands ax0 ay0)])
                    (or (first-valid ac ah0)
                        (first-valid ac #f #f)))))
           (let ([fb (simcity-mineral-line-def-cands min-cx min-cy away-ux away-uy bx-f by-f)])
             (or (first-valid fb main-h)
                 (first-valid fb #f #f))))]
      [else
       (define cands
         (for*/list ([k (in-range 12)]
                     [r (in-list '(7.0 9.5))])
           (define ang (* k (/ (* 2.0 pi) 12.0)))
           (cons (+ bx-f (* r (cos ang))) (+ by-f (* r (sin ang))))))
       (first-valid cands main-h)]))
  (if picked
      (values (car picked) (cdr picked))
      (spiral-search-free-point canon (+ bx-f (* 6.0 rear-ux)) (+ by-f (* 6.0 rear-uy))
                                phys-aabbs addon-aabbs exp-pads #f)))

;; Computes pro-level SimCity `(values px py)` for Terran (`2x5` matrix + outer cliff perimeter depots),
;; Protoss (`Dual-Pylon` power matrix + `1`-tile Natural/Third flank wedges + rear mineral-shadow hidden tech),
;; and Zerg (mineral-pocket tech tuck + Natural/Third choke semi-wall + behind-wall SpineCrawler slots).
(define (solve-pro-simcity-layout-placement bldg-sym race base-x base-y nat-x nat-y
                                            #:enemy-x [enemy-x SC2-DEFAULT-ENEMY-BASE-X]
                                            #:enemy-y [enemy-y SC2-DEFAULT-ENEMY-BASE-Y]
                                            #:ally-bldgs [ally-bldgs '()]
                                            #:mineral-patches [mineral-patches '()]
                                            #:geysers [geysers '()]
                                            #:reserved-sites [reserved-sites '()]
                                            #:reserved-aabbs [reserved-aabbs '()]
                                            #:expansion-pads [expansion-pads '()]
                                            #:map-grids [map-grids #f]
                                            #:frame [frame 0])
  (define canon (if (symbol? bldg-sym) (sc2-canonical-structure-sym bldg-sym) bldg-sym))
  (define r-norm (normalize-simcity-race race canon))
  (define bx-f (exact->inexact base-x))
  (define by-f (exact->inexact base-y))
  (define nx-f (exact->inexact nat-x))
  (define ny-f (exact->inexact nat-y))
  (define ex-f (exact->inexact enemy-x))
  (define ey-f (exact->inexact enemy-y))
  (define-values (phys-aabbs addon-aabbs)
    (collect-placement-blocking-aabbs #:reserved-aabbs reserved-aabbs
                                      #:reserved-sites reserved-sites
                                      #:ally-bldgs ally-bldgs
                                      #:frame frame))
  (define-values (res-aabbs min-pts geyser-pts)
    (collect-simcity-resource-geometry mineral-patches geysers))
  (define-values (grids-ok? w h pref bref href) (extract-map-grid-accessors map-grids))
  (define main-h
    (and grids-ok?
         (simcity-grid-height-or-false
          href (max 0 (min (sub1 w) (exact-floor bx-f)))
          (max 0 (min (sub1 h) (exact-floor by-f))) #f)))
  (define nat-h
    (and grids-ok?
         (simcity-grid-height-or-false
          href (max 0 (min (sub1 w) (exact-floor nx-f)))
          (max 0 (min (sub1 h) (exact-floor ny-f))) main-h)))
  (define ths (filter-ally-structures-by-syms ally-bldgs SC2-TOWNHALL-STRUCTURE-SYMS))
  (define extra-ths (map (lambda (b) (cons (exact->inexact (hash-ref b 'x bx-f))
                                           (exact->inexact (hash-ref b 'y by-f))))
                         ths))
  (define corridors (collect-mining-corridors bx-f by-f min-pts geyser-pts extra-ths))
  (case r-norm
    [(Terran)
     (solve-terran-pro-simcity canon bx-f by-f nx-f ny-f ex-f ey-f
                               ally-bldgs phys-aabbs addon-aabbs res-aabbs expansion-pads
                               min-pts geyser-pts grids-ok? w h pref bref href main-h nat-h map-grids corridors)]
    [(Protoss)
     (solve-protoss-pro-simcity canon bx-f by-f nx-f ny-f ex-f ey-f
                                ally-bldgs phys-aabbs addon-aabbs res-aabbs expansion-pads
                                min-pts geyser-pts grids-ok? w h pref bref href main-h nat-h corridors)]
    [else
     (solve-zerg-pro-simcity canon bx-f by-f nx-f ny-f ex-f ey-f
                             ally-bldgs phys-aabbs addon-aabbs res-aabbs expansion-pads
                             min-pts geyser-pts grids-ok? w h pref bref href main-h nat-h corridors)]))

;; Selects the mineral patch record/hash closest to `(enemy-cx, enemy-cy)` within 14.0 tiles
;; of `(townhall-x, townhall-y)` for mineral-walk drill-stacking defenders onto an enemy worker stack.
(define (select-worker-drill-stack-mineral-patch enemy-cx enemy-cy townhall-x townhall-y mineral-patches)
  (define ecx (exact->inexact enemy-cx))
  (define ecy (exact->inexact enemy-cy))
  (define tx (exact->inexact townhall-x))
  (define ty (exact->inexact townhall-y))
  (define candidates
    (filter (lambda (mp)
              (define-values (ok? mx my) (simcity-record->xy mp))
              (and ok?
                   (or (not (hash? mp))
                       (> (hash-ref mp 'mineral-contents 1) 0))
                   (<= (dist2d mx my tx ty) 14.0)))
            (if (list? mineral-patches) mineral-patches '())))
  (and (not (null? candidates))
       (argmin (lambda (mp)
                 (define-values (_ok? mx my) (simcity-record->xy mp))
                 (dist2d mx my ecx ecy))
               candidates)))
