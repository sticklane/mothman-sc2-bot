#lang racket/base

;; =============================================================================
;; Comprehensive Unit, Wire-Codec, Actuator & Mock-SC2 WebSocket Server Test Suite
;; for `lib/sc2-protobuf-ws.rkt` and `sim/racket-sc2-ladder-main.rkt`
;; =============================================================================

(require racket/bytes
         racket/list
         racket/match
         racket/math
         racket/port
         racket/set
         racket/string
         racket/tcp
         "../lib/sc2-game-constants.rkt"
         "../lib/sc2-protobuf-ws.rkt"
         "../sim/racket-sc2-ladder-main.rkt")

(define total-checks 0)
(define failed-checks 0)

(define (check-true label cond-val)
  (set! total-checks (add1 total-checks))
  (unless cond-val
    (set! failed-checks (add1 failed-checks))
    (printf "  [FAIL] ~a\n" label)))

(define (check-eqv label actual expected)
  (set! total-checks (add1 total-checks))
  (unless (equal? actual expected)
    (set! failed-checks (add1 failed-checks))
    (printf "  [FAIL] ~a: expected ~s, got ~s\n" label expected actual)))

(define (check-approx label actual expected [eps 1e-4])
  (set! total-checks (add1 total-checks))
  (unless (<= (abs (- actual expected)) eps)
    (set! failed-checks (add1 failed-checks))
    (printf "  [FAIL] ~a: expected ~a ± ~a, got ~a\n" label expected eps actual)))

(printf "=================================================================\n")
(printf "SUITE: Pure-Racket SC2 Protobuf + RFC 6455 WebSocket Client Tests\n")
(printf "=================================================================\n")

;; -----------------------------------------------------------------------------
;; 1. Protobuf Wire-Format Round-Trip Tests
;; -----------------------------------------------------------------------------
(printf "[1/5] Testing Protobuf varint, float32, packed/unpacked repeated fields...\n")

