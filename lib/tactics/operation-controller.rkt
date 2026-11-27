#lang racket/base

;; =============================================================================
;; `lib/tactics/operation-controller.rkt`
;; Layer 4 Unified Tactical Operation Controller
;;
;; Single general per-step operational decision-maker replacing scattered ad-hoc
;; runtime hold/suppress booleans. Consumes all 7 calibrated OWM dimensions via
;; `owm-control-signals` plus local cohesive combat cluster value (`<= 18t`),
;; terrain elevation (`delta-z`) and choke geometry, upgrade advantage, and
;; active timing-spike ETA (`<= 25s`), producing one canonical `tactical-op-plan`:
;;
;;   op-mode: 'defend-home | 'regroup-stage | 'pre-arc-hold
;;            | 'commit-push | 'flank-rotate | 'retreat-regroup
;;
;; Also decouples bounded (`<= 15%`) mobile delay harass (`delay-harass-allowed?`)
;; from main-army `'regroup-stage` / `'pre-arc-hold` holds while preserving
;; `active-home-defense-engaged?` so live home defense fights are never split.
;; =============================================================================

(require racket/flonum
         racket/list
         racket/math
         racket/set
         (only-in "../sc2-game-constants.rkt"
                  SC2-MAX-SUPPLY
                  sc2-canonical-unit-sym
                  sc2-canonical-structure-sym
                  sc2-supply-cost
                  sc2-min-cost
                  sc2-gas-cost)
         (only-in "../opponent-world-model.rkt"
                  opponent-world-summary?
                  opponent-world-model?
                  free-summon-unit-sym?
                  owm-control-signals
                  owm-control-signals?
                  owm-build-control-signals
                  owm-control-signals-confirmed-bases
                  owm-control-signals-estimated-bases
                  owm-control-signals-happy-expected-bases
                  owm-control-signals-stopped-expanding?
                  owm-control-signals-unscouted-expansion-ambiguity?
                  owm-control-signals-confirmed-early-greed?
                  owm-control-signals-urgent-scout-pad
                  owm-control-signals-confirmed-geysers
                  owm-control-signals-estimated-geysers
                  owm-control-signals-est-min-rate
                  owm-control-signals-est-gas-rate
                  owm-control-signals-cum-minerals-mined
                  owm-control-signals-cum-gas-mined
                  owm-control-signals-estimated-workers
                  owm-control-signals-workers-killed
                  owm-control-signals-production-facility-count
                  owm-control-signals-home-prod-count
                  owm-control-signals-imminent-reachable-supply
                  owm-control-signals-unaccounted-minerals
                  owm-control-signals-unaccounted-gas
                  owm-control-signals-hidden-gas-tech-risk?
                  owm-control-signals-enemy-1base-double-gas?
                  owm-control-signals-early-pool-latched?
                  owm-control-signals-inferred-proxy-rush-floor
                  owm-control-signals-requires-anti-air?
                  owm-control-signals-requires-detection?
                  owm-control-signals-known-army-supply
                  owm-control-signals-known-army-value
                  owm-control-signals-believed-army-supply
                  owm-control-signals-believed-army-value
                  owm-control-signals-enemy-siege-or-turtle-count
                  owm-control-signals-locust-wave-active?
                  owm-control-signals-swarm-host-cooldown-window?
                  owm-control-signals-active-summon-count
                  owm-control-signals-destroyed-min
                  owm-control-signals-destroyed-gas
                  owm-control-signals-enemy-upgrade-advantage
                  owm-control-signals-enemy-posture)
         (only-in "../sc2-combat-eval.rkt"
                  predict-engagement-outcome))

(provide
 (struct-out tactical-op-plan)
 (struct-out tactical-op-state)
 make-tactical-op-state
 reset-tactical-op-state!
 compute-local-combat-clusters
 compute-clash-elevation-and-choke
 evaluate-tactical-operation)

;; =============================================================================
;; Constants (Pure SC2 Geometry & Physics)
;; =============================================================================

(define OP-CLUSTER-RADIUS 18.0)
(define OP-LOCAL-CLASH-RADIUS 22.0)
(define OP-HOME-THREAT-RADIUS 26.0)
(define OP-OWN-TERRITORY-CLASH-RADIUS 38.0)
(define OP-HOME-APPROACH-RADIUS 40.0)
(define OP-HOME-ENGAGED-RADIUS 12.0)
(define OP-SPIKE-WINDOW-SEC 25.0)
(define OP-POWER-SPIKE-DWELL-FRAMES 448) ;; 20.0s upgrade power-spike window
(define OP-HYSTERESIS-DWELL-FRAMES 67)   ;; ~3.0s anti-flicker dwell

(define TOWNHALL-SYMS
  '(hatchery lair hive nexus command-center orbital-command planetary-fortress))

(define WORKER-OR-NONCOMBAT-SYMS
  '(scv probe drone mule larva egg overlord overlord-cocoon
    observer observer-siege-mode overseer overseer-siege-mode
    changeling creep-tumor creep-tumor-burrowed))

;; Base-bound macro/defense combat units (e.g. inject/creep Queens near owned THs)
;; are excluded from offensive cross-map cohesion clustering when not defending home.
(define BASE-BOUND-MACRO-COMBAT-SYMS
  '(queen))

(define SIEGE-BREAKER-SYMS
  '(colossus disruptor tempest immortal
    siege-tank siege-tank-sieged liberator liberator-ag battlecruiser
    ravager lurker lurker-burrowed lurker-mp-burrowed brood-lord broodlord viper
    swarm-host swarm-host-mp))

(define ENEMY-SIEGE-WALL-SYMS
  '(siege-tank siege-tank-sieged tempest lurker lurker-burrowed lurker-mp-burrowed
    brood-lord broodlord liberator-ag))

(define SLOW-FOG-COMMIT-SYMS
  '(siege-tank siege-tank-sieged thor thor-ap immortal colossus disruptor
    roach lurker lurker-burrowed lurker-mp-burrowed brood-lord broodlord ultralisk))

;; Weak side-table on `tactical-op-state` tracking newly completed ally upgrades
;; (zero struct ABI change) so upgrade power-spike timing windows fire automatically.
(define op-state-upgrade-table (make-weak-hasheq))

;; =============================================================================
;; Structs
;; =============================================================================

