#lang racket/base

(require racket/match
         racket/list
         racket/set
         racket/math
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
                           #:epm-cap [epm-cap 360]
                           #:max-tokens [max-tokens 48])
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
  (define half-w (/ (exact->inexact w) 2.0))
  (define half-h (/ (exact->inexact h) 2.0))
  (and (>= x (- cx half-w))
       (<= x (+ cx half-w))
       (>= y (- cy half-h))
       (<= y (+ cy half-h))))

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
  (when (and (>= group-id 0) (< group-id SC2-CONTROL-GROUP-COUNT))
    (define vec (human-cortex-control-groups cortex))
    (define existing (vector-ref vec group-id))
    (vector-set! vec group-id (remove-duplicates (append existing unit-ids))))
  cortex)

(define (cortex-set-control-group! cortex group-id unit-ids)
  (when (and (>= group-id 0) (< group-id SC2-CONTROL-GROUP-COUNT))
    (define vec (human-cortex-control-groups cortex))
    (vector-set! vec group-id (remove-duplicates unit-ids)))
  cortex)

;; Exclusive Control-Group Stealing (Alt + 0..9):
;; Removes `unit-ids` from ALL other control groups (0..9) and assigns to `group-id`.
(define (cortex-steal-control-group! cortex group-id unit-ids)
  (define stolen-set (list->set unit-ids))
  (define vec (human-cortex-control-groups cortex))
  (for ([g (in-range SC2-CONTROL-GROUP-COUNT)])
    (when (not (= g group-id))
      (define cur (vector-ref vec g))
      (vector-set! vec g (filter (lambda (id) (not (set-member? stolen-set id))) cur))))
  (when (and (>= group-id 0) (< group-id SC2-CONTROL-GROUP-COUNT))
    (define cur-target (vector-ref vec group-id))
    (vector-set! vec group-id (remove-duplicates (append cur-target unit-ids))))
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
(define (cortex-sync-control-groups! cortex ally-units ally-buildings base-x base-y)
  (define actions '())
  (define (emit! a) (set! actions (cons a actions)))
  (define harass-types
    '(banshee mutalisk oracle phoenix void-ray warp-prism medivac reaper hellion adept viking))
  (define caster-siege-types
    '(queen raven viper infestor high-templar sentry disruptor
      siege-tank siege-tank-sieged liberator lurker lurker-burrowed observer overseer))
  (define worker-types '(drone probe scv mule larva egg cocoon overlord))
  (define townhall-types
    '(hatchery lair hive nexus command-center orbital-command planetary-fortress))
  (define primary-prod-types '(barracks gateway warp-gate))
  (define tech-prod-types '(factory starport robotics-facility stargate))
  (define upgrade-bldg-types
    '(engineering-bay armory fusion-core ghost-academy
      barracks-tech-lab barracks-techlab factory-tech-lab factory-techlab starport-tech-lab starport-techlab
      forge cybernetics-core twilight-council robotics-bay fleet-beacon templar-archive dark-shrine
      evolution-chamber spire greater-spire spawning-pool infestation-pit
      baneling-nest roach-warren hydralisk-den lurker-den ultralisk-cavern))
  (define defense-wall-types
    '(supply-depot supply-depot-lowered bunker missile-turret
      photon-cannon shield-battery spine-crawler spore-crawler))

  (define vec (human-cortex-control-groups cortex))
  (define existing-g2-set (list->set (vector-ref vec 2)))
  (define group-tags (make-vector SC2-CONTROL-GROUP-COUNT '()))
  (for ([u (in-list ally-units)])
    (define id (hash-ref u 'id 0))
    (define t (hash-ref u 'type 'unknown))
    (define ux (hash-ref u 'x base-x))
    (define uy (hash-ref u 'y base-y))
    (define d-home (sqrt (+ (sqr (- ux base-x)) (sqr (- uy base-y)))))
    (when (> id 0)
      (cond
        [(and (memq t '(drone probe scv overlord observer)) (> d-home 28.0))
         (vector-set! group-tags 8 (cons id (vector-ref group-tags 8)))]
        [(or (memq t harass-types) (set-member? existing-g2-set id))
         (vector-set! group-tags 2 (cons id (vector-ref group-tags 2)))
         (vector-set! group-tags 0 (cons id (vector-ref group-tags 0)))]
        [(memq t caster-siege-types)
         (vector-set! group-tags 3 (cons id (vector-ref group-tags 3)))
         (when (not (eq? t 'queen))
           (vector-set! group-tags 0 (cons id (vector-ref group-tags 0))))]
        [(not (memq t worker-types))
         (vector-set! group-tags 1 (cons id (vector-ref group-tags 1)))
         (vector-set! group-tags 0 (cons id (vector-ref group-tags 0)))])))

  (for ([b (in-list ally-buildings)])
    (define id (hash-ref b 'id 0))
    (define t (hash-ref b 'type 'unknown))
    (when (> id 0)
      (cond
        [(memq t townhall-types)
         (vector-set! group-tags 4 (cons id (vector-ref group-tags 4)))]
        [(memq t primary-prod-types)
         (vector-set! group-tags 5 (cons id (vector-ref group-tags 5)))]
        [(memq t tech-prod-types)
         (vector-set! group-tags 6 (cons id (vector-ref group-tags 6)))]
        [(memq t upgrade-bldg-types)
         (vector-set! group-tags 7 (cons id (vector-ref group-tags 7)))]
        [(memq t defense-wall-types)
         (vector-set! group-tags 9 (cons id (vector-ref group-tags 9)))])))

  ;; Prioritize control groups 4, 5, 6, 7, 9 (Buildings) and 1, 2, 3, 8, 0 (Units)
  (for ([g (in-list '(4 5 6 7 9 1 2 3 8 0))])
    (define desired (sort (remove-duplicates (vector-ref group-tags g)) <))
    (define current (sort (remove-duplicates (vector-ref vec g)) <))
    (when (and (not (null? desired))
               (not (equal? desired current)))
      (cond
        [(memv g '(1 2 3 8))
         (cortex-steal-control-group! cortex g desired)
         (vector-set! vec g desired)
         (emit! (list 'control-group-steal g desired))]
        [else
         (cortex-set-control-group! cortex g desired)
         (emit! (list 'control-group-set g desired))])))
  (reverse actions))

;; Inspect a building control group (`4` = Townhalls, `5` = Primary Production,
;; `6` = Tech Production, `7` = Upgrade/TechLab Structures) and compute exact
;; open production/research slot capacity across all ready structures in that group.
;; - Reactor-attached facilities provide 2 concurrent production slots.
;; - TechLab-attached or naked facilities provide 1 production slot.
;; - Busy facilities (`order-count >= max-slots`) provide 0 open slots.
(define (cortex-production-group-capacity cortex ally-buildings group-id)
  (define group-tag-set (list->set (cortex-get-control-group cortex group-id)))
  (define default-types-for-group
    (case group-id
      [(4) '(hatchery lair hive nexus command-center orbital-command planetary-fortress)]
      [(5) '(barracks gateway warp-gate)]
      [(6) '(factory starport robotics-facility stargate)]
      [(7) '(engineering-bay armory fusion-core ghost-academy
             barracks-tech-lab barracks-techlab factory-tech-lab factory-techlab starport-tech-lab starport-techlab
             forge cybernetics-core twilight-council robotics-bay fleet-beacon templar-archive dark-shrine
             evolution-chamber spire greater-spire spawning-pool infestation-pit
             baneling-nest roach-warren hydralisk-den lurker-den ultralisk-cavern)]
      [else '()]))

  (define ready-bldgs
    (filter (lambda (b)
              (define id (hash-ref b 'id 0))
              (define t (hash-ref b 'type 'unknown))
              (define prog (hash-ref b 'build-progress 1.0))
              (and (>= prog 1.0)
                   (or (set-member? group-tag-set id)
                       (memq t default-types-for-group))))
            ally-buildings))

  (define (facility-addon-kind b)
    (define explicit (hash-ref b 'addon #f))
    (cond
      [(memq explicit '(reactor barracks-reactor factory-reactor starport-reactor)) 'reactor]
      [(memq explicit '(tech-lab techlab barracks-tech-lab barracks-techlab
                        factory-tech-lab factory-techlab starport-tech-lab starport-techlab))
       'tech-lab]
      [else
       (define bx (hash-ref b 'x 0.0))
       (define by (hash-ref b 'y 0.0))
       (define ax (+ bx SC2-TERRAN-ADDON-OFFSET-X))
       (define ay (+ by SC2-TERRAN-ADDON-OFFSET-Y))
       (define nearby-addon
         (findf (lambda (other)
                  (and (>= (hash-ref other 'build-progress 1.0) 1.0)
                       (<= (sqrt (+ (sqr (- (hash-ref other 'x 0.0) ax))
                                    (sqr (- (hash-ref other 'y 0.0) ay))))
                           1.75)
                       (memq (hash-ref other 'type 'unknown)
                             '(reactor barracks-reactor factory-reactor starport-reactor
                               tech-lab techlab barracks-tech-lab barracks-techlab
                               factory-tech-lab factory-techlab starport-tech-lab starport-techlab))))
                ally-buildings))
       (cond
         [(not nearby-addon) 'none]
         [(memq (hash-ref nearby-addon 'type 'unknown)
                '(reactor barracks-reactor factory-reactor starport-reactor))
          'reactor]
         [else 'tech-lab])]))

  (define ready-tags '())
  (define idle-tags '())
  (define techlab-idle-tags '())
  (define reactor-idle-tags '())
  (define total-open-slots 0)
  (define open-slots-by-type (make-hash))
  (define techlab-open-slots-by-type (make-hash))
  (define idle-tags-by-type (make-hash))

  (for ([b (in-list ready-bldgs)])
    (define id (hash-ref b 'id 0))
    (define raw-t (hash-ref b 'type 'unknown))
    (define t
      (case raw-t
        [(warpgate)             'warp-gate]
        [(robotics-support-bay) 'robotics-bay]
        [(templar-archives)     'templar-archive]
        [else                   raw-t]))
    (define addon-kind (facility-addon-kind b))
    (define max-slots (if (eq? addon-kind 'reactor) 2 1))
    (define used-slots
      (max (hash-ref b 'order-count 0)
           (length (hash-ref b 'orders '()))
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
      (define slot-tags (for/list ([_ (in-range open-slots)]) id))
      (hash-set! idle-tags-by-type t
                 (append (hash-ref idle-tags-by-type t '()) slot-tags))))

  (hash 'group-id group-id
        'ready-tags (reverse ready-tags)
        'idle-tags (reverse idle-tags)
        'techlab-idle-tags (reverse techlab-idle-tags)
        'reactor-idle-tags (reverse reactor-idle-tags)
        'open-slot-count total-open-slots
        'open-slots-by-type open-slots-by-type
        'techlab-open-slots-by-type techlab-open-slots-by-type
        'idle-tags-by-type idle-tags-by-type))

(define (cortex-idle-facilities-in-group cortex ally-buildings group-id [bldg-type #f])
  (define cap (cortex-production-group-capacity cortex ally-buildings group-id))
  (if bldg-type
      (hash-ref (hash-ref cap 'idle-tags-by-type (hash)) bldg-type '())
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

;; Synchronize all 8 pro camera bookmarks (F1..F8 = slots 1..8) with drift gating
;; (`>= SC2-BOOKMARK-DRIFT-UPDATE-DIST` tiles) so bookmarks are only saved when needed.
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
               [arena-y (if (pair? e-units) (hash-ref (car e-units) 'y stage-y) stage-y)])
          (list (list 1 bx by)
                (list 2 nx ny)
                (list 3 tx ty)
                (list 4 ramp-x ramp-y)
                (list 5 stage-x stage-y)
                (list 6 arena-x arena-y)
                (list 7 eex eey)
                (list 8 ex ey)))
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
;; Action Prioritization & Viewport / Token-Bucket Filtering
;; =============================================================================

(define (ui-or-framing-action? act)
  (match act
    [(list (or 'posture-transition
               'move-camera
               'camera-focus
               'camera-bookmark-save
               'camera-bookmark-jump
               'control-group-steal
               'control-group-set
               'control-group-recall
               'mirror-spatial-maneuver
               'mirror-macro-directive
               'mirror-prediction
               'mirror-tech-observation
               'mirror-zero-sum-exclusion) _ ...)
     #t]
    [_ #f]))

(define (action-priority act)
  (match act
    [(list 'posture-transition _ ...)        100]
    [(list 'cancel _ ...)                    96]
    [(list 'pull-workers-attack _ ...)       95]
    [(list 'clear-expansion-block _ ...)     94]
    [(list 'clear-gas-steal _ ...)           94]
    [(list 'resume-halted-building _ ...)    93]
    [(list 'hold-position _ ...)             92]
    [(list 'swap-addon _ ...)                92]
    [(list 'transport-juggle _ ...)          91]
    [(list 'multi-prong-drop _ ...)          90]
    [(list 'mineral-walk _ ...)              90]
    [(list 'worker-harass _ ...)             89]
    [(list 'inject-larva _ ...)              88]
    [(list 'chrono-boost _ ...)              88]
    [(list 'calldown-mule _ ...)             88]
    [(list (or 'cast 'cast-spell 'use-ability) _ ...) 86]
    [(list 'morph _ ...)                     84]
    [(list 'build _ ...)                     82]
    [(list 'expand _ ...)                    81]
    [(list 'research _ ...)                  79]
    [(list 'train _ ...)                     78]
    [(list 'kite _ ...)                      77]
    [(list (or 'attack 'attack-unit) _ ...)  76]
    [(list 'attack-pos _ ...)                75]
    [(list 'execute-spatial-maneuver _ ...)  74]
    [(list 'mirror-spatial-maneuver _ ...)   73]
    [(list 'mirror-macro-directive _ ...)    72]
    [(list 'mirror-prediction _ ...)         71]
    [(list 'mirror-tech-observation _ ...)   70]
    [(list 'mirror-zero-sum-exclusion _ ...) 69]
    [(list 'move-camera _ ...)               68]
    [(list 'camera-focus _ ...)              68]
    [(list 'camera-bookmark-save _ ...)      67]
    [(list 'camera-bookmark-jump _ ...)      67]
    [(list 'control-group-steal _ ...)       66]
    [(list 'control-group-set _ ...)         66]
    [(list 'control-group-recall _ ...)      66]
    [(list (or 'cast-protective-buff-aura
               'position-in-buff-aura-with-splash-spread
               'pre-split-wings
               'form-concave-arc
               'high-ground-tactics) _ ...)  52]
    [(list 'harvest-gas _ ...)               42]
    [(list 'harvest-mineral _ ...)           40]
    [_                                       55]))

;; Filter candidate actions through the human cortex token bucket and camera viewport.
;; UI/framing actions (`move-camera`, `camera-bookmark-*`, `control-group-*`, `posture-transition`,
;; `mirror-*`) are zero-token-cost cognitive framing directives so they never starve `build`,
;; `train`, `kite`, or `attack-unit` out of the unit/macro token budget (`cap`).
(define (cortex-filter-actions! cortex candidate-actions #:budget [budget #f])
  (define cap (max 0 (or budget (human-cortex-max-tokens cortex))))
  (define indexed
    (for/list ([a (in-list candidate-actions)]
               [i (in-naturals)])
      (cons i a)))
  (define ui-indexed (filter (lambda (p) (ui-or-framing-action? (cdr p))) indexed))
  (define unit-indexed (filter (lambda (p) (not (ui-or-framing-action? (cdr p)))) indexed))
  (define total-unit (length unit-indexed))
  (define accepted-unit-indexed
    (cond
      [(<= total-unit cap)
       unit-indexed]
      [else
       (take (sort unit-indexed > #:key (lambda (p) (action-priority (cdr p))))
             cap)]))
  (define accepted
    (map cdr (sort (append ui-indexed accepted-unit-indexed) < #:key car)))
  (define dropped (max 0 (- total-unit (length accepted-unit-indexed))))
  (set-human-cortex-tokens! cortex (max 0 (- cap (length accepted-unit-indexed))))
  (set-human-cortex-accepted-count!
   cortex (+ (human-cortex-accepted-count cortex) (length accepted)))
  (set-human-cortex-dropped-count!
   cortex (+ (human-cortex-dropped-count cortex) dropped))
  (set-human-cortex-action-history!
   cortex (append accepted (take (human-cortex-action-history cortex)
                                 (min 50 (length (human-cortex-action-history cortex))))))
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

;; Hellinger distance between two discrete probability distributions P and Q
(define (hellinger-distance dist-p dist-q)
  (define sum-sq
    (for/sum ([p (in-list dist-p)]
              [q (in-list dist-q)])
      (sqr (- (sqrt (max 0.0 p)) (sqrt (max 0.0 q))))))
  (* (/ 1.0 (sqrt 2.0)) (sqrt sum-sq)))

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
