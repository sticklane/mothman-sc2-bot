#lang racket/base

;; =============================================================================
;; `lib/tactics/multiprong-coordinator.rkt`
;; Architecture Phase B + Loop 65 — Operational Multiprong, Rotation,
;; Counter-Backstab & Defensive Split Coordinator (L2b Pure Domain Proposer)
;;
;; FIRST LIVE NATIVE CITIZEN OF `lib/engine/arbiter.rkt` (L3 Unified Arbiter):
;;   - Strictly L0 + L3 (`lib/engine/arbiter.rkt`) + `staging-groups.rkt` ONLY
;;     (zero imports of `bot-runtime.rkt`, `sc2-protobuf-ws.rkt`, or
;;     `priority-macro-brain.rkt`).
;;   - Strictly gated on `(and live-obs? (>= (length ally-townhalls) 2)
;;     (>= frame 5376))` (>= 4:00) so 0/278 Tactics Arena skirmishes are altered.
;;   - 100% map-, race-, and corner-agnostic geometry (NW/NE/SW/SE symmetric).
;;   - Builds typed `proposal` records with ranked same-step `alternatives` and
;;     resolves all tag ownership & threat vetoes through `arbiter-resolve!`,
;;     logging structured `override-signal`s into `arbiter-ledger` and honoring
;;     `claimed-tags` + `role-leases` (`'home-defense` 88 / `'strike-group` 55).
;;
;; Four Unified Operational Mobility Modes (Calibrated to Pro GM Graphs 16-17):
;;   1. Mode 1 (`defensive-split` / `defensive-full-rotate`, prio 860/880):
;;      Proportional nearby response (`~1.5x` threat) for small harass (`<= 12`
;;      supply, `< 1200` value) while main army stays active; immediate full-army
;;      rotation for major pushes (`> 12` supply or `>= 1200` value) hitting an
;;      owned base `>= 25t` from main army.
;;   2. Mode 2 (`counter-backstab`, prio 495):
;;      Capped `10-20%` mobile pack routed via enemy-avoiding flank waypoint
;;      (`>= 20t` clear of enemy army centroid) when enemy army is `>= 30t` from
;;      an exposed outer base and home defense is secure (`336f` cooldown, `560f`
;;      mission timeout, auto-withdraw if defenders `>= 1.25x`).
;;   3. Mode 3 (`offensive-rotate`, prio 510, with same-step `alternatives`):
;;      Rotates mobile attacking force around fortified/losing Enemy Base A
;;      (`>= 500` static/siege value or `< 0.90x` local strength) to lower-threat
;;      Enemy Base B (`>= 25t` away) with `336f` per-pair cooldown & `224f` dwell.
;;   4. Mode 4 (`two-prong-sync`, prio 525, cascading -> rotate -> backstab):
;;      Synchronizes a secondary mobile prong (`10-20%` supply) against Enemy
;;      Base B (`>= 25t` from Base A) inside the same `6-12s` strike window as
;;      main army closing on Base A (with `180f` anti-stall timeout).
;; =============================================================================

(require racket/flonum
         racket/list
         racket/math
         racket/set
         (only-in "../sc2-game-constants.rkt"
                  sc2-canonical-unit-sym
                  sc2-canonical-structure-sym
                  sc2-supply-cost
                  sc2-min-cost
                  sc2-gas-cost
                  acquire-unit-lease!
                  unit-leased-above?
                  unit-role-lease?
                  unit-role-lease-priority
                  unit-role-lease-expires-frame)
         (only-in "../engine/arbiter.rkt"
                  make-proposal
                  make-proposal-claim
                  make-arbiter-budget-snapshot
                  make-arbiter-ledger
                  arbiter-ledger?
                  arbiter-ledger-role-leases
                  arbiter-resolve!
                  arbiter-result-accepted-proposals
                  arbiter-result-approved-actions
                  arbiter-result-claimed-tags
                  arbiter-result-override-signals
                  arbiter-recent-override-count
                  arbiter-role-priority
                  proposal-id
                  proposal-priority
                  proposal-rationale
                  proposal-claim-spec
                  proposal-claim?
                  proposal-claim-role
                  proposal-claim-lease-ttl
                  proposal-claim-unit-tags)
         (only-in "staging-groups.rkt"
                  pick-safe-fallback-point))

(provide
 MULTIPRONG-MIN-FRAME
 MULTIPRONG-ROTATE-COOLDOWN-FRAMES
 MULTIPRONG-ROTATE-DWELL-FRAMES
 MULTIPRONG-BACKSTAB-COOLDOWN-FRAMES
 MULTIPRONG-BACKSTAB-TIMEOUT-FRAMES
 MULTIPRONG-SYNC-MAX-HOLD-FRAMES
 (struct-out multiprong-state)
 make-multiprong-state
 multiprong-state-reset!
 (struct-out multiprong-result)
 multiprong-live-eligible?
 compute-flank-waypoint
 compute-prism-warp-pocket
 step-multiprong-coordinator!)

;; =============================================================================
;; Tuned Operational Constants (Pro GM Graphs 16-17 + Loop 65 Spec)
;; =============================================================================

(define MULTIPRONG-MIN-FRAME 5376)                ;; 4:00 (22.4 fps * 240s)
(define MULTIPRONG-ROTATE-COOLDOWN-FRAMES 336)    ;; 15s per-pair rotation cooldown
(define MULTIPRONG-ROTATE-DWELL-FRAMES 224)       ;; 10s minimum rotation dwell
(define MULTIPRONG-BACKSTAB-COOLDOWN-FRAMES 336)  ;; 15s between backstab dispatches
(define MULTIPRONG-BACKSTAB-TIMEOUT-FRAMES 560)   ;; 25s max runby mission duration
(define MULTIPRONG-SYNC-MAX-HOLD-FRAMES 180)      ;; 8s anti-stall hold for 2-prong sync
(define MULTIPRONG-DEF-COOLDOWN-FRAMES 168)       ;; 7.5s offensive pause after >=3 vetoes
(define MULTIPRONG-BASE-MIN-SEP 25.0)             ;; distinct enemy base separation
(define MULTIPRONG-DEF-THREAT-RADIUS 18.0)        ;; enemy near owned TH
(define MULTIPRONG-DEF-ARMY-FAR-DIST 25.0)        ;; main army far from threatened TH
(define MULTIPRONG-HARASS-MAX-SUPPLY 12.0)        ;; <= 12 sup -> proportional split
(define MULTIPRONG-HARASS-MAX-VALUE 1200.0)       ;; < 1200 res val -> proportional split
(define MULTIPRONG-BACKSTAB-ENEMY-DIST 30.0)      ;; enemy army >= 30t from exposed base
(define MULTIPRONG-FLANK-CLEARANCE 20.0)          ;; >= 20t clear of enemy main centroid
(define MULTIPRONG-CONTACT-NO-MOVE-DIST 18.0)     ;; zero passive 'move within 18t of enemies
(define MULTIPRONG-ENGAGE-LOCK-DIST 12.0)         ;; Loop 65B (`#1861`/`#1862`): never pull units <= 12t off combat/Phase 5 micro!
(define MULTIPRONG-DEF-LEASE-TTL 20)
(define MULTIPRONG-STRIKE-LEASE-TTL 20)
;; Loop 65 Addendum (`#1845`): Protoss Empty-Warp-Prism Chargelot Backstab
(define MULTIPRONG-PRISM-POCKET-MIN-R 8.5)
(define MULTIPRONG-PRISM-POCKET-IDEAL-R 9.5)
(define MULTIPRONG-PRISM-POCKET-MAX-R 10.5)
(define MULTIPRONG-PRISM-POCKET-ARRIVE-DIST 5.0)
(define MULTIPRONG-PRISM-SAFE-PHASE-AA-DIST 9.5)
(define MULTIPRONG-PRISM-POCKET-SAFE-AA-DIST 11.5)
(define MULTIPRONG-PRISM-RETREAT-DIST 8.5)
(define MULTIPRONG-PRISM-RETREAT-COOLDOWN-FRAMES 112)
(define MULTIPRONG-PRISM-MORPH-REFRACTORY-FRAMES 112)   ;; Loop 65C (`#1874`/`#1875`): >=5s between morphs!
(define MULTIPRONG-PRISM-MAX-PHASE-DWELL-FRAMES 448)    ;; Loop 65C (`#1874`/`#1875`): stay phased across <200M/WG dips up to 20s!

(define TOWNHALL-SYMS
  (seteq 'command-center 'orbital-command 'planetary-fortress
         'hatchery 'lair 'hive 'nexus))

(define STATIC-DEFENSE-OR-SIEGE-SYMS
  (seteq 'bunker 'shield-battery 'photon-cannon 'spine-crawler 'spore-crawler
         'planetary-fortress 'missile-turret
         'siege-tank-sieged 'lurker-burrowed 'lurker-mp-burrowed 'liberator-ag))

(define NON-COMBAT-SYMS
  (seteq 'scv 'probe 'drone 'mule 'larva 'egg
         'overlord 'overlord-cocoon 'overlord-transport 'overlord-transport-cocoon
         'overseer 'overseer-siege-mode 'observer 'observer-siege-mode
         'changeling 'changeling-zealot 'changeling-zergling 'changeling-zergling-wings
         'changeling-marine 'changeling-marine-shield
         'creep-tumor 'creep-tumor-burrowed 'creep-tumor-queen
         'interceptor 'locust 'locust-mp 'locust-mp-flying 'broodling 'broodling-escort
         'nydus-worm 'nydus-canal))

(define AIR-UNIT-SYMS
  (seteq 'mutalisk 'corruptor 'brood-lord 'broodlord 'viper
         'phoenix 'oracle 'void-ray 'voidray 'carrier 'tempest 'mothership 'warp-prism 'warp-prism-phasing
         'viking-fighter 'viking 'banshee 'medivac 'liberator 'liberator-ag 'raven 'battlecruiser))

