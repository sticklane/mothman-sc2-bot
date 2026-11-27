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
         racket/set
         (only-in "../sc2-game-constants.rkt"
                  sc2-canonical-unit-sym
                  sc2-supply-cost))

(provide
 (struct-out combat-pos-ctx)
 build-combat-positioning-context
 compute-local-cluster-axis
 compute-front-to-back-advance-pt
 compute-caster-rear-leash-pt
 compute-zerg-surround-wing-pt
 zerg-uphill-ramp-hold-pt
 all-race-uphill-ramp-hold-pt
 compute-lateral-concave-spread-pt
 compute-in-combat-concave-step-pt
 compute-defensive-pre-arc-pt
 compute-blind-uphill-retreat-pt
 plan-high-ground-vision-actions)

;; =============================================================================
;; Classification Tables
;; =============================================================================

(define PROTOSS-FRONT-SYMS '(zealot archon))
(define PROTOSS-MID-SYMS   '(stalker adept))
(define PROTOSS-HEAVY-BACK-SYMS '(immortal colossus sentry high-templar))
(define PROTOSS-CORE-SYMS  '(zealot archon stalker adept immortal))
(define PROTOSS-CASTER-SYMS '(high-templar sentry disruptor colossus))

(define TERRAN-FRONT-SYMS  '(marauder hellbat))
(define TERRAN-MID-SYMS    '(marine))
(define TERRAN-BIO-SYMS    '(marine marauder hellbat ghost reaper))
(define TERRAN-CASTER-SYMS '(medivac raven ghost))

(define ZERG-FRONT-SYMS         '(zergling baneling roach ultralisk))
(define ZERG-DURABLE-FRONT-SYMS '(roach ultralisk baneling))
;; L58-HOLD Bug #3a fix: restrict Zerg two-wing surround strictly to fast melee `'zergling`
;; (never pull ranged `roach`/`ravager`/`hydralisk` or `baneling` laterally into choke walls!)
(define ZERG-SURROUND-SYMS '(zergling))
(define ZERG-MID-SYMS      '(hydralisk ravager))
(define ZERG-CORE-SYMS     '(zergling baneling roach ravager hydralisk ultralisk))
(define ZERG-CASTER-SYMS   '(infestor viper lurker lurker-mp))
(define ZERG-GROUND-HOLD-SYMS '(zergling baneling roach hydralisk ultralisk))
(define ZERG-UPHILL-BREAKER-SYMS '(ravager viper brood-lord broodlord mutalisk corruptor swarm-host swarm-host-mp))

(define ALL-RACE-GROUND-HOLD-SYMS
  '(zergling baneling roach hydralisk ultralisk
    marine marauder hellion hellbat cyclone ghost reaper
    zealot stalker adept sentry immortal archon dark-templar high-templar))

(define ALL-RACE-UPHILL-BREAKER-SYMS
  '(ravager viper brood-lord broodlord mutalisk corruptor swarm-host swarm-host-mp
    siege-tank siege-tank-sieged liberator liberator-ag battlecruiser banshee viking-fighter raven
    colossus tempest disruptor warp-prism void-ray voidray carrier phoenix oracle))

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

(define ENEMY-AIR-COMBAT-ATTACKER-SYMS
  '(mutalisk banshee oracle void-ray voidray liberator liberator-ag
    battlecruiser carrier tempest mothership brood-lord broodlord phoenix))

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
   ;; Terran Bio + Protoss/Zerg combat core centroids for all-race caster rear leash
   t-bio-cnt t-bio-cx t-bio-cy
   p-core-cnt p-core-cx p-core-cy
   z-core-cnt z-core-cx z-core-cy
   ;; Splash, air & entrenched uphill siege records
   enemy-air-pts          ;; list of (cons ex ey) flying combat attackers (excl. support air)
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

;; ABI-preserving weak side-table storing per-cluster enemy vectors, per-cluster
;; axes, all-enemy elevation records, and all-race uphill-breaker status without
;; changing the `combat-pos-ctx` struct arity.
(define pos-ctx-extra-table (make-weak-hasheq))

(define (pos-ctx-extra pos-ctx)
  (and (combat-pos-ctx? pos-ctx)
       (hash-ref pos-ctx-extra-table pos-ctx #f)))

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

  ;; 0. Rough ally combat centroid so Gap C2 anchors the enemy cluster to the nearest active clash
  (define-values (rough-ac rough-asx rough-asy)
    (for/fold ([c 0] [sx 0.0] [sy 0.0])
              ([u (in-list (or combat-units '()))]
               #:when (rec-xy? u))
      (values (add1 c) (fl+ sx (rec-x u 0.0)) (fl+ sy (rec-y u 0.0)))))
  (define rough-ax (if (> rough-ac 0) (fl/ rough-asx (exact->inexact rough-ac)) (fl->safe efx 100.0)))
  (define rough-ay (if (> rough-ac 0) (fl/ rough-asy (exact->inexact rough-ac)) (fl->safe efy 100.0)))

  ;; 1. Scan enemies once: collect visible points, air/splash/uphill records, and nearest clash anchor
  (define-values (ecnt-all e-vecs near-ex near-ey _near-ed air-pts splash-pts uphill-siege all-elev-enemies)
    (for/fold ([c 0] [evs '()] [nex #f] [ney #f] [ned +inf.0] [apts '()] [spts '()] [usge '()] [aev '()])
              ([e (in-list (or enemy-units '()))]
               #:when (and (rec-xy? e) (not (rec-snapshot? e))))
      (define raw (rec-raw-sym e))
      (define canon (sc2-canonical-unit-sym raw))
      (cond
        [(memq canon NON-COMBAT-IGNORE-SYMS)
         (values c evs nex ney ned apts spts usge aev)]
        [else
         (define ex (rec-x e efx))
         (define ey (rec-y e efy))
         (define ez (rec-z e))
         (define w (rec-supply-weight e))
         (define d-rough (dist2d-fl ex ey rough-ax rough-ay))
         (define closer? (or (not nex) (fl< d-rough ned)))
         ;; Strictly air-to-ground / ground-threatening combat flyers (exclude medivac,
         ;; warp-prism, raven, viper, overlord, overseer, observer, corruptor, viking-fighter)
         ;; so non-ground-attacking support air NEVER disables front-to-back ground screening!
         (define is-air?
           (and (or (memq raw ENEMY-AIR-COMBAT-ATTACKER-SYMS)
                    (memq canon ENEMY-AIR-COMBAT-ATTACKER-SYMS))
                #t))
         (define is-splash?
           (or (memq raw ENEMY-SPLASH-SYMS)
               (memq canon '(baneling colossus high-templar disruptor archon))))
         (define is-uphill-siege?
           (and ez
                (or (memq raw ENEMY-UPHILL-SIEGE-SYMS)
                    (and (eq? canon 'siege-tank) (eq? (hash-ref e 'sieged #f) #t))
                    (and (eq? canon 'lurker) (eq? (hash-ref e 'burrowed #f) #t)))))
         (values (add1 c)
                 (cons (vector ex ey w) evs)
                 (if closer? ex nex)
                 (if closer? ey ney)
                 (if closer? d-rough ned)
                 (if is-air? (cons (cons ex ey) apts) apts)
                 (if is-splash? (cons (cons ex ey) spts) spts)
                 (if is-uphill-siege? (cons (vector ex ey ez raw) usge) usge)
                 (if ez (cons (vector ex ey ez canon) aev) aev))])))

  ;; Build greedy spatial enemy clusters (`r = 18.0t`) for per-cluster combat axes
  (define raw-enemy-clusters
    (for/fold ([cls '()]) ([ev (in-list e-vecs)])
      (define ex (vector-ref ev 0))
      (define ey (vector-ref ev 1))
      (define ew (vector-ref ev 2))
      (let loop ([rem cls] [acc '()] [merged? #f])
        (cond
          [(null? rem)
           (if merged?
               (reverse acc)
               (reverse (cons (vector ex ey 1 ew) acc)))]
          [(not merged?)
           (define cl (car rem))
           (define cl-n (exact->inexact (vector-ref cl 2)))
           (define cl-cx (fl/ (vector-ref cl 0) cl-n))
           (define cl-cy (fl/ (vector-ref cl 1) cl-n))
           (if (fl<= (dist2d-fl ex ey cl-cx cl-cy) 18.0)
               (loop (cdr rem)
                     (cons (vector (fl+ (vector-ref cl 0) ex)
                                   (fl+ (vector-ref cl 1) ey)
                                   (add1 (vector-ref cl 2))
                                   (fl+ (vector-ref cl 3) ew))
                           acc)
                     #t)
               (loop (cdr rem) (cons cl acc) #f))]
          [else
           (loop (cdr rem) (cons (car rem) acc) #t)]))))
  ;; Finalize cluster centroids: `#(cx cy cnt str-sum ally-cx ally-cy fwd-ux fwd-uy perp-ux perp-uy)`
  (define enemy-cluster-axes
    (for/list ([cl (in-list raw-enemy-clusters)])
      (define n (exact->inexact (max 1 (vector-ref cl 2))))
      (define cl-cx (fl/ (vector-ref cl 0) n))
      (define cl-cy (fl/ (vector-ref cl 1) n))
      (define-values (ac-loc asx-loc asy-loc)
        (for/fold ([c 0] [sx 0.0] [sy 0.0])
                  ([u (in-list (or combat-units '()))]
                   #:when (rec-xy? u))
          (define ux (rec-x u 0.0))
          (define uy (rec-y u 0.0))
          (if (fl<= (dist2d-fl ux uy cl-cx cl-cy) 26.0)
              (values (add1 c) (fl+ sx ux) (fl+ sy uy))
              (values c sx sy))))
      (define lacx (if (> ac-loc 0) (fl/ asx-loc (exact->inexact ac-loc)) rough-ax))
      (define lacy (if (> ac-loc 0) (fl/ asy-loc (exact->inexact ac-loc)) rough-ay))
      (define cdx (fl- cl-cx lacx))
      (define cdy (fl- cl-cy lacy))
      (define cdn (flmax 0.1 (flsqrt (fl+ (fl* cdx cdx) (fl* cdy cdy)))))
      (define cfux (fl/ cdx cdn))
      (define cfuy (fl/ cdy cdn))
      (vector cl-cx cl-cy (vector-ref cl 2) (vector-ref cl 3)
              lacx lacy cfux cfuy (fl- cfuy) cfux)))

  ;; Loop 65 Gap C2: Compute engagement enemy centroid LOCALLY (`<= 22.0t` of nearest active clash)
  ;; so stray off-map scouts/Overlords/drops NEVER skew `fwd-ux/fwd-uy` or concave arcs!
  (define-values (ecnt esx esy e-str)
    (if (and (> ecnt-all 0) near-ex near-ey)
        (for/fold ([c 0] [sx 0.0] [sy 0.0] [estr 0.0]) ([ev (in-list e-vecs)])
          (define ex (vector-ref ev 0))
          (define ey (vector-ref ev 1))
          (define ew (vector-ref ev 2))
          (if (fl<= (dist2d-fl ex ey near-ex near-ey) 22.0)
              (values (add1 c) (fl+ sx ex) (fl+ sy ey) (fl+ estr ew))
              (values c sx sy estr)))
        (values 0 0.0 0.0 0.0)))

  (define ecx (if (> ecnt 0) (fl/ esx (exact->inexact ecnt)) (fl->safe efx 100.0)))
  (define ecy (if (> ecnt 0) (fl/ esy (exact->inexact ecnt)) (fl->safe efy 100.0)))

  ;; 2. Scan allies once to find local/overall army centroid + per-race frontlines & core centroids
  (define-values (acnt asx asy a-str
                  loc-ac loc-asx loc-asy
                  pfc pfx pfy
                  tfc tfx tfy
                  zfc zfx zfy
                  zdc zdx zdy
                  tbc tbx tby
                  pcc pcx pcy pcc-all pcx-all pcy-all
                  zcc zcx zcy zcc-all zcx-all zcy-all
                  has-breaker?
                  has-all-race-breaker?
                  ranged-list zerg-surr-list)
    (for/fold ([ac 0] [asx 0.0] [asy 0.0] [astr 0.0]
               [lac 0] [lasx 0.0] [lasy 0.0]
               [pfc 0] [pfx 0.0] [pfy 0.0]
               [tfc 0] [tfx 0.0] [tfy 0.0]
               [zfc 0] [zfx 0.0] [zfy 0.0]
               [zdc 0] [zdx 0.0] [zdy 0.0]
               [tbc 0] [tbx 0.0] [tby 0.0]
               [pcc 0] [pcx 0.0] [pcy 0.0] [pcca 0] [pcxa 0.0] [pcya 0.0]
               [zcc 0] [zcx 0.0] [zcy 0.0] [zcca 0] [zcxa 0.0] [zcya 0.0]
               [brk? #f]
               [all-brk? #f]
               [rng '()] [zsr '()])
              ([u (in-list (or combat-units '()))]
               #:when (rec-xy? u))
      (define raw (rec-raw-sym u))
      (define canon (sc2-canonical-unit-sym raw))
      (define ux (rec-x u 0.0))
      (define uy (rec-y u 0.0))
      (define d-e
        (if (pair? enemy-cluster-axes)
            (for/fold ([md (dist2d-fl ux uy ecx ecy)]) ([cl (in-list enemy-cluster-axes)])
              (flmin md (dist2d-fl ux uy (vector-ref cl 0) (vector-ref cl 1))))
            (dist2d-fl ux uy ecx ecy)))
      (define near-fight? (or (= ecnt 0) (fl<= d-e 26.0)))
      (define loc-ally? (or (= ecnt 0) (fl<= d-e 28.0)))
      ;; Include live-combat ranged units down to `3.5t` so in-combat concave widening has slots
      (define in-approach? (and (> ecnt 0) (fl>= d-e 3.5) (fl<= d-e 18.5)))
      (define is-pcore? (and (memq canon PROTOSS-CORE-SYMS) #t))
      (define is-zcore? (and (memq canon ZERG-CORE-SYMS) #t))
      (define is-zdur? (and near-fight? (memq canon ZERG-DURABLE-FRONT-SYMS) #t))
      (values (add1 ac) (fl+ asx ux) (fl+ asy uy) (fl+ astr (rec-supply-weight u))
              (if loc-ally? (add1 lac) lac)
              (if loc-ally? (fl+ lasx ux) lasx)
              (if loc-ally? (fl+ lasy uy) lasy)
              (if (and near-fight? (memq canon PROTOSS-FRONT-SYMS)) (add1 pfc) pfc)
              (if (and near-fight? (memq canon PROTOSS-FRONT-SYMS)) (fl+ pfx ux) pfx)
              (if (and near-fight? (memq canon PROTOSS-FRONT-SYMS)) (fl+ pfy uy) pfy)
              (if (and near-fight? (memq canon TERRAN-FRONT-SYMS)) (add1 tfc) tfc)
              (if (and near-fight? (memq canon TERRAN-FRONT-SYMS)) (fl+ tfx ux) tfx)
              (if (and near-fight? (memq canon TERRAN-FRONT-SYMS)) (fl+ tfy uy) tfy)
              (if (and near-fight? (memq canon ZERG-FRONT-SYMS)) (add1 zfc) zfc)
              (if (and near-fight? (memq canon ZERG-FRONT-SYMS)) (fl+ zfx ux) zfx)
              (if (and near-fight? (memq canon ZERG-FRONT-SYMS)) (fl+ zfy uy) zfy)
              (if is-zdur? (add1 zdc) zdc)
              (if is-zdur? (fl+ zdx ux) zdx)
              (if is-zdur? (fl+ zdy uy) zdy)
              (if (memq canon TERRAN-BIO-SYMS) (add1 tbc) tbc)
              (if (memq canon TERRAN-BIO-SYMS) (fl+ tbx ux) tbx)
              (if (memq canon TERRAN-BIO-SYMS) (fl+ tby uy) tby)
              (if (and near-fight? is-pcore?) (add1 pcc) pcc)
              (if (and near-fight? is-pcore?) (fl+ pcx ux) pcx)
              (if (and near-fight? is-pcore?) (fl+ pcy uy) pcy)
              (if is-pcore? (add1 pcca) pcca)
              (if is-pcore? (fl+ pcxa ux) pcxa)
              (if is-pcore? (fl+ pcya uy) pcya)
              (if (and near-fight? is-zcore?) (add1 zcc) zcc)
              (if (and near-fight? is-zcore?) (fl+ zcx ux) zcx)
              (if (and near-fight? is-zcore?) (fl+ zcy uy) zcy)
              (if is-zcore? (add1 zcca) zcca)
              (if is-zcore? (fl+ zcxa ux) zcxa)
              (if is-zcore? (fl+ zcya uy) zcya)
              (or brk? (and near-fight? (not (not (memq canon ZERG-UPHILL-BREAKER-SYMS)))))
              (or all-brk? (and near-fight? (not (not (memq canon ALL-RACE-UPHILL-BREAKER-SYMS)))))
              (if (and in-approach? (memq canon RANGED-CONCAVE-SYMS)) (cons u rng) rng)
              (if (and in-approach? (memq canon ZERG-SURROUND-SYMS)) (cons u zsr) zsr))))

  (define acx (cond [(> loc-ac 0) (fl/ loc-asx (exact->inexact loc-ac))]
                    [(> acnt 0)   (fl/ asx (exact->inexact acnt))]
                    [else         (fl- ecx 10.0)]))
  (define acy (cond [(> loc-ac 0) (fl/ loc-asy (exact->inexact loc-ac))]
                    [(> acnt 0)   (fl/ asy (exact->inexact acnt))]
                    [else         ecy]))
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
  ;; Anchor Zerg frontline to durable tanks (Roach/Ultralisk/Baneling) when >= 2 near the fight
  ;; so fast flanking Zerglings never pull z-front-proj forward and expose Hydralisks/Ravagers!
  (define eff-zfc (if (>= zdc 2) zdc zfc))
  (define zfcx (cond [(>= zdc 2) (fl/ zdx (exact->inexact zdc))]
                     [(> zfc 0)  (fl/ zfx (exact->inexact zfc))]
                     [else acx]))
  (define zfcy (cond [(>= zdc 2) (fl/ zdy (exact->inexact zdc))]
                     [(> zfc 0)  (fl/ zfy (exact->inexact zfc))]
                     [else acy]))
  (define tbcx (if (> tbc 0) (fl/ tbx (exact->inexact tbc)) acx))
  (define tbcy (if (> tbc 0) (fl/ tby (exact->inexact tbc)) acy))
  (define eff-pcc (if (> pcc 0) pcc pcc-all))
  (define eff-pcx (cond [(> pcc 0) (fl/ pcx (exact->inexact pcc))]
                        [(> pcc-all 0) (fl/ pcx-all (exact->inexact pcc-all))]
                        [else acx]))
  (define eff-pcy (cond [(> pcc 0) (fl/ pcy (exact->inexact pcc))]
                        [(> pcc-all 0) (fl/ pcy-all (exact->inexact pcc-all))]
                        [else acy]))
  (define eff-zcc (if (> zcc 0) zcc zcc-all))
  (define eff-zcx (cond [(> zcc 0) (fl/ zcx (exact->inexact zcc))]
                        [(> zcc-all 0) (fl/ zcx-all (exact->inexact zcc-all))]
                        [else acx]))
  (define eff-zcy (cond [(> zcc 0) (fl/ zcy (exact->inexact zcc))]
                        [(> zcc-all 0) (fl/ zcy-all (exact->inexact zcc-all))]
                        [else acy]))

  ;; Loop 65 Gap C1: Lower ranged concave minimum squad size `6 -> 4`
  (define ranged-ht
    (if (>= (length ranged-list) 4)
        (build-lateral-slot-table ranged-list ecx ecy perp-ux perp-uy)
        (hasheqv)))
  ;; Per-cluster ranged slot tables when >= 2 spatially distinct enemy fronts exist
  (define cluster-ranged-ht
    (if (and (>= (length enemy-cluster-axes) 2) (>= (length ranged-list) 4))
        (let ([out (make-hasheqv)]
              [buckets (make-vector (length enemy-cluster-axes) '())])
          (for ([u (in-list ranged-list)])
            (define ux (rec-x u 0.0))
            (define uy (rec-y u 0.0))
            (define best-i
              (for/fold ([bi 0] [bd +inf.0] #:result bi)
                        ([cl (in-list enemy-cluster-axes)]
                         [i (in-naturals)])
                (define d (dist2d-fl ux uy (vector-ref cl 0) (vector-ref cl 1)))
                (if (fl< d bd) (values i d) (values bi bd))))
            (vector-set! buckets best-i (cons u (vector-ref buckets best-i))))
          (for ([cl (in-list enemy-cluster-axes)]
                [i (in-naturals)])
            (define us (vector-ref buckets i))
            (when (>= (length us) 3)
              (define sub-ht
                (build-lateral-slot-table us
                                          (vector-ref cl 0) (vector-ref cl 1)
                                          (vector-ref cl 8) (vector-ref cl 9)))
              (for ([(uid sl) (in-hash sub-ht)])
                (hash-set! out uid sl))))
          out)
        ranged-ht))
  (define zerg-surr-ht
    (if (>= (length zerg-surr-list) 8)
        (build-lateral-slot-table zerg-surr-list ecx ecy perp-ux perp-uy)
        (hasheqv)))

  ;; Identify ranged units genuinely body-blocked in a back row behind >= 2 closer
  ;; friendly combat units along their local combat axis (so single-line squads never
  ;; scatter away from clean `'attack-unit` focus-fire coalescing!).
  (define ally-xy-vecs
    (for/list ([u (in-list (or combat-units '()))]
               #:when (rec-xy? u))
      (vector (rec-id u) (rec-x u 0.0) (rec-y u 0.0))))
  (define blocked-back-row-set
    (if (and (> ecnt 0) (>= (length ranged-list) 4))
        (for/fold ([s (seteqv)]) ([u (in-list ranged-list)])
          (define uid (rec-id u))
          (define ux (rec-x u 0.0))
          (define uy (rec-y u 0.0))
          (define-values (lfux lfuy lpux lpuy)
            (let ([best-cl
                   (and (pair? enemy-cluster-axes) (pair? (cdr enemy-cluster-axes))
                        (for/fold ([bc #f] [bd +inf.0] #:result bc) ([cl (in-list enemy-cluster-axes)])
                          (define d (dist2d-fl ux uy (vector-ref cl 0) (vector-ref cl 1)))
                          (if (fl< d bd) (values cl d) (values bc bd))))])
              (if best-cl
                  (values (vector-ref best-cl 6) (vector-ref best-cl 7)
                          (vector-ref best-cl 8) (vector-ref best-cl 9))
                  (values fwd-ux fwd-uy perp-ux perp-uy))))
          (define ahead-cnt
            (for/sum ([av (in-list ally-xy-vecs)]
                      #:when (not (= (vector-ref av 0) uid)))
              (define dx (fl- (vector-ref av 1) ux))
              (define dy (fl- (vector-ref av 2) uy))
              (define fwd-d (fl+ (fl* dx lfux) (fl* dy lfuy)))
              (define lat-d (flabs (fl+ (fl* dx lpux) (fl* dy lpuy))))
              (if (and (fl>= fwd-d 0.8) (fl<= fwd-d 6.0) (fl<= lat-d 2.5)) 1 0)))
          (if (>= ahead-cnt 2) (set-add s uid) s))
        (seteqv)))

  (define ctx-out
    (combat-pos-ctx
     ecnt ecx ecy fwd-ux fwd-uy perp-ux perp-uy
     pfc pfcx pfcy (proj pfcx pfcy)
     tfc tfcx tfcy (proj tfcx tfcy)
     eff-zfc zfcx zfcy (proj zfcx zfcy)
     tbc tbcx tbcy
     eff-pcc eff-pcx eff-pcy
     eff-zcc eff-zcx eff-zcy
     air-pts splash-pts uphill-siege
     has-breaker?
     (if (fl> e-str 0.01) (fl/ a-str e-str) 99.0)
     ranged-ht zerg-surr-ht
     mw mh))
  (hash-set! pos-ctx-extra-table ctx-out
             (hasheq 'enemy-cluster-axes enemy-cluster-axes
                     'cluster-ranged-ht cluster-ranged-ht
                     'blocked-back-row-set blocked-back-row-set
                     'all-elev-enemies all-elev-enemies
                     'ally-has-all-race-breaker? has-all-race-breaker?))
  ctx-out)

;; Per-cluster combat axis lookup: returns `(values ecx ecy fwd-ux fwd-uy perp-ux perp-uy)`
;; oriented to the nearest active enemy cluster to `(ux, uy)` (falls back to global axis).
(define (compute-local-cluster-axis pos-ctx ux uy)
  (cond
    [(not (combat-pos-ctx? pos-ctx))
     (values 100.0 100.0 1.0 0.0 0.0 1.0)]
    [else
     (define ex (pos-ctx-extra pos-ctx))
     (define cls (and (hash? ex) (hash-ref ex 'enemy-cluster-axes '())))
     (cond
       [(and (pair? cls) (pair? (cdr cls)))
        (define fux0 (fl->safe ux (combat-pos-ctx-enemy-cx pos-ctx)))
        (define fuy0 (fl->safe uy (combat-pos-ctx-enemy-cy pos-ctx)))
        (define best-cl
          (for/fold ([bc #f] [bd +inf.0] #:result bc) ([cl (in-list cls)])
            (define d (dist2d-fl fux0 fuy0 (vector-ref cl 0) (vector-ref cl 1)))
            (if (fl< d bd) (values cl d) (values bc bd))))
        (if best-cl
            (values (vector-ref best-cl 0) (vector-ref best-cl 1)
                    (vector-ref best-cl 6) (vector-ref best-cl 7)
                    (vector-ref best-cl 8) (vector-ref best-cl 9))
            (values (combat-pos-ctx-enemy-cx pos-ctx) (combat-pos-ctx-enemy-cy pos-ctx)
                    (combat-pos-ctx-fwd-ux pos-ctx) (combat-pos-ctx-fwd-uy pos-ctx)
                    (combat-pos-ctx-perp-ux pos-ctx) (combat-pos-ctx-perp-uy pos-ctx)))]
       [else
        (values (combat-pos-ctx-enemy-cx pos-ctx) (combat-pos-ctx-enemy-cy pos-ctx)
                (combat-pos-ctx-fwd-ux pos-ctx) (combat-pos-ctx-fwd-uy pos-ctx)
                (combat-pos-ctx-perp-ux pos-ctx) (combat-pos-ctx-perp-uy pos-ctx))])]))

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
        ;; Never hold an anti-air unit behind ground-only frontliners when enemy air attackers are within 16t!
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
;; 2. All-Race Caster Rear Leash (`-2.0..-3.5t` behind Race Frontline / Core)
;; =============================================================================
;; Keeps Terran (`medivac`, `raven`, `ghost`), Protoss (`high-templar`, `sentry`,
;; `disruptor`, `colossus`), and Zerg (`infestor`, `viper`, unburrowed `lurker`)
;; tethered `-2.0..-3.5t` behind their race's frontline/combat core along the
;; enemy-facing axis so high-value casters NEVER drift in front of meatshields!
;; Returns `(values leash-x leash-y)` or `(values #f #f)`.

(define (compute-caster-rear-leash-pt pos-ctx u
                                      #:rear-dist [rear-dist 2.5]
                                      #:max-ahead-tol [max-ahead-tol #f]
                                      #:enemy-fallback-x [efx #f]
                                      #:enemy-fallback-y [efy #f])
  (cond
    [(not (combat-pos-ctx? pos-ctx))
     (values #f #f)]
    [else
     (define raw-sym (rec-raw-sym u))
     (define sym (sc2-canonical-unit-sym raw-sym))
     (define burrowed?
       (and (hash? u)
            (or (memq raw-sym '(lurker-burrowed lurker-mp-burrowed infestor-burrowed))
                (eq? (hash-ref u 'burrowed #f) #t)
                (eq? (hash-ref u 'is-burrowed #f) #t))))
     (define-values (anchor-cnt bcx bcy)
       (cond
         [(memq sym TERRAN-CASTER-SYMS)
          (if (>= (combat-pos-ctx-t-bio-cnt pos-ctx) 2)
              (values (combat-pos-ctx-t-bio-cnt pos-ctx)
                      (combat-pos-ctx-t-bio-cx pos-ctx)
                      (combat-pos-ctx-t-bio-cy pos-ctx))
              (values (combat-pos-ctx-t-front-cnt pos-ctx)
                      (combat-pos-ctx-t-front-cx pos-ctx)
                      (combat-pos-ctx-t-front-cy pos-ctx)))]
         [(memq sym PROTOSS-CASTER-SYMS)
          (if (>= (combat-pos-ctx-p-front-cnt pos-ctx) 2)
              (values (combat-pos-ctx-p-front-cnt pos-ctx)
                      (combat-pos-ctx-p-front-cx pos-ctx)
                      (combat-pos-ctx-p-front-cy pos-ctx))
              (values (combat-pos-ctx-p-core-cnt pos-ctx)
                      (combat-pos-ctx-p-core-cx pos-ctx)
                      (combat-pos-ctx-p-core-cy pos-ctx)))]
         [(and (not burrowed?) (memq sym ZERG-CASTER-SYMS))
          (if (>= (combat-pos-ctx-z-front-cnt pos-ctx) 2)
              (values (combat-pos-ctx-z-front-cnt pos-ctx)
                      (combat-pos-ctx-z-front-cx pos-ctx)
                      (combat-pos-ctx-z-front-cy pos-ctx))
              (values (combat-pos-ctx-z-core-cnt pos-ctx)
                      (combat-pos-ctx-z-core-cx pos-ctx)
                      (combat-pos-ctx-z-core-cy pos-ctx)))]
         [else (values 0 0.0 0.0)]))
     (cond
       [(< anchor-cnt 2)
        (values #f #f)]
       [else
        (define ux (rec-x u 0.0))
        (define uy (rec-y u 0.0))
        (define d-bio (dist2d-fl ux uy bcx bcy))
        (cond
          [(fl> d-bio 18.0)
           ;; Far across the map (e.g. separate drop/scout): do not yank back
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
                             [(memq sym '(raven high-templar disruptor infestor viper)) -0.5]
                             [(eq? sym 'colossus) 0.0]
                             [(memq sym '(sentry lurker lurker-mp)) 0.2]
                             [else 1.0]))
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
               [(memq sym '(high-templar disruptor))
                (and (fl> caster-proj tol)
                     (fl> d-enemy 6.0))]
               [(eq? sym 'sentry)
                ;; Loop 65B (`#1861`/`#1862`): Exempt energy-ready Sentries (`>= 50` energy) inside
                ;; `<= 11.5t` unless drifting `> 1.2t` ahead of core, so Force Field (`<= 9.0t`) fires!
                (define s-en (fl->safe (hash-ref u 'energy 50.0) 50.0))
                (and (fl> d-enemy 6.5)
                     (or (fl> caster-proj 1.2)
                         (and (fl> caster-proj tol)
                              (or (fl> d-enemy 11.5)
                                  (fl< s-en 50.0)))))]
               [(memq sym '(infestor viper))
                (and (fl> caster-proj tol)
                     (fl> d-enemy 6.5))]
               [(eq? sym 'colossus)
                (and (fl> caster-proj tol)
                     (fl> d-enemy 8.0))]
               [(memq sym '(lurker lurker-mp))
                (and (not burrowed?)
                     (fl> caster-proj tol)
                     (fl> d-enemy 9.0))]
               [else #f]))
           (if needs-leash?
               (values lx ly)
               (values #f #f))])])]))

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
;; 3c. All-Race Uphill Ramp Brake (Protoss, Terran & Zerg)
;; =============================================================================
;; Holds non-flying ground combat units outside an uphill ramp/cliff (`sz - uz >= 1.5`)
;; guarded by entrenched uphill siege (`15.0t` standoff) OR high-ground enemy combat
;; (`>= 2` uphill units, `11.5t` standoff) when we lack high-ground vision/breakers
;; and lack overwhelming strength (`< 1.55x`). Flat ground ALWAYS returns `(values #f #f)`!

(define (all-race-uphill-ramp-hold-pt pos-ctx u
                                      #:high-ground-vision? [hg-vision? #f]
                                      #:strength-ratio [str-ratio-arg #f])
  (cond
    [(or (not (combat-pos-ctx? pos-ctx))
         (not (hash? u))
         (rec-flying? u))
     (values #f #f)]
    [else
     (define sym (rec-canon-sym u))
     (define uz (rec-z u))
     (define eff-str
       (if (real? str-ratio-arg)
           (fl->safe str-ratio-arg 1.0)
           (combat-pos-ctx-ally-strength-ratio pos-ctx)))
     (define ex-meta (pos-ctx-extra pos-ctx))
     (define has-breaker?
       (or (combat-pos-ctx-ally-has-uphill-breaker? pos-ctx)
           (and (hash? ex-meta) (hash-ref ex-meta 'ally-has-all-race-breaker? #f))))
     (cond
       [(or (not uz)
            (not (memq sym ALL-RACE-GROUND-HOLD-SYMS))
            (fl>= eff-str 1.55))
        (values #f #f)]
       [else
        (define ux (rec-x u 0.0))
        (define uy (rec-y u 0.0))
        ;; 1. Entrenched uphill siege (Tank/Lurker) holds unless we have breakers
        (define-values (best-sv best-sd)
          (if has-breaker?
              (values #f +inf.0)
              (for/fold ([bs #f] [bd +inf.0])
                        ([sv (in-list (combat-pos-ctx-enemy-uphill-siege pos-ctx))])
                (define sx (vector-ref sv 0))
                (define sy (vector-ref sv 1))
                (define sz (vector-ref sv 2))
                (if (fl>= (fl- sz uz) 1.5)
                    (let ([d (dist2d-fl ux uy sx sy)])
                      (if (and (fl>= d 5.5) (fl<= d 16.5) (fl< d bd))
                          (values sv d)
                          (values bs bd)))
                    (values bs bd)))))
        ;; 2. General uphill high-ground enemy combat (`>= 2` uphill units within `15.5t`)
        ;;    holds when we lack high-ground vision and lack overwhelming advantage
        (define all-ev (if (hash? ex-meta) (hash-ref ex-meta 'all-elev-enemies '()) '()))
        (define-values (up-cnt up-sx up-sy best-ud)
          (if (or best-sv hg-vision?)
              (values 0 0.0 0.0 +inf.0)
              (for/fold ([c 0] [sx 0.0] [sy 0.0] [bd +inf.0])
                        ([ev (in-list all-ev)])
                (define ex (vector-ref ev 0))
                (define ey (vector-ref ev 1))
                (define ez (vector-ref ev 2))
                (if (fl>= (fl- ez uz) 1.5)
                    (let ([d (dist2d-fl ux uy ex ey)])
                      (if (fl<= d 15.5)
                          (values (add1 c) (fl+ sx ex) (fl+ sy ey) (flmin bd d))
                          (values c sx sy bd)))
                    (values c sx sy bd)))))
        (cond
          [best-sv
           (define sx (vector-ref best-sv 0))
           (define sy (vector-ref best-sv 1))
           (define dx (fl- ux sx))
           (define dy (fl- uy sy))
           (define dn (flmax 0.1 (flsqrt (fl+ (fl* dx dx) (fl* dy dy)))))
           (define hold-r 15.0)
           (values (clamp-fl (fl+ sx (fl* hold-r (fl/ dx dn)))
                             4.0 (fl- (combat-pos-ctx-map-w pos-ctx) 4.0))
                   (clamp-fl (fl+ sy (fl* hold-r (fl/ dy dn)))
                             4.0 (fl- (combat-pos-ctx-map-h pos-ctx) 4.0)))]
          [(and (>= up-cnt 2) (fl>= best-ud 5.5) (fl<= best-ud 15.0))
           (define sx (fl/ up-sx (exact->inexact up-cnt)))
           (define sy (fl/ up-sy (exact->inexact up-cnt)))
           (define dx (fl- ux sx))
           (define dy (fl- uy sy))
           (define dn (flmax 0.1 (flsqrt (fl+ (fl* dx dx) (fl* dy dy)))))
           (define hold-r 11.5)
           (values (clamp-fl (fl+ sx (fl* hold-r (fl/ dx dn)))
                             4.0 (fl- (combat-pos-ctx-map-w pos-ctx) 4.0))
                   (clamp-fl (fl+ sy (fl* hold-r (fl/ dy dn)))
                             4.0 (fl- (combat-pos-ctx-map-h pos-ctx) 4.0)))]
          [else (values #f #f)])])]))

;; =============================================================================
;; 4. Pre-Contact & In-Combat Lateral Concave Widening (Per-Cluster Axis)
;; =============================================================================
;; For ranged squads (`>= 4` units) approaching OR actively fighting (`3.5..16.5t`):
;;   - Uses per-cluster combat axis `(ecx, ecy, fwd-ux, fwd-uy, perp-ux, perp-uy)`
;;     so split-front squads each form an accurate concave facing their own clash.
;;   - Outside weapon range (`d-tgt > wr + 1.0`): natural (`2.2..6.0t`) or anti-splash
;;     (`3.0..8.5t`) concave fan-out.
;;   - Inside combat (`wr - 1.5 <= d-tgt <= wr + 1.0`): widens ONLY while unit is
;;     between shots (`weapon-cooldown > 0.1`) so ready shots are NEVER cancelled,
;;     stepping back-row units smoothly into an active concave arc!
;; Returns `(values ax ay)` or `(values #f #f)`.

(define (rec-weapon-cooldown u)
  (if (hash? u)
      (fl->safe (hash-ref u 'weapon-cooldown (hash-ref u 'weapon_cooldown 0.0)) 0.0)
      0.0))

(define (compute-lateral-concave-spread-pt pos-ctx u target-x target-y weapon-range
                                           #:in-combat-step? [in-combat-step? #f])
  (cond
    [(or (not (combat-pos-ctx? pos-ctx))
         (= (combat-pos-ctx-enemy-cnt pos-ctx) 0))
     (values #f #f)]
    [else
     (define uid (rec-id u))
     (define ex-meta (pos-ctx-extra pos-ctx))
     (define cl-ht (and (hash? ex-meta) (hash-ref ex-meta 'cluster-ranged-ht #f)))
     (define slot
       (or (and (hash? cl-ht) (hash-ref cl-ht uid #f))
           (hash-ref (combat-pos-ctx-ranged-slot-ht pos-ctx) uid #f)))
     (cond
       [(not (pair? slot)) (values #f #f)]
       [else
        (define ux (rec-x u 0.0))
        (define uy (rec-y u 0.0))
        (define-values (ecx ecy fux fuy pux puy) (compute-local-cluster-axis pos-ctx ux uy))
        (define d-ec (dist2d-fl ux uy ecx ecy))
        (define ftx (fl->safe target-x ecx))
        (define fty (fl->safe target-y ecy))
        (define d-tgt (dist2d-fl ux uy ftx fty))
        (define wr (fl->safe weapon-range 5.0))
        (define wcd (rec-weapon-cooldown u))
        (define splash-near?
          (let ([spts (combat-pos-ctx-enemy-splash-pts pos-ctx)])
            (and (pair? spts)
                 (for/or ([sp (in-list spts)])
                   (fl<= (dist2d-fl ux uy (car sp) (cdr sp)) 18.0)))))
        (define outside-range? (fl> d-tgt (fl+ wr 1.0)))
        (define in-combat-between-shots?
          (and in-combat-step?
               (not outside-range?)
               (fl> wcd 0.10)
               (fl>= d-tgt (flmax 3.0 (fl- wr 1.5)))))
        (define min-ec-d (if in-combat-step? 3.5 6.5))
        (cond
          [(or (fl< d-ec min-ec-d)
               (fl> d-ec 16.5)
               (and (not outside-range?) (not in-combat-between-shots?))
               (and (eq? (rec-canon-sym u) 'roach) (not splash-near?)))
           (values #f #f)]
          [else
           (define idx (car slot))
           (define tot (cdr slot))
           ;; Normalized slot `t` in `[-1.0, +1.0]`
           (define t (if (> tot 1)
                         (fl- (fl* 2.0 (fl/ (exact->inexact idx) (exact->inexact (- tot 1)))) 1.0)
                         0.0))
           ;; Wider anti-splash spread (`3.0..8.5t`) vs natural max-DPS concave (`2.2..6.0t`)
           (define half-span
             (if splash-near?
                 (clamp-fl (fl* 1.20 (exact->inexact (- tot 1))) 3.0 8.5)
                 (clamp-fl (fl* 0.82 (exact->inexact (- tot 1))) 2.2 6.0)))
           (define lat-target (fl* t half-span))
           (define cur-lat (fl+ (fl* (fl- ux ecx) pux) (fl* (fl- uy ecy) puy)))
           (define lat-deadband (if in-combat-between-shots? 1.5 1.0))
           (if (fl< (flabs (fl- cur-lat lat-target)) lat-deadband)
               (values #f #f)
               (let* ([standoff
                       (if in-combat-between-shots?
                           (flmax 3.5 (flmin (fl+ wr 0.25) (flmax (fl- wr 0.5) d-ec)))
                           (flmax (fl+ wr 0.25) (fl- d-ec 2.0)))]
                      ;; Outer wings curve forward into a concave arc (`1.4t` natural / `1.2t` splash)
                      [arc-fwd (fl* (if splash-near? 1.2 1.4) (fl* t t))]
                      [base-x (fl- ecx (fl* (fl- standoff arc-fwd) fux))]
                      [base-y (fl- ecy (fl* (fl- standoff arc-fwd) fuy))]
                      [ax (clamp-fl (fl+ base-x (fl* lat-target pux))
                                    4.0 (fl- (combat-pos-ctx-map-w pos-ctx) 4.0))]
                      [ay (clamp-fl (fl+ base-y (fl* lat-target puy))
                                    4.0 (fl- (combat-pos-ctx-map-h pos-ctx) 4.0))])
                 (values ax ay)))])])]))

;; Dedicated in-combat concave widening wrapper: ONLY widens ranged units that are
;; genuinely body-blocked in a back row behind >= 2 front-row allies (never scatters
;; clean single-row squads away from `'attack-unit` focus-fire coalescing!), stepping
;; laterally when out of weapon range (`d-tgt > wr`) OR between shots (`wcd > 0.10`).
(define (compute-in-combat-concave-step-pt pos-ctx u target-x target-y weapon-range)
  (cond
    [(or (not (combat-pos-ctx? pos-ctx))
         (not (hash? u)))
     (values #f #f)]
    [else
     (define ex-meta (pos-ctx-extra pos-ctx))
     (define blk-set (and (hash? ex-meta) (hash-ref ex-meta 'blocked-back-row-set #f)))
     (if (and (set? blk-set) (set-member? blk-set (rec-id u)))
         (compute-lateral-concave-spread-pt pos-ctx u target-x target-y weapon-range
                                            #:in-combat-step? #t)
         (values #f #f))]))

;; =============================================================================
;; 4b. Defensive Pre-Arc Crescent (`pre-arc-hold` / `regroup-stage`)
;; =============================================================================
;; Positions staging/defending combat units into a front-to-back concave crescent
;; around `(anchor-x, anchor-y)` facing `(facing-x, facing-y)` so incoming pushes
;; walk INTO a pre-built surround instead of our army clumping in a ball.
;; Returns `(values ax ay)` or `(values #f #f)` when already within `1.2t` of slot.

(define (compute-defensive-pre-arc-pt pos-ctx u
                                      #:anchor-x anchor-x
                                      #:anchor-y anchor-y
                                      #:facing-x facing-x
                                      #:facing-y facing-y
                                      #:arc-radius [arc-r 6.5]
                                      #:slot-index [slot-idx #f]
                                      #:slot-total [slot-tot #f]
                                      #:map-width [mw-arg #f]
                                      #:map-height [mh-arg #f]
                                      #:pathable? [pathable? #f])
  (cond
    [(not (and (hash? u) (rec-xy? u)))
     (values #f #f)]
    [else
     (define sym (rec-canon-sym u))
     (define uid (rec-id u))
     (define ux (rec-x u 0.0))
     (define uy (rec-y u 0.0))
     (define ax0 (fl->safe anchor-x ux))
     (define ay0 (fl->safe anchor-y uy))
     (define fx0 (fl->safe facing-x (fl+ ax0 10.0)))
     (define fy0 (fl->safe facing-y ay0))
     (define dx (fl- fx0 ax0))
     (define dy (fl- fy0 ay0))
     (define dn (flmax 0.1 (flsqrt (fl+ (fl* dx dx) (fl* dy dy)))))
     (define fux (fl/ dx dn))
     (define fuy (fl/ dy dn))
     (define pux (fl- fuy))
     (define puy fux)
     (define mw (if (real? mw-arg)
                    (fl->safe mw-arg 200.0)
                    (if (combat-pos-ctx? pos-ctx) (combat-pos-ctx-map-w pos-ctx) 200.0)))
     (define mh (if (real? mh-arg)
                    (fl->safe mh-arg 200.0)
                    (if (combat-pos-ctx? pos-ctx) (combat-pos-ctx-map-h pos-ctx) 200.0)))
     (define slot-pair
       (cond
         [(and (exact-integer? slot-idx) (exact-integer? slot-tot) (> slot-tot 0))
          (cons (max 0 (min (- slot-tot 1) slot-idx)) slot-tot)]
         [(and (combat-pos-ctx? pos-ctx)
               (hash-ref (combat-pos-ctx-ranged-slot-ht pos-ctx) uid #f))
          => values]
         [else
          (cons (modulo (abs uid) 9) 9)]))
     (define idx (car slot-pair))
     (define tot (max 1 (cdr slot-pair)))
     (define t (if (> tot 1)
                   (fl- (fl* 2.0 (fl/ (exact->inexact idx) (exact->inexact (- tot 1)))) 1.0)
                   0.0))
     ;; Front-to-back depth layering along the defensive crescent:
     ;; melee/durable tank rim (`+1.5t`), ranged core (`0.0t`), casters/heavy rear (`-2.5t`)
     (define depth-offset
       (cond
         [(or (memq sym PROTOSS-FRONT-SYMS)
              (memq sym TERRAN-FRONT-SYMS)
              (memq sym ZERG-FRONT-SYMS))
          1.5]
         [(or (memq sym PROTOSS-CASTER-SYMS)
              (memq sym TERRAN-CASTER-SYMS)
              (memq sym ZERG-CASTER-SYMS)
              (memq sym PROTOSS-HEAVY-BACK-SYMS))
          -2.5]
         [else 0.0]))
     (define base-r (flmax 3.0 (fl->safe arc-r 6.5)))
     (define half-span (clamp-fl (fl* 0.85 (exact->inexact (max 3 tot))) 3.5 7.5))
     (define lat (fl* t half-span))
     ;; Wings curve forward (`+2.2t * t^2`) toward approaching enemy to form a true concave pocket
     (define fwd (fl+ (fl+ base-r depth-offset) (fl* 2.2 (fl* t t))))
     (define px (clamp-fl (fl+ ax0 (fl+ (fl* fwd fux) (fl* lat pux))) 4.0 (fl- mw 4.0)))
     (define py (clamp-fl (fl+ ay0 (fl+ (fl* fwd fuy) (fl* lat puy))) 4.0 (fl- mh 4.0)))
     (cond
       [(fl<= (dist2d-fl ux uy px py) 1.2)
        (values #f #f)]
       [(and (procedure? pathable?) (not (pathable? px py)))
        (values #f #f)]
       [else
        (values px py)])]))

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

;; Loop 65C (`#1874`/`#1875`): Detect Stimpack-buffed Marines/Marauders (`'stimpack`,
;; `'stimpack-marauder`, buff IDs `27`/`24`) so self-inflicted Stim HP loss NEVER
;; triggers blind-uphill retreat!
(define (rec-stimmed? u)
  (and (hash? u)
       (or (eq? (hash-ref u 'stimpack? #f) #t)
           (eq? (hash-ref u 'stimmed? #f) #t)
           (let ([has-stim?
                  (lambda (xs)
                    (and (list? xs)
                         (ormap (lambda (b)
                                  (or (eq? b 'stimpack)
                                      (eq? b 'stimpack-marauder)
                                      (eq? b 'stim)
                                      (eqv? b 27)
                                      (eqv? b 24)))
                                xs)))])
             (or (has-stim? (hash-ref u 'buffs #f))
                 (has-stim? (hash-ref u 'buff-ids #f)))))))

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
         (rec-flying? u)
         (rec-stimmed? u))
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
       ;; Loop 65C (`#1874`/`#1875`): STRICT `(and took-damage? uphill-gap?)` — NEVER fire on flat ground!
       [(not (and took-damage? uphill-gap?))
        (values #f #f)]
       [else
        (define ux (rec-x u 0.0))
        (define uy (rec-y u 0.0))
        (define wr (fl->safe weapon-range 5.5))
        ;; Loop 65D (`#1891`/`#1892`): Widen visible-enemy sightline scan to `>= 16.5t`
        ;; and reject distant uphill hints `> 16.0t` away!
        (define scan-r (flmax 16.5 (fl+ wr 3.0)))
        (define uphill-hint-too-far?
          (and (real? uphill-tx)
               (real? uphill-ty)
               (fl> (dist2d-fl ux uy (fl->safe uphill-tx ux) (fl->safe uphill-ty uy)) 16.0)))
        ;; If ANY visible non-snapshot enemy is already within firing sightline, fight — NEVER pull back!
        (define visible-in-range?
          (for/or ([e (in-list (if (list? enemy-units) enemy-units '()))])
            (and (rec-xy? e)
                 (not (rec-snapshot? e))
                 (not (memq (rec-canon-sym e) NON-COMBAT-IGNORE-SYMS))
                 (fl<= (dist2d-fl ux uy (rec-x e 0.0) (rec-y e 0.0)) scan-r))))
        (cond
          [(or visible-in-range? uphill-hint-too-far?) (values #f #f)]
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

;; Multi-race High-Ground Vision Dispatcher (Loop 65C `#1874`/`#1875` — dedicated vision units ONLY):
;;   - Protoss: cliff-edge `observer` / `observer-siege-mode`, or Sentry `hallucination-phoenix` (154, >= 75E)
;;   - Terran : cliff-edge `viking-fighter` / `raven`, or OC `scanner-sweep` (399, >= 50E)
;;   - Zerg   : cliff-edge `changeling*` / `overlord` / `overseer`
;; NEVER leases transports/harassers/combat air (`warp-prism`, `medivac`, `oracle`, `phoenix`, `banshee`, `mutalisk`).
;; Keeps air spotters perched at a safe cliff-edge standoff (`4.0t`, pushed to `7.0t` if visible AA sits nearby).
(define HIGH-GROUND-AA-THREAT-SYMS
  '(marine ghost thor thor-ap viking-fighter cyclone missile-turret widow-mine widow-mine-burrowed
    stalker phoenix archon void-ray tempest carrier photon-cannon sentry
    hydralisk queen mutalisk corruptor spore-crawler))

(define (spotter-rank-for-race race sym)
  (case race
    [(Protoss protoss)
     (cond [(memq sym '(observer observer-siege-mode)) 1]
           [else #f])]
    [(Terran terran)
     (cond [(memq sym '(viking viking-fighter)) 1]
           [(eq? sym 'raven) 2]
           [else #f])]
    [(Zerg zerg)
     (cond [(memq sym '(changeling changeling-zealot changeling-marine changeling-marine-shield
                        changeling-zergling changeling-zergling-wings)) 1]
           [(eq? sym 'overlord) 2]
           [(memq sym '(overseer overseer-siege-mode)) 3]
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