(struct tactical-op-plan
  (op-mode                      ;; 'defend-home | 'regroup-stage | 'pre-arc-hold
                                ;; | 'commit-push | 'flank-rotate | 'retreat-regroup
   delay-harass-allowed?        ;; boolean: decoupled <= 15% mobile delay harass
   suppress-main-attack?        ;; boolean: main army holds/stages/retreats
   should-engage-local?         ;; boolean: engage immediate local threats
   regroup-pt                   ;; (cons x y) or #f
   pre-arc-anchor-pt            ;; (cons x y) or #f
   pre-arc-facing-pt            ;; (cons x y) or #f
   redirect-target-pt           ;; (cons x y) or #f
   scout-ambiguous-pad          ;; (cons x y) or #f
   reserve-home-detector?       ;; boolean
   spike-eta-sec                ;; flonum
   local-cohesion-ratio         ;; flonum in [0.0 .. 1.0]
   local-cluster-val            ;; flonum
   eff-enemy-threat-val         ;; flonum
   eff-power-ratio              ;; flonum
   uphill-brake-active?         ;; boolean
   active-home-defense-engaged? ;; boolean
   rationale)                   ;; symbol
  #:transparent)

(struct tactical-op-state
  (last-frame
   last-mode
   mode-entered-frame)
  #:mutable
  #:transparent)

(define (make-tactical-op-state)
  (tactical-op-state -1 'commit-push 0))

(define (reset-tactical-op-state! st)
  (when (tactical-op-state? st)
    (set-tactical-op-state-last-frame! st -1)
    (set-tactical-op-state-last-mode! st 'commit-push)
    (set-tactical-op-state-mode-entered-frame! st 0)
    (hash-remove! op-state-upgrade-table st)))

;; =============================================================================
;; Pure Record & Geometry Helpers
;; =============================================================================

(define (fl->safe v fallback)
  (if (and (real? v) (not (nan? v)) (not (infinite? v)))
      (exact->inexact v)
      (exact->inexact fallback)))

(define (dist2d-fl x1 y1 x2 y2)
  (define dx (fl- x1 x2))
  (define dy (fl- y1 y2))
  (flsqrt (fl+ (fl* dx dx) (fl* dy dy))))

(define (rec-xy? u)
  (and (hash? u)
       (real? (hash-ref u 'x #f))
       (real? (hash-ref u 'y #f))))

(define (rec-x u [fb 0.0]) (fl->safe (and (hash? u) (hash-ref u 'x fb)) fb))
(define (rec-y u [fb 0.0]) (fl->safe (and (hash? u) (hash-ref u 'y fb)) fb))

(define (rec-z u)
  (and (hash? u)
       (let ([v (hash-ref u 'z (hash-ref u 'pos-z #f))])
         (and (real? v) (not (nan? v)) (exact->inexact v)))))

(define (rec-snapshot? u)
  (and (hash? u)
       (or (eq? (hash-ref u 'snapshot? #f) #t)
           (eqv? (hash-ref u 'display-type 1) 2))))

(define (rec-raw-sym u)
  (if (hash? u)
      (let ([t (hash-ref u 'type (hash-ref u 'unit-type (hash-ref u 'unit_type 'unknown)))])
        (cond [(symbol? t) t]
              [(string? t) (string->symbol (string-downcase t))]
              [else 'unknown]))
      'unknown))

(define (rec-canon-sym u)
  (sc2-canonical-unit-sym (rec-raw-sym u)))

(define (rec-combat-unit? u)
  (and (hash? u)
       (rec-xy? u)
       (not (rec-snapshot? u))
       (let ([sym (rec-canon-sym u)])
         (and (not (eq? sym 'unknown))
              (not (memq sym WORKER-OR-NONCOMBAT-SYMS))
              (not (free-summon-unit-sym? (rec-raw-sym u)))
              (not (free-summon-unit-sym? sym))))))

(define (unit-res-val u)
  (define sym (rec-canon-sym u))
  (define m (exact->inexact (max 0 (sc2-min-cost sym 50))))
  (define g (exact->inexact (max 0 (sc2-gas-cost sym 0))))
  (flmax 50.0 (fl+ m (fl* 1.5 g))))

(define (unit-sup-val u)
  (flmax 0.5 (exact->inexact (sc2-supply-cost (rec-canon-sym u) 1))))

(define (extract-owned-th-pts bldgs fallback-x fallback-y)
  (for/list ([b (in-list (if (list? bldgs) bldgs '()))]
             #:when (and (rec-xy? b)
                         (memq (sc2-canonical-structure-sym (rec-raw-sym b)) TOWNHALL-SYMS)))
    (cons (rec-x b fallback-x) (rec-y b fallback-y))))

;; =============================================================================
;; 1. Local Cohesive Combat Clustering (`<= 18t`)
;; =============================================================================
;; Finds the primary cohesive fighting cluster among `combat-units` (optionally
;; biased toward `focus-pt` when a clash anchor is known).
;; Returns `(values cluster-units cx cy cluster-val total-val cohesion-ratio)`.

(define (compute-local-combat-clusters combat-units
                                       #:radius [radius OP-CLUSTER-RADIUS]
                                       #:focus-pt [focus-pt #f])
  (define rad (flmax 4.0 (fl->safe radius OP-CLUSTER-RADIUS)))
  (define units
    (for/list ([u (in-list (if (list? combat-units) combat-units '()))]
               #:when (rec-combat-unit? u))
      (vector u (rec-x u 0.0) (rec-y u 0.0) (unit-res-val u))))
  (cond
    [(null? units)
     (values '() 0.0 0.0 0.0 0.0 1.0)]
    [else
     (define total-val
       (for/fold ([tv 0.0]) ([uv (in-list units)])
         (fl+ tv (vector-ref uv 3))))
     ;; Greedy seed clustering at `rad`
     (define raw-clusters
       (for/fold ([cls '()]) ([uv (in-list units)])
         (define ux (vector-ref uv 1))
         (define uy (vector-ref uv 2))
         (define uval (vector-ref uv 3))
         (let loop ([rem cls] [acc '()] [merged? #f])
           (cond
             [(null? rem)
              (if merged?
                  (reverse acc)
                  (reverse (cons (vector (fl* ux uval) (fl* uy uval) uval (list uv)) acc)))]
             [(not merged?)
              (define cl (car rem))
              (define cw (flmax 1.0 (vector-ref cl 2)))
              (define cx (fl/ (vector-ref cl 0) cw))
              (define cy (fl/ (vector-ref cl 1) cw))
              (if (fl<= (dist2d-fl ux uy cx cy) rad)
                  (loop (cdr rem)
                        (cons (vector (fl+ (vector-ref cl 0) (fl* ux uval))
                                      (fl+ (vector-ref cl 1) (fl* uy uval))
                                      (fl+ cw uval)
                                      (cons uv (vector-ref cl 3)))
                              acc)
                        #t)
                  (loop (cdr rem) (cons cl acc) #f))]
             [else
              (loop (cdr rem) (cons (car rem) acc) #t)]))))
     ;; Score clusters by total resource value (slight tie-break toward focus-pt if supplied)
     (define best-cl
       (for/fold ([best #f] [best-sc -1.0] #:result best) ([cl (in-list raw-clusters)])
         (define cw (vector-ref cl 2))
         (define cx (fl/ (vector-ref cl 0) (flmax 1.0 cw)))
         (define cy (fl/ (vector-ref cl 1) (flmax 1.0 cw)))
         (define focus-bonus
           (if (and (pair? focus-pt) (real? (car focus-pt)) (real? (cdr focus-pt)))
               (fl/ 1.0 (fl+ 1.0 (fl/ (dist2d-fl cx cy (fl->safe (car focus-pt) cx)
                                                 (fl->safe (cdr focus-pt) cy))
                                      60.0)))
               1.0))
         (define sc (fl* cw (fl+ 0.75 (fl* 0.25 focus-bonus))))
         (if (fl> sc best-sc) (values cl sc) (values best best-sc))))
     (define best-w (flmax 1.0 (vector-ref best-cl 2)))
     (define best-cx (fl/ (vector-ref best-cl 0) best-w))
     (define best-cy (fl/ (vector-ref best-cl 1) best-w))
     ;; Final exact membership pass within `rad` of the winning centroid
     (define-values (members m-val)
       (for/fold ([ms '()] [mv 0.0]) ([uv (in-list units)])
         (if (fl<= (dist2d-fl (vector-ref uv 1) (vector-ref uv 2) best-cx best-cy) rad)
             (values (cons (vector-ref uv 0) ms) (fl+ mv (vector-ref uv 3)))
             (values ms mv))))
     (define coh (if (fl> total-val 0.0) (flmin 1.0 (fl/ m-val total-val)) 1.0))
     (values members best-cx best-cy m-val total-val coh)]))

;; =============================================================================
;; 2. Clash Elevation Delta (`ally_z - enemy_z`) & Choke Width Estimation
;; =============================================================================
;; Returns `(values elev-delta choke-width)` where:
;;   - `elev-delta` is `avg(ally_z) - avg(enemy_z)` (`<= -1.5` = uphill disadvantage)
;;   - `choke-width` is estimated walkable tile span perpendicular to midpoint (`#f` if
;;     no `#:pathable-fn` predicate is provided).

(define (compute-clash-elevation-and-choke ally-cluster enemy-cluster
                                           #:pathable-fn [pathable-fn #f])
  (define-values (az-cnt az-sum ax-sum ay-sum)
    (for/fold ([c 0] [zs 0.0] [xs 0.0] [ys 0.0]) ([u (in-list (or ally-cluster '()))])
      (define uz (rec-z u))
      (if uz
          (values (add1 c) (fl+ zs uz) (fl+ xs (rec-x u 0.0)) (fl+ ys (rec-y u 0.0)))
          (values c zs xs ys))))
  (define-values (ez-cnt ez-sum ex-sum ey-sum)
    (for/fold ([c 0] [zs 0.0] [xs 0.0] [ys 0.0]) ([e (in-list (or enemy-cluster '()))])
      (define ez (rec-z e))
      (if ez
          (values (add1 c) (fl+ zs ez) (fl+ xs (rec-x e 0.0)) (fl+ ys (rec-y e 0.0)))
          (values c zs xs ys))))
  (define elev-delta
    (if (and (> az-cnt 0) (> ez-cnt 0))
        (fl- (fl/ az-sum (exact->inexact az-cnt))
             (fl/ ez-sum (exact->inexact ez-cnt)))
        0.0))
  (define choke-w
    (if (and (procedure? pathable-fn)
             (pair? ally-cluster)
             (pair? enemy-cluster))
        (let* ([acx (if (> az-cnt 0)
                        (fl/ ax-sum (exact->inexact az-cnt))
                        (rec-x (car ally-cluster) 0.0))]
               [acy (if (> az-cnt 0)
                        (fl/ ay-sum (exact->inexact az-cnt))
                        (rec-y (car ally-cluster) 0.0))]
               [ecx (if (> ez-cnt 0)
                        (fl/ ex-sum (exact->inexact ez-cnt))
                        (rec-x (car enemy-cluster) 0.0))]
               [ecy (if (> ez-cnt 0)
                        (fl/ ey-sum (exact->inexact ez-cnt))
                        (rec-y (car enemy-cluster) 0.0))]
               [mx (fl* 0.5 (fl+ acx ecx))]
               [my (fl* 0.5 (fl+ acy ecy))]
               [dx (fl- ecx acx)]
               [dy (fl- ecy acy)]
               [dn (flmax 0.1 (flsqrt (fl+ (fl* dx dx) (fl* dy dy))))]
               [pux (fl- (fl/ dy dn))]
               [puy (fl/ dx dn)])
          (define (scan-side sign)
            (let loop ([step 1] [open 0.0])
              (if (> step 8)
                  open
                  (let ([sx (fl+ mx (fl* (fl* sign (exact->inexact step)) pux))]
                        [sy (fl+ my (fl* (fl* sign (exact->inexact step)) puy))])
                    (if (pathable-fn sx sy)
                        (loop (add1 step) (fl+ open 1.0))
                        open)))))
          (fl+ 1.0 (fl+ (scan-side 1.0) (scan-side -1.0))))
        #f))
  (values elev-delta choke-w))

;; =============================================================================
;; 3. Unified Per-Step Tactical Operation Evaluator
;; =============================================================================

(define (normalize-owm-signals raw upg-adv-override)
  (define sig
    (cond
      [(owm-control-signals? raw) raw]
      [(or (opponent-world-summary? raw) (opponent-world-model? raw))
       (owm-build-control-signals raw
                                  #:enemy-upgrade-advantage (or upg-adv-override 0))]
      [else
       (owm-build-control-signals #f
                                  #:enemy-upgrade-advantage (or upg-adv-override 0))]))
  (if (and (real? upg-adv-override)
           (= (owm-control-signals-enemy-upgrade-advantage sig) 0)
           (not (= upg-adv-override 0)))
      (struct-copy owm-control-signals sig
                   [enemy-upgrade-advantage (inexact->exact (round upg-adv-override))])
      sig))

(define (evaluate-tactical-operation
         #:frame [frame 0]
         #:race [race 'Unknown]
         #:live-obs? [live-obs? #t]
         #:combat-units [combat-units '()]
         #:enemy-units [enemy-units '()]
         #:ally-buildings [ally-buildings '()]
         #:enemy-buildings [enemy-buildings '()]
         #:owm-signals [raw-owm-signals #f]
         #:base-x [base-x 32.5]
         #:base-y [base-y 32.5]
         #:nat-x [nat-x #f]
         #:nat-y [nat-y #f]
         #:enemy-x [enemy-x 160.5]
         #:enemy-y [enemy-y 160.5]
         #:ally-upgrades [ally-upgrades '()]
         #:enemy-upgrades [enemy-upgrades '()]
         #:enemy-upgrade-advantage [enemy-upg-adv #f]
         #:our-workers [our-workers #f]
         #:our-bases [our-bases #f]
         #:spike-eta-sec [raw-spike-eta 0.0]
         #:power-spike-active? [power-spike-arg? #f]
         #:choke-hold-active? [choke-hold-active? #f]
         #:choke-redirect-xy [choke-redirect-xy #f]
         #:enemy-turtle-posterior [raw-turtle-post 0.0]
         #:under-home-attack? [under-home-attack? #f]
         #:enemy-near-main? [enemy-near-main? #f]
         #:enemy-main-cleared? [enemy-main-cleared? #f]
         #:decisive-victory? [decisive-victory? #f]
         #:cheese-committed? [cheese-committed? #f]
         #:skip-build-order? [skip-build-order? #f]
         #:has-home-economy-base? [has-home-base? #t]
         #:pullback-active? [pullback-active? #f]
         #:supply-used [supply-used 0]
         #:combat-pred-ht [combat-pred-ht #f]
         #:pathable-fn [pathable-fn #f]
         #:fallback-pt [fallback-pt #f]
         #:state [op-state #f])
  (define cur-frame (if (exact-integer? frame) frame 0))
  (when (and (tactical-op-state? op-state)
             (>= (tactical-op-state-last-frame op-state) 0)
             (or (< cur-frame (tactical-op-state-last-frame op-state))
                 (> (- cur-frame (tactical-op-state-last-frame op-state)) 1200)))
    (reset-tactical-op-state! op-state))

  ;; ---------------------------------------------------------------------------
  ;; A. Read ALL 7 Calibrated OWM Dimensions
  ;; ---------------------------------------------------------------------------
  (define owm (normalize-owm-signals raw-owm-signals enemy-upg-adv))
  ;; Dim 1: Bases & Map Control
  (define owm-conf-bases (owm-control-signals-confirmed-bases owm))
  (define owm-est-bases (max owm-conf-bases (owm-control-signals-estimated-bases owm)))
  (define owm-happy-bases (owm-control-signals-happy-expected-bases owm))
  (define owm-stopped-exp? (owm-control-signals-stopped-expanding? owm))
  (define owm-unscouted-ambig? (owm-control-signals-unscouted-expansion-ambiguity? owm))
  (define owm-early-greed? (owm-control-signals-confirmed-early-greed? owm))
  (define owm-urgent-pad (owm-control-signals-urgent-scout-pad owm))
  ;; Dim 2: Geysers & Resource Income
  (define owm-est-gases (max (owm-control-signals-confirmed-geysers owm)
                             (owm-control-signals-estimated-geysers owm)))
  (define owm-min-rate (fl->safe (owm-control-signals-est-min-rate owm) 0.0))
  (define owm-gas-rate (fl->safe (owm-control-signals-est-gas-rate owm) 0.0))
  (define owm-cum-min (fl->safe (owm-control-signals-cum-minerals-mined owm) 0.0))
  (define owm-cum-gas (fl->safe (owm-control-signals-cum-gas-mined owm) 0.0))
  ;; Dim 3: Workers & Eco Attrition
  (define owm-est-workers (owm-control-signals-estimated-workers owm))
  (define owm-workers-killed (owm-control-signals-workers-killed owm))
  ;; Dim 4: Production Throughput & Imminent Reachable Supply
  (define owm-prod-facs (max (owm-control-signals-production-facility-count owm)
                             (owm-control-signals-home-prod-count owm)))
  (define owm-imminent-sup (fl->safe (owm-control-signals-imminent-reachable-supply owm) 0.0))
  ;; Dim 5: Hidden Tech & Unaccounted Bank
  (define owm-unacc-min (fl->safe (owm-control-signals-unaccounted-minerals owm) 0.0))
  (define owm-unacc-gas (fl->safe (owm-control-signals-unaccounted-gas owm) 0.0))
  (define owm-hidden-gas-tech? (owm-control-signals-hidden-gas-tech-risk? owm))
  (define owm-1base-2gas? (owm-control-signals-enemy-1base-double-gas? owm))
  (define owm-early-pool? (owm-control-signals-early-pool-latched? owm))
  (define owm-proxy-floor (fl->safe (owm-control-signals-inferred-proxy-rush-floor owm) 0.0))
  (define owm-req-aa? (owm-control-signals-requires-anti-air? owm))
  (define owm-req-det? (owm-control-signals-requires-detection? owm))
  ;; Dim 6: Standing Army, Siege/Turtle & Free-Summon Split
  (define owm-known-sup (fl->safe (owm-control-signals-known-army-supply owm) 0.0))
  (define owm-known-val (fl->safe (owm-control-signals-known-army-value owm) 0.0))
  (define owm-bel-sup (fl->safe (owm-control-signals-believed-army-supply owm) 0.0))
  (define owm-bel-val (fl->safe (owm-control-signals-believed-army-value owm) 0.0))
  (define owm-siege-cnt (owm-control-signals-enemy-siege-or-turtle-count owm))
  (define owm-locust-wave? (owm-control-signals-locust-wave-active? owm))
  (define owm-sh-cooldown? (owm-control-signals-swarm-host-cooldown-window? owm))
  (define owm-summon-cnt (owm-control-signals-active-summon-count owm))
  (define owm-destroyed-val
    (fl+ (fl->safe (owm-control-signals-destroyed-min owm) 0.0)
         (fl* 1.5 (fl->safe (owm-control-signals-destroyed-gas owm) 0.0))))
  ;; Dim 7: Upgrades & Posture
  (define enemy-upg-adv-int (owm-control-signals-enemy-upgrade-advantage owm))
  (define ally-upg-delta (- enemy-upg-adv-int)) ;; positive = we are ahead on upgrades
  (define owm-enemy-posture (owm-control-signals-enemy-posture owm))

  ;; ---------------------------------------------------------------------------
  ;; B. Spatial Anchors, Local Cohesive Force & Home Defense Engagement Check
  ;; ---------------------------------------------------------------------------
  (define bx (fl->safe base-x 32.5))
  (define by (fl->safe base-y 32.5))
  (define nx (if (real? nat-x) (exact->inexact nat-x) bx))
  (define ny (if (real? nat-y) (exact->inexact nat-y) by))
  (define ex0 (fl->safe enemy-x 160.5))
  (define ey0 (fl->safe enemy-y 160.5))
  (define own-th-pts (extract-owned-th-pts ally-buildings bx by))
  (define eff-our-bases
    (if (and (exact-integer? our-bases) (> our-bases 0))
        our-bases
        (max 1 (length own-th-pts))))

  (define vis-enemy-combat
    (for/list ([e (in-list (if (list? enemy-units) enemy-units '()))]
               #:when (rec-combat-unit? e))
      e))
  (define vis-ally-combat
    (for/list ([u (in-list (if (list? combat-units) combat-units '()))]
               #:when (rec-combat-unit? u))
      u))
  (define total-ally-sup
    (for/fold ([s 0.0]) ([u (in-list vis-ally-combat)])
      (fl+ s (unit-sup-val u))))
  (define our-siege-breaker-cnt
    (for/sum ([u (in-list vis-ally-combat)])
      (if (memq (rec-canon-sym u) SIEGE-BREAKER-SYMS) 1 0)))

  ;; Owned-base defense perimeter (`<= 26t` immediate TH threat, `<= 38t` own-territory
  ;; clash guard, `<= 40t` home-approach Queen retention; strictly requires `(pair? own-th-pts)`
  ;; so 0-TH arenas & mid-map skirmishes never misfire!)
  (define (pt-within-owned-th-radius? px py rad)
    (and (pair? own-th-pts)
         (for/or ([tp (in-list own-th-pts)])
           (fl<= (dist2d-fl px py (car tp) (cdr tp)) rad))))
  (define (pt-near-owned-th? px py)
    (pt-within-owned-th-radius? px py OP-HOME-THREAT-RADIUS))

  (define th-perimeter-enemies
    (for/list ([e (in-list vis-enemy-combat)]
               #:when (pt-near-owned-th? (rec-x e 9999.0) (rec-y e 9999.0)))
      e))
  (define own-territory-enemies
    (for/list ([e (in-list vis-enemy-combat)]
               #:when (pt-within-owned-th-radius? (rec-x e 9999.0) (rec-y e 9999.0)
                                                  OP-OWN-TERRITORY-CLASH-RADIUS))
      e))
  (define enemy-near-home-approach?
    (for/or ([e (in-list vis-enemy-combat)])
      (pt-within-owned-th-radius? (rec-x e 9999.0) (rec-y e 9999.0)
                                  OP-HOME-APPROACH-RADIUS)))
  (define any-local-clash-now?
    (and (pair? vis-enemy-combat)
         (for/or ([u (in-list vis-ally-combat)])
           (let ([ux (rec-x u 0.0)] [uy (rec-y u 0.0)])
             (for/or ([e (in-list vis-enemy-combat)])
               (fl<= (dist2d-fl ux uy (rec-x e 9999.0) (rec-y e 9999.0))
                     OP-LOCAL-CLASH-RADIUS))))))
  (define home-enemy-units th-perimeter-enemies)
  (define th-threat-active?
    (or enemy-near-main? under-home-attack? (pair? home-enemy-units)))
  (define home-threat-active? th-threat-active?)

  ;; Keep base-bound macro/defense units (e.g. Queens) in `main-cluster` / `local-cluster-val`
  ;; whenever defending home, any visible enemy is `<= 40t` of an owned TH, OR any local clash
  ;; is active; ONLY exclude home Queens from cross-map `local-cohesion` clustering in pure fog!
  (define mobile-ally-combat
    (if (or home-threat-active? enemy-near-home-approach? any-local-clash-now?)
        vis-ally-combat
        (let ([mob (for/list ([u (in-list vis-ally-combat)]
                              #:unless (and (memq (rec-canon-sym u) BASE-BOUND-MACRO-COMBAT-SYMS)
                                            (pt-near-owned-th? (rec-x u 0.0) (rec-y u 0.0))))
                     u)])
          (if (pair? mob) mob vis-ally-combat))))

  ;; Local cohesive combat cluster (`<= 18t`)
  (define focus-pt
    (cond
      [(pair? th-perimeter-enemies)
       (cons (rec-x (car th-perimeter-enemies) nx) (rec-y (car th-perimeter-enemies) ny))]
      [(pair? vis-enemy-combat)
       (cons (rec-x (car vis-enemy-combat) ex0) (rec-y (car vis-enemy-combat) ey0))]
      [else #f]))
  (define-values (main-cluster main-cx main-cy local-cluster-val total-ally-val local-cohesion)
    (compute-local-combat-clusters mobile-ally-combat
                                   #:radius OP-CLUSTER-RADIUS
                                   #:focus-pt focus-pt))

  ;; Local visible enemy cluster near our main fighting cluster (`<= 22t`)
  (define local-enemy-cluster
    (if (pair? main-cluster)
        (for/list ([e (in-list vis-enemy-combat)]
                   #:when (fl<= (dist2d-fl (rec-x e 9999.0) (rec-y e 9999.0) main-cx main-cy)
                                OP-LOCAL-CLASH-RADIUS))
          e)
        '()))
  (define local-enemy-val
    (for/fold ([v 0.0]) ([e (in-list local-enemy-cluster)])
      (fl+ v (unit-res-val e))))
  ;; Include all visible enemy combat units (including distant scouted siege/armies)
  (define-values (total-vis-enemy-val vis-enemy-siege-cnt)
    (for/fold ([tv 0.0] [sc 0]) ([e (in-list vis-enemy-combat)])
      (values (fl+ tv (unit-res-val e))
              (if (memq (rec-canon-sym e) ENEMY-SIEGE-WALL-SYMS) (add1 sc) sc))))
  (define slow-nonretreatable-army?
    (for/or ([u (in-list vis-ally-combat)])
      (and (memq (rec-canon-sym u) SLOW-FOG-COMMIT-SYMS) #t)))

  ;; Automatic upgrade-completion power-spike detection on `op-state`
  (define auto-upgrade-spike?
    (cond
      [(not (tactical-op-state? op-state)) #f]
      [else
       (define cur-u-set
         (for/seteq ([u (in-list (if (list? ally-upgrades) ally-upgrades '()))]
                     #:when (symbol? u))
           u))
       (define rec (hash-ref op-state-upgrade-table op-state #f))
       (cond
         [(not (pair? rec))
          (hash-set! op-state-upgrade-table op-state (cons cur-u-set -1))
          #f]
         [else
          (define prev-set (car rec))
          (define prev-until (cdr rec))
          (define new-upg? (> (set-count (set-subtract cur-u-set prev-set)) 0))
          (define next-until
            (if new-upg?
                (+ cur-frame OP-POWER-SPIKE-DWELL-FRAMES)
                prev-until))
          (hash-set! op-state-upgrade-table op-state (cons cur-u-set next-until))
          (and (> next-until 0) (<= cur-frame next-until))])]))
  (define eff-power-spike? (or power-spike-arg? auto-upgrade-spike?))

  ;; Detect exposed outer enemy expansion (> 26t from enemy main anchor)
  (define exposed-enemy-expand?
    (or owm-early-greed?
        (for/or ([eb (in-list (if (list? enemy-buildings) enemy-buildings '()))])
          (and (rec-xy? eb)
               (memq (sc2-canonical-structure-sym (rec-raw-sym eb)) TOWNHALL-SYMS)
               (fl> (dist2d-fl (rec-x eb ex0) (rec-y eb ey0) ex0 ey0) 26.0)))))

  ;; Detect contested-frontline enemy structure within `<= 26t` of our main cluster
  ;; on our half / midline (not deep enemy territory -> zero deep-fog surcharge!)
  (define frontline-contest-target?
    (and (pair? main-cluster)
         (for/or ([eb (in-list (if (list? enemy-buildings) enemy-buildings '()))])
           (and (rec-xy? eb)
                (not (rec-snapshot? eb))
                (let* ([ebx (rec-x eb ex0)]
                       [eby (rec-y eb ey0)]
                       [d-cl (dist2d-fl ebx eby main-cx main-cy)]
                       [d-our (dist2d-fl ebx eby bx by)]
                       [d-en (dist2d-fl ebx eby ex0 ey0)])
                  (and (fl<= d-cl 26.0)
                       (fl<= d-our (fl+ d-en 12.0))))))))

  ;; Clash elevation & choke geometry
  (define-values (elev-delta choke-width)
    (compute-clash-elevation-and-choke main-cluster local-enemy-cluster
                                       #:pathable-fn pathable-fn))
  (define uphill-disadv? (fl<= elev-delta -1.5))

  ;; Resolve Loop 87C `active-home-defense-engaged?` & own-territory clash guard
  (define home-enemy-val
    (for/fold ([v 0.0]) ([e (in-list home-enemy-units)])
      (fl+ v (unit-res-val e))))
  (define-values (home-eng-cnt home-eng-sup)
    (if (pair? home-enemy-units)
        (for/fold ([c 0] [s 0.0]) ([u (in-list vis-ally-combat)])
          (define ux (rec-x u 0.0))
          (define uy (rec-y u 0.0))
          (if (for/or ([e (in-list home-enemy-units)])
                (fl<= (dist2d-fl ux uy (rec-x e 9999.0) (rec-y e 9999.0)) OP-HOME-ENGAGED-RADIUS))
              (values (add1 c) (fl+ s (unit-sup-val u)))
              (values c s)))
        (values 0 0.0)))
  (define active-home-defense-engaged?
    (or (>= home-eng-cnt 3) (fl>= home-eng-sup 6.0)))
  ;; Any live clash inside a real owned TownHall perimeter (`<= 38t` of any owned TH)
  ;; MUST NEVER fall through to `'retreat-regroup` (prevents own-territory retreat loops
  ;; across the 26..38t home-approach band while preserving mid-map & 0-TH arena micro!).
  (define own-territory-clash?
    (and (pair? own-th-pts)
         (pair? main-cluster)
         (pair? local-enemy-cluster)
         (or (pt-within-owned-th-radius? main-cx main-cy OP-OWN-TERRITORY-CLASH-RADIUS)
             (pair? own-territory-enemies))))

  ;; ---------------------------------------------------------------------------
  ;; C. Combine All 7 OWM Dimensions + Local Cohesive Lanchester Physics
  ;; ---------------------------------------------------------------------------
  ;; Dim 4: Imminent reachable enemy reinforcements (~75 res/supply average)
  (define imminent-val (fl* 75.0 owm-imminent-sup))
  ;; Dim 5: Hidden tech / unaccounted bank buffer (bounded when army unseen)
  (define unacc-fog-buffer
    (if (and (null? local-enemy-cluster)
             (or owm-hidden-gas-tech? owm-1base-2gas? (fl>= owm-proxy-floor 0.50)))
        (flmin 900.0 (fl* 0.35 (fl+ owm-unacc-min (fl* 1.5 owm-unacc-gas))))
        0.0))
  ;; Effective threat value seen (local OR distant) + believed vs (known + imminent wave)
  (define standing-enemy-val
    (flmax total-vis-enemy-val local-enemy-val home-enemy-val owm-known-val owm-bel-val))
  (define eff-enemy-threat-val
    (if home-threat-active?
        (flmax home-enemy-val local-enemy-val)
        (fl+ (flmax standing-enemy-val (fl+ owm-known-val imminent-val))
             unacc-fog-buffer)))

  ;; Run Lanchester + terrain + choke + upgrade evaluation on already-clustered `main-cluster`
  ;; (pass `#:ally-cohesion 1.0` because `main-cluster` ALREADY excludes dispersed units > 18t!)
  (define local-pred-ht
    (cond
      [(and (pair? main-cluster) (pair? local-enemy-cluster))
       (predict-engagement-outcome
        main-cluster local-enemy-cluster
        #:ally-upgrades ally-upgrades
        #:enemy-upgrades enemy-upgrades
        #:defending-home? home-threat-active?
        #:ally-cohesion 1.0
        #:elevation-delta elev-delta
        #:choke-width choke-width
        #:upgrade-delta ally-upg-delta)]
      [(and home-threat-active? (hash? combat-pred-ht)) combat-pred-ht]
      [else #f]))

  (define upg-ratio-factor
    (expt 1.12 (flmax -3.0 (flmin 3.0 (exact->inexact ally-upg-delta)))))
  ;; `local-cluster-val` ALREADY excludes rear stragglers/rallies outside `<= 18t`;
  ;; do NOT multiply again by `(local-cohesion)^1.35` (eliminates double cohesion penalty!).
  (define fog-ratio
    (if (fl> eff-enemy-threat-val 1.0)
        (fl* (fl/ local-cluster-val eff-enemy-threat-val)
             upg-ratio-factor)
        (if (pair? main-cluster) 2.5 0.0)))
  (define eff-power-ratio
    (cond
      [(and (hash? local-pred-ht)
            (real? (hash-ref local-pred-ht 'predicted-lanchester-ratio #f)))
       (exact->inexact (hash-ref local-pred-ht 'predicted-lanchester-ratio 1.0))]
      [else fog-ratio]))

  ;; Dynamic commit threshold shaped continuously by OWM Dims 1-7
  (define high-gas-tech-opp?
    (or (and (fl> owm-min-rate 1.0) (fl>= (fl/ owm-gas-rate owm-min-rate) 0.35))
        (and (fl> owm-cum-min 1.0) (fl>= (fl/ owm-cum-gas owm-cum-min) 0.35))
        (>= owm-est-gases 4)))
  (define worker-delta
    (if (and (exact-integer? our-workers) (> owm-est-workers 0))
        (- our-workers owm-est-workers)
        0))
  (define owm-initialized?
    (or (fl> owm-cum-min 0.0) (> owm-est-workers 0) (fl> owm-bel-val 0.0)))
  (define eco-lead?
    (and owm-initialized?
         (or (>= worker-delta 8)
             (> eff-our-bases owm-est-bases)
             (and (>= owm-workers-killed 8) (fl> owm-destroyed-val 600.0)))))
  ;; Confirm economic deficit from confirmed enemy bases (never blind 1-base fog priors)
  (define eco-behind?
    (or (>= (- owm-conf-bases eff-our-bases) 2)
        (and (>= eff-our-bases 2) (<= worker-delta -16))))
  (define enemy-stopped-behind-happy?
    (or owm-stopped-exp? (< owm-est-bases owm-happy-bases)))
  (define enemy-aggressive-posture?
    (memq owm-enemy-posture '(AllIn Rush Cheese Aggressive TimingPush)))
  (define turtle-post (fl->safe raw-turtle-post 0.0))
  (define eff-enemy-siege-cnt (max owm-siege-cnt vis-enemy-siege-cnt))
  (define critical-mass-army?
    (fl>= total-ally-sup (fl* 0.30 (exact->inexact SC2-MAX-SUPPLY))))
  (define enemy-fortified?
    (or (>= eff-enemy-siege-cnt 3)
        (fl>= turtle-post 0.45)
        choke-hold-active?))
  (define prod-surge-pressure?
    (or (>= owm-prod-facs 5)
        (fl>= owm-imminent-sup 10.0)
        owm-early-pool?))

  (define siege-parity-met?
    (and (>= our-siege-breaker-cnt 3)
         (>= our-siege-breaker-cnt
             (inexact->exact (ceiling (fl* 0.65 (exact->inexact eff-enemy-siege-cnt)))))))

  (define base-commit-thresh
    (let* ([t0 0.95]
           ;; Dim 1: Stopped expanding -> expect all-in; greed/exposed/frontline -> contest
           [t1 (cond [exposed-enemy-expand? (fl- t0 0.12)]
                     [frontline-contest-target? (fl- t0 0.15)]
                     [enemy-stopped-behind-happy? (fl+ t0 0.08)]
                     [else t0])]
           ;; Dim 2 & 3: High-gas tech / eco lead (only when behind in army < 1.0!) -> play solid;
           ;;            confirmed eco behind -> force tempo; never hesitate when ahead in army!
           [t2 (fl+ t1
                    (fl+ (if high-gas-tech-opp? 0.05 0.0)
                         (cond [(and eco-lead? (fl< eff-power-ratio 1.0)) 0.08]
                               [eco-behind? -0.14]
                               [else 0.0])))]
           ;; Dim 4 & 5: Heavy production / hidden tech / slow sub-parity blind-fog risk
           [t3 (fl+ t2
                    (fl+ (if prod-surge-pressure? 0.05 0.0)
                         (fl+ (if (or owm-hidden-gas-tech? owm-req-aa?) 0.06 0.0)
                              (if (and (null? vis-enemy-combat)
                                       slow-nonretreatable-army?
                                       (fl< eff-power-ratio 1.05)
                                       (not eff-power-spike?)
                                       (not frontline-contest-target?))
                                  0.08
                                  0.0))))]
           ;; Dim 6: Siege/turtle requires breaker parity or critical mass; SH cooldown opens punish
           [t4 (fl+ t3
                    (cond [owm-sh-cooldown? -0.20]
                          [critical-mass-army? 0.0]
                          [(and enemy-fortified? siege-parity-met?) 0.0]
                          [(and enemy-fortified? (< our-siege-breaker-cnt 2)) 0.18]
                          [enemy-fortified? 0.06]
                          [else 0.0]))]
           ;; Dim 7: Upgrade timing / active power spike & aggressive enemy posture
           [t5 (fl+ t4
                    (fl+ (cond [eff-power-spike? -0.14]
                               [(>= ally-upg-delta 1) -0.12]
                               [(<= ally-upg-delta -1) 0.12]
                               [else 0.0])
                         (if enemy-aggressive-posture? 0.06 0.0)))]
           ;; Prevent penalty stacking from locking midgame armies in passive hold:
           ;; non-fortified (or siege-parity / critical-mass) capped at 1.12; fortified at 1.22.
           [max-thresh (if (and enemy-fortified?
                                (not critical-mass-army?)
                                (not siege-parity-met?))
                           1.22
                           1.12)])
      (flmax 0.65 (flmin max-thresh t5))))

  ;; Cap retreat threshold cleanly at 0.78 so even/winning fights never trigger `'retreat-regroup`
  (define retreat-thresh (flmax 0.50 (flmin 0.78 (fl- base-commit-thresh 0.25))))
  (define spike-eta (flmax 0.0 (fl->safe raw-spike-eta 0.0)))
  ;; Only small early 2-base flagship tech timings (`< 12%` max supply, empty local map)
  ;; wait above parity; midgame armies (`>= 1.05x`) NEVER stall on secondary tech addons!
  (define early-flagship-spike-wait?
    (and (null? local-enemy-cluster)
         (<= eff-our-bases 2)
         (fl< total-ally-sup (fl* 0.12 (exact->inexact SC2-MAX-SUPPLY)))))
  (define waiting-for-spike?
    (and (fl> spike-eta 0.0)
         (fl<= spike-eta OP-SPIKE-WINDOW-SEC)
         (not home-threat-active?)
         (not owm-sh-cooldown?)
         (fl< eff-power-ratio (if early-flagship-spike-wait? 2.50 1.05))))
  (define uphill-brake-active?
    (and uphill-disadv?
         (not th-threat-active?)
         (fl< eff-power-ratio 1.50)))
  ;; Relax `dispersed-army?` whenever our main cohesive cluster ALREADY beats the enemy
  ;; threat (or holds critical mass), so multi-base rallies never stall a winning push!
  (define main-cluster-beats-threat?
    (or critical-mass-army?
        (and (fl> eff-enemy-threat-val 200.0)
             (fl>= local-cluster-val (fl* eff-enemy-threat-val base-commit-thresh)))))
  (define dispersed-army?
    (and (>= (length mobile-ally-combat) 4)
         (fl< local-cohesion 0.65)
         (null? local-enemy-cluster)
         (not main-cluster-beats-threat?)))
  (define locust-kite-now?
    (and owm-locust-wave?
         (>= owm-summon-cnt 6)
         (not enemy-near-main?)))
  (define valid-redirect-pt
    (and (pair? choke-redirect-xy)
         (real? (car choke-redirect-xy))
         (real? (cdr choke-redirect-xy))
         (cons (exact->inexact (car choke-redirect-xy))
               (exact->inexact (cdr choke-redirect-xy)))))

  ;; Safe regroup / pre-arc anchor points
  (define default-regroup-pt
    (cond
      [(and (pair? fallback-pt) (real? (car fallback-pt)) (real? (cdr fallback-pt)))
       (cons (exact->inexact (car fallback-pt)) (exact->inexact (cdr fallback-pt)))]
      [(>= eff-our-bases 2)
       (cons nx ny)]
      [else
       (cons bx by)]))
  (define facing-pt
    (cond
      [(pair? local-enemy-cluster)
       (cons (rec-x (car local-enemy-cluster) ex0) (rec-y (car local-enemy-cluster) ey0))]
      [(pair? home-enemy-units)
       (cons (rec-x (car home-enemy-units) ex0) (rec-y (car home-enemy-units) ey0))]
      [else
       (cons ex0 ey0)]))

  ;; ---------------------------------------------------------------------------
  ;; D. Resolve Single Canonical `op-mode`
  ;; ---------------------------------------------------------------------------
  (define raw-mode-and-reason
    (cond
      ;; 1. Unconditional commit bypasses (arena, cheese, endgame, decisive lead, maxed)
      [(or (not live-obs?)
           skip-build-order?
           cheese-committed?
           (not has-home-base?)
           enemy-main-cleared?
           decisive-victory?
           (>= supply-used (inexact->exact (floor (* 0.90 SC2-MAX-SUPPLY)))))
       (cons 'commit-push 'all-in-or-endgame)]
      ;; 2. Home defense: NEVER split an active home fight (`active-home-defense-engaged?`)
      [home-threat-active?
       (define local-home-ok?
         (or (fl<= home-enemy-val 0.0)
             (fl>= local-cluster-val (fl* 0.72 home-enemy-val))
             (fl>= total-ally-val (fl* 0.72 home-enemy-val))
             (fl>= eff-power-ratio 1.15)))
       (if (or enemy-near-main? active-home-defense-engaged? local-home-ok?)
           (cons 'defend-home 'home-defense-commit)
           (cons 'pre-arc-hold 'home-outer-base-pre-arc))]
      ;; 3. Free-summon anti-bait or genuinely outgunned mid-map fight
      ;;    (NEVER triggers `'retreat-regroup` inside our own 38t TH perimeter or on stale pullback!)
      [(or locust-kite-now?
           (and (not own-territory-clash?)
                (pair? local-enemy-cluster)
                (fl< eff-power-ratio retreat-thresh)))
       (cons 'retreat-regroup
             (if locust-kite-now? 'locust-wave-kite 'outgunned-retreat))]
      ;; 3b. Wave-loss rebuild stages cleanly in `'regroup-stage` (not when winning a live clash)
      [(and pullback-active?
            (not own-territory-clash?)
            (not (and (pair? local-enemy-cluster)
                      (fl>= eff-power-ratio base-commit-thresh))))
       (cons 'regroup-stage 'wave-loss-regroup-stage)]
      ;; 4. Flank / soft-outer-base rotation around fortified chokes or uphill sieges
      [(and valid-redirect-pt
            (or choke-hold-active?
                uphill-brake-active?
                (and enemy-fortified?
                     (not critical-mass-army?)
                     (not siege-parity-met?)
                     (fl< eff-power-ratio base-commit-thresh))))
       (cons 'flank-rotate 'soft-base-flank-redirect)]
      ;; 5. All-race uphill ramp brake (hold pre-arc at ramp bottom while vision arrives)
      [uphill-brake-active?
       (cons 'pre-arc-hold 'all-race-uphill-brake)]
      ;; 6. Imminent upgrade/tech timing spike (`<= 25s`)
      [waiting-for-spike?
       (cons 'pre-arc-hold 'timing-spike-hold)]
      ;; 7. Dispersed army link-up before crossing the map
      [dispersed-army?
       (cons 'regroup-stage 'cohesion-link-up)]
      ;; 8. Insufficient local cohesive force vs believed/imminent enemy threat or fortified choke
      [(or choke-hold-active?
           (and (not critical-mass-army?)
                (fl> eff-enemy-threat-val 200.0)
                (fl< eff-power-ratio base-commit-thresh)))
       (cons (if (or enemy-fortified? (pair? local-enemy-cluster) enemy-stopped-behind-happy?)
                 'pre-arc-hold
                 'regroup-stage)
             (if choke-hold-active? 'choke-attrition-hold 'below-commit-threshold))]
      ;; 9. Ready to commit!
      [else
       (cons 'commit-push 'favorable-commit)]))

  ;; Anti-flicker hysteresis on non-emergency offensive transitions when `op-state` supplied
  (define-values (final-mode final-rationale)
    (let ([cand-mode (car raw-mode-and-reason)]
          [cand-rat (cdr raw-mode-and-reason)])
      (cond
        [(not (tactical-op-state? op-state))
         (values cand-mode cand-rat)]
        [else
         (define prev-mode (tactical-op-state-last-mode op-state))
         (define entered-f (tactical-op-state-mode-entered-frame op-state))
         (define dwell-active? (< (- cur-frame entered-f) OP-HYSTERESIS-DWELL-FRAMES))
         (define emergency-override?
           (or (eq? cand-mode 'defend-home)
               (eq? cand-mode 'retreat-regroup)
               enemy-near-main?
               active-home-defense-engaged?
               owm-sh-cooldown?
               eff-power-spike?
               (fl>= eff-power-ratio (fl+ base-commit-thresh 0.20))))
         (define eff-mode
           (if (and dwell-active?
                    (not emergency-override?)
                    (memq prev-mode '(regroup-stage pre-arc-hold))
                    (eq? cand-mode 'commit-push))
               prev-mode
               cand-mode))
         (unless (eq? eff-mode prev-mode)
           (set-tactical-op-state-last-mode! op-state eff-mode)
           (set-tactical-op-state-mode-entered-frame! op-state cur-frame))
         (set-tactical-op-state-last-frame! op-state cur-frame)
         (values eff-mode (if (eq? eff-mode cand-mode) cand-rat 'hysteresis-hold))])))

  ;; ---------------------------------------------------------------------------
  ;; E. Decoupled Delay Harass, Detector Reserve & Unscouted Pad Signal
  ;; ---------------------------------------------------------------------------
  (define home-defense-deficit?
    (and home-threat-active?
         (fl> home-enemy-val 0.0)
         (fl< total-ally-val (fl* 0.90 home-enemy-val))))
  ;; Bounded (`<= 15%`) mobile delay harass stays ENABLED during `'regroup-stage`,
  ;; `'pre-arc-hold`, `'commit-push`, `'flank-rotate`, and even mid-map `'retreat-regroup`,
  ;; blocked ONLY under active main breach, losing home defense, active home battle,
  ;; tiny army (`< 12` supply), or all-in cheese!
  (define delay-harass-allowed?
    (and live-obs?
         (not cheese-committed?)
         (not skip-build-order?)
         (not enemy-near-main?)
         (not home-defense-deficit?)
         (not active-home-defense-engaged?)
         (>= eff-our-bases 2)
         (fl>= total-ally-sup 12.0)))

  (define suppress-main-attack?
    (and (memq final-mode '(regroup-stage pre-arc-hold retreat-regroup)) #t))
  (define should-engage-local?
    (or (memq final-mode '(defend-home commit-push flank-rotate))
        (and (eq? final-mode 'pre-arc-hold) (pair? local-enemy-cluster))))
  (define scout-ambiguous-pad
    (and owm-unscouted-ambig?
         (pair? owm-urgent-pad)
         owm-urgent-pad))
  (define reserve-home-detector?
    (and (or owm-req-det? owm-hidden-gas-tech? owm-1base-2gas?) #t))

  (tactical-op-plan
   final-mode
   delay-harass-allowed?
   suppress-main-attack?
   should-engage-local?
   default-regroup-pt
   (if (memq final-mode '(pre-arc-hold regroup-stage)) default-regroup-pt #f)
   (if (memq final-mode '(pre-arc-hold regroup-stage)) facing-pt #f)
   (if (eq? final-mode 'flank-rotate) valid-redirect-pt #f)
   scout-ambiguous-pad
   reserve-home-detector?
   spike-eta
   local-cohesion
   local-cluster-val
   eff-enemy-threat-val
   eff-power-ratio
   uphill-brake-active?
   active-home-defense-engaged?
   final-rationale))
