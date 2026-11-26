#lang racket/base

;; =============================================================================
;; Loop 85 Track 1: Wide PvZ Natural Sealing, Full-Map Seal Verification,
;; 6.25t Pylon Power Tightening, 3-Slot Wire Placement & 14-Spawn Map Audit
;; =============================================================================

(require racket/file
         racket/list
         racket/match
         racket/math
         racket/port
         racket/set
         racket/system
         json
         "../lib/sc2-game-constants.rkt"
         "../lib/sc2-placement.rkt"
         "../lib/sc2-protobuf-ws.rkt")

(define pass-count 0)
(define fail-count 0)

(define (check-true name expr)
  (if expr
      (set! pass-count (add1 pass-count))
      (begin
        (set! fail-count (add1 fail-count))
        (printf "FAIL [~a]: expected truthy, got ~s\n" name expr))))

(define (check-equal name actual expected)
  (if (equal? actual expected)
      (set! pass-count (add1 pass-count))
      (begin
        (set! fail-count (add1 fail-count))
        (printf "FAIL [~a]: expected ~s, got ~s\n" name expected actual))))

(define (dist2d x1 y1 x2 y2)
  (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))

(define (make-bytes-grids w h path place height)
  (hash 'width w
        'height h
        'pathing-ref (lambda (x y)
                       (if (and (>= x 0) (< x w) (>= y 0) (< y h))
                           (bytes-ref path (+ (* y w) x))
                           0))
        'placement-ref (lambda (x y)
                         (if (and (>= x 0) (< x w) (>= y 0) (< y h))
                             (bytes-ref place (+ (* y w) x))
                             0))
        'height-ref (lambda (x y)
                      (if (and (>= x 0) (< x w) (>= y 0) (< y h))
                          (exact->inexact (bytes-ref height (+ (* y w) x)))
                          0.0))))

