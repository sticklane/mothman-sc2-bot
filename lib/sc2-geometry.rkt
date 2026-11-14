#lang typed/racket/base

(require racket/math
         "sc2-types.rkt")

(provide
 (struct-out point2d)
 (struct-out aabb2d)
 dist-sq-2d
 dist-2d
 chebyshev-dist-2d
 manhattan-dist-2d
 point-lerp-2d
 step-toward-2d
 step-away-2d
 clamp-point-to-map
 quantize-cell-2.5
 offset-defense-anchor
 aabb2d-overlaps?
 aabb-overlaps?
 building-footprint-half-extent
 footprint-overlaps?
 point-in-circle?
 centroid-2d
 snap-3x3-coord
 snap-2x2-coord
 footprints-disjoint?
 footprints-touch-gap
 footprints-share-edge?
 point-to-segment-dist)

;; =============================================================================
;; Layer 1: Pure Typed 2D Geometry Primitives & Footprint Helpers
;; =============================================================================

(: dist-sq-xy (-> Real Real Real Real Nonnegative-Float))
(define (dist-sq-xy x1 y1 x2 y2)
  (define dx : Float (- (->float x2) (->float x1)))
  (define dy : Float (- (->float y2) (->float y1)))
  (define s : Float (+ (* dx dx) (* dy dy)))
  (if (> s 0.0) s 0.0))

(: dist-sq-2d (case-> (-> point2d point2d Float)
                      (-> Real Real Real Real Float)))
(define dist-sq-2d
  (case-lambda
    [([p1 : point2d] [p2 : point2d])
     (dist-sq-xy (point2d-x p1) (point2d-y p1) (point2d-x p2) (point2d-y p2))]
    [([x1 : Real] [y1 : Real] [x2 : Real] [y2 : Real])
     (dist-sq-xy x1 y1 x2 y2)]))

(: dist-2d (case-> (-> point2d point2d Float)
                   (-> Real Real Real Real Float)))
(define dist-2d
  (case-lambda
    [([p1 : point2d] [p2 : point2d])
     (->float (sqrt (dist-sq-xy (point2d-x p1) (point2d-y p1) (point2d-x p2) (point2d-y p2))))]
    [([x1 : Real] [y1 : Real] [x2 : Real] [y2 : Real])
     (->float (sqrt (dist-sq-xy x1 y1 x2 y2)))]))

(: chebyshev-dist-2d (case-> (-> point2d point2d Float)
                             (-> Real Real Real Real Float)))
(define chebyshev-dist-2d
  (case-lambda
    [([p1 : point2d] [p2 : point2d])
     (max (abs (- (point2d-x p2) (point2d-x p1)))
          (abs (- (point2d-y p2) (point2d-y p1))))]
    [([x1 : Real] [y1 : Real] [x2 : Real] [y2 : Real])
     (max (abs (- (->float x2) (->float x1)))
          (abs (- (->float y2) (->float y1))))]))

(: manhattan-dist-2d (case-> (-> point2d point2d Float)
                             (-> Real Real Real Real Float)))
(define manhattan-dist-2d
  (case-lambda
    [([p1 : point2d] [p2 : point2d])
     (+ (abs (- (point2d-x p2) (point2d-x p1)))
        (abs (- (point2d-y p2) (point2d-y p1))))]
    [([x1 : Real] [y1 : Real] [x2 : Real] [y2 : Real])
     (+ (abs (- (->float x2) (->float x1)))
        (abs (- (->float y2) (->float y1))))]))

(: point-lerp-2d (case-> (-> point2d point2d Real point2d)
                         (-> Real Real Real Real Real point2d)))
(define point-lerp-2d
  (case-lambda
    [([p1 : point2d] [p2 : point2d] [t : Real])
     (define ft : Float (->float t))
     (point2d (+ (point2d-x p1) (* ft (- (point2d-x p2) (point2d-x p1))))
              (+ (point2d-y p1) (* ft (- (point2d-y p2) (point2d-y p1)))))]
    [([x1 : Real] [y1 : Real] [x2 : Real] [y2 : Real] [t : Real])
     (define fx1 : Float (->float x1))
     (define fy1 : Float (->float y1))
     (define ft : Float (->float t))
     (point2d (+ fx1 (* ft (- (->float x2) fx1)))
              (+ fy1 (* ft (- (->float y2) fy1))))]))

