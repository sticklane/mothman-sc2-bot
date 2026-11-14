#lang typed/racket/base

;; =============================================================================
;; `lib/tactics/disruptor-micro.rkt`
;; Protoss Disruptor (`694`) & Purification Nova (`733` / Ability `2346`)
;; Comprehensive Offensive & Defensive Micro Module (Typed Racket):
;;
;; Offensive Micro:
;;   - `plan-disruptor-nova-casts`     : Ground-cluster optimization, 145 (+55 shield)
;;                                       splash scoring, 2.0x friendly-fire guard,
;;                                       min-value gate, reach clamp, >= 4.0-tile
;;                                       volley de-confliction across casters/Novas
;;   - `steer-purification-novas`      : Per-step homing for friendly `DisruptorPhased`
;;                                       (`733`) projectiles onto best reachable
;;                                       enemy ground cluster (with anti-FF escape)
;;   - `kite-disruptor-casters`        : Weaponless standoff (10.5-12.0 ready) &
;;                                       cooldown retreat (13.0-15.0 behind army),
;;                                       never emitting `attack-unit` / `attack-move`
;;
;; Defensive & Counter-Play Micro:
;;   - `purification-nova-unit?`       : Invulnerable `disruptor-phased` (`733`) guard
;;   - `plan-anti-nova-scatter`        : Velocity-ray + radial/perpendicular split
;;                                       (danger <= 6.5 / corridor <= 9.5), any-HP
;;                                       emergency Stalker Blink (< 2.75 tiles),
;;                                       and pre-split spacing near ready casters
;;   - `evaluate-disruptor-snipe-and-cooldowns`
;;                                     : Enemy Disruptor 480-frame cooldown tracking
;;                                       & lethal active-cast fizzle-snipe scoring
;;   - `step-disruptor-tactical-micro!`: Unified per-frame orchestrator emitting
;;                                       S-expression tactical orders
;; =============================================================================

(require racket/list
         racket/math
         racket/set
         racket/flonum
         racket/fixnum
         typed/racket/unsafe
         "../sc2-types.rkt"
         "../sc2-geometry.rkt"
         (except-in "../sc2-game-constants.rkt" aabb-overlaps?))