(define ANTI-AIR-UNIT-SYMS
  (seteq 'marine 'viking 'viking-fighter 'thor 'thor-ap 'cyclone 'ghost 'widow-mine 'battlecruiser 'liberator
         'missile-turret 'bunker
         'stalker 'phoenix 'void-ray 'voidray 'archon 'carrier 'tempest 'sentry 'high-templar 'photon-cannon
         'queen 'hydralisk 'mutalisk 'corruptor 'spore-crawler))

(define MOBILE-RAID-SYMS-BY-RACE
  (hasheq
   'Zerg    (seteq 'zergling 'baneling 'mutalisk)
   'Protoss (seteq 'dark-templar 'zealot 'adept 'oracle 'phoenix)
   'Terran  (seteq 'hellion 'hellbat 'reaper 'banshee)))

(define SLOW-OR-ANCHORED-SYMS
  (seteq 'siege-tank 'siege-tank-sieged 'lurker 'lurker-mp 'lurker-burrowed 'lurker-mp-burrowed 'liberator-ag
         'widow-mine-burrowed 'brood-lord 'broodlord 'carrier 'tempest 'mothership
         'battlecruiser 'thor 'thor-ap 'colossus 'queen 'sentry 'medivac 'high-templar 'infestor
         'infestor-burrowed 'viper 'disruptor 'disruptor-phased 'raven))

;; =============================================================================
;; State & Frozen Cross-Lane Result Structs (`#1828`)
;; =============================================================================

(struct multiprong-state
  ([last-frame #:mutable]
   [active-mode #:mutable]             ;; 'inactive | 'defensive-split | 'defensive-full-rotate | 'counter-backstab | 'prism-warp-backstab | 'offensive-rotate | 'two-prong-sync
   [active-target #:mutable]           ;; (cons tx ty) or #f
   [mode-entered-frame #:mutable]
   [last-rotation-frame #:mutable]
   [rotation-from-xy #:mutable]        ;; (cons fx fy) or #f
   [rotation-to-xy #:mutable]          ;; (cons tx ty) or #f
   [rotation-dwell-until #:mutable]
   [last-backstab-frame #:mutable]
   [backstab-tags #:mutable]           ;; immutable seteqv
   [backstab-target #:mutable]         ;; (cons tx ty) or #f
   [backstab-start-frame #:mutable]
   [backstab-phase #:mutable]          ;; 'flank | 'strike
   [sync-hold-start-frame #:mutable]
   [sync-target-b #:mutable]           ;; (cons tx ty) or #f
   [def-cooldown-until #:mutable]
   [prism-tag #:mutable]               ;; exact-integer or #f
   [prism-target-base #:mutable]       ;; (cons bx by) or #f
   [prism-pocket #:mutable]            ;; (cons wx wy) or #f
   [prism-start-frame #:mutable]       ;; exact-integer
   [prism-retreat-until #:mutable]     ;; exact-integer
   [prism-last-morph-frame #:mutable]  ;; exact-integer (112f per-Prism morph refractory!)
   [prism-phased-since-frame #:mutable];; exact-integer (-1 when not phased at pocket; 448f dwell!)
   pair-cooldowns                      ;; mutable hash: (list ax ay bx by) -> frame
   internal-ledger)                    ;; fallback arbiter-ledger when caller passes #f
  #:transparent)

(define (make-multiprong-state)
  (multiprong-state
   -1 'inactive #f -9999 -9999 #f #f -1 -9999 (seteqv) #f -9999 'flank -1 #f -1
   #f #f #f -9999 -1 -9999 -1
   (make-hash)
   (make-arbiter-ledger #:ring-cap 32)))

(define (multiprong-state-reset! st)
  (when (multiprong-state? st)
    (set-multiprong-state-last-frame! st -1)
    (set-multiprong-state-active-mode! st 'inactive)
    (set-multiprong-state-active-target! st #f)
    (set-multiprong-state-mode-entered-frame! st -9999)
    (set-multiprong-state-last-rotation-frame! st -9999)
    (set-multiprong-state-rotation-from-xy! st #f)
    (set-multiprong-state-rotation-to-xy! st #f)
    (set-multiprong-state-rotation-dwell-until! st -1)
    (set-multiprong-state-last-backstab-frame! st -9999)
    (set-multiprong-state-backstab-tags! st (seteqv))
    (set-multiprong-state-backstab-target! st #f)
    (set-multiprong-state-backstab-start-frame! st -9999)
    (set-multiprong-state-backstab-phase! st 'flank)
    (set-multiprong-state-sync-hold-start-frame! st -1)
    (set-multiprong-state-sync-target-b! st #f)
    (set-multiprong-state-def-cooldown-until! st -1)
    (set-multiprong-state-prism-tag! st #f)
    (set-multiprong-state-prism-target-base! st #f)
    (set-multiprong-state-prism-pocket! st #f)
    (set-multiprong-state-prism-start-frame! st -9999)
    (set-multiprong-state-prism-retreat-until! st -1)
    (set-multiprong-state-prism-last-morph-frame! st -9999)
    (set-multiprong-state-prism-phased-since-frame! st -1)
    (hash-clear! (multiprong-state-pair-cooldowns st))))

;; Exact frozen cross-lane result struct (`#1828` / `#1829`)
(struct multiprong-result
  (actions               ;; (listof action-sexp): '(attack-pos uid x y) or '(move uid x y)
   proposals             ;; (listof proposal) submitted to arbiter-resolve! this step
   handled-tags          ;; immutable seteqv of claimed UnitTags
   mode                  ;; symbol: 'inactive | 'defensive-split | 'defensive-full-rotate | 'counter-backstab | 'offensive-rotate | 'two-prong-sync
   active-prong-target)  ;; (cons tx ty) or #f
  #:transparent)

(define (empty-multiprong-result [props '()])
  (multiprong-result '() props (seteqv) 'inactive #f))

;; =============================================================================
;; Fast Flonum Geometry & Entity Helpers
;; =============================================================================

(define (rec-id u)
  (and (hash? u)
       (let ([v (hash-ref u 'id (lambda () (hash-ref u 'tag #f)))])
         (and (exact-integer? v) (> v 0) v))))

(define (rec-x u [def 0.0])
  (define v (and (hash? u) (hash-ref u 'x #f)))
  (if (real? v) (exact->inexact v) (exact->inexact def)))

(define (rec-y u [def 0.0])
  (define v (and (hash? u) (hash-ref u 'y #f)))
  (if (real? v) (exact->inexact v) (exact->inexact def)))

;; Module-level untyped memo tables avoiding per-unit Typed/Untyped contract
;; crossings on `sc2-game-constants.rkt` hot lookups (~10x steady-state speedup!).
(define CANON-UNIT-CACHE (make-hasheq))
(define CANON-STRUCT-CACHE (make-hasheq))
(define UNIT-SUP-CACHE (make-hasheq))
(define UNIT-VAL-CACHE (make-hasheq))

(define (fast-canon-unit sym)
  (hash-ref CANON-UNIT-CACHE sym
            (lambda ()
              (define c (sc2-canonical-unit-sym sym))
              (hash-set! CANON-UNIT-CACHE sym c)
              c)))

(define (fast-canon-struct sym)
  (hash-ref CANON-STRUCT-CACHE sym
            (lambda ()
              (define c (sc2-canonical-structure-sym sym))
              (hash-set! CANON-STRUCT-CACHE sym c)
              c)))

(define (fast-sym-supply s)
  (hash-ref UNIT-SUP-CACHE s
            (lambda ()
              (define v
                (cond
                  [(set-member? NON-COMBAT-SYMS s) 0.0]
                  [(eq? s 'zergling) 0.5]
                  [(eq? s 'baneling) 0.5]
                  [else (max 0.5 (exact->inexact (sc2-supply-cost s 1)))]))
              (hash-set! UNIT-SUP-CACHE s v)
              v)))

(define (fast-sym-val s)
  (hash-ref UNIT-VAL-CACHE s
            (lambda ()
              (define v
                (cond
                  [(set-member? NON-COMBAT-SYMS s) 0.0]
                  [(eq? s 'zergling) 25.0]
                  [(eq? s 'baneling) 50.0]
                  [(set-member? STATIC-DEFENSE-OR-SIEGE-SYMS s)
                   (case s
                     [(planetary-fortress) 550.0]
                     [(bunker) 200.0]
                     [(shield-battery) 150.0]
                     [(photon-cannon spine-crawler) 150.0]
                     [(siege-tank-sieged) 275.0]
                     [(lurker-burrowed lurker-mp-burrowed) 250.0]
                     [(liberator-ag) 300.0]
                     [else 125.0])]
                  [else
                   (exact->inexact (+ (sc2-min-cost s 50) (sc2-gas-cost s 0)))]))
              (hash-set! UNIT-VAL-CACHE s v)
              v)))

(define (rec-sym u)
  (define raw (and (hash? u) (hash-ref u 'type (lambda () (hash-ref u 'unit-type 'unknown)))))
  (if (symbol? raw) (fast-canon-unit raw) 'unknown))

(define (rec-struct-sym b)
  (define raw (and (hash? b) (hash-ref b 'type (lambda () (hash-ref b 'unit-type 'unknown)))))
  (if (symbol? raw) (fast-canon-struct raw) 'unknown))

(define (dist2d-fl ax ay bx by)
  (define dx (fl- ax bx))
  (define dy (fl- ay by))
  (flsqrt (fl+ (fl* dx dx) (fl* dy dy))))

(define (clamp-fl v lo hi)
  (flmax lo (flmin hi v)))

(define (unit-is-air? u)
  (or (eq? (and (hash? u) (hash-ref u 'flying? #f)) #t)
      (set-member? AIR-UNIT-SYMS (rec-sym u))))

(define (unit-supply u)
  (fast-sym-supply (rec-sym u)))

(define (unit-resource-value u)
  (define bs (rec-struct-sym u))
  (if (set-member? STATIC-DEFENSE-OR-SIEGE-SYMS bs)
      (fast-sym-val bs)
      (fast-sym-val (rec-sym u))))

(define (enemy-combat-entity? e)
  (and (hash? e)
       (real? (hash-ref e 'x #f))
       (real? (hash-ref e 'y #f))
       (let ([s (rec-sym e)])
         (not (set-member? NON-COMBAT-SYMS s)))))

(define (centroid-of recs [fbx 0.0] [fby 0.0])
  (if (null? recs)
      (values (exact->inexact fbx) (exact->inexact fby))
      (let-values ([(sx sy n)
                    (for/fold ([sx 0.0] [sy 0.0] [n 0]) ([r (in-list recs)])
                      (values (fl+ sx (rec-x r fbx))
                              (fl+ sy (rec-y r fby))
                              (add1 n)))])
        (if (= n 0)
            (values (exact->inexact fbx) (exact->inexact fby))
            (values (fl/ sx (exact->inexact n))
                    (fl/ sy (exact->inexact n)))))))

(define (min-dist-to-recs x y recs)
  (define best2
    (for/fold ([best 99999999.0]) ([r (in-list recs)])
      (define dx (fl- x (rec-x r 9999.0)))
      (define dy (fl- y (rec-y r 9999.0)))
      (flmin best (fl+ (fl* dx dx) (fl* dy dy)))))
  (if (fl>= best2 99999998.0) 9999.0 (flsqrt best2)))

;; Fast pre-extracted unit cache: #(id sym x y sup val is-air? is-aa? is-raid? min-d-enemy)
(define (make-unit-vec u enemy-xy-vecs raid-pref-set)
  (define tid (rec-id u))
  (define sym (rec-sym u))
  (define ux (rec-x u 0.0))
  (define uy (rec-y u 0.0))
  (define sup (unit-supply u))
  (define val (unit-resource-value u))
  (define air? (unit-is-air? u))
  (define aa? (set-member? ANTI-AIR-UNIT-SYMS sym))
  (define raid? (set-member? raid-pref-set sym))
  (define d2
    (for/fold ([best 99999999.0]) ([ev (in-list enemy-xy-vecs)])
      (define dx (fl- ux (vector-ref ev 0)))
      (define dy (fl- uy (vector-ref ev 1)))
      (flmin best (fl+ (fl* dx dx) (fl* dy dy)))))
  (define den (if (fl>= d2 99999998.0) 9999.0 (flsqrt d2)))
  (vector tid sym ux uy sup val air? aa? raid? den))

(define (extract-base-points th-list [extra-bldgs '()] [fallback-x #f] [fallback-y #f])
  (define raw-pts '())
  (define (add-pt! px py)
    (define fx (exact->inexact px))
    (define fy (exact->inexact py))
    (unless (ormap (lambda (p) (fl< (dist2d-fl fx fy (car p) (cdr p)) 18.0)) raw-pts)
      (set! raw-pts (cons (cons fx fy) raw-pts))))
  (for ([b (in-list (if (list? th-list) th-list '()))])
    (cond
      [(and (hash? b) (real? (hash-ref b 'x #f)) (real? (hash-ref b 'y #f)))
       (add-pt! (hash-ref b 'x) (hash-ref b 'y))]
      [(and (pair? b) (real? (car b)) (real? (cdr b)))
       (add-pt! (car b) (cdr b))]
      [(and (list? b) (>= (length b) 2) (real? (first b)) (real? (second b)))
       (add-pt! (first b) (second b))]))
  (for ([b (in-list (if (list? extra-bldgs) extra-bldgs '()))])
    (when (and (hash? b)
               (set-member? TOWNHALL-SYMS (rec-struct-sym b))
               (real? (hash-ref b 'x #f))
               (real? (hash-ref b 'y #f)))
      (add-pt! (hash-ref b 'x) (hash-ref b 'y))))
  (when (and (real? fallback-x) (real? fallback-y) (null? raw-pts))
    (add-pt! fallback-x fallback-y))
  (reverse raw-pts))

;; Compute an enemy-avoiding flank waypoint >= `clearance` tiles away from
;; `(avoid-x, avoid-y)` between `(sx, sy)` and `(tx, ty)`, 100% map/corner agnostic.
(define (compute-flank-waypoint sx sy tx ty avoid-x avoid-y map-w map-h
                                #:clearance [clearance MULTIPRONG-FLANK-CLEARANCE]
                                #:bfs-dist-fn [bfs-dist-fn #f])
  (define fsx (exact->inexact sx))
  (define fsy (exact->inexact sy))
  (define ftx (exact->inexact tx))
  (define fty (exact->inexact ty))
  (define fax (exact->inexact avoid-x))
  (define fay (exact->inexact avoid-y))
  (define mw (max 40.0 (exact->inexact map-w)))
  (define mh (max 40.0 (exact->inexact map-h)))
  (define dx (fl- ftx fsx))
  (define dy (fl- fty fsy))
  (define len (flmax 1.0 (flsqrt (fl+ (fl* dx dx) (fl* dy dy)))))
  (define px (fl/ (fl- 0.0 dy) len))
  (define py (fl/ dx len))
  (define mx (fl* 0.5 (fl+ fsx ftx)))
  (define my (fl* 0.5 (fl+ fsy fty)))
  (define margin 8.0)
  (define cands
    (for*/list ([side (in-list '(1.0 -1.0))]
                [scale (in-list (list (exact->inexact clearance)
                                      (fl+ (exact->inexact clearance) 8.0)
                                      (fl+ (exact->inexact clearance) 16.0)))])
      (define cx (clamp-fl (fl+ mx (fl* side (fl* scale px))) margin (fl- mw margin)))
      (define cy (clamp-fl (fl+ my (fl* side (fl* scale py))) margin (fl- mh margin)))
      (define bfs-ok?
        (or (not (procedure? bfs-dist-fn))
            (let ([d (bfs-dist-fn cx cy)])
              (and (real? d) (< d 900.0)))))
      (define d-avoid (dist2d-fl cx cy fax fay))
      (define path-cost (fl+ (dist2d-fl fsx fsy cx cy) (dist2d-fl cx cy ftx fty)))
      (vector cx cy d-avoid path-cost bfs-ok?)))
  (define valid (filter (lambda (v) (vector-ref v 4)) cands))
  (define pool (if (pair? valid) valid cands))
  (define safe-pool
    (filter (lambda (v) (fl>= (vector-ref v 2) (exact->inexact clearance))) pool))
  (define best
    (cond
      [(pair? safe-pool)
       (car (sort safe-pool (lambda (a b) (fl< (vector-ref a 3) (vector-ref b 3)))))]
      [else
       (car (sort pool (lambda (a b) (fl> (vector-ref a 2) (vector-ref b 2)))))]))
  (values (vector-ref best 0) (vector-ref best 1)))

(define (base-key pt)
  (cons (exact-round (/ (car pt) 6.0))
        (exact-round (/ (cdr pt) 6.0))))

(define (pair-on-cooldown? st a-pt b-pt frame)
  (define ka (base-key a-pt))
  (define kb (base-key b-pt))
  (define tbl (multiprong-state-pair-cooldowns st))
  (define t1 (hash-ref tbl (cons ka kb) -99999))
  (define t2 (hash-ref tbl (cons kb ka) -99999))
  (< (- frame (max t1 t2)) MULTIPRONG-ROTATE-COOLDOWN-FRAMES))

(define (record-pair-cooldown! st a-pt b-pt frame)
  (define ka (base-key a-pt))
  (define kb (base-key b-pt))
  (define tbl (multiprong-state-pair-cooldowns st))
  (hash-set! tbl (cons ka kb) frame)
  (hash-set! tbl (cons kb ka) frame))

;; =============================================================================
;; Hard Eligibility Gate (`0/278` Tactics Arena Guarantee)
;; =============================================================================

(define (multiprong-live-eligible? #:live-obs? live-obs?
                                   #:frame frame
                                   #:ally-townhalls ally-townhalls
                                   #:endgame-hunt-active? [endgame-hunt-active? #f]
                                   #:enemy-main-cleared? [enemy-main-cleared? #f])
  (and (eq? live-obs? #t)
       (exact-integer? frame)
       (>= frame MULTIPRONG-MIN-FRAME)
       (list? ally-townhalls)
       (>= (length ally-townhalls) 2)
       (not endgame-hunt-active?)
       (not enemy-main-cleared?)))

;; =============================================================================
;; Action Materialization Helpers (`zero_fire_retreat = 0` Discipline!)
;; =============================================================================

;; Emit per-unit commands for `chosen-tags` from `unit-by-tag`:
;; - Ground units NEVER receive passive `'move` within `18.0t` of visible enemies.
;; - In `'attack` style, ALWAYS emit `'attack-pos`.
;; - In `'flank` style, emit `'move` ONLY when strictly `> 18.0t` from ALL visible
;;   enemy combat units (otherwise `'attack-pos` so nobody runs past enemies taking free fire!).
(define (build-squad-actions chosen-tags unit-by-tag tx ty enemy-combat-recs
                             #:style [style 'attack])
  (define ftx (exact->inexact tx))
  (define fty (exact->inexact ty))
  (for/list ([tid (in-list chosen-tags)]
             #:when (hash-has-key? unit-by-tag tid))
    (define u (hash-ref unit-by-tag tid))
    (define ux (rec-x u ftx))
    (define uy (rec-y u fty))
    (define d-en (min-dist-to-recs ux uy enemy-combat-recs))
    (define cmd
      (if (and (eq? style 'flank)
               (fl> d-en MULTIPRONG-CONTACT-NO-MOVE-DIST))
          'move
          'attack-pos))
    (list cmd tid ftx fty)))

(define (rec-raw-type u)
  (and (hash? u)
       (hash-ref u 'type (lambda () (hash-ref u 'unit-type #f)))))

;; Detect Warp Prism transport vs phasing mode directly on raw type/id so
;; `sc2-canonical-unit-sym` (`warp-prism-phasing -> warp-prism`) never hides mode!
(define (unit-is-warp-prism-phasing? u)
  (define rt (rec-raw-type u))
  (or (eq? rt 'warp-prism-phasing) (eqv? rt 136)))

(define (unit-is-warp-prism-transport? u)
  (define rt (rec-raw-type u))
  (or (eq? rt 'warp-prism) (eqv? rt 81)))

(define (unit-is-warp-prism? u)
  (or (unit-is-warp-prism-transport? u)
      (unit-is-warp-prism-phasing? u)))

(define (unit-is-empty-warp-prism? u)
  (and (unit-is-warp-prism? u)
       (<= (let ([c (hash-ref u 'cargo-space-taken 0)])
             (if (real? c) c 0))
           0)
       (let ([p (hash-ref u 'passengers '())])
         (or (not (list? p)) (null? p)))))

(define (min-dist-to-xy-vecs x y vecs)
  (define best2
    (for/fold ([best 99999999.0]) ([v (in-list vecs)])
      (define dx (fl- x (vector-ref v 0)))
      (define dy (fl- y (vector-ref v 1)))
      (flmin best (fl+ (fl* dx dx) (fl* dy dy)))))
  (if (fl>= best2 99999998.0) 9999.0 (flsqrt best2)))

(define (nearest-xy-vec x y vecs [fbx 0.0] [fby 0.0])
  (define-values (bx by best2)
    (for/fold ([bx fbx] [by fby] [best 99999999.0]) ([v (in-list vecs)])
      (define vx (vector-ref v 0))
      (define vy (vector-ref v 1))
      (define dx (fl- x vx))
      (define dy (fl- y vy))
      (define d2 (fl+ (fl* dx dx) (fl* dy dy)))
      (if (fl< d2 best) (values vx vy d2) (values bx by best))))
  (values bx by (if (fl>= best2 99999998.0) 9999.0 (flsqrt best2))))

;; Compute a safe warp-in pocket `8.5-10.5t` behind/beside an exposed enemy base
;; `(bx, by)` (outside `16t` of enemy AA/army when available, strictly `> 14t` of AA),
;; 100% map- & corner-agnostic! Returns `(cons wx wy)` or `#f` if all pockets are unsafe.
(define (compute-prism-warp-pocket bx by en-cx en-cy enemy-aa-vecs enemy-combat-vecs map-w map-h)
  (define fbx (exact->inexact bx))
  (define fby (exact->inexact by))
  (define fex (exact->inexact en-cx))
  (define fey (exact->inexact en-cy))
  (define mw (max 40.0 (exact->inexact map-w)))
  (define mh (max 40.0 (exact->inexact map-h)))
  (define mid-x (fl* 0.5 mw))
  (define mid-y (fl* 0.5 mh))
  (define margin 6.0)
  (define two-pi (fl* 2.0 pi))
  (define best-safe #f)    ;; (vector score x y)
  (define best-ok #f)      ;; (vector score x y)
  (for ([r (in-list (list MULTIPRONG-PRISM-POCKET-IDEAL-R 10.2 8.8))])
    (for ([k (in-range 12)])
      (define ang (fl* two-pi (fl/ (exact->inexact k) 12.0)))
      (define px (clamp-fl (fl+ fbx (fl* r (flcos ang))) margin (fl- mw margin)))
      (define py (clamp-fl (fl+ fby (fl* r (flsin ang))) margin (fl- mh margin)))
      (define d-base (dist2d-fl px py fbx fby))
      (when (and (fl>= d-base 7.5) (fl<= d-base 11.0))
        (define d-aa (min-dist-to-xy-vecs px py enemy-aa-vecs))
        (when (fl> d-aa MULTIPRONG-PRISM-SAFE-PHASE-AA-DIST)
          (define d-en (min-dist-to-xy-vecs px py enemy-combat-vecs))
          (define d-cent (dist2d-fl px py fex fey))
          (define d-mid (dist2d-fl px py mid-x mid-y))
          (define r-pen (flabs (fl- d-base MULTIPRONG-PRISM-POCKET-IDEAL-R)))
          ;; Prefer behind/beside base (away from map center & enemy army centroid), high AA clearance
          (define score
            (fl- (fl+ (flmin 30.0 d-aa)
                      (fl* 0.65 (flmin 30.0 d-en))
                      (fl* 0.25 (flmin 60.0 d-cent))
                      (fl* 0.20 (flmin 80.0 d-mid)))
                 (fl* 2.0 r-pen)))
          (when (and (fl>= d-aa MULTIPRONG-PRISM-POCKET-SAFE-AA-DIST)
                     (fl>= d-en MULTIPRONG-PRISM-POCKET-SAFE-AA-DIST))
            (when (or (not best-safe) (fl> score (vector-ref best-safe 0)))
              (set! best-safe (vector score px py))))
          (when (or (not best-ok) (fl> score (vector-ref best-ok 0)))
            (set! best-ok (vector score px py)))))))
  (define winner (or best-safe best-ok))
  (and winner (cons (vector-ref winner 1) (vector-ref winner 2))))

(define (point-to-segment-dist-fl px py ax ay bx by)
  (define dx (fl- bx ax))
  (define dy (fl- by ay))
  (define len2 (fl+ (fl* dx dx) (fl* dy dy)))
  (if (fl<= len2 1e-6)
      (dist2d-fl px py ax ay)
      (let* ([t (clamp-fl (fl/ (fl+ (fl* (fl- px ax) dx)
                                    (fl* (fl- py ay) dy))
                               len2)
                          0.0 1.0)]
             [cx (fl+ ax (fl* t dx))]
             [cy (fl+ ay (fl* t dy))])
        (dist2d-fl px py cx cy))))

(define (compute-prism-escape-point px py threat-x threat-y base-x base-y map-w map-h)
  (define fpx (exact->inexact px))
  (define fpy (exact->inexact py))
  (define ftx (exact->inexact threat-x))
  (define fty (exact->inexact threat-y))
  (define fbx (exact->inexact base-x))
  (define fby (exact->inexact base-y))
  (define mw (max 40.0 (exact->inexact map-w)))
  (define mh (max 40.0 (exact->inexact map-h)))
  (define ax (fl- fpx ftx))
  (define ay (fl- fpy fty))
  (define alen (flmax 0.5 (flsqrt (fl+ (fl* ax ax) (fl* ay ay)))))
  (define ux (fl/ ax alen))
  (define uy (fl/ ay alen))
  (define hx (fl- fbx fpx))
  (define hy (fl- fby fpy))
  (define hlen (flmax 0.5 (flsqrt (fl+ (fl* hx hx) (fl* hy hy)))))
  (define vx (fl+ (fl* 0.72 ux) (fl* 0.28 (fl/ hx hlen))))
  (define vy (fl+ (fl* 0.72 uy) (fl* 0.28 (fl/ hy hlen))))
  (define vlen (flmax 0.5 (flsqrt (fl+ (fl* vx vx) (fl* vy vy)))))
  ;; Loop 65H (`#1948`): Clamp margin 6.0 -> 12.0 so escape never pins Prism into map corner!
  (values (clamp-fl (fl+ fpx (fl* 18.0 (fl/ vx vlen))) 12.0 (fl- mw 12.0))
          (clamp-fl (fl+ fpy (fl* 18.0 (fl/ vy vlen))) 12.0 (fl- mh 12.0))))

;; =============================================================================
;; Main Step Function (`step-multiprong-coordinator!`, Frozen `#1828` Contract)
;; =============================================================================

(define (step-multiprong-coordinator!
         st
         #:frame frame
         #:live-obs? live-obs?
         #:race race
         #:ally-units ally-units
         #:combat-units combat-units
         #:ally-townhalls ally-townhalls
         #:enemy-units enemy-units
         #:enemy-townhalls enemy-townhalls
         #:base-x base-x
         #:base-y base-y
         #:enemy-x enemy-x
         #:enemy-y enemy-y
         #:map-width [map-w 200.0]
         #:map-height [map-h 200.0]
         #:claimed-tags [claimed-tags (seteqv)]
         #:arbiter-ledger [ledger #f]
         #:role-leases [role-leases #f]
         #:defensive-muster-active? [defensive-muster-active? #f]
         #:combat-suppress-attack? [combat-suppress-attack? #f]
         #:endgame-hunt-active? [endgame-hunt-active? #f]
         #:enemy-main-cleared? [enemy-main-cleared? #f]
         #:enemy-buildings [enemy-buildings '()]
         #:bfs-dist-fn [bfs-dist-fn #f]
         #:fallback-point-fn [fallback-point-fn #f]
         #:ready-warp-gates [ready-warp-gates 0]
         #:minerals [minerals 0]
         #:supply-left [supply-left 0]
         #:charge-researched? [charge-researched? #f])
  (define cur-frame (if (exact-integer? frame) frame 0))
  ;; Automatic rewind / cross-test state reset
  (define prev-f (multiprong-state-last-frame st))
  (when (and (>= prev-f 0)
             (or (< cur-frame prev-f)
                 (> (- cur-frame prev-f) 1200)))
    (multiprong-state-reset! st))
  (set-multiprong-state-last-frame! st cur-frame)

  ;; Collect empty Protoss Warp Prisms from both `ally-units` and `combat-units`
  ;; (deduped by tag) so empty-Prism Chargelot backstabs work with 0 ground units!
  (define ally-empty-prisms
    (if (eq? race 'Protoss)
        (let ([seen (make-hasheqv)]
              [acc '()])
          (for ([lst (in-list (list (if (list? ally-units) ally-units '())
                                    (if (list? combat-units) combat-units '())))])
            (for ([u (in-list lst)])
              (define tid (rec-id u))
              (when (and tid
                         (not (hash-has-key? seen tid))
                         (unit-is-empty-warp-prism? u))
                (hash-set! seen tid #t)
                (set! acc (cons u acc)))))
          (reverse acc))
        '()))
  (define safe-combat-units (if (list? combat-units) combat-units '()))
  (define ground-eligible?
    (multiprong-live-eligible?
     #:live-obs? live-obs?
     #:frame cur-frame
     #:ally-townhalls ally-townhalls
     #:endgame-hunt-active? endgame-hunt-active?
     #:enemy-main-cleared? enemy-main-cleared?))
  ;; Loop 65E (`#1907`/`#1908`): Allow Mode 2B (`prism-warp-backstab`) even during
  ;; `endgame-hunt-active?` as long as `(not enemy-main-cleared?)` and live enemy THs exist
  ;; (still skipping ground Modes 1-4 during `endgame-hunt-active?`!).
  (define live-enemy-th-pts (extract-base-points enemy-townhalls enemy-buildings #f #f))
  (define prism-endgame-eligible?
    (and (eq? race 'Protoss)
         (pair? ally-empty-prisms)
         (eq? live-obs? #t)
         (exact-integer? cur-frame)
         (>= cur-frame MULTIPRONG-MIN-FRAME)
         (list? ally-townhalls)
         (>= (length ally-townhalls) 2)
         (not enemy-main-cleared?)
         (pair? live-enemy-th-pts)))

  (cond
    [(or (and (not ground-eligible?) (not prism-endgame-eligible?))
         (and (null? safe-combat-units)
              (null? ally-empty-prisms)))
     (set-multiprong-state-active-mode! st 'inactive)
     (set-multiprong-state-active-target! st #f)
     (empty-multiprong-result)]
    [else
     (define active-ledger
       (if (arbiter-ledger? ledger)
           ledger
           (multiprong-state-internal-ledger st)))
     (define ledger-leases (arbiter-ledger-role-leases active-ledger))

     ;; Honor external non-ledger claims (`claimed-tags` + distinct caller `role-leases`);
     ;; leases stored directly inside `active-ledger` are adjudicated natively by `arbiter-resolve!`
     ;; so partial narrowing, same-step `alternatives` cascade, and `override-signal` logging all fire.
     (define (tag-externally-blocked? tid caller-role)
       (or (and (set? claimed-tags) (set-member? claimed-tags tid))
           (and (hash? role-leases)
                (not (eq? role-leases ledger-leases))
                (unit-leased-above? role-leases tid caller-role cur-frame))))

     (define enemy-combat-recs
       (filter enemy-combat-entity? (if (list? enemy-units) enemy-units '())))
     ;; Pre-extract lightweight flonum vectors once per step -> < 0.10 ms/step even uncompiled!
     (define enemy-xy-vecs
       (for/list ([e (in-list enemy-combat-recs)])
         (vector (rec-x e 0.0) (rec-y e 0.0) (unit-supply e) (unit-resource-value e) (unit-is-air? e))))
     (define enemy-aa-xy-vecs
       (if (null? ally-empty-prisms)
           '()
           (append
            (for/list ([e (in-list enemy-combat-recs)]
                       #:when (set-member? ANTI-AIR-UNIT-SYMS (rec-sym e)))
              (vector (rec-x e 0.0) (rec-y e 0.0)))
            (for/list ([b (in-list (if (list? enemy-buildings) enemy-buildings '()))]
                       #:when (and (hash? b)
                                   (set-member? ANTI-AIR-UNIT-SYMS (rec-struct-sym b))
                                   (real? (hash-ref b 'x #f))
                                   (real? (hash-ref b 'y #f))))
              (vector (rec-x b 0.0) (rec-y b 0.0))))))
     (define raid-pref-set (hash-ref MOBILE-RAID-SYMS-BY-RACE race (seteq)))

     (define unit-by-tag (make-hasheqv))
     (define uvec-by-tag (make-hasheqv))
     (define all-mobile-combat '())
     (define total-combat-sup 0.0)
     (for ([u (in-list safe-combat-units)])
       (define tid (rec-id u))
       (when tid
         (define sym (rec-sym u))
         (unless (or (set-member? NON-COMBAT-SYMS sym)
                     (unit-is-warp-prism? u))
           (define uv (make-unit-vec u enemy-xy-vecs raid-pref-set))
           (hash-set! unit-by-tag tid u)
           (hash-set! uvec-by-tag tid uv)
           (set! total-combat-sup (fl+ total-combat-sup (vector-ref uv 4)))
           (unless (set-member? SLOW-OR-ANCHORED-SYMS sym)
             (set! all-mobile-combat (cons u all-mobile-combat))))))
     (set! all-mobile-combat (reverse all-mobile-combat))

     (define (uvec-of u) (hash-ref uvec-by-tag (rec-id u) #f))
     (define (uvec-min-d-en u)
       (define uv (uvec-of u))
       (if uv (vector-ref uv 9) 9999.0))
     (define (uvec-sup u)
       (define uv (uvec-of u))
       (if uv (vector-ref uv 4) (unit-supply u)))
     (define (uvec-val u)
       (define uv (uvec-of u))
       (if uv (vector-ref uv 5) (unit-resource-value u)))
     (define (uvec-raid? u)
       (define uv (uvec-of u))
       (and uv (vector-ref uv 8)))
     (define (uvec-aa? u)
       (define uv (uvec-of u))
       (and uv (vector-ref uv 7)))
     (define (uvec-x u)
       (define uv (uvec-of u))
       (if uv (vector-ref uv 2) (rec-x u 0.0)))
     (define (uvec-y u)
       (define uv (uvec-of u))
       (if uv (vector-ref uv 3) (rec-y u 0.0)))
     (define (fast-build-squad-actions chosen-tags tx ty #:style [style 'attack])
       (define ftx (exact->inexact tx))
       (define fty (exact->inexact ty))
       (for/list ([tid (in-list chosen-tags)]
                  #:when (hash-has-key? uvec-by-tag tid))
         (define uv (hash-ref uvec-by-tag tid))
         (define cmd
           (if (and (eq? style 'flank)
                    (fl> (vector-ref uv 9) MULTIPRONG-CONTACT-NO-MOVE-DIST))
               'move
               'attack-pos))
         (list cmd tid ftx fty)))

     (define enemy-static-recs
       (for/list ([b (in-list (append (if (list? enemy-buildings) enemy-buildings '())
                                      (if (list? enemy-units) enemy-units '())))]
                  #:when (and (hash? b)
                              (set-member? STATIC-DEFENSE-OR-SIEGE-SYMS (rec-struct-sym b))
                              (real? (hash-ref b 'x #f))
                              (real? (hash-ref b 'y #f))))
         b))

     (define ally-th-pts (extract-base-points ally-townhalls '() base-x base-y))
     (define enemy-base-pts (extract-base-points enemy-townhalls enemy-buildings enemy-x enemy-y))
     (define-values (main-ax main-ay)
       (centroid-of (if (pair? all-mobile-combat) all-mobile-combat combat-units) base-x base-y))

     ;; Check cross-step arbiter feedback hysteresis (`>= 3` threat vetoes OR `>= 3` higher-priority
     ;; unit claims in `224f` -> bounded `168f` offensive cooldown so multiprong does not oscillate
     ;; against active home defense or detector escort!)
     (define recent-vetoes
       (arbiter-recent-override-count active-ledger 'multiprong-coordinator 'threat-veto cur-frame
                                      #:window-frames 224))
     (define recent-claim-preempts
       (arbiter-recent-override-count active-ledger 'multiprong-coordinator 'unit-claimed-higher-priority cur-frame
                                      #:window-frames 224))
     (when (or (>= recent-vetoes 3)
               (>= recent-claim-preempts 3))
       (set-multiprong-state-def-cooldown-until!
        st (max (multiprong-state-def-cooldown-until st)
                (+ cur-frame MULTIPRONG-DEF-COOLDOWN-FRAMES))))
     (define off-veto-cooled? (< cur-frame (multiprong-state-def-cooldown-until st)))

     ;; =========================================================================
     ;; Evaluate Home Base Threats (Drives Mode 1 & Threat-Veto Guard)
     ;; =========================================================================
     (define worst-home-threat #f) ;; (vector th-x th-y threat-sup threat-val local-def-sup ex ey has-air? major?)
     (define home-defense-deficit? #f)
     ;; Loop 65E/65F (`#1907`/`#1920`): Sticky hysteresis on `army-far?` (enter >= 25.0t, stay active
     ;; down to >= 12.0t for substantive `> 4.0`-sup / `>= 4`-unit threats while in defensive mode),
     ;; AND never peel a forward push (`>= 55.0t` away) for tiny `<= 4.0`-sup / `< 4`-unit micro-harass
     ;; (unless Main base itself has `def-sup = 0`)!
     (define prev-def-mode?
       (and (memq (multiprong-state-active-mode st) '(defensive-full-rotate defensive-split)) #t))
     (for ([th (in-list ally-th-pts)])
       (define thx (car th))
       (define thy (cdr th))
       (define near-en
         (filter (lambda (e) (fl<= (dist2d-fl (rec-x e) (rec-y e) thx thy) MULTIPRONG-DEF-THREAT-RADIUS))
                 enemy-combat-recs))
       (when (pair? near-en)
         (define n-en (length near-en))
         (define t-sup (for/fold ([s 0.0]) ([e (in-list near-en)]) (fl+ s (unit-supply e))))
         (define t-val (for/fold ([v 0.0]) ([e (in-list near-en)]) (fl+ v (unit-resource-value e))))
         (define has-air? (ormap unit-is-air? near-en))
         (define near-allies
           (filter (lambda (u) (fl<= (dist2d-fl (rec-x u) (rec-y u) thx thy) MULTIPRONG-DEF-THREAT-RADIUS))
                   combat-units))
         (define def-sup (for/fold ([s 0.0]) ([u (in-list near-allies)]) (fl+ s (unit-supply u))))
         (define major? (or (fl> t-sup MULTIPRONG-HARASS-MAX-SUPPLY)
                            (fl>= t-val MULTIPRONG-HARASS-MAX-VALUE)))
         (define substantive-threat? (or (fl> t-sup 4.0) (>= n-en 4)))
         (define d-army-th (dist2d-fl main-ax main-ay thx thy))
         (define is-main-th?
           (fl<= (dist2d-fl thx thy (exact->inexact base-x) (exact->inexact base-y)) 12.0))
         (define micro-harass-far-ignore?
           (and (fl>= d-army-th 55.0)
                (not substantive-threat?)
                (not (and is-main-th? (fl<= def-sup 0.0)))))
         (define army-far-thresh
           (if (and prev-def-mode? substantive-threat?) 12.0 MULTIPRONG-DEF-ARMY-FAR-DIST))
         (define army-far? (fl>= d-army-th army-far-thresh))
         (when (and (fl< def-sup (fl* 0.90 t-sup))
                    (or major? (not army-far?)))
           (set! home-defense-deficit? #t))
         (define-values (ex ey) (centroid-of near-en thx thy))
         (when (and (not micro-harass-far-ignore?)
                    (fl< def-sup (fl* 1.15 t-sup))
                    army-far?
                    (or (not worst-home-threat)
                        (fl> t-sup (vector-ref worst-home-threat 2))))
           (set! worst-home-threat (vector thx thy t-sup t-val def-sup ex ey has-air? major?)))))

     (define major-home-push?
       (and worst-home-threat (vector-ref worst-home-threat 8)))

     ;; =========================================================================
     ;; Enemy Main Army Centroid & Per-Base Local Defense Evaluation
     ;; =========================================================================
     (define enemy-army-sup
       (for/fold ([s 0.0]) ([ev (in-list enemy-xy-vecs)]) (fl+ s (vector-ref ev 2))))
     (define-values (en-cx en-cy)
       (if (null? enemy-xy-vecs)
           (values (exact->inexact enemy-x) (exact->inexact enemy-y))
           (let-values ([(sx sy n)
                         (for/fold ([sx 0.0] [sy 0.0] [n 0]) ([ev (in-list enemy-xy-vecs)])
                           (values (fl+ sx (vector-ref ev 0)) (fl+ sy (vector-ref ev 1)) (add1 n)))])
             (values (fl/ sx (exact->inexact n)) (fl/ sy (exact->inexact n))))))

     (define enemy-static-xy-vecs
       (for/list ([b (in-list enemy-static-recs)])
         (vector (rec-x b 0.0) (rec-y b 0.0) (unit-resource-value b))))
     (define (enemy-base-defense-info bpt)
       (define bx (car bpt))
       (define by (cdr bpt))
       (define-values (en-cnt en-val)
         (for/fold ([c 0] [v 0.0]) ([ev (in-list enemy-xy-vecs)])
           (define dx (fl- (vector-ref ev 0) bx))
           (define dy (fl- (vector-ref ev 1) by))
           (if (fl<= (fl+ (fl* dx dx) (fl* dy dy)) 256.0)
               (values (add1 c) (fl+ v (vector-ref ev 3)))
               (values c v))))
       (define st-val
         (for/fold ([v 0.0]) ([sv (in-list enemy-static-xy-vecs)])
           (define dx (fl- (vector-ref sv 0) bx))
           (define dy (fl- (vector-ref sv 1) by))
           (if (fl<= (fl+ (fl* dx dx) (fl* dy dy)) 324.0)
               (fl+ v (vector-ref sv 2))
               v)))
       (values en-cnt en-val st-val (fl+ en-val st-val)))

     ;; =========================================================================
     ;; Proposal Builders for All 4 Modes
     ;; =========================================================================

     ;; --- Mode 1: Defensive Proportional Split vs Immediate Full Rotation ---
     (define mode1-proposal
       (and worst-home-threat
            (let* ([thx (vector-ref worst-home-threat 0)]
                   [thy (vector-ref worst-home-threat 1)]
                   [t-sup (vector-ref worst-home-threat 2)]
                   [def-sup (vector-ref worst-home-threat 4)]
                   [ex (vector-ref worst-home-threat 5)]
                   [ey (vector-ref worst-home-threat 6)]
                   [has-air? (vector-ref worst-home-threat 7)]
                   [major? (or (vector-ref worst-home-threat 8) defensive-muster-active?)]
                   [eligible
                    (filter (lambda (u)
                              (define tid (rec-id u))
                              (and tid
                                   (not (tag-externally-blocked? tid 'home-defense))
                                   (fl> (uvec-min-d-en u) MULTIPRONG-ENGAGE-LOCK-DIST)))
                            all-mobile-combat)])
              (and (pair? eligible)
                   (if major?
                       ;; Mode 1B: Immediate zero-latency FULL army rotation!
                       (let-values ([(tx ty)
                                     (cond
                                       [(procedure? fallback-point-fn)
                                        (fallback-point-fn thx thy ex ey)]
                                       [else
                                        ;; Loop 65E (`#1907`/`#1908`): Intercept enemy push right at the
                                        ;; threatened base (`0.75*ex + 0.25*thx`) instead of pulling behind Main!
                                        (values (fl+ (fl* 0.75 ex) (fl* 0.25 thx))
                                                (fl+ (fl* 0.75 ey) (fl* 0.25 thy)))])])
                         (define req-tags (map rec-id eligible))
                         (make-proposal
                          'mp-defensive-full-rotate
                          'multiprong-coordinator
                          'ops
                          880.0
                          (lambda (chosen)
                            (fast-build-squad-actions chosen tx ty #:style 'attack))
                          #:claim (make-proposal-claim req-tags
                                                       #:role 'home-defense
                                                       #:lease-ttl MULTIPRONG-DEF-LEASE-TTL
                                                       #:allow-partial? #t
                                                       #:min-units 1)
                          #:attention-tier 0
                          #:rationale (cons 'defensive-full-rotate (cons tx ty))))
                       ;; Mode 1A: Proportional nearby response squad (~1.5x threat, leaves main army forward!)
                       (let* ([need-sup (flmin 20.0 (flmax 6.0 (fl* 1.5 (flmax 1.0 (fl- t-sup def-sup)))))]
                              [max-peel (if (fl>= total-combat-sup 24.0)
                                            (fl* 0.45 total-combat-sup)
                                            need-sup)]
                              [cap-sup (flmin need-sup (flmax 6.0 max-peel))]
                              [sorted-def
                               (sort eligible
                                     (lambda (a b)
                                       (define aa-a (and has-air? (uvec-aa? a)))
                                       (define aa-b (and has-air? (uvec-aa? b)))
                                       (cond
                                         [(and aa-a (not aa-b)) #t]
                                         [(and aa-b (not aa-a)) #f]
                                         [else
                                          (fl< (dist2d-fl (uvec-x a) (uvec-y a) thx thy)
                                               (dist2d-fl (uvec-x b) (uvec-y b) thx thy))])))])
                         (define-values (picked-rev _acc-sup)
                           (for/fold ([acc '()] [sup 0.0]) ([u (in-list sorted-def)])
                             (if (and (pair? acc) (fl>= sup cap-sup))
                                 (values acc sup)
                                 (values (cons (rec-id u) acc) (fl+ sup (uvec-sup u))))))
                         (define req-tags (reverse picked-rev))
                         (and (pair? req-tags)
                              (make-proposal
                               'mp-defensive-split
                               'multiprong-coordinator
                               'ops
                               860.0
                               (lambda (chosen)
                                 (fast-build-squad-actions chosen ex ey #:style 'attack))
                               #:claim (make-proposal-claim req-tags
                                                            #:role 'home-defense
                                                            #:lease-ttl MULTIPRONG-DEF-LEASE-TTL
                                                            #:allow-partial? #t
                                                            #:min-units 1)
                               #:attention-tier 0
                               #:rationale (cons 'defensive-split (cons ex ey))))))))))

     ;; --- Helper: Select a 10-20% Mobile Raid / Secondary Prong Pack ---
     (define (select-mobile-pack exclude-tags target-pt [max-sup 12.0])
       (define tx (car target-pt))
       (define ty (cdr target-pt))
       (define target-sup (flmin max-sup (flmax 4.0 (fl* 0.16 total-combat-sup))))
       (define avail
         (filter (lambda (u)
                   (define tid (rec-id u))
                   (and tid
                        (not (set-member? exclude-tags tid))
                        (not (tag-externally-blocked? tid 'strike-group))
                        ;; Never yank units already engaged within 14t of enemies!
                        (fl> (uvec-min-d-en u) 14.0)))
                 all-mobile-combat))
       (define sorted
         (sort avail
               (lambda (a b)
                 (define pa (uvec-raid? a))
                 (define pb (uvec-raid? b))
                 (cond
                   [(and pa (not pb)) #t]
                   [(and pb (not pa)) #f]
                   [else
                    (fl< (dist2d-fl (uvec-x a) (uvec-y a) tx ty)
                         (dist2d-fl (uvec-x b) (uvec-y b) tx ty))]))))
       (define-values (picked-rev acc-sup)
         (for/fold ([acc '()] [sup 0.0]) ([u (in-list sorted)])
           (define us (uvec-sup u))
           (cond
             [(and (pair? acc) (fl>= sup target-sup)) (values acc sup)]
             [(and (pair? acc) (fl> (fl+ sup us) (flmax 6.0 (fl* 0.22 total-combat-sup))))
              (values acc sup)]
             [else (values (cons u acc) (fl+ sup us))])))
       (values (reverse picked-rev) acc-sup))

     ;; Track whether an active backstab mission just aborted (so Mode 4 doesn't
     ;; re-launch immediately into the defended base on the same frame!)
     (define backstab-continuing-before?
       (and (not (set-empty? (multiprong-state-backstab-tags st)))
            (multiprong-state-backstab-target st)
            (< (- cur-frame (multiprong-state-backstab-start-frame st))
               MULTIPRONG-BACKSTAB-TIMEOUT-FRAMES)))
     (define backstab-aborted-this-step? #f)

     ;; --- Mode 2: Counter-Backstab / Runby Proposal Builder ---
     (define (build-backstab-proposal [forced-target #f] [prio 495.0])
       (define existing-tags (multiprong-state-backstab-tags st))
       (define existing-tgt (multiprong-state-backstab-target st))
       (define continuing?
         (and (not (set-empty? existing-tags))
              existing-tgt
              (< (- cur-frame (multiprong-state-backstab-start-frame st))
                 MULTIPRONG-BACKSTAB-TIMEOUT-FRAMES)))
       (cond
         [(or defensive-muster-active? combat-suppress-attack? home-defense-deficit? major-home-push?)
          (when continuing?
            (set-multiprong-state-backstab-tags! st (seteqv))
            (set-multiprong-state-backstab-target! st #f)
            (set-multiprong-state-last-backstab-frame! st cur-frame))
          #f]
         [continuing?
          (define alive-recs
            (for/list ([tid (in-set existing-tags)]
                       #:when (and (hash-has-key? unit-by-tag tid)
                                   (not (tag-externally-blocked? tid 'strike-group))))
              (hash-ref unit-by-tag tid)))
          (define-values (_ec en-val _sv tot-def-val) (enemy-base-defense-info existing-tgt))
          (define pack-val (for/fold ([v 0.0]) ([u (in-list alive-recs)]) (fl+ v (unit-resource-value u))))
          (define-values (px py) (centroid-of alive-recs base-x base-y))
          ;; Loop 65B (`#1861`/`#1862`): Also detect interceptors within `<= 14t` of pack `(px, py)`!
          (define en-pack-val
            (for/fold ([v 0.0]) ([ev (in-list enemy-xy-vecs)])
              (define dx (fl- (vector-ref ev 0) px))
              (define dy (fl- (vector-ref ev 1) py))
              (if (fl<= (fl+ (fl* dx dx) (fl* dy dy)) 196.0)
                  (fl+ v (vector-ref ev 3))
                  v)))
          (define claimable-recs
            (filter (lambda (u) (fl> (uvec-min-d-en u) MULTIPRONG-ENGAGE-LOCK-DIST)) alive-recs))
          (cond
            [(or (null? alive-recs)
                 (and (fl> pack-val 0.0)
                      (or (fl>= en-val (fl* 1.25 pack-val))
                          (fl>= en-pack-val (fl* 1.25 pack-val)))))
             ;; Auto-withdraw / release when outnumbered >= 1.25x (at target OR intercepted en-route) or wiped
             (set! backstab-aborted-this-step? #t)
             (set-multiprong-state-backstab-tags! st (seteqv))
             (set-multiprong-state-backstab-target! st #f)
             (set-multiprong-state-last-backstab-frame! st cur-frame)
             #f]
            [(null? claimable-recs)
             ;; Entire pack made <= 12t combat contact: hand off cleanly to Phase 5 micro/disengage!
             (set-multiprong-state-backstab-tags! st (seteqv))
             (set-multiprong-state-backstab-target! st #f)
             (set-multiprong-state-last-backstab-frame! st cur-frame)
             #f]
            [else
             (define-values (wx wy)
               (compute-flank-waypoint px py (car existing-tgt) (cdr existing-tgt)
                                       en-cx en-cy map-w map-h
                                       #:clearance MULTIPRONG-FLANK-CLEARANCE
                                       #:bfs-dist-fn bfs-dist-fn))
             (define d-wp (dist2d-fl px py wx wy))
             (define d-tgt (dist2d-fl px py (car existing-tgt) (cdr existing-tgt)))
             (define strike-now?
               (or (eq? (multiprong-state-backstab-phase st) 'strike)
                   (fl<= d-wp 10.0)
                   (fl<= d-tgt 22.0)))
             (define cmd-x (if strike-now? (car existing-tgt) wx))
             (define cmd-y (if strike-now? (cdr existing-tgt) wy))
             (define style (if strike-now? 'attack 'flank))
             (define tags (map rec-id claimable-recs))
             (make-proposal
              'mp-counter-backstab
              'multiprong-coordinator
              'ops
              prio
              (lambda (chosen)
                (fast-build-squad-actions chosen cmd-x cmd-y #:style style))
              #:claim (make-proposal-claim tags
                                           #:role 'strike-group
                                           #:lease-ttl MULTIPRONG-STRIKE-LEASE-TTL
                                           #:allow-partial? #t
                                           #:min-units 1)
              #:attention-tier 2
              #:rationale (list 'counter-backstab existing-tgt (if strike-now? 'strike 'flank)))])]
         [(and (>= (- cur-frame (multiprong-state-last-backstab-frame st))
                   MULTIPRONG-BACKSTAB-COOLDOWN-FRAMES)
               ;; Loop 65D (`#1891`/`#1892`): Require >= 32 sup & >= 0.90x visible enemy army!
               (fl>= total-combat-sup 32.0)
               (not (and (fl> enemy-army-sup 0.0)
                         (fl< total-combat-sup (fl* 0.90 enemy-army-sup))))
               (or forced-target
                   (and (>= (length enemy-combat-recs) 4)
                        (fl>= enemy-army-sup 10.0))))
          (define exposed-bases
            (if forced-target
                (list (cons forced-target 0.0))
                (for/list ([bpt (in-list enemy-base-pts)]
                           #:when (fl>= (dist2d-fl en-cx en-cy (car bpt) (cdr bpt))
                                        MULTIPRONG-BACKSTAB-ENEMY-DIST))
                  (define-values (ec _ev _sv tot-v) (enemy-base-defense-info bpt))
                  (and (<= ec 4) (cons bpt tot-v)))))
          (define clean-exposed (filter pair? exposed-bases))
          (and (pair? clean-exposed)
               (let* ([best-b
                       (car (car (sort clean-exposed
                                       (lambda (a b)
                                         (if (fl= (cdr a) (cdr b))
                                             (fl< (dist2d-fl (car (car a)) (cdr (car a))
                                                             (exact->inexact base-x) (exact->inexact base-y))
                                                  (dist2d-fl (car (car b)) (cdr (car b))
                                                             (exact->inexact base-x) (exact->inexact base-y)))
                                             (fl< (cdr a) (cdr b)))))))]
                      [pack-and-sup
                       (call-with-values
                        (lambda () (select-mobile-pack (seteqv) best-b (flmin 10.0 (fl* 0.25 total-combat-sup))))
                        cons)]
                      [pack (car pack-and-sup)]
                      [min-req (if (ormap (lambda (u) (memq (rec-sym u) '(dark-templar banshee oracle))) pack)
                                   1
                                   2)])
                 (and (>= (length pack) min-req)
                      (let-values ([(px py) (centroid-of pack base-x base-y)])
                        (define-values (wx wy)
                          (compute-flank-waypoint px py (car best-b) (cdr best-b)
                                                  en-cx en-cy map-w map-h
                                                  #:clearance MULTIPRONG-FLANK-CLEARANCE
                                                  #:bfs-dist-fn bfs-dist-fn))
                        (define tags (map rec-id pack))
                        (make-proposal
                         'mp-counter-backstab
                         'multiprong-coordinator
                         'ops
                         prio
                         (lambda (chosen)
                           (fast-build-squad-actions chosen wx wy #:style 'flank))
                         #:claim (make-proposal-claim tags
                                                      #:role 'strike-group
                                                      #:lease-ttl MULTIPRONG-STRIKE-LEASE-TTL
                                                      #:allow-partial? #t
                                                      #:min-units min-req)
                         #:attention-tier 2
                         #:rationale (list 'counter-backstab best-b 'flank))))))]
         [else #f]))

     ;; --- Mode 3: Offensive Base-to-Base Army Rotation Proposal Builder ---
     (define (build-offensive-rotate-proposal [prio 510.0])
       (cond
         [(or defensive-muster-active? combat-suppress-attack? off-veto-cooled?
              (< (length enemy-base-pts) 2))
          #f]
         ;; Continue active rotation inside 224f minimum dwell window (zero oscillation!)
         ;; Loop 65D (`#1891`/`#1892`): Abort dwell early if >= 35% of mobile army is engaged <= 12t!
         [(and (multiprong-state-rotation-to-xy st)
               (< cur-frame (multiprong-state-rotation-dwell-until st)))
          (define to-pt (multiprong-state-rotation-to-xy st))
          (define engaged-mob-cnt
            (for/fold ([c 0]) ([u (in-list all-mobile-combat)])
              (if (fl<= (uvec-min-d-en u) MULTIPRONG-ENGAGE-LOCK-DIST) (add1 c) c)))
          (define dwell-engaged-abort?
            (and (pair? all-mobile-combat)
                 (fl>= (exact->inexact engaged-mob-cnt)
                       (fl* 0.35 (exact->inexact (length all-mobile-combat))))))
          (cond
            [dwell-engaged-abort?
             (set-multiprong-state-rotation-dwell-until! st -1)
             #f]
            [else
             (define rot-units
               (filter (lambda (u)
                         (define tid (rec-id u))
                         (and tid
                              (not (tag-externally-blocked? tid 'strike-group))
                              (fl> (uvec-min-d-en u) MULTIPRONG-ENGAGE-LOCK-DIST)))
                       all-mobile-combat))
             (and (>= (length rot-units) 3)
                  (make-proposal
                   'mp-offensive-rotate-dwell
                   'multiprong-coordinator
                   'ops
                   prio
                   (lambda (chosen)
                     (fast-build-squad-actions chosen (car to-pt) (cdr to-pt) #:style 'attack))
                   #:claim (make-proposal-claim (map rec-id rot-units)
                                                #:role 'strike-group
                                                #:lease-ttl MULTIPRONG-STRIKE-LEASE-TTL
                                                #:allow-partial? #t
                                                #:min-units 2)
                   #:attention-tier 2
                   #:rationale (list 'offensive-rotate to-pt (multiprong-state-rotation-from-xy st) #t)))])]
         [else
          ;; Identify Base A where an attacking mobile cluster (`>= 20` supply) is within `<= 24t`
          (define-values (base-a near-atk atk-sup atk-val)
            (for/fold ([best-b #f] [best-u '()] [best-sup 0.0] [best-val 0.0])
                      ([bpt (in-list enemy-base-pts)])
              (define bx (car bpt))
              (define by (cdr bpt))
              (define nu
                (filter (lambda (u)
                          (define dx (fl- (uvec-x u) bx))
                          (define dy (fl- (uvec-y u) by))
                          (fl<= (fl+ (fl* dx dx) (fl* dy dy)) 576.0))
                        all-mobile-combat))
              (define nsup (for/fold ([s 0.0]) ([u (in-list nu)]) (fl+ s (uvec-sup u))))
              (if (fl> nsup best-sup)
                  (values bpt nu nsup
                          (for/fold ([v 0.0]) ([u (in-list nu)]) (fl+ v (uvec-val u))))
                  (values best-b best-u best-sup best-val))))
          (and base-a
               (fl>= atk-sup 20.0)
               (let ()
                 (define-values (_ec-a en-val-a st-val-a tot-val-a) (enemy-base-defense-info base-a))
                 (define-values (atk-cx atk-cy) (centroid-of near-atk (car base-a) (cdr base-a)))
                 (define fortified-or-losing?
                   (or (fl>= st-val-a 500.0)
                       (and (fl> tot-val-a 0.0)
                            (fl< atk-val (fl* 0.90 tot-val-a)))))
                 (and fortified-or-losing?
                      (let* ([alt-bases
                              (for/list ([bpt (in-list enemy-base-pts)]
                                         #:when (and (fl>= (dist2d-fl (car base-a) (cdr base-a) (car bpt) (cdr bpt))
                                                           MULTIPRONG-BASE-MIN-SEP)
                                                     (not (pair-on-cooldown? st base-a bpt cur-frame))))
                                (define-values (ec-b _ev-b _sv-b tot-b) (enemy-base-defense-info bpt))
                                (and (or (<= ec-b 4)
                                         (fl<= tot-b (fl* 0.55 (flmax 1.0 tot-val-a))))
                                     (cons bpt tot-b)))]
                             [clean-alts (sort (filter pair? alt-bases)
                                               (lambda (a b) (fl< (cdr a) (cdr b))))])
                        (and (pair? clean-alts)
                             (let* ([engaged-front-cnt
                                     (for/fold ([c 0]) ([u (in-list near-atk)])
                                       (if (fl<= (uvec-min-d-en u) MULTIPRONG-ENGAGE-LOCK-DIST) (add1 c) c))]
                                    [rot-units
                                     (filter (lambda (u)
                                               (define tid (rec-id u))
                                               (and tid
                                                    (not (tag-externally-blocked? tid 'strike-group))
                                                    (fl> (uvec-min-d-en u) MULTIPRONG-ENGAGE-LOCK-DIST)))
                                             near-atk)]
                                    [min-free-req
                                     (max 3 (inexact->exact (ceiling (* 0.75 (length near-atk)))))]
                                    [mk-rot-prop
                                     (lambda (bpt p-id p-prio alts)
                                       (define-values (wx wy)
                                         (compute-flank-waypoint atk-cx atk-cy (car bpt) (cdr bpt)
                                                                 (car base-a) (cdr base-a) map-w map-h
                                                                 #:clearance 18.0
                                                                 #:bfs-dist-fn bfs-dist-fn))
                                       (define d-b (dist2d-fl atk-cx atk-cy (car bpt) (cdr bpt)))
                                       (define tx (if (fl> d-b 24.0) wx (car bpt)))
                                       (define ty (if (fl> d-b 24.0) wy (cdr bpt)))
                                       (make-proposal
                                        p-id
                                        'multiprong-coordinator
                                        'ops
                                        p-prio
                                        (lambda (chosen)
                                          (fast-build-squad-actions chosen tx ty #:style 'attack))
                                        #:claim (make-proposal-claim (map rec-id rot-units)
                                                                     #:role 'strike-group
                                                                     #:lease-ttl MULTIPRONG-STRIKE-LEASE-TTL
                                                                     #:allow-partial? #t
                                                                     #:min-units 2)
                                        #:alternatives alts
                                        #:attention-tier 2
                                        #:rationale (list 'offensive-rotate bpt base-a #f)))])
                               ;; Loop 65D atomic cohesion guard: zero half-army abandonment when front <= 12t engaged!
                               (and (= engaged-front-cnt 0)
                                    (>= (length rot-units) min-free-req)
                                    (let* ([b1 (car (first clean-alts))]
                                           [alt-rot2
                                            (if (>= (length clean-alts) 2)
                                                (list (mk-rot-prop (car (second clean-alts))
                                                                   'mp-offensive-rotate-alt
                                                                   (- prio 10.0)
                                                                   '()))
                                                '())]
                                           [alt-bs (build-backstab-proposal b1 (- prio 20.0))]
                                           [alts (append alt-rot2 (if alt-bs (list alt-bs) '()))])
                                      (mk-rot-prop b1 'mp-offensive-rotate prio alts)))))))))])
       )

     ;; --- Mode 4: Synchronized 2-Prong Attack Window Proposal Builder ---
     (define (build-two-prong-proposal alt-proposals)
       (cond
         [(or defensive-muster-active? combat-suppress-attack? off-veto-cooled?
              backstab-aborted-this-step?
              (< (length enemy-base-pts) 2)
              ;; Loop 65D (`#1891`/`#1892`): Require >= 36 sup & >= 1.05x visible enemy army!
              (fl< total-combat-sup 36.0)
              (and (pair? enemy-combat-recs)
                   (fl< total-combat-sup (fl* 1.05 enemy-army-sup))))
          #f]
         [else
          ;; Identify Base A where our main core (>= 50% combat supply) is closing (<= 55t)
          (define core-units
            (let ([non-raid (filter (lambda (u) (not (uvec-raid? u))) all-mobile-combat)])
              (if (pair? non-raid) non-raid all-mobile-combat)))
          (define-values (core-ax core-ay) (centroid-of core-units main-ax main-ay))
          (define base-a
            (for/fold ([best #f] [best-d 9999.0] #:result (and (fl<= best-d 55.0) best))
                      ([bpt (in-list enemy-base-pts)])
              (define d (dist2d-fl core-ax core-ay (car bpt) (cdr bpt)))
              (if (fl< d best-d) (values bpt d) (values best best-d))))
          (and base-a
               (let* ([closing-sup
                       (for/fold ([s 0.0]) ([u (in-list all-mobile-combat)])
                         (if (fl<= (dist2d-fl (uvec-x u) (uvec-y u) (car base-a) (cdr base-a)) 60.0)
                             (fl+ s (uvec-sup u))
                             s))]
                      [cand-bs
                       (if (fl>= closing-sup (fl* 0.50 total-combat-sup))
                           (for/list ([bpt (in-list enemy-base-pts)]
                                      #:when (fl>= (dist2d-fl (car base-a) (cdr base-a) (car bpt) (cdr bpt))
                                                   MULTIPRONG-BASE-MIN-SEP))
                             (define-values (_ec _ev _sv tot-v) (enemy-base-defense-info bpt))
                             (cons bpt tot-v))
                           '())]
                      [sorted-bs (sort cand-bs (lambda (a b) (fl< (cdr a) (cdr b))))])
                 (and (pair? sorted-bs)
                      (let* ([base-b (car (car sorted-bs))]
                             ;; Reserve core non-raid units closest to Base A (>= 70% supply) for main front
                             [sorted-by-a
                              (sort all-mobile-combat
                                    (lambda (u1 u2)
                                      (define r1 (uvec-raid? u1))
                                      (define r2 (uvec-raid? u2))
                                      (cond
                                        [(and (not r1) r2) #t]
                                        [(and r1 (not r2)) #f]
                                        [else
                                         (fl< (dist2d-fl (uvec-x u1) (uvec-y u1) (car base-a) (cdr base-a))
                                              (dist2d-fl (uvec-x u2) (uvec-y u2) (car base-a) (cdr base-a)))])))]
                             [main-reserve-tags
                              (let-values ([(s _sup)
                                            (for/fold ([s (seteqv)] [sup 0.0]) ([u (in-list sorted-by-a)])
                                              (if (fl>= sup (fl* 0.70 total-combat-sup))
                                                  (values s sup)
                                                  (values (set-add s (rec-id u))
                                                          (fl+ sup (uvec-sup u)))))])
                                s)])
                        (define-values (prong-b _pb-sup)
                          (select-mobile-pack main-reserve-tags base-b (flmin 10.0 (fl* 0.25 total-combat-sup))))
                        (and (>= (length prong-b) 2)
                             (let-values ([(pbx pby) (centroid-of prong-b base-x base-y)])
                               (define d-main-a (dist2d-fl core-ax core-ay (car base-a) (cdr base-a)))
                               (define d-prong-b (dist2d-fl pbx pby (car base-b) (cdr base-b)))
                               (define eta-a (fl/ d-main-a 3.5))
                               (define eta-b (fl/ d-prong-b 4.2))
                               (define hold-start (multiprong-state-sync-hold-start-frame st))
                               (define hold-elapsed
                                 (if (>= hold-start 0) (- cur-frame hold-start) 0))
                               ;; Hold secondary prong at safe flank staging if main is > 10s out
                               ;; AND secondary would arrive > 6s early (capped by 180f anti-stall!)
                               (define holding?
                                 (and (fl> eta-a 10.0)
                                      (fl< eta-b (fl- eta-a 6.0))
                                      (< hold-elapsed MULTIPRONG-SYNC-MAX-HOLD-FRAMES)))
                               (define-values (wx wy)
                                 (compute-flank-waypoint pbx pby (car base-b) (cdr base-b)
                                                         (car base-a) (cdr base-a) map-w map-h
                                                         #:clearance 18.0
                                                         #:bfs-dist-fn bfs-dist-fn))
                               (define cmd-x (if holding? wx (car base-b)))
                               (define cmd-y (if holding? wy (cdr base-b)))
                               (define style (if holding? 'flank 'attack))
                               (make-proposal
                                'mp-two-prong-sync
                                'multiprong-coordinator
                                'ops
                                525.0
                                (lambda (chosen)
                                  (fast-build-squad-actions chosen cmd-x cmd-y #:style style))
                                #:claim (make-proposal-claim (map rec-id prong-b)
                                                             #:role 'strike-group
                                                             #:lease-ttl MULTIPRONG-STRIKE-LEASE-TTL
                                                             #:allow-partial? #t
                                                             #:min-units 2)
                                #:alternatives alt-proposals
                                #:attention-tier 2
                                #:rationale (list 'two-prong-sync base-b holding?))))))))]))

     ;; --- Mode 2B (`#1845`): Protoss Empty-Warp-Prism Chargelot Backstab ---
     ;; Does NOT require standing ground units: an unclaimed empty Warp Prism +
     ;; `>= 2` ready Warp Gates + `>= 200M` + `>= 4` supply-left flies a flank to
     ;; a safe `8.5-10.5t` pocket behind an exposed enemy base, phases (`1528`),
     ;; and exposes `(cons wx wy)` so Lane B warps Chargelots into its power field!
     (define prism-aa-threat-now? #f)
     (define prism-dwell-unphase-now? #f)
     (define prism-deployed-forward-hold? #f)
     (define (build-prism-warp-backstab-proposal)
       (define rwg (if (exact-integer? ready-warp-gates) ready-warp-gates 0))
       (define min-bank (if (real? minerals) minerals 0))
       (define sup-l (if (real? supply-left) supply-left 0))
       ;; Loop 65D (`#1891`/`#1892`): Decouple proactive transit/phasing from warp-in readiness!
       ;; Warp-in target requires >= 1 WG, >= 100M, >= 2 supply-left.
       (define warp-ready? (and (>= rwg 1) (>= min-bank 100) (>= sup-l 2)))
       (define avail-prisms
         (filter (lambda (u)
                   (define tid (rec-id u))
                   (and tid (not (tag-externally-blocked? tid 'strike-group))))
                 ally-empty-prisms))
       (cond
         [(or (not (eq? race 'Protoss))
              (null? avail-prisms)
              (null? enemy-base-pts))
          #f]
         [else
          (define tracked-tid (multiprong-state-prism-tag st))
          (define chosen-prism
            (or (and tracked-tid
                     (findf (lambda (u) (eqv? (rec-id u) tracked-tid)) avail-prisms))
                (findf unit-is-warp-prism-phasing? avail-prisms)
                (car (sort avail-prisms
                           (lambda (a b)
                             (define da (for/fold ([m 9999.0]) ([bp (in-list enemy-base-pts)])
                                          (flmin m (dist2d-fl (rec-x a) (rec-y a) (car bp) (cdr bp)))))
                             (define db (for/fold ([m 9999.0]) ([bp (in-list enemy-base-pts)])
                                          (flmin m (dist2d-fl (rec-x b) (rec-y b) (car bp) (cdr bp)))))
                             (fl< da db))))))
          (define ptag (rec-id chosen-prism))
          (define px (rec-x chosen-prism base-x))
          (define py (rec-y chosen-prism base-y))
          (define phasing-now? (unit-is-warp-prism-phasing? chosen-prism))
          (define-values (naa-x naa-y d-aa) (nearest-xy-vec px py enemy-aa-xy-vecs enemy-x enemy-y))
          (define-values (nen-x nen-y d-en) (nearest-xy-vec px py enemy-xy-vecs enemy-x enemy-y))
          (define nearest-en-base-d
            (for/fold ([m 9999.0]) ([bp (in-list enemy-base-pts)])
              (flmin m (dist2d-fl px py (car bp) (cdr bp)))))
          (define prism-active-on-mission?
            (or (eqv? ptag tracked-tid)
                phasing-now?
                (fl<= nearest-en-base-d 24.0)))
          (define prism-ehp-ratio
            (let* ([hp (let ([v (and (hash? chosen-prism)
                                     (hash-ref chosen-prism 'hp (lambda () (hash-ref chosen-prism 'health #f))))])
                         (if (real? v) (exact->inexact v) 80.0))]
                   [sh (let ([v (and (hash? chosen-prism)
                                     (hash-ref chosen-prism 'shield (lambda () (hash-ref chosen-prism 'shields #f))))])
                         (if (real? v) (exact->inexact v) 100.0))]
                   [mhp (let ([v (and (hash? chosen-prism)
                                      (hash-ref chosen-prism 'max-hp (lambda () (hash-ref chosen-prism 'max-health #f))))])
                          (if (and (real? v) (> v 0)) (exact->inexact v) 80.0))]
                   [msh (let ([v (and (hash? chosen-prism)
                                      (hash-ref chosen-prism 'max-shield (lambda () (hash-ref chosen-prism 'max-shields #f))))])
                          (if (and (real? v) (>= v 0)) (exact->inexact v) 100.0))])
              (fl/ (fl+ hp sh) (flmax 1.0 (fl+ mhp msh)))))
          (define prism-retreat-dist
            (if (fl< prism-ehp-ratio 0.70) 10.0 MULTIPRONG-PRISM-RETREAT-DIST))
          (define immediate-threat?
            (and prism-active-on-mission?
                 (or (fl<= d-aa prism-retreat-dist)
                     (and phasing-now? (fl<= d-en prism-retreat-dist)))))
          (define close-aa-threat?
            (and prism-active-on-mission?
                 (fl<= d-aa MULTIPRONG-PRISM-SAFE-PHASE-AA-DIST)))
          (when (or immediate-threat? close-aa-threat?)
            (set! prism-aa-threat-now? #t))
          (define threat-x (if (fl<= d-aa d-en) naa-x nen-x))
          (define threat-y (if (fl<= d-aa d-en) naa-y nen-y))
          (define-values (esc-x esc-y)
            (compute-prism-escape-point px py threat-x threat-y base-x base-y map-w map-h))
          (define retreat-action
            (if phasing-now?
                (list (list 'cast-spell ptag 'morph-warp-prism-transport ptag))
                (list (list 'move ptag esc-x esc-y))))
          (define retreat-prop
            (make-proposal
             'mp-prism-warp-retreat
             'multiprong-coordinator
             'ops
             560.0
             (lambda (chosen)
               (if (memv ptag chosen) retreat-action '()))
             #:claim (make-proposal-claim (list ptag)
                                          #:role 'strike-group
                                          #:lease-ttl MULTIPRONG-STRIKE-LEASE-TTL
                                          #:allow-partial? #f
                                          #:min-units 1)
             #:attention-tier 1
             #:rationale (list 'prism-warp-retreat ptag #f)))
          (define prev-b-st (multiprong-state-prism-target-base st))
          (define prev-pkt-st (multiprong-state-prism-pocket st))
          (define morph-allowed?
            (>= (- cur-frame (multiprong-state-prism-last-morph-frame st))
                MULTIPRONG-PRISM-MORPH-REFRACTORY-FRAMES))
          ;; Loop 65C/65H (`#1874`/`#1948`): Keep an already-phased Warp Prism at an enemy pocket
          ;; (`7.5..16.5t` ring) PHASED across `< 200M` / Warp Gate cooldown dips (ONLY unphase on
          ;; AA threat or >448f dwell!).
          (define phasing-at-enemy-pocket?
            (and phasing-now?
                 (not immediate-threat?)
                 (not close-aa-threat?)
                 (or (and prev-pkt-st
                          (fl<= (dist2d-fl px py (car prev-pkt-st) (cdr prev-pkt-st))
                                (fl+ MULTIPRONG-PRISM-POCKET-ARRIVE-DIST 1.5)))
                     (and prev-b-st
                          (let ([db (dist2d-fl px py (car prev-b-st) (cdr prev-b-st))])
                            (and (fl>= db 7.5) (fl<= db 16.5))))
                     (and (fl>= nearest-en-base-d 7.5)
                          (fl<= nearest-en-base-d 16.5)))))
          (define d-home
            (dist2d-fl px py (exact->inexact base-x) (exact->inexact base-y)))
          (define deployed-forward?
            (or phasing-at-enemy-pocket?
                (and prism-active-on-mission? (fl> d-home 45.0))))
          (define phased-since (multiprong-state-prism-phased-since-frame st))
          (define phase-dwell-elapsed
            (if (>= phased-since 0) (- cur-frame phased-since) 0))
          (define dwell-expired?
            (> phase-dwell-elapsed MULTIPRONG-PRISM-MAX-PHASE-DWELL-FRAMES))
          (define (make-hold-phased-prop [warp-tgt #f])
            (make-proposal
             'mp-prism-warp-backstab
             'multiprong-coordinator
             'ops
             505.0
             (lambda (_chosen) '())
             #:claim (make-proposal-claim (list ptag)
                                          #:role 'strike-group
                                          #:lease-ttl MULTIPRONG-STRIKE-LEASE-TTL
                                          #:allow-partial? #f
                                          #:min-units 1)
             #:alternatives (list retreat-prop)
             #:attention-tier 2
             #:rationale (list 'prism-warp-backstab ptag
                               (or prev-b-st (car enemy-base-pts))
                               (or prev-pkt-st (cons px py))
                               warp-tgt (if phasing-now? 'phased 'hold))))
          (define transit-ready?
            (or (>= rwg 2)
                charge-researched?
                prism-active-on-mission?))
          (cond
            [immediate-threat?
             retreat-prop]
            ;; Dwell expiration (> 448f) when unable to warp -> unphase cleanly (subject to 112f refractory)
            [(and phasing-at-enemy-pocket? dwell-expired? (not warp-ready?))
             (cond
               [close-aa-threat? retreat-prop]
               [morph-allowed?
                (set! prism-dwell-unphase-now? #t)
                retreat-prop]
               [else
                (set! prism-deployed-forward-hold? #t)
                (make-hold-phased-prop #f)])]
            [(not transit-ready?)
             (cond
               [close-aa-threat? retreat-prop]
               [phasing-at-enemy-pocket?
                (set! prism-deployed-forward-hold? #t)
                (make-hold-phased-prop #f)]
               [else #f])]
            ;; Loop 65H (`#1948`): During home defense (`defensive-muster-active?`/`home-defense-deficit?`/
            ;; `major-home-push?`/`mode1-proposal`), NEVER drop the `'strike-group` lease of an already
            ;; deployed forward Prism (`phasing-at-enemy-pocket?` OR active mission `> 45.0t` from home)!
            [(or defensive-muster-active?
                 home-defense-deficit?
                 major-home-push?
                 (and ground-eligible? mode1-proposal #t))
             (cond
               [close-aa-threat? retreat-prop]
               [deployed-forward?
                (set! prism-deployed-forward-hold? #t)
                (make-hold-phased-prop (and phasing-at-enemy-pocket? warp-ready? (cons px py)))]
               [else #f])]
            [else
             ;; Determine exposed enemy bases (`>= 30t` from enemy army centroid, OR
             ;; distinct from main-army engagement base `>= 25t` during a 2-prong window,
             ;; OR any enemy base when enemy army is unseen in FoW).
             (define main-engaged-base
               (and (fl>= total-combat-sup 12.0)
                    (for/fold ([best #f] [best-d 55.0] #:result best) ([bp (in-list enemy-base-pts)])
                      (define d (dist2d-fl main-ax main-ay (car bp) (cdr bp)))
                      (if (fl< d best-d) (values bp d) (values best best-d)))))
             (define (base-exposed? bp)
               (or (null? enemy-xy-vecs)
                   (fl>= (dist2d-fl en-cx en-cy (car bp) (cdr bp)) MULTIPRONG-BACKSTAB-ENEMY-DIST)
                   (and main-engaged-base
                        (fl>= (dist2d-fl (car main-engaged-base) (cdr main-engaged-base)
                                         (car bp) (cdr bp))
                              MULTIPRONG-BASE-MIN-SEP))))
             (define prev-b prev-b-st)
             (define prev-b-still-valid
               (and prev-b
                    (findf (lambda (bp)
                             (and (fl<= (dist2d-fl (car bp) (cdr bp) (car prev-b) (cdr prev-b)) 6.0)
                                  (base-exposed? bp)))
                           enemy-base-pts)))
             (define candidate-bases
               (for/list ([bp (in-list enemy-base-pts)]
                          #:when (base-exposed? bp))
                 (define pkt
                   (compute-prism-warp-pocket (car bp) (cdr bp) en-cx en-cy
                                              enemy-aa-xy-vecs enemy-xy-vecs map-w map-h))
                 (and pkt
                      (let-values ([(_ec _ev _sv tot-v) (enemy-base-defense-info bp)])
                        (vector bp pkt tot-v (dist2d-fl px py (car pkt) (cdr pkt)))))))
             (define valid-cands (filter vector? candidate-bases))
             (define chosen-cand
               (or (and prev-b-still-valid
                        (findf (lambda (v)
                                 (fl<= (dist2d-fl (car (vector-ref v 0)) (cdr (vector-ref v 0))
                                                  (car prev-b-still-valid) (cdr prev-b-still-valid))
                                       6.0))
                               valid-cands))
                   (and (pair? valid-cands)
                        (car (sort valid-cands
                                   (lambda (a b)
                                     ;; Balance local defense value + flight distance (`4.0/tile`) so a Prism
                                     ;; already at a lightly-guarded pocket (e.g. 1 Marine 10.5t away) phases
                                     ;; immediately instead of flying 50t away to another base!
                                     (fl< (fl+ (vector-ref a 2) (fl* 4.0 (vector-ref a 3)))
                                          (fl+ (vector-ref b 2) (fl* 4.0 (vector-ref b 3))))))))))
             (or (and chosen-cand
                      (let* ([target-b (vector-ref chosen-cand 0)]
                             [pocket (vector-ref chosen-cand 1)]
                             [wx (car pocket)]
                             [wy (cdr pocket)]
                             [d-pocket (dist2d-fl px py wx wy)]
                             [d-base (dist2d-fl px py (car target-b) (cdr target-b))]
                             ;; Loop 65E/65H (`#1907`/`#1948`): Phase immediately once `<= 5.0t` of pocket OR
                             ;; already at any safe `7.5..16.0t` ring around target base with `d-aa > 9.5t`!
                             [at-pocket? (or (fl<= d-pocket MULTIPRONG-PRISM-POCKET-ARRIVE-DIST)
                                             (and (fl>= d-base 7.5)
                                                  (fl<= d-base 16.0)
                                                  (fl> d-aa MULTIPRONG-PRISM-SAFE-PHASE-AA-DIST)))]
                             [preferred? (or charge-researched? (>= rwg 4) (>= min-bank 400))]
                             [prop-prio (if preferred? 560.0 505.0)]
                             [phasing-or-morphing-now? (and at-pocket? (or phasing-now? morph-allowed?))]
                             ;; Loop 65D: Expose `warp-target` ONLY when phased/morphing AND `warp-ready?`!
                             [warp-target (and phasing-or-morphing-now? warp-ready? (cons px py))]
                             [act-list
                              (cond
                                [at-pocket?
                                 (cond
                                   [phasing-now? '()]
                                   [morph-allowed?
                                    (list (list 'cast-spell ptag 'morph-warp-prism-phasing ptag))]
                                   [else '()])]
                                [phasing-now?
                                 (if morph-allowed?
                                     (list (list 'cast-spell ptag 'morph-warp-prism-transport ptag))
                                     '())]
                                ;; Loop 65E/65H (`#1907`/`#1948`): Detour around close AA `<= 10.5t` en-route;
                                ;; only call `compute-flank-waypoint` when `d-pocket > 22.0` AND direct segment
                                ;; `(px,py)->(wx,wy)` passes `<= 16.0t` of `(en-cx,en-cy)` (or `d-aa <= 16.0`),
                                ;; with dynamic clearance `min(22.0, 0.55 * d-pocket)`; otherwise fly straight!
                                [(fl<= d-aa 10.5)
                                 (define-values (det-x det-y)
                                   (compute-prism-escape-point px py naa-x naa-y base-x base-y map-w map-h))
                                 (list (list 'move ptag det-x det-y))]
                                [(and (fl> d-pocket 22.0)
                                      (or (fl<= (point-to-segment-dist-fl en-cx en-cy px py wx wy) 16.0)
                                          (fl<= d-aa 16.0)))
                                 (define-values (fx fy)
                                   (compute-flank-waypoint px py wx wy en-cx en-cy map-w map-h
                                                           #:clearance (flmin 22.0 (fl* 0.55 d-pocket))))
                                 (list (list 'move ptag fx fy))]
                                [else
                                 (list (list 'move ptag wx wy))])])
                        (make-proposal
                         'mp-prism-warp-backstab
                         'multiprong-coordinator
                         'ops
                         prop-prio
                         (lambda (chosen)
                           (if (memv ptag chosen) act-list '()))
                         #:claim (make-proposal-claim (list ptag)
                                                      #:role 'strike-group
                                                      #:lease-ttl MULTIPRONG-STRIKE-LEASE-TTL
                                                      #:allow-partial? #f
                                                      #:min-units 1)
                         #:alternatives (list retreat-prop)
                         #:attention-tier 2
                         #:rationale (list 'prism-warp-backstab ptag target-b pocket warp-target
                                           (if phasing-or-morphing-now? 'phased 'flank)))))
                 (and close-aa-threat? retreat-prop)
                 (and phasing-at-enemy-pocket? (not dwell-expired?)
                      (make-hold-phased-prop (and warp-ready? (cons px py)))))])]))

     ;; =========================================================================
     ;; Assemble Proposals & Resolve Atomically via `arbiter-resolve!`
     ;; =========================================================================
     ;; Loop 65E: During `endgame-hunt-active?` (`(not ground-eligible?)`), skip ground
     ;; Modes 1-4 and run ONLY Mode 2B (`prism-warp-backstab`)!
     (define rot-prop (and ground-eligible? (build-offensive-rotate-proposal 510.0)))
     (define bs-prop (and ground-eligible? (build-backstab-proposal #f 495.0)))
     (define two-prong-alts
       (append (if rot-prop (list rot-prop) '())
               (if bs-prop (list bs-prop) '())))
     (define two-prong-prop (and ground-eligible? (build-two-prong-proposal two-prong-alts)))
     (define prism-prop (build-prism-warp-backstab-proposal))

     ;; Primary offensive candidate hierarchy (active rotation dwell or continuing backstab
     ;; stays locked until completion/abort; otherwise Mode 3 fortified rotation > Mode 4 2-prong
     ;; cascading -> Mode 3 -> Mode 2 cleanly via arbiter `alternatives`!)
     (define offensive-prop
       (cond
         [(not ground-eligible?) #f]
         [(and rot-prop
               (or (eq? (proposal-id rot-prop) 'mp-offensive-rotate-dwell)
                   (eq? (proposal-id rot-prop) 'mp-offensive-rotate)))
          rot-prop]
         [(and backstab-continuing-before? bs-prop) bs-prop]
         [backstab-aborted-this-step? #f]
         [two-prong-prop two-prong-prop]
         [bs-prop bs-prop]
         [else #f]))

     (define submitted-proposals
       (append (if (and ground-eligible? mode1-proposal) (list mode1-proposal) '())
               (if prism-prop (list prism-prop) '())
               (if offensive-prop (list offensive-prop) '())))

     ;; Threat-veto callback enforced by `arbiter-resolve!` (logs structured `'threat-veto`
     ;; into `active-ledger` when home defense preempts offensive pushes, or enemy AA closes
     ;; within <= 14t of a backstab Warp Prism -> cascades into `mp-prism-warp-retreat`!)
     (define (mp-threat-veto-fn p)
       (define pid (proposal-id p))
       (define is-def? (memq pid '(mp-defensive-full-rotate mp-defensive-split)))
       (cond
         [is-def? #f]
         [(eq? pid 'mp-prism-warp-retreat)
          ;; Allow Prism retreat ONLY when under AA/defender threat OR >448f dwell unphase
          ;; (never fire retreat fallback when home defense simply vetoes launching a safe Prism!)
          (if (or prism-aa-threat-now? prism-dwell-unphase-now?)
              #f
              (list 'prism-safe-no-retreat 'home-defense 900.0 (hasheq 'reason 'prism-safe)))]
         [(and (eq? pid 'mp-prism-warp-backstab) prism-aa-threat-now?)
          (list 'prism-aa-threat-veto
                'home-defense
                890.0
                (hasheq 'reason 'prism-aa-close))]
         [(and (eq? pid 'mp-prism-warp-backstab) prism-deployed-forward-hold?)
          #f]
         [(or major-home-push? defensive-muster-active? (and ground-eligible? mode1-proposal #t))
          (list 'home-defense-threat-veto
                'home-defense
                900.0
                (hasheq 'reason (cond [major-home-push? 'major-home-push]
                                      [defensive-muster-active? 'defensive-muster]
                                      [else 'home-defense-split-active])))]
         [(and home-defense-deficit?
               (memq pid '(mp-counter-backstab mp-two-prong-sync mp-prism-warp-backstab)))
          (list 'home-defense-deficit-veto
                'home-defense
                880.0
                (hasheq 'reason 'home-defense-deficit))]
         [else #f]))

     (define budget-snap (make-arbiter-budget-snapshot))
     (define ares
       (arbiter-resolve! active-ledger
                         cur-frame
                         budget-snap
                         submitted-proposals
                         #:threat-veto-fn mp-threat-veto-fn
                         #:max-alt-depth 3))

     (define accepted (arbiter-result-accepted-proposals ares))
     (define out-actions (arbiter-result-approved-actions ares))
     (define arbiter-claimed (arbiter-result-claimed-tags ares))

     ;; Update Prism state & stamp `112f` per-Prism morph refractory / `448f` dwell clock
     (define emitted-prism-phase?
       (ormap (lambda (a)
                (and (list? a) (>= (length a) 3)
                     (eq? (first a) 'cast-spell)
                     (eq? (third a) 'morph-warp-prism-phasing)))
              out-actions))
     (define emitted-prism-unphase?
       (ormap (lambda (a)
                (and (list? a) (>= (length a) 3)
                     (eq? (first a) 'cast-spell)
                     (eq? (third a) 'morph-warp-prism-transport)))
              out-actions))
     (when emitted-prism-phase?
       (set-multiprong-state-prism-last-morph-frame! st cur-frame)
       (set-multiprong-state-prism-phased-since-frame! st cur-frame))
     (when emitted-prism-unphase?
       (set-multiprong-state-prism-last-morph-frame! st cur-frame)
       (set-multiprong-state-prism-phased-since-frame! st -1))
     (define acc-prism-bs
       (findf (lambda (p) (eq? (proposal-id p) 'mp-prism-warp-backstab)) accepted))
     (define acc-prism-ret
       (findf (lambda (p) (eq? (proposal-id p) 'mp-prism-warp-retreat)) accepted))
     (cond
       [acc-prism-bs
        (define rat (proposal-rationale acc-prism-bs))
        (define ptag (and (list? rat) (>= (length rat) 2) (second rat)))
        (define tb (and (list? rat) (>= (length rat) 3) (third rat)))
        (define pkt (and (list? rat) (>= (length rat) 4) (fourth rat)))
        (define ph (and (list? rat) (>= (length rat) 6) (sixth rat)))
        (unless (eqv? ptag (multiprong-state-prism-tag st))
          (set-multiprong-state-prism-start-frame! st cur-frame))
        (when (and (eq? ph 'phased) (< (multiprong-state-prism-phased-since-frame st) 0))
          (set-multiprong-state-prism-phased-since-frame! st cur-frame))
        (set-multiprong-state-prism-tag! st ptag)
        (set-multiprong-state-prism-target-base! st tb)
        (set-multiprong-state-prism-pocket! st pkt)]
       [acc-prism-ret
        (define rat (proposal-rationale acc-prism-ret))
        (define ptag (and (list? rat) (>= (length rat) 2) (second rat)))
        (set-multiprong-state-prism-tag! st ptag)
        (set-multiprong-state-prism-pocket! st #f)
        (set-multiprong-state-prism-retreat-until!
         st (+ cur-frame MULTIPRONG-PRISM-RETREAT-COOLDOWN-FRAMES))]
       [else
        (when (and (multiprong-state-prism-tag st)
                   (not (ormap (lambda (u) (eqv? (rec-id u) (multiprong-state-prism-tag st)))
                               ally-empty-prisms)))
          (set-multiprong-state-prism-tag! st #f)
          (set-multiprong-state-prism-target-base! st #f)
          (set-multiprong-state-prism-pocket! st #f)
          (set-multiprong-state-prism-phased-since-frame! st -1))])

     ;; Determine primary mode, target & update stateful hysteresis trackers
     ;; If a phased Warp Prism backstab is ready for warp-ins AND no home-defense mode fired,
     ;; surface `'prism-warp-backstab` + `(cons wx wy)` so Lane B warps Chargelots immediately!
     (define top-acc
       (let ([def-acc (findf (lambda (p)
                               (memq (proposal-id p) '(mp-defensive-full-rotate mp-defensive-split)))
                             accepted)]
             [ready-prism-acc
              (and acc-prism-bs
                   (let ([rat (proposal-rationale acc-prism-bs)])
                     (and (list? rat) (>= (length rat) 5) (fifth rat)))
                   acc-prism-bs)])
         (or def-acc
             ready-prism-acc
             (and (pair? accepted) (car accepted)))))
     (define-values (final-mode final-target lease-role lease-ttl)
       (cond
         [(not top-acc)
          (set-multiprong-state-sync-hold-start-frame! st -1)
          (values 'inactive #f 'strike-group 0)]
         [else
          (define rat (proposal-rationale top-acc))
          (define pid (proposal-id top-acc))
          (cond
            [(eq? pid 'mp-defensive-full-rotate)
             (define tgt (and (pair? rat) (cdr rat)))
             (set-multiprong-state-sync-hold-start-frame! st -1)
             (values 'defensive-full-rotate tgt 'home-defense MULTIPRONG-DEF-LEASE-TTL)]
            [(eq? pid 'mp-defensive-split)
             (define tgt (and (pair? rat) (cdr rat)))
             (values 'defensive-split tgt 'home-defense MULTIPRONG-DEF-LEASE-TTL)]
            [(eq? pid 'mp-prism-warp-backstab)
             (define warp-tgt (and (list? rat) (>= (length rat) 5) (fifth rat)))
             (values 'prism-warp-backstab warp-tgt 'strike-group MULTIPRONG-STRIKE-LEASE-TTL)]
            [(eq? pid 'mp-prism-warp-retreat)
             (values 'prism-warp-backstab #f 'strike-group MULTIPRONG-STRIKE-LEASE-TTL)]
            [(memq pid '(mp-offensive-rotate mp-offensive-rotate-alt mp-offensive-rotate-dwell))
             (define to-pt (and (list? rat) (>= (length rat) 2) (second rat)))
             (define from-pt (and (list? rat) (>= (length rat) 3) (third rat)))
             (define is-dwell? (and (list? rat) (>= (length rat) 4) (fourth rat)))
             (unless is-dwell?
               (set-multiprong-state-last-rotation-frame! st cur-frame)
               (set-multiprong-state-rotation-from-xy! st from-pt)
               (set-multiprong-state-rotation-to-xy! st to-pt)
               (set-multiprong-state-rotation-dwell-until!
                st (+ cur-frame MULTIPRONG-ROTATE-DWELL-FRAMES))
               (when (and from-pt to-pt)
                 (record-pair-cooldown! st from-pt to-pt cur-frame)))
             (values 'offensive-rotate to-pt 'strike-group MULTIPRONG-STRIKE-LEASE-TTL)]
            [(eq? pid 'mp-two-prong-sync)
             (define bpt (and (list? rat) (>= (length rat) 2) (second rat)))
             (define holding? (and (list? rat) (>= (length rat) 3) (third rat)))
             (if holding?
                 (when (< (multiprong-state-sync-hold-start-frame st) 0)
                   (set-multiprong-state-sync-hold-start-frame! st cur-frame))
                 (set-multiprong-state-sync-hold-start-frame! st -1))
             (set-multiprong-state-sync-target-b! st bpt)
             (values 'two-prong-sync bpt 'strike-group MULTIPRONG-STRIKE-LEASE-TTL)]
            [(eq? pid 'mp-counter-backstab)
             (define bpt (and (list? rat) (>= (length rat) 2) (second rat)))
             (define ph (and (list? rat) (>= (length rat) 3) (third rat)))
             (define ground-claimed
               (for/seteqv ([tid (in-set arbiter-claimed)]
                            #:when (hash-has-key? unit-by-tag tid))
                 tid))
             (when (set-empty? (multiprong-state-backstab-tags st))
               (set-multiprong-state-backstab-start-frame! st cur-frame))
             (set-multiprong-state-backstab-tags! st ground-claimed)
             (set-multiprong-state-backstab-target! st bpt)
             (set-multiprong-state-backstab-phase! st (or ph 'flank))
             (values 'counter-backstab bpt 'strike-group MULTIPRONG-STRIKE-LEASE-TTL)]
            [else
             (values 'inactive #f 'strike-group 0)])]))

     (unless (eq? final-mode (multiprong-state-active-mode st))
       (set-multiprong-state-active-mode! st final-mode)
       (set-multiprong-state-mode-entered-frame! st cur-frame))
     (set-multiprong-state-active-target! st final-target)

     ;; Mirror arbiter-approved leases into caller's `role-leases` hash when distinct
     ;; Loop 65D/65H (`#1891`/`#1948`): Skip mirroring `'strike-group` when `combat-suppress-attack?`
     ;; is #t, EXCEPT for an already-deployed forward Warp Prism hold/retreat so its lease is NEVER dropped!
     (when (and (hash? role-leases)
                (not (eq? role-leases ledger-leases))
                (pair? accepted))
       (define tx (if (pair? final-target) (car final-target) enemy-x))
       (define ty (if (pair? final-target) (cdr final-target) enemy-y))
       (for ([p (in-list accepted)])
         (define cl (proposal-claim-spec p))
         (define pid (proposal-id p))
         (define p-role (if (proposal-claim? cl) (proposal-claim-role cl) lease-role))
         (define p-ttl (if (proposal-claim? cl) (proposal-claim-lease-ttl cl) lease-ttl))
         (define p-tags (if (proposal-claim? cl) (proposal-claim-unit-tags cl) '()))
         (when (and (> p-ttl 0)
                    (or (not combat-suppress-attack?)
                        (not (eq? p-role 'strike-group))
                        (eq? pid 'mp-prism-warp-retreat)
                        (and (eq? pid 'mp-prism-warp-backstab)
                             prism-deployed-forward-hold?)))
           (for ([tid (in-list p-tags)]
                 #:when (set-member? arbiter-claimed tid))
             (acquire-unit-lease! role-leases tid p-role cur-frame p-ttl
                                  #:target-id final-mode #:x tx #:y ty)))))

     (multiprong-result
      out-actions
      submitted-proposals
      arbiter-claimed
      final-mode
      final-target)]))
