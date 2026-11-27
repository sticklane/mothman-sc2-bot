#lang racket/base

;; =============================================================================
;; `lib/plan/nydus.rkt`
;; Symmetric Zerg Nydus Network / Nydus Worm Offense <-> Counter-Nydus Plans
;;
;; Layering invariant: imports ONLY `"../sc2-geometry.rkt"`,
;; `"../sc2-game-constants.rkt"`, and `"../sc2-common.rkt"` (plus `racket/*`).
;; Never imports `sc2-placement.rkt`, `tactics-sim.rkt`, or `static-defense.rkt`.
;;
;; Symmetric Pair (Offense <-> Counter):
;;   `plan-nydus-worm-tactics` <-> `plan-counter-nydus-worm-tactics`
;; Unified Orchestrator:
;;   `plan-nydus-actions`
;; =============================================================================

(require racket/list
         racket/math
         racket/flonum
         racket/fixnum
         racket/set
         "../sc2-common.rkt"
         (except-in "../sc2-geometry.rkt" point2d aabb2d)
         (except-in "../sc2-game-constants.rkt" aabb-overlaps?))

(provide
 plan-nydus-worm-tactics
 plan-counter-nydus-worm-tactics
 plan-nydus-actions)

;; -----------------------------------------------------------------------------
;; 1. Fast Cached Observation, Index & Geometry Helpers (Zero Contract Churn)
;; -----------------------------------------------------------------------------