;; Full-map 4-connected ground reachability between (sx, sy) and (gx, gy) avoiding `rects`
;; where each rect is (list cx cy hw hh).
(define (full-map-4conn-reachable? w h path sx sy gx gy rects)
  (define (blocked? ix iy)
    (define wx (+ ix 0.5))
    (define wy (+ iy 0.5))
    (for/or ([r (in-list rects)])
      (and (>= wx (- (first r) (third r))) (<= wx (+ (first r) (third r)))
           (>= wy (- (second r) (fourth r))) (<= wy (+ (second r) (fourth r))))))
  (define (pass? ix iy)
    (and (>= ix 0) (< ix w) (>= iy 0) (< iy h)
         (> (bytes-ref path (+ (* iy w) ix)) 0)
         (not (blocked? ix iy))))
  (define vis (make-bytes (* w h) 0))
  (define q (make-vector (* w h) 0))
  (define qh 0)
  (define qt 0)
  (define (enq ix iy)
    (when (and (pass? ix iy) (= (bytes-ref vis (+ (* iy w) ix)) 0))
      (bytes-set! vis (+ (* iy w) ix) 1)
      (vector-set! q qt (+ (* iy w) ix))
      (set! qt (add1 qt))))
  (define sx0 (inexact->exact (floor sx)))
  (define sy0 (inexact->exact (floor sy)))
  (for* ([dy (in-range -4 5)] [dx (in-range -4 5)])
    (enq (+ sx0 dx) (+ sy0 dy)))
  (let loop ()
    (cond
      [(>= qh qt) #f]
      [else
       (define u (vector-ref q qh))
       (set! qh (add1 qh))
       (define ux (remainder u w))
       (define uy (quotient u w))
       (if (<= (+ (sqr (- ux gx)) (sqr (- uy gy))) 36)
           #t
           (begin
             (enq (add1 ux) uy)
             (enq (sub1 ux) uy)
             (enq ux (add1 uy))
             (enq ux (sub1 uy))
             (loop)))])))

(define (wall-rects-with-nat wall nx ny)
  (define pyl (hash-ref wall 'pylon #f))
  (define s1 (hash-ref wall 'slot-1 #f))
  (define s2 (hash-ref wall 'slot-2 #f))
  (define s3 (hash-ref wall 'slot-3 #f))
  (filter values
          (list (list nx ny 2.5 2.5)
                (and pyl (list (car pyl) (cdr pyl) 1.0 1.0))
                (and s1  (list (car s1)  (cdr s1)  1.5 1.5))
                (and s2  (list (car s2)  (cdr s2)  1.5 1.5))
                (and s3  (list (car s3)  (cdr s3)  1.5 1.5)))))

(define (wall-door-rect wall)
  (define dx (hash-ref wall 'door-x #f))
  (define dy (hash-ref wall 'door-y #f))
  (and dx dy (list dx dy 0.5 0.5)))

(define (wall-max-pylon-dist wall)
  (define pyl (hash-ref wall 'pylon #f))
  (define slots (filter values (list (hash-ref wall 'slot-1 #f)
                                     (hash-ref wall 'slot-2 #f)
                                     (hash-ref wall 'slot-3 #f))))
  (if (and pyl (pair? slots))
      (apply max (for/list ([s (in-list slots)])
                   (dist2d (car pyl) (cdr pyl) (car s) (cdr s))))
      99.0))

(define (mk-unit tag utype alliance x y #:bp [bp 1.0] #:orders [orders '()])
  (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 2)
            (sc2-point3d x y 8.0) 0.0 1.0 bp 0 #f #f #f
            100.0 100.0 0.0 0.0 0.0 200.0
            0 0 #f #f #f #t #f orders 0 '() 0 0 0.0 0 0 0 0))

(define (mk-obs loop units)
  (sc2-observation loop
                   (sc2-player-common 1 500 200 24 40 0 0 16 1 0 0)
                   units '() '() #f '() '() '() '() '() '()))

(define (verify-wire-exact-wall-slots wall bx by nx ny)
  (define pyl (hash-ref wall 'pylon #f))
  (define s1 (hash-ref wall 'slot-1 #f))
  (define s2 (hash-ref wall 'slot-2 #f))
  (define s3 (hash-ref wall 'slot-3 #f))
  (define dx (hash-ref wall 'door-x #f))
  (define dy (hash-ref wall 'door-y #f))
  (define dpx (hash-ref wall 'door-park-x dx))
  (define dpy (hash-ref wall 'door-park-y dy))
  (define raabbs
    (filter values
            (list (and pyl (reserved-aabb (car pyl) (cdr pyl) 1.0 1.0 'wall-slot 0 0))
                  (and s1  (reserved-aabb (car s1)  (cdr s1)  1.5 1.5 'wall-slot 0 0))
                  (and s2  (reserved-aabb (car s2)  (cdr s2)  1.5 1.5 'wall-slot 0 0))
                  (and s3  (reserved-aabb (car s3)  (cdr s3)  1.5 1.5 'wall-slot 0 0))
                  (and dx dy (reserved-aabb dx dy 1.2 1.2 'doorway-corridor 0 0))
                  (and dpx dpy (reserved-aabb dpx dpy 1.2 1.2 'doorway-corridor 0 0)))))
  (define u-nex (mk-unit 1 59 1 bx by))
  (define u-nat (mk-unit 2 59 1 nx ny))
  (define p-pt (and pyl (find-verified-building-placement #f 881 (car pyl) (cdr pyl) (list u-nex u-nat)
                                                          #:min-spacing 0.0 #:reserved-aabbs raabbs
                                                          #:expansion-pads (list (cons nx ny)) #:bldg-sym 'pylon)))
  (define u-pyl (and pyl (mk-unit 3 60 1 (car pyl) (cdr pyl))))
  (define s1-pt (and s1 u-pyl (find-verified-building-placement #f 883 (car s1) (cdr s1) (list u-nex u-nat u-pyl)
                                                                #:min-spacing 0.0 #:reserved-aabbs raabbs
                                                                #:expansion-pads (list (cons nx ny)) #:bldg-sym 'gateway)))
  (define u-s1 (and s1 (mk-unit 4 62 1 (car s1) (cdr s1))))
  (define s2-pt (and s2 u-pyl u-s1 (find-verified-building-placement #f 894 (car s2) (cdr s2) (list u-nex u-nat u-pyl u-s1)
                                                                     #:min-spacing 0.0 #:reserved-aabbs raabbs
                                                                     #:expansion-pads (list (cons nx ny)) #:bldg-sym 'cybernetics-core)))
  (define u-s2 (and s2 (mk-unit 5 72 1 (car s2) (cdr s2))))
  (define s3-pt (if s3
                    (find-verified-building-placement #f 883 (car s3) (cdr s3) (list u-nex u-nat u-pyl u-s1 u-s2)
                                                      #:min-spacing 0.0 #:reserved-aabbs raabbs
                                                      #:expansion-pads (list (cons nx ny)) #:bldg-sym 'gateway)
                    'none))
  (define (eq-pt? pt target)
    (and (sc2-point2d? pt)
         (= (sc2-point2d-x pt) (car target))
         (= (sc2-point2d-y pt) (cdr target))))
  (and (eq-pt? p-pt pyl)
       (eq-pt? s1-pt s1)
       (eq-pt? s2-pt s2)
       (or (eq? s3-pt 'none) (eq-pt? s3-pt s3))))

;; =============================================================================
;; 1. Wide Straight, Wide Diagonal (35 deg) & Large-Shelf Natural Chokes
;; =============================================================================
(printf "[1/4] Testing wide straight, diagonal (35 deg), and large-shelf PvZ natural chokes...\n")

;; Helper: build an elevated 150x150 map with main high-ground on West, ramp to natural,
;; and configurable choke opening into an expansive outer battlefield (enemy main on East).
(define (make-elevated-nat-map #:choke-width [cw 10]
                               #:diagonal? [diag? #f]
                               #:shelf-dist [shelf-d 11]
                               #:flank-leak? [flank-leak? #f])
  (define w 150)
  (define h 150)
  (define path (make-bytes (* w h) 0))
  (define place (make-bytes (* w h) 0))
  (define height (make-bytes (* w h) 96))
  (define (set-cell! x y p b hv)
    (when (and (>= x 0) (< x w) (>= y 0) (< y h))
      (define i (+ (* y w) x))
      (bytes-set! path i p)
      (bytes-set! place i b)
      (bytes-set! height i hv)))
  ;; Main plateau (West, height 112): x in [10..34], y in [55..95]
  (for* ([y (in-range 55 96)] [x (in-range 10 35)])
    (set-cell! x y 1 1 112))
  ;; 2-tile Main Ramp: x in [35..38], y in [74..75]
  (for* ([y (in-range 74 76)] [x (in-range 35 39)])
    (set-cell! x y 1 0 (- 112 (* 4 (- x 34)))))
  ;; Natural basin: x in [39 .. 49+shelf-d], y in [58..92], height 96
  (define nat-x 48.5)
  (define nat-y 75.5)
  (define wall-x (+ 48 shelf-d))
  (for* ([y (in-range 58 93)] [x (in-range 39 wall-x)])
    (set-cell! x y 1 1 96))
  ;; Outer battlefield (East): x in [wall-x+3 .. 140], y in [20..130], height 96
  (for* ([y (in-range 20 131)] [x (in-range (+ wall-x 3) 141)])
    (set-cell! x y 1 1 96))
  (cond
    [(not diag?)
     ;; Straight choke of width `cw` centered at (wall-x+1, 75)
     (define y0 (- 75 (quotient cw 2)))
     (define y1 (+ y0 cw))
     (for* ([y (in-range y0 y1)] [x (in-range wall-x (+ wall-x 3))])
       (set-cell! x y 1 1 96))
     ;; Optional secondary NW wrap-around flank leak (4-tile wide opening 14 tiles north of main choke)
     ;; that lies outside the 44x44 local pocket src->dst cut unless full-map seal verification catches it!
     (when flank-leak?
       (for* ([y (in-range 88 92)] [x (in-range wall-x (+ wall-x 3))])
         (set-cell! x y 1 1 96)))]
    [else
     ;; Diagonal / oblique (~35 deg) wide choke connecting natural basin to outer battlefield!
     ;; Clear all low-ground x >= 39 and carve a single clean diagonal divider along
     ;; u = (x - wall-x) - 0.7*(y - 75) in [-1.5 .. 2.5], open ONLY where |v| <= (cw / 2) - 0.5.
     (for* ([y (in-range 20 131)] [x (in-range 39 141)])
       (define u (- (- x wall-x) (* 0.7 (- y 75))))
       (define v (+ (* 0.7 (- x wall-x)) (- y 75)))
       (cond
         [(< u -1.5)
          ;; Natural basin side (bounded north/south at y in [58..92])
          (if (and (>= y 58) (<= y 92))
              (set-cell! x y 1 1 96)
              (set-cell! x y 0 0 96))]
         [(<= u 2.5)
          ;; Diagonal cliff barrier with single oblique mouth of width ~cw tiles
          (if (and (>= y 58) (<= y 92) (<= (abs v) (- (/ cw 2.0) 0.5)))
              (set-cell! x y 1 1 96)
              (set-cell! x y 0 0 96))]
         [else
          ;; Outer battlefield side
          (set-cell! x y 1 1 96)]))])
  (values (make-bytes-grids w h path place height) w h path 22.5 75.5 nat-x nat-y 132.5 75.5))

;; 1a. 10-tile wide straight natural choke -> sealed 3-slot wall, <= 6.25t Pylon, < 150ms
(define-values (mg-s10 ws10 hs10 ps10 bx10 by10 nx10 ny10 ex10 ey10)
  (make-elevated-nat-map #:choke-width 10 #:diagonal? #f #:shelf-dist 11))
(define t1a-0 (current-inexact-milliseconds))
(define w-s10 (solve-protoss-matchup-wall bx10 by10 nx10 ny10 'Zerg #:map-grids mg-s10 #:enemy-x ex10 #:enemy-y ey10))
(define dt-1a (- (current-inexact-milliseconds) t1a-0))
(define r-s10 (wall-rects-with-nat w-s10 nx10 ny10))
(check-equal "l85-wide10-straight-locus" (hash-ref w-s10 'locus) 'natural-choke)
(check-true  "l85-wide10-straight-sealed" (hash-ref w-s10 'sealed? #f))
(check-true  "l85-wide10-straight-slot3-populated" (pair? (hash-ref w-s10 'slot-3 #f)))
(check-true  "l85-wide10-straight-valid-on-grids" (protoss-wall-valid-on-grids? w-s10 bx10 by10 nx10 ny10 mg-s10))
(check-true  "l85-wide10-straight-full-map-open" (full-map-4conn-reachable? ws10 hs10 ps10 bx10 by10 ex10 ey10 r-s10))
(check-true  "l85-wide10-straight-full-map-plugged-sealed"
             (not (full-map-4conn-reachable? ws10 hs10 ps10 bx10 by10 ex10 ey10 (cons (wall-door-rect w-s10) r-s10))))
(check-true  "l85-wide10-straight-pylon-le-6.25" (<= (wall-max-pylon-dist w-s10) 6.25))
(check-true  "l85-wide10-straight-under-150ms" (< dt-1a 150.0))

;; 1b. 10-tile wide diagonal (~35 deg) natural choke -> multi-rotation cross-section finds choke & seals!
(define-values (mg-d10 wd10 hd10 pd10 bxd10 byd10 nxd10 nyd10 exd10 eyd10)
  (make-elevated-nat-map #:choke-width 10 #:diagonal? #t #:shelf-dist 12))
(define t1b-0 (current-inexact-milliseconds))
(define w-d10 (solve-protoss-matchup-wall bxd10 byd10 nxd10 nyd10 'Zerg #:map-grids mg-d10 #:enemy-x exd10 #:enemy-y eyd10))
(define dt-1b (- (current-inexact-milliseconds) t1b-0))
(define r-d10 (wall-rects-with-nat w-d10 nxd10 nyd10))
(check-equal "l85-wide10-diag-locus" (hash-ref w-d10 'locus) 'natural-choke)
(check-true  "l85-wide10-diag-sealed" (hash-ref w-d10 'sealed? #f))
(check-true  "l85-wide10-diag-valid-on-grids" (protoss-wall-valid-on-grids? w-d10 bxd10 byd10 nxd10 nyd10 mg-d10))
(check-true  "l85-wide10-diag-full-map-open" (full-map-4conn-reachable? wd10 hd10 pd10 bxd10 byd10 exd10 eyd10 r-d10))
(check-true  "l85-wide10-diag-full-map-plugged-sealed"
             (not (full-map-4conn-reachable? wd10 hd10 pd10 bxd10 byd10 exd10 eyd10 (cons (wall-door-rect w-d10) r-d10))))
(check-true  "l85-wide10-diag-pylon-le-6.25" (<= (wall-max-pylon-dist w-d10) 6.25))
(check-true  "l85-wide10-diag-under-150ms" (< dt-1b 150.0))

;; 1c. Large-shelf natural choke at d ~ 22-24 -> still discovered (d <= 26) and sealed!
(define-values (mg-sh wsh hsh psh bxsh bysh nxsh nysh exsh eysh)
  (make-elevated-nat-map #:choke-width 8 #:diagonal? #f #:shelf-dist 22))
(define t1c-0 (current-inexact-milliseconds))
(define w-sh (solve-protoss-matchup-wall bxsh bysh nxsh nysh 'Zerg #:map-grids mg-sh #:enemy-x exsh #:enemy-y eysh))
(define dt-1c (- (current-inexact-milliseconds) t1c-0))
(define r-sh (wall-rects-with-nat w-sh nxsh nysh))
(check-equal "l85-large-shelf-locus" (hash-ref w-sh 'locus) 'natural-choke)
(check-true  "l85-large-shelf-sealed" (hash-ref w-sh 'sealed? #f))
(check-true  "l85-large-shelf-full-map-open" (full-map-4conn-reachable? wsh hsh psh bxsh bysh exsh eysh r-sh))
(check-true  "l85-large-shelf-full-map-plugged-sealed"
             (not (full-map-4conn-reachable? wsh hsh psh bxsh bysh exsh eysh (cons (wall-door-rect w-sh) r-sh))))
(check-true  "l85-large-shelf-pylon-le-6.25" (<= (wall-max-pylon-dist w-sh) 6.25))
(check-true  "l85-large-shelf-under-150ms" (< dt-1c 150.0))

;; =============================================================================
;; 2. Full-Map Seal Verification: Reject False-Positive Local Pocket Seals &
;;    Promote Unsealable Dual-Exit Naturals to Sealed Main-Ramp Wall
;; =============================================================================
(printf "[2/4] Testing full-map seal verification (flank wrap-around leak rejection + Pass 1C promotion)...\n")

;; 2a. Dual-exit natural (6t front choke + 4t secondary flank leak 14t north):
;;     No single natural wall seals both exits! `wide-seal-ok?` MUST REJECT any false-positive local
;;     2-slot wall on the 6t choke, and Pass 1C MUST promote to a genuinely FULL-MAP-SEALED main-ramp wall!
(define-values (mg-lk wlk hlk plk bxlk bylk nxlk nylk exlk eylk)
  (make-elevated-nat-map #:choke-width 6 #:diagonal? #f #:shelf-dist 11 #:flank-leak? #t))
(define t2a-0 (current-inexact-milliseconds))
(define w-lk (solve-protoss-matchup-wall bxlk bylk nxlk nylk 'Zerg #:map-grids mg-lk #:enemy-x exlk #:enemy-y eylk))
(define dt-2a (- (current-inexact-milliseconds) t2a-0))
(define r-lk (wall-rects-with-nat w-lk nxlk nylk))
(check-true  "l85-dual-exit-no-false-positive-sealed" (hash-ref w-lk 'sealed? #f))
(check-equal "l85-dual-exit-promotes-main-ramp" (hash-ref w-lk 'locus) 'main-ramp)
(check-true  "l85-dual-exit-full-map-open" (full-map-4conn-reachable? wlk hlk plk bxlk bylk exlk eylk r-lk))
(check-true  "l85-dual-exit-full-map-plugged-sealed"
             (not (full-map-4conn-reachable? wlk hlk plk bxlk bylk exlk eylk (cons (wall-door-rect w-lk) r-lk))))
(check-true  "l85-dual-exit-pylon-le-6.25" (<= (wall-max-pylon-dist w-lk) 6.25))
(check-true  "l85-dual-exit-under-150ms" (< dt-2a 150.0))

;; 2b. Local wrap-around bypass trap (2-slot seals central 6t mouth, but a 2-tile notch right next to
;;     the NW corner leaks around a 2-slot wall while a 3-slot wall seals BOTH the mouth and notch!).
(define (make-flank-notch-map)
  (define w 150)
  (define h 150)
  (define path (make-bytes (* w h) 0))
  (define place (make-bytes (* w h) 0))
  (define height (make-bytes (* w h) 96))
  (define (set-cell! x y p b hv)
    (define i (+ (* y w) x))
    (bytes-set! path i p)
    (bytes-set! place i b)
    (bytes-set! height i hv))
  (for* ([y (in-range 55 96)] [x (in-range 10 35)]) (set-cell! x y 1 1 112))
  (for* ([y (in-range 74 76)] [x (in-range 35 39)]) (set-cell! x y 1 0 (- 112 (* 4 (- x 34)))))
  (for* ([y (in-range 58 93)] [x (in-range 39 59)]) (set-cell! x y 1 1 96))
  (for* ([y (in-range 20 131)] [x (in-range 62 141)]) (set-cell! x y 1 1 96))
  ;; 6t primary mouth at y in [71..76], 1-tile rock pillar at y=77, plus 2t flank notch at y in [78..79]
  ;; Total buildable span = 9t (y in [71..79]); 2-slot seals [71..76] locally but leaks through [78..79],
  ;; while 3-slot (or 2-slot + wall-pylon) seals [71..79] completely!
  (for* ([y (in-range 71 77)] [x (in-range 59 62)]) (set-cell! x y 1 1 96))
  (for* ([y (in-range 78 80)] [x (in-range 59 62)]) (set-cell! x y 1 1 96))
  (values (make-bytes-grids w h path place height) w h path 22.5 75.5 48.5 75.5 132.5 75.5))

(define-values (mg-fn wfn hfn pfn bxfn byfn nxfn nyfn exfn eyfn) (make-flank-notch-map))
(define t2b-0 (current-inexact-milliseconds))
(define w-fn (solve-protoss-matchup-wall bxfn byfn nxfn nyfn 'Zerg #:map-grids mg-fn #:enemy-x exfn #:enemy-y eyfn))
(define dt-2b (- (current-inexact-milliseconds) t2b-0))
(define r-fn (wall-rects-with-nat w-fn nxfn nyfn))
(check-equal "l85-flank-notch-keeps-natural-choke" (hash-ref w-fn 'locus) 'natural-choke)
(check-true  "l85-flank-notch-sealed" (hash-ref w-fn 'sealed? #f))
(check-true  "l85-flank-notch-valid-on-grids" (protoss-wall-valid-on-grids? w-fn bxfn byfn nxfn nyfn mg-fn))
(check-true  "l85-flank-notch-full-map-open" (full-map-4conn-reachable? wfn hfn pfn bxfn byfn exfn eyfn r-fn))
(check-true  "l85-flank-notch-full-map-plugged-sealed"
             (not (full-map-4conn-reachable? wfn hfn pfn bxfn byfn exfn eyfn (cons (wall-door-rect w-fn) r-fn))))
(check-true  "l85-flank-notch-pylon-le-6.25" (<= (wall-max-pylon-dist w-fn) 6.25))
(check-true  "l85-flank-notch-under-150ms" (< dt-2b 150.0))

;; =============================================================================
;; 3. Wire Exact 3-Slot Placement (`argmin` Touching Slots & Early-Rush Non-Override)
;; =============================================================================
(printf "[3/4] Testing sc2-protobuf-ws 3-slot touching wall-slot exactness & early-rush guard...\n")

;; 3a. Three touching 3.0t adjacent wall slots (`slot-1`, `slot-2`, `slot-3`) + doorway-corridor AABBs:
;;     `matched-wall-slot` MUST pick the nearest slot via `argmin`, never drifting `slot-2` or `slot-3`!
(define touch3-reserved
  (list (reserved-aabb 54.0 135.0 1.0 1.0 'wall-slot 0 0)        ; pylon
        (reserved-aabb 55.5 137.5 1.5 1.5 'wall-slot 0 0)        ; slot-1
        (reserved-aabb 52.5 137.5 1.5 1.5 'wall-slot 0 0)        ; slot-2 (touches slot-1 at EXACT 3.0t!)
        (reserved-aabb 52.5 140.5 1.5 1.5 'wall-slot 0 0)        ; slot-3 (touches slot-2 at EXACT 3.0t!)
        (reserved-aabb 55.5 140.5 1.2 1.2 'doorway-corridor 0 0) ; door
        (reserved-aabb 54.0 139.0 1.2 1.2 'doorway-corridor 0 0))) ; door-park
(define t3-nex (mk-unit 800 59 1 37.5 145.5))
(define t3-pyl (mk-unit 801 60 1 54.0 135.0))
(define t3-gw1 (mk-unit 802 62 1 55.5 137.5))
(define t3-core (mk-unit 803 72 1 52.5 137.5))

(define t3-s1-pt
  (find-verified-building-placement #f 883 55.5 137.5 (list t3-nex t3-pyl)
                                    #:min-spacing 0.0 #:reserved-aabbs touch3-reserved #:bldg-sym 'gateway))
(define t3-s2-pt
  (find-verified-building-placement #f 894 52.5 137.5 (list t3-nex t3-pyl t3-gw1)
                                    #:min-spacing 0.0 #:reserved-aabbs touch3-reserved #:bldg-sym 'cybernetics-core))
(define t3-s3-pt
  (find-verified-building-placement #f 883 52.5 140.5 (list t3-nex t3-pyl t3-gw1 t3-core)
                                    #:min-spacing 0.0 #:reserved-aabbs touch3-reserved #:bldg-sym 'gateway))
(check-true "wire-l85-touch3-slot1-exact"
            (and (sc2-point2d? t3-s1-pt) (= (sc2-point2d-x t3-s1-pt) 55.5) (= (sc2-point2d-y t3-s1-pt) 137.5)))
(check-true "wire-l85-touch3-slot2-exact-argmin"
            (and (sc2-point2d? t3-s2-pt) (= (sc2-point2d-x t3-s2-pt) 52.5) (= (sc2-point2d-y t3-s2-pt) 137.5)))
(check-true "wire-l85-touch3-slot3-exact-argmin"
            (and (sc2-point2d? t3-s3-pt) (= (sc2-point2d-x t3-s3-pt) 52.5) (= (sc2-point2d-y t3-s3-pt) 140.5)))

;; 3b. Active < 4:00 12-Pool Ling flood (`4` Zerglings near Main + `1` Zergling 5.5t from natural wall):
;;     - CyberCore on `wall-slot-2` & Gateway #2 on `wall-slot-3` MUST land at exact wall-slot coordinates!
;;     - Non-wall Gateway #2 MUST still redirect to Main Pylon (`early-rush-gw2-main-safe?`).
;;     - Fragile RoboticsFacility MUST never claim a front `'wall-slot`.
(define main-pyl (mk-unit 804 60 1 36.0 151.0))
(define probe-u  (mk-unit 805 84 1 48.0 139.0))
(define lings
  (list (mk-unit 901 105 4 57.5 142.0)  ; 5.5t from wall-slot-3 -> triggers req-contested? if unprotected!
        (mk-unit 902 105 4 49.0 144.0)
        (mk-unit 903 105 4 47.0 144.0)
        (mk-unit 904 105 4 45.0 144.0)))
(define rush-obs (mk-obs 2800 (append (list t3-nex main-pyl t3-pyl t3-gw1 probe-u) lings)))
(define rush-obs-s3 (mk-obs 2800 (append (list t3-nex main-pyl t3-pyl t3-gw1 t3-core probe-u) lings)))

(define core-wall-cmds
  (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 894)))
          (translate-bot-actions->sc2-raw-commands '((build cybernetics-core 52.5 137.5))
                                                   rush-obs
                                                   #:reserved-aabbs touch3-reserved)))
(check-true "wire-l85-rush-cybercore-wall-slot2-exact"
            (and (= (length core-wall-cmds) 1)
                 (let ([tp (sc2-raw-unit-command-target-pos (first core-wall-cmds))])
                   (and (sc2-point2d? tp)
                        (= (sc2-point2d-x tp) 52.5)
                        (= (sc2-point2d-y tp) 137.5)))))

(define gw2-wall-cmds
  (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 883)))
          (translate-bot-actions->sc2-raw-commands '((build gateway 52.5 140.5))
                                                   rush-obs-s3
                                                   #:reserved-aabbs touch3-reserved)))
(check-true "wire-l85-rush-gw2-wall-slot3-exact"
            (and (= (length gw2-wall-cmds) 1)
                 (let ([tp (sc2-raw-unit-command-target-pos (first gw2-wall-cmds))])
                   (and (sc2-point2d? tp)
                        (= (sc2-point2d-x tp) 52.5)
                        (= (sc2-point2d-y tp) 140.5)))))

;; Non-wall Gateway #2 requested near natural pylon (NOT a wall-slot!) under Ling rush -> redirected to Main Pylon!
(define gw2-nonwall-cmds
  (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 883)))
          (translate-bot-actions->sc2-raw-commands '((build gateway 57.5 133.5))
                                                   rush-obs-s3
                                                   #:reserved-aabbs touch3-reserved)))
(check-true "wire-l85-rush-nonwall-gw2-stays-in-main"
            (and (= (length gw2-nonwall-cmds) 1)
                 (let ([tp (sc2-raw-unit-command-target-pos (first gw2-nonwall-cmds))])
                   (and (sc2-point2d? tp)
                        (<= (dist2d (sc2-point2d-x tp) (sc2-point2d-y tp) 36.0 151.0) 7.0)))))

;; Fragile RoboticsFacility requested on wall-slot-3 -> NEVER placed on wall-slot-3!
(define robo-wall-cmds
  (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 893)))
          (translate-bot-actions->sc2-raw-commands '((build robotics-facility 52.5 140.5))
                                                   rush-obs-s3
                                                   #:reserved-aabbs touch3-reserved)))
(check-true "wire-l85-fragile-robo-never-claims-wall-slot"
            (or (null? robo-wall-cmds)
                (let ([tp (sc2-raw-unit-command-target-pos (first robo-wall-cmds))])
                  (not (and (= (sc2-point2d-x tp) 52.5) (= (sc2-point2d-y tp) 140.5))))))

;; =============================================================================
;; 4. Live Competition Ladder 14-Spawn Offline Map Audit (when local SC2 maps exist)
;; =============================================================================
(define map-dir "/home/sjaconette/sc2-local-arena/maps")
(define manifest-path (build-path map-dir "maps_manifest.json"))
(define pylibs-dir "/home/sjaconette/sc2-local-arena/pylibs")
(define py-exe (find-executable-path "python3"))

(cond
  [(and py-exe (file-exists? manifest-path) (directory-exists? pylibs-dir))
   (printf "[4/4] Auditing all 14 real SC2 Competition spawns (pnp==0 & pnp<128 + PvP + Terran + wire)...\n")
   (define extract-py #<<PY
import os, sys, json, struct, math, collections, xml.etree.ElementTree as ET
sys.path.insert(0, "/home/sjaconette/sc2-local-arena/pylibs")
import mpyq

map_dir = "/home/sjaconette/sc2-local-arena/maps"
manifest = json.load(open(os.path.join(map_dir, "maps_manifest.json")))
out = {"pnp0": [], "pnp128": []}

for entry in manifest["maps"]:
    mpath = os.path.join(map_dir, entry["filename"])
    arch = mpyq.MPQArchive(mpath)
    t3 = ET.fromstring(arch.read_file("t3Terrain.xml"))
    dim = [int(v) for v in t3.find(".//heightMap").attrib["dim"].split()]
    w, h = dim[0] - 1, dim[1] - 1
    b_cliff = arch.read_file("t3SyncCliffLevel")
    cliff = struct.unpack_from(f"<{w*h}H", b_cliff, len(b_cliff) - 2*w*h)
    b_pnp = arch.read_file("CellAttribute_Pnp")
    pnp = b_pnp[len(b_pnp) - w*h:]
    b_cda = arch.read_file("CellAttribute_Cda")
    cda = b_cda[len(b_cda) - w*h:] if b_cda else bytes(w*h)
    height = bytes(min(255, 64 + (cliff[i] // 64) * 16) for i in range(w * h))

    oroot = ET.fromstring(arch.read_file("Objects"))
    starts, mins, geysers = [], [], []
    for p in oroot.findall(".//ObjectPoint"):
        if p.attrib.get("Type") == "StartLoc":
            x, y = [float(v) for v in p.attrib["Position"].split(",")[:2]]
            starts.append((x, y))
    for u in oroot.findall(".//ObjectUnit"):
        ut = u.attrib.get("UnitType", "")
        pos = u.attrib.get("Position", "")
        if not pos: continue
        x, y = [float(v) for v in pos.split(",")[:2]]
        if "Mineral" in ut: mins.append((x, y, "m"))
        elif "Vespene" in ut or "Geyser" in ut: geysers.append((x, y, "g"))

    res_blk = bytearray(w * h)
    for rx, ry, kind in mins + geysers:
        hw, hh = (1.0, 0.5) if kind == "m" else (1.5, 1.5)
        for dy in range(int(math.floor(ry - hh)), int(math.ceil(ry + hh))):
            for dx in range(int(math.floor(rx - hw)), int(math.ceil(rx + hw))):
                if 0 <= dx < w and 0 <= dy < h:
                    res_blk[dy*w + dx] = 1

    # Cluster resources into expansion bases and pick closest BFS ground natural per start
    clusters = []
    for r in mins + geysers:
        hit = [cl for cl in clusters if any((r[0]-x)**2 + (r[1]-y)**2 <= 100 for x, y, _ in cl)]
        if not hit: clusters.append([r])
        else:
            hit[0].append(r)
            for other in hit[1:]:
                hit[0].extend(other)
                clusters.remove(other)

    def make_grids(thresh):
        wk = bytearray(w * h)
        pl = bytearray(w * h)
        for y in range(h):
            for x in range(w):
                i = y*w + x
                c = cliff[i]
                if c == 0 or res_blk[i]: continue
                below = False
                if c % 64 == 0:
                    for dx, dy in ((1,0),(-1,0),(0,1),(0,-1)):
                        nx2, ny2 = x+dx, y+dy
                        if 0 <= nx2 < w and 0 <= ny2 < h:
                            nc = cliff[ny2*w + nx2]
                            if nc > c and (nc - c) >= 64 and nc % 64 == 0:
                                below = True; break
                if pnp[i] < thresh and not below:
                    wk[i] = 1
                    if c % 64 == 0 and cda[i] == 0:
                        pl[i] = 1
        return wk, pl

    wk0, pl0 = make_grids(1)
    wk128, pl128 = make_grids(128)

    def th_ok(cx, cy, cl):
        x0, y0 = int(round(cx - 2.5)), int(round(cy - 2.5))
        if x0 < 0 or y0 < 0 or x0 + 5 > w or y0 + 5 > h: return False
        for yy in range(y0, y0 + 5):
            for xx in range(x0, x0 + 5):
                if not pl0[yy*w + xx]: return False
        for rx, ry, kind in cl:
            dx, dy = abs(cx - rx), abs(cy - ry)
            if kind == "m":
                if dx < 5.99 and dy < 5.49: return False
            else:
                if dx < 6.49 and dy < 6.49: return False
        return True

    base_centers = []
    for cl in clusters:
        if len(cl) < 6: continue
        mx = sum(x for x, _, _ in cl) / len(cl)
        my = sum(y for _, y, _ in cl) / len(cl)
        best = None
        for dy in range(-10, 11):
            for dx in range(-10, 11):
                cx = math.floor(mx) + dx + 0.5
                cy = math.floor(my) + dy + 0.5
                if th_ok(cx, cy, cl):
                    sc = sum(math.hypot(cx - rx, cy - ry) for rx, ry, _ in cl)
                    if best is None or sc < best[0]: best = (sc, cx, cy)
        if best: base_centers.append((best[1], best[2]))

    def bfs_dist(sx, sy):
        dist = [-1] * (w * h)
        s0 = int(sy) * w + int(sx)
        dist[s0] = 0
        q = collections.deque([s0])
        while q:
            u = q.popleft()
            du = dist[u]
            ux, uy = u % w, u // w
            for dx, dy in ((1,0),(-1,0),(0,1),(0,-1)):
                vx, vy = ux + dx, uy + dy
                if 0 <= vx < w and 0 <= vy < h:
                    v = vy * w + vx
                    if dist[v] == -1 and wk0[v]:
                        dist[v] = du + 1
                        q.append(v)
        return dist

    spawns = []
    for idx_s, (sx, sy) in enumerate(starts):
        ex, ey = starts[(idx_s + 1) % len(starts)]
        dm = bfs_dist(sx, sy)
        cands = sorted((dm[int(by)*w + int(bx)], bx, by)
                       for bx, by in base_centers
                       if math.hypot(bx - sx, by - sy) > 15.0 and dm[int(by)*w + int(bx)] > 0)
        spawns.append({"bx": sx, "by": sy, "nx": cands[0][1], "ny": cands[0][2], "ex": ex, "ey": ey})

    for key, wk, pl in (("pnp0", wk0, pl0), ("pnp128", wk128, pl128)):
        out[key].append({
            "name": entry["name"], "w": w, "h": h, "spawns": spawns,
            "walk": bytes(wk).hex(), "place": bytes(pl).hex(), "height": height.hex()
        })

print(json.dumps(out))
PY
     )
   (define json-str
     (with-output-to-string
       (lambda ()
         (system* py-exe "-c" extract-py))))
   (define extracted (string->jsexpr json-str))
   (define (hex->bytes s)
     (define n (quotient (string-length s) 2))
     (define bs (make-bytes n 0))
     (for ([i (in-range n)])
       (bytes-set! bs i (string->number (substring s (* 2 i) (+ (* 2 i) 2)) 16)))
     bs)
   (for ([mode (in-list '(pnp0 pnp128))])
     (define maps (hash-ref extracted mode))
     (define total 0)
     (define pvz-sealed 0)
     (define pvz-nat-locus 0)
     (define pvz-full 0)
     (define pvz-valid 0)
     (define pvz-pylon-ok 0)
     (define pvz-fast 0)
     (define wire-ok 0)
     (define pvp-sealed 0)
     (define ter-solved 0)
     (for ([m (in-list maps)])
       (define w (hash-ref m 'w))
       (define h (hash-ref m 'h))
       (define path (hex->bytes (hash-ref m 'walk)))
       (define place (hex->bytes (hash-ref m 'place)))
       (define height (hex->bytes (hash-ref m 'height)))
       (define mg (make-bytes-grids w h path place height))
       (for ([sp (in-list (hash-ref m 'spawns))])
         (set! total (add1 total))
         (define bx (hash-ref sp 'bx)) (define by (hash-ref sp 'by))
         (define nx (hash-ref sp 'nx)) (define ny (hash-ref sp 'ny))
         (define ex (hash-ref sp 'ex)) (define ey (hash-ref sp 'ey))
         (define t0 (current-inexact-milliseconds))
         (define r (solve-protoss-matchup-wall bx by nx ny 'Zerg #:map-grids mg #:enemy-x ex #:enemy-y ey))
         (define dt (- (current-inexact-milliseconds) t0))
         (define b-rects (wall-rects-with-nat r nx ny))
         (define d-rect (wall-door-rect r))
         (define open? (and r (full-map-4conn-reachable? w h path bx by ex ey b-rects)))
         (define plug? (and r d-rect (not (full-map-4conn-reachable? w h path bx by ex ey (cons d-rect b-rects)))))
         (when (and r (hash-ref r 'sealed? #f)) (set! pvz-sealed (add1 pvz-sealed)))
         (when (and r (eq? (hash-ref r 'locus #f) 'natural-choke)) (set! pvz-nat-locus (add1 pvz-nat-locus)))
         (when (and r (hash-ref r 'sealed? #f) open? plug?) (set! pvz-full (add1 pvz-full)))
         (when (and r (protoss-wall-valid-on-grids? r bx by nx ny mg)) (set! pvz-valid (add1 pvz-valid)))
         (when (and r (<= (wall-max-pylon-dist r) 6.25)) (set! pvz-pylon-ok (add1 pvz-pylon-ok)))
         (when (< dt 150.0) (set! pvz-fast (add1 pvz-fast)))
         (when (and r (verify-wire-exact-wall-slots r bx by nx ny)) (set! wire-ok (add1 wire-ok)))
         (define r-pvp (solve-protoss-matchup-wall bx by nx ny 'Protoss #:map-grids mg #:enemy-x ex #:enemy-y ey))
         (when (and r-pvp (hash-ref r-pvp 'sealed? #f)) (set! pvp-sealed (add1 pvp-sealed)))
         (define r-ter (solve-terran-ramp-wall bx by nx ny #:map-grids mg))
         (when (and r-ter (hash-ref r-ter 'grid-solved? #f)) (set! ter-solved (add1 ter-solved)))))
     (check-equal (format "l85-c38-~a-14-spawns-seen" mode) total 14)
     (check-equal (format "l85-c38-~a-pvz-sealed-14/14" mode) pvz-sealed total)
     (check-equal (format "l85-c38-~a-pvz-natural-choke-14/14" mode) pvz-nat-locus total)
     (check-equal (format "l85-c38-~a-pvz-full-map-sealed-14/14" mode) pvz-full total)
     (check-equal (format "l85-c38-~a-pvz-valid-on-grids-14/14" mode) pvz-valid total)
     (check-equal (format "l85-c38-~a-pvz-pylon-le-6.25-14/14" mode) pvz-pylon-ok total)
     (check-equal (format "l85-c38-~a-pvz-under-150ms-14/14" mode) pvz-fast total)
     (check-equal (format "l85-c38-~a-wire-exact-slots-14/14" mode) wire-ok total)
     (check-equal (format "l85-c38-~a-pvp-main-ramp-14/14" mode) pvp-sealed total)
     (check-equal (format "l85-c38-~a-terran-main-ramp-14/14" mode) ter-solved total))]
  [else
   (printf "[4/4] Local SC2 map pool not present; skipping offline 14-spawn audit.\n")])

(printf "\n=============================================================================\n")
(printf "l85-wide-wall-placement-test: ~a PASSED, ~a FAILED\n" pass-count fail-count)
(printf "=============================================================================\n")
(when (> fail-count 0) (exit 1))
