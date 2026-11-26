#lang racket/base

;; =============================================================================
;; Loop 82 Track A: Walling Perfection, Terran Ramp-Barracks Protection &
;; Multi-Worker Expansion-Block Clear Tests
;; =============================================================================

(require racket/list
         racket/match
         racket/math
         racket/set
         "../lib/sc2-game-constants.rkt"
         "../lib/sc2-placement.rkt"
         "../lib/plan/terran-addon-swap.rkt"
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
        (printf "FAIL [~a]:\n  actual:   ~s\n  expected: ~s\n" name actual expected))))

;; Helper: 4-connected BFS reachability on a map-grids hash with rectangular footprints blocked.
(define (grid-4conn-reachable? mgrids sx sy dx dy blocked-rects)
  (define w (hash-ref mgrids 'width))
  (define h (hash-ref mgrids 'height))
  (define pref (hash-ref mgrids 'pathing-ref))
  (define (blk? ix iy)
    (ormap (lambda (r)
             (match-define (list cx cy hw hh) r)
             (and (>= ix (exact-round (- cx hw))) (< ix (exact-round (+ cx hw)))
                  (>= iy (exact-round (- cy hh))) (< iy (exact-round (+ cy hh)))))
           blocked-rects))
  (define (ok? ix iy)
    (and (>= ix 0) (< ix w) (>= iy 0) (< iy h)
         (> (pref ix iy) 0)
         (not (blk? ix iy))))
  (define s (cons (exact-floor sx) (exact-floor sy)))
  (define t (cons (exact-floor dx) (exact-floor dy)))
  (and (ok? (car s) (cdr s))
       (ok? (car t) (cdr t))
       (let ([seen (make-hash)])
         (hash-set! seen s #t)
         (let loop ([q (list s)])
           (cond
             [(null? q) #f]
             [(equal? (car q) t) #t]
             [else
              (define u (car q))
              (define nxt
                (for/list ([d (in-list '((1 . 0) (-1 . 0) (0 . 1) (0 . -1)))]
                           #:do [(define p (cons (+ (car u) (car d)) (+ (cdr u) (cdr d))))]
                           #:when (and (ok? (car p) (cdr p)) (not (hash-has-key? seen p))))
                  (hash-set! seen p #t)
                  p))
              (loop (append (cdr q) nxt))])))))

(define (make-vec-grids w h pvec bvec hvec)
  (hash 'width w
        'height h
        'pathing-ref (lambda (x y) (if (and (>= x 0) (< x w) (>= y 0) (< y h)) (vector-ref pvec (+ (* y w) x)) 0))
        'placement-ref (lambda (x y) (if (and (>= x 0) (< x w) (>= y 0) (< y h)) (vector-ref bvec (+ (* y w) x)) 0))
        'height-ref (lambda (x y) (if (and (>= x 0) (< x w) (>= y 0) (< y h)) (vector-ref hvec (+ (* y w) x)) 0))))

;; =============================================================================
;; 1. Synthetic Main-Ramp Grid with SC2 Bottom-Left Vertex Cliff Bevel
;;    Tests west-facing (addon-clear=#t) & east-facing (addon-clear=#f) ramps!
;; =============================================================================
(printf "[1/7] Testing Terran main-ramp wall + vertex cliff-bevel + metadata exports...\n")

;; Build a realistic 120x120 map with high-ground main on the EAST (west-facing ramp -> addon inside)
;; and bottom-left vertex cliff bevel along the West lip of the high-ground plateau (`x = 58`).
(define (make-ramp-map #:east-facing? east-facing? #:with-vertex-bevel? [bevel? #t])
  (define w 120)
  (define h 120)
  (define pvec (make-vector (* w h) 0))
  (define bvec (make-vector (* w h) 0))
  (define hvec (make-vector (* w h) 112.0))
  (define (idx x y) (+ (* y w) x))
  (cond
    [(not east-facing?)
     ;; High ground on EAST: x in [58..100], y in [40..80]; Low ground on WEST: x in [15..52], y in [35..85]
     ;; 2-tile wide ramp at y in [59..60], x in [53..57]
     (for* ([y (in-range 40 81)] [x (in-range 58 101)])
       (vector-set! pvec (idx x y) 1)
       (vector-set! bvec (idx x y) 1)
       (vector-set! hvec (idx x y) 128.0))
     ;; SC2 vertex-heightmap cliff bevel: bottom-left vertex of west lip cells x=58 sits at low ground 112!
     (when bevel?
       (for ([y (in-range 40 81)])
         (vector-set! hvec (idx 58 y) 112.0)))
     ;; Unbuildable walkable rim strip along cliff interior edge (tests hg-plat BFS decoupling)
     (for ([y (in-range 55 58)])
       (vector-set! bvec (idx 58 y) 0))
     ;; Ramp strip (walkable, unbuildable, sloped height)
     (for* ([y (in-range 59 61)] [x (in-range 53 58)])
       (vector-set! pvec (idx x y) 1)
       (vector-set! bvec (idx x y) 0)
       (vector-set! hvec (idx x y) (+ 112.0 (* 3.0 (- x 52)))))
     ;; Low ground natural
     (for* ([y (in-range 35 86)] [x (in-range 15 53)])
       (vector-set! pvec (idx x y) 1)
       (vector-set! bvec (idx x y) 1)
       (vector-set! hvec (idx x y) 112.0))
     (values (make-vec-grids w h pvec bvec hvec) 78.5 60.5 36.5 60.5)]
    [else
     ;; High ground on WEST: x in [20..62], y in [40..80]; Low ground on EAST: x in [68..105], y in [35..85]
     ;; 2-tile wide east-facing ramp at y in [59..60], x in [63..67]
     ;; East cliff at x = 63..67 blocks the Barracks +2.5 East add-on slot!
     (for* ([y (in-range 40 81)] [x (in-range 20 63)])
       (vector-set! pvec (idx x y) 1)
       (vector-set! bvec (idx x y) 1)
       (vector-set! hvec (idx x y) 128.0))
     (for* ([y (in-range 59 61)] [x (in-range 63 68)])
       (vector-set! pvec (idx x y) 1)
       (vector-set! bvec (idx x y) 0)
       (vector-set! hvec (idx x y) (- 128.0 (* 3.0 (- x 62)))))
     (for* ([y (in-range 35 86)] [x (in-range 68 106)])
       (vector-set! pvec (idx x y) 1)
       (vector-set! bvec (idx x y) 1)
       (vector-set! hvec (idx x y) 112.0))
     (values (make-vec-grids w h pvec bvec hvec) 41.5 60.5 83.5 60.5)]))

(define-values (mg-west bx-w by-w nx-w ny-w) (make-ramp-map #:east-facing? #f #:with-vertex-bevel? #t))
(define tw-west (solve-terran-ramp-wall bx-w by-w nx-w ny-w #:map-grids mg-west))
(check-true "terran-west-bevel-grid-solved" (hash-ref tw-west 'grid-solved? #f))
(check-true "terran-west-bevel-addon-clear" (terran-wall-barracks-addon-clear? tw-west))
(define tw-west-rects
  (list (list (car (hash-ref tw-west 'depot-1)) (cdr (hash-ref tw-west 'depot-1)) 1.0 1.0)
        (list (car (hash-ref tw-west 'depot-2)) (cdr (hash-ref tw-west 'depot-2)) 1.0 1.0)
        (list (car (hash-ref tw-west 'barracks)) (cdr (hash-ref tw-west 'barracks)) 1.5 1.5)))
(check-true "terran-west-bevel-seals-zero-gap"
            (not (grid-4conn-reachable? mg-west bx-w by-w nx-w ny-w tw-west-rects)))
(check-true "terran-west-wall-barracks-slot-true"
            (terran-wall-barracks-slot? tw-west (car (hash-ref tw-west 'barracks)) (cdr (hash-ref tw-west 'barracks))))
(check-true "terran-west-wall-barracks-slot-false-far"
            (not (terran-wall-barracks-slot? tw-west (+ bx-w 8.0) (- by-w 8.0))))
(check-true "terran-west-seal-coord-depot1"
            (terran-wall-seal-coord? tw-west (car (hash-ref tw-west 'depot-1)) (cdr (hash-ref tw-west 'depot-1))))
(check-true "terran-west-addon-pad-buildable"
            (wall-barracks-addon-pad-buildable? (car (hash-ref tw-west 'barracks))
                                                (cdr (hash-ref tw-west 'barracks))
                                                mg-west))

;; East-facing ramp: Barracks at crest x=60.5 has add-on at x=63.0 (over unbuildable ramp/cliff -> addon-clear=#f)
(define-values (mg-east bx-e by-e nx-e ny-e) (make-ramp-map #:east-facing? #t))
(define tw-east (solve-terran-ramp-wall bx-e by-e nx-e ny-e #:map-grids mg-east))
(check-true "terran-east-grid-solved" (hash-ref tw-east 'grid-solved? #f))
(define tw-east-rects
  (append (list (list (car (hash-ref tw-east 'depot-1)) (cdr (hash-ref tw-east 'depot-1)) 1.0 1.0)
                (list (car (hash-ref tw-east 'depot-2)) (cdr (hash-ref tw-east 'depot-2)) 1.0 1.0)
                (list (car (hash-ref tw-east 'barracks)) (cdr (hash-ref tw-east 'barracks)) 1.5 1.5))
          (if (hash-ref tw-east 'seals-with-addon? #f)
              (list (list (car (hash-ref tw-east 'barracks-addon)) (cdr (hash-ref tw-east 'barracks-addon)) 1.0 1.0))
              '())))
(check-true "terran-east-seals-zero-gap"
            (not (grid-4conn-reachable? mg-east bx-e by-e nx-e ny-e tw-east-rects)))
(check-true "terran-east-wall-structure-coords-len3"
            (= (length (hash-ref tw-east 'wall-structure-coords '())) 3))
;; Confirm wall-barracks-addon-pad-buildable? returns #f directly on the cliff lip (61.5, 60.5)
(check-true "terran-east-cliff-lip-addon-pad-blocked"
            (not (wall-barracks-addon-pad-buildable? 61.5 60.5 mg-east)))

;; =============================================================================
;; 2. Protoss Main-Ramp Wall (PvP, PvT, vs Random) on Vertex-Bevel Ramp
;; =============================================================================
(printf "[2/7] Testing Protoss main-ramp wall (PvP/PvT/Random) on vertex-bevel ramp...\n")

(for ([opp (in-list '(Protoss Terran Random))])
  (define t0 (current-inexact-milliseconds))
  (define pw (solve-protoss-matchup-wall bx-w by-w nx-w ny-w opp
                                         #:map-grids mg-west #:enemy-x 10.5 #:enemy-y 60.5))
  (define dt (- (current-inexact-milliseconds) t0))
  (define p-rects
    (append (list (list (car (hash-ref pw 'pylon)) (cdr (hash-ref pw 'pylon)) 1.0 1.0)
                  (list (car (hash-ref pw 'slot-1)) (cdr (hash-ref pw 'slot-1)) 1.5 1.5)
                  (list (car (hash-ref pw 'slot-2)) (cdr (hash-ref pw 'slot-2)) 1.5 1.5))
            (if (hash-ref pw 'slot-3 #f)
                (list (list (car (hash-ref pw 'slot-3)) (cdr (hash-ref pw 'slot-3)) 1.5 1.5))
                '())))
  (define door-rect (list (hash-ref pw 'door-x) (hash-ref pw 'door-y) 0.5 0.5))
  (check-equal (format "protoss-main-~a-locus" opp) (hash-ref pw 'locus) 'main-ramp)
  (check-true  (format "protoss-main-~a-grid-solved" opp) (hash-ref pw 'grid-solved? #f))
  (check-true  (format "protoss-main-~a-sealed" opp) (hash-ref pw 'sealed? #f))
  (check-true  (format "protoss-main-~a-valid-on-grids" opp)
               (protoss-wall-valid-on-grids? pw bx-w by-w nx-w ny-w mg-west))
  (check-true  (format "protoss-main-~a-door-open-reachable" opp)
               (grid-4conn-reachable? mg-west bx-w by-w nx-w ny-w p-rects))
  (check-true  (format "protoss-main-~a-door-plugged-sealed" opp)
               (not (grid-4conn-reachable? mg-west bx-w by-w nx-w ny-w (cons door-rect p-rects))))
  (check-true  (format "protoss-main-~a-under-150ms" opp) (< dt 150.0)))

;; Random-initially opponent later revealed as Zerg stays locked to main-ramp
(define pw-rand-z (solve-protoss-matchup-wall bx-w by-w nx-w ny-w 'Zerg
                                              #:initial-enemy-race 'Random
                                              #:map-grids mg-west #:enemy-x 10.5 #:enemy-y 60.5))
(check-equal "protoss-random-revealed-zerg-stays-main-ramp" (hash-ref pw-rand-z 'locus) 'main-ramp)

;; =============================================================================
;; 3. Protoss Natural-Choke Wall (PvZ) with Dead-End Mineral Pocket Trap
;; =============================================================================
(printf "[3/7] Testing Protoss PvZ natural-choke wall (dead-end pocket rejection + 6t & 8t chokes)...\n")

(define (make-nat-choke-map choke-width)
  ;; 140x140 map:
  ;; - Main plateau on WEST: x in [12..34], y in [48..72], h=128
  ;; - Main ramp at x in [35..38], y in [59..60]
  ;; - Natural basin: x in [39..58], y in [49..72], h=112; Natural Nexus at (48.5, 60.5)
  ;; - Dead-end mineral pocket SOUTH of natural: narrow 4-tile neck at x in [46..49], y in [47..48],
  ;;   dead-end alcove y in [42..46], x in [43..54] (depth d<=20, dist<=18 — mimics real mineral pocket!)
  ;; - Real front natural choke EAST of natural: x in [59..61], exact width = choke-width (`10.5t` from nat!)
  ;; - Huge open map EAST of choke: x in [62..134], y in [20..105], h=112
  (define w 140)
  (define h 140)
  (define pvec (make-vector (* w h) 0))
  (define bvec (make-vector (* w h) 0))
  (define hvec (make-vector (* w h) 112.0))
  (define (idx x y) (+ (* y w) x))
  ;; Main plateau
  (for* ([y (in-range 48 73)] [x (in-range 12 35)])
    (vector-set! pvec (idx x y) 1)
    (vector-set! bvec (idx x y) 1)
    (vector-set! hvec (idx x y) 128.0))
  ;; Main ramp
  (for* ([y (in-range 59 61)] [x (in-range 35 39)])
    (vector-set! pvec (idx x y) 1)
    (vector-set! bvec (idx x y) 0)
    (vector-set! hvec (idx x y) (- 128.0 (* 3.2 (- x 34)))))
  ;; Natural basin
  (for* ([y (in-range 49 73)] [x (in-range 39 59)])
    (vector-set! pvec (idx x y) 1)
    (vector-set! bvec (idx x y) 1)
    (vector-set! hvec (idx x y) 112.0))
  ;; Dead-end mineral pocket SOUTH (reaches d=18..20, dist=16..18, closed at y=42!)
  (for* ([y (in-range 47 49)] [x (in-range 46 50)])
    (vector-set! pvec (idx x y) 1)
    (vector-set! bvec (idx x y) 1))
  (for* ([y (in-range 42 47)] [x (in-range 43 55)])
    (vector-set! pvec (idx x y) 1)
    (vector-set! bvec (idx x y) 1))
  ;; Front natural choke (exact width = choke-width)
  (define cy0 (- 60 (quotient choke-width 2)))
  (define cy1 (+ cy0 choke-width))
  (for* ([y (in-range cy0 cy1)] [x (in-range 59 62)])
    (vector-set! pvec (idx x y) 1)
    (vector-set! bvec (idx x y) 1))
  ;; Open outer map EAST
  (for* ([y (in-range 20 106)] [x (in-range 62 135)])
    (vector-set! pvec (idx x y) 1)
    (vector-set! bvec (idx x y) 1))
  (values (make-vec-grids w h pvec bvec hvec) 22.5 60.5 48.5 60.5 120.5 60.5))

(for ([cw (in-list '(6 8))])
  (define-values (mg bx by nx ny ex ey) (make-nat-choke-map cw))
  (define t0 (current-inexact-milliseconds))
  (define pnw (solve-protoss-matchup-wall bx by nx ny 'Zerg #:map-grids mg #:enemy-x ex #:enemy-y ey))
  (define dt (- (current-inexact-milliseconds) t0))
  (define rects
    (list (list nx ny 2.5 2.5)
          (list (car (hash-ref pnw 'pylon)) (cdr (hash-ref pnw 'pylon)) 1.0 1.0)
          (list (car (hash-ref pnw 'slot-1)) (cdr (hash-ref pnw 'slot-1)) 1.5 1.5)
          (list (car (hash-ref pnw 'slot-2)) (cdr (hash-ref pnw 'slot-2)) 1.5 1.5)))
  (define door-r (list (hash-ref pnw 'door-x) (hash-ref pnw 'door-y) 0.5 0.5))
  (check-equal (format "pvz-nat-cw~a-locus" cw) (hash-ref pnw 'locus) 'natural-choke)
  (check-equal (format "pvz-nat-cw~a-slot3-false" cw) (hash-ref pnw 'slot-3 'unset) #f)
  (check-true  (format "pvz-nat-cw~a-grid-solved" cw) (hash-ref pnw 'grid-solved? #f))
  (check-true  (format "pvz-nat-cw~a-sealed" cw) (hash-ref pnw 'sealed? #f))
  (check-true  (format "pvz-nat-cw~a-valid-on-grids" cw)
               (protoss-wall-valid-on-grids? pnw bx by nx ny mg))
  (check-true  (format "pvz-nat-cw~a-ignored-deadend-pocket" cw) (> (hash-ref pnw 'door-x) 55.0))
  (check-true  (format "pvz-nat-cw~a-door-open-reachable" cw)
               (grid-4conn-reachable? mg 41.5 60.5 95.5 60.5 rects))
  (check-true  (format "pvz-nat-cw~a-door-plugged-sealed" cw)
               (not (grid-4conn-reachable? mg 41.5 60.5 95.5 60.5 (cons door-r rects))))
  (check-true  (format "pvz-nat-cw~a-under-150ms" cw) (< dt 150.0)))

;; =============================================================================
;; 4. Zerg ZvZ Natural-Choke Wall Solver (`solve-zerg-natural-wall`)
;; =============================================================================
(printf "[4/7] Testing Zerg ZvZ natural-choke wall solver (6t & 8t chokes + analytical fallback)...\n")

(for ([cw (in-list '(6 8))])
  (define-values (mg bx by nx ny ex ey) (make-nat-choke-map cw))
  (define t0 (current-inexact-milliseconds))
  (define znw (solve-zerg-natural-wall bx by nx ny #:map-grids mg #:enemy-x ex #:enemy-y ey))
  (define dt (- (current-inexact-milliseconds) t0))
  (define z-rects
    (append (list (list nx ny 2.5 2.5)
                  (list (car (hash-ref znw 'roach-warren)) (cdr (hash-ref znw 'roach-warren)) 1.5 1.5)
                  (list (car (hash-ref znw 'evolution-chamber)) (cdr (hash-ref znw 'evolution-chamber)) 1.5 1.5))
            (if (hash-ref znw 'slot-3 #f)
                (list (list (car (hash-ref znw 'slot-3)) (cdr (hash-ref znw 'slot-3)) 1.5 1.5))
                '())))
  (define door-r (list (hash-ref znw 'door-x) (hash-ref znw 'door-y) 0.5 0.5))
  (check-equal (format "zvz-nat-cw~a-locus" cw) (hash-ref znw 'locus) 'natural-choke)
  (check-equal (format "zvz-nat-cw~a-no-pylon" cw) (hash-ref znw 'pylon #f) #f)
  (check-true  (format "zvz-nat-cw~a-grid-solved" cw) (hash-ref znw 'grid-solved? #f))
  (check-true  (format "zvz-nat-cw~a-sealed" cw) (hash-ref znw 'sealed? #f))
  (check-true  (format "zvz-nat-cw~a-door-open-reachable" cw)
               (grid-4conn-reachable? mg 41.5 60.5 95.5 60.5 z-rects))
  (check-true  (format "zvz-nat-cw~a-door-plugged-sealed" cw)
               (not (grid-4conn-reachable? mg 41.5 60.5 95.5 60.5 (cons door-r z-rects))))
  (check-true  (format "zvz-nat-cw~a-under-150ms" cw) (< dt 150.0)))

(define znw-ana (solve-zerg-natural-wall 22.5 60.5 48.5 60.5 #:enemy-x 120.5 #:enemy-y 60.5))
(check-true "zvz-nat-analytical-has-rw-evo-door"
            (and (pair? (hash-ref znw-ana 'roach-warren #f))
                 (pair? (hash-ref znw-ana 'evolution-chamber #f))
                 (pair? (hash-ref znw-ana 'door #f))
                 (not (hash-ref znw-ana 'grid-solved? #t))))

;; =============================================================================
;; 5. Terran Bug T1 Secondary Leak: `plan-terran-addon-swap` Wall-Barracks Guard
;; =============================================================================
(printf "[5/7] Testing plan-terran-addon-swap ramp-wall Barracks protection...\n")

(define sample-rw (hash 'barracks (cons 50.5 50.5) 'depot-1 (cons 48.0 52.0) 'depot-2 (cons 53.0 48.0) 'addon-clear? #t))
(define wall-depots-2
  (list (hash 'id 101 'type 'supply-depot 'x 48.0 'y 52.0 'build-progress 1.0)
        (hash 'id 102 'type 'supply-depot 'x 53.0 'y 48.0 'build-progress 1.0)))

;; 5a. Case 1: Bare ramp-wall Barracks MUST NOT lift to claim an orphaned free add-on!
(define swap-case1-blocked
  (plan-terran-addon-swap
   (hash 'frame 3200 'base-x 35.0 'base-y 45.0
         'terran-ramp-wall sample-rw
         'ally-buildings (append wall-depots-2
                                 (list (hash 'id 201 'type 'barracks 'x 50.5 'y 50.5 'build-progress 1.0 'order-count 0)
                                       (hash 'id 299 'type 'reactor 'x 42.0 'y 42.0 'build-progress 1.0)))
         'enemy-units '())))
(check-equal "terran-swap-case1-never-lifts-bare-wall-rax" swap-case1-blocked '())

;; 5b. Case 2: Ramp-wall Barracks donor MUST NOT lift for a Starport (non-Factory) while unbacked!
(define swap-case2-starport-blocked
  (plan-terran-addon-swap
   (hash 'frame 4600 'base-x 35.0 'base-y 45.0
         'terran-ramp-wall sample-rw
         'ally-buildings (append wall-depots-2
                                 (list (hash 'id 201 'type 'barracks 'x 50.5 'y 50.5 'build-progress 1.0 'add-on-tag 202)
                                       (hash 'id 202 'type 'barracks-reactor 'x 53.0 'y 50.0 'build-progress 1.0)
                                       (hash 'id 203 'type 'starport 'x 36.5 'y 45.5 'build-progress 1.0)))
         'enemy-units '())))
(check-equal "terran-swap-case2-blocks-wall-rax-for-starport" swap-case2-starport-blocked '())

;; 5c. Case 2 FactorySwap ABORTS when enemy combat unit is 21t from wall Barracks (outside 18t base radius!)
;;     even when the waiting recipient Factory sits 4t behind the ramp Barracks!
(define swap-case2-threat21-blocked
  (plan-terran-addon-swap
   (hash 'frame 4650 'base-x 35.0 'base-y 45.0
         'terran-ramp-wall sample-rw
         'ally-buildings (append wall-depots-2
                                 (list (hash 'id 201 'type 'barracks 'x 50.5 'y 50.5 'build-progress 1.0 'add-on-tag 202)
                                       (hash 'id 202 'type 'barracks-reactor 'x 53.0 'y 50.0 'build-progress 1.0)
                                       (hash 'id 204 'type 'factory 'x 46.5 'y 50.5 'build-progress 1.0)))
         'enemy-units (list (hash 'id 9001 'type 'zergling 'x 70.5 'y 50.5 'hp 35)))))
(check-equal "terran-swap-case2-aborts-factoryswap-within-24t-of-wall" swap-case2-threat21-blocked '())

;; 5d. Case 2 FactorySwap ALLOWED when 0 threats within 24t of wall Barracks!
(define swap-case2-peace-allowed
  (plan-terran-addon-swap
   (hash 'frame 4700 'base-x 35.0 'base-y 45.0
         'terran-ramp-wall sample-rw
         'ally-buildings (append wall-depots-2
                                 (list (hash 'id 201 'type 'barracks 'x 50.5 'y 50.5 'build-progress 1.0 'add-on-tag 202)
                                       (hash 'id 202 'type 'barracks-reactor 'x 53.0 'y 50.0 'build-progress 1.0)
                                       (hash 'id 204 'type 'factory 'x 46.5 'y 50.5 'build-progress 1.0)))
         'enemy-units '())))
(check-true "terran-swap-case2-allows-factoryswap-in-peace"
            (and (pair? swap-case2-peace-allowed)
                 (equal? (first swap-case2-peace-allowed) '(terran-addon-swap 201 204 53.0 50.0))))

;; 5e. Non-wall Barracks #2 is strictly preferred over ramp-wall Barracks #1 as donor!
(define swap-prefers-nonwall
  (plan-terran-addon-swap
   (hash 'frame 100 ; reset anti-thrash tables cleanly
         'base-x 35.0 'base-y 45.0
         'ally-buildings '())))
(define swap-prefers-nonwall-2
  (plan-terran-addon-swap
   (hash 'frame 4800 'base-x 35.0 'base-y 45.0
         'terran-ramp-wall sample-rw
         'ally-buildings (append wall-depots-2
                                 (list (hash 'id 201 'type 'barracks 'x 50.5 'y 50.5 'build-progress 1.0 'add-on-tag 202)
                                       (hash 'id 202 'type 'barracks-reactor 'x 53.0 'y 50.0 'build-progress 1.0)
                                       (hash 'id 205 'type 'barracks 'x 36.5 'y 38.5 'build-progress 1.0 'add-on-tag 206)
                                       (hash 'id 206 'type 'barracks-reactor 'x 39.0 'y 38.0 'build-progress 1.0)
                                       (hash 'id 204 'type 'factory 'x 42.5 'y 42.5 'build-progress 1.0)))
         'enemy-units '())))
(check-true "terran-swap-prefers-nonwall-rax-over-wall-rax"
            (and (pair? swap-prefers-nonwall-2)
                 (equal? (first swap-prefers-nonwall-2) '(terran-addon-swap 205 204 39.0 38.0))))

;; 5f. 3rd Supply Depot backup seal unlocks wall-Barracks lift even for Starport!
(define swap-3rd-depot-unlocks
  (plan-terran-addon-swap
   (hash 'frame 100 'base-x 35.0 'base-y 45.0 'ally-buildings '())))
(define swap-3rd-depot-acts
  (plan-terran-addon-swap
   (hash 'frame 4850 'base-x 35.0 'base-y 45.0
         'terran-ramp-wall sample-rw
         'ally-buildings (append wall-depots-2
                                 (list (hash 'id 103 'type 'supply-depot 'x 50.0 'y 47.0 'build-progress 1.0)
                                       (hash 'id 201 'type 'barracks 'x 50.5 'y 50.5 'build-progress 1.0 'add-on-tag 202)
                                       (hash 'id 202 'type 'barracks-reactor 'x 53.0 'y 50.0 'build-progress 1.0)
                                       (hash 'id 203 'type 'starport 'x 36.5 'y 45.5 'build-progress 1.0)))
         'enemy-units '())))
(check-true "terran-swap-3rd-depot-unlocks-wall-rax"
            (and (pair? swap-3rd-depot-acts)
                 (equal? (first swap-3rd-depot-acts) '(terran-addon-swap 201 203 53.0 50.0))))

;; 5g. Pure geometry fallback (no 'terran-ramp-wall key, flanked by 2 depots) STILL protects wall Barracks!
(define swap-geom-fallback
  (plan-terran-addon-swap
   (hash 'frame 100 'base-x 35.0 'base-y 45.0 'ally-buildings '())))
(define swap-geom-fallback-blocked
  (plan-terran-addon-swap
   (hash 'frame 4860 'base-x 35.0 'base-y 45.0
         'ally-buildings (append wall-depots-2
                                 (list (hash 'id 201 'type 'barracks 'x 50.5 'y 50.5 'build-progress 1.0 'add-on-tag 202)
                                       (hash 'id 202 'type 'barracks-reactor 'x 53.0 'y 50.0 'build-progress 1.0)
                                       (hash 'id 203 'type 'starport 'x 36.5 'y 45.5 'build-progress 1.0)))
         'enemy-units '())))
(check-equal "terran-swap-pure-geometry-fallback-protects-wall-rax" swap-geom-fallback-blocked '())

;; =============================================================================
;; 6. Terran Bug T1 Primary Wire Guard (`lib/sc2-protobuf-ws.rkt`)
;; =============================================================================
(printf "[6/7] Testing sc2-protobuf-ws wall-Barracks add-on non-lift guard...\n")

(define (mk-unit tag utype alliance x y
                 #:bp [bp 1.0] #:orders [orders '()] #:addon [addon 0] #:flying? [fl? #f])
  (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 2)
            (sc2-point3d x y 8.0) 0.0 1.0 bp 0 #f #f #f
            100.0 100.0 0.0 0.0 0.0 200.0
            0 0
            fl? #f #f #t #f
            orders addon '() 0 0 0.0 0 0 0 0))

(define (mk-obs loop units)
  (sc2-observation loop
                   (sc2-player-common 1 500 200 20 30 0 0 0 0 0 0)
                   units '() '() #f '() '() '() '() '() '()))

(define (filter-addon-cmds cmds)
  (filter (lambda (c)
            (and (sc2-raw-unit-command? c)
                 (memv (sc2-raw-unit-command-ability-id c) '(421 422 454 455 487 488 3682 3683))))
          cmds))

;; 6a. Ramp-wall Barracks (#301 at 50.5,50.5 flanked by 2 Depots at 48,52 and 53,50 — note depot #303 blocks +2.5,-0.5!)
;;     MUST NOT emit a relocation point / auto-lift for `barracks-reactor`!
(define wall-rax-blocked-obs
  (mk-obs 2600
          (list (mk-unit 100 18 1 35.5 45.5) ; Command Center
                (mk-unit 301 21 1 50.5 50.5) ; Wall Barracks
                (mk-unit 302 19 1 48.0 52.0) ; Depot 1 (wall)
                (mk-unit 303 19 1 53.0 50.0)))) ; Depot 2 (blocks East addon slot 53.0,50.0!)
(define wall-addon-cmds
  (filter-addon-cmds
   (translate-bot-actions->sc2-raw-commands '((build barracks-reactor 50.5 50.5)) wall-rax-blocked-obs)))
(check-equal "wire-wall-rax-blocked-addon-emits-zero-reloc-lift" wall-addon-cmds '())

;; 6b. When BOTH a ramp-wall Barracks (#301, clear) AND an interior Barracks (#305, clear) exist,
;;     wire prefers interior Barracks #305 ahead of ramp-wall Barracks #301!
(define wall-and-interior-obs
  (mk-obs 2700
          (list (mk-unit 100 18 1 35.5 45.5) ; Command Center
                (mk-unit 301 21 1 50.5 50.5) ; Wall Barracks (listed FIRST!)
                (mk-unit 302 19 1 48.0 52.0) ; Depot 1
                (mk-unit 303 19 1 48.0 48.0) ; Depot 2 (west side, so #301 East slot is clear)
                (mk-unit 305 21 1 34.5 38.5)))) ; Interior Barracks #2
(define prefer-int-cmds
  (filter-addon-cmds
   (translate-bot-actions->sc2-raw-commands '((build barracks-reactor 34.5 38.5)) wall-and-interior-obs)))
(check-true "wire-prefers-interior-rax-over-wall-rax"
            (and (= (length prefer-int-cmds) 1)
                 (equal? (sc2-raw-unit-command-unit-tags (first prefer-int-cmds)) '(305))
                 (not (sc2-raw-unit-command-target-pos (first prefer-int-cmds)))))

;; 6c. Non-wall interior Barracks (#305) with blocked East slot STILL relocates cleanly!
(define nonwall-blocked-obs
  (mk-obs 2800
          (list (mk-unit 100 18 1 35.5 45.5)
                (mk-unit 305 21 1 38.5 38.5)
                (mk-unit 306 19 1 41.0 38.0)))) ; Only 1 depot blocking East -> NOT a 2-depot ramp wall
(define nonwall-reloc-cmds
  (filter-addon-cmds
   (translate-bot-actions->sc2-raw-commands '((build barracks-reactor 38.5 38.5)) nonwall-blocked-obs)))
(check-true "wire-nonwall-blocked-rax-still-relocates"
            (and (= (length nonwall-reloc-cmds) 1)
                 (equal? (sc2-raw-unit-command-unit-tags (first nonwall-reloc-cmds)) '(305))
                 (sc2-point2d? (sc2-raw-unit-command-target-pos (first nonwall-reloc-cmds)))))

;; =============================================================================
;; 7. Multi-Worker `clear-expansion-block` (`lib/sc2-protobuf-ws.rkt`)
;; =============================================================================
(printf "[7/7] Testing multi-worker clear-expansion-block (worker/pylon/ebay + PV8 builder guard)...\n")

(define (make-worker-obs loop n-workers blocker-u #:builder-idx [b-idx -1])
  (define th (mk-unit 100 86 1 32.5 32.5)) ; Hatchery
  (define ws
    (for/list ([i (in-range n-workers)])
      (define orders
        (if (= i b-idx)
            (list (sc2-unit-order 1152 (sc2-point3d 48.5 32.5 8.0) 0 0.0)) ; ZERGBUILD_HATCHERY
            '()))
      (mk-unit (+ 500 i) 104 1 (+ 30.0 (* 0.5 i)) 34.0 #:orders orders)))
  (mk-obs loop (append (list th blocker-u) ws)))

;; 7a. Enemy Probe block -> pulls 2 workers (and excludes active builder #500!)
(define blk-probe (mk-unit 9101 84 4 50.5 32.5))
(define obs-probe (make-worker-obs 1400 14 blk-probe #:builder-idx 0))
(define cmds-probe
  (translate-bot-actions->sc2-raw-commands '((clear-expansion-block 9101 50.5 32.5)) obs-probe))
(check-true "clear-block-probe-pulls-2-workers-no-builder"
            (and (= (length cmds-probe) 1)
                 (= (sc2-raw-unit-command-ability-id (first cmds-probe)) 23)
                 (= (sc2-raw-unit-command-target-unit-tag (first cmds-probe)) 9101)
                 (= (length (sc2-raw-unit-command-unit-tags (first cmds-probe))) 2)
                 (not (memv 500 (sc2-raw-unit-command-unit-tags (first cmds-probe))))))

;; 7b. Enemy Pylon block with 14 workers -> pulls 3 workers!
(define blk-pylon (mk-unit 9102 60 4 50.5 32.5 #:bp 0.35))
(define obs-pylon-14 (make-worker-obs 1500 14 blk-pylon))
(define cmds-pylon-14
  (translate-bot-actions->sc2-raw-commands '((clear-expansion-block 9102 50.5 32.5)) obs-pylon-14))
(check-equal "clear-block-pylon-14w-pulls-3"
             (and (= (length cmds-pylon-14) 1)
                  (length (sc2-raw-unit-command-unit-tags (first cmds-pylon-14))))
             3)

;; 7c. Enemy Pylon block with 18 workers -> pulls 4 workers!
(define obs-pylon-18 (make-worker-obs 1600 18 blk-pylon))
(define cmds-pylon-18
  (translate-bot-actions->sc2-raw-commands '((clear-expansion-block 9102 50.5 32.5)) obs-pylon-18))
(check-equal "clear-block-pylon-18w-pulls-4"
             (and (= (length cmds-pylon-18) 1)
                  (length (sc2-raw-unit-command-unit-tags (first cmds-pylon-18))))
             4)

;; 7d. Enemy Engineering Bay (850 HP) block with 18 workers -> pulls 2 workers (NOT 4)!
(define blk-ebay (mk-unit 9103 22 4 50.5 32.5 #:bp 0.40))
(define obs-ebay-18 (make-worker-obs 1700 18 blk-ebay))
(define cmds-ebay-18
  (translate-bot-actions->sc2-raw-commands '((clear-expansion-block 9103 50.5 32.5)) obs-ebay-18))
(check-equal "clear-block-ebay-18w-pulls-2"
             (and (= (length cmds-ebay-18) 1)
                  (length (sc2-raw-unit-command-unit-tags (first cmds-ebay-18))))
             2)

;; 7e. Eco floor: with 10 workers vs Pylon, keeps >= 8 mining -> pulls at most 2!
(define obs-pylon-10 (make-worker-obs 1800 10 blk-pylon))
(define cmds-pylon-10
  (translate-bot-actions->sc2-raw-commands '((clear-expansion-block 9102 50.5 32.5)) obs-pylon-10))
(check-equal "clear-block-pylon-10w-eco-floor-pulls-2"
             (and (= (length cmds-pylon-10) 1)
                  (length (sc2-raw-unit-command-unit-tags (first cmds-pylon-10))))
             2)

;; =============================================================================
;; 8. Loop 82B: Protoss Live Wall Wire Placement (`'doorway-corridor` Strip +
;;    0.0 Spacing + Nexus-Adjacent Clearance) & Wide-Natural Pass-1 `slot-3`
;; =============================================================================
(printf "[8/8] Testing Loop 82B Protoss wire wall-slot acceptance & Pass-1 wide natural slot-3...\n")

;; 8a. Door-adjacent Protoss wall slots (pylon + slot-1 + slot-2) MUST land at EXACT coordinates
;;     even when 1.2x1.2 `'doorway-corridor` AABBs sit on `door` and `door-park`!
(define pwall-reserved
  (list (reserved-aabb 51.0 136.0 1.0 1.0 'wall-slot 0 0)         ; pylon
        (reserved-aabb 55.5 137.5 1.5 1.5 'wall-slot 0 0)         ; slot-1 (touches door at dist 2.0!)
        (reserved-aabb 52.5 141.5 1.5 1.5 'wall-slot 0 0)         ; slot-2 (touches door at dist 2.0!)
        (reserved-aabb 54.5 139.5 1.2 1.2 'doorway-corridor 0 0)  ; door (bloated 1.2x1.2!)
        (reserved-aabb 52.94 137.94 1.2 1.2 'doorway-corridor 0 0))) ; door-park (overlaps pylon @ 1.94!)
(define pwall-nex (mk-unit 700 59 1 37.5 145.5)) ; Main Nexus
(define pwall-pyl-pt
  (find-verified-building-placement #f 881 51.0 136.0 (list pwall-nex)
                                    #:min-spacing 0.0
                                    #:reserved-aabbs pwall-reserved
                                    #:bldg-sym 'pylon))
(check-true "wire-l82b-protoss-wall-pylon-exact-despite-doorway-corridor"
            (and (sc2-point2d? pwall-pyl-pt)
                 (= (sc2-point2d-x pwall-pyl-pt) 51.0)
                 (= (sc2-point2d-y pwall-pyl-pt) 136.0)))

(define pwall-pyl-u (mk-unit 701 60 1 51.0 136.0))
(define pwall-s1-pt
  (find-verified-building-placement #f 883 55.5 137.5 (list pwall-nex pwall-pyl-u)
                                    #:min-spacing 0.0
                                    #:reserved-aabbs pwall-reserved
                                    #:bldg-sym 'gateway))
(check-true "wire-l82b-protoss-wall-slot1-exact-despite-doorway-corridor"
            (and (sc2-point2d? pwall-s1-pt)
                 (= (sc2-point2d-x pwall-s1-pt) 55.5)
                 (= (sc2-point2d-y pwall-s1-pt) 137.5)))

(define pwall-gw-u (mk-unit 702 62 1 55.5 137.5))
(define pwall-s2-pt
  (find-verified-building-placement #f 894 52.5 141.5 (list pwall-nex pwall-pyl-u pwall-gw-u)
                                    #:min-spacing 0.0
                                    #:reserved-aabbs pwall-reserved
                                    #:bldg-sym 'cybernetics-core))
(check-true "wire-l82b-protoss-wall-slot2-exact-despite-doorway-corridor"
            (and (sc2-point2d? pwall-s2-pt)
                 (= (sc2-point2d-x pwall-s2-pt) 52.5)
                 (= (sc2-point2d-y pwall-s2-pt) 141.5)))

;; 8b. Non-wall interior building (RoboticsFacility) MUST still obey `'doorway-corridor` and NOT plug door!
(define pwall-robo-pt
  (find-verified-building-placement #f 893 54.5 139.5 (list pwall-nex pwall-pyl-u pwall-gw-u)
                                    #:min-spacing 2.0
                                    #:reserved-aabbs pwall-reserved
                                    #:bldg-sym 'robotics-facility))
(check-true "wire-l82b-nonwall-robo-respects-doorway-corridor"
            (and (sc2-point2d? pwall-robo-pt)
                 (>= (max (abs (- (sc2-point2d-x pwall-robo-pt) 54.5))
                          (abs (- (sc2-point2d-y pwall-robo-pt) 139.5)))
                     2.65)))

;; 8c. Natural-choke wall slot touching the 5x5 Natural Nexus (center-to-center 4.0t < 4.5t) is ACCEPTED!
(define nat-touch-reserved
  (list (reserved-aabb 52.5 60.5 1.5 1.5 'wall-slot 0 0)
        (reserved-aabb 54.5 60.5 0.5 0.5 'doorway-corridor 0 0)))
(define nat-touch-pyl (mk-unit 710 60 1 48.0 64.0))
(define nat-touch-pt
  (find-verified-building-placement #f 883 52.5 60.5 (list pwall-nex nat-touch-pyl)
                                    #:min-spacing 0.0
                                    #:reserved-aabbs nat-touch-reserved
                                    #:expansion-pads (list (cons 48.5 60.5))
                                    #:bldg-sym 'gateway))
(check-true "wire-l82b-nat-wall-slot-touching-nexus-4t-accepted"
            (and (sc2-point2d? nat-touch-pt)
                 (= (sc2-point2d-x nat-touch-pt) 52.5)
                 (= (sc2-point2d-y nat-touch-pt) 60.5)))

;; 8d. End-to-end translate-bot-actions->sc2-raw-commands places Gateway at exact wall slot with 0.0 spacing!
(define pwall-probe (mk-unit 703 84 1 45.0 140.0))
(define pwall-obs (mk-obs 1200 (list pwall-nex pwall-pyl-u pwall-probe)))
(define pwall-cmds
  (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 883)))
          (translate-bot-actions->sc2-raw-commands '((build gateway 55.5 137.5))
                                                   pwall-obs
                                                   #:reserved-aabbs pwall-reserved)))
(check-true "wire-l82b-translate-gateway-wall-slot-exact"
            (and (= (length pwall-cmds) 1)
                 (let ([tp (sc2-raw-unit-command-target-pos (first pwall-cmds))])
                   (and (sc2-point2d? tp)
                        (= (sc2-point2d-x tp) 55.5)
                        (= (sc2-point2d-y tp) 137.5)))))

;; 8e. Wide 10-tile natural choke on full-size elevated map (140x140) auto-enables Pass-1 `slot-3` and SEALS!
(define-values (mg-10 bx10 by10 nx10 ny10 ex10 ey10) (make-nat-choke-map 10))
(define t10-0 (current-inexact-milliseconds))
(define pnw-10 (solve-protoss-matchup-wall bx10 by10 nx10 ny10 'Zerg #:map-grids mg-10 #:enemy-x ex10 #:enemy-y ey10))
(define dt10 (- (current-inexact-milliseconds) t10-0))
(define pnw-10-rects
  (append (list (list nx10 ny10 2.5 2.5)
                (list (car (hash-ref pnw-10 'pylon)) (cdr (hash-ref pnw-10 'pylon)) 1.0 1.0)
                (list (car (hash-ref pnw-10 'slot-1)) (cdr (hash-ref pnw-10 'slot-1)) 1.5 1.5)
                (list (car (hash-ref pnw-10 'slot-2)) (cdr (hash-ref pnw-10 'slot-2)) 1.5 1.5))
          (if (hash-ref pnw-10 'slot-3 #f)
              (list (list (car (hash-ref pnw-10 'slot-3)) (cdr (hash-ref pnw-10 'slot-3)) 1.5 1.5))
              '())))
(define pnw-10-door (list (hash-ref pnw-10 'door-x) (hash-ref pnw-10 'door-y) 0.5 0.5))
(check-equal "l82b-pvz-wide10-locus" (hash-ref pnw-10 'locus) 'natural-choke)
(check-true  "l82b-pvz-wide10-slot3-populated" (pair? (hash-ref pnw-10 'slot-3 #f)))
(check-true  "l82b-pvz-wide10-sealed" (hash-ref pnw-10 'sealed? #f))
(check-true  "l82b-pvz-wide10-valid-on-grids" (protoss-wall-valid-on-grids? pnw-10 bx10 by10 nx10 ny10 mg-10))
(check-true  "l82b-pvz-wide10-door-open-reachable"
             (grid-4conn-reachable? mg-10 41.5 60.5 95.5 60.5 pnw-10-rects))
(check-true  "l82b-pvz-wide10-door-plugged-sealed"
             (not (grid-4conn-reachable? mg-10 41.5 60.5 95.5 60.5 (cons pnw-10-door pnw-10-rects))))
(check-true  "l82b-pvz-wide10-under-150ms" (< dt10 150.0))

(printf "\n=============================================================================\n")
(printf "l82-walling-placement-test: ~a PASSED, ~a FAILED\n" pass-count fail-count)
(printf "=============================================================================\n")
(when (> fail-count 0) (exit 1))