;; Safe bridge for inspecting heterogeneous untyped/mutable/immutable unit hashes.
(module dyn-hash-ops racket/base
  (require racket/flonum
           racket/fixnum)
  (provide dyn-hash-ref
           dyn-hash-has-key?
           fast-units-have-disruptor-or-nova?
           fast-unit-nova-eval-raw
           fast-hash-disruptor-kind
           fast-extract-disruptor-entities
           fast-compute-army-anchor-raw
           fast-nearest-kite-threats
           fast-flvec-pick-best-nova-target)
  (define (dyn-hash-ref h k default)
    (if (hash? h)
        (if (procedure? default)
            (hash-ref h k (lambda () default))
            (hash-ref h k default))
        default))
  (define (dyn-hash-has-key? h k)
    (and (hash? h) (hash-has-key? h k)))
  (define (fast-units-have-disruptor-or-nova? units)
    (for/or ([u (in-list units)])
      (and (hash? u)
           (let ([t (hash-ref u 'type #f)])
             (cond
               [(or (eq? t 'disruptor) (eq? t 'disruptor-phased)) #t]
               [(and (symbol? t) (not (eq? t 'unknown)))
                (not (not (memq t '(Disruptor DisruptorPhased disruptor_phased
                                     Disruptor_Phased DISRUPTOR DISRUPTOR-PHASED DISRUPTOR_PHASED))))]
               [else #t])))))
  (define (safe-fl v def)
    (if (rational? v)
        (real->double-flonum v)
        def))
  (define (safe-int v def)
    (cond
      [(exact-integer? v) v]
      [(rational? v)
       (inexact->exact (truncate v))]
      [else def]))
  (define (fast-unit-nova-eval-raw u)
    (cond
      [(not (hash? u))
       (values #f 'unknown 0 0.0 0.0 0.0 0.0 0.0)]
      [(or (eq? (hash-ref u 'hallucination #f) #t)
           (eq? (hash-ref u 'flying #f) #t)
           (eq? (hash-ref u 'flying? #f) #t)
           (eq? (hash-ref u 'is-flying #f) #t)
           (eq? (hash-ref u 'is_flying #f) #t)
           (eq? (hash-ref u 'is-building #f) #t)
           (eq? (hash-ref u 'building? #f) #t)
           (eq? (hash-ref u 'is-structure #f) #t))
       (values #f 'unknown 0 0.0 0.0 0.0 0.0 0.0)]
      [else
       (define has-hp? (hash-has-key? u 'hp))
       (define has-health? (hash-has-key? u 'health))
       (define has-sh? (hash-has-key? u 'shield))
       (define has-shs? (hash-has-key? u 'shields))
       (define hp-alive
         (cond
           [has-hp? (max 0.0 (safe-fl (hash-ref u 'hp 0.0) 0.0))]
           [has-health? (max 0.0 (safe-fl (hash-ref u 'health 0.0) 0.0))]
           [else 0.0]))
       (define sh-alive
         (cond
           [has-sh? (max 0.0 (safe-fl (hash-ref u 'shield 0.0) 0.0))]
           [has-shs? (max 0.0 (safe-fl (hash-ref u 'shields 0.0) 0.0))]
           [else 0.0]))
       (define alive?
         (if (or has-hp? has-health? has-sh? has-shs?)
             (> (+ hp-alive sh-alive) 0.0)
             #t))
       (if (not alive?)
           (values #f 'unknown 0 0.0 0.0 0.0 0.0 0.0)
           (let* ([t (hash-ref u 'type 'unknown)]
                  [ut (if (symbol? t) t 'unknown)]
                  [uid-t (safe-int (hash-ref u 'unit_type 0) 0)]
                  [ux (safe-fl (hash-ref u 'x 0.0) 0.0)]
                  [uy (safe-fl (hash-ref u 'y 0.0) 0.0)]
                  [hp (if (or has-hp? has-health?) hp-alive 80.0)]
                  [raw-r (hash-ref u 'radius #f)]
                  [rad (if (rational? raw-r)
                           (max 0.0 (min 0.65 (real->double-flonum raw-r)))
                           0.0)])
             (values #t ut uid-t ux uy hp sh-alive rad)))]))

  ;; Returns 'disruptor, 'disruptor-phased, #f (definitely neither), or 'check (needs canonical fallback).
  (define (fast-hash-disruptor-kind u)
    (cond
      [(not (hash? u)) #f]
      [else
       (define t (hash-ref u 'type #f))
       (cond
         [(eq? t 'disruptor) 'disruptor]
         [(eq? t 'disruptor-phased) 'disruptor-phased]
         [(and (symbol? t)
               (not (eq? t 'unknown))
               (not (memq t '(Disruptor DisruptorPhased disruptor_phased
                                         Disruptor_Phased DISRUPTOR DISRUPTOR-PHASED DISRUPTOR_PHASED))))
          (define uid-t (safe-int (hash-ref u 'unit_type 0) 0))
          (cond
            [(= uid-t 694) 'disruptor]
            [(= uid-t 733) 'disruptor-phased]
            [else #f])]
         [else 'check])]))

  (define (fast-extract-disruptor-entities units)
    (let loop ([us units] [casters '()] [novas '()] [checks '()])
      (cond
        [(null? us)
         (values (reverse casters) (reverse novas) (reverse checks))]
        [else
         (define u (car us))
         (define kind (fast-hash-disruptor-kind u))
         (cond
           [(eq? kind 'disruptor) (loop (cdr us) (cons u casters) novas checks)]
           [(eq? kind 'disruptor-phased) (loop (cdr us) casters (cons u novas) checks)]
           [(eq? kind 'check) (loop (cdr us) casters novas (cons u checks))]
           [else (loop (cdr us) casters novas checks)])])))

  (define (fast-unit-alive? u)
    (define hp-v (hash-ref u 'hp #f))
    (cond
      [(and (rational? hp-v) (> hp-v 0.0)) #t]
      [else
       (define hl-v (if (eq? hp-v #f) (hash-ref u 'health #f) #f))
       (define sh-v (hash-ref u 'shield #f))
       (define shs-v (if (eq? sh-v #f) (hash-ref u 'shields #f) #f))
       (if (or (not (eq? hp-v #f)) (not (eq? hl-v #f))
               (not (eq? sh-v #f)) (not (eq? shs-v #f)))
           (> (+ (max 0.0 (safe-fl (or hp-v hl-v 0.0) 0.0))
                 (max 0.0 (safe-fl (or sh-v shs-v 0.0) 0.0)))
              0.0)
           #t)]))

  (define (fast-compute-army-anchor-raw ally-units anchor-cache)
    (let loop ([us ally-units] [sx 0.0] [sy 0.0] [cnt 0] [fallback '()])
      (cond
        [(null? us) (values sx sy cnt fallback)]
        [else
         (define u (car us))
         (if (and (hash? u) (fast-unit-alive? u))
             (let* ([t (hash-ref u 'type #f)]
                    [cls (if (symbol? t) (hash-ref anchor-cache t #f) #f)])
               (cond
                 [(not cls)
                  (loop (cdr us) sx sy cnt (cons u fallback))]
                 [(eq? cls 'skip)
                  (loop (cdr us) sx sy cnt fallback)]
                 [(or (eq? (hash-ref u 'is-building #f) #t)
                      (eq? (hash-ref u 'building? #f) #t)
                      (eq? (hash-ref u 'is-structure #f) #t)
                      (let ([uid-t (hash-ref u 'unit_type #f)])
                        (and (exact-integer? uid-t) (or (= uid-t 694) (= uid-t 733)))))
                  (loop (cdr us) sx sy cnt fallback)]
                 [else
                  (loop (cdr us)
                        (fl+ sx (safe-fl (hash-ref u 'x 0.0) 0.0))
                        (fl+ sy (safe-fl (hash-ref u 'y 0.0) 0.0))
                        (fx+ cnt 1)
                        fallback)]))
             (loop (cdr us) sx sy cnt fallback))])))

  (define (fast-nearest-kite-threats enemy-units cxs cys k)
    (define min-xs (make-flvector k 0.0))
    (define min-ys (make-flvector k 0.0))
    (define min-d2s (make-flvector k +inf.0))
    (define threat-cnt 0)
    (for ([e (in-list enemy-units)])
      (when (and (hash? e)
                 (not (eq? (hash-ref e 'hallucination #f) #t)))
        (define t (hash-ref e 'type #f))
        (define is-nova?
          (or (eq? t 'disruptor-phased)
              (and (symbol? t)
                   (memq t '(DisruptorPhased disruptor_phased Disruptor_Phased DISRUPTOR-PHASED DISRUPTOR_PHASED)))
              (let ([uid-t (hash-ref e 'unit_type #f)])
                (and (exact-integer? uid-t) (= uid-t 733)))))
        (when (and (not is-nova?) (fast-unit-alive? e))
          (define ex (safe-fl (hash-ref e 'x 0.0) 0.0))
          (define ey (safe-fl (hash-ref e 'y 0.0) 0.0))
          (set! threat-cnt (fx+ threat-cnt 1))
          (let loop-j ([j 0])
            (when (fx< j k)
              (define dx (fl- (flvector-ref cxs j) ex))
              (define dy (fl- (flvector-ref cys j) ey))
              (define d2 (fl+ (fl* dx dx) (fl* dy dy)))
              (when (fl< d2 (flvector-ref min-d2s j))
                (flvector-set! min-d2s j d2)
                (flvector-set! min-xs j ex)
                (flvector-set! min-ys j ey))
              (loop-j (fx+ j 1)))))))
    (values min-xs min-ys min-d2s threat-cnt))

  (define (fast-flvec-pick-best-nova-target
           e-cnt near-cnt exv eyv ehrv ehr2v ecv
           a-hit-cnt a-cnt axv ayv ahrv ahr2v acv
           res-cnt rxv ryv
           ox oy max-r dec-d pmin pmax)
    (define max-r2 (fl* max-r max-r))
    (define dec2 (fl* dec-d dec-d))
    (define has-res? (fx> res-cnt 0))
    (define seen (make-hasheqv))
    (define found? #f)
    (define best-x 0.0)
    (define best-y 0.0)
    (define best-net -999999.0)
    (define best-ehits 0)
    (define best-ahits 0)
    (define best-eraw 0.0)
    (define best-apen 0.0)
    (define best-od2 +inf.0)

    (define (score-and-update! cx cy od2)
      (define clear?
        (if has-res?
            (let rloop ([r 0])
              (cond
                [(fx>= r res-cnt) #t]
                [else
                 (define rdx (fl- cx (flvector-ref rxv r)))
                 (define rdy (fl- cy (flvector-ref ryv r)))
                 (if (fl>= (fl+ (fl* rdx rdx) (fl* rdy rdy)) dec2)
                     (rloop (fx+ r 1))
                     #f)]))
            #t))
      (when clear?
        (define eraw 0.0)
        (define ehits 0)
        (let eloop ([i 0])
          (when (fx< i e-cnt)
            (define hr (flvector-ref ehrv i))
            (define dx (flabs (fl- cx (flvector-ref exv i))))
            (when (fl<= dx hr)
              (define dy (flabs (fl- cy (flvector-ref eyv i))))
              (when (and (fl<= dy hr)
                         (fl<= (fl+ (fl* dx dx) (fl* dy dy)) (flvector-ref ehr2v i)))
                (set! eraw (fl+ eraw (flvector-ref ecv i)))
                (set! ehits (fx+ ehits 1))))
            (eloop (fx+ i 1))))
        (define apen 0.0)
        (define ahits 0)
        (let aloop ([i 0])
          (when (fx< i a-hit-cnt)
            (define hr (flvector-ref ahrv i))
            (define dx (flabs (fl- cx (flvector-ref axv i))))
            (when (fl<= dx hr)
              (define dy (flabs (fl- cy (flvector-ref ayv i))))
              (when (and (fl<= dy hr)
                         (fl<= (fl+ (fl* dx dx) (fl* dy dy)) (flvector-ref ahr2v i)))
                (set! apen (fl+ apen (flvector-ref acv i)))
                (set! ahits (fx+ ahits 1))))
            (aloop (fx+ i 1))))
        (define net (fl- eraw apen))
        (when (or (not found?)
                  (fl> net best-net)
                  (and (fl= net best-net) (fl< od2 best-od2)))
          (set! found? #t)
          (set! best-x cx)
          (set! best-y cy)
          (set! best-net net)
          (set! best-ehits ehits)
          (set! best-ahits ahits)
          (set! best-eraw eraw)
          (set! best-apen apen)
          (set! best-od2 od2))))

    (define (try-cand! raw-x raw-y)
      (define cx (flmin pmax (flmax pmin raw-x)))
      (define cy (flmin pmax (flmax pmin raw-y)))
      (define dx (fl- ox cx))
      (define dy (fl- oy cy))
      (define od2 (fl+ (fl* dx dx) (fl* dy dy)))
      (when (fl<= od2 max-r2)
        (define qx (inexact->exact (flround (fl* cx 2.0))))
        (define qy (inexact->exact (flround (fl* cy 2.0))))
        (define key (+ (* qx 4096) qy))
        (unless (hash-ref seen key #f)
          (hash-set! seen key #t)
          (score-and-update! cx cy od2))))

    (let loop-i ([i 0])
      (when (fx< i near-cnt)
        (define x1 (flvector-ref exv i))
        (define y1 (flvector-ref eyv i))
        (try-cand! x1 y1)
        (define sx 0.0)
        (define sy 0.0)
        (define cnt 0)
        (let loop-j ([j 0])
          (when (fx< j near-cnt)
            (define x2 (flvector-ref exv j))
            (define y2 (flvector-ref eyv j))
            (define dx (flabs (fl- x1 x2)))
            (define dy (flabs (fl- y1 y2)))
            (when (and (fl<= dx 3.05) (fl<= dy 3.05))
              (define d2 (fl+ (fl* dx dx) (fl* dy dy)))
              (when (fl<= d2 9.3025)
                (set! sx (fl+ sx x2))
                (set! sy (fl+ sy y2))
                (set! cnt (fx+ cnt 1))
                (when (and (fx> j i) (fl> d2 0.01))
                  (try-cand! (fl* 0.5 (fl+ x1 x2)) (fl* 0.5 (fl+ y1 y2))))))
            (loop-j (fx+ j 1))))
        (when (fx> cnt 1)
          (define fcnt (->fl cnt))
          (try-cand! (fl/ sx fcnt) (fl/ sy fcnt)))
        (when (fx> a-cnt 0)
          (define acx 0.0)
          (define acy 0.0)
          (define acnt 0)
          (let loop-a ([a 0])
            (when (fx< a a-cnt)
              (define axu (flvector-ref axv a))
              (define ayu (flvector-ref ayv a))
              (define dx (fl- x1 axu))
              (define dy (fl- y1 ayu))
              (when (and (fl<= (flabs dx) 3.5)
                         (fl<= (flabs dy) 3.5)
                         (fl<= (fl+ (fl* dx dx) (fl* dy dy)) 12.25))
                (set! acx (fl+ acx axu))
                (set! acy (fl+ acy ayu))
                (set! acnt (fx+ acnt 1)))
              (loop-a (fx+ a 1))))
          (when (fx> acnt 0)
            (define facnt (->fl acnt))
            (define away-x (fl- x1 (fl/ acx facnt)))
            (define away-y (fl- y1 (fl/ acy facnt)))
            (define mag2 (fl+ (fl* away-x away-x) (fl* away-y away-y)))
            (when (fl> mag2 0.0025)
              (define mag (flsqrt mag2))
              (try-cand! (fl+ x1 (fl* 1.15 (fl/ away-x mag)))
                         (fl+ y1 (fl* 1.15 (fl/ away-y mag)))))))
        (loop-i (fx+ i 1))))
    (values found? best-x best-y best-net best-ehits best-ahits best-eraw best-apen)))

(unsafe-require/typed (submod "." dyn-hash-ops)
  [dyn-hash-ref (-> Any Any Any Any)]
  [dyn-hash-has-key? (-> Any Any Boolean)]
  [fast-units-have-disruptor-or-nova? (-> (Listof Any) Boolean)]
  [fast-unit-nova-eval-raw (-> Any (Values Boolean Symbol Integer Float Float Float Float Float))]
  [fast-hash-disruptor-kind (-> Any (U Boolean Symbol))]
  [fast-extract-disruptor-entities (-> (Listof Any) (Values (Listof Any) (Listof Any) (Listof Any)))]
  [fast-compute-army-anchor-raw (-> (Listof Any) (HashTable Symbol Symbol) (Values Float Float Fixnum (Listof Any)))]
  [fast-nearest-kite-threats (-> (Listof Any) FlVector FlVector Fixnum (Values FlVector FlVector FlVector Fixnum))]
  [fast-flvec-pick-best-nova-target
   (-> Fixnum Fixnum FlVector FlVector FlVector FlVector FlVector
       Fixnum Fixnum FlVector FlVector FlVector FlVector FlVector
       Fixnum FlVector FlVector
       Float Float Float Float Float Float
       (Values Boolean Float Float Float Integer Integer Float Float))])

(provide
 ;; LotV Disruptor & Purification Nova constants
 DISRUPTOR-UNIT-TYPE-ID
 DISRUPTOR-PHASED-UNIT-TYPE-ID
 PURIFICATION-NOVA-ABILITY-ID
 DISRUPTOR-NOVA-SPLASH-RADIUS
 DISRUPTOR-NOVA-BASE-DAMAGE
 DISRUPTOR-NOVA-SHIELD-BONUS
 DISRUPTOR-NOVA-LIFETIME-FRAMES
 DISRUPTOR-NOVA-COOLDOWN-FRAMES
 DISRUPTOR-NOVA-SPEED
 DISRUPTOR-NOVA-SPEED-PER-FRAME
 DISRUPTOR-CAST-RANGE
 DISRUPTOR-MAX-REACH-RANGE
 DISRUPTOR-STANDOFF-MIN-DIST
 DISRUPTOR-STANDOFF-MAX-DIST
 DISRUPTOR-RETREAT-MIN-DIST
 DISRUPTOR-RETREAT-MAX-DIST
 DISRUPTOR-MIN-WORTHWHILE-SCORE
 DISRUPTOR-VOLLEY-DECONFLICT-DIST
 DISRUPTOR-ANTI-NOVA-DANGER-RADIUS
 DISRUPTOR-ANTI-NOVA-CONE-RANGE
 DISRUPTOR-BLINK-DODGE-RADIUS
 DISRUPTOR-BLINK-COOLDOWN-FRAMES
 DISRUPTOR-PRESPLIT-THREAT-RANGE
 DISRUPTOR-PRESPLIT-SPACING-TARGET

 ;; Output & state structs
 (struct-out nova-impact-score)
 (struct-out nova-cast-plan)
 (struct-out nova-steer-order)
 (struct-out disruptor-kite-order)
 (struct-out anti-nova-dodge-order)
 (struct-out disruptor-snipe-eval)

 ;; Tracker management & accessors
 disruptor-tactical-tracker?
 make-disruptor-tactical-tracker
 disruptor-tracker-enemy-cooldown
 disruptor-tracker-enemy-active-nova-frames
 disruptor-tracker-friendly-cooldown
 disruptor-tracker-stalker-blink-cooldown
 disruptor-tracker-nova-velocity

 ;; Predicates & scoring
 purification-nova-unit?
 disruptor-caster-unit?
 ground-nova-vulnerable-unit?
 filter-targetable-ground-units
 score-purification-nova-impact

 ;; Offensive & defensive tactical planners
 plan-disruptor-nova-casts
 steer-purification-novas
 kite-disruptor-casters
 plan-anti-nova-scatter
 evaluate-disruptor-snipe-and-cooldowns
 step-disruptor-tactical-micro!)

;; =============================================================================
;; Constants (LotV Balance / 22.4 Faster-speed frames)
;; =============================================================================

(: DISRUPTOR-UNIT-TYPE-ID Integer)
(define DISRUPTOR-UNIT-TYPE-ID 694)

(: DISRUPTOR-PHASED-UNIT-TYPE-ID Integer)
(define DISRUPTOR-PHASED-UNIT-TYPE-ID 733)

(: PURIFICATION-NOVA-ABILITY-ID Integer)
(define PURIFICATION-NOVA-ABILITY-ID 2346)

(: DISRUPTOR-NOVA-SPLASH-RADIUS Float)
(define DISRUPTOR-NOVA-SPLASH-RADIUS 1.5)

(: DISRUPTOR-NOVA-BASE-DAMAGE Float)
(define DISRUPTOR-NOVA-BASE-DAMAGE 145.0)

(: DISRUPTOR-NOVA-SHIELD-BONUS Float)
(define DISRUPTOR-NOVA-SHIELD-BONUS 55.0)

(: DISRUPTOR-NOVA-LIFETIME-FRAMES Integer)
(define DISRUPTOR-NOVA-LIFETIME-FRAMES 47)

(: DISRUPTOR-NOVA-COOLDOWN-FRAMES Integer)
(define DISRUPTOR-NOVA-COOLDOWN-FRAMES 480)

(: DISRUPTOR-NOVA-SPEED Float)
(define DISRUPTOR-NOVA-SPEED 5.95)

(: DISRUPTOR-NOVA-SPEED-PER-FRAME Float)
(define DISRUPTOR-NOVA-SPEED-PER-FRAME (/ 5.95 22.4))

(: DISRUPTOR-CAST-RANGE Float)
(define DISRUPTOR-CAST-RANGE 10.0)

(: DISRUPTOR-MAX-REACH-RANGE Float)
(define DISRUPTOR-MAX-REACH-RANGE 13.0)

(: DISRUPTOR-STANDOFF-MIN-DIST Float)
(define DISRUPTOR-STANDOFF-MIN-DIST 10.5)

(: DISRUPTOR-STANDOFF-MAX-DIST Float)
(define DISRUPTOR-STANDOFF-MAX-DIST 12.0)

(: DISRUPTOR-RETREAT-MIN-DIST Float)
(define DISRUPTOR-RETREAT-MIN-DIST 13.0)

(: DISRUPTOR-RETREAT-MAX-DIST Float)
(define DISRUPTOR-RETREAT-MAX-DIST 15.0)

(: DISRUPTOR-MIN-WORTHWHILE-SCORE Float)
(define DISRUPTOR-MIN-WORTHWHILE-SCORE 100.0)

(: DISRUPTOR-VOLLEY-DECONFLICT-DIST Float)
(define DISRUPTOR-VOLLEY-DECONFLICT-DIST 4.0)

(: DISRUPTOR-ANTI-NOVA-DANGER-RADIUS Float)
(define DISRUPTOR-ANTI-NOVA-DANGER-RADIUS 6.5)

(: DISRUPTOR-ANTI-NOVA-CONE-RANGE Float)
(define DISRUPTOR-ANTI-NOVA-CONE-RANGE 9.0)

(: DISRUPTOR-BLINK-DODGE-RADIUS Float)
(define DISRUPTOR-BLINK-DODGE-RADIUS 2.75)

(: DISRUPTOR-BLINK-COOLDOWN-FRAMES Integer)
(define DISRUPTOR-BLINK-COOLDOWN-FRAMES 160)

(: DISRUPTOR-PRESPLIT-THREAT-RANGE Float)
(define DISRUPTOR-PRESPLIT-THREAT-RANGE 14.5)

(: DISRUPTOR-PRESPLIT-SPACING-TARGET Float)
(define DISRUPTOR-PRESPLIT-SPACING-TARGET 3.0)

(: DISRUPTOR-HIGH-VALUE-SYMS (Listof Symbol))
(define DISRUPTOR-HIGH-VALUE-SYMS
  '(lurker lurker-burrowed siege-tank siege-tank-sieged ghost high-templar
    disruptor ravager infestor infestor-burrowed viper colossus immortal archon))

;; =============================================================================
;; Public Data Structs
;; =============================================================================

(struct nova-impact-score
  ([net-score : Float]
   [enemy-hits : Integer]
   [ally-hits : Integer]
   [enemy-raw-value : Float]
   [ally-penalty-value : Float])
  #:transparent)

(struct nova-cast-plan
  ([caster-tag : Integer]
   [tx : Float]
   [ty : Float]
   [expected-score : Float]
   [enemy-hits : Integer]
   [ally-risk : Integer])
  #:transparent)

(struct nova-steer-order
  ([nova-tag : Integer]
   [tx : Float]
   [ty : Float]
   [target-score : Float]
   [hits : Integer])
  #:transparent)

(struct disruptor-kite-order
  ([unit-tag : Integer]
   [action : Symbol]
   [tx : Float]
   [ty : Float]
   [nearest-enemy-dist : Float]
   [state : Symbol]
   [reason : Symbol])
  #:transparent)

(struct anti-nova-dodge-order
  ([unit-tag : Integer]
   [action : Symbol]
   [tx : Float]
   [ty : Float]
   [threat-nova-tag : Integer]
   [dist : Float]
   [reason : Symbol])
  #:transparent)

(struct disruptor-snipe-eval
  ([enemy-tag : Integer]
   [x : Float]
   [y : Float]
   [state : Symbol]
   [cooldown-remaining : Integer]
   [active-nova-frames-left : Integer]
   [snipe-feasible? : Boolean]
   [attacker-tags : (Listof Integer)]
   [projected-burst-dps : Float]
   [effective-ehp : Float])
  #:transparent)

;; =============================================================================
;; Stateful Cross-Frame Tracker (Velocities, Parent Links, 480f/160f Cooldowns)
;; =============================================================================

(struct nova-track-state
  ([x : Float]
   [y : Float]
   [vx : Float]
   [vy : Float]
   [first-frame : Integer]
   [last-frame : Integer]
   [expire-frame : Integer]
   [parent-tag : Integer]
   [friendly? : Boolean])
  #:transparent)

(struct caster-cooldown-state
  ([cooldown-until-frame : Integer]
   [active-nova-tag : Integer]
   [nova-expire-frame : Integer])
  #:transparent)

(struct disruptor-tactical-tracker
  ([nova-table : (Mutable-HashTable Integer nova-track-state)]
   [enemy-casters : (Mutable-HashTable Integer caster-cooldown-state)]
   [friendly-casters : (Mutable-HashTable Integer Integer)]
   [stalker-blinks : (Mutable-HashTable Integer Integer)]))

(: make-disruptor-tactical-tracker (-> disruptor-tactical-tracker))
(define (make-disruptor-tactical-tracker)
  (disruptor-tactical-tracker
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)
   (make-hasheqv)))

(: disruptor-tracker-enemy-cooldown (-> disruptor-tactical-tracker Integer Integer Integer))
(define (disruptor-tracker-enemy-cooldown tr enemy-tag current-frame)
  (define st (hash-ref (disruptor-tactical-tracker-enemy-casters tr) enemy-tag (lambda () #f)))
  (if st
      (max 0 (- (caster-cooldown-state-cooldown-until-frame st) current-frame))
      0))

(: disruptor-tracker-enemy-active-nova-frames (-> disruptor-tactical-tracker Integer Integer Integer))
(define (disruptor-tracker-enemy-active-nova-frames tr enemy-tag current-frame)
  (define st (hash-ref (disruptor-tactical-tracker-enemy-casters tr) enemy-tag (lambda () #f)))
  (if (and st (> (caster-cooldown-state-active-nova-tag st) 0))
      (max 0 (- (caster-cooldown-state-nova-expire-frame st) current-frame))
      0))

(: disruptor-tracker-friendly-cooldown (-> disruptor-tactical-tracker Integer Integer Integer))
(define (disruptor-tracker-friendly-cooldown tr unit-tag current-frame)
  (define until (hash-ref (disruptor-tactical-tracker-friendly-casters tr) unit-tag (lambda () 0)))
  (max 0 (- until current-frame)))

(: disruptor-tracker-stalker-blink-cooldown (-> disruptor-tactical-tracker Integer Integer Integer))
(define (disruptor-tracker-stalker-blink-cooldown tr unit-tag current-frame)
  (define until (hash-ref (disruptor-tactical-tracker-stalker-blinks tr) unit-tag (lambda () 0)))
  (max 0 (- until current-frame)))

(: disruptor-tracker-nova-velocity (-> disruptor-tactical-tracker Integer (Values Float Float Boolean)))
(define (disruptor-tracker-nova-velocity tr nova-tag)
  (define st (hash-ref (disruptor-tactical-tracker-nova-table tr) nova-tag (lambda () #f)))
  (if st
      (let ([vx (nova-track-state-vx st)]
            [vy (nova-track-state-vy st)])
        (values vx vy (> (+ (* vx vx) (* vy vy)) 0.0025)))
      (values 0.0 0.0 #f)))

;; =============================================================================
;; Internal Unit Attribute & Vector Helpers
;; =============================================================================

(: unit-tag-int (-> Any Integer))
(define (unit-tag-int u)
  (if (hash? u)
      (let ([t (dyn-hash-ref u 'tag #f)])
        (if (exact-integer? t)
            t
            (safe-exact-int (dyn-hash-ref u 'id 0) 0)))
      0))

(: resolved-unit-type (-> Any Symbol))
(define (resolved-unit-type u)
  (cond
    [(symbol? u) (sc2-canonical-unit-sym u)]
    [(exact-integer? u)
     (cond
       [(= u DISRUPTOR-UNIT-TYPE-ID) 'disruptor]
       [(= u DISRUPTOR-PHASED-UNIT-TYPE-ID) 'disruptor-phased]
       [(= u 74) 'stalker]
       [else 'unknown])]
    [(hash? u)
     (define ut (unit-type-sym u))
     (define uid-type (safe-exact-int (dyn-hash-ref u 'unit_type 0) 0))
     (cond
       [(not (eq? ut 'unknown)) (sc2-canonical-unit-sym ut)]
       [(= uid-type DISRUPTOR-UNIT-TYPE-ID) 'disruptor]
       [(= uid-type DISRUPTOR-PHASED-UNIT-TYPE-ID) 'disruptor-phased]
       [(= uid-type 74) 'stalker]
       [else 'unknown])]
    [else 'unknown]))

(: unit-x (-> Any Float))
(define (unit-x u)
  (safe-finite-real (dyn-hash-ref u 'x 0.0) 0.0))

(: unit-y (-> Any Float))
(define (unit-y u)
  (safe-finite-real (dyn-hash-ref u 'y 0.0) 0.0))

(: unit-hp (-> Any Float Float))
(define (unit-hp u default-hp)
  (cond
    [(dyn-hash-has-key? u 'hp) (max 0.0 (safe-finite-real (dyn-hash-ref u 'hp default-hp) default-hp))]
    [(dyn-hash-has-key? u 'health) (max 0.0 (safe-finite-real (dyn-hash-ref u 'health default-hp) default-hp))]
    [else default-hp]))

(: unit-shield (-> Any Float Float))
(define (unit-shield u default-shield)
  (cond
    [(dyn-hash-has-key? u 'shield) (max 0.0 (safe-finite-real (dyn-hash-ref u 'shield default-shield) default-shield))]
    [(dyn-hash-has-key? u 'shields) (max 0.0 (safe-finite-real (dyn-hash-ref u 'shields default-shield) default-shield))]
    [else default-shield]))

(: unit-alive? (-> Any Boolean))
(define (unit-alive? u)
  (if (or (dyn-hash-has-key? u 'hp)
          (dyn-hash-has-key? u 'health)
          (dyn-hash-has-key? u 'shield)
          (dyn-hash-has-key? u 'shields))
      (> (+ (unit-hp u 0.0) (unit-shield u 0.0)) 0.0)
      #t))

(: unit-is-flying? (-> Any Boolean))
(define (unit-is-flying? u)
  (define ut (resolved-unit-type u))
  (not (not (or (eq? (dyn-hash-ref u 'flying #f) #t)
                (eq? (dyn-hash-ref u 'flying? #f) #t)
                (eq? (dyn-hash-ref u 'is-flying #f) #t)
                (eq? (dyn-hash-ref u 'is_flying #f) #t)
                (sc2-unit-is-flying-sym? ut)))))

(: unit-is-structure? (-> Any Boolean))
(define (unit-is-structure? u)
  (define ut (resolved-unit-type u))
  (not (not (or (eq? (dyn-hash-ref u 'is-building #f) #t)
                (eq? (dyn-hash-ref u 'building? #f) #t)
                (eq? (dyn-hash-ref u 'is-structure #f) #t)
                (memq ut SC2-ALL-STRUCTURE-SYMS)
                (memq ut '(auto-turret point-defense-drone interceptor))))))

(: unit-radius-bonus (-> Any Float Float))
(define (unit-radius-bonus u extra-margin)
  (define raw
    (if (dyn-hash-has-key? u 'radius)
        (clamp-real (safe-finite-real (dyn-hash-ref u 'radius 0.0) 0.0) 0.0 0.65)
        0.0))
  (+ raw extra-margin))

(: clamp-to-playable (-> Real Real point2d))
(define (clamp-to-playable x y)
  (clamp-point-to-map (point2d (->float x) (->float y))
                      SC2-MAP-PLAYABLE-MIN-COORD
                      SC2-MAP-PLAYABLE-MAX-COORD))

(: unit-vec-2d (-> Real Real (Values Float Float Float)))
(define (unit-vec-2d dx dy)
  (define fx (->float dx))
  (define fy (->float dy))
  (define sq (max 0.0 (+ (* fx fx) (* fy fy))))
  (define mag : Float (if (> sq 0.0) (assert (sqrt sq) flonum?) 0.0))
  (if (> mag 1e-6)
      (values (/ fx mag) (/ fy mag) mag)
      (values 0.0 0.0 0.0)))

(: stalker-unit? (-> Any Boolean))
(define (stalker-unit? u)
  (eq? (resolved-unit-type u) 'stalker))

(: explicit-nova-order? (-> Any Boolean))
(define (explicit-nova-order? u)
  (define orders (dyn-hash-ref u 'orders '()))
  (and (list? orders)
       (for/or : Boolean ([o (in-list orders)])
         (cond
           [(eq? o 'purification-nova) #t]
           [(exact-integer? o) (= o PURIFICATION-NOVA-ABILITY-ID)]
           [(pair? o)
            (or (eq? (car o) 'purification-nova)
                (equal? (car o) PURIFICATION-NOVA-ABILITY-ID))]
           [(hash? o)
            (define aid (dyn-hash-ref o 'ability_id #f))
            (define asym (dyn-hash-ref o 'ability #f))
            (or (equal? aid PURIFICATION-NOVA-ABILITY-ID)
                (eq? asym 'purification-nova)
                (eq? asym 'purification-nova-targeted))]
           [else #f]))))

(: explicit-order-target-point (-> Any (Option point2d)))
(define (explicit-order-target-point u)
  (define orders (dyn-hash-ref u 'orders '()))
  (and (list? orders)
       (for/or : (Option point2d) ([o (in-list orders)])
         (cond
           [(hash? o)
            (define tx (dyn-hash-ref o 'target_x (dyn-hash-ref o 'tx #f)))
            (define ty (dyn-hash-ref o 'target_y (dyn-hash-ref o 'ty #f)))
            (and (finite-real? tx) (finite-real? ty)
                 (point2d (safe-finite-real tx 0.0) (safe-finite-real ty 0.0)))]
           [else #f]))))

;; =============================================================================
;; Public Unit Predicates & Target Filtering
;; =============================================================================

;; Identify phased Purification Nova projectiles (`DisruptorPhased` 733),
;; which are completely invulnerable and must NEVER be targeted by attacks/spells.
(: purification-nova-unit? (-> Any Boolean))
(define (purification-nova-unit? u)
  (cond
    [(symbol? u) (eq? (sc2-canonical-unit-sym u) 'disruptor-phased)]
    [(exact-integer? u) (= u DISRUPTOR-PHASED-UNIT-TYPE-ID)]
    [(hash? u)
     (define kind (fast-hash-disruptor-kind u))
     (cond
       [(eq? kind 'disruptor-phased) #t]
       [(not (eq? kind 'check)) #f]
       [else
        (define ut (unit-type-sym u))
        (define uid-type (safe-exact-int (dyn-hash-ref u 'unit_type 0) 0))
        (not (not (or (eq? ut 'disruptor-phased)
                      (eq? (sc2-canonical-unit-sym ut) 'disruptor-phased)
                      (= uid-type DISRUPTOR-PHASED-UNIT-TYPE-ID))))])]
    [else #f]))

;; Identify Protoss Disruptor caster units (`694`), which have NO auto-attack weapon.
(: disruptor-caster-unit? (-> Any Boolean))
(define (disruptor-caster-unit? u)
  (cond
    [(symbol? u) (eq? (sc2-canonical-unit-sym u) 'disruptor)]
    [(exact-integer? u) (= u DISRUPTOR-UNIT-TYPE-ID)]
    [(hash? u)
     (define kind (fast-hash-disruptor-kind u))
     (cond
       [(eq? kind 'disruptor) #t]
       [(not (eq? kind 'check)) #f]
       [else (eq? (resolved-unit-type u) 'disruptor)])]
    [else #f]))

;; Fast zero-allocation predicate matching both `'disruptor` (694) and `'disruptor-phased` (733).
(: fast-disruptor-or-nova? (-> Any Boolean))
(define (fast-disruptor-or-nova? u)
  (define kind (fast-hash-disruptor-kind u))
  (cond
    [(or (eq? kind 'disruptor) (eq? kind 'disruptor-phased)) #t]
    [(not (eq? kind 'check)) #f]
    [else (or (disruptor-caster-unit? u) (purification-nova-unit? u))]))

(: extract-disruptor-casters+novas (-> (Listof Any) (Values (Listof Any) (Listof Any))))
(define (extract-disruptor-casters+novas units)
  (define-values (casters novas checks) (fast-extract-disruptor-entities units))
  (if (null? checks)
      (values casters novas)
      (values (append casters (filter disruptor-caster-unit? checks))
              (append novas (filter purification-nova-unit? checks)))))

;; Filter `units` to those within Euclidean `radius` (e.g. 15.0 tiles) of any reference unit in `refs`.
(: filter-units-within-range (-> (Listof Any) (Listof Any) Float (Listof Any)))
(define (filter-units-within-range units refs radius)
  (if (or (null? refs) (null? units))
      '()
      (let ([ref-pts : (Listof (Pairof Float Float))
                     (for/list : (Listof (Pairof Float Float)) ([r (in-list refs)])
                       (cons (unit-x r) (unit-y r)))]
            [r2 (* radius radius)])
        (filter (lambda ([u : Any])
                  (and (hash? u)
                       (let ([ux (unit-x u)]
                             [uy (unit-y u)])
                         (for/or : Boolean ([pt (in-list ref-pts)])
                           (define dx (- ux (car pt)))
                           (define dy (- uy (cdr pt)))
                           (and (<= (abs dx) radius)
                                (<= (abs dy) radius)
                                (<= (+ (* dx dx) (* dy dy)) r2))))))
                units))))

(: internal-skip-sync? (Parameterof Boolean))
(define internal-skip-sync? (make-parameter #f))

(: internal-ally-casters (Parameterof (Option (Listof Any))))
(define internal-ally-casters (make-parameter #f))

(: internal-ally-novas (Parameterof (Option (Listof Any))))
(define internal-ally-novas (make-parameter #f))

(: internal-enemy-casters (Parameterof (Option (Listof Any))))
(define internal-enemy-casters (make-parameter #f))

(: internal-enemy-novas (Parameterof (Option (Listof Any))))
(define internal-enemy-novas (make-parameter #f))

(: CANONICAL-ANCHOR-CLASS-CACHE (HashTable Symbol Symbol))
(define CANONICAL-ANCHOR-CLASS-CACHE (make-hasheq))

;; Return #t iff `u` is a living, non-hallucination ground non-structure unit
;; susceptible to Purification Nova splash damage.
(: ground-nova-vulnerable-unit? (-> Any Boolean))
(define (ground-nova-vulnerable-unit? u)
  (and (hash? u)
       (not (purification-nova-unit? u))
       (not (eq? (dyn-hash-ref u 'hallucination #f) #t))
       (unit-alive? u)
       (let ([ut (resolved-unit-type u)])
         (and (not (memq ut SC2-UNTARGETABLE-OR-DECOY-UNIT-SYMS))
              (not (unit-is-flying? u))
              (not (unit-is-structure? u))))))

;; Filter a list of enemy (or ally) hashes down to targetable ground units,
;; excluding `disruptor-phased`, decoys, air units, hallucinations, and buildings.
(: filter-targetable-ground-units (-> (Listof Any) (Listof Any)))
(define (filter-targetable-ground-units units)
  (filter ground-nova-vulnerable-unit? units))

;; =============================================================================
;; Splash Cluster Scoring (`145 + 55 shield`, 1.5 radius, 2.0x FF penalty)
;; =============================================================================

(: unit-nova-replacement-value (-> Any Float))
(define (unit-nova-replacement-value u)
  (define ut (resolved-unit-type u))
  (define min-c (sc2-min-cost ut 50))
  (define gas-c (sc2-gas-cost ut 0))
  (define base (+ (->float min-c) (* 1.25 (->float gas-c))))
  (define tier-mult (if (memq ut DISRUPTOR-HIGH-VALUE-SYMS) 1.15 1.0))
  (* base tier-mult))

(: effective-nova-damage-fraction (-> Any Float Float))
(define (effective-nova-damage-fraction u unit-val)
  (define hp (unit-hp u 80.0))
  (define sh (unit-shield u 0.0))
  (define ehp (+ hp sh))
  (define nova-dmg
    (if (> sh 0.0)
        (+ DISRUPTOR-NOVA-BASE-DAMAGE DISRUPTOR-NOVA-SHIELD-BONUS)
        DISRUPTOR-NOVA-BASE-DAMAGE))
  (define frac (if (> ehp 0.0) (min 1.0 (/ nova-dmg ehp)) 1.0))
  (define kill-mult (if (<= ehp nova-dmg) 1.15 0.85))
  (* unit-val frac kill-mult))

(struct nova-eval-unit
  ([x : Float]
   [y : Float]
   [hit-r : Float]
   [hit-r2 : Float]
   [contrib : Float])
  #:transparent)

(: precompute-nova-eval-units
   (-> (Listof Any) (Listof (Pairof Float Float)) Float Boolean (Listof nova-eval-unit)))
(define (precompute-nova-eval-units units ref-pts search-radius ally?)
  (if (or (null? units) (null? ref-pts))
      '()
      (let ([sr2 (* search-radius search-radius)]
            [extra-r (if ally? 0.25 0.0)]
            [mult (if ally? 2.0 1.0)])
        (for/fold ([acc : (Listof nova-eval-unit) '()])
                  ([u (in-list units)])
          (define-values (ok? raw-ut uid-type ux uy hp sh rad)
            (fast-unit-nova-eval-raw u))
          (cond
            [(not ok?) acc]
            [(not (for/or : Boolean ([rp (in-list ref-pts)])
                    (define dx (- ux (car rp)))
                    (define dy (- uy (cdr rp)))
                    (and (<= (abs dx) search-radius)
                         (<= (abs dy) search-radius)
                         (<= (+ (* dx dx) (* dy dy)) sr2))))
             acc]
            [else
             (define ut : Symbol
               (cond
                 [(not (eq? raw-ut 'unknown)) (sc2-canonical-unit-sym raw-ut)]
                 [(= uid-type DISRUPTOR-UNIT-TYPE-ID) 'disruptor]
                 [(= uid-type DISRUPTOR-PHASED-UNIT-TYPE-ID) 'disruptor-phased]
                 [(= uid-type 74) 'stalker]
                 [else 'unknown]))
             (cond
               [(or (eq? ut 'disruptor-phased)
                    (= uid-type DISRUPTOR-PHASED-UNIT-TYPE-ID)
                    (memq ut SC2-UNTARGETABLE-OR-DECOY-UNIT-SYMS)
                    (sc2-unit-is-flying-sym? ut)
                    (memq ut SC2-ALL-STRUCTURE-SYMS)
                    (memq ut '(auto-turret point-defense-drone interceptor)))
                acc]
               [else
                (define min-c (sc2-min-cost ut 50))
                (define gas-c (sc2-gas-cost ut 0))
                (define base (+ (->float min-c) (* 1.25 (->float gas-c))))
                (define tier-mult (if (memq ut DISRUPTOR-HIGH-VALUE-SYMS) 1.15 1.0))
                (define uval (* base tier-mult))
                (define ehp (+ hp sh))
                (define nova-dmg
                  (if (> sh 0.0)
                      (+ DISRUPTOR-NOVA-BASE-DAMAGE DISRUPTOR-NOVA-SHIELD-BONUS)
                      DISRUPTOR-NOVA-BASE-DAMAGE))
                (define frac (if (> ehp 0.0) (min 1.0 (/ nova-dmg ehp)) 1.0))
                (define kill-mult (if (<= ehp nova-dmg) 1.15 0.85))
                (define contrib (* mult (* uval frac kill-mult)))
                (define hr (+ DISRUPTOR-NOVA-SPLASH-RADIUS (+ rad extra-r)))
                (cons (nova-eval-unit ux uy hr (* hr hr) contrib) acc)])])))))

(: filter-nova-eval-units-within (-> (Listof nova-eval-unit) Float Float Float (Listof nova-eval-unit)))
(define (filter-nova-eval-units-within evals ox oy max-r)
  (define r2 (* max-r max-r))
  (for/list : (Listof nova-eval-unit) ([eu (in-list evals)]
                                        #:when (let ([dx (- ox (nova-eval-unit-x eu))]
                                                     [dy (- oy (nova-eval-unit-y eu))])
                                                 (and (<= (abs dx) max-r)
                                                      (<= (abs dy) max-r)
                                                      (<= (+ (* dx dx) (* dy dy)) r2))))
    eu))

(: score-nova-eval-impact (-> Float Float (Listof nova-eval-unit) (Listof nova-eval-unit) nova-impact-score))
(define (score-nova-eval-impact ftx fty eval-enemies eval-allies)
  (define-values (enemy-raw enemy-hits)
    (for/fold ([acc : Float 0.0]
               [hits : Integer 0])
              ([eu (in-list eval-enemies)])
      (define dx (abs (- ftx (nova-eval-unit-x eu))))
      (define hr (nova-eval-unit-hit-r eu))
      (if (<= dx hr)
          (let ([dy (abs (- fty (nova-eval-unit-y eu)))])
            (if (and (<= dy hr)
                     (<= (+ (* dx dx) (* dy dy)) (nova-eval-unit-hit-r2 eu)))
                (values (+ acc (nova-eval-unit-contrib eu)) (+ hits 1))
                (values acc hits)))
          (values acc hits))))
  (define-values (ally-pen ally-hits)
    (for/fold ([acc : Float 0.0]
               [hits : Integer 0])
              ([au (in-list eval-allies)])
      (define dx (abs (- ftx (nova-eval-unit-x au))))
      (define hr (nova-eval-unit-hit-r au))
      (if (<= dx hr)
          (let ([dy (abs (- fty (nova-eval-unit-y au)))])
            (if (and (<= dy hr)
                     (<= (+ (* dx dx) (* dy dy)) (nova-eval-unit-hit-r2 au)))
                (values (+ acc (nova-eval-unit-contrib au)) (+ hits 1))
                (values acc hits)))
          (values acc hits))))
  (nova-impact-score (- enemy-raw ally-pen) enemy-hits ally-hits enemy-raw ally-pen))

;; Score placing a Purification Nova detonation at `(tx, ty)` against
;; ground-vulnerable `enemy-units` and `ally-units` within splash radius `1.5`.
(: score-purification-nova-impact (-> Real Real (Listof Any) (Listof Any) nova-impact-score))
(define (score-purification-nova-impact tx ty enemy-units ally-units)
  (define ftx (->float tx))
  (define fty (->float ty))
  (define-values (enemy-raw enemy-hits)
    (for/fold ([acc : Float 0.0]
               [hits : Integer 0])
              ([e (in-list enemy-units)]
               #:when (ground-nova-vulnerable-unit? e))
      (define ex (unit-x e))
      (define ey (unit-y e))
      (if (and (<= (abs (- ftx ex)) 2.5)
               (<= (abs (- fty ey)) 2.5)
               (<= (dist-2d ftx fty ex ey)
                   (+ DISRUPTOR-NOVA-SPLASH-RADIUS (unit-radius-bonus e 0.0))))
          (let* ([uval (unit-nova-replacement-value e)]
                 [contrib (effective-nova-damage-fraction e uval)])
            (values (+ acc contrib) (+ hits 1)))
          (values acc hits))))
  ;; Friendly fire: Disruption hits ally ground units too; apply 2.0x penalty + 0.25m buffer.
  (define-values (ally-pen ally-hits)
    (for/fold ([acc : Float 0.0]
               [hits : Integer 0])
              ([a (in-list ally-units)]
               #:when (ground-nova-vulnerable-unit? a))
      (define ax (unit-x a))
      (define ay (unit-y a))
      (if (and (<= (abs (- ftx ax)) 2.5)
               (<= (abs (- fty ay)) 2.5)
               (<= (dist-2d ftx fty ax ay)
                   (+ DISRUPTOR-NOVA-SPLASH-RADIUS (unit-radius-bonus a 0.25))))
          (let* ([uval (unit-nova-replacement-value a)]
                 [loss (effective-nova-damage-fraction a uval)])
            (values (+ acc (* 2.0 loss)) (+ hits 1)))
          (values acc hits))))
  (nova-impact-score (- enemy-raw ally-pen) enemy-hits ally-hits enemy-raw ally-pen))

;; Generate candidate detonation points covering exact unit positions, 2-unit
;; midpoints (catching pairs <= 3.0 apart), local neighborhood centroids, and
;; ally-avoiding outer offsets (deduplicated on a 0.25-tile grid).
(: generate-nova-candidate-points/eval
   (-> (Listof nova-eval-unit) (Listof nova-eval-unit) Float Float Float (Listof point2d)))
(define (generate-nova-candidate-points/eval eval-enemies eval-allies origin-x origin-y max-range)
  (define e-lim (+ max-range 2.5))
  (define a-lim (+ max-range 5.0))
  (define near-enemies : (Listof nova-eval-unit)
    (let ([filtered (filter-nova-eval-units-within eval-enemies origin-x origin-y e-lim)])
      (if (> (length filtered) 40)
          (take (sort filtered
                      (lambda ([a : nova-eval-unit] [b : nova-eval-unit])
                        (< (dist-sq-2d origin-x origin-y (nova-eval-unit-x a) (nova-eval-unit-y a))
                           (dist-sq-2d origin-x origin-y (nova-eval-unit-x b) (nova-eval-unit-y b)))))
                40)
          filtered)))
  (define near-allies : (Listof nova-eval-unit)
    (filter-nova-eval-units-within eval-allies origin-x origin-y a-lim))
  (define max-r2 (* max-range max-range))
  (define seen : (HashTable Integer Boolean) (make-hasheqv))
  (define raw-pts : (Listof point2d) '())
  (: add-pt! (-> Real Real Void))
  (define (add-pt! x y)
    (define cp (clamp-to-playable x y))
    (define cpx (point2d-x cp))
    (define cpy (point2d-y cp))
    (define dx (- origin-x cpx))
    (define dy (- origin-y cpy))
    (when (<= (+ (* dx dx) (* dy dy)) max-r2)
      (define key : Integer
        (+ (* (exact-round (* cpx 4.0)) 4096)
           (exact-round (* cpy 4.0))))
      (unless (hash-ref seen key #f)
        (hash-set! seen key #t)
        (set! raw-pts (cons cp raw-pts)))))

  (for ([e1 (in-list near-enemies)])
    (define x1 (nova-eval-unit-x e1))
    (define y1 (nova-eval-unit-y e1))
    (add-pt! x1 y1)
    ;; Neighborhood centroid & pair midpoints within 2*radius (~3.05 tiles)
    (define-values (sx sy cnt)
      (for/fold ([ax : Float 0.0]
                 [ay : Float 0.0]
                 [c : Integer 0])
                ([e2 (in-list near-enemies)])
        (define x2 (nova-eval-unit-x e2))
        (define y2 (nova-eval-unit-y e2))
        (define dx (abs (- x1 x2)))
        (define dy (abs (- y1 y2)))
        (if (and (<= dx 3.05) (<= dy 3.05))
            (let ([d2 (+ (* dx dx) (* dy dy))])
              (if (<= d2 9.3025)
                  (begin
                    (when (> d2 0.01)
                      (add-pt! (* 0.5 (+ x1 x2)) (* 0.5 (+ y1 y2))))
                    (values (+ ax x2) (+ ay y2) (+ c 1)))
                  (values ax ay c)))
            (values ax ay c))))
    (when (> cnt 1)
      (add-pt! (/ sx (->float cnt)) (/ sy (->float cnt))))
    ;; Off-center shift away from nearby friendly ground units to avoid friendly fire
    (when (pair? near-allies)
      (define-values (cx cy acnt)
        (for/fold ([ax : Float 0.0]
                   [ay : Float 0.0]
                   [c : Integer 0])
                  ([a (in-list near-allies)])
          (define axu (nova-eval-unit-x a))
          (define ayu (nova-eval-unit-y a))
          (define dx (abs (- x1 axu)))
          (define dy (abs (- y1 ayu)))
          (if (and (<= dx 3.5) (<= dy 3.5) (<= (+ (* dx dx) (* dy dy)) 12.25))
              (values (+ ax axu) (+ ay ayu) (+ c 1))
              (values ax ay c))))
      (when (> acnt 0)
        (define away-x (- x1 (/ cx (->float acnt))))
        (define away-y (- y1 (/ cy (->float acnt))))
        (define-values (ux uy mag) (unit-vec-2d away-x away-y))
        (when (> mag 0.05)
          (add-pt! (+ x1 (* 1.15 ux)) (+ y1 (* 1.15 uy)))))))
  raw-pts)

(: generate-nova-candidate-points (-> (Listof Any) (Listof Any) Float Float Float (Listof point2d)))
(define (generate-nova-candidate-points enemies allies origin-x origin-y max-range)
  (define refs (list (cons origin-x origin-y)))
  (define eval-e (precompute-nova-eval-units enemies refs (+ max-range 2.5) #f))
  (define eval-a (precompute-nova-eval-units allies refs (+ max-range 5.0) #t))
  (generate-nova-candidate-points/eval eval-e eval-a origin-x origin-y max-range))

(: pick-best-nova-target/eval
   (-> (Listof nova-eval-unit) (Listof nova-eval-unit) Float Float Float (Listof point2d) Float
       (Values (Option point2d) nova-impact-score)))
(define (pick-best-nova-target/eval eval-enemies eval-allies origin-x origin-y max-range reserved-pts deconflict-dist)
  (define local-enemies (filter-nova-eval-units-within eval-enemies origin-x origin-y (+ max-range 2.5)))
  (if (null? local-enemies)
      (values #f (nova-impact-score -999999.0 0 0 0.0 0.0))
      (let ()
        (define e-cnt : Integer (length local-enemies))
        (define ordered-enemies : (Listof nova-eval-unit)
          (if (> e-cnt 40)
              (sort local-enemies
                    (lambda ([a : nova-eval-unit] [b : nova-eval-unit])
                      (< (dist-sq-2d origin-x origin-y (nova-eval-unit-x a) (nova-eval-unit-y a))
                         (dist-sq-2d origin-x origin-y (nova-eval-unit-x b) (nova-eval-unit-y b)))))
              local-enemies))
        (define e-fx : Fixnum (assert e-cnt fixnum?))
        (define near-fx : Fixnum (fxmin 40 e-fx))
        (define exv (make-flvector e-fx 0.0))
        (define eyv (make-flvector e-fx 0.0))
        (define ehrv (make-flvector e-fx 0.0))
        (define ehr2v (make-flvector e-fx 0.0))
        (define ecv (make-flvector e-fx 0.0))
        (let eloop ([es ordered-enemies] [i : Fixnum 0])
          (unless (null? es)
            (define eu (car es))
            (flvector-set! exv i (nova-eval-unit-x eu))
            (flvector-set! eyv i (nova-eval-unit-y eu))
            (flvector-set! ehrv i (nova-eval-unit-hit-r eu))
            (flvector-set! ehr2v i (nova-eval-unit-hit-r2 eu))
            (flvector-set! ecv i (nova-eval-unit-contrib eu))
            (eloop (cdr es) (fx+ i 1))))

        (define hit-lim (+ max-range 2.5))
        (define hit-lim2 (* hit-lim hit-lim))
        (define all-lim (+ max-range 5.0))
        (define all-lim2 (* all-lim all-lim))
        (define-values (hit-allies outer-allies)
          (for/fold ([hs : (Listof nova-eval-unit) '()]
                     [os : (Listof nova-eval-unit) '()])
                    ([au (in-list eval-allies)])
            (define dx (- origin-x (nova-eval-unit-x au)))
            (define dy (- origin-y (nova-eval-unit-y au)))
            (if (and (<= (abs dx) all-lim) (<= (abs dy) all-lim))
                (let ([d2 (+ (* dx dx) (* dy dy))])
                  (cond
                    [(<= d2 hit-lim2) (values (cons au hs) os)]
                    [(<= d2 all-lim2) (values hs (cons au os))]
                    [else (values hs os)]))
                (values hs os))))
        (define a-hit-fx : Fixnum (assert (length hit-allies) fixnum?))
        (define a-fx : Fixnum (fx+ a-hit-fx (assert (length outer-allies) fixnum?)))
        (define axv (make-flvector a-fx 0.0))
        (define ayv (make-flvector a-fx 0.0))
        (define ahrv (make-flvector a-fx 0.0))
        (define ahr2v (make-flvector a-fx 0.0))
        (define acv (make-flvector a-fx 0.0))
        (let aloop ([as hit-allies] [i : Fixnum 0] [in-hit? #t])
          (cond
            [(not (null? as))
             (define au (car as))
             (flvector-set! axv i (nova-eval-unit-x au))
             (flvector-set! ayv i (nova-eval-unit-y au))
             (flvector-set! ahrv i (nova-eval-unit-hit-r au))
             (flvector-set! ahr2v i (nova-eval-unit-hit-r2 au))
             (flvector-set! acv i (nova-eval-unit-contrib au))
             (aloop (cdr as) (fx+ i 1) in-hit?)]
            [(and in-hit? (pair? outer-allies))
             (aloop outer-allies i #f)]
            [else (void)]))

        (define res-fx : Fixnum (assert (length reserved-pts) fixnum?))
        (define rxv (make-flvector res-fx 0.0))
        (define ryv (make-flvector res-fx 0.0))
        (let rloop ([rs reserved-pts] [i : Fixnum 0])
          (unless (null? rs)
            (define rp (car rs))
            (flvector-set! rxv i (point2d-x rp))
            (flvector-set! ryv i (point2d-y rp))
            (rloop (cdr rs) (fx+ i 1))))

        (define-values (found? bx by bnet behits bahits beraw bapen)
          (fast-flvec-pick-best-nova-target
           e-fx near-fx exv eyv ehrv ehr2v ecv
           a-hit-fx a-fx axv ayv ahrv ahr2v acv
           res-fx rxv ryv
           origin-x origin-y max-range deconflict-dist
           (->float SC2-MAP-PLAYABLE-MIN-COORD)
           (->float SC2-MAP-PLAYABLE-MAX-COORD)))
        (values (and found? (point2d bx by))
                (nova-impact-score bnet behits bahits beraw bapen)))))

(: pick-best-nova-target
   (-> (Listof Any) (Listof Any) Float Float Float (Listof point2d) Float
       (Values (Option point2d) nova-impact-score)))
(define (pick-best-nova-target ground-enemies ground-allies origin-x origin-y max-range reserved-pts deconflict-dist)
  (define refs (list (cons origin-x origin-y)))
  (define eval-e (precompute-nova-eval-units ground-enemies refs (+ max-range 2.5) #f))
  (define eval-a (precompute-nova-eval-units ground-allies refs (+ max-range 5.0) #t))
  (pick-best-nova-target/eval eval-e eval-a origin-x origin-y max-range reserved-pts deconflict-dist))

;; =============================================================================
;; Tracker State Synchronization (Velocities, Parent Matching, Cooldowns)
;; =============================================================================

(: sync-tracker-state!
   (-> disruptor-tactical-tracker (Listof Any) (Listof Any) Integer Void))
(define (sync-tracker-state! tr ally-units enemy-units current-frame)
  (define nova-ht (disruptor-tactical-tracker-nova-table tr))
  (define enemy-cd-ht (disruptor-tactical-tracker-enemy-casters tr))
  (define friendly-cd-ht (disruptor-tactical-tracker-friendly-casters tr))

  (define-values (ally-casters ally-novas)
    (let ([pc (internal-ally-casters)]
          [pn (internal-ally-novas)])
      (if (and pc pn)
          (values pc pn)
          (extract-disruptor-casters+novas ally-units))))
  (define-values (enemy-casters enemy-novas)
    (let ([pc (internal-enemy-casters)]
          [pn (internal-enemy-novas)])
      (if (and pc pn)
          (values pc pn)
          (extract-disruptor-casters+novas enemy-units))))

  ;; Helper to update a faction's Nova positions/velocities and discover new spawns.
  (: update-nova-list! (-> (Listof Any) (Listof Any) Boolean Void))
  (define (update-nova-list! novas casters friendly?)
    (for ([u (in-list novas)])
      (define ntag (unit-tag-int u))
      (define nx (unit-x u))
      (define ny (unit-y u))
      (define prev (hash-ref nova-ht ntag (lambda () #f)))
      (define explicit-vx (if (dyn-hash-has-key? u 'vx) (safe-finite-real (dyn-hash-ref u 'vx 0.0) 0.0) 0.0))
      (define explicit-vy (if (dyn-hash-has-key? u 'vy) (safe-finite-real (dyn-hash-ref u 'vy 0.0) 0.0) 0.0))
      (define-values (vx vy)
        (cond
          [(> (+ (* explicit-vx explicit-vx) (* explicit-vy explicit-vy)) 0.0025)
           (values explicit-vx explicit-vy)]
          [(and prev (> (- current-frame (nova-track-state-last-frame prev)) 0))
           (define dt-sec (/ (->float (- current-frame (nova-track-state-last-frame prev))) 22.4))
           (define cvx (/ (- nx (nova-track-state-x prev)) dt-sec))
           (define cvy (/ (- ny (nova-track-state-y prev)) dt-sec))
           (if (> (+ (* cvx cvx) (* cvy cvy)) 0.0025)
               (values cvx cvy)
               (values (nova-track-state-vx prev) (nova-track-state-vy prev)))]
          [(dyn-hash-has-key? u 'facing)
           (define ang (safe-finite-real (dyn-hash-ref u 'facing 0.0) 0.0))
           (values (* DISRUPTOR-NOVA-SPEED (cos ang)) (* DISRUPTOR-NOVA-SPEED (sin ang)))]
          [else (values 0.0 0.0)]))
      (define first-f (if prev (nova-track-state-first-frame prev) current-frame))
      (define expire-f
        (if (dyn-hash-has-key? u 'remaining-frames)
            (+ current-frame (max 1 (safe-exact-int (dyn-hash-ref u 'remaining-frames DISRUPTOR-NOVA-LIFETIME-FRAMES) DISRUPTOR-NOVA-LIFETIME-FRAMES)))
            (if prev
                (nova-track-state-expire-frame prev)
                (+ current-frame DISRUPTOR-NOVA-LIFETIME-FRAMES))))
      ;; Match newly observed Nova to nearest parent Disruptor within 3.5 tiles
      (define parent-tag : Integer
        (if (and prev (> (nova-track-state-parent-tag prev) 0))
            (nova-track-state-parent-tag prev)
            (let-values ([(best-p _best-d)
                          (for/fold ([best-p : Integer 0]
                                     [best-d : Float 3.51])
                                    ([c (in-list casters)])
                            (define d (dist-2d nx ny (unit-x c) (unit-y c)))
                            (if (< d best-d)
                                (values (unit-tag-int c) d)
                                (values best-p best-d)))])
              best-p)))
      (hash-set! nova-ht ntag
                 (nova-track-state nx ny vx vy first-f current-frame expire-f parent-tag friendly?))
      (when (> parent-tag 0)
        (if friendly?
            (when (<= (hash-ref friendly-cd-ht parent-tag (lambda () 0)) current-frame)
              (hash-set! friendly-cd-ht parent-tag (+ first-f DISRUPTOR-NOVA-COOLDOWN-FRAMES)))
            (let ([cst (hash-ref enemy-cd-ht parent-tag (lambda () #f))])
              (when (or (not cst)
                        (not (= (caster-cooldown-state-active-nova-tag cst) ntag)))
                (hash-set! enemy-cd-ht parent-tag
                           (caster-cooldown-state
                            (+ first-f DISRUPTOR-NOVA-COOLDOWN-FRAMES)
                            ntag
                            expire-f))))))))

  (unless (null? ally-novas)
    (update-nova-list! ally-novas ally-casters #t))
  (unless (null? enemy-novas)
    (update-nova-list! enemy-novas enemy-casters #f))

  ;; Clear expired active-nova links if Nova vanished or expired
  (define live-enemy-nova-tags : (Setof Integer)
    (if (null? enemy-novas)
        (set)
        (list->set
         (for/list : (Listof Integer) ([u (in-list enemy-novas)])
           (unit-tag-int u)))))
  (unless (null? enemy-casters)
    (for ([ec (in-list enemy-casters)])
      (define etag (unit-tag-int ec))
      (define cst (hash-ref enemy-cd-ht etag (lambda () #f)))
      (when (and cst (> (caster-cooldown-state-active-nova-tag cst) 0))
        (define ant (caster-cooldown-state-active-nova-tag cst))
        (when (or (not (set-member? live-enemy-nova-tags ant))
                  (> current-frame (caster-cooldown-state-nova-expire-frame cst)))
          (hash-set! enemy-cd-ht etag
                     (caster-cooldown-state
                      (caster-cooldown-state-cooldown-until-frame cst)
                      0
                      0))))
      ;; Also honor explicit unit order 2346 or explicit cooldown on hash
      (when (and (explicit-nova-order? ec)
                 (or (not cst) (<= (caster-cooldown-state-cooldown-until-frame cst) current-frame)))
        (hash-set! enemy-cd-ht etag
                   (caster-cooldown-state
                    (+ current-frame DISRUPTOR-NOVA-COOLDOWN-FRAMES)
                    (if cst (caster-cooldown-state-active-nova-tag cst) -1)
                    (+ current-frame DISRUPTOR-NOVA-LIFETIME-FRAMES))))))

  ;; Prune dead/expired Novas from nova-table
  (unless (zero? (hash-count nova-ht))
    (define live-all-novas : (Setof Integer)
      (if (null? ally-novas)
          live-enemy-nova-tags
          (set-union
           live-enemy-nova-tags
           (list->set
            (for/list : (Listof Integer) ([u (in-list ally-novas)])
              (unit-tag-int u))))))
    (for ([k (in-list (hash-keys nova-ht))])
      (unless (set-member? live-all-novas k)
        (hash-remove! nova-ht k)))))

;; =============================================================================
;; 1. Offensive Cast Planning (`plan-disruptor-nova-casts`)
;; =============================================================================

(: caster-on-cooldown? (-> Any (Option disruptor-tactical-tracker) Integer Boolean))
(define (caster-on-cooldown? u tr current-frame)
  (define uid (unit-tag-int u))
  (define explicit-cd
    (max (safe-exact-int (dyn-hash-ref u 'nova-cooldown 0) 0)
         (safe-exact-int (dyn-hash-ref u 'ability-cooldown 0) 0)
         (safe-exact-int (dyn-hash-ref u 'cooldown 0) 0)))
  (define explicit-not-ready? (eq? (dyn-hash-ref u 'purification-nova-ready #t) #f))
  (define tracker-cd
    (if tr (disruptor-tracker-friendly-cooldown tr uid current-frame) 0))
  (or (> explicit-cd 0)
      explicit-not-ready?
      (> tracker-cd 0)
      (explicit-nova-order? u)))

;; Plan optimal Purification Nova (`2346`) casts for ready friendly Disruptors:
;; - Ground non-structure non-`disruptor-phased` enemies only
;; - Requires net splash score >= `min-worthwhile-score` (default 100.0)
;; - Checks cast reach <= `max-reach` (default 13.0)
;; - De-conflicts >= `deconflict-dist` (default 4.0) from active friendly Novas
;;   and earlier planned casts on the same tick.
(: plan-disruptor-nova-casts
   (->* ((Listof Any) (Listof Any))
        (#:tracker (Option disruptor-tactical-tracker)
         #:current-frame Integer
         #:min-worthwhile-score Real
         #:max-reach Real
         #:deconflict-dist Real)
        (Listof nova-cast-plan)))
(define (plan-disruptor-nova-casts ally-units enemy-units
                                   #:tracker [tr #f]
                                   #:current-frame [current-frame 0]
                                   #:min-worthwhile-score [min-score-arg DISRUPTOR-MIN-WORTHWHILE-SCORE]
                                   #:max-reach [max-reach-arg DISRUPTOR-MAX-REACH-RANGE]
                                   #:deconflict-dist [deconflict-arg DISRUPTOR-VOLLEY-DECONFLICT-DIST])
  (plan-disruptor-nova-casts-core ally-units enemy-units tr current-frame
                                  min-score-arg max-reach-arg deconflict-arg #t))

(: plan-disruptor-nova-casts-core
   (-> (Listof Any) (Listof Any) (Option disruptor-tactical-tracker) Integer
       Real Real Real Boolean (Listof nova-cast-plan)))
(define (plan-disruptor-nova-casts-core ally-units enemy-units tr current-frame
                                        min-score-arg max-reach-arg deconflict-arg sync?)
  (when (and tr sync?)
    (sync-tracker-state! tr ally-units enemy-units current-frame))
  (define-values (ally-casters ally-novas)
    (let ([pc (internal-ally-casters)]
          [pn (internal-ally-novas)])
      (if (and pc pn)
          (values pc pn)
          (extract-disruptor-casters+novas ally-units))))
  (define ready-casters : (Listof Any)
    (filter (lambda ([u : Any])
              (and (unit-alive? u)
                   (not (caster-on-cooldown? u tr current-frame))))
            ally-casters))
  (if (null? ready-casters)
      '()
      (let ()
        (define min-score (->float min-score-arg))
        (define max-reach (->float max-reach-arg))
        (define deconflict (->float deconflict-arg))
        (define caster-refs : (Listof (Pairof Float Float))
          (for/list : (Listof (Pairof Float Float)) ([c (in-list ready-casters)])
            (cons (unit-x c) (unit-y c))))
        (define eval-enemies (precompute-nova-eval-units enemy-units caster-refs (+ max-reach 2.5) #f))
        (if (null? eval-enemies)
            '()
            (let ()
              (define eval-allies (precompute-nova-eval-units ally-units caster-refs (+ max-reach 5.0) #t))
              ;; Reserve positions of live friendly Novas + active channeling orders
              (define reserved-pts : (Listof point2d)
                (append
                 (for/list : (Listof point2d) ([u (in-list ally-novas)])
                   (point2d (unit-x u) (unit-y u)))
                 (for/fold ([pts : (Listof point2d) '()])
                           ([u (in-list ally-casters)]
                            #:when (explicit-nova-order? u))
                   (define op (explicit-order-target-point u))
                   (if op (cons op pts) pts))))
              (define plans : (Listof nova-cast-plan) '())
              (for ([c (in-list ready-casters)])
                (define cid (unit-tag-int c))
                (define cx (unit-x c))
                (define cy (unit-y c))
                (define-values (best-pt sc)
                  (pick-best-nova-target/eval eval-enemies eval-allies cx cy max-reach reserved-pts deconflict))
                (when (and best-pt
                           (> (nova-impact-score-enemy-hits sc) 0)
                           (>= (nova-impact-score-net-score sc) min-score))
                  (define tx (point2d-x best-pt))
                  (define ty (point2d-y best-pt))
                  (set! reserved-pts (cons best-pt reserved-pts))
                  (set! plans (cons (nova-cast-plan cid tx ty
                                                    (nova-impact-score-net-score sc)
                                                    (nova-impact-score-enemy-hits sc)
                                                    (nova-impact-score-ally-hits sc))
                                    plans))
                  (when tr
                    (hash-set! (disruptor-tactical-tracker-friendly-casters tr)
                               cid
                               (+ current-frame DISRUPTOR-NOVA-COOLDOWN-FRAMES)))))
              (reverse plans))))))

;; =============================================================================
;; 2. Live Friendly Purification Nova Steering (`steer-purification-novas`)
;; =============================================================================

;; Compute per-step homing orders for active friendly `DisruptorPhased` (`733`)
;; balls (~47-frame lifetime, 5.95 tiles/sec) onto the highest-value reachable
;; enemy ground cluster centroid, avoiding friendly fire.
(: steer-purification-novas
   (->* ((Listof Any) (Listof Any))
        (#:tracker (Option disruptor-tactical-tracker)
         #:current-frame Integer)
        (Listof nova-steer-order)))
(define (steer-purification-novas ally-units enemy-units
                                  #:tracker [tr #f]
                                  #:current-frame [current-frame 0])
  (steer-purification-novas-core ally-units enemy-units tr current-frame #t))

(: steer-purification-novas-core
   (-> (Listof Any) (Listof Any) (Option disruptor-tactical-tracker) Integer Boolean
       (Listof nova-steer-order)))
(define (steer-purification-novas-core ally-units enemy-units tr current-frame sync?)
  (when (and tr sync?)
    (sync-tracker-state! tr ally-units enemy-units current-frame))
  (define friendly-novas : (Listof Any)
    (or (internal-ally-novas)
        (let-values ([(_c n) (extract-disruptor-casters+novas ally-units)])
          n)))
  (if (null? friendly-novas)
      '()
      (let ()
        (define nova-refs : (Listof (Pairof Float Float))
          (for/list : (Listof (Pairof Float Float)) ([n (in-list friendly-novas)])
            (cons (unit-x n) (unit-y n))))
        (define max-reach-bound
          (+ DISRUPTOR-NOVA-SPLASH-RADIUS
             (* (->float DISRUPTOR-NOVA-LIFETIME-FRAMES) DISRUPTOR-NOVA-SPEED-PER-FRAME)))
        (define eval-enemies (precompute-nova-eval-units enemy-units nova-refs (+ max-reach-bound 2.5) #f))
        (define eval-allies (precompute-nova-eval-units ally-units nova-refs (+ max-reach-bound 5.0) #t))
        (define lazy-ground-enemies : (Option (Listof Any)) #f)
        (: get-ground-enemies (-> (Listof Any)))
        (define (get-ground-enemies)
          (or lazy-ground-enemies
              (let ([ge (filter-targetable-ground-units enemy-units)])
                (set! lazy-ground-enemies ge)
                ge)))
        (define claimed-targets : (Listof point2d) '())
        (define orders : (Listof nova-steer-order) '())
        (for ([n (in-list friendly-novas)])
          (define nid (unit-tag-int n))
          (define nx (unit-x n))
          (define ny (unit-y n))
          (define rem-frames : Integer
            (cond
              [(dyn-hash-has-key? n 'remaining-frames)
               (max 1 (safe-exact-int (dyn-hash-ref n 'remaining-frames DISRUPTOR-NOVA-LIFETIME-FRAMES)
                                      DISRUPTOR-NOVA-LIFETIME-FRAMES))]
              [(dyn-hash-has-key? n 'age-frames)
               (max 1 (- DISRUPTOR-NOVA-LIFETIME-FRAMES
                         (max 0 (safe-exact-int (dyn-hash-ref n 'age-frames 0) 0))))]
              [tr
               (define st (hash-ref (disruptor-tactical-tracker-nova-table tr) nid (lambda () #f)))
               (if st
                   (max 1 (- (nova-track-state-expire-frame st) current-frame))
                   DISRUPTOR-NOVA-LIFETIME-FRAMES)]
              [else DISRUPTOR-NOVA-LIFETIME-FRAMES]))
          ;; Reachable travel radius before detonation + splash margin
          (define travel-reach
            (+ DISRUPTOR-NOVA-SPLASH-RADIUS
               (* (->float rem-frames) DISRUPTOR-NOVA-SPEED-PER-FRAME)))
          (define-values (best-pt sc)
            (if (null? eval-enemies)
                (values #f (nova-impact-score -1.0 0 0 0.0 0.0))
                (let ()
                  ;; Try de-conflicted reachable clusters first
                  (define-values (pt1 sc1)
                    (pick-best-nova-target/eval eval-enemies eval-allies nx ny travel-reach claimed-targets 3.2))
                  (if (and pt1 (> (nova-impact-score-enemy-hits sc1) 0))
                      (values pt1 sc1)
                      ;; Fallback without de-confliction if only 1 enemy cluster exists
                      (pick-best-nova-target/eval eval-enemies eval-allies nx ny travel-reach '() 0.0)))))
          (cond
            [(and best-pt
                  (> (nova-impact-score-enemy-hits sc) 0)
                  (>= (nova-impact-score-net-score sc) 0.0))
             (set! claimed-targets (cons best-pt claimed-targets))
             (set! orders (cons (nova-steer-order nid (point2d-x best-pt) (point2d-y best-pt)
                                                  (nova-impact-score-net-score sc)
                                                  (nova-impact-score-enemy-hits sc))
                                orders))]
            [else
             ;; If only friendly units are near the live Nova (avoid friendly fire!) or
             ;; enemies are slightly beyond remaining reach, steer away from ally cluster.
             (define near-ally-pts : (Listof point2d)
               (for/list : (Listof point2d) ([a (in-list (filter-nova-eval-units-within eval-allies nx ny (+ travel-reach 2.5)))])
                 (point2d (nova-eval-unit-x a) (nova-eval-unit-y a))))
             (cond
               [(pair? near-ally-pts)
                (define ac (centroid-2d near-ally-pts))
                (define away-pt (clamp-point-to-map
                                 (step-away-2d nx ny (point2d-x ac) (point2d-y ac) (min travel-reach 5.0))
                                 SC2-MAP-PLAYABLE-MIN-COORD SC2-MAP-PLAYABLE-MAX-COORD))
                (set! orders (cons (nova-steer-order nid (point2d-x away-pt) (point2d-y away-pt) 0.0 0)
                                   orders))]
               [(pair? (get-ground-enemies))
                ;; Lunge toward nearest ground enemy if strictly beyond current travel reach
                (define ground-enemies (get-ground-enemies))
                (define-values (nearest-e _bd)
                  (for/fold ([best : Any (car ground-enemies)]
                             [bd : Float (dist-2d nx ny (unit-x (car ground-enemies)) (unit-y (car ground-enemies)))])
                            ([e (in-list (cdr ground-enemies))])
                    (define d (dist-2d nx ny (unit-x e) (unit-y e)))
                    (if (< d bd) (values e d) (values best bd))))
                (define lunge (clamp-to-playable (unit-x nearest-e) (unit-y nearest-e)))
                (set! orders (cons (nova-steer-order nid (point2d-x lunge) (point2d-y lunge) 0.0 1)
                                   orders))]
               [else (void)])]))
        (reverse orders))))

;; =============================================================================
;; 3. Weaponless Disruptor Stand-off & Cooldown Kiting (`kite-disruptor-casters`)
;; =============================================================================

(: compute-friendly-army-anchor (-> (Listof Any) Float Float point2d))
(define (compute-friendly-army-anchor ally-units home-x home-y)
  (define-values (sx sy cnt fallback)
    (fast-compute-army-anchor-raw ally-units CANONICAL-ANCHOR-CLASS-CACHE))
  (define tot-x : Float sx)
  (define tot-y : Float sy)
  (define tot-n : Fixnum cnt)
  (unless (null? fallback)
    (for ([u (in-list fallback)])
      (define ut-raw (dyn-hash-ref u 'type #f))
      (define cs (resolved-unit-type u))
      (define skip? : Boolean
        (or (purification-nova-unit? u)
            (disruptor-caster-unit? u)
            (unit-is-structure? u)
            (not (not (memq cs '(probe scv drone mule observer))))))
      (when (and (symbol? ut-raw) (not (eq? ut-raw 'unknown)))
        (unless (or (eq? (dyn-hash-ref u 'is-building #f) #t)
                    (eq? (dyn-hash-ref u 'building? #f) #t)
                    (eq? (dyn-hash-ref u 'is-structure #f) #t))
          (hash-set! CANONICAL-ANCHOR-CLASS-CACHE ut-raw (if skip? 'skip 'keep))))
      (unless skip?
        (set! tot-x (fl+ tot-x (unit-x u)))
        (set! tot-y (fl+ tot-y (unit-y u)))
        (set! tot-n (fx+ tot-n 1)))))
  (if (fx> tot-n 0)
      (point2d (fl/ tot-x (->fl tot-n)) (fl/ tot-y (->fl tot-n)))
      (point2d home-x home-y)))

;; Position friendly weaponless Disruptors (`694`) cleanly:
;; - NEVER emits `attack-unit` or `attack-move`!
;; - Ready casters hold standoff 10.5 - 12.0 tiles from nearest enemy threat.
;; - On-cooldown or active-channeling casters retreat behind army anchor to
;;   13.0 - 15.0 tiles from nearest enemy threat.
(: kite-disruptor-casters
   (->* ((Listof Any) (Listof Any))
        (#:tracker (Option disruptor-tactical-tracker)
         #:current-frame Integer
         #:home-x Real
         #:home-y Real
         #:exclude-tags (Listof Integer)
         #:emit-hold? Boolean)
        (Listof disruptor-kite-order)))
(define (kite-disruptor-casters ally-units enemy-units
                                #:tracker [tr #f]
                                #:current-frame [current-frame 0]
                                #:home-x [home-x-arg 32.0]
                                #:home-y [home-y-arg 32.0]
                                #:exclude-tags [exclude-tags '()]
                                #:emit-hold? [emit-hold? #f])
  (kite-disruptor-casters-core ally-units enemy-units tr current-frame
                               home-x-arg home-y-arg exclude-tags emit-hold? #t))

(: kite-disruptor-casters-core
   (-> (Listof Any) (Listof Any) (Option disruptor-tactical-tracker) Integer
       Real Real (Listof Integer) Boolean Boolean (Listof disruptor-kite-order)))
(define (kite-disruptor-casters-core ally-units enemy-units tr current-frame
                                     home-x-arg home-y-arg exclude-tags emit-hold? sync?)
  (when (and tr sync? (not (internal-skip-sync?)))
    (sync-tracker-state! tr ally-units enemy-units current-frame))
  (define raw-casters : (Listof Any)
    (or (internal-ally-casters)
        (let-values ([(cs _n) (extract-disruptor-casters+novas ally-units)])
          cs)))
  (define casters : (Listof Any)
    (filter (lambda ([u : Any])
              (and (unit-alive? u)
                   (not (memv (unit-tag-int u) exclude-tags))))
            raw-casters))
  (if (null? casters)
      '()
      (let ()
        (define home-x (->float home-x-arg))
        (define home-y (->float home-y-arg))
        (define k : Fixnum (length casters))
        (define cids : (Vectorof Integer) (make-vector k 0))
        (define cxs : FlVector (make-flvector k 0.0))
        (define cys : FlVector (make-flvector k 0.0))
        (let fill ([cs casters] [idx : Fixnum 0])
          (unless (null? cs)
            (define c (car cs))
            (vector-set! cids idx (unit-tag-int c))
            (flvector-set! cxs idx (unit-x c))
            (flvector-set! cys idx (unit-y c))
            (fill (cdr cs) (fx+ idx 1))))
        (define-values (th-xs th-ys th-d2s th-cnt)
          (fast-nearest-kite-threats enemy-units cxs cys k))
        (if (fx= th-cnt 0)
            '()
            (let ()
        (define lazy-anchor : (Option point2d) #f)
        (: get-anchor (-> point2d))
        (define (get-anchor)
          (or lazy-anchor
              (let ([a (compute-friendly-army-anchor ally-units home-x home-y)])
                (set! lazy-anchor a)
                a)))
        (define orders : (Listof disruptor-kite-order) '())
        (for ([c (in-list casters)]
              [idx (in-range k)])
          (define cid (vector-ref cids idx))
          (define cx (flvector-ref cxs idx))
          (define cy (flvector-ref cys idx))
          (define ex (flvector-ref th-xs idx))
          (define ey (flvector-ref th-ys idx))
          (define best-d2 (flvector-ref th-d2s idx))
          (define min-d : Float (assert (sqrt (max 0.0 best-d2)) flonum?))
          (define on-cd? (caster-on-cooldown? c tr current-frame))
          (define state-sym : Symbol (if on-cd? 'on-cooldown 'ready))
          (define min-band (if on-cd? DISRUPTOR-RETREAT-MIN-DIST DISRUPTOR-STANDOFF-MIN-DIST))
          (define max-band (if on-cd? DISRUPTOR-RETREAT-MAX-DIST DISRUPTOR-STANDOFF-MAX-DIST))
          (define desired-d (* 0.5 (+ min-band max-band))) ; 11.25 ready / 14.0 cooldown

          (cond
            ;; Too close -> retreat to exact desired standoff / cooldown distance
            [(< min-d min-band)
             (define anchor (get-anchor))
             (define ax (point2d-x anchor))
             (define ay (point2d-y anchor))
             (define-values (awx awy amag) (unit-vec-2d (- cx ex) (- cy ey)))
             (define-values (hmx hmy hmag) (unit-vec-2d (- home-x cx) (- home-y cy)))
             (define-values (acx acy acmag) (unit-vec-2d (- ax cx) (- ay cy)))
             (define base-vx (if (> amag 0.05) awx (if (> hmag 0.05) hmx -1.0)))
             (define base-vy (if (> amag 0.05) awy (if (> hmag 0.05) hmy 0.0)))
             (define-values (rx ry rmag)
               (unit-vec-2d (+ (* 0.85 base-vx) (* 0.15 (if (> acmag 0.05) acx hmx)))
                            (+ (* 0.85 base-vy) (* 0.15 (if (> acmag 0.05) acy hmy)))))
             (define raw-tx (+ ex (* desired-d (if (> rmag 0.05) rx base-vx))))
             (define raw-ty (+ ey (* desired-d (if (> rmag 0.05) ry base-vy))))
             (define tgt (clamp-to-playable raw-tx raw-ty))
             (set! orders (cons (disruptor-kite-order cid 'move (point2d-x tgt) (point2d-y tgt)
                                                      min-d state-sym
                                                      (if on-cd? 'cooldown-retreat 'standoff-retreat))
                                orders))]
            ;; Ready caster too far from enemy fight -> move up ONLY to 11.25 standoff (never attack-unit!)
            [(and (not on-cd?) (> min-d max-band) (<= min-d 30.0))
             (define-values (awx awy amag) (unit-vec-2d (- cx ex) (- cy ey)))
             (define-values (hmx hmy hmag) (unit-vec-2d (- home-x cx) (- home-y cy)))
             (define base-vx (if (> amag 0.05) awx (if (> hmag 0.05) hmx -1.0)))
             (define base-vy (if (> amag 0.05) awy (if (> hmag 0.05) hmy 0.0)))
             (define tgt (clamp-to-playable (+ ex (* desired-d base-vx))
                                            (+ ey (* desired-d base-vy))))
             (set! orders (cons (disruptor-kite-order cid 'move (point2d-x tgt) (point2d-y tgt)
                                                      min-d 'ready 'standoff-approach)
                                orders))]
            ;; On-cooldown caster way behind friendly army (> 17.5 from threat): escort behind anchor at >= 14.0
            [(and on-cd? (> min-d 17.5)
                  (let ([anchor (get-anchor)])
                    (< (dist-2d ex ey (point2d-x anchor) (point2d-y anchor)) (- min-d 2.0))))
             (define-values (awx awy amag) (unit-vec-2d (- cx ex) (- cy ey)))
             (define-values (hmx hmy hmag) (unit-vec-2d (- home-x cx) (- home-y cy)))
             (define base-vx (if (> amag 0.05) awx (if (> hmag 0.05) hmx -1.0)))
             (define base-vy (if (> amag 0.05) awy (if (> hmag 0.05) hmy 0.0)))
             (define tgt (clamp-to-playable (+ ex (* desired-d base-vx))
                                            (+ ey (* desired-d base-vy))))
             (set! orders (cons (disruptor-kite-order cid 'move (point2d-x tgt) (point2d-y tgt)
                                                      min-d 'on-cooldown 'cooldown-escort-behind-army)
                                orders))]
            [emit-hold?
             (set! orders (cons (disruptor-kite-order cid 'move cx cy min-d state-sym 'hold-standoff)
                                orders))]))
        (reverse orders))))))

;; =============================================================================
;; 4. Defensive Anti-Nova Scatter, Emergency Stalker Blink, & Pre-Split
;; =============================================================================

;; Estimate unit heading vector `(hx, hy)` and forward corridor endpoint `(fx, fy)`
;; for an enemy `DisruptorPhased` Nova ball.
(: infer-enemy-nova-ray
   (-> Any (Option disruptor-tactical-tracker) (Listof Any) (Values Float Float Float Float)))
(define (infer-enemy-nova-ray nova tr ground-allies)
  (define nid (unit-tag-int nova))
  (define nx (unit-x nova))
  (define ny (unit-y nova))
  ;; 1. Explicit vx/vy on hash
  (define evx (if (dyn-hash-has-key? nova 'vx) (safe-finite-real (dyn-hash-ref nova 'vx 0.0) 0.0) 0.0))
  (define evy (if (dyn-hash-has-key? nova 'vy) (safe-finite-real (dyn-hash-ref nova 'vy 0.0) 0.0) 0.0))
  (define-values (ux1 uy1 mag1) (unit-vec-2d evx evy))
  (cond
    [(> mag1 0.05) (values ux1 uy1 1.0 DISRUPTOR-ANTI-NOVA-CONE-RANGE)]
    [else
     ;; 2. Tracker frame-delta velocity
     (define-values (tvx tvy has-tv?)
       (if tr (disruptor-tracker-nova-velocity tr nid) (values 0.0 0.0 #f)))
     (define-values (ux2 uy2 mag2) (unit-vec-2d tvx tvy))
     (cond
       [(and has-tv? (> mag2 0.05)) (values ux2 uy2 1.0 DISRUPTOR-ANTI-NOVA-CONE-RANGE)]
       [(dyn-hash-has-key? nova 'facing)
        (define ang (safe-finite-real (dyn-hash-ref nova 'facing 0.0) 0.0))
        (values (cos ang) (sin ang) 1.0 DISRUPTOR-ANTI-NOVA-CONE-RANGE)]
       [else
        ;; 3. Infer oncoming steering direction toward nearest/highest-value friendly ground clump
        (define-values (sx sy wsum)
          (for/fold ([ax : Float 0.0]
                     [ay : Float 0.0]
                     [ws : Float 0.0])
                    ([a (in-list ground-allies)])
            (define d (dist-2d nx ny (unit-x a) (unit-y a)))
            (if (<= d 13.0)
                (let ([w (/ (unit-nova-replacement-value a) (+ 1.0 (* 0.3 d)))])
                  (values (+ ax (* w (unit-x a))) (+ ay (* w (unit-y a))) (+ ws w)))
                (values ax ay ws))))
        (if (> wsum 0.0)
            (let-values ([(ux3 uy3 mag3) (unit-vec-2d (- (/ sx wsum) nx) (- (/ sy wsum) ny))])
              (values ux3 uy3 (if (> mag3 0.05) 1.0 0.0) DISRUPTOR-ANTI-NOVA-CONE-RANGE))
            (values 0.0 0.0 0.0 0.0))])]))

(struct nova-ray-info
  ([tag : Integer]
   [x : Float]
   [y : Float]
   [hx : Float]
   [hy : Float]
   [has-ray? : Float]
   [ray-len : Float]))

(struct nova-threat-hit
  ([ray : nova-ray-info]
   [dist : Float]
   [ray-dist : Float]))

(: nova-threat-score-for-unit (-> Float Float Float Float Float Float Float Float
                                  (Values Boolean Float Float)))
(define (nova-threat-score-for-unit ux uy nx ny hx hy has-ray? ray-len)
  (define d (dist-2d ux uy nx ny))
  (define fx (+ nx (* hx ray-len)))
  (define fy (+ ny (* hy ray-len)))
  (define ray-d
    (if (> has-ray? 0.5)
        (point-to-segment-dist ux uy nx ny fx fy)
        d))
  (define proj
    (if (> has-ray? 0.5)
        (+ (* (- ux nx) hx) (* (- uy ny) hy))
        0.0))
  (define threatened?
    (or (<= d DISRUPTOR-ANTI-NOVA-DANGER-RADIUS)
        (and (> has-ray? 0.5)
             (>= proj -0.5)
             (<= proj ray-len)
             (<= ray-d 3.25))))
  (values threatened? d ray-d))

;; Choose a safe 7.5-tile Stalker Blink landing destination escaping radial + perpendicular
;; away from the threatening Nova while avoiding all other active enemy Novas.
(: pick-safe-stalker-blink-point (-> Float Float Float Float Float Float Integer (Listof Any) point2d))
(define (pick-safe-stalker-blink-point ux uy nx ny hx hy uid enemy-novas)
  (define-values (rx ry rmag) (unit-vec-2d (- ux nx) (- uy ny)))
  (define px (if (> (+ (* hx hx) (* hy hy)) 0.25) (- hy) (if (> rmag 0.05) (- ry) 0.0)))
  (define py (if (> (+ (* hx hx) (* hy hy)) 0.25) hx (if (> rmag 0.05) rx 1.0)))
  (define cross
    (if (> (+ (* hx hx) (* hy hy)) 0.25)
        (- (* hx (- uy ny)) (* hy (- ux nx)))
        0.0))
  (define p-sign : Float (cond [(> cross 0.05) 1.0] [(< cross -0.05) -1.0] [(even? uid) 1.0] [else -1.0]))
  (define candidates : (Listof point2d)
    (for/list : (Listof point2d) ([dir (in-list (list (cons (+ (* 0.55 rx) (* 0.85 p-sign px))
                                                            (+ (* 0.55 ry) (* 0.85 p-sign py)))
                                                      (cons (* p-sign px) (* p-sign py))
                                                      (cons (* (- p-sign) px) (* (- p-sign) py))
                                                      (cons (if (> rmag 0.05) rx 0.0)
                                                            (if (> rmag 0.05) ry 1.0))
                                                      (cons (+ (* -0.4 hx) (* p-sign px))
                                                            (+ (* -0.4 hy) (* p-sign py)))))])
      (define-values (dx dy dmag) (unit-vec-2d (car dir) (cdr dir)))
      (if (> dmag 0.05)
          (clamp-to-playable (+ ux (* 7.6 dx)) (+ uy (* 7.6 dy)))
          (clamp-to-playable (+ ux 7.6) uy))))
  ;; Pick candidate maximizing minimum distance to all active enemy Novas
  (define-values (best-pt _best-min-d)
    (for/fold ([best-pt : point2d (car candidates)]
               [best-min-d : Float -1.0])
              ([cand (in-list candidates)])
      (define md
        (for/fold ([m : Float 999.0]) ([en (in-list enemy-novas)])
          (min m (dist-2d (point2d-x cand) (point2d-y cand) (unit-x en) (unit-y en)))))
      (if (> md best-min-d)
          (values cand md)
          (values best-pt best-min-d))))
  best-pt)

;; Plan defensive evasion against enemy Disruptors and active Purification Novas:
;; 1. Emergency Stalker Blink (< 2.75 tiles OR imminent forward cone), REGARDLESS of HP!
;; 2. Radial + perpendicular fan split for ground units within danger radius <= 6.5
;;    or forward Nova velocity corridor (ray <= 3.25, ahead <= 9.0), using signed
;;    cross product + deterministic ID parity tie-break to part away from the Nova path.
;; 3. Pre-split spacing repulsion when enemy `Disruptor` (`694`) is within 14.5 tiles
;;    and not known on cooldown, and friendly ground units cluster < 2.8 tiles apart.
(: plan-anti-nova-scatter
   (->* ((Listof Any) (Listof Any))
        (#:tracker (Option disruptor-tactical-tracker)
         #:current-frame Integer
         #:blink-researched? Boolean
         #:home-x Real
         #:home-y Real)
        (Listof anti-nova-dodge-order)))
(define (plan-anti-nova-scatter ally-units enemy-units
                                 #:tracker [tr #f]
                                 #:current-frame [current-frame 0]
                                 #:blink-researched? [blink-researched? #t]
                                 #:home-x [home-x-arg 32.0]
                                 #:home-y [home-y-arg 32.0])
  (when (and tr (not (internal-skip-sync?)))
    (sync-tracker-state! tr ally-units enemy-units current-frame))
  (define-values (all-enemy-casters enemy-novas)
    (let ([pc (internal-enemy-casters)]
          [pn (internal-enemy-novas)])
      (if (and pc pn)
          (values pc pn)
          (extract-disruptor-casters+novas enemy-units))))
  (define ready-enemy-casters : (Listof Any)
    (if (null? all-enemy-casters)
        '()
        (filter (lambda ([e : Any])
                  (and (unit-alive? e)
                       (or (not tr)
                           (<= (disruptor-tracker-enemy-cooldown tr (unit-tag-int e) current-frame) 0))
                       (<= (safe-exact-int (dyn-hash-ref e 'nova-cooldown 0) 0) 0)))
                all-enemy-casters)))
  (define threat-refs : (Listof Any)
    (if (and (null? enemy-novas) (null? ready-enemy-casters))
        '()
        (append enemy-novas ready-enemy-casters)))
  (define home-x (->float home-x-arg))
  (define home-y (->float home-y-arg))
  ;; Never scatter air units or `disruptor-phased` Novas or buildings!
  (define ground-allies : (Listof Any)
    (if (null? threat-refs)
        '()
        (filter-targetable-ground-units
         (filter-units-within-range ally-units threat-refs 15.0))))

  (if (or (null? ground-allies)
          (and (null? enemy-novas) (null? ready-enemy-casters)))
      '()
      (let ()
        ;; Precompute rays for all live enemy Novas
        (define nova-rays : (Listof nova-ray-info)
          (for/list : (Listof nova-ray-info) ([en (in-list enemy-novas)])
            (define-values (hx hy has-r? rlen) (infer-enemy-nova-ray en tr ground-allies))
            (nova-ray-info (unit-tag-int en) (unit-x en) (unit-y en) hx hy has-r? rlen)))

        (define orders : (Listof anti-nova-dodge-order) '())
        (for ([u (in-list ground-allies)])
          (define uid (unit-tag-int u))
          (define ux (unit-x u))
          (define uy (unit-y u))

          ;; Find highest-urgency active Nova threatening this unit
          (define best-threat : (Option nova-threat-hit) #f)
          (for ([nr (in-list nova-rays)])
            (define nx (nova-ray-info-x nr))
            (define ny (nova-ray-info-y nr))
            (define hx (nova-ray-info-hx nr))
            (define hy (nova-ray-info-hy nr))
            (define has-r? (nova-ray-info-has-ray? nr))
            (define rlen (nova-ray-info-ray-len nr))
            (define-values (threat? d ray-d)
              (nova-threat-score-for-unit ux uy nx ny hx hy has-r? rlen))
            (when threat?
              (define urgency (min d (+ ray-d 0.8)))
              (define prev-bt best-threat)
              (when (or (not prev-bt)
                        (< urgency (min (nova-threat-hit-dist prev-bt)
                                        (+ (nova-threat-hit-ray-dist prev-bt) 0.8))))
                (set! best-threat (nova-threat-hit nr d ray-d)))))

          (define chosen-threat best-threat)
          (cond
            [chosen-threat
             (define nr (nova-threat-hit-ray chosen-threat))
             (define ntag (nova-ray-info-tag nr))
             (define nx (nova-ray-info-x nr))
             (define ny (nova-ray-info-y nr))
             (define hx (nova-ray-info-hx nr))
             (define hy (nova-ray-info-hy nr))
             (define has-r? (nova-ray-info-has-ray? nr))
             (define d (nova-threat-hit-dist chosen-threat))
             (define ray-d (nova-threat-hit-ray-dist chosen-threat))

             (define blink-cd
               (max (safe-exact-int (dyn-hash-ref u 'blink-cooldown 0) 0)
                    (if tr (disruptor-tracker-stalker-blink-cooldown tr uid current-frame) 0)))
             (define urgent-blink?
               (and (stalker-unit? u)
                    blink-researched?
                    (<= blink-cd 0)
                    (or (< d DISRUPTOR-BLINK-DODGE-RADIUS)
                        (and (> has-r? 0.5) (< d 3.25) (< ray-d 2.2)))))

             (cond
               [urgent-blink?
                (define bpt (pick-safe-stalker-blink-point ux uy nx ny hx hy uid enemy-novas))
                (when tr
                  (hash-set! (disruptor-tactical-tracker-stalker-blinks tr)
                             uid
                             (+ current-frame DISRUPTOR-BLINK-COOLDOWN-FRAMES)))
                (set! orders (cons (anti-nova-dodge-order uid 'blink (point2d-x bpt) (point2d-y bpt)
                                                         ntag d 'emergency-stalker-blink)
                                   orders))]
               [else
                ;; Radial + perpendicular split orthogonal to Nova trajectory
                (define-values (rx0 ry0 rmag) (unit-vec-2d (- ux nx) (- uy ny)))
                (define-values (hmx hmy hmag) (unit-vec-2d (- home-x ux) (- home-y uy)))
                (define rx (if (> rmag 0.05) rx0 (if (> hmag 0.05) hmx -1.0)))
                (define ry (if (> rmag 0.05) ry0 (if (> hmag 0.05) hmy 0.0)))
                ;; Effective forward axis: Nova velocity axis if known, else (n -> u)
                (define ax-hx (if (> has-r? 0.5) hx (- rx)))
                (define ax-hy (if (> has-r? 0.5) hy (- ry)))
                (define px (- ax-hy))
                (define py ax-hx)
                (define cross (- (* ax-hx (- uy ny)) (* ax-hy (- ux nx))))
                (define p-sign : Float
                  (cond
                    [(> cross 0.05) 1.0]
                    [(< cross -0.05) -1.0]
                    [(even? uid) 1.0]
                    [else -1.0]))
                ;; Local neighbor repulsion (< 2.2 tiles) so dodging units don't stack
                (define-values (nsx nsy ncnt)
                  (for/fold ([sx : Float 0.0]
                             [sy : Float 0.0]
                             [c : Integer 0])
                            ([other (in-list ground-allies)]
                             #:when (and (not (= (unit-tag-int other) uid))
                                         (< (dist-2d ux uy (unit-x other) (unit-y other)) 2.2)))
                    (define-values (ox oy omag) (unit-vec-2d (- ux (unit-x other)) (- uy (unit-y other))))
                    (if (> omag 0.05)
                        (values (+ sx ox) (+ sy oy) (+ c 1))
                        (values sx sy c))))
                (define nrep-x (if (> ncnt 0) (/ nsx (->float ncnt)) 0.0))
                (define nrep-y (if (> ncnt 0) (/ nsy (->float ncnt)) 0.0))
                ;; Blend: strong perpendicular fan (0.75) + radial escape (0.55) + de-stack (0.25)
                (define-values (sx sy smag)
                  (unit-vec-2d (+ (* 0.55 rx) (* 0.75 p-sign px) (* 0.25 nrep-x))
                               (+ (* 0.55 ry) (* 0.75 p-sign py) (* 0.25 nrep-y))))
                (define step-dist (if (<= d 4.0) 5.0 4.2))
                (define tgt (clamp-to-playable (+ ux (* step-dist (if (> smag 0.05) sx rx)))
                                               (+ uy (* step-dist (if (> smag 0.05) sy ry)))))
                (set! orders (cons (anti-nova-dodge-order
                                    uid 'split (point2d-x tgt) (point2d-y tgt)
                                    ntag d
                                    (if (<= (abs cross) 0.05)
                                        'centerline-perp-split
                                        'radial-perp-split))
                                   orders))])]

            ;; No live Nova threatening `u`: check ready enemy Disruptor pre-split spacing pressure
            [(pair? ready-enemy-casters)
             (define-values (near-ed near-ed-dist)
               (for/fold ([bd-e : Any (car ready-enemy-casters)]
                          [bd : Float 999.0])
                         ([ed (in-list ready-enemy-casters)])
                 (define d (dist-2d ux uy (unit-x ed) (unit-y ed)))
                 (if (< d bd) (values ed d) (values bd-e bd))))
             (when (<= near-ed-dist DISRUPTOR-PRESPLIT-THREAT-RANGE)
               ;; Check tight friendly ground neighbors within 2.8 tiles (< 3.0 splash diameter)
               (define-values (clx cly cl-cnt)
                 (for/fold ([sx : Float 0.0]
                            [sy : Float 0.0]
                            [c : Integer 0])
                           ([other (in-list ground-allies)]
                            #:when (and (not (= (unit-tag-int other) uid))
                                        (not (disruptor-caster-unit? other))
                                        (< (dist-2d ux uy (unit-x other) (unit-y other)) 2.8)))
                   (values (+ sx (unit-x other)) (+ sy (unit-y other)) (+ c 1))))
               (when (>= cl-cnt 1)
                 (define cx (/ clx (->float cl-cnt)))
                 (define cy (/ cly (->float cl-cnt)))
                 (define-values (rep-x rep-y rmag) (unit-vec-2d (- ux cx) (- uy cy)))
                 (when (> rmag 0.05)
                   (define tgt (clamp-to-playable (+ ux (* 2.2 rep-x))
                                                  (+ uy (* 2.2 rep-y))))
                   (set! orders (cons (anti-nova-dodge-order
                                       uid 'pre-split (point2d-x tgt) (point2d-y tgt)
                                       (unit-tag-int near-ed) near-ed-dist 'disruptor-pre-split)
                                      orders)))))]))
        (reverse orders))))

;; =============================================================================
;; 5. Enemy Disruptor 480-Frame Cooldown & Active-Cast Parent Snipe Evaluator
;; =============================================================================

;; Evaluate all enemy `Disruptor` (`694`) casters:
;; - Tracks active casting window (`active-nova-frames-left` in `~47` frames) and
;;   `480`-frame post-shot cooldown via `tracker` (automatic Nova-spawn matching
;;   within 3.5 tiles + explicit `'orders` / `'nova-cooldown` support).
;; - Computes whether nearby friendly ranged/air units can lethally burst an
;;   active-casting parent Disruptor before its Nova detonates (killing the caster
;;   fizzles the Nova!).
(: evaluate-disruptor-snipe-and-cooldowns
   (->* ((Listof Any) (Listof Any))
        (#:tracker (Option disruptor-tactical-tracker)
         #:current-frame Integer)
        (Listof disruptor-snipe-eval)))
(define (evaluate-disruptor-snipe-and-cooldowns ally-units enemy-units
                                                #:tracker [tr #f]
                                                #:current-frame [current-frame 0])
  (when (and tr (not (internal-skip-sync?)))
    (sync-tracker-state! tr ally-units enemy-units current-frame))
  (define-values (raw-enemy-casters enemy-novas)
    (let ([pc (internal-enemy-casters)]
          [pn (internal-enemy-novas)])
      (if (and pc pn)
          (values pc pn)
          (extract-disruptor-casters+novas enemy-units))))
  (define enemy-casters : (Listof Any)
    (filter (lambda ([e : Any]) (unit-alive? e)) raw-enemy-casters))
  (define friendly-shooters : (Listof Any)
    (if (null? enemy-casters)
        '()
        (filter (lambda ([a : Any])
                  (and (hash? a)
                       (unit-alive? a)
                       (not (purification-nova-unit? a))
                       (not (disruptor-caster-unit? a))
                       (not (memq (resolved-unit-type a) '(probe scv drone mule observer)))))
                (filter-units-within-range ally-units enemy-casters 15.0))))

  (for/list : (Listof disruptor-snipe-eval) ([ed (in-list enemy-casters)])
    (define etag (unit-tag-int ed))
    (define ex (unit-x ed))
    (define ey (unit-y ed))
    (define ehp (+ (unit-hp ed 100.0) (unit-shield ed 100.0)))

    (define explicit-cd (safe-exact-int (dyn-hash-ref ed 'nova-cooldown 0) 0))
    (define tr-cd (if tr (disruptor-tracker-enemy-cooldown tr etag current-frame) 0))
    (define tr-nova-left (if tr (disruptor-tracker-enemy-active-nova-frames tr etag current-frame) 0))

    ;; Fallback if no tracker passed: associate nearby live enemy Nova within 3.5 tiles
    (define fallback-nova-left : Integer
      (if (and (= tr-nova-left 0)
               (or (explicit-nova-order? ed)
                   (for/or : Boolean ([en (in-list enemy-novas)])
                     (<= (dist-2d ex ey (unit-x en) (unit-y en)) 3.5))))
          DISRUPTOR-NOVA-LIFETIME-FRAMES
          0))
    (define active-left (max tr-nova-left fallback-nova-left))
    (define cd-rem (max explicit-cd tr-cd (if (> active-left 0) DISRUPTOR-NOVA-COOLDOWN-FRAMES 0)))
    (define state : Symbol
      (cond
        [(> active-left 0) 'active-casting]
        [(> cd-rem 0) 'on-cooldown]
        [else 'ready]))

    ;; Burst window: active Nova frames remaining minus ~5f reaction margin (min 0.25s),
    ;; or 1.6s reference window for DPS assessment.
    (define t-win-sec
      (if (> active-left 0)
          (/ (->float (max 6 (- active-left 5))) 22.4)
          1.6))

    (define-values (att-tags burst-dps total-burst-dmg)
      (for/fold ([tags : (Listof Integer) '()]
                 [dps-acc : Float 0.0]
                 [dmg-acc : Float 0.0])
                ([a (in-list friendly-shooters)])
        (define ut (resolved-unit-type a))
        (define stats (sc2-unit-combat-stats ut))
        (define gdps (safe-finite-real (hash-ref stats 'ground-dps (lambda () 0.0)) 0.0))
        (define grange (safe-finite-real (hash-ref stats 'ground-range (lambda () 0.0)) 0.0))
        (define spd (max 1.0 (safe-finite-real (hash-ref stats 'speed (lambda () 3.0)) 3.0)))
        (define wperiod (safe-finite-real (hash-ref stats 'weapon-period (lambda () 1.0)) 1.0))
        (define d (dist-2d (unit-x a) (unit-y a) ex ey))
        ;; Exclude ground units currently right inside a live Nova (< 2.75) that must dodge instead
        (define must-dodge-now?
          (and (not (unit-is-flying? a))
               (for/or : Boolean ([en (in-list enemy-novas)])
                 (< (dist-2d (unit-x a) (unit-y a) (unit-x en) (unit-y en))
                    DISRUPTOR-BLINK-DODGE-RADIUS))))
        (if (and (> gdps 0.0)
                 (<= d (+ grange 1.5))
                 (not must-dodge-now?))
            (let* ([walk-sec (if (<= d (+ grange 0.35)) 0.0 (/ (- d (+ grange 0.35)) spd))]
                   [t-eff (max 0.0 (- t-win-sec walk-sec))]
                   [volley-bonus (if (<= d (+ grange 0.35)) (* 0.45 wperiod) 0.0)]
                   [dmg (* gdps (+ t-eff volley-bonus))])
              (if (> dmg 0.0)
                  (values (cons (unit-tag-int a) tags) (+ dps-acc gdps) (+ dmg-acc dmg))
                  (values tags dps-acc dmg-acc)))
            (values tags dps-acc dmg-acc))))

    (define snipe-ok?
      (and (eq? state 'active-casting)
           (pair? att-tags)
           (>= total-burst-dmg (* 1.05 ehp))))

    (disruptor-snipe-eval etag ex ey state cd-rem active-left snipe-ok?
                          (reverse att-tags) burst-dps ehp)))

;; =============================================================================
;; 6. Unified S-Expression Action Orchestrator (`step-disruptor-tactical-micro!`)
;; =============================================================================

;; Execute a full offensive + defensive Disruptor/Nova micro step and emit clean
;; S-expression action commands compatible with `bot-runtime.rkt`:
;;   - `(purification-nova uid tx ty)`
;;   - `(move uid tx ty)`  (Nova homing `733`, caster standoff/retreat `694`, `split`/`pre-split`)
;;   - `(blink uid tx ty)` (emergency Stalker Blink dodge)
;;   - `(attack-unit uid enemy-disruptor-tag)` (lethal active-cast fizzle snipe)
(: step-disruptor-tactical-micro!
   (->* ((Listof Any) (Listof Any))
        (#:tracker (Option disruptor-tactical-tracker)
         #:current-frame Integer
         #:blink-researched? Boolean
         #:home-x Real
         #:home-y Real)
        (Listof (Listof Any))))
(define (step-disruptor-tactical-micro! ally-units enemy-units
                                        #:tracker [tr-arg #f]
                                        #:current-frame [current-frame 0]
                                        #:blink-researched? [blink-researched? #t]
                                        #:home-x [home-x 32.0]
                                        #:home-y [home-y 32.0])
  (define-values (ally-casters ally-novas)
    (if (fast-units-have-disruptor-or-nova? ally-units)
        (extract-disruptor-casters+novas ally-units)
        (values '() '())))
  (define-values (enemy-casters enemy-novas)
    (if (fast-units-have-disruptor-or-nova? enemy-units)
        (extract-disruptor-casters+novas enemy-units)
        (values '() '())))
  (define has-ally-d-or-n? : Boolean (or (pair? ally-casters) (pair? ally-novas)))
  (define has-enemy-d-or-n? : Boolean (or (pair? enemy-casters) (pair? enemy-novas)))
  (define has-active-novas? : Boolean
    (and tr-arg
         (> (hash-count (disruptor-tactical-tracker-nova-table tr-arg)) 0)))
  (cond
    [(and (not has-ally-d-or-n?)
          (not has-enemy-d-or-n?)
          (not has-active-novas?))
     '()]
    [else
     (define tr (or tr-arg (make-disruptor-tactical-tracker)))
     (parameterize ([internal-ally-casters ally-casters]
                    [internal-ally-novas ally-novas]
                    [internal-enemy-casters enemy-casters]
                    [internal-enemy-novas enemy-novas]
                    [internal-skip-sync? #t])
       (sync-tracker-state! tr ally-units enemy-units current-frame)
       (define nova-active?
         (> (hash-count (disruptor-tactical-tracker-nova-table tr)) 0))

       (define cast-plans : (Listof nova-cast-plan)
         (if has-ally-d-or-n?
             (plan-disruptor-nova-casts-core ally-units enemy-units tr current-frame
                                             DISRUPTOR-MIN-WORTHWHILE-SCORE
                                             DISRUPTOR-MAX-REACH-RANGE
                                             DISRUPTOR-VOLLEY-DECONFLICT-DIST
                                             #f)
             '()))
       (define cast-tags (map nova-cast-plan-caster-tag cast-plans))

       (define steer-orders : (Listof nova-steer-order)
         (if (or has-ally-d-or-n? nova-active?)
             (steer-purification-novas-core ally-units enemy-units tr current-frame #f)
             '()))
       (define kite-orders : (Listof disruptor-kite-order)
         (if has-ally-d-or-n?
             (kite-disruptor-casters-core ally-units enemy-units tr current-frame
                                          home-x home-y cast-tags #f #f)
             '()))
       (define-values (dodge-orders snipe-evals)
         (if (or has-enemy-d-or-n? nova-active?)
             (values
              (plan-anti-nova-scatter ally-units enemy-units
                                      #:tracker tr
                                      #:current-frame current-frame
                                      #:blink-researched? blink-researched?
                                      #:home-x home-x
                                      #:home-y home-y)
              (evaluate-disruptor-snipe-and-cooldowns ally-units enemy-units
                                                      #:tracker tr
                                                      #:current-frame current-frame))
             (values '() '())))

       ;; Defensive dodges take priority over snipe attacks if the same unit is listed in both
       (define dodging-tags : (Setof Integer)
         (if (null? dodge-orders)
             (set)
             (list->set
              (for/list : (Listof Integer) ([d (in-list dodge-orders)])
                (anti-nova-dodge-order-unit-tag d)))))

       (define actions : (Listof (Listof Any)) '())
       (: emit! (-> (Listof Any) Void))
       (define (emit! a) (set! actions (cons a actions)))

       (for ([cp (in-list cast-plans)])
         (emit! (list 'purification-nova
                      (nova-cast-plan-caster-tag cp)
                      (nova-cast-plan-tx cp)
                      (nova-cast-plan-ty cp))))
       (for ([so (in-list steer-orders)])
         (emit! (list 'move
                      (nova-steer-order-nova-tag so)
                      (nova-steer-order-tx so)
                      (nova-steer-order-ty so))))
       (for ([ko (in-list kite-orders)]
             #:when (not (set-member? dodging-tags (disruptor-kite-order-unit-tag ko))))
         (emit! (list (disruptor-kite-order-action ko)
                      (disruptor-kite-order-unit-tag ko)
                      (disruptor-kite-order-tx ko)
                      (disruptor-kite-order-ty ko))))
       (for ([do (in-list dodge-orders)])
         (emit! (list (anti-nova-dodge-order-action do)
                      (anti-nova-dodge-order-unit-tag do)
                      (anti-nova-dodge-order-tx do)
                      (anti-nova-dodge-order-ty do))))
       (for ([se (in-list snipe-evals)]
             #:when (disruptor-snipe-eval-snipe-feasible? se))
         (define etag (disruptor-snipe-eval-enemy-tag se))
         (for ([att-id (in-list (disruptor-snipe-eval-attacker-tags se))]
               #:when (not (set-member? dodging-tags att-id)))
           (emit! (list 'attack-unit att-id etag))))

       (reverse actions))]))
