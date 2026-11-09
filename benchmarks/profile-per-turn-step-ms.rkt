#lang racket/base

(require racket/list
         racket/vector
         racket/set
         racket/math
         racket/format
         racket/bytes
         "../lib/sc2-protobuf-ws.rkt"
         "../lib/bot-runtime.rkt"
         "../lib/econ-ledger.rkt"
         "../lib/tactics-sim.rkt")

(provide build-midgame-response-observation-bytes
         run-benchmark)

;; =============================================================================
;; Deterministic 500-Turn Per-Turn (`step_ms`) Microbenchmark Suite
;; Profiles:
;;   (a) `obs_ms`       : `decode-sc2-response` + `sc2-observation->runtime-obs-hash`
;;   (b) `runtime_ms`   : `step-live-bot-runtime!` (`step-bot-runtime` +
;;                        `compute-priority-schedule` + `step-tactical-mirror-brain!`)
;;   (c) `translate_ms` : `translate-bot-actions->sc2-raw-commands` +
;;                        `saturate-workers-and-gas-commands` + `make-request-action`
;; =============================================================================

(define (encode-point2d x y)
  (bytes-append (encode-float32 1 x)
                (encode-float32 2 y)))

(define (encode-point3d x y z)
  (bytes-append (encode-float32 1 x)
                (encode-float32 2 y)
                (encode-float32 3 z)))