(: step-toward-xy (-> Real Real Real Real Real point2d))
(define (step-toward-xy x1 y1 x2 y2 step-dist)
  (define fx1 : Float (->float x1))
  (define fy1 : Float (->float y1))
  (define fx2 : Float (->float x2))
  (define fy2 : Float (->float y2))
  (define fs : Float (->float step-dist))
  (define dx : Float (- fx2 fx1))
  (define dy : Float (- fy2 fy1))
  (define d : Float (->float (sqrt (max 0.0 (+ (* dx dx) (* dy dy))))))
  (cond
    [(<= d 1e-6) (point2d fx2 fy2)]
    [(and (>= fs 0.0) (<= d fs)) (point2d fx2 fy2)]
    [else
     (point2d (+ fx1 (* fs (/ dx d)))
              (+ fy1 (* fs (/ dy d))))]))

(: step-toward-2d (case-> (-> point2d point2d Real point2d)
                          (-> Real Real Real Real Real point2d)))
(define step-toward-2d
  (case-lambda
    [([p1 : point2d] [p2 : point2d] [step-dist : Real])
     (step-toward-xy (point2d-x p1) (point2d-y p1) (point2d-x p2) (point2d-y p2) step-dist)]
    [([x1 : Real] [y1 : Real] [x2 : Real] [y2 : Real] [step-dist : Real])
     (step-toward-xy x1 y1 x2 y2 step-dist)]))

(: step-away-xy (-> Real Real Real Real Real point2d))
(define (step-away-xy x1 y1 x2 y2 step-dist)
  (define fx1 : Float (->float x1))
  (define fy1 : Float (->float y1))
  (define fs : Float (->float step-dist))
  (define dx : Float (- fx1 (->float x2)))
  (define dy : Float (- fy1 (->float y2)))
  (define d : Float (->float (sqrt (max 0.0 (+ (* dx dx) (* dy dy))))))
  (if (<= d 1e-6)
      (point2d (+ fx1 fs) fy1)
      (point2d (+ fx1 (* fs (/ dx d)))
               (+ fy1 (* fs (/ dy d))))))

(: step-away-2d (case-> (-> point2d point2d Real point2d)
                        (-> Real Real Real Real Real point2d)))
(define step-away-2d
  (case-lambda
    [([p1 : point2d] [p2 : point2d] [step-dist : Real])
     (step-away-xy (point2d-x p1) (point2d-y p1) (point2d-x p2) (point2d-y p2) step-dist)]
    [([x1 : Real] [y1 : Real] [x2 : Real] [y2 : Real] [step-dist : Real])
     (step-away-xy x1 y1 x2 y2 step-dist)]))

(: clamp-point-to-map (case-> (-> point2d point2d)
                              (-> point2d Real Real point2d)
                              (-> point2d Real Real Real Real point2d)
                              (-> Real Real point2d)
                              (-> Real Real Real Real point2d)
                              (-> Real Real Real Real Real Real point2d)))
(define clamp-point-to-map
  (case-lambda
    [([pt : point2d])
     (point2d (clamp-real (point2d-x pt) 4.0 248.0)
              (clamp-real (point2d-y pt) 4.0 248.0))]
    [([x : Real] [y : Real])
     (point2d (clamp-real x 4.0 248.0)
              (clamp-real y 4.0 248.0))]
    [([pt : point2d] [min-c : Real] [max-c : Real])
     (point2d (clamp-real (point2d-x pt) min-c max-c)
              (clamp-real (point2d-y pt) min-c max-c))]
    [([x : Real] [y : Real] [min-c : Real] [max-c : Real])
     (point2d (clamp-real x min-c max-c)
              (clamp-real y min-c max-c))]
    [([pt : point2d] [min-x : Real] [min-y : Real] [max-x : Real] [max-y : Real])
     (point2d (clamp-real (point2d-x pt) min-x max-x)
              (clamp-real (point2d-y pt) min-y max-y))]
    [([x : Real] [y : Real] [min-x : Real] [min-y : Real] [max-x : Real] [max-y : Real])
     (point2d (clamp-real x min-x max-x)
              (clamp-real y min-y max-y))]))

