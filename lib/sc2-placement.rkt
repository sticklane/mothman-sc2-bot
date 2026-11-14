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
         "sc2-pathing.rkt"
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
 solve-protoss-matchup-wall
 solve-choke-wall-in
 wall-solution-valid-ref
 wall-solution-zergling-tight-ref
 wall-solution-max-gap-ref
 wall-solution-placements-ref

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
     (define mx (+ base-x (* 0.35 (- nat-x base-x))))
     (define my (+ base-y (* 0.35 (- nat-y base-y))))
     (list eff-w eff-h
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
        (define s3 (cons (+ door-x 5.0) door-y))
        (define px (snap-2x2-coord (+ door-x 1.5)))
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
              'slot-3 s3
              'grid-solved? #f)]
       [else
        (define sx (if (>= out-ux 0.0) 1.0 -1.0))
        (define door-x (snap-3x3-coord (+ nx-f (* 9.0 out-ux))))
        (define door-y (snap-3x3-coord (+ ny-f (* 9.0 out-uy))))
        (define s1 (cons door-x (- door-y 2.0)))
        (define s2 (cons door-x (+ door-y 2.0)))
        (define s3 (cons door-x (if (>= out-uy 0.0) (+ door-y 5.0) (- door-y 5.0))))
        (define px (snap-2x2-coord (- door-x (* 3.5 sx))))
        (define py (snap-2x2-coord (+ door-y (if (>= out-uy 0.0) 1.5 -1.5))))
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
              'slot-3 s3
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
               (define vth (grid-height-val href vgx vgy h-nat))
               (define genuine-ramp-slope?
                 (and (procedure? href)
                      (or (> (abs (- vth h-nat)) 1.75)
                          (for*/or ([rdy-i (in-range -2 3)]
                                    [rdx-i (in-range -2 3)]
                                    #:do [(define rgx (+ vgx rdx-i))
                                          (define rgy (+ vgy rdy-i))]
                                    #:when (and (>= rgx 0) (< rgx w) (>= rgy 0) (< rgy h)
                                                (grid-cell-positive? (pref rgx rgy))))
                            (> (abs (- (grid-height-val href rgx rgy h-nat) h-nat)) 2.5)))))
               (define flat-unbuildable-plug?
                 (and (>= du 5)
                      (not (grid-cell-positive? (bref vgx vgy)))
                      (not genuine-ramp-slope?)))
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
                 (when (>= buildable-cnt 12)
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
         [(or (null? rem) (>= (length acc) 3)) (reverse acc)]
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
       (for*/list ([dy-i (in-range -6 7)]
                   [dx-i (in-range -6 7)]
                   #:do [(define sx (+ (floor center-x) dx-i 0.5))
                         (define sy (+ (floor center-y) dy-i 0.5))]
                   #:when (and (<= (dist2d sx sy center-x center-y) 6.2)
                               (outside-nexus-pads? sx sy 1.5 1.5)
                               (strict-slot-buildable? sx sy 1.5 1.5)))
         (cons sx sy)))
     (define door-cands
       (for*/list ([dy-i (in-range -4 5)]
                   [dx-i (in-range -4 5)]
                   #:do [(define ix (+ (exact-floor center-x) dx-i))
                         (define iy (+ (exact-floor center-y) dy-i))
                         (define dx0 (+ ix 0.5))
                         (define dy0 (+ iy 0.5))]
                   #:when (and (>= ix 0) (< ix w) (>= iy 0) (< iy h)
                               (<= (dist2d dx0 dy0 center-x center-y) 4.5)
                               (outside-nexus-pads? dx0 dy0 0.5 0.5)
                               (not (set-member? forbid-tiles-set (cons ix iy)))
                               (grid-cell-positive? (pref ix iy))))
         (list dx0 dy0 (- ix win-x0) (- iy win-y0))))

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
         (when (and (>= rear-proj 1.5)
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
           (define ideal-band? (and (>= rear-dist 3.2) (<= rear-dist 5.0)))
           (define psc
             (+ (if ideal-band? 200.0 0.0)
                (* 10.0 rear-proj)
                (- (* 4.0 (abs (- rear-dist 4.0))))))
           (when (> psc best-psc)
             (set! best-psc psc)
             (set! best-p (cons px py)))))
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

     ;; 1. Try 2x 3x3 slots + 1x1 doorway
     (define best-wall #f)
     (define best-wsc -1e9)
     (for ([dc (in-list door-cands)])
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
           (define w-rects
             (list (list (car s1) (cdr s1) 1.5 1.5)
                   (list (car s2) (cdr s2) 1.5 1.5)))
           (when (and (seals-cleanly? (cons (list door-x door-y 0.5 0.5) w-rects))
                      (bfs-reach? w-rects (car src-pt) (cdr src-pt) dlx dly)
                      (bfs-reach? w-rects dlx dly (car dst-pt) (cdr dst-pt)))
             (define pyl (find-rear-pylon (list s1 s2) door-x door-y dlx dly w-rects))
             (when pyl
               (define sandwich-bonus (if (and s1-edge-door? s2-edge-door?) 120.0 0.0))
               (define sc
                 (+ 500.0
                    sandwich-bonus
                    (- (* 8.0 (+ (dist2d (car s1) (cdr s1) center-x center-y)
                                 (dist2d (car s2) (cdr s2) center-x center-y)
                                 (dist2d door-x door-y center-x center-y))))))
               (when (> sc best-wsc)
                 (set! best-wsc sc)
                 (set! best-wall (list s1 s2 #f door-x door-y pyl w-rects))))))))

     ;; 2. If 2x 3x3 did not seal (wide natural choke), try 3x 3x3 slots + 1x1 doorway
     (when (not best-wall)
       (for ([dc (in-list door-cands)])
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
           (define w-rects
             (list (list (car s1) (cdr s1) 1.5 1.5)
                   (list (car s2) (cdr s2) 1.5 1.5)
                   (list (car s3) (cdr s3) 1.5 1.5)))
           (when (and (seals-cleanly? (cons (list door-x door-y 0.5 0.5) w-rects))
                      (bfs-reach? w-rects (car src-pt) (cdr src-pt) dlx dly)
                      (bfs-reach? w-rects dlx dly (car dst-pt) (cdr dst-pt)))
             (define pyl (find-rear-pylon (list s1 s2 s3) door-x door-y dlx dly w-rects))
             (when pyl
               (define sc
                 (- 350.0
                    (* 6.0 (+ (dist2d (car s1) (cdr s1) center-x center-y)
                              (dist2d (car s2) (cdr s2) center-x center-y)
                              (dist2d (car s3) (cdr s3) center-x center-y)))))
               (when (> sc best-wsc)
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

;; Selects and caches a matchup-specific Protoss wall (natural choke vs Zerg, main ramp otherwise).
(define (solve-protoss-matchup-wall base-x base-y nat-x nat-y enemy-race
                                    #:map-grids [map-grids #f]
                                    #:enemy-x [enemy-x 160.5]
                                    #:enemy-y [enemy-y 160.5])
  (define vs-zerg?
    (or (memq enemy-race '(Zerg zerg ZERG))
        (and (string? enemy-race) (string-ci=? enemy-race "zerg"))))
  (define locus (if vs-zerg? 'natural-choke 'main-ramp))
  (define cache-key
    (list 'protoss
          (round base-x) (round base-y)
          (round nat-x) (round nat-y)
          locus
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

;; Resolves a collision-free build coordinate `(values x y)` via lattice snapping and 3-tile spiral search.
(define (solve-spiral-placement bldg-sym raw-x raw-y
                                #:ally-bldgs [ally-bldgs '()]
                                #:reserved-sites [reserved-sites '()]
                                #:reserved-aabbs [reserved-aabbs '()]
                                #:expansion-pads [expansion-pads '()]
                                #:frame [frame 0]
                                #:exact-wall-slot? [exact-wall-slot? #f])
  (define canon (if (symbol? bldg-sym) (sc2-canonical-structure-sym bldg-sym) bldg-sym))
  (define-values (cand-hw cand-hh) (if (symbol? canon) (sc2-structure-half-dims canon) (values 1.5 1.5)))
  (define is-townhall?
    (or (memq bldg-sym SC2-TOWNHALL-STRUCTURE-SYMS)
        (memq canon SC2-TOWNHALL-STRUCTURE-SYMS)))
  (define snap-fn (if (sc2-odd-footprint-structure? canon) snap-3x3-coord snap-2x2-coord))
  (define-values (physical-aabbs addon-pad-aabbs)
    (collect-placement-blocking-aabbs #:reserved-aabbs reserved-aabbs
                                      #:reserved-sites reserved-sites
                                      #:ally-bldgs ally-bldgs
                                      #:frame frame))
  (cond
    [(and exact-wall-slot?
          (placement-in-playable-bounds? raw-x raw-y)
          (not (placement-point-overlaps-expansion-pad? (exact->inexact raw-x) (exact->inexact raw-y) expansion-pads is-townhall?))
          (not (ormap (lambda (b) (aabb-overlaps? raw-x raw-y cand-hw cand-hh b)) physical-aabbs)))
     (values raw-x raw-y)]
    [else
     (define x0 (snap-fn raw-x))
     (define y0 (snap-fn raw-y))
     (if (placement-site-free? canon x0 y0 physical-aabbs addon-pad-aabbs expansion-pads exact-wall-slot?)
         (values x0 y0)
         (let search ([r 3.0])
           (if (> r 18.0)
               (values x0 y0)
               (let ([found
                      (for*/first ([dx (in-list (list 0.0 r (- r)))]
                                   [dy (in-list (list 0.0 r (- r)))]
                                   #:when (and (or (not (zero? dx)) (not (zero? dy)))
                                               (placement-site-free? canon
                                                                     (snap-fn (+ x0 dx))
                                                                     (snap-fn (+ y0 dy))
                                                                     physical-aabbs
                                                                     addon-pad-aabbs
                                                                     expansion-pads
                                                                     exact-wall-slot?)))
                        (cons (snap-fn (+ x0 dx)) (snap-fn (+ y0 dy))))])
                 (if found
                     (values (car found) (cdr found))
                     (search (+ r 3.0)))))))]))

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
