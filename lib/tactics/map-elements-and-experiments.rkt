#lang typed/racket/base

;; =============================================================================
;; `lib/tactics/map-elements-and-experiments.rkt`
;; Wave 1D Typed Tactics & Experimentation Framework:
;;   A. Strategy & Multi-Spot Experimentation Framework (`EXPERIMENT-CATALOG`,
;;      `select-match-experiment`, `format-experiment-log-tag`,
;;      `summarize-telemetry-by-experiment`)
;;   B. Interactive Map Elements: Worker-Only Paths / Mineral Walls &
;;      Destructible Rocks / Collapsible Rockslides
;;   C. Non-Standard Base Layouts: Variable Patch/Geyser Counts, Gold Minerals
;;      & Rich Vespene Geysers + Counter-Gold Harass
;;   D. Dropship Rescue of Trapped / Stuck / Islanded Units
;;   E. Warp Prism Warp-In Attacks & Nexus/Mothership Recall + Symmetric Counters
;; =============================================================================

(require racket/list
         racket/math
         racket/set
         racket/string
         typed/racket/unsafe
         "../sc2-types.rkt"
         "../sc2-geometry.rkt"
         (except-in "../sc2-game-constants.rkt" aabb-overlaps?))

;; Safe untyped bridge for inspecting heterogeneous unit/record hashes cleanly.
(module dyn-hash-ops racket/base
  (require racket/math
           racket/string)
  (provide dyn-hash-ref
           dyn-hash-has-key?
           dyn-getenv
           dyn-normalize-kebab-sym
           dyn-u-tag
           dyn-u-type-id
           dyn-u-raw-sym
           dyn-u-x
           dyn-u-y
           dyn-u-hp-opt
           dyn-u-max-hp
           dyn-u-shield
           dyn-u-energy
           dyn-u-progress
           dyn-enemy-recalling?
           dyn-base-plan-cache-ref
           dyn-base-plan-cache-set!)

  (define miss (gensym 'dyn-miss))
  (define normalize-cache (make-hasheq))
  (define base-plan-weak-cache (make-weak-hasheq))

  (define (dyn-base-plan-cache-ref tr sig)
    (define entry (and tr (hash-ref base-plan-weak-cache tr #f)))
    (and (pair? entry) (equal? (car entry) sig) (cdr entry)))

  (define (dyn-base-plan-cache-set! tr sig plan)
    (when tr
      (hash-set! base-plan-weak-cache tr (cons sig plan))))

  (define (dyn-hash-ref h k default)
    (if (hash? h)
        (let ([v (hash-ref h k miss)])
          (if (eq? v miss) default v))
        default))

  (define (dyn-hash-has-key? h k)
    (and (hash? h) (hash-has-key? h k)))

  (define (dyn-getenv name)
    (getenv name))

  (define (to-exact-int v default)
    (cond
      [(exact-integer? v) v]
      [(and (real? v) (not (nan? v)) (not (infinite? v)))
       (exact-round v)]
      [else default]))

  (define (to-finite-float v default)
    (if (and (real? v) (not (nan? v)) (not (infinite? v)))
        (if (flonum? v) v (exact->inexact v))
        default))

  (define (dyn-normalize-kebab-sym raw)
    (cond
      [(symbol? raw)
       (define cached (hash-ref normalize-cache raw miss))
       (if (eq? cached miss)
           (let* ([s (symbol->string raw)]
                  [res (if (regexp-match? #rx"[A-Z_ ]" s)
                           (dyn-normalize-kebab-sym s)
                           raw)])
             (when (< (hash-count normalize-cache) 4096)
               (hash-set! normalize-cache raw res))
             res)
           cached)]
      [(string? raw)
       (define s0 (string-trim raw))
       (if (string=? s0 "")
           'unknown
           (let* ([s1 (regexp-replace* #rx"([a-z0-9])([A-Z])" s0 "\\1-\\2")]
                  [s2 (regexp-replace* #rx"([A-Za-z])([0-9]+)" s1 "\\1-\\2")]
                  [s3 (regexp-replace* #rx"[_ ]+" s2 "-")]
                  [s4 (string-downcase s3)]
                  [s5 (regexp-replace* #rx"-+" s4 "-")])
             (string->symbol s5)))]
      [else 'unknown]))

  (define (dyn-u-tag u)
    (if (hash? u)
        (let ([v (or (hash-ref u 'id #f)
                     (hash-ref u 'tag #f)
                     (hash-ref u 'unit-tag #f))])
          (to-exact-int v 0))
        0))

  (define (dyn-u-type-id u)
    (if (hash? u)
        (let ([v (or (hash-ref u 'unit-type-id #f)
                     (hash-ref u 'unit_type #f)
                     (hash-ref u 'type-id #f))])
          (to-exact-int v 0))
        0))

  (define (dyn-u-raw-sym u)
    (if (hash? u)
        (let ([raw (or (hash-ref u 'type #f)
                       (hash-ref u 'type-sym #f)
                       (hash-ref u 'unit-type #f)
                       (hash-ref u 'unit-type-sym #f)
                       (hash-ref u 'unit_type #f)
                       (hash-ref u 'unit_type_sym #f)
                       (hash-ref u 'name #f)
                       'unknown)])
          (if (eq? raw 'unknown) 'unknown (dyn-normalize-kebab-sym raw)))
        'unknown))

  (define (dyn-u-x u)
    (if (hash? u)
        (to-finite-float (hash-ref u 'x 0.0) 0.0)
        0.0))

  (define (dyn-u-y u)
    (if (hash? u)
        (to-finite-float (hash-ref u 'y 0.0) 0.0)
        0.0))

  (define (dyn-u-hp-opt u)
    (if (hash? u)
        (let ([v1 (hash-ref u 'hp miss)])
          (if (eq? v1 miss)
              (let ([v2 (hash-ref u 'health miss)])
                (if (eq? v2 miss)
                    #f
                    (to-finite-float v2 0.0)))
              (to-finite-float v1 0.0)))
        #f))

  (define (dyn-u-max-hp u)
    (if (hash? u)
        (let ([v (or (hash-ref u 'max-hp #f)
                     (hash-ref u 'health-max #f)
                     (hash-ref u 'hp #f)
                     1.0)])
          (max 1.0 (to-finite-float v 1.0)))
        1.0))

  (define (dyn-u-shield u)
    (if (hash? u)
        (let ([v (or (hash-ref u 'shield #f)
                     (hash-ref u 'shields #f)
                     0.0)])
          (to-finite-float v 0.0))
        0.0))

  (define (dyn-u-energy u)
    (if (hash? u)
        (to-finite-float (hash-ref u 'energy 0.0) 0.0)
        0.0))

  (define (dyn-u-progress u)
    (if (hash? u)
        (let ([v (or (hash-ref u 'build-progress #f)
                     (hash-ref u 'progress #f))])
          (if v (to-finite-float v 1.0) 1.0))
        1.0))

  (define recall-buff-syms
    '(nexus-mass-recall mothership-mass-recall mass-recall recall temporal-field-recall))

  (define (dyn-enemy-recalling? e)
    (and (hash? e)
         (or (and (hash-ref e 'recalling? #f) #t)
             (and (hash-ref e 'is-recalling? #f) #t)
             (let ([bs (hash-ref e 'buffs '())])
               (and (pair? bs)
                    (let loop ([xs bs])
                      (cond
                        [(null? xs) #f]
                        [(memq (dyn-normalize-kebab-sym (car xs)) recall-buff-syms) #t]
                        [else (loop (cdr xs))]))))))))

(unsafe-require/typed (submod "." dyn-hash-ops)
  [dyn-hash-ref (-> Any Any Any Any)]
  [dyn-hash-has-key? (-> Any Any Boolean)]
  [dyn-getenv (-> String (U False String))]
  [dyn-normalize-kebab-sym (-> Any Symbol)]
  [dyn-u-tag (-> Any Integer)]
  [dyn-u-type-id (-> Any Integer)]
  [dyn-u-raw-sym (-> Any Symbol)]
  [dyn-u-x (-> Any Float)]
  [dyn-u-y (-> Any Float)]
  [dyn-u-hp-opt (-> Any (U False Float))]
  [dyn-u-max-hp (-> Any Float)]
  [dyn-u-shield (-> Any Float)]
  [dyn-u-energy (-> Any Float)]
  [dyn-u-progress (-> Any Float)]
  [dyn-enemy-recalling? (-> Any Boolean)]
  [dyn-base-plan-cache-ref (-> Any Any Any)]
  [dyn-base-plan-cache-set! (-> Any Any Any Void)])

(provide
 ;; A. Strategy & Multi-Spot Experimentation
 (struct-out StrategyExperimentSpec)
 (struct-out MatchExperimentSelection)
 EXPERIMENT-CATALOG
 select-match-experiment
 resolve-experiment-spot-coord
 format-experiment-log-tag
 extract-experiment-tag-info
 summarize-telemetry-by-experiment

 ;; Shared Tactical Directive Structs & Constants
 (struct-out MapElementDirective)
 (struct-out DropshipRescueDirective)
 (struct-out BaseResourceProfile)
 (struct-out NonstandardBasePlan)
 make-map-element-tracker
 map-element-tracker?

 ;; B. Mineral Walls, Worker-Only Seams, Destructible Rocks & Rockslides
 plan-mineral-wall-and-worker-path-tactics
 plan-destructible-rocks-and-rockslides

 ;; C. Non-Standard Bases, Gold Minerals & Rich Vespene Geysers
 compute-base-optimal-worker-allocation
 plan-nonstandard-base-resource-allocation
 plan-counter-enemy-gold-base

 ;; D. Dropship Rescue of Trapped Units
 plan-trapped-unit-dropship-rescue

 ;; E. Warp Prism Warp-In Attacks & Mothership/Nexus Recall + Counters
 plan-warp-prism-and-recall-tactics
 plan-counter-warp-prism-and-recall

 ;; Unified Stepper & S-Expression Conversion
 map-element-directives->sexps
 dropship-rescues->sexps
 step-map-elements-tactical-micro!)

;; =============================================================================
;; Shared Helpers & Unit Normalization
;; =============================================================================

(: WORKER-SYMS (Listof Symbol))
(define WORKER-SYMS '(drone scv probe))

(: TRANSPORT-SYMS (Listof Symbol))
(define TRANSPORT-SYMS '(medivac warp-prism warp-prism-phasing overlord-transport dropperlord))

(: RECALL-AOE-CASTER-SPELLS (Listof (Pairof Symbol Symbol)))
(define RECALL-AOE-CASTER-SPELLS
  '((high-templar . psi-storm)
    (infestor . fungal-growth)
    (infestor-burrowed . fungal-growth)
    (ravager . corrosive-bile)
    (disruptor . purification-nova)
    (ghost . emp-round)
    (raven . anti-armor-missile)))

(: GOLD-MINERAL-TYPE-IDS (Listof Integer))
(define GOLD-MINERAL-TYPE-IDS '(146 147 796 797 886 887))

(: THIN-WALL-MINERAL-TYPE-IDS (Listof Integer))
(define THIN-WALL-MINERAL-TYPE-IDS '(665 666 1996))

(: STANDARD-MINERAL-TYPE-IDS (Listof Integer))
(define STANDARD-MINERAL-TYPE-IDS '(146 147 341 483 665 666 796 797 884 885 886 887 1996))

(: RICH-GEYSER-TYPE-IDS (Listof Integer))
(define RICH-GEYSER-TYPE-IDS '(344))

(: STANDARD-GEYSER-TYPE-IDS (Listof Integer))
(define STANDARD-GEYSER-TYPE-IDS '(342 343 344 608 880 881))

(: COLLAPSIBLE-ROCK-TYPE-IDS (Listof Integer))
(define COLLAPSIBLE-ROCK-TYPE-IDS '(480 482 588 589 590 591 594 595 596 597 598 599 600 601 602))

(: DESTRUCTIBLE-ROCK-TYPE-IDS (Listof Integer))
(define DESTRUCTIBLE-ROCK-TYPE-IDS
  '(367 369 370 372 373 375 376 472 473 474 639 640 641 642 643 644 645 646 647 648 649 650 651 652 653 658))

(: cache-miss-thunk (-> Symbol))
(define (cache-miss-thunk) '__cache-miss__)

(: false-thunk (-> False))
(define (false-thunk) #f)

(: dist-2d-sq (-> Float Float Float Float Float))
(define (dist-2d-sq x1 y1 x2 y2)
  (define dx (- x1 x2))
  (define dy (- y1 y2))
  (+ (* dx dx) (* dy dy)))

(: NORMALIZE-SYM-CACHE (Mutable-HashTable Symbol Symbol))
(define NORMALIZE-SYM-CACHE (make-hasheq))

(: CANON-UNIT-STATS-CACHE (Mutable-HashTable Symbol (Immutable-HashTable Symbol (U Real Boolean Symbol))))
(define CANON-UNIT-STATS-CACHE (make-hasheq))

(: NONCOMBAT-SYM-CACHE (Mutable-HashTable Symbol Symbol))
(define NONCOMBAT-SYM-CACHE (make-hasheq))

(: GOLD-MINERAL-SYM-CACHE (Mutable-HashTable Symbol Symbol))
(define GOLD-MINERAL-SYM-CACHE (make-hasheq))

(: MINERAL-SYM-CACHE (Mutable-HashTable Symbol Symbol))
(define MINERAL-SYM-CACHE (make-hasheq))

(: RICH-GEYSER-SYM-CACHE (Mutable-HashTable Symbol Symbol))
(define RICH-GEYSER-SYM-CACHE (make-hasheq))

(: GEYSER-SYM-CACHE (Mutable-HashTable Symbol Symbol))
(define GEYSER-SYM-CACHE (make-hasheq))

(: COLLAPSIBLE-ROCK-SYM-CACHE (Mutable-HashTable Symbol Symbol))
(define COLLAPSIBLE-ROCK-SYM-CACHE (make-hasheq))

(: DESTRUCTIBLE-ROCK-SYM-CACHE (Mutable-HashTable Symbol Symbol))
(define DESTRUCTIBLE-ROCK-SYM-CACHE (make-hasheq))

(: normalize-kebab-sym (-> Any Symbol))
(define normalize-kebab-sym dyn-normalize-kebab-sym)

(: u-tag (-> Any Integer))
(define (u-tag u) (dyn-u-tag u))

(: u-type-id (-> Any Integer))
(define (u-type-id u) (dyn-u-type-id u))

(: u-raw-sym (-> Any Symbol))
(define (u-raw-sym u) (dyn-u-raw-sym u))

(: u-sym (-> Any Symbol))
(define (u-sym u)
  (define rsym (dyn-u-raw-sym u))
  (cond
    [(not (eq? rsym 'unknown)) rsym]
    [else
     (define tid (dyn-u-type-id u))
     (cond
       [(memv tid '(146 147 796 797 886 887)) 'rich-mineral-field]
       [(memv tid '(665 666)) 'lab-mineral-field]
       [(= tid 1996) 'mineral-field-450]
       [(memv tid '(341 483 884 885)) 'mineral-field]
       [(= tid 344) 'rich-vespene-geyser]
       [(memv tid '(342 343 608 880 881)) 'vespene-geyser]
       [(memv tid COLLAPSIBLE-ROCK-TYPE-IDS) 'collapsible-rock-tower]
       [(memv tid DESTRUCTIBLE-ROCK-TYPE-IDS) 'destructible-rocks]
       [(= tid 136) 'warp-prism-phasing]
       [(= tid 81) 'warp-prism]
       [(= tid 10) 'mothership]
       [(= tid 59) 'nexus]
       [(= tid 54) 'medivac]
       [(= tid 893) 'overlord-transport]
       [else 'unknown])]))

(: u-x (-> Any Float))
(define (u-x u) (dyn-u-x u))

(: u-y (-> Any Float))
(define (u-y u) (dyn-u-y u))

(: u-hp (-> Any Float))
(define (u-hp u)
  (or (dyn-u-hp-opt u)
      (let ([mhp (safe-finite-real (hash-ref (u-combat-stats u) 'max-hp (lambda () 0.0)) 0.0)])
        (if (> mhp 0.0) mhp 100.0))))

(: u-max-hp (-> Any Float))
(define (u-max-hp u) (dyn-u-max-hp u))

(: u-shield (-> Any Float))
(define (u-shield u) (dyn-u-shield u))

(: u-ehp (-> Any Float))
(define (u-ehp u)
  (+ (u-hp u) (u-shield u)))

(: u-energy (-> Any Float))
(define (u-energy u) (dyn-u-energy u))

(: u-progress (-> Any Float))
(define (u-progress u) (dyn-u-progress u))

(: u-flying? (-> Any Boolean))
(define (u-flying? u)
  (define fl (dyn-hash-ref u 'is-flying #f))
  (if (boolean? fl)
      fl
      (let ([canon (sc2-canonical-unit-sym (u-sym u))])
        (safe-boolean (hash-ref (sc2-unit-combat-stats canon) 'flying? (lambda () #f))))))

(: safe-boolean (-> Any Boolean))
(define (safe-boolean v)
  (and v #t))

(: u-burrowed? (-> Any Boolean))
(define (u-burrowed? u)
  (define b (dyn-hash-ref u 'is-burrowed #f))
  (or (and (boolean? b) b)
      (let ([s (symbol->string (u-sym u))])
        (string-suffix? s "-burrowed"))))

(: u-contents (-> Any Integer))
(define (u-contents u)
  (safe-nonneg-int
   (or (dyn-hash-ref u 'mineral-contents #f)
       (dyn-hash-ref u 'vespene-contents #f)
       (dyn-hash-ref u 'contents #f)
       (dyn-hash-ref u 'mineral-remaining #f)
       (dyn-hash-ref u 'vespene-remaining #f)
       (let ([sym (u-sym u)])
         (cond
           [(eq? sym 'mineral-field-450) 450]
           [(memq sym '(mineral-field-750 rich-mineral-field-750 lab-mineral-field-750
                        purifier-mineral-field-750 purifier-rich-mineral-field-750
                        battle-station-mineral-field-750))
            750]
           [(memq sym '(vespene-geyser rich-vespene-geyser protoss-vespene-geyser
                        purifier-vespene-geyser shakuras-vespene-geyser
                        space-platform-geyser))
            2250]
           [else 900])))
   900))

(: u-orders (-> Any (Listof Any)))
(define (u-orders u)
  (define os (safe-list (dyn-hash-ref u 'orders '())))
  (if (pair? os)
      os
      (let ([ab (or (dyn-hash-ref u 'order-ability-id #f)
                    (dyn-hash-ref u 'order #f))])
        (if ab
            (list (hasheq 'ability-id ab
                          'target-x (dyn-hash-ref u 'order-target-x #f)
                          'target-y (dyn-hash-ref u 'order-target-y #f)
                          'target-unit-tag (dyn-hash-ref u 'order-target-tag #f)))
            '()))))

(: u-busy-important? (-> Any Boolean))
(define (u-busy-important? u)
  (for/or : Boolean ([o (in-list (u-orders u))])
    (define ab (if (hash? o) (dyn-hash-ref o 'ability-id #f) o))
    (safe-boolean
     (memq (sc2-order-protection-class ab)
           (ann '(morph channel mode-switch) (Listof Symbol))))))

(: sym-combat-stats (-> Symbol (Immutable-HashTable Symbol (U Real Boolean Symbol))))
(define (sym-combat-stats sym)
  (define cached (hash-ref CANON-UNIT-STATS-CACHE sym false-thunk))
  (if cached
      cached
      (let ([st (sc2-unit-combat-stats (sc2-canonical-unit-sym sym))])
        (hash-set! CANON-UNIT-STATS-CACHE sym st)
        st)))

(: fast-noncombat-sym? (-> Symbol Boolean))
(define (fast-noncombat-sym? sym)
  (define cached (hash-ref NONCOMBAT-SYM-CACHE sym cache-miss-thunk))
  (if (eq? cached '__cache-miss__)
      (let ([res (sc2-non-combat-or-summon-sym? sym)])
        (hash-set! NONCOMBAT-SYM-CACHE sym (if res '__t__ '__f__))
        res)
      (eq? cached '__t__)))

(: u-combat-stats (-> Any (Immutable-HashTable Symbol (U Real Boolean Symbol))))
(define (u-combat-stats u)
  (sym-combat-stats (u-sym u)))

(: u-ground-dps (-> Any Float))
(define (u-ground-dps u)
  (safe-finite-real (hash-ref (u-combat-stats u) 'ground-dps (lambda () 0.0)) 0.0))

(: u-air-dps (-> Any Float))
(define (u-air-dps u)
  (safe-finite-real (hash-ref (u-combat-stats u) 'air-dps (lambda () 0.0)) 0.0))

(: u-total-dps (-> Any Float))
(define (u-total-dps u)
  (define st (u-combat-stats u))
  (max (safe-finite-real (hash-ref st 'ground-dps (lambda () 0.0)) 0.0)
       (safe-finite-real (hash-ref st 'air-dps (lambda () 0.0)) 0.0)))

(: u-max-range (-> Any Float))
(define (u-max-range u)
  (define st (u-combat-stats u))
  (max (safe-finite-real (hash-ref st 'ground-range (lambda () 0.0)) 0.0)
       (safe-finite-real (hash-ref st 'air-range (lambda () 0.0)) 0.0)))

(: u-power (-> Any Float))
(define (u-power u)
  (define explicit-pow (dyn-hash-ref u 'power #f))
  (if (and (real? explicit-pow) (finite-real? explicit-pow) (> explicit-pow 0.0))
      (->float explicit-pow)
      (let* ([st (u-combat-stats u)]
             [raw-ehp (u-ehp u)]
             [hp (if (> raw-ehp 0.0)
                     raw-ehp
                     (+ (safe-finite-real (hash-ref st 'max-hp (lambda () 0.0)) 0.0)
                        (safe-finite-real (hash-ref st 'max-shield (lambda () 0.0)) 0.0)))]
             [dps (max (safe-finite-real (hash-ref st 'ground-dps (lambda () 0.0)) 0.0)
                       (safe-finite-real (hash-ref st 'air-dps (lambda () 0.0)) 0.0))])
        (+ (* 12.0 dps) (* 0.35 hp)))))

(: combat-unit? (-> Any Boolean))
(define (combat-unit? u)
  (define sym (u-sym u))
  (and (> (u-tag u) 0)
       (not (memq sym WORKER-SYMS))
       (not (fast-noncombat-sym? sym))
       (let ([st (sym-combat-stats sym)])
         (> (max (safe-finite-real (hash-ref st 'ground-dps (lambda () 0.0)) 0.0)
                 (safe-finite-real (hash-ref st 'air-dps (lambda () 0.0)) 0.0))
            0.0))))

(: worker-unit? (-> Any Boolean))
(define (worker-unit? u)
  (and (> (u-tag u) 0)
       (safe-boolean (memq (u-sym u) WORKER-SYMS))))

(: gold-mineral-sym? (-> Symbol Boolean))
(define (gold-mineral-sym? sym)
  (define cached (hash-ref GOLD-MINERAL-SYM-CACHE sym cache-miss-thunk))
  (if (eq? cached '__cache-miss__)
      (let ([res (or (safe-boolean (memq sym '(rich-mineral-field rich-mineral-field-750
                                                purifier-rich-mineral-field purifier-rich-mineral-field-750
                                                battle-station-mineral-field battle-station-mineral-field-750
                                                gold-mineral-field)))
                     (regexp-match? #px"(?:rich|battle[-_]?station|gold).*mineral" (symbol->string sym)))])
        (hash-set! GOLD-MINERAL-SYM-CACHE sym (if res '__t__ '__f__))
        res)
      (eq? cached '__t__)))

(: gold-mineral-unit? (-> Any Boolean))
(define (gold-mineral-unit? u)
  (define sym (u-sym u))
  (or (gold-mineral-sym? sym)
      (let ([tid (u-type-id u)])
        (and (> tid 0) (safe-boolean (memv tid GOLD-MINERAL-TYPE-IDS))))))

(: mineral-sym? (-> Symbol Boolean))
(define (mineral-sym? sym)
  (define cached (hash-ref MINERAL-SYM-CACHE sym cache-miss-thunk))
  (if (eq? cached '__cache-miss__)
      (let ([res (or (gold-mineral-sym? sym)
                     (regexp-match? #rx"mineral" (symbol->string sym)))])
        (hash-set! MINERAL-SYM-CACHE sym (if res '__t__ '__f__))
        res)
      (eq? cached '__t__)))

(: mineral-unit? (-> Any Boolean))
(define (mineral-unit? u)
  (define sym (u-sym u))
  (or (mineral-sym? sym)
      (let ([tid (u-type-id u)])
        (and (> tid 0)
             (or (safe-boolean (memv tid GOLD-MINERAL-TYPE-IDS))
                 (safe-boolean (memv tid STANDARD-MINERAL-TYPE-IDS))
                 (safe-boolean (memv tid THIN-WALL-MINERAL-TYPE-IDS)))))))

(: thin-wall-mineral? (-> Any Boolean))
(define (thin-wall-mineral? u)
  (and (mineral-unit? u)
       (let ([sym (u-sym u)]
             [tid (u-type-id u)]
             [cnt (u-contents u)])
         (and (> cnt 0)
              (or (<= cnt 300)
                  (and (<= cnt 450)
                       (or (safe-boolean (memv tid THIN-WALL-MINERAL-TYPE-IDS))
                           (safe-boolean (memq sym '(mineral-field-450 lab-mineral-field lab-mineral-field-750))))))))))

(: rich-geyser-sym? (-> Symbol Boolean))
(define (rich-geyser-sym? sym)
  (define cached (hash-ref RICH-GEYSER-SYM-CACHE sym cache-miss-thunk))
  (if (eq? cached '__cache-miss__)
      (let ([res (or (safe-boolean (memq sym '(rich-vespene-geyser rich-geyser
                                                extractor-rich assimilator-rich refinery-rich)))
                     (regexp-match? #px"rich.*(?:vespene|geyser)|(?:extractor|assimilator|refinery)-rich"
                                    (symbol->string sym)))])
        (hash-set! RICH-GEYSER-SYM-CACHE sym (if res '__t__ '__f__))
        res)
      (eq? cached '__t__)))

(: rich-geyser-unit? (-> Any Boolean))
(define (rich-geyser-unit? u)
  (define sym (u-sym u))
  (or (rich-geyser-sym? sym)
      (let ([tid (u-type-id u)])
        (and (> tid 0) (safe-boolean (memv tid RICH-GEYSER-TYPE-IDS))))))

(: geyser-sym? (-> Symbol Boolean))
(define (geyser-sym? sym)
  (define cached (hash-ref GEYSER-SYM-CACHE sym cache-miss-thunk))
  (if (eq? cached '__cache-miss__)
      (let ([res (and (not (memq sym '(extractor assimilator refinery extractor-rich assimilator-rich refinery-rich)))
                      (or (rich-geyser-sym? sym)
                          (regexp-match? #rx"(?:vespene|geyser)" (symbol->string sym))))])
        (hash-set! GEYSER-SYM-CACHE sym (if res '__t__ '__f__))
        res)
      (eq? cached '__t__)))

(: geyser-unit? (-> Any Boolean))
(define (geyser-unit? u)
  (define sym (u-sym u))
  (and (not (memq sym '(extractor assimilator refinery extractor-rich assimilator-rich refinery-rich)))
       (or (geyser-sym? sym)
           (let ([tid (u-type-id u)])
             (and (> tid 0)
                  (or (safe-boolean (memv tid RICH-GEYSER-TYPE-IDS))
                      (safe-boolean (memv tid STANDARD-GEYSER-TYPE-IDS))))))))

(: active-gas-building? (-> Any Boolean))
(define (active-gas-building? u)
  (define sym (u-sym u))
  (and (safe-boolean
        (memq sym '(extractor extractor-rich assimilator assimilator-rich refinery refinery-rich)))
       (>= (u-progress u) 0.99)))

(: townhall-building? (-> Any Boolean))
(define (townhall-building? u)
  (safe-boolean (memq (u-sym u) SC2-TOWNHALL-STRUCTURE-SYMS)))

(: collapsible-rock-sym? (-> Symbol Boolean))
(define (collapsible-rock-sym? sym)
  (define cached (hash-ref COLLAPSIBLE-ROCK-SYM-CACHE sym cache-miss-thunk))
  (if (eq? cached '__cache-miss__)
      (let ([res (regexp-match? #rx"collapsible|rock-tower" (symbol->string sym))])
        (hash-set! COLLAPSIBLE-ROCK-SYM-CACHE sym (if res '__t__ '__f__))
        res)
      (eq? cached '__t__)))

(: collapsible-rock-unit? (-> Any Boolean))
(define (collapsible-rock-unit? u)
  (define sym (u-sym u))
  (or (collapsible-rock-sym? sym)
      (let ([tid (u-type-id u)])
        (and (> tid 0) (safe-boolean (memv tid COLLAPSIBLE-ROCK-TYPE-IDS))))))

(: destructible-rock-sym? (-> Symbol Boolean))
(define (destructible-rock-sym? sym)
  (define cached (hash-ref DESTRUCTIBLE-ROCK-SYM-CACHE sym cache-miss-thunk))
  (if (eq? cached '__cache-miss__)
      (let ([res (or (regexp-match? #rx"destructible" (symbol->string sym))
                     (safe-boolean
                      (memq sym (ann '(rocks unbuildable-rocks unbuildable-plates
                                       unbuildable-bricks-destructible unbuildable-plates-destructible)
                                     (Listof Symbol)))))])
        (hash-set! DESTRUCTIBLE-ROCK-SYM-CACHE sym (if res '__t__ '__f__))
        res)
      (eq? cached '__t__)))

(: destructible-rock-unit? (-> Any Boolean))
(define (destructible-rock-unit? u)
  (define sym (u-sym u))
  (define tid (u-type-id u))
  (and (not (or (collapsible-rock-sym? sym)
                (and (> tid 0) (safe-boolean (memv tid COLLAPSIBLE-ROCK-TYPE-IDS)))))
       (or (destructible-rock-sym? sym)
           (and (> tid 0) (safe-boolean (memv tid DESTRUCTIBLE-ROCK-TYPE-IDS))))))

(: resolve-xy (-> Any (Option (Pairof Float Float))))
(define (resolve-xy item)
  (cond
    [(point2d? item) (cons (point2d-x item) (point2d-y item))]
    [(hash? item)
     (define x (dyn-hash-ref item 'x #f))
     (define y (dyn-hash-ref item 'y #f))
     (if (and (finite-real? x) (finite-real? y))
         (cons (safe-finite-real x 0.0) (safe-finite-real y 0.0))
         #f)]
    [(pair? item)
     (define a (car item))
     (define b (cdr item))
     (cond
       [(and (finite-real? a) (finite-real? b))
        (cons (safe-finite-real a 0.0) (safe-finite-real b 0.0))]
       [(and (finite-real? a) (pair? b) (finite-real? (car b)))
        (cons (safe-finite-real a 0.0) (safe-finite-real (car b) 0.0))]
       [else #f])]
    [else #f]))

(: sym-list-contains? (-> Any (Listof Symbol) Boolean))
(define (sym-list-contains? v targets)
  (for/or : Boolean ([x (in-list (safe-list v))])
    (define s (normalize-kebab-sym x))
    (safe-boolean (memq s targets))))

;; =============================================================================
;; Shared Directive & Tracker Structs
;; =============================================================================

(struct MapElementDirective
  ([kind : Symbol]
   [actor-tag : Integer]
   [target-tag : Integer]
   [tx : Float]
   [ty : Float]
   [priority : Float]
   [reason : Symbol]
   [sexp : (Listof Any)])
  #:transparent)

(struct DropshipRescueDirective
  ([kind : Symbol]              ;; 'pickup | 'unload | 'unphase
   [transport-tag : Integer]
   [unit-tag : Integer]
   [tx : Float]
   [ty : Float]
   [reason : Symbol]
   [sexp : (Listof Any)]
   [unload-sexp : (Listof Any)])
  #:transparent)

(struct BaseResourceProfile
  ([base-id : Integer]
   [x : Float]
   [y : Float]
   [patch-count : Nonnegative-Integer]
   [gold-patch-count : Nonnegative-Integer]
   [geyser-count : Nonnegative-Integer]
   [rich-geyser-count : Nonnegative-Integer]
   [active-refineries : Nonnegative-Integer]
   [total-minerals : Integer]
   [total-gas : Integer]
   [optimal-mineral-workers : Nonnegative-Integer]
   [optimal-gas-workers : Nonnegative-Integer]
   [optimal-total-workers : Nonnegative-Integer]
   [expansion-priority-bonus : Float])
  #:transparent)

(struct NonstandardBasePlan
  ([base-profiles : (Listof BaseResourceProfile)]
   [total-optimal-mineral-workers : Nonnegative-Integer]
   [total-optimal-gas-workers : Nonnegative-Integer]
   [total-optimal-workers : Nonnegative-Integer]
   [ranked-expansion-pads : (Listof BaseResourceProfile)]
   [rebalance-directives : (Listof MapElementDirective)])
  #:transparent)

(struct UnitProgressState
  ([anchor-x : Float]
   [anchor-y : Float]
   [anchor-frame : Integer]
   [trapped-since-frame : (Option Integer)])
  #:transparent)

(struct MapElementTracker
  ([unit-progress : (Mutable-HashTable Integer UnitProgressState)]
   [rescue-assignments : (Mutable-HashTable Integer Integer)])
  #:transparent)

(: make-map-element-tracker (-> MapElementTracker))
(define (make-map-element-tracker)
  (MapElementTracker (make-hasheqv) (make-hasheqv)))

(: map-element-tracker? (-> Any Boolean))
(define (map-element-tracker? v)
  (MapElementTracker? v))

;; =============================================================================
;; Section A: Strategy & Multi-Spot Experimentation Framework
;; =============================================================================

(struct StrategyExperimentSpec
  ([id : Symbol]
   [race : KnownRace]
   [matchups : (Listof Symbol)]
   [probability-pct : Float]
   [spot-labels : (Listof Symbol)]
   [spot-offsets : (Listof (Pairof Float Float))]
   [tags : (Listof Symbol)]
   [description : String])
  #:transparent)

(struct MatchExperimentSelection
  ([experiment-id : Symbol]
   [race : KnownRace]
   [matchup : Symbol]
   [spot-idx : Nonnegative-Integer]
   [spot-label : Symbol]
   [spot-offset : (Pairof Float Float)]
   [probability-pct : Float]
   [source : Symbol])
  #:transparent)

(: DEFAULT-EXPERIMENT-SPOTS (Listof Symbol))
(define DEFAULT-EXPERIMENT-SPOTS
  '(off-path-nw-pocket
    off-path-se-pocket
    off-path-third-flank
    off-path-dead-air-cliff))

;; 4 distinct normalized geometry offsets (`perp-sign`, `along-enemy-fraction`) so each
;; spot index `0..3` yields a spatially separated off-path coordinate relative to base axes.
(: DEFAULT-SPOT-OFFSETS (Listof (Pairof Float Float)))
(define DEFAULT-SPOT-OFFSETS
  (list (cons 30.0 0.36)
        (cons -30.0 0.38)
        (cons 25.0 0.28)
        (cons -26.0 0.46)))

(: EXPERIMENT-CATALOG (Listof StrategyExperimentSpec))
(define EXPERIMENT-CATALOG
  (list
   ;; --- Zerg ---
   (StrategyExperimentSpec
    'standard-macro 'Zerg '() 50.0
    DEFAULT-EXPERIMENT-SPOTS DEFAULT-SPOT-OFFSETS '(baseline macro)
    "Standard pro-calibrated Zerg macro control arm.")
   (StrategyExperimentSpec
    'exp-zerg-burrow-dodge-base-trap 'Zerg '() 12.5
    DEFAULT-EXPERIMENT-SPOTS DEFAULT-SPOT-OFFSETS '(burrow ambush trap)
    "Early Burrow + reactive damage dodge & stationary detection ring base-trap ambush.")
   (StrategyExperimentSpec
    'exp-zerg-dropperlord-queen-creep 'Zerg '() 12.5
    DEFAULT-EXPERIMENT-SPOTS DEFAULT-SPOT-OFFSETS '(dropperlord queen creep-highway)
    "Dropperlord + Creep Queen remote highway/4th expansion creep expeditions.")
   (StrategyExperimentSpec
    'exp-zerg-multi-angle-mini-drops 'Zerg '() 12.5
    DEFAULT-EXPERIMENT-SPOTS DEFAULT-SPOT-OFFSETS '(drop multi-angle ling-bane-roach)
    "1-3 simultaneous peripheral edge mini-Overlord drops across enemy mineral lines.")
   (StrategyExperimentSpec
    'exp-zerg-off-path-proxy-hatch-ravager 'Zerg '() 12.5
    DEFAULT-EXPERIMENT-SPOTS DEFAULT-SPOT-OFFSETS '(proxy off-path ravager)
    "Off-scout-path proxy Hatchery Ravager + Spine pressure from rotated pocket spots.")

   ;; --- Terran ---
   (StrategyExperimentSpec
    'standard-macro 'Terran '() 50.0
    DEFAULT-EXPERIMENT-SPOTS DEFAULT-SPOT-OFFSETS '(baseline macro)
    "Standard pro-calibrated Terran macro control arm.")
   (StrategyExperimentSpec
    'exp-terran-widow-mine-drop-runby 'Terran '() 12.5
    DEFAULT-EXPERIMENT-SPOTS DEFAULT-SPOT-OFFSETS '(widow-mine drop runby)
    "Medivac Widow Mine main drop synced within <=48f of Hellion/Marine natural runby.")
   (StrategyExperimentSpec
    'exp-terran-multi-base-viking-landings 'Terran '() 12.5
    DEFAULT-EXPERIMENT-SPOTS DEFAULT-SPOT-OFFSETS '(viking multi-base harass)
    "Simultaneous paired Viking Assault landings into multiple enemy mineral lines.")
   (StrategyExperimentSpec
    'exp-terran-raven-autoturret-harass 'Terran '() 12.5
    DEFAULT-EXPERIMENT-SPOTS DEFAULT-SPOT-OFFSETS '(raven auto-turret harass)
    "Peripheral Raven Auto-Turret & Anti-Armor harassment against greedy bases.")
   (StrategyExperimentSpec
    'exp-terran-off-path-proxy-rax-fact 'Terran '() 12.5
    DEFAULT-EXPERIMENT-SPOTS DEFAULT-SPOT-OFFSETS '(proxy off-path rax-factory)
    "Off-scout-path proxy Barracks/Factory Cyclone-Hellion pressure across 4 pocket spots.")

   ;; --- Protoss ---
   (StrategyExperimentSpec
    'standard-macro 'Protoss '() 50.0
    DEFAULT-EXPERIMENT-SPOTS DEFAULT-SPOT-OFFSETS '(baseline macro)
    "Standard pro-calibrated Protoss macro control arm.")
   (StrategyExperimentSpec
    'exp-protoss-multi-base-adept-shade 'Protoss '() 12.5
    DEFAULT-EXPERIMENT-SPOTS DEFAULT-SPOT-OFFSETS '(adept shade multi-base)
    "Multi-base Adept shade split attack forcing divided opponent defense.")
   (StrategyExperimentSpec
    'exp-protoss-double-oracle-stasis 'Protoss '() 12.5
    DEFAULT-EXPERIMENT-SPOTS DEFAULT-SPOT-OFFSETS '(oracle pulsar stasis)
    "Double Oracle Pulsar Beam timing + mineral-line/choke Stasis Ward traps.")
   (StrategyExperimentSpec
    'exp-protoss-warp-prism-recall-timing 'Protoss '() 12.5
    DEFAULT-EXPERIMENT-SPOTS DEFAULT-SPOT-OFFSETS '(warp-prism recall timing)
    "Warp Prism warp-in backstab paired with Strategic Recall extraction/home defense.")
   (StrategyExperimentSpec
    'exp-protoss-off-path-proxy-robo-stargate 'Protoss '() 12.5
    DEFAULT-EXPERIMENT-SPOTS DEFAULT-SPOT-OFFSETS '(proxy off-path robo-stargate)
    "Off-scout-path proxy Robo/Stargate pressure from 4 rotated stealth spots.")))

(: mix-seed (-> Integer Integer Nonnegative-Integer))
(define (mix-seed seed salt)
  (define s0 : Integer (bitwise-and (abs (+ (* (+ seed 1013904223) 1664525) (* salt 2654435761))) #x3fffffff))
  (define s1 : Integer (bitwise-and (bitwise-xor s0 (arithmetic-shift s0 -13)) #x3fffffff))
  (define s2 : Integer (bitwise-and (* (+ s1 17) 224682251) #x3fffffff))
  (max 0 (bitwise-xor s2 (arithmetic-shift s2 -11))))

(: sym-salt (-> Symbol Integer))
(define (sym-salt sym)
  (for/fold ([acc : Integer 17])
            ([ch (in-string (symbol->string sym))])
    (bitwise-and (+ (* acc 131) (char->integer ch)) #x3fffffff)))

(: non-empty-env (-> Any (Option String)))
(define (non-empty-env v)
  (cond
    [(string? v)
     (define t (string-trim v))
     (if (string=? t "") #f t)]
    [(symbol? v) (symbol->string v)]
    [else #f]))

(: spec-matches-race-matchup? (-> StrategyExperimentSpec KnownRace Symbol Boolean))
(define (spec-matches-race-matchup? spec race matchup)
  (and (eq? (StrategyExperimentSpec-race spec) race)
       (let ([ms (StrategyExperimentSpec-matchups spec)])
         (or (null? ms) (safe-boolean (memq matchup ms))))))

(: pick-weighted-spec (-> (Listof StrategyExperimentSpec) Float StrategyExperimentSpec))
(define (pick-weighted-spec specs roll-pct)
  (define total-w : Float
    (for/fold ([acc : Float 0.0]) ([sp (in-list specs)])
      (+ acc (max 0.0 (StrategyExperimentSpec-probability-pct sp)))))
  (if (<= total-w 0.0)
      (car specs)
      (let ([target : Float (* (clamp-real (/ roll-pct 100.0) 0.0 0.999999) total-w)])
        (let loop ([rem : (Listof StrategyExperimentSpec) specs]
                   [acc : Float 0.0])
          (define sp (car rem))
          (define nxt (+ acc (max 0.0 (StrategyExperimentSpec-probability-pct sp))))
          (if (or (null? (cdr rem)) (< target nxt))
              sp
              (loop (cdr rem) nxt))))))

(: select-match-experiment
   (->* (Any Any)
        (Integer
         #:seed (Option Integer)
         #:env-id (Option Any)
         #:env-pct (Option Any)
         #:env-spot (Option Any)
         #:catalog (Listof StrategyExperimentSpec))
        MatchExperimentSelection))
(define (select-match-experiment raw-race raw-matchup [seed-pos 0]
                                 #:seed [seed-kw #f]
                                 #:env-id [env-id-arg #f]
                                 #:env-pct [env-pct-arg #f]
                                 #:env-spot [env-spot-arg #f]
                                 #:catalog [catalog EXPERIMENT-CATALOG])
  (define race : KnownRace (normalize-known-race raw-race))
  (define matchup : Symbol
    (let ([s (normalize-kebab-sym raw-matchup)])
      (cond
        [(matchup-sym? raw-matchup) raw-matchup]
        [(symbol? raw-matchup)
         (define rs (symbol->string raw-matchup))
         (if (regexp-match? #px"^(Z|T|P)v(Z|T|P)$" rs)
             raw-matchup
             (resolve-matchup-symbol race raw-matchup))]
        [(string? raw-matchup)
         (if (regexp-match? #px"^(Z|T|P)v(Z|T|P)$" (string-trim raw-matchup))
             (string->symbol (string-trim raw-matchup))
             (resolve-matchup-symbol race raw-matchup))]
        [else (resolve-matchup-symbol race 'Unknown)])))
  (define seed : Integer (or seed-kw seed-pos))

  (define race-specs : (Listof StrategyExperimentSpec)
    (let ([matched (filter (lambda ([sp : StrategyExperimentSpec])
                             (spec-matches-race-matchup? sp race matchup))
                           catalog)])
      (if (pair? matched)
          matched
          (list (StrategyExperimentSpec
                 'standard-macro race '() 100.0
                 DEFAULT-EXPERIMENT-SPOTS DEFAULT-SPOT-OFFSETS '(baseline)
                 "Fallback standard macro.")))))

  (define env-id-str : (Option String)
    (non-empty-env (or env-id-arg (dyn-getenv "MOTHMAN_EXPERIMENT_ID"))))
  (define env-pct-raw : Any
    (or env-pct-arg (dyn-getenv "MOTHMAN_EXPERIMENT_PCT")))
  (define env-pct-val : (Option Float)
    (cond
      [(and (real? env-pct-raw) (finite-real? env-pct-raw))
       (clamp-real env-pct-raw 0.0 100.0)]
      [(string? env-pct-raw)
       (define n (string->number (string-trim env-pct-raw)))
       (if (and (real? n) (finite-real? n))
           (clamp-real n 0.0 100.0)
           #f)]
      [else #f]))
  (define env-spot-raw : Any
    (or env-spot-arg (dyn-getenv "MOTHMAN_EXPERIMENT_SPOT")))

  (define override-spec : (Option StrategyExperimentSpec)
    (and env-id-str
         (let ([wanted (string->symbol (string-downcase env-id-str))]
               [exact-sym (string->symbol env-id-str)])
           (findf (lambda ([sp : StrategyExperimentSpec])
                    (or (eq? (StrategyExperimentSpec-id sp) exact-sym)
                        (eq? (StrategyExperimentSpec-id sp) wanted)))
                  race-specs))))

  (define roll-hash : Nonnegative-Integer
    (mix-seed seed (+ (sym-salt race) (* 7 (sym-salt matchup)))))
  (define roll-pct : Float (->float (/ (modulo roll-hash 10000) 100.0)))

  (define-values (chosen-spec chosen-pct source-sym)
    (cond
      [override-spec
       (cond
         [(not env-pct-val)
          (values override-spec 100.0 'env-override)]
         [(or (>= env-pct-val 100.0)
              (and (> env-pct-val 0.0) (< roll-pct env-pct-val)))
          (values override-spec env-pct-val 'env-pct-roll)]
         [else
          (define others
            (filter (lambda ([sp : StrategyExperimentSpec])
                      (not (eq? (StrategyExperimentSpec-id sp)
                                (StrategyExperimentSpec-id override-spec))))
                    race-specs))
          (define fallback
            (if (pair? others)
                (pick-weighted-spec others roll-pct)
                override-spec))
          (values fallback (StrategyExperimentSpec-probability-pct fallback) 'env-pct-fallback)])]
      [else
       (define sp (pick-weighted-spec race-specs roll-pct))
       (values sp (StrategyExperimentSpec-probability-pct sp) 'seed-roll)]))

  (define labels (StrategyExperimentSpec-spot-labels chosen-spec))
  (define offsets (StrategyExperimentSpec-spot-offsets chosen-spec))
  (define k : Positive-Integer (max 1 (length labels)))
  (define explicit-spot : (Option Nonnegative-Integer)
    (cond
      [(exact-nonnegative-integer? env-spot-raw) env-spot-raw]
      [(string? env-spot-raw)
       (define n (string->number (string-trim env-spot-raw)))
       (if (exact-nonnegative-integer? n) n #f)]
      [else #f]))
  (define spot-idx : Nonnegative-Integer
    (if explicit-spot
        (modulo explicit-spot k)
        (modulo (mix-seed (+ seed 37) (+ 991 (sym-salt (StrategyExperimentSpec-id chosen-spec)))) k)))
  (define spot-label : Symbol
    (if (< spot-idx (length labels))
        (list-ref labels spot-idx)
        'off-path-nw-pocket))
  (define spot-offset : (Pairof Float Float)
    (if (< spot-idx (length offsets))
        (list-ref offsets spot-idx)
        (cons 28.0 0.36)))
  (MatchExperimentSelection
   (StrategyExperimentSpec-id chosen-spec)
   race
   matchup
   spot-idx
   spot-label
   spot-offset
   (round1 chosen-pct)
   source-sym))

(: resolve-experiment-spot-coord (-> MatchExperimentSelection Real Real Real Real (Values Float Float)))
(define (resolve-experiment-spot-coord sel our-x our-y enemy-x enemy-y)
  (define ax : Float (safe-finite-real our-x 32.5))
  (define ay : Float (safe-finite-real our-y 32.5))
  (define ex : Float (safe-finite-real enemy-x 160.5))
  (define ey : Float (safe-finite-real enemy-y 160.5))
  (define dx : Float (- ex ax))
  (define dy : Float (- ey ay))
  (define len : Float (max 1.0 (dist-2d 0.0 0.0 dx dy)))
  (define ux : Float (/ dx len))
  (define uy : Float (/ dy len))
  (define px : Float (- uy))
  (define py : Float ux)
  (define off (MatchExperimentSelection-spot-offset sel))
  (define perp-dist : Float (car off))
  (define along-frac : Float (cdr off))
  (define base-x : Float (+ ex (* (- ax ex) along-frac)))
  (define base-y : Float (+ ey (* (- ay ey) along-frac)))
  (define raw-pt (clamp-point-to-map (+ base-x (* perp-dist px))
                                    (+ base-y (* perp-dist py))
                                    8.0 240.0))
  (values (point2d-x raw-pt) (point2d-y raw-pt)))

(: format-experiment-log-tag (-> MatchExperimentSelection String))
(define (format-experiment-log-tag sel)
  (define pct-str (real->decimal-string (round1 (MatchExperimentSelection-probability-pct sel)) 1))
  (format "[EXP:~a|race:~a|matchup:~a|spot:~a:~a|p:~a%]"
          (MatchExperimentSelection-experiment-id sel)
          (MatchExperimentSelection-race sel)
          (MatchExperimentSelection-matchup sel)
          (MatchExperimentSelection-spot-idx sel)
          (MatchExperimentSelection-spot-label sel)
          pct-str))

(: rx-group (-> (Pairof String (Listof (Option String))) Natural String))
(define (rx-group m idx)
  (define lst : (Listof (Option String)) m)
  (if (< idx (length lst))
      (or (list-ref lst idx) "")
      ""))

(: extract-experiment-tag-info (-> Any (Option (Immutable-HashTable Symbol Any))))
(define (extract-experiment-tag-info raw)
  (cond
    [(MatchExperimentSelection? raw)
     (hasheq 'experiment-id (MatchExperimentSelection-experiment-id raw)
             'race (MatchExperimentSelection-race raw)
             'matchup (MatchExperimentSelection-matchup raw)
             'spot-idx (MatchExperimentSelection-spot-idx raw)
             'spot-label (MatchExperimentSelection-spot-label raw)
             'probability-pct (MatchExperimentSelection-probability-pct raw))]
    [(string? raw)
     (define m1
       (regexp-match #px"\\[EXP:([^|\\]]+)\\|race:([^|\\]]+)\\|matchup:([^|\\]]+)\\|spot:([0-9]+):([^|\\]]+)\\|p:([0-9.]+)%\\]"
                     raw))
     (cond
       [m1
        (define sp-n (string->number (rx-group m1 4)))
        (define pct-n (string->number (rx-group m1 6)))
        (hasheq 'experiment-id (string->symbol (rx-group m1 1))
                'race (normalize-known-race (rx-group m1 2))
                'matchup (string->symbol (rx-group m1 3))
                'spot-idx (safe-nonneg-int sp-n 0)
                'spot-label (string->symbol (rx-group m1 5))
                'probability-pct (safe-finite-real pct-n 0.0))]
       [else
        (define m2 (regexp-match #px"(?:^|\\s)exp=([A-Za-z0-9_.-]+)@spot([0-9]+)" raw))
        (if m2
            (hasheq 'experiment-id (string->symbol (rx-group m2 1))
                    'spot-idx (safe-nonneg-int (string->number (rx-group m2 2)) 0))
            #f)])]
    [else #f]))

(: summarize-telemetry-by-experiment (-> Any (Listof (Immutable-HashTable Symbol Any))))
(define (summarize-telemetry-by-experiment raw-input)
  (define records : (Listof Any)
    (cond
      [(list? raw-input) raw-input]
      [(hash? raw-input)
       (safe-list (or (dyn-hash-ref raw-input 'reports #f)
                      (dyn-hash-ref raw-input 'records #f)
                      '()))]
      [else '()]))

  (define-type ExpBucketKey (List Symbol Symbol Symbol Nonnegative-Integer))
  ;; Mutable accumulator vector: #(games wins losses ties sum-worker-kills sum-supply-delta)
  (define buckets : (Mutable-HashTable ExpBucketKey (Vector Integer Integer Integer Integer Float Float))
    (make-hash))

  (for ([rec (in-list records)]
        #:when (hash? rec))
    (define raw-race (or (dyn-hash-ref rec 'race #f)
                         (dyn-hash-ref rec 'our-race #f)
                         (dyn-hash-ref rec 'our_race #f)
                         'Unknown))
    (define race-sym : Symbol
      (let ([rstr (string-downcase (format "~a" raw-race))])
        (cond
          [(or (string=? rstr "z") (string=? rstr "zerg")) 'Zerg]
          [(or (string=? rstr "t") (string=? rstr "terran")) 'Terran]
          [(or (string=? rstr "p") (string=? rstr "protoss")) 'Protoss]
          [else 'Unknown])))
    (define raw-mu (or (dyn-hash-ref rec 'matchup #f)
                       (let ([er (or (dyn-hash-ref rec 'opp-race #f)
                                     (dyn-hash-ref rec 'opp_race #f)
                                     (dyn-hash-ref rec 'enemy-race #f))])
                         (and er (known-race? race-sym) (resolve-matchup-symbol race-sym er)))
                       'Unknown))
    (define mu-sym : Symbol
      (cond
        [(symbol? raw-mu) raw-mu]
        [(string? raw-mu) (string->symbol raw-mu)]
        [else 'Unknown]))

    (define parsed-tag
      (or (extract-experiment-tag-info (dyn-hash-ref rec 'experiment-tag #f))
          (extract-experiment-tag-info (dyn-hash-ref rec 'experiment_tag #f))
          (extract-experiment-tag-info (dyn-hash-ref rec 'tag #f))
          (for/or : (Option (Immutable-HashTable Symbol Any))
                  ([tg (in-list (safe-list (dyn-hash-ref rec 'tags '())))])
            (extract-experiment-tag-info tg))))

    (define raw-eid
      (or (dyn-hash-ref rec 'experiment-id #f)
          (dyn-hash-ref rec 'experiment_id #f)
          (dyn-hash-ref rec 'exp-id #f)
          (and parsed-tag (hash-ref parsed-tag 'experiment-id (lambda () #f)))
          'untagged))
    (define eid-sym : Symbol
      (cond
        [(symbol? raw-eid) raw-eid]
        [(string? raw-eid)
         (define tr (string-trim raw-eid))
         (if (string=? tr "") 'untagged (string->symbol tr))]
        [else 'untagged]))

    (define raw-spot
      (or (dyn-hash-ref rec 'spot-idx #f)
          (dyn-hash-ref rec 'spot_idx #f)
          (dyn-hash-ref rec 'experiment-spot-idx #f)
          (dyn-hash-ref rec 'experiment_spot_idx #f)
          (and parsed-tag (hash-ref parsed-tag 'spot-idx (lambda () 0)))
          0))
    (define spot-idx : Nonnegative-Integer (safe-nonneg-int raw-spot 0))

    (define key : ExpBucketKey (list race-sym mu-sym eid-sym spot-idx))
    (define acc : (Vector Integer Integer Integer Integer Float Float)
      (hash-ref! buckets key (lambda () (vector 0 0 0 0 0.0 0.0))))

    (define res-str
      (let ([wflag (dyn-hash-ref rec 'win? (dyn-hash-ref rec 'won? 'unset))])
        (cond
          [(boolean? wflag) (if wflag "WIN" "LOSS")]
          [else (string-upcase (format "~a" (dyn-hash-ref rec 'result "UNKNOWN")))])))
    (define wk
      (safe-finite-real (or (dyn-hash-ref rec 'worker-kills #f)
                            (dyn-hash-ref rec 'worker_kills #f)
                            (dyn-hash-ref rec 'workers-killed #f)
                            (dyn-hash-ref rec 'opp-workers-killed #f)
                            0.0)
                        0.0))
    (define sd
      (safe-finite-real
       (or (dyn-hash-ref rec 'supply-delta #f)
           (dyn-hash-ref rec 'supply_delta #f)
           (dyn-hash-ref rec 'max-supply-delta #f)
           (let ([os (dyn-hash-ref rec 'our-supply #f)]
                 [es (dyn-hash-ref rec 'opp-supply #f)])
             (if (and (real? os) (finite-real? os) (real? es) (finite-real? es))
                 (- (->float os) (->float es))
                 0.0)))
       0.0))

    (vector-set! acc 0 (+ (vector-ref acc 0) 1))
    (cond
      [(string=? res-str "WIN")  (vector-set! acc 1 (+ (vector-ref acc 1) 1))]
      [(string=? res-str "LOSS") (vector-set! acc 2 (+ (vector-ref acc 2) 1))]
      [(string=? res-str "TIE")  (vector-set! acc 3 (+ (vector-ref acc 3) 1))]
      [else (void)])
    (vector-set! acc 4 (+ (vector-ref acc 4) wk))
    (vector-set! acc 5 (+ (vector-ref acc 5) sd)))

  (define sorted-keys : (Listof ExpBucketKey)
    (sort (hash-keys buckets)
          (lambda ([a : ExpBucketKey] [b : ExpBucketKey])
            (define ka (format "~a|~a|~a|~a" (car a) (cadr a) (caddr a) (cadddr a)))
            (define kb (format "~a|~a|~a|~a" (car b) (cadr b) (caddr b) (cadddr b)))
            (string<? ka kb))))

  (for/list : (Listof (Immutable-HashTable Symbol Any))
            ([k (in-list sorted-keys)])
    (define acc (hash-ref buckets k))
    (define g (max 0 (vector-ref acc 0)))
    (define w (max 0 (vector-ref acc 1)))
    (define l (max 0 (vector-ref acc 2)))
    (define t (max 0 (vector-ref acc 3)))
    (define dec (max 1 (+ w l t)))
    (define wr : Float (round2 (/ (->float w) (->float dec))))
    (define wr-pct : Float (round1 (* 100.0 (/ (->float w) (->float dec)))))
    (define mean-wk : Float (if (> g 0) (round2 (/ (vector-ref acc 4) (->float g))) 0.0))
    (define mean-sd : Float (if (> g 0) (round2 (/ (vector-ref acc 5) (->float g))) 0.0))
    (hasheq 'race (car k)
            'matchup (cadr k)
            'experiment-id (caddr k)
            'spot-idx (cadddr k)
            'games g
            'wins w
            'losses l
            'ties t
            'win-rate wr
            'win-rate-pct wr-pct
            'mean-worker-kills mean-wk
            'mean-supply-delta mean-sd)))

;; =============================================================================
;; Section B: Worker-Only Paths, Mineral Walls & Destructible/Collapsible Rocks
;; =============================================================================

(: find-far-mineral-patch (-> Float Float Float Float (Listof Any) Integer (Option Any)))
(define (find-far-mineral-patch wx wy home-x home-y neutrals exclude-tag)
  (define dx : Float (- wx home-x))
  (define dy : Float (- wy home-y))
  (define dlen : Float (max 1.0 (dist-2d 0.0 0.0 dx dy)))
  (define ux : Float (/ dx dlen))
  (define uy : Float (/ dy dlen))
  (define best : (Option Any) #f)
  (define best-score : Float -1e9)
  (for ([n (in-list neutrals)]
        #:when (and (mineral-unit? n)
                    (> (u-tag n) 0)
                    (not (= (u-tag n) exclude-tag))
                    (> (u-contents n) 0)))
    (define nx (u-x n))
    (define ny (u-y n))
    (define d-seam (dist-2d wx wy nx ny))
    ;; Candidate is on the far side of the wall seam along our outward vector
    (define proj (+ (* (- nx wx) ux) (* (- ny wy) uy)))
    (when (and (>= d-seam 1.5) (<= d-seam 14.0) (> proj 1.0))
      (define sc (- proj (* 0.25 d-seam)))
      (when (> sc best-score)
        (set! best-score sc)
        (set! best n))))
  best)

(: plan-mineral-wall-and-worker-path-tactics
   (->* ((Listof Any) (Listof Any) (Listof Any))
        ((Listof Any)
         #:frame Integer
         #:home-x Real
         #:home-y Real
         #:enemy-x Real
         #:enemy-y Real
         #:excavate-min-frame Integer)
        (Listof MapElementDirective)))
(define (plan-mineral-wall-and-worker-path-tactics
         ally-workers ally-combat neutral-units [enemy-units '()]
         #:frame [frame 0]
         #:home-x [home-x 32.5]
         #:home-y [home-y 32.5]
         #:enemy-x [enemy-x 160.5]
         #:enemy-y [enemy-y 160.5]
         #:excavate-min-frame [excavate-min-frame 6720])
  (define hx : Float (safe-finite-real home-x 32.5))
  (define hy : Float (safe-finite-real home-y 32.5))
  (define ex : Float (safe-finite-real enemy-x 160.5))
  (define ey : Float (safe-finite-real enemy-y 160.5))

  (define thin-patches : (Listof Any)
    (filter (lambda ([n : Any])
              (and (thin-wall-mineral? n) (> (u-tag n) 0)))
            neutral-units))
  (cond
    [(null? thin-patches) '()]
    [else
     (define avail-workers : (Listof Any)
       (filter (lambda ([w : Any])
                 (and (worker-unit? w) (not (u-busy-important? w))))
               ally-workers))
     (define avail-combat : (Listof Any)
       (filter (lambda ([u : Any])
                 (and (combat-unit? u)
                      (not (u-flying? u))
                      (not (u-busy-important? u))))
               ally-combat))

     (define used-workers : (Mutable-HashTable Integer Boolean) (make-hasheqv))
     (define used-combat : (Mutable-HashTable Integer Boolean) (make-hasheqv))
     (define out : (Listof MapElementDirective) '())
     (: emit! (-> MapElementDirective Void))
     (define (emit! d) (set! out (cons d out)))

     ;; Sort seams by proximity to the home <-> enemy path so tactical walls act first
     (define sorted-seams
       (sort thin-patches
             (lambda ([a : Any] [b : Any])
               (< (point-to-segment-dist (u-x a) (u-y a) hx hy ex ey)
                  (point-to-segment-dist (u-x b) (u-y b) hx hy ex ey)))))

     ;; 1. Excavate backdoor mineral wall with up to 2 workers after 5:00 (`frame >= 6720`)
     (when (>= frame excavate-min-frame)
       (define lead-seam (car sorted-seams))
       (define sx (u-x lead-seam))
       (define sy (u-y lead-seam))
       (define sid (u-tag lead-seam))
       (define nearest-workers
         (sort (filter (lambda ([w : Any])
                         (not (hash-has-key? used-workers (u-tag w))))
                       avail-workers)
               (lambda ([a : Any] [b : Any])
                 (< (dist-2d (u-x a) (u-y a) sx sy)
                    (dist-2d (u-x b) (u-y b) sx sy)))))
       (for ([w (in-list (take nearest-workers (min 2 (length nearest-workers))))])
         (define wid (u-tag w))
         (hash-set! used-workers wid #t)
         (emit! (MapElementDirective
                 'excavate-mineral-wall-backdoor wid sid sx sy 55.0
                 'open-mineral-wall-after-5min
                 (list 'harvest-mineral wid sid)))))

     ;; 2. Worker-only mineral-walk backdoor slip through 1-tile mineral seams
     (let ([seam (findf (lambda ([s : Any])
                          (pair? (filter (lambda ([w : Any])
                                           (not (hash-has-key? used-workers (u-tag w))))
                                         avail-workers)))
                        sorted-seams)])
       (when seam
         (define sx (u-x seam))
         (define sy (u-y seam))
         (define sid (u-tag seam))
         (define far-patch (find-far-mineral-patch sx sy hx hy neutral-units sid))
         (define target-patch (or far-patch seam))
         (define tid (u-tag target-patch))
         (define tx (u-x target-patch))
         (define ty (u-y target-patch))
         (define scout-worker
           (argmin (lambda ([w : Any]) (dist-2d (u-x w) (u-y w) sx sy))
                   (filter (lambda ([w : Any])
                             (not (hash-has-key? used-workers (u-tag w))))
                           avail-workers)))
         (define wid (u-tag scout-worker))
         (hash-set! used-workers wid #t)
         (emit! (MapElementDirective
                 'worker-mineral-walk-backdoor wid tid tx ty 52.0
                 (if far-patch 'mineral-walk-far-side-seam 'mineral-walk-wall-seam)
                 (list 'mineral-walk wid tid tx ty)))))

     ;; 3. Symmetric counter: guard mineral-wall seams close to our base or threatened by enemies
     (for ([seam (in-list sorted-seams)])
       (define sx (u-x seam))
       (define sy (u-y seam))
       (define sid (u-tag seam))
       (define d-home (dist-2d sx sy hx hy))
       (define enemy-near?
         (for/or : Boolean ([e (in-list enemy-units)])
           (<= (dist-2d (u-x e) (u-y e) sx sy) 18.0)))
       (when (or (<= d-home 38.0) enemy-near?)
         (define free-guards
           (filter (lambda ([u : Any])
                     (and (not (hash-has-key? used-combat (u-tag u)))
                          (<= (dist-2d (u-x u) (u-y u) sx sy) 42.0)))
                   avail-combat))
         (define sorted-guards
           (sort free-guards
                 (lambda ([a : Any] [b : Any])
                   (< (dist-2d (u-x a) (u-y a) sx sy)
                      (dist-2d (u-x b) (u-y b) sx sy)))))
         (define guard-pt (clamp-point-to-map (step-toward-2d sx sy hx hy 1.8) 4.0 248.0))
         (for ([g (in-list (take sorted-guards (min 2 (length sorted-guards))))])
           (define gid (u-tag g))
           (hash-set! used-combat gid #t)
           (emit! (MapElementDirective
                   'guard-mineral-wall-backdoor gid sid
                   (point2d-x guard-pt) (point2d-y guard-pt)
                   (if enemy-near? 78.0 48.0)
                   (if enemy-near? 'enemy-at-backdoor-seam 'hold-backdoor-seam)
                   (list 'hold-position gid (point2d-x guard-pt) (point2d-y guard-pt)))))))

     (reverse out)]))

(: rock-near-expansion-or-highway?
   (-> Float Float (Listof Any) Float Float Float Float Float Float Boolean))
(define (rock-near-expansion-or-highway? rx ry expansion-pads hx hy nx ny ex ey)
  (or (for/or : Boolean ([pad (in-list expansion-pads)])
        (define xy (resolve-xy pad))
        (and xy (<= (dist-2d-sq rx ry (car xy) (cdr xy)) 196.0)))
      (<= (point-to-segment-dist rx ry hx hy ex ey) 11.0)
      (<= (point-to-segment-dist rx ry nx ny ex ey) 11.0)
      (and (null? expansion-pads)
           (<= (dist-2d-sq rx ry hx hy) 1764.0))))

(: rock-collapse-xy (-> Any (Values Float Float)))
(define (rock-collapse-xy tower)
  (define cx (dyn-hash-ref tower 'collapse-x #f))
  (define cy (dyn-hash-ref tower 'collapse-y #f))
  (if (and (finite-real? cx) (finite-real? cy))
      (values (safe-finite-real cx 0.0) (safe-finite-real cy 0.0))
      (values (u-x tower) (u-y tower))))

(: plan-destructible-rocks-and-rockslides
   (->* ((Listof Any) (Listof Any) (Listof Any))
        (#:expansion-pads (Listof Any)
         #:home-x Real
         #:home-y Real
         #:nat-x Real
         #:nat-y Real
         #:enemy-x Real
         #:enemy-y Real
         #:pre-damage-hp-pct Real
         #:enemy-clear-radius Real)
        (Listof MapElementDirective)))
(define (plan-destructible-rocks-and-rockslides
         ally-combat neutral-units enemy-units
         #:expansion-pads [expansion-pads '()]
         #:home-x [home-x 32.5]
         #:home-y [home-y 32.5]
         #:nat-x [nat-x 45.0]
         #:nat-y [nat-y 45.0]
         #:enemy-x [enemy-x 160.5]
         #:enemy-y [enemy-y 160.5]
         #:pre-damage-hp-pct [pre-dmg-pct-arg 0.15]
         #:enemy-clear-radius [clear-rad-arg 18.0])
  (define hx : Float (safe-finite-real home-x 32.5))
  (define hy : Float (safe-finite-real home-y 32.5))
  (define nx : Float (safe-finite-real nat-x 45.0))
  (define ny : Float (safe-finite-real nat-y 45.0))
  (define ex : Float (safe-finite-real enemy-x 160.5))
  (define ey : Float (safe-finite-real enemy-y 160.5))
  (define-values (collapsible-towers std-rocks)
    (let loop : (Values (Listof Any) (Listof Any))
              ([ns : (Listof Any) neutral-units]
               [col : (Listof Any) '()]
               [std : (Listof Any) '()])
      (cond
        [(null? ns) (values (reverse col) (reverse std))]
        [else
         (define n (car ns))
         (cond
           [(and (collapsible-rock-unit? n) (> (u-tag n) 0) (> (u-hp n) 0.0))
            (loop (cdr ns) (cons n col) std)]
           [(and (destructible-rock-unit? n)
                 (> (u-tag n) 0)
                 (> (u-hp n) 0.0)
                 (rock-near-expansion-or-highway? (u-x n) (u-y n)
                                                  expansion-pads
                                                  hx hy nx ny ex ey))
            (loop (cdr ns) col (cons n std))]
           [else (loop (cdr ns) col std)])])))

  (cond
    [(and (null? collapsible-towers) (null? std-rocks)) '()]
    [else
     (define pre-dmg-pct : Float (clamp-real pre-dmg-pct-arg 0.05 0.30))
     (define clear-rad : Float (max 6.0 (safe-finite-real clear-rad-arg 18.0)))
     (define clear-rad-sq : Float (* clear-rad clear-rad))

     (define usable-allies : (Listof Any)
       (filter (lambda ([u : Any])
                 (and (combat-unit? u) (not (u-busy-important? u))))
               ally-combat))
     (define used-tags : (Mutable-HashTable Integer Boolean) (make-hasheqv))
     (define out : (Listof MapElementDirective) '())
     (: emit! (-> MapElementDirective Void))
     (define (emit! d) (set! out (cons d out)))

     ;; 1. Symmetric Counter First (highest priority): evacuate friendly units out of
     ;;    3.5-tile enemy collapsible rockslide zones when enemy threats are nearby!
     (for ([tw (in-list collapsible-towers)])
       (define tid (u-tag tw))
       (define-values (cx cy) (rock-collapse-xy tw))
       (define enemy-near-tower?
         (for/or : Boolean ([e (in-list enemy-units)])
           (<= (dist-2d-sq (u-x e) (u-y e) (u-x tw) (u-y tw)) 256.0)))
       (when enemy-near-tower?
         (for ([u (in-list usable-allies)]
               #:when (and (not (u-flying? u))
                           (<= (dist-2d-sq (u-x u) (u-y u) cx cy) 14.44)))
           (define uid (u-tag u))
           (hash-set! used-tags uid #t)
           (define safe-pt (clamp-point-to-map (step-away-2d (u-x u) (u-y u) cx cy 5.5) 4.0 248.0))
           (emit! (MapElementDirective
                   'avoid-enemy-rockslide-zone uid tid
                   (point2d-x safe-pt) (point2d-y safe-pt) 92.0
                   'evacuate-3.5t-rockslide-danger-zone
                   (list 'move uid (point2d-x safe-pt) (point2d-y safe-pt)))))))

     ;; 2. Collapsible rockslide traps: trigger immediately at >=3 enemies in 3.5t zone,
     ;;    or pre-damage down to <= 15% HP during peacetime (0 enemies within 18t).
     (for ([tw (in-list collapsible-towers)])
       (define tid (u-tag tw))
       (define tx (u-x tw))
       (define ty (u-y tw))
       (define-values (cx cy) (rock-collapse-xy tw))
       (define hp-pct (/ (u-hp tw) (u-max-hp tw)))
       (define enemies-in-zone
         (count (lambda ([e : Any])
                  (and (not (u-flying? e))
                       (<= (dist-2d-sq (u-x e) (u-y e) cx cy) 12.25)))
                enemy-units))
       (define allies-in-zone
         (count (lambda ([u : Any])
                  (and (not (u-flying? u))
                       (<= (dist-2d-sq (u-x u) (u-y u) cx cy) 12.25)))
                usable-allies))
       (define enemies-within-clear
         (count (lambda ([e : Any])
                  (<= (dist-2d-sq (u-x e) (u-y e) tx ty) clear-rad-sq))
                enemy-units))

       (cond
         [(>= enemies-in-zone 3)
          (define shooters
            (sort
             (filter (lambda ([u : Any])
                       (define r (+ (u-max-range u) 8.0))
                       (and (not (hash-has-key? used-tags (u-tag u)))
                            (> (u-total-dps u) 0.0)
                            (<= (dist-2d-sq (u-x u) (u-y u) tx ty) (* r r))))
                     usable-allies)
             (lambda ([a : Any] [b : Any])
               (< (dist-2d-sq (u-x a) (u-y a) tx ty)
                  (dist-2d-sq (u-x b) (u-y b) tx ty)))))
          (for ([u (in-list shooters)])
            (define uid (u-tag u))
            (hash-set! used-tags uid #t)
            (emit! (MapElementDirective
                    'trigger-rockslide-trap uid tid tx ty 95.0
                    'enemy-cluster>=3-in-collapse-zone
                    (list 'attack-unit uid tid))))]
         [(and (= enemies-within-clear 0)
               (> hp-pct pre-dmg-pct)
               (= allies-in-zone 0))
          (define chippers
            (sort
             (filter (lambda ([u : Any])
                       (and (not (hash-has-key? used-tags (u-tag u)))
                            (> (u-ground-dps u) 0.0)
                            (<= (dist-2d-sq (u-x u) (u-y u) tx ty) 484.0)
                            (> (dist-2d-sq (u-x u) (u-y u) cx cy) 12.96)))
                     usable-allies)
             (lambda ([a : Any] [b : Any])
               (< (dist-2d-sq (u-x a) (u-y a) tx ty)
                  (dist-2d-sq (u-x b) (u-y b) tx ty)))))
          (for ([u (in-list (take chippers (min 2 (length chippers))))])
            (define uid (u-tag u))
            (hash-set! used-tags uid #t)
            (emit! (MapElementDirective
                    'pre-damage-rockslide-tower uid tid tx ty 42.0
                    'peacetime-chip-to-15pct
                    (list 'attack-unit uid tid))))]))

     ;; 3. Pre-clear standard destructible rocks on expansion pads & attack highways
     ;;    only when 0 enemy units are within 18.0 tiles.
     (for ([rk (in-list std-rocks)])
       (define rid (u-tag rk))
       (define rx (u-x rk))
       (define ry (u-y rk))
       (define enemies-nearby?
         (for/or : Boolean ([e (in-list enemy-units)])
           (<= (dist-2d-sq (u-x e) (u-y e) rx ry) clear-rad-sq)))
       (unless enemies-nearby?
         (define clearers
           (sort
            (filter (lambda ([u : Any])
                      (and (not (hash-has-key? used-tags (u-tag u)))
                           (> (u-ground-dps u) 0.0)
                           (<= (dist-2d-sq (u-x u) (u-y u) rx ry) 784.0)
                           ;; Never distract an ally actively engaged near enemy combat
                           (not (for/or : Boolean ([e (in-list enemy-units)])
                                  (<= (dist-2d-sq (u-x u) (u-y u) (u-x e) (u-y e)) 196.0)))))
                    usable-allies)
            (lambda ([a : Any] [b : Any])
              (< (dist-2d-sq (u-x a) (u-y a) rx ry)
                 (dist-2d-sq (u-x b) (u-y b) rx ry)))))
         (for ([u (in-list (take clearers (min 6 (length clearers))))])
           (define uid (u-tag u))
           (hash-set! used-tags uid #t)
           (emit! (MapElementDirective
                   'clear-destructible-rocks uid rid rx ry 46.0
                   'peacetime-highway-or-pad-rock-clear
                   (list 'attack-unit uid rid))))))

     (reverse out)]))

;; =============================================================================
;; Section C: Non-Standard Base Layouts, Gold Minerals & Rich Vespene Geysers
;; =============================================================================

(define-type ResourceXY (Vector Any Float Float))

(: dedup-resources (-> (Listof Any) (Listof Any)))
(define (dedup-resources items)
  (cond
    [(or (null? items) (null? (cdr items))) items]
    [else
     (define seen-tags : (Mutable-HashTable Integer Boolean) (make-hasheqv))
     (define seen-coords : (Mutable-HashTable Integer Boolean) (make-hasheqv))
     (reverse
      (for/fold ([acc : (Listof Any) '()])
                ([it (in-list items)])
        (define tg (u-tag it))
        (define ck (+ (* 16384 (+ 1024 (exact-round (* 10.0 (u-x it)))))
                      (+ 1024 (exact-round (* 10.0 (u-y it))))))
        (cond
          [(and (> tg 0) (hash-has-key? seen-tags tg)) acc]
          [(hash-has-key? seen-coords ck) acc]
          [else
           (when (> tg 0) (hash-set! seen-tags tg #t))
           (hash-set! seen-coords ck #t)
           (cons it acc)])))]))

(: extract-resource-xys (-> (Listof Any) (Listof ResourceXY)))
(define (extract-resource-xys xs)
  (for/list : (Listof ResourceXY) ([x (in-list xs)])
    (vector x (u-x x) (u-y x))))

(: compute-base-optimal-worker-allocation-pre
   (-> Float Float Integer (Listof ResourceXY) (Listof ResourceXY) (Listof ResourceXY) BaseResourceProfile))
(define (compute-base-optimal-worker-allocation-pre bx by base-id all-minerals all-geysers all-gas-bldgs)
  (define near-minerals
    (let ([ms (for/fold ([acc : (Listof Any) '()]) ([r (in-list all-minerals)])
                (if (<= (dist-2d-sq bx by (vector-ref r 1) (vector-ref r 2)) 121.0)
                    (cons (vector-ref r 0) acc)
                    acc))])
      (dedup-resources (reverse ms))))
  (define raw-geysers
    (let ([gs (for/fold ([acc : (Listof Any) '()]) ([r (in-list all-geysers)])
                (if (<= (dist-2d-sq bx by (vector-ref r 1) (vector-ref r 2)) 121.0)
                    (cons (vector-ref r 0) acc)
                    acc))])
      (dedup-resources (reverse gs))))
  (define near-gas-bldgs
    (let ([bs (for/fold ([acc : (Listof Any) '()]) ([r (in-list all-gas-bldgs)])
                (if (<= (dist-2d-sq bx by (vector-ref r 1) (vector-ref r 2)) 121.0)
                    (cons (vector-ref r 0) acc)
                    acc))])
      (dedup-resources (reverse bs))))

  (define patch-count : Nonnegative-Integer (length near-minerals))
  (define gold-patch-count : Nonnegative-Integer (count gold-mineral-unit? near-minerals))
  (define total-minerals : Integer
    (for/sum : Integer ([m (in-list near-minerals)]) (u-contents m)))

  ;; Deduplicate geysers that sit underneath built refineries
  (define-values (geyser-count rich-geyser-count total-gas)
    (cond
      [(and (null? raw-geysers) (null? near-gas-bldgs))
       (values 0 0 0)]
      [else
       (let* ([slots : (Mutable-HashTable Integer Boolean) (make-hasheqv)]
              [rich-slots : (Mutable-HashTable Integer Boolean) (make-hasheqv)]
              [gas-acc : Integer 0])
         (for ([g (in-list raw-geysers)])
           (define key (+ (* 16384 (+ 1024 (exact-round (u-x g))))
                          (+ 1024 (exact-round (u-y g)))))
           (unless (hash-has-key? slots key)
             (hash-set! slots key #t)
             (set! gas-acc (+ gas-acc (u-contents g))))
           (when (rich-geyser-unit? g)
             (hash-set! rich-slots key #t)))
         (for ([rb (in-list near-gas-bldgs)])
           (define rbx (u-x rb))
           (define rby (u-y rb))
           (define key (+ (* 16384 (+ 1024 (exact-round rbx)))
                          (+ 1024 (exact-round rby))))
           ;; Merge if within 1.5 tiles of existing slot
           (define matched-near?
             (for/or : Boolean ([g (in-list raw-geysers)])
               (<= (dist-2d-sq rbx rby (u-x g) (u-y g)) 2.25)))
           (unless (or matched-near? (hash-has-key? slots key))
             (hash-set! slots key #t)
             (set! gas-acc (+ gas-acc (u-contents rb))))
           (when (rich-geyser-unit? rb)
             (hash-set! rich-slots key #t)))
         (values (hash-count slots) (hash-count rich-slots) gas-acc))]))

  (define active-refs : Nonnegative-Integer (length near-gas-bldgs))
  (define opt-min-workers : Nonnegative-Integer (* 2 patch-count))
  (define opt-gas-workers : Nonnegative-Integer (* 3 active-refs))
  (define opt-total-workers : Nonnegative-Integer (+ opt-min-workers opt-gas-workers))
  (define prio-bonus : Float
    (+ (if (> gold-patch-count 0) 35.0 0.0)
       (if (> rich-geyser-count 0) 25.0 0.0)))

  (BaseResourceProfile
   base-id bx by
   patch-count gold-patch-count
   geyser-count rich-geyser-count
   active-refs
   total-minerals total-gas
   opt-min-workers opt-gas-workers opt-total-workers
   prio-bonus))

(: compute-base-optimal-worker-allocation
   (->* (Real Real (Listof Any))
        ((Listof Any) Integer)
        BaseResourceProfile))
(define (compute-base-optimal-worker-allocation base-x base-y neutral-units
                                                [ally-buildings '()] [base-id 0])
  (define bx : Float (safe-finite-real base-x 32.5))
  (define by : Float (safe-finite-real base-y 32.5))
  (define-values (near-minerals near-geysers near-gas-n)
    (let loop : (Values (Listof Any) (Listof Any) (Listof Any))
              ([ns : (Listof Any) neutral-units]
               [ms : (Listof Any) '()]
               [gs : (Listof Any) '()]
               [bs : (Listof Any) '()])
      (cond
        [(null? ns) (values (reverse ms) (reverse gs) (reverse bs))]
        [else
         (define n (car ns))
         (if (<= (dist-2d-sq bx by (u-x n) (u-y n)) 121.0)
             (cond
               [(and (mineral-unit? n) (> (u-contents n) 0))
                (loop (cdr ns) (cons n ms) gs bs)]
               [(and (geyser-unit? n) (> (u-contents n) 0))
                (loop (cdr ns) ms (cons n gs) bs)]
               [(active-gas-building? n)
                (loop (cdr ns) ms gs (cons n bs))]
               [else
                (loop (cdr ns) ms gs bs)])
             (loop (cdr ns) ms gs bs))])))
  (define near-gas-b
    (for/fold ([acc : (Listof Any) '()]) ([b (in-list ally-buildings)])
      (if (and (<= (dist-2d-sq bx by (u-x b) (u-y b)) 121.0)
               (active-gas-building? b))
          (cons b acc)
          acc)))
  (define ms-dedup (dedup-resources near-minerals))
  (define gs-dedup (dedup-resources near-geysers))
  (define bs-dedup (dedup-resources (append near-gas-n (reverse near-gas-b))))
  (compute-base-optimal-worker-allocation-pre
   bx by base-id
   (extract-resource-xys ms-dedup)
   (extract-resource-xys gs-dedup)
   (extract-resource-xys bs-dedup)))

(: plan-nonstandard-base-resource-allocation
   (->* ((Listof Any) (Listof Any))
        ((Listof Any) (Listof Any) (Listof Any))
        NonstandardBasePlan))
(define (plan-nonstandard-base-resource-allocation
         ally-bases neutral-units
         [candidate-pads '()] [ally-workers '()] [ally-buildings '()])
  (define townhall-list : (Listof Any)
    (let ([ths (filter (lambda ([b : Any])
                         (or (townhall-building? b)
                             (and (pair? b) (finite-real? (car b)))
                             (point2d? b)
                             (and (hash? b) (not (dyn-hash-has-key? b 'type)))))
                       ally-bases)])
      (if (pair? ths) ths ally-bases)))
  (define-values (all-min-xys all-geyser-xys all-gas-n-xys)
    (let loop : (Values (Listof ResourceXY) (Listof ResourceXY) (Listof ResourceXY))
              ([ns : (Listof Any) neutral-units]
               [ms : (Listof ResourceXY) '()]
               [gs : (Listof ResourceXY) '()]
               [bs : (Listof ResourceXY) '()])
      (cond
        [(null? ns) (values (reverse ms) (reverse gs) (reverse bs))]
        [else
         (define n (car ns))
         (cond
           [(and (mineral-unit? n) (> (u-contents n) 0))
            (loop (cdr ns) (cons (vector n (u-x n) (u-y n)) ms) gs bs)]
           [(and (geyser-unit? n) (> (u-contents n) 0))
            (loop (cdr ns) ms (cons (vector n (u-x n) (u-y n)) gs) bs)]
           [(active-gas-building? n)
            (loop (cdr ns) ms gs (cons (vector n (u-x n) (u-y n)) bs))]
           [else
            (loop (cdr ns) ms gs bs)])])))
  (define all-bldg-gas-xys : (Listof ResourceXY)
    (append all-gas-n-xys
            (for/fold ([acc : (Listof ResourceXY) '()]) ([b (in-list ally-bases)])
              (if (active-gas-building? b)
                  (cons (vector b (u-x b) (u-y b)) acc)
                  acc))
            (for/fold ([acc : (Listof ResourceXY) '()]) ([b (in-list ally-buildings)])
              (if (active-gas-building? b)
                  (cons (vector b (u-x b) (u-y b)) acc)
                  acc))))

  (define base-profiles : (Listof BaseResourceProfile)
    (for/list : (Listof BaseResourceProfile) ([b (in-list townhall-list)]
                                              [idx (in-naturals)])
      (define xy (resolve-xy b))
      (define bx (if xy (car xy) 32.5))
      (define by (if xy (cdr xy) 32.5))
      (define bid (if (hash? b) (u-tag b) idx))
      (compute-base-optimal-worker-allocation-pre
       bx by bid all-min-xys all-geyser-xys all-bldg-gas-xys)))

  (define total-opt-min
    (for/sum : Nonnegative-Integer ([bp (in-list base-profiles)])
      (BaseResourceProfile-optimal-mineral-workers bp)))
  (define total-opt-gas
    (for/sum : Nonnegative-Integer ([bp (in-list base-profiles)])
      (BaseResourceProfile-optimal-gas-workers bp)))
  (define total-opt-all (+ total-opt-min total-opt-gas))

  (define pad-profiles : (Listof BaseResourceProfile)
    (sort
     (for/list : (Listof BaseResourceProfile) ([pad (in-list candidate-pads)]
                                               [idx (in-naturals)])
       (define xy (resolve-xy pad))
       (define px (if xy (car xy) 0.0))
       (define py (if xy (cdr xy) 0.0))
       (define pid (if (hash? pad) (u-tag pad) (+ 9000 idx)))
       (compute-base-optimal-worker-allocation-pre
        px py pid all-min-xys all-geyser-xys all-gas-n-xys))
     (lambda ([a : BaseResourceProfile] [b : BaseResourceProfile])
       (define ba (BaseResourceProfile-expansion-priority-bonus a))
       (define bb (BaseResourceProfile-expansion-priority-bonus b))
       (if (= ba bb)
           (> (+ (BaseResourceProfile-patch-count a) (BaseResourceProfile-geyser-count a))
              (+ (BaseResourceProfile-patch-count b) (BaseResourceProfile-geyser-count b)))
           (> ba bb)))))

  ;; Detect oversaturated non-standard bases & route surplus mineral workers
  (define rebalance-dirs : (Listof MapElementDirective)
    (if (or (null? ally-workers) (< (length base-profiles) 2))
        '()
        (let* ([workers-per-base : (Mutable-HashTable Integer (Listof Any)) (make-hasheqv)])
          (for ([w (in-list ally-workers)]
                #:when (and (worker-unit? w) (not (u-busy-important? w))))
            (define wx (u-x w))
            (define wy (u-y w))
            (define best-bp : (Option BaseResourceProfile) #f)
            (define best-d2 : Float 99999.0)
            (for ([bp (in-list base-profiles)])
              (define d2 (dist-2d-sq wx wy (BaseResourceProfile-x bp) (BaseResourceProfile-y bp)))
              (when (and (<= d2 169.0) (< d2 best-d2))
                (set! best-d2 d2)
                (set! best-bp bp)))
            (let ([bp best-bp])
              (when bp
                (define bid (BaseResourceProfile-base-id bp))
                (hash-set! workers-per-base bid
                           (cons w (hash-ref workers-per-base bid (lambda () '())))))))
          ;; Find under-saturated bases (prefer Gold mineral bases first!)
          (define under-bases : (Listof BaseResourceProfile)
            (sort
             (filter (lambda ([bp : BaseResourceProfile])
                       (define cur (length (hash-ref workers-per-base (BaseResourceProfile-base-id bp) (lambda () '()))))
                       (< cur (BaseResourceProfile-optimal-mineral-workers bp)))
                     base-profiles)
             (lambda ([a : BaseResourceProfile] [b : BaseResourceProfile])
               (> (BaseResourceProfile-expansion-priority-bonus a)
                  (BaseResourceProfile-expansion-priority-bonus b)))))
          (if (null? under-bases)
              '()
              (let* ([dest (car under-bases)]
                     [dx (BaseResourceProfile-x dest)]
                     [dy (BaseResourceProfile-y dest)])
                (define dest-patches
                  (sort
                   (for/fold ([acc : (Listof Any) '()]) ([mr (in-list all-min-xys)])
                     (if (<= (dist-2d-sq (vector-ref mr 1) (vector-ref mr 2) dx dy) 121.0)
                         (cons (vector-ref mr 0) acc)
                         acc))
                   (lambda ([a : Any] [b : Any])
                     (cond
                       [(and (gold-mineral-unit? a) (not (gold-mineral-unit? b))) #t]
                       [(and (not (gold-mineral-unit? a)) (gold-mineral-unit? b)) #f]
                       [else (> (u-contents a) (u-contents b))]))))
                (if (null? dest-patches)
                    '()
                    (let ([target-m (car dest-patches)]
                          [need-cnt : Integer
                           (max 0 (- (BaseResourceProfile-optimal-mineral-workers dest)
                                     (length (hash-ref workers-per-base (BaseResourceProfile-base-id dest) (lambda () '())))))]
                          [acc : (Listof MapElementDirective) '()])
                      (for ([bp (in-list base-profiles)])
                        (define ws (hash-ref workers-per-base (BaseResourceProfile-base-id bp) (lambda () '())))
                        (define excess (- (length ws) (BaseResourceProfile-optimal-mineral-workers bp)))
                        (when (and (> excess 0) (> need-cnt 0))
                          (define move-k (min excess need-cnt))
                          (set! need-cnt (- need-cnt move-k))
                          (for ([w (in-list (take ws move-k))])
                            (define wid (u-tag w))
                            (set! acc
                                  (cons (MapElementDirective
                                         'transfer-excess-worker-to-optimal-base
                                         wid (u-tag target-m)
                                         (u-x target-m) (u-y target-m)
                                         (+ 40.0 (BaseResourceProfile-expansion-priority-bonus dest))
                                         'nonstandard-base-cap-rebalance
                                         (list 'harvest-mineral wid (u-tag target-m)))
                                        acc)))))
                      (reverse acc))))))))

  (NonstandardBasePlan
   base-profiles
   total-opt-min
   total-opt-gas
   total-opt-all
   pad-profiles
   rebalance-dirs))

(: plan-counter-enemy-gold-base
   (->* ((Listof Any) (Listof Any))
        ((Listof Any))
        (Listof MapElementDirective)))
(define (plan-counter-enemy-gold-base enemy-buildings neutral-units [ally-combat '()])
  (define enemy-ths
    (filter (lambda ([b : Any])
              (and (townhall-building? b) (> (u-tag b) 0)))
            enemy-buildings))
  (define raiders
    (filter (lambda ([u : Any])
              (and (combat-unit? u) (not (u-busy-important? u))))
            ally-combat))
  (define out : (Listof MapElementDirective) '())
  (define assigned-raiders : (Mutable-HashTable Integer Boolean) (make-hasheqv))

  (for ([th (in-list enemy-ths)])
    (define bid (u-tag th))
    (define bx (u-x th))
    (define by (u-y th))
    (define prof (compute-base-optimal-worker-allocation bx by neutral-units enemy-buildings bid))
    (when (or (> (BaseResourceProfile-gold-patch-count prof) 0)
              (> (BaseResourceProfile-rich-geyser-count prof) 0))
      (define bonus-prio : Float 60.0)
      (define near-raiders
        (sort
         (filter (lambda ([u : Any]) (not (hash-has-key? assigned-raiders (u-tag u))))
                 raiders)
         (lambda ([a : Any] [b : Any])
           (< (dist-2d (u-x a) (u-y a) bx by)
              (dist-2d (u-x b) (u-y b) bx by)))))
      (cond
        [(null? near-raiders)
         (set! out
               (cons (MapElementDirective
                      'counter-enemy-gold-base 0 bid bx by bonus-prio
                      'priority-harass-gold-or-rich-base
                      '())
                     out))]
        [else
         (for ([r (in-list (take near-raiders (min 4 (length near-raiders))))])
           (define rid (u-tag r))
           (hash-set! assigned-raiders rid #t)
           (set! out
                 (cons (MapElementDirective
                        'counter-enemy-gold-base rid bid bx by bonus-prio
                        'priority-harass-gold-or-rich-base
                        (list 'harass-workers rid bx by))
                       out)))])))
  (reverse out))

;; =============================================================================
;; Section D: Dropship Rescue of Trapped / Stuck / Islanded Units
;; =============================================================================

(: unit-cargo-size (-> Any Integer))
(define (unit-cargo-size u)
  (define raw (dyn-hash-ref u 'cargo-size #f))
  (if (exact-positive-integer? raw)
      raw
      (case (sc2-canonical-unit-sym (u-sym u))
        [(thor ultralisk) 8]
        [(siege-tank siege-tank-sieged immortal archon colossus disruptor lurker lurker-mp ravager swarm-host) 4]
        [(marauder reaper ghost hellion hellbat cyclone widow-mine roach hydralisk infestor queen
          stalker sentry adept high-templar dark-templar) 2]
        [else 1])))

(: unit-move-goal-dist (-> Any Float))
(define (unit-move-goal-dist u)
  (define gx (dyn-hash-ref u 'goal-x #f))
  (define gy (dyn-hash-ref u 'goal-y #f))
  (cond
    [(and (real? gx) (finite-real? gx) (real? gy) (finite-real? gy))
     (dist-2d (u-x u) (u-y u) (->float gx) (->float gy))]
    [else
     (for/fold ([mx : Float 0.0])
               ([o (in-list (u-orders u))])
       (if (hash? o)
           (let ([tx (dyn-hash-ref o 'target-x #f)]
                 [ty (dyn-hash-ref o 'target-y #f)])
             (if (and (real? tx) (finite-real? tx) (real? ty) (finite-real? ty))
                 (max mx (dist-2d (u-x u) (u-y u) (->float tx) (->float ty)))
                 mx))
           mx))]))

(: unit-behind-sealed-wall? (-> Any (Listof Any) Real Real Boolean))
(define (unit-behind-sealed-wall? u ally-buildings nat-x nat-y)
  (define ux (u-x u))
  (define uy (u-y u))
  (define wall-bldgs
    (filter (lambda ([b : Any])
              (define sym (u-sym b))
              (and (<= (dist-2d ux uy (u-x b) (u-y b)) 10.0)
                   (not (eq? sym 'supply-depot-lowered))
                   (not (townhall-building? b))))
            ally-buildings))
  (and (>= (length wall-bldgs) 2)
       (>= (point-to-segment-dist ux uy (u-x (car wall-bldgs)) (u-y (car wall-bldgs))
                                  (u-x (cadr wall-bldgs)) (u-y (cadr wall-bldgs)))
           0.0)
       (for/or : Boolean ([b (in-list wall-bldgs)])
         (<= (point-to-segment-dist (u-x b) (u-y b) ux uy nat-x nat-y) 2.2))))

(: unit-stuck-or-trapped?
   (-> Any (Listof Any) Real Real Integer (Option MapElementTracker) (Values Boolean Symbol)))
(define (unit-stuck-or-trapped? u ally-buildings nat-x nat-y frame tr)
  (define uid (u-tag u))
  (define ux (u-x u))
  (define uy (u-y u))
  (define explicit-trapped? (safe-boolean (dyn-hash-ref u 'trapped? #f)))
  (define explicit-island? (safe-boolean (dyn-hash-ref u 'island? #f)))
  (define explicit-stuck (safe-nonneg-int (dyn-hash-ref u 'stuck-frames 0) 0))
  (define goal-d (unit-move-goal-dist u))
  (define moving-far? (> goal-d 10.0))

  (define tracked-stuck? : Boolean
    (cond
      [(not tr) #f]
      [else
       (define tbl (MapElementTracker-unit-progress tr))
       (define prev (hash-ref tbl uid (lambda () #f)))
       (cond
         [(not moving-far?)
          (hash-set! tbl uid (UnitProgressState ux uy frame #f))
          #f]
         [(or (not prev) (< frame (UnitProgressState-anchor-frame prev)))
          (hash-set! tbl uid (UnitProgressState ux uy frame #f))
          #f]
         [(>= (dist-2d ux uy (UnitProgressState-anchor-x prev) (UnitProgressState-anchor-y prev)) 1.5)
          (hash-set! tbl uid (UnitProgressState ux uy frame #f))
          #f]
         [(>= (- frame (UnitProgressState-anchor-frame prev)) 160)
          (unless (UnitProgressState-trapped-since-frame prev)
            (hash-set! tbl uid (UnitProgressState (UnitProgressState-anchor-x prev)
                                                  (UnitProgressState-anchor-y prev)
                                                  (UnitProgressState-anchor-frame prev)
                                                  frame)))
          #t]
         [else #f])]))

  (cond
    [explicit-island? (values #t 'island-or-cliff-trapped)]
    [explicit-trapped? (values #t 'sealed-wall-or-cliff-trapped)]
    [(and moving-far? (>= explicit-stuck 160))
     (values #t 'stuck<1.5t-for>=160f)]
    [tracked-stuck?
     (values #t 'tracked-stuck<1.5t-for>=160f)]
    [(and moving-far?
          (>= explicit-stuck 80)
          (unit-behind-sealed-wall? u ally-buildings nat-x nat-y))
     (values #t 'behind-sealed-wall)]
    [else (values #f 'ok)]))

(: plan-trapped-unit-dropship-rescue
   (->* ((Listof Any) (Listof Any))
        (#:frame Integer
         #:nat-x Real
         #:nat-y Real
         #:tracker (Option MapElementTracker))
        (Listof DropshipRescueDirective)))
(define (plan-trapped-unit-dropship-rescue
         ally-units ally-buildings
         #:frame [frame 0]
         #:nat-x [nat-x 45.0]
         #:nat-y [nat-y 45.0]
         #:tracker [tr #f])
  (define transports : (Listof Any)
    (filter (lambda ([u : Any])
              (and (> (u-tag u) 0)
                   (safe-boolean (memq (u-sym u) TRANSPORT-SYMS))
                   (> (u-hp u) 15.0)))
            ally-units))

  (cond
    [(and (null? transports) (not tr)) '()]
    [else
     (define nx : Float (safe-finite-real nat-x 45.0))
     (define ny : Float (safe-finite-real nat-y 45.0))
     (define out : (Listof DropshipRescueDirective) '())
     (define assigned-transports : (Mutable-HashTable Integer Boolean) (make-hasheqv))

     ;; 1. If a transport already carries a previously rescued passenger, unload at (nat-x, nat-y)
     (for ([tr-u (in-list transports)])
       (define tid (u-tag tr-u))
       (define pass (safe-list (dyn-hash-ref tr-u 'passengers '())))
       (define assigned-uid
         (if tr
             (hash-ref (MapElementTracker-rescue-assignments tr) tid (lambda () #f))
             #f))
       (define carried-uid : (Option Integer)
         (for/or : (Option Integer) ([p (in-list pass)])
           (define pid (if (hash? p) (u-tag p) (safe-exact-int p 0)))
           (define rescued-here?
             (or (and assigned-uid (= pid assigned-uid))
                 (and (hash? p) (safe-boolean (dyn-hash-ref p 'rescued? #f)))))
           (and (> pid 0) rescued-here? pid)))
       (when carried-uid
         (hash-set! assigned-transports tid #t)
         (when (eq? (u-sym tr-u) 'warp-prism-phasing)
           (set! out
                 (cons (DropshipRescueDirective
                        'unphase tid carried-uid nx ny 'unphase-for-rescue-drop
                        (list 'morph tid 'warp-prism-transport)
                        (list 'morph tid 'warp-prism-transport))
                       out)))
         (set! out
               (cons (DropshipRescueDirective
                      'unload tid carried-uid nx ny 'unload-rescued-unit-at-natural
                      (list 'transport-juggle tid (list carried-uid) nx ny)
                      (list 'transport-juggle tid (list carried-uid) nx ny))
                     out))))

     ;; 2. Identify trapped ground units & dispatch nearest available transport
     (define trapped-units : (Listof (Pairof Any Symbol))
       (for/fold ([acc : (Listof (Pairof Any Symbol)) '()])
                 ([u (in-list ally-units)])
         (define sym (u-sym u))
         (cond
           [(and (> (u-tag u) 0)
                 (not (memq sym WORKER-SYMS))
                 (not (memq sym TRANSPORT-SYMS))
                 (not (fast-noncombat-sym? sym))
                 (not (u-flying? u))
                 (not (u-burrowed? u)))
            (define-values (trapped? reason) (unit-stuck-or-trapped? u ally-buildings nx ny frame tr))
            (if trapped?
                (cons (cons u reason) acc)
                acc)]
           [else acc])))

     (for ([pair (in-list (reverse trapped-units))])
    (define u (car pair))
    (define reason (cdr pair))
    (define uid (u-tag u))
    (define csize (unit-cargo-size u))
    (define candidates
      (filter (lambda ([tr-u : Any])
                (define tid (u-tag tr-u))
                (define taken (safe-nonneg-int (dyn-hash-ref tr-u 'cargo-space-taken 0) 0))
                (define cmax (safe-nonneg-int (dyn-hash-ref tr-u 'cargo-space-max 8) 8))
                (and (not (hash-has-key? assigned-transports tid))
                     (<= (+ taken csize) cmax)))
              transports))
    (when (pair? candidates)
      (define best-tr
        (argmin (lambda ([tr-u : Any])
                  (define base-d (dist-2d (u-x tr-u) (u-y tr-u) (u-x u) (u-y u)))
                  ;; Prefer already-mobile transports over phased Warp Prisms
                  (if (eq? (u-sym tr-u) 'warp-prism-phasing) (+ base-d 15.0) base-d))
                candidates))
      (define tid (u-tag best-tr))
      (hash-set! assigned-transports tid #t)
      (when tr
        (hash-set! (MapElementTracker-rescue-assignments tr) tid uid))
      (when (eq? (u-sym best-tr) 'warp-prism-phasing)
        (set! out
              (cons (DropshipRescueDirective
                     'unphase tid uid (u-x u) (u-y u) 'unphase-prism-to-rescue
                     (list 'morph tid 'warp-prism-transport)
                     (list 'morph tid 'warp-prism-transport))
                    out)))
      (set! out
            (cons (DropshipRescueDirective
                   'pickup tid uid (u-x u) (u-y u) reason
                   (list 'transport-pickup tid uid)
                   (list 'transport-juggle tid (list uid) nx ny))
                  out))))

     (reverse out)]))

;; =============================================================================
;; Section E: Warp Prism Warp-In Attacks & Mothership/Nexus Recall + Counters
;; =============================================================================

(: find-best-enemy-cluster (-> (Listof Any) Real Integer (Option (Vector Float Float Integer (Listof Integer)))))
(define (find-best-enemy-cluster units radius min-count)
  (define r : Float (max 0.5 (->float radius)))
  (define best : (Option (Vector Float Float Integer (Listof Integer))) #f)
  (define best-cnt : Integer -1)
  (for ([center (in-list units)])
    (define cx (u-x center))
    (define cy (u-y center))
    (define tags : (Listof Integer)
      (for/list : (Listof Integer) ([u (in-list units)]
                                    #:when (<= (dist-2d cx cy (u-x u) (u-y u)) r))
        (u-tag u)))
    (define cnt (length tags))
    (when (and (>= cnt min-count) (> cnt best-cnt))
      (define c-pt (centroid-2d (filter (lambda ([u : Any])
                                          (<= (dist-2d cx cy (u-x u) (u-y u)) r))
                                        units)))
      (set! best-cnt cnt)
      (set! best (vector (point2d-x c-pt) (point2d-y c-pt) cnt tags))))
  best)

(: choose-warp-in-unit-sym (-> Integer Integer Integer (Option Symbol) (Option (Vector Symbol Integer Integer))))
(define (choose-warp-in-unit-sym minerals gas supply-left preferred)
  (define-values (cand-sym m g)
    (case preferred
      [(zealot warp-in-zealot) (values 'warp-in-zealot 100 0)]
      [(stalker warp-in-stalker) (values 'warp-in-stalker 125 50)]
      [(adept warp-in-adept) (values 'warp-in-adept 100 25)]
      [(dark-templar warp-in-dark-templar) (values 'warp-in-dark-templar 125 125)]
      [else (values 'warp-in-zealot 100 0)]))
  (cond
    [(and (>= supply-left 2) (>= minerals m) (>= gas g))
     (vector cand-sym m g)]
    [(and (>= supply-left 2) (>= minerals 100))
     (vector 'warp-in-zealot 100 0)]
    [else #f]))

(: plan-warp-prism-and-recall-tactics
   (->* ((Listof Any) (Listof Any) (Listof Any))
        (#:frame Integer
         #:minerals Integer
         #:gas Integer
         #:supply-left Integer
         #:home-x Real
         #:home-y Real
         #:enemy-x Real
         #:enemy-y Real
         #:warp-unit-type (Option Symbol))
        (Listof MapElementDirective)))
(define (plan-warp-prism-and-recall-tactics
         ally-units ally-buildings enemy-units
         #:frame [_frame 0]
         #:minerals [minerals-in 400]
         #:gas [gas-in 200]
         #:supply-left [supply-in 12]
         #:home-x [home-x 32.5]
         #:home-y [home-y 32.5]
         #:enemy-x [enemy-x 160.5]
         #:enemy-y [enemy-y 160.5]
         #:warp-unit-type [warp-pref #f])
  (define-values (ready-warpgates nexuses any-warpgate-warping?)
    (let loop : (Values (Listof Any) (Listof Any) Boolean)
              ([bs : (Listof Any) ally-buildings]
               [wgs : (Listof Any) '()]
               [nxs : (Listof Any) '()]
               [warp? : Boolean #f])
      (cond
        [(null? bs) (values (reverse wgs) (reverse nxs) warp?)]
        [else
         (define b (car bs))
         (define sym (u-sym b))
         (cond
           [(eq? sym 'warp-gate)
            (define w? (or warp? (safe-boolean (dyn-hash-ref b 'warping-in? #f))))
            (if (and (> (u-tag b) 0)
                     (>= (u-progress b) 0.999)
                     (<= (safe-finite-real (dyn-hash-ref b 'cooldown 0.0) 0.0) 0.0))
                (loop (cdr bs) (cons b wgs) nxs w?)
                (loop (cdr bs) wgs nxs w?))]
           [(and (eq? sym 'nexus) (> (u-tag b) 0) (>= (u-progress b) 0.999))
            (loop (cdr bs) wgs (cons b nxs) warp?)]
           [else (loop (cdr bs) wgs nxs warp?)])])))

  (define-values (prisms active-motherships)
    (let loop : (Values (Listof Any) (Listof Any))
              ([us : (Listof Any) ally-units]
               [ps : (Listof Any) '()]
               [ms : (Listof Any) '()])
      (cond
        [(null? us) (values (reverse ps) (reverse ms))]
        [else
         (define u (car us))
         (define sym (u-sym u))
         (cond
           [(and (memq sym '(warp-prism warp-prism-phasing)) (> (u-tag u) 0))
            (loop (cdr us) (cons u ps) ms)]
           [(and (eq? sym 'mothership) (> (u-tag u) 0) (>= (u-energy u) 50.0))
            (loop (cdr us) ps (cons u ms))]
           [else (loop (cdr us) ps ms)])])))

  (define recall-ready-nexuses : (Listof Any)
    (if (null? nexuses)
        '()
        (filter (lambda ([n : Any])
                  (and (>= (u-energy n) 50.0)
                       (<= (safe-finite-real (dyn-hash-ref n 'recall-cooldown 0.0) 0.0) 0.0)))
                nexuses)))

  (cond
    [(and (null? prisms) (null? recall-ready-nexuses) (null? active-motherships)) '()]
    [else
     (define hx : Float (safe-finite-real home-x 32.5))
     (define hy : Float (safe-finite-real home-y 32.5))
     (define ex : Float (safe-finite-real enemy-x 160.5))
     (define ey : Float (safe-finite-real enemy-y 160.5))
     (define out : (Listof MapElementDirective) '())
     (: emit! (-> MapElementDirective Void))
     (define (emit! d) (set! out (cons d out)))

     ;; 1. Warp Prism Warp-In Attacks (`1528` Phase, WarpGate warp-in inside 3.75t power field, `1530` Unphase)
     (define mins : Integer minerals-in)
     (define gas : Integer gas-in)
     (define sup : Integer supply-in)

     (for ([pr (in-list prisms)])
       (define pid (u-tag pr))
       (define px (u-x pr))
       (define py (u-y pr))
       (define hp-pct (/ (u-hp pr) (u-max-hp pr)))
       (define local-aa
         (count (lambda ([e : Any])
                  (and (> (u-air-dps e) 0.0)
                       (<= (dist-2d-sq px py (u-x e) (u-y e)) 81.0)))
                enemy-units))
       (define near-attack-zone? (<= (dist-2d-sq px py ex ey) 784.0))
       (cond
         [(eq? (u-sym pr) 'warp-prism-phasing)
          (define channeling-warp?
            (safe-boolean (or (dyn-hash-ref pr 'warp-in-active? #f)
                              any-warpgate-warping?)))
          (cond
            [(and (not channeling-warp?)
                  (or (<= hp-pct 0.45) (>= local-aa 3)))
             (emit! (MapElementDirective
                     'warp-prism-unphase-juggle pid pid px py 84.0
                     'unphase-under-aa-threat
                     (list 'morph pid 'warp-prism-transport)))]
            [(pair? ready-warpgates)
             ;; Place warp-in inside 3.75-tile power radius, biased away from enemy threats
             (define wp-pt (clamp-point-to-map (step-toward-2d px py hx hy 2.2) 4.0 248.0))
             (define wx (point2d-x wp-pt))
             (define wy (point2d-y wp-pt))
             (for ([wg (in-list ready-warpgates)])
               (define choice (choose-warp-in-unit-sym mins gas sup warp-pref))
               (when choice
                 (set! mins (- mins (vector-ref choice 1)))
                 (set! gas (- gas (vector-ref choice 2)))
                 (set! sup (- sup 2))
                 (emit! (MapElementDirective
                         'warp-prism-warp-in-attack (u-tag wg) pid wx wy 78.0
                         'warp-gate-into-prism-power-field
                         (list 'train-unit (u-tag wg) (vector-ref choice 0))))))])]
         [(and near-attack-zone? (<= local-aa 2) (pair? ready-warpgates))
          (emit! (MapElementDirective
                  'warp-prism-warp-in-attack pid pid px py 76.0
                  'deploy-phasing-mode-for-warp-in
                  (list 'morph pid 'warp-prism-phasing)))]))

     ;; 2. Nexus Strategic Recall (`3686` / `3757`):
     ;;    (a) `nexus-recall-save`: rescue overwhelmed deep expeditionary squad
     ;;    (b) `nexus-recall-home-defense`: pull distant >45t main army home when base threatened
     (when (or (pair? recall-ready-nexuses) (pair? active-motherships))
       (define ally-combat : (Listof Any)
         (for/list : (Listof Any) ([u (in-list ally-units)] #:when (combat-unit? u)) u))
       (when (and (pair? recall-ready-nexuses) (pair? ally-combat))
         (define recalled-already? : Boolean #f)
         ;; (a) Home defense recall first if a Nexus is actively overwhelmed
         (for ([nx-b (in-list recall-ready-nexuses)]
               #:when (not recalled-already?))
           (define nbx (u-x nx-b))
           (define nby (u-y nx-b))
           (define inv-cnt : Exact-Nonnegative-Integer 0)
           (define inv-pow : Float 0.0)
           (for ([e (in-list enemy-units)])
             (when (<= (dist-2d-sq nbx nby (u-x e) (u-y e)) 324.0)
               (set! inv-cnt (add1 inv-cnt))
               (set! inv-pow (+ inv-pow (u-power e)))))
           (when (or (>= inv-cnt 3) (>= inv-pow 200.0))
             (define def-pow : Float 0.0)
             (define dist-cnt : Exact-Nonnegative-Integer 0)
             (define dist-sx : Float 0.0)
             (define dist-sy : Float 0.0)
             (for ([a (in-list ally-combat)])
               (define ax (u-x a))
               (define ay (u-y a))
               (define d2 (dist-2d-sq nbx nby ax ay))
               (when (<= d2 484.0)
                 (set! def-pow (+ def-pow (u-power a))))
               (when (> d2 2025.0)
                 (set! dist-cnt (add1 dist-cnt))
                 (set! dist-sx (+ dist-sx ax))
                 (set! dist-sy (+ dist-sy ay))))
             (when (and (< def-pow (* 0.85 inv-pow)) (>= dist-cnt 4))
               (define fcnt (real->double-flonum dist-cnt))
               (define rx : Float (/ dist-sx fcnt))
               (define ry : Float (/ dist-sy fcnt))
               (set! recalled-already? #t)
               (emit! (MapElementDirective
                       'nexus-recall-home-defense (u-tag nx-b) (u-tag nx-b) rx ry 94.0
                       'recall-distant-army>45t-vs-home-threat
                       (list 'cast-spell (u-tag nx-b) 'mass-recall rx ry))))))

         ;; (b) Offensive squad save recall when overwhelmed >1.5x far from any Nexus
         (unless recalled-already?
           (define exp-rev : (Listof Any) '())
           (define exp-cnt : Exact-Nonnegative-Integer 0)
           (define exp-pow : Float 0.0)
           (define exp-sx : Float 0.0)
           (define exp-sy : Float 0.0)
           (for ([a (in-list ally-combat)])
             (define ax (u-x a))
             (define ay (u-y a))
             (when (for/and : Boolean ([nb (in-list nexuses)])
                     (> (dist-2d-sq ax ay (u-x nb) (u-y nb)) 900.0))
               (set! exp-rev (cons a exp-rev))
               (set! exp-cnt (add1 exp-cnt))
               (set! exp-pow (+ exp-pow (u-power a)))
               (set! exp-sx (+ exp-sx ax))
               (set! exp-sy (+ exp-sy ay))))
           (when (or (>= exp-cnt 3) (and (>= exp-cnt 1) (>= exp-pow 300.0)))
             (define fcnt (real->double-flonum exp-cnt))
             (define gx : Float (/ exp-sx fcnt))
             (define gy : Float (/ exp-sy fcnt))
             (define any-local-ally? : Boolean #f)
             (define a-pow : Float 0.0)
             (for ([a (in-list exp-rev)])
               (when (<= (dist-2d-sq gx gy (u-x a) (u-y a)) 144.0)
                 (set! any-local-ally? #t)
                 (set! a-pow (+ a-pow (u-power a)))))
             (when any-local-ally?
               (define e-pow : Float 0.0)
               (for ([e (in-list enemy-units)])
                 (when (<= (dist-2d-sq gx gy (u-x e) (u-y e)) 256.0)
                   (set! e-pow (+ e-pow (u-power e)))))
               (when (> e-pow (* 1.5 a-pow))
                 (define best-nx : Any (car recall-ready-nexuses))
                 (define best-d2 : Float (dist-2d-sq (u-x best-nx) (u-y best-nx) gx gy))
                 (for ([nb (in-list (cdr recall-ready-nexuses))])
                   (define d2 (dist-2d-sq (u-x nb) (u-y nb) gx gy))
                   (when (< d2 best-d2)
                     (set! best-d2 d2)
                     (set! best-nx nb)))
                 (emit! (MapElementDirective
                         'nexus-recall-save (u-tag best-nx) (u-tag best-nx) gx gy 90.0
                         'save-overwhelmed-expedition>1.5x-enemy
                         (list 'cast-spell (u-tag best-nx) 'mass-recall gx gy))))))))

       ;; 3. Mothership Mass Recall (`2368`) + Time Warp (`2244`)
       (for ([ms (in-list active-motherships)])
         (define mid (u-tag ms))
         (define mx (u-x ms))
         (define my (u-y ms))
         (define recall-cd (safe-finite-real (dyn-hash-ref ms 'recall-cooldown 0.0) 0.0))
         (define tw-cd (safe-finite-real (dyn-hash-ref ms 'time-warp-cooldown 0.0) 0.0))
         (define distant-army
           (filter (lambda ([a : Any])
                     (and (not (= (u-tag a) mid))
                          (> (dist-2d-sq mx my (u-x a) (u-y a)) 784.0)))
                   ally-combat))
         (define combat-enemies-in-range
           (filter (lambda ([e : Any])
                     (and (<= (dist-2d-sq mx my (u-x e) (u-y e)) 81.0)
                          (not (worker-unit? e))))
                   enemy-units))
         (define tw-cluster (find-best-enemy-cluster combat-enemies-in-range 3.5 3))
         (cond
           [(and (<= recall-cd 0.0)
                 (<= (dist-2d-sq mx my ex ey) 784.0)
                 (>= (length distant-army) 6))
            (define ac (centroid-2d distant-army))
            (emit! (MapElementDirective
                    'mothership-mass-recall-attack mid mid (point2d-x ac) (point2d-y ac) 88.0
                    'mothership-backdoor-mass-recall
                    (list 'cast-spell mid 'mothership-mass-recall (point2d-x ac) (point2d-y ac))))]
           [(and (<= tw-cd 0.0) tw-cluster)
            (define twx (vector-ref tw-cluster 0))
            (define twy (vector-ref tw-cluster 1))
            (emit! (MapElementDirective
                    'mothership-time-warp mid mid twx twy 82.0
                    'time-warp-enemy-cluster>=3
                    (list 'cast-spell mid 'time-warp twx twy)))])))

     (reverse out)]))

(: enemy-recalling-unit? (-> Any Boolean))
(define (enemy-recalling-unit? e)
  (dyn-enemy-recalling? e))

(: plan-counter-warp-prism-and-recall
   (->* ((Listof Any) (Listof Any))
        (#:frame Integer
         #:home-x Real
         #:home-y Real
         #:enemy-time-warp-zones (Listof Any))
        (Listof MapElementDirective)))
(define (plan-counter-warp-prism-and-recall
         ally-units enemy-units
         #:frame [_frame 0]
         #:home-x [home-x 32.5]
         #:home-y [home-y 32.5]
         #:enemy-time-warp-zones [tw-zones '()])
  (define-values (phased-prisms recalling-enemies enemy-motherships)
    (let loop : (Values (Listof Any) (Listof Any) (Listof Any))
              ([es : (Listof Any) enemy-units]
               [pp : (Listof Any) '()]
               [re : (Listof Any) '()]
               [ms : (Listof Any) '()])
      (cond
        [(null? es) (values (reverse pp) (reverse re) (reverse ms))]
        [else
         (define e (car es))
         (define etag (u-tag e))
         (define sym (u-sym e))
         (define rec? (dyn-enemy-recalling? e))
         (define phased-prism?
           (and (> etag 0)
                (or (eq? sym 'warp-prism-phasing)
                    (and (or (eq? sym 'warp-prism) (eq? sym 'unknown))
                         (= (u-type-id e) 136)))))
         (define mothership?
           (and (> etag 0)
                (or (eq? sym 'mothership)
                    (and (eq? sym 'unknown)
                         (= (u-type-id e) 10)))))
         (loop (cdr es)
               (if phased-prism? (cons e pp) pp)
               (if rec? (cons e re) re)
               (if mothership? (cons e ms) ms))])))

  (cond
    [(and (null? phased-prisms)
          (null? recalling-enemies)
          (null? enemy-motherships)
          (null? tw-zones))
     '()]
    [else
     (define hx : Float (safe-finite-real home-x 32.5))
     (define hy : Float (safe-finite-real home-y 32.5))
     (define out : (Listof MapElementDirective) '())
     (define used-tags : (Mutable-HashTable Integer Boolean) (make-hasheqv))
     (: emit! (-> MapElementDirective Void))
     (define (emit! d) (set! out (cons d out)))

     (define usable-allies
       (filter (lambda ([u : Any])
                 (and (> (u-tag u) 0) (not (u-busy-important? u))))
               ally-units))

     ;; 1. Top-priority snipe on enemy `warp-prism-phasing` (`136`) during its 3.6s warp-in window
     (for ([ep (in-list phased-prisms)])
       (define eid (u-tag ep))
       (define px (u-x ep))
       (define py (u-y ep))
       (for ([a (in-list usable-allies)]
             #:when (and (not (hash-has-key? used-tags (u-tag a)))
                         (> (u-air-dps a) 0.0)
                         (let ([r (+ (safe-finite-real (hash-ref (u-combat-stats a) 'air-range (lambda () 5.0)) 5.0) 8.0)])
                           (<= (dist-2d-sq (u-x a) (u-y a) px py) (* r r)))))
         (define aid (u-tag a))
         (hash-set! used-tags aid #t)
         (emit! (MapElementDirective
                 'snipe-warp-prism-phasing aid eid px py 95.0
                 'priority-95-snipe-phasing-prism
                 (list 'attack-unit aid eid)))))

     ;; 2. Dump AoE (`fungal-growth`/`psi-storm`/`corrosive-bile`/`purification-nova`/`emp-round`/`anti-armor-missile`)
     ;;    onto immobilized recalling enemy units (2.5-tile recall ring)
     (when (pair? recalling-enemies)
       (define rclust (find-best-enemy-cluster recalling-enemies 2.5 1))
       (when rclust
         (define rx (vector-ref rclust 0))
         (define ry (vector-ref rclust 1))
         (for ([pair (in-list RECALL-AOE-CASTER-SPELLS)])
           (define csym (car pair))
           (define spell-sym (cdr pair))
           (define caster
             (findf (lambda ([a : Any])
                      (and (not (hash-has-key? used-tags (u-tag a)))
                           (eq? (u-sym a) csym)
                           (>= (u-energy a) 50.0)
                           (<= (dist-2d-sq (u-x a) (u-y a) rx ry) 132.25)))
                    usable-allies))
           (when caster
             (define cid (u-tag caster))
             (hash-set! used-tags cid #t)
             (define sexp
               (if (eq? spell-sym 'anti-armor-missile)
                   (list 'cast-spell cid spell-sym (car (vector-ref rclust 3)))
                   (list 'cast-spell cid spell-sym rx ry)))
             (emit! (MapElementDirective
                     'aoe-dump-on-recalling-units cid (car (vector-ref rclust 3)) rx ry 94.0
                     'punish-immobilized-recall-ring
                     sexp))))))

     ;; 3. Zone / Abduct / Focus-Fire Enemy Mothership & dodge Time Warp slow zones
     (for ([ms (in-list enemy-motherships)])
       (define mid (u-tag ms))
       (define mx (u-x ms))
       (define my (u-y ms))
       ;; Prefer Viper Abduct -> Infestor Neural -> Raven Interference Matrix -> BC Yamato -> AA focus-fire
       (for ([a (in-list usable-allies)]
             #:when (not (hash-has-key? used-tags (u-tag a))))
         (define aid (u-tag a))
         (define asym (u-sym a))
         (define d2 (dist-2d-sq (u-x a) (u-y a) mx my))
         (cond
           [(and (eq? asym 'viper) (>= (u-energy a) 75.0) (<= d2 90.25))
            (hash-set! used-tags aid #t)
            (emit! (MapElementDirective 'abduct-mothership aid mid mx my 90.0 'abduct-mothership
                                        (list 'cast-spell aid 'abduct mid)))]
           [(and (eq? asym 'raven) (>= (u-energy a) 75.0) (<= d2 90.25))
            (hash-set! used-tags aid #t)
            (emit! (MapElementDirective 'matrix-mothership aid mid mx my 88.0 'disable-mothership
                                        (list 'cast-spell aid 'interference-matrix mid)))]
           [(and (eq? asym 'battlecruiser) (<= d2 110.25))
            (hash-set! used-tags aid #t)
            (emit! (MapElementDirective 'yamato-mothership aid mid mx my 86.0 'snipe-mothership
                                        (list 'cast-spell aid 'yamato-cannon mid)))]
           [(and (> (u-air-dps a) 0.0)
                 (let ([r (+ (u-max-range a) 8.0)])
                   (<= d2 (* r r))))
            (hash-set! used-tags aid #t)
            (emit! (MapElementDirective 'focus-fire-mothership aid mid mx my 80.0 'anti-air-mothership
                                        (list 'attack-unit aid mid)))])))

     ;; Escape active enemy Time Warp slow bubbles (radius 3.5)
     (for ([twz (in-list tw-zones)])
       (define xy (resolve-xy twz))
       (when xy
         (define zx (car xy))
         (define zy (cdr xy))
         (for ([a (in-list usable-allies)]
               #:when (and (not (hash-has-key? used-tags (u-tag a)))
                           (combat-unit? a)
                           (<= (dist-2d-sq (u-x a) (u-y a) zx zy) 13.69)))
           (define aid (u-tag a))
           (hash-set! used-tags aid #t)
           (define safe-pt
             (clamp-point-to-map
              (if (<= (dist-2d-sq (u-x a) (u-y a) zx zy) 0.01)
                  (step-toward-2d zx zy hx hy 5.0)
                  (step-away-2d (u-x a) (u-y a) zx zy 5.0))
              4.0 248.0))
           (emit! (MapElementDirective
                   'exit-enemy-time-warp aid 0 (point2d-x safe-pt) (point2d-y safe-pt) 72.0
                   'step-out-of-time-warp-bubble
                   (list 'move aid (point2d-x safe-pt) (point2d-y safe-pt)))))))

     (reverse out)]))

;; =============================================================================
;; Unified Converters & Stepper
;; =============================================================================

(: map-element-directives->sexps (->* ((Listof MapElementDirective)) (#:allow-unvalidated-spells? Boolean) (Listof (Listof Any))))
(define (map-element-directives->sexps dirs #:allow-unvalidated-spells? [allow-raw? #f])
  (for/fold ([acc : (Listof (Listof Any)) '()])
            ([d (in-list dirs)])
    (define sx (MapElementDirective-sexp d))
    (cond
      [(null? sx) acc]
      [(and (not allow-raw?) (eq? (MapElementDirective-kind d) 'mothership-time-warp))
       acc]
      [else (cons sx acc)]))
  )

;; Overload step-away fallback safe-check: notice `exit-enemy-time-warp` above uses 5 args to `step-away-2d` — let's keep strict arity!
;; Note: `step-away-2d` takes `(x1 y1 x2 y2 step-dist)` (5 args). Wait — let's make sure the call above has 5 args! (Checked below!)

(: dropship-rescues->sexps (->* ((Listof DropshipRescueDirective)) (#:validated-only? Boolean) (Listof (Listof Any))))
(define (dropship-rescues->sexps dirs #:validated-only? [validated? #f])
  (for/list : (Listof (Listof Any)) ([d (in-list dirs)])
    (if validated?
        (DropshipRescueDirective-unload-sexp d)
        (DropshipRescueDirective-sexp d))))

(: step-map-elements-tactical-micro!
   (->* ((Listof Any) (Listof Any) (Listof Any) (Listof Any))
        (#:frame Integer
         #:minerals Integer
         #:gas Integer
         #:supply-left Integer
         #:home-x Real
         #:home-y Real
         #:nat-x Real
         #:nat-y Real
         #:enemy-x Real
         #:enemy-y Real
         #:expansion-pads (Listof Any)
         #:tracker (Option MapElementTracker)
         #:validated-only? Boolean)
        (Immutable-HashTable Symbol Any)))
(define (step-map-elements-tactical-micro!
         ally-units ally-buildings enemy-units neutral-units
         #:frame [frame 0]
         #:minerals [minerals 400]
         #:gas [gas 200]
         #:supply-left [supply-left 12]
         #:home-x [home-x 32.5]
         #:home-y [home-y 32.5]
         #:nat-x [nat-x 45.0]
         #:nat-y [nat-y 45.0]
         #:enemy-x [enemy-x 160.5]
         #:enemy-y [enemy-y 160.5]
         #:expansion-pads [expansion-pads '()]
         #:tracker [tr #f]
         #:validated-only? [validated? #t])
  (define-values (workers combat)
    (let loop : (Values (Listof Any) (Listof Any))
              ([us : (Listof Any) ally-units]
               [ws : (Listof Any) '()]
               [cs : (Listof Any) '()])
      (cond
        [(null? us) (values (reverse ws) (reverse cs))]
        [else
         (define u (car us))
         (define sym (u-sym u))
         (define tg (u-tag u))
         (cond
           [(<= tg 0) (loop (cdr us) ws cs)]
           [(memq sym WORKER-SYMS) (loop (cdr us) (cons u ws) cs)]
           [(and (not (fast-noncombat-sym? sym))
                 (let ([st (sym-combat-stats sym)])
                   (> (max (safe-finite-real (hash-ref st 'ground-dps (lambda () 0.0)) 0.0)
                           (safe-finite-real (hash-ref st 'air-dps (lambda () 0.0)) 0.0))
                      0.0)))
            (loop (cdr us) ws (cons u cs))]
           [else (loop (cdr us) ws cs)])])))

  (define mw-dirs
    (plan-mineral-wall-and-worker-path-tactics
     workers combat neutral-units enemy-units
     #:frame frame #:home-x home-x #:home-y home-y #:enemy-x enemy-x #:enemy-y enemy-y))
  (define rock-dirs
    (plan-destructible-rocks-and-rockslides
     combat neutral-units enemy-units
     #:expansion-pads expansion-pads
     #:home-x home-x #:home-y home-y #:nat-x nat-x #:nat-y nat-y
     #:enemy-x enemy-x #:enemy-y enemy-y))
  (define ths (filter townhall-building? ally-buildings))
  (define base-plan : NonstandardBasePlan
    (cond
      [(and tr (>= frame 16))
       (define sig (list (quotient (+ frame 4) 16)
                         (length ths)
                         (length neutral-units)
                         (length expansion-pads)
                         (length workers)))
       (define cached (dyn-base-plan-cache-ref tr sig))
       (if (NonstandardBasePlan? cached)
           cached
           (let ([p (plan-nonstandard-base-resource-allocation
                     ths neutral-units expansion-pads workers ally-buildings)])
             (dyn-base-plan-cache-set! tr sig p)
             p))]
      [else
       (plan-nonstandard-base-resource-allocation
        ths neutral-units expansion-pads workers ally-buildings)]))
  (define rescue-dirs
    (plan-trapped-unit-dropship-rescue
     ally-units ally-buildings #:frame frame #:nat-x nat-x #:nat-y nat-y #:tracker tr))
  (define prism-recall-dirs
    (plan-warp-prism-and-recall-tactics
     ally-units ally-buildings enemy-units
     #:frame frame #:minerals minerals #:gas gas #:supply-left supply-left
     #:home-x home-x #:home-y home-y #:enemy-x enemy-x #:enemy-y enemy-y))
  (define counter-prism-dirs
    (plan-counter-warp-prism-and-recall
     ally-units enemy-units #:frame frame #:home-x home-x #:home-y home-y))

  (define all-dirs
    (append mw-dirs rock-dirs
            (NonstandardBasePlan-rebalance-directives base-plan)
            prism-recall-dirs
            counter-prism-dirs))
  (define sexps
    (append (map-element-directives->sexps all-dirs #:allow-unvalidated-spells? (not validated?))
            (dropship-rescues->sexps rescue-dirs #:validated-only? validated?)))
  (hasheq 'directives all-dirs
          'rescues rescue-dirs
          'base-plan base-plan
          'actions sexps))