(for ([v (in-list '(0 1 7 127 128 255 300 16384 65535 4294967295 9007199254740991))])
  (define enc (encode-varint v))
  (define-values (dec next-pos) (decode-varint enc 0))
  (check-eqv (format "varint-roundtrip-~a" v) dec v)
  (check-eqv (format "varint-len-~a" v) next-pos (bytes-length enc)))

(for ([f (in-list '(0.0 1.0 -1.0 32.5 144.25 -75.125 2048.0))])
  (define enc (encode-float32 f))
  (check-eqv (format "float32-4bytes-~a" f) (bytes-length enc) 4)
  (check-approx (format "float32-roundtrip-~a" f) (decode-float32 enc 0) f 1e-4))

;; Test packed and unpacked repeated varints in decode-packed-or-unpacked-varints
(define packed-payload
  (bytes-append (encode-varint 66) (encode-varint 84) (encode-varint 134)))
(define mixed-msg
  (bytes-append
   (encode-uint32 3 15)
   (encode-bytes-field 3 packed-payload)
   (encode-uint32 3 87)))
(define decoded-mixed-fields (decode-protobuf-message mixed-msg))
(define extracted-varints (decode-packed-or-unpacked-varints decoded-mixed-fields 3))
(check-eqv "packed-and-unpacked-varints" extracted-varints '(15 66 84 134 87))

;; -----------------------------------------------------------------------------
;; 2. Canonical SC2 ID Tables (36 Units, 35+ Structures, Upgrades, Morphs, Spells)
;; -----------------------------------------------------------------------------
(printf "[2/5] Testing Canonical Unit / Ability / Upgrade / Buff / Effect ID tables...\n")

(define trainable-36-units
  '(;; Zerg (12)
    drone overlord zergling roach hydralisk mutalisk corruptor
    infestor swarm-host ultralisk viper queen
    ;; Terran (13)
    scv marine marauder reaper ghost hellion hellbat widow-mine
    siege-tank cyclone thor viking medivac liberator raven banshee battlecruiser
    ;; Protoss (14)
    probe zealot stalker sentry adept high-templar dark-templar
    observer immortal warp-prism colossus disruptor
    phoenix void-ray oracle carrier tempest mothership))

(for ([u (in-list trainable-36-units)])
  (define uid (unit-symbol->sc2-id u 0))
  (define tid (train-symbol->ability-id u))
  (check-true (format "unit-id-exists-~a" u) (> uid 0))
  (check-true (format "train-ability-exists-~a" u) (and (exact-integer? tid) (> tid 0))))

(define buildable-35-structures
  '(;; Zerg
    hatchery lair hive extractor spawning-pool evolution-chamber
    roach-warren baneling-nest hydralisk-den lurker-den spire greater-spire
    infestation-pit ultralisk-cavern nydus-network spine-crawler spore-crawler
    ;; Terran
    command-center orbital-command planetary-fortress supply-depot refinery
    barracks factory starport engineering-bay armory bunker
    missile-turret sensor-tower ghost-academy fusion-core
    ;; Protoss
    nexus pylon assimilator gateway forge cybernetics-core
    photon-cannon shield-battery twilight-council robotics-facility
    robotics-bay stargate templar-archive dark-shrine fleet-beacon))

(for ([b (in-list buildable-35-structures)])
  (define bid (unit-symbol->sc2-id b 0))
  (define ab-id (build-symbol->ability-id b))
  (check-true (format "bldg-id-exists-~a" b) (> bid 0))
  (check-true (format "build-ability-exists-~a" b) (and (exact-integer? ab-id) (> ab-id 0))))

(for ([upg (in-list '(zergling-movementspeed glial-reconstitution grooved-spines
                      stimpack combat-shield concussive-shells
                      warpgate charge blink extended-thermal-lance psi-storm))])
  (check-true (format "upgrade-id-~a" upg) (> (upgrade-symbol->sc2-id upg 0) 0))
  (check-true (format "research-ability-~a" upg)
              (let ([aid (research-symbol->ability-id upg)])
                (and (exact-integer? aid) (> aid 0)))))

;; -----------------------------------------------------------------------------
;; 3. `s2clientprotocol` Request Builders & Response Decoders
;; -----------------------------------------------------------------------------
(printf "[3/5] Testing s2clientprotocol Request / Response wire encoding...\n")

(define cg-bytes
  (make-request-create-game #:map-path "Simple64.SC2Map"
                            #:our-race 'Zerg
                            #:computer-race 'Protoss
                            #:computer-difficulty 'VeryHard
                            #:realtime? #f
                            #:id 10))
(define cg-fields (decode-protobuf-message cg-bytes))
(check-true "create-game-has-field-1" (not (not (assoc 1 cg-fields))))
(check-true "create-game-has-id-97" (equal? (assoc 97 cg-fields) '(97 0 10)))

(define jg-bytes
  (make-request-join-game #:race 'Random
                          #:shared-port 5001
                          #:server-ports '(5002 5003)
                          #:client-ports '((5004 5005))
                          #:player-name "Mothman"
                          #:id 11))
(define jg-fields (decode-protobuf-message jg-bytes))
(check-true "join-game-has-field-2" (not (not (assoc 2 jg-fields))))

(define act-bytes
  (make-request-action
   (list (sc2-raw-unit-command 23 (sc2-point2d 48.5 64.0) 0 '(1001 1002) #f)
         (sc2-raw-camera-move 36.0 40.0 0.0)
         (sc2-chat-action 1 "gl hf"))
   #:id 12))
(define act-fields (decode-protobuf-message act-bytes))
(check-true "action-request-has-field-11" (not (not (assoc 11 act-fields))))

;; Construct a synthetic binary ResponseObservation and decode it
(define (encode-synthetic-unit tag unit-type alliance x y hp energy [assigned 0] [ideal 0])
  (bytes-append
   (encode-int32 1 1)
   (encode-int32 2 alliance)
   (encode-uint64 3 tag)
   (encode-uint32 4 unit-type)
   (encode-int32 5 (if (= alliance 1) 1 2))
   (encode-submessage-field 6 (encode-point3d x y 8.0))
   (encode-float32 8 1.25)
   (encode-float32 9 1.0)
   (encode-float32 14 hp)
   (encode-float32 15 hp)
   (encode-float32 17 energy)
   (if (> assigned 0) (encode-int32 28 assigned) #"")
   (if (> ideal 0) (encode-int32 29 ideal) #"")
   (if (= alliance 3) (encode-int32 18 1500) #"")))

(define (encode-synthetic-observation-response game-loop minerals vespene food-used food-cap
                                               units-bytes
                                               #:upgrade-ids [upgrade-ids '(66)]
                                               #:result [result #f]
                                               #:status [status 3])
  (define pc-bytes
    (bytes-append
     (encode-uint32 1 1)
     (encode-uint32 2 minerals)
     (encode-uint32 3 vespene)
     (encode-uint32 4 food-cap)
     (encode-uint32 5 food-used)
     (encode-uint32 6 (max 0 (- food-used 12)))
     (encode-uint32 7 12)
     (encode-uint32 8 1)
     (encode-uint32 9 4)
     (encode-uint32 11 3)))
  ;; Pack upgrade_ids into packed length-delimited field 3 of PlayerRaw
  (define packed-upgs (apply bytes-append (map encode-varint upgrade-ids)))
  (define player-raw-bytes
    (bytes-append
     (encode-submessage-field 2 (encode-point3d 32.0 32.0 10.0))
     (encode-bytes-field 3 packed-upgs)))
  (define obs-raw-bytes
    (bytes-append
     (encode-submessage-field 1 player-raw-bytes)
     (apply bytes-append (map (lambda (ub) (encode-submessage-field 2 ub)) units-bytes))))
  (define inner-obs-bytes
    (bytes-append
     (encode-submessage-field 1 pc-bytes)
     (encode-submessage-field 5 obs-raw-bytes)
     (encode-uint32 9 game-loop)))
  (define player-res-part
    (if result
        (encode-submessage-field 4 (bytes-append (encode-uint32 1 1)
                                                 (encode-int32 2 result)))
        #""))
  (define resp-obs-bytes
    (bytes-append
     (encode-submessage-field 3 inner-obs-bytes)
     player-res-part))
  (bytes-append
   (encode-submessage-field 10 resp-obs-bytes)
   (encode-int32 99 status)))

(define synth-units
  (list
   (encode-synthetic-unit 100 86 1 32.0 32.0 1500.0 0.0 12 16) ;; Hatchery
   (encode-synthetic-unit 101 89 1 36.0 34.0 1000.0 0.0)       ;; Spawning Pool
   (encode-synthetic-unit 102 151 1 33.0 31.0 25.0 0.0)        ;; Larva
   (encode-synthetic-unit 103 104 1 30.0 30.0 40.0 0.0)        ;; Idle Drone
   (encode-synthetic-unit 104 126 1 32.5 32.5 175.0 50.0)      ;; Queen
   (encode-synthetic-unit 105 105 1 40.0 40.0 35.0 0.0)        ;; Zergling
   (encode-synthetic-unit 200 341 3 26.0 32.0 10000.0 0.0)     ;; Mineral Field
   (encode-synthetic-unit 201 342 3 32.0 25.0 10000.0 0.0)     ;; Vespene Geyser
   (encode-synthetic-unit 300 73 4 140.0 140.0 100.0 0.0)))    ;; Enemy Zealot

(define synth-resp-bytes
  (encode-synthetic-observation-response 224 350 100 16 22 synth-units))
(define decoded-resp (decode-sc2-response synth-resp-bytes))
(check-eqv "decoded-resp-status" (sc2-response-status decoded-resp) 'in-game)
(define decoded-obs (sc2-response-observation decoded-resp))
(check-true "decoded-obs-present" (sc2-observation? decoded-obs))
(check-eqv "decoded-obs-loop" (sc2-observation-game-loop decoded-obs) 224)
(check-eqv "decoded-obs-minerals" (sc2-player-common-minerals (sc2-observation-player-common decoded-obs)) 350)
(check-eqv "decoded-obs-upgrades" (sc2-observation-upgrade-ids decoded-obs) '(66))
(check-eqv "decoded-obs-unit-count" (length (sc2-observation-units decoded-obs)) 9)

;; -----------------------------------------------------------------------------
;; 4. Observation Converter & S-Expression Actuator Tests
;; -----------------------------------------------------------------------------
(printf "[4/5] Testing sc2-observation->runtime-obs-hash & S-expression actuator...\n")

(define rt-obs-hash (sc2-observation->runtime-obs-hash decoded-obs))
(check-eqv "obs-hash-race" (hash-ref rt-obs-hash 'race) 'Zerg)
(check-eqv "obs-hash-minerals" (hash-ref rt-obs-hash 'minerals) 350)
(check-true "obs-hash-has-researched-speed"
            (pair? (memq 'zergling-movementspeed (hash-ref rt-obs-hash 'researched-upgrades))))

(define sexp-obs (sc2-observation->frame-state-sexp decoded-obs))
(check-eqv "sexp-obs-head" (car sexp-obs) 'frame-state)

(define sample-bot-actions
  '((train zergling)
    (build roach-warren 38.0 38.0)
    (build extractor 32.0 25.0)
    (expand 56.0 56.0)
    (inject-larva 104 100)
    (cast 104 spread-creep-tumor 42.0 42.0)
    (attack-pos (105) 140.0 140.0)
    (camera-focus home-macro-base 32.0 32.0)))

(define raw-cmds
  (append (translate-bot-actions->sc2-raw-commands sample-bot-actions decoded-obs)
          (saturate-workers-and-gas-commands decoded-obs)))
(check-true "translated-raw-cmds-non-empty" (>= (length raw-cmds) 8))
(check-true "translated-includes-train-zergling"
            (ormap (lambda (c)
                     (and (sc2-raw-unit-command? c)
                          (= (sc2-raw-unit-command-ability-id c) 1343)
                          (equal? (sc2-raw-unit-command-unit-tags c) '(102))))
                   raw-cmds))
(check-true "translated-includes-build-extractor-on-geyser"
            (ormap (lambda (c)
                     (and (sc2-raw-unit-command? c)
                          (= (sc2-raw-unit-command-ability-id c) 1154)
                          (= (sc2-raw-unit-command-target-unit-tag c) 201)))
                   raw-cmds))
(check-true "translated-includes-camera-move"
            (ormap sc2-raw-camera-move? raw-cmds))
(check-true "translated-includes-worker-gather"
            (ormap (lambda (c)
                     (and (sc2-raw-unit-command? c)
                          (= (sc2-raw-unit-command-ability-id c) 3666)
                          (= (sc2-raw-unit-command-target-unit-tag c) 200)))
                   raw-cmds))

;; Regression Tests for Bugs #8–#20 & Central SC2 Game Constants
(check-eqv "constants-queen-inject-energy" SC2-QUEEN-INJECT-ENERGY 25)
(check-eqv "constants-queen-tumor-surplus-energy" SC2-QUEEN-TUMOR-SURPLUS-ENERGY 45)
(check-eqv "constants-pylon-total-max-hp" SC2-PYLON-TOTAL-MAX-HP 400)
(check-eqv "constants-stalker-cost"
           (list (sc2-min-cost 'stalker) (sc2-gas-cost 'stalker) (sc2-supply-cost 'stalker))
           '(125 50 2))
(check-eqv "constants-barracks-techlab-alias"
           (unit-symbol->sc2-id 'barracks-techlab)
           (unit-symbol->sc2-id 'barracks-tech-lab))

(define (make-test-unit tag unit-type alliance x y
                        #:hp [hp 100.0]
                        #:energy [energy 0.0]
                        #:assigned [assigned 0]
                        #:ideal [ideal 0]
                        #:minerals [min-contents 1500]
                        #:vespene [vesp-contents 1500]
                        #:orders [orders '()]
                        #:add-on-tag [add-on-tag 0]
                        #:flying? [flying? #f])
  (sc2-unit 1 alliance tag unit-type (if (= alliance 1) 1 2)
            (sc2-point3d x y 8.0) 0.0 1.0 1.0 0 #f #f #f
            hp hp 0.0 0.0 energy 200.0
            (if (= alliance 3) min-contents 0)
            (if (or (= alliance 3) (memv unit-type '(88 61 20))) vesp-contents 0)
            flying? #f #f #t #f
            orders add-on-tag '() assigned ideal 0.0 0 0 0 0))

(define (make-test-obs loop minerals vespene units)
  (sc2-observation loop
                   (sc2-player-common 1 minerals vespene 44 24 8 16 0 4 0 3)
                   units '() '() #f '() '() '() '() '() '()))

;; Bug #8: Gas harvester near Extractor (`<= 3.5` tiles) or targeting Extractor is not re-ordered
(define bug8-obs
  (make-test-obs
   448 200 50
   (append
    (list (make-test-unit 1 86 1 32.0 32.0 #:assigned 14 #:ideal 16)
          ;; Ready Extractor (88) at (32.0, 25.0) needing 1 more worker (2/3)
          (make-test-unit 2 88 1 32.0 25.0 #:assigned 2 #:ideal 3)
          ;; Drone #10 right next to Extractor (dist 1.0 <= 3.5) returning gas to Hatchery
          (make-test-unit 10 104 1 32.0 26.0 #:orders (list (sc2-unit-order 299 #f 1 0.0)))
          ;; Drone #11 mining minerals closer to Extractor than other mineral drones (dist 5.0 > 3.5)
          (make-test-unit 11 104 1 28.0 28.0 #:orders (list (sc2-unit-order 298 #f 50 0.0)))
          (make-test-unit 50 341 3 24.0 28.0))
    ;; 12 more mineral drones farther away at (22.0, 32.0) so total workers = 14 (>= SC2-MIN-WORKERS-FOR-GAS)
    (for/list ([i (in-range 12)])
      (make-test-unit (+ 100 i) 104 1 22.0 32.0 #:orders (list (sc2-unit-order 298 #f 50 0.0)))))))
(define bug8-cmds (saturate-workers-and-gas-commands bug8-obs))
(check-true "bug8-picks-mineral-drone-11-not-gas-drone-10"
            (and (ormap (lambda (c)
                          (and (sc2-raw-unit-command? c)
                               (equal? (sc2-raw-unit-command-unit-tags c) '(11))
                               (= (sc2-raw-unit-command-target-unit-tag c) 2)))
                        bug8-cmds)
                 (not (ormap (lambda (c)
                               (and (sc2-raw-unit-command? c)
                                    (equal? (sc2-raw-unit-command-unit-tags c) '(10))))
                             bug8-cmds))))

;; Bug #9: Over-saturated main (20/16) transfers worker to under-saturated natural (2/16),
;; and gas float (gas > 600, minerals < 200) pulls worker from gas to minerals
(define bug9-obs
  (make-test-obs
   2000 120 750
   (list ;; Main Hatchery over-saturated (20/16)
         (make-test-unit 1 86 1 32.0 32.0 #:assigned 20 #:ideal 16)
         ;; Natural Hatchery under-saturated (2/16)
         (make-test-unit 2 86 1 60.0 32.0 #:assigned 2 #:ideal 16)
         ;; Extractor (3/3)
         (make-test-unit 3 88 1 32.0 25.0 #:assigned 3 #:ideal 3)
         ;; Drone #20 mining main minerals
         (make-test-unit 20 104 1 26.0 32.0 #:orders (list (sc2-unit-order 298 #f 50 0.0)))
         ;; Drone #21 mining gas at Extractor #3
         (make-test-unit 21 104 1 32.0 25.5 #:orders (list (sc2-unit-order 298 #f 3 0.0)))
         ;; Main mineral field #50 & Natural mineral field #51
         (make-test-unit 50 341 3 25.0 32.0)
         (make-test-unit 51 341 3 66.0 32.0))))
(define bug9-cmds (saturate-workers-and-gas-commands bug9-obs))
(check-true "bug9-transfers-worker-20-to-natural-mineral-51"
            (ormap (lambda (c)
                     (and (sc2-raw-unit-command? c)
                          (equal? (sc2-raw-unit-command-unit-tags c) '(20))
                          (= (sc2-raw-unit-command-target-unit-tag c) 51)))
                   bug9-cmds))
(check-true "bug9-pulls-gas-worker-21-to-minerals-on-high-gas-float"
            (ormap (lambda (c)
                     (and (sc2-raw-unit-command? c)
                          (equal? (sc2-raw-unit-command-unit-tags c) '(21))
                          (memv (sc2-raw-unit-command-target-unit-tag c) '(50 51))))
                   bug9-cmds))

;; Bug #10: Commanded builder worker is excluded from saturate-workers-and-gas-commands
(define bug10-commanded (mutable-set))
(define _bug10-build-cmds
  (translate-bot-actions->sc2-raw-commands '((build spawning-pool 36.0 36.0))
                                           decoded-obs
                                           #:commanded-workers bug10-commanded))
(check-true "bug10-builder-worker-recorded-in-commanded-set"
            (set-member? bug10-commanded 103))
(define bug10-sat-cmds
  (saturate-workers-and-gas-commands decoded-obs #:excluded-worker-tags bug10-commanded))
(check-true "bug10-saturate-does-not-overwrite-builder-worker-103"
            (not (ormap (lambda (c)
                          (and (sc2-raw-unit-command? c)
                               (member 103 (sc2-raw-unit-command-unit-tags c))))
                        bug10-sat-cmds)))

;; Bug #11: execute-spatial-maneuver does not trickle-feed < 8 combat units or overwrite micro
(define bug11-cmds
  (translate-bot-actions->sc2-raw-commands
   '((attack-unit 105 300)
     (execute-spatial-maneuver 140.0 140.0 130.0 130.0))
   decoded-obs))
(check-eqv "bug11-only-micro-command-emitted-no-trickle-override"
           (length bug11-cmds)
           1)
(check-eqv "bug11-micro-targets-enemy-unit-300"
           (sc2-raw-unit-command-target-unit-tag (car bug11-cmds))
           300)

;; Bug #14, #17, #19: MULE target mineral patch, WarpGate warp-in, and Target.None abilities
(define protoss-terran-obs
  (make-test-obs
   600 300 200
   (list ;; Orbital Command (132) at (32, 32)
         (make-test-unit 500 132 1 32.0 32.0 #:energy 100.0 #:assigned 16 #:ideal 16)
         ;; Pylon (60) at (38, 38)
         (make-test-unit 501 60 1 38.0 38.0)
         ;; WarpGate (133) at (40, 38)
         (make-test-unit 502 133 1 40.0 38.0)
         ;; Marine (48) at (42, 42)
         (make-test-unit 503 48 1 42.0 42.0)
         ;; Mineral Field (341) at (26, 32)
         (make-test-unit 600 341 3 26.0 32.0))))
(define pt-cmds
  (translate-bot-actions->sc2-raw-commands
   '((cast-spell 500 calldown-mule 504)
     (train stalker)
     (cast-spell 503 stimpack 503))
   protoss-terran-obs))
(check-true "bug14-mule-resolves-real-mineral-field-600"
            (ormap (lambda (c)
                     (and (sc2-raw-unit-command? c)
                          (= (sc2-raw-unit-command-ability-id c) 171)
                          (= (sc2-raw-unit-command-target-unit-tag c) 600)))
                   pt-cmds))
(check-true "bug17-warpgate-trains-stalker-via-warp-in-1414-at-point"
            (ormap (lambda (c)
                     (and (sc2-raw-unit-command? c)
                          (= (sc2-raw-unit-command-ability-id c) 1414)
                          (sc2-point2d? (sc2-raw-unit-command-target-pos c))
                          (= (sc2-raw-unit-command-target-unit-tag c) 0)))
                   pt-cmds))
(check-true "bug19-stimpack-uses-target-none"
            (ormap (lambda (c)
                     (and (sc2-raw-unit-command? c)
                          (memv (sc2-raw-unit-command-ability-id c) '(380 3675))
                          (not (sc2-raw-unit-command-target-pos c))
                          (= (sc2-raw-unit-command-target-unit-tag c) 0)))
                   pt-cmds))

;; Verify UI Control Groups, Camera Bookmarks, Reactor Multi-Slot Production,
;; Terran East (+X) Add-On Reservation, Depot Lower/Raise, and Combat Order Deduplication
(define cg-wire (encode-sc2-action (sc2-ui-control-group 4 2)))
(check-true "ui-control-group-wire-nonempty" (> (bytes-length cg-wire) 0))

(define terran-wall-obs
  (make-test-obs
   400 300 150
   (list ;; SCV (45) at (34, 34)
         (make-test-unit 701 45 1 34.0 34.0)
         (make-test-unit 702 45 1 35.0 34.0)
         ;; Raised Supply Depot (19) at (40, 40) - no enemy near -> should auto-lower (556)
         (make-test-unit 710 19 1 40.0 40.0)
         ;; Barracks (21) at (44, 44) with attached BarracksReactor (38, tag 721)
         (make-test-unit 720 21 1 44.0 44.0 #:add-on-tag 721)
         (make-test-unit 721 38 1 46.5 43.5)
         ;; Cloaked Banshee (55) at (60, 60)
         (make-test-unit 730 55 1 60.0 60.0 #:flying? #t))))

;; 1. East (+X) add-on slot of Barracks at (44, 44) is (46.5, 43.5); spiral candidates around (46.5, 43.5)
;;    must never place a building on top of the East add-on slot!
(define addon-cands
  (collect-spiral-candidates 46.5 43.5 (sc2-observation-units terran-wall-obs)
                             #:min-spacing 2.5 #:max-radius 8.0 #:step 2.0))
(check-true "terran-east-addon-slot-reserved"
            (for/and ([pt (in-list addon-cands)])
              (> (sqrt (+ (sqr (- (sc2-point2d-x pt) 46.5))
                          (sqr (- (sc2-point2d-y pt) 43.5))))
                 2.0)))

;; 2. Reactor Barracks (720) with 0 orders returns tag 720 twice so 2 Marines train in 1 step!
(define reactor-prod-tags
  (select-producer-tags-for-unit 'marine (sc2-observation-units terran-wall-obs)))
(check-eqv "reactor-barracks-two-open-slots"
           (count (lambda (t) (= t 720)) reactor-prod-tags)
           2)

;; 3. Translate batch with 2 Marines, 2 Pylons at same anchor, Control Group Set/Steal/Recall,
;;    Camera Bookmark Jump deduplication, and conflicting Banshee orders in same step
(define tw-cmds
  (translate-bot-actions->sc2-raw-commands
   '((train marine)
     (train marine)
     (build supply-depot 36.0 36.0)
     (build supply-depot 36.0 36.0)
     (control-group-set 5 (720))
     (control-group-steal 2 (730))
     (control-group-recall 5)
     (camera-bookmark-jump 1 32.0 32.0)
     (move-camera 32.5 32.5) ;; within 2.0 tiles -> deduplicated!
     (kite 730 55.0 55.0)
     (attack-pos (730) 90.0 90.0)) ;; conflicting lower-priority order on 730 -> suppressed!
   terran-wall-obs))

(check-eqv "reactor-barracks-emits-two-marine-trains-in-one-step"
           (count (lambda (c)
                    (and (sc2-raw-unit-command? c)
                         (= (sc2-raw-unit-command-ability-id c) 560)
                         (equal? (sc2-raw-unit-command-unit-tags c) '(720))))
                  tw-cmds)
           2)

(define depot-build-pts
  (for/list ([c (in-list tw-cmds)]
             #:when (and (sc2-raw-unit-command? c)
                         (= (sc2-raw-unit-command-ability-id c) 319)))
    (sc2-raw-unit-command-target-pos c)))
(check-eqv "two-depots-built-in-same-step" (length depot-build-pts) 2)
(check-true "two-depots-have-distinct-reserved-coords"
            (not (equal? (first depot-build-pts) (second depot-build-pts))))

(check-eqv "ui-control-group-commands-emitted"
           (count sc2-ui-control-group? tw-cmds)
           3)
(check-eqv "camera-moves-deduplicated-within-step"
           (count sc2-raw-camera-move? tw-cmds)
           1)
(check-eqv "banshee-730-receives-exactly-one-combat-order-per-step"
           (count (lambda (c)
                    (and (sc2-raw-unit-command? c)
                         (member 730 (sc2-raw-unit-command-unit-tags c))))
                  tw-cmds)
           1)
(check-true "raised-depot-710-auto-lowers-when-safe"
            (ormap (lambda (c)
                     (and (sc2-raw-unit-command? c)
                          (= (sc2-raw-unit-command-ability-id c) 556)
                          (equal? (sc2-raw-unit-command-unit-tags c) '(710))))
                   tw-cmds))

;; 4. Bug #21 & #22: `(morph lair)` / `(morph warp-gate)` producer resolution,
;;    Queen active Inject (251) / Tumor (1694) order protection, and Queen tumor creep anchoring
(define queen-morph-obs
  (make-test-obs
   1200 300 150
   (list ;; Idle Hatchery (86, tag 801) at (32, 32)
         (make-test-unit 801 86 1 32.0 32.0)
         ;; Idle Gateway (62, tag 802) at (38, 38)
         (make-test-unit 802 62 1 38.0 38.0)
         ;; Queen #810 actively executing Inject Larva (251) on Hatchery #801
         (make-test-unit 810 126 1 33.0 32.0 #:energy 50.0
                         #:orders (list (sc2-unit-order 251 #f 801 0.0)))
         ;; Idle Queen #811 at (32.5, 32.5)
         (make-test-unit 811 126 1 32.5 32.5 #:energy 50.0))))

(define qm-cmds
  (translate-bot-actions->sc2-raw-commands
   '((morph lair)
     (morph warp-gate)
     ;; Attempt to interrupt Queen #810 (already executing 251) with tumor, inject, and attack-pos:
     (cast-spell 810 spawn-creep-tumor 60.0 60.0)
     (inject-larva 810 801)
     (attack-pos (810) 90.0 90.0)
     ;; Idle Queen #811 spawns a creep tumor requested far away at (80.0, 80.0) -> anchored near (32.5, 32.5)!
     (cast-spell 811 spawn-creep-tumor 80.0 80.0))
   queen-morph-obs))

(check-true "morph-lair-resolves-idle-hatchery-801"
            (ormap (lambda (c)
                     (and (sc2-raw-unit-command? c)
                          (= (sc2-raw-unit-command-ability-id c) 1216)
                          (equal? (sc2-raw-unit-command-unit-tags c) '(801))))
                   qm-cmds))
(check-true "morph-warpgate-resolves-idle-gateway-802"
            (ormap (lambda (c)
                     (and (sc2-raw-unit-command? c)
                          (= (sc2-raw-unit-command-ability-id c) 1518)
                          (equal? (sc2-raw-unit-command-unit-tags c) '(802))))
                   qm-cmds))
(check-true "busy-injecting-queen-810-never-cancelled"
            (not (ormap (lambda (c)
                          (and (sc2-raw-unit-command? c)
                               (member 810 (sc2-raw-unit-command-unit-tags c))))
                        qm-cmds)))
(check-true "idle-queen-811-tumor-anchored-near-queen-on-creep"
            (ormap (lambda (c)
                     (and (sc2-raw-unit-command? c)
                          (= (sc2-raw-unit-command-ability-id c) 1694)
                          (equal? (sc2-raw-unit-command-unit-tags c) '(811))
                          (let ([pt (sc2-raw-unit-command-target-pos c)])
                            (and (sc2-point2d? pt)
                                 (<= (sqrt (+ (sqr (- (sc2-point2d-x pt) 32.5))
                                              (sqr (- (sc2-point2d-y pt) 32.5))))
                                     10.0)))))
                   qm-cmds))

;; -----------------------------------------------------------------------------
;; 5. Full Mock SC2_x64 RFC 6455 WebSocket Server + Match Loop Integration Test
;; -----------------------------------------------------------------------------
(printf "[5/5] Testing full RFC 6455 WebSocket + Protobuf match loop against mock SC2 server...\n")

(define (server-send-ws-frame! out opcode payload #:fin? [fin? #t])
  (define len (bytes-length payload))
  (define b0 (bitwise-ior (if fin? #x80 0) (bitwise-and opcode #x0F)))
  (define hdr
    (cond
      [(< len 126) (bytes b0 len)]
      [(<= len 65535) (bytes-append (bytes b0 126) (integer->integer-bytes len 2 #f #t))]
      [else (bytes-append (bytes b0 127) (integer->integer-bytes len 8 #f #t))]))
  (write-bytes hdr out)
  (write-bytes payload out)
  (flush-output out))

(define (server-recv-ws-frame! in)
  (define hdr2 (read-bytes 2 in))
  (if (eof-object? hdr2)
      (values eof 0 #"" #f)
      (let* ([b0 (bytes-ref hdr2 0)]
             [b1 (bytes-ref hdr2 1)]
             [opcode (bitwise-and b0 #x0F)]
             [masked? (not (zero? (bitwise-and b1 #x80)))]
             [len7 (bitwise-and b1 #x7F)]
             [plen
              (cond
                [(< len7 126) len7]
                [(= len7 126) (integer-bytes->integer (read-bytes 2 in) #f #t)]
                [else (integer-bytes->integer (read-bytes 8 in) #f #t)])]
             [mkey (if masked? (read-bytes 4 in) #f)]
             [raw (read-bytes plen in)]
             [unmasked (if masked? (mask-ws-payload raw mkey) raw)])
        (values opcode plen unmasked masked?))))

(define listener (tcp-listen 0 4 #t "127.0.0.1"))
(define-values (_local-host mock-port _remote-host _remote-port)
  (tcp-addresses listener #t))

(define server-pong-received? #f)
(define server-masked-frames-count 0)
(define server-actions-received 0)
(define server-steps-received 0)

(define server-thread
  (thread
   (lambda ()
     (define-values (in out) (tcp-accept listener))
     ;; 1. Read HTTP/1.1 Upgrade request headers
     (define req-line (read-line in 'any))
     (define ws-key #f)
     (let hdr-loop ()
       (define line (read-line in 'any))
       (unless (or (eof-object? line) (string=? (string-trim line) ""))
         (when (string-prefix? (string-downcase line) "sec-websocket-key:")
           (set! ws-key (string-trim (substring line 18))))
         (hdr-loop)))
     (define accept-key (compute-ws-accept-key (or ws-key "dGhlIHNhbXBsZSBub25jZQ==")))
     (define resp-hdr
       (string-append
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Accept: " accept-key "\r\n"
        "\r\n"))
     (write-bytes (string->bytes/utf-8 resp-hdr) out)
     (flush-output out)

     ;; 2. Serve SC2 Protobuf RPC loop
     (define sim-loop 0)
     (let rpc-loop ()
       (define-values (opcode _plen payload masked?) (server-recv-ws-frame! in))
       (cond
         [(or (eof-object? opcode) (= opcode 8))
          (close-input-port in)
          (close-output-port out)]
         [(= opcode 10) ;; Client answered our Ping with Pong!
          (when masked? (set! server-masked-frames-count (add1 server-masked-frames-count)))
          (set! server-pong-received? (equal? payload #"sc2-keepalive"))
          (rpc-loop)]
         [(= opcode 2)
          (when masked? (set! server-masked-frames-count (add1 server-masked-frames-count)))
          (define req-fields (decode-protobuf-message payload))
          (define req-id
            (let ([ p (assoc 97 req-fields) ]) (if p (third p) #f)))
          (define id-tag-bytes (if req-id (encode-uint32 97 req-id) #""))
          (cond
            ;; CreateGame (1)
            [(assoc 1 req-fields)
             (define resp
               (bytes-append (encode-submessage-field 1 #"")
                             id-tag-bytes
                             (encode-int32 99 2)))
             (server-send-ws-frame! out 2 resp)
             (rpc-loop)]
            ;; JoinGame (2)
            [(assoc 2 req-fields)
             (define resp
               (bytes-append (encode-submessage-field 2 (encode-uint32 1 1))
                             id-tag-bytes
                             (encode-int32 99 3)))
             (server-send-ws-frame! out 2 resp)
             (rpc-loop)]
            ;; GameInfo (9)
            [(assoc 9 req-fields)
             ;; Send a WebSocket Ping (opcode 9) first to verify automatic client Pong!
             (server-send-ws-frame! out 9 #"sc2-keepalive")
             (define start-raw
               (bytes-append
                (encode-submessage-field 1 (bytes-append (encode-int32 1 176) (encode-int32 2 176)))
                (encode-submessage-field 6 (encode-point2d 144.0 144.0))))
             (define gi-body
               (bytes-append
                (encode-string-field 1 "Simple64")
                (encode-submessage-field 3 (bytes-append (encode-uint32 1 1)
                                                         (encode-int32 2 1)
                                                         (encode-int32 3 4)
                                                         (encode-int32 4 2)))
                (encode-submessage-field 4 start-raw)))
             (define resp
               (bytes-append (encode-submessage-field 9 gi-body)
                             id-tag-bytes
                             (encode-int32 99 3)))
             (server-send-ws-frame! out 2 resp)
             (rpc-loop)]
            ;; Data (13)
            [(assoc 13 req-fields)
             (define data-body
               (bytes-append
                (encode-submessage-field 2 (bytes-append (encode-uint32 1 105)
                                                         (encode-string-field 2 "Zergling")))))
             (define resp
               (bytes-append (encode-submessage-field 13 data-body)
                             id-tag-bytes
                             (encode-int32 99 3)))
             (server-send-ws-frame! out 2 resp)
             (rpc-loop)]
            ;; Observation (10)
            [(assoc 10 req-fields)
             (define victory? (>= sim-loop 16))
             (define obs-resp
               (bytes-append
                (encode-synthetic-observation-response
                 sim-loop
                 (+ 200 (* sim-loop 15))
                 (+ 50 (* sim-loop 5))
                 16
                 22
                 synth-units
                 #:result (if victory? 1 #f)
                 #:status (if victory? 5 3))
                id-tag-bytes))
             (server-send-ws-frame! out 2 obs-resp)
             (rpc-loop)]
            ;; Action (11)
            [(assoc 11 req-fields)
             (set! server-actions-received (add1 server-actions-received))
             (define resp
               (bytes-append (encode-submessage-field 11 (encode-int32 1 1))
                             id-tag-bytes
                             (encode-int32 99 3)))
             (server-send-ws-frame! out 2 resp)
             (rpc-loop)]
            ;; Step (12)
            [(assoc 12 req-fields)
             (set! server-steps-received (add1 server-steps-received))
             (set! sim-loop (+ sim-loop 4))
             (define resp
               (bytes-append (encode-submessage-field 12 (encode-uint32 1 sim-loop))
                             id-tag-bytes
                             (encode-int32 99 3)))
             (server-send-ws-frame! out 2 resp)
             (rpc-loop)]
            ;; LeaveGame (5)
            [(assoc 5 req-fields)
             (define resp
               (bytes-append (encode-submessage-field 5 #"")
                             id-tag-bytes
                             (encode-int32 99 5)))
             (server-send-ws-frame! out 2 resp)
             (rpc-loop)]
            [else
             (server-send-ws-frame! out 2 (bytes-append id-tag-bytes (encode-int32 99 3)))
             (rpc-loop)])])))))

(define match-summary
  (run-racket-sc2-match #:host "127.0.0.1"
                        #:game-port mock-port
                        #:start-port 6000
                        #:bot-name "Mothman"
                        #:bot-rkt-path "bots/Mothman.rkt"
                        #:our-race "Random"
                        #:computer-opponent? #t
                        #:computer-race "Protoss"
                        #:computer-difficulty "VeryHard"
                        #:map-name "Simple64"
                        #:max-loops 64
                        #:step-size 4))

(thread-wait server-thread)
(tcp-close listener)

(check-eqv "match-summary-status" (hash-ref match-summary 'status) "MATCH_COMPLETED")
(check-eqv "match-summary-result" (hash-ref match-summary 'result) "Victory")
(check-eqv "match-summary-actual-race" (hash-ref match-summary 'actual_race_played) "Zerg")
(check-eqv "match-summary-steps" (hash-ref match-summary 'steps_executed) 4)
(check-true "match-summary-commands-sent" (> (hash-ref match-summary 'commands_sent) 0))
(check-true "server-verified-client-pong" server-pong-received?)
(check-true "server-verified-masked-frames" (>= server-masked-frames-count 10))
(check-eqv "server-steps-received" server-steps-received 4)
(check-true "server-actions-received" (>= server-actions-received 4))

;; Also test CLI `--dry-run`
(define dry-run-summary
  (with-output-to-string
    (lambda ()
      (run-racket-sc2-cli #("--dry-run" "--BotName" "Mothman-T")))))
(check-true "cli-dry-run-json-ok" (string-contains? dry-run-summary "DRY_RUN_OK"))

;; Test map resolution and auto-launched `--ComputerOpponent` without `--GamePort`
(check-true "resolve-sc2-map-path-suffix"
            (string-suffix? (string-downcase (resolve-sc2-map-path "Simple64")) ".sc2map"))
(check-true "pick-free-local-port-valid"
            (> (pick-free-local-port) 1024))
(define auto-summary
  (run-racket-sc2-match #:game-port #f
                        #:bot-name "Mothman-R"
                        #:bot-rkt-path "bots/Mothman-R.rkt"
                        #:our-race "Random"
                        #:computer-opponent? #t
                        #:computer-race "Protoss"
                        #:computer-difficulty "VeryHard"
                        #:map-name "Simple64"
                        #:max-loops 32
                        #:step-size 4))
(check-eqv "auto-launch-status" (hash-ref auto-summary 'status) "MATCH_COMPLETED")
(check-eqv "auto-launch-loops" (hash-ref auto-summary 'game_loops) 32)
(check-true "auto-launch-commands" (> (hash-ref auto-summary 'commands_sent) 0))

(printf "-----------------------------------------------------------------\n")
(printf "Pure-Racket SC2 Protobuf + WebSocket Checks: ~a/~a passed (~a failed)\n"
        (- total-checks failed-checks)
        total-checks
        failed-checks)
(printf "=================================================================\n")

(when (> failed-checks 0)
  (exit 1))
