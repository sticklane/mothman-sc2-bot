#lang racket/base

;; =============================================================================
;; `tools/tactics-unit-tester.rkt`
;; Expandable End-to-End Live-Pipeline Tactical Unit-Tester Suite for Mothman
;;
;; Exercises the REAL integrated Mothman decision + wire pipeline:
;;   sc2-observation
;;     -> sc2-observation->runtime-obs-hash   (lib/sc2-protobuf-ws.rkt)
;;     -> step-live-bot-runtime!              (lib/bot-runtime.rkt: L1..L5)
;;     -> translate-bot-actions->sc2-raw-commands (lib/sc2-protobuf-ws.rkt)
;;
;; Covers 3 structured tiers (32 scenarios across Protoss, Terran, Zerg):
;;   1. wave2-repro (9):  Direct reproductions of Wave-1 / #77 tactical failures
;;   2. core       (13):  Full P/T/Z core tactics (stutter-step, melee, tanks,
;;                        focus-fire, casters, choke, worker-pull, splash, rally)
;;   3. novel      (10):  Pro-inspired stress scenarios beyond known losses
;;
;; CLI:
;;   racket tools/tactics-unit-tester.rkt [--all] [--tier T] [--race R]
;;                                        [--scenario ID] [--list]
;;                                        [--json] [--out PATH] [--rev REV]
;;                                        [--strict]
;; =============================================================================

(require racket/cmdline
         racket/file
         racket/format
         racket/list
         racket/match
         racket/math
         racket/path
         racket/port
         racket/set
         racket/string
         racket/system
         json
         "../lib/bot-runtime.rkt"
         "../lib/mirror-mind-predictor.rkt"
         "../lib/sc2-game-constants.rkt"
         "../lib/sc2-protobuf-ws.rkt")

;; -----------------------------------------------------------------------------
;; Canonical SC2 Ability IDs (verified against lib/sc2-game-constants.rkt & ws)
;; -----------------------------------------------------------------------------
(define AB-MOVE                 16)
(define AB-PATROL               17)
(define AB-HOLD                 18)
(define AB-ATTACK               23)
(define AB-CANCEL               314)
(define AB-SIEGE-MODE           388)
(define AB-UNSIEGE-MODE         390)
(define AB-GUARDIAN-SHIELD      76)
(define AB-FEEDBACK             140)
(define AB-PSI-STORM            1036)
(define AB-BLINK-STALKER        1442)
(define AB-FORCE-FIELD          1526)
(define AB-EMP                  1628)
(define AB-CORROSIVE-BILE       2338)
(define AB-PURIFICATION-NOVA    2346)
(define AB-SNIPE                2714)
(define AB-GATHER               298)
(define AB-MINERAL-WALK-GATHER  3666)
(define AB-STIMPACK             3675)
(define AB-BLINK-GENERIC        3687)
(define AB-INTERFERENCE-MATRIX  3747)
(define AB-ANTI-ARMOR-MISSILE   3753)
(define AB-HEAL                 386)
(define AB-MEDIVAC-LOAD         394)
(define AB-WARP-PRISM-LOAD      911)
(define AB-STIM-ALT             367)
(define AB-STIM-MARAUDER        253)
(define AB-FUNGAL-GROWTH        74)
(define AB-BLINDING-CLOUD       2063)
(define AB-ABDUCT               2067)
(define AB-BURROW-WIDOW-MINE    2095)
(define AB-UNBURROW-WIDOW-MINE  2097)
(define AB-BURROW-LURKER        2108)
(define AB-UNBURROW-LURKER      2110)
(define AB-LIBERATOR-AG         2558)
(define AB-LIBERATOR-AA         2560)
(define AB-BURROW-DOWN          3661)
(define AB-BURROW-UP            3662)
(define AB-LOAD-GENERIC         3668)
(define AB-LOAD-BUNKER          407)
(define AB-SCANNER-SWEEP        399)
(define AB-CALLDOWN-MULE        171)
(define AB-SPAWN-CHANGELING     181)
(define AB-VIPER-CONSUME        2073)
(define AB-AUTO-TURRET          1764)
(define AB-MICROBIAL-SHROUD     4111)
(define AB-PULSAR-BEAM-OFF      2376)
(define AB-CREEP-TUMOR-QUEEN    1694)
(define AB-UNLOAD-ALL-AT        3669)
(define AB-MEDIVAC-UNLOAD-ALL-AT 396)
(define AB-WARP-PRISM-UNLOAD-ALL-AT 913)
(define AB-BUILD-INTERCEPTORS   1042)
(define AB-TRANSFUSE            1664)
(define AB-MORPH-ARCHON         1766)
(define AB-LOCK-ON              2350)
(define AB-YAMATO-CANNON        401)
(define AB-TACTICAL-JUMP        2358)
(define AB-THOR-HIGH-IMPACT     2362)
(define AB-THOR-EXPLOSIVE       2364)
(define AB-VIKING-ASSAULT       403)
(define AB-VIKING-FIGHTER       405)
(define AB-MORPH-HELLBAT        1998)
(define AB-REPAIR-GENERIC       3685)
(define AB-REPAIR-SCV           316)
(define AB-ORACLE-REVELATION    2146)
(define AB-PULSAR-BEAM-ON       2375)
(define AB-BATTERY-OVERCHARGE   4107)
(define AB-PARASITIC-BOMB       2542)
(define AB-NEURAL-PARASITE      249)
(define AB-BURROW-ROACH-DOWN    1386)
(define AB-BURROW-ROACH-UP      1388)
(define AB-CHRONO-BOOST         3755)
(define AB-DEPOT-LOWER          556)
(define AB-DEPOT-RAISE          558)
(define AB-BUNKER-LOAD          407)
(define AB-GRAVITON-BEAM        173)
(define AB-SPAWN-LOCUSTS        2704)
(define AB-SPAWN-LOCUSTS-FLYING 2704)
(define AB-CLOAK-GHOST          382)
(define AB-MORPH-BANELING       4121)
(define AB-MORPH-RAVAGER        2330)
(define AB-CAUSTIC-SPRAY        2324)
(define AB-CONTAMINATE          1825)
(define AB-MEDIVAC-BOOST        2116)
(define AB-STASIS-WARD          2505)
(define AB-ADEPT-SHADE          2544)
(define AB-CLOAK-BANSHEE        392)
(define AB-HALLUCINATION-PHOENIX 154)
(define AB-MORPH-OVERSIGHT-MODE 3743)
(define AB-PRISMATIC-ALIGNMENT 2393)
(define AB-KD8-CHARGE 2588)
(define AB-MORPH-WARP-PRISM-TRANSPORT 1530)
(define AB-INJECT-LARVA 251)
(define AB-NEXUS-MASS-RECALL 3757)
(define AB-DECLOAK-GHOST 383)
(define AB-DECLOAK-BANSHEE 393)
(define AB-UPROOT-SPINE 1725)
(define AB-UPROOT-SPORE 1727)
(define AB-CREEP-TUMOR-TUMOR 1733)
(define AB-TRAIN-SCV 524)
(define AB-TRAIN-MARINE 560)
(define AB-TRAIN-MARAUDER 563)
(define AB-TRAIN-SIEGE-TANK 591)
(define AB-TRAIN-MEDIVAC 620)
(define AB-TRAIN-VIKING 624)
(define AB-TRAIN-ZERGLING 1343)
(define AB-TRAIN-HYDRALISK 1345)
(define AB-TRAIN-MUTALISK 1346)
(define AB-TRAIN-ROACH 1351)
(define AB-TRAIN-CORRUPTOR 1353)
(define AB-MORPH-LAIR 1216)
(define AB-BUILD-BARRACKS 321)
(define AB-BUILD-BUNKER 324)
(define AB-BUILD-STARPORT 329)
(define AB-TRAIN-REAPER 561)
(define AB-BUILD-GATEWAY 883)
(define AB-BUILD-SHIELD-BATTERY 895)
(define AB-TRAIN-ZEALOT 916)
(define AB-SALVAGE-BUNKER 32)

;; Minimal SC2 protobuf wire encoders (for true wire-level decoding regression tests)
(define (pb-varint n)
  (let loop ([v (if (< n 0) (+ n (expt 2 64)) n)] [acc '()])
    (if (< v 128)
        (apply bytes (reverse (cons v acc)))
        (loop (arithmetic-shift v -7) (cons (bitwise-ior (bitwise-and v #x7f) #x80) acc)))))

(define (pb-f32 x)
  (real->floating-point-bytes (exact->inexact x) 4 #f))

(define (pb-tag-varint fnum v)
  (bytes-append (pb-varint (bitwise-ior (arithmetic-shift fnum 3) 0)) (pb-varint v)))

(define (pb-tag-f32 fnum x)
  (bytes-append (pb-varint (bitwise-ior (arithmetic-shift fnum 3) 5)) (pb-f32 x)))

(define (pb-tag-bytes fnum b)
  (bytes-append (pb-varint (bitwise-ior (arithmetic-shift fnum 3) 2))
                (pb-varint (bytes-length b))
                b))

(define (pb-encode-passenger tag utype hp hp-max)
  ;; Official raw.proto PassengerUnit: 1=tag, 2=health, 3=health_max, 6=unit_type
  (bytes-append
   (pb-tag-varint 1 tag)
   (pb-tag-f32 2 hp)
   (pb-tag-f32 3 hp-max)
   (pb-tag-varint 6 utype)))

(define (pb-encode-unit tag utype alliance owner x y
                        #:hp [hp 150.0] #:hp-max [hp-max 150.0]
                        #:energy [energy 0.0] #:flying? [flying? #f]
                        #:passengers [passengers '()]
                        #:cargo-taken [cargo-taken 0] #:cargo-max [cargo-max 0])
  (define pt-b (bytes-append (pb-tag-f32 1 x) (pb-tag-f32 2 y) (pb-tag-f32 3 8.0)))
  (apply bytes-append
         (append
          (list (pb-tag-varint 1 1)
                (pb-tag-varint 2 alliance)
                (pb-tag-varint 3 tag)
                (pb-tag-varint 4 utype)
                (pb-tag-varint 5 owner)
                (pb-tag-bytes 6 pt-b)
                (pb-tag-f32 8 0.75)
                (pb-tag-f32 9 1.0)
                (pb-tag-f32 14 hp)
                (pb-tag-f32 15 hp-max)
                (pb-tag-f32 17 energy)
                (pb-tag-f32 37 (if (> energy 0.0) 200.0 0.0))
                (pb-tag-varint 20 (if flying? 1 0))
                (pb-tag-varint 35 1))
          (for/list ([pb (in-list passengers)])
            (pb-tag-bytes 24 pb))
          (if (> cargo-taken 0) (list (pb-tag-varint 25 cargo-taken)) '())
          (if (> cargo-max 0)   (list (pb-tag-varint 26 cargo-max))   '()))))

(define (pb-encode-response-obs game-loop unit-bytes-list
                                #:minerals [minerals 200] #:vespene [vespene 100]
                                #:food-cap [food-cap 66] #:food-used [food-used 40]
                                #:food-army [food-army 16] #:food-workers [food-workers 24])
  (define pc-b
    (bytes-append (pb-tag-varint 1 1)
                  (pb-tag-varint 2 minerals)
                  (pb-tag-varint 3 vespene)
                  (pb-tag-varint 4 food-cap)
                  (pb-tag-varint 5 food-used)
                  (pb-tag-varint 6 food-army)
                  (pb-tag-varint 7 food-workers)
                  (pb-tag-varint 9 10)))
  (define raw-b (apply bytes-append (for/list ([ub (in-list unit-bytes-list)]) (pb-tag-bytes 2 ub))))
  (define obs-b (bytes-append (pb-tag-bytes 1 pc-b)
                              (pb-tag-bytes 5 raw-b)
                              (pb-tag-varint 9 game-loop)))
  (define resp-obs-b (pb-tag-bytes 3 obs-b))
  (bytes-append (pb-tag-bytes 10 resp-obs-b)
                (pb-tag-varint 99 3)))

;; -----------------------------------------------------------------------------
;; Helper: Distance, JSON Sanitization & VCS Revision Detection
;; -----------------------------------------------------------------------------
(define (dist2d-xy x1 y1 x2 y2)
  (define dx (- (exact->inexact x1) (exact->inexact x2)))
  (define dy (- (exact->inexact y1) (exact->inexact y2)))
  (sqrt (+ (* dx dx) (* dy dy))))

(define (sanitize-json v)
  (cond
    [(symbol? v) (symbol->string v)]
    [(and (real? v) (not (rational? v))) 0.0]
    [(list? v) (map sanitize-json v)]
    [(vector? v) (map sanitize-json (vector->list v))]
    [(hash? v)
     (for/hasheq ([(k val) (in-hash v)])
       (define ks (if (symbol? k) k (string->symbol (~a k))))
       (values ks (sanitize-json val)))]
    [else v]))

(define (detect-vcs-rev)
  (with-handlers ([exn:fail? (lambda (_) "unknown")])
    (define out
      (with-output-to-string
        (lambda ()
          (system "jj log -r @ --no-graph -T 'change_id.short(8) ++ \" \" ++ commit_id.short(8)' 2>/dev/null"))))
    (define trimmed (string-trim out))
    (if (non-empty-string? trimmed) trimmed "unknown")))

(define (utc-timestamp-iso)
  (with-handlers ([exn:fail? (lambda (_) "unknown")])
    (string-trim
     (with-output-to-string
       (lambda () (system "date -u +%Y-%m-%dT%H:%M:%SZ"))))))

;; -----------------------------------------------------------------------------
;; Synthetic-yet-Live SC2 Observation & Unit Builders
;; -----------------------------------------------------------------------------
(define (sym->uid sym)
  (define id (unit-symbol->sc2-id sym 0))
  (when (= id 0)
    (error 'sym->uid "Unknown SC2 unit symbol: ~a" sym))
  id)

(define (mk-unit tag type-sym alliance x y
                 #:hp [hp #f]
                 #:hp-max [hp-max #f]
                 #:shield [shield 0.0]
                 #:shield-max [shield-max 0.0]
                 #:energy [energy 0.0]
                 #:energy-max [energy-max 200.0]
                 #:build-progress [build-progress 1.0]
                 #:weapon-cooldown [weapon-cooldown 0.0]
                 #:flying? [flying? #f]
                 #:burrowed? [burrowed? #f]
                 #:cloak [cloak 0]
                 #:powered? [powered? #t]
                 #:assigned [assigned 0]
                 #:ideal [ideal 0]
                 #:orders [orders '()]
                 #:buffs [buffs '()]
                 #:add-on-tag [add-on-tag 0]
                 #:radius [radius 0.75]
                 #:minerals [minerals 0]
                 #:vespene [vespene 0]
                 #:display-type [display-type 1]
                 #:passengers [passengers '()]
                 #:cargo-taken [cargo-taken 0]
                 #:cargo-max [cargo-max 0])
  (define ut-id (sym->uid type-sym))
  (define default-hp
    (case type-sym
      [(nexus hatchery lair hive command-center orbital-command planetary-fortress) 1500.0]
      [(pylon gateway warp-gate cybernetics-core robotics-facility stargate barracks factory starport
              spawning-pool roach-warren hydralisk-den spire baneling-nest) 500.0]
      [(photon-cannon shield-battery spine-crawler spore-crawler bunker missile-turret) 300.0]
      [(marine zergling baneling) 45.0]
      [(marauder stalker roach ravager adept hydralisk) 125.0]
      [(zealot) 100.0]
      [(immortal siege-tank siege-tank-sieged lurker lurker-mp lurker-burrowed lurker-mp-burrowed) 175.0]
      [(colossus tempest carrier battlecruiser thor ultralisk) 300.0]
      [(high-templar ghost raven viper infestor oracle medivac warp-prism observer) 80.0]
      [(probe scv drone) 45.0]
      [(creep-tumor creep-tumor-burrowed creep-tumor-queen) 50.0]
      [(overlord overseer) 200.0]
      [(mineral-field) 1500.0]
      [(vespene-geyser) 2250.0]
      [else 100.0]))
  (define max-hp-val (exact->inexact (or hp-max (if hp (max hp default-hp) default-hp))))
  (define cur-hp-val (exact->inexact (or hp default-hp)))
  (define is-fly?
    (or flying?
        (not (not (memq type-sym '(overlord overseer mutalisk corruptor brood-lord viper
                                            medivac banshee viking viking-fighter raven liberator liberator-ag battlecruiser
                                            observer warp-prism phoenix oracle void-ray carrier tempest mothership))))))
  (define is-burr?
    (or burrowed?
        (not (not (memq type-sym '(creep-tumor-burrowed lurker-burrowed lurker-mp-burrowed
                                                        widow-mine-burrowed roach-burrowed zergling-burrowed
                                                        infestor-burrowed baneling-burrowed))))))
  (define eff-min (if (eq? type-sym 'mineral-field) (if (> minerals 0) minerals 1500) minerals))
  (define eff-vesp (if (memq type-sym '(vespene-geyser extractor assimilator refinery))
                       (if (> vespene 0) vespene 2250)
                       vespene))
  (sc2-unit display-type
            alliance
            tag
            ut-id
            (if (= alliance 1) 1 (if (= alliance 4) 2 16))
            (sc2-point3d (exact->inexact x) (exact->inexact y) 8.0)
            0.0
            (exact->inexact radius)
            (exact->inexact build-progress)
            cloak
            #f
            #t
            #f
            cur-hp-val
            max-hp-val
            (exact->inexact shield)
            (exact->inexact (max shield shield-max))
            (exact->inexact energy)
            (exact->inexact energy-max)
            eff-min
            eff-vesp
            is-fly?
            is-burr?
            #f
            powered?
            #f
            orders
            add-on-tag
            buffs
            assigned
            ideal
            (exact->inexact weapon-cooldown)
            0
            0
            0
            0
            passengers
            cargo-taken
            cargo-max))

(define (mk-walkable-pathing-grid w h #:wall-rects [wall-rects '()])
  ;; Build an 8-bpp `sc2-image-grid` (1 = walkable, 0 = cliff/wall) for real ground-BFS Voronoi tests.
  (define data (make-bytes (* w h) 1))
  (for ([rect (in-list wall-rects)])
    (define x0 (max 0 (inexact->exact (floor (first rect)))))
    (define y0 (max 0 (inexact->exact (floor (second rect)))))
    (define x1 (min w (inexact->exact (ceiling (third rect)))))
    (define y1 (min h (inexact->exact (ceiling (fourth rect)))))
    (for* ([y (in-range y0 y1)]
           [x (in-range x0 x1)])
      (bytes-set! data (+ x (* y w)) 0)))
  (sc2-image-grid 8 w h data #f #f))

(define (make-standard-game-info our-race enemy-race
                                 #:enemy-x [enemy-x 160.0]
                                 #:enemy-y [enemy-y 160.0]
                                 #:map-size [map-size (cons 200 200)]
                                 #:playable-area [playable-area (hash 'x0 16.0 'y0 16.0 'x1 184.0 'y1 184.0)]
                                 #:pathing-grid [pathing-grid #f]
                                 #:terrain-height [terrain-height #f]
                                 #:placement-grid [placement-grid #f])
  (if (or pathing-grid terrain-height placement-grid)
      (sc2-game-info
       "TacticsArenaMap"
       "TacticsArenaMap.SC2Map"
       (list (hash 'player-id 1 'race-requested our-race 'race-actual our-race)
             (hash 'player-id 2 'race-requested enemy-race 'race-actual enemy-race))
       map-size
       playable-area
       (list (sc2-point2d (exact->inexact enemy-x) (exact->inexact enemy-y)))
       pathing-grid
       terrain-height
       placement-grid)
      (sc2-game-info
       "TacticsArenaMap"
       "TacticsArenaMap.SC2Map"
       (list (hash 'player-id 1 'race-requested our-race 'race-actual our-race)
             (hash 'player-id 2 'race-requested enemy-race 'race-actual enemy-race))
       map-size
       playable-area
       (list (sc2-point2d (exact->inexact enemy-x) (exact->inexact enemy-y))))))

(define (default-neutral-minerals)
  (list
   ;; Main base minerals near (32, 32)
   (mk-unit 90001 'mineral-field 3 25.0 30.0)
   (mk-unit 90002 'mineral-field 3 25.0 32.0)
   (mk-unit 90003 'mineral-field 3 25.0 34.0)
   (mk-unit 90004 'vespene-geyser 3 28.0 26.0)
   ;; Natural minerals near (52, 32)
   (mk-unit 90011 'mineral-field 3 52.0 25.0)
   (mk-unit 90012 'mineral-field 3 54.0 25.0)
   ;; Third minerals near (72, 32)
   (mk-unit 90021 'mineral-field 3 72.0 25.0)
   ;; Enemy natural & main minerals
   (mk-unit 90031 'mineral-field 3 167.0 160.0)
   (mk-unit 90032 'mineral-field 3 140.0 167.0)
   ;; Hidden expansion cluster at (88, 138)
   (mk-unit 90041 'mineral-field 3 88.0 144.0)
   (mk-unit 90042 'mineral-field 3 90.0 144.0)))

(define (race->townhall-sym race)
  (case race
    [(Protoss) 'nexus]
    [(Terran)  'command-center]
    [(Zerg)    'hatchery]
    [else      'command-center]))

(define (race->worker-sym race)
  (case race
    [(Protoss) 'probe]
    [(Terran)  'scv]
    [(Zerg)    'drone]
    [else      'scv]))

(define (mk-home-base-units race
                            #:base-x [bx 32.0]
                            #:base-y [by 32.0]
                            #:workers [n-workers 16]
                            #:with-natural? [with-nat? #f]
                            #:nat-x [nx 52.0]
                            #:nat-y [ny 32.0])
  (define th-sym (race->townhall-sym race))
  (define w-sym (race->worker-sym race))
  (append
   (list (mk-unit 1001 th-sym 1 bx by #:assigned (min 16 n-workers) #:ideal 16))
   (if with-nat?
       (list (mk-unit 1002 th-sym 1 nx ny #:assigned 8 #:ideal 16))
       '())
   (for/list ([i (in-range n-workers)])
     (mk-unit (+ 1100 i) w-sym 1
              (+ (- bx 5.0) (* 0.3 (modulo i 6)))
              (+ (- by 2.0) (* 0.4 (quotient i 6)))
              #:orders (list (sc2-unit-order AB-GATHER #f 90001 0.0))))))

(define (mk-obs loop units
                #:minerals [minerals 200]
                #:vespene [vespene 100]
                #:food-used [food-used 40]
                #:food-cap [food-cap 100]
                #:food-army [food-army 24]
                #:food-workers [food-workers 16]
                #:larva-count [larva-count 3]
                #:upgrades [upgrades '()]
                #:effects [effects '()]
                #:dead-tags [dead-tags '()]
                #:neutral-units [neutral-units #f]
                #:camera-x [camera-x 32.0]
                #:camera-y [camera-y 32.0])
  (define upg-ids
    (filter (lambda (id) (> id 0))
            (for/list ([u (in-list upgrades)])
              (if (exact-integer? u) u (upgrade-symbol->sc2-id u 0)))))
  (sc2-observation
   loop
   (sc2-player-common 1 minerals vespene food-cap food-used food-army food-workers 0
                      (max 0 (quotient food-army 2)) 0 larva-count)
   (append (or neutral-units (default-neutral-minerals)) units)
   upg-ids
   '()
   (sc2-point3d (exact->inexact camera-x) (exact->inexact camera-y) 8.0)
   dead-tags
   effects
   '()
   '()
   '()
   '()))

;; -----------------------------------------------------------------------------
;; Live-Pipeline Execution Driver
;; -----------------------------------------------------------------------------
(struct step-outcome
  (obs-hash bot-actions wire-cmds wire-rejects posture telemetry mm-tech-obs rt)
  #:transparent)

(define (run-live-step! rt gi obs our-race
                        #:enemy-base [enemy-base '(160.0 160.0)]
                        #:obs-overlay [obs-overlay (hash)])
  (define base-hash
    (sc2-observation->runtime-obs-hash obs
                                       #:game-info gi
                                       #:our-player-id 1
                                       #:configured-race our-race))
  (define obs-hash
    (for/fold ([h base-hash]) ([(k v) (in-hash obs-overlay)])
      (hash-set h k v)))
  (define step-res (step-live-bot-runtime! rt obs-hash))
  (define bot-actions (hash-ref step-res 'actions '()))
  (reset-typed-command-gate-stats!)
  (define wire-cmds
    (translate-bot-actions->sc2-raw-commands
     bot-actions
     obs
     #:enemy-base enemy-base
     #:role-leases (hash-ref step-res 'role-leases #f)
     #:reserved-aabbs (hash-ref step-res 'wall-reserved-aabbs '())
     #:game-info gi))
  (define wire-rejects (length (get-last-bot-action-rejects)))
  (define mm (live-bot-runtime-mirror-mind rt))
  (define mm-tech (and mm (mirror-mind-state-last-tech-observation mm)))
  (step-outcome obs-hash
                bot-actions
                wire-cmds
                wire-rejects
                (hash-ref step-res 'posture 'unknown)
                (hash-ref step-res 'telemetry (hash))
                mm-tech
                rt))

(define (run-pipeline-sequence our-race enemy-race step-specs
                               #:our-x [our-x 32.0]
                               #:our-y [our-y 32.0]
                               #:enemy-x [enemy-x 160.0]
                               #:enemy-y [enemy-y 160.0]
                               #:map-size [map-size (cons 200 200)]
                               #:playable-area [playable-area (hash 'x0 16.0 'y0 16.0 'x1 184.0 'y1 184.0)]
                               #:pathing-grid [pathing-grid #f]
                               #:placement-grid [placement-grid #f]
                               #:neutral-units [neutral-units #f])
  ;; Step 0: clean frame-0 reset so all sc2-protobuf-ws module caches reset AND l34-ctx-live-obs? -> #t
  (define gi (make-standard-game-info our-race enemy-race
                                      #:enemy-x enemy-x
                                      #:enemy-y enemy-y
                                      #:map-size map-size
                                      #:playable-area playable-area
                                      #:pathing-grid pathing-grid
                                      #:placement-grid placement-grid))
  (define rt (make-live-bot-runtime #:bot-name 'mothman-tactics-test
                                    #:race our-race))
  (define init-obs
    (mk-obs 0 (mk-home-base-units our-race #:base-x our-x #:base-y our-y #:workers 12)
            #:minerals 50 #:vespene 0 #:food-used 12 #:food-cap 15 #:food-army 0 #:food-workers 12
            #:neutral-units neutral-units #:camera-x our-x #:camera-y our-y))
  (run-live-step! rt gi init-obs our-race #:enemy-base (list enemy-x enemy-y))
  ;; Execute each scenario step in sequence and return list of step-outcomes
  (for/list ([sp (in-list step-specs)])
    (define obs (hash-ref sp 'obs))
    (define overlay (hash-ref sp 'overlay (hash)))
    (run-live-step! rt gi obs our-race
                    #:enemy-base (list enemy-x enemy-y)
                    #:obs-overlay overlay)))

;; -----------------------------------------------------------------------------
;; Command Inspection Helpers (Wire SC2 Commands + High-Level Bot Actions)
;; -----------------------------------------------------------------------------
(define (wire-cmds-for-tag wire-cmds tag)
  (for/list ([c (in-list wire-cmds)]
             #:when (and (sc2-raw-unit-command? c)
                         (memv tag (sc2-raw-unit-command-unit-tags c))))
    c))

(define (wire-abilities-for-tag wire-cmds tag)
  (map sc2-raw-unit-command-ability-id (wire-cmds-for-tag wire-cmds tag)))

(define (wire-has-ability? wire-cmds tags ab-id)
  (for/or ([c (in-list wire-cmds)])
    (and (sc2-raw-unit-command? c)
         (= (sc2-raw-unit-command-ability-id c) ab-id)
         (for/or ([t (in-list tags)])
           (not (not (memv t (sc2-raw-unit-command-unit-tags c))))))))

(define (wire-any-ability? wire-cmds tags ab-ids)
  (for/or ([ab (in-list ab-ids)])
    (wire-has-ability? wire-cmds tags ab)))

(define (wire-all-tags-have-ability? wire-cmds tags ab-id)
  (and (pair? tags)
       (for/and ([t (in-list tags)])
         (not (not (memv ab-id (wire-abilities-for-tag wire-cmds t)))))))

(define (wire-count-tags-with-ability wire-cmds tags ab-id)
  (for/sum ([t (in-list tags)])
    (if (memv ab-id (wire-abilities-for-tag wire-cmds t)) 1 0)))

(define (wire-count-tags-heading-deep wire-cmds tags deep-x deep-y
                                      #:enemy-tags [enemy-tags '()]
                                      #:radius [radius 35.0])
  ;; Counts tags issued an offensive ATTACK/MOVE/harass command into deep enemy territory
  ;; (targeting an enemy unit in `enemy-tags` or a map point within `radius` of `(deep-x, deep-y)`).
  (for/sum ([t (in-list tags)])
    (define deep?
      (for/or ([c (in-list (wire-cmds-for-tag wire-cmds t))])
        (and (memv (sc2-raw-unit-command-ability-id c) (list AB-ATTACK AB-MOVE AB-PATROL))
             (let ([tt (sc2-raw-unit-command-target-unit-tag c)]
                   [tp (sc2-raw-unit-command-target-pos c)])
               (or (and tt (memv tt enemy-tags))
                   (and tp (<= (dist2d-xy (sc2-point2d-x tp) (sc2-point2d-y tp) deep-x deep-y) radius)))))))
    (if deep? 1 0)))

(define (wire-pure-move-only? wire-cmds tag)
  (define abs (wire-abilities-for-tag wire-cmds tag))
  (and (pair? abs)
       (not (not (memv AB-MOVE abs)))
       (not (memv AB-ATTACK abs))))

(define (wire-targets-for-tags wire-cmds tags ab-id)
  (for/list ([c (in-list wire-cmds)]
             #:when (and (sc2-raw-unit-command? c)
                         (= (sc2-raw-unit-command-ability-id c) ab-id)
                         (for/or ([t (in-list tags)])
                           (not (not (memv t (sc2-raw-unit-command-unit-tags c)))))))
    (list (sc2-raw-unit-command-unit-tags c)
          (sc2-raw-unit-command-target-unit-tag c)
          (let ([p (sc2-raw-unit-command-target-pos c)])
            (and p (list (sc2-point2d-x p) (sc2-point2d-y p)))))))

(define (wire-count-local-attacks wire-cmds tags local-enemy-tags local-ex local-ey [radius 16.0])
  (for/sum ([t (in-list tags)])
    (define hits-local?
      (for/or ([c (in-list (wire-cmds-for-tag wire-cmds t))])
        (and (= (sc2-raw-unit-command-ability-id c) AB-ATTACK)
             (let ([tt (sc2-raw-unit-command-target-unit-tag c)]
                   [tp (sc2-raw-unit-command-target-pos c)])
               (or (and (> tt 0) (not (not (memv tt local-enemy-tags))))
                   (and tp (<= (dist2d-xy (sc2-point2d-x tp) (sc2-point2d-y tp) local-ex local-ey) radius)))))))
    (if hits-local? 1 0)))

(define (bot-actions-kite-tags bot-actions tags)
  (for/sum ([t (in-list tags)])
    (define kited?
      (for/or ([a (in-list bot-actions)])
        (match a
          [(list 'kite u _ _) (if (list? u) (not (not (memv t u))) (equal? u t))]
          [_ #f])))
    (if kited? 1 0)))

(define (wire-cmd->summary c)
  (hasheq 'ability_id (sc2-raw-unit-command-ability-id c)
          'ability_sym (symbol->string (sc2-id->ability-symbol (sc2-raw-unit-command-ability-id c) 'unknown))
          'unit_tags (sc2-raw-unit-command-unit-tags c)
          'target_tag (sc2-raw-unit-command-target-unit-tag c)
          'target_pos (let ([p (sc2-raw-unit-command-target-pos c)])
                        (if p (list (sc2-point2d-x p) (sc2-point2d-y p)) #f))))

(define (bot-actions-has-train? bot-actions unit-sym)
  (for/or ([a (in-list bot-actions)])
    (match a
      [(list 'train s) (eq? s unit-sym)]
      [(list 'train _ s) (eq? s unit-sym)]
      [(list 'morph s) (eq? s unit-sym)]
      [(list 'morph _ s) (eq? s unit-sym)]
      [(list 'warp-in s _ _) (eq? s unit-sym)]
      [_ #f])))

(define (bot-actions-has-cancel? bot-actions tag)
  (for/or ([a (in-list bot-actions)])
    (match a
      [(list (or 'cancel 'cancel-building) t) (= t tag)]
      [_ #f])))

(define (bot-actions-has-build? bot-actions bldg-sym)
  (for/or ([a (in-list bot-actions)])
    (match a
      [(list 'build s _ _) (eq? s bldg-sym)]
      [(list 'build _ s _ _) (eq? s bldg-sym)]
      [(list 'build-bldg s _ _) (eq? s bldg-sym)]
      [_ #f])))

(define (mk-check name passed? detail)
  (hasheq 'name name 'passed (not (not passed?)) 'detail detail))

;; -----------------------------------------------------------------------------
;; Scenario Registry Struct
;; -----------------------------------------------------------------------------
(struct tactical-scenario
  (id tier race enemy-race category description run-fn)
  #:transparent)

;; =============================================================================
;; TIER 1: WAVE-2 / #77 IMMEDIATE FAILURE REPRODUCTIONS (9 Scenarios)
;; =============================================================================

;; 0. W2-P0-0: SC2 `Unit.weapon_cooldown` wire normalization (game loops -> Faster seconds / 22.4)
(define scen-w2-p0-0
  (tactical-scenario
   "w2-p0-0-weapon-cooldown-loops-to-seconds"
   "wave2-repro" "Terran" "Protoss" "stutter-step-and-pullback"
   "W2-P0-0: sc2-observation->runtime-obs-hash must normalize SC2 weapon_cooldown from game loops (22.4/s) to seconds for ally & enemy units"
   (lambda ()
     (define allies
       (append
        (mk-home-base-units 'Terran)
        (list (mk-unit 2000 'marine 1 80.0 80.0 #:weapon-cooldown 11.2))))
     (define enemies
       (list (mk-unit 5000 'stalker 4 85.0 80.0 #:shield 80.0 #:shield-max 80.0 #:weapon-cooldown 22.4)))
     (define s1 (mk-obs 5000 (append allies enemies) #:food-used 17 #:food-cap 46 #:food-army 1 #:food-workers 16))
     (define outs (run-pipeline-sequence 'Terran 'Protoss (list (hash 'obs s1))))
     (define out (last outs))
     (define oh (step-outcome-obs-hash out))
     (define ally-m (findf (lambda (u) (= (hash-ref u 'id 0) 2000)) (hash-ref oh 'ally-units '())))
     (define enemy-s (findf (lambda (u) (= (hash-ref u 'id 0) 5000)) (hash-ref oh 'enemy-units '())))
     (define a-cd (if ally-m (hash-ref ally-m 'weapon-cooldown -1.0) -1.0))
     (define e-cd (if enemy-s (hash-ref enemy-s 'weapon-cooldown -1.0) -1.0))
     (values out
             (list
              (mk-check "ally-weapon-cooldown-normalized-to-seconds"
                        (and (>= a-cd 0.45) (<= a-cd 0.55))
                        (format "Marine 11.2 loops -> obs weapon-cooldown=~a (expected 0.50s)" a-cd))
              (mk-check "enemy-weapon-cooldown-normalized-to-seconds"
                        (and (>= e-cd 0.95) (<= e-cd 1.05))
                        (format "Stalker 22.4 loops -> obs weapon-cooldown=~a (expected 1.00s)" e-cd)))))))

;; 1. W2-P0-1a: Melee Zealots/Zerglings under pullback (`our < 0.85 * est_enemy`)
;;    at close combat range MUST NEVER receive pure MOVE (16) / kite with 0 local attacks!
(define scen-w2-p0-1a
  (tactical-scenario
   "w2-p0-1a-melee-suicide-kite-pullback"
   "wave2-repro" "Protoss" "Terran" "stutter-step-and-pullback"
   "W2-P0-1: Melee Zealots engaged at 4.5t under pullback must attack local enemies (23), never kite/pure-MOVE (16) suicide-retreat"
   (lambda ()
     (define zealot-tags '(2001 2002 2003 2004))
     (define enemy-tags (append (for/list ([i (in-range 10)]) (+ 5000 i))
                                (for/list ([i (in-range 4)]) (+ 5100 i))))
     ;; Outnumbered away from base: 4 Zealots (8 sup) vs 10 Marines + 4 Marauders (18 sup) at (80,80)/(84.5,80)
     (define enemies
       (append
        (for/list ([i (in-range 10)])
          (mk-unit (+ 5000 i) 'marine 4 (+ 84.5 (* 0.5 (modulo i 5))) (+ 79.0 (* 0.6 (quotient i 5)))))
        (for/list ([i (in-range 4)])
          (mk-unit (+ 5100 i) 'marauder 4 86.0 (+ 78.5 (* 0.8 i))))))
     (define allies
       (append
        (mk-home-base-units 'Protoss)
        (for/list ([tag (in-list zealot-tags)] [i (in-naturals)])
          (mk-unit tag 'zealot 1 80.0 (+ 78.5 (* 0.8 i)) #:shield 50.0 #:shield-max 50.0 #:weapon-cooldown 0.0))))
     (define s1 (mk-obs 6000 (append allies enemies) #:food-used 24 #:food-cap 46 #:food-army 8 #:food-workers 16))
     (define s2 (mk-obs 6020 (append allies enemies) #:food-used 24 #:food-cap 46 #:food-army 8 #:food-workers 16))
     (define outs (run-pipeline-sequence 'Protoss 'Terran (list (hash 'obs s1) (hash 'obs s2))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define kited-cnt (bot-actions-kite-tags (step-outcome-bot-actions out) zealot-tags))
     (define local-atk-cnt (wire-count-local-attacks wcmds zealot-tags enemy-tags 85.0 79.5 16.0))
     (values out
             (list
              (mk-check "no-melee-suicide-kite-emitted"
                        (= kited-cnt 0)
                        (format "melee zealots receiving (kite ...) in bot-actions=~a/4" kited-cnt))
              (mk-check "melee-zealots-attack-local-enemies"
                        (>= local-atk-cnt 3)
                        (format "zealots attacking local enemies within 16t=~a/4, wire_targets=~a"
                                local-atk-cnt (wire-targets-for-tags wcmds zealot-tags AB-ATTACK))))))))

;; 2. W2-P0-1b: Ranged Stalkers/Marines with READY weapon (`weapon-cooldown = 0.0`)
;;    at `dist = 5.5` under pullback MUST fire (`23`), NEVER pure-MOVE (`16`)!
(define scen-w2-p0-1b
  (tactical-scenario
   "w2-p0-1b-ranged-ready-weapon-suicide-kite"
   "wave2-repro" "Protoss" "Terran" "stutter-step-and-pullback"
   "W2-P0-1: Ranged Stalkers with weapon-cooldown=0.0 at 5.5t under pullback must fire ATTACK(23), never zero-shot MOVE(16)"
   (lambda ()
     (define stalker-tags '(2011 2012 2013 2014))
     (define enemies
       (append
        (for/list ([i (in-range 10)])
          (mk-unit (+ 5000 i) 'marine 4 (+ 85.5 (* 0.5 (modulo i 5))) (+ 79.0 (* 0.6 (quotient i 5)))))
        (for/list ([i (in-range 4)])
          (mk-unit (+ 5100 i) 'marauder 4 87.0 (+ 78.5 (* 0.8 i))))))
     (define allies
       (append
        (mk-home-base-units 'Protoss)
        (for/list ([tag (in-list stalker-tags)] [i (in-naturals)])
          (mk-unit tag 'stalker 1 80.0 (+ 78.5 (* 0.8 i))
                   #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0 #:weapon-cooldown 0.0))))
     (define s1 (mk-obs 6500 (append allies enemies) #:food-used 24 #:food-cap 46 #:food-army 8 #:food-workers 16))
     (define s2 (mk-obs 6520 (append allies enemies) #:food-used 24 #:food-cap 46 #:food-army 8 #:food-workers 16))
     (define outs (run-pipeline-sequence 'Protoss 'Terran (list (hash 'obs s1) (hash 'obs s2))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define pure-move-cnt (for/sum ([t (in-list stalker-tags)]) (if (wire-pure-move-only? wcmds t) 1 0)))
     (define atk-cnt (wire-count-tags-with-ability wcmds stalker-tags AB-ATTACK))
     (values out
             (list
              (mk-check "ranged-ready-weapon-no-pure-move"
                        (= pure-move-cnt 0)
                        (format "ready-weapon stalkers pure-MOVE-only=~a/4, cmds=~a"
                                pure-move-cnt
                                (for/list ([t stalker-tags]) (cons t (wire-abilities-for-tag wcmds t)))))
              (mk-check "ranged-ready-weapon-emits-attack"
                        (>= atk-cnt 3)
                        (format "ready-weapon stalkers with ATTACK(23)=~a/4" atk-cnt)))))))

;; 3. W2-P0-1c: Natural wall & production defense at 18 tiles from TownHall
;;    (`> 14` tiles of TH, `<= 10` tiles of ally Gateway/CyberCore at natural wall)
(define scen-w2-p0-1c
  (tactical-scenario
   "w2-p0-1c-natural-wall-defense-18t-from-th"
   "wave2-repro" "Protoss" "Zerg" "home-defense"
   "W2-P0-1: Defending natural wall/production 18t from TownHall while outnumbered must engage (23), not suppress outside 14t"
   (lambda ()
     (define def-tags '(2021 2022 2023 2024))
     ;; Main Nexus at (32,32), Natural Nexus at (52,32); Natural wall Gateways at (68,32) & (68,35);
     ;; Enemies attacking natural wall at (70,33) -> dist 18.03t from Nat Nexus (> 14t!), dist 2.2t from Gateways!
     (define allies
       (append
        (mk-home-base-units 'Protoss #:with-natural? #t #:nat-x 52.0 #:nat-y 32.0)
        (list (mk-unit 1201 'gateway 1 68.0 31.0)
              (mk-unit 1202 'cybernetics-core 1 68.0 35.0)
              (mk-unit 1203 'pylon 1 65.0 33.0))
        (list (mk-unit 2021 'zealot 1 66.0 32.5 #:shield 50.0 #:shield-max 50.0 #:weapon-cooldown 0.0)
              (mk-unit 2022 'stalker 1 65.0 31.0 #:shield 80.0 #:shield-max 80.0 #:weapon-cooldown 0.0)
              (mk-unit 2023 'stalker 1 65.0 34.0 #:shield 80.0 #:shield-max 80.0 #:weapon-cooldown 0.0)
              (mk-unit 2024 'immortal 1 64.5 32.5 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0 #:weapon-cooldown 0.0))))
     (define enemies
       (append
        (for/list ([i (in-range 10)])
          (mk-unit (+ 5200 i) 'roach 4 (+ 70.0 (* 0.5 (modulo i 5))) (+ 31.5 (* 0.7 (quotient i 5)))))
        (for/list ([i (in-range 8)])
          (mk-unit (+ 5300 i) 'zergling 4 (+ 69.5 (* 0.4 (modulo i 4))) (+ 32.0 (* 0.5 (quotient i 4)))))))
     (define s1 (mk-obs 7000 (append allies enemies) #:food-used 34 #:food-cap 54 #:food-army 10 #:food-workers 24))
     (define s2 (mk-obs 7020 (append allies enemies) #:food-used 34 #:food-cap 54 #:food-army 10 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Protoss 'Zerg (list (hash 'obs s1) (hash 'obs s2))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define atk-cnt (wire-count-tags-with-ability wcmds def-tags AB-ATTACK))
     (define pure-move-cnt (for/sum ([t (in-list def-tags)]) (if (wire-pure-move-only? wcmds t) 1 0)))
     (values out
             (list
              (mk-check "natural-wall-defenders-attack"
                        (>= atk-cnt 3)
                        (format "natural-wall defenders with ATTACK(23)=~a/4 (enemy 18t from TH, 2.2t from Gateways)" atk-cnt))
              (mk-check "natural-wall-no-abandon-kite"
                        (= pure-move-cnt 0)
                        (format "natural-wall defenders pure-MOVE-only=~a/4, cmds=~a"
                                pure-move-cnt
                                (for/list ([t def-tags]) (cons t (wire-abilities-for-tag wcmds t))))))))))

;; 4. W2-P0-1d: Global `pullback-active?` must NOT override a clear local winning fight
;;    (e.g. 6 Stalkers catching 3 exposed Marines locally while enemy had 28 supply remembered)
(define scen-w2-p0-1d
  (tactical-scenario
   "w2-p0-1d-pullback-does-not-override-winning-local-fight"
   "wave2-repro" "Protoss" "Terran" "stutter-step-and-pullback"
   "W2-P0-1: Global pullback (remembered larger enemy army) must not suppress a winning 6-Stalker vs 3-Marine local fight"
   (lambda ()
     (define stalker-tags '(2031 2032 2033 2034 2035 2036))
     (define allies
       (append
        (mk-home-base-units 'Protoss)
        (for/list ([tag (in-list stalker-tags)] [i (in-naturals)])
          (mk-unit tag 'stalker 1 82.0 (+ 78.0 (* 0.8 i))
                   #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0 #:weapon-cooldown 0.0))))
     ;; Warmup step: bot sees 24-supply Terran army so est-enemy-army-supply >= 24 (> our 12 / 0.85)
     (define big-enemies
       (for/list ([i (in-range 24)])
         (mk-unit (+ 5400 i) 'marine 4 (+ 125.0 (* 0.5 (modulo i 6))) (+ 125.0 (* 0.5 (quotient i 6))))))
     ;; Target step (40 frames later): 6 Stalkers (12 sup) vs 5 Marines + 2 Marauders (9 sup) — winning local fight (1.2 < pred-ratio < 2.5)!
     (define small-enemy-tags '(5501 5502 5503 5504 5505 5506 5507))
     (define small-enemies
       (list (mk-unit 5501 'marine 4 87.0 78.5)
             (mk-unit 5502 'marine 4 87.5 79.3)
             (mk-unit 5503 'marine 4 87.0 80.1)
             (mk-unit 5504 'marine 4 87.5 80.9)
             (mk-unit 5505 'marine 4 87.0 81.7)
             (mk-unit 5506 'marauder 4 88.0 79.5)
             (mk-unit 5507 'marauder 4 88.0 80.7)))
     (define s1 (mk-obs 8000 (append allies big-enemies) #:food-used 28 #:food-cap 54 #:food-army 12 #:food-workers 16))
     (define s2 (mk-obs 8040 (append allies small-enemies) #:food-used 28 #:food-cap 54 #:food-army 12 #:food-workers 16))
     (define outs (run-pipeline-sequence 'Protoss 'Terran (list (hash 'obs s1) (hash 'obs s2))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define atk-cnt (wire-count-local-attacks wcmds stalker-tags small-enemy-tags 87.5 80.0 16.0))
     (values out
             (list
              (mk-check "winning-local-pickoff-attacks-under-global-pullback"
                        (>= atk-cnt 4)
                        (format "6 Stalkers vs 5 Marines+2 Marauders under global pullback: local ATTACK(23)=~a/6, cmds=~a"
                                atk-cnt
                                (for/list ([t stalker-tags]) (cons t (wire-abilities-for-tag wcmds t))))))))))

;; 5. W2-P0-2a: Endgame building-hunt blocked by leftover CreepTumorQueen / CreepTumorBurrowed
;;    and stray Overlords at cleared enemy main (`#013` 30:00 tie with 102 army vs 1 Hatchery!)
(define scen-w2-p0-2a
  (tactical-scenario
   "w2-p0-2a-endgame-hunt-ignores-creep-tumors-and-overlords"
   "wave2-repro" "Terran" "Zerg" "endgame-hunt"
   "W2-P0-2: Dominant 100-supply Terran army at enemy main with only CreepTumors + Overlords must sweep other expansions"
   (lambda ()
     (define marine-tags (for/list ([i (in-range 30)]) (+ 2100 i)))
     (define marauder-tags (for/list ([i (in-range 15)]) (+ 2150 i)))
     (define army-tags (append marine-tags marauder-tags))
     (define allies
       (append
        (mk-home-base-units 'Terran #:with-natural? #t)
        (for/list ([t (in-list marine-tags)] [i (in-naturals)])
          (mk-unit t 'marine 1 (+ 156.0 (* 0.5 (modulo i 10))) (+ 156.0 (* 0.5 (quotient i 10)))))
        (for/list ([t (in-list marauder-tags)] [i (in-naturals)])
          (mk-unit t 'marauder 1 (+ 157.0 (* 0.6 (modulo i 5))) (+ 159.0 (* 0.6 (quotient i 5)))))))
     ;; Only leftover burrowed CreepTumors + harmless Overlords near enemy main (160,160) & natural (140,160)
     (define noise-enemies
       (list (mk-unit 6001 'creep-tumor-burrowed 4 159.0 159.0 #:burrowed? #t)
             (mk-unit 6002 'creep-tumor-queen 4 142.0 158.0 #:burrowed? #t)
             (mk-unit 6003 'overlord 4 152.0 165.0 #:flying? #t)
             (mk-unit 6004 'overlord 4 138.0 162.0 #:flying? #t)))
     (define exp-cands (list (hash 'x 88.0 'y 138.0) (hash 'x 160.0 'y 32.0) (hash 'x 32.0 'y 160.0)))
     (define s1 (mk-obs 18000 (append allies noise-enemies) #:food-used 110 #:food-cap 150 #:food-army 60 #:food-workers 24))
     (define s2 (mk-obs 18050 (append allies noise-enemies) #:food-used 110 #:food-cap 150 #:food-army 60 #:food-workers 24))
     (define overlay (hash 'expansion-candidates exp-cands))
     (define outs (run-pipeline-sequence 'Terran 'Zerg
                                         (list (hash 'obs s1 'overlay overlay)
                                               (hash 'obs s2 'overlay overlay))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     ;; Check if any army units are sent to sweep away from (160,160) toward an unvisited expansion (e.g. (88,138) or corners)
     (define sweep-cmds
       (for/list ([c (in-list wcmds)]
                  #:when (and (sc2-raw-unit-command? c)
                              (memv (sc2-raw-unit-command-ability-id c) (list AB-ATTACK AB-MOVE))
                              (sc2-raw-unit-command-target-pos c)
                              (let* ([p (sc2-raw-unit-command-target-pos c)]
                                     [px (sc2-point2d-x p)]
                                     [py (sc2-point2d-y p)])
                                (> (dist2d-xy px py 160.0 160.0) 25.0))))
         c))
     (values out
             (list
              (mk-check "endgame-sweep-emits-expansion-search-despite-tumors-and-overlords"
                        (pair? sweep-cmds)
                        (format "sweep cmds away from (160,160)=~a (expected >=1 toward hidden expansions like (88,138)); bot_actions_sample=~a"
                                (length sweep-cmds)
                                (take (step-outcome-bot-actions out) (min 6 (length (step-outcome-bot-actions out)))))))))))

;; 6. W2-P0-2b: ZvZ CreepTumor must NOT trigger Mirror-Mind `requires-detection? = #t`
(define scen-w2-p0-2b
  (tactical-scenario
   "w2-p0-2b-zvz-creep-tumor-no-detection-panic"
   "wave2-repro" "Zerg" "Zerg" "detection-and-anti-air"
   "W2-P0-2: Enemy CreepTumorBurrowed/CreepTumorQueen (in enemy-buildings OR enemy-units) must NOT trigger requires-detection?=#t"
   (lambda ()
     (define allies
       (append
        (mk-home-base-units 'Zerg #:with-natural? #t)
        (list (mk-unit 1210 'spawning-pool 1 36.0 34.0)
              (mk-unit 2201 'zergling 1 70.0 70.0)
              (mk-unit 2202 'roach 1 71.0 70.0))))
     (define enemies
       (list (mk-unit 6101 'creep-tumor-burrowed 4 85.0 85.0 #:burrowed? #t)
             (mk-unit 6102 'creep-tumor-queen 4 88.0 88.0 #:burrowed? #t)
             (mk-unit 6103 'zergling 4 90.0 90.0)
             (mk-unit 6104 'roach 4 91.0 90.0)))
     (define s1 (mk-obs 5000 (append allies enemies) #:food-used 36 #:food-cap 44 #:food-army 12 #:food-workers 24))
     ;; Also inject creep-tumor-burrowed into enemy-units (mirroring live ZvZ obs records where burrowed tumors enter unit pass)
     (define tumor-overlay
       (hash 'enemy-units (list (hash 'id 6101 'type 'creep-tumor-burrowed 'x 85.0 'y 85.0 'hp 50 'burrowed #t)
                                (hash 'id 6102 'type 'creep-tumor-queen 'x 88.0 'y 88.0 'hp 50 'burrowed #t)
                                (hash 'id 6103 'type 'zergling 'x 90.0 'y 90.0 'hp 35)
                                (hash 'id 6104 'type 'roach 'x 91.0 'y 90.0 'hp 145))))
     (define outs (run-pipeline-sequence 'Zerg 'Zerg (list (hash 'obs s1 'overlay tumor-overlay))))
     (define out (last outs))
     (define tech (step-outcome-mm-tech-obs out))
     (define req-det? (and tech (enemy-tech-observation-requires-detection? tech)))
     (values out
             (list
              (mk-check "creep-tumor-does-not-trigger-requires-detection"
                        (not req-det?)
                        (format "mirror-mind requires-detection?=~a (expected #f for ZvZ creep tumors only)" req-det?)))))))

;; 6b. W2-P0-2c: Maxed Zerg (190/200 supply) must NOT perpetually kite 40+ Zerglings away from a Sieged Tank/PF
(define scen-w2-p0-2c
  (tactical-scenario
   "w2-p0-2c-maxed-zerg-breaks-pf-siege-stalemate"
   "wave2-repro" "Zerg" "Terran" "endgame-hunt"
   "W2-P0-2: Maxed Zerg (190/200 supply) with overwhelming local army vs 1 Sieged Tank + PF must break through instead of perpetual kite stalemate"
   (lambda ()
     (define ling-tags (for/list ([i (in-range 36)]) (+ 2260 i)))
     (define roach-tags (for/list ([i (in-range 16)]) (+ 2296 i)))
     (define allies
       (append
        (mk-home-base-units 'Zerg #:with-natural? #t)
        (for/list ([t (in-list ling-tags)] [i (in-naturals)])
          (mk-unit t 'zergling 1 (+ 133.0 (* 0.4 (modulo i 9))) (+ 153.0 (* 0.4 (quotient i 9)))))
        (for/list ([t (in-list roach-tags)] [i (in-naturals)])
          (mk-unit t 'roach 1 (+ 132.0 (* 0.6 (modulo i 8))) (+ 151.0 (* 0.6 (quotient i 8)))))))
     (define enemy-tags '(6711 6712))
     (define enemies
       (list (mk-unit 6711 'planetary-fortress 4 140.0 160.0)
             (mk-unit 6712 'siege-tank-sieged 4 141.0 161.0)))
     (define s1 (mk-obs 20000 (append allies enemies) #:food-used 192 #:food-cap 200 #:food-army 120 #:food-workers 72))
     (define s2 (mk-obs 20020 (append allies enemies) #:food-used 192 #:food-cap 200 #:food-army 120 #:food-workers 72))
     (define outs (run-pipeline-sequence 'Zerg 'Terran (list (hash 'obs s1) (hash 'obs s2))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define kited-lings (bot-actions-kite-tags (step-outcome-bot-actions out) ling-tags))
     (define atk-lings (wire-count-local-attacks wcmds ling-tags enemy-tags 140.0 160.0 18.0))
     (values out
             (list
              (mk-check "maxed-zerg-does-not-perpetually-kite-lings-at-192-supply"
                        (and (< kited-lings 10) (>= atk-lings 18))
                        (format "maxed 192-supply zerglings: kited=~a/36, local ATTACK=~a/36" kited-lings atk-lings)))))))

;; 7. W2-P0-3: Zerg air-dominated threat (Tempests + Oracles) with 150M / 75G and 0 Lair
;;    MUST NOT spend 25G on ground Roach bypassing Lair gas escrow!
(define scen-w2-p0-3
  (tactical-scenario
   "w2-p0-3-zerg-air-threat-roach-respects-lair-escrow"
   "wave2-repro" "Zerg" "Protoss" "detection-and-anti-air"
   "W2-P0-3: Facing Tempests+Oracles with 75G and no Lair, Zerg must NOT train ground Roaches draining gas below 100G for Lair"
   (lambda ()
     (define allies
       (append
        (mk-home-base-units 'Zerg #:with-natural? #t)
        (list (mk-unit 1220 'spawning-pool 1 36.0 34.0)
              (mk-unit 1221 'roach-warren 1 38.0 34.0)
              (mk-unit 1222 'extractor 1 28.0 26.0 #:assigned 3 #:ideal 3)
              (mk-unit 1223 'larva 1 33.0 31.0)
              (mk-unit 1224 'larva 1 34.0 31.0)
              (mk-unit 1225 'larva 1 35.0 31.0)
              (mk-unit 1226 'queen 1 35.0 32.0 #:energy 50.0))))
     ;; Pure air threat attacking near base: 4 Tempests + 2 Oracles (0 ground threats!)
     (define enemies
       (list (mk-unit 6201 'tempest 4 58.0 38.0 #:flying? #t)
             (mk-unit 6202 'tempest 4 59.0 39.0 #:flying? #t)
             (mk-unit 6203 'tempest 4 60.0 38.0 #:flying? #t)
             (mk-unit 6204 'tempest 4 61.0 39.0 #:flying? #t)
             (mk-unit 6205 'oracle 4 57.0 36.0 #:flying? #t)
             (mk-unit 6206 'oracle 4 58.0 35.0 #:flying? #t)))
     ;; 225M / 75G — enough for a ground Roach (75M/25G), saving 25G away from Lair (150M/100G)!
     (define s1 (mk-obs 7500 (append allies enemies)
                        #:minerals 225 #:vespene 75 #:food-used 28 #:food-cap 52 #:food-army 2 #:food-workers 24 #:larva-count 3))
     (define s2 (mk-obs 7520 (append allies enemies)
                        #:minerals 225 #:vespene 75 #:food-used 28 #:food-cap 52 #:food-army 2 #:food-workers 24 #:larva-count 3))
     (define outs (run-pipeline-sequence 'Zerg 'Protoss (list (hash 'obs s1) (hash 'obs s2))))
     (define out (last outs))
     (define trained-roach? (bot-actions-has-train? (step-outcome-bot-actions out) 'roach))
     (define tech (step-outcome-mm-tech-obs out))
     (define req-aa? (and tech (enemy-tech-observation-requires-anti-air? tech)))
     (values out
             (list
              (mk-check "air-threat-detected-by-mirror-mind"
                        req-aa?
                        (format "requires-anti-air?=~a" req-aa?))
              (mk-check "no-ground-roach-draining-lair-gas-escrow"
                        (not trained-roach?)
                        (format "trained-roach?=~a with 225M/75G vs 4 Tempests + 2 Oracles (actions=~a)"
                                trained-roach?
                                (filter (lambda (a) (and (pair? a) (memq (car a) '(train morph build))))
                                        (step-outcome-bot-actions out)))))))))

;; 8. W2-P1-2: Zerg fresh Spore Crawler morph (`build-progress = 0.12`, starts near 10% HP!)
;;    MUST NOT self-cancel at `prog = 0.12` (causes `#025` 28x self-cancel loop!)
(define scen-w2-p1-2
  (tactical-scenario
   "w2-p1-2-zerg-spore-fresh-morph-no-self-cancel"
   "wave2-repro" "Zerg" "Zerg" "static-defense-discipline"
   "W2-P1-2: Freshly morphing SporeCrawler at build-progress=0.12 (~15% HP) near combat must NOT self-cancel into an infinite rebuild loop"
   (lambda ()
     (define spore-tag 1230)
     (define allies
       (append
        (mk-home-base-units 'Zerg #:with-natural? #t)
        (list (mk-unit 1229 'spawning-pool 1 36.0 34.0)
              ;; Freshly started SporeCrawler (max 400 HP, 12% build-progress => took 1 swipe down to 20 HP = 5%!)
              (mk-unit spore-tag 'spore-crawler 1 51.0 34.0 #:hp 20.0 #:hp-max 400.0 #:build-progress 0.12)
              (mk-unit 2231 'queen 1 50.0 33.0 #:energy 50.0))))
     (define enemies
       (list (mk-unit 6231 'zergling 4 56.0 35.0)
             (mk-unit 6232 'zergling 4 56.5 35.5)))
     (define s1 (mk-obs 6200 (append allies enemies) #:minerals 300 #:vespene 100 #:food-used 28 #:food-cap 44 #:food-army 2 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Zerg 'Zerg (list (hash 'obs s1))))
     (define out (last outs))
     (define canceled-bot? (bot-actions-has-cancel? (step-outcome-bot-actions out) spore-tag))
     (define canceled-wire? (wire-has-ability? (step-outcome-wire-cmds out) (list spore-tag) AB-CANCEL))
     (values out
             (list
              (mk-check "fresh-spore-not-self-canceled"
                        (and (not canceled-bot?) (not canceled-wire?))
                        (format "fresh spore(prog=0.12,hp=20/400) canceled-bot?=~a canceled-wire?=~a"
                                canceled-bot? canceled-wire?)))))))

;; 9. W2-P1-1b: Protoss Observer cap without cloak/burrow (`#006` built 8 Observers = 600G!)
;;    With 1 existing Observer, >=40 army supply, NO cloak/burrow enemy -> MUST NOT train 2nd Observer!
(define scen-w2-p1-1b
  (tactical-scenario
   "w2-p1-1b-protoss-observer-cap-without-cloak"
   "wave2-repro" "Protoss" "Terran" "detection-and-anti-air"
   "W2-P1-1b: Protoss at >=40 army supply with 1 Observer and NO cloaked/burrowed enemy must cap Observers at 1"
   (lambda ()
     (define allies
       (append
        (mk-home-base-units 'Protoss #:with-natural? #t)
        (list (mk-unit 1240 'gateway 1 38.0 34.0)
              (mk-unit 1241 'cybernetics-core 1 40.0 34.0)
              (mk-unit 1242 'robotics-facility 1 42.0 34.0)
              (mk-unit 1243 'pylon 1 40.0 32.0)
              (mk-unit 2240 'observer 1 70.0 70.0 #:flying? #t))
        (for/list ([i (in-range 14)])
          (mk-unit (+ 2250 i) 'stalker 1 (+ 68.0 (* 0.5 (modulo i 7))) (+ 68.0 (* 0.5 (quotient i 7)))))
        (for/list ([i (in-range 4)])
          (mk-unit (+ 2270 i) 'immortal 1 (+ 66.0 (* 0.8 i)) 68.0))))
     ;; Only uncloaked Marines + Vikings (no Banshee/Ghost/WidowMine)
     (define enemies
       (list (mk-unit 6250 'marine 4 95.0 95.0)
             (mk-unit 6251 'viking-fighter 4 96.0 95.0 #:flying? #t)))
     (define s1 (mk-obs 10000 (append allies enemies)
                        #:minerals 400 #:vespene 250 #:food-used 76 #:food-cap 110 #:food-army 44 #:food-workers 32))
     (define s2 (mk-obs 10020 (append allies enemies)
                        #:minerals 400 #:vespene 250 #:food-used 76 #:food-cap 110 #:food-army 44 #:food-workers 32))
     (define outs (run-pipeline-sequence 'Protoss 'Terran (list (hash 'obs s1) (hash 'obs s2))))
     (define out (last outs))
     (define trained-obs? (bot-actions-has-train? (step-outcome-bot-actions out) 'observer))
     (values out
             (list
              (mk-check "no-redundant-second-observer-without-cloak"
                        (not trained-obs?)
                        (format "trained-observer?=~a when already have 1 observer and no cloak/burrow (actions=~a)"
                                trained-obs?
                                (filter (lambda (a) (and (pair? a) (eq? (car a) 'train)))
                                        (step-outcome-bot-actions out)))))))))

;; =============================================================================
;; TIER 2: FULL CORE TACTICS COVERAGE ACROSS P / T / Z (13 Scenarios)
;; =============================================================================

;; 10. Ranged stutter-step: ready weapon fires (23) vs on-cooldown kites (16)
(define scen-core-stutter
  (tactical-scenario
   "core-ranged-stutter-step-ready-vs-cooldown"
   "core" "Terran" "Protoss" "stutter-step-and-pullback"
   "Core: Marines facing melee Zealots at 4.2t fire ATTACK(23) when weapon-cooldown=0.0 and kite MOVE(16) when weapon-cooldown=0.55 under suppression"
   (lambda ()
     (define m-ready '(2301 2302 2303))
     (define m-cd    '(2304 2305 2306))
     (define enemies
       (for/list ([i (in-range 10)])
         (mk-unit (+ 6300 i) 'zealot 4 (+ 84.2 (* 0.5 (modulo i 5))) (+ 79.0 (* 0.6 (quotient i 5)))
                  #:shield 50.0 #:shield-max 50.0)))
     (define allies
       (append
        (mk-home-base-units 'Terran)
        (for/list ([t (in-list m-ready)] [i (in-naturals)])
          (mk-unit t 'marine 1 80.0 (+ 78.5 (* 0.6 i)) #:hp 45.0 #:hp-max 45.0 #:weapon-cooldown 0.0))
        (for/list ([t (in-list m-cd)] [i (in-naturals)])
          ;; 8.0 SC2 game loops = 0.357s (past Marine 0.08s swing window, still > 0.15s kite threshold!)
          (mk-unit t 'marine 1 80.0 (+ 80.5 (* 0.6 i)) #:hp 45.0 #:hp-max 45.0 #:weapon-cooldown 8.0))))
     (define s1 (mk-obs 5500 (append allies enemies) #:food-used 22 #:food-cap 46 #:food-army 6 #:food-workers 16))
     (define s2 (mk-obs 5520 (append allies enemies) #:food-used 22 #:food-cap 46 #:food-army 6 #:food-workers 16))
     (define outs (run-pipeline-sequence 'Terran 'Protoss (list (hash 'obs s1) (hash 'obs s2))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define enemy-tags (for/list ([i (in-range 10)]) (+ 6300 i)))
     (define ready-atk (wire-count-local-attacks wcmds m-ready enemy-tags 84.5 79.5 16.0))
     (define cd-move   (wire-count-tags-with-ability wcmds m-cd AB-MOVE))
     (values out
             (list
              (mk-check "ready-weapon-marines-fire"
                        (>= ready-atk 2)
                        (format "weapon-cd=0.0 marines local ATTACK(23)=~a/3" ready-atk))
              (mk-check "cooldown-marines-kite-back"
                        (>= cd-move 2)
                        (format "weapon-cd=8.0 loops (0.36s) marines MOVE(16)=~a/3" cd-move)))))))

;; 11. Melee surround & engage (favorable Zerglings vs Marines in open field)
(define scen-core-melee
  (tactical-scenario
   "core-melee-surround-and-engage"
   "core" "Zerg" "Terran" "melee-engage"
   "Core: 20 Speedlings engaging 6 Marines in open field commit directly via ATTACK(23) with zero backward MOVE(16)"
   (lambda ()
     (define ling-tags (for/list ([i (in-range 20)]) (+ 2320 i)))
     (define allies
       (append
        (mk-home-base-units 'Zerg)
        (for/list ([t (in-list ling-tags)] [i (in-naturals)])
          (mk-unit t 'zergling 1 (+ 80.0 (* 0.4 (modulo i 5))) (+ 78.0 (* 0.4 (quotient i 5)))))))
     (define enemies
       (for/list ([i (in-range 6)])
         (mk-unit (+ 6320 i) 'marine 4 (+ 86.0 (* 0.4 (modulo i 3))) (+ 79.0 (* 0.5 (quotient i 3))))))
     (define s1 (mk-obs 4500 (append allies enemies) #:food-used 26 #:food-cap 44 #:food-army 10 #:food-workers 16
                        #:upgrades '(zergling-movementspeed)))
     (define s2 (mk-obs 4520 (append allies enemies) #:food-used 26 #:food-cap 44 #:food-army 10 #:food-workers 16
                        #:upgrades '(zergling-movementspeed)))
     (define outs (run-pipeline-sequence 'Zerg 'Terran (list (hash 'obs s1) (hash 'obs s2))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define atk-cnt (wire-count-tags-with-ability wcmds ling-tags AB-ATTACK))
     (define pure-move-cnt (for/sum ([t (in-list ling-tags)]) (if (wire-pure-move-only? wcmds t) 1 0)))
     (values out
             (list
              (mk-check "melee-lings-commit-attack"
                        (>= atk-cnt 15)
                        (format "lings ATTACK(23)=~a/20" atk-cnt))
              (mk-check "melee-lings-no-pure-move-retreat"
                        (= pure-move-cnt 0)
                        (format "lings pure-MOVE=~a/20" pure-move-cnt)))))))

;; 12. Siege Tank siege/unsiege range discipline
(define scen-core-siege-tank
  (tactical-scenario
   "core-siege-tank-siege-and-unsiege-discipline"
   "core" "Terran" "Zerg" "siege-tank-mode"
   "Core: Unsieged Tank at 10.5t sieges (388); Sieged Tank with nearest enemy at 22t unsieges (390)"
   (lambda ()
     (define tank-unsieged 2351)
     (define tank-sieged-far 2352)
     (define allies
       (append
        (mk-home-base-units 'Terran)
        (list (mk-unit tank-unsieged 'siege-tank 1 80.0 80.0)
              (mk-unit tank-sieged-far 'siege-tank-sieged 1 40.0 40.0)
              (mk-unit 2353 'marine 1 82.0 80.0)
              (mk-unit 2354 'marine 1 82.0 81.0)
              (mk-unit 2355 'marine 1 82.0 79.0)
              (mk-unit 2356 'marine 1 81.5 80.5))))
     (define enemies
       (list (mk-unit 6351 'roach 4 90.5 80.0)
             (mk-unit 6352 'roach 4 91.0 81.0)))
     (define s1 (mk-obs 7200 (append allies enemies) #:food-used 28 #:food-cap 54 #:food-army 12 #:food-workers 16))
     (define outs (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define sieged? (wire-has-ability? wcmds (list tank-unsieged) AB-SIEGE-MODE))
     (define unsieged? (wire-has-ability? wcmds (list tank-sieged-far) AB-UNSIEGE-MODE))
     (values out
             (list
              (mk-check "unsieged-tank-at-10.5t-sieges"
                        sieged?
                        (format "tank-2351 wire abs=~a (expected ~a SIEGE)" (wire-abilities-for-tag wcmds tank-unsieged) AB-SIEGE-MODE))
              (mk-check "sieged-tank-at-65t-unsieges"
                        unsieged?
                        (format "tank-2352 wire abs=~a (expected ~a UNSIEGE)" (wire-abilities-for-tag wcmds tank-sieged-far) AB-UNSIEGE-MODE)))))))

;; 13. Focus-fire low-HP / high-DPS priority
(define scen-core-focus-fire
  (tactical-scenario
   "core-focus-fire-low-hp-high-dps-priority"
   "core" "Protoss" "Terran" "focus-fire"
   "Core: 6 Stalkers facing a 20-HP Siege Tank vs a full-HP Marauder at equal distance prioritize finishing the low-HP high-DPS Tank"
   (lambda ()
     (define stalker-tags '(2361 2362 2363 2364 2365 2366))
     (define low-tank-tag 6361)
     (define full-marauder-tag 6362)
     (define allies
       (append
        (mk-home-base-units 'Protoss)
        (for/list ([t (in-list stalker-tags)] [i (in-naturals)])
          (mk-unit t 'stalker 1 80.0 (+ 78.5 (* 0.6 i)) #:shield 80.0 #:shield-max 80.0 #:weapon-cooldown 0.0))))
     (define enemies
       (list (mk-unit full-marauder-tag 'marauder 4 84.8 80.0 #:hp 125.0 #:hp-max 125.0)
             (mk-unit low-tank-tag 'siege-tank-sieged 4 85.0 80.2 #:hp 20.0 #:hp-max 175.0)))
     (define s1 (mk-obs 7800 (append allies enemies) #:food-used 28 #:food-cap 54 #:food-army 12 #:food-workers 16))
     (define outs (run-pipeline-sequence 'Protoss 'Terran (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define tgts (wire-targets-for-tags wcmds stalker-tags AB-ATTACK))
     (define hit-tank?
       (for/or ([entry (in-list tgts)])
         (= (second entry) low-tank-tag)))
     (values out
             (list
              (mk-check "stalkers-focus-low-hp-siege-tank"
                        hit-tank?
                        (format "attack targets=~a (expected target ~a low-HP Tank over ~a full Marauder)"
                                tgts low-tank-tag full-marauder-tag)))))))

;; 14. Ravager Corrosive Bile on Sieged Tank
(define scen-core-ravager-bile
  (tactical-scenario
   "core-ravager-corrosive-bile-on-sieged-tank"
   "core" "Zerg" "Terran" "spellcasters"
   "Core: Zerg Ravagers within 7.5t of enemy Sieged Tanks cast Corrosive Bile (2338)"
   (lambda ()
     (define rav-tags '(2371 2372 2373))
     (define allies
       (append
        (mk-home-base-units 'Zerg)
        (for/list ([t (in-list rav-tags)] [i (in-naturals)])
          (mk-unit t 'ravager 1 80.0 (+ 79.0 (* 0.8 i))))
        (for/list ([i (in-range 6)])
          (mk-unit (+ 2375 i) 'roach 1 79.0 (+ 78.0 (* 0.6 i))))))
     (define enemies
       (list (mk-unit 6371 'siege-tank-sieged 4 87.0 80.0)
             (mk-unit 6372 'siege-tank-sieged 4 87.5 81.5)))
     (define s1 (mk-obs 7600 (append allies enemies) #:food-used 40 #:food-cap 66 #:food-army 24 #:food-workers 16))
     (define outs (run-pipeline-sequence 'Zerg 'Terran (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define cast-bile? (wire-has-ability? wcmds rav-tags AB-CORROSIVE-BILE))
     (values out
             (list
              (mk-check "ravager-casts-corrosive-bile-2338"
                        cast-bile?
                        (format "ravager wire cmds=~a (expected ~a CORROSIVE-BILE)"
                                (for/list ([t rav-tags]) (cons t (wire-abilities-for-tag wcmds t)))
                                AB-CORROSIVE-BILE)))))))

;; 15. Protoss High Templar Psi Storm + Low-Energy Rear Leash
(define scen-core-ht-storm
  (tactical-scenario
   "core-protoss-ht-psi-storm-and-rear-leash"
   "core" "Protoss" "Terran" "spellcasters"
   "Core: High Templar with 100en + psi-storm casts Storm (1036) on clumped Marines; dry HT (20en) stays on rear leash"
   (lambda ()
     (define ht-full 2381)
     (define ht-dry  2382)
     (define allies
       (append
        (mk-home-base-units 'Protoss)
        (list (mk-unit ht-full 'high-templar 1 80.0 80.0 #:energy 100.0 #:shield 40.0 #:shield-max 40.0)
              (mk-unit ht-dry  'high-templar 1 83.0 80.0 #:energy 20.0  #:shield 40.0 #:shield-max 40.0))
        (for/list ([i (in-range 6)])
          (mk-unit (+ 2385 i) 'zealot 1 81.0 (+ 78.0 (* 0.6 i)) #:shield 50.0 #:shield-max 50.0))
        (for/list ([i (in-range 4)])
          (mk-unit (+ 2392 i) 'stalker 1 79.0 (+ 78.5 (* 0.7 i)) #:shield 80.0 #:shield-max 80.0))))
     (define enemies
       (for/list ([i (in-range 10)])
         (mk-unit (+ 6380 i) 'marine 4 (+ 86.5 (* 0.4 (modulo i 5))) (+ 79.2 (* 0.4 (quotient i 5))))))
     (define s1 (mk-obs 9200 (append allies enemies)
                        #:food-used 40 #:food-cap 66 #:food-army 24 #:food-workers 16
                        #:upgrades '(psi-storm)))
     (define outs (run-pipeline-sequence 'Protoss 'Terran (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define cast-storm? (wire-has-ability? wcmds (list ht-full) AB-PSI-STORM))
     (define dry-no-suicide-atk? (not (wire-has-ability? wcmds (list ht-dry) AB-ATTACK)))
     (values out
             (list
              (mk-check "ht-casts-psi-storm-1036"
                        cast-storm?
                        (format "ht-2381 wire abs=~a (expected ~a PSI-STORM)" (wire-abilities-for-tag wcmds ht-full) AB-PSI-STORM))
              (mk-check "dry-ht-does-not-suicide-attack"
                        dry-no-suicide-atk?
                        (format "dry ht-2382 wire abs=~a (must not attack-dive)" (wire-abilities-for-tag wcmds ht-dry))))))))

;; 16. Terran Ghost EMP vs High Templar + Archons
(define scen-core-ghost-emp
  (tactical-scenario
   "core-terran-ghost-emp-vs-protoss-psionic"
   "core" "Terran" "Protoss" "spellcasters"
   "Core: Terran Ghosts with 100en cast EMP (1628) onto clumped High Templars + Archons"
   (lambda ()
     (define ghost-tags '(2401 2402))
     (define allies
       (append
        (mk-home-base-units 'Terran)
        (for/list ([t (in-list ghost-tags)] [i (in-naturals)])
          (mk-unit t 'ghost 1 80.0 (+ 79.5 (* 1.0 i)) #:energy 100.0))
        (for/list ([i (in-range 8)])
          (mk-unit (+ 2405 i) 'marine 1 78.5 (+ 78.0 (* 0.5 i))))))
     (define enemies
       (list (mk-unit 6401 'high-templar 4 88.0 79.5 #:energy 125.0 #:shield 40.0 #:shield-max 40.0)
             (mk-unit 6402 'high-templar 4 88.5 80.5 #:energy 125.0 #:shield 40.0 #:shield-max 40.0)
             (mk-unit 6403 'archon 4 88.2 80.0 #:hp 10.0 #:hp-max 10.0 #:shield 350.0 #:shield-max 350.0)
             (mk-unit 6404 'archon 4 89.0 80.0 #:hp 10.0 #:hp-max 10.0 #:shield 350.0 #:shield-max 350.0)))
     (define s1 (mk-obs 10500 (append allies enemies) #:food-used 36 #:food-cap 66 #:food-army 20 #:food-workers 16))
     (define outs (run-pipeline-sequence 'Terran 'Protoss (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define cast-emp? (wire-has-ability? wcmds ghost-tags AB-EMP))
     (values out
             (list
              (mk-check "ghost-casts-emp-1628"
                        cast-emp?
                        (format "ghosts wire abs=~a (expected ~a EMP)"
                                (for/list ([t ghost-tags]) (cons t (wire-abilities-for-tag wcmds t)))
                                AB-EMP)))))))

;; 17. Terran Raven Interference Matrix / Anti-Armor Missile vs Colossus + Tanks
(define scen-core-raven
  (tactical-scenario
   "core-terran-raven-interference-matrix-or-aam"
   "core" "Terran" "Protoss" "spellcasters"
   "Core: Terran Raven with 100en casts Interference Matrix (3747) or Anti-Armor Missile (3753) on enemy Colossus/mech"
   (lambda ()
     (define raven-tag 2421)
     (define allies
       (append
        (mk-home-base-units 'Terran)
        (list (mk-unit raven-tag 'raven 1 80.0 80.0 #:energy 100.0 #:flying? #t))
        (for/list ([i (in-range 10)])
          (mk-unit (+ 2425 i) 'marine 1 79.0 (+ 77.5 (* 0.5 i))))))
     (define enemies
       (list (mk-unit 6421 'colossus 4 87.0 80.0 #:hp 200.0 #:hp-max 200.0 #:shield 150.0 #:shield-max 150.0)
             (mk-unit 6422 'colossus 4 87.5 81.0 #:hp 200.0 #:hp-max 200.0 #:shield 150.0 #:shield-max 150.0)
             (mk-unit 6423 'stalker 4 86.5 79.5 #:shield 80.0 #:shield-max 80.0)
             (mk-unit 6424 'stalker 4 86.5 80.5 #:shield 80.0 #:shield-max 80.0)))
     (define s1 (mk-obs 9500 (append allies enemies) #:upgrades '(interference-matrix) #:food-used 34 #:food-cap 66 #:food-army 18 #:food-workers 16))
     (define outs (run-pipeline-sequence 'Terran 'Protoss (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define cast-raven? (wire-any-ability? wcmds (list raven-tag) (list AB-INTERFERENCE-MATRIX AB-ANTI-ARMOR-MISSILE)))
     (values out
             (list
              (mk-check "raven-casts-imatrix-or-aam"
                        cast-raven?
                        (format "raven-2421 wire abs=~a (expected ~a iMatrix or ~a AAM)"
                                (wire-abilities-for-tag wcmds raven-tag)
                                AB-INTERFERENCE-MATRIX AB-ANTI-ARMOR-MISSILE)))))))

;; 18. Medivac healing injured Bio + Observer preservation (no dive)
(define scen-core-support-preservation
  (tactical-scenario
   "core-medivac-heal-and-support-preservation"
   "core" "Terran" "Zerg" "spellcasters"
   "Core: Medivac near injured Marines heals or stays behind bio without attack-diving into enemy anti-air"
   (lambda ()
     (define med-tag 2441)
     (define allies
       (append
        (mk-home-base-units 'Terran)
        (list (mk-unit med-tag 'medivac 1 79.0 80.0 #:energy 100.0 #:flying? #t)
              (mk-unit 2442 'marine 1 80.5 80.0 #:hp 18.0 #:hp-max 45.0)
              (mk-unit 2443 'marine 1 80.5 81.0 #:hp 20.0 #:hp-max 45.0)
              (mk-unit 2444 'marine 1 81.0 79.5 #:hp 45.0 #:hp-max 45.0)
              (mk-unit 2445 'marauder 1 81.5 80.0 #:hp 70.0 #:hp-max 125.0))))
     (define enemies
       (list (mk-unit 6441 'hydralisk 4 86.5 80.0)
             (mk-unit 6442 'hydralisk 4 87.0 81.0)))
     (define s1 (mk-obs 8400 (append allies enemies) #:food-used 28 #:food-cap 54 #:food-army 12 #:food-workers 16))
     (define outs (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define med-abs (wire-abilities-for-tag wcmds med-tag))
     (define no-attack? (not (memv AB-ATTACK med-abs)))
     (define heals-or-supports?
       (or (memv AB-HEAL med-abs)
           (memv AB-MEDIVAC-LOAD med-abs)
           (memv AB-MOVE med-abs)
           (null? med-abs)))
     (values out
             (list
              (mk-check "medivac-never-attack-dives"
                        no-attack?
                        (format "medivac-2441 wire abs=~a" med-abs))
              (mk-check "medivac-heals-or-positions-safely"
                        heals-or-supports?
                        (format "medivac-2441 wire abs=~a" med-abs)))))))

;; 19. Choke / Ramp Defense (Protoss holding natural choke near Nexus vs Ling flood)
(define scen-core-choke-defense
  (tactical-scenario
   "core-choke-ramp-defense-protoss-hold"
   "core" "Protoss" "Zerg" "choke-and-ramp-defense"
   "Core: Protoss Zealot + Stalkers defending natural choke 10t from Natural Nexus vs Zergling flood actively engage"
   (lambda ()
     (define def-tags '(2461 2462 2463 2464))
     (define allies
       (append
        (mk-home-base-units 'Protoss #:with-natural? #t #:nat-x 52.0 #:nat-y 32.0)
        (list (mk-unit 1260 'gateway 1 60.0 30.0)
              (mk-unit 1261 'cybernetics-core 1 60.0 34.0)
              (mk-unit 2461 'zealot 1 60.0 32.0 #:shield 50.0 #:shield-max 50.0)
              (mk-unit 2462 'stalker 1 58.0 31.0 #:shield 80.0 #:shield-max 80.0)
              (mk-unit 2463 'stalker 1 58.0 33.0 #:shield 80.0 #:shield-max 80.0)
              (mk-unit 2464 'sentry 1 57.5 32.0 #:energy 75.0 #:shield 40.0 #:shield-max 40.0))))
     (define enemies
       (for/list ([i (in-range 14)])
         (mk-unit (+ 6460 i) 'zergling 4 (+ 62.5 (* 0.4 (modulo i 5))) (+ 31.0 (* 0.4 (quotient i 5))))))
     (define s1 (mk-obs 4200 (append allies enemies) #:food-used 32 #:food-cap 46 #:food-army 8 #:food-workers 24))
     (define s2 (mk-obs 4220 (append allies enemies) #:food-used 32 #:food-cap 46 #:food-army 8 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Protoss 'Zerg (list (hash 'obs s1) (hash 'obs s2))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define atk-or-hold
       (for/sum ([t (in-list def-tags)])
         (define abs (wire-abilities-for-tag wcmds t))
         (if (or (memv AB-ATTACK abs) (memv AB-HOLD abs) (memv AB-GUARDIAN-SHIELD abs) (memv AB-FORCE-FIELD abs))
             1 0)))
     (values out
             (list
              (mk-check "choke-defenders-engage-or-cast"
                        (>= atk-or-hold 3)
                        (format "choke defenders engaging/casting=~a/4, cmds=~a"
                                atk-or-hold
                                (for/list ([t def-tags]) (cons t (wire-abilities-for-tag wcmds t))))))))))

;; 20. Worker-Pull Early-Rush Defense (10 enemy Probes <= 6t of TownHall, 0 army)
(define scen-core-worker-pull
  (tactical-scenario
   "core-worker-pull-early-rush-defense"
   "core" "Terran" "Protoss" "worker-pull-defense"
   "Core: 12 SCVs vs 10 enemy Probes rushing inside 6t of Command Center must pull workers to fight/mineral-drill with 0 rejects"
   (lambda ()
     (define scv-tags (for/list ([i (in-range 12)]) (+ 1100 i)))
     (define allies (mk-home-base-units 'Terran #:workers 12))
     (define enemies
       (for/list ([i (in-range 10)])
         (mk-unit (+ 6480 i) 'probe 4 (+ 35.5 (* 0.4 (modulo i 5))) (+ 31.0 (* 0.4 (quotient i 5))))))
     (define s1 (mk-obs 1200 (append allies enemies) #:minerals 100 #:vespene 0 #:food-used 12 #:food-cap 15 #:food-army 0 #:food-workers 12))
     (define outs (run-pipeline-sequence 'Terran 'Protoss (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define active-scvs
       (for/sum ([t (in-list scv-tags)])
         (define abs (wire-abilities-for-tag wcmds t))
         (if (or (memv AB-ATTACK abs) (memv AB-MINERAL-WALK-GATHER abs) (memv AB-MOVE abs)) 1 0)))
     (values out
             (list
              (mk-check "workers-pulled-to-defend-rush"
                        (>= active-scvs 6)
                        (format "active defending SCVs=~a/12" active-scvs))
              (mk-check "zero-wire-rejects"
                        (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; 21. Splash Evasion: Marines standing inside enemy Psi Storm + Purification Nova
(define scen-core-splash-evasion
  (tactical-scenario
   "core-splash-evasion-storm-and-disruptor-nova"
   "core" "Terran" "Protoss" "splash-evasion"
   "Core: Marines standing inside an active enemy Psi Storm (effect 1) must issue evasion MOVE(16) out of the storm radius"
   (lambda ()
     (define m-tags '(2501 2502 2503 2504 2505))
     (define allies
       (append
        (mk-home-base-units 'Terran)
        (for/list ([t (in-list m-tags)] [i (in-naturals)])
          (mk-unit t 'marine 1 (+ 80.0 (* 0.3 i)) 80.0))))
     (define enemies
       (list (mk-unit 6501 'high-templar 4 86.0 80.0 #:energy 25.0)
             (mk-unit 6502 'zealot 4 86.0 81.0)))
     (define storm-eff (sc2-effect 1 (list (sc2-point2d 80.5 80.0)) 4 2 1.5))
     (define s1 (mk-obs 9000 (append allies enemies)
                        #:food-used 21 #:food-cap 46 #:food-army 5 #:food-workers 16
                        #:effects (list storm-eff)))
     (define outs (run-pipeline-sequence 'Terran 'Protoss (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define evading (wire-count-tags-with-ability wcmds m-tags AB-MOVE))
     (values out
             (list
              (mk-check "marines-evade-psi-storm"
                        (>= evading 4)
                        (format "marines emitting evasion MOVE(16) out of Psi Storm=~a/5" evading)))))))

;; 22. Rally-Stream Prevention: Small 4-Marine squad far from enemy main must NOT trickle-attack across map
(define scen-core-rally-stream
  (tactical-scenario
   "core-rally-stream-prevention-small-squad"
   "core" "Terran" "Zerg" "rally-stream-prevention"
   "Core: Small 4-Marine squad near natural facing a 20-supply enemy army across map must regroup/hold, not trickle-march into enemy main"
   (lambda ()
     (define m-tags '(2521 2522 2523 2524))
     (define allies
       (append
        (mk-home-base-units 'Terran #:with-natural? #t)
        (for/list ([t (in-list m-tags)] [i (in-naturals)])
          (mk-unit t 'marine 1 (+ 54.0 (* 0.5 i)) 34.0))))
     (define enemies
       (for/list ([i (in-range 10)])
         (mk-unit (+ 6520 i) 'roach 4 (+ 135.0 (* 0.6 (modulo i 5))) (+ 135.0 (* 0.6 (quotient i 5))))))
     (define s1 (mk-obs 6800 (append allies enemies) #:food-used 28 #:food-cap 54 #:food-army 4 #:food-workers 24))
     (define s2 (mk-obs 6820 (append allies enemies) #:food-used 28 #:food-cap 54 #:food-army 4 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s1) (hash 'obs s2))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     ;; None of the 4 Marines should be issued an attack-move or attack-unit toward (135,135)
     (define suicide-march?
       (for/or ([c (in-list wcmds)])
         (and (sc2-raw-unit-command? c)
              (= (sc2-raw-unit-command-ability-id c) AB-ATTACK)
              (for/or ([t (in-list m-tags)]) (not (not (memv t (sc2-raw-unit-command-unit-tags c)))))
              (or (>= (sc2-raw-unit-command-target-unit-tag c) 6520)
                  (let ([p (sc2-raw-unit-command-target-pos c)])
                    (and p (> (dist2d-xy (sc2-point2d-x p) (sc2-point2d-y p) 54.0 34.0) 40.0)))))))
     (values out
             (list
              (mk-check "small-squad-does-not-trickle-attack-across-map"
                        (not suicide-march?)
                        (format "suicide-march?=~a, wire cmds for marines=~a"
                                suicide-march?
                                (for/list ([t m-tags]) (cons t (wire-abilities-for-tag wcmds t))))))))))

;; =============================================================================
;; TIER 3: NEWLY INVENTED PRO-INSPIRED STRESS SCENARIOS (10 Novel Scenarios)
;; =============================================================================

;; 23. Novel-01: Outnumbered Home Defense Backed by Shield Battery + Photon Cannons
(define scen-novel-01
  (tactical-scenario
   "novel-01-outnumbered-home-defense-backed-by-static-d"
   "novel" "Protoss" "Zerg" "home-defense"
   "Novel: Outnumbered 6 Stalkers backed by 2 Shield Batteries + 2 Photon Cannons at 17t from Natural Nexus must fight under static-D umbrella"
   (lambda ()
     (define stalker-tags '(2601 2602 2603 2604 2605 2606))
     (define allies
       (append
        (mk-home-base-units 'Protoss #:with-natural? #t #:nat-x 52.0 #:nat-y 32.0)
        (list (mk-unit 1301 'pylon 1 65.0 32.0)
              (mk-unit 1302 'shield-battery 1 66.0 31.0 #:energy 100.0 #:shield 150.0 #:shield-max 150.0)
              (mk-unit 1303 'shield-battery 1 66.0 33.5 #:energy 100.0 #:shield 150.0 #:shield-max 150.0)
              (mk-unit 1304 'photon-cannon 1 67.5 31.0 #:shield 150.0 #:shield-max 150.0)
              (mk-unit 1305 'photon-cannon 1 67.5 33.5 #:shield 150.0 #:shield-max 150.0))
        (for/list ([t (in-list stalker-tags)] [i (in-naturals)])
          (mk-unit t 'stalker 1 66.5 (+ 30.5 (* 0.7 i)) #:shield 80.0 #:shield-max 80.0 #:weapon-cooldown 0.0))))
     ;; 10 Roaches + 4 Ravagers attacking static-D wall at x=69.5 (17.5t from Nat Nexus!)
     (define enemies
       (append
        (for/list ([i (in-range 10)])
          (mk-unit (+ 6600 i) 'roach 4 (+ 69.5 (* 0.5 (modulo i 5))) (+ 30.5 (* 0.7 (quotient i 5)))))
        (for/list ([i (in-range 4)])
          (mk-unit (+ 6620 i) 'ravager 4 71.0 (+ 30.8 (* 0.8 i))))))
     (define s1 (mk-obs 7400 (append allies enemies) #:food-used 36 #:food-cap 54 #:food-army 12 #:food-workers 24))
     (define s2 (mk-obs 7420 (append allies enemies) #:food-used 36 #:food-cap 54 #:food-army 12 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Protoss 'Zerg (list (hash 'obs s1) (hash 'obs s2))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define atk-cnt (wire-count-tags-with-ability wcmds stalker-tags AB-ATTACK))
     (define pure-move-cnt (for/sum ([t (in-list stalker-tags)]) (if (wire-pure-move-only? wcmds t) 1 0)))
     (values out
             (list
              (mk-check "stalkers-fight-under-battery-cannon-umbrella"
                        (>= atk-cnt 4)
                        (format "stalkers ATTACK(23)=~a/6 under 2 Batteries + 2 Cannons" atk-cnt))
              (mk-check "stalkers-do-not-abandon-static-d"
                        (= pure-move-cnt 0)
                        (format "stalkers pure-MOVE=~a/6" pure-move-cnt)))))))

;; 24. Novel-02: Fighting into Enemy Sieged Tank + Burrowed Lurker Zone
(define scen-novel-02
  (tactical-scenario
   "novel-02-fight-into-siege-tank-and-lurker-zone"
   "novel" "Zerg" "Zerg" "splash-zone-discipline"
   "Novel: Roaches + Ravagers facing 3 Burrowed Lurkers at range 8t must cast Corrosive Bile or scatter laterally instead of blind clump dive"
   (lambda ()
     (define rav-tags '(2621 2622 2623))
     (define roach-tags '(2624 2625 2626 2627 2628 2629))
     (define allies
       (append
        (mk-home-base-units 'Zerg #:with-natural? #t)
        (for/list ([t (in-list rav-tags)] [i (in-naturals)])
          (mk-unit t 'ravager 1 80.0 (+ 79.0 (* 0.8 i))))
        (for/list ([t (in-list roach-tags)] [i (in-naturals)])
          (mk-unit t 'roach 1 82.0 (+ 78.0 (* 0.5 i))))
        (list (mk-unit 2630 'overseer 1 81.0 80.0 #:flying? #t))))
     (define enemies
       (list (mk-unit 6631 'lurker-mp-burrowed 4 88.0 79.0 #:burrowed? #t)
             (mk-unit 6632 'lurker-mp-burrowed 4 88.0 80.5 #:burrowed? #t)
             (mk-unit 6633 'lurker-mp-burrowed 4 88.0 82.0 #:burrowed? #t)))
     (define s1 (mk-obs 9600 (append allies enemies) #:food-used 45 #:food-cap 66 #:food-army 21 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Zerg 'Zerg (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define bile-cast? (wire-has-ability? wcmds rav-tags AB-CORROSIVE-BILE))
     (define any-scatter-move? (> (wire-count-tags-with-ability wcmds roach-tags AB-MOVE) 0))
     (values out
             (list
              (mk-check "ravagers-bile-burrowed-lurkers"
                        bile-cast?
                        (format "ravagers wire abs=~a (expected ~a BILE)"
                                (for/list ([t rav-tags]) (cons t (wire-abilities-for-tag wcmds t)))
                                AB-CORROSIVE-BILE))
              (mk-check "roaches-scatter-or-bile-supported"
                        (or bile-cast? any-scatter-move?)
                        (format "roach scatter MOVE count=~a/6" (wire-count-tags-with-ability wcmds roach-tags AB-MOVE))))))))

;; 25. Novel-03: Retreating Through a Choke While Pursued by Fast Speedlings (Zero-Fire Suicide Check)
(define scen-novel-03
  (tactical-scenario
   "novel-03-choke-retreat-without-zero-fire-suicide"
   "novel" "Terran" "Zerg" "stutter-step-and-pullback"
   "Novel: Outnumbered Marines+Marauders retreating through a choke with Speedlings at 3.5t and weapon-cooldown=0.0 must stutter-fire, never zero-shot MOVE"
   (lambda ()
     (define bio-tags '(2641 2642 2643 2644 2645 2646))
     (define allies
       (append
        (mk-home-base-units 'Terran #:with-natural? #t)
        (list (mk-unit 2641 'marine 1 78.0 60.0 #:weapon-cooldown 0.0)
              (mk-unit 2642 'marine 1 78.5 60.5 #:weapon-cooldown 0.0)
              (mk-unit 2643 'marine 1 78.0 61.0 #:weapon-cooldown 0.0)
              (mk-unit 2644 'marine 1 78.5 61.5 #:weapon-cooldown 0.0)
              (mk-unit 2645 'marauder 1 77.5 60.5 #:weapon-cooldown 0.0)
              (mk-unit 2646 'marauder 1 77.5 61.2 #:weapon-cooldown 0.0))))
     ;; Pursuing 16 Speedlings + 6 Banelings (heavily outnumbered -> pullback active) right on their heels at dist ~3.5t
     (define enemies
       (append
        (for/list ([i (in-range 16)])
          (mk-unit (+ 6640 i) 'zergling 4 (+ 81.5 (* 0.4 (modulo i 4))) (+ 59.8 (* 0.4 (quotient i 4)))))
        (for/list ([i (in-range 6)])
          (mk-unit (+ 6660 i) 'roach 4 (+ 83.5 (* 0.5 (modulo i 3))) (+ 60.0 (* 0.6 (quotient i 3)))))))
     (define s1 (mk-obs 7900 (append allies enemies) #:food-used 32 #:food-cap 54 #:food-army 8 #:food-workers 24))
     (define s2 (mk-obs 7920 (append allies enemies) #:food-used 32 #:food-cap 54 #:food-army 8 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s1) (hash 'obs s2))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define enemy-tags (append (for/list ([i (in-range 16)]) (+ 6640 i))
                                (for/list ([i (in-range 6)]) (+ 6660 i))))
     (define atk-cnt (wire-count-local-attacks wcmds bio-tags enemy-tags 82.0 60.5 16.0))
     (define kited-cnt (bot-actions-kite-tags (step-outcome-bot-actions out) bio-tags))
     (values out
             (list
              (mk-check "retreating-bio-stutter-fires-ready-weapons"
                        (>= atk-cnt 4)
                        (format "ready-weapon bio local ATTACK(23)=~a/6 under pursuit, targets=~a"
                                atk-cnt (wire-targets-for-tags wcmds bio-tags AB-ATTACK)))
              (mk-check "no-zero-fire-retreat-suicide"
                        (= kited-cnt 0)
                        (format "ready-weapon bio receiving (kite ...)=~a/6" kited-cnt)))))))

;; 26. Novel-04: Defending Simultaneous Main Drop + Third-Base Raid (2-Prong Harass)
(define scen-novel-04
  (tactical-scenario
   "novel-04-simultaneous-main-drop-and-third-harass"
   "novel" "Zerg" "Terran" "multi-prong-defense"
   "Novel: Simultaneous 4-Marine drop in Main (30,30) + 6-Marine raid at Third (72,32) must engage threats at BOTH bases"
   (lambda ()
     (define main-def-tags '(2681 2682 2683 2684 2685 2686))
     (define third-def-tags '(2691 2692 2693 2694 2695 2696))
     (define main-enemy-tags '(6681 6682 6683 6684))
     (define third-enemy-tags '(6691 6692 6693 6694 6695 6696))
     (define allies
       (append
        (mk-home-base-units 'Zerg #:with-natural? #t #:nat-x 52.0 #:nat-y 32.0)
        (list (mk-unit 1320 'hatchery 1 72.0 32.0 #:assigned 8 #:ideal 16))
        (for/list ([t (in-list main-def-tags)] [i (in-naturals)])
          (mk-unit t 'zergling 1 (+ 34.0 (* 0.4 i)) 31.0))
        (for/list ([t (in-list third-def-tags)] [i (in-naturals)])
          (mk-unit t 'roach 1 (+ 68.0 (* 0.5 i)) 33.0))))
     (define enemies
       (append
        (for/list ([t (in-list main-enemy-tags)] [i (in-naturals)])
          (mk-unit t 'marine 4 (+ 29.0 (* 0.4 i)) 31.0))
        (for/list ([t (in-list third-enemy-tags)] [i (in-naturals)])
          (mk-unit t 'marine 4 (+ 74.5 (* 0.4 i)) 32.0))))
     (define s1 (mk-obs 8600 (append allies enemies) #:food-used 47 #:food-cap 66 #:food-army 15 #:food-workers 32))
     (define s2 (mk-obs 8620 (append allies enemies) #:food-used 47 #:food-cap 66 #:food-army 15 #:food-workers 32))
     (define outs (run-pipeline-sequence 'Zerg 'Terran (list (hash 'obs s1) (hash 'obs s2))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define main-tgts (wire-targets-for-tags wcmds main-def-tags AB-ATTACK))
     (define third-tgts (wire-targets-for-tags wcmds third-def-tags AB-ATTACK))
     (define hits-main? (for/or ([e (in-list main-tgts)]) (not (not (memv (second e) main-enemy-tags)))))
     (define hits-third? (for/or ([e (in-list third-tgts)]) (not (not (memv (second e) third-enemy-tags)))))
     (values out
             (list
              (mk-check "main-squad-engages-main-drop"
                        hits-main?
                        (format "main squad attack targets=~a" main-tgts))
              (mk-check "third-squad-engages-third-raid"
                        hits-third?
                        (format "third squad attack targets=~a" third-tgts)))))))

;; 27. Novel-05: Over-Chase Trap Into Enemy Planetary Fortress / Static-D
(define scen-novel-05
  (tactical-scenario
   "novel-05-overchase-trap-into-enemy-static-d"
   "novel" "Zerg" "Terran" "static-defense-discipline"
   "Novel: Zergling pack near enemy Planetary Fortress + Sieged Tank must hold off/pull back instead of diving into PF splash"
   (lambda ()
     (define ling-tags '(2701 2702 2703 2704 2705 2706 2707 2708))
     (define allies
       (append
        (mk-home-base-units 'Zerg #:with-natural? #t)
        (for/list ([t (in-list ling-tags)] [i (in-naturals)])
          (mk-unit t 'zergling 1 (+ 133.0 (* 0.4 (modulo i 4))) (+ 154.0 (* 0.4 (quotient i 4)))))))
     (define enemies
       (list (mk-unit 6701 'planetary-fortress 4 140.0 160.0)
             (mk-unit 6702 'siege-tank-sieged 4 142.0 162.0)
             (mk-unit 6703 'scv 4 139.0 158.0)))
     (define s1 (mk-obs 9400 (append allies enemies) #:food-used 28 #:food-cap 44 #:food-army 4 #:food-workers 24))
     (define s2 (mk-obs 9420 (append allies enemies) #:food-used 28 #:food-cap 44 #:food-army 4 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Zerg 'Terran (list (hash 'obs s1) (hash 'obs s2))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define diving-pf?
       (for/or ([e (in-list (wire-targets-for-tags wcmds ling-tags AB-ATTACK))])
         (memv (second e) '(6701 6702 6703))))
     (values out
             (list
              (mk-check "lings-do-not-suicide-into-pf-and-sieged-tank"
                        (not diving-pf?)
                        (format "ling attack targets=~a (must hold off PF 6701 + Sieged Tank 6702)"
                                (wire-targets-for-tags wcmds ling-tags AB-ATTACK))))))))

;; 28. Novel-06: Anti-Air Minimal-Pull vs Oracle Harass (Defend Main Without Abandoning Natural Front)
(define scen-novel-06
  (tactical-scenario
   "novel-06-anti-air-minimal-pull-vs-oracle-harass"
   "novel" "Terran" "Protoss" "detection-and-anti-air"
   "Novel: 1 enemy Oracle harassing Main SCVs while Protoss ground army threatens Natural — main Marines shoot Oracle while natural front holds/engages"
   (lambda ()
     (define main-aa-tags '(2721 2722 2723 2724))
     (define nat-front-tags '(2731 2732 2733 2734 2735 2736))
     (define oracle-tag 6721)
     (define nat-enemy-tags '(6731 6732 6733 6734))
     (define allies
       (append
        (mk-home-base-units 'Terran #:with-natural? #t #:nat-x 52.0 #:nat-y 32.0)
        (for/list ([t (in-list main-aa-tags)] [i (in-naturals)])
          (mk-unit t 'marine 1 (+ 30.0 (* 0.5 i)) 31.0 #:weapon-cooldown 0.0))
        (for/list ([t (in-list nat-front-tags)] [i (in-naturals)])
          (mk-unit t 'marine 1 (+ 55.0 (* 0.5 i)) 32.0 #:weapon-cooldown 0.0))))
     (define enemies
       (cons
        (mk-unit oracle-tag 'oracle 4 28.0 31.5 #:flying? #t #:energy 60.0 #:shield 60.0 #:shield-max 60.0)
        (for/list ([t (in-list nat-enemy-tags)] [i (in-naturals)])
          (mk-unit t 'stalker 4 (+ 61.0 (* 0.6 i)) 32.0 #:shield 80.0 #:shield-max 80.0))))
     (define s1 (mk-obs 5800 (append allies enemies) #:food-used 34 #:food-cap 54 #:food-army 10 #:food-workers 24))
     (define s2 (mk-obs 5820 (append allies enemies) #:food-used 34 #:food-cap 54 #:food-army 10 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Terran 'Protoss (list (hash 'obs s1) (hash 'obs s2))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define main-hits-oracle?
       (for/or ([e (in-list (wire-targets-for-tags wcmds main-aa-tags AB-ATTACK))])
         (= (second e) oracle-tag)))
     (define nat-hits-front?
       (for/or ([e (in-list (wire-targets-for-tags wcmds nat-front-tags AB-ATTACK))])
         (not (not (memv (second e) nat-enemy-tags)))))
     (values out
             (list
              (mk-check "main-aa-defenders-target-oracle"
                        main-hits-oracle?
                        (format "main marines targets=~a (expected oracle ~a)"
                                (wire-targets-for-tags wcmds main-aa-tags AB-ATTACK) oracle-tag))
              (mk-check "natural-front-stays-engaged-with-stalkers"
                        nat-hits-front?
                        (format "natural marines targets=~a (expected stalkers ~a)"
                                (wire-targets-for-tags wcmds nat-front-tags AB-ATTACK) nat-enemy-tags)))))))

;; 29. Novel-07: Hidden-Base Endgame Sweep Ordering (Enemy-Side First With Multi-Candidate Expansions)
(define scen-novel-07
  (tactical-scenario
   "novel-07-hidden-base-endgame-sweep-multi-candidate"
   "novel" "Protoss" "Zerg" "endgame-hunt"
   "Novel: Dominant 110-supply Protoss army after clearing enemy main with leftover Overlord + CreepTumor must sweep enemy-side expansion candidates"
   (lambda ()
     (define army-tags (for/list ([i (in-range 28)]) (+ 2750 i)))
     (define allies
       (append
        (mk-home-base-units 'Protoss #:with-natural? #t)
        (for/list ([t (in-list army-tags)] [i (in-naturals)])
          (mk-unit t 'stalker 1 (+ 157.0 (* 0.5 (modulo i 7))) (+ 157.0 (* 0.5 (quotient i 7)))
                   #:shield 80.0 #:shield-max 80.0))))
     (define enemies
       (list (mk-unit 6751 'creep-tumor-burrowed 4 159.0 160.0 #:burrowed? #t)
             (mk-unit 6752 'overlord 4 162.0 164.0 #:flying? #t)))
     (define exp-cands (list (hash 'x 115.0 'y 150.0) (hash 'x 160.0 'y 60.0) (hash 'x 40.0 'y 155.0)))
     (define overlay (hash 'expansion-candidates exp-cands))
     (define s1 (mk-obs 19000 (append allies enemies) #:food-used 112 #:food-cap 150 #:food-army 56 #:food-workers 24))
     (define s2 (mk-obs 19050 (append allies enemies) #:food-used 112 #:food-cap 150 #:food-army 56 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Protoss 'Zerg
                                         (list (hash 'obs s1 'overlay overlay)
                                               (hash 'obs s2 'overlay overlay))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define sweep-cmds
       (for/list ([c (in-list wcmds)]
                  #:when (and (sc2-raw-unit-command? c)
                              (memv (sc2-raw-unit-command-ability-id c) (list AB-ATTACK AB-MOVE))
                              (sc2-raw-unit-command-target-pos c)
                              (let ([p (sc2-raw-unit-command-target-pos c)])
                                (> (dist2d-xy (sc2-point2d-x p) (sc2-point2d-y p) 160.0 160.0) 20.0))))
         c))
     (values out
             (list
              (mk-check "protoss-dominant-army-sweeps-hidden-expansions"
                        (pair? sweep-cmds)
                        (format "sweep cmds=~a (expected >=1 toward unvisited expansions)" (length sweep-cmds))))))))

;; 30. Novel-08: Unit-Type-Aware Pullback Thresholds (Slow Immortal + Melee Zealot vs Fast Stalker)
(define scen-novel-08
  (tactical-scenario
   "novel-08-unit-type-aware-retreat-immortal-zealot-vs-stalker"
   "novel" "Protoss" "Zerg" "stutter-step-and-pullback"
   "Novel: Under pullback at dist 4.5t with weapon-cooldown=0.0, slow Immortal & melee Zealot must fire (23) instead of getting chased down via pure MOVE(16)"
   (lambda ()
     (define immortal-tags '(2781 2782))
     (define zealot-tags   '(2783 2784))
     (define stalker-cd    '(2785 2786))
     (define allies
       (append
        (mk-home-base-units 'Protoss)
        (for/list ([t (in-list immortal-tags)] [i (in-naturals)])
          (mk-unit t 'immortal 1 80.0 (+ 79.0 (* 1.0 i))
                   #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0 #:weapon-cooldown 0.0))
        (for/list ([t (in-list zealot-tags)] [i (in-naturals)])
          (mk-unit t 'zealot 1 81.5 (+ 79.0 (* 1.0 i))
                   #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0 #:weapon-cooldown 0.0))
        (for/list ([t (in-list stalker-cd)] [i (in-naturals)])
          ;; 18.0 SC2 game loops = 0.804s (past Stalker swing window, well above 0.15s kite thresh!)
          (mk-unit t 'stalker 1 78.5 (+ 79.0 (* 1.0 i))
                   #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0 #:weapon-cooldown 18.0))))
     ;; Heavily outnumbered by 14 Roaches + 10 Speedlings at x=84.5 (dist 3..4.5t)
     (define enemies
       (append
        (for/list ([i (in-range 14)])
          (mk-unit (+ 6780 i) 'roach 4 (+ 84.5 (* 0.5 (modulo i 7))) (+ 78.5 (* 0.7 (quotient i 7)))))
        (for/list ([i (in-range 10)])
          (mk-unit (+ 6800 i) 'zergling 4 (+ 84.0 (* 0.4 (modulo i 5))) (+ 79.0 (* 0.5 (quotient i 5)))))))
     (define s1 (mk-obs 8800 (append allies enemies) #:food-used 32 #:food-cap 54 #:food-army 16 #:food-workers 16))
     (define s2 (mk-obs 8820 (append allies enemies) #:food-used 32 #:food-cap 54 #:food-army 16 #:food-workers 16))
     (define outs (run-pipeline-sequence 'Protoss 'Zerg (list (hash 'obs s1) (hash 'obs s2))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define imm-atk (wire-count-tags-with-ability wcmds immortal-tags AB-ATTACK))
     (define zea-atk (wire-count-tags-with-ability wcmds zealot-tags AB-ATTACK))
     (define stk-move (wire-count-tags-with-ability wcmds stalker-cd AB-MOVE))
     (values out
             (list
              (mk-check "slow-immortals-ready-weapon-fire"
                        (= imm-atk 2)
                        (format "immortals ATTACK(23)=~a/2, cmds=~a"
                                imm-atk (for/list ([t immortal-tags]) (cons t (wire-abilities-for-tag wcmds t)))))
              (mk-check "melee-zealots-fight"
                        (= zea-atk 2)
                        (format "zealots ATTACK(23)=~a/2" zea-atk))
              (mk-check "on-cooldown-stalkers-kite"
                        (>= stk-move 1)
                        (format "on-cooldown stalkers MOVE(16)=~a/2" stk-move)))))))

;; 31. Novel-09: Cloaked Dark Templar Harass Without Detection -> Triggers Mirror-Mind Detection
(define scen-novel-09
  (tactical-scenario
   "novel-09-cloaked-dt-triggers-real-detection"
   "novel" "Terran" "Protoss" "detection-and-anti-air"
   "Novel: Cloaked Dark Templar in Terran natural with no detector must trigger Mirror-Mind requires-detection?=#t with 0 wire rejects"
   (lambda ()
     (define allies
       (append
        (mk-home-base-units 'Terran #:with-natural? #t)
        (list (mk-unit 1340 'orbital-command 1 32.0 32.0 #:energy 50.0 #:assigned 16 #:ideal 16)
              (mk-unit 2811 'marine 1 50.0 32.0)
              (mk-unit 2812 'marine 1 50.5 32.5))))
     (define enemies
       (list (mk-unit 6811 'dark-templar 4 53.0 32.5 #:cloak 1 #:shield 80.0 #:shield-max 80.0)))
     (define s1 (mk-obs 6600 (append allies enemies) #:food-used 28 #:food-cap 46 #:food-army 2 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Terran 'Protoss (list (hash 'obs s1))))
     (define out (last outs))
     (define tech (step-outcome-mm-tech-obs out))
     (define req-det? (and tech (enemy-tech-observation-requires-detection? tech)))
     (values out
             (list
              (mk-check "cloaked-dt-triggers-requires-detection"
                        req-det?
                        (format "mirror-mind requires-detection?=~a (expected #t for cloaked DT)" req-det?))
              (mk-check "zero-wire-rejects-under-cloak"
                        (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; 32. Novel-10: Baneling Approach — Light Marines Radial Pre-Split While Armored Marauders Hold/Engage
(define scen-novel-10
  (tactical-scenario
   "novel-10-baneling-light-marine-split-vs-armored-marauder"
   "novel" "Terran" "Zerg" "splash-evasion"
   "Novel: Incoming Banelings at 4.5t cause light Marines to radial pre-split MOVE(16) while armored Marauders engage/focus-fire"
   (lambda ()
     (define marine-tags '(2831 2832 2833 2834 2835 2836))
     (define marauder-tags '(2841 2842 2843))
     (define allies
       (append
        (mk-home-base-units 'Terran)
        (for/list ([t (in-list marine-tags)] [i (in-naturals)])
          (mk-unit t 'marine 1 (+ 79.5 (* 0.4 (modulo i 3))) (+ 79.5 (* 0.4 (quotient i 3))) #:weapon-cooldown 0.0))
        (for/list ([t (in-list marauder-tags)] [i (in-naturals)])
          (mk-unit t 'marauder 1 81.5 (+ 79.2 (* 0.8 i)) #:weapon-cooldown 0.0))))
     (define enemies
       (list (mk-unit 6831 'baneling 4 82.8 79.5)
             (mk-unit 6832 'baneling 4 82.8 80.5)
             (mk-unit 6833 'baneling 4 83.0 80.0)))
     (define s1 (mk-obs 6400 (append allies enemies) #:food-used 28 #:food-cap 54 #:food-army 12 #:food-workers 16))
     (define outs (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define marine-splits (wire-count-tags-with-ability wcmds marine-tags AB-MOVE))
     (define marauder-atks (wire-count-tags-with-ability wcmds marauder-tags AB-ATTACK))
     (values out
             (list
              (mk-check "light-marines-radial-split-vs-banelings"
                        (>= marine-splits 4)
                        (format "light marines radial-split MOVE(16)=~a/6" marine-splits))
              (mk-check "armored-marauders-hold-and-focus-banelings"
                        (>= marauder-atks 2)
                        (format "armored marauders ATTACK(23)=~a/3" marauder-atks)))))))

;; 33. Novel-11: Winning Melee Protoss Zealots Must Not DisengageRetreat (`arena-minimax` regression guard)
(define scen-novel-11
  (tactical-scenario
   "novel-11-winning-melee-zealots-no-disengage-retreat"
   "novel" "Protoss" "Terran" "melee-engage"
   "Novel: 10 Charge Zealots engaging 5 Marines in open field must commit ATTACK(23) locally, never DisengageRetreat MOVE(16) home"
   (lambda ()
     (define zealot-tags (for/list ([i (in-range 10)]) (+ 2850 i)))
     (define enemy-tags (for/list ([i (in-range 5)]) (+ 6850 i)))
     (define allies
       (append
        (mk-home-base-units 'Protoss #:with-natural? #t)
        (for/list ([t (in-list zealot-tags)] [i (in-naturals)])
          (mk-unit t 'zealot 1 (+ 80.0 (* 0.5 (modulo i 5))) (+ 79.0 (* 0.6 (quotient i 5)))
                   #:shield 50.0 #:shield-max 50.0 #:weapon-cooldown 0.0))))
     (define enemies
       (for/list ([t (in-list enemy-tags)] [i (in-naturals)])
         (mk-unit t 'marine 4 (+ 85.0 (* 0.4 i)) 79.5)))
     (define s1 (mk-obs 7200 (append allies enemies) #:food-used 44 #:food-cap 66 #:food-army 20 #:food-workers 24
                        #:upgrades '(charge)))
     (define s2 (mk-obs 7220 (append allies enemies) #:food-used 44 #:food-cap 66 #:food-army 20 #:food-workers 24
                        #:upgrades '(charge)))
     (define outs (run-pipeline-sequence 'Protoss 'Terran (list (hash 'obs s1) (hash 'obs s2))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define local-atks (wire-count-local-attacks wcmds zealot-tags enemy-tags 85.5 79.5 16.0))
     (define pure-moves (for/sum ([t (in-list zealot-tags)]) (if (wire-pure-move-only? wcmds t) 1 0)))
     (values out
             (list
              (mk-check "winning-zealots-attack-marines-locally"
                        (>= local-atks 7)
                        (format "zealots local ATTACK(23)=~a/10" local-atks))
              (mk-check "winning-zealots-no-pure-move-retreat"
                        (= pure-moves 0)
                        (format "zealots pure-MOVE=~a/10" pure-moves)))))))

;; 34. Novel-12: Engaged Frontline Marines Must Not Be Stolen by Cross-Map Harass/Raid
(define scen-novel-12
  (tactical-scenario
   "novel-12-frontline-not-stolen-by-cross-map-harass"
   "novel" "Terran" "Zerg" "multi-prong-defense"
   "Novel: 6 Marines actively fighting 8 Zerglings at 4t mid-map must NOT be stolen by multitask-harass-and-proxy for cross-map raids"
   (lambda ()
     (define marine-tags '(2871 2872 2873 2874 2875 2876))
     (define enemy-tags (for/list ([i (in-range 8)]) (+ 6870 i)))
     (define allies
       (append
        (mk-home-base-units 'Terran #:with-natural? #t)
        (for/list ([t (in-list marine-tags)] [i (in-naturals)])
          (mk-unit t 'marine 1 80.0 (+ 78.5 (* 0.5 i)) #:weapon-cooldown 0.0))))
     (define enemies
       (for/list ([t (in-list enemy-tags)] [i (in-naturals)])
         (mk-unit t 'zergling 4 (+ 84.0 (* 0.4 (modulo i 4))) (+ 78.8 (* 0.5 (quotient i 4))))))
     (define s1 (mk-obs 6200 (append allies enemies) #:food-used 30 #:food-cap 54 #:food-army 6 #:food-workers 24))
     (define s2 (mk-obs 6220 (append allies enemies) #:food-used 30 #:food-cap 54 #:food-army 6 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s1) (hash 'obs s2))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define cross-map-cmds
       (for/sum ([t (in-list marine-tags)])
         (define bad?
           (for/or ([c (in-list (wire-cmds-for-tag wcmds t))])
             (define p (sc2-raw-unit-command-target-pos c))
             (and p (> (dist2d-xy (sc2-point2d-x p) (sc2-point2d-y p) 82.0 79.5) 35.0))))
         (if bad? 1 0)))
     (define local-atks (wire-count-local-attacks wcmds marine-tags enemy-tags 84.0 79.5 16.0))
     (values out
             (list
              (mk-check "no-frontline-marine-stolen-across-map"
                        (= cross-map-cmds 0)
                        (format "frontline marines sent >35t away=~a/6, targets=~a"
                                cross-map-cmds (wire-targets-for-tags wcmds marine-tags AB-ATTACK)))
              (mk-check "frontline-marines-engage-local-lings"
                        (>= local-atks 4)
                        (format "frontline marines local ATTACK(23)=~a/6" local-atks)))))))

;; 35. Novel-13: Stalker Blink Micro — Injured Stalker Blinks Back, Healthy Stalkers Fire
(define scen-novel-13
  (tactical-scenario
   "novel-13-stalker-blink-micro-injured-vs-healthy"
   "novel" "Protoss" "Terran" "unit-mobility-micro"
   "Novel: With Blink researched, injured Stalker (35 HP / 0 Shield) blinks back (1442/3687) while healthy Stalkers fire ATTACK(23)"
   (lambda ()
     (define injured-tag 2891)
     (define healthy-tags '(2892 2893 2894 2895))
     (define enemy-tags '(6891 6892 6893))
     (define allies
       (append
        (mk-home-base-units 'Protoss #:with-natural? #t)
        (list (mk-unit injured-tag 'stalker 1 80.5 80.0 #:hp 35.0 #:hp-max 80.0 #:shield 0.0 #:shield-max 80.0 #:weapon-cooldown 0.0))
        (for/list ([t (in-list healthy-tags)] [i (in-naturals)])
          (mk-unit t 'stalker 1 79.5 (+ 78.5 (* 0.8 i)) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0 #:weapon-cooldown 0.0))))
     (define enemies
       (list (mk-unit 6891 'marine 4 85.5 79.5)
             (mk-unit 6892 'marine 4 85.5 80.5)
             (mk-unit 6893 'marauder 4 86.0 80.0)))
     (define s1 (mk-obs 7400 (append allies enemies) #:food-used 34 #:food-cap 54 #:food-army 10 #:food-workers 24
                        #:upgrades '(blink)))
     (define outs (run-pipeline-sequence 'Protoss 'Terran (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define blinked? (wire-any-ability? wcmds (list injured-tag) (list AB-BLINK-STALKER AB-BLINK-GENERIC)))
     (define healthy-atks (wire-count-local-attacks wcmds healthy-tags enemy-tags 85.5 80.0 16.0))
     (values out
             (list
              (mk-check "injured-stalker-casts-blink"
                        blinked?
                        (format "injured stalker-2891 wire abs=~a (expected ~a/~a BLINK)"
                                (wire-abilities-for-tag wcmds injured-tag) AB-BLINK-STALKER AB-BLINK-GENERIC))
              (mk-check "healthy-stalkers-keep-firing"
                        (>= healthy-atks 3)
                        (format "healthy stalkers local ATTACK(23)=~a/4" healthy-atks)))))))

;; 36. Novel-14: Marine Stimpack HP Gate — Healthy Marines Stim, Critical-HP Marines Do Not Self-Stim
(define scen-novel-14
  (tactical-scenario
   "novel-14-marine-stimpack-hp-gate"
   "novel" "Terran" "Protoss" "unit-mobility-micro"
   "Novel: With Stimpack researched, healthy Marines (45 HP) stim (3675/367) on engage while low-HP Marines (15 HP) do NOT self-stim"
   (lambda ()
     (define healthy-tags '(2901 2902 2903 2904))
     (define lowhp-tags   '(2905 2906))
     (define allies
       (append
        (mk-home-base-units 'Terran #:with-natural? #t)
        (for/list ([t (in-list healthy-tags)] [i (in-naturals)])
          (mk-unit t 'marine 1 80.0 (+ 78.5 (* 0.6 i)) #:hp 45.0 #:hp-max 45.0))
        (for/list ([t (in-list lowhp-tags)] [i (in-naturals)])
          (mk-unit t 'marine 1 79.5 (+ 81.0 (* 0.6 i)) #:hp 15.0 #:hp-max 45.0))))
     (define enemies
       (list (mk-unit 6901 'zealot 4 85.5 79.5 #:shield 50.0 #:shield-max 50.0)
             (mk-unit 6902 'stalker 4 86.0 80.5 #:shield 80.0 #:shield-max 80.0)))
     (define s1 (mk-obs 7600 (append allies enemies) #:food-used 30 #:food-cap 54 #:food-army 6 #:food-workers 24
                        #:upgrades '(stimpack)))
     (define outs (run-pipeline-sequence 'Terran 'Protoss (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define healthy-stim? (wire-any-ability? wcmds healthy-tags (list AB-STIMPACK AB-STIM-ALT)))
     (define lowhp-stim?   (wire-any-ability? wcmds lowhp-tags (list AB-STIMPACK AB-STIM-ALT)))
     (values out
             (list
              (mk-check "healthy-marines-activate-stimpack"
                        healthy-stim?
                        (format "healthy marines abs=~a" (for/list ([t healthy-tags]) (cons t (wire-abilities-for-tag wcmds t)))))
              (mk-check "low-hp-marines-do-not-self-stim"
                        (not lowhp-stim?)
                        (format "low-HP (15/45) marines abs=~a" (for/list ([t lowhp-tags]) (cons t (wire-abilities-for-tag wcmds t))))))))))

;; 37. Novel-15: Disruptor Purification Nova Lateral Evasion
(define scen-novel-15
  (tactical-scenario
   "novel-15-disruptor-purification-nova-lateral-evasion"
   "novel" "Terran" "Protoss" "splash-evasion"
   "Novel: Marines within 2.5t of an active enemy Disruptor Purification Nova (disruptor-phased) must evade via MOVE(16)"
   (lambda ()
     (define m-tags '(2911 2912 2913 2914 2915 2916))
     (define allies
       (append
        (mk-home-base-units 'Terran #:with-natural? #t)
        (for/list ([t (in-list m-tags)] [i (in-naturals)])
          (mk-unit t 'marine 1 (+ 80.0 (* 0.3 (modulo i 3))) (+ 79.5 (* 0.3 (quotient i 3)))))))
     (define enemies
       (list (mk-unit 6911 'disruptor-phased 4 82.0 79.7)
             (mk-unit 6912 'disruptor 4 89.0 80.0 #:shield 100.0 #:shield-max 100.0)
             (mk-unit 6913 'stalker 4 88.0 80.0 #:shield 80.0 #:shield-max 80.0)))
     (define s1 (mk-obs 10200 (append allies enemies) #:food-used 30 #:food-cap 54 #:food-army 6 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Terran 'Protoss (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define evading (wire-count-tags-with-ability wcmds m-tags AB-MOVE))
     (values out
             (list
              (mk-check "marines-evade-purification-nova"
                        (>= evading 4)
                        (format "marines emitting MOVE(16) away from disruptor-phased=~a/6" evading)))))))

;; 38. Novel-16: Widow Mine Burrow on Approach & Unburrow When Clear
(define scen-novel-16
  (tactical-scenario
   "novel-16-widow-mine-burrow-and-unburrow-discipline"
   "novel" "Terran" "Zerg" "unit-mode-micro"
   "Novel: Unburrowed Widow Mine at 7t from incoming Zerglings burrows (2095); Burrowed Widow Mine 50t from all enemies unburrows (2097)"
   (lambda ()
     (define wm-close 2921)
     (define wm-far   2922)
     (define allies
       (append
        (mk-home-base-units 'Terran #:with-natural? #t)
        (list (mk-unit wm-close 'widow-mine 1 80.0 80.0)
              (mk-unit wm-far   'widow-mine-burrowed 1 35.0 35.0 #:burrowed? #t)
              (mk-unit 2923 'marine 1 78.5 80.0)
              (mk-unit 2924 'marine 1 78.5 81.0))))
     (define enemies
       (for/list ([i (in-range 6)])
         (mk-unit (+ 6920 i) 'zergling 4 (+ 86.5 (* 0.4 i)) 80.0)))
     (define s1 (mk-obs 6800 (append allies enemies) #:food-used 30 #:food-cap 54 #:food-army 6 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define burrowed? (wire-any-ability? wcmds (list wm-close) (list AB-BURROW-WIDOW-MINE AB-BURROW-DOWN)))
     (define unburrowed? (wire-any-ability? wcmds (list wm-far) (list AB-UNBURROW-WIDOW-MINE AB-BURROW-UP)))
     (values out
             (list
              (mk-check "widow-mine-burrows-vs-approaching-lings"
                        burrowed?
                        (format "wm-2921 abs=~a (expected ~a BURROW)" (wire-abilities-for-tag wcmds wm-close) AB-BURROW-WIDOW-MINE))
              (mk-check "idle-far-widow-mine-unburrows"
                        unburrowed?
                        (format "wm-2922 abs=~a (expected ~a UNBURROW)" (wire-abilities-for-tag wcmds wm-far) AB-UNBURROW-WIDOW-MINE)))))))

;; 39. Novel-17: Liberator Defender Zone Siege (AG) & Reposition Unsiege (AA)
(define scen-novel-17
  (tactical-scenario
   "novel-17-liberator-ag-siege-and-aa-reposition"
   "novel" "Terran" "Zerg" "unit-mode-micro"
   "Novel: Liberator within 6.5t of enemy Roaches morphs to Defender Mode AG (2558); Liberator-AG 50t from enemies morphs back to AA (2560)"
   (lambda ()
     (define lib-near 2931)
     (define lib-far  2932)
     (define allies
       (append
        (mk-home-base-units 'Terran #:with-natural? #t)
        (list (mk-unit lib-near 'liberator 1 80.0 80.0 #:flying? #t)
              (mk-unit lib-far  'liberator-ag 1 36.0 36.0 #:flying? #t)
              (mk-unit 2933 'marine 1 78.0 80.0)
              (mk-unit 2934 'marine 1 78.0 81.0))))
     (define enemies
       (list (mk-unit 6931 'roach 4 86.0 80.0)
             (mk-unit 6932 'roach 4 86.5 81.0)
             (mk-unit 6933 'roach 4 86.5 79.0)))
     (define s1 (mk-obs 8600 (append allies enemies) #:food-used 32 #:food-cap 54 #:food-army 8 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define sieged-ag? (wire-has-ability? wcmds (list lib-near) AB-LIBERATOR-AG))
     (define unsieged-aa? (wire-has-ability? wcmds (list lib-far) AB-LIBERATOR-AA))
     (values out
             (list
              (mk-check "liberator-sieges-ag-over-roaches"
                        sieged-ag?
                        (format "lib-2931 abs=~a (expected ~a LIBERATOR-AG)" (wire-abilities-for-tag wcmds lib-near) AB-LIBERATOR-AG))
              (mk-check "idle-far-liberator-unsieges-aa"
                        unsieged-aa?
                        (format "lib-2932 abs=~a (expected ~a LIBERATOR-AA)" (wire-abilities-for-tag wcmds lib-far) AB-LIBERATOR-AA)))))))

;; 40. Novel-18: Zerg Viper Abduct / Blinding Cloud vs Siege Tank + Thor
(define scen-novel-18
  (tactical-scenario
   "novel-18-zerg-viper-abduct-or-blinding-cloud"
   "novel" "Zerg" "Terran" "spellcasters"
   "Novel: Zerg Viper (125en) facing Sieged Tanks + Thor casts Abduct (2067) or Blinding Cloud (2063) without attack-diving"
   (lambda ()
     (define viper-tag 2941)
     (define allies
       (append
        (mk-home-base-units 'Zerg #:with-natural? #t)
        (list (mk-unit viper-tag 'viper 1 80.0 80.0 #:energy 125.0 #:flying? #t))
        (for/list ([i (in-range 8)])
          (mk-unit (+ 2942 i) 'hydralisk 1 78.5 (+ 78.0 (* 0.5 i))))))
     (define enemies
       (list (mk-unit 6941 'siege-tank-sieged 4 87.5 79.5)
             (mk-unit 6942 'siege-tank-sieged 4 88.0 80.5)
             (mk-unit 6943 'thor 4 87.0 80.0)))
     (define s1 (mk-obs 12000 (append allies enemies) #:food-used 43 #:food-cap 66 #:food-army 19 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Zerg 'Terran (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define cast-spell? (wire-any-ability? wcmds (list viper-tag) (list AB-ABDUCT AB-BLINDING-CLOUD)))
     (define no-attack? (not (wire-has-ability? wcmds (list viper-tag) AB-ATTACK)))
     (values out
             (list
              (mk-check "viper-casts-abduct-or-blinding-cloud"
                        cast-spell?
                        (format "viper-2941 wire abs=~a (expected ~a ABDUCT or ~a BLINDING-CLOUD)"
                                (wire-abilities-for-tag wcmds viper-tag) AB-ABDUCT AB-BLINDING-CLOUD))
              (mk-check "viper-does-not-attack-dive"
                        no-attack?
                        (format "viper-2941 wire abs=~a" (wire-abilities-for-tag wcmds viper-tag))))))))

;; 41. Novel-19: Zerg Infestor Fungal Growth vs Clumped Marines
(define scen-novel-19
  (tactical-scenario
   "novel-19-zerg-infestor-fungal-growth-vs-bio"
   "novel" "Zerg" "Terran" "spellcasters"
   "Novel: Zerg Infestor (100en) within 8t of 10 clumped Marines casts Fungal Growth (74) without attack-diving"
   (lambda ()
     (define inf-tag 2951)
     (define allies
       (append
        (mk-home-base-units 'Zerg #:with-natural? #t)
        (list (mk-unit inf-tag 'infestor 1 80.0 80.0 #:energy 100.0))
        (for/list ([i (in-range 10)])
          (mk-unit (+ 2952 i) 'zergling 1 81.5 (+ 78.0 (* 0.4 i))))))
     (define enemies
       (for/list ([i (in-range 10)])
         (mk-unit (+ 6950 i) 'marine 4 (+ 87.5 (* 0.4 (modulo i 5))) (+ 79.5 (* 0.4 (quotient i 5))))))
     (define s1 (mk-obs 10400 (append allies enemies) #:food-used 31 #:food-cap 54 #:food-army 7 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Zerg 'Terran (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define cast-fungal? (wire-has-ability? wcmds (list inf-tag) AB-FUNGAL-GROWTH))
     (define no-attack? (not (wire-has-ability? wcmds (list inf-tag) AB-ATTACK)))
     (values out
             (list
              (mk-check "infestor-casts-fungal-growth-74"
                        cast-fungal?
                        (format "infestor-2951 wire abs=~a (expected ~a FUNGAL-GROWTH)"
                                (wire-abilities-for-tag wcmds inf-tag) AB-FUNGAL-GROWTH))
              (mk-check "infestor-does-not-attack-dive"
                        no-attack?
                        (format "infestor-2951 wire abs=~a" (wire-abilities-for-tag wcmds inf-tag))))))))

;; 42. Novel-20: Zerg Lurker Burrow in Combat Range & Unburrow When Clear
(define scen-novel-20
  (tactical-scenario
   "novel-20-zerg-lurker-burrow-and-unburrow-discipline"
   "novel" "Zerg" "Terran" "unit-mode-micro"
   "Novel: Unburrowed Lurker at 7t from Marines burrows (2108); Burrowed Lurker 50t from all enemies unburrows (2110)"
   (lambda ()
     (define lurk-close 2961)
     (define lurk-far   2962)
     (define allies
       (append
        (mk-home-base-units 'Zerg #:with-natural? #t)
        (list (mk-unit lurk-close 'lurker-mp 1 80.0 80.0)
              (mk-unit lurk-far   'lurker-mp-burrowed 1 36.0 36.0 #:burrowed? #t)
              (mk-unit 2963 'hydralisk 1 78.5 80.0)
              (mk-unit 2964 'hydralisk 1 78.5 81.0))))
     (define enemies
       (for/list ([i (in-range 6)])
         (mk-unit (+ 6960 i) 'marine 4 (+ 86.5 (* 0.4 i)) 80.0)))
     (define s1 (mk-obs 10800 (append allies enemies) #:food-used 34 #:food-cap 54 #:food-army 10 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Zerg 'Terran (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define burrowed? (wire-any-ability? wcmds (list lurk-close) (list AB-BURROW-LURKER AB-BURROW-DOWN)))
     (define unburrowed? (wire-any-ability? wcmds (list lurk-far) (list AB-UNBURROW-LURKER AB-BURROW-UP)))
     (values out
             (list
              (mk-check "lurker-burrows-in-range-of-marines"
                        burrowed?
                        (format "lurker-2961 abs=~a (expected ~a BURROW-LURKER)" (wire-abilities-for-tag wcmds lurk-close) AB-BURROW-LURKER))
              (mk-check "idle-far-lurker-unburrows-to-reposition"
                        unburrowed?
                        (format "lurker-2962 abs=~a (expected ~a UNBURROW-LURKER)" (wire-abilities-for-tag wcmds lurk-far) AB-UNBURROW-LURKER)))))))

;; =============================================================================
;; ROUND-3 PRO-INSPIRED STRESS SCENARIOS (novel-21 .. novel-32)
;; =============================================================================

;; 43. Novel-21 (W3-TAC-3): Bio Stutter-Step Cadence (`t02`/`t01` real-SC2 regression repro)
;;     14 Marines + 2 Medivacs at edge of weapon range (4.8t) vs 6 Stalkers + 3 Zealots with
;;     short remaining cooldown (5.0 loops = 0.223s on 0.61s Marine period) must NOT all emit
;;     pure MOVE(16) 5 tiles backwards out of weapon range (`StutterKiteBack` over-kiting)!
(define scen-novel-21
  (tactical-scenario
   "w3-tac-3-bio-no-overkite-out-of-range-vs-ranged"
   "wave3-repro" "Terran" "Protoss" "stutter-step-and-pullback"
   "Wave-3 Repro (W3-TAC-3 / t02): 14 Marines (w-cd=5.0 loops=0.22s) + 2 Medivacs at 4.8t vs 6 Stalkers + 3 Zealots must hold range/engage, not pure-MOVE 5t out of range"
   (lambda ()
     (define marine-tags (for/list ([i (in-range 14)]) (+ 3010 i)))
     (define enemy-tags (append (for/list ([i (in-range 6)]) (+ 7001 i))
                                (for/list ([i (in-range 3)]) (+ 7010 i))))
     (define allies
       (append
        (mk-home-base-units 'Terran #:with-natural? #t)
        (list (mk-unit 3001 'medivac 1 78.0 79.0 #:hp 150.0 #:hp-max 150.0 #:energy 100.0 #:flying? #t)
              (mk-unit 3002 'medivac 1 78.0 81.0 #:hp 150.0 #:hp-max 150.0 #:energy 100.0 #:flying? #t))
        (for/list ([t (in-list marine-tags)] [i (in-naturals)])
          ;; 5.0 loops = 0.223s remaining on 0.61s Marine period, standing at 4.8t (max range 5.0!)
          (mk-unit t 'marine 1 80.0 (+ 77.0 (* 0.4 i)) #:hp 45.0 #:hp-max 45.0 #:weapon-cooldown 5.0))))
     (define enemies
       (append
        (for/list ([i (in-range 6)])
          (mk-unit (+ 7001 i) 'stalker 4 84.8 (+ 78.0 (* 0.7 i)) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))
        (for/list ([i (in-range 3)])
          (mk-unit (+ 7010 i) 'zealot 4 84.5 (+ 79.0 (* 0.8 i)) #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0))))
     (define s1 (mk-obs 8200 (append allies enemies) #:food-used 42 #:food-cap 66 #:food-army 18 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Terran 'Protoss (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define pure-move-cnt (for/sum ([t (in-list marine-tags)]) (if (wire-pure-move-only? wcmds t) 1 0)))
     (define local-atk-cnt (wire-count-local-attacks wcmds marine-tags enemy-tags 84.8 80.0 14.0))
     (values out
             (list
              (mk-check "marines-at-edge-of-range-do-not-overkite-pure-move"
                        (and (<= pure-move-cnt 4) (>= local-atk-cnt 8))
                        (format "t02 Marines (w-cd=0.223s, dist=4.8t) vs 6 Stalkers+3 Zealots: pure-MOVE=~a/14, local-ATK=~a/14"
                                pure-move-cnt local-atk-cnt)))))))

;; 44. Novel-22: Nuclear Strike Calldown Evacuation (10-tile radius)
(define scen-novel-22
  (tactical-scenario
   "novel-22-nuke-calldown-evacuation"
   "novel" "Protoss" "Terran" "splash-evasion"
   "Novel: Protoss Stalkers + Immortals standing within 5t of an incoming enemy Nuke calldown must evacuate via MOVE(16)"
   (lambda ()
     (define army-tags '(3021 3022 3023 3024 3025 3026))
     (define allies
       (append
        (mk-home-base-units 'Protoss #:with-natural? #t)
        (for/list ([t (in-list army-tags)] [i (in-naturals)])
          (mk-unit t 'stalker 1 (+ 80.0 (* 0.5 (modulo i 3))) (+ 79.5 (* 0.5 (quotient i 3)))
                   #:shield 80.0 #:shield-max 80.0))))
     (define enemies
       (list (mk-unit 7021 'ghost 4 91.0 80.0 #:energy 50.0)
             (mk-unit 7022 'marine 4 90.0 80.0)))
     (define nuke-eff (sc2-effect 7 (list (sc2-point2d 81.5 80.0)) 4 2 8.0))
     (define s1 (mk-obs 12400 (append allies enemies)
                        #:food-used 36 #:food-cap 66 #:food-army 12 #:food-workers 24
                        #:effects (list nuke-eff)))
     (define overlay (hash 'nuke-alert (cons 81.5 80.0)))
     (define outs (run-pipeline-sequence 'Protoss 'Terran (list (hash 'obs s1 'overlay overlay))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define evading (wire-count-tags-with-ability wcmds army-tags AB-MOVE))
     (values out
             (list
              (mk-check "army-evacuates-nuke-calldown-zone"
                        (>= evading 5)
                        (format "stalkers emitting MOVE(16) out of Nuke zone=~a/6" evading))
              (mk-check "zero-wire-rejects-nuke-evasion"
                        (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; 45. Novel-23 (W3-TAC-6): Zerg Queen Transfuse Injured Ultralisk in Combat
;;     Both (a) combat Queen (with 2 home inject Queens at main+natural) fighting mid-map next to
;;     dying 120/500 HP Ultralisk AND (b) Queen defending near natural next to dying Ultralisk must
;;     prioritize Transfuse (1664) over L2 inject-larva (251) and 2*TH+2 home-recall MOVE(16).
(define scen-novel-23
  (tactical-scenario
   "w3-tac-6-queen-transfuse-injured-ultralisk"
   "wave3-repro" "Zerg" "Protoss" "spellcasters"
   "Wave-3 Repro (W3-TAC-6): Zerg Queen (75en) next to dying Ultralisk (120/500 HP) casts Transfuse (1664) instead of L2 inject-larva / home-recall"
   (lambda ()
     (define queen-tag 3031)
     (define ultra-tag 3032)
     ;; Part A: Forward combat Queen (with 2 dedicated inject Queens already at main & natural)
     (define allies-a
       (append
        (mk-home-base-units 'Zerg #:with-natural? #t)
        (list (mk-unit 3028 'queen 1 33.5 33.5 #:hp 175.0 #:hp-max 175.0 #:energy 50.0)
              (mk-unit 3029 'queen 1 53.5 35.5 #:hp 175.0 #:hp-max 175.0 #:energy 50.0)
              (mk-unit queen-tag 'queen 1 78.0 80.0 #:hp 175.0 #:hp-max 175.0 #:energy 75.0)
              (mk-unit ultra-tag 'ultralisk 1 80.5 80.0 #:hp 120.0 #:hp-max 500.0)
              (mk-unit 3033 'zergling 1 81.5 79.5)
              (mk-unit 3034 'zergling 1 81.5 80.5))))
     (define enemies-a
       (list (mk-unit 7031 'stalker 4 85.0 80.0 #:shield 80.0 #:shield-max 80.0)
             (mk-unit 7032 'stalker 4 85.5 81.0 #:shield 80.0 #:shield-max 80.0)))
     (define s1 (mk-obs 13000 (append allies-a enemies-a) #:food-used 38 #:food-cap 66 #:food-army 14 #:food-workers 24))
     (define out-a (last (run-pipeline-sequence 'Zerg 'Protoss (list (hash 'obs s1)))))
     (define wcmds-a (step-outcome-wire-cmds out-a))
     (define transfuse-midmap? (wire-has-ability? wcmds-a (list queen-tag) AB-TRANSFUSE))
     ;; Part B: Near-natural defense Queen (2.5t from dying Ultralisk, 11.3t from uninjected natural Hatchery)
     (define allies-b
       (append
        (mk-home-base-units 'Zerg #:with-natural? #t)
        (list (mk-unit queen-tag 'queen 1 60.0 42.0 #:hp 175.0 #:hp-max 175.0 #:energy 75.0)
              (mk-unit ultra-tag 'ultralisk 1 62.5 42.0 #:hp 120.0 #:hp-max 500.0))))
     (define enemies-b
       (list (mk-unit 7035 'stalker 4 67.0 42.0 #:shield 80.0 #:shield-max 80.0)))
     (define s2 (mk-obs 13020 (append allies-b enemies-b) #:food-used 34 #:food-cap 66 #:food-army 10 #:food-workers 24))
     (define out-b (last (run-pipeline-sequence 'Zerg 'Protoss (list (hash 'obs s2)))))
     (define wcmds-b (step-outcome-wire-cmds out-b))
     (define transfuse-nat? (wire-has-ability? wcmds-b (list queen-tag) AB-TRANSFUSE))
     (values out-a
             (list
              (mk-check "combat-queen-casts-transfuse-1664-not-home-recall"
                        transfuse-midmap?
                        (format "midmap queen-3031 wire abs=~a (expected ~a TRANSFUSE, not 16 home-recall)"
                                (wire-abilities-for-tag wcmds-a queen-tag) AB-TRANSFUSE))
              (mk-check "defending-queen-casts-transfuse-1664-not-l2-inject"
                        transfuse-nat?
                        (format "natural queen-3031 wire abs=~a (expected ~a TRANSFUSE, not 251 inject-larva)"
                                (wire-abilities-for-tag wcmds-b queen-tag) AB-TRANSFUSE)))))))

;; 46. Novel-24: Terran Ghost Steady Targeting (Snipe) vs Massive Zerg Bio (Ultralisk / Brood Lord)
(define scen-novel-24
  (tactical-scenario
   "novel-24-ghost-snipe-massive-zerg-bio"
   "novel" "Terran" "Zerg" "spellcasters"
   "Novel: Terran Ghosts (100en) at 8.5t from enemy Ultralisks + Brood Lord cast Snipe (2714)"
   (lambda ()
     (define ghost-tags '(3041 3042))
     (define allies
       (append
        (mk-home-base-units 'Terran #:with-natural? #t)
        (for/list ([t (in-list ghost-tags)] [i (in-naturals)])
          (mk-unit t 'ghost 1 79.0 (+ 79.5 (* 1.0 i)) #:energy 100.0))
        (for/list ([i (in-range 6)])
          (mk-unit (+ 3045 i) 'marauder 1 80.5 (+ 78.0 (* 0.6 i))))))
     (define enemies
       (list (mk-unit 7041 'ultralisk 4 87.0 79.5 #:hp 500.0 #:hp-max 500.0)
             (mk-unit 7042 'ultralisk 4 87.5 80.5 #:hp 500.0 #:hp-max 500.0)
             (mk-unit 7043 'brood-lord 4 88.0 80.0 #:hp 225.0 #:hp-max 225.0 #:flying? #t)))
     (define s1 (mk-obs 13500 (append allies enemies) #:food-used 40 #:food-cap 66 #:food-army 16 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define cast-snipe? (wire-has-ability? wcmds ghost-tags AB-SNIPE))
     (values out
             (list
              (mk-check "ghost-casts-snipe-2714-on-massive-bio"
                        cast-snipe?
                        (format "ghosts wire abs=~a (expected ~a SNIPE)"
                                (for/list ([t ghost-tags]) (cons t (wire-abilities-for-tag wcmds t)))
                                AB-SNIPE)))))))

;; 47. Novel-25: Protoss Sentry Guardian Shield vs Terran Ranged Bio
(define scen-novel-25
  (tactical-scenario
   "novel-25-sentry-guardian-shield-vs-ranged-bio"
   "novel" "Protoss" "Terran" "spellcasters"
   "Novel: Protoss Sentry (100en) alongside Stalkers+Zealots facing 12 Marines casts Guardian Shield (76)"
   (lambda ()
     (define sentry-tag 3051)
     (define allies
       (append
        (mk-home-base-units 'Protoss #:with-natural? #t)
        (list (mk-unit sentry-tag 'sentry 1 80.0 80.0 #:energy 100.0 #:shield 40.0 #:shield-max 40.0))
        (for/list ([i (in-range 6)])
          (mk-unit (+ 3052 i) 'stalker 1 79.5 (+ 78.0 (* 0.6 i)) #:shield 80.0 #:shield-max 80.0))
        (for/list ([i (in-range 4)])
          (mk-unit (+ 3060 i) 'zealot 1 81.5 (+ 78.5 (* 0.7 i)) #:shield 50.0 #:shield-max 50.0))))
     (define enemies
       (for/list ([i (in-range 12)])
         (mk-unit (+ 7050 i) 'marine 4 (+ 86.0 (* 0.4 (modulo i 6))) (+ 79.0 (* 0.5 (quotient i 6))))))
     (define s1 (mk-obs 7800 (append allies enemies) #:food-used 46 #:food-cap 66 #:food-army 22 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Protoss 'Terran (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define cast-gs? (wire-has-ability? wcmds (list sentry-tag) AB-GUARDIAN-SHIELD))
     (values out
             (list
              (mk-check "sentry-casts-guardian-shield-76"
                        cast-gs?
                        (format "sentry-3051 wire abs=~a (expected ~a GUARDIAN-SHIELD)"
                                (wire-abilities-for-tag wcmds sentry-tag) AB-GUARDIAN-SHIELD)))))))

;; 48. Novel-26: Protoss Carrier Interceptor Production & Standoff Leash
(define scen-novel-26
  (tactical-scenario
   "novel-26-carrier-interceptors-and-standoff-leash"
   "novel" "Protoss" "Terran" "unit-mobility-micro"
   "Novel: Protoss Carrier within 5.5t of enemy Marines builds Interceptors (1042) and kites back to standoff leash range"
   (lambda ()
     (define carrier-tag 3071)
     (define allies
       (append
        (mk-home-base-units 'Protoss #:with-natural? #t)
        (list (mk-unit carrier-tag 'carrier 1 80.0 80.0 #:hp 300.0 #:hp-max 300.0 #:shield 150.0 #:shield-max 150.0 #:flying? #t)
              (mk-unit 3072 'zealot 1 82.0 79.5 #:shield 50.0 #:shield-max 50.0)
              (mk-unit 3073 'zealot 1 82.0 80.5 #:shield 50.0 #:shield-max 50.0))))
     (define enemies
       (for/list ([i (in-range 6)])
         (mk-unit (+ 7070 i) 'marine 4 (+ 85.0 (* 0.4 i)) 80.0)))
     (define s1 (mk-obs 12500 (append allies enemies) #:minerals 400 #:vespene 200 #:food-used 34 #:food-cap 66 #:food-army 10 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Protoss 'Terran (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define build-int? (wire-has-ability? wcmds (list carrier-tag) AB-BUILD-INTERCEPTORS))
     (define kited-back? (wire-has-ability? wcmds (list carrier-tag) AB-MOVE))
     (values out
             (list
              (mk-check "carrier-builds-interceptors-1042"
                        build-int?
                        (format "carrier-3071 wire abs=~a (expected ~a BUILD-INTERCEPTORS)"
                                (wire-abilities-for-tag wcmds carrier-tag) AB-BUILD-INTERCEPTORS))
              (mk-check "carrier-kites-back-from-close-marines"
                        kited-back?
                        (format "carrier-3071 wire abs=~a (expected ~a MOVE standoff)"
                                (wire-abilities-for-tag wcmds carrier-tag) AB-MOVE)))))))

;; 49. Novel-27: Swarm Host Locust Wave Kite vs Exposed Swarm Host Punish
(define scen-novel-27
  (tactical-scenario
   "novel-27-locust-wave-kite-vs-exposed-swarm-host"
   "novel" "Terran" "Zerg" "splash-zone-discipline"
   "Novel: Facing temporary Swarm Host Locust wave with no exposed SH, Marines kite out; with exposed SH at 8t, Marines attack"
   (lambda ()
     (define bio-tags '(3081 3082 3083 3084 3085 3086))
     (define allies
       (append
        (mk-home-base-units 'Terran #:with-natural? #t)
        (for/list ([t (in-list bio-tags)] [i (in-naturals)])
          (mk-unit t 'marine 1 80.0 (+ 78.5 (* 0.5 i)) #:weapon-cooldown 0.0))))
     (define locusts
       (for/list ([i (in-range 8)])
         (mk-unit (+ 7080 i) 'locust 4 (+ 86.0 (* 0.4 (modulo i 4))) (+ 79.0 (* 0.5 (quotient i 4))))))
     ;; Step 1 & 2: Locusts only (triggers OWM locust-wave-active?, no exposed SH)
     (define s1 (mk-obs 9000 (append allies locusts) #:food-used 30 #:food-cap 54 #:food-army 6 #:food-workers 24))
     (define s2 (mk-obs 9020 (append allies locusts) #:food-used 30 #:food-cap 54 #:food-army 6 #:food-workers 24))
     (define outs-a (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s1) (hash 'obs s2))))
     (define out-a (last outs-a))
     (define wcmds-a (step-outcome-wire-cmds out-a))
     (define kiting-locusts (wire-count-tags-with-ability wcmds-a bio-tags AB-MOVE))
     ;; Part B: Exposed Swarm Host at 8t!
     (define sh-enemies (cons (mk-unit 7099 'swarm-host 4 87.5 80.0) locusts))
     (define s3 (mk-obs 9040 (append allies sh-enemies) #:food-used 30 #:food-cap 54 #:food-army 6 #:food-workers 24))
     (define outs-b (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s1) (hash 'obs s3))))
     (define out-b (last outs-b))
     (define wcmds-b (step-outcome-wire-cmds out-b))
     (define atk-sh (wire-count-local-attacks wcmds-b bio-tags (cons 7099 (for/list ([i (in-range 8)]) (+ 7080 i))) 87.0 80.0 16.0))
     (values out-b
             (list
              (mk-check "marines-kite-free-locust-wave-when-no-sh-exposed"
                        (>= kiting-locusts 4)
                        (format "locust-only MOVE(16)=~a/6" kiting-locusts))
              (mk-check "marines-engage-when-swarm-host-exposed"
                        (>= atk-sh 4)
                        (format "exposed-SH local ATTACK(23)=~a/6" atk-sh)))))))

;; 50. Novel-28 (W3-TAC-4a): High Templar Feedback High-Energy Enemy Spellcaster
;;     Exposes missing `'energy` field on `enemy-unit-records` in `sc2-protobuf-ws.rkt:4804-4833`.
(define scen-novel-28
  (tactical-scenario
   "w3-tac-4a-ht-feedback-high-energy-caster"
   "wave3-repro" "Protoss" "Terran" "spellcasters"
   "Wave-3 Repro (W3-TAC-4a): High Templar (60en < 75en Storm) facing 150en enemy Raven/Medivac casts Feedback (140) — requires enemy energy in obs hash"
   (lambda ()
     (define ht-tag 3101)
     (define allies
       (append
        (mk-home-base-units 'Protoss #:with-natural? #t)
        (list (mk-unit ht-tag 'high-templar 1 80.0 80.0 #:energy 60.0 #:shield 40.0 #:shield-max 40.0)
              (mk-unit 3102 'stalker 1 79.0 79.5 #:shield 80.0 #:shield-max 80.0)
              (mk-unit 3103 'stalker 1 79.0 80.5 #:shield 80.0 #:shield-max 80.0))))
     (define enemies
       (list (mk-unit 7101 'raven 4 86.5 80.0 #:energy 150.0 #:flying? #t)
             (mk-unit 7102 'medivac 4 87.0 81.0 #:energy 150.0 #:flying? #t)
             (mk-unit 7103 'marine 4 87.5 80.0)))
     (define s1 (mk-obs 10500 (append allies enemies)
                        #:food-used 30 #:food-cap 54 #:food-army 6 #:food-workers 24
                        #:upgrades '(psi-storm)))
     (define outs (run-pipeline-sequence 'Protoss 'Terran (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define cast-fb? (wire-has-ability? wcmds (list ht-tag) AB-FEEDBACK))
     (values out
             (list
              (mk-check "ht-casts-feedback-140-on-high-energy-caster"
                        cast-fb?
                        (format "ht-3101 wire abs=~a (expected ~a FEEDBACK; check enemy-unit-records 'energy)"
                                (wire-abilities-for-tag wcmds ht-tag) AB-FEEDBACK)))))))

;; 51. Novel-29: Warp Prism Rescue Pickup of Critically Injured Immortal
(define scen-novel-29
  (tactical-scenario
   "novel-29-warp-prism-injured-immortal-rescue"
   "novel" "Protoss" "Terran" "unit-mobility-micro"
   "Novel: Warp Prism adjacent to critically injured Immortal (30/200 HP, 0 Shield) rescues via Load (3668/911) and never attack-dives"
   (lambda ()
     (define prism-tag 3111)
     (define imm-tag   3112)
     (define allies
       (append
        (mk-home-base-units 'Protoss #:with-natural? #t)
        (list (mk-unit prism-tag 'warp-prism 1 79.0 80.0 #:hp 80.0 #:hp-max 80.0 #:shield 100.0 #:shield-max 100.0 #:flying? #t)
              (mk-unit imm-tag 'immortal 1 80.5 80.0 #:hp 30.0 #:hp-max 200.0 #:shield 0.0 #:shield-max 100.0)
              (mk-unit 3113 'stalker 1 79.5 79.0 #:shield 80.0 #:shield-max 80.0)
              (mk-unit 3114 'stalker 1 79.5 81.0 #:shield 80.0 #:shield-max 80.0))))
     (define enemies
       (list (mk-unit 7111 'marauder 4 85.0 79.5)
             (mk-unit 7112 'marauder 4 85.0 80.5)
             (mk-unit 7113 'marine 4 85.5 80.0)))
     (define s1 (mk-obs 9400 (append allies enemies) #:food-used 34 #:food-cap 54 #:food-army 10 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Protoss 'Terran (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define prism-abs (wire-abilities-for-tag wcmds prism-tag))
     (define loaded? (wire-any-ability? wcmds (list prism-tag) (list AB-LOAD-GENERIC AB-WARP-PRISM-LOAD)))
     (define no-atk? (not (memv AB-ATTACK prism-abs)))
     (values out
             (list
              (mk-check "warp-prism-loads-injured-immortal"
                        loaded?
                        (format "warp-prism-3111 wire abs=~a (expected ~a/~a LOAD)" prism-abs AB-LOAD-GENERIC AB-WARP-PRISM-LOAD))
              (mk-check "warp-prism-never-attack-dives"
                        no-atk?
                        (format "warp-prism-3111 wire abs=~a" prism-abs)))))))

;; 52. Novel-30: Incoming Enemy Corrosive Bile Impact Marker Evasion
(define scen-novel-30
  (tactical-scenario
   "novel-30-corrosive-bile-marker-evasion"
   "novel" "Protoss" "Zerg" "splash-evasion"
   "Novel: Protoss Immortals + Stalkers standing directly on an incoming enemy Corrosive Bile marker (effect 11) must evade via MOVE(16)"
   (lambda ()
     (define army-tags '(3121 3122 3123 3124))
     (define allies
       (append
        (mk-home-base-units 'Protoss #:with-natural? #t)
        (list (mk-unit 3121 'immortal 1 80.0 80.0 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0)
              (mk-unit 3122 'immortal 1 80.5 80.2 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0)
              (mk-unit 3123 'stalker  1 80.2 79.8 #:shield 80.0 #:shield-max 80.0)
              (mk-unit 3124 'stalker  1 80.4 80.4 #:shield 80.0 #:shield-max 80.0))))
     (define enemies
       (list (mk-unit 7121 'ravager 4 87.0 80.0)
             (mk-unit 7122 'roach 4 86.0 80.5)))
     (define bile-eff (sc2-effect 11 (list (sc2-point2d 80.2 80.0)) 4 2 0.5))
     (define s1 (mk-obs 8400 (append allies enemies)
                        #:food-used 36 #:food-cap 54 #:food-army 12 #:food-workers 24
                        #:effects (list bile-eff)))
     (define outs (run-pipeline-sequence 'Protoss 'Zerg (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define evading (wire-count-tags-with-ability wcmds army-tags AB-MOVE))
     (values out
             (list
              (mk-check "units-evade-corrosive-bile-marker"
                        (>= evading 3)
                        (format "units emitting MOVE(16) off Corrosive Bile=~a/4" evading)))))))

;; 53. Novel-31: Weapon Target-Domain Filtering (Ground-Only Roaches vs Flying Void Ray + Ground Zealot)
(define scen-novel-31
  (tactical-scenario
   "novel-31-ground-only-vs-flying-target-filtering"
   "novel" "Zerg" "Protoss" "focus-fire"
   "Novel: Mixed Roaches (ground-only) + Hydralisks (air+ground) vs Void Ray (flying) + Zealot (ground) — Roaches MUST NOT target flying Void Ray!"
   (lambda ()
     (define roach-tags '(3131 3132 3133 3134))
     (define hydra-tags '(3135 3136 3137 3138))
     (define voidray-tag 7131)
     (define zealot-tag  7132)
     (define allies
       (append
        (mk-home-base-units 'Zerg #:with-natural? #t)
        (for/list ([t (in-list roach-tags)] [i (in-naturals)])
          (mk-unit t 'roach 1 80.0 (+ 78.8 (* 0.6 i)) #:weapon-cooldown 0.0))
        (for/list ([t (in-list hydra-tags)] [i (in-naturals)])
          (mk-unit t 'hydralisk 1 78.5 (+ 78.8 (* 0.6 i)) #:weapon-cooldown 0.0))))
     (define enemies
       (list (mk-unit voidray-tag 'void-ray 4 83.5 79.5 #:flying? #t #:hp 150.0 #:hp-max 150.0 #:shield 100.0 #:shield-max 100.0)
             (mk-unit zealot-tag  'zealot   4 84.5 79.8 #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0)))
     (define s1 (mk-obs 8600 (append allies enemies) #:food-used 40 #:food-cap 66 #:food-army 16 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Zerg 'Protoss (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define roach-tgts (wire-targets-for-tags wcmds roach-tags AB-ATTACK))
     (define hydra-tgts (wire-targets-for-tags wcmds hydra-tags AB-ATTACK))
     (define roach-hits-air? (for/or ([e (in-list roach-tgts)]) (= (second e) voidray-tag)))
     (define roach-hits-ground? (for/or ([e (in-list roach-tgts)]) (= (second e) zealot-tag)))
     (define hydra-hits-air? (for/or ([e (in-list hydra-tgts)]) (= (second e) voidray-tag)))
     (values out
             (list
              (mk-check "ground-only-roaches-never-target-flying-void-ray"
                        (and (not roach-hits-air?) roach-hits-ground?)
                        (format "roach attack targets=~a (must hit zealot ~a, never flying void-ray ~a)"
                                roach-tgts zealot-tag voidray-tag))
              (mk-check "hydralisks-target-air-threat-void-ray"
                        hydra-hits-air?
                        (format "hydra attack targets=~a (expected void-ray ~a)" hydra-tgts voidray-tag)))))))

;; 54. Novel-32: Enemy Changeling Snipe & Friendly Observer Non-Dive Preservation
(define scen-novel-32
  (tactical-scenario
   "novel-32-changeling-snipe-and-observer-preservation"
   "novel" "Protoss" "Zerg" "detection-and-anti-air"
   "Novel: Friendly Stalkers snipe nearby enemy ChangelingZealot while friendly Observer NEVER receives suicide ATTACK(23)"
   (lambda ()
     (define stalker-tags '(3141 3142 3143))
     (define obs-tag 3144)
     (define changeling-tag 7141)
     (define allies
       (append
        (mk-home-base-units 'Protoss #:with-natural? #t)
        (for/list ([t (in-list stalker-tags)] [i (in-naturals)])
          (mk-unit t 'stalker 1 54.0 (+ 31.0 (* 0.8 i)) #:shield 80.0 #:shield-max 80.0))
        (list (mk-unit obs-tag 'observer 1 56.0 32.0 #:flying? #t #:hp 40.0 #:hp-max 40.0 #:shield 20.0 #:shield-max 20.0))))
     (define enemies
       (list (mk-unit changeling-tag 'changeling-zealot 4 57.5 32.0 #:hp 5.0 #:hp-max 5.0)
             (mk-unit 7142 'hydralisk 4 64.0 32.0)))
     (define s1 (mk-obs 7200 (append allies enemies) #:food-used 31 #:food-cap 54 #:food-army 7 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Protoss 'Zerg (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define obs-abs (wire-abilities-for-tag wcmds obs-tag))
     (define any-snipe?
       (for/or ([e (in-list (wire-targets-for-tags wcmds stalker-tags AB-ATTACK))])
         (memv (second e) (list changeling-tag 7142))))
     (values out
             (list
              (mk-check "stalkers-engage-changeling-or-hydra"
                        any-snipe?
                        (format "stalkers attack targets=~a" (wire-targets-for-tags wcmds stalker-tags AB-ATTACK)))
              (mk-check "observer-never-attack-dives"
                        (not (memv AB-ATTACK obs-abs))
                        (format "observer-3144 wire abs=~a (must never get ATTACK 23)" obs-abs)))))))

;; 55. Novel-33 (W3-TAC-4b): Terran Ghost EMP vs Zerg High-Energy Infestors & Vipers (0 Shields)
;;     Exposes missing `'energy` on `enemy-unit-records` (`sc2-protobuf-ws.rkt:4804-4833`):
;;     Ghost EMP worked in TvP (via `'shield`), but is 100% dead vs Zerg/Terran casters (0 shields)!
(define scen-novel-33
  (tactical-scenario
   "w3-tac-4b-ghost-emp-vs-zerg-infestor-viper"
   "wave3-repro" "Terran" "Zerg" "spellcasters"
   "Wave-3 Repro (W3-TAC-4b): Terran Ghost (100en) facing high-energy Zerg Infestors+Vipers (0 shields, 150en) casts EMP (1628)"
   (lambda ()
     (define ghost-tags '(3151 3152))
     (define allies
       (append
        (mk-home-base-units 'Terran #:with-natural? #t)
        (for/list ([t (in-list ghost-tags)] [i (in-naturals)])
          (mk-unit t 'ghost 1 79.0 (+ 79.5 (* 1.0 i)) #:energy 100.0))
        (for/list ([i (in-range 8)])
          (mk-unit (+ 3155 i) 'marine 1 80.0 (+ 78.0 (* 0.5 i))))))
     (define enemies
       (list (mk-unit 7151 'infestor 4 86.5 79.5 #:hp 90.0 #:hp-max 90.0 #:energy 150.0)
             (mk-unit 7152 'infestor 4 87.0 80.2 #:hp 90.0 #:hp-max 90.0 #:energy 150.0)
             (mk-unit 7153 'viper    4 86.8 79.8 #:hp 150.0 #:hp-max 150.0 #:energy 175.0 #:flying? #t)))
     (define s1 (mk-obs 12600 (append allies enemies) #:food-used 40 #:food-cap 66 #:food-army 16 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define cast-emp? (wire-has-ability? wcmds ghost-tags AB-EMP))
     (values out
             (list
              (mk-check "ghost-casts-emp-1628-on-high-energy-zerg-casters"
                        cast-emp?
                        (format "ghosts wire abs=~a (expected ~a EMP; check enemy-unit-records 'energy)"
                                (for/list ([t ghost-tags]) (cons t (wire-abilities-for-tag wcmds t)))
                                AB-EMP)))))))

;; 56. Novel-34 (W3-TAC-5): Protobuf Transport Cargo Decoding & Unload (`passengers` / `cargo_space_taken`)
;;     Encodes a real SC2 protobuf `ResponseObservation` wire packet with a loaded Medivac
;;     (`cargo_space_taken=8`, `cargo_space_max=8`, `passengers=[Marine x4]`) arriving at an enemy
;;     drop zone -> decodes via `decode-sc2-response` -> `sc2-observation->runtime-obs-hash` ->
;;     `step-live-bot-runtime!` -> checks runtime hash exposes `'cargo-space-taken > 0` AND Medivac unloads!
(define scen-novel-34
  (tactical-scenario
   "w3-tac-5-loaded-transport-cargo-decode-and-unload"
   "wave3-repro" "Terran" "Protoss" "unit-mobility-micro"
   "Wave-3 Repro (W3-TAC-5): Protobuf Unit fields 24-26 (passengers/cargo_space_taken) must decode into obs hash so loaded Medivac unloads (396/3669)"
   (lambda ()
     (define med-tag 3161)
     (define passengers
       (for/list ([i (in-range 4)])
         (pb-encode-passenger (+ 3170 i) 48 45.0 45.0)))
     (define pb-units
       (list
        ;; Home Command Center + Natural Command Center + 2 SCVs + 2 neutral mineral patches + 4 home Marines
        (pb-encode-unit 1 18 1 1 32.0 32.0 #:hp 1500.0 #:hp-max 1500.0)
        (pb-encode-unit 2 18 1 1 52.0 34.0 #:hp 1500.0 #:hp-max 1500.0)
        (pb-encode-unit 10 45 1 1 28.0 31.0 #:hp 45.0 #:hp-max 45.0)
        (pb-encode-unit 11 45 1 1 28.0 33.0 #:hp 45.0 #:hp-max 45.0)
        (pb-encode-unit 90001 341 3 16 25.0 31.0 #:hp 1500.0 #:hp-max 1500.0)
        (pb-encode-unit 90002 341 3 16 25.0 33.0 #:hp 1500.0 #:hp-max 1500.0)
        (pb-encode-unit 3165 48 1 1 54.0 34.0 #:hp 45.0 #:hp-max 45.0)
        (pb-encode-unit 3166 48 1 1 54.5 34.0 #:hp 45.0 #:hp-max 45.0)
        (pb-encode-unit 3167 48 1 1 54.0 35.0 #:hp 45.0 #:hp-max 45.0)
        (pb-encode-unit 3168 48 1 1 54.5 35.0 #:hp 45.0 #:hp-max 45.0)
        ;; Loaded Medivac arriving at enemy mineral line (157.0, 158.0) with 4 Marines (cargo=4/8)
        (pb-encode-unit med-tag 54 1 1 157.0 158.0
                        #:hp 150.0 #:hp-max 150.0 #:energy 100.0 #:flying? #t
                        #:passengers passengers #:cargo-taken 4 #:cargo-max 8)
        ;; Enemy Nexus + Probes at (160, 160), no anti-air
        (pb-encode-unit 7161 59 4 2 160.0 160.0 #:hp 1000.0 #:hp-max 1000.0)
        (pb-encode-unit 7162 84 4 2 164.0 160.0 #:hp 20.0 #:hp-max 20.0)
        (pb-encode-unit 7163 84 4 2 164.0 161.0 #:hp 20.0 #:hp-max 20.0)))
     ;; 2-step sequence (9200 -> 9224, +24f >= MIN-CARRY-DWELL-FRAMES=18) so transport-drop-micro
     ;; clears intentional carry-dwell before unloading at the enemy mineral line.
     (define decoded-obs-1 (sc2-response-observation (decode-sc2-response (pb-encode-response-obs 9200 pb-units))))
     (define decoded-obs-2 (sc2-response-observation (decode-sc2-response (pb-encode-response-obs 9224 pb-units))))
     (define gi (make-standard-game-info 'Terran 'Protoss))
     (define rt-obs (sc2-observation->runtime-obs-hash decoded-obs-1 #:game-info gi #:configured-race 'Terran))
     (define med-rec (findf (lambda (u) (eqv? (hash-ref u 'id -1) med-tag))
                            (hash-ref rt-obs 'ally-units '())))
     (define decoded-cargo (if (hash? med-rec) (hash-ref med-rec 'cargo-space-taken 0) 0))
     (define decoded-pax   (if (hash? med-rec) (length (hash-ref med-rec 'passengers '())) 0))
     (define outs (run-pipeline-sequence 'Terran 'Protoss (list (hash 'obs decoded-obs-1) (hash 'obs decoded-obs-2))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define unloaded?
       (for/or ([o (in-list outs)])
         (wire-any-ability? (step-outcome-wire-cmds o) (list med-tag) (list AB-MEDIVAC-UNLOAD-ALL-AT AB-UNLOAD-ALL-AT))))
     (values out
             (list
              (mk-check "protobuf-decodes-cargo-space-taken-and-passengers"
                        (and (> decoded-cargo 0) (> decoded-pax 0))
                        (format "decoded medivac-3161 cargo-space-taken=~a passengers=~a (expected >0; check sc2-protobuf-ws fields 24-26)"
                                decoded-cargo decoded-pax))
              (mk-check "loaded-medivac-unloads-at-enemy-mineral-line"
                        unloaded?
                        (format "medivac-3161 wire abs (step1/step2)=~a/~a (expected ~a/~a UNLOAD)"
                                (wire-abilities-for-tag (step-outcome-wire-cmds (first outs)) med-tag)
                                (wire-abilities-for-tag wcmds med-tag)
                                AB-MEDIVAC-UNLOAD-ALL-AT AB-UNLOAD-ALL-AT)))))))

;; 57. Novel-35 (W3-TAC-7): Empty Frontline Medivacs Never Stolen Into Suicide Harass to Enemy Main
;;     Exposes `bot-runtime.rkt:23300`: `frontline-combat-engaged?` explicitly exempted `medivac`,
;;     causing `step-multitask-harass-and-proxy` to send empty frontline Medivacs `(move ... 160 160)`
;;     straight over enemy Stalkers into the enemy main base whenever Marines are full HP!
(define scen-novel-35
  (tactical-scenario
   "w3-tac-7-empty-frontline-medivac-never-suicide-harass"
   "wave3-repro" "Terran" "Protoss" "support-preservation"
   "Wave-3 Repro (W3-TAC-7): Empty Medivacs supporting full-HP frontline Marines at (80,80) vs Stalkers must NEVER fly solo to enemy main (160,160)"
   (lambda ()
     (define med-tags '(3181 3182))
     (define allies
       (append
        (mk-home-base-units 'Terran #:with-natural? #t)
        (list (mk-unit 3181 'medivac 1 78.0 79.0 #:hp 150.0 #:hp-max 150.0 #:energy 100.0 #:flying? #t)
              (mk-unit 3182 'medivac 1 78.0 81.0 #:hp 150.0 #:hp-max 150.0 #:energy 100.0 #:flying? #t))
        (for/list ([i (in-range 14)])
          (mk-unit (+ 3185 i) 'marine 1 80.0 (+ 77.0 (* 0.4 i)) #:hp 45.0 #:hp-max 45.0 #:weapon-cooldown 0.0))))
     (define enemies
       (for/list ([i (in-range 6)])
         (mk-unit (+ 7181 i) 'stalker 4 85.0 (+ 78.0 (* 0.7 i)) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0)))
     (define s1 (mk-obs 8200 (append allies enemies) #:food-used 42 #:food-cap 66 #:food-army 18 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Terran 'Protoss (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define suicide-fly-pts
       (for/list ([c (in-list (filter sc2-raw-unit-command? wcmds))]
                  #:when (and (ormap (lambda (t) (memv t (sc2-raw-unit-command-unit-tags c))) med-tags)
                              (sc2-raw-unit-command-target-pos c)
                              (> (dist2d-xy (sc2-point2d-x (sc2-raw-unit-command-target-pos c))
                                            (sc2-point2d-y (sc2-raw-unit-command-target-pos c))
                                            80.0 80.0)
                                 30.0)))
         (list (sc2-raw-unit-command-ability-id c)
               (sc2-point2d-x (sc2-raw-unit-command-target-pos c))
               (sc2-point2d-y (sc2-raw-unit-command-target-pos c)))))
     (values out
             (list
              (mk-check "empty-frontline-medivacs-do-not-fly-to-enemy-base"
                        (null? suicide-fly-pts)
                        (format "medivac long-range moves (>30t from army)=~a (must be empty; check bot-runtime.rkt:23300)"
                                suicide-fly-pts)))))))

;; 58. Novel-36 (W3-TAC-8): Frontline Combat Units Never Stolen by L2 `periodic-scout`
;;     Exposes `bot-runtime.rkt:9242-9251`: L2 `periodic-scout` picks `argmin dist(enemy-base)`
;;     from ALL combat units (literally the point-man Zealot/Marine fighting 2t from enemies!)
;;     and emits `MOVE(16)` to the enemy base, which `PRESERVED-ECON-HEAD-SET` protects over combat!
(define scen-novel-36
  (tactical-scenario
   "w3-tac-8-periodic-scout-never-steals-frontline-unit"
   "wave3-repro" "Protoss" "Terran" "melee-engage"
   "Wave-3 Repro (W3-TAC-8): Mixed Protoss (4 Zealots + 8 Stalkers fighting 14 Marines at 2t) — ZERO frontline Zealots stolen by L2 periodic-scout MOVE(16)"
   (lambda ()
     (define zealot-tags '(3201 3202 3203 3204))
     (define stalker-tags '(3210 3211 3212 3213 3214 3215 3216 3217))
     (define enemy-tags (for/list ([i (in-range 14)]) (+ 7201 i)))
     (define allies
       (append
        (mk-home-base-units 'Protoss #:with-natural? #t)
        (for/list ([t (in-list zealot-tags)] [i (in-naturals)])
          (mk-unit t 'zealot 1 83.0 (+ 79.0 (* 0.5 i)) #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0 #:weapon-cooldown 6.0))
        (for/list ([t (in-list stalker-tags)] [i (in-naturals)])
          (mk-unit t 'stalker 1 79.5 (+ 78.0 (* 0.5 i)) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0 #:weapon-cooldown 12.0))))
     (define enemies
       (for/list ([t (in-list enemy-tags)] [i (in-naturals)])
         (mk-unit t 'marine 4 85.0 (+ 77.5 (* 0.4 i)) #:hp 45.0 #:hp-max 45.0)))
     (define s1 (mk-obs 8200 (append allies enemies) #:food-used 48 #:food-cap 66 #:food-army 24 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Protoss 'Terran (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define z-pure-move (for/sum ([t (in-list zealot-tags)]) (if (wire-pure-move-only? wcmds t) 1 0)))
     (define z-atk (wire-count-local-attacks wcmds zealot-tags enemy-tags 85.0 80.0 12.0))
     (values out
             (list
              (mk-check "zero-frontline-zealots-stolen-by-periodic-scout-or-kite"
                        (and (= z-pure-move 0) (= z-atk 4))
                        (format "frontline Zealots (2t from 14 Marines): pure-MOVE=~a/4, local-ATK=~a/4 (check bot-runtime.rkt:9242 periodic-scout)"
                                z-pure-move z-atk)))))))

;; 59. W3-P0-1: Zerg `SwarmVictory` 14m Stall vs Fog/Snapshot Enemy Main Buildings (`#7 Z v Chance`)
;;     Exposes the triple trap when `45` Lings + `10` Roaches + `9` Hydras (`supply=120 < 155`,
;;     `SwarmVictory`, `0` visible enemy army) face `display_type=2` Snapshot enemy buildings at
;;     `(136..175, 76..80)`:
;;     1) `fog-belief-suppress?` (`L18290`) hallucinates a phantom army -> `combat-suppress-attack?=#t`
;;     2) `l34-phase5b-engage!` sends `51/64` units on pure `MOVE(16)` back to own 3rd `(72.5,45.0)`
;;     3) `endgame-building-hunt` (`L22267-22268`) skips because BOTH `(null? sweep-active-enemies)`
;;        AND `(not bldg-at-known-base?)` are `#f` when Snapshot `enemy-bldgs` sit at enemy main!
(define scen-w3-p0-1
  (tactical-scenario
   "w3-p0-1-zerg-swarm-victory-attacks-snapshot-enemy-base"
   "wave3-repro" "Zerg" "Protoss" "endgame-hunt"
   "Wave-3 Repro (W3-P0-1 / #7 Z v Chance): 64-unit Zerg SwarmVictory army vs Snapshot enemy Protoss buildings at (136..175, 76..80) must ATTACK enemy base, not MOVE(16) home"
   (lambda ()
     (define ling-tags  (for/list ([i (in-range 45)]) (+ 3000 i)))
     (define roach-tags (for/list ([i (in-range 10)]) (+ 3100 i)))
     (define hydra-tags (for/list ([i (in-range 9)])  (+ 3200 i)))
     (define army-tags  (append ling-tags roach-tags hydra-tags))
     (define allies
       (append
        (list (mk-unit 1 'hatchery 1 32.0 32.0 #:hp 1500.0 #:hp-max 1500.0)
              (mk-unit 2 'hatchery 1 52.0 34.0 #:hp 1500.0 #:hp-max 1500.0)
              (mk-unit 3 'hatchery 1 72.0 36.0 #:hp 1500.0 #:hp-max 1500.0)
              (mk-unit 4 'spawning-pool 1 35.0 36.0 #:hp 1000.0 #:hp-max 1000.0))
        (for/list ([i (in-range 20)])
          (mk-unit (+ 10 i) 'drone 1 28.0 (+ 28.0 (* 0.4 i)) #:hp 40.0 #:hp-max 40.0))
        (for/list ([t (in-list ling-tags)] [i (in-naturals)])
          (mk-unit t 'zergling 1 (+ 55.0 (* 0.4 (modulo i 15))) (+ 42.0 (* 0.4 (quotient i 15))) #:hp 35.0 #:hp-max 35.0))
        (for/list ([t (in-list roach-tags)] [i (in-naturals)])
          (mk-unit t 'roach 1 (+ 56.0 (* 0.6 i)) 45.0 #:hp 145.0 #:hp-max 145.0))
        (for/list ([t (in-list hydra-tags)] [i (in-naturals)])
          (mk-unit t 'hydralisk 1 (+ 55.0 (* 0.6 i)) 47.0 #:hp 90.0 #:hp-max 90.0))))
     ;; Snapshot (display_type=2) enemy Protoss main + Gateway/wall buildings, 0 visible enemy army
     ;; Matches #7 Z v Chance where OWM infers phantom enemy army from production buildings in fog.
     (define enemies
       (list (mk-unit 7001 'nexus 4 175.0 76.0 #:hp 1000.0 #:hp-max 1000.0 #:shield 1000.0 #:shield-max 1000.0 #:display-type 2 #:cloak 3)
             (mk-unit 7002 'gateway 4 136.0 80.0 #:hp 500.0 #:hp-max 500.0 #:shield 500.0 #:shield-max 500.0 #:display-type 2 #:cloak 3)
             (mk-unit 7003 'gateway 4 141.0 86.0 #:hp 500.0 #:hp-max 500.0 #:shield 500.0 #:shield-max 500.0 #:display-type 2 #:cloak 3)
             (mk-unit 7004 'robotics-facility 4 146.0 83.0 #:hp 450.0 #:hp-max 450.0 #:shield 450.0 #:shield-max 450.0 #:display-type 2 #:cloak 3)))
     (define s1 (mk-obs 12000 (append allies enemies)
                        #:minerals 1200 #:vespene 600
                        #:food-used 120 #:food-cap 180 #:food-army 75 #:food-workers 45))
     (define s2 (mk-obs 12600 (append allies enemies)
                        #:minerals 1200 #:vespene 600
                        #:food-used 120 #:food-cap 180 #:food-army 75 #:food-workers 45))
     (define outs (run-pipeline-sequence 'Zerg 'Protoss (list (hash 'obs s1) (hash 'obs s2))
                                         #:enemy-x 175.0 #:enemy-y 76.0))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define ucmds (filter sc2-raw-unit-command? wcmds))
     (define atk-enemy-side-tags
       (let ([st (mutable-seteqv)])
         (for ([c (in-list ucmds)]
               #:when (= (sc2-raw-unit-command-ability-id c) AB-ATTACK))
           (define tp (sc2-raw-unit-command-target-pos c))
           (define tt (sc2-raw-unit-command-target-unit-tag c))
           (when (or (memv tt '(7001 7002 7003))
                     (and (sc2-point2d? tp) (>= (sc2-point2d-x tp) 110.0)))
             (for ([t (in-list (sc2-raw-unit-command-unit-tags c))]
                   #:when (memv t army-tags))
               (set-add! st t))))
         (set-count st)))
     (define home-move-tags
       (let ([st (mutable-seteqv)])
         (for ([c (in-list ucmds)]
               #:when (= (sc2-raw-unit-command-ability-id c) AB-MOVE))
           (define tp (sc2-raw-unit-command-target-pos c))
           (when (and (sc2-point2d? tp) (<= (sc2-point2d-x tp) 90.0))
             (for ([t (in-list (sc2-raw-unit-command-unit-tags c))]
                   #:when (memv t army-tags))
               (set-add! st t))))
         (set-count st)))
     (values out
             (list
              (mk-check "swarm-victory-attacks-snapshot-enemy-base"
                        (>= atk-enemy-side-tags 40)
                        (format "army units attacking enemy half (x>=110)=~a/64 (expected >=40; home-MOVE=~a/64)"
                                atk-enemy-side-tags home-move-tags))
              (mk-check "swarm-victory-does-not-move-home-under-fog-suppress"
                        (<= home-move-tags 8)
                        (format "army units sent pure MOVE(16) to own half (x<=90)=~a/64 (expected <=8)"
                                home-move-tags)))))))

;; =============================================================================
;; ROUND-4 WAVE-4 REPROS (w4-tac-1..3) & PRO-INSPIRED STRESS SCENARIOS (novel-37..48)
;; =============================================================================

;; 62. W4-TAC-1 (from real-SC2 t04: 1.26x W -> 0.15x T): Ghost Snipe Priority vs Close Ultralisks
;;     2 Ghosts (100en) + Bio facing 2 close Ultralisks (7.0t, 500 HP) + 2 Infestors (120en):
;;     Ghost #1 burns 75en on EMP first (leaving 25en -> 0 Snipes!), AND Ghost #2 Snipes
;;     the already-EMP'd 90-HP Infestor (7303) because `ghost-snipe-weight` ranks infestor=124 > ultralisk=115!
;;     At least 1 Ghost MUST cast Snipe (2714) directly on a closing Ultralisk (7301/7302)!
(define scen-w4-tac-1
  (tactical-scenario
   "w4-tac-1-ghost-snipe-over-emp-vs-close-ultralisks"
   "wave4-repro" "Terran" "Zerg" "spellcasters"
   "Wave-4 Repro (W4-TAC-1 / t04): Ghosts (100en) facing 2 close Ultralisks (500 HP) + 2 Infestors must Snipe (2714) an Ultralisk, not EMP-starve or Snipe an EMP'd Infestor"
   (lambda ()
     (define ghost-tags '(3301 3302))
     (define ultra-tags '(7301 7302))
     (define allies
       (append
        (mk-home-base-units 'Terran #:with-natural? #t)
        (for/list ([t (in-list ghost-tags)] [i (in-naturals)])
          (mk-unit t 'ghost 1 78.5 (+ 79.5 (* 1.0 i)) #:energy 100.0))
        (list (mk-unit 3303 'medivac 1 77.5 80.0 #:energy 100.0 #:flying? #t))
        (for/list ([i (in-range 8)])
          (mk-unit (+ 3310 i) 'marine 1 80.0 (+ 78.0 (* 0.5 i))))
        (for/list ([i (in-range 4)])
          (mk-unit (+ 3320 i) 'marauder 1 80.5 (+ 79.0 (* 0.6 i))))))
     (define enemies
       (list (mk-unit 7301 'ultralisk 4 85.5 79.5 #:hp 500.0 #:hp-max 500.0)
             (mk-unit 7302 'ultralisk 4 85.5 80.5 #:hp 500.0 #:hp-max 500.0)
             (mk-unit 7303 'infestor  4 87.0 79.5 #:hp 90.0 #:hp-max 90.0 #:energy 120.0)
             (mk-unit 7304 'infestor  4 87.2 80.2 #:hp 90.0 #:hp-max 90.0 #:energy 120.0)))
     (define s1 (mk-obs 13800 (append allies enemies) #:food-used 46 #:food-cap 66 #:food-army 22 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define snipe-targets
       (for/list ([c (in-list wcmds)]
                  #:when (and (sc2-raw-unit-command? c)
                              (= (sc2-raw-unit-command-ability-id c) AB-SNIPE)
                              (ormap (lambda (t) (memv t ghost-tags)) (sc2-raw-unit-command-unit-tags c))))
         (sc2-raw-unit-command-target-unit-tag c)))
     (define sniped-ultra? (ormap (lambda (tt) (memv tt ultra-tags)) snipe-targets))
     (values out
             (list
              (mk-check "ghost-snipes-closing-ultralisk-2714-not-emp-starved-or-infestor"
                        sniped-ultra?
                        (format "ghosts wire abs=~a snipe-targets=~a (expected ~a SNIPE on Ultralisk 7301/7302)"
                                (for/list ([t ghost-tags]) (cons t (wire-abilities-for-tag wcmds t)))
                                snipe-targets AB-SNIPE)))))))

;; 63. W4-TAC-2 (from real-SC2 p05: 0.05x T): High Templars Never Mid-Fight Archon Merge
;;     2 High Templars (65en, ready for Feedback!) + 2 Archons fighting close Hydralisks + Zerglings (6.5t):
;;     Both L2 (`bot-runtime.rkt:14171-14190`) and `sc2-protobuf-ws.rkt:7326` lack a combat-proximity guard
;;     and only reserve >=75en HTs, emitting wire `1766 MORPH-ARCHON` right in the middle of combat!
(define scen-w4-tac-2
  (tactical-scenario
   "w4-tac-2-ht-no-midfight-archon-merge-with-energy"
   "wave4-repro" "Protoss" "Zerg" "spellcasters"
   "Wave-4 Repro (W4-TAC-2 / p05): 2 energized HTs (65en) fighting close Hydras+Lings (6.5t) must NEVER emit mid-fight MORPH-ARCHON (1766)"
   (lambda ()
     (define ht-tags '(3331 3332))
     (define allies
       (append
        (mk-home-base-units 'Protoss #:with-natural? #t)
        (list (mk-unit 3331 'high-templar 1 78.5 79.5 #:energy 65.0 #:shield 40.0 #:shield-max 40.0)
              (mk-unit 3332 'high-templar 1 78.5 80.5 #:energy 65.0 #:shield 40.0 #:shield-max 40.0)
              (mk-unit 3333 'archon 1 80.5 79.5 #:hp 10.0 #:hp-max 10.0 #:shield 350.0 #:shield-max 350.0)
              (mk-unit 3334 'archon 1 80.5 80.5 #:hp 10.0 #:hp-max 10.0 #:shield 350.0 #:shield-max 350.0))
        (for/list ([i (in-range 4)])
          (mk-unit (+ 3335 i) 'stalker 1 79.5 (+ 78.5 (* 0.8 i)) #:shield 80.0 #:shield-max 80.0))))
     (define enemies
       (append
        (for/list ([i (in-range 8)])
          (mk-unit (+ 7331 i) 'hydralisk 4 86.0 (+ 78.0 (* 0.5 i))))
        (for/list ([i (in-range 8)])
          (mk-unit (+ 7340 i) 'zergling 4 84.5 (+ 78.5 (* 0.4 i))))))
     (define s1 (mk-obs 11400 (append allies enemies) #:food-used 46 #:food-cap 66 #:food-army 22 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Protoss 'Zerg (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define merged? (wire-has-ability? wcmds ht-tags AB-MORPH-ARCHON))
     (values out
             (list
              (mk-check "energized-hts-never-midfight-archon-merge"
                        (not merged?)
                        (format "ht wire abs=~a (must NOT emit ~a MORPH-ARCHON mid-fight with enemies 6.5t away!)"
                                (for/list ([t ht-tags]) (cons t (wire-abilities-for-tag wcmds t)))
                                AB-MORPH-ARCHON)))))))

;; 64. W4-TAC-3 (from real-SC2 t01: 0.27x 15A/84M & p03: 0.12x 16A/66M):
;;     Ranged Units in DisengageRetreat Just Outside Weapon Range (`5.9t`) While Longer-Range
;;     Enemies (`6.0t` Stalkers) Shoot Them For Free Must Not Pure-MOVE(16) With Ready Weapon (`w-cd=0`)!
(define scen-w4-tac-3
  (tactical-scenario
   "w4-tac-3-ranged-retreat-ready-weapon-fires-vs-pursuers"
   "wave4-repro" "Terran" "Protoss" "stutter-step-and-pullback"
   "Wave-4 Repro (W4-TAC-3 / t01): Marines with READY weapon (w-cd=0) at 5.9t from pursuing 6-range Stalkers+Zealots must step-fire, not pure-MOVE at 0 DPS"
   (lambda ()
     (define marine-tags (for/list ([i (in-range 10)]) (+ 3360 i)))
     (define enemy-tags (append (for/list ([i (in-range 5)]) (+ 7360 i))
                                (for/list ([i (in-range 4)]) (+ 7370 i))))
     (define allies
       (append
        (mk-home-base-units 'Terran #:with-natural? #t)
        (list (mk-unit 3359 'medivac 1 77.0 80.0 #:energy 100.0 #:flying? #t)
              (mk-unit 3375 'marauder 1 79.5 79.5 #:weapon-cooldown 0.0)
              (mk-unit 3376 'marauder 1 79.5 80.5 #:weapon-cooldown 0.0))
        (for/list ([t (in-list marine-tags)] [i (in-naturals)])
          ;; Ready weapon (w-cd=0.0) at 5.9t from 6.0-range Stalkers + pursuing Zealots!
          (mk-unit t 'marine 1 79.0 (+ 78.0 (* 0.45 i)) #:hp 45.0 #:hp-max 45.0 #:weapon-cooldown 0.0))))
     (define enemies
       (append
        (for/list ([i (in-range 5)])
          (mk-unit (+ 7360 i) 'zealot 4 85.2 (+ 78.5 (* 0.6 i)) #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0))
        (for/list ([i (in-range 4)])
          (mk-unit (+ 7370 i) 'stalker 4 85.0 (+ 78.5 (* 0.8 i)) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))))
     ;; Simulate pullback/wave-loss pressure + slight disadvantage so DisengageRetreat fires
     (define s1 (mk-obs 8600 (append allies enemies) #:food-used 40 #:food-cap 66 #:food-army 16 #:food-workers 24))
     (define s2 (mk-obs 8604 (append allies enemies) #:food-used 40 #:food-cap 66 #:food-army 16 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Terran 'Protoss (list (hash 'obs s1) (hash 'obs s2))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define pure-move-cnt (for/sum ([t (in-list marine-tags)]) (if (wire-pure-move-only? wcmds t) 1 0)))
     (define local-atk-cnt (wire-count-local-attacks wcmds marine-tags enemy-tags 85.0 80.0 14.0))
     (values out
             (list
              (mk-check "ready-weapon-marines-under-stalker-fire-do-not-pure-move"
                        (and (<= pure-move-cnt 3) (>= local-atk-cnt 6))
                        (format "Marines (w-cd=0, dist=5.9t) vs 6-range Stalkers+Zealots: pure-MOVE=~a/10, local-ATK=~a/10"
                                pure-move-cnt local-atk-cnt)))))))

;; 65. Novel-37: Terran Cyclone Lock-On High-Value Armored/Air Target
(define scen-novel-37
  (tactical-scenario
   "novel-37-cyclone-lock-on-high-value-target"
   "novel" "Terran" "Protoss" "unit-mobility-micro"
   "Novel: Terran Cyclone within 6.5t of enemy Void Ray / Stalker casts Lock-On (2350)"
   (lambda ()
     (define cyc-tag 3381)
     (define allies
       (append
        (mk-home-base-units 'Terran #:with-natural? #t)
        (list (mk-unit cyc-tag 'cyclone 1 80.0 80.0 #:hp 120.0 #:hp-max 120.0)
              (mk-unit 3382 'marine 1 79.0 79.5)
              (mk-unit 3383 'marine 1 79.0 80.5))))
     (define enemies
       (list (mk-unit 7381 'void-ray 4 85.5 80.0 #:hp 150.0 #:hp-max 150.0 #:shield 100.0 #:shield-max 100.0 #:flying? #t)
             (mk-unit 7382 'stalker  4 86.0 81.0 #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0)))
     (define s1 (mk-obs 7400 (append allies enemies) #:food-used 29 #:food-cap 54 #:food-army 5 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Terran 'Protoss (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define locked? (wire-has-ability? wcmds (list cyc-tag) AB-LOCK-ON))
     (values out
             (list
              (mk-check "cyclone-casts-lock-on-2350"
                        locked?
                        (format "cyclone-3381 wire abs=~a (expected ~a LOCK-ON)"
                                (wire-abilities-for-tag wcmds cyc-tag) AB-LOCK-ON)))))))

;; 66. Novel-38: Terran Battlecruiser Yamato Cannon & Low-HP Tactical Jump Escape
(define scen-novel-38
  (tactical-scenario
   "novel-38-battlecruiser-yamato-and-tactical-jump"
   "novel" "Terran" "Protoss" "spellcasters"
   "Novel: Healthy Battlecruiser (Weapon Refit) casts Yamato (401) on Tempest; injured BC (130/550 HP) Tactical Jumps (2358) home"
   (lambda ()
     (define bc-healthy 3391)
     (define bc-injured 3392)
     (define allies
       (append
        (mk-home-base-units 'Terran #:with-natural? #t)
        (list (mk-unit bc-healthy 'battlecruiser 1 80.0 79.0 #:hp 550.0 #:hp-max 550.0 #:flying? #t)
              (mk-unit bc-injured 'battlecruiser 1 80.0 81.5 #:hp 130.0 #:hp-max 550.0 #:flying? #t))))
     (define enemies
       (list (mk-unit 7391 'tempest 4 86.5 79.0 #:hp 200.0 #:hp-max 200.0 #:shield 125.0 #:shield-max 125.0 #:flying? #t)
             (mk-unit 7392 'stalker 4 85.0 81.5 #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0)
             (mk-unit 7393 'stalker 4 85.5 82.0 #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0)))
     (define s1 (mk-obs 14200 (append allies enemies)
                        #:food-used 36 #:food-cap 66 #:food-army 12 #:food-workers 24
                        #:upgrades '(weapon-refit)))
     (define outs (run-pipeline-sequence 'Terran 'Protoss (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define yamato? (wire-has-ability? wcmds (list bc-healthy) AB-YAMATO-CANNON))
     (define jumped? (wire-has-ability? wcmds (list bc-injured) AB-TACTICAL-JUMP))
     (values out
             (list
              (mk-check "healthy-bc-casts-yamato-401"
                        yamato?
                        (format "bc-3391 wire abs=~a (expected ~a YAMATO)" (wire-abilities-for-tag wcmds bc-healthy) AB-YAMATO-CANNON))
              (mk-check "injured-bc-casts-tactical-jump-2358"
                        jumped?
                        (format "bc-3392 wire abs=~a (expected ~a TACTICAL-JUMP)" (wire-abilities-for-tag wcmds bc-injured) AB-TACTICAL-JUMP)))))))

;; 67. Novel-39: Terran Thor Mode Discipline (High-Impact vs Massive Air / Explosive vs Mutalisks)
(define scen-novel-39
  (tactical-scenario
   "novel-39-thor-high-impact-vs-broodlord-explosive-vs-mutas"
   "novel" "Terran" "Zerg" "unit-mobility-micro"
   "Novel: Thor switches to High-Impact Payload (2362) vs Brood Lords and Explosive Payload (2364) vs clumped Mutalisks"
   (lambda ()
     (define thor-tag 3401)
     ;; Part A: Standard Explosive Thor facing 3 Brood Lords -> must morph High-Impact (2362)
     (define allies-a
       (append (mk-home-base-units 'Terran #:with-natural? #t)
               (list (mk-unit thor-tag 'thor 1 80.0 80.0 #:hp 400.0 #:hp-max 400.0))))
     (define enemies-a
       (list (mk-unit 7401 'brood-lord 4 88.0 79.0 #:hp 225.0 #:hp-max 225.0 #:flying? #t)
             (mk-unit 7402 'brood-lord 4 88.5 80.5 #:hp 225.0 #:hp-max 225.0 #:flying? #t)
             (mk-unit 7403 'brood-lord 4 89.0 80.0 #:hp 225.0 #:hp-max 225.0 #:flying? #t)))
     (define s1 (mk-obs 13600 (append allies-a enemies-a) #:food-used 30 #:food-cap 66 #:food-army 6 #:food-workers 24))
     (define out-a (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s1)))))
     (define hi-mode? (wire-has-ability? (step-outcome-wire-cmds out-a) (list thor-tag) AB-THOR-HIGH-IMPACT))
     ;; Part B: High-Impact Thor (`thor-ap`) facing 8 clumped Mutalisks -> must morph Explosive (2364)
     (define allies-b
       (append (mk-home-base-units 'Terran #:with-natural? #t)
               (list (mk-unit thor-tag 'thor-ap 1 80.0 80.0 #:hp 400.0 #:hp-max 400.0))))
     (define enemies-b
       (for/list ([i (in-range 8)])
         (mk-unit (+ 7410 i) 'mutalisk 4 (+ 87.5 (* 0.3 (modulo i 4))) (+ 79.5 (* 0.3 (quotient i 4))) #:hp 120.0 #:hp-max 120.0 #:flying? #t)))
     (define s2 (mk-obs 13700 (append allies-b enemies-b) #:food-used 30 #:food-cap 66 #:food-army 6 #:food-workers 24))
     (define out-b (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s2)))))
     (define exp-mode? (wire-has-ability? (step-outcome-wire-cmds out-b) (list thor-tag) AB-THOR-EXPLOSIVE))
     (values out-a
             (list
              (mk-check "thor-switches-high-impact-2362-vs-brood-lords"
                        hi-mode?
                        (format "thor-3401 vs Brood Lords wire abs=~a (expected ~a HIGH-IMPACT)"
                                (wire-abilities-for-tag (step-outcome-wire-cmds out-a) thor-tag) AB-THOR-HIGH-IMPACT))
              (mk-check "thor-ap-switches-explosive-2364-vs-mutalisks"
                        exp-mode?
                        (format "thor-ap-3401 vs 8 Mutalisks wire abs=~a (expected ~a EXPLOSIVE)"
                                (wire-abilities-for-tag (step-outcome-wire-cmds out-b) thor-tag) AB-THOR-EXPLOSIVE)))))))

;; 68. Novel-40: Terran Viking Fighter Air Discipline vs Colossus & Safe Assault Landing vs Pure Ground
(define scen-novel-40
  (tactical-scenario
   "novel-40-viking-fighter-vs-colossus-and-assault-vs-ground"
   "novel" "Terran" "Protoss" "unit-mobility-micro"
   "Novel: Fighter Vikings stay airborne (never land Assault 403) when enemy Colossus is present, and land Assault (403) when only undefended Probes/Nexus remain"
   (lambda ()
     (define vik-a-tags '(3410 3411))
     ;; Part A: Fighter Vikings facing Colossus -> must STAY airborne (never emit 403 ASSAULT!)
     (define allies-a
       (append (mk-home-base-units 'Terran #:with-natural? #t)
               (for/list ([t (in-list vik-a-tags)] [i (in-naturals)])
                 (mk-unit t 'viking-fighter 1 80.0 (+ 79.5 (* 1.0 i)) #:hp 135.0 #:hp-max 135.0 #:flying? #t))))
     (define enemies-a
       (list (mk-unit 7421 'colossus 4 87.0 80.0 #:hp 200.0 #:hp-max 200.0 #:shield 150.0 #:shield-max 150.0)))
     (define s1 (mk-obs 10400 (append allies-a enemies-a) #:food-used 28 #:food-cap 54 #:food-army 4 #:food-workers 24))
     (define out-a (last (run-pipeline-sequence 'Terran 'Protoss (list (hash 'obs s1)))))
     (define stayed-air? (not (wire-has-ability? (step-outcome-wire-cmds out-a) vik-a-tags AB-VIKING-ASSAULT)))
     ;; Part B: Fighter Vikings over undefended enemy Probes (zero air/AA/colossus) -> land Assault (403)
     (define vik-b-tags '(3412 3413 3414))
     (define allies-b
       (append (mk-home-base-units 'Terran #:with-natural? #t)
               (for/list ([t (in-list vik-b-tags)] [i (in-naturals)])
                 (mk-unit t 'viking-fighter 1 156.0 (+ 158.0 (* 0.8 i)) #:hp 135.0 #:hp-max 135.0 #:flying? #t))))
     (define enemies-b
       (list (mk-unit 7425 'probe 4 160.0 159.0 #:hp 20.0 #:hp-max 20.0 #:shield 20.0 #:shield-max 20.0)
             (mk-unit 7426 'probe 4 160.5 160.0 #:hp 20.0 #:hp-max 20.0 #:shield 20.0 #:shield-max 20.0)
             (mk-unit 7427 'nexus 4 160.0 160.0 #:hp 1000.0 #:hp-max 1000.0 #:shield 1000.0 #:shield-max 1000.0)))
     (define s2 (mk-obs 11000 (append allies-b enemies-b) #:food-used 30 #:food-cap 54 #:food-army 6 #:food-workers 24))
     (define out-b (last (run-pipeline-sequence 'Terran 'Protoss (list (hash 'obs s2)))))
     (define landed? (wire-has-ability? (step-outcome-wire-cmds out-b) vik-b-tags AB-VIKING-ASSAULT))
     (values out-a
             (list
              (mk-check "viking-fighter-stays-airborne-vs-colossus"
                        stayed-air?
                        (format "vikings-3410..3411 vs Colossus wire abs=~a (must NOT land ~a)"
                                (for/list ([t vik-a-tags]) (cons t (wire-abilities-for-tag (step-outcome-wire-cmds out-a) t)))
                                AB-VIKING-ASSAULT))
              (mk-check "viking-fighter-lands-assault-403-vs-undefended-probes"
                        landed?
                        (format "vikings-3412..3414 wire abs=~a (expected ~a VIKING-ASSAULT)"
                                (for/list ([t vik-b-tags]) (cons t (wire-abilities-for-tag (step-outcome-wire-cmds out-b) t)))
                                AB-VIKING-ASSAULT)))))))

;; 69. Novel-41: Terran Hellion -> Hellbat Transform With Completed Armory vs Charging Zerglings
(define scen-novel-41
  (tactical-scenario
   "novel-41-hellion-to-hellbat-transform-with-armory"
   "novel" "Terran" "Zerg" "unit-mobility-micro"
   "Novel: Terran Hellions with completed Armory facing close charging Zerglings transform to Hellbats (1998)"
   (lambda ()
     (define hel-tags '(3421 3422 3423 3424))
     (define allies
       (append
        (mk-home-base-units 'Terran #:with-natural? #t)
        (list (mk-unit 3420 'armory 1 36.0 36.0 #:hp 750.0 #:hp-max 750.0))
        (for/list ([t (in-list hel-tags)] [i (in-naturals)])
          (mk-unit t 'hellion 1 80.0 (+ 79.0 (* 0.6 i)) #:hp 90.0 #:hp-max 90.0))
        (for/list ([i (in-range 6)])
          (mk-unit (+ 3425 i) 'marine 1 78.5 (+ 78.5 (* 0.5 i))))))
     (define enemies
       (for/list ([i (in-range 14)])
         (mk-unit (+ 7430 i) 'zergling 4 85.0 (+ 78.0 (* 0.35 i)))))
     (define s1 (mk-obs 7600 (append allies enemies) #:food-used 38 #:food-cap 66 #:food-army 14 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define morphed? (wire-has-ability? wcmds hel-tags AB-MORPH-HELLBAT))
     (values out
             (list
              (mk-check "hellions-morph-to-hellbats-1998-with-armory"
                        morphed?
                        (format "hellions wire abs=~a (expected ~a MORPH-HELLBAT)"
                                (for/list ([t hel-tags]) (cons t (wire-abilities-for-tag wcmds t)))
                                AB-MORPH-HELLBAT)))))))

;; 70. Novel-42: Terran SCV Combat Repair Damaged Siege Tank Without Pulling Builders
(define scen-novel-42
  (tactical-scenario
   "novel-42-scv-combat-repair-tank-protects-builders"
   "novel" "Terran" "Protoss" "support-preservation"
   "Novel: Idle SCVs next to damaged Siege Tank (60/175 HP) cast Repair (316/3685), while constructing SCV is NOT pulled off build order"
   (lambda ()
     (define idle-scv 3431)
     (define builder-scv 3432)
     (define tank-tag 3433)
     (define allies
       (append
        (mk-home-base-units 'Terran #:with-natural? #t)
        (list (mk-unit idle-scv 'scv 1 54.0 36.0 #:hp 45.0 #:hp-max 45.0)
              (mk-unit builder-scv 'scv 1 54.5 36.5 #:hp 45.0 #:hp-max 45.0
                       #:orders (list (sc2-unit-order 319 (sc2-point2d 56.0 38.0) 0 0.4))) ;; Build Supply Depot (319)
              (mk-unit tank-tag 'siege-tank-sieged 1 55.5 36.0 #:hp 60.0 #:hp-max 175.0))))
     (define enemies
       (list (mk-unit 7441 'stalker 4 64.0 36.0 #:shield 80.0 #:shield-max 80.0)))
     (define s1 (mk-obs 6800 (append allies enemies) #:minerals 300 #:vespene 100 #:food-used 29 #:food-cap 54 #:food-army 3 #:food-workers 26))
     (define outs (run-pipeline-sequence 'Terran 'Protoss (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define repaired? (wire-any-ability? wcmds (list idle-scv) (list AB-REPAIR-SCV AB-REPAIR-GENERIC)))
     (define builder-untouched? (not (wire-any-ability? wcmds (list builder-scv) (list AB-REPAIR-SCV AB-REPAIR-GENERIC AB-ATTACK))))
     (values out
             (list
              (mk-check "idle-scv-repairs-damaged-siege-tank"
                        repaired?
                        (format "idle scv-3431 wire abs=~a (expected ~a/~a REPAIR)"
                                (wire-abilities-for-tag wcmds idle-scv) AB-REPAIR-SCV AB-REPAIR-GENERIC))
              (mk-check "constructing-scv-not-stolen-for-repair"
                        builder-untouched?
                        (format "builder scv-3432 wire abs=~a (must not be pulled off construction)"
                                (wire-abilities-for-tag wcmds builder-scv))))))))

;; 71. Novel-43: Protoss Sentry Force Field Splits Charging Melee Army
(define scen-novel-43
  (tactical-scenario
   "novel-43-sentry-force-field-splits-charging-melee"
   "novel" "Protoss" "Zerg" "spellcasters"
   "Novel: Protoss Sentry (100en, Guardian Shield already active) facing charging Zerglings casts Force Field (1526)"
   (lambda ()
     (define sentry-tag 3441)
     (define allies
       (append
        (mk-home-base-units 'Protoss #:with-natural? #t)
        (list (mk-unit sentry-tag 'sentry 1 80.0 80.0 #:energy 100.0 #:shield 40.0 #:shield-max 40.0 #:buffs '(18)))
        (for/list ([i (in-range 6)])
          (mk-unit (+ 3442 i) 'stalker 1 78.5 (+ 78.0 (* 0.6 i)) #:shield 80.0 #:shield-max 80.0))))
     (define enemies
       (for/list ([i (in-range 14)])
         (mk-unit (+ 7450 i) 'zergling 4 (+ 85.0 (* 0.4 (modulo i 5))) (+ 78.8 (* 0.5 (quotient i 5))))))
     (define s1 (mk-obs 7200 (append allies enemies) #:food-used 38 #:food-cap 54 #:food-army 14 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Protoss 'Zerg (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define cast-ff? (wire-has-ability? wcmds (list sentry-tag) AB-FORCE-FIELD))
     (values out
             (list
              (mk-check "sentry-casts-force-field-1526-vs-charging-lings"
                        cast-ff?
                        (format "sentry-3441 wire abs=~a (expected ~a FORCE-FIELD)"
                                (wire-abilities-for-tag wcmds sentry-tag) AB-FORCE-FIELD)))))))

;; 72. Novel-44: Protoss Oracle Revelation vs Cloaked/Burrowed & Pulsar Beam vs Enemy Workers
(define scen-novel-44
  (tactical-scenario
   "novel-44-oracle-revelation-and-pulsar-beam-harass"
   "novel" "Protoss" "Terran" "spellcasters"
   "Novel: Oracle (100en) casts Revelation (2146) on cloaked Banshee and activates Pulsar Beam (2375) over undefended enemy SCVs"
   (lambda ()
     (define ora-tag 3451)
     ;; Part A: Cloaked Banshee -> Revelation (2146)
     (define allies-a
       (append (mk-home-base-units 'Protoss #:with-natural? #t)
               (list (mk-unit ora-tag 'oracle 1 55.0 36.0 #:energy 100.0 #:shield 60.0 #:shield-max 60.0 #:flying? #t)
                     (mk-unit 3452 'stalker 1 53.0 36.0 #:shield 80.0 #:shield-max 80.0))))
     (define enemies-a
       (list (mk-unit 7461 'banshee 4 61.0 36.0 #:cloak 2 #:flying? #t)))
     (define s1 (mk-obs 6600 (append allies-a enemies-a) #:food-used 29 #:food-cap 54 #:food-army 5 #:food-workers 24))
     (define out-a (last (run-pipeline-sequence 'Protoss 'Terran (list (hash 'obs s1)))))
     (define cast-rev? (wire-has-ability? (step-outcome-wire-cmds out-a) (list ora-tag) AB-ORACLE-REVELATION))
     ;; Part B: Undefended enemy SCV mineral line -> Pulsar Beam ON (2375)
     (define allies-b
       (append (mk-home-base-units 'Protoss #:with-natural? #t)
               (list (mk-unit ora-tag 'oracle 1 159.0 160.0 #:energy 100.0 #:shield 60.0 #:shield-max 60.0 #:flying? #t))))
     (define enemies-b
       (for/list ([i (in-range 6)])
         (mk-unit (+ 7470 i) 'scv 4 162.5 (+ 158.5 (* 0.5 i)))))
     (define s2 (mk-obs 6800 (append allies-b enemies-b) #:food-used 27 #:food-cap 54 #:food-army 3 #:food-workers 24))
     (define out-b (last (run-pipeline-sequence 'Protoss 'Terran (list (hash 'obs s2)))))
     (define pulsar-on? (wire-has-ability? (step-outcome-wire-cmds out-b) (list ora-tag) AB-PULSAR-BEAM-ON))
     (values out-a
             (list
              (mk-check "oracle-casts-revelation-2146-on-cloaked-banshee"
                        cast-rev?
                        (format "oracle-3451 vs cloaked Banshee wire abs=~a (expected ~a REVELATION)"
                                (wire-abilities-for-tag (step-outcome-wire-cmds out-a) ora-tag) AB-ORACLE-REVELATION))
              (mk-check "oracle-activates-pulsar-beam-2375-on-scvs"
                        pulsar-on?
                        (format "oracle-3451 vs SCVs wire abs=~a (expected ~a PULSAR-BEAM)"
                                (wire-abilities-for-tag (step-outcome-wire-cmds out-b) ora-tag) AB-PULSAR-BEAM-ON)))))))

;; 73. Novel-45: Protoss Nexus Chrono Boost (SC2 4.10.0 Base75689) & Shield-Battery-Backed Natural Hold
(define scen-novel-45
  (tactical-scenario
   "novel-45-protoss-chrono-boost-and-battery-natural-hold"
   "novel" "Protoss" "Zerg" "home-defense"
   "Novel: Protoss Nexus (100en, SC2 4.10.0) Chrono Boosts (3755) active Gateway/Robo while Shield-Battery-backed Stalkers/Immortals defend natural against Roaches"
   (lambda ()
     (define nat-nexus-tag 2)
     (define bat-tag 3461)
     (define army-tags '(3462 3463 3464 3465))
     (define enemy-tags (for/list ([i (in-range 6)]) (+ 7480 i)))
     (define allies
       (append
        (list (mk-unit 1 'nexus 1 32.0 32.0 #:energy 100.0 #:shield 1000.0 #:shield-max 1000.0)
              (mk-unit nat-nexus-tag 'nexus 1 52.0 34.0 #:energy 100.0 #:shield 1000.0 #:shield-max 1000.0)
              (mk-unit 10 'pylon 1 56.0 35.0 #:shield 200.0 #:shield-max 200.0)
              (mk-unit 11 'robotics-facility 1 36.0 35.0 #:shield 450.0 #:shield-max 450.0
                       #:orders (list (sc2-unit-order 979 #f 0 0.25))) ;; Training Immortal
              (mk-unit bat-tag 'shield-battery 1 56.5 36.0 #:energy 100.0 #:shield 150.0 #:shield-max 150.0))
        (for/list ([i (in-range 12)])
          (mk-unit (+ 20 i) 'probe 1 28.0 (+ 28.0 (* 0.4 i)) #:shield 20.0 #:shield-max 20.0))
        (list (mk-unit 3462 'stalker 1 57.5 35.5 #:hp 80.0 #:hp-max 80.0 #:shield 30.0 #:shield-max 80.0)
              (mk-unit 3463 'stalker 1 57.5 36.5 #:hp 80.0 #:hp-max 80.0 #:shield 25.0 #:shield-max 80.0)
              (mk-unit 3464 'immortal 1 58.0 36.0 #:hp 200.0 #:hp-max 200.0 #:shield 40.0 #:shield-max 100.0)
              (mk-unit 3465 'immortal 1 58.0 37.0 #:hp 200.0 #:hp-max 200.0 #:shield 50.0 #:shield-max 100.0))))
     (define enemies
       (for/list ([t (in-list enemy-tags)] [i (in-naturals)])
         (mk-unit t 'roach 4 62.5 (+ 35.0 (* 0.5 i)))))
     (define s1 (mk-obs 6200 (append allies enemies) #:food-used 32 #:food-cap 46 #:food-army 12 #:food-workers 20))
     (define outs (run-pipeline-sequence 'Protoss 'Zerg (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define chrono? (wire-has-ability? wcmds (list 1 nat-nexus-tag) AB-CHRONO-BOOST))
     (define defenders-atk (wire-count-local-attacks wcmds army-tags enemy-tags 62.5 36.0 14.0))
     (values out
             (list
              (mk-check "nexus-chrono-boosts-3755-active-production"
                        chrono?
                        (format "nexuses wire abs=~a (expected ~a CHRONO-BOOST on active Robotics Facility)"
                                (for/list ([t '(1 2)]) (cons t (wire-abilities-for-tag wcmds t)))
                                AB-CHRONO-BOOST))
              (mk-check "battery-backed-defenders-hold-and-attack-roaches"
                        (>= defenders-atk 3)
                        (format "defenders local-ATK=~a/4 under Shield Battery cover" defenders-atk)))))))

;; 74. Novel-46: Zerg Roach Burrow-Regen When Injured & Unburrow When Healed
(define scen-novel-46
  (tactical-scenario
   "novel-46-zerg-roach-burrow-regen-and-unburrow"
   "novel" "Zerg" "Protoss" "unit-mobility-micro"
   "Novel: Injured Roach (35/145 HP, Burrow researched, no enemy detector) burrows (3661/1386); full-HP burrowed Roach unburrows (3662/1388)"
   (lambda ()
     (define injured-roach 3471)
     (define healed-roach  3472)
     (define allies
       (append
        (mk-home-base-units 'Zerg #:with-natural? #t)
        (list (mk-unit injured-roach 'roach 1 80.0 79.5 #:hp 35.0 #:hp-max 145.0)
              (mk-unit healed-roach 'roach-burrowed 1 79.0 81.0 #:hp 145.0 #:hp-max 145.0 #:burrowed? #t)
              (mk-unit 3473 'roach 1 80.5 80.0 #:hp 145.0 #:hp-max 145.0)
              (mk-unit 3474 'roach 1 80.5 80.5 #:hp 145.0 #:hp-max 145.0))))
     (define enemies
       (list (mk-unit 7491 'stalker 4 85.0 79.5 #:shield 80.0 #:shield-max 80.0)
             (mk-unit 7492 'stalker 4 85.0 80.5 #:shield 80.0 #:shield-max 80.0)))
     (define s1 (mk-obs 8800 (append allies enemies)
                        #:food-used 32 #:food-cap 54 #:food-army 8 #:food-workers 24
                        #:upgrades '(burrow tunneling-claws)))
     (define outs (run-pipeline-sequence 'Zerg 'Protoss (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define burrowed? (wire-any-ability? wcmds (list injured-roach) (list AB-BURROW-DOWN AB-BURROW-ROACH-DOWN)))
     (define unburrowed? (wire-any-ability? wcmds (list healed-roach) (list AB-BURROW-UP AB-BURROW-ROACH-UP)))
     (values out
             (list
              (mk-check "injured-roach-burrows-to-regen"
                        burrowed?
                        (format "roach-3471 wire abs=~a (expected ~a/~a BURROW)"
                                (wire-abilities-for-tag wcmds injured-roach) AB-BURROW-DOWN AB-BURROW-ROACH-DOWN))
              (mk-check "healed-burrowed-roach-unburrows-to-fight"
                        unburrowed?
                        (format "roach-burrowed-3472 wire abs=~a (expected ~a/~a UNBURROW)"
                                (wire-abilities-for-tag wcmds healed-roach) AB-BURROW-UP AB-BURROW-ROACH-UP)))))))

;; 75. Novel-47: Zerg Viper Parasitic Bomb vs Clumped Enemy Air Squad
(define scen-novel-47
  (tactical-scenario
   "novel-47-zerg-viper-parasitic-bomb-clumped-air"
   "novel" "Zerg" "Terran" "spellcasters"
   "Novel: Zerg Viper (150en) facing 6 clumped enemy Vikings casts Parasitic Bomb (2542)"
   (lambda ()
     (define viper-tag 3481)
     (define allies
       (append
        (mk-home-base-units 'Zerg #:with-natural? #t)
        (list (mk-unit viper-tag 'viper 1 80.0 80.0 #:energy 150.0 #:flying? #t))
        (for/list ([i (in-range 6)])
          (mk-unit (+ 3482 i) 'corruptor 1 78.0 (+ 78.5 (* 0.5 i)) #:flying? #t))))
     (define enemies
       (for/list ([i (in-range 6)])
         (mk-unit (+ 7500 i) 'viking-fighter 4 (+ 86.5 (* 0.3 (modulo i 3))) (+ 79.5 (* 0.3 (quotient i 3))) #:flying? #t)))
     (define s1 (mk-obs 12800 (append allies enemies) #:food-used 39 #:food-cap 66 #:food-army 15 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Zerg 'Terran (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define pbomb? (wire-has-ability? wcmds (list viper-tag) AB-PARASITIC-BOMB))
     (values out
             (list
              (mk-check "viper-casts-parasitic-bomb-2542-on-clumped-vikings"
                        pbomb?
                        (format "viper-3481 wire abs=~a (expected ~a PARASITIC-BOMB)"
                                (wire-abilities-for-tag wcmds viper-tag) AB-PARASITIC-BOMB)))))))

;; 76. Novel-48: Zerg Infestor Neural Parasite vs Enemy Massive Capital Unit (Colossus/Thor)
(define scen-novel-48
  (tactical-scenario
   "novel-48-zerg-infestor-neural-parasite-massive"
   "novel" "Zerg" "Protoss" "spellcasters"
   "Novel: Zerg Infestor (150en, Neural Parasite researched) facing isolated enemy Colossus casts Neural Parasite (249)"
   (lambda ()
     (define inf-tag 3491)
     (define allies
       (append
        (mk-home-base-units 'Zerg #:with-natural? #t)
        (list (mk-unit inf-tag 'infestor 1 80.0 80.0 #:energy 150.0))
        (for/list ([i (in-range 6)])
          (mk-unit (+ 3492 i) 'hydralisk 1 78.5 (+ 78.5 (* 0.5 i))))))
     (define enemies
       (list (mk-unit 7511 'colossus 4 86.5 80.0 #:hp 200.0 #:hp-max 200.0 #:shield 150.0 #:shield-max 150.0)))
     (define s1 (mk-obs 13200 (append allies enemies)
                        #:food-used 38 #:food-cap 66 #:food-army 14 #:food-workers 24
                        #:upgrades '(neural-parasite)))
     (define outs (run-pipeline-sequence 'Zerg 'Protoss (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define neural? (wire-has-ability? wcmds (list inf-tag) AB-NEURAL-PARASITE))
     (values out
             (list
              (mk-check "infestor-casts-neural-parasite-249-on-colossus"
                        neural?
                        (format "infestor-3491 wire abs=~a (expected ~a NEURAL-PARASITE)"
                                (wire-abilities-for-tag wcmds inf-tag) AB-NEURAL-PARASITE)))))))

;; 77. Novel-49: Early 12-Pool Zergling Rush Defense at Protoss Natural Wall
(define scen-novel-49
  (tactical-scenario
   "novel-49-early-12pool-ling-rush-protoss-wall-defense"
   "novel" "Protoss" "Zerg" "home-defense"
   "Novel: Early 12-Pool Zergling rush hitting Protoss natural wall Gateway/CyberCore at 2:30 -> Zealot+Adept+Stalker defend the wall without pure-MOVE fleeing"
   (lambda ()
     (define def-tags '(3501 3502 3503))
     (define enemy-tags (for/list ([i (in-range 6)]) (+ 7520 i)))
     (define allies
       (append
        (list (mk-unit 1 'nexus 1 32.0 32.0 #:shield 1000.0 #:shield-max 1000.0)
              (mk-unit 10 'pylon 1 46.5 47.0 #:shield 200.0 #:shield-max 200.0)
              (mk-unit 11 'gateway 1 48.5 49.0 #:hp 500.0 #:hp-max 500.0 #:shield 350.0 #:shield-max 500.0)
              (mk-unit 12 'cybernetics-core 1 49.0 46.5 #:hp 550.0 #:hp-max 550.0 #:shield 550.0 #:shield-max 550.0))
        (for/list ([i (in-range 16)])
          (mk-unit (+ 20 i) 'probe 1 28.0 (+ 28.0 (* 0.35 i)) #:shield 20.0 #:shield-max 20.0))
        (list (mk-unit 3501 'zealot  1 47.5 48.0 #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0)
              (mk-unit 3502 'adept   1 47.0 47.5 #:hp 70.0 #:hp-max 70.0 #:shield 70.0 #:shield-max 70.0)
              (mk-unit 3503 'stalker 1 46.5 48.5 #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))))
     (define enemies
       (for/list ([t (in-list enemy-tags)] [i (in-naturals)])
         (mk-unit t 'zergling 4 51.0 (+ 47.0 (* 0.45 i)))))
     (define s1 (mk-obs 3360 (append allies enemies) #:food-used 22 #:food-cap 31 #:food-army 6 #:food-workers 16))
     (define outs (run-pipeline-sequence 'Protoss 'Zerg (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define def-active
       (for/sum ([t (in-list def-tags)])
         (if (wire-any-ability? wcmds (list t) (list AB-ATTACK 17 18 2544)) 1 0)))
     (define def-pure-move
       (for/sum ([t (in-list def-tags)])
         (define abs (wire-abilities-for-tag wcmds t))
         (if (and (memv AB-MOVE abs)
                  (not (ormap (lambda (a) (memv a (list AB-ATTACK 17 18 2544))) abs)))
             1
             0)))
     (values out
             (list
              (mk-check "protoss-wall-defenders-engage-12pool-zerglings"
                        (and (>= def-active 3) (= def-pure-move 0))
                        (format "defenders active-combat=~a/3 (ATK/PATROL/HOLD/SHADE), pure-MOVE=~a/3; wire abs=~a"
                                def-active def-pure-move
                                (for/list ([t def-tags]) (cons t (wire-abilities-for-tag wcmds t))))))))))

;; 78. W4-P0-2 (from iter3_wave3 #2 T v titania 23.0m T: 11m stall, 8200 vs 1775 army):
;;     `harmless-sweep-entity?` (`bot-runtime.rkt:21832, 22430`) omits `overseer` / `overseer-siege-mode`
;;     (and lone non-combat workers), keeping `sweep-active-enemies` non-empty so `endgame-building-hunt`
;;     NEVER triggers when enemy Overseers + Overlords + CreepTumors linger after enemy main is cleared!
(define scen-w4-p0-2
  (tactical-scenario
   "w4-p0-2-overseer-blocked-endgame-sweep"
   "wave4-repro" "Terran" "Zerg" "endgame-sweep"
   "Wave-4 Repro (W4-P0-2 / #2 T v titania): Dominant Terran army at cleared enemy main seeing only enemy Overseers+Overlords+CreepTumors must launch endgame-building-hunt"
   (lambda ()
     (define army-tags (append (for/list ([i (in-range 14)]) (+ 3510 i))
                               (for/list ([i (in-range 4)]) (+ 3530 i))))
     (define allies
       (append
        (mk-home-base-units 'Terran #:with-natural? #t)
        (for/list ([i (in-range 14)])
          (mk-unit (+ 3510 i) 'marine 1 (+ 156.0 (* 0.4 (modulo i 5))) (+ 157.0 (* 0.4 (quotient i 5)))))
        (for/list ([i (in-range 4)])
          (mk-unit (+ 3530 i) 'marauder 1 (+ 157.0 (* 0.5 i)) 159.0))))
     ;; Enemy main (160,160) has 0 buildings left — only Overseers + Overlord + CreepTumorBurrowed!
     (define enemies
       (list (mk-unit 7541 'overseer 4 159.0 159.0 #:hp 200.0 #:hp-max 200.0 #:flying? #t)
             (mk-unit 7542 'overseer 4 161.0 160.0 #:hp 200.0 #:hp-max 200.0 #:flying? #t)
             (mk-unit 7543 'overlord 4 162.0 161.0 #:hp 200.0 #:hp-max 200.0 #:flying? #t)
             (mk-unit 7544 'creep-tumor-burrowed 4 155.0 155.0 #:hp 50.0 #:hp-max 50.0 #:burrowed? #t)))
     (define exp-cands (list (hash 'x 88.0 'y 138.0) (hash 'x 160.0 'y 32.0) (hash 'x 32.0 'y 160.0)))
     (define overlay (hash 'expansion-candidates exp-cands))
     (define s1 (mk-obs 22000 (append allies enemies)
                        #:minerals 3000 #:vespene 1000
                        #:food-used 175 #:food-cap 200 #:food-army 110 #:food-workers 65))
     (define s2 (mk-obs 22050 (append allies enemies)
                        #:minerals 3000 #:vespene 1000
                        #:food-used 175 #:food-cap 200 #:food-army 110 #:food-workers 65))
     (define outs (run-pipeline-sequence 'Terran 'Zerg
                                         (list (hash 'obs s1 'overlay overlay)
                                               (hash 'obs s2 'overlay overlay))))
     (define out (last outs))
     (define raw-acts (step-outcome-bot-actions out))
     (define wcmds (step-outcome-wire-cmds out))
     (define raw-sweep-pos?
       (for/or ([a (in-list raw-acts)])
         (and (pair? a)
              (eq? (car a) 'attack-pos)
              (>= (length a) 4)
              (real? (caddr a))
              (real? (cadddr a))
              (> (dist2d-xy (exact->inexact (caddr a)) (exact->inexact (cadddr a)) 160.0 160.0) 25.0))))
     ;; Check that army gets search/attack-move commands AWAY from cleared enemy main (160,160)
     (define sweeping-out?
       (for/or ([c (in-list wcmds)])
         (and (sc2-raw-unit-command? c)
              (memv (sc2-raw-unit-command-ability-id c) (list AB-ATTACK AB-MOVE))
              (sc2-point2d? (sc2-raw-unit-command-target-pos c))
              (ormap (lambda (t) (memv t army-tags)) (sc2-raw-unit-command-unit-tags c))
              (let ([pt (sc2-raw-unit-command-target-pos c)])
                (> (dist2d-xy (sc2-point2d-x pt) (sc2-point2d-y pt) 160.0 160.0) 25.0)))))
     (values out
             (list
              (mk-check "overseer-does-not-block-endgame-building-hunt"
                        (and (or raw-sweep-pos? sweeping-out?)
                             sweeping-out?
                             (= (step-outcome-wire-rejects out) 0))
                        (format "raw-sweep-pos?=~a sweeping-out?=~a wire_rejects=~a (Overseers+CreepTumor must not block endgame sweep!)"
                                raw-sweep-pos? sweeping-out? (step-outcome-wire-rejects out))))))))

;; 79. W4-TAC-4 (NEW live-pipeline bug!): Grounded Viking Assault vs Colossus Trapped by Splash-Evasion
;;     `l34-phase4a-hazards-wm!` (`bot-runtime.rkt:19920-19978`) puts enemy Colossus in `base-splash-hazards`
;;     and exempts `'ghost` from `ground-splash-cands`, but does NOT exempt `'viking-assault`!
;;     Result: grounded `viking-assault` is added to `splash-evading-tags` (`move 78,80` on foot!) and
;;     skipped by `um-eligible?` (`L21345`), preventing `plan-viking-modes` from ever lifting to Fighter (405)!
(define scen-w4-tac-4
  (tactical-scenario
   "w4-tac-4-viking-assault-lifts-vs-colossus-not-splash-evade"
   "wave4-repro" "Terran" "Protoss" "unit-mobility-micro"
   "Wave-4 Repro (W4-TAC-4): Grounded Viking Assault 7t from Colossus must lift off to Fighter (405), not be trapped in ground splash-evasion MOVE(16)"
   (lambda ()
     (define vik-tag 3551)
     (define allies
       (append (mk-home-base-units 'Terran #:with-natural? #t)
               (list (mk-unit vik-tag 'viking-assault 1 80.0 80.0 #:hp 135.0 #:hp-max 135.0 #:flying? #f))))
     (define enemies
       (list (mk-unit 7551 'colossus 4 87.0 80.0 #:hp 200.0 #:hp-max 200.0 #:shield 150.0 #:shield-max 150.0)))
     (define s1 (mk-obs 10400 (append allies enemies) #:food-used 26 #:food-cap 54 #:food-army 2 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Terran 'Protoss (list (hash 'obs s1))))
     (define out (last outs))
     (define wcmds (step-outcome-wire-cmds out))
     (define lifted? (wire-has-ability? wcmds (list vik-tag) AB-VIKING-FIGHTER))
     (values out
             (list
              (mk-check "viking-assault-lifts-to-fighter-405-vs-colossus"
                        lifted?
                        (format "viking-3551 wire abs=~a (expected ~a VIKING-FIGHTER, not splash-evasion MOVE 16!)"
                                (wire-abilities-for-tag wcmds vik-tag) AB-VIKING-FIGHTER)))))))

;; 80. W4-TAC-5 (NEW systemic multi-caster claim bug!): Distinct Target Claims Across Multiple Casters
;;     `pro-spellcaster-micro.rkt` `best-unit-target` predicates for `ht-feedback` (L3473),
;;     `raven-interference-matrix` (L2907), `viper-abduct` (L2508), `infestor-neural` (L2390/2429),
;;     `ghost-snipe` (L2877), and `queen-transfuse` (L2255) do NOT filter out targets already claimed
;;     on the same frame! Caster #2 picks Caster #1's target, `spell-claim-unit?!` returns `#f`,
;;     and Caster #2 drops its spell on the 2nd high-value target!
(define scen-w4-tac-5
  (tactical-scenario
   "w4-tac-5-multi-caster-distinct-target-claims"
   "wave4-repro" "Protoss" "Zerg" "spellcasters"
   "Wave-4 Repro (W4-TAC-5): 2 HTs vs 2 Infestors must cast Feedback (140) on 2 DISTINCT targets, and 2 Ravens vs 2 Colossi must cast Interference Matrix (3747) on 2 DISTINCT Colossi"
   (lambda ()
     ;; Part A: 2 HTs (75en) vs 2 Infestors (120en) -> BOTH Infestors must receive Feedback (140)!
     (define ht-tags '(3561 3562))
     (define inf-tags '(7561 7562))
     (define allies-a
       (append
        (mk-home-base-units 'Protoss #:with-natural? #t)
        (list (mk-unit 3561 'high-templar 1 78.5 79.5 #:energy 75.0 #:shield 40.0 #:shield-max 40.0)
              (mk-unit 3562 'high-templar 1 78.5 80.5 #:energy 75.0 #:shield 40.0 #:shield-max 40.0)
              (mk-unit 3563 'archon 1 80.5 80.0 #:hp 10.0 #:hp-max 10.0 #:shield 350.0 #:shield-max 350.0))))
     (define enemies-a
       (list (mk-unit 7561 'infestor 4 87.0 79.5 #:hp 90.0 #:hp-max 90.0 #:energy 120.0)
             (mk-unit 7562 'infestor 4 87.0 80.5 #:hp 90.0 #:hp-max 90.0 #:energy 120.0)
             (mk-unit 7563 'zergling 4 84.5 80.0)))
     (define s1 (mk-obs 11400 (append allies-a enemies-a) #:food-used 32 #:food-cap 54 #:food-army 8 #:food-workers 24))
     (define out-a (last (run-pipeline-sequence 'Protoss 'Zerg (list (hash 'obs s1)))))
     (define wcmds-a (step-outcome-wire-cmds out-a))
     (define fb-targets
       (remove-duplicates
        (for/list ([c (in-list wcmds-a)]
                   #:when (and (sc2-raw-unit-command? c)
                               (= (sc2-raw-unit-command-ability-id c) AB-FEEDBACK)
                               (ormap (lambda (t) (memv t ht-tags)) (sc2-raw-unit-command-unit-tags c))
                               (memv (sc2-raw-unit-command-target-unit-tag c) inf-tags)))
          (sc2-raw-unit-command-target-unit-tag c))))
     ;; Part B: 2 Ravens (100en) vs 2 Colossi -> BOTH Colossi must receive Interference Matrix (3747)!
     (define rav-tags '(3571 3572))
     (define col-tags '(7571 7572))
     (define allies-b
       (append
        (mk-home-base-units 'Terran #:with-natural? #t)
        (list (mk-unit 3571 'raven 1 78.0 79.5 #:hp 140.0 #:hp-max 140.0 #:energy 100.0 #:flying? #t)
              (mk-unit 3572 'raven 1 78.0 80.5 #:hp 140.0 #:hp-max 140.0 #:energy 100.0 #:flying? #t))))
     (define enemies-b
       (list (mk-unit 7571 'colossus 4 85.0 79.5 #:hp 200.0 #:hp-max 200.0 #:shield 150.0 #:shield-max 150.0)
             (mk-unit 7572 'colossus 4 85.0 80.5 #:hp 200.0 #:hp-max 200.0 #:shield 150.0 #:shield-max 150.0)))
     (define s2 (mk-obs 11200 (append allies-b enemies-b) #:upgrades '(interference-matrix) #:food-used 28 #:food-cap 54 #:food-army 4 #:food-workers 24))
     (define out-b (last (run-pipeline-sequence 'Terran 'Protoss (list (hash 'obs s2)))))
     (define wcmds-b (step-outcome-wire-cmds out-b))
     (define mx-targets
       (remove-duplicates
        (for/list ([c (in-list wcmds-b)]
                   #:when (and (sc2-raw-unit-command? c)
                               (= (sc2-raw-unit-command-ability-id c) AB-INTERFERENCE-MATRIX)
                               (ormap (lambda (t) (memv t rav-tags)) (sc2-raw-unit-command-unit-tags c))
                               (memv (sc2-raw-unit-command-target-unit-tag c) col-tags)))
          (sc2-raw-unit-command-target-unit-tag c))))
     (values out-a
             (list
              (mk-check "two-hts-feedback-two-distinct-infestors"
                        (= (length fb-targets) 2)
                        (format "HT Feedback distinct targets=~a (expected both 7561 & 7562; HT wire abs=~a)"
                                fb-targets
                                (for/list ([t ht-tags]) (cons t (wire-abilities-for-tag wcmds-a t)))))
              (mk-check "two-ravens-matrix-two-distinct-colossi"
                        (= (length mx-targets) 2)
                        (format "Raven Matrix distinct targets=~a (expected both 7571 & 7572; Raven wire abs=~a)"
                                mx-targets
                                (for/list ([t rav-tags]) (cons t (wire-abilities-for-tag wcmds-b t))))))))))

;; =============================================================================
;; ROUND-5 PRO-TACTIC SHIELDS (novel-50..56) & WAVE-5 REPROS (w5-tac-1..5)
;; =============================================================================

;; 81. Novel-50: Terran Supply Depot Lower (556) for Own Army & Raise (558) vs Enemy Zerglings
(define scen-novel-50
  (tactical-scenario
   "novel-50-terran-supply-depot-lower-and-raise-ramp"
   "novel" "Terran" "Zerg" "home-defense"
   "Novel: Terran Supply Depot lowers (556) when friendly Marines approach ramp, and raises (558) when enemy Zerglings close within 4t"
   (lambda ()
     (define dep-tag 3601)
     ;; Part A: Own Marines next to raised Supply Depot -> lower (556)
     (define allies-a
       (append (mk-home-base-units 'Terran #:with-natural? #f)
               (list (mk-unit dep-tag 'supply-depot 1 46.0 46.0 #:hp 400.0 #:hp-max 400.0)
                     (mk-unit 3602 'marine 1 45.0 45.0)
                     (mk-unit 3603 'marine 1 45.5 45.5))))
     (define s1 (mk-obs 4800 allies-a #:food-used 22 #:food-cap 39 #:food-army 2 #:food-workers 20))
     (define out-a (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s1)))))
     (define lowered? (wire-has-ability? (step-outcome-wire-cmds out-a) (list dep-tag) AB-DEPOT-LOWER))
     ;; Part B: Enemy Zerglings within 4t of lowered Supply Depot -> raise (558)
     (define allies-b
       (append (mk-home-base-units 'Terran #:with-natural? #f)
               (list (mk-unit dep-tag 'supply-depot-lowered 1 46.0 46.0 #:hp 400.0 #:hp-max 400.0))))
     (define enemies-b
       (list (mk-unit 7601 'zergling 4 49.0 49.0)
             (mk-unit 7602 'zergling 4 49.5 49.0)))
     (define s2 (mk-obs 4800 (append allies-b enemies-b) #:food-used 20 #:food-cap 39 #:food-army 0 #:food-workers 20))
     (define out-b (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s2)))))
     (define raised? (wire-has-ability? (step-outcome-wire-cmds out-b) (list dep-tag) AB-DEPOT-RAISE))
     (values out-b
             (list
              (mk-check "supply-depot-lowers-556-for-friendly-army"
                        lowered?
                        (format "depot-3601 wire abs=~a (expected ~a LOWER)"
                                (wire-abilities-for-tag (step-outcome-wire-cmds out-a) dep-tag) AB-DEPOT-LOWER))
              (mk-check "supply-depot-raises-558-vs-enemy-zerglings"
                        raised?
                        (format "depot-3601 wire abs=~a (expected ~a RAISE)"
                                (wire-abilities-for-tag (step-outcome-wire-cmds out-b) dep-tag) AB-DEPOT-RAISE)))))))

;; 82. Novel-51: Terran Bunker Load (407) Under Early Roach Push
(define scen-novel-51
  (tactical-scenario
   "novel-51-terran-bunker-load-under-early-push"
   "novel" "Terran" "Zerg" "home-defense"
   "Novel: Terran Bunker at natural loads (407) nearby Marines when enemy Roaches attack"
   (lambda ()
     (define bnk-tag 3610)
     (define allies
       (append (mk-home-base-units 'Terran #:with-natural? #t)
               (list (mk-unit bnk-tag 'bunker 1 48.0 48.0 #:hp 400.0 #:hp-max 400.0)
                     (mk-unit 3611 'marine 1 47.0 47.5)
                     (mk-unit 3612 'marine 1 47.0 48.5)
                     (mk-unit 3613 'marine 1 47.5 47.0)
                     (mk-unit 3614 'marine 1 47.5 49.0))))
     (define enemies
       (for/list ([i (in-range 4)])
         (mk-unit (+ 7610 i) 'roach 4 54.0 (+ 47.5 (* 0.5 i)))))
     (define s1 (mk-obs 4600 (append allies enemies) #:food-used 28 #:food-cap 54 #:food-army 4 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define loaded? (wire-has-ability? wcmds (list bnk-tag) AB-BUNKER-LOAD))
     (values out
             (list
              (mk-check "bunker-loads-407-marines-under-roach-push"
                        loaded?
                        (format "bunker-3610 wire abs=~a (expected ~a BUNKER-LOAD)"
                                (wire-abilities-for-tag wcmds bnk-tag) AB-BUNKER-LOAD)))))))

;; 83. Novel-52: Protoss Tempest Long-Range Siege Focus-Fire vs Sieged Tank & Brood Lord
(define scen-novel-52
  (tactical-scenario
   "novel-52-protoss-tempest-long-range-focus-fire"
   "novel" "Protoss" "Zerg" "focus-fire"
   "Novel: Protoss Tempests at 10-12t standoff engage enemy Brood Lords (priority massive air) without pure-MOVE fleeing"
   (lambda ()
     (define tmp-tags '(3621 3622 3623))
     (define enemy-tags '(7621 7622 7623))
     (define allies
       (append (mk-home-base-units 'Protoss #:with-natural? #t)
               (for/list ([t (in-list tmp-tags)] [i (in-naturals)])
                 (mk-unit t 'tempest 1 78.0 (+ 79.0 (* 1.0 i)) #:hp 200.0 #:hp-max 200.0 #:shield 125.0 #:shield-max 125.0 #:flying? #t))))
     (define enemies
       (list (mk-unit 7621 'brood-lord 4 89.0 79.5 #:hp 225.0 #:hp-max 225.0 #:flying? #t)
             (mk-unit 7622 'brood-lord 4 89.0 80.5 #:hp 225.0 #:hp-max 225.0 #:flying? #t)
             (mk-unit 7623 'zergling   4 86.0 80.0)))
     (define s1 (mk-obs 14400 (append allies enemies) #:food-used 39 #:food-cap 66 #:food-army 15 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Protoss 'Zerg (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define tmp-atk (wire-count-local-attacks wcmds tmp-tags '(7621 7622) 89.0 80.0 16.0))
     (values out
             (list
              (mk-check "tempests-focus-fire-brood-lords-at-long-range"
                        (>= tmp-atk 2)
                        (format "tempests local-ATK on Brood Lords=~a/3 (wire abs=~a)"
                                tmp-atk
                                (for/list ([t tmp-tags]) (cons t (wire-abilities-for-tag wcmds t))))))))))

;; 84. Novel-53: Protoss Warp Prism Low-HP Immortal Pickup Rescue & Queued Retreat
(define scen-novel-53
  (tactical-scenario
   "novel-53-protoss-warp-prism-immortal-rescue-juggle"
   "novel" "Protoss" "Zerg" "support-preservation"
   "Novel: Warp Prism picks up (3668/911) low-HP Immortal (45/200 HP, 0 shield) under Roach fire and shift-queues safe retreat"
   (lambda ()
     (define prism-tag 3630)
     (define imm-tag 3631)
     (define allies
       (append (mk-home-base-units 'Protoss #:with-natural? #t)
               (list (mk-unit prism-tag 'warp-prism 1 78.5 80.0 #:hp 80.0 #:hp-max 80.0 #:shield 100.0 #:shield-max 100.0 #:flying? #t)
                     (mk-unit imm-tag 'immortal 1 80.0 80.0 #:hp 45.0 #:hp-max 200.0 #:shield 0.0 #:shield-max 100.0))))
     (define enemies
       (list (mk-unit 7631 'roach 4 84.0 80.0)
             (mk-unit 7632 'roach 4 84.5 80.5)))
     (define s1 (mk-obs 9200 (append allies enemies) #:food-used 30 #:food-cap 54 #:food-army 6 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Protoss 'Zerg (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define loaded-imm?
       (for/or ([c (in-list wcmds)])
         (and (sc2-raw-unit-command? c)
              (memv (sc2-raw-unit-command-ability-id c) (list AB-LOAD-GENERIC AB-WARP-PRISM-LOAD))
              (memv prism-tag (sc2-raw-unit-command-unit-tags c))
              (= (sc2-raw-unit-command-target-unit-tag c) imm-tag))))
     (define unqueued-move-cancel?
       (for/or ([c (in-list wcmds)])
         (and (sc2-raw-unit-command? c)
              (= (sc2-raw-unit-command-ability-id c) AB-MOVE)
              (memv prism-tag (sc2-raw-unit-command-unit-tags c))
              (not (sc2-raw-unit-command-queue? c)))))
     (values out
             (list
              (mk-check "warp-prism-loads-low-hp-immortal-without-unqueued-cancel"
                        (and loaded-imm? (not unqueued-move-cancel?))
                        (format "loaded-imm?=~a unqueued-move-cancel?=~a prism wire abs=~a"
                                loaded-imm? unqueued-move-cancel? (wire-abilities-for-tag wcmds prism-tag))))))))

;; 85. Novel-54: Zerg Baneling Move-Targets Light Marine Clump Past Closer Armored Marauder
(define scen-novel-54
  (tactical-scenario
   "novel-54-zerg-baneling-rolls-into-marine-clump-past-marauder"
   "novel" "Zerg" "Terran" "focus-fire"
   "Novel: Zerg Banelings move-roll into clumped Light Marines (84.5,80.0) instead of detonating early on closer Armored Marauder (83.0,80.0)"
   (lambda ()
     (define bane-tags '(3640 3641 3642))
     (define allies
       (append (mk-home-base-units 'Zerg #:with-natural? #t)
               (for/list ([t (in-list bane-tags)] [i (in-naturals)])
                 (mk-unit t 'baneling 1 80.0 (+ 79.5 (* 0.5 i)) #:hp 30.0 #:hp-max 30.0))))
     (define enemies
       (list (mk-unit 7640 'marauder 4 83.0 80.0 #:hp 125.0 #:hp-max 125.0)
             (mk-unit 7641 'marine   4 84.5 80.0 #:hp 45.0 #:hp-max 45.0)
             (mk-unit 7642 'marine   4 84.7 80.3 #:hp 45.0 #:hp-max 45.0)
             (mk-unit 7643 'marine   4 84.7 79.7 #:hp 45.0 #:hp-max 45.0)
             (mk-unit 7644 'marine   4 85.0 80.0 #:hp 45.0 #:hp-max 45.0)))
     (define s1 (mk-obs 7200 (append allies enemies) #:food-used 28 #:food-cap 54 #:food-army 4 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Zerg 'Terran (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define rolled-to-marines?
       (for/or ([c (in-list wcmds)])
         (and (sc2-raw-unit-command? c)
              (memv (sc2-raw-unit-command-ability-id c) (list AB-MOVE AB-ATTACK))
              (ormap (lambda (t) (memv t bane-tags)) (sc2-raw-unit-command-unit-tags c))
              (or (memv (sc2-raw-unit-command-target-unit-tag c) '(7641 7642 7643 7644))
                  (and (sc2-point2d? (sc2-raw-unit-command-target-pos c))
                       (>= (sc2-point2d-x (sc2-raw-unit-command-target-pos c)) 84.0))))))
     (define wasted-on-marauder?
       (for/or ([c (in-list wcmds)])
         (and (sc2-raw-unit-command? c)
              (= (sc2-raw-unit-command-ability-id c) AB-ATTACK)
              (ormap (lambda (t) (memv t bane-tags)) (sc2-raw-unit-command-unit-tags c))
              (= (sc2-raw-unit-command-target-unit-tag c) 7640))))
     (values out
             (list
              (mk-check "banelings-target-marine-clump-over-armored-marauder"
                        (and rolled-to-marines? (not wasted-on-marauder?))
                        (format "rolled-to-marines?=~a wasted-on-marauder?=~a" rolled-to-marines? wasted-on-marauder?)))))))

;; 86. Novel-55: W5-EARLY-1 Zerg ZvZ 12-Pool Early Rush Defense (Queen + Lings + Spine Hold)
(define scen-novel-55
  (tactical-scenario
   "novel-55-zerg-12pool-early-rush-defense-queen-ling-spine"
   "novel" "Zerg" "Zerg" "home-defense"
   "Novel (W5-EARLY-1): Early 12-Pool Zergling rush hitting Zerg natural/main at 2:15 -> Queen + defender Lings + Spine engage locally without pure-MOVE fleeing"
   (lambda ()
     (define def-tags '(3651 3652 3653 3654 3655))
     (define enemy-tags (for/list ([i (in-range 6)]) (+ 7650 i)))
     (define allies
       (append
        (list (mk-unit 1 'hatchery 1 32.0 32.0 #:buffs '(11))
              (mk-unit 2 'hatchery 1 52.0 34.0 #:buffs '(11))
              (mk-unit 10 'spawning-pool 1 36.0 34.0)
              (mk-unit 11 'spine-crawler 1 48.0 34.5 #:hp 300.0 #:hp-max 300.0)
              (mk-unit 3651 'queen 1 49.0 34.0 #:hp 175.0 #:hp-max 175.0 #:energy 50.0)
              (mk-unit 3652 'zergling 1 50.0 34.0)
              (mk-unit 3653 'zergling 1 50.0 34.5)
              (mk-unit 3654 'zergling 1 50.5 34.0)
              (mk-unit 3655 'zergling 1 50.5 34.5))
        (for/list ([i (in-range 14)])
          (mk-unit (+ 20 i) 'drone 1 28.0 (+ 28.0 (* 0.35 i))))))
     (define enemies
       (for/list ([t (in-list enemy-tags)] [i (in-naturals)])
         (mk-unit t 'zergling 4 53.5 (+ 33.5 (* 0.4 i)))))
     (define s1 (mk-obs 3024 (append allies enemies) #:food-used 18 #:food-cap 28 #:food-army 4 #:food-workers 14))
     (define out (last (run-pipeline-sequence 'Zerg 'Zerg (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define def-active
       (for/sum ([t (in-list def-tags)])
         (if (wire-any-ability? wcmds (list t) (list AB-ATTACK 17 18)) 1 0)))
     (define def-pure-move (for/sum ([t (in-list def-tags)]) (if (wire-pure-move-only? wcmds t) 1 0)))
     (values out
             (list
              (mk-check "zerg-defenders-engage-12pool-zerglings"
                        (and (>= def-active 4) (= def-pure-move 0))
                        (format "Zerg defenders active-combat=~a/5 (ATK/PATROL/HOLD), pure-MOVE=~a/5 vs 6 early Zerglings" def-active def-pure-move)))))))

;; 87. Novel-56: W5-EARLY-1 Terran 12-Pool Early Rush Ramp Defense (Depot Raise + Marines Engage)
(define scen-novel-56
  (tactical-scenario
   "novel-56-terran-12pool-early-rush-ramp-defense"
   "novel" "Terran" "Zerg" "home-defense"
   "Novel (W5-EARLY-1): Early 12-Pool Zergling rush hitting Terran ramp at 2:15 -> lowered Supply Depot raises (558) AND ramp Marines attack Zerglings without pure-MOVE fleeing"
   (lambda ()
     (define dep-tag 3660)
     (define mar-tags '(3661 3662 3663 3664))
     (define enemy-tags (for/list ([i (in-range 6)]) (+ 7660 i)))
     (define allies
       (append
        (list (mk-unit 1 'command-center 1 32.0 32.0)
              (mk-unit 10 'barracks 1 45.0 46.5)
              (mk-unit dep-tag 'supply-depot-lowered 1 46.0 46.0 #:hp 400.0 #:hp-max 400.0))
        (for/list ([i (in-range 16)])
          (mk-unit (+ 20 i) 'scv 1 28.0 (+ 28.0 (* 0.35 i))))
        (for/list ([t (in-list mar-tags)] [i (in-naturals)])
          (mk-unit t 'marine 1 44.5 (+ 45.0 (* 0.5 i))))))
     (define enemies
       (for/list ([t (in-list enemy-tags)] [i (in-naturals)])
         (mk-unit t 'zergling 4 48.5 (+ 45.5 (* 0.4 i)))))
     (define s1 (mk-obs 3024 (append allies enemies) #:food-used 20 #:food-cap 31 #:food-army 4 #:food-workers 16))
     (define out (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define raised? (wire-has-ability? wcmds (list dep-tag) AB-DEPOT-RAISE))
     (define mar-atk (wire-count-local-attacks wcmds mar-tags enemy-tags 48.5 46.5 14.0))
     (values out
             (list
              (mk-check "terran-ramp-depot-raises-558-vs-12pool"
                        raised?
                        (format "depot-3660 wire abs=~a (expected ~a RAISE)" (wire-abilities-for-tag wcmds dep-tag) AB-DEPOT-RAISE))
              (mk-check "terran-ramp-marines-engage-12pool-zerglings"
                        (>= mar-atk 3)
                        (format "ramp Marines local-ATK=~a/4 vs 6 Zerglings" mar-atk)))))))

;; 88. W5-TAC-1 (from real-SC2 z04: 4.40x -> 0.61x): `rt-spotter-lings` Steals Active Combat Zerglings Mid-Fight!
;;     `lib/bot-runtime.rkt:18052-18073` picks the closest Zergling to enemy front/3rd/4th with ZERO
;;     active-combat proximity check, peeling 3 Zerglings (30% of the pack!) right out of battle (`7.5t`
;;     from Protoss army!) and ordering them `(move sid 116.5 116.5)` across the map!
(define scen-w5-tac-1
  (tactical-scenario
   "w5-tac-1-spotter-lings-never-stolen-mid-combat"
   "wave5-repro" "Zerg" "Protoss" "unit-mobility-micro"
   "Wave-5 Repro (W5-TAC-1 / z04): Zerglings engaged 7.5t from enemy Protoss army must NEVER be stolen by rt-spotter-lings into cross-map MOVE(16) orders"
   (lambda ()
     (define ling-tags (for/list ([i (in-range 10)]) (+ 3700 i)))
     (define enemy-tags (append '(7701 7702 7703 7710) (for/list ([i (in-range 6)]) (+ 7720 i))))
     (define allies
       (append
        (mk-home-base-units 'Zerg #:with-natural? #t)
        (for/list ([t (in-list ling-tags)] [i (in-naturals)])
          (mk-unit t 'zergling 1 76.5 (+ 78.0 (* 0.4 i)) #:hp 35.0 #:hp-max 35.0))
        (list (mk-unit 3720 'ultralisk 1 76.0 79.5 #:hp 500.0 #:hp-max 500.0)
              (mk-unit 3721 'ultralisk 1 76.0 80.5 #:hp 500.0 #:hp-max 500.0))))
     (define enemies
       (append
        (list (mk-unit 7701 'zealot   4 84.0 79.0 #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0)
              (mk-unit 7702 'zealot   4 84.0 80.0 #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0)
              (mk-unit 7703 'zealot   4 84.0 81.0 #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0)
              (mk-unit 7710 'immortal 4 84.8 80.0 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0))
        (for/list ([i (in-range 6)])
          (mk-unit (+ 7720 i) 'stalker 4 85.5 (+ 78.5 (* 0.6 i)) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))))
     (define s1 (mk-obs 12400 (append allies enemies) #:food-used 46 #:food-cap 66 #:food-army 22 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Zerg 'Protoss (list (hash 'obs s1)))))
     (define raw-acts (step-outcome-bot-actions out))
     (define wcmds (step-outcome-wire-cmds out))
     (define raw-spotter-steals
       (for/sum ([t (in-list ling-tags)])
         (if (for/or ([a (in-list raw-acts)])
               (and (pair? a) (eq? (car a) 'move) (>= (length a) 4)
                    (or (equal? (cadr a) t) (and (list? (cadr a)) (memv t (cadr a))))
                    (real? (caddr a)) (real? (cadddr a))
                    (> (dist2d-xy (exact->inexact (caddr a)) (exact->inexact (cadddr a)) 80.0 80.0) 20.0)))
             1 0)))
     (define ling-atk (wire-count-local-attacks wcmds ling-tags enemy-tags 84.5 80.0 14.0))
     (values out
             (list
              (mk-check "zero-combat-zerglings-stolen-by-spotter-posts"
                        (and (= raw-spotter-steals 0) (>= ling-atk 9))
                        (format "raw spotter-stolen Lings=~a/10, wire local-ATK=~a/10 (spotter-lings must not steal fighting Lings!)"
                                raw-spotter-steals ling-atk)))))))

;; 89. W5-TAC-2 (from real-SC2 z04: 4.40x -> 0.61x): Frontline Combat Queens Recalled 64t Home Mid-Fight!
;;     `lib/bot-runtime.rkt:20979-20990` (`queen-home-recall`) only exempts Queens when an ally is ALREADY
;;     `< 65%` HP (`queen-urgent-transfuse?`), with ZERO active-combat proximity check! So 3 full-energy
;;     combat Queens marching with Ultralisks 9t from enemy Zealots/Stalkers are ordered `(move 32,32)` home!
(define scen-w5-tac-2
  (tactical-scenario
   "w5-tac-2-combat-queens-never-recalled-home-mid-fight"
   "wave5-repro" "Zerg" "Protoss" "support-preservation"
   "Wave-5 Repro (W5-TAC-2 / z04): 3 full-energy frontline Queens fighting 9t from Protoss army with Ultralisks must NOT be recalled 64t home to (32,32) and must engage"
   (lambda ()
     (define queen-tags '(3730 3731 3732))
     (define enemy-tags (append '(7731 7732 7733 7740) (for/list ([i (in-range 6)]) (+ 7750 i))))
     (define allies
       (append
        (list (mk-unit 1 'hatchery 1 32.0 32.0))
        (for/list ([i (in-range 16)])
          (mk-unit (+ 20 i) 'drone 1 28.0 (+ 28.0 (* 0.35 i))))
        (for/list ([i (in-range 10)])
          (mk-unit (+ 3740 i) 'zergling 1 76.5 (+ 78.0 (* 0.4 i))))
        (list (mk-unit 3750 'ultralisk 1 76.0 79.5 #:hp 500.0 #:hp-max 500.0)
              (mk-unit 3751 'ultralisk 1 76.0 80.5 #:hp 500.0 #:hp-max 500.0)
              (mk-unit 3730 'queen 1 74.8 79.0 #:hp 175.0 #:hp-max 175.0 #:energy 120.0)
              (mk-unit 3731 'queen 1 74.8 80.0 #:hp 175.0 #:hp-max 175.0 #:energy 120.0)
              (mk-unit 3732 'queen 1 74.8 81.0 #:hp 175.0 #:hp-max 175.0 #:energy 120.0))))
     (define enemies
       (append
        (list (mk-unit 7731 'zealot   4 84.0 79.0 #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0)
              (mk-unit 7732 'zealot   4 84.0 80.0 #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0)
              (mk-unit 7733 'zealot   4 84.0 81.0 #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0)
              (mk-unit 7740 'immortal 4 84.8 80.0 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0))
        (for/list ([i (in-range 6)])
          (mk-unit (+ 7750 i) 'stalker 4 85.5 (+ 78.5 (* 0.6 i)) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))))
     (define s1 (mk-obs 12400 (append allies enemies) #:food-used 42 #:food-cap 66 #:food-army 26 #:food-workers 16))
     (define out (last (run-pipeline-sequence 'Zerg 'Protoss (list (hash 'obs s1)))))
     (define raw-acts (step-outcome-bot-actions out))
     (define wcmds (step-outcome-wire-cmds out))
     (define raw-recalled-home
       (for/sum ([t (in-list queen-tags)])
         (if (for/or ([a (in-list raw-acts)])
               (and (pair? a) (eq? (car a) 'move) (>= (length a) 4)
                    (or (equal? (cadr a) t) (and (list? (cadr a)) (memv t (cadr a))))
                    (real? (caddr a)) (real? (cadddr a))
                    (< (dist2d-xy (exact->inexact (caddr a)) (exact->inexact (cadddr a)) 32.0 32.0) 20.0)))
             1 0)))
     (define queen-atk (wire-count-local-attacks wcmds queen-tags enemy-tags 84.5 80.0 16.0))
     (values out
             (list
              (mk-check "frontline-combat-queens-not-recalled-home-mid-fight"
                        (and (= raw-recalled-home 0) (>= queen-atk 2))
                        (format "Queens recalled home (32,32)=~a/3, wire local-ATK=~a/3 while fighting 9t from Protoss army!"
                                raw-recalled-home queen-atk)))))))

;; 90. W5-TAC-3 (NEW systemic 12-unit dead-code bug!): `RUNTIME-SPELLCASTER-SET` (`bot-runtime.rkt:516-518`)
;;     omits 12 units already wired in `PRO-CASTER-RACE-HT` (`L20733`), including `phoenix`, `swarm-host`,
;;     `medivac`, `corruptor`, `overseer`, `lurker*`, `infestor-burrowed`, `cyclone`, `scv`, `disruptor`!
;;     When an army lacks the 10 listed casters, `any-pro-caster?` is `#f` and `plan-*-spellcaster-micro`
;;     is 100% SKIPPED (Phoenix tries to ground-ATTACK Immortal; Swarm Host walks into melee; Medivac 0 heal)!
(define scen-w5-tac-3
  (tactical-scenario
   "w5-tac-3-runtime-spellcaster-set-unlocks-phoenix-swarmhost-medivac"
   "wave5-repro" "Protoss" "Zerg" "spellcasters"
   "Wave-5 Repro (W5-TAC-3): Standalone Phoenix casts Graviton Beam (173), standalone Swarm Host casts Spawn Locusts (1990/2704), standalone Bio+Medivac casts Heal (386)"
   (lambda ()
     ;; Part A: Standalone Phoenix (no Sentry/HT/Oracle!) + Stalker vs Immortal -> Graviton Beam (173)
     (define phx-tag 3761)
     (define s1 (mk-obs 8400
                        (list (mk-unit 1 'nexus 1 32.0 32.0 #:shield 1000.0 #:shield-max 1000.0)
                              (mk-unit phx-tag 'phoenix 1 80.0 80.0 #:hp 120.0 #:hp-max 120.0 #:shield 60.0 #:shield-max 60.0 #:energy 100.0 #:flying? #t)
                              (mk-unit 3762 'stalker 1 79.0 80.0 #:shield 80.0 #:shield-max 80.0)
                              (mk-unit 7761 'immortal 4 84.5 80.0 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0))
                        #:food-used 24 #:food-cap 54 #:food-army 4 #:food-workers 20))
     (define out-a (last (run-pipeline-sequence 'Protoss 'Protoss (list (hash 'obs s1)))))
     (define lifted? (wire-has-ability? (step-outcome-wire-cmds out-a) (list phx-tag) AB-GRAVITON-BEAM))
     ;; Part B: Standalone Swarm Host (no Queen/Ravager/Infestor/Viper!) vs Stalker+Nexus -> Spawn Locusts (1990/2704)
     (define sh-tag 3765)
     (define s2 (mk-obs 10200
                        (list (mk-unit 1 'hatchery 1 32.0 32.0)
                              (mk-unit sh-tag 'swarm-host 1 80.0 80.0 #:hp 160.0 #:hp-max 160.0)
                              (mk-unit 7765 'stalker 4 92.0 80.0 #:shield 80.0 #:shield-max 80.0)
                              (mk-unit 7766 'nexus 4 96.0 80.0 #:shield 1000.0 #:shield-max 1000.0))
                        #:food-used 23 #:food-cap 54 #:food-army 3 #:food-workers 20))
     (define out-b (last (run-pipeline-sequence 'Zerg 'Protoss (list (hash 'obs s2)))))
     (define spawned? (wire-any-ability? (step-outcome-wire-cmds out-b) (list sh-tag) (list AB-SPAWN-LOCUSTS AB-SPAWN-LOCUSTS-FLYING)))
     ;; Part C: Standalone Bio+Medivac (no Ghost/Raven/BC/SCV!) with injured Marauder -> Medivac Heal (386)
     (define med-tag 3768)
     (define s3 (mk-obs 8200
                        (list (mk-unit 1 'command-center 1 32.0 32.0)
                              (mk-unit med-tag 'medivac 1 78.0 80.0 #:hp 150.0 #:hp-max 150.0 #:energy 100.0 #:flying? #t)
                              (mk-unit 3769 'marauder 1 80.0 80.0 #:hp 55.0 #:hp-max 125.0)
                              (mk-unit 7769 'stalker 4 86.0 80.0 #:shield 80.0 #:shield-max 80.0))
                        #:food-used 10 #:food-cap 30 #:food-army 4 #:food-workers 6))
     (define out-c (last (run-pipeline-sequence 'Terran 'Protoss (list (hash 'obs s3)))))
     (define healed? (wire-has-ability? (step-outcome-wire-cmds out-c) (list med-tag) AB-HEAL))
     (values out-a
             (list
              (mk-check "standalone-phoenix-casts-graviton-beam-173"
                        lifted?
                        (format "phoenix-3761 wire abs=~a (expected ~a GRAVITON-BEAM; RUNTIME-SPELLCASTER-SET missing phoenix!)"
                                (wire-abilities-for-tag (step-outcome-wire-cmds out-a) phx-tag) AB-GRAVITON-BEAM))
              (mk-check "standalone-swarm-host-casts-spawn-locusts"
                        spawned?
                        (format "swarm-host-3765 wire abs=~a (expected ~a/~a SPAWN-LOCUSTS; RUNTIME-SPELLCASTER-SET missing swarm-host!)"
                                (wire-abilities-for-tag (step-outcome-wire-cmds out-b) sh-tag) AB-SPAWN-LOCUSTS AB-SPAWN-LOCUSTS-FLYING))
              (mk-check "standalone-medivac-casts-heal-386"
                        healed?
                        (format "medivac-3768 wire abs=~a (expected ~a HEAL; RUNTIME-SPELLCASTER-SET missing medivac!)"
                                (wire-abilities-for-tag (step-outcome-wire-cmds out-c) med-tag) AB-HEAL)))))))

;; 91. W5-TAC-4 (from real-SC2 t04 40S + pro-spellcaster-micro.rkt:3095, 3148):
;;     (a) 2 Medivacs stack both Heal (386) beams onto the SAME Marauder (SC2 only allows 1 beam/target!)
;;         instead of healing 2 distinct injured Bio units;
;;     (b) 2 Battlecruisers facing 2 135-HP Vikings both pick Viking #1, BC #2 fails 1-shot claim cap and
;;         drops Yamato (401) on Viking #2!
(define scen-w5-tac-4
  (tactical-scenario
   "w5-tac-4-medivac-distinct-heal-and-bc-distinct-yamato"
   "wave5-repro" "Terran" "Zerg" "spellcasters"
   "Wave-5 Repro (W5-TAC-4 / t04): 2 Medivacs spread Heal (386) across 2 DISTINCT injured Bio units; 2 BCs cast Yamato (401) on 2 DISTINCT Vikings"
   (lambda ()
     ;; Part A: 2 Medivacs + 4 injured Marauders -> 2 DISTINCT heal targets (386)!
     (define med-tags '(3771 3772))
     (define bio-tags '(3773 3774 3775 3776))
     (define s1 (mk-obs 13808
                        (append
                         (mk-home-base-units 'Terran #:with-natural? #t)
                         (list (mk-unit 3770 'ghost 1 74.5 80.0 #:energy 20.0)
                               (mk-unit 3771 'medivac 1 75.0 79.5 #:hp 150.0 #:hp-max 150.0 #:energy 110.0 #:flying? #t)
                               (mk-unit 3772 'medivac 1 75.0 80.5 #:hp 150.0 #:hp-max 150.0 #:energy 110.0 #:flying? #t)
                               (mk-unit 3773 'marauder 1 76.5 79.0 #:hp 70.0 #:hp-max 125.0)
                               (mk-unit 3774 'marauder 1 76.5 79.7 #:hp 70.0 #:hp-max 125.0)
                               (mk-unit 3775 'marauder 1 76.5 80.3 #:hp 70.0 #:hp-max 125.0)
                               (mk-unit 3776 'marauder 1 76.5 81.0 #:hp 70.0 #:hp-max 125.0)
                               (mk-unit 7771 'zergling 4 82.0 80.0)))
                        #:food-used 38 #:food-cap 66 #:food-army 14 #:food-workers 24))
     (define out-a (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s1)))))
     (define wcmds-a (step-outcome-wire-cmds out-a))
     (define heal-targets
       (remove-duplicates
        (for/list ([c (in-list wcmds-a)]
                   #:when (and (sc2-raw-unit-command? c)
                               (= (sc2-raw-unit-command-ability-id c) AB-HEAL)
                               (ormap (lambda (t) (memv t med-tags)) (sc2-raw-unit-command-unit-tags c))
                               (memv (sc2-raw-unit-command-target-unit-tag c) bio-tags)))
          (sc2-raw-unit-command-target-unit-tag c))))
     ;; Part B: 2 Battlecruisers (Weapon Refit) vs 2 135-HP Vikings -> 2 DISTINCT Yamato targets (401)!
     (define bc-tags '(3781 3782))
     (define vik-tags '(7781 7782))
     (define s2 (mk-obs 14200
                        (append
                         (mk-home-base-units 'Terran #:with-natural? #t)
                         (list (mk-unit 3781 'battlecruiser 1 78.0 79.5 #:hp 550.0 #:hp-max 550.0 #:flying? #t)
                               (mk-unit 3782 'battlecruiser 1 78.0 80.5 #:hp 550.0 #:hp-max 550.0 #:flying? #t)
                               (mk-unit 7781 'viking-fighter 4 85.0 79.5 #:hp 135.0 #:hp-max 135.0 #:flying? #t)
                               (mk-unit 7782 'viking-fighter 4 85.0 80.5 #:hp 135.0 #:hp-max 135.0 #:flying? #t)))
                        #:food-used 36 #:food-cap 66 #:food-army 12 #:food-workers 24
                        #:upgrades '(weapon-refit)))
     (define out-b (last (run-pipeline-sequence 'Terran 'Terran (list (hash 'obs s2)))))
     (define wcmds-b (step-outcome-wire-cmds out-b))
     (define yam-targets
       (remove-duplicates
        (for/list ([c (in-list wcmds-b)]
                   #:when (and (sc2-raw-unit-command? c)
                               (= (sc2-raw-unit-command-ability-id c) AB-YAMATO-CANNON)
                               (ormap (lambda (t) (memv t bc-tags)) (sc2-raw-unit-command-unit-tags c))
                               (memv (sc2-raw-unit-command-target-unit-tag c) vik-tags)))
          (sc2-raw-unit-command-target-unit-tag c))))
     (values out-a
             (list
              (mk-check "two-medivacs-heal-two-distinct-injured-bio"
                        (= (length heal-targets) 2)
                        (format "Medivac Heal distinct targets=~a (expected 2 distinct targets from ~a)" heal-targets bio-tags))
              (mk-check "two-bcs-yamato-two-distinct-vikings"
                        (= (length yam-targets) 2)
                        (format "BC Yamato distinct targets=~a (expected both 7781 & 7782; wire abs=~a)"
                                yam-targets
                                (for/list ([t bc-tags]) (cons t (wire-abilities-for-tag wcmds-b t))))))))))

;; 92. W5-TAC-5 (from real-SC2 t04: 1.26x W -> 0.15x T): Bio-Ghost Army Splits in Half at 8.5t!
;;     24-supply Terran (8 Marines + 4 Marauders + 2 Ghosts 120en + 2 Medivacs 120en) vs 21-supply Zerg
;;     (2 Ultralisks + 10 Lings + 2 Infestors) at 8.5t: `combat-suppress-attack?` fires `#t`, causing ALL
;;     8/8 ready-weapon Marines (`dist=8.5t > fire-r=7.5t`) to FLEE BACKWARDS (`kite 74,79`) while
;;     Marauders charge forward (`plan-marauder-concussive-targets`) and Ghosts stand still channeling Snipe!
(define scen-w5-tac-5
  (tactical-scenario
   "w5-tac-5-bio-ghost-marines-do-not-flee-behind-sniping-ghosts"
   "wave5-repro" "Terran" "Zerg" "stutter-step-and-pullback"
   "Wave-5 Repro (W5-TAC-5 / t04): 24-supply Bio+Ghost+Medivac vs 21-supply Ultra+Ling+Infestor at 8.5t — Marines must NOT flee backwards behind channeling Ghosts & engaging Marauders"
   (lambda ()
     (define marine-tags (for/list ([i (in-range 8)]) (+ 3810 i)))
     (define enemy-tags (append '(7801 7802 7820 7821) (for/list ([i (in-range 10)]) (+ 7810 i))))
     (define allies
       (append
        (mk-home-base-units 'Terran #:with-natural? #t)
        (for/list ([i (in-range 4)]) (mk-unit (+ 3800 i) 'marauder 1 76.5 (+ 79.0 (* 0.6 i)) #:hp 125.0 #:hp-max 125.0))
        (for/list ([t (in-list marine-tags)] [i (in-naturals)])
          (mk-unit t 'marine 1 75.5 (+ 78.0 (* 0.5 i)) #:hp 45.0 #:hp-max 45.0 #:weapon-cooldown 0.0))
        (list (mk-unit 3820 'ghost   1 74.5 79.5 #:hp 100.0 #:hp-max 100.0 #:energy 120.0)
              (mk-unit 3821 'ghost   1 74.5 80.5 #:hp 100.0 #:hp-max 100.0 #:energy 120.0)
              (mk-unit 3825 'medivac 1 74.0 79.5 #:hp 150.0 #:hp-max 150.0 #:energy 120.0 #:flying? #t)
              (mk-unit 3826 'medivac 1 74.0 80.5 #:hp 150.0 #:hp-max 150.0 #:energy 120.0 #:flying? #t))))
     (define enemies
       (append
        (list (mk-unit 7801 'ultralisk 4 84.0 79.5 #:hp 500.0 #:hp-max 500.0)
              (mk-unit 7802 'ultralisk 4 84.0 80.5 #:hp 500.0 #:hp-max 500.0)
              (mk-unit 7820 'infestor  4 85.8 79.5 #:hp 90.0  #:hp-max 90.0  #:energy 120.0)
              (mk-unit 7821 'infestor  4 85.8 80.5 #:hp 90.0  #:hp-max 90.0  #:energy 120.0))
        (for/list ([i (in-range 10)]) (mk-unit (+ 7810 i) 'zergling 4 84.2 (+ 78.0 (* 0.4 i)) #:hp 35.0 #:hp-max 35.0))))
     (define s1 (mk-obs 13800 (append allies enemies) #:food-used 48 #:food-cap 66 #:food-army 24 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define mar-pure-move (for/sum ([t (in-list marine-tags)]) (if (wire-pure-move-only? wcmds t) 1 0)))
     (define mar-atk (wire-count-local-attacks wcmds marine-tags enemy-tags 84.2 80.0 16.0))
     (values out
             (list
              (mk-check "bio-ghost-marines-engage-not-flee-behind-sniping-ghosts"
                        (and (<= mar-pure-move 2) (>= mar-atk 6))
                        (format "t04 Marines (w-cd=0, 24sup vs 21sup w/ 2 sniping Ghosts): pure-MOVE=~a/8, local-ATK=~a/8"
                                mar-pure-move mar-atk)))))))

;; =============================================================================
;; Round-6 Pro-Inspired Regression Shields (novel-57..62)
;; =============================================================================

;; 57. Planetary Fortress SCV Auto-Repair Under Attack (W5-TAC-3 shield)
(define scen-novel-57
  (tactical-scenario
   "novel-57-terran-pf-scv-auto-repair"
   "novel" "Terran" "Zerg" "spellcasters"
   "Damaged Planetary Fortress under Zergling attack: nearby SCVs emit Repair (3685/316) despite adjacent mineral patches (W5-TAC-3 unlock shield)."
   (lambda ()
     (define scv-tags '(3910 3911 3912))
     (define allies
       (append
        (mk-home-base-units 'Terran #:with-natural? #t)
        (list (mk-unit 3905 'planetary-fortress 1 72.0 32.0 #:hp 700.0 #:hp-max 1500.0)
              (mk-unit 3907 'marine 1 71.0 34.0 #:hp 45.0 #:hp-max 45.0)
              (mk-unit 3908 'marine 1 71.0 30.0 #:hp 45.0 #:hp-max 45.0)
              (mk-unit 3910 'scv 1 69.5 32.0 #:hp 45.0 #:hp-max 45.0
                       #:orders (list (sc2-unit-order AB-GATHER #f 90021 0.0)))
              (mk-unit 3911 'scv 1 70.0 33.5 #:hp 45.0 #:hp-max 45.0
                       #:orders (list (sc2-unit-order AB-GATHER #f 90021 0.0)))
              (mk-unit 3912 'scv 1 70.0 30.5 #:hp 45.0 #:hp-max 45.0
                       #:orders (list (sc2-unit-order AB-GATHER #f 90021 0.0))))))
     (define enemies
       (for/list ([i (in-range 6)])
         (mk-unit (+ 7900 i) 'zergling 4 75.5 (+ 30.5 (* 0.6 i)) #:hp 35.0 #:hp-max 35.0)))
     (define s1 (mk-obs 14100 (append allies enemies)
                        #:minerals 250 #:vespene 100 #:food-used 36 #:food-cap 60 #:food-army 10 #:food-workers 26))
     (define out (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define rep-cnt
       (+ (wire-count-tags-with-ability wcmds scv-tags AB-REPAIR-GENERIC)
          (wire-count-tags-with-ability wcmds scv-tags AB-REPAIR-SCV)))
     (values out
             (list
              (mk-check "scvs-repair-damaged-planetary-fortress"
                        (>= rep-cnt 1)
                        (format "SCVs repairing damaged PF (3685/316): ~a/3" rep-cnt))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; 58. Disruptor Purification Nova Onto Enemy Bio Clump (W5-TAC-3 shield)
(define scen-novel-58
  (tactical-scenario
   "novel-58-protoss-disruptor-purification-nova-clump"
   "novel" "Protoss" "Terran" "spellcasters"
   "Protoss Disruptor facing clumped Marines + Marauders emits Purification Nova (2346) onto the bio cluster (W5-TAC-3 unlock shield)."
   (lambda ()
     (define allies
       (append
        (mk-home-base-units 'Protoss #:with-natural? #t)
        (list (mk-unit 3920 'disruptor 1 80.0 80.0 #:hp 100.0 #:hp-max 100.0 #:shield 100.0 #:shield-max 100.0)
              (mk-unit 3921 'stalker   1 77.5 80.0 #:hp 80.0  #:hp-max 80.0  #:shield 80.0  #:shield-max 80.0))))
     (define enemies
       (list (mk-unit 7920 'marine   4 88.0 80.0 #:hp 45.0  #:hp-max 45.0)
             (mk-unit 7921 'marine   4 88.5 80.5 #:hp 45.0  #:hp-max 45.0)
             (mk-unit 7922 'marine   4 88.5 79.5 #:hp 45.0  #:hp-max 45.0)
             (mk-unit 7923 'marauder 4 88.0 81.0 #:hp 125.0 #:hp-max 125.0)
             (mk-unit 7924 'marauder 4 88.0 79.0 #:hp 125.0 #:hp-max 125.0)))
     (define s1 (mk-obs 14200 (append allies enemies)
                        #:minerals 100 #:vespene 100 #:food-used 34 #:food-cap 56 #:food-army 10 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Protoss 'Terran (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define nova? (wire-has-ability? wcmds '(3920) AB-PURIFICATION-NOVA))
     (values out
             (list
              (mk-check "disruptor-casts-purification-nova"
                        nova?
                        (format "Disruptor 3920 emitted Purification Nova (2346): ~a" nova?))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; 59. Dual Cyclone Lock-On Distinct Armored Targets (W5-TAC-3 shield)
(define scen-novel-59
  (tactical-scenario
   "novel-59-terran-dual-cyclone-lock-on-distinct"
   "novel" "Terran" "Protoss" "spellcasters"
   "Two Terran Cyclones vs Void Ray + Immortal emit Lock-On (2350) onto distinct armored high-value targets without double-casting (W5-TAC-3 unlock shield)."
   (lambda ()
     (define cyc-tags '(3930 3931))
     (define allies
       (append
        (mk-home-base-units 'Terran #:with-natural? #t)
        (list (mk-unit 3930 'cyclone 1 80.0 80.0 #:hp 120.0 #:hp-max 120.0)
              (mk-unit 3931 'cyclone 1 80.0 82.0 #:hp 120.0 #:hp-max 120.0))))
     (define enemies
       (list (mk-unit 7930 'void-ray 4 86.0 80.0 #:hp 150.0 #:hp-max 150.0 #:shield 100.0 #:shield-max 100.0 #:flying? #t)
             (mk-unit 7931 'immortal 4 86.0 82.0 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0)))
     (define s1 (mk-obs 14300 (append allies enemies)
                        #:minerals 100 #:vespene 100 #:food-used 34 #:food-cap 56 #:food-army 10 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Terran 'Protoss (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define lock-tgts (wire-targets-for-tags wcmds cyc-tags AB-LOCK-ON))
     (define distinct-tgts (remove-duplicates (filter (lambda (t) (> t 0)) (map second lock-tgts))))
     (values out
             (list
              (mk-check "dual-cyclones-lock-on-distinct-armored-targets"
                        (= (length distinct-tgts) 2)
                        (format "Cyclone Lock-On (2350) cmds=~a, distinct_targets=~a" (length lock-tgts) distinct-tgts))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; 60. Zerg Corruptor Caustic Spray + Overseer Contaminate (W5-TAC-3 shield)
(define scen-novel-60
  (tactical-scenario
   "novel-60-zerg-corruptor-caustic-spray-and-overseer-contaminate"
   "novel" "Zerg" "Protoss" "spellcasters"
   "Undefended enemy Nexus + Robotics Facility: Corruptors cast Caustic Spray (2324) on Nexus and Overseer casts Contaminate (1825) on Robotics Facility (W5-TAC-3 unlock shield)."
   (lambda ()
     (define allies
       (append
        (mk-home-base-units 'Zerg #:with-natural? #t)
        (list (mk-unit 3940 'corruptor 1 136.0 140.0 #:hp 200.0 #:hp-max 200.0 #:flying? #t)
              (mk-unit 3941 'corruptor 1 136.0 142.0 #:hp 200.0 #:hp-max 200.0 #:flying? #t)
              (mk-unit 3942 'overseer  1 141.0 140.0 #:hp 200.0 #:hp-max 200.0 #:energy 150.0 #:flying? #t))))
     (define enemies
       (list (mk-unit 7940 'nexus             4 140.0 140.0 #:hp 1000.0 #:hp-max 1000.0 #:shield 1000.0 #:shield-max 1000.0)
             (mk-unit 7941 'robotics-facility 4 144.0 140.0 #:hp 450.0  #:hp-max 450.0  #:shield 450.0  #:shield-max 450.0)))
     (define s1 (mk-obs 14400 (append allies enemies)
                        #:minerals 100 #:vespene 100 #:food-used 36 #:food-cap 60 #:food-army 12 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Zerg 'Protoss (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define spray? (wire-has-ability? wcmds '(3940 3941) AB-CAUSTIC-SPRAY))
     (define contam? (wire-has-ability? wcmds '(3942) AB-CONTAMINATE))
     (values out
             (list
              (mk-check "corruptors-cast-caustic-spray"
                        spray?
                        (format "Corruptors emitted Caustic Spray (2324): ~a" spray?))
              (mk-check "overseer-casts-contaminate"
                        contam?
                        (format "Overseer emitted Contaminate (1825): ~a" contam?))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; 61. Terran Medivac Low-HP Ignite Afterburners Boost (W5-TAC-3 shield)
(define scen-novel-61
  (tactical-scenario
   "novel-61-terran-medivac-low-hp-boost-evac"
   "novel" "Terran" "Protoss" "support-preservation"
   "Damaged Terran Medivac (<45% HP) near enemy Stalker anti-air emits Ignite Afterburners (2116) to escape (W5-TAC-3 unlock shield)."
   (lambda ()
     (define allies
       (append
        (mk-home-base-units 'Terran #:with-natural? #t)
        (list (mk-unit 3950 'medivac 1 80.0 80.0 #:hp 50.0 #:hp-max 150.0 #:energy 80.0 #:flying? #t))))
     (define enemies
       (list (mk-unit 7950 'stalker 4 85.0 80.0 #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0)
             (mk-unit 7951 'stalker 4 85.0 82.0 #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0)))
     (define s1 (mk-obs 14500 (append allies enemies)
                        #:minerals 50 #:vespene 0 #:food-used 28 #:food-cap 50 #:food-army 4 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Terran 'Protoss (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define boost? (wire-has-ability? wcmds '(3950) AB-MEDIVAC-BOOST))
     (values out
             (list
              (mk-check "low-hp-medivac-emits-ignite-afterburners"
                        boost?
                        (format "Low-HP Medivac 3950 emitted Ignite Afterburners (2116): ~a" boost?))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; 62. Terran Ghost Cloak WITH Personal Cloaking Upgrade Researched (positive shield counterpart to w6-tac-1)
(define scen-novel-62
  (tactical-scenario
   "novel-62-terran-ghost-cloak-with-personal-cloaking-upgrade"
   "novel" "Terran" "Zerg" "spellcasters"
   "Terran Ghosts WITH Personal Cloaking (id=25) researched cloak (382) when Ultralisks close <4.5t (disabling Snipe) and no enemy detector is within 11t."
   (lambda ()
     (define ghost-tags '(3960 3961))
     (define allies
       (append
        (mk-home-base-units 'Terran #:with-natural? #t)
        (list (mk-unit 3960 'ghost 1 80.0 79.0 #:hp 100.0 #:hp-max 100.0 #:energy 100.0)
              (mk-unit 3961 'ghost 1 80.0 81.0 #:hp 100.0 #:hp-max 100.0 #:energy 100.0))))
     (define enemies
       (list (mk-unit 7960 'ultralisk 4 83.8 79.0 #:hp 500.0 #:hp-max 500.0)
             (mk-unit 7961 'ultralisk 4 83.8 81.0 #:hp 500.0 #:hp-max 500.0)))
     (define s1 (mk-obs 14600 (append allies enemies)
                        #:minerals 50 #:vespene 0 #:upgrades '(25)
                        #:food-used 32 #:food-cap 56 #:food-army 8 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define cloak-cnt (wire-count-tags-with-ability wcmds ghost-tags AB-CLOAK-GHOST))
     (values out
             (list
              (mk-check "upgraded-ghosts-cast-cloak-382"
                        (>= cloak-cnt 1)
                        (format "Ghosts WITH personal-cloaking(25) emitting Cloak (382): ~a/2" cloak-cnt))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; =============================================================================
;; Tier 7: Wave-6 Verified Real-SC2 Physics & Live-Pipeline Bug Repros (4)
;; =============================================================================

;; W6-TAC-1: Ghost Spams Invalid Cloak (382) Without Personal Cloaking Upgrade
(define scen-w6-tac-1
  (tactical-scenario
   "w6-tac-1-terran-ghost-no-cloak-without-personal-cloaking"
   "wave6-repro" "Terran" "Zerg" "spellcasters"
   "Repro (t04 real-SC2 '382':6): Ghosts WITHOUT Personal Cloaking (id=25) researched must NOT emit invalid Cloak (382) in pro-spellcaster-micro.rkt:2931-2939."
   (lambda ()
     (define ghost-tags '(3970 3971))
     (define allies
       (append
        (mk-home-base-units 'Terran #:with-natural? #t)
        (list (mk-unit 3970 'ghost 1 80.0 79.0 #:hp 100.0 #:hp-max 100.0 #:energy 100.0)
              (mk-unit 3971 'ghost 1 80.0 81.0 #:hp 100.0 #:hp-max 100.0 #:energy 100.0))))
     (define enemies
       (list (mk-unit 7970 'ultralisk 4 83.8 79.0 #:hp 500.0 #:hp-max 500.0)
             (mk-unit 7971 'ultralisk 4 83.8 81.0 #:hp 500.0 #:hp-max 500.0)))
     (define s1 (mk-obs 14700 (append allies enemies)
                        #:minerals 50 #:vespene 0 #:upgrades '()
                        #:food-used 32 #:food-cap 56 #:food-army 8 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define cloak-cnt (wire-count-tags-with-ability wcmds ghost-tags AB-CLOAK-GHOST))
     (values out
             (list
              (mk-check "unupgraded-ghosts-never-emit-cloak-382"
                        (= cloak-cnt 0)
                        (format "Ghosts WITHOUT personal-cloaking emitting invalid Cloak (382): ~a/2 (expected 0)" cloak-cnt))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; W6-TAC-2: Zerg Mid-Fight Combat Cocoon Morph Suicide (Ravager 2330 / Baneling 80)
(define scen-w6-tac-2
  (tactical-scenario
   "w6-tac-2-zerg-no-mid-fight-ravager-baneling-cocoon-morph"
   "wave6-repro" "Zerg" "Terran" "combat-preservation"
   "Repro (sc2-protobuf-ws.rkt:7253-7300): Roaches & Zerglings fighting 10 enemy Marines at 2.5-4.0t must NOT morph into immobile Ravager (2330) or Baneling (80) cocoons mid-fight."
   (lambda ()
     (define roach-tags (for/list ([i (in-range 6)]) (+ 3980 i)))
     (define ling-tags  (for/list ([i (in-range 6)]) (+ 3990 i)))
     (define allies
       (append
        (mk-home-base-units 'Zerg #:with-natural? #t)
        (list (mk-unit 3978 'roach-warren  1 36.0 32.0 #:hp 850.0 #:hp-max 850.0)
              (mk-unit 3979 'baneling-nest 1 36.0 36.0 #:hp 850.0 #:hp-max 850.0))
        (for/list ([t (in-list roach-tags)] [i (in-naturals)])
          (mk-unit t 'roach 1 80.0 (+ 77.5 i) #:hp 145.0 #:hp-max 145.0))
        (for/list ([t (in-list ling-tags)] [i (in-naturals)])
          (mk-unit t 'zergling 1 81.5 (+ 77.5 i) #:hp 35.0 #:hp-max 35.0))))
     (define enemies
       (for/list ([i (in-range 10)])
         (mk-unit (+ 7980 i) 'marine 4 84.0 (+ 76.5 (* 0.8 i)) #:hp 45.0 #:hp-max 45.0)))
     (define s1 (mk-obs 14800 (append allies enemies)
                        #:minerals 400 #:vespene 400 #:food-used 42 #:food-cap 66 #:food-army 18 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Zerg 'Terran (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define rav-morphs (wire-count-tags-with-ability wcmds roach-tags AB-MORPH-RAVAGER))
     (define bane-morphs (wire-count-tags-with-ability wcmds ling-tags AB-MORPH-BANELING))
     (values out
             (list
              (mk-check "no-mid-fight-ravager-cocoon-morph"
                        (= rav-morphs 0)
                        (format "Frontline Roaches morphing Ravager (2330) 4t from 10 Marines: ~a/6 (expected 0)" rav-morphs))
              (mk-check "no-mid-fight-baneling-cocoon-morph"
                        (= bane-morphs 0)
                        (format "Frontline Zerglings morphing Baneling (80) 2.5t from 10 Marines: ~a/6 (expected 0)" bane-morphs))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; W6-TAC-3: Siege-Line-Hold Zero-DPS Pure-MOVE Retreat While Marines Are Inside Roach Weapon Range
(define scen-w6-tac-3
  (tactical-scenario
   "w6-tac-3-zerg-siege-line-hold-fire-ready-vs-in-range-bio"
   "wave6-repro" "Zerg" "Terran" "stutter-step"
   "Repro (z02 real-SC2 23:1 vs 16:21, bot-runtime.rkt:17735-17741): Weapon-ready Roaches (w-cd=0) with 8 enemy Marines at 3.5t (inside 4.0t range) and 2 Sieged Tanks at 8.5t must fire ATTACK (23) instead of pure-MOVE (16) suicide."
   (lambda ()
     (define roach-tags (for/list ([i (in-range 6)]) (+ 4000 i)))
     (define rav-tags   '(4010 4011 4012))
     (define enemy-tags (append (for/list ([i (in-range 8)]) (+ 8000 i)) '(8020 8021)))
     (define allies
       (append
        (mk-home-base-units 'Zerg #:with-natural? #t)
        (list (mk-unit 3998 'roach-warren 1 36.0 32.0 #:hp 850.0 #:hp-max 850.0))
        (for/list ([t (in-list roach-tags)] [i (in-naturals)])
          (mk-unit t 'roach 1 80.0 (+ 77.5 i) #:hp 145.0 #:hp-max 145.0 #:weapon-cooldown 0.0))
        (for/list ([t (in-list rav-tags)] [i (in-naturals)])
          (mk-unit t 'ravager 1 80.0 (+ 78.5 (* 1.5 i)) #:hp 120.0 #:hp-max 120.0 #:weapon-cooldown 0.0))))
     (define enemies
       (append
        (for/list ([i (in-range 8)])
          (mk-unit (+ 8000 i) 'marine 4 83.5 (+ 77.0 (* 0.85 i)) #:hp 45.0 #:hp-max 45.0))
        (list (mk-unit 8020 'siege-tank-sieged 4 88.5 79.0 #:hp 175.0 #:hp-max 175.0)
              (mk-unit 8021 'siege-tank-sieged 4 88.5 81.0 #:hp 175.0 #:hp-max 175.0))))
     (define s1 (mk-obs 14900 (append allies enemies)
                        #:minerals 50 #:vespene 0 #:food-used 46 #:food-cap 66 #:food-army 21 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Zerg 'Terran (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define roach-pure-move (for/sum ([t (in-list roach-tags)]) (if (wire-pure-move-only? wcmds t) 1 0)))
     (define roach-local-atk (wire-count-local-attacks wcmds roach-tags enemy-tags 83.5 80.0 14.0))
     (define rav-biles (wire-count-tags-with-ability wcmds rav-tags AB-CORROSIVE-BILE))
     (values out
             (list
              (mk-check "ready-roaches-fire-at-in-range-marines-under-siege-hold"
                        (and (<= roach-pure-move 1) (>= roach-local-atk 4))
                        (format "Roaches (w-cd=0, Marines at 3.5t, Tanks at 8.5t): pure-MOVE=~a/6, local-ATK=~a/6"
                                roach-pure-move roach-local-atk))
              (mk-check "ravagers-cast-corrosive-bile-on-sieged-tanks"
                        (>= rav-biles 2)
                        (format "Ravagers casting Corrosive Bile (2338): ~a/3" rav-biles))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; W6-TAC-4: wall-and-block.rkt Natural Patrol Must NOT Steal Actively-Fighting Frontline Combat Units
(define scen-w6-tac-4
  (tactical-scenario
   "w6-tac-4-no-nat-patrol-stealing-frontline-combat-units"
   "wave6-repro" "Protoss" "Terran" "combat-cohesion"
   "Repro (wall-and-block.rkt:980-1007 + sc2-protobuf-ws.rkt:12085): On 1 base with minerals>=180, natural-pad patrol must NOT steal frontline Stalkers fighting enemy Bio 50t away into PATROL (17)."
   (lambda ()
     (define stalker-tags '(4030 4031 4032 4033))
     (define zealot-tags  '(4020 4021 4022 4023))
     (define all-army (append zealot-tags stalker-tags))
     (define allies
       (append
        ;; 1-base (#:with-natural? #f) + minerals=220 triggers wall-and-block.rkt:955-1007!
        (mk-home-base-units 'Protoss #:with-natural? #f)
        (for/list ([t (in-list zealot-tags)] [i (in-naturals)])
          (mk-unit t 'zealot 1 83.0 (+ 78.5 i) #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0))
        (for/list ([t (in-list stalker-tags)] [i (in-naturals)])
          (mk-unit t 'stalker 1 80.5 (+ 78.0 (* 1.2 i)) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))))
     (define enemies
       (append
        (list (mk-unit 8029 'command-center 4 160.0 160.0 #:hp 1500.0 #:hp-max 1500.0))
        (for/list ([i (in-range 10)])
          (mk-unit (+ 8030 i) 'marine 4 (+ 86.0 (quotient i 5)) (+ 77.5 (remainder i 5)) #:hp 45.0 #:hp-max 45.0))
        (for/list ([i (in-range 3)])
          (mk-unit (+ 8040 i) 'marauder 4 85.0 (+ 78.5 (* 1.5 i)) #:hp 125.0 #:hp-max 125.0))))
     (define s1 (mk-obs 2400 (append allies enemies)
                        #:minerals 220 #:vespene 100 #:food-used 34 #:food-cap 50 #:food-army 16 #:food-workers 16))
     (define out (last (run-pipeline-sequence 'Protoss 'Terran (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define stolen-patrol (wire-count-tags-with-ability wcmds all-army AB-PATROL))
     (define stalker-atks (wire-count-tags-with-ability wcmds stalker-tags AB-ATTACK))
     (values out
             (list
              (mk-check "frontline-army-not-stolen-for-nat-patrol-17"
                        (= stolen-patrol 0)
                        (format "Frontline army units stolen by PATROL (17) to empty natural: ~a/8 (expected 0)" stolen-patrol))
              (mk-check "all-frontline-stalkers-engage"
                        (>= stalker-atks 4)
                        (format "Frontline Stalkers issuing ATTACK (23): ~a/4" stalker-atks))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; =============================================================================
;; Round-7 Pro-Inspired Regression Shields (novel-63..68)
;; =============================================================================

;; 63. Protoss Oracle Stasis Ward Placement on Defensive Natural Choke
(define scen-novel-63
  (tactical-scenario
   "novel-63-protoss-oracle-stasis-ward-choke"
   "novel" "Protoss" "Zerg" "spellcasters"
   "Protoss Oracle with 100 energy at natural expansion places Stasis Ward (2505) defensively near natural choke."
   (lambda ()
     (define allies
       (append
        (mk-home-base-units 'Protoss #:with-natural? #t)
        (list (mk-unit 4050 'oracle 1 52.0 34.0 #:hp 100.0 #:hp-max 100.0 #:shield 60.0 #:shield-max 60.0 #:energy 100.0 #:flying? #t))))
     (define enemies
       (list (mk-unit 8050 'zergling 4 100.0 100.0 #:hp 35.0 #:hp-max 35.0)))
     (define s1 (mk-obs 15100 (append allies enemies)
                        #:minerals 100 #:vespene 100 #:food-used 28 #:food-cap 50 #:food-army 4 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Protoss 'Zerg (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define stasis? (wire-has-ability? wcmds '(4050) AB-STASIS-WARD))
     (values out
             (list
              (mk-check "oracle-places-stasis-ward"
                        stasis?
                        (format "Oracle 4050 emitted Stasis Ward (2505): ~a" stasis?))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; 64. Terran Ghost EMP Reveal Cloaked Dark Templars
(define scen-novel-64
  (tactical-scenario
   "novel-64-terran-ghost-emp-reveal-cloaked-dt"
   "novel" "Terran" "Protoss" "detection"
   "Terran Ghost facing cloaked Dark Templars (cloak=1) casts EMP (1628) onto DT cluster to reveal and strip shields."
   (lambda ()
     (define allies
       (append
        (mk-home-base-units 'Terran #:with-natural? #t)
        (list (mk-unit 4060 'ghost  1 80.0 80.0 #:hp 100.0 #:hp-max 100.0 #:energy 100.0)
              (mk-unit 4061 'marine 1 78.5 80.0 #:hp 45.0  #:hp-max 45.0))))
     (define enemies
       (list (mk-unit 8060 'dark-templar 4 86.0 80.0 #:hp 40.0 #:hp-max 40.0 #:shield 80.0 #:shield-max 80.0 #:cloak 1)
             (mk-unit 8061 'dark-templar 4 86.5 80.5 #:hp 40.0 #:hp-max 40.0 #:shield 80.0 #:shield-max 80.0 #:cloak 1)))
     (define s1 (mk-obs 15200 (append allies enemies)
                        #:minerals 100 #:vespene 50 #:food-used 30 #:food-cap 50 #:food-army 6 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Terran 'Protoss (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define emp? (wire-has-ability? wcmds '(4060) AB-EMP))
     (values out
             (list
              (mk-check "ghost-casts-emp-on-cloaked-dts"
                        emp?
                        (format "Ghost 4060 emitted EMP (1628) onto cloaked DTs: ~a" emp?))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; 65. Zerg Infestor Neural Parasite on Enemy Capital Ship (Battlecruiser)
(define scen-novel-65
  (tactical-scenario
   "novel-65-zerg-infestor-neural-parasite-capital"
   "novel" "Zerg" "Terran" "spellcasters"
   "Zerg Infestor with Neural Parasite (id=101) casts Neural Parasite (249) onto an approaching enemy Battlecruiser."
   (lambda ()
     (define allies
       (append
        (mk-home-base-units 'Zerg #:with-natural? #t)
        (list (mk-unit 4070 'infestor  1 80.0 80.0 #:hp 90.0 #:hp-max 90.0 #:energy 150.0)
              (mk-unit 4071 'hydralisk 1 78.0 80.0 #:hp 90.0 #:hp-max 90.0))))
     (define enemies
       (list (mk-unit 8070 'battlecruiser 4 86.0 80.0 #:hp 550.0 #:hp-max 550.0 #:flying? #t)))
     (define s1 (mk-obs 15300 (append allies enemies)
                        #:minerals 100 #:vespene 100 #:upgrades '(101)
                        #:food-used 32 #:food-cap 56 #:food-army 8 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Zerg 'Terran (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define neural? (wire-has-ability? wcmds '(4070) AB-NEURAL-PARASITE))
     (values out
             (list
              (mk-check "infestor-casts-neural-parasite-on-bc"
                        neural?
                        (format "Infestor 4070 emitted Neural Parasite (249) on BC: ~a" neural?))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; 66. Protoss Adept Psionic Transfer Shade
(define scen-novel-66
  (tactical-scenario
   "novel-66-protoss-adept-psionic-transfer-shade"
   "novel" "Protoss" "Zerg" "harass-micro"
   "Protoss Adepts engaging Zerglings emit Psionic Transfer (2544) shade for mobility/harass."
   (lambda ()
     (define adept-tags '(4080 4081))
     (define allies
       (append
        (mk-home-base-units 'Protoss #:with-natural? #t)
        (list (mk-unit 4080 'adept 1 80.0 80.0 #:hp 70.0 #:hp-max 70.0 #:shield 70.0 #:shield-max 70.0)
              (mk-unit 4081 'adept 1 80.0 82.0 #:hp 70.0 #:hp-max 70.0 #:shield 70.0 #:shield-max 70.0))))
     (define enemies
       (for/list ([i (in-range 4)])
         (mk-unit (+ 8080 i) 'zergling 4 85.0 (+ 79.0 i) #:hp 35.0 #:hp-max 35.0)))
     (define s1 (mk-obs 15400 (append allies enemies)
                        #:minerals 50 #:vespene 0 #:food-used 30 #:food-cap 50 #:food-army 6 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Protoss 'Zerg (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define shade? (wire-has-ability? wcmds adept-tags AB-ADEPT-SHADE))
     (values out
             (list
              (mk-check "adepts-emit-psionic-transfer-2544"
                        shade?
                        (format "Adepts emitted Psionic Transfer (2544): ~a" shade?))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; 67. Pro-Calibrated Zerg Opening: Zero 14-Drone Scout + Dual Overlord Scouting (W6-P0-4-rt shield)
(define scen-novel-67
  (tactical-scenario
   "novel-67-zerg-pro-opening-zero-drone-scout-overlords"
   "novel" "Zerg" "Terran" "scouting"
   "W6-P0-4-rt Pro-corpus shield: live 14-supply Zerg sends ZERO Drone scouts (preserving ~130M eco) and dispatches Overlord #1 to enemy natural + Overlord #2 to own ramp/natural watch."
   (lambda ()
     (define ov-tags '(4090 4091))
     (define allies
       (append
        (mk-home-base-units 'Zerg #:workers 14 #:with-natural? #f)
        (list (mk-unit 4090 'overlord 1 34.0 36.0 #:hp 200.0 #:hp-max 200.0 #:flying? #t)
              (mk-unit 4091 'overlord 1 36.0 34.0 #:hp 200.0 #:hp-max 200.0 #:flying? #t))))
     (define s1 (mk-obs 400 allies
                        #:minerals 100 #:vespene 0 #:food-used 14 #:food-cap 22 #:food-army 0 #:food-workers 14))
     (define out (last (run-pipeline-sequence 'Zerg 'Terran (list (hash 'obs s1)))))
     (define acts (step-outcome-bot-actions out))
     (define wcmds (step-outcome-wire-cmds out))
     (define drone-scouts (for/sum ([a (in-list acts)]) (if (and (pair? a) (eq? (car a) 'worker-scout)) 1 0)))
     (define ov-moves (wire-count-tags-with-ability wcmds ov-tags AB-MOVE))
     (values out
             (list
              (mk-check "zerg-never-pulls-early-drone-scout"
                        (= drone-scouts 0)
                        (format "Zerg 14-supply worker-scout actions: ~a (expected 0)" drone-scouts))
              (mk-check "zerg-dispatches-both-overlords"
                        (= ov-moves 2)
                        (format "Zerg Overlords moving to scout/watch posts: ~a/2" ov-moves))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; =============================================================================
;; Tier 8: Wave-7 Verified Real-SC2 Physics & Live-Pipeline Bug Repros (5)
;; =============================================================================

;; W7-TAC-5: W6-P0-4-rt Pro Scouting Reads Missing 'enemy-race Key Instead of l2-ctx-effective-enemy-race
(define scen-w7-tac-5
  (tactical-scenario
   "w7-tac-5-pro-scout-reads-effective-enemy-race-not-missing-key"
   "wave7-repro" "Protoss" "Zerg" "scouting"
   "Repro (bot-runtime.rkt:8303): live sc2-observation->runtime-obs-hash omits 'enemy-race (resolved to l2-ctx-effective-enemy-race at L6026), so Protoss 14-supply pre-Gateway (frame 350) falls through to 13.4s worker scout instead of waiting for Gateway #1 at 16-17 supply (frame >= 672)."
   (lambda ()
     (define s1
       (mk-obs 350
               (append (mk-home-base-units 'Protoss #:workers 14 #:with-natural? #f)
                       (list (mk-unit 4100 'pylon 1 38.0 35.0 #:hp 200.0 #:hp-max 200.0 #:shield 200.0 #:shield-max 200.0)))
               #:minerals 100 #:vespene 0 #:food-used 14 #:food-cap 23 #:food-army 0 #:food-workers 14))
     (define s2
       (mk-obs 900
               (append (mk-home-base-units 'Protoss #:workers 17 #:with-natural? #f)
                       (list (mk-unit 4100 'pylon   1 38.0 35.0 #:hp 200.0 #:hp-max 200.0 #:shield 200.0 #:shield-max 200.0)
                             (mk-unit 4101 'gateway 1 40.0 35.0 #:hp 500.0 #:hp-max 500.0 #:shield 500.0 #:shield-max 500.0 #:build-progress 0.3)))
               #:minerals 100 #:vespene 0 #:food-used 17 #:food-cap 23 #:food-army 0 #:food-workers 17))
     (define outs (run-pipeline-sequence 'Protoss 'Zerg (list (hash 'obs s1) (hash 'obs s2))))
     (define out1 (first outs))
     (define out2 (second outs))
     (define early-scouts (for/sum ([a (in-list (step-outcome-bot-actions out1))]) (if (and (pair? a) (eq? (car a) 'worker-scout)) 1 0)))
     (define post-gw-scouts (for/sum ([a (in-list (step-outcome-bot-actions out2))]) (if (and (pair? a) (eq? (car a) 'worker-scout)) 1 0)))
     (values out2
             (list
              (mk-check "no-premature-14-supply-probe-scout"
                        (= early-scouts 0)
                        (format "Protoss 14-supply pre-Gateway worker-scout actions: ~a (expected 0)" early-scouts))
              (mk-check "probe-scouts-after-gateway-at-17-supply"
                        (>= post-gw-scouts 1)
                        (format "Protoss 17-supply post-Gateway worker-scout actions: ~a (expected >=1)" post-gw-scouts))
              (mk-check "zero-wire-rejects" (= (+ (step-outcome-wire-rejects out1) (step-outcome-wire-rejects out2)) 0)
                        (format "wire_rejects=~a" (+ (step-outcome-wire-rejects out1) (step-outcome-wire-rejects out2)))))))))

;; W7-TAC-1: Protoss Shields Double-Counted in Combat-Eval & Arena-Minimax (z05 fa=28 repro!)
(define scen-w7-tac-1
  (tactical-scenario
   "w7-tac-1-protoss-shields-not-double-counted-in-combat-eval"
   "wave7-repro" "Zerg" "Protoss" "combat-evaluation"
   "Repro (z05 real-SC2 fa=28, bot-runtime.rkt:18885 + sc2-combat-eval.rkt:1474 + arena-minimax.rkt:776): sc2-protobuf-ws puts health+shield in 'hp AND raw health in 'hull-hp, yet combat-eval & arena-minimax add 'hp + 'shield a SECOND time (+33-97% fake Protoss EHP!), causing 4 Roaches + 8 Hydras (true 1.30x WIN) vs 4 Zealots + 3 Void Rays to falsely retreat 12/12 in pure MOVE(16)!"
   (lambda ()
     (define roach-tags (for/list ([i (in-range 4)]) (+ 4110 i)))
     (define hydra-tags (for/list ([i (in-range 8)]) (+ 4120 i)))
     (define all-zerg (append roach-tags hydra-tags))
     (define enemy-tags (append (for/list ([i (in-range 4)]) (+ 8110 i)) '(8120 8121 8122)))
     (define allies
       (append
        (mk-home-base-units 'Zerg #:with-natural? #t)
        (for/list ([t (in-list roach-tags)] [i (in-naturals)])
          (mk-unit t 'roach 1 76.5 (+ 78.5 i) #:hp 145.0 #:hp-max 145.0))
        (for/list ([t (in-list hydra-tags)] [i (in-naturals)])
          (mk-unit t 'hydralisk 1 75.0 (+ 76.5 (* 0.9 i)) #:hp 90.0 #:hp-max 90.0))))
     (define enemies
       (append
        (for/list ([i (in-range 4)])
          (mk-unit (+ 8110 i) 'zealot 4 84.0 (+ 78.5 i) #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0))
        (for/list ([i (in-range 3)])
          (mk-unit (+ 8120 i) 'void-ray 4 85.0 (+ 78.5 (* 1.5 i)) #:hp 150.0 #:hp-max 150.0 #:shield 100.0 #:shield-max 100.0 #:flying? #t))))
     (define s1 (mk-obs 15500 (append allies enemies)
                        #:minerals 50 #:vespene 0 #:food-used 48 #:food-cap 66 #:food-army 24 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Zerg 'Protoss (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define pure-moves (for/sum ([t (in-list all-zerg)]) (if (wire-pure-move-only? wcmds t) 1 0)))
     (define local-atks (wire-count-local-attacks wcmds all-zerg enemy-tags 84.5 80.0 16.0))
     (values out
             (list
              (mk-check "winning-zerg-army-engages-protoss-not-false-retreat"
                        (and (<= pure-moves 2) (>= local-atks 8))
                        (format "4 Roaches + 8 Hydras vs 4 Zealots + 3 Void Rays (true 1.30x WIN): pure-MOVE=~a/12, local-ATK=~a/12"
                                pure-moves local-atks))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; W7-TAC-2: arena-minimax DisengageRetreat Lacks Bio Ally-Cohesion (t01 M=55 repro!)
(define scen-w7-tac-2
  (tactical-scenario
   "w7-tac-2-arena-minimax-disengage-retreat-bio-cohesion"
   "wave7-repro" "Terran" "Protoss" "combat-cohesion"
   "Repro (t01 real-SC2 M=55, arena-minimax.rkt:3337-3353): Under DisengageRetreat, 4 frontline Marauders (range 6, dist 7.5<=8.5) attack forward while 8 ready Marines (range 5, dist 8.5>7.5) just 1t behind flee backwards in pure MOVE(16), splitting Bio in half!"
   (lambda ()
     (define marine-tags   (for/list ([i (in-range 8)]) (+ 4140 i)))
     (define marauder-tags (for/list ([i (in-range 4)]) (+ 4150 i)))
     (define enemy-tags (append (for/list ([i (in-range 7)]) (+ 8140 i)) (for/list ([i (in-range 6)]) (+ 8150 i))))
     (define allies
       (append
        (mk-home-base-units 'Terran #:with-natural? #t)
        (for/list ([t (in-list marine-tags)] [i (in-naturals)])
          (mk-unit t 'marine 1 75.5 (+ 76.5 (* 0.9 i)) #:hp 45.0 #:hp-max 45.0 #:weapon-cooldown 0.0))
        (for/list ([t (in-list marauder-tags)] [i (in-naturals)])
          (mk-unit t 'marauder 1 76.5 (+ 78.5 i) #:hp 125.0 #:hp-max 125.0 #:weapon-cooldown 0.0))))
     (define enemies
       (append
        (for/list ([i (in-range 7)])
          (mk-unit (+ 8140 i) 'zealot 4 84.0 (+ 77.0 (* 0.9 i)) #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0))
        (for/list ([i (in-range 6)])
          (mk-unit (+ 8150 i) 'stalker 4 85.5 (+ 77.5 i) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))))
     (define s1 (mk-obs 15600 (append allies enemies)
                        #:minerals 50 #:vespene 0 #:food-used 40 #:food-cap 66 #:food-army 16 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Terran 'Protoss (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define mar-pure-move (for/sum ([t (in-list marine-tags)]) (if (wire-pure-move-only? wcmds t) 1 0)))
     (define mar-atks (wire-count-local-attacks wcmds marine-tags enemy-tags 84.5 80.0 16.0))
     (values out
             (list
              (mk-check "marines-support-committing-marauders-not-split-flee"
                        (and (<= mar-pure-move 2) (>= mar-atks 6))
                        (format "Marines 1t behind committing Marauders (w-cd=0): pure-MOVE=~a/8, local-ATK=~a/8"
                                mar-pure-move mar-atks))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; W7-TAC-3: arena-minimax Enemy DisengageRetreat Flattens Payoff Matrix to Tie (p03 repro!)
(define scen-w7-tac-3
  (tactical-scenario
   "w7-tac-3-arena-minimax-enemy-retreat-tie-breaks-by-combat-payoff"
   "wave7-repro" "Protoss" "Zerg" "stutter-step"
   "Repro (p03 real-SC2 0.88x->0.29x, arena-minimax.rkt:452-503): 7 Stalkers vs 14 Zerglings at dist=9t — StutterKiteBack beats CommitFocusFire by +100+ vs every enemy combat action, yet pred-enemy=DisengageRetreat flattens all rows to baseline tie so minimax picks CommitFocusFire instead of StutterKiteBack!"
   (lambda ()
     (define stalker-tags (for/list ([i (in-range 7)]) (+ 4160 i)))
     (define allies
       (append
        (mk-home-base-units 'Protoss #:with-natural? #t)
        (for/list ([t (in-list stalker-tags)] [i (in-naturals)])
          (mk-unit t 'stalker 1 75.5 (+ 77.5 i) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))))
     (define enemies
       (for/list ([i (in-range 14)])
         (mk-unit (+ 8160 i) 'zergling 4 84.5 (+ 76.0 (* 0.6 i)) #:hp 35.0 #:hp-max 35.0)))
     (define s1 (mk-obs 15700 (append allies enemies)
                        #:minerals 50 #:vespene 0 #:food-used 38 #:food-cap 60 #:food-army 14 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Protoss 'Zerg (list (hash 'obs s1)))))
     (define tdecs (hash-ref (step-outcome-telemetry out) 'tactical-decisions '()))
     (define act (and (pair? tdecs) (hash-ref (first tdecs) 'committed-action #f)))
     (values out
             (list
              (mk-check "stalkers-vs-zerglings-selects-stutter-kite-back"
                        (eq? act 'StutterKiteBack)
                        (format "7 Stalkers vs 14 Zerglings arena-minimax committed-action=~a (expected StutterKiteBack)" act))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; W7-TAC-4: z02 Commit-Through-Splash Roaches Walk Pure-MOVE Past Marines at 5.5t (z02 A=2 M=16 repro!)
(define scen-w7-tac-4
  (tactical-scenario
   "w7-tac-4-z02-commit-splash-roaches-attack-nearby-marines"
   "wave7-repro" "Zerg" "Terran" "splash-evasion"
   "Repro (z02 real-SC2 A=2 vs M=16, bot-runtime.rkt:20434, 20469-20481): Under commit-run-through-splash-concave, 6 weapon-ready Roaches at 5.5t from 8 Marines (and 7.5t from 2 Sieged Tanks) are just 0.25t past gr+1.25=5.25t -> 6/6 emit zero-fire pure MOVE(16) instead of ATTACK(23)!"
   (lambda ()
     (define roach-tags (for/list ([i (in-range 6)]) (+ 4180 i)))
     (define rav-tags   '(4190 4191 4192))
     (define enemy-tags (append (for/list ([i (in-range 8)]) (+ 8180 i)) '(8190 8191)))
     (define allies
       (append
        (mk-home-base-units 'Zerg #:with-natural? #t)
        (for/list ([t (in-list roach-tags)] [i (in-naturals)])
          (mk-unit t 'roach 1 78.5 (+ 77.5 i) #:hp 145.0 #:hp-max 145.0 #:weapon-cooldown 0.0))
        (for/list ([t (in-list rav-tags)] [i (in-naturals)])
          (mk-unit t 'ravager 1 77.5 (+ 78.5 (* 1.5 i)) #:hp 120.0 #:hp-max 120.0 #:weapon-cooldown 0.0))))
     (define enemies
       (append
        (for/list ([i (in-range 8)])
          (mk-unit (+ 8180 i) 'marine 4 84.0 (+ 77.0 (* 0.85 i)) #:hp 45.0 #:hp-max 45.0))
        (list (mk-unit 8190 'siege-tank-sieged 4 86.0 79.0 #:hp 175.0 #:hp-max 175.0)
              (mk-unit 8191 'siege-tank-sieged 4 86.0 81.0 #:hp 175.0 #:hp-max 175.0))))
     (define s1 (mk-obs 15800 (append allies enemies)
                        #:minerals 50 #:vespene 0 #:food-used 45 #:food-cap 66 #:food-army 21 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Zerg 'Terran (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define roach-pure-move (for/sum ([t (in-list roach-tags)]) (if (wire-pure-move-only? wcmds t) 1 0)))
     (define roach-atks (wire-count-local-attacks wcmds roach-tags enemy-tags 84.5 80.0 14.0))
     (define rav-biles (wire-count-tags-with-ability wcmds rav-tags AB-CORROSIVE-BILE))
     (values out
             (list
              (mk-check "committed-roaches-attack-marines-5.5t-not-pure-move"
                        (and (<= roach-pure-move 1) (>= roach-atks 4))
                        (format "Committed Roaches 5.5t from Marines + 7.5t from Sieged Tanks: pure-MOVE=~a/6, local-ATK=~a/6"
                                roach-pure-move roach-atks))
              (mk-check "ravagers-still-bile-sieged-tanks"
                        (>= rav-biles 2)
                        (format "Ravagers casting Corrosive Bile (2338): ~a/3" rav-biles))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; =============================================================================
;; Round-8 Pro-Inspired Regression Shields (novel-68..74)
;; =============================================================================

;; 68. Zerg Roach Burrow Regen (1386/3661) & Healed Unburrow (1388/3662)
(define scen-novel-68
  (tactical-scenario
   "novel-68-zerg-roach-burrow-regen-and-unburrow"
   "novel" "Zerg" "Terran" "burrow-micro"
   "With Burrow (id=64) researched: critically wounded Roach (35/145 HP) burrows down to heal, while healed burrowed Roach (138/145 HP) unburrows to rejoin the fight."
   (lambda ()
     (define s-down
       (mk-obs 16000
               (append (mk-home-base-units 'Zerg #:with-natural? #t)
                       (list (mk-unit 4200 'roach 1 80.0 80.0 #:hp 35.0 #:hp-max 145.0)
                             (mk-unit 4201 'roach 1 80.0 82.0 #:hp 145.0 #:hp-max 145.0)
                             (mk-unit 8200 'marine 4 84.0 80.0 #:hp 45.0 #:hp-max 45.0)
                             (mk-unit 8201 'marine 4 84.0 81.0 #:hp 45.0 #:hp-max 45.0)
                             (mk-unit 8202 'marine 4 84.0 82.0 #:hp 45.0 #:hp-max 45.0)))
               #:upgrades '(64) #:food-used 34 #:food-cap 60 #:food-army 10 #:food-workers 24))
     (define out-down (last (run-pipeline-sequence 'Zerg 'Terran (list (hash 'obs s-down)))))
     (define burrowed? (wire-any-ability? (step-outcome-wire-cmds out-down) '(4200) (list AB-BURROW-ROACH-DOWN AB-BURROW-DOWN)))
     (define s-up
       (mk-obs 16100
               (append (mk-home-base-units 'Zerg #:with-natural? #t)
                       (list (mk-unit 4205 'roach-burrowed 1 80.0 80.0 #:hp 138.0 #:hp-max 145.0 #:burrowed? #t)
                             (mk-unit 4206 'roach 1 82.0 80.0 #:hp 145.0 #:hp-max 145.0)
                             (mk-unit 8205 'marine 4 90.0 80.0 #:hp 45.0 #:hp-max 45.0)))
               #:upgrades '(64) #:food-used 34 #:food-cap 60 #:food-army 10 #:food-workers 24))
     (define out-up (last (run-pipeline-sequence 'Zerg 'Terran (list (hash 'obs s-up)))))
     (define unburrowed? (wire-any-ability? (step-outcome-wire-cmds out-up) '(4205) (list AB-BURROW-ROACH-UP AB-BURROW-UP)))
     (values out-up
             (list
              (mk-check "wounded-roach-burrows-for-regen"
                        burrowed?
                        (format "Wounded 35HP Roach 4200 emitted Burrow (1386/3661): ~a" burrowed?))
              (mk-check "healed-roach-unburrows-to-rejoin"
                        unburrowed?
                        (format "Healed 138HP burrowed Roach 4205 emitted Unburrow (1388/3662): ~a" unburrowed?))
              (mk-check "zero-wire-rejects" (= (+ (step-outcome-wire-rejects out-down) (step-outcome-wire-rejects out-up)) 0)
                        (format "wire_rejects=~a" (+ (step-outcome-wire-rejects out-down) (step-outcome-wire-rejects out-up)))))))))

;; 69. Terran Thor High-Impact Payload vs Enemy Brood Lords
(define scen-novel-69
  (tactical-scenario
   "novel-69-terran-thor-high-impact-vs-brood-lord"
   "novel" "Terran" "Zerg" "unit-modes"
   "Terran Thors in Explosive mode facing Massive Brood Lords morph to High-Impact Payload (2362) for long-range single-target anti-air."
   (lambda ()
     (define thor-tags '(4210 4211))
     (define allies
       (append (mk-home-base-units 'Terran #:with-natural? #t)
               (list (mk-unit 4210 'thor 1 80.0 80.0 #:hp 400.0 #:hp-max 400.0)
                     (mk-unit 4211 'thor 1 80.0 82.0 #:hp 400.0 #:hp-max 400.0))))
     (define enemies
       (list (mk-unit 8210 'brood-lord 4 88.0 80.0 #:hp 225.0 #:hp-max 225.0 #:flying? #t)
             (mk-unit 8211 'brood-lord 4 88.0 82.0 #:hp 225.0 #:hp-max 225.0 #:flying? #t)))
     (define s1 (mk-obs 16200 (append allies enemies)
                        #:food-used 36 #:food-cap 60 #:food-army 12 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s1)))))
     (define hi-cnt (wire-count-tags-with-ability (step-outcome-wire-cmds out) thor-tags AB-THOR-HIGH-IMPACT))
     (values out
             (list
              (mk-check "thors-switch-to-high-impact-vs-brood-lords"
                        (= hi-cnt 2)
                        (format "Thors switching to High-Impact Payload (2362): ~a/2" hi-cnt))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; 70. Terran Thor Explosive Payload vs Clumped Mutalisk Flock
(define scen-novel-70
  (tactical-scenario
   "novel-70-terran-thor-explosive-vs-mutalisk-flock"
   "novel" "Terran" "Zerg" "unit-modes"
   "Terran Thor in High-Impact (thor-ap) mode facing clumped Light Mutalisks switches back to Explosive splash Payload (2364)."
   (lambda ()
     (define allies
       (append (mk-home-base-units 'Terran #:with-natural? #t)
               (list (mk-unit 4220 'thor-ap 1 80.0 80.0 #:hp 400.0 #:hp-max 400.0))))
     (define enemies
       (list (mk-unit 8220 'mutalisk 4 87.0 80.0 #:hp 120.0 #:hp-max 120.0 #:flying? #t)
             (mk-unit 8221 'mutalisk 4 87.5 80.5 #:hp 120.0 #:hp-max 120.0 #:flying? #t)
             (mk-unit 8222 'mutalisk 4 87.5 79.5 #:hp 120.0 #:hp-max 120.0 #:flying? #t)
             (mk-unit 8223 'mutalisk 4 88.0 80.0 #:hp 120.0 #:hp-max 120.0 #:flying? #t)
             (mk-unit 8224 'mutalisk 4 88.0 81.0 #:hp 120.0 #:hp-max 120.0 #:flying? #t)))
     (define s1 (mk-obs 16300 (append allies enemies)
                        #:food-used 32 #:food-cap 56 #:food-army 6 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s1)))))
     (define exp? (wire-has-ability? (step-outcome-wire-cmds out) '(4220) AB-THOR-EXPLOSIVE))
     (values out
             (list
              (mk-check "thor-ap-switches-to-explosive-vs-mutalisks"
                        exp?
                        (format "Thor-AP 4220 switched to Explosive Payload (2364): ~a" exp?))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; 71. Terran Liberator AG Siege vs Ground + AA Unsiege When Zone Empty
(define scen-novel-71
  (tactical-scenario
   "novel-71-terran-liberator-ag-siege-and-aa-unsiege"
   "novel" "Terran" "Zerg" "unit-modes"
   "Terran Liberator sieges Defender Mode (2558) onto nearby Roaches, and unsieges to Fighter Mode (2560) when enemies move 55t away."
   (lambda ()
     (define s-ag
       (mk-obs 16400
               (append (mk-home-base-units 'Terran #:with-natural? #t)
                       (list (mk-unit 4230 'liberator 1 80.0 80.0 #:hp 180.0 #:hp-max 180.0 #:flying? #t)
                             (mk-unit 4231 'marine    1 78.0 80.0 #:hp 45.0  #:hp-max 45.0)
                             (mk-unit 8230 'roach 4 85.0 80.0 #:hp 145.0 #:hp-max 145.0)
                             (mk-unit 8231 'roach 4 85.5 81.0 #:hp 145.0 #:hp-max 145.0)
                             (mk-unit 8232 'roach 4 85.5 79.0 #:hp 145.0 #:hp-max 145.0)))
               #:food-used 32 #:food-cap 56 #:food-army 8 #:food-workers 24))
     (define out-ag (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s-ag)))))
     (define sieged? (wire-has-ability? (step-outcome-wire-cmds out-ag) '(4230) AB-LIBERATOR-AG))
     (define s-aa
       (mk-obs 16500
               (append (mk-home-base-units 'Terran #:with-natural? #t)
                       (list (mk-unit 4235 'liberator-ag 1 80.0 80.0 #:hp 180.0 #:hp-max 180.0 #:flying? #t)
                             (mk-unit 4236 'marine       1 78.0 80.0 #:hp 45.0  #:hp-max 45.0)
                             (mk-unit 8235 'roach 4 120.0 120.0 #:hp 145.0 #:hp-max 145.0)))
               #:food-used 32 #:food-cap 56 #:food-army 8 #:food-workers 24))
     (define out-aa (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s-aa)))))
     (define unsieged? (wire-has-ability? (step-outcome-wire-cmds out-aa) '(4235) AB-LIBERATOR-AA))
     (values out-aa
             (list
              (mk-check "liberator-sieges-defender-mode-onto-roaches"
                        sieged?
                        (format "Liberator 4230 emitted Defender Mode (2558): ~a" sieged?))
              (mk-check "liberator-unsieges-when-zone-empty"
                        unsieged?
                        (format "Liberator-AG 4235 emitted Fighter Mode (2560): ~a" unsieged?))
              (mk-check "zero-wire-rejects" (= (+ (step-outcome-wire-rejects out-ag) (step-outcome-wire-rejects out-aa)) 0)
                        (format "wire_rejects=~a" (+ (step-outcome-wire-rejects out-ag) (step-outcome-wire-rejects out-aa)))))))))

;; 72. Terran Banshee Cloak Upgrade Gate (392 only WITH banshee-cloak id=20)
(define scen-novel-72
  (tactical-scenario
   "novel-72-terran-banshee-cloak-upgrade-gate"
   "novel" "Terran" "Zerg" "spellcasters"
   "Terran Banshee under anti-air threat (Queen, no detector) never emits invalid Cloak (392) without Banshee Cloak (id=20), and DOES emit Cloak (392) when id=20 is researched."
   (lambda ()
     (define base-units
       (append (mk-home-base-units 'Terran #:with-natural? #t)
               (list (mk-unit 4240 'banshee 1 80.0 80.0 #:hp 100.0 #:hp-max 140.0 #:energy 100.0 #:flying? #t)
                     (mk-unit 8240 'queen   4 85.0 80.0 #:hp 175.0 #:hp-max 175.0))))
     (define out-no (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs (mk-obs 16600 base-units #:upgrades '()))))))
     (define out-yes (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs (mk-obs 16600 base-units #:upgrades '(20)))))))
     (define cloak-no? (wire-has-ability? (step-outcome-wire-cmds out-no) '(4240) AB-CLOAK-BANSHEE))
     (define cloak-yes? (wire-has-ability? (step-outcome-wire-cmds out-yes) '(4240) AB-CLOAK-BANSHEE))
     (values out-yes
             (list
              (mk-check "banshee-no-cloak-without-upgrade"
                        (not cloak-no?)
                        (format "Un-upgraded Banshee emitted Cloak (392): ~a (expected #f)" cloak-no?))
              (mk-check "banshee-cloaks-with-upgrade-20"
                        cloak-yes?
                        (format "Upgraded Banshee (id=20) emitted Cloak (392): ~a (expected #t)" cloak-yes?))
              (mk-check "zero-wire-rejects" (= (+ (step-outcome-wire-rejects out-no) (step-outcome-wire-rejects out-yes)) 0)
                        (format "wire_rejects=~a" (+ (step-outcome-wire-rejects out-no) (step-outcome-wire-rejects out-yes)))))))))

;; 73. Zerg Lurker Burrow in Combat Range & Unburrow When Empty
(define scen-novel-73
  (tactical-scenario
   "novel-73-zerg-lurker-burrow-and-unburrow-discipline"
   "novel" "Zerg" "Terran" "unit-modes"
   "Zerg Lurkers burrow (2108) in range of approaching enemy Bio, and burrowed Lurkers unburrow (2110/3662) when enemies are 35t away."
   (lambda ()
     (define s-b
       (mk-obs 16700
               (append (mk-home-base-units 'Zerg #:with-natural? #t)
                       (list (mk-unit 4250 'lurker-mp 1 80.0 80.0 #:hp 200.0 #:hp-max 200.0)
                             (mk-unit 4251 'lurker-mp 1 80.0 82.0 #:hp 200.0 #:hp-max 200.0)
                             (mk-unit 8250 'marine   4 86.0 80.0 #:hp 45.0  #:hp-max 45.0)
                             (mk-unit 8251 'marine   4 86.5 81.0 #:hp 45.0  #:hp-max 45.0)
                             (mk-unit 8252 'marine   4 86.5 79.0 #:hp 45.0  #:hp-max 45.0)
                             (mk-unit 8253 'marauder 4 86.0 82.0 #:hp 125.0 #:hp-max 125.0)))
               #:food-used 36 #:food-cap 60 #:food-army 12 #:food-workers 24))
     (define out-b (last (run-pipeline-sequence 'Zerg 'Terran (list (hash 'obs s-b)))))
     (define burr-cnt (wire-count-tags-with-ability (step-outcome-wire-cmds out-b) '(4250 4251) AB-BURROW-LURKER))
     (define s-u
       (mk-obs 16800
               (append (mk-home-base-units 'Zerg #:with-natural? #t)
                       (list (mk-unit 4255 'lurker-mp-burrowed 1 80.0 80.0 #:hp 200.0 #:hp-max 200.0 #:burrowed? #t)
                             (mk-unit 4256 'roach 1 82.0 80.0 #:hp 145.0 #:hp-max 145.0)
                             (mk-unit 8255 'marine 4 115.0 115.0 #:hp 45.0 #:hp-max 45.0)))
               #:food-used 34 #:food-cap 60 #:food-army 10 #:food-workers 24))
     (define out-u (last (run-pipeline-sequence 'Zerg 'Terran (list (hash 'obs s-u)))))
     (define unburr? (wire-any-ability? (step-outcome-wire-cmds out-u) '(4255) (list AB-UNBURROW-LURKER AB-BURROW-UP)))
     (values out-u
             (list
              (mk-check "lurkers-burrow-in-range-of-bio"
                        (= burr-cnt 2)
                        (format "Lurkers emitting Burrow (2108): ~a/2" burr-cnt))
              (mk-check "lurker-unburrows-when-enemies-far"
                        unburr?
                        (format "Burrowed Lurker 4255 emitted Unburrow (2110/3662): ~a" unburr?))
              (mk-check "zero-wire-rejects" (= (+ (step-outcome-wire-rejects out-b) (step-outcome-wire-rejects out-u)) 0)
                        (format "wire_rejects=~a" (+ (step-outcome-wire-rejects out-b) (step-outcome-wire-rejects out-u)))))))))

;; 74. Terran Widow Mine Burrow vs Approaching Lings & Unburrow When Empty
(define scen-novel-74
  (tactical-scenario
   "novel-74-terran-widow-mine-burrow-and-unburrow-discipline"
   "novel" "Terran" "Zerg" "unit-modes"
   "Terran Widow Mine burrows (2095/3661) near approaching Zerglings, and unburrows (2097/3662) to advance when enemies are 35t away."
   (lambda ()
     (define s-b
       (mk-obs 16900
               (append (mk-home-base-units 'Terran #:with-natural? #t)
                       (list (mk-unit 4260 'widow-mine 1 80.0 80.0 #:hp 90.0 #:hp-max 90.0)
                             (mk-unit 4261 'marine     1 78.0 80.0 #:hp 45.0 #:hp-max 45.0)
                             (mk-unit 8260 'zergling 4 85.0 80.0 #:hp 35.0 #:hp-max 35.0)
                             (mk-unit 8261 'zergling 4 85.5 80.5 #:hp 35.0 #:hp-max 35.0)
                             (mk-unit 8262 'zergling 4 85.5 79.5 #:hp 35.0 #:hp-max 35.0)))
               #:food-used 30 #:food-cap 56 #:food-army 6 #:food-workers 24))
     (define out-b (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s-b)))))
     (define burr? (wire-any-ability? (step-outcome-wire-cmds out-b) '(4260) (list AB-BURROW-WIDOW-MINE AB-BURROW-DOWN)))
     (define s-u
       (mk-obs 17000
               (append (mk-home-base-units 'Terran #:with-natural? #t)
                       (list (mk-unit 4265 'widow-mine-burrowed 1 80.0 80.0 #:hp 90.0 #:hp-max 90.0 #:burrowed? #t)
                             (mk-unit 4266 'marine 1 78.0 80.0 #:hp 45.0 #:hp-max 45.0)
                             (mk-unit 8265 'zergling 4 115.0 115.0 #:hp 35.0 #:hp-max 35.0)))
               #:food-used 30 #:food-cap 56 #:food-army 6 #:food-workers 24))
     (define out-u (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s-u)))))
     (define unburr? (wire-any-ability? (step-outcome-wire-cmds out-u) '(4265) (list AB-UNBURROW-WIDOW-MINE AB-BURROW-UP)))
     (values out-u
             (list
              (mk-check "widow-mine-burrows-vs-zerglings"
                        burr?
                        (format "Widow Mine 4260 emitted Burrow (2095/3661): ~a" burr?))
              (mk-check "widow-mine-unburrows-when-enemies-far"
                        unburr?
                        (format "Widow Mine 4265 emitted Unburrow (2097/3662): ~a" unburr?))
              (mk-check "zero-wire-rejects" (= (+ (step-outcome-wire-rejects out-b) (step-outcome-wire-rejects out-u)) 0)
                        (format "wire_rejects=~a" (+ (step-outcome-wire-rejects out-b) (step-outcome-wire-rejects out-u)))))))))

;; =============================================================================
;; Tier 9: Wave-8 Verified Real-SC2 Physics & Live-Pipeline Bug Repros (4)
;; =============================================================================

;; W8-TAC-1: dedicated-harass-units Steals Units in Active Combat to Attack-Move (160,160) (p06 + Reaper + Banshee repro!)
(define scen-w8-tac-1
  (tactical-scenario
   "w8-tac-1-dedicated-harass-never-steals-units-in-active-combat"
   "wave8-repro" "Protoss" "Zerg" "harass-micro"
   "Repro (p06 3.50x W -> 0.75x T, bot-runtime.rkt:23341-23389): dedicated-harass-units (adept/reaper/banshee/oracle/hellion/phoenix/mutalisk) ignores active combat & tbrain-committed-tags, sending 2 Adepts fighting 12 Zerglings 8.5t away on blind ATTACK-MOVE to enemy main (160,160)!"
   (lambda ()
     (define adept-tags '(4270 4271))
     (define allies
       (append (mk-home-base-units 'Protoss #:with-natural? #t)
               (list (mk-unit 4268 'zealot 1 76.5 79.0 #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0)
                     (mk-unit 4269 'zealot 1 76.5 80.0 #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0)
                     (mk-unit 4270 'adept  1 75.5 79.0 #:hp 70.0  #:hp-max 70.0  #:shield 70.0 #:shield-max 70.0)
                     (mk-unit 4271 'adept  1 75.5 80.0 #:hp 70.0  #:hp-max 70.0  #:shield 70.0 #:shield-max 70.0))))
     (define enemies
       (append (list (mk-unit 8269 'hatchery 4 160.0 160.0 #:hp 1500.0 #:hp-max 1500.0))
               (for/list ([i (in-range 12)])
                 (mk-unit (+ 8270 i) 'zergling 4 84.0 (+ 76.0 (* 0.6 i)) #:hp 35.0 #:hp-max 35.0))))
     (define s1 (mk-obs 17100 (append allies enemies)
                        #:minerals 50 #:vespene 0 #:food-used 32 #:food-cap 56 #:food-army 8 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Protoss 'Zerg (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define stolen-to-enemy-main?
       (for/or ([c (in-list wcmds)])
         (and (sc2-raw-unit-command? c)
              (for/or ([t (in-list adept-tags)]) (not (not (memv t (sc2-raw-unit-command-unit-tags c)))))
              (let ([p (sc2-raw-unit-command-target-pos c)])
                (and p (<= (dist2d-xy (sc2-point2d-x p) (sc2-point2d-y p) 160.0 160.0) 15.0))))))
     (values out
             (list
              (mk-check "adepts-in-combat-not-stolen-by-dedicated-harass-to-enemy-main"
                        (not stolen-to-enemy-main?)
                        (format "Adepts facing 12 Zerglings 8.5t away sent to enemy main (160,160): ~a (expected #f)" stolen-to-enemy-main?))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; W8-TAC-2: Infestor Spams Invalid Neural Parasite (249) Without Upgrade (id=101)
(define scen-w8-tac-2
  (tactical-scenario
   "w8-tac-2-zerg-infestor-no-neural-parasite-without-upgrade"
   "wave8-repro" "Zerg" "Terran" "spellcasters"
   "Repro (pro-spellcaster-micro.rkt:2385-2442): Infestor WITHOUT Neural Parasite upgrade (id=101) researched must NOT emit invalid Neural Parasite (249) — wasting its frame and starving Microbial Shroud (2545)!"
   (lambda ()
     (define allies
       (append (mk-home-base-units 'Zerg #:with-natural? #t)
               (list (mk-unit 4280 'infestor  1 80.0 80.0 #:hp 90.0 #:hp-max 90.0 #:energy 150.0)
                     (mk-unit 4281 'hydralisk 1 78.0 80.0 #:hp 90.0 #:hp-max 90.0))))
     (define enemies
       (list (mk-unit 8280 'battlecruiser 4 86.0 80.0 #:hp 550.0 #:hp-max 550.0 #:flying? #t)))
     (define s1 (mk-obs 17200 (append allies enemies)
                        #:minerals 100 #:vespene 100 #:upgrades '()
                        #:food-used 32 #:food-cap 56 #:food-army 8 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Zerg 'Terran (list (hash 'obs s1)))))
     (define neural? (wire-has-ability? (step-outcome-wire-cmds out) '(4280) AB-NEURAL-PARASITE))
     (values out
             (list
              (mk-check "unupgraded-infestor-never-emits-neural-249"
                        (not neural?)
                        (format "Infestor WITHOUT neural-parasite(101) emitted invalid Neural Parasite (249): ~a (expected #f)" neural?))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; W8-TAC-3: High Templar With 120 Energy Suicide-Charged Into Hydras via ATTACK-UNIT (23) (p05 repro!)
(define scen-w8-tac-3
  (tactical-scenario
   "w8-tac-3-protoss-high-templar-never-suicide-attack-unit-into-army"
   "wave8-repro" "Protoss" "Zerg" "support-preservation"
   "Repro (p05, arena-minimax.rkt:3450-3539): Fragile 120-energy High Templars (40HP/40SH, 4 DPS) behind Archons + Stalkers must NEVER be ordered ATTACK-UNIT (23) directly into 8 enemy Hydralisks!"
   (lambda ()
     (define ht-tags '(4290 4291))
     (define allies
       (append (mk-home-base-units 'Protoss #:with-natural? #t)
               (list (mk-unit 4282 'archon 1 76.5 79.0 #:hp 10.0 #:hp-max 10.0 #:shield 350.0 #:shield-max 350.0)
                     (mk-unit 4283 'archon 1 76.5 80.5 #:hp 10.0 #:hp-max 10.0 #:shield 350.0 #:shield-max 350.0))
               (for/list ([i (in-range 4)])
                 (mk-unit (+ 4284 i) 'stalker 1 75.0 (+ 78.0 i) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))
               (list (mk-unit 4290 'high-templar 1 74.0 79.0 #:hp 40.0 #:hp-max 40.0 #:shield 40.0 #:shield-max 40.0 #:energy 120.0)
                     (mk-unit 4291 'high-templar 1 74.0 80.5 #:hp 40.0 #:hp-max 40.0 #:shield 40.0 #:shield-max 40.0 #:energy 120.0))))
     (define enemies
       (append (for/list ([i (in-range 8)])
                 (mk-unit (+ 8290 i) 'hydralisk 4 84.0 (+ 76.5 (* 0.9 i)) #:hp 90.0 #:hp-max 90.0))
               (list (mk-unit 8298 'infestor 4 85.5 79.0 #:hp 90.0 #:hp-max 90.0 #:energy 120.0)
                     (mk-unit 8299 'infestor 4 85.5 80.5 #:hp 90.0 #:hp-max 90.0 #:energy 120.0))))
     (define s1 (mk-obs 17300 (append allies enemies)
                        #:minerals 50 #:vespene 0 #:upgrades '(52)
                        #:food-used 44 #:food-cap 66 #:food-army 20 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Protoss 'Zerg (list (hash 'obs s1)))))
     (define ht-atks (wire-count-tags-with-ability (step-outcome-wire-cmds out) ht-tags AB-ATTACK))
     (values out
             (list
              (mk-check "high-templars-never-suicide-attack-unit-into-hydras"
                        (= ht-atks 0)
                        (format "120-energy High Templars ordered ATTACK (23) into 8 Hydralisks: ~a/2 (expected 0)" ht-atks))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; W8-TAC-4: Sentry Mid-Fight Hallucination Phoenix (154) Burns 75 Energy Before Guardian Shield (76)!
(define scen-w8-tac-4
  (tactical-scenario
   "w8-tac-4-protoss-sentry-no-mid-fight-hallucination-stealing-guardian-shield"
   "wave8-repro" "Protoss" "Terran" "spellcasters"
   "Repro (bot-runtime.rkt:9439-9448): A 100-energy Sentry 6t from Terran Bio emits HALLUCINATION_PHOENIX (154, -75 energy) BEFORE GUARDIAN_SHIELD (76, -75 energy), starving Guardian Shield mid-fight!"
   (lambda ()
     (define allies
       (append (mk-home-base-units 'Protoss #:with-natural? #t)
               (list (mk-unit 4300 'sentry  1 80.0 80.0 #:hp 40.0  #:hp-max 40.0  #:shield 40.0 #:shield-max 40.0 #:energy 100.0)
                     (mk-unit 4301 'stalker 1 81.0 80.0 #:hp 80.0  #:hp-max 80.0  #:shield 80.0 #:shield-max 80.0)
                     (mk-unit 4302 'stalker 1 81.0 82.0 #:hp 80.0  #:hp-max 80.0  #:shield 80.0 #:shield-max 80.0)
                     (mk-unit 4303 'zealot  1 82.0 81.0 #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0))))
     (define enemies
       (list (mk-unit 8300 'marine   4 86.0 80.0 #:hp 45.0  #:hp-max 45.0)
             (mk-unit 8301 'marine   4 86.0 81.0 #:hp 45.0  #:hp-max 45.0)
             (mk-unit 8302 'marine   4 86.0 82.0 #:hp 45.0  #:hp-max 45.0)
             (mk-unit 8303 'marauder 4 86.0 79.0 #:hp 125.0 #:hp-max 125.0)))
     (define s1 (mk-obs 17400 (append allies enemies)
                        #:minerals 50 #:vespene 0 #:food-used 34 #:food-cap 56 #:food-army 10 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Protoss 'Terran (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define hallu? (wire-has-ability? wcmds '(4300) AB-HALLUCINATION-PHOENIX))
     (define gshield? (wire-has-ability? wcmds '(4300) AB-GUARDIAN-SHIELD))
     (values out
             (list
              (mk-check "sentry-never-wastes-75-energy-on-hallucination-mid-fight"
                        (not hallu?)
                        (format "100-energy Sentry 6t from Bio emitted Hallucination Phoenix (154): ~a (expected #f)" hallu?))
              (mk-check "sentry-casts-guardian-shield-76"
                        gshield?
                        (format "Sentry 4300 emitted Guardian Shield (76): ~a" gshield?))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; 124. W8-TAC-5 (W8-P0-3-rt / #35 T v 12PoolBot): Early Rush Must Suppress Cross-Map Worker-Scout!
;;      When 12 Zerglings attack our natural Bunker at 14-16t from main CC (frame=2600, > SC2-CHEESE-RUSH-RADIUS=9.0
;;      so `under-early-cheese?` / `early-survival-crisis?` are BOTH `#f`), `scout-eligible-window?` at
;;      `lib/bot-runtime.rkt:8297-8334` still dispatches an SCV on `MOVE (16)` to enemy natural `(143, 143)`
;;      right through the 12-Pool rush instead of keeping all SCVs home for Bunker repair & defense!
(define scen-w8-tac-5
  (tactical-scenario
   "w8-tac-5-terran-early-rush-suppresses-worker-scout-and-loads-bunker"
   "wave8-repro" "Terran" "Zerg" "early-rush-defense"
   "Wave-8 Repro (W8-TAC-5 / W8-P0-3-rt #35): 12 Zerglings rushing natural Bunker (14-16t from main CC, frame=2600) must suppress cross-map SCV worker-scout while loading Bunker / defending"
   (lambda ()
     (define scv-tags (for/list ([i (in-range 16)]) (+ 50 i)))
     (define marine-tags '(4401 4402 4403))
     (define allies
       (append
        (list (mk-unit 1 'command-center 1 32.0 32.0 #:hp 1500.0 #:hp-max 1500.0)
              (mk-unit 2 'supply-depot   1 36.0 30.0 #:hp 400.0  #:hp-max 400.0)
              (mk-unit 3 'barracks       1 38.0 34.0 #:hp 1000.0 #:hp-max 1000.0)
              (mk-unit 4 'bunker         1 44.0 34.0 #:hp 320.0  #:hp-max 400.0)
              (mk-unit 9001 'mineral-field 3 26.0 32.0 #:hp 1000.0 #:hp-max 1000.0))
        (for/list ([t (in-list scv-tags)] [i (in-naturals)])
          (mk-unit t 'scv 1 (+ 29.0 (* 0.4 (modulo i 5))) (+ 30.5 (* 0.5 (quotient i 5)))
                   #:hp 45.0 #:hp-max 45.0
                   #:orders (list (sc2-unit-order AB-GATHER #f 9001 0.0))))
        (list (mk-unit 4401 'marine 1 43.0 33.5 #:hp 45.0 #:hp-max 45.0)
              (mk-unit 4402 'marine 1 43.0 34.5 #:hp 45.0 #:hp-max 45.0)
              (mk-unit 4403 'marine 1 42.5 34.0 #:hp 45.0 #:hp-max 45.0)
              (mk-unit 4404 'reaper 1 42.0 35.0 #:hp 60.0 #:hp-max 60.0))))
     (define enemies
       (for/list ([i (in-range 12)])
         (mk-unit (+ 8400 i) 'zergling 4 (+ 46.0 (* 0.5 (modulo i 4))) (+ 32.5 (* 0.6 (quotient i 4)))
                  #:hp 35.0 #:hp-max 35.0)))
     (define s1 (mk-obs 2600 (append allies enemies)
                        #:minerals 120 #:vespene 25 #:food-used 20 #:food-cap 23
                        #:food-army 4 #:food-workers 16))
     (define out (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define cross-map-scv-scouts
       (for/list ([c (in-list wcmds)]
                  #:when (and (sc2-raw-unit-command? c)
                              (= (sc2-raw-unit-command-ability-id c) AB-MOVE)
                              (sc2-point2d? (sc2-raw-unit-command-target-pos c))
                              (> (dist2d-xy 32.0 32.0
                                            (sc2-point2d-x (sc2-raw-unit-command-target-pos c))
                                            (sc2-point2d-y (sc2-raw-unit-command-target-pos c)))
                                 60.0)
                              (ormap (lambda (t) (memv t scv-tags))
                                     (sc2-raw-unit-command-unit-tags c))))
         (wire-cmd->summary c)))
     (define bunker-loaded-or-shooting?
       (or (wire-has-ability? wcmds '(4) AB-LOAD-BUNKER)
           (wire-has-ability? wcmds marine-tags AB-LOAD-BUNKER)
           (wire-has-ability? wcmds marine-tags AB-ATTACK)))
     (values out
             (list
              (mk-check "no-cross-map-worker-scout-during-early-ling-rush"
                        (null? cross-map-scv-scouts)
                        (format "SCV cross-map scout MOVE (>60t from base) during 12-Ling rush at natural: ~a (expected none)"
                                cross-map-scv-scouts))
              (mk-check "marines-load-bunker-or-engage-lings"
                        bunker-loaded-or-shooting?
                        (format "Bunker(4)/Marines emitted Load(407) or Attack(23): ~a" bunker-loaded-or-shooting?))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))


;; =============================================================================
;; Round-9 Pro-Inspired Regression Shields (novel-75..83)
;; =============================================================================

;; 75. Terran Battlecruiser Critical-HP Tactical Jump Escape (2358)
(define scen-novel-75
  (tactical-scenario
   "novel-75-terran-bc-tactical-jump-low-hp-escape"
   "novel" "Terran" "Zerg" "support-preservation"
   "Critically wounded Battlecruiser (95/550 HP) pursued by 6 Corruptors executes Tactical Jump (2358) back to home base."
   (lambda ()
     (define allies
       (append (mk-home-base-units 'Terran #:with-natural? #t)
               (list (mk-unit 5601 'battlecruiser 1 80.0 80.0 #:hp 95.0 #:hp-max 550.0 #:flying? #t))))
     (define enemies
       (for/list ([i (in-range 6)])
         (mk-unit (+ 8600 i) 'corruptor 4 85.0 (+ 78.5 (* 0.6 i)) #:hp 200.0 #:hp-max 200.0 #:flying? #t)))
     (define s1 (mk-obs 15000 (append allies enemies)
                        #:food-used 36 #:food-cap 66 #:food-army 6 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define jumped? (wire-has-ability? wcmds '(5601) AB-TACTICAL-JUMP))
     (values out
             (list
              (mk-check "low-hp-bc-emits-tactical-jump-2358"
                        jumped?
                        (format "BC 5601 (95/550 HP vs 6 Corruptors) emitted Tactical Jump (2358): ~a (abs=~a)"
                                jumped? (wire-abilities-for-tag wcmds 5601)))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; 76. Zerg Viper Low-Energy Consume Recharge (2073)
(define scen-novel-76
  (tactical-scenario
   "novel-76-zerg-viper-consume-hatchery-recharge"
   "novel" "Zerg" "Protoss" "spellcasters"
   "Low-energy Viper (25en) beside full-HP natural Hatchery casts Consume (2073) to recharge energy."
   (lambda ()
     (define allies
       (append (mk-home-base-units 'Zerg #:with-natural? #t)
               (list (mk-unit 6201 'viper 1 54.0 34.0 #:hp 150.0 #:hp-max 150.0 #:energy 25.0 #:flying? #t))))
     (define enemies
       (list (mk-unit 9301 'colossus 4 120.0 120.0 #:hp 200.0 #:hp-max 200.0 #:shield 150.0 #:shield-max 150.0)))
     (define s1 (mk-obs 14000 (append allies enemies)
                        #:food-used 34 #:food-cap 66 #:food-army 3 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Zerg 'Protoss (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define consumed? (wire-has-ability? wcmds '(6201) AB-VIPER-CONSUME))
     (values out
             (list
              (mk-check "low-energy-viper-emits-consume-2073"
                        consumed?
                        (format "Viper 6201 (25en near Hatchery 1002) emitted Consume (2073): ~a (abs=~a)"
                                consumed? (wire-abilities-for-tag wcmds 6201)))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; 77. Terran Raven Auto-Turret Worker Harass at 60 Energy (349)
(define scen-novel-77
  (tactical-scenario
   "novel-77-terran-raven-auto-turret-harass-low-energy"
   "novel" "Terran" "Protoss" "spellcasters"
   "Raven at 60 energy (<75 for AAM) over enemy mineral line drops Auto-Turret (349)."
   (lambda ()
     (define allies
       (append (mk-home-base-units 'Terran #:with-natural? #t)
               (list (mk-unit 6301 'raven 1 78.0 80.0 #:hp 140.0 #:hp-max 140.0 #:energy 60.0 #:flying? #t))))
     (define enemies
       (for/list ([i (in-range 5)])
         (mk-unit (+ 9400 i) 'probe 4 82.0 (+ 78.5 (* 0.5 i)) #:hp 20.0 #:hp-max 20.0 #:shield 20.0 #:shield-max 20.0)))
     (define s1 (mk-obs 10400 (append allies enemies)
                        #:food-used 32 #:food-cap 66 #:food-army 2 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Terran 'Protoss (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define turret? (wire-has-ability? wcmds '(6301) AB-AUTO-TURRET))
     (values out
             (list
              (mk-check "raven-60en-emits-auto-turret-349"
                        turret?
                        (format "Raven 6301 (60en over 5 Probes) emitted Auto-Turret (349): ~a (abs=~a)"
                                turret? (wire-abilities-for-tag wcmds 6301)))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; 78. Zerg Infestor Microbial Shroud Over Ground Army vs Air Fleet (4111)
(define scen-novel-78
  (tactical-scenario
   "novel-78-zerg-infestor-microbial-shroud-vs-air"
   "novel" "Zerg" "Protoss" "spellcasters"
   "Infestor (120en) with 6 Hydralisks facing 4 Void Rays at 11.5t (outside Fungal range) casts Microbial Shroud (4111) over Hydralisks."
   (lambda ()
     (define allies
       (append (mk-home-base-units 'Zerg #:with-natural? #t)
               (list (mk-unit 7201 'infestor 1 76.0 80.0 #:hp 90.0 #:hp-max 90.0 #:energy 120.0))
               (for/list ([i (in-range 6)])
                 (mk-unit (+ 7210 i) 'hydralisk 1 78.5 (+ 78.5 (* 0.5 i)) #:hp 90.0 #:hp-max 90.0))))
     (define enemies
       (for/list ([i (in-range 4)])
         (mk-unit (+ 9500 i) 'void-ray 4 87.5 (+ 78.5 (* 0.8 i))
                  #:hp 150.0 #:hp-max 150.0 #:shield 100.0 #:shield-max 100.0 #:flying? #t)))
     (define s1 (mk-obs 13000 (append allies enemies)
                        #:food-used 44 #:food-cap 66 #:food-army 14 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Zerg 'Protoss (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define shroud? (wire-has-ability? wcmds '(7201) AB-MICROBIAL-SHROUD))
     (values out
             (list
              (mk-check "infestor-casts-microbial-shroud-4111"
                        shroud?
                        (format "Infestor 7201 emitted Microbial Shroud (4111): ~a (abs=~a)"
                                shroud? (wire-abilities-for-tag wcmds 7201)))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; 79. Zerg Swarm Host Spawn Locusts Siege Wave (1990)
(define scen-novel-79
  (tactical-scenario
   "novel-79-zerg-swarm-host-spawn-locusts-siege"
   "novel" "Zerg" "Terran" "spellcasters"
   "Two Swarm Hosts outside enemy base emit Spawn Locusts (1990) toward enemy Command Center and defenders."
   (lambda ()
     (define allies
       (append (mk-home-base-units 'Zerg #:with-natural? #t)
               (list (mk-unit 6501 'swarm-host 1 138.0 138.0 #:hp 160.0 #:hp-max 160.0)
                     (mk-unit 6502 'swarm-host 1 139.0 138.0 #:hp 160.0 #:hp-max 160.0))))
     (define enemies
       (list (mk-unit 9601 'command-center 4 155.0 155.0 #:hp 1500.0 #:hp-max 1500.0)
             (mk-unit 9602 'marine 4 152.0 152.0 #:hp 45.0 #:hp-max 45.0)))
     (define s1 (mk-obs 11200 (append allies enemies)
                        #:food-used 36 #:food-cap 66 #:food-army 6 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Zerg 'Terran (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define sh1? (wire-has-ability? wcmds '(6501) AB-SPAWN-LOCUSTS))
     (define sh2? (wire-has-ability? wcmds '(6502) AB-SPAWN-LOCUSTS))
     (values out
             (list
              (mk-check "both-swarm-hosts-spawn-locusts-1990"
                        (and sh1? sh2?)
                        (format "Swarm Hosts 6501/6502 emitted Spawn Locusts (1990): ~a / ~a" sh1? sh2?))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; 80. Zerg Queen Mid-Fight Transfuse Priority Over Creep Tumor
(define scen-novel-80
  (tactical-scenario
   "novel-80-zerg-queen-transfuse-priority-over-creep-tumor"
   "novel" "Zerg" "Protoss" "spellcasters"
   "55-energy Queen fighting alongside a critically wounded Ultralisk (180/500 HP) prioritizes Transfusion (1664) over Creep Tumor (1694)."
   (lambda ()
     (define allies
       (append (mk-home-base-units 'Zerg #:with-natural? #t)
               (list (mk-unit 5901 'queen 1 78.0 80.0 #:hp 175.0 #:hp-max 175.0 #:energy 55.0)
                     (mk-unit 5902 'ultralisk 1 80.0 80.0 #:hp 180.0 #:hp-max 500.0))))
     (define enemies
       (for/list ([i (in-range 4)])
         (mk-unit (+ 8900 i) 'stalker 4 84.5 (+ 78.5 (* 0.6 i))
                  #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0)))
     (define s1 (mk-obs 12200 (append allies enemies)
                        #:food-used 40 #:food-cap 66 #:food-army 8 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Zerg 'Protoss (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define transfused? (wire-has-ability? wcmds '(5901) AB-TRANSFUSE))
     (define tumored? (wire-has-ability? wcmds '(5901) AB-CREEP-TUMOR-QUEEN))
     (values out
             (list
              (mk-check "queen-55en-transfuses-wounded-ultralisk"
                        (and transfused? (not tumored?))
                        (format "Queen 5901: Transfuse(1664)=~a CreepTumor(1694)=~a" transfused? tumored?))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; 81. Protoss Stalker Blink Upgrade Gate (no Blink without id=87; Blink with id=87)
(define scen-novel-81
  (tactical-scenario
   "novel-81-protoss-stalker-blink-upgrade-gate"
   "novel" "Protoss" "Terran" "unit-mobility-micro"
   "Low-shield Stalker (5/80 SH) never emits invalid Blink without Blink upgrade (id=87), and DOES blink back (3687/1442) when id=87 is researched."
   (lambda ()
     (define (mk-st upgs)
       (mk-obs 10000
               (append (mk-home-base-units 'Protoss #:with-natural? #t)
                       (list (mk-unit 7501 'stalker 1 78.0 80.0 #:hp 65.0 #:hp-max 80.0 #:shield 5.0 #:shield-max 80.0)
                             (mk-unit 7502 'stalker 1 78.0 81.5 #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))
                       (for/list ([i (in-range 4)])
                         (mk-unit (+ 9800 i) 'marauder 4 83.0 (+ 79.5 (* 0.6 i)) #:hp 125.0 #:hp-max 125.0)))
               #:upgrades upgs #:food-used 36 #:food-cap 56 #:food-army 4 #:food-workers 24))
     (define out-no (last (run-pipeline-sequence 'Protoss 'Terran (list (hash 'obs (mk-st '()))))))
     (define w-no (step-outcome-wire-cmds out-no))
     (define blink-no? (or (wire-has-ability? w-no '(7501) AB-BLINK-GENERIC)
                           (wire-has-ability? w-no '(7501) AB-BLINK-STALKER)))
     (define out-yes (last (run-pipeline-sequence 'Protoss 'Terran (list (hash 'obs (mk-st '(blink)))))))
     (define w-yes (step-outcome-wire-cmds out-yes))
     (define blink-yes? (or (wire-has-ability? w-yes '(7501) AB-BLINK-GENERIC)
                            (wire-has-ability? w-yes '(7501) AB-BLINK-STALKER)))
     (values out-yes
             (list
              (mk-check "no-blink-without-upgrade"
                        (not blink-no?)
                        (format "Unupgraded Stalker 7501 emitted Blink: ~a (expected #f)" blink-no?))
              (mk-check "blink-back-with-upgrade"
                        blink-yes?
                        (format "Upgraded low-shield Stalker 7501 emitted Blink (3687/1442): ~a" blink-yes?))
              (mk-check "zero-wire-rejects"
                        (and (= (step-outcome-wire-rejects out-no) 0) (= (step-outcome-wire-rejects out-yes) 0))
                        (format "rejects no=~a yes=~a"
                                (step-outcome-wire-rejects out-no) (step-outcome-wire-rejects out-yes))))))))

;; 82. Protoss Carrier Auto-Interceptors (1042) & Oracle Pulsar Beam Off (2376 after dwell)
(define scen-novel-82
  (tactical-scenario
   "novel-82-protoss-carrier-interceptors-and-oracle-beam-off"
   "novel" "Protoss" "Terran" "unit-modes"
   "Carrier builds Interceptors (1042), and Oracle with active Pulsar Beam (buff=56) and 0 nearby enemies turns Pulsar Beam OFF (2376) after >=111f dwell."
   (lambda ()
     (define s-car
       (mk-obs 16000
               (append (mk-home-base-units 'Protoss #:with-natural? #t)
                       (list (mk-unit 6801 'carrier 1 50.0 36.0 #:hp 300.0 #:hp-max 300.0 #:shield 150.0 #:shield-max 150.0 #:flying? #t)
                             (mk-unit 9901 'command-center 4 160.0 160.0 #:hp 1500.0 #:hp-max 1500.0)))
               #:food-used 40 #:food-cap 66 #:food-army 6 #:food-workers 24))
     (define out-car (last (run-pipeline-sequence 'Protoss 'Terran (list (hash 'obs s-car)))))
     (define int-ok? (wire-has-ability? (step-outcome-wire-cmds out-car) '(6801) AB-BUILD-INTERCEPTORS))
     (define (mk-ora fr)
       (mk-obs fr
               (append (mk-home-base-units 'Protoss #:with-natural? #t)
                       (list (mk-unit 7101 'oracle 1 70.0 70.0 #:hp 100.0 #:hp-max 100.0 #:shield 60.0 #:shield-max 60.0
                                      #:energy 40.0 #:flying? #t #:buffs '(99))
                             (mk-unit 9701 'command-center 4 160.0 160.0 #:hp 1500.0 #:hp-max 1500.0)))
               #:food-used 30 #:food-cap 46 #:food-army 3 #:food-workers 24))
     (define out-ora (last (run-pipeline-sequence 'Protoss 'Terran
                                                  (list (hash 'obs (mk-ora 9000))
                                                        (hash 'obs (mk-ora 9140))))))
     (define beam-off? (wire-has-ability? (step-outcome-wire-cmds out-ora) '(7101) AB-PULSAR-BEAM-OFF))
     (values out-ora
             (list
              (mk-check "carrier-queues-build-interceptors-1042"
                        int-ok?
                        (format "Carrier 6801 emitted Build Interceptors (1042): ~a" int-ok?))
              (mk-check "oracle-turns-pulsar-beam-off-2376-after-dwell"
                        beam-off?
                        (format "Oracle 7101 (buff=99, 140f dwell, 0 enemies near) emitted Pulsar Beam Off (2376): ~a (abs=~a)"
                                beam-off? (wire-abilities-for-tag (step-outcome-wire-cmds out-ora) 7101)))
              (mk-check "zero-wire-rejects"
                        (and (= (step-outcome-wire-rejects out-car) 0) (= (step-outcome-wire-rejects out-ora) 0))
                        (format "rejects car=~a ora=~a"
                                (step-outcome-wire-rejects out-car) (step-outcome-wire-rejects out-ora))))))))

;; 83. Zerg Low-Energy Infestor Retreats Safely While Roaches Engage
(define scen-novel-83
  (tactical-scenario
   "novel-83-zerg-low-energy-infestor-retreat-not-suicide"
   "novel" "Zerg" "Terran" "support-preservation"
   "Low-energy Infestor (30en, <70en) threatened by 8 Marines retreats toward home (MOVE 16) while 4 Roaches engage."
   (lambda ()
     (define roach-tags '(7410 7411 7412 7413))
     (define enemy-tags (for/list ([i (in-range 8)]) (+ 9700 i)))
     (define allies
       (append (mk-home-base-units 'Zerg #:with-natural? #t)
               (list (mk-unit 7401 'infestor 1 78.0 80.0 #:hp 90.0 #:hp-max 90.0 #:energy 30.0))
               (for/list ([t (in-list roach-tags)] [i (in-naturals)])
                 (mk-unit t 'roach 1 80.0 (+ 79.0 (* 0.6 i)) #:hp 145.0 #:hp-max 145.0))))
     (define enemies
       (for/list ([t (in-list enemy-tags)] [i (in-naturals)])
         (mk-unit t 'marine 4 85.0 (+ 78.0 (* 0.5 i)) #:hp 45.0 #:hp-max 45.0)))
     (define s1 (mk-obs 12500 (append allies enemies)
                        #:food-used 44 #:food-cap 66 #:food-army 10 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Zerg 'Terran (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define inf-retreats?
       (for/or ([c (in-list (wire-cmds-for-tag wcmds 7401))])
         (and (= (sc2-raw-unit-command-ability-id c) AB-MOVE)
              (sc2-point2d? (sc2-raw-unit-command-target-pos c))
              (< (sc2-point2d-x (sc2-raw-unit-command-target-pos c)) 76.0))))
     (define roach-atk (wire-count-local-attacks wcmds roach-tags enemy-tags 85.0 80.0 16.0))
     (values out
             (list
              (mk-check "low-energy-infestor-retreats-away-from-marines"
                        inf-retreats?
                        (format "30en Infestor 7401 retreated west (x<76): ~a" inf-retreats?))
              (mk-check "roaches-engage-marines"
                        (>= roach-atk 3)
                        (format "Roaches attacking Marines: ~a/4" roach-atk))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; 84. Terran Medivac Critical-HP Marauder Save-Pickup (3668) With Shift-Queued Retreat
(define scen-novel-84
  (tactical-scenario
   "novel-84-terran-medivac-save-pickup-critical-marauder"
   "novel" "Terran" "Zerg" "support-preservation"
   "Medivac next to a critically wounded Marauder (25/125 HP) under Ultralisk threat emits Load Transport (3668) with shift-queued safe retreat (no unstacked MOVE overwrite)."
   (lambda ()
     (define allies
       (append (mk-home-base-units 'Terran #:with-natural? #t)
               (list (mk-unit 7601 'marauder 1 76.0 80.0 #:hp 25.0 #:hp-max 125.0)
                     (mk-unit 7602 'medivac  1 75.5 80.0 #:hp 150.0 #:hp-max 150.0 #:energy 100.0 #:flying? #t)
                     (mk-unit 7603 'marine   1 77.0 80.0 #:hp 45.0 #:hp-max 45.0))))
     (define enemies
       (list (mk-unit 9601 'ultralisk 4 82.0 80.0 #:hp 500.0 #:hp-max 500.0)))
     (define s1 (mk-obs 12000 (append allies enemies)
                        #:food-used 40 #:food-cap 66 #:food-army 5 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define med-cmds (wire-cmds-for-tag wcmds 7602))
     (define has-load? (wire-has-ability? wcmds '(7602) AB-LOAD-GENERIC))
     (define has-unstacked-move?
       (for/or ([c (in-list med-cmds)])
         (and (= (sc2-raw-unit-command-ability-id c) AB-MOVE)
              (not (sc2-raw-unit-command-queue? c)))))
     (values out
             (list
              (mk-check "medivac-emits-load-transport-3668"
                        has-load?
                        (format "Medivac 7602 emitted Load Transport (3668): ~a (abs=~a)"
                                has-load? (wire-abilities-for-tag wcmds 7602)))
              (mk-check "medivac-load-not-cancelled-by-unstacked-move-16"
                        (not has-unstacked-move?)
                        (format "Medivac 7602 emitted non-queued MOVE (16) overwriting 3668: ~a"
                                has-unstacked-move?))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; =============================================================================
;; Round-9 Verified Live-Pipeline Bug Reproductions (wave9-repro: w9-tac-1..5)
;; =============================================================================

;; 134. W9-TAC-1 (from real-SC2 t02 3.00x W -> 0.55x L & Phoenix Graviton probe):
;;      `lib/sc2-protobuf-ws.rkt:13334-13345` (`tactical-hold-posture?` post-loop idle handler)
;;      has ZERO enemy-proximity check (`<= 16.0t`), unlike `execute-spatial-maneuver` (`L12700`).
;;      Any idle/cortex-clipped combat unit standing right next to live enemies (Marines 5011/5012
;;      at 7.5t from Lings+Roaches in t02, or Phoenix 5702 at 4.5t from the Immortal that Phoenix
;;      5701 just lifted) gets yanked 40+ tiles backwards to `(eff-hold-x, eff-hold-y)` = (48.97, 48.97)!
(define scen-w9-tac-1
  (tactical-scenario
   "w9-tac-1-tactical-hold-idle-never-yanks-frontline-units-home"
   "wave9-repro" "Terran" "Zerg" "frontline-cohesion"
   "Wave-9 Repro (W9-TAC-1 / t02 + Phoenix): tactical-hold-posture idle handler (sc2-protobuf-ws.rkt:13334) must NEVER yank frontline combat units within <=16t of enemies 40t back to (48.97, 48.97)"
   (lambda ()
     ;; Part A: t02 (2 Siege Tanks + 8 Marines at (76.5, 79) vs 12 Lings + 8 Roaches at (84, 79))
     (define mar-tags (for/list ([i (in-range 8)]) (+ 5010 i)))
     (define t02-allies
       (append (mk-home-base-units 'Terran #:with-natural? #t)
               (list (mk-unit 5001 'siege-tank 1 74.5 80.0 #:hp 175.0 #:hp-max 175.0)
                     (mk-unit 5002 'siege-tank 1 74.5 81.5 #:hp 175.0 #:hp-max 175.0))
               (for/list ([t (in-list mar-tags)] [i (in-naturals)])
                 (mk-unit t 'marine 1 76.5 (+ 78.0 (* 0.5 i)) #:hp 45.0 #:hp-max 45.0))))
     (define t02-enemies
       (append (for/list ([i (in-range 12)])
                 (mk-unit (+ 8010 i) 'zergling 4 84.0 (+ 77.5 (* 0.4 i)) #:hp 35.0 #:hp-max 35.0))
               (for/list ([i (in-range 8)])
                 (mk-unit (+ 8030 i) 'roach 4 85.5 (+ 78.0 (* 0.5 i)) #:hp 145.0 #:hp-max 145.0))))
     (define out-a (last (run-pipeline-sequence 'Terran 'Zerg
                                                (list (hash 'obs (mk-obs 12000 (append t02-allies t02-enemies)
                                                                         #:food-used 44 #:food-cap 66 #:food-army 14 #:food-workers 24))))))
     (define w-a (step-outcome-wire-cmds out-a))
     (define t02-yanked-home
       (for/list ([c (in-list w-a)]
                  #:when (and (sc2-raw-unit-command? c)
                              (memv (sc2-raw-unit-command-ability-id c) (list AB-ATTACK AB-MOVE))
                              (sc2-point2d? (sc2-raw-unit-command-target-pos c))
                              (> (dist2d-xy 80.0 80.0
                                            (sc2-point2d-x (sc2-raw-unit-command-target-pos c))
                                            (sc2-point2d-y (sc2-raw-unit-command-target-pos c)))
                                 25.0)
                              (ormap (lambda (t) (memv t mar-tags)) (sc2-raw-unit-command-unit-tags c))))
         (wire-cmd->summary c)))
     ;; Part B: 2 Phoenixes + Zealot at (78, 81) vs Immortal + Zealot at (82.5, 81)
     (define phx-allies
       (append (mk-home-base-units 'Protoss #:with-natural? #t)
               (list (mk-unit 5701 'phoenix 1 78.0 80.0 #:hp 120.0 #:hp-max 120.0 #:shield 60.0 #:shield-max 60.0 #:energy 100.0 #:flying? #t)
                     (mk-unit 5702 'phoenix 1 78.0 82.0 #:hp 120.0 #:hp-max 120.0 #:shield 60.0 #:shield-max 60.0 #:energy 100.0 #:flying? #t)
                     (mk-unit 5703 'zealot  1 80.0 80.5 #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0))))
     (define phx-enemies
       (list (mk-unit 8701 'immortal 4 82.5 80.5 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0)
             (mk-unit 8702 'zealot   4 82.5 82.0 #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0)))
     (define out-b (last (run-pipeline-sequence 'Protoss 'Protoss
                                                (list (hash 'obs (mk-obs 9800 (append phx-allies phx-enemies)
                                                                         #:food-used 36 #:food-cap 56 #:food-army 6 #:food-workers 24))))))
     (define w-b (step-outcome-wire-cmds out-b))
     (define phx1-lifted? (wire-has-ability? w-b '(5701) AB-GRAVITON-BEAM))
     (define phx2-yanked-home
       (for/list ([c (in-list (wire-cmds-for-tag w-b 5702))]
                  #:when (and (memv (sc2-raw-unit-command-ability-id c) (list AB-ATTACK AB-MOVE))
                              (sc2-point2d? (sc2-raw-unit-command-target-pos c))
                              (> (dist2d-xy 80.0 80.0
                                            (sc2-point2d-x (sc2-raw-unit-command-target-pos c))
                                            (sc2-point2d-y (sc2-raw-unit-command-target-pos c)))
                                 25.0)))
         (wire-cmd->summary c)))
     (values out-a
             (list
              (mk-check "t02-marines-near-enemies-never-yanked-home"
                        (null? t02-yanked-home)
                        (format "t02 Marines yanked >25t away from fight: ~a (expected none)" t02-yanked-home))
              (mk-check "phoenix-1-casts-graviton-beam-and-phoenix-2-not-yanked-home"
                        (and phx1-lifted? (null? phx2-yanked-home))
                        (format "Phoenix 5701 Graviton(173)=~a; Phoenix 5702 yanked >25t away: ~a (expected none)"
                                phx1-lifted? phx2-yanked-home))
              (mk-check "zero-wire-rejects"
                        (and (= (step-outcome-wire-rejects out-a) 0) (= (step-outcome-wire-rejects out-b) 0))
                        (format "rejects a=~a b=~a"
                                (step-outcome-wire-rejects out-a) (step-outcome-wire-rejects out-b))))))))

;; 135. W9-TAC-2 (bot-runtime.rkt:23687, 23710 + human-cortex.rkt:1687):
;;      Passing per-unit enemy target `eid` to zero-target self-abilities (`stimpack`, `siege-mode`)
;;      shatters `human-cortex` box-select coalescing -> ONLY 2/6 Marines get Stimpack (3675) and
;;      ONLY 2/4 Siege Tanks siege (388) on a step!
(define scen-w9-tac-2
  (tactical-scenario
   "w9-tac-2-no-target-stimpack-and-siege-mode-coalesce-full-squad"
   "wave9-repro" "Terran" "Zerg" "unit-modes"
   "Wave-9 Repro (W9-TAC-2): zero-target Stimpack (3675) and Siege Mode (388) must omit spurious enemy `eid` so human-cortex coalesces full Bio/Tank squads (all 6/6 Marines stim, all 4/4 Tanks siege)"
   (lambda ()
     ;; Part A: 6 full-HP Marines with Stimpack researched vs 6 spread Roaches
     (define mar-tags (for/list ([i (in-range 6)]) (+ 6000 i)))
     (define s-bio
       (mk-obs 8400
               (append (mk-home-base-units 'Terran #:with-natural? #t)
                       (for/list ([t (in-list mar-tags)] [i (in-naturals)])
                         (mk-unit t 'marine 1 78.0 (+ 78.5 (* 0.5 i)) #:hp 45.0 #:hp-max 45.0))
                       (for/list ([i (in-range 6)])
                         (mk-unit (+ 9100 i) 'roach 4 83.0 (+ 78.5 (* 0.5 i)) #:hp 145.0 #:hp-max 145.0)))
               #:upgrades '(stimpack) #:food-used 40 #:food-cap 66 #:food-army 6 #:food-workers 24))
     (define out-bio (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s-bio)))))
     (define w-bio (step-outcome-wire-cmds out-bio))
     (define stimmed-marines
       (for/sum ([t (in-list mar-tags)])
         (if (or (wire-has-ability? w-bio (list t) AB-STIMPACK)
                 (wire-has-ability? w-bio (list t) AB-STIM-ALT))
             1 0)))
     ;; Part B: 4 Siege Tanks vs 4 spread Roaches (distinct enemy targets!)
     (define tank-tags '(7001 7002 7003 7004))
     (define s-tanks
       (mk-obs 12000
               (append (mk-home-base-units 'Terran #:with-natural? #t)
                       (list (mk-unit 7001 'siege-tank 1 74.0 74.0 #:hp 175.0 #:hp-max 175.0)
                             (mk-unit 7002 'siege-tank 1 74.0 78.0 #:hp 175.0 #:hp-max 175.0)
                             (mk-unit 7003 'siege-tank 1 74.0 82.0 #:hp 175.0 #:hp-max 175.0)
                             (mk-unit 7004 'siege-tank 1 74.0 86.0 #:hp 175.0 #:hp-max 175.0)
                             (mk-unit 8001 'roach 4 84.0 74.0 #:hp 145.0 #:hp-max 145.0)
                             (mk-unit 8010 'roach 4 84.0 78.0 #:hp 145.0 #:hp-max 145.0)
                             (mk-unit 8020 'roach 4 84.0 82.0 #:hp 145.0 #:hp-max 145.0)
                             (mk-unit 8030 'roach 4 84.0 86.0 #:hp 145.0 #:hp-max 145.0)))
               #:food-used 48 #:food-cap 66 #:food-army 12 #:food-workers 24))
     (define out-tanks (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s-tanks)))))
     (define w-tanks (step-outcome-wire-cmds out-tanks))
     (define sieged-tanks
       (for/sum ([t (in-list tank-tags)])
         (if (wire-has-ability? w-tanks (list t) AB-SIEGE-MODE) 1 0)))
     (values out-bio
             (list
              (mk-check "all-6-marines-coalesce-into-stimpack"
                        (>= stimmed-marines 5)
                        (format "Marines receiving Stimpack (3675): ~a/6 (expected >=5/6)" stimmed-marines))
              (mk-check "all-4-tanks-coalesce-into-siege-mode"
                        (= sieged-tanks 4)
                        (format "Siege Tanks emitting Siege Mode (388): ~a/4 (expected 4/4)" sieged-tanks))
              (mk-check "zero-wire-rejects"
                        (and (= (step-outcome-wire-rejects out-bio) 0) (= (step-outcome-wire-rejects out-tanks) 0))
                        (format "rejects bio=~a tanks=~a"
                                (step-outcome-wire-rejects out-bio) (step-outcome-wire-rejects out-tanks))))))))

;; 136. W9-TAC-3 (sc2-protobuf-ws.rkt:12463-12479 + bot-runtime.rkt:15178):
;;      100-energy Orbital Command facing cloaked Dark Templars emits TWO Scanner Sweep (399)
;;      wire commands on the exact same OC `0.5` tiles apart in ONE step (`cast-spell` +
;;      `blind-skillshot-shimmer`), burning all 100 energy on one cloaked cluster!
(define scen-w9-tac-3
  (tactical-scenario
   "w9-tac-3-orbital-command-never-double-scans-same-cloaked-threat"
   "wave9-repro" "Terran" "Protoss" "detection"
   "Wave-9 Repro (W9-TAC-3): 100-energy Orbital Command revealing cloaked Dark Templars must emit EXACTLY 1 Scanner Sweep (399) per step (never double-burning 100 energy 0.5t apart)"
   (lambda ()
     (define allies
       (append
        (list (mk-unit 1001 'orbital-command 1 32.0 32.0 #:hp 1500.0 #:hp-max 1500.0 #:energy 100.0)
              (mk-unit 1002 'orbital-command 1 52.0 32.0 #:hp 1500.0 #:hp-max 1500.0 #:energy 75.0))
        (for/list ([i (in-range 12)])
          (mk-unit (+ 1100 i) 'scv 1 (+ 27.0 (* 0.4 (modulo i 4))) (+ 30.0 (* 0.4 (quotient i 4)))
                   #:orders (list (sc2-unit-order AB-GATHER #f 90001 0.0))))
        (for/list ([i (in-range 6)])
          (mk-unit (+ 5400 i) 'marine 1 78.0 (+ 78.5 (* 0.5 i)) #:hp 45.0 #:hp-max 45.0))))
     (define enemies
       (list (mk-unit 8401 'dark-templar 4 81.5 80.0 #:hp 40.0 #:hp-max 40.0 #:shield 80.0 #:shield-max 80.0 #:cloak 1)
             (mk-unit 8402 'dark-templar 4 81.5 81.0 #:hp 40.0 #:hp-max 40.0 #:shield 80.0 #:shield-max 80.0 #:cloak 1)))
     (define s1 (mk-obs 9600 (append allies enemies)
                        #:food-used 36 #:food-cap 56 #:food-army 6 #:food-workers 12))
     (define out (last (run-pipeline-sequence 'Terran 'Protoss (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define scan-cmds
       (for/list ([c (in-list wcmds)]
                  #:when (and (sc2-raw-unit-command? c)
                              (= (sc2-raw-unit-command-ability-id c) AB-SCANNER-SWEEP)))
         (wire-cmd->summary c)))
     (values out
             (list
              (mk-check "exactly-one-scanner-sweep-399-emitted"
                        (= (length scan-cmds) 1)
                        (format "Scanner Sweep (399) count=~a (expected exactly 1; cmds=~a)"
                                (length scan-cmds) scan-cmds))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; 137. W9-TAC-4 (sc2-protobuf-ws.rkt:12318-12325 + bot-runtime.rkt:9512,24108 + pro-spellcaster-micro.rkt:2642):
;;      100-energy Overseer emits THREE identical Spawn Changeling (181) wire commands on the
;;      exact same tag in ONE step (`L2 cast` + `cast-deception-and-scout-spells` + `pro-spellcaster-micro`),
;;      draining all 100 energy and starving Contaminate!
(define scen-w9-tac-4
  (tactical-scenario
   "w9-tac-4-overseer-never-triple-spams-spawn-changeling-same-step"
   "wave9-repro" "Zerg" "Terran" "spellcasters"
   "Wave-9 Repro (W9-TAC-4): 100-energy Overseer must emit AT MOST 1 Spawn Changeling (181) wire command per step (never triple-spamming 3x 181 on the same tag)"
   (lambda ()
     (define allies
       (append (mk-home-base-units 'Zerg #:with-natural? #t)
               (list (mk-unit 6101 'overseer 1 80.0 80.0 #:hp 200.0 #:hp-max 200.0 #:energy 100.0 #:flying? #t))))
     (define enemies
       (list (mk-unit 9201 'command-center 4 160.0 160.0 #:hp 1500.0 #:hp-max 1500.0)))
     (define s1 (mk-obs 10000 (append allies enemies)
                        #:food-used 30 #:food-cap 52 #:food-army 0 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Zerg 'Terran (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define chg-cmds
       (for/list ([c (in-list (wire-cmds-for-tag wcmds 6101))]
                  #:when (= (sc2-raw-unit-command-ability-id c) AB-SPAWN-CHANGELING))
         (wire-cmd->summary c)))
     (values out
             (list
              (mk-check "overseer-emits-exactly-one-spawn-changeling-181"
                        (= (length chg-cmds) 1)
                        (format "Overseer 6101 Spawn Changeling (181) count=~a (expected 1; cmds=~a)"
                                (length chg-cmds) chg-cmds))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; 139. W9-TAC-5 (from t04 real-SC2 `3668` pickup cancelling Snipe!):
;;      `transport-drop-micro.rkt` (`ally-base-save-priority`) + `sc2-protobuf-ws.rkt:11439`
;;      never check if a bruised Ghost (`35/100 HP`) is actively channeling `STEADY_TARGETING (2714)`
;;      at safe standoff (`8t` from Ultralisk) -> Medivac emits `LOAD_TRANSPORT (3668)` on the
;;      channeling Ghost, instantly cancelling its 170-damage Snipe instead of healing it!
(define scen-w9-tac-5
  (tactical-scenario
   "w9-tac-5-medivac-never-cancels-channeling-ghost-snipe-via-pickup"
   "wave9-repro" "Terran" "Zerg" "spellcasters"
   "Wave-9 Repro (W9-TAC-5 / t04): Medivac beside a bruised Ghost (25/100 HP) actively channeling Steady Targeting (2714) at 8t standoff must NOT cancel its Snipe via Load Transport (3668)"
   (lambda ()
     (define allies
       (append (mk-home-base-units 'Terran #:with-natural? #t)
               (list (mk-unit 7301 'ghost 1 76.0 80.0 #:hp 25.0 #:hp-max 100.0 #:energy 100.0
                              #:orders (list (sc2-unit-order AB-SNIPE #f 9601 0.0)))
                     (mk-unit 7302 'medivac 1 75.5 80.0 #:hp 150.0 #:hp-max 150.0 #:energy 100.0 #:flying? #t)
                     (mk-unit 7303 'marine  1 77.0 80.0 #:hp 45.0 #:hp-max 45.0))))
     (define enemies
       (list (mk-unit 9601 'ultralisk 4 84.0 80.0 #:hp 500.0 #:hp-max 500.0)))
     (define s1 (mk-obs 13800 (append allies enemies)
                        #:food-used 40 #:food-cap 66 #:food-army 5 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define picked-up-channeling-ghost?
       (for/or ([c (in-list (wire-cmds-for-tag wcmds 7302))])
         (and (memv (sc2-raw-unit-command-ability-id c) (list AB-LOAD-GENERIC AB-MEDIVAC-LOAD))
              (= (sc2-raw-unit-command-target-unit-tag c) 7301))))
     (values out
             (list
              (mk-check "medivac-does-not-load-channeling-ghost-7301"
                        (not picked-up-channeling-ghost?)
                        (format "Medivac 7302 emitted Load (3668/394) on Snipe-channeling Ghost 7301: ~a (expected #f; cmds=~a)"
                                picked-up-channeling-ghost? (map wire-cmd->summary (wire-cmds-for-tag wcmds 7302))))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; 140. W9-TAC-6 (W9-P0-2-rt / #28 Z v Creepy 172-2 & #30 P v Creepy 55-2 0-DPS Tempest Retreat):
;;      12 Hydralisks at (75,75) facing 22 Tempests at (86,75) (11t away, inside Tempest range 10-14t)
;;      currently emit 11/12 pure MOVE (16) retreats + 1/12 yanked to (50,50) — ZERO local attacks!
;;      With W9-P0-2-rt (capital/siege dive within <=15.5t when >=6 AA units ready), Hydralisks dive in
;;      and emit ATTACK (23) onto the Tempests instead of dying at 0 DPS while kiting!
(define scen-w9-tac-6
  (tactical-scenario
   "w9-tac-6-hydralisks-dive-tempests-at-11t-not-zero-dps-retreat"
   "wave9-repro" "Zerg" "Protoss" "capital-siege-dive"
   "Wave-9 Repro (W9-TAC-6 / W9-P0-2-rt #28): 12 ready-weapon Hydralisks facing Tempests at 11t must dive in and attack (ATTACK 23) instead of pure-MOVE retreating at 0 DPS"
   (lambda ()
     (define hydra-tags (for/list ([i (in-range 12)]) (+ 6000 i)))
     (define tempest-tags (for/list ([i (in-range 22)]) (+ 9000 i)))
     (define allies
       (append (mk-home-base-units 'Zerg #:with-natural? #t)
               (for/list ([t (in-list hydra-tags)] [i (in-naturals)])
                 (mk-unit t 'hydralisk 1 (+ 75.0 (* 0.5 (modulo i 4))) (+ 74.0 (* 0.6 (quotient i 4)))
                          #:hp 90.0 #:hp-max 90.0 #:weapon-cooldown 0.0))))
     (define enemies
       (for/list ([t (in-list tempest-tags)] [i (in-naturals)])
         (mk-unit t 'tempest 4 (+ 86.0 (* 0.7 (modulo i 6))) (+ 72.5 (* 0.9 (quotient i 6)))
                  #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0 #:flying? #t)))
     (define s1 (mk-obs 18000 (append allies enemies)
                        #:food-used 48 #:food-cap 66 #:food-army 24 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Zerg 'Protoss (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define hydra-local-atk (wire-count-local-attacks wcmds hydra-tags tempest-tags 87.5 74.0 16.0))
     (define hydra-pure-move (for/sum ([t (in-list hydra-tags)]) (if (wire-pure-move-only? wcmds t) 1 0)))
     (values out
             (list
              (mk-check "hydralisks-dive-tempests-not-pure-move-suicide"
                        (and (>= hydra-local-atk 8) (<= hydra-pure-move 3))
                        (format "12 Hydras vs Tempests at 11t: local-ATK=~a/12 (expected >=8), pure-MOVE=~a/12 (expected <=3)"
                                hydra-local-atk hydra-pure-move))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))


;; =============================================================================
;; Round-10 Pro-Inspired Multi-Step Cooldown & Cadence Regression Shields (novel-85..90)
;; =============================================================================

;; 85. Zerg Swarm Host 2-Step Cooldown Discipline (spawns Locusts step 1, retreats step 2)
(define scen-novel-85
  (tactical-scenario
   "novel-85-zerg-swarm-host-2step-cooldown-retreats-safely"
   "novel" "Zerg" "Terran" "spellcasters"
   "2-step Swarm Host emits Spawn Locusts (1990) on step 1, and retreats (MOVE 16) without re-spamming 1990 on step 2 (+20f)."
   (lambda ()
     (define (mk-sh fr)
       (mk-obs fr
               (append (mk-home-base-units 'Zerg #:with-natural? #t)
                       (list (mk-unit 5281 'swarm-host 1 138.0 138.0 #:hp 160.0 #:hp-max 160.0)
                             (mk-unit 8281 'command-center 4 155.0 155.0 #:hp 1500.0 #:hp-max 1500.0)
                             (mk-unit 8282 'marine 4 152.0 152.0 #:hp 45.0 #:hp-max 45.0)))
               #:food-used 36 #:food-cap 66 #:food-army 3 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Zerg 'Terran
                                         (list (hash 'obs (mk-sh 11200))
                                               (hash 'obs (mk-sh 11220)))))
     (define w1 (step-outcome-wire-cmds (first outs)))
     (define w2 (step-outcome-wire-cmds (second outs)))
     (define s1-locust? (wire-has-ability? w1 '(5281) AB-SPAWN-LOCUSTS))
     (define s2-locust? (wire-has-ability? w2 '(5281) AB-SPAWN-LOCUSTS))
     (define s2-move?   (wire-has-ability? w2 '(5281) AB-MOVE))
     (values (second outs)
             (list
              (mk-check "swarm-host-spawns-locusts-step1" s1-locust?
                        (format "Step 1 Spawn Locusts (1990): ~a" s1-locust?))
              (mk-check "swarm-host-retreats-not-spam-step2" (and (not s2-locust?) s2-move?)
                        (format "Step 2 (+20f): SpawnLocusts=~a MOVE=~a (abs=~a)"
                                s2-locust? s2-move? (wire-abilities-for-tag w2 5281)))
              (mk-check "zero-wire-rejects"
                        (and (= (step-outcome-wire-rejects (first outs)) 0)
                             (= (step-outcome-wire-rejects (second outs)) 0))
                        "wire_rejects=0"))))))

;; 86. Protoss Disruptor 2-Step Nova Cooldown Discipline (fires Nova step 1, kites safely step 2)
(define scen-novel-86
  (tactical-scenario
   "novel-86-protoss-disruptor-nova-2step-cooldown-kites-back"
   "novel" "Protoss" "Terran" "spellcasters"
   "2-step Disruptor emits Purification Nova (2346) on step 1, then kites safely back (MOVE 16) on step 2 (+60f) without re-spamming 2346."
   (lambda ()
     (define (mk-dis fr)
       (mk-obs fr
               (append (mk-home-base-units 'Protoss #:with-natural? #t)
                       (list (mk-unit 5201 'disruptor 1 76.0 80.0 #:hp 100.0 #:hp-max 100.0 #:shield 100.0 #:shield-max 100.0))
                       (for/list ([i (in-range 6)])
                         (mk-unit (+ 8200 i) 'marine 4 84.0 (+ 79.0 (* 0.4 i)) #:hp 45.0 #:hp-max 45.0)))
               #:food-used 36 #:food-cap 56 #:food-army 3 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Protoss 'Terran
                                         (list (hash 'obs (mk-dis 12000))
                                               (hash 'obs (mk-dis 12060)))))
     (define w1 (step-outcome-wire-cmds (first outs)))
     (define w2 (step-outcome-wire-cmds (second outs)))
     (define s1-nova? (wire-has-ability? w1 '(5201) AB-PURIFICATION-NOVA))
     (define s2-nova? (wire-has-ability? w2 '(5201) AB-PURIFICATION-NOVA))
     (define s2-move? (wire-has-ability? w2 '(5201) AB-MOVE))
     (values (second outs)
             (list
              (mk-check "disruptor-fires-nova-step1" s1-nova?
                        (format "Step 1 Purification Nova (2346): ~a" s1-nova?))
              (mk-check "disruptor-kites-on-cooldown-step2" (and (not s2-nova?) s2-move?)
                        (format "Step 2 (+60f): Nova=~a MOVE=~a (abs=~a)"
                                s2-nova? s2-move? (wire-abilities-for-tag w2 5201)))
              (mk-check "zero-wire-rejects"
                        (and (= (step-outcome-wire-rejects (first outs)) 0)
                             (= (step-outcome-wire-rejects (second outs)) 0))
                        "wire_rejects=0"))))))

;; 87. Protoss Adept 2-Step Psionic Transfer Cooldown Discipline (shades step 1, attacks step 2)
(define scen-novel-87
  (tactical-scenario
   "novel-87-protoss-adept-shade-2step-cooldown-engages"
   "novel" "Protoss" "Zerg" "harass-micro"
   "2-step Adepts emit Psionic Transfer (2544) on step 1, then engage with ATTACK (23) on step 2 (+20f) without spamming 2544 on cooldown."
   (lambda ()
     (define (mk-ad fr)
       (mk-obs fr
               (append (mk-home-base-units 'Protoss #:with-natural? #t)
                       (list (mk-unit 5301 'adept 1 78.0 80.0 #:hp 70.0 #:hp-max 70.0 #:shield 70.0 #:shield-max 70.0)
                             (mk-unit 5302 'adept 1 78.0 81.0 #:hp 70.0 #:hp-max 70.0 #:shield 70.0 #:shield-max 70.0))
                       (for/list ([i (in-range 6)])
                         (mk-unit (+ 8300 i) 'zergling 4 83.0 (+ 79.0 (* 0.4 i)) #:hp 35.0 #:hp-max 35.0)))
               #:food-used 36 #:food-cap 56 #:food-army 4 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Protoss 'Zerg
                                         (list (hash 'obs (mk-ad 6000))
                                               (hash 'obs (mk-ad 6020)))))
     (define w1 (step-outcome-wire-cmds (first outs)))
     (define w2 (step-outcome-wire-cmds (second outs)))
     (define s1-shade? (wire-has-ability? w1 '(5301 5302) AB-ADEPT-SHADE))
     (define s2-shade? (wire-has-ability? w2 '(5301 5302) AB-ADEPT-SHADE))
     (define s2-atk?   (wire-has-ability? w2 '(5301 5302) AB-ATTACK))
     (values (second outs)
             (list
              (mk-check "adepts-emit-shade-step1" s1-shade?
                        (format "Step 1 Adept Shade (2544): ~a" s1-shade?))
              (mk-check "adepts-attack-on-shade-cooldown-step2" (and (not s2-shade?) s2-atk?)
                        (format "Step 2 (+20f): Shade=~a ATTACK=~a" s2-shade? s2-atk?))
              (mk-check "zero-wire-rejects"
                        (and (= (step-outcome-wire-rejects (first outs)) 0)
                             (= (step-outcome-wire-rejects (second outs)) 0))
                        "wire_rejects=0"))))))

;; 88. Protoss Stalker Stutter-Step Cadence (fires at low w-cd=5, kites at high w-cd=14)
(define scen-novel-88
  (tactical-scenario
   "novel-88-protoss-stalker-stutter-cadence-fires-low-cd-kites-high-cd"
   "novel" "Protoss" "Zerg" "stutter-step-and-pullback"
   "5 Stalkers vs 18 Zerglings at 5.5t: all 5/5 shoot (ATTACK 23) at low weapon-cooldown (5.0), and all 5/5 kite (MOVE 16) at high weapon-cooldown (14.0)."
   (lambda ()
     (define st-tags '(5500 5501 5502 5503 5504))
     (define ling-tags (for/list ([i (in-range 18)]) (+ 8500 i)))
     (define (mk-st wcd)
       (mk-obs 7200
               (append (mk-home-base-units 'Protoss #:with-natural? #t)
                       (for/list ([t (in-list st-tags)] [i (in-naturals)])
                         (mk-unit t 'stalker 1 76.0 (+ 78.5 (* 0.7 i))
                                  #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0 #:weapon-cooldown wcd))
                       (for/list ([t (in-list ling-tags)] [i (in-naturals)])
                         (mk-unit t 'zergling 4 81.5 (+ 77.5 (* 0.3 i)) #:hp 35.0 #:hp-max 35.0)))
               #:food-used 34 #:food-cap 56 #:food-army 10 #:food-workers 24))
     (define out-lo (last (run-pipeline-sequence 'Protoss 'Zerg (list (hash 'obs (mk-st 5.0))))))
     (define out-hi (last (run-pipeline-sequence 'Protoss 'Zerg (list (hash 'obs (mk-st 14.0))))))
     (define lo-atk (wire-count-local-attacks (step-outcome-wire-cmds out-lo) st-tags ling-tags 81.5 80.0 16.0))
     (define hi-mov (for/sum ([t (in-list st-tags)]) (if (wire-pure-move-only? (step-outcome-wire-cmds out-hi) t) 1 0)))
     (values out-lo
             (list
              (mk-check "stalkers-shoot-at-low-weapon-cooldown-5" (>= lo-atk 4)
                        (format "Stalkers w-cd=5.0 local-ATK=~a/5 (expected >=4)" lo-atk))
              (mk-check "stalkers-kite-at-high-weapon-cooldown-14" (>= hi-mov 4)
                        (format "Stalkers w-cd=14.0 pure-MOVE kite=~a/5 (expected >=4)" hi-mov))
              (mk-check "zero-wire-rejects"
                        (and (= (step-outcome-wire-rejects out-lo) 0) (= (step-outcome-wire-rejects out-hi) 0))
                        "wire_rejects=0"))))))

;; 89. Protoss Zealot+Stalker Mixed Engage on Mid-Cooldown vs Terran Bio
(define scen-novel-89
  (tactical-scenario
   "novel-89-protoss-zealot-stalker-mixed-engage-on-mid-cooldown"
   "novel" "Protoss" "Terran" "melee-engage"
   "4 Zealots + 4 Stalkers vs 12 Marines + 3 Marauders at 4.5t (w-cd=8.0): both Zealots and Stalkers commit ATTACK (23) rather than breaking cohesion."
   (lambda ()
     (define z-tags '(5600 5601 5602 5603))
     (define s-tags '(5610 5611 5612 5613))
     (define e-tags (append (for/list ([i (in-range 12)]) (+ 8600 i)) '(8620 8621 8622)))
     (define s1
       (mk-obs 8000
               (append (mk-home-base-units 'Protoss #:with-natural? #t)
                       (for/list ([t (in-list z-tags)] [i (in-naturals)])
                         (mk-unit t 'zealot 1 79.5 (+ 78.5 (* 0.7 i)) #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0 #:weapon-cooldown 8.0))
                       (for/list ([t (in-list s-tags)] [i (in-naturals)])
                         (mk-unit t 'stalker 1 77.0 (+ 78.5 (* 0.7 i)) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0 #:weapon-cooldown 8.0))
                       (for/list ([i (in-range 12)])
                         (mk-unit (+ 8600 i) 'marine 4 82.0 (+ 77.5 (* 0.4 i)) #:hp 45.0 #:hp-max 45.0))
                       (for/list ([i (in-range 3)])
                         (mk-unit (+ 8620 i) 'marauder 4 81.5 (+ 79.0 (* 0.7 i)) #:hp 125.0 #:hp-max 125.0)))
               #:food-used 40 #:food-cap 56 #:food-army 16 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Protoss 'Terran (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define z-atk (wire-count-local-attacks wcmds z-tags e-tags 82.0 79.5 16.0))
     (define s-atk (wire-count-local-attacks wcmds s-tags e-tags 82.0 79.5 16.0))
     (values out
             (list
              (mk-check "zealots-and-stalkers-engage-bio"
                        (and (= z-atk 4) (>= s-atk 3))
                        (format "Zealots ATK=~a/4, Stalkers ATK=~a/4" z-atk s-atk))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; 90. Terran Sieged Tank Line + Ready Marines Hold Front vs Lings+Roaches
(define scen-novel-90
  (tactical-scenario
   "novel-90-terran-sieged-tank-line-marines-hold-front-vs-lings-roaches"
   "novel" "Terran" "Zerg" "choke-defense"
   "2 Sieged Tanks + 8 ready Marines (6.5t from 12 Zerglings + 8 Roaches): both Tanks and all 8/8 Marines fire locally without abandoning the tank line."
   (lambda ()
     (define m-tags (for/list ([i (in-range 8)]) (+ 5310 i)))
     (define t-tags '(5301 5302))
     (define e-tags (append (for/list ([i (in-range 12)]) (+ 8310 i))
                            (for/list ([i (in-range 8)]) (+ 8330 i))))
     (define s1
       (mk-obs 12000
               (append (mk-home-base-units 'Terran #:with-natural? #t)
                       (list (mk-unit 5301 'siege-tank-sieged 1 74.5 80.0 #:hp 175.0 #:hp-max 175.0)
                             (mk-unit 5302 'siege-tank-sieged 1 74.5 81.5 #:hp 175.0 #:hp-max 175.0))
                       (for/list ([t (in-list m-tags)] [i (in-naturals)])
                         (mk-unit t 'marine 1 76.5 (+ 78.0 (* 0.5 i)) #:hp 45.0 #:hp-max 45.0 #:weapon-cooldown 0.0))
                       (for/list ([i (in-range 12)])
                         (mk-unit (+ 8310 i) 'zergling 4 83.0 (+ 77.5 (* 0.4 i)) #:hp 35.0 #:hp-max 35.0))
                       (for/list ([i (in-range 8)])
                         (mk-unit (+ 8330 i) 'roach 4 84.5 (+ 78.0 (* 0.5 i)) #:hp 145.0 #:hp-max 145.0)))
               #:food-used 44 #:food-cap 66 #:food-army 14 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define m-atk (wire-count-local-attacks wcmds m-tags e-tags 83.5 79.5 16.0))
     (define t-atk (wire-count-local-attacks wcmds t-tags e-tags 83.5 79.5 16.0))
     (values out
             (list
              (mk-check "tank-line-and-marines-all-fire"
                        (and (= t-atk 2) (>= m-atk 7))
                        (format "Sieged Tanks ATK=~a/2, Marines ATK=~a/8" t-atk m-atk))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; =============================================================================
;; Round-10 Verified Real-SC2 & Live-Pipeline Bug Reproductions (wave10-repro: w10-tac-1..5)
;; =============================================================================

;; 147. W10-TAC-1 (from real-SC2 t01 `2116` spammed 45x, starving `386` Heal 25->7!):
;;      `lib/tactics/pro-spellcaster-micro.rkt:3158-3170` checks `(dyn-hash-ref u 'boost-ready? #t)`
;;      (never set by live SC2 protobuf!) with ZERO per-unit cooldown tracking in `spell-claims` ->
;;      a damaged Medivac spams `MEDIVAC_BOOST (2116)` EVERY frame for 14.3s (320f), completely
;;      starving `HEAL (386)` and low-HP retreat!
(define scen-w10-tac-1
  (tactical-scenario
   "w10-tac-1-medivac-boost-cooldown-does-not-starve-heal"
   "wave10-repro" "Terran" "Protoss" "spellcasters"
   "Wave-10 Repro (W10-TAC-1 / t01 45x Boost spam): damaged Medivac emits Medivac Boost (2116) on step 1, then must NOT re-spam 2116 on step 2 (+16f, 320f cd) so Heal (386) or retreat fires"
   (lambda ()
     (define (mk-med fr)
       (mk-obs fr
               (append (mk-home-base-units 'Terran #:with-natural? #t)
                       (list (mk-unit 5001 'medivac 1 76.0 80.0 #:hp 60.0 #:hp-max 150.0 #:energy 100.0 #:flying? #t)
                             (mk-unit 5002 'marine  1 78.0 80.0 #:hp 20.0 #:hp-max 45.0)
                             (mk-unit 5003 'marine  1 78.0 81.0 #:hp 45.0 #:hp-max 45.0)
                             (mk-unit 8001 'stalker 4 84.0 80.0 #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0)))
               #:food-used 36 #:food-cap 66 #:food-army 4 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Terran 'Protoss
                                         (list (hash 'obs (mk-med 10000))
                                               (hash 'obs (mk-med 10016)))))
     (define w1 (step-outcome-wire-cmds (first outs)))
     (define w2 (step-outcome-wire-cmds (second outs)))
     (define s1-boost? (wire-has-ability? w1 '(5001) AB-MEDIVAC-BOOST))
     (define s2-boost? (wire-has-ability? w2 '(5001) AB-MEDIVAC-BOOST))
     (define s2-heal-or-move? (or (wire-has-ability? w2 '(5001) AB-HEAL)
                                  (wire-has-ability? w2 '(5001) AB-MOVE)))
     (values (second outs)
             (list
              (mk-check "medivac-boosts-step1" s1-boost?
                        (format "Step 1 Medivac Boost (2116): ~a" s1-boost?))
              (mk-check "medivac-no-boost-spam-on-cooldown-step2"
                        (and (not s2-boost?) s2-heal-or-move?)
                        (format "Step 2 (+16f inside 320f cd): Boost(2116)=~a (expected #f), Heal/Move=~a (abs=~a)"
                                s2-boost? s2-heal-or-move? (wire-abilities-for-tag w2 5001)))
              (mk-check "zero-wire-rejects"
                        (and (= (step-outcome-wire-rejects (first outs)) 0)
                             (= (step-outcome-wire-rejects (second outs)) 0))
                        "wire_rejects=0"))))))

;; 148. W10-TAC-2 (pro-spellcaster-micro.rkt:3108, 3200 missing live cooldown trackers):
;;      Cyclone `LOCK_ON (2350)` (196f cd) and Battlecruiser `TACTICAL_JUMP (2358)` (1590f cd)
;;      have ZERO per-unit cooldown tracking in `spell-claims` -> both re-spam on step 2 (+20f),
;;      starving Battlecruiser Yamato Cannon (401) & Cyclone kite/attack!
(define scen-w10-tac-2
  (tactical-scenario
   "w10-tac-2-cyclone-lock-on-and-bc-jump-respect-cooldowns"
   "wave10-repro" "Terran" "Zerg" "spellcasters"
   "Wave-10 Repro (W10-TAC-2): Cyclone Lock-On (2350, 196f cd) and BC Tactical Jump (2358, 1590f cd) must track per-unit cooldowns so step 2 (+20f) does not re-spam and starve Yamato/attack"
   (lambda ()
     ;; Part A: Cyclone Lock-On 2-step (+20f inside 196f cd)
     (define (mk-cyc fr)
       (mk-obs fr
               (append (mk-home-base-units 'Terran #:with-natural? #t)
                       (list (mk-unit 5201 'cyclone 1 78.0 80.0 #:hp 120.0 #:hp-max 120.0)
                             (mk-unit 8201 'immortal 4 84.0 80.0 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0)))
               #:food-used 36 #:food-cap 66 #:food-army 3 #:food-workers 24))
     (define cyc-outs (run-pipeline-sequence 'Terran 'Protoss
                                             (list (hash 'obs (mk-cyc 10000))
                                                   (hash 'obs (mk-cyc 10020)))))
     (define cyc-s1? (wire-has-ability? (step-outcome-wire-cmds (first cyc-outs)) '(5201) AB-LOCK-ON))
     (define cyc-s2? (wire-has-ability? (step-outcome-wire-cmds (second cyc-outs)) '(5201) AB-LOCK-ON))
     ;; Part B: Low-HP BC Tactical Jump 2-step (+20f inside 1590f cd -> should fire Yamato 401 instead!)
     (define (mk-bc fr)
       (mk-obs fr
               (append (mk-home-base-units 'Terran #:with-natural? #t)
                       (list (mk-unit 5251 'battlecruiser 1 80.0 80.0 #:hp 95.0 #:hp-max 550.0 #:flying? #t)
                             (mk-unit 8251 'corruptor 4 85.0 80.0 #:hp 200.0 #:hp-max 200.0 #:flying? #t)
                             (mk-unit 8252 'corruptor 4 85.0 81.0 #:hp 200.0 #:hp-max 200.0 #:flying? #t)))
               #:upgrades '(weapon-refit) #:food-used 40 #:food-cap 66 #:food-army 6 #:food-workers 24))
     (define bc-outs (run-pipeline-sequence 'Terran 'Zerg
                                            (list (hash 'obs (mk-bc 15000))
                                                  (hash 'obs (mk-bc 15020)))))
     (define bc-s1-jump? (wire-has-ability? (step-outcome-wire-cmds (first bc-outs)) '(5251) AB-TACTICAL-JUMP))
     (define bc-s2-jump? (wire-has-ability? (step-outcome-wire-cmds (second bc-outs)) '(5251) AB-TACTICAL-JUMP))
     (values (second bc-outs)
             (list
              (mk-check "cyclone-locks-step1-not-spam-step2"
                        (and cyc-s1? (not cyc-s2?))
                        (format "Cyclone Lock-On (2350): step1=~a step2(+20f)=~a (expected #t / #f)" cyc-s1? cyc-s2?))
              (mk-check "bc-jumps-step1-not-spam-step2"
                        (and bc-s1-jump? (not bc-s2-jump?))
                        (format "BC Tactical Jump (2358): step1=~a step2(+20f)=~a (expected #t / #f; step2 abs=~a)"
                                bc-s1-jump? bc-s2-jump? (wire-abilities-for-tag (step-outcome-wire-cmds (second bc-outs)) 5251)))
              (mk-check "zero-wire-rejects"
                        (and (= (step-outcome-wire-rejects (second cyc-outs)) 0)
                             (= (step-outcome-wire-rejects (second bc-outs)) 0))
                        "wire_rejects=0"))))))

;; 149. W10-TAC-3 (from real-SC2 t04 `3669` spammed 15x — `lib/sc2-protobuf-ws.rkt:13042-13048`!):
;;      Loaded Medivac inside an AoE danger zone (Psi Storm / Fungal) executes `'transport-drop-point`
;;      -> `(transport-juggle tr-id sx sy)` -> `sc2-protobuf-ws.rkt:13048` emits HARDCODED generic
;;      `3669 (UNLOAD_ALL_AT)` instead of Medivac-specific `396` (`MEDIVAC_UNLOAD_ALL_AT`), which
;;      SC2 4.10.0 ignores/rejects, trapping passengers inside the Medivac for the entire fight!
(define scen-w10-tac-3
  (tactical-scenario
   "w10-tac-3-medivac-offset-drop-emits-396-not-generic-3669"
   "wave10-repro" "Terran" "Zerg" "support-preservation"
   "Wave-10 Repro (W10-TAC-3 / t04 15x 3669 spam): loaded Medivac executing offset drop (transport-juggle) out of AoE must emit Medivac-specific 396 (MEDIVAC_UNLOAD_ALL_AT), NOT generic 3669"
   (lambda ()
     (define pax (list (pb-encode-passenger 5199 51 80.0 125.0)))
     (define pbu
       (list (pb-encode-unit 1 18 1 1 32.0 32.0 #:hp 1500.0 #:hp-max 1500.0)
             (pb-encode-unit 2 18 1 1 52.0 34.0 #:hp 1500.0 #:hp-max 1500.0)
             (pb-encode-unit 10 45 1 1 28.0 31.0 #:hp 45.0 #:hp-max 45.0)
             (pb-encode-unit 90001 341 3 16 25.0 31.0 #:hp 1500.0 #:hp-max 1500.0)
             (pb-encode-unit 5101 54 1 1 82.0 80.0 #:hp 30.0 #:hp-max 150.0 #:energy 100.0 #:flying? #t
                             #:passengers pax #:cargo-taken 2 #:cargo-max 8)
             (pb-encode-unit 5102 48 1 1 78.0 80.0 #:hp 45.0 #:hp-max 45.0)
             (pb-encode-unit 8101 107 4 2 84.0 80.0 #:hp 90.0 #:hp-max 90.0)))
     (define raw-o1 (sc2-response-observation (decode-sc2-response (pb-encode-response-obs 13800 pbu))))
     (define storm-eff (sc2-effect 1 (list (sc2-point2d 82.0 80.0)) 4 2 1.5))
     (define o1 (struct-copy sc2-observation raw-o1 [effects (list storm-eff)]))
     (define out (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs o1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define has-396?  (wire-has-ability? wcmds '(5101) AB-MEDIVAC-UNLOAD-ALL-AT))
     (define has-3669? (wire-has-ability? wcmds '(5101) AB-UNLOAD-ALL-AT))
     (values out
             (list
              (mk-check "medivac-offset-drop-uses-396-not-3669"
                        (and has-396? (not has-3669?))
                        (format "Medivac 5101 offset drop: 396(medivac-unload-all-at)=~a, 3669(generic)=~a (expected #t / #f; abs=~a)"
                                has-396? has-3669? (wire-abilities-for-tag wcmds 5101)))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; 150. W10-TAC-4 (from real-SC2 t02 0.59x Loss — Sieged Tanks targeting Zerglings inside 2.0t deadzone!):
;;      `arena-minimax.rkt` runs before `unit-mode-micro.rkt:2786` (`plan-siege-tank-targets/list`) and
;;      never checks `siege-tank-sieged`'s 2.0-tile minimum range deadzone -> orders BOTH Sieged Tanks
;;      to target Zerglings at 1.20t (`8311`, `8315`), freezing Tanks at 0 DPS while 8 Armored Roaches
;;      sit cleanly at 7.0t inside [2.0 .. 13.0] range!
(define scen-w10-tac-4
  (tactical-scenario
   "w10-tac-4-sieged-tank-never-targets-enemies-inside-2t-min-range"
   "wave10-repro" "Terran" "Zerg" "focus-fire"
   "Wave-10 Repro (W10-TAC-4 / t02): Sieged Tanks with Zerglings at 1.2t (<2.0t deadzone) and 8 Armored Roaches at 7.0t must target the Roaches in [2.0..13.0], NEVER the untargetable 1.2t Zerglings"
   (lambda ()
     (define deadzone-lings (for/list ([i (in-range 6)]) (+ 8310 i)))
     (define valid-roaches  (for/list ([i (in-range 8)]) (+ 8330 i)))
     (define allies
       (append (mk-home-base-units 'Terran #:with-natural? #t)
               (list (mk-unit 5301 'siege-tank-sieged 1 74.5 80.0 #:hp 140.0 #:hp-max 175.0)
                     (mk-unit 5302 'siege-tank-sieged 1 74.5 81.5 #:hp 140.0 #:hp-max 175.0))
               (for/list ([i (in-range 6)])
                 (mk-unit (+ 5310 i) 'marine 1 73.0 (+ 79.0 (* 0.5 i)) #:hp 45.0 #:hp-max 45.0 #:weapon-cooldown 0.0))))
     (define enemies
       (append (for/list ([t (in-list deadzone-lings)] [i (in-naturals)])
                 (mk-unit t 'zergling 4 75.7 (+ 79.5 (* 0.4 i)) #:hp 35.0 #:hp-max 35.0))
               (for/list ([t (in-list valid-roaches)] [i (in-naturals)])
                 (mk-unit t 'roach 4 81.5 (+ 78.0 (* 0.5 i)) #:hp 145.0 #:hp-max 145.0))))
     (define s1 (mk-obs 12040 (append allies enemies)
                        #:food-used 42 #:food-cap 66 #:food-army 12 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define (tank-target-tag tid)
       (for/first ([c (in-list (wire-cmds-for-tag wcmds tid))]
                   #:when (= (sc2-raw-unit-command-ability-id c) AB-ATTACK))
         (sc2-raw-unit-command-target-unit-tag c)))
     (define t1-tgt (tank-target-tag 5301))
     (define t2-tgt (tank-target-tag 5302))
     (define t1-bad? (and t1-tgt (not (not (memv t1-tgt deadzone-lings)))))
     (define t2-bad? (and t2-tgt (not (not (memv t2-tgt deadzone-lings)))))
     (define t1-roach? (and t1-tgt (not (not (memv t1-tgt valid-roaches)))))
     (define t2-roach? (and t2-tgt (not (not (memv t2-tgt valid-roaches)))))
     (values out
             (list
              (mk-check "sieged-tanks-never-target-1.2t-deadzone-lings"
                        (and (not t1-bad?) (not t2-bad?))
                        (format "Sieged Tank targets: 5301->~a 5302->~a (deadzone <2t lings=~a)"
                                t1-tgt t2-tgt deadzone-lings))
              (mk-check "sieged-tanks-shell-7t-armored-roaches"
                        (and t1-roach? t2-roach?)
                        (format "Sieged Tanks targeting Roaches (8330..8337): 5301->~a 5302->~a" t1-tgt t2-tgt))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; 151. W10-TAC-5 (pro-spellcaster-micro.rkt:2583-2595 missing Caustic Spray 1008f cooldown):
;;      Corruptor emits `CAUSTIC_SPRAY (2324)` on step 1 (14000f) and re-emits `2324` on step 2
;;      (14020f, inside its 45s / 1008f cooldown!), resetting/spamming Caustic Spray!
(define scen-w10-tac-5
  (tactical-scenario
   "w10-tac-5-corruptor-caustic-spray-respects-cooldown"
   "wave10-repro" "Zerg" "Protoss" "spellcasters"
   "Wave-10 Repro (W10-TAC-5): Corruptor casting Caustic Spray (2324, 1008f cd) on step 1 must NOT re-emit 2324 on step 2 (+20f) during cooldown"
   (lambda ()
     (define (mk-cor fr)
       (mk-obs fr
               (append (mk-home-base-units 'Zerg #:with-natural? #t)
                       (list (mk-unit 5401 'corruptor 1 155.0 158.0 #:hp 200.0 #:hp-max 200.0 #:flying? #t)
                             (mk-unit 8401 'nexus 4 160.0 160.0 #:hp 1000.0 #:hp-max 1000.0 #:shield 1000.0 #:shield-max 1000.0)))
               #:food-used 36 #:food-cap 56 #:food-army 2 #:food-workers 24))
     (define outs (run-pipeline-sequence 'Zerg 'Protoss
                                         (list (hash 'obs (mk-cor 14000))
                                               (hash 'obs (mk-cor 14020)))))
     (define s1-cs? (wire-has-ability? (step-outcome-wire-cmds (first outs)) '(5401) AB-CAUSTIC-SPRAY))
     (define s2-cs? (wire-has-ability? (step-outcome-wire-cmds (second outs)) '(5401) AB-CAUSTIC-SPRAY))
     (values (second outs)
             (list
              (mk-check "corruptor-casts-caustic-spray-step1" s1-cs?
                        (format "Step 1 Caustic Spray (2324): ~a" s1-cs?))
              (mk-check "corruptor-no-caustic-spray-spam-step2" (not s2-cs?)
                        (format "Step 2 (+20f inside 1008f cd): Caustic Spray (2324)=~a (expected #f)" s2-cs?))
              (mk-check "zero-wire-rejects"
                        (and (= (step-outcome-wire-rejects (first outs)) 0)
                             (= (step-outcome-wire-rejects (second outs)) 0))
                        "wire_rejects=0"))))))

;; 152. W10-TAC-6 (W10-P0-1 / #54 P v who 250/5,925 despite Observer:2 — sc2-protobuf-ws.rkt:12327!):
;;      When cloaked Dark Templars attack our main at (30,32), tactics orders Observer 5001 to MOVE
;;      toward the DTs (44.4, 32.04) — then on the VERY NEXT wire command of the same step,
;;      `cast-deception-and-scout-spells` (`sc2-protobuf-ws.rkt:12327`) checks only `(null? (sc2-unit-orders u))`
;;      and OVERWRITES Observer 5001 with MOVE (160, 160) to enemy main!
(define scen-w10-tac-6
  (tactical-scenario
   "w10-tac-6-observer-never-overwritten-to-enemy-main-during-cloaked-dt-attack"
   "wave10-repro" "Protoss" "Protoss" "detection"
   "Wave-10 Repro (W10-TAC-6 / #54 P v who): Observer defending cloaked Dark Templars in our main must NOT be overwritten to MOVE (160,160) by cast-deception-and-scout-spells"
   (lambda ()
     (define allies
       (append (mk-home-base-units 'Protoss #:with-natural? #t)
               (list (mk-unit 5001 'observer 1 52.0 34.0 #:hp 40.0 #:hp-max 40.0 #:shield 20.0 #:shield-max 20.0 #:flying? #t)
                     (mk-unit 5002 'sentry   1 46.0 32.0 #:hp 40.0 #:hp-max 40.0 #:shield 40.0 #:shield-max 40.0 #:energy 100.0))
               (for/list ([i (in-range 4)])
                 (mk-unit (+ 5010 i) 'stalker 1 44.0 (+ 31.0 (* 0.7 i)) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))))
     (define enemies
       (list (mk-unit 8001 'dark-templar 4 30.0 32.0 #:hp 40.0 #:hp-max 40.0 #:shield 80.0 #:shield-max 80.0 #:cloak 1)
             (mk-unit 8002 'dark-templar 4 31.0 33.0 #:hp 40.0 #:hp-max 40.0 #:shield 80.0 #:shield-max 80.0 #:cloak 1)))
     (define s1 (mk-obs 10000 (append allies enemies)
                        #:food-used 40 #:food-cap 56 #:food-army 10 #:food-workers 24))
     (define out (last (run-pipeline-sequence 'Protoss 'Protoss (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define obs-cmds (wire-cmds-for-tag wcmds 5001))
     (define sent-to-enemy-main?
       (for/or ([c (in-list obs-cmds)])
         (and (= (sc2-raw-unit-command-ability-id c) AB-MOVE)
              (sc2-point2d? (sc2-raw-unit-command-target-pos c))
              (> (dist2d-xy 32.0 32.0
                            (sc2-point2d-x (sc2-raw-unit-command-target-pos c))
                            (sc2-point2d-y (sc2-raw-unit-command-target-pos c)))
                 80.0))))
     (values out
             (list
              (mk-check "observer-stays-home-not-overwritten-to-enemy-main"
                        (and (pair? obs-cmds) (not sent-to-enemy-main?))
                        (format "Observer 5001 cmds during cloaked DT attack in main: ~a (sent >80t away=~a, expected #f)"
                                (map wire-cmd->summary obs-cmds) sent-to-enemy-main?))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; 153. W10-TAC-7 (W10-P0-1 / #53 T v who 200/5,700):
;;      With 2 Orbital Commands (55 energy each) and cloaked Dark Templars attacking our main,
;;      OC #1 scans (399) while OC #2 (55en) immediately burns its last 50 energy on Calldown MULE (171),
;;      leaving ZERO scan energy when Scan #1 expires! Must reserve 50 energy (>=100en for MULE) under cloaked threat.
(define scen-w10-tac-7
  (tactical-scenario
   "w10-tac-7-orbital-command-reserves-scan-energy-not-mule-under-cloaked-threat"
   "wave10-repro" "Terran" "Protoss" "detection"
   "Wave-10 Repro (W10-TAC-7 / #53 T v who): 55-energy Orbital Command must reserve 50 energy for Scanner Sweep (no MULE 171 below 100en) while cloaked Dark Templars are in our base"
   (lambda ()
     (define allies
       (append
        (list (mk-unit 1001 'orbital-command 1 32.0 32.0 #:hp 1500.0 #:hp-max 1500.0 #:energy 55.0)
              (mk-unit 1002 'orbital-command 1 52.0 32.0 #:hp 1500.0 #:hp-max 1500.0 #:energy 55.0))
        (for/list ([i (in-range 12)])
          (mk-unit (+ 1100 i) 'scv 1 (+ 27.0 (* 0.4 (modulo i 4))) (+ 30.0 (* 0.4 (quotient i 4)))
                   #:orders (list (sc2-unit-order AB-GATHER #f 90001 0.0))))
        (for/list ([i (in-range 6)])
          (mk-unit (+ 5100 i) 'marine 1 36.0 (+ 31.0 (* 0.5 i)) #:hp 45.0 #:hp-max 45.0))))
     (define enemies
       (list (mk-unit 8101 'dark-templar 4 30.0 32.0 #:hp 40.0 #:hp-max 40.0 #:shield 80.0 #:shield-max 80.0 #:cloak 1)
             (mk-unit 8102 'dark-templar 4 31.0 33.0 #:hp 40.0 #:hp-max 40.0 #:shield 80.0 #:shield-max 80.0 #:cloak 1)))
     (define s1 (mk-obs 10000 (append allies enemies)
                        #:food-used 36 #:food-cap 56 #:food-army 6 #:food-workers 12))
     (define out (last (run-pipeline-sequence 'Terran 'Protoss (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define scanned? (wire-has-ability? wcmds '(1001 1002) AB-SCANNER-SWEEP))
     (define muled?   (wire-has-ability? wcmds '(1001 1002) AB-CALLDOWN-MULE))
     (values out
             (list
              (mk-check "oc-scans-cloaked-dt" scanned?
                        (format "OCs emitted Scanner Sweep (399): ~a" scanned?))
              (mk-check "low-energy-oc-reserves-50en-not-mule-under-cloaked-threat"
                        (not muled?)
                        (format "55-energy OC burned last 50en on Calldown MULE (171) during cloaked DT attack: ~a (expected #f)" muled?))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))


;; -----------------------------------------------------------------------------
;; Round-11 Pro-Inspired Regression Shields (novel-91..100)
;; -----------------------------------------------------------------------------
(define scen-novel-91
  (tactical-scenario
   "novel-91-ghost-channeling-snipe-protected"
   "novel" "Terran" "Zerg" "spellcaster"
   "Channel protection: Ghost channeling Steady Targeting (2714) is not self-cancelled while allies fight"
   (lambda ()
     (define home (mk-home-base-units 'Terran #:workers 16))
     (define allies
       (append
        home
        (list (mk-unit 5001 'ghost 1 73.0 80.0 #:hp 100.0 #:hp-max 100.0 #:energy 100.0
                       #:orders (list (sc2-unit-order AB-SNIPE #f 8001 0.5))))
        (for/list ([i (in-range 6)])
          (mk-unit (+ 5010 i) 'marine 1 75.5 (+ 77.5 (* i 0.9)) #:hp 45.0 #:hp-max 45.0))))
     (define enemies
       (list (mk-unit 8001 'ultralisk 4 81.0 80.0 #:hp 500.0 #:hp-max 500.0)
             (mk-unit 8002 'zergling 4 80.0 79.0 #:hp 35.0 #:hp-max 35.0)
             (mk-unit 8003 'zergling 4 80.0 81.0 #:hp 35.0 #:hp-max 35.0)))
     (define s1 (mk-obs 12000 (append allies enemies)
                        #:food-used 36 #:food-cap 66 #:food-army 20 #:food-workers 16))
     (define out (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define ghost-cmds (wire-cmds-for-tag wcmds 5001))
     (define marine-atk (wire-count-tags-with-ability wcmds '(5010 5011 5012 5013 5014 5015) AB-ATTACK))
     (values out
             (list
              (mk-check "channeling-ghost-not-interrupted" (null? ghost-cmds)
                        (format "Ghost channeling Snipe (2714) received ~a cmds (expected 0)" (length ghost-cmds)))
              (mk-check "marines-still-engage" (>= marine-atk 4)
                        (format "Marine attackers=~a/6" marine-atk))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

(define scen-novel-92
  (tactical-scenario
   "novel-92-phoenix-channeling-graviton-beam-protected"
   "novel" "Protoss" "Protoss" "spellcaster"
   "Channel protection: Phoenix channeling Graviton Beam (173) is not interrupted while wingman attacks lifted Immortal"
   (lambda ()
     (define home (mk-home-base-units 'Protoss #:workers 16))
     (define allies
       (append
        home
        (list (mk-unit 5101 'phoenix 1 76.0 80.0 #:hp 120.0 #:hp-max 120.0 #:shield 60.0 #:shield-max 60.0 #:energy 75.0
                       #:orders (list (sc2-unit-order AB-GRAVITON-BEAM #f 8101 0.4)))
              (mk-unit 5102 'phoenix 1 76.0 81.5 #:hp 120.0 #:hp-max 120.0 #:shield 60.0 #:shield-max 60.0 #:energy 50.0)
              (mk-unit 5103 'phoenix 1 76.0 78.5 #:hp 120.0 #:hp-max 120.0 #:shield 60.0 #:shield-max 60.0 #:energy 50.0))))
     (define enemies
       (list (mk-unit 8101 'immortal 4 79.0 80.0 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0 #:flying? #t)))
     (define s1 (mk-obs 12100 (append allies enemies)
                        #:food-used 28 #:food-cap 54 #:food-army 12 #:food-workers 16))
     (define out (last (run-pipeline-sequence 'Protoss 'Protoss (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define beam-cmds (wire-cmds-for-tag wcmds 5101))
     (define wing-atk (wire-count-tags-with-ability wcmds '(5102 5103) AB-ATTACK))
     (values out
             (list
              (mk-check "channeling-phoenix-not-interrupted" (null? beam-cmds)
                        (format "Phoenix channeling Graviton Beam (173) received ~a cmds (expected 0)" (length beam-cmds)))
              (mk-check "wingmen-attack-lifted-immortal" (>= wing-atk 1)
                        (format "Wingman Phoenix attackers=~a/2" wing-atk))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

(define scen-novel-93
  (tactical-scenario
   "novel-93-infestor-channeling-neural-protected"
   "novel" "Zerg" "Protoss" "spellcaster"
   "Channel protection: low-energy Infestor channeling Neural Parasite (249) is not self-cancelled by rear-leash"
   (lambda ()
     (define home (mk-home-base-units 'Zerg #:workers 16))
     (define allies
       (append
        home
        (list (mk-unit 5201 'infestor 1 74.0 80.0 #:hp 90.0 #:hp-max 90.0 #:energy 20.0
                       #:orders (list (sc2-unit-order AB-NEURAL-PARASITE #f 8201 0.5))))
        (for/list ([i (in-range 6)])
          (mk-unit (+ 5210 i) 'hydralisk 1 75.5 (+ 77.5 (* i 0.9)) #:hp 90.0 #:hp-max 90.0))))
     (define enemies
       (list (mk-unit 8201 'thor 4 80.5 80.0 #:hp 400.0 #:hp-max 400.0)
             (mk-unit 8202 'marauder 4 79.5 79.0 #:hp 125.0 #:hp-max 125.0)
             (mk-unit 8203 'marauder 4 79.5 81.0 #:hp 125.0 #:hp-max 125.0)))
     (define s1 (mk-obs 12200 (append allies enemies)
                        #:food-used 36 #:food-cap 66 #:food-army 20 #:food-workers 16))
     (define out (last (run-pipeline-sequence 'Zerg 'Terran (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define inf-cmds (wire-cmds-for-tag wcmds 5201))
     (define hydra-atk (wire-count-tags-with-ability wcmds '(5210 5211 5212 5213 5214 5215) AB-ATTACK))
     (values out
             (list
              (mk-check "channeling-infestor-not-interrupted" (null? inf-cmds)
                        (format "Infestor channeling Neural Parasite (249) received ~a cmds (expected 0)" (length inf-cmds)))
              (mk-check "hydras-still-engage" (>= hydra-atk 4)
                        (format "Hydralisk attackers=~a/6" hydra-atk))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

(define scen-novel-94
  (tactical-scenario
   "novel-94-corruptor-caustic-spray-and-viper-consume-protected"
   "novel" "Zerg" "Protoss" "spellcaster"
   "Channel protection: Corruptor channeling Caustic Spray (2324) and Viper channeling Consume (2073) are preserved"
   (lambda ()
     (define home (mk-home-base-units 'Zerg #:workers 16))
     (define allies
       (append
        home
        (list (mk-unit 5301 'corruptor 1 112.0 112.0 #:hp 200.0 #:hp-max 200.0
                       #:orders (list (sc2-unit-order AB-CAUSTIC-SPRAY #f 8301 0.5)))
              (mk-unit 5302 'viper 1 35.0 34.0 #:hp 150.0 #:hp-max 150.0 #:energy 30.0
                       #:orders (list (sc2-unit-order AB-VIPER-CONSUME #f 1001 0.5)))
              (mk-unit 5303 'spawning-pool 1 35.0 35.0 #:hp 1000.0 #:hp-max 1000.0))))
     (define enemies
       (list (mk-unit 8301 'nexus 4 115.0 115.0 #:hp 1000.0 #:hp-max 1000.0 #:shield 1000.0 #:shield-max 1000.0)))
     (define s1 (mk-obs 12300 (append allies enemies)
                        #:food-used 28 #:food-cap 54 #:food-army 12 #:food-workers 16))
     (define out (last (run-pipeline-sequence 'Zerg 'Protoss (list (hash 'obs s1)))))
     (define wcmds (step-outcome-wire-cmds out))
     (define corr-cmds (wire-cmds-for-tag wcmds 5301))
     (define vip-cmds (wire-cmds-for-tag wcmds 5302))
     (values out
             (list
              (mk-check "channeling-corruptor-preserved" (null? corr-cmds)
                        (format "Corruptor channeling Caustic Spray received ~a cmds" (length corr-cmds)))
              (mk-check "channeling-viper-consume-preserved" (null? vip-cmds)
                        (format "Viper channeling Consume received ~a cmds" (length vip-cmds)))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

(define scen-novel-95
  (tactical-scenario
   "novel-95-ht-psi-storm-dedup-active-effect-and-friendly-fire-guard"
   "novel" "Protoss" "Terran" "spellcaster"
   "High Templar Psi Storm discipline: single non-overlapping Storm on step 1, 0 re-cast into active Storm effect, 0 friendly-fire onto meleeing Zealots"
   (lambda ()
     (define home (mk-home-base-units 'Protoss #:workers 16))
     ;; Part A: 2 HTs vs 12 packed Marines (step 1 casts 1 Storm; step 2 with active effect=1 casts 0)
     (define allies-a
       (append
        home
        (list (mk-unit 5501 'high-templar 1 73.5 80.0 #:hp 40.0 #:hp-max 40.0 #:shield 40.0 #:shield-max 40.0 #:energy 150.0)
              (mk-unit 5502 'high-templar 1 73.5 81.5 #:hp 40.0 #:hp-max 40.0 #:shield 40.0 #:shield-max 40.0 #:energy 150.0))
        (for/list ([i (in-range 6)])
          (mk-unit (+ 5510 i) 'stalker 1 75.0 (+ 77.5 (* i 0.9)) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))))
     (define enemies-a
       (for/list ([i (in-range 12)])
         (mk-unit (+ 8501 i) 'marine 4 80.0 (+ 77.5 (* i 0.4)) #:hp 45.0 #:hp-max 45.0)))
     (define outs-a
       (run-pipeline-sequence 'Protoss 'Terran
         (list (hash 'obs (mk-obs 12600 (append allies-a enemies-a) #:upgrades '(psi-storm)
                                  #:food-used 46 #:food-cap 66 #:food-army 30 #:food-workers 16))
               (hash 'obs (mk-obs 12608 (append allies-a enemies-a) #:upgrades '(psi-storm)
                                  #:effects (list (sc2-effect 1 (list (sc2-point2d 80.0 79.7)) 1 1 1.5))
                                  #:food-used 46 #:food-cap 66 #:food-army 30 #:food-workers 16)))))
     (define storm1 (wire-count-tags-with-ability (step-outcome-wire-cmds (first outs-a)) '(5501 5502) AB-PSI-STORM))
     (define storm2 (wire-count-tags-with-ability (step-outcome-wire-cmds (second outs-a)) '(5501 5502) AB-PSI-STORM))
     ;; Part B: HT behind 6 Zealots meleeing 6 Marines must NOT storm own Zealots
     (define allies-b
       (append
        home
        (list (mk-unit 5551 'high-templar 1 74.0 80.0 #:hp 40.0 #:hp-max 40.0 #:shield 40.0 #:shield-max 40.0 #:energy 100.0))
        (for/list ([i (in-range 6)])
          (mk-unit (+ 5560 i) 'zealot 1 79.6 (+ 78.5 (* i 0.5)) #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0))))
     (define enemies-b
       (for/list ([i (in-range 6)])
         (mk-unit (+ 8560 i) 'marine 4 80.1 (+ 78.5 (* i 0.5)) #:hp 45.0 #:hp-max 45.0)))
     (define out-b
       (last (run-pipeline-sequence 'Protoss 'Terran
               (list (hash 'obs (mk-obs 12650 (append allies-b enemies-b) #:upgrades '(psi-storm)
                                        #:food-used 40 #:food-cap 66 #:food-army 24 #:food-workers 16))))))
     (define ff-storm? (wire-has-ability? (step-outcome-wire-cmds out-b) '(5551) AB-PSI-STORM))
     (define total-rej (+ (step-outcome-wire-rejects (first outs-a))
                          (step-outcome-wire-rejects (second outs-a))
                          (step-outcome-wire-rejects out-b)))
     (values (second outs-a)
             (list
              (mk-check "step1-exactly-one-ht-storms-no-double-overlap" (= storm1 1)
                        (format "HTs casting Psi Storm on step 1=~a (expected 1)" storm1))
              (mk-check "step2-zero-storms-into-active-storm-effect" (= storm2 0)
                        (format "HTs casting Psi Storm into active storm=~a (expected 0)" storm2))
              (mk-check "no-friendly-fire-storm-on-meleeing-zealots" (not ff-storm?)
                        (format "HT stormed meleeing Zealots: ~a" ff-storm?))
              (mk-check "zero-wire-rejects" (= total-rej 0)
                        (format "wire_rejects=~a" total-rej)))))))

(define scen-novel-96
  (tactical-scenario
   "novel-96-shield-battery-4.10.0-hygiene-and-colossus-commitment"
   "novel" "Protoss" "Protoss" "splash"
   "SC2 4.10.0 Shield Battery hygiene (0 invalid 4107 Battery Overcharge) + full Stalker/Bio commitment vs 4 Colossi"
   (lambda ()
     (define home (mk-home-base-units 'Protoss #:workers 16 #:with-natural? #t))
     (define allies-p
       (append
        home
        (list (mk-unit 1050 'shield-battery 1 56.0 34.0 #:hp 150.0 #:hp-max 150.0 #:shield 150.0 #:shield-max 150.0 #:energy 100.0))
        (for/list ([i (in-range 8)])
          (mk-unit (+ 5601 i) 'stalker 1 58.0 (+ 31.0 (* i 0.8)) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))))
     (define enemies-p
       (for/list ([i (in-range 4)])
         (mk-unit (+ 8601 i) 'colossus 4 68.0 (+ 32.0 (* i 1.2)) #:hp 200.0 #:hp-max 200.0 #:shield 150.0 #:shield-max 150.0)))
     (define out-p
       (last (run-pipeline-sequence 'Protoss 'Protoss
               (list (hash 'obs (mk-obs 12700 (append allies-p enemies-p)
                                        #:food-used 40 #:food-cap 66 #:food-army 24 #:food-workers 16))))))
     (define wcmds-p (step-outcome-wire-cmds out-p))
     (define bad-4107? (wire-has-ability? wcmds-p '(1001 1002 1050) AB-BATTERY-OVERCHARGE))
     (define stalker-atk (wire-count-tags-with-ability wcmds-p '(5601 5602 5603 5604 5605 5606 5607 5608) AB-ATTACK))
     ;; Part B: 10 Marines + 4 Marauders vs 4 Colossi at 10t
     (define home-t (mk-home-base-units 'Terran #:workers 16))
     (define allies-t
       (append
        home-t
        (for/list ([i (in-range 10)])
          (mk-unit (+ 5621 i) 'marine 1 74.0 (+ 76.0 (* i 0.7)) #:hp 45.0 #:hp-max 45.0))
        (for/list ([i (in-range 4)])
          (mk-unit (+ 5641 i) 'marauder 1 75.5 (+ 78.0 (* i 0.9)) #:hp 125.0 #:hp-max 125.0))))
     (define enemies-t
       (for/list ([i (in-range 4)])
         (mk-unit (+ 8621 i) 'colossus 4 84.0 (+ 78.0 (* i 1.2)) #:hp 200.0 #:hp-max 200.0 #:shield 150.0 #:shield-max 150.0)))
     (define out-t
       (last (run-pipeline-sequence 'Terran 'Protoss
               (list (hash 'obs (mk-obs 12700 (append allies-t enemies-t)
                                        #:food-used 46 #:food-cap 66 #:food-army 30 #:food-workers 16))))))
     (define bio-tags (append (for/list ([i (in-range 10)]) (+ 5621 i))
                              (for/list ([i (in-range 4)]) (+ 5641 i))))
     (define bio-atk (wire-count-tags-with-ability (step-outcome-wire-cmds out-t) bio-tags AB-ATTACK))
     (define total-rej (+ (step-outcome-wire-rejects out-p) (step-outcome-wire-rejects out-t)))
     (values out-p
             (list
              (mk-check "zero-4107-battery-overcharge-on-4.10.0" (not bad-4107?)
                        (format "Emitted invalid 4107 Battery Overcharge: ~a" bad-4107?))
              (mk-check "stalkers-commit-vs-4-colossi" (>= stalker-atk 6)
                        (format "Stalker attackers=~a/8" stalker-atk))
              (mk-check "bio-commits-vs-4-colossi" (>= bio-atk 11)
                        (format "Bio attackers=~a/14" bio-atk))
              (mk-check "zero-wire-rejects" (= total-rej 0)
                        (format "wire_rejects=~a" total-rej)))))))

(define scen-novel-97
  (tactical-scenario
   "novel-97-ht-zero-energy-feedback-and-phoenix-massive-beam-legality"
   "novel" "Protoss" "Terran" "spellcaster"
   "Spell target legality: HT emits 0 Feedback on 0-energy/10-energy casters AND Phoenix emits 0 Graviton Beam on Massive Ultralisks"
   (lambda ()
     (define home (mk-home-base-units 'Protoss #:workers 16))
     (define allies-ht
       (append
        home
        (list (mk-unit 5701 'high-templar 1 74.0 80.0 #:hp 40.0 #:hp-max 40.0 #:shield 40.0 #:shield-max 40.0 #:energy 100.0))
        (for/list ([i (in-range 6)])
          (mk-unit (+ 5710 i) 'stalker 1 75.5 (+ 77.5 (* i 0.9)) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))))
     (define enemies-ht
       (list (mk-unit 8701 'medivac 4 79.0 80.0 #:hp 150.0 #:hp-max 150.0 #:energy 0.0)
             (mk-unit 8702 'raven 4 79.5 81.0 #:hp 140.0 #:hp-max 140.0 #:energy 10.0)
             (mk-unit 8703 'marine 4 80.0 79.0 #:hp 45.0 #:hp-max 45.0)))
     (define out-ht
       (last (run-pipeline-sequence 'Protoss 'Terran
               (list (hash 'obs (mk-obs 12800 (append allies-ht enemies-ht)
                                        #:food-used 40 #:food-cap 66 #:food-army 24 #:food-workers 16))))))
     (define bad-fb? (wire-has-ability? (step-outcome-wire-cmds out-ht) '(5701) AB-FEEDBACK))
     (define allies-phx
       (append
        home
        (list (mk-unit 5721 'phoenix 1 76.0 80.0 #:hp 120.0 #:hp-max 120.0 #:shield 60.0 #:shield-max 60.0 #:energy 100.0)
              (mk-unit 5722 'phoenix 1 76.0 81.5 #:hp 120.0 #:hp-max 120.0 #:shield 60.0 #:shield-max 60.0 #:energy 100.0)
              (mk-unit 5723 'phoenix 1 76.0 78.5 #:hp 120.0 #:hp-max 120.0 #:shield 60.0 #:shield-max 60.0 #:energy 100.0))))
     (define enemies-ultra
       (list (mk-unit 8721 'ultralisk 4 79.0 80.0 #:hp 500.0 #:hp-max 500.0)
             (mk-unit 8722 'ultralisk 4 79.5 81.0 #:hp 500.0 #:hp-max 500.0)))
     (define out-phx
       (last (run-pipeline-sequence 'Protoss 'Zerg
               (list (hash 'obs (mk-obs 12800 (append allies-phx enemies-ultra)
                                        #:food-used 30 #:food-cap 50 #:food-army 14 #:food-workers 16))))))
     (define bad-beam? (wire-has-ability? (step-outcome-wire-cmds out-phx) '(5721 5722 5723) AB-GRAVITON-BEAM))
     (define total-rej (+ (step-outcome-wire-rejects out-ht) (step-outcome-wire-rejects out-phx)))
     (values out-ht
             (list
              (mk-check "no-wasted-feedback-on-low-energy-casters" (not bad-fb?)
                        (format "HT cast Feedback (140) on 0/10-energy casters: ~a" bad-fb?))
              (mk-check "no-invalid-graviton-beam-on-massive-ultralisks" (not bad-beam?)
                        (format "Phoenix cast Graviton Beam (173) on Massive Ultralisks: ~a" bad-beam?))
              (mk-check "zero-wire-rejects" (= total-rej 0)
                        (format "wire_rejects=~a" total-rej)))))))

(define scen-novel-98
  (tactical-scenario
   "novel-98-sentry-guardian-shield-single-cast-and-buff18-dedup"
   "novel" "Protoss" "Terran" "spellcaster"
   "Sentry Guardian Shield deduplication: only 1 of 2 Sentries casts 76 on step 1 and 0 re-cast on step 2 while buff 18 is active"
   (lambda ()
     (define home (mk-home-base-units 'Protoss #:workers 16))
     (define allies1
       (append
        home
        (list (mk-unit 5801 'sentry 1 74.5 80.0 #:hp 40.0 #:hp-max 40.0 #:shield 40.0 #:shield-max 40.0 #:energy 100.0)
              (mk-unit 5802 'sentry 1 74.5 81.2 #:hp 40.0 #:hp-max 40.0 #:shield 40.0 #:shield-max 40.0 #:energy 100.0))
        (for/list ([i (in-range 6)])
          (mk-unit (+ 5810 i) 'stalker 1 76.0 (+ 77.5 (* i 0.9)) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))))
     (define allies2
       (append
        home
        (list (mk-unit 5801 'sentry 1 74.5 80.0 #:hp 40.0 #:hp-max 40.0 #:shield 40.0 #:shield-max 40.0 #:energy 25.0 #:buffs '(18))
              (mk-unit 5802 'sentry 1 74.5 81.2 #:hp 40.0 #:hp-max 40.0 #:shield 40.0 #:shield-max 40.0 #:energy 100.0 #:buffs '(18)))
        (for/list ([i (in-range 6)])
          (mk-unit (+ 5810 i) 'stalker 1 76.0 (+ 77.5 (* i 0.9)) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0 #:buffs '(18)))))
     (define enemies
       (for/list ([i (in-range 10)])
         (mk-unit (+ 8801 i) 'marine 4 81.0 (+ 76.5 (* i 0.8)) #:hp 45.0 #:hp-max 45.0)))
     (define outs
       (run-pipeline-sequence 'Protoss 'Terran
         (list (hash 'obs (mk-obs 12900 (append allies1 enemies) #:food-used 40 #:food-cap 66 #:food-army 24 #:food-workers 16))
               (hash 'obs (mk-obs 12908 (append allies2 enemies) #:food-used 40 #:food-cap 66 #:food-army 24 #:food-workers 16)))))
     (define gs1 (wire-count-tags-with-ability (step-outcome-wire-cmds (first outs)) '(5801 5802) AB-GUARDIAN-SHIELD))
     (define gs2 (wire-count-tags-with-ability (step-outcome-wire-cmds (second outs)) '(5801 5802) AB-GUARDIAN-SHIELD))
     (define total-rej (+ (step-outcome-wire-rejects (first outs)) (step-outcome-wire-rejects (second outs))))
     (values (second outs)
             (list
              (mk-check "step1-exactly-one-sentry-casts-guardian-shield" (= gs1 1)
                        (format "Sentries casting Guardian Shield on step 1=~a (expected 1)" gs1))
              (mk-check "step2-zero-recasts-with-buff-18-active" (= gs2 0)
                        (format "Sentries re-casting Guardian Shield while buff 18 active=~a (expected 0)" gs2))
              (mk-check "zero-wire-rejects" (= total-rej 0)
                        (format "wire_rejects=~a" total-rej)))))))

(define scen-novel-99
  (tactical-scenario
   "novel-99-raven-im-aam-dedup-and-ghost-emp-snipe-legality"
   "novel" "Terran" "Protoss" "spellcaster"
   "Raven IM/AAM deduplication + Ghost spell legality (0 EMP on 0-shield/0-energy Bio, 0 Snipe on Mechanical)"
   (lambda ()
     (define home (mk-home-base-units 'Terran #:workers 16))
     ;; Part A: Two Ravens split IM (3747) + AAM (3753) on step 1, 0 duplicate 3747 on step 2 (8f later)
     (define allies-r
       (append
        home
        (list (mk-unit 5901 'raven 1 74.0 80.0 #:hp 140.0 #:hp-max 140.0 #:energy 150.0)
              (mk-unit 5902 'raven 1 74.0 81.5 #:hp 140.0 #:hp-max 140.0 #:energy 150.0))
        (for/list ([i (in-range 8)])
          (mk-unit (+ 5910 i) 'marine 1 75.5 (+ 77.0 (* i 0.9)) #:hp 45.0 #:hp-max 45.0))))
     (define enemies-r
       (list (mk-unit 8901 'colossus 4 80.0 80.0 #:hp 200.0 #:hp-max 200.0 #:shield 150.0 #:shield-max 150.0)
             (mk-unit 8902 'stalker 4 81.0 80.0 #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0)
             (mk-unit 8903 'stalker 4 81.0 81.5 #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0)))
     (define outs-r
       (run-pipeline-sequence 'Terran 'Protoss
         (list (hash 'obs (mk-obs 13000 (append allies-r enemies-r) #:upgrades '(interference-matrix) #:food-used 46 #:food-cap 66 #:food-army 30 #:food-workers 16))
               (hash 'obs (mk-obs 13008 (append allies-r enemies-r) #:upgrades '(interference-matrix) #:food-used 46 #:food-cap 66 #:food-army 30 #:food-workers 16)))))
     (define im1 (wire-count-tags-with-ability (step-outcome-wire-cmds (first outs-r)) '(5901 5902) AB-INTERFERENCE-MATRIX))
     (define aam1 (wire-count-tags-with-ability (step-outcome-wire-cmds (first outs-r)) '(5901 5902) AB-ANTI-ARMOR-MISSILE))
     (define im2 (wire-count-tags-with-ability (step-outcome-wire-cmds (second outs-r)) '(5901 5902) AB-INTERFERENCE-MATRIX))
     ;; Part B: Ghost vs 0-shield/0-energy Marines (0 EMP) & vs 0-shield Mechanical Immortal/Stalker (0 Snipe)
     (define allies-g
       (append
        home
        (list (mk-unit 5951 'ghost 1 74.0 80.0 #:hp 100.0 #:hp-max 100.0 #:energy 125.0))
        (for/list ([i (in-range 8)])
          (mk-unit (+ 5960 i) 'marine 1 75.5 (+ 77.0 (* i 0.8)) #:hp 45.0 #:hp-max 45.0))))
     (define enemies-bio
       (for/list ([i (in-range 8)])
         (mk-unit (+ 8951 i) 'marine 4 80.0 (+ 77.5 (* i 0.6)) #:hp 45.0 #:hp-max 45.0)))
     (define enemies-mech
       (list (mk-unit 8971 'immortal 4 80.0 80.0 #:hp 200.0 #:hp-max 200.0 #:shield 0.0 #:shield-max 100.0)
             (mk-unit 8972 'stalker 4 80.5 81.0 #:hp 80.0 #:hp-max 80.0 #:shield 0.0 #:shield-max 80.0)))
     (define out-bio (last (run-pipeline-sequence 'Terran 'Terran
                             (list (hash 'obs (mk-obs 13000 (append allies-g enemies-bio) #:food-used 40 #:food-cap 66 #:food-army 24 #:food-workers 16))))))
     (define out-mech (last (run-pipeline-sequence 'Terran 'Protoss
                              (list (hash 'obs (mk-obs 13000 (append allies-g enemies-mech) #:food-used 40 #:food-cap 66 #:food-army 24 #:food-workers 16))))))
     (define bad-emp? (wire-has-ability? (step-outcome-wire-cmds out-bio) '(5951) AB-EMP))
     (define bad-snipe? (wire-has-ability? (step-outcome-wire-cmds out-mech) '(5951) AB-SNIPE))
     (define total-rej (+ (step-outcome-wire-rejects (first outs-r))
                          (step-outcome-wire-rejects (second outs-r))
                          (step-outcome-wire-rejects out-bio)
                          (step-outcome-wire-rejects out-mech)))
     (values (first outs-r)
             (list
              (mk-check "two-ravens-split-im-and-aam-step1" (and (= im1 1) (= aam1 1))
                        (format "Raven step1 IM=~a AAM=~a (expected 1 and 1)" im1 aam1))
              (mk-check "no-duplicate-im-8f-later" (= im2 0)
                        (format "Raven step2 duplicate IM=~a (expected 0)" im2))
              (mk-check "ghost-no-wasted-emp-on-zero-shield-bio" (not bad-emp?)
                        (format "Ghost cast EMP on 0-shield/0-energy Marines: ~a" bad-emp?))
              (mk-check "ghost-no-invalid-snipe-on-mechanical" (not bad-snipe?)
                        (format "Ghost cast Snipe on Mechanical Immortal/Stalker: ~a" bad-snipe?))
              (mk-check "zero-wire-rejects" (= total-rej 0)
                        (format "wire_rejects=~a" total-rej)))))))

(define scen-novel-100
  (tactical-scenario
   "novel-100-ravager-bile-cd-infestor-buff17-oc-scan-and-observer-dispatch"
   "novel" "Zerg" "Terran" "spellcaster"
   "Milestone 100th novel shield: Ravager 157f Bile cooldown, Infestor buff-17 Fungal dedup, OC exact-coord Scan & Observer dispatch"
   (lambda ()
     ;; Part A: 2 Ravagers cast 2338 on step 1 vs Sieged Tanks, then respect cooldown (0 Bile, attack) 8f later
     (define home-z (mk-home-base-units 'Zerg #:workers 16))
     (define allies-rav
       (append
        home-z
        (list (mk-unit 6001 'ravager 1 75.0 80.0 #:hp 120.0 #:hp-max 120.0)
              (mk-unit 6002 'ravager 1 75.0 81.5 #:hp 120.0 #:hp-max 120.0))
        (for/list ([i (in-range 6)])
          (mk-unit (+ 6010 i) 'roach 1 74.0 (+ 77.5 (* i 0.9)) #:hp 145.0 #:hp-max 145.0))))
     (define enemies-tank
       (list (mk-unit 9001 'siege-tank-sieged 4 82.0 80.0 #:hp 175.0 #:hp-max 175.0)
             (mk-unit 9002 'siege-tank-sieged 4 82.0 82.0 #:hp 175.0 #:hp-max 175.0)))
     (define outs-rav
       (run-pipeline-sequence 'Zerg 'Terran
         (list (hash 'obs (mk-obs 13100 (append allies-rav enemies-tank) #:food-used 46 #:food-cap 66 #:food-army 30 #:food-workers 16))
               (hash 'obs (mk-obs 13108 (append allies-rav enemies-tank) #:food-used 46 #:food-cap 66 #:food-army 30 #:food-workers 16)))))
     (define bile1 (wire-count-tags-with-ability (step-outcome-wire-cmds (first outs-rav)) '(6001 6002) AB-CORROSIVE-BILE))
     (define bile2 (wire-count-tags-with-ability (step-outcome-wire-cmds (second outs-rav)) '(6001 6002) AB-CORROSIVE-BILE))
     ;; Part B: 2 Infestors split Fungal on step 1, then 0 re-casts on step 2 when enemies carry buff 17 (fungal-growth)
     (define allies-inf
       (append
        home-z
        (list (mk-unit 6021 'infestor 1 73.5 80.0 #:hp 90.0 #:hp-max 90.0 #:energy 150.0)
              (mk-unit 6022 'infestor 1 73.5 81.5 #:hp 90.0 #:hp-max 90.0 #:energy 150.0))
        (for/list ([i (in-range 8)])
          (mk-unit (+ 6030 i) 'roach 1 75.0 (+ 77.0 (* i 0.8)) #:hp 145.0 #:hp-max 145.0))))
     (define enemies-m1 (for/list ([i (in-range 12)]) (mk-unit (+ 9021 i) 'marine 4 80.0 (+ 77.5 (* i 0.4)) #:hp 45.0 #:hp-max 45.0)))
     (define enemies-m2 (for/list ([i (in-range 12)]) (mk-unit (+ 9021 i) 'marine 4 80.0 (+ 77.5 (* i 0.4)) #:hp 35.0 #:hp-max 45.0 #:buffs '(17))))
     (define outs-inf
       (run-pipeline-sequence 'Zerg 'Terran
         (list (hash 'obs (mk-obs 13200 (append allies-inf enemies-m1) #:food-used 46 #:food-cap 66 #:food-army 30 #:food-workers 16))
               (hash 'obs (mk-obs 13208 (append allies-inf enemies-m2) #:food-used 46 #:food-cap 66 #:food-army 30 #:food-workers 16)))))
     (define fung1 (wire-count-tags-with-ability (step-outcome-wire-cmds (first outs-inf)) '(6021 6022) AB-FUNGAL-GROWTH))
     (define fung2 (wire-count-tags-with-ability (step-outcome-wire-cmds (second outs-inf)) '(6021 6022) AB-FUNGAL-GROWTH))
     ;; Part C: OC scans exact Cloaked DT coords (115, 115) & Protoss Observer flies from (60,60) toward DT at (115,115)
     (define allies-oc
       (append
        (mk-home-base-units 'Terran #:workers 16)
        (list (mk-unit 1005 'orbital-command 1 52.0 32.0 #:energy 55.0))
        (for/list ([i (in-range 8)]) (mk-unit (+ 6051 i) 'marine 1 112.0 (+ 113.0 (* i 0.7)) #:hp 45.0 #:hp-max 45.0))))
     (define dt-115
       (list (mk-unit 9051 'dark-templar 4 115.0 115.0 #:hp 40.0 #:hp-max 40.0 #:shield 80.0 #:shield-max 80.0 #:cloak 1)))
     (define out-oc (last (run-pipeline-sequence 'Terran 'Protoss
                            (list (hash 'obs (mk-obs 11000 (append allies-oc dt-115) #:food-used 40 #:food-cap 60 #:food-army 24 #:food-workers 16))))))
     (define scan-tgts (wire-targets-for-tags (step-outcome-wire-cmds out-oc) '(1005) AB-SCANNER-SWEEP))
     (define scan-accurate?
       (for/or ([t (in-list scan-tgts)])
         (define pt (third t))
         (and pt (<= (dist2d-xy (first pt) (second pt) 115.0 115.0) 8.0))))
     (define allies-obs
       (append
        (mk-home-base-units 'Protoss #:workers 16)
        (list (mk-unit 6071 'observer 1 60.0 60.0 #:hp 40.0 #:hp-max 40.0 #:shield 20.0 #:shield-max 20.0))
        (for/list ([i (in-range 6)]) (mk-unit (+ 6080 i) 'stalker 1 112.0 (+ 113.0 (* i 0.7)) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))))
     (define out-obs (last (run-pipeline-sequence 'Protoss 'Protoss
                             (list (hash 'obs (mk-obs 11000 (append allies-obs dt-115) #:food-used 40 #:food-cap 60 #:food-army 24 #:food-workers 16))))))
     (define obs-moves (wire-targets-for-tags (step-outcome-wire-cmds out-obs) '(6071) AB-MOVE))
     (define obs-dispatched?
       (for/or ([t (in-list obs-moves)])
         (define pt (third t))
         (and pt (<= (dist2d-xy (first pt) (second pt) 115.0 115.0) 15.0))))
     (define total-rej (+ (step-outcome-wire-rejects (first outs-rav)) (step-outcome-wire-rejects (second outs-rav))
                          (step-outcome-wire-rejects (first outs-inf)) (step-outcome-wire-rejects (second outs-inf))
                          (step-outcome-wire-rejects out-oc) (step-outcome-wire-rejects out-obs)))
     (values out-oc
             (list
              (mk-check "ravagers-bile-step1-and-respect-cooldown-step2" (and (>= bile1 1) (= bile2 0))
                        (format "Ravager Bile step1=~a step2=~a (expected >=1 then 0)" bile1 bile2))
              (mk-check "infestors-fungal-step1-and-skip-buff17-step2" (and (>= fung1 1) (= fung2 0))
                        (format "Infestor Fungal step1=~a step2=~a (expected >=1 then 0)" fung1 fung2))
              (mk-check "oc-scans-actual-dt-coords-115-115" scan-accurate?
                        (format "OC scan targets=~a (expected within 8t of 115,115)" scan-tgts))
              (mk-check "observer-flies-to-detect-dt-at-115-115" obs-dispatched?
                        (format "Observer moves=~a (expected toward 115,115)" obs-moves))
              (mk-check "zero-wire-rejects" (= total-rej 0)
                        (format "wire_rejects=~a" total-rej)))))))

;; -----------------------------------------------------------------------------
;; Tier 12: Wave-11 Verified Live-Pipeline & Real-SC2 Bug Reproductions (5)
;; -----------------------------------------------------------------------------
(define scen-w11-tac-1
  (tactical-scenario
   "w11-tac-1-siege-tank-splash-split-and-z02-concave-must-fire"
   "wave11-repro" "Protoss" "Terran" "splash"
   "Wave-11 P0 (Siege0DPS #46/#48 + z02): splash-split/run-through-concave must NOT force 0-DPS pure-MOVE vs Sieged Tanks + Marines"
   (lambda ()
     ;; Sub-case A: 8 Stalkers + 4 Zealots vs 4 Sieged Tanks + 12 Marines (avoid-siege-tank-splash-split + DisengageRetreat -> ATK=0, MOV=12!)
     (define home-p (mk-home-base-units 'Protoss #:workers 16))
     (define stalker-tags (for/list ([i (in-range 8)]) (+ 6101 i)))
     (define zealot-tags  (for/list ([i (in-range 4)]) (+ 6111 i)))
     (define p-combat-tags (append stalker-tags zealot-tags))
     (define allies-p
       (append
        home-p
        (for/list ([i (in-range 8)])
          (mk-unit (+ 6101 i) 'stalker 1 74.0 (+ 76.5 (* i 1.0)) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))
        (for/list ([i (in-range 4)])
          (mk-unit (+ 6111 i) 'zealot 1 75.5 (+ 78.5 (* i 1.0)) #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0))))
     (define enemies-p
       (append
        (for/list ([i (in-range 4)])
          (mk-unit (+ 9101 i) 'siege-tank-sieged 4 86.0 (+ 77.0 (* i 2.0)) #:hp 175.0 #:hp-max 175.0))
        (for/list ([i (in-range 12)])
          (mk-unit (+ 9110 i) 'marine 4 83.0 (+ 75.5 (* i 0.8)) #:hp 45.0 #:hp-max 45.0))))
     (define out-p
       (last (run-pipeline-sequence 'Protoss 'Terran
               (list (hash 'obs (mk-obs 14000 (append allies-p enemies-p)
                                        #:food-used 52 #:food-cap 80 #:food-army 36 #:food-workers 16))))))
     (define p-atk (wire-count-tags-with-ability (step-outcome-wire-cmds out-p) p-combat-tags AB-ATTACK))
     ;; Sub-case B (z02): 8 Roaches + 4 Ravagers at 8-9t vs 2 Sieged Tanks + 12 Marines (commit-run-through-splash-concave -> ATK=0, MOV=12!)
     (define home-z (mk-home-base-units 'Zerg #:workers 16))
     (define z-combat-tags (append (for/list ([i (in-range 8)]) (+ 6121 i))
                                   (for/list ([i (in-range 4)]) (+ 6131 i))))
     (define allies-z
       (append
        home-z
        (for/list ([i (in-range 8)])
          (mk-unit (+ 6121 i) 'roach 1 76.0 (+ 76.5 (* i 1.0)) #:hp 145.0 #:hp-max 145.0))
        (for/list ([i (in-range 4)])
          (mk-unit (+ 6131 i) 'ravager 1 75.0 (+ 78.0 (* i 1.2)) #:hp 120.0 #:hp-max 120.0))))
     (define enemies-z
       (append
        (list (mk-unit 9151 'siege-tank-sieged 4 86.0 79.0 #:hp 175.0 #:hp-max 175.0)
              (mk-unit 9152 'siege-tank-sieged 4 86.0 81.5 #:hp 175.0 #:hp-max 175.0))
        (for/list ([i (in-range 12)])
          (mk-unit (+ 9160 i) 'marine 4 84.0 (+ 75.5 (* i 0.8)) #:hp 45.0 #:hp-max 45.0))))
     (define out-z
       (last (run-pipeline-sequence 'Zerg 'Terran
               (list (hash 'obs (mk-obs 14000 (append allies-z enemies-z)
                                        #:food-used 52 #:food-cap 80 #:food-army 36 #:food-workers 16))))))
     (define wcmds-z (step-outcome-wire-cmds out-z))
     (define z-engage
       (for/sum ([t (in-list z-combat-tags)])
         (define abs (wire-abilities-for-tag wcmds-z t))
         (if (or (memv AB-ATTACK abs) (memv AB-CORROSIVE-BILE abs)) 1 0)))
     (define total-rej (+ (step-outcome-wire-rejects out-p) (step-outcome-wire-rejects out-z)))
     (values out-p
             (list
              (mk-check "protoss-fires-instead-of-0dps-tank-splash-retreat" (>= p-atk 6)
                        (format "Stalker+Zealot attackers=~a/12 vs Sieged Tanks+Marines (expected >=6)" p-atk))
              (mk-check "z02-roach-ravager-fires-instead-of-0dps-pure-move" (>= z-engage 6)
                        (format "Roach+Ravager ATTACK/BILE=~a/12 vs Sieged Tanks+Marines (expected >=6)" z-engage))
              (mk-check "zero-wire-rejects" (= total-rej 0)
                        (format "wire_rejects=~a" total-rej)))))))

(define scen-w11-tac-2
  (tactical-scenario
   "w11-tac-2-never-unit-target-attack-undetected-cloak1-enemies"
   "wave11-repro" "Terran" "Terran" "detection"
   "Wave-11 P0 (Cloak targeting #49/#53/#54): never unit-target ATTACK (23) undetected cloak=1 enemies; attack visible enemies or pull back safely, while still attacking detected cloak=2"
   (lambda ()
     ;; Sub-case A: 8 Marines vs 1 undetected Cloaked Banshee (cloak=1) + 4 visible Marines (cloak=3)
     (define home-t (mk-home-base-units 'Terran #:workers 16))
     (define m-tags (for/list ([i (in-range 8)]) (+ 6201 i)))
     (define allies-a
       (append home-t (for/list ([i (in-range 8)]) (mk-unit (+ 6201 i) 'marine 1 75.0 (+ 77.0 (* i 0.8)) #:hp 45.0 #:hp-max 45.0))))
     (define enemies-a
       (append (list (mk-unit 9201 'banshee 4 79.0 80.0 #:hp 140.0 #:hp-max 140.0 #:cloak 1))
               (for/list ([i (in-range 4)]) (mk-unit (+ 9210 i) 'marine 4 81.5 (+ 78.5 (* i 0.8)) #:hp 45.0 #:hp-max 45.0 #:cloak 3))))
     (define out-a
       (last (run-pipeline-sequence 'Terran 'Terran
               (list (hash 'obs (mk-obs 12000 (append allies-a enemies-a) #:food-used 36 #:food-cap 54 #:food-army 20 #:food-workers 16))))))
     (define atk-tgts-a (wire-targets-for-tags (step-outcome-wire-cmds out-a) m-tags AB-ATTACK))
     (define bad-clk-atk-a
       (for/sum ([t (in-list atk-tgts-a)])
         (if (= (second t) 9201) (length (first t)) 0)))
     (define vis-atk-a
       (for/sum ([t (in-list atk-tgts-a)])
         (if (memv (second t) '(9210 9211 9212 9213)) (length (first t)) 0)))
     ;; Sub-case B: 6 Stalkers vs 2 undetected Cloaked DTs (cloak=1), NO Observer
     (define home-p (mk-home-base-units 'Protoss #:workers 16))
     (define s-tags (for/list ([i (in-range 6)]) (+ 6221 i)))
     (define allies-b
       (append home-p (for/list ([i (in-range 6)]) (mk-unit (+ 6221 i) 'stalker 1 75.0 (+ 77.5 (* i 0.9)) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))))
     (define enemies-b
       (list (mk-unit 9221 'dark-templar 4 78.0 80.0 #:hp 40.0 #:hp-max 40.0 #:shield 80.0 #:shield-max 80.0 #:cloak 1)
             (mk-unit 9222 'dark-templar 4 78.5 81.0 #:hp 40.0 #:hp-max 40.0 #:shield 80.0 #:shield-max 80.0 #:cloak 1)))
     (define out-b
       (last (run-pipeline-sequence 'Protoss 'Protoss
               (list (hash 'obs (mk-obs 12000 (append allies-b enemies-b) #:food-used 36 #:food-cap 54 #:food-army 20 #:food-workers 16))))))
     (define atk-tgts-b (wire-targets-for-tags (step-outcome-wire-cmds out-b) s-tags AB-ATTACK))
     (define bad-clk-atk-b
       (for/sum ([t (in-list atk-tgts-b)])
         (if (memv (second t) '(9221 9222)) (length (first t)) 0)))
     (define move-b (wire-count-tags-with-ability (step-outcome-wire-cmds out-b) s-tags AB-MOVE))
     ;; Sub-case C: Detected Cloaked Banshee (cloak=2) MUST still be attacked!
     (define enemies-c (list (mk-unit 9241 'banshee 4 79.0 80.0 #:hp 140.0 #:hp-max 140.0 #:cloak 2)))
     (define out-c
       (last (run-pipeline-sequence 'Terran 'Terran
               (list (hash 'obs (mk-obs 12000 (append allies-a enemies-c) #:food-used 36 #:food-cap 54 #:food-army 20 #:food-workers 16))))))
     (define det-atk-c (wire-count-tags-with-ability (step-outcome-wire-cmds out-c) m-tags AB-ATTACK))
     (define total-rej (+ (step-outcome-wire-rejects out-a) (step-outcome-wire-rejects out-b) (step-outcome-wire-rejects out-c)))
     (values out-a
             (list
              (mk-check "mixed-army-zero-attacks-on-undetected-cloak1-banshee" (= bad-clk-atk-a 0)
                        (format "Marines unit-targeting undetected cloak=1 Banshee=~a (expected 0)" bad-clk-atk-a))
              (mk-check "mixed-army-attacks-visible-marines" (>= vis-atk-a 6)
                        (format "Marines attacking visible Marines=~a/8 (expected >=6)" vis-atk-a))
              (mk-check "stalkers-zero-invalid-attacks-on-undetected-dts" (= bad-clk-atk-b 0)
                        (format "Stalkers unit-targeting undetected cloak=1 DTs=~a (expected 0)" bad-clk-atk-b))
              (mk-check "stalkers-pull-back-from-undetected-dts" (>= move-b 4)
                        (format "Stalkers pulling back (MOVE)=~a/6 (expected >=4)" move-b))
              (mk-check "detected-cloak2-banshee-still-attacked" (>= det-atk-c 6)
                        (format "Marines attacking detected cloak=2 Banshee=~a/8 (expected >=6)" det-atk-c))
              (mk-check "zero-wire-rejects" (= total-rej 0)
                        (format "wire_rejects=~a" total-rej)))))))

(define scen-w11-tac-3
  (tactical-scenario
   "w11-tac-3-situational-counter-no-buff132-pbomb-or-phantom-90-90-bile"
   "wave11-repro" "Zerg" "Terran" "spellcaster"
   "Wave-11 P0 (situational-counter live-wire sabotage): 0 Parasitic Bomb (2542) on already-bombed buff-132 air AND 0 hardcoded (90,90) phantom Ravager Bile (2338)"
   (lambda ()
     (define home-z (mk-home-base-units 'Zerg #:workers 24 #:with-natural? #t))
     ;; Sub-case A: Viper (175en) vs 4 Vikings ALL already carrying parasitic-bomb buff 132
     (define allies-v
       (append
        home-z
        (list (mk-unit 6301 'viper 1 74.0 80.0 #:hp 150.0 #:hp-max 150.0 #:energy 175.0))
        (for/list ([i (in-range 8)]) (mk-unit (+ 6310 i) 'hydralisk 1 75.5 (+ 77.0 (* i 0.9)) #:hp 90.0 #:hp-max 90.0))))
     (define enemies-v
       (for/list ([i (in-range 4)]) (mk-unit (+ 9301 i) 'viking-fighter 4 80.0 (+ 78.5 (* i 0.6)) #:hp 135.0 #:hp-max 135.0 #:buffs '(132))))
     (define out-v
       (last (run-pipeline-sequence 'Zerg 'Terran
               (list (hash 'obs (mk-obs 12200 (append allies-v enemies-v) #:food-used 50 #:food-cap 80 #:food-army 26 #:food-workers 24))))))
     (define bad-pbomb? (wire-has-ability? (step-outcome-wire-cmds out-v) '(6301) AB-PARASITIC-BOMB))
     ;; Sub-case B: Ravager at (108, 115) vs 3 Sieged Tanks at (125, 115) must NOT cast Bile at empty hardcoded (90, 90)
     (define allies-r
       (append
        home-z
        (list (mk-unit 6321 'ravager 1 108.0 115.0 #:hp 120.0 #:hp-max 120.0))
        (for/list ([i (in-range 8)]) (mk-unit (+ 6330 i) 'roach 1 108.0 (+ 112.0 (* i 0.9)) #:hp 145.0 #:hp-max 145.0))))
     (define enemies-r
       (list (mk-unit 9321 'siege-tank-sieged 4 125.0 115.0 #:hp 175.0 #:hp-max 175.0)
             (mk-unit 9322 'siege-tank-sieged 4 125.0 117.0 #:hp 175.0 #:hp-max 175.0)
             (mk-unit 9323 'siege-tank-sieged 4 125.0 119.0 #:hp 175.0 #:hp-max 175.0)))
     (define out-r
       (last (run-pipeline-sequence 'Zerg 'Terran
               (list (hash 'obs (mk-obs 14000 (append allies-r enemies-r) #:food-used 50 #:food-cap 80 #:food-army 26 #:food-workers 24))))))
     (define bile-tgts (wire-targets-for-tags (step-outcome-wire-cmds out-r) '(6321) AB-CORROSIVE-BILE))
     (define phantom-bile?
       (for/or ([t (in-list bile-tgts)])
         (define pt (third t))
         (and pt (> (dist2d-xy (first pt) (second pt) 125.0 117.0) 8.0))))
     (define total-rej (+ (step-outcome-wire-rejects out-v) (step-outcome-wire-rejects out-r)))
     (values out-r
             (list
              (mk-check "viper-skips-already-pbombed-buff132-vikings" (not bad-pbomb?)
                        (format "Viper cast Parasitic Bomb (2542) onto buff-132 Vikings: ~a" bad-pbomb?))
              (mk-check "ravager-no-phantom-90-90-bile" (not phantom-bile?)
                        (format "Ravager Bile targets=~a (expected none >8t from tanks at 125,117)" bile-tgts))
              (mk-check "zero-wire-rejects" (= total-rej 0)
                        (format "wire_rejects=~a" total-rej)))))))

(define scen-w11-tac-4
  (tactical-scenario
   "w11-tac-4-overseer-flies-to-cloaked-banshee-not-oversight-or-changeling"
   "wave11-repro" "Zerg" "Terran" "detection"
   "Wave-11 P0 (Zerg detector paralysis #49 Z v onlyfans): Overseer must fly to active Cloaked Banshee instead of freezing in Oversight Mode (3743) or casting Changeling (181)"
   (lambda ()
     (define home-z (mk-home-base-units 'Zerg #:workers 16))
     ;; Sub-case A: 0-energy Overseer at (60, 60) with Cloaked Banshee attacking Hydras at (115, 115)
     (define allies-a
       (append
        home-z
        (list (mk-unit 6401 'overseer 1 60.0 60.0 #:hp 200.0 #:hp-max 200.0 #:energy 0.0))
        (for/list ([i (in-range 8)]) (mk-unit (+ 6410 i) 'hydralisk 1 112.0 (+ 113.0 (* i 0.7)) #:hp 90.0 #:hp-max 90.0))))
     (define enemies-a (list (mk-unit 9401 'banshee 4 115.0 115.0 #:hp 140.0 #:hp-max 140.0 #:cloak 1)))
     (define out-a
       (last (run-pipeline-sequence 'Zerg 'Terran
               (list (hash 'obs (mk-obs 11000 (append allies-a enemies-a) #:food-used 40 #:food-cap 60 #:food-army 24 #:food-workers 16))))))
     (define wcmds-a (step-outcome-wire-cmds out-a))
     (define froze-oversight-a? (wire-has-ability? wcmds-a '(6401) AB-MORPH-OVERSIGHT-MODE))
     (define moved-to-115?
       (for/or ([t (in-list (wire-targets-for-tags wcmds-a '(6401) AB-MOVE))])
         (define pt (third t))
         (and pt (<= (dist2d-xy (first pt) (second pt) 115.0 115.0) 15.0))))
     ;; Sub-case B: 50-energy Overseer at (60, 60) with Cloaked Banshee attacking home base (35, 35)
     (define allies-b
       (append
        home-z
        (list (mk-unit 6421 'overseer 1 60.0 60.0 #:hp 200.0 #:hp-max 200.0 #:energy 50.0))
        (for/list ([i (in-range 8)]) (mk-unit (+ 6430 i) 'hydralisk 1 36.0 (+ 33.0 (* i 0.7)) #:hp 90.0 #:hp-max 90.0))))
     (define enemies-b (list (mk-unit 9421 'banshee 4 35.0 35.0 #:hp 140.0 #:hp-max 140.0 #:cloak 1)))
     (define out-b
       (last (run-pipeline-sequence 'Zerg 'Terran
               (list (hash 'obs (mk-obs 11000 (append allies-b enemies-b) #:food-used 40 #:food-cap 60 #:food-army 24 #:food-workers 16))))))
     (define wcmds-b (step-outcome-wire-cmds out-b))
     (define changeling-b? (wire-has-ability? wcmds-b '(6421) AB-SPAWN-CHANGELING))
     (define froze-oversight-b? (wire-has-ability? wcmds-b '(6421) AB-MORPH-OVERSIGHT-MODE))
     (define moved-to-35?
       (for/or ([t (in-list (wire-targets-for-tags wcmds-b '(6421) AB-MOVE))])
         (define pt (third t))
         (and pt (<= (dist2d-xy (first pt) (second pt) 35.0 35.0) 15.0))))
     (define total-rej (+ (step-outcome-wire-rejects out-a) (step-outcome-wire-rejects out-b)))
     (values out-a
             (list
              (mk-check "0en-overseer-does-not-freeze-in-oversight-mode" (not froze-oversight-a?)
                        (format "0en Overseer cast 3743 Oversight Mode 78t from Banshee: ~a" froze-oversight-a?))
              (mk-check "0en-overseer-flies-to-cloaked-banshee" moved-to-115?
                        (format "0en Overseer MOVE toward (115,115): ~a" moved-to-115?))
              (mk-check "50en-overseer-skips-changeling-and-oversight-during-home-cloak" (and (not changeling-b?) (not froze-oversight-b?))
                        (format "50en Overseer Changeling=~a Oversight=~a (expected #f, #f)" changeling-b? froze-oversight-b?))
              (mk-check "50en-overseer-flies-home-to-detect-banshee" moved-to-35?
                        (format "50en Overseer MOVE toward home (35,35): ~a" moved-to-35?))
              (mk-check "zero-wire-rejects" (= total-rej 0)
                        (format "wire_rejects=~a" total-rej)))))))

(define scen-w11-tac-5
  (tactical-scenario
   "w11-tac-5-full-energy-medivac-heals-not-3668-pickups-fighting-marauder"
   "wave11-repro" "Terran" "Zerg" "transport"
   "Wave-11 P1 (t04 0.15x Medivac pickup): full-energy Medivac (100en) must NOT 3668-pickup a frontline fighting Marauder (30% HP) with no lethal AoE instead of healing bio"
   (lambda ()
     (define home-t (mk-home-base-units 'Terran #:workers 16))
     (define allies
       (append
        home-t
        (list (mk-unit 6501 'medivac 1 74.2 80.0 #:hp 150.0 #:hp-max 150.0 #:energy 100.0)
              (mk-unit 6502 'marauder 1 75.0 80.0 #:hp 37.0 #:hp-max 125.0)
              (mk-unit 6503 'marauder 1 75.0 81.5 #:hp 95.0 #:hp-max 125.0))
        (for/list ([i (in-range 6)])
          (mk-unit (+ 6510 i) 'marine 1 74.5 (+ 77.5 (* i 1.0)) #:hp 35.0 #:hp-max 45.0))))
     (define enemies
       (append
        (list (mk-unit 9501 'ultralisk 4 79.0 80.0 #:hp 450.0 #:hp-max 500.0))
        (for/list ([i (in-range 6)])
          (mk-unit (+ 9510 i) 'zergling 4 78.0 (+ 78.0 (* i 0.8)) #:hp 35.0 #:hp-max 35.0))))
     (define out
       (last (run-pipeline-sequence 'Terran 'Zerg
               (list (hash 'obs (mk-obs 12000 (append allies enemies)
                                        #:food-used 46 #:food-cap 66 #:food-army 30 #:food-workers 16))))))
     (define wcmds (step-outcome-wire-cmds out))
     (define picked-up-marauder? (wire-any-ability? wcmds '(6501) (list AB-LOAD-GENERIC AB-MEDIVAC-LOAD)))
     (define marauder-atk (wire-count-tags-with-ability wcmds '(6502 6503) AB-ATTACK))
     (values out
             (list
              (mk-check "100en-medivac-does-not-pickup-fighting-marauder-no-aoe" (not picked-up-marauder?)
                        (format "100en Medivac emitted LOAD (3668/394) on fighting Marauder with no AoE: ~a (expected #f)" picked-up-marauder?))
              (mk-check "marauders-keep-firing" (>= marauder-atk 1)
                        (format "Marauder attackers=~a/2" marauder-atk))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))


(define scen-w11-tac-6
  (tactical-scenario
   "w11-tac-6-stalkers-vs-tempests-at-16t-shell-range-must-dive-not-rally-retreat"
   "wave11-repro" "Protoss" "Protoss" "capital-dive"
   "Wave-11 P0 (W11-P0-4 / #30 P v Creepy OBRet=7,268f): 12 Stalkers at 16t inside Tempest 16.9t weapon range must dive/attack instead of falling outside 15t arena radius into combat-suppress-attack rally-retreat (ATK=0, MOV=12 -> 50,50)"
   (lambda ()
     (define home-p (mk-home-base-units 'Protoss #:workers 24 #:with-natural? #t))
     (define tags (for/list ([i (in-range 12)]) (+ 6601 i)))
     (define allies
       (append home-p
               (for/list ([i (in-range 12)])
                 (mk-unit (+ 6601 i) 'stalker 1 74.0 (+ 74.0 (* i 1.0))
                          #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))))
     ;; Sub-case A: 12 Stalkers vs 8 Tempests at 16.0t (fap=hold -> currently ATK=0/12, MOV=12/12 -> 50,50!)
     (define enemies-8
       (for/list ([i (in-range 8)])
         (mk-unit (+ 9601 i) 'tempest 4 90.0 (+ 76.0 (* i 1.2))
                  #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0)))
     (define out-a
       (last (run-pipeline-sequence 'Protoss 'Protoss
               (list (hash 'obs (mk-obs 16000 (append allies enemies-8)
                                        #:food-used 60 #:food-cap 100 #:food-army 36 #:food-workers 24))))))
     (define atk-a (wire-count-tags-with-ability (step-outcome-wire-cmds out-a) tags AB-ATTACK))
     ;; Sub-case B: 12 Stalkers vs 16 Tempests at 16.0t (fap=retreat -> currently ATK=0/12, MOV=12/12 -> 50,50!)
     (define enemies-16
       (for/list ([i (in-range 16)])
         (mk-unit (+ 9621 i) 'tempest 4 90.0 (+ 72.0 (* i 1.0))
                  #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0)))
     (define out-b
       (last (run-pipeline-sequence 'Protoss 'Protoss
               (list (hash 'obs (mk-obs 16000 (append allies enemies-16)
                                        #:food-used 60 #:food-cap 100 #:food-army 36 #:food-workers 24))))))
     (define atk-b (wire-count-tags-with-ability (step-outcome-wire-cmds out-b) tags AB-ATTACK))
     (define total-rej (+ (step-outcome-wire-rejects out-a) (step-outcome-wire-rejects out-b)))
     (values out-b
             (list
              (mk-check "12-stalkers-dive-8-tempests-at-16t" (>= atk-a 8)
                        (format "Stalker attackers vs 8 Tempests at 16t=~a/12 (expected >=8)" atk-a))
              (mk-check "12-stalkers-dive-16-tempests-at-16t" (>= atk-b 8)
                        (format "Stalker attackers vs 16 Tempests at 16t=~a/12 (expected >=8)" atk-b))
              (mk-check "zero-wire-rejects" (= total-rej 0)
                        (format "wire_rejects=~a" total-rej)))))))


;; -----------------------------------------------------------------------------
;; Round-12 Pro-Inspired Regression Shields (novel-101..113)
;; -----------------------------------------------------------------------------
(define scen-novel-101
  (tactical-scenario
   "novel-101-stalker-blink-lowhp-pullback-and-cooldown"
   "novel" "Protoss" "Zerg" "kite"
   "Low-HP Stalker with blink-tech blinks back (3687/1442) on step 1 and respects cooldown (0 Blink, attacks) 8f later"
   (lambda ()
     (define home (mk-home-base-units 'Protoss #:workers 16))
     (define allies
       (append home
               (list (mk-unit 5001 'stalker 1 75.5 80.0 #:hp 35.0 #:hp-max 80.0 #:shield 0.0 #:shield-max 80.0))
               (for/list ([i (in-range 5)])
                 (mk-unit (+ 5002 i) 'stalker 1 74.0 (+ 77.5 (* i 1.0)) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))))
     (define enemies (for/list ([i (in-range 8)]) (mk-unit (+ 8001 i) 'roach 4 80.0 (+ 77.0 (* i 0.8)) #:hp 145.0 #:hp-max 145.0)))
     (define outs
       (run-pipeline-sequence 'Protoss 'Zerg
         (list (hash 'obs (mk-obs 12000 (append allies enemies) #:upgrades '(blink-tech) #:food-used 40 #:food-cap 66 #:food-army 24 #:food-workers 16))
               (hash 'obs (mk-obs 12008 (append allies enemies) #:upgrades '(blink-tech) #:food-used 40 #:food-cap 66 #:food-army 24 #:food-workers 16)))))
     (define blink1? (wire-any-ability? (step-outcome-wire-cmds (first outs)) '(5001) (list AB-BLINK-STALKER AB-BLINK-GENERIC)))
     (define blink2? (wire-any-ability? (step-outcome-wire-cmds (second outs)) '(5001) (list AB-BLINK-STALKER AB-BLINK-GENERIC)))
     (define total-rej (+ (step-outcome-wire-rejects (first outs)) (step-outcome-wire-rejects (second outs))))
     (values (second outs)
             (list
              (mk-check "lowhp-stalker-blinks-step1" blink1? (format "Stalker 5001 blinked step1=~a" blink1?))
              (mk-check "stalker-respects-blink-cooldown-step2" (not blink2?) (format "Stalker 5001 spammed Blink step2=~a" blink2?))
              (mk-check "zero-wire-rejects" (= total-rej 0) (format "wire_rejects=~a" total-rej)))))))

(define scen-novel-102
  (tactical-scenario
   "novel-102-disruptor-purification-nova-cast-and-cooldown"
   "novel" "Protoss" "Zerg" "spellcaster"
   "Disruptor fires Purification Nova (2346) at clustered Roaches on step 1 and pulls back (0 spam) 8f later"
   (lambda ()
     (define home (mk-home-base-units 'Protoss #:workers 16))
     (define allies
       (append home
               (list (mk-unit 5301 'disruptor 1 73.0 80.0 #:hp 100.0 #:hp-max 100.0 #:shield 100.0 #:shield-max 100.0))
               (for/list ([i (in-range 6)])
                 (mk-unit (+ 5310 i) 'stalker 1 74.5 (+ 77.5 (* i 0.9)) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))))
     (define enemies (for/list ([i (in-range 10)]) (mk-unit (+ 8301 i) 'roach 4 81.5 (+ 77.5 (* i 0.5)) #:hp 145.0 #:hp-max 145.0)))
     (define outs
       (run-pipeline-sequence 'Protoss 'Zerg
         (list (hash 'obs (mk-obs 12300 (append allies enemies) #:food-used 44 #:food-cap 66 #:food-army 28 #:food-workers 16))
               (hash 'obs (mk-obs 12308 (append allies enemies) #:food-used 44 #:food-cap 66 #:food-army 28 #:food-workers 16)))))
     (define nova1? (wire-has-ability? (step-outcome-wire-cmds (first outs)) '(5301) AB-PURIFICATION-NOVA))
     (define nova2? (wire-has-ability? (step-outcome-wire-cmds (second outs)) '(5301) AB-PURIFICATION-NOVA))
     (define total-rej (+ (step-outcome-wire-rejects (first outs)) (step-outcome-wire-rejects (second outs))))
     (values (second outs)
             (list
              (mk-check "disruptor-fires-nova-step1" nova1? (format "Disruptor Nova step1=~a" nova1?))
              (mk-check "disruptor-respects-nova-cooldown-step2" (not nova2?) (format "Disruptor spammed Nova step2=~a" nova2?))
              (mk-check "zero-wire-rejects" (= total-rej 0) (format "wire_rejects=~a" total-rej)))))))

(define scen-novel-103
  (tactical-scenario
   "novel-103-adept-phase-shift-and-cooldown"
   "novel" "Protoss" "Terran" "harass"
   "Adepts cast Psionic Transfer (2544) on step 1 and respect cooldown (0 spam, attack) 8f later"
   (lambda ()
     (define home (mk-home-base-units 'Protoss #:workers 16))
     (define tags '(5701 5702 5703 5704))
     (define allies (append home (for/list ([i (in-range 4)]) (mk-unit (+ 5701 i) 'adept 1 75.0 (+ 78.5 (* i 0.9)) #:hp 70.0 #:hp-max 70.0 #:shield 70.0 #:shield-max 70.0))))
     (define enemies (for/list ([i (in-range 8)]) (mk-unit (+ 8701 i) 'marine 4 81.0 (+ 77.5 (* i 0.7)) #:hp 45.0 #:hp-max 45.0)))
     (define outs
       (run-pipeline-sequence 'Protoss 'Terran
         (list (hash 'obs (mk-obs 8000 (append allies enemies) #:food-used 32 #:food-cap 54 #:food-army 16 #:food-workers 16))
               (hash 'obs (mk-obs 8008 (append allies enemies) #:food-used 32 #:food-cap 54 #:food-army 16 #:food-workers 16)))))
     (define sh1 (wire-count-tags-with-ability (step-outcome-wire-cmds (first outs)) tags AB-ADEPT-SHADE))
     (define sh2 (wire-count-tags-with-ability (step-outcome-wire-cmds (second outs)) tags AB-ADEPT-SHADE))
     (define atk2 (wire-count-tags-with-ability (step-outcome-wire-cmds (second outs)) tags AB-ATTACK))
     (define total-rej (+ (step-outcome-wire-rejects (first outs)) (step-outcome-wire-rejects (second outs))))
     (values (second outs)
             (list
              (mk-check "adepts-cast-shade-step1" (>= sh1 1) (format "Adept Shade step1=~a" sh1))
              (mk-check "adepts-respect-shade-cooldown-and-attack-step2" (and (= sh2 0) (>= atk2 3))
                        (format "Adept step2 Shade=~a ATK=~a" sh2 atk2))
              (mk-check "zero-wire-rejects" (= total-rej 0) (format "wire_rejects=~a" total-rej)))))))

(define scen-novel-104
  (tactical-scenario
   "novel-104-warp-prism-unphase-under-fire-and-immortal-rescue"
   "novel" "Protoss" "Terran" "transport"
   "Low-HP Phasing Warp Prism unphases (1530) under Marine fire AND Transport Warp Prism rescues 30%-HP Immortal (3668)"
   (lambda ()
     (define home (mk-home-base-units 'Protoss #:workers 16))
     (define enemies (for/list ([i (in-range 6)]) (mk-unit (+ 8201 i) 'marine 4 79.0 (+ 78.5 (* i 0.6)) #:hp 45.0 #:hp-max 45.0)))
     (define allies-ph (append home (list (mk-unit 5201 'warp-prism-phasing 1 75.0 80.0 #:hp 35.0 #:hp-max 80.0 #:shield 0.0 #:shield-max 100.0))))
     (define allies-pk (append home (list (mk-unit 5211 'warp-prism 1 74.0 80.0 #:hp 80.0 #:hp-max 80.0 #:shield 100.0 #:shield-max 100.0)
                                          (mk-unit 5212 'immortal 1 75.0 80.0 #:hp 55.0 #:hp-max 200.0 #:shield 0.0 #:shield-max 100.0))))
     (define o1 (last (run-pipeline-sequence 'Protoss 'Terran (list (hash 'obs (mk-obs 12200 (append allies-ph enemies) #:food-used 30 #:food-cap 50 #:food-army 14 #:food-workers 16))))))
     (define o2 (last (run-pipeline-sequence 'Protoss 'Terran (list (hash 'obs (mk-obs 12200 (append allies-pk enemies) #:food-used 30 #:food-cap 50 #:food-army 14 #:food-workers 16))))))
     (define unphased? (wire-has-ability? (step-outcome-wire-cmds o1) '(5201) AB-MORPH-WARP-PRISM-TRANSPORT))
     (define picked? (wire-any-ability? (step-outcome-wire-cmds o2) '(5211) (list AB-LOAD-GENERIC AB-WARP-PRISM-LOAD)))
     (define total-rej (+ (step-outcome-wire-rejects o1) (step-outcome-wire-rejects o2)))
     (values o2
             (list
              (mk-check "lowhp-phasing-warp-prism-unphases" unphased? (format "WarpPrism unphased (1530)=~a" unphased?))
              (mk-check "warp-prism-rescues-lowhp-immortal" picked? (format "WarpPrism rescued 30% Immortal=~a" picked?))
              (mk-check "zero-wire-rejects" (= total-rej 0) (format "wire_rejects=~a" total-rej)))))))

(define scen-novel-105
  (tactical-scenario
   "novel-105-terran-bunker-load-and-scv-auto-repair"
   "novel" "Terran" "Zerg" "defense"
   "Marines load empty Bunker (407) AND nearby SCVs auto-repair (3685/316) 35%-HP Bunker during Zergling attack"
   (lambda ()
     (define home (mk-home-base-units 'Terran #:workers 16))
     (define allies
       (append home
               (list (mk-unit 5301 'bunker 1 56.0 32.0 #:hp 140.0 #:hp-max 400.0)
                     (mk-unit 5302 'scv 1 54.0 32.0 #:hp 45.0 #:hp-max 45.0)
                     (mk-unit 5303 'scv 1 54.0 33.0 #:hp 45.0 #:hp-max 45.0))
               (for/list ([i (in-range 4)]) (mk-unit (+ 5310 i) 'marine 1 55.0 (+ 31.0 (* i 0.6)) #:hp 45.0 #:hp-max 45.0))))
     (define enemies (for/list ([i (in-range 10)]) (mk-unit (+ 8301 i) 'zergling 4 59.0 (+ 30.0 (* i 0.5)) #:hp 35.0 #:hp-max 35.0)))
     (define out (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs (mk-obs 6000 (append allies enemies) #:food-used 28 #:food-cap 46 #:food-army 12 #:food-workers 16))))))
     (define wcmds (step-outcome-wire-cmds out))
     (define loaded? (wire-has-ability? wcmds '(5301) AB-LOAD-BUNKER))
     (define repaired (wire-count-tags-with-ability wcmds '(5302 5303) AB-REPAIR-GENERIC))
     (define repaired-scv (wire-count-tags-with-ability wcmds '(5302 5303) AB-REPAIR-SCV))
     (values out
             (list
              (mk-check "bunker-loads-marines-407" loaded? (format "Bunker emitted 407 load=~a" loaded?))
              (mk-check "scvs-repair-damaged-bunker" (>= (+ repaired repaired-scv) 1)
                        (format "SCVs repairing Bunker=~a" (+ repaired repaired-scv)))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

(define scen-novel-106
  (tactical-scenario
   "novel-106-liberator-ag-aa-mode-and-widow-mine-burrow"
   "novel" "Terran" "Zerg" "unit-modes"
   "Liberator sieges AG (2558) vs Roaches, unsieges AA (2560) vs Mutalisks, and Widow Mine burrows (2095/3661) on Ling contact"
   (lambda ()
     (define home (mk-home-base-units 'Terran #:workers 16))
     (define o-ag (last (run-pipeline-sequence 'Terran 'Zerg
                          (list (hash 'obs (mk-obs 12700 (append home (list (mk-unit 5701 'liberator 1 75.0 80.0 #:hp 180.0 #:hp-max 180.0))
                                                                 (for/list ([i (in-range 6)]) (mk-unit (+ 8701 i) 'roach 4 80.0 (+ 78.0 (* i 0.8)) #:hp 145.0 #:hp-max 145.0)))
                                                   #:food-used 36 #:food-cap 60 #:food-army 20 #:food-workers 16))))))
     (define o-aa (last (run-pipeline-sequence 'Terran 'Zerg
                          (list (hash 'obs (mk-obs 12700 (append home (list (mk-unit 5711 'liberator-ag 1 75.0 80.0 #:hp 180.0 #:hp-max 180.0))
                                                                 (for/list ([i (in-range 4)]) (mk-unit (+ 8711 i) 'mutalisk 4 80.0 (+ 78.5 (* i 0.9)) #:hp 120.0 #:hp-max 120.0)))
                                                   #:food-used 36 #:food-cap 60 #:food-army 20 #:food-workers 16))))))
     (define o-wm (last (run-pipeline-sequence 'Terran 'Zerg
                          (list (hash 'obs (mk-obs 12400 (append home (list (mk-unit 5401 'widow-mine 1 75.0 80.0 #:hp 90.0 #:hp-max 90.0))
                                                                 (for/list ([i (in-range 8)]) (mk-unit (+ 8401 i) 'zergling 4 79.0 (+ 78.0 (* i 0.5)) #:hp 35.0 #:hp-max 35.0)))
                                                   #:food-used 30 #:food-cap 50 #:food-army 14 #:food-workers 16))))))
     (define lib-ag? (wire-has-ability? (step-outcome-wire-cmds o-ag) '(5701) AB-LIBERATOR-AG))
     (define lib-aa? (wire-has-ability? (step-outcome-wire-cmds o-aa) '(5711) AB-LIBERATOR-AA))
     (define wm-burr? (wire-any-ability? (step-outcome-wire-cmds o-wm) '(5401) (list AB-BURROW-WIDOW-MINE AB-BURROW-DOWN)))
     (define total-rej (+ (step-outcome-wire-rejects o-ag) (step-outcome-wire-rejects o-aa) (step-outcome-wire-rejects o-wm)))
     (values o-ag
             (list
              (mk-check "liberator-sieges-ag-over-roaches" lib-ag? (format "Liberator AG (2558)=~a" lib-ag?))
              (mk-check "liberator-unsieges-aa-vs-mutalisks" lib-aa? (format "Liberator AA (2560)=~a" lib-aa?))
              (mk-check "widow-mine-burrows-vs-zerglings" wm-burr? (format "WidowMine burrow=~a" wm-burr?))
              (mk-check "zero-wire-rejects" (= total-rej 0) (format "wire_rejects=~a" total-rej)))))))

(define scen-novel-107
  (tactical-scenario
   "novel-107-thor-high-impact-vs-carriers-and-explosive-vs-mutalisks"
   "novel" "Terran" "Protoss" "unit-modes"
   "Thor switches to High Impact (2362) vs Massive Carriers AND Thor-AP switches to Explosive (2364) vs Mutalisk flock"
   (lambda ()
     (define home (mk-home-base-units 'Terran #:workers 16))
     (define o-hi (last (run-pipeline-sequence 'Terran 'Protoss
                          (list (hash 'obs (mk-obs 12400 (append home (list (mk-unit 5411 'thor 1 75.0 80.0 #:hp 400.0 #:hp-max 400.0))
                                                                 (for/list ([i (in-range 4)]) (mk-unit (+ 8411 i) 'carrier 4 82.0 (+ 78.0 (* i 1.2)) #:hp 300.0 #:hp-max 300.0 #:shield 150.0 #:shield-max 150.0)))
                                                   #:food-used 36 #:food-cap 60 #:food-army 20 #:food-workers 16))))))
     (define o-ex (last (run-pipeline-sequence 'Terran 'Zerg
                          (list (hash 'obs (mk-obs 12400 (append home (list (mk-unit 5412 'thor-ap 1 75.0 80.0 #:hp 400.0 #:hp-max 400.0))
                                                                 (for/list ([i (in-range 8)]) (mk-unit (+ 8421 i) 'mutalisk 4 81.0 (+ 77.5 (* i 0.7)) #:hp 120.0 #:hp-max 120.0)))
                                                   #:food-used 36 #:food-cap 60 #:food-army 20 #:food-workers 16))))))
     (define hi? (wire-has-ability? (step-outcome-wire-cmds o-hi) '(5411) AB-THOR-HIGH-IMPACT))
     (define ex? (wire-has-ability? (step-outcome-wire-cmds o-ex) '(5412) AB-THOR-EXPLOSIVE))
     (define total-rej (+ (step-outcome-wire-rejects o-hi) (step-outcome-wire-rejects o-ex)))
     (values o-hi
             (list
              (mk-check "thor-switches-high-impact-vs-carriers" hi? (format "Thor High Impact (2362)=~a" hi?))
              (mk-check "thor-ap-switches-explosive-vs-mutalisks" ex? (format "Thor Explosive (2364)=~a" ex?))
              (mk-check "zero-wire-rejects" (= total-rej 0) (format "wire_rejects=~a" total-rej)))))))

(define scen-novel-108
  (tactical-scenario
   "novel-108-upgrade-gate-hygiene-cloak-and-burrow"
   "novel" "Terran" "Terran" "wire-hygiene"
   "Ghost/Banshee emit 0 invalid cloak (382/392) without upgrades AND low-HP Roach emits 0 invalid burrow (1386/3661) without burrow upgrade"
   (lambda ()
     (define enemies (for/list ([i (in-range 8)]) (mk-unit (+ 8501 i) 'marine 4 79.0 (+ 78.0 (* i 0.6)) #:hp 45.0 #:hp-max 45.0)))
     (define o-t (last (run-pipeline-sequence 'Terran 'Terran
                         (list (hash 'obs (mk-obs 12500 (append (mk-home-base-units 'Terran #:workers 16)
                                                                (list (mk-unit 5501 'ghost 1 75.0 80.0 #:hp 40.0 #:hp-max 100.0 #:energy 100.0)
                                                                      (mk-unit 5502 'banshee 1 75.0 82.0 #:hp 60.0 #:hp-max 140.0 #:energy 100.0))
                                                                enemies)
                                                  #:upgrades '() #:food-used 30 #:food-cap 50 #:food-army 14 #:food-workers 16))))))
     (define o-z (last (run-pipeline-sequence 'Zerg 'Terran
                         (list (hash 'obs (mk-obs 12500 (append (mk-home-base-units 'Zerg #:workers 16)
                                                                (list (mk-unit 5511 'roach 1 75.0 80.0 #:hp 30.0 #:hp-max 145.0)
                                                                      (mk-unit 5512 'roach 1 75.0 81.5 #:hp 145.0 #:hp-max 145.0))
                                                                enemies)
                                                  #:upgrades '() #:food-used 30 #:food-cap 50 #:food-army 14 #:food-workers 16))))))
     (define bad-clk? (wire-any-ability? (step-outcome-wire-cmds o-t) '(5501 5502) (list AB-CLOAK-GHOST AB-CLOAK-BANSHEE)))
     (define bad-burr? (wire-any-ability? (step-outcome-wire-cmds o-z) '(5511 5512) (list AB-BURROW-ROACH-DOWN AB-BURROW-DOWN)))
     (define total-rej (+ (step-outcome-wire-rejects o-t) (step-outcome-wire-rejects o-z)))
     (values o-t
             (list
              (mk-check "zero-unresearched-cloak-casts" (not bad-clk?) (format "Unresearched Ghost/Banshee cloak=~a" bad-clk?))
              (mk-check "zero-unresearched-roach-burrow" (not bad-burr?) (format "Unresearched Roach burrow=~a" bad-burr?))
              (mk-check "zero-wire-rejects" (= total-rej 0) (format "wire_rejects=~a" total-rej)))))))

(define scen-novel-109
  (tactical-scenario
   "novel-109-baneling-light-target-and-queen-transfusion"
   "novel" "Zerg" "Terran" "focus-fire"
   "Banelings detonate on Light Marines (not Marauders) at 1.0t AND Queen transfuses 30%-HP Ultralisk while skipping 100%-HP Ultralisk"
   (lambda ()
     (define home (mk-home-base-units 'Zerg #:workers 16))
     (define b-tags '(5001 5002 5003 5004 5005 5006))
     (define allies-b (append home (for/list ([i (in-range 6)]) (mk-unit (+ 5001 i) 'baneling 1 79.5 (+ 78.5 (* i 0.5)) #:hp 30.0 #:hp-max 30.0))))
     (define enemies-b (append (list (mk-unit 8001 'marauder 4 78.0 79.5 #:hp 125.0 #:hp-max 125.0))
                               (for/list ([i (in-range 8)]) (mk-unit (+ 8010 i) 'marine 4 80.5 (+ 78.0 (* i 0.5)) #:hp 45.0 #:hp-max 45.0))))
     (define o-b (last (run-pipeline-sequence 'Zerg 'Terran (list (hash 'obs (mk-obs 12000 (append allies-b enemies-b) #:food-used 36 #:food-cap 60 #:food-army 20 #:food-workers 16))))))
     (define b-tgts (wire-targets-for-tags (step-outcome-wire-cmds o-b) b-tags AB-ATTACK))
     (define hit-marines (for/sum ([t (in-list b-tgts)]) (if (and (>= (second t) 8010) (<= (second t) 8017)) (length (first t)) 0)))
     (define enemies-q (for/list ([i (in-range 8)]) (mk-unit (+ 8501 i) 'marine 4 81.0 (+ 77.5 (* i 0.7)) #:hp 45.0 #:hp-max 45.0)))
     (define o-q1 (last (run-pipeline-sequence 'Zerg 'Terran (list (hash 'obs (mk-obs 12500 (append home (list (mk-unit 5501 'queen 1 74.0 80.0 #:hp 175.0 #:hp-max 175.0 #:energy 100.0) (mk-unit 5502 'ultralisk 1 76.5 80.0 #:hp 150.0 #:hp-max 500.0)) enemies-q) #:food-used 40 #:food-cap 66 #:food-army 24 #:food-workers 16))))))
     (define o-q2 (last (run-pipeline-sequence 'Zerg 'Terran (list (hash 'obs (mk-obs 12500 (append home (list (mk-unit 5501 'queen 1 74.0 80.0 #:hp 175.0 #:hp-max 175.0 #:energy 100.0) (mk-unit 5502 'ultralisk 1 76.5 80.0 #:hp 500.0 #:hp-max 500.0)) enemies-q) #:food-used 40 #:food-cap 66 #:food-army 24 #:food-workers 16))))))
     (define tr-inj? (wire-has-ability? (step-outcome-wire-cmds o-q1) '(5501) AB-TRANSFUSE))
     (define tr-ok?  (wire-has-ability? (step-outcome-wire-cmds o-q2) '(5501) AB-TRANSFUSE))
     (define total-rej (+ (step-outcome-wire-rejects o-b) (step-outcome-wire-rejects o-q1) (step-outcome-wire-rejects o-q2)))
     (values o-b
             (list
              (mk-check "banelings-target-light-marines-not-marauder" (>= hit-marines 4)
                        (format "Banelings targeting Light Marines=~a/6" hit-marines))
              (mk-check "queen-transfuses-injured-ultralisk" tr-inj? (format "Queen transfused 30% Ultra=~a" tr-inj?))
              (mk-check "queen-skips-transfuse-on-fullhp-ultralisk" (not tr-ok?) (format "Queen transfused 100% Ultra=~a" tr-ok?))
              (mk-check "zero-wire-rejects" (= total-rej 0) (format "wire_rejects=~a" total-rej)))))))

(define scen-novel-110
  (tactical-scenario
   "novel-110-lurker-burrow-unburrow-and-swarm-host-cooldown"
   "novel" "Zerg" "Terran" "unit-modes"
   "Lurkers burrow (2108) on Marine contact and unburrow (3662/2110) when enemies are 27t away; Swarm Host spawns Locusts step 1 and respects cooldown step 2"
   (lambda ()
     (define home (mk-home-base-units 'Zerg #:workers 16))
     (define o-dn (last (run-pipeline-sequence 'Zerg 'Terran (list (hash 'obs (mk-obs 12800 (append home (list (mk-unit 5801 'lurker-mp 1 75.0 80.0 #:hp 200.0 #:hp-max 200.0)) (for/list ([i (in-range 8)]) (mk-unit (+ 8801 i) 'marine 4 81.5 (+ 77.5 (* i 0.7)) #:hp 45.0 #:hp-max 45.0))) #:food-used 36 #:food-cap 60 #:food-army 20 #:food-workers 16))))))
     (define o-up (last (run-pipeline-sequence 'Zerg 'Terran (list (hash 'obs (mk-obs 12800 (append home (list (mk-unit 5811 'lurker-mp-burrowed 1 75.0 80.0 #:hp 200.0 #:hp-max 200.0 #:burrowed? #t)) (for/list ([i (in-range 8)]) (mk-unit (+ 8811 i) 'marine 4 102.0 (+ 77.5 (* i 0.7)) #:hp 45.0 #:hp-max 45.0))) #:food-used 36 #:food-cap 60 #:food-army 20 #:food-workers 16))))))
     (define sh-allies (append home (list (mk-unit 5401 'swarm-host 1 70.0 80.0 #:hp 160.0 #:hp-max 160.0) (mk-unit 5402 'swarm-host 1 70.0 82.0 #:hp 160.0 #:hp-max 160.0))))
     (define sh-enemies (for/list ([i (in-range 6)]) (mk-unit (+ 8401 i) 'stalker 4 86.0 (+ 78.0 (* i 0.9)) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0)))
     (define outs-sh (run-pipeline-sequence 'Zerg 'Protoss
                       (list (hash 'obs (mk-obs 12400 (append sh-allies sh-enemies) #:food-used 36 #:food-cap 60 #:food-army 20 #:food-workers 16))
                             (hash 'obs (mk-obs 12408 (append sh-allies sh-enemies) #:food-used 36 #:food-cap 60 #:food-army 20 #:food-workers 16)))))
     (define burrowed? (wire-any-ability? (step-outcome-wire-cmds o-dn) '(5801) (list AB-BURROW-LURKER AB-BURROW-DOWN)))
     (define unburrowed? (wire-any-ability? (step-outcome-wire-cmds o-up) '(5811) (list AB-UNBURROW-LURKER AB-BURROW-UP)))
     (define loc1 (wire-count-tags-with-ability (step-outcome-wire-cmds (first outs-sh)) '(5401 5402) AB-SPAWN-LOCUSTS))
     (define loc2 (wire-count-tags-with-ability (step-outcome-wire-cmds (second outs-sh)) '(5401 5402) AB-SPAWN-LOCUSTS))
     (define total-rej (+ (step-outcome-wire-rejects o-dn) (step-outcome-wire-rejects o-up) (step-outcome-wire-rejects (first outs-sh)) (step-outcome-wire-rejects (second outs-sh))))
     (values o-dn
             (list
              (mk-check "lurker-burrows-on-marine-contact" burrowed? (format "Lurker burrow=~a" burrowed?))
              (mk-check "lurker-unburrows-when-enemies-far" unburrowed? (format "Lurker unburrow=~a" unburrowed?))
              (mk-check "swarmhost-spawns-locusts-step1-and-respects-cd-step2" (and (>= loc1 1) (= loc2 0))
                        (format "SwarmHost Locusts step1=~a step2=~a" loc1 loc2))
              (mk-check "zero-wire-rejects" (= total-rej 0) (format "wire_rejects=~a" total-rej)))))))

(define scen-novel-111
  (tactical-scenario
   "novel-111-sentry-force-field-dedup-and-worker-scout-proportionality"
   "novel" "Protoss" "Protoss" "spellcaster"
   "Sentry casts Force Field (1526) vs charging Zealots without spamming 8f later AND <=2/16 workers pull vs 1 lone scout Probe"
   (lambda ()
     (define home (mk-home-base-units 'Protoss #:workers 16))
     (define allies-s (append home (list (mk-unit 5501 'sentry 1 74.0 80.0 #:hp 40.0 #:hp-max 40.0 #:shield 40.0 #:shield-max 40.0 #:energy 125.0))
                              (for/list ([i (in-range 6)]) (mk-unit (+ 5510 i) 'stalker 1 73.5 (+ 77.5 (* i 0.9)) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))))
     (define enemies-z (for/list ([i (in-range 8)]) (mk-unit (+ 8501 i) 'zealot 4 79.0 (+ 78.0 (* i 0.6)) #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0)))
     (define outs-s (run-pipeline-sequence 'Protoss 'Protoss
                      (list (hash 'obs (mk-obs 10000 (append allies-s enemies-z) #:food-used 40 #:food-cap 66 #:food-army 24 #:food-workers 16))
                            (hash 'obs (mk-obs 10008 (append allies-s enemies-z) #:food-used 40 #:food-cap 66 #:food-army 24 #:food-workers 16)))))
     (define ff1? (wire-has-ability? (step-outcome-wire-cmds (first outs-s)) '(5501) AB-FORCE-FIELD))
     (define ff2? (wire-has-ability? (step-outcome-wire-cmds (second outs-s)) '(5501) AB-FORCE-FIELD))
     (define w-tags (for/list ([i (in-range 16)]) (+ 1100 i)))
     (define o-w (last (run-pipeline-sequence 'Protoss 'Protoss
                         (list (hash 'obs (mk-obs 2000 (append home (list (mk-unit 8601 'probe 4 29.0 32.0 #:hp 20.0 #:hp-max 20.0 #:shield 20.0 #:shield-max 20.0)))
                                                  #:food-used 16 #:food-cap 23 #:food-army 0 #:food-workers 16))))))
     (define w-pulled (+ (wire-count-tags-with-ability (step-outcome-wire-cmds o-w) w-tags AB-ATTACK)
                         (wire-count-tags-with-ability (step-outcome-wire-cmds o-w) w-tags AB-MOVE)))
     (define total-rej (+ (step-outcome-wire-rejects (first outs-s)) (step-outcome-wire-rejects (second outs-s)) (step-outcome-wire-rejects o-w)))
     (values (first outs-s)
             (list
              (mk-check "sentry-casts-ff-step1-and-no-spam-step2" (and ff1? (not ff2?)) (format "Sentry FF step1=~a step2=~a" ff1? ff2?))
              (mk-check "worker-pull-proportional-vs-1-scout-probe" (<= w-pulled 2) (format "Workers pulled vs 1 scout Probe=~a/16 (expected <=2)" w-pulled))
              (mk-check "zero-wire-rejects" (= total-rej 0) (format "wire_rejects=~a" total-rej)))))))

(define scen-novel-112
  (tactical-scenario
   "novel-112-macro-caster-buff-hygiene-chrono-and-inject"
   "novel" "Protoss" "Terran" "macro-spells"
   "Nexus Chrono Boost (3755) skips already-Chronoed (buff 281) & idle Gateways; Queen skips double-Inject (251) on buff-11 Hatchery"
   (lambda ()
     (define p-units
       (append
        (list (mk-unit 1001 'nexus 1 32.0 32.0 #:energy 100.0 #:buffs '(281) #:orders (list (sc2-unit-order 1006 #f 0 0.5)))
              (mk-unit 1005 'gateway 1 38.0 34.0 #:buffs '(281) #:orders (list (sc2-unit-order 917 #f 0 0.5)))
              (mk-unit 1006 'gateway 1 38.0 37.0))
        (for/list ([i (in-range 16)]) (mk-unit (+ 1100 i) 'probe 1 (+ 27.0 (* 0.3 (modulo i 6))) (+ 30.0 (* 0.4 (quotient i 6))) #:orders (list (sc2-unit-order AB-GATHER #f 90001 0.0))))))
     (define o-p (last (run-pipeline-sequence 'Protoss 'Terran (list (hash 'obs (mk-obs 4000 p-units #:minerals 50 #:vespene 0 #:food-used 20 #:food-cap 31 #:food-army 4 #:food-workers 16))))))
     (define z-units
       (append
        (list (mk-unit 1001 'hatchery 1 32.0 32.0 #:buffs '(11))
              (mk-unit 5201 'queen 1 34.0 32.0 #:hp 175.0 #:hp-max 175.0 #:energy 50.0))
        (for/list ([i (in-range 16)]) (mk-unit (+ 1100 i) 'drone 1 (+ 27.0 (* 0.3 (modulo i 6))) (+ 30.0 (* 0.4 (quotient i 6))) #:orders (list (sc2-unit-order AB-GATHER #f 90001 0.0))))))
     (define o-z (last (run-pipeline-sequence 'Zerg 'Terran (list (hash 'obs (mk-obs 4000 z-units #:food-used 20 #:food-cap 36 #:food-army 2 #:food-workers 16))))))
     (define bad-chrono? (wire-has-ability? (step-outcome-wire-cmds o-p) '(1001) AB-CHRONO-BOOST))
     (define bad-inject? (wire-has-ability? (step-outcome-wire-cmds o-z) '(5201) AB-INJECT-LARVA))
     (define total-rej (+ (step-outcome-wire-rejects o-p) (step-outcome-wire-rejects o-z)))
     (values o-p
             (list
              (mk-check "nexus-skips-chrono-on-buff281-and-idle" (not bad-chrono?) (format "Nexus wasted Chrono=~a" bad-chrono?))
              (mk-check "queen-skips-double-inject-on-buff11-hatch" (not bad-inject?) (format "Queen double-injected buff-11 Hatch=~a" bad-inject?))
              (mk-check "zero-wire-rejects" (= total-rej 0) (format "wire_rejects=~a" total-rej)))))))

(define scen-novel-113
  (tactical-scenario
   "novel-113-tank-unsiege-when-enemies-far-and-overlord-flee"
   "novel" "Terran" "Zerg" "positioning"
   "Sieged Tanks unsiege (390) when all enemies are 35t away AND Zerg Overlord flees (16 MOVE) upon spotting 4 Marines"
   (lambda ()
     (define home-t (mk-home-base-units 'Terran #:workers 16))
     (define o-t (last (run-pipeline-sequence 'Terran 'Zerg
                         (list (hash 'obs (mk-obs 12000 (append home-t
                                                                (list (mk-unit 5301 'siege-tank-sieged 1 70.0 80.0 #:hp 175.0 #:hp-max 175.0)
                                                                      (mk-unit 5302 'siege-tank-sieged 1 70.0 82.0 #:hp 175.0 #:hp-max 175.0))
                                                                (for/list ([i (in-range 8)]) (mk-unit (+ 5310 i) 'marine 1 72.0 (+ 78.0 (* i 0.7)) #:hp 45.0 #:hp-max 45.0))
                                                                (for/list ([i (in-range 6)]) (mk-unit (+ 8301 i) 'roach 4 105.0 (+ 80.0 (* i 0.9)) #:hp 145.0 #:hp-max 145.0)))
                                                  #:food-used 40 #:food-cap 66 #:food-army 24 #:food-workers 16))))))
     (define home-z (mk-home-base-units 'Zerg #:workers 16))
     (define o-z (last (run-pipeline-sequence 'Zerg 'Terran
                         (list (hash 'obs (mk-obs 5000 (append home-z
                                                               (list (mk-unit 5601 'overlord 1 78.0 80.0 #:hp 200.0 #:hp-max 200.0))
                                                               (for/list ([i (in-range 4)]) (mk-unit (+ 8601 i) 'marine 4 81.5 (+ 79.0 (* i 0.7)) #:hp 45.0 #:hp-max 45.0)))
                                                  #:food-used 16 #:food-cap 30 #:food-army 0 #:food-workers 16))))))
     (define unsieged (wire-count-tags-with-ability (step-outcome-wire-cmds o-t) '(5301 5302) AB-UNSIEGE-MODE))
     (define ovie-fled? (wire-has-ability? (step-outcome-wire-cmds o-z) '(5601) AB-MOVE))
     (define total-rej (+ (step-outcome-wire-rejects o-t) (step-outcome-wire-rejects o-z)))
     (values o-t
             (list
              (mk-check "sieged-tanks-unsiege-when-enemies-35t-away" (= unsieged 2) (format "Tanks unsieged=~a/2" unsieged))
              (mk-check "overlord-flees-from-4-marines" ovie-fled? (format "Overlord fled (MOVE)=~a" ovie-fled?))
              (mk-check "zero-wire-rejects" (= total-rej 0) (format "wire_rejects=~a" total-rej)))))))

;; -----------------------------------------------------------------------------
;; Tier 13: Wave-12 Verified Live-Pipeline Bug Reproductions (4)
;; -----------------------------------------------------------------------------
(define scen-w12-tac-1
  (tactical-scenario
   "w12-tac-1-oracle-revelation-single-cast-skip-buff49-and-no-weaponless-attack"
   "wave12-repro" "Protoss" "Protoss" "detection"
   "Wave-12 P0 (Oracle Revelation 2146): emit at most 1 Revelation on step 1 (no same-tick double-cast), 0 Revelation on step 2 when DT already carries buff 49 (oracle-revelation), and 0 ATTACK (23) for weaponless beam-off Oracle"
   (lambda ()
     (define home (mk-home-base-units 'Protoss #:workers 16))
     (define allies
       (append home
               (list (mk-unit 5201 'oracle 1 75.0 80.0 #:hp 100.0 #:hp-max 100.0 #:shield 60.0 #:shield-max 60.0 #:energy 100.0))
               (for/list ([i (in-range 6)]) (mk-unit (+ 5210 i) 'stalker 1 74.0 (+ 77.5 (* i 0.9)) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))))
     (define enemy1 (list (mk-unit 8201 'dark-templar 4 79.0 80.0 #:hp 40.0 #:hp-max 40.0 #:shield 80.0 #:shield-max 80.0 #:cloak 1)))
     (define enemy2 (list (mk-unit 8201 'dark-templar 4 79.0 80.0 #:hp 40.0 #:hp-max 40.0 #:shield 80.0 #:shield-max 80.0 #:cloak 2 #:buffs '(49))))
     (define outs
       (run-pipeline-sequence 'Protoss 'Protoss
         (list (hash 'obs (mk-obs 12200 (append allies enemy1) #:food-used 40 #:food-cap 66 #:food-army 24 #:food-workers 16))
               (hash 'obs (mk-obs 12208 (append allies enemy2) #:food-used 40 #:food-cap 66 #:food-army 24 #:food-workers 16)))))
     (define rev1-cnt (length (filter (lambda (c) (= (sc2-raw-unit-command-ability-id c) AB-ORACLE-REVELATION))
                                      (wire-cmds-for-tag (step-outcome-wire-cmds (first outs)) 5201))))
     (define rev2-cnt (length (filter (lambda (c) (= (sc2-raw-unit-command-ability-id c) AB-ORACLE-REVELATION))
                                      (wire-cmds-for-tag (step-outcome-wire-cmds (second outs)) 5201))))
     (define bad-atk2? (wire-has-ability? (step-outcome-wire-cmds (second outs)) '(5201) AB-ATTACK))
     (define total-rej (+ (step-outcome-wire-rejects (first outs)) (step-outcome-wire-rejects (second outs))))
     (values (second outs)
             (list
              (mk-check "oracle-single-revelation-step1-no-double-cast" (= rev1-cnt 1)
                        (format "Oracle emitted Revelation (2146) ~a times on step 1 (expected 1)" rev1-cnt))
              (mk-check "oracle-skips-revelation-on-already-revealed-buff49-step2" (= rev2-cnt 0)
                        (format "Oracle spammed Revelation (2146) ~a times on already-revealed buff-49 DT (expected 0)" rev2-cnt))
              (mk-check "weaponless-beam-off-oracle-never-emits-attack" (not bad-atk2?)
                        (format "Beam-off Oracle emitted suicide ATTACK (23): ~a (expected #f)" bad-atk2?))
              (mk-check "zero-wire-rejects" (= total-rej 0) (format "wire_rejects=~a" total-rej)))))))

(define scen-w12-tac-2
  (tactical-scenario
   "w12-tac-2-cyclones-skip-lock-on-on-already-locked-buff116-target"
   "wave12-repro" "Terran" "Protoss" "spellcaster"
   "Wave-12 P1 (unit-mode-micro.rkt:1963): Cyclones must NOT burn Lock-On (2350) onto an enemy that already carries buff 116 (lock-on)"
   (lambda ()
     (define home (mk-home-base-units 'Terran #:workers 16))
     (define allies (append home (list (mk-unit 5401 'cyclone 1 75.0 80.0 #:hp 120.0 #:hp-max 120.0)
                                       (mk-unit 5402 'cyclone 1 75.0 81.5 #:hp 120.0 #:hp-max 120.0))))
     (define enemies (list (mk-unit 8401 'immortal 4 81.0 80.0 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0 #:buffs '(116))))
     (define out (last (run-pipeline-sequence 'Terran 'Protoss (list (hash 'obs (mk-obs 10000 (append allies enemies) #:food-used 30 #:food-cap 50 #:food-army 14 #:food-workers 16))))))
     (define lock-cnt (wire-count-tags-with-ability (step-outcome-wire-cmds out) '(5401 5402) AB-LOCK-ON))
     (values out
             (list
              (mk-check "cyclones-skip-already-locked-buff116-immortal" (= lock-cnt 0)
                        (format "Cyclones cast Lock-On (2350) onto already-locked buff-116 Immortal=~a/2 (expected 0)" lock-cnt))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

(define scen-w12-tac-3
  (tactical-scenario
   "w12-tac-3-viking-assault-single-405-liftoff-no-same-tick-triple-spam"
   "wave12-repro" "Terran" "Zerg" "unit-modes"
   "Wave-12 P1 (unit-mode-micro + multitask-harass + bot-runtime): Viking Assault lifting off vs Mutalisks must emit at most 1 morph-viking-fighter (405) command per Viking on the same tick"
   (lambda ()
     (define home (mk-home-base-units 'Terran #:workers 16))
     (define allies (append home (list (mk-unit 5611 'viking-assault 1 75.0 80.0 #:hp 135.0 #:hp-max 135.0)
                                       (mk-unit 5612 'viking-assault 1 75.0 81.5 #:hp 135.0 #:hp-max 135.0))))
     (define enemies (for/list ([i (in-range 4)]) (mk-unit (+ 8611 i) 'mutalisk 4 80.0 (+ 78.5 (* i 0.9)) #:hp 120.0 #:hp-max 120.0)))
     (define out (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs (mk-obs 12600 (append allies enemies) #:food-used 36 #:food-cap 60 #:food-army 20 #:food-workers 16))))))
     (define v1-405 (length (filter (lambda (c) (= (sc2-raw-unit-command-ability-id c) AB-VIKING-FIGHTER)) (wire-cmds-for-tag (step-outcome-wire-cmds out) 5611))))
     (define v2-405 (length (filter (lambda (c) (= (sc2-raw-unit-command-ability-id c) AB-VIKING-FIGHTER)) (wire-cmds-for-tag (step-outcome-wire-cmds out) 5612))))
     (values out
             (list
              (mk-check "viking-5611-exactly-one-405-liftoff" (= v1-405 1)
                        (format "Viking 5611 received ~a morph-viking-fighter (405) cmds on 1 tick (expected 1)" v1-405))
              (mk-check "viking-5612-exactly-one-405-liftoff" (= v2-405 1)
                        (format "Viking 5612 received ~a morph-viking-fighter (405) cmds on 1 tick (expected 1)" v2-405))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

(define scen-w12-tac-4
  (tactical-scenario
   "w12-tac-4-voidray-prismatic-alignment-vs-armored-and-reaper-kd8-charge"
   "wave12-repro" "Protoss" "Terran" "unit-abilities"
   "Wave-12 P1 (unit abilities): Void Rays activate Prismatic Alignment (2393) vs Armored Battlecruisers (not Light Marines) AND Reaper throws KD8 Charge (2588) vs chasing Zerglings (t06)"
   (lambda ()
     ;; Part A: Void Rays vs Armored Battlecruisers (cast 2393) vs Light Marines (0 2393)
     (define home-p (mk-home-base-units 'Protoss #:workers 16))
     (define vrs (list (mk-unit 5101 'void-ray 1 75.0 80.0 #:hp 150.0 #:hp-max 150.0 #:shield 100.0 #:shield-max 100.0)
                       (mk-unit 5102 'void-ray 1 75.0 81.5 #:hp 150.0 #:hp-max 150.0 #:shield 100.0 #:shield-max 100.0)))
     (define bcs (list (mk-unit 8101 'battlecruiser 4 80.0 80.0 #:hp 550.0 #:hp-max 550.0)
                       (mk-unit 8102 'battlecruiser 4 80.0 82.0 #:hp 550.0 #:hp-max 550.0)))
     (define marines (for/list ([i (in-range 8)]) (mk-unit (+ 8121 i) 'marine 4 80.0 (+ 78.0 (* i 0.6)) #:hp 45.0 #:hp-max 45.0)))
     (define outs-vr
       (run-pipeline-sequence 'Protoss 'Terran
         (list (hash 'obs (mk-obs 12100 (append home-p vrs bcs) #:food-used 36 #:food-cap 60 #:food-army 20 #:food-workers 16))
               (hash 'obs (mk-obs 12108 (append home-p vrs bcs) #:food-used 36 #:food-cap 60 #:food-army 20 #:food-workers 16)))))
     (define out-vr-lgt (last (run-pipeline-sequence 'Protoss 'Terran
                                (list (hash 'obs (mk-obs 12100 (append home-p vrs marines) #:food-used 36 #:food-cap 60 #:food-army 20 #:food-workers 16))))))
     (define align1 (wire-count-tags-with-ability (step-outcome-wire-cmds (first outs-vr)) '(5101 5102) AB-PRISMATIC-ALIGNMENT))
     (define align2 (wire-count-tags-with-ability (step-outcome-wire-cmds (second outs-vr)) '(5101 5102) AB-PRISMATIC-ALIGNMENT))
     (define align-lgt (wire-count-tags-with-ability (step-outcome-wire-cmds out-vr-lgt) '(5101 5102) AB-PRISMATIC-ALIGNMENT))
     ;; Part B: Reaper + 4 Marines vs 10 chasing Zerglings (t06) — Reaper throws KD8 Charge (2588) on step 1, 0 spam 8f later
     (define home-t (mk-home-base-units 'Terran #:workers 16))
     (define t-allies (append home-t (list (mk-unit 5001 'reaper 1 75.0 80.0 #:hp 60.0 #:hp-max 60.0))
                              (for/list ([i (in-range 4)]) (mk-unit (+ 5010 i) 'marine 1 74.0 (+ 78.5 (* i 0.9)) #:hp 45.0 #:hp-max 45.0))))
     (define lings (for/list ([i (in-range 10)]) (mk-unit (+ 8001 i) 'zergling 4 79.0 (+ 78.0 (* i 0.5)) #:hp 35.0 #:hp-max 35.0)))
     (define outs-r
       (run-pipeline-sequence 'Terran 'Zerg
         (list (hash 'obs (mk-obs 4000 (append t-allies lings) #:food-used 24 #:food-cap 39 #:food-army 8 #:food-workers 16))
               (hash 'obs (mk-obs 4008 (append t-allies lings) #:food-used 24 #:food-cap 39 #:food-army 8 #:food-workers 16)))))
     (define kd8-1? (wire-has-ability? (step-outcome-wire-cmds (first outs-r)) '(5001) AB-KD8-CHARGE))
     (define kd8-2? (wire-has-ability? (step-outcome-wire-cmds (second outs-r)) '(5001) AB-KD8-CHARGE))
     (define total-rej (+ (step-outcome-wire-rejects (first outs-vr)) (step-outcome-wire-rejects (second outs-vr))
                          (step-outcome-wire-rejects out-vr-lgt) (step-outcome-wire-rejects (first outs-r)) (step-outcome-wire-rejects (second outs-r))))
     (values (first outs-vr)
             (list
              (mk-check "voidray-activates-prismatic-alignment-vs-armored-bcs" (and (>= align1 1) (= align2 0))
                        (format "VoidRay Prismatic Alignment step1=~a step2=~a (expected >=1 then 0)" align1 align2))
              (mk-check "voidray-skips-prismatic-alignment-vs-light-marines" (= align-lgt 0)
                        (format "VoidRay aligned vs Light Marines=~a (expected 0)" align-lgt))
              (mk-check "reaper-throws-kd8-charge-vs-chasing-lings-and-respects-cd" (and kd8-1? (not kd8-2?))
                        (format "Reaper KD8 Charge step1=~a step2=~a (expected #t then #f)" kd8-1? kd8-2?))
              (mk-check "zero-wire-rejects" (= total-rej 0) (format "wire_rejects=~a" total-rej)))))))


(define scen-w12-tac-5
  (tactical-scenario
   "w12-tac-5-territory-defense-29t-from-natural-not-suppressed-by-pullback"
   "wave12-repro" "Terran" "Zerg" "defense"
   "Wave-12 P0 (W12-P0-5 / lib/bot-runtime.rkt:23666 / #08): 8 Marines defending natural/Barracks at (64,34) vs 14 visible Roaches at (81,34) (29t from natural, inside territory!) must attack instead of falling into suppress-this-target? rally-retreat (ATK=0/8, MOV=8/8 -> 50,50)"
   (lambda ()
     (define home (mk-home-base-units 'Terran #:workers 24 #:with-natural? #t))
     (define m-tags (for/list ([i (in-range 8)]) (+ 6701 i)))
     (define allies
       (append home
               (list (mk-unit 1050 'barracks 1 60.0 34.0 #:hp 1000.0 #:hp-max 1000.0))
               (for/list ([i (in-range 8)]) (mk-unit (+ 6701 i) 'marine 1 64.0 (+ 31.0 (* i 0.8)) #:hp 45.0 #:hp-max 45.0))))
     (define enemies
       (for/list ([i (in-range 14)]) (mk-unit (+ 9701 i) 'roach 4 81.0 (+ 29.0 (* i 0.7)) #:hp 145.0 #:hp-max 145.0)))
     (define out
       (last (run-pipeline-sequence 'Terran 'Zerg
               (list (hash 'obs (mk-obs 10000 (append allies enemies)
                                        #:food-used 48 #:food-cap 80 #:food-army 24 #:food-workers 24))))))
     (define atk (wire-count-tags-with-ability (step-outcome-wire-cmds out) m-tags AB-ATTACK))
     (values out
             (list
              (mk-check "territory-defenders-engage-roaches-29t-from-natural" (>= atk 6)
                        (format "Terran natural defenders attacking Roaches 29t from natural=~a/8 (expected >=6)" atk))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))


;; -----------------------------------------------------------------------------
;; Round-13 Pro-Inspired Regression Shields (novel-114..122 -> Milestone 200!)
;; -----------------------------------------------------------------------------
(define scen-novel-114
  (tactical-scenario
   "novel-114-banshee-and-ghost-cloak-researched-activate-and-preserve"
   "novel" "Terran" "Terran" "cloak"
   "Researched Banshee (392) & Ghost (382) Cloak activate on step 1 while attacking and emit 0 duplicate cloak or decloak on step 2 with buffs 7/8 active"
   (lambda ()
     (define home (mk-home-base-units 'Terran #:workers 16))
     (define enemy (for/list ([i (in-range 6)]) (mk-unit (+ 8301 i) 'marine 4 79.0 (+ 78.0 (* i 0.6)) #:hp 45.0 #:hp-max 45.0)))
     (define ally1 (append home (list (mk-unit 5301 'banshee 1 75.0 80.0 #:hp 60.0 #:hp-max 140.0 #:energy 100.0)
                                      (mk-unit 5302 'ghost 1 75.0 82.0 #:hp 40.0 #:hp-max 100.0 #:energy 100.0))))
     (define ally2 (append home (list (mk-unit 5301 'banshee 1 75.0 80.0 #:hp 60.0 #:hp-max 140.0 #:energy 70.0 #:cloak 1 #:buffs '(7))
                                      (mk-unit 5302 'ghost 1 75.0 82.0 #:hp 40.0 #:hp-max 100.0 #:energy 70.0 #:cloak 1 #:buffs '(6)))))
     (define outs
       (run-pipeline-sequence 'Terran 'Terran
         (list (hash 'obs (mk-obs 12000 (append ally1 enemy) #:upgrades '(banshee-cloak personal-cloaking) #:food-used 30 #:food-cap 50 #:food-army 14 #:food-workers 16))
               (hash 'obs (mk-obs 12008 (append ally2 enemy) #:upgrades '(banshee-cloak personal-cloaking) #:food-used 30 #:food-cap 50 #:food-army 14 #:food-workers 16)))))
     (define b-clk1? (wire-has-ability? (step-outcome-wire-cmds (first outs)) '(5301) AB-CLOAK-BANSHEE))
     (define g-clk1? (wire-has-ability? (step-outcome-wire-cmds (first outs)) '(5302) AB-CLOAK-GHOST))
     (define bad-clk2? (wire-any-ability? (step-outcome-wire-cmds (second outs)) '(5301 5302) (list AB-CLOAK-BANSHEE AB-CLOAK-GHOST AB-DECLOAK-BANSHEE AB-DECLOAK-GHOST)))
     (define total-rej (+ (step-outcome-wire-rejects (first outs)) (step-outcome-wire-rejects (second outs))))
     (values (second outs)
             (list
              (mk-check "banshee-and-ghost-cloak-step1" (and b-clk1? g-clk1?) (format "step1 banshee-cloak=~a ghost-cloak=~a" b-clk1? g-clk1?))
              (mk-check "no-duplicate-cloak-or-decloak-step2" (not bad-clk2?) (format "step2 cloak/decloak spam=~a" bad-clk2?))
              (mk-check "zero-wire-rejects" (= total-rej 0) (format "wire_rejects=~a" total-rej)))))))

(define scen-novel-115
  (tactical-scenario
   "novel-115-marine-stimpack-skips-buff27-and-critical-12hp"
   "novel" "Terran" "Zerg" "spellcaster"
   "Marines emit 0 re-stim when already carrying buff 27 (stimpack) AND 0 suicide-stim at critical 12/45 HP while all 8 engage"
   (lambda ()
     (define home (mk-home-base-units 'Terran #:workers 16))
     (define enemy (for/list ([i (in-range 6)]) (mk-unit (+ 8401 i) 'roach 4 80.0 (+ 78.0 (* i 0.8)) #:hp 145.0 #:hp-max 145.0)))
     (define tags1 (for/list ([i (in-range 8)]) (+ 5401 i)))
     (define tags2 (for/list ([i (in-range 8)]) (+ 5411 i)))
     (define o1 (last (run-pipeline-sequence 'Terran 'Zerg
                        (list (hash 'obs (mk-obs 10000 (append home (for/list ([i (in-range 8)]) (mk-unit (+ 5401 i) 'marine 1 75.0 (+ 77.5 (* i 0.7)) #:hp 35.0 #:hp-max 45.0 #:buffs '(27))) enemy)
                                                 #:upgrades '(stimpack) #:food-used 32 #:food-cap 54 #:food-army 16 #:food-workers 16))))))
     (define o2 (last (run-pipeline-sequence 'Terran 'Zerg
                        (list (hash 'obs (mk-obs 10000 (append home (for/list ([i (in-range 8)]) (mk-unit (+ 5411 i) 'marine 1 75.0 (+ 77.5 (* i 0.7)) #:hp 12.0 #:hp-max 45.0)) enemy)
                                                 #:upgrades '(stimpack) #:food-used 32 #:food-cap 54 #:food-army 16 #:food-workers 16))))))
     (define bad-st1? (wire-any-ability? (step-outcome-wire-cmds o1) tags1 (list AB-STIMPACK AB-STIM-ALT)))
     (define bad-st2? (wire-any-ability? (step-outcome-wire-cmds o2) tags2 (list AB-STIMPACK AB-STIM-ALT)))
     (define atk1 (wire-count-tags-with-ability (step-outcome-wire-cmds o1) tags1 AB-ATTACK))
     (define atk2 (wire-count-tags-with-ability (step-outcome-wire-cmds o2) tags2 AB-ATTACK))
     (define total-rej (+ (step-outcome-wire-rejects o1) (step-outcome-wire-rejects o2)))
     (values o2
             (list
              (mk-check "no-restim-on-buff27-marines" (not bad-st1?) (format "re-stimmed buff-27 Marines=~a" bad-st1?))
              (mk-check "no-suicide-stim-on-12hp-marines" (not bad-st2?) (format "suicide-stimmed 12HP Marines=~a" bad-st2?))
              (mk-check "both-marine-squads-engage" (and (>= atk1 6) (>= atk2 6)) (format "ATK buff27=~a/8 lowHP=~a/8" atk1 atk2))
              (mk-check "zero-wire-rejects" (= total-rej 0) (format "wire_rejects=~a" total-rej)))))))

(define scen-novel-116
  (tactical-scenario
   "novel-116-infestors-vs-skytoss-split-fungal-neural-no-4.11-shroud"
   "novel" "Zerg" "Protoss" "spellcaster"
   "Two Infestors vs Carriers + Void Rays split Fungal Growth (74) and Neural Parasite (249) with 0 Microbial Shroud (4111)"
   (lambda ()
     (define home (mk-home-base-units 'Zerg #:workers 16))
     (define allies (append home
                            (list (mk-unit 5201 'infestor 1 75.0 80.0 #:hp 90.0 #:hp-max 90.0 #:energy 150.0)
                                  (mk-unit 5202 'infestor 1 75.0 81.5 #:hp 90.0 #:hp-max 90.0 #:energy 150.0))
                            (for/list ([i (in-range 8)]) (mk-unit (+ 5210 i) 'hydralisk 1 76.0 (+ 77.0 (* i 0.8)) #:hp 90.0 #:hp-max 90.0))))
     (define enemies (append (for/list ([i (in-range 3)]) (mk-unit (+ 8201 i) 'carrier 4 82.0 (+ 78.5 (* i 1.5)) #:hp 300.0 #:hp-max 300.0 #:shield 150.0 #:shield-max 150.0))
                             (for/list ([i (in-range 3)]) (mk-unit (+ 8210 i) 'void-ray 4 81.0 (+ 78.5 (* i 1.2)) #:hp 150.0 #:hp-max 150.0 #:shield 100.0 #:shield-max 100.0))))
     (define out (last (run-pipeline-sequence 'Zerg 'Protoss
                         (list (hash 'obs (mk-obs 14000 (append allies enemies) #:upgrades '(neural-parasite) #:food-used 46 #:food-cap 66 #:food-army 30 #:food-workers 16))))))
     (define wcmds (step-outcome-wire-cmds out))
     (define fung? (wire-has-ability? wcmds '(5201 5202) AB-FUNGAL-GROWTH))
     (define neur? (wire-has-ability? wcmds '(5201 5202) AB-NEURAL-PARASITE))
     (define shroud? (wire-has-ability? wcmds '(5201 5202) AB-MICROBIAL-SHROUD))
     (values out
             (list
              (mk-check "infestors-cast-fungal-and-neural" (and fung? neur?) (format "Fungal=~a Neural=~a" fung? neur?))
              (mk-check "zero-4.11-microbial-shroud-on-4.10.0" (not shroud?) (format "Microbial Shroud (4111)=~a" shroud?))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0) (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

(define scen-novel-117
  (tactical-scenario
   "novel-117-protoss-tempest-carrier-dt-engage-and-build-interceptors"
   "novel" "Protoss" "Terran" "late-game"
   "Tempest, Carrier, and Dark Templar all engage enemy Marauders cleanly AND Carrier builds Interceptors (1042)"
   (lambda ()
     (define home (mk-home-base-units 'Protoss #:workers 16))
     (define allies (append home (list (mk-unit 5501 'tempest 1 72.0 80.0 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0)
                                       (mk-unit 5502 'carrier 1 74.0 80.0 #:hp 300.0 #:hp-max 300.0 #:shield 150.0 #:shield-max 150.0)
                                       (mk-unit 5503 'dark-templar 1 78.0 80.0 #:hp 40.0 #:hp-max 40.0 #:shield 80.0 #:shield-max 80.0 #:cloak 1))))
     (define enemies (for/list ([i (in-range 6)]) (mk-unit (+ 8501 i) 'marauder 4 82.0 (+ 78.0 (* i 0.9)) #:hp 125.0 #:hp-max 125.0)))
     (define out (last (run-pipeline-sequence 'Protoss 'Terran (list (hash 'obs (mk-obs 15000 (append allies enemies) #:food-used 40 #:food-cap 66 #:food-army 24 #:food-workers 16))))))
     (define wcmds (step-outcome-wire-cmds out))
     (define atk (wire-count-tags-with-ability wcmds '(5501 5502 5503) AB-ATTACK))
     (define inter? (wire-has-ability? wcmds '(5502) AB-BUILD-INTERCEPTORS))
     (values out
             (list
              (mk-check "tempest-carrier-dt-all-engage" (= atk 3) (format "Attackers=~a/3" atk))
              (mk-check "carrier-queues-interceptors-1042" inter? (format "Carrier 1042=~a" inter?))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0) (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

(define scen-novel-118
  (tactical-scenario
   "novel-118-protoss-mothership-and-tempests-commit"
   "novel" "Protoss" "Terran" "late-game"
   "Mothership and 4 Tempests commit cleanly to attacking 12 Marines with zero passive stall"
   (lambda ()
     (define home (mk-home-base-units 'Protoss #:workers 16))
     (define tags '(5201 5210 5211 5212 5213))
     (define allies (append home (list (mk-unit 5201 'mothership 1 74.0 80.0 #:hp 350.0 #:hp-max 350.0 #:shield 350.0 #:shield-max 350.0 #:energy 150.0))
                            (for/list ([i (in-range 4)]) (mk-unit (+ 5210 i) 'tempest 1 73.0 (+ 78.0 (* i 1.2)) #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0))))
     (define enemies (for/list ([i (in-range 12)]) (mk-unit (+ 8201 i) 'marine 4 81.0 (+ 77.0 (* i 0.5)) #:hp 45.0 #:hp-max 45.0)))
     (define out (last (run-pipeline-sequence 'Protoss 'Terran (list (hash 'obs (mk-obs 16000 (append allies enemies) #:food-used 52 #:food-cap 80 #:food-army 36 #:food-workers 16))))))
     (define atk (wire-count-tags-with-ability (step-outcome-wire-cmds out) tags AB-ATTACK))
     (values out
             (list
              (mk-check "mothership-and-tempests-all-attack" (= atk 5) (format "Attackers=~a/5" atk))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0) (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

(define scen-novel-119
  (tactical-scenario
   "novel-119-zerg-corruptors-focus-carriers-ignoring-ground-zealots"
   "novel" "Zerg" "Protoss" "anti-air"
   "8 Zerg Corruptors focus-fire 3 enemy Carriers directly without stalling on 6 ground Zealots"
   (lambda ()
     (define home (mk-home-base-units 'Zerg #:workers 16))
     (define tags (for/list ([i (in-range 8)]) (+ 5101 i)))
     (define allies (append home (for/list ([i (in-range 8)]) (mk-unit (+ 5101 i) 'corruptor 1 75.0 (+ 77.0 (* i 0.8)) #:hp 200.0 #:hp-max 200.0))))
     (define enemies (append (for/list ([i (in-range 3)]) (mk-unit (+ 8101 i) 'carrier 4 81.0 (+ 78.5 (* i 1.2)) #:hp 300.0 #:hp-max 300.0 #:shield 150.0 #:shield-max 150.0))
                             (for/list ([i (in-range 6)]) (mk-unit (+ 8110 i) 'zealot 4 79.0 (+ 78.0 (* i 0.7)) #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0))))
     (define out (last (run-pipeline-sequence 'Zerg 'Protoss (list (hash 'obs (mk-obs 14000 (append allies enemies) #:food-used 46 #:food-cap 66 #:food-army 30 #:food-workers 16))))))
     (define tgts (wire-targets-for-tags (step-outcome-wire-cmds out) tags AB-ATTACK))
     (define hit-carr (for/sum ([t (in-list tgts)]) (if (memv (second t) '(8101 8102 8103)) (length (first t)) 0)))
     (values out
             (list
              (mk-check "corruptors-focus-air-carriers" (= hit-carr 8) (format "Corruptors attacking Carriers=~a/8" hit-carr))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0) (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

(define scen-novel-120
  (tactical-scenario
   "novel-120-zerg-broodlords-and-mutalisks-engage-marauders"
   "novel" "Zerg" "Terran" "late-game"
   "2 Brood Lords and 2 Mutalisks all engage ground Marauders cleanly with zero retreat"
   (lambda ()
     (define home (mk-home-base-units 'Zerg #:workers 16))
     (define tags '(5511 5512 5513 5514))
     (define allies (append home (list (mk-unit 5511 'brood-lord 1 73.0 80.0 #:hp 225.0 #:hp-max 225.0)
                                       (mk-unit 5512 'brood-lord 1 73.0 82.0 #:hp 225.0 #:hp-max 225.0)
                                       (mk-unit 5513 'mutalisk 1 76.0 79.0 #:hp 120.0 #:hp-max 120.0)
                                       (mk-unit 5514 'mutalisk 1 76.0 81.0 #:hp 120.0 #:hp-max 120.0))))
     (define enemies (for/list ([i (in-range 6)]) (mk-unit (+ 8501 i) 'marauder 4 82.0 (+ 78.0 (* i 0.9)) #:hp 125.0 #:hp-max 125.0)))
     (define out (last (run-pipeline-sequence 'Zerg 'Terran (list (hash 'obs (mk-obs 15000 (append allies enemies) #:food-used 40 #:food-cap 66 #:food-army 24 #:food-workers 16))))))
     (define atk (wire-count-tags-with-ability (step-outcome-wire-cmds out) tags AB-ATTACK))
     (values out
             (list
              (mk-check "broodlords-and-mutas-all-attack" (= atk 4) (format "Attackers=~a/4" atk))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0) (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

(define scen-novel-121
  (tactical-scenario
   "novel-121-terran-hellbats-roast-zerglings"
   "novel" "Terran" "Zerg" "melee"
   "4 Terran Hellbats (hellion-tank) cleanly engage 12 Zerglings with 100% attack commitment"
   (lambda ()
     (define home (mk-home-base-units 'Terran #:workers 16))
     (define tags '(5521 5522 5523 5524))
     (define allies (append home (for/list ([i (in-range 4)]) (mk-unit (+ 5521 i) 'hellion-tank 1 76.0 (+ 78.5 (* i 0.9)) #:hp 135.0 #:hp-max 135.0))))
     (define enemies (for/list ([i (in-range 12)]) (mk-unit (+ 8521 i) 'zergling 4 80.0 (+ 77.5 (* i 0.5)) #:hp 35.0 #:hp-max 35.0)))
     (define out (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs (mk-obs 9000 (append allies enemies) #:food-used 32 #:food-cap 54 #:food-army 16 #:food-workers 16))))))
     (define atk (wire-count-tags-with-ability (step-outcome-wire-cmds out) tags AB-ATTACK))
     (values out
             (list
              (mk-check "hellbats-all-attack-zerglings" (= atk 4) (format "Hellbat attackers=~a/4" atk))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0) (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

(define scen-novel-122
  (tactical-scenario
   "novel-122-terran-battlecruisers-engage-carriers"
   "novel" "Terran" "Protoss" "late-game"
   "2 Terran Battlecruisers cleanly engage 2 Protoss Carriers with zero retreat"
   (lambda ()
     (define home (mk-home-base-units 'Terran #:workers 16))
     (define allies (append home (list (mk-unit 5301 'battlecruiser 1 75.0 79.0 #:hp 550.0 #:hp-max 550.0)
                                       (mk-unit 5302 'battlecruiser 1 75.0 81.0 #:hp 550.0 #:hp-max 550.0))))
     (define enemies (list (mk-unit 8301 'carrier 4 81.0 79.0 #:hp 300.0 #:hp-max 300.0 #:shield 150.0 #:shield-max 150.0)
                           (mk-unit 8302 'carrier 4 81.0 81.0 #:hp 300.0 #:hp-max 300.0 #:shield 150.0 #:shield-max 150.0)))
     (define out (last (run-pipeline-sequence 'Terran 'Protoss (list (hash 'obs (mk-obs 16000 (append allies enemies) #:upgrades '(yamato-cannon) #:food-used 46 #:food-cap 66 #:food-army 30 #:food-workers 16))))))
     (define atk (wire-count-tags-with-ability (step-outcome-wire-cmds out) '(5301 5302) AB-ATTACK))
     (values out
             (list
              (mk-check "battlecruisers-both-engage-carriers" (= atk 2) (format "BC attackers=~a/2" atk))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0) (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; -----------------------------------------------------------------------------
;; Round-14 Final Ship-Gate Pro Regression Shields (novel-123..130 -> 204 Total!)
;; -----------------------------------------------------------------------------
(define scen-novel-123
  (tactical-scenario
   "novel-123-ht-archon-merge-when-dry-safe-and-storm-when-full-energy"
   "novel" "Protoss" "Terran" "spellcaster"
   "Two spent 10-energy HTs safely at 14t merge into an Archon (1766), while 125-energy HTs cast Psi Storm (1036) instead of merging"
   (lambda ()
     (define home (mk-home-base-units 'Protoss #:workers 16))
     (define o-dry
       (last (run-pipeline-sequence 'Protoss 'Terran
               (list (hash 'obs (mk-obs 12000
                                        (append home
                                                (list (mk-unit 5001 'high-templar 1 70.0 80.0 #:hp 40.0 #:hp-max 40.0 #:shield 40.0 #:shield-max 40.0 #:energy 10.0)
                                                      (mk-unit 5002 'high-templar 1 70.0 81.2 #:hp 40.0 #:hp-max 40.0 #:shield 40.0 #:shield-max 40.0 #:energy 10.0))
                                                (for/list ([i (in-range 6)]) (mk-unit (+ 8001 i) 'marine 4 84.0 (+ 78.0 (* i 0.7)) #:hp 45.0 #:hp-max 45.0)))
                                        #:upgrades '(psi-storm) #:food-used 32 #:food-cap 54 #:food-army 16 #:food-workers 16))))))
     (define o-hi
       (last (run-pipeline-sequence 'Protoss 'Terran
               (list (hash 'obs (mk-obs 12000
                                        (append home
                                                (list (mk-unit 5021 'high-templar 1 74.0 80.0 #:hp 40.0 #:hp-max 40.0 #:shield 40.0 #:shield-max 40.0 #:energy 125.0)
                                                      (mk-unit 5022 'high-templar 1 74.0 81.2 #:hp 40.0 #:hp-max 40.0 #:shield 40.0 #:shield-max 40.0 #:energy 125.0))
                                                (for/list ([i (in-range 6)]) (mk-unit (+ 5030 i) 'stalker 1 75.5 (+ 77.5 (* i 0.9)) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))
                                                (for/list ([i (in-range 8)]) (mk-unit (+ 8021 i) 'marine 4 81.0 (+ 77.5 (* i 0.7)) #:hp 45.0 #:hp-max 45.0)))
                                        #:upgrades '(psi-storm) #:food-used 40 #:food-cap 66 #:food-army 24 #:food-workers 16))))))
     (define merged? (wire-has-ability? (step-outcome-wire-cmds o-dry) '(5001 5002) AB-MORPH-ARCHON))
     (define hi-merged? (wire-has-ability? (step-outcome-wire-cmds o-hi) '(5021 5022) AB-MORPH-ARCHON))
     (define hi-storm? (wire-has-ability? (step-outcome-wire-cmds o-hi) '(5021 5022) AB-PSI-STORM))
     (define total-rej (+ (step-outcome-wire-rejects o-dry) (step-outcome-wire-rejects o-hi)))
     (values o-dry
             (list
              (mk-check "dry-safe-hts-merge-archon-1766" merged? (format "Dry HT Archon merge=~a" merged?))
              (mk-check "full-energy-hts-storm-not-merge" (and hi-storm? (not hi-merged?)) (format "125en HT storm=~a merge=~a" hi-storm? hi-merged?))
              (mk-check "zero-wire-rejects" (= total-rej 0) (format "wire_rejects=~a" total-rej)))))))

(define scen-novel-124
  (tactical-scenario
   "novel-124-oracle-pulsar-beam-on-vs-workers-and-off-after-dwell-safe"
   "novel" "Protoss" "Terran" "harass"
   "Oracle activates Pulsar Beam (2375) near enemy workers and deactivates Pulsar Beam (2376) after 120f dwell when no enemies are nearby"
   (lambda ()
     (define home (mk-home-base-units 'Protoss #:workers 16))
     (define o-on
       (last (run-pipeline-sequence 'Protoss 'Terran
               (list (hash 'obs (mk-obs 7000
                                        (append home
                                                (list (mk-unit 5101 'oracle 1 155.0 158.0 #:hp 100.0 #:hp-max 100.0 #:shield 60.0 #:shield-max 60.0 #:energy 80.0))
                                                (for/list ([i (in-range 8)]) (mk-unit (+ 8101 i) 'scv 4 159.0 (+ 156.0 (* i 0.5)) #:hp 45.0 #:hp-max 45.0)))
                                        #:food-used 20 #:food-cap 31 #:food-army 4 #:food-workers 16))))))
     (define ally-off (append home (list (mk-unit 5111 'oracle 1 70.0 70.0 #:hp 100.0 #:hp-max 100.0 #:shield 60.0 #:shield-max 60.0 #:energy 60.0 #:buffs '(99)))))
     (define outs-off
       (run-pipeline-sequence 'Protoss 'Terran
         (list (hash 'obs (mk-obs 7200 ally-off #:food-used 20 #:food-cap 31 #:food-army 4 #:food-workers 16))
               (hash 'obs (mk-obs 7320 ally-off #:food-used 20 #:food-cap 31 #:food-army 4 #:food-workers 16)))))
     (define on?  (wire-has-ability? (step-outcome-wire-cmds o-on) '(5101) AB-PULSAR-BEAM-ON))
     (define off? (wire-has-ability? (step-outcome-wire-cmds (second outs-off)) '(5111) AB-PULSAR-BEAM-OFF))
     (define total-rej (+ (step-outcome-wire-rejects o-on) (step-outcome-wire-rejects (first outs-off)) (step-outcome-wire-rejects (second outs-off))))
     (values (second outs-off)
             (list
              (mk-check "oracle-turns-pulsar-beam-on-near-workers" on? (format "Pulsar Beam ON (2375)=~a" on?))
              (mk-check "oracle-turns-pulsar-beam-off-when-safe-after-dwell" off? (format "Pulsar Beam OFF (2376)=~a" off?))
              (mk-check "zero-wire-rejects" (= total-rej 0) (format "wire_rejects=~a" total-rej)))))))

(define scen-novel-125
  (tactical-scenario
   "novel-125-vipers-split-blinding-cloud-abduct-and-safe-consume"
   "novel" "Zerg" "Terran" "spellcaster"
   "Two Vipers vs 3 unblinded Sieged Tanks split Blinding Cloud (2063) + Abduct (2067) AND low-energy (30en) Viper safely Consumes (2073) home building"
   (lambda ()
     (define home (mk-home-base-units 'Zerg #:workers 16))
     (define o-tanks
       (last (run-pipeline-sequence 'Zerg 'Terran
               (list (hash 'obs (mk-obs 14000
                                        (append home
                                                (list (mk-unit 5201 'viper 1 75.0 79.5 #:hp 150.0 #:hp-max 150.0 #:energy 120.0)
                                                      (mk-unit 5202 'viper 1 75.0 81.5 #:hp 150.0 #:hp-max 150.0 #:energy 120.0))
                                                (for/list ([i (in-range 8)]) (mk-unit (+ 5210 i) 'roach 1 76.0 (+ 77.0 (* i 0.8)) #:hp 145.0 #:hp-max 145.0))
                                                (list (mk-unit 8201 'siege-tank-sieged 4 82.0 79.5 #:hp 175.0 #:hp-max 175.0)
                                                      (mk-unit 8202 'siege-tank-sieged 4 82.0 80.5 #:hp 175.0 #:hp-max 175.0)
                                                      (mk-unit 8203 'siege-tank-sieged 4 82.0 81.5 #:hp 175.0 #:hp-max 175.0)))
                                        #:food-used 46 #:food-cap 66 #:food-army 30 #:food-workers 16))))))
     (define o-con
       (last (run-pipeline-sequence 'Zerg 'Terran
               (list (hash 'obs (mk-obs 14000
                                        (append home
                                                (list (mk-unit 5221 'viper 1 36.0 34.0 #:hp 150.0 #:hp-max 150.0 #:energy 30.0)
                                                      (mk-unit 5222 'evolution-chamber 1 38.0 34.0 #:hp 750.0 #:hp-max 750.0)))
                                        #:food-used 30 #:food-cap 50 #:food-army 6 #:food-workers 16))))))
     (define bc-cnt (wire-count-tags-with-ability (step-outcome-wire-cmds o-tanks) '(5201 5202) AB-BLINDING-CLOUD))
     (define ab-cnt (wire-count-tags-with-ability (step-outcome-wire-cmds o-tanks) '(5201 5202) AB-ABDUCT))
     (define con?   (wire-has-ability? (step-outcome-wire-cmds o-con) '(5221) AB-VIPER-CONSUME))
     (define total-rej (+ (step-outcome-wire-rejects o-tanks) (step-outcome-wire-rejects o-con)))
     (values o-tanks
             (list
              (mk-check "two-vipers-split-blinding-cloud-and-abduct" (and (= bc-cnt 1) (= ab-cnt 1))
                        (format "Viper BlindingCloud=~a Abduct=~a (expected 1 and 1)" bc-cnt ab-cnt))
              (mk-check "lowen-viper-consumes-home-structure" con? (format "Viper Consume (2073)=~a" con?))
              (mk-check "zero-wire-rejects" (= total-rej 0) (format "wire_rejects=~a" total-rej)))))))

(define scen-novel-126
  (tactical-scenario
   "novel-126-crawlers-stay-rooted-under-attack-and-creep-tumor-spreads"
   "novel" "Zerg" "Protoss" "defense"
   "Spine & Spore Crawlers stay rooted under Zealot + Oracle attack (0 uproot 1725/1727) AND active Creep Tumor spreads creep (1733)"
   (lambda ()
     (define home (mk-home-base-units 'Zerg #:workers 16 #:with-natural? #t))
     (define o-def
       (last (run-pipeline-sequence 'Zerg 'Protoss
               (list (hash 'obs (mk-obs 8000
                                        (append home
                                                (list (mk-unit 5301 'spine-crawler 1 56.0 32.0 #:hp 300.0 #:hp-max 300.0)
                                                      (mk-unit 5302 'spore-crawler 1 54.0 34.0 #:hp 400.0 #:hp-max 400.0))
                                                (for/list ([i (in-range 6)]) (mk-unit (+ 8301 i) 'zealot 4 59.0 (+ 30.0 (* i 0.7)) #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0))
                                                (list (mk-unit 8310 'oracle 4 56.0 36.0 #:hp 100.0 #:hp-max 100.0 #:shield 60.0 #:shield-max 60.0)))
                                        #:food-used 24 #:food-cap 44 #:food-army 0 #:food-workers 16))))))
     (define o-crp
       (last (run-pipeline-sequence 'Zerg 'Terran
               (list (hash 'obs (mk-obs 6000
                                        (append (mk-home-base-units 'Zerg #:workers 16)
                                                (list (mk-unit 5701 'creep-tumor-burrowed 1 42.0 42.0 #:hp 50.0 #:hp-max 50.0 #:burrowed? #t)))
                                        #:food-used 20 #:food-cap 36 #:food-army 0 #:food-workers 16))))))
     (define bad-uproot? (wire-any-ability? (step-outcome-wire-cmds o-def) '(5301 5302) (list AB-UPROOT-SPINE AB-UPROOT-SPORE)))
     (define spread?     (wire-has-ability? (step-outcome-wire-cmds o-crp) '(5701) AB-CREEP-TUMOR-TUMOR))
     (define total-rej (+ (step-outcome-wire-rejects o-def) (step-outcome-wire-rejects o-crp)))
     (values o-def
             (list
              (mk-check "crawlers-stay-rooted-under-attack" (not bad-uproot?) (format "Crawlers uprooted under attack=~a" bad-uproot?))
              (mk-check "creep-tumor-spreads-creep-1733" spread? (format "Creep Tumor emitted 1733=~a" spread?))
              (mk-check "zero-wire-rejects" (= total-rej 0) (format "wire_rejects=~a" total-rej)))))))

(define scen-novel-127
  (tactical-scenario
   "novel-127-planetary-fortress-and-scvs-repair-35pct-thor"
   "novel" "Terran" "Zerg" "defense"
   "SCVs auto-repair (3685/316) critically injured 35%-HP Thor beside Planetary Fortress while Thor engages Roaches"
   (lambda ()
     (define allies
       (append (list (mk-unit 1001 'planetary-fortress 1 52.0 32.0 #:hp 900.0 #:hp-max 1500.0)
                     (mk-unit 5401 'thor 1 56.0 32.0 #:hp 140.0 #:hp-max 400.0)
                     (mk-unit 5402 'scv 1 54.5 32.0 #:hp 45.0 #:hp-max 45.0)
                     (mk-unit 5403 'scv 1 54.5 33.0 #:hp 45.0 #:hp-max 45.0))
               (for/list ([i (in-range 12)])
                 (mk-unit (+ 1100 i) 'scv 1 (+ 48.0 (* 0.4 (modulo i 4))) (+ 30.0 (* 0.4 (quotient i 4)))
                          #:orders (list (sc2-unit-order AB-GATHER #f 90011 0.0))))))
     (define enemies (for/list ([i (in-range 8)]) (mk-unit (+ 8401 i) 'roach 4 59.0 (+ 30.0 (* i 0.7)) #:hp 145.0 #:hp-max 145.0)))
     (define out (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs (mk-obs 12000 (append allies enemies) #:food-used 36 #:food-cap 66 #:food-army 12 #:food-workers 14))))))
     (define wcmds (step-outcome-wire-cmds out))
     (define rep-cnt (+ (wire-count-tags-with-ability wcmds '(5402 5403) AB-REPAIR-GENERIC)
                        (wire-count-tags-with-ability wcmds '(5402 5403) AB-REPAIR-SCV)))
     (define thor-atk? (wire-has-ability? wcmds '(5401) AB-ATTACK))
     (values out
             (list
              (mk-check "scvs-auto-repair-injured-thor" (>= rep-cnt 1) (format "SCVs repairing Thor=~a/2" rep-cnt))
              (mk-check "thor-keeps-engaging-roaches" thor-atk? (format "Thor attacking=~a" thor-atk?))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0) (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

(define scen-novel-128
  (tactical-scenario
   "novel-128-supply-depot-wall-raises-vs-lings-and-lowers-when-safe"
   "novel" "Terran" "Zerg" "defense"
   "Lowered Supply Depot raises (558) when Zerglings rush within 4t AND raised Supply Depot lowers (556) when safe for army exit"
   (lambda ()
     (define home (mk-home-base-units 'Terran #:workers 16))
     (define marines (for/list ([i (in-range 4)]) (mk-unit (+ 5610 i) 'marine 1 40.0 (+ 33.0 (* i 0.6)) #:hp 45.0 #:hp-max 45.0)))
     (define lings   (for/list ([i (in-range 6)]) (mk-unit (+ 8601 i) 'zergling 4 46.0 (+ 33.0 (* i 0.5)) #:hp 35.0 #:hp-max 35.0)))
     (define o-up (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs (mk-obs 5000 (append home (list (mk-unit 5601 'supply-depot-lowered 1 42.0 34.0 #:hp 400.0 #:hp-max 400.0)) marines lings) #:food-used 24 #:food-cap 39 #:food-army 4 #:food-workers 16))))))
     (define o-dn (last (run-pipeline-sequence 'Terran 'Zerg (list (hash 'obs (mk-obs 5000 (append home (list (mk-unit 5602 'supply-depot 1 42.0 34.0 #:hp 400.0 #:hp-max 400.0)) marines) #:food-used 24 #:food-cap 39 #:food-army 4 #:food-workers 16))))))
     (define raised?  (wire-has-ability? (step-outcome-wire-cmds o-up) '(5601) AB-DEPOT-RAISE))
     (define lowered? (wire-has-ability? (step-outcome-wire-cmds o-dn) '(5602) AB-DEPOT-LOWER))
     (define total-rej (+ (step-outcome-wire-rejects o-up) (step-outcome-wire-rejects o-dn)))
     (values o-up
             (list
              (mk-check "lowered-depot-raises-558-vs-lings" raised? (format "Depot raised (558)=~a" raised?))
              (mk-check "raised-depot-lowers-556-when-safe" lowered? (format "Depot lowered (556)=~a" lowered?))
              (mk-check "zero-wire-rejects" (= total-rej 0) (format "wire_rejects=~a" total-rej)))))))

(define scen-novel-129
  (tactical-scenario
   "novel-129-zero-energy-protoss-casters-emit-zero-invalid-spells"
   "novel" "Protoss" "Terran" "wire-hygiene"
   "0-energy High Templar, Sentry, Oracle, and Phoenix emit 0 invalid energy-requiring spells in combat"
   (lambda ()
     (define home (mk-home-base-units 'Protoss #:workers 16))
     (define allies (append home (list (mk-unit 5301 'high-templar 1 74.0 80.0 #:energy 0.0)
                                       (mk-unit 5302 'sentry 1 74.0 81.0 #:energy 0.0)
                                       (mk-unit 5303 'oracle 1 74.0 79.0 #:energy 0.0)
                                       (mk-unit 5304 'phoenix 1 74.0 82.0 #:energy 0.0))))
     (define enemies (for/list ([i (in-range 8)]) (mk-unit (+ 8301 i) 'marine 4 80.0 (+ 77.5 (* i 0.6)) #:hp 45.0 #:hp-max 45.0)))
     (define out (last (run-pipeline-sequence 'Protoss 'Terran (list (hash 'obs (mk-obs 12000 (append allies enemies) #:upgrades '(psi-storm) #:food-used 32 #:food-cap 54 #:food-army 16 #:food-workers 16))))))
     (define bad-spell? (wire-any-ability? (step-outcome-wire-cmds out) '(5301 5302 5303 5304)
                                           (list AB-PSI-STORM AB-FEEDBACK AB-GUARDIAN-SHIELD AB-FORCE-FIELD AB-ORACLE-REVELATION AB-PULSAR-BEAM-ON AB-GRAVITON-BEAM AB-STASIS-WARD)))
     (values out
             (list
              (mk-check "zero-energy-protoss-casters-emit-no-spells" (not bad-spell?) (format "0-energy Protoss caster emitted spell=~a" bad-spell?))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0) (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

(define scen-novel-130
  (tactical-scenario
   "novel-130-zero-energy-zerg-and-terran-casters-emit-zero-invalid-spells"
   "novel" "Zerg" "Protoss" "wire-hygiene"
   "0-energy Infestor, Viper, Queen, Overseer, Ghost, Raven, and Banshee emit 0 invalid energy-requiring spells in combat"
   (lambda ()
     (define o-z
       (last (run-pipeline-sequence 'Zerg 'Protoss
               (list (hash 'obs (mk-obs 12000
                                        (append (mk-home-base-units 'Zerg #:workers 16)
                                                (list (mk-unit 5501 'infestor 1 74.0 80.0 #:energy 0.0)
                                                      (mk-unit 5502 'viper 1 74.0 81.0 #:energy 0.0)
                                                      (mk-unit 5503 'queen 1 74.0 79.0 #:energy 0.0)
                                                      (mk-unit 5504 'overseer 1 74.0 82.0 #:energy 0.0)
                                                      (mk-unit 5505 'ultralisk 1 75.5 79.0 #:hp 120.0 #:hp-max 500.0)
                                                      (mk-unit 8501 'carrier 4 80.0 80.0 #:hp 300.0 #:hp-max 300.0 #:shield 150.0 #:shield-max 150.0)))
                                        #:upgrades '(neural-parasite) #:food-used 32 #:food-cap 54 #:food-army 16 #:food-workers 16))))))
     (define o-t
       (last (run-pipeline-sequence 'Terran 'Protoss
               (list (hash 'obs (mk-obs 12000
                                        (append (mk-home-base-units 'Terran #:workers 16)
                                                (list (mk-unit 5401 'ghost 1 74.0 80.0 #:energy 0.0)
                                                      (mk-unit 5402 'raven 1 74.0 81.0 #:energy 0.0)
                                                      (mk-unit 5403 'banshee 1 74.0 79.0 #:energy 0.0)
                                                      (mk-unit 8401 'colossus 4 80.0 80.0 #:hp 200.0 #:hp-max 200.0 #:shield 150.0 #:shield-max 150.0)))
                                        #:upgrades '(banshee-cloak personal-cloaking interference-matrix) #:food-used 32 #:food-cap 54 #:food-army 16 #:food-workers 16))))))
     (define bad-z? (wire-any-ability? (step-outcome-wire-cmds o-z) '(5501 5502 5503 5504)
                                       (list AB-FUNGAL-GROWTH AB-NEURAL-PARASITE AB-PARASITIC-BOMB AB-BLINDING-CLOUD AB-ABDUCT AB-TRANSFUSE AB-SPAWN-CHANGELING AB-CONTAMINATE)))
     (define bad-t? (wire-any-ability? (step-outcome-wire-cmds o-t) '(5401 5402 5403)
                                       (list AB-EMP AB-SNIPE AB-CLOAK-GHOST AB-CLOAK-BANSHEE AB-INTERFERENCE-MATRIX AB-ANTI-ARMOR-MISSILE AB-AUTO-TURRET)))
     (define total-rej (+ (step-outcome-wire-rejects o-z) (step-outcome-wire-rejects o-t)))
     (values o-z
             (list
              (mk-check "zero-energy-zerg-casters-emit-no-spells" (not bad-z?) (format "0-energy Zerg caster emitted spell=~a" bad-z?))
              (mk-check "zero-energy-terran-casters-emit-no-spells" (not bad-t?) (format "0-energy Terran caster emitted spell=~a" bad-t?))
              (mk-check "zero-wire-rejects" (= total-rej 0) (format "wire_rejects=~a" total-rej)))))))

;; -----------------------------------------------------------------------------
;; Round-15 Map-Symmetry, Cliff-BFS Voronoi & Dynamic Fog-Risk Helpers + Shields
;; -----------------------------------------------------------------------------
(define (mk-mineral-cluster base-tag cx cy)
  (list (mk-unit base-tag 'mineral-field 3 (- cx 6.0) (- cy 2.0))
        (mk-unit (+ base-tag 1) 'mineral-field 3 (- cx 6.0) cy)
        (mk-unit (+ base-tag 2) 'mineral-field 3 (- cx 6.0) (+ cy 2.0))
        (mk-unit (+ base-tag 3) 'vespene-geyser 3 (- cx 4.0) (- cy 5.0))))

(define (mk-reflected-mineral-cluster sym-kind base-tag cx cy)
  ;; Reflect every resource patch cleanly about playable area [16, 184]^2 (center = (100, 100)).
  (define pts
    (list (list 'mineral-field (- cx 6.0) (- cy 2.0))
          (list 'mineral-field (- cx 6.0) cy)
          (list 'mineral-field (- cx 6.0) (+ cy 2.0))
          (list 'vespene-geyser (- cx 4.0) (- cy 5.0))))
  (for/list ([p (in-list pts)] [i (in-naturals)])
    (define r (sc2-symmetry-reflect-point sym-kind (second p) (third p) 168.0 168.0 #:x0 16.0 #:y0 16.0))
    (mk-unit (+ base-tag i) (first p) 3 (car r) (cdr r))))

(define (mk-mirror-minerals sym-kind)
  ;; Construct exact symmetric mineral clusters matching each map symmetry geometry inside [16, 184]^2.
  (case sym-kind
    [(rotational-180)
     (append (mk-mineral-cluster 91000 32.0 32.0)
             (mk-mineral-cluster 91010 52.0 32.0)
             (mk-mineral-cluster 91020 76.0 40.0)
             (mk-reflected-mineral-cluster 'rotational-180 91030 32.0 32.0)
             (mk-reflected-mineral-cluster 'rotational-180 91040 52.0 32.0)
             (mk-reflected-mineral-cluster 'rotational-180 91050 76.0 40.0))]
    [(mirror-horizontal)
     ;; Left-vs-Right reflection across x = 100 (our=(32,100), enemy=(168,100))
     (append (mk-mineral-cluster 91100 32.0 100.0)
             (mk-mineral-cluster 91110 52.0 128.0)
             (mk-mineral-cluster 91120 72.0 66.0)
             (mk-reflected-mineral-cluster 'mirror-horizontal 91130 32.0 100.0)
             (mk-reflected-mineral-cluster 'mirror-horizontal 91140 52.0 128.0)
             (mk-reflected-mineral-cluster 'mirror-horizontal 91150 72.0 66.0))]
    [(mirror-vertical)
     ;; Bottom-vs-Top reflection across y = 100 (our=(100,32), enemy=(100,168))
     (append (mk-mineral-cluster 91200 100.0 32.0)
             (mk-mineral-cluster 91210 128.0 52.0)
             (mk-mineral-cluster 91220 66.0 72.0)
             (mk-reflected-mineral-cluster 'mirror-vertical 91230 100.0 32.0)
             (mk-reflected-mineral-cluster 'mirror-vertical 91240 128.0 52.0)
             (mk-reflected-mineral-cluster 'mirror-vertical 91250 66.0 72.0))]
    [(mirror-diagonal-main)
     ;; Reflection across main diagonal y = x (our=(32,168), enemy=(168,32))
     (append (mk-mineral-cluster 91300 32.0 168.0)
             (mk-mineral-cluster 91310 56.0 148.0)
             (mk-mineral-cluster 91320 40.0 118.0)
             (mk-reflected-mineral-cluster 'mirror-diagonal-main 91330 32.0 168.0)
             (mk-reflected-mineral-cluster 'mirror-diagonal-main 91340 56.0 148.0)
             (mk-reflected-mineral-cluster 'mirror-diagonal-main 91350 40.0 118.0))]
    [(mirror-diagonal-anti)
     ;; Reflection across anti-diagonal x + y = 200 (our=(32,32), enemy=(168,168))
     (append (mk-mineral-cluster 91400 32.0 32.0)
             (mk-mineral-cluster 91410 62.0 40.0)
             (mk-mineral-cluster 91420 42.0 90.0)
             (mk-reflected-mineral-cluster 'mirror-diagonal-anti 91430 32.0 32.0)
             (mk-reflected-mineral-cluster 'mirror-diagonal-anti 91440 62.0 40.0)
             (mk-reflected-mineral-cluster 'mirror-diagonal-anti 91450 42.0 90.0))]
    [else
     ;; Asymmetric pad layout
     (append (mk-mineral-cluster 91500 32.0 36.0)
             (mk-mineral-cluster 91510 66.0 44.0)
             (mk-mineral-cluster 91520 50.0 110.0)
             (mk-mineral-cluster 91530 166.0 142.0)
             (mk-mineral-cluster 91540 138.0 92.0))]))

(define scen-novel-131
  (tactical-scenario
   "novel-131-air-harass-strikes-over-cliff-chasm-while-ground-defends-home"
   "novel" "Protoss" "Protoss" "harass-defense"
   "Across an impassable horizontal cliff chasm (y=95..105), flying Oracles/Mutalisks strike enemy workers over the cliff while ground defenders hold our main base"
   (lambda ()
     (define chasm-grid (mk-walkable-pathing-grid 200 200 #:wall-rects '((0 95 170 105))))
     (define mins (mk-mirror-minerals 'mirror-vertical))
     (define home (mk-home-base-units 'Protoss #:base-x 100.0 #:base-y 32.0 #:workers 16))
     (define defenders (for/list ([i (in-range 6)]) (mk-unit (+ 5610 i) 'stalker 1 (+ 97.0 (* i 0.8)) 38.0 #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0)))
     (define oracles   (list (mk-unit 5601 'oracle 1 100.0 162.0 #:hp 100.0 #:hp-max 100.0 #:shield 60.0 #:shield-max 60.0 #:energy 120.0)
                             (mk-unit 5602 'oracle 1 102.0 162.0 #:hp 100.0 #:hp-max 100.0 #:shield 60.0 #:shield-max 60.0 #:energy 120.0)))
     (define home-raiders (for/list ([i (in-range 4)]) (mk-unit (+ 8610 i) 'zealot 4 (+ 98.0 (* i 0.8)) 42.0 #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0)))
     (define enemy-line (append (list (mk-unit 8601 'nexus 4 100.0 168.0 #:hp 1000.0 #:hp-max 1000.0 #:shield 1000.0 #:shield-max 1000.0))
                                (for/list ([i (in-range 6)]) (mk-unit (+ 8620 i) 'probe 4 (+ 96.0 (* i 0.8)) 166.0 #:hp 20.0 #:hp-max 20.0 #:shield 20.0 #:shield-max 20.0))))
     (define out
       (last (run-pipeline-sequence 'Protoss 'Protoss
               (list (hash 'obs (mk-obs 9000 (append home defenders oracles home-raiders enemy-line)
                                        #:food-used 36 #:food-cap 60 #:food-army 20 #:food-workers 16
                                        #:neutral-units mins #:camera-x 100.0 #:camera-y 32.0)))
               #:our-x 100.0 #:our-y 32.0 #:enemy-x 100.0 #:enemy-y 168.0
               #:pathing-grid chasm-grid #:neutral-units mins)))
     (define wcmds (step-outcome-wire-cmds out))
     (define def-atk (wire-count-tags-with-ability wcmds '(5610 5611 5612 5613 5614 5615) AB-ATTACK))
     (define ora-act? (wire-any-ability? wcmds '(5601 5602) (list AB-PULSAR-BEAM-ON AB-ATTACK AB-ORACLE-REVELATION AB-MOVE)))
     (values out
             (list
              (mk-check "home-stalkers-engage-raiders" (>= def-atk 4)
                        (format "Home Stalkers ATTACK=~a/6 vs Zealot raiders (expected >=4)" def-atk))
              (mk-check "oracles-operate-over-chasm-on-enemy-mineral-line" ora-act?
                        (format "Oracles over cliff chasm active=~a" ora-act?))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

(define scen-novel-132
  (tactical-scenario
   "novel-132-horizontal-and-vertical-mirror-natural-defense-zero-abandon"
   "novel" "Terran" "Protoss" "home-defense"
   "On both Horizontal-mirror (our=(32,100), enemy=(168,100)) and Vertical-mirror (our=(100,32), enemy=(100,168)) maps, defenders engage threats on our side of the mirror axis without abandoning natural bases"
   (lambda ()
     (define grid-open (mk-walkable-pathing-grid 200 200))
     ;; Part A: Horizontal mirror
     (define h-mins (mk-mirror-minerals 'mirror-horizontal))
     (define h-home (mk-home-base-units 'Terran #:base-x 32.0 #:base-y 100.0 #:with-natural? #t #:nat-x 52.0 #:nat-y 128.0 #:workers 16))
     (define h-tags (for/list ([i (in-range 8)]) (+ 5710 i)))
     (define h-allies (append h-home (for/list ([i (in-range 8)]) (mk-unit (+ 5710 i) 'marine 1 64.0 (+ 124.0 (* i 0.7)) #:hp 45.0 #:hp-max 45.0))))
     (define h-enemies (for/list ([i (in-range 4)]) (mk-unit (+ 8710 i) 'stalker 4 71.0 (+ 125.0 (* i 0.9)) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0)))
     (define o-h
       (last (run-pipeline-sequence 'Terran 'Protoss
               (list (hash 'obs (mk-obs 9000 (append h-allies h-enemies)
                                        #:food-used 28 #:food-cap 50 #:food-army 12 #:food-workers 16
                                        #:neutral-units h-mins #:camera-x 32.0 #:camera-y 100.0)))
               #:our-x 32.0 #:our-y 100.0 #:enemy-x 168.0 #:enemy-y 100.0
               #:pathing-grid grid-open #:neutral-units h-mins)))
     (define h-atk (wire-count-tags-with-ability (step-outcome-wire-cmds o-h) h-tags AB-ATTACK))
     ;; Part B: Vertical mirror
     (define v-mins (mk-mirror-minerals 'mirror-vertical))
     (define v-home (mk-home-base-units 'Terran #:base-x 100.0 #:base-y 32.0 #:with-natural? #t #:nat-x 128.0 #:nat-y 52.0 #:workers 16))
     (define v-tags (for/list ([i (in-range 8)]) (+ 5720 i)))
     (define v-allies (append v-home (for/list ([i (in-range 8)]) (mk-unit (+ 5720 i) 'marine 1 (+ 124.0 (* i 0.7)) 64.0 #:hp 45.0 #:hp-max 45.0))))
     (define v-enemies (for/list ([i (in-range 4)]) (mk-unit (+ 8720 i) 'stalker 4 (+ 125.0 (* i 0.9)) 71.0 #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0)))
     (define o-v
       (last (run-pipeline-sequence 'Terran 'Protoss
               (list (hash 'obs (mk-obs 9000 (append v-allies v-enemies)
                                        #:food-used 28 #:food-cap 50 #:food-army 12 #:food-workers 16
                                        #:neutral-units v-mins #:camera-x 100.0 #:camera-y 32.0)))
               #:our-x 100.0 #:our-y 32.0 #:enemy-x 100.0 #:enemy-y 168.0
               #:pathing-grid grid-open #:neutral-units v-mins)))
     (define v-atk (wire-count-tags-with-ability (step-outcome-wire-cmds o-v) v-tags AB-ATTACK))
     (define total-rej (+ (step-outcome-wire-rejects o-h) (step-outcome-wire-rejects o-v)))
     (values o-h
             (list
              (mk-check "horizontal-mirror-defenders-engage" (>= h-atk 6)
                        (format "H-mirror Marines ATTACK=~a/8 (expected >=6)" h-atk))
              (mk-check "vertical-mirror-defenders-engage" (>= v-atk 6)
                        (format "V-mirror Marines ATTACK=~a/8 (expected >=6)" v-atk))
              (mk-check "zero-wire-rejects" (= total-rej 0)
                        (format "wire_rejects=~a" total-rej)))))))

;; -----------------------------------------------------------------------------
;; Tier 14: Wave-15 Symmetry-Agnostic Ground-BFS Voronoi & Dynamic Fog-Risk (6)
;; -----------------------------------------------------------------------------
(define scen-w15-tac-1
  (tactical-scenario
   "w15-tac-1-map-symmetry-classification-all-geometries-and-dual-bfs"
   "wave15-repro" "Protoss" "Terran" "map-symmetry"
   "Wave-15 P0-2 (zero map-name hacks): Live obs-hash classifies rotational-180, horizontal-mirror, vertical-mirror, diagonal-main, diagonal-anti & asymmetric maps and populates dual Ground-BFS Voronoi territory zones"
   (lambda ()
     (define open-grid (mk-walkable-pathing-grid 200 200))
     (define cases
       (list (list 'rotational-180       32.0  32.0 168.0 168.0  52.0  52.0 100.0 100.0 148.0 148.0)
             (list 'mirror-horizontal    32.0 100.0 168.0 100.0  60.0 110.0 100.0 100.0 140.0 110.0)
             (list 'mirror-vertical     100.0  32.0 100.0 168.0 110.0  60.0 100.0 100.0 110.0 140.0)
             (list 'mirror-diagonal-main 32.0 168.0 168.0  32.0  54.0 146.0 100.0 100.0 146.0  54.0)
             (list 'mirror-diagonal-anti 32.0  32.0 168.0 168.0  54.0  54.0 100.0 100.0 146.0 146.0)
             (list 'asymmetric           32.0  36.0 166.0 142.0  50.0  50.0  99.0  89.0 150.0 130.0)))
     (define results
       (for/list ([c (in-list cases)])
         (define exp-sym (first c))
         (define ox (second c)) (define oy (third c))
         (define ex (fourth c)) (define ey (fifth c))
         (define own-x (sixth c)) (define own-y (seventh c))
         (define mid-x (eighth c)) (define mid-y (ninth c))
         (define deep-x (tenth c)) (define deep-y (list-ref c 10))
         (define mins (mk-mirror-minerals exp-sym))
         (define home (mk-home-base-units 'Protoss #:base-x ox #:base-y oy #:workers 16))
         (define out
           (last (run-pipeline-sequence 'Protoss 'Terran
                   (list (hash 'obs (mk-obs 2000 home
                                            #:food-used 16 #:food-cap 30 #:food-army 0 #:food-workers 16
                                            #:neutral-units mins #:camera-x ox #:camera-y oy)))
                   #:our-x ox #:our-y oy #:enemy-x ex #:enemy-y ey
                   #:pathing-grid open-grid #:neutral-units mins)))
         (define oh (step-outcome-obs-hash out))
         (define got-sym (hash-ref oh 'map-symmetry-kind #f))
         (define obfs (hash-ref oh 'our-ground-bfs #f))
         (define ebfs (hash-ref oh 'enemy-ground-bfs #f))
         (define m-own  (and obfs ebfs (sc2-ground-territory-margin obfs ebfs own-x own-y)))
         (define m-mid  (and obfs ebfs (sc2-ground-territory-margin obfs ebfs mid-x mid-y)))
         (define m-deep (and obfs ebfs (sc2-ground-territory-margin obfs ebfs deep-x deep-y)))
         (define z-own  (bot-runtime-point-territory-zone oh own-x own-y))
         (define z-mid  (bot-runtime-point-territory-zone oh mid-x mid-y))
         (define z-deep (bot-runtime-point-territory-zone oh deep-x deep-y))
         (list exp-sym got-sym (and obfs ebfs #t) m-own m-mid m-deep z-own z-mid z-deep (step-outcome-wire-rejects out) out)))
     (define all-sym-ok? (for/and ([r (in-list results)]) (eq? (first r) (second r))))
     (define all-bfs-ok? (for/and ([r (in-list results)]) (third r)))
     (define all-zones-ok?
       (for/and ([r (in-list results)])
         (and (real? (fourth r)) (>= (fourth r) 6.0)
              (real? (fifth r))  (>= (fifth r) -8.0) (< (fifth r) 6.0)
              (real? (sixth r))  (< (sixth r) -8.0)
              (eq? (seventh r) 'own-territory)
              (eq? (eighth r) 'contested-frontline)
              (eq? (ninth r) 'deep-enemy-territory))))
     (define total-rej (for/sum ([r (in-list results)]) (tenth r)))
     (values (list-ref (first results) 10)
             (list
              (mk-check "all-6-symmetry-geometries-classified-cleanly" all-sym-ok?
                        (format "symmetries=~a" (map (lambda (r) (cons (first r) (second r))) results)))
              (mk-check "dual-ground-bfs-populated-on-all-maps" all-bfs-ok?
                        (format "dual-bfs=~a" (map third results)))
              (mk-check "own-contested-deep-voronoi-zones-accurate" all-zones-ok?
                        (format "zones=~a" (map (lambda (r) (list (first r) (seventh r) (eighth r) (ninth r))) results)))
              (mk-check "zero-wire-rejects" (= total-rej 0)
                        (format "wire_rejects=~a" total-rej)))))))

(define scen-w15-tac-2
  (tactical-scenario
   "w15-tac-2-cliff-choke-ground-bfs-voronoi-defense-and-air-separation"
   "wave15-repro" "Terran" "Protoss" "home-defense"
   "Wave-15 P0-2 (cliff-choke Voronoi): Defend own-territory point 44.4t outside old 36t Euclidean circle when cliff makes Ground-BFS margin >> +6, while rejecting cliff-blocked points for ground (keeping air margin positive!)"
   (lambda ()
     ;; Part A: Vertical cliff at x=76..82, y=0..158 -> P=(68, 58) is 44.4t Euclidean (>36t!) from BOTH main (32,32) and nat (24,52),
     ;; yet Ground-BFS d_ours ~ 45t <= 48t while d_enemy ~ 200t -> margin >> +80 -> Own Territory defended even under outnumbered suppress!
     (define cliff-grid-a (mk-walkable-pathing-grid 200 200 #:wall-rects '((76 0 82 158))))
     (define mins-a
       (append (mk-mineral-cluster 92000 32.0 32.0)
               (mk-mineral-cluster 92010 24.0 52.0)
               (mk-mineral-cluster 92020 168.0 168.0)))
     (define home-a (mk-home-base-units 'Terran #:base-x 32.0 #:base-y 32.0 #:workers 16))
     (define m-tags '(5801 5802 5803 5804 5805))
     (define defenders-a (for/list ([i (in-range 5)]) (mk-unit (+ 5801 i) 'marine 1 62.5 (+ 56.5 (* i 0.7)) #:hp 45.0 #:hp-max 45.0)))
     (define enemies-a
       (append (for/list ([i (in-range 4)]) (mk-unit (+ 8801 i) 'stalker 4 68.0 (+ 56.5 (* i 0.9)) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))
               (list (mk-unit 8810 'immortal 4 69.0 58.0 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0)
                     (mk-unit 8811 'immortal 4 69.0 59.5 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0))))
     (define o-a
       (last (run-pipeline-sequence 'Terran 'Protoss
               (list (hash 'obs (mk-obs 9000 (append home-a defenders-a enemies-a)
                                        #:food-used 24 #:food-cap 45 #:food-army 8 #:food-workers 16
                                        #:neutral-units mins-a #:camera-x 32.0 #:camera-y 32.0)))
               #:our-x 32.0 #:our-y 32.0 #:enemy-x 168.0 #:enemy-y 168.0
               #:pathing-grid cliff-grid-a #:neutral-units mins-a)))
     (define oh-a (step-outcome-obs-hash o-a))
     (define m-a (bot-runtime-point-territory-margin oh-a 68.0 58.0 #:air? #f))
     (define z-a (bot-runtime-point-territory-zone oh-a 68.0 58.0 #:air? #f))
     (define def-atk-a (wire-count-tags-with-ability (step-outcome-wire-cmds o-a) m-tags AB-ATTACK))
     ;; Part B: Cliff wall right next to main at x=46..52, y=0..145 -> Q=(56, 32) is only 24t Euclidean from main (32,32),
     ;; YET Ground-BFS detour > 220t vs enemy ~175t -> ground zone is 'deep-enemy-territory (NOT 'own-territory), while air margin > +100!
     (define cliff-grid-b (mk-walkable-pathing-grid 200 200 #:wall-rects '((46 0 52 145))))
     (define o-b
       (last (run-pipeline-sequence 'Terran 'Protoss
               (list (hash 'obs (mk-obs 9000 home-a
                                        #:food-used 16 #:food-cap 30 #:food-army 0 #:food-workers 16
                                        #:neutral-units mins-a #:camera-x 32.0 #:camera-y 32.0)))
               #:our-x 32.0 #:our-y 32.0 #:enemy-x 168.0 #:enemy-y 168.0
               #:pathing-grid cliff-grid-b #:neutral-units mins-a)))
     (define oh-b (step-outcome-obs-hash o-b))
     (define m-b-gnd (bot-runtime-point-territory-margin oh-b 56.0 32.0 #:air? #f))
     (define z-b-gnd (bot-runtime-point-territory-zone oh-b 56.0 32.0 #:air? #f))
     (define m-b-air (bot-runtime-point-territory-margin oh-b 56.0 32.0 #:air? #t))
     (define total-rej (+ (step-outcome-wire-rejects o-a) (step-outcome-wire-rejects o-b)))
     (values o-a
             (list
              (mk-check "cliff-voronoi-point-classified-own-territory-outside-36t"
                        (and (real? m-a) (>= m-a 80.0) (eq? z-a 'own-territory))
                        (format "P=(68,58) 44.4t Euclidean: margin=~a zone=~a" m-a z-a))
              (mk-check "defenders-engage-in-cliff-voronoi-territory-under-outnumbered-suppress"
                        (>= def-atk-a 4)
                        (format "Marines ATTACK=~a/5 at cliff-Voronoi P=(68,58) (expected >=4)" def-atk-a))
              (mk-check "cliff-blocked-point-rejected-for-ground-positive-for-air"
                        (and (real? m-b-gnd) (< m-b-gnd -8.0) (eq? z-b-gnd 'deep-enemy-territory)
                             (real? m-b-air) (> m-b-air 100.0))
                        (format "Q=(56,32) behind cliff: gnd_margin=~a gnd_zone=~a air_margin=~a" m-b-gnd z-b-gnd m-b-air))
              (mk-check "zero-wire-rejects" (= total-rej 0)
                        (format "wire_rejects=~a" total-rej)))))))

(define scen-w15-tac-3
  (tactical-scenario
   "w15-tac-3-mobile-harass-crosses-deep-territory-under-fog-belief"
   "wave15-repro" "Protoss" "Terran" "harass-defense"
   "Wave-15 P0-2 (Dynamic Fog-Risk Gate): Mobile/retreatable harass units (Oracle, Blink-Stalker, Reaper, Banshee, Medivac, Mutalisk, small Zergling runby) cross into deep enemy territory under fog belief while slow main-army units stay gated"
   (lambda ()
     (define open-grid (mk-walkable-pathing-grid 200 200))
     (define mins (mk-mirror-minerals 'rotational-180))
     ;; Classifier sanity across P/T/Z mobile vs slow unit classes
     (define cls-ok?
       (and (bot-runtime-mobile-retreatable-unit? 'oracle)
            (bot-runtime-mobile-retreatable-unit? 'reaper)
            (bot-runtime-mobile-retreatable-unit? 'banshee)
            (bot-runtime-mobile-retreatable-unit? 'medivac)
            (bot-runtime-mobile-retreatable-unit? 'mutalisk)
            (bot-runtime-mobile-retreatable-unit? 'stalker #:researched-upgrades '(blink))
            (bot-runtime-mobile-retreatable-unit? 'zergling #:small-ling-runby? #t)
            (not (bot-runtime-mobile-retreatable-unit? 'stalker #:researched-upgrades '()))
            (not (bot-runtime-mobile-retreatable-unit? 'immortal))
            (not (bot-runtime-mobile-retreatable-unit? 'siege-tank))
            (not (bot-runtime-mobile-retreatable-unit? 'roach))))
     ;; Part A (Protoss): Dedicated air harass (2 Oracles) crosses out of a mixed slow army (2 Immortals)
     ;; under fog belief while slow Immortals hold; AND a pure Blink-Stalker squad (`all-mobile-retreatable?`,
     ;; Blink established >60s earlier at f=7000!) crosses deep cleanly!
     (define p-home (mk-home-base-units 'Protoss #:base-x 32.0 #:base-y 32.0 #:workers 16))
     (define p-oras (list (mk-unit 5901 'oracle 1 70.0 70.0 #:energy 100.0)
                          (mk-unit 5902 'oracle 1 71.0 71.0 #:energy 100.0)))
     (define p-slow (list (mk-unit 5911 'immortal 1 68.0 68.0 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0)
                          (mk-unit 5912 'immortal 1 69.0 68.0 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0)))
     (define p-pure-blink (for/list ([i (in-range 4)]) (mk-unit (+ 5903 i) 'stalker 1 (+ 70.0 (* i 0.7)) 72.0 #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0)))
     (define e-cc   (list (mk-unit 8901 'command-center 4 168.0 168.0 #:hp 1500.0 #:hp-max 1500.0)))
     (define o-p
       (last (run-pipeline-sequence 'Protoss 'Terran
               (list (hash 'obs (mk-obs 9000 (append p-home p-oras p-slow e-cc)
                                        #:food-used 30 #:food-cap 60 #:food-army 14 #:food-workers 16
                                        #:neutral-units mins #:camera-x 32.0 #:camera-y 32.0)))
               #:our-x 32.0 #:our-y 32.0 #:enemy-x 168.0 #:enemy-y 168.0
               #:pathing-grid open-grid #:neutral-units mins)))
     (define o-p-pure
       (last (run-pipeline-sequence 'Protoss 'Terran
               (list (hash 'obs (mk-obs 7000 (append p-home p-pure-blink)
                                        #:upgrades '(blink) #:food-used 24 #:food-cap 60 #:food-army 8 #:food-workers 16
                                        #:neutral-units mins #:camera-x 32.0 #:camera-y 32.0))
                     (hash 'obs (mk-obs 9000 (append p-home p-pure-blink e-cc)
                                        #:upgrades '(blink) #:food-used 24 #:food-cap 60 #:food-army 8 #:food-workers 16
                                        #:neutral-units mins #:camera-x 32.0 #:camera-y 32.0)))
               #:our-x 32.0 #:our-y 32.0 #:enemy-x 168.0 #:enemy-y 168.0
               #:pathing-grid open-grid #:neutral-units mins)))
     (define p-ora-go (wire-count-tags-heading-deep (step-outcome-wire-cmds o-p) '(5901 5902) 168.0 168.0 #:enemy-tags '(8901)))
     (define p-slow-deep (wire-count-tags-heading-deep (step-outcome-wire-cmds o-p) '(5911 5912) 168.0 168.0 #:enemy-tags '(8901)))
     (define p-blink-go (wire-count-tags-heading-deep (step-outcome-wire-cmds o-p-pure) '(5903 5904 5905 5906) 168.0 168.0 #:enemy-tags '(8901)))
     ;; Part B (Terran): 2 Reapers + 1 Banshee (dedicated harass) cross while 2 slow Siege Tanks hold
     (define t-home (mk-home-base-units 'Terran #:base-x 32.0 #:base-y 32.0 #:workers 16))
     (define t-mob  (list (mk-unit 5921 'reaper 1 70.0 70.0 #:hp 60.0 #:hp-max 60.0)
                          (mk-unit 5922 'reaper 1 71.0 70.0 #:hp 60.0 #:hp-max 60.0)
                          (mk-unit 5923 'banshee 1 70.0 72.0 #:hp 140.0 #:hp-max 140.0 #:energy 100.0)))
     (define t-slow (list (mk-unit 5931 'siege-tank 1 68.0 68.0 #:hp 175.0 #:hp-max 175.0)
                          (mk-unit 5932 'siege-tank 1 69.0 68.0 #:hp 175.0 #:hp-max 175.0)))
     (define e-nex  (list (mk-unit 8902 'nexus 4 168.0 168.0 #:hp 1000.0 #:hp-max 1000.0 #:shield 1000.0 #:shield-max 1000.0)))
     (define o-t
       (last (run-pipeline-sequence 'Terran 'Protoss
               (list (hash 'obs (mk-obs 9000 (append t-home t-mob t-slow e-nex)
                                        #:food-used 28 #:food-cap 50 #:food-army 12 #:food-workers 16
                                        #:neutral-units mins #:camera-x 32.0 #:camera-y 32.0)))
               #:our-x 32.0 #:our-y 32.0 #:enemy-x 168.0 #:enemy-y 168.0
               #:pathing-grid open-grid #:neutral-units mins)))
     (define t-mob-go (wire-count-tags-heading-deep (step-outcome-wire-cmds o-t) '(5921 5922 5923) 168.0 168.0 #:enemy-tags '(8902)))
     (define t-slow-deep (wire-count-tags-heading-deep (step-outcome-wire-cmds o-t) '(5931 5932) 168.0 168.0 #:enemy-tags '(8902)))
     ;; Part C (Zerg): 2 Mutalisks (dedicated air harass) cross out of mixed slow army (3 Roaches),
     ;; AND a pure small 6-Zergling runby (`all-mobile-retreatable?`) crosses deep cleanly!
     (define z-home (mk-home-base-units 'Zerg #:base-x 32.0 #:base-y 32.0 #:workers 16))
     (define z-mutas (list (mk-unit 5941 'mutalisk 1 70.0 70.0 #:hp 120.0 #:hp-max 120.0)
                           (mk-unit 5942 'mutalisk 1 71.0 70.0 #:hp 120.0 #:hp-max 120.0)))
     (define z-slow (for/list ([i (in-range 3)]) (mk-unit (+ 5951 i) 'roach 1 (+ 67.5 (* i 0.8)) 68.0 #:hp 145.0 #:hp-max 145.0)))
     (define z-pure-lings (for/list ([i (in-range 6)]) (mk-unit (+ 5943 i) 'zergling 1 (+ 69.5 (* i 0.4)) 72.0 #:hp 35.0 #:hp-max 35.0)))
     (define o-z
       (last (run-pipeline-sequence 'Zerg 'Protoss
               (list (hash 'obs (mk-obs 9000 (append z-home z-mutas z-slow e-nex)
                                        #:food-used 26 #:food-cap 50 #:food-army 10 #:food-workers 16
                                        #:neutral-units mins #:camera-x 32.0 #:camera-y 32.0)))
               #:our-x 32.0 #:our-y 32.0 #:enemy-x 168.0 #:enemy-y 168.0
               #:pathing-grid open-grid #:neutral-units mins)))
     (define o-z-pure
       (last (run-pipeline-sequence 'Zerg 'Protoss
               (list (hash 'obs (mk-obs 9000 (append z-home z-pure-lings e-nex)
                                        #:food-used 19 #:food-cap 50 #:food-army 3 #:food-workers 16
                                        #:neutral-units mins #:camera-x 32.0 #:camera-y 32.0)))
               #:our-x 32.0 #:our-y 32.0 #:enemy-x 168.0 #:enemy-y 168.0
               #:pathing-grid open-grid #:neutral-units mins)))
     (define z-muta-go (wire-count-tags-heading-deep (step-outcome-wire-cmds o-z) '(5941 5942) 168.0 168.0 #:enemy-tags '(8902)))
     (define z-slow-deep (wire-count-tags-heading-deep (step-outcome-wire-cmds o-z) '(5951 5952 5953) 168.0 168.0 #:enemy-tags '(8902)))
     (define z-ling-go (wire-count-tags-heading-deep (step-outcome-wire-cmds o-z-pure) '(5943 5944 5945 5946 5947 5948) 168.0 168.0 #:enemy-tags '(8902)))
     (define total-rej (+ (step-outcome-wire-rejects o-p) (step-outcome-wire-rejects o-p-pure)
                          (step-outcome-wire-rejects o-t) (step-outcome-wire-rejects o-z) (step-outcome-wire-rejects o-z-pure)))
     (values o-p
             (list
              (mk-check "mobile-retreatable-classifier-exact-across-ptz" cls-ok?
                        (format "classifier_ok=~a" cls-ok?))
              (mk-check "protoss-oracles-and-pure-blink-stalkers-cross-while-immortals-hold"
                        (and (>= p-ora-go 1) (= p-slow-deep 0) (>= p-blink-go 3))
                        (format "P Oracles deep=~a/2, slow Immortals deep=~a/2, pure Blink-Stalkers deep=~a/4" p-ora-go p-slow-deep p-blink-go))
              (mk-check "terran-reapers-banshee-cross-while-tanks-hold"
                        (and (>= t-mob-go 2) (= t-slow-deep 0))
                        (format "T mobile heading-deep=~a/3, slow Tanks deep=~a/2" t-mob-go t-slow-deep))
              (mk-check "zerg-mutas-and-pure-ling-runby-cross-while-roaches-hold"
                        (and (= z-muta-go 2) (= z-slow-deep 0) (>= z-ling-go 4))
                        (format "Z Mutas deep=~a/2, slow Roaches deep=~a/3, pure Ling runby deep=~a/6" z-muta-go z-slow-deep z-ling-go))
              (mk-check "zero-wire-rejects" (= total-rej 0)
                        (format "wire_rejects=~a" total-rej)))))))

(define scen-w15-tac-4
  (tactical-scenario
   "w15-tac-4-slow-army-respects-deep-fog-risk-vs-contested-frontline"
   "wave15-repro" "Terran" "Protoss" "macro-tactics"
   "Wave-15c P0-2 (Dynamic Fog-Risk Gate): Slow non-retreatable army holds back from Deep Enemy Territory (margin < -8) AND outgunned (0.40x) Contested Frontline marches, while a competitive (>=0.85x) army contests Contested Frontline (-8 <= margin < +6)"
   (lambda ()
     (define open-grid (mk-walkable-pathing-grid 200 200))
     (define mins (mk-mirror-minerals 'rotational-180))
     (define home (mk-home-base-units 'Terran #:base-x 32.0 #:base-y 32.0 #:workers 16))
     (define squad-tags '(6001 6002 6003 6004 6005 6006))
     ;; Subcase A: Deep Enemy Territory target at (158, 158) (margin << -8) -> slow squad MUST NOT commit across map
     (define squad-a
       (append (list (mk-unit 6001 'siege-tank 1 70.0 70.0 #:hp 175.0 #:hp-max 175.0)
                     (mk-unit 6002 'siege-tank 1 71.5 70.0 #:hp 175.0 #:hp-max 175.0))
               (for/list ([i (in-range 4)]) (mk-unit (+ 6003 i) 'marine 1 (+ 69.5 (* i 0.7)) 72.0 #:hp 45.0 #:hp-max 45.0))))
     (define deep-bldg (list (mk-unit 8910 'gateway 4 158.0 158.0 #:hp 500.0 #:hp-max 500.0 #:shield 500.0 #:shield-max 500.0)))
     (define o-deep
       (last (run-pipeline-sequence 'Terran 'Protoss
               (list (hash 'obs (mk-obs 9000 (append home squad-a deep-bldg)
                                        #:food-used 26 #:food-cap 50 #:food-army 10 #:food-workers 16
                                        #:neutral-units mins #:camera-x 32.0 #:camera-y 32.0)))
               #:our-x 32.0 #:our-y 32.0 #:enemy-x 168.0 #:enemy-y 168.0
               #:pathing-grid open-grid #:neutral-units mins)))
     (define z-deep (bot-runtime-point-territory-zone (step-outcome-obs-hash o-deep) 158.0 158.0))
     (define deep-atk (wire-count-tags-with-ability (step-outcome-wire-cmds o-deep) squad-tags AB-ATTACK))
     ;; Subcase B: Outgunned (0.39x) slow squad at 18t (edist2=324 > 225) from Contested Frontline pylon (100,100) stays gated!
     (define squad-outgunned
       (append (list (mk-unit 6001 'siege-tank 1 87.0 87.0 #:hp 175.0 #:hp-max 175.0)
                     (mk-unit 6002 'siege-tank 1 88.0 87.0 #:hp 175.0 #:hp-max 175.0))
               (for/list ([i (in-range 4)]) (mk-unit (+ 6003 i) 'marine 1 (+ 86.5 (* i 0.6)) 88.0 #:hp 45.0 #:hp-max 45.0))))
     (define mid-bldg (list (mk-unit 8911 'pylon 4 100.0 100.0 #:hp 200.0 #:hp-max 200.0 #:shield 200.0 #:shield-max 200.0)))
     (define o-mid-weak
       (last (run-pipeline-sequence 'Terran 'Protoss
               (list (hash 'obs (mk-obs 9000 (append home squad-outgunned mid-bldg)
                                        #:food-used 26 #:food-cap 50 #:food-army 10 #:food-workers 16
                                        #:neutral-units mins #:camera-x 32.0 #:camera-y 32.0)))
               #:our-x 32.0 #:our-y 32.0 #:enemy-x 168.0 #:enemy-y 168.0
               #:pathing-grid open-grid #:neutral-units mins)))
     (define mid-weak-atk (wire-count-tags-with-ability (step-outcome-wire-cmds o-mid-weak) squad-tags AB-ATTACK))
     ;; Subcase C: Competitive (>=0.85x: 3 Tanks + 3 Marauders + 12 Marines = 2025 val ~0.90x) slow squad at 18t contests Contested Frontline!
     (define comp-tags (append '(6021 6022 6023 6024 6025 6026) (for/list ([i (in-range 12)]) (+ 6030 i))))
     (define squad-comp
       (append (list (mk-unit 6021 'siege-tank 1 87.0 87.0 #:hp 175.0 #:hp-max 175.0)
                     (mk-unit 6022 'siege-tank 1 88.5 87.0 #:hp 175.0 #:hp-max 175.0)
                     (mk-unit 6023 'siege-tank 1 87.0 88.5 #:hp 175.0 #:hp-max 175.0)
                     (mk-unit 6024 'marauder 1 88.5 88.5 #:hp 125.0 #:hp-max 125.0)
                     (mk-unit 6025 'marauder 1 89.5 88.5 #:hp 125.0 #:hp-max 125.0)
                     (mk-unit 6026 'marauder 1 88.5 89.5 #:hp 125.0 #:hp-max 125.0))
               (for/list ([i (in-range 12)])
                 (mk-unit (+ 6030 i) 'marine 1 (+ 86.0 (* 0.5 (modulo i 6))) (+ 89.0 (* 0.5 (quotient i 6))) #:hp 45.0 #:hp-max 45.0))))
     (define o-mid-comp
       (last (run-pipeline-sequence 'Terran 'Protoss
               (list (hash 'obs (mk-obs 9000 (append home squad-comp mid-bldg)
                                        #:food-used 43 #:food-cap 66 #:food-army 27 #:food-workers 16
                                        #:neutral-units mins #:camera-x 32.0 #:camera-y 32.0)))
               #:our-x 32.0 #:our-y 32.0 #:enemy-x 168.0 #:enemy-y 168.0
               #:pathing-grid open-grid #:neutral-units mins)))
     (define z-mid (bot-runtime-point-territory-zone (step-outcome-obs-hash o-mid-comp) 100.0 100.0))
     (define mid-comp-atk (wire-count-tags-with-ability (step-outcome-wire-cmds o-mid-comp) comp-tags AB-ATTACK))
     (define total-rej (+ (step-outcome-wire-rejects o-deep) (step-outcome-wire-rejects o-mid-weak) (step-outcome-wire-rejects o-mid-comp)))
     (values o-deep
             (list
              (mk-check "slow-army-gated-from-deep-enemy-territory-under-fog-belief"
                        (and (eq? z-deep 'deep-enemy-territory) (= deep-atk 0))
                        (format "Deep target zone=~a, slow squad ATTACK=~a/6 (expected 0)" z-deep deep-atk))
              (mk-check "outgunned-0.40x-slow-army-does-not-march-into-contested-frontline"
                        (= mid-weak-atk 0)
                        (format "Outgunned 0.40x squad at 18t from frontline ATTACK=~a/6 (expected 0)" mid-weak-atk))
              (mk-check "competitive-0.90x-slow-army-contests-frontline-skirmish"
                        (and (eq? z-mid 'contested-frontline) (>= mid-comp-atk 10))
                        (format "Competitive 0.90x squad frontline zone=~a, ATTACK=~a/18 (expected >=10)" z-mid mid-comp-atk))
              (mk-check "zero-wire-rejects" (= total-rej 0)
                        (format "wire_rejects=~a" total-rej)))))))

(define scen-w15-tac-5
  (tactical-scenario
   "w15-tac-5-upgrade-power-spike-overrides-deep-fog-gate"
   "wave15-repro" "Terran" "Zerg" "macro-tactics"
   "Wave-15b P0-2 (Dynamic Fog-Risk Gate): Cohesive >=18-sup timing squad (~0.90x believed army) holds under fog belief without a spike, yet commits forward immediately when Stimpack power-spike completes"
   (lambda ()
     (define open-grid (mk-walkable-pathing-grid 200 200))
     (define mins (mk-mirror-minerals 'rotational-180))
     (define home (mk-home-base-units 'Terran #:base-x 32.0 #:base-y 32.0 #:workers 16))
     ;; 3 Siege Tanks (1012.5) + 3 Marauders (412.5) + 12 Marines (600) = 2025 val (~0.903x of 2243 owm, 27 sup >= 18)
     (define squad-tags (append '(6101 6102 6103 6104 6105 6106) (for/list ([i (in-range 12)]) (+ 6110 i))))
     (define squad
       (append (list (mk-unit 6101 'siege-tank 1 70.0 70.0 #:hp 175.0 #:hp-max 175.0)
                     (mk-unit 6102 'siege-tank 1 71.5 70.0 #:hp 175.0 #:hp-max 175.0)
                     (mk-unit 6103 'siege-tank 1 73.0 70.0 #:hp 175.0 #:hp-max 175.0)
                     (mk-unit 6104 'marauder 1 72.0 71.0 #:hp 125.0 #:hp-max 125.0)
                     (mk-unit 6105 'marauder 1 72.0 72.5 #:hp 125.0 #:hp-max 125.0)
                     (mk-unit 6106 'marauder 1 73.5 72.5 #:hp 125.0 #:hp-max 125.0))
               (for/list ([i (in-range 12)])
                 (mk-unit (+ 6110 i) 'marine 1 (+ 70.0 (* 0.5 (modulo i 6))) (+ 73.5 (* 0.6 (quotient i 6))) #:hp 45.0 #:hp-max 45.0))))
     (define deep-pool (list (mk-unit 8920 'spawning-pool 4 158.0 158.0 #:hp 1000.0 #:hp-max 1000.0)))
     ;; Subcase A: No upgrade finishes between f=8900 and f=9000 -> deep-fog gate holds slow timing army
     (define o-no-spike
       (last (run-pipeline-sequence 'Terran 'Zerg
               (list (hash 'obs (mk-obs 8900 (append home squad deep-pool)
                                        #:upgrades '() #:food-used 43 #:food-cap 66 #:food-army 27 #:food-workers 16
                                        #:neutral-units mins #:camera-x 32.0 #:camera-y 32.0))
                     (hash 'obs (mk-obs 9000 (append home squad deep-pool)
                                        #:upgrades '() #:food-used 43 #:food-cap 66 #:food-army 27 #:food-workers 16
                                        #:neutral-units mins #:camera-x 32.0 #:camera-y 32.0)))
               #:our-x 32.0 #:our-y 32.0 #:enemy-x 168.0 #:enemy-y 168.0
               #:pathing-grid open-grid #:neutral-units mins)))
     (define atk-no-spike (wire-count-tags-with-ability (step-outcome-wire-cmds o-no-spike) squad-tags AB-ATTACK))
     ;; Subcase B: Stimpack completes at f=9000 -> active power-spike window exempts timing squad from fog gate!
     (define o-spike
       (last (run-pipeline-sequence 'Terran 'Zerg
               (list (hash 'obs (mk-obs 8900 (append home squad deep-pool)
                                        #:upgrades '() #:food-used 43 #:food-cap 66 #:food-army 27 #:food-workers 16
                                        #:neutral-units mins #:camera-x 32.0 #:camera-y 32.0))
                     (hash 'obs (mk-obs 9000 (append home squad deep-pool)
                                        #:upgrades '(stimpack) #:food-used 43 #:food-cap 66 #:food-army 27 #:food-workers 16
                                        #:neutral-units mins #:camera-x 32.0 #:camera-y 32.0)))
               #:our-x 32.0 #:our-y 32.0 #:enemy-x 168.0 #:enemy-y 168.0
               #:pathing-grid open-grid #:neutral-units mins)))
     (define atk-spike (wire-count-tags-with-ability (step-outcome-wire-cmds o-spike) squad-tags AB-ATTACK))
     (define total-rej (+ (step-outcome-wire-rejects o-no-spike) (step-outcome-wire-rejects o-spike)))
     (values o-spike
             (list
              (mk-check "without-power-spike-deep-fog-gate-holds" (= atk-no-spike 0)
                        (format "No-spike slow squad ATTACK=~a/18 (expected 0)" atk-no-spike))
              (mk-check "with-fresh-stimpack-power-spike-army-commits" (>= atk-spike 10)
                        (format "Stimpack-spike timing squad ATTACK=~a/18 (expected >=10)" atk-spike))
              (mk-check "zero-wire-rejects" (= total-rej 0)
                        (format "wire_rejects=~a" total-rej)))))))

(define scen-w15-tac-6
  (tactical-scenario
   "w15-tac-6-exposed-expand-and-behind-in-eco-desperation-override-fog-gate"
   "wave15-repro" "Protoss" "Zerg" "macro-tactics"
   "Wave-15b P0-2 (Dynamic Fog-Risk Gate): Cohesive >=18-sup Protoss army breaks deep-fog gate at >=0.90x to deny a truly greedy/exposed 3rd expansion (>26t from enemy main) AND at >=0.85x on a >=2-base behind-in-eco desperation timing"
   (lambda ()
     (define open-grid (mk-walkable-pathing-grid 200 200))
     (define mins (mk-mirror-minerals 'rotational-180))
     (define home (mk-home-base-units 'Protoss #:base-x 32.0 #:base-y 32.0 #:workers 16))
     ;; Subcase A: Truly greedy/exposed expansion at (118, 128) (64t > 26t from enemy main (168,168); enemy 2b > our 1b)
     ;; 4 Immortals (1700) + 5 Zealots (500) = 2200 val (~0.98x of 2243 owm >= 0.90x, 26 sup >= 18)
     (define tags-a '(6201 6202 6203 6204 6205 6206 6207 6208 6209))
     (define squad-a
       (append (list (mk-unit 6201 'immortal 1 70.0 70.0 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0)
                     (mk-unit 6202 'immortal 1 71.5 70.0 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0)
                     (mk-unit 6203 'immortal 1 73.0 70.0 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0)
                     (mk-unit 6204 'immortal 1 74.5 70.0 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0))
               (for/list ([i (in-range 5)]) (mk-unit (+ 6205 i) 'zealot 1 (+ 70.0 (* i 0.8)) 72.5 #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0))))
     (define exposed-hatches
       (list (mk-unit 8929 'hatchery 4 168.0 168.0 #:hp 1500.0 #:hp-max 1500.0)
             (mk-unit 8930 'hatchery 4 118.0 128.0 #:hp 900.0 #:hp-max 1500.0 #:build-progress 0.60)))
     (define o-exp
       (last (run-pipeline-sequence 'Protoss 'Zerg
               (list (hash 'obs (mk-obs 9000 (append home squad-a exposed-hatches)
                                        #:food-used 42 #:food-cap 66 #:food-army 26 #:food-workers 16
                                        #:neutral-units mins #:camera-x 32.0 #:camera-y 32.0)))
               #:our-x 32.0 #:our-y 32.0 #:enemy-x 168.0 #:enemy-y 168.0
               #:pathing-grid open-grid #:neutral-units mins)))
     (define atk-exp (wire-count-tags-with-ability (step-outcome-wire-cmds o-exp) tags-a AB-ATTACK))
     ;; Subcase B: Behind-in-eco desperation (1 base vs 3 enemy Hatcheries; 3 Immortals + 7 Zealots = 1975 val ~0.88x in [0.85, 0.90), 26 sup >= 18)
     (define tags-b (append '(6221 6222 6223) (for/list ([i (in-range 7)]) (+ 6230 i))))
     (define squad-b
       (append (list (mk-unit 6221 'immortal 1 70.0 70.0 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0)
                     (mk-unit 6222 'immortal 1 71.5 70.0 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0)
                     (mk-unit 6223 'immortal 1 73.0 70.0 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0))
               (for/list ([i (in-range 7)]) (mk-unit (+ 6230 i) 'zealot 1 (+ 69.5 (* 0.7 (modulo i 4))) (+ 72.0 (* 0.8 (quotient i 4))) #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0))))
     (define three-hatches
       (list (mk-unit 8940 'hatchery 4 168.0 168.0 #:hp 1500.0 #:hp-max 1500.0)
             (mk-unit 8941 'hatchery 4 148.0 168.0 #:hp 1500.0 #:hp-max 1500.0)
             (mk-unit 8942 'hatchery 4 124.0 160.0 #:hp 1500.0 #:hp-max 1500.0)))
     (define o-desp
       (last (run-pipeline-sequence 'Protoss 'Zerg
               (list (hash 'obs (mk-obs 9000 (append home squad-b three-hatches)
                                        #:food-used 42 #:food-cap 66 #:food-army 26 #:food-workers 16
                                        #:neutral-units mins #:camera-x 32.0 #:camera-y 32.0)))
               #:our-x 32.0 #:our-y 32.0 #:enemy-x 168.0 #:enemy-y 168.0
               #:pathing-grid open-grid #:neutral-units mins)))
     (define atk-desp (wire-count-tags-with-ability (step-outcome-wire-cmds o-desp) tags-b AB-ATTACK))
     (define total-rej (+ (step-outcome-wire-rejects o-exp) (step-outcome-wire-rejects o-desp)))
     (values o-exp
             (list
              (mk-check "exposed-enemy-expand-overrides-fog-gate" (>= atk-exp 7)
                        (format "Exposed Hatchery denial ATTACK=~a/9 (expected >=7)" atk-exp))
              (mk-check "behind-in-eco-desperation-timing-overrides-fog-gate" (>= atk-desp 7)
                        (format "1v3-base desperation timing ATTACK=~a/10 (expected >=7)" atk-desp))
              (mk-check "zero-wire-rejects" (= total-rej 0)
                        (format "wire_rejects=~a" total-rej)))))))

(define scen-w15-tac-7
  (tactical-scenario
   "w15-tac-7-m5-non-blink-stalkers-never-suicide-into-standard-natural"
   "wave15-repro" "Protoss" "Terran" "macro-tactics"
   "Wave-15b Calibration (#18 P v RustyNikolaj & #12 P v puck & Zerg metabolic-boost): Early non-Blink Stalkers/Sentry/Zealot at ~0.65x believed army must NOT suicide into an opponent's standard main-adjacent 2nd natural (2b vs 2b), and basic metabolic-boost must NOT disable slow Zerg fog protection"
   (lambda ()
     (define open-grid (mk-walkable-pathing-grid 200 200))
     ;; Part A (#18 Torches vertical-mirror shape): 2-base vs 2-base, standard main-adjacent enemy natural at (120, 152) (dist=25.6t <= 26t)
     ;; Our non-Blink squad: 6 Stalkers (1200) + 1 Sentry (200) + 1 Zealot (100) = 1500 val (~0.67x of believed army, 16 sup)
     (define v-mins (mk-mirror-minerals 'mirror-vertical))
     (define p-home (mk-home-base-units 'Protoss #:base-x 100.0 #:base-y 32.0 #:with-natural? #t #:nat-x 128.0 #:nat-y 52.0 #:workers 24))
     (define p-tags '(6301 6302 6303 6304 6305 6306 6307 6308))
     (define p-squad
       (append (for/list ([i (in-range 6)])
                 (mk-unit (+ 6301 i) 'stalker 1 (+ 98.0 (* i 0.8)) 86.0 #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))
               (list (mk-unit 6307 'sentry 1 99.0 84.5 #:hp 40.0 #:hp-max 40.0 #:shield 40.0 #:shield-max 40.0 #:energy 75.0)
                     (mk-unit 6308 'zealot 1 101.0 87.5 #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0))))
     (define enemy-std-2b
       (list (mk-unit 8950 'command-center 4 100.0 168.0 #:hp 1500.0 #:hp-max 1500.0)
             (mk-unit 8951 'command-center 4 118.0 154.0 #:hp 1500.0 #:hp-max 1500.0)))
     (define o-nat
       (last (run-pipeline-sequence 'Protoss 'Terran
               (list (hash 'obs (mk-obs 9000 (append p-home p-squad enemy-std-2b)
                                        #:upgrades '() #:food-used 40 #:food-cap 66 #:food-army 16 #:food-workers 24
                                        #:neutral-units v-mins #:camera-x 100.0 #:camera-y 32.0)))
               #:our-x 100.0 #:our-y 32.0 #:enemy-x 100.0 #:enemy-y 168.0
               #:pathing-grid open-grid #:neutral-units v-mins)))
     (define p-suicide-atk (wire-count-tags-heading-deep (step-outcome-wire-cmds o-nat) p-tags 118.0 154.0 #:enemy-tags '(8950 8951)))
     ;; Part B (Zerg metabolic-boost): Basic Ling speed finishing at f=9000 must NOT disable deep-fog protection for slow Roaches/Ravagers at ~0.55x!
     (define r-mins (mk-mirror-minerals 'rotational-180))
     (define z-home (mk-home-base-units 'Zerg #:base-x 32.0 #:base-y 32.0 #:workers 16))
     (define z-tags '(6321 6322 6323 6324 6325 6326))
     (define z-squad
       (append (for/list ([i (in-range 4)]) (mk-unit (+ 6321 i) 'roach 1 (+ 70.0 (* i 0.8)) 70.0 #:hp 145.0 #:hp-max 145.0))
               (list (mk-unit 6325 'ravager 1 70.5 72.0 #:hp 120.0 #:hp-max 120.0)
                     (mk-unit 6326 'ravager 1 72.0 72.0 #:hp 120.0 #:hp-max 120.0))))
     (define deep-gate (list (mk-unit 8955 'gateway 4 158.0 158.0 #:hp 500.0 #:hp-max 500.0 #:shield 500.0 #:shield-max 500.0)))
     (define o-zling
       (last (run-pipeline-sequence 'Zerg 'Protoss
               (list (hash 'obs (mk-obs 8900 (append z-home z-squad deep-gate)
                                        #:upgrades '() #:food-used 30 #:food-cap 54 #:food-army 14 #:food-workers 16
                                        #:neutral-units r-mins #:camera-x 32.0 #:camera-y 32.0))
                     (hash 'obs (mk-obs 9000 (append z-home z-squad deep-gate)
                                        #:upgrades '(metabolic-boost) #:food-used 30 #:food-cap 54 #:food-army 14 #:food-workers 16
                                        #:neutral-units r-mins #:camera-x 32.0 #:camera-y 32.0)))
               #:our-x 32.0 #:our-y 32.0 #:enemy-x 168.0 #:enemy-y 168.0
               #:pathing-grid open-grid #:neutral-units r-mins)))
     (define z-suicide-atk (wire-count-tags-with-ability (step-outcome-wire-cmds o-zling) z-tags AB-ATTACK))
     (define total-rej (+ (step-outcome-wire-rejects o-nat) (step-outcome-wire-rejects o-zling)))
     (values o-nat
             (list
              (mk-check "m5-non-blink-stalkers-never-suicide-into-standard-enemy-natural"
                        (= p-suicide-atk 0)
                        (format "Non-Blink Protoss squad heading into standard 2b enemy natural=~a/8 (expected 0)" p-suicide-atk))
              (mk-check "metabolic-boost-does-not-disable-slow-roach-fog-gate"
                        (= z-suicide-atk 0)
                        (format "Slow Roaches/Ravagers ATTACK deep after metabolic-boost=~a/6 (expected 0)" z-suicide-atk))
              (mk-check "zero-wire-rejects" (= total-rej 0)
                        (format "wire_rejects=~a" total-rej)))))))

(define scen-w15-tac-8
  (tactical-scenario
   "w15-tac-8-main-ramp-cliff-defense-and-no-split-squad-feeding"
   "wave15-repro" "Terran" "Protoss" "home-defense"
   "Wave-15c Smoking Guns (#443/#446): (a) High-ground main ramp cliff (eucl=13-16t, ground-BFS d_ours=33-35t, margin>>+6) triggers BOTH enemy-within-14-of-th? AND Own-Territory defense (zero false cliff-blocked?), while true chasm (d_ours>90t) stays rejected; (b) Empty Medivacs & 2 Adepts in mixed slow armies NEVER detach to feed alone under fog-only-suppressed?"
   (lambda ()
     ;; Part A1 & A2: Realistic high-ground main plateau cliff x=40..43, y=0..44 (ramp opening at y>=44)
     ;; Main=(32,32), Enemy=(168,168).
     ;; P1=(47,27): eucl=15.8t, walking around y=45 -> d_ours ~ 34.8t > 15.8+16 (old cliff-blocked?=#t BUG!), yet <= 38t & margin>>+100!
     ;; P2=(45,30): eucl=13.15t <= 14t, walking around y=45 -> d_ours ~ 33.5t > 13.15+16 (old cliff-blocked?=#t broke L19955 enemy-within-14-of-th?!)
     (define ramp-grid (mk-walkable-pathing-grid 200 200 #:wall-rects '((40 0 43 44))))
     (define ramp-mins
       (append (mk-mineral-cluster 93000 32.0 32.0)
               (mk-mineral-cluster 93010 168.0 168.0)))
     (define home-t (mk-home-base-units 'Terran #:base-x 32.0 #:base-y 32.0 #:workers 16))
     ;; A1: 5 outnumbered Marines at (45,38) (11.2t > fire-r 7.5t from P1!) vs 4 Stalkers + 2 Immortals at P1=(47,27) (eucl=15.8t > 14t, tests L18683)
     (define a1-tags '(6401 6402 6403 6404 6405))
     (define a1-defs (for/list ([i (in-range 5)]) (mk-unit (+ 6401 i) 'marine 1 (+ 45.0 (* i 0.6)) 38.0 #:hp 45.0 #:hp-max 45.0)))
     (define a1-enms
       (append (for/list ([i (in-range 4)]) (mk-unit (+ 8960 i) 'stalker 4 (+ 46.0 (* i 0.7)) 27.0 #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))
               (list (mk-unit 8965 'immortal 4 47.0 26.0 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0)
                     (mk-unit 8966 'immortal 4 48.0 26.0 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0))))
     (define o-a1
       (last (run-pipeline-sequence 'Terran 'Protoss
               (list (hash 'obs (mk-obs 9000 (append home-t a1-defs a1-enms)
                                        #:food-used 21 #:food-cap 45 #:food-army 5 #:food-workers 16
                                        #:neutral-units ramp-mins #:camera-x 32.0 #:camera-y 32.0)))
               #:our-x 32.0 #:our-y 32.0 #:enemy-x 168.0 #:enemy-y 168.0
               #:pathing-grid ramp-grid #:neutral-units ramp-mins)))
     (define a1-atk (wire-count-tags-with-ability (step-outcome-wire-cmds o-a1) a1-tags AB-ATTACK))
     (define a1-zone (bot-runtime-point-territory-zone (step-outcome-obs-hash o-a1) 47.0 27.0 #:air? #f))
     ;; A2: Only 3 heavily outnumbered Marines (<4!) at (45,40.5) (10.5t > fire-r 7.5t from P2!) vs 4 Stalkers + 2 Immortals at P2=(45,30) (eucl=13.15t <= 14t, tests L19955!)
     (define a2-tags '(6411 6412 6413))
     (define a2-defs (for/list ([i (in-range 3)]) (mk-unit (+ 6411 i) 'marine 1 (+ 44.5 (* i 0.7)) 40.5 #:hp 45.0 #:hp-max 45.0)))
     (define a2-enms
       (append (for/list ([i (in-range 4)]) (mk-unit (+ 8970 i) 'stalker 4 (+ 44.5 (* i 0.7)) 30.0 #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))
               (list (mk-unit 8975 'immortal 4 45.0 29.0 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0)
                     (mk-unit 8976 'immortal 4 46.0 29.0 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0))))
     (define o-a2
       (last (run-pipeline-sequence 'Terran 'Protoss
               (list (hash 'obs (mk-obs 9000 (append home-t a2-defs a2-enms)
                                        #:food-used 19 #:food-cap 45 #:food-army 3 #:food-workers 16
                                        #:neutral-units ramp-mins #:camera-x 32.0 #:camera-y 32.0)))
               #:our-x 32.0 #:our-y 32.0 #:enemy-x 168.0 #:enemy-y 168.0
               #:pathing-grid ramp-grid #:neutral-units ramp-mins)))
     (define a2-atk (wire-count-tags-with-ability (step-outcome-wire-cmds o-a2) a2-tags AB-ATTACK))
     ;; Part B1: Terran mixed slow army with 2 empty Medivacs + 6 Marines + 2 Tanks under fog-only-suppressed? -> 0 empty Medivacs detach!
     (define open-grid (mk-walkable-pathing-grid 200 200))
     (define rot-mins (mk-mirror-minerals 'rotational-180))
     (define b1-meds (list (mk-unit 6421 'medivac 1 68.0 70.0 #:hp 150.0 #:hp-max 150.0 #:energy 100.0)
                           (mk-unit 6422 'medivac 1 69.0 70.0 #:hp 150.0 #:hp-max 150.0 #:energy 100.0)))
     (define b1-gnd  (append (list (mk-unit 6423 'siege-tank 1 70.0 70.0 #:hp 175.0 #:hp-max 175.0)
                                   (mk-unit 6424 'siege-tank 1 71.5 70.0 #:hp 175.0 #:hp-max 175.0))
                             (for/list ([i (in-range 6)]) (mk-unit (+ 6425 i) 'marine 1 (+ 69.5 (* i 0.6)) 72.0 #:hp 45.0 #:hp-max 45.0))))
     (define deep-nex (list (mk-unit 8980 'nexus 4 168.0 168.0 #:hp 1000.0 #:hp-max 1000.0 #:shield 1000.0 #:shield-max 1000.0)))
     (define o-b1
       (last (run-pipeline-sequence 'Terran 'Protoss
               (list (hash 'obs (mk-obs 9000 (append home-t b1-meds b1-gnd deep-nex)
                                        #:food-used 32 #:food-cap 54 #:food-army 16 #:food-workers 16
                                        #:neutral-units rot-mins #:camera-x 32.0 #:camera-y 32.0)))
               #:our-x 32.0 #:our-y 32.0 #:enemy-x 168.0 #:enemy-y 168.0
               #:pathing-grid open-grid #:neutral-units rot-mins)))
     (define b1-med-deep (wire-count-tags-heading-deep (step-outcome-wire-cmds o-b1) '(6421 6422) 168.0 168.0 #:enemy-tags '(8980)))
     (define b1-gnd-deep (wire-count-tags-heading-deep (step-outcome-wire-cmds o-b1) '(6423 6424 6425 6426 6427 6428 6429 6430) 168.0 168.0 #:enemy-tags '(8980)))
     ;; Part B2: Protoss mixed slow army with 2 Adepts + 2 Immortals + 3 non-Blink Stalkers under fog-only-suppressed? -> 0 Adepts detach to feed!
     (define home-p (mk-home-base-units 'Protoss #:base-x 32.0 #:base-y 32.0 #:workers 16))
     (define b2-adepts (list (mk-unit 6441 'adept 1 70.0 70.0 #:hp 70.0 #:hp-max 70.0 #:shield 70.0 #:shield-max 70.0)
                             (mk-unit 6442 'adept 1 71.0 70.0 #:hp 70.0 #:hp-max 70.0 #:shield 70.0 #:shield-max 70.0)))
     (define b2-main   (append (list (mk-unit 6443 'immortal 1 68.0 68.0 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0)
                                     (mk-unit 6444 'immortal 1 69.5 68.0 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0))
                               (for/list ([i (in-range 3)]) (mk-unit (+ 6445 i) 'stalker 1 (+ 68.5 (* i 0.8)) 71.0 #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))))
     (define deep-cc (list (mk-unit 8981 'command-center 4 168.0 168.0 #:hp 1500.0 #:hp-max 1500.0)))
     (define o-b2
       (last (run-pipeline-sequence 'Protoss 'Terran
               (list (hash 'obs (mk-obs 9000 (append home-p b2-adepts b2-main deep-cc)
                                        #:food-used 34 #:food-cap 54 #:food-army 18 #:food-workers 16
                                        #:neutral-units rot-mins #:camera-x 32.0 #:camera-y 32.0)))
               #:our-x 32.0 #:our-y 32.0 #:enemy-x 168.0 #:enemy-y 168.0
               #:pathing-grid open-grid #:neutral-units rot-mins)))
     (define b2-adept-deep (wire-count-tags-heading-deep (step-outcome-wire-cmds o-b2) '(6441 6442) 168.0 168.0 #:enemy-tags '(8981)))
     (define b2-main-deep  (wire-count-tags-heading-deep (step-outcome-wire-cmds o-b2) '(6443 6444 6445 6446 6447) 168.0 168.0 #:enemy-tags '(8981)))
     (define total-rej (+ (step-outcome-wire-rejects o-a1) (step-outcome-wire-rejects o-a2)
                          (step-outcome-wire-rejects o-b1) (step-outcome-wire-rejects o-b2)))
     (values o-a1
             (list
              (mk-check "main-ramp-cliff-point-defended-as-own-territory"
                        (and (eq? a1-zone 'own-territory) (>= a1-atk 4))
                        (format "Main-ramp P1=(47,27) [eucl=15.8t, bfs=35t]: zone=~a, Marines ATTACK=~a/5 (expected >=4)" a1-zone a1-atk))
              (mk-check "main-ramp-foot-within-14t-fires-home-defense-without-false-cliff-block"
                        (>= a2-atk 2)
                        (format "Main-ramp foot P2=(45,30) [eucl=13.2t, bfs=33.5t]: 3 Marines ATTACK=~a/3 (expected >=2)" a2-atk))
              (mk-check "empty-medivacs-never-detach-from-held-back-bio-under-fog-suppress"
                        (and (= b1-med-deep 0) (= b1-gnd-deep 0))
                        (format "Empty Medivacs heading deep=~a/2, Bio/Tanks deep=~a/8 (expected 0/0)" b1-med-deep b1-gnd-deep))
              (mk-check "adepts-in-mixed-slow-army-never-detach-to-feed-alone"
                        (and (= b2-adept-deep 0) (= b2-main-deep 0))
                        (format "Adepts heading deep=~a/2, Immortals/Stalkers deep=~a/5 (expected 0/0)" b2-adept-deep b2-main-deep))
              (mk-check "zero-wire-rejects" (= total-rej 0)
                        (format "wire_rejects=~a" total-rej)))))))

;; -----------------------------------------------------------------------------
;; Tier 3 additions (Wave-16 regression shields): novel-133..134
;; -----------------------------------------------------------------------------
(define scen-novel-133
  (tactical-scenario
   "novel-133-clean-disengage-outside-tank-16t-shell-zone-no-yoyo"
   "novel" "Terran" "Terran" "siege-discipline"
   "Wave-16 shield: Small outnumbered ground squad safely OUTSIDE Sieged Tank shell range (18.0t > 16.0t, away from home) cleanly disengages/holds with 0 suicide ATTACK dives"
   (lambda ()
     (define home (mk-home-base-units 'Terran #:base-x 32.0 #:base-y 32.0 #:workers 16))
     (define mar-tags (for/list ([i (in-range 4)]) (+ 6501 i)))
     (define allies
       (append home
               (for/list ([i (in-range 4)])
                 (mk-unit (+ 6501 i) 'marine 1 72.0 (+ 78.5 (* i 1.0)) #:hp 45.0 #:hp-max 45.0))))
     (define enemies
       (append (for/list ([i (in-range 4)])
                 (mk-unit (+ 9501 i) 'siege-tank-sieged 4 90.0 (+ 77.0 (* i 2.0)) #:hp 175.0 #:hp-max 175.0))
               (for/list ([i (in-range 4)])
                 (mk-unit (+ 9511 i) 'marine 4 89.0 (+ 78.0 (* i 1.2)) #:hp 45.0 #:hp-max 45.0))))
     (define out
       (last (run-pipeline-sequence 'Terran 'Terran
               (list (hash 'obs (mk-obs 12000 (append allies enemies)
                                        #:food-used 20 #:food-cap 50 #:food-army 4 #:food-workers 16))))))
     (define wcmds (step-outcome-wire-cmds out))
     (define atk-cnt (wire-count-tags-with-ability wcmds mar-tags AB-ATTACK))
     (define mov-cnt (wire-count-tags-with-ability wcmds mar-tags AB-MOVE))
     (values out
             (list
              (mk-check "no-suicide-attack-from-18t-outside-tank-shell-zone" (= atk-cnt 0)
                        (format "4 outnumbered Marines at 18.0t vs 4 Sieged Tanks emitted ATTACK=~a/4 (expected 0)" atk-cnt))
              (mk-check "clean-disengage-move-outside-16t" (>= mov-cnt 3)
                        (format "4 outnumbered Marines at 18.0t emitted MOVE=~a/4 (expected >=3)" mov-cnt))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

(define scen-novel-134
  (tactical-scenario
   "novel-134-tempest-capital-air-dive-protoss-and-terran-no-0dps-kite"
   "novel" "Protoss" "Protoss" "capital-siege-dive"
   "Wave-16 shield (#5136387 P v who / #5136274 T v MetaScoreCritic): Outnumbered Protoss Stalkers and Terran Marine+Viking squads within 14t of enemy Tempests dive/fire (ATTACK) under capital-siege-dive instead of 0-DPS kiting"
   (lambda ()
     ;; Part A: Protoss 6 Stalkers at 14.0t vs 4 Tempests (outnumbered 12 vs 20 sup, away from home)
     (define home-p (mk-home-base-units 'Protoss #:base-x 32.0 #:base-y 32.0 #:workers 16))
     (define p-tags (for/list ([i (in-range 6)]) (+ 6521 i)))
     (define allies-p
       (append home-p
               (for/list ([i (in-range 6)])
                 (mk-unit (+ 6521 i) 'stalker 1 76.0 (+ 77.5 (* i 1.0)) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))))
     (define enemies-p
       (for/list ([i (in-range 4)])
         (mk-unit (+ 9521 i) 'tempest 4 90.0 (+ 77.0 (* i 2.0)) #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0 #:flying? #t)))
     (define out-p
       (last (run-pipeline-sequence 'Protoss 'Protoss
               (list (hash 'obs (mk-obs 16000 (append allies-p enemies-p)
                                        #:food-used 28 #:food-cap 60 #:food-army 12 #:food-workers 16))))))
     (define p-atk (wire-count-tags-with-ability (step-outcome-wire-cmds out-p) p-tags AB-ATTACK))
     ;; Part B: Terran 6 Marines + 2 Viking Fighters at 13.5t vs 4 Tempests (outnumbered 10 vs 20 sup)
     (define home-t (mk-home-base-units 'Terran #:base-x 32.0 #:base-y 32.0 #:workers 16))
     (define t-tags (append (for/list ([i (in-range 6)]) (+ 6531 i)) '(6541 6542)))
     (define allies-t
       (append home-t
               (for/list ([i (in-range 6)])
                 (mk-unit (+ 6531 i) 'marine 1 76.5 (+ 77.5 (* i 0.9)) #:hp 45.0 #:hp-max 45.0))
               (list (mk-unit 6541 'viking-fighter 1 76.5 79.0 #:hp 135.0 #:hp-max 135.0 #:flying? #t)
                     (mk-unit 6542 'viking-fighter 1 76.5 81.0 #:hp 135.0 #:hp-max 135.0 #:flying? #t))))
     (define enemies-t
       (for/list ([i (in-range 4)])
         (mk-unit (+ 9531 i) 'tempest 4 90.0 (+ 77.0 (* i 2.0)) #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0 #:flying? #t)))
     (define out-t
       (last (run-pipeline-sequence 'Terran 'Protoss
               (list (hash 'obs (mk-obs 16000 (append allies-t enemies-t)
                                        #:food-used 26 #:food-cap 60 #:food-army 10 #:food-workers 16))))))
     (define t-atk (wire-count-tags-with-ability (step-outcome-wire-cmds out-t) t-tags AB-ATTACK))
     (define total-rej (+ (step-outcome-wire-rejects out-p) (step-outcome-wire-rejects out-t)))
     (values out-p
             (list
              (mk-check "protoss-stalkers-dive-tempests-at-14t" (>= p-atk 4)
                        (format "Stalkers ATTACK=~a/6 vs 4 Tempests at 14.0t (expected >=4)" p-atk))
              (mk-check "terran-marine-viking-dives-tempests-at-13.5t" (>= t-atk 5)
                        (format "Marines+Vikings ATTACK=~a/8 vs 4 Tempests at 13.5t (expected >=5)" t-atk))
              (mk-check "zero-wire-rejects" (= total-rej 0)
                        (format "wire_rejects=~a" total-rej)))))))

;; -----------------------------------------------------------------------------
;; Tier 15: Wave-16 Siege0 3-Bug Chain, Terran Phantom Deduction & Corner Sweep (4)
;; -----------------------------------------------------------------------------
(define scen-w16-tac-1
  (tactical-scenario
   "w16-tac-1-zerg-ground-squad-in-siege-tank-shell-zone-commits-zero-yoyo"
   "wave16-repro" "Zerg" "Terran" "siege-zero-dps"
   "Wave-16 P0-1 (#16/#5134985/#5135912/#5136228): Zerglings/Roaches/Hydras at 10-12t inside Siege Tank shell zone (both 22t from our Hatchery and mid-map) commit ATTACK instead of 0-DPS backward yo-yo kiting"
   (lambda ()
     ;; Part A: 4 Sieged Tanks at 22.0t from our Hatchery (inside 30t home-defense, outside old 15.5t siege-shelling-friendly-structure?)
     ;; 10 Zerglings + 4 Roaches + 4 Hydralisks at 10-12t (inside 13.0t Tank splash, outside old 9.5t fire-r!)
     (define home-a (mk-home-base-units 'Zerg #:base-x 32.0 #:base-y 32.0 #:workers 16))
     (define ling-a-tags (for/list ([i (in-range 10)]) (+ 6601 i)))
     (define rng-a-tags  (append (for/list ([i (in-range 4)]) (+ 6611 i))
                                 (for/list ([i (in-range 4)]) (+ 6621 i))))
     (define allies-a
       (append home-a
               (for/list ([i (in-range 10)])
                 (mk-unit (+ 6601 i) 'zergling 1 43.0 (+ 29.5 (* i 0.5)) #:hp 35.0 #:hp-max 35.0))
               (for/list ([i (in-range 4)])
                 (mk-unit (+ 6611 i) 'roach 1 42.5 (+ 30.5 (* i 1.0)) #:hp 145.0 #:hp-max 145.0))
               (for/list ([i (in-range 4)])
                 (mk-unit (+ 6621 i) 'hydralisk 1 42.0 (+ 30.5 (* i 1.0)) #:hp 90.0 #:hp-max 90.0))))
     (define enemies-a
       (append (for/list ([i (in-range 4)])
                 (mk-unit (+ 9601 i) 'siege-tank-sieged 4 54.0 (+ 29.5 (* i 1.5)) #:hp 175.0 #:hp-max 175.0))
               (for/list ([i (in-range 4)])
                 (mk-unit (+ 9611 i) 'marine 4 52.5 (+ 30.0 (* i 1.2)) #:hp 45.0 #:hp-max 45.0))))
     (define out-a
       (last (run-pipeline-sequence 'Zerg 'Terran
               (list (hash 'obs (mk-obs 12000 (append allies-a enemies-a)
                                        #:food-used 37 #:food-cap 66 #:food-army 21 #:food-workers 16))))))
     (define a-ling-atk (wire-count-tags-with-ability (step-outcome-wire-cmds out-a) ling-a-tags AB-ATTACK))
     (define a-rng-atk  (wire-count-tags-with-ability (step-outcome-wire-cmds out-a) rng-a-tags AB-ATTACK))
     ;; Part B: Mid-map inside 13.0t Tank splash (away from home, outnumbered so can-break-siege-line? = #f!):
     ;; 6 Lings + 4 Roaches + 4 Hydras at 11.5t vs 4 Sieged Tanks + 6 Marines
     (define home-b (mk-home-base-units 'Zerg #:base-x 32.0 #:base-y 32.0 #:workers 16))
     (define b-tags (append (for/list ([i (in-range 6)]) (+ 6641 i))
                            (for/list ([i (in-range 4)]) (+ 6651 i))
                            (for/list ([i (in-range 4)]) (+ 6661 i))))
     (define allies-b
       (append home-b
               (for/list ([i (in-range 6)])
                 (mk-unit (+ 6641 i) 'zergling 1 78.5 (+ 78.0 (* i 0.7)) #:hp 35.0 #:hp-max 35.0))
               (for/list ([i (in-range 4)])
                 (mk-unit (+ 6651 i) 'roach 1 78.5 (+ 78.5 (* i 1.0)) #:hp 145.0 #:hp-max 145.0))
               (for/list ([i (in-range 4)])
                 (mk-unit (+ 6661 i) 'hydralisk 1 78.5 (+ 78.5 (* i 1.0)) #:hp 90.0 #:hp-max 90.0))))
     (define enemies-b
       (append (for/list ([i (in-range 4)])
                 (mk-unit (+ 9641 i) 'siege-tank-sieged 4 90.0 (+ 77.5 (* i 1.6)) #:hp 175.0 #:hp-max 175.0))
               (for/list ([i (in-range 6)])
                 (mk-unit (+ 9651 i) 'marine 4 90.0 (+ 77.5 (* i 1.0)) #:hp 45.0 #:hp-max 45.0))))
     (define out-b
       (last (run-pipeline-sequence 'Zerg 'Terran
               (list (hash 'obs (mk-obs 12400 (append allies-b enemies-b)
                                        #:food-used 35 #:food-cap 66 #:food-army 19 #:food-workers 16))))))
     (define b-atk (wire-count-tags-with-ability (step-outcome-wire-cmds out-b) b-tags AB-ATTACK))
     (define total-rej (+ (step-outcome-wire-rejects out-a) (step-outcome-wire-rejects out-b)))
     (values out-a
             (list
              (mk-check "own-territory-22t-zerglings-commit-against-tanks" (>= a-ling-atk 6)
                        (format "Own-territory 22t Zerglings ATTACK=~a/10 at 11.0t vs Sieged Tanks (expected >=6)" a-ling-atk))
              (mk-check "own-territory-22t-roach-hydra-commit-against-tanks" (>= a-rng-atk 5)
                        (format "Own-territory 22t Roach+Hydra ATTACK=~a/8 at 10-12t vs Sieged Tanks (expected >=5)" a-rng-atk))
              (mk-check "midmap-11.5t-shell-zone-zerg-commits-zero-yoyo" (>= b-atk 9)
                        (format "Mid-map 11.5t Zerg squad ATTACK=~a/14 vs 4 Sieged Tanks+6 Marines (expected >=9)" b-atk))
              (mk-check "zero-wire-rejects" (= total-rej 0)
                        (format "wire_rejects=~a" total-rej)))))))

(define scen-w16-tac-2
  (tactical-scenario
   "w16-tac-2-ranged-squad-under-pullback-suppress-dives-sieged-tanks-not-dead-code"
   "wave16-repro" "Terran" "Terran" "siege-zero-dps"
   "Wave-16 P0-1 (#17/#5135913/#5136226/#5136227/#5136343): Outnumbered Terran Bio and Protoss Stalkers trapped at 11t inside Tank shell zone under combat-suppress-attack? dive/fire (ATTACK) instead of L19053 unreachable dead-code retreat"
   (lambda ()
     ;; Part A (Terran nearest-enemy-tank + shell zone): 4 Marines + 2 Marauders at 11.0t vs 4 Sieged Tanks (outnumbered 8 vs 12 sup)
     (define home-t (mk-home-base-units 'Terran #:base-x 32.0 #:base-y 32.0 #:workers 16))
     (define t-tags (append (for/list ([i (in-range 4)]) (+ 6701 i)) '(6711 6712)))
     (define allies-t
       (append home-t
               (for/list ([i (in-range 4)])
                 (mk-unit (+ 6701 i) 'marine 1 79.0 (+ 78.5 (* i 0.9)) #:hp 45.0 #:hp-max 45.0))
               (list (mk-unit 6711 'marauder 1 79.0 79.5 #:hp 125.0 #:hp-max 125.0)
                     (mk-unit 6712 'marauder 1 79.0 81.0 #:hp 125.0 #:hp-max 125.0))))
     (define enemies-t
       (for/list ([i (in-range 4)])
         (mk-unit (+ 9701 i) 'siege-tank-sieged 4 90.0 (+ 77.5 (* i 1.5)) #:hp 175.0 #:hp-max 175.0)))
     (define out-t
       (last (run-pipeline-sequence 'Terran 'Terran
               (list (hash 'obs (mk-obs 13000 (append allies-t enemies-t)
                                        #:food-used 24 #:food-cap 50 #:food-army 8 #:food-workers 16))))))
     (define t-atk (wire-count-tags-with-ability (step-outcome-wire-cmds out-t) t-tags AB-ATTACK))
     ;; Part B (Direct L19053 capital-siege-dive? dead-code repro): 6 Stalkers at 11.5t vs 1 Sieged Tank (front) + 12 Marines + 2 Marauders (rear)
     ;; Only 1 Tank -> bypasses siege-line-hold? (>=2 Tanks), enters combat-suppress-attack? directly with target=siege-tank-sieged at 11.5t!
     (define home-p (mk-home-base-units 'Protoss #:base-x 32.0 #:base-y 32.0 #:workers 16))
     (define p-tags (for/list ([i (in-range 6)]) (+ 6721 i)))
     (define allies-p
       (append home-p
               (for/list ([i (in-range 6)])
                 (mk-unit (+ 6721 i) 'stalker 1 78.5 (+ 77.5 (* i 1.0)) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))))
     (define enemies-p
       (append (list (mk-unit 9721 'siege-tank-sieged 4 90.0 80.0 #:hp 175.0 #:hp-max 175.0))
               (for/list ([i (in-range 12)])
                 (mk-unit (+ 9730 i) 'marine 4 94.0 (+ 75.5 (* i 0.8)) #:hp 45.0 #:hp-max 45.0))
               (list (mk-unit 9751 'marauder 4 94.5 79.0 #:hp 125.0 #:hp-max 125.0)
                     (mk-unit 9752 'marauder 4 94.5 81.0 #:hp 125.0 #:hp-max 125.0))))
     (define out-p
       (last (run-pipeline-sequence 'Protoss 'Terran
               (list (hash 'obs (mk-obs 13000 (append allies-p enemies-p)
                                        #:food-used 28 #:food-cap 50 #:food-army 12 #:food-workers 16))))))
     (define p-atk (wire-count-tags-with-ability (step-outcome-wire-cmds out-p) p-tags AB-ATTACK))
     (define total-rej (+ (step-outcome-wire-rejects out-t) (step-outcome-wire-rejects out-p)))
     (values out-t
             (list
              (mk-check "terran-bio-in-11t-tank-shell-zone-dives-under-suppress" (>= t-atk 4)
                        (format "Terran 4M+2MR at 11.0t vs 4 Sieged Tanks ATTACK=~a/6 (expected >=4)" t-atk))
              (mk-check "protoss-stalkers-hit-l19053-tank-dive-under-suppress" (>= p-atk 4)
                        (format "Protoss 6 Stalkers at 11.5t vs 1 Sieged Tank+Bio (L19053) ATTACK=~a/6 (expected >=4)" p-atk))
              (mk-check "zero-wire-rejects" (= total-rej 0)
                        (format "wire_rejects=~a" total-rej)))))))

(define scen-w16-tac-3
  (tactical-scenario
   "w16-tac-3-terran-phantom-deduction-never-freezes-scv-marine-tank-training"
   "wave16-repro" "Terran" "Zerg" "macro-production"
   "Wave-16 P0-2 (#17 147s Terran production freeze at 1,060M/409G, sup=28/46): Failing Phase 1/2 expand/barracks-techlab/starport-addon retries must NOT phantom-deduct bank or steal open-prod-slots ahead of SCV, Marine, and Siege Tank training"
   (lambda ()
     ;; Reconstruct exact #17 f=5712 Terran board state:
     ;; 2 Orbitals, 22 SCVs, 1 bare Barracks (addon east blocked), 1 Factory+TechLab, 1 bare Starport (addon east blocked),
     ;; 2 Refineries, 4 Depots, 4 Marines + 1 Tank, bank 1,060M/409G, sup 28/46 across 3 ticks spaced 40f apart (>36f addon refractory).
     (define pgrid (mk-walkable-pathing-grid 200 200 #:wall-rects '((39 34 44 39) (39 46 44 51))))
     (define base-units
       (append
        (list (mk-unit 1001 'orbital-command 1 32.0 32.0 #:energy 20.0 #:assigned 16 #:ideal 16)
              (mk-unit 1002 'orbital-command 1 52.0 32.0 #:energy 20.0 #:assigned 6 #:ideal 16)
              (mk-unit 1201 'supply-depot 1 40.5 35.5)
              (mk-unit 1202 'supply-depot 1 40.5 47.5)
              (mk-unit 1203 'supply-depot 1 35.0 28.0)
              (mk-unit 1204 'supply-depot 1 37.5 28.0)
              (mk-unit 1301 'barracks 1 38.0 36.0)
              (mk-unit 1302 'factory 1 38.0 42.0 #:add-on-tag 1303)
              (mk-unit 1303 'factory-techlab 1 40.5 41.5)
              (mk-unit 1304 'starport 1 38.0 48.0)
              (mk-unit 1311 'refinery 1 28.0 26.0 #:assigned 3 #:ideal 3)
              (mk-unit 1312 'refinery 1 36.0 25.0 #:assigned 3 #:ideal 3))
        (for/list ([i (in-range 22)])
          (mk-unit (+ 1100 i) 'scv 1
                   (+ 27.0 (* 0.35 (modulo i 6)))
                   (+ 30.0 (* 0.45 (quotient i 6)))
                   #:orders (list (sc2-unit-order AB-GATHER #f 90001 0.0))))
        (for/list ([i (in-range 4)])
          (mk-unit (+ 1401 i) 'marine 1 56.0 (+ 34.0 (* i 0.9)) #:hp 45.0 #:hp-max 45.0))
        (list (mk-unit 1405 'siege-tank 1 55.0 36.0 #:hp 175.0 #:hp-max 175.0))
        ;; Distant scouted enemy so match is live mid-game
        (list (mk-unit 9801 'hatchery 4 160.0 160.0 #:hp 1500.0 #:hp-max 1500.0))))
     (define steps
       (for/list ([f (in-list '(5712 5752 5792))])
         (hash 'obs (mk-obs f base-units
                            #:minerals 700 #:vespene 350
                            #:food-used 28 #:food-cap 46 #:food-army 6 #:food-workers 22))))
     (define outs
       (run-pipeline-sequence 'Terran 'Zerg steps
                              #:our-x 32.0 #:our-y 32.0 #:enemy-x 160.0 #:enemy-y 160.0
                              #:placement-grid pgrid))
     (define all-wcmds (apply append (map step-outcome-wire-cmds outs)))
     (define trained-scv?    (wire-has-ability? all-wcmds '(1001 1002) AB-TRAIN-SCV))
     (define trained-marine? (wire-has-ability? all-wcmds '(1301) AB-TRAIN-MARINE))
     (define trained-tank?   (wire-has-ability? all-wcmds '(1302) AB-TRAIN-SIEGE-TANK))
     (define total-rej (for/sum ([o (in-list outs)]) (step-outcome-wire-rejects o)))
     (values (last outs)
             (list
              (mk-check "terran-trains-scv-despite-retrying-phase12-builds" trained-scv?
                        (format "Orbital 1001/1002 emitted TRAIN_SCV (524)=~a across 3 ticks at 1,060M/409G" trained-scv?))
              (mk-check "terran-trains-marine-despite-blocked-barracks-addon" trained-marine?
                        (format "Bare Barracks 1301 emitted TRAIN_MARINE (560)=~a (slot not stolen by blocked TechLab)" trained-marine?))
              (mk-check "terran-trains-siege-tank-despite-phase12-deductions" trained-tank?
                        (format "Factory+TL 1302 emitted TRAIN_SIEGE_TANK (591)=~a across 3 ticks at 1,060M/409G" trained-tank?))
              (mk-check "zero-wire-rejects" (= total-rej 0)
                        (format "wire_rejects=~a" total-rej)))))))

(define scen-w16-tac-4
  (tactical-scenario
   "w16-tac-4-endgame-lifted-building-and-1scv-corner-sweep-zero-stall"
   "wave16-repro" "Terran" "Terran" "endgame-sweep"
   "Wave-16 P1-2 (#5135717 T v Carcara): Dominating Terran army with enemy main cleared and only 1 enemy SCV + lifted corner Barracks emits continuous preserved sweep ATTACK orders, rotates after waypoint timeout (zero home stall), and attacks visible flying corner building"
   (lambda ()
     (define open-grid (mk-walkable-pathing-grid 200 200))
     ;; Minimal 2-base minerals so primary-wps has only 3 unvisited targets outside enemy main (168,168):
     ;; after 3 timeout cycles (>672f each), timed-out waypoints MUST be marked visited to unlock the fallback grid!
     (define mins (append (mk-mineral-cluster 91101 26.0 32.0)
                          (mk-mineral-cluster 91111 174.0 168.0)))
     (define home
       (append
        (list (mk-unit 1001 'orbital-command 1 32.0 32.0 #:energy 100.0 #:assigned 16 #:ideal 16)
              (mk-unit 1002 'orbital-command 1 52.0 32.0 #:energy 100.0 #:assigned 16 #:ideal 16)
              (mk-unit 1003 'orbital-command 1 72.0 32.0 #:energy 100.0 #:assigned 12 #:ideal 16))
        (for/list ([i (in-range 20)])
          (mk-unit (+ 1100 i) 'scv 1 (+ 27.0 (* 0.3 (modulo i 6))) (+ 30.0 (* 0.4 (quotient i 6)))
                   #:orders (list (sc2-unit-order AB-GATHER #f 91101 0.0))))))
     (define mar-tags (for/list ([i (in-range 12)]) (+ 6801 i)))
     (define mrd-tags (for/list ([i (in-range 4)])  (+ 6821 i)))
     (define vik-tags (for/list ([i (in-range 4)])  (+ 6831 i)))
     (define army-tags (append mar-tags mrd-tags vik-tags))
     ;; Place 1 Viking at enemy main (168,168) so enemy-main-cleared? -> #t, rest of army mid-map
     (define army-units
       (append
        (for/list ([i (in-range 12)])
          (mk-unit (+ 6801 i) 'marine 1 118.0 (+ 114.0 (* i 0.7)) #:hp 45.0 #:hp-max 45.0))
        (for/list ([i (in-range 4)])
          (mk-unit (+ 6821 i) 'marauder 1 120.0 (+ 116.0 (* i 1.0)) #:hp 125.0 #:hp-max 125.0))
        (list (mk-unit 6831 'viking-fighter 1 168.0 168.0 #:hp 135.0 #:hp-max 135.0 #:flying? #t)
              (mk-unit 6832 'viking-fighter 1 122.0 118.0 #:hp 135.0 #:hp-max 135.0 #:flying? #t)
              (mk-unit 6833 'viking-fighter 1 122.0 120.0 #:hp 135.0 #:hp-max 135.0 #:flying? #t)
              (mk-unit 6834 'viking-fighter 1 122.0 122.0 #:hp 135.0 #:hp-max 135.0 #:flying? #t))))
     (define lone-scv (list (mk-unit 9851 'scv 4 105.0 95.0 #:hp 45.0 #:hp-max 45.0)))
     ;; Part A: 6 steps (f=24000 initial sweep + scan; f=24016 inside refractory no home recall;
     ;; f=24720, 25440, 26160, 26880 after >672f timeouts must mark timed-out waypoints visited and unlock >=4 distinct grid targets!)
     (define outs-a
       (run-pipeline-sequence 'Terran 'Terran
         (for/list ([f (in-list '(24000 24016 24720 25440 26160 26880))])
           (hash 'obs (mk-obs f (append home army-units lone-scv)
                              #:minerals 2500 #:vespene 1200
                              #:food-used 170 #:food-cap 200 #:food-army 120 #:food-workers 50
                              #:neutral-units mins #:camera-x 32.0 #:camera-y 32.0)))
         #:our-x 32.0 #:our-y 32.0 #:enemy-x 168.0 #:enemy-y 168.0
         #:pathing-grid open-grid #:neutral-units mins))
     (define o1 (first outs-a))
     (define o2 (second outs-a))
     (define timeout-outs (list o1 (third outs-a) (fourth outs-a) (fifth outs-a) (sixth outs-a)))
     (define atk1 (wire-count-tags-with-ability (step-outcome-wire-cmds o1) army-tags AB-ATTACK))
     (define scan1? (wire-has-ability? (step-outcome-wire-cmds o1) '(1001 1002 1003) AB-SCANNER-SWEEP))
     (define home-mov2
       (for/sum ([t (in-list army-tags)])
         (if (ormap (lambda (c)
                      (and (= (sc2-raw-unit-command-ability-id c) AB-MOVE)
                           (let ([p (sc2-raw-unit-command-target-pos c)])
                             (and p (<= (dist2d-xy (sc2-point2d-x p) (sc2-point2d-y p) 32.0 32.0) 30.0)))))
                    (wire-cmds-for-tag (step-outcome-wire-cmds o2) t))
             1 0)))
     (define (first-atk-pt wcmds tag)
       (for/first ([c (in-list (wire-cmds-for-tag wcmds tag))]
                   #:when (and (= (sc2-raw-unit-command-ability-id c) AB-ATTACK)
                               (sc2-raw-unit-command-target-pos c)))
         (define p (sc2-raw-unit-command-target-pos c))
         (cons (sc2-point2d-x p) (sc2-point2d-y p))))
     (define mar-pts (filter values (for/list ([o (in-list timeout-outs)]) (first-atk-pt (step-outcome-wire-cmds o) 6801))))
     (define distinct-mar-pts
       (for/fold ([acc '()]) ([p (in-list mar-pts)])
         (if (ormap (lambda (q) (<= (dist2d-xy (car p) (cdr p) (car q) (cdr q)) 5.0)) acc)
             acc
             (cons p acc))))
     (define atk-last (wire-count-tags-with-ability (step-outcome-wire-cmds (sixth outs-a)) army-tags AB-ATTACK))
     ;; Part B: Visible lifted barracks-flying in map corner (18, 182) -> Vikings immediately ATTACK it!
     (define lifted-rax (list (mk-unit 9861 'barracks-flying 4 18.0 182.0 #:hp 1000.0 #:hp-max 1000.0 #:flying? #t)))
     (define o-b
       (last (run-pipeline-sequence 'Terran 'Terran
               (list (hash 'obs (mk-obs 25000 (append home army-units lifted-rax)
                                        #:minerals 2500 #:vespene 1200
                                        #:food-used 170 #:food-cap 200 #:food-army 120 #:food-workers 50
                                        #:neutral-units mins #:camera-x 32.0 #:camera-y 32.0)))
               #:our-x 32.0 #:our-y 32.0 #:enemy-x 168.0 #:enemy-y 168.0
               #:pathing-grid open-grid #:neutral-units mins)))
     (define vik-atk-lifted (wire-count-tags-with-ability (step-outcome-wire-cmds o-b) vik-tags AB-ATTACK))
     (define total-rej (+ (for/sum ([o (in-list outs-a)]) (step-outcome-wire-rejects o))
                          (step-outcome-wire-rejects o-b)))
     (values (sixth outs-a)
             (list
              (mk-check "step1-dominating-army-emits-preserved-sweep-and-scan" (and (>= atk1 14) scan1?)
                        (format "Step1 sweep ATTACK=~a/20 (expected >=14), Orbital Scan=~a" atk1 scan1?))
              (mk-check "step2-inside-refractory-zero-home-stall-recall" (= home-mov2 0)
                        (format "Step2 units recalled to home (32,32)=~a/20 (expected 0)" home-mov2))
              (mk-check "timeout-cycles-mark-visited-and-unlock-fallback-grid"
                        (and (>= atk-last 14) (>= (length distinct-mar-pts) 4))
                        (format "Last ATTACK=~a/20, distinct Marine targets across 5 timeout cycles=~a (expected >=4; pts=~a)"
                                atk-last (length distinct-mar-pts) mar-pts))
              (mk-check "part-b-vikings-attack-visible-lifted-corner-barracks" (>= vik-atk-lifted 3)
                        (format "Vikings ATTACK lifted barracks-flying at (18,182)=~a/4 (expected >=3)" vik-atk-lifted))
              (mk-check "zero-wire-rejects" (= total-rej 0)
                        (format "wire_rejects=~a" total-rej)))))))

;; -----------------------------------------------------------------------------
;; Tier 3 additions (Wave-17 regression shields): novel-135..136
;; -----------------------------------------------------------------------------
(define scen-novel-135
  (tactical-scenario
   "novel-135-zerg-larva-spending-with-lair-and-hydraden-never-starves"
   "novel" "Zerg" "Terran" "macro-production"
   "Wave-17 shield: Saturated mid-game 5-base Zerg with Lair, RoachWarren, HydraliskDen, BanelingNest, Spire, 5 Queens, 72 Drones, 10 idle Larvae, and 1,500M/700G spends surplus Larvae into combat units cleanly with 0 wire rejects"
   (lambda ()
     (define larva-tags (for/list ([i (in-range 10)]) (+ 6901 i)))
     (define units
       (append
        (list (mk-unit 1001 'lair 1 32.0 32.0 #:assigned 16 #:ideal 16)
              (mk-unit 1002 'hatchery 1 52.0 32.0 #:assigned 16 #:ideal 16)
              (mk-unit 1003 'hatchery 1 72.0 32.0 #:assigned 16 #:ideal 16)
              (mk-unit 1004 'hatchery 1 32.0 54.0 #:assigned 16 #:ideal 16)
              (mk-unit 1005 'hatchery 1 52.0 54.0 #:assigned 8 #:ideal 16)
              (mk-unit 1301 'spawning-pool 1 36.0 36.0)
              (mk-unit 1302 'roach-warren 1 38.0 36.0)
              (mk-unit 1303 'hydralisk-den 1 40.0 36.0)
              (mk-unit 1304 'baneling-nest 1 42.0 36.0)
              (mk-unit 1305 'spire 1 44.0 36.0)
              (mk-unit 1306 'evolution-chamber 1 46.0 36.0)
              (mk-unit 1307 'infestation-pit 1 48.0 36.0)
              (mk-unit 1308 'lurker-den-mp 1 50.0 36.0)
              (mk-unit 1311 'extractor 1 28.0 26.0 #:assigned 3 #:ideal 3)
              (mk-unit 1312 'extractor 1 36.0 25.0 #:assigned 3 #:ideal 3)
              (mk-unit 1313 'extractor 1 52.0 25.0 #:assigned 3 #:ideal 3)
              (mk-unit 1321 'overlord 1 30.0 35.0 #:flying? #t))
        (for/list ([i (in-range 72)])
          (mk-unit (+ 1100 i) 'drone 1 (+ 27.0 (* 0.25 (modulo i 10))) (+ 30.0 (* 0.35 (quotient i 10)))
                   #:orders (list (sc2-unit-order AB-GATHER #f 90001 0.0))))
        (for/list ([i (in-range 6)])
          (mk-unit (+ 1250 i) 'queen 1 (+ 34.0 (* i 2.5)) 33.0 #:hp 175.0 #:hp-max 175.0))
        (for/list ([i (in-range 10)])
          (mk-unit (+ 6901 i) 'larva 1 (+ 32.0 (* 0.3 (modulo i 5))) (+ 34.5 (* 0.3 (quotient i 5)))))
        (for/list ([i (in-range 6)])
          (mk-unit (+ 6921 i) 'roach 1 60.0 (+ 34.0 (* i 0.9)) #:hp 145.0 #:hp-max 145.0))
        (list (mk-unit 9901 'command-center 4 160.0 160.0 #:hp 1500.0 #:hp-max 1500.0)
              (mk-unit 9902 'marine 4 150.0 150.0 #:hp 45.0 #:hp-max 45.0)
              (mk-unit 9903 'siege-tank-sieged 4 152.0 150.0 #:hp 175.0 #:hp-max 175.0))))
     (define outs
       (run-pipeline-sequence 'Zerg 'Terran
         (list (hash 'obs (mk-obs 10500 units
                                  #:minerals 1800 #:vespene 900
                                  #:food-used 116 #:food-cap 170 #:food-army 44 #:food-workers 72
                                  #:larva-count 10 #:upgrades '(metabolic-boost)))
               (hash 'obs (mk-obs 10540 units
                                  #:minerals 1800 #:vespene 900
                                  #:food-used 116 #:food-cap 170 #:food-army 44 #:food-workers 72
                                  #:larva-count 10 #:upgrades '(metabolic-boost))))))
     (define out (last outs))
     (define wcmds (apply append (map step-outcome-wire-cmds outs)))
     (define combat-train-cnt
       (for/sum ([t (in-list larva-tags)])
         (define abs (wire-abilities-for-tag wcmds t))
         (if (ormap (lambda (ab) (memv ab abs))
                    (list AB-TRAIN-HYDRALISK AB-TRAIN-ROACH AB-TRAIN-ZERGLING AB-TRAIN-MUTALISK AB-TRAIN-CORRUPTOR))
             1 0)))
     (define total-rej (for/sum ([o (in-list outs)]) (step-outcome-wire-rejects o)))
     (values out
             (list
              (mk-check "zerg-spends-larvae-into-combat-units" (>= combat-train-cnt 2)
                        (format "Larvae trained into Hydra/Roach/Ling/Muta/Corruptor=~a/10 at 1,800M/900G (expected >=2)" combat-train-cnt))
              (mk-check "zero-wire-rejects" (= total-rej 0)
                        (format "wire_rejects=~a" total-rej)))))))

(define scen-novel-136
  (tactical-scenario
   "novel-136-protoss-and-terran-natural-defense-vs-marauder-bio-push"
   "novel" "Protoss" "Terran" "home-defense"
   "Wave-17 shield: Protoss Immortal+Stalker+Zealot natural defenders hold and ATTACK against incoming Marauder+Marine push without backward OBRet flee"
   (lambda ()
     (define home (mk-home-base-units 'Protoss #:base-x 32.0 #:base-y 32.0 #:with-natural? #t #:nat-x 52.0 #:nat-y 32.0 #:workers 22))
     (define def-tags '(6951 6952 6953 6954 6955 6956 6957 6958 6959))
     (define defenders
       (list (mk-unit 6951 'immortal 1 56.0 31.0 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0)
             (mk-unit 6952 'immortal 1 56.0 33.0 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0)
             (mk-unit 6953 'stalker 1 55.5 29.5 #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0)
             (mk-unit 6954 'stalker 1 55.5 30.5 #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0)
             (mk-unit 6955 'stalker 1 55.5 32.0 #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0)
             (mk-unit 6956 'stalker 1 55.5 33.5 #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0)
             (mk-unit 6957 'stalker 1 55.5 34.5 #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0)
             (mk-unit 6958 'zealot 1 57.5 31.0 #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0)
             (mk-unit 6959 'zealot 1 57.5 33.0 #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0)))
     (define enemies
       (append (for/list ([i (in-range 6)])
                 (mk-unit (+ 9921 i) 'marauder 4 65.5 (+ 29.5 (* i 1.0)) #:hp 125.0 #:hp-max 125.0))
               (for/list ([i (in-range 6)])
                 (mk-unit (+ 9931 i) 'marine 4 66.5 (+ 29.5 (* i 0.9)) #:hp 45.0 #:hp-max 45.0))))
     (define out
       (last (run-pipeline-sequence 'Protoss 'Terran
               (list (hash 'obs (mk-obs 7200 (append home defenders enemies)
                                        #:food-used 46 #:food-cap 66 #:food-army 24 #:food-workers 22))))))
     (define atk-cnt (wire-count-tags-with-ability (step-outcome-wire-cmds out) def-tags AB-ATTACK))
     (values out
             (list
              (mk-check "protoss-natural-defenders-engage-marauder-bio" (>= atk-cnt 6)
                        (format "Protoss natural defenders ATTACK=~a/9 vs 6 Marauders+6 Marines (expected >=6)" atk-cnt))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; -----------------------------------------------------------------------------
;; Tier 16: Wave-17 Peaceful Terran Freeze, Zerg Lair/Larva Freeze, 0G Gas & Proxy Marauder (4)
;; -----------------------------------------------------------------------------
(define scen-w17-tac-1
  (tactical-scenario
   "w17-tac-1-terran-peaceful-midgame-never-freezes-scv-marine-tank-starport"
   "wave17-repro" "Terran" "Terran" "macro-production"
   "Wave-17 P0-1 (#17/#11/#5134986/#5136226 143s peaceful Terran freeze): 2 completed Bunkers (1 loaded, 1 empty) at f>5700 must NOT spam salvage (ab=32) every 4f and starve APM headroom for SCV, Bio, SiegeTank, and Starport"
   (lambda ()
     (define units
       (append
        (list (mk-unit 1001 'orbital-command 1 32.0 32.0 #:energy 20.0 #:assigned 16 #:ideal 16)
              (mk-unit 1002 'orbital-command 1 52.0 32.0 #:energy 20.0 #:assigned 6 #:ideal 16)
              (mk-unit 1201 'supply-depot 1 35.0 27.0)
              (mk-unit 1202 'supply-depot 1 37.5 27.0)
              (mk-unit 1203 'supply-depot 1 40.0 27.0)
              (mk-unit 1204 'supply-depot 1 42.5 27.0)
              (mk-unit 1205 'supply-depot 1 45.0 27.0)
              ;; 2 completed Bunkers (1 loaded w/ cargo-taken=4, 1 empty) that triggered 1,344 APM P0 salvage spam in #17/#11!
              (mk-unit 1211 'bunker 1 56.0 30.0 #:hp 400.0 #:hp-max 400.0 #:cargo-taken 4 #:cargo-max 4)
              (mk-unit 1212 'bunker 1 56.0 34.0 #:hp 400.0 #:hp-max 400.0 #:cargo-taken 0 #:cargo-max 4)
              (mk-unit 1301 'barracks 1 38.0 36.0 #:add-on-tag 1302)
              (mk-unit 1302 'barracks-techlab 1 40.5 35.5)
              (mk-unit 1303 'factory 1 38.0 42.0 #:add-on-tag 1304)
              (mk-unit 1304 'factory-techlab 1 40.5 41.5)
              (mk-unit 1311 'refinery 1 28.0 26.0 #:assigned 3 #:ideal 3)
              (mk-unit 1312 'refinery 1 36.0 25.0 #:assigned 3 #:ideal 3)
              (mk-unit 1315 'engineering-bay 1 33.0 39.0))
        (for/list ([i (in-range 22)])
          (mk-unit (+ 1100 i) 'scv 1
                   (+ 27.0 (* 0.35 (modulo i 6)))
                   (+ 30.0 (* 0.45 (quotient i 6)))
                   #:orders (list (sc2-unit-order AB-GATHER #f 90001 0.0))))
        (for/list ([i (in-range 4)])
          (mk-unit (+ 1401 i) 'marine 1 58.0 (+ 34.0 (* i 0.9)) #:hp 45.0 #:hp-max 45.0))
        (list (mk-unit 1405 'siege-tank 1 55.0 36.0 #:hp 175.0 #:hp-max 175.0)
              ;; Distant enemy CC only -> under-base-attack? = #f!
              (mk-unit 9941 'command-center 4 160.0 160.0 #:hp 1500.0 #:hp-max 1500.0))))
     (define scv-tags (for/list ([i (in-range 22)]) (+ 1100 i)))
     ;; 8 consecutive 4f steps (f=5712..5740): pre-W17 emitted 2x salvage/step = 16 salvage cmds starving P1 macro!
     (define steps
       (for/list ([i (in-range 8)])
         (hash 'obs (mk-obs (+ 5712 (* i 4)) units
                            #:minerals 2000 #:vespene 500
                            #:food-used 28 #:food-cap 54 #:food-army 6 #:food-workers 22))))
     (define outs
       (run-pipeline-sequence 'Terran 'Terran steps
                              #:our-x 32.0 #:our-y 32.0 #:enemy-x 160.0 #:enemy-y 160.0))
     (define all-wcmds (apply append (map step-outcome-wire-cmds outs)))
     (define loaded-salvage-cnt
       (length (filter (lambda (c) (= (sc2-raw-unit-command-ability-id c) AB-SALVAGE-BUNKER))
                       (wire-cmds-for-tag all-wcmds 1211))))
     (define total-salvage-cnt
       (length (filter (lambda (c) (= (sc2-raw-unit-command-ability-id c) AB-SALVAGE-BUNKER))
                       (append (wire-cmds-for-tag all-wcmds 1211)
                               (wire-cmds-for-tag all-wcmds 1212)))))
     (define trained-scv?      (wire-has-ability? all-wcmds '(1001 1002) AB-TRAIN-SCV))
     (define trained-bio?      (or (wire-has-ability? all-wcmds '(1301) AB-TRAIN-MARINE)
                                   (wire-has-ability? all-wcmds '(1301) AB-TRAIN-MARAUDER)))
     (define trained-tank?     (wire-has-ability? all-wcmds '(1303) AB-TRAIN-SIEGE-TANK))
     (define built-starport?   (wire-has-ability? all-wcmds scv-tags AB-BUILD-STARPORT))
     (define total-rej (for/sum ([o (in-list outs)]) (step-outcome-wire-rejects o)))
     (values (last outs)
             (list
              (mk-check "loaded-bunker-never-emits-salvage" (= loaded-salvage-cnt 0)
                        (format "Loaded Bunker 1211 (cargo=4/4) emitted SALVAGE (32)=~a across 8 steps (expected 0)" loaded-salvage-cnt))
              (mk-check "bunker-salvage-never-spams-4f-apm-cap" (<= total-salvage-cnt 1)
                        (format "Total SALVAGE (32) cmds across 8 4f steps=~a (expected <=1; pre-W17 spammed 16)" total-salvage-cnt))
              (mk-check "peaceful-terran-trains-scv" trained-scv?
                        (format "Orbitals 1001/1002 emitted TRAIN_SCV (524)=~a at 2,000M/500G" trained-scv?))
              (mk-check "peaceful-terran-trains-bio" trained-bio?
                        (format "Barracks+TL 1301 emitted TRAIN_MARINE/MARAUDER (560/563)=~a" trained-bio?))
              (mk-check "peaceful-terran-trains-siege-tank" trained-tank?
                        (format "Factory+TL 1303 emitted TRAIN_SIEGE_TANK (591)=~a" trained-tank?))
              (mk-check "peaceful-terran-builds-starport" built-starport?
                        (format "SCVs emitted BUILD_STARPORT (329)=~a across 8 steps at 2,000M/500G" built-starport?))
              (mk-check "zero-wire-rejects" (= total-rej 0)
                        (format "wire_rejects=~a" total-rej)))))))

(define scen-w17-tac-2
  (tactical-scenario
   "w17-tac-2-zerg-15k-bank-5-hatcheries-morphs-lair-and-spends-idle-larvae"
   "wave17-repro" "Zerg" "Zerg" "macro-production"
   "Wave-17 P0-2 (#1 Z v titania ZvZ SwarmVictory 15,680M/1,017G, 5 Hatcheries, 0 Lair, 64 Lings, 50 idle Larvae, 0 visible enemy combat units): Zerg MUST morph Lair (1216) AND spend idle Larvae on combat units (Roach/Ling)"
   (lambda ()
     (define hatch-tags '(1001 1002 1003 1004 1005))
     (define larva-tags (for/list ([i (in-range 15)]) (+ 7001 i)))
     (define units
       (append
        (list (mk-unit 1001 'hatchery 1 32.0 32.0 #:assigned 16 #:ideal 16)
              (mk-unit 1002 'hatchery 1 52.0 32.0 #:assigned 16 #:ideal 16)
              (mk-unit 1003 'hatchery 1 72.0 32.0 #:assigned 16 #:ideal 16)
              (mk-unit 1004 'hatchery 1 32.0 54.0 #:assigned 14 #:ideal 16)
              (mk-unit 1005 'hatchery 1 52.0 54.0 #:assigned 10 #:ideal 16)
              (mk-unit 1301 'spawning-pool 1 36.0 36.0)
              (mk-unit 1302 'roach-warren 1 38.0 36.0)
              (mk-unit 1303 'baneling-nest 1 40.0 36.0)
              (mk-unit 1311 'extractor 1 28.0 26.0 #:assigned 3 #:ideal 3)
              (mk-unit 1312 'extractor 1 36.0 25.0 #:assigned 3 #:ideal 3)
              (mk-unit 1313 'extractor 1 52.0 25.0 #:assigned 3 #:ideal 3))
        (for/list ([i (in-range 70)])
          (mk-unit (+ 1100 i) 'drone 1 (+ 27.0 (* 0.2 (modulo i 10))) (+ 30.0 (* 0.3 (quotient i 10)))
                   #:orders (list (sc2-unit-order AB-GATHER #f 90001 0.0))))
        (for/list ([i (in-range 7)])
          (mk-unit (+ 1250 i) 'queen 1 (+ 34.0 (* i 2.5)) 33.0 #:hp 175.0 #:hp-max 175.0 #:energy 50.0))
        ;; 64 Zerglings (= zergling-standing-cap!) + 5 Roaches + 3 Ravagers, 0 visible enemy combat units (only surviving enemy Hatchery!)
        (for/list ([i (in-range 64)])
          (mk-unit (+ 7100 i) 'zergling 1 (+ 70.0 (* 0.4 (modulo i 16))) (+ 60.0 (* 0.4 (quotient i 16))) #:hp 35.0 #:hp-max 35.0))
        (for/list ([i (in-range 5)])
          (mk-unit (+ 7200 i) 'roach 1 (+ 72.0 (* i 0.8)) 64.0 #:hp 145.0 #:hp-max 145.0))
        (for/list ([i (in-range 3)])
          (mk-unit (+ 7210 i) 'ravager 1 (+ 72.0 (* i 1.0)) 66.0 #:hp 120.0 #:hp-max 120.0))
        (for/list ([i (in-range 15)])
          (mk-unit (+ 7001 i) 'larva 1 (+ 32.0 (* 0.3 (modulo i 5))) (+ 34.5 (* 0.3 (quotient i 5)))))
        ;; 20 active Creep Tumors (Bombshell #2 from #1/#503: uncapped creep spread used to emit 43 cast-spells/step
        ;; overflowing cortex-filter-actions! and evicting 100% of lair/combat orders!)
        (for/list ([i (in-range 20)])
          (mk-unit (+ 1500 i) 'creep-tumor-burrowed 1 (+ 42.0 (* 2.0 (modulo i 10))) (+ 42.0 (* 2.5 (quotient i 10))) #:burrowed? #t))
        ;; Exact #1 Z v titania state: ONLY surviving enemy Zerg structures, 0 visible enemy combat units!
        (list (mk-unit 9951 'hatchery 4 160.0 160.0 #:hp 1500.0 #:hp-max 1500.0)
              (mk-unit 9952 'spawning-pool 4 156.0 156.0 #:hp 1000.0 #:hp-max 1000.0))))
     (define steps
       (for/list ([f (in-list '(16000 16064 16128))])
         (hash 'obs (mk-obs f units
                            #:minerals 15000 #:vespene 1000
                            #:food-used 136 #:food-cap 200 #:food-army 66 #:food-workers 70
                            #:larva-count 15))))
     (define outs
       (run-pipeline-sequence 'Zerg 'Zerg steps
                              #:our-x 32.0 #:our-y 32.0 #:enemy-x 160.0 #:enemy-y 160.0))
     (define all-wcmds (apply append (map step-outcome-wire-cmds outs)))
     (define morphed-lair? (wire-has-ability? all-wcmds hatch-tags AB-MORPH-LAIR))
     (define combat-larvae-trained
       (for/sum ([t (in-list larva-tags)])
         (define abs (wire-abilities-for-tag all-wcmds t))
         (if (or (memv AB-TRAIN-ROACH abs) (memv AB-TRAIN-ZERGLING abs) (memv AB-TRAIN-HYDRALISK abs)) 1 0)))
     (define max-creep-per-step
       (apply max (for/list ([o (in-list outs)])
                    (length (filter (lambda (c)
                                      (and (sc2-raw-unit-command? c)
                                           (memv (sc2-raw-unit-command-ability-id c)
                                                 (list AB-CREEP-TUMOR-TUMOR AB-CREEP-TUMOR-QUEEN))))
                                    (step-outcome-wire-cmds o))))))
     (define total-rej (for/sum ([o (in-list outs)]) (step-outcome-wire-rejects o)))
     (values (last outs)
             (list
              (mk-check "zerg-5-hatcheries-morphs-lair-at-15k-bank" morphed-lair?
                        (format "Hatcheries 1001..1005 emitted MORPH_LAIR (1216)=~a at 15,000M/1,000G despite 20 Creep Tumors" morphed-lair?))
              (mk-check "zerg-spends-idle-larvae-on-combat-despite-lair-bo" (>= combat-larvae-trained 2)
                        (format "Larvae trained into Roach/Ling/Hydra=~a/15 at 15,000M/1,000G (expected >=2)" combat-larvae-trained))
              (mk-check "creep-spread-capped-never-evicts-macro-or-combat" (<= max-creep-per-step 3)
                        (format "Max creep-tumor casts in any single step=~a (expected <=3; pre-W17 spammed 43)" max-creep-per-step))
              (mk-check "zero-wire-rejects" (= total-rej 0)
                        (format "wire_rejects=~a" total-rej)))))))

(define scen-w17-tac-3
  (tactical-scenario
   "w17-tac-3-zerg-0g-gas-freeze-under-hovering-tempests-assigns-gas-drones"
   "wave17-repro" "Zerg" "Protoss" "economy-gas-recovery"
   "Wave-17 P0-3 (#28 Z v Creepy_strategies 10-min 0G freeze across 7 Extractors): At 19G with 0 gas workers and >=2 Tempests hovering near each base, wire gas saturation MUST fall back to safest ready Extractor instead of locking gas to 0G/min"
   (lambda ()
     (define extractor-tags '(1311 1312 1313))
     (define drone-tags (for/list ([i (in-range 32)]) (+ 1100 i)))
     (define units
       (append
        (list (mk-unit 1001 'lair 1 32.0 32.0 #:assigned 16 #:ideal 16)
              (mk-unit 1002 'hatchery 1 52.0 32.0 #:assigned 16 #:ideal 16)
              (mk-unit 1301 'spawning-pool 1 36.0 36.0)
              (mk-unit 1311 'extractor 1 28.0 26.0 #:assigned 0 #:ideal 3)
              (mk-unit 1312 'extractor 1 36.0 26.0 #:assigned 0 #:ideal 3)
              (mk-unit 1313 'extractor 1 52.0 26.0 #:assigned 0 #:ideal 3))
        (for/list ([i (in-range 32)])
          (mk-unit (+ 1100 i) 'drone 1
                   (+ (if (< i 16) 27.0 52.0) (* 0.3 (modulo i 6)))
                   (+ (if (< i 16) 30.0 28.0) (* 0.4 (quotient (modulo i 16) 6)))
                   #:orders (list (sc2-unit-order AB-GATHER #f (if (< i 16) 90001 90011) 0.0))))
        (list (mk-unit 1401 'queen 1 34.0 34.0 #:hp 175.0 #:hp-max 175.0)
              (mk-unit 1402 'queen 1 54.0 34.0 #:hp 175.0 #:hp-max 175.0)
              ;; 2 Tempests within 10.5t of EACH TownHall -> both bases flagged th-combat-unsafe? on pre-W17!
              (mk-unit 9961 'tempest 4 38.0 36.0 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0 #:flying? #t)
              (mk-unit 9962 'tempest 4 39.5 36.0 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0 #:flying? #t)
              (mk-unit 9963 'tempest 4 58.0 36.0 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0 #:flying? #t)
              (mk-unit 9964 'tempest 4 59.5 36.0 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0 #:flying? #t))))
     (define obs-w17-3
       (mk-obs 12000 units
               #:minerals 800 #:vespene 19
               #:food-used 40 #:food-cap 66 #:food-army 4 #:food-workers 32))
     (define out
       (last (run-pipeline-sequence 'Zerg 'Protoss
               (list (hash 'obs obs-w17-3)))))
     ;; Live ladder main invokes `saturate-workers-and-gas-commands` alongside `translate-bot-actions->sc2-raw-commands`!
     (define sat-cmds (saturate-workers-and-gas-commands obs-w17-3))
     (define wcmds (append (step-outcome-wire-cmds out) sat-cmds))
     (define gas-assigned-drones
       (for/sum ([t (in-list drone-tags)])
         (if (ormap (lambda (c)
                      (and (sc2-raw-unit-command? c)
                           (memv (sc2-raw-unit-command-ability-id c) (list AB-GATHER AB-MINERAL-WALK-GATHER))
                           (memv (sc2-raw-unit-command-target-unit-tag c) extractor-tags)))
                    (wire-cmds-for-tag wcmds t))
             1 0)))
     (values out
             (list
              (mk-check "zerg-assigns-gas-drones-despite-hovering-tempests-at-19g" (>= gas-assigned-drones 1)
                        (format "Drones assigned to ready Extractors (1311..1313) at 19G=~a/32 (expected >=1)" gas-assigned-drones))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

(define scen-w17-tac-4
  (tactical-scenario
   "w17-tac-4-early-proxy-marauder-rush-defends-natural-zero-obret"
   "wave17-repro" "Terran" "Terran" "early-rush-defense"
   "Wave-17 P1-1 (#14 T / #15 P v oberon <5:30 proxy 2-Rax TechLab Marauder rush): Early Terran and Protoss natural defenders engage (ATTACK) with 0 backward OBRet while Barracks trains combat units instead of holding for greedy tech"
   (lambda ()
     ;; Part A: Terran #14 at f=5600 (4:10 < 5:30): 4 Marines + 2 Marauders at natural (58,32) vs 5 Marauders + 2 Marines + proxy Rax at (68.5,32)
     (define home-t
       (append (mk-home-base-units 'Terran #:base-x 32.0 #:base-y 32.0 #:with-natural? #t #:nat-x 52.0 #:nat-y 32.0 #:workers 22)
               (list (mk-unit 1301 'barracks 1 38.0 36.0)
                     (mk-unit 1302 'factory 1 38.0 42.0))))
     (define t-def-tags '(7301 7302 7303 7304 7305 7306))
     (define t-defs
       (list (mk-unit 7301 'marine 1 58.0 30.5 #:hp 45.0 #:hp-max 45.0)
             (mk-unit 7302 'marine 1 58.0 31.5 #:hp 45.0 #:hp-max 45.0)
             (mk-unit 7303 'marine 1 58.0 32.5 #:hp 45.0 #:hp-max 45.0)
             (mk-unit 7304 'marine 1 58.0 33.5 #:hp 45.0 #:hp-max 45.0)
             (mk-unit 7305 'marauder 1 58.5 31.5 #:hp 125.0 #:hp-max 125.0)
             (mk-unit 7306 'marauder 1 58.5 32.5 #:hp 125.0 #:hp-max 125.0)))
     (define t-enemies
       (append (for/list ([i (in-range 5)])
                 (mk-unit (+ 9971 i) 'marauder 4 68.5 (+ 30.0 (* i 1.0)) #:hp 125.0 #:hp-max 125.0))
               (list (mk-unit 9978 'marine 4 69.5 31.0 #:hp 45.0 #:hp-max 45.0)
                     (mk-unit 9979 'marine 4 69.5 33.0 #:hp 45.0 #:hp-max 45.0)
                     (mk-unit 9980 'barracks 4 78.0 36.0 #:hp 1000.0 #:hp-max 1000.0))))
     (define out-t
       (last (run-pipeline-sequence 'Terran 'Terran
               (list (hash 'obs (mk-obs 5600 (append home-t t-defs t-enemies)
                                        #:minerals 220 #:vespene 120
                                        #:food-used 30 #:food-cap 46 #:food-army 8 #:food-workers 22))))))
     (define t-wcmds (step-outcome-wire-cmds out-t))
     (define t-atk (wire-count-tags-with-ability t-wcmds t-def-tags AB-ATTACK))
     (define t-trains-bio? (or (wire-has-ability? t-wcmds '(1301) AB-TRAIN-MARINE)
                               (wire-has-ability? t-wcmds '(1301) AB-TRAIN-MARAUDER)))
     ;; Part B: Protoss #15 at f=5800 (4:18 < 5:30): 4 Stalkers + 1 Immortal + 2 Zealots at natural (58,32) vs 6 Marauders + 2 Marines + proxy Rax
     (define home-p
       (append (mk-home-base-units 'Protoss #:base-x 32.0 #:base-y 32.0 #:with-natural? #t #:nat-x 52.0 #:nat-y 32.0 #:workers 22)
               (list (mk-unit 1321 'gateway 1 38.0 36.0)
                     (mk-unit 1322 'gateway 1 38.0 40.0)
                     (mk-unit 1323 'robotics-facility 1 38.0 44.0)
                     (mk-unit 1324 'pylon 1 36.0 38.0))))
     (define p-def-tags '(7311 7312 7313 7314 7315 7316 7317))
     (define p-defs
       (list (mk-unit 7311 'stalker 1 58.0 30.0 #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0)
             (mk-unit 7312 'stalker 1 58.0 31.2 #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0)
             (mk-unit 7313 'stalker 1 58.0 32.8 #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0)
             (mk-unit 7314 'stalker 1 58.0 34.0 #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0)
             (mk-unit 7315 'immortal 1 58.5 32.0 #:hp 200.0 #:hp-max 200.0 #:shield 100.0 #:shield-max 100.0)
             (mk-unit 7316 'zealot 1 59.0 31.0 #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0)
             (mk-unit 7317 'zealot 1 59.0 33.0 #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0)))
     (define p-enemies
       (append (for/list ([i (in-range 6)])
                 (mk-unit (+ 9981 i) 'marauder 4 68.5 (+ 29.5 (* i 1.0)) #:hp 125.0 #:hp-max 125.0))
               (list (mk-unit 9988 'marine 4 69.5 31.0 #:hp 45.0 #:hp-max 45.0)
                     (mk-unit 9989 'marine 4 69.5 33.0 #:hp 45.0 #:hp-max 45.0)
                     (mk-unit 9990 'barracks 4 78.0 36.0 #:hp 1000.0 #:hp-max 1000.0))))
     (define out-p
       (last (run-pipeline-sequence 'Protoss 'Terran
               (list (hash 'obs (mk-obs 5800 (append home-p p-defs p-enemies)
                                        #:minerals 280 #:vespene 140
                                        #:food-used 38 #:food-cap 54 #:food-army 16 #:food-workers 22))))))
     (define p-atk (wire-count-tags-with-ability (step-outcome-wire-cmds out-p) p-def-tags AB-ATTACK))
     (define total-rej (+ (step-outcome-wire-rejects out-t) (step-outcome-wire-rejects out-p)))
     (values out-t
             (list
              (mk-check "terran-early-proxy-marauder-defenders-attack-zero-obret" (>= t-atk 4)
                        (format "Terran <5:30 natural defenders ATTACK=~a/6 vs 5 Marauders+2 Marines (expected >=4)" t-atk))
              (mk-check "terran-early-proxy-marauder-keeps-training-bio" t-trains-bio?
                        (format "Barracks 1301 trained Marine/Marauder under <5:30 proxy Marauder rush=~a" t-trains-bio?))
              (mk-check "protoss-early-proxy-marauder-defenders-attack-zero-obret" (>= p-atk 5)
                        (format "Protoss <5:30 natural defenders ATTACK=~a/7 vs 6 Marauders+2 Marines (expected >=5)" p-atk))
              (mk-check "zero-wire-rejects" (= total-rej 0)
                        (format "wire_rejects=~a" total-rej)))))))

;; -----------------------------------------------------------------------------
;; Tier 3 addition (Wave-18 regression shield): novel-137
;; -----------------------------------------------------------------------------
(define scen-novel-137
  (tactical-scenario
   "novel-137-terran-bio-viking-engages-colossus-stalker-no-0dps-kite"
   "novel" "Terran" "Protoss" "siege-zero-dps"
   "Wave-18 shield (#26 T v Thssprtssbt): Outnumbered Terran Marine+Marauder+Viking squad within 10.5t of enemy Colossi+Stalkers engages (ATTACK) instead of 0-DPS backward kiting"
   (lambda ()
     (define home (mk-home-base-units 'Terran #:base-x 32.0 #:base-y 32.0 #:workers 16))
     (define bio-tags (append (for/list ([i (in-range 8)]) (+ 7351 i))
                              (for/list ([i (in-range 4)]) (+ 7361 i))
                              '(7371 7372)))
     (define allies
       (append home
               (for/list ([i (in-range 8)])
                 (mk-unit (+ 7351 i) 'marine 1 78.5 (+ 77.0 (* i 0.8)) #:hp 45.0 #:hp-max 45.0))
               (for/list ([i (in-range 4)])
                 (mk-unit (+ 7361 i) 'marauder 1 79.0 (+ 78.0 (* i 1.2)) #:hp 125.0 #:hp-max 125.0))
               (list (mk-unit 7371 'viking-fighter 1 78.0 79.0 #:hp 135.0 #:hp-max 135.0 #:flying? #t)
                     (mk-unit 7372 'viking-fighter 1 78.0 81.0 #:hp 135.0 #:hp-max 135.0 #:flying? #t))))
     (define enemies
       (append (for/list ([i (in-range 3)])
                 (mk-unit (+ 9991 i) 'colossus 4 89.0 (+ 78.0 (* i 2.0)) #:hp 200.0 #:hp-max 200.0 #:shield 150.0 #:shield-max 150.0))
               (for/list ([i (in-range 6)])
                 (mk-unit (+ 9995 i) 'stalker 4 88.5 (+ 77.5 (* i 1.0)) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))))
     (define out
       (last (run-pipeline-sequence 'Terran 'Protoss
               (list (hash 'obs (mk-obs 15000 (append allies enemies)
                                        #:food-used 36 #:food-cap 60 #:food-army 20 #:food-workers 16))))))
     (define atk-cnt (wire-count-tags-with-ability (step-outcome-wire-cmds out) bio-tags AB-ATTACK))
     (values out
             (list
              (mk-check "terran-bio-viking-engages-colossus-stalker-at-10.5t" (>= atk-cnt 8)
                        (format "Terran Bio+Vikings ATTACK=~a/14 vs 3 Colossi+6 Stalkers at 10.5t (expected >=8)" atk-cnt))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

;; -----------------------------------------------------------------------------
;; Tier 17: Wave-18 Finale — Gas Resaturation Under P2 Micro, 12-Pool Rush & Reaper/Colossus (3)
;; -----------------------------------------------------------------------------
(define scen-w18-tac-1
  (tactical-scenario
   "w18-tac-1-post-gas-pull-resaturation-under-p2-combat-micro-zero-starve"
   "wave18-repro" "Protoss" "Zerg" "economy-gas-recovery"
   "Wave-18 P0-2 (#514/#009/#003/#028): Under continuous P2 combat micro draining APM tokens, gas resaturation (and carrying-cargo workers) MUST still pass govern-sc2-wire-actions! instead of starving 0/100 for 100-388s"
   (lambda ()
     (define assim-tags '(1311 1312))
     (define probe-tags (for/list ([i (in-range 20)]) (+ 1100 i)))
     ;; Part A: 20 Probes (half carrying minerals buff=271), 2 empty ready Assimilators (assigned=0), gas=16G,
     ;; fed through govern-sc2-wire-actions! alongside 8 P2 combat micro commands EVERY 4f step for 30 steps!
     (define units-a
       (append
        (list (mk-unit 1001 'nexus 1 32.0 32.0 #:assigned 20 #:ideal 16)
              (mk-unit 1311 'assimilator 1 28.0 26.0 #:assigned 0 #:ideal 3)
              (mk-unit 1312 'assimilator 1 36.0 26.0 #:assigned 0 #:ideal 3))
        (for/list ([i (in-range 20)])
          (mk-unit (+ 1100 i) 'probe 1
                   (+ 27.0 (* 0.3 (modulo i 6)))
                   (+ 30.0 (* 0.4 (quotient i 6)))
                   #:buffs (if (< i 10) '(271) '())
                   #:orders (list (sc2-unit-order AB-GATHER #f 90001 0.0))))
        (for/list ([i (in-range 8)])
          (mk-unit (+ 7401 i) 'stalker 1 80.0 (+ 76.0 (* i 0.9)) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))))
     (define gov (make-wire-apm-governor))
     (define steady-state-gas-emits
       (for/sum ([step-i (in-range 30)])
         (define f (+ 5120 (* step-i 4)))
         (define obs-s (mk-obs f units-a #:minerals 240 #:vespene 16 #:food-used 36 #:food-cap 54 #:food-army 16 #:food-workers 20))
         (define p2-cmds
           (for/list ([i (in-range 8)])
             (sc2-raw-unit-command AB-ATTACK (sc2-point2d (+ 90.0 (* i 0.5)) 80.0) 0 (list (+ 7401 i)) #f)))
         (define sat-cmds (saturate-workers-and-gas-commands obs-s))
         (define gov-cmds (govern-sc2-wire-actions! gov (append p2-cmds sat-cmds) f obs-s))
         (if (and (>= step-i 10)
                  (ormap (lambda (c)
                           (and (sc2-raw-unit-command? c)
                                (memv (sc2-raw-unit-command-ability-id c) (list AB-GATHER AB-MINERAL-WALK-GATHER))
                                (memv (sc2-raw-unit-command-target-unit-tag c) assim-tags)))
                         gov-cmds))
             1 0)))
     ;; Part B: All 16 Probes carrying minerals (buff=271) at 16G with 2 empty Assimilators -> STILL assigns gas worker!
     (define units-b
       (append
        (list (mk-unit 1001 'nexus 1 32.0 32.0 #:assigned 16 #:ideal 16)
              (mk-unit 1311 'assimilator 1 28.0 26.0 #:assigned 0 #:ideal 3)
              (mk-unit 1312 'assimilator 1 36.0 26.0 #:assigned 0 #:ideal 3))
        (for/list ([i (in-range 16)])
          (mk-unit (+ 1100 i) 'probe 1
                   (+ 27.0 (* 0.3 (modulo i 6)))
                   (+ 30.0 (* 0.4 (quotient i 6)))
                   #:buffs '(271)
                   #:orders (list (sc2-unit-order AB-GATHER #f 90001 0.0))))))
     (define obs-b (mk-obs 5240 units-b #:minerals 240 #:vespene 16 #:food-used 16 #:food-cap 30 #:food-army 0 #:food-workers 16))
     (define sat-b (saturate-workers-and-gas-commands obs-b))
     (define carry-gas-assigned
       (for/sum ([t (in-list (take probe-tags 16))])
         (if (ormap (lambda (c)
                      (and (sc2-raw-unit-command? c)
                           (memv (sc2-raw-unit-command-ability-id c) (list AB-GATHER AB-MINERAL-WALK-GATHER))
                           (memv (sc2-raw-unit-command-target-unit-tag c) assim-tags)))
                    (wire-cmds-for-tag sat-b t))
             1 0)))
     (define out
       (last (run-pipeline-sequence 'Protoss 'Zerg
               (list (hash 'obs (mk-obs 5240 units-a #:minerals 240 #:vespene 16 #:food-used 36 #:food-cap 54 #:food-army 16 #:food-workers 20))))))
     (values out
             (list
              (mk-check "gas-resaturation-passes-apm-governor-under-steady-p2-micro" (>= steady-state-gas-emits 3)
                        (format "Governed gas-assign steps during steady-state P2 micro (steps 10..29)=~a/20 (expected >=3; pre-W18 was 0/20)" steady-state-gas-emits))
              (mk-check "carrying-mineral-workers-still-resaturate-empty-gas-at-16g" (>= carry-gas-assigned 1)
                        (format "Carrying-mineral Probes (buff 271) assigned to empty Assimilators=~a/16 (expected >=1)" carry-gas-assigned))
              (mk-check "zero-wire-rejects" (= (step-outcome-wire-rejects out) 0)
                        (format "wire_rejects=~a" (step-outcome-wire-rejects out))))))))

(define scen-w18-tac-2
  (tactical-scenario
   "w18-tac-2-early-12pool-zergling-rush-fights-at-home-and-adds-2nd-prod"
   "wave18-repro" "Protoss" "Zerg" "early-rush-defense"
   "Wave-18 P0-1 (#36 P / #35 T / #8 T v <3:30 12-Pool Zergling rush): Combat units + workers STAND AND FIGHT inside main (0% OBRet) and spend >=300M on 2nd Gateway/Barracks or static defense + continuous Zealot/Marine"
   (lambda ()
     ;; Part A: Protoss #36 at f=2600 (1:56 < 3:30), 340M, 1 Gateway, 2 Zealots + 16 Probes vs 12 Zerglings inside main!
     (define home-p
       (append (mk-home-base-units 'Protoss #:base-x 32.0 #:base-y 32.0 #:workers 16)
               (list (mk-unit 1301 'pylon 1 36.0 36.0)
                     (mk-unit 1302 'gateway 1 38.0 36.0))))
     (define p-zeal-tags '(7451 7452))
     (define p-probe-tags (for/list ([i (in-range 16)]) (+ 1100 i)))
     (define p-zeals
       (list (mk-unit 7451 'zealot 1 36.0 31.5 #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0)
             (mk-unit 7452 'zealot 1 36.0 32.5 #:hp 100.0 #:hp-max 100.0 #:shield 50.0 #:shield-max 50.0)))
     (define p-lings
       (for/list ([i (in-range 12)])
         (mk-unit (+ 9910 i) 'zergling 4 41.0 (+ 29.5 (* i 0.5)) #:hp 35.0 #:hp-max 35.0)))
     (define out-p
       (last (run-pipeline-sequence 'Protoss 'Zerg
               (list (hash 'obs (mk-obs 2600 (append home-p p-zeals p-lings)
                                        #:minerals 340 #:vespene 0
                                        #:food-used 20 #:food-cap 31 #:food-army 4 #:food-workers 16))))))
     (define pw (step-outcome-wire-cmds out-p))
     (define p-zeal-atk (wire-count-tags-with-ability pw p-zeal-tags AB-ATTACK))
     (define p-probe-atk (wire-count-tags-with-ability pw p-probe-tags AB-ATTACK))
     (define p-trains-zeal? (wire-has-ability? pw '(1302) AB-TRAIN-ZEALOT))
     (define p-adds-def-or-gate?
       (or (wire-has-ability? pw p-probe-tags AB-BUILD-GATEWAY)
           (wire-has-ability? pw p-probe-tags AB-BUILD-SHIELD-BATTERY)))
     ;; Part B: Terran #35/#8 at f=2700 (2:00 < 3:30), 320M, 1 Barracks, 3 Marines + 16 SCVs vs 12 Zerglings inside main!
     (define home-t
       (append (mk-home-base-units 'Terran #:base-x 32.0 #:base-y 32.0 #:workers 16)
               (list (mk-unit 1311 'supply-depot 1 35.0 28.0)
                     (mk-unit 1312 'supply-depot 1 37.5 28.0)
                     (mk-unit 1313 'barracks 1 38.0 36.0))))
     (define t-mar-tags '(7461 7462 7463))
     (define t-scv-tags (for/list ([i (in-range 16)]) (+ 1100 i)))
     (define t-mars
       (list (mk-unit 7461 'marine 1 36.0 31.0 #:hp 45.0 #:hp-max 45.0)
             (mk-unit 7462 'marine 1 36.0 32.0 #:hp 45.0 #:hp-max 45.0)
             (mk-unit 7463 'marine 1 36.0 33.0 #:hp 45.0 #:hp-max 45.0)))
     (define t-lings
       (for/list ([i (in-range 12)])
         (mk-unit (+ 9930 i) 'zergling 4 41.5 (+ 29.5 (* i 0.5)) #:hp 35.0 #:hp-max 35.0)))
     (define out-t
       (last (run-pipeline-sequence 'Terran 'Zerg
               (list (hash 'obs (mk-obs 2700 (append home-t t-mars t-lings)
                                        #:minerals 320 #:vespene 0
                                        #:food-used 19 #:food-cap 31 #:food-army 3 #:food-workers 16))))))
     (define tw (step-outcome-wire-cmds out-t))
     (define t-mar-atk (wire-count-tags-with-ability tw t-mar-tags AB-ATTACK))
     (define t-trains-mar? (wire-has-ability? tw '(1313) AB-TRAIN-MARINE))
     (define t-adds-rax-or-bunker?
       (or (wire-has-ability? tw t-scv-tags AB-BUILD-BARRACKS)
           (wire-has-ability? tw t-scv-tags AB-BUILD-BUNKER)))
     (define total-rej (+ (step-outcome-wire-rejects out-p) (step-outcome-wire-rejects out-t)))
     (values out-p
             (list
              (mk-check "protoss-12pool-zealots-and-probes-stand-and-fight" (and (>= p-zeal-atk 2) (>= p-probe-atk 2))
                        (format "Protoss vs 12 Lings in main: Zealots ATTACK=~a/2, Probes ATTACK=~a/16 (expected >=2 & >=2)" p-zeal-atk p-probe-atk))
              (mk-check "protoss-12pool-spends-340m-on-zealot-and-2nd-gate-or-battery" (and p-trains-zeal? p-adds-def-or-gate?)
                        (format "Protoss at 340M vs 12 Lings: train_zealot=~a, build_gate/battery=~a" p-trains-zeal? p-adds-def-or-gate?))
              (mk-check "terran-12pool-marines-fight-zero-obret" (>= t-mar-atk 2)
                        (format "Terran Marines ATTACK=~a/3 vs 12 Lings in main (expected >=2)" t-mar-atk))
              (mk-check "terran-12pool-spends-320m-on-marine-and-2nd-rax-or-bunker" (and t-trains-mar? t-adds-rax-or-bunker?)
                        (format "Terran at 320M vs 12 Lings: train_marine=~a, build_rax/bunker=~a" t-trains-mar? t-adds-rax-or-bunker?))
              (mk-check "zero-wire-rejects" (= total-rej 0)
                        (format "wire_rejects=~a" total-rej)))))))

(define scen-w18-tac-3
  (tactical-scenario
   "w18-tac-3-no-late-reaper-escrow-under-pressure-and-anti-tank-colossus-engage"
   "wave18-repro" "Terran" "Protoss" "siege-zero-dps"
   "Wave-18 P0-3 (#29 T v Creepy f=4368 reaper@1269 escrow + #26/#32 Tank/Colossus Siege0DPS): Terran past 2:30 under Stalker pressure trains Marine (0 Reaper escrow!) and Terran Bio trapped at 11t vs Tanks+Colossi attacks instead of 0-DPS retreat"
   (lambda ()
     ;; Part A: #29 T v Creepy at f=4368 (3:15 > 2:30), 140M/45G (<50G!), Barracks+Factory, 6 enemy Stalkers approaching natural
     (define home-a
       (append (mk-home-base-units 'Terran #:base-x 32.0 #:base-y 32.0 #:with-natural? #t #:nat-x 52.0 #:nat-y 32.0 #:workers 22)
               (list (mk-unit 1301 'barracks 1 38.0 36.0)
                     (mk-unit 1302 'factory 1 38.0 42.0)
                     (mk-unit 1303 'supply-depot 1 35.0 28.0)
                     (mk-unit 1304 'supply-depot 1 37.5 28.0)
                     (mk-unit 1305 'refinery 1 28.0 26.0 #:assigned 3 #:ideal 3))))
     (define defs-a
       (for/list ([i (in-range 3)])
         (mk-unit (+ 7471 i) 'marine 1 56.0 (+ 31.0 (* i 1.0)) #:hp 45.0 #:hp-max 45.0)))
     (define enemies-a
       (for/list ([i (in-range 6)])
         (mk-unit (+ 9950 i) 'stalker 4 66.0 (+ 29.5 (* i 1.0)) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0)))
     (define out-a
       (last (run-pipeline-sequence 'Terran 'Protoss
               (list (hash 'obs (mk-obs 4368 (append home-a defs-a enemies-a)
                                        #:minerals 140 #:vespene 45
                                        #:food-used 25 #:food-cap 46 #:food-army 3 #:food-workers 22))))))
     (define wa (step-outcome-wire-cmds out-a))
     (define trained-mar-a? (wire-has-ability? wa '(1301) AB-TRAIN-MARINE))
     (define trained-reaper-a? (wire-has-ability? wa '(1301) AB-TRAIN-REAPER))
     ;; Part B: #26/#32 outnumbered 6 Marines + 3 Marauders at 11.0t vs 2 Colossi + 2 Sieged Tanks + 4 Stalkers (away from home)
     (define home-b (mk-home-base-units 'Terran #:base-x 32.0 #:base-y 32.0 #:workers 16))
     (define b-tags (append (for/list ([i (in-range 6)]) (+ 7481 i)) '(7491 7492 7493)))
     (define allies-b
       (append home-b
               (for/list ([i (in-range 6)])
                 (mk-unit (+ 7481 i) 'marine 1 79.0 (+ 77.5 (* i 0.9)) #:hp 45.0 #:hp-max 45.0))
               (list (mk-unit 7491 'marauder 1 79.0 78.5 #:hp 125.0 #:hp-max 125.0)
                     (mk-unit 7492 'marauder 1 79.0 80.0 #:hp 125.0 #:hp-max 125.0)
                     (mk-unit 7493 'marauder 1 79.0 81.5 #:hp 125.0 #:hp-max 125.0))))
     (define enemies-b
       (append (list (mk-unit 9961 'colossus 4 90.0 78.5 #:hp 200.0 #:hp-max 200.0 #:shield 150.0 #:shield-max 150.0)
                     (mk-unit 9962 'colossus 4 90.0 81.5 #:hp 200.0 #:hp-max 200.0 #:shield 150.0 #:shield-max 150.0)
                     (mk-unit 9963 'siege-tank-sieged 4 90.0 76.5 #:hp 175.0 #:hp-max 175.0)
                     (mk-unit 9964 'siege-tank-sieged 4 90.0 83.5 #:hp 175.0 #:hp-max 175.0))
               (for/list ([i (in-range 4)])
                 (mk-unit (+ 9970 i) 'stalker 4 91.0 (+ 78.0 (* i 1.2)) #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))))
     (define out-b
       (last (run-pipeline-sequence 'Terran 'Protoss
               (list (hash 'obs (mk-obs 15000 (append allies-b enemies-b)
                                        #:food-used 28 #:food-cap 54 #:food-army 12 #:food-workers 16))))))
     (define b-atk (wire-count-tags-with-ability (step-outcome-wire-cmds out-b) b-tags AB-ATTACK))
     (define total-rej (+ (step-outcome-wire-rejects out-a) (step-outcome-wire-rejects out-b)))
     (values out-a
             (list
              (mk-check "no-reaper-escrow-past-230-under-stalker-pressure" (and trained-mar-a? (not trained-reaper-a?))
                        (format "At f=4368 (3:15, 140M/45G) vs 6 Stalkers: train_marine=~a, train_reaper=~a (expected #t/#f)" trained-mar-a? trained-reaper-a?))
              (mk-check "bio-trapped-at-11t-vs-colossi-and-tanks-attacks-no-0dps-retreat" (>= b-atk 6)
                        (format "Terran 6M+3MR at 11.0t vs 2 Colossi+2 Sieged Tanks ATTACK=~a/9 (expected >=6)" b-atk))
              (mk-check "zero-wire-rejects" (= total-rej 0)
                        (format "wire_rejects=~a" total-rej)))))))

(define scen-novel-138
  (tactical-scenario
   "novel-138-protoss-double-forge-skytoss-endgame-zero-crash"
   "novel" "Protoss" "Terran" "runtime-safety"
   "Wave-18 P0 crash shield (#24 Mothman-P v onlyfans f=20678): Late-game Protoss with >=2 ready Forges, CyberCore, Stargate, FleetBeacon, and sky-toss army (sup=143/165) must execute l2-phase8-macro-escrow! / generate-race-priority-candidates with zero unbound/uninitialized identifier exceptions and zero wire rejects"
   (lambda ()
     (define units
       (append
        (list (mk-unit 1001 'nexus 1 32.0 32.0 #:assigned 16 #:ideal 16)
              (mk-unit 1002 'nexus 1 52.0 32.0 #:assigned 16 #:ideal 16)
              (mk-unit 1003 'nexus 1 72.0 32.0 #:assigned 16 #:ideal 16)
              (mk-unit 1301 'pylon 1 36.0 36.0)
              (mk-unit 1302 'pylon 1 42.0 36.0)
              (mk-unit 1303 'gateway 1 38.0 36.0)
              (mk-unit 1304 'warp-gate 1 40.0 36.0)
              (mk-unit 1305 'cybernetics-core 1 36.0 40.0)
              (mk-unit 1306 'twilight-council 1 38.0 40.0)
              (mk-unit 1307 'templar-archive 1 40.0 40.0)
              (mk-unit 1308 'robotics-facility 1 42.0 40.0)
              (mk-unit 1309 'stargate 1 44.0 36.0)
              (mk-unit 1310 'stargate 1 46.0 36.0)
              (mk-unit 1311 'fleet-beacon 1 44.0 40.0)
              ;; >= 2 ready Forges triggers protoss-second-upg-sym -> protoss-upg-prereq-ok? -> has-core?!
              (mk-unit 1321 'forge 1 34.0 38.0)
              (mk-unit 1322 'forge 1 34.0 42.0)
              (mk-unit 1331 'assimilator 1 28.0 26.0 #:assigned 3 #:ideal 3)
              (mk-unit 1332 'assimilator 1 36.0 25.0 #:assigned 3 #:ideal 3))
        (for/list ([i (in-range 50)])
          (mk-unit (+ 1100 i) 'probe 1 (+ 27.0 (* 0.25 (modulo i 10))) (+ 30.0 (* 0.35 (quotient i 10)))
                   #:orders (list (sc2-unit-order AB-GATHER #f 90001 0.0))))
        (for/list ([i (in-range 6)])
          (mk-unit (+ 7501 i) 'carrier 1 (+ 90.0 (* i 1.5)) 90.0 #:hp 300.0 #:hp-max 300.0 #:shield 150.0 #:shield-max 150.0 #:flying? #t))
        (for/list ([i (in-range 6)])
          (mk-unit (+ 7511 i) 'void-ray 1 (+ 90.0 (* i 1.2)) 93.0 #:hp 150.0 #:hp-max 150.0 #:shield 100.0 #:shield-max 100.0 #:flying? #t))
        (for/list ([i (in-range 10)])
          (mk-unit (+ 7521 i) 'stalker 1 (+ 88.0 (* i 0.9)) 86.0 #:hp 80.0 #:hp-max 80.0 #:shield 80.0 #:shield-max 80.0))
        (list (mk-unit 9981 'command-center 4 160.0 160.0 #:hp 1500.0 #:hp-max 1500.0)
              (mk-unit 9982 'viking-fighter 4 152.0 152.0 #:hp 135.0 #:hp-max 135.0 #:flying? #t)
              (mk-unit 9983 'battlecruiser 4 154.0 154.0 #:hp 550.0 #:hp-max 550.0 #:flying? #t))))
     ;; Run across 3 upgrade states (including #24's exact 0M/372G bank + >=2 Forges + FleetBeacon + CyberCore)
     ;; so ALL has-core? branches in protoss-upg-prereq-ok? (warp-gate, air-weapons-1/2, air-armor-1/2) evaluate cleanly!
     (define outs
       (run-pipeline-sequence 'Protoss 'Terran
         (list (hash 'obs (mk-obs 20608 units
                                  #:minerals 50 #:vespene 372
                                  #:food-used 143 #:food-cap 165 #:food-army 94 #:food-workers 50
                                  #:upgrades '(protoss-ground-weapons-1)))
               (hash 'obs (mk-obs 20636 units
                                  #:minerals 450 #:vespene 370
                                  #:food-used 143 #:food-cap 165 #:food-army 94 #:food-workers 50
                                  #:upgrades '(warp-gate-research protoss-ground-weapons-1 protoss-ground-armor-1 blink charge psi-storm)))
               (hash 'obs (mk-obs 20678 units
                                  #:minerals 600 #:vespene 420
                                  #:food-used 143 #:food-cap 165 #:food-army 94 #:food-workers 50
                                  #:upgrades '(warp-gate-research protoss-ground-weapons-1 protoss-ground-armor-1 protoss-air-weapons-1))))))
     (define total-rej (for/sum ([o (in-list outs)]) (step-outcome-wire-rejects o)))
     (values (last outs)
             (list
              (mk-check "double-forge-skytoss-endgame-steps-without-exception" (= (length outs) 3)
                        (format "Completed ~a/3 Protoss double-forge sky-toss endgame steps cleanly (posture=~a)"
                                (length outs) (step-outcome-posture (last outs))))
              (mk-check "zero-wire-rejects" (= total-rej 0)
                        (format "wire_rejects=~a" total-rej)))))))

;; -----------------------------------------------------------------------------
;; Full Scenario Catalog (231 Scenarios)
;; -----------------------------------------------------------------------------
(define ALL-TACTICAL-SCENARIOS
  (list
   ;; Tier 1: Wave-2 / #77 & #87 failure reproductions (11)
   scen-w2-p0-0
   scen-w2-p0-1a
   scen-w2-p0-1b
   scen-w2-p0-1c
   scen-w2-p0-1d
   scen-w2-p0-2a
   scen-w2-p0-2b
   scen-w2-p0-2c
   scen-w2-p0-3
   scen-w2-p1-2
   scen-w2-p1-1b
   ;; Tier 2: Core P/T/Z tactics coverage (13)
   scen-core-stutter
   scen-core-melee
   scen-core-siege-tank
   scen-core-focus-fire
   scen-core-ravager-bile
   scen-core-ht-storm
   scen-core-ghost-emp
   scen-core-raven
   scen-core-support-preservation
   scen-core-choke-defense
   scen-core-worker-pull
   scen-core-splash-evasion
   scen-core-rally-stream
   ;; Tier 3: Pro-inspired stress & regression-shield scenarios (29)
   scen-novel-01
   scen-novel-02
   scen-novel-03
   scen-novel-04
   scen-novel-05
   scen-novel-06
   scen-novel-07
   scen-novel-08
   scen-novel-09
   scen-novel-10
   scen-novel-11
   scen-novel-12
   scen-novel-13
   scen-novel-14
   scen-novel-15
   scen-novel-16
   scen-novel-17
   scen-novel-18
   scen-novel-19
   scen-novel-20
   scen-novel-22
   scen-novel-24
   scen-novel-25
   scen-novel-26
   scen-novel-27
   scen-novel-29
   scen-novel-30
   scen-novel-31
   scen-novel-32
   scen-novel-37
   scen-novel-38
   scen-novel-39
   scen-novel-40
   scen-novel-41
   scen-novel-42
   scen-novel-43
   scen-novel-44
   scen-novel-45
   scen-novel-46
   scen-novel-47
   scen-novel-48
   scen-novel-49
   scen-novel-50
   scen-novel-51
   scen-novel-52
   scen-novel-53
   scen-novel-54
   scen-novel-55
   scen-novel-56
   scen-novel-57
   scen-novel-58
   scen-novel-59
   scen-novel-60
   scen-novel-61
   scen-novel-62
   scen-novel-63
   scen-novel-64
   scen-novel-65
   scen-novel-66
   scen-novel-67
   scen-novel-68
   scen-novel-69
   scen-novel-70
   scen-novel-71
   scen-novel-72
   scen-novel-73
   scen-novel-74
   scen-novel-75
   scen-novel-76
   scen-novel-77
   scen-novel-78
   scen-novel-79
   scen-novel-80
   scen-novel-81
   scen-novel-82
   scen-novel-83
   scen-novel-84
   scen-novel-85
   scen-novel-86
   scen-novel-87
   scen-novel-88
   scen-novel-89
   scen-novel-90
   scen-novel-91
   scen-novel-92
   scen-novel-93
   scen-novel-94
   scen-novel-95
   scen-novel-96
   scen-novel-97
   scen-novel-98
   scen-novel-99
   scen-novel-100
   scen-novel-101
   scen-novel-102
   scen-novel-103
   scen-novel-104
   scen-novel-105
   scen-novel-106
   scen-novel-107
   scen-novel-108
   scen-novel-109
   scen-novel-110
   scen-novel-111
   scen-novel-112
   scen-novel-113
   scen-novel-114
   scen-novel-115
   scen-novel-116
   scen-novel-117
   scen-novel-118
   scen-novel-119
   scen-novel-120
   scen-novel-121
   scen-novel-122
   scen-novel-123
   scen-novel-124
   scen-novel-125
   scen-novel-126
   scen-novel-127
   scen-novel-128
   scen-novel-129
   scen-novel-130
   scen-novel-131
   scen-novel-132
   scen-novel-133
   scen-novel-134
   scen-novel-135
   scen-novel-136
   scen-novel-137
   scen-novel-138
   ;; Tier 4: Wave-3 verified live-pipeline bug reproductions (8)
   scen-w3-p0-1
   scen-novel-21
   scen-novel-23
   scen-novel-28
   scen-novel-33
   scen-novel-34
   scen-novel-35
   scen-novel-36
   ;; Tier 5: Wave-4 real-SC2 physics & live-pipeline bug reproductions (6)
   scen-w4-p0-2
   scen-w4-tac-1
   scen-w4-tac-2
   scen-w4-tac-3
   scen-w4-tac-4
   scen-w4-tac-5
   ;; Tier 6: Wave-5 real-SC2 physics & live-pipeline bug reproductions (5)
   scen-w5-tac-1
   scen-w5-tac-2
   scen-w5-tac-3
   scen-w5-tac-4
   scen-w5-tac-5
   ;; Tier 7: Wave-6 real-SC2 physics & live-pipeline bug reproductions (4)
   scen-w6-tac-1
   scen-w6-tac-2
   scen-w6-tac-3
   scen-w6-tac-4
   ;; Tier 8: Wave-7 real-SC2 physics & live-pipeline bug reproductions (5)
   scen-w7-tac-1
   scen-w7-tac-2
   scen-w7-tac-3
   scen-w7-tac-4
   scen-w7-tac-5
   ;; Tier 9: Wave-8 real-SC2 physics & live-pipeline bug reproductions (5)
   scen-w8-tac-1
   scen-w8-tac-2
   scen-w8-tac-3
   scen-w8-tac-4
   scen-w8-tac-5
   ;; Tier 10: Wave-9 real-SC2 physics & live-pipeline bug reproductions (6)
   scen-w9-tac-1
   scen-w9-tac-2
   scen-w9-tac-3
   scen-w9-tac-4
   scen-w9-tac-5
   scen-w9-tac-6
   ;; Tier 11: Wave-10 real-SC2 physics & live-pipeline bug reproductions (7)
   scen-w10-tac-1
   scen-w10-tac-2
   scen-w10-tac-3
   scen-w10-tac-4
   scen-w10-tac-5
   scen-w10-tac-6
   scen-w10-tac-7
   ;; Tier 12: Wave-11 real-SC2 physics & live-pipeline bug reproductions (6)
   scen-w11-tac-1
   scen-w11-tac-2
   scen-w11-tac-3
   scen-w11-tac-4
   scen-w11-tac-5
   scen-w11-tac-6
   ;; Tier 13: Wave-12 verified live-pipeline bug reproductions (5)
   scen-w12-tac-1
   scen-w12-tac-2
   scen-w12-tac-3
   scen-w12-tac-4
   scen-w12-tac-5
   ;; Tier 14: Wave-15 / W15b / W15c symmetry-agnostic ground-BFS Voronoi & dynamic fog-risk (8)
   scen-w15-tac-1
   scen-w15-tac-2
   scen-w15-tac-3
   scen-w15-tac-4
   scen-w15-tac-5
   scen-w15-tac-6
   scen-w15-tac-7
   scen-w15-tac-8
   ;; Tier 15: Wave-16 Siege0 3-Bug Chain, Terran Phantom Deduction & Corner Sweep (4)
   scen-w16-tac-1
   scen-w16-tac-2
   scen-w16-tac-3
   scen-w16-tac-4
   ;; Tier 16: Wave-17 Peaceful Terran Freeze, Zerg Lair/Larva Freeze, 0G Gas & Proxy Marauder (4)
   scen-w17-tac-1
   scen-w17-tac-2
   scen-w17-tac-3
   scen-w17-tac-4
   ;; Tier 17: Wave-18 Finale — Gas Resaturation Under P2 Micro, 12-Pool Rush & Reaper/Colossus (3)
   scen-w18-tac-1
   scen-w18-tac-2
   scen-w18-tac-3))

;; -----------------------------------------------------------------------------
;; Runner & Aggregator
;; -----------------------------------------------------------------------------
(define (execute-scenario scen)
  (define t0 (current-inexact-monotonic-milliseconds))
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (define dt (- (current-inexact-monotonic-milliseconds) t0))
                     (hasheq 'id (tactical-scenario-id scen)
                             'tier (tactical-scenario-tier scen)
                             'race (tactical-scenario-race scen)
                             'enemy_race (tactical-scenario-enemy-race scen)
                             'category (tactical-scenario-category scen)
                             'description (tactical-scenario-description scen)
                             'passed #f
                             'elapsed_ms (inexact->exact (round dt))
                             'wire_rejects 0
                             'checks (list (mk-check "no-runtime-exception" #f (exn-message e)))
                             'observed (hasheq 'error (exn-message e))))])
    (define-values (out checks) ((tactical-scenario-run-fn scen)))
    (define dt (- (current-inexact-monotonic-milliseconds) t0))
    (define all-ok? (and (pair? checks) (andmap (lambda (c) (hash-ref c 'passed #f)) checks)))
    (define wcmds (step-outcome-wire-cmds out))
    (define ucmds (filter sc2-raw-unit-command? wcmds))
    (hasheq 'id (tactical-scenario-id scen)
            'tier (tactical-scenario-tier scen)
            'race (tactical-scenario-race scen)
            'enemy_race (tactical-scenario-enemy-race scen)
            'category (tactical-scenario-category scen)
            'description (tactical-scenario-description scen)
            'passed all-ok?
            'elapsed_ms (inexact->exact (round dt))
            'wire_rejects (step-outcome-wire-rejects out)
            'checks checks
            'observed (hasheq 'posture (symbol->string (step-outcome-posture out))
                              'bot_action_count (length (step-outcome-bot-actions out))
                              'wire_cmd_count (length ucmds)
                              'sample_wire_cmds (map wire-cmd->summary (take ucmds (min 8 (length ucmds))))))))

(define (group-counts results key-sym)
  (define buckets (make-hash))
  (for ([r (in-list results)])
    (define k (hash-ref r key-sym "unknown"))
    (define cur (hash-ref buckets k (list 0 0 0)))
    (define p? (hash-ref r 'passed #f))
    (hash-set! buckets k
               (list (add1 (first cur))
                     (+ (second cur) (if p? 1 0))
                     (+ (third cur) (if p? 0 1)))))
  (for/hasheq ([(k triple) (in-hash buckets)])
    (values (string->symbol k)
            (hasheq 'total (first triple)
                    'passed (second triple)
                    'failed (third triple)))))

(define (run-suite scenarios #:rev [rev-override #f])
  (define t0 (current-inexact-monotonic-milliseconds))
  (define results (map execute-scenario scenarios))
  (define dt (- (current-inexact-monotonic-milliseconds) t0))
  (define total (length results))
  (define passed (for/sum ([r (in-list results)]) (if (hash-ref r 'passed #f) 1 0)))
  (define failed (- total passed))
  (define total-rejects (for/sum ([r (in-list results)]) (hash-ref r 'wire_rejects 0)))
  (hasheq 'suite "mothman-tactics-unit-tester"
          'version "1.0"
          'timestamp_utc (utc-timestamp-iso)
          'rev (or rev-override (detect-vcs-rev))
          'elapsed_ms (inexact->exact (round dt))
          'summary (hasheq 'total total
                           'passed passed
                           'failed failed
                           'pass_rate (if (> total 0) (/ (exact->inexact passed) total) 0.0)
                           'by_tier (group-counts results 'tier)
                           'by_race (group-counts results 'race)
                           'by_category (group-counts results 'category)
                           'total_wire_rejects total-rejects)
          'scenarios results))

(define (print-report report)
  (define sum (hash-ref report 'summary))
  (printf "==========================================================================================================\n")
  (printf "MOTHMAN TACTICAL UNIT-TESTER SUITE (rev=~a, elapsed=~ams)\n"
          (hash-ref report 'rev) (hash-ref report 'elapsed_ms))
  (printf "==========================================================================================================\n")
  (printf "~a ~a ~a ~a ~a\n"
          (~a "SCENARIO" #:min-width 56)
          (~a "TIER" #:min-width 12)
          (~a "RACE" #:min-width 8)
          (~a "MS" #:min-width 6)
          "STATUS")
  (printf "----------------------------------------------------------------------------------------------------------\n")
  (for ([r (in-list (hash-ref report 'scenarios))])
    (define st (if (hash-ref r 'passed #f) "PASS" "FAIL"))
    (printf "~a ~a ~a ~a ~a\n"
            (~a (hash-ref r 'id) #:min-width 56)
            (~a (hash-ref r 'tier) #:min-width 12)
            (~a (hash-ref r 'race) #:min-width 8)
            (~a (hash-ref r 'elapsed_ms) #:min-width 6)
            st)
    (unless (hash-ref r 'passed #f)
      (for ([c (in-list (hash-ref r 'checks))]
            #:unless (hash-ref c 'passed #f))
        (printf "    [FAIL] ~a: ~a\n" (hash-ref c 'name) (hash-ref c 'detail)))))
  (printf "----------------------------------------------------------------------------------------------------------\n")
  (printf "TOTAL: ~a/~a PASSED (~a FAILED, ~a% pass rate, wire_rejects=~a)\n"
          (hash-ref sum 'passed)
          (hash-ref sum 'total)
          (hash-ref sum 'failed)
          (~r (* 100.0 (hash-ref sum 'pass_rate)) #:precision '(= 1))
          (hash-ref sum 'total_wire_rejects))
  (for ([(tier-k counts) (in-hash (hash-ref sum 'by_tier))])
    (printf "  tier ~a: ~a/~a passed (~a failed)\n"
            (~a tier-k #:min-width 12)
            (hash-ref counts 'passed)
            (hash-ref counts 'total)
            (hash-ref counts 'failed)))
  (printf "==========================================================================================================\n"))

;; -----------------------------------------------------------------------------
;; CLI Entry Point
;; -----------------------------------------------------------------------------
(module+ main
  (define tier-filter #f)
  (define exclude-tier #f)
  (define race-filter #f)
  (define scenario-filter #f)
  (define list-only? #f)
  (define emit-json? #f)
  (define out-path #f)
  (define rev-override #f)
  (define strict? #f)

  (command-line
   #:program "tactics-unit-tester.rkt"
   #:once-each
   [("--all") "Run all tactical scenarios (default)" (void)]
   [("--tier") t "Filter by tier: wave2-repro | core | novel | wave3-repro | wave4-repro | wave5-repro | wave6-repro | wave7-repro | wave8-repro | wave9-repro | wave10-repro" (set! tier-filter t)]
   [("--exclude-tier") t "Exclude a tier (e.g. wave10-repro)" (set! exclude-tier t)]
   [("--race") r "Filter by race: Protoss | Terran | Zerg" (set! race-filter r)]
   [("--scenario") id "Run one scenario by exact ID" (set! scenario-filter id)]
   [("--list") "List all scenarios" (set! list-only? #t)]
   [("--json") "Print JSON report to stdout" (set! emit-json? #t)]
   [("--out") path "Write JSON report to file path" (set! out-path path)]
   [("--rev") rev "Override revision label in report" (set! rev-override rev)]
   [("--strict") "Exit non-zero if any scenario fails" (set! strict? #t)])

  (define selected
    (filter
     (lambda (s)
       (and (or (not tier-filter) (string=? (tactical-scenario-tier s) tier-filter))
            (or (not exclude-tier) (not (string=? (tactical-scenario-tier s) exclude-tier)))
            (or (not race-filter) (string-ci=? (tactical-scenario-race s) race-filter))
            (or (not scenario-filter) (string=? (tactical-scenario-id s) scenario-filter))))
     ALL-TACTICAL-SCENARIOS))

  (cond
    [list-only?
     (for ([s (in-list selected)])
       (printf "~a\t~a\t~a\t~a\t~a\n"
               (tactical-scenario-id s)
               (tactical-scenario-tier s)
               (tactical-scenario-race s)
               (tactical-scenario-category s)
               (tactical-scenario-description s)))]
    [else
     (when (null? selected)
       (eprintf "No scenarios matched filters (tier=~a race=~a scenario=~a)\n"
                tier-filter race-filter scenario-filter)
       (exit 2))
     (define report (run-suite selected #:rev rev-override))
     (define clean-json (sanitize-json report))
     (when out-path
       (define parent (path-only (string->path out-path)))
       (when parent (make-directory* parent))
       (call-with-output-file out-path
         #:exists 'replace
         (lambda (p) (write-json clean-json p) (newline p))))
     (if emit-json?
         (begin (write-json clean-json) (newline))
         (print-report report))
     (when (and strict? (> (hash-ref (hash-ref report 'summary) 'failed) 0))
       (exit 1))]))
