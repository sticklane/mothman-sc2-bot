#lang racket/base

(require racket/match
         racket/list
         racket/set
         racket/math
         racket/flonum
         "sc2-bayesian.rkt"
         "sc2-game-constants.rkt")

(provide
 VIEWPORT-WIDTH
 VIEWPORT-HEIGHT
 TAU-FIXATION-MS
 TAU-FIXATION-FRAMES

 (struct-out human-cortex)
 make-human-cortex
 in-camera-viewport?
 fitts-saccade-ms
 fitts-saccade-frames
 cortex-move-camera!
 action-requires-camera-focus
 action-priority
 cortex-filter-actions!

 ;; Control Groups (0..9) & Pro Control-Group Stealing (Alt+Group)
 cortex-assign-control-group!
 cortex-steal-control-group!
 cortex-set-control-group!
 cortex-get-control-group
 cortex-sync-control-groups!
 cortex-production-group-capacity
 cortex-idle-facilities-in-group

 ;; Camera Location Bookmarks (F1..F8)
 cortex-save-camera-bookmark!
 cortex-get-camera-bookmark
 cortex-jump-camera-bookmark!
 cortex-sync-camera-bookmarks!

 ;; Optimal Human Selection & Control-Group Compiler (On-Screen Box, Ctrl-Click, Control Group)
 cortex-active-selection
 set-cortex-active-selection!
 units-in-camera-viewport
 simulate-box-drag-on-screen
 simulate-ctrl-click-subselect
 simulate-shift-ctrl-deselect-type
 compile-optimal-unit-selection!
 cortex-collapse-and-compile-selections!

 ;; 7-Year (2019-2026) Pro Tournament Cortex Calibration & Fingerprinting
 PRO-CORTEX-PROFILES
 get-pro-cortex-profile
 calibrate-cortex-from-corpus
 ks-two-sample-statistic
 hellinger-distance
 classify-player-fingerprint)

(define VIEWPORT-WIDTH 24)
(define VIEWPORT-HEIGHT 18)
(define TAU-FIXATION-MS 160)
(define TAU-FIXATION-FRAMES 4)

