#lang racket/base

;; =============================================================================
;; `lib/tactics/concave-positioning.rkt`
;; Generalizable Combat Concave, Front-to-Back Layering, Caster Rear Leash,
;; Zerg Two-Wing Surround & Uphill-Siege Ramp Brake
;;
;; All calculations are pure, lightweight (`O(N log N)` flonum math, `< 0.2ms/step`),
;; race-general, and map-symmetry-agnostic. Units already inside immediate weapon
;; firing range (`<= weapon-range + 1.0t`) are NEVER pulled off DPS.
;; =============================================================================

(require racket/flonum
         racket/list
         racket/math
         (only-in "../sc2-game-constants.rkt"
                  sc2-canonical-unit-sym
                  sc2-supply-cost))

(provide
 (struct-out combat-pos-ctx)
 build-combat-positioning-context
 compute-front-to-back-advance-pt
 compute-caster-rear-leash-pt
 compute-zerg-surround-wing-pt
 zerg-uphill-ramp-hold-pt
 compute-lateral-concave-spread-pt
 compute-blind-uphill-retreat-pt
 plan-high-ground-vision-actions)

;; =============================================================================
;; Classification Tables
;; =============================================================================

(define PROTOSS-FRONT-SYMS '(zealot archon))
(define PROTOSS-MID-SYMS   '(stalker adept))
(define PROTOSS-HEAVY-BACK-SYMS '(immortal colossus sentry high-templar))

(define TERRAN-FRONT-SYMS  '(marauder hellbat))
(define TERRAN-MID-SYMS    '(marine))
(define TERRAN-BIO-SYMS    '(marine marauder hellbat ghost reaper))
(define TERRAN-CASTER-SYMS '(medivac raven ghost))

(define ZERG-FRONT-SYMS    '(zergling baneling roach ultralisk))
;; L58-HOLD Bug #3a fix: restrict Zerg two-wing surround strictly to fast melee `'zergling`
;; (never pull ranged `roach`/`ravager`/`hydralisk` or `baneling` laterally into choke walls!)
(define ZERG-SURROUND-SYMS '(zergling))
(define ZERG-MID-SYMS      '(hydralisk ravager))
(define ZERG-GROUND-HOLD-SYMS '(zergling baneling roach hydralisk ultralisk))
(define ZERG-UPHILL-BREAKER-SYMS '(ravager viper brood-lord broodlord mutalisk corruptor swarm-host swarm-host-mp))

(define RANGED-CONCAVE-SYMS
  '(marine marauder ghost stalker adept immortal colossus sentry
    hydralisk roach ravager))

(define ENEMY-SPLASH-SYMS
  '(siege-tank-sieged baneling colossus high-templar
    disruptor disruptor-phased
    lurker-burrowed lurker-mp-burrowed
    widow-mine-burrowed archon))

(define ENEMY-UPHILL-SIEGE-SYMS
  '(siege-tank-sieged lurker-burrowed lurker-mp-burrowed))

(define NON-COMBAT-IGNORE-SYMS
  '(larva egg changeling overlord overlord-cocoon observer observer-siege-mode
    overseer overseer-siege-mode creep-tumor creep-tumor-burrowed))

;; =============================================================================
;; Context Structure
;; =============================================================================

(struct combat-pos-ctx
  (enemy-cnt
   enemy-cx
   enemy-cy
   fwd-ux          ;; unit vector from ally-army -> enemy centroid
   fwd-uy
   perp-ux         ;; unit perpendicular (-fwd-uy, fwd-ux)
   perp-uy
   ;; Frontline centroids per race family
   p-front-cnt p-front-cx p-front-cy p-front-proj
   t-front-cnt t-front-cx t-front-cy t-front-proj
   z-front-cnt z-front-cx z-front-cy z-front-proj
   ;; Terran Bio centroid & enemy-facing axis for caster rear leash
   t-bio-cnt t-bio-cx t-bio-cy
   ;; Splash, air & entrenched uphill siege records
   enemy-air-pts          ;; list of (cons ex ey) flying combat enemies
   enemy-splash-pts       ;; list of (cons ex ey)
   enemy-uphill-siege     ;; list of (vector ex ey ez sym)
   ally-has-uphill-breaker?
   ally-strength-ratio
   ;; Precomputed deterministic lateral slots (uid -> (cons idx total))
   ranged-slot-ht
   zerg-surround-slot-ht
   ;; Map bounds
   map-w
   map-h)
  #:transparent)

;; =============================================================================
;; Fast Math & Record Helpers
;; =============================================================================

(define (fl->safe v fallback)
  (if (and (real? v) (not (nan? v)) (not (infinite? v)))
      (exact->inexact v)
      (exact->inexact fallback)))

(define (dist2d-fl x1 y1 x2 y2)
  (let ([dx (fl- x1 x2)]
        [dy (fl- y1 y2)])
    (flsqrt (fl+ (fl* dx dx) (fl* dy dy)))))

(define (clamp-fl v lo hi)
  (flmax lo (flmin hi v)))

(define (rec-id u)
  (if (hash? u)
      (let ([v (hash-ref u 'id -1)])
        (if (exact-integer? v) v -1))
      -1))

(define (rec-raw-sym u)
  (cond
    [(hash? u)
     (define raw (hash-ref u 'type 'unknown))
     (cond
       [(symbol? raw) raw]
       [(string? raw) (string->symbol (string-downcase raw))]
       [else 'unknown])]
    [(symbol? u) u]
    [else 'unknown]))

(define (rec-canon-sym u)
  (sc2-canonical-unit-sym (rec-raw-sym u)))

(define (rec-xy? u)
  (and (hash? u)
       (real? (hash-ref u 'x #f))
       (real? (hash-ref u 'y #f))))

(define (rec-snapshot? u)
  (and (hash? u)
       (or (eq? (hash-ref u 'snapshot? #f) #t)
           (not (eqv? (hash-ref u 'display-type 1) 1)))))

(define (rec-x u fallback)
  (if (hash? u) (fl->safe (hash-ref u 'x fallback) fallback) (exact->inexact fallback)))

(define (rec-y u fallback)
  (if (hash? u) (fl->safe (hash-ref u 'y fallback) fallback) (exact->inexact fallback)))

(define (rec-z u)
  (if (hash? u)
      (let ([z (hash-ref u 'z (hash-ref u 'pos-z #f))])
        (if (and (real? z) (not (nan? z)) (not (infinite? z)))
            (exact->inexact z)
            #f))
      #f))

(define (rec-supply-weight u)
  (define sym (rec-canon-sym u))
  (cond
    [(memq sym NON-COMBAT-IGNORE-SYMS) 0.0]
    [(memq sym '(scv probe drone mule)) 0.3]
    [else (exact->inexact (max 1 (sc2-supply-cost sym 1)))]))

(define (build-lateral-slot-table items ecx ecy perp-ux perp-uy)
  (define ht (make-hasheqv))
  (define n (length items))
  (when (> n 0)
    (define scored
      (sort
       (for/list ([u (in-list items)])
         (define uid (rec-id u))
         (define ux (rec-x u ecx))
         (define uy (rec-y u ecy))
         (define lat (fl+ (fl* (fl- ux ecx) perp-ux)
                          (fl* (fl- uy ecy) perp-uy)))
         (cons uid lat))
       (lambda (a b)
         (or (fl< (cdr a) (cdr b))
             (and (fl= (cdr a) (cdr b)) (< (car a) (car b)))))))
    (for ([p (in-list scored)]
          [i (in-naturals)])
      (hash-set! ht (car p) (cons i n))))
  ht)

;; =============================================================================
;; Context Builder (`O(N log N)` once per step)
;; =============================================================================

(define (build-combat-positioning-context
         combat-units
         enemy-units
         #:map-width [map-w 200.0]
         #:map-height [map-h 200.0]
         #:enemy-fallback-x [efx 100.0]
         #:enemy-fallback-y [efy 100.0])
  (define mw (flmax 64.0 (fl->safe map-w 200.0)))
  (define mh (flmax 64.0 (fl->safe map-h 200.0)))

  ;; 1. Scan enemies once
  (define-values (ecnt esx esy e-str air-pts splash-pts uphill-siege)
    (for/fold ([c 0] [sx 0.0] [sy 0.0] [estr 0.0] [apts '()] [spts '()] [usge '()])
              ([e (in-list (or enemy-units '()))]
               #:when (and (rec-xy? e) (not (rec-snapshot? e))))
      (define raw (rec-raw-sym e))
      (define canon (sc2-canonical-unit-sym raw))
      (cond
        [(memq canon NON-COMBAT-IGNORE-SYMS)
         (values c sx sy estr apts spts usge)]
        [else
         (define ex (rec-x e efx))
         (define ey (rec-y e efy))
         (define ez (rec-z e))
         (define is-air?
           (or (eq? (hash-ref e 'flying? #f) #t)
               (eq? (hash-ref e 'flying #f) #t)
               (eq? (hash-ref e 'is-flying #f) #t)
               (and (memq canon '(mutalisk corruptor brood-lord broodlord viper phoenix void-ray
                                  oracle carrier tempest mothership viking-fighter medivac
                                  banshee raven battlecruiser liberator))
                    #t)))
         (define is-splash?
           (or (memq raw ENEMY-SPLASH-SYMS)
               (memq canon '(baneling colossus high-templar disruptor archon))))
         (define is-uphill-siege?
           (and ez
                (or (memq raw ENEMY-UPHILL-SIEGE-SYMS)
                    (and (eq? canon 'siege-tank) (eq? (hash-ref e 'sieged #f) #t))
                    (and (eq? canon 'lurker) (eq? (hash-ref e 'burrowed #f) #t)))))
         (values (add1 c)
                 (fl+ sx ex)
                 (fl+ sy ey)
                 (fl+ estr (rec-supply-weight e))
                 (if is-air? (cons (cons ex ey) apts) apts)
                 (if is-splash? (cons (cons ex ey) spts) spts)
                 (if is-uphill-siege? (cons (vector ex ey ez raw) usge) usge))])))

  (define ecx (if (> ecnt 0) (fl/ esx (exact->inexact ecnt)) (fl->safe efx 100.0)))
  (define ecy (if (> ecnt 0) (fl/ esy (exact->inexact ecnt)) (fl->safe efy 100.0)))

  ;; 2. Scan allies once to find overall army centroid + per-race frontlines + bio centroid
  (define-values (acnt asx asy a-str
                  pfc pfx pfy
                  tfc tfx tfy
                  zfc zfx zfy
                  tbc tbx tby
                  has-breaker?
                  ranged-list zerg-surr-list)
    (for/fold ([ac 0] [asx 0.0] [asy 0.0] [astr 0.0]
               [pfc 0] [pfx 0.0] [pfy 0.0]
               [tfc 0] [tfx 0.0] [tfy 0.0]
               [zfc 0] [zfx 0.0] [zfy 0.0]
               [tbc 0] [tbx 0.0] [tby 0.0]
               [brk? #f]
               [rng '()] [zsr '()])
              ([u (in-list (or combat-units '()))]
               #:when (rec-xy? u))
      (define raw (rec-raw-sym u))
      (define canon (sc2-canonical-unit-sym raw))
      (define ux (rec-x u 0.0))
      (define uy (rec-y u 0.0))
      (define d-e (dist2d-fl ux uy ecx ecy))
      (define near-fight? (or (= ecnt 0) (fl<= d-e 26.0)))
      (define in-approach? (and (> ecnt 0) (fl>= d-e 5.5) (fl<= d-e 18.0)))
      (values (add1 ac) (fl+ asx ux) (fl+ asy uy) (fl+ astr (rec-supply-weight u))
              (if (and near-fight? (memq canon PROTOSS-FRONT-SYMS)) (add1 pfc) pfc)
              (if (and near-fight? (memq canon PROTOSS-FRONT-SYMS)) (fl+ pfx ux) pfx)
              (if (and near-fight? (memq canon PROTOSS-FRONT-SYMS)) (fl+ pfy uy) pfy)
              (if (and near-fight? (memq canon TERRAN-FRONT-SYMS)) (add1 tfc) tfc)
              (if (and near-fight? (memq canon TERRAN-FRONT-SYMS)) (fl+ tfx ux) tfx)
              (if (and near-fight? (memq canon TERRAN-FRONT-SYMS)) (fl+ tfy uy) tfy)
              (if (and near-fight? (memq canon ZERG-FRONT-SYMS)) (add1 zfc) zfc)
              (if (and near-fight? (memq canon ZERG-FRONT-SYMS)) (fl+ zfx ux) zfx)
              (if (and near-fight? (memq canon ZERG-FRONT-SYMS)) (fl+ zfy uy) zfy)
              (if (memq canon TERRAN-BIO-SYMS) (add1 tbc) tbc)
              (if (memq canon TERRAN-BIO-SYMS) (fl+ tbx ux) tbx)
              (if (memq canon TERRAN-BIO-SYMS) (fl+ tby uy) tby)
              (or brk? (and near-fight? (not (not (memq canon ZERG-UPHILL-BREAKER-SYMS)))))
              (if (and in-approach? (memq canon RANGED-CONCAVE-SYMS)) (cons u rng) rng)
              (if (and in-approach? (memq canon ZERG-SURROUND-SYMS)) (cons u zsr) zsr))))

  (define acx (if (> acnt 0) (fl/ asx (exact->inexact acnt)) (fl- ecx 10.0)))
  (define acy (if (> acnt 0) (fl/ asy (exact->inexact acnt)) ecy))
  (define dx (fl- ecx acx))
  (define dy (fl- ecy acy))
  (define dn (flmax 0.1 (flsqrt (fl+ (fl* dx dx) (fl* dy dy)))))
  (define fwd-ux (fl/ dx dn))
  (define fwd-uy (fl/ dy dn))
  (define perp-ux (fl- fwd-uy))
  (define perp-uy fwd-ux)

  (define (proj x y) (fl+ (fl* x fwd-ux) (fl* y fwd-uy)))

  (define pfcx (if (> pfc 0) (fl/ pfx (exact->inexact pfc)) acx))
  (define pfcy (if (> pfc 0) (fl/ pfy (exact->inexact pfc)) acy))
  (define tfcx (if (> tfc 0) (fl/ tfx (exact->inexact tfc)) acx))
  (define tfcy (if (> tfc 0) (fl/ tfy (exact->inexact tfc)) acy))
  (define zfcx (if (> zfc 0) (fl/ zfx (exact->inexact zfc)) acx))
  (define zfcy (if (> zfc 0) (fl/ zfy (exact->inexact zfc)) acy))
  (define tbcx (if (> tbc 0) (fl/ tbx (exact->inexact tbc)) acx))
  (define tbcy (if (> tbc 0) (fl/ tby (exact->inexact tbc)) acy))

  (define ranged-ht
    (if (>= (length ranged-list) 6)
        (build-lateral-slot-table ranged-list ecx ecy perp-ux perp-uy)
        (hasheqv)))
  (define zerg-surr-ht
    (if (>= (length zerg-surr-list) 8)
        (build-lateral-slot-table zerg-surr-list ecx ecy perp-ux perp-uy)
        (hasheqv)))

  (combat-pos-ctx
   ecnt ecx ecy fwd-ux fwd-uy perp-ux perp-uy
   pfc pfcx pfcy (proj pfcx pfcy)
   tfc tfcx tfcy (proj tfcx tfcy)
   zfc zfcx zfcy (proj zfcx zfcy)
   tbc tbcx tbcy
   air-pts splash-pts uphill-siege
   has-breaker?
   (if (fl> e-str 0.01) (fl/ a-str e-str) 99.0)
   ranged-ht zerg-surr-ht
   mw mh))

;; =============================================================================
;; 1. Speed-Matched Front-to-Back Advance (`6..16t` approach)
;; =============================================================================
;; Holds faster/fragile midliners behind slower frontliners ONLY when:
;;   - Matching frontliners exist in the advancing group (`front-cnt >= 1`),
;;   - Unit is in the approach window (`6.0t <= d-target <= 16.0t`) AND strictly
;;     outside weapon firing range (`d-target > weapon-range + 1.0t`),
;;   - Unit is currently ahead of `(front-proj - desired-rear-offset + 0.35)`.
;; Returns `(values hold-x hold-y)` or `(values #f #f)` when no hold is needed.

(define (compute-front-to-back-advance-pt pos-ctx u target-x target-y weapon-range)
  (cond
    [(or (not (combat-pos-ctx? pos-ctx))
         (= (combat-pos-ctx-enemy-cnt pos-ctx) 0))
     (values #f #f)]
    [else
     (define sym (rec-canon-sym u))
     (define ux (rec-x u 0.0))
     (define uy (rec-y u 0.0))
     (define ftx (fl->safe target-x (combat-pos-ctx-enemy-cx pos-ctx)))
     (define fty (fl->safe target-y (combat-pos-ctx-enemy-cy pos-ctx)))
     (define d-tgt (dist2d-fl ux uy ftx fty))
     (define wr (fl->safe weapon-range 5.0))
     (define-values (fcnt fcx fcy fproj rear-off min-app-d max-app-d)
       (cond
         [(memq sym PROTOSS-MID-SYMS)
          ;; L58-HOLD Bug #3a fix: tighten Protoss Stalker/Adept offset to `1.2t` within `8..14t` approach
          ;; so Stalkers stay wide & ready to fire (`attack-pos` at call sites, never `'move`)!
          (values (combat-pos-ctx-p-front-cnt pos-ctx)
                  (combat-pos-ctx-p-front-cx pos-ctx)
                  (combat-pos-ctx-p-front-cy pos-ctx)
                  (combat-pos-ctx-p-front-proj pos-ctx)
                  1.2 8.0 14.0)]
         [(memq sym PROTOSS-HEAVY-BACK-SYMS)
          (values (combat-pos-ctx-p-front-cnt pos-ctx)
                  (combat-pos-ctx-p-front-cx pos-ctx)
                  (combat-pos-ctx-p-front-cy pos-ctx)
                  (combat-pos-ctx-p-front-proj pos-ctx)
                  2.8 6.0 16.0)]
         [(memq sym TERRAN-MID-SYMS)
          (values (combat-pos-ctx-t-front-cnt pos-ctx)
                  (combat-pos-ctx-t-front-cx pos-ctx)
                  (combat-pos-ctx-t-front-cy pos-ctx)
                  (combat-pos-ctx-t-front-proj pos-ctx)
                  1.2 6.0 16.0)]
         [(memq sym ZERG-MID-SYMS)
          (values (combat-pos-ctx-z-front-cnt pos-ctx)
                  (combat-pos-ctx-z-front-cx pos-ctx)
                  (combat-pos-ctx-z-front-cy pos-ctx)
                  (combat-pos-ctx-z-front-proj pos-ctx)
                  2.2 6.0 16.0)]
         [else
          (values 0 0.0 0.0 0.0 0.0 6.0 16.0)]))
     (cond
       [(or (= fcnt 0)
            (fl< d-tgt min-app-d)
            (fl> d-tgt max-app-d)
            (fl<= d-tgt (fl+ wr 1.0)))
        (values #f #f)]
       [else
        (define fux (combat-pos-ctx-fwd-ux pos-ctx))
        (define fuy (combat-pos-ctx-fwd-uy pos-ctx))
        (define pux (combat-pos-ctx-perp-ux pos-ctx))
        (define puy (combat-pos-ctx-perp-uy pos-ctx))
        (define u-proj (fl+ (fl* ux fux) (fl* uy fuy)))
        ;; Never hold an anti-air unit behind ground-only frontliners when enemy air is within 16t!
        (define enemy-air-near?
          (and (memq sym '(hydralisk stalker marine sentry))
               (for/or ([ap (in-list (combat-pos-ctx-enemy-air-pts pos-ctx))])
                 (fl<= (dist2d-fl ux uy (car ap) (cdr ap)) 16.0))))
        ;; Only hold back when genuinely role-inverted (at or ahead of the frontline centroid!)
        ;; AND frontline is within 10.5t (part of the same advancing group!)
        (if (and (not enemy-air-near?)
                 (fl>= u-proj (fl- fproj 0.25))
                 (fl<= (dist2d-fl ux uy fcx fcy) 10.5))
            (let* ([lat-off (clamp-fl (fl+ (fl* (fl- ux fcx) pux)
                                           (fl* (fl- uy fcy) puy))
                                      -3.5 3.5)]
                   [hx (clamp-fl (fl+ (fl- fcx (fl* rear-off fux)) (fl* lat-off pux))
                                 4.0 (fl- (combat-pos-ctx-map-w pos-ctx) 4.0))]
                   [hy (clamp-fl (fl+ (fl- fcy (fl* rear-off fuy)) (fl* lat-off puy))
                                 4.0 (fl- (combat-pos-ctx-map-h pos-ctx) 4.0))])
              (values hx hy))
            (values #f #f))])]))

;; =============================================================================
;; 2. Terran Caster Rear Leash (Medivac / Raven / Ghost `-2.0..-3.0t` behind Bio)
;; =============================================================================
;; Keeps Medivacs, Ravens, and non-channeling Ghosts tethered `-2.0..-3.0t` behind
;; our Bio centroid along the enemy-facing axis so casters NEVER drift ahead of
;; Marines/Marauders even against non-AA melee armies (e.g. Zerglings/Banelings).
;; Returns `(values leash-x leash-y)` or `(values #f #f)`.

(define (compute-caster-rear-leash-pt pos-ctx u
                                      #:rear-dist [rear-dist 2.5]
                                      #:max-ahead-tol [max-ahead-tol #f]
                                      #:enemy-fallback-x [efx #f]
                                      #:enemy-fallback-y [efy #f])
  (cond
    [(or (not (combat-pos-ctx? pos-ctx))
         (< (combat-pos-ctx-t-bio-cnt pos-ctx) 2))
     (values #f #f)]
    [else
     (define sym (rec-canon-sym u))
     (define ux (rec-x u 0.0))
     (define uy (rec-y u 0.0))
     (define bcx (combat-pos-ctx-t-bio-cx pos-ctx))
     (define bcy (combat-pos-ctx-t-bio-cy pos-ctx))
     (define d-bio (dist2d-fl ux uy bcx bcy))
     (cond
       [(fl> d-bio 18.0)
        ;; Far across the map (e.g. separate drop/scout): do not yank back unless Medivac
        (values #f #f)]
       [else
        (define ecx (if (> (combat-pos-ctx-enemy-cnt pos-ctx) 0)
                        (combat-pos-ctx-enemy-cx pos-ctx)
                        (fl->safe (or efx (+ bcx 10.0)) (+ bcx 10.0))))
        (define ecy (if (> (combat-pos-ctx-enemy-cnt pos-ctx) 0)
                        (combat-pos-ctx-enemy-cy pos-ctx)
                        (fl->safe (or efy bcy) bcy)))
        (define dx (fl- ecx bcx))
        (define dy (fl- ecy bcy))
        (define dn (flmax 0.1 (flsqrt (fl+ (fl* dx dx) (fl* dy dy)))))
        (define fux (fl/ dx dn))
        (define fuy (fl/ dy dn))
        (define caster-proj (fl+ (fl* (fl- ux bcx) fux) (fl* (fl- uy bcy) fuy)))
        (define d-enemy (dist2d-fl ux uy ecx ecy))
        (define tol
          (fl->safe (or max-ahead-tol
                        (cond
                          [(eq? sym 'medivac) -0.8]
                          [(eq? sym 'raven)   -0.5]
                          [else                1.0]))
                    0.5))
        (define rdist (clamp-fl (fl->safe rear-dist 2.5) 2.0 3.5))
        (define lx (clamp-fl (fl- bcx (fl* rdist fux)) 4.0 (fl- (combat-pos-ctx-map-w pos-ctx) 4.0)))
        (define ly (clamp-fl (fl- bcy (fl* rdist fuy)) 4.0 (fl- (combat-pos-ctx-map-h pos-ctx) 4.0)))
        (define needs-leash?
          (cond
            [(eq? sym 'ghost)
             ;; Pull Ghosts back ONLY when drifting > 1.0t ahead of Bio while approaching (> 6.5t)
             (and (fl> caster-proj tol)
                  (fl> d-enemy 6.5))]
            [(eq? sym 'medivac)
             ;; Medivacs always hold -2.5t behind Bio when ahead of tol or > 4.5t off leash
             (or (fl> caster-proj tol)
                 (fl> (dist2d-fl ux uy lx ly) 4.5))]
            [(eq? sym 'raven)
             (fl> caster-proj tol)]
            [else #f]))
        (if needs-leash?
            (values lx ly)
            (values #f #f))])]))

;; =============================================================================
;; 3a. Zerg Two-Wing Surround (`>= 8` Zerglings only, outer `40%` wings, `'attack-pos`)
;; =============================================================================
;; Fans the outer `40%` (`left 20%`, `right 20%`) of an approaching Zergling pack
;; `±3.0..4.0t` perpendicular to the enemy vector curving `+1.5t` around the flanks.
;; Center `60%` advances straight. ALWAYS returns `use-move? = #f` (`'attack-pos`)
;; and rejects unpathable points when optional `#:pathable?` predicate is supplied.
;; Returns `(values wx wy #f)` or `(values #f #f #f)`.

(define (compute-zerg-surround-wing-pt pos-ctx u enemy-units
                                       #:pathable? [pathable? #f])
  (cond
    [(or (not (combat-pos-ctx? pos-ctx))
         (= (combat-pos-ctx-enemy-cnt pos-ctx) 0)
         (not (eq? (rec-canon-sym u) 'zergling)))
     (values #f #f #f)]
    [else
     (define uid (rec-id u))
     (define slot (hash-ref (combat-pos-ctx-zerg-surround-slot-ht pos-ctx) uid #f))
     (cond
       [(not (pair? slot)) (values #f #f #f)]
       [else
        (define idx (car slot))
        (define tot (cdr slot))
        (define wing-k (max 1 (inexact->exact (floor (* 0.20 tot)))))
        (define wing-sign
          (cond
            [(< idx wing-k) -1.0]
            [(>= idx (- tot wing-k)) 1.0]
            [else 0.0]))
        (cond
          [(fl= wing-sign 0.0) (values #f #f #f)]
          [else
           (define ux (rec-x u 0.0))
           (define uy (rec-y u 0.0))
           (define ecx (combat-pos-ctx-enemy-cx pos-ctx))
           (define ecy (combat-pos-ctx-enemy-cy pos-ctx))
           (define d-ec (dist2d-fl ux uy ecx ecy))
           (cond
             [(or (fl< d-ec 6.0) (fl> d-ec 15.0))
              (values #f #f #f)]
             [else
              ;; If an enemy is already within <= 4.5t of this wing unit, stop flanking & bite!
              (define close-interceptor?
                (for/or ([e (in-list (or enemy-units '()))]
                         #:when (and (rec-xy? e) (not (rec-snapshot? e))))
                  (fl<= (dist2d-fl ux uy (rec-x e 9999.0) (rec-y e 9999.0)) 4.5)))
              (if close-interceptor?
                  (values #f #f #f)
                  (let* ([fux (combat-pos-ctx-fwd-ux pos-ctx)]
                         [fuy (combat-pos-ctx-fwd-uy pos-ctx)]
                         [pux (combat-pos-ctx-perp-ux pos-ctx)]
                         [puy (combat-pos-ctx-perp-uy pos-ctx)]
                         ;; Narrowed lateral offset `3.0..4.0t` scaling mildly with rank on outer wing
                         [wing-frac (if (fl< wing-sign 0.0)
                                        (fl/ (exact->inexact (- wing-k idx)) (exact->inexact (max 1 wing-k)))
                                        (fl/ (exact->inexact (+ 1 (- idx (- tot wing-k)))) (exact->inexact (max 1 wing-k))))]
                         [lat-r (fl+ 3.0 (fl* 1.0 (clamp-fl wing-frac 0.0 1.0)))]
                         [fwd-curve 1.5]
                         [wx (clamp-fl (fl+ ecx (fl+ (fl* (fl* wing-sign lat-r) pux)
                                                     (fl* fwd-curve fux)))
                                       4.0 (fl- (combat-pos-ctx-map-w pos-ctx) 4.0))]
                         [wy (clamp-fl (fl+ ecy (fl+ (fl* (fl* wing-sign lat-r) puy)
                                                     (fl* fwd-curve fuy)))
                                       4.0 (fl- (combat-pos-ctx-map-h pos-ctx) 4.0))])
                    ;; L58-HOLD Bug #3a fix: ALWAYS return `use-move? = #f` (`'attack-pos`) and
                    ;; honor optional `#:pathable?` wall/choke rejection!
                    (if (and (procedure? pathable?) (not (pathable? wx wy)))
                        (values #f #f #f)
                        (values wx wy #f))))])])])]))

;; =============================================================================
;; 3b. Zerg Uphill Ramp Brake (strict `z` elevation diff `>= 1.5` vs Tank/Lurker)
;; =============================================================================
;; Holds Zerg ground units outside an uphill high-ground ramp guarded by entrenched
;; Sieged Tanks or Burrowed Lurkers (`enemy-z - ally-z >= 1.5`) when we lack
;; Ravager Bile / air / Viper / `>= 1.60x` overwhelming army advantage.
;; Flat-ground battles (`enemy-z - ally-z < 1.5`) ALWAYS return `(values #f #f)`!

(define (zerg-uphill-ramp-hold-pt pos-ctx u)
  (cond
    [(or (not (combat-pos-ctx? pos-ctx))
         (null? (combat-pos-ctx-enemy-uphill-siege pos-ctx))
         (combat-pos-ctx-ally-has-uphill-breaker? pos-ctx)
         (fl>= (combat-pos-ctx-ally-strength-ratio pos-ctx) 1.60))
     (values #f #f)]
    [else
     (define sym (rec-canon-sym u))
     (define uz (rec-z u))
     (cond
       [(or (not uz) (not (memq sym ZERG-GROUND-HOLD-SYMS)))
        (values #f #f)]
       [else
        (define ux (rec-x u 0.0))
        (define uy (rec-y u 0.0))
        (define-values (best-sv best-d)
          (for/fold ([bs #f] [bd +inf.0]) ([sv (in-list (combat-pos-ctx-enemy-uphill-siege pos-ctx))])
            (define sx (vector-ref sv 0))
            (define sy (vector-ref sv 1))
            (define sz (vector-ref sv 2))
            (if (fl>= (fl- sz uz) 1.5)
                (let ([d (dist2d-fl ux uy sx sy)])
                  (if (and (fl<= d 16.5) (fl< d bd))
                      (values sv d)
                      (values bs bd)))
                (values bs bd))))
        (if (not best-sv)
            (values #f #f)
            (let* ([sx (vector-ref best-sv 0)]
                   [sy (vector-ref best-sv 1)]
                   [dx (fl- ux sx)]
                   [dy (fl- uy sy)]
                   [dn (flmax 0.1 (flsqrt (fl+ (fl* dx dx) (fl* dy dy))))]
                   [hold-r 15.0]
                   [hx (clamp-fl (fl+ sx (fl* hold-r (fl/ dx dn)))
                                 4.0 (fl- (combat-pos-ctx-map-w pos-ctx) 4.0))]
                   [hy (clamp-fl (fl+ sy (fl* hold-r (fl/ dy dn)))
                                 4.0 (fl- (combat-pos-ctx-map-h pos-ctx) 4.0))])
              (values hx hy)))])]))

;; =============================================================================
;; 4. Pre-Contact Lateral Concave Fan-Out & Anti-Splash Spread
;; =============================================================================
;; For ranged squads (`>= 6` units) approaching enemy splash (`Tank`/`Bane`/
;; `Colossus`/`Storm`/`Disruptor`/`Lurker`/`Mine`/`Archon`) within `7..14t` and
;; strictly outside immediate weapon range (`d > weapon-range + 1.0t`), fans slots
;; laterally `±2.0..4.5t`+ perpendicular to enemy centroid (`>= 2.0t` spacing).
;; Returns `(values ax ay)` or `(values #f #f)`.

(define (compute-lateral-concave-spread-pt pos-ctx u target-x target-y weapon-range)
  (cond
    [(or (not (combat-pos-ctx? pos-ctx))
         (= (combat-pos-ctx-enemy-cnt pos-ctx) 0)
         (null? (combat-pos-ctx-enemy-splash-pts pos-ctx)))
     (values #f #f)]
    [else
     (define uid (rec-id u))
     (define slot (hash-ref (combat-pos-ctx-ranged-slot-ht pos-ctx) uid #f))
     (cond
       [(not (pair? slot)) (values #f #f)]
       [else
        (define ux (rec-x u 0.0))
        (define uy (rec-y u 0.0))
        (define ecx (combat-pos-ctx-enemy-cx pos-ctx))
        (define ecy (combat-pos-ctx-enemy-cy pos-ctx))
        (define d-ec (dist2d-fl ux uy ecx ecy))
        (define ftx (fl->safe target-x ecx))
        (define fty (fl->safe target-y ecy))
        (define d-tgt (dist2d-fl ux uy ftx fty))
        (define wr (fl->safe weapon-range 5.0))
        (define splash-near?
          (for/or ([sp (in-list (combat-pos-ctx-enemy-splash-pts pos-ctx))])
            (fl<= (dist2d-fl ux uy (car sp) (cdr sp)) 18.0)))
        (cond
          [(or (not splash-near?)
               (fl< d-ec 7.0)
               (fl> d-ec 14.0)
               (fl<= d-tgt (fl+ wr 1.0)))
           (values #f #f)]
          [else
           (define idx (car slot))
           (define tot (cdr slot))
           (define fux (combat-pos-ctx-fwd-ux pos-ctx))
           (define fuy (combat-pos-ctx-fwd-uy pos-ctx))
           (define pux (combat-pos-ctx-perp-ux pos-ctx))
           (define puy (combat-pos-ctx-perp-uy pos-ctx))
           ;; Normalized slot `t` in `[-1.0, +1.0]`
           (define t (if (> tot 1)
                         (fl- (fl* 2.0 (fl/ (exact->inexact idx) (exact->inexact (- tot 1)))) 1.0)
                         0.0))
           ;; Guarantee `>= 2.0t` lateral slot spacing across `6+` ranged units (`±2.0..7.5t`)
           (define half-span (clamp-fl (fl* 1.05 (exact->inexact (- tot 1))) 2.5 7.5))
           (define lat-target (fl* t half-span))
           (define cur-lat (fl+ (fl* (fl- ux ecx) pux) (fl* (fl- uy ecy) puy)))
           (if (fl< (flabs (fl- cur-lat lat-target)) 1.0)
               (values #f #f)
               (let* ([standoff (flmax (fl+ wr 0.25) (fl- d-ec 2.0))]
                      ;; Outer wings curve `+1.2t` forward into a concave arc
                      [arc-fwd (fl* 1.2 (fl* t t))]
                      [base-x (fl- ecx (fl* (fl- standoff arc-fwd) fux))]
                      [base-y (fl- ecy (fl* (fl- standoff arc-fwd) fuy))]
                      [ax (clamp-fl (fl+ base-x (fl* lat-target pux))
                                    4.0 (fl- (combat-pos-ctx-map-w pos-ctx) 4.0))]
                      [ay (clamp-fl (fl+ base-y (fl* lat-target puy))
                                    4.0 (fl- (combat-pos-ctx-map-h pos-ctx) 4.0))])
                 (values ax ay)))])])]))

;; =============================================================================
;; 5. Blind-Uphill Retreat & Multi-Race High-Ground Vision Dispatcher (`#1481`)
;; =============================================================================
;; Prevents ground squads from standing blindly at the base of a ramp/cliff taking
;; unseen high-ground fire (`0` visible in-range attackers while taking HP/shield
;; damage or facing uphill elevation `uphill-z - uz >= 1.5`). Returns `(values rx ry)`
;; `retreat-dist` (default `4.5t`) back away from the cliff/uphill axis, or `(values #f #f)`
;; whenever the unit is flying, not under unseen uphill fire, or already sees an in-range target.

(define (rec-total-ehp u)
  (if (hash? u)
      (fl+ (fl->safe (hash-ref u 'hp (hash-ref u 'health 0.0)) 0.0)
           (fl->safe (hash-ref u 'shields (hash-ref u 'shield 0.0)) 0.0))
      0.0))

(define (rec-flying? u)
  (and (hash? u)
       (or (eq? (hash-ref u 'flying? #f) #t)
           (eq? (hash-ref u 'flying #f) #t)
           (eq? (hash-ref u 'is-flying #f) #t))))

(define (rec-energy u)
  (if (hash? u)
      (fl->safe (hash-ref u 'energy 0.0) 0.0)
      0.0))

(define (compute-blind-uphill-retreat-pt pos-ctx u
                                         #:prev-hp [prev-hp #f]
                                         #:under-fire? [under-fire? #f]
                                         #:enemy-units [enemy-units '()]
                                         #:uphill-target-x [uphill-tx #f]
                                         #:uphill-target-y [uphill-ty #f]
                                         #:uphill-z [uphill-z #f]
                                         #:weapon-range [weapon-range 5.5]
                                         #:retreat-dist [retreat-dist 4.5]
                                         #:map-width [mw-arg #f]
                                         #:map-height [mh-arg #f])
  (cond
    [(or (not (hash? u))
         (rec-flying? u))
     (values #f #f)]
    [else
     (define cur-ehp (rec-total-ehp u))
     (define took-damage?
       (or (and under-fire? #t)
           (and (real? prev-hp) (fl< cur-ehp (fl- (fl->safe prev-hp cur-ehp) 0.5)))))
     (define uz (rec-z u))
     (define uphill-gap?
       (and uz (real? uphill-z) (fl>= (fl- (fl->safe uphill-z uz) uz) 1.5)))
     (cond
       [(not (or took-damage? uphill-gap?))
        (values #f #f)]
       [else
        (define ux (rec-x u 0.0))
        (define uy (rec-y u 0.0))
        (define wr (fl->safe weapon-range 5.5))
        (define scan-r (flmax 7.5 (fl+ wr 1.5)))
        ;; If ANY visible non-snapshot enemy is already within firing sightline, fight — NEVER pull back!
        (define visible-in-range?
          (for/or ([e (in-list (if (list? enemy-units) enemy-units '()))])
            (and (rec-xy? e)
                 (not (rec-snapshot? e))
                 (not (memq (rec-canon-sym e) NON-COMBAT-IGNORE-SYMS))
                 (fl<= (dist2d-fl ux uy (rec-x e 0.0) (rec-y e 0.0)) scan-r))))
        (cond
          [visible-in-range? (values #f #f)]
          [else
           (define mw (if (real? mw-arg)
                          (fl->safe mw-arg 200.0)
                          (if (combat-pos-ctx? pos-ctx) (combat-pos-ctx-map-w pos-ctx) 200.0)))
           (define mh (if (real? mh-arg)
                          (fl->safe mh-arg 200.0)
                          (if (combat-pos-ctx? pos-ctx) (combat-pos-ctx-map-h pos-ctx) 200.0)))
           (define-values (back-ux back-uy)
             (cond
               [(and (real? uphill-tx) (real? uphill-ty))
                (define dx (fl- ux (fl->safe uphill-tx ux)))
                (define dy (fl- uy (fl->safe uphill-ty uy)))
                (define dn (flsqrt (fl+ (fl* dx dx) (fl* dy dy))))
                (if (fl> dn 0.05)
                    (values (fl/ dx dn) (fl/ dy dn))
                    (if (combat-pos-ctx? pos-ctx)
                        (values (fl- (combat-pos-ctx-fwd-ux pos-ctx))
                                (fl- (combat-pos-ctx-fwd-uy pos-ctx)))
                        (values -1.0 0.0)))]
               [(combat-pos-ctx? pos-ctx)
                (values (fl- (combat-pos-ctx-fwd-ux pos-ctx))
                        (fl- (combat-pos-ctx-fwd-uy pos-ctx)))]
               [else
                (values -1.0 0.0)]))
           (define rdist (flmax 2.5 (fl->safe retreat-dist 4.5)))
           (define rx (clamp-fl (fl+ ux (fl* rdist back-ux)) 4.0 (fl- mw 4.0)))
           (define ry (clamp-fl (fl+ uy (fl* rdist back-uy)) 4.0 (fl- mh 4.0)))
           (values rx ry)])])]))

;; Multi-race High-Ground Vision Dispatcher:
;;   - Protoss: cliff-edge `observer` / `phoenix` / `warp-prism` / `oracle`, or Sentry `hallucination-phoenix` (154, >= 75E)
;;   - Terran : cliff-edge `medivac` / `viking-fighter` / `raven` / `banshee`, or OC `scanner-sweep` (399, >= 50E)
;;   - Zerg   : cliff-edge `changeling*` / `overlord` / `overseer` / `mutalisk`
;; Keeps air spotters perched at a safe cliff-edge standoff (`4.5t`, pushed to `7.5t` if visible AA sits nearby).
(define HIGH-GROUND-AA-THREAT-SYMS
  '(marine ghost thor thor-ap viking-fighter cyclone missile-turret widow-mine widow-mine-burrowed
    stalker phoenix archon void-ray tempest carrier photon-cannon sentry
    hydralisk queen mutalisk corruptor spore-crawler))

(define (spotter-rank-for-race race sym)
  (case race
    [(Protoss protoss)
     (cond [(memq sym '(observer observer-siege-mode)) 1]
           [(eq? sym 'phoenix) 2]
           [(eq? sym 'warp-prism) 3]
           [(eq? sym 'oracle) 4]
           [else #f])]
    [(Terran terran)
     (cond [(memq sym '(viking viking-fighter)) 1]
           [(eq? sym 'medivac) 2]
           [(eq? sym 'raven) 3]
           [(eq? sym 'banshee) 4]
           [else #f])]
    [(Zerg zerg)
     (cond [(memq sym '(changeling changeling-zealot changeling-marine changeling-marine-shield
                        changeling-zergling changeling-zergling-wings)) 1]
           [(eq? sym 'overlord) 2]
           [(memq sym '(overseer overseer-siege-mode)) 3]
           [(eq? sym 'mutalisk) 4]
           [else #f])]
    [else #f]))

(define (plan-high-ground-vision-actions race ally-units ally-buildings enemy-units
                                         #:uphill-x uphill-x
                                         #:uphill-y uphill-y
                                         #:uphill-z [uphill-z #f]
                                         #:home-x [home-x 32.5]
                                         #:home-y [home-y 32.5]
                                         #:map-width [map-w 200.0]
                                         #:map-height [map-h 200.0])
  (define ux (fl->safe uphill-x 64.0))
  (define uy (fl->safe uphill-y 64.0))
  (define hx (fl->safe home-x 32.5))
  (define hy (fl->safe home-y 32.5))
  (define mw (fl->safe map-w 200.0))
  (define mh (fl->safe map-h 200.0))
  (define dx (fl- hx ux))
  (define dy (fl- hy uy))
  (define dn (flmax 0.1 (flsqrt (fl+ (fl* dx dx) (fl* dy dy)))))
  (define back-x (fl/ dx dn))
  (define back-y (fl/ dy dn))
  (define aa-near?
    (for/or ([e (in-list (if (list? enemy-units) enemy-units '()))])
      (and (rec-xy? e)
           (not (rec-snapshot? e))
           (memq (rec-canon-sym e) HIGH-GROUND-AA-THREAT-SYMS)
           (fl<= (dist2d-fl ux uy (rec-x e 0.0) (rec-y e 0.0)) 8.0))))
  (define perch-standoff (if aa-near? 7.0 4.0))
  (define perch-x (clamp-fl (fl+ ux (fl* perch-standoff back-x)) 4.0 (fl- mw 4.0)))
  (define perch-y (clamp-fl (fl+ uy (fl* perch-standoff back-y)) 4.0 (fl- mh 4.0)))
  ;; Already have a friendly air spotter perched cleanly within vision range (`<= 8.5t`)?
  (define-values (best-spotter best-score)
    (for/fold ([bs #f] [bsc +inf.0]) ([a (in-list (if (list? ally-units) ally-units '()))])
      (define rk (and (rec-xy? a) (> (rec-id a) 0) (spotter-rank-for-race race (rec-canon-sym a))))
      (if rk
          (let ([d (dist2d-fl (rec-x a 0.0) (rec-y a 0.0) ux uy)])
            (if (fl<= d 36.0)
                (let ([sc (fl+ (fl* 8.0 (exact->inexact rk)) d)])
                  (if (fl< sc bsc) (values a sc) (values bs bsc)))
                (values bs bsc)))
          (values bs bsc))))
  (cond
    [best-spotter
     (define sid (rec-id best-spotter))
     (define d-perch (dist2d-fl (rec-x best-spotter 0.0) (rec-y best-spotter 0.0) perch-x perch-y))
     (if (fl> d-perch 1.5)
         (list (list 'move sid perch-x perch-y))
         '())]
    [else
     ;; No mobile spotter within 36t -> race-specific ability vision fallback!
     (case race
       [(Protoss protoss)
        (define ready-sentry
          (for/or ([a (in-list (if (list? ally-units) ally-units '()))])
            (and (hash? a)
                 (> (rec-id a) 0)
                 (eq? (rec-canon-sym a) 'sentry)
                 (fl>= (rec-energy a) 75.0)
                 a)))
        (if ready-sentry
            (list (list 'cast-spell (rec-id ready-sentry) 'hallucination-phoenix))
            '())]
       [(Terran terran)
        (define ready-oc
          (for/or ([b (in-list (if (list? ally-buildings) ally-buildings '()))])
            (and (hash? b)
                 (> (rec-id b) 0)
                 (eq? (rec-canon-sym b) 'orbital-command)
                 (fl>= (rec-energy b) 50.0)
                 b)))
        (if ready-oc
            (list (list 'cast-spell (rec-id ready-oc) 'scanner-sweep ux uy))
            '())]
       [else '()])]))