;; Quantizes coordinate `v` to 2.5-tile grid increments cleanly on finite/non-finite inputs.
(: quantize-cell-2.5 (->* (Any) (Real Boolean) Float))
(define (quantize-cell-2.5 v [fallback 32.5] [quantize? #t])
  (define fb : Float (->float (if (finite-real? fallback) fallback 32.5)))
  (define sv : Float (->float (safe-tile-coord v fb)))
  (if quantize?
      (->float (safe-tile-coord (* 2.5 (round (/ sv 2.5))) sv))
      sv))

(: extract-xy-from-any (-> Any (U False (Pairof Float Float))))
(define (extract-xy-from-any item)
  (cond
    [(point2d? item)
     (cons (point2d-x item) (point2d-y item))]
    [(pair? item)
     (define a (car item))
     (define b (cdr item))
     (cond
       [(and (real? a) (real? b) (finite-real? a) (finite-real? b))
        (cons (->float a) (->float b))]
       [(and (real? a) (pair? b) (real? (car b)) (finite-real? a) (finite-real? (car b)))
        (cons (->float a) (->float (car b)))]
       [else #f])]
    [(hash? item)
     (define hx (hash-ref item 'x (lambda () #f)))
     (define hy (hash-ref item 'y (lambda () #f)))
     (if (and (real? hx) (real? hy) (finite-real? hx) (finite-real? hy))
         (cons (->float hx) (->float hy))
         #f)]
    [else #f]))

;; Offsets static defense / forward anchor >= `min-dist` (at least 5.0 tiles) away from
;; `anchor` and from each expansion pad in `avoid-pads` toward `(enemy-x, enemy-y)`.
(: offset-defense-anchor (->* (Real Real Real Real) (Real (Listof Any)) (Values Float Float)))
(define (offset-defense-anchor anchor-x anchor-y enemy-x enemy-y [min-dist 5.5] [avoid-pads '()])
  (define ax : Float (safe-finite-real anchor-x 32.5))
  (define ay : Float (safe-finite-real anchor-y 32.5))
  (define ex : Float (safe-finite-real enemy-x 160.5))
  (define ey : Float (safe-finite-real enemy-y 160.5))
  (define dx : Float (- ex ax))
  (define dy : Float (- ey ay))
  (define d : Float (max 1.0 (->float (sqrt (max 0.0 (+ (* dx dx) (* dy dy)))))))
  (define eff-d : Float (max 5.0 (safe-finite-real min-dist 5.5)))
  (define cx0 : Float (+ ax (* eff-d (/ dx d))))
  (define cy0 : Float (+ ay (* eff-d (/ dy d))))
  (define-values (cx2 cy2)
    (for/fold ([rx : Float cx0] [ry : Float cy0])
              ([pad (in-list avoid-pads)])
      (define xy (extract-xy-from-any pad))
      (cond
        [(not xy) (values rx ry)]
        [else
         (define px : Float (car xy))
         (define py : Float (cdr xy))
         (if (< (dist-sq-xy rx ry px py) 25.0)
             (let* ([pdx : Float (- ex px)]
                    [pdy : Float (- ey py)]
                    [plen : Float (max 1.0 (->float (sqrt (max 0.0 (+ (* pdx pdx) (* pdy pdy))))))])
               (values (+ px (* 5.5 (/ pdx plen)))
                       (+ py (* 5.5 (/ pdy plen)))))
             (values rx ry))])))
  (values (->float (safe-tile-coord cx2 ax))
          (->float (safe-tile-coord cy2 ay))))

(: footprints-disjoint? (-> Real Real Real Real Real Real Real Real Boolean))
(define (footprints-disjoint? cx1 cy1 hw1 hh1 cx2 cy2 hw2 hh2)
  (or (>= (abs (- (->float cx1) (->float cx2)))
          (- (+ (->float hw1) (->float hw2)) 1e-6))
      (>= (abs (- (->float cy1) (->float cy2)))
          (- (+ (->float hh1) (->float hh2)) 1e-6))))

(: footprints-touch-gap (-> Real Real Real Real Real Real Real Real Float))
(define (footprints-touch-gap cx1 cy1 hw1 hh1 cx2 cy2 hw2 hh2)
  (max (- (abs (- (->float cx1) (->float cx2))) (+ (->float hw1) (->float hw2)))
       (- (abs (- (->float cy1) (->float cy2))) (+ (->float hh1) (->float hh2)))))

(: footprints-share-edge? (-> Real Real Real Real Real Real Real Real Boolean))
(define (footprints-share-edge? cx1 cy1 hw1 hh1 cx2 cy2 hw2 hh2)
  (define dx : Float (abs (- (->float cx1) (->float cx2))))
  (define dy : Float (abs (- (->float cy1) (->float cy2))))
  (define sx : Float (+ (->float hw1) (->float hw2)))
  (define sy : Float (+ (->float hh1) (->float hh2)))
  (and (footprints-disjoint? cx1 cy1 hw1 hh1 cx2 cy2 hw2 hh2)
       (or (and (<= (abs (- dx sx)) 0.05) (<= dy (- sy 0.9)))
           (and (<= (abs (- dy sy)) 0.05) (<= dx (- sx 0.9))))))

(: aabb2d-overlaps? (case-> (-> aabb2d aabb2d Boolean)
                            (-> Real Real Real Real aabb2d Boolean)
                            (-> Real Real Real Real Real Real Real Real Boolean)))
(define aabb2d-overlaps?
  (case-lambda
    [([a : aabb2d] [b : aabb2d])
     (not (footprints-disjoint? (aabb2d-cx a) (aabb2d-cy a) (aabb2d-half-w a) (aabb2d-half-h a)
                                (aabb2d-cx b) (aabb2d-cy b) (aabb2d-half-w b) (aabb2d-half-h b)))]
    [([cx1 : Real] [cy1 : Real] [hw1 : Real] [hh1 : Real] [b : aabb2d])
     (not (footprints-disjoint? cx1 cy1 hw1 hh1
                                (aabb2d-cx b) (aabb2d-cy b) (aabb2d-half-w b) (aabb2d-half-h b)))]
    [([cx1 : Real] [cy1 : Real] [hw1 : Real] [hh1 : Real]
      [cx2 : Real] [cy2 : Real] [hw2 : Real] [hh2 : Real])
     (not (footprints-disjoint? cx1 cy1 hw1 hh1 cx2 cy2 hw2 hh2))]))

(: aabb-overlaps? (case-> (-> aabb2d aabb2d Boolean)
                          (-> Real Real Real Real aabb2d Boolean)
                          (-> Real Real Real Real Real Real Real Real Boolean)))
(define aabb-overlaps? aabb2d-overlaps?)

;; Returns canonical SC2 structure half-extent (2.5 for 5x5 townhalls, 1.0 for 2x2 buildings,
;; 0.5 for 1x1 creep tumors/turrets, and 1.5 for standard 3x3 structures).
;; Also maps exact tile widths 1/2/3/5 to 0.5/1.0/1.5/2.5.
(: building-footprint-half-extent (-> Any Float))
(define (building-footprint-half-extent spec)
  (cond
    [(and (real? spec) (finite-real? spec))
     (* 0.5 (abs (->float spec)))]
    [else
     (define sym : Symbol (unit-type-sym spec))
     (case sym
       [(hatchery lair hive nexus
         command-center command-center-flying
         orbital-command orbital-command-flying
         planetary-fortress)
        2.5]
       [(supply-depot supply-depot-lowered missile-turret sensor-tower
         pylon pylon-overcharged photon-cannon shield-battery dark-shrine oracle-stasis-trap
         spire greater-spire spine-crawler spine-crawler-uprooted
         spore-crawler spore-crawler-uprooted
         barracks-techlab barracks-tech-lab barracks-reactor
         factory-techlab factory-tech-lab factory-reactor
         starport-techlab starport-tech-lab starport-reactor
         tech-lab techlab reactor)
        1.0]
       [(creep-tumor creep-tumor-burrowed creep-tumor-queen
         auto-turret point-defense-drone stasis-ward)
        0.5]
       [else 1.5])]))

(: resolve-extent (-> Any Float))
(define (resolve-extent ext)
  (if (and (real? ext) (finite-real? ext))
      (abs (->float ext))
      (building-footprint-half-extent ext)))

(: footprint-overlaps?
   (case-> (-> aabb2d aabb2d Boolean)
           (-> point2d Any point2d Any Boolean)
           (-> Real Real Any Real Real Any Boolean)
           (-> Real Real Real Real Real Real Real Real Boolean)))
(define footprint-overlaps?
  (case-lambda
    [([a : aabb2d] [b : aabb2d])
     (aabb2d-overlaps? a b)]
    [([p1 : point2d] [ext1 : Any] [p2 : point2d] [ext2 : Any])
     (define h1 : Float (resolve-extent ext1))
     (define h2 : Float (resolve-extent ext2))
     (not (footprints-disjoint? (point2d-x p1) (point2d-y p1) h1 h1
                                (point2d-x p2) (point2d-y p2) h2 h2))]
    [([x1 : Real] [y1 : Real] [ext1 : Any] [x2 : Real] [y2 : Real] [ext2 : Any])
     (define h1 : Float (resolve-extent ext1))
     (define h2 : Float (resolve-extent ext2))
     (not (footprints-disjoint? x1 y1 h1 h1 x2 y2 h2 h2))]
    [([x1 : Real] [y1 : Real] [hw1 : Real] [hh1 : Real]
      [x2 : Real] [y2 : Real] [hw2 : Real] [hh2 : Real])
     (not (footprints-disjoint? x1 y1 hw1 hh1 x2 y2 hw2 hh2))]))

(: point-in-circle? (case-> (-> point2d point2d Real Boolean)
                            (-> Real Real Real Real Real Boolean)))
(define point-in-circle?
  (case-lambda
    [([pt : point2d] [center : point2d] [radius : Real])
     (define r : Float (max 0.0 (->float radius)))
     (<= (dist-sq-xy (point2d-x pt) (point2d-y pt) (point2d-x center) (point2d-y center))
         (* r r))]
    [([px : Real] [py : Real] [cx : Real] [cy : Real] [radius : Real])
     (define r : Float (max 0.0 (->float radius)))
     (<= (dist-sq-xy px py cx cy) (* r r))]))

(: centroid-2d (-> (Listof Any) point2d))
(define (centroid-2d pts)
  (define-values (sx sy cnt)
    (for/fold ([ax : Float 0.0] [ay : Float 0.0] [n : Nonnegative-Integer 0])
              ([p (in-list pts)])
      (define xy (extract-xy-from-any p))
      (if xy
          (values (+ ax (car xy)) (+ ay (cdr xy)) (add1 n))
          (values ax ay n))))
  (if (zero? cnt)
      (point2d 0.0 0.0)
      (let ([fn : Float (->float cnt)])
        (point2d (/ sx fn) (/ sy fn)))))

(: snap-3x3-coord (-> Real Float))
(define (snap-3x3-coord c)
  (+ (floor (->float c)) 0.5))

(: snap-2x2-coord (-> Real Float))
(define (snap-2x2-coord c)
  (->float (round (->float c))))

(: point-to-segment-dist (-> Real Real Real Real Real Real Float))
(define (point-to-segment-dist px py ax ay bx by)
  (define fpx : Float (->float px))
  (define fpy : Float (->float py))
  (define fax : Float (->float ax))
  (define fay : Float (->float ay))
  (define dx : Float (- (->float bx) fax))
  (define dy : Float (- (->float by) fay))
  (define len2 : Float (+ (* dx dx) (* dy dy)))
  (if (<= len2 1e-6)
      (->float (sqrt (dist-sq-xy fpx fpy fax fay)))
      (let* ([raw-t : Float (/ (+ (* (- fpx fax) dx) (* (- fpy fay) dy)) len2)]
             [t : Float (max 0.0 (min 1.0 raw-t))])
        (->float (sqrt (dist-sq-xy fpx fpy (+ fax (* t dx)) (+ fay (* t dy))))))))