(define (encode-unit-order ability-id target-tag target-pos progress)
  (bytes-append
   (encode-uint32 1 ability-id)
   (if target-pos
       (encode-submessage-field 2 (encode-point3d (car target-pos) (cadr target-pos) 0.0))
       #"")
   (if (> target-tag 0)
       (encode-uint64 3 target-tag)
       #"")
   (encode-float32 4 progress)))

(define (encode-unit
         #:alliance [alliance 1]
         #:tag [tag 1000]
         #:unit-type [unit-type 104]
         #:owner [owner 1]
         #:x [x 50.0]
         #:y [y 50.0]
         #:z [z 8.0]
         #:facing [facing 0.0]
         #:radius [radius 0.5]
         #:build-progress [build-progress 1.0]
         #:health [health 40.0]
         #:health-max [health-max 40.0]
         #:shield [shield 0.0]
         #:shield-max [shield-max 0.0]
         #:energy [energy 0.0]
         #:energy-max [energy-max 0.0]
         #:mineral-contents [mineral-contents 0]
         #:vespene-contents [vespene-contents 0]
         #:is-flying [is-flying #f]
         #:is-burrowed [is-burrowed #f]
         #:is-powered [is-powered #t]
         #:orders [orders '()]
         #:buff-ids [buff-ids '()]
         #:assigned-harvesters [assigned-harvesters 0]
         #:ideal-harvesters [ideal-harvesters 0]
         #:weapon-cooldown [weapon-cooldown 0.0]
         #:engaged-target-tag [engaged-target-tag 0]
         #:attack-upgrade [attack-upgrade 1]
         #:armor-upgrade [armor-upgrade 1]
         #:shield-upgrade [shield-upgrade 0])
  (bytes-append
   (encode-uint32 1 1) ;; display_type = Visible
   (encode-uint32 2 alliance)
   (encode-uint64 3 tag)
   (encode-uint32 4 unit-type)
   (encode-uint32 5 owner)
   (encode-submessage-field 6 (encode-point3d x y z))
   (encode-float32 7 facing)
   (encode-float32 8 radius)
   (encode-float32 9 build-progress)
   (encode-uint32 10 3) ;; cloak = NotCloaked
   (encode-bool 11 #f)
   (encode-bool 12 #t)
   (encode-bool 13 #f)
   (encode-float32 14 health)
   (encode-float32 15 health-max)
   (encode-float32 16 shield)
   (encode-float32 17 energy)
   (if (> mineral-contents 0) (encode-uint32 18 mineral-contents) #"")
   (if (> vespene-contents 0) (encode-uint32 19 vespene-contents) #"")
   (encode-bool 20 is-flying)
   (encode-bool 21 is-burrowed)
   (apply bytes-append
          (for/list ([ord (in-list orders)])
            (encode-submessage-field 22 ord)))
   (apply bytes-append
          (for/list ([b (in-list buff-ids)])
            (encode-uint32 27 b)))
   (if (> assigned-harvesters 0) (encode-uint32 28 assigned-harvesters) #"")
   (if (> ideal-harvesters 0) (encode-uint32 29 ideal-harvesters) #"")
   (encode-float32 30 weapon-cooldown)
   (if (> engaged-target-tag 0) (encode-uint64 34 engaged-target-tag) #"")
   (encode-bool 35 is-powered)
   (encode-float32 36 shield-max)
   (encode-float32 37 energy-max)
   (encode-bool 38 #f)
   (encode-bool 39 (not (null? orders)))
   (encode-uint32 40 attack-upgrade)
   (encode-uint32 41 armor-upgrade)
   (encode-uint32 42 shield-upgrade)))

(define (build-midgame-response-observation-bytes turn-idx)
  (define game-loop (+ 2400 (* turn-idx 4)))
  (define phase (modulo turn-idx 20))
  (define dx (* 0.25 (- phase 10)))
  (define minerals (+ 350 (* 15 (modulo turn-idx 17))))
  (define vespene (+ 220 (* 10 (modulo turn-idx 13))))

  ;; 1. Self structures (26 structures)
  (define self-structures
    (append
     ;; 3 Bases: Lair (100), Hatchery (86), Hatchery (86)
     (list
      (encode-unit #:alliance 1 #:tag 1001 #:unit-type 100 #:owner 1
                   #:x 36.0 #:y 36.0 #:radius 2.75 #:health 1800.0 #:health-max 1800.0
                   #:assigned-harvesters 16 #:ideal-harvesters 16)
      (encode-unit #:alliance 1 #:tag 1002 #:unit-type 86 #:owner 1
                   #:x 36.0 #:y 68.0 #:radius 2.75 #:health 1500.0 #:health-max 1500.0
                   #:assigned-harvesters 16 #:ideal-harvesters 16)
      (encode-unit #:alliance 1 #:tag 1003 #:unit-type 86 #:owner 1
                   #:x 68.0 #:y 36.0 #:radius 2.75 #:health 1500.0 #:health-max 1500.0
                   #:assigned-harvesters 12 #:ideal-harvesters 16))
     ;; Tech structures: SpawningPool (89), RoachWarren (97), HydraliskDen (91), Spire (92), InfestationPit (94), 2x EvolutionChamber (90)
     (list
      (encode-unit #:alliance 1 #:tag 1010 #:unit-type 89 #:owner 1 #:x 30.0 #:y 32.0 #:health 1000.0 #:health-max 1000.0)
      (encode-unit #:alliance 1 #:tag 1011 #:unit-type 97 #:owner 1 #:x 32.0 #:y 30.0 #:health 850.0 #:health-max 850.0)
      (encode-unit #:alliance 1 #:tag 1012 #:unit-type 91 #:owner 1 #:x 28.0 #:y 35.0 #:health 850.0 #:health-max 850.0)
      (encode-unit #:alliance 1 #:tag 1013 #:unit-type 92 #:owner 1 #:x 28.0 #:y 38.0 #:health 850.0 #:health-max 850.0)
      (encode-unit #:alliance 1 #:tag 1014 #:unit-type 94 #:owner 1 #:x 33.0 #:y 27.0 #:health 850.0 #:health-max 850.0)
      (encode-unit #:alliance 1 #:tag 1015 #:unit-type 90 #:owner 1 #:x 35.0 #:y 27.0 #:health 750.0 #:health-max 750.0)
      (encode-unit #:alliance 1 #:tag 1016 #:unit-type 90 #:owner 1 #:x 38.0 #:y 27.0 #:health 750.0 #:health-max 750.0))
     ;; 6 Extractors (88)
     (for/list ([i (in-range 6)])
       (encode-unit #:alliance 1 #:tag (+ 1020 i) #:unit-type 88 #:owner 1
                    #:x (+ 32.0 (* i 6.0)) #:y 40.0 #:radius 1.5
                    #:health 500.0 #:health-max 500.0
                    #:vespene-contents 1200
                    #:assigned-harvesters (if (< i 5) 3 1)
                    #:ideal-harvesters 3))
     ;; 6 Burrowed Creep Tumors (137) + 4 Spine Crawlers (98)
     (for/list ([i (in-range 6)])
       (encode-unit #:alliance 1 #:tag (+ 1030 i) #:unit-type 137 #:owner 1
                    #:x (+ 48.0 (* i 6.0)) #:y (+ 48.0 (* i 6.0))
                    #:health 50.0 #:health-max 50.0 #:is-burrowed #t))
     (for/list ([i (in-range 4)])
       (encode-unit #:alliance 1 #:tag (+ 1040 i) #:unit-type 98 #:owner 1
                    #:x (+ 60.0 (* i 2.0)) #:y 60.0
                    #:health 300.0 #:health-max 300.0))))

  ;; 2. Self Drones (54 workers, 48 harvesting, 6 idle to exercise saturation)
  (define self-drones
    (for/list ([i (in-range 54)])
      (define idle? (>= i 48))
      (define min-tag (+ 9000 (modulo i 24)))
      (encode-unit #:alliance 1 #:tag (+ 2000 i) #:unit-type 104 #:owner 1
                   #:x (+ 34.0 (modulo i 12)) #:y (+ 34.0 (* 4.0 (quotient i 12)))
                   #:radius 0.375 #:health 40.0 #:health-max 40.0
                   #:orders (if idle?
                                '()
                                (list (encode-unit-order 295 min-tag #f 0.5))))))

  ;; 3. Self Larva (12), Overlords (8), Overseers (2), Queens (4)
  (define self-support
    (append
     (for/list ([i (in-range 12)])
       (encode-unit #:alliance 1 #:tag (+ 2200 i) #:unit-type 151 #:owner 1
                    #:x (+ 35.0 (* 0.5 i)) #:y 35.0 #:radius 0.25 #:health 25.0 #:health-max 25.0))
     (for/list ([i (in-range 8)])
       (encode-unit #:alliance 1 #:tag (+ 2300 i) #:unit-type 106 #:owner 1
                    #:x (+ 40.0 (* i 12.0)) #:y (+ 40.0 (* i 8.0))
                    #:radius 1.0 #:health 200.0 #:health-max 200.0 #:is-flying #t))
     (for/list ([i (in-range 2)])
       (encode-unit #:alliance 1 #:tag (+ 2320 i) #:unit-type 129 #:owner 1
                    #:x (+ 82.0 (* i 4.0)) #:y 82.0
                    #:radius 1.0 #:health 200.0 #:health-max 200.0
                    #:energy 75.0 #:energy-max 200.0 #:is-flying #t))
     (for/list ([i (in-range 4)])
       (encode-unit #:alliance 1 #:tag (+ 2340 i) #:unit-type 126 #:owner 1
                    #:x (+ 37.0 (* i 10.0)) #:y (+ 37.0 (* i 10.0))
                    #:radius 0.875 #:health 175.0 #:health-max 175.0
                    #:energy (+ 30.0 (* i 10.0)) #:energy-max 200.0))))

  ;; 4. Self Combat Army (62 units: 24 Zerglings (105), 6 Banelings (9), 14 Roaches (110), 4 Ravagers (688), 10 Hydralisks (107), 4 Mutalisks (108))
  (define self-army
    (append
     (for/list ([i (in-range 24)])
       (encode-unit #:alliance 1 #:tag (+ 3000 i) #:unit-type 105 #:owner 1
                    #:x (+ 84.0 dx (* 0.6 (modulo i 6)))
                    #:y (+ 84.0 (* 0.6 (quotient i 6)))
                    #:radius 0.375
                    #:health (max 10.0 (- 35.0 (* 2.0 (modulo (+ i turn-idx) 8))))
                    #:health-max 35.0
                    #:weapon-cooldown (if (even? (+ i turn-idx)) 0.0 4.0)
                    #:engaged-target-tag (+ 6000 (modulo i 12))))
     (for/list ([i (in-range 6)])
       (encode-unit #:alliance 1 #:tag (+ 3100 i) #:unit-type 9 #:owner 1
                    #:x (+ 86.0 dx (* 0.7 i)) #:y 85.0
                    #:radius 0.375 #:health 30.0 #:health-max 35.0))
     (for/list ([i (in-range 14)])
       (encode-unit #:alliance 1 #:tag (+ 3200 i) #:unit-type 110 #:owner 1
                    #:x (+ 81.0 dx (* 0.8 (modulo i 7)))
                    #:y (+ 81.0 (* 0.8 (quotient i 7)))
                    #:radius 0.75
                    #:health (max 30.0 (- 145.0 (* 12.0 (modulo (+ i turn-idx) 9))))
                    #:health-max 145.0
                    #:weapon-cooldown (if (zero? (modulo (+ i turn-idx) 3)) 8.0 0.0)
                    #:engaged-target-tag (+ 6000 (modulo i 16))))
     (for/list ([i (in-range 4)])
       (encode-unit #:alliance 1 #:tag (+ 3300 i) #:unit-type 688 #:owner 1
                    #:x (+ 79.0 dx (* 1.0 i)) #:y 79.0
                    #:radius 0.875 #:health 110.0 #:health-max 120.0
                    #:weapon-cooldown 0.0))
     (for/list ([i (in-range 10)])
       (encode-unit #:alliance 1 #:tag (+ 3400 i) #:unit-type 107 #:owner 1
                    #:x (+ 77.0 dx (* 0.7 (modulo i 5)))
                    #:y (+ 77.0 (* 0.7 (quotient i 5)))
                    #:radius 0.625 #:health 85.0 #:health-max 90.0
                    #:weapon-cooldown (if (odd? (+ i turn-idx)) 2.0 0.0)))
     (for/list ([i (in-range 4)])
       (encode-unit #:alliance 1 #:tag (+ 3500 i) #:unit-type 108 #:owner 1
                    #:x (+ 85.0 dx (* 1.1 i)) #:y 92.0
                    #:radius 0.75 #:health 115.0 #:health-max 120.0 #:is-flying #t))))

  ;; 5. Enemy Combat Army (40 units: 14 Zealots (73), 14 Stalkers (74), 4 Immortals (83), 2 Colossus (4), 4 HighTemplar (75), 2 Archons (141))
  (define enemy-army
    (append
     (for/list ([i (in-range 14)])
       (encode-unit #:alliance 4 #:tag (+ 6000 i) #:unit-type 73 #:owner 2
                    #:x (+ 90.0 (- dx) (* 0.7 (modulo i 7)))
                    #:y (+ 90.0 (* 0.7 (quotient i 7)))
                    #:radius 0.5 #:health 100.0 #:health-max 100.0
                    #:shield (max 0.0 (- 50.0 (* 8.0 (modulo (+ i turn-idx) 6))))
                    #:shield-max 50.0))
     (for/list ([i (in-range 14)])
       (encode-unit #:alliance 4 #:tag (+ 6100 i) #:unit-type 74 #:owner 2
                    #:x (+ 93.0 (- dx) (* 0.8 (modulo i 7)))
                    #:y (+ 93.0 (* 0.8 (quotient i 7)))
                    #:radius 0.625 #:health 80.0 #:health-max 80.0
                    #:shield 60.0 #:shield-max 80.0))
     (for/list ([i (in-range 4)])
       (encode-unit #:alliance 4 #:tag (+ 6200 i) #:unit-type 83 #:owner 2
                    #:x (+ 95.0 (* 1.2 i)) #:y 95.0
                    #:radius 0.875 #:health 200.0 #:health-max 200.0
                    #:shield 90.0 #:shield-max 100.0))
     (for/list ([i (in-range 2)])
       (encode-unit #:alliance 4 #:tag (+ 6300 i) #:unit-type 4 #:owner 2
                    #:x (+ 97.0 (* 1.5 i)) #:y 97.0
                    #:radius 1.125 #:health 200.0 #:health-max 200.0
                    #:shield 150.0 #:shield-max 150.0))
     (for/list ([i (in-range 4)])
       (encode-unit #:alliance 4 #:tag (+ 6400 i) #:unit-type 75 #:owner 2
                    #:x (+ 96.0 (* 1.0 i)) #:y 94.0
                    #:radius 0.5 #:health 40.0 #:health-max 40.0
                    #:shield 40.0 #:shield-max 40.0 #:energy 90.0 #:energy-max 200.0))
     (for/list ([i (in-range 2)])
       (encode-unit #:alliance 4 #:tag (+ 6500 i) #:unit-type 141 #:owner 2
                    #:x (+ 91.0 (* 1.2 i)) #:y 91.0
                    #:radius 1.25 #:health 10.0 #:health-max 10.0
                    #:shield 320.0 #:shield-max 350.0))))

  ;; 6. Enemy Structures (12 structures: 2 Nexus (59), 4 Pylons (60), 3 Gateways (62), 1 CyberneticsCore (72), 1 RoboticsFacility (71), 1 PhotonCannon (66))
  (define enemy-structures
    (list
     (encode-unit #:alliance 4 #:tag 7001 #:unit-type 59 #:owner 2 #:x 140.0 #:y 140.0 #:radius 2.75 #:health 1000.0 #:health-max 1000.0 #:shield 1000.0 #:shield-max 1000.0)
     (encode-unit #:alliance 4 #:tag 7002 #:unit-type 59 #:owner 2 #:x 140.0 #:y 108.0 #:radius 2.75 #:health 1000.0 #:health-max 1000.0 #:shield 1000.0 #:shield-max 1000.0)
     (encode-unit #:alliance 4 #:tag 7010 #:unit-type 60 #:owner 2 #:x 132.0 #:y 132.0 #:radius 1.0 #:health 200.0 #:health-max 200.0 #:shield 200.0 #:shield-max 200.0)
     (encode-unit #:alliance 4 #:tag 7011 #:unit-type 60 #:owner 2 #:x 136.0 #:y 128.0 #:radius 1.0 #:health 200.0 #:health-max 200.0 #:shield 200.0 #:shield-max 200.0)
     (encode-unit #:alliance 4 #:tag 7012 #:unit-type 60 #:owner 2 #:x 128.0 #:y 136.0 #:radius 1.0 #:health 200.0 #:health-max 200.0 #:shield 200.0 #:shield-max 200.0)
     (encode-unit #:alliance 4 #:tag 7013 #:unit-type 60 #:owner 2 #:x 135.0 #:y 112.0 #:radius 1.0 #:health 200.0 #:health-max 200.0 #:shield 200.0 #:shield-max 200.0)
     (encode-unit #:alliance 4 #:tag 7020 #:unit-type 62 #:owner 2 #:x 130.0 #:y 130.0 #:radius 1.75 #:health 500.0 #:health-max 500.0 #:shield 500.0 #:shield-max 500.0)
     (encode-unit #:alliance 4 #:tag 7021 #:unit-type 62 #:owner 2 #:x 134.0 #:y 130.0 #:radius 1.75 #:health 500.0 #:health-max 500.0 #:shield 500.0 #:shield-max 500.0)
     (encode-unit #:alliance 4 #:tag 7022 #:unit-type 62 #:owner 2 #:x 130.0 #:y 134.0 #:radius 1.75 #:health 500.0 #:health-max 500.0 #:shield 500.0 #:shield-max 500.0)
     (encode-unit #:alliance 4 #:tag 7030 #:unit-type 72 #:owner 2 #:x 126.0 #:y 132.0 #:radius 1.75 #:health 550.0 #:health-max 550.0 #:shield 550.0 #:shield-max 550.0)
     (encode-unit #:alliance 4 #:tag 7031 #:unit-type 71 #:owner 2 #:x 126.0 #:y 128.0 #:radius 1.75 #:health 450.0 #:health-max 450.0 #:shield 450.0 #:shield-max 450.0)
     (encode-unit #:alliance 4 #:tag 7040 #:unit-type 66 #:owner 2 #:x 122.0 #:y 118.0 #:radius 1.0 #:health 150.0 #:health-max 150.0 #:shield 150.0 #:shield-max 150.0)))

  ;; 7. Neutral Mineral Fields (24 x type 341) & Vespene Geysers (6 x type 342)
  (define neutral-resources
    (append
     (for/list ([i (in-range 24)])
       (define base-idx (quotient i 8))
       (define bx (if (= base-idx 2) 68.0 36.0))
       (define by (if (= base-idx 1) 68.0 36.0))
       (encode-unit #:alliance 3 #:tag (+ 9000 i) #:unit-type 341 #:owner 16
                    #:x (+ bx -6.0 (* 1.5 (modulo i 8)))
                    #:y (+ by -5.0)
                    #:radius 1.125 #:health 1800.0 #:health-max 1800.0
                    #:mineral-contents 1350))
     (for/list ([i (in-range 6)])
       (encode-unit #:alliance 3 #:tag (+ 9200 i) #:unit-type 342 #:owner 16
                    #:x (+ 32.0 (* i 6.0)) #:y 40.0
                    #:radius 1.5 #:health 10000.0 #:health-max 10000.0
                    #:vespene-contents 1200))))

  (define all-units
    (append self-structures
            self-drones
            self-support
            self-army
            enemy-army
            enemy-structures
            neutral-resources))

  (define player-common-bytes
    (bytes-append
     (encode-uint32 1 1)          ;; player_id = 1
     (encode-uint32 2 minerals)   ;; minerals
     (encode-uint32 3 vespene)    ;; vespene
     (encode-uint32 4 164)        ;; food_cap
     (encode-uint32 5 142)        ;; food_used
     (encode-uint32 6 88)         ;; food_army
     (encode-uint32 7 54)         ;; food_workers
     (encode-uint32 8 6)          ;; idle_worker_count
     (encode-uint32 9 62)         ;; army_count
     (encode-uint32 10 0)         ;; warp_gate_count
     (encode-uint32 11 12)))      ;; larva_count

  (define player-raw-bytes
    (bytes-append
     (encode-submessage-field
      1
      (bytes-append (encode-submessage-field 1 (encode-point3d 132.0 132.0 8.0))
                    (encode-float32 2 6.5)
                    (encode-uint64 3 7010)))
     (encode-submessage-field 2 (encode-point3d 84.0 84.0 12.0))
     (encode-uint32 3 66)   ;; zerglingmovementspeed
     (encode-uint32 3 53)   ;; zergmeleeweaponslevel1
     (encode-uint32 3 59))) ;; zergmissileweaponslevel1

  (define effect-bytes
    (bytes-append
     (encode-uint32 1 1) ;; PSI_STORM_PERSISTENT = 1
     (encode-submessage-field 2 (encode-point2d 85.5 85.5))
     (encode-uint32 3 4) ;; Enemy
     (encode-uint32 4 2)
     (encode-float32 5 1.5)))

  (define raw-data-bytes
    (bytes-append
     (encode-submessage-field 1 player-raw-bytes)
     (apply bytes-append
            (for/list ([ub (in-list all-units)])
              (encode-submessage-field 2 ub)))
     (encode-submessage-field 5 effect-bytes)))

  (define observation-bytes
    (bytes-append
     (encode-submessage-field 1 player-common-bytes)
     (encode-submessage-field 5 raw-data-bytes)
     (encode-uint32 9 game-loop)))

  (define resp-obs-bytes
    (encode-submessage-field 3 observation-bytes))

  (values
   (bytes-append
    (encode-uint32 97 (+ 1 turn-idx))
    (encode-uint32 99 3) ;; in_game
    (encode-submessage-field 10 resp-obs-bytes))
   (length all-units)))

(define (percentile sorted-vec pct)
  (define n (vector-length sorted-vec))
  (if (zero? n)
      0.0
      (let ([idx (min (sub1 n) (max 0 (exact-floor (* pct n))))])
        (vector-ref sorted-vec idx))))

(define (mean vec)
  (define n (vector-length vec))
  (if (zero? n)
      0.0
      (/ (for/fold ([s 0.0]) ([x (in-vector vec)]) (+ s x))
         (exact->inexact n))))

(define (run-benchmark [num-turns 500])
  (printf "==> Building ~a deterministic mid-game ResponseObservation frames...\n" num-turns)
  (define-values (first-frame unit-count) (build-midgame-response-observation-bytes 0))
  (define frames
    (for/vector #:length num-turns ([t (in-range num-turns)])
      (if (zero? t)
          first-frame
          (let-values ([(b _cnt) (build-midgame-response-observation-bytes t)])
            b))))
  (printf "==> Frame 0 size: ~a bytes, total units per frame: ~a\n"
          (bytes-length first-frame) unit-count)

  (define game-info
    (sc2-game-info "AcropolisLE" "" '() (cons 176 176)
                   (hash 'x0 8 'y0 8 'x1 168 'y1 168)
                   (list (sc2-point2d 36.0 36.0) (sc2-point2d 140.0 140.0))))

  ;; Warmup 10 turns
  (let ([warm-state (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg #:initial-posture 'Macro12Hatch)])
    (for ([t (in-range (min 10 num-turns))])
      (define resp (decode-sc2-response (vector-ref frames t)))
      (define obs-struct (sc2-response-observation resp))
      (define obs-hash
        (sc2-observation->runtime-obs-hash
         obs-struct
         #:game-info game-info
         #:our-player-id 1
         #:configured-race 'Zerg
         #:used-creep-tumors (live-bot-runtime-used-creep-tumors warm-state)))
      (define step-res (step-live-bot-runtime! warm-state obs-hash))
      (define bot-actions
        (append (hash-ref step-res 'actions '())
                (hash-ref step-res 'mirror-actions '())))
      (define commanded-workers (mutable-seteqv))
      (define raw-cmds
        (append
         (translate-bot-actions->sc2-raw-commands
          bot-actions
          obs-struct
          #:used-creep-tumors (live-bot-runtime-used-creep-tumors warm-state)
          #:ws-conn #f
          #:enemy-base (hash-ref obs-hash 'enemy-base #f)
          #:commanded-workers commanded-workers)
         (saturate-workers-and-gas-commands
          obs-struct
          #:excluded-worker-tags commanded-workers)))
      (make-request-action raw-cmds #:id (+ 1000 t))))

  (collect-garbage)
  (collect-garbage)

  (define state (make-live-bot-runtime #:bot-name 'Mothman-Z #:race 'Zerg #:initial-posture 'Macro12Hatch))
  (define obs-times (make-vector num-turns 0.0))
  (define runtime-times (make-vector num-turns 0.0))
  (define translate-times (make-vector num-turns 0.0))
  (define step-times (make-vector num-turns 0.0))
  (define total-actions-emitted 0)
  (define total-raw-cmds-encoded 0)
  (define digest-acc 0)

  (define t-bench-start (current-inexact-monotonic-milliseconds))
  (for ([t (in-range num-turns)])
    (define frame-bytes (vector-ref frames t))

    ;; Stage (a): obs_ms (`decode-sc2-response` + `sc2-observation->runtime-obs-hash`)
    (define t0 (current-inexact-monotonic-milliseconds))
    (define resp (decode-sc2-response frame-bytes))
    (define obs-struct (sc2-response-observation resp))
    (define obs-hash
      (sc2-observation->runtime-obs-hash
       obs-struct
       #:game-info game-info
       #:our-player-id 1
       #:configured-race 'Zerg
       #:used-creep-tumors (live-bot-runtime-used-creep-tumors state)))
    (define t1 (current-inexact-monotonic-milliseconds))

    ;; Stage (b): runtime_ms (`step-live-bot-runtime!`)
    (define step-res (step-live-bot-runtime! state obs-hash))
    (define actions
      (append (hash-ref step-res 'actions '())
              (hash-ref step-res 'mirror-actions '())))
    (define t2 (current-inexact-monotonic-milliseconds))

    ;; Stage (c): translate_ms (`translate-bot-actions->sc2-raw-commands` + `saturate` + `make-request-action`)
    (define commanded-workers (mutable-seteqv))
    (define translated-cmds
      (translate-bot-actions->sc2-raw-commands
       actions
       obs-struct
       #:used-creep-tumors (live-bot-runtime-used-creep-tumors state)
       #:ws-conn #f
       #:enemy-base (hash-ref obs-hash 'enemy-base #f)
       #:commanded-workers commanded-workers))
    (define sat-cmds
      (saturate-workers-and-gas-commands
       obs-struct
       #:excluded-worker-tags commanded-workers))
    (define raw-cmds (append translated-cmds sat-cmds))
    (define req-bytes (make-request-action raw-cmds #:id (+ 1 t)))
    (define t3 (current-inexact-monotonic-milliseconds))

    (define obs-ms (- t1 t0))
    (define rt-ms (- t2 t1))
    (define tr-ms (- t3 t2))
    (define st-ms (- t3 t0))

    (vector-set! obs-times t obs-ms)
    (vector-set! runtime-times t rt-ms)
    (vector-set! translate-times t tr-ms)
    (vector-set! step-times t st-ms)

    (set! total-actions-emitted (+ total-actions-emitted (length actions)))
    (set! total-raw-cmds-encoded (+ total-raw-cmds-encoded (length raw-cmds)))
    (set! digest-acc
          (bitwise-and #x7FFFFFFF
                       (+ (* digest-acc 31)
                          (length actions)
                          (* 7 (length raw-cmds))
                          (bytes-length req-bytes)))))
  (define t-bench-end (current-inexact-monotonic-milliseconds))

  (define sorted-step (vector-sort step-times <))
  (define sorted-obs (vector-sort obs-times <))
  (define sorted-rt (vector-sort runtime-times <))
  (define sorted-tr (vector-sort translate-times <))

  (printf "\n======================================================================\n")
  (printf "PER-TURN (`step_ms`) PIPELINE BENCHMARK RESULTS (~a turns, ~a units/turn)\n"
          num-turns unit-count)
  (printf "======================================================================\n")
  (printf "Total wall time     : ~a ms\n" (~r (- t-bench-end t-bench-start) #:precision '(= 2)))
  (printf "avg_step_ms         : ~a ms\n" (~r (mean step-times) #:precision '(= 3)))
  (printf "p50_step_ms         : ~a ms\n" (~r (percentile sorted-step 0.50) #:precision '(= 3)))
  (printf "p95_step_ms         : ~a ms\n" (~r (percentile sorted-step 0.95) #:precision '(= 3)))
  (printf "p99_step_ms         : ~a ms\n" (~r (percentile sorted-step 0.99) #:precision '(= 3)))
  (printf "max_step_ms         : ~a ms\n" (~r (vector-ref sorted-step (sub1 num-turns)) #:precision '(= 3)))
  (printf "----------------------------------------------------------------------\n")
  (printf "avg_obs_ms          : ~a ms (p95: ~a ms, max: ~a ms)\n"
          (~r (mean obs-times) #:precision '(= 3))
          (~r (percentile sorted-obs 0.95) #:precision '(= 3))
          (~r (vector-ref sorted-obs (sub1 num-turns)) #:precision '(= 3)))
  (printf "avg_runtime_ms      : ~a ms (p95: ~a ms, max: ~a ms)\n"
          (~r (mean runtime-times) #:precision '(= 3))
          (~r (percentile sorted-rt 0.95) #:precision '(= 3))
          (~r (vector-ref sorted-rt (sub1 num-turns)) #:precision '(= 3)))
  (printf "avg_translate_ms    : ~a ms (p95: ~a ms, max: ~a ms)\n"
          (~r (mean translate-times) #:precision '(= 3))
          (~r (percentile sorted-tr 0.95) #:precision '(= 3))
          (~r (vector-ref sorted-tr (sub1 num-turns)) #:precision '(= 3)))
  (printf "----------------------------------------------------------------------\n")
  (printf "Total bot actions   : ~a (~a/turn)\n"
          total-actions-emitted (~r (/ total-actions-emitted (exact->inexact num-turns)) #:precision '(= 1)))
  (printf "Total raw SC2 cmds  : ~a (~a/turn)\n"
          total-raw-cmds-encoded (~r (/ total-raw-cmds-encoded (exact->inexact num-turns)) #:precision '(= 1)))
  (printf "Verification digest : ~a\n" digest-acc)
  (printf "======================================================================\n"))

(module+ main
  (run-benchmark 500))
