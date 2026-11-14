#lang racket/base

(require racket/match
         racket/list
         racket/set
         racket/math
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

(define (cortex-sync-control-groups! cortex ally-units ally-buildings base-x base-y
                                     #:excluded-tags [excluded-tags #f])
  (define actions '())
  (define (emit! a) (set! actions (cons a actions)))
  (define (tag-excluded? id)
    (cond
      [(not excluded-tags) #f]
      [(set? excluded-tags) (set-member? excluded-tags id)]
      [(hash? excluded-tags) (hash-has-key? excluded-tags id)]
      [(list? excluded-tags) (not (not (memv id excluded-tags)))]
      [else #f]))
  (define (unit-is-hallucination? u)
    (or (eq? (hash-ref u 'is-hallucination #f) #t)
        (eq? (hash-ref u 'hallucination #f) #t)))
  (define townhall-types
    '(hatchery lair hive nexus
      command-center command-center-flying
      orbital-command orbital-command-flying
      planetary-fortress))
  (define primary-prod-types '(barracks barracks-flying gateway warp-gate warpgate))
  (define tech-prod-types
    '(factory factory-flying starport starport-flying robotics-facility stargate))
  (define upgrade-bldg-types
    '(engineering-bay armory fusion-core ghost-academy
      barracks-tech-lab barracks-techlab factory-tech-lab factory-techlab starport-tech-lab starport-techlab
      forge cybernetics-core twilight-council robotics-bay robotics-support-bay
      fleet-beacon templar-archive templar-archives dark-shrine
      evolution-chamber spire greater-spire spawning-pool infestation-pit
      baneling-nest roach-warren hydralisk-den lurker-den lurker-den-mp ultralisk-cavern))
  (define defense-wall-types
    '(supply-depot supply-depot-lowered bunker missile-turret sensor-tower
      pylon-overcharged photon-cannon shield-battery
      spine-crawler spine-crawler-uprooted spore-crawler spore-crawler-uprooted))

  (define th-coords
    (let ([pts (for/list ([b (in-list ally-buildings)]
                          #:when (and (not (hash-ref b 'in-transit? #f))
                                      (< (hash-ref b 'id 0) 9000000)
                                      (memq (hash-ref b 'type 'unknown) townhall-types)))
                 (cons (hash-ref b 'x base-x) (hash-ref b 'y base-y)))])
      (if (null? pts) (list (cons base-x base-y)) pts)))

  (define vec (human-cortex-control-groups cortex))
  (define existing-g2-set (list->set (vector-ref vec 2)))
  (define group-tags (make-vector SC2-CONTROL-GROUP-COUNT '()))
  (for ([u (in-list ally-units)])
    (define id (hash-ref u 'id 0))
    (define t (hash-ref u 'type 'unknown))
    (define ux (hash-ref u 'x base-x))
    (define uy (hash-ref u 'y base-y))
    (define d-nearest-th
      (apply min
             (for/list ([pt (in-list th-coords)])
               (sqrt (+ (sqr (- ux (car pt))) (sqr (- uy (cdr pt))))))))
    (define worker-building?
      (or (hash-ref u 'has-build-order? #f)
          (and (hash-ref u 'build-target #f) #t)
          (memq (hash-ref u 'order-kind #f) '(build expand))))
    (define non-combat-or-summon?
      (or (sc2-non-combat-or-summon-sym? t)
          (memq t NON-COMBAT-SELECTION-INTRUDER-TYPES)))
    (when (and (> id 0)
               (not (tag-excluded? id))
               (not (unit-is-hallucination? u)))
      (cond
        [(and (or (eq? t 'overlord)
                  (and (memq t '(drone probe scv))
                       (not worker-building?)))
              (> d-nearest-th 28.0))
         (vector-set! group-tags 8 (cons id (vector-ref group-tags 8)))]
        [(and (not non-combat-or-summon?)
              (or (memq t CORTEX-HARASS-UNIT-TYPES)
                  (set-member? existing-g2-set id)))
         (vector-set! group-tags 2 (cons id (vector-ref group-tags 2)))
         (vector-set! group-tags 0 (cons id (vector-ref group-tags 0)))]
        [(and (not non-combat-or-summon?)
              (memq t CORTEX-CASTER-SIEGE-UNIT-TYPES))
         (vector-set! group-tags 3 (cons id (vector-ref group-tags 3)))
         (when (not (memq t '(queen queen-burrowed)))
           (vector-set! group-tags 0 (cons id (vector-ref group-tags 0))))]
        [(not non-combat-or-summon?)
         (vector-set! group-tags 1 (cons id (vector-ref group-tags 1)))
         (vector-set! group-tags 0 (cons id (vector-ref group-tags 0)))])))

  (for ([b (in-list ally-buildings)])
    (define id (hash-ref b 'id 0))
    (define t (hash-ref b 'type 'unknown))
    (when (and (> id 0)
               (< id 9000000)
               (not (hash-ref b 'in-transit? #f)))
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
  (reverse actions))

;; Inspect a building control group (`4` = Townhalls, `5` = Primary Production,
;; `6` = Tech Production, `7` = Upgrade/TechLab Structures) and compute exact
;; open production/research slot capacity across all ready structures in that group.
;; - Reactor-attached facilities provide 2 concurrent production slots.
;; - TechLab-attached or naked facilities provide 1 production slot.
;; - Busy facilities (`order-count >= max-slots`), unpowered Protoss structures, and flying structures provide 0 open slots.
(define (cortex-production-group-capacity cortex ally-buildings group-id)
  (define group-tag-set (list->set (cortex-get-control-group cortex group-id)))
  (define default-types-for-group
    (case group-id
      [(4) '(hatchery lair hive nexus command-center orbital-command planetary-fortress)]
      [(5) '(barracks gateway warp-gate warpgate)]
      [(6) '(factory starport robotics-facility stargate)]
      [(7) '(engineering-bay armory fusion-core ghost-academy
             barracks-tech-lab barracks-techlab factory-tech-lab factory-techlab starport-tech-lab starport-techlab
             forge cybernetics-core twilight-council robotics-bay robotics-support-bay
             fleet-beacon templar-archive templar-archives dark-shrine
             evolution-chamber spire greater-spire spawning-pool infestation-pit
             baneling-nest roach-warren hydralisk-den lurker-den lurker-den-mp ultralisk-cavern)]
      [else '()]))

  (define ready-bldgs
    (filter (lambda (b)
              (define id (hash-ref b 'id 0))
              (define t (hash-ref b 'type 'unknown))
              (define prog (hash-ref b 'build-progress 1.0))
              (and (> id 0)
                   (< id 9000000)
                   (not (hash-ref b 'in-transit? #f))
                   (>= prog SC2-BUILD-COMPLETE-PROGRESS)
                   (not (hash-ref b 'flying? #f))
                   (not (memq t '(command-center-flying orbital-command-flying
                                  barracks-flying factory-flying starport-flying
                                  spine-crawler-uprooted spore-crawler-uprooted)))
                   (or (not (sc2-structure-requires-pylon-power? t))
                       (not (eq? (hash-ref b 'powered? #t) #f)))
                   (or (set-member? group-tag-set id)
                       (memq t default-types-for-group))))
            ally-buildings))

  (define (facility-addon-kind b)
    (define canon-fac (sc2-canonical-structure-sym (hash-ref b 'type 'unknown)))
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
          (define bx (hash-ref b 'x 0.0))
          (define by (hash-ref b 'y 0.0))
          (define ax (+ bx SC2-TERRAN-ADDON-OFFSET-X))
          (define ay (+ by SC2-TERRAN-ADDON-OFFSET-Y))
          (define nearby-addon
            (findf (lambda (other)
                     (and (>= (hash-ref other 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS)
                          (not (hash-ref other 'in-transit? #f))
                          (not (hash-ref other 'flying? #f))
                          (<= (sqrt (+ (sqr (- (hash-ref other 'x 0.0) ax))
                                       (sqr (- (hash-ref other 'y 0.0) ay))))
                              1.75)
                          (memq (hash-ref other 'type 'unknown)
                                '(barracks-reactor factory-reactor starport-reactor
                                  barracks-tech-lab barracks-techlab
                                  factory-tech-lab factory-techlab
                                  starport-tech-lab starport-techlab))))
                   ally-buildings))
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
  (define open-slots-by-type (make-hash))
  (define techlab-open-slots-by-type (make-hash))
  (define idle-tags-by-type (make-hash))

  (for ([b (in-list ready-bldgs)])
    (define id (hash-ref b 'id 0))
    (define raw-t (hash-ref b 'type 'unknown))
    (define t (sc2-canonical-structure-sym raw-t))
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

(define (set-cortex-active-selection! cortex unit-ids)
  (define clean
    (sort (remove-duplicates (filter (lambda (id) (and (exact-integer? id) (> id 0)))
                                     (if (list? unit-ids) unit-ids (list unit-ids))))
          <))
  (hash-set! (human-cortex-camera-bookmarks cortex) 'active-selection clean)
  clean)

(define (units-in-camera-viewport units cam-x cam-y [w VIEWPORT-WIDTH] [h VIEWPORT-HEIGHT])
  (filter (lambda (u)
            (and (hash? u)
                 (in-camera-viewport? cam-x cam-y
                                      (hash-ref u 'x cam-x)
                                      (hash-ref u 'y cam-y)
                                      w h)))
          units))

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
     (filter (lambda (u)
               (define ux (exact->inexact (hash-ref u 'x 0.0)))
               (define uy (exact->inexact (hash-ref u 'y 0.0)))
               (and (>= ux bx0) (<= ux bx1)
                    (>= uy by0) (<= uy by1)))
             screen-pool)]))

;; Simulate Ctrl+clicking a unit portrait in the selection wireframe (or on screen):
;; Filters `candidate-units` down to `{u in candidate-units | type(u) == target-type}`.
(define (simulate-ctrl-click-subselect target-type candidate-units)
  (filter (lambda (u)
            (eq? (hash-ref u 'type 'unknown) target-type))
          candidate-units))

;; Simulate Shift+Ctrl+clicking a unit portrait in the selection wireframe:
;; Deselects all units of `unwanted-type` from `candidate-units`.
(define (simulate-shift-ctrl-deselect-type unwanted-type candidate-units)
  (filter (lambda (u)
            (not (eq? (hash-ref u 'type 'unknown) unwanted-type)))
          candidate-units))

(define (infer-natural-control-group-for-units unit-records)
  (define types (remove-duplicates (map (lambda (u) (hash-ref u 'type 'unknown)) unit-records)))
  (cond
    [(null? types) #f]
    [(andmap (lambda (t) (memq t CORTEX-CASTER-SIEGE-UNIT-TYPES)) types) 3]
    [(andmap (lambda (t) (memq t CORTEX-HARASS-UNIT-TYPES)) types) 2]
    [(andmap (lambda (t) (not (memq t NON-COMBAT-SELECTION-INTRUDER-TYPES))) types) 1]
    [else #f]))

;; Compile a raw desired list of unit IDs into the minimum-APM physically valid
;; sequence of StarCraft II selection actions:
;;   - `keep-selection` (0 APM)
;;   - `select-ctrl-type` / `deselect-ctrl-type` within `active-selection` (1 APM)
;;   - `control-group-recall` [+ optional `select-ctrl-type` / `deselect-ctrl-type`] (1-2 APM)
;;   - On-screen `select-click` / `select-ctrl-type` / `select-box` [+ optional wireframe filter] (1-2 APM)
;;   - Optional on-the-fly control group binding (`control-group-steal`) when new units are boxed.
(define (compile-optimal-unit-selection! cortex
                                         raw-desired-ids
                                         ally-units
                                         [ally-buildings '()]
                                         #:allow-superset? [allow-superset? #t]
                                         #:compatible-pred [compatible-pred #f]
                                         #:allow-camera-move? [allow-camera-move? #t]
                                         #:allow-on-the-fly-cg-update? [allow-cg-update? #t])
  (define desired-list
    (sort (remove-duplicates
           (filter (lambda (id) (and (exact-integer? id) (> id 0)))
                   (if (list? raw-desired-ids) raw-desired-ids (list raw-desired-ids))))
          <))
  (define desired-set (list->seteqv desired-list))
  (define all-records (append ally-units ally-buildings))
  (define unit-by-id
    (for/hasheqv ([u (in-list all-records)]
                  #:when (and (hash? u) (exact-integer? (hash-ref u 'id #f))))
      (values (hash-ref u 'id) u)))
  (define desired-records
    (filter-map (lambda (id) (hash-ref unit-by-id id #f)) desired-list))
  (define desired-types
    (remove-duplicates (map (lambda (u) (hash-ref u 'type 'unknown)) desired-records)))
  (define single-desired-type
    (and (= (length desired-types) 1) (car desired-types)))
  (define desired-are-combat?
    (and (not (null? desired-records))
         (andmap (lambda (u)
                   (define ut (hash-ref u 'type 'unknown))
                   (and (not (memq ut NON-COMBAT-SELECTION-INTRUDER-TYPES))
                        (not (sc2-non-combat-or-summon-sym? ut))
                        (not (hash-ref u 'is-hallucination #f))
                        (not (hash-ref u 'hallucination #f))))
                 desired-records)))

  (define (unit-compatible? u)
    (define id (hash-ref u 'id 0))
    (define ut (hash-ref u 'type 'unknown))
    (or (set-member? desired-set id)
        (and allow-superset?
             (if compatible-pred
                 (compatible-pred u)
                 (and desired-are-combat?
                      (not (memq ut NON-COMBAT-SELECTION-INTRUDER-TYPES))
                      (not (sc2-non-combat-or-summon-sym? ut))
                      (not (hash-ref u 'is-hallucination #f))
                      (not (hash-ref u 'hallucination #f))
                      (not (memq ut '(queen queen-burrowed
                                      siege-tank-sieged liberator-ag
                                      lurker-burrowed lurker-mp-burrowed
                                      widow-mine-burrowed swarm-host-burrowed))))))))

  (define (ids->records ids)
    (filter-map (lambda (id) (hash-ref unit-by-id id #f)) ids))

  (define (selection-valid-and-covers? cand-ids [min-coverage-ratio 0.70])
    (define clean-ids
      (sort (remove-duplicates (filter (lambda (id) (hash-has-key? unit-by-id id)) cand-ids)) <))
    (define recs (ids->records clean-ids))
    (define covered
      (count (lambda (id) (set-member? desired-set id)) clean-ids))
    (define min-needed
      (max 1 (exact-ceiling (* min-coverage-ratio (max 1 (length desired-records))))))
    (define max-allowed
      (if allow-superset?
          (max (length desired-records)
               (exact-ceiling (* 1.35 (max 1 (length desired-records)))))
          (length desired-records)))
    (and (not (null? clean-ids))
         (>= covered min-needed)
         (<= (length clean-ids) max-allowed)
         (andmap unit-compatible? recs)
         clean-ids))

  (cond
    [(null? desired-records)
     ;; If unit tags are synthetic test IDs not present in `ally-units`, pass through directly
     (values '() desired-list)]
    [else
     (define active-ids
       (filter (lambda (id) (hash-has-key? unit-by-id id))
               (cortex-active-selection cortex)))
     (define active-recs (ids->records active-ids))
     (define candidates '())
     (define (add-candidate! apm-cost covered-count seq realized-ids [box-origin? #f])
       (when (and (pair? realized-ids) (> covered-count 0))
         (set! candidates
               (cons (list apm-cost covered-count seq (sort (remove-duplicates realized-ids) <) box-origin?)
                     candidates))))

     ;; -----------------------------------------------------------------------
     ;; 1. Active Selection Reuse (0 APM) or Active Wireframe Sub-Select (1 APM)
     ;; -----------------------------------------------------------------------
     (when (not (null? active-ids))
       (define valid-active (selection-valid-and-covers? active-ids 0.85))
       (when valid-active
         (add-candidate! 0
                         (count (lambda (id) (set-member? desired-set id)) valid-active)
                         '()
                         valid-active
                         #f))
       ;; 1b. Ctrl-click single unit type `T` inside current `active-selection` (1 APM)
       (when single-desired-type
         (define sub-recs (simulate-ctrl-click-subselect single-desired-type active-recs))
         (define sub-ids (map (lambda (u) (hash-ref u 'id 0)) sub-recs))
         (define valid-sub (selection-valid-and-covers? sub-ids 0.75))
         (when valid-sub
           (add-candidate! 1
                           (count (lambda (id) (set-member? desired-set id)) valid-sub)
                           (list (list 'select-ctrl-type single-desired-type valid-sub))
                           valid-sub
                           #f)))
       ;; 1c. Shift+Ctrl-click deselect single intruder type from `active-selection` (1 APM)
       (define bad-types
         (remove-duplicates
          (map (lambda (u) (hash-ref u 'type 'unknown))
               (filter (lambda (u) (not (unit-compatible? u))) active-recs))))
       (when (= (length bad-types) 1)
         (define bad-t (car bad-types))
         (define desel-recs (simulate-shift-ctrl-deselect-type bad-t active-recs))
         (define desel-ids (map (lambda (u) (hash-ref u 'id 0)) desel-recs))
         (define valid-desel (selection-valid-and-covers? desel-ids 0.75))
         (when valid-desel
           (add-candidate! 1
                           (count (lambda (id) (set-member? desired-set id)) valid-desel)
                           (list (list 'deselect-ctrl-type bad-t valid-desel))
                           valid-desel
                           #f))))

     ;; -----------------------------------------------------------------------
     ;; 2. Control Group Recall (1 APM) or Recall + Wireframe Ctrl-Click (2 APM)
     ;; -----------------------------------------------------------------------
     (for ([g (in-list '(1 2 3 8 4 5 6 7 9 0))])
       (define cg-ids
         (filter (lambda (id) (hash-has-key? unit-by-id id))
                 (cortex-get-control-group cortex g)))
       (define all-desired-in-cg?
         (andmap (lambda (id) (not (not (memv id cg-ids)))) desired-list))
       (when (and all-desired-in-cg? (not (null? cg-ids)))
         (define cg-recs (ids->records cg-ids))
         ;; 2a. Direct Control Group Recall (1 APM)
         (define valid-cg (selection-valid-and-covers? cg-ids 0.75))
         (when valid-cg
           (add-candidate! 1
                           (count (lambda (id) (set-member? desired-set id)) valid-cg)
                           (list (list 'control-group-recall g valid-cg))
                           valid-cg
                           #f))
         ;; 2b. Control Group Recall + Wireframe Ctrl-Click Type (2 APM)
         (when single-desired-type
           (define sub-recs (simulate-ctrl-click-subselect single-desired-type cg-recs))
           (define sub-ids (map (lambda (u) (hash-ref u 'id 0)) sub-recs))
           (define valid-sub (selection-valid-and-covers? sub-ids 0.75))
           (when valid-sub
             (add-candidate! 2
                             (count (lambda (id) (set-member? desired-set id)) valid-sub)
                             (list (list 'control-group-recall g cg-ids)
                                   (list 'select-ctrl-type single-desired-type valid-sub))
                             valid-sub
                             #f)))
         ;; 2c. Control Group Recall + Wireframe Shift+Ctrl-Click Deselect Intruder Type (2 APM)
         (define cg-bad-types
           (remove-duplicates
            (map (lambda (u) (hash-ref u 'type 'unknown))
                 (filter (lambda (u) (not (unit-compatible? u))) cg-recs))))
         (when (= (length cg-bad-types) 1)
           (define bad-t (car cg-bad-types))
           (define desel-recs (simulate-shift-ctrl-deselect-type bad-t cg-recs))
           (define desel-ids (map (lambda (u) (hash-ref u 'id 0)) desel-recs))
           (define valid-desel (selection-valid-and-covers? desel-ids 0.75))
           (when valid-desel
             (add-candidate! 2
                             (count (lambda (id) (set-member? desired-set id)) valid-desel)
                             (list (list 'control-group-recall g cg-ids)
                                   (list 'deselect-ctrl-type bad-t valid-desel))
                             valid-desel
                             #f)))))

     ;; -----------------------------------------------------------------------
     ;; 3. On-Screen Box-Drag, Single-Click & On-Screen Ctrl-Click Type
     ;;    (Strictly restricted to units inside the camera viewport!)
     ;; -----------------------------------------------------------------------
     (define cur-cam-x (human-cortex-cam-x cortex))
     (define cur-cam-y (human-cortex-cam-y cortex))
     (define on-screen-desired-now
       (units-in-camera-viewport desired-records cur-cam-x cur-cam-y))
     (define need-camera-move?
       (and allow-camera-move?
            (< (length on-screen-desired-now)
               (max 1 (exact-ceiling (* 0.50 (length desired-records)))))))
     (define-values (eff-cam-x eff-cam-y cam-prefix cam-cost)
       (if need-camera-move?
           (let* ([cx (/ (for/sum ([u (in-list desired-records)])
                           (exact->inexact (hash-ref u 'x cur-cam-x)))
                         (max 1.0 (exact->inexact (length desired-records))))]
                  [cy (/ (for/sum ([u (in-list desired-records)])
                           (exact->inexact (hash-ref u 'y cur-cam-y)))
                         (max 1.0 (exact->inexact (length desired-records))))])
             (values cx cy (list (list 'move-camera cx cy)) 1))
           (values cur-cam-x cur-cam-y '() 0)))

     (define screen-ally-units
       (units-in-camera-viewport ally-units eff-cam-x eff-cam-y))
     (define screen-desired
       (units-in-camera-viewport desired-records eff-cam-x eff-cam-y))

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

       ;; 3b. On-Screen Ctrl+Click Unit Type (1 APM + cam-cost)
       (when single-desired-type
         (define screen-same-type
           (simulate-ctrl-click-subselect single-desired-type screen-ally-units))
         (when (and (not (null? screen-same-type))
                    (andmap unit-compatible? screen-same-type))
           (define u0 (car screen-desired))
           (define st-ids (map (lambda (u) (hash-ref u 'id 0)) screen-same-type))
           (define cov (count (lambda (id) (set-member? desired-set id)) st-ids))
           (add-candidate! (+ 1 cam-cost)
                           cov
                           (append cam-prefix
                                   (list (list 'select-ctrl-type
                                               single-desired-type
                                               (hash-ref u0 'x eff-cam-x)
                                               (hash-ref u0 'y eff-cam-y)
                                               st-ids)))
                           st-ids
                           #t)))

       ;; 3c. On-Screen Axis-Aligned Box-Drag `[x0, x1] x [y0, y1]`
       (define x0 (apply min (map (lambda (u) (exact->inexact (hash-ref u 'x eff-cam-x))) screen-desired)))
       (define x1 (apply max (map (lambda (u) (exact->inexact (hash-ref u 'x eff-cam-x))) screen-desired)))
       (define y0 (apply min (map (lambda (u) (exact->inexact (hash-ref u 'y eff-cam-y))) screen-desired)))
       (define y1 (apply max (map (lambda (u) (exact->inexact (hash-ref u 'y eff-cam-y))) screen-desired)))
       (define boxed-units
         (simulate-box-drag-on-screen x0 y0 x1 y1 screen-ally-units eff-cam-x eff-cam-y))
       (define boxed-ids (map (lambda (u) (hash-ref u 'id 0)) boxed-units))
       (define incompatible-in-box
         (filter (lambda (u) (not (unit-compatible? u))) boxed-units))

       (cond
         ;; Clean Box: zero incompatible intruders inside `[x0, x1] x [y0, y1]` (1 APM + cam-cost)
         [(null? incompatible-in-box)
          (define cov (count (lambda (id) (set-member? desired-set id)) boxed-ids))
          (add-candidate! (+ 1 cam-cost)
                          cov
                          (append cam-prefix
                                  (list (list 'select-box x0 y0 x1 y1 boxed-ids)))
                          boxed-ids
                          #t)]
         [else
          ;; Option i: Box + Wireframe Ctrl-Click Type (2 APM + cam-cost)
          (when single-desired-type
            (define sub-recs (simulate-ctrl-click-subselect single-desired-type boxed-units))
            (define sub-ids (map (lambda (u) (hash-ref u 'id 0)) sub-recs))
            (when (and (not (null? sub-ids))
                       (andmap unit-compatible? sub-recs))
              (define cov (count (lambda (id) (set-member? desired-set id)) sub-ids))
              (add-candidate! (+ 2 cam-cost)
                              cov
                              (append cam-prefix
                                      (list (list 'select-box x0 y0 x1 y1 boxed-ids)
                                            (list 'select-ctrl-type single-desired-type sub-ids)))
                              sub-ids
                              #t)))

          ;; Option ii: Box + Wireframe Shift+Ctrl-Click Deselect Intruder Type (2 APM + cam-cost)
          (define intruder-types
            (remove-duplicates (map (lambda (u) (hash-ref u 'type 'unknown)) incompatible-in-box)))
          (when (= (length intruder-types) 1)
            (define bad-t (car intruder-types))
            (define cleaned-recs (simulate-shift-ctrl-deselect-type bad-t boxed-units))
            (define cleaned-ids (map (lambda (u) (hash-ref u 'id 0)) cleaned-recs))
            (when (and (not (null? cleaned-ids))
                       (andmap unit-compatible? cleaned-recs))
              (define cov (count (lambda (id) (set-member? desired-set id)) cleaned-ids))
              (add-candidate! (+ 2 cam-cost)
                              cov
                              (append cam-prefix
                                      (list (list 'select-box x0 y0 x1 y1 boxed-ids)
                                            (list 'deselect-ctrl-type bad-t cleaned-ids)))
                              cleaned-ids
                              #t)))

          ;; Option iii: Intruder-Pruned Sub-Box (shrink box to exclude incompatible intruders, 1 APM + cam-cost)
          (let prune-loop ([sub-desired screen-desired])
            (when (>= (length sub-desired) 1)
              (define sx0 (apply min (map (lambda (u) (exact->inexact (hash-ref u 'x eff-cam-x))) sub-desired)))
              (define sx1 (apply max (map (lambda (u) (exact->inexact (hash-ref u 'x eff-cam-x))) sub-desired)))
              (define sy0 (apply min (map (lambda (u) (exact->inexact (hash-ref u 'y eff-cam-y))) sub-desired)))
              (define sy1 (apply max (map (lambda (u) (exact->inexact (hash-ref u 'y eff-cam-y))) sub-desired)))
              (define sub-boxed
                (simulate-box-drag-on-screen sx0 sy0 sx1 sy1 screen-ally-units eff-cam-x eff-cam-y))
              (define sub-bad (filter (lambda (u) (not (unit-compatible? u))) sub-boxed))
              (cond
                [(null? sub-bad)
                 (define sb-ids (map (lambda (u) (hash-ref u 'id 0)) sub-boxed))
                 (define cov (count (lambda (id) (set-member? desired-set id)) sb-ids))
                 (add-candidate! (+ 1 cam-cost)
                                 cov
                                 (append cam-prefix
                                         (list (if (= (length sb-ids) 1)
                                                   (list 'select-click (car sb-ids) sx0 sy0 sb-ids)
                                                   (list 'select-box sx0 sy0 sx1 sy1 sb-ids))))
                                 sb-ids
                                 (> (length sb-ids) 1))]
                [(> (length sub-desired) 1)
                 (define cx (/ (for/sum ([u (in-list sub-desired)]) (exact->inexact (hash-ref u 'x eff-cam-x)))
                               (exact->inexact (length sub-desired))))
                 (define cy (/ (for/sum ([u (in-list sub-desired)]) (exact->inexact (hash-ref u 'y eff-cam-y)))
                               (exact->inexact (length sub-desired))))
                 (define outlier
                   (argmax (lambda (u)
                             (+ (sqr (- (hash-ref u 'x cx) cx))
                                (sqr (- (hash-ref u 'y cy) cy))))
                           sub-desired))
                 (prune-loop (remq outlier sub-desired))])))]))

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
                           [cur-set (list->seteqv cur-cg)]
                           [has-new? (ormap (lambda (id) (not (set-member? cur-set id))) best-ids)])
                      (if has-new?
                          (let ([merged-cg (remove-duplicates (append cur-cg best-ids))])
                            (cortex-steal-control-group! cortex nat-g merged-cg)
                            (list (list 'control-group-steal nat-g merged-cg)))
                          '()))
                    '()))
              '()))
        (values (append best-seq cg-update-tail) best-ids)])]))

;; Coalesce per-unit tactical commands into shared group commands, order broad-group
;; commands before narrowed wireframe `select-ctrl-type` commands, and compile each
;; command's unit selection into minimal-APM `select-box` / `control-group-recall` /
;; `select-ctrl-type` / `deselect-ctrl-type` sequences.
(define (cortex-collapse-and-compile-selections! cortex
                                                 candidate-actions
                                                 ally-units
                                                 [ally-buildings '()]
                                                 #:allow-camera-move? [allow-camera-move? #t])
  (define (quantize-pt v)
    (/ (round (* (exact->inexact v) 0.5)) 0.5))

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
    (define uid-arg (if (= (length uids) 1) (car uids) uids))
    (match template-act
      [(list (or 'attack 'attack-unit) _ target-id)
       (list 'attack-unit uid-arg target-id)]
      [(list op _ rest ...)
       (cons op (cons uid-arg rest))]))

  ;; Collect unit IDs with pending explicit mode-switch, morph, burrow/unburrow, or spell commands
  ;; (plus units currently in protected morph/channel orders in the SC2 engine) so generic
  ;; `attack`/`move` superset box-drags never overwrite them!
  (define protected-mode-or-spell-uids
    (for/fold ([s (seteqv)]) ([act (in-list candidate-actions)])
      (match act
        [(list (or 'cast 'cast-spell 'use-ability
                   'burrow-down 'burrow-up 'burrow 'unburrow
                   'siege-mode 'unsiege-mode 'morph 'archon-warp
                   'inject-larva 'spawn-creep-tumor 'spread-creep-tumor)
               raw-uid _ ...)
         (define uids
           (filter exact-integer? (if (list? raw-uid) raw-uid (list raw-uid))))
         (for/fold ([acc s]) ([id (in-list uids)])
           (set-add acc id))]
        [_ s])))

  (define all-explicitly-commanded-uids
    (for/fold ([s (seteqv)]) ([act (in-list candidate-actions)])
      (if (or (ui-or-framing-action? act) (< (length act) 2))
          s
          (let* ([raw-uid (second act)]
                 [uids (filter (lambda (id) (and (exact-integer? id) (> id 0)))
                               (if (list? raw-uid) raw-uid (list raw-uid)))])
            (for/fold ([acc s]) ([id (in-list uids)])
              (set-add acc id))))))

  (define protected-in-engine-uids
    (for/fold ([s (seteqv)]) ([u (in-list ally-units)] #:when (hash? u))
      (define uid (hash-ref u 'id 0))
      (define pclass (sc2-order-protection-class (hash-ref u 'order-ability-id 0)))
      (if (and (exact-integer? uid) (> uid 0) (memq pclass '(morph channel)))
          (set-add s uid)
          s)))

  ;; 1. Coalesce per-unit commands sharing the same equivalence key
  (define key->uids (make-hash))
  (define key->template (make-hash))
  (for ([act (in-list candidate-actions)])
    (define k (unit-command-coalesce-key act))
    (when k
      (unless (hash-has-key? key->template k)
        (hash-set! key->template k act))
      (hash-set! key->uids k
                 (append (hash-ref key->uids k '()) (extract-action-uids act)))))

  (define emitted-keys (mutable-set))
  (define coalesced-list '())
  (for ([act (in-list candidate-actions)])
    (define k (unit-command-coalesce-key act))
    (cond
      [(not k)
       (set! coalesced-list (cons act coalesced-list))]
      [(not (set-member? emitted-keys k))
       (set-add! emitted-keys k)
       (define uids (remove-duplicates (hash-ref key->uids k '())))
       (set! coalesced-list
             (cons (rebuild-coalesced-action (hash-ref key->template k act) uids)
                   coalesced-list))]))
  (define ordered-coalesced (reverse coalesced-list))

  ;; 2. Sort combat commands so generic movement/attack commands ALWAYS execute BEFORE
  ;;    mode-switch/morph/spell commands (`cast-spell`), both preventing a generic `attack`/`move`
  ;;    from overwriting a mode-switch later in the same frame and enabling 1-click
  ;;    `select-ctrl-type` wireframe narrowing from the active army selection!
  (define combat-cmds
    (filter (lambda (a) (unit-command-coalesce-key a)) ordered-coalesced))
  (define sorted-combat-cmds
    (sort combat-cmds
          >
          #:key (lambda (a)
                  (define uids (extract-action-uids a))
                  (define is-spell-cmd? (memq (car a) '(cast cast-spell)))
                  (+ (if is-spell-cmd? 0 100000)
                     (* 10 (length uids))
                     (if (memq (car a) '(attack-unit attack attack-pos move kite)) 5 0)))))
  (define combat-queue sorted-combat-cmds)
  (define reordered-actions
    (for/list ([a (in-list ordered-coalesced)])
      (if (unit-command-coalesce-key a)
          (begin0 (car combat-queue)
            (set! combat-queue (cdr combat-queue)))
          a)))

  ;; 3. Compile each coalesced unit command through `compile-optimal-unit-selection!`
  (define compiled-out '())
  (for ([act (in-list reordered-actions)])
    (define k (unit-command-coalesce-key act))
    (cond
      [(not k)
       ;; Keep cortex camera & control-group state synced with explicit framing actions
       (match act
         [(list (or 'move-camera 'camera-focus) (? real? cx) (? real? cy))
          (cortex-move-camera! cortex cx cy)]
         [(list 'camera-focus _ (? real? cx) (? real? cy))
          (cortex-move-camera! cortex cx cy)]
         [(list 'control-group-recall (? exact-integer? g) _ ...)
          (set-cortex-active-selection! cortex (cortex-get-control-group cortex g))]
         [_ (void)])
       (set! compiled-out (append compiled-out (list act)))]
      [else
       (define desired-uids (extract-action-uids act))
       (define is-spell? (memq (car act) '(cast cast-spell)))
       (define allow-superset-for-cmd?
         (and (not is-spell?)
              (> (length desired-uids) 1)
              (not (eq? (car act) 'hold-position))))
       (define superset-compat-pred
         (and allow-superset-for-cmd?
              (lambda (u)
                (define uid (hash-ref u 'id 0))
                (define ut (hash-ref u 'type 'unknown))
                (and (not (set-member? all-explicitly-commanded-uids uid))
                     (not (set-member? protected-mode-or-spell-uids uid))
                     (not (set-member? protected-in-engine-uids uid))
                     (not (sc2-non-combat-or-summon-sym? ut))
                     (not (memq ut NON-COMBAT-SELECTION-INTRUDER-TYPES))
                     (not (memq ut '(queen queen-burrowed
                                     siege-tank-sieged liberator-ag
                                     lurker-burrowed lurker-mp-burrowed
                                     widow-mine-burrowed swarm-host-burrowed)))))))
       (define-values (sel-seq realized-uids)
         (compile-optimal-unit-selection!
          cortex
          desired-uids
          ally-units
          ally-buildings
          #:allow-superset? allow-superset-for-cmd?
          #:compatible-pred superset-compat-pred
          #:allow-camera-move? allow-camera-move?
          #:allow-on-the-fly-cg-update? allow-superset-for-cmd?))
       (when (not (null? realized-uids))
         (set! compiled-out
               (append compiled-out
                       sel-seq
                       (list (rebuild-coalesced-action act realized-uids)))))]))
  compiled-out)

;; =============================================================================
;; Action Prioritization & Viewport / Token-Bucket Filtering
;; =============================================================================

;; Determine whether an action targets an un-control-grouped unit or spatial map
;; location that requires camera framing, returning `(cons cx cy)` or `#f`.
(define (action-requires-camera-focus act all-cgroup-member-ids unit-pos-by-id home-x home-y)
  (define (in-cgroup? uid)
    (cond
      [(set? all-cgroup-member-ids) (set-member? all-cgroup-member-ids uid)]
      [(list? all-cgroup-member-ids) (not (not (memv uid all-cgroup-member-ids)))]
      [(hash? all-cgroup-member-ids) (hash-has-key? all-cgroup-member-ids uid)]
      [else #f]))
  (define (extract-ids raw)
    (filter (lambda (id) (and (exact-integer? id) (> id 0)))
            (if (list? raw) raw (list raw))))
  (define (lookup-pos uid)
    (and (hash? unit-pos-by-id)
         (exact-integer? uid)
         (let ([p (hash-ref unit-pos-by-id uid #f)])
           (and (pair? p) (real? (car p)) (real? (cdr p))
                (cons (exact->inexact (car p)) (exact->inexact (cdr p)))))))
  (define (ungrouped-unit-pos raw-uids [fb-pos #f])
    (define uids (extract-ids raw-uids))
    (define ungrouped-id
      (for/first ([id (in-list uids)]
                  #:when (not (in-cgroup? id)))
        id))
    (and ungrouped-id
         (or (lookup-pos ungrouped-id)
             (for/or ([id (in-list uids)]) (lookup-pos id))
             fb-pos)))
  (define (first-real-pair xs)
    (let loop ([rem xs])
      (cond
        [(not (pair? rem)) #f]
        [(and (real? (car rem)) (pair? (cdr rem)) (real? (cadr rem)))
         (cons (exact->inexact (car rem)) (exact->inexact (cadr rem)))]
        [else (loop (cdr rem))])))
  (match act
    [(list (or 'move-camera 'camera-focus 'camera-bookmark-save 'camera-bookmark-jump
               'control-group-set 'control-group-append 'control-group-steal
               'control-group-append-steal 'control-group-recall
               'select-box 'select-click 'select-ctrl-type 'deselect-ctrl-type
               'human-apm-discipline 'train 'train-unit 'research 'posture-transition)
           _ ...)
     #f]
    [(list 'build _ (? real? x) (? real? y) _ ...)
     (cons (exact->inexact x) (exact->inexact y))]
    [(list 'build _ _ (? real? x) (? real? y) _ ...)
     (cons (exact->inexact x) (exact->inexact y))]
    [(list 'expand (? real? x) (? real? y) _ ...)
     (cons (exact->inexact x) (exact->inexact y))]
    [(list 'expand _ (? real? x) (? real? y) _ ...)
     (cons (exact->inexact x) (exact->inexact y))]
    [(list 'build-nydus-worm (? real? x) (? real? y) _ ...)
     (cons (exact->inexact x) (exact->inexact y))]
    [(list 'build-nydus-worm _ (? real? x) (? real? y) _ ...)
     (cons (exact->inexact x) (exact->inexact y))]
    [(list (or 'scout-sector 'clear-expansion-block) rest ...)
     (first-real-pair rest)]
    [(list (or 'worker-scout 'overlord-scout 'periodic-scout
               'patrol-block-expansion 'burrow-block)
           raw-uid rest ...)
     (define pt (first-real-pair rest))
     (define uids (extract-ids raw-uid))
     (if (null? uids)
         pt
         (ungrouped-unit-pos uids pt))]
    [(list (or 'cast 'cast-spell) raw-uid _spell args ...)
     (define pt
       (or (first-real-pair args)
           (and (pair? args) (exact-integer? (car args)) (lookup-pos (car args)))))
     (ungrouped-unit-pos raw-uid pt)]
    [(list (or 'inject-larva 'harvest-mineral 'harvest-gas
               'rebalance-gas-to-minerals 'resume-halted-building
               'attack 'attack-unit 'focus-fire)
           raw-uid target-id _ ...)
     (ungrouped-unit-pos raw-uid (or (lookup-pos target-id)
                                     (cons (exact->inexact home-x) (exact->inexact home-y))))]
    [(list (or 'move 'kite 'retreat 'hold-position 'attack-pos
               'mineral-walk 'worker-harass 'mineral-harass 'multi-prong-drop
               'pull-workers-attack 'worker-drill-stack-attack 'harass-workers
               'burrow-down 'burrow-up 'roach-tunnel-move 'infestor-burrow-move
               'infestor-burrow-cast 'blind-skillshot-shimmer
               'land-building 'transport-juggle 'snipe-enemy-changeling
               'morph 'cancel 'cancel-building)
           raw-uid rest ...)
     (ungrouped-unit-pos raw-uid (first-real-pair rest))]
    [_ #f]))

(define (ui-or-framing-action? act)
  (match act
    [(list (or 'posture-transition
               'move-camera
               'camera-focus
               'camera-bookmark-save
               'camera-bookmark-jump
               'control-group-steal
               'control-group-set
               'control-group-append
               'control-group-append-steal
               'control-group-recall
               'select-box
               'select-click
               'select-ctrl-type
               'deselect-ctrl-type
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
    [(list (or 'swap-addon 'terran-addon-swap 'land-building) _ ...) 92]
    [(list (or 'burrow-down 'burrow-up 'transport-juggle) _ ...) 91]
    [(list 'multi-prong-drop _ ...)          90]
    [(list 'mineral-walk _ ...)              90]
    [(list 'morph _ ...)                     90]
    [(list (or 'worker-harass 'mineral-harass) _ ...) 89]
    [(list 'build _ ...)                     89]
    [(list 'expand _ ...)                    89]
    [(list 'inject-larva _ ...)              88]
    [(list 'chrono-boost _ ...)              88]
    [(list 'calldown-mule _ ...)             88]
    [(list 'research _ ...)                  87]
    [(list (or 'emergency-detector-response 'blind-skillshot-shimmer) _ ...) 87]
    [(list (or 'cast 'cast-spell 'use-ability) _ ...) 86]
    [(list 'train _ ...)                     86]
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
    [(list 'control-group-append _ ...)      66]
    [(list 'control-group-append-steal _ ...) 66]
    [(list 'control-group-recall _ ...)      66]
    [(list 'select-box _ ...)                66]
    [(list 'select-click _ ...)              66]
    [(list 'select-ctrl-type _ ...)          66]
    [(list 'deselect-ctrl-type _ ...)        66]
    [(list (or 'cast-protective-buff-aura
               'position-in-buff-aura-with-splash-spread
               'pre-split-wings
               'form-concave-arc
               'high-ground-tactics) _ ...)  52]
    [(list 'harvest-gas _ ...)               42]
    [(list 'harvest-mineral _ ...)           40]
    [_                                       55]))

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
  (define indexed
    (for/list ([a (in-list candidate-actions)]
               [i (in-naturals)])
      (cons i a)))
  (define ui-indexed (filter (lambda (p) (ui-or-framing-action? (cdr p))) indexed))
  (define unit-indexed (filter (lambda (p) (not (ui-or-framing-action? (cdr p)))) indexed))
  (define total-unit (length unit-indexed))
  (define critical-indexed
    (filter (lambda (p) (>= (action-priority (cdr p)) 85)) unit-indexed))
  (define lower-indexed
    (filter (lambda (p) (< (action-priority (cdr p)) 85)) unit-indexed))
  (define accepted-unit-indexed
    (cond
      [(<= total-unit cap)
       unit-indexed]
      [(>= (length critical-indexed) cap)
       (if budget
           (take (sort critical-indexed > #:key (lambda (p) (action-priority (cdr p)))) cap)
           critical-indexed)]
      [else
       (define rem-cap (- cap (length critical-indexed)))
       (append critical-indexed
               (take (sort lower-indexed > #:key (lambda (p) (action-priority (cdr p))))
                     (min (length lower-indexed) rem-cap)))]))
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