(define *missing* (gensym 'missing))
(define *canon-unit-cache* (make-hasheq))
(define *canon-struct-cache* (make-hasheq))
(define *flying-sym-cache* (make-hasheq))
(define *noncombat-sym-cache* (make-hasheq))
(define *unit-meta-cache* (make-hasheq))

(define (fast-safe-real v default)
  (if (and (real? v) (< -inf.0 v +inf.0))
      (exact->inexact v)
      (exact->inexact default)))

(define (fast-safe-int v default)
  (cond
    [(exact-integer? v) v]
    [(and (real? v) (< -inf.0 v +inf.0)) (inexact->exact (round v))]
    [else default]))

(define (fast-safe-nonneg-int v default)
  (define iv (fast-safe-int v default))
  (if (>= iv 0) iv default))

(define (fast-round2 v)
  (/ (round (* 100.0 (fast-safe-real v 0.0))) 100.0))

(define (fast-dist2 x1 y1 x2 y2)
  (define dx (- x2 x1))
  (define dy (- y2 y1))
  (+ (* dx dx) (* dy dy)))

(define (fast-raw-unit-sym u)
  (cond
    [(hash? u)
     (define raw (hash-ref u 'type 'unknown))
     (cond
       [(symbol? raw) raw]
       [(string? raw) (string->symbol (string-downcase raw))]
       [else 'unknown])]
    [(symbol? u) u]
    [(string? u) (string->symbol (string-downcase u))]
    [else 'unknown]))

(define (fast-canon-unit raw-sym)
  (or (hash-ref *canon-unit-cache* raw-sym #f)
      (let ([c (sc2-canonical-unit-sym raw-sym)])
        (hash-set! *canon-unit-cache* raw-sym c)
        c)))

(define (fast-canon-struct raw-sym)
  (or (hash-ref *canon-struct-cache* raw-sym #f)
      (let ([c (sc2-canonical-structure-sym raw-sym)])
        (hash-set! *canon-struct-cache* raw-sym c)
        c)))

(define (fast-flying-sym? csym)
  (define hit (hash-ref *flying-sym-cache* csym #f))
  (if hit
      (eq? hit 'yes)
      (let ([f? (or (sc2-unit-is-flying-sym? csym)
                    (and (memq csym
                               '(oracle banshee mutalisk phoenix void-ray liberator medivac
                                 warp-prism carrier tempest battlecruiser brood-lord))
                         #t))])
        (hash-set! *flying-sym-cache* csym (if f? 'yes 'no))
        f?)))

(define (fast-noncombat-sym? csym)
  (define hit (hash-ref *noncombat-sym-cache* csym #f))
  (if hit
      (eq? hit 'yes)
      (let ([nc? (or (and (memq csym '(scv probe drone larva egg overlord mule observer changeling)) #t)
                     (sc2-non-combat-or-summon-sym? csym))])
        (hash-set! *noncombat-sym-cache* csym (if nc? 'yes 'no))
        nc?)))

;; Combined per-symbol unit metadata: #(canon-sym worker? noncombat? flying?)
(define (fast-unit-meta raw-sym)
  (or (hash-ref *unit-meta-cache* raw-sym #f)
      (let* ([csym (fast-canon-unit raw-sym)]
             [wrk? (and (memq csym '(scv probe drone)) #t)]
             [nc?  (fast-noncombat-sym? csym)]
             [fly? (fast-flying-sym? csym)]
             [v    (vector csym wrk? nc? fly?)])
        (hash-set! *unit-meta-cache* raw-sym v)
        v)))

(define (fast-hash-unit-pos-id? u)
  (define vid (hash-ref u 'id *missing*))
  (if (exact-integer? vid)
      (> vid 0)
      (> (u-id u) 0)))

(define (fast-hash-raw-sym u)
  (define raw (hash-ref u 'type 'unknown))
  (cond
    [(symbol? raw) raw]
    [(string? raw) (string->symbol (string-downcase raw))]
    [else 'unknown]))

(define (ensure-obs obs)
  (if (hash? obs) obs (hash)))

(define (obs-ref obs k default)
  (if (hash? obs)
      (let ([v (hash-ref obs k *missing*)])
        (if (eq? v *missing*) default v))
      default))

(define (obs-list obs k)
  (define v (obs-ref obs k '()))
  (if (list? v) v '()))

(define (u-id u)
  (if (hash? u)
      (let ([v (hash-ref u 'id *missing*)])
        (cond
          [(exact-integer? v) v]
          [(eq? v *missing*) (fast-safe-int (hash-ref u 'tag 0) 0)]
          [else (fast-safe-int v 0)]))
      0))

(define (u-x u [default 32.5])
  (if (hash? u)
      (let ([v (hash-ref u 'x *missing*)])
        (cond
          [(and (flonum? v) (fl< -inf.0 v) (fl< v +inf.0)) v]
          [(eq? v *missing*) (exact->inexact default)]
          [else (fast-safe-real v default)]))
      (exact->inexact default)))

(define (u-y u [default 32.5])
  (if (hash? u)
      (let ([v (hash-ref u 'y *missing*)])
        (cond
          [(and (flonum? v) (fl< -inf.0 v) (fl< v +inf.0)) v]
          [(eq? v *missing*) (exact->inexact default)]
          [else (fast-safe-real v default)]))
      (exact->inexact default)))

(define (u-hp u [default 100.0])
  (if (hash? u)
      (let ([v (hash-ref u 'hp *missing*)])
        (cond
          [(and (flonum? v) (fl< -inf.0 v) (fl< v +inf.0)) v]
          [(eq? v *missing*) (exact->inexact default)]
          [else (fast-safe-real v default)]))
      (exact->inexact default)))

(define (u-max-hp u [default 100.0])
  (if (hash? u)
      (let ([v (hash-ref u 'max-hp *missing*)])
        (cond
          [(and (flonum? v) (fl< 1.0 v) (fl< v +inf.0)) v]
          [(eq? v *missing*) (max 1.0 (fast-safe-real (hash-ref u 'health-max default) default))]
          [else (max 1.0 (fast-safe-real v default))]))
      (max 1.0 (exact->inexact default))))

(define (u-hp-frac u)
  (if (hash? u)
      (let ([hp (hash-ref u 'hp *missing*)]
            [mh (hash-ref u 'max-hp *missing*)])
        (if (and (flonum? hp) (flonum? mh) (fl> mh 1.0) (fl< mh +inf.0) (fl< -inf.0 hp) (fl< hp +inf.0))
            (fl/ hp mh)
            (/ (u-hp u) (u-max-hp u))))
      1.0))

(define (u-energy u [default 0.0])
  (if (hash? u)
      (let ([v (hash-ref u 'energy *missing*)])
        (if (eq? v *missing*)
            (exact->inexact default)
            (fast-safe-real v default)))
      (exact->inexact default)))

(define (u-progress u [default 1.0])
  (if (hash? u)
      (let ([v (hash-ref u 'build-progress *missing*)])
        (cond
          [(and (flonum? v) (fl< -inf.0 v) (fl< v +inf.0)) v]
          [(eq? v *missing*) (exact->inexact default)]
          [else (fast-safe-real v default)]))
      (exact->inexact default)))

(define (u-complete? u)
  (if (hash? u)
      (let ([v (hash-ref u 'build-progress *missing*)])
        (cond
          [(flonum? v) (fl>= v SC2-BUILD-COMPLETE-PROGRESS)]
          [(eq? v *missing*) #t]
          [else (>= (fast-safe-real v 1.0) SC2-BUILD-COMPLETE-PROGRESS)]))
      #t))

(define (clamp-coord v)
  (fast-round2 (max SC2-MAP-SAFE-MIN-COORD (min SC2-MAP-SAFE-MAX-COORD (fast-safe-real v 88.0)))))

(define (home-xy obs)
  (values (fast-safe-real (obs-ref obs 'base-x SC2-DEFAULT-HOME-BASE-X) SC2-DEFAULT-HOME-BASE-X)
          (fast-safe-real (obs-ref obs 'base-y SC2-DEFAULT-HOME-BASE-Y) SC2-DEFAULT-HOME-BASE-Y)))

(define (nat-xy obs)
  (values (fast-safe-real (obs-ref obs 'natural-x SC2-DEFAULT-NATURAL-X) SC2-DEFAULT-NATURAL-X)
          (fast-safe-real (obs-ref obs 'natural-y SC2-DEFAULT-NATURAL-Y) SC2-DEFAULT-NATURAL-Y)))

(define (enemy-xy obs)
  (values (fast-safe-real (obs-ref obs 'enemy-x SC2-DEFAULT-ENEMY-BASE-X) SC2-DEFAULT-ENEMY-BASE-X)
          (fast-safe-real (obs-ref obs 'enemy-y SC2-DEFAULT-ENEMY-BASE-Y) SC2-DEFAULT-ENEMY-BASE-Y)))

(define (enemy-exp-xy obs)
  (values (fast-safe-real (obs-ref obs 'enemy-expand-x (obs-ref obs 'enemy-exp-x SC2-DEFAULT-ENEMY-EXPAND-X))
                          SC2-DEFAULT-ENEMY-EXPAND-X)
          (fast-safe-real (obs-ref obs 'enemy-expand-y (obs-ref obs 'enemy-exp-y SC2-DEFAULT-ENEMY-EXPAND-Y))
                          SC2-DEFAULT-ENEMY-EXPAND-Y)))

(define (topk-insert! kd2 ku filled k d2 u)
  (define full? (= filled k))
  (cond
    [(and full? (> d2 (vector-ref kd2 (- k 1)))) filled]
    [else
     (let loop ([p (if full? (- k 1) filled)])
       (cond
         [(and (> p 0) (<= d2 (vector-ref kd2 (- p 1))))
          (vector-set! kd2 p (vector-ref kd2 (- p 1)))
          (vector-set! ku p (vector-ref ku (- p 1)))
          (loop (- p 1))]
         [else
          (vector-set! kd2 p d2)
          (vector-set! ku p u)
          (if full? k (+ filled 1))]))]))

(define (topk->list ku filled)
  (let loop ([i (- filled 1)] [acc '()])
    (if (< i 0) acc (loop (- i 1) (cons (vector-ref ku i) acc)))))

(define (k-nearest-to x y k candidates [max-dist +inf.0])
  (if (or (fx<= k 0) (null? candidates))
      '()
      (let ([fx (real->double-flonum x)]
            [fy (real->double-flonum y)]
            [k-1 (fx- k 1)]
            [kd2 (make-vector k +inf.0)]
            [ku (make-vector k #f)]
            [init-cutoff (if (infinite? max-dist) +inf.0 (* max-dist max-dist))])
        (let loop ([rem candidates] [filled 0] [cutoff init-cutoff])
          (if (null? rem)
              (topk->list ku filled)
              (let* ([c (car rem)]
                     [dx (fl- (u-x c 9999.0) fx)]
                     [dx2 (fl* dx dx)])
                (if (<= dx2 cutoff)
                    (let* ([dy (fl- (u-y c 9999.0) fy)]
                           [d2 (fl+ dx2 (fl* dy dy))])
                      (if (<= d2 cutoff)
                          (let ([nf (topk-insert! kd2 ku filled k d2 c)])
                            (loop (cdr rem)
                                  nf
                                  (if (fx= nf k) (vector-ref kd2 k-1) cutoff)))
                          (loop (cdr rem) filled cutoff)))
                    (loop (cdr rem) filled cutoff))))))))

(struct xy-cloud (units xs ys minx maxx miny maxy count) #:transparent)

(define (build-xy-cloud lst default-xy)
  (if (null? lst)
      (xy-cloud '#() (flvector) (flvector) +inf.0 -inf.0 +inf.0 -inf.0 0)
      (let* ([dxy (real->double-flonum default-xy)]
             [uv (list->vector lst)]
             [n (vector-length uv)]
             [xv (make-flvector n 0.0)]
             [yv (make-flvector n 0.0)])
        (let loop ([i 0] [minx +inf.0] [maxx -inf.0] [miny +inf.0] [maxy -inf.0])
          (if (fx>= i n)
              (xy-cloud uv xv yv minx maxx miny maxy n)
              (let* ([u (vector-ref uv i)]
                     [ux (if (hash? u)
                             (let ([rx (hash-ref u 'x *missing*)])
                               (cond
                                 [(and (flonum? rx) (fl< -inf.0 rx) (fl< rx +inf.0)) rx]
                                 [(and (real? rx) (< -inf.0 rx +inf.0)) (real->double-flonum rx)]
                                 [else dxy]))
                             dxy)]
                     [uy (if (hash? u)
                             (let ([ry (hash-ref u 'y *missing*)])
                               (cond
                                 [(and (flonum? ry) (fl< -inf.0 ry) (fl< ry +inf.0)) ry]
                                 [(and (real? ry) (< -inf.0 ry +inf.0)) (real->double-flonum ry)]
                                 [else dxy]))
                             dxy)])
                (flvector-set! xv i ux)
                (flvector-set! yv i uy)
                (loop (fx+ i 1)
                      (if (fl< ux minx) ux minx)
                      (if (fl> ux maxx) ux maxx)
                      (if (fl< uy miny) uy miny)
                      (if (fl> uy maxy) uy maxy))))))))

(struct nydus-index
  (frame
   enemy-race
   under-attack?
   bx by nx ny ex ey eex eey
   ally-units enemy-units
   ally-u-by-type ally-b-by-type enemy-b-by-type
   ally-workers ally-combat
   [eu-cloud #:mutable]
   [au-cloud #:mutable]
   [combat-cloud #:mutable])
  #:transparent)

(define (ensure-eu-cloud! idx)
  (or (nydus-index-eu-cloud idx)
      (let ([c (build-xy-cloud (nydus-index-enemy-units idx) 9999.0)])
        (set-nydus-index-eu-cloud! idx c)
        c)))

(define (ensure-au-cloud! idx)
  (or (nydus-index-au-cloud idx)
      (let ([c (build-xy-cloud (nydus-index-ally-units idx) 9999.0)])
        (set-nydus-index-au-cloud! idx c)
        c)))

(define (ensure-combat-cloud! idx)
  (or (nydus-index-combat-cloud idx)
      (let ([c (build-xy-cloud (nydus-index-ally-combat idx) 9999.0)])
        (set-nydus-index-combat-cloud! idx c)
        c)))

(define (cloud-k-nearest-to cld x y k max-dist)
  (define cnt (xy-cloud-count cld))
  (cond
    [(or (fx<= k 0) (fx= cnt 0)) '()]
    [(and (not (infinite? max-dist))
          (or (< (+ x max-dist) (xy-cloud-minx cld))
              (> (- x max-dist) (xy-cloud-maxx cld))
              (< (+ y max-dist) (xy-cloud-miny cld))
              (> (- y max-dist) (xy-cloud-maxy cld))))
     '()]
    [else
     (define uv (xy-cloud-units cld))
     (define xs (xy-cloud-xs cld))
     (define ys (xy-cloud-ys cld))
     (define fx (real->double-flonum x))
     (define fy (real->double-flonum y))
     (define max-d2 (if (infinite? max-dist) +inf.0 (real->double-flonum (* max-dist max-dist))))
     (define k-1 (fx- k 1))
     (define kd2 (make-vector k +inf.0))
     (define ku (make-vector k #f))
     (let loop ([i 0] [filled 0] [cutoff max-d2])
       (if (fx>= i cnt)
           (topk->list ku filled)
           (let* ([dx (fl- (flvector-ref xs i) fx)]
                  [dx2 (fl* dx dx)])
             (if (fl<= dx2 cutoff)
                 (let* ([dy (fl- (flvector-ref ys i) fy)]
                        [d2 (fl+ dx2 (fl* dy dy))])
                   (if (fl<= d2 cutoff)
                       (let ([nf (topk-insert! kd2 ku filled k d2 (vector-ref uv i))])
                         (loop (fx+ i 1)
                               nf
                               (if (fx= nf k) (real->double-flonum (vector-ref kd2 k-1)) cutoff)))
                       (loop (fx+ i 1) filled cutoff)))
                 (loop (fx+ i 1) filled cutoff)))))]))

(define (cloud-count-within? cld x y r limit)
  (define cnt (xy-cloud-count cld))
  (cond
    [(fx= cnt 0) 0]
    [(or (< (+ x r) (xy-cloud-minx cld))
         (> (- x r) (xy-cloud-maxx cld))
         (< (+ y r) (xy-cloud-miny cld))
         (> (- y r) (xy-cloud-maxy cld)))
     0]
    [else
     (define xs (xy-cloud-xs cld))
     (define ys (xy-cloud-ys cld))
     (define fx (real->double-flonum x))
     (define fy (real->double-flonum y))
     (define r2 (real->double-flonum (* r r)))
     (let loop ([i 0] [hits 0])
       (cond
         [(or (fx>= i cnt) (fx>= hits limit)) hits]
         [else
          (define dx (fl- (flvector-ref xs i) fx))
          (define dy (fl- (flvector-ref ys i) fy))
          (if (fl<= (fl+ (fl* dx dx) (fl* dy dy)) r2)
              (loop (fx+ i 1) (fx+ hits 1))
              (loop (fx+ i 1) hits))]))]))

(define (cloud-entities-within cld x y r)
  (define cnt (xy-cloud-count cld))
  (cond
    [(fx= cnt 0) '()]
    [(or (< (+ x r) (xy-cloud-minx cld))
         (> (- x r) (xy-cloud-maxx cld))
         (< (+ y r) (xy-cloud-miny cld))
         (> (- y r) (xy-cloud-maxy cld)))
     '()]
    [else
     (define uv (xy-cloud-units cld))
     (define xs (xy-cloud-xs cld))
     (define ys (xy-cloud-ys cld))
     (define fx (real->double-flonum x))
     (define fy (real->double-flonum y))
     (define r2 (real->double-flonum (* r r)))
     (let loop ([i (fx- cnt 1)] [acc '()])
       (cond
         [(fx< i 0) acc]
         [else
          (define dx (fl- (flvector-ref xs i) fx))
          (define dy (fl- (flvector-ref ys i) fy))
          (if (fl<= (fl+ (fl* dx dx) (fl* dy dy)) r2)
              (loop (fx- i 1) (cons (vector-ref uv i) acc))
              (loop (fx- i 1) acc))]))]))

(define (ht-push! ht key val)
  (define b (hash-ref ht key #f))
  (if b
      (set-box! b (cons val (unbox b)))
      (hash-set! ht key (box (list val)))))

(define (finalize-buckets! ht)
  (let loop ([pos (hash-iterate-first ht)])
    (when pos
      (define lst (unbox (hash-iterate-value ht pos)))
      (hash-set! ht (hash-iterate-key ht pos)
                 (if (and (pair? lst) (pair? (cdr lst))) (reverse lst) lst))
      (loop (hash-iterate-next ht pos)))))

(define (bucket-pos-ids ht syms)
  (if (and (pair? syms) (null? (cdr syms)))
      (hash-ref ht (car syms) '())
      (let loop ([rem syms] [acc '()])
        (if (null? rem)
            acc
            (let ([vs (hash-ref ht (car rem) '())])
              (loop (cdr rem)
                    (if (null? vs) acc (if (null? acc) vs (append acc vs)))))))))

(define (build-nydus-index raw-obs)
  (define obs (ensure-obs raw-obs))
  (define frame (fast-safe-nonneg-int (obs-ref obs 'frame 0) 0))
  (define enemy-race (obs-ref obs 'enemy-race 'Unknown))
  (define under-attack? (and (obs-ref obs 'under-attack? #f) #t))
  (define-values (bx by) (home-xy obs))
  (define-values (nx ny) (nat-xy obs))
  (define-values (ex ey) (enemy-xy obs))
  (define-values (eex eey) (enemy-exp-xy obs))
  (define ally-units (obs-list obs 'ally-units))
  (define ally-bldgs (obs-list obs 'ally-buildings))
  (define enemy-units (obs-list obs 'enemy-units))
  (define enemy-bldgs (obs-list obs 'enemy-buildings))

  (define ally-u-ht (make-hasheq))
  (define ally-b-ht (make-hasheq))
  (define enemy-b-ht (make-hasheq))

  (define-values (workers-rev combat-rev)
    (let loop-ally ([rem ally-units] [w-rev '()] [c-rev '()])
      (if (null? rem)
          (values w-rev c-rev)
          (let ([u (car rem)]
                [rest (cdr rem)])
            (if (and (hash? u) (fast-hash-unit-pos-id? u))
                (let ([meta (fast-unit-meta (fast-hash-raw-sym u))])
                  (ht-push! ally-u-ht (vector-ref meta 0) u)
                  (cond
                    [(vector-ref meta 1) (loop-ally rest (cons u w-rev) c-rev)]
                    [(not (vector-ref meta 2)) (loop-ally rest w-rev (cons u c-rev))]
                    [else (loop-ally rest w-rev c-rev)]))
                (loop-ally rest w-rev c-rev))))))

  (for ([b (in-list ally-bldgs)]
        #:when (and (hash? b) (fast-hash-unit-pos-id? b)))
    (ht-push! ally-b-ht (fast-canon-struct (fast-hash-raw-sym b)) b))

  (for ([b (in-list enemy-bldgs)]
        #:when (and (hash? b) (fast-hash-unit-pos-id? b)))
    (ht-push! enemy-b-ht (fast-canon-struct (fast-hash-raw-sym b)) b))

  (finalize-buckets! ally-u-ht)
  (finalize-buckets! ally-b-ht)
  (finalize-buckets! enemy-b-ht)

  (nydus-index frame enemy-race under-attack?
               bx by nx ny ex ey eex eey
               ally-units enemy-units
               ally-u-ht ally-b-ht enemy-b-ht
               (reverse workers-rev) (reverse combat-rev)
               #f #f #f))

;; -----------------------------------------------------------------------------
;; 2. Symmetric Nydus Worm Tactics <-> Counter Nydus Worm Tactics
;; -----------------------------------------------------------------------------

(define (plan-nydus-worm-tactics/idx idx
                                     #:preferred-worm-pt [pref-worm-pt #f]
                                     #:preferred-perch-pt [pref-perch-pt #f])
  (define ab-ht (nydus-index-ally-b-by-type idx))
  (define nets (bucket-pos-ids ab-ht '(nydus-network)))
  (define worms (bucket-pos-ids ab-ht '(nydus-canal nydus-worm)))
  (if (and (null? nets) (null? worms))
      '()
      (let ()
        (define bx (nydus-index-bx idx))
        (define by (nydus-index-by idx))
        (define ex (nydus-index-ex idx))
        (define ey (nydus-index-ey idx))
        (define eex (nydus-index-eex idx))
        (define eey (nydus-index-eey idx))
        (define au-ht (nydus-index-ally-u-by-type idx))
        (define eb-ht (nydus-index-enemy-b-by-type idx))
        (define queens (bucket-pos-ids au-ht '(queen)))
        (define e-bunkers (bucket-pos-ids eb-ht '(bunker)))
        (define actions '())
        (define (emit! a) (set! actions (cons a actions)))

        ;; L59-P2 (`#1481`): Vision-Verified Nydus Worm Placement!
        ;; Locate live vision spotters (`changeling*` > `overlord`/`overseer` > `mutalisk`/`corruptor`)
        ;; already near enemy Main/Nat (`<= 32t`) so `build-nydus-worm` lands on a VISIBLE tile instead
        ;; of failing `CantSeeBuildLocation` in fog!
        (define all-changelings
          (bucket-pos-ids au-ht '(changeling changeling-zealot changeling-marine
                                  changeling-marine-shield changeling-zergling
                                  changeling-zergling-wings)))
        (define all-air-spotters
          (bucket-pos-ids au-ht '(overlord overlord-transport overseer overseer-siege-mode
                                  mutalisk corruptor)))
        (define all-spotters (append all-changelings all-air-spotters))
        (define (spotter-near-enemy? u)
          (define ux (u-x u bx))
          (define uy (u-y u by))
          (or (<= (fast-dist2 ux uy ex ey) 1024.0)
              (<= (fast-dist2 ux uy eex eey) 1024.0)
              (and (pair? pref-worm-pt) (real? (car pref-worm-pt)) (real? (cdr pref-worm-pt))
                   (<= (fast-dist2 ux uy
                                   (exact->inexact (car pref-worm-pt))
                                   (exact->inexact (cdr pref-worm-pt)))
                       121.0))))
        (define active-spotters
          (filter spotter-near-enemy? all-spotters))
        (define frame (nydus-index-frame idx))
        ;; L59-P3 (`n20` fix): Collect visible enemy combat units near enemy Main (`<= 30t`) so
        ;; emerging Nydus Worms (`1768`) are NEVER planted right in front of Sieged Tanks / Marines!
        (define enemy-main-combat
          (for/list ([eu (in-list (nydus-index-enemy-units idx))]
                     #:when (and (hash? eu)
                                 (fast-hash-unit-pos-id? eu)
                                 (let ([meta (fast-unit-meta (fast-hash-raw-sym eu))])
                                   (and (not (vector-ref meta 1))
                                        (not (vector-ref meta 2))))
                                 (<= (fast-dist2 (u-x eu ex) (u-y eu ey) ex ey) 900.0)))
            eu))
        (define (point-safe-from-enemy-combat? px py)
          (for/and ([eu (in-list enemy-main-combat)])
            (define meta (fast-unit-meta (fast-hash-raw-sym eu)))
            (define sym (vector-ref meta 0))
            (define min-r2 (if (memq sym '(siege-tank siege-tank-sieged)) 182.25 110.25)) ;; 13.5t vs Tank, 10.5t vs Bio
            (>= (fast-dist2 px py (u-x eu ex) (u-y eu ey)) min-r2)))
        (define (compute-safe-corner-xy sx sy)
          ;; Pick a safe rear corner behind enemy Main / mineral line opposite visible enemy combat centroid!
          (define nc (length enemy-main-combat))
          (define ecx (/ (for/fold ([s 0.0]) ([eu (in-list enemy-main-combat)]) (+ s (u-x eu ex))) (exact->inexact nc)))
          (define ecy (/ (for/fold ([s 0.0]) ([eu (in-list enemy-main-combat)]) (+ s (u-y eu ey))) (exact->inexact nc)))
          ;; Vector from enemy combat centroid through enemy TH (or away from combat centroid)
          (define ax (- ex ecx))
          (define ay (- ey ecy))
          (define al (sqrt (+ (* ax ax) (* ay ay))))
          (define-values (ux uy)
            (if (> al 0.5)
                (values (/ ax al) (/ ay al))
                (let* ([dx (- sx ecx)]
                       [dy (- sy ecy)]
                       [dl (max 0.1 (sqrt (+ (* dx dx) (* dy dy))))])
                  (values (/ dx dl) (/ dy dl)))))
          (define px (- uy))
          (define py ux)
          ;; Evaluate 8 rear-corner / far-flank candidates (`12..16t` from `(ex, ey)`) and pick the
          ;; safest candidate closest to our live spotter `(sx, sy)`!
          (define cands
            (list
             ;; Far side past current spotter away from combat centroid (often already in 11t Overseer vision!)
             (let* ([sdx (- sx ecx)]
                    [sdy (- sy ecy)]
                    [sdl (max 0.1 (sqrt (+ (* sdx sdx) (* sdy sdy))))])
               (cons (clamp-coord (+ ecx (* 14.5 (/ sdx sdl))))
                     (clamp-coord (+ ecy (* 14.5 (/ sdy sdl))))))
             (cons (clamp-coord (+ ex (* 11.5 ux) (* 7.0 px)))
                   (clamp-coord (+ ey (* 11.5 uy) (* 7.0 py))))
             (cons (clamp-coord (+ ex (* 11.5 ux) (* -7.0 px)))
                   (clamp-coord (+ ey (* 11.5 uy) (* -7.0 py))))
             (cons (clamp-coord (+ ex (* 13.5 ux)))
                   (clamp-coord (+ ey (* 13.5 uy))))
             (cons (clamp-coord (+ ex (* 7.0 ux) (* 12.0 px)))
                   (clamp-coord (+ ey (* 7.0 uy) (* 12.0 py))))
             (cons (clamp-coord (+ ex (* 7.0 ux) (* -12.0 px)))
                   (clamp-coord (+ ey (* 7.0 uy) (* -12.0 py))))))
          (define safe-cands (filter (lambda (pt) (point-safe-from-enemy-combat? (car pt) (cdr pt))) cands))
          (define pool
            (sort (if (pair? safe-cands) safe-cands cands)
                  (lambda (a b) (< (fast-dist2 sx sy (car a) (cdr a))
                                   (fast-dist2 sx sy (car b) (cdr b))))))
          ;; Rotate across safe rear-corner candidates every 24f if the first tile hit an unbuildable cliff edge!
          (define idx-c (modulo (quotient (max 0 frame) 24) (length pool)))
          (define best (list-ref pool idx-c))
          (values (car best) (cdr best)))
        (define (spotter-drop-xy u)
          (define sx (u-x u ex))
          (define sy (u-y u ey))
          ;; Nudge 4.8t away from enemy TH center if sitting directly on its 5x5 footprint
          (define d2-th (fast-dist2 sx sy ex ey))
          (define-values (base-x base-y)
            (if (< d2-th 16.0)
                (let* ([dx (- sx ex)]
                       [dy (- sy ey)]
                       [dl (max 0.1 (sqrt (+ (* dx dx) (* dy dy))))])
                  (values (+ ex (* 4.8 (/ dx dl)))
                          (+ ey (* 4.8 (/ dy dl)))))
                (values sx sy)))
          ;; L59-P2 (`n20` fix): Frame-indexed retry spiral (`slot = 0` at `frame < 16` uses exact `(base-x, base-y)`,
          ;; then sweeps inward/laterally toward `(ex, ey)` if the first tile was unbuildable cliff/mineral/geyser!)
          (define slot (modulo (quotient (max 0 frame) 16) 8))
          (if (= slot 0)
              (values (clamp-coord base-x) (clamp-coord base-y))
              (let* ([ix (- ex base-x)]
                     [iy (- ey base-y)]
                     [il (max 0.1 (sqrt (+ (* ix ix) (* iy iy))))]
                     [ux (/ ix il)]
                     [uy (/ iy il)]
                     [px (- uy)]
                     [py ux]
                     [off (case slot
                            [(1) '(2.6 . 0.0)]
                            [(2) '(2.6 . 2.6)]
                            [(3) '(2.6 . -2.6)]
                            [(4) '(4.5 . 0.0)]
                            [(5) '(0.0 . 3.2)]
                            [(6) '(0.0 . -3.2)]
                            [else '(4.5 . 2.8)])]
                     [fwd (car off)]
                     [lat (cdr off)])
                (values (clamp-coord (+ base-x (* fwd ux) (* lat px)))
                        (clamp-coord (+ base-y (* fwd uy) (* lat py)))))))
        ;; Emit safe Nydus Worm or glide spotter to safe rear corner when spotter is inside Tank/Marine range!
        (define (emit-safe-nydus-for-spotter! net-u sp-u)
          (define sx (u-x sp-u ex))
          (define sy (u-y sp-u ey))
          (define pref-ok?
            (and (pair? pref-worm-pt)
                 (real? (car pref-worm-pt)) (real? (cdr pref-worm-pt))
                 (<= (fast-dist2 sx sy
                                 (exact->inexact (car pref-worm-pt))
                                 (exact->inexact (cdr pref-worm-pt)))
                     100.0)))
          (define-values (wx0 wy0)
            (if pref-ok?
                (values (clamp-coord (exact->inexact (car pref-worm-pt)))
                        (clamp-coord (exact->inexact (cdr pref-worm-pt))))
                (spotter-drop-xy sp-u)))
          (cond
            [(or (null? enemy-main-combat) (point-safe-from-enemy-combat? wx0 wy0))
             (emit! (list 'build-nydus-worm (u-id net-u) wx0 wy0))]
            [else
             (define-values (cx cy) (compute-safe-corner-xy sx sy))
             ;; Overseer/Overlord sight radius is 11t (`<= 9.5t` guarantees live vision on `(cx, cy)`)!
             (if (<= (fast-dist2 sx sy cx cy) 90.25)
                 (emit! (list 'build-nydus-worm (u-id net-u) cx cy))
                 (emit! (list 'move (u-id sp-u) cx cy)))]))

        ;; Bypass fortified enemy bunker contain via main-edge Nydus Worm (preferring spotter vision!)
        ;; Loop 87C: NEVER emit blind fogged Nydus Worms when allied Overlord/Overseer spotters exist
        ;; (prevents wire fallback from spawning Worms inside our own main base).
        (when (and (pair? e-bunkers) (pair? nets) (null? worms))
          (cond
            [(pair? active-spotters)
             (emit-safe-nydus-for-spotter! (first nets) (first active-spotters))]
            [(null? all-spotters)
             (emit! (list 'build-nydus-worm (u-id (first nets))
                          (clamp-coord (- ex 10.0))
                          (clamp-coord (+ ey 8.0))))]))

        (when (and (pair? nets) (null? worms))
          (cond
            [(pair? active-spotters)
             (define sp0 (first active-spotters))
             (emit-safe-nydus-for-spotter! (first nets) sp0)
             (when (>= (length nets) 2)
               (define sp0x (u-x sp0 ex))
               (define sp0y (u-y sp0 ey))
               (define sp1
                 (findf (lambda (u)
                          (>= (fast-dist2 (u-x u ex) (u-y u ey) sp0x sp0y) 100.0))
                        (cdr active-spotters)))
               (when sp1
                 (emit-safe-nydus-for-spotter! (second nets) sp1)))]
            [(pair? all-spotters)
             ;; Live match with spotters available elsewhere -> send nearest Changeling/Overlord
             ;; to solved dead-air perch (or enemy main back corner) to open live vision!
             (define-values (corner-x corner-y)
               (if (and (pair? pref-perch-pt)
                        (real? (car pref-perch-pt)) (real? (cdr pref-perch-pt)))
                   (values (clamp-coord (exact->inexact (car pref-perch-pt)))
                           (clamp-coord (exact->inexact (cdr pref-perch-pt))))
                   (let* ([dx (- ex bx)]
                          [dy (- ey by)]
                          [dl (max 1.0 (sqrt (+ (* dx dx) (* dy dy))))])
                     (values (clamp-coord (+ ex (* 9.5 (/ dx dl)) (* 6.5 (/ (- dy) dl))))
                             (clamp-coord (+ ey (* 9.5 (/ dy dl)) (* 6.5 (/ dx dl))))))))
             (define lead-sp
               (car (k-nearest-to corner-x corner-y 1 all-spotters)))
             (emit! (list 'move (u-id lead-sp) corner-x corner-y))]
            [else
             ;; Synthetic/minimal test with 0 spotters in obs -> preserve legacy placement fallback
             (emit! (list 'build-nydus-worm (u-id (first nets))
                          (clamp-coord (+ ex 9.0)) (clamp-coord (+ ey 9.0))))
             (when (>= (length nets) 2)
               (emit! (list 'build-nydus-worm (u-id (second nets))
                            (clamp-coord (- eex 10.0)) (clamp-coord (+ eey 10.0)))))]))

        ;; Loop 87C: Pre-load up to 7 Queens + 24 ground army units once a worm is emerging/active
        ;; OR once an active spotter is in position at the enemy main with a completed Network!
        (when (and (pair? nets)
                   (u-complete? (first nets))
                   (or (pair? worms) (pair? active-spotters)))
          (define army (bucket-pos-ids au-ht '(zergling baneling roach ravager hydralisk lurker ultralisk)))
          (define net0 (first nets))
          (define nx0 (u-x net0 bx))
          (define ny0 (u-y net0 by))
          (for ([q (in-list (k-nearest-to nx0 ny0 7 queens 22.0))])
            (emit! (list 'nydus-load (u-id net0) (u-id q))))
          (for ([au (in-list (k-nearest-to nx0 ny0 24 army 24.0))])
            (emit! (list 'nydus-load (u-id net0) (u-id au)))))

        (define completed-worms
          (for/fold ([acc '()] #:result (reverse acc))
                    ([w (in-list worms)])
            (if (u-complete? w) (cons w acc) acc)))
        (when (pair? completed-worms)
          (define au-cld (ensure-au-cloud! idx))
          (define eu-cld (ensure-eu-cloud! idx))
          (define queen-pts
            (for/list ([q (in-list queens)])
              (vector (u-id q) (u-x q bx) (u-y q by) (u-energy q 0.0))))
          (for ([w (in-list completed-worms)])
            (define wid (u-id w))
            (define wx (u-x w ex))
            (define wy (u-y w ey))
            ;; L59-P2 (`n20` fix): Only ground COMBAT allies can enter a Nydus Worm (`overseer`/`changeling` cannot!),
            ;; only enemy COMBAT units count toward outnumbering (never 16 SCVs in a mineral line!), and never abort
            ;; `(nydus-unload wid)` while the worm still holds cargo and has `>= 35%` HP!
            (define local-allies
              (for/list ([au (in-list (cloud-entities-within au-cld wx wy 12.0))]
                         #:when (let ([meta (fast-unit-meta (fast-hash-raw-sym au))])
                                  (and (not (vector-ref meta 2))
                                       (not (vector-ref meta 3)))))
                au))
            (define enemy-combat-cnt
              (for/sum ([eu (in-list (cloud-entities-within eu-cld wx wy 14.0))]
                        #:when (let ([meta (fast-unit-meta (fast-hash-raw-sym eu))])
                                 (and (not (vector-ref meta 1))
                                      (not (vector-ref meta 2)))))
                1))
            (define worm-cargo
              (fast-safe-nonneg-int (hash-ref w 'cargo-space-taken 0) 0))
            (define trapped-or-dying?
              (and (pair? local-allies)
                   (or (< (u-hp-frac w) 0.35)
                       (and (= worm-cargo 0)
                            (>= (length local-allies) 3)
                            (>= enemy-combat-cnt (+ 1 (* 2 (length local-allies))))))))
            (cond
              [trapped-or-dying?
               (for ([au (in-list local-allies)])
                 (emit! (list 'nydus-load wid (u-id au))))]
              [else
               (emit! (list 'nydus-unload wid))
               (when (pair? queen-pts)
                 (define low-hp? (< (u-hp-frac w) 0.90))
                 (define tumor-x (clamp-coord (+ wx 2.0)))
                 (define tumor-y (clamp-coord (+ wy 2.0)))
                 (for ([qp (in-list queen-pts)])
                   (when (<= (fast-dist2 wx wy (vector-ref qp 1) (vector-ref qp 2)) 64.0)
                     (define qid (vector-ref qp 0))
                     (when low-hp?
                       (emit! (list 'cast-spell qid 'transfusion wid)))
                     (when (>= (vector-ref qp 3) 25.0)
                       (emit! (list 'cast-spell qid 'spawn-creep-tumor tumor-x tumor-y))))))])))

        (reverse actions))))

(define (plan-nydus-worm-tactics raw-obs)
  (plan-nydus-worm-tactics/idx (build-nydus-index raw-obs)))

(define (enemy-race-is-zerg? r)
  (or (eq? r 'Zerg)
      (eq? r 'zerg)
      (and (string? r) (string-ci=? r "zerg"))))

(define (plan-counter-nydus-worm-tactics/idx idx)
  (define eb-ht (nydus-index-enemy-b-by-type idx))
  (define enemy-worms (bucket-pos-ids eb-ht '(nydus-canal nydus-worm)))
  (define combat (nydus-index-ally-combat idx))
  (define frame (nydus-index-frame idx))
  (define enemy-zerg? (enemy-race-is-zerg? (nydus-index-enemy-race idx)))
  (define patrol-candidate?
    (and (>= frame 4500)
         (pair? combat)
         (or (pair? enemy-worms)
             (and enemy-zerg?
                  (>= (length combat) 10)))))
  (if (and (null? enemy-worms)
           (not patrol-candidate?))
      '()
      (let ()
        (define bx (nydus-index-bx idx))
        (define by (nydus-index-by idx))
        (define nx (nydus-index-nx idx))
        (define ny (nydus-index-ny idx))
        (define actions '())
        (define (emit! a) (set! actions (cons a actions)))

        (when (pair? enemy-worms)
          (define workers (nydus-index-ally-workers idx))
          (define combat-cld (and (pair? (cdr enemy-worms)) (ensure-combat-cloud! idx)))
          (for ([ew (in-list enemy-worms)])
            (define wx (u-x ew bx))
            (define wy (u-y ew by))
            (define pull-cnt (if (< (u-progress ew 1.0) 1.0) 8 6))
            (define pulled (k-nearest-to wx wy pull-cnt workers 26.0))
            (when (pair? pulled)
              (emit! (list 'pull-workers-attack (map u-id pulled) (u-id ew) wx wy)))
            (define local-def
              (if combat-cld
                  (cloud-k-nearest-to combat-cld wx wy 12 26.0)
                  (k-nearest-to wx wy 12 combat 26.0)))
            (when (pair? local-def)
              (emit! (list 'focus-fire (map u-id local-def) (u-id ew))))))

        ;; L55-N1 (`#1371`/`#1372`): Gate anti-Nydus perimeter patrol on enemy Zerg (>= 10 combat)
        ;; or active enemy Nydus Worms AND never yank combat units defending against enemy combat
        ;; units near Main/Natural (<= 30t)!
        (when patrol-candidate?
          (define enemy-combat-near-home?
            (or (nydus-index-under-attack? idx)
                (for/or ([eu (in-list (nydus-index-enemy-units idx))])
                  (and (hash? eu)
                       (fast-hash-unit-pos-id? eu)
                       (not (vector-ref (fast-unit-meta (fast-hash-raw-sym eu)) 2))
                       (let ([exu (u-x eu 9999.0)]
                             [eyu (u-y eu 9999.0)])
                         (or (<= (fast-dist2 bx by exu eyu) 900.0)
                             (<= (fast-dist2 nx ny exu eyu) 900.0)))))))
          (when (not enemy-combat-near-home?)
            (define spotter (first combat))
            (emit! (list 'patrol (u-id spotter) (clamp-coord (- bx 9.0)) (clamp-coord (- by 9.0))))
            (when (pair? (cdr combat))
              (emit! (list 'patrol (u-id (second combat)) (clamp-coord (+ nx 9.0)) (clamp-coord (- ny 8.0)))))))

        (reverse actions))))

(define (plan-counter-nydus-worm-tactics raw-obs)
  (plan-counter-nydus-worm-tactics/idx (build-nydus-index raw-obs)))

;; -----------------------------------------------------------------------------
;; 3. Top-Level Nydus Orchestrator (`plan-nydus-actions`)
;; -----------------------------------------------------------------------------

(define (dedup-action-slot a)
  (and (pair? a)
       (symbol? (car a))
       (let ([r2 (cdr a)])
         (and (pair? r2)
              (let* ([k2 (car r2)]
                     [r3 (cdr r2)]
                     [k (if (and (pair? r3) (exact-integer? (car r3)))
                            (car r3)
                            (and (or (exact-integer? k2) (symbol? k2)) k2))])
                (and k
                     (cond
                       [(and (fixnum? k) (fixnum? k2))
                        (fxand (fx+ (fx* k2 131) k) 511)]
                       [(fixnum? k) (fxand k 511)]
                       [else (fxand (eq-hash-code k) 511)])))))))

(define (dedup-vec-seen?! vec a slot)
  (define bucket (vector-ref vec slot))
  (cond
    [(not bucket)
     (vector-set! vec slot a)
     #f]
    [(pair? bucket)
     (cond
       [(symbol? (car bucket))
        (if (equal? bucket a)
            #t
            (begin
              (vector-set! vec slot (list a bucket))
              #f))]
       [(member a bucket) #t]
       [(and (pair? (cdr bucket)) (pair? (cddr bucket)) (pair? (cdddr bucket))
             (pair? (cddddr bucket)) (pair? (cdr (cddddr bucket)))
             (pair? (cddr (cddddr bucket))) (pair? (cdddr (cddddr bucket))))
        (define h (make-hash))
        (for ([x (in-list bucket)]) (hash-set! h x #t))
        (hash-set! h a #t)
        (vector-set! vec slot h)
        #f]
       [else
        (vector-set! vec slot (cons a bucket))
        #f])]
    [else
     (if (hash-ref bucket a #f)
         #t
         (begin
           (hash-set! bucket a #t)
           #f))]))

(define (dedup-action-chunks chunks)
  (let loop-ch ([chs chunks] [acc '()] [n 0] [vec #f] [fb #f])
    (if (null? chs)
        (cond
          [(null? acc) '()]
          [(null? (cdr acc)) acc]
          [else (reverse acc)])
        (let loop-act ([acts (car chs)] [acc acc] [n n] [vec vec] [fb fb])
          (if (null? acts)
              (loop-ch (cdr chs) acc n vec fb)
              (let ([a (car acts)]
                    [rest (cdr acts)])
                (cond
                  [(and (not vec) (fx< n 8))
                   (if (member a acc)
                       (loop-act rest acc n vec fb)
                       (loop-act rest (cons a acc) (fx+ n 1) vec fb))]
                  [else
                   (define-values (v fb0)
                     (if vec
                         (values vec fb)
                         (let ([nv (make-vector 512 #f)])
                           (let loop-prev ([p acc] [f fb])
                             (if (null? p)
                                 (values nv f)
                                 (let* ([pa (car p)]
                                        [pslot (dedup-action-slot pa)])
                                   (if pslot
                                       (begin
                                         (dedup-vec-seen?! nv pa pslot)
                                         (loop-prev (cdr p) f))
                                       (let ([f2 (or f (make-hash))])
                                         (hash-set! f2 pa #t)
                                         (loop-prev (cdr p) f2)))))))))
                   (define slot (dedup-action-slot a))
                   (if slot
                       (if (dedup-vec-seen?! v a slot)
                           (loop-act rest acc n v fb0)
                           (loop-act rest (cons a acc) n v fb0))
                       (let ([f2 (or fb0 (make-hash))])
                         (if (hash-ref f2 a #f)
                             (loop-act rest acc n v f2)
                             (begin
                               (hash-set! f2 a #t)
                               (loop-act rest (cons a acc) n v f2)))))])))))))

(define (plan-nydus-actions raw-obs)
  (define obs (ensure-obs raw-obs))
  (define idx (build-nydus-index obs))
  (define pref-worm (obs-ref obs 'nydus-worm-pt #f))
  (define pref-perch (obs-ref obs 'nydus-perch-pt #f))
  (dedup-action-chunks
   (list
    (plan-nydus-worm-tactics/idx idx
                                 #:preferred-worm-pt pref-worm
                                 #:preferred-perch-pt pref-perch)
    (plan-counter-nydus-worm-tactics/idx idx))))
