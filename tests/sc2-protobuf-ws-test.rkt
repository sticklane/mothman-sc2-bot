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
         (prefix-in pl: "../lib/sc2-placement.rkt")
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

(define sample-multi-drone-obs
  (sc2-response-observation
   (decode-sc2-response
    (encode-synthetic-observation-response
     224 350 100 16 22
     (append synth-units
             (list (encode-synthetic-unit 106 104 1 31.0 26.0 40.0 0.0)
                   (encode-synthetic-unit 107 104 1 35.0 35.0 40.0 0.0)
                   (encode-synthetic-unit 108 104 1 28.0 31.0 40.0 0.0)))))))

(define raw-cmds
  (append (translate-bot-actions->sc2-raw-commands sample-bot-actions sample-multi-drone-obs)
          (saturate-workers-and-gas-commands sample-multi-drone-obs)))
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
                        #:buffs [buffs '()]
                        #:flying? [flying? #f]
                        #:weapon-cooldown [weapon-cooldown 0.0])
  (sc2-unit 1 alliance tag unit-type (if (= alliance 1) 1 2)
            (sc2-point3d x y 8.0) 0.0 1.0 1.0 0 #f #f #f
            hp hp 0.0 0.0 energy 200.0
            (if (= alliance 3) min-contents 0)
            (if (or (= alliance 3) (memv unit-type '(88 61 20))) vesp-contents 0)
            flying? #f #f #t #f
            orders add-on-tag buffs assigned ideal weapon-cooldown 0 0 0 0))

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
;; (decoded-obs already has completed SpawningPool 101, so building EvolutionChamber 90 exercises worker exclusion
;;  while verifying duplicate singleton SpawningPool wire builds are blocked!)
(define bug10-dup-pool-cmds
  (translate-bot-actions->sc2-raw-commands '((build spawning-pool 36.0 36.0))
                                           decoded-obs))
(check-true "bug10-duplicate-singleton-spawning-pool-blocked"
            (null? bug10-dup-pool-cmds))
(define bug10-commanded (mutable-set))
(define _bug10-build-cmds
  (translate-bot-actions->sc2-raw-commands '((build evolution-chamber 36.0 36.0))
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

(check-eqv "ui-control-group-raw-wire-noop"
           (count sc2-ui-control-group? tw-cmds)
           0)
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

;; 6. Unseen Units (Lurker Den 1163 Drone Build, Seismic Spines 3710, Carrier Build Interceptors 1042),
;;    Auto-Unsiege/Unburrow (SiegeTankSieged 32 -> 390, LurkerMPBurrowed 503 -> 2110, WidowMineBurrowed 500 -> 2097),
;;    and Section 13 Multi-Tag Command Coalescing on the Wire
(define unseen-units-obs
  (make-test-obs
   2400 400 300
   (list ;; Hatchery (86, tag 900) at (32, 32)
         (make-test-unit 900 86 1 32.0 32.0)
         ;; Idle Drone (104, tag 901) at (34, 32)
         (make-test-unit 901 104 1 34.0 32.0)
         ;; Completed LurkerDenMP (504, tag 902) at (36, 34)
         (make-test-unit 902 504 1 36.0 34.0)
         ;; Carrier (79, tag 903) at (50, 50)
         (make-test-unit 903 79 1 50.0 50.0 #:flying? #t)
         ;; SiegeTankSieged (32, tag 904) at (40, 40) - no enemy near -> auto-unsiege (390)
         (make-test-unit 904 32 1 40.0 40.0)
         ;; LurkerMPBurrowed (503, tag 905) at (42, 40) - no enemy near -> auto-unburrow (2110)
         (make-test-unit 905 503 1 42.0 40.0)
         ;; WidowMineBurrowed (500, tag 906) at (44, 40) - no enemy near -> auto-unburrow (2097)
         (make-test-unit 906 500 1 44.0 40.0)
         ;; 4 Marines (48, tags 911..914) at (60, 60)
         (make-test-unit 911 48 1 60.0 60.0)
         (make-test-unit 912 48 1 60.5 60.0)
         (make-test-unit 913 48 1 61.0 60.0)
         (make-test-unit 914 48 1 61.5 60.0)
         ;; Enemy Roach (110, tag 999) far away at (120, 120)
         (make-test-unit 999 110 4 120.0 120.0))))

(define unseen-lurker-build-obs
  (make-test-obs
   2400 400 300
   (list (make-test-unit 900 86 1 32.0 32.0)
         (make-test-unit 901 104 1 34.0 32.0)
         (make-test-unit 902 91 1 36.0 34.0))))

(define uu-build-cmds
  (translate-bot-actions->sc2-raw-commands
   '((build lurker-den 37.0 35.0))
   unseen-lurker-build-obs))

(check-true "lurker-den-built-by-drone-901-at-point-1163"
            (ormap (lambda (c)
                     (and (sc2-raw-unit-command? c)
                          (= (sc2-raw-unit-command-ability-id c) 1163)
                          (equal? (sc2-raw-unit-command-unit-tags c) '(901))
                          (sc2-point2d? (sc2-raw-unit-command-target-pos c))))
                   uu-build-cmds))

(define uu-cmds
  (translate-bot-actions->sc2-raw-commands
   '((research seismic-spines)
     (cast-spell 903 build-interceptors 903)
     (attack-unit 911 999)
     (attack-unit 912 999)
     (attack-unit 913 999)
     (attack-unit 914 999))
   unseen-units-obs))

(define uu-dup-lurker-cmds
  (translate-bot-actions->sc2-raw-commands
   '((build lurker-den 37.0 35.0))
   unseen-units-obs))
(check-true "duplicate-singleton-lurker-den-blocked"
            (not (ormap (lambda (c)
                          (and (sc2-raw-unit-command? c)
                               (= (sc2-raw-unit-command-ability-id c) 1163)))
                        uu-dup-lurker-cmds)))

(check-true "seismic-spines-researched-at-lurker-den-902-ability-3710"
            (ormap (lambda (c)
                     (and (sc2-raw-unit-command? c)
                          (= (sc2-raw-unit-command-ability-id c) 3710)
                          (equal? (sc2-raw-unit-command-unit-tags c) '(902))))
                   uu-cmds))
(check-true "carrier-903-builds-interceptors-1042-target-none"
            (ormap (lambda (c)
                     (and (sc2-raw-unit-command? c)
                          (= (sc2-raw-unit-command-ability-id c) 1042)
                          (equal? (sc2-raw-unit-command-unit-tags c) '(903))
                          (not (sc2-raw-unit-command-target-pos c))
                          (= (sc2-raw-unit-command-target-unit-tag c) 0)))
                   uu-cmds))
(check-true "siege-tank-sieged-32-auto-unsieges-390-when-clear"
            (ormap (lambda (c)
                     (and (sc2-raw-unit-command? c)
                          (= (sc2-raw-unit-command-ability-id c) 390)
                          (equal? (sc2-raw-unit-command-unit-tags c) '(904))))
                   uu-cmds))
(check-true "lurker-burrowed-503-auto-unburrows-2110-when-clear"
            (ormap (lambda (c)
                     (and (sc2-raw-unit-command? c)
                          (= (sc2-raw-unit-command-ability-id c) 2110)
                          (equal? (sc2-raw-unit-command-unit-tags c) '(905))))
                   uu-cmds))
(check-true "widow-mine-burrowed-500-auto-unburrows-2097-when-clear"
            (ormap (lambda (c)
                     (and (sc2-raw-unit-command? c)
                          (= (sc2-raw-unit-command-ability-id c) 2097)
                          (equal? (sc2-raw-unit-command-unit-tags c) '(906))))
                   uu-cmds))
(check-true "four-marine-attack-unit-commands-coalesced-into-single-multi-tag-wire-cmd"
            (ormap (lambda (c)
                     (and (sc2-raw-unit-command? c)
                          (memv (sc2-raw-unit-command-ability-id c) '(23 3674))
                          (= (sc2-raw-unit-command-target-unit-tag c) 999)
                          (equal? (sc2-raw-unit-command-unit-tags c) '(911 912 913 914))))
                   uu-cmds))

;; 10. Oracle Stasis Ward (2505), Pulsar Beam (2375/2376), Stasis-Frozen Worker Accounting (buff 57),
;;     Mineral-Walk HARVEST_GATHER (3666), and Worker-Drill Stack Attack
(check-eqv "ability-id-pulsar-beam" (ability-symbol->sc2-id 'pulsar-beam) 2375)
(check-eqv "ability-id-pulsar-beam-off" (ability-symbol->sc2-id 'pulsar-beam-off) 2376)
(check-eqv "ability-id-stasis-ward" (ability-symbol->sc2-id 'stasis-ward) 2505)
(check-eqv "buff-id-oracle-stasis-trap-target" (buff-id->symbol 57) 'oracle-stasis-trap-target)

(define stasis-drill-obs
  (make-test-obs
   1600 400 200
   (list ;; Nexus (59, tag 950) at (32, 32) with 16 assigned harvesters
         (make-test-unit 950 59 1 32.0 32.0 #:assigned 16 #:ideal 16)
         ;; Probe #951 (84) at (34, 32) - unfrozen
         (make-test-unit 951 84 1 34.0 32.0)
         ;; Probe #952 (84) at (59.5, 60.0) - already within 1.5 tiles of drill target (60, 60)
         (make-test-unit 952 84 1 59.5 60.0)
         ;; Probe #953 (84) at (35, 32) - frozen by Oracle Stasis Trap (buff 57)
         (make-test-unit 953 84 1 35.0 32.0 #:buffs '(57))
         ;; Friendly Oracle #960 (495) at (50, 50)
         (make-test-unit 960 495 1 50.0 50.0 #:flying? #t #:energy 75.0)
         ;; Neutral Mineral Field #9500 (341) at (36, 40)
         (make-test-unit 9500 341 3 36.0 40.0)
         ;; Enemy Roach #999 (110) at (60, 60)
         (make-test-unit 999 110 4 60.0 60.0))))

(define stasis-rt-hash (sc2-observation->runtime-obs-hash stasis-drill-obs))
(check-eqv "stasis-frozen-worker-count-detected"
           (hash-ref stasis-rt-hash 'stasis-frozen-worker-count 0)
           1)
(check-eqv "stasis-frozen-unit-ids-detected"
           (hash-ref stasis-rt-hash 'stasis-frozen-unit-ids '())
           '(953))
(check-eqv "raw-mineral-harvesters-preserved"
           (hash-ref stasis-rt-hash 'raw-mineral-harvesters 0)
           16)
(check-eqv "mineral-harvesters-deducts-stasis-frozen-workers"
           (hash-ref stasis-rt-hash 'mineral-harvesters 0)
           15)

(define sd-cmds
  (translate-bot-actions->sc2-raw-commands
   '((mineral-walk 951 36.0 40.0)
     (worker-drill-stack-attack (951 952) 9500 999 60.0 60.0)
     (cast-spell 960 stasis-ward 55.0 55.0)
     (cast-spell 960 pulsar-beam 999))
   stasis-drill-obs))

(check-true "mineral-walk-targets-mineral-patch-3666"
            (ormap (lambda (c)
                     (and (sc2-raw-unit-command? c)
                          (= (sc2-raw-unit-command-ability-id c) 3666)
                          (= (sc2-raw-unit-command-target-unit-tag c) 9500)
                          (member 951 (sc2-raw-unit-command-unit-tags c))))
                   sd-cmds))
(check-true "worker-drill-stack-attack-strikes-when-within-1.5-tiles"
            (ormap (lambda (c)
                     (and (sc2-raw-unit-command? c)
                          (= (sc2-raw-unit-command-ability-id c) 23)
                          (= (sc2-raw-unit-command-target-unit-tag c) 999)
                          (equal? (sc2-raw-unit-command-unit-tags c) '(952))))
                   sd-cmds))
(check-true "oracle-stasis-ward-2505-point-target"
            (ormap (lambda (c)
                     (and (sc2-raw-unit-command? c)
                          (= (sc2-raw-unit-command-ability-id c) 2505)
                          (equal? (sc2-raw-unit-command-unit-tags c) '(960))
                          (sc2-point2d? (sc2-raw-unit-command-target-pos c))))
                   sd-cmds))
(check-true "oracle-pulsar-beam-2375-no-target-toggle"
            (ormap (lambda (c)
                     (and (sc2-raw-unit-command? c)
                          (= (sc2-raw-unit-command-ability-id c) 2375)
                          (equal? (sc2-raw-unit-command-unit-tags c) '(960))
                          (not (sc2-raw-unit-command-target-pos c))
                          (= (sc2-raw-unit-command-target-unit-tag c) 0)))
                   sd-cmds))

;; Dynamic Gas Pull + Automatic Hysteresis Re-Saturation (no worker ping-pong!)
(define (make-hysteresis-gas-obs loop mins vesp)
  (make-test-obs
   loop mins vesp
   (append
    (list (make-test-unit 1 86 1 32.0 32.0 #:assigned 12 #:ideal 16)
          (make-test-unit 2 88 1 32.0 25.0 #:assigned 2 #:ideal 3)
          (make-test-unit 50 341 3 32.0 38.0 #:minerals 1500)
          ;; 2 gas Drones targeting Extractor #2
          (make-test-unit 201 104 1 32.0 26.0 #:orders (list (sc2-unit-order 1183 #f 2 0.0)))
          (make-test-unit 202 104 1 32.5 26.0 #:orders (list (sc2-unit-order 1183 #f 2 0.0))))
    ;; 12 mineral Drones targeting Mineral #50
    (for/list ([i (in-range 12)])
      (make-test-unit (+ 210 i) 104 1 (+ 29.0 (* 0.4 i)) 35.0
                      #:orders (list (sc2-unit-order 1183 #f 50 0.0)))))))

(define hyst-pull-cmds (saturate-workers-and-gas-commands (make-hysteresis-gas-obs 6000 110 320)))
(check-true "gas-pull-fires-at-320G-110M"
            (ormap (lambda (c)
                     (and (sc2-raw-unit-command? c)
                          (= (sc2-raw-unit-command-target-unit-tag c) 50)
                          (or (member 201 (sc2-raw-unit-command-unit-tags c))
                              (member 202 (sc2-raw-unit-command-unit-tags c)))))
                   hyst-pull-cmds))
(define hyst-deadband-cmds (saturate-workers-and-gas-commands (make-hysteresis-gas-obs 6016 180 240)))
(check-true "gas-hysteresis-deadband-prevents-pingpong-at-240G-180M"
            (not (ormap (lambda (c)
                          (and (sc2-raw-unit-command? c)
                               (= (sc2-raw-unit-command-target-unit-tag c) 2)))
                        hyst-deadband-cmds)))
(define hyst-resat-cmds (saturate-workers-and-gas-commands (make-hysteresis-gas-obs 6032 180 175)))
(check-true "gas-auto-resaturates-when-vespene-drops-below-200G"
            (ormap (lambda (c)
                     (and (sc2-raw-unit-command? c)
                          (= (sc2-raw-unit-command-target-unit-tag c) 2)))
                   hyst-resat-cmds))

;; P0-2 Regression: Cohesive Midgame Armies (No 6-10 Way Scatter), Hold/Suppress Posture
;;                  Preservation, and Strictly Verified Endgame Building-Cleanup Sweeps
(define p02-ginfo
  (sc2-game-info "P02-CohesiveMidgame-Map" "" '() (cons 176 176) (list 8 8 168 168)
                 (list (sc2-point2d 32.5 32.5) (sc2-point2d 143.5 143.5))
                 #f #f #f))

(define p02-map-minerals
  (list (make-test-unit 9801 341 3 26.0 32.5)
        (make-test-unit 9802 341 3 56.0 32.5)
        (make-test-unit 9803 341 3 32.5 68.0)
        (make-test-unit 9804 341 3 118.0 143.5)
        (make-test-unit 9805 341 3 149.0 143.5)))

(define (p02-attack-point-cmds cmds)
  (filter (lambda (c)
            (and (sc2-raw-unit-command? c)
                 (= (sc2-raw-unit-command-ability-id c) 23)
                 (sc2-point2d? (sc2-raw-unit-command-target-pos c))))
          cmds))

(define (p02-distinct-attack-pts cmds)
  (remove-duplicates
   (for/list ([c (in-list (p02-attack-point-cmds cmds))])
     (define p (sc2-raw-unit-command-target-pos c))
     (cons (sc2-point2d-x p) (sc2-point2d-y p)))))

(define (p02-has-corner-scan? cmds)
  (ormap (lambda (c)
           (and (sc2-raw-unit-command? c)
                (= (sc2-raw-unit-command-ability-id c) 399)))
         cmds))

;; Reset match state cleanly at loop 4 and populate base clusters
(void
 (translate-bot-actions->sc2-raw-commands
  '()
  (make-test-obs
   4 50 0
   (cons (make-test-unit 9001 132 1 32.5 32.5 #:energy 50.0)
         p02-map-minerals))
  #:game-info p02-ginfo
  #:enemy-base '(143.5 143.5)))

;; 1. Midgame 20-supply army (10 Stalkers = 20 supply) at loop 5500 AND loop 8000 with EMPTY enemy-units,
;;    normal mineral fields, and sc2-game-info -> MUST stay cohesive (1 unified target, NO 6-10 way scatter,
;;    NO premature Orbital Command corner scan!).
(define p02-midgame-20sup-obs-5500
  (make-test-obs
   5500 350 150
   (append
    (list (make-test-unit 9001 132 1 32.5 32.5 #:energy 110.0))
    (for/list ([i (in-range 10)])
      (make-test-unit (+ 9100 i) 74 1 (+ 38.0 (* 0.5 i)) 34.0))
    p02-map-minerals)))

(define p02-midgame-sp-cmds
  (translate-bot-actions->sc2-raw-commands
   '((execute-spatial-maneuver multiprong-rotate-and-pin 143.5 143.5))
   p02-midgame-20sup-obs-5500
   #:game-info p02-ginfo
   #:enemy-base '(143.5 143.5)))

(check-eqv "p02-midgame-20sup-spatial-maneuver-single-cohesive-target"
           (length (p02-distinct-attack-pts p02-midgame-sp-cmds))
           1)
(check-true "p02-midgame-20sup-spatial-maneuver-unifies-all-10-stalkers"
            (ormap (lambda (c)
                     (and (= (length (sc2-raw-unit-command-unit-tags c)) 10)
                          (let ([p (sc2-raw-unit-command-target-pos c)])
                            (and (= (sc2-point2d-x p) 143.5)
                                 (= (sc2-point2d-y p) 143.5)))))
                   (p02-attack-point-cmds p02-midgame-sp-cmds)))
(check-true "p02-midgame-20sup-no-premature-corner-scan"
            (not (p02-has-corner-scan? p02-midgame-sp-cmds)))

;; 2. Midgame >= 6000 loops (loop 7200) idle-combat fallback with empty enemy-units & 20-supply army
;;    MUST also stay cohesive (single ball, NO fan-out scatter, NO premature corner scan!).
(define p02-midgame-20sup-obs-7200
  (make-test-obs
   7200 350 150
   (append
    (list (make-test-unit 9001 132 1 32.5 32.5 #:energy 110.0))
    (for/list ([i (in-range 10)])
      (make-test-unit (+ 9100 i) 74 1 (+ 38.0 (* 0.5 i)) 34.0))
    p02-map-minerals)))

(define p02-midgame-idle-cmds
  (translate-bot-actions->sc2-raw-commands
   '()
   p02-midgame-20sup-obs-7200
   #:game-info p02-ginfo
   #:enemy-base '(143.5 143.5)))

(check-eqv "p02-midgame-7200-idle-fallback-single-cohesive-target"
           (length (p02-distinct-attack-pts p02-midgame-idle-cmds))
           1)
(check-true "p02-midgame-7200-idle-fallback-unifies-all-10-stalkers"
            (ormap (lambda (c) (= (length (sc2-raw-unit-command-unit-tags c)) 10))
                   (p02-attack-point-cmds p02-midgame-idle-cmds)))
(check-true "p02-midgame-7200-no-premature-corner-scan"
            (not (p02-has-corner-scan? p02-midgame-idle-cmds)))

;; 3. Midgame small squad (4 Marines at loop 7300 >= 6000, normal map, enemy main not cleared)
;;    MUST NOT stream across the map (no 4-unit conga line of death!).
(define p02-small-squad-obs
  (make-test-obs
   7300 200 50
   (append
    (list (make-test-unit 9001 132 1 32.5 32.5 #:energy 50.0))
    (for/list ([i (in-range 4)])
      (make-test-unit (+ 9150 i) 48 1 (+ 34.0 (* 0.5 i)) 34.0))
    p02-map-minerals)))
(define p02-small-squad-cmds
  (translate-bot-actions->sc2-raw-commands
   '((execute-spatial-maneuver multiprong-rotate-and-pin 143.5 143.5))
   p02-small-squad-obs
   #:game-info p02-ginfo
   #:enemy-base '(143.5 143.5)))
(check-true "p02-midgame-4-marine-squad-never-pushes-cross-map"
            (not (ormap (lambda (c)
                          (let ([p (sc2-raw-unit-command-target-pos c)])
                            (or (> (sc2-point2d-x p) 80.0)
                                (> (sc2-point2d-y p) 80.0))))
                        (p02-attack-point-cmds p02-small-squad-cmds))))

;; 4. Layer 3/4 hold / intercept / suppress-attack posture NEVER overridden by wire layer
;;    (including across the 28-frame spatial-maneuver refractory cooldown!).
(define p02-hold-obs-7500
  (make-test-obs
   7500 350 150
   (append
    (list (make-test-unit 9001 132 1 32.5 32.5 #:energy 110.0))
    (for/list ([i (in-range 10)])
      (make-test-unit (+ 9100 i) 74 1 (+ 36.0 (* 0.5 i)) 34.0))
    p02-map-minerals)))
(define p02-intercept-cmds
  (translate-bot-actions->sc2-raw-commands
   '((execute-spatial-maneuver pre-rotate-intercept-incoming-threat 56.5 32.5))
   p02-hold-obs-7500
   #:game-info p02-ginfo
   #:enemy-base '(143.5 143.5)))
(check-eqv "p02-midgame-pre-rotate-intercept-single-defensive-target"
           (length (p02-distinct-attack-pts p02-intercept-cmds))
           1)
(check-true "p02-midgame-pre-rotate-intercept-respects-natural-rally"
            (ormap (lambda (c)
                     (let ([p (sc2-raw-unit-command-target-pos c)])
                       (and (= (sc2-point2d-x p) 56.5)
                            (= (sc2-point2d-y p) 32.5)
                            (= (length (sc2-raw-unit-command-unit-tags c)) 10))))
                   (p02-attack-point-cmds p02-intercept-cmds)))

;; Next step inside 28-loop refractory cooldown (loop 7516, raw-actions = '(), units idle at natural):
;; wire idle fallback MUST keep them holding cohesively at (56.5, 32.5) rather than marching cross-map!
(define p02-sticky-hold-obs-7516
  (make-test-obs
   7516 350 150
   (append
    (list (make-test-unit 9001 132 1 32.5 32.5 #:energy 110.0))
    (for/list ([i (in-range 10)])
      (make-test-unit (+ 9100 i) 74 1 (+ 55.0 (* 0.3 i)) 32.5))
    p02-map-minerals)))
(define p02-sticky-hold-cmds
  (translate-bot-actions->sc2-raw-commands
   '()
   p02-sticky-hold-obs-7516
   #:game-info p02-ginfo
   #:enemy-base '(143.5 143.5)))
(check-true "p02-sticky-hold-preserves-natural-hold-during-cooldown"
            (null? (p02-attack-point-cmds p02-sticky-hold-cmds)))

;; Explicit #:suppress-attack? #t MUST override even an offensive spatial maneuver and keep units near home!
(define p02-suppress-cmds
  (translate-bot-actions->sc2-raw-commands
   '((execute-spatial-maneuver multiprong-rotate-and-pin 143.5 143.5))
   p02-midgame-20sup-obs-7200
   #:game-info p02-ginfo
   #:enemy-base '(143.5 143.5)
   #:suppress-attack? #t))
(check-true "p02-explicit-suppress-attack-never-marches-to-enemy-base"
            (not (ormap (lambda (c)
                          (let ([p (sc2-raw-unit-command-target-pos c)])
                            (or (> (sc2-point2d-x p) 70.0)
                                (> (sc2-point2d-y p) 70.0))))
                        (p02-attack-point-cmds p02-suppress-cmds))))

;; Explicit crisis posture-transition MUST keep idle 20-supply army holding near home (never cross-map)
(define p02-crisis-hold-cmds
  (translate-bot-actions->sc2-raw-commands
   '((posture-transition CrisisEarlyBust))
   p02-midgame-20sup-obs-7200
   #:game-info p02-ginfo
   #:enemy-base '(143.5 143.5)))
(check-true "p02-crisis-posture-prevents-cross-map-idle-push"
            (not (ormap (lambda (c)
                          (let ([p (sc2-raw-unit-command-target-pos c)])
                            (or (> (sc2-point2d-x p) 70.0)
                                (> (sc2-point2d-y p) 70.0))))
                        (p02-attack-point-cmds p02-crisis-hold-cmds))))

;; Base defense STILL overrides hold/suppress posture when an enemy attacks inside SC2-BASE-DEFENSE-RADIUS!
(define p02-base-threat-obs
  (make-test-obs
   7600 350 150
   (append
    (list (make-test-unit 9001 132 1 32.5 32.5 #:energy 50.0)
          (make-test-unit 9999 48 4 42.0 34.0))
    (for/list ([i (in-range 10)])
      (make-test-unit (+ 9100 i) 74 1 (+ 50.0 (* 0.3 i)) 34.0))
    p02-map-minerals)))
(define p02-base-threat-cmds
  (translate-bot-actions->sc2-raw-commands
   '()
   p02-base-threat-obs
   #:game-info p02-ginfo
   #:enemy-base '(143.5 143.5)
   #:suppress-attack? #t))
(check-true "p02-base-defense-still-engages-local-threat-under-suppress"
            (ormap (lambda (c)
                     (let ([p (sc2-raw-unit-command-target-pos c)])
                       (and (= (sc2-point2d-x p) 42.0)
                            (= (sc2-point2d-y p) 34.0)
                            (= (length (sc2-raw-unit-command-unit-tags c)) 10))))
                   (p02-attack-point-cmds p02-base-threat-cmds)))

;; 5. Verified Endgame Cleanup A (Enemy Main Cleared with normal mineral fields still on map!):
;;    Decisive army arrives at (143.5, 143.5) with 0 visible/snapshot enemies -> sweep activates cleanly!
(define p02-cleared-main-obs
  (make-test-obs
   9000 600 300
   (append
    (list (make-test-unit 9001 132 1 32.5 32.5 #:energy 110.0)
          (make-test-unit 9220 34 1 142.0 142.0 #:flying? #t)
          (make-test-unit 9221 34 1 143.0 142.0 #:flying? #t))
    (for/list ([i (in-range 12)])
      (make-test-unit (+ 9200 i) 48 1 (+ 140.0 (* 0.4 i)) 143.5))
    (for/list ([i (in-range 4)])
      (make-test-unit (+ 9230 i) 51 1 (+ 141.0 (* 0.5 i)) 144.5))
    p02-map-minerals)))
(define p02-cleared-main-cmds
  (translate-bot-actions->sc2-raw-commands
   '((execute-spatial-maneuver multiprong-rotate-and-pin 143.5 143.5))
   p02-cleared-main-obs
   #:game-info p02-ginfo
   #:enemy-base '(143.5 143.5)))
(define p02-cleared-main-pts (p02-distinct-attack-pts p02-cleared-main-cmds))
(check-true "p02-verified-enemy-main-cleared-scans-corner"
            (p02-has-corner-scan? p02-cleared-main-cmds))
(check-true "p02-verified-enemy-main-cleared-sweeps-multiple-waypoints"
            (>= (length p02-cleared-main-pts) 3))
(check-true "p02-verified-enemy-main-cleared-waypoints-inside-playable-bounds"
            (for/and ([pt (in-list p02-cleared-main-pts)])
              (and (>= (car pt) 11.0) (<= (car pt) 165.0)
                   (>= (cdr pt) 11.0) (<= (cdr pt) 165.0))))

;; 6. Verified Endgame Cleanup B (Mined-Out Map at loop 8000 after loop-4 cluster cache):
;;    Fresh match rewind at loop 4 -> loop 8000 with '() mineral fields -> scans corner & sweeps >= 3 waypoints!
(void
 (translate-bot-actions->sc2-raw-commands
  '()
  (make-test-obs
   4 50 0
   (cons (make-test-unit 9301 132 1 32.5 32.5 #:energy 50.0)
         p02-map-minerals))
  #:game-info p02-ginfo
  #:enemy-base '(143.5 143.5)))
(define p02-mined-out-cmds
  (translate-bot-actions->sc2-raw-commands
   '((execute-spatial-maneuver pre-rotate-intercept-incoming-threat 56.5 32.5))
   (make-test-obs
    8000 800 400
    (list (make-test-unit 9301 132 1 32.5 32.5 #:energy 110.0)
          (make-test-unit 9311 83 1 38.0 34.0)
          (make-test-unit 9312 83 1 39.0 34.0)
          (make-test-unit 9313 83 1 40.0 34.0)
          (make-test-unit 9314 83 1 41.0 34.0)
          (make-test-unit 9315 83 1 42.0 34.0)
          (make-test-unit 9316 78 1 40.0 36.0 #:flying? #t)
          (make-test-unit 9317 78 1 41.0 36.0 #:flying? #t)))
   #:game-info p02-ginfo
   #:enemy-base '(143.5 143.5)))
(define p02-mined-out-pts (p02-distinct-attack-pts p02-mined-out-cmds))
(check-true "p02-mined-out-endgame-scans-corner"
            (p02-has-corner-scan? p02-mined-out-cmds))
(check-true "p02-mined-out-endgame-sweeps-at-least-3-waypoints"
            (>= (length p02-mined-out-pts) 3))

;; 7. Explicit #:endgame-cleanup? #t activates sweep even with minerals present,
;;    while hard #:suppress-attack? #t takes precedence over #:endgame-cleanup? #t!
(define p02-explicit-cleanup-cmds
  (translate-bot-actions->sc2-raw-commands
   '((execute-spatial-maneuver multiprong-rotate-and-pin 143.5 143.5))
   p02-midgame-20sup-obs-7200
   #:game-info p02-ginfo
   #:enemy-base '(143.5 143.5)
   #:endgame-cleanup? #t))
(check-true "p02-explicit-endgame-cleanup-sweeps-cleanly"
            (>= (length (p02-distinct-attack-pts p02-explicit-cleanup-cmds)) 3))
(define p02-explicit-cleanup-suppressed-cmds
  (translate-bot-actions->sc2-raw-commands
   '((execute-spatial-maneuver multiprong-rotate-and-pin 143.5 143.5))
   p02-midgame-20sup-obs-7200
   #:game-info p02-ginfo
   #:enemy-base '(143.5 143.5)
   #:endgame-cleanup? #t
   #:suppress-attack? #t))
(check-true "p02-suppress-attack-overrides-endgame-cleanup"
            (not (ormap (lambda (c)
                          (let ([p (sc2-raw-unit-command-target-pos c)])
                            (or (> (sc2-point2d-x p) 70.0)
                                (> (sc2-point2d-y p) 70.0))))
                        (p02-attack-point-cmds p02-explicit-cleanup-suppressed-cmds))))

;; W2-P0-0 Regression: Normalize SC2 Unit.weapon_cooldown from game loops (22.4/s) to Faster seconds
;;                     at the wire boundary for BOTH ally and enemy unit hashes.
(check-approx "w2-p0-0-helper-zero-loops" (sc2-weapon-cooldown-loops->seconds 0.0) 0.0 1e-6)
(check-approx "w2-p0-0-helper-marine-13.7-loops" (sc2-weapon-cooldown-loops->seconds 13.7) (/ 13.7 22.4) 1e-4)
(check-approx "w2-p0-0-helper-one-second-22.4-loops" (sc2-weapon-cooldown-loops->seconds 22.4) 1.0 1e-6)
(check-approx "w2-p0-0-helper-negative-clamps-to-zero" (sc2-weapon-cooldown-loops->seconds -5.0) 0.0 1e-6)
(check-approx "w2-p0-0-helper-nan-clamps-to-zero" (sc2-weapon-cooldown-loops->seconds +nan.0) 0.0 1e-6)
(check-approx "w2-p0-0-helper-inf-clamps-to-zero" (sc2-weapon-cooldown-loops->seconds +inf.0) 0.0 1e-6)
(check-approx "w2-p0-0-helper-nonreal-clamps-to-zero" (sc2-weapon-cooldown-loops->seconds #f) 0.0 1e-6)

(define w2-p0-0-obs
  (make-test-obs
   3000 200 100
   (list (make-test-unit 9600 18 1 32.5 32.5) ;; Command Center
         (make-test-unit 9601 48 1 40.0 34.0 #:weapon-cooldown 0.0)
         (make-test-unit 9602 48 1 41.0 34.0 #:weapon-cooldown 13.7)
         (make-test-unit 9603 74 1 42.0 34.0 #:weapon-cooldown 22.4)
         (make-test-unit 9604 48 1 43.0 34.0 #:weapon-cooldown -4.2)
         (make-test-unit 9701 74 4 50.0 34.0 #:weapon-cooldown 0.0)
         (make-test-unit 9702 48 4 51.0 34.0 #:weapon-cooldown 13.7)
         (make-test-unit 9703 74 4 52.0 34.0 #:weapon-cooldown 22.4)
         (make-test-unit 9704 48 4 53.0 34.0 #:weapon-cooldown -3.5))))
(define w2-p0-0-rt-hash (sc2-observation->runtime-obs-hash w2-p0-0-obs))
(define (w2-p0-0-find-cd lst id)
  (define rec (findf (lambda (h) (= (hash-ref h 'id -1) id)) lst))
  (and rec (hash-ref rec 'weapon-cooldown #f)))
(define w2-p0-0-allies (hash-ref w2-p0-0-rt-hash 'ally-units '()))
(define w2-p0-0-enemies (hash-ref w2-p0-0-rt-hash 'enemy-units '()))

(check-approx "w2-p0-0-ally-zero-loops-to-0.0s" (w2-p0-0-find-cd w2-p0-0-allies 9601) 0.0 1e-6)
(check-approx "w2-p0-0-ally-13.7-loops-to-0.612s" (w2-p0-0-find-cd w2-p0-0-allies 9602) 0.6116 1e-3)
(check-approx "w2-p0-0-ally-22.4-loops-to-1.0s" (w2-p0-0-find-cd w2-p0-0-allies 9603) 1.0 1e-6)
(check-approx "w2-p0-0-ally-negative-loops-to-0.0s" (w2-p0-0-find-cd w2-p0-0-allies 9604) 0.0 1e-6)
(check-approx "w2-p0-0-enemy-zero-loops-to-0.0s" (w2-p0-0-find-cd w2-p0-0-enemies 9701) 0.0 1e-6)
(check-approx "w2-p0-0-enemy-13.7-loops-to-0.612s" (w2-p0-0-find-cd w2-p0-0-enemies 9702) 0.6116 1e-3)
(check-approx "w2-p0-0-enemy-22.4-loops-to-1.0s" (w2-p0-0-find-cd w2-p0-0-enemies 9703) 1.0 1e-6)
(check-approx "w2-p0-0-enemy-negative-loops-to-0.0s" (w2-p0-0-find-cd w2-p0-0-enemies 9704) 0.0 1e-6)

;; -----------------------------------------------------------------------------
;; Wave 3 Tests: W3-TAC-4 (Enemy Energy), W3-TAC-5 (Cargo/Passengers Fields 24-26),
;;               W3-P1-1 (Single-RPC Batched Placement, 64-Loop Caches, <=2 RPC Budget & <=1 Tumor Throttle)
;; -----------------------------------------------------------------------------
(printf "[Wave 3] Testing W3-TAC-4 enemy energy, W3-TAC-5 cargo/passengers, W3-P1-1 placement batching/budget...\n")

;; W3-TAC-4: Enemy unit hashes MUST carry 'energy and 'energy-max for live Feedback/EMP targeting
(define w3-tac4-obs
  (make-test-obs
   3200 200 100
   (list (make-test-unit 9800 59 1 32.5 32.5) ;; Nexus
         (sc2-unit 1 1 9810 75 1 (sc2-point3d 40.0 34.0 8.0) 0.0 0.5 1.0 0 #f #f #f
                   40.0 40.0 40.0 40.0 110.0 200.0 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0)
         (sc2-unit 1 4 9801 56 2 (sc2-point3d 48.0 34.0 8.0) 0.0 0.625 1.0 0 #f #f #f
                   140.0 140.0 0.0 0.0 150.0 200.0 0 0 #t #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0)
         (sc2-unit 1 4 9802 111 2 (sc2-point3d 49.0 34.0 8.0) 0.0 0.75 1.0 0 #f #f #f
                   90.0 90.0 0.0 0.0 125.4 200.0 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0)
         (sc2-unit 1 4 9803 48 2 (sc2-point3d 50.0 34.0 8.0) 0.0 0.375 1.0 0 #f #f #f
                   45.0 45.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0)
         (sc2-unit 1 4 9804 75 2 (sc2-point3d 51.0 34.0 8.0) 0.0 0.5 1.0 0 #f #f #f
                   40.0 40.0 40.0 40.0 92.6 200.0 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0))))
(define w3-tac4-rt (sc2-observation->runtime-obs-hash w3-tac4-obs))
(define (w3-find-rec lst id)
  (findf (lambda (h) (= (hash-ref h 'id -1) id)) lst))
(define w3-tac4-raven (w3-find-rec (hash-ref w3-tac4-rt 'enemy-units '()) 9801))
(define w3-tac4-infestor (w3-find-rec (hash-ref w3-tac4-rt 'enemy-units '()) 9802))
(define w3-tac4-marine (w3-find-rec (hash-ref w3-tac4-rt 'enemy-units '()) 9803))
(define w3-tac4-enemy-ht (w3-find-rec (hash-ref w3-tac4-rt 'enemy-units '()) 9804))
(define w3-tac4-ally-ht (w3-find-rec (hash-ref w3-tac4-rt 'ally-units '()) 9810))
(check-eqv "w3-tac4-enemy-raven-energy" (and w3-tac4-raven (hash-ref w3-tac4-raven 'energy #f)) 150)
(check-eqv "w3-tac4-enemy-raven-energy-max" (and w3-tac4-raven (hash-ref w3-tac4-raven 'energy-max #f)) 200)
(check-eqv "w3-tac4-enemy-infestor-energy" (and w3-tac4-infestor (hash-ref w3-tac4-infestor 'energy #f)) 125)
(check-eqv "w3-tac4-enemy-infestor-energy-max" (and w3-tac4-infestor (hash-ref w3-tac4-infestor 'energy-max #f)) 200)
(check-eqv "w3-tac4-enemy-marine-energy-zero" (and w3-tac4-marine (hash-ref w3-tac4-marine 'energy #f)) 0)
(check-eqv "w3-tac4-enemy-marine-energy-max-zero" (and w3-tac4-marine (hash-ref w3-tac4-marine 'energy-max #f)) 0)
(check-eqv "w3-tac4-enemy-ht-energy-rounded" (and w3-tac4-enemy-ht (hash-ref w3-tac4-enemy-ht 'energy #f)) 93)
(check-eqv "w3-tac4-ally-ht-energy-max" (and w3-tac4-ally-ht (hash-ref w3-tac4-ally-ht 'energy-max #f)) 200)

;; W3-TAC-5: Protobuf Unit fields 24 (passengers), 25 (cargo_space_taken), 26 (cargo_space_max)
(define (w3-f32 fnum v)
  (bytes-append (encode-tag fnum 5) (encode-float32 v)))

(define (w3-encode-passenger tag utype hp hp-max
                             #:shield [sh 0.0] #:shield-max [sh-max 0.0]
                             #:energy [en 0.0] #:energy-max [en-max 0.0]
                             #:legacy-field8-utype? [legacy-f8? #f])
  (bytes-append
   (encode-uint64 1 tag)
   (w3-f32 2 hp)
   (w3-f32 3 hp-max)
   (w3-f32 4 sh)
   (w3-f32 5 en)
   (if legacy-f8?
       (encode-uint32 8 utype)
       (bytes-append (encode-uint32 6 utype)
                     (w3-f32 7 sh-max)
                     (w3-f32 8 en-max)))))

(define (w3-encode-cargo-unit tag utype alliance x y hp passengers-bytes cargo-taken cargo-max)
  (bytes-append
   (encode-synthetic-unit tag utype alliance x y hp 0.0)
   (apply bytes-append (for/list ([pb (in-list passengers-bytes)])
                         (encode-submessage-field 24 pb)))
   (encode-int32 25 cargo-taken)
   (encode-int32 26 cargo-max)))

(define w3-tac5-medivac-pb
  (w3-encode-cargo-unit
   9901 54 1 45.0 45.0 150.0
   (list (w3-encode-passenger 9910 48 45.0 45.0)
         (w3-encode-passenger 9911 51 110.0 125.0 #:energy 30.0 #:energy-max 100.0))
   3 8))
(define w3-tac5-prism-pb
  (w3-encode-cargo-unit
   9902 81 1 50.0 50.0 80.0
   (list (w3-encode-passenger 9912 83 200.0 200.0 #:shield 100.0 #:legacy-field8-utype? #t))
   4 8))
(define w3-tac5-bunker-pb
  (w3-encode-cargo-unit
   9903 24 1 38.0 38.0 400.0
   (list (w3-encode-passenger 9913 48 45.0 45.0)
         (w3-encode-passenger 9914 48 40.0 45.0))
   2 4))
(define w3-tac5-cc-pb (encode-synthetic-unit 9900 18 1 32.5 32.5 1500.0 0.0))
(define w3-tac5-resp
  (decode-sc2-response
   (encode-synthetic-observation-response
    3400 300 150 40 54
    (list w3-tac5-cc-pb w3-tac5-medivac-pb w3-tac5-prism-pb w3-tac5-bunker-pb))))
(define w3-tac5-obs (sc2-response-observation w3-tac5-resp))
(define (w3-find-sc2-unit obs tag)
  (findf (lambda (u) (= (sc2-unit-tag u) tag)) (sc2-observation-units obs)))
(define w3-medivac-u (w3-find-sc2-unit w3-tac5-obs 9901))
(define w3-prism-u (w3-find-sc2-unit w3-tac5-obs 9902))
(define w3-bunker-u (w3-find-sc2-unit w3-tac5-obs 9903))

(check-eqv "w3-tac5-medivac-cargo-taken" (sc2-unit-cargo-space-taken w3-medivac-u) 3)
(check-eqv "w3-tac5-medivac-cargo-max" (sc2-unit-cargo-space-max w3-medivac-u) 8)
(check-eqv "w3-tac5-medivac-passenger-count" (length (sc2-unit-passengers w3-medivac-u)) 2)
(check-eqv "w3-tac5-medivac-pax0-tag" (sc2-passenger-unit-tag (first (sc2-unit-passengers w3-medivac-u))) 9910)
(check-eqv "w3-tac5-medivac-pax0-type" (sc2-passenger-unit-unit-type (first (sc2-unit-passengers w3-medivac-u))) 48)
(check-eqv "w3-tac5-medivac-pax1-type" (sc2-passenger-unit-unit-type (second (sc2-unit-passengers w3-medivac-u))) 51)
(check-approx "w3-tac5-medivac-pax1-energy-max" (sc2-passenger-unit-energy-max (second (sc2-unit-passengers w3-medivac-u))) 100.0 1e-4)
(check-eqv "w3-tac5-prism-cargo-taken" (sc2-unit-cargo-space-taken w3-prism-u) 4)
(check-eqv "w3-tac5-prism-legacy-f8-pax-type" (sc2-passenger-unit-unit-type (first (sc2-unit-passengers w3-prism-u))) 83)

;; struct-copy sc2-unit MUST preserve decoded passengers/cargo fields cleanly across module boundaries
(define w3-medivac-copied (struct-copy sc2-unit w3-medivac-u [health 120.0]))
(check-approx "w3-tac5-struct-copy-updates-health" (sc2-unit-health w3-medivac-copied) 120.0 1e-4)
(check-eqv "w3-tac5-struct-copy-preserves-cargo-taken" (sc2-unit-cargo-space-taken w3-medivac-copied) 3)
(check-eqv "w3-tac5-struct-copy-preserves-cargo-max" (sc2-unit-cargo-space-max w3-medivac-copied) 8)
(check-eqv "w3-tac5-struct-copy-preserves-passengers" (length (sc2-unit-passengers w3-medivac-copied)) 2)

;; Runtime obs hash exposes cargo fields on BOTH ally units and ally buildings
(define w3-tac5-rt (sc2-observation->runtime-obs-hash w3-tac5-obs))
(define w3-rt-medivac (w3-find-rec (hash-ref w3-tac5-rt 'ally-units '()) 9901))
(define w3-rt-prism (w3-find-rec (hash-ref w3-tac5-rt 'ally-units '()) 9902))
(define w3-rt-bunker (w3-find-rec (hash-ref w3-tac5-rt 'ally-buildings '()) 9903))
(check-eqv "w3-tac5-rt-medivac-cargo-taken" (hash-ref w3-rt-medivac 'cargo-space-taken -1) 3)
(check-eqv "w3-tac5-rt-medivac-cargo-max" (hash-ref w3-rt-medivac 'cargo-space-max -1) 8)
(check-eqv "w3-tac5-rt-medivac-pax-types"
           (map (lambda (p) (hash-ref p 'type 'unknown)) (hash-ref w3-rt-medivac 'passengers '()))
           '(marine marauder))
(check-eqv "w3-tac5-rt-prism-pax-type"
           (hash-ref (first (hash-ref w3-rt-prism 'passengers '())) 'type 'unknown)
           'immortal)
(check-eqv "w3-tac5-rt-prism-pax-shield"
           (hash-ref (first (hash-ref w3-rt-prism 'passengers '())) 'shield -1)
           100)
(check-eqv "w3-tac5-rt-bunker-cargo-taken" (hash-ref w3-rt-bunker 'cargo-space-taken -1) 2)
(check-eqv "w3-tac5-rt-bunker-cargo-max" (hash-ref w3-rt-bunker 'cargo-space-max -1) 4)
(check-eqv "w3-tac5-rt-bunker-pax-count" (length (hash-ref w3-rt-bunker 'passengers '())) 2)

;; W3-P1-1: Single-RPC batched placement, 64-loop pos/neg caches, <= 2 RPC/step budget, <= 1 tumor RPC/step
(define (w3-start-mock-placement-ws policy-fn)
  ;; policy-fn: (rpc-index, item-index, total-items) -> result-code (1=Success, 2=Invalid)
  (define-values (c-in s-out) (make-pipe))
  (define-values (s-in c-out) (make-pipe))
  (define ws (sc2-ws-conn "127.0.0.1" 0 "/sc2api" c-in c-out #f 1))
  (define rpc-count (box 0))
  (define batch-sizes (box '()))
  (define thd
    (thread
     (lambda ()
       (let lp ()
         (define hdr2 (read-bytes 2 s-in))
         (unless (eof-object? hdr2)
           (define b0 (bytes-ref hdr2 0))
           (define b1 (bytes-ref hdr2 1))
           (define opcode (bitwise-and b0 #x0F))
           (define masked? (not (zero? (bitwise-and b1 #x80))))
           (define len7 (bitwise-and b1 #x7F))
           (define plen
             (cond [(< len7 126) len7]
                   [(= len7 126) (integer-bytes->integer (read-bytes 2 s-in) #f #t)]
                   [else (integer-bytes->integer (read-bytes 8 s-in) #f #t)]))
           (define mkey (if masked? (read-bytes 4 s-in) #f))
           (define raw (read-bytes plen s-in))
           (define payload (if masked? (mask-ws-payload raw mkey) raw))
           (when (= opcode 2)
             (define cur-rpc (unbox rpc-count))
             (set-box! rpc-count (add1 cur-rpc))
             (define req-f (decode-protobuf-message payload))
             (define req-id-p (assoc 97 req-f))
             (define id-b (if req-id-p (encode-uint32 97 (third req-id-p)) #""))
             (define q-p (assoc 14 req-f))
             (when q-p
               (define qf (decode-protobuf-message (third q-p)))
               (define p-items (filter (lambda (e) (= (first e) 3)) qf))
               (define n-items (length p-items))
               (set-box! batch-sizes (append (unbox batch-sizes) (list n-items)))
               (define res-b
                 (apply bytes-append
                        (for/list ([_it (in-list p-items)]
                                   [idx (in-naturals 0)])
                          (encode-submessage-field 3 (encode-int32 1 (policy-fn cur-rpc idx n-items))))))
               (define resp (bytes-append (encode-submessage-field 14 res-b) id-b (encode-int32 99 3)))
               (define rlen (bytes-length resp))
               (define rhdr
                 (cond [(< rlen 126) (bytes #x82 rlen)]
                       [(<= rlen 65535) (bytes-append (bytes #x82 126) (integer->integer-bytes rlen 2 #f #t))]
                       [else (bytes-append (bytes #x82 127) (integer->integer-bytes rlen 8 #f #t))]))
               (write-bytes rhdr s-out)
               (write-bytes resp s-out)
               (flush-output s-out))
             (lp)))))))
  (values ws rpc-count batch-sizes
          (lambda ()
            (close-output-port c-out)
            (close-input-port c-in)
            (thread-wait thd))))

(define w3-full-grid (sc2-image-grid 8 128 128 (make-bytes (* 128 128) 1) #f #f))
(define w3-ginfo
  (sc2-game-info "W3PlacementMap" "" '() '(128 128) '(4 4 124 124)
                 (list (sc2-point2d 100.0 100.0))
                 w3-full-grid #f w3-full-grid))

;; W3-P1-1A: Single batched RequestQuery RPC even when all primary spots (0..35) fail and fallback spot succeeds
(hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
(hash-clear! SC2-PLACEMENT-POS-CACHE)
(hash-clear! SC2-TUMOR-PLACEMENT-CACHE)
(let-values ([(ws rpc-cnt bsizes cleanup!)
              (w3-start-mock-placement-ws (lambda (_rpc idx n) (if (= idx (sub1 n)) 1 2)))])
  (define pylon-u (sc2-unit 1 1 8801 60 1 (sc2-point3d 30.0 30.0 8.0) 0.0 1.0 1.0 0 #f #t #f
                            200.0 200.0 200.0 200.0 0.0 0.0 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0))
  (define nexus-u (sc2-unit 1 1 8800 59 1 (sc2-point3d 24.5 24.5 8.0) 0.0 2.75 1.0 0 #f #t #f
                            1000.0 1000.0 1000.0 1000.0 50.0 200.0 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0))
  (define pt1
    (find-verified-building-placement ws 882 30.0 30.0 (list nexus-u pylon-u)
                                      #:min-spacing 2.0 #:max-radius 6.5 #:step 1.0
                                      #:bldg-sym 'gateway #:game-info w3-ginfo #:cur-loop 500))
  (check-true "w3-p1-1a-single-rpc-finds-fallback-spot" (sc2-point2d? pt1))
  (check-eqv "w3-p1-1a-single-batched-rpc-count" (unbox rpc-cnt) 1)
  (check-true "w3-p1-1a-batch-contains-multiple-candidates"
              (and (pair? (unbox bsizes)) (>= (first (unbox bsizes)) 8)))
  ;; W3-P1-1B: Positive cache hit within 64 loops -> 0 additional RPCs!
  (define pt2
    (find-verified-building-placement ws 882 30.0 30.0 (list nexus-u pylon-u)
                                      #:min-spacing 2.0 #:max-radius 6.5 #:step 1.0
                                      #:bldg-sym 'gateway #:game-info w3-ginfo #:cur-loop 540))
  (check-eqv "w3-p1-1b-pos-cache-hit-same-pt" pt2 pt1)
  (check-eqv "w3-p1-1b-pos-cache-hit-zero-extra-rpcs" (unbox rpc-cnt) 1)
  ;; Positive cache invalidates on step-reserved collision (extra-reserved-points) so two builds never overlap
  (define pt3
    (find-verified-building-placement ws 882 30.0 30.0 (list nexus-u pylon-u)
                                      #:min-spacing 2.0 #:max-radius 6.5 #:step 1.0
                                      #:extra-reserved-points (list pt1)
                                      #:bldg-sym 'gateway #:game-info w3-ginfo #:cur-loop 540))
  (check-true "w3-p1-1b-pos-cache-skips-reserved-collision"
              (and (sc2-point2d? pt3) (not (equal? pt3 pt1))))
  (check-eqv "w3-p1-1b-reserved-collision-triggers-1-rpc" (unbox rpc-cnt) 2)
  (cleanup!))

;; W3-P1-1C: Negative cooldown 64-loop TTL skips retries at +48 loops and re-queries at +65 loops
(hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
(hash-clear! SC2-PLACEMENT-POS-CACHE)
(let-values ([(ws rpc-cnt _bsizes cleanup!)
              (w3-start-mock-placement-ws (lambda (_rpc _idx _n) 2))])
  (define pylon-u (sc2-unit 1 1 8811 60 1 (sc2-point3d 30.0 30.0 8.0) 0.0 1.0 1.0 0 #f #t #f
                            200.0 200.0 200.0 200.0 0.0 0.0 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0))
  (define r1 (find-verified-building-placement ws 882 30.0 30.0 (list pylon-u)
                                               #:bldg-sym 'gateway #:game-info w3-ginfo #:cur-loop 1000))
  (define r2 (find-verified-building-placement ws 882 30.0 30.0 (list pylon-u)
                                               #:bldg-sym 'gateway #:game-info w3-ginfo #:cur-loop 1048))
  (define r3 (find-verified-building-placement ws 882 30.0 30.0 (list pylon-u)
                                               #:bldg-sym 'gateway #:game-info w3-ginfo #:cur-loop 1065))
  (check-eqv "w3-p1-1c-neg-cache-all-fail" (list r1 r2 r3) '(#f #f #f))
  (check-eqv "w3-p1-1c-neg-cache-64-loop-ttl-only-2-rpcs" (unbox rpc-cnt) 2)
  (cleanup!))

;; W3-P1-1D: Per-step Creep Tumor <= 1 RPC/step throttle & <= 2 total placement RPCs/step budget (P1 macro first!)
(hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
(hash-clear! SC2-PLACEMENT-POS-CACHE)
(hash-clear! SC2-TUMOR-PLACEMENT-CACHE)
(let-values ([(ws rpc-cnt _bsizes cleanup!)
              (w3-start-mock-placement-ws (lambda (_rpc _idx _n) 1))])
  (define hatch-u (sc2-unit 1 1 8900 86 1 (sc2-point3d 32.5 32.5 8.0) 0.0 2.75 1.0 0 #f #t #f
                            1500.0 1500.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0))
  (define drones (for/list ([i (in-range 4)])
                   (make-test-unit (+ 8901 i) 104 1 (+ 35.0 i) 32.0 #:hp 40.0)))
  (define tumors (for/list ([i (in-range 8)])
                   (sc2-unit 1 1 (+ 8920 i) 137 1 (sc2-point3d (+ 40.0 (* 4.0 i)) 34.0 8.0) 0.0 0.5 1.0 0 #f #t #f
                             50.0 50.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0)))
  (define zerg-obs (make-test-obs 4000 1000 500 (append (list hatch-u) drones tumors)))
  ;; Subtest D1: 8 Creep Tumors casting in one step -> throttled to <= 1 RPC and <= 1 cast emitted!
  (define tumor-actions
    (for/list ([i (in-range 8)])
      (list 'cast (+ 8920 i) 'spread-creep-tumor (+ 48.0 (* 4.0 i)) 34.0)))
  (define tumor-cmds
    (translate-bot-actions->sc2-raw-commands tumor-actions zerg-obs #:ws-conn ws #:game-info w3-ginfo))
  (define tumor-spread-cmds
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1733)))
            tumor-cmds))
  (check-eqv "w3-p1-1d-8-tumors-throttled-to-1-rpc" (unbox rpc-cnt) 1)
  (check-eqv "w3-p1-1d-8-tumors-emits-1-spread-cmd" (length tumor-spread-cmds) 1)
  ;; Subtest D2: 3 distinct P1 macro builds + 4 Creep Tumors in one step -> <= 2 total RPCs/step,
  ;; P1 macro buildings get priority over Creep Tumors, and deferred 3rd build does NOT poison neg cooldown!
  (define rpcs-before-d2 (unbox rpc-cnt))
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (define zerg-obs-d2 (make-test-obs 4008 1000 500 (append (list hatch-u) drones tumors)))
  (define mixed-actions
    (append
     (take tumor-actions 4) ;; deliberately placed BEFORE builds in input to prove P1 macro priority!
     '((build spawning-pool 36.0 36.0)
       (build roach-warren 28.0 36.0)
       (build evolution-chamber 36.0 28.0))))
  (define mixed-cmds
    (translate-bot-actions->sc2-raw-commands mixed-actions zerg-obs-d2 #:ws-conn ws #:game-info w3-ginfo))
  (define d2-rpcs (- (unbox rpc-cnt) rpcs-before-d2))
  (define d2-bldg-cmds
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (memv (sc2-raw-unit-command-ability-id c) '(1155 1165 1156))))
            mixed-cmds))
  (define d2-tumor-cmds
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1733)))
            mixed-cmds))
  (check-true "w3-p1-1d-mixed-step-respects-2-rpc-budget" (<= d2-rpcs 2))
  (check-eqv "w3-p1-1d-p1-macro-gets-both-rpcs" (length d2-bldg-cmds) 2)
  (check-eqv "w3-p1-1d-tumors-deferred-when-macro-uses-budget" (length d2-tumor-cmds) 0)
  (check-true "w3-p1-1d-deferred-3rd-build-does-not-poison-neg-cooldown"
              (= (hash-count SC2-PLACEMENT-NEG-COOLDOWN) 0))
  (cleanup!))

;; W3-P1-1D3: Creep Tumor negative placement cache (64-loop TTL) skips redundant RPCs
(hash-clear! SC2-TUMOR-PLACEMENT-CACHE)
(let-values ([(ws rpc-cnt _bsizes cleanup!)
              (w3-start-mock-placement-ws (lambda (_rpc _idx _n) 2))])
  (define hatch-u (sc2-unit 1 1 8960 86 1 (sc2-point3d 32.5 32.5 8.0) 0.0 2.75 1.0 0 #f #t #f
                            1500.0 1500.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0))
  (define tumor-u (sc2-unit 1 1 8961 137 1 (sc2-point3d 40.0 34.0 8.0) 0.0 0.5 1.0 0 #f #t #f
                            50.0 50.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0))
  (define act '((cast 8961 spread-creep-tumor 48.0 34.0)))
  (void (translate-bot-actions->sc2-raw-commands act (make-test-obs 4200 400 100 (list hatch-u tumor-u)) #:ws-conn ws #:game-info w3-ginfo))
  (void (translate-bot-actions->sc2-raw-commands act (make-test-obs 4240 400 100 (list hatch-u tumor-u)) #:ws-conn ws #:game-info w3-ginfo))
  (void (translate-bot-actions->sc2-raw-commands act (make-test-obs 4268 400 100 (list hatch-u tumor-u)) #:ws-conn ws #:game-info w3-ginfo))
  (check-eqv "w3-p1-1d3-tumor-neg-cache-64-loop-ttl-only-2-rpcs" (unbox rpc-cnt) 2)
  (cleanup!))

;; W3-P1-1E: Multi-base find-best-expansion-placement batches across bases in 1 SINGLE RPC!
(let-values ([(ws rpc-cnt bsizes cleanup!)
              ;; Reject all Base #0 candidates and accept the last candidate (inside Base #1)!
              (w3-start-mock-placement-ws (lambda (_rpc idx n) (if (= idx (sub1 n)) 1 2)))])
  (define (mk-exp-cluster tag0 px py)
    (append
     (for/list ([k (in-range 8)])
       (make-test-unit (+ tag0 k) 341 3 (- px 6.5) (+ (- py 3.5) k) #:minerals 1500))
     (list (make-test-unit (+ tag0 8) 342 3 px (- py 7.0) #:vespene 2250)
           (make-test-unit (+ tag0 9) 342 3 px (+ py 7.0) #:vespene 2250))))
  (define exp-units
    (append
     (list (sc2-unit 1 1 8950 86 1 (sc2-point3d 24.5 24.5 8.0) 0.0 2.75 1.0 0 #f #t #f
                     1500.0 1500.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0))
     (mk-exp-cluster 9100 24.5 24.5)
     (mk-exp-cluster 9200 24.5 56.5)
     (mk-exp-cluster 9300 64.5 24.5)))
  (define exp-pt
    (find-best-expansion-placement ws 1152 24.5 24.5 exp-units #:game-info w3-ginfo))
  (check-true "w3-p1-1e-batched-expand-finds-2nd-base"
              (and (sc2-point2d? exp-pt)
                   (<= (sqrt (+ (sqr (- (sc2-point2d-x exp-pt) 64.5))
                                (sqr (- (sc2-point2d-y exp-pt) 24.5))))
                       6.0)))
  (check-eqv "w3-p1-1e-batched-expand-only-1-rpc" (unbox rpc-cnt) 1)
  (check-true "w3-p1-1e-batched-expand-spans-multiple-bases"
              (and (pair? (unbox bsizes)) (>= (first (unbox bsizes)) 6)))
  (cleanup!))

(hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
(hash-clear! SC2-PLACEMENT-POS-CACHE)
(hash-clear! SC2-TUMOR-PLACEMENT-CACHE)

;; -----------------------------------------------------------------------------
;; Wave 4 Tests: W4-TAC-2-wire (No Mid-Fight / Armed-HT Archon Merge)
;;               W4-P1-1 (Pruned PvZ Natural-Wall Solver Latency & Validity)
;; -----------------------------------------------------------------------------
(printf "[Wave 4] Testing W4-TAC-2-wire Archon merge guards & W4-P1-1 PvZ wall solver latency...\n")

(define (w4-has-1766? cmds)
  (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1766)))
         cmds))

(define w4-ht-armed-1 (make-test-unit 9951 75 1 78.5 79.5 #:hp 40.0 #:energy 65.0))
(define w4-ht-armed-2 (make-test-unit 9952 75 1 78.5 80.5 #:hp 40.0 #:energy 65.0))
(define w4-ht-50en-1  (make-test-unit 9953 75 1 78.5 79.5 #:hp 40.0 #:energy 50.0))
(define w4-ht-50en-2  (make-test-unit 9954 75 1 78.5 80.5 #:hp 40.0 #:energy 50.0))
(define w4-ht-spent-1 (make-test-unit 9955 75 1 78.5 79.5 #:hp 40.0 #:energy 20.0))
(define w4-ht-spent-2 (make-test-unit 9956 75 1 78.5 80.5 #:hp 40.0 #:energy 15.0))
(define w4-close-ling (make-test-unit 9960 105 4 84.5 80.0 #:hp 35.0)) ;; 6.0t <= 8.5t
(define w4-far-hydra  (make-test-unit 9961 107 4 92.5 80.0 #:hp 90.0)) ;; 14.0t > 8.5t
(define w4-close-ovi  (make-test-unit 9962 106 4 82.0 80.0 #:hp 200.0 #:flying? #t)) ;; non-combat
(define w4-3-mutas-far
  (for/list ([i (in-range 3)]) (make-test-unit (+ 9970 i) 108 4 (+ 86.0 i) 80.0 #:hp 120.0 #:flying? #t))) ;; 7.5t > 4.5t
(define w4-3-mutas-close
  (for/list ([i (in-range 3)]) (make-test-unit (+ 9975 i) 108 4 (+ 81.5 i) 80.0 #:hp 120.0 #:flying? #t))) ;; 3.0t <= 4.5t

;; 1. Armed HTs (65en > 50) NEVER merge even with 0 enemies across ALL 4 wire paths
(check-eqv "w4-tac2-65en-no-enemies-producer-blocked"
           (select-producer-tags-for-unit 'archon (list w4-ht-armed-1 w4-ht-armed-2) '())
           '())
(define w4-obs-65en (make-test-obs 5000 300 200 (list w4-ht-armed-1 w4-ht-armed-2)))
(check-true "w4-tac2-65en-morph-archon-blocked"
            (not (w4-has-1766? (translate-bot-actions->sc2-raw-commands '((morph archon)) w4-obs-65en))))
(check-true "w4-tac2-65en-morph-ids-archon-blocked"
            (not (w4-has-1766? (translate-bot-actions->sc2-raw-commands '((morph (9951 9952) archon)) w4-obs-65en))))
(check-true "w4-tac2-65en-cast-morph-archon-blocked"
            (not (w4-has-1766? (translate-bot-actions->sc2-raw-commands '((cast (9951 9952) morph-archon)) w4-obs-65en))))

;; 2. 50en HTs: blocked when combat enemies are visible (Feedback-ready), allowed at home with 0 enemies (Suite 25)
(check-eqv "w4-tac2-50en-with-visible-combat-blocked"
           (select-producer-tags-for-unit 'archon (list w4-ht-50en-1 w4-ht-50en-2) (list w4-far-hydra))
           '())
(check-eqv "w4-tac2-50en-at-home-no-enemies-allowed"
           (sort (select-producer-tags-for-unit 'archon (list w4-ht-50en-1 w4-ht-50en-2) '()) <)
           '(9953 9954))

;; 3. Spent HTs (<50en) NEVER merge while enemy combat is within 8.5t of merge midpoint across ALL paths
(check-eqv "w4-tac2-spent-ht-close-ling-producer-blocked"
           (select-producer-tags-for-unit 'archon (list w4-ht-spent-1 w4-ht-spent-2) (list w4-close-ling))
           '())
(define w4-obs-spent-close (make-test-obs 5010 300 200 (list w4-ht-spent-1 w4-ht-spent-2 w4-close-ling)))
(check-true "w4-tac2-spent-ht-close-ling-morph-blocked"
            (not (w4-has-1766? (translate-bot-actions->sc2-raw-commands '((morph archon)) w4-obs-spent-close))))
(check-true "w4-tac2-spent-ht-close-ling-morph-ids-blocked"
            (not (w4-has-1766? (translate-bot-actions->sc2-raw-commands '((morph (9955 9956) archon)) w4-obs-spent-close))))
(check-true "w4-tac2-spent-ht-close-ling-cast-blocked"
            (not (w4-has-1766? (translate-bot-actions->sc2-raw-commands '((cast (9955 9956) morph-archon)) w4-obs-spent-close))))

;; 4. Spent HTs safely > 8.5t from combat (or near non-combat Overlord) merge cleanly!
(define w4-obs-spent-safe (make-test-obs 5020 300 200 (list w4-ht-spent-1 w4-ht-spent-2 w4-far-hydra w4-close-ovi)))
(check-true "w4-tac2-spent-ht-safe-dist-allows-merge"
            (w4-has-1766? (translate-bot-actions->sc2-raw-commands '((morph (9955 9956) archon)) w4-obs-spent-safe)))

;; 5. >= 3 Mutalisks AA-Archon override works at 7.5t (> 4.5t), blocked when Mutalisks dive inside <= 4.5t
(check-eqv "w4-tac2-3-mutas-at-7.5t-allows-aa-archon-override"
           (sort (select-producer-tags-for-unit 'archon (list w4-ht-armed-1 w4-ht-armed-2) w4-3-mutas-far) <)
           '(9951 9952))
(check-eqv "w4-tac2-3-mutas-at-3.0t-blocks-cocoon-suicide"
           (select-producer-tags-for-unit 'archon (list w4-ht-armed-1 w4-ht-armed-2) w4-3-mutas-close)
           '())

;; W4-P1-1: Pruned PvZ natural-choke wall solver stays < 150ms across 6..12t chokes & open fields
(define (w4-mk-choke-grid w h cy0 cy1 gx0 gx1)
  (hash 'width w 'height h
        'pathing-ref
        (lambda (ix iy)
          (cond [(or (< ix 2) (>= ix (- w 2)) (< iy 2) (>= iy (- h 2))) 0]
                [(and (>= iy cy0) (< iy cy1)) (if (and (>= ix gx0) (< ix gx1)) 1 0)]
                [else 1]))
        'placement-ref
        (lambda (ix iy)
          (cond [(or (< ix 2) (>= ix (- w 2)) (< iy 2) (>= iy (- h 2))) 0]
                [(and (>= iy cy0) (< iy cy1)) (if (and (>= ix gx0) (< ix gx1)) 1 0)]
                [else 1]))
        'height-ref (lambda (_ix _iy) 112.0)))

(for ([cw (in-list '(6 7 8 9 10 12))])
  (define gr (w4-mk-choke-grid 96 96 40 56 36 (+ 36 cw)))
  (define t0 (current-inexact-milliseconds))
  (define wres (pl:solve-protoss-matchup-wall 20.5 14.5 36.5 34.5 'Zerg
                                              #:map-grids gr #:enemy-x 41.0 #:enemy-y (+ 84.5 cw)))
  (define dt (- (current-inexact-milliseconds) t0))
  (check-true (format "w4-p1-1-pvz-choke-~a-valid-natural-wall" cw)
              (and (hash? wres)
                   (eq? (hash-ref wres 'locus #f) 'natural-choke)
                   (eq? (hash-ref wres 'slot-3 'unset) #f)
                   (pl:protoss-wall-valid-on-grids? wres 20.5 14.5 36.5 34.5 gr)))
  (check-true (format "w4-p1-1-pvz-choke-~a-under-150ms" cw)
              (< dt 150.0)))

;; -----------------------------------------------------------------------------
;; Wave 5 Tests: W5-P0-1a-wire (Late-Zerg translate_ms < 4.5ms, Creep Tumor
;;               <=1/step + <=1 RPC/8 loops + <=16 fan, skip enemy burrowed tumors,
;;               and Lair/Hive safe-idle preference + anti-Queen-starvation)
;; -----------------------------------------------------------------------------
(printf "[Wave 5] Testing W5-P0-1a-wire Creep Tumor throttling, late-Zerg translate_ms, & Lair morph unblock...\n")

;; 1. Creep Tumor <= 1 placement/step (offline), <= 1 RPC per 8 loops, <= 16 fan batch, and enemy tumor non-blocking
(hash-clear! SC2-TUMOR-PLACEMENT-CACHE)
(set-box! SC2-LAST-TUMOR-RPC-LOOP -9999)
(let ()
  (define hatch-w5 (sc2-unit 1 1 9500 86 1 (sc2-point3d 32.5 32.5 8.0) 0.0 2.75 1.0 0 #f #t #f
                             1500.0 1500.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0))
  (define tumors-w5
    (for/list ([i (in-range 10)])
      (sc2-unit 1 1 (+ 9510 i) 137 1 (sc2-point3d 40.0 (+ 34.0 (* 4.0 i)) 8.0) 0.0 0.5 1.0 0 #f #t #f
                50.0 50.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0)))
  (define enemy-tumor-on-spot
    (sc2-unit 1 4 9599 137 2 (sc2-point3d 48.5 34.5 8.0) 0.0 0.5 1.0 0 #f #t #f
              50.0 50.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0))
  (define tumor-acts-10
    (for/list ([i (in-range 10)])
      (list 'cast (+ 9510 i) 'spread-creep-tumor 48.5 (+ 34.5 (* 4.0 i)))))
  ;; Offline (no WS): 10 tumors in 1 step -> throttled to <= 1 spread command AND ignores enemy burrowed tumor!
  (define off-cmds
    (translate-bot-actions->sc2-raw-commands
     tumor-acts-10
     (make-test-obs 5900 500 200 (append (list hatch-w5 enemy-tumor-on-spot) tumors-w5))
     #:game-info w3-ginfo))
  (define off-spreads
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1733))) off-cmds))
  (check-eqv "w5-p0-1a-offline-10-tumors-throttled-to-1-per-step" (length off-spreads) 1)
  (check-true "w5-p0-1a-enemy-burrowed-tumor-does-not-block-target-spot"
              (and (pair? off-spreads)
                   (equal? (sc2-raw-unit-command-target-pos (first off-spreads)) (sc2-point2d 48.5 34.5))))
  ;; Active WS: <= 1 RPC per 8 game loops AND fan batch size <= 16
  (hash-clear! SC2-TUMOR-PLACEMENT-CACHE)
  (set-box! SC2-LAST-TUMOR-RPC-LOOP -9999)
  (let-values ([(ws rpc-cnt bsizes cleanup!)
                (w3-start-mock-placement-ws (lambda (_rpc _idx _n) 1))])
    (define obs-6000 (make-test-obs 6000 500 200 (append (list hatch-w5) tumors-w5)))
    (define obs-6004 (make-test-obs 6004 500 200 (append (list hatch-w5) tumors-w5)))
    (define obs-6008 (make-test-obs 6008 500 200 (append (list hatch-w5) tumors-w5)))
    (void (translate-bot-actions->sc2-raw-commands '((cast 9511 spread-creep-tumor 48.5 38.5)) obs-6000 #:ws-conn ws #:game-info w3-ginfo))
    (check-eqv "w5-p0-1a-tumor-rpc-fires-at-loop-6000" (unbox rpc-cnt) 1)
    (check-true "w5-p0-1a-tumor-fan-batch-le-16" (and (pair? (unbox bsizes)) (<= (first (unbox bsizes)) 16)))
    ;; 4 loops later (< 8): DIFFERENT tumor off cooldown must NOT fire RPC!
    (void (translate-bot-actions->sc2-raw-commands '((cast 9512 spread-creep-tumor 48.5 42.5)) obs-6004 #:ws-conn ws #:game-info w3-ginfo))
    (check-eqv "w5-p0-1a-tumor-rpc-throttled-within-8-loops" (unbox rpc-cnt) 1)
    ;; 8 loops later (>= 8): RPC window reopens!
    (void (translate-bot-actions->sc2-raw-commands '((cast 9512 spread-creep-tumor 48.5 42.5)) obs-6008 #:ws-conn ws #:game-info w3-ginfo))
    (check-eqv "w5-p0-1a-tumor-rpc-allowed-after-8-loops" (unbox rpc-cnt) 2)
    (cleanup!)))

;; 2. Late-Zerg translate_ms benchmark (< 4.5ms/step on 135 actions + 25 tumors + 300 enemy burrowed tumors)
(let ()
  (define w5-allies
    (append
     (for/list ([i (in-range 6)])
       (sc2-unit 1 1 (+ 9600 i) 86 1 (sc2-point3d (+ 24.5 (* 18.0 (remainder i 3))) (+ 24.5 (* 24.0 (quotient i 3))) 8.0)
                 0.0 2.75 1.0 0 #f #t #f 1500.0 1500.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0))
     (for/list ([i (in-range 50)]) (make-test-unit (+ 9620 i) 104 1 (+ 26.0 (remainder i 10)) (+ 25.0 (quotient i 10)) #:hp 40.0))
     (for/list ([i (in-range 110)]) (make-test-unit (+ 9700 i) 105 1 (+ 60.0 (* 0.5 (remainder i 20))) (+ 60.0 (* 0.5 (quotient i 20))) #:hp 35.0))
     (for/list ([i (in-range 25)])
       (sc2-unit 1 1 (+ 9820 i) 137 1 (sc2-point3d (+ 35.0 (* 3.0 (remainder i 10))) (+ 35.0 (* 3.0 (quotient i 10))) 8.0)
                 0.0 0.5 1.0 0 #f #t #f 50.0 50.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0))))
  (define w5-enemies
    (append
     (for/list ([i (in-range 300)])
       (sc2-unit 1 4 (+ 29000 i) 137 2 (sc2-point3d (+ 70.0 (* 1.5 (remainder i 20))) (+ 70.0 (* 1.5 (quotient i 20))) 8.0)
                 0.0 0.5 1.0 0 #f #t #f 50.0 50.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0))
     (for/list ([i (in-range 30)]) (make-test-unit (+ 29400 i) 105 4 (+ 85.0 (* 0.5 (remainder i 10))) (+ 85.0 (* 0.5 (quotient i 10))) #:hp 35.0))))
  (define w5-acts
    (append
     (for/list ([i (in-range 25)]) (list 'cast (+ 9820 i) 'spread-creep-tumor (+ 43.0 (* 3.0 (remainder i 10))) (+ 43.0 (* 3.0 (quotient i 10)))))
     (for/list ([i (in-range 110)]) (list 'attack-unit (+ 9700 i) (+ 29400 (remainder i 30))))))
  (define w5-units (append w5-allies w5-enemies))
  (void (translate-bot-actions->sc2-raw-commands w5-acts (make-test-obs 22000 1200 400 w5-units) #:game-info w3-ginfo #:enemy-base '(100.0 100.0)))
  (define t0-w5 (current-inexact-milliseconds))
  (for ([k (in-range 10)])
    (void (translate-bot-actions->sc2-raw-commands w5-acts (make-test-obs (+ 22004 (* k 4)) 1200 400 w5-units) #:game-info w3-ginfo #:enemy-base '(100.0 100.0))))
  (define avg-w5-ms (/ (- (current-inexact-milliseconds) t0-w5) 10.0))
  (check-true (format "w5-p0-1a-late-zerg-translate-under-4.5ms (~a ms)" (real->decimal-string avg-w5-ms 2))
              (< avg-w5-ms 4.5)))

;; 3. Lair/Hive morph prefers safe idle Hatchery closest to home AND prevents Queen training from starving Lair
(set-box! SC2-ZERG-TH-MORPH-RESERVE-LOOP #f)
(let ()
  (define (mk-hatch tag x y [ords '()])
    (sc2-unit 1 1 tag 86 1 (sc2-point3d x y 8.0) 0.0 2.75 1.0 0 #f #t #f
              1500.0 1500.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #f ords 0 '() 0 0 0.0 0 0 0 0))
  (define (mk-lair tag x y)
    (sc2-unit 1 1 tag 100 1 (sc2-point3d x y 8.0) 0.0 2.75 1.0 0 #f #t #f
              2000.0 2000.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0))
  ;; A. Main idle Hatchery (9851 at 32.5,32.5) preferred over exposed 3rd (9852 at 80.5,80.5) even when 3rd is first in list
  ;;    Wait: home-x/y defaults to first townhall if SC2-HOME-BASE-ANCHOR unset; initialize anchor with main first!
  (void (sc2-observation->runtime-obs-hash (make-test-obs 100 200 100 (list (mk-hatch 9851 32.5 32.5)))))
  (define cmds-lair-main
    (translate-bot-actions->sc2-raw-commands
     '((build lair))
     (make-test-obs 7000 300 200 (list (mk-hatch 9852 80.5 80.5) (mk-hatch 9851 32.5 32.5)))))
  (define lair-cmd-a (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1216))) cmds-lair-main))
  (check-eqv "w5-p0-1a-lair-prefers-safe-idle-main-hatch"
             (and lair-cmd-a (sc2-raw-unit-command-unit-tags lair-cmd-a))
             '(9851))
  ;; B. Main Hatchery busy training Queen (1632) -> Lair immediately picks idle natural Hatchery (9852)
  (define cmds-lair-idle-nat
    (translate-bot-actions->sc2-raw-commands
     '((build lair))
     (make-test-obs 7040 300 200 (list (mk-hatch 9851 32.5 32.5 (list (sc2-unit-order 1632 #f 0 0.5)))
                                       (mk-hatch 9852 54.5 32.5)))))
  (define lair-cmd-b (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1216))) cmds-lair-idle-nat))
  (check-eqv "w5-p0-1a-lair-picks-idle-hatch-when-main-busy"
             (and lair-cmd-b (sc2-raw-unit-command-unit-tags lair-cmd-b))
             '(9852))
  ;; C. Single Hatchery busy when (build lair) requested -> sets Lair reservation -> 20 loops later when idle,
  ;;    (train queen) MUST NOT steal the last idle Hatchery!
  (set-box! SC2-ZERG-TH-MORPH-RESERVE-LOOP #f)
  (void (translate-bot-actions->sc2-raw-commands
         '((build lair))
         (make-test-obs 7100 300 200 (list (mk-hatch 9851 32.5 32.5 (list (sc2-unit-order 1632 #f 0 0.9)))))))
  (define cmds-q-blocked
    (translate-bot-actions->sc2-raw-commands
     '((train queen))
     (make-test-obs 7120 300 200 (list (mk-hatch 9851 32.5 32.5)))))
  (check-true "w5-p0-1a-queen-does-not-starve-last-idle-hatch-while-lair-reserved"
              (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1632)))
                          cmds-q-blocked)))
  ;; D. With 2 idle Hatcheries while Lair is reserved, (train queen) trains on the non-main Hatchery (9852), keeping main (9851) free!
  (define cmds-q-2hatch
    (translate-bot-actions->sc2-raw-commands
     '((train queen))
     (make-test-obs 7124 300 200 (list (mk-hatch 9851 32.5 32.5) (mk-hatch 9852 54.5 32.5)))))
  (define q-cmd-d (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1632))) cmds-q-2hatch))
  (check-eqv "w5-p0-1a-queen-uses-second-hatch-keeping-main-for-lair"
             (and q-cmd-d (sc2-raw-unit-command-unit-tags q-cmd-d))
             '(9852))
  ;; E. Once Lair exists, reservation clears and (train queen) resumes freely!
  (define cmds-q-after-lair
    (translate-bot-actions->sc2-raw-commands
     '((train queen))
     (make-test-obs 7128 300 200 (list (mk-lair 9851 32.5 32.5)))))
  (check-true "w5-p0-1a-queen-resumes-once-lair-exists"
              (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1632)))
                     cmds-q-after-lair)))
(set-box! SC2-ZERG-TH-MORPH-RESERVE-LOOP #f)

(printf "[Wave 6] Testing W6-TAC-2 Zerg combat morph proximity guard & W6-TAC-4-wire patrol-block-expansion reservation...\n")

;; 1. W6-TAC-2: Zerg combat morphs (baneling/ravager/lurker/brood-lord) never morph within <= 10.0t of live enemy combat
(let ()
  (define (mk-u tag utype ally x y [ords '()])
    (sc2-unit 1 ally tag utype 1 (sc2-point3d x y 8.0) 0.0 0.5 1.0 0 #f #f #f
              100.0 100.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #f ords 0 '() 0 0 0.0 0 0 0 0))
  (define (mk-bldg tag utype ally x y)
    (sc2-unit 1 ally tag utype 1 (sc2-point3d x y 8.0) 0.0 2.0 1.0 0 #f #t #f
              500.0 500.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0))
  (define front-roach (mk-u 9901 110 1 80.0 80.0))     ;; 4.0t from Marine
  (define front-ling  (mk-u 9902 105 1 81.5 80.0))     ;; 2.5t from Marine
  (define front-hydra (mk-u 9903 107 1 78.0 80.0))     ;; 6.0t from Marine
  (define front-corr  (mk-u 9904 112 1 76.0 80.0))     ;; 8.0t from Marine
  (define enemy-marine (mk-u 29901 48 4 84.0 80.0))
  (define front-allies (list front-roach front-ling front-hydra front-corr))
  (check-eqv "w6-tac-2-frontline-ravager-blocked"
             (select-producer-tags-for-unit 'ravager front-allies (list enemy-marine))
             '())
  (check-eqv "w6-tac-2-frontline-baneling-blocked"
             (select-producer-tags-for-unit 'baneling front-allies (list enemy-marine))
             '())
  (check-eqv "w6-tac-2-frontline-lurker-blocked"
             (select-producer-tags-for-unit 'lurker front-allies (list enemy-marine))
             '())
  (check-eqv "w6-tac-2-frontline-broodlord-blocked"
             (select-producer-tags-for-unit 'brood-lord front-allies (list enemy-marine))
             '())
  ;; Full wire translation rejects train/morph/explicit-morph when all units are in combat
  (define front-obs (make-test-obs 15000 500 500 (append front-allies (list enemy-marine))))
  (define front-cmds
    (translate-bot-actions->sc2-raw-commands
     '((train ravager) (train baneling) (morph lurker) (morph 9901 ravager) (morph brood-lord))
     front-obs))
  (check-true "w6-tac-2-wire-emits-zero-midfight-cocoon-morphs"
              (not (ormap (lambda (c)
                            (and (sc2-raw-unit-command? c)
                                 (memv (sc2-raw-unit-command-ability-id c) '(80 2330 2332 1372))))
                          front-cmds)))
  ;; Rear units (> 10.0t) ARE allowed, sorted farthest-first, and explicit frontline morph falls back to rear unit!
  (define mid-roach  (mk-u 9905 110 1 68.0 80.0))      ;; 16.0t from Marine
  (define rear-roach (mk-u 9906 110 1 60.0 80.0))      ;; 24.0t from Marine
  (check-eqv "w6-tac-2-prefers-farthest-safe-rear-roach"
             (select-producer-tags-for-unit 'ravager (list front-roach mid-roach rear-roach) (list enemy-marine))
             '(9906 9905))
  (define fallback-obs
    (make-test-obs 15010 500 500 (list front-roach mid-roach rear-roach enemy-marine)))
  (define fallback-cmds
    (translate-bot-actions->sc2-raw-commands '((morph 9901 ravager)) fallback-obs))
  (define rav-cmd (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 2330))) fallback-cmds))
  (check-eqv "w6-tac-2-explicit-frontline-morph-falls-back-to-rear-roach"
             (and rav-cmd (sc2-raw-unit-command-unit-tags rav-cmd))
             '(9906))
  ;; Defensive structure (Photon Cannon at 6t) blocks cocoon morph; passive Nexus/Overlord at 4t does NOT block!
  (define enemy-cannon (mk-bldg 29902 66 4 86.0 80.0))
  (define enemy-nexus  (mk-bldg 29903 59 4 84.0 80.0))
  (define enemy-ovie   (mk-u    29904 106 4 84.0 80.0))
  (check-eqv "w6-tac-2-defensive-structure-blocks-cocoon-morph"
             (select-producer-tags-for-unit 'ravager (list front-roach) (list enemy-cannon))
             '())
  (check-eqv "w6-tac-2-passive-building-or-overlord-allows-morph"
             (select-producer-tags-for-unit 'ravager (list front-roach) (list enemy-nexus enemy-ovie))
             '(9901)))

;; 2. W6-TAC-4-wire: patrol-block-expansion routes through claim-combat-tags-for-order! & runs post-combat
(let ()
  (define (mk-u tag utype ally x y [ords '()])
    (sc2-unit 1 ally tag utype 1 (sc2-point3d x y 8.0) 0.0 0.625 1.0 0 #f #f #f
              80.0 80.0 80.0 80.0 0.0 0.0 0 0 #f #f #f #t #f ords 0 '() 0 0 0.0 0 0 0 0))
  (define (mk-min tag x y)
    (sc2-unit 1 3 tag 341 1 (sc2-point3d x y 8.0) 0.0 1.0 1.0 0 #f #f #f
              0.0 0.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0))
  (define stalker-fight (mk-u 9951 74 1 80.5 78.0))
  (define enemy-marine  (mk-u 29951 48 4 85.0 78.0))
  ;; Even when patrol-block-expansion appears BEFORE attack-unit, combat order claims 9951 and patrol is dropped!
  (define cmds-combat-wins
    (translate-bot-actions->sc2-raw-commands
     '((patrol-block-expansion 9951 48.0 48.0)
       (attack-unit 9951 29951))
     (make-test-obs 2400 220 100 (list stalker-fight enemy-marine))))
  (check-true "w6-tac-4-wire-combat-order-beats-patrol-block-expansion"
              (and (ormap (lambda (c)
                            (and (sc2-raw-unit-command? c)
                                 (= (sc2-raw-unit-command-ability-id c) 23)
                                 (memv 9951 (sc2-raw-unit-command-unit-tags c))))
                          cmds-combat-wins)
                   (not (ormap (lambda (c)
                                 (and (sc2-raw-unit-command? c)
                                      (= (sc2-raw-unit-command-ability-id c) 17)
                                      (memv 9951 (sc2-raw-unit-command-unit-tags c))))
                               cmds-combat-wins))))
  ;; Protected active order (e.g., Ghost Snipe channel 2714) is NOT stolen by patrol-block-expansion
  (define ghost-chan (mk-u 9952 50 1 80.0 80.0 (list (sc2-unit-order 2714 #f 29951 0.5))))
  (define cmds-prot
    (translate-bot-actions->sc2-raw-commands
     '((patrol-block-expansion 9952 48.0 48.0))
     (make-test-obs 2420 220 100 (list ghost-chan enemy-marine))))
  (check-true "w6-tac-4-wire-protected-order-not-stolen-by-patrol"
              (not (ormap (lambda (c)
                            (and (sc2-raw-unit-command? c)
                                 (= (sc2-raw-unit-command-ability-id c) 17)
                                 (memv 9952 (sc2-raw-unit-command-unit-tags c))))
                          cmds-prot)))
  ;; Unclaimed idle unit DOES execute patrol-block-expansion cleanly
  (define idle-marine (mk-u 9953 48 1 46.0 46.0))
  (define cmds-idle-patrol
    (translate-bot-actions->sc2-raw-commands
     '((patrol-block-expansion 9953 48.0 48.0))
     (make-test-obs 2440 220 100 (list idle-marine))))
  (check-true "w6-tac-4-wire-idle-unit-emits-patrol-17"
              (ormap (lambda (c)
                       (and (sc2-raw-unit-command? c)
                            (= (sc2-raw-unit-command-ability-id c) 17)
                            (equal? (sc2-raw-unit-command-unit-tags c) '(9953))))
                     cmds-idle-patrol))
  ;; Idle worker patrolling nat is protected from trailing harvest-mineral (3666)
  (define idle-probe (mk-u 9954 84 1 46.0 46.0))
  (define min-patch  (mk-min 29954 30.0 30.0))
  (define cmds-worker-patrol
    (translate-bot-actions->sc2-raw-commands
     '((patrol-block-expansion 9954 48.0 48.0)
       (harvest-mineral 9954 29954))
     (make-test-obs 2460 220 100 (list idle-probe min-patch))))
  (check-true "w6-tac-4-wire-patrolling-worker-not-overwritten-by-harvest"
              (and (ormap (lambda (c)
                            (and (sc2-raw-unit-command? c)
                                 (= (sc2-raw-unit-command-ability-id c) 17)
                                 (memv 9954 (sc2-raw-unit-command-unit-tags c))))
                          cmds-worker-patrol)
                   (not (ormap (lambda (c)
                                 (and (sc2-raw-unit-command? c)
                                      (= (sc2-raw-unit-command-ability-id c) 3666)
                                      (memv 9954 (sc2-raw-unit-command-unit-tags c))))
                               cmds-worker-patrol))))
  ;; Already-patrolling unit at same point is deduplicated by claim-combat-tags-for-order!
  (define already-patrol (mk-u 9955 48 1 46.0 46.0 (list (sc2-unit-order 17 (sc2-point3d 48.0 48.0 8.0) 0 0.0))))
  (define cmds-dedup
    (translate-bot-actions->sc2-raw-commands
     '((patrol-block-expansion 9955 48.0 48.0))
     (make-test-obs 2480 220 100 (list already-patrol))))
  (check-true "w6-tac-4-wire-already-patrolling-unit-deduped"
              (not (ormap (lambda (c)
                            (and (sc2-raw-unit-command? c)
                                 (= (sc2-raw-unit-command-ability-id c) 17)
                                 (memv 9955 (sc2-raw-unit-command-unit-tags c))))
                          cmds-dedup))))

(printf "[Wave 7] Testing W7-P0-2-wire governor large-P2 rescue & maxed-army push vs sticky-hold/hg-hold...\n")

;; 1. W7-P0-2-wire Governor: continuous P1 creep-tumor / macro spam NEVER starves overdue (>= 8 loops)
;;    large multi-unit (>= 8 tags, AB 23/16) P2 combat marches, while keeping P1 healthy & APM <= hard cap!
(let ()
  (define gov-w7 (make-wire-apm-governor #:target-apm 410.0 #:hard-cap-apm 485.0))
  (define large-p2-emitted 0)
  (define p1-macro-emitted 0)
  (define sim-ev-total 0)
  (define sim-sel #f)
  (define squad-a (for/list ([i (in-range 12)]) (+ 8100 i)))
  (define squad-b (for/list ([i (in-range 8)])  (+ 8200 i)))
  (for ([step-idx (in-range 60)])
    (define gl (* step-idx 4))
    (define batch
      (list (sc2-raw-unit-command 1733 (sc2-point2d (+ 45.0 (modulo step-idx 10)) 45.0) 0 (list (+ 6001 (modulo step-idx 7))) #f)
            (sc2-raw-unit-command 1343 #f 0 (list (+ 6101 (modulo step-idx 7))) #f)
            (sc2-raw-unit-command 1342 #f 0 (list (+ 6201 (modulo step-idx 7))) #f)
            (sc2-raw-unit-command 1340 #f 0 (list (+ 6301 (modulo step-idx 7))) #f)
            (sc2-raw-unit-command 1632 #f 0 (list (+ 6401 (modulo step-idx 5))) #f)
            (sc2-raw-unit-command 1152 (sc2-point2d 54.5 32.5) 0 (list (+ 6501 (modulo step-idx 5))) #f)
            (sc2-raw-unit-command 23 (sc2-point2d 143.5 143.5) 0 squad-a #f)
            (sc2-raw-unit-command 16 (sc2-point2d 135.0 135.0) 0 squad-b #f)))
    (for ([c (in-list (govern-sc2-wire-actions! gov-w7 batch gl))])
      (when (sc2-raw-unit-command? c)
        (define ab (sc2-raw-unit-command-ability-id c))
        (define tags (sc2-raw-unit-command-unit-tags c))
        (if (and sim-sel (equal? tags sim-sel))
            (set! sim-ev-total (+ sim-ev-total 1))
            (begin (set! sim-sel tags) (set! sim-ev-total (+ sim-ev-total 2))))
        (cond
          [(and (memv ab '(23 16)) (>= (length tags) 8))
           (set! large-p2-emitted (add1 large-p2-emitted))]
          [(memv ab '(1733 1343 1342 1340 1632 1152))
           (set! p1-macro-emitted (add1 p1-macro-emitted))]))))
  (check-true (format "w7-p0-2-wire-gov-large-p2-not-starved-by-p1-spam (got ~a)" large-p2-emitted)
              (>= large-p2-emitted 12))
  (check-true (format "w7-p0-2-wire-gov-p1-macro-remains-healthy (got ~a)" p1-macro-emitted)
              (>= p1-macro-emitted 20))
  (check-true (format "w7-p0-2-wire-gov-rolling-apm-within-hard-cap (ev=~a)" sim-ev-total)
              (<= sim-ev-total 485))

  ;; Overdue (>= 8 loops) multi-squad burst with 4 large P2 squads + 10 P1 commands emits all 4 squads
  ;; ahead of P1 drain (and sorts largest army first when tokens only allow a subset)!
  (define gov-w7b (make-wire-apm-governor #:target-apm 410.0 #:hard-cap-apm 485.0))
  (define p1-burst
    (for/list ([i (in-range 10)])
      (sc2-raw-unit-command 1733 (sc2-point2d (+ 50.0 i) 50.0) 0 (list (+ 6600 i)) #f)))
  (define sq4-cmds
    (list (sc2-raw-unit-command 23 (sc2-point2d 140.0 140.0) 0 (for/list ([i (in-range 8)])  (+ 8300 i)) #f)
          (sc2-raw-unit-command 23 (sc2-point2d 142.0 40.0)  0 (for/list ([i (in-range 10)]) (+ 8400 i)) #f)
          (sc2-raw-unit-command 23 (sc2-point2d 40.0 142.0)  0 (for/list ([i (in-range 16)]) (+ 8500 i)) #f)
          (sc2-raw-unit-command 16 (sc2-point2d 120.0 120.0) 0 (for/list ([i (in-range 9)])  (+ 8600 i)) #f)))
  (define out-4sq (govern-sc2-wire-actions! gov-w7b (append p1-burst sq4-cmds) 100))
  (define emitted-large-sq
    (filter (lambda (c) (and (sc2-raw-unit-command? c)
                             (memv (sc2-raw-unit-command-ability-id c) '(23 16))
                             (>= (length (sc2-raw-unit-command-unit-tags c)) 8)))
            out-4sq))
  (check-eqv "w7-p0-2-wire-gov-overdue-4-large-p2-squads-all-rescued"
             (length emitted-large-sq)
             4)
  (check-eqv "w7-p0-2-wire-gov-largest-army-squad-emitted-first"
             (length (sc2-raw-unit-command-unit-tags (first emitted-large-sq)))
             16))

;; 2. W7-P0-2-wire Hold-Posture: maxed/dominant armies (>= 40 combat supply, no explicit hold/suppress)
;;    with empty targetable-enemy-units and active/recent offensive push or enemy-main-cleared? are NEVER
;;    pulled backward to home staging by `action-has-hg-hold?` or `sticky-hold-pt`!
(let ()
  (define (mk-u tag utype ally x y)
    (sc2-unit 1 ally tag utype 1 (sc2-point3d x y 8.0) 0.0 0.625 1.0 0 #f #f #f
              145.0 145.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0))
  (define (mk-th tag x y)
    (sc2-unit 1 1 tag 86 1 (sc2-point3d x y 8.0) 0.0 2.75 1.0 0 #f #t #f
              1500.0 1500.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0))
  (define home-th (mk-th 9970 32.5 32.5))
  (define roach-tags-40 (for/list ([i (in-range 20)]) (+ 9971 i))) ;; 20 Roaches = 40 combat supply
  ;; Reset match state cleanly at loop 100, then advance to late game 16000
  (void (sc2-observation->runtime-obs-hash (make-test-obs 100 200 100 (list home-th))))
  ;; Step A (loop 16000): Offensive attack-pos push toward enemy base (143.5, 143.5)
  (define obs-push-16000
    (make-test-obs
     16000 1000 500
     (cons home-th
           (for/list ([t (in-list roach-tags-40)] [i (in-naturals)])
             (mk-u t 110 1 (+ 55.0 (* 0.3 i)) (+ 55.0 (* 0.2 i)))))))
  (void (translate-bot-actions->sc2-raw-commands
         (list (list 'attack-pos roach-tags-40 143.5 143.5))
         obs-push-16000
         #:game-info p02-ginfo
         #:enemy-base '(143.5 143.5)))
  ;; Step B (loop 16016, inside 44-loop refractory window): stray high-ground-tactics hold at home ramp (44, 44)
  ;; MUST NOT pull the 40-supply idle army back to (44, 44) — army must march forward toward (143.5, 143.5)!
  (define obs-hg-16016
    (make-test-obs
     16016 1000 500
     (cons home-th
           (for/list ([t (in-list roach-tags-40)] [i (in-naturals)])
             (mk-u t 110 1 (+ 56.0 (* 0.3 i)) (+ 56.0 (* 0.2 i)))))))
  (define cmds-hg-16016
    (translate-bot-actions->sc2-raw-commands
     '((high-ground-tactics hold-high-ground-ramp-arc 44.0 44.0 #f))
     obs-hg-16016
     #:game-info p02-ginfo
     #:enemy-base '(143.5 143.5)))
  (define atk-pts-hg
    (filter (lambda (c) (and (sc2-raw-unit-command? c)
                             (= (sc2-raw-unit-command-ability-id c) 23)
                             (sc2-point2d? (sc2-raw-unit-command-target-pos c))))
            cmds-hg-16016))
  (check-true "w7-p0-2-wire-maxed-push-not-pulled-back-by-hg-hold"
              (and (pair? atk-pts-hg)
                   (not (ormap (lambda (c)
                                 (let ([p (sc2-raw-unit-command-target-pos c)])
                                   (and (< (sc2-point2d-x p) 70.0)
                                        (< (sc2-point2d-y p) 70.0))))
                               atk-pts-hg))
                   (ormap (lambda (c)
                            (let ([p (sc2-raw-unit-command-target-pos c)])
                              (and (> (sc2-point2d-x p) 120.0)
                                   (> (sc2-point2d-y p) 120.0))))
                          atk-pts-hg)))
  ;; Step C (loop 16100 -> 16112 -> 16120): sticky-hold-pt set earlier does NOT pull a 40-supply army back
  ;; once enemy-main-cleared? is active!
  (define obs-hold-16100
    (make-test-obs
     16100 1000 500
     (cons home-th
           (for/list ([t (in-list roach-tags-40)] [i (in-naturals)])
             (mk-u t 110 1 (+ 85.0 (* 0.3 i)) (+ 85.0 (* 0.2 i)))))))
  (void (translate-bot-actions->sc2-raw-commands
         '((execute-spatial-maneuver safe-to-expand-enemy-pinned-far 48.0 48.0))
         obs-hold-16100
         #:game-info p02-ginfo
         #:enemy-base '(143.5 143.5)))
  (define obs-cleared-16112
    (make-test-obs
     16112 1000 500
     (cons home-th
           (append
            (list (mk-u 9971 110 1 142.0 142.0)
                  (mk-u 9972 110 1 143.0 142.0))
            (for/list ([t (in-list (cddr roach-tags-40))] [i (in-naturals)])
              (mk-u t 110 1 (+ 90.0 (* 0.3 i)) (+ 90.0 (* 0.2 i))))))))
  (define cmds-cleared-16112
    (translate-bot-actions->sc2-raw-commands
     '()
     obs-cleared-16112
     #:game-info p02-ginfo
     #:enemy-base '(143.5 143.5)))
  (define atk-pts-cleared
    (filter (lambda (c) (and (sc2-raw-unit-command? c)
                             (= (sc2-raw-unit-command-ability-id c) 23)
                             (sc2-point2d? (sc2-raw-unit-command-target-pos c))))
            cmds-cleared-16112))
  (check-true "w7-p0-2-wire-enemy-main-cleared-ignores-stale-sticky-hold"
              (not (ormap (lambda (c)
                            (let ([p (sc2-raw-unit-command-target-pos c)])
                              (and (<= (abs (- (sc2-point2d-x p) 48.0)) 2.0)
                                   (<= (abs (- (sc2-point2d-y p) 48.0)) 2.0))))
                          atk-pts-cleared)))
  ;; Step D: Explicit #:suppress-attack? #t STILL overrides and keeps even a 40-supply army from pushing cross-map!
  (define cmds-explicit-suppress
    (translate-bot-actions->sc2-raw-commands
     '()
     obs-hg-16016
     #:game-info p02-ginfo
     #:enemy-base '(143.5 143.5)
     #:suppress-attack? #t))
  (check-true "w7-p0-2-wire-explicit-suppress-still-respected-for-maxed-army"
              (not (ormap (lambda (c)
                            (and (sc2-raw-unit-command? c)
                                 (= (sc2-raw-unit-command-ability-id c) 23)
                                 (sc2-point2d? (sc2-raw-unit-command-target-pos c))
                                 (let ([p (sc2-raw-unit-command-target-pos c)])
                                   (or (> (sc2-point2d-x p) 100.0)
                                       (> (sc2-point2d-y p) 100.0)))))
                          cmds-explicit-suppress))))

(printf "[Wave 8] Testing W8-P0-4-wire Bunker-Load/own-base defense P0 priority & W8-TAC-1/4 wire guards...\n")

(let ()
  (define (mk-u tag utype ally x y #:en [en 0.0] #:prog [prog 1.0] #:struct? [struct? #f]
                #:cargo-taken [ct 0] #:cargo-max [cm 0])
    (sc2-unit 1 ally tag utype 1 (sc2-point3d x y 8.0) 0.0 (if struct? 1.5 0.5) prog 0 #f struct? #f
              100.0 100.0 0.0 0.0 en (if (> en 0.0) 200.0 0.0) 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0
              '() ct cm))
  (define (mk-min tag x y)
    (sc2-unit 1 3 tag 341 1 (sc2-point3d x y 8.0) 0.0 1.0 1.0 0 #f #f #f
              0.0 0.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0))

  ;; 1. Bunker LOAD-BUNKER (407) & own-base defensive attack-unit (<= 24t from TownHall) are BOTH P0 urgent
  ;;    survival commands, strictly beating P1 macro, P2 worker-scout, and P3 harvest under a drained governor!
  (define cc-home     (mk-u 1 18 1 32.0 32.0 #:struct? #t))
  (define bunker-ok   (mk-u 4 24 1 44.0 34.0 #:struct? #t #:cargo-taken 0 #:cargo-max 4))
  (define scv-50      (mk-u 50 45 1 29.0 31.0))
  (define scv-51      (mk-u 51 45 1 29.5 31.5))
  (define marine-4401 (mk-u 4401 48 1 43.0 33.5))
  (define marine-4402 (mk-u 4402 48 1 43.0 34.5))
  (define ling-home   (mk-u 8400 105 4 46.0 34.0)) ;; 14.1t from CC (<= 24t own-base threat!)
  (define marine-far  (mk-u 8500 48 4 125.0 125.0)) ;; > 120t from CC (distant combat)
  (define min-9001    (mk-min 9001 26.0 32.0))

  (define rush-obs
    (make-test-obs 2600 120 25 (list cc-home bunker-ok scv-50 scv-51 marine-4401 marine-4402 ling-home marine-far min-9001)))
  (define rush-cmds
    (translate-bot-actions->sc2-raw-commands
     '((worker-scout 50 143.5 143.5)
       (harvest-mineral 51 9001)
       (bunker-load 4 4401)
       (attack-unit 4402 8400))
     rush-obs))
  (define cmd-bunk407 (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 407))) rush-cmds))
  (define cmd-def-atk (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 23) (= (sc2-raw-unit-command-target-unit-tag c) 8400))) rush-cmds))
  (check-true "w8-p0-4-wire-bunker-load-407-is-p0-urgent"
              (and cmd-bunk407 (urgent-survival-cmd? cmd-bunk407) (= (wire-cmd-priority-tier cmd-bunk407) 0)))
  (check-true "w8-p0-4-wire-own-base-defensive-attack-unit-is-p0-urgent"
              (and cmd-def-atk (urgent-survival-cmd? cmd-def-atk) (= (wire-cmd-priority-tier cmd-def-atk) 0)))
  (check-true "w8-p0-4-wire-rush-suppresses-home-worker-cross-map-scout"
              (not (ormap (lambda (c)
                            (and (sc2-raw-unit-command? c)
                                 (= (sc2-raw-unit-command-ability-id c) 16)
                                 (memv 50 (sc2-raw-unit-command-unit-tags c))))
                          rush-cmds)))

  ;; Governor token-starved batch: P0 bunker-load (407) & own-base defensive attack-unit (23) MUST emit
  ;; ahead of P1 macro, P2 worker-scout, and P3 harvest even when tokens are drained to 0.0!
  (define gov-w8 (make-wire-apm-governor #:target-apm 410.0 #:hard-cap-apm 485.0))
  (define drain-p1
    (for/list ([i (in-range 12)])
      (sc2-raw-unit-command 560 #f 0 (list (+ 7000 i)) #f)))
  (void (govern-sc2-wire-actions! gov-w8 drain-p1 100)) ;; drains 24.0 burst tokens to 0.0!
  (define scout-p2 (sc2-raw-unit-command 16 (sc2-point2d 143.5 143.5) 0 '(50) #f))
  (define harv-p3  (sc2-raw-unit-command 3666 #f 9001 '(51) #f))
  (define gov-w8-out
    (govern-sc2-wire-actions! gov-w8 (list harv-p3 scout-p2 cmd-bunk407 cmd-def-atk) 104))
  (check-true "w8-p0-4-wire-gov-emits-bunker407-and-own-base-atk-over-scout-and-harvest"
              (and (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 407))) gov-w8-out)
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 23))) gov-w8-out)
                   (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 16))) gov-w8-out))
                   (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 3666))) gov-w8-out))))

  ;; 2. Full (4/4) or incomplete Bunker skips LOAD-BUNKER (407) so Marine stays free to fire attack-unit!
  (define bunker-full (mk-u 4 24 1 44.0 34.0 #:struct? #t #:cargo-taken 4 #:cargo-max 4))
  (define full-bunk-cmds
    (translate-bot-actions->sc2-raw-commands
     '((bunker-load 4 4401) (attack-unit 4401 8400))
     (make-test-obs 2610 120 25 (list cc-home bunker-full marine-4401 ling-home))))
  (check-true "w8-p0-4-wire-full-bunker-leaves-marine-free-to-attack"
              (and (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 407))) full-bunk-cmds))
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 23) (memv 4401 (sc2-raw-unit-command-unit-tags c)))) full-bunk-cmds)))

  ;; 3. Distant attack-unit (> 24t from TownHall) stays normal Tier P2 (not falsely promoted to P0)
  (define far-cmds
    (translate-bot-actions->sc2-raw-commands
     '((attack-unit 4402 8500))
     (make-test-obs 2620 120 25 (list cc-home marine-4402 marine-far))))
  (define far-atk (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 23))) far-cmds))
  (check-true "w8-p0-4-wire-distant-attack-unit-remains-p2"
              (and far-atk (not (urgent-survival-cmd? far-atk)) (= (wire-cmd-priority-tier far-atk) 2)))

  ;; 4. Peacetime worker-scout (no enemy combat near base) executes and beats trailing harvest-mineral
  (define peace-cmds
    (translate-bot-actions->sc2-raw-commands
     '((worker-scout 50 143.5 143.5) (harvest-mineral 50 9001))
     (make-test-obs 2630 120 25 (list cc-home scv-50 min-9001))))
  (check-true "w8-p0-4-wire-peacetime-worker-scout-beats-trailing-harvest"
              (and (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 16) (memv 50 (sc2-raw-unit-command-unit-tags c)))) peace-cmds)
                   (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 3666) (memv 50 (sc2-raw-unit-command-unit-tags c)))) peace-cmds))))

  ;; 5. W8-TAC-1 wire invariant: harass-workers & periodic-scout NEVER preempt combat attack-unit
  (define adept-a (mk-u 4270 311 1 75.5 79.0))
  (define adept-b (mk-u 4271 311 1 75.5 80.0))
  (define ling-mid (mk-u 8270 105 4 84.0 79.5))
  (define harass-vs-atk-cmds
    (translate-bot-actions->sc2-raw-commands
     '((harass-workers (4270 4271) 160.0 160.0)
       (periodic-scout 4271 160.0 160.0)
       (attack-unit 4270 8270)
       (attack-unit 4271 8270))
     (make-test-obs 17100 100 50 (list cc-home adept-a adept-b ling-mid))))
  (check-true "w8-tac-1-wire-combat-attack-unit-beats-harass-workers-and-periodic-scout"
              (and (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 23) (= (sc2-raw-unit-command-target-unit-tag c) 8270) (memv 4270 (sc2-raw-unit-command-unit-tags c)))) harass-vs-atk-cmds)
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 23) (= (sc2-raw-unit-command-target-unit-tag c) 8270) (memv 4271 (sc2-raw-unit-command-unit-tags c)))) harass-vs-atk-cmds)
                   (not (ormap (lambda (c)
                                 (and (sc2-raw-unit-command? c)
                                      (sc2-point2d? (sc2-raw-unit-command-target-pos c))
                                      (> (sc2-point2d-x (sc2-raw-unit-command-target-pos c)) 140.0)))
                               harass-vs-atk-cmds))))

  ;; 6. W8-TAC-4 wire invariant: Sentry Hallucination Phoenix (154) never steals Guardian Shield (76)
  ;;    or fires mid-fight (<= 16t from enemy combat with energy < 150), while peacetime Sentry still casts 154!
  (define sentry-fight (mk-u 4300 77 1 80.0 80.0 #:en 100.0))
  (define marine-near  (mk-u 8300 48 4 86.0 80.0))
  (define sentry-fight-cmds
    (translate-bot-actions->sc2-raw-commands
     '((cast-deception-and-scout-spells)
       (cast-spell 4300 guardian-shield))
     (make-test-obs 17400 100 50 (list cc-home sentry-fight marine-near))))
  (check-true "w8-tac-4-wire-guardian-shield-beats-deception-hallucination-midfight"
              (and (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 76) (memv 4300 (sc2-raw-unit-command-unit-tags c)))) sentry-fight-cmds)
                   (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 154))) sentry-fight-cmds))))
  (define sentry-peace-cmds
    (translate-bot-actions->sc2-raw-commands
     '((cast-deception-and-scout-spells))
     (make-test-obs 17420 100 50 (list cc-home sentry-fight))))
  (check-true "w8-tac-4-wire-peacetime-sentry-still-casts-hallucination-154"
              (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 154) (memv 4300 (sc2-raw-unit-command-unit-tags c)))) sentry-peace-cmds)))

(printf "-----------------------------------------------------------------\n")
(printf "Pure-Racket SC2 Protobuf + WebSocket Checks: ~a/~a passed (~a failed)\n"
        (- total-checks failed-checks)
        total-checks
        failed-checks)
(printf "=================================================================\n")

(when (> failed-checks 0)
  (exit 1))
