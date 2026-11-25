#lang racket/base

;; =============================================================================
;; `lib/tactics/staging-groups.rkt`
;; Generalized Safe-Rally Control-Group Staging & Dynamic Rally-Point Selection
;;
;; Unifies rally/staging across all 3 races (Zerg, Terran, Protoss) and 4 domains
;; (`'air`, `'ground-front`, `'ground-flank`, `'drop`):
;;   - Dynamic symmetry-agnostic safe staging point selection across all 4 map corners
;;     (NW/NE/SW/SE), BFS-pathability-checked for ground domains, obstacle/mineral
;;     cleared (`>= 3.0t`), anchor-smoothed (`4.5t`), never tied to any single tech building.
;;   - Stateful control-group lifecycle (`'staging -> 'dispatched -> 'regrouping`)
;;     with hysteresis (`>= 75%` cohesion, `min-dwell` `64..112f`, `< 0.55x` / `< 45%` HP
;;     regroup trigger).
;;   - Unified staging families:
;;       * `'air-anti-cap`    : Corruptor / Viking / Void-Ray anti-capital-air volley packs
;;       * `'air-harass`      : Phoenix / Mutalisk / Oracle / Banshee packs
;;       * `'ground-harass`   : Zergling / Hellion / Adept / Reaper runby packs
;;       * `'main-reinforce`  : `7.5s` (`168f`) wave batching for newly spawned home ground
;;                              reinforcements when frontline is `> 30t` away or counter-staging
;;   - All 5 Hard Safety Overrides:
;;       1. Emergency Home-Defense Scramble (releases staging groups when home base/miners
;;          are attacked, while protecting `< 6` Corruptors from suiciding into `>= 3` Tempests)
;;       2. In-Contact Reflex (staging unit within `14t` / `16.5t` vs Tempests commits if
;;          local strength `>= 0.70x` or actively retreats away if `< 0.55x`)
;;       3. Production-Aware Anti-Stall + Endgame Override (`ENDGAME_HOME_STALL = 0`:
;;          immediate force-dispatch on endgame hunt, enemy main cleared, decisive victory,
;;          `supply >= 165`, `>= 1.50x` army dominance, or `max-wait` with 0 in production)
;;       4. Live Full-Match Gate Only (automatically bypassed in isolated micro skirmishes)
;;       5. Order Discipline & Role Leases (ground staging uses `attack-pos` only; throttled
;;          `20f` / `3.5t` re-issue; acquires `'staging-group` prio 50 / `'strike-group` prio 55)
;; =============================================================================

(require racket/flonum
         racket/list
         racket/math
         racket/set
         (only-in "../sc2-game-constants.rkt"
                  unit-role-lease?
                  unit-role-lease-role
                  acquire-unit-lease!
                  unit-leased-above?
                  sc2-canonical-unit-sym
                  sc2-supply-cost))

(provide
 (struct-out staging-group)
 (struct-out staging-group-manager)
 (struct-out staging-step-result)
 STAGE-MUSTER-COMMIT-RATIO
 STAGE-MUSTER-RETREAT-RATIO
 make-staging-group-manager
 staging-group-manager-reset!
 staging-live-full-match-eligible?
 pick-safe-staging-point
 pick-safe-fallback-point
 step-staging-groups!
 staging-group-handled-tags)

;; =============================================================================
;; Constants
;; =============================================================================

(define STAGE-OBSTACLE-MIN-CLEARANCE 3.0)
(define STAGE-ENEMY-SAFE-RADIUS 16.0)
(define STAGE-ENEMY-CAP-AIR-SAFE-RADIUS 18.5)
(define STAGE-SMOOTH-DRIFT-THRESH 4.5)
(define STAGE-ORDER-THROTTLE-FRAMES 20)
(define STAGE-ORDER-DRIFT-THRESH 3.5)
(define STAGE-COHESION-RADIUS 10.0)
(define STAGE-AT-ANCHOR-RADIUS 12.0)
(define STAGE-COHESION-RATIO 0.75)
(define STAGE-IN-CONTACT-RADIUS 14.0)
(define STAGE-TEMPEST-CONTACT-RADIUS 18.0)
(define STAGE-COMMIT-STRENGTH-RATIO 0.70)
(define STAGE-RETREAT-STRENGTH-RATIO 0.55)
(define STAGE-MUSTER-COMMIT-RATIO 0.95)
(define STAGE-MUSTER-RETREAT-RATIO 0.78)
(define STAGE-REGROUP-DROP-RATIO 0.55)
(define STAGE-REGROUP-HP-RATIO 0.45)
(define STAGE-HOME-REINFORCE-RADIUS 24.0)
(define STAGE-FRONTLINE-SEPARATION-RADIUS 30.0)
(define STAGE-REINFORCE-MAX-WAIT-FRAMES 168)
(define STAGE-NO-PROD-MAX-WAIT-FRAMES 112)
(define STAGE-ZERG-REINFORCE-MAX-WAIT-FRAMES 96)
(define STAGE-ZERG-NO-PROD-MAX-WAIT-FRAMES 64)
(define STAGE-PROTOSS-REINFORCE-MAX-WAIT-FRAMES 268)
(define STAGE-PROTOSS-NO-PROD-MAX-WAIT-FRAMES 180)
(define STAGE-LEASE-TTL-FRAMES 44)
(define STAGE-STRIKE-LEASE-TTL-FRAMES 112)

(define TOWNHALL-SYMS
  '(command-center orbital-command planetary-fortress
    hatchery lair hive
    nexus))

(define DEFENSIVE-ANCHOR-SYMS
  '(shield-battery bunker photon-cannon spine-crawler spore-crawler planetary-fortress
    siege-tank-sieged lurker-burrowed lurker-mp-burrowed liberator-ag))

(define PRODUCTION-BLDG-SYMS
  '(hatchery lair hive spire greater-spire spawning-pool roach-warren baneling-nest hydralisk-den
    barracks factory starport
    gateway warp-gate robotics-facility stargate))

(define CAP-AIR-SYMS
  '(tempest carrier battlecruiser mothership brood-lord broodlord))

(define WORKER-SYMS '(scv probe drone mule))

(define NON-REINFORCE-STAGING-SYMS
  '(scv probe drone mule larva egg
    overlord overlord-cocoon overlord-transport overlord-transport-cocoon
    overseer overseer-siege-mode observer observer-siege-mode
    warp-prism warp-prism-phasing medivac queen
    high-templar infestor infestor-burrowed viper disruptor disruptor-phased raven
    carrier tempest battlecruiser mothership brood-lord broodlord swarm-host swarm-host-mp
    siege-tank siege-tank-sieged widow-mine widow-mine-burrowed
    lurker lurker-mp lurker-burrowed lurker-mp-burrowed liberator liberator-ag
    corruptor phoenix mutalisk oracle banshee viking viking-fighter
    zergling hellion adept reaper colossus))

(define AIR-DOMAIN-UNIT-SYMS
  '(corruptor phoenix mutalisk oracle banshee viking viking-fighter void-ray voidray
    tempest carrier battlecruiser liberator medivac warp-prism raven viper))

;; =============================================================================
;; Data Structures
;; =============================================================================

