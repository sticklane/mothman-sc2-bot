#lang typed/racket/base

;; =============================================================================
;; `lib/tactics/stealth-shimmer-response.rkt`
;; Cloaked Shimmer & Burrowed Movement Ripple Detection + Detector / Scan /
;; Blind AoE Skillshot Response (`execute-shimmer-and-burrow-ripple-response`).
;; =============================================================================

(require racket/list
         racket/math
         typed/racket/unsafe
         "../sc2-types.rkt"
         "../sc2-game-constants.rkt")

(module dyn-hash-ops racket/base
  (provide dyn-hash-ref)
  (define (dyn-hash-ref h k default)
    (if (hash? h)
        (hash-ref h k (lambda () default))
        default)))

(unsafe-require/typed (submod "." dyn-hash-ops)
  [dyn-hash-ref (-> Any Any Any Any)])

(provide
 shimmer-target-unit?
 mobile-or-static-detector-nearby?
 execute-shimmer-and-burrow-ripple-response)

(: shimmer-target-unit? (-> Any Boolean))
(define (shimmer-target-unit? e)
  (and (hash? e)
       (not (not (or (dyn-hash-ref e 'is-shimmer? #f)
                     (= (safe-exact-int (dyn-hash-ref e 'display-type 1) 1)
                        SC2-SHIMMER-DISPLAY-TYPE-HIDDEN)
                     (= (safe-exact-int (dyn-hash-ref e 'cloak-state 0) 0) 2)
                     (dyn-hash-ref e 'burrowed #f))))))

(: mobile-or-static-detector-nearby? (-> Any Any Real Real Real Boolean))
(define (mobile-or-static-detector-nearby? ally-units ally-bldgs tx ty radius)
  (define u-list : (Listof Any) (if (list? ally-units) ally-units '()))
  (define b-list : (Listof Any) (if (list? ally-bldgs) ally-bldgs '()))
  (define r (max 0.0 (safe-finite-real radius 10.0)))
  (or (for/or : Boolean ([u (in-list u-list)])
        (and (hash? u)
             (let ([ut (dyn-hash-ref u 'type 'unknown)])
               (and (memq ut SC2-MOBILE-DETECTOR-SYMS) #t))
             (<= (dist2d (safe-real (dyn-hash-ref u 'x 999.0) 999.0)
                         (safe-real (dyn-hash-ref u 'y 999.0) 999.0)
                         tx ty)
                 r)))
      (for/or : Boolean ([b (in-list b-list)])
        (and (hash? b)
             (let ([bt (dyn-hash-ref b 'type 'unknown)])
               (and (memq bt SC2-STATIC-DETECTOR-SYMS) #t))
             (>= (safe-real (dyn-hash-ref b 'build-progress 1.0) 1.0)
                 SC2-BUILD-COMPLETE-PROGRESS)
             (<= (dist2d (safe-real (dyn-hash-ref b 'x 999.0) 999.0)
                         (safe-real (dyn-hash-ref b 'y 999.0) 999.0)
                         tx ty)
                 r)))))

;; Blind AoE Skillshot & Emergency Detector Response on Cloaked Shimmer / Burrow Ripples:
;; When an enemy unit is observed with `display-type = 2 (Hidden)`, `cloak-state = 2`,
;; `is-shimmer? = #t`, or burrowed movement ripples (`shimmer-and-burrow-ripples`),
;; fire available AoE / reveal spells (`corrosive-bile`, `psi-storm`, `fungal-growth`,
;; `purification-nova`, `emp-round`, `scanner-sweep`, `oracle-revelation`) at the
;; exact shimmer/ripple coordinates and emit `emergency-detector-response`.
(: execute-shimmer-and-burrow-ripple-response (-> Any (Listof (Listof Any))))
(define (execute-shimmer-and-burrow-ripple-response obs)
  (define sanitized-obs : Any (if (hash? obs) obs (hash)))
  (define ally-raw (dyn-hash-ref sanitized-obs 'ally-units '()))
  (define bldg-raw (dyn-hash-ref sanitized-obs 'ally-buildings '()))
  (define enemy-raw (dyn-hash-ref sanitized-obs 'enemy-units '()))
  (define ripple-raw (dyn-hash-ref sanitized-obs 'shimmer-and-burrow-ripples '()))
  (define ally-units : (Listof Any) (if (list? ally-raw) ally-raw '()))
  (define ally-bldgs : (Listof Any) (if (list? bldg-raw) bldg-raw '()))
  (define enemy-units : (Listof Any) (if (list? enemy-raw) enemy-raw '()))
  (define explicit-ripples : (Listof Any) (if (list? ripple-raw) ripple-raw '()))
  (define shimmer-targets : (Listof Any)
    (append
     (filter hash? explicit-ripples)
     (filter shimmer-target-unit? enemy-units)))
  (cond
    [(null? shimmer-targets) '()]
    [else
     (define tgt (car shimmer-targets))
     (define tx (safe-exact-int (dyn-hash-ref tgt 'x 160) 160))
     (define ty (safe-exact-int (dyn-hash-ref tgt 'y 160) 160))
     (define tx-f (->float tx))
     (define ty-f (->float ty))
     (define kind (dyn-hash-ref tgt 'indicator-kind 'cloaked-shimmer))
     (define actions : (Listof (Listof Any))
       (list (list 'emergency-detector-response kind tx ty)))
     (: emit! (-> (Listof Any) Void))
     (define (emit! a) (set! actions (cons a actions)))

     ;; Check friendly AoE casters / revealers
     (for ([u (in-list ally-units)]
           #:when (hash? u))
       (define uid (dyn-hash-ref u 'id 0))
       (define utype (dyn-hash-ref u 'type 'unknown))
       (define energy (safe-real (dyn-hash-ref u 'energy 75.0) 75.0))
       (case utype
         [(ravager)
          (emit! (list 'blind-skillshot-shimmer uid 'corrosive-bile tx ty))]
         [(high-templar)
          (when (>= energy 75.0)
            (emit! (list 'blind-skillshot-shimmer uid 'psi-storm tx ty)))]
         [(infestor infestor-burrowed)
          (when (>= energy 75.0)
            (emit! (list 'blind-skillshot-shimmer uid 'fungal-growth tx ty)))]
         [(disruptor)
          (emit! (list 'blind-skillshot-shimmer uid 'purification-nova tx ty))]
         [(ghost)
          (when (>= energy 75.0)
            (emit! (list 'blind-skillshot-shimmer uid 'emp-round tx ty)))]
         [(oracle)
          (when (>= energy 25.0)
            (emit! (list 'blind-skillshot-shimmer uid 'oracle-revelation tx ty)))]))

     ;; Emit Scanner Sweep from AT MOST ONE Orbital Command (highest energy >= 50),
     ;; ONLY when friendly combat units are within 13.0 tiles and no Raven/Turret is within 10.0 tiles!
     (define friendly-combat-within-13? : Boolean
       (for/or : Boolean ([u (in-list ally-units)])
         (and (hash? u)
              (let ([ut (dyn-hash-ref u 'type 'unknown)])
                (and (not (memq ut '(scv probe drone drone-burrowed)))
                     (not (sc2-non-combat-or-summon-sym? ut))
                     (not (dyn-hash-ref u 'is-hallucination #f))
                     (<= (dist2d (safe-real (dyn-hash-ref u 'x 999.0) 999.0)
                                 (safe-real (dyn-hash-ref u 'y 999.0) 999.0)
                                 tx-f ty-f)
                         13.0))))))
     (define raven-or-turret-within-10? : Boolean
       (or (for/or : Boolean ([u (in-list ally-units)])
             (and (hash? u)
                  (eq? (dyn-hash-ref u 'type 'unknown) 'raven)
                  (<= (dist2d (safe-real (dyn-hash-ref u 'x 999.0) 999.0)
                              (safe-real (dyn-hash-ref u 'y 999.0) 999.0)
                              tx-f ty-f)
                      10.0)))
           (for/or : Boolean ([b (in-list ally-bldgs)])
             (and (hash? b)
                  (eq? (dyn-hash-ref b 'type 'unknown) 'missile-turret)
                  (>= (safe-real (dyn-hash-ref b 'build-progress 1.0) 1.0)
                      SC2-BUILD-COMPLETE-PROGRESS)
                  (<= (dist2d (safe-real (dyn-hash-ref b 'x 999.0) 999.0)
                              (safe-real (dyn-hash-ref b 'y 999.0) 999.0)
                              tx-f ty-f)
                      10.0)))))
     (when (and friendly-combat-within-13? (not raven-or-turret-within-10?))
       (define best-oc : Any #f)
       (define best-energy : Flonum -inf.0)
       (for ([b (in-list ally-bldgs)]
             #:when (and (hash? b)
                         (eq? (dyn-hash-ref b 'type 'unknown) 'orbital-command)
                         (>= (safe-real (dyn-hash-ref b 'build-progress 1.0) 1.0)
                             SC2-BUILD-COMPLETE-PROGRESS)))
         (define en (safe-real (dyn-hash-ref b 'energy 50.0) 50.0))
         (when (and (>= en 50.0) (> en best-energy))
           (set! best-energy en)
           (set! best-oc b)))
       (when best-oc
         (emit! (list 'blind-skillshot-shimmer (dyn-hash-ref best-oc 'id 0) 'scanner-sweep tx ty))))

     (reverse actions)]))