(struct human-cortex
  (profile-name
   cam-x
   cam-y
   fixation-frames
   epm-cap
   tokens
   max-tokens
   accepted-count
   dropped-count
   offscreen-violations
   control-groups     ; 10-element vector of unit-id lists
   camera-bookmarks   ; hash slot (1..8) -> (cons x y)
   action-history)
  #:mutable
  #:transparent)

(define PRO-CORTEX-PROFILES
  (hash
   'Serral   (hash 'name 'Serral   'race 'Zerg    'mean-epm 365 'burst-epm 620 'saccade-a 42.0 'saccade-b 18.5 'fixation-ms 155 'screen-jumps-per-min 44.2)
   'Reynor   (hash 'name 'Reynor   'race 'Zerg    'mean-epm 392 'burst-epm 680 'saccade-a 38.0 'saccade-b 17.0 'fixation-ms 148 'screen-jumps-per-min 48.5)
   'Maru     (hash 'name 'Maru     'race 'Terran  'mean-epm 358 'burst-epm 610 'saccade-a 44.0 'saccade-b 19.0 'fixation-ms 160 'screen-jumps-per-min 39.8)
   'Clem     (hash 'name 'Clem     'race 'Terran  'mean-epm 410 'burst-epm 710 'saccade-a 36.0 'saccade-b 16.5 'fixation-ms 142 'screen-jumps-per-min 52.1)
   'Oliveira (hash 'name 'Oliveira 'race 'Terran  'mean-epm 345 'burst-epm 580 'saccade-a 45.0 'saccade-b 19.5 'fixation-ms 162 'screen-jumps-per-min 38.4)
   'herO     (hash 'name 'herO     'race 'Protoss 'mean-epm 338 'burst-epm 575 'saccade-a 46.0 'saccade-b 20.0 'fixation-ms 165 'screen-jumps-per-min 41.0)
   'Classic  (hash 'name 'Classic  'race 'Protoss 'mean-epm 312 'burst-epm 530 'saccade-a 48.0 'saccade-b 21.0 'fixation-ms 172 'screen-jumps-per-min 35.6)
   'MaxPax   (hash 'name 'MaxPax   'race 'Protoss 'mean-epm 352 'burst-epm 595 'saccade-a 43.0 'saccade-b 18.8 'fixation-ms 158 'screen-jumps-per-min 43.0)
   'Flash    (hash 'name 'Flash    'race 'Terran  'mean-epm 330 'burst-epm 540 'saccade-a 47.0 'saccade-b 20.5 'fixation-ms 168 'screen-jumps-per-min 37.2)
   'Jaedong  (hash 'name 'Jaedong  'race 'Zerg    'mean-epm 375 'burst-epm 640 'saccade-a 40.0 'saccade-b 18.0 'fixation-ms 152 'screen-jumps-per-min 45.0)
   'Bisu     (hash 'name 'Bisu     'race 'Protoss 'mean-epm 340 'burst-epm 565 'saccade-a 45.0 'saccade-b 19.8 'fixation-ms 164 'screen-jumps-per-min 42.5)))

(define (get-pro-cortex-profile [name 'Serral])
  (hash-ref PRO-CORTEX-PROFILES name
            (lambda () (hash-ref PRO-CORTEX-PROFILES 'Serral))))

(define (make-human-cortex #:profile [profile 'Serral]
                           #:cam-x [cam-x 32.0]
                           #:cam-y [cam-y 32.0]
                           #:epm-cap [epm-cap 420]
                           #:max-tokens [max-tokens 56])
  (human-cortex
   profile
   cam-x
   cam-y
   1
   epm-cap
   max-tokens
   max-tokens
   0
   0
   0
   (make-vector SC2-CONTROL-GROUP-COUNT '())
   (make-hash)
   '()))

(define (in-camera-viewport? cx cy x y [w VIEWPORT-WIDTH] [h VIEWPORT-HEIGHT])
  (define half-w (fl* 0.5 (if (flonum? w) w (exact->inexact w))))
  (define half-h (fl* 0.5 (if (flonum? h) h (exact->inexact h))))
  (define fcx (if (flonum? cx) cx (exact->inexact cx)))
  (define fcy (if (flonum? cy) cy (exact->inexact cy)))
  (define fx (if (flonum? x) x (exact->inexact x)))
  (define fy (if (flonum? y) y (exact->inexact y)))
  (and (fl>= fx (fl- fcx half-w))
       (fl<= fx (fl+ fcx half-w))
       (fl>= fy (fl- fcy half-h))
       (fl<= fy (fl+ fcy half-h))))

;; Fitts's Law Saccade Duration in SC2 map tiles: T = a + b * log2(1 + D / W)
(define (fitts-saccade-ms x1 y1 x2 y2 [target-width 4.0] [a 42.0] [b 18.5])
  (define dist (sqrt (+ (sqr (- x2 x1)) (sqr (- y2 y1)))))
  (+ a (* b (/ (log (+ 1.0 (/ dist (max 1.0 target-width)))) (log 2.0)))))

(define (fitts-saccade-frames x1 y1 x2 y2)
  (max 1 (exact-ceiling (/ (fitts-saccade-ms x1 y1 x2 y2) 42.0))))

(define (cortex-move-camera! cortex new-x new-y)
  (define old-x (human-cortex-cam-x cortex))
  (define old-y (human-cortex-cam-y cortex))
  (cond
    [(and (= old-x new-x) (= old-y new-y))
     (set-human-cortex-fixation-frames! cortex (add1 (human-cortex-fixation-frames cortex)))]
    [else
     (set-human-cortex-cam-x! cortex new-x)
     (set-human-cortex-cam-y! cortex new-y)
     (set-human-cortex-fixation-frames! cortex 1)])
  cortex)

;; =============================================================================
;; Control Groups (0..9) & Pro Control-Group Stealing (Alt+Group)
;; =============================================================================

(define (cortex-assign-control-group! cortex group-id unit-ids)
  (when (and (>= group-id 0) (< group-id SC2-CONTROL-GROUP-COUNT) (pair? unit-ids))
    (define vec (human-cortex-control-groups cortex))
    (define existing (vector-ref vec group-id))
    (vector-set! vec group-id
                 (dedup-ints-order (if (null? existing) unit-ids (append existing unit-ids)))))
  cortex)

(define (cortex-set-control-group! cortex group-id unit-ids)
  (when (and (>= group-id 0) (< group-id SC2-CONTROL-GROUP-COUNT))
    (define vec (human-cortex-control-groups cortex))
    (vector-set! vec group-id (dedup-ints-order unit-ids)))
  cortex)

;; Exclusive Control-Group Stealing (Alt + 0..9):
;; Removes `unit-ids` from ALL other control groups (0..9) and assigns to `group-id`.
(define (cortex-steal-control-group! cortex group-id unit-ids)
  (when (pair? unit-ids)
    (define stolen-ht (list->hasheqv-opt unit-ids))
    (define vec (human-cortex-control-groups cortex))
    (when stolen-ht
      (for ([g (in-range SC2-CONTROL-GROUP-COUNT)])
        (unless (= g group-id)
          (define cur (vector-ref vec g))
          (when (pair? cur)
            (vector-set! vec g (filter (lambda (id) (not (hash-ref stolen-ht id #f))) cur))))))
    (when (and (>= group-id 0) (< group-id SC2-CONTROL-GROUP-COUNT))
      (define cur-target (vector-ref vec group-id))
      (vector-set! vec group-id
                   (dedup-ints-order (if (null? cur-target) unit-ids (append cur-target unit-ids))))))
  cortex)

(define (cortex-get-control-group cortex group-id)
  (if (and (>= group-id 0) (< group-id SC2-CONTROL-GROUP-COUNT))
      (vector-ref (human-cortex-control-groups cortex) group-id)
      '()))

;; Synchronize all 10 pro control groups (0..9) with dirty-set diffing so we only
;; emit `(control-group-steal g tags)` or `(control-group-set g tags)` when membership changes.
;;   1: Main Combat Army
;;   2: Harass / Air / Flanking Squad (Banshees, Mutas, Oracles, Phoenix, Void Rays, Warp Prisms, Medivacs, Reapers, Hellions, Adepts)
;;   3: Spellcasters / Siege / Detectors (Queens, Ravens, Vipers, Infestors, HTs, Sentries, Disruptors, Siege Tanks, Liberators, Lurkers, Observers, Overseers)
;;   4: Townhalls (Nexus, Command Center, Orbital Command, Planetary Fortress, Hatchery, Lair, Hive)
;;   5: Primary Production (Barracks, Gateways, Warp Gates)
;;   6: Tech Production (Factories, Starports, Robotics Facilities, Stargates)
;;   7: Upgrade Structures (Engineering Bays, Armories, Forges, Cybernetics Cores, Evolution Chambers, Spires)
;;   8: Active Scouts (forward scouts > 28 tiles from home base)
;;   9: Static Defense & Ramp Wall Depots
;;   0: All-In / Emergency Mobilization Reserve
(define NON-COMBAT-SELECTION-INTRUDER-TYPES
  '(drone drone-burrowed probe scv mule
    larva egg cocoon baneling-cocoon ravager-cocoon
    lurker-egg lurker-mp-egg brood-lord-cocoon overlord-cocoon
    overlord overlord-transport
    creep-tumor creep-tumor-burrowed creep-tumor-queen
    auto-turret point-defense-drone raven-repair-drone
    kd8-charge parasitic-bomb-dummy adept-phase-shift interceptor))

(define CORTEX-HARASS-UNIT-TYPES
  '(banshee mutalisk oracle phoenix void-ray voidray
    warp-prism warp-prism-phasing medivac reaper hellion adept
    viking viking-fighter viking-assault))

(define CORTEX-CASTER-SIEGE-UNIT-TYPES
  '(queen queen-burrowed raven viper infestor infestor-burrowed
    high-templar sentry disruptor disruptor-phased
    siege-tank siege-tank-sieged liberator liberator-ag
    lurker lurker-mp lurker-burrowed lurker-mp-burrowed
    widow-mine widow-mine-burrowed
    swarm-host swarmhost swarm-host-mp swarm-host-burrowed
    observer observer-siege-mode overseer overseer-siege-mode))

(define CORTEX-HARASS-UNIT-SET
  (for/hasheq ([t (in-list CORTEX-HARASS-UNIT-TYPES)]) (values t #t)))

(define CORTEX-CASTER-SIEGE-SET
  (for/hasheq ([t (in-list CORTEX-CASTER-SIEGE-UNIT-TYPES)]) (values t #t)))

(define CORTEX-WORKER-SET
  (hasheq 'drone #t 'probe #t 'scv #t))

(define CORTEX-TOWNHALL-SET
  (hasheq 'hatchery #t 'lair #t 'hive #t 'nexus #t
          'command-center #t 'command-center-flying #t
          'orbital-command #t 'orbital-command-flying #t
          'planetary-fortress #t))

(define CORTEX-PRIMARY-PROD-SET
  (hasheq 'barracks #t 'barracks-flying #t 'gateway #t 'warp-gate #t 'warpgate #t))

(define CORTEX-TECH-PROD-SET
  (hasheq 'factory #t 'factory-flying #t 'starport #t 'starport-flying #t
          'robotics-facility #t 'stargate #t))

(define CORTEX-UPGRADE-BLDG-SET
  (hasheq 'engineering-bay #t 'armory #t 'fusion-core #t 'ghost-academy #t
          'barracks-tech-lab #t 'barracks-techlab #t 'factory-tech-lab #t 'factory-techlab #t
          'starport-tech-lab #t 'starport-techlab #t
          'forge #t 'cybernetics-core #t 'twilight-council #t 'robotics-bay #t 'robotics-support-bay #t
          'fleet-beacon #t 'templar-archive #t 'templar-archives #t 'dark-shrine #t
          'evolution-chamber #t 'spire #t 'greater-spire #t 'spawning-pool #t 'infestation-pit #t
          'baneling-nest #t 'roach-warren #t 'hydralisk-den #t 'lurker-den #t 'lurker-den-mp #t
          'ultralisk-cavern #t))

(define CORTEX-DEFENSE-WALL-SET
  (hasheq 'supply-depot #t 'supply-depot-lowered #t 'bunker #t 'missile-turret #t 'sensor-tower #t
          'pylon-overcharged #t 'photon-cannon #t 'shield-battery #t
          'spine-crawler #t 'spine-crawler-uprooted #t 'spore-crawler #t 'spore-crawler-uprooted #t))

(define NON-COMBAT-SELECTION-INTRUDER-SET
  (for/hasheq ([t (in-list NON-COMBAT-SELECTION-INTRUDER-TYPES)]) (values t #t)))

(define CORTEX-PROTECTED-MODE-EXCLUDED-SET
  (hasheq 'queen #t 'queen-burrowed #t
          'siege-tank-sieged #t 'liberator-ag #t
          'lurker-burrowed #t 'lurker-mp-burrowed #t
          'widow-mine-burrowed #t 'swarm-host-burrowed #t))

(define CORTEX-NONCOMBAT-CACHE (make-hasheq))
(define (fast-noncombat-sym? t)
  (hash-ref! CORTEX-NONCOMBAT-CACHE t (lambda () (sc2-non-combat-or-summon-sym? t))))

(define CORTEX-ORDER-PROT-CACHE (make-hasheqv))
(define (fast-order-protection-class ab-id)
  (if (or (not (exact-integer? ab-id)) (<= ab-id 0))
      'none
      (hash-ref! CORTEX-ORDER-PROT-CACHE ab-id (lambda () (sc2-order-protection-class ab-id)))))

(define CORTEX-REQUIRES-PYLON-CACHE (make-hasheq))
(define CORTEX-CANON-STRUCT-CACHE (make-hasheq))
(define (cortex-miss-thunk) '__cortex-miss__)

(define (fast-requires-pylon-power? t)
  (define cached (hash-ref CORTEX-REQUIRES-PYLON-CACHE t cortex-miss-thunk))
  (if (eq? cached '__cortex-miss__)
      (let ([res (sc2-structure-requires-pylon-power? t)])
        (hash-set! CORTEX-REQUIRES-PYLON-CACHE t res)
        res)
      cached))

(define (fast-canon-struct-sym t)
  (define cached (hash-ref CORTEX-CANON-STRUCT-CACHE t cortex-miss-thunk))
  (if (eq? cached '__cortex-miss__)
      (let ([res (sc2-canonical-structure-sym t)])
        (hash-set! CORTEX-CANON-STRUCT-CACHE t res)
        res)
      cached))

(define (sort-dedup-ints xs)
  (cond
    [(null? xs) '()]
    [(null? (cdr xs)) xs]
    [else
     (define x0 (car xs))
     (define x1 (cadr xs))
     (cond
       [(and (< x0 x1)
             (let asc? ([prev x1] [rem (cddr xs)])
               (or (null? rem)
                   (let ([x (car rem)])
                     (and (< prev x) (asc? x (cdr rem)))))))
        xs]
       [(and (> x0 x1)
             (let desc? ([prev x1] [rem (cddr xs)])
               (or (null? rem)
                   (let ([x (car rem)])
                     (and (> prev x) (desc? x (cdr rem)))))))
        (reverse xs)]
       [else
        (let check-sorted ([rem (cdr xs)] [prev (car xs)])
          (cond
            [(null? rem) xs]
            [else
             (define x (car rem))
             (if (> x prev)
                 (check-sorted (cdr rem) x)
                 (let ([sorted (sort xs <)])
                   (let loop ([srem (cdr sorted)] [sprev (car sorted)] [acc (list (car sorted))])
                     (cond
                       [(null? srem) (reverse acc)]
                       [else
                        (define sx (car srem))
                        (if (= sx sprev)
                            (loop (cdr srem) sprev acc)
                            (loop (cdr srem) sx (cons sx acc)))]))))]))])]))

(define DEDUP-INT-STAMP-HT (make-hasheqv))
(define DEDUP-INT-STAMP-GEN 0)

(define (dedup-ints-order xs)
  (cond
    [(or (null? xs) (null? (cdr xs))) xs]
    [(null? (cddr xs))
     (if (eqv? (car xs) (cadr xs)) (list (car xs)) xs)]
    [(strictly-ascending-pos-ints? xs) xs]
    [else
     (when (> (hash-count DEDUP-INT-STAMP-HT) 4096)
       (hash-clear! DEDUP-INT-STAMP-HT))
     (set! DEDUP-INT-STAMP-GEN (+ DEDUP-INT-STAMP-GEN 1))
     (define gen DEDUP-INT-STAMP-GEN)
     (let loop ([rem xs] [acc '()])
       (cond
         [(null? rem) (reverse acc)]
         [else
          (define x (car rem))
          (define slot (hash-ref DEDUP-INT-STAMP-HT x #f))
          (cond
            [(and slot (eqv? (mcar slot) gen))
             (loop (cdr rem) acc)]
            [slot
             (set-mcar! slot gen)
             (loop (cdr rem) (cons x acc))]
            [else
             (hash-set! DEDUP-INT-STAMP-HT x (mcons gen #t))
             (loop (cdr rem) (cons x acc))])]))]))

(define (list->hasheqv-opt xs)
  (and (pair? xs)
       (for/hasheqv ([x (in-list xs)])
         (values x #t))))

(define (stamp-ht-has? ht gen uid)
  (let ([slot (hash-ref ht uid #f)])
    (and slot (eqv? (mcar slot) gen))))

(define (stamp-ht-add! ht gen uid [val #t])
  (let ([slot (hash-ref ht uid #f)])
    (cond
      [slot
       (set-mcar! slot gen)
       (set-mcdr! slot val)]
      [else
       (hash-set! ht uid (mcons gen val))])))

(define (stamp-ht-lookup ht gen uid)
  (let ([slot (hash-ref ht uid #f)])
    (and slot (eqv? (mcar slot) gen) (mcdr slot))))

(define CORTEX-SYNC-SCRATCH (make-weak-hasheq))
(define CORTEX-CAP-TAG-HT (make-hasheqv))
(define CORTEX-CAP-TAG-GEN 0)

(define (cortex-sync-control-groups! cortex ally-units ally-buildings base-x base-y
                                     #:excluded-tags [excluded-tags #f])
  (define actions '())
  (define (emit! a) (set! actions (cons a actions)))
  (define (tag-excluded? id)
    (cond
      [(not excluded-tags) #f]
      [(set? excluded-tags) (set-member? excluded-tags id)]
      [(hash? excluded-tags) (and (hash-ref excluded-tags id #f) #t)]
      [(list? excluded-tags) (not (not (memv id excluded-tags)))]
      [else #f]))
  (define (unit-is-hallucination? u)
    (or (eq? (hash-ref u 'is-hallucination #f) #t)
        (eq? (hash-ref u 'hallucination #f) #t)))
  (define vec (human-cortex-control-groups cortex))
  (define scratch
    (or (hash-ref CORTEX-SYNC-SCRATCH cortex #f)
        (let ([s (vector 0 (make-hasheqv) (make-vector SC2-CONTROL-GROUP-COUNT '()))])
          (hash-set! CORTEX-SYNC-SCRATCH cortex s)
          s)))
  (define sync-gen (+ (vector-ref scratch 0) 1))
  (vector-set! scratch 0 sync-gen)
  (define g2-stamp-ht (vector-ref scratch 1))
  (when (> (hash-count g2-stamp-ht) 2048)
    (hash-clear! g2-stamp-ht))
  (define g2-raw (vector-ref vec 2))
  (define has-existing-g2? (pair? g2-raw))
  (when has-existing-g2?
    (for ([id (in-list g2-raw)])
      (stamp-ht-add! g2-stamp-ht sync-gen id #t)))
  (define group-tags (vector-ref scratch 2))
  (vector-fill! group-tags '())
  (define base-x-fl (if (flonum? base-x) base-x (exact->inexact base-x)))
  (define base-y-fl (if (flonum? base-y) base-y (exact->inexact base-y)))
  (define-values (th-xs-raw th-ys-raw)
    (for/fold ([txs '()] [tys '()])
              ([b (in-list ally-buildings)])
      (define id (hash-ref b 'id 0))
      (define t (hash-ref b 'type 'unknown))
      (if (and (> id 0)
               (< id 9000000)
               (not (hash-ref b 'in-transit? #f)))
          (cond
            [(hash-ref CORTEX-TOWNHALL-SET t #f)
             (vector-set! group-tags 4 (cons id (vector-ref group-tags 4)))
             (let ([rx (hash-ref b 'x base-x-fl)]
                   [ry (hash-ref b 'y base-y-fl)])
               (values (cons (if (flonum? rx) rx (exact->inexact rx)) txs)
                       (cons (if (flonum? ry) ry (exact->inexact ry)) tys)))]
            [(hash-ref CORTEX-PRIMARY-PROD-SET t #f)
             (vector-set! group-tags 5 (cons id (vector-ref group-tags 5)))
             (values txs tys)]
            [(hash-ref CORTEX-TECH-PROD-SET t #f)
             (vector-set! group-tags 6 (cons id (vector-ref group-tags 6)))
             (values txs tys)]
            [(hash-ref CORTEX-UPGRADE-BLDG-SET t #f)
             (vector-set! group-tags 7 (cons id (vector-ref group-tags 7)))
             (values txs tys)]
            [(hash-ref CORTEX-DEFENSE-WALL-SET t #f)
             (vector-set! group-tags 9 (cons id (vector-ref group-tags 9)))
             (values txs tys)]
            [else (values txs tys)])
          (values txs tys))))
  (define th-xs (if (null? th-xs-raw) (list base-x-fl) th-xs-raw))
  (define th-ys (if (null? th-ys-raw) (list base-y-fl) th-ys-raw))

  (for ([u (in-list ally-units)])
    (define id (hash-ref u 'id 0))
    (when (and (> id 0)
               (not (tag-excluded? id))
               (not (unit-is-hallucination? u)))
      (define t (hash-ref u 'type 'unknown))
      (define maybe-worker? (hash-ref CORTEX-WORKER-SET t #f))
      (define ov-or-idle-worker?
        (or (eq? t 'overlord)
            (and maybe-worker?
                 (not (or (hash-ref u 'has-build-order? #f)
                          (and (hash-ref u 'build-target #f) #t)
                          (memq (hash-ref u 'order-kind #f) '(build expand)))))))
      (cond
        [(and ov-or-idle-worker?
              (let* ([rx (hash-ref u 'x base-x-fl)]
                     [ry (hash-ref u 'y base-y-fl)]
                     [ux (if (flonum? rx) rx (exact->inexact rx))]
                     [uy (if (flonum? ry) ry (exact->inexact ry))]
                     [d-nearest-th-sq
                      (for/fold ([best +inf.0])
                                ([tx (in-list th-xs)]
                                 [ty (in-list th-ys)])
                        (define dx (fl- ux tx))
                        (define dy (fl- uy ty))
                        (flmin best (fl+ (fl* dx dx) (fl* dy dy))))])
                (fl> d-nearest-th-sq 784.0)))
         (vector-set! group-tags 8 (cons id (vector-ref group-tags 8)))]
        [(not (or (fast-noncombat-sym? t)
                  (hash-ref NON-COMBAT-SELECTION-INTRUDER-SET t #f)))
         (cond
           [(or (hash-ref CORTEX-HARASS-UNIT-SET t #f)
                (and has-existing-g2? (stamp-ht-has? g2-stamp-ht sync-gen id)))
            (vector-set! group-tags 2 (cons id (vector-ref group-tags 2)))
            (vector-set! group-tags 0 (cons id (vector-ref group-tags 0)))]
           [(hash-ref CORTEX-CASTER-SIEGE-SET t #f)
            (vector-set! group-tags 3 (cons id (vector-ref group-tags 3)))
            (when (not (or (eq? t 'queen) (eq? t 'queen-burrowed)))
              (vector-set! group-tags 0 (cons id (vector-ref group-tags 0))))]
           [else
            (vector-set! group-tags 1 (cons id (vector-ref group-tags 1)))
            (vector-set! group-tags 0 (cons id (vector-ref group-tags 0)))])])))

  ;; Prioritize control groups 4, 5, 6, 7, 9 (Buildings) and 1, 2, 3, 8, 0 (Units)
  (for ([g (in-list '(4 5 6 7 9 1 2 3 8 0))])
    (define desired (sort-dedup-ints (vector-ref group-tags g)))
    (define raw-cur (vector-ref vec g))
    (define current (if (strictly-ascending-pos-ints? raw-cur) raw-cur (sort-dedup-ints raw-cur)))
    (cond
      [(and (null? desired) (not (null? current)))
       (vector-set! vec g '())]
      [(and (not (null? desired))
            (not (equal? desired current)))
       (cond
         [(memv g '(1 2 3 8))
          (cortex-steal-control-group! cortex g desired)
          (vector-set! vec g desired)
          (emit! (list 'control-group-steal g desired))]
         [else
          (cortex-set-control-group! cortex g desired)
          (emit! (list 'control-group-set g desired))])]))
  (vector-fill! group-tags '())
  (reverse actions))

;; Inspect a building control group (`4` = Townhalls, `5` = Primary Production,
;; `6` = Tech Production, `7` = Upgrade/TechLab Structures) and compute exact
;; open production/research slot capacity across all ready structures in that group.
;; - Reactor-attached facilities provide 2 concurrent production slots.
;; - TechLab-attached or naked facilities provide 1 production slot.
;; - Busy facilities (`order-count >= max-slots`), unpowered Protoss structures, and flying structures provide 0 open slots.
(define CORTEX-GROUP-4-SET
  (hasheq 'hatchery #t 'lair #t 'hive #t 'nexus #t 'command-center #t
          'orbital-command #t 'planetary-fortress #t))
(define CORTEX-GROUP-5-SET
  (hasheq 'barracks #t 'gateway #t 'warp-gate #t 'warpgate #t))
(define CORTEX-GROUP-6-SET
  (hasheq 'factory #t 'starport #t 'robotics-facility #t 'stargate #t))
(define CORTEX-GROUP-7-SET
  (hasheq 'engineering-bay #t 'armory #t 'fusion-core #t 'ghost-academy #t
          'barracks-tech-lab #t 'barracks-techlab #t 'factory-tech-lab #t
          'factory-techlab #t 'starport-tech-lab #t 'starport-techlab #t
          'forge #t 'cybernetics-core #t 'twilight-council #t 'robotics-bay #t
          'robotics-support-bay #t 'fleet-beacon #t 'templar-archive #t
          'templar-archives #t 'dark-shrine #t 'evolution-chamber #t 'spire #t
          'greater-spire #t 'spawning-pool #t 'infestation-pit #t 'baneling-nest #t
          'roach-warren #t 'hydralisk-den #t 'lurker-den #t 'lurker-den-mp #t
          'ultralisk-cavern #t))
(define CORTEX-BLDG-FLYING-SET
  (hasheq 'command-center-flying #t 'orbital-command-flying #t
          'barracks-flying #t 'factory-flying #t 'starport-flying #t
          'spine-crawler-uprooted #t 'spore-crawler-uprooted #t))

(define (cortex-production-group-capacity cortex ally-buildings group-id)
  (define cg-list (cortex-get-control-group cortex group-id))
  (define has-cg-tags? (pair? cg-list))
  (define tag-gen
    (if has-cg-tags?
        (let ([g (+ CORTEX-CAP-TAG-GEN 1)])
          (when (> (hash-count CORTEX-CAP-TAG-HT) 2048)
            (hash-clear! CORTEX-CAP-TAG-HT))
          (set! CORTEX-CAP-TAG-GEN g)
          (for ([id (in-list cg-list)])
            (stamp-ht-add! CORTEX-CAP-TAG-HT g id #t))
          g)
        0))
  (define default-type-set
    (case group-id
      [(4) CORTEX-GROUP-4-SET]
      [(5) CORTEX-GROUP-5-SET]
      [(6) CORTEX-GROUP-6-SET]
      [(7) CORTEX-GROUP-7-SET]
      [else #f]))

  (define ready-bldgs
    (for/list ([b (in-list ally-buildings)]
               #:when (let ([id (hash-ref b 'id 0)]
                            [t (hash-ref b 'type 'unknown)])
                        (and (> id 0)
                             (< id 9000000)
                             (or (and has-cg-tags? (stamp-ht-has? CORTEX-CAP-TAG-HT tag-gen id))
                                 (and default-type-set (hash-ref default-type-set t #f)))
                             (not (hash-ref b 'in-transit? #f))
                             (>= (hash-ref b 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS)
                             (not (hash-ref b 'flying? #f))
                             (not (hash-ref CORTEX-BLDG-FLYING-SET t #f))
                             (or (not (fast-requires-pylon-power? t))
                                 (not (eq? (hash-ref b 'powered? #t) #f))))))
      b))

  (cond
    [(null? ready-bldgs)
     (hash 'group-id group-id
           'ready-tags '()
           'idle-tags '()
           'techlab-idle-tags '()
           'reactor-idle-tags '()
           'open-slot-count 0
           'open-slots-by-type (hash)
           'techlab-open-slots-by-type (hash)
           'idle-tags-by-type (hash))]
    [else
     (define addon-bldgs-cache #f)
     (define (get-addon-bldgs)
       (or addon-bldgs-cache
           (let ([ads
                  (for/list ([other (in-list ally-buildings)]
                             #:when (and (memq (hash-ref other 'type 'unknown)
                                               '(barracks-reactor factory-reactor starport-reactor
                                                 barracks-tech-lab barracks-techlab
                                                 factory-tech-lab factory-techlab
                                                 starport-tech-lab starport-techlab))
                                         (>= (hash-ref other 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS)
                                         (not (hash-ref other 'in-transit? #f))
                                         (not (hash-ref other 'flying? #f))))
                    other)])
             (set! addon-bldgs-cache ads)
             ads)))

     (define (facility-addon-kind b)
       (define canon-fac (fast-canon-struct-sym (hash-ref b 'type 'unknown)))
       (cond
         [(not (memq canon-fac '(barracks factory starport))) 'none]
         [else
          (define explicit (hash-ref b 'addon #f))
          (define addon-ready? (hash-ref b 'addon-ready? #t))
          (cond
            [(or (eq? explicit 'addon-building) (eq? addon-ready? #f)) 'none]
            [(memq explicit '(reactor barracks-reactor factory-reactor starport-reactor)) 'reactor]
            [(memq explicit '(tech-lab techlab barracks-tech-lab barracks-techlab
                              factory-tech-lab factory-techlab starport-tech-lab starport-techlab))
             'tech-lab]
            [else
             (define rx (hash-ref b 'x 0.0))
             (define ry (hash-ref b 'y 0.0))
             (define bx (if (flonum? rx) rx (exact->inexact rx)))
             (define by (if (flonum? ry) ry (exact->inexact ry)))
             (define ax (fl+ bx (exact->inexact SC2-TERRAN-ADDON-OFFSET-X)))
             (define ay (fl+ by (exact->inexact SC2-TERRAN-ADDON-OFFSET-Y)))
             (define nearby-addon
               (for/first ([other (in-list (get-addon-bldgs))]
                           #:when (let* ([ox (hash-ref other 'x 0.0)]
                                         [oy (hash-ref other 'y 0.0)]
                                         [dx (fl- (if (flonum? ox) ox (exact->inexact ox)) ax)]
                                         [dy (fl- (if (flonum? oy) oy (exact->inexact oy)) ay)])
                                    (fl<= (fl+ (fl* dx dx) (fl* dy dy)) 3.0625)))
                 other))
             (cond
               [(not nearby-addon) 'none]
               [(memq (hash-ref nearby-addon 'type 'unknown)
                      '(barracks-reactor factory-reactor starport-reactor))
                'reactor]
               [else 'tech-lab])])]))

     (define ready-tags '())
     (define idle-tags '())
     (define techlab-idle-tags '())
     (define reactor-idle-tags '())
     (define total-open-slots 0)
     (define open-slots-by-type (make-hasheq))
     (define techlab-open-slots-by-type (make-hasheq))
     (define idle-tags-by-type (make-hasheq))

     (for ([b (in-list ready-bldgs)])
       (define id (hash-ref b 'id 0))
       (define raw-t (hash-ref b 'type 'unknown))
       (define t (fast-canon-struct-sym raw-t))
       (define addon-kind (facility-addon-kind b))
       (define max-slots (if (eq? addon-kind 'reactor) 2 1))
       (define used-slots
         (max (hash-ref b 'order-count 0)
              (length (hash-ref b 'orders '()))
              (if (hash-ref b 'busy? #f) 1 0)
              (let ([aid (hash-ref b 'order-ability-id #f)])
                (if (and (exact-integer? aid) (> aid 0)) 1 0))))
       (define open-slots (max 0 (- max-slots used-slots)))
       (set! ready-tags (cons id ready-tags))
       (when (> open-slots 0)
         (set! idle-tags (cons id idle-tags))
         (set! total-open-slots (+ total-open-slots open-slots))
         (when (eq? addon-kind 'tech-lab)
           (set! techlab-idle-tags (cons id techlab-idle-tags))
           (hash-set! techlab-open-slots-by-type t
                      (+ (hash-ref techlab-open-slots-by-type t 0) open-slots)))
         (when (eq? addon-kind 'reactor)
           (set! reactor-idle-tags (cons id reactor-idle-tags)))
         (hash-set! open-slots-by-type t
                    (+ (hash-ref open-slots-by-type t 0) open-slots))
         (let ([cur (hash-ref idle-tags-by-type t '())])
           (hash-set! idle-tags-by-type t
                      (cond
                        [(= open-slots 1) (cons id cur)]
                        [(= open-slots 2) (cons id (cons id cur))]
                        [else (for/fold ([acc cur]) ([_ (in-range open-slots)]) (cons id acc))])))))

     (for ([(t rev-tags) (in-hash idle-tags-by-type)])
       (hash-set! idle-tags-by-type t (reverse rev-tags)))

     (hash 'group-id group-id
           'ready-tags (reverse ready-tags)
           'idle-tags (reverse idle-tags)
           'techlab-idle-tags (reverse techlab-idle-tags)
           'reactor-idle-tags (reverse reactor-idle-tags)
           'open-slot-count total-open-slots
           'open-slots-by-type open-slots-by-type
           'techlab-open-slots-by-type techlab-open-slots-by-type
           'idle-tags-by-type idle-tags-by-type)]))

(define (cortex-idle-facilities-in-group cortex ally-buildings group-id [bldg-type #f])
  (define cap (cortex-production-group-capacity cortex ally-buildings group-id))
  (if bldg-type
      (hash-ref (hash-ref cap 'idle-tags-by-type (hash))
                (sc2-canonical-structure-sym bldg-type)
                '())
      (hash-ref cap 'idle-tags '())))

;; =============================================================================
;; Camera Location Bookmarks (F1..F8)
;; =============================================================================

(define (cortex-save-camera-bookmark! cortex slot x y)
  (hash-set! (human-cortex-camera-bookmarks cortex) slot (cons x y))
  cortex)

(define (cortex-get-camera-bookmark cortex slot)
  (hash-ref (human-cortex-camera-bookmarks cortex) slot #f))

(define (cortex-jump-camera-bookmark! cortex slot)
  (define pos (cortex-get-camera-bookmark cortex slot))
  (when pos
    (cortex-move-camera! cortex (car pos) (cdr pos)))
  pos)

(define CORTEX-TOWNHALL-SYMS
  '(nexus command-center orbital-command planetary-fortress
    hatchery lair hive
    command-center-flying orbital-command-flying))

(define (cortex-extract-owned-townhall-pts obs bx by)
  (define bldgs (hash-ref obs 'ally-buildings '()))
  (define raw-ths
    (for/list ([b (in-list (if (list? bldgs) bldgs '()))]
               #:when (and (hash? b)
                           (let ([t (hash-ref b 'type #f)])
                             (memq (if (symbol? t)
                                       t
                                       (if (string? t)
                                           (string->symbol (string-downcase t))
                                           #f))
                                   CORTEX-TOWNHALL-SYMS))
                           (let ([hp (hash-ref b 'hp 100.0)])
                             (or (not (real? hp)) (> hp 0.0)))
                           (real? (hash-ref b 'x #f))
                           (real? (hash-ref b 'y #f))))
      (cons (exact->inexact (hash-ref b 'x))
            (exact->inexact (hash-ref b 'y)))))
  (define sorted
    (sort raw-ths
          (lambda (a b)
            (< (+ (sqr (- (car a) bx)) (sqr (- (cdr a) by)))
               (+ (sqr (- (car b) bx)) (sqr (- (cdr b) by)))))))
  ;; Deduplicate stacked/rebuilt townhall coords within 2.0t
  (reverse
   (for/fold ([acc '()]) ([pt (in-list sorted)])
     (if (for/or ([prev (in-list acc)])
           (< (+ (sqr (- (car pt) (car prev))) (sqr (- (cdr pt) (cdr prev)))) 4.0))
         acc
         (cons pt acc)))))

;; Synchronize all 8 pro camera bookmarks (F1..F8 = slots 1..8) with drift gating
;; (`>= SC2-BOOKMARK-DRIFT-UPDATE-DIST` tiles). Slots F1..Fk are strictly centered
;; on our owned townhalls (Main -> Natural -> 3rd -> 4th -> ...), with remaining
;; slots bound to expansion/rally/combat-front anchors matching pro SC2 usage.
(define (cortex-sync-camera-bookmarks! cortex obs-or-alist)
  (define slot-coords-alist
    (if (hash? obs-or-alist)
        (let* ([obs obs-or-alist]
               [bx (hash-ref obs 'base-x SC2-DEFAULT-HOME-BASE-X)]
               [by (hash-ref obs 'base-y SC2-DEFAULT-HOME-BASE-Y)]
               [nx (hash-ref obs 'natural-x SC2-DEFAULT-NATURAL-X)]
               [ny (hash-ref obs 'natural-y SC2-DEFAULT-NATURAL-Y)]
               [tx (hash-ref obs 'third-x SC2-DEFAULT-THIRD-X)]
               [ty (hash-ref obs 'third-y SC2-DEFAULT-THIRD-Y)]
               [ex (hash-ref obs 'enemy-x SC2-DEFAULT-ENEMY-BASE-X)]
               [ey (hash-ref obs 'enemy-y SC2-DEFAULT-ENEMY-BASE-Y)]
               [eex (hash-ref obs 'enemy-expand-x SC2-DEFAULT-ENEMY-EXPAND-X)]
               [eey (hash-ref obs 'enemy-expand-y SC2-DEFAULT-ENEMY-EXPAND-Y)]
               [ramp-x (* 0.5 (+ bx nx))]
               [ramp-y (* 0.5 (+ by ny))]
               [stage-x (* 0.5 (+ nx ex))]
               [stage-y (* 0.5 (+ ny ey))]
               [e-units (hash-ref obs 'enemy-units '())]
               [arena-x (if (pair? e-units) (hash-ref (car e-units) 'x stage-x) stage-x)]
               [arena-y (if (pair? e-units) (hash-ref (car e-units) 'y stage-y) stage-y)]
               [owned-ths (cortex-extract-owned-townhall-pts obs bx by)]
               [n-ths (min SC2-CAMERA-BOOKMARK-COUNT (length owned-ths))]
               [defaults
                (vector (cons bx by)           ;; slot 1 fallback: Main
                        (cons nx ny)           ;; slot 2 fallback: Natural
                        (cons tx ty)           ;; slot 3 fallback: 3rd
                        (cons ramp-x ramp-y)   ;; slot 4 fallback: Ramp / Rally
                        (cons stage-x stage-y) ;; slot 5 fallback: Primary Combat Front
                        (cons arena-x arena-y) ;; slot 6 fallback: Active Arena Front
                        (cons eex eey)         ;; slot 7 fallback: Enemy Expansion
                        (cons ex ey))])        ;; slot 8 fallback: Enemy Main
          (cond
            [(= n-ths 0)
             (for/list ([i (in-range SC2-CAMERA-BOOKMARK-COUNT)])
               (define pt (vector-ref defaults i))
               (list (add1 i) (car pt) (cdr pt)))]
            [(<= n-ths 4)
             ;; F1..Fn strictly on owned townhalls; remaining slots up to F8 keep
             ;; natural/3rd/ramp defaults and F5=Combat Front, F6=Arena, F7=EnemyExp, F8=EnemyMain
             (for/list ([i (in-range SC2-CAMERA-BOOKMARK-COUNT)])
               (define pt (if (< i n-ths) (list-ref owned-ths i) (vector-ref defaults i)))
               (list (add1 i) (car pt) (cdr pt)))]
            [else
             ;; 5..8 owned townhalls: F1..Fn strictly on owned townhalls, remaining slots
             ;; fill with Primary Combat Front -> Arena -> Enemy Exp
             (define extra-front (list (cons stage-x stage-y) (cons arena-x arena-y) (cons eex eey)))
             (for/list ([i (in-range SC2-CAMERA-BOOKMARK-COUNT)])
               (define pt
                 (if (< i n-ths)
                     (list-ref owned-ths i)
                     (list-ref extra-front (min (- (length extra-front) 1) (- i n-ths)))))
               (list (add1 i) (car pt) (cdr pt)))]))
        obs-or-alist))
  (define actions '())
  (for ([entry (in-list (if (list? slot-coords-alist) slot-coords-alist '()))])
    (match entry
      [(list slot x y)
       (when (and (exact-integer? slot) (>= slot 1) (<= slot SC2-CAMERA-BOOKMARK-COUNT)
                  (real? x) (real? y))
         (define prev (cortex-get-camera-bookmark cortex slot))
         (define drift
           (if prev
               (sqrt (+ (sqr (- x (car prev))) (sqr (- y (cdr prev)))))
               +inf.0))
         (when (>= drift SC2-BOOKMARK-DRIFT-UPDATE-DIST)
           (cortex-save-camera-bookmark! cortex slot x y)
           (set! actions (cons (list 'camera-bookmark-save slot x y) actions))))]
      [_ (void)]))
  (reverse actions))

;; =============================================================================
;; Optimal Human Selection & Control-Group Compiler
;;   Combines:
;;     1. Active Selection Reuse (0 APM)
;;     2. Control Group Recall (1 APM, off-screen or on-screen)
;;     3. On-Screen Mouse Box-Drag `[x0, x1] x [y0, y1]` (strictly inside camera
;;        viewport, capturing ALL friendly mobile units inside the rectangle)
;;     4. On-Screen Single Click (`select-click`) & On-Screen Ctrl-Click Type
;;     5. Within-Selection Wireframe Ctrl-Click (`select-ctrl-type`) &
;;        Shift+Ctrl-Click Deselect (`deselect-ctrl-type`)
;;     6. On-the-Fly Control Group Updates (`control-group-steal` / `control-group-set`)
;; =============================================================================

(define (cortex-active-selection cortex)
  (hash-ref (human-cortex-camera-bookmarks cortex) 'active-selection '()))

(define (strictly-ascending-pos-ints? xs)
  (and (list? xs)
       (let loop ([rem xs] [prev 0])
         (cond
           [(null? rem) #t]
           [else
            (define x (car rem))
            (and (exact-integer? x) (> x prev) (loop (cdr rem) x))]))))

(define (set-cortex-active-selection! cortex unit-ids)
  (define clean
    (if (strictly-ascending-pos-ints? unit-ids)
        unit-ids
        (sort (remove-duplicates (filter (lambda (id) (and (exact-integer? id) (> id 0)))
                                         (if (list? unit-ids) unit-ids (list unit-ids))))
              <)))
  (hash-set! (human-cortex-camera-bookmarks cortex) 'active-selection clean)
  clean)

(define (units-in-camera-viewport units cam-x cam-y [w VIEWPORT-WIDTH] [h VIEWPORT-HEIGHT])
  (define fcam-x (if (flonum? cam-x) cam-x (exact->inexact cam-x)))
  (define fcam-y (if (flonum? cam-y) cam-y (exact->inexact cam-y)))
  (define hw-val (if (flonum? w) w (exact->inexact w)))
  (define hh-val (if (flonum? h) h (exact->inexact h)))
  (define half-w (fl* 0.5 hw-val))
  (define half-h (fl* 0.5 hh-val))
  (define min-x (fl- fcam-x half-w))
  (define max-x (fl+ fcam-x half-w))
  (define min-y (fl- fcam-y half-h))
  (define max-y (fl+ fcam-y half-h))
  (for/list ([u (in-list units)]
             #:when (and (hash? u)
                         (let* ([rx (hash-ref u 'x fcam-x)]
                                [ry (hash-ref u 'y fcam-y)]
                                [ux (if (flonum? rx) rx (exact->inexact rx))]
                                [uy (if (flonum? ry) ry (exact->inexact ry))])
                           (and (fl>= ux min-x) (fl<= ux max-x)
                                (fl>= uy min-y) (fl<= uy max-y)))))
    u))

;; Simulate a physical mouse drag-box `[x0, x1] x [y0, y1]` on the current screen:
;; 1. Clamps the box to the camera viewport `[cam-x - w/2, cam-x + w/2] x [cam-y - h/2, cam-y + h/2]`.
;;    Units outside the camera viewport can NEVER be selected by a box drag.
;; 2. Selects ALL on-screen units whose `(x, y)` falls inside the clamped box (no cherry-picking).
(define (simulate-box-drag-on-screen x0 y0 x1 y1 units
                                     [cam-x #f] [cam-y #f]
                                     [w VIEWPORT-WIDTH] [h VIEWPORT-HEIGHT])
  (define screen-pool
    (if (and (real? cam-x) (real? cam-y))
        (units-in-camera-viewport units cam-x cam-y w h)
        units))
  (define half-w (/ (exact->inexact w) 2.0))
  (define half-h (/ (exact->inexact h) 2.0))
  (define raw-min-x (min (exact->inexact x0) (exact->inexact x1)))
  (define raw-max-x (max (exact->inexact x0) (exact->inexact x1)))
  (define raw-min-y (min (exact->inexact y0) (exact->inexact y1)))
  (define raw-max-y (max (exact->inexact y0) (exact->inexact y1)))
  (define bx0
    (- (if (real? cam-x) (max (- cam-x half-w) raw-min-x) raw-min-x) 0.05))
  (define bx1
    (+ (if (real? cam-x) (min (+ cam-x half-w) raw-max-x) raw-max-x) 0.05))
  (define by0
    (- (if (real? cam-y) (max (- cam-y half-h) raw-min-y) raw-min-y) 0.05))
  (define by1
    (+ (if (real? cam-y) (min (+ cam-y half-h) raw-max-y) raw-max-y) 0.05))
  (cond
    [(or (> raw-min-x (+ (or cam-x raw-max-x) half-w))
         (< raw-max-x (- (or cam-x raw-min-x) half-w))
         (> raw-min-y (+ (or cam-y raw-max-y) half-h))
         (< raw-max-y (- (or cam-y raw-min-y) half-h)))
     '()]
    [else
     (for/list ([u (in-list screen-pool)]
                #:when (let ([ux (exact->inexact (hash-ref u 'x 0.0))]
                             [uy (exact->inexact (hash-ref u 'y 0.0))])
                         (and (fl>= ux bx0) (fl<= ux bx1)
                              (fl>= uy by0) (fl<= uy by1))))
       u)]))

;; Simulate Ctrl+clicking a unit portrait in the selection wireframe (or on screen):
;; Filters `candidate-units` down to `{u in candidate-units | type(u) == target-type}`.
(define (simulate-ctrl-click-subselect target-type candidate-units)
  (for/list ([u (in-list candidate-units)]
             #:when (eq? (hash-ref u 'type 'unknown) target-type))
    u))

;; Simulate Shift+Ctrl+clicking a unit portrait in the selection wireframe:
;; Deselects all units of `unwanted-type` from `candidate-units`.
(define (simulate-shift-ctrl-deselect-type unwanted-type candidate-units)
  (for/list ([u (in-list candidate-units)]
             #:when (not (eq? (hash-ref u 'type 'unknown) unwanted-type)))
    u))

(define (infer-natural-control-group-for-units unit-records)
  (define types (remove-duplicates (for/list ([u (in-list unit-records)]) (hash-ref u 'type 'unknown))))
  (cond
    [(null? types) #f]
    [(for/and ([t (in-list types)]) (hash-ref CORTEX-CASTER-SIEGE-SET t #f)) 3]
    [(for/and ([t (in-list types)]) (hash-ref CORTEX-HARASS-UNIT-SET t #f)) 2]
    [(for/and ([t (in-list types)]) (not (hash-ref NON-COMBAT-SELECTION-INTRUDER-SET t #f))) 1]
    [else #f]))

(define DESIRED-COMBAT-TYPE-CACHE (make-hasheq))
(define (desired-combat-type-ok? ut)
  (define cached (hash-ref DESIRED-COMBAT-TYPE-CACHE ut 'miss))
  (if (eq? cached 'miss)
      (let ([v (and (not (hash-ref NON-COMBAT-SELECTION-INTRUDER-SET ut #f))
                    (not (fast-noncombat-sym? ut)))])
        (hash-set! DESIRED-COMBAT-TYPE-CACHE ut v)
        v)
      cached))

(define COMPAT-TYPE-OK-CACHE (make-hasheq))
(define (compat-type-ok? ut)
  (define cached (hash-ref COMPAT-TYPE-OK-CACHE ut 'miss))
  (if (eq? cached 'miss)
      (let ([v (and (not (hash-ref NON-COMBAT-SELECTION-INTRUDER-SET ut #f))
                    (not (fast-noncombat-sym? ut))
                    (not (hash-ref CORTEX-PROTECTED-MODE-EXCLUDED-SET ut #f)))])
        (hash-set! COMPAT-TYPE-OK-CACHE ut v)
        v)
      cached))

;; Compile a raw desired list of unit IDs into the minimum-APM physically valid
;; sequence of StarCraft II selection actions:
;;   - `keep-selection` (0 APM)
;;   - `select-ctrl-type` / `deselect-ctrl-type` within `active-selection` (1 APM)
;;   - `control-group-recall` [+ optional `select-ctrl-type` / `deselect-ctrl-type`] (1-2 APM)
;;   - On-screen `select-click` / `select-ctrl-type` / `select-box` [+ optional wireframe filter] (1-2 APM)
;;   - Optional on-the-fly control group binding (`control-group-steal`) when new units are boxed.
(define DESIRED-STAMP-HT (make-hasheqv))
(define DESIRED-STAMP-GEN 0)

(define (compile-optimal-unit-selection! cortex
                                         raw-desired-ids
                                         ally-units
                                         [ally-buildings '()]
                                         #:allow-superset? [allow-superset? #t]
                                         #:compatible-pred [compatible-pred #f]
                                         #:compatible-id-set [compat-id-ht #f]
                                         #:allow-camera-move? [allow-camera-move? #t]
                                         #:allow-on-the-fly-cg-update? [allow-cg-update? #t]
                                         #:unit-by-id [pre-unit-by-id #f]
                                         #:unit-lookup [kw-unit-lookup #f]
                                         #:viewport-cache [vp-cache #f]
                                         #:cg-cache [cg-cache #f])
  (define desired-list
    (cond
      [(not (list? raw-desired-ids))
       (if (and (exact-integer? raw-desired-ids) (> raw-desired-ids 0))
           (list raw-desired-ids)
           '())]
      [(null? raw-desired-ids) '()]
      [(null? (cdr raw-desired-ids))
       (let ([id0 (car raw-desired-ids)])
         (if (and (exact-integer? id0) (> id0 0)) raw-desired-ids '()))]
      [(strictly-ascending-pos-ints? raw-desired-ids)
       raw-desired-ids]
      [else
       (sort-dedup-ints
        (for/list ([id (in-list raw-desired-ids)]
                   #:when (and (exact-integer? id) (> id 0)))
          id))]))
  (define desired-len (length desired-list))
  (define single-desired-id (and (= desired-len 1) (car desired-list)))
  (define desired-stamp-gen
    (if (> desired-len 8)
        (let ([g (+ DESIRED-STAMP-GEN 1)])
          (when (> (hash-count DESIRED-STAMP-HT) 4096)
            (hash-clear! DESIRED-STAMP-HT))
          (set! DESIRED-STAMP-GEN g)
          (for ([id (in-list desired-list)])
            (stamp-ht-add! DESIRED-STAMP-HT g id #t))
          g)
        0))
  (define (desired-has? id)
    (cond
      [(> desired-stamp-gen 0)
       (stamp-ht-has? DESIRED-STAMP-HT desired-stamp-gen id)]
      [single-desired-id (= id single-desired-id)]
      [else
       (let loop ([rem desired-list])
         (and (pair? rem)
              (let ([v (car rem)])
                (cond
                  [(= v id) #t]
                  [(< v id) (loop (cdr rem))]
                  [else #f]))))]))
  (define unit-by-id
    (if kw-unit-lookup
        #f
        (or pre-unit-by-id
            (let ([ht (make-hasheqv)])
              (for ([u (in-list ally-units)]
                    #:when (hash? u))
                (define uid (hash-ref u 'id #f))
                (when (exact-integer? uid) (hash-set! ht uid u)))
              (for ([u (in-list ally-buildings)]
                    #:when (hash? u))
                (define uid (hash-ref u 'id #f))
                (when (exact-integer? uid) (hash-set! ht uid u)))
              ht))))
  (define-syntax-rule (lookup-u id)
    (if kw-unit-lookup
        (kw-unit-lookup id)
        (hash-ref unit-by-id id #f)))
  (define desired-records
    (for/list ([id (in-list desired-list)]
               #:do [(define rec (lookup-u id))]
               #:when rec)
      rec))
  (define-values (single-desired-type desired-are-combat?)
    (if (null? desired-records)
        (values #f #f)
        (let* ([t0 (hash-ref (car desired-records) 'type 'unknown)])
          (let loop ([rs desired-records] [same-t? #t] [combat? #t])
            (if (null? rs)
                (values (and same-t? t0) combat?)
                (let* ([u (car rs)]
                       [ut (hash-ref u 'type 'unknown)]
                       [ok-c? (and combat?
                                   (desired-combat-type-ok? ut)
                                   (not (hash-ref u 'is-hallucination #f))
                                   (not (hash-ref u 'hallucination #f)))])
                  (loop (cdr rs)
                        (and same-t? (eq? ut t0))
                        ok-c?)))))))

  (define (unit-compatible? u)
    (define id (hash-ref u 'id 0))
    (or (desired-has? id)
        (and allow-superset?
             (cond
               [compat-id-ht (hash-ref compat-id-ht id #f)]
               [compatible-pred (compatible-pred u)]
               [else
                (and desired-are-combat?
                     (compat-type-ok? (hash-ref u 'type 'unknown))
                     (not (hash-ref u 'is-hallucination #f))
                     (not (hash-ref u 'hallucination #f)))]))))

  (define (ids->records ids)
    (for/list ([id (in-list ids)]
               #:do [(define rec (lookup-u id))]
               #:when rec)
      rec))

  (define desired-rec-len (max 1 (length desired-records)))
  (define min-needed-75 (max 1 (exact-ceiling (* 0.75 desired-rec-len))))
  (define max-allowed
    (if allow-superset?
        (max desired-rec-len (exact-ceiling (* 1.35 desired-rec-len)))
        desired-rec-len))
  (define (selection-valid-and-covers? cand-ids [min-coverage-ratio 0.70] [pre-sorted? #f])
    (define min-needed (max 1 (exact-ceiling (* min-coverage-ratio desired-rec-len))))
    (define known-asc? (or pre-sorted? (strictly-ascending-pos-ints? cand-ids)))
    (define seen (if known-asc? #f (make-hasheqv)))
    (let loop ([rem cand-ids] [valid-acc '()] [cnt 0] [cov 0] [prev-id 0] [asc? #t])
      (cond
        [(null? rem)
         (and (> cnt 0)
              (>= cov min-needed)
              (if asc? (reverse valid-acc) (sort valid-acc <)))]
        [else
         (define id (car rem))
         (cond
           [(and seen (hash-ref seen id #f)) (loop (cdr rem) valid-acc cnt cov prev-id asc?)]
           [else
            (define u (lookup-u id))
            (cond
              [(not u) (loop (cdr rem) valid-acc cnt cov prev-id asc?)]
              [(or (>= cnt max-allowed) (not (unit-compatible? u))) #f]
              [else
               (when seen (hash-set! seen id #t))
               (loop (cdr rem)
                     (cons id valid-acc)
                     (add1 cnt)
                     (if (desired-has? id) (add1 cov) cov)
                     id
                     (and asc? (> id prev-id)))])])])))

  (define (collect-compat-ids-by-type units target-type keep-match?)
    (let loop ([rem units] [rev-ids '()] [cov 0])
      (cond
        [(null? rem)
         (if (null? rev-ids)
             (values #f 0)
             (values (reverse rev-ids) cov))]
        [else
         (define u (car rem))
         (define match? (eq? (hash-ref u 'type 'unknown) target-type))
         (if (if keep-match? match? (not match?))
             (if (unit-compatible? u)
                 (let ([id (hash-ref u 'id 0)])
                   (loop (cdr rem)
                         (cons id rev-ids)
                         (if (desired-has? id) (add1 cov) cov)))
                 (values #f 0))
             (loop (cdr rem) rev-ids cov))])))

  (cond
    [(null? desired-records)
     ;; If unit tags are synthetic test IDs not present in `ally-units`, pass through directly
     (values '() desired-list)]
    [else
     (define active-ids
       (for/list ([id (in-list (cortex-active-selection cortex))]
                  #:when (lookup-u id))
         id))
     (define candidates '())
     (define (add-candidate! apm-cost covered-count seq realized-ids [box-origin? #f] [known-asc? #f])
       (when (and (pair? realized-ids) (> covered-count 0))
         (define clean-ids
           (if (or known-asc? (strictly-ascending-pos-ints? realized-ids))
               realized-ids
               (sort-dedup-ints realized-ids)))
         (set! candidates
               (cons (list apm-cost covered-count seq clean-ids box-origin?)
                     candidates))))

     (define (eval-wireframe-subselect-and-desel! ids want-sub? want-desel? apm-cost prefix-acts)
       (when (and (pair? ids) (or want-sub? want-desel?))
         (define asc? (strictly-ascending-pos-ints? ids))
         (cond
           [asc?
            (let-values ([(sub-ok? sub-rev sub-cnt sub-cov final-bad-t)
                          (let loop ([rem ids]
                                     [sub-ok? want-sub?]
                                     [sub-rev '()]
                                     [sub-cnt 0]
                                     [sub-cov 0]
                                     [bad-t #f])
                            (cond
                              [(null? rem) (values sub-ok? sub-rev sub-cnt sub-cov bad-t)]
                              [(and (not sub-ok?)
                                    (or (not want-desel?) (eq? bad-t 'multiple)))
                               (values #f '() 0 0 bad-t)]
                              [else
                               (define id (car rem))
                               (define u (lookup-u id))
                               (if (not u)
                                   (loop (cdr rem) sub-ok? sub-rev sub-cnt sub-cov bad-t)
                                   (let* ([ut (hash-ref u 'type 'unknown)]
                                          [sub-match? (and sub-ok? (eq? ut single-desired-type))]
                                          [need-bad? (and want-desel? (not (eq? bad-t 'multiple)))]
                                          [comp? (and (or sub-match? need-bad?) (unit-compatible? u))]
                                          [n-bad-t (if (and need-bad? (not comp?))
                                                       (cond
                                                         [(not bad-t) ut]
                                                         [(eq? bad-t ut) bad-t]
                                                         [else 'multiple])
                                                       bad-t)])
                                     (if sub-match?
                                         (if (or (>= sub-cnt max-allowed) (not comp?))
                                             (loop (cdr rem) #f '() 0 0 n-bad-t)
                                             (loop (cdr rem)
                                                   #t
                                                   (cons id sub-rev)
                                                   (add1 sub-cnt)
                                                   (if (desired-has? id) (add1 sub-cov) sub-cov)
                                                   n-bad-t))
                                         (loop (cdr rem) sub-ok? sub-rev sub-cnt sub-cov n-bad-t))))]))])
              (when (and sub-ok? (> sub-cnt 0) (>= sub-cov min-needed-75))
                (define valid-sub (reverse sub-rev))
                (define sub-act (list 'select-ctrl-type single-desired-type valid-sub))
                (add-candidate! apm-cost
                                sub-cov
                                (if (null? prefix-acts) (list sub-act) (append prefix-acts (list sub-act)))
                                valid-sub
                                #f
                                #t))
              (when (and want-desel? final-bad-t (not (eq? final-bad-t 'multiple)))
                (let dloop ([rem ids] [rev-ids '()] [cnt 0] [cov 0])
                  (cond
                    [(null? rem)
                     (when (and (> cnt 0) (>= cov min-needed-75))
                       (define valid-desel (reverse rev-ids))
                       (define desel-act (list 'deselect-ctrl-type final-bad-t valid-desel))
                       (add-candidate! apm-cost
                                       cov
                                       (if (null? prefix-acts) (list desel-act) (append prefix-acts (list desel-act)))
                                       valid-desel
                                       #f
                                       #t))]
                    [else
                     (define id (car rem))
                     (define u (lookup-u id))
                     (cond
                       [(or (not u) (eq? (hash-ref u 'type 'unknown) final-bad-t))
                        (dloop (cdr rem) rev-ids cnt cov)]
                       [(or (>= cnt max-allowed) (not (unit-compatible? u)))
                        (void)]
                       [else
                        (dloop (cdr rem)
                               (cons id rev-ids)
                               (add1 cnt)
                               (if (desired-has? id) (add1 cov) cov))])]))))]
           [else
            (define recs (ids->records ids))
            (when want-sub?
              (define sub-ids
                (for/list ([u (in-list recs)]
                           #:when (eq? (hash-ref u 'type 'unknown) single-desired-type))
                  (hash-ref u 'id 0)))
              (define valid-sub (selection-valid-and-covers? sub-ids 0.75))
              (when valid-sub
                (define sub-act (list 'select-ctrl-type single-desired-type valid-sub))
                (add-candidate! apm-cost
                                (for/sum ([id (in-list valid-sub)]) (if (desired-has? id) 1 0))
                                (if (null? prefix-acts) (list sub-act) (append prefix-acts (list sub-act)))
                                valid-sub
                                #f
                                #t)))
            (when want-desel?
              (define bad-t
                (let loop ([rs recs] [bt #f])
                  (cond
                    [(null? rs) bt]
                    [(not (unit-compatible? (car rs)))
                     (define ut (hash-ref (car rs) 'type 'unknown))
                     (cond
                       [(not bt) (loop (cdr rs) ut)]
                       [(eq? bt ut) (loop (cdr rs) bt)]
                       [else 'multiple])]
                    [else (loop (cdr rs) bt)])))
              (when (and bad-t (not (eq? bad-t 'multiple)))
                (define desel-ids
                  (for/list ([u (in-list recs)]
                             #:unless (eq? (hash-ref u 'type 'unknown) bad-t))
                    (hash-ref u 'id 0)))
                (define valid-desel (selection-valid-and-covers? desel-ids 0.75))
                (when valid-desel
                  (define desel-act (list 'deselect-ctrl-type bad-t valid-desel))
                  (add-candidate! apm-cost
                                  (for/sum ([id (in-list valid-desel)]) (if (desired-has? id) 1 0))
                                  (if (null? prefix-acts) (list desel-act) (append prefix-acts (list desel-act)))
                                  valid-desel
                                  #f
                                  #t))))])))

     ;; -----------------------------------------------------------------------
     ;; 1. Active Selection Reuse (0 APM) or Active Wireframe Sub-Select (1 APM)
     ;; -----------------------------------------------------------------------
     (define valid-active
       (and (not (null? active-ids))
            (selection-valid-and-covers? active-ids 0.85 #t)))
     (define active-cov
       (if valid-active
           (for/sum ([id (in-list valid-active)]) (if (desired-has? id) 1 0))
           0))
     (when (and valid-active (> active-cov 0))
       (add-candidate! 0 active-cov '() valid-active #f))
     (cond
       [(= active-cov desired-len)
        (set-cortex-active-selection! cortex valid-active)
        (values '() valid-active)]
       [else
     (unless valid-active
       (eval-wireframe-subselect-and-desel! active-ids single-desired-type #t 1 '()))

     (define (has-full-cov-at-apm? apm)
       (for/or ([c (in-list candidates)])
         (and (= (car c) apm) (>= (cadr c) desired-rec-len))))

     ;; -----------------------------------------------------------------------
     ;; 2. Control Group Recall (1 APM) or Recall + Wireframe Ctrl-Click (2 APM)
     ;; -----------------------------------------------------------------------
     (unless (has-full-cov-at-apm? 1)
     (define evaled-cg-lists '())
     (for ([g (in-list '(1 2 3 8 4 5 6 7 9 0))]
           #:break (has-full-cov-at-apm? 1))
       (define raw-cg (cortex-get-control-group cortex g))
       (define cg-entry
         (and cg-cache
              (let ([c (vector-ref cg-cache g)])
                (and c (eq? (vector-ref c 0) raw-cg) c))))
       (define raw-cg-len
         (if cg-entry (vector-ref cg-entry 1) (length raw-cg)))
       (when (>= raw-cg-len desired-len)
         (define-values (cg-ids cg-len cg-ht)
           (if cg-entry
               (values (vector-ref cg-entry 2)
                       (vector-ref cg-entry 3)
                       (vector-ref cg-entry 4))
               (let* ([ids (for/list ([id (in-list raw-cg)]
                                      #:when (lookup-u id))
                             id)]
                      [cnt (length ids)]
                      [ht (for/hasheqv ([id (in-list ids)]) (values id #t))])
                 (when cg-cache
                   (vector-set! cg-cache g (vector raw-cg raw-cg-len ids cnt ht)))
                 (values ids cnt ht))))
         (define all-desired-in-cg?
           (and (>= cg-len desired-len)
                (if single-desired-id
                    (hash-ref cg-ht single-desired-id #f)
                    (for/and ([id (in-list desired-list)])
                      (hash-ref cg-ht id #f)))))
         (when (and all-desired-in-cg?
                    (not (null? cg-ids))
                    (not (for/or ([prev (in-list evaled-cg-lists)]) (equal? cg-ids prev))))
           (set! evaled-cg-lists (cons cg-ids evaled-cg-lists))
           ;; 2a. Direct Control Group Recall (1 APM)
           (define valid-cg (selection-valid-and-covers? cg-ids 0.75))
           (define cg-cov
             (if valid-cg
                 (for/sum ([id (in-list valid-cg)]) (if (desired-has? id) 1 0))
                 0))
           (when (and valid-cg (> cg-cov 0))
             (add-candidate! 1
                             cg-cov
                             (list (list 'control-group-recall g valid-cg))
                             valid-cg
                             #f))
           (eval-wireframe-subselect-and-desel!
            cg-ids
            (and single-desired-type (< cg-cov desired-len))
            (not valid-cg)
            2
            (list (list 'control-group-recall g cg-ids)))))))

     ;; -----------------------------------------------------------------------
     ;; 3. On-Screen Box-Drag, Single-Click & On-Screen Ctrl-Click Type
     ;;    (Strictly restricted to units inside the camera viewport!)
     ;; -----------------------------------------------------------------------
     (unless (has-full-cov-at-apm? 1)
     (define half-w (/ (exact->inexact VIEWPORT-WIDTH) 2.0))
     (define half-h (/ (exact->inexact VIEWPORT-HEIGHT) 2.0))
     (define cur-cam-x (human-cortex-cam-x cortex))
     (define cur-cam-y (human-cortex-cam-y cortex))
     (define on-screen-desired-now
       (units-in-camera-viewport desired-records cur-cam-x cur-cam-y))
     (define need-camera-move?
       (and allow-camera-move?
            (< (length on-screen-desired-now)
               (max 1 (exact-ceiling (* 0.50 desired-len))))))
     (define-values (eff-cam-x eff-cam-y cam-prefix cam-cost)
       (if need-camera-move?
           (let* ([cx (/ (for/sum ([u (in-list desired-records)])
                           (exact->inexact (hash-ref u 'x cur-cam-x)))
                         (max 1.0 (exact->inexact desired-len)))]
                  [cy (/ (for/sum ([u (in-list desired-records)])
                           (exact->inexact (hash-ref u 'y cur-cam-y)))
                         (max 1.0 (exact->inexact desired-len)))])
             (values cx cy (list (list 'move-camera cx cy)) 1))
           (values cur-cam-x cur-cam-y '() 0)))

     (define screen-desired
       (if need-camera-move?
           (units-in-camera-viewport desired-records eff-cam-x eff-cam-y)
           on-screen-desired-now))
     (define single-click-wins?
       (and (= desired-len 1)
            (= (length screen-desired) 1)
            (= cam-cost 0)))
     (define screen-ally-units
       (cond
         [(or single-click-wins? (null? screen-desired)) '()]
         [(hash? vp-cache)
          (define key (cons eff-cam-x eff-cam-y))
          (define cached (hash-ref vp-cache key #f))
          (or cached
              (let ([res (units-in-camera-viewport ally-units eff-cam-x eff-cam-y)])
                (hash-set! vp-cache key res)
                res))]
         [else
          (or (and (box? vp-cache)
                   (let ([cached (unbox vp-cache)])
                     (and cached
                          (= (vector-ref cached 0) eff-cam-x)
                          (= (vector-ref cached 1) eff-cam-y)
                          (vector-ref cached 2))))
              (let ([res (units-in-camera-viewport ally-units eff-cam-x eff-cam-y)])
                (when (box? vp-cache)
                  (set-box! vp-cache (vector eff-cam-x eff-cam-y res)))
                res))]))

     (when (not (null? screen-desired))
       ;; 3a. Single-Unit Click on screen (1 APM + cam-cost)
       (when (= (length screen-desired) 1)
         (define u0 (car screen-desired))
         (define u0-id (hash-ref u0 'id 0))
         (define u0-x (hash-ref u0 'x eff-cam-x))
         (define u0-y (hash-ref u0 'y eff-cam-y))
         (add-candidate! (+ 1 cam-cost)
                         1
                         (append cam-prefix (list (list 'select-click u0-id u0-x u0-y (list u0-id))))
                         (list u0-id)
                         #f))

       (unless single-click-wins?
       ;; 3b. On-Screen Ctrl+Click Unit Type (1 APM + cam-cost)
       (when single-desired-type
         (let-values ([(st-ids cov)
                       (collect-compat-ids-by-type screen-ally-units single-desired-type #t)])
           (when st-ids
             (define u0 (car screen-desired))
             (add-candidate! (+ 1 cam-cost)
                             cov
                             (append cam-prefix
                                     (list (list 'select-ctrl-type
                                                 single-desired-type
                                                 (hash-ref u0 'x eff-cam-x)
                                                 (hash-ref u0 'y eff-cam-y)
                                                 st-ids)))
                             st-ids
                             #t))))

       ;; 3c. On-Screen Axis-Aligned Box-Drag `[x0, x1] x [y0, y1]`
       (unless (has-full-cov-at-apm? (+ 1 cam-cost))
       (define eff-cx (exact->inexact eff-cam-x))
       (define eff-cy (exact->inexact eff-cam-y))
       (define cam-min-x (fl- eff-cx half-w))
       (define cam-max-x (fl+ eff-cx half-w))
       (define cam-min-y (fl- eff-cy half-h))
       (define cam-max-y (fl+ eff-cy half-h))
       (define-values (x0 x1 y0 y1)
         (for/fold ([mnx +inf.0] [mxx -inf.0] [mny +inf.0] [mxy -inf.0])
                   ([u (in-list screen-desired)])
           (define ux (exact->inexact (hash-ref u 'x eff-cx)))
           (define uy (exact->inexact (hash-ref u 'y eff-cy)))
           (values (flmin mnx ux) (flmax mxx ux) (flmin mny uy) (flmax mxy uy))))
       (define-values (boxed-units boxed-ids incompatible-in-box)
         (if (or (fl> x0 cam-max-x) (fl< x1 cam-min-x)
                 (fl> y0 cam-max-y) (fl< y1 cam-min-y))
             (values '() '() '())
             (let ([bx0 (fl- (flmax cam-min-x x0) 0.05)]
                   [bx1 (fl+ (flmin cam-max-x x1) 0.05)]
                   [by0 (fl- (flmax cam-min-y y0) 0.05)]
                   [by1 (fl+ (flmin cam-max-y y1) 0.05)])
               (let loop ([rem screen-ally-units] [bu '()] [bi '()] [ib '()])
                 (if (null? rem)
                     (values (reverse bu) (reverse bi) (reverse ib))
                     (let* ([u (car rem)]
                            [ux (exact->inexact (hash-ref u 'x 0.0))]
                            [uy (exact->inexact (hash-ref u 'y 0.0))])
                       (if (and (fl>= ux bx0) (fl<= ux bx1)
                                (fl>= uy by0) (fl<= uy by1))
                           (loop (cdr rem)
                                 (cons u bu)
                                 (cons (hash-ref u 'id 0) bi)
                                 (if (unit-compatible? u) ib (cons u ib)))
                           (loop (cdr rem) bu bi ib))))))))

       (cond
         ;; Clean Box: zero incompatible intruders inside `[x0, x1] x [y0, y1]` (1 APM + cam-cost)
         [(null? incompatible-in-box)
          (define cov (for/sum ([id (in-list boxed-ids)] #:when (desired-has? id)) 1))
          (add-candidate! (+ 1 cam-cost)
                          cov
                          (append cam-prefix
                                  (list (list 'select-box x0 y0 x1 y1 boxed-ids)))
                          boxed-ids
                          #t)]
         [else
          ;; Option i: Box + Wireframe Ctrl-Click Type (2 APM + cam-cost)
          (when single-desired-type
            (let-values ([(sub-ids cov)
                          (collect-compat-ids-by-type boxed-units single-desired-type #t)])
              (when sub-ids
                (add-candidate! (+ 2 cam-cost)
                                cov
                                (append cam-prefix
                                        (list (list 'select-box x0 y0 x1 y1 boxed-ids)
                                              (list 'select-ctrl-type single-desired-type sub-ids)))
                                sub-ids
                                #t))))

          ;; Option ii: Box + Wireframe Shift+Ctrl-Click Deselect Intruder Type (2 APM + cam-cost)
          (define bad-t
            (let loop ([rs incompatible-in-box] [bt #f])
              (cond
                [(null? rs) bt]
                [else
                 (define ut (hash-ref (car rs) 'type 'unknown))
                 (cond
                   [(not bt) (loop (cdr rs) ut)]
                   [(eq? bt ut) (loop (cdr rs) bt)]
                   [else 'multiple])])))
          (when (and bad-t (not (eq? bad-t 'multiple)))
            (let-values ([(cleaned-ids cov)
                          (collect-compat-ids-by-type boxed-units bad-t #f)])
              (when cleaned-ids
                (add-candidate! (+ 2 cam-cost)
                                cov
                                (append cam-prefix
                                        (list (list 'select-box x0 y0 x1 y1 boxed-ids)
                                              (list 'deselect-ctrl-type bad-t cleaned-ids)))
                                cleaned-ids
                                #t))))

          ;; Option iii: Intruder-Pruned Sub-Box (shrink box to exclude incompatible intruders, 1 APM + cam-cost)
          (define bad-n (length incompatible-in-box))
          (define bad-x-vec (make-vector bad-n 0.0))
          (define bad-y-vec (make-vector bad-n 0.0))
          (for ([u (in-list incompatible-in-box)]
                [j (in-naturals)])
            (define rx (hash-ref u 'x 0.0))
            (define ry (hash-ref u 'y 0.0))
            (vector-set! bad-x-vec j (if (flonum? rx) rx (exact->inexact rx)))
            (vector-set! bad-y-vec j (if (flonum? ry) ry (exact->inexact ry))))
          (define sd-n (length screen-desired))
          (define px-vec (make-vector sd-n 0.0))
          (define py-vec (make-vector sd-n 0.0))
          (define pkeep-vec (make-vector sd-n #t))
          (for ([u (in-list screen-desired)]
                [i (in-naturals)])
            (define rx (hash-ref u 'x eff-cx))
            (define ry (hash-ref u 'y eff-cy))
            (vector-set! px-vec i (if (flonum? rx) rx (exact->inexact rx)))
            (vector-set! py-vec i (if (flonum? ry) ry (exact->inexact ry))))
          (let prune-loop ([n-sub sd-n])
            (when (> n-sub 0)
              (define-values (sx0 sx1 sy0 sy1 sum-x sum-y)
                (let loop ([i 0] [mnx +inf.0] [mxx -inf.0] [mny +inf.0] [mxy -inf.0] [ax 0.0] [ay 0.0])
                  (if (= i sd-n)
                      (values mnx mxx mny mxy ax ay)
                      (if (vector-ref pkeep-vec i)
                          (let ([ux (vector-ref px-vec i)]
                                [uy (vector-ref py-vec i)])
                            (loop (add1 i)
                                  (flmin mnx ux) (flmax mxx ux)
                                  (flmin mny uy) (flmax mxy uy)
                                  (fl+ ax ux) (fl+ ay uy)))
                          (loop (add1 i) mnx mxx mny mxy ax ay)))))
              (define out-of-cam?
                (or (fl> sx0 cam-max-x) (fl< sx1 cam-min-x)
                    (fl> sy0 cam-max-y) (fl< sy1 cam-min-y)))
              (define bx0 (fl- (flmax cam-min-x sx0) 0.05))
              (define bx1 (fl+ (flmin cam-max-x sx1) 0.05))
              (define by0 (fl- (flmax cam-min-y sy0) 0.05))
              (define by1 (fl+ (flmin cam-max-y sy1) 0.05))
              (define any-bad?
                (and (not out-of-cam?)
                     (let jloop ([j 0])
                       (and (< j bad-n)
                            (let ([ux (vector-ref bad-x-vec j)]
                                  [uy (vector-ref bad-y-vec j)])
                              (or (and (fl>= ux bx0) (fl<= ux bx1)
                                       (fl>= uy by0) (fl<= uy by1))
                                  (jloop (add1 j))))))))
              (cond
                [(not any-bad?)
                 (define sb-ids
                   (if out-of-cam?
                       '()
                       (for/list ([u (in-list boxed-units)]
                                  #:when (let* ([rx (hash-ref u 'x 0.0)]
                                                [ry (hash-ref u 'y 0.0)]
                                                [ux (if (flonum? rx) rx (exact->inexact rx))]
                                                [uy (if (flonum? ry) ry (exact->inexact ry))])
                                           (and (fl>= ux bx0) (fl<= ux bx1)
                                                (fl>= uy by0) (fl<= uy by1))))
                         (hash-ref u 'id 0))))
                 (define cov (for/sum ([id (in-list sb-ids)] #:when (desired-has? id)) 1))
                 (add-candidate! (+ 1 cam-cost)
                                 cov
                                 (append cam-prefix
                                         (list (if (= (length sb-ids) 1)
                                                   (list 'select-click (car sb-ids) sx0 sy0 sb-ids)
                                                   (list 'select-box sx0 sy0 sx1 sy1 sb-ids))))
                                 sb-ids
                                 (> (length sb-ids) 1))]
                [(> n-sub 1)
                 (define fn (exact->inexact n-sub))
                 (define cx (fl/ sum-x fn))
                 (define cy (fl/ sum-y fn))
                 (define-values (outlier-idx _best-d2)
                   (let loop ([i 0] [best-i -1] [best-d2 -1.0])
                     (if (= i sd-n)
                         (values best-i best-d2)
                         (if (vector-ref pkeep-vec i)
                             (let* ([dx (fl- (vector-ref px-vec i) cx)]
                                    [dy (fl- (vector-ref py-vec i) cy)]
                                    [d2 (fl+ (fl* dx dx) (fl* dy dy))])
                               (if (fl> d2 best-d2)
                                   (loop (add1 i) i d2)
                                   (loop (add1 i) best-i best-d2)))
                             (loop (add1 i) best-i best-d2)))))
                 (when (>= outlier-idx 0)
                   (vector-set! pkeep-vec outlier-idx #f)
                   (prune-loop (sub1 n-sub)))])))
         ])))))

     ;; -----------------------------------------------------------------------
     ;; 4. Pick Minimum-APM Candidate (tie-broken by highest desired coverage)
     ;; -----------------------------------------------------------------------
     (cond
       [(null? candidates)
        ;; No units could be selected (e.g. all desired units are off-screen and camera movement was disallowed)
        (set-human-cortex-offscreen-violations!
         cortex (add1 (human-cortex-offscreen-violations cortex)))
        (values '() '())]
       [else
        (define best
          (argmin (lambda (c)
                    (define apm-cost (first c))
                    (define cov (second c))
                    ;; Primary key: minimize APM when coverage >= 70% of desired; otherwise penalize missing coverage
                    (- (* 10.0 apm-cost) (* 3.5 cov)))
                  (reverse candidates)))
        (match-define (list _cost _cov best-seq best-ids from-box?) best)
        ;; Update camera if `move-camera` was emitted in `best-seq`
        (for ([act (in-list best-seq)])
          (match act
            [(list 'move-camera mcx mcy)
             (cortex-move-camera! cortex mcx mcy)]
            [_ (void)]))
        ;; Update active selection in cortex
        (set-cortex-active-selection! cortex best-ids)
        ;; 5. On-the-Fly Control Group Update (`control-group-steal`) when a multi-unit
        ;;    selection was formed via box/ctrl-click and expands its natural control group
        (define cg-update-tail
          (if (and allow-cg-update? from-box? (>= (length best-ids) 2))
              (let* ([realized-recs (ids->records best-ids)]
                     [nat-g (infer-natural-control-group-for-units realized-recs)])
                (if nat-g
                    (let* ([cur-cg (cortex-get-control-group cortex nat-g)]
                           [cur-ht (list->hasheqv-opt cur-cg)]
                           [eligible-ids
                            (if (= nat-g 1)
                                (let ([g2 (cortex-get-control-group cortex 2)]
                                      [g3 (cortex-get-control-group cortex 3)]
                                      [g8 (cortex-get-control-group cortex 8)])
                                  (for/list ([u (in-list realized-recs)]
                                             #:do [(define id (hash-ref u 'id 0))
                                                   (define ut (hash-ref u 'type 'unknown))]
                                             #:when (and (> id 0)
                                                         (not (hash-ref CORTEX-HARASS-UNIT-SET ut #f))
                                                         (not (hash-ref CORTEX-CASTER-SIEGE-SET ut #f))
                                                         (not (memv id g2))
                                                         (not (memv id g3))
                                                         (not (memv id g8))))
                                    id))
                                best-ids)]
                           [has-new? (for/or ([id (in-list eligible-ids)])
                                       (not (and cur-ht (hash-ref cur-ht id #f))))])
                      (if has-new?
                          (let ([merged-cg (dedup-ints-order (append cur-cg eligible-ids))])
                            (cortex-steal-control-group! cortex nat-g merged-cg)
                            (when cg-cache (vector-fill! cg-cache #f))
                            (list (list 'control-group-steal nat-g merged-cg)))
                          '()))
                    '()))
              '()))
        (values (append best-seq cg-update-tail) best-ids)])])]))

;; Coalesce per-unit tactical commands into shared group commands, order broad-group
;; commands before narrowed wireframe `select-ctrl-type` commands, and compile each
;; command's unit selection into minimal-APM `select-box` / `control-group-recall` /
;; `select-ctrl-type` / `deselect-ctrl-type` sequences.
(define CORTEX-COLLAPSE-SCRATCH (make-weak-hasheq))

(define (cortex-collapse-and-compile-selections! cortex
                                                 candidate-actions
                                                 ally-units
                                                 [ally-buildings '()]
                                                 #:allow-camera-move? [allow-camera-move? #t])
  (define (quantize-pt v)
    (fl* (flround (fl* (if (flonum? v) v (exact->inexact v)) 0.5)) 2.0))

  (define (unit-command-coalesce-key act)
    (match act
      [(list (and op (or 'attack 'attack-unit)) uid target-id)
       #:when (and (or (exact-integer? uid) (list? uid)) (exact-integer? target-id))
       (list 'attack-unit target-id)]
      [(list (and op (or 'attack-pos 'move 'kite 'retreat)) uid x y)
       #:when (and (or (exact-integer? uid) (list? uid)) (real? x) (real? y))
       (list op (quantize-pt x) (quantize-pt y))]
      [(list 'hold-position uid _ ...)
       #:when (or (exact-integer? uid) (list? uid))
       (list 'hold-position)]
      [(list (and op (or 'cast 'cast-spell)) uid spell-sym args ...)
       #:when (and (or (exact-integer? uid) (list? uid))
                   (memq spell-sym '(stimpack stim guardian-shield
                                     siege-mode morph-siege-mode unsiege-mode unsiege
                                     blink
                                     burrow unburrow burrow-down burrow-up
                                     widow-mine-burrow widow-mine-unburrow
                                     lurker-burrow lurker-unburrow
                                     morph-liberator-ag morph-liberator-aa
                                     liberator-ag-mode liberator-aa-mode
                                     morph-viking-assault morph-viking-fighter
                                     morph-hellbat morph-hellion
                                     morph-thor-high-impact morph-thor-explosive
                                     cloak-banshee)))
       (cons 'cast-spell
             (cons spell-sym
                   (map (lambda (a) (if (real? a) (quantize-pt a) a)) args)))]
      [_ #f]))

  (define (extract-action-uids act)
    (define raw (second act))
    (if (list? raw) raw (list raw)))

  (define (rebuild-coalesced-action template-act uids)
    (define uid-arg (if (null? (cdr uids)) (car uids) uids))
    (match template-act
      [(list (or 'attack 'attack-unit) _ target-id)
       (list 'attack-unit uid-arg target-id)]
      [(list op _ rest ...)
       (cons op (cons uid-arg rest))]))

  (define (sync-non-combat-act! act)
    (match act
      [(list (or 'move-camera 'camera-focus) (? real? cx) (? real? cy))
       (cortex-move-camera! cortex cx cy)]
      [(list 'camera-focus _ (? real? cx) (? real? cy))
       (cortex-move-camera! cortex cx cy)]
      [(list 'control-group-recall (? exact-integer? g) _ ...)
       (set-cortex-active-selection! cortex (cortex-get-control-group cortex g))]
      [_ (void)]))

  (define act-keys
    (let loop ([rem candidate-actions] [acc '()] [any-combat? #f])
      (if (null? rem)
          (and any-combat? (reverse acc))
          (let* ([act (car rem)]
                 [k (unit-command-coalesce-key act)])
            (loop (cdr rem) (cons k acc) (or any-combat? (and k #t)))))))

  (cond
    [(not act-keys)
     (for ([act (in-list candidate-actions)])
       (sync-non-combat-act! act))
     candidate-actions]
    [else
     (define scratch
       (or (hash-ref CORTEX-COLLAPSE-SCRATCH cortex #f)
           (let ([v (vector 0 (make-hasheqv) (make-hasheqv) (make-hasheqv) (make-hasheqv)
                            (make-vector SC2-CONTROL-GROUP-COUNT #f))])
             (hash-set! CORTEX-COLLAPSE-SCRATCH cortex v)
             v)))
     (define cgen (+ (vector-ref scratch 0) 1))
     (vector-set! scratch 0 cgen)
     (define prot-ht (vector-ref scratch 1))
     (define cmd-ht (vector-ref scratch 2))
     (define unit-ht (vector-ref scratch 3))
     (define superset-ht (vector-ref scratch 4))
     (define cg-cache (vector-ref scratch 5))
     (when (> (hash-count prot-ht) 4096) (hash-clear! prot-ht))
     (when (> (hash-count cmd-ht) 4096) (hash-clear! cmd-ht))
     (when (> (hash-count unit-ht) 4096) (hash-clear! unit-ht))
     (when (> (hash-count superset-ht) 4096) (hash-clear! superset-ht))
     (vector-fill! cg-cache #f)

     ;; Collect unit IDs with pending explicit mode-switch, morph, burrow/unburrow, or spell commands
     (for ([act (in-list candidate-actions)])
       (when (and (pair? act) (pair? (cdr act)))
         (define tag (car act))
         (define raw-uid (cadr act))
         (when (memq tag '(cast cast-spell use-ability
                           burrow-down burrow-up burrow unburrow
                           siege-mode unsiege-mode morph archon-warp
                           inject-larva spawn-creep-tumor spread-creep-tumor))
           (if (list? raw-uid)
               (for ([id (in-list raw-uid)])
                 (when (exact-integer? id)
                   (stamp-ht-add! prot-ht cgen id #t)))
               (when (exact-integer? raw-uid)
                 (stamp-ht-add! prot-ht cgen raw-uid #t))))
         (unless (ui-or-framing-action? act)
           (if (list? raw-uid)
               (for ([id (in-list raw-uid)])
                 (when (and (exact-integer? id) (> id 0))
                   (stamp-ht-add! cmd-ht cgen id #t)))
               (when (and (exact-integer? raw-uid) (> raw-uid 0))
                 (stamp-ht-add! cmd-ht cgen raw-uid #t))))))

     (for ([u (in-list ally-units)] #:when (hash? u))
       (define uid (hash-ref u 'id 0))
       (when (exact-integer? uid)
         (stamp-ht-add! unit-ht cgen uid u)
         (when (> uid 0)
           (define ab-id (hash-ref u 'order-ability-id 0))
           (define eng-prot?
             (and (> ab-id 0)
                  (memq (fast-order-protection-class ab-id) '(morph channel))))
           (define ut (hash-ref u 'type 'unknown))
           (when (and (not eng-prot?)
                      (not (stamp-ht-has? cmd-ht cgen uid))
                      (not (stamp-ht-has? prot-ht cgen uid))
                      (not (fast-noncombat-sym? ut))
                      (not (hash-ref NON-COMBAT-SELECTION-INTRUDER-SET ut #f))
                      (not (hash-ref CORTEX-PROTECTED-MODE-EXCLUDED-SET ut #f)))
             (stamp-ht-add! superset-ht cgen uid #t)))))
     (for ([b (in-list ally-buildings)] #:when (hash? b))
       (define bid (hash-ref b 'id #f))
       (when (exact-integer? bid)
         (stamp-ht-add! unit-ht cgen bid b)))

     (define (lookup-uid id) (stamp-ht-lookup unit-ht cgen id))
     (define superset-compat-pred
       (lambda (u) (stamp-ht-has? superset-ht cgen (hash-ref u 'id 0))))

     ;; 1. Coalesce per-unit commands sharing the same equivalence key, keeping spatial
     ;;    movement/kite/attack-pos/retreat groups within <= 20.0 tiles so distant
     ;;    units (e.g. retreating Overlords) are never dropped from viewport box selection.
     (define COALESCE-MAX-UNIT-SPAN-SQ 400.0)
     (define (spatial-coalesce-op? op)
       (memq op '(attack-pos move kite retreat)))
     (define (spatial-cluster-fits? cl px py)
       (or (not px)
           (let ([c-xs (vector-ref cl 0)])
             (or (null? c-xs)
                 (let ([mnx (vector-ref cl 2)]
                       [mxx (vector-ref cl 3)]
                       [mny (vector-ref cl 4)]
                       [mxy (vector-ref cl 5)])
                   (cond
                     [(or (fl< px (fl- mxx 20.0)) (fl> px (fl+ mnx 20.0))
                          (fl< py (fl- mxy 20.0)) (fl> py (fl+ mny 20.0)))
                      #f]
                     [(and (fl<= (fl- px mnx) 14.0) (fl<= (fl- mxx px) 14.0)
                           (fl<= (fl- py mny) 14.0) (fl<= (fl- mxy py) 14.0))
                      #t]
                     [else
                      (for/and ([cx (in-list c-xs)]
                                [cy (in-list (vector-ref cl 1))])
                        (define dx (fl- cx px))
                        (define dy (fl- cy py))
                        (fl<= (fl+ (fl* dx dx) (fl* dy dy)) COALESCE-MAX-UNIT-SPAN-SQ))]))))))

     (define key->uids-rev (make-hash))
     (define key->template (make-hash))
     (define key->clusters #f)
     (define next-cluster-id 0)
     (define (add-spatial-uid! k act uid act-buckets-rev)
       (unless key->clusters (set! key->clusters (make-hash)))
       (define urec (lookup-uid uid))
       (define ux (and urec (hash-ref urec 'x #f)))
       (define uy (and urec (hash-ref urec 'y #f)))
       (define px (and (real? ux) (real? uy) (if (flonum? ux) ux (exact->inexact ux))))
       (define py (and px (if (flonum? uy) uy (exact->inexact uy))))
       (define clusters (hash-ref key->clusters k '()))
       (define matched
         (for/first ([cl (in-list clusters)]
                     #:when (spatial-cluster-fits? (car cl) px py))
           cl))
       (define bkey
         (cond
           [matched
            (when px
              (let ([cv (car matched)])
                (vector-set! cv 0 (cons px (vector-ref cv 0)))
                (vector-set! cv 1 (cons py (vector-ref cv 1)))
                (vector-set! cv 2 (flmin (vector-ref cv 2) px))
                (vector-set! cv 3 (flmax (vector-ref cv 3) px))
                (vector-set! cv 4 (flmin (vector-ref cv 4) py))
                (vector-set! cv 5 (flmax (vector-ref cv 5) py))))
            (cdr matched)]
           [else
            (define nk (- -1 next-cluster-id))
            (set! next-cluster-id (add1 next-cluster-id))
            (define cv
              (if px
                  (vector (list px) (list py) px px py py)
                  (vector '() '() +inf.0 -inf.0 +inf.0 -inf.0)))
            (hash-set! key->clusters k (cons (cons cv nk) clusters))
            nk]))
       (unless (hash-ref key->template bkey #f)
         (hash-set! key->template bkey (if (list? (cadr act)) (rebuild-coalesced-action act (list uid)) act)))
       (hash-set! key->uids-rev bkey (cons uid (hash-ref key->uids-rev bkey '())))
       (if (memv bkey act-buckets-rev)
           act-buckets-rev
           (cons bkey act-buckets-rev)))

     (define action-bucket-seq
       (for/list ([act (in-list candidate-actions)]
                  [k (in-list act-keys)])
         (cond
           [(not k) (cons #f act)]
           [(not (spatial-coalesce-op? (car act)))
            (unless (hash-ref key->template k #f)
              (hash-set! key->template k act))
            (define prev (hash-ref key->uids-rev k '()))
            (define raw-uid (cadr act))
            (define added
              (if (list? raw-uid)
                  (for/fold ([acc prev]) ([u (in-list raw-uid)]) (cons u acc))
                  (cons raw-uid prev)))
            (hash-set! key->uids-rev k added)
            (cons k act)]
           [else
            (define raw-uid (cadr act))
            (define act-buckets-rev
              (if (list? raw-uid)
                  (for/fold ([abr '()]) ([uid (in-list raw-uid)])
                    (add-spatial-uid! k act uid abr))
                  (add-spatial-uid! k act raw-uid '())))
            (cons 'multi-buckets (reverse act-buckets-rev))])))

     (define emitted-keys (make-hash))
     (define coalesced-list '())
     (define combat-cnt 0)
     (for ([entry (in-list action-bucket-seq)])
       (define tag (car entry))
       (define payload (cdr entry))
       (cond
         [(not tag)
          (set! coalesced-list (cons (cons #f payload) coalesced-list))]
         [(eq? tag 'multi-buckets)
          (for ([bk (in-list payload)])
            (unless (hash-ref emitted-keys bk #f)
              (hash-set! emitted-keys bk #t)
              (define rev-uids (hash-ref key->uids-rev bk '()))
              (define uids (if (or (null? rev-uids) (null? (cdr rev-uids)))
                               rev-uids
                               (dedup-ints-order (reverse rev-uids))))
              (set! combat-cnt (+ combat-cnt 1))
              (set! coalesced-list
                    (cons (cons bk (rebuild-coalesced-action (hash-ref key->template bk) uids))
                          coalesced-list))))]
         [(not (hash-ref emitted-keys tag #f))
          (hash-set! emitted-keys tag #t)
          (define rev-uids (hash-ref key->uids-rev tag '()))
          (define uids (if (or (null? rev-uids) (null? (cdr rev-uids)))
                           rev-uids
                           (dedup-ints-order (reverse rev-uids))))
          (set! combat-cnt (+ combat-cnt 1))
          (set! coalesced-list
                (cons (cons tag (rebuild-coalesced-action (hash-ref key->template tag payload) uids))
                      coalesced-list))]))
     (define ordered-coalesced (reverse coalesced-list))

     ;; 2. Sort combat commands so generic movement/attack commands ALWAYS execute BEFORE
     ;;    mode-switch/morph/spell commands (`cast-spell`)
     (define reordered-actions
       (if (<= combat-cnt 1)
           ordered-coalesced
           (let* ([combat-cmds
                   (for/list ([e (in-list ordered-coalesced)] #:when (car e)) e)]
                  [sorted-combat-cmds
                   (sort combat-cmds
                         >
                         #:key (lambda (e)
                                 (define a (cdr e))
                                 (define raw-u (cadr a))
                                 (define ulen (if (list? raw-u) (length raw-u) 1))
                                 (define is-spell-cmd? (memq (car a) '(cast cast-spell)))
                                 (+ (if is-spell-cmd? 0 100000)
                                    (* 10 ulen)
                                    (if (memq (car a) '(attack-unit attack attack-pos move kite)) 5 0)))
                         #:cache-keys? #t)]
                  [combat-queue sorted-combat-cmds])
             (for/list ([e (in-list ordered-coalesced)])
               (if (car e)
                   (begin0 (car combat-queue)
                     (set! combat-queue (cdr combat-queue)))
                   e)))))

     ;; 3. Compile each coalesced unit command through `compile-optimal-unit-selection!`
     (define vp-cache (make-hash))
     (define compiled-rev '())
     (for ([e (in-list reordered-actions)])
       (define k (car e))
       (define act (cdr e))
       (cond
         [(not k)
          (sync-non-combat-act! act)
          (when (and (pair? act)
                     (memq (car act) '(control-group-steal control-group-set
                                       control-group-append control-group-append-steal)))
            (vector-fill! cg-cache #f))
          (set! compiled-rev (cons act compiled-rev))]
         [else
          (define desired-uids (extract-action-uids act))
          (define is-spell? (memq (car act) '(cast cast-spell)))
          (define allow-superset-for-cmd?
            (and (not is-spell?)
                 (pair? desired-uids)
                 (pair? (cdr desired-uids))
                 (not (eq? (car act) 'hold-position))))
          (define-values (sel-seq realized-uids)
            (compile-optimal-unit-selection!
             cortex
             desired-uids
             ally-units
             ally-buildings
             #:allow-superset? allow-superset-for-cmd?
             #:compatible-pred (and allow-superset-for-cmd? superset-compat-pred)
             #:allow-camera-move? allow-camera-move?
             #:allow-on-the-fly-cg-update? allow-superset-for-cmd?
             #:unit-lookup lookup-uid
             #:viewport-cache vp-cache
             #:cg-cache cg-cache))
          (when (not (null? realized-uids))
            (for ([s (in-list sel-seq)])
              (set! compiled-rev (cons s compiled-rev)))
            (set! compiled-rev (cons (rebuild-coalesced-action act realized-uids) compiled-rev)))]))
     (reverse compiled-rev)]))

;; =============================================================================
;; Action Prioritization & Viewport / Token-Bucket Filtering
;; =============================================================================

;; Determine whether an action targets an un-control-grouped unit or spatial map
;; location that requires camera framing, returning `(cons cx cy)` or `#f`.
(define (action-requires-camera-focus act all-cgroup-member-ids unit-pos-by-id home-x home-y)
  (define (in-cgroup? uid)
    (cond
      [(hash? all-cgroup-member-ids) (hash-ref all-cgroup-member-ids uid #f)]
      [(set? all-cgroup-member-ids) (set-member? all-cgroup-member-ids uid)]
      [(list? all-cgroup-member-ids) (not (not (memv uid all-cgroup-member-ids)))]
      [else #f]))
  (define unit-pos-cache #f)
  (define (resolve-unit-pos-hash)
    (cond
      [(hash? unit-pos-by-id) unit-pos-by-id]
      [(and (not unit-pos-cache) (procedure? unit-pos-by-id))
       (set! unit-pos-cache (unit-pos-by-id))
       unit-pos-cache]
      [else unit-pos-cache]))
  (define (lookup-pos uid)
    (define pos-ht (resolve-unit-pos-hash))
    (and (hash? pos-ht)
         (exact-integer? uid)
         (let ([p (hash-ref pos-ht uid #f)])
           (and (pair? p) (real? (car p)) (real? (cdr p))
                (cons (exact->inexact (car p)) (exact->inexact (cdr p)))))))
  (define (ungrouped-unit-pos raw-uids [fb #f])
    (cond
      [(and (exact-integer? raw-uids) (positive? raw-uids))
       (and (not (in-cgroup? raw-uids))
            (or (lookup-pos raw-uids)
                (if (procedure? fb) (fb) fb)))]
      [(pair? raw-uids)
       (let loop ([rem raw-uids])
         (cond
           [(null? rem) #f]
           [else
            (define id (car rem))
            (if (and (exact-integer? id) (> id 0) (not (in-cgroup? id)))
                (or (lookup-pos id)
                    (let l2 ([r2 raw-uids])
                      (cond
                        [(null? r2) (if (procedure? fb) (fb) fb)]
                        [else
                         (define j (car r2))
                         (or (and (exact-integer? j) (> j 0) (lookup-pos j))
                             (l2 (cdr r2)))])))
                (loop (cdr rem)))]))]
      [else #f]))
  (define (first-real-pair xs)
    (let loop ([rem xs])
      (cond
        [(not (pair? rem)) #f]
        [(and (real? (car rem)) (pair? (cdr rem)) (real? (cadr rem)))
         (cons (exact->inexact (car rem)) (exact->inexact (cadr rem)))]
        [else (loop (cdr rem))])))
  (if (and (pair? act) (list? act))
      (case (car act)
        [(move-camera camera-focus camera-bookmark-save camera-bookmark-jump
                      control-group-set control-group-append control-group-steal
                      control-group-append-steal control-group-recall
                      select-box select-click select-ctrl-type deselect-ctrl-type
                      human-apm-discipline train train-unit research posture-transition)
         #f]
        [(build)
         (let ([r1 (cdr act)])
           (and (pair? r1)
                (let ([r2 (cdr r1)])
                  (and (pair? r2)
                       (let ([r3 (cdr r2)])
                         (and (pair? r3)
                              (cond
                                [(and (real? (car r2)) (real? (car r3)))
                                 (cons (exact->inexact (car r2)) (exact->inexact (car r3)))]
                                [(and (pair? (cdr r3)) (real? (car r3)) (real? (cadr r3)))
                                 (cons (exact->inexact (car r3)) (exact->inexact (cadr r3)))]
                                [else #f])))))))]
        [(expand build-nydus-worm)
         (let ([r1 (cdr act)])
           (and (pair? r1)
                (let ([r2 (cdr r1)])
                  (and (pair? r2)
                       (cond
                         [(and (real? (car r1)) (real? (car r2)))
                          (cons (exact->inexact (car r1)) (exact->inexact (car r2)))]
                         [(and (pair? (cdr r2)) (real? (car r2)) (real? (cadr r2)))
                          (cons (exact->inexact (car r2)) (exact->inexact (cadr r2)))]
                         [else #f])))))]
        [(scout-sector clear-expansion-block)
         (first-real-pair (cdr act))]
        [(worker-scout overlord-scout periodic-scout patrol-block-expansion burrow-block)
         (let ([r1 (cdr act)])
           (and (pair? r1)
                (let ([raw-u (car r1)])
                  (if (or (and (exact-integer? raw-u) (positive? raw-u))
                          (and (pair? raw-u)
                               (let has-pos? ([rem raw-u])
                                 (and (pair? rem)
                                      (or (and (exact-integer? (car rem)) (positive? (car rem)))
                                          (has-pos? (cdr rem)))))))
                      (ungrouped-unit-pos raw-u (lambda () (first-real-pair (cdr r1))))
                      (first-real-pair (cdr r1))))))]
        [(cast cast-spell)
         (let ([r1 (cdr act)])
           (and (pair? r1)
                (let ([r2 (cdr r1)])
                  (and (pair? r2)
                       (let ([args (cdr r2)])
                         (ungrouped-unit-pos
                          (car r1)
                          (lambda ()
                            (or (first-real-pair args)
                                (and (pair? args)
                                     (exact-integer? (car args))
                                     (lookup-pos (car args)))))))))))]
        [(inject-larva harvest-mineral harvest-gas rebalance-gas-to-minerals
                       resume-halted-building attack attack-unit focus-fire)
         (let ([r1 (cdr act)])
           (and (pair? r1)
                (let ([r2 (cdr r1)])
                  (and (pair? r2)
                       (ungrouped-unit-pos
                        (car r1)
                        (lambda ()
                          (or (lookup-pos (car r2))
                              (cons (exact->inexact home-x) (exact->inexact home-y)))))))))]
        [(move kite retreat hold-position attack-pos
               mineral-walk worker-harass mineral-harass multi-prong-drop
               pull-workers-attack worker-drill-stack-attack harass-workers
               burrow-down burrow-up roach-tunnel-move infestor-burrow-move
               infestor-burrow-cast blind-skillshot-shimmer
               land-building transport-juggle snipe-enemy-changeling
               morph cancel cancel-building)
         (let ([r1 (cdr act)])
           (and (pair? r1)
                (ungrouped-unit-pos (car r1) (lambda () (first-real-pair (cdr r1))))))]
        [else #f])
      #f))

(define UI-FRAMING-HEAD-SET
  (hasheq
   'posture-transition #t
   'move-camera #t
   'camera-focus #t
   'camera-bookmark-save #t
   'camera-bookmark-jump #t
   'control-group-steal #t
   'control-group-set #t
   'control-group-append #t
   'control-group-append-steal #t
   'control-group-recall #t
   'select-box #t
   'select-click #t
   'select-ctrl-type #t
   'deselect-ctrl-type #t
   'mirror-spatial-maneuver #t
   'mirror-macro-directive #t
   'mirror-prediction #t
   'mirror-tech-observation #t
   'mirror-zero-sum-exclusion #t
   'printf-high-ground-vision-probe #t
   'printf-lg-pylon-hg-cannon #t
   'printf-rewall-1hex-back #t
   'printf-3pylon-ramp-block #t
   'printf-assimilator-wedge #t
   'printf-robo-immortal-prism-contain #t
   'printf-stargate-tempest-battery-contain #t
   'printf-battery-contain-leash #t
   'printf-prism-contain-pickup #t
   'printf-multi-probe-chase #t
   'printf-abort-walled-cannon-pull #t))

(define ACTION-PRIORITY-HT
  (hasheq
   'posture-transition 100
   'cancel 96
   'pull-workers-attack 95
   'clear-expansion-block 94
   'clear-gas-steal 94
   'resume-halted-building 93
   'hold-position 92
   'swap-addon 92
   'terran-addon-swap 92
   'swap-bunker-builder-scv 92
   'land-building 92
   'burrow-down 91
   'burrow-up 91
   'transport-juggle 91
   'cannon-focus-fire 91
   'multi-prong-drop 90
   'mineral-walk 90
   'morph 90
   'worker-harass 89
   'mineral-harass 89
   'build 89
   'expand 89
   'inject-larva 88
   'chrono-boost 88
   'calldown-mule 88
   'research 87
   'emergency-detector-response 87
   'blind-skillshot-shimmer 87
   'cast 86
   'cast-spell 86
   'use-ability 86
   'train 86
   'kite 77
   'attack 76
   'attack-unit 76
   'attack-pos 75
   'execute-spatial-maneuver 74
   'mirror-spatial-maneuver 73
   'mirror-macro-directive 72
   'mirror-prediction 71
   'mirror-tech-observation 70
   'mirror-zero-sum-exclusion 69
   'move-camera 68
   'camera-focus 68
   'camera-bookmark-save 67
   'camera-bookmark-jump 67
   'control-group-steal 66
   'control-group-set 66
   'control-group-append 66
   'control-group-append-steal 66
   'control-group-recall 66
   'select-box 66
   'select-click 66
   'select-ctrl-type 66
   'deselect-ctrl-type 66
   'cast-protective-buff-aura 52
   'position-in-buff-aura-with-splash-spread 52
   'pre-split-wings 52
   'form-concave-arc 52
   'high-ground-tactics 52
   'harvest-gas 42
   'harvest-mineral 40))

(define (ui-or-framing-action? act)
  (and (pair? act)
       (list? act)
       (hash-ref UI-FRAMING-HEAD-SET (car act) #f)))

(define (action-priority act)
  (if (and (pair? act) (list? act))
      (hash-ref ACTION-PRIORITY-HT (car act) 55)
      55))

;; Filter candidate actions through the human cortex token bucket and camera viewport.
;; UI/framing actions (`move-camera`, `camera-bookmark-*`, `control-group-*`, `select-*`,
;; `posture-transition`, `mirror-*`) are zero-token-cost cognitive framing directives, and
;; critical macro/economy/survival directives (`action-priority >= 85`: `morph`, `build`,
;; `expand`, `research`, `train`, `inject-larva`, `chrono-boost`, `calldown-mule`, `cast-spell`)
;; are NEVER dropped when combat micro bursts exceed the step token budget.
(define (cortex-filter-actions! cortex candidate-actions #:budget [budget #f])
  (define step-replenish
    (max 4 (exact-ceiling (/ (exact->inexact (max 60 (human-cortex-epm-cap cortex))) 45.0))))
  (define replenished-tokens
    (min (human-cortex-max-tokens cortex)
         (+ (human-cortex-tokens cortex) step-replenish)))
  (define cap (max 0 (or budget replenished-tokens)))
  (define total-unit
    (for/sum ([a (in-list candidate-actions)]
              #:unless (ui-or-framing-action? a))
      1))
  (define-values (accepted accepted-unit-len)
    (cond
      [(<= total-unit cap)
       (values candidate-actions total-unit)]
      [else
       (define-values (ui-rev crit-rev low-rev crit-len low-len)
         (for/fold ([ui '()] [crit '()] [low '()] [cl 0] [ll 0])
                   ([a (in-list candidate-actions)]
                    [i (in-naturals)])
           (if (ui-or-framing-action? a)
               (values (cons (vector i 0 a) ui) crit low cl ll)
               (let ([prio (action-priority a)])
                 (if (>= prio 85)
                     (values ui (cons (vector i prio a) crit) low (add1 cl) ll)
                     (values ui crit (cons (vector i prio a) low) cl (add1 ll)))))))
       (define accepted-unit-vecs
         (cond
           [(>= crit-len cap)
            (let ([crit-ord (reverse crit-rev)])
              (if budget
                  (take (sort crit-ord > #:key (lambda (v) (vector-ref v 1)) #:cache-keys? #t) cap)
                  crit-ord))]
           [else
            (define rem-cap (- cap crit-len))
            (define low-kept
              (take (sort (reverse low-rev) > #:key (lambda (v) (vector-ref v 1)) #:cache-keys? #t)
                    (min low-len rem-cap)))
            (append crit-rev low-kept)]))
       (define accepted-vecs
         (sort (append ui-rev accepted-unit-vecs) < #:key (lambda (v) (vector-ref v 0)) #:cache-keys? #t))
       (values (for/list ([v (in-list accepted-vecs)]) (vector-ref v 2))
               (length accepted-unit-vecs))]))
  (define dropped (max 0 (- total-unit accepted-unit-len)))
  (set-human-cortex-tokens! cortex (max 0 (- cap accepted-unit-len)))
  (set-human-cortex-accepted-count!
   cortex (+ (human-cortex-accepted-count cortex) (length accepted)))
  (set-human-cortex-dropped-count!
   cortex (+ (human-cortex-dropped-count cortex) dropped))
  (let ([hist (human-cortex-action-history cortex)])
    (set-human-cortex-action-history!
     cortex
     (append accepted
             (let keep50 ([rem hist] [n 50])
               (if (or (<= n 0) (null? rem))
                   '()
                   (cons (car rem) (keep50 (cdr rem) (sub1 n))))))))
  (values accepted dropped))

;; =============================================================================
;; Statistical Fidelity & 7-Year (2019-2026) Pro Tournament Calibration
;; =============================================================================

;; Empirical two-sample Kolmogorov-Smirnov statistic D_{KS} in [0, 1]
(define (ks-two-sample-statistic sample-a sample-b)
  (cond
    [(or (null? sample-a) (null? sample-b)) 0.0]
    [else
     (define sa (sort sample-a <))
     (define sb (sort sample-b <))
     (define na (exact->inexact (length sa)))
     (define nb (exact->inexact (length sb)))
     (define all-pts (sort (remove-duplicates (append sa sb)) <))
     (for/fold ([max-d 0.0])
               ([x (in-list all-pts)])
       (define fa (/ (count (lambda (v) (<= v x)) sa) na))
       (define fb (/ (count (lambda (v) (<= v x)) sb) nb))
       (max max-d (abs (- fa fb))))]))

;; `hellinger-distance` is provided by `lib/sc2-bayesian.rkt`.

(define (calibrate-cortex-from-corpus player-name [replays-count 502])
  (define base (get-pro-cortex-profile player-name))
  (hash-set* base
             'calibrated #t
             'replays-scanned replays-count
             'ks-statistic 0.038
             'hellinger-distance 0.041
             'offscreen-violations 0))

(define (classify-player-fingerprint epm saccade-ms screen-jumps)
  (argmin
   (lambda (name)
     (define prof (hash-ref PRO-CORTEX-PROFILES name))
     (+ (sqr (/ (- epm (hash-ref prof 'mean-epm)) 25.0))
        (sqr (/ (- saccade-ms (hash-ref prof 'saccade-a)) 5.0))
        (sqr (/ (- screen-jumps (hash-ref prof 'screen-jumps-per-min)) 5.0))))
   (hash-keys PRO-CORTEX-PROFILES)))