(struct staging-group
  (id
   domain
   state            ;; 'staging | 'dispatched | 'regrouping
   stage-x
   stage-y
   member-tags      ;; immutable seteqv of integer tags
   commit-size      ;; member count at last dispatch for < 0.55x attrition check
   formed-frame
   last-state-frame
   last-order-frame
   last-order-x
   last-order-y)
  #:mutable #:transparent)

(struct staging-group-manager
  (groups           ;; mutable hasheq: group-id -> staging-group
   unit->group      ;; mutable hasheqv: uid -> group-id
   unit-first-seen  ;; mutable hasheqv: uid -> frame
   last-frame)      ;; box integer
  #:transparent)

(struct staging-step-result
  (active?
   actions           ;; list of action sexps: '(move uid x y) or '(attack-pos uid x y)
   preserved-actions ;; high-priority survival retreat actions (e.g. Corruptor vs Tempests)
   handled-tags      ;; seteqv of uids currently controlled by staging/regrouping
   dispatched-groups ;; list of group-ids currently in 'dispatched
   staging-groups    ;; list of group-ids currently in 'staging or 'regrouping
   anchors)          ;; immutable hasheq: group-id -> (cons sx sy)
  #:transparent)

(define (make-staging-group-manager)
  (staging-group-manager (make-hasheq)
                         (make-hasheqv)
                         (make-hasheqv)
                         (box -1)))

(define (staging-group-manager-reset! mgr)
  (hash-clear! (staging-group-manager-groups mgr))
  (hash-clear! (staging-group-manager-unit->group mgr))
  (hash-clear! (staging-group-manager-unit-first-seen mgr))
  (set-box! (staging-group-manager-last-frame mgr) -1)
  (void))

(define (staging-group-handled-tags res)
  (if (staging-step-result? res)
      (staging-step-result-handled-tags res)
      (seteqv)))

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

(define (rec-type-sym u)
  (cond
    [(hash? u)
     (define raw (hash-ref u 'type 'unknown))
     (cond
       [(symbol? raw) (sc2-canonical-unit-sym raw)]
       [(string? raw) (sc2-canonical-unit-sym (string->symbol (string-downcase raw)))]
       [else 'unknown])]
    [(symbol? u) (sc2-canonical-unit-sym u)]
    [else 'unknown]))

(define (rec-raw-type-sym u)
  (cond
    [(hash? u)
     (define raw (hash-ref u 'type 'unknown))
     (cond
       [(symbol? raw) raw]
       [(string? raw) (string->symbol (string-downcase raw))]
       [else 'unknown])]
    [(symbol? u) u]
    [else 'unknown]))

(define (rec-id u)
  (if (hash? u)
      (let ([v (hash-ref u 'id -1)])
        (if (exact-integer? v) v -1))
      -1))

(define (rec-x u fallback)
  (if (hash? u) (fl->safe (hash-ref u 'x fallback) fallback) (exact->inexact fallback)))

(define (rec-y u fallback)
  (if (hash? u) (fl->safe (hash-ref u 'y fallback) fallback) (exact->inexact fallback)))

(define (rec-xy? u)
  (and (hash? u)
       (real? (hash-ref u 'x #f))
       (real? (hash-ref u 'y #f))))

(define (rec-snapshot? u)
  (and (hash? u)
       (or (eq? (hash-ref u 'snapshot? #f) #t)
           (not (eqv? (hash-ref u 'display-type 1) 1)))))

(define (rec-hp-ratio u)
  (if (not (hash? u))
      1.0
      (let* ([hp (fl->safe (hash-ref u 'hp (hash-ref u 'health 100.0)) 100.0)]
             [sh (fl->safe (hash-ref u 'shields (hash-ref u 'shield 0.0)) 0.0)]
             [mhp (flmax 1.0 (fl->safe (hash-ref u 'max-hp (hash-ref u 'health-max hp)) (flmax 1.0 hp)))]
             [msh (flmax 0.0 (fl->safe (hash-ref u 'max-shields (hash-ref u 'shield-max sh)) sh))]
             [tot-max (flmax 1.0 (fl+ mhp msh))])
        (clamp-fl (fl/ (fl+ hp sh) tot-max) 0.0 1.0))))

(define (rec-unit-strength u)
  (define sym (rec-type-sym u))
  (cond
    [(memq sym '(larva egg changeling overlord observer overseer)) 0.0]
    [(memq sym WORKER-SYMS) 0.35]
    [else
     (let ([sup (exact->inexact (max 1 (sc2-supply-cost sym 1)))])
       (fl* sup (flmax 0.25 (rec-hp-ratio u))))]))

(define (rotate-vec vx vy angle-rad)
  (define c (flcos angle-rad))
  (define s (flsin angle-rad))
  (values (fl- (fl* vx c) (fl* vy s))
          (fl+ (fl* vx s) (fl* vy c))))

;; =============================================================================
;; Hard Safety Override #4: Live Full-Match Eligibility Gate
;; =============================================================================
;; Staging is ONLY enabled in live full matches (owned TownHall + economy/production).
;; Isolated Arena micro skirmishes (0 TownHalls, or 1 lone OC/Nexus with 0 workers and
;; 0 extra production buildings) bypass staging completely.

(define (staging-live-full-match-eligible? #:live-obs? live-obs?
                                           #:ally-buildings ally-buildings
                                           #:ally-units ally-units
                                           #:mineral-harvesters [mineral-harvesters 0]
                                           #:vespene-harvesters [vespene-harvesters 0])
  (and live-obs?
       (let* ([th-cnt
               (for/sum ([b (in-list (or ally-buildings '()))]
                         #:when (and (hash? b) (memq (rec-type-sym b) TOWNHALL-SYMS)))
                 1)]
              [prod-cnt
               (for/sum ([b (in-list (or ally-buildings '()))]
                         #:when (and (hash? b) (memq (rec-type-sym b) PRODUCTION-BLDG-SYMS)))
                 1)]
              [worker-cnt
               (for/sum ([u (in-list (or ally-units '()))]
                         #:when (and (hash? u) (memq (rec-type-sym u) WORKER-SYMS)))
                 1)])
         (and (>= th-cnt 1)
              (or (>= worker-cnt 1)
                  (>= (+ (if (exact-integer? mineral-harvesters) mineral-harvesters 0)
                         (if (exact-integer? vespene-harvesters) vespene-harvesters 0))
                      1)
                  (>= prod-cnt 2))))))

;; =============================================================================
;; Dynamic Symmetry-Agnostic Safe Staging Point Selection
;; =============================================================================

(define (extract-xy-pts recs [pred (lambda (_) #t)])
  (for/list ([r (in-list (or recs '()))]
             #:when (and (rec-xy? r) (not (rec-snapshot? r)) (pred r)))
    (cons (rec-x r 0.0) (rec-y r 0.0))))

(define (min-dist-to-pts px py pts)
  (for/fold ([md +inf.0]) ([pt (in-list pts)])
    (flmin md (dist2d-fl px py (car pt) (cdr pt)))))

(define (bfs-pathable? bfs-dist-fn px py)
  (if (not (procedure? bfs-dist-fn))
      #t
      (let ([d (bfs-dist-fn px py)])
        (and (real? d) (not (nan? d)) (not (infinite? d)) (< d 9000.0)))))

(define (pick-safe-staging-point
         #:domain domain
         #:ally-townhalls [ally-townhalls '()]
         #:ally-buildings [ally-buildings '()]
         #:mineral-patches [mineral-patches '()]
         #:enemy-units [enemy-units '()]
         #:enemy-anchor-x enemy-anchor-x
         #:enemy-anchor-y enemy-anchor-y
         #:base-x base-x
         #:base-y base-y
         #:nat-x nat-x
         #:nat-y nat-y
         #:third-x [third-x nat-x]
         #:third-y [third-y nat-y]
         #:map-width [map-w 200.0]
         #:map-height [map-h 200.0]
         #:prev-pt [prev-pt #f]
         #:bfs-dist-fn [bfs-dist-fn #f]
         #:enemy-capital-air? [enemy-cap-air? #f]
         #:flank-sign [flank-sign 1.0])
  (define mw (flmax 64.0 (fl->safe map-w 200.0)))
  (define mh (flmax 64.0 (fl->safe map-h 200.0)))
  (define air-domain? (or (eq? domain 'air) (eq? domain 'drop)))
  (define margin (if air-domain? 5.0 6.0))
  (define fbx (fl->safe base-x 32.5))
  (define fby (fl->safe base-y 32.5))
  (define fnx (fl->safe nat-x fbx))
  (define fny (fl->safe nat-y fby))
  (define f3x (fl->safe third-x fnx))
  (define f3y (fl->safe third-y fny))
  (define fex (fl->safe enemy-anchor-x (fl- mw fbx)))
  (define fey (fl->safe enemy-anchor-y (fl- mh fby)))

  (define th-pts
    (let ([pts (extract-xy-pts ally-townhalls)])
      (if (pair? pts) pts (list (cons fbx fby)))))
  (define enemy-pts
    (extract-xy-pts enemy-units
                    (lambda (e)
                      (not (memq (rec-type-sym e) '(larva egg changeling overlord observer))))))
  (define obstacle-pts
    (if air-domain?
        '()
        (append (extract-xy-pts ally-buildings)
                (extract-xy-pts mineral-patches))))

  (define safe-enemy-r (if enemy-cap-air? STAGE-ENEMY-CAP-AIR-SAFE-RADIUS STAGE-ENEMY-SAFE-RADIUS))

  ;; Choose base anchor dynamically relative to enemy vector (100% corner-symmetry-agnostic!)
  (define-values (anchor-x anchor-y dir-ux dir-uy radii angles)
    (case domain
      [(air)
       ;; Safest TownHall farthest from enemy, projected behind it away from enemy
       (define safe-th
         (for/fold ([best (car th-pts)]
                    [best-d (dist2d-fl (caar th-pts) (cdar th-pts) fex fey)]
                    #:result best)
                   ([p (in-list (cdr th-pts))])
           (define d (dist2d-fl (car p) (cdr p) fex fey))
           (if (fl> d best-d) (values p d) (values best best-d))))
       (define ax (car safe-th))
       (define ay (cdr safe-th))
       (define vx (fl- ax fex))
       (define vy (fl- ay fey))
       (define vd (flmax 1.0 (flsqrt (fl+ (fl* vx vx) (fl* vy vy)))))
       (values ax ay (fl/ vx vd) (fl/ vy vd)
               (if enemy-cap-air? '(18.5 22.0 26.0 15.5) '(14.0 17.0 11.5))
               (if enemy-cap-air?
                   '(0.0 0.48 -0.48 0.96 -0.96 1.50 -1.50 2.15 -2.15 3.14)
                   '(0.0 0.48 -0.48 0.96 -0.96)))]
      [(drop)
       ;; Rear-safe TownHall projected toward side map corridor away from enemy
       (define safe-th
         (for/fold ([best (car th-pts)]
                    [best-d (dist2d-fl (caar th-pts) (cdar th-pts) fex fey)]
                    #:result best)
                   ([p (in-list (cdr th-pts))])
           (define d (dist2d-fl (car p) (cdr p) fex fey))
           (if (fl> d best-d) (values p d) (values best best-d))))
       (define ax (car safe-th))
       (define ay (cdr safe-th))
       (define vx (fl- fex ax))
       (define vy (fl- fey ay))
       (define vd (flmax 1.0 (flsqrt (fl+ (fl* vx vx) (fl* vy vy)))))
       (define sgn (if (fl< (fl->safe flank-sign 1.0) 0.0) -1.0 1.0))
       ;; Blend 75% lateral edge + 25% rear away from enemy
       (define px (fl+ (fl* 0.75 (fl* sgn (fl/ (fl- vy) vd))) (fl* -0.25 (fl/ vx vd))))
       (define py (fl+ (fl* 0.75 (fl* sgn (fl/ vx vd))) (fl* -0.25 (fl/ vy vd))))
       (define pd (flmax 0.1 (flsqrt (fl+ (fl* px px) (fl* py py)))))
       (values ax ay (fl/ px pd) (fl/ py pd)
               '(12.0 15.0 9.0)
               '(0.0 0.40 -0.40 0.80 -0.80))]
      [(ground-flank)
       ;; Natural/forward safe anchor stepped laterally perpendicular to enemy vector
       (define nat-safe? (fl> (min-dist-to-pts fnx fny enemy-pts) 14.0))
       (define ax (if nat-safe? fnx fbx))
       (define ay (if nat-safe? fny fby))
       (define vx (fl- fex ax))
       (define vy (fl- fey ay))
       (define vd (flmax 1.0 (flsqrt (fl+ (fl* vx vx) (fl* vy vy)))))
       (define sgn (if (fl< (fl->safe flank-sign 1.0) 0.0) -1.0 1.0))
       (define fx (fl+ (fl* 0.82 (fl* sgn (fl/ (fl- vy) vd))) (fl* 0.35 (fl/ vx vd))))
       (define fy (fl+ (fl* 0.82 (fl* sgn (fl/ vx vd))) (fl* 0.35 (fl/ vy vd))))
       (define fd (flmax 0.1 (flsqrt (fl+ (fl* fx fx) (fl* fy fy)))))
       (values ax ay (fl/ fx fd) (fl/ fy fd)
               '(12.0 15.0 9.0)
               '(0.0 0.38 -0.38 0.76 -0.76))]
      [else ;; 'ground-front
       ;; Frontline safe expansion closest to enemy that is NOT besieged (> 14t from enemy)
       (define safe-ths
         (filter (lambda (p) (fl> (min-dist-to-pts (car p) (cdr p) enemy-pts) 14.0)) th-pts))
       (define front-pt
         (cond
           [(pair? safe-ths)
            (for/fold ([best (car safe-ths)]
                       [best-d (dist2d-fl (caar safe-ths) (cdar safe-ths) fex fey)]
                       #:result best)
                      ([p (in-list (cdr safe-ths))])
              (define d (dist2d-fl (car p) (cdr p) fex fey))
              (if (fl< d best-d) (values p d) (values best best-d)))]
           [(and (>= (length th-pts) 3) (fl> (min-dist-to-pts f3x f3y enemy-pts) 14.0))
            (cons f3x f3y)]
           [(fl> (min-dist-to-pts fnx fny enemy-pts) 14.0)
            (cons fnx fny)]
           [else
            (cons fbx fby)]))
       (define ax (car front-pt))
       (define ay (cdr front-pt))
       ;; If Natural/front is camped and we fell back to Main, aim toward Nat; else aim toward enemy
       (define aim-x (if (and (fl<= (dist2d-fl ax ay fbx fby) 4.0)
                              (fl<= (min-dist-to-pts fnx fny enemy-pts) 14.0))
                         fnx
                         fex))
       (define aim-y (if (and (fl<= (dist2d-fl ax ay fbx fby) 4.0)
                              (fl<= (min-dist-to-pts fnx fny enemy-pts) 14.0))
                         fny
                         fey))
       (define vx (fl- aim-x ax))
       (define vy (fl- aim-y ay))
       (define vd (flmax 1.0 (flsqrt (fl+ (fl* vx vx) (fl* vy vy)))))
       (values ax ay (fl/ vx vd) (fl/ vy vd)
               '(7.5 10.0 5.0)
               '(0.0 0.44 -0.44 0.88 -0.88))]))

  ;; Score 5-ray x 3-radius fan
  (define-values (best-x best-y _best-sc)
    (for/fold ([bx (clamp-fl (fl+ anchor-x (fl* (car radii) dir-ux)) margin (fl- mw margin))]
               [by (clamp-fl (fl+ anchor-y (fl* (car radii) dir-uy)) margin (fl- mh margin))]
               [bsc -1e18])
              ([r (in-list radii)])
      (for/fold ([bx2 bx] [by2 by] [bsc2 bsc])
                ([ang (in-list angles)])
        (define-values (rx ry) (rotate-vec dir-ux dir-uy ang))
        (define raw-cx (fl+ anchor-x (fl* r rx)))
        (define raw-cy (fl+ anchor-y (fl* r ry)))
        (define cx (clamp-fl raw-cx margin (fl- mw margin)))
        (define cy (clamp-fl raw-cy margin (fl- mh margin)))
        (define clamp-pen (fl* -4.0 (dist2d-fl raw-cx raw-cy cx cy)))
        (define path-ok? (or air-domain? (bfs-pathable? bfs-dist-fn cx cy)))
        (define min-obs-d (if (null? obstacle-pts) 99.0 (min-dist-to-pts cx cy obstacle-pts)))
        (define min-e-d (if (null? enemy-pts) 99.0 (min-dist-to-pts cx cy enemy-pts)))
        (define d-from-enemy (dist2d-fl cx cy fex fey))
        (define sc
          (fl+ clamp-pen
               (fl+ (if path-ok? 0.0 -500.0)
                    (fl+ (if (and (not air-domain?) (fl< min-obs-d STAGE-OBSTACLE-MIN-CLEARANCE))
                             (fl* -120.0 (fl- STAGE-OBSTACLE-MIN-CLEARANCE min-obs-d))
                             (flmin 6.0 min-obs-d))
                         (fl+ (if (fl< min-e-d safe-enemy-r)
                                  (fl* -25.0 (fl- safe-enemy-r min-e-d))
                                  (flmin 24.0 min-e-d))
                              (fl+ (fl* -3.0 (flabs ang))
                                   (if air-domain?
                                       (fl* 0.12 (flmin 60.0 d-from-enemy))
                                       0.0)))))))
        (if (fl> sc bsc2)
            (values cx cy sc)
            (values bx2 by2 bsc2)))))

  ;; Anchor Smoothing: hold `prev-pt` unless unsafe, unpathable, or drifted `> 4.5t`
  (cond
    [(and (pair? prev-pt) (real? (car prev-pt)) (real? (cdr prev-pt)))
     (define px (clamp-fl (fl->safe (car prev-pt) best-x) margin (fl- mw margin)))
     (define py (clamp-fl (fl->safe (cdr prev-pt) best-y) margin (fl- mh margin)))
     (define prev-e-d (if (null? enemy-pts) 99.0 (min-dist-to-pts px py enemy-pts)))
     (define prev-obs-d (if (null? obstacle-pts) 99.0 (min-dist-to-pts px py obstacle-pts)))
     (define prev-safe?
       (and (fl>= prev-e-d safe-enemy-r)
            (or air-domain?
                (and (bfs-pathable? bfs-dist-fn px py)
                     (fl>= prev-obs-d STAGE-OBSTACLE-MIN-CLEARANCE)))))
     (if (and prev-safe? (fl<= (dist2d-fl px py best-x best-y) STAGE-SMOOTH-DRIFT-THRESH))
         (cons px py)
         (cons best-x best-y))]
    [else
     (cons best-x best-y)]))

;; =============================================================================
;; Generalized Situational Pull-Back / Fallback Anchor (`pick-safe-fallback-point`)
;; Loop 64 P0 #1 (`#1724`): 100% map/race/corner-agnostic situational fallback
;; scoring all 1..N owned TownHalls, static defense & siege anchors, safe ally
;; reinforcement centroids, local mid-map disengage offsets, and interior chokes.
;; =============================================================================

(define (rec-complete? r)
  (or (not (hash? r))
      (fl>= (fl->safe (hash-ref r 'build-progress 1.0) 1.0) 0.999)))

(define (rec-z-opt r)
  (and (hash? r)
       (let ([z (hash-ref r 'z #f)])
         (and (real? z) (not (nan? z)) (not (infinite? z)) (exact->inexact z)))))

;; Count visible enemies lying within `r-block` of the interior (`0.12 < t < 0.92`)
;; of the escape segment `(gx, gy) -> (cx, cy)` (anti-flank trap detection).
(define (escape-segment-blocking-count gx gy cx cy enemy-pts [r-block 8.5])
  (define dx (fl- cx gx))
  (define dy (fl- cy gy))
  (define len2 (fl+ (fl* dx dx) (fl* dy dy)))
  (if (fl<= len2 4.0)
      0
      (let ([r2 (fl* r-block r-block)])
        (for/sum ([ep (in-list enemy-pts)])
          (define ex (car ep))
          (define ey (cdr ep))
          (define t (fl/ (fl+ (fl* (fl- ex gx) dx) (fl* (fl- ey gy) dy)) len2))
          (if (and (fl> t 0.12) (fl< t 0.92))
              (let* ([px (fl+ gx (fl* t dx))]
                     [py (fl+ gy (fl* t dy))]
                     [ddx (fl- ex px)]
                     [ddy (fl- ey py)])
                (if (fl<= (fl+ (fl* ddx ddx) (fl* ddy ddy)) r2) 1 0))
              0)))))

(define (pick-safe-fallback-point
         #:domain [domain 'ground]
         #:group-x group-x
         #:group-y group-y
         #:threat-x threat-x
         #:threat-y threat-y
         #:severity [severity 'muster]
         #:ally-townhalls [ally-townhalls '()]
         #:ally-buildings [ally-buildings '()]
         #:ally-units [ally-units '()]
         #:mineral-patches [mineral-patches '()]
         #:enemy-units [enemy-units '()]
         #:base-x base-x
         #:base-y base-y
         #:nat-x nat-x
         #:nat-y nat-y
         #:map-width [map-w 200.0]
         #:map-height [map-h 200.0]
         #:prev-pt [prev-pt #f]
         #:bfs-dist-fn [bfs-dist-fn #f]
         #:enemy-capital-air? [enemy-cap-air? #f]
         #:group-z [group-z #f])
  (define mw (flmax 64.0 (fl->safe map-w 200.0)))
  (define mh (flmax 64.0 (fl->safe map-h 200.0)))
  (define air-domain? (or (eq? domain 'air) (eq? domain 'drop)))
  (define margin (if air-domain? 5.0 6.0))
  (define fgx (fl->safe group-x (fl->safe nat-x 32.5)))
  (define fgy (fl->safe group-y (fl->safe nat-y 32.5)))
  (define ftx (fl->safe threat-x (fl- mw fgx)))
  (define fty (fl->safe threat-y (fl- mh fgy)))
  (define fbx (fl->safe base-x 32.5))
  (define fby (fl->safe base-y 32.5))
  (define fnx (fl->safe nat-x fbx))
  (define fny (fl->safe nat-y fby))

  (define th-recs
    (if (pair? ally-townhalls)
        (filter (lambda (b) (and (rec-xy? b) (not (rec-snapshot? b)))) ally-townhalls)
        (filter (lambda (b) (and (rec-xy? b) (not (rec-snapshot? b)) (memq (rec-type-sym b) TOWNHALL-SYMS)))
                (or ally-buildings '()))))
  (define has-owned-th? (pair? th-recs))
  ;; Loop 76 P0: When 0 owned TownHalls exist (skirmish / base-eliminated), NEVER fall back
  ;; to distant corner `(base-x, base-y)` (`32.5, 32.5`). Compute a bounded `6.5t` disengage
  ;; away from `(threat-x, threat-y)` blended tangentially away from arena edges `[10, mw-10]`.
  (define zero-th-edge (flmin 10.0 (fl* 0.25 (flmin mw mh))))
  (define-values (zero-th-ux zero-th-uy zero-th-pt)
    (if has-owned-th?
        (values 0.0 0.0 (cons fbx fby))
        (let* ([adx (fl- fgx ftx)]
               [ady (fl- fgy fty)]
               [ad (flsqrt (fl+ (fl* adx adx) (fl* ady ady)))]
               [mcx (fl* 0.5 mw)]
               [mcy (fl* 0.5 mh)]
               [cdx (fl- mcx fgx)]
               [cdy (fl- mcy fgy)]
               [cd (flmax 1.0 (flsqrt (fl+ (fl* cdx cdx) (fl* cdy cdy))))]
               [aux (if (fl> ad 0.1) (fl/ adx ad) (fl/ cdx cd))]
               [auy (if (fl> ad 0.1) (fl/ ady ad) (fl/ cdy cd))]
               [raw-x (fl+ fgx (fl* 6.5 aux))]
               [raw-y (fl+ fgy (fl* 6.5 auy))]
               [near-edge?
                (or (fl< raw-x zero-th-edge) (fl> raw-x (fl- mw zero-th-edge))
                    (fl< raw-y zero-th-edge) (fl> raw-y (fl- mh zero-th-edge))
                    (fl< fgx (fl+ zero-th-edge 4.0)) (fl> fgx (fl- mw (fl+ zero-th-edge 4.0)))
                    (fl< fgy (fl+ zero-th-edge 4.0)) (fl> fgy (fl- mh (fl+ zero-th-edge 4.0))))]
               [bux-raw
                (if near-edge?
                    (let* ([t1x (fl- auy)] [t1y aux]
                           [t2x auy] [t2y (fl- aux)]
                           [d1 (fl+ (fl* t1x cdx) (fl* t1y cdy))]
                           [d2 (fl+ (fl* t2x cdx) (fl* t2y cdy))]
                           [tx (if (fl>= d1 d2) t1x t2x)])
                      (fl+ (fl* 0.35 aux) (fl* 0.65 tx)))
                    aux)]
               [buy-raw
                (if near-edge?
                    (let* ([t1x (fl- auy)] [t1y aux]
                           [t2x auy] [t2y (fl- aux)]
                           [d1 (fl+ (fl* t1x cdx) (fl* t1y cdy))]
                           [d2 (fl+ (fl* t2x cdx) (fl* t2y cdy))]
                           [ty (if (fl>= d1 d2) t1y t2y)])
                      (fl+ (fl* 0.35 auy) (fl* 0.65 ty)))
                    auy)]
               [bn (flmax 0.01 (flsqrt (fl+ (fl* bux-raw bux-raw) (fl* buy-raw buy-raw))))]
               [bux (fl/ bux-raw bn)]
               [buy (fl/ buy-raw bn)]
               [px (clamp-fl (fl+ fgx (fl* 6.5 bux)) zero-th-edge (fl- mw zero-th-edge))]
               [py (clamp-fl (fl+ fgy (fl* 6.5 buy)) zero-th-edge (fl- mh zero-th-edge))])
          (values bux buy (cons px py)))))
  (define th-pts
    (if has-owned-th?
        (for/list ([b (in-list th-recs)]) (cons (rec-x b fbx) (rec-y b fby)))
        (list zero-th-pt)))

  (define enemy-pts
    (extract-xy-pts enemy-units
                    (lambda (e)
                      (not (memq (rec-type-sym e) '(larva egg changeling overlord observer overseer))))))
  (define threat-z
    (let-values ([(sz cnt)
                  (for/fold ([s 0.0] [c 0]) ([e (in-list (or enemy-units '()))])
                    (define ez (rec-z-opt e))
                    (if (and ez (not (memq (rec-type-sym e) '(larva egg changeling overlord observer overseer))))
                        (values (fl+ s ez) (+ c 1))
                        (values s c)))])
      (cond
        [(> cnt 0) (fl/ sz (exact->inexact cnt))]
        [(and (real? group-z) (not (nan? group-z)) (not (infinite? group-z))) (exact->inexact group-z)]
        [else #f])))

  (define obstacle-pts
    (if air-domain?
        '()
        (append (extract-xy-pts ally-buildings)
                (extract-xy-pts mineral-patches))))

  ;; Defensive cover anchors (completed static D + sieged tanks/lurkers/liberators)
  (define def-anchor-recs
    (append
     (filter (lambda (b)
               (and (rec-xy? b) (not (rec-snapshot? b)) (rec-complete? b)
                    (memq (rec-type-sym b) DEFENSIVE-ANCHOR-SYMS)))
             (or ally-buildings '()))
     (filter (lambda (u)
               (and (rec-xy? u) (not (rec-snapshot? u))
                    (memq (rec-type-sym u) DEFENSIVE-ANCHOR-SYMS)))
             (or ally-units '()))))
  (define def-anchor-pts
    (for/list ([d (in-list def-anchor-recs)]) (cons (rec-x d fbx) (rec-y d fby))))

  ;; Safe ally combat reinforcement cluster (combat allies outside 14t of threat & > 12t of enemies)
  (define group-threat-d (dist2d-fl fgx fgy ftx fty))
  (define safe-ally-pts
    (for/list ([u (in-list (or ally-units '()))]
               #:when (and (rec-xy? u) (not (rec-snapshot? u))
                           (not (memq (rec-type-sym u) '(scv probe drone larva egg overlord observer overseer changeling)))
                           (let ([ux (rec-x u 0.0)] [uy (rec-y u 0.0)])
                             ;; Only count SEPARATE reinforcement allies (> 12t from group and further
                             ;; from threat than the group itself) so Pool 3 never selects the group's
                             ;; own standing centroid as its "fallback" point!
                             (and (fl> (dist2d-fl ux uy fgx fgy) 12.0)
                                  (fl> (dist2d-fl ux uy ftx fty) (flmax 14.0 (fl+ group-threat-d 4.0)))
                                  (fl> (min-dist-to-pts ux uy enemy-pts) 12.0)))))
      (cons (rec-x u 0.0) (rec-y u 0.0))))

  (define safe-enemy-r (if enemy-cap-air? STAGE-ENEMY-CAP-AIR-SAFE-RADIUS STAGE-ENEMY-SAFE-RADIUS))
  (define travel-w
    (case severity
      [(skirmish) 0.85]
      [(severe)   0.35]
      [else       0.50]))

  ;; Helper: build candidate tuple `(vector cx cy raw-cx raw-cy hg-bonus?)`
  (define cands-rev '())
  (define (add-cand! raw-cx raw-cy [hg? #f])
    (define cx (clamp-fl raw-cx margin (fl- mw margin)))
    (define cy (clamp-fl raw-cy margin (fl- mh margin)))
    (set! cands-rev (cons (vector cx cy raw-cx raw-cy hg?) cands-rev)))

  ;; Pool 1: All live owned TownHalls 1..N (5.0t behind each TH away from threat).
  ;; When 0 owned THs exist, use bounded 6.5t tangential-blended disengage arc instead of corner `(fbx, fby)`!
  (cond
    [has-owned-th?
     (for ([th (in-list th-recs)])
       (define thx (rec-x th fbx))
       (define thy (rec-y th fby))
       (define thz (rec-z-opt th))
       (define th-hg? (and thz threat-z (fl>= (fl- thz threat-z) 0.5)))
       (define vx (fl- thx ftx))
       (define vy (fl- thy fty))
       (define vd (flmax 1.0 (flsqrt (fl+ (fl* vx vx) (fl* vy vy)))))
       (define ux (fl/ vx vd))
       (define uy (fl/ vy vd))
       (for ([ang (in-list '(0.0 0.55 -0.55))])
         (define-values (rx ry) (rotate-vec ux uy ang))
         (add-cand! (fl+ thx (fl* 5.0 rx)) (fl+ thy (fl* 5.0 ry)) th-hg?)))]
    [else
     (for ([ang (in-list '(0.0 0.45 -0.45 0.90 -0.90))])
       (define-values (rx ry) (rotate-vec zero-th-ux zero-th-uy ang))
       (define cx (clamp-fl (fl+ fgx (fl* 6.5 rx)) zero-th-edge (fl- mw zero-th-edge)))
       (define cy (clamp-fl (fl+ fgy (fl* 6.5 ry)) zero-th-edge (fl- mh zero-th-edge)))
       (set! cands-rev (cons (vector cx cy (fl+ fgx (fl* 6.5 rx)) (fl+ fgy (fl* 6.5 ry)) #f) cands-rev)))])

  ;; Pool 2: Friendly static defense & siege anchor cover (3.5t behind away from threat)
  (for ([da (in-list def-anchor-recs)])
    (define dax (rec-x da fbx))
    (define day (rec-y da fby))
    (when (or has-owned-th? (fl<= (dist2d-fl fgx fgy dax day) 10.0))
      (define daz (rec-z-opt da))
      (define da-hg? (and daz threat-z (fl>= (fl- daz threat-z) 0.5)))
      (define vx (fl- dax ftx))
      (define vy (fl- day fty))
      (define vd (flmax 1.0 (flsqrt (fl+ (fl* vx vx) (fl* vy vy)))))
      (define ux (fl/ vx vd))
      (define uy (fl/ vy vd))
      (add-cand! (fl+ dax (fl* 3.5 ux)) (fl+ day (fl* 3.5 uy)) da-hg?)))

  ;; Pool 3: Safe friendly reinforcement cluster centroid (>= 4 safe allies)
  (define safe-ally-centroid #f)
  (when (and has-owned-th? (>= (length safe-ally-pts) 4))
    (define n-sa (exact->inexact (length safe-ally-pts)))
    (define-values (scx scy)
      (for/fold ([sx 0.0] [sy 0.0] #:result (values (fl/ sx n-sa) (fl/ sy n-sa)))
                ([p (in-list safe-ally-pts)])
        (values (fl+ sx (car p)) (fl+ sy (cdr p)))))
    (set! safe-ally-centroid (cons scx scy))
    (add-cand! scx scy #f)
    (define vx (fl- scx ftx))
    (define vy (fl- scy fty))
    (define vd (flmax 1.0 (flsqrt (fl+ (fl* vx vx) (fl* vy vy)))))
    (add-cand! (fl+ scx (fl* 3.5 (fl/ vx vd))) (fl+ scy (fl* 3.5 (fl/ vy vd))) #f))

  ;; Pool 4: Mid-map tactical disengage offset (14/18/22t along 65% away + 35% toward safe anchor)
  (define min-group-th-d (min-dist-to-pts fgx fgy th-pts))
  (when (and has-owned-th? (eq? severity 'skirmish) (fl> min-group-th-d 26.0))
    ;; Pick nearest safe TH (or safe ally centroid if closer)
    (define safe-home-pt
      (let* ([safe-ths (filter (lambda (p) (fl> (min-dist-to-pts (car p) (cdr p) enemy-pts) 14.0)) th-pts)]
             [pool (append safe-ths (if safe-ally-centroid (list safe-ally-centroid) '()))]
             [use-pool (if (pair? pool) pool th-pts)])
        (for/fold ([best (car use-pool)]
                   [bd (dist2d-fl fgx fgy (caar use-pool) (cdar use-pool))]
                   #:result best)
                  ([p (in-list (cdr use-pool))])
          (define d (dist2d-fl fgx fgy (car p) (cdr p)))
          (if (fl< d bd) (values p d) (values best bd)))))
    (define adx (fl- fgx ftx))
    (define ady (fl- fgy fty))
    (define ad (flmax 1.0 (flsqrt (fl+ (fl* adx adx) (fl* ady ady)))))
    (define hdx (fl- (car safe-home-pt) fgx))
    (define hdy (fl- (cdr safe-home-pt) fgy))
    (define hd (flmax 1.0 (flsqrt (fl+ (fl* hdx hdx) (fl* hdy hdy)))))
    (define bxv (fl+ (fl* 0.65 (fl/ adx ad)) (fl* 0.35 (fl/ hdx hd))))
    (define byv (fl+ (fl* 0.65 (fl/ ady ad)) (fl* 0.35 (fl/ hdy hd))))
    (define bn (flmax 0.01 (flsqrt (fl+ (fl* bxv bxv) (fl* byv byv)))))
    (define bux (fl/ bxv bn))
    (define buy (fl/ byv bn))
    (for ([r (in-list '(14.0 18.0 22.0))])
      (for ([ang (in-list '(0.0 0.45 -0.45))])
        (define-values (rx ry) (rotate-vec bux buy ang))
        (add-cand! (fl+ fgx (fl* r rx)) (fl+ fgy (fl* r ry)) #f))))

  ;; Pool 5: Interior high-ground / main ramp choke (5.0t from base toward nat, 0 / +/- 0.45 rad)
  (when has-owned-th?
    (let* ([dx (fl- fnx fbx)]
           [dy (fl- fny fby)]
           [d (flmax 1.0 (flsqrt (fl+ (fl* dx dx) (fl* dy dy))))]
           [step (flmin 5.0 (fl* 0.35 d))]
           [ux (fl/ dx d)]
           [uy (fl/ dy d)]
           [main-hg? (or (eq? severity 'severe)
                         (fl<= (min-dist-to-pts fnx fny enemy-pts) 18.0))])
      (for ([ang (in-list '(0.0 0.45 -0.45))])
        (define-values (rx ry) (rotate-vec ux uy ang))
        (add-cand! (fl+ fbx (fl* step rx)) (fl+ fby (fl* step ry)) main-hg?))))

  (define (score-fallback-cand cx cy raw-cx raw-cy hg?)
    (define clamp-pen (fl* -4.0 (dist2d-fl raw-cx raw-cy cx cy)))
    (define path-ok? (or air-domain? (bfs-pathable? bfs-dist-fn cx cy)))
    (define min-obs-d (if (null? obstacle-pts) 99.0 (min-dist-to-pts cx cy obstacle-pts)))
    (define min-e-d (if (null? enemy-pts) 99.0 (min-dist-to-pts cx cy enemy-pts)))
    (define blk-cnt (escape-segment-blocking-count fgx fgy cx cy enemy-pts 8.5))
    (define def-cnt
      (for/sum ([dp (in-list def-anchor-pts)])
        (if (fl<= (dist2d-fl cx cy (car dp) (cdr dp)) 8.0) 1 0)))
    (define ally-cnt
      (for/sum ([ap (in-list safe-ally-pts)])
        (if (fl<= (dist2d-fl cx cy (car ap) (cdr ap)) 10.0) 1 0)))
    (define travel-d (dist2d-fl fgx fgy cx cy))
    (fl+ clamp-pen
         (fl+ (if path-ok? 0.0 -500.0)
              (fl+ (if (and (not air-domain?) (fl< min-obs-d STAGE-OBSTACLE-MIN-CLEARANCE))
                       (fl* -120.0 (fl- STAGE-OBSTACLE-MIN-CLEARANCE min-obs-d))
                       (flmin 6.0 min-obs-d))
                   (fl+ (if (fl< min-e-d safe-enemy-r)
                            (fl* -25.0 (fl- safe-enemy-r min-e-d))
                            (flmin 20.0 (fl* 0.8 (fl- min-e-d safe-enemy-r))))
                        (fl+ (fl* -90.0 (exact->inexact blk-cnt))
                             (fl+ (flmin 66.0 (fl* 22.0 (exact->inexact def-cnt)))
                                  (fl+ (flmin 32.0 (fl* 4.0 (exact->inexact ally-cnt)))
                                       (fl+ (if hg? 18.0 0.0)
                                            (fl* (fl- travel-w) travel-d))))))))))

  (define init-bx (if has-owned-th? (clamp-fl fbx margin (fl- mw margin)) (car zero-th-pt)))
  (define init-by (if has-owned-th? (clamp-fl fby margin (fl- mh margin)) (cdr zero-th-pt)))
  (define-values (best-x best-y _best-sc)
    (for/fold ([bx init-bx]
               [by init-by]
               [bsc -1e18])
              ([c (in-list cands-rev)])
      (define cx (vector-ref c 0))
      (define cy (vector-ref c 1))
      (define sc (score-fallback-cand cx cy (vector-ref c 2) (vector-ref c 3) (vector-ref c 4)))
      (if (fl> sc bsc)
          (values cx cy sc)
          (values bx by bsc))))

  ;; Hysteresis Smoothing: hold `prev-pt` unless unsafe, flank-blocked, unpathable, or drifted `> 4.5t`
  (cond
    [(and (pair? prev-pt) (real? (car prev-pt)) (real? (cdr prev-pt)))
     (define px (clamp-fl (fl->safe (car prev-pt) best-x) margin (fl- mw margin)))
     (define py (clamp-fl (fl->safe (cdr prev-pt) best-y) margin (fl- mh margin)))
     (define prev-e-d (if (null? enemy-pts) 99.0 (min-dist-to-pts px py enemy-pts)))
     (define prev-obs-d (if (null? obstacle-pts) 99.0 (min-dist-to-pts px py obstacle-pts)))
     (define prev-blk (escape-segment-blocking-count fgx fgy px py enemy-pts 8.5))
     (define prev-safe?
       (and (fl>= prev-e-d safe-enemy-r)
            (= prev-blk 0)
            (or air-domain?
                (and (bfs-pathable? bfs-dist-fn px py)
                     (fl>= prev-obs-d STAGE-OBSTACLE-MIN-CLEARANCE)))))
     (if (and prev-safe? (fl<= (dist2d-fl px py best-x best-y) STAGE-SMOOTH-DRIFT-THRESH))
         (cons px py)
         (cons best-x best-y))]
    [else
     (cons best-x best-y)]))

;; =============================================================================
;; Group Policy & State Machine (`'staging -> 'dispatched -> 'regrouping`)
;; =============================================================================

(define (unit-near-enemy-info u enemy-combat-recs)
  (define ux (rec-x u 0.0))
  (define uy (rec-y u 0.0))
  (for/fold ([min-d +inf.0] [near-x #f] [near-y #f] [near-tempest? #f] [e-str 0.0])
            ([e (in-list enemy-combat-recs)])
    (define ex (rec-x e 9999.0))
    (define ey (rec-y e 9999.0))
    (define d (dist2d-fl ux uy ex ey))
    (define esym (rec-type-sym e))
    (define is-temp? (eq? esym 'tempest))
    (define str-add (if (fl<= d 16.5) (rec-unit-strength e) 0.0))
    (if (fl< d min-d)
        (values d ex ey (or near-tempest? (and is-temp? (fl<= d STAGE-TEMPEST-CONTACT-RADIUS))) (fl+ e-str str-add))
        (values min-d near-x near-y (or near-tempest? (and is-temp? (fl<= d STAGE-TEMPEST-CONTACT-RADIUS))) (fl+ e-str str-add)))))

(define (local-ally-strength ux uy all-combat-units [radius 14.0])
  (for/fold ([s 0.0]) ([a (in-list all-combat-units)] #:when (rec-xy? a))
    (if (fl<= (dist2d-fl ux uy (rec-x a 9999.0) (rec-y a 9999.0)) radius)
        (fl+ s (rec-unit-strength a))
        s)))

(define (group-cohesion-ok? members sx sy)
  (define n (length members))
  (cond
    [(= n 0) #f]
    [(= n 1)
     (fl<= (dist2d-fl (rec-x (car members) sx) (rec-y (car members) sy) sx sy)
           STAGE-AT-ANCHOR-RADIUS)]
    [else
     (define-values (cx cy)
       (for/fold ([ax 0.0] [ay 0.0] #:result (values (fl/ ax (exact->inexact n))
                                                     (fl/ ay (exact->inexact n))))
                 ([u (in-list members)])
         (values (fl+ ax (rec-x u sx)) (fl+ ay (rec-y u sy)))))
     (define cohesive-cnt
       (for/sum ([u (in-list members)])
         (define ux (rec-x u sx))
         (define uy (rec-y u sy))
         (if (or (fl<= (dist2d-fl ux uy cx cy) STAGE-COHESION-RADIUS)
                 (fl<= (dist2d-fl ux uy sx sy) STAGE-AT-ANCHOR-RADIUS))
             1
             0)))
     (fl>= (fl/ (exact->inexact cohesive-cnt) (exact->inexact n))
           STAGE-COHESION-RATIO)]))

(define (group-avg-hp-ratio members)
  (define n (length members))
  (if (= n 0)
      1.0
      (fl/ (for/fold ([s 0.0]) ([u (in-list members)])
             (fl+ s (rec-hp-ratio u)))
           (exact->inexact n))))

(define (group-total-supply members)
  (for/sum ([u (in-list members)])
    (max 1 (sc2-supply-cost (rec-type-sym u) 1))))

(define (group-max-enemy-proximity members enemy-combat-recs)
  (for/fold ([md +inf.0]) ([u (in-list members)])
    (define ux (rec-x u 0.0))
    (define uy (rec-y u 0.0))
    (for/fold ([md2 md]) ([e (in-list enemy-combat-recs)])
      (flmin md2 (dist2d-fl ux uy (rec-x e 9999.0) (rec-y e 9999.0))))))

(define (group-max-anchor-dist members sx sy)
  (for/fold ([md 0.0]) ([u (in-list members)])
    (flmax md (dist2d-fl (rec-x u sx) (rec-y u sy) sx sy))))

(define (compute-retreat-pt ux uy ex ey sx sy map-w map-h)
  (define adx (fl- ux ex))
  (define ady (fl- uy ey))
  (define ad (flmax 1.0 (flsqrt (fl+ (fl* adx adx) (fl* ady ady)))))
  (define sdx (fl- sx ux))
  (define sdy (fl- sy uy))
  (define sd (flmax 1.0 (flsqrt (fl+ (fl* sdx sdx) (fl* sdy sdy)))))
  (define vx (fl+ (fl* 0.65 (fl/ adx ad)) (fl* 0.35 (fl/ sdx sd))))
  (define vy (fl+ (fl* 0.65 (fl/ ady ad)) (fl* 0.35 (fl/ sdy sd))))
  (define vn (flmax 0.01 (flsqrt (fl+ (fl* vx vx) (fl* vy vy)))))
  (values (clamp-fl (fl+ ux (fl* 8.0 (fl/ vx vn))) 5.0 (fl- map-w 5.0))
          (clamp-fl (fl+ uy (fl* 8.0 (fl/ vy vn))) 5.0 (fl- map-h 5.0))))

(define (step-staging-groups!
         mgr
         #:frame frame
         #:live-obs? live-obs?
         #:ally-units ally-units
         #:combat-units combat-units
         #:ally-buildings ally-buildings
         #:enemy-units enemy-units
         #:mineral-patches [mineral-patches '()]
         #:mineral-harvesters [mineral-harvesters 0]
         #:vespene-harvesters [vespene-harvesters 0]
         #:base-x base-x
         #:base-y base-y
         #:nat-x nat-x
         #:nat-y nat-y
         #:third-x [third-x nat-x]
         #:third-y [third-y nat-y]
         #:enemy-anchor-x enemy-anchor-x
         #:enemy-anchor-y enemy-anchor-y
         #:map-width [map-w 200.0]
         #:map-height [map-h 200.0]
         #:bfs-dist-fn [bfs-dist-fn #f]
         #:role-leases [role-leases #f]
         #:skip-tags [skip-tags (seteqv)]
         #:enemy-cap-air-cnt [enemy-cap-air-cnt 0]
         #:enemy-contested-aa-cnt [enemy-contested-aa-cnt 0]
         #:combat-suppress-attack? [combat-suppress-attack? #f]
         #:under-home-attack? [under-home-attack? #f]
         #:enemy-near-main? [enemy-near-main? #f]
         #:endgame-hunt-active? [endgame-hunt-active? #f]
         #:enemy-main-cleared? [enemy-main-cleared? #f]
         #:decisive-victory-posture? [decisive-victory-posture? #f]
         #:supply-used [supply-used 0]
         #:ally-combat-supply [ally-combat-supply 0]
         #:enemy-believed-supply [enemy-believed-supply 0]
         #:in-production-counts [in-prod-counts (hasheq)]
         #:defensive-muster-active? [defensive-muster-active? #f])
  ;; Reset cleanly on new match / frame rewind
  (when (or (<= frame 4) (< frame (unbox (staging-group-manager-last-frame mgr))))
    (staging-group-manager-reset! mgr))
  (set-box! (staging-group-manager-last-frame mgr) frame)

  ;; Hard Safety Override #4: Live Full-Match Gate Only (Arena / isolated skirmishes bypass)
  (define eligible?
    (staging-live-full-match-eligible?
     #:live-obs? live-obs?
     #:ally-buildings ally-buildings
     #:ally-units ally-units
     #:mineral-harvesters mineral-harvesters
     #:vespene-harvesters vespene-harvesters))

  (cond
    [(or (not eligible?) (null? combat-units))
     (staging-step-result #f '() '() (seteqv) '() '() (hasheq))]
    [else
     (define mw (flmax 64.0 (fl->safe map-w 200.0)))
     (define mh (flmax 64.0 (fl->safe map-h 200.0)))
     (define fbx (fl->safe base-x 32.5))
     (define fby (fl->safe base-y 32.5))
     (define fnx (fl->safe nat-x fbx))
     (define fny (fl->safe nat-y fby))
     (define fex (fl->safe enemy-anchor-x (fl- mw fbx)))
     (define fey (fl->safe enemy-anchor-y (fl- mh fby)))

     (define ally-townhalls
       (filter (lambda (b) (and (hash? b) (memq (rec-type-sym b) TOWNHALL-SYMS)))
               (or ally-buildings '())))

     ;; Loop 65F/65H (`#1920`/`#1948`): Detect Zerg/Protoss via existing `ally-townhalls` (zero new kwargs)
     ;; so Zerg keeps `96f/64f`, Terran keeps `168f/112f`, and Protoss gets warp-in staging (`268f/180f`)!
     (define zerg-race?
       (and (list? ally-townhalls)
            (ormap (lambda (b) (memq (rec-type-sym b) '(hatchery lair hive)))
                   ally-townhalls)))
     (define protoss-race?
       (and (list? ally-townhalls)
            (ormap (lambda (b) (eq? (rec-type-sym b) 'nexus))
                   ally-townhalls)))

     (define enemy-combat-recs
       (filter (lambda (e)
                 (and (rec-xy? e)
                      (not (rec-snapshot? e))
                      (not (memq (rec-type-sym e) '(larva egg changeling overlord observer overseer)))))
               (or enemy-units '())))

     ;; Hard Safety Override #3: Endgame / Dominant-Army Force-Dispatch (`ENDGAME_HOME_STALL = 0`)
     (define endgame-force-dispatch?
       (or endgame-hunt-active?
           enemy-main-cleared?
           decisive-victory-posture?
           (>= supply-used 165)
           (and (>= ally-combat-supply 40)
                (>= (exact->inexact ally-combat-supply)
                    (fl* 1.50 (flmax 1.0 (exact->inexact enemy-believed-supply)))))))

     ;; Prune dead units from tracking maps & record first-seen frame
     ;; (`unit-first-seen`: positive frame = fresh unit; negative frame = graduated from `'main-reinforce`)
     ;; Loop 65H (`#1948`): For Protoss ONLY, require `(rec-complete? u)` (`build-progress >= 0.999`)
     ;; before recording `first-seen`, counting `front-cnt`, or entering `'main-reinforce`!
     (define first-seen (staging-group-manager-unit-first-seen mgr))
     (define (reinf-graduated? uid)
       (< (hash-ref first-seen uid 1) 0))
     (define (graduate-reinf! uid)
       (hash-set! first-seen uid (- (max 1 (abs (hash-ref first-seen uid (max 1 frame)))))))
     (define alive-uid-set
       (for/fold ([s (seteqv)]) ([u (in-list combat-units)])
         (define uid (rec-id u))
         (if (> uid 0)
             (begin
               (when (and (or (not protoss-race?) (rec-complete? u))
                          (not (hash-has-key? first-seen uid)))
                 (hash-set! first-seen uid (max 1 frame)))
               (set-add s uid))
             s)))
     (define dead-u2g
       (for/list ([uid (in-hash-keys (staging-group-manager-unit->group mgr))]
                  #:when (not (set-member? alive-uid-set uid)))
         uid))
     (for ([uid (in-list dead-u2g)])
       (hash-remove! (staging-group-manager-unit->group mgr) uid))
     (define dead-fs
       (for/list ([uid (in-hash-keys first-seen)]
                  #:when (not (set-member? alive-uid-set uid)))
         uid))
     (for ([uid (in-list dead-fs)])
       (hash-remove! first-seen uid))

     ;; Compute frontline ground army cluster (non-home units > 26t from Main)
     (define-values (front-cnt front-sup front-sx front-sy)
       (for/fold ([fc 0] [fs 0] [sx 0.0] [sy 0.0]) ([u (in-list combat-units)])
         (define sym (rec-type-sym u))
         (if (and (rec-xy? u)
                  (or (not protoss-race?) (rec-complete? u))
                  (not (memq sym NON-REINFORCE-STAGING-SYMS)))
             (let ([ux (rec-x u fbx)] [uy (rec-y u fby)])
               (if (fl> (dist2d-fl ux uy fbx fby) 26.0)
                   (values (add1 fc) (+ fs (max 1 (sc2-supply-cost sym 1))) (fl+ sx ux) (fl+ sy uy))
                   (values fc fs sx sy)))
             (values fc fs sx sy))))
     (define front-cx (if (> front-cnt 0) (fl/ front-sx (exact->inexact front-cnt)) fbx))
     (define front-cy (if (> front-cnt 0) (fl/ front-sy (exact->inexact front-cnt)) fby))
     (define has-distant-frontline?
       (and (>= front-cnt 4)
            (fl> (dist2d-fl front-cx front-cy fbx fby)
                 STAGE-FRONTLINE-SEPARATION-RADIUS)))
     (define front-far-from-nat?
       (and (> front-cnt 0)
            (fl> (dist2d-fl front-cx front-cy fnx fny) 28.0)))

     ;; Count matching units currently in production/morphing
     (define (prod-count-for syms)
       (if (hash? in-prod-counts)
           (for/sum ([s (in-list syms)])
             (define v (hash-ref in-prod-counts s 0))
             (if (exact-integer? v) (max 0 v) 0))
           0))

     (define total-combat-in-prod
       (if (hash? in-prod-counts)
           (for/sum ([(k v) (in-hash in-prod-counts)]
                     #:when (and (exact-integer? v) (> v 0) (not (memq k WORKER-SYMS))))
             v)
           0))

     ;; Partition eligible units into unified staging families
     (define groups-ht (staging-group-manager-groups mgr))
     (define u2g (staging-group-manager-unit->group mgr))
     (define buckets (make-hasheq))
     (define (bucket-add! gid u)
       (hash-set! buckets gid (cons u (hash-ref buckets gid '()))))

     (define (unit-eligible-for-staging? u)
       (define uid (rec-id u))
       (and (> uid 0)
            (rec-xy? u)
            (or (not protoss-race?) (rec-complete? u))
            (not (set-member? skip-tags uid))
            (not (and role-leases (unit-leased-above? role-leases uid 'staging-group frame)))))

     ;; Loop 65F (`#1920`/`#1921`): Require substantive non-worker combat threat (`>= 6.0` supply
     ;; OR `>= 3` combat units within `<= 22.0t` of Main or `<= 20.0t` of Natural) so a lone scout
     ;; Probe / Tempest / Phoenix / Banshee at `24-28t` NEVER disables `'main-reinforce`!
     (define enemy-near-main-or-nat?
       (let-values ([(cnt sup)
                     (for/fold ([c 0] [s 0.0]) ([e (in-list enemy-combat-recs)])
                       (define esym (rec-type-sym e))
                       (if (memq esym WORKER-SYMS)
                           (values c s)
                           (let ([ex (rec-x e 9999.0)]
                                 [ey (rec-y e 9999.0)])
                             (if (or (fl<= (dist2d-fl ex ey fbx fby) 22.0)
                                     (fl<= (dist2d-fl ex ey fnx fny) 20.0))
                                 (values (add1 c)
                                         (fl+ s (exact->inexact
                                                 (if (eq? esym 'zergling)
                                                     0.5
                                                     (max 1 (sc2-supply-cost esym 1))))))
                                 (values c s)))))])
         (or (>= cnt 3) (fl>= sup 6.0))))

     (for ([u (in-list combat-units)]
           #:when (unit-eligible-for-staging? u))
       (define uid (rec-id u))
       (define raw-sym (rec-raw-type-sym u))
       (define sym (rec-type-sym u))
       (define ux (rec-x u fbx))
       (define uy (rec-y u fby))
       (cond
         ;; Family 1: Air Anti-Capital Volley (`corruptor` vs >= 1 cap-air — never 1-by-1 feed Tempests!)
         [(and (eq? sym 'corruptor) (>= enemy-cap-air-cnt 1))
          (bucket-add! 'air-anti-cap u)]
         ;; Family 2: Fast Air Harass / Contested Phoenix (`phoenix`, `mutalisk`, `oracle`, `banshee`)
         ;; Only capture home-side units (`<= 36t` from Main/Nat or already staging) so already-deployed
         ;; mid-map harass packs or active combat wingmen are NEVER yanked back across the map!
         [(and (eq? sym 'phoenix)
               (or (>= enemy-contested-aa-cnt 4)
                   (>= enemy-cap-air-cnt 2)
                   combat-suppress-attack?)
               (or (fl<= (dist2d-fl ux uy fbx fby) 36.0)
                   (fl<= (dist2d-fl ux uy fnx fny) 24.0)
                   (eq? (hash-ref u2g uid #f) 'air-harass-phoenix)))
          (bucket-add! 'air-harass-phoenix u)]
         [(and (eq? sym 'mutalisk)
               (or (fl<= (dist2d-fl ux uy fbx fby) 36.0)
                   (fl<= (dist2d-fl ux uy fnx fny) 24.0)
                   (eq? (hash-ref u2g uid #f) 'air-harass-muta)))
          (bucket-add! 'air-harass-muta u)]
         [(and (eq? sym 'banshee)
               (> (prod-count-for '(banshee)) 0)
               (or (fl<= (dist2d-fl ux uy fbx fby) 36.0)
                   (fl<= (dist2d-fl ux uy fnx fny) 24.0)
                   (eq? (hash-ref u2g uid #f) 'air-harass-raider)))
          (bucket-add! 'air-harass-raider u)]
         ;; Family 3: Ground Harass / Runby Packs (`hellion`, `adept` when home-side & not defending home)
         [(and (eq? sym 'hellion)
               (not under-home-attack?)
               (or (fl<= (dist2d-fl ux uy fbx fby) 36.0)
                   (fl<= (dist2d-fl ux uy fnx fny) 24.0)
                   (eq? (hash-ref u2g uid #f) 'ground-harass-hellion)))
          (bucket-add! 'ground-harass-hellion u)]
         [(and (eq? sym 'adept)
               (not under-home-attack?)
               (or (fl<= (dist2d-fl ux uy fbx fby) 32.0)
                   (eq? (hash-ref u2g uid #f) 'ground-harass-adept)))
          (bucket-add! 'ground-harass-adept u)]
         ;; Family 4: Main Ground Reinforce Wave (strictly home-spawn wave-batching `<= 24t` from home;
         ;; Loop 65H `#1948`: for Protoss ONLY, ALSO capture fresh non-graduated units warped near
         ;; Natural `<= 16.0t` while frontline centroid is `> 28.0t` from Natural!)
         ;; NEVER capture or recapture units `> 26t` from home (for Terran/Zerg), NEVER recapture
         ;; already-dispatched units, and NEVER trigger on `combat-suppress-attack?` (only `has-distant-frontline?`)!
         [(and (not (memq sym NON-REINFORCE-STAGING-SYMS))
               (not (memq raw-sym NON-REINFORCE-STAGING-SYMS))
               (not under-home-attack?)
               (not defensive-muster-active?)
               (not enemy-near-main-or-nat?)
               has-distant-frontline?
               (not (reinf-graduated? uid))
               (let ([d-home (dist2d-fl ux uy fbx fby)]
                     [d-nat (dist2d-fl ux uy fnx fny)])
                 (or (and (fl<= d-home 26.0)
                          (or (fl<= d-home STAGE-HOME-REINFORCE-RADIUS)
                              (eq? (hash-ref u2g uid #f) 'main-reinforce)))
                     (and protoss-race?
                          front-far-from-nat?
                          (or (fl<= d-nat 16.0)
                              (and (fl<= d-nat 18.0)
                                   (eq? (hash-ref u2g uid #f) 'main-reinforce)))))))
          (bucket-add! 'main-reinforce u)]))

     ;; Helper: release any staging/strike lease owned by staging-groups for `uid`
     (define (release-staging-lease! uid)
       (when (and role-leases (hash? role-leases) (not (immutable? role-leases)))
         (define ex (hash-ref role-leases uid #f))
         (when (and (unit-role-lease? ex)
                    (memq (unit-role-lease-role ex) '(staging-group strike-group)))
           (hash-remove! role-leases uid))))

     ;; Clear any stale `'main-reinforce` `u2g` entries for units that left home (`> 26t`) or dropped out
     (define active-reinf-ids
       (for/seteqv ([u (in-list (hash-ref buckets 'main-reinforce '()))])
         (rec-id u)))
     (for ([uid (in-list (hash-keys u2g))]
           #:when (and (eq? (hash-ref u2g uid #f) 'main-reinforce)
                       (not (set-member? active-reinf-ids uid))))
       (hash-remove! u2g uid)
       (release-staging-lease! uid))

     ;; Detect whether enemy capital air is shelling any friendly base (`<= 24t` from any TH/main/nat)
     (define cap-air-shelling-base?
       (and (> enemy-cap-air-cnt 0)
            (let ([base-pts (append (list (cons fbx fby) (cons fnx fny))
                                    (for/list ([th (in-list ally-townhalls)] #:when (rec-xy? th))
                                      (cons (rec-x th fbx) (rec-y th fby))))])
              (for/or ([e (in-list enemy-combat-recs)]
                       #:when (memq (rec-type-sym e) CAP-AIR-SYMS))
                (define ex (rec-x e 9999.0))
                (define ey (rec-y e 9999.0))
                (for/or ([bp (in-list base-pts)])
                  (fl<= (dist2d-fl ex ey (car bp) (cdr bp)) 24.0))))))

     ;; Loop 64B Bug #1 (`#1811`): On `<= 2` bases, enemy combat `< 10.0t` from Natural is an
     ;; existential core-base threat — allow home-defense scramble even during defensive muster!
     (define enemy-near-nat-2base?
       (and (<= (length ally-townhalls) 2)
            (for/or ([e (in-list enemy-combat-recs)])
              (fl< (dist2d-fl (rec-x e 9999.0) (rec-y e 9999.0) fnx fny) 10.0))))

     ;; Policy lookup per group family:
     ;; returns (values domain min-cnt min-sup max-wait-frames min-dwell-frames prod-cnt protect-vs-cap-air?)
     (define (group-policy gid)
       (case gid
         [(air-anti-cap)
          ;; L58-HOLD Bug #2 fix: cap `min-c` at 12 (never demand 18 Corruptors vs 17 Tempests!)
          (define min-c (min 12 (max 6 (+ enemy-cap-air-cnt 2))))
          (define pc (prod-count-for '(corruptor)))
          (values 'air min-c (* min-c 2)
                  (if (> pc 0) 336 STAGE-NO-PROD-MAX-WAIT-FRAMES)
                  84 pc #t)]
         [(air-harass-phoenix)
          (define pc (prod-count-for '(phoenix)))
          (values 'air 4 8
                  (if (> pc 0) 224 STAGE-NO-PROD-MAX-WAIT-FRAMES)
                  84 pc #f)]
         [(air-harass-muta)
          (define pc (prod-count-for '(mutalisk)))
          (values 'air 6 12
                  (if (> pc 0) 224 STAGE-NO-PROD-MAX-WAIT-FRAMES)
                  96 pc #f)]
         [(air-harass-raider)
          (define pc (prod-count-for '(banshee)))
          (values 'air 2 4
                  (if (> pc 0) 112 44)
                  64 pc #f)]
         [(ground-harass-hellion)
          (define pc (prod-count-for '(hellion)))
          (values 'ground-flank 4 8
                  (if (> pc 0) 168 STAGE-NO-PROD-MAX-WAIT-FRAMES)
                  84 pc #f)]
         [(ground-harass-adept)
          (define pc (prod-count-for '(adept)))
          (values 'ground-flank 2 4
                  (if (> pc 0) 140 84)
                  64 pc #f)]
         [else ;; 'main-reinforce
          (define min-s (max 6 (if (> front-sup 0) (max 6 (quotient front-sup 4)) 6)))
          (define reinf-wait
            (cond [zerg-race? STAGE-ZERG-REINFORCE-MAX-WAIT-FRAMES]
                  [protoss-race? STAGE-PROTOSS-REINFORCE-MAX-WAIT-FRAMES]
                  [else STAGE-REINFORCE-MAX-WAIT-FRAMES]))
          (define noprod-wait
            (cond [zerg-race? STAGE-ZERG-NO-PROD-MAX-WAIT-FRAMES]
                  [protoss-race? STAGE-PROTOSS-NO-PROD-MAX-WAIT-FRAMES]
                  [else STAGE-NO-PROD-MAX-WAIT-FRAMES]))
          (values 'ground-front 4 min-s
                  (if (> total-combat-in-prod 0) reinf-wait noprod-wait)
                  84 total-combat-in-prod #f)]))

     (define actions-rev '())
     (define preserved-rev '())
     (define handled (mutable-seteqv))
     (define dispatched-gids '())
     (define staging-gids '())
     (define anchors-ht (make-hasheq))

     ;; Remove empty groups
     (for ([gid (in-list (hash-keys groups-ht))])
       (unless (hash-has-key? buckets gid)
         (hash-remove! groups-ht gid)))

     ;; Evaluate each active group
     (for ([(gid members) (in-hash buckets)])
       (define-values (domain min-cnt min-sup max-wait min-dwell prod-cnt protect-vs-cap-air?)
         (group-policy gid))
       (define air-domain? (or (eq? domain 'air) (eq? domain 'drop)))
       (define existing (hash-ref groups-ht gid #f))
       (define prev-pt
         (and existing (cons (staging-group-stage-x existing) (staging-group-stage-y existing))))
       (define stage-pt
         (pick-safe-staging-point
          #:domain domain
          #:ally-townhalls ally-townhalls
          #:ally-buildings ally-buildings
          #:mineral-patches mineral-patches
          #:enemy-units enemy-combat-recs
          #:enemy-anchor-x fex
          #:enemy-anchor-y fey
          #:base-x fbx
          #:base-y fby
          #:nat-x fnx
          #:nat-y fny
          #:third-x third-x
          #:third-y third-y
          #:map-width mw
          #:map-height mh
          #:prev-pt prev-pt
          #:bfs-dist-fn bfs-dist-fn
          #:enemy-capital-air? (or protect-vs-cap-air? (>= enemy-cap-air-cnt 1))))
       (define sx (car stage-pt))
       (define sy (cdr stage-pt))
       (hash-set! anchors-ht gid stage-pt)

       (define m-tags
         (for/fold ([s (seteqv)]) ([u (in-list members)])
           (define uid (rec-id u))
           (hash-set! u2g uid gid)
           (set-add s uid)))
       (define grp
         (if existing
             (begin
               (set-staging-group-stage-x! existing sx)
               (set-staging-group-stage-y! existing sy)
               (set-staging-group-member-tags! existing m-tags)
               existing)
             (let ([ng (staging-group gid domain 'staging sx sy m-tags 0 frame frame -99999 sx sy)])
               (hash-set! groups-ht gid ng)
               ng)))

       (define n-members (length members))
       (define tot-sup (group-total-supply members))
       (define wait-elapsed (max 0 (- frame (staging-group-formed-frame grp))))
       (define state-elapsed (max 0 (- frame (staging-group-last-state-frame grp))))
       (define cohesive? (group-cohesion-ok? members sx sy))
       (define avg-hp (group-avg-hp-ratio members))
       (define min-e-dist (group-max-enemy-proximity members enemy-combat-recs))

       ;; Hard Safety Override #1: Emergency Home-Defense Scramble
       ;; Releases all staging groups when home base / workers are under attack (or enemy capital air
       ;; shells ANY base), EXCEPT `< 6` Corruptors vs `>= 3` Tempests so small packs don't feed,
       ;; AND Loop 64B Bug #1: during `defensive-muster-active?`, suppress outer-base (3rd+)
       ;; scramble so staging packs consolidate, while ALWAYS scrambling on Main threat OR
       ;; `<= 2`-base Natural threat (`< 10.0t` of Natural)!
       (define home-scramble-override?
         (or (and (eq? gid 'main-reinforce)
                  (or under-home-attack?
                      defensive-muster-active?
                      enemy-near-main-or-nat?))
             (and (or (and under-home-attack?
                           (or (not defensive-muster-active?)
                               enemy-near-main?
                               enemy-near-nat-2base?))
                      (and protect-vs-cap-air? cap-air-shelling-base?))
                  (not (and protect-vs-cap-air? (< n-members 6))))))

       ;; Ready-to-commit condition (pack threshold + cohesion OR anti-stall / endgame / home-defense)
       (define pack-threshold-met?
         (cond
           [(eq? gid 'main-reinforce)
            (or (>= n-members min-cnt) (>= tot-sup min-sup))]
           [else
            (and (>= n-members min-cnt) (>= tot-sup min-sup))]))

       ;; Anti-stall: never stall forever! Only hold `< 6` Corruptors vs enemy capital air
       ;; (`<= 48t` or cap-air active) so late-game newly hatched Corruptors NEVER trickle 1-by-1
       ;; into Tempests; NEVER block anti-stall past `336f` (`15s`) once `>= 6` Corruptors are alive!
       (define anti-stall-release?
         (cond
           [(and protect-vs-cap-air? (>= n-members 6))
            (>= wait-elapsed (min 336 max-wait))]
           [(and protect-vs-cap-air? (< n-members 6)
                 (or (>= enemy-cap-air-cnt 1) (fl<= min-e-dist 48.0)))
            #f]
           [else
            (>= wait-elapsed max-wait)]))

       ;; L59-P2 (`#1500` Corruptor 1-by-1 Tempest feed fix): Endgame `supply >= 165` MUST NOT
       ;; force-dispatch `< 6` Corruptors 1-by-1 into active enemy Tempests/Carriers/BCs!
       (define effective-endgame-dispatch?
         (and endgame-force-dispatch?
              (or enemy-main-cleared?
                  (not (and protect-vs-cap-air? (< n-members 6))))))

       ;; State transitions with hysteresis
       (define cur-state (staging-group-state grp))
       (define next-state
         (cond
           [(or effective-endgame-dispatch? home-scramble-override?)
            'dispatched]
           [(eq? cur-state 'staging)
            (cond
              [(and pack-threshold-met? cohesive?) 'dispatched]
              [anti-stall-release? 'dispatched]
              [else 'staging])]
           [(eq? cur-state 'dispatched)
            (cond
              ;; L58-HOLD Bug #1 fix: `'main-reinforce` NEVER regroups frontline units!
              [(eq? gid 'main-reinforce) 'dispatched]
              [(< state-elapsed min-dwell) 'dispatched]
              [(and protect-vs-cap-air? (< n-members 6))
               'regrouping]
              [(or (and (> (staging-group-commit-size grp) 0)
                        (< n-members (max 1 (inexact->exact (floor (* STAGE-REGROUP-DROP-RATIO (staging-group-commit-size grp)))))))
                   (fl< avg-hp STAGE-REGROUP-HP-RATIO)
                   (and combat-suppress-attack? (fl> min-e-dist 22.0) (not pack-threshold-met?)))
               'regrouping]
              [else 'dispatched])]
           [else ;; 'regrouping
            (if (or (eq? gid 'main-reinforce)
                    (and (fl> min-e-dist 16.0)
                         (fl<= (group-max-anchor-dist members sx sy) 14.0))
                    (>= state-elapsed 96))
                'staging
                'regrouping)]))

       (unless (eq? next-state cur-state)
         (set-staging-group-state! grp next-state)
         (set-staging-group-last-state-frame! grp frame)
         (when (eq? next-state 'dispatched)
           (set-staging-group-commit-size! grp n-members))
         (when (eq? next-state 'staging)
           (set-staging-group-formed-frame! grp frame)))

       (cond
         [(eq? next-state 'dispatched)
          (set! dispatched-gids (cons gid dispatched-gids))
          ;; Release staging lease so `'army` combat micro (`l34-phase5b` / `direct-actions`) owns dispatched units cleanly!
          ;; For `'main-reinforce`: ALSO clear `u2g`, graduate members (never recapture!), and reset group for next spawn wave!
          (for ([u (in-list members)])
            (define uid (rec-id u))
            (release-staging-lease! uid)
            (when (eq? gid 'main-reinforce)
              (hash-remove! u2g uid)
              (graduate-reinf! uid)))
          (when (eq? gid 'main-reinforce)
            (hash-remove! groups-ht 'main-reinforce))]
         [else
          ;; `'staging` or `'regrouping`
          (set! staging-gids (cons gid staging-gids))
          (define throttle-ok?
            (or (>= (- frame (staging-group-last-order-frame grp)) STAGE-ORDER-THROTTLE-FRAMES)
                (fl> (dist2d-fl sx sy (staging-group-last-order-x grp) (staging-group-last-order-y grp))
                     STAGE-ORDER-DRIFT-THRESH)))
          (define issued-group-order? #f)
          (for ([u (in-list members)])
            (define uid (rec-id u))
            (define ux (rec-x u sx))
            (define uy (rec-y u sy))
            (define-values (u-edist near-ex near-ey near-temp? local-e-str)
              (unit-near-enemy-info u enemy-combat-recs))
            (define contact-r (if (or protect-vs-cap-air? near-temp?)
                                  STAGE-TEMPEST-CONTACT-RADIUS
                                  STAGE-IN-CONTACT-RADIUS))
            (define in-contact? (and near-ex (fl<= u-edist contact-r)))
            (cond
              ;; Hard Safety Override #2: In-Contact Reflex
              ;; L58-HOLD Bug #1 fix: Ground staging NEVER emits passive `'move` (`zero_fire_retreat`) —
              ;; release any ground staging member in combat contact immediately to Phase 5b!
              [(and in-contact? (not air-domain?))
               (release-staging-lease! uid)]
              [in-contact?
               (define local-a-str (local-ally-strength ux uy combat-units 14.0))
               ;; L58-HOLD Bug #2 fix: remove `(<= enemy-cap-air-cnt 8)` cap — dive whenever
               ;; `>= 8` Corruptors OR `>= 6` Corruptors while Tempests shell any home base!
               (define cap-dive-ok?
                 (and protect-vs-cap-air?
                      (or (>= n-members 8)
                          (and (>= n-members 6)
                               (or under-home-attack? cap-air-shelling-base?)))
                      (fl<= u-edist STAGE-TEMPEST-CONTACT-RADIUS)))
               (define eff-commit-ratio
                 (if defensive-muster-active? STAGE-MUSTER-COMMIT-RATIO STAGE-COMMIT-STRENGTH-RATIO))
               (define eff-retreat-ratio
                 (if defensive-muster-active? STAGE-MUSTER-RETREAT-RATIO STAGE-RETREAT-STRENGTH-RATIO))
               (define commit-fight?
                 (and (not (and protect-vs-cap-air? (< n-members min-cnt) (not cap-dive-ok?)))
                      (or cap-dive-ok?
                          (fl<= local-e-str 0.01)
                          (fl>= local-a-str (fl* eff-commit-ratio local-e-str)))))
               (cond
                 [commit-fight?
                  ;; Release this unit to Phase 5b to fight immediately!
                  (release-staging-lease! uid)]
                 [(or protect-vs-cap-air?
                      (fl< local-a-str (fl* eff-retreat-ratio local-e-str)))
                  ;; Actively retreat air units away from enemy blended toward safe stage point
                  (define-values (rx ry) (compute-retreat-pt ux uy near-ex near-ey sx sy mw mh))
                  (set-add! handled uid)
                  (when role-leases
                    (acquire-unit-lease! role-leases uid 'staging-group frame STAGE-LEASE-TTL-FRAMES
                                         #:target-id gid #:x rx #:y ry))
                  (if protect-vs-cap-air?
                      (set! preserved-rev (cons (list 'move uid rx ry) preserved-rev))
                      (set! actions-rev (cons (list 'move uid rx ry) actions-rev)))]
                 [else
                  ;; Marginal 0.55x..0.70x contact: release to combat micro so unit shoots back!
                  (release-staging-lease! uid)])]
              [else
               ;; Safely staging/regrouping outside immediate contact
               (set-add! handled uid)
               (when role-leases
                 (acquire-unit-lease! role-leases uid 'staging-group frame STAGE-LEASE-TTL-FRAMES
                                      #:target-id gid #:x sx #:y sy))
               (define d-stage (dist2d-fl ux uy sx sy))
               (when (and (fl> d-stage 3.5)
                          (or throttle-ok? (fl> d-stage 12.0)))
                 (set! issued-group-order? #t)
                 ;; Hard Safety Override #5: Ground staging ALWAYS uses `attack-pos` (`OBRet = 0`);
                 ;; Air staging uses `move` so flyers don't drift into long-range AA!
                 (define cmd (if air-domain? 'move 'attack-pos))
                 (if protect-vs-cap-air?
                     (set! preserved-rev (cons (list cmd uid sx sy) preserved-rev))
                     (set! actions-rev (cons (list cmd uid sx sy) actions-rev))))]))
          (when issued-group-order?
            (set-staging-group-last-order-frame! grp frame)
            (set-staging-group-last-order-x! grp sx)
            (set-staging-group-last-order-y! grp sy))]))

     (staging-step-result #t
                          (reverse actions-rev)
                          (reverse preserved-rev)
                          (for/fold ([s (seteqv)]) ([uid (in-set handled)]) (set-add s uid))
                          dispatched-gids
                          staging-gids
                          (for/hasheq ([(k v) (in-hash anchors-ht)]) (values k v)))]))
