#lang racket/base

;; =============================================================================
;; Comprehensive Unit, Wire-Codec, Actuator & Mock-SC2 WebSocket Server Test Suite
;; for `lib/sc2-protobuf-ws.rkt` and `sim/racket-sc2-ladder-main.rkt`
;; =============================================================================

(require racket/bytes
         racket/file
         racket/list
         racket/match
         racket/math
         racket/port
         racket/set
         racket/string
         racket/tcp
         json
         "../lib/sc2-game-constants.rkt"
         (prefix-in l0: "../lib/sc2-game-constants.rkt")
         (prefix-in pl: "../lib/sc2-placement.rkt")
         "../lib/plan/situational-counter.rkt"
         "../lib/sc2-protobuf-ws.rkt"
         "../sim/racket-sc2-ladder-main.rkt"
         (only-in "../lib/sc2-typed-commands.rkt"
                  decode-typed-sc2-action
                  WireChat?
                  WireChat-team?
                  WireChat-message)
         (only-in "../lib/sc2-proto-wire-verifier.rkt"
                  verify-sc2-action-bytes)
         (only-in "../lib/plan/multitask-harass-and-proxy.rkt"
                  AUTO-TURRET-ABILITY-ID)
         (only-in "../lib/plan/wall-and-block.rkt"
                  classify-enemy-wall-state
                  EnemyWallAssessment-entry-x
                  EnemyWallAssessment-entry-y
                  plan-own-wall-integrity-defense
                  plan-expansion-and-gas-blocks
                  plan-counter-expansion-and-gas-blocks)
         (only-in "../lib/plan/creep-and-changeling.rkt"
                  make-creep-spread-tracker
                  plan-multi-highway-creep-spread
                  plan-changeling-free-unit-tactics
                  plan-dropperlord-queen-creep-expedition)
         (only-in "../ladder/build-aiarena-zip.rkt"
                  detect-build-version-metadata
                  build-bot-config-json-bytes)
         (only-in "../lib/plan/worker-saturation-policy.rkt"
                  worker-sat-state-zero-gas-rescue-rotation-idx)
         (only-in "../lib/engine/arbiter.rkt"
                  make-arbiter-ledger))

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

;; 10. Oracle Stasis Ward (2505), Pulsar Beam (2375/2376), Stasis-Frozen Worker Accounting (buff 129),
;;     Mineral-Walk HARVEST_GATHER (3666), and Worker-Drill Stack Attack
(check-eqv "ability-id-pulsar-beam" (ability-symbol->sc2-id 'pulsar-beam) 2375)
(check-eqv "ability-id-pulsar-beam-off" (ability-symbol->sc2-id 'pulsar-beam-off) 2376)
(check-eqv "ability-id-stasis-ward" (ability-symbol->sc2-id 'stasis-ward) 2505)
(check-eqv "buff-id-oracle-stasis-trap-target" (buff-id->symbol 129) 'oracle-stasis-trap-target)

(define stasis-drill-obs
  (make-test-obs
   1600 400 200
   (list ;; Nexus (59, tag 950) at (32, 32) with 16 assigned harvesters
         (make-test-unit 950 59 1 32.0 32.0 #:assigned 16 #:ideal 16)
         ;; Probe #951 (84) at (34, 32) - unfrozen
         (make-test-unit 951 84 1 34.0 32.0)
         ;; Probe #952 (84) at (59.5, 60.0) - already within 1.5 tiles of drill target (60, 60)
         (make-test-unit 952 84 1 59.5 60.0)
         ;; Probe #953 (84) at (35, 32) - frozen by Oracle Stasis Trap (buff 129)
         (make-test-unit 953 84 1 35.0 32.0 #:buffs '(129))
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
(define hyst-resat-cmds (saturate-workers-and-gas-commands (make-hysteresis-gas-obs 6120 180 125)))
(check-true "gas-auto-resaturates-when-vespene-drops-below-130G"
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
                                 (memv (sc2-raw-unit-command-ability-id c) '(80 4121 2330 2332 1372))))
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

(printf "[Wave 9] Testing W9-TAC-1 hold-posture frontline guard, W9-TAC-3 OC scan dedupe, W9-TAC-4 Changeling dedupe, & W9-TAC-5 channeling pickup guard...\n")

(let ()
  (define (w9-dist x1 y1 x2 y2) (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))
  (define (mk-u tag utype ally x y #:en [en 0.0] #:hp [hp 100.0] #:hpm [hpm 100.0]
                #:struct? [struct? #f] #:flying? [fly? #f] #:ords [ords '()])
    (sc2-unit 1 ally tag utype 1 (sc2-point3d x y 8.0) 0.0 (if struct? 2.0 0.5) 1.0 0 #f struct? fly?
              hp hpm 0.0 0.0 en (if (> en 0.0) 200.0 0.0) 0 0 #f #f #f #t #f ords 0 '() 0 0 0.0 0 0 0 0))

  ;; 1. W9-TAC-1: Under tactical-hold-posture?, idle frontline Marines/Phoenixes <= 16t from enemy combat
  ;;    are NEVER yanked back home (engage locally), fragile HTs aren't yanked or suicide-attacked,
  ;;    while distant rear units (> 16t from enemies) still rally cohesively to the hold point!
  (define cc-w9    (mk-u 1001 18 1 32.5 32.5 #:struct? #t))
  (define mar-fl   (mk-u 5011 48 1 76.5 79.0 #:hp 45.0 #:hpm 45.0))
  (define phx-fl   (mk-u 5702 78 1 78.0 82.0 #:flying? #t))
  (define ht-fl    (mk-u 5709 75 1 77.0 80.0 #:en 100.0))
  (define mar-rear (mk-u 5099 48 1 90.0 32.5 #:hp 45.0 #:hpm 45.0)) ;; > 45t from enemy, > 8t from home hold
  (define ling-e   (mk-u 8010 105 4 84.0 79.0 #:hp 35.0 #:hpm 35.0))
  (define imm-e    (mk-u 8701 83 4 82.5 80.5 #:hp 200.0 #:hpm 200.0))
  (define hold-cmds
    (translate-bot-actions->sc2-raw-commands
     '()
     (make-test-obs 12000 300 100 (list cc-w9 mar-fl phx-fl ht-fl mar-rear ling-e imm-e))
     #:tactical-posture 'hold
     #:enemy-base '(143.5 143.5)))
  (define (cmds-for-tag cs t)
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (memv t (sc2-raw-unit-command-unit-tags c)))) cs))
  (check-true "w9-tac-1-frontline-marine-engages-locally-never-yanked-home"
              (let ([cs (cmds-for-tag hold-cmds 5011)])
                (and (pair? cs)
                     (andmap (lambda (c)
                               (define p (sc2-raw-unit-command-target-pos c))
                               (and (= (sc2-raw-unit-command-ability-id c) 23)
                                    (sc2-point2d? p)
                                    (<= (w9-dist 84.0 79.0 (sc2-point2d-x p) (sc2-point2d-y p)) 10.0)))
                             cs))))
  (check-true "w9-tac-1-frontline-phoenix-never-yanked-home"
              (let ([cs (cmds-for-tag hold-cmds 5702)])
                (and (pair? cs)
                     (andmap (lambda (c)
                               (define p (sc2-raw-unit-command-target-pos c))
                               (and (sc2-point2d? p)
                                    (<= (w9-dist 82.5 80.5 (sc2-point2d-x p) (sc2-point2d-y p)) 10.0)))
                             cs))))
  (check-true "w9-tac-1-frontline-ht-neither-yanked-home-nor-suicide-attacked"
              (null? (cmds-for-tag hold-cmds 5709)))
  (check-true "w9-tac-1-rear-idle-marine-still-rallies-to-hold-point"
              (let ([cs (cmds-for-tag hold-cmds 5099)])
                (and (pair? cs)
                     (ormap (lambda (c)
                              (define p (sc2-raw-unit-command-target-pos c))
                              (and (= (sc2-raw-unit-command-ability-id c) 23)
                                   (sc2-point2d? p)
                                   (< (sc2-point2d-x p) 65.0)
                                   (< (sc2-point2d-y p) 65.0)))
                            cs))))

  ;; 2. W9-TAC-3: Orbital Command Scanner Sweep (399) deduped per OC tag & within <= 10.0t same step!
  (define oc-1 (mk-u 1001 132 1 32.0 32.0 #:en 100.0 #:struct? #t))
  (define oc-2 (mk-u 1002 132 1 52.0 32.0 #:en 75.0  #:struct? #t))
  (define scan-dedup-cmds
    (translate-bot-actions->sc2-raw-commands
     '((cast-spell 1001 scanner-sweep 81.5 80.0)
       (blind-skillshot-shimmer 1001 scanner-sweep 81.5 80.5)
       (cast-spell 1002 scanner-sweep 82.0 80.5))
     (make-test-obs 9600 200 100 (list oc-1 oc-2))))
  (check-eqv "w9-tac-3-double-scan-same-cluster-deduped-to-1"
             (count (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 399)))
                    scan-dedup-cmds)
             1)
  (define scan-two-far-cmds
    (translate-bot-actions->sc2-raw-commands
     '((cast-spell 1001 scanner-sweep 81.5 80.0)
       (cast-spell 1002 scanner-sweep 140.0 140.0))
     (make-test-obs 9604 200 100 (list oc-1 oc-2))))
  (check-eqv "w9-tac-3-two-distinct-ocs-distant-points-both-scan"
             (count (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 399)))
                    scan-two-far-cmds)
             2)

  ;; 3. W9-TAC-4: Overseer Spawn Changeling (181) deduped <= 1 per Overseer tag per step!
  (define ov-1 (mk-u 6101 129 1 80.0 80.0 #:en 100.0 #:flying? #t))
  (define ov-2 (mk-u 6102 129 1 90.0 90.0 #:en 100.0 #:flying? #t))
  (define chg-dedup-cmds
    (translate-bot-actions->sc2-raw-commands
     '((cast 6101 spawn-changeling)
       (cast-spell 6101 spawn-changeling)
       (cast-deception-and-scout-spells))
     (make-test-obs 10000 200 100 (list ov-1))))
  (check-eqv "w9-tac-4-overseer-triple-changeling-deduped-to-1"
             (count (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 181)))
                    chg-dedup-cmds)
             1)
  (define chg-two-ov-cmds
    (translate-bot-actions->sc2-raw-commands
     '((cast 6101 spawn-changeling)
       (cast 6102 spawn-changeling))
     (make-test-obs 10004 200 100 (list ov-1 ov-2))))
  (check-eqv "w9-tac-4-two-distinct-overseers-both-spawn-changeling"
             (count (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 181)))
                    chg-two-ov-cmds)
             2)

  ;; 4. W9-TAC-5-wire: Medivac LOAD_TRANSPORT (3668) never cancels channeling Ghost Snipe (2714) at safe standoff,
  ;;    still saves Ghost in immediate melee danger (<= 2.5t), and still rescues non-channeling units!
  (define ghost-chan (mk-u 7301 50 1 76.0 80.0 #:hp 25.0 #:hpm 100.0 #:en 100.0
                           #:ords (list (sc2-unit-order 2714 #f 9601 0.0))))
  (define med-7302   (mk-u 7302 54 1 75.5 80.0 #:hp 150.0 #:hpm 150.0 #:en 100.0 #:flying? #t))
  (define mar-7305   (mk-u 7305 51 1 76.0 81.0 #:hp 20.0 #:hpm 125.0))
  (define ultra-far  (mk-u 9601 109 4 84.0 80.0 #:hp 500.0 #:hpm 500.0)) ;; 8.0t standoff
  (define ultra-near (mk-u 9601 109 4 78.0 80.0 #:hp 500.0 #:hpm 500.0)) ;; 2.0t melee danger
  (define pickup-standoff-cmds
    (translate-bot-actions->sc2-raw-commands
     '((load-unit 7302 7301)
       (transport-pickup 7302 7301)
       (cast-spell 7302 load-transport 7301))
     (make-test-obs 13800 200 100 (list cc-w9 ghost-chan med-7302 ultra-far))))
  (check-true "w9-tac-5-wire-no-load-transport-on-channeling-ghost-at-standoff"
              (not (ormap (lambda (c)
                            (and (sc2-raw-unit-command? c)
                                 (memv (sc2-raw-unit-command-ability-id c) '(394 3668))
                                 (= (sc2-raw-unit-command-target-unit-tag c) 7301)))
                          pickup-standoff-cmds)))
  (define pickup-melee-cmds
    (translate-bot-actions->sc2-raw-commands
     '((load-unit 7302 7301))
     (make-test-obs 13804 200 100 (list cc-w9 ghost-chan med-7302 ultra-near))))
  (check-true "w9-tac-5-wire-emergency-pickup-allowed-when-enemy-in-melee-range"
              (ormap (lambda (c)
                       (and (sc2-raw-unit-command? c)
                            (= (sc2-raw-unit-command-ability-id c) 3668)
                            (= (sc2-raw-unit-command-target-unit-tag c) 7301)))
                     pickup-melee-cmds))
  (define pickup-normal-cmds
    (translate-bot-actions->sc2-raw-commands
     '((load-unit 7302 7305))
     (make-test-obs 13808 200 100 (list cc-w9 mar-7305 med-7302 ultra-far))))
  (check-true "w9-tac-5-wire-normal-nonchanneling-unit-still-picked-up"
              (ormap (lambda (c)
                       (and (sc2-raw-unit-command? c)
                            (= (sc2-raw-unit-command-ability-id c) 3668)
                            (= (sc2-raw-unit-command-target-unit-tag c) 7305)))
                     pickup-normal-cmds)))

(printf "[Wave 10] Testing W10-TAC-3 race-specific transport unload (396/913/1408) & W10-TAC-6 Observer defense preservation...\n")

(let ()
  (define (mk-u tag utype ally x y #:flying? [fly? #f] #:cloak [clk 0]
                #:cargo-taken [ct 0] #:cargo-max [cm 0] #:pax [pax '()])
    (sc2-unit 1 ally tag utype 1 (sc2-point3d x y 8.0) 0.0 0.625 1.0 clk #f #f fly?
              100.0 100.0 0.0 0.0 50.0 200.0 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0
              pax ct cm))

  ;; 1. W10-TAC-3: transport-juggle emits race-specific 396/913/1408 (NEVER generic 3669) and skips empty transports!
  (define med-loaded   (mk-u 5101 54  1 82.0 80.0 #:flying? #t #:cargo-taken 2 #:cargo-max 8))
  (define prism-loaded (mk-u 5102 81  1 82.0 80.0 #:flying? #t #:cargo-taken 4 #:cargo-max 8))
  (define drop-loaded  (mk-u 5103 893 1 82.0 80.0 #:flying? #t #:cargo-taken 4 #:cargo-max 8))
  (define med-empty    (mk-u 5104 54  1 82.0 80.0 #:flying? #t #:cargo-taken 0 #:cargo-max 8))
  (define tr-cmds
    (translate-bot-actions->sc2-raw-commands
     '((transport-juggle 5101 76.0 80.0)
       (transport-juggle 5102 76.0 82.0)
       (transport-juggle 5103 76.0 84.0)
       (transport-juggle 5104 76.0 86.0))
     (make-test-obs 13800 200 100 (list med-loaded prism-loaded drop-loaded med-empty))))
  (check-true "w10-tac-3-medivac-juggle-emits-396-not-3669"
              (and (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 396) (equal? (sc2-raw-unit-command-unit-tags c) '(5101)))) tr-cmds)
                   (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 3669))) tr-cmds))))
  (check-true "w10-tac-3-warp-prism-juggle-emits-913"
              (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 913) (equal? (sc2-raw-unit-command-unit-tags c) '(5102)))) tr-cmds))
  (check-true "w10-tac-3-dropperlord-juggle-emits-1408"
              (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1408) (equal? (sc2-raw-unit-command-unit-tags c) '(5103)))) tr-cmds))
  (check-true "w10-tac-3-empty-medivac-emits-zero-unload-spam"
              (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (memv 5104 (sc2-raw-unit-command-unit-tags c)))) tr-cmds)))

  ;; 2. W10-TAC-6: cast-deception-and-scout-spells & scout-sector NEVER overwrite a commanded Observer
  ;;    and NEVER send an Observer (82) cross-map when cloaked/burrowed enemies are present!
  (define obs-5001  (mk-u 5001 82 1 52.0 34.0 #:flying? #t))
  (define chg-5009  (mk-u 5009 15 1 60.0 60.0))
  (define dt-cloak  (mk-u 8001 76 4 30.0 32.0 #:cloak 1))
  (define banshee-e (mk-u 8002 55 4 40.0 40.0 #:flying? #t))
  ;; (a) Commanded Observer is NEVER overwritten to enemy main even without cloaked enemies
  (define obs-cmd-cmds
    (translate-bot-actions->sc2-raw-commands
     '((move 5001 44.4 32.04)
       (cast-deception-and-scout-spells))
     (make-test-obs 10000 200 100 (list obs-5001))
     #:enemy-base '(160.0 160.0)))
  (check-true "w10-tac-6-commanded-observer-never-overwritten-by-deception-scout"
              (and (= (count (lambda (c) (and (sc2-raw-unit-command? c) (memv 5001 (sc2-raw-unit-command-unit-tags c)))) obs-cmd-cmds) 1)
                   (not (ormap (lambda (c)
                                 (and (sc2-raw-unit-command? c)
                                      (memv 5001 (sc2-raw-unit-command-unit-tags c))
                                      (sc2-point2d? (sc2-raw-unit-command-target-pos c))
                                      (> (sc2-point2d-x (sc2-raw-unit-command-target-pos c)) 100.0)))
                               obs-cmd-cmds))))
  ;; (b) Idle Observer under cloaked DT attack is NOT sent to enemy main (instead flies to detect DT at home, while Changeling still scouts)
  (define obs-dt-cmds
    (translate-bot-actions->sc2-raw-commands
     '((cast-deception-and-scout-spells))
     (make-test-obs 10004 200 100 (list obs-5001 chg-5009 dt-cloak))
     #:enemy-base '(160.0 160.0)))
  (check-true "w10-tac-6-idle-observer-stays-home-under-cloaked-dt-attack"
              (and (not (ormap (lambda (c)
                                 (and (sc2-raw-unit-command? c)
                                      (memv 5001 (sc2-raw-unit-command-unit-tags c))
                                      (sc2-point2d? (sc2-raw-unit-command-target-pos c))
                                      (> (sc2-point2d-x (sc2-raw-unit-command-target-pos c)) 100.0)))
                               obs-dt-cmds))
                   (ormap (lambda (c)
                            (and (sc2-raw-unit-command? c)
                                 (= (sc2-raw-unit-command-ability-id c) 16)
                                 (memv 5001 (sc2-raw-unit-command-unit-tags c))
                                 (sc2-point2d? (sc2-raw-unit-command-target-pos c))
                                 (<= (sqrt (+ (sqr (- (sc2-point2d-x (sc2-raw-unit-command-target-pos c)) 30.0))
                                              (sqr (- (sc2-point2d-y (sc2-raw-unit-command-target-pos c)) 32.0))))
                                     10.5)))
                          obs-dt-cmds)))
  (check-true "w10-tac-6-changeling-still-scouts-under-cloaked-dt-attack"
              (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 16) (memv 5009 (sc2-raw-unit-command-unit-tags c)))) obs-dt-cmds))
  ;; (c) scout-sector skips Observer when enemy Banshee cloak threat is visible
  (define obs-sec-cmds
    (translate-bot-actions->sc2-raw-commands
     '((scout-sector 160.0 160.0))
     (make-test-obs 10008 200 100 (list obs-5001 banshee-e))
     #:enemy-base '(160.0 160.0)))
  (check-true "w10-tac-6-scout-sector-never-steals-observer-under-banshee-threat"
              (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (memv 5001 (sc2-raw-unit-command-unit-tags c)))) obs-sec-cmds)))
  ;; (d) Peacetime idle Observer with NO cloaked threat still scouts enemy base normally
  (define obs-peace-cmds
    (translate-bot-actions->sc2-raw-commands
     '((cast-deception-and-scout-spells))
     (make-test-obs 10012 200 100 (list obs-5001))
     #:enemy-base '(160.0 160.0)))
  (check-true "w10-tac-6-peacetime-idle-observer-still-scouts"
              (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 16) (memv 5001 (sc2-raw-unit-command-unit-tags c)))) obs-peace-cmds)))

;; =============================================================================
;; Wave 11 Regression Checks:
;;   - W11-P0-4-wire (`w11-tac-3` & `w11-tac-4`): situational-counter live-obs
;;     hardcoded-coord/dummy-tag-1 suppression + Overseer/Observer stealth intercept
;;   - W11-P0-3-wire: WarpGate multi-gate batching, grid safety, Chronoboost CD,
;;     action-error & warp_gate_count reconciliation, and governor-drop CD release
;; =============================================================================
(printf "[Wave 11] Testing W11-P0-4-wire (situational-counter live-obs + Overseer stealth intercept) & W11-P0-3-wire (WarpGate batching)...\n")
(let ()
  (define (w11-dist x1 y1 x2 y2)
    (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))
  (define (mk-w11-u tag utype all x y
                    #:hp [hp 150.0] #:en [en 0.0] #:flying? [fly? #f]
                    #:cloak [cl 0] #:burrowed? [bur? #f] #:powered? [pow? #t]
                    #:buffs [buffs '()] #:rad [rad 0.75])
    (sc2-unit 1 all tag utype (if (= all 1) 1 2)
              (sc2-point3d x y 8.0) 0.0 rad 1.0 cl #f #f #f
              hp hp 0.0 0.0 en 200.0 0 0 fly? bur?
              #f (if pow? #t #f) #f '() 0 buffs
              0 0 0.0 0 0 0 0))

  ;; 1. W11-P0-4-wire (`w11-tac-3`): situational-counter suppresses dummy-tag-1 & hardcoded (90,90)
  ;;    casts on live observations while preserving real-ally-tag abilities (`battery-overcharge`)
  ;;    and NEVER emitting `morph-oversight-mode` / `morph-observer-siege-mode` on cloak threats.
  (define live-viper-plan
    (evaluate-situational-counter-plan
     (hash 'frame 12200 'race 'Zerg 'enemy-race 'Terran
           'raw-mineral-harvesters 16 'ideal-mineral-harvesters 16 'mineral-patches '()
           'ally-units (list (hash 'id 6301 'type 'viper 'x 74.0 'y 80.0 'energy 175.0))
           'ally-buildings (list (hash 'id 1001 'type 'hatchery 'x 32.5 'y 32.5 'build-progress 1.0))
           'enemy-units (list (hash 'id 9301 'type 'viking-fighter 'x 80.0 'y 78.5)
                              (hash 'id 9302 'type 'viking-fighter 'x 80.0 'y 79.5)
                              (hash 'id 9303 'type 'viking-fighter 'x 80.0 'y 80.5)))
     'Zerg 'Terran 12200))
  (check-true "w11-tac-3-live-obs-zero-dummy-tag-1-parasitic-bomb"
              (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (third a) 'parasitic-bomb)))
                          (situational-counter-plan-ability-actions live-viper-plan))))

  (define live-ravager-plan
    (evaluate-situational-counter-plan
     (hash 'frame 14000 'race 'Zerg 'enemy-race 'Terran
           'raw-mineral-harvesters 16 'ideal-mineral-harvesters 16 'mineral-patches '()
           'ally-units (list (hash 'id 6321 'type 'ravager 'x 108.0 'y 115.0 'energy 0.0))
           'ally-buildings (list (hash 'id 1001 'type 'hatchery 'x 32.5 'y 32.5 'build-progress 1.0))
           'enemy-units (list (hash 'id 9321 'type 'siege-tank-sieged 'x 125.0 'y 115.0)
                              (hash 'id 9322 'type 'siege-tank-sieged 'x 125.0 'y 117.0)
                              (hash 'id 9323 'type 'siege-tank-sieged 'x 125.0 'y 119.0)))
     'Zerg 'Terran 14000))
  (check-true "w11-tac-3-live-obs-zero-hardcoded-90-90-corrosive-bile"
              (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell) (eq? (third a) 'corrosive-bile)))
                          (situational-counter-plan-ability-actions live-ravager-plan))))

  (define live-overseer-cloak-plan
    (evaluate-situational-counter-plan
     (hash 'frame 11000 'race 'Zerg 'enemy-race 'Terran
           'raw-mineral-harvesters 16 'ideal-mineral-harvesters 16 'mineral-patches '()
           'ally-units (list (hash 'id 6401 'type 'overseer 'x 60.0 'y 60.0 'energy 0.0))
           'ally-buildings (list (hash 'id 1001 'type 'hatchery 'x 32.5 'y 32.5 'build-progress 1.0))
           'enemy-units (list (hash 'id 9401 'type 'banshee 'x 115.0 'y 115.0 'cloaked #t)))
     'Zerg 'Terran 11000))
  (check-true "w11-tac-4-situational-counter-never-emits-oversight-mode-on-cloak"
              (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell)
                                           (memq (third a) '(morph-oversight-mode morph-observer-siege-mode))))
                          (situational-counter-plan-ability-actions live-overseer-cloak-plan))))
  (check-true "w11-tac-4-standalone-selector-never-emits-oversight-mode-on-cloak"
              (not (ormap (lambda (a) (and (pair? a) (eq? (car a) 'cast-spell)
                                           (memq (third a) '(morph-oversight-mode morph-observer-siege-mode))))
                          (select-situational-ability-actions
                           'enemy-cloaked-or-burrowed-threat '(banshee)
                           (list (hash 'id 6401 'type 'overseer 'energy 0.0)
                                 (hash 'id 6402 'type 'observer 'energy 0.0))))))

  ;; Real allied-tag abilities (`battery-overcharge`) remain active on live obs
  (define live-battery-plan
    (evaluate-situational-counter-plan
     (hash 'frame 3200 'race 'Protoss 'enemy-race 'Protoss
           'raw-mineral-harvesters 16 'ideal-mineral-harvesters 16 'mineral-patches '()
           'proxy-detected? #t
           'ally-units '()
           'ally-buildings (list (hash 'id 5001 'type 'nexus 'x 32.5 'y 32.5 'energy 100.0 'build-progress 1.0)
                                 (hash 'id 5002 'type 'shield-battery 'x 36.0 'y 36.0 'energy 100.0 'build-progress 1.0))
           'enemy-buildings (list (hash 'id 9001 'type 'photon-cannon 'x 44.0 'y 44.0)))
     'Protoss 'Protoss 3200))
  (check-true "w11-tac-3-live-obs-preserves-real-tag-battery-overcharge"
              (not (not (ormap (lambda (a) (equal? a '(cast-spell 5001 battery-overcharge 5002)))
                               (situational-counter-plan-ability-actions live-battery-plan)))))

  ;; 2. W11-P0-4-wire (`w11-tac-4`): Wire suppresses 3743/181 and flies Overseer directly to
  ;;    uncovered Cloaked Banshee (115,115) / (35,35), and unmorphs OverseerSiege (1912) via 3745!
  (define ov-a-cmds
    (translate-bot-actions->sc2-raw-commands
     '((cast-spell 6401 morph-oversight-mode))
     (make-test-obs 11000 300 200
                    (list (mk-w11-u 1001 86 1 32.5 32.5 #:hp 1500.0 #:rad 2.75)
                          (mk-w11-u 6401 129 1 60.0 60.0 #:hp 200.0 #:en 0.0 #:flying? #t)
                          (mk-w11-u 6410 107 1 112.0 113.0 #:hp 90.0)
                          (mk-w11-u 9401 55 4 115.0 115.0 #:hp 140.0 #:flying? #t #:cloak 1)))))
  (check-true "w11-tac-4-wire-0en-overseer-skips-3743-and-moves-to-cloaked-banshee"
              (and (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 3743))) ov-a-cmds))
                   (ormap (lambda (c)
                            (and (sc2-raw-unit-command? c)
                                 (= (sc2-raw-unit-command-ability-id c) 16)
                                 (memv 6401 (sc2-raw-unit-command-unit-tags c))
                                 (sc2-point2d? (sc2-raw-unit-command-target-pos c))
                                 (<= (w11-dist (sc2-point2d-x (sc2-raw-unit-command-target-pos c))
                                               (sc2-point2d-y (sc2-raw-unit-command-target-pos c))
                                               115.0 115.0)
                                     15.0)))
                          ov-a-cmds)))

  (define ov-b-cmds
    (translate-bot-actions->sc2-raw-commands
     '((cast 6421 spawn-changeling 160.0 160.0)
       (cast-spell 6421 morph-oversight-mode)
       (cast-deception-and-scout-spells))
     (make-test-obs 11004 300 200
                    (list (mk-w11-u 1001 86 1 32.5 32.5 #:hp 1500.0 #:rad 2.75)
                          (mk-w11-u 6421 129 1 60.0 60.0 #:hp 200.0 #:en 50.0 #:flying? #t)
                          (mk-w11-u 6430 107 1 36.0 34.0 #:hp 90.0)
                          (mk-w11-u 9421 55 4 35.0 35.0 #:hp 140.0 #:flying? #t #:cloak 1)))))
  (check-true "w11-tac-4-wire-50en-overseer-skips-181-3743-and-moves-home-to-banshee"
              (and (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (memv (sc2-raw-unit-command-ability-id c) '(181 3743)))) ov-b-cmds))
                   (ormap (lambda (c)
                            (and (sc2-raw-unit-command? c)
                                 (= (sc2-raw-unit-command-ability-id c) 16)
                                 (memv 6421 (sc2-raw-unit-command-unit-tags c))
                                 (sc2-point2d? (sc2-raw-unit-command-target-pos c))
                                 (<= (w11-dist (sc2-point2d-x (sc2-raw-unit-command-target-pos c))
                                               (sc2-point2d-y (sc2-raw-unit-command-target-pos c))
                                               35.0 35.0)
                                     15.0)))
                          ov-b-cmds)))

  (define ov-siege-cmds
    (translate-bot-actions->sc2-raw-commands
     '()
     (make-test-obs 11008 300 200
                    (list (mk-w11-u 1001 86 1 32.5 32.5 #:hp 1500.0 #:rad 2.75)
                          (mk-w11-u 6441 1912 1 60.0 60.0 #:hp 200.0 #:flying? #t)
                          (mk-w11-u 9441 55 4 115.0 115.0 #:hp 140.0 #:flying? #t #:cloak 1)))))
  (check-true "w11-tac-4-wire-unmorphs-sieged-overseer-1912-via-3745"
              (ormap (lambda (c)
                       (and (sc2-raw-unit-command? c)
                            (= (sc2-raw-unit-command-ability-id c) 3745)
                            (memv 6441 (sc2-raw-unit-command-unit-tags c))))
                     ov-siege-cmds))

  (define ov-peace-cmds
    (translate-bot-actions->sc2-raw-commands
     '((cast-spell 6450 morph-oversight-mode))
     (make-test-obs 11012 300 200
                    (list (mk-w11-u 6450 129 1 60.0 60.0 #:hp 200.0 #:flying? #t)))))
  (check-true "w11-tac-4-peacetime-explicit-oversight-3743-still-allowed"
              (ormap (lambda (c)
                       (and (sc2-raw-unit-command? c)
                            (= (sc2-raw-unit-command-ability-id c) 3743)
                            (memv 6450 (sc2-raw-unit-command-unit-tags c))))
                     ov-peace-cmds))

  ;; 3. W11-P0-3-wire: WarpGate multi-gate batching, grid safety, Chronoboost CD,
  ;;    governor-drop CD release, action-error & player_common.warp_gate_count reconciliation!
  ;; Build a 100x100 8bpp pathing+placement grid where x < 40 is unpathable cliff (0) and x >= 40 is open (1)
  (define w11-grid-bytes (make-bytes (* 100 100) 0))
  (for* ([y (in-range 100)] [x (in-range 40 100)])
    (bytes-set! w11-grid-bytes (+ x (* y 100)) 1))
  (define w11-grid (sc2-image-grid 8 100 100 w11-grid-bytes #f #f))
  (define w11-gi (sc2-game-info "TestMap" "" '() '(100 . 100) '(0 0 100 100) '() w11-grid #f w11-grid))
  (define w11-wg-units
    (list (mk-w11-u 7100 59 1 46.0 50.0 #:hp 1000.0 #:rad 2.75) ;; Nexus
          (mk-w11-u 7110 60 1 40.5 50.0 #:hp 200.0 #:rad 1.0)   ;; Pylon on cliff edge x=40.5
          (mk-w11-u 7101 133 1 44.0 44.0 #:hp 500.0 #:rad 1.5 #:buffs '(281)) ;; Chronoboosted WG
          (mk-w11-u 7102 133 1 47.0 44.0 #:hp 500.0 #:rad 1.5)
          (mk-w11-u 7103 133 1 50.0 44.0 #:hp 500.0 #:rad 1.5)
          (mk-w11-u 7104 133 1 53.0 44.0 #:hp 500.0 #:rad 1.5)
          (mk-w11-u 7105 62  1 56.0 44.0 #:hp 500.0 #:rad 1.5))) ;; Un-morphed Gateway
  (define w11-wg-obs1
    (sc2-observation 2000 (sc2-player-common 1 800 400 50 90 20 30 0 10 4 0)
                     w11-wg-units '(84)
                     (list (sc2-power-source (sc2-point3d 40.5 50.0 8.0) 6.5 7110))
                     (sc2-point3d 46.0 50.0 0.0) '() '() '() '() '() '()))
  (define wg-batch-cmds
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1414)))
            (translate-bot-actions->sc2-raw-commands
             '((train stalker) (train stalker) (train stalker) (train stalker))
             w11-wg-obs1
             #:game-info w11-gi)))
  (define wg-batch-tags (apply append (map sc2-raw-unit-command-unit-tags wg-batch-cmds)))
  (define wg-batch-pts (map sc2-raw-unit-command-target-pos wg-batch-cmds))
  (check-eqv "w11-p0-3-4-ready-warpgates-batch-all-4-stalkers-in-one-step"
             (length wg-batch-cmds) 4)
  (check-true "w11-p0-3-warpgates-preferred-over-unmorphed-gateway-7105"
              (and (= (length (remove-duplicates wg-batch-tags)) 4)
                   (not (memv 7105 wg-batch-tags))))
  (check-true "w11-p0-3-all-4-warp-spots-respect-cliff-grid-and-1.5t-separation"
              (and (andmap (lambda (p) (and (sc2-point2d? p) (>= (sc2-point2d-x p) 40.45))) wg-batch-pts)
                   (for*/and ([i (in-range (length wg-batch-pts))]
                              [j (in-range (add1 i) (length wg-batch-pts))])
                     (define p1 (list-ref wg-batch-pts i))
                     (define p2 (list-ref wg-batch-pts j))
                     (> (w11-dist (sc2-point2d-x p1) (sc2-point2d-y p1)
                                  (sc2-point2d-x p2) (sc2-point2d-y p2))
                        1.5))))

  ;; Chronoboosted WG 7101 finishes ~343 loops (ready at loop 2350), while non-chrono 7102..7104 wait until 2515!
  (define w11-wg-obs-chrono
    (sc2-observation 2350 (sc2-player-common 1 800 400 50 90 20 30 0 10 0 0)
                     w11-wg-units '(84)
                     (list (sc2-power-source (sc2-point3d 40.5 50.0 8.0) 6.5 7110))
                     (sc2-point3d 46.0 50.0 0.0) '() '() '() '() '() '()))
  (define wg-chrono-cmds
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1414)))
            (translate-bot-actions->sc2-raw-commands '((train stalker)) w11-wg-obs-chrono #:game-info w11-gi)))
  (check-true "w11-p0-3-chronoboosted-warpgate-7101-ready-early-at-350-loops"
              (and (= (length wg-chrono-cmds) 1)
                   (equal? (sc2-raw-unit-command-unit-tags (first wg-chrono-cmds)) '(7101))))

  ;; Action-error on WG 7102 (`ability-id 1414, result 47`) immediately unlocks WG 7102!
  (define w11-wg-obs-err
    (sc2-observation 2354 (sc2-player-common 1 800 400 50 90 20 30 0 10 0 0)
                     w11-wg-units '(84)
                     (list (sc2-power-source (sc2-point3d 40.5 50.0 8.0) 6.5 7110))
                     (sc2-point3d 46.0 50.0 0.0) '() '() '()
                     (list (hash 'unit-tag 7102 'ability-id 1414 'result 47))
                     '() '()))
  (define wg-err-cmds
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1414)))
            (translate-bot-actions->sc2-raw-commands '((train stalker)) w11-wg-obs-err #:game-info w11-gi)))
  (check-true "w11-p0-3-action-error-unlocks-rejected-warpgate-7102-immediately"
              (and (= (length wg-err-cmds) 1)
                   (equal? (sc2-raw-unit-command-unit-tags (first wg-err-cmds)) '(7102))))

  ;; Ground-truth `player_common.warp_gate_count = 2` unlocks 2 still-locked WarpGates (7103 & 7104)!
  (define w11-wg-obs-pc
    (sc2-observation 2358 (sc2-player-common 1 800 400 50 90 20 30 0 10 2 0)
                     w11-wg-units '(84)
                     (list (sc2-power-source (sc2-point3d 40.5 50.0 8.0) 6.5 7110))
                     (sc2-point3d 46.0 50.0 0.0) '() '() '() '() '() '()))
  (define wg-pc-cmds
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1414)))
            (translate-bot-actions->sc2-raw-commands '((train stalker) (train stalker)) w11-wg-obs-pc #:game-info w11-gi)))
  (check-eqv "w11-p0-3-player-common-warp-gate-count-reconciles-2-ready-gates"
             (length wg-pc-cmds) 2)

  ;; Governor-dropped warp-in commands release their WarpGate cooldown immediately!
  (define wg-gov (make-wire-apm-governor #:target-apm 410.0 #:hard-cap-apm 485.0))
  ;; Drain 22 of 24 initial tokens at loop 2998 via 11 non-coalescable P1 cmds -> ~2.6 tokens & recent P1 at loop 3000
  (void (govern-sc2-wire-actions!
         wg-gov
         (for/list ([i (in-range 11)])
           (sc2-raw-unit-command 1006 #f 0 (list (+ 9500 i)) #f))
         2998))
  (define w11-wg-obs-gov
    (sc2-observation 3000 (sc2-player-common 1 800 400 50 90 20 30 0 10 0 0)
                     w11-wg-units '(84)
                     (list (sc2-power-source (sc2-point3d 40.5 50.0 8.0) 6.5 7110))
                     (sc2-point3d 46.0 50.0 0.0) '() '() '() '() '() '()))
  (define wg-raw-4
    (translate-bot-actions->sc2-raw-commands
     '((train stalker) (train stalker) (train stalker) (train stalker))
     w11-wg-obs-gov #:game-info w11-gi))
  (define wg-gov-emitted (govern-sc2-wire-actions! wg-gov wg-raw-4 3000))
  (define wg-gov-emitted-cnt
    (count (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1414)))
           wg-gov-emitted))
  ;; Next step at 3004: the dropped WarpGates must STILL be ready (NOT locked out for 515 loops!)
  (define w11-wg-obs-gov-next
    (sc2-observation 3004 (sc2-player-common 1 800 400 50 90 20 30 0 10 0 0)
                     w11-wg-units '(84)
                     (list (sc2-power-source (sc2-point3d 40.5 50.0 8.0) 6.5 7110))
                     (sc2-point3d 46.0 50.0 0.0) '() '() '() '() '() '()))
  (define wg-retry-cmds
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1414)))
            (translate-bot-actions->sc2-raw-commands
             '((train stalker) (train stalker) (train stalker) (train stalker))
             w11-wg-obs-gov-next #:game-info w11-gi)))
  (check-true "w11-p0-3-governor-dropped-warpgates-unlock-immediately-for-next-step"
              (and (< wg-gov-emitted-cnt 4)
                   (= (+ wg-gov-emitted-cnt (length wg-retry-cmds)) 4)))

  ;; Phasing WarpPrism (`radius 3.75`) keeps warp-in inside <= 3.1t radius
  (define w11-prism-obs
    (sc2-observation 3600 (sc2-player-common 1 400 200 50 90 20 30 0 10 1 0)
                     (list (mk-w11-u 7201 133 1 44.0 44.0 #:hp 500.0 #:rad 1.5)
                           (mk-w11-u 7202 136 1 60.0 60.0 #:hp 100.0 #:flying? #t))
                     '(84)
                     (list (sc2-power-source (sc2-point3d 60.0 60.0 8.0) 3.75 7202))
                     (sc2-point3d 60.0 60.0 0.0) '() '() '() '() '() '()))
  (define wg-prism-cmds
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1414)))
            (translate-bot-actions->sc2-raw-commands '((train stalker)) w11-prism-obs)))
  (check-true "w11-p0-3-phasing-warp-prism-respects-3.75-power-radius"
              (and (= (length wg-prism-cmds) 1)
                   (let ([p (sc2-raw-unit-command-target-pos (first wg-prism-cmds))])
                     (and (sc2-point2d? p)
                          (<= (w11-dist (sc2-point2d-x p) (sc2-point2d-y p) 60.0 60.0) 3.15))))))

;; =============================================================================
;; Wave 12 Regression Checks (`W12-P0-3-wire`):
;;   - Early-rush placement stall fixes (`#36 P v 12PoolBot`, `#35 T v 12PoolBot`):
;;     build-priority strictly ahead of `pull-workers-attack`, contested-site
;;     in-main safe fallback, enemy ground unit avoidance in spiral search, and
;;     terrain/enemy-aware `emergency-inmain-supply-anchor`.
;;   - Defense-in-depth wire dedupe & P0 legality (`w12-tac-1..4`):
;;     Oracle Revelation `2146` (buff=49 skip + single-cast + weaponless beam-off
;;     Oracle no-ATTACK), Cyclone Lock-On `2350` (buff=116 skip + single-cast),
;;     Viking `405` dedupe + coalescing, and Void Ray `2393` / Reaper `2588` P0 legality.
;; =============================================================================
(printf "[Wave 12] Testing W12-P0-3-wire (early-rush placement stall fixes + 2146/2350/405/2393/2588 wire dedupe & legality)...\n")
(let ()
  (define (w12-dist x1 y1 x2 y2)
    (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))
  (define (mk-w12-u tag utype all x y
                    #:hp [hp 100.0] #:en [en 100.0] #:flying? [fly? #f]
                    #:cloak [cl 0] #:buffs [buffs '()] #:rad [rad 0.5])
    (sc2-unit 1 all tag utype (if (= all 1) 1 2)
              (sc2-point3d x y 8.0) 0.0 rad 1.0 cl #f #f #f
              hp hp 0.0 0.0 en 200.0 0 0 fly? #f
              #f #t #f '() 0 buffs
              0 0 0.0 0 0 0 0))

  ;; 1a. Build priority runs strictly ahead of `pull-workers-attack` so a 12-Pool worker pull
  ;;     NEVER starves emergency Pylon/SupplyDepot/Bunker placement of a builder worker!
  (define rush-probes
    (list (mk-w12-u 7301 84 1 30.0 32.0 #:hp 20.0)
          (mk-w12-u 7302 84 1 30.5 32.5 #:hp 20.0)
          (mk-w12-u 7303 84 1 31.0 32.0 #:hp 20.0)
          (mk-w12-u 7304 84 1 31.5 32.5 #:hp 20.0)))
  (define rush-lings
    (for/list ([i (in-range 6)])
      (mk-w12-u (+ 8301 i) 105 4 (+ 47.5 (* 0.3 i)) (+ 47.5 (* 0.3 i)) #:hp 35.0)))
  (define rush-mins
    (for/list ([i (in-range 6)])
      (mk-w12-u (+ 9301 i) 341 3 25.5 (+ 29.0 (* 1.2 i)) #:rad 0.75)))
  (define rush-p-obs
    (make-test-obs 1900 440 40
                   (append (list (mk-w12-u 7300 59 1 32.5 32.5 #:hp 1000.0 #:rad 2.75))
                           rush-probes rush-lings rush-mins)))
  (define rush-p-cmds
    (translate-bot-actions->sc2-raw-commands
     '((pull-workers-attack (7301 7302 7303 7304) 8301 47.5 47.5)
       (build pylon 48.0 48.0))
     rush-p-obs))
  (define pylon-build-cmd
    (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 881)))
           rush-p-cmds))
  (define pull-atk-tags
    (apply append
           (for/list ([c (in-list rush-p-cmds)]
                      #:when (and (sc2-raw-unit-command? c)
                                  (= (sc2-raw-unit-command-ability-id c) 23)))
             (sc2-raw-unit-command-unit-tags c))))
  (check-true "w12-p0-3-build-pylon-claims-builder-before-pull-workers-attack"
              (and (sc2-raw-unit-command? pylon-build-cmd)
                   (= (length (sc2-raw-unit-command-unit-tags pylon-build-cmd)) 1)
                   (= (length pull-atk-tags) 3)
                   (not (memv (first (sc2-raw-unit-command-unit-tags pylon-build-cmd)) pull-atk-tags))))
  (check-true "w12-p0-3-contested-rush-pylon-falls-back-to-safe-inmain-spot"
              (and (sc2-raw-unit-command? pylon-build-cmd)
                   (let ([pt (sc2-raw-unit-command-target-pos pylon-build-cmd)])
                     (and (sc2-point2d? pt)
                          (> (w12-dist (sc2-point2d-x pt) (sc2-point2d-y pt) 48.0 48.0) 5.0)
                          (<= (w12-dist (sc2-point2d-x pt) (sc2-point2d-y pt) 32.5 32.5) 16.0)))))

  ;; 1b. Contested Terran Supply Depot under 12-Pool rush falls back safely in-main AND claims 1 SCV ahead of pull!
  (define rush-scvs
    (list (mk-w12-u 7311 45 1 30.0 32.0 #:hp 45.0)
          (mk-w12-u 7312 45 1 30.5 32.5 #:hp 45.0)
          (mk-w12-u 7313 45 1 31.0 32.0 #:hp 45.0)))
  (define rush-t-obs
    (make-test-obs 1904 395 40
                   (append (list (mk-w12-u 7310 18 1 32.5 32.5 #:hp 1500.0 #:rad 2.75))
                           rush-scvs rush-lings rush-mins)))
  (define rush-t-cmds
    (translate-bot-actions->sc2-raw-commands
     '((pull-workers-attack (7311 7312 7313) 8301 47.5 47.5)
       (build supply-depot 48.0 48.0))
     rush-t-obs))
  (define depot-build-cmd
    (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 319)))
           rush-t-cmds))
  (check-true "w12-p0-3-contested-rush-supply-depot-builds-safely-inmain-before-pull"
              (and (sc2-raw-unit-command? depot-build-cmd)
                   (let ([pt (sc2-raw-unit-command-target-pos depot-build-cmd)])
                     (and (sc2-point2d? pt)
                          (> (w12-dist (sc2-point2d-x pt) (sc2-point2d-y pt) 48.0 48.0) 5.0)
                          (<= (w12-dist (sc2-point2d-x pt) (sc2-point2d-y pt) 32.5 32.5) 16.0)))))

  ;; 1c. `collect-spiral-candidates` excludes tiles directly occupied by live non-flying enemy units!
  (define spiral-vs-ling
    (collect-spiral-candidates 48.0 48.0 rush-lings
                               #:min-spacing 2.0 #:max-radius 6.0 #:step 1.0 #:limit 6 #:bldg-sym 'pylon))
  (check-true "w12-p0-3-spiral-candidates-skip-enemy-ground-occupied-tiles"
              (and (pair? spiral-vs-ling)
                   (for/and ([pt (in-list spiral-vs-ling)])
                     (for/and ([e (in-list rush-lings)])
                       (define ep (sc2-unit-pos e))
                       (> (w12-dist (sc2-point2d-x pt) (sc2-point2d-y pt)
                                    (sc2-point3d-x ep) (sc2-point3d-y ep))
                          2.0)))))

  ;; 1d. `pl:emergency-inmain-supply-anchor` avoids unbuildable cliff regions and enemy rush positions!
  (define w12-map-grids
    (hash 'width 80 'height 80
          'pathing-ref (lambda (x y) (if (>= y 30) 1 0))
          'placement-ref (lambda (x y) (if (>= y 30) 1 0))
          'height-ref (lambda (x y) 10.0)))
  (define-values (em-ax em-ay)
    (pl:emergency-inmain-supply-anchor
     32.5 32.5 52.0 32.5 0
     (list (hash 'x 25.5 'y 32.5))
     #:enemy-pts '((38.5 . 32.5))
     #:map-grids w12-map-grids))
  (check-true "w12-p0-3-emergency-inmain-supply-anchor-avoids-enemies-and-cliffs"
              (and (>= em-ay 31.0)
                   (> (w12-dist em-ax em-ay 38.5 32.5) 5.5)))

  ;; 2a. `w12-tac-1` wire defense-in-depth: Oracle Revelation (2146) single-cast dedupe,
  ;;     buff=49 skip, weaponless beam-off Oracle no-ATTACK (23), beam-on Oracle ATTACK allowed!
  (define ora-7401 (mk-w12-u 7401 495 1 75.0 80.0 #:hp 100.0 #:en 100.0 #:flying? #t))
  (define dt-unrev (mk-w12-u 8401 76  4 79.0 80.0 #:hp 40.0 #:cloak 1))
  (define dt-rev49 (mk-w12-u 8401 76  4 79.0 80.0 #:hp 40.0 #:cloak 2 #:buffs '(49)))
  (define scv-8402 (mk-w12-u 8402 45  4 78.0 80.0 #:hp 45.0))
  (define rev-step1-cmds
    (translate-bot-actions->sc2-raw-commands
     '((cast-spell 7401 oracle-revelation 79.0 80.0)
       (blind-skillshot-shimmer 7401 oracle-revelation 79.0 80.0)
       (cast 7401 oracle-revelation 79.0 80.0))
     (make-test-obs 12200 200 100 (list ora-7401 dt-unrev))))
  (check-eqv "w12-tac-1-wire-oracle-revelation-single-cast-dedupe"
             (count (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 2146)))
                    rev-step1-cmds)
             1)
  (define rev-step2-cmds
    (translate-bot-actions->sc2-raw-commands
     '((cast-spell 7401 oracle-revelation 79.0 80.0)
       (attack 7401 8401))
     (make-test-obs 12208 200 100 (list ora-7401 dt-rev49))))
  (check-true "w12-tac-1-wire-oracle-skips-buff49-revelation-and-weaponless-attack"
              (and (= (count (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 2146))) rev-step2-cmds) 0)
                   (= (count (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 23)
                                              (memv 7401 (sc2-raw-unit-command-unit-tags c)))) rev-step2-cmds) 0)))
  (define ora-beam-cmds
    (translate-bot-actions->sc2-raw-commands
     '((cast-spell 7401 pulsar-beam)
       (attack 7401 8402))
     (make-test-obs 12212 200 100 (list ora-7401 scv-8402))))
  (check-true "w12-tac-1-wire-oracle-activating-pulsar-beam-still-allowed-attack"
              (and (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 2375))) ora-beam-cmds)
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 23)
                                           (memv 7401 (sc2-raw-unit-command-unit-tags c)))) ora-beam-cmds)))

  ;; 2b. `w12-tac-2` wire defense-in-depth: Cyclone Lock-On (2350) single-cast per target + buff=116 skip!
  (define cyc-1 (mk-w12-u 7411 692 1 75.0 80.0 #:hp 120.0))
  (define cyc-2 (mk-w12-u 7412 692 1 75.0 81.5 #:hp 120.0))
  (define imm-clean (mk-w12-u 8411 83 4 81.0 80.0 #:hp 200.0))
  (define imm-buff116 (mk-w12-u 8411 83 4 81.0 80.0 #:hp 200.0 #:buffs '(116)))
  (define lock-clean-cmds
    (translate-bot-actions->sc2-raw-commands
     '((cast-spell 7411 lock-on 8411)
       (cast-spell 7412 lock-on 8411))
     (make-test-obs 12300 200 100 (list cyc-1 cyc-2 imm-clean))))
  (check-eqv "w12-tac-2-wire-cyclone-lockon-single-cast-per-target"
             (count (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 2350)))
                    lock-clean-cmds)
             1)
  (define lock-buff116-cmds
    (translate-bot-actions->sc2-raw-commands
     '((cast-spell 7411 lock-on 8411)
       (cast-spell 7412 lock-on 8411))
     (make-test-obs 12304 200 100 (list cyc-1 cyc-2 imm-buff116))))
  (check-eqv "w12-tac-2-wire-cyclone-skips-already-locked-buff116-target"
             (count (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 2350)))
                    lock-buff116-cmds)
             0)

  ;; 2c. `w12-tac-3` wire defense-in-depth: Viking Assault `405` dedupe + multi-tag coalescing!
  (define vik-a1 (mk-w12-u 7421 34 1 75.0 80.0 #:hp 135.0))
  (define vik-a2 (mk-w12-u 7422 34 1 75.0 81.5 #:hp 135.0))
  (define vik-f3 (mk-w12-u 7423 35 1 75.0 83.0 #:hp 135.0 #:flying? #t))
  (define vik-cmds
    (translate-bot-actions->sc2-raw-commands
     '((cast-spell 7421 morph-viking-fighter)
       (morph 7421 viking-fighter)
       (cast 7421 morph-viking-fighter)
       (cast-spell 7422 morph-viking-fighter)
       (morph 7422 viking-fighter)
       (cast-spell 7423 morph-viking-fighter))
     (make-test-obs 12600 200 100 (list vik-a1 vik-a2 vik-f3))))
  (define vik-405-cmds
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 405)))
            vik-cmds))
  (check-true "w12-tac-3-wire-viking-405-deduped-coalesced-and-skips-already-fighter"
              (and (= (length vik-405-cmds) 1)
                   (equal? (sort (sc2-raw-unit-command-unit-tags (first vik-405-cmds)) <) '(7421 7422))))

  ;; 2d. `w12-tac-4` wire legality & P0 priority: Void Ray Prismatic Alignment (2393) & Reaper KD8 Charge (2588)!
  (define vr-7431 (mk-w12-u 7431 80 1 75.0 80.0 #:hp 150.0 #:flying? #t))
  (define rpr-7441 (mk-w12-u 7441 49 1 75.0 80.0 #:hp 60.0))
  (define ab2393-cmds
    (translate-bot-actions->sc2-raw-commands
     '((cast-spell 7431 prismatic-alignment)
       (cast-spell 7431 prismatic-alignment)
       (cast-spell 7441 kd8-charge 79.0 80.0)
       (cast-spell 7441 kd8-charge 79.0 80.0))
     (make-test-obs 12700 200 100 (list vr-7431 rpr-7441))))
  (define vr-cmd (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 2393))) ab2393-cmds))
  (define rpr-cmd (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 2588))) ab2393-cmds))
  (check-true "w12-tac-4-wire-prismatic-alignment-2393-deduped-notarget-and-p0"
              (and (= (count (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 2393))) ab2393-cmds) 1)
                   (not (sc2-raw-unit-command-target-pos vr-cmd))
                   (= (sc2-raw-unit-command-target-unit-tag vr-cmd) 0)
                   (= (wire-cmd-priority-tier vr-cmd) 0)))
  (check-true "w12-tac-4-wire-reaper-kd8-charge-2588-deduped-pointtarget-and-p0"
              (and (= (count (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 2588))) ab2393-cmds) 1)
                   (sc2-point2d? (sc2-raw-unit-command-target-pos rpr-cmd))
                   (= (sc2-raw-unit-command-target-unit-tag rpr-cmd) 0)
                   (= (wire-cmd-priority-tier rpr-cmd) 0))))

;; =============================================================================
;; Wave 15 (`W15-P0-2-wire`): Map-Symmetry Inference & Dual Ground-BFS Voronoi
;; =============================================================================
(printf "[Wave 15] Testing W15-P0-2-wire map-symmetry classification & dual ground-BFS Voronoi territory...\n")
(let ()
  ;; 1. Zero-map-name symmetry classification across all 6 symmetry kinds
  (check-eqv "w15-sym-rotational-180"
             (sc2-detect-map-symmetry
              (sc2-point2d 30.0 30.0) (sc2-point2d 170.0 170.0) 200.0 200.0
              (list (cons 30.0 60.0) (cons 170.0 140.0) (cons 75.0 35.0) (cons 125.0 165.0)))
             'rotational-180)
  (check-eqv "w15-sym-mirror-horizontal-off-center"
             (sc2-detect-map-symmetry
              '(30.0 . 40.0) '(170.0 . 40.0) 200.0 200.0
              '((30.0 . 80.0) (170.0 . 80.0) (60.0 . 150.0) (140.0 . 150.0)))
             'mirror-horizontal)
  (check-eqv "w15-sym-mirror-horizontal-centerline-disambiguated-by-pads"
             (sc2-detect-map-symmetry
              '(30.0 . 100.0) '(170.0 . 100.0) 200.0 200.0
              '((40.0 . 150.0) (160.0 . 150.0) (70.0 . 130.0) (130.0 . 130.0)))
             'mirror-horizontal)
  (check-eqv "w15-sym-mirror-vertical"
             (sc2-detect-map-symmetry
              '(40.0 . 30.0) '(40.0 . 170.0) 200.0 200.0
              '((80.0 . 30.0) (80.0 . 170.0) (150.0 . 60.0) (150.0 . 140.0)))
             'mirror-vertical)
  (check-eqv "w15-sym-mirror-diagonal-main"
             (sc2-detect-map-symmetry
              '(30.0 . 170.0) '(170.0 . 30.0) 200.0 200.0
              '((30.0 . 110.0) (110.0 . 30.0) (60.0 . 160.0) (160.0 . 60.0)))
             'mirror-diagonal-main)
  (check-eqv "w15-sym-mirror-diagonal-anti"
             (sc2-detect-map-symmetry
              '(30.0 . 30.0) '(170.0 . 170.0) 200.0 200.0
              '((30.0 . 90.0) (110.0 . 170.0) (45.0 . 120.0) (80.0 . 155.0)))
             'mirror-diagonal-anti)
  (check-eqv "w15-sym-asymmetric-starts"
             (sc2-detect-map-symmetry
              '(25.0 . 30.0) '(155.0 . 140.0) 200.0 200.0
              '((40.0 . 80.0) (90.0 . 150.0) (160.0 . 40.0)))
             'asymmetric)
  (check-eqv "w15-sym-asymmetric-pads-despite-symmetric-starts"
             (sc2-detect-map-symmetry
              '(30.0 . 30.0) '(170.0 . 170.0) 200.0 200.0
              '((40.0 . 120.0) (90.0 . 150.0) (130.0 . 40.0) (160.0 . 80.0)))
             'asymmetric)
  (check-eqv "w15-sym-shifted-playable-origin-offset"
             (sc2-detect-map-symmetry
              '(32.0 . 46.0) '(188.0 . 46.0) 176.0 160.0
              '((42.0 . 120.0) (178.0 . 120.0) (62.0 . 150.0) (158.0 . 150.0))
              #:x0 22.0 #:y0 20.0)
             'mirror-horizontal)

  ;; 2. Cliff/wall ground-path Voronoi divergence from Euclidean midpoint!
  ;; 64x64 grid: our main=(10,10), enemy main=(54,10).
  ;; Impassable vertical cliff at x=38..40, y=0..55 (only northern bridge y=56..60 connects sides).
  ;; Point P=(35,10) is EUCLIDEAN closer to enemy (19t vs 25t), yet GROUND-PATH much closer to US (25t vs >100t)!
  (define gw 64)
  (define gh 64)
  (define cliff-bytes (make-bytes (* gw gh) 1))
  (for* ([y (in-range 0 56)]
         [x (in-range 38 41)])
    (bytes-set! cliff-bytes (+ x (* y gw)) 0))
  (define cliff-pgrid (sc2-image-grid 8 gw gh cliff-bytes #f #f))
  (define our-bfs (compute-ground-bfs-distances cliff-pgrid 10.0 10.0 '()))
  (define enemy-bfs (compute-ground-bfs-distances cliff-pgrid 54.0 10.0 '()))
  (define m-own-side (sc2-ground-territory-margin our-bfs enemy-bfs 35.0 10.0))
  (define m-enemy-side (sc2-ground-territory-margin our-bfs enemy-bfs 44.0 10.0))
  (define m-cliff-wall (sc2-ground-territory-margin our-bfs enemy-bfs 39.0 10.0))
  (define m-missing (sc2-ground-territory-margin #f enemy-bfs 35.0 10.0))
  (check-true "w15-voronoi-cliff-diverges-from-euclidean-midpoint-own-side"
              (and (real? m-own-side) (> m-own-side 65.0)))
  (check-true "w15-voronoi-cliff-enemy-side-deep-negative-margin"
              (and (real? m-enemy-side) (< m-enemy-side -65.0)))
  (check-eqv "w15-voronoi-unpathable-cliff-returns-false" m-cliff-wall #f)
  (check-eqv "w15-voronoi-missing-bfs-returns-false" m-missing #f)

  ;; 3. Live `sc2-observation->runtime-obs-hash` exposure + O(1) match-start cache + rewind reset
  (set-box! SC2-TERRITORY-FIELD-CACHE #f)
  (define cliff-ginfo
    (sc2-game-info "CliffTest" "CliffTest.SC2Map"
                   (list (hash 'player-id 1 'race-requested 'Terran)
                         (hash 'player-id 2 'race-requested 'Zerg))
                   (cons gw gh)
                   (hash 'x0 0 'y0 0 'x1 gw 'y1 gh)
                   (list (sc2-point2d 54.0 10.0))
                   cliff-pgrid cliff-pgrid cliff-pgrid))
  (define our-cc
    (sc2-unit 1 1 9701 18 1 (sc2-point3d 10.0 10.0 8.0) 0.0 2.75 1.0 0 #f #t #f
              1500.0 1500.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0))
  (define obs-f0 (make-test-obs 0 50 0 (list our-cc)))
  (define obs-f4 (make-test-obs 4 50 0 (list our-cc)))
  (define obs-f8 (make-test-obs 8 50 0 (list our-cc)))
  (define h-f0 (sc2-observation->runtime-obs-hash obs-f0 #:game-info cliff-ginfo #:defer-expansions? #t))
  (define h-f4 (sc2-observation->runtime-obs-hash obs-f4 #:game-info cliff-ginfo #:defer-expansions? #f))
  (define h-f8 (sc2-observation->runtime-obs-hash obs-f8 #:game-info cliff-ginfo #:defer-expansions? #f))
  (check-true "w15-obs-f0-defers-bfs-while-classifying-symmetry"
              (and (eq? (hash-ref h-f0 'map-symmetry-kind #f) 'mirror-horizontal)
                   (eq? (hash-ref h-f0 'our-ground-bfs 'missing) #f)
                   (eq? (hash-ref h-f0 'enemy-ground-bfs 'missing) #f)))
  (check-true "w15-obs-f4-populates-dual-ground-bfs-and-voronoi-margin"
              (let ([ob (hash-ref h-f4 'our-ground-bfs #f)]
                    [eb (hash-ref h-f4 'enemy-ground-bfs #f)])
                (and (eq? (hash-ref h-f4 'map-symmetry-kind #f) 'mirror-horizontal)
                     (procedure? ob) (procedure? eb)
                     (let ([m (sc2-ground-territory-margin ob eb 35.0 10.0)])
                       (and (real? m) (> m 65.0))))))
  (check-true "w15-obs-f8-reuses-exact-cached-ground-bfs-zero-recompute"
              (and (eq? (hash-ref h-f4 'our-ground-bfs #f)
                        (hash-ref h-f8 'our-ground-bfs #f))
                   (eq? (hash-ref h-f4 'enemy-ground-bfs #f)
                        (hash-ref h-f8 'enemy-ground-bfs #f))))
  ;; Match rewind to loop 4 on a vertical-mirror map clears cache & re-infers `'mirror-vertical`
  (define vert-ginfo
    (sc2-game-info "VertTest" "VertTest.SC2Map"
                   (list (hash 'player-id 1 'race-requested 'Terran)
                         (hash 'player-id 2 'race-requested 'Protoss))
                   (cons gw gh)
                   (hash 'x0 0 'y0 0 'x1 gw 'y1 gh)
                   (list (sc2-point2d 10.0 54.0))
                   cliff-pgrid cliff-pgrid cliff-pgrid))
  (define h-newmatch (sc2-observation->runtime-obs-hash obs-f4 #:game-info vert-ginfo #:defer-expansions? #f))
  (check-eqv "w15-obs-match-rewind-resets-territory-cache-and-reclassifies"
             (hash-ref h-newmatch 'map-symmetry-kind #f)
             'mirror-vertical))

;; =============================================================================
;; Wave 16 (`W16-P1-2-wire`): Terran 5x3 Add-on Clearance, Auto-Relocation,
;; Per-Tag Backoff, Core-Macro RPC Priority & BFS Critter/Mineout Cache Hygiene
;; =============================================================================
(printf "[Wave 16] Testing W16-P1-2-wire Terran 5x3/3x3 clearance, add-on relocation/backoff, RPC priority & BFS cache...\n")
(let ()
  (define (mk-w16-u tag utype alliance x y #:hp [hp 100.0] #:rad [rad 0.75] #:prog [prog 1.0])
    (sc2-unit 1 alliance tag utype alliance (sc2-point3d x y 8.0) 0.0 rad prog
              0 #f #t #f hp hp 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #f
              '() 0 '() 0 0 0.0 0 0 0 0))
  (define (w16-start-geom-placement-ws geom-policy-fn)
    (define-values (c-in s-out) (make-pipe))
    (define-values (s-in c-out) (make-pipe))
    (define ws (sc2-ws-conn "127.0.0.1" 59916 "/sc2api" c-in c-out #f 1))
    (define rpc-count (box 0))
    (define thd
      (thread
       (lambda ()
         (let lp ()
           (define b0 (read-byte s-in))
           (unless (eof-object? b0)
             (define b1 (read-byte s-in))
             (define masked? (not (zero? (bitwise-and b1 #x80))))
             (define len0 (bitwise-and b1 #x7F))
             (define plen
               (cond [(< len0 126) len0]
                     [(= len0 126) (integer-bytes->integer (read-bytes 2 s-in) #f #t)]
                     [else (integer-bytes->integer (read-bytes 8 s-in) #f #t)]))
             (define mkey (if masked? (read-bytes 4 s-in) #f))
             (define raw (read-bytes plen s-in))
             (define payload
               (if masked?
                   (let ([out (make-bytes plen)])
                     (for ([i (in-range plen)])
                       (bytes-set! out i (bitwise-xor (bytes-ref raw i) (bytes-ref mkey (modulo i 4)))))
                     out)
                   raw))
             (set-box! rpc-count (add1 (unbox rpc-count)))
             (define req-f (decode-protobuf-message payload))
             (define req-id-p (assoc 97 req-f))
             (define id-b (if req-id-p (encode-uint32 97 (third req-id-p)) #""))
             (define q-p (assoc 14 req-f))
             (when q-p
               (define qf (decode-protobuf-message (third q-p)))
               (define p-items (filter (lambda (e) (= (first e) 3)) qf))
               (define res-b
                 (apply bytes-append
                        (for/list ([it (in-list p-items)])
                          (define itf (decode-protobuf-message (third it)))
                          (define ab (let ([p (assoc 1 itf)]) (if p (third p) 0)))
                          (define tp-e (assoc 2 itf))
                          (define-values (px py)
                            (if tp-e
                                (let ([ptf (decode-protobuf-message (third tp-e))])
                                  (values (let ([xp (assoc 1 ptf)])
                                            (if (and xp (bytes? (third xp)))
                                                (floating-point-bytes->real (third xp) #f)
                                                0.0))
                                          (let ([yp (assoc 2 ptf)])
                                            (if (and yp (bytes? (third yp)))
                                                (floating-point-bytes->real (third yp) #f)
                                                0.0))))
                                (values 0.0 0.0)))
                          (encode-submessage-field 3 (encode-int32 1 (geom-policy-fn ab px py))))))
               (define resp (bytes-append (encode-submessage-field 14 res-b) id-b (encode-int32 99 3)))
               (define rlen (bytes-length resp))
               (define rhdr
                 (cond [(< rlen 126) (bytes #x82 rlen)]
                       [(<= rlen 65535) (bytes-append (bytes #x82 126) (integer->integer-bytes rlen 2 #f #t))]
                       [else (bytes-append (bytes #x82 127) (integer->integer-bytes rlen 8 #f #t))]))
               (write-bytes rhdr s-out)
               (write-bytes resp s-out)
               (flush-output s-out))
             (lp))))))
    (values ws rpc-count
            (lambda ()
              (close-output-port c-out)
              (close-input-port c-in)
              (thread-wait thd))))

  ;; 1a. Barracks prefers verified 5x3 (even via natural overflow) over 3x3-only in crowded main!
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (let-values ([(ws rpc-cnt cleanup!)
                ;; Main (x < 54) accepts 3x3 (321) only (East 319 blocked); Natural (x >= 56) accepts full 5x3!
                (w16-start-geom-placement-ws
                 (lambda (ab px _py)
                   (cond
                     [(= ab 321) 1]
                     [(= ab 319) (if (>= px 56.0) 1 2)]
                     [else 2])))])
    (define main-cc (mk-w16-u 9801 18 1 28.5 28.5 #:hp 1500.0 #:rad 2.75))
    (define nat-cc  (mk-w16-u 9802 18 1 64.5 30.5 #:hp 1500.0 #:rad 2.75))
    (define main-rax (mk-w16-u 9803 21 1 34.5 28.5 #:hp 1000.0 #:rad 1.5))
    (define main-scv (mk-w16-u 9804 45 1 30.0 26.0 #:hp 45.0 #:rad 0.375))
    (define cmds
      (translate-bot-actions->sc2-raw-commands
       '((build barracks 32.5 30.5))
       (make-test-obs 5800 400 100 (list main-cc nat-cc main-rax main-scv))
       #:ws-conn ws #:game-info w3-ginfo))
    (define rax-cmd
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 321))) cmds))
    (check-true "w16-p1-2-barracks-prefers-5x3-overflow-over-3x3-only-in-1-rpc"
                (and (sc2-raw-unit-command? rax-cmd)
                     (sc2-point2d? (sc2-raw-unit-command-target-pos rax-cmd))
                     (>= (+ (sc2-point2d-x (sc2-raw-unit-command-target-pos rax-cmd)) 2.5) 56.0)
                     (= (unbox rpc-cnt) 1)))
    (cleanup!))

  ;; 1b. Barracks falls back cleanly to natural 3x3 when ALL 5x3 slots fail (zero deadlock!)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (let-values ([(ws rpc-cnt cleanup!)
                (w16-start-geom-placement-ws
                 (lambda (ab px _py) (if (and (= ab 321) (>= px 56.0)) 1 2)))])
    (define main-cc (mk-w16-u 9811 18 1 28.5 28.5 #:hp 1500.0 #:rad 2.75))
    (define nat-cc  (mk-w16-u 9812 18 1 64.5 30.5 #:hp 1500.0 #:rad 2.75))
    (define main-rax1 (mk-w16-u 9813 21 1 34.5 28.5 #:hp 1000.0 #:rad 1.5))
    (define main-rax2 (mk-w16-u 9814 21 1 34.5 33.5 #:hp 1000.0 #:rad 1.5))
    (define main-scv (mk-w16-u 9815 45 1 30.0 26.0 #:hp 45.0 #:rad 0.375))
    (define cmds
      (translate-bot-actions->sc2-raw-commands
       '((build barracks 32.5 30.5))
       (make-test-obs 5820 400 100 (list main-cc nat-cc main-rax1 main-rax2 main-scv))
       #:ws-conn ws #:game-info w3-ginfo))
    (define rax-cmd
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 321))) cmds))
    (check-true "w16-p1-2-barracks-falls-back-to-natural-3x3-when-no-5x3-exists"
                (and (sc2-raw-unit-command? rax-cmd)
                     (sc2-point2d? (sc2-raw-unit-command-target-pos rax-cmd))
                     (>= (sc2-point2d-x (sc2-raw-unit-command-target-pos rax-cmd)) 56.0)
                     (= (unbox rpc-cnt) 1)))
    (cleanup!))

  ;; 2a. `#17` Single Starport blocked East slot -> relocates via PointOrNone (487 + verified 5x3 pt) & encodes cleanly
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-ADDON-SLOT-BLOCKED-CACHE)
  (let-values ([(ws rpc-cnt cleanup!)
                (w16-start-geom-placement-ws
                 (lambda (ab px _py)
                   (cond
                     [(= ab 319) (if (<= px 44.0) 1 2)]
                     [(= ab 329) (if (<= px 41.5) 1 2)]
                     [else 2])))])
    (define cc-u (mk-w16-u 9820 18 1 28.5 28.5 #:hp 1500.0 #:rad 2.75))
    (define sp-u (mk-w16-u 9821 28 1 51.5 49.5 #:hp 1300.0 #:rad 1.5))
    (define sp-cmds
      (translate-bot-actions->sc2-raw-commands
       '((build starport-techlab 51.5 49.5))
       (make-test-obs 5940 600 300 (list cc-u sp-u))
       #:ws-conn ws #:game-info w3-ginfo))
    (define tl-cmd
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 487))) sp-cmds))
    (check-true "w16-p1-2-starport-blocked-east-slot-relocates-to-verified-5x3-pt"
                (and (sc2-raw-unit-command? tl-cmd)
                     (sc2-point2d? (sc2-raw-unit-command-target-pos tl-cmd))
                     (<= (sc2-point2d-x (sc2-raw-unit-command-target-pos tl-cmd)) 41.5)
                     (<= (unbox rpc-cnt) 2)))
    (check-true "w16-p1-2-starport-reloc-487-encodes-valid-wire-point-cmd"
                (and (sc2-raw-unit-command? tl-cmd)
                     (> (bytes-length (encode-action-raw-unit-command tl-cmd)) 0)))
    (cleanup!))

  ;; 2b. Single Starport clear East slot -> fast in-place `#f` (0 flying downtime, 1 RPC)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-ADDON-SLOT-BLOCKED-CACHE)
  (let-values ([(ws rpc-cnt cleanup!)
                (w16-start-geom-placement-ws
                 (lambda (ab _px _py) (if (memv ab '(319 329)) 1 2)))])
    (define cc-u (mk-w16-u 9825 18 1 28.5 28.5 #:hp 1500.0 #:rad 2.75))
    (define sp-u (mk-w16-u 9826 28 1 38.5 38.5 #:hp 1300.0 #:rad 1.5))
    (define sp-ok-cmds
      (translate-bot-actions->sc2-raw-commands
       '((build starport-techlab 38.5 38.5))
       (make-test-obs 5950 600 300 (list cc-u sp-u))
       #:ws-conn ws #:game-info w3-ginfo))
    (define tl-ok-cmd
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 487))) sp-ok-cmds))
    (check-true "w16-p1-2-starport-clear-east-slot-builds-in-place-1-rpc"
                (and (sc2-raw-unit-command? tl-ok-cmd)
                     (eq? (sc2-raw-unit-command-target-pos tl-ok-cmd) #f)
                     (= (unbox rpc-cnt) 1)))
    (cleanup!))

  ;; 2c. Add-on action-error invalidates ONLY the matching facility pos-cache entry (preserving unrelated
  ;;     buildings like Barracks!), exposes `addon-blocked-facility-ids`, and relocates in 1 RPC
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-ADDON-SLOT-BLOCKED-CACHE)
  (hash-clear! SC2-TERRAN-5X3-MISS-CACHE)
  (hash-set! SC2-PLACEMENT-POS-CACHE '(barracks 35 31 15) (list 5990 (sc2-point2d 35.5 31.5)))
  (hash-set! SC2-PLACEMENT-POS-CACHE '(starport 52 50 18 addon-req) (list 5990 (sc2-point2d 51.5 49.5)))
  (let-values ([(ws rpc-cnt cleanup!)
                (w16-start-geom-placement-ws
                 (lambda (ab px _py)
                   (cond
                     [(= ab 319) (if (<= px 44.0) 1 2)]
                     [(= ab 329) (if (<= px 41.5) 1 2)]
                     [else 2])))])
    (define cc-u (mk-w16-u 9830 18 1 28.5 28.5 #:hp 1500.0 #:rad 2.75))
    (define sp-u (mk-w16-u 9831 28 1 51.5 49.5 #:hp 1300.0 #:rad 1.5))
    (define obs-ae
      (sc2-observation 6000 (sc2-player-common 1 600 300 40 60 20 20 0 0 0 0)
                       (list cc-u sp-u) '() '() #f '() '() '()
                       (list (hash 'unit-tag 9831 'ability-id 487 'result 19))
                       '() '()))
    (define obs-ae-h (sc2-observation->runtime-obs-hash obs-ae))
    (check-true "w16-p1-2-build-action-error-targets-only-failed-bldg-pos-cache"
                (and (not (hash-has-key? SC2-PLACEMENT-POS-CACHE '(starport 52 50 18 addon-req)))
                     (hash-has-key? SC2-PLACEMENT-POS-CACHE '(barracks 35 31 15))))
    (check-true "w16-p1-2-addon-action-error-exposes-blocked-facility-id-in-obs"
                (and (memv 9831 (hash-ref obs-ae-h 'addon-blocked-facility-ids '())) #t))
    (define sp-ae-cmds
      (translate-bot-actions->sc2-raw-commands
       '((build starport-techlab 51.5 49.5))
       (make-test-obs 6004 600 300 (list cc-u sp-u))
       #:ws-conn ws #:game-info w3-ginfo))
    (define tl-ae-cmd
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 487))) sp-ae-cmds))
    (check-true "w16-p1-2-addon-action-error-skips-recheck-and-relocates-in-1-rpc"
                (and (sc2-raw-unit-command? tl-ae-cmd)
                     (sc2-point2d? (sc2-raw-unit-command-target-pos tl-ae-cmd))
                     (= (unbox rpc-cnt) 1)))
    (cleanup!))

  ;; 2d. Unrelocatable add-on facility (both East slot & all 5x3 relocation spots rejected) enters 64-loop per-tag backoff (ZERO spam!)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-ADDON-SLOT-BLOCKED-CACHE)
  (let-values ([(ws rpc-cnt cleanup!)
                (w16-start-geom-placement-ws (lambda (_ab _px _py) 2))])
    (define cc-u (mk-w16-u 9840 18 1 28.5 28.5 #:hp 1500.0 #:rad 2.75))
    (define rax-u (mk-w16-u 9841 21 1 40.5 40.5 #:hp 1000.0 #:rad 1.5))
    (define c1 (translate-bot-actions->sc2-raw-commands
                '((build barracks-techlab 40.5 40.5))
                (make-test-obs 7000 400 200 (list cc-u rax-u))
                #:ws-conn ws #:game-info w3-ginfo))
    (define rpcs-after-1 (unbox rpc-cnt))
    (define c2 (translate-bot-actions->sc2-raw-commands
                '((build barracks-techlab 40.5 40.5))
                (make-test-obs 7004 400 200 (list cc-u rax-u))
                #:ws-conn ws #:game-info w3-ginfo))
    (define c3 (translate-bot-actions->sc2-raw-commands
                '((build barracks-techlab 40.5 40.5))
                (make-test-obs 7040 400 200 (list cc-u rax-u))
                #:ws-conn ws #:game-info w3-ginfo))
    (define rpcs-after-3 (unbox rpc-cnt))
    (void (translate-bot-actions->sc2-raw-commands
           '((build barracks-techlab 40.5 40.5))
           (make-test-obs 7068 400 200 (list cc-u rax-u))
           #:ws-conn ws #:game-info w3-ginfo))
    (define rpcs-after-retry (unbox rpc-cnt))
    (check-true "w16-p1-2-unrelocatable-addon-emits-zero-doomed-cmds-and-backs-off-64-loops"
                (and (null? (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 421))) (append c1 c2 c3)))
                     (= rpcs-after-1 2)
                     (= rpcs-after-3 rpcs-after-1)
                     (> rpcs-after-retry rpcs-after-3)))
    (cleanup!))

  ;; 3. Core macro (`barracks`, `supply-depot`) preempts secondary (`bunker`, `engineering-bay`) for the 2-RPC/step budget
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (let-values ([(ws rpc-cnt cleanup!)
                (w16-start-geom-placement-ws (lambda (_ab _px _py) 1))])
    (define cc-u (mk-w16-u 9850 18 1 28.5 28.5 #:hp 1500.0 #:rad 2.75))
    (define scvs (for/list ([i (in-range 4)])
                   (mk-w16-u (+ 9851 i) 45 1 (+ 32.0 i) 26.0 #:hp 45.0 #:rad 0.375)))
    (define prio-cmds
      (translate-bot-actions->sc2-raw-commands
       '((build bunker 36.5 34.5)
         (build engineering-bay 36.5 39.5)
         (build barracks 36.5 28.5)
         (build supply-depot 32.5 35.5))
       (make-test-obs 7200 1000 300 (cons cc-u scvs))
       #:ws-conn ws #:game-info w3-ginfo))
    (define emitted-abs
      (for/list ([c (in-list prio-cmds)] #:when (sc2-raw-unit-command? c))
        (sc2-raw-unit-command-ability-id c)))
    (check-true "w16-p1-2-core-macro-barracks-and-depot-preempt-bunker-and-ebay"
                (and (<= (unbox rpc-cnt) 2)
                     (memv 321 emitted-abs)
                     (memv 319 emitted-abs)
                     (not (memv 324 emitted-abs))
                     (not (memv 322 emitted-abs))))
    (cleanup!))

  ;; 4. Latency hygiene (`#13` Incorporeal AIE): moving map critters & mineral mine-out never bust territory/expansion BFS cache
  (set-box! SC2-TERRITORY-FIELD-CACHE #f)
  (define g64 (make-bytes (* 64 64) 1))
  (define p64 (sc2-image-grid 8 64 64 g64 #f #f))
  (define gi64
    (sc2-game-info "CritterTest" "CritterTest.SC2Map"
                   (list (hash 'player-id 1 'race-requested 'Zerg)
                         (hash 'player-id 2 'race-requested 'Terran))
                   (cons 64 64) (hash 'x0 0 'y0 0 'x1 64 'y1 64)
                   (list (sc2-point2d 52.0 52.0))
                   p64 p64 p64))
  (define h-u (mk-w16-u 9860 86 1 12.0 12.0 #:hp 1500.0 #:rad 2.75))
  (define crit-a (mk-w16-u 9861 335 3 25.0 25.0 #:hp 10.0 #:rad 0.375))
  (define crit-b (mk-w16-u 9861 335 3 26.5 25.0 #:hp 10.0 #:rad 0.375))
  (define obs-c1 (sc2-observation 4 (sc2-player-common 1 50 0 12 14 0 12 0 0 0 0)
                                  (list h-u crit-a) '() '() #f '() '() '() '() '() '()))
  (define obs-c2 (sc2-observation 8 (sc2-player-common 1 50 0 12 14 0 12 0 0 0 0)
                                  (list h-u crit-b) '() '() #f '() '() '() '() '() '()))
  (define hc1 (sc2-observation->runtime-obs-hash obs-c1 #:game-info gi64 #:defer-expansions? #f))
  (define hc2 (sc2-observation->runtime-obs-hash obs-c2 #:game-info gi64 #:defer-expansions? #f))
  (define ord1 (order-expansions-from-origin (list (hash 'x 24.0 'y 12.0) (hash 'x 44.0 'y 44.0))
                                             12.0 12.0 p64 (list crit-b)
                                             #:bfs (hash-ref hc1 'our-ground-bfs)))
  (check-true "w16-p1-2-walking-critter-preserves-exact-cached-ground-bfs-and-exp-order"
              (and (eq? (hash-ref hc1 'our-ground-bfs) (hash-ref hc2 'our-ground-bfs))
                   (eq? (hash-ref hc1 'enemy-ground-bfs) (hash-ref hc2 'enemy-ground-bfs))
                   (= (hash-ref (first ord1) 'x) 24.0))))

(printf "[Wave 17] Testing W17-P0-1 targeted pos-cache invalidation + >=48f TTL + 1-miss 5x3->3x3, W17-P0-2 Lair/Terran producers, & W17-P0-3 hovering-air gas fallback...\n")
(let ()
  (define (mk-w17-u tag utype alliance x y
                    #:hp [hp 100.0] #:shield [sh 0.0] #:rad [rad 1.0]
                    #:bp [bp 1.0] #:flying? [fly? #f] #:powered? [pow? #t]
                    #:orders [ords '()] #:addon [addon 0]
                    #:assigned [asgn 0] #:ideal [idl 0] #:vesp [vesp 0])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 2)
              (sc2-point3d x y (if fly? 12.0 8.0)) 0.0 rad bp 0 #f #f fly?
              hp hp sh sh 0.0 0.0 0 0 #f #f #f pow? #f ords addon '() asgn idl 0.0 0 0 0 vesp))

  ;; W17-P0-1a: Targeted pos-cache invalidation: failed `build-photon-cannon` (887) at (30,30) removes
  ;; ONLY `(photon-cannon, ~30, ~30)` while preserving `gateway` at (30,30) AND `photon-cannon` at (90,90)!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-clear! SC2-TERRAN-5X3-MISS-CACHE)
  (hash-set! SC2-PLACEMENT-POS-CACHE '(photon-cannon 30 30 6) (list 12000 (sc2-point2d 32.0 30.0)))
  (hash-set! SC2-PLACEMENT-POS-CACHE '(photon-cannon 90 90 6) (list 12000 (sc2-point2d 92.0 90.0)))
  (hash-set! SC2-PLACEMENT-POS-CACHE '(gateway 30 30 6) (list 12000 (sc2-point2d 33.5 31.5)))
  (define probe-u (mk-w17-u 9901 84 1 30.5 30.5 #:hp 20.0 #:shield 20.0 #:rad 0.375))
  (define obs-pc-err
    (sc2-observation 12004 (sc2-player-common 1 800 100 100 72 30 42 0 0 0 0)
                     (list probe-u) '() '() #f '() '() '()
                     (list (hash 'unit-tag 9901 'ability-id 887 'result 19))
                     '() '()))
  (void (sc2-observation->runtime-obs-hash obs-pc-err))
  (check-true "w17-p0-1a-failed-photon-cannon-preserves-gateway-and-distant-cannon-pos-cache"
              (and (not (hash-has-key? SC2-PLACEMENT-POS-CACHE '(photon-cannon 30 30 6)))
                   (hash-has-key? SC2-PLACEMENT-POS-CACHE '(gateway 30 30 6))
                   (hash-has-key? SC2-PLACEMENT-POS-CACHE '(photon-cannon 90 90 6))))

  ;; W17-P0-1b: `neg-cd-ttl >= 48f` for Terran production (`barracks`) and `64f` for late-game static
  ;; defense (`photon-cannon` >= 5400f, even when requested coords jitter across Pylons!), while keeping
  ;; fast `12f` recovery for supply (`pylon`).
  (define (w17-start-mock-ws decide-fn)
    (define-values (c-in s-out) (make-pipe))
    (define-values (s-in c-out) (make-pipe))
    (define ws (sc2-ws-conn "127.0.0.1" 59917 "/sc2api" c-in c-out #f 1))
    (define rpc-cnt (box 0))
    (define saw-319? (box #f))
    (define th
      (thread
       (lambda ()
         (let lp ()
           (define b0 (read-byte s-in))
           (unless (eof-object? b0)
             (define b1 (read-byte s-in))
             (define masked? (not (zero? (bitwise-and b1 #x80))))
             (define len0 (bitwise-and b1 #x7F))
             (define plen
               (cond [(< len0 126) len0]
                     [(= len0 126) (integer-bytes->integer (read-bytes 2 s-in) #f #t)]
                     [else (integer-bytes->integer (read-bytes 8 s-in) #f #t)]))
             (define mkey (if masked? (read-bytes 4 s-in) #f))
             (define raw (read-bytes plen s-in))
             (define payload
               (if masked?
                   (let ([out (make-bytes plen)])
                     (for ([i (in-range plen)])
                       (bytes-set! out i (bitwise-xor (bytes-ref raw i) (bytes-ref mkey (modulo i 4)))))
                     out)
                   raw))
             (set-box! rpc-cnt (add1 (unbox rpc-cnt)))
             (define req-f (decode-protobuf-message payload))
             (define req-id-p (assoc 97 req-f))
             (define id-b (if req-id-p (encode-uint32 97 (third req-id-p)) #""))
             (define q-p (assoc 14 req-f))
             (when q-p
               (define qf (decode-protobuf-message (third q-p)))
               (define p-items (filter (lambda (e) (= (first e) 3)) qf))
               (define res-b
                 (apply bytes-append
                        (for/list ([it (in-list p-items)])
                          (define itf (decode-protobuf-message (third it)))
                          (define ab (let ([p (assoc 1 itf)]) (if p (third p) 0)))
                          (when (= ab 319) (set-box! saw-319? #t))
                          (define tp-e (assoc 2 itf))
                          (define-values (px py)
                            (if tp-e
                                (let ([ptf (decode-protobuf-message (third tp-e))])
                                  (values (let ([xp (assoc 1 ptf)])
                                            (if (and xp (bytes? (third xp)))
                                                (floating-point-bytes->real (third xp) #f)
                                                0.0))
                                          (let ([yp (assoc 2 ptf)])
                                            (if (and yp (bytes? (third yp)))
                                                (floating-point-bytes->real (third yp) #f)
                                                0.0))))
                                (values 0.0 0.0)))
                          (encode-submessage-field 3 (encode-int32 1 (decide-fn ab px py))))))
               (define resp (bytes-append (encode-submessage-field 14 res-b) id-b (encode-int32 99 3)))
               (define rlen (bytes-length resp))
               (define rhdr
                 (cond [(< rlen 126) (bytes #x82 rlen)]
                       [(<= rlen 65535) (bytes-append (bytes #x82 126) (integer->integer-bytes rlen 2 #f #t))]
                       [else (bytes-append (bytes #x82 127) (integer->integer-bytes rlen 8 #f #t))]))
               (write-bytes rhdr s-out)
               (write-bytes resp s-out)
               (flush-output s-out))
             (lp))))))
    (values ws rpc-cnt saw-319?
            (lambda ()
              (close-output-port c-out)
              (close-input-port c-in)
              (thread-wait th))))

  ;; 1b-i: Terran `barracks` neg-cd >= 48 loops
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-TERRAN-5X3-MISS-CACHE)
  (let-values ([(ws rpc-cnt _saw319 cleanup!) (w17-start-mock-ws (lambda (_ab _px _py) 2))])
    (define cc-u (mk-w17-u 9910 18 1 28.5 28.5 #:hp 1500.0 #:rad 2.75))
    (define r1 (find-verified-building-placement ws 321 32.0 30.0 (list cc-u)
                                                 #:bldg-sym 'barracks #:game-info w3-ginfo #:cur-loop 6000))
    (define rpcs-1 (unbox rpc-cnt))
    (define r2 (find-verified-building-placement ws 321 32.0 30.0 (list cc-u)
                                                 #:bldg-sym 'barracks #:game-info w3-ginfo #:cur-loop 6036))
    (define rpcs-2 (unbox rpc-cnt))
    (define r3 (find-verified-building-placement ws 321 32.0 30.0 (list cc-u)
                                                 #:bldg-sym 'barracks #:game-info w3-ginfo #:cur-loop 6052))
    (define rpcs-3 (unbox rpc-cnt))
    (check-true "w17-p0-1b-terran-barracks-neg-cd-ttl-at-least-48-loops"
                (and (not r1) (not r2) (not r3)
                     (= rpcs-2 rpcs-1)
                     (> rpcs-3 rpcs-2)))
    (cleanup!))

  ;; 1b-ii: Late-game `photon-cannon` (>= 5400f) uses 64-loop TTL & skips jittered-anchor retries across Pylons,
  ;;        while supply `pylon` retains fast 12-loop recovery!
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (let-values ([(ws rpc-cnt _saw319 cleanup!) (w17-start-mock-ws (lambda (_ab _px _py) 2))])
    (define py1 (mk-w17-u 9915 60 1 30.0 30.0 #:hp 200.0 #:shield 200.0 #:rad 1.0))
    (define py2 (mk-w17-u 9916 60 1 56.0 30.0 #:hp 200.0 #:shield 200.0 #:rad 1.0))
    (define p-units (list py1 py2))
    (void (find-verified-building-placement ws 887 30.0 30.0 p-units
                                            #:anchor-points '((30.0 . 30.0) (56.0 . 30.0))
                                            #:bldg-sym 'photon-cannon #:game-info w3-ginfo #:cur-loop 12000))
    (define pc-rpcs-1 (unbox rpc-cnt))
    ;; Jittered primary anchor (32, 31) at +40 loops MUST still hit 64f late-game cooldown (0 RPCs)!
    (void (find-verified-building-placement ws 887 32.0 31.0 p-units
                                            #:anchor-points '((32.0 . 31.0) (30.0 . 30.0) (56.0 . 30.0))
                                            #:bldg-sym 'photon-cannon #:game-info w3-ginfo #:cur-loop 12040))
    (define pc-rpcs-2 (unbox rpc-cnt))
    (void (find-verified-building-placement ws 887 32.0 31.0 p-units
                                            #:anchor-points '((32.0 . 31.0) (30.0 . 30.0) (56.0 . 30.0))
                                            #:bldg-sym 'photon-cannon #:game-info w3-ginfo #:cur-loop 12068))
    (define pc-rpcs-3 (unbox rpc-cnt))
    (check-true "w17-p0-1b-late-game-photon-cannon-64f-ttl-blocks-jittered-thrash"
                (and (= pc-rpcs-1 1)
                     (= pc-rpcs-2 1)
                     (= pc-rpcs-3 2)))
    ;; Early supply `pylon` keeps fast 12-loop recovery
    (define before-py (unbox rpc-cnt))
    (void (find-verified-building-placement ws 881 30.0 30.0 p-units
                                            #:bldg-sym 'pylon #:game-info w3-ginfo #:cur-loop 12080))
    (void (find-verified-building-placement ws 881 30.0 30.0 p-units
                                            #:bldg-sym 'pylon #:game-info w3-ginfo #:cur-loop 12096))
    (check-eqv "w17-p0-1b-supply-pylon-keeps-fast-12f-recovery"
               (- (unbox rpc-cnt) before-py) 2)
    (cleanup!))

  ;; W17-P0-1c: Terran 1-miss `5x3 -> 3x3` / less-crowded base fallback & cached 3x3 freshness
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-TERRAN-5X3-MISS-CACHE)
  (let-values ([(ws rpc-cnt saw-319? cleanup!)
                (w17-start-mock-ws
                 (lambda (ab px _py)
                   ;; Reject ALL 5x3 East add-on slots (319) and reject crowded main (px < 56.0);
                   ;; accept 3x3 Starport (329) ONLY at the less-crowded natural (px >= 56.0)!
                   (if (and (= ab 329) (>= px 56.0)) 1 2)))])
    (define main-cc (mk-w17-u 9920 18 1 28.5 28.5 #:hp 1500.0 #:rad 2.75))
    (define nat-cc  (mk-w17-u 9921 18 1 64.5 30.5 #:hp 1500.0 #:rad 2.75))
    (define main-r1 (mk-w17-u 9922 21 1 34.5 28.5 #:hp 1000.0 #:rad 1.5))
    (define main-r2 (mk-w17-u 9923 21 1 34.5 33.5 #:hp 1000.0 #:rad 1.5))
    (define main-scv1 (mk-w17-u 9924 45 1 30.0 26.0 #:hp 45.0 #:rad 0.375))
    (define main-scv2 (mk-w17-u 9925 45 1 31.0 26.0 #:hp 45.0 #:rad 0.375))
    (define main-scv3 (mk-w17-u 9926 45 1 32.0 26.0 #:hp 45.0 #:rad 0.375))
    (define t-units (list main-cc nat-cc main-r1 main-r2 main-scv1 main-scv2 main-scv3))
    ;; 1st attempt: falls back to natural 3x3 AND records 5x3 miss in `SC2-TERRAN-5X3-MISS-CACHE`!
    (define sp-cmds-1
      (translate-bot-actions->sc2-raw-commands
       '((build starport 32.0 30.0))
       (make-test-obs 6500 500 300 t-units)
       #:ws-conn ws #:game-info w3-ginfo))
    (define sp-cmd-1
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 329))) sp-cmds-1))
    (check-true "w17-p0-1c-starport-1st-miss-places-natural-3x3-and-records-5x3-miss"
                (and (sc2-raw-unit-command? sp-cmd-1)
                     (sc2-point2d? (sc2-raw-unit-command-target-pos sp-cmd-1))
                     (>= (sc2-point2d-x (sc2-raw-unit-command-target-pos sp-cmd-1)) 56.0)
                     (> (hash-count SC2-TERRAN-5X3-MISS-CACHE) 0)))
    ;; Clear pos-cache (simulate next Starport build) while keeping `SC2-TERRAN-5X3-MISS-CACHE`:
    ;; 2nd attempt MUST skip 5x3 dual-query (`saw-319? = #f`) and place directly at natural in 1 single-query RPC!
    (hash-clear! SC2-PLACEMENT-POS-CACHE)
    (set-box! rpc-cnt 0)
    (set-box! saw-319? #f)
    (define sp-cmds-2
      (translate-bot-actions->sc2-raw-commands
       '((build starport 32.0 30.0))
       (make-test-obs 6504 500 300 t-units)
       #:ws-conn ws #:game-info w3-ginfo))
    (define sp-cmd-2
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 329))) sp-cmds-2))
    (check-true "w17-p0-1c-after-1-miss-starport-uses-pure-3x3-single-rpc-at-less-crowded-base"
                (and (sc2-raw-unit-command? sp-cmd-2)
                     (= (unbox rpc-cnt) 1)
                     (not (unbox saw-319?))
                     (>= (sc2-point2d-x (sc2-raw-unit-command-target-pos sp-cmd-2)) 56.0)))
    ;; 3rd call (pos-cache still warm with cached 3x3 point!) MUST hit positive cache (0 RPCs)!
    (set-box! rpc-cnt 0)
    (define sp-cmds-3
      (translate-bot-actions->sc2-raw-commands
       '((build starport 32.0 30.0))
       (make-test-obs 6508 500 300 t-units)
       #:ws-conn ws #:game-info w3-ginfo))
    (check-true "w17-p0-1c-cached-3x3-fallback-spot-stays-fresh-0-rpcs"
                (and (pair? (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 329))) sp-cmds-3))
                     (= (unbox rpc-cnt) 0)))
    (cleanup!))

  ;; W17-P0-2: `#1 Z` `(morph lair)` skips busy/cooldown Hatcheries & ignores non-blocking Rally orders,
  ;;           failed `1216` action-error clears cooldown, and `#17 T` trains SCV+Marine+SiegeTank cleanly!
  (define h1-busy (mk-w17-u 9931 86 1 32.0 32.0 #:hp 1500.0 #:rad 2.75
                            #:orders (list (sc2-unit-order 1632 #f 0 0.25))))
  (define h2-cd   (mk-w17-u 9932 86 1 46.0 32.0 #:hp 1500.0 #:rad 2.75))
  (define h3-rly  (mk-w17-u 9933 86 1 60.0 32.0 #:hp 1500.0 #:rad 2.75
                            #:orders (list (sc2-unit-order 212 (sc2-point2d 55.0 35.0) 0 0.0))))
  (define h4-far  (mk-w17-u 9934 86 1 90.0 32.0 #:hp 1500.0 #:rad 2.75))
  (define h5-far  (mk-w17-u 9935 86 1 110.0 32.0 #:hp 1500.0 #:rad 2.75))
  (define z-hatch-units (list h1-busy h2-cd h3-rly h4-far h5-far))
  ;; Step 1 at f=9100: morph lair selects h2-cd (closest idle Hatchery to home 32,32) and puts h2-cd on 24f cooldown
  (define lair-cmds-1
    (translate-bot-actions->sc2-raw-commands
     '((morph lair))
     (make-test-obs 9100 1500 500 z-hatch-units)))
  ;; Step 2 at f=9104 (4 frames later, h2-cd on cooldown!): MUST fall through to h3-rly (ignoring Rally order 212!)
  (define lair-cmds-2
    (translate-bot-actions->sc2-raw-commands
     '((morph lair))
     (make-test-obs 9104 1500 500 z-hatch-units)))
  (define lair-c1 (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1216))) lair-cmds-1))
  (define lair-c2 (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1216))) lair-cmds-2))
  (check-true "w17-p0-2-morph-lair-skips-busy-and-cooldown-hatcheries-and-ignores-rally-order"
              (and (sc2-raw-unit-command? lair-c1)
                   (equal? (sc2-raw-unit-command-unit-tags lair-c1) '(9932))
                   (sc2-raw-unit-command? lair-c2)
                   (equal? (sc2-raw-unit-command-unit-tags lair-c2) '(9933))))
  ;; Failed `1216` action-error on h2-cd (9932) immediately releases its cooldown so it is selectable again at f=9108!
  (define obs-lair-err
    (sc2-observation 9108 (sc2-player-common 1 1500 500 100 70 20 50 0 0 0 0)
                     z-hatch-units '() '() #f '() '() '()
                     (list (hash 'unit-tag 9932 'ability-id 1216 'result 19))
                     '() '()))
  (void (sc2-observation->runtime-obs-hash obs-lair-err))
  (define lair-cmds-3
    (translate-bot-actions->sc2-raw-commands '((morph lair)) obs-lair-err))
  (define lair-c3 (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1216))) lair-cmds-3))
  (check-true "w17-p0-2-lair-action-error-releases-cooldown-for-immediate-retry"
              (and (sc2-raw-unit-command? lair-c3)
                   (equal? (sc2-raw-unit-command-unit-tags lair-c3) '(9932))))
  ;; `#17 T` wire producer check: idle OC (with Rally order 3690), Barracks(TechLab), Factory(TechLab) train all 3!
  (define oc-u   (mk-w17-u 9940 132 1 30.0 30.0 #:hp 1500.0 #:rad 2.75
                           #:orders (list (sc2-unit-order 3690 (sc2-point2d 25.0 30.0) 0 0.0))))
  (define rax-tl (mk-w17-u 9942 37  1 38.5 29.5 #:hp 400.0 #:rad 1.0))
  (define rax-u  (mk-w17-u 9941 21  1 36.0 30.0 #:hp 1000.0 #:rad 1.5 #:addon 9942))
  (define fac-tl (mk-w17-u 9944 39  1 44.5 29.5 #:hp 400.0 #:rad 1.0))
  (define fac-u  (mk-w17-u 9943 27  1 42.0 30.0 #:hp 1250.0 #:rad 1.5 #:addon 9944))
  (define t17-cmds
    (translate-bot-actions->sc2-raw-commands
     '((train scv) (train marine) (train siege-tank))
     (make-test-obs 6200 1800 500 (list oc-u rax-u rax-tl fac-u fac-tl))))
  (check-true "w17-p0-2-terran-trains-scv-marine-siege-tank-despite-rally-order"
              (and (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 524))) t17-cmds)
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 560))) t17-cmds)
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 591))) t17-cmds)))

  ;; W17-P0-2b (`#17`/`#11` salvage APM-burn freeze defense-in-depth):
  ;;   1. Loaded Bunker (cargo > 0) MUST NOT emit salvage (32);
  ;;   2. Empty completed Bunker emits salvage (32) once as non-urgent P3 (NEVER P0!), then enters >=112f cooldown;
  ;;   3. Repeated `(salvage ...)` spam NEVER drains APM governor or starves P1 macro `(train scv/marine)`!
  (define bnk-loaded (sc2-unit 1 1 9945 24 1 (sc2-point3d 48.0 30.0 8.0) 0.0 1.5 1.0 0 #f #t #f
                               400.0 400.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #f #f '() 0 '() 0 0 0.0 0 0 0 0 '() 2 4))
  (define bnk-empty  (sc2-unit 1 1 9946 24 1 (sc2-point3d 52.0 30.0 8.0) 0.0 1.5 1.0 0 #f #t #f
                               400.0 400.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #f #f '() 0 '() 0 0 0.0 0 0 0 0 '() 0 4))
  (define salv-cmds-1
    (translate-bot-actions->sc2-raw-commands
     '((salvage 9945) (salvage 9946))
     (make-test-obs 6300 800 200 (list oc-u bnk-loaded bnk-empty))))
  (define salv-c1 (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 32))) salv-cmds-1))
  (define salv-cmds-2
    (translate-bot-actions->sc2-raw-commands
     '((salvage 9946))
     (make-test-obs 6304 800 200 (list oc-u bnk-loaded bnk-empty))))
  (define salv-cmds-3
    (translate-bot-actions->sc2-raw-commands
     '((salvage 9946))
     (make-test-obs 6416 800 200 (list oc-u bnk-loaded bnk-empty))))
  (check-true "w17-p0-2b-salvage-requires-empty-bunker-p3-non-urgent-and-112f-cooldown"
              (and (sc2-raw-unit-command? salv-c1)
                   (equal? (sc2-raw-unit-command-unit-tags salv-c1) '(9946))
                   (not (urgent-survival-cmd? salv-c1))
                   (= (wire-cmd-priority-tier salv-c1) 3)
                   (null? (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 32))) salv-cmds-2))
                   (pair? (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 32))) salv-cmds-3))))
  ;; Verify 50 steps of repeated `(salvage 9946)` + `(train scv)` NEVER starves P1 SCV training under APM governor!
  (define salv-gov (make-wire-apm-governor))
  (define p1-scv-emitted
    (for/sum ([k (in-range 50)])
      (define lp (+ 6500 (* 4 k)))
      (define raws (translate-bot-actions->sc2-raw-commands
                    '((salvage 9946) (train scv))
                    (make-test-obs lp 800 200 (list oc-u bnk-empty))))
      (define govd (govern-sc2-wire-actions! salv-gov raws lp))
      (if (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 524))) govd)
          1 0)))
  (check-true "w17-p0-2b-repeated-salvage-never-starves-p1-macro-under-apm-governor"
              (= p1-scv-emitted 50))

  ;; W17-P0-3: `#28 Z` (`550s 0G`) & `#10 Z` (`243s 0G`) emergency gas-harvest fallback under hovering air
  ;; Case 1: All bases unsafe under hovering Tempests (`19G`, `0` gas workers) -> assigns to SAFEST Extractor
  ;;         (prefers air-only threatened Extractor 9955 over ground-zealot-camped Extractor 9956!)
  (define th-m  (mk-w17-u 9951 100 1 32.0 32.0 #:hp 2000.0 #:rad 2.75 #:assigned 16 #:ideal 16))
  (define th-n  (mk-w17-u 9952 86  1 64.0 32.0 #:hp 1500.0 #:rad 2.75 #:assigned 16 #:ideal 16))
  (define ex-air-only (mk-w17-u 9955 88 1 28.0 26.0 #:hp 500.0 #:rad 1.5 #:assigned 0 #:ideal 3 #:vesp 1800))
  (define ex-gnd-camp (mk-w17-u 9956 88 1 60.0 26.0 #:hp 500.0 #:rad 1.5 #:assigned 0 #:ideal 3 #:vesp 1800))
  (define min-m (mk-w17-u 9957 341 3 25.0 32.0 #:hp 1000.0 #:rad 1.0))
  (define min-n (mk-w17-u 9958 341 3 57.0 32.0 #:hp 1000.0 #:rad 1.0))
  (define z-drones-1
    (for/list ([i (in-range 20)])
      (mk-w17-u (+ 9960 i) 104 1
                (+ (if (< i 10) 27.0 59.0) (* 0.25 (modulo i 5)))
                (+ 31.0 (* 0.3 (quotient (modulo i 10) 5)))
                #:hp 40.0 #:rad 0.375
                #:orders (list (sc2-unit-order 298 #f (if (< i 10) 9957 9958) 0.0)))))
  (define tempests-both
    (list (mk-w17-u 9991 496 4 38.0 36.0 #:hp 200.0 #:shield 100.0 #:rad 1.25 #:flying? #t)
          (mk-w17-u 9992 496 4 39.5 36.0 #:hp 200.0 #:shield 100.0 #:rad 1.25 #:flying? #t)
          (mk-w17-u 9993 496 4 70.0 36.0 #:hp 200.0 #:shield 100.0 #:rad 1.25 #:flying? #t)
          (mk-w17-u 9994 496 4 71.5 36.0 #:hp 200.0 #:shield 100.0 #:rad 1.25 #:flying? #t)
          ;; Close enemy ground Zealot right on top of `ex-gnd-camp` (60, 26)!
          (mk-w17-u 9995 73  4 61.0 27.0 #:hp 100.0 #:shield 50.0 #:rad 0.5 #:flying? #f)))
  (define obs-gas-lock
    (sc2-observation 12500 (sc2-player-common 1 600 19 80 44 4 20 0 0 0 0)
                     (append (list th-m th-n ex-air-only ex-gnd-camp min-m min-n) z-drones-1 tempests-both)
                     '() '() #f '() '() '() '() '() '()))
  (define gas-fb-cmds (saturate-workers-and-gas-commands obs-gas-lock))
  (check-true "w17-p0-3-hovering-tempests-19g-assigns-drone-to-safest-extractor"
              (ormap (lambda (c)
                       (and (sc2-raw-unit-command? c)
                            (= (sc2-raw-unit-command-ability-id c) 3666)
                            (= (sc2-raw-unit-command-target-unit-tag c) 9955)))
                     gas-fb-cmds))

  ;; Case 2: Safe 3rd Hatchery (0 Extractors!) + unsafe Main with 3 Drones ALREADY mining safest Extractor 9955
  ;;         at 19G: `0b` evacuation MUST NOT pull those 3 emergency gas Drones off 9955 (zero oscillation)!
  (define th-3rd (mk-w17-u 9953 86 1 96.0 32.0 #:hp 1500.0 #:rad 2.75 #:assigned 6 #:ideal 16))
  (define min-3  (mk-w17-u 9959 341 3 103.0 32.0 #:hp 1000.0 #:rad 1.0))
  (define ex-air-full (mk-w17-u 9955 88 1 28.0 26.0 #:hp 500.0 #:rad 1.5 #:assigned 3 #:ideal 3 #:vesp 1800))
  (define gas-drones-3
    (for/list ([i (in-range 3)])
      (mk-w17-u (+ 9980 i) 104 1 (+ 28.5 (* 0.3 i)) 27.5 #:hp 40.0 #:rad 0.375
                #:orders (list (sc2-unit-order 298 #f 9955 0.0)))))
  (define obs-gas-hold
    (sc2-observation 12504 (sc2-player-common 1 600 19 80 47 4 23 0 0 0 0)
                     (append (list th-m th-n th-3rd ex-air-full ex-gnd-camp min-m min-n min-3)
                             z-drones-1 gas-drones-3 tempests-both)
                     '() '() #f '() '() '() '() '() '()))
  (define gas-hold-cmds (saturate-workers-and-gas-commands obs-gas-hold))
  (check-true "w17-p0-3-evacuation-protects-emergency-gas-drones-from-pulloff"
              (not (ormap (lambda (c)
                            (and (sc2-raw-unit-command? c)
                                 (ormap (lambda (gt) (memv gt (sc2-raw-unit-command-unit-tags c)))
                                        '(9980 9981 9982))))
                          gas-hold-cmds)))

  ;; Case 3: When gas is already banked (>= 300G) and all Extractor bases are unsafe, do NOT force workers into unsafe gas!
  (define obs-gas-banked
    (sc2-observation 12508 (sc2-player-common 1 600 320 80 44 4 20 0 0 0 0)
                     (append (list th-m th-n th-3rd ex-air-only ex-gnd-camp min-m min-n min-3)
                             z-drones-1 tempests-both)
                     '() '() #f '() '() '() '() '() '()))
  (define gas-banked-cmds (saturate-workers-and-gas-commands obs-gas-banked))
  (check-true "w17-p0-3-no-unsafe-gas-assignment-when-gas-already-banked"
              (not (ormap (lambda (c)
                            (and (sc2-raw-unit-command? c)
                                 (memv (sc2-raw-unit-command-target-unit-tag c) '(9955 9956))))
                          gas-banked-cmds))))

(printf "[Wave 18] Testing P1 macro-econ gas resat & P3 rescue, cargo fallback, gentle 1-worker pull, Factory TechLab nudge, and <3:30 rush placement...\n")
(let ()
  (define (mk-w18-u tag utype alliance x y
                    #:hp [hp 100.0] #:shield [sh 0.0] #:rad [rad 1.0]
                    #:bp [bp 1.0] #:flying? [fly? #f] #:powered? [pow? #t]
                    #:orders [ords '()] #:addon [addon 0] #:buffs [buffs '()]
                    #:assigned [asgn 0] #:ideal [idl 0]
                    #:mins [mins 0] #:vesp [vesp 0])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 2)
              (sc2-point3d x y (if fly? 12.0 8.0)) 0.0 rad bp 0 #f #f #f
              hp hp sh sh 0.0 0.0 mins vesp fly? #f #f pow? #f
              ords addon buffs asgn idl 0.0 0 0 0 0 '() 0 0))

  (define (w18-start-mock-ws decide-fn)
    (define-values (c-in s-out) (make-pipe))
    (define-values (s-in c-out) (make-pipe))
    (define ws (sc2-ws-conn "127.0.0.1" 59918 "/sc2api" c-in c-out #f 1))
    (define rpc-cnt (box 0))
    (define th
      (thread
       (lambda ()
         (let lp ()
           (define b0 (read-byte s-in))
           (unless (eof-object? b0)
             (define b1 (read-byte s-in))
             (define masked? (not (zero? (bitwise-and b1 #x80))))
             (define len0 (bitwise-and b1 #x7F))
             (define plen
               (cond [(< len0 126) len0]
                     [(= len0 126) (integer-bytes->integer (read-bytes 2 s-in) #f #t)]
                     [else (integer-bytes->integer (read-bytes 8 s-in) #f #t)]))
             (define mkey (if masked? (read-bytes 4 s-in) #f))
             (define raw (read-bytes plen s-in))
             (define payload
               (if masked?
                   (let ([out (make-bytes plen)])
                     (for ([i (in-range plen)])
                       (bytes-set! out i (bitwise-xor (bytes-ref raw i) (bytes-ref mkey (modulo i 4)))))
                     out)
                   raw))
             (set-box! rpc-cnt (add1 (unbox rpc-cnt)))
             (define req-f (decode-protobuf-message payload))
             (define req-id-p (assoc 97 req-f))
             (define id-b (if req-id-p (encode-uint32 97 (third req-id-p)) #""))
             (define q-p (assoc 14 req-f))
             (when q-p
               (define qf (decode-protobuf-message (third q-p)))
               (define p-items (filter (lambda (e) (= (first e) 3)) qf))
               (define res-b
                 (apply bytes-append
                        (for/list ([it (in-list p-items)])
                          (define itf (decode-protobuf-message (third it)))
                          (define ab (let ([p (assoc 1 itf)]) (if p (third p) 0)))
                          (define tp-e (assoc 2 itf))
                          (define-values (px py)
                            (if tp-e
                                (let ([ptf (decode-protobuf-message (third tp-e))])
                                  (values (let ([xp (assoc 1 ptf)])
                                            (if (and xp (bytes? (third xp)))
                                                (floating-point-bytes->real (third xp) #f)
                                                0.0))
                                          (let ([yp (assoc 2 ptf)])
                                            (if (and yp (bytes? (third yp)))
                                                (floating-point-bytes->real (third yp) #f)
                                                0.0))))
                                (values 0.0 0.0)))
                          (encode-submessage-field 3 (encode-int32 1 (decide-fn ab px py))))))
               (define resp (bytes-append (encode-submessage-field 14 res-b) id-b (encode-int32 99 3)))
               (define rlen (bytes-length resp))
               (define rhdr
                 (cond [(< rlen 126) (bytes #x82 rlen)]
                       [(<= rlen 65535) (bytes-append (bytes #x82 126) (integer->integer-bytes rlen 2 #f #t))]
                       [else (bytes-append (bytes #x82 127) (integer->integer-bytes rlen 8 #f #t))]))
               (write-bytes rhdr s-out)
               (write-bytes resp s-out)
               (flush-output s-out))
             (lp))))))
    (values ws rpc-cnt
            (lambda ()
              (close-output-port c-out)
              (close-input-port c-in)
              (thread-wait th))))

  ;; W18-P0-2a: Gas resat elevated to P1 (`macro-econ-cmd?`, preserved across `coalesce-sc2-raw-commands`)
  ;;            NEVER starves under continuous 8-cmd/step P2 combat micro (`>= 80/100`, was `0/100`),
  ;;            AND routine unmarked P3 gather gets rescued via `>= 24f` overdue rescue!
  (set-box! SC2-GAS-PULL-HYSTERESIS-LATCH #f)
  (define cc-18  (mk-w18-u 9801 18 1 28.5 28.5 #:hp 1500.0 #:rad 2.75 #:assigned 14 #:ideal 16))
  (define ref-18 (mk-w18-u 9802 20 1 25.0 23.0 #:hp 500.0 #:rad 1.5 #:assigned 0 #:ideal 3 #:vesp 1800))
  (define min-18 (mk-w18-u 9803 341 3 22.0 28.5 #:hp 1000.0 #:rad 1.0 #:mins 1500))
  (define scvs-18
    (for/list ([i (in-range 14)])
      (mk-w18-u (+ 9810 i) 45 1 (+ 24.5 (* 0.3 (modulo i 5))) (+ 27.5 (* 0.4 (quotient i 5)))
                #:hp 45.0 #:rad 0.375
                #:orders (list (sc2-unit-order 295 #f 9803 0.0)))))
  (define obs-resat-18
    (sc2-observation 7000 (sc2-player-common 1 500 19 80 42 14 14 0 0 0 0)
                     (append (list cc-18 ref-18 min-18) scvs-18)
                     '() '() #f '() '() '() '() '() '()))
  (define resat-cmds-18 (saturate-workers-and-gas-commands obs-resat-18))
  (define gas-cmd-18
    (findf (lambda (c)
             (and (sc2-raw-unit-command? c)
                  (= (sc2-raw-unit-command-ability-id c) 3666)
                  (= (sc2-raw-unit-command-target-unit-tag c) 9802)))
           resat-cmds-18))
  (check-true "w18-p0-2a-gas-resat-tagged-macro-econ-tier-1"
              (and (sc2-raw-unit-command? gas-cmd-18)
                   (macro-econ-cmd? gas-cmd-18)
                   (= (wire-cmd-priority-tier gas-cmd-18) 1)))
  (define coal-18
    (coalesce-sc2-raw-commands (list gas-cmd-18)
                               (seteqv 3666)
                               (lambda (xs _n) (list xs))))
  (check-true "w18-p0-2a-coalesce-preserves-macro-econ-tag"
              (and (= (length coal-18) 1)
                   (macro-econ-cmd? (first coal-18))
                   (= (wire-cmd-priority-tier (first coal-18)) 1)))
  (define gov-18 (make-wire-apm-governor #:target-apm 410.0 #:hard-cap-apm 485.0))
  (define p1-gas-emitted 0)
  (for ([step (in-range 100)])
    (define lp (+ 7000 (* 4 step)))
    (define p2-micro
      (for/list ([k (in-range 8)])
        (sc2-raw-unit-command 16 (sc2-point2d (+ 60.0 k) (+ 60.0 (modulo step 5)))
                              0 (list (+ 8100 k)) #f)))
    (define fresh-gas-cmds (saturate-workers-and-gas-commands
                            (sc2-observation lp (sc2-player-common 1 500 19 80 42 14 14 0 0 0 0)
                                             (append (list cc-18 ref-18 min-18) scvs-18)
                                             '() '() #f '() '() '() '() '() '())))
    (define out (govern-sc2-wire-actions! gov-18 (append p2-micro fresh-gas-cmds) lp))
    (when (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                  (= (sc2-raw-unit-command-target-unit-tag c) 9802)))
                 out)
      (set! p1-gas-emitted (add1 p1-gas-emitted))))
  ;; L61 (`#1609`): With `32f` per-geyser retry throttling across 400 loops (`7000..7396`), zero-worker
  ;; P1 gas rescue emits cleanly every ~32f (`>= 10` times) with 0 starvation under steady P2 combat micro!
  (check-true "w18-p0-2a-p1-gas-resat-never-starved-under-steady-p2-combat-micro"
              (>= p1-gas-emitted 10))
  ;; Separate governor stress test: steady 8-cmd/step P2 combat micro + 1 routine unmarked P3 gather/step
  ;; -> P3 `>= 24f` overdue rescue emits `>= 10/100` (was `0/100`!) while P2 pins tokens around `4.0..5.22`!
  (define gov-18-p3 (make-wire-apm-governor #:target-apm 410.0 #:hard-cap-apm 485.0))
  (define p3-routine-emitted 0)
  (for ([step (in-range 100)])
    (define lp (+ 7000 (* 4 step)))
    (define p2-micro
      (for/list ([k (in-range 8)])
        (sc2-raw-unit-command 16 (sc2-point2d (+ 60.0 k) (+ 60.0 (modulo step 5)))
                              0 (list (+ 8200 k)) #f)))
    (define routine-p3 (sc2-raw-unit-command 3666 #f 9803 '(9899) #f))
    (define out (govern-sc2-wire-actions! gov-18-p3 (append p2-micro (list routine-p3)) lp))
    (when (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                  (equal? (sc2-raw-unit-command-unit-tags c) '(9899))))
                 out)
      (set! p3-routine-emitted (add1 p3-routine-emitted))))
  (check-true "w18-p0-2a-p3-overdue-rescue-fires-under-steady-p2-combat-micro"
              (>= p3-routine-emitted 10))

  ;; W18-P0-2b: `eligible-for-gas?` skips carrying-cargo workers (picking clean empty worker instead),
  ;;            and falls back cleanly when ALL workers hold minerals (`buff 271`) at `0` gas workers & `< 180G`!
  (set-box! SC2-GAS-PULL-HYSTERESIS-LATCH #f)
  (define scv-close-carrying
    (mk-w18-u 9831 45 1 25.5 24.5 #:hp 45.0 #:rad 0.375 #:buffs '(271)
              #:orders (list (sc2-unit-order 295 #f 9803 0.0))))
  (define scv-farther-empty
    (mk-w18-u 9832 45 1 27.5 27.5 #:hp 45.0 #:rad 0.375 #:buffs '()
              #:orders (list (sc2-unit-order 295 #f 9803 0.0))))
  (define filler-carrying-scvs
    (for/list ([i (in-range 10)])
      (mk-w18-u (+ 9833 i) 45 1 (+ 23.0 (* 0.3 i)) 29.0 #:hp 45.0 #:rad 0.375 #:buffs '(271)
                #:orders (list (sc2-unit-order 295 #f 9803 0.0)))))
  (define obs-cargo-mix
    (sc2-observation 7500 (sc2-player-common 1 500 19 80 30 12 12 0 0 0 0)
                     (append (list cc-18 ref-18 min-18 scv-close-carrying scv-farther-empty) filler-carrying-scvs)
                     '() '() #f '() '() '() '() '() '()))
  (define cargo-mix-cmds (saturate-workers-and-gas-commands obs-cargo-mix))
  (check-true "w18-p0-2b-prefers-non-carrying-worker-over-closer-mineral-carrier"
              (ormap (lambda (c)
                       (and (sc2-raw-unit-command? c)
                            (= (sc2-raw-unit-command-target-unit-tag c) 9802)
                            (equal? (sc2-raw-unit-command-unit-tags c) '(9832))))
                     cargo-mix-cmds))
  ;; ALL 11 mineral workers carrying mineral (`buff 271`) at 0 active gas workers & 19G:
  ;; fallback MUST still assign the closest mineral-carrier (`9831`) to Refinery `9802` at P1!
  (define obs-all-carrying
    (sc2-observation 7504 (sc2-player-common 1 500 19 80 30 11 11 0 0 0 0)
                     (append (list cc-18 ref-18 min-18 scv-close-carrying) filler-carrying-scvs)
                     '() '() #f '() '() '() '() '() '()))
  (define all-carrying-cmds (saturate-workers-and-gas-commands obs-all-carrying))
  (check-true "w18-p0-2b-zero-gas-fallback-assigns-mineral-carrier-at-p1"
              (ormap (lambda (c)
                       (and (sc2-raw-unit-command? c)
                            (= (sc2-raw-unit-command-target-unit-tag c) 9802)
                            (macro-econ-cmd? c)
                            (equal? (sc2-raw-unit-command-unit-tags c) '(9831))))
                     all-carrying-cmds))

  ;; W18-P0-2c: Gentle 1-worker pull at `200..349G & < 100M` (never drops to 0 below 350G),
  ;;            full pull still fires at `>= 350G`, and latch clears cleanly at `>= 220M` OR `< 180G`!
  (define (mk-gas-state-obs lp mins vesp n-gas)
    (define ref-g (mk-w18-u 9802 20 1 25.0 23.0 #:hp 500.0 #:rad 1.5 #:assigned n-gas #:ideal 3 #:vesp 1800))
    (define gas-ws
      (for/list ([i (in-range n-gas)])
        (mk-w18-u (+ 9860 i) 45 1 (+ 25.0 (* 0.2 i)) 24.2 #:hp 45.0 #:rad 0.375
                  #:orders (list (sc2-unit-order 295 #f 9802 0.0)))))
    (sc2-observation lp (sc2-player-common 1 mins vesp 80 40 (+ 14 n-gas) (+ 14 n-gas) 0 0 0 0)
                     (append (list cc-18 ref-g min-18) gas-ws scvs-18)
                     '() '() #f '() '() '() '() '() '()))
  (set-box! SC2-GAS-PULL-HYSTERESIS-LATCH #f)
  (define mild-pull-2 (saturate-workers-and-gas-commands (mk-gas-state-obs 7620 60 220 2)))
  (check-true "w18-p0-2c-mild-mineral-starve-trims-2-to-1-at-p1"
              (ormap (lambda (c)
                       (and (sc2-raw-unit-command? c)
                            (= (sc2-raw-unit-command-target-unit-tag c) 9803)
                            (macro-econ-cmd? c)
                            (or (memv 9860 (sc2-raw-unit-command-unit-tags c))
                                (memv 9861 (sc2-raw-unit-command-unit-tags c)))))
                     mild-pull-2))
  (define mild-hold-1 (saturate-workers-and-gas-commands (mk-gas-state-obs 7624 60 220 1)))
  (check-true "w18-p0-2c-mild-mineral-starve-keeps-1-gas-worker-never-zeroes-below-350g"
              (and (not (ormap (lambda (c)
                                 (and (sc2-raw-unit-command? c)
                                      (memv 9860 (sc2-raw-unit-command-unit-tags c))))
                               mild-hold-1))
                   (not (ormap (lambda (c)
                                 (and (sc2-raw-unit-command? c)
                                      (= (sc2-raw-unit-command-target-unit-tag c) 9802)))
                               mild-hold-1))))
  (define high-pull-1 (saturate-workers-and-gas-commands (mk-gas-state-obs 7660 110 380 1)))
  (check-true "w18-p0-2c-high-gas-380g-still-pulls-down-to-0"
              (ormap (lambda (c)
                       (and (sc2-raw-unit-command? c)
                            (= (sc2-raw-unit-command-target-unit-tag c) 9803)
                            (memv 9860 (sc2-raw-unit-command-unit-tags c))))
                     high-pull-1))
  ;; Latch set from 380G/110M: recovering minerals to 285M (at 240G) after >= 112f clears latch & resaturates (P3)!
  (define latch-clear-min (saturate-workers-and-gas-commands (mk-gas-state-obs 7780 285 240 1)))
  (check-true "w18-p0-2c-hysteresis-latch-clears-at-285m-and-resaturates-at-p3"
              (and (not (unbox SC2-GAS-PULL-HYSTERESIS-LATCH))
                   (ormap (lambda (c)
                            (and (sc2-raw-unit-command? c)
                                 (= (sc2-raw-unit-command-target-unit-tag c) 9802)
                                 (= (wire-cmd-priority-tier c) 3)))
                          latch-clear-min)))
  ;; Re-latch at 320G/110M (>= 112f after fill), then drop gas to 125G (at 120M) >= 112f later -> clears latch & resats (L61C P1 < 180G)!
  (void (saturate-workers-and-gas-commands (mk-gas-state-obs 7900 110 320 2)))
  (define latch-clear-gas (saturate-workers-and-gas-commands (mk-gas-state-obs 8020 120 125 1)))
  (check-true "w18-p0-2c-hysteresis-latch-clears-at-125g-and-resaturates-at-p1"
              (and (not (unbox SC2-GAS-PULL-HYSTERESIS-LATCH))
                   (ormap (lambda (c)
                            (and (sc2-raw-unit-command? c)
                                 (= (sc2-raw-unit-command-target-unit-tag c) 9802)
                                 (macro-econ-cmd? c)
                                 (= (wire-cmd-priority-tier c) 1)))
                          latch-clear-gas)))

  ;; W18-P0-3: `#14` `factory-techlab` ignores non-blocking Rally order (`3690`) AND issues in-place
  ;;           add-on build (`454`, `target-pos = #f`) when a locally-clear East slot fails `QueryPlacement 319`
  ;;           ONLY because a friendly SCV is walking across `(fx+2.5, fy-0.5)`!
  (hash-clear! SC2-ADDON-SLOT-BLOCKED-CACHE)
  (let-values ([(ws _rpc-cnt cleanup!)
                (w18-start-mock-ws (lambda (ab _px _py) (if (= ab 319) 2 1)))])
    (define fac-rly (mk-w18-u 9851 27 1 34.5 30.5 #:hp 1250.0 #:rad 1.5
                              #:orders (list (sc2-unit-order 3690 (sc2-point2d 44.0 34.0) 0 0.0))))
    (define scv-on-slot (mk-w18-u 9852 45 1 37.0 30.0 #:hp 45.0 #:rad 0.375))
    (define addon-cmds
      (translate-bot-actions->sc2-raw-commands
       '((build factory-techlab))
       (make-test-obs 6200 200 100 (list cc-18 fac-rly scv-on-slot))
       #:ws-conn ws #:game-info w3-ginfo))
    (define tl-cmd
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 454)))
             addon-cmds))
    (check-true "w18-p0-3-factory-techlab-ignores-rally-and-builds-inplace-when-friendly-unit-on-east-slot"
                (and (sc2-raw-unit-command? tl-cmd)
                     (equal? (sc2-raw-unit-command-unit-tags tl-cmd) '(9851))
                     (not (sc2-raw-unit-command-target-pos tl-cmd))))
    (cleanup!))

  (define (w18-dist x1 y1 x2 y2)
    (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))

  ;; W18-P0-1: `<3:30` early-rush 2nd Gateway & 1-base Barracks pivot safely to uncontested in-main spots!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-clear! SC2-TERRAN-5X3-MISS-CACHE)
  (let-values ([(ws _rpc-cnt cleanup!) (w18-start-mock-ws (lambda (_ab _px _py) 1))])
    ;; Protoss `<3:30` (`f=2400`): natural Pylon (52,30) surrounded by 6 Zerglings, safe main Pylon at (28,34)
    (define nex-18 (mk-w18-u 9871 59 1 28.5 28.5 #:hp 1000.0 #:shield 1000.0 #:rad 2.75))
    (define py-main (mk-w18-u 9872 60 1 28.0 34.0 #:hp 200.0 #:shield 200.0 #:rad 1.0))
    (define py-nat  (mk-w18-u 9873 60 1 52.0 30.0 #:hp 200.0 #:shield 200.0 #:rad 1.0))
    (define prb-18  (mk-w18-u 9874 84 1 29.0 32.0 #:hp 20.0 #:shield 20.0 #:rad 0.375))
    (define lings-nat
      (for/list ([i (in-range 6)])
        (mk-w18-u (+ 9875 i) 105 4 (+ 51.0 (* 0.5 i)) 30.0 #:hp 35.0 #:rad 0.375)))
    (define obs-p-rush
      (sc2-observation 2400 (sc2-player-common 1 250 50 31 20 2 18 0 0 0 0)
                       (append (list nex-18 py-main py-nat prb-18) lings-nat)
                       '()
                       (list (sc2-power-source (sc2-point2d 28.0 34.0) 6.5 9872)
                             (sc2-power-source (sc2-point2d 52.0 30.0) 6.5 9873))
                       #f '() '() '() '() '() '()))
    (define gw-cmds
      (translate-bot-actions->sc2-raw-commands
       '((build gateway 52.0 30.0))
       obs-p-rush #:ws-conn ws #:game-info w3-ginfo))
    (define gw-cmd
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 883))) gw-cmds))
    (define gw-pt (and gw-cmd (sc2-raw-unit-command-target-pos gw-cmd)))
    (check-true "w18-p0-1-early-rush-2nd-gateway-pivots-to-uncontested-inmain-pylon"
                (and (sc2-point2d? gw-pt)
                     (< (w18-dist (sc2-point2d-x gw-pt) (sc2-point2d-y gw-pt) 28.0 34.0) 8.0)
                     (> (w18-dist (sc2-point2d-x gw-pt) (sc2-point2d-y gw-pt) 52.0 30.0) 12.0)))

    ;; Terran 1-base `<3:30` (`f=2400`): Zerglings attacking requested Barracks spot (38,30) -> pivots in-main!
    (hash-clear! SC2-PLACEMENT-POS-CACHE)
    (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
    (define scv-t-18 (mk-w18-u 9882 45 1 27.0 29.0 #:hp 45.0 #:rad 0.375))
    (define lings-front
      (for/list ([i (in-range 6)])
        (mk-w18-u (+ 9883 i) 105 4 (+ 37.0 (* 0.4 i)) 30.0 #:hp 35.0 #:rad 0.375)))
    (define rax-cmds
      (translate-bot-actions->sc2-raw-commands
       '((build barracks 38.0 30.0))
       (make-test-obs 2400 250 50 (append (list cc-18 min-18 scv-t-18) lings-front))
       #:ws-conn ws #:game-info w3-ginfo))
    (define rax-cmd
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 321))) rax-cmds))
    (define rax-pt (and rax-cmd (sc2-raw-unit-command-target-pos rax-cmd)))
    (check-true "w18-p0-1-early-rush-1base-barracks-pivots-away-from-zerglings-to-inmain-safe-spot"
                (and (sc2-point2d? rax-pt)
                     (> (w18-dist (sc2-point2d-x rax-pt) (sc2-point2d-y rax-pt) 38.0 30.0) 5.5)))
    (cleanup!)))

(printf "[Loop 19] Testing L19-P0-1 dynamic gas-to-mineral rebalance (18/28 floors, all-worker-count hysteresis, 2/step + carrying pull, GasZeroFreeze=0)...\n")
(let ()
  (define (mk-l19-u tag utype alliance x y
                    #:hp [hp 100.0] #:rad [rad 1.0] #:orders [ords '()] #:buffs [buffs '()]
                    #:assigned [asgn 0] #:ideal [idl 0] #:mins [mins 0] #:vesp [vesp 0])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 2)
              (sc2-point3d x y 8.0) 0.0 rad 1.0 0 #f #f #f
              hp hp 0.0 0.0 0.0 0.0 mins vesp #f #f #f #t #f
              ords 0 buffs asgn idl 0.0 0 0 0 0 '() 0 0))

  (define th-1 (mk-l19-u 9601 18 1 28.5 28.5 #:hp 1500.0 #:rad 2.75 #:assigned 16 #:ideal 16))
  (define th-2 (mk-l19-u 9602 18 1 60.5 28.5 #:hp 1500.0 #:rad 2.75 #:assigned 16 #:ideal 16))
  (define min-1 (mk-l19-u 9603 341 3 22.0 28.5 #:hp 1000.0 #:rad 1.0 #:mins 1500))
  (define min-2 (mk-l19-u 9604 341 3 67.0 28.5 #:hp 1000.0 #:rad 1.0 #:mins 1500))
  (define (mk-min-scvs start-tag n base-x min-tag)
    (for/list ([i (in-range n)])
      (mk-l19-u (+ start-tag i) 45 1
                (+ base-x (* 0.25 (modulo i 8)))
                (+ 27.0 (* 0.35 (quotient i 8)))
                #:hp 45.0 #:rad 0.375
                #:orders (list (sc2-unit-order 295 #f min-tag 0.0)))))

  ;; L19-P0-1a: 2nd geyser (slots 3..5) requires >= 18 mineral workers when < 300M (even with 1 worker inside 1st Refinery!),
  ;;            and immediately allows filling at 18 mineral workers OR >= 300M!
  (set-box! SC2-GAS-PULL-HYSTERESIS-LATCH #f)
  (define ref-1-full (mk-l19-u 9611 20 1 25.0 23.0 #:hp 500.0 #:rad 1.5 #:assigned 3 #:ideal 3 #:vesp 1800))
  (define ref-2-empty (mk-l19-u 9612 20 1 32.0 23.0 #:hp 500.0 #:rad 1.5 #:assigned 0 #:ideal 3 #:vesp 1800))
  ;; 2 visible gas workers + 1 inside Refinery 9611 (`assigned = 3` -> `eff-active-gas-workers = 3`)!
  (define gas-vis-2
    (list (mk-l19-u 9621 45 1 25.2 24.2 #:hp 45.0 #:rad 0.375 #:orders (list (sc2-unit-order 295 #f 9611 0.0)))
          (mk-l19-u 9622 45 1 25.6 24.4 #:hp 45.0 #:rad 0.375 #:orders (list (sc2-unit-order 295 #f 9611 0.0)))))
  (define cmds-2nd-16min
    (saturate-workers-and-gas-commands
     (sc2-observation 4000 (sc2-player-common 1 180 60 50 30 19 19 0 0 0 0)
                      (append (list th-1 min-1 ref-1-full ref-2-empty) gas-vis-2 (mk-min-scvs 9630 16 23.0 9603))
                      '() '() #f '() '() '() '() '() '())))
  (check-true "l19-p0-1a-2nd-geyser-blocked-at-16-mineral-workers-below-300m"
              (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-target-unit-tag c) 9612)))
                          cmds-2nd-16min)))
  (define cmds-2nd-18min
    (saturate-workers-and-gas-commands
     (sc2-observation 4004 (sc2-player-common 1 180 60 50 32 21 21 0 0 0 0)
                      (append (list th-1 th-2 min-1 min-2 ref-1-full ref-2-empty) gas-vis-2
                              (mk-min-scvs 9630 14 23.0 9603) (mk-min-scvs 9650 4 64.0 9604))
                      '() '() #f '() '() '() '() '() '())))
  (check-true "l19-p0-1a-2nd-geyser-fills-at-18-mineral-workers"
              (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                      (= (sc2-raw-unit-command-target-unit-tag c) 9612)
                                      (macro-econ-cmd? c)
                                      (= (wire-cmd-priority-tier c) 1)))
                     cmds-2nd-18min))
  (define cmds-2nd-16min-320m
    (saturate-workers-and-gas-commands
     (sc2-observation 4040 (sc2-player-common 1 320 60 50 30 19 19 0 0 0 0)
                      (append (list th-1 min-1 ref-1-full ref-2-empty) gas-vis-2 (mk-min-scvs 9630 16 23.0 9603))
                      '() '() #f '() '() '() '() '() '())))
  (check-true "l19-p0-1a-2nd-geyser-fills-at-16-min-workers-when-320m-banked"
              (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-target-unit-tag c) 9612)))
                     cmds-2nd-16min-320m))

  ;; L19-P0-1b: 3rd+ geyser (slots 6+) requires >= 28 mineral workers when < 400M!
  (set-box! SC2-GAS-PULL-HYSTERESIS-LATCH #f)
  (define ref-2-full (mk-l19-u 9612 20 1 32.0 23.0 #:hp 500.0 #:rad 1.5 #:assigned 3 #:ideal 3 #:vesp 1800))
  (define ref-3-empty (mk-l19-u 9613 20 1 57.0 23.0 #:hp 500.0 #:rad 1.5 #:assigned 0 #:ideal 3 #:vesp 1800))
  (define gas-vis-6
    (append (for/list ([i (in-range 3)])
              (mk-l19-u (+ 9621 i) 45 1 (+ 25.0 (* 0.3 i)) 24.2 #:hp 45.0 #:rad 0.375
                        #:orders (list (sc2-unit-order 295 #f 9611 0.0))))
            (for/list ([i (in-range 3)])
              (mk-l19-u (+ 9624 i) 45 1 (+ 32.0 (* 0.3 i)) 24.2 #:hp 45.0 #:rad 0.375
                        #:orders (list (sc2-unit-order 295 #f 9612 0.0))))))
  (define cmds-3rd-24min
    (saturate-workers-and-gas-commands
     (sc2-observation 6000 (sc2-player-common 1 200 80 80 50 30 30 0 0 0 0)
                      (append (list th-1 th-2 min-1 min-2 ref-1-full ref-2-full ref-3-empty)
                              gas-vis-6 (mk-min-scvs 9630 12 23.0 9603) (mk-min-scvs 9650 12 64.0 9604))
                      '() '() #f '() '() '() '() '() '())))
  (check-true "l19-p0-1b-3rd-geyser-blocked-at-24-mineral-workers-below-400m"
              (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-target-unit-tag c) 9613)))
                          cmds-3rd-24min)))
  (define cmds-3rd-28min
    (saturate-workers-and-gas-commands
     (sc2-observation 6004 (sc2-player-common 1 200 80 80 54 34 34 0 0 0 0)
                      (append (list th-1 th-2 min-1 min-2 ref-1-full ref-2-full ref-3-empty)
                              gas-vis-6 (mk-min-scvs 9630 14 23.0 9603) (mk-min-scvs 9650 14 64.0 9604))
                      '() '() #f '() '() '() '() '() '())))
  (check-true "l19-p0-1b-3rd-geyser-fills-at-28-mineral-workers"
              (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-target-unit-tag c) 9613)))
                     cmds-3rd-28min))

  ;; L19-P0-1c + L61B (`#1641`): No 54w/66w worker-count cutoff! At 70 workers (64 min + 6 gas) on 2 bases
  ;;            & 210G/100M (GRMS `>=200G & <110M`) -> latches ON and pulls 3 gas workers (coalesced P1)!
  (set-box! SC2-GAS-PULL-HYSTERESIS-LATCH #f)
  (define cmds-70w-pull
    (saturate-workers-and-gas-commands
     (sc2-observation 9000 (sc2-player-common 1 100 210 150 120 70 70 0 0 0 0)
                      (append (list th-1 th-2 min-1 min-2 ref-1-full ref-2-full)
                              gas-vis-6 (mk-min-scvs 9630 32 23.0 9603) (mk-min-scvs 9700 32 64.0 9604))
                      '() '() #f '() '() '() '() '() '())))
  (define pulled-70w-tags
    (apply append
           (map sc2-raw-unit-command-unit-tags
                (filter (lambda (c) (and (sc2-raw-unit-command? c)
                                         (= (sc2-raw-unit-command-ability-id c) 3666)
                                         (memv (sc2-raw-unit-command-target-unit-tag c) '(9603 9604))
                                         (macro-econ-cmd? c)
                                         (ormap (lambda (t) (and (>= t 9621) (<= t 9626)))
                                                (sc2-raw-unit-command-unit-tags c))))
                        cmds-70w-pull))))
  (check-true "l19-p0-1c-70-workers-210g-100m-latches-and-pulls-3-gas-workers-per-step"
              (and (unbox SC2-GAS-PULL-HYSTERESIS-LATCH)
                   (= (length pulled-70w-tags) 3)))

  ;; L19-P0-1d: Pulls up to 2/step including carrying gas (`buff 273`, order `296 -> CC`) at `>= 200G & < 120M`
  ;;            (non-carrying first!), keeps `>= 1` gas worker strictly below `260G`, and skips carrying at `>= 120M`!
  (set-box! SC2-GAS-PULL-HYSTERESIS-LATCH #f)
  (define gw-clean (mk-l19-u 9751 45 1 25.2 24.2 #:hp 45.0 #:rad 0.375
                             #:orders (list (sc2-unit-order 295 #f 9611 0.0))))
  (define gw-carry-1 (mk-l19-u 9752 45 1 26.0 25.5 #:hp 45.0 #:rad 0.375 #:buffs '(273)
                               #:orders (list (sc2-unit-order 296 #f 9601 0.0))))
  (define gw-carry-2 (mk-l19-u 9753 45 1 26.5 26.0 #:hp 45.0 #:rad 0.375 #:buffs '(273)
                               #:orders (list (sc2-unit-order 296 #f 9601 0.0))))
  (define cmds-240g-60m
    (saturate-workers-and-gas-commands
     (sc2-observation 9100 (sc2-player-common 1 60 240 80 40 19 19 0 0 0 0)
                      (append (list th-1 min-1 ref-1-full gw-clean gw-carry-1 gw-carry-2)
                              (mk-min-scvs 9630 16 23.0 9603))
                      '() '() #f '() '() '() '() '() '())))
  (define pulled-tags-60m
    (apply append (map sc2-raw-unit-command-unit-tags
                       (filter (lambda (c) (and (sc2-raw-unit-command? c)
                                                (= (sc2-raw-unit-command-ability-id c) 3666)
                                                (= (sc2-raw-unit-command-target-unit-tag c) 9603)
                                                (macro-econ-cmd? c)))
                               cmds-240g-60m))))
  (check-true "l19-p0-1d-240g-60m-pulls-2-clean-plus-carrying-leaving-1-gas-worker"
              (and (= (length pulled-tags-60m) 2)
                   (memv 9751 pulled-tags-60m)
                   (memv 9752 pulled-tags-60m)
                   (not (memv 9753 pulled-tags-60m))))
  ;; With only 1 gas worker left at 240G/60M (< 260G), MUST pull 0 (`GasZeroFreeze = 0`)!
  (define ref-1-one (mk-l19-u 9611 20 1 25.0 23.0 #:hp 500.0 #:rad 1.5 #:assigned 1 #:ideal 3 #:vesp 1800))
  (define cmds-240g-60m-floor1
    (saturate-workers-and-gas-commands
     (sc2-observation 9104 (sc2-player-common 1 60 240 80 40 17 17 0 0 0 0)
                      (append (list th-1 min-1 ref-1-one gw-carry-2) (mk-min-scvs 9630 16 23.0 9603))
                      '() '() #f '() '() '() '() '() '())))
  (check-true "l19-p0-1d-240g-60m-keeps-last-1-gas-worker"
              (not (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                           (memv 9753 (sc2-raw-unit-command-unit-tags c))))
                          cmds-240g-60m-floor1)))
  ;; At 240G/125M (min >= 120) >= 32f later, pulls ONLY the 1 non-carrying worker 9751 (does not pull carrying gas)!
  (define cmds-240g-125m
    (saturate-workers-and-gas-commands
     (sc2-observation 9140 (sc2-player-common 1 125 240 80 40 19 19 0 0 0 0)
                      (append (list th-1 min-1 ref-1-full gw-clean gw-carry-1 gw-carry-2)
                              (mk-min-scvs 9630 16 23.0 9603))
                      '() '() #f '() '() '() '() '() '())))
  (define pulled-tags-125m
    (apply append (map sc2-raw-unit-command-unit-tags
                       (filter (lambda (c) (and (sc2-raw-unit-command? c)
                                                (= (sc2-raw-unit-command-ability-id c) 3666)
                                                (= (sc2-raw-unit-command-target-unit-tag c) 9603)))
                               cmds-240g-125m))))
  (check-true "l19-p0-1d-240g-125m-pulls-only-non-carrying-worker"
              (equal? pulled-tags-125m '(9751)))

  ;; L19-P0-1e: Deadband holds at 170G/240M, releases at < 140G or >= 280M, and 0-gas resaturates even while latched < 350G!
  (set-box! SC2-GAS-PULL-HYSTERESIS-LATCH #t)
  (define cmds-deadband
    (saturate-workers-and-gas-commands
     (sc2-observation 9300 (sc2-player-common 1 240 170 80 40 17 17 0 0 0 0)
                      (append (list th-1 min-1 ref-1-one gw-clean) (mk-min-scvs 9630 16 23.0 9603))
                      '() '() #f '() '() '() '() '() '())))
  (check-true "l19-p0-1e-deadband-holds-at-170g-240m"
              (and (unbox SC2-GAS-PULL-HYSTERESIS-LATCH)
                   (not (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                                (= (sc2-raw-unit-command-target-unit-tag c) 9611)))
                               cmds-deadband))))
  ;; Even while latched ON at 210G/110M, 0 active gas workers (< 350G) MUST immediately assign 1 worker at P1!
  (define ref-1-zero (mk-l19-u 9611 20 1 25.0 23.0 #:hp 500.0 #:rad 1.5 #:assigned 0 #:ideal 3 #:vesp 1800))
  (define cmds-latched-0gas
    (saturate-workers-and-gas-commands
     (sc2-observation 9304 (sc2-player-common 1 110 210 80 40 16 16 0 0 0 0)
                      (append (list th-1 min-1 ref-1-zero) (mk-min-scvs 9630 16 23.0 9603))
                      '() '() #f '() '() '() '() '() '())))
  (check-true "l19-p0-1e-latched-below-350g-still-resaturates-from-0-gas-workers-at-p1"
              (and (unbox SC2-GAS-PULL-HYSTERESIS-LATCH)
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                           (= (sc2-raw-unit-command-target-unit-tag c) 9611)
                                           (macro-econ-cmd? c)))
                          cmds-latched-0gas))))

(printf "[Loop 20] Testing L20-P0-1 unified emergency gas threat scoring (GasZeroFreeze=0) & <=12w worker-crisis gas evac...\n")
(let ()
  (define (mk-l20-u tag utype alliance x y
                    #:hp [hp 100.0] #:shield [sh 0.0] #:rad [rad 1.0]
                    #:flying? [fly? #f] #:orders [ords '()] #:buffs [buffs '()]
                    #:assigned [asgn 0] #:ideal [idl 0] #:mins [mins 0] #:vesp [vesp 0])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 2)
              (sc2-point3d x y (if fly? 12.0 8.0)) 0.0 rad 1.0 0 #f #f #f
              hp hp sh sh 0.0 0.0 mins vesp fly? #f #f #t #f
              ords 0 buffs asgn idl 0.0 0 0 0 0 '() 0 0))

  ;; L20-P0-1a (`#28` GasZeroFreeze 1 -> 0): Surviving Hatchery (32,32) has Extractor 9502 camped
  ;; by 6 Tempests (threat > 6,000), while distant live Extractor 9503 at (96,64) (whose Hatchery
  ;; was destroyed) has 0 threat (`score = 150.0`) -> MUST choose 9503 over 9502!
  (set-box! SC2-GAS-PULL-HYSTERESIS-LATCH #f)
  (define h-camped (mk-l20-u 9501 100 1 32.0 32.0 #:hp 2000.0 #:rad 2.75 #:assigned 14 #:ideal 16))
  (define ex-camped (mk-l20-u 9502 88 1 28.0 26.0 #:hp 500.0 #:rad 1.5 #:assigned 0 #:ideal 3 #:vesp 1800))
  (define ex-safe-far (mk-l20-u 9503 88 1 96.0 64.0 #:hp 500.0 #:rad 1.5 #:assigned 0 #:ideal 3 #:vesp 1800))
  (define min-h (mk-l20-u 9505 341 3 25.0 32.0 #:hp 1000.0 #:rad 1.0 #:mins 1500))
  (define drones-20
    (for/list ([i (in-range 14)])
      (mk-l20-u (+ 9540 i) 104 1 (+ 27.0 (* 0.3 (modulo i 5))) (+ 31.0 (* 0.4 (quotient i 5)))
                #:hp 40.0 #:rad 0.375 #:orders (list (sc2-unit-order 298 #f 9505 0.0)))))
  (define tempests-6
    (for/list ([i (in-range 6)])
      (mk-l20-u (+ 9560 i) 496 4 (+ 30.0 (* 0.8 i)) 28.0 #:hp 200.0 #:shield 100.0 #:rad 1.25 #:flying? #t)))
  (define cmds-far-safe-0
    (saturate-workers-and-gas-commands
     (sc2-observation 13000 (sc2-player-common 1 500 19 80 40 4 14 0 0 0 0)
                      (append (list h-camped ex-camped ex-safe-far min-h) drones-20 tempests-6)
                      '() '() #f '() '() '() '() '() '())))
  (check-true "l20-p0-1a-zero-threat-distant-extractor-beats-tempest-camped-near-th-extractor"
              (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                      (= (sc2-raw-unit-command-ability-id c) 3666)
                                      (= (sc2-raw-unit-command-target-unit-tag c) 9503)
                                      (macro-econ-cmd? c)))
                     cmds-far-safe-0))

  ;; Even when distant zero-threat Extractor 9503 already has 1/3 Drone assigned (while Tempest-camped
  ;; Extractor 9502 has 0/3!), Drone #2 MUST still go to safe 9503 instead of Tempest-camped 9502!
  (define ex-safe-far-1 (mk-l20-u 9503 88 1 96.0 64.0 #:hp 500.0 #:rad 1.5 #:assigned 1 #:ideal 3 #:vesp 1800))
  (define d-on-safe-far (mk-l20-u 9520 104 1 95.5 64.5 #:hp 40.0 #:rad 0.375
                                  #:orders (list (sc2-unit-order 298 #f 9503 0.0))))
  (define cmds-far-safe-1
    (saturate-workers-and-gas-commands
     (sc2-observation 13004 (sc2-player-common 1 500 19 80 41 4 15 0 0 0 0)
                      (append (list h-camped ex-camped ex-safe-far-1 min-h d-on-safe-far) drones-20 tempests-6)
                      '() '() #f '() '() '() '() '() '())))
  (check-true "l20-p0-1a-emergency-under-gas-keeps-filling-safe-extractor-over-camped-0-assigned"
              (and (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                           (= (sc2-raw-unit-command-target-unit-tag c) 9503)))
                          cmds-far-safe-1)
                   (not (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                                (= (sc2-raw-unit-command-target-unit-tag c) 9502)))
                               cmds-far-safe-1))))

  ;; Step 0b evacuation MUST protect Drone 9520 mining distant zero-threat Extractor 9503 even when
  ;; a safe Hatchery 9504 (with 0 geysers) exists elsewhere!
  (define h-safe-nogas (mk-l20-u 9504 86 1 64.0 32.0 #:hp 1500.0 #:rad 2.75 #:assigned 4 #:ideal 16))
  (define min-safe (mk-l20-u 9506 341 3 70.0 32.0 #:hp 1000.0 #:rad 1.0 #:mins 1500))
  (define cmds-far-safe-protect
    (saturate-workers-and-gas-commands
     (sc2-observation 13008 (sc2-player-common 1 500 19 80 41 4 15 0 0 0 0)
                      (append (list h-camped h-safe-nogas ex-camped ex-safe-far-1 min-h min-safe d-on-safe-far)
                              drones-20 tempests-6)
                      '() '() #f '() '() '() '() '() '())))
  (check-true "l20-p0-1a-evacuation-protects-distant-zero-threat-emergency-extractor"
              (not (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                           (memv 9520 (sc2-raw-unit-command-unit-tags c))))
                          cmds-far-safe-protect)))

  ;; L20-P0-1b (`#29` crushed worker economy `<= 12w`): 7 SCVs total (6 mineral + 1 carrying gas),
  ;; 160G / 80M -> pulls last gas worker all the way to 0 (even while carrying gas!) at P1,
  ;; blocks gas re-saturation while crisis holds, and cleanly resumes once minerals >= 120M!
  (set-box! SC2-GAS-PULL-HYSTERESIS-LATCH #f)
  (define cc-crushed (mk-l20-u 9511 18 1 28.5 28.5 #:hp 1500.0 #:rad 2.75 #:assigned 6 #:ideal 16))
  (define ref-crushed (mk-l20-u 9512 20 1 25.0 23.0 #:hp 500.0 #:rad 1.5 #:assigned 1 #:ideal 3 #:vesp 1800))
  (define min-crushed (mk-l20-u 9513 341 3 22.0 28.5 #:hp 1000.0 #:rad 1.0 #:mins 1500))
  (define scvs-6
    (for/list ([i (in-range 6)])
      (mk-l20-u (+ 9521 i) 45 1 (+ 23.5 (* 0.3 i)) 28.0 #:hp 45.0 #:rad 0.375
                #:orders (list (sc2-unit-order 295 #f 9513 0.0)))))
  (define scv-last-gas (mk-l20-u 9530 45 1 26.0 25.5 #:hp 45.0 #:rad 0.375 #:buffs '(273)
                                 #:orders (list (sc2-unit-order 296 #f 9511 0.0))))
  (define cmds-crisis-evac
    (saturate-workers-and-gas-commands
     (sc2-observation 8000 (sc2-player-common 1 80 160 50 15 8 7 0 0 0 0)
                      (append (list cc-crushed ref-crushed min-crushed scv-last-gas) scvs-6)
                      '() '() #f '() '() '() '() '() '())))
  (check-true "l20-p0-1b-worker-crisis-12w-160g-80m-evacuates-last-gas-worker-to-0-at-p3"
              (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                      (= (sc2-raw-unit-command-ability-id c) 3666)
                                      (= (sc2-raw-unit-command-target-unit-tag c) 9513)
                                      (= (wire-cmd-priority-tier c) 3)
                                      (equal? (sc2-raw-unit-command-unit-tags c) '(9530))))
                     cmds-crisis-evac))
  ;; While still crushed at 7 SCVs, 0 gas workers, 160G/80M -> MUST NOT send any worker back to gas!
  (define ref-crushed-0 (mk-l20-u 9512 20 1 25.0 23.0 #:hp 500.0 #:rad 1.5 #:assigned 0 #:ideal 3 #:vesp 1800))
  (define scv-7th-min (mk-l20-u 9530 45 1 24.0 28.5 #:hp 45.0 #:rad 0.375
                                #:orders (list (sc2-unit-order 295 #f 9513 0.0))))
  (define cmds-crisis-hold0
    (saturate-workers-and-gas-commands
     (sc2-observation 8004 (sc2-player-common 1 80 160 50 15 8 7 0 0 0 0)
                      (append (list cc-crushed ref-crushed-0 min-crushed scv-7th-min) scvs-6)
                      '() '() #f '() '() '() '() '() '())))
  (check-true "l20-p0-1b-worker-crisis-blocks-gas-resat-at-0-while-crushed"
              (not (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                           (= (sc2-raw-unit-command-target-unit-tag c) 9512)))
                          cmds-crisis-hold0)))
  ;; Once minerals recover to 130M (>= 120M) after >= 112f, crisis ends cleanly & 0-worker gas rescue resumes at P1!
  (define cmds-crisis-resume
    (saturate-workers-and-gas-commands
     (sc2-observation 8120 (sc2-player-common 1 130 160 50 15 8 7 0 0 0 0)
                      (append (list cc-crushed ref-crushed-0 min-crushed scv-7th-min) scvs-6)
                      '() '() #f '() '() '() '() '() '())))
  (check-true "l20-p0-1b-worker-crisis-resumes-gas-at-p1-once-minerals-recover"
              (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                      (= (sc2-raw-unit-command-target-unit-tag c) 9512)
                                      (macro-econ-cmd? c)))
                     cmds-crisis-resume)))

(printf "[Loop 21] Testing L21-P0-1 tightened midgame gas-pull hysteresis (>=180G/<160M, OFF <130G/>=280M, >=1 floor <300G)...\n")
(let ()
  (define (mk-l21-u tag utype alliance x y
                    #:hp [hp 100.0] #:rad [rad 1.0] #:orders [ords '()]
                    #:assigned [asgn 0] #:ideal [idl 0] #:mins [mins 0] #:vesp [vesp 0])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 2)
              (sc2-point3d x y 8.0) 0.0 rad 1.0 0 #f #f #f
              hp hp 0.0 0.0 0.0 0.0 mins vesp #f #f #f #t #f
              ords 0 '() asgn idl 0.0 0 0 0 0 '() 0 0))

  (define th-21 (mk-l21-u 9401 18 1 28.5 28.5 #:hp 1500.0 #:rad 2.75 #:assigned 16 #:ideal 16))
  (define min-21 (mk-l21-u 9403 341 3 22.0 28.5 #:hp 1000.0 #:rad 1.0 #:mins 1500))
  (define scvs-min-16
    (for/list ([i (in-range 16)])
      (mk-l21-u (+ 9430 i) 45 1 (+ 23.0 (* 0.25 (modulo i 8))) (+ 27.0 (* 0.35 (quotient i 8)))
                #:hp 45.0 #:rad 0.375 #:orders (list (sc2-unit-order 295 #f 9403 0.0)))))
  (define (mk-l21-obs lp mins vesp n-gas)
    (define ref-u (mk-l21-u 9402 20 1 25.0 23.0 #:hp 500.0 #:rad 1.5 #:assigned n-gas #:ideal 3 #:vesp 1800))
    (define gas-ws
      (for/list ([i (in-range n-gas)])
        (mk-l21-u (+ 9410 i) 45 1 (+ 25.0 (* 0.25 i)) 24.2 #:hp 45.0 #:rad 0.375
                  #:orders (list (sc2-unit-order 295 #f 9402 0.0)))))
    (sc2-observation lp (sc2-player-common 1 mins vesp 80 40 (+ 16 n-gas) (+ 16 n-gas) 0 0 0 0)
                     (append (list th-21 ref-u min-21) gas-ws scvs-min-16)
                     '() '() #f '() '() '() '() '() '()))

  ;; L21-P0-1a: Triggers proactively at 185G / 150M (pulling 2 of 3 gas workers to minerals at P3 coalesced, keeping 1!)
  (set-box! SC2-GAS-PULL-HYSTERESIS-LATCH #f)
  (define cmds-185g-150m (saturate-workers-and-gas-commands (mk-l21-obs 8500 150 185 3)))
  (define pulled-185-tags
    (apply append
           (map sc2-raw-unit-command-unit-tags
                (filter (lambda (c) (and (sc2-raw-unit-command? c)
                                         (= (sc2-raw-unit-command-ability-id c) 3666)
                                         (= (sc2-raw-unit-command-target-unit-tag c) 9403)
                                         (= (wire-cmd-priority-tier c) 3)))
                        cmds-185g-150m))))
  (check-true "l21-p0-1-triggers-early-at-185g-150m-pulling-2-down-to-1-floor"
              (and (unbox SC2-GAS-PULL-HYSTERESIS-LATCH)
                   (= (length pulled-185-tags) 2)))

  ;; L21-P0-1b: Keeps >= 1 gas harvester below 300G (290G/150M -> 0 pulls), pulls to 0 at >= 300G (310G/150M)!
  (define cmds-290g-1w (saturate-workers-and-gas-commands (mk-l21-obs 8504 150 290 1)))
  (check-true "l21-p0-1-keeps-last-1-gas-worker-at-290g-below-300g"
              (not (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                           (memv 9410 (sc2-raw-unit-command-unit-tags c))))
                          cmds-290g-1w)))
  (define cmds-310g-1w (saturate-workers-and-gas-commands (mk-l21-obs 8540 150 310 1)))
  (check-true "l21-p0-1-pulls-last-gas-worker-to-0-at-310g"
              (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                      (= (sc2-raw-unit-command-ability-id c) 3666)
                                      (= (sc2-raw-unit-command-target-unit-tag c) 9403)
                                      (= (wire-cmd-priority-tier c) 3)
                                      (equal? (sc2-raw-unit-command-unit-tags c) '(9410))))
                     cmds-310g-1w))

  ;; L21-P0-1c: Deadband holds at 135G/240M, clears at 125G (<130G) and at 280M (>=280M) after >= 112f!
  (set-box! SC2-GAS-PULL-HYSTERESIS-LATCH #t)
  (define cmds-db-135 (saturate-workers-and-gas-commands (mk-l21-obs 8660 240 135 1)))
  (check-true "l21-p0-1-deadband-holds-at-135g-240m"
              (and (unbox SC2-GAS-PULL-HYSTERESIS-LATCH)
                   (not (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                                (= (sc2-raw-unit-command-target-unit-tag c) 9402)))
                               cmds-db-135))))
  (define cmds-off-125 (saturate-workers-and-gas-commands (mk-l21-obs 8664 200 125 1)))
  (check-true "l21-p0-1-releases-and-resaturates-at-p1-below-130g"
              (and (not (unbox SC2-GAS-PULL-HYSTERESIS-LATCH))
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                           (= (sc2-raw-unit-command-target-unit-tag c) 9402)
                                           (macro-econ-cmd? c)
                                           (= (wire-cmd-priority-tier c) 1)))
                          cmds-off-125)))
  (void (saturate-workers-and-gas-commands (mk-l21-obs 8780 150 185 3)))
  (define cmds-off-280m (saturate-workers-and-gas-commands (mk-l21-obs 8900 280 220 1)))
  (check-true "l21-p0-1-releases-and-resaturates-at-p3-at-280m"
              (and (not (unbox SC2-GAS-PULL-HYSTERESIS-LATCH))
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                           (= (sc2-raw-unit-command-target-unit-tag c) 9402)
                                           (= (wire-cmd-priority-tier c) 3)))
                          cmds-off-280m)))

  ;; L21-P0-1d: Even while latched ON at 250G/100M (< 260G), 0 active gas workers immediately assigns 1 at P1!
  (set-box! SC2-GAS-PULL-HYSTERESIS-LATCH #t)
  (define cmds-0w-250g (saturate-workers-and-gas-commands (mk-l21-obs 9020 100 250 0)))
  (check-true "l21-p0-1-latched-250g-with-0-gas-workers-resaturates-1-at-p1"
              (and (unbox SC2-GAS-PULL-HYSTERESIS-LATCH)
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                           (= (sc2-raw-unit-command-target-unit-tag c) 9402)
                                           (macro-econ-cmd? c)))
                          cmds-0w-250g))))

(printf "[Loop 22] Testing L22-P0-1 >=260G/<120M zero-pull, >=200G/<120M carrying-gas pull, & 3/step pull at >=4 gas workers...\n")
(let ()
  (define (mk-l22-u tag utype alliance x y
                    #:hp [hp 100.0] #:rad [rad 1.0] #:orders [ords '()] #:buffs [buffs '()]
                    #:assigned [asgn 0] #:ideal [idl 0] #:mins [mins 0] #:vesp [vesp 0])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 2)
              (sc2-point3d x y 8.0) 0.0 rad 1.0 0 #f #f #f
              hp hp 0.0 0.0 0.0 0.0 mins vesp #f #f #f #t #f
              ords 0 buffs asgn idl 0.0 0 0 0 0 '() 0 0))

  (define th-22 (mk-l22-u 9301 18 1 28.5 28.5 #:hp 1500.0 #:rad 2.75 #:assigned 16 #:ideal 16))
  (define min-22 (mk-l22-u 9303 341 3 22.0 28.5 #:hp 1000.0 #:rad 1.0 #:mins 1500))
  (define scvs-min-16
    (for/list ([i (in-range 16)])
      (mk-l22-u (+ 9330 i) 45 1 (+ 23.0 (* 0.25 (modulo i 8))) (+ 27.0 (* 0.35 (quotient i 8)))
                #:hp 45.0 #:rad 0.375 #:orders (list (sc2-unit-order 295 #f 9303 0.0)))))

  ;; L22-P0-1a: At 250G/110M (< 260G) keeps last 1 gas worker (`GasZeroFreeze = 0`), while at
  ;;            265G/110M (>= 260G & < 120M) pulls the last gas worker all the way to 0 at P1!
  (set-box! SC2-GAS-PULL-HYSTERESIS-LATCH #f)
  (define ref-one (mk-l22-u 9302 20 1 25.0 23.0 #:hp 500.0 #:rad 1.5 #:assigned 1 #:ideal 3 #:vesp 1800))
  (define gw-last-carry (mk-l22-u 9310 45 1 26.0 25.5 #:hp 45.0 #:rad 0.375 #:buffs '(273)
                                  #:orders (list (sc2-unit-order 296 #f 9301 0.0))))
  (define cmds-250-110
    (saturate-workers-and-gas-commands
     (sc2-observation 9400 (sc2-player-common 1 110 250 80 40 17 17 0 0 0 0)
                      (append (list th-22 ref-one min-22 gw-last-carry) scvs-min-16)
                      '() '() #f '() '() '() '() '() '())))
  (check-true "l22-p0-1a-250g-110m-keeps-last-1-gas-worker"
              (and (unbox SC2-GAS-PULL-HYSTERESIS-LATCH)
                   (not (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                                (memv 9310 (sc2-raw-unit-command-unit-tags c))))
                               cmds-250-110))))
  (define cmds-265-110
    (saturate-workers-and-gas-commands
     (sc2-observation 9404 (sc2-player-common 1 110 265 80 40 17 17 0 0 0 0)
                      (append (list th-22 ref-one min-22 gw-last-carry) scvs-min-16)
                      '() '() #f '() '() '() '() '() '())))
  (check-true "l22-p0-1a-265g-110m-pulls-last-carrying-gas-worker-to-0-at-p3"
              (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                      (= (sc2-raw-unit-command-ability-id c) 3666)
                                      (= (sc2-raw-unit-command-target-unit-tag c) 9303)
                                      (= (wire-cmd-priority-tier c) 3)
                                      (equal? (sc2-raw-unit-command-unit-tags c) '(9310))))
                     cmds-265-110))

  ;; L22-P0-1b & 1c: With 5 active gas workers (2 clean + 3 carrying gas) at 210G/110M (>=200G & <120M),
  ;;                 pulls EXACTLY 3 workers in one step (the 2 clean + 1 carrying gas) at P3!
  (set-box! SC2-GAS-PULL-HYSTERESIS-LATCH #f)
  (define ref-a (mk-l22-u 9302 20 1 25.0 23.0 #:hp 500.0 #:rad 1.5 #:assigned 3 #:ideal 3 #:vesp 1800))
  (define ref-b (mk-l22-u 9304 20 1 32.0 23.0 #:hp 500.0 #:rad 1.5 #:assigned 2 #:ideal 3 #:vesp 1800))
  (define gw-c1 (mk-l22-u 9311 45 1 25.2 24.2 #:hp 45.0 #:rad 0.375 #:orders (list (sc2-unit-order 295 #f 9302 0.0))))
  (define gw-c2 (mk-l22-u 9312 45 1 32.2 24.2 #:hp 45.0 #:rad 0.375 #:orders (list (sc2-unit-order 295 #f 9304 0.0))))
  (define gw-k1 (mk-l22-u 9313 45 1 26.0 25.5 #:hp 45.0 #:rad 0.375 #:buffs '(273) #:orders (list (sc2-unit-order 296 #f 9301 0.0))))
  (define gw-k2 (mk-l22-u 9314 45 1 26.4 25.5 #:hp 45.0 #:rad 0.375 #:buffs '(273) #:orders (list (sc2-unit-order 296 #f 9301 0.0))))
  (define gw-k3 (mk-l22-u 9315 45 1 31.8 25.5 #:hp 45.0 #:rad 0.375 #:buffs '(273) #:orders (list (sc2-unit-order 296 #f 9301 0.0))))
  (define cmds-5g-210-110
    (saturate-workers-and-gas-commands
     (sc2-observation 9440 (sc2-player-common 1 110 210 80 45 21 21 0 0 0 0)
                      (append (list th-22 ref-a ref-b min-22 gw-c1 gw-c2 gw-k1 gw-k2 gw-k3) scvs-min-16)
                      '() '() #f '() '() '() '() '() '())))
  (define pulled-tags-5g
    (apply append (map sc2-raw-unit-command-unit-tags
                       (filter (lambda (c) (and (sc2-raw-unit-command? c)
                                                (= (sc2-raw-unit-command-ability-id c) 3666)
                                                (= (sc2-raw-unit-command-target-unit-tag c) 9303)
                                                (= (wire-cmd-priority-tier c) 3)))
                               cmds-5g-210-110))))
  (check-true "l22-p0-1bc-5-gas-workers-210g-110m-pulls-3-per-step-clean-first-plus-carrying"
              (and (= (length pulled-tags-5g) 3)
                   (memv 9311 pulled-tags-5g)
                   (memv 9312 pulled-tags-5g)
                   (memv 9313 pulled-tags-5g)))
  ;; Same 5 gas workers at 210G/125M (min >= 120) >= 32f later: pulls ONLY the 2 non-carrying workers (9311, 9312)!
  (define cmds-5g-210-125
    (saturate-workers-and-gas-commands
     (sc2-observation 9476 (sc2-player-common 1 125 210 80 45 21 21 0 0 0 0)
                      (append (list th-22 ref-a ref-b min-22 gw-c1 gw-c2 gw-k1 gw-k2 gw-k3) scvs-min-16)
                      '() '() #f '() '() '() '() '() '())))
  (define pulled-tags-5g-125
    (apply append (map sc2-raw-unit-command-unit-tags
                       (filter (lambda (c) (and (sc2-raw-unit-command? c)
                                                (= (sc2-raw-unit-command-ability-id c) 3666)
                                                (= (sc2-raw-unit-command-target-unit-tag c) 9303)))
                               cmds-5g-210-125))))
  (check-true "l22-p0-1b-210g-125m-skips-carrying-gas-workers"
              (and (= (length pulled-tags-5g-125) 2)
                   (memv 9311 pulled-tags-5g-125)
                   (memv 9312 pulled-tags-5g-125))))

(printf "[Loop 23] Testing L23-P0-1 P1 MULE/ChronoBoost cadence & dedupe, idle-MULE P1, and fast bp>=0.85 early natural transfer...\n")
(let ()
  (define (mk-l23-u tag utype alliance x y
                    #:hp [hp 100.0] #:shield [sh 0.0] #:energy [en 0.0] #:rad [rad 1.0]
                    #:bp [bp 1.0] #:cloak [cloak 0] #:orders [ords '()] #:buffs [buffs '()]
                    #:assigned [asgn 0] #:ideal [idl 0] #:mins [mins 0])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 2)
              (sc2-point3d x y 8.0) 0.0 rad bp cloak #f #f #f
              hp hp sh sh en (if (> en 0.0) 200.0 0.0) mins 0 #f #f #f #t #f
              ords 0 buffs asgn idl 0.0 0 0 0 0 '() 0 0))

  ;; L23-P0-1a: Orbital Command MULE (`171`) at P1 (`macro-econ-cmd?`), survives P2 combat micro,
  ;;            deduped with Layer 2 `calldown-mule` & `scanner-sweep`, and respects cloaked-enemy Scan reserve!
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define oc-23 (mk-l23-u 9201 132 1 28.5 28.5 #:hp 1500.0 #:energy 55.0 #:rad 2.75 #:assigned 14 #:ideal 16))
  (define min-23 (mk-l23-u 9203 341 3 22.0 28.5 #:hp 1000.0 #:rad 1.0 #:mins 1500))
  (define obs-mule-23
    (sc2-observation 3200 (sc2-player-common 1 120 40 50 26 6 20 0 0 0 0)
                     (list oc-23 min-23) '() '() #f '() '() '() '() '() '()))
  (define mule-sat-cmds (saturate-workers-and-gas-commands obs-mule-23))
  (define mule-cmd-23
    (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 171)))
           mule-sat-cmds))
  (check-true "l23-p0-1a-orbital-mule-emitted-at-p1-macro-econ"
              (and (sc2-raw-unit-command? mule-cmd-23)
                   (macro-econ-cmd? mule-cmd-23)
                   (= (wire-cmd-priority-tier mule-cmd-23) 1)
                   (= (sc2-raw-unit-command-target-unit-tag mule-cmd-23) 9203)
                   (equal? (sc2-raw-unit-command-unit-tags mule-cmd-23) '(9201))))
  ;; Under saturated P2 combat micro (governor tokens drained to 4.0), P1 MULE STILL emits immediately!
  (define gov-23 (make-wire-apm-governor #:target-apm 410.0 #:hard-cap-apm 485.0))
  (for ([step (in-range 20)])
    (define lp (+ 3200 (* 4 step)))
    (define p2-spam
      (for/list ([k (in-range 8)])
        (sc2-raw-unit-command 16 (sc2-point2d (+ 60.0 k) (+ 60.0 (modulo step 4))) 0 (list (+ 8700 k)) #f)))
    (void (govern-sc2-wire-actions! gov-23 p2-spam lp)))
  (define gov-mule-out (govern-sc2-wire-actions! gov-23 (list mule-cmd-23) 3284))
  (check-true "l23-p0-1a-p1-mule-never-starved-by-p2-combat-micro"
              (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 171)))
                     gov-mule-out))
  ;; Dedupe: after Layer 2 casts `calldown-mule` on loop 3300, `saturate-workers-and-gas-commands` emits 0 duplicate MULE!
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define obs-mule-dedupe
    (sc2-observation 3300 (sc2-player-common 1 120 40 50 26 6 20 0 0 0 0)
                     (list oc-23 min-23) '() '() #f '() '() '() '() '() '()))
  (define l2-mule-cmds
    (translate-bot-actions->sc2-raw-commands '((cast-spell 9201 calldown-mule 9203)) obs-mule-dedupe))
  (define sat-after-l2-mule (saturate-workers-and-gas-commands obs-mule-dedupe))
  (check-true "l23-p0-1a-l2-mule-tagged-p1-and-deduped-against-sat-safety-net"
              (and (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                           (= (sc2-raw-unit-command-ability-id c) 171)
                                           (macro-econ-cmd? c)))
                          l2-mule-cmds)
                   (not (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                                (= (sc2-raw-unit-command-ability-id c) 171)))
                               sat-after-l2-mule))))
  ;; Cloak threat (revealed cloak=2 DT): OC at 55 energy reserves Scan (0 MULEs), while OC at 105 energy still drops MULE!
  ;; (Undetected cloak=1 DT within 32t hard-blocks MULE even at 100e — verified by `l58-p1-l23-mule-blocks-uncovered-cloak`.)
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define dt-cloak (mk-l23-u 9299 76 4 45.0 45.0 #:hp 40.0 #:shield 80.0 #:cloak 2 #:rad 0.375))
  (define cmds-mule-cloak-55
    (saturate-workers-and-gas-commands
     (sc2-observation 3400 (sc2-player-common 1 120 40 50 26 6 20 0 0 0 0)
                      (list oc-23 min-23 dt-cloak) '() '() #f '() '() '() '() '() '())))
  (define oc-23-105 (mk-l23-u 9201 132 1 28.5 28.5 #:hp 1500.0 #:energy 105.0 #:rad 2.75 #:assigned 14 #:ideal 16))
  (define cmds-mule-cloak-105
    (saturate-workers-and-gas-commands
     (sc2-observation 3404 (sc2-player-common 1 120 40 50 26 6 20 0 0 0 0)
                      (list oc-23-105 min-23 dt-cloak) '() '() #f '() '() '() '() '() '())))
  (check-true "l23-p0-1a-mule-reserves-50-energy-scan-vs-cloak-and-fires-at-105-energy"
              (and (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 171)))
                               cmds-mule-cloak-55))
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 171)))
                          cmds-mule-cloak-105)))

  ;; L23-P0-1b: Early `0:00-5:00` Probe-training Nexus ChronoBoost (`3755`) emitted at P1 (`macro-econ-cmd?`),
  ;;            skips already-boosted Nexuses (`buff 281`), and dedupes with Layer 2!
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define nx-train (mk-l23-u 9211 59 1 28.5 28.5 #:hp 1000.0 #:shield 1000.0 #:energy 55.0 #:rad 2.75
                             #:orders (list (sc2-unit-order 1006 #f 0 0.25)) #:assigned 14 #:ideal 16))
  (define obs-chrono-23
    (sc2-observation 3500 (sc2-player-common 1 120 40 50 26 6 20 0 0 0 0)
                     (list nx-train min-23) '() '() #f '() '() '() '() '() '()))
  (define chrono-sat-cmds (saturate-workers-and-gas-commands obs-chrono-23))
  (define chrono-cmd-23
    (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 3755)))
           chrono-sat-cmds))
  (check-true "l23-p0-1b-early-nexus-probe-chrono-emitted-at-p1-macro-econ"
              (and (sc2-raw-unit-command? chrono-cmd-23)
                   (macro-econ-cmd? chrono-cmd-23)
                   (= (wire-cmd-priority-tier chrono-cmd-23) 1)
                   (= (sc2-raw-unit-command-target-unit-tag chrono-cmd-23) 9211)
                   (equal? (sc2-raw-unit-command-unit-tags chrono-cmd-23) '(9211))))
  ;; Already boosted (`buff 281`) OR deduped after Layer 2 -> emits 0 duplicate ChronoBoost!
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define nx-boosted (mk-l23-u 9211 59 1 28.5 28.5 #:hp 1000.0 #:shield 1000.0 #:energy 55.0 #:rad 2.75
                               #:orders (list (sc2-unit-order 1006 #f 0 0.25)) #:buffs '(281)))
  (define chrono-already-cmds
    (saturate-workers-and-gas-commands
     (sc2-observation 3520 (sc2-player-common 1 120 40 50 26 6 20 0 0 0 0)
                      (list nx-boosted min-23) '() '() #f '() '() '() '() '() '())))
  (define l2-chrono-cmds
    (translate-bot-actions->sc2-raw-commands '((cast-spell 9211 chrono-boost 9211))
                                             (sc2-observation 3540 (sc2-player-common 1 120 40 50 26 6 20 0 0 0 0)
                                                              (list nx-train min-23) '() '() #f '() '() '() '() '() '())))
  (define sat-after-l2-chrono
    (saturate-workers-and-gas-commands
     (sc2-observation 3540 (sc2-player-common 1 120 40 50 26 6 20 0 0 0 0)
                      (list nx-train min-23) '() '() #f '() '() '() '() '() '())))
  (check-true "l23-p0-1b-chrono-skips-buffed-and-dedupes-with-l2"
              (and (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 3755)))
                               chrono-already-cmds))
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 3755) (macro-econ-cmd? c)))
                          l2-chrono-cmds)
                   (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 3755)))
                               sat-after-l2-chrono))))

  ;; L23-P0-1c: Early `0:00-4:00` natural split (`bp = 0.88`, `0/16`) transfers 2 workers/step at Tier P1
  ;;            even when Main is `15/16` (NOT over-saturated, previously blocked by Main sorting first!)
  (define main-cc-15 (mk-l23-u 9221 18 1 28.5 28.5 #:hp 1500.0 #:rad 2.75 #:bp 1.0 #:assigned 15 #:ideal 16))
  (define nat-cc-88  (mk-l23-u 9222 18 1 60.5 28.5 #:hp 1320.0 #:rad 2.75 #:bp 0.88 #:assigned 0 #:ideal 16))
  (define main-mins-4
    (for/list ([i (in-range 4)])
      (mk-l23-u (+ 9230 i) 341 3 22.0 (+ 25.0 (* 2.0 i)) #:hp 1000.0 #:rad 1.0 #:mins 1500)))
  (define nat-mins-4
    (for/list ([i (in-range 4)])
      (mk-l23-u (+ 9234 i) 341 3 66.5 (+ 25.0 (* 2.0 i)) #:hp 1000.0 #:rad 1.0 #:mins 1500)))
  (define main-scvs-15
    (for/list ([i (in-range 15)])
      (mk-l23-u (+ 9240 i) 45 1 (+ 22.5 (* 0.3 (modulo i 5))) (+ 25.5 (* 1.5 (quotient i 5)))
                #:hp 45.0 #:rad 0.375
                #:orders (list (sc2-unit-order 295 #f (+ 9230 (modulo i 4)) 0.0)))))
  (define xfer-early-cmds
    (saturate-workers-and-gas-commands
     (sc2-observation 2800 (sc2-player-common 1 150 20 40 24 4 15 0 0 0 0)
                      (append (list main-cc-15 nat-cc-88) main-mins-4 nat-mins-4 main-scvs-15)
                      '() '() #f '() '() '() '() '() '())))
  (define xfers-to-nat
    (filter (lambda (c) (and (sc2-raw-unit-command? c)
                             (= (sc2-raw-unit-command-ability-id c) 3666)
                             (memv (sc2-raw-unit-command-target-unit-tag c) '(9234 9235 9236 9237))
                             (macro-econ-cmd? c)))
            xfer-early-cmds))
  (check-true "l23-p0-1c-bp88-natural-immediately-splits-2-workers-at-p1-from-15-of-16-main"
              (= (length xfers-to-nat) 2))

  ;; L23-P0-1d + L61 (`#1609`): Midgame (`> 2688`) idle MULE re-tasking purified to Tier P3!
  (define idle-mule-23 (mk-l23-u 9280 268 1 25.0 28.5 #:hp 60.0 #:rad 0.375 #:orders '()))
  (define mule-retask-cmds
    (saturate-workers-and-gas-commands
     (sc2-observation 3600 (sc2-player-common 1 150 20 40 24 4 15 0 0 0 0)
                      (list main-cc-15 min-23 idle-mule-23)
                      '() '() #f '() '() '() '() '() '())))
  (check-true "l23-p0-1d-idle-mule-retask-purified-p3-midgame"
              (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                      (= (sc2-raw-unit-command-ability-id c) 3666)
                                      (equal? (sc2-raw-unit-command-unit-tags c) '(9280))
                                      (= (wire-cmd-priority-tier c) 3)))
                     mule-retask-cmds)))

(printf "[Loop 24] Testing L24-P0-1 unpowered Protoss production repower guarantee (#51) & Zerg 8.5->11.5 creep tech fallback (#52)...\n")
(let ()
  (define (l24-dist x1 y1 x2 y2)
    (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))
  (define (mk-l24-u tag utype alliance x y
                    #:hp [hp 100.0] #:shield [sh 0.0] #:rad [rad 1.0]
                    #:bp [bp 1.0] #:powered? [pow? #t] #:mins [mins 0])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 2)
              (sc2-point3d x y 8.0) 0.0 rad bp 0 #f #f #f
              hp hp sh sh 0.0 0.0 mins 0 #f #f #f pow? #f
              '() 0 '() 0 0 0.0 0 0 0 0 '() 0 0))
  (define (l24-start-mock-ws decide-fn)
    (define-values (c-in s-out) (make-pipe))
    (define-values (s-in c-out) (make-pipe))
    (define ws (sc2-ws-conn "127.0.0.1" 59924 "/sc2api" c-in c-out #f 1))
    (define th
      (thread
       (lambda ()
         (let lp ()
           (define b0 (read-byte s-in))
           (unless (eof-object? b0)
             (define b1 (read-byte s-in))
             (define masked? (not (zero? (bitwise-and b1 #x80))))
             (define len0 (bitwise-and b1 #x7F))
             (define plen
               (cond [(< len0 126) len0]
                     [(= len0 126) (integer-bytes->integer (read-bytes 2 s-in) #f #t)]
                     [else (integer-bytes->integer (read-bytes 8 s-in) #f #t)]))
             (define mkey (if masked? (read-bytes 4 s-in) #f))
             (define raw (read-bytes plen s-in))
             (define payload
               (if masked?
                   (let ([out (make-bytes plen)])
                     (for ([i (in-range plen)])
                       (bytes-set! out i (bitwise-xor (bytes-ref raw i) (bytes-ref mkey (modulo i 4)))))
                     out)
                   raw))
             (define req-f (decode-protobuf-message payload))
             (define req-id-p (assoc 97 req-f))
             (define id-b (if req-id-p (encode-uint32 97 (third req-id-p)) #""))
             (define q-p (assoc 14 req-f))
             (when q-p
               (define qf (decode-protobuf-message (third q-p)))
               (define p-items (filter (lambda (e) (= (first e) 3)) qf))
               (define res-b
                 (apply bytes-append
                        (for/list ([it (in-list p-items)])
                          (define itf (decode-protobuf-message (third it)))
                          (define ab (let ([p (assoc 1 itf)]) (if p (third p) 0)))
                          (define tp-e (assoc 2 itf))
                          (define-values (px py)
                            (if tp-e
                                (let ([ptf (decode-protobuf-message (third tp-e))])
                                  (values (let ([xp (assoc 1 ptf)])
                                            (if (and xp (bytes? (third xp)))
                                                (floating-point-bytes->real (third xp) #f)
                                                0.0))
                                          (let ([yp (assoc 2 ptf)])
                                            (if (and yp (bytes? (third yp)))
                                                (floating-point-bytes->real (third yp) #f)
                                                0.0))))
                                (values 0.0 0.0)))
                          (encode-submessage-field 3 (encode-int32 1 (decide-fn ab px py))))))
               (define resp (bytes-append (encode-submessage-field 14 res-b) id-b (encode-int32 99 3)))
               (define rlen (bytes-length resp))
               (define rhdr
                 (cond [(< rlen 126) (bytes #x82 rlen)]
                       [(<= rlen 65535) (bytes-append (bytes #x82 126) (integer->integer-bytes rlen 2 #f #t))]
                       [else (bytes-append (bytes #x82 127) (integer->integer-bytes rlen 8 #f #t))]))
               (write-bytes rhdr s-out)
               (write-bytes resp s-out)
               (flush-output s-out))
             (lp))))))
    (values ws (lambda () (close-output-port c-out) (close-input-port c-in) (thread-wait th))))

  ;; L24-P0-1a (`#51` 3D Visual-QA): Unpowered East Gateway (39.5, 28.5) under 12-Pool Ling rush at (42.5, 28.5)
  ;; with minerals East/South so `inmain-safe-anchors` pull WEST to ~22.5 -> repower Pylon MUST still land
  ;; strictly within <= 6.0t of Gateway (39.5, 28.5) on the home-side (`x < 39.5`, away from Zerglings)!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (let-values ([(ws cleanup!) (l24-start-mock-ws (lambda (_ab _px _py) 1))])
    (define nex-24 (mk-l24-u 9101 59 1 28.5 28.5 #:hp 1000.0 #:shield 1000.0 #:rad 2.75))
    (define min-e  (mk-l24-u 9102 341 3 34.0 23.0 #:hp 1000.0 #:rad 1.0 #:mins 1500))
    (define gw-unp (mk-l24-u 9103 62 1 39.5 28.5 #:hp 500.0 #:shield 500.0 #:rad 1.5 #:powered? #f))
    (define fg-unp (mk-l24-u 9104 63 1 24.0 39.0 #:hp 400.0 #:shield 400.0 #:rad 1.5 #:powered? #f))
    (define prb-24 (mk-l24-u 9105 84 1 32.0 29.0 #:hp 20.0 #:shield 20.0 #:rad 0.375))
    (define lings-e
      (for/list ([i (in-range 6)])
        (mk-l24-u (+ 9110 i) 105 4 (+ 42.5 (* 0.3 i)) (+ 28.0 (* 0.2 (modulo i 3))) #:hp 35.0 #:rad 0.375)))
    (define obs-repower-gw
      (sc2-observation 2400 (sc2-player-common 1 350 0 23 18 0 18 0 0 0 0)
                       (append (list nex-24 min-e gw-unp fg-unp prb-24) lings-e)
                       '() '() #f '() '() '() '() '() '()))
    (define py-cmds-1
      (translate-bot-actions->sc2-raw-commands '((build pylon 40.0 28.5))
                                               obs-repower-gw #:ws-conn ws #:game-info w3-ginfo))
    (define py-cmd-1
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 881))) py-cmds-1))
    (define py-pt-1 (and py-cmd-1 (sc2-raw-unit-command-target-pos py-cmd-1)))
    (check-true "l24-p0-1a-repower-pylon-powers-east-gateway-on-homeside-under-ling-rush"
                (and (sc2-point2d? py-pt-1)
                     (<= (l24-dist (sc2-point2d-x py-pt-1) (sc2-point2d-y py-pt-1) 39.5 28.5) 6.0)
                     (< (sc2-point2d-x py-pt-1) 39.5)))
    ;; Once a warping-in Pylon (`bp = 0.40`) is already covering Gateway (39.5, 28.5), the next Pylon
    ;; repowers the unpowered Forge at (24.0, 39.0) instead of stacking on the Gateway!
    (hash-clear! SC2-PLACEMENT-POS-CACHE)
    (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
    (define py-warping (mk-l24-u 9106 60 1 36.0 28.5 #:hp 100.0 #:shield 100.0 #:rad 1.0 #:bp 0.40))
    (define obs-repower-fg
      (sc2-observation 2440 (sc2-player-common 1 350 0 23 18 0 18 0 0 0 0)
                       (append (list nex-24 min-e gw-unp fg-unp py-warping prb-24) lings-e)
                       '() '() #f '() '() '() '() '() '()))
    (define py-cmds-2
      (translate-bot-actions->sc2-raw-commands '((build pylon 40.0 28.5))
                                               obs-repower-fg #:ws-conn ws #:game-info w3-ginfo))
    (define py-cmd-2
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 881))) py-cmds-2))
    (define py-pt-2 (and py-cmd-2 (sc2-raw-unit-command-target-pos py-cmd-2)))
    (check-true "l24-p0-1a-repower-skips-gateway-with-warping-pylon-and-repowers-forge"
                (and (sc2-point2d? py-pt-2)
                     (<= (l24-dist (sc2-point2d-x py-pt-2) (sc2-point2d-y py-pt-2) 24.0 39.0) 6.0)))
    (cleanup!))

  ;; L24-P0-1b (`#52` SpireDrop=14t): When default 8.5t creep search fails for `spire`, expands to 11.5t
  ;; outer creep ring (single Lair) AND across all completed Hatcheries/Lairs (2-base)!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (let-values ([(ws cleanup!)
                (l24-start-mock-ws
                 (lambda (ab px py)
                   ;; Reject ALL Spire placements within <= 8.5t of Main Lair (32.0, 32.0);
                   ;; accept ONLY outer creep ring (8.8..11.5t from (32.0, 32.0))!
                   (define d (l24-dist px py 32.0 32.0))
                   (if (and (= ab 1158) (>= d 8.8) (<= d 11.5)) 1 2)))])
    (define lair-24 (mk-l24-u 9121 100 1 32.0 32.0 #:hp 2000.0 #:rad 2.75))
    (define drn-24  (mk-l24-u 9122 104 1 35.0 34.0 #:hp 40.0 #:rad 0.375))
    (define sp-cmds-ring
      (translate-bot-actions->sc2-raw-commands
       '((build spire 32.0 32.0))
       (make-test-obs 9000 300 250 (list lair-24 drn-24))
       #:ws-conn ws #:game-info w3-ginfo))
    (define sp-cmd-ring
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1158))) sp-cmds-ring))
    (define sp-pt-ring (and sp-cmd-ring (sc2-raw-unit-command-target-pos sp-cmd-ring)))
    (check-true "l24-p0-1b-spire-expands-to-11-5t-outer-creep-ring-when-8-5t-fails"
                (and (sc2-point2d? sp-pt-ring)
                     (>= (l24-dist (sc2-point2d-x sp-pt-ring) (sc2-point2d-y sp-pt-ring) 32.0 32.0) 8.8)
                     (<= (l24-dist (sc2-point2d-x sp-pt-ring) (sc2-point2d-y sp-pt-ring) 32.0 32.0) 11.5)))
    (cleanup!))

  ;; Case 2: Main Lair (32,32) completely unbuildable, Natural Hatchery (64,32) open -> expanded fallback places at Natural!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (let-values ([(ws cleanup!)
                (l24-start-mock-ws
                 (lambda (ab px py)
                   (if (and (= ab 1158) (<= (l24-dist px py 64.0 32.0) 11.5) (>= (l24-dist px py 64.0 32.0) 4.0))
                       1 2)))])
    (define lair-24 (mk-l24-u 9131 100 1 32.0 32.0 #:hp 2000.0 #:rad 2.75))
    (define nat-h24 (mk-l24-u 9132 86  1 64.0 32.0 #:hp 1500.0 #:rad 2.75))
    (define drn-24  (mk-l24-u 9133 104 1 60.0 32.0 #:hp 40.0 #:rad 0.375))
    (define sp-cmds-nat
      (translate-bot-actions->sc2-raw-commands
       '((build spire 32.0 32.0))
       (make-test-obs 9020 300 250 (list lair-24 nat-h24 drn-24))
       #:ws-conn ws #:game-info w3-ginfo))
    (define sp-cmd-nat
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1158))) sp-cmds-nat))
    (define sp-pt-nat (and sp-cmd-nat (sc2-raw-unit-command-target-pos sp-cmd-nat)))
    (check-true "l24-p0-1b-spire-expands-to-natural-hatchery-creep-when-main-blocked"
                (and (sc2-point2d? sp-pt-nat)
                     (<= (l24-dist (sc2-point2d-x sp-pt-nat) (sc2-point2d-y sp-pt-nat) 64.0 32.0) 11.5)))
    (cleanup!)))

(printf "[Loop 25] Testing L25-P0-1 threat-sorted safe-under-gas (#33), anti-harass mineral stability (#21/#33), & multi-base barracks4/gateway4 fallback (#17/#08/#33)...\n")
(let ()
  (define (l25-dist x1 y1 x2 y2)
    (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))
  (define (mk-l25-u tag utype alliance x y
                    #:hp [hp 100.0] #:mhp [mhp #f] #:shield [sh 0.0] #:rad [rad 1.0]
                    #:bp [bp 1.0] #:flying? [fly? #f] #:orders [ords '()]
                    #:assigned [asgn 0] #:ideal [idl 0] #:mins [mins 0] #:vesp [vesp 0])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 2)
              (sc2-point3d x y (if fly? 12.0 8.0)) 0.0 rad bp 0 #f #f #f
              hp (or mhp hp) sh sh 0.0 0.0 mins vesp fly? #f #f #t #f
              ords 0 '() asgn idl 0.0 0 0 0 0 '() 0 0))
  (define (l25-start-mock-ws decide-fn)
    (define-values (c-in s-out) (make-pipe))
    (define-values (s-in c-out) (make-pipe))
    (define ws (sc2-ws-conn "127.0.0.1" 59925 "/sc2api" c-in c-out #f 1))
    (define saw-319? (box #f))
    (define th
      (thread
       (lambda ()
         (let lp ()
           (define b0 (read-byte s-in))
           (unless (eof-object? b0)
             (define b1 (read-byte s-in))
             (define masked? (not (zero? (bitwise-and b1 #x80))))
             (define len0 (bitwise-and b1 #x7F))
             (define plen
               (cond [(< len0 126) len0]
                     [(= len0 126) (integer-bytes->integer (read-bytes 2 s-in) #f #t)]
                     [else (integer-bytes->integer (read-bytes 8 s-in) #f #t)]))
             (define mkey (if masked? (read-bytes 4 s-in) #f))
             (define raw (read-bytes plen s-in))
             (define payload
               (if masked?
                   (let ([out (make-bytes plen)])
                     (for ([i (in-range plen)])
                       (bytes-set! out i (bitwise-xor (bytes-ref raw i) (bytes-ref mkey (modulo i 4)))))
                     out)
                   raw))
             (define req-f (decode-protobuf-message payload))
             (define req-id-p (assoc 97 req-f))
             (define id-b (if req-id-p (encode-uint32 97 (third req-id-p)) #""))
             (define q-p (assoc 14 req-f))
             (when q-p
               (define qf (decode-protobuf-message (third q-p)))
               (define p-items (filter (lambda (e) (= (first e) 3)) qf))
               (define res-b
                 (apply bytes-append
                        (for/list ([it (in-list p-items)])
                          (define itf (decode-protobuf-message (third it)))
                          (define ab (let ([p (assoc 1 itf)]) (if p (third p) 0)))
                          (when (= ab 319) (set-box! saw-319? #t))
                          (define tp-e (assoc 2 itf))
                          (define-values (px py)
                            (if tp-e
                                (let ([ptf (decode-protobuf-message (third tp-e))])
                                  (values (let ([xp (assoc 1 ptf)])
                                            (if (and xp (bytes? (third xp)))
                                                (floating-point-bytes->real (third xp) #f)
                                                0.0))
                                          (let ([yp (assoc 2 ptf)])
                                            (if (and yp (bytes? (third yp)))
                                                (floating-point-bytes->real (third yp) #f)
                                                0.0))))
                                (values 0.0 0.0)))
                          (encode-submessage-field 3 (encode-int32 1 (decide-fn ab px py))))))
               (define resp (bytes-append (encode-submessage-field 14 res-b) id-b (encode-int32 99 3)))
               (define rlen (bytes-length resp))
               (define rhdr
                 (cond [(< rlen 126) (bytes #x82 rlen)]
                       [(<= rlen 65535) (bytes-append (bytes #x82 126) (integer->integer-bytes rlen 2 #f #t))]
                       [else (bytes-append (bytes #x82 127) (integer->integer-bytes rlen 8 #f #t))]))
               (write-bytes rhdr s-out)
               (write-bytes resp s-out)
               (flush-output s-out))
             (lp))))))
    (values ws saw-319? (lambda () (close-output-port c-out) (close-input-port c-in) (thread-wait th))))

  ;; L25-P0-1a (`#33` GasZeroFreeze 1 -> 0): Both Main and Natural Nexuses are online (`2` Stalkers at Natural
  ;; don't knock Natural offline), Natural Assimilator 9012 has 0/3 assigned BUT is camped by the 2 Stalkers
  ;; while safe Main Assimilator 9011 has 1/3 assigned -> MUST fill safe Main 9011, NEVER camped Natural 9012!
  (set-box! SC2-GAS-PULL-HYSTERESIS-LATCH #f)
  (define nx-m (mk-l25-u 9001 59 1 28.5 28.5 #:hp 1000.0 #:shield 1000.0 #:rad 2.75 #:assigned 14 #:ideal 16))
  (define nx-n (mk-l25-u 9002 59 1 64.5 28.5 #:hp 1000.0 #:shield 1000.0 #:rad 2.75 #:assigned 12 #:ideal 16))
  (define as-m (mk-l25-u 9011 61 1 25.0 23.0 #:hp 450.0 #:shield 450.0 #:rad 1.5 #:assigned 1 #:ideal 3 #:vesp 1800))
  (define as-n (mk-l25-u 9012 61 1 61.0 23.0 #:hp 450.0 #:shield 450.0 #:rad 1.5 #:assigned 0 #:ideal 3 #:vesp 1800))
  (define mn-m (mk-l25-u 9003 341 3 22.0 28.5 #:hp 1000.0 #:rad 1.0 #:mins 1500))
  (define mn-n (mk-l25-u 9004 341 3 70.0 28.5 #:hp 1000.0 #:rad 1.0 #:mins 1500))
  (define prb-gas1 (mk-l25-u 9020 84 1 25.4 24.0 #:hp 20.0 #:shield 20.0 #:rad 0.375
                             #:orders (list (sc2-unit-order 298 #f 9011 0.0))))
  (define prbs-m
    (for/list ([i (in-range 14)])
      (mk-l25-u (+ 9030 i) 84 1 (+ 23.5 (* 0.3 (modulo i 5))) (+ 27.5 (* 0.4 (quotient i 5)))
                #:hp 20.0 #:shield 20.0 #:rad 0.375 #:orders (list (sc2-unit-order 298 #f 9003 0.0)))))
  (define stalkers-nat
    (list (mk-l25-u 9081 74 4 61.5 24.5 #:hp 80.0 #:shield 80.0 #:rad 0.625)
          (mk-l25-u 9082 74 4 62.5 24.5 #:hp 80.0 #:shield 80.0 #:rad 0.625)))
  (define cmds-safe-gas
    (saturate-workers-and-gas-commands
     (sc2-observation 7200 (sc2-player-common 1 200 20 80 40 4 20 0 0 0 0)
                      (append (list nx-m nx-n as-m as-n mn-m mn-n prb-gas1) prbs-m stalkers-nat)
                      '() '() #f '() '() '() '() '() '())))
  (check-true "l25-p0-1a-safe-under-gas-prefers-zero-threat-main-over-camped-0-assigned-natural"
              (and (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                           (= (sc2-raw-unit-command-target-unit-tag c) 9011)))
                          cmds-safe-gas)
                   (not (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                                (= (sc2-raw-unit-command-target-unit-tag c) 9012)))
                               cmds-safe-gas))))

  ;; L25-P0-1b (`#21`/`#33` anti-harass mineral-line stability):
  ;;   - 4 Phoenixes (`78`) over Main -> stays ONLINE (no full worker evac!)
  ;;   - 2 Adepts (`311`) poking Main -> stays ONLINE (`2 < 3` non-heavy!)
  ;;   - 2 Oracles (`495`, heavy ground killer) -> goes OFFLINE (`h-cnt = 2`, `e-hp > 1.5*a-hp`)
  ;;   - 3 Stalkers (`74`) -> goes OFFLINE (`g-cnt = 3`)
  ;;   - Damaged Nexus (`30% < 35%` HP) under 1 Stalker -> goes OFFLINE
  (define phoenixes-4
    (for/list ([i (in-range 4)])
      (mk-l25-u (+ 9085 i) 78 4 (+ 29.0 (* 0.5 i)) 29.0 #:hp 120.0 #:shield 60.0 #:flying? #t)))
  (define adepts-2
    (list (mk-l25-u 9091 311 4 31.0 29.0 #:hp 70.0 #:shield 70.0)
          (mk-l25-u 9092 311 4 32.0 29.0 #:hp 70.0 #:shield 70.0)))
  (define oracles-2
    (list (mk-l25-u 9093 495 4 31.0 29.0 #:hp 100.0 #:shield 60.0 #:flying? #t)
          (mk-l25-u 9094 495 4 32.0 29.0 #:hp 100.0 #:shield 60.0 #:flying? #t)))
  (define stalkers-3
    (for/list ([i (in-range 3)])
      (mk-l25-u (+ 9095 i) 74 4 (+ 31.0 (* 0.5 i)) 29.0 #:hp 80.0 #:shield 80.0)))
  (define nx-damaged (mk-l25-u 9001 59 1 28.5 28.5 #:hp 300.0 #:mhp 1000.0 #:shield 0.0 #:rad 2.75))
  (check-true "l25-p0-1b-4-phoenixes-never-evacuate-mineral-line"
              (not (townhall-offline? nx-m (list mn-m) phoenixes-4 '())))
  (check-true "l25-p0-1b-2-adepts-poke-never-evacuates-mineral-line"
              (not (townhall-offline? nx-m (list mn-m) adepts-2 '())))
  (check-true "l25-p0-1b-2-heavy-oracles-evacuate-mineral-line"
              (townhall-offline? nx-m (list mn-m) oracles-2 '()))
  (check-true "l25-p0-1b-3-ground-stalkers-evacuate-mineral-line"
              (townhall-offline? nx-m (list mn-m) stalkers-3 '()))
  (check-true "l25-p0-1b-damaged-th-under-35pct-with-1-attacker-evacuates"
              (townhall-offline? nx-damaged (list mn-m) (list (first stalkers-3)) '()))

  ;; L25-P0-1c-i (`#17/#08` Terran barracks #4+): Drive 2 real consecutive 5x3 misses across a Depot
  ;; completion (`cur-struct-sig` change clears `SC2-TERRAN-5X3-MISS-CACHE`), then verify `barracks #4`
  ;; skips `319` completely (`rax4-fast-3x3?`) and places pure `3x3` at safe completed Natural `(64.5, 30.5)`!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-clear! SC2-TERRAN-5X3-MISS-CACHE)
  (hash-clear! SC2-TERRAN-5X3-MISS-STREAK)
  (define allow-nat-321? (box #f))
  (let-values ([(ws saw-319? cleanup!)
                (l25-start-mock-ws
                 (lambda (ab px _py)
                   (if (and (unbox allow-nat-321?) (= ab 321) (>= px 56.0)) 1 2)))])
    (define cc-m (mk-l25-u 9041 18 1 28.5 28.5 #:hp 1500.0 #:rad 2.75))
    (define cc-n (mk-l25-u 9042 18 1 64.5 30.5 #:hp 1500.0 #:rad 2.75))
    (define rax1 (mk-l25-u 9043 21 1 34.5 28.5 #:hp 1000.0 #:rad 1.5))
    (define rax2 (mk-l25-u 9044 21 1 34.5 33.5 #:hp 1000.0 #:rad 1.5))
    (define rax3 (mk-l25-u 9045 21 1 28.5 35.5 #:hp 1000.0 #:rad 1.5))
    (define dep1 (mk-l25-u 9047 19 1 24.0 35.5 #:hp 400.0 #:rad 1.0))
    (define scv1 (mk-l25-u 9046 45 1 60.0 30.0 #:hp 45.0 #:rad 0.375))
    ;; Miss #1 at loop 9100 (crowded Main, 3 Barracks) -> streak = 1
    (translate-bot-actions->sc2-raw-commands
     '((build barracks 32.0 30.0))
     (make-test-obs 9100 500 100 (list cc-m rax1 rax2 rax3 scv1))
     #:ws-conn ws #:game-info w3-ginfo)
    ;; Miss #2 at loop 9160 after Supply Depot finishes (`cur-struct-sig` changes!) -> streak = 2
    (translate-bot-actions->sc2-raw-commands
     '((build barracks 32.0 30.0))
     (make-test-obs 9160 500 100 (list cc-m rax1 rax2 rax3 dep1 scv1))
     #:ws-conn ws #:game-info w3-ginfo)
    ;; Attempt #3 at loop 9220 after Natural CC finishes (`cur-struct-sig` changes again, wiping
    ;; `SC2-TERRAN-5X3-MISS-CACHE`, while `SC2-TERRAN-5X3-MISS-STREAK` persists at >= 2!):
    (set-box! saw-319? #f)
    (set-box! allow-nat-321? #t)
    (define r4-cmds
      (translate-bot-actions->sc2-raw-commands
       '((build barracks 32.0 30.0))
       (make-test-obs 9220 500 100 (list cc-m cc-n rax1 rax2 rax3 dep1 scv1))
       #:ws-conn ws #:game-info w3-ginfo))
    (define r4-cmd
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 321))) r4-cmds))
    (check-true "l25-p0-1c-barracks4-after-2-misses-skips-5x3-and-places-3x3-at-safe-natural"
                (and (>= (hash-ref SC2-TERRAN-5X3-MISS-STREAK 'barracks 0) 2)
                     (sc2-raw-unit-command? r4-cmd)
                     (not (unbox saw-319?))
                     (sc2-point2d? (sc2-raw-unit-command-target-pos r4-cmd))
                     (>= (sc2-point2d-x (sc2-raw-unit-command-target-pos r4-cmd)) 56.0)))
    (cleanup!))
  (hash-clear! SC2-TERRAN-5X3-MISS-STREAK)

  ;; L25-P0-1c-ii (`#33` Protoss gateway #4+): Crowded Main Pylons rejected (`px < 56.0`) + contested 3rd Pylon
  ;; at `(96, 30)` with enemy Zealots -> widens fallback cleanly to uncontested Natural Pylon `(64, 30)`!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (let-values ([(ws _saw319 cleanup!)
                (l25-start-mock-ws
                 (lambda (ab px _py)
                   (if (and (= ab 883) (>= px 56.0) (<= px 72.0)) 1 2)))])
    (define py-m1 (mk-l25-u 9051 60 1 28.0 34.0 #:hp 200.0 #:shield 200.0 #:rad 1.0))
    (define py-m2 (mk-l25-u 9052 60 1 34.0 34.0 #:hp 200.0 #:shield 200.0 #:rad 1.0))
    (define py-n  (mk-l25-u 9053 60 1 64.0 30.0 #:hp 200.0 #:shield 200.0 #:rad 1.0))
    (define py-3  (mk-l25-u 9054 60 1 96.0 30.0 #:hp 200.0 #:shield 200.0 #:rad 1.0))
    (define gw1   (mk-l25-u 9055 62 1 30.0 37.0 #:hp 500.0 #:shield 500.0 #:rad 1.5))
    (define gw2   (mk-l25-u 9056 62 1 34.0 37.0 #:hp 500.0 #:shield 500.0 #:rad 1.5))
    (define gw3   (mk-l25-u 9057 62 1 38.0 34.0 #:hp 500.0 #:shield 500.0 #:rad 1.5))
    (define prb1  (mk-l25-u 9058 84 1 60.0 30.0 #:hp 20.0 #:shield 20.0 #:rad 0.375))
    (define zlt-3 (mk-l25-u 9059 73 4 95.5 31.0 #:hp 100.0 #:shield 50.0 #:rad 0.5))
    (define obs-gw4
      (sc2-observation 9400 (sc2-player-common 1 500 100 80 50 20 30 0 0 0 0)
                       (list nx-m nx-n py-m1 py-m2 py-n py-3 gw1 gw2 gw3 prb1 zlt-3)
                       '()
                       (list (sc2-power-source (sc2-point2d 28.0 34.0) 6.5 9051)
                             (sc2-power-source (sc2-point2d 34.0 34.0) 6.5 9052)
                             (sc2-power-source (sc2-point2d 64.0 30.0) 6.5 9053)
                             (sc2-power-source (sc2-point2d 96.0 30.0) 6.5 9054))
                       #f '() '() '() '() '() '()))
    (define gw4-cmds
      (translate-bot-actions->sc2-raw-commands
       '((build gateway 30.0 34.0))
       obs-gw4 #:ws-conn ws #:game-info w3-ginfo))
    (define gw4-cmd
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 883))) gw4-cmds))
    (define gw4-pt (and gw4-cmd (sc2-raw-unit-command-target-pos gw4-cmd)))
    (check-true "l25-p0-1c-gateway4-places-at-uncontested-natural-pylon-when-main-crowded"
                (and (sc2-point2d? gw4-pt)
                     (<= (l25-dist (sc2-point2d-x gw4-pt) (sc2-point2d-y gw4-pt) 64.0 30.0) 6.5)))
    (cleanup!)))

(printf "[Loop 26] Testing L26-P0-1 Protoss tight-spacing (0.5t) powered-placement fallback across all uncontested Pylons (#21/#36)...\n")
(let ()
  (define (l26-dist x1 y1 x2 y2)
    (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))
  (define (mk-l26-u tag utype alliance x y
                    #:hp [hp 100.0] #:shield [sh 0.0] #:rad [rad 1.0] #:orders [ords '()])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 2)
              (sc2-point3d x y 8.0) 0.0 rad 1.0 0 #f #f #f
              hp hp sh sh 0.0 0.0 0 0 #f #f #f #t #f
              ords 0 '() 0 0 0.0 0 0 0 0 '() 0 0))
  (define (l26-start-mock-ws decide-fn)
    (define-values (c-in s-out) (make-pipe))
    (define-values (s-in c-out) (make-pipe))
    (define ws (sc2-ws-conn "127.0.0.1" 59926 "/sc2api" c-in c-out #f 1))
    (define rpc-cnt (box 0))
    (define th
      (thread
       (lambda ()
         (let lp ()
           (define b0 (read-byte s-in))
           (unless (eof-object? b0)
             (define b1 (read-byte s-in))
             (define masked? (not (zero? (bitwise-and b1 #x80))))
             (define len0 (bitwise-and b1 #x7F))
             (define plen
               (cond [(< len0 126) len0]
                     [(= len0 126) (integer-bytes->integer (read-bytes 2 s-in) #f #t)]
                     [else (integer-bytes->integer (read-bytes 8 s-in) #f #t)]))
             (define mkey (if masked? (read-bytes 4 s-in) #f))
             (define raw (read-bytes plen s-in))
             (define payload
               (if masked?
                   (let ([out (make-bytes plen)])
                     (for ([i (in-range plen)])
                       (bytes-set! out i (bitwise-xor (bytes-ref raw i) (bytes-ref mkey (modulo i 4)))))
                     out)
                   raw))
             (define req-f (decode-protobuf-message payload))
             (define req-id-p (assoc 97 req-f))
             (define id-b (if req-id-p (encode-uint32 97 (third req-id-p)) #""))
             (define q-p (assoc 14 req-f))
             (when q-p
               (set-box! rpc-cnt (add1 (unbox rpc-cnt)))
               (define qf (decode-protobuf-message (third q-p)))
               (define p-items (filter (lambda (e) (= (first e) 3)) qf))
               (define res-b
                 (apply bytes-append
                        (for/list ([it (in-list p-items)])
                          (define itf (decode-protobuf-message (third it)))
                          (define ab (let ([p (assoc 1 itf)]) (if p (third p) 0)))
                          (define tp-e (assoc 2 itf))
                          (define-values (px py)
                            (if tp-e
                                (let ([ptf (decode-protobuf-message (third tp-e))])
                                  (values (let ([xp (assoc 1 ptf)])
                                            (if (and xp (bytes? (third xp)))
                                                (floating-point-bytes->real (third xp) #f)
                                                0.0))
                                          (let ([yp (assoc 2 ptf)])
                                            (if (and yp (bytes? (third yp)))
                                                (floating-point-bytes->real (third yp) #f)
                                                0.0))))
                                (values 0.0 0.0)))
                          (encode-submessage-field 3 (encode-int32 1 (decide-fn ab px py))))))
               (define resp (bytes-append (encode-submessage-field 14 res-b) id-b (encode-int32 99 3)))
               (define rlen (bytes-length resp))
               (define rhdr
                 (cond [(< rlen 126) (bytes #x82 rlen)]
                       [(<= rlen 65535) (bytes-append (bytes #x82 126) (integer->integer-bytes rlen 2 #f #t))]
                       [else (bytes-append (bytes #x82 127) (integer->integer-bytes rlen 8 #f #t))]))
               (write-bytes rhdr s-out)
               (write-bytes resp s-out)
               (flush-output s-out))
             (lp))))))
    (values ws rpc-cnt (lambda () (close-output-port c-out) (close-input-port c-in) (thread-wait th))))

  ;; L26-P0-1a: `shield-battery` (`895`, 2x2) flush side-by-side (`d = 2.0`) against Pylon `(32, 32)`:
  ;; standard `#:min-spacing 2.0` rejects `d = 2.0` (`req-d = 2.0` strict `>`), so RPC #1 misses and
  ;; tight-spacing `#:min-spacing 0.5` immediately succeeds on RPC #2 in the SAME step!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (set-box! SC2-PROTOSS-POWER-PLACEMENT-FAIL-LOOP -9999)
  (let-values ([(ws rpc-cnt cleanup!)
                (l26-start-mock-ws
                 (lambda (ab px py)
                   (if (and (= ab 895) (<= (l26-dist px py 32.0 32.0) 2.05)) 1 2)))])
    (define nx-m (mk-l26-u 9601 59 1 26.5 26.5 #:hp 1000.0 #:shield 1000.0 #:rad 2.75))
    (define py-m (mk-l26-u 9602 60 1 32.0 32.0 #:hp 200.0 #:shield 200.0 #:rad 1.0))
    (define prb1 (mk-l26-u 9603 84 1 30.0 31.0 #:hp 20.0 #:shield 20.0 #:rad 0.375))
    (define obs-sb
      (sc2-observation 9500 (sc2-player-common 1 400 100 40 24 6 18 0 0 0 0)
                       (list nx-m py-m prb1) '()
                       (list (sc2-power-source (sc2-point3d 32.0 32.0 8.0) 6.5 9602))
                       #f '() '() '() '() '() '()))
    (define sb-cmds
      (translate-bot-actions->sc2-raw-commands '((build shield-battery 32.0 32.0))
                                               obs-sb #:ws-conn ws #:game-info w3-ginfo))
    (define sb-cmd
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 895))) sb-cmds))
    (define sb-pt (and sb-cmd (sc2-raw-unit-command-target-pos sb-cmd)))
    (check-true "l26-p0-1a-shield-battery-tight-05-places-flush-against-pylon-when-20-fails"
                (and (= (unbox rpc-cnt) 2)
                     (sc2-point2d? sb-pt)
                     (<= (l26-dist (sc2-point2d-x sb-pt) (sc2-point2d-y sb-pt) 32.0 32.0) 2.05)
                     (= (unbox SC2-PROTOSS-POWER-PLACEMENT-FAIL-LOOP) -9999)))
    (cleanup!))

  ;; L26-P0-1b (`#21`/`#36` crowded Pylon Gateway): When an in-transit Probe build at `(31.5, 34.0)` blocks
  ;; the only open Gateway (`883`) spot `(33.5, 33.5)` (`dist = 2.06 < 2.5`) under `#:min-spacing 2.0`,
  ;; tight-spacing `#:min-spacing 0.5` (`reserved-dist = 1.5`) immediately places Gateway in the SAME step!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (set-box! SC2-PROTOSS-POWER-PLACEMENT-FAIL-LOOP -9999)
  (let-values ([(ws rpc-cnt cleanup!)
                (l26-start-mock-ws
                 (lambda (ab px py)
                   (if (and (= ab 883) (<= (l26-dist px py 33.5 33.5) 0.1)) 1 2)))])
    (define nx-m (mk-l26-u 9611 59 1 26.5 26.5 #:hp 1000.0 #:shield 1000.0 #:rad 2.75))
    (define py-m (mk-l26-u 9612 60 1 30.0 34.0 #:hp 200.0 #:shield 200.0 #:rad 1.0))
    (define gw1  (mk-l26-u 9613 62 1 26.5 34.5 #:hp 500.0 #:shield 500.0 #:rad 1.5))
    (define cyb1 (mk-l26-u 9614 72 1 30.5 37.5 #:hp 550.0 #:shield 550.0 #:rad 1.5))
    (define prb-busy
      (mk-l26-u 9615 84 1 31.0 33.0 #:hp 20.0 #:shield 20.0 #:rad 0.375
                #:orders (list (sc2-unit-order 881 (sc2-point3d 31.5 34.0 8.0) 0 0.0))))
    (define prb-free (mk-l26-u 9616 84 1 29.0 32.0 #:hp 20.0 #:shield 20.0 #:rad 0.375))
    (define obs-gw
      (sc2-observation 9600 (sc2-player-common 1 550 100 40 28 8 20 0 0 0 0)
                       (list nx-m py-m gw1 cyb1 prb-busy prb-free) '()
                       (list (sc2-power-source (sc2-point3d 30.0 34.0 8.0) 6.5 9612))
                       #f '() '() '() '() '() '()))
    (define gw-cmds
      (translate-bot-actions->sc2-raw-commands '((build gateway 30.0 34.0))
                                               obs-gw #:ws-conn ws #:game-info w3-ginfo))
    (define gw-cmd
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 883))) gw-cmds))
    (define gw-pt (and gw-cmd (sc2-raw-unit-command-target-pos gw-cmd)))
    (check-true "l26-p0-1b-gateway-tight-05-fallback-places-crowded-pylon-in-same-step"
                (and (= (unbox rpc-cnt) 2)
                     (sc2-point2d? gw-pt)
                     (<= (l26-dist (sc2-point2d-x gw-pt) (sc2-point2d-y gw-pt) 33.5 33.5) 0.1)
                     (= (unbox SC2-PROTOSS-POWER-PLACEMENT-FAIL-LOOP) -9999)))
    (cleanup!))

  ;; L26-P0-1c: `robotics-facility` (`893`) with packed Main Pylon + contested 3rd Pylon (`96, 30` with enemy
  ;; Zerglings) widens tight-spacing `0.5` fallback cleanly to uncontested Natural Pylon `(64, 30)`!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (set-box! SC2-PROTOSS-POWER-PLACEMENT-FAIL-LOOP -9999)
  (let-values ([(ws rpc-cnt cleanup!)
                (l26-start-mock-ws
                 (lambda (ab px py)
                   ;; Only tight spot `(66.5, 30.5)` at Natural (`dist = 2.06` from in-transit Probe at `(64.5, 31.0)`)
                   ;; OR contested 3rd Pylon `(96, 30)` are accepted — MUST pick Natural `(66.5, 30.5)`, NEVER 3rd!
                   (if (and (= ab 893)
                            (or (<= (l26-dist px py 66.5 30.5) 0.1)
                                (>= px 90.0)))
                       1 2)))])
    (define nx-m (mk-l26-u 9621 59 1 26.5 26.5 #:hp 1000.0 #:shield 1000.0 #:rad 2.75))
    (define nx-n (mk-l26-u 9622 59 1 64.5 24.5 #:hp 1000.0 #:shield 1000.0 #:rad 2.75))
    (define py-m (mk-l26-u 9623 60 1 30.0 34.0 #:hp 200.0 #:shield 200.0 #:rad 1.0))
    (define py-n (mk-l26-u 9624 60 1 64.0 30.0 #:hp 200.0 #:shield 200.0 #:rad 1.0))
    (define py-3 (mk-l26-u 9625 60 1 96.0 30.0 #:hp 200.0 #:shield 200.0 #:rad 1.0))
    (define prb-busy
      (mk-l26-u 9626 84 1 63.0 31.0 #:hp 20.0 #:shield 20.0 #:rad 0.375
                #:orders (list (sc2-unit-order 881 (sc2-point3d 64.5 31.0 8.0) 0 0.0))))
    (define prb-free (mk-l26-u 9627 84 1 62.0 29.0 #:hp 20.0 #:shield 20.0 #:rad 0.375))
    (define ling-3 (mk-l26-u 9628 105 4 95.5 31.0 #:hp 35.0 #:rad 0.375))
    (define obs-robo
      (sc2-observation 9700 (sc2-player-common 1 500 200 60 36 10 26 0 0 0 0)
                       (list nx-m nx-n py-m py-n py-3 prb-busy prb-free ling-3) '()
                       (list (sc2-power-source (sc2-point3d 30.0 34.0 8.0) 6.5 9623)
                             (sc2-power-source (sc2-point3d 64.0 30.0 8.0) 6.5 9624)
                             (sc2-power-source (sc2-point3d 96.0 30.0 8.0) 6.5 9625))
                       #f '() '() '() '() '() '()))
    (define robo-cmds
      (translate-bot-actions->sc2-raw-commands '((build robotics-facility 30.0 34.0))
                                               obs-robo #:ws-conn ws #:game-info w3-ginfo))
    (define robo-cmd
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 893))) robo-cmds))
    (define robo-pt (and robo-cmd (sc2-raw-unit-command-target-pos robo-cmd)))
    (check-true "l26-p0-1c-robotics-facility-tight-05-widens-to-uncontested-natural-skipping-contested"
                (and (= (unbox rpc-cnt) 2)
                     (sc2-point2d? robo-pt)
                     (<= (l26-dist (sc2-point2d-x robo-pt) (sc2-point2d-y robo-pt) 66.5 30.5) 0.1)
                     (= (unbox SC2-PROTOSS-POWER-PLACEMENT-FAIL-LOOP) -9999)))
    (cleanup!))

  ;; L26-P0-1d: When EVERY spot on ALL uncontested Pylons fails BOTH `2.0` AND tight `0.5`, BOTH searches
  ;; execute (`rpc-cnt = 2`, distinct `'tight` neg-cd key), `SC2-PROTOSS-POWER-PLACEMENT-FAIL-LOOP` is set
  ;; to `9800`, and a repeat call 4 frames later (`9804`) hits both neg-cd caches (`0` extra RPCs)!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (set-box! SC2-PROTOSS-POWER-PLACEMENT-FAIL-LOOP -9999)
  (let-values ([(ws rpc-cnt cleanup!)
                (l26-start-mock-ws (lambda (_ab _px _py) 2))])
    (define nx-m (mk-l26-u 9631 59 1 26.5 26.5 #:hp 1000.0 #:shield 1000.0 #:rad 2.75))
    (define py-m (mk-l26-u 9632 60 1 32.0 32.0 #:hp 200.0 #:shield 200.0 #:rad 1.0))
    (define prb1 (mk-l26-u 9633 84 1 30.0 31.0 #:hp 20.0 #:shield 20.0 #:rad 0.375))
    (define (mk-sg-obs gl)
      (sc2-observation gl (sc2-player-common 1 500 200 60 36 10 26 0 0 0 0)
                       (list nx-m py-m prb1) '()
                       (list (sc2-power-source (sc2-point3d 32.0 32.0 8.0) 6.5 9632))
                       #f '() '() '() '() '() '()))
    (define sg-cmds-1
      (translate-bot-actions->sc2-raw-commands '((build stargate 32.0 32.0))
                                               (mk-sg-obs 9800) #:ws-conn ws #:game-info w3-ginfo))
    (define rpcs-after-1 (unbox rpc-cnt))
    (define fail-loop-1 (unbox SC2-PROTOSS-POWER-PLACEMENT-FAIL-LOOP))
    (translate-bot-actions->sc2-raw-commands '((build stargate 32.0 32.0))
                                             (mk-sg-obs 9804) #:ws-conn ws #:game-info w3-ginfo)
    (check-true "l26-p0-1d-fail-loop-only-set-after-tight-05-also-fails-and-neg-cd-key-distinct"
                (and (not (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 889))) sg-cmds-1))
                     (= rpcs-after-1 2)
                     (= fail-loop-1 9800)
                     (= (unbox rpc-cnt) 2)))
    (cleanup!)))

(printf "[Loop 27] Testing L27-P0-1 all-base Protoss tight-05 overflow (#18 25-streak) & Terran barracks4+ 0.5t 3x3 overflow (#05/#20/#23)...\n")
(let ()
  (define (l27-dist x1 y1 x2 y2)
    (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))
  (define (mk-l27-u tag utype alliance x y
                    #:hp [hp 100.0] #:shield [sh 0.0] #:rad [rad 1.0] #:orders [ords '()])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 2)
              (sc2-point3d x y 8.0) 0.0 rad 1.0 0 #f #f #f
              hp hp sh sh 0.0 0.0 0 0 #f #f #f #t #f
              ords 0 '() 0 0 0.0 0 0 0 0 '() 0 0))
  (define (l27-start-mock-ws decide-fn)
    (define-values (c-in s-out) (make-pipe))
    (define-values (s-in c-out) (make-pipe))
    (define ws (sc2-ws-conn "127.0.0.1" 59927 "/sc2api" c-in c-out #f 1))
    (define rpc-cnt (box 0))
    (define saw-319? (box #f))
    (define th
      (thread
       (lambda ()
         (let lp ()
           (define b0 (read-byte s-in))
           (unless (eof-object? b0)
             (define b1 (read-byte s-in))
             (define masked? (not (zero? (bitwise-and b1 #x80))))
             (define len0 (bitwise-and b1 #x7F))
             (define plen
               (cond [(< len0 126) len0]
                     [(= len0 126) (integer-bytes->integer (read-bytes 2 s-in) #f #t)]
                     [else (integer-bytes->integer (read-bytes 8 s-in) #f #t)]))
             (define mkey (if masked? (read-bytes 4 s-in) #f))
             (define raw (read-bytes plen s-in))
             (define payload
               (if masked?
                   (let ([out (make-bytes plen)])
                     (for ([i (in-range plen)])
                       (bytes-set! out i (bitwise-xor (bytes-ref raw i) (bytes-ref mkey (modulo i 4)))))
                     out)
                   raw))
             (define req-f (decode-protobuf-message payload))
             (define req-id-p (assoc 97 req-f))
             (define id-b (if req-id-p (encode-uint32 97 (third req-id-p)) #""))
             (define q-p (assoc 14 req-f))
             (when q-p
               (set-box! rpc-cnt (add1 (unbox rpc-cnt)))
               (define qf (decode-protobuf-message (third q-p)))
               (define p-items (filter (lambda (e) (= (first e) 3)) qf))
               (define res-b
                 (apply bytes-append
                        (for/list ([it (in-list p-items)])
                          (define itf (decode-protobuf-message (third it)))
                          (define ab (let ([p (assoc 1 itf)]) (if p (third p) 0)))
                          (when (= ab 319) (set-box! saw-319? #t))
                          (define tp-e (assoc 2 itf))
                          (define-values (px py)
                            (if tp-e
                                (let ([ptf (decode-protobuf-message (third tp-e))])
                                  (values (let ([xp (assoc 1 ptf)])
                                            (if (and xp (bytes? (third xp)))
                                                (floating-point-bytes->real (third xp) #f)
                                                0.0))
                                          (let ([yp (assoc 2 ptf)])
                                            (if (and yp (bytes? (third yp)))
                                                (floating-point-bytes->real (third yp) #f)
                                                0.0))))
                                (values 0.0 0.0)))
                          (encode-submessage-field 3 (encode-int32 1 (decide-fn ab px py))))))
               (define resp (bytes-append (encode-submessage-field 14 res-b) id-b (encode-int32 99 3)))
               (define rlen (bytes-length resp))
               (define rhdr
                 (cond [(< rlen 126) (bytes #x82 rlen)]
                       [(<= rlen 65535) (bytes-append (bytes #x82 126) (integer->integer-bytes rlen 2 #f #t))]
                       [else (bytes-append (bytes #x82 127) (integer->integer-bytes rlen 8 #f #t))]))
               (write-bytes rhdr s-out)
               (write-bytes resp s-out)
               (flush-output s-out))
             (lp))))))
    (values ws rpc-cnt saw-319? (lambda () (close-output-port c-out) (close-input-port c-in) (thread-wait th))))

  ;; L27-P0-1a (`#18` 25-streak late-game gateway stall): 12 uncontested completed Pylons across 4 bases
  ;; (9 jammed in Main, 2 jammed in Natural, 1 open at 4th base `(104, 96)` ONLY at tight `0.5t` spot
  ;; `(106.5, 96.5)`, `dist = 2.06` from in-transit Probe at `(104.5, 97.0)`!). Base-diversified
  ;; `tight-safe-pylons` + `24`-anchor cap reaches 4th base in the SAME step instead of truncating at 8!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (set-box! SC2-PROTOSS-POWER-PLACEMENT-FAIL-LOOP -9999)
  (let-values ([(ws rpc-cnt _saw319 cleanup!)
                (l27-start-mock-ws
                 (lambda (ab px py)
                   (if (and (= ab 883) (<= (l27-dist px py 106.5 96.5) 0.1)) 1 2)))])
    (define nx-m (mk-l27-u 9701 59 1 26.5 26.5 #:hp 1000.0 #:shield 1000.0 #:rad 2.75))
    (define nx-n (mk-l27-u 9702 59 1 64.5 26.5 #:hp 1000.0 #:shield 1000.0 #:rad 2.75))
    (define nx-4 (mk-l27-u 9703 59 1 100.5 90.5 #:hp 1000.0 #:shield 1000.0 #:rad 2.75))
    (define pylon-coords
      (list (cons 22.0 34.0) (cons 25.0 34.0) (cons 28.0 34.0)
            (cons 31.0 34.0) (cons 34.0 34.0) (cons 22.0 37.0)
            (cons 25.0 37.0) (cons 28.0 37.0) (cons 31.0 37.0)
            (cons 62.0 34.0) (cons 66.0 34.0)
            (cons 104.0 96.0)))
    (define pylons
      (for/list ([pt (in-list pylon-coords)] [i (in-naturals 0)])
        (mk-l27-u (+ 9710 i) 60 1 (car pt) (cdr pt) #:hp 200.0 #:shield 200.0 #:rad 1.0)))
    (define psrcs
      (for/list ([pt (in-list pylon-coords)] [i (in-naturals 0)])
        (sc2-power-source (sc2-point3d (car pt) (cdr pt) 8.0) 6.5 (+ 9710 i))))
    (define gws
      (list (mk-l27-u 9730 62 1 36.5 34.5 #:hp 500.0 #:shield 500.0 #:rad 1.5)
            (mk-l27-u 9731 62 1 36.5 37.5 #:hp 500.0 #:shield 500.0 #:rad 1.5)
            (mk-l27-u 9732 62 1 39.5 34.5 #:hp 500.0 #:shield 500.0 #:rad 1.5)
            (mk-l27-u 9733 62 1 39.5 37.5 #:hp 500.0 #:shield 500.0 #:rad 1.5)))
    (define prb-busy
      (mk-l27-u 9734 84 1 103.0 96.0 #:hp 20.0 #:shield 20.0 #:rad 0.375
                #:orders (list (sc2-unit-order 881 (sc2-point3d 104.5 97.0 8.0) 0 0.0))))
    (define prb-free (mk-l27-u 9735 84 1 102.0 94.0 #:hp 20.0 #:shield 20.0 #:rad 0.375))
    (define obs-12py
      (sc2-observation 10000 (sc2-player-common 1 1200 300 120 80 40 40 0 0 0 0)
                       (append (list nx-m nx-n nx-4 prb-busy prb-free) pylons gws)
                       '() psrcs #f '() '() '() '() '() '()))
    (define gw-cmds
      (translate-bot-actions->sc2-raw-commands '((build gateway 30.0 34.0))
                                               obs-12py #:ws-conn ws #:game-info w3-ginfo))
    (define gw-cmd
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 883))) gw-cmds))
    (define gw-pt (and gw-cmd (sc2-raw-unit-command-target-pos gw-cmd)))
    (check-true "l27-p0-1a-protoss-gateway-tight-05-searches-across-all-12-pylons-reaching-4th-base"
                (and (= (unbox rpc-cnt) 2)
                     (sc2-point2d? gw-pt)
                     (<= (l27-dist (sc2-point2d-x gw-pt) (sc2-point2d-y gw-pt) 106.5 96.5) 0.1)
                     (= (unbox SC2-PROTOSS-POWER-PLACEMENT-FAIL-LOOP) -9999)))
    (cleanup!))

  ;; L27-P0-1b: Non-gateway Protoss tech (`twilight-council`, `886`) also uses tight-05 fallback across
  ;; > 8 Pylons, skipping 9 jammed Main/Natural Pylons to place cleanly at 3rd base Pylon `(98, 32)`!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (set-box! SC2-PROTOSS-POWER-PLACEMENT-FAIL-LOOP -9999)
  (let-values ([(ws rpc-cnt _saw319 cleanup!)
                (l27-start-mock-ws
                 (lambda (ab px py)
                   (if (and (= ab 886) (<= (l27-dist px py 100.5 32.5) 0.1)) 1 2)))])
    (define nx-m (mk-l27-u 9741 59 1 26.5 26.5 #:hp 1000.0 #:shield 1000.0 #:rad 2.75))
    (define py-coords
      (list (cons 22.0 34.0) (cons 25.0 34.0) (cons 28.0 34.0)
            (cons 31.0 34.0) (cons 34.0 34.0) (cons 22.0 37.0)
            (cons 25.0 37.0) (cons 28.0 37.0) (cons 31.0 37.0)
            (cons 98.0 32.0)))
    (define pylons
      (for/list ([pt (in-list py-coords)] [i (in-naturals 0)])
        (mk-l27-u (+ 9750 i) 60 1 (car pt) (cdr pt) #:hp 200.0 #:shield 200.0 #:rad 1.0)))
    (define psrcs
      (for/list ([pt (in-list py-coords)] [i (in-naturals 0)])
        (sc2-power-source (sc2-point3d (car pt) (cdr pt) 8.0) 6.5 (+ 9750 i))))
    (define prb-busy
      (mk-l27-u 9765 84 1 97.0 33.0 #:hp 20.0 #:shield 20.0 #:rad 0.375
                #:orders (list (sc2-unit-order 881 (sc2-point3d 98.5 33.0 8.0) 0 0.0))))
    (define prb-free (mk-l27-u 9766 84 1 96.0 31.0 #:hp 20.0 #:shield 20.0 #:rad 0.375))
    (define obs-tc
      (sc2-observation 10100 (sc2-player-common 1 800 300 100 60 30 30 0 0 0 0)
                       (append (list nx-m prb-busy prb-free) pylons)
                       '() psrcs #f '() '() '() '() '() '()))
    (define tc-cmds
      (translate-bot-actions->sc2-raw-commands '((build twilight-council 28.0 34.0))
                                               obs-tc #:ws-conn ws #:game-info w3-ginfo))
    (define tc-cmd
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 886))) tc-cmds))
    (define tc-pt (and tc-cmd (sc2-raw-unit-command-target-pos tc-cmd)))
    (check-true "l27-p0-1b-protoss-late-tech-twilight-council-tight-05-reaches-3rd-base-over-10-pylons"
                (and (= (unbox rpc-cnt) 2)
                     (sc2-point2d? tc-pt)
                     (<= (l27-dist (sc2-point2d-x tc-pt) (sc2-point2d-y tc-pt) 100.5 32.5) 0.1)
                     (= (unbox SC2-PROTOSS-POWER-PLACEMENT-FAIL-LOOP) -9999)))
    (cleanup!))

  ;; L27-P0-1c (`#05/#20/#23` Terran barracks #4+): Natural CC `(64.5, 30.5)` sits on a real mineral-solved
  ;; expansion pad (`all-expansion-pads` includes `(64.5, 30.5)`), so the only open Barracks spot `(68.5, 30.5)`
  ;; (`Chebyshev dist = 4.0 < 4.5`) is rejected by `place-pt0` (`#:min-spacing 2.0`, `pad-clr = 4.5`) on RPC #1
  ;; and IMMEDIATELY placed by L27 `0.5t` pure `3x3` overflow (`tight-pad-clearance = 3.95`) on RPC #2 with ZERO `319`!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-clear! SC2-TERRAN-5X3-MISS-CACHE)
  (hash-set! SC2-TERRAN-5X3-MISS-STREAK 'barracks 2)
  (let-values ([(ws rpc-cnt saw-319? cleanup!)
                (l27-start-mock-ws
                 (lambda (ab px py)
                   (if (and (= ab 321) (<= (l27-dist px py 68.5 30.5) 0.1)) 1 2)))])
    (define cc-m (mk-l27-u 9771 18 1 28.5 28.5 #:hp 1500.0 #:rad 2.75))
    (define cc-n (mk-l27-u 9772 18 1 64.5 30.5 #:hp 1500.0 #:rad 2.75))
    (define rax1 (mk-l27-u 9773 21 1 34.5 28.5 #:hp 1000.0 #:rad 1.5))
    (define rax2 (mk-l27-u 9774 21 1 34.5 33.5 #:hp 1000.0 #:rad 1.5))
    (define rax3 (mk-l27-u 9775 21 1 28.5 35.5 #:hp 1000.0 #:rad 1.5))
    (define scv-free (mk-l27-u 9777 45 1 63.0 29.0 #:hp 45.0 #:rad 0.375))
    (define nat-mins
      (for/list ([y (in-list '(27.5 29.5 31.5 33.5))] [i (in-naturals 0)])
        (sc2-unit 1 3 (+ 9780 i) 341 0 (sc2-point3d 71.0 y 8.0) 0.0 1.0 1.0 0 #f #f #f
                  1000.0 1000.0 0.0 0.0 0.0 0.0 1500 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0 '() 0 0)))
    (define l27-t-ginfo
      (sc2-game-info "L27TerranMap" "" '() '(128 128) '(4 4 124 124)
                     (list (sc2-point2d 100.0 100.0))
                     w3-full-grid #f w3-full-grid))
    (define r4-cmds
      (translate-bot-actions->sc2-raw-commands
       '((build barracks 32.0 30.0))
       (make-test-obs 10200 600 100 (append (list cc-m cc-n rax1 rax2 rax3 scv-free) nat-mins))
       #:ws-conn ws #:game-info l27-t-ginfo))
    (define r4-cmd
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 321))) r4-cmds))
    (define r4-pt (and r4-cmd (sc2-raw-unit-command-target-pos r4-cmd)))
    (check-true "l27-p0-1c-barracks4-tight-05-3x3-places-crowded-base-in-same-step-without-319"
                (and (= (unbox rpc-cnt) 2)
                     (not (unbox saw-319?))
                     (sc2-point2d? r4-pt)
                     (<= (l27-dist (sc2-point2d-x r4-pt) (sc2-point2d-y r4-pt) 68.5 30.5) 0.1)))
    (cleanup!))
  (hash-clear! SC2-TERRAN-5X3-MISS-STREAK))

(printf "[Loop 28] Testing L28-P0-1 early-rush Main-safe Gateway #2+, last-resort contested tight-05 (#36), & Terran barracks #2+ 0.5t overflow (#11/#20/#23)...\n")
(let ()
  (define (l28-dist x1 y1 x2 y2)
    (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))
  (define (mk-l28-u tag utype alliance x y
                    #:hp [hp 100.0] #:shield [sh 0.0] #:rad [rad 1.0] #:orders [ords '()])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 2)
              (sc2-point3d x y 8.0) 0.0 rad 1.0 0 #f #f #f
              hp hp sh sh 0.0 0.0 0 0 #f #f #f #t #f
              ords 0 '() 0 0 0.0 0 0 0 0 '() 0 0))
  (define (l28-start-mock-ws decide-fn)
    (define-values (c-in s-out) (make-pipe))
    (define-values (s-in c-out) (make-pipe))
    (define ws (sc2-ws-conn "127.0.0.1" 59928 "/sc2api" c-in c-out #f 1))
    (define rpc-cnt (box 0))
    (define th
      (thread
       (lambda ()
         (let lp ()
           (define b0 (read-byte s-in))
           (unless (eof-object? b0)
             (define b1 (read-byte s-in))
             (define masked? (not (zero? (bitwise-and b1 #x80))))
             (define len0 (bitwise-and b1 #x7F))
             (define plen
               (cond [(< len0 126) len0]
                     [(= len0 126) (integer-bytes->integer (read-bytes 2 s-in) #f #t)]
                     [else (integer-bytes->integer (read-bytes 8 s-in) #f #t)]))
             (define mkey (if masked? (read-bytes 4 s-in) #f))
             (define raw (read-bytes plen s-in))
             (define payload
               (if masked?
                   (let ([out (make-bytes plen)])
                     (for ([i (in-range plen)])
                       (bytes-set! out i (bitwise-xor (bytes-ref raw i) (bytes-ref mkey (modulo i 4)))))
                     out)
                   raw))
             (define req-f (decode-protobuf-message payload))
             (define req-id-p (assoc 97 req-f))
             (define id-b (if req-id-p (encode-uint32 97 (third req-id-p)) #""))
             (define q-p (assoc 14 req-f))
             (when q-p
               (set-box! rpc-cnt (add1 (unbox rpc-cnt)))
               (define qf (decode-protobuf-message (third q-p)))
               (define p-items (filter (lambda (e) (= (first e) 3)) qf))
               (define res-b
                 (apply bytes-append
                        (for/list ([it (in-list p-items)])
                          (define itf (decode-protobuf-message (third it)))
                          (define ab (let ([p (assoc 1 itf)]) (if p (third p) 0)))
                          (define tp-e (assoc 2 itf))
                          (define-values (px py)
                            (if tp-e
                                (let ([ptf (decode-protobuf-message (third tp-e))])
                                  (values (let ([xp (assoc 1 ptf)])
                                            (if (and xp (bytes? (third xp)))
                                                (floating-point-bytes->real (third xp) #f)
                                                0.0))
                                          (let ([yp (assoc 2 ptf)])
                                            (if (and yp (bytes? (third yp)))
                                                (floating-point-bytes->real (third yp) #f)
                                                0.0))))
                                (values 0.0 0.0)))
                          (encode-submessage-field 3 (encode-int32 1 (decide-fn ab px py))))))
               (define resp (bytes-append (encode-submessage-field 14 res-b) id-b (encode-int32 99 3)))
               (define rlen (bytes-length resp))
               (define rhdr
                 (cond [(< rlen 126) (bytes #x82 rlen)]
                       [(<= rlen 65535) (bytes-append (bytes #x82 126) (integer->integer-bytes rlen 2 #f #t))]
                       [else (bytes-append (bytes #x82 127) (integer->integer-bytes rlen 8 #f #t))]))
               (write-bytes rhdr s-out)
               (write-bytes resp s-out)
               (flush-output s-out))
             (lp))))))
    (values ws rpc-cnt (lambda () (close-output-port c-out) (close-input-port c-in) (thread-wait th))))

  ;; L28-P0-1a (`#36` < 4:00 early rush Main-safe Gateway #2+): 4 Zerglings approaching within 35t of Main
  ;; (still > 6.0t from exposed Natural-wall Pylon `(48, 30)` so `req-contested?` is `#f`!). Brain asks
  ;; `(build gateway 48.0 30.0)` while Main Pylon `(30, 34)` is safe -> MUST anchor `Gateway #2` inside
  ;; Main Pylon `(30, 34)` instead of stacking Gateways on the exposed Natural wall Pylon!
  (let-values ([(ws _rpc-cnt cleanup!)
                (l28-start-mock-ws (lambda (ab _px _py) (if (= ab 883) 1 2)))])
    (define nx-m  (mk-l28-u 9801 59 1 28.5 28.5 #:hp 1000.0 #:shield 1000.0 #:rad 2.75))
    (define py-m  (mk-l28-u 9802 60 1 30.0 34.0 #:hp 200.0 #:shield 200.0 #:rad 1.0))
    (define py-w  (mk-l28-u 9803 60 1 48.0 30.0 #:hp 200.0 #:shield 200.0 #:rad 1.0))
    (define gw1   (mk-l28-u 9804 62 1 50.5 30.5 #:hp 500.0 #:shield 500.0 #:rad 1.5))
    (define prb1  (mk-l28-u 9805 84 1 31.0 31.0 #:hp 20.0 #:shield 20.0 #:rad 0.375))
    (define lings
      (for/list ([i (in-range 4)])
        (mk-l28-u (+ 9810 i) 105 4 (+ 57.0 (* 0.5 i)) 30.0 #:hp 35.0 #:rad 0.375)))
    (define obs-gw2
      (sc2-observation 3200 (sc2-player-common 1 400 0 31 20 2 18 0 0 0 0)
                       (append (list nx-m py-m py-w gw1 prb1) lings)
                       '()
                       (list (sc2-power-source (sc2-point3d 30.0 34.0 8.0) 6.5 9802)
                             (sc2-power-source (sc2-point3d 48.0 30.0 8.0) 6.5 9803))
                       #f '() '() '() '() '() '()))
    (define gw2-cmds
      (translate-bot-actions->sc2-raw-commands '((build gateway 48.0 30.0))
                                               obs-gw2 #:ws-conn ws #:game-info w3-ginfo))
    (define gw2-cmd
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 883))) gw2-cmds))
    (define gw2-pt (and gw2-cmd (sc2-raw-unit-command-target-pos gw2-cmd)))
    (check-true "l28-p0-1a-early-rush-gateway2-anchors-on-main-pylon-over-exposed-natural-wall"
                (and (sc2-point2d? gw2-pt)
                     (<= (l28-dist (sc2-point2d-x gw2-pt) (sc2-point2d-y gw2-pt) 30.0 34.0) 6.5)
                     (> (l28-dist (sc2-point2d-x gw2-pt) (sc2-point2d-y gw2-pt) 48.0 30.0) 8.0)))
    (cleanup!))

  ;; L28-P0-1b (`#36` 11-streak stall at 530M when ALL Pylons are contested): Both Main Pylon `(32, 32)`
  ;; and outer Pylon `(52, 32)` have Zerglings within `6.5t` (`uncontested-pylons = '()`). Only tight spot
  ;; `(34.5, 32.5)` (`dist = 2.33` from Main Ling `(32.5, 33.7)` -> `< 2.525` rejected at `2.0`, `> 2.025`
  ;; accepted at `0.5`!) is accepted -> last-resort `0.5t` runs on RPC #2 and places Gateway at Main Pylon!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (set-box! SC2-PROTOSS-POWER-PLACEMENT-FAIL-LOOP -9999)
  (let-values ([(ws rpc-cnt cleanup!)
                (l28-start-mock-ws
                 (lambda (ab px py)
                   (if (and (= ab 883) (<= (l28-dist px py 34.5 32.5) 0.1)) 1 2)))])
    (define nx-m   (mk-l28-u 9821 59 1 28.5 28.5 #:hp 1000.0 #:shield 1000.0 #:rad 2.75))
    (define py-m   (mk-l28-u 9822 60 1 32.0 32.0 #:hp 200.0 #:shield 200.0 #:rad 1.0))
    (define py-o   (mk-l28-u 9823 60 1 52.0 32.0 #:hp 200.0 #:shield 200.0 #:rad 1.0))
    (define prb1   (mk-l28-u 9824 84 1 30.0 30.0 #:hp 20.0 #:shield 20.0 #:rad 0.375))
    (define ling-m (mk-l28-u 9825 105 4 32.5 33.7 #:hp 35.0 #:rad 0.375))
    (define ling-o (mk-l28-u 9826 105 4 52.0 34.0 #:hp 35.0 #:rad 0.375))
    (define obs-all-cont
      (sc2-observation 3400 (sc2-player-common 1 530 0 31 18 0 18 0 0 0 0)
                       (list nx-m py-m py-o prb1 ling-m ling-o)
                       '()
                       (list (sc2-power-source (sc2-point3d 32.0 32.0 8.0) 6.5 9822)
                             (sc2-power-source (sc2-point3d 52.0 32.0 8.0) 6.5 9823))
                       #f '() '() '() '() '() '()))
    (define gw-cmds
      (translate-bot-actions->sc2-raw-commands '((build gateway 52.0 32.0))
                                               obs-all-cont #:ws-conn ws #:game-info w3-ginfo))
    (define gw-cmd
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 883))) gw-cmds))
    (define gw-pt (and gw-cmd (sc2-raw-unit-command-target-pos gw-cmd)))
    (check-true "l28-p0-1b-all-pylons-contested-last-resort-tight-05-places-closest-to-main"
                (and (= (unbox rpc-cnt) 2)
                     (sc2-point2d? gw-pt)
                     (<= (l28-dist (sc2-point2d-x gw-pt) (sc2-point2d-y gw-pt) 34.5 32.5) 0.1)
                     (= (unbox SC2-PROTOSS-POWER-PLACEMENT-FAIL-LOOP) -9999)))
    (cleanup!))

  ;; L28-P0-1c (`#11/#20/#23` Terran barracks #2+): With ONLY 1 existing Barracks (`cur-rax-count = 1`),
  ;; after `place-pt0` (`5x3` + `2.0t` `unq-3x3`) misses on tick 1 (`3600`), tick 2 (`3604`) hits `2.0`
  ;; neg-cd and L28 `is-rax2+?` `0.5t` pure `3x3` overflow IMMEDIATELY places `barracks #2` at `(68.5, 30.5)`
  ;; (`Chebyshev = 4.0 < 4.5` for `2.0`, `>= 3.95` for `0.5`) instead of stalling 48 frames!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-clear! SC2-TERRAN-5X3-MISS-CACHE)
  (hash-clear! SC2-TERRAN-5X3-MISS-STREAK)
  (let-values ([(ws _rpc-cnt cleanup!)
                (l28-start-mock-ws
                 (lambda (ab px py)
                   (if (and (= ab 321) (<= (l28-dist px py 68.5 30.5) 0.1)) 1 2)))])
    (define cc-m (mk-l28-u 9831 18 1 28.5 28.5 #:hp 1500.0 #:rad 2.75))
    (define cc-n (mk-l28-u 9832 18 1 64.5 30.5 #:hp 1500.0 #:rad 2.75))
    (define rax1 (mk-l28-u 9833 21 1 34.5 28.5 #:hp 1000.0 #:rad 1.5))
    (define scv1 (mk-l28-u 9834 45 1 63.0 29.0 #:hp 45.0 #:rad 0.375))
    (define nat-mins
      (for/list ([y (in-list '(27.5 29.5 31.5 33.5))] [i (in-naturals 0)])
        (sc2-unit 1 3 (+ 9840 i) 341 0 (sc2-point3d 71.0 y 8.0) 0.0 1.0 1.0 0 #f #f #f
                  1000.0 1000.0 0.0 0.0 0.0 0.0 1500 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0 '() 0 0)))
    (define l28-t-ginfo
      (sc2-game-info "L28TerranMap" "" '() '(128 128) '(4 4 124 124)
                     (list (sc2-point2d 100.0 100.0))
                     w3-full-grid #f w3-full-grid))
    (define units-r2 (append (list cc-m cc-n rax1 scv1) nat-mins))
    (define r2-cmds-1
      (translate-bot-actions->sc2-raw-commands
       '((build barracks 32.0 30.0))
       (make-test-obs 3600 450 50 units-r2)
       #:ws-conn ws #:game-info l28-t-ginfo))
    (define r2-cmds-2
      (translate-bot-actions->sc2-raw-commands
       '((build barracks 32.0 30.0))
       (make-test-obs 3604 450 50 units-r2)
       #:ws-conn ws #:game-info l28-t-ginfo))
    (define r2-cmd
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 321)))
             (append r2-cmds-1 r2-cmds-2)))
    (define r2-pt (and r2-cmd (sc2-raw-unit-command-target-pos r2-cmd)))
    (check-true "l28-p0-1c-barracks2-tight-05-3x3-places-crowded-base-immediately-on-20-miss"
                (and (sc2-point2d? r2-pt)
                     (<= (l28-dist (sc2-point2d-x r2-pt) (sc2-point2d-y r2-pt) 68.5 30.5) 0.1)))
    (cleanup!))
  (hash-clear! SC2-TERRAN-5X3-MISS-STREAK))

(printf "[Loop 29] Testing L29-P0-1 Terran barracks #2/#3 fast-3x3+0.5t spillover & emergency cloak static detectors (Cannon/Spore/Turret) at attacked mineral lines...\n")
(let ()
  (define (l29-dist x1 y1 x2 y2)
    (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))
  (define (mk-l29-u tag utype alliance x y
                    #:hp [hp 100.0] #:shield [sh 0.0] #:rad [rad 1.0]
                    #:cloak [clk 0] #:flying? [fly? #f] #:orders [ords '()])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 2)
              (sc2-point3d x y (if fly? 12.0 8.0)) 0.0 rad 1.0 clk #f #f #f
              hp hp sh sh 0.0 0.0 0 0 fly? #f #f #t #f
              ords 0 '() 0 0 0.0 0 0 0 0 '() 0 0))
  (define (mk-l29-mins base-tag)
    (for/list ([y (in-list '(27.5 29.5 31.5 33.5))] [i (in-naturals 0)])
      (sc2-unit 1 3 (+ base-tag i) 341 0 (sc2-point3d 71.0 y 8.0) 0.0 1.0 1.0 0 #f #f #f
                1000.0 1000.0 0.0 0.0 0.0 0.0 1500 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0 '() 0 0)))
  (define (l29-start-mock-ws decide-fn)
    (define-values (c-in s-out) (make-pipe))
    (define-values (s-in c-out) (make-pipe))
    (define ws (sc2-ws-conn "127.0.0.1" 59929 "/sc2api" c-in c-out #f 1))
    (define rpc-cnt (box 0))
    (define saw-319? (box #f))
    (define th
      (thread
       (lambda ()
         (let lp ()
           (define b0 (read-byte s-in))
           (unless (eof-object? b0)
             (define b1 (read-byte s-in))
             (define masked? (not (zero? (bitwise-and b1 #x80))))
             (define len0 (bitwise-and b1 #x7F))
             (define plen
               (cond [(< len0 126) len0]
                     [(= len0 126) (integer-bytes->integer (read-bytes 2 s-in) #f #t)]
                     [else (integer-bytes->integer (read-bytes 8 s-in) #f #t)]))
             (define mkey (if masked? (read-bytes 4 s-in) #f))
             (define raw (read-bytes plen s-in))
             (define payload
               (if masked?
                   (let ([out (make-bytes plen)])
                     (for ([i (in-range plen)])
                       (bytes-set! out i (bitwise-xor (bytes-ref raw i) (bytes-ref mkey (modulo i 4)))))
                     out)
                   raw))
             (define req-f (decode-protobuf-message payload))
             (define req-id-p (assoc 97 req-f))
             (define id-b (if req-id-p (encode-uint32 97 (third req-id-p)) #""))
             (define q-p (assoc 14 req-f))
             (when q-p
               (set-box! rpc-cnt (add1 (unbox rpc-cnt)))
               (define qf (decode-protobuf-message (third q-p)))
               (define p-items (filter (lambda (e) (= (first e) 3)) qf))
               (define res-b
                 (apply bytes-append
                        (for/list ([it (in-list p-items)])
                          (define itf (decode-protobuf-message (third it)))
                          (define ab (let ([p (assoc 1 itf)]) (if p (third p) 0)))
                          (when (= ab 319) (set-box! saw-319? #t))
                          (define tp-e (assoc 2 itf))
                          (define-values (px py)
                            (if tp-e
                                (let ([ptf (decode-protobuf-message (third tp-e))])
                                  (values (let ([xp (assoc 1 ptf)])
                                            (if (and xp (bytes? (third xp)))
                                                (floating-point-bytes->real (third xp) #f)
                                                0.0))
                                          (let ([yp (assoc 2 ptf)])
                                            (if (and yp (bytes? (third yp)))
                                                (floating-point-bytes->real (third yp) #f)
                                                0.0))))
                                (values 0.0 0.0)))
                          (encode-submessage-field 3 (encode-int32 1 (decide-fn ab px py))))))
               (define resp (bytes-append (encode-submessage-field 14 res-b) id-b (encode-int32 99 3)))
               (define rlen (bytes-length resp))
               (define rhdr
                 (cond [(< rlen 126) (bytes #x82 rlen)]
                       [(<= rlen 65535) (bytes-append (bytes #x82 126) (integer->integer-bytes rlen 2 #f #t))]
                       [else (bytes-append (bytes #x82 127) (integer->integer-bytes rlen 8 #f #t))]))
               (write-bytes rhdr s-out)
               (write-bytes resp s-out)
               (flush-output s-out))
             (lp))))))
    (values ws rpc-cnt saw-319? (lambda () (close-output-port c-out) (close-input-port c-in) (thread-wait th))))

  ;; L29-P0-1a (`#02/#08/#26/#32/#35` Terran barracks #2/#3): After 1 complete `5x3`+`2.0t` miss on
  ;; `barracks #2` (`cur-rax-count = 1`), even after a Supply Depot finishes (changing `cur-struct-sig`
  ;; and wiping `SC2-TERRAN-5X3-MISS-CACHE`!), `rax2-fast-3x3?` persists (`streak >= 2`), sends ZERO `319`
  ;; queries, and IMMEDIATELY places `barracks #2` via `0.5t` pure `3x3` at Natural `(68.5, 30.5)`!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-clear! SC2-TERRAN-5X3-MISS-CACHE)
  (hash-clear! SC2-TERRAN-5X3-MISS-STREAK)
  (define allow-r2-321? (box #f))
  (let-values ([(ws rpc-cnt saw-319? cleanup!)
                (l29-start-mock-ws
                 (lambda (ab px py)
                   (if (and (unbox allow-r2-321?) (= ab 321) (<= (l29-dist px py 68.5 30.5) 0.1)) 1 2)))])
    (define cc-m (mk-l29-u 9901 18 1 28.5 28.5 #:hp 1500.0 #:rad 2.75))
    (define cc-n (mk-l29-u 9902 18 1 64.5 30.5 #:hp 1500.0 #:rad 2.75))
    (define rax1 (mk-l29-u 9903 21 1 34.5 28.5 #:hp 1000.0 #:rad 1.5))
    (define dep1 (mk-l29-u 9904 19 1 24.0 34.0 #:hp 400.0 #:rad 1.0))
    (define scv1 (mk-l29-u 9905 45 1 63.0 29.0 #:hp 45.0 #:rad 0.375))
    (define nat-mins (mk-l29-mins 9910))
    (define g29-t
      (sc2-game-info "L29TerranRax2Map" "" '() '(128 128) '(4 4 124 124)
                     (list (sc2-point2d 100.0 100.0)) w3-full-grid #f w3-full-grid))
    ;; Tick 1 (`4000`): complete `5x3` + `2.0t` `unq-3x3` miss -> streak >= 2
    (translate-bot-actions->sc2-raw-commands
     '((build barracks 32.0 30.0))
     (make-test-obs 4000 450 50 (append (list cc-m rax1 scv1) nat-mins))
     #:ws-conn ws #:game-info g29-t)
    ;; Tick 2 (`4020`): Depot + Natural CC change `cur-struct-sig` -> wipes `SC2-TERRAN-5X3-MISS-CACHE`,
    ;; yet `rax2-fast-3x3?` skips `319` and places `0.5t` pure `3x3` at `(68.5, 30.5)` in 1 step!
    (set-box! saw-319? #f)
    (set-box! rpc-cnt 0)
    (set-box! allow-r2-321? #t)
    (define r2-cmds
      (translate-bot-actions->sc2-raw-commands
       '((build barracks 32.0 30.0))
       (make-test-obs 4020 450 50 (append (list cc-m cc-n rax1 dep1 scv1) nat-mins))
       #:ws-conn ws #:game-info g29-t))
    (define r2-cmd
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 321))) r2-cmds))
    (define r2-pt (and r2-cmd (sc2-raw-unit-command-target-pos r2-cmd)))
    (check-true "l29-p0-1a-barracks2-persists-fast-3x3-across-depot-completion-and-places-05t"
                (and (not (unbox saw-319?))
                     (= (unbox rpc-cnt) 2)
                     (sc2-point2d? r2-pt)
                     (<= (l29-dist (sc2-point2d-x r2-pt) (sc2-point2d-y r2-pt) 68.5 30.5) 0.1)))
    (cleanup!))
  (hash-clear! SC2-TERRAN-5X3-MISS-STREAK)

  ;; L29-P0-1b (`#52 who` DT): Cloaked Dark Templar attacking Natural mineral line `(64.5, 30.5)`.
  ;; Even when Brain passes Main `(28.5, 28.5)` and DT stands near Natural Pylon `(66, 34)`,
  ;; `emerg-cloak-cannon?` redirects to Natural mineral line and places `photon-cannon` (`887`) via
  ;; `0.5t` tight spacing (`3.45` pad clearance) at `(68.0, 31.0)` in the SAME step!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (set-box! SC2-PROTOSS-POWER-PLACEMENT-FAIL-LOOP -9999)
  (let-values ([(ws rpc-cnt _saw319 cleanup!)
                (l29-start-mock-ws
                 (lambda (ab px py)
                   (if (and (= ab 887) (<= (l29-dist px py 68.0 31.0) 0.1)) 1 2)))])
    (define nx-m (mk-l29-u 9921 59 1 28.5 28.5 #:hp 1000.0 #:shield 1000.0 #:rad 2.75))
    (define nx-n (mk-l29-u 9922 59 1 64.5 30.5 #:hp 1000.0 #:shield 1000.0 #:rad 2.75))
    (define py-m (mk-l29-u 9923 60 1 30.0 34.0 #:hp 200.0 #:shield 200.0 #:rad 1.0))
    (define py-n (mk-l29-u 9924 60 1 66.0 34.0 #:hp 200.0 #:shield 200.0 #:rad 1.0))
    (define prb1 (mk-l29-u 9925 84 1 63.0 29.0 #:hp 20.0 #:shield 20.0 #:rad 0.375))
    (define dt-n (mk-l29-u 9926 76 4 66.0 32.5 #:hp 40.0 #:shield 80.0 #:rad 0.375 #:cloak 1))
    (define nat-mins (mk-l29-mins 9930))
    (define g29-p
      (sc2-game-info "L29ProtoCloakMap" "" '() '(128 128) '(4 4 124 124)
                     (list (sc2-point2d 100.0 100.0)) w3-full-grid #f w3-full-grid))
    (define obs-pc
      (sc2-observation 4100 (sc2-player-common 1 400 100 60 36 10 26 0 0 0 0)
                       (append (list nx-m nx-n py-m py-n prb1 dt-n) nat-mins)
                       '()
                       (list (sc2-power-source (sc2-point3d 30.0 34.0 8.0) 6.5 9923)
                             (sc2-power-source (sc2-point3d 66.0 34.0 8.0) 6.5 9924))
                       #f '() '() '() '() '() '()))
    (define pc-cmds
      (translate-bot-actions->sc2-raw-commands '((build photon-cannon 28.5 28.5))
                                               obs-pc #:ws-conn ws #:game-info g29-p))
    (define pc-cmd
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 887))) pc-cmds))
    (define pc-pt (and pc-cmd (sc2-raw-unit-command-target-pos pc-cmd)))
    (check-true "l29-p0-1b-cloak-photon-cannon-places-05t-at-dt-attacked-natural-mineral-line"
                (and (= (unbox rpc-cnt) 2)
                     (sc2-point2d? pc-pt)
                     (<= (l29-dist (sc2-point2d-x pc-pt) (sc2-point2d-y pc-pt) 68.0 31.0) 0.1)
                     (= (unbox SC2-PROTOSS-POWER-PLACEMENT-FAIL-LOOP) -9999)))
    (cleanup!))

  ;; L29-P0-1c (`#54 who` Banshee vs Zerg): Cloaked Banshee attacking Natural Hatchery `(64.5, 30.5)`.
  ;; `emerg-cloak-spore?` keeps Spore Crawler anchored AT the attacked Natural mineral line (never
  ;; redirecting to unattacked Main!) and uses `0.5t` tight spacing (`dist = 2.1 < 2.5` from in-transit
  ;; Drone build at `(68.0, 32.1)`) to place `spore-crawler` (`1167`) at `(68.0, 30.0)` in the SAME step!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (let-values ([(ws rpc-cnt _saw319 cleanup!)
                (l29-start-mock-ws
                 (lambda (ab px py)
                   (if (and (= ab 1167) (<= (l29-dist px py 68.0 30.0) 0.1)) 1 2)))])
    (define ht-m (mk-l29-u 9941 86 1 28.5 28.5 #:hp 1500.0 #:rad 2.75))
    (define ht-n (mk-l29-u 9942 86 1 64.5 30.5 #:hp 1500.0 #:rad 2.75))
    (define drn-busy
      (mk-l29-u 9943 104 1 67.0 32.0 #:hp 40.0 #:rad 0.375
                #:orders (list (sc2-unit-order 1166 (sc2-point3d 68.0 32.1 8.0) 0 0.0))))
    (define drn1 (mk-l29-u 9944 104 1 63.0 29.0 #:hp 40.0 #:rad 0.375))
    (define ban-n (mk-l29-u 9945 55 4 67.5 30.5 #:hp 140.0 #:rad 0.75 #:cloak 1 #:flying? #t))
    (define nat-mins (mk-l29-mins 9950))
    (define g29-z
      (sc2-game-info "L29ZergCloakMap" "" '() '(128 128) '(4 4 124 124)
                     (list (sc2-point2d 100.0 100.0)) w3-full-grid #f w3-full-grid))
    (define sp-cmds
      (translate-bot-actions->sc2-raw-commands
       '((build spore-crawler 28.5 28.5))
       (make-test-obs 4200 300 50 (append (list ht-m ht-n drn-busy drn1 ban-n) nat-mins))
       #:ws-conn ws #:game-info g29-z))
    (define sp-cmd
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1167))) sp-cmds))
    (define sp-pt (and sp-cmd (sc2-raw-unit-command-target-pos sp-cmd)))
    (check-true "l29-p0-1c-cloak-spore-crawler-places-05t-at-banshee-attacked-natural-mineral-line"
                (and (= (unbox rpc-cnt) 2)
                     (sc2-point2d? sp-pt)
                     (<= (l29-dist (sc2-point2d-x sp-pt) (sc2-point2d-y sp-pt) 68.0 30.0) 0.1)))
    (cleanup!))

  ;; L29-P0-1d (`#54 who` Banshee vs Terran): Cloaked Banshee attacking Natural CC `(64.5, 30.5)`.
  ;; `emerg-cloak-turret?` redirects from Main `(28.5, 28.5)` to Natural mineral line and places
  ;; `missile-turret` (`323`) via `0.5t` tight spacing (`3.45` pad clearance) at `(68.0, 30.0)` in 1 step!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (let-values ([(ws rpc-cnt _saw319 cleanup!)
                (l29-start-mock-ws
                 (lambda (ab px py)
                   (if (and (= ab 323) (<= (l29-dist px py 68.0 30.0) 0.1)) 1 2)))])
    (define cc-m (mk-l29-u 9961 18 1 28.5 28.5 #:hp 1500.0 #:rad 2.75))
    (define cc-n (mk-l29-u 9962 18 1 64.5 30.5 #:hp 1500.0 #:rad 2.75))
    (define scv1 (mk-l29-u 9963 45 1 63.0 29.0 #:hp 45.0 #:rad 0.375))
    (define ban-n (mk-l29-u 9964 55 4 67.5 30.5 #:hp 140.0 #:rad 0.75 #:cloak 1 #:flying? #t))
    (define nat-mins (mk-l29-mins 9970))
    (define g29-mt
      (sc2-game-info "L29TerranCloakMap" "" '() '(128 128) '(4 4 124 124)
                     (list (sc2-point2d 100.0 100.0)) w3-full-grid #f w3-full-grid))
    (define mt-cmds
      (translate-bot-actions->sc2-raw-commands
       '((build missile-turret 28.5 28.5))
       (make-test-obs 4300 300 50 (append (list cc-m cc-n scv1 ban-n) nat-mins))
       #:ws-conn ws #:game-info g29-mt))
    (define mt-cmd
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 323))) mt-cmds))
    (define mt-pt (and mt-cmd (sc2-raw-unit-command-target-pos mt-cmd)))
    (check-true "l29-p0-1d-cloak-missile-turret-places-05t-at-banshee-attacked-natural-mineral-line"
                (and (= (unbox rpc-cnt) 2)
                     (sc2-point2d? mt-pt)
                     (<= (l29-dist (sc2-point2d-x mt-pt) (sc2-point2d-y mt-pt) 68.0 30.0) 0.1)))
    (cleanup!)))

(printf "[Loop 30] Testing L30-P0-1 Terran factory/starport 0.5t spillover (#11/#26), Protoss multi-bldg budget=3 + sticky power-fail (#36/#40), & mined-out gas evac (#38)...\n")
(let ()
  (define (l30-dist x1 y1 x2 y2)
    (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))
  (define (mk-l30-u tag utype alliance x y
                    #:hp [hp 100.0] #:shield [sh 0.0] #:rad [rad 1.0]
                    #:display [disp 1] #:buffs [buffs '()] #:orders [ords '()]
                    #:assigned [asgn 0] #:ideal [idl 0] #:mins [mins 0] #:vesp [vesp 0])
    (sc2-unit disp alliance tag utype (if (= alliance 1) 1 (if (= alliance 3) 0 2))
              (sc2-point3d x y 8.0) 0.0 rad 1.0 0 #f #f #f
              hp hp sh sh 0.0 0.0 mins vesp #f #f #f #t #f
              ords 0 buffs asgn idl 0.0 0 0 0 0 '() 0 0))
  (define (mk-l30-mins base-tag)
    (for/list ([y (in-list '(27.5 29.5 31.5 33.5))] [i (in-naturals 0)])
      (mk-l30-u (+ base-tag i) 341 3 71.0 y #:hp 1000.0 #:rad 1.0 #:mins 1500)))
  (define (l30-start-mock-ws decide-fn)
    (define-values (c-in s-out) (make-pipe))
    (define-values (s-in c-out) (make-pipe))
    (define ws (sc2-ws-conn "127.0.0.1" 59930 "/sc2api" c-in c-out #f 1))
    (define rpc-cnt (box 0))
    (define saw-319? (box #f))
    (define th
      (thread
       (lambda ()
         (let lp ()
           (define b0 (read-byte s-in))
           (unless (eof-object? b0)
             (define b1 (read-byte s-in))
             (define masked? (not (zero? (bitwise-and b1 #x80))))
             (define len0 (bitwise-and b1 #x7F))
             (define plen
               (cond [(< len0 126) len0]
                     [(= len0 126) (integer-bytes->integer (read-bytes 2 s-in) #f #t)]
                     [else (integer-bytes->integer (read-bytes 8 s-in) #f #t)]))
             (define mkey (if masked? (read-bytes 4 s-in) #f))
             (define raw (read-bytes plen s-in))
             (define payload
               (if masked?
                   (let ([out (make-bytes plen)])
                     (for ([i (in-range plen)])
                       (bytes-set! out i (bitwise-xor (bytes-ref raw i) (bytes-ref mkey (modulo i 4)))))
                     out)
                   raw))
             (define req-f (decode-protobuf-message payload))
             (define req-id-p (assoc 97 req-f))
             (define id-b (if req-id-p (encode-uint32 97 (third req-id-p)) #""))
             (define q-p (assoc 14 req-f))
             (when q-p
               (set-box! rpc-cnt (add1 (unbox rpc-cnt)))
               (define qf (decode-protobuf-message (third q-p)))
               (define p-items (filter (lambda (e) (= (first e) 3)) qf))
               (define res-b
                 (apply bytes-append
                        (for/list ([it (in-list p-items)])
                          (define itf (decode-protobuf-message (third it)))
                          (define ab (let ([p (assoc 1 itf)]) (if p (third p) 0)))
                          (when (= ab 319) (set-box! saw-319? #t))
                          (define tp-e (assoc 2 itf))
                          (define-values (px py)
                            (if tp-e
                                (let ([ptf (decode-protobuf-message (third tp-e))])
                                  (values (let ([xp (assoc 1 ptf)])
                                            (if (and xp (bytes? (third xp)))
                                                (floating-point-bytes->real (third xp) #f)
                                                0.0))
                                          (let ([yp (assoc 2 ptf)])
                                            (if (and yp (bytes? (third yp)))
                                                (floating-point-bytes->real (third yp) #f)
                                                0.0))))
                                (values 0.0 0.0)))
                          (encode-submessage-field 3 (encode-int32 1 (decide-fn ab px py))))))
               (define resp (bytes-append (encode-submessage-field 14 res-b) id-b (encode-int32 99 3)))
               (define rlen (bytes-length resp))
               (define rhdr
                 (cond [(< rlen 126) (bytes #x82 rlen)]
                       [(<= rlen 65535) (bytes-append (bytes #x82 126) (integer->integer-bytes rlen 2 #f #t))]
                       [else (bytes-append (bytes #x82 127) (integer->integer-bytes rlen 8 #f #t))]))
               (write-bytes rhdr s-out)
               (write-bytes resp s-out)
               (flush-output s-out))
             (lp))))))
    (values ws rpc-cnt saw-319? (lambda () (close-output-port c-out) (close-input-port c-in) (thread-wait th))))

  ;; L30-P0-1a (`#11` Terran factory #2+): After 1 complete `5x3`+`2.0t` miss on `factory #2` (`count = 1`),
  ;; even after a Supply Depot finishes (wiping `SC2-TERRAN-5X3-MISS-CACHE`), `terran-prod-fast-3x3?`
  ;; persists, skips `319`, and spills over via `0.5t` pure `3x3` to safe Natural `(68.5, 30.5)` in 1 step!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-clear! SC2-TERRAN-5X3-MISS-CACHE)
  (hash-clear! SC2-TERRAN-5X3-MISS-STREAK)
  (define allow-f2-328? (box #f))
  (let-values ([(ws rpc-cnt saw-319? cleanup!)
                (l30-start-mock-ws
                 (lambda (ab px py)
                   (if (and (unbox allow-f2-328?) (= ab 328) (<= (l30-dist px py 68.5 30.5) 0.1)) 1 2)))])
    (define cc-m (mk-l30-u 10001 18 1 28.5 28.5 #:hp 1500.0 #:rad 2.75))
    (define cc-n (mk-l30-u 10002 18 1 64.5 30.5 #:hp 1500.0 #:rad 2.75))
    (define fac1 (mk-l30-u 10003 27 1 34.5 28.5 #:hp 1250.0 #:rad 1.5))
    (define dep1 (mk-l30-u 10004 19 1 24.0 34.0 #:hp 400.0 #:rad 1.0))
    (define scv1 (mk-l30-u 10005 45 1 63.0 29.0 #:hp 45.0 #:rad 0.375))
    (define nat-mins (mk-l30-mins 10010))
    (define g30-f2
      (sc2-game-info "L30Factory2Map" "" '() '(128 128) '(4 4 124 124)
                     (list (sc2-point2d 100.0 100.0)) w3-full-grid #f w3-full-grid))
    (translate-bot-actions->sc2-raw-commands
     '((build factory 32.0 30.0))
     (make-test-obs 4500 500 250 (append (list cc-m fac1 scv1) nat-mins))
     #:ws-conn ws #:game-info g30-f2)
    (set-box! saw-319? #f)
    (set-box! rpc-cnt 0)
    (set-box! allow-f2-328? #t)
    (define f2-cmds
      (translate-bot-actions->sc2-raw-commands
       '((build factory 32.0 30.0))
       (make-test-obs 4520 500 250 (append (list cc-m cc-n fac1 dep1 scv1) nat-mins))
       #:ws-conn ws #:game-info g30-f2))
    (define f2-cmd
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 328))) f2-cmds))
    (define f2-pt (and f2-cmd (sc2-raw-unit-command-target-pos f2-cmd)))
    (check-true "l30-p0-1a-factory2-persists-fast-3x3-across-depot-and-spills-05t-to-natural"
                (and (not (unbox saw-319?))
                     (= (unbox rpc-cnt) 2)
                     (sc2-point2d? f2-pt)
                     (<= (l30-dist (sc2-point2d-x f2-pt) (sc2-point2d-y f2-pt) 68.5 30.5) 0.1)))
    (cleanup!))
  (hash-clear! SC2-TERRAN-5X3-MISS-STREAK)

  ;; L30-P0-1b (`#11/#26` Terran starport #1 after >= 3 misses): Even with `0` existing Starports,
  ;; once `SC2-TERRAN-5X3-MISS-STREAK['starport] >= 3`, skips `319` and spills over via `0.5t` pure
  ;; `3x3` across ALL safe completed TownHalls (`(68.5, 30.5)`) in 1 step!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-clear! SC2-TERRAN-5X3-MISS-CACHE)
  (hash-set! SC2-TERRAN-5X3-MISS-STREAK 'starport 3)
  (let-values ([(ws rpc-cnt saw-319? cleanup!)
                (l30-start-mock-ws
                 (lambda (ab px py)
                   (if (and (= ab 329) (<= (l30-dist px py 68.5 30.5) 0.1)) 1 2)))])
    (define cc-m (mk-l30-u 10021 18 1 28.5 28.5 #:hp 1500.0 #:rad 2.75))
    (define cc-n (mk-l30-u 10022 18 1 64.5 30.5 #:hp 1500.0 #:rad 2.75))
    (define scv1 (mk-l30-u 10023 45 1 63.0 29.0 #:hp 45.0 #:rad 0.375))
    (define nat-mins (mk-l30-mins 10025))
    (define g30-sp1
      (sc2-game-info "L30Starport1Map" "" '() '(128 128) '(4 4 124 124)
                     (list (sc2-point2d 100.0 100.0)) w3-full-grid #f w3-full-grid))
    (define sp1-cmds
      (translate-bot-actions->sc2-raw-commands
       '((build starport 32.0 30.0))
       (make-test-obs 4600 500 250 (append (list cc-m cc-n scv1) nat-mins))
       #:ws-conn ws #:game-info g30-sp1))
    (define sp1-cmd
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 329))) sp1-cmds))
    (define sp1-pt (and sp1-cmd (sc2-raw-unit-command-target-pos sp1-cmd)))
    (check-true "l30-p0-1b-starport1-after-3-misses-spills-05t-3x3-across-safe-ths"
                (and (not (unbox saw-319?))
                     (= (unbox rpc-cnt) 2)
                     (sc2-point2d? sp1-pt)
                     (<= (l30-dist (sc2-point2d-x sp1-pt) (sc2-point2d-y sp1-pt) 68.5 30.5) 0.1)))
    (cleanup!))
  (hash-clear! SC2-TERRAN-5X3-MISS-STREAK)

  ;; L30-P0-1c (`#36/#40` Protoss multi-bldg budget = 3): When `pylon` AND `gateway` queue in the
  ;; same step, `step-placement-rpc-budget = 3` so `pylon` takes RPC #1 (`3 -> 2`) and `gateway`
  ;; STILL gets both `2.0t` (RPC #2) AND `0.5t` tight fallback (RPC #3) without budget deferral!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (set-box! SC2-PROTOSS-POWER-PLACEMENT-FAIL-LOOP -9999)
  (let-values ([(ws rpc-cnt _saw319 cleanup!)
                (l30-start-mock-ws
                 (lambda (ab px py)
                   (cond
                     [(= ab 881) 1]
                     [(and (= ab 883) (<= (l30-dist px py 33.5 33.5) 0.1)) 1]
                     [else 2])))])
    (define nx-m (mk-l30-u 10031 59 1 26.5 26.5 #:hp 1000.0 #:shield 1000.0 #:rad 2.75))
    (define py-m (mk-l30-u 10032 60 1 30.0 34.0 #:hp 200.0 #:shield 200.0 #:rad 1.0))
    (define prb-busy
      (mk-l30-u 10033 84 1 31.0 33.0 #:hp 20.0 #:shield 20.0 #:rad 0.375
                #:orders (list (sc2-unit-order 881 (sc2-point3d 31.5 34.0 8.0) 0 0.0))))
    (define prb-a (mk-l30-u 10034 84 1 29.0 32.0 #:hp 20.0 #:shield 20.0 #:rad 0.375))
    (define prb-b (mk-l30-u 10035 84 1 28.0 32.0 #:hp 20.0 #:shield 20.0 #:rad 0.375))
    (define obs-mb
      (sc2-observation 4700 (sc2-player-common 1 600 100 60 36 10 26 0 0 0 0)
                       (list nx-m py-m prb-busy prb-a prb-b) '()
                       (list (sc2-power-source (sc2-point3d 30.0 34.0 8.0) 6.5 10032))
                       #f '() '() '() '() '() '()))
    (define mb-cmds
      (translate-bot-actions->sc2-raw-commands
       '((build pylon 24.0 24.0) (build gateway 30.0 34.0))
       obs-mb #:ws-conn ws #:game-info w3-ginfo))
    (define py-cmd (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 881))) mb-cmds))
    (define gw-cmd (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 883))) mb-cmds))
    (define gw-pt (and gw-cmd (sc2-raw-unit-command-target-pos gw-cmd)))
    (check-true "l30-p0-1c-protoss-multi-bldg-budget-3-places-gateway-tight-05-after-pylon"
                (and (= (unbox rpc-cnt) 3)
                     (sc2-raw-unit-command? py-cmd)
                     (sc2-point2d? gw-pt)
                     (<= (l30-dist (sc2-point2d-x gw-pt) (sc2-point2d-y gw-pt) 33.5 33.5) 0.1)))
    (cleanup!))

  ;; L30-P0-1d (`#40` sticky power-fail): When `gateway` fails both `2.0t` & `0.5t` (setting
  ;; `SC2-PROTOSS-POWER-PLACEMENT-FAIL-LOOP = 4800`) and `shield-battery` (`2x2`) succeeds in the
  ;; same step, `SC2-PROTOSS-POWER-PLACEMENT-FAIL-LOOP` MUST remain `4800` (not cleared to `-9999`)!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (set-box! SC2-PROTOSS-POWER-PLACEMENT-FAIL-LOOP -9999)
  (let-values ([(ws rpc-cnt _saw319 cleanup!)
                (l30-start-mock-ws (lambda (ab _px _py) (if (= ab 895) 1 2)))])
    (define nx-m  (mk-l30-u 10041 59 1 26.5 26.5 #:hp 1000.0 #:shield 1000.0 #:rad 2.75))
    (define py-m  (mk-l30-u 10042 60 1 32.0 32.0 #:hp 200.0 #:shield 200.0 #:rad 1.0))
    (define prb-a (mk-l30-u 10043 84 1 30.0 31.0 #:hp 20.0 #:shield 20.0 #:rad 0.375))
    (define prb-b (mk-l30-u 10044 84 1 31.0 31.0 #:hp 20.0 #:shield 20.0 #:rad 0.375))
    (define obs-pf
      (sc2-observation 4800 (sc2-player-common 1 600 100 60 36 10 26 0 0 0 0)
                       (list nx-m py-m prb-a prb-b) '()
                       (list (sc2-power-source (sc2-point3d 32.0 32.0 8.0) 6.5 10042))
                       #f '() '() '() '() '() '()))
    (define pf-cmds
      (translate-bot-actions->sc2-raw-commands
       '((build gateway 32.0 32.0) (build shield-battery 32.0 32.0))
       obs-pf #:ws-conn ws #:game-info w3-ginfo))
    (define sb-cmd (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 895))) pf-cmds))
    (check-true "l30-p0-1d-protoss-power-fail-loop-stays-sticky-when-battery-succeeds-after-gateway-fails"
                (and (= (unbox rpc-cnt) 3)
                     (sc2-raw-unit-command? sb-cmd)
                     (= (unbox SC2-PROTOSS-POWER-PLACEMENT-FAIL-LOOP) 4800)))
    (cleanup!))

  ;; L30-P0-1e (`#38` 2,275G/0M mined-out base gas evac): Owned CC `(28.5, 28.5)` has ZERO local
  ;; minerals (`owned-base-minerals = '()`), `cur-gas = 900`, `cur-min = 50`. Refinery `10052` has
  ;; 2/3 SCVs (1 non-carrying + 1 carrying gas `buff 273`) + 1 idle SCV. Two fog-of-war snapshot
  ;; map minerals exist (`display-type = 2`): safe `10061` at `(64, 30)` and enemy-camped `10062`
  ;; at `(45, 30)` (with enemy Tank at `(46, 30)`). MUST NOT resaturate Refinery, and MUST evacuate
  ;; BOTH gas SCVs + idle SCV onto safe map mineral patch `10061` (NEVER `10062`)!
  (set-box! SC2-GAS-PULL-HYSTERESIS-LATCH #f)
  (define cc-mo (mk-l30-u 10051 18 1 28.5 28.5 #:hp 1500.0 #:rad 2.75 #:assigned 0 #:ideal 0))
  (define ref-mo (mk-l30-u 10052 20 1 25.0 23.0 #:hp 500.0 #:rad 1.5 #:assigned 2 #:ideal 3 #:vesp 1800))
  (define scv-g1 (mk-l30-u 10053 45 1 25.5 24.0 #:hp 45.0 #:rad 0.375
                           #:orders (list (sc2-unit-order 295 #f 10052 0.0))))
  (define scv-g2 (mk-l30-u 10054 45 1 26.0 24.5 #:hp 45.0 #:rad 0.375
                           #:buffs '(273) #:orders (list (sc2-unit-order 295 #f 10052 0.0))))
  (define scv-id (mk-l30-u 10055 45 1 29.0 26.0 #:hp 45.0 #:rad 0.375))
  (define map-m-safe (mk-l30-u 10061 341 3 64.0 30.0 #:hp 1000.0 #:rad 1.0 #:display 2 #:mins 0))
  (define map-m-camp (mk-l30-u 10062 341 3 45.0 30.0 #:hp 1000.0 #:rad 1.0 #:display 2 #:mins 0))
  (define enemy-tnk  (mk-l30-u 10063 32  4 46.0 30.0 #:hp 175.0 #:rad 0.875))
  (define mo-cmds
    (saturate-workers-and-gas-commands
     (sc2-observation 18000 (sc2-player-common 1 50 900 100 40 20 20 0 0 0 0)
                      (list cc-mo ref-mo scv-g1 scv-g2 scv-id map-m-safe map-m-camp enemy-tnk)
                      '() '() #f '() '() '() '() '() '())))
  (define mo-cmds-by-w
    (for/hasheqv ([c (in-list mo-cmds)] #:when (sc2-raw-unit-command? c))
      (values (first (sc2-raw-unit-command-unit-tags c)) c)))
  (define (mo-sent-to-safe-fog? wtag)
    (define c (hash-ref mo-cmds-by-w wtag #f))
    (and (sc2-raw-unit-command? c)
         (= (sc2-raw-unit-command-ability-id c) 16)
         (sc2-point2d? (sc2-raw-unit-command-target-pos c))
         (<= (l30-dist (sc2-point2d-x (sc2-raw-unit-command-target-pos c))
                       (sc2-point2d-y (sc2-raw-unit-command-target-pos c))
                       64.0 30.0)
             0.1)))
  (check-true "l30-p0-1e-mined-out-base-evacuates-gas-to-nearest-safe-map-minerals-and-blocks-resat"
              (and (not (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                                (memv (sc2-raw-unit-command-target-unit-tag c) '(10052 10062))))
                               mo-cmds))
                   (mo-sent-to-safe-fog? 10053)
                   (mo-sent-to-safe-fog? 10054)
                   (mo-sent-to-safe-fog? 10055))))

;; =============================================================================
;; Loop 31 (`L31-P0-1`): Zero GasZeroFreeze + Terran step-placement-rpc-budget=3
;; =============================================================================
(printf "[Loop 31] Testing L31-P0-1 depleted-gas filter, 300f zero-gas-freeze rescue + 0b exemption, & Terran budget=3 spillover...\n")
(let ()
  (define (mk-l31-u tag utype alliance x y
                    #:hp [hp 100.0] #:hp-max [hp-max hp] #:shield [sh 0.0] #:rad [rad 1.0]
                    #:display [disp 1] #:orders [ords '()] #:buffs [buffs '()]
                    #:flying? [flying? #f]
                    #:mins [mins 0] #:vesp [vesp 0]
                    #:assigned [asgn 0] #:ideal [idl 0])
    (sc2-unit disp alliance tag utype (if (= alliance 1) 1 (if (= alliance 3) 0 2))
              (sc2-point3d x y 8.0) 0.0 rad 1.0 0 flying? #f #f
              hp hp-max sh sh 0.0 0.0 mins vesp #f #f #f #t #f
              ords 0 buffs asgn idl 0.0 0 0 0 0 '() 0 0))

  (define (l31-dist x1 y1 x2 y2)
    (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))

  (define (l31-start-mock-ws decide-fn)
    (define-values (c-in s-out) (make-pipe))
    (define-values (s-in c-out) (make-pipe))
    (define ws (sc2-ws-conn "127.0.0.1" 59931 "/sc2api" c-in c-out #f 1))
    (define rpc-cnt (box 0))
    (define th
      (thread
       (lambda ()
         (let lp ()
           (define b0 (read-byte s-in))
           (unless (eof-object? b0)
             (define b1 (read-byte s-in))
             (define masked? (not (zero? (bitwise-and b1 #x80))))
             (define len0 (bitwise-and b1 #x7F))
             (define plen
               (cond [(< len0 126) len0]
                     [(= len0 126) (integer-bytes->integer (read-bytes 2 s-in) #f #t)]
                     [else (integer-bytes->integer (read-bytes 8 s-in) #f #t)]))
             (define mkey (if masked? (read-bytes 4 s-in) #f))
             (define raw (read-bytes plen s-in))
             (define payload
               (if masked?
                   (let ([out (make-bytes plen)])
                     (for ([i (in-range plen)])
                       (bytes-set! out i (bitwise-xor (bytes-ref raw i) (bytes-ref mkey (modulo i 4)))))
                     out)
                   raw))
             (define req-f (decode-protobuf-message payload))
             (define id-p (assoc 97 req-f))
             (define id-b (if id-p (encode-uint32 97 (third id-p)) #""))
             (define q-p (assoc 14 req-f))
             (when q-p
               (set-box! rpc-cnt (add1 (unbox rpc-cnt)))
               (define rn (unbox rpc-cnt))
               (define qf (decode-protobuf-message (third q-p)))
               (define p-items (filter (lambda (e) (= (first e) 3)) qf))
               (define res-b
                 (apply bytes-append
                        (for/list ([it (in-list p-items)])
                          (define itf (decode-protobuf-message (third it)))
                          (define ab (let ([p (assoc 1 itf)]) (if p (third p) 0)))
                          (define tp-e (assoc 2 itf))
                          (define-values (px py)
                            (if tp-e
                                (let ([ptf (decode-protobuf-message (third tp-e))])
                                  (values (let ([xp (assoc 1 ptf)])
                                            (if (and xp (bytes? (third xp)))
                                                (floating-point-bytes->real (third xp) #f)
                                                0.0))
                                          (let ([yp (assoc 2 ptf)])
                                            (if (and yp (bytes? (third yp)))
                                                (floating-point-bytes->real (third yp) #f)
                                                0.0))))
                                (values 0.0 0.0)))
                          (encode-submessage-field 3 (encode-int32 1 (decide-fn ab px py rn))))))
               (define resp (bytes-append (encode-submessage-field 14 res-b) id-b (encode-int32 99 3)))
               (define rlen (bytes-length resp))
               (define rhdr
                 (cond [(< rlen 126) (bytes #x82 rlen)]
                       [(<= rlen 65535) (bytes-append (bytes #x82 126) (integer->integer-bytes rlen 2 #f #t))]
                       [else (bytes-append (bytes #x82 127) (integer->integer-bytes rlen 8 #f #t))]))
               (write-bytes rhdr s-out)
               (write-bytes resp s-out)
               (flush-output s-out))
             (lp))))))
    (values ws rpc-cnt (lambda () (close-output-port c-out) (close-input-port c-in) (thread-wait th))))

  ;; L31-P0-1a: Strictly filter depleted `vespene-contents == 0` geyser out of `ready-gas-bldgs`
  ;; (and into `depleted-gas-tags`) whenever ANY live geyser reports `vespene-contents > 0`, even
  ;; if SC2 transiently leaves `ideal-harvesters = 3` on the depleted Assimilator!
  (set-box! SC2-GAS-PULL-HYSTERESIS-LATCH #f)
  (set-box! SC2-ZERO-GAS-STREAK-START-LOOP #f)
  (set-box! SC2-ZERO-GAS-LAST-VESPENE #f)
  (set-box! SC2-ZERO-GAS-RESCUE-LATCH #f)
  (define nx-1a (mk-l31-u 11001 59 1 28.5 28.5 #:hp 1000.0 #:shield 1000.0 #:rad 2.75 #:assigned 10 #:ideal 16))
  (define as-dep (mk-l31-u 11002 61 1 24.0 23.0 #:hp 450.0 #:shield 450.0 #:rad 1.5 #:assigned 1 #:ideal 3 #:vesp 0))
  (define as-liv (mk-l31-u 11003 61 1 33.0 23.0 #:hp 450.0 #:shield 450.0 #:rad 1.5 #:assigned 0 #:ideal 3 #:vesp 1800))
  (define m-1a-1 (mk-l31-u 11004 341 3 23.0 31.0 #:hp 1000.0 #:rad 1.0 #:mins 1200))
  (define m-1a-2 (mk-l31-u 11005 341 3 25.0 32.5 #:hp 1000.0 #:rad 1.0 #:mins 1200))
  (define prb-on-dep
    (mk-l31-u 11010 84 1 24.5 24.0 #:hp 20.0 #:shield 20.0 #:rad 0.375
              #:orders (list (sc2-unit-order 298 #f 11002 0.0))))
  (define prbs-1a
    (cons prb-on-dep
          (for/list ([i (in-range 1 12)])
            (mk-l31-u (+ 11010 i) 84 1 (+ 26.0 (* 0.4 i)) 30.5 #:hp 20.0 #:shield 20.0 #:rad 0.375
                      #:orders (list (sc2-unit-order 298 #f 11004 0.0))))))
  (define cmds-1a
    (saturate-workers-and-gas-commands
     (sc2-observation 18500 (sc2-player-common 1 300 40 60 30 6 12 0 0 0 0)
                      (append (list nx-1a as-dep as-liv m-1a-1 m-1a-2) prbs-1a)
                      '() '() #f '() '() '() '() '() '())))
  (define targets-1a
    (for/list ([c (in-list cmds-1a)] #:when (sc2-raw-unit-command? c))
      (cons (first (sc2-raw-unit-command-unit-tags c))
            (sc2-raw-unit-command-target-unit-tag c))))
  (check-true "l31-p0-1a-depleted-vespene-zero-geyser-filtered-even-with-ideal-harvesters-3"
              (and (not (ormap (lambda (p) (= (cdr p) 11002)) targets-1a))
                   (let ([ev (assoc 11010 targets-1a)])
                     (and ev (memv (cdr ev) '(11004 11005))))
                   (ormap (lambda (p) (= (cdr p) 11003)) targets-1a)))

  ;; L31-P0-1b: Zero-gas-freeze rescue after >= 300f of zero gas gain (`cur-gas < 150`, `workers >= 16`,
  ;; live `ready-gas-bldgs` non-empty): force-assigns 3 workers directly to the lowest-threat non-lethal
  ;; live geyser (beating a higher-threat geyser) AND keeps them exempt from non-lethal peripheral/air
  ;; `0b` evacuation as gas resumes (`21 -> 25`) until `cur-gas >= 150`!
  (set-box! SC2-GAS-PULL-HYSTERESIS-LATCH #f)
  (set-box! SC2-ZERO-GAS-STREAK-START-LOOP #f)
  (set-box! SC2-ZERO-GAS-LAST-VESPENE #f)
  (set-box! SC2-ZERO-GAS-RESCUE-LATCH #f)
  ;; Offline Main Nexus (`hp 300/1000` + peripheral Stalker at `13t` -> `th-combat-unsafe? = #t`)
  ;; with low-threat non-lethal live Assimilator `11102` (1 flying Phoenix `9t` away -> score ~1180).
  (define nx-main-off (mk-l31-u 11101 59 1 28.5 28.5 #:hp 300.0 #:hp-max 1000.0 #:shield 0.0 #:rad 2.75 #:assigned 0 #:ideal 16))
  (define as-low-thrt (mk-l31-u 11102 61 1 24.0 23.0 #:hp 450.0 #:shield 450.0 #:rad 1.5 #:assigned 0 #:ideal 3 #:vesp 2000))
  (define m-main-1    (mk-l31-u 11104 341 3 23.0 31.0 #:hp 1000.0 #:rad 1.0 #:mins 1200))
  (define e-periph-st (mk-l31-u 11105 74 4 41.5 28.5 #:hp 160.0 #:rad 0.625))
  (define e-air-phx   (mk-l31-u 11106 78 4 24.0 14.0 #:hp 180.0 #:rad 0.75 #:flying? #t))
  ;; Online Natural Nexus (safe minerals so `0b` runs!) + offline Third with higher-threat live Assimilator `11103`
  ;; (2 ground Stalkers at `5t` -> threat ~12320, non-lethal `< 3` but far worse than `11102`).
  (define nx-nat-on   (mk-l31-u 11107 59 1 60.5 28.5 #:hp 1000.0 #:shield 1000.0 #:rad 2.75 #:assigned 14 #:ideal 16))
  (define m-nat-1     (mk-l31-u 11108 341 3 66.0 28.5 #:hp 1000.0 #:rad 1.0 #:mins 1200))
  (define m-nat-2     (mk-l31-u 11109 341 3 66.0 31.0 #:hp 1000.0 #:rad 1.0 #:mins 1200))
  (define nx-3rd-off  (mk-l31-u 11110 59 1 60.5 60.5 #:hp 300.0 #:hp-max 1000.0 #:rad 2.75 #:assigned 0 #:ideal 16))
  (define as-hi-thrt  (mk-l31-u 11103 61 1 56.0 55.0 #:hp 450.0 #:shield 450.0 #:rad 1.5 #:assigned 0 #:ideal 3 #:vesp 2000))
  (define e-camp-st1  (mk-l31-u 11111 74 4 56.0 50.0 #:hp 160.0 #:rad 0.625))
  (define e-camp-st2  (mk-l31-u 11112 74 4 59.0 52.0 #:hp 160.0 #:rad 0.625))
  ;; 20 Probes (17 mining Natural minerals, 3 near Main).
  (define (mk-1b-obs loop gas #:rescued-targeting? [rescued-targeting? #f])
    (define probes
      (for/list ([i (in-range 0 20)])
        (define tag (+ 11120 i))
        (if (< i 3)
            (mk-l31-u tag 84 1 (+ 25.0 (* 0.5 i)) 25.0 #:hp 20.0 #:shield 20.0 #:rad 0.375
                      #:orders (if rescued-targeting?
                                   (list (sc2-unit-order 298 #f 11102 0.0))
                                   (list (sc2-unit-order 298 #f 11104 0.0))))
            (mk-l31-u tag 84 1 (+ 62.0 (* 0.2 i)) 29.0 #:hp 20.0 #:shield 20.0 #:rad 0.375
                      #:orders (list (sc2-unit-order 298 #f 11108 0.0))))))
    (sc2-observation loop (sc2-player-common 1 500 gas 80 50 10 20 0 0 0 0)
                     (append (list nx-main-off as-low-thrt m-main-1 e-periph-st e-air-phx
                                   nx-nat-on m-nat-1 m-nat-2
                                   nx-3rd-off as-hi-thrt e-camp-st1 e-camp-st2)
                             probes)
                     '() '() #f '() '() '() '() '() '()))
  ;; Loop 19000: starts zero-gas streak (no rescue yet).
  (void (saturate-workers-and-gas-commands (mk-1b-obs 19000 21)))
  (define latch-at-0 (unbox SC2-ZERO-GAS-RESCUE-LATCH))
  ;; Loop 19250 (250f < 300f): still no rescue latch.
  (void (saturate-workers-and-gas-commands (mk-1b-obs 19250 21)))
  (define latch-at-250 (unbox SC2-ZERO-GAS-RESCUE-LATCH))
  ;; Loop 19300 (300f >= 300f): rescue triggers! Force-assigns 3 workers directly to `11102` (not `11103`).
  (define cmds-1b-rescue (saturate-workers-and-gas-commands (mk-1b-obs 19300 21)))
  (define latch-at-300 (unbox SC2-ZERO-GAS-RESCUE-LATCH))
  (define rescue-11102-cnt
    (count (lambda (c)
             (and (sc2-raw-unit-command? c)
                  (= (sc2-raw-unit-command-ability-id c) 3666)
                  (= (sc2-raw-unit-command-target-unit-tag c) 11102)))
           cmds-1b-rescue))
  (define rescue-11103-cnt
    (count (lambda (c)
             (and (sc2-raw-unit-command? c)
                  (= (sc2-raw-unit-command-target-unit-tag c) 11103)))
           cmds-1b-rescue))
  ;; Loop 19340 (`cur-gas = 25`, gas flowing < 150!): latch MUST stay `#t` and `0b` MUST NOT
  ;; evacuate the 3 Probes (`11120..11122`) harvesting `11102` near offline Main Nexus!
  (define cmds-1b-keep
    (saturate-workers-and-gas-commands (mk-1b-obs 19340 25 #:rescued-targeting? #t)))
  (define latch-at-25g (unbox SC2-ZERO-GAS-RESCUE-LATCH))
  (define evacuated-rescued?
    (ormap (lambda (c)
             (and (sc2-raw-unit-command? c)
                  (ormap (lambda (wt) (memv wt '(11120 11121 11122)))
                         (sc2-raw-unit-command-unit-tags c))))
           cmds-1b-keep))
  ;; Loop 19600 (`cur-gas = 155 >= 150`): rescue latch cleanly disengages!
  (void (saturate-workers-and-gas-commands (mk-1b-obs 19600 155 #:rescued-targeting? #t)))
  (define latch-at-155g (unbox SC2-ZERO-GAS-RESCUE-LATCH))
  (check-true "l31-p0-1b-zero-gas-freeze-rescue-300f-assigns-3-to-lowest-threat-and-exempts-0b-until-150g"
              (and (not latch-at-0)
                   (not latch-at-250)
                   latch-at-300
                   (= rescue-11102-cnt 3)
                   (= rescue-11103-cnt 0)
                   latch-at-25g
                   (not evacuated-rescued?)
                   (not latch-at-155g)))

  ;; L31-P0-1c: Zero-gas-freeze rescue MUST NOT feed workers into lethal ground slaughter
  ;; (`>= 3` uncontested ground-damaging enemy units within `7.0t` of the ONLY live geyser)!
  (set-box! SC2-ZERO-GAS-STREAK-START-LOOP #f)
  (set-box! SC2-ZERO-GAS-LAST-VESPENE #f)
  (set-box! SC2-ZERO-GAS-RESCUE-LATCH #f)
  (define as-lethal (mk-l31-u 11202 61 1 24.0 23.0 #:hp 450.0 #:shield 450.0 #:rad 1.5 #:assigned 0 #:ideal 3 #:vesp 2000))
  (define e-kill-1  (mk-l31-u 11203 74 4 24.0 26.0 #:hp 160.0 #:rad 0.625))
  (define e-kill-2  (mk-l31-u 11204 74 4 26.0 24.0 #:hp 160.0 #:rad 0.625))
  (define e-kill-3  (mk-l31-u 11205 74 4 22.0 25.0 #:hp 160.0 #:rad 0.625))
  (define prbs-1c
    (for/list ([i (in-range 0 18)])
      (mk-l31-u (+ 11210 i) 84 1 (+ 62.0 (* 0.2 i)) 29.0 #:hp 20.0 #:shield 20.0 #:rad 0.375
                #:orders (list (sc2-unit-order 298 #f 11108 0.0)))))
  (define (mk-1c-obs loop)
    (sc2-observation loop (sc2-player-common 1 500 20 80 48 0 18 0 0 0 0)
                     (append (list nx-main-off as-lethal e-kill-1 e-kill-2 e-kill-3
                                   nx-nat-on m-nat-1 m-nat-2)
                             prbs-1c)
                     '() '() #f '() '() '() '() '() '()))
  (void (saturate-workers-and-gas-commands (mk-1c-obs 19700)))
  (define cmds-1c (saturate-workers-and-gas-commands (mk-1c-obs 20050)))
  ;; Note: `emergency-protected-gas-bldgs` still allows at most 1 emergency probe when `safe-ready-gas-bldgs = '()`,
  ;; while `gas-zero-freeze-rescue?` MUST NOT force-assign 3 workers into `>= 3` close ground killers!
  (define sent-to-lethal-cnt
    (count (lambda (c)
             (and (sc2-raw-unit-command? c)
                  (= (sc2-raw-unit-command-target-unit-tag c) 11202)))
           cmds-1c))
  (check-true "l31-p0-1c-zero-gas-freeze-rescue-does-not-force-3-workers-into-lethal-ground-slaughter"
              (<= sent-to-lethal-cnt 1))

  ;; L31-P0-1d: Terran multi-structure `step-placement-rpc-budget = 3`: when `supply-depot` + `barracks`
  ;; (`>= 2` distinct Terran structures) queue in ONE step and `barracks #2` (`terran-prod-spillover-eligible?`)
  ;; fails `2.0t` on RPC #2, RPC #3 MUST execute `0.5t` tight spillover and place BOTH in the same step!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-clear! SC2-TERRAN-5X3-MISS-CACHE)
  (hash-clear! SC2-TERRAN-5X3-MISS-STREAK)
  (define l31-gi
    (sc2-game-info "L31TerranBudgetMap" "" '() '(128 128) '(4 4 124 124)
                   (list (sc2-point2d 100.0 100.0)) w3-full-grid #f w3-full-grid))
  (let-values ([(ws rpc-cnt cleanup!)
                (l31-start-mock-ws
                 (lambda (ab px py _rn)
                   (cond
                     [(= ab 319) 1]
                     [(and (= ab 321) (<= (l31-dist px py 35.5 29.5) 0.1)) 1]
                     [else 2])))])
    (define cc-main (mk-l31-u 11301 18 1 28.5 28.5 #:hp 1500.0 #:rad 2.75))
    (define cc-nat  (mk-l31-u 11302 18 1 56.5 28.5 #:hp 1500.0 #:rad 2.75))
    (define rax-1   (mk-l31-u 11303 21 1 32.5 28.5 #:hp 1000.0 #:rad 1.5))
    ;; `(35.5, 29.5)` sits `3.16t` from `rax-1 (32.5, 28.5)` -> fails `2.0t` & `em-spacing=1.25`,
    ;; passing ONLY under `0.5t` tight spillover on RPC #3!
    (define scv-1   (mk-l31-u 11305 45 1 27.0 26.0 #:hp 45.0 #:rad 0.375))
    (define scv-2   (mk-l31-u 11306 45 1 55.0 28.0 #:hp 45.0 #:rad 0.375))
    (define obs-1d
      (sc2-observation 20200 (sc2-player-common 1 800 200 70 40 16 24 0 0 0 0)
                       (list cc-main cc-nat rax-1 scv-1 scv-2)
                       '() '() #f '() '() '() '() '() '()))
    (define cmds-1d
      (translate-bot-actions->sc2-raw-commands
       '((build supply-depot 26.0 24.0) (build barracks 28.5 28.5))
       obs-1d #:ws-conn ws #:game-info l31-gi))
    (define dep-cmd (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 319))) cmds-1d))
    (define rax-cmd (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 321))) cmds-1d))
    (define rax-pt (and rax-cmd (sc2-raw-unit-command-target-pos rax-cmd)))
    (check-true "l31-p0-1d-terran-multi-bldg-budget-3-places-barracks-tight-05-after-depot"
                (and (= (unbox rpc-cnt) 3)
                     (sc2-raw-unit-command? dep-cmd)
                     (sc2-point2d? rax-pt)
                     (<= (l31-dist (sc2-point2d-x rax-pt) (sc2-point2d-y rax-pt) 35.5 29.5) 0.1)))
    (cleanup!))

  ;; L31-P0-1e: Same-type dual Terran `barracks` (`distinct-terran-build-count = 1`, initial budget=2):
  ;; 1st `barracks` takes RPC #1, 2nd `barracks` fails `2.0t` on RPC #2 (`budget -> 0`), and
  ;; `terran-tight-bonus-granted?` grants the single 3rd RPC so 2nd `barracks` lands via `0.5t` tight!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-clear! SC2-TERRAN-5X3-MISS-CACHE)
  (hash-clear! SC2-TERRAN-5X3-MISS-STREAK)
  (let-values ([(ws rpc-cnt cleanup!)
                (l31-start-mock-ws
                 (lambda (ab px py rn)
                   (cond
                     ;; 1st Barracks passes anywhere on RPC #1
                     [(and (= ab 321) (= rn 1)) 1]
                     [(and (= ab 319) (= rn 1)) 1]
                     ;; 2nd Barracks fails `2.0t` on RPC #2 and passes ONLY at tight spot `(35.5, 29.5)` on RPC #3!
                     [(and (= ab 321) (<= (l31-dist px py 35.5 29.5) 0.1)) 1]
                     [else 2])))])
    (define cc-main (mk-l31-u 11401 18 1 28.5 28.5 #:hp 1500.0 #:rad 2.75))
    (define cc-nat  (mk-l31-u 11402 18 1 56.5 28.5 #:hp 1500.0 #:rad 2.75))
    (define rax-1   (mk-l31-u 11403 21 1 32.5 28.5 #:hp 1000.0 #:rad 1.5))
    (define scv-1   (mk-l31-u 11405 45 1 27.0 26.0 #:hp 45.0 #:rad 0.375))
    (define scv-2   (mk-l31-u 11406 45 1 55.0 28.0 #:hp 45.0 #:rad 0.375))
    (define obs-1e
      (sc2-observation 20300 (sc2-player-common 1 800 200 70 40 16 24 0 0 0 0)
                       (list cc-main cc-nat rax-1 scv-1 scv-2)
                       '() '() #f '() '() '() '() '() '()))
    (define cmds-1e
      (translate-bot-actions->sc2-raw-commands
       '((build barracks 28.5 28.5) (build barracks 28.5 28.5))
       obs-1e #:ws-conn ws #:game-info l31-gi))
    (define rax-cmds
      (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 321))) cmds-1e))
    (define hit-tight?
      (ormap (lambda (c)
               (define pt (sc2-raw-unit-command-target-pos c))
               (and (sc2-point2d? pt)
                    (<= (l31-dist (sc2-point2d-x pt) (sc2-point2d-y pt) 35.5 29.5) 0.1)))
             rax-cmds))
    (check-true "l31-p0-1e-terran-spillover-tight-05-grants-3rd-rpc-for-same-type-dual-barracks"
                (and (= (unbox rpc-cnt) 3)
                     (= (length rax-cmds) 2)
                     hit-tight?))
    (cleanup!)))

;; =============================================================================
;; Loop 32 (`L32-P0-1`): Mined-Out Long-Distance Mining (MOVE 16 / SMART 3666),
;; Round-Robin Multi-Geyser Gas Rescue + 4.5t Harvest Corridor, & Tight Spillover
;; =============================================================================
(printf "[Loop 32] Testing L32-P0-1 mined-out LDM (MOVE16/SMART3666), round-robin 224f multi-geyser rescue + 4.5t corridor, & dual-gateway tight spillover...\n")
(let ()
  (define (mk-l32-u tag utype alliance x y
                    #:hp [hp 100.0] #:hp-max [hp-max hp] #:shield [sh 0.0] #:rad [rad 1.0]
                    #:display [disp 1] #:orders [ords '()] #:buffs [buffs '()]
                    #:flying? [flying? #f]
                    #:mins [mins 0] #:vesp [vesp 0]
                    #:assigned [asgn 0] #:ideal [idl 0])
    (sc2-unit disp alliance tag utype (if (= alliance 1) 1 (if (= alliance 3) 0 2))
              (sc2-point3d x y 8.0) 0.0 rad 1.0 0 flying? #f #f
              hp hp-max sh sh 0.0 0.0 mins vesp #f #f #f #t #f
              ords 0 buffs asgn idl 0.0 0 0 0 0 '() 0 0))

  (define (l32-dist x1 y1 x2 y2)
    (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))

  (define (l32-start-mock-ws decide-fn)
    (define-values (c-in s-out) (make-pipe))
    (define-values (s-in c-out) (make-pipe))
    (define ws (sc2-ws-conn "127.0.0.1" 59932 "/sc2api" c-in c-out #f 1))
    (define rpc-cnt (box 0))
    (define th
      (thread
       (lambda ()
         (let lp ()
           (define b0 (read-byte s-in))
           (unless (eof-object? b0)
             (define b1 (read-byte s-in))
             (define masked? (not (zero? (bitwise-and b1 #x80))))
             (define len0 (bitwise-and b1 #x7F))
             (define plen
               (cond [(< len0 126) len0]
                     [(= len0 126) (integer-bytes->integer (read-bytes 2 s-in) #f #t)]
                     [else (integer-bytes->integer (read-bytes 8 s-in) #f #t)]))
             (define mkey (if masked? (read-bytes 4 s-in) #f))
             (define raw (read-bytes plen s-in))
             (define payload
               (if masked?
                   (let ([out (make-bytes plen)])
                     (for ([i (in-range plen)])
                       (bytes-set! out i (bitwise-xor (bytes-ref raw i) (bytes-ref mkey (modulo i 4)))))
                     out)
                   raw))
             (define req-f (decode-protobuf-message payload))
             (define id-p (assoc 97 req-f))
             (define id-b (if id-p (encode-uint32 97 (third id-p)) #""))
             (define q-p (assoc 14 req-f))
             (when q-p
               (set-box! rpc-cnt (add1 (unbox rpc-cnt)))
               (define rn (unbox rpc-cnt))
               (define qf (decode-protobuf-message (third q-p)))
               (define p-items (filter (lambda (e) (= (first e) 3)) qf))
               (define res-b
                 (apply bytes-append
                        (for/list ([it (in-list p-items)])
                          (define itf (decode-protobuf-message (third it)))
                          (define ab (let ([p (assoc 1 itf)]) (if p (third p) 0)))
                          (define tp-e (assoc 2 itf))
                          (define-values (px py)
                            (if tp-e
                                (let ([ptf (decode-protobuf-message (third tp-e))])
                                  (values (let ([xp (assoc 1 ptf)])
                                            (if (and xp (bytes? (third xp)))
                                                (floating-point-bytes->real (third xp) #f)
                                                0.0))
                                          (let ([yp (assoc 2 ptf)])
                                            (if (and yp (bytes? (third yp)))
                                                (floating-point-bytes->real (third yp) #f)
                                                0.0))))
                                (values 0.0 0.0)))
                          (encode-submessage-field 3 (encode-int32 1 (decide-fn ab px py rn))))))
               (define resp (bytes-append (encode-submessage-field 14 res-b) id-b (encode-int32 99 3)))
               (define rlen (bytes-length resp))
               (define rhdr
                 (cond [(< rlen 126) (bytes #x82 rlen)]
                       [(<= rlen 65535) (bytes-append (bytes #x82 126) (integer->integer-bytes rlen 2 #f #t))]
                       [else (bytes-append (bytes #x82 127) (integer->integer-bytes rlen 8 #f #t))]))
               (write-bytes rhdr s-out)
               (write-bytes resp s-out)
               (flush-output s-out))
             (lp))))))
    (values ws rpc-cnt (lambda () (close-output-port c-out) (close-input-port c-in) (thread-wait th))))

  ;; L32-P0-1a: Mined-out long-distance mining works below 500G (`32M/448G`, no `>= 500G` gate!),
  ;; emits `MOVE (16)` to `(mx, my)` for `display-type = 2` fog-of-war snapshot minerals, ignores
  ;; enemy-camped patches, and upgrades to `SMART (3666)` once visible (`display-type = 1`) for
  ;; BOTH idle workers AND moving workers whose move target is revealed!
  (set-box! SC2-GAS-PULL-HYSTERESIS-LATCH #f)
  (define hatch-mo (mk-l32-u 12001 86 1 28.5 28.5 #:hp 1500.0 #:rad 2.75 #:assigned 0 #:ideal 0))
  (define drn-id1  (mk-l32-u 12002 104 1 30.0 29.0 #:hp 40.0 #:rad 0.375))
  (define drn-id2  (mk-l32-u 12003 104 1 31.0 29.0 #:hp 40.0 #:rad 0.375))
  (define m-camp-2 (mk-l32-u 12011 341 3 50.0 28.5 #:hp 1000.0 #:rad 1.0 #:display 2 #:mins 0))
  (define e-grd-1  (mk-l32-u 12012 74  4 52.0 28.5 #:hp 160.0 #:rad 0.625))
  (define m-safe-2 (mk-l32-u 12013 341 3 80.0 40.0 #:hp 1000.0 #:rad 1.0 #:display 2 #:mins 0))
  (define cmds-ldm-fog
    (saturate-workers-and-gas-commands
     (sc2-observation 20500 (sc2-player-common 1 32 448 120 70 20 44 0 0 0 0)
                      (list hatch-mo drn-id1 drn-id2 m-camp-2 e-grd-1 m-safe-2)
                      '() '() #f '() '() '() '() '() '())))
  (define fog-ok?
    (for/and ([wt (in-list '(12002 12003))])
      (define c (findf (lambda (x) (and (sc2-raw-unit-command? x)
                                        (memv wt (sc2-raw-unit-command-unit-tags x))))
                       cmds-ldm-fog))
      (and (sc2-raw-unit-command? c)
           (= (sc2-raw-unit-command-ability-id c) 16)
           (sc2-point2d? (sc2-raw-unit-command-target-pos c))
           (<= (l32-dist (sc2-point2d-x (sc2-raw-unit-command-target-pos c))
                         (sc2-point2d-y (sc2-raw-unit-command-target-pos c))
                         80.0 40.0)
               0.1))))
  ;; Once patch `12013` flips to `display-type = 1` visible, BOTH idle `12002` AND moving `12003`
  ;; (already walking toward `(80.0, 40.0)` within `14t`) immediately get `SMART (3666)` onto `12013`!
  (define m-safe-1  (mk-l32-u 12013 341 3 80.0 40.0 #:hp 1000.0 #:rad 1.0 #:display 1 #:mins 1400))
  (define drn-mov   (mk-l32-u 12003 104 1 73.0 40.0 #:hp 40.0 #:rad 0.375
                              #:orders (list (sc2-unit-order 16 (sc2-point3d 80.0 40.0 8.0) 0 0.0))))
  (define cmds-ldm-vis
    (saturate-workers-and-gas-commands
     (sc2-observation 20540 (sc2-player-common 1 32 448 120 70 20 44 0 0 0 0)
                      (list hatch-mo drn-id1 drn-mov m-camp-2 e-grd-1 m-safe-1)
                      '() '() #f '() '() '() '() '() '())))
  (define vis-ok?
    (for/and ([wt (in-list '(12002 12003))])
      (define c (findf (lambda (x) (and (sc2-raw-unit-command? x)
                                        (memv wt (sc2-raw-unit-command-unit-tags x))))
                       cmds-ldm-vis))
      (and (sc2-raw-unit-command? c)
           (= (sc2-raw-unit-command-ability-id c) 3666)
           (= (sc2-raw-unit-command-target-unit-tag c) 12013))))
  (check-true "l32-p0-1a-mined-out-idle-workers-ldm-below-500g-move16-fog-and-smart3666-visible"
              (and fog-ok? vis-ok?))

  ;; L32-P0-1b: Round-robin multi-geyser `Step 0a` rescue + top-2 protection (`#28` GasZeroFreeze -> 0):
  ;; Three non-lethal live Extractors `12102`, `12103`, `12104` at offline Hatcheries (plus safe Natural
  ;; minerals so `0b` runs!). At `t + 300f`, assigns 3 workers to `12102` + 2 to `12103` and protects
  ;; BOTH in `online-gas-tags`; after `>= 224f` (~10s) of still 0 gas gain, rotates round-robin to
  ;; rescue & protect `12104`!
  (set-box! SC2-GAS-PULL-HYSTERESIS-LATCH #f)
  (set-box! SC2-ZERO-GAS-STREAK-START-LOOP #f)
  (set-box! SC2-ZERO-GAS-LAST-VESPENE #f)
  (set-box! SC2-ZERO-GAS-RESCUE-LATCH #f)
  (set-box! (worker-sat-state-zero-gas-rescue-rotation-idx SC2-DEFAULT-WORKER-SAT-STATE) 0)
  (set-box! SC2-ZERO-GAS-RESCUE-LAST-ROTATE-LOOP #f)
  (define h-off-1 (mk-l32-u 12101 86 1 28.5 28.5 #:hp 400.0 #:hp-max 1500.0 #:rad 2.75 #:assigned 0 #:ideal 16))
  (define e-per-1 (mk-l32-u 12105 74 4 41.0 28.5 #:hp 160.0 #:rad 0.625))
  (define h-on-2  (mk-l32-u 12106 86 1 70.5 28.5 #:hp 1500.0 #:rad 2.75 #:assigned 14 #:ideal 16))
  (define m-on-2a (mk-l32-u 12107 341 3 76.0 28.5 #:hp 1000.0 #:rad 1.0 #:mins 1200))
  (define m-on-2b (mk-l32-u 12108 341 3 76.0 31.0 #:hp 1000.0 #:rad 1.0 #:mins 1200))
  (define (mk-1b32-obs loop gas #:a1 [a1 0] #:a2 [a2 0] #:a3 [a3 0] #:e1-e2-active? [e12? #f])
    (define ex1 (mk-l32-u 12102 88 1 24.0 23.0 #:hp 500.0 #:rad 1.5 #:assigned a1 #:ideal 3 #:vesp 2000))
    (define ex2 (mk-l32-u 12103 88 1 24.0 34.0 #:hp 500.0 #:rad 1.5 #:assigned a2 #:ideal 3 #:vesp 2000))
    (define ex3 (mk-l32-u 12104 88 1 28.5 36.5 #:hp 500.0 #:rad 1.5 #:assigned a3 #:ideal 3 #:vesp 2000))
    (define drns
      (for/list ([i (in-range 0 20)])
        (define tag (+ 12120 i))
        (cond
          [(and e12? (< i 3))
           (mk-l32-u tag 104 1 25.0 24.0 #:hp 40.0 #:rad 0.375
                     #:orders (list (sc2-unit-order 1183 #f 12102 0.0)))]
          [(and e12? (< i 5))
           (mk-l32-u tag 104 1 25.0 33.0 #:hp 40.0 #:rad 0.375
                     #:orders (list (sc2-unit-order 1183 #f 12103 0.0)))]
          [else
           (mk-l32-u tag 104 1 (+ 72.0 (* 0.2 i)) 29.0 #:hp 40.0 #:rad 0.375
                     #:orders (list (sc2-unit-order 1183 #f 12107 0.0)))])))
    (sc2-observation loop (sc2-player-common 1 400 gas 100 50 10 20 0 0 0 0)
                     (append (list h-off-1 e-per-1 h-on-2 m-on-2a m-on-2b ex1 ex2 ex3) drns)
                     '() '() #f '() '() '() '() '() '()))
  (void (saturate-workers-and-gas-commands (mk-1b32-obs 21000 19)))
  ;; At +300f: initial rescue activates — assigns 3 workers to E1 (`12102`) + 2 to E2 (`12103`)!
  (define cmds-rr-0 (saturate-workers-and-gas-commands (mk-1b32-obs 21300 19)))
  (define rr0-e1 (count (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-target-unit-tag c) 12102))) cmds-rr-0))
  (define rr0-e2 (count (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-target-unit-tag c) 12103))) cmds-rr-0))
  ;; At +340f (40f later, still 19G, E1 has 3 & E2 has 2): BOTH E1 and E2 workers stay protected from `0b`!
  (define cmds-rr-hold (saturate-workers-and-gas-commands (mk-1b32-obs 21340 19 #:a1 3 #:a2 2 #:e1-e2-active? #t)))
  (define evac-e12?
    (ormap (lambda (c)
             (and (sc2-raw-unit-command? c)
                  (ormap (lambda (wt) (memv wt '(12120 12121 12122 12123 12124)))
                         (sc2-raw-unit-command-unit-tags c))))
           cmds-rr-hold))
  ;; At +524f (`21300 + 224` with still 0 gas gain!): rotates round-robin (`rot-idx -> 1`) so
  ;; active = E2 (`12103`, topped up from 2->3) AND backup = E3 (`12104`, assigned 2 workers!)!
  (define cmds-rr-1 (saturate-workers-and-gas-commands (mk-1b32-obs 21524 19 #:a1 3 #:a2 2 #:e1-e2-active? #t)))
  (define rot-after-224 (unbox (worker-sat-state-zero-gas-rescue-rotation-idx SC2-DEFAULT-WORKER-SAT-STATE)))
  (define rr1-e2 (count (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-target-unit-tag c) 12103))) cmds-rr-1))
  (define rr1-e3 (count (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-target-unit-tag c) 12104))) cmds-rr-1))
  (check-true "l32-p0-1b-round-robin-step0a-rotates-after-224f-and-protects-2-live-geysers"
              (and (= rr0-e1 3)
                   (= rr0-e2 2)
                   (not evac-e12?)
                   (= rot-after-224 1)
                   (= rr1-e2 1)
                   (= rr1-e3 2)))

  ;; L32-P0-1c: `4.5t` TownHall-to-geyser/gas-building harvest corridor exclusion (`#28`):
  ;; Even AFTER an Extractor (`88`) is built on the geyser (neutral geyser gone!), non-defensive
  ;; tech buildings (`evolution-chamber`, `roach-warren`) MUST be rejected inside the `4.5t`
  ;; Hatch->Extractor corridor (`(178.5, 81.5)` is `3.4t` from `(175.5, 76.5)->(182.5, 79.5)`),
  ;; while open tiles `> 4.5t` clear (`(175.5, 84.5)`) AND static defense (`spore-crawler`) PASS!
  (define h-cor   (mk-l32-u 12201 86 1 175.5 76.5 #:hp 1500.0 #:rad 2.75))
  (define ex-cor  (mk-l32-u 12202 88 1 182.5 79.5 #:hp 500.0 #:rad 1.5 #:vesp 2000))
  (define cor-units (list h-cor ex-cor))
  (check-true "l32-p0-1c-harvest-corridor-45t-excludes-evo-and-roach-warren-around-built-extractor"
              (and (not (placement-preserves-base-exit-and-spawn? 178.5 81.5 'evolution-chamber cor-units
                                                                  #:base-x 175.5 #:base-y 76.5))
                   (not (placement-preserves-base-exit-and-spawn? 178.5 81.5 'roach-warren cor-units
                                                                  #:base-x 175.5 #:base-y 76.5))
                   (placement-preserves-base-exit-and-spawn? 175.5 84.5 'evolution-chamber cor-units
                                                             #:base-x 175.5 #:base-y 76.5)
                   (placement-preserves-base-exit-and-spawn? 178.5 81.5 'spore-crawler cor-units
                                                             #:base-x 175.5 #:base-y 76.5)))

  ;; L32-P0-1d: Protoss same-type dual `gateway` (`distinct-protoss-build-count = 1`, initial budget=2):
  ;; 1st `gateway` succeeds on RPC #1, 2nd `gateway` fails `2.0t` on RPC #2 (`budget -> 0`), and
  ;; `protoss-tight-bonus-granted?` grants the single 3rd RPC so 2nd `gateway` lands at tight `0.5t`!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (set-box! SC2-PROTOSS-POWER-PLACEMENT-FAIL-LOOP -9999)
  (define l32-gi
    (sc2-game-info "L32ProtoTightMap" "" '() '(128 128) '(4 4 124 124)
                   (list (sc2-point2d 100.0 100.0)) w3-full-grid #f w3-full-grid))
  (let-values ([(ws rpc-cnt cleanup!)
                (l32-start-mock-ws
                 (lambda (ab px py rn)
                   (cond
                     ;; 1st Gateway succeeds on RPC #1 (far spot `(26.5, 36.5)` or any first query)
                     [(and (= ab 883) (= rn 1) (<= (l32-dist px py 26.5 34.5) 2.5)) 1]
                     ;; 2nd Gateway fails `2.0t` on RPC #2 and lands ONLY at tight `0.5t` spot `(33.5, 33.5)` on RPC #3!
                     [(and (= ab 883) (<= (l32-dist px py 33.5 33.5) 0.1)) 1]
                     [else 2])))])
    (define nx-m (mk-l32-u 12301 59 1 26.5 26.5 #:hp 1000.0 #:shield 1000.0 #:rad 2.75))
    (define py-m (mk-l32-u 12302 60 1 30.0 34.0 #:hp 200.0 #:shield 200.0 #:rad 1.0))
    (define prb-busy
      (mk-l32-u 12303 84 1 31.0 33.0 #:hp 20.0 #:shield 20.0 #:rad 0.375
                #:orders (list (sc2-unit-order 881 (sc2-point3d 31.5 34.0 8.0) 0 0.0))))
    (define prb-a (mk-l32-u 12304 84 1 29.0 32.0 #:hp 20.0 #:shield 20.0 #:rad 0.375))
    (define prb-b (mk-l32-u 12305 84 1 28.0 32.0 #:hp 20.0 #:shield 20.0 #:rad 0.375))
    (define obs-2gw
      (sc2-observation 21800 (sc2-player-common 1 600 100 60 36 10 26 0 0 0 0)
                       (list nx-m py-m prb-busy prb-a prb-b) '()
                       (list (sc2-power-source (sc2-point3d 30.0 34.0 8.0) 6.5 12302))
                       #f '() '() '() '() '() '()))
    (define cmds-2gw
      (translate-bot-actions->sc2-raw-commands
       '((build gateway 30.0 34.0) (build gateway 30.0 34.0))
       obs-2gw #:ws-conn ws #:game-info l32-gi))
    (define gw-cmds
      (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 883))) cmds-2gw))
    (define hit-gw-tight?
      (ormap (lambda (c)
               (define pt (sc2-raw-unit-command-target-pos c))
               (and (sc2-point2d? pt)
                    (<= (l32-dist (sc2-point2d-x pt) (sc2-point2d-y pt) 33.5 33.5) 0.1)))
             gw-cmds))
    (check-true "l32-p0-1d-protoss-same-type-dual-gateway-grants-3rd-rpc-tight-05-spillover"
                (and (= (unbox rpc-cnt) 3)
                     (= (length gw-cmds) 2)
                     hit-gw-tight?))
    (cleanup!))

  ;; L32-P0-1e: Early-rush (`< 4:00`) `gateway` negative cooldown TTL is `16f` (NOT `64f`!) so
  ;; once rush units vacate a build tile, Gateway re-probes and places within 16 game loops!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (define allow-gw-1e? (box #f))
  (let-values ([(ws rpc-cnt cleanup!)
                (l32-start-mock-ws
                 (lambda (ab _px _py _rn)
                   (if (and (= ab 883) (unbox allow-gw-1e?)) 1 2)))])
    (define nx-e (mk-l32-u 12401 59 1 26.5 26.5 #:hp 1000.0 #:shield 1000.0 #:rad 2.75))
    (define py-e (mk-l32-u 12402 60 1 30.0 34.0 #:hp 200.0 #:shield 200.0 #:rad 1.0))
    (define prb-e (mk-l32-u 12403 84 1 29.0 32.0 #:hp 20.0 #:shield 20.0 #:rad 0.375))
    (define ling-e (mk-l32-u 12404 105 4 40.0 34.0 #:hp 35.0 #:rad 0.375))
    (define (mk-1e-obs loop)
      (sc2-observation loop (sc2-player-common 1 350 50 31 20 2 18 0 0 0 0)
                       (list nx-e py-e prb-e ling-e) '()
                       (list (sc2-power-source (sc2-point3d 30.0 34.0 8.0) 6.5 12402))
                       #f '() '() '() '() '() '()))
    ;; Loop 2800: Gateway fails (sets 16f neg-cd)
    (void (translate-bot-actions->sc2-raw-commands '((build gateway 30.0 34.0)) (mk-1e-obs 2800) #:ws-conn ws #:game-info l32-gi))
    (define rpcs-at-2800 (unbox rpc-cnt))
    ;; Loop 2816 (+16f < 64f!): tile clears -> MUST re-query and immediately emit Gateway!
    (set-box! allow-gw-1e? #t)
    (define cmds-2816
      (translate-bot-actions->sc2-raw-commands '((build gateway 30.0 34.0)) (mk-1e-obs 2816) #:ws-conn ws #:game-info l32-gi))
    (define gw-2816
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 883))) cmds-2816))
    (check-true "l32-p0-1e-early-rush-gateway-neg-cd-ttl-16f-recovers-fast"
                (and (> rpcs-at-2800 0)
                     (> (unbox rpc-cnt) rpcs-at-2800)
                     (sc2-raw-unit-command? gw-2816)))
    (cleanup!)))

;; =============================================================================
;; Loop 33 (`L33-P0-1`): Zero P0 Wire Starvation of P1 Macro + Zerg-Only 4.5t Corridor
;; =============================================================================
(printf "[Loop 33] Testing L33-P0-1 depot 556/558 P2 demotion, 10f mode-switch dedup, unstarvable P1 hr-floor=0 rescue, Zerg-only 4.5t corridor, & >=2-miss spillover...\n")
(let ()
  (define (mk-l33-u tag utype alliance x y
                    #:hp [hp 100.0] #:rad [rad 1.0] #:mins [mins 0] #:vesp [vesp 0])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 (if (= alliance 3) 0 2))
              (sc2-point3d x y 8.0) 0.0 rad 1.0 0 #f #f #f
              hp hp 0.0 0.0 0.0 0.0 mins vesp #f #f #f #t #f
              '() 0 '() 0 0 0.0 0 0 0 0 '() 0 0))

  (define (l33-dist x1 y1 x2 y2)
    (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))

  (define (l33-start-mock-ws decide-fn)
    (define-values (c-in s-out) (make-pipe))
    (define-values (s-in c-out) (make-pipe))
    (define ws (sc2-ws-conn "127.0.0.1" 59933 "/sc2api" c-in c-out #f 1))
    (define rpc-cnt (box 0))
    (define saw-319? (box #f))
    (define th
      (thread
       (lambda ()
         (let lp ()
           (define b0 (read-byte s-in))
           (unless (eof-object? b0)
             (define b1 (read-byte s-in))
             (define masked? (not (zero? (bitwise-and b1 #x80))))
             (define len0 (bitwise-and b1 #x7F))
             (define plen
               (cond [(< len0 126) len0]
                     [(= len0 126) (integer-bytes->integer (read-bytes 2 s-in) #f #t)]
                     [else (integer-bytes->integer (read-bytes 8 s-in) #f #t)]))
             (define mkey (if masked? (read-bytes 4 s-in) #f))
             (define raw (read-bytes plen s-in))
             (define payload
               (if masked?
                   (let ([out (make-bytes plen)])
                     (for ([i (in-range plen)])
                       (bytes-set! out i (bitwise-xor (bytes-ref raw i) (bytes-ref mkey (modulo i 4)))))
                     out)
                   raw))
             (define req-f (decode-protobuf-message payload))
             (define id-p (assoc 97 req-f))
             (define id-b (if id-p (encode-uint32 97 (third id-p)) #""))
             (define q-p (assoc 14 req-f))
             (when q-p
               (set-box! rpc-cnt (add1 (unbox rpc-cnt)))
               (define qf (decode-protobuf-message (third q-p)))
               (define p-items (filter (lambda (e) (= (first e) 3)) qf))
               (define res-b
                 (apply bytes-append
                        (for/list ([it (in-list p-items)])
                          (define itf (decode-protobuf-message (third it)))
                          (define ab (let ([p (assoc 1 itf)]) (if p (third p) 0)))
                          (when (= ab 319) (set-box! saw-319? #t))
                          (define tp-e (assoc 2 itf))
                          (define-values (px py)
                            (if tp-e
                                (let ([ptf (decode-protobuf-message (third tp-e))])
                                  (values (let ([xp (assoc 1 ptf)])
                                            (if (and xp (bytes? (third xp)))
                                                (floating-point-bytes->real (third xp) #f)
                                                0.0))
                                          (let ([yp (assoc 2 ptf)])
                                            (if (and yp (bytes? (third yp)))
                                                (floating-point-bytes->real (third yp) #f)
                                                0.0))))
                                (values 0.0 0.0)))
                          (encode-submessage-field 3 (encode-int32 1 (decide-fn ab px py))))))
               (define resp (bytes-append (encode-submessage-field 14 res-b) id-b (encode-int32 99 3)))
               (define rlen (bytes-length resp))
               (define rhdr
                 (cond [(< rlen 126) (bytes #x82 rlen)]
                       [(<= rlen 65535) (bytes-append (bytes #x82 126) (integer->integer-bytes rlen 2 #f #t))]
                       [else (bytes-append (bytes #x82 127) (integer->integer-bytes rlen 8 #f #t))]))
               (write-bytes rhdr s-out)
               (write-bytes resp s-out)
               (flush-output s-out))
             (lp))))))
    (values ws rpc-cnt saw-319? (lambda () (close-output-port c-out) (close-input-port c-in) (thread-wait th))))

  ;; L33-P0-1a (+ L54-W1): Supply Depot raise (`558`) stays P2 (cannot starve P1 macro),
  ;; Supply Depot lower (`556`) is promoted to P1 (cannot be starved by trapped P2 combat spam),
  ;; and identical non-urgent mode switches `(ab, sorted-tags)` are deduped for >= 10 loops!
  (define cmd-556 (sc2-raw-unit-command 556 #f 0 '(13001) #f))
  (define cmd-558 (sc2-raw-unit-command 558 #f 0 '(13001) #f))
  (define gov-33a (make-wire-apm-governor #:target-apm 410.0 #:hard-cap-apm 485.0))
  (define emit-loops-558
    (for/list ([gl (in-list '(100 102 104 106 108 110))]
               #:when (pair? (govern-sc2-wire-actions!
                              gov-33a
                              (list (sc2-raw-unit-command 558 #f 0 '(13001) #f))
                              gl)))
      gl))
  (define emit-loops-388
    (for/list ([gl (in-list '(200 203 206 209 210))]
               #:when (pair? (govern-sc2-wire-actions!
                              gov-33a
                              (list (sc2-raw-unit-command 388 #f 0 '(13002 13003) #f))
                              gl)))
      gl))
  (check-true "l33-p0-1a-depot-556-p1-558-p2-and-10-loop-mode-switch-dedup"
              (and (= (wire-cmd-priority-tier cmd-556) 1)
                   (= (wire-cmd-priority-tier cmd-558) 2)
                   (equal? emit-loops-558 '(100 110))
                   (equal? emit-loops-388 '(200 210))))

  ;; L33-P0-1b: Relentless `558` depot spam + non-urgent P0 mode-switch spam every step over >= 240 loops
  ;; MUST NEVER starve P1 macro (`171` MULE, `524` SCV, `560` Marine, `321` Build Barracks) AND stays <= 485 APM!
  (define gov-33b (make-wire-apm-governor #:target-apm 410.0 #:hard-cap-apm 485.0))
  (define p1-emitted-33b 0)
  (define mule-emitted-33b 0)
  (define scv-emitted-33b 0)
  (define train-emitted-33b 0)
  (define build-emitted-33b 0)
  (define max-p1-gap-33b 0)
  (define last-p1-loop-33b 1000)
  (define ev-win-33b '())
  (define peak-60s-ev-33b 0)
  (define sim-sel-33b #f)
  (for ([step-i (in-range 0 65)])
    (define gl (+ 1000 (* step-i 4)))
    (define spam-558
      (for/list ([k (in-range 10)])
        (sc2-raw-unit-command 558 #f 0 (list (+ 13100 k (* step-i 20))) #f)))
    (define spam-388
      (for/list ([k (in-range 6)])
        (sc2-raw-unit-command 388 #f 0 (list (+ 13500 k (* step-i 20))) #f)))
    (define base-macro
      (list (sc2-raw-unit-command 171 #f 9001 (list (+ 13900 (modulo step-i 3))) #f)
            (sc2-raw-unit-command 524 #f 0 (list (+ 13910 (modulo step-i 3))) #f)
            (sc2-raw-unit-command 560 #f 0 (list (+ 13920 (modulo step-i 4))) #f)
            (sc2-raw-unit-command 321 (sc2-point2d 34.5 34.5) 0 (list (+ 13930 (modulo step-i 4))) #f)))
    (define rot (modulo (+ step-i (quotient step-i 2)) 4))
    (define macro-batch (append (drop base-macro rot) (take base-macro rot)))
    (define out (govern-sc2-wire-actions! gov-33b (append spam-558 spam-388 macro-batch) gl))
    (define saw-p1-this-step? #f)
    (for ([c (in-list out)] #:when (sc2-raw-unit-command? c))
      (define ab (sc2-raw-unit-command-ability-id c))
      (define tags (sc2-raw-unit-command-unit-tags c))
      (define cost (if (and sim-sel-33b (equal? tags sim-sel-33b)) 1 2))
      (set! sim-sel-33b tags)
      (set! ev-win-33b (cons (cons gl cost) ev-win-33b))
      (when (memv ab '(171 524 560 321))
        (set! saw-p1-this-step? #t)
        (set! p1-emitted-33b (add1 p1-emitted-33b))
        (case ab
          [(171) (set! mule-emitted-33b (add1 mule-emitted-33b))]
          [(524) (set! scv-emitted-33b (add1 scv-emitted-33b))]
          [(560) (set! train-emitted-33b (add1 train-emitted-33b))]
          [(321) (set! build-emitted-33b (add1 build-emitted-33b))])))
    (set! ev-win-33b (filter (lambda (e) (> (car e) (- gl 1344))) ev-win-33b))
    (set! peak-60s-ev-33b (max peak-60s-ev-33b (for/sum ([e (in-list ev-win-33b)]) (cdr e))))
    (if saw-p1-this-step?
        (begin
          (set! max-p1-gap-33b (max max-p1-gap-33b (- gl last-p1-loop-33b)))
          (set! last-p1-loop-33b gl))
        (set! max-p1-gap-33b (max max-p1-gap-33b (- gl last-p1-loop-33b)))))
  (check-true (format "l33-p0-1b-558-and-p0-mode-spam-never-starves-p1-macro (p1=~a gap=~a ev=~a)"
                      p1-emitted-33b max-p1-gap-33b peak-60s-ev-33b)
              (and (>= p1-emitted-33b 40)
                   (>= mule-emitted-33b 10)
                   (>= scv-emitted-33b 10)
                   (>= train-emitted-33b 10)
                   (>= build-emitted-33b 10)
                   (<= max-p1-gap-33b 16)
                   (<= peak-60s-ev-33b 485)))

  ;; L33-P0-1c: At rolling-window saturation (`rem-headroom = 2.0`), overdue P1 macro (`>= 8` loops)
  ;; MUST emit with `hr-floor = 0.0` BEFORE non-urgent P0 mode switches (`388`), while `urgent-survival-cmd?`
  ;; P0 spells STILL take precedence over overdue P1!
  (define gov-33c (make-wire-apm-governor #:target-apm 410.0 #:hard-cap-apm 12.0))
  ;; Loop 100: 1 P1 cmd (cost 2, last-p1=100); Loop 102: 4 P0 cmds (cost 8 -> rolling-used=10, headroom=2.0!).
  (void (govern-sc2-wire-actions! gov-33c (list (sc2-raw-unit-command 524 #f 0 '(13950) #f)) 100))
  (void (govern-sc2-wire-actions!
         gov-33c
         (for/list ([k (in-range 4)])
           (mark-urgent-survival-cmd! (sc2-raw-unit-command 407 #f 13999 (list (+ 13970 k)) #f)))
         102))
  (define mode-388-c (sc2-raw-unit-command 388 #f 0 '(13951) #f))
  (define bld-321-c  (sc2-raw-unit-command 321 (sc2-point2d 34.5 34.5) 0 '(13952) #f))
  (define out-33c (govern-sc2-wire-actions! gov-33c (list mode-388-c bld-321-c) 112))
  ;; Now check urgent P0 beats overdue P1 in the 8..11f window when only 2.0 headroom remains
  ;; (whereas >= 12f critical overdue P1 preempts even urgent P0 — tested in L34-P0-1c!):
  (define gov-33d (make-wire-apm-governor #:target-apm 410.0 #:hard-cap-apm 12.0))
  (void (govern-sc2-wire-actions! gov-33d (list (sc2-raw-unit-command 524 #f 0 '(13960) #f)) 100))
  (void (govern-sc2-wire-actions!
         gov-33d
         (for/list ([k (in-range 4)])
           (mark-urgent-survival-cmd! (sc2-raw-unit-command 407 #f 13999 (list (+ 13980 k)) #f)))
         102))
  (define urg-407-d (mark-urgent-survival-cmd! (sc2-raw-unit-command 407 #f 13969 '(13961) #f)))
  (define bld-321-d (sc2-raw-unit-command 321 (sc2-point2d 34.5 34.5) 0 '(13962) #f))
  (define out-33d (govern-sc2-wire-actions! gov-33d (list bld-321-d urg-407-d) 109))
  (check-true "l33-p0-1c-overdue-p1-runs-at-hr-floor-0-before-p0-mode-switch-after-urgent-p0"
              (and (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 321))) out-33c)
                   (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 388))) out-33c))
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 407))) out-33d)
                   (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 321))) out-33d))))

  ;; L33-P0-1d: Narrow `4.5t` TownHall-to-geyser harvest corridor to Zerg tech ONLY:
  ;; Zerg `evolution-chamber`/`roach-warren` stay blocked at `3.4t < 4.5t` (keeping `GasZeroFreeze = 0`),
  ;; while Protoss `cybernetics-core`/`gateway` and Terran `engineering-bay`/`barracks` PASS at `3.4t`!
  (define th-pt-33 (mk-l33-u 13201 18 1 185.5 86.5 #:hp 1500.0 #:rad 2.75))
  (define ref-33   (mk-l33-u 13202 20 1 192.5 89.5 #:hp 500.0 #:rad 1.5 #:vesp 2000))
  (define pt-units-33 (list th-pt-33 ref-33))
  (check-true "l33-p0-1d-45t-corridor-zerg-only-allows-pt-tight-main-placement"
              (and (not (placement-preserves-base-exit-and-spawn? 188.5 91.5 'evolution-chamber pt-units-33
                                                                  #:base-x 185.5 #:base-y 86.5))
                   (not (placement-preserves-base-exit-and-spawn? 188.5 91.5 'roach-warren pt-units-33
                                                                  #:base-x 185.5 #:base-y 86.5))
                   (placement-preserves-base-exit-and-spawn? 188.5 91.5 'cybernetics-core pt-units-33
                                                             #:base-x 185.5 #:base-y 86.5)
                   (placement-preserves-base-exit-and-spawn? 188.5 91.5 'engineering-bay pt-units-33
                                                             #:base-x 185.5 #:base-y 86.5)
                   (placement-preserves-base-exit-and-spawn? 188.5 91.5 'barracks pt-units-33
                                                             #:base-x 185.5 #:base-y 86.5)
                   (placement-preserves-base-exit-and-spawn? 188.5 91.5 'gateway pt-units-33
                                                             #:base-x 185.5 #:base-y 86.5)))

  ;; L33-P0-1e: `barracks` with `0` existing Barracks spills over across ALL safe completed TownHalls
  ;; via `0.5t` pure `3x3` (skipping `319`) after `>= 2` placement misses!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-clear! SC2-TERRAN-5X3-MISS-CACHE)
  (hash-set! SC2-TERRAN-5X3-MISS-STREAK 'barracks 2)
  (let-values ([(ws rpc-cnt saw-319? cleanup!)
                (l33-start-mock-ws
                 (lambda (ab px py)
                   (if (and (= ab 321) (<= (l33-dist px py 68.5 30.5) 0.1)) 1 2)))])
    (define cc-m33 (mk-l33-u 13301 18 1 28.5 28.5 #:hp 1500.0 #:rad 2.75))
    (define cc-n33 (mk-l33-u 13302 18 1 64.5 30.5 #:hp 1500.0 #:rad 2.75))
    (define scv-33 (mk-l33-u 13303 45 1 63.0 29.0 #:hp 45.0 #:rad 0.375))
    (define nat-m33
      (for/list ([y (in-list '(27.5 29.5 31.5 33.5))] [i (in-naturals 0)])
        (mk-l33-u (+ 13310 i) 341 3 71.0 y #:hp 1000.0 #:rad 1.0 #:mins 1500)))
    (define g33-rax
      (sc2-game-info "L33RaxSpillMap" "" '() '(128 128) '(4 4 124 124)
                     (list (sc2-point2d 100.0 100.0)) w3-full-grid #f w3-full-grid))
    (define rax33-cmds
      (translate-bot-actions->sc2-raw-commands
       '((build barracks 32.0 30.0))
       (make-test-obs 22000 500 250 (append (list cc-m33 cc-n33 scv-33) nat-m33))
       #:ws-conn ws #:game-info g33-rax))
    (define rax33-cmd
      (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 321))) rax33-cmds))
    (define rax33-pt (and rax33-cmd (sc2-raw-unit-command-target-pos rax33-cmd)))
    (check-true "l33-p0-1e-barracks1-spills-over-05t-3x3-across-safe-ths-after-2-misses"
                (and (not (unbox saw-319?))
                     (= (unbox rpc-cnt) 2)
                     (sc2-point2d? rax33-pt)
                     (<= (l33-dist (sc2-point2d-x rax33-pt) (sc2-point2d-y rax33-pt) 68.5 30.5) 0.1)))
    (cleanup!))
  (hash-clear! SC2-TERRAN-5X3-MISS-STREAK))

;; =============================================================================
;; Loop 34 (`L34-P0-1`): Overlord Cliff-Edge P0 Freeze Fix + Unstarvable P1 Before
;; Urgent P0 + LabMineralField Main Clustering (Zero Fake 0-Mineral Expansion Pads)
;; =============================================================================
(printf "[Loop 34] Testing L34-P0-1 Overlord dead-airspace non-dispatch, AA-only 16f dead-air limit, >=12f P1-before-urgent-P0 + 8f dedup, & LabMineralField main clustering...\n")
(let ()
  (define (mk-l34-u tag utype alliance x y
                    #:hp [hp 100.0] #:rad [rad 1.0] #:flying? [fly? #f]
                    #:mins [mins 0] #:vesp [vesp 0])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 (if (= alliance 3) 0 2))
              (sc2-point3d x y (if fly? 12.0 8.0)) 0.0 rad 1.0 0 #f #f #f
              hp hp 0.0 0.0 0.0 0.0 mins vesp fly? #f #f #t #f
              '() 0 '() 0 0 0.0 0 0 0 0 '() 0 0))

  (define (l34-dist x1 y1 x2 y2)
    (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))

  ;; Build a 128x128 pathing grid with unpathable cliff-edge dead airspace for `x < 22`!
  (define l34-path-bytes (make-bytes (* 128 128) 1))
  (for* ([iy (in-range 128)]
         [ix (in-range 22)])
    (bytes-set! l34-path-bytes (+ ix (* iy 128)) 0))
  (define l34-path-grid (sc2-image-grid 8 128 128 l34-path-bytes #f #f))
  (define l34-gi
    (sc2-game-info "L34DeadAirMap" "" '() '(128 128) '(4 4 124 124)
                   (list (sc2-point2d 100.0 100.0)) l34-path-grid #f l34-path-grid))

  ;; L34-P0-1a: Enemy Overlord (106) hovering over unpathable dead airspace `(16.0, 28.5)` behind Main
  ;; CC `(28.5, 28.5)` MUST NOT dispatch idle Marauders/Medivacs via `base-threat`, AND an explicit
  ;; `(attack-unit ...)` targeting that Overlord MUST NOT escalate to `urgent-survival-cmd?` (P0)!
  (define cc-34a  (mk-l34-u 14001 18 1 28.5 28.5 #:hp 1500.0 #:rad 2.75))
  (define mar-34a (mk-l34-u 14002 51 1 31.0 28.5 #:hp 125.0 #:rad 0.5625)) ;; Marauder (ground-only)
  (define med-34a (mk-l34-u 14003 54 1 31.0 30.0 #:hp 150.0 #:rad 1.0 #:flying? #t)) ;; Medivac (non-AA)
  (define mrn-34a (mk-l34-u 14010 48 1 30.0 28.5 #:hp 45.0 #:rad 0.375)) ;; Marine (explicit attack-unit)
  (define ovl-34a (mk-l34-u 14099 106 4 16.0 28.5 #:hp 200.0 #:rad 1.0 #:flying? #t))
  (define cmds-34a
    (translate-bot-actions->sc2-raw-commands
     '((attack-unit 14010 14099))
     (make-test-obs 23000 500 200 (list cc-34a mar-34a med-34a mrn-34a ovl-34a))
     #:game-info l34-gi #:suppress-attack? #t))
  (define dead-air-dispatch-34a
    (ormap (lambda (c)
             (and (sc2-raw-unit-command? c)
                  (= (sc2-raw-unit-command-ability-id c) 23)
                  (sc2-point2d? (sc2-raw-unit-command-target-pos c))
                  (<= (l34-dist (sc2-point2d-x (sc2-raw-unit-command-target-pos c))
                                (sc2-point2d-y (sc2-raw-unit-command-target-pos c))
                                16.0 28.5)
                      1.0)))
           cmds-34a))
  (define ovl-atk-34a
    (findf (lambda (c) (and (sc2-raw-unit-command? c)
                            (= (sc2-raw-unit-command-ability-id c) 23)
                            (= (sc2-raw-unit-command-target-unit-tag c) 14099)))
           cmds-34a))
  (check-true "l34-p0-1a-overlord-dead-airspace-never-dispatches-ground-or-escalates-p0"
              (and (not dead-air-dispatch-34a)
                   (sc2-raw-unit-command? ovl-atk-34a)
                   (not (urgent-survival-cmd? ovl-atk-34a))
                   (= (wire-cmd-priority-tier ovl-atk-34a) 2)))

  ;; L34-P0-1b: Real flying combat `base-threat` (Banshee 55) over unpathable dead airspace `(20.0, 28.5)`:
  ;; dispatches ONLY AA-capable `marine (48)` (NEVER `marauder (51)` or `medivac (54)`!), keeps it
  ;; non-urgent (`P2`), and enforces >= 16f per-tile cooldown (`23100` emits, `23108` skipped, `23116` emits)!
  (define cc-34b  (mk-l34-u 14101 18 1 28.5 28.5 #:hp 1500.0 #:rad 2.75))
  (define mrn-34b (mk-l34-u 14102 48 1 26.0 28.5 #:hp 45.0 #:rad 0.375))  ;; AA Marine (`6t` from Banshee)
  (define mar-34b (mk-l34-u 14103 51 1 26.0 29.5 #:hp 125.0 #:rad 0.5625)) ;; Ground-only Marauder
  (define med-34b (mk-l34-u 14104 54 1 26.0 30.5 #:hp 150.0 #:rad 1.0 #:flying? #t)) ;; Non-AA Medivac
  (define ban-34b (mk-l34-u 14199 55 4 20.0 28.5 #:hp 140.0 #:rad 0.75 #:flying? #t))
  (define (run-34b loop)
    (translate-bot-actions->sc2-raw-commands
     '()
     (make-test-obs loop 500 200 (list cc-34b mrn-34b mar-34b med-34b ban-34b))
     #:game-info l34-gi #:suppress-attack? #t))
  (define (find-bt-23 cmds)
    (findf (lambda (c)
             (and (sc2-raw-unit-command? c)
                  (= (sc2-raw-unit-command-ability-id c) 23)
                  (sc2-point2d? (sc2-raw-unit-command-target-pos c))
                  (<= (l34-dist (sc2-point2d-x (sc2-raw-unit-command-target-pos c))
                                (sc2-point2d-y (sc2-raw-unit-command-target-pos c))
                                20.0 28.5)
                      1.0)))
           cmds))
  (define bt-23100 (find-bt-23 (run-34b 23100)))
  (define bt-23108 (find-bt-23 (run-34b 23108)))
  (define bt-23116 (find-bt-23 (run-34b 23116)))
  (check-true "l34-p0-1b-flying-base-threat-aa-only-and-16f-dead-airspace-cooldown"
              (and (sc2-raw-unit-command? bt-23100)
                   (equal? (sc2-raw-unit-command-unit-tags bt-23100) '(14102))
                   (not (urgent-survival-cmd? bt-23100))
                   (not bt-23108)
                   (sc2-raw-unit-command? bt-23116)
                   (equal? (sc2-raw-unit-command-unit-tags bt-23116) '(14102))))

  ;; L34-P0-1c: `8f` repeat dedup on identical `urgent-survival-cmd?` combat `23`/`16`, AND
  ;; `240`-loop continuous `urgent-survival-cmd?` `P0` spam NEVER starves overdue `P1` macro
  ;; (`1a-pre` rescues `>= 12` loops stale P1 BEFORE `1a` `p0-urgent-cmds` with `tok=-4.0, hr=0.0`!)!
  (define gov-34d (make-wire-apm-governor #:target-apm 410.0 #:hard-cap-apm 485.0))
  (define urg-dedup-loops
    (for/list ([gl (in-list '(100 102 104 106 108))]
               #:when (pair? (govern-sc2-wire-actions!
                              gov-34d
                              (list (mark-urgent-survival-cmd!
                                     (sc2-raw-unit-command 23 (sc2-point2d 16.0 152.0) 0 '(14201 14202) #f)))
                              gl)))
      gl))
  (define gov-34s (make-wire-apm-governor #:target-apm 410.0 #:hard-cap-apm 485.0))
  (define p1-cnt-34s 0)
  (define p1-kinds-34s (mutable-seteqv))
  (define max-p1-gap-34s 0)
  (define last-p1-34s 1000)
  (define ev-win-34s '())
  (define peak-ev-34s 0)
  (define sel-34s #f)
  (for ([step-i (in-range 0 65)])
    (define gl (+ 1000 (* step-i 4)))
    ;; Spam 12 unique urgent-survival P0 commands EVERY step!
    (define urg-spam
      (for/list ([k (in-range 12)])
        (mark-urgent-survival-cmd!
         (sc2-raw-unit-command 23 (sc2-point2d (+ 20.0 (* 0.5 k)) (+ 20.0 step-i)) 0
                               (list (+ 14300 (* step-i 16) k)) #f))))
    (define base-m
      (list (sc2-raw-unit-command 171 #f 9001 (list (+ 14900 (modulo step-i 3))) #f)
            (sc2-raw-unit-command 524 #f 0 (list (+ 14910 (modulo step-i 3))) #f)
            (sc2-raw-unit-command 560 #f 0 (list (+ 14920 (modulo step-i 4))) #f)
            (sc2-raw-unit-command 321 (sc2-point2d 34.5 34.5) 0 (list (+ 14930 (modulo step-i 4))) #f)))
    (define rot (modulo (quotient step-i 3) 4))
    (define m-batch (append (drop base-m rot) (take base-m rot)))
    (define out (govern-sc2-wire-actions! gov-34s (append urg-spam m-batch) gl))
    (define saw-p1? #f)
    (for ([c (in-list out)] #:when (sc2-raw-unit-command? c))
      (define ab (sc2-raw-unit-command-ability-id c))
      (define tags (sc2-raw-unit-command-unit-tags c))
      (define cost (if (and sel-34s (equal? tags sel-34s)) 1 2))
      (set! sel-34s tags)
      (set! ev-win-34s (cons (cons gl cost) ev-win-34s))
      (when (memv ab '(171 524 560 321))
        (set! saw-p1? #t)
        (set! p1-cnt-34s (add1 p1-cnt-34s))
        (set-add! p1-kinds-34s ab)))
    (set! ev-win-34s (filter (lambda (e) (> (car e) (- gl 1344))) ev-win-34s))
    (set! peak-ev-34s (max peak-ev-34s (for/sum ([e (in-list ev-win-34s)]) (cdr e))))
    (if saw-p1?
        (begin
          (set! max-p1-gap-34s (max max-p1-gap-34s (- gl last-p1-34s)))
          (set! last-p1-34s gl))
        (set! max-p1-gap-34s (max max-p1-gap-34s (- gl last-p1-34s)))))
  (check-true (format "l34-p0-1c-urgent-p0-spam-never-starves-p1-and-8f-dedups-combat (dedup=~a p1=~a kinds=~a gap=~a ev=~a)"
                      urg-dedup-loops p1-cnt-34s (set-count p1-kinds-34s) max-p1-gap-34s peak-ev-34s)
              (and (equal? urg-dedup-loops '(100 108))
                   (>= p1-cnt-34s 20)
                   (= (set-count p1-kinds-34s) 4)
                   (<= max-p1-gap-34s 16)
                   (<= peak-ev-34s 485)))

  ;; L34-P0-1d: `LabMineralField` (665) / `LabMineralField750` (666) + 2 `SpacePlatformGeyser` (343)
  ;; main-base clustering produces 0 fake 0-mineral geyser-only pads, clusters Main cleanly, filters
  ;; `mineral-field-450` (1996) wall blockers, enforces 16.0t non-main distance, and ranks real Natural #1!
  (define map-w 192)
  (define map-h 168)
  (define full-192 (sc2-image-grid 8 map-w map-h (make-bytes (* map-w map-h) 1) #f #f))
  (define th-192 (sc2-image-grid 8 map-w map-h (make-bytes (* map-w map-h) 160) #f #f))
  (define gi-lab
    (sc2-game-info "L34LabMinMainMap" "" '() (cons map-w map-h) (hash 'x0 4 'y0 4 'x1 188 'y1 164)
                   (list (sc2-point2d 42.5 40.5)) full-192 th-192 full-192))
  (define (mk-lab-cluster tag0 px py mtype1 mtype2 gtype)
    (append
     (for/list ([k (in-range 8)])
       (define mt (if (even? k) mtype1 mtype2))
       (define mc (if (even? k) 1800 900))
       (mk-l34-u (+ tag0 k) mt 3 (+ px 6.5) (+ (- py 3.5) (* 1.0 k)) #:rad 1.125 #:mins mc))
     (list (mk-l34-u (+ tag0 10) gtype 3 (- px 1.0) (- py 7.0) #:rad 1.5 #:vesp 2250)
           (mk-l34-u (+ tag0 11) gtype 3 (- px 1.0) (+ py 7.0) #:rad 1.5 #:vesp 2250))))
  (define lab-neutrals
    (append
     ;; Top-Right Main `(155.5, 133.5)`: 8 LabMineralField / LabMineralField750 + 2 SpacePlatformGeysers
     (mk-lab-cluster 15100 155.5 133.5 665 666 343)
     ;; MineralField450 blockers (must be excluded!)
     (list (mk-l34-u 15150 1996 3 140.0 120.0 #:rad 1.125 #:mins 450)
           (mk-l34-u 15151 1996 3 141.0 120.0 #:rad 1.125 #:mins 450))
     ;; Two stray orphan geysers (`0` minerals!) at `(144, 143)` (`14.8t` from Main — must produce 0 fake pads!)
     (list (mk-l34-u 15160 343 3 144.0 140.0 #:rad 1.5 #:vesp 2250)
           (mk-l34-u 15161 343 3 144.0 146.0 #:rad 1.5 #:vesp 2250))
     ;; Real Natural at `(157.5, 104.5)` (`29.1t` South of Main)
     (mk-lab-cluster 15200 157.5 104.5 341 483 343)
     ;; Third base at `(116.5, 133.5)` (`39.0t` West of Main)
     (mk-lab-cluster 15300 116.5 133.5 341 483 343)))
  (define lab-bases (solve-all-map-expansion-bases lab-neutrals gi-lab))
  (define lab-ordered (order-expansions-from-origin lab-bases 155.5 133.5 full-192 lab-neutrals))
  (define no-zero-min-pads?
    (for/and ([b (in-list lab-bases)])
      (>= (length (hash-ref b 'minerals '())) 4)))
  (define main-clustered?
    (ormap (lambda (b)
             (and (<= (l34-dist (hash-ref b 'x) (hash-ref b 'y) 155.5 133.5) 3.0)
                  (= (length (hash-ref b 'minerals '())) 8)
                  (= (length (hash-ref b 'geysers '())) 2)))
           lab-bases))
  (define first-nat (and (pair? lab-ordered) (first lab-ordered)))
  (check-true "l34-p0-1d-lab-mineral-field-main-0-fake-geyser-pads-and-ranks-real-natural-first"
              (and (= (length lab-bases) 3)
                   no-zero-min-pads?
                   main-clustered?
                   (hash? first-nat)
                   (<= (l34-dist (hash-ref first-nat 'x) (hash-ref first-nat 'y) 157.5 104.5) 3.0))))

;; =============================================================================
;; Loop 35 (`L35-P0-1`): Persistent 224f Addon-Blocked Cache + 2x2 Creep Check +
;; Unchanged-State Exponential Backoff (`24f->64f->168f` P0 / `24f->96f->224f` P1
;; Demotion) & Late-Game Wire Micro-Perf
;; =============================================================================
(printf "[Loop 35] Testing L35-P0-1 persistent 224f addon cache, 2x2 creep pad guard, unchanged-state P0/P1 backoff & demotion...\n")
(let ()
  (define (mk-l35-u tag utype alliance x y
                    #:hp [hp 500.0] #:rad [rad 1.5] #:flying? [fly? #f]
                    #:orders [ords '()] #:addon [addon 0])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 (if (= alliance 3) 0 2))
              (sc2-point3d x y (if fly? 12.0 8.0)) 0.0 rad 1.0 0 #f #f #f
              hp hp 0.0 0.0 0.0 0.0 0 0 fly? #f #f #t #f
              ords addon '() 0 0 0.0 0 0 0 0 '() 0 0))

  (define map-w 128)
  (define map-h 128)
  (define pl-128 (sc2-image-grid 8 map-w map-h (make-bytes (* map-w map-h) 1) #f #f))
  (define th-128 (sc2-image-grid 8 map-w map-h (make-bytes (* map-w map-h) 160) #f #f))
  (define gi-128
    (sc2-game-info "L35TestMap" "" '() (cons map-w map-h) (hash 'x0 4 'y0 4 'x1 124 'y1 124)
                   (list (sc2-point2d 100.0 100.0)) pl-128 th-128 pl-128))

  (define (l35-start-mock-ws decide-fn)
    (define-values (c-in s-out) (make-pipe))
    (define-values (s-in c-out) (make-pipe))
    (define ws (sc2-ws-conn "127.0.0.1" 59935 "/sc2api" c-in c-out #f 1))
    (define rpc-cnt (box 0))
    (define th
      (thread
       (lambda ()
         (let lp ()
           (define b0 (read-byte s-in))
           (unless (eof-object? b0)
             (define b1 (read-byte s-in))
             (define masked? (not (zero? (bitwise-and b1 #x80))))
             (define len0 (bitwise-and b1 #x7F))
             (define plen
               (cond [(< len0 126) len0]
                     [(= len0 126) (integer-bytes->integer (read-bytes 2 s-in) #f #t)]
                     [else (integer-bytes->integer (read-bytes 8 s-in) #f #t)]))
             (define mkey (if masked? (read-bytes 4 s-in) #f))
             (define raw (read-bytes plen s-in))
             (define payload
               (if masked?
                   (let ([out (make-bytes plen)])
                     (for ([i (in-range plen)])
                       (bytes-set! out i (bitwise-xor (bytes-ref raw i) (bytes-ref mkey (modulo i 4)))))
                     out)
                   raw))
             (define req-f (decode-protobuf-message payload))
             (define id-p (assoc 97 req-f))
             (define id-b (if id-p (encode-uint32 97 (third id-p)) #""))
             (define q-p (assoc 14 req-f))
             (when q-p
               (set-box! rpc-cnt (add1 (unbox rpc-cnt)))
               (define qf (decode-protobuf-message (third q-p)))
               (define p-items (filter (lambda (e) (= (first e) 3)) qf))
               (define res-b
                 (apply bytes-append
                        (for/list ([it (in-list p-items)])
                          (define itf (decode-protobuf-message (third it)))
                          (define ab (let ([p (assoc 1 itf)]) (if p (third p) 0)))
                          (define tp-e (assoc 2 itf))
                          (define-values (px py)
                            (if tp-e
                                (let ([ptf (decode-protobuf-message (third tp-e))])
                                  (values (let ([xp (assoc 1 ptf)])
                                            (if (and xp (bytes? (third xp)))
                                                (floating-point-bytes->real (third xp) #f)
                                                0.0))
                                          (let ([yp (assoc 2 ptf)])
                                            (if (and yp (bytes? (third yp)))
                                                (floating-point-bytes->real (third yp) #f)
                                                0.0))))
                                (values 0.0 0.0)))
                          (encode-submessage-field 3 (encode-int32 1 (decide-fn ab px py))))))
               (define resp (bytes-append (encode-submessage-field 14 res-b) id-b (encode-int32 99 3)))
               (define rlen (bytes-length resp))
               (define rhdr
                 (cond [(< rlen 126) (bytes #x82 rlen)]
                       [(<= rlen 65535) (bytes-append (bytes #x82 126) (integer->integer-bytes rlen 2 #f #t))]
                       [else (bytes-append (bytes #x82 127) (integer->integer-bytes rlen 8 #f #t))]))
               (write-bytes rhdr s-out)
               (write-bytes resp s-out)
               (flush-output s-out))
             (lp))))))
    (values ws rpc-cnt (lambda () (close-output-port c-out) (close-input-port c-in) (thread-wait th))))

  ;; L35-P0-1a: `SC2-ADDON-SLOT-BLOCKED-CACHE` survives unrelated structure completions/deaths
  ;; for 224f, and clears immediately when that specific facility lifts off!
  (hash-clear! SC2-ADDON-SLOT-BLOCKED-CACHE)
  (define cc-35a (mk-l35-u 15000 18 1 28.5 28.5 #:hp 1500.0 #:rad 2.75))
  (define sp-35a (mk-l35-u 15001 28 1 40.5 40.5 #:hp 1300.0 #:rad 1.5))
  (define dp-35a (mk-l35-u 15002 19 1 32.5 34.5 #:hp 400.0 #:rad 1.0))
  (hash-set! SC2-ADDON-SLOT-BLOCKED-CACHE '(15001 40 40) 24000)
  (let-values ([(ws _rc cleanup!) (l35-start-mock-ws (lambda (_ab _px _py) 1))])
    ;; Unrelated structure completion changes `cur-struct-sig`: must NOT clear `SC2-ADDON-SLOT-BLOCKED-CACHE`!
    (void (find-verified-building-placement ws 319 30.0 30.0 (list cc-35a sp-35a)
                                            #:game-info gi-128 #:cur-loop 24010))
    (void (find-verified-building-placement ws 319 30.0 30.0 (list cc-35a sp-35a dp-35a)
                                            #:game-info gi-128 #:cur-loop 24016))
    (cleanup!))
  (define obs-35a-still
    (make-test-obs 24120 400 200 (list cc-35a sp-35a dp-35a)))
  (define h-35a-still (sc2-observation->runtime-obs-hash obs-35a-still #:game-info gi-128))
  (define still-blocked-at-120f?
    (and (hash-has-key? SC2-ADDON-SLOT-BLOCKED-CACHE '(15001 40 40))
         (and (memv 15001 (hash-ref h-35a-still 'addon-blocked-facility-ids '())) #t)))
  ;; Lift Starport `15001` (`is-flying = #t`) -> immediately clears its blocked-slot entry!
  (define sp-35a-fly (mk-l35-u 15001 44 1 40.5 40.5 #:hp 1300.0 #:rad 1.5 #:flying? #t))
  (define obs-35a-lift
    (make-test-obs 24124 400 200 (list cc-35a sp-35a-fly dp-35a)))
  (define h-35a-lift (sc2-observation->runtime-obs-hash obs-35a-lift #:game-info gi-128))
  (define cleared-on-lift?
    (and (not (hash-has-key? SC2-ADDON-SLOT-BLOCKED-CACHE '(15001 40 40)))
         (not (memv 15001 (hash-ref h-35a-lift 'addon-blocked-facility-ids '())))))
  (check-true "l35-p0-1a-addon-blocked-cache-persists-224f-across-unrelated-structs-and-clears-on-lift"
              (and still-blocked-at-120f? cleared-on-lift?))

  ;; L35-P0-1b: `2x2` Terran addon pad `(+2.5, -0.5)` on Zerg Creep NEVER emits an in-place
  ;; addon order (`target-pos = #f`); it relocates to a creep-free pad or backs off cleanly!
  (hash-clear! SC2-ADDON-SLOT-BLOCKED-CACHE)
  (define creep-east-bytes (make-bytes (* map-w map-h) 0))
  (for* ([iy (in-range map-h)]
         [ix (in-range 42 map-w)])
    (bytes-set! creep-east-bytes (+ ix (* iy map-w)) 1))
  (define creep-east-grid (sc2-image-grid 8 map-w map-h creep-east-bytes #f #f))
  (define creep-all-grid (sc2-image-grid 8 map-w map-h (make-bytes (* map-w map-h) 1) #f #f))
  (define sp-35b (mk-l35-u 15101 28 1 40.5 40.5 #:hp 1300.0 #:rad 1.5)) ;; addon center `(43.0, 40.0)` ON creep!
  (define obs-35b-reloc (make-test-obs 24200 400 200 (list cc-35a sp-35b)))
  (hash-set! SC2-OBS-CREEP-GRIDS obs-35b-reloc creep-east-grid)
  (define cmds-35b-reloc
    (translate-bot-actions->sc2-raw-commands
     '((build starport-techlab 40.5 40.5))
     obs-35b-reloc #:game-info gi-128))
  (define cmd-35b-reloc
    (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 487)))
           cmds-35b-reloc))
  (define relocated-off-creep?
    (and (sc2-raw-unit-command? cmd-35b-reloc)
         (sc2-point2d? (sc2-raw-unit-command-target-pos cmd-35b-reloc))
         (< (+ (sc2-point2d-x (sc2-raw-unit-command-target-pos cmd-35b-reloc)) 2.5) 42.0)))
  ;; When ALL map tiles have creep, emits ZERO doomed in-place `487` commands!
  (hash-clear! SC2-ADDON-SLOT-BLOCKED-CACHE)
  (define sp-35b2 (mk-l35-u 15102 28 1 40.5 40.5 #:hp 1300.0 #:rad 1.5))
  (define obs-35b-all (make-test-obs 24210 400 200 (list cc-35a sp-35b2)))
  (hash-set! SC2-OBS-CREEP-GRIDS obs-35b-all creep-all-grid)
  (define cmds-35b-all
    (translate-bot-actions->sc2-raw-commands
     '((build starport-techlab 40.5 40.5))
     obs-35b-all #:game-info gi-128))
  (define no-doomed-inplace-on-creep?
    (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 487)))
                cmds-35b-all)))
  (check-true "l35-p0-1b-terran-addon-2x2-creep-check-blocks-inplace-and-relocates-off-creep"
              (and relocated-off-creep? no-doomed-inplace-on-creep?))

  ;; L35-P0-1c: Unchanged-state exponential backoff in `govern-sc2-wire-actions!`:
  ;; (1) Exact standalone schedule: P1 addon `487` (`24f->96f->224f`) & P0 mode `388` (`24f->64f->168f`);
  ;; (2) Contested 240-loop stream: blocked Starport `487` + SiegeTank `388` NEVER starve real P1 macro
  ;;     (`171`/`524`/`560`/`321`) or burn `485` APM, AND reset immediately when unit state changes!
  (define sp-stuck (mk-l35-u 15201 28 1 40.5 40.5 #:hp 1300.0 #:rad 1.5))
  (define tk-stuck (mk-l35-u 15202 33 1 50.5 50.5 #:hp 175.0 #:rad 0.875))
  (define gov-35c-sched (make-wire-apm-governor #:target-apm 410.0 #:hard-cap-apm 485.0))
  (define sched-sp-loops '())
  (define sched-tk-loops '())
  (for ([gl (in-range 13000 13360 4)])
    (define ob (make-test-obs gl 2700 800 (list cc-35a sp-stuck tk-stuck)))
    (define out (govern-sc2-wire-actions!
                 gov-35c-sched
                 (list (sc2-raw-unit-command 487 #f 0 '(15201) #f)
                       (sc2-raw-unit-command 388 #f 0 '(15202) #f))
                 gl ob))
    (for ([c (in-list out)] #:when (sc2-raw-unit-command? c))
      (when (= (sc2-raw-unit-command-ability-id c) 487) (set! sched-sp-loops (cons gl sched-sp-loops)))
      (when (= (sc2-raw-unit-command-ability-id c) 388) (set! sched-tk-loops (cons gl sched-tk-loops)))))
  (define sched-sp-chron (reverse sched-sp-loops))
  (define sched-tk-chron (reverse sched-tk-loops))
  (define gov-35c (make-wire-apm-governor #:target-apm 410.0 #:hard-cap-apm 485.0))
  (define sp-emit-loops '())
  (define tk-emit-loops '())
  (define macro-cnt-35c 0)
  (define macro-kinds-35c (mutable-seteqv))
  (define max-p1-gap-35c 0)
  (define last-p1-35c 13000)
  (define ev-win-35c '())
  (define peak-ev-35c 0)
  (define sel-35c #f)
  (for ([step-i (in-range 0 61)]) ;; 240 loops (`13000..13240`)
    (define gl (+ 13000 (* step-i 4)))
    (define obs-st (make-test-obs gl 2700 800 (list cc-35a sp-stuck tk-stuck)))
    (define sp-cmd (sc2-raw-unit-command 487 #f 0 '(15201) #f))
    (define tk-cmd (sc2-raw-unit-command 388 #f 0 '(15202) #f))
    (define base-m
      (list (sc2-raw-unit-command 171 #f 9001 (list (+ 15900 (modulo step-i 3))) #f)
            (sc2-raw-unit-command 524 #f 0 (list (+ 15910 (modulo step-i 3))) #f)
            (sc2-raw-unit-command 560 #f 0 (list (+ 15920 (modulo step-i 4))) #f)
            (sc2-raw-unit-command 321 (sc2-point2d 34.5 34.5) 0 (list (+ 15930 step-i)) #f)))
    (define rot (modulo step-i 4))
    (define m-batch (append (drop base-m rot) (take base-m rot)))
    (define p2-noise
      (for/list ([k (in-range 6)])
        (sc2-raw-unit-command 23 (sc2-point2d (+ 60.0 k) (+ 60.0 (modulo step-i 10))) 0
                              (list (+ 15500 (* step-i 8) k)) #f)))
    ;; Place blocked Starport `487` FIRST in input batch — backoff & demotion must prevent starvation!
    (define out (govern-sc2-wire-actions! gov-35c (append (list sp-cmd tk-cmd) m-batch p2-noise) gl obs-st))
    (define saw-real-p1? #f)
    (for ([c (in-list out)] #:when (sc2-raw-unit-command? c))
      (define ab (sc2-raw-unit-command-ability-id c))
      (define tags (sc2-raw-unit-command-unit-tags c))
      (define cost (if (and sel-35c (equal? tags sel-35c)) 1 2))
      (set! sel-35c tags)
      (set! ev-win-35c (cons (cons gl cost) ev-win-35c))
      (when (= ab 487) (set! sp-emit-loops (cons gl sp-emit-loops)))
      (when (= ab 388) (set! tk-emit-loops (cons gl tk-emit-loops)))
      (when (memv ab '(171 524 560 321))
        (set! saw-real-p1? #t)
        (set! macro-cnt-35c (add1 macro-cnt-35c))
        (set-add! macro-kinds-35c ab)))
    (set! ev-win-35c (filter (lambda (e) (> (car e) (- gl 1344))) ev-win-35c))
    (set! peak-ev-35c (max peak-ev-35c (for/sum ([e (in-list ev-win-35c)]) (cdr e))))
    (if saw-real-p1?
        (begin
          (set! max-p1-gap-35c (max max-p1-gap-35c (- gl last-p1-35c)))
          (set! last-p1-35c gl))
        (set! max-p1-gap-35c (max max-p1-gap-35c (- gl last-p1-35c)))))
  (define sp-loops-chron (reverse sp-emit-loops))
  (define tk-loops-chron (reverse tk-emit-loops))
  ;; Once Siege Tank actually changes state (starts order 16 / moves), backoff resets cleanly!
  (define tk-moved (mk-l35-u 15202 33 1 52.0 52.0 #:hp 175.0 #:rad 0.875
                             #:orders (list (sc2-unit-order 16 (sc2-point3d 55.0 55.0 8.0) 0 0.0))))
  (define out-tk-reset
    (govern-sc2-wire-actions! gov-35c-sched
                              (list (sc2-raw-unit-command 388 #f 0 '(15202) #f))
                              13364
                              (make-test-obs 13364 2700 800 (list cc-35a sp-stuck tk-moved))))
  (define tk-reset-ok?
    (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 388)))
           out-tk-reset))
  (check-true (format "l35-p0-1c-unchanged-p0-p1-backoff-never-starves-macro (sched-sp=~a sched-tk=~a sp=~a tk=~a p1=~a kinds=~a gap=~a ev=~a rst=~a)"
                      sched-sp-chron sched-tk-chron sp-loops-chron tk-loops-chron
                      macro-cnt-35c (set-count macro-kinds-35c) max-p1-gap-35c peak-ev-35c tk-reset-ok?)
              (and (equal? sched-sp-chron '(13000 13024 13120 13344))
                   (equal? sched-tk-chron '(13000 13024 13088 13256))
                   (<= (length sp-loops-chron) 3)
                   (<= (length tk-loops-chron) 3)
                   (>= macro-cnt-35c 40)
                   (= (set-count macro-kinds-35c) 4)
                   (<= max-p1-gap-35c 16)
                   (<= peak-ev-35c 485)
                   tk-reset-ok?))

  ;; L35-P0-1d: Even when the blocked Starport is STILL `cur-sel` (selection affinity), its demoted
  ;; P1 retry yields strictly behind fresh Train/SCV macro in Step `1a-pre`!
  (define gov-35d (make-wire-apm-governor #:target-apm 410.0 #:hard-cap-apm 485.0))
  (define sp-sel (mk-l35-u 15301 28 1 40.5 40.5 #:hp 1300.0 #:rad 1.5))
  (define obs-35d0 (make-test-obs 14000 600 200 (list cc-35a sp-sel)))
  ;; Emit once at `14000` so streak = 1 (`tokens: 24.0 -> 22.0`).
  (void (govern-sc2-wire-actions! gov-35d
                                  (list (sc2-raw-unit-command 487 #f 0 '(15301) #f))
                                  14000 obs-35d0))
  ;; At `14016` (`+4.88 -> 26.88`), drain 14 unique cmds (`28 ev -> -1.12`) + 1 cmd on `'(15301)`
  ;; (`2 ev -> -3.12`, setting `cur-sel = '(15301)`).
  (void (govern-sc2-wire-actions!
         gov-35d
         (append
          (for/list ([k (in-range 14)])
            (mark-urgent-survival-cmd!
             (sc2-raw-unit-command 407 #f 15999 (list (+ 15400 k)) #f)))
          (list (mark-urgent-survival-cmd!
                 (sc2-raw-unit-command 407 #f 15999 '(15301) #f))))
         14016 obs-35d0))
  ;; At `14020` (`+1.22 -> -1.90`), emit 1 same-selection urgent cmd on `'(15301)` (`1 ev -> -2.90`).
  ;; At `14024` (`+1.22 -> -1.68`, `cur-sel = '(15301)`, `24f` retry window!), room for ONLY ONE
  ;; new-selection 2-event cmd (`-1.68 - 2.0 = -3.68 >= -4.0`): fresh `560` MUST beat demoted `487`!
  (void (govern-sc2-wire-actions!
         gov-35d
         (list (mark-urgent-survival-cmd!
                (sc2-raw-unit-command 407 #f 15999 '(15301) #f)))
         14020 obs-35d0))
  (define obs-35d1 (make-test-obs 14024 600 200 (list cc-35a sp-sel)))
  (define out-35d
    (govern-sc2-wire-actions!
     gov-35d
     (list (sc2-raw-unit-command 487 #f 0 '(15301) #f)
           (sc2-raw-unit-command 560 #f 0 '(15310) #f))
     14024 obs-35d1))
  (check-true "l35-p0-1d-demoted-p1-addon-yields-to-fresh-macro-even-when-selected"
              (and (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 560)))
                          out-35d)
                   (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 487)))
                               out-35d)))))

;; =============================================================================
;; Loop 36 (`L36-P0-1`): Bot Build Version Stamping (`BuildVersion`/`BuildTimestampUtc`),
;; `[SCBOT_BUILD]` Banner + `0`-APM Team-Only `Tag:v_<rev>` Chat Emission Once/Match,
;; & Spawn-Symmetric Front-of-Hatchery Spine Crawler Placement
;; =============================================================================
(printf "[Loop 36] Testing L36-P0-1 BuildVersion stamp/load, 0-APM team-only Tag:v_<rev> once/match, & front-of-Hatchery Spine placement...\n")
(let ()
  ;; L36-P0-1a: `detect-build-version-metadata`, `build-bot-config-json-bytes`, `load-bot-build-metadata`
  ;; (`bot_config.json` & `config.json` zip mode + `MOTHMAN_BUILD_VERSION` source fallback) & `[SCBOT_BUILD]` banner!
  (define-values (det-ver det-ts) (detect-build-version-metadata))
  (define cfg-bstr
    (build-bot-config-json-bytes "Mothman-Z" "Zerg" "bots/Mothman-Z.rkt"
                                 #:build-version "abcd1234_9876fedc"
                                 #:build-timestamp-utc "2026-11-20T18:35:00Z"))
  (define cfg-j (bytes->jsexpr cfg-bstr))
  (define tmp-dir-a (make-temporary-file "mothman-l36-cfg-~a" 'directory))
  (define tmp-dir-b (make-temporary-file "mothman-l36-src-~a" 'directory))
  (define prev-env (getenv "MOTHMAN_BUILD_VERSION"))
  (define meta-zip #f)
  (define meta-src #f)
  (define banner-zip "")
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file (build-path tmp-dir-a "bot_config.json")
        #:exists 'replace
        (lambda (out) (write-bytes cfg-bstr out)))
      (set! meta-zip (load-bot-build-metadata #:root-dir tmp-dir-a))
      (set! banner-zip (format-bot-build-banner meta-zip 'Zerg))
      (putenv "MOTHMAN_BUILD_VERSION" "src12345_cafe9999")
      (set! meta-src (load-bot-build-metadata #:root-dir tmp-dir-b)))
    (lambda ()
      (if prev-env
          (putenv "MOTHMAN_BUILD_VERSION" prev-env)
          (putenv "MOTHMAN_BUILD_VERSION" ""))
      (with-handlers ([exn:fail? void]) (delete-directory/files tmp-dir-a))
      (with-handlers ([exn:fail? void]) (delete-directory/files tmp-dir-b))))
  (check-true "l36-p0-1a-build-version-stamp-config-load-and-scbot-build-banner"
              (and (string? det-ver)
                   (> (string-length det-ver) 0)
                   (regexp-match? #px"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$" det-ts)
                   (equal? (hash-ref cfg-j 'BuildVersion #f) "abcd1234_9876fedc")
                   (equal? (hash-ref cfg-j 'BuildTimestampUtc #f) "2026-11-20T18:35:00Z")
                   (equal? (hash-ref meta-zip 'version #f) "abcd1234_9876fedc")
                   (eq? (hash-ref meta-zip 'mode #f) 'zip)
                   (equal? banner-zip "[SCBOT_BUILD] bot=Mothman-Z race=Zerg version=abcd1234_9876fedc mode=zip")
                   (equal? (hash-ref meta-src 'version #f) "src12345_cafe9999")
                   (eq? (hash-ref meta-src 'mode #f) 'source)))

  ;; L36-P0-1b / L37-P0-3: `0`-APM Broadcast `(sc2-chat-action 1 "Tag:v_<rev>")` emits ONCE per match
  ;; at frame `~24` (captured in `.SC2Replay` on 100% of wins AND losses!), passes through
  ;; `govern-sc2-wire-actions!` even at drained `-4.0` tokens with `0` APM cost, encodes cleanly via
  ;; `encode-sc2-action` with `team? = #f` (Broadcast channel 1), and re-emits once after a match rewind!
  (define (mk-l36-u tag utype alliance x y #:hp [hp 100.0] #:rad [rad 1.0] #:mins [mins 0])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 (if (= alliance 3) 0 2))
              (sc2-point3d x y 8.0) 0.0 rad 1.0 0 #f #f #f
              hp hp 0.0 0.0 0.0 0.0 mins 0 #f #f #f #t #f
              '() 0 '() 0 0 0.0 0 0 0 0 '() 0 0))
  (define h-36b (mk-l36-u 16001 86 1 32.5 32.5 #:hp 1500.0 #:rad 2.75))
  (define d-36b (mk-l36-u 16002 104 1 31.0 31.0 #:hp 40.0 #:rad 0.375))
  (reset-bot-build-version-cache!)
  (define (chat-cmds-at lp)
    (filter sc2-chat-action?
            (translate-bot-actions->sc2-raw-commands
             '() (make-test-obs lp 50 0 (list h-36b d-36b)))))
  (define chats-0   (chat-cmds-at 0))
  (define chats-12  (chat-cmds-at 12))
  (define chats-24  (chat-cmds-at 24))
  (define chats-28  (chat-cmds-at 28))
  (define chats-100 (chat-cmds-at 100))
  ;; Match rewind to loop 0 -> loop 24 re-emits once for the new match!
  (define chats-rw0  (chat-cmds-at 0))
  (define chats-rw24 (chat-cmds-at 24))
  (define tag-act (and (= (length chats-24) 1) (first chats-24)))
  ;; Verify 0-APM governor emission even when tokens are drained to `-4.0`
  (define gov-36b (make-wire-apm-governor #:target-apm 410.0 #:hard-cap-apm 485.0))
  (void (govern-sc2-wire-actions!
         gov-36b
         (for/list ([k (in-range 16)])
           (mark-urgent-survival-cmd!
            (sc2-raw-unit-command 23 (sc2-point2d (+ 20.0 k) 20.0) 0 (list (+ 16100 k)) #f)))
         20))
  (define gov-tag-out (govern-sc2-wire-actions! gov-36b (list tag-act) 24))
  (define drops-before (get-total-wire-action-drop-count))
  (define enc-tag (and tag-act (encode-sc2-action tag-act)))
  (define dec-tag (and (bytes? enc-tag) (decode-typed-sc2-action enc-tag)))
  (define drops-after (get-total-wire-action-drop-count))
  (check-true "l36-p0-1b-zero-apm-broadcast-tag-emits-once-per-match-and-resets-on-rewind"
              (and (null? chats-0)
                   (null? chats-12)
                   (= (length chats-24) 1)
                   (null? chats-28)
                   (null? chats-100)
                   (null? chats-rw0)
                   (= (length chats-rw24) 1)
                   (sc2-chat-action? tag-act)
                   (= (sc2-chat-action-channel tag-act) 1)
                   (string-prefix? (sc2-chat-action-message tag-act) "Tag:v_")
                   (= (wire-cmd-priority-tier tag-act) 0)
                   (equal? gov-tag-out (list tag-act))
                   (bytes? enc-tag)
                   (> (bytes-length enc-tag) 4)
                   (WireChat? dec-tag)
                   (not (WireChat-team? dec-tag))
                   (equal? (WireChat-message dec-tag) (sc2-chat-action-message tag-act))
                   (= drops-before drops-after)))

  ;; L36-P0-1c: Front-of-Hatchery Spine Crawler placement (`#37` 12-Pool fix) is 100% spawn-symmetric
  ;; across SW AND NE spawns — NEVER tucks behind the mineral line even when enemy Lings contest
  ;; the Hatchery and `req-x/req-y` points at Hatchery center or behind the minerals!
  (define map-w 192)
  (define map-h 168)
  (define full-pl (sc2-image-grid 8 map-w map-h (make-bytes (* map-w map-h) 1) #f #f))
  (define full-th (sc2-image-grid 8 map-w map-h (make-bytes (* map-w map-h) 160) #f #f))
  (define gi-36c
    (sc2-game-info "L36SpineMap" "" '() (cons map-w map-h) (hash 'x0 4 'y0 4 'x1 188 'y1 164)
                   (list (sc2-point2d 155.5 133.5)) full-pl full-th full-pl))
  (define (mk-min-line tag0 mx y0)
    (for/list ([k (in-range 8)])
      (mk-l36-u (+ tag0 k) 341 3 mx (+ y0 (* 1.0 k)) #:rad 1.125 #:mins 1500)))
  (define (run-spine-test base-x base-y min-x enemy-x enemy-y req-x req-y loop)
    (define hatch (mk-l36-u 16201 86 1 base-x base-y #:hp 1500.0 #:rad 2.75))
    (define drone (mk-l36-u 16202 104 1 (+ base-x 2.0) base-y #:hp 40.0 #:rad 0.375))
    ;; Active enemy Zerglings attacking the Hatchery (`#37` 12-Pool rush!)
    (define lings
      (for/list ([k (in-range 6)])
        (mk-l36-u (+ 16250 k) 105 4 (+ base-x (* 3.0 (if (< base-x 96.0) 1.0 -1.0))) (+ base-y (- k 2.5)) #:hp 35.0 #:rad 0.375)))
    (define mins (mk-min-line 16300 min-x (- base-y 3.5)))
    (define obs-sp (make-test-obs loop 200 0 (append (list hatch drone) lings mins)))
    (define cmds
      (translate-bot-actions->sc2-raw-commands
       (list (list 'build 'spine-crawler req-x req-y))
       obs-sp #:game-info gi-36c #:enemy-base (list enemy-x enemy-y)))
    (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1166)))
           cmds))
  ;; SW spawn: Hatch `(32.5, 32.5)`, minerals West at `x = 26.0`, enemy NE `(155.5, 133.5)`, bad req behind minerals `(24.0, 32.5)`
  (define spine-sw (run-spine-test 32.5 32.5 26.0 155.5 133.5 24.0 32.5 25000))
  ;; NE spawn: Hatch `(155.5, 133.5)`, minerals East at `x = 162.0`, enemy SW `(32.5, 32.5)`, bad req behind minerals `(164.0, 133.5)`
  (define spine-ne (run-spine-test 155.5 133.5 162.0 32.5 32.5 164.0 133.5 25040))
  (define sw-pt (and (sc2-raw-unit-command? spine-sw) (sc2-raw-unit-command-target-pos spine-sw)))
  (define ne-pt (and (sc2-raw-unit-command? spine-ne) (sc2-raw-unit-command-target-pos spine-ne)))
  (check-true (format "l36-p0-1c-front-of-hatchery-spine-placement-sw-and-ne (sw=~a ne=~a)" sw-pt ne-pt)
              (and (sc2-point2d? sw-pt)
                   (> (sc2-point2d-x sw-pt) 34.5)    ;; STRICTLY East (front) of SW Hatchery, away from West minerals!
                   (<= (sc2-point2d-x sw-pt) 43.0)
                   (sc2-point2d? ne-pt)
                   (< (sc2-point2d-x ne-pt) 153.5)   ;; STRICTLY West (front) of NE Hatchery, away from East minerals!
                   (>= (sc2-point2d-x ne-pt) 145.0))))

;; =============================================================================
;; Loop 37 (`L37-P0-3`): Broadcast `Tag:v_<rev>` (`channel=1`) + `jj --ignore-working-copy`,
;; 4-Corner (`SW/SE/NW/NE`) Spawn-Symmetry for Wire/Wall/Creep Directional Fallbacks,
;; & Honest Arena 2.0 40-Scenario Prod-Killer Catalog Validation
;; =============================================================================
(printf "[Loop 37] Testing L37-P0-3 Broadcast Tag:v_<rev>, 4-corner spawn-symmetric fallbacks (wire/wall/creep), & 40-scenario Arena 2.0 catalog...\n")
(let ()
  (define (mk-l37-u tag utype alliance x y #:hp [hp 100.0] #:rad [rad 1.0] #:bp [bp 1.0])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 (if (= alliance 3) 0 2))
              (sc2-point3d x y 8.0) 0.0 rad bp 0 #f #f #f
              hp hp 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #f
              '() 0 '() 0 0 0.0 0 0 0 0 '() 0 0))

  ;; L37-P0-3a: `make-bot-build-tag-chat-action` uses Broadcast (`channel=1`, `team?=#f`)
  ;; and source metadata loads cleanly via `jj --ignore-working-copy` without failing!
  (define l37-tag (make-bot-build-tag-chat-action (hasheq 'short-rev "ltxmxpzu_e45b61eb")))
  (define l37-dec (decode-typed-sc2-action (encode-sc2-action l37-tag)))
  (define l37-prev-env (getenv "MOTHMAN_BUILD_VERSION"))
  (define l37-src-meta #f)
  (dynamic-wind
    void
    (lambda ()
      (putenv "MOTHMAN_BUILD_VERSION" "")
      (set! l37-src-meta (load-bot-build-metadata #:root-dir (current-directory))))
    (lambda ()
      (if l37-prev-env
          (putenv "MOTHMAN_BUILD_VERSION" l37-prev-env)
          (putenv "MOTHMAN_BUILD_VERSION" ""))))
  (check-true "l37-p0-3a-broadcast-channel-1-and-jj-ignore-working-copy-metadata"
              (and (sc2-chat-action? l37-tag)
                   (= (sc2-chat-action-channel l37-tag) 1)
                   (equal? (sc2-chat-action-message l37-tag) "Tag:v_ltxmxpzu_e45b61eb")
                   (WireChat? l37-dec)
                   (not (WireChat-team? l37-dec))
                   (hash? l37-src-meta)
                   (> (string-length (hash-ref l37-src-meta 'version "")) 0)))

  ;; L37-P0-3b: `find-best-expansion-placement` empty-resource fallback steps INWARD toward map center
  ;; across ALL 4 corners (`SW/SE/NW/NE`) — NEVER drifts `+20/+20` off-map on `NE`/`NW`/`SE`!
  (define mw37 192)
  (define mh37 168)
  (define cx37 96.0)
  (define cy37 84.0)
  (define full-pl37 (sc2-image-grid 8 mw37 mh37 (make-bytes (* mw37 mh37) 1) #f #f))
  (define full-th37 (sc2-image-grid 8 mw37 mh37 (make-bytes (* mw37 mh37) 160) #f #f))
  (define gi-37
    (sc2-game-info "L37SymMap" "" '() (cons mw37 mh37) (hash 'x0 4 'y0 4 'x1 188 'y1 164)
                   (list (sc2-point2d 32.0 32.0) (sc2-point2d 160.0 136.0))
                   full-pl37 full-th37 full-pl37))
  (define corners-37
    (list (list 'sw 32.0 32.0 160.0 136.0)
          (list 'se 160.0 32.0 32.0 136.0)
          (list 'nw 32.0 136.0 160.0 32.0)
          (list 'ne 160.0 136.0 32.0 32.0)))
  (define exp-4corner-ok?
    (for/and ([c (in-list corners-37)])
      (match-define (list _lbl hx hy _ex _ey) c)
      (define th (mk-l37-u 17001 86 1 hx hy #:hp 1500.0 #:rad 2.75))
      (define pt (find-best-expansion-placement #f 1152 hx hy (list th) #:game-info gi-37))
      (and (sc2-point2d? pt)
           (let ([px (sc2-point2d-x pt)]
                 [py (sc2-point2d-y pt)])
             ;; Strictly closer to map center than `(hx, hy)` and inside playable bounds!
             (and (>= px 8.0) (<= px 184.0) (>= py 8.0) (<= py 160.0)
                  (< (sqrt (+ (sqr (- px cx37)) (sqr (- py cy37))))
                     (sqrt (+ (sqr (- hx cx37)) (sqr (- hy cy37))))))))))
  (check-true "l37-p0-3b-find-best-expansion-placement-4corner-inward-symmetry"
              exp-4corner-ok?)

  ;; L37-P0-3c: WarpGate warp-in fallback moves strictly INWARD toward opponent across ALL 4 corners
  ;; when the grid around a corner Pylon fails primary search (no `+2.5/+2.5` NE off-map bias)!
  (define zero-pl37 (sc2-image-grid 8 mw37 mh37 (make-bytes (* mw37 mh37) 0) #f #f))
  (define gi-37-unpath
    (sc2-game-info "L37WarpMap" "" '() (cons mw37 mh37) (hash 'x0 4 'y0 4 'x1 188 'y1 164)
                   '() zero-pl37 full-th37 zero-pl37))
  (define warp-4corner-ok?
    (for/and ([c (in-list corners-37)]
              [ci (in-naturals)])
      (match-define (list _lbl hx hy ex ey) c)
      (define nex (mk-l37-u (+ 17100 (* ci 10)) 59 1 hx hy #:hp 1000.0 #:rad 2.75))
      (define pyl (mk-l37-u (+ 17101 (* ci 10)) 60 1 hx hy #:hp 200.0 #:rad 1.0))
      (define wg  (mk-l37-u (+ 17102 (* ci 10)) 133 1 hx hy #:hp 500.0 #:rad 1.5))
      (define obs-w
        (sc2-observation (+ 30000 (* ci 600))
                         (sc2-player-common 1 500 500 50 30 20 10 0 1 0 0)
                         (list nex pyl wg) '()
                         (list (sc2-power-source (sc2-point2d hx hy) 6.5 (+ 17101 (* ci 10))))
                         #f '() '() '() '() '() '()))
      (define cmds
        (translate-bot-actions->sc2-raw-commands
         '((train stalker)) obs-w #:game-info gi-37-unpath #:enemy-base (list ex ey)))
      (define wcmd (findf (lambda (x) (and (sc2-raw-unit-command? x) (= (sc2-raw-unit-command-ability-id x) 1414))) cmds))
      (define wpt (and wcmd (sc2-raw-unit-command-target-pos wcmd)))
      (and (sc2-point2d? wpt)
           (let ([wx (sc2-point2d-x wpt)]
                 [wy (sc2-point2d-y wpt)])
             (< (sqrt (+ (sqr (- wx ex)) (sqr (- wy ey))))
                (sqrt (+ (sqr (- hx ex)) (sqr (- hy ey)))))))))
  (check-true "l37-p0-3c-warpgate-fallback-4corner-inward-symmetry"
              warp-4corner-ok?)

  ;; L37-P0-3d: `lib/plan/wall-and-block.rkt` 4-corner (`SW/SE/NW/NE`) symmetry across
  ;; `classify-enemy-wall-state`, `plan-own-wall-integrity-defense`, `plan-expansion-and-gas-blocks`,
  ;; and `plan-counter-expansion-and-gas-blocks` when natural/enemy-natural keys are omitted!
  (define wall-4corner-ok?
    (for/and ([c (in-list corners-37)])
      (match-define (list _lbl hx hy ex ey) c)
      (define dx (- ex hx))
      (define dy (- ey hy))
      (define len (sqrt (+ (* dx dx) (* dy dy))))
      (define ux (/ dx len))
      (define uy (/ dy len))
      (define exp-own-nat-x (+ hx (* 22.627416997969522 ux)))
      (define exp-own-nat-y (+ hy (* 22.627416997969522 uy)))
      (define exp-en-nat-x  (- ex (* 22.627416997969522 ux)))
      (define exp-en-nat-y  (- ey (* 22.627416997969522 uy)))
      ;; 1. Enemy natural & entry point strictly between enemy main and our base
      (define wa
        (classify-enemy-wall-state
         (hasheq 'frame 2000 'base-x hx 'base-y hy 'enemy-x ex 'enemy-y ey
                 'enemy-buildings (list (hasheq 'type 'hatchery 'x exp-en-nat-x 'y exp-en-nat-y)))))
      (define wa-ok?
        (< (sqrt (+ (sqr (- (EnemyWallAssessment-entry-x wa) hx))
                    (sqr (- (EnemyWallAssessment-entry-y wa) hy))))
           (sqrt (+ (sqr (- ex hx)) (sqr (- ey hy))))))
      ;; 2. Own wall integrity defense raises lowered depot at spawn-symmetric natural door
      (define door-x (+ exp-own-nat-x (* 8.0 ux)))
      (define door-y (+ exp-own-nat-y (* 8.0 uy)))
      (define wall-cmds
        (plan-own-wall-integrity-defense
         (hasheq 'base-x hx 'base-y hy 'enemy-x ex 'enemy-y ey
                 'ally-buildings (list (hasheq 'id 501 'type 'supply-depot-lowered 'x door-x 'y door-y))
                 'enemy-units (list (hasheq 'id 601 'type 'zergling 'x (+ door-x (* 4.0 ux)) 'y (+ door-y (* 4.0 uy)))))))
      (define wall-ok?
        (ormap (lambda (a) (and (pair? a) (eq? (first a) 'cast-spell) (eq? (third a) 'morph-supply-depot-raise)))
               wall-cmds))
      ;; 3. Offensive natural block targets enemy natural strictly between enemy main and our base
      (define blk-cmds
        (plan-expansion-and-gas-blocks
         (hasheq 'frame 1200 'minerals 200 'our-race 'Protoss
                 'base-x hx 'base-y hy 'enemy-x ex 'enemy-y ey
                 'ally-units (list (hasheq 'id 701 'type 'probe 'x exp-en-nat-x 'y exp-en-nat-y)))))
      (define blk-cmd (findf (lambda (a) (and (pair? a) (eq? (first a) 'build) (eq? (second a) 'pylon))) blk-cmds))
      (define blk-ok?
        (and blk-cmd
             (<= (sqrt (+ (sqr (- (third blk-cmd) exp-en-nat-x))
                          (sqr (- (fourth blk-cmd) exp-en-nat-y))))
                 0.5)))
      ;; 4. Counter-expansion patrol targets our spawn-symmetric natural pad (strictly toward enemy!)
      (define ctr-cmds
        (plan-counter-expansion-and-gas-blocks
         (hasheq 'minerals 200 'base-x hx 'base-y hy 'enemy-x ex 'enemy-y ey
                 'ally-units (list (hasheq 'id 801 'type 'zergling 'x exp-own-nat-x 'y exp-own-nat-y)))))
      (define ctr-cmd (findf (lambda (a) (and (pair? a) (eq? (first a) 'patrol-block-expansion))) ctr-cmds))
      (define ctr-ok?
        (and ctr-cmd
             (<= (sqrt (+ (sqr (- (third ctr-cmd) exp-own-nat-x))
                          (sqr (- (fourth ctr-cmd) exp-own-nat-y))))
                 0.5)))
      (and wa-ok? wall-ok? blk-ok? ctr-ok?)))
  (check-true "l37-p0-3d-wall-and-block-4corner-spawn-symmetry"
              wall-4corner-ok?)

  ;; L37-P0-3e: `lib/plan/creep-and-changeling.rkt` 4-corner (`SW/SE/NW/NE`) symmetry across
  ;; `plan-multi-highway-creep-spread`, `plan-changeling-free-unit-tactics`, and
  ;; `plan-dropperlord-queen-creep-expedition` when natural/third/enemy-natural keys are omitted!
  (define creep-4corner-ok?
    (for/and ([c (in-list corners-37)])
      (match-define (list _lbl hx hy ex ey) c)
      (define dx (- ex hx))
      (define dy (- ey hy))
      (define len (sqrt (+ (* dx dx) (* dy dy))))
      (define ux (/ dx len))
      (define uy (/ dy len))
      (define tr (make-creep-spread-tracker))
      ;; 1. Creep spread Queen near main plants tumor strictly toward enemy/interior (NOT off-map!)
      (define qx (+ hx (* 4.0 ux)))
      (define qy (+ hy (* 4.0 uy)))
      (define cr-cmds
        (plan-multi-highway-creep-spread
         (hasheq 'frame 2500 'base-x hx 'base-y hy 'enemy-x ex 'enemy-y ey
                 'ally-units (list (hasheq 'id 901 'type 'queen 'x qx 'y qy 'energy 50.0)))
         #:tracker tr))
      (define cr-cmd (findf (lambda (a) (and (pair? a) (eq? (first a) 'cast-spell) (eq? (third a) 'spawn-creep-tumor))) cr-cmds))
      (define cr-ok?
        (and cr-cmd
             (< (sqrt (+ (sqr (- (fourth cr-cmd) ex)) (sqr (- (fifth cr-cmd) ey))))
                (sqrt (+ (sqr (- qx ex)) (sqr (- qy ey)))))))
      ;; 2. Changeling ramp body-block targets midpoint between enemy main & spawn-symmetric enemy natural
      (define ch-cmds
        (plan-changeling-free-unit-tactics
         (hasheq 'base-x hx 'base-y hy 'enemy-x ex 'enemy-y ey
                 'ally-units (list (hasheq 'id 902 'type 'changeling 'x hx 'y hy)))))
      (define ch-cmd (findf (lambda (a) (and (pair? a) (eq? (first a) 'move) (= (second a) 902))) ch-cmds))
      (define ch-ok?
        (and ch-cmd
             (< (sqrt (+ (sqr (- (third ch-cmd) hx)) (sqr (- (fourth ch-cmd) hy))))
                (sqrt (+ (sqr (- ex hx)) (sqr (- ey hy)))))))
      ;; 3. Dropperlord expedition selects flank anchor strictly inside playable bounds
      (define exp-cmds
        (plan-dropperlord-queen-creep-expedition
         (hasheq 'frame 4500 'base-x hx 'base-y hy 'enemy-x ex 'enemy-y ey
                 'ally-units (list (hasheq 'id 903 'type 'overlord-transport 'x hx 'y hy 'cargo-tags '())
                                   (hasheq 'id 904 'type 'queen 'x hx 'y hy 'energy 50.0)))
         #:tracker (make-creep-spread-tracker)))
      (define exp-cmd (findf (lambda (a) (and (pair? a) (eq? (first a) 'transport-juggle))) exp-cmds))
      (define exp-ok?
        (and exp-cmd
             (>= (fourth exp-cmd) SC2-MAP-PLAYABLE-MIN-COORD)
             (<= (fourth exp-cmd) SC2-MAP-PLAYABLE-MAX-COORD)
             (>= (fifth exp-cmd) SC2-MAP-PLAYABLE-MIN-COORD)
             (<= (fifth exp-cmd) SC2-MAP-PLAYABLE-MAX-COORD)))
      (and cr-ok? ch-ok? exp-ok?)))
  (check-true "l37-p0-3e-creep-and-changeling-4corner-spawn-symmetry"
              creep-4corner-ok?)

  ;; L37-P0-3f / L38-P0-4 / L39-P0-4 / L42-P0-3a: Honest Arena 2.0 3-tier catalog (`58` scenarios: `49` canonical + `4` econ-harass + `5` regression)!
  (define cat-path (build-path (current-directory) "tools" "arena-scenarios.json"))
  (define cat-j (and (file-exists? cat-path) (call-with-input-file cat-path read-json)))
  (define cat-scens (if (hash? cat-j) (hash-ref cat-j 'scenarios '()) '()))
  (define cat-ids (for/list ([s (in-list cat-scens)]) (hash-ref s 'id "")))
  (define cat-by-id (for/hash ([s (in-list cat-scens)]) (values (hash-ref s 'id "") s)))
  (define tier-canon (count (lambda (s) (equal? (hash-ref s 'tier "canonical") "canonical")) cat-scens))
  (define tier-econ  (count (lambda (s) (equal? (hash-ref s 'tier "canonical") "econ-harass")) cat-scens))
  (define tier-reg   (count (lambda (s) (equal? (hash-ref s 'tier "canonical") "regression")) cat-scens))
  (define req-ids
    '("sc2-real-p13-obs-colossus-stalker-vs-bio-widowmines"
      "sc2-real-p14-pvp-stalker-chargelot-immortal-mirror"
      "sc2-real-p15-dt-blink-snipe-planetary"
      "sc2-real-p16-warpprism-immortal-juggle-vs-roach-ravager"
      "sc2-real-p17-skytoss-ht-feedback-vs-corruptor-viper"
      "sc2-real-p18-glaive-adept-oracle-revelation-vs-lurker-hydra"
      "sc2-real-t13-bio-tank-viking-vs-blink-colossus"
      "sc2-real-t14-raven-imatrix-aam-bio-vs-colossus"
      "sc2-real-t15-bc-yamato-jump-vs-corruptor-viper"
      "sc2-real-z13-ravager-hydra-ling-vs-heavy-tank-line"
      "sc2-real-z14-infestor-fungal-neural-lingbane-vs-bio-tank"
      "sc2-real-z15-viper-blindingcloud-pbomb-ultra-vs-mech-bio"
      "sc2-real-z16-muta-magicbox-vs-thors"
      "sc2-econ-e01-probe-harass-mineral-defense"
      "sc2-econ-e02-reaper-harass-mineral-defense"
      "sc2-econ-e03-3adept-scv-mineral-defense"
      "sc2-econ-e04-6ling-runby-mineral-defense"
      "sc2-reg-r01-prod5138254-pvt-obs-stalker-vs-cloaked-banshees"
      "sc2-reg-r02-prod5138248-zvp-drone-hold-vs-15probe-rush"
      "sc2-reg-r03-iter37-m42-pvz-ramp-hold-vs-ling-flood"
      "sc2-reg-r05-prod5140013-tvp-scv-hold-vs-15probe-rush"
      "sc2-reg-r06-prod5140055-pvp-probe-hold-vs-15probe-rush"))
  (define p15-s (hash-ref cat-by-id "sc2-real-p15-dt-blink-snipe-planetary" #f))
  (define p18-s (hash-ref cat-by-id "sc2-real-p18-glaive-adept-oracle-revelation-vs-lurker-hydra" #f))
  (define t15-s (hash-ref cat-by-id "sc2-real-t15-bc-yamato-jump-vs-corruptor-viper" #f))
  (define e03-s (hash-ref cat-by-id "sc2-econ-e03-3adept-scv-mineral-defense" #f))
  (define r01-s (hash-ref cat-by-id "sc2-reg-r01-prod5138254-pvt-obs-stalker-vs-cloaked-banshees" #f))
  (define r02-s (hash-ref cat-by-id "sc2-reg-r02-prod5138248-zvp-drone-hold-vs-15probe-rush" #f))
  (define r05-s (hash-ref cat-by-id "sc2-reg-r05-prod5140013-tvp-scv-hold-vs-15probe-rush" #f))
  (define r06-s (hash-ref cat-by-id "sc2-reg-r06-prod5140055-pvp-probe-hold-vs-15probe-rush" #f))
  (check-true (format "l37-p0-3f-l43-arena-scenarios-3tier-catalog (n=~a c=~a e=~a r=~a)"
                      (length cat-scens) tier-canon tier-econ tier-reg)
              (and (hash? cat-j)
                   (>= (hash-ref cat-j 'schema_version 0) 2)
                   (>= (length cat-scens) 58)
                   (= (length (remove-duplicates cat-ids)) (length cat-scens))
                   (>= tier-canon 49)
                   (>= tier-econ 4)
                   (>= tier-reg 5)
                   (for/and ([rid (in-list req-ids)]) (hash-has-key? cat-by-id rid))
                   (hash? p15-s)
                   (member "ShadowStride" (hash-ref p15-s 'p1_upgrades '()))
                   (member "ProtossGroundWeapons3" (hash-ref p15-s 'p1_upgrades '()))
                   (hash? p18-s)
                   (member "ResonatingGlaives" (hash-ref p18-s 'p1_upgrades '()))
                   (member "LurkerRange" (hash-ref p18-s 'p2_upgrades '()))
                   (hash? t15-s)
                   (member "WeaponRefit" (hash-ref t15-s 'p1_upgrades '()))
                   (hash? e03-s)
                   (equal? (hash-ref e03-s 'scoring_mode "") "mineral-defense")
                   (> (hash-ref e03-s 'pass_net_econ_min 0) 0)
                   (hash? r01-s)
                   (equal? (hash-ref r01-s 'source "") "replay-extract")
                   (equal? (hash-ref r01-s 'origin_match_id "") "prod-5138254")
                   (hash? r02-s)
                   (equal? (hash-ref r02-s 'use_main_base #f) #t)
                   (hash? r05-s)
                   (equal? (hash-ref r05-s 'source "") "replay-extract")
                   (equal? (hash-ref r05-s 'origin_match_id "") "prod-5140013")
                   (equal? (hash-ref r05-s 'use_main_base #f) #t)
                   (hash? r06-s)
                   (equal? (hash-ref r06-s 'our_race "") "Protoss")
                   (equal? (hash-ref r06-s 'enemy_race "") "Protoss")
                   (equal? (hash-ref r06-s 'source "") "replay-extract")
                   (equal? (hash-ref r06-s 'origin_match_id "") "prod-5140055")
                   (equal? (hash-ref r06-s 'use_main_base #f) #t))))

(printf "[Loop 39] Testing L39-P0-4 wire translation for ShadowStride (2700), Yamato (401), NeuralParasite (249), & worker-drill 3666+23...\n")
(let ()
  (define (mk-l39-u tag utype alliance x y #:hp [hp 100.0] #:sh [sh 0.0] #:en [en 100.0] #:rad [rad 0.5] #:mins [mins 0])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 2)
              (sc2-point3d x y 8.0) 0.0 rad 1.0 0 #f #f #f
              hp hp sh sh en (max en 100.0) mins 0 #f #f #f #t #f
              '() 0 '() 0 0 0.0 0 0 0 0 '() 0 0))

  ;; 1. ShadowStride (2700) point-target wire translation (`p15` DT Blink PF snipe)
  (define dt-u (mk-l39-u 99001 76 1 76.0 80.0 #:hp 40.0 #:sh 80.0 #:en 0.0))
  (define pf-u (mk-l39-u 99101 130 4 85.0 80.0 #:hp 1500.0 #:rad 2.75))
  (define obs-dt (make-test-obs 4200 100 0 (list dt-u pf-u)))
  (define cmds-dt (translate-bot-actions->sc2-raw-commands '((cast 99001 shadow-stride 82.0 80.0)) obs-dt))
  (define c-2700 (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 2700))) cmds-dt))
  (check-true "l39-p0-4a-shadow-stride-2700-point-target-wire-translation"
              (and (sc2-raw-unit-command? c-2700)
                   (sc2-point2d? (sc2-raw-unit-command-target-pos c-2700))
                   (= (sc2-raw-unit-command-target-unit-tag c-2700) 0)
                   (equal? (sc2-raw-unit-command-unit-tags c-2700) '(99001))))

  ;; 2. Battlecruiser Yamato Cannon (401) unit-target wire translation & P0 tier (`t15`)
  (define bc-u (mk-l39-u 99002 57 1 70.0 70.0 #:hp 550.0 #:en 0.0 #:rad 1.25))
  (define corr-u (mk-l39-u 99102 112 4 78.0 70.0 #:hp 200.0 #:en 0.0))
  (define obs-bc (make-test-obs 4210 100 0 (list bc-u corr-u)))
  (define cmds-bc (translate-bot-actions->sc2-raw-commands '((cast 99002 yamato-cannon 99102)) obs-bc))
  (define c-401 (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 401))) cmds-bc))
  (check-true "l39-p0-4b-yamato-cannon-401-unit-target-wire-translation-and-p0"
              (and (sc2-raw-unit-command? c-401)
                   (not (sc2-raw-unit-command-target-pos c-401))
                   (= (sc2-raw-unit-command-target-unit-tag c-401) 99102)
                   (equal? (sc2-raw-unit-command-unit-tags c-401) '(99002))
                   (= (wire-cmd-priority-tier c-401) 0)))

  ;; 3. Infestor Neural Parasite (249) unit-target wire translation (`cast` + `infestor-burrow-cast`) & P0 tier (`z14`)
  (define inf-u (mk-l39-u 99003 111 1 72.0 72.0 #:hp 90.0 #:en 120.0))
  (define tank-u (mk-l39-u 99103 32 4 80.0 72.0 #:hp 175.0 #:en 0.0))
  (define obs-inf (make-test-obs 4220 100 0 (list inf-u tank-u)))
  (define cmds-np1 (translate-bot-actions->sc2-raw-commands '((cast 99003 neural-parasite 99103)) obs-inf))
  (define cmds-np2 (translate-bot-actions->sc2-raw-commands '((infestor-burrow-cast 99003 neural-parasite 99103)) obs-inf))
  (define c-249a (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 249))) cmds-np1))
  (define c-249b (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 249))) cmds-np2))
  (check-true "l39-p0-4c-neural-parasite-249-unit-target-wire-translation-and-p0"
              (and (sc2-raw-unit-command? c-249a)
                   (= (sc2-raw-unit-command-target-unit-tag c-249a) 99103)
                   (= (wire-cmd-priority-tier c-249a) 0)
                   (sc2-raw-unit-command? c-249b)
                   (= (sc2-raw-unit-command-target-unit-tag c-249b) 99103)
                   (= (wire-cmd-priority-tier c-249b) 0)))

  ;; 4. Worker-rush defense `3666+23` wire translation (`worker-drill-stack-attack` + urgent `mineral-walk` + `pull-workers-attack`)
  (define cc-u   (mk-l39-u 99009 18 1 28.5 28.5 #:hp 1500.0 #:en 0.0 #:rad 2.75))
  (define min-u  (mk-l39-u 99501 341 3 23.0 28.5 #:hp 1000.0 #:en 0.0 #:rad 1.0 #:mins 1500))
  (define scv-far (mk-l39-u 99010 45 1 28.5 28.5 #:hp 45.0 #:en 0.0 #:rad 0.375))
  (define scv-near (mk-l39-u 99011 45 1 25.5 28.5 #:hp 45.0 #:en 0.0 #:rad 0.375))
  (define scv-hurt (mk-l39-u 99012 45 1 26.5 29.0 #:hp 15.0 #:en 0.0 #:rad 0.375))
  (define prb-e   (mk-l39-u 99201 84 4 24.5 28.5 #:hp 20.0 #:sh 20.0 #:en 0.0 #:rad 0.375))
  (define obs-wr (make-test-obs 1400 50 0 (list cc-u min-u scv-far scv-near scv-hurt prb-e)))
  (define cmds-drill
    (translate-bot-actions->sc2-raw-commands
     '((worker-drill-stack-attack (99010 99011) 99501 99201 24.5 28.5)
       (mineral-walk 99012 99501 23.0 28.5))
     obs-wr))
  (define c-3666-drill
    (findf (lambda (c) (and (sc2-raw-unit-command? c)
                            (= (sc2-raw-unit-command-ability-id c) 3666)
                            (= (sc2-raw-unit-command-target-unit-tag c) 99501)
                            (member 99010 (sc2-raw-unit-command-unit-tags c))))
           cmds-drill))
  (define c-23-drill
    (findf (lambda (c) (and (sc2-raw-unit-command? c)
                            (= (sc2-raw-unit-command-ability-id c) 23)
                            (= (sc2-raw-unit-command-target-unit-tag c) 99201)
                            (member 99011 (sc2-raw-unit-command-unit-tags c))))
           cmds-drill))
  (define c-3666-mw
    (findf (lambda (c) (and (sc2-raw-unit-command? c)
                            (= (sc2-raw-unit-command-ability-id c) 3666)
                            (= (sc2-raw-unit-command-target-unit-tag c) 99501)
                            (member 99012 (sc2-raw-unit-command-unit-tags c))))
           cmds-drill))
  (check-true "l39-p0-4d-worker-rush-3666-plus-23-wire-translation-and-urgent-mineral-walk-p0"
              (and (sc2-raw-unit-command? c-3666-drill)
                   (sc2-raw-unit-command? c-23-drill)
                   (sc2-raw-unit-command? c-3666-mw)
                   (= (wire-cmd-priority-tier c-3666-mw) 0))))

(printf "[Loop 41] Testing L41-P0-3a r02/r05 heavy-worker-rush 3666 auto-saturate suppression, latch lifecycle, & combat-worker exclusion...\n")
(let ()
  (define (mk-l41-u tag utype alliance x y #:hp [hp 45.0] #:rad [rad 0.375] #:mins [mins 0] #:orders [ords '()])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 2)
              (sc2-point3d x y 8.0) 0.0 rad 1.0 0 #f #f #f
              hp hp 0.0 0.0 0.0 0.0 mins 0 #f #f #f #t #f
              ords 0 '() 0 0 0.0 0 0 0 0 '() 0 0))
  (define (mk-l41-obs gl food-army units)
    (sc2-observation gl (sc2-player-common 1 100 0 23 (+ 16 food-army) food-army 16 0 0 0 0)
                     units '() '() #f '() '() '() '() '() '()))
  (define cc-41 (mk-l41-u 99300 18 1 33.5 138.5 #:hp 1500.0 #:rad 2.75))
  (define mins-41
    (for/list ([i (in-range 8)])
      (mk-l41-u (+ 99350 i) 341 3 (+ 27.5 (* 0.5 i)) (+ 142.0 (* 0.4 (modulo i 3))) #:hp 1000.0 #:rad 1.0 #:mins 1500)))
  (define idle-scvs-41
    (for/list ([i (in-range 16)])
      (mk-l41-u (+ 99310 i) 45 1 (+ 31.0 (* 0.25 (modulo i 4))) (+ 139.0 (* 0.25 (quotient i 4))))))
  (define (mk-eprobes n [dx 4.0])
    (for/list ([i (in-range n)])
      (mk-l41-u (+ 99400 i) 84 4 (+ 33.5 dx (* 0.25 (modulo i 5))) (+ 138.5 (* 0.25 (quotient i 5))) #:hp 20.0)))
  (define (gather-cmds cmds)
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 3666))) cmds))

  ;; 1. >= 6 enemy Probes within <= 14t of ready CC with food-army=0 suppresses ALL idle-worker 3666 gathers!
  (set-box! SC2-HEAVY-WORKER-RUSH-LATCH #f)
  (define cmds-rush-15
    (saturate-workers-and-gas-commands
     (mk-l41-obs 1000 0 (append (list cc-41) mins-41 idle-scvs-41 (mk-eprobes 15 4.0)))))
  (check-true "l41-p0-3a-heavy-worker-rush-15-probes-suppresses-idle-3666"
              (and (null? (gather-cmds cmds-rush-15))
                   (eq? (unbox SC2-HEAVY-WORKER-RUSH-LATCH) #t)))

  ;; 2. Stays latched at 4 remaining Probes (cleanup) and clears immediately when < 3 Probes remain!
  (define cmds-rush-4
    (saturate-workers-and-gas-commands
     (mk-l41-obs 1004 0 (append (list cc-41) mins-41 idle-scvs-41 (mk-eprobes 4 5.0)))))
  (define latch-at-4 (unbox SC2-HEAVY-WORKER-RUSH-LATCH))
  (define cmds-rush-2
    (saturate-workers-and-gas-commands
     (mk-l41-obs 1008 0 (append (list cc-41) mins-41 idle-scvs-41 (mk-eprobes 2 5.0)))))
  (check-true "l41-p0-3b-heavy-worker-rush-latched-at-4-and-resumes-mining-below-3"
              (and (null? (gather-cmds cmds-rush-4))
                   (eq? latch-at-4 #t)
                   (not (null? (gather-cmds cmds-rush-2)))
                   (eq? (unbox SC2-HEAVY-WORKER-RUSH-LATCH) #f)))

  ;; 3. Negative guards: 2-Probe harass (`e01`) and `food-army >= 4` BOTH keep normal 3666 saturation active!
  (set-box! SC2-HEAVY-WORKER-RUSH-LATCH #f)
  (define cmds-2probe
    (saturate-workers-and-gas-commands
     (mk-l41-obs 1200 0 (append (list cc-41) mins-41 idle-scvs-41 (mk-eprobes 2 4.0)))))
  (define latch-2probe (unbox SC2-HEAVY-WORKER-RUSH-LATCH))
  (define cmds-army4
    (saturate-workers-and-gas-commands
     (mk-l41-obs 1204 4 (append (list cc-41) mins-41 idle-scvs-41 (mk-eprobes 10 4.0)))))
  (check-true "l41-p0-3c-negative-guards-2probe-harass-and-food-army-4-keep-3666-active"
              (and (not (null? (gather-cmds cmds-2probe)))
                   (eq? latch-2probe #f)
                   (not (null? (gather-cmds cmds-army4)))
                   (eq? (unbox SC2-HEAVY-WORKER-RUSH-LATCH) #f)))

  ;; 4. Opening anti-bounce (`cur-loop <= 336`) is ALSO suppressed during heavy worker rush (yet fires normally w/o rush)!
  (set-box! SC2-HEAVY-WORKER-RUSH-LATCH #f)
  (define scv-f0 (mk-l41-u 99310 45 1 31.0 139.0))
  (void (frame0-pro-worker-split-commands (mk-l41-obs 0 0 (append (list cc-41 scv-f0) mins-41))))
  (define far-min-tag (sc2-unit-tag (first mins-41)))
  (define scv-bounced
    (mk-l41-u 99310 45 1 31.0 139.0 #:orders (list (sc2-unit-order 298 #f far-min-tag 0.0))))
  (define cmds-ab-rush
    (saturate-workers-and-gas-commands
     (mk-l41-obs 200 0 (append (list cc-41 scv-bounced) mins-41 (mk-eprobes 12 4.0)))))
  (define latch-ab-rush (unbox SC2-HEAVY-WORKER-RUSH-LATCH))
  (define cmds-ab-peace
    (saturate-workers-and-gas-commands
     (mk-l41-obs 204 0 (append (list cc-41 scv-bounced) mins-41))))
  (check-true "l41-p0-3d-opening-antibounce-suppressed-under-heavy-worker-rush"
              (and (null? (gather-cmds cmds-ab-rush))
                   (eq? latch-ab-rush #t)
                   (not (null? (gather-cmds cmds-ab-peace)))
                   (eq? (unbox SC2-HEAVY-WORKER-RUSH-LATCH) #f)))

  ;; 5. `attack-unit` on a fighting worker records it in `commanded-workers` so same-tick `saturate-workers-and-gas-commands`
  ;;    NEVER overwrites its Attack (23) with 3666 (even against 2-Probe harass where heavy-worker-rush is #f)!
  (define cw-41 (mutable-seteqv))
  (define w-fighter (mk-l41-u 99310 45 1 31.0 139.0))
  (define w-idle    (mk-l41-u 99311 45 1 30.5 139.5))
  (define obs-same-tick (mk-l41-obs 1500 0 (append (list cc-41 w-fighter w-idle) mins-41 (mk-eprobes 2 4.0))))
  (define act-41
    (translate-bot-actions->sc2-raw-commands '((attack-unit 99310 99400))
                                             obs-same-tick
                                             #:commanded-workers cw-41))
  (define sat-41
    (saturate-workers-and-gas-commands obs-same-tick #:excluded-worker-tags cw-41))
  (check-true "l41-p0-3e-attack-unit-worker-excluded-from-same-tick-3666-saturation"
              (and (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                           (= (sc2-raw-unit-command-ability-id c) 23)
                                           (member 99310 (sc2-raw-unit-command-unit-tags c))))
                          act-41)
                   (set-member? cw-41 99310)
                   (not (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                                (member 99310 (sc2-raw-unit-command-unit-tags c))))
                               sat-41))
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                           (= (sc2-raw-unit-command-ability-id c) 3666)
                                           (member 99311 (sc2-raw-unit-command-unit-tags c))))
                          sat-41))))

(printf "[Loop 42] Testing L42-P0-3a 3-race (P/T/Z) heavy-worker-rush 3666 suppression & L42-P0-3b Terran/Protoss >=3-miss wide placement + relief Pylon...\n")
(let ()
  (define (mk-l42-u tag utype alliance x y
                    #:hp [hp 45.0] #:sh [sh 0.0] #:rad [rad 0.375] #:bp [bp 1.0] #:mins [mins 0])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 (if (= alliance 3) 0 2))
              (sc2-point3d x y 8.0) 0.0 rad bp 0 #f #f #f
              hp hp sh sh 0.0 0.0 mins 0 #f #f #f #t #f
              '() 0 '() 0 0 0.0 0 0 0 0 '() 0 0))
  (define (l42-dist x1 y1 x2 y2)
    (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))
  (define (l42-start-mock-ws decide-fn)
    (define-values (c-in s-out) (make-pipe))
    (define-values (s-in c-out) (make-pipe))
    (define ws (sc2-ws-conn "127.0.0.1" 59942 "/sc2api" c-in c-out #f 1))
    (define rpc-cnt (box 0))
    (define th
      (thread
       (lambda ()
         (let lp ()
           (define b0 (read-byte s-in))
           (unless (eof-object? b0)
             (define b1 (read-byte s-in))
             (define masked? (not (zero? (bitwise-and b1 #x80))))
             (define len0 (bitwise-and b1 #x7F))
             (define plen
               (cond [(< len0 126) len0]
                     [(= len0 126) (integer-bytes->integer (read-bytes 2 s-in) #f #t)]
                     [else (integer-bytes->integer (read-bytes 8 s-in) #f #t)]))
             (define mkey (if masked? (read-bytes 4 s-in) #f))
             (define raw (read-bytes plen s-in))
             (define payload
               (if masked?
                   (let ([out (make-bytes plen)])
                     (for ([i (in-range plen)])
                       (bytes-set! out i (bitwise-xor (bytes-ref raw i) (bytes-ref mkey (modulo i 4)))))
                     out)
                   raw))
             (define req-f (decode-protobuf-message payload))
             (define id-p (assoc 97 req-f))
             (define id-b (if id-p (encode-uint32 97 (third id-p)) #""))
             (define q-p (assoc 14 req-f))
             (when q-p
               (set-box! rpc-cnt (add1 (unbox rpc-cnt)))
               (define qf (decode-protobuf-message (third q-p)))
               (define p-items (filter (lambda (e) (= (first e) 3)) qf))
               (define res-b
                 (apply bytes-append
                        (for/list ([it (in-list p-items)])
                          (define itf (decode-protobuf-message (third it)))
                          (define ab (let ([p (assoc 1 itf)]) (if p (third p) 0)))
                          (define tp-e (assoc 2 itf))
                          (define-values (px py)
                            (if tp-e
                                (let ([ptf (decode-protobuf-message (third tp-e))])
                                  (values (let ([xp (assoc 1 ptf)])
                                            (if (and xp (bytes? (third xp)))
                                                (floating-point-bytes->real (third xp) #f)
                                                0.0))
                                          (let ([yp (assoc 2 ptf)])
                                            (if (and yp (bytes? (third yp)))
                                                (floating-point-bytes->real (third yp) #f)
                                                0.0))))
                                (values 0.0 0.0)))
                          (encode-submessage-field 3 (encode-int32 1 (decide-fn ab px py))))))
               (define resp (bytes-append (encode-submessage-field 14 res-b) id-b (encode-int32 99 3)))
               (define rlen (bytes-length resp))
               (define rhdr
                 (cond [(< rlen 126) (bytes #x82 rlen)]
                       [(<= rlen 65535) (bytes-append (bytes #x82 126) (integer->integer-bytes rlen 2 #f #t))]
                       [else (bytes-append (bytes #x82 127) (integer->integer-bytes rlen 8 #f #t))]))
               (write-bytes rhdr s-out)
               (write-bytes resp s-out)
               (flush-output s-out))
             (lp))))))
    (values ws rpc-cnt (lambda () (close-output-port c-out) (close-input-port c-in) (thread-wait th))))

  ;; 1. L42-P0-3a: All 3 races (Protoss Probe+Nexus `r06`, Terran SCV+CC `r05`, Zerg Drone+Hatch `r02`)
  ;;    suppress 100% of idle-worker 3666 gathers under 15-Probe rush (food-army=0), stay latched at 4,
  ;;    and immediately resume mining below 3!
  (define mins-42
    (for/list ([i (in-range 8)])
      (mk-l42-u (+ 99650 i) 341 3 (+ 27.5 (* 0.5 i)) (+ 142.0 (* 0.4 (modulo i 3))) #:hp 1000.0 #:rad 1.0 #:mins 1500)))
  (define (mk-eprobes-42 n)
    (for/list ([i (in-range n)])
      (mk-l42-u (+ 99700 i) 84 4 (+ 37.5 (* 0.25 (modulo i 5))) (+ 138.5 (* 0.25 (quotient i 5))) #:hp 20.0 #:sh 20.0)))
  (define (gather-3666 cmds)
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 3666))) cmds))
  (define three-race-3666-ok?
    (for/and ([spec (in-list '((protoss 59 84 20.0 20.0)
                               (terran  18 45 45.0  0.0)
                               (zerg    86 104 40.0 0.0)))])
      (define th-id (second spec))
      (define wk-id (third spec))
      (define wk-hp (fourth spec))
      (define wk-sh (fifth spec))
      (define th-u (mk-l42-u 99600 th-id 1 33.5 138.5 #:hp 1500.0 #:rad 2.75))
      (define wks
        (for/list ([i (in-range 16)])
          (mk-l42-u (+ 99610 i) wk-id 1 (+ 31.0 (* 0.25 (modulo i 4))) (+ 139.0 (* 0.25 (quotient i 4)))
                    #:hp wk-hp #:sh wk-sh)))
      (define (obs-with-n gl n)
        (sc2-observation gl (sc2-player-common 1 100 0 23 16 0 16 0 0 0 0)
                         (append (list th-u) mins-42 wks (mk-eprobes-42 n))
                         '() '() #f '() '() '() '() '() '()))
      (set-box! SC2-HEAVY-WORKER-RUSH-LATCH #f)
      (define c15 (saturate-workers-and-gas-commands (obs-with-n 1000 15)))
      (define l15 (unbox SC2-HEAVY-WORKER-RUSH-LATCH))
      (define c4  (saturate-workers-and-gas-commands (obs-with-n 1004 4)))
      (define l4  (unbox SC2-HEAVY-WORKER-RUSH-LATCH))
      (define c2  (saturate-workers-and-gas-commands (obs-with-n 1008 2)))
      (define l2  (unbox SC2-HEAVY-WORKER-RUSH-LATCH))
      (and (null? (gather-3666 c15)) (eq? l15 #t)
           (null? (gather-3666 c4))  (eq? l4 #t)
           (not (null? (gather-3666 c2))) (eq? l2 #f))))
  (check-true "l42-p0-3a-3race-protoss-terran-zerg-heavy-worker-rush-3666-suppression"
              three-race-3666-ok?)

  ;; 2. L42-P0-3b (Terran): After >= 3 consecutive `barracks` misses, wide `30t` + secondary-TH
  ;;    (even incomplete `bp=0.5`!) + `+/-14` outer-ring fallback grid breaks out of a crowded main,
  ;;    places `barracks (321)` at `(76.5, 30.5)` (`14t` East of secondary CC), and resets miss streak to 0!
  (define l42-gi
    (sc2-game-info "L42ProdStallMap" "" '() '(128 128) '(4 4 124 124)
                   (list (sc2-point2d 100.0 100.0)) w3-full-grid #f w3-full-grid))
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-clear! SC2-TERRAN-5X3-MISS-CACHE)
  (hash-clear! SC2-TERRAN-5X3-MISS-STREAK)
  (hash-clear! SC2-PROD-PLACEMENT-MISS-STREAK)
  (let-values ([(ws rpc-cnt cleanup!)
                (l42-start-mock-ws
                 (lambda (ab px py)
                   ;; Reject everything within 20t of main `(28.5, 28.5)` and near secondary CC `(62.5, 30.5)`;
                   ;; accept ONLY the wide outer-ring grid spot `(76.5, 30.5)` (`+14t` East of secondary CC)!
                   (if (and (= ab 321) (<= (l42-dist px py 76.5 30.5) 2.5)) 1 2)))])
    (define cc-m (mk-l42-u 99801 18 1 28.5 28.5 #:hp 1500.0 #:rad 2.75))
    (define cc-2 (mk-l42-u 99802 18 1 62.5 30.5 #:hp 750.0 #:rad 2.75 #:bp 0.5))
    (define rax1 (mk-l42-u 99803 21 1 32.5 28.5 #:hp 1000.0 #:rad 1.5))
    (define scv1 (mk-l42-u 99804 45 1 60.0 30.0 #:hp 45.0 #:rad 0.375))
    (define u-list (list cc-m cc-2 rax1 scv1))
    ;; Simulate 3 failed attempts -> streak reaches 3
    (hash-set! SC2-PROD-PLACEMENT-MISS-STREAK 'barracks 3)
    (define cmds-t
      (translate-bot-actions->sc2-raw-commands
       '((build barracks 30.0 30.0))
       (sc2-observation 24000 (sc2-player-common 1 800 200 70 42 18 24 0 0 0 0)
                        u-list '() '() #f '() '() '() '() '() '())
       #:ws-conn ws #:game-info l42-gi))
    (define rax-cmd (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 321))) cmds-t))
    (define rax-pt (and rax-cmd (sc2-raw-unit-command-target-pos rax-cmd)))
    (check-true "l42-p0-3b1-terran-barracks-3miss-wide-30t-secondary-th-outer-grid-places-and-resets-streak"
                (and (sc2-point2d? rax-pt)
                     (<= (l42-dist (sc2-point2d-x rax-pt) (sc2-point2d-y rax-pt) 76.5 30.5) 2.5)
                     (= (hash-ref SC2-PROD-PLACEMENT-MISS-STREAK 'barracks -1) 0)))
    (cleanup!))

  ;; 3. L42-P0-3b (Protoss `#33` deadlock): When ALL existing Pylons reject `gateway (883)` after
  ;;    >= 3 consecutive misses while `minerals >= 100` and 0 Pylons are warping in (even when NOT
  ;;    supply-blocked!), emit a relief `Pylon (881)` at the uncontested secondary Nexus and reset streak to 0!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-clear! SC2-PROD-PLACEMENT-MISS-STREAK)
  (set-box! SC2-PROTOSS-POWER-PLACEMENT-FAIL-LOOP -9999)
  (let-values ([(ws rpc-cnt cleanup!)
                (l42-start-mock-ws
                 (lambda (ab px py)
                   (cond
                     ;; Every Gateway (883) query fails (boxed-in Main Pylon)!
                     [(= ab 883) 2]
                     ;; Relief Pylon (881) near secondary Nexus `(72.5, 32.5)` succeeds!
                     [(and (= ab 881) (<= (l42-dist px py 72.5 32.5) 18.0)) 1]
                     [else 2])))])
    (define nx-1 (mk-l42-u 99851 59 1 28.5 28.5 #:hp 1000.0 #:sh 1000.0 #:rad 2.75))
    (define nx-2 (mk-l42-u 99852 59 1 72.5 32.5 #:hp 1000.0 #:sh 1000.0 #:rad 2.75))
    (define py-1 (mk-l42-u 99853 60 1 32.0 34.0 #:hp 200.0 #:sh 200.0 #:rad 1.0))
    (define prb1 (mk-l42-u 99854 84 1 70.0 32.0 #:hp 20.0 #:sh 20.0 #:rad 0.375))
    (define obs-p33
      (sc2-observation 26000 (sc2-player-common 1 4800 500 91 61 25 36 0 0 0 0)
                       (list nx-1 nx-2 py-1 prb1) '()
                       (list (sc2-power-source (sc2-point3d 32.0 34.0 8.0) 6.5 99853))
                       #f '() '() '() '() '() '()))
    ;; First 3 attempts increment streak 0 -> 1 -> 2 -> 3 (use distinct loops > 64 apart to bypass neg-cd)
    (for ([gl (in-list '(26000 26080 26160))])
      (translate-bot-actions->sc2-raw-commands
       '((build gateway 32.0 34.0))
       (struct-copy sc2-observation obs-p33 [game-loop gl])
       #:ws-conn ws #:game-info l42-gi))
    (define streak-after-3 (hash-ref SC2-PROD-PLACEMENT-MISS-STREAK 'gateway 0))
    ;; Attempt #4 (streak = 3) emits relief Pylon (881) near secondary Nexus `(72.5, 32.5)` and resets streak to 0!
    (define cmds-p4
      (translate-bot-actions->sc2-raw-commands
       '((build gateway 32.0 34.0))
       (struct-copy sc2-observation obs-p33 [game-loop 26240])
       #:ws-conn ws #:game-info l42-gi))
    (define py-cmd (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 881))) cmds-p4))
    (define py-pt (and py-cmd (sc2-raw-unit-command-target-pos py-cmd)))
    (check-true "l42-p0-3b2-protoss-gateway-3miss-boxed-in-emits-relief-pylon-881-at-secondary-nexus"
                (and (= streak-after-3 3)
                     (sc2-point2d? py-pt)
                     (<= (l42-dist (sc2-point2d-x py-pt) (sc2-point2d-y py-pt) 72.5 32.5) 18.0)
                     (= (hash-ref SC2-PROD-PLACEMENT-MISS-STREAK 'gateway -1) 0)))
    (cleanup!))
  (hash-clear! SC2-TERRAN-5X3-MISS-STREAK)
  (hash-clear! SC2-PROD-PLACEMENT-MISS-STREAK))

(printf "[Loop 43] Testing L43-P0-3a ProdStall (Barracks #3+) + GasZero (8s 12w resat & stuck-harvester override) & L43-P0-3b stasis-ward/widow-mine-2099/nydus/burrow/r02-r05-r06...\n")
(let ()
  (define (mk-l43-u tag utype alliance x y
                    #:hp [hp 100.0] #:sh [sh 0.0] #:en [en 100.0]
                    #:rad [rad 0.5] #:bp [bp 1.0]
                    #:mins [mins 0] #:vesp [vesp 0]
                    #:assigned [assigned 0] #:ideal [ideal 0]
                    #:burrowed? [burr? #f] #:orders [ords '()])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 (if (= alliance 3) 0 2))
              (sc2-point3d x y 8.0) 0.0 rad bp 0 #f #f #f
              hp hp sh sh en (max en 100.0) mins vesp #f burr? #f #t #f
              ords 0 '() 0 0 0.0 assigned ideal 0 0 '() 0 0))
  (define (l43-dist x1 y1 x2 y2)
    (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))
  (define (l43-start-mock-ws decide-fn)
    (define-values (c-in s-out) (make-pipe))
    (define-values (s-in c-out) (make-pipe))
    (define ws (sc2-ws-conn "127.0.0.1" 59943 "/sc2api" c-in c-out #f 1))
    (define rpc-cnt (box 0))
    (define th
      (thread
       (lambda ()
         (let lp ()
           (define b0 (read-byte s-in))
           (unless (eof-object? b0)
             (define b1 (read-byte s-in))
             (define masked? (not (zero? (bitwise-and b1 #x80))))
             (define len0 (bitwise-and b1 #x7F))
             (define plen
               (cond [(< len0 126) len0]
                     [(= len0 126) (integer-bytes->integer (read-bytes 2 s-in) #f #t)]
                     [else (integer-bytes->integer (read-bytes 8 s-in) #f #t)]))
             (define mkey (if masked? (read-bytes 4 s-in) #f))
             (define raw (read-bytes plen s-in))
             (define payload
               (if masked?
                   (let ([out (make-bytes plen)])
                     (for ([i (in-range plen)])
                       (bytes-set! out i (bitwise-xor (bytes-ref raw i) (bytes-ref mkey (modulo i 4)))))
                     out)
                   raw))
             (define req-f (decode-protobuf-message payload))
             (define id-p (assoc 97 req-f))
             (define id-b (if id-p (encode-uint32 97 (third id-p)) #""))
             (define q-p (assoc 14 req-f))
             (when q-p
               (set-box! rpc-cnt (add1 (unbox rpc-cnt)))
               (define qf (decode-protobuf-message (third q-p)))
               (define p-items (filter (lambda (e) (= (first e) 3)) qf))
               (define res-b
                 (apply bytes-append
                        (for/list ([it (in-list p-items)])
                          (define itf (decode-protobuf-message (third it)))
                          (define ab (let ([p (assoc 1 itf)]) (if p (third p) 0)))
                          (define tp-e (assoc 2 itf))
                          (define-values (px py)
                            (if tp-e
                                (let ([ptf (decode-protobuf-message (third tp-e))])
                                  (values (let ([xp (assoc 1 ptf)])
                                            (if (and xp (bytes? (third xp)))
                                                (floating-point-bytes->real (third xp) #f)
                                                0.0))
                                          (let ([yp (assoc 2 ptf)])
                                            (if (and yp (bytes? (third yp)))
                                                (floating-point-bytes->real (third yp) #f)
                                                0.0))))
                                (values 0.0 0.0)))
                          (encode-submessage-field 3 (encode-int32 1 (decide-fn ab px py))))))
               (define resp (bytes-append (encode-submessage-field 14 res-b) id-b (encode-int32 99 3)))
               (define rlen (bytes-length resp))
               (define rhdr
                 (cond [(< rlen 126) (bytes #x82 rlen)]
                       [(<= rlen 65535) (bytes-append (bytes #x82 126) (integer->integer-bytes rlen 2 #f #t))]
                       [else (bytes-append (bytes #x82 127) (integer->integer-bytes rlen 8 #f #t))]))
               (write-bytes rhdr s-out)
               (write-bytes resp s-out)
               (flush-output s-out))
             (lp))))))
    (values ws rpc-cnt (lambda () (close-output-port c-out) (close-input-port c-in) (thread-wait th))))

  ;; 1. L43-P0-3a (ProdStall 1 -> 0, `#68` Barracks #3+):
  ;;    (A) Preserves valid 5x3 east add-on space on Barracks #3 when a 5x3 spot exists!
  ;;    (B) When crowded main rejects 5x3/tight AND prior `missile-turret` + `bunker` drain initial
  ;;        RPC budget to 0, Barracks #3 triggers wide `30t` / secondary-TH outer-ring fallback
  ;;        immediately after just 1 miss (NOT waiting 3 full 48f cycles!) and places cleanly!
  (define l43-gi
    (sc2-game-info "L43WireMap" "" '() '(128 128) '(4 4 124 124)
                   (list (sc2-point2d 100.0 100.0)) w3-full-grid #f w3-full-grid))
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-clear! SC2-TERRAN-5X3-MISS-CACHE)
  (hash-clear! SC2-TERRAN-5X3-MISS-STREAK)
  (hash-clear! SC2-PROD-PLACEMENT-MISS-STREAK)
  (define cc-m43 (mk-l43-u 94001 18 1 28.5 28.5 #:hp 1500.0 #:rad 2.75))
  (define cc-243 (mk-l43-u 94002 18 1 64.5 30.5 #:hp 1500.0 #:rad 2.75))
  (define rax-a  (mk-l43-u 94003 21 1 33.5 28.5 #:hp 1000.0 #:rad 1.5))
  (define rax-b  (mk-l43-u 94004 21 1 28.5 33.5 #:hp 1000.0 #:rad 1.5))
  (define scv-43 (mk-l43-u 94005 45 1 62.0 30.0 #:hp 45.0 #:rad 0.375))
  (define obs-rax3-a
    (sc2-observation 28000 (sc2-player-common 1 800 200 70 42 18 24 0 0 0 0)
                     (list cc-m43 cc-243 rax-a rax-b scv-43) '() '() #f '() '() '() '() '() '()))
  ;; Part A: Accept pure 3x3 at `(68.5, 30.5)` (queried #1, NO east add-on) AND full 5x3 at `(32.5, 32.5)`
  ;;         (queried #2: both 321 at `(32.5, 32.5)` AND east 319 at `(35.0, 32.0)` pass!) -> MUST prefer 5x3!
  (define rax3-5x3-pt
    (let-values ([(ws _rc cleanup!)
                  (l43-start-mock-ws
                   (lambda (ab px py)
                     (cond
                       [(and (= ab 321) (<= (l43-dist px py 68.5 30.5) 0.1)) 1]
                       [(and (= ab 321) (<= (l43-dist px py 32.5 32.5) 0.1)) 1]
                       [(and (= ab 319) (<= (l43-dist px py 35.0 32.0) 0.1)) 1]
                       [else 2])))])
      (define cs (translate-bot-actions->sc2-raw-commands '((build barracks 30.0 30.0)) obs-rax3-a #:ws-conn ws #:game-info l43-gi))
      (cleanup!)
      (define c321 (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 321))) cs))
      (and c321 (sc2-raw-unit-command-target-pos c321))))
  ;; Part B: Barracks #3 with streak=1, prior `missile-turret` + `bunker` eating initial RPCs,
  ;;         and ONLY outer-ring `+22t` spot `(86.5, 30.5)` valid -> still lands in 1 step!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-set! SC2-PROD-PLACEMENT-MISS-STREAK 'barracks 1)
  (define rax3-wide-pt
    (let-values ([(ws _rc cleanup!)
                  (l43-start-mock-ws
                   (lambda (ab px py)
                     (cond
                       [(and (= ab 321) (<= (l43-dist px py 86.5 30.5) 2.5)) 1]
                       [else 2])))])
      (define cc-3b (mk-l43-u 94006 18 1 64.5 30.5 #:hp 750.0 #:rad 2.75 #:bp 0.5))
      (define obs-b
        (sc2-observation 28100 (sc2-player-common 1 900 300 70 42 18 24 0 0 0 0)
                         (list cc-m43 cc-3b rax-a rax-b scv-43) '() '() #f '() '() '() '() '() '()))
      (define cs (translate-bot-actions->sc2-raw-commands
                  '((build missile-turret 30.0 30.0) (build bunker 30.0 30.0) (build barracks 30.0 30.0))
                  obs-b #:ws-conn ws #:game-info l43-gi))
      (cleanup!)
      (define c321 (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 321))) cs))
      (and c321 (sc2-raw-unit-command-target-pos c321))))
  (check-true "l43-p0-3a1-barracks-3plus-preserves-5x3-addon-when-available-and-relaxes-fast-after-1-miss"
              (and (sc2-point2d? rax3-5x3-pt)
                   (<= (l43-dist (sc2-point2d-x rax3-5x3-pt) (sc2-point2d-y rax3-5x3-pt) 32.5 32.5) 0.1)
                   (sc2-point2d? rax3-wide-pt)
                   (<= (l43-dist (sc2-point2d-x rax3-wide-pt) (sc2-point2d-y rax3-wide-pt) 86.5 30.5) 2.5)
                   (= (hash-ref SC2-PROD-PLACEMENT-MISS-STREAK 'barracks -1) 0)))

  ;; 2. L43-P0-3a (GasZero 1 -> 0, `#59`):
  ;;    (A) Active gas building with `0` workers & `12` total workers auto-resaturates `3` workers
  ;;        in ONE step after `180f` (`8.0s`)!
  ;;    (B) Stuck-harvester override (`#59` exact bug): When `SC2-ZERO-GAS-RESCUE-LATCH` is latched
  ;;        and `assigned = 3` yields `0` gas for `>= 180f`, forces `3` FRESH mineral workers onto it!
  (set-box! SC2-GAS-PULL-HYSTERESIS-LATCH #f)
  (set-box! SC2-HEAVY-WORKER-RUSH-LATCH #f)
  (set-box! SC2-ZERO-GAS-STREAK-START-LOOP #f)
  (set-box! SC2-ZERO-GAS-LAST-VESPENE #f)
  (set-box! SC2-ZERO-GAS-RESCUE-LATCH #f)
  (set-box! SC2-ZERO-GAS-RESCUE-LAST-REFRESH-LOOP #f)
  (hash-clear! SC2-GAS-BLDG-ZERO-WORKERS-SINCE)
  (define cc-g43 (mk-l43-u 94100 18 1 42.0 40.0 #:hp 1500.0 #:rad 2.75 #:assigned 12 #:ideal 16))
  (define m-g43  (mk-l43-u 94101 341 3 36.0 40.0 #:hp 1000.0 #:rad 1.0 #:mins 1500))
  (define ref-0w (mk-l43-u 94102 20 1 46.0 33.0 #:hp 500.0 #:rad 1.5 #:vesp 1800 #:assigned 0 #:ideal 3))
  (define scvs-12
    (for/list ([i (in-range 12)])
      (mk-l43-u (+ 94110 i) 45 1 (+ 38.0 (* 0.3 (modulo i 4))) (+ 39.0 (* 0.3 (quotient i 4)))
                #:hp 45.0 #:rad 0.375 #:orders (list (sc2-unit-order 298 #f 94101 0.0)))))
  (define (mk-g43-obs gl gas ref-u [wks scvs-12])
    (sc2-observation gl (sc2-player-common 1 200 gas 40 16 4 (length wks) 0 0 0 0)
                     (append (list cc-g43 m-g43 ref-u) wks) '() '() #f '() '() '() '() '() '()))
  (void (saturate-workers-and-gas-commands (mk-g43-obs 20000 25 ref-0w)))
  (define cmds-8s (saturate-workers-and-gas-commands (mk-g43-obs 20180 25 ref-0w)))
  (define cnt-8s-3w
    (count (lambda (c) (and (sc2-raw-unit-command? c)
                            (= (sc2-raw-unit-command-ability-id c) 3666)
                            (= (sc2-raw-unit-command-target-unit-tag c) 94102)))
           cmds-8s))
  ;; Part B: Stuck `assigned=3` Refinery yielding 0 gas for >= 300f latch + 180f stuck window -> dispatches 3 fresh SCVs!
  (set-box! SC2-ZERO-GAS-STREAK-START-LOOP #f)
  (set-box! SC2-ZERO-GAS-LAST-VESPENE #f)
  (set-box! SC2-ZERO-GAS-RESCUE-LATCH #f)
  (set-box! SC2-ZERO-GAS-RESCUE-LAST-REFRESH-LOOP #f)
  (hash-clear! SC2-GAS-BLDG-ZERO-WORKERS-SINCE)
  (define ref-stuck (mk-l43-u 94102 20 1 46.0 33.0 #:hp 500.0 #:rad 1.5 #:vesp 1800 #:assigned 3 #:ideal 3))
  (void (saturate-workers-and-gas-commands (mk-g43-obs 21000 25 ref-stuck)))
  (void (saturate-workers-and-gas-commands (mk-g43-obs 21300 25 ref-stuck)))
  (define cmds-stuck (saturate-workers-and-gas-commands (mk-g43-obs 21484 25 ref-stuck)))
  (define cnt-stuck-refresh
    (count (lambda (c) (and (sc2-raw-unit-command? c)
                            (= (sc2-raw-unit-command-ability-id c) 3666)
                            (= (sc2-raw-unit-command-target-unit-tag c) 94102)))
           cmds-stuck))
  (check-true "l43-p0-3a2-gas-zero-8s-auto-resat-at-12-workers-and-stuck-harvester-override"
              (and (= cnt-8s-3w 3)
                   (= cnt-stuck-refresh 3)))

  ;; 3. L43-P0-3b1: Stasis Ward (2505) point-target emission via canonical `(cast ... stasis-ward/oracle-stasis-ward/build-stasis-trap x y)`,
  ;;    P0 priority, & clean dedupe when already executing!
  (define or-a (mk-l43-u 94201 495 1 60.0 60.0 #:hp 100.0 #:sh 60.0 #:en 80.0))
  (define or-b (mk-l43-u 94202 495 1 62.0 60.0 #:hp 100.0 #:sh 60.0 #:en 80.0
                         #:orders (list (sc2-unit-order 2505 (sc2-point3d 64.0 62.0 8.0) 0 0.0))))
  (define obs-sw (make-test-obs 4500 100 50 (list or-a or-b)))
  (define cmds-sw1 (translate-bot-actions->sc2-raw-commands '((cast 94201 stasis-ward 64.0 62.0) (cast 94202 stasis-ward 64.0 62.0)) obs-sw))
  (define cmds-sw2 (translate-bot-actions->sc2-raw-commands '((cast 94201 oracle-stasis-ward 66.0 64.0)) obs-sw))
  (define c-sw1 (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 2505))) cmds-sw1))
  (define c-sw2 (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 2505))) cmds-sw2))
  (check-true "l43-p0-3b1-stasis-ward-2505-point-target-and-dedupe"
              (and (sc2-raw-unit-command? c-sw1)
                   (sc2-point2d? (sc2-raw-unit-command-target-pos c-sw1))
                   (= (sc2-raw-unit-command-target-unit-tag c-sw1) 0)
                   (equal? (sc2-raw-unit-command-unit-tags c-sw1) '(94201))
                   (= (wire-cmd-priority-tier c-sw1) 0)
                   (sc2-raw-unit-command? c-sw2)
                   (equal? (sc2-raw-unit-command-unit-tags c-sw2) '(94201))))

  ;; 4. L43-P0-3b2: Burrowed Widow Mine (500) target-fire emits `2099` via `attack-unit`,
  ;;    `focus-fire`, AND `widow-mine-retarget`, while co-grouped Marine (48) still emits `23`!
  (define wm-b  (mk-l43-u 94301 500 1 70.0 70.0 #:hp 90.0 #:burrowed? #t))
  (define mar-u (mk-l43-u 94302 48 1 68.0 70.0 #:hp 45.0))
  (define prb-t (mk-l43-u 94399 84 4 73.0 70.0 #:hp 20.0 #:sh 20.0))
  (define obs-wm (make-test-obs 4600 100 50 (list wm-b mar-u prb-t)))
  (define cmds-wm-atk (translate-bot-actions->sc2-raw-commands '((attack-unit (94301 94302) 94399)) obs-wm))
  (define cmds-wm-ff  (translate-bot-actions->sc2-raw-commands '((focus-fire 94301 94399)) obs-wm))
  (define cmds-wm-rt  (translate-bot-actions->sc2-raw-commands '((widow-mine-retarget 94301 94399)) obs-wm))
  (define c-wm-2099 (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 2099))) cmds-wm-atk))
  (define c-mar-23  (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 23))) cmds-wm-atk))
  (define c-ff-2099 (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 2099))) cmds-wm-ff))
  (define c-rt-2099 (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 2099))) cmds-wm-rt))
  (check-true "l43-p0-3b2-burrowed-widow-mine-attack-unit-focus-fire-retarget-emit-2099"
              (and (sc2-raw-unit-command? c-wm-2099)
                   (= (sc2-raw-unit-command-target-unit-tag c-wm-2099) 94399)
                   (equal? (sc2-raw-unit-command-unit-tags c-wm-2099) '(94301))
                   (sc2-raw-unit-command? c-mar-23)
                   (equal? (sc2-raw-unit-command-unit-tags c-mar-23) '(94302))
                   (sc2-raw-unit-command? c-ff-2099)
                   (sc2-raw-unit-command? c-rt-2099)))

  ;; 5. L43-P0-3b3: Nydus Load/Unload cleanly routes Network (`95` -> `1437`/`1438`) AND Canal (`142` -> `2370`/`2371`),
  ;;    supporting both single & list passengers at P0 priority!
  (define nyd-net (mk-l43-u 94401 95 1 30.0 30.0 #:hp 850.0 #:rad 1.5))
  (define nyd-can (mk-l43-u 94402 142 1 110.0 110.0 #:hp 300.0 #:rad 1.5))
  (define rch-1   (mk-l43-u 94411 110 1 31.0 30.0 #:hp 145.0))
  (define rch-2   (mk-l43-u 94412 110 1 31.5 30.5 #:hp 145.0))
  (define obs-nyd (make-test-obs 4700 200 100 (list nyd-net nyd-can rch-1 rch-2)))
  (define cmds-nyd
    (translate-bot-actions->sc2-raw-commands
     '((nydus-load 94401 (94411 94412)) (nydus-unload 94401)
       (nydus-load 94402 94411) (nydus-unload 94402))
     obs-nyd))
  (define n-1437 (count (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1437) (= (wire-cmd-priority-tier c) 0))) cmds-nyd))
  (define n-1438 (count (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1438) (= (wire-cmd-priority-tier c) 0))) cmds-nyd))
  (define n-2370 (count (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 2370) (= (wire-cmd-priority-tier c) 0))) cmds-nyd))
  (define n-2371 (count (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 2371) (= (wire-cmd-priority-tier c) 0))) cmds-nyd))
  (check-true "l43-p0-3b3-nydus-load-unload-network-1437-1438-and-canal-2370-2371"
              (and (= n-1437 2) (= n-1438 1) (= n-2370 1) (= n-2371 1)))

  ;; 6. L43-P0-3b4: `burrow-down`/`burrow-up` AND `(cast ... burrow/unburrow)` across ALL 6 families
  ;;    (`Roach`, `Baneling`, `Infestor`, `Lurker`, `Zergling`, `WidowMine`) emit exact SC2 ability IDs
  ;;    (`3661/3662`, `2108/2110`, `2095/2097`)!
  (define u-roach (mk-l43-u 94501 110 1 50.0 50.0 #:hp 145.0))
  (define u-bane  (mk-l43-u 94502 9   1 51.0 50.0 #:hp 30.0))
  (define u-inf   (mk-l43-u 94503 111 1 52.0 50.0 #:hp 90.0))
  (define u-lurk  (mk-l43-u 94504 502 1 53.0 50.0 #:hp 200.0))
  (define u-ling  (mk-l43-u 94505 105 1 54.0 50.0 #:hp 35.0))
  (define u-mine  (mk-l43-u 94506 498 1 55.0 50.0 #:hp 90.0))
  (define obs-bur (make-test-obs 4800 100 50 (list u-roach u-bane u-inf u-lurk u-ling u-mine)))
  (define cmds-bd
    (translate-bot-actions->sc2-raw-commands
     '((burrow-down 94501) (burrow-down 94502) (burrow-down 94503)
       (burrow-down 94504) (burrow-down 94505) (burrow-down 94506))
     obs-bur))
  (define u-roach-b (mk-l43-u 94501 118 1 50.0 50.0 #:hp 145.0))
  (define u-bane-b  (mk-l43-u 94502 115 1 51.0 50.0 #:hp 30.0))
  (define u-inf-b   (mk-l43-u 94503 127 1 52.0 50.0 #:hp 90.0))
  (define u-lurk-b  (mk-l43-u 94504 503 1 53.0 50.0 #:hp 200.0))
  (define u-ling-b  (mk-l43-u 94505 119 1 54.0 50.0 #:hp 35.0))
  (define u-mine-b  (mk-l43-u 94506 500 1 55.0 50.0 #:hp 90.0))
  (define obs-bur-up (make-test-obs 4820 100 50 (list u-roach-b u-bane-b u-inf-b u-lurk-b u-ling-b u-mine-b)))
  (define cmds-bu
    (translate-bot-actions->sc2-raw-commands
     '((burrow-up 94501) (burrow-up 94502) (burrow-up 94503)
       (burrow-up 94504) (burrow-up 94505) (burrow-up 94506))
     obs-bur-up))
  (define cmds-cast-bd
    (translate-bot-actions->sc2-raw-commands
     '((cast 94501 burrow) (cast 94504 burrow) (cast 94506 burrow-down))
     (make-test-obs 4900 100 50 (list u-roach u-lurk u-mine))))
  (define cmds-cast-bu
    (translate-bot-actions->sc2-raw-commands
     '((cast 94501 unburrow) (cast 94504 unburrow) (cast 94506 burrow-up))
     (make-test-obs 5000 100 50 (list u-roach-b u-lurk-b u-mine-b))))
  (define (tags-for-ab cmds ab)
    (apply append
           (for/list ([c (in-list cmds)]
                      #:when (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) ab)))
             (sc2-raw-unit-command-unit-tags c))))
  (check-true "l43-p0-3b4-burrow-unburrow-all-6-families-roach-bane-infestor-lurker-ling-mine"
              (and (equal? (sort (tags-for-ab cmds-bd 3661) <) '(94501 94502 94503 94505))
                   (equal? (tags-for-ab cmds-bd 2108) '(94504))
                   (equal? (tags-for-ab cmds-bd 2095) '(94506))
                   (equal? (sort (tags-for-ab cmds-bu 3662) <) '(94501 94502 94503 94505))
                   (equal? (tags-for-ab cmds-bu 2110) '(94504))
                   (equal? (tags-for-ab cmds-bu 2097) '(94506))
                   (equal? (tags-for-ab cmds-cast-bd 3661) '(94501))
                   (equal? (tags-for-ab cmds-cast-bd 2108) '(94504))
                   (equal? (tags-for-ab cmds-cast-bd 2095) '(94506))
                   (equal? (tags-for-ab cmds-cast-bu 3662) '(94501))
                   (equal? (tags-for-ab cmds-cast-bu 2110) '(94504))
                   (equal? (tags-for-ab cmds-cast-bu 2097) '(94506))))

  ;; 7. L43-P0-3b5: Sustained 40-tick 3-race (`r02` Zerg, `r05` Terran, `r06` Protoss) worker-rush
  ;;    simulation keeps total auto-saturate `3666` orders `<= 16` (`0` under active 15->3 Probe rush)!
  (define mins-r43
    (for/list ([i (in-range 8)])
      (mk-l43-u (+ 94650 i) 341 3 (+ 27.5 (* 0.5 i)) (+ 142.0 (* 0.4 (modulo i 3))) #:hp 1000.0 #:rad 1.0 #:mins 1500)))
  (define sustained-3race-le16?
    (for/and ([spec (in-list '((zerg 86 104) (terran 18 45) (protoss 59 84)))])
      (define th-u (mk-l43-u 94600 (second spec) 1 33.5 138.5 #:hp 1500.0 #:rad 2.75))
      (define wks (for/list ([i (in-range 16)])
                    (mk-l43-u (+ 94610 i) (third spec) 1 (+ 31.0 (* 0.25 (modulo i 4))) (+ 139.0 (* 0.25 (quotient i 4))) #:hp 40.0)))
      (set-box! SC2-HEAVY-WORKER-RUSH-LATCH #f)
      (define total-3666
        (for/sum ([step-i (in-range 40)])
          (define gl (+ 1000 (* step-i 4)))
          (define n-ep (max 3 (- 15 (quotient step-i 3))))
          (define eps (for/list ([i (in-range n-ep)])
                        (mk-l43-u (+ 94700 i) 84 4 (+ 37.5 (* 0.25 (modulo i 5))) (+ 138.5 (* 0.25 (quotient i 5))) #:hp 20.0 #:sh 20.0)))
          (define cs
            (saturate-workers-and-gas-commands
             (sc2-observation gl (sc2-player-common 1 100 0 23 16 0 16 0 0 0 0)
                              (append (list th-u) mins-r43 wks eps) '() '() #f '() '() '() '() '() '())))
          (count (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 3666))) cs)))
      (<= total-3666 16)))
  (check-true "l43-p0-3b5-3race-worker-rush-sustained-r02-r05-r06-3666-at-most-16"
              sustained-3race-le16?)
  (hash-clear! SC2-TERRAN-5X3-MISS-STREAK)
  (hash-clear! SC2-PROD-PLACEMENT-MISS-STREAK)
  (hash-clear! SC2-GAS-BLDG-ZERO-WORKERS-SINCE))

;; =============================================================================
;; [Loop 44] Stream 3 Wire & Arena Catalog Regressions (`L44-P0-3a` & `L44-P0-3b`)
;; =============================================================================
(let ()
  (define (mk-l44-u tag utype alliance x y
                    #:hp [hp 100.0] #:sh [sh 0.0] #:rad [rad 0.75]
                    #:bp [bp 1.0] #:fly [fly #f] #:mins [mins 0]
                    #:pax [pax '()] #:ctaken [ctaken 0] #:cmax [cmax 0])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 (if (= alliance 4) 2 0))
              (sc2-point3d x y 8.0) 0.0 rad bp 0 #f #t #f
              hp hp sh sh 50.0 200.0 mins 0 fly #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0
              pax ctaken cmax))

  ;; 1. L44-P0-3a1: Transport cargo/passengers protobuf decode + observation forwarding AND
  ;;    `(unload-all-at tr-id x y)` / `(unload-unit tr-id x y)` / `(cast tr-id *-unload-all-at x y)`
  ;;    emit exact `396` (Medivac) / `913` (Warp Prism) / `1408` (Dropperlord) with 0 schema rejects
  ;;    at P0 priority, suppressing conflicting same-tick `move (16)` on the same transport!
  (define pax-m1 (sc2-passenger-unit 95111 48 45.0 45.0 0.0 0.0 0.0 0.0))
  (define pax-m2 (sc2-passenger-unit 95112 51 125.0 125.0 0.0 0.0 0.0 0.0))
  (define med-u (mk-l44-u 95101 54 1 60.0 60.0 #:hp 150.0 #:fly #t #:pax (list pax-m1 pax-m2) #:ctaken 3 #:cmax 8))
  (define wp-u  (mk-l44-u 95102 81 1 62.0 60.0 #:hp 80.0 #:sh 100.0 #:fly #t #:ctaken 4 #:cmax 8))
  (define dl-u  (mk-l44-u 95103 893 1 64.0 60.0 #:hp 200.0 #:fly #t #:ctaken 8 #:cmax 8))
  (define obs-tr (make-test-obs 5100 300 100 (list med-u wp-u dl-u)))
  (define bot-obs-tr (sc2-observation->runtime-obs-hash obs-tr #:configured-race 'Terran))
  (define med-h (findf (lambda (h) (= (hash-ref h 'id 0) 95101)) (hash-ref bot-obs-tr 'ally-units '())))
  (define cmds-unload
    (translate-bot-actions->sc2-raw-commands
     '((move 95101 10.0 10.0)
       (unload-all-at 95101 90.0 90.0)
       (unload-all-at 95102 92.0 88.0)
       (unload-unit 95103 94.0 86.0))
     obs-tr))
  (define rej-unload (get-last-bot-action-rejects))
  (define cmds-unload-cast
    (translate-bot-actions->sc2-raw-commands
     '((cast 95101 medivac-unload-all-at 90.0 90.0)
       (cast 95102 warp-prism-unload-all-at 92.0 88.0)
       (cast 95103 overlord-unload-all-at 94.0 86.0))
     (make-test-obs 5110 300 100 (list med-u wp-u dl-u))))
  (define rej-unload-cast (get-last-bot-action-rejects))
  (define (find-cmd-for-ab cmds ab)
    (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) ab))) cmds))
  (define c-396 (find-cmd-for-ab cmds-unload 396))
  (define c-913 (find-cmd-for-ab cmds-unload 913))
  (define c-1408 (find-cmd-for-ab cmds-unload 1408))
  (define has-clobber-move?
    (ormap (lambda (c)
             (and (sc2-raw-unit-command? c)
                  (= (sc2-raw-unit-command-ability-id c) 16)
                  (memv 95101 (sc2-raw-unit-command-unit-tags c))))
           cmds-unload))
  (check-true "l44-p0-3a1-transport-cargo-passengers-forward-and-unload-all-at-396-913-1408-zero-rejects"
              (and (hash? med-h)
                   (= (hash-ref med-h 'cargo-space-taken 0) 3)
                   (= (hash-ref med-h 'cargo-space-max 0) 8)
                   (= (length (hash-ref med-h 'passengers '())) 2)
                   (eq? (hash-ref (first (hash-ref med-h 'passengers '())) 'type #f) 'marine)
                   (null? rej-unload)
                   (null? rej-unload-cast)
                   (not has-clobber-move?)
                   (sc2-raw-unit-command? c-396)
                   (sc2-point2d? (sc2-raw-unit-command-target-pos c-396))
                   (= (wire-cmd-priority-tier c-396) 0)
                   (sc2-raw-unit-command? c-913)
                   (sc2-point2d? (sc2-raw-unit-command-target-pos c-913))
                   (= (wire-cmd-priority-tier c-913) 0)
                   (sc2-raw-unit-command? c-1408)
                   (sc2-point2d? (sc2-raw-unit-command-target-pos c-1408))
                   (= (wire-cmd-priority-tier c-1408) 0)
                   (sc2-raw-unit-command? (find-cmd-for-ab cmds-unload-cast 396))
                   (sc2-raw-unit-command? (find-cmd-for-ab cmds-unload-cast 913))
                   (sc2-raw-unit-command? (find-cmd-for-ab cmds-unload-cast 1408))))

  ;; 2. L44-P0-3a2: Natural expansion ignores harmless `AdeptPhaseShift` (801) and non-blocking
  ;;    scouts (`Observer` 82) BOTH while live AND after disappearing into fog without `dead-unit-tags`,
  ;;    while a real combat enemy (`Adept` 311) still redirects expansion cleanly to the open 3rd!
  (define (mk-cluster-mins base-tag cx cy dx-off)
    (for/list ([i (in-range 8)])
      (mk-l44-u (+ base-tag i) 341 3 (+ cx dx-off) (+ cy (- (* 1.5 i) 5.25)) #:hp 1000.0 #:rad 1.0 #:mins 1500)))
  (define gi-exp-l44
    (sc2-game-info "L44NaturalShadeMap" "" '() '(128 128) '(4 4 124 124)
                   (list (sc2-point2d 100.0 30.0)) w3-full-grid #f w3-full-grid))
  (define main-cc-e (mk-l44-u 95201 18 1 30.0 95.0 #:hp 1500.0 #:rad 2.75))
  (define scv-e     (mk-l44-u 95202 45 1 34.0 95.0 #:hp 45.0 #:rad 0.375))
  (define mins-e-main (mk-cluster-mins 95210 30.0 95.0 -6.5))
  (define mins-e-nat  (mk-cluster-mins 95220 60.0 98.0 6.5))
  (define mins-e-3rd  (mk-cluster-mins 95230 58.0 56.0 6.5))
  (define base-units-e (append (list main-cc-e scv-e) mins-e-main mins-e-nat mins-e-3rd))
  (define shade-u (mk-l44-u 95281 801 4 56.0 96.5 #:hp 1.0))
  (define obsv-u  (mk-l44-u 95282 82  4 59.0 97.5 #:hp 40.0 #:sh 20.0 #:fly #t))
  (define adept-u (mk-l44-u 95283 311 4 57.0 97.5 #:hp 70.0 #:sh 70.0))
  (define (exp-pt-of cmds)
    (define c (findf (lambda (x) (and (sc2-raw-unit-command? x) (= (sc2-raw-unit-command-ability-id x) 318))) cmds))
    (and c (sc2-raw-unit-command-target-pos c)))
  (define (d2 pt x y)
    (and (sc2-point2d? pt)
         (sqrt (+ (sqr (- (sc2-point2d-x pt) x)) (sqr (- (sc2-point2d-y pt) y))))))
  ;; Step 1 (loop 4 -> clean reset): live shade + observer at natural -> still expands to natural!
  (define cmds-exp-live-shade
    (translate-bot-actions->sc2-raw-commands
     '((expand 60.0 98.0))
     (make-test-obs 4 450 0 (append base-units-e (list shade-u obsv-u)))
     #:game-info gi-exp-l44))
  (define pt-exp-live-shade (exp-pt-of cmds-exp-live-shade))
  ;; Step 2 (loop 240, past builder reservation TTL): shade & observer leave vision (no dead-unit-tags) -> still expands to natural!
  (define cmds-exp-fog-shade
    (translate-bot-actions->sc2-raw-commands
     '((expand 60.0 98.0))
     (make-test-obs 240 450 0 base-units-e)
     #:game-info gi-exp-l44))
  (define pt-exp-fog-shade (exp-pt-of cmds-exp-fog-shade))
  ;; Step 3 (loop 480): real enemy Adept camps natural -> redirects to open 3rd `(58.0, 56.0)`!
  (define cmds-exp-live-adept
    (translate-bot-actions->sc2-raw-commands
     '((expand 60.0 98.0))
     (make-test-obs 480 450 0 (append base-units-e (list adept-u)))
     #:game-info gi-exp-l44))
  (define pt-exp-live-adept (exp-pt-of cmds-exp-live-adept))
  (check-true "l44-p0-3a2-natural-expansion-ignores-adept-phase-shift-801-live-and-remembered"
              (and (not (hash-has-key? SC2-LAST-KNOWN-ENEMY-POS 95281))
                   (sc2-point2d? pt-exp-live-shade)
                   (< (d2 pt-exp-live-shade 60.0 98.0) 6.0)
                   (sc2-point2d? pt-exp-fog-shade)
                   (< (d2 pt-exp-fog-shade 60.0 98.0) 6.0)
                   (sc2-point2d? pt-exp-live-adept)
                   (< (d2 pt-exp-live-adept 58.0 56.0) 6.0)))

  ;; 3. L44-P0-3a3: Universal Barracks 2-miss relaxation (`cur-terran-prod-count = 1`) + 1-base
  ;;    packed-main wide fallback spills onto the nearest open uncontested expansion apron
  ;;    (`all-expansion-pads`, outside the `4.5t` CC footprint!) BOTH offline (`placement_grid`)
  ;;    AND under live `RequestQuery` WS when Main (`x < 68`) rejects every candidate (`50t` span)!
  (define gw 128)
  (define gh 128)
  (define pgrid-bytes (make-bytes (* gw gh) 0))
  ;; Mark ONLY open ground around Natural `(68.0, 60.0)` (`x in [52..88], y in [44..76]`) buildable,
  ;; leaving the entire Main plateau around `(28.0, 60.0)` (`x < 52`) 100% packed/unplaceable!
  (for* ([y (in-range 44 76)]
         [x (in-range 52 88)])
    (bytes-set! pgrid-bytes (+ (* y gw) x) 1))
  (define path-bytes (make-bytes (* gw gh) 1))
  (define gi-1base
    (sc2-game-info "L44Packed1BaseMap" "" '() (list gw gh) (list 4 4 (- gw 4) (- gh 4))
                   (list (sc2-point2d 100.0 60.0))
                   (sc2-image-grid 8 gw gh path-bytes #f #f)
                   #f
                   (sc2-image-grid 8 gw gh pgrid-bytes #f #f)))
  (define cc-1b  (mk-l44-u 95301 18 1 28.0 60.0 #:hp 1500.0 #:rad 2.75))
  (define rax-1b (mk-l44-u 95302 21 1 32.0 64.0 #:hp 1000.0 #:rad 1.5))
  (define scv-1b (mk-l44-u 95303 45 1 30.0 60.0 #:hp 45.0 #:rad 0.375))
  (define mins-1b-main (mk-cluster-mins 95310 28.0 60.0 -6.5))
  (define mins-1b-nat  (mk-cluster-mins 95320 68.0 60.0 6.5))
  (define obs-1b
    (make-test-obs 5200 400 0 (append (list cc-1b rax-1b scv-1b) mins-1b-main mins-1b-nat)))
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-set! SC2-PROD-PLACEMENT-MISS-STREAK 'barracks 2)
  (define cmds-1b
    (translate-bot-actions->sc2-raw-commands
     '((build barracks 28.0 60.0))
     obs-1b
     #:game-info gi-1base))
  (define c-rax-1b
    (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 321))) cmds-1b))
  (define pt-rax-1b (and c-rax-1b (sc2-raw-unit-command-target-pos c-rax-1b)))
  ;; Part B (live mock WS `RequestQuery`): Natural is 50t away at `(78.0, 60.0)`, and ONLY
  ;; natural apron (`x in [68..82], y in [50..70]`) returns `1=Success` in `RequestQuery`!
  (define (l44-start-mock-ws decide-fn)
    (define-values (c-in s-out) (make-pipe))
    (define-values (s-in c-out) (make-pipe))
    (define ws (sc2-ws-conn "127.0.0.1" 0 "/sc2api" c-in c-out #f (box 1)))
    (define th
      (thread
       (lambda ()
         (let lp ()
           (define b0 (read-byte s-in))
           (unless (eof-object? b0)
             (define b1 (read-byte s-in))
             (define masked? (not (zero? (bitwise-and b1 #x80))))
             (define len0 (bitwise-and b1 #x7F))
             (define plen
               (cond [(< len0 126) len0]
                     [(= len0 126) (integer-bytes->integer (read-bytes 2 s-in) #f #t)]
                     [else (integer-bytes->integer (read-bytes 8 s-in) #f #t)]))
             (define mkey (if masked? (read-bytes 4 s-in) #f))
             (define raw (read-bytes plen s-in))
             (define payload
               (if masked?
                   (let ([out (make-bytes plen)])
                     (for ([i (in-range plen)])
                       (bytes-set! out i (bitwise-xor (bytes-ref raw i) (bytes-ref mkey (modulo i 4)))))
                     out)
                   raw))
             (define req-f (decode-protobuf-message payload))
             (define id-p (assoc 97 req-f))
             (define id-b (if id-p (encode-uint32 97 (third id-p)) #""))
             (define q-p (assoc 14 req-f))
             (when q-p
               (define qf (decode-protobuf-message (third q-p)))
               (define p-items (filter (lambda (e) (= (first e) 3)) qf))
               (define res-b
                 (apply bytes-append
                        (for/list ([it (in-list p-items)])
                          (define itf (decode-protobuf-message (third it)))
                          (define ab (let ([p (assoc 1 itf)]) (if p (third p) 0)))
                          (define tp-e (assoc 2 itf))
                          (define-values (px py)
                            (if tp-e
                                (let ([ptf (decode-protobuf-message (third tp-e))])
                                  (values (let ([xp (assoc 1 ptf)])
                                            (if (and xp (bytes? (third xp)))
                                                (floating-point-bytes->real (third xp) #f)
                                                0.0))
                                          (let ([yp (assoc 2 ptf)])
                                            (if (and yp (bytes? (third yp)))
                                                (floating-point-bytes->real (third yp) #f)
                                                0.0))))
                                (values 0.0 0.0)))
                          (encode-submessage-field 3 (encode-int32 1 (decide-fn ab px py))))))
               (define resp (bytes-append (encode-submessage-field 14 res-b) id-b (encode-int32 99 3)))
               (define rlen (bytes-length resp))
               (define rhdr
                 (cond [(< rlen 126) (bytes #x82 rlen)]
                       [(<= rlen 65535) (bytes-append (bytes #x82 126) (integer->integer-bytes rlen 2 #f #t))]
                       [else (bytes-append (bytes #x82 127) (integer->integer-bytes rlen 8 #f #t))]))
               (write-bytes rhdr s-out)
               (write-bytes resp s-out)
               (flush-output s-out))
             (lp))))))
    (values ws (lambda () (close-output-port c-out) (close-input-port c-in) (thread-wait th))))
  (define gi-1b-ws
    (sc2-game-info "L44Packed1BaseWS" "" '() (list gw gh) (list 4 4 (- gw 4) (- gh 4))
                   (list (sc2-point2d 100.0 60.0))
                   (sc2-image-grid 8 gw gh path-bytes #f #f)
                   #f
                   (sc2-image-grid 8 gw gh path-bytes #f #f)))
  (define obs-1b-ws
    (make-test-obs 5600 400 0 (append (list cc-1b rax-1b scv-1b) mins-1b-main (mk-cluster-mins 95330 78.0 60.0 6.5))))
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-set! SC2-PROD-PLACEMENT-MISS-STREAK 'barracks 2)
  (define pt-rax-1b-ws
    (let-values ([(ws cleanup!)
                  (l44-start-mock-ws
                   (lambda (ab px py)
                     (if (and (= ab 321) (>= px 68.0) (<= px 82.0) (>= py 50.0) (<= py 70.0)) 1 2)))])
      (define cs
        (translate-bot-actions->sc2-raw-commands
         '((build barracks 28.0 60.0))
         obs-1b-ws
         #:ws-conn ws
         #:game-info gi-1b-ws))
      (cleanup!)
      (define c321 (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 321))) cs))
      (and c321 (sc2-raw-unit-command-target-pos c321))))
  (check-true "l44-p0-3a3-universal-barracks-2miss-relaxation-and-1base-open-expansion-pad-fallback"
              (and (sc2-point2d? pt-rax-1b)
                   (>= (sc2-point2d-x pt-rax-1b) 52.0)
                   (>= (d2 pt-rax-1b 68.0 60.0) 4.0)
                   (sc2-point2d? pt-rax-1b-ws)
                   (>= (sc2-point2d-x pt-rax-1b-ws) 68.0)
                   (>= (d2 pt-rax-1b-ws 78.0 60.0) 4.0)
                   (= (hash-ref SC2-PROD-PLACEMENT-MISS-STREAK 'barracks -1) 0)))

  ;; 4. L44-P0-3b: `d10` has P1 `raven` and `d17` has P1 `overseer` in `tools/arena-scenarios.json`!
  (define arena-json-l44
    (call-with-input-file "tools/arena-scenarios.json" read-json))
  (define scens-l44 (hash-ref arena-json-l44 'scenarios '()))
  (define d10-sc (findf (lambda (s) (equal? (hash-ref s 'id "") "sc2-det-d10-t-cloaked-banshee-viking-vs-observers-stalker")) scens-l44))
  (define d17-sc (findf (lambda (s) (equal? (hash-ref s 'id "") "sc2-det-d17-z-burrowed-roach-corruptor-vs-observers-stalker-immortal")) scens-l44))
  (define (has-p1-unit? sc uname)
    (and (hash? sc)
         (ormap (lambda (u) (and (pair? u) (equal? (car u) uname) (>= (cadr u) 1)))
                (hash-ref sc 'p1_units '()))))
  (check-true "l44-p0-3b-d10-raven-and-d17-overseer-detectors-in-arena-catalog"
              (and (has-p1-unit? d10-sc "raven")
                   (has-p1-unit? d17-sc "overseer")))
  (hash-clear! SC2-TERRAN-5X3-MISS-STREAK)
  (hash-clear! SC2-PROD-PLACEMENT-MISS-STREAK)
  (hash-clear! SC2-LAST-KNOWN-ENEMY-POS)
  (hash-clear! SC2-LAST-KNOWN-ENEMY-META))

;; =============================================================================
;; [Loop 45] Stream 3 Wire Regressions (`L45-P0-3a`: `p15` Fog Ground Memory &
;;           Moving Medivac `396` Unload Wire + Governor Integrity)
;; =============================================================================
(let ()
  (define (mk-l45-u tag utype alliance x y
                    #:hp [hp 100.0] #:sh [sh 0.0] #:rad [rad 0.75]
                    #:fly [fly #f] #:orders [orders '()]
                    #:pax [pax '()] #:ctaken [ctaken 0] #:cmax [cmax 0])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 (if (= alliance 4) 2 0))
              (sc2-point3d x y 8.0) 0.0 rad 1.0 0 #f #t #f
              hp hp sh sh 50.0 200.0 0 0 fly #f #f #t #f orders 0 '() 0 0 0.0 0 0 0 0
              pax ctaken cmax))

  ;; 1. L45-P0-3a1: `raw.map_state.visibility` decode + true line-of-sight stale-purge keeps a fogged
  ;;    ground Sieged Tank (`visibility=1`, tucked behind a sight-blocking wall ONLY 4.6t from a DT!)
  ;;    retained in `SC2-LAST-KNOWN-ENEMY-POS` AND forwarded via `'remembered-enemy-ground-positions`
  ;;    (excluding flying Medivacs!), downgrades `(attack-unit dt tank)` to `23` at `(86.0, 52.0)`,
  ;;    purges cleanly once `visibility=2` (`Visible`), and has zero cross-match bleed on loop rewind!
  (define gw 128)
  (define gh 128)
  (define vis-fog-bytes (make-bytes (* gw gh) 1)) ;; 1 = Fogged everywhere behind walls
  (bytes-set! vis-fog-bytes (+ (* 53 gw) 81) 2)   ;; 2 = Visible where DT stands at (81, 53)
  (define vis-clear-bytes (make-bytes (* gw gh) 2)) ;; 2 = Visible everywhere once wall rounded
  ;; Encode real SC2 ResponseObservation protobuf with MapState.visibility (field 1)!
  (define vis-img-pb
    (bytes-append (encode-int32 1 8)
                  (encode-submessage-field 2 (bytes-append (encode-int32 1 gw) (encode-int32 2 gh)))
                  (encode-bytes-field 3 vis-fog-bytes)))
  (define raw-obs-pb
    (encode-submessage-field
     10
     (encode-submessage-field
      3
      (bytes-append (encode-uint32 9 64)
                    (encode-submessage-field 5 (encode-submessage-field 3 (encode-submessage-field 1 vis-img-pb)))))))
  (define decoded-vis-obs (sc2-response-observation (decode-sc2-response raw-obs-pb)))
  (define decoded-vg (hash-ref SC2-OBS-VISIBILITY-GRIDS decoded-vis-obs #f))
  (define dt-u   (mk-l45-u 96111 76 1 81.5 53.0 #:hp 40.0 #:sh 80.0))
  (define tank-u (mk-l45-u 96101 32 4 86.0 52.0 #:hp 175.0))
  (define med-e  (mk-l45-u 96102 54 4 86.0 54.0 #:hp 150.0 #:fly #t))
  (define gi-p15
    (sc2-game-info "L45FogWallMap" "" '() (list gw gh) (list 4 4 124 124)
                   (list (sc2-point2d 100.0 100.0)) w3-full-grid #f w3-full-grid))
  ;; Step 1 (gl=16, after clean rewind gl=4): Tank + Medivac visible -> recorded in last-known memory!
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 0 0 (list dt-u)) #:game-info gi-p15))
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 16 0 0 (list dt-u tank-u med-e)) #:game-info gi-p15))
  ;; Step 2 (gl=64): Both disappear into fog behind destructible wall (`visibility=1` at `(86,52)`,
  ;;         while DT is only `4.6t` away at `(81.5,53.0)`!) -> Tank MUST stay retained & forwarded!
  (define obs-fog64 (make-test-obs 64 0 0 (list dt-u)))
  (hash-set! SC2-OBS-VISIBILITY-GRIDS obs-fog64 (sc2-image-grid 8 gw gh vis-fog-bytes #f #f))
  (define cmds-fog64
    (translate-bot-actions->sc2-raw-commands '((attack-unit 96111 96101)) obs-fog64 #:game-info gi-p15))
  (define bot-obs-fog64
    (sc2-observation->runtime-obs-hash obs-fog64 #:game-info gi-p15 #:configured-race 'Protoss))
  (define rem-gnd64 (hash-ref bot-obs-fog64 'remembered-enemy-ground-positions '()))
  (define rem-tank64 (findf (lambda (h) (= (hash-ref h 'id 0) 96101)) rem-gnd64))
  (define rem-med64  (findf (lambda (h) (= (hash-ref h 'id 0) 96102)) rem-gnd64))
  (define atk23-fog64
    (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 23))) cmds-fog64))
  (define atk23-pt (and atk23-fog64 (sc2-raw-unit-command-target-pos atk23-fog64)))
  (define retained-at-64? (hash-has-key? SC2-LAST-KNOWN-ENEMY-POS 96101))
  ;; Step 3 (gl=120): DT gains true line-of-sight (`visibility=2` at `(86,52)`) with no live Tank -> purged!
  (define obs-vis120 (make-test-obs 120 0 0 (list dt-u)))
  (hash-set! SC2-OBS-VISIBILITY-GRIDS obs-vis120 (sc2-image-grid 8 gw gh vis-clear-bytes #f #f))
  (void (translate-bot-actions->sc2-raw-commands '() obs-vis120 #:game-info gi-p15))
  (define purged-at-120? (not (hash-has-key? SC2-LAST-KNOWN-ENEMY-POS 96101)))
  ;; Step 4 (gl=4 new match rewind before translate runs): zero cross-match bleed in runtime obs hash!
  (hash-set! SC2-LAST-KNOWN-ENEMY-POS 96199 (cons 70.0 70.0))
  (hash-set! SC2-LAST-KNOWN-ENEMY-META 96199 (cons 'siege-tank-sieged #f))
  (define bot-obs-rewind
    (sc2-observation->runtime-obs-hash (make-test-obs 4 0 0 (list dt-u)) #:game-info gi-p15 #:configured-race 'Protoss))
  (define zero-bleed-rewind? (null? (hash-ref bot-obs-rewind 'remembered-enemy-ground-positions '())))
  (check-true "l45-p0-3a1-fog-ground-enemy-retained-behind-sight-blocker-and-forwarded-to-runtime-obs"
              (and (sc2-image-grid? decoded-vg)
                   (= (sc2-grid-ref decoded-vg 86 52) 1)
                   (= (sc2-grid-ref decoded-vg 81 53) 2)
                   retained-at-64?
                   (hash? rem-tank64)
                   (eq? (hash-ref rem-tank64 'type #f) 'siege-tank-sieged)
                   (= (hash-ref rem-tank64 'x 0.0) 86.0)
                   (= (hash-ref rem-tank64 'y 0.0) 52.0)
                   (not rem-med64)
                   (sc2-point2d? atk23-pt)
                   (< (abs (- (sc2-point2d-x atk23-pt) 86.0)) 0.1)
                   (< (abs (- (sc2-point2d-y atk23-pt) 52.0)) 0.1)
                   purged-at-120?
                   zero-bleed-rewind?))

  ;; 2. L45-P0-3a2: Actively flying/moving loaded Medivac (`orders = (MOVE 16)`) cleanly executes BOTH
  ;;    `(unload-all-at tr-id x y)` (point drop `396`, suppressing same-tick kite `move 16`) AND
  ;;    `(transport-drop-moving tr-id)` (self-target moving drop `396`) with 0 schema rejects,
  ;;    P0 priority, and 100% pass-through in `govern-sc2-wire-actions!` across consecutive ticks!
  (define wm-pax1 (sc2-passenger-unit 96211 498 90.0 90.0 0.0 0.0 0.0 0.0))
  (define wm-pax2 (sc2-passenger-unit 96212 498 90.0 90.0 0.0 0.0 0.0 0.0))
  (define moving-med
    (mk-l45-u 96201 54 1 84.0 84.0 #:hp 150.0 #:fly #t
              #:orders (list (sc2-unit-order 16 (sc2-point2d 95.0 95.0) 0 0.0))
              #:pax (list wm-pax1 wm-pax2) #:ctaken 4 #:cmax 8))
  (define gov-l45 (make-wire-apm-governor #:target-apm 420.0 #:hard-cap-apm 485.0))
  (define cmds-mv-pt
    (translate-bot-actions->sc2-raw-commands
     '((move 96201 40.0 40.0)
       (unload-all-at 96201 88.0 88.0))
     (make-test-obs 1000 0 0 (list moving-med))))
  (define rej-mv-pt (get-last-bot-action-rejects))
  (define gov-mv-pt (govern-sc2-wire-actions! gov-l45 cmds-mv-pt 1000))
  (define cmds-mv-self
    (translate-bot-actions->sc2-raw-commands
     '((move 96201 40.0 40.0)
       (transport-drop-moving 96201))
     (make-test-obs 1004 0 0 (list moving-med))))
  (define rej-mv-self (get-last-bot-action-rejects))
  (define gov-mv-self (govern-sc2-wire-actions! gov-l45 cmds-mv-self 1004))
  (define c-pt-396
    (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 396))) gov-mv-pt))
  (define c-self-396
    (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 396))) gov-mv-self))
  (define mv-clobber?
    (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 16)))
           (append cmds-mv-pt cmds-mv-self)))
  (check-true "l45-p0-3a2-moving-medivac-unload-all-at-396-and-moving-drop-wire-priority-and-governor"
              (and (null? rej-mv-pt)
                   (null? rej-mv-self)
                   (not mv-clobber?)
                   (sc2-raw-unit-command? c-pt-396)
                   (= (wire-cmd-priority-tier c-pt-396) 0)
                   (sc2-point2d? (sc2-raw-unit-command-target-pos c-pt-396))
                   (< (abs (- (sc2-point2d-x (sc2-raw-unit-command-target-pos c-pt-396)) 88.0)) 0.1)
                   (sc2-raw-unit-command? c-self-396)
                   (= (wire-cmd-priority-tier c-self-396) 0)
                   (= (sc2-raw-unit-command-target-unit-tag c-self-396) 96201)))
  (hash-clear! SC2-LAST-KNOWN-ENEMY-POS)
  (hash-clear! SC2-LAST-KNOWN-ENEMY-META))

;; =============================================================================
;; [Loop 46] Stream 3 Wire Regressions (`L46-P0-3a`: Incomplete `Nexus #2`
;;           Cancel-Building under 12-Pool Rush — `314` / `3659` P0 & Governor)
;; =============================================================================
(let ()
  (define (mk-l46-u tag utype alliance x y #:hp [hp 100.0] #:sh [sh 0.0] #:rad [rad 0.75] #:bp [bp 1.0])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 (if (= alliance 4) 2 0))
              (sc2-point3d x y 8.0) 0.0 rad bp 0 #f #t #f
              hp hp sh sh 50.0 200.0 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0 '() 0 0))
  (define nex1 (mk-l46-u 96301 59 1 32.0 32.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75 #:bp 1.0))
  (define nex2 (mk-l46-u 96302 59 1 56.0 34.0 #:hp 350.0  #:sh 350.0  #:rad 2.75 #:bp 0.35))
  (define lings-12p
    (for/list ([i (in-range 6)])
      (mk-l46-u (+ 96310 i) 105 4 (+ 52.0 (* 0.5 i)) 34.0 #:hp 35.0 #:rad 0.375)))
  (define obs-12p (make-test-obs 2200 100 0 (append (list nex1 nex2) lings-12p)))
  (define gov-l46 (make-wire-apm-governor #:target-apm 420.0 #:hard-cap-apm 485.0))
  ;; Test BOTH `(cancel 96302)` AND `(cancel-building 96302)` on incomplete Nexus #2 under 12-Pool:
  ;; must pass typed validation with 0 rejects, emit P0 `CANCEL_BUILDINPROGRESS (314)` (and `3659`
  ;; `CANCEL` is also P0 in `wire-cmd-priority-tier`), claim `used-producer-tags` so no same-tick
  ;; order targets `96302`, and pass cleanly through `govern-sc2-wire-actions!`!
  (define cmds-c1
    (translate-bot-actions->sc2-raw-commands
     '((cancel-building 96302) (cast 96302 chrono-boost 96301))
     obs-12p))
  (define rej-c1 (get-last-bot-action-rejects))
  (define gov-c1 (govern-sc2-wire-actions! gov-l46 cmds-c1 2200))
  (define cmds-c2
    (translate-bot-actions->sc2-raw-commands
     '((cancel 96302))
     (make-test-obs 2204 100 0 (append (list nex1 nex2) lings-12p))))
  (define rej-c2 (get-last-bot-action-rejects))
  (define gov-c2 (govern-sc2-wire-actions! gov-l46 cmds-c2 2204))
  (define c314-a (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 314))) gov-c1))
  (define c314-b (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 314))) gov-c2))
  (check-true "l46-p0-3a-nexus2-cancel-building-wire-314-3659-p0-under-12pool"
              (and (null? rej-c1)
                   (null? rej-c2)
                   (sc2-raw-unit-command? c314-a)
                   (equal? (sc2-raw-unit-command-unit-tags c314-a) '(96302))
                   (= (wire-cmd-priority-tier c314-a) 0)
                   (sc2-raw-unit-command? c314-b)
                   (equal? (sc2-raw-unit-command-unit-tags c314-b) '(96302))
                   (= (wire-cmd-priority-tier c314-b) 0)
                   (= (wire-cmd-priority-tier (sc2-raw-unit-command 3659 #f 0 '(96302) #f)) 0))))

;; =============================================================================
;; [Loop 47] Stream 3 Wire Regressions (`L47-P0-3a`: First CyberCore / RoboBay
;;           Core-Macro Priority, Natural/3rd CC Perimeter Starport & Barracks
;;           Fallback, and `expand` Walk/Arrival Reservation & Retry Resilience)
;; =============================================================================
(let ()
  (define (mk-l47-u tag utype alliance x y
                    #:hp [hp 100.0] #:sh [sh 0.0] #:rad [rad 0.75]
                    #:bp [bp 1.0] #:mins [mins 0] #:orders [orders '()])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 (if (= alliance 4) 2 0))
              (sc2-point3d x y 8.0) 0.0 rad bp 0 #f #t #f
              hp hp sh sh 50.0 200.0 mins 0 #f #f #f #t #f orders 0 '() 0 0 0.0 0 0 0 0 '() 0 0))
  (define (mk-l47-mins base-tag cx cy dx-off)
    (for/list ([i (in-range 8)])
      (mk-l47-u (+ base-tag i) 341 3 (+ cx dx-off) (+ cy (- (* 1.5 i) 5.25)) #:hp 1000.0 #:rad 1.0 #:mins 1500)))
  (define gi-l47
    (sc2-game-info "L47WireTestMap" "" '() '(128 128) '(4 4 124 124)
                   (list (sc2-point2d 100.0 30.0)) w3-full-grid #f w3-full-grid))

  ;; 1. L47-P0-3a1: First `cybernetics-core` (`cnt=0`) and first `robotics-bay` (`cnt=0`) are
  ;;    promoted into `build-core-macro-action?` ahead of secondary structures (`forge`/`shield-battery`)
  ;;    and worker-pull combat actions, while duplicate `cybernetics-core` (`cnt>=1`) yields to `gateway`!
  (define p-nex  (mk-l47-u 97101 59 1 32.0 32.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75))
  (define p-pyl  (mk-l47-u 97102 60 1 38.0 32.0 #:hp 200.0  #:sh 200.0  #:rad 1.0))
  (define p-gw   (mk-l47-u 97103 62 1 36.0 36.0 #:hp 500.0  #:sh 500.0  #:rad 1.5))
  (define p-prb  (mk-l47-u 97104 84 1 37.0 32.0 #:hp 20.0   #:sh 20.0   #:rad 0.375))
  (define p-ling (mk-l47-u 97190 105 4 46.0 32.0 #:hp 35.0))
  (define p-psrc (list (sc2-power-source (sc2-point2d 38.0 32.0) 6.5 97102)))
  (define (mk-p-obs gl us)
    (sc2-observation gl (sc2-player-common 1 500 300 40 20 8 12 0 0 0 0)
                     us '() p-psrc #f '() '() '() '() '() '()))
  ;; Part A: 1 free Probe + pull-workers-attack + forge + first cybernetics-core -> cybernetics-core (894) wins!
  (define cmds-cc0
    (translate-bot-actions->sc2-raw-commands
     '((pull-workers-attack (97104) 97190 46.0 32.0)
       (build forge 38.0 32.0)
       (build cybernetics-core 38.0 32.0))
     (mk-p-obs 100 (list p-nex p-pyl p-gw p-prb p-ling))
     #:game-info gi-l47))
  (define has-cc-894?
    (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 894))) cmds-cc0))
  ;; Part B: 1 free Probe + forge + shield-battery + first robotics-bay -> robotics-bay (892) wins!
  (define p-robo (mk-l47-u 97105 71 1 40.0 36.0 #:hp 450.0 #:sh 450.0 #:rad 1.5))
  (define cmds-rb0
    (translate-bot-actions->sc2-raw-commands
     '((build forge 38.0 32.0)
       (build shield-battery 38.0 32.0)
       (build robotics-bay 38.0 32.0))
     (mk-p-obs 400 (list p-nex p-pyl p-gw p-robo p-prb))
     #:game-info gi-l47))
  (define has-rb-892?
    (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 892))) cmds-rb0))
  ;; Part C: Negative guard — when 1 CyberCore already exists, duplicate cybernetics-core yields to gateway (883)!
  (define p-cyb1 (mk-l47-u 97106 72 1 35.0 29.0 #:hp 550.0 #:sh 550.0 #:rad 1.5))
  (define cmds-cc1
    (translate-bot-actions->sc2-raw-commands
     '((build cybernetics-core 38.0 32.0)
       (build gateway 38.0 32.0))
     (mk-p-obs 700 (list p-nex p-pyl p-gw p-cyb1 p-prb))
     #:game-info gi-l47))
  (define has-gw-883-not-dup-cc?
    (and (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 883))) cmds-cc1)
         (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 894))) cmds-cc1))))
  (check-true "l47-p0-3a1-first-cybercore-and-robobay-promoted-to-core-macro-priority"
              (and has-cc-894? has-rb-892? has-gw-883-not-dup-cc?))

  ;; 2. L47-P0-3a2: Terran Starport `#1` (`cur-terran-prod-count = 0`, `streak = 1`) and Barracks `#3`
  ;;    (`cur-terran-prod-count = 2`, `streak = 1`) cleanly spill onto the open non-mineral perimeter
  ;;    (`~7.5t` west of Natural CC & 3rd CC, strictly outside CC footprint) under live mock-WS `RequestQuery`!
  (define (l47-start-mock-ws decide-fn)
    (define-values (c-in s-out) (make-pipe))
    (define-values (s-in c-out) (make-pipe))
    (define ws (sc2-ws-conn "127.0.0.1" 0 "/sc2api" c-in c-out #f (box 1)))
    (define th
      (thread
       (lambda ()
         (let lp ()
           (define b0 (read-byte s-in))
           (unless (eof-object? b0)
             (define b1 (read-byte s-in))
             (define masked? (not (zero? (bitwise-and b1 #x80))))
             (define len0 (bitwise-and b1 #x7F))
             (define plen
               (cond [(< len0 126) len0]
                     [(= len0 126) (integer-bytes->integer (read-bytes 2 s-in) #f #t)]
                     [else (integer-bytes->integer (read-bytes 8 s-in) #f #t)]))
             (define mkey (if masked? (read-bytes 4 s-in) #f))
             (define raw (read-bytes plen s-in))
             (define payload
               (if masked?
                   (let ([out (make-bytes plen)])
                     (for ([i (in-range plen)])
                       (bytes-set! out i (bitwise-xor (bytes-ref raw i) (bytes-ref mkey (modulo i 4)))))
                     out)
                   raw))
             (define req-f (decode-protobuf-message payload))
             (define id-p (assoc 97 req-f))
             (define id-b (if id-p (encode-uint32 97 (third id-p)) #""))
             (define q-p (assoc 14 req-f))
             (when q-p
               (define qf (decode-protobuf-message (third q-p)))
               (define p-items (filter (lambda (e) (= (first e) 3)) qf))
               (define res-b
                 (apply bytes-append
                        (for/list ([it (in-list p-items)])
                          (define itf (decode-protobuf-message (third it)))
                          (define ab (let ([p (assoc 1 itf)]) (if p (third p) 0)))
                          (define tp-e (assoc 2 itf))
                          (define-values (px py)
                            (if tp-e
                                (let ([ptf (decode-protobuf-message (third tp-e))])
                                  (values (let ([xp (assoc 1 ptf)])
                                            (if (and xp (bytes? (third xp)))
                                                (floating-point-bytes->real (third xp) #f)
                                                0.0))
                                          (let ([yp (assoc 2 ptf)])
                                            (if (and yp (bytes? (third yp)))
                                                (floating-point-bytes->real (third yp) #f)
                                                0.0))))
                                (values 0.0 0.0)))
                          (encode-submessage-field 3 (encode-int32 1 (decide-fn ab px py))))))
               (define resp (bytes-append (encode-submessage-field 14 res-b) id-b (encode-int32 99 3)))
               (define rlen (bytes-length resp))
               (define rhdr
                 (cond [(< rlen 126) (bytes #x82 rlen)]
                       [(<= rlen 65535) (bytes-append (bytes #x82 126) (integer->integer-bytes rlen 2 #f #t))]
                       [else (bytes-append (bytes #x82 127) (integer->integer-bytes rlen 8 #f #t))]))
               (write-bytes rhdr s-out)
               (write-bytes resp s-out)
               (flush-output s-out))
             (lp))))))
    (values ws (lambda () (close-output-port c-out) (close-input-port c-in) (thread-wait th))))
  (define cc-m47 (mk-l47-u 97201 18 1 28.0 60.0 #:hp 1500.0 #:rad 2.75))
  (define cc-n47 (mk-l47-u 97202 18 1 68.0 60.0 #:hp 1500.0 #:rad 2.75))
  (define cc-347 (mk-l47-u 97203 18 1 68.0 96.0 #:hp 1500.0 #:rad 2.75))
  (define rx-a47 (mk-l47-u 97204 21 1 32.0 64.0 #:hp 1000.0 #:rad 1.5))
  (define rx-b47 (mk-l47-u 97205 21 1 32.0 56.0 #:hp 1000.0 #:rad 1.5))
  (define scv-47 (mk-l47-u 97206 45 1 64.0 60.0 #:hp 45.0 #:rad 0.375))
  (define t-units-47
    (append (list cc-m47 cc-n47 cc-347 rx-a47 rx-b47 scv-47)
            (mk-l47-mins 97210 28.0 60.0 -6.5)
            (mk-l47-mins 97220 68.0 60.0 6.5)
            (mk-l47-mins 97230 68.0 96.0 6.5)))
  ;; Part A: Starport #1 (cnt=0, streak=1) -> ONLY Natural CC west courtyard perimeter [58.5..62.5, 58..62] valid!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-set! SC2-PROD-PLACEMENT-MISS-STREAK 'starport 1)
  (define sp-perim-pt
    (let-values ([(ws cleanup!)
                  (l47-start-mock-ws
                   (lambda (ab px py)
                     (if (and (= ab 329) (>= px 58.5) (<= px 62.5) (>= py 58.0) (<= py 62.0)) 1 2)))])
      (define cs (translate-bot-actions->sc2-raw-commands
                  '((build starport 28.0 60.0))
                  (make-test-obs 6000 500 300 t-units-47)
                  #:ws-conn ws #:game-info gi-l47))
      (cleanup!)
      (define c329 (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 329))) cs))
      (and c329 (sc2-raw-unit-command-target-pos c329))))
  (define sp-streak-cleared? (= (hash-ref SC2-PROD-PLACEMENT-MISS-STREAK 'starport -1) 0))
  ;; Part B: Barracks #3 (cnt=2, streak=1) -> ONLY 3rd CC west courtyard perimeter [58.5..62.5, 94..98] valid!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-set! SC2-PROD-PLACEMENT-MISS-STREAK 'barracks 1)
  (define rx-3rd-perim-pt
    (let-values ([(ws cleanup!)
                  (l47-start-mock-ws
                   (lambda (ab px py)
                     (if (and (= ab 321) (>= px 58.5) (<= px 62.5) (>= py 94.0) (<= py 98.0)) 1 2)))])
      (define cs (translate-bot-actions->sc2-raw-commands
                  '((build barracks 28.0 60.0))
                  (make-test-obs 6200 500 300 t-units-47)
                  #:ws-conn ws #:game-info gi-l47))
      (cleanup!)
      (define c321 (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 321))) cs))
      (and c321 (sc2-raw-unit-command-target-pos c321))))
  (define rx-streak-cleared? (= (hash-ref SC2-PROD-PLACEMENT-MISS-STREAK 'barracks -1) 0))
  (check-true "l47-p0-3a2-starport-and-barracks-natural-3rd-cc-perimeter-fallback"
              (and (sc2-point2d? sp-perim-pt)
                   (>= (sc2-point2d-x sp-perim-pt) 58.5) (<= (sc2-point2d-x sp-perim-pt) 62.5)
                   (>= (sc2-point2d-y sp-perim-pt) 58.0) (<= (sc2-point2d-y sp-perim-pt) 62.0)
                   sp-streak-cleared?
                   (sc2-point2d? rx-3rd-perim-pt)
                   (>= (sc2-point2d-x rx-3rd-perim-pt) 58.5) (<= (sc2-point2d-x rx-3rd-perim-pt) 62.5)
                   (>= (sc2-point2d-y rx-3rd-perim-pt) 94.0) (<= (sc2-point2d-y rx-3rd-perim-pt) 98.0)
                   rx-streak-cleared?))

  ;; 3. L47-P0-3a3: `expand` walk/command-arrival reservation (`H2H #03` `f=5088 -> 5092`) reserves
  ;;    `400M` in `clean-minerals` and exposes an in-transit `'nexus` while the Probe acquires its
  ;;    SC2 `880` order (`<= 16f`), then releases cleanly and retries `(expand ...)` if the order drops!
  (define ex-nex (mk-l47-u 97301 59 1 30.0 95.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75))
  (define ex-prb (mk-l47-u 97302 84 1 34.0 95.0 #:hp 20.0   #:sh 20.0   #:rad 0.375))
  (define ex-units
    (append (list ex-nex ex-prb)
            (mk-l47-mins 97310 30.0 95.0 -6.5)
            (mk-l47-mins 97320 60.0 98.0 6.5)))
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 420 0 ex-units) #:game-info gi-l47))
  (define cmds-ex1
    (translate-bot-actions->sc2-raw-commands
     '((expand 60.0 98.0))
     (make-test-obs 5088 420 0 ex-units)
     #:game-info gi-l47))
  (define ex1-880?
    (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 880))) cmds-ex1))
  ;; 4 loops later (`f=5092`): Probe `w.orders` does NOT yet reflect `880` -> reservation STILL deducts `400M`!
  (define obs-h-5092
    (sc2-observation->runtime-obs-hash (make-test-obs 5092 420 0 ex-units) #:game-info gi-l47 #:configured-race 'Protoss))
  (define mins-reserved-5092 (hash-ref obs-h-5092 'minerals -1))
  (define in-transit-nex-5092?
    (ormap (lambda (b) (and (eq? (hash-ref b 'type #f) 'nexus) (eq? (hash-ref b 'in-transit? #f) #t)))
           (hash-ref obs-h-5092 'ally-buildings '())))
  ;; 24 loops later (`f=5112 > 5088+16`): order still missing -> `420M` released cleanly (no lock)!
  (define obs-h-5112
    (sc2-observation->runtime-obs-hash (make-test-obs 5112 420 0 ex-units) #:game-info gi-l47 #:configured-race 'Protoss))
  (define mins-released-5112 (hash-ref obs-h-5112 'minerals -1))
  ;; 36 loops later (`f=5124 > 5088+32`): Probe free again -> retry `(expand 60.0 98.0)` emits `880` cleanly!
  (define cmds-ex-retry
    (translate-bot-actions->sc2-raw-commands
     '((expand 60.0 98.0))
     (make-test-obs 5124 420 0 ex-units)
     #:game-info gi-l47))
  (define ex-retry-880?
    (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 880))) cmds-ex-retry))
  (check-true "l47-p0-3a3-expand-walk-arrival-reservation-minerals-and-clean-retry"
              (and ex1-880?
                   (<= mins-reserved-5092 20)
                   in-transit-nex-5092?
                   (= mins-released-5112 420)
                   ex-retry-880?))
  (hash-clear! SC2-PROD-PLACEMENT-MISS-STREAK)
  (hash-clear! SC2-TERRAN-5X3-MISS-STREAK))

;; ---------------------------------------------------------------------------
;; [Loop 48] L48-P0-3a: First Spire Core-Macro Priority + Multi-Hatchery Creep-Ring
;; Fallback (`SpireDrop 2 -> 0`), `#12` Blocked Natural Expansion `>= 2` Pad Fallback
;; (`SC2-EXPANSION-PAD-BLOCK-STREAK`), & `#72` Early-Rush First Cybernetics Core
;; Tight Main-Pylon Emergency Placement!
;; ---------------------------------------------------------------------------
(let ()
  (define (hypot dx dy) (sqrt (+ (* dx dx) (* dy dy))))
  (define (mk-l48-u tag utype alliance x y
                    #:hp [hp 100.0] #:sh [sh 0.0] #:rad [rad 0.75]
                    #:bp [bp 1.0] #:mins [mins 0] #:orders [orders '()])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 (if (= alliance 4) 2 0))
              (sc2-point3d x y 8.0) 0.0 rad bp 0 #f #t #f
              hp hp sh sh 50.0 200.0 mins 0 #f #f #f #t #f orders 0 '() 0 0 0.0 0 0 0 0 '() 0 0))
  (define (mk-l48-mins base-tag cx cy dx-off)
    (for/list ([i (in-range 8)])
      (mk-l48-u (+ base-tag i) 341 3 (+ cx dx-off) (+ cy (- (* 1.5 i) 5.25)) #:hp 1000.0 #:rad 1.0 #:mins 1500)))
  (define gi-l48
    (sc2-game-info "L48WireTestMap" "" '() '(128 128) '(4 4 124 124)
                   (list (sc2-point2d 100.0 30.0)) w3-full-grid #f w3-full-grid))
  (define (l48-start-mock-ws decide-fn)
    (define-values (c-in s-out) (make-pipe))
    (define-values (s-in c-out) (make-pipe))
    (define rpc-count (box 0))
    (define ws (sc2-ws-conn "127.0.0.1" 0 "/sc2api" c-in c-out #f (box 1)))
    (define th
      (thread
       (lambda ()
         (let lp ()
           (define b0 (read-byte s-in))
           (unless (eof-object? b0)
             (define b1 (read-byte s-in))
             (define masked? (not (zero? (bitwise-and b1 #x80))))
             (define len0 (bitwise-and b1 #x7F))
             (define plen
               (cond [(< len0 126) len0]
                     [(= len0 126) (integer-bytes->integer (read-bytes 2 s-in) #f #t)]
                     [else (integer-bytes->integer (read-bytes 8 s-in) #f #t)]))
             (define mkey (if masked? (read-bytes 4 s-in) #f))
             (define raw (read-bytes plen s-in))
             (define payload
               (if masked?
                   (let ([out (make-bytes plen)])
                     (for ([i (in-range plen)])
                       (bytes-set! out i (bitwise-xor (bytes-ref raw i) (bytes-ref mkey (modulo i 4)))))
                     out)
                   raw))
             (define req-f (decode-protobuf-message payload))
             (define id-p (assoc 97 req-f))
             (define id-b (if id-p (encode-uint32 97 (third id-p)) #""))
             (define q-p (assoc 14 req-f))
             (when q-p
               (set-box! rpc-count (add1 (unbox rpc-count)))
               (define qf (decode-protobuf-message (third q-p)))
               (define p-items (filter (lambda (e) (= (first e) 3)) qf))
               (define res-b
                 (apply bytes-append
                        (for/list ([it (in-list p-items)])
                          (define itf (decode-protobuf-message (third it)))
                          (define ab (let ([p (assoc 1 itf)]) (if p (third p) 0)))
                          (define tp-e (assoc 2 itf))
                          (define-values (px py)
                            (if tp-e
                                (let ([ptf (decode-protobuf-message (third tp-e))])
                                  (values (let ([xp (assoc 1 ptf)])
                                            (if (and xp (bytes? (third xp)))
                                                (floating-point-bytes->real (third xp) #f)
                                                0.0))
                                          (let ([yp (assoc 2 ptf)])
                                            (if (and yp (bytes? (third yp)))
                                                (floating-point-bytes->real (third yp) #f)
                                                0.0))))
                                (values 0.0 0.0)))
                          (encode-submessage-field 3 (encode-int32 1 (decide-fn ab px py))))))
               (define resp (bytes-append (encode-submessage-field 14 res-b) id-b (encode-int32 99 3)))
               (define rlen (bytes-length resp))
               (define rhdr
                 (cond [(< rlen 126) (bytes #x82 rlen)]
                       [(<= rlen 65535) (bytes-append (bytes #x82 126) (integer->integer-bytes rlen 2 #f #t))]
                       [else (bytes-append (bytes #x82 127) (integer->integer-bytes rlen 8 #f #t))]))
               (write-bytes rhdr s-out)
               (write-bytes resp s-out)
               (flush-output s-out))
             (lp))))))
    (values ws rpc-count (lambda () (close-output-port c-out) (close-input-port c-in) (thread-wait th))))

  ;; 1. L48-P0-3a1: First `spire` (`cnt = 0`) is promoted to core-macro priority (claiming the sole
  ;;    free Drone ahead of `pull-workers-attack` and `evolution-chamber`, while duplicate Spire #2 yields
  ;;    to `hatchery`), AND when Main/Natural inner rings fail, Spire lands on the 3rd Hatchery's `9.5t`
  ;;    outer creep-ring fallback even after prior core-macro builds spend placement RPC budget!
  (define z-lair (mk-l48-u 98101 100 1 28.0 60.0 #:hp 2000.0 #:rad 2.75))
  (define z-pool (mk-l48-u 98102 89  1 33.0 60.0 #:hp 1000.0 #:rad 1.5))
  (define z-drn1 (mk-l48-u 98103 104 1 34.0 58.0 #:hp 40.0   #:rad 0.375))
  (define z-ling (mk-l48-u 98104 105 4 45.0 60.0 #:hp 35.0   #:rad 0.375))
  ;; Reset match state cleanly before Part A
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 600 400 (list z-lair z-pool z-drn1)) #:game-info gi-l48))
  (define cmds-sp0
    (translate-bot-actions->sc2-raw-commands
     '((pull-workers-attack (98103) 98104 45.0 60.0)
       (build evolution-chamber 32.0 56.0)
       (build spire 32.0 56.0))
     (make-test-obs 1200 600 400 (list z-lair z-pool z-drn1 z-ling))
     #:game-info gi-l48))
  (define sp0-won-drone?
    (and (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1158))) cmds-sp0)
         (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1156))) cmds-sp0))))
  ;; Negative guard: when 1 Spire already exists, duplicate Spire yields to `hatchery` (1152)!
  (define z-sp1 (mk-l48-u 98105 92 1 32.0 64.0 #:hp 850.0 #:rad 1.0))
  (define cmds-sp1
    (translate-bot-actions->sc2-raw-commands
     '((build spire 32.0 56.0)
       (build hatchery 68.0 60.0))
     (make-test-obs 1500 600 400 (list z-lair z-pool z-sp1 z-drn1))
     #:game-info gi-l48))
  (define hatch-beat-dup-spire?
    (and (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1152))) cmds-sp1)
         (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1158))) cmds-sp1))))
  ;; Part B: Multi-Hatchery creep-ring fallback across Main (28,60), Natural (68,60), 3rd (68,96):
  ;; Mock WS ONLY accepts Spire (1158) in 3rd Hatchery's outer 9.5t east creep ring [76.0..79.0, 94.5..97.5]
  ;; (strictly outside default 8.5t inner radius from all 3 Hatcheries!).
  (define z-nat  (mk-l48-u 98111 86  1 68.0 60.0 #:hp 1500.0 #:rad 2.75))
  (define z-3rd  (mk-l48-u 98112 86  1 68.0 96.0 #:hp 1500.0 #:rad 2.75))
  (define z-drn2 (mk-l48-u 98113 104 1 70.0 96.0 #:hp 40.0   #:rad 0.375))
  (define z-units-b
    (append (list z-lair z-nat z-3rd z-pool z-drn1 z-drn2)
            (mk-l48-mins 98120 28.0 60.0 -6.5)
            (mk-l48-mins 98130 68.0 60.0 -6.5)
            (mk-l48-mins 98140 68.0 96.0 -6.5)))
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (define spire-3rd-ring-pt
    (let-values ([(ws _rc cleanup!)
                  (l48-start-mock-ws
                   (lambda (ab px py)
                     (if (and (= ab 1158) (>= px 76.0) (<= px 79.0) (>= py 94.5) (<= py 97.5)) 1 2)))])
      (define cs (translate-bot-actions->sc2-raw-commands
                  '((build spawning-pool 28.0 60.0)
                    (build spire 28.0 60.0))
                  (make-test-obs 5200 600 400 z-units-b)
                  #:ws-conn ws #:game-info gi-l48))
      (cleanup!)
      (define c1158 (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1158))) cs))
      (and c1158 (sc2-raw-unit-command-target-pos c1158))))
  (check-true "l48-p0-3a1-first-spire-core-macro-priority-and-multi-hatch-creep-ring-fallback"
              (and sp0-won-drone?
                   hatch-beat-dup-spire?
                   (sc2-point2d? spire-3rd-ring-pt)
                   (>= (sc2-point2d-x spire-3rd-ring-pt) 76.0)
                   (<= (sc2-point2d-x spire-3rd-ring-pt) 79.0)
                   (>= (sc2-point2d-y spire-3rd-ring-pt) 94.5)
                   (<= (sc2-point2d-y spire-3rd-ring-pt) 97.5)))

  ;; 2. L48-P0-3a2 (`#12`): Blocked Natural pad tracking (`SC2-EXPANSION-PAD-BLOCK-STREAK`):
  ;;    After >= 2 consecutive blocked `RequestQuery` responses on Natural `(60, 98)`,
  ;;    `find-best-expansion-placement` automatically demotes Natural behind the unblocked 3rd
  ;;    pad `(58, 56)` even when Natural is explicitly requested, then reclaims Natural cleanly
  ;;    after the `224f` decay window once clear (and clears on new match reset)!
  (define e-nex  (mk-l48-u 98201 59 1 30.0 95.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75))
  (define e-prb  (mk-l48-u 98202 84 1 34.0 95.0 #:hp 20.0   #:sh 20.0   #:rad 0.375))
  (define e-units
    (append (list e-nex e-prb)
            (mk-l48-mins 98210 30.0 95.0 -6.5)
            (mk-l48-mins 98220 60.0 98.0  6.5)
            (mk-l48-mins 98230 58.0 56.0  6.5)))
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 400 0 e-units) #:game-info gi-l48))
  (hash-clear! SC2-EXPANSION-PAD-BLOCK-STREAK)
  (define-values (exp-q1 exp-q2 exp-streak-after-2)
    (let-values ([(ws _rc cleanup!)
                  (l48-start-mock-ws
                   (lambda (ab px py)
                     ;; Block ALL placements near Natural (60, 98); allow 3rd (58, 56)
                     (if (and (= ab 880) (<= (hypot (- px 58.0) (- py 56.0)) 6.0)) 1 2)))])
      (define p1 (find-best-expansion-placement ws 880 30.0 95.0 e-units
                                                #:req-x 60.0 #:req-y 98.0
                                                #:game-info gi-l48 #:cur-loop 1000))
      (define p2 (find-best-expansion-placement ws 880 30.0 95.0 e-units
                                                #:req-x 60.0 #:req-y 98.0
                                                #:game-info gi-l48 #:cur-loop 1040))
      (cleanup!)
      (define st
        (for/first ([(_k v) (in-hash SC2-EXPANSION-PAD-BLOCK-STREAK)] #:when (pair? v))
          (car v)))
      (values p1 p2 (or st 0))))
  ;; Query 3 (offline / explicit Natural request within 224f): streak >= 2 demotes Natural -> picks 3rd (58, 56)!
  (define exp-q3-demoted
    (find-best-expansion-placement #f 880 30.0 95.0 e-units
                                   #:req-x 60.0 #:req-y 98.0
                                   #:game-info gi-l48 #:cur-loop 1080))
  ;; Query 4 (+360f past 224f decay, Natural clear again): Natural is reclaimed and streak removed!
  (define-values (exp-q4-reclaimed exp-streak-cleared?)
    (let-values ([(ws _rc cleanup!)
                  (l48-start-mock-ws (lambda (ab _px _py) (if (= ab 880) 1 2)))])
      (define p4 (find-best-expansion-placement ws 880 30.0 95.0 e-units
                                                #:req-x 60.0 #:req-y 98.0
                                                #:game-info gi-l48 #:cur-loop 1400))
      (cleanup!)
      (values p4 (= (hash-count SC2-EXPANSION-PAD-BLOCK-STREAK) 0))))
  ;; Verify match reset (`cur-loop = 1400 -> 4`) clears SC2-EXPANSION-PAD-BLOCK-STREAK
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 1400 400 0 e-units) #:game-info gi-l48))
  (hash-set! SC2-EXPANSION-PAD-BLOCK-STREAK '(60 . 98) '(3 . 1400))
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 400 0 e-units) #:game-info gi-l48))
  (define exp-streak-reset-ok? (= (hash-count SC2-EXPANSION-PAD-BLOCK-STREAK) 0))
  (check-true "l48-p0-3a2-blocked-natural-expansion-2plus-fallback-to-3rd-pad"
              (and (sc2-point2d? exp-q1)
                   (<= (hypot (- (sc2-point2d-x exp-q1) 58.0) (- (sc2-point2d-y exp-q1) 56.0)) 5.0)
                   (sc2-point2d? exp-q2)
                   (<= (hypot (- (sc2-point2d-x exp-q2) 58.0) (- (sc2-point2d-y exp-q2) 56.0)) 5.0)
                   (>= exp-streak-after-2 2)
                   (sc2-point2d? exp-q3-demoted)
                   (<= (hypot (- (sc2-point2d-x exp-q3-demoted) 58.0) (- (sc2-point2d-y exp-q3-demoted) 56.0)) 5.0)
                   (sc2-point2d? exp-q4-reclaimed)
                   (<= (hypot (- (sc2-point2d-x exp-q4-reclaimed) 60.0) (- (sc2-point2d-y exp-q4-reclaimed) 98.0)) 5.0)
                   exp-streak-cleared?
                   exp-streak-reset-ok?))

  ;; 3. L48-P0-3a3 (`#72`): Under `< 4:00` early ground rush (`>= 3` enemy Zerglings within `35t`),
  ;;    first `cybernetics-core` (`cnt = 0`) ignores the contested Natural Pylon `(56, 34)` and anchors
  ;;    directly on the safe Main Pylon `(36, 32)` with tight (`< 1.0t`) emergency spacing in ONE RPC!
  (define p48-nex  (mk-l48-u 98301 59 1 30.0 32.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75))
  (define p48-pym  (mk-l48-u 98302 60 1 36.0 32.0 #:hp 200.0  #:sh 200.0  #:rad 1.0))
  (define p48-pyn  (mk-l48-u 98303 60 1 56.0 34.0 #:hp 200.0  #:sh 200.0  #:rad 1.0))
  (define p48-gw1  (mk-l48-u 98304 62 1 39.0 35.0 #:hp 500.0  #:sh 500.0  #:rad 1.5))
  (define p48-prb  (mk-l48-u 98305 84 1 36.0 35.0 #:hp 20.0   #:sh 20.0   #:rad 0.375))
  (define p48-lings
    (for/list ([i (in-range 4)])
      (mk-l48-u (+ 98310 i) 105 4 (+ 54.0 (* i 0.6)) 34.0 #:hp 35.0 #:rad 0.375)))
  (define p48-obs
    (sc2-observation 2800 (sc2-player-common 1 300 50 31 20 8 12 0 0 0 0)
                     (append (list p48-nex p48-pym p48-pyn p48-gw1 p48-prb) p48-lings)
                     '()
                     (list (sc2-power-source (sc2-point2d 36.0 32.0) 6.5 98302)
                           (sc2-power-source (sc2-point2d 56.0 34.0) 6.5 98303))
                     #f '() '() '() '() '() '()))
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (define-values (cyb-rush-pt cyb-rush-rpcs)
    (let-values ([(ws rpc-cnt cleanup!)
                  (l48-start-mock-ws
                   (lambda (ab px py)
                     ;; Only accept CyberCore (894) in a tight 1t-adjacent pocket right south of Main Pylon (36, 32):
                     ;; center (36.5, 29.5) is dist 2.55 from Main Pylon (36,32) — passes tight (<1.0t) spacing
                     ;; and AABB clearance (2.45), while rejected by normal 2.0t spacing (req-d = 2.0/2.85)!
                     (if (and (= ab 894)
                              (>= px 34.0) (<= px 38.0)
                              (>= py 28.0) (<= py 30.0))
                         1
                         2)))])
      (define cs (translate-bot-actions->sc2-raw-commands
                  '((build cybernetics-core 56.0 34.0))
                  p48-obs
                  #:ws-conn ws #:game-info gi-l48))
      (cleanup!)
      (define c894 (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 894))) cs))
      (values (and c894 (sc2-raw-unit-command-target-pos c894)) (unbox rpc-cnt))))
  (check-true "l48-p0-3a3-early-rush-cybernetics-core-1t-main-pylon-emergency-fallback"
              (and (sc2-point2d? cyb-rush-pt)
                   (<= (hypot (- (sc2-point2d-x cyb-rush-pt) 36.0) (- (sc2-point2d-y cyb-rush-pt) 32.0)) 6.5)
                   (> (hypot (- (sc2-point2d-x cyb-rush-pt) 56.0) (- (sc2-point2d-y cyb-rush-pt) 34.0)) 12.0)
                   (= cyb-rush-rpcs 1)))

  ;; 4. L48-W3: `pull-workers-attack` (both 4-arg unit-target & 3-arg point-target forms) is elevated
  ;;    to P0 urgent survival (`urgent-survival-cmd? = #t`, `wire-cmd-priority-tier = 0`) and survives
  ;;    governor throttling ahead of routine P2/P3 orders!
  (define t48-cc   (mk-l48-u 98400 18 1 30.0 32.0 #:hp 1500.0 #:rad 2.75))
  (define t48-scv1 (mk-l48-u 98401 45 1 32.0 32.0 #:hp 45.0   #:rad 0.375))
  (define t48-scv2 (mk-l48-u 98402 45 1 32.5 32.5 #:hp 45.0   #:rad 0.375))
  (define t48-scv3 (mk-l48-u 98403 45 1 33.0 32.0 #:hp 45.0   #:rad 0.375))
  (define t48-scv4 (mk-l48-u 98404 45 1 33.5 32.5 #:hp 45.0   #:rad 0.375))
  (define t48-ep   (mk-l48-u 98490 84 4 36.0 32.0 #:hp 20.0   #:sh 20.0 #:rad 0.375))
  (define t48-obs-p0
    (make-test-obs 1200 150 0 (list t48-cc t48-scv1 t48-scv2 t48-scv3 t48-scv4 t48-ep)))
  (define pwa-cmds
    (translate-bot-actions->sc2-raw-commands
     '((pull-workers-attack (98401 98402) 98490 36.0 32.0)
       (pull-workers-attack (98403 98404) 36.0 32.0))
     t48-obs-p0
     #:game-info gi-l48))
  (define pwa-u-cmd
    (findf (lambda (c)
             (and (sc2-raw-unit-command? c)
                  (= (sc2-raw-unit-command-ability-id c) 23)
                  (= (sc2-raw-unit-command-target-unit-tag c) 98490)))
           pwa-cmds))
  (define pwa-pt-cmd
    (findf (lambda (c)
             (and (sc2-raw-unit-command? c)
                  (= (sc2-raw-unit-command-ability-id c) 23)
                  (= (sc2-raw-unit-command-target-unit-tag c) 0)))
           pwa-cmds))
  (define gov-l48 (make-wire-apm-governor #:target-apm 250.0 #:hard-cap-apm 480.0))
  (define gov-p0-out
    (govern-sc2-wire-actions!
     gov-l48
     (list (sc2-raw-unit-command 23 (sc2-point2d 60.0 60.0) 0 '(99901) #f)
           pwa-u-cmd
           pwa-pt-cmd)
     1200
     t48-obs-p0))
  (check-true "l48-w3-pull-workers-attack-p0-urgent-survival-priority"
              (and (sc2-raw-unit-command? pwa-u-cmd)
                   (urgent-survival-cmd? pwa-u-cmd)
                   (= (wire-cmd-priority-tier pwa-u-cmd) 0)
                   (sc2-raw-unit-command? pwa-pt-cmd)
                   (urgent-survival-cmd? pwa-pt-cmd)
                   (= (wire-cmd-priority-tier pwa-pt-cmd) 0)
                   (ormap (lambda (c)
                            (and (sc2-raw-unit-command? c)
                                 (= (sc2-raw-unit-command-ability-id c) 23)
                                 (= (sc2-raw-unit-command-target-unit-tag c) 98490)
                                 (urgent-survival-cmd? c)))
                          gov-p0-out)
                   (ormap (lambda (c)
                            (and (sc2-raw-unit-command? c)
                                 (= (sc2-raw-unit-command-ability-id c) 23)
                                 (= (sc2-raw-unit-command-target-unit-tag c) 0)
                                 (urgent-survival-cmd? c)))
                          gov-p0-out)))

  ;; 5. L48-W3: `resume-halted-building` runs ahead of & protects its resuming SCV via
  ;;    `builder-worker-tags` + `commanded-combat-tags` + P0 urgent survival so same-frame
  ;;    `pull-workers-attack` / `mineral-walk` / `worker-drill-stack-attack` NEVER clobber it!
  (define r48-cc   (mk-l48-u 98500 18 1 30.0 32.0 #:hp 1500.0 #:rad 2.75))
  (define r48-rax  (mk-l48-u 98510 21 1 34.0 35.0 #:hp 500.0  #:rad 1.5 #:bp 0.5))
  (define r48-scv1 (mk-l48-u 98501 45 1 32.0 34.0 #:hp 45.0   #:rad 0.375))
  (define r48-scv2 (mk-l48-u 98502 45 1 31.5 31.5 #:hp 45.0   #:rad 0.375))
  (define r48-scv3 (mk-l48-u 98503 45 1 32.5 31.5 #:hp 45.0   #:rad 0.375))
  (define r48-min  (mk-l48-u 98520 341 3 23.5 32.0 #:hp 1000.0 #:rad 1.0 #:mins 1500))
  (define r48-ep   (mk-l48-u 98590 84 4 33.5 32.0 #:hp 20.0   #:sh 20.0 #:rad 0.375))
  (define r48-obs
    (make-test-obs 1240 150 0 (list r48-cc r48-rax r48-scv1 r48-scv2 r48-scv3 r48-min r48-ep)))
  (define resume-cmds
    (translate-bot-actions->sc2-raw-commands
     '((pull-workers-attack (98501 98502 98503) 98590 33.5 32.0)
       (mineral-walk (98501) 98520 23.5 32.0)
       (worker-drill-stack-attack (98501 98502) 98520 98590 33.5 32.0)
       (resume-halted-building 98501 98510))
     r48-obs
     #:game-info gi-l48))
  (define c-resume
    (findf (lambda (c)
             (and (sc2-raw-unit-command? c)
                  (= (sc2-raw-unit-command-ability-id c) 1)
                  (= (sc2-raw-unit-command-target-unit-tag c) 98510)))
           resume-cmds))
  (define c-pull
    (findf (lambda (c)
             (and (sc2-raw-unit-command? c)
                  (= (sc2-raw-unit-command-ability-id c) 23)))
           resume-cmds))
  (define scv1-clobbered-by-other?
    (ormap (lambda (c)
             (and (sc2-raw-unit-command? c)
                  (not (= (sc2-raw-unit-command-ability-id c) 1))
                  (memv 98501 (sc2-raw-unit-command-unit-tags c))))
           resume-cmds))
  (check-true "l48-w3-resume-halted-building-p0-and-no-same-frame-pull-clobber"
              (and (sc2-raw-unit-command? c-resume)
                   (equal? (sc2-raw-unit-command-unit-tags c-resume) '(98501))
                   (urgent-survival-cmd? c-resume)
                   (= (wire-cmd-priority-tier c-resume) 0)
                   (sc2-raw-unit-command? c-pull)
                   (equal? (sort (sc2-raw-unit-command-unit-tags c-pull) <) '(98502 98503))
                   (urgent-survival-cmd? c-pull)
                   (= (wire-cmd-priority-tier c-pull) 0)
                   (not scv1-clobbered-by-other?)))

  ;; 6. L48-W2 (`#1095`/`#1096`): Safe Rear-Side Secondary-TH Perimeter Fallback:
  ;;    (a) At `cur-prod-miss-streak = 0`, Barracks #3+ prefers safe Main interior spots
  ;;        ahead of secondary-TH perimeter (never skipping open Main interior!).
  ;;    (b) At `cur-prod-miss-streak = 1`, when Main & Natural interior are blocked and
  ;;        the 3rd CC's minerals sit on its rear/NE side (so away-from-minerals points SW
  ;;        toward Enemy Main `(20, 20)`!), exposed forward/enemy-facing perimeter spots
  ;;        (`dot(pt - th, enemy_dir) > 0`) are REJECTED and ONLY rear-side spots (`dot <= 0`) win!
  (define gi-l48-ne
    (sc2-game-info "L48RearPerimMap" "" '() '(128 128) '(4 4 124 124)
                   (list (sc2-point2d 20.0 20.0)) w3-full-grid #f w3-full-grid))
  (define p2-cc-main (mk-l48-u 98601 18 1 104.0 104.0 #:hp 1500.0 #:rad 2.75))
  (define p2-cc-3rd  (mk-l48-u 98602 18 1  76.0  76.0 #:hp 1500.0 #:rad 2.75))
  (define p2-rx1     (mk-l48-u 98603 21 1  98.0 108.0 #:hp 1000.0 #:rad 1.5))
  (define p2-rx2     (mk-l48-u 98604 21 1  98.0 100.0 #:hp 1000.0 #:rad 1.5))
  (define p2-scv     (mk-l48-u 98605 45 1  96.0 104.0 #:hp 45.0   #:rad 0.375))
  ;; Place 3rd CC minerals on its East/NE rear side (+6.5 x) so away-from-minerals points West/SW toward enemy (20,20)!
  (define p2-units
    (append (list p2-cc-main p2-cc-3rd p2-rx1 p2-rx2 p2-scv)
            (mk-l48-mins 98610 104.0 104.0  6.5)
            (mk-l48-mins 98620  76.0  76.0  6.5)))
  ;; Part A (`miss-streak = 0`): Both Main interior [90..112, 90..112] AND 3rd CC perimeter open -> picks Main interior!
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 500 200 p2-units) #:game-info gi-l48-ne))
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-set! SC2-PROD-PLACEMENT-MISS-STREAK 'barracks 0)
  (define rx3-streak0-pt
    (let-values ([(ws _rc cleanup!)
                  (l48-start-mock-ws
                   (lambda (ab px py)
                     (if (and (= ab 321)
                              (or (and (>= px 92.0) (<= px 112.0) (>= py 92.0) (<= py 112.0))
                                  (and (>= px 64.0) (<= px 88.0) (>= py 64.0) (<= py 88.0))))
                         1 2)))])
      (define cs (translate-bot-actions->sc2-raw-commands
                  '((build barracks 104.0 104.0))
                  (make-test-obs 6000 500 200 p2-units)
                  #:ws-conn ws #:game-info gi-l48-ne))
      (cleanup!)
      (define c321 (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 321))) cs))
      (and c321 (sc2-raw-unit-command-target-pos c321))))
  ;; Part B (`miss-streak = 1`): Main blocked; on 3rd CC (76,76), BOTH exposed forward SW pocket [66..71, 66..71]
  ;; AND safe rear NW/NE flank [68..84, 80..87] (where dot((pt - (76,76)), (-1,-1)) <= 0 -> (px-76)+(py-76) >= 0!)
  ;; are open on mock-WS -> secondary-th-perimeter-anchors MUST pick the safe rear half-plane (NEVER exposed SW)!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-set! SC2-PROD-PLACEMENT-MISS-STREAK 'barracks 1)
  (define rx3-streak1-pt
    (let-values ([(ws _rc cleanup!)
                  (l48-start-mock-ws
                   (lambda (ab px py)
                     (if (and (= ab 321)
                              (or (and (>= px 66.0) (<= px 71.0) (>= py 66.0) (<= py 71.0))
                                  (and (>= px 68.0) (<= px 84.0) (>= py 81.0) (<= py 87.0))))
                         1 2)))])
      (define cs (translate-bot-actions->sc2-raw-commands
                  '((build barracks 104.0 104.0))
                  (make-test-obs 6200 500 200 p2-units)
                  #:ws-conn ws #:game-info gi-l48-ne))
      (cleanup!)
      (define c321 (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 321))) cs))
      (and c321 (sc2-raw-unit-command-target-pos c321))))
  (check-true "l48-w2-secondary-th-perimeter-rear-halfplane-and-miss-streak-fallback"
              (and (sc2-point2d? rx3-streak0-pt)
                   (>= (sc2-point2d-x rx3-streak0-pt) 90.0)
                   (>= (sc2-point2d-y rx3-streak0-pt) 90.0)
                   (sc2-point2d? rx3-streak1-pt)
                   ;; Strictly in rear half-plane relative to 3rd CC (76,76) away from enemy (20,20):
                   ;; enemy_dir = (-0.707, -0.707), so rear half-plane is (px - 76) + (py - 76) >= 0!
                   (>= (+ (- (sc2-point2d-x rx3-streak1-pt) 76.0)
                          (- (sc2-point2d-y rx3-streak1-pt) 76.0))
                       0.0)))
  (hash-clear! SC2-PROD-PLACEMENT-MISS-STREAK)
  (hash-clear! SC2-EXPANSION-PAD-BLOCK-STREAK))

;; ---------------------------------------------------------------------------
;; [Loop 49] Wave 1 Track 2: Pro-Grade Base & Wall Placement Upgrades + Law 1
;; Stage-2 Expanded Placement Ring Fallback (100% North/South Spawn Symmetric)
;; ---------------------------------------------------------------------------
(let ()
  (define (hypot dx dy) (sqrt (+ (* dx dx) (* dy dy))))
  (define (mk-l49-u tag utype alliance x y
                    #:hp [hp 100.0] #:sh [sh 0.0] #:rad [rad 0.75]
                    #:bp [bp 1.0] #:mins [mins 0] #:orders [orders '()])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 (if (= alliance 4) 2 0))
              (sc2-point3d x y 8.0) 0.0 rad bp 0 #f #t #f
              hp hp sh sh 50.0 200.0 mins 0 #f #f #f #t #f orders 0 '() 0 0 0.0 0 0 0 0 '() 0 0))
  (define (mk-l49-mins-x base-tag cx cy dx-off)
    (for/list ([i (in-range 8)])
      (mk-l49-u (+ base-tag i) 341 3 (+ cx dx-off) (+ cy (- (* 1.5 i) 5.25)) #:hp 1000.0 #:rad 1.0 #:mins 1500)))
  (define (mk-l49-mins-y base-tag cx cy dy-off)
    (for/list ([i (in-range 8)])
      (mk-l49-u (+ base-tag i) 341 3 (+ cx (- (* 1.5 i) 5.25)) (+ cy dy-off) #:hp 1000.0 #:rad 1.0 #:mins 1500)))
  (define (mk-l49-gi enemy-sx enemy-sy [enemy-race 'Random])
    (sc2-game-info "L49LayoutMap" ""
                   (list (hash 'player-id 1 'race-requested 'Protoss)
                         (hash 'player-id 2 'race-requested enemy-race))
                   '(128 128) '(4 4 124 124)
                   (list (sc2-point2d enemy-sx enemy-sy)) w3-full-grid #f w3-full-grid))
  (define (l49-start-mock-ws decide-fn)
    (define-values (c-in s-out) (make-pipe))
    (define-values (s-in c-out) (make-pipe))
    (define ws (sc2-ws-conn "127.0.0.1" 0 "/sc2api" c-in c-out #f (box 1)))
    (define th
      (thread
       (lambda ()
         (let lp ()
           (define b0 (read-byte s-in))
           (unless (eof-object? b0)
             (define b1 (read-byte s-in))
             (define masked? (not (zero? (bitwise-and b1 #x80))))
             (define len0 (bitwise-and b1 #x7F))
             (define plen
               (cond [(< len0 126) len0]
                     [(= len0 126) (integer-bytes->integer (read-bytes 2 s-in) #f #t)]
                     [else (integer-bytes->integer (read-bytes 8 s-in) #f #t)]))
             (define mkey (if masked? (read-bytes 4 s-in) #f))
             (define raw (read-bytes plen s-in))
             (define payload
               (if masked?
                   (let ([out (make-bytes plen)])
                     (for ([i (in-range plen)])
                       (bytes-set! out i (bitwise-xor (bytes-ref raw i) (bytes-ref mkey (modulo i 4)))))
                     out)
                   raw))
             (define req-f (decode-protobuf-message payload))
             (define id-p (assoc 97 req-f))
             (define id-b (if id-p (encode-uint32 97 (third id-p)) #""))
             (define q-p (assoc 14 req-f))
             (when q-p
               (define qf (decode-protobuf-message (third q-p)))
               (define p-items (filter (lambda (e) (= (first e) 3)) qf))
               (define res-b
                 (apply bytes-append
                        (for/list ([it (in-list p-items)])
                          (define itf (decode-protobuf-message (third it)))
                          (define ab (let ([p (assoc 1 itf)]) (if p (third p) 0)))
                          (define tp-e (assoc 2 itf))
                          (define-values (px py)
                            (if tp-e
                                (let ([ptf (decode-protobuf-message (third tp-e))])
                                  (values (let ([xp (assoc 1 ptf)])
                                            (if (and xp (bytes? (third xp)))
                                                (floating-point-bytes->real (third xp) #f)
                                                0.0))
                                          (let ([yp (assoc 2 ptf)])
                                            (if (and yp (bytes? (third yp)))
                                                (floating-point-bytes->real (third yp) #f)
                                                0.0))))
                                (values 0.0 0.0)))
                          (encode-submessage-field 3 (encode-int32 1 (decide-fn ab px py))))))
               (define resp (bytes-append (encode-submessage-field 14 res-b) id-b (encode-int32 99 3)))
               (define rlen (bytes-length resp))
               (define rhdr
                 (cond [(< rlen 126) (bytes #x82 rlen)]
                       [(<= rlen 65535) (bytes-append (bytes #x82 126) (integer->integer-bytes rlen 2 #f #t))]
                       [else (bytes-append (bytes #x82 127) (integer->integer-bytes rlen 8 #f #t))]))
               (write-bytes rhdr s-out)
               (write-bytes resp s-out)
               (flush-output s-out))
             (lp))))))
    (values ws (lambda () (close-output-port c-out) (close-input-port c-in) (thread-wait th))))

  ;; 1. L49-2a1: Protoss Anti-"Pylon Soup" (`>= 9.0t` spacing) + Natural Pylon Coverage
  ;;    verified in BOTH South and North spawns (100% spawn-symmetric)!
  (define gi-sw (mk-l49-gi 98.0 96.0 'Terran))
  (define gi-ne (mk-l49-gi 30.0 32.0 'Terran))
  ;; Part A: 2 existing Main Pylons at (36, 32) and (36, 42) -> 3rd non-wall Pylon stays >= 9.0t from both!
  (define p49-nex  (mk-l49-u 99101 59 1 30.0 32.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75))
  (define p49-py1  (mk-l49-u 99102 60 1 36.0 32.0 #:hp 200.0  #:sh 200.0  #:rad 1.0))
  (define p49-py2  (mk-l49-u 99103 60 1 36.0 42.0 #:hp 200.0  #:sh 200.0  #:rad 1.0))
  (define p49-prb  (mk-l49-u 99104 84 1 34.0 36.0 #:hp 20.0   #:sh 20.0   #:rad 0.375))
  (define p49-u-a  (append (list p49-nex p49-py1 p49-py2 p49-prb) (mk-l49-mins-x 99110 30.0 32.0 -6.5)))
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 300 0 p49-u-a) #:game-info gi-sw))
  (define py3-cmds
    (translate-bot-actions->sc2-raw-commands '((build pylon 36.0 36.0))
                                             (make-test-obs 2000 300 0 p49-u-a) #:game-info gi-sw))
  (define py3-pt
    (let ([c (findf (lambda (x) (and (sc2-raw-unit-command? x) (= (sc2-raw-unit-command-ability-id x) 881))) py3-cmds)])
      (and c (sc2-raw-unit-command-target-pos c))))
  ;; Part B (South): Natural Nexus (60, 32) starts (`bp = 0.20`) with 0 Natural Pylons -> next Pylon goes to Natural!
  (define p49-nat-s (mk-l49-u 99120 59 1 60.0 32.0 #:hp 500.0 #:sh 500.0 #:rad 2.75 #:bp 0.20))
  (define p49-u-s   (append (list p49-nex p49-nat-s p49-py1 p49-prb)
                            (mk-l49-mins-x 99110 30.0 32.0 -6.5)
                            (mk-l49-mins-y 99130 60.0 32.0 -6.5)))
  (define py-nat-s-cmds
    (translate-bot-actions->sc2-raw-commands '((build pylon 36.0 36.0))
                                             (make-test-obs 2400 300 0 p49-u-s) #:game-info gi-sw))
  (define py-nat-s-pt
    (let ([c (findf (lambda (x) (and (sc2-raw-unit-command? x) (= (sc2-raw-unit-command-ability-id x) 881))) py-nat-s-cmds)])
      (and c (sc2-raw-unit-command-target-pos c))))
  ;; Part C (North mirror): Main (98, 96), Natural (68, 96) (`bp = 0.20`) -> next Pylon goes to North Natural!
  (define p49-nex-n (mk-l49-u 99141 59 1 98.0 96.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75))
  (define p49-nat-n (mk-l49-u 99142 59 1 68.0 96.0 #:hp 500.0  #:sh 500.0  #:rad 2.75 #:bp 0.20))
  (define p49-py1-n (mk-l49-u 99143 60 1 92.0 96.0 #:hp 200.0  #:sh 200.0  #:rad 1.0))
  (define p49-prb-n (mk-l49-u 99144 84 1 90.0 94.0 #:hp 20.0   #:sh 20.0   #:rad 0.375))
  (define p49-u-n   (append (list p49-nex-n p49-nat-n p49-py1-n p49-prb-n)
                            (mk-l49-mins-x 99150 98.0 96.0  6.5)
                            (mk-l49-mins-y 99160 68.0 96.0  6.5)))
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 300 0 p49-u-n) #:game-info gi-ne))
  (define py-nat-n-cmds
    (translate-bot-actions->sc2-raw-commands '((build pylon 92.0 92.0))
                                             (make-test-obs 2400 300 0 p49-u-n) #:game-info gi-ne))
  (define py-nat-n-pt
    (let ([c (findf (lambda (x) (and (sc2-raw-unit-command? x) (= (sc2-raw-unit-command-ability-id x) 881))) py-nat-n-cmds)])
      (and c (sc2-raw-unit-command-target-pos c))))
  (check-true "l49-2a1-protoss-anti-pylon-soup-9t-spacing-and-natural-pylon-coverage"
              (and (sc2-point2d? py3-pt)
                   (>= (hypot (- (sc2-point2d-x py3-pt) 36.0) (- (sc2-point2d-y py3-pt) 32.0)) 8.95)
                   (>= (hypot (- (sc2-point2d-x py3-pt) 36.0) (- (sc2-point2d-y py3-pt) 42.0)) 8.95)
                   (sc2-point2d? py-nat-s-pt)
                   (<= (hypot (- (sc2-point2d-x py-nat-s-pt) 60.0) (- (sc2-point2d-y py-nat-s-pt) 32.0)) 9.5)
                   (sc2-point2d? py-nat-n-pt)
                   (<= (hypot (- (sc2-point2d-x py-nat-n-pt) 68.0) (- (sc2-point2d-y py-nat-n-pt) 96.0)) 9.5)))

  ;; 2. L49-2a2: Protoss Protected Tech — Fragile tech (`RoboticsFacility`/`Stargate`) NEVER claims
  ;;    front `PvZ` natural `'wall-slot` and tucks inside Main, while sturdy `Gateway` still walls!
  (define gi-pvz (mk-l49-gi 98.0 96.0 'Zerg))
  (define pvz-nex  (mk-l49-u 99201 59 1 30.0 32.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75))
  (define pvz-pym  (mk-l49-u 99202 60 1 34.0 30.0 #:hp 200.0  #:sh 200.0  #:rad 1.0))
  (define pvz-pyn  (mk-l49-u 99203 60 1 56.0 36.0 #:hp 200.0  #:sh 200.0  #:rad 1.0))
  (define pvz-prb  (mk-l49-u 99204 84 1 36.0 32.0 #:hp 20.0   #:sh 20.0   #:rad 0.375))
  (define pvz-wall (list (reserved-aabb 58.5 36.5 1.5 1.5 'wall-slot #f 99999)))
  (define pvz-obs
    (sc2-observation 3200 (sc2-player-common 1 500 300 40 24 8 16 0 0 0 0)
                     (list pvz-nex pvz-pym pvz-pyn pvz-prb) '()
                     (list (sc2-power-source (sc2-point2d 34.0 30.0) 6.5 99202)
                           (sc2-power-source (sc2-point2d 56.0 36.0) 6.5 99203))
                     #f '() '() '() '() '() '()))
  (define robo-cmds-49
    (translate-bot-actions->sc2-raw-commands '((build robotics-facility 58.5 36.5))
                                             pvz-obs #:game-info gi-pvz #:reserved-aabbs pvz-wall))
  (define robo-pt-49
    (let ([c (findf (lambda (x) (and (sc2-raw-unit-command? x) (= (sc2-raw-unit-command-ability-id x) 893))) robo-cmds-49)])
      (and c (sc2-raw-unit-command-target-pos c))))
  (define sg-cmds-49
    (translate-bot-actions->sc2-raw-commands '((build stargate 58.5 36.5))
                                             pvz-obs #:game-info gi-pvz #:reserved-aabbs pvz-wall))
  (define sg-pt-49
    (let ([c (findf (lambda (x) (and (sc2-raw-unit-command? x) (= (sc2-raw-unit-command-ability-id x) 889))) sg-cmds-49)])
      (and c (sc2-raw-unit-command-target-pos c))))
  (define gw-wall-cmds-49
    (translate-bot-actions->sc2-raw-commands '((build gateway 58.5 36.5))
                                             pvz-obs #:game-info gi-pvz #:reserved-aabbs pvz-wall))
  (define gw-wall-pt-49
    (let ([c (findf (lambda (x) (and (sc2-raw-unit-command? x) (= (sc2-raw-unit-command-ability-id x) 883))) gw-wall-cmds-49)])
      (and c (sc2-raw-unit-command-target-pos c))))
  (check-true "l49-2a2-protoss-protected-tech-out-of-pvz-wall-slot-and-tucked-in-main"
              (and (sc2-point2d? robo-pt-49)
                   (<= (hypot (- (sc2-point2d-x robo-pt-49) 34.0) (- (sc2-point2d-y robo-pt-49) 30.0)) 6.5)
                   (> (hypot (- (sc2-point2d-x robo-pt-49) 58.5) (- (sc2-point2d-y robo-pt-49) 36.5)) 12.0)
                   (sc2-point2d? sg-pt-49)
                   (<= (hypot (- (sc2-point2d-x sg-pt-49) 34.0) (- (sc2-point2d-y sg-pt-49) 30.0)) 6.5)
                   (sc2-point2d? gw-wall-pt-49)
                   (<= (hypot (- (sc2-point2d-x gw-wall-pt-49) 58.5) (- (sc2-point2d-y gw-wall-pt-49) 36.5)) 3.0)))

  ;; 3. L49-2b1: Terran Natural Depot Wall (`#3/#4`) + Back-Edge Drop-Vision Depot (`#5`),
  ;;    verified in BOTH South and North spawns (100% N/S symmetry)!
  ;; South spawn: Main CC (30, 32), Nat CC (60, 32) (minerals South at 60, 25.5), 2 Main Depots -> Depot #3 at Nat front!
  (define t49-ccm-s (mk-l49-u 99301 18 1 30.0 32.0 #:hp 1500.0 #:rad 2.75))
  (define t49-ccn-s (mk-l49-u 99302 18 1 60.0 32.0 #:hp 1000.0 #:rad 2.75 #:bp 0.25))
  (define t49-dp1-s (mk-l49-u 99303 19 1 39.0 36.0 #:hp 400.0  #:rad 1.0))
  (define t49-dp2-s (mk-l49-u 99304 19 1 41.0 34.0 #:hp 400.0  #:rad 1.0))
  (define t49-scv-s (mk-l49-u 99305 45 1 34.0 34.0 #:hp 45.0   #:rad 0.375))
  (define t49-u-s   (append (list t49-ccm-s t49-ccn-s t49-dp1-s t49-dp2-s t49-scv-s)
                            (mk-l49-mins-x 99310 30.0 32.0 -6.5)
                            (mk-l49-mins-y 99320 60.0 32.0 -6.5)))
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 300 0 t49-u-s) #:game-info gi-sw))
  (define dp3-s-pt
    (let* ([cs (translate-bot-actions->sc2-raw-commands '((build supply-depot 32.0 38.0))
                                                        (make-test-obs 2800 300 0 t49-u-s) #:game-info gi-sw)]
           [c (findf (lambda (x) (and (sc2-raw-unit-command? x) (= (sc2-raw-unit-command-ability-id x) 319))) cs)])
      (and c (sc2-raw-unit-command-target-pos c))))
  ;; North spawn mirror: Main CC (98, 96), Nat CC (68, 96) (minerals North at 68, 102.5) -> Depot #3 at North Nat front!
  (define t49-ccm-n (mk-l49-u 99331 18 1 98.0 96.0 #:hp 1500.0 #:rad 2.75))
  (define t49-ccn-n (mk-l49-u 99332 18 1 68.0 96.0 #:hp 1000.0 #:rad 2.75 #:bp 0.25))
  (define t49-dp1-n (mk-l49-u 99333 19 1 89.0 92.0 #:hp 400.0  #:rad 1.0))
  (define t49-dp2-n (mk-l49-u 99334 19 1 87.0 94.0 #:hp 400.0  #:rad 1.0))
  (define t49-scv-n (mk-l49-u 99335 45 1 94.0 94.0 #:hp 45.0   #:rad 0.375))
  (define t49-u-n   (append (list t49-ccm-n t49-ccn-n t49-dp1-n t49-dp2-n t49-scv-n)
                            (mk-l49-mins-x 99340 98.0 96.0 6.5)
                            (mk-l49-mins-y 99350 68.0 96.0 6.5)))
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 300 0 t49-u-n) #:game-info gi-ne))
  (define dp3-n-pt
    (let* ([cs (translate-bot-actions->sc2-raw-commands '((build supply-depot 96.0 90.0))
                                                        (make-test-obs 2800 300 0 t49-u-n) #:game-info gi-ne)]
           [c (findf (lambda (x) (and (sc2-raw-unit-command? x) (= (sc2-raw-unit-command-ability-id x) 319))) cs)])
      (and c (sc2-raw-unit-command-target-pos c))))
  ;; Back-edge drop-vision Depot (#5 once 2 Main + 2 Nat Depots exist): lands behind Main CC away from enemy (98, 96)!
  (define t49-dp3-s (mk-l49-u 99306 19 1 64.0 38.0 #:hp 400.0 #:rad 1.0))
  (define t49-dp4-s (mk-l49-u 99307 19 1 66.0 36.0 #:hp 400.0 #:rad 1.0))
  (define t49-u-s5  (append (list t49-ccm-s t49-ccn-s t49-dp1-s t49-dp2-s t49-dp3-s t49-dp4-s t49-scv-s)
                            (mk-l49-mins-x 99310 30.0 32.0 -6.5)
                            (mk-l49-mins-y 99320 60.0 32.0 -6.5)))
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 300 0 t49-u-s5) #:game-info gi-sw))
  (define dp5-back-pt
    (let* ([cs (translate-bot-actions->sc2-raw-commands '((build supply-depot 36.0 36.0))
                                                        (make-test-obs 3600 300 0 t49-u-s5) #:game-info gi-sw)]
           [c (findf (lambda (x) (and (sc2-raw-unit-command? x) (= (sc2-raw-unit-command-ability-id x) 319))) cs)])
      (and c (sc2-raw-unit-command-target-pos c))))
  (check-true "l49-2b1-terran-natural-depot-wall-and-back-edge-vision-north-south-symmetric"
              (and (sc2-point2d? dp3-s-pt)
                   (<= (hypot (- (sc2-point2d-x dp3-s-pt) 60.0) (- (sc2-point2d-y dp3-s-pt) 32.0)) 11.0)
                   (> (sc2-point2d-y dp3-s-pt) 32.0) ;; away from South minerals (25.5) toward front!
                   (sc2-point2d? dp3-n-pt)
                   (<= (hypot (- (sc2-point2d-x dp3-n-pt) 68.0) (- (sc2-point2d-y dp3-n-pt) 96.0)) 11.0)
                   (< (sc2-point2d-y dp3-n-pt) 96.0) ;; away from North minerals (102.5) toward front!
                   (sc2-point2d? dp5-back-pt)
                   (>= (hypot (- (sc2-point2d-x dp5-back-pt) 30.0) (- (sc2-point2d-y dp5-back-pt) 32.0)) 6.5)
                   ;; Behind Main CC (30,32) away from Enemy (98,96): (x-30)+(y-32) < 0!
                   (< (+ (- (sc2-point2d-x dp5-back-pt) 30.0) (- (sc2-point2d-y dp5-back-pt) 32.0)) 0.0)))

  ;; 4. L49-2b2: Terran Compact Main Addon-Swap Cluster (`miss-streak = 0`):
  ;;    Factory clusters tightly beside existing Main Barracks (`<= 13.5t` from Main CC, east `+2.5x` addon clear!)
  (define sw-cc  (mk-l49-u 99401 18 1 30.0 60.0 #:hp 1500.0 #:rad 2.75))
  (define sw-rax (mk-l49-u 99402 21 1 38.0 60.0 #:hp 1000.0 #:rad 1.5))
  (define sw-scv (mk-l49-u 99403 45 1 35.0 62.0 #:hp 45.0   #:rad 0.375))
  (define sw-us  (append (list sw-cc sw-rax sw-scv) (mk-l49-mins-x 99410 30.0 60.0 -6.5)))
  (hash-clear! SC2-PROD-PLACEMENT-MISS-STREAK)
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 400 200 sw-us) #:game-info gi-sw))
  (define fac-swap-pt
    (let* ([cs (translate-bot-actions->sc2-raw-commands '((build factory 46.0 78.0))
                                                        (make-test-obs 3200 400 200 sw-us) #:game-info gi-sw)]
           [c (findf (lambda (x) (and (sc2-raw-unit-command? x) (= (sc2-raw-unit-command-ability-id x) 328))) cs)])
      (and c (sc2-raw-unit-command-target-pos c))))
  (check-true "l49-2b2-terran-compact-main-addon-swap-cluster"
              (and (sc2-point2d? fac-swap-pt)
                   (<= (hypot (- (sc2-point2d-x fac-swap-pt) 30.0) (- (sc2-point2d-y fac-swap-pt) 60.0)) 13.5)
                   (<= (hypot (- (sc2-point2d-x fac-swap-pt) 38.0) (- (sc2-point2d-y fac-swap-pt) 60.0)) 7.5)))

  ;; 5. L49-2c: Zerg Pro-Style Layout — Rear/Mineral-Arc SpawningPool (North & South symmetric),
  ;;    Mineral-Line Routine SporeCrawler (~3.5t toward minerals), & ZvZ Natural Front Choke RoachWarren!
  (define gi-zvz-s (mk-l49-gi 98.0 68.0 'Zerg))
  (define gi-zvz-n (mk-l49-gi 30.0 60.0 'Zerg))
  ;; Part A1 (South): Main Hatch (30, 60), minerals West (23.5, 60) -> SpawningPool tucks on rear/mineral arc (x < 30)!
  (define z49-hs  (mk-l49-u 99501 86  1 30.0 60.0 #:hp 1500.0 #:rad 2.75))
  (define z49-ds  (mk-l49-u 99502 104 1 28.0 58.0 #:hp 40.0   #:rad 0.375))
  (define z49-us  (append (list z49-hs z49-ds) (mk-l49-mins-x 99510 30.0 60.0 -6.5)))
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 400 100 z49-us) #:game-info gi-zvz-s))
  (define pool-s-pt
    (let* ([cs (translate-bot-actions->sc2-raw-commands '((build spawning-pool 36.0 60.0))
                                                        (make-test-obs 1200 400 100 z49-us) #:game-info gi-zvz-s)]
           [c (findf (lambda (x) (and (sc2-raw-unit-command? x) (= (sc2-raw-unit-command-ability-id x) 1155))) cs)])
      (and c (sc2-raw-unit-command-target-pos c))))
  ;; Part A2 (North mirror): Main Hatch (98, 68), minerals East (104.5, 68) -> SpawningPool tucks East (x > 98)!
  (define z49-hn  (mk-l49-u 99521 86  1 98.0 68.0 #:hp 1500.0 #:rad 2.75))
  (define z49-dn  (mk-l49-u 99522 104 1 100.0 66.0 #:hp 40.0  #:rad 0.375))
  (define z49-un  (append (list z49-hn z49-dn) (mk-l49-mins-x 99530 98.0 68.0 6.5)))
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 400 100 z49-un) #:game-info gi-zvz-n))
  (define pool-n-pt
    (let* ([cs (translate-bot-actions->sc2-raw-commands '((build spawning-pool 92.0 68.0))
                                                        (make-test-obs 1200 400 100 z49-un) #:game-info gi-zvz-n)]
           [c (findf (lambda (x) (and (sc2-raw-unit-command? x) (= (sc2-raw-unit-command-ability-id x) 1155))) cs)])
      (and c (sc2-raw-unit-command-target-pos c))))
  ;; Part B: Routine SporeCrawler (NO cloak threat!) -> lands inside/behind mineral line (~3.5t toward 23.5, 60)!
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 400 100 z49-us) #:game-info gi-zvz-s))
  (define spore-ml-pt
    (let* ([cs (translate-bot-actions->sc2-raw-commands '((build spore-crawler 36.0 60.0))
                                                        (make-test-obs 2400 400 100 z49-us) #:game-info gi-zvz-s)]
           [c (findf (lambda (x) (and (sc2-raw-unit-command? x) (= (sc2-raw-unit-command-ability-id x) 1167))) cs)])
      (and c (sc2-raw-unit-command-target-pos c))))
  ;; Part C: ZvZ Natural front choke partial wall (`RoachWarren`) once Natural Hatchery completes!
  (define z49-hnat (mk-l49-u 99541 86 1 60.0 60.0 #:hp 1500.0 #:rad 2.75 #:bp 1.0))
  (define z49-uzvz (append (list z49-hs z49-hnat z49-ds)
                           (mk-l49-mins-x 99510 30.0 60.0 -6.5)
                           (mk-l49-mins-y 99550 60.0 60.0 -6.5)))
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 400 100 z49-uzvz) #:game-info gi-zvz-s))
  (define rw-zvz-pt
    (let* ([cs (translate-bot-actions->sc2-raw-commands '((build roach-warren 32.0 60.0))
                                                        (make-test-obs 3600 400 100 z49-uzvz) #:game-info gi-zvz-s)]
           [c (findf (lambda (x) (and (sc2-raw-unit-command? x) (= (sc2-raw-unit-command-ability-id x) 1165))) cs)])
      (and c (sc2-raw-unit-command-target-pos c))))
  (check-true "l49-2c-zerg-pro-layout-rear-pool-mineral-spore-and-zvz-nat-choke-wall"
              (and (sc2-point2d? pool-s-pt) (< (sc2-point2d-x pool-s-pt) 30.0)
                   (sc2-point2d? pool-n-pt) (> (sc2-point2d-x pool-n-pt) 98.0)
                   (sc2-point2d? spore-ml-pt)
                   (< (sc2-point2d-x spore-ml-pt) 30.0)
                   (<= (hypot (- (sc2-point2d-x spore-ml-pt) 23.5) (- (sc2-point2d-y spore-ml-pt) 60.0)) 6.5)
                   (sc2-point2d? rw-zvz-pt)
                   (<= (hypot (- (sc2-point2d-x rw-zvz-pt) 60.0) (- (sc2-point2d-y rw-zvz-pt) 60.0)) 9.5)
                   (> (sc2-point2d-y rw-zvz-pt) 59.0)))

  ;; 6. L49-2d: Law 1 Stage-2 Expanded Placement Ring Fallback across ALL 3 races via
  ;;    `#:watchdog-expand-ring-syms` / `sc2-request-ring-expand!` / `miss-streak >= 2`!
  ;; (a) Terran non-prod (`engineering-bay`): Main blocked; watchdog ring-expand lands on 22t outer ring!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-clear! SC2-PROD-PLACEMENT-MISS-STREAK)
  (hash-clear! SC2-WATCHDOG-RING-EXPAND-SYMS)
  (define ebay-stage2-pt
    (let-values ([(ws cleanup!)
                  (l49-start-mock-ws
                   (lambda (ab px py)
                     (if (and (= ab 322) (>= px 50.0) (<= px 56.0) (>= py 58.0) (<= py 64.0)) 1 2)))])
      (define cs (translate-bot-actions->sc2-raw-commands
                  '((build engineering-bay 30.0 60.0))
                  (make-test-obs 5000 400 100 sw-us)
                  #:ws-conn ws #:game-info gi-sw
                  #:watchdog-expand-ring-syms '(engineering-bay)))
      (cleanup!)
      (let ([c (findf (lambda (x) (and (sc2-raw-unit-command? x) (= (sc2-raw-unit-command-ability-id x) 322))) cs)])
        (and c (sc2-raw-unit-command-target-pos c)))))
  ;; (b) Protoss non-gateway (`robotics-facility`): All Pylons boxed out; `sc2-request-ring-expand!`
  ;;     triggers Stage-2 relief Pylon (881) cleanly!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (sc2-request-ring-expand! 'robotics-facility 5100)
  (define robo-relief-pylon?
    (let-values ([(ws cleanup!)
                  (l49-start-mock-ws
                   (lambda (ab _px _py) (if (= ab 881) 1 2)))])
      (define obs-p-box
        (sc2-observation 5100 (sc2-player-common 1 300 200 40 24 8 16 0 0 0 0)
                         (list p49-nex p49-py1 p49-prb) '()
                         (list (sc2-power-source (sc2-point2d 36.0 32.0) 6.5 99102))
                         #f '() '() '() '() '() '()))
      (define cs (translate-bot-actions->sc2-raw-commands
                  '((build robotics-facility 36.0 32.0))
                  obs-p-box #:ws-conn ws #:game-info gi-sw))
      (cleanup!)
      (and (findf (lambda (x) (and (sc2-raw-unit-command? x) (= (sc2-raw-unit-command-ability-id x) 881))) cs) #t)))
  ;; (c) Zerg non-spire (`roach-warren`): Main blocked; `miss-streak = 2` triggers Stage-2 multi-Hatchery
  ;;     creep-ring fallback onto Natural's outer 9.5t ring [68..71, 58..62]!
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (hash-set! SC2-PROD-PLACEMENT-MISS-STREAK 'roach-warren 2)
  (define rw-stage2-pt
    (let-values ([(ws cleanup!)
                  (l49-start-mock-ws
                   (lambda (ab px py)
                     (if (and (= ab 1165) (>= px 68.0) (<= px 71.0) (>= py 58.0) (<= py 62.0)) 1 2)))])
      (define cs (translate-bot-actions->sc2-raw-commands
                  '((build roach-warren 30.0 60.0))
                  (make-test-obs 5200 400 100 z49-uzvz)
                  #:ws-conn ws #:game-info gi-sw))
      (cleanup!)
      (let ([c (findf (lambda (x) (and (sc2-raw-unit-command? x) (= (sc2-raw-unit-command-ability-id x) 1165))) cs)])
        (and c (sc2-raw-unit-command-target-pos c)))))
  (check-true "l49-2d-law1-stage2-expanded-placement-ring-fallback-all-races"
              (and (sc2-point2d? ebay-stage2-pt)
                   (>= (sc2-point2d-x ebay-stage2-pt) 50.0) (<= (sc2-point2d-x ebay-stage2-pt) 56.0)
                   robo-relief-pylon?
                   (sc2-point2d? rw-stage2-pt)
                   (>= (sc2-point2d-x rw-stage2-pt) 68.0) (<= (sc2-point2d-x rw-stage2-pt) 71.0)))

  ;; 7. L49-1B (`#1156`/`#1157`): Baneling Morph Ability ID `80 -> 4121` (`MORPHTOBANELING_BANELING`)
  ;;    + non-primary inbound decode alias `80 -> 'morph-baneling` + order protection `'morph`
  ;;    + Suite 34.1 tight Hatchery-adjacent SpawningPool (`has-mins? = #f`) recovery!
  (define b49-hatch (mk-l49-u 99701 86  1 30.0 60.0 #:hp 1500.0 #:rad 2.75))
  (define b49-bnest (mk-l49-u 99702 96  1 27.0 65.0 #:hp 850.0  #:rad 1.5))
  (define b49-ling1 (mk-l49-u 99703 105 1 32.0 62.0 #:hp 35.0   #:rad 0.375))
  (define b49-ling2 (mk-l49-u 99704 105 1 33.0 62.0 #:hp 35.0   #:rad 0.375))
  (define b49-obs   (make-test-obs 4200 400 200 (list b49-hatch b49-bnest b49-ling1 b49-ling2)))
  (define b49-train-cmds
    (translate-bot-actions->sc2-raw-commands '((train baneling)) b49-obs #:game-info gi-sw))
  (define b49-morph-cmds
    (translate-bot-actions->sc2-raw-commands '((morph baneling)) b49-obs #:game-info gi-sw))
  (define b49-c-train
    (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 4121))) b49-train-cmds))
  (define b49-c-morph
    (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 4121))) b49-morph-cmds))
  (define b49-any-legacy-80?
    (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 80)))
           (append b49-train-cmds b49-morph-cmds)))
  ;; Tight Hatchery-adjacent SpawningPool recovery (`has-mins? = #f`, Chebyshev 3.95..4.5 only!)
  (hash-clear! SC2-PLACEMENT-POS-CACHE)
  (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
  (define tight-pool-pt
    (let-values ([(ws cleanup!)
                  (l49-start-mock-ws
                   (lambda (ab px py)
                     (define ch (max (abs (- px 141.5)) (abs (- py 38.5))))
                     (if (and (= ab 1155) (>= ch 3.95) (< ch 4.5)) 1 2)))])
      (define th-z (mk-l49-u 99711 86  1 141.5 38.5 #:hp 1500.0 #:rad 2.75))
      (define dr-z (mk-l49-u 99712 104 1 139.5 38.5 #:hp 40.0   #:rad 0.375))
      (define cs (translate-bot-actions->sc2-raw-commands
                  '((build spawning-pool 137.5 38.5))
                  (make-test-obs 1200 300 0 (list th-z dr-z))
                  #:ws-conn ws))
      (cleanup!)
      (let ([c (findf (lambda (x) (and (sc2-raw-unit-command? x) (= (sc2-raw-unit-command-ability-id x) 1155))) cs)])
        (and c (sc2-raw-unit-command-target-pos c)))))
  (check-true "l49-1b-baneling-morph-4121-and-tight-hatchery-adjacent-spawning-pool"
              (and (= (ability-symbol->sc2-id 'morph-baneling) 4121)
                   (= (ability-symbol->sc2-id 'train-baneling) 4121)
                   (= (train-symbol->ability-id 'baneling) 4121)
                   (= (morph-symbol->ability-id 'baneling) 4121)
                   (eq? (sc2-id->ability-symbol 4121) 'morph-baneling)
                   (eq? (sc2-id->ability-symbol 80) 'morph-baneling)
                   (eq? (sc2-order-protection-class 4121) 'morph)
                   (eq? (sc2-canonical-order-ability 4121) 'morph-baneling)
                   (eq? (sc2-canonical-order-ability 80) 'morph-baneling)
                   (sc2-raw-unit-command? b49-c-train)
                   (sc2-raw-unit-command? b49-c-morph)
                   (not b49-any-legacy-80?)
                   (sc2-point2d? tight-pool-pt)
                   (>= (max (abs (- (sc2-point2d-x tight-pool-pt) 141.5))
                            (abs (- (sc2-point2d-y tight-pool-pt) 38.5)))
                       3.95)
                   (< (max (abs (- (sc2-point2d-x tight-pool-pt) 141.5))
                           (abs (- (sc2-point2d-y tight-pool-pt) 38.5)))
                      4.5)))

  ;; 8. L50 (`#1218`): SC2 4.10 outbound ability IDs for Auto-Turret (`349 -> 1764`),
  ;;    Viper Consume (`2069 -> 2073`), Swarm Host Spawn Locusts (`1990 -> 2704`), and
  ;;    Overlord Generate Creep (`1882 -> 1692`) while preserving inbound legacy decoding!
  (define l50-raven (mk-l49-u 99801 56  1 40.0 60.0 #:hp 140.0 #:rad 0.75))
  (define l50-viper (mk-l49-u 99802 499 1 42.0 60.0 #:hp 150.0 #:rad 1.0))
  (define l50-hatch (mk-l49-u 99803 86  1 38.0 60.0 #:hp 1500.0 #:rad 2.75))
  (define l50-shost (mk-l49-u 99804 494 1 44.0 60.0 #:hp 160.0 #:rad 0.875))
  (define l50-ovl   (mk-l49-u 99805 106 1 46.0 60.0 #:hp 200.0 #:rad 1.0))
  (define l50-obs   (make-test-obs 4500 400 200 (list l50-raven l50-viper l50-hatch l50-shost l50-ovl)))
  (define l50-cmds
    (translate-bot-actions->sc2-raw-commands
     '((cast-spell 99801 auto-turret 45.0 62.0)
       (cast-spell 99802 viper-consume 99803)
       (cast-spell 99804 spawn-locusts 50.0 62.0)
       (cast-spell 99805 overlord-generate-creep))
     l50-obs #:game-info gi-sw))
  (define (l50-find-ab id)
    (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) id))) l50-cmds))
  (define l50-c-1764 (l50-find-ab 1764))
  (define l50-c-2073 (l50-find-ab 2073))
  (define l50-c-2704 (l50-find-ab 2704))
  (define l50-c-1692 (l50-find-ab 1692))
  (define l50-any-legacy?
    (ormap (lambda (c)
             (and (sc2-raw-unit-command? c)
                  (memv (sc2-raw-unit-command-ability-id c) '(349 2069 1990 1882))))
           l50-cmds))
  (define (l50-wire-ok? cmd)
    (and cmd
         (let-values ([(ok? _info) (verify-sc2-action-bytes (encode-sc2-action cmd))])
           ok?)))
  (define (l50-catalog-id sym)
    (let ([e (findf (lambda (x) (eq? (ability-catalog-entry-sym x) sym)) COMPLETE-LOTV-ABILITY-LIST)])
      (and e (ability-catalog-entry-ability-id e))))
  (check-true "l50-sc2-410-outbound-ability-ids-auto-turret-viper-locust-creep"
              (and (= (ability-symbol->sc2-id 'auto-turret) 1764)
                   (= (ability-symbol->sc2-id 'build-auto-turret) 1764)
                   (= (spell-symbol->ability-id 'auto-turret) 1764)
                   (= (hash-ref SC2-SPELL-ABILITY-IDS 'auto-turret 0) 1764)
                   (= AUTO-TURRET-ABILITY-ID 1764)
                   (= (l50-catalog-id 'auto-turret) 1764)
                   (= (ability-symbol->sc2-id 'viper-consume) 2073)
                   (= (ability-symbol->sc2-id 'consume) 2073)
                   (= (ability-symbol->sc2-id 'viper-consume-structure) 2073)
                   (= (spell-symbol->ability-id 'viper-consume) 2073)
                   (= (l50-catalog-id 'viper-consume) 2073)
                   (= (l50-catalog-id 'viper-consume-structure) 2073)
                   (= (ability-symbol->sc2-id 'spawn-locusts) 2704)
                   (= (ability-symbol->sc2-id 'spawn-locusts-flying) 2704)
                   (= (ability-symbol->sc2-id 'swarm-host-spawn-locusts) 2704)
                   (= (spell-symbol->ability-id 'spawn-locusts) 2704)
                   (= (hash-ref SC2-SPELL-ABILITY-IDS 'spawn-locusts 0) 2704)
                   (= (l50-catalog-id 'spawn-locusts) 2704)
                   (= (ability-symbol->sc2-id 'overlord-generate-creep) 1692)
                   (= (ability-symbol->sc2-id 'generate-creep) 1692)
                   (= (spell-symbol->ability-id 'overlord-generate-creep) 1692)
                   (= (hash-ref SC2-SPELL-ABILITY-IDS 'overlord-generate-creep 0) 1692)
                   ;; Inbound decoder accepts BOTH SC2 4.10 and legacy IDs
                   (eq? (sc2-id->ability-symbol 1764) 'auto-turret)
                   (eq? (sc2-id->ability-symbol 349) 'auto-turret)
                   (eq? (sc2-id->ability-symbol 379) 'auto-turret)
                   (eq? (sc2-id->ability-symbol 2073) 'viper-consume)
                   (eq? (sc2-id->ability-symbol 2069) 'viper-consume)
                   (eq? (sc2-id->ability-symbol 2704) 'spawn-locusts)
                   (eq? (sc2-id->ability-symbol 1990) 'spawn-locusts)
                   (eq? (sc2-id->ability-symbol 1692) 'overlord-generate-creep)
                   (eq? (sc2-id->ability-symbol 1882) 'overlord-generate-creep)
                   ;; Canonical order & protection consistency
                   (eq? (sc2-canonical-order-ability 1764) 'auto-turret)
                   (eq? (sc2-canonical-order-ability 349) 'auto-turret)
                   (eq? (sc2-canonical-order-ability 2073) 'viper-consume)
                   (eq? (sc2-canonical-order-ability 2069) 'viper-consume)
                   (eq? (sc2-canonical-order-ability 2704) 'spawn-locusts)
                   (eq? (sc2-canonical-order-ability 1990) 'spawn-locusts)
                   (eq? (sc2-canonical-order-ability 1692) 'overlord-generate-creep)
                   (eq? (sc2-canonical-order-ability 1882) 'overlord-generate-creep)
                   (eq? (sc2-order-protection-class 1764) 'cast-walk)
                   (eq? (sc2-order-protection-class 2704) 'cast-walk)
                   (eq? (sc2-order-protection-class 2073) 'channel)
                   ;; Translation emits 4.10 IDs with P0 tier and passes wire verifier
                   (not l50-any-legacy?)
                   (l50-wire-ok? l50-c-1764) (= (wire-cmd-priority-tier l50-c-1764) 0)
                   (l50-wire-ok? l50-c-2073) (= (wire-cmd-priority-tier l50-c-2073) 0)
                   (l50-wire-ok? l50-c-2704) (= (wire-cmd-priority-tier l50-c-2704) 0)
                   (l50-wire-ok? l50-c-1692) (= (wire-cmd-priority-tier l50-c-1692) 0)))

  ;; 9. L50 (`#1222`): Exhaustive SC2 4.10 Buff, Ability, Research-Building & Upgrade ID Audit
  (define l50-fc   (mk-l49-u 99811 30  1 30.0 60.0 #:hp 750.0 #:rad 1.5)) ;; Fusion Core
  (define l50-stl  (mk-l49-u 99812 41  1 35.0 60.0 #:hp 400.0 #:rad 1.0)) ;; Starport TechLab
  (define l50-fb   (mk-l49-u 99813 64  1 40.0 60.0 #:hp 500.0 #:rad 1.5)) ;; Fleet Beacon
  (define l50-loc  (mk-l49-u 99814 693 1 45.0 60.0 #:hp 50.0  #:rad 0.375)) ;; Locust Flying
  (define l50-shd  (mk-l49-u 99815 801 1 48.0 60.0 #:hp 1.0   #:rad 0.5)) ;; Adept Phase Shift
  (define l50-obs2 (make-test-obs 4600 600 600 (list l50-fc l50-stl l50-fb l50-loc l50-shd)))
  (define l50-ab-cmds
    (translate-bot-actions->sc2-raw-commands
     '((research advanced-ballistics)
       (research anion-pulse-crystals)
       (locust-swoop 99814 55.0 62.0)
       (cast-spell 99815 cancel-adept-shade))
     l50-obs2 #:game-info gi-sw))
  (define l50-cr-cmds
    (translate-bot-actions->sc2-raw-commands
     '((research caduceus-reactor))
     l50-obs2 #:game-info gi-sw))
  (define (l50-find2 cs id)
    (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) id))) cs))
  (define l50-c-1533 (l50-find2 l50-ab-cmds 1533))
  (define l50-c-1535 (l50-find2 l50-cr-cmds 1535))
  (define l50-c-46   (l50-find2 l50-ab-cmds 46))
  (define l50-c-2387 (l50-find2 l50-ab-cmds 2387))
  (define l50-c-2596 (l50-find2 l50-ab-cmds 2596))
  (define (l50-upg-entry sym)
    (findf (lambda (x) (eq? (upgrade-catalog-entry-sym x) sym)) COMPLETE-LOTV-UPGRADE-LIST))
  (define l50-u-hr  (l50-upg-entry 'hyperflight-rotors))
  (define l50-u-ab  (l50-upg-entry 'advanced-ballistics))
  (define l50-u-apc (l50-upg-entry 'anion-pulse-crystals))
  (check-true "l50-exhaustive-sc2-410-buff-ability-research-upgrade-ids"
              (and ;; 1. Corrected & added Buff IDs
                   (eq? (buff-id->symbol 99)  'oracle-weapon)
                   (eq? (buff-id->symbol 56)  'oracle-cloak-field-effect)
                   (eq? (buff-id->symbol 129) 'oracle-stasis-trap-target)
                   (eq? (buff-id->symbol 6)   'ghost-cloak)
                   (eq? (buff-id->symbol 288) 'transfusion)
                   (eq? (buff-id->symbol 28)  'psi-storm)
                   (eq? (buff-id->symbol 280) 'anti-armor-missile)
                   (eq? (buff-id->symbol 277) 'interference-matrix)
                   (eq? (buff-id->symbol 5)   'graviton-beam)
                   (eq? (buff-id->symbol 36)  'contaminate)
                   (eq? (buff-id->symbol 72)  'stasis)
                   (eq? (buff-id->symbol 122) 'void-ray-prismatic-alignment)
                   (eq? (buff-id->symbol 276) 'permanently-cloaked)
                   ;; 2. Outbound Ability IDs + inbound legacy decoding
                   (= (ability-symbol->sc2-id 'cancel-adept-shade) 2596)
                   (eq? (sc2-id->ability-symbol 2596) 'cancel-adept-shade)
                   (= (ability-symbol->sc2-id 'spawn-creep-tumor-queen) 1694)
                   (= (ability-symbol->sc2-id 'build-creep-tumor-queen) 1694)
                   (eq? (sc2-id->ability-symbol 1662) 'spawn-creep-tumor-queen)
                   (= (ability-symbol->sc2-id 'morph-lurker-den) 1163)
                   (= (ability-symbol->sc2-id 'build-lurker-den) 1163)
                   (eq? (sc2-id->ability-symbol 1163) 'build-lurker-den)
                   (eq? (sc2-id->ability-symbol 2112) 'morph-lurker-den)
                   (= (research-symbol->ability-id 'advanced-ballistics) 1533)
                   (eq? (sc2-id->ability-symbol 1533) 'research-advanced-ballistics)
                   (eq? (sc2-id->ability-symbol 805)  'research-advanced-ballistics)
                   (= (research-symbol->ability-id 'caduceus-reactor) 1535)
                   (= (research-symbol->ability-id 'medivac-caduceus-reactor) 1535)
                   (= (research-symbol->ability-id 'anion-pulse-crystals) 46)
                   (= (ability-symbol->sc2-id 'locust-swoop) 2387)
                   (= (hash-ref SC2-SPELL-ABILITY-IDS 'locust-swoop 0) 2387)
                   (= LOCUST-SWOOP-ABILITY-ID 2387)
                   (= (l50-catalog-id 'locust-swoop) 2387)
                   (eq? (sc2-id->ability-symbol 2387) 'locust-swoop)
                   (eq? (sc2-id->ability-symbol 2706) 'locust-swoop)
                   (eq? (sc2-canonical-order-ability 2387) 'locust-swoop)
                   (eq? (sc2-canonical-order-ability 2706) 'locust-swoop)
                   ;; 3. Upgrade IDs + catalog sync
                   (= (upgrade-symbol->sc2-id 'hyperflight-rotors) 136)
                   (eq? (sc2-id->upgrade-symbol 136) 'hyperflight-rotors)
                   (= (upgrade-symbol->sc2-id 'anion-pulse-crystals) 99)
                   (eq? (sc2-id->upgrade-symbol 99) 'anion-pulse-crystals)
                   (and l50-u-hr  (= (upgrade-catalog-entry-upgrade-id l50-u-hr) 136))
                   (and l50-u-ab  (= (upgrade-catalog-entry-research-id l50-u-ab) 1533))
                   (and l50-u-apc (= (upgrade-catalog-entry-research-id l50-u-apc) 46)
                                  (= (upgrade-catalog-entry-upgrade-id l50-u-apc) 99))
                   ;; 4. Live translation routes advanced-ballistics & caduceus-reactor to Fusion Core (99811, NOT Starport TechLab 99812!)
                   (l50-wire-ok? l50-c-1533)
                   (equal? (sc2-raw-unit-command-unit-tags l50-c-1533) '(99811))
                   (l50-wire-ok? l50-c-1535)
                   (equal? (sc2-raw-unit-command-unit-tags l50-c-1535) '(99811))
                   (l50-wire-ok? l50-c-46)
                   (equal? (sc2-raw-unit-command-unit-tags l50-c-46) '(99813))
                   (l50-wire-ok? l50-c-2387) (= (wire-cmd-priority-tier l50-c-2387) 0)
                   (l50-wire-ok? l50-c-2596) (= (wire-cmd-priority-tier l50-c-2596) 0)))

  ;; 10. L51 (`#1263`): SC2 5.0.14 Wire Fixes (`4111` Microbial Shroud, `3743 <-> 3745` Overseer swap,
  ;;     `142` Mothership Recall, `4109` Hydralisk Frenzy, `807`/`49`/`770`/`1284` research + `279`/`297`/`300`/`302` buffs)
  ;;     + Dynamic `ResponseData` Sync (patch-mod A `299` vs patch-mod B `300` InterferenceMatrix, `4107` unavailable / `4111` available)
  (define l51-inf  (mk-l49-u 99821 111 1 30.0 60.0 #:hp 90.0   #:rad 0.75)) ;; Infestor
  (define l51-moth (mk-l49-u 99822 10  1 34.0 60.0 #:hp 350.0  #:rad 1.375)) ;; Mothership
  (define l51-hyd  (mk-l49-u 99823 107 1 36.0 60.0 #:hp 90.0   #:rad 0.625)) ;; Hydralisk
  (define l51-ovs  (mk-l49-u 99824 129 1 38.0 60.0 #:hp 200.0  #:rad 1.0)) ;; Overseer
  (define l51-stl  (mk-l49-u 99825 41  1 40.0 60.0 #:hp 400.0  #:rad 1.0)) ;; StarportTechLab
  (define l51-ftl  (mk-l49-u 99826 39  1 42.0 60.0 #:hp 400.0  #:rad 1.0)) ;; FactoryTechLab
  (define l51-fb   (mk-l49-u 99827 64  1 44.0 60.0 #:hp 500.0  #:rad 1.5)) ;; FleetBeacon
  (define l51-hden (mk-l49-u 99828 91  1 46.0 60.0 #:hp 850.0  #:rad 1.5)) ;; HydraliskDen
  (define l51-nex  (mk-l49-u 99829 59  1 48.0 60.0 #:hp 1000.0 #:rad 2.5)) ;; Nexus
  (define l51-bat  (mk-l49-u 99830 1910 1 50.0 60.0 #:hp 150.0 #:rad 1.0)) ;; ShieldBattery
  (define l51-obs  (make-test-obs 4700 800 800
                                  (list l51-inf l51-moth l51-hyd l51-ovs l51-stl l51-ftl l51-fb l51-hden l51-nex l51-bat)))
  (define l51-cmds
    (translate-bot-actions->sc2-raw-commands
     '((cast-spell 99821 microbial-shroud 35.0 62.0)
       (cast-spell 99822 mothership-mass-recall 35.0 62.0)
       (cast-spell 99823 hydralisk-frenzy)
       (cast-spell 99824 morph-oversight-mode)
       (research interference-matrix)
       (research hurricane-thrusters)
       (research tectonic-destabilizers)
       (research hydralisk-frenzy))
     l51-obs #:game-info gi-sw))
  (define l51-c-4111 (l50-find2 l51-cmds 4111))
  (define l51-c-142  (l50-find2 l51-cmds 142))
  (define l51-c-4109 (l50-find2 l51-cmds 4109))
  (define l51-c-3743 (l50-find2 l51-cmds 3743))
  (define l51-c-807  (l50-find2 l51-cmds 807))
  (define l51-c-770  (l50-find2 l51-cmds 770))
  (define l51-c-49   (l50-find2 l51-cmds 49))
  (define l51-c-1284 (l50-find2 l51-cmds 1284))
  ;; Dynamic ResponseData sync: test patch-mod A (InterferenceMatrix=299, 4107=avail)
  ;; then patch-mod B (MicrobialShroud=299, InterferenceMatrix=300, 4107=unavail, 4111=avail)
  (define mod-a-data
    (sc2-data (list (sc2-ability-data-entry 4107 "Effect BatteryOvercharge" #t)
                    (sc2-ability-data-entry 4111 "Effect AmorphousArmorcloud" #t))
              '()
              (list (sc2-data-entry 299 "InterferenceMatrix"))
              '() '()))
  (register-sc2-response-data! mod-a-data)
  (define mod-a-im-sym (sc2-id->upgrade-symbol 299))
  (define mod-a-im-id  (upgrade-symbol->sc2-id 'interference-matrix))
  (define mod-a-4107?  (sc2-ability-live-available? 4107))
  (define mod-a-def?   (sc2-upgrade-defined-in-live-data? 'interference-matrix))
  (define mod-b-data
    (sc2-data (list (sc2-ability-data-entry 4107 "Effect BatteryOvercharge" #f)
                    (sc2-ability-data-entry 4111 "Effect AmorphousArmorcloud" #t))
              '()
              (list (sc2-data-entry 296 "HurricaneThrusters")
                    (sc2-data-entry 297 "TempestGroundAttackUpgrade")
                    (sc2-data-entry 298 "Frenzy")
                    (sc2-data-entry 299 "MicrobialShroud")
                    (sc2-data-entry 300 "InterferenceMatrix"))
              '() '()))
  (register-sc2-response-data! mod-b-data)
  (define mod-b-ms-sym  (sc2-id->upgrade-symbol 299))
  (define mod-b-im-sym  (sc2-id->upgrade-symbol 300))
  (define mod-b-im-id   (upgrade-symbol->sc2-id 'interference-matrix))
  (define mod-b-4107?   (sc2-ability-live-available? 4107))
  (define mod-b-4111?   (sc2-ability-live-available? 4111))
  (define mod-b-def?    (sc2-upgrade-defined-in-live-data? 'interference-matrix))
  ;; Wire suppresses 4107 BatteryOvercharge when ResponseData marks 4107 unavailable
  (define mod-b-bo-cmds
    (translate-bot-actions->sc2-raw-commands
     '((cast-spell 99829 battery-overcharge 99830))
     l51-obs #:game-info gi-sw))
  (define mod-b-bo-suppressed? (not (l50-find2 mod-b-bo-cmds 4107)))
  ;; Clean reset restores offline default (`sc2-ability-live-available? 4107` -> `#t`)
  (reset-sc2-live-response-data!)
  (define offline-4107? (sc2-ability-live-available? 4107))
  (check-true "l51-sc2-5014-wire-ids-and-dynamic-response-data-sync"
              (and ;; 1. Corrected 5.0.14 outbound IDs & inbound legacy aliases
                   (= (ability-symbol->sc2-id 'microbial-shroud) 4111)
                   (eq? (sc2-id->ability-symbol 4111) 'microbial-shroud)
                   (eq? (sc2-id->ability-symbol 2545) 'microbial-shroud)
                   (= (ability-symbol->sc2-id 'morph-oversight-mode) 3743)
                   (= (ability-symbol->sc2-id 'morph-overseer-mode) 3745)
                   (eq? (sc2-id->ability-symbol 3743) 'morph-oversight-mode)
                   (eq? (sc2-id->ability-symbol 3745) 'morph-overseer-mode)
                   (= (ability-symbol->sc2-id 'mothership-mass-recall) 142)
                   (eq? (sc2-id->ability-symbol 142) 'mothership-mass-recall)
                   (eq? (sc2-id->ability-symbol 2368) 'mothership-mass-recall)
                   (= (ability-symbol->sc2-id 'hydralisk-frenzy) 4109)
                   (= (research-symbol->ability-id 'interference-matrix) 807)
                   (= (research-symbol->ability-id 'hurricane-thrusters) 770)
                   (= (research-symbol->ability-id 'tectonic-destabilizers) 49)
                   (= (research-symbol->ability-id 'hydralisk-frenzy) 1284)
                   ;; 2. Missing 5.0.14 buffs & upgrades
                   (eq? (buff-id->symbol 279) 'raven-shredder-missile-tint)
                   (eq? (buff-id->symbol 297) 'microbial-shroud)
                   (eq? (buff-id->symbol 300) 'interference-matrix-carrier)
                   (eq? (buff-id->symbol 302) 'hydralisk-frenzy)
                   (= (upgrade-symbol->sc2-id 'caduceus-reactor) 21)
                   (= (upgrade-symbol->sc2-id 'medivac-caduceus-reactor) 21)
                   (= (upgrade-symbol->sc2-id 'hurricane-thrusters) 296)
                   (= (upgrade-symbol->sc2-id 'tectonic-destabilizers) 297)
                   (= (upgrade-symbol->sc2-id 'hydralisk-frenzy) 298)
                   ;; 3. Live translation & research-building routing + wire verifier OK
                   (l50-wire-ok? l51-c-4111) (= (wire-cmd-priority-tier l51-c-4111) 0)
                   (l50-wire-ok? l51-c-142)  (= (wire-cmd-priority-tier l51-c-142) 0)
                   (l50-wire-ok? l51-c-4109) (= (wire-cmd-priority-tier l51-c-4109) 0)
                   (l50-wire-ok? l51-c-3743)
                   (l50-wire-ok? l51-c-807)  (equal? (sc2-raw-unit-command-unit-tags l51-c-807)  '(99825))
                   (l50-wire-ok? l51-c-770)  (equal? (sc2-raw-unit-command-unit-tags l51-c-770)  '(99826))
                   (l50-wire-ok? l51-c-49)   (equal? (sc2-raw-unit-command-unit-tags l51-c-49)   '(99827))
                   (l50-wire-ok? l51-c-1284) (equal? (sc2-raw-unit-command-unit-tags l51-c-1284) '(99828))
                   ;; 4. Dynamic ResponseData map-shift resolution (299 vs 300) & live availability
                   (eq? mod-a-im-sym 'interference-matrix) (= mod-a-im-id 299) mod-a-4107? mod-a-def?
                   (eq? mod-b-ms-sym 'microbial-shroud)
                   (eq? mod-b-im-sym 'interference-matrix)  (= mod-b-im-id 300)
                   (not mod-b-4107?) mod-b-4111? mod-b-def?
                   mod-b-bo-suppressed? offline-4107?))

  ;; 11. L54-W1 (`#1323`): Raised-Depot Wall-Lock Fix —
  ;;     (a) All clear raised depots (`utype=19`) batch into ONE multi-tag `556` command (`2` APM total),
  ;;     (b) `556` is promoted to P1 (and P0 urgent-survival when `friendly-transit?`) so P2 army
  ;;         MOVE/ATTACK spam can NEVER starve ramp lowering,
  ;;     (c) Dropping a depot command (`556`/`558`) in the APM governor clears `SC2-DEPOT-TOGGLE-COOLDOWN`!
  (hash-clear! SC2-DEPOT-TOGGLE-COOLDOWN)
  (define l54-cc  (mk-l49-u 99901 18 1 30.0 30.0 #:hp 1500.0 #:rad 2.75))
  (define l54-d1  (mk-l49-u 99911 19 1 42.0 42.0 #:hp 400.0  #:rad 1.25))
  (define l54-d2  (mk-l49-u 99912 19 1 44.0 44.0 #:hp 400.0  #:rad 1.25))
  (define l54-d3  (mk-l49-u 99913 19 1 46.0 46.0 #:hp 400.0  #:rad 1.25))
  (define l54-d4  (mk-l49-u 99914 19 1 34.0 24.0 #:hp 400.0  #:rad 1.25))
  (define l54-obs-batch (make-test-obs 5000 300 100 (list l54-cc l54-d1 l54-d2 l54-d3 l54-d4)))
  (define l54-cmds-batch (translate-bot-actions->sc2-raw-commands '() l54-obs-batch #:game-info gi-sw))
  (define l54-556-batch
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 556)))
            l54-cmds-batch))
  ;; (b) Friendly Marine requesting transit across depot `99911` promotes batched `556` to P0 urgent-survival
  ;;     AND beats heavy P2 Marine MOVE/ATTACK spam in the APM governor!
  (hash-clear! SC2-DEPOT-TOGGLE-COOLDOWN)
  (define l54-mar-tr
    (mk-l49-u 99921 48 1 41.0 41.0 #:hp 45.0 #:rad 0.375
              #:orders (list (sc2-unit-order 16 (sc2-point3d 80.0 80.0 0.0) 0 0.0))))
  (define l54-obs-tr (make-test-obs 5100 300 100 (list l54-cc l54-d1 l54-d2 l54-mar-tr)))
  (define l54-cmds-tr (translate-bot-actions->sc2-raw-commands '() l54-obs-tr #:game-info gi-sw))
  (define l54-556-tr
    (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 556)))
           l54-cmds-tr))
  (define gov-54-spam (make-wire-apm-governor #:target-apm 410.0 #:hard-cap-apm 485.0))
  (define p2-spam-54
    (for/list ([k (in-range 25)])
      (sc2-raw-unit-command 16 (sc2-point2d (+ 80.0 k) 80.0) 0 (list (+ 98000 k)) #f)))
  (define gov-54-out
    (govern-sc2-wire-actions!
     gov-54-spam
     (append p2-spam-54 (list (sc2-raw-unit-command 556 #f 0 '(99911 99912) #f)))
     5100))
  (define gov-54-emitted-556?
    (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 556)))
           gov-54-out))
  ;; (c) When APM governor drops a depot toggle command (`556`/`558`), SC2-DEPOT-TOGGLE-COOLDOWN is cleared!
  (define gov-54-dry (make-wire-apm-governor #:target-apm 10.0 #:hard-cap-apm 10.0))
  ;; Exhaust rolling headroom (10 APM) via 6 distinct non-coalescable P1 train commands (`524`, 2 APM each)
  (govern-sc2-wire-actions!
   gov-54-dry
   (for/list ([k (in-range 6)])
     (sc2-raw-unit-command 524 #f 0 (list (+ 98500 k)) #f))
   5200)
  (hash-set! SC2-DEPOT-TOGGLE-COOLDOWN 99931 5244)
  (hash-set! SC2-DEPOT-TOGGLE-COOLDOWN 99932 5244)
  (define gov-54-drop-out
    (govern-sc2-wire-actions!
     gov-54-dry
     (list (sc2-raw-unit-command 558 #f 0 '(99931) #f)
           (sc2-raw-unit-command 556 #f 0 '(99932) #f))
     5204))
  (define l54-cd-cleared?
    (and (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (memv (sc2-raw-unit-command-ability-id c) '(556 558))))
                     gov-54-drop-out))
         (not (hash-has-key? SC2-DEPOT-TOGGLE-COOLDOWN 99931))
         (not (hash-has-key? SC2-DEPOT-TOGGLE-COOLDOWN 99932))))
  (check-true "l54-w1-depot-556-batching-p1-urgent-and-dropped-cooldown-clear"
              (and (= (length l54-556-batch) 1)
                   (equal? (sort (sc2-raw-unit-command-unit-tags (car l54-556-batch)) <)
                           '(99911 99912 99913 99914))
                   (= (wire-cmd-priority-tier (car l54-556-batch)) 1)
                   (sc2-raw-unit-command? l54-556-tr)
                   (urgent-survival-cmd? l54-556-tr)
                   (= (wire-cmd-priority-tier l54-556-tr) 0)
                   gov-54-emitted-556?
                   l54-cd-cleared?))

  ;; 12. L54-W2 (`#1323`): Observer/Overseer Cross-Map Scout Hijack Suppression + `12a` Preemption!
  ;;     (a) Under cloaked Banshee threat, `periodic-scout` on Observer `82` is suppressed (NO cross-map
  ;;         MOVE `16` to `(160, 160)`), and `12a` flies the Observer onto the cloaked Banshee `(36, 36)` as P0!
  ;;     (b) Under home-base combat (`enemy-combat-near-own-base?`), `periodic-scout` on Observer `82` /
  ;;         Overseer `129` is also suppressed; in peacetime, `periodic-scout` on Observer `82` still works!
  (define l54-nex   (mk-l49-u 99941 59 1 32.0 32.0 #:hp 1000.0 #:rad 2.5))
  (define l54-obs82 (mk-l49-u 99942 82 1 40.0 40.0 #:hp 40.0   #:rad 0.5))
  (define l54-stk   (mk-l49-u 99943 74 1 36.0 34.0 #:hp 80.0   #:rad 0.625))
  (define l54-ban
    (sc2-unit 1 4 99944 55 2 (sc2-point3d 36.0 36.0 8.0) 0.0 0.75 1.0 1 #f #t #f
              140.0 140.0 0.0 0.0 50.0 200.0 0 0 #t #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0 '() 0 0))
  (define l54-scout-cloak-cmds
    (translate-bot-actions->sc2-raw-commands
     '((periodic-scout 99942 160.0 160.0)
       (cast-deception-and-scout-spells))
     (make-test-obs 5300 300 200 (list l54-nex l54-obs82 l54-stk l54-ban))
     #:game-info gi-sw))
  (define l54-obs-far-scout?
    (ormap (lambda (c)
             (and (sc2-raw-unit-command? c)
                  (= (sc2-raw-unit-command-ability-id c) 16)
                  (memv 99942 (sc2-raw-unit-command-unit-tags c))
                  (sc2-point2d? (sc2-raw-unit-command-target-pos c))
                  (> (sc2-point2d-x (sc2-raw-unit-command-target-pos c)) 100.0)))
           l54-scout-cloak-cmds))
  (define l54-obs-covers-ban?
    (ormap (lambda (c)
             (and (sc2-raw-unit-command? c)
                  (= (sc2-raw-unit-command-ability-id c) 16)
                  (urgent-survival-cmd? c)
                  (memv 99942 (sc2-raw-unit-command-unit-tags c))
                  (sc2-point2d? (sc2-raw-unit-command-target-pos c))
                  (<= (sqrt (+ (sqr (- (sc2-point2d-x (sc2-raw-unit-command-target-pos c)) 36.0))
                               (sqr (- (sc2-point2d-y (sc2-raw-unit-command-target-pos c)) 36.0))))
                      12.0)))
           l54-scout-cloak-cmds))
  ;; (b) Under active non-stealth home-base attack, Overseer `129` `periodic-scout` is suppressed too!
  (define l54-htch  (mk-l49-u 99951 86  1 32.0 32.0 #:hp 1500.0 #:rad 2.75))
  (define l54-ovs   (mk-l49-u 99952 129 1 38.0 38.0 #:hp 200.0  #:rad 1.0))
  (define l54-emr   (mk-l49-u 99953 48  4 38.0 36.0 #:hp 45.0   #:rad 0.375))
  (define l54-ovs-base-atk-cmds
    (translate-bot-actions->sc2-raw-commands
     '((periodic-scout 99952 160.0 160.0))
     (make-test-obs 5320 300 200 (list l54-htch l54-ovs l54-emr))
     #:game-info gi-sw))
  (define l54-ovs-suppressed?
    (not (ormap (lambda (c)
                  (and (sc2-raw-unit-command? c)
                       (= (sc2-raw-unit-command-ability-id c) 16)
                       (memv 99952 (sc2-raw-unit-command-unit-tags c))))
                l54-ovs-base-atk-cmds)))
  ;; (c) In peacetime (`0` stealth, `0` enemies near base), Observer `82` `periodic-scout` STILL works!
  (define l54-obs-peace-cmds
    (translate-bot-actions->sc2-raw-commands
     '((periodic-scout 99942 160.0 160.0))
     (make-test-obs 5340 300 200 (list l54-nex l54-obs82))
     #:game-info gi-sw))
  (define l54-obs-peace-ok?
    (ormap (lambda (c)
             (and (sc2-raw-unit-command? c)
                  (= (sc2-raw-unit-command-ability-id c) 16)
                  (memv 99942 (sc2-raw-unit-command-unit-tags c))
                  (sc2-point2d? (sc2-raw-unit-command-target-pos c))
                  (> (sc2-point2d-x (sc2-raw-unit-command-target-pos c)) 100.0)))
           l54-obs-peace-cmds))
  (check-true "l54-w2-detector-scout-suppression-and-12a-preemption"
              (and (not l54-obs-far-scout?)
                   l54-obs-covers-ban?
                   l54-ovs-suppressed?
                   l54-obs-peace-ok?))

  ;; 13. L55-W1 (`#1345`): Global Cloak Shimmer Fix (`cloak=1` undetected, NOT `cloak=2` detected)
  ;;     + `'over-unpathable-airspace?` tag on flying enemy records via `path-grid`!
  (define l55-pgrid-bytes (make-bytes (* 128 128) 1))
  (for* ([y (in-range 128)] [x (in-range 25)])
    (bytes-set! l55-pgrid-bytes (+ x (* y 128)) 0))
  (define l55-pgrid (sc2-image-grid 8 128 128 l55-pgrid-bytes #f #f))
  (define l55-gi-p
    (sc2-game-info "L55TestMap" ""
                   (list (hash 'player-id 1 'race-requested 'Terran)
                         (hash 'player-id 2 'race-requested 'Protoss))
                   '(128 128) '(4 4 124 124) (list (sc2-point2d 100.0 100.0))
                   l55-pgrid #f l55-pgrid))
  (define l55-dt-c1
    (sc2-unit 1 4 99961 76 2 (sc2-point3d 40.0 40.0 8.0) 0.0 0.375 1.0 1 #f #t #f
              40.0 40.0 80.0 80.0 0.0 0.0 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0 '() 0 0))
  (define l55-dt-c2
    (sc2-unit 1 4 99962 76 2 (sc2-point3d 42.0 42.0 8.0) 0.0 0.375 1.0 2 #f #t #f
              40.0 40.0 80.0 80.0 0.0 0.0 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0 '() 0 0))
  (define l55-ban-cliff
    (sc2-unit 1 4 99963 55 2 (sc2-point3d 18.0 60.0 8.0) 0.0 0.75 1.0 0 #f #t #f
              140.0 140.0 0.0 0.0 50.0 200.0 0 0 #t #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0 '() 0 0))
  (define l55-ban-walk
    (sc2-unit 1 4 99964 55 2 (sc2-point3d 40.0 60.0 8.0) 0.0 0.75 1.0 0 #f #t #f
              140.0 140.0 0.0 0.0 50.0 200.0 0 0 #t #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0 '() 0 0))
  (define l55-rt-hash
    (sc2-observation->runtime-obs-hash
     (make-test-obs 5500 300 200 (list l54-cc l55-dt-c1 l55-dt-c2 l55-ban-cliff l55-ban-walk))
     #:game-info l55-gi-p))
  (define l55-eus (hash-ref l55-rt-hash 'enemy-units '()))
  (define (l55-eu id) (findf (lambda (u) (= (hash-ref u 'id 0) id)) l55-eus))
  (define l55-shims (hash-ref l55-rt-hash 'shimmer-and-burrow-ripples '()))
  (check-true "l55-w1-shimmer-cloak1-and-unpathable-airspace-tag"
              (and (hash-ref (l55-eu 99961) 'is-shimmer? #f)
                   (not (hash-ref (l55-eu 99962) 'is-shimmer? #t))
                   (ormap (lambda (u) (= (hash-ref u 'id 0) 99961)) l55-shims)
                   (not (ormap (lambda (u) (= (hash-ref u 'id 0) 99962)) l55-shims))
                   (hash-ref (l55-eu 99963) 'over-unpathable-airspace? #f)
                   (not (hash-ref (l55-eu 99964) 'over-unpathable-airspace? #t))
                   (not (hash-ref (l55-eu 99961) 'over-unpathable-airspace? #t))))

  ;; 14. L56-W2-1 (L55-W2b/L55-W3a, `#1357`/`#1372`/`#1394`): Tier-P1 MULE Safety Net Proactive Scan Reserve:
  ;;     - TvP/Random `>= 5376` (4:00), `0` Ravens & `0` Turrets -> `100.0e` floor on up to `2`
  ;;       ready OCs (top-2 by energy; 3rd+ OC MULEs at `50.0e`; `3:30` still MULEs!)
  ;;     - TvT with NO scouted cloak tech (`41`/`26`/`50`/`55`): BOTH 1-OC and 2-OC MULE freely even `>= 4:15` (`5712`)!
  ;;     - TvT WITH scouted StarportTechLab (`41`) or Banshee (`55`) -> reserves `100.0e` on top-1 OC (2nd OC still MULEs)!
  (define (mk-l55-oc tag x y en)
    (sc2-unit 1 1 tag 132 1 (sc2-point3d x y 8.0) 0.0 2.75 1.0 0 #f #t #f
              1500.0 1500.0 0.0 0.0 en 200.0 0 0 #f #f #f #t #f '() 0 '() 14 16 0.0 0 0 0 0 '() 0 0))
  (define l55-min1 (mk-l49-u 99971 341 3 24.0 30.0 #:hp 1000.0 #:rad 1.0 #:mins 1500))
  (define l55-min2 (mk-l49-u 99972 341 3 56.0 30.0 #:hp 1000.0 #:rad 1.0 #:mins 1500))
  (define l55-min3 (mk-l49-u 99980 341 3 76.0 30.0 #:hp 1000.0 #:rad 1.0 #:mins 1500))
  (define l55-oc1-75  (mk-l55-oc 99973 30.0 30.0 75.0))
  (define l55-oc1-90  (mk-l55-oc 99973 30.0 30.0 90.0))
  (define l55-oc1-100 (mk-l55-oc 99973 30.0 30.0 100.0))
  (define l55-oc2-60  (mk-l55-oc 99974 50.0 30.0 60.0))
  (define l55-oc2-75  (mk-l55-oc 99974 50.0 30.0 75.0))
  (define l55-oc3-60  (mk-l55-oc 99979 70.0 30.0 60.0))
  (define l55-turret  (mk-l49-u 99975 23 1 28.0 28.0 #:hp 250.0 #:rad 1.0))
  (define l55-raven   (mk-l49-u 99976 56 1 32.0 32.0 #:hp 140.0 #:rad 0.75))
  (define l55-enemy-stl (mk-l49-u 99977 41 4 95.0 95.0 #:hp 400.0 #:rad 1.0))
  (define l55-enemy-ban
    (sc2-unit 1 4 99978 55 2 (sc2-point3d 95.0 95.0 8.0) 0.0 0.75 1.0 0 #f #t #f
              140.0 140.0 0.0 0.0 50.0 200.0 0 0 #t #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0 '() 0 0))
  (define l55-gi-t
    (sc2-game-info "L55TestMap" ""
                   (list (hash 'player-id 1 'race-requested 'Terran)
                         (hash 'player-id 2 'race-requested 'Terran))
                   '(128 128) '(4 4 124 124) (list (sc2-point2d 100.0 100.0))
                   l55-pgrid #f l55-pgrid))
  (define l55-gi-z
    (sc2-game-info "L55TestMap" ""
                   (list (hash 'player-id 1 'race-requested 'Terran)
                         (hash 'player-id 2 'race-requested 'Zerg))
                   '(128 128) '(4 4 124 124) (list (sc2-point2d 100.0 100.0))
                   l55-pgrid #f l55-pgrid))
  (define (l55-mule-tags cs)
    (for/list ([c (in-list cs)]
               #:when (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 171)))
      (car (sc2-raw-unit-command-unit-tags c))))
  ;; Rewind match state cleanly before TvT no-cloak checks
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 100 (list l55-oc1-75 l55-min1)) #:game-info l55-gi-t))
  ;; (a0) TvP at 3:30 (4704 < 5376): STILL drops MULE normally at 75e!
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define m-tvp-330
    (l55-mule-tags (saturate-workers-and-gas-commands
                    (make-test-obs 4704 200 100 (list l55-oc1-75 l55-min1))
                    #:game-info l55-gi-p)))
  ;; (a1) TvT with NO scouted cloak tech: 1-OC & 2-OC at 3:30 (4724), 4:05 (5488), & 4:15+ (5712/5720) MULE freely!
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define m-tvt-330-clean
    (l55-mule-tags (saturate-workers-and-gas-commands
                    (make-test-obs 4724 200 100 (list l55-oc1-75 l55-min1))
                    #:game-info l55-gi-t)))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define m-tvt-405-two-oc
    (l55-mule-tags (saturate-workers-and-gas-commands
                    (make-test-obs 5488 200 100 (list l55-oc1-75 l55-oc2-60 l55-min1 l55-min2))
                    #:game-info l55-gi-t)))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define m-tvt-415-clean
    (l55-mule-tags (saturate-workers-and-gas-commands
                    (make-test-obs 5712 200 100 (list l55-oc1-75 l55-min1))
                    #:game-info l55-gi-t)))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define m-tvt-415-two-oc
    (l55-mule-tags (saturate-workers-and-gas-commands
                    (make-test-obs 5720 200 100 (list l55-oc1-75 l55-oc2-60 l55-min1 l55-min2))
                    #:game-info l55-gi-t)))
  ;; (a2) TvP at 4:15 (5732 >= 5376), 0 Ravens, 0 Turrets -> HOLD MULE (reserves Scan!)
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define m-hold-1
    (l55-mule-tags (saturate-workers-and-gas-commands
                    (make-test-obs 5732 200 100 (list l55-oc1-75 l55-min1))
                    #:game-info l55-gi-p)))
  ;; (b) L59-C (`#1566` Fix #3): 2 OCs (75e + 60e) in TvP at >= 4:00 -> ONLY top-1 OC (99973) holds Scan,
  ;;     2nd OC (99974) MULEs freely at 50e (eliminating `#010` 2-base TvP 65s OC #2 blackout)!
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define m-two-oc
    (l55-mule-tags (saturate-workers-and-gas-commands
                    (make-test-obs 5840 200 100 (list l55-oc1-75 l55-oc2-60 l55-min1 l55-min2))
                    #:game-info l55-gi-p)))
  ;; (b2) L55-W3a: 3 OCs (90e + 75e + 60e) in TvP at >= 4:00 -> top-2 OCs hold 100e, 3rd OC (99979) MULEs at 50e!
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define m-three-oc
    (l55-mule-tags (saturate-workers-and-gas-commands
                    (make-test-obs 5850 200 100 (list l55-oc1-90 l55-oc2-75 l55-oc3-60 l55-min1 l55-min2 l55-min3))
                    #:game-info l55-gi-p)))
  ;; (c) OC1 at 100e -> drops MULE cleanly (50e Scan remains banked!)
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define m-100e
    (l55-mule-tags (saturate-workers-and-gas-commands
                    (make-test-obs 5860 200 100 (list l55-oc1-100 l55-min1))
                    #:game-info l55-gi-p)))
  ;; (d) With a ready Missile Turret OR Raven OR vs Zerg -> OC1 at 75e drops MULE!
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define m-with-turret
    (l55-mule-tags (saturate-workers-and-gas-commands
                    (make-test-obs 5880 200 100 (list l55-oc1-75 l55-turret l55-min1))
                    #:game-info l55-gi-p)))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define m-with-raven
    (l55-mule-tags (saturate-workers-and-gas-commands
                    (make-test-obs 5900 200 100 (list l55-oc1-75 l55-raven l55-min1))
                    #:game-info l55-gi-p)))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define m-vs-zerg
    (l55-mule-tags (saturate-workers-and-gas-commands
                    (make-test-obs 5920 200 100 (list l55-oc1-75 l55-min1))
                    #:game-info l55-gi-z)))
  ;; (e) TvT WITH scouted enemy StarportTechLab (41) OR Banshee (55) -> holds 100e on top-1 OC only (2nd OC still MULEs)!
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define m-tvt-stl
    (l55-mule-tags (saturate-workers-and-gas-commands
                    (make-test-obs 5940 200 100 (list l55-oc1-75 l55-min1 l55-enemy-stl))
                    #:game-info l55-gi-t)))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define m-tvt-stl-two-oc
    (l55-mule-tags (saturate-workers-and-gas-commands
                    (make-test-obs 5950 200 100 (list l55-oc1-75 l55-oc2-60 l55-min1 l55-min2 l55-enemy-stl))
                    #:game-info l55-gi-t)))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define m-tvt-ban
    (l55-mule-tags (saturate-workers-and-gas-commands
                    (make-test-obs 5960 200 100 (list l55-oc1-75 l55-min1 l55-enemy-ban))
                    #:game-info l55-gi-t)))
  ;; Clean rewind reset for subsequent checks
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 100 (list l55-min1))))
  (check-true "l55-w2-mule-safety-net-proactive-scan-reserve"
              (and (equal? m-tvp-330 '(99973))
                   (equal? m-tvt-330-clean '(99973))
                   (equal? (sort m-tvt-405-two-oc <) '(99973 99974))
                   (equal? m-tvt-415-clean '(99973))
                   (equal? (sort m-tvt-415-two-oc <) '(99973 99974))
                   (null? m-hold-1)
                   (equal? m-two-oc '(99974))
                   (equal? m-three-oc '(99979))
                   (equal? m-100e '(99973))
                   (equal? m-with-turret '(99973))
                   (equal? m-with-raven '(99973))
                   (equal? m-vs-zerg '(99973))
                   (null? m-tvt-stl)
                   (equal? m-tvt-stl-two-oc '(99974))
                   (null? m-tvt-ban)))

  ;; 15. L55-W3 (`#1345`): `high-ground-tactics` `air-spotter` excludes detectors
  ;;     `'(82 106 129 1911 1912)` while still picking real non-detector flyers (e.g. Phoenix `78`)!
  (define (mk-l55-fly tag utype x y)
    (sc2-unit 1 1 tag utype 1 (sc2-point3d x y 10.0) 0.0 0.75 1.0 0 #f #t #f
              120.0 120.0 60.0 60.0 50.0 200.0 0 0 #t #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0 '() 0 0))
  (define l55-det-only
    (list l54-nex
          (mk-l55-fly 99981 82   40.0 40.0)
          (mk-l55-fly 99982 106  41.0 40.0)
          (mk-l55-fly 99983 129  42.0 40.0)
          (mk-l55-fly 99984 1911 43.0 40.0)
          (mk-l55-fly 99985 1912 44.0 40.0)))
  (define l55-hg-det-cmds
    (translate-bot-actions->sc2-raw-commands
     '((high-ground-tactics hold-high-ground-ramp-arc 80.0 80.0 #t))
     (make-test-obs 5940 300 200 l55-det-only)
     #:game-info gi-sw))
  (define l55-hg-det-hijacked?
    (ormap (lambda (c)
             (and (sc2-raw-unit-command? c)
                  (= (sc2-raw-unit-command-ability-id c) 16)
                  (ormap (lambda (t) (memv t '(99981 99982 99983 99984 99985)))
                         (sc2-raw-unit-command-unit-tags c))))
           l55-hg-det-cmds))
  (define l55-hg-phx-cmds
    (translate-bot-actions->sc2-raw-commands
     '((high-ground-tactics hold-high-ground-ramp-arc 80.0 80.0 #t))
     (make-test-obs 5960 300 200 (append l55-det-only (list (mk-l55-fly 99986 78 45.0 40.0))))
     #:game-info gi-sw))
  (define l55-hg-picked-phx?
    (ormap (lambda (c)
             (and (sc2-raw-unit-command? c)
                  (= (sc2-raw-unit-command-ability-id c) 16)
                  (equal? (sc2-raw-unit-command-unit-tags c) '(99986))))
           l55-hg-phx-cmds))
  (check-true "l55-w3-high-ground-air-spotter-excludes-detectors"
              (and (not l55-hg-det-hijacked?)
                   l55-hg-picked-phx?))

  ;; 16. L58-P1 (`#1431` / `#1435`): Arena Pass 1 wire/reject fixes:
  ;;     (a) `hallucination-zealot` (`164`) + all 13 Sentry hallucinations mapped & emitted as NoTarget,
  ;;     (b) Hallucinated casters blocked from spells (`173` `2:NotSupported`), air-only attackers (`35/78/112`)
  ;;         blocked from ground unit-target Attack (`111:MustTargetAirUnits`, Colossus `4` still allowed!),
  ;;         and burrowed non-attackers (`baneling-burrowed=115`) blocked from Attack (`23`, `2:NotSupported`),
  ;;     (c) Nydus Worm unload (`2371`) gated on cargo > 0 (`0` empty-worm `2:NotSupported`),
  ;;     (d) Warp Prism unload (`913`) gated on live owned loaded transport + Recall/Stasis freeze shield
  ;;         (`0` `88:YouCantIssueCommandsToThatUnit` & `0` `3757` `6:Cooldown`),
  ;;     (e) SCV Repair (`3685`) strictly requires `health < health-max` (`0` `28:TooMuchLife`),
  ;;     (f) Nexus Energy Recharge (`4126`) enforces `<= 15.0t` range, `>= 50.0e` energy, & non-full target,
  ;;     (g) `L23-P0-1` MULE blocks on nearby uncovered `cloak=1` threats & ChronoBoost yields to `4126`!
  (define (mk-l58-u tag utype alliance x y
                    #:hp [hp 100.0] #:hp-max [hp-max hp] #:en [en 100.0] #:en-max [en-max 200.0]
                    #:fly [fly #f] #:halluc [halluc #f] #:cloak [cloak 0] #:burr [burr #f]
                    #:orders [ords '()] #:buffs [buffs '()]
                    #:ctaken [ctaken 0] #:cmax [cmax 0])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 (if (= alliance 4) 2 0))
              (sc2-point3d x y 8.0) 0.0 0.75 1.0 cloak #f #t #f
              hp hp-max 0.0 0.0 en en-max 0 0 fly burr halluc #t #f
              ords 0 buffs 0 0 0.0 0 0 0 0 '() ctaken cmax))

  ;; (16a + 16b) Hallucination Zealot (164), Hallucinated caster block, Air-only ground guard, Burrowed Bane guard
  (define l58-sentry (mk-l58-u 98101 77  1 30.0 30.0 #:hp 40.0 #:en 150.0))
  (define l58-hphx   (mk-l58-u 98102 78  1 32.0 30.0 #:hp 120.0 #:en 100.0 #:fly #t #:halluc #t))
  (define l58-rphx   (mk-l58-u 98103 78  1 33.0 30.0 #:hp 120.0 #:en 100.0 #:fly #t))
  (define l58-bbane  (mk-l58-u 98104 115 1 35.0 30.0 #:hp 30.0  #:en 0.0   #:en-max 0.0 #:burr #t))
  (define l58-emar   (mk-l58-u 98111 48  4 40.0 30.0 #:hp 45.0  #:en 0.0   #:en-max 0.0))
  (define l58-ecol   (mk-l58-u 98112 4   4 41.0 30.0 #:hp 200.0 #:en 0.0   #:en-max 0.0))
  (define l58-emed   (mk-l58-u 98113 54  4 42.0 30.0 #:hp 150.0 #:en 50.0  #:fly #t))
  (define l58-cmds-hal
    (translate-bot-actions->sc2-raw-commands
     '((cast-spell 98101 hallucination-zealot)
       (cast-spell 98101 hallucination-archon)
       (cast-spell 98102 graviton-beam 98111)
       (attack-unit 98102 98111)
       (attack-unit 98103 98111)
       (attack-unit 98103 98112)
       (attack-unit 98104 98111)
       (attack-pos (98104) 40.0 30.0)
       (baneling-explode 98104))
     (make-test-obs 6100 300 200 (list l58-sentry l58-hphx l58-rphx l58-bbane l58-emar l58-ecol l58-emed))))
  (define l58-has-164?
    (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 164)
                            (equal? (sc2-raw-unit-command-unit-tags c) '(98101)))) l58-cmds-hal))
  (define l58-has-146?
    (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 146))) l58-cmds-hal))
  (define l58-has-173?
    (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 173))) l58-cmds-hal))
  (define l58-phx-hit-mar?
    (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 23)
                            (= (sc2-raw-unit-command-target-unit-tag c) 98111)
                            (ormap (lambda (t) (memv t '(98102 98103))) (sc2-raw-unit-command-unit-tags c))))
           l58-cmds-hal))
  (define l58-phx-hit-col?
    (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 23)
                            (= (sc2-raw-unit-command-target-unit-tag c) 98112)
                            (equal? (sc2-raw-unit-command-unit-tags c) '(98103))))
           l58-cmds-hal))
  (define l58-bbane-atk?
    (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 23)
                            (memv 98104 (sc2-raw-unit-command-unit-tags c))))
           l58-cmds-hal))
  (define l58-bbane-exp?
    (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 42)
                            (equal? (sc2-raw-unit-command-unit-tags c) '(98104))))
           l58-cmds-hal))
  (define l58-bbane-idle-cmds
    (translate-bot-actions->sc2-raw-commands
     '()
     (make-test-obs 6108 300 200 (list l58-bbane l58-emar))))
  (define l58-bbane-idle-atk?
    (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 23)
                            (memv 98104 (sc2-raw-unit-command-unit-tags c))))
           l58-bbane-idle-cmds))
  (check-true "l58-p1-hallucination-zealot-and-hallucinated-air-burrow-guards"
              (and (= (ability-symbol->sc2-id 'hallucination-zealot) 164)
                   (= (ability-symbol->sc2-id 'hallucination-archon) 146)
                   (= (ability-symbol->sc2-id 'hallucination-phoenix) 154)
                   (= (ability-symbol->sc2-id 'hallucination-adept) 2391)
                   l58-has-164? l58-has-146?
                   (not l58-has-173?)
                   (not l58-phx-hit-mar?)
                   l58-phx-hit-col?
                   (not l58-bbane-atk?)
                   (not l58-bbane-idle-atk?)
                   l58-bbane-exp?))

  ;; (16c + 16d) Nydus empty-cargo guard (2371), Warp Prism guard (913), Recall/Stasis freeze shield (88)
  (define l58-nyd-full  (mk-l58-u 98201 142 1 60.0 60.0 #:hp 300.0 #:ctaken 8 #:cmax 255))
  (define l58-nyd-empty (mk-l58-u 98202 142 1 64.0 60.0 #:hp 300.0 #:ctaken 0 #:cmax 255))
  (define l58-cmds-nyd-full
    (translate-bot-actions->sc2-raw-commands '((nydus-unload 98201)) (make-test-obs 6120 100 50 (list l58-nyd-full))))
  (define l58-cmds-nyd-empty
    (translate-bot-actions->sc2-raw-commands '((nydus-unload 98202)) (make-test-obs 6124 100 50 (list l58-nyd-empty))))
  (define l58-nx-rec   (mk-l58-u 98210 59 1 30.0 30.0 #:hp 1000.0 #:en 100.0))
  (define l58-wp-far   (mk-l58-u 98211 81 1 80.0 80.0 #:hp 80.0   #:fly #t #:ctaken 4 #:cmax 8))
  (define l58-wp-empty (mk-l58-u 98212 81 1 50.0 50.0 #:hp 80.0   #:fly #t #:ctaken 0 #:cmax 8))
  (define l58-wp-home  (mk-l58-u 98211 81 1 32.0 32.0 #:hp 80.0   #:fly #t #:ctaken 4 #:cmax 8))
  (define l58-wp-stas  (mk-l58-u 98213 81 1 55.0 55.0 #:hp 80.0   #:fly #t #:ctaken 4 #:cmax 8 #:buffs '(129)))
  ;; Cast Mass Recall (3757) at (80,80), then verify second 3757 is blocked by cooldown AND 913/16 on recalled wp-far are blocked!
  (define l58-cmds-rec1
    (translate-bot-actions->sc2-raw-commands
     '((cast-spell 98210 mass-recall 80.0 80.0))
     (make-test-obs 6140 200 100 (list l58-nx-rec l58-wp-far l58-wp-empty l58-wp-stas))))
  (define l58-cmds-rec2
    (translate-bot-actions->sc2-raw-commands
     '((cast-spell 98210 mass-recall 80.0 80.0)
       (unload-all-at 98211 80.0 80.0)
       (move 98211 82.0 82.0)
       (unload-all-at 98212 50.0 50.0)
       (unload-all-at 98213 55.0 55.0)
       (unload-all-at 999999 80.0 80.0))
     (make-test-obs 6144 200 100 (list l58-nx-rec l58-wp-far l58-wp-empty l58-wp-stas))))
  ;; Once Warp Prism finishes teleporting home to (32, 32) (> 8.5t from recall zone), 913 immediately works again!
  (define l58-cmds-rec-home
    (translate-bot-actions->sc2-raw-commands
     '((unload-all-at 98211 32.0 32.0))
     (make-test-obs 6160 200 100 (list l58-nx-rec l58-wp-home))))
  (check-true "l58-p1-nydus-empty-guard-warp-prism-and-recall-stasis-shield"
              (and (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 2371))) l58-cmds-nyd-full)
                   (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 2371))) l58-cmds-nyd-empty))
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 3757))) l58-cmds-rec1)
                   (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (memv (sc2-raw-unit-command-ability-id c) '(3757 913 16)))) l58-cmds-rec2))
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 913)
                                           (equal? (sc2-raw-unit-command-unit-tags c) '(98211))))
                          l58-cmds-rec-home)))

  ;; (16e + 16f) SCV Repair damaged-only guard (`28:TooMuchLife`) & Nexus Energy Recharge `4126` (`<=15t`, `>=50e`)
  (define l58-scv1    (mk-l58-u 98301 45 1 30.0 30.0 #:hp 45.0   #:hp-max 45.0   #:en 0.0 #:en-max 0.0))
  (define l58-scv2    (mk-l58-u 98302 45 1 31.0 30.0 #:hp 45.0   #:hp-max 45.0   #:en 0.0 #:en-max 0.0))
  (define l58-bkr-ok  (mk-l58-u 98303 24 1 33.0 30.0 #:hp 400.0  #:hp-max 400.0  #:en 0.0 #:en-max 0.0))
  (define l58-bkr-dmg (mk-l58-u 98304 24 1 33.0 33.0 #:hp 260.0  #:hp-max 400.0  #:en 0.0 #:en-max 0.0))
  (define l58-cmds-rep
    (translate-bot-actions->sc2-raw-commands
     '((repair 98301 98303)
       (cast-spell 98302 repair 98303)
       (repair 98301 98304))
     (make-test-obs 6200 200 100 (list l58-scv1 l58-scv2 l58-bkr-ok l58-bkr-dmg))))
  (define l58-nx-hi   (mk-l58-u 98310 59 1 30.0 30.0 #:hp 1000.0 #:en 100.0))
  (define l58-nx-lo   (mk-l58-u 98311 59 1 32.0 30.0 #:hp 1000.0 #:en 40.0))
  (define l58-ht-near (mk-l58-u 98312 75 1 35.0 30.0 #:hp 40.0   #:en 25.0))
  (define l58-ht-far  (mk-l58-u 98313 75 1 70.0 30.0 #:hp 40.0   #:en 25.0))
  (define l58-ht-full (mk-l58-u 98314 75 1 34.0 30.0 #:hp 40.0   #:en 200.0))
  (define l58-cmds-er
    (translate-bot-actions->sc2-raw-commands
     '((cast-spell 98310 nexus-energy-recharge 98313)
       (cast-spell 98311 nexus-energy-recharge 98312)
       (cast-spell 98310 nexus-energy-recharge 98314)
       (cast-spell 98310 nexus-energy-recharge 98312))
     (make-test-obs 6220 200 100 (list l58-nx-hi l58-nx-lo l58-ht-near l58-ht-far l58-ht-full))))
  (define l58-er-cmds
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 4126))) l58-cmds-er))
  (check-true "l58-p1-scv-repair-damaged-only-and-nexus-energy-recharge-4126-guards"
              (and (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 3685)
                                                (= (sc2-raw-unit-command-target-unit-tag c) 98303)))
                               l58-cmds-rep))
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 3685)
                                           (= (sc2-raw-unit-command-target-unit-tag c) 98304)
                                           (equal? (sc2-raw-unit-command-unit-tags c) '(98301))))
                          l58-cmds-rep)
                   (= (length l58-er-cmds) 1)
                   (= (sc2-raw-unit-command-target-unit-tag (first l58-er-cmds)) 98312)
                   (equal? (sc2-raw-unit-command-unit-tags (first l58-er-cmds)) '(98310))))

  ;; (16g) L23-P0-1 MULE hard-blocks on nearby uncovered cloak=1 DT (even at 100e!),
  ;;       banks 50e Scan vs Protoss when >= 8 combat units exist even < 4:00, & ChronoBoost yields to 4126!
  (define l58-dt-cl1 (mk-l58-u 98401 76 4 38.0 30.0 #:hp 40.0 #:cloak 1))
  (define l58-8mar
    (for/list ([i (in-range 8)])
      (mk-l58-u (+ 98420 i) 48 1 (+ 32.0 (* 0.5 i)) 30.0 #:hp 45.0 #:en 0.0 #:en-max 0.0)))
  (define l58-nx-prb
    (mk-l58-u 98410 59 1 30.0 30.0 #:hp 1000.0 #:en 75.0
              #:orders (list (sc2-unit-order 1006 #f 0 0.25))))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define l58-mule-under-dt
    (l55-mule-tags (saturate-workers-and-gas-commands
                    (make-test-obs 6240 200 100 (list l55-oc1-100 l55-min1 l58-dt-cl1))
                    #:game-info l55-gi-p)))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  ;; Rewind to loop 16 (< 5376): with 8 Marines vs Protoss & 0 Ravens/Turrets, 75e OC holds 50e Scan!
  (define l58-mule-8mar-tvp
    (l55-mule-tags (saturate-workers-and-gas-commands
                    (make-test-obs 16 200 100 (append (list l55-oc1-75 l55-min1) l58-8mar))
                    #:game-info l55-gi-p)))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define l58-chrono-yield
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 3755)))
            (saturate-workers-and-gas-commands
             (make-test-obs 6250 200 100 (list l58-nx-prb l58-ht-near l58-emar l55-min1)))))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define l58-chrono-normal
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 3755)))
            (saturate-workers-and-gas-commands
             (make-test-obs 6260 200 100 (list l58-nx-prb l58-ht-full l58-emar l55-min1)))))
  ;; Rewind cleanly so no recall/cooldown boxes persist
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 100 (list l55-min1))))
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 100 (list l55-min1))))
  (check-true "l58-p1-l23-mule-blocks-uncovered-cloak-and-chrono-yields-to-4126"
              (and (null? l58-mule-under-dt)
                   (null? l58-mule-8mar-tvp)
                   (null? l58-chrono-yield)
                   (= (length l58-chrono-normal) 1)))

  ;; 17. L58-P2 (`#1442`): Arena Pass 2 wire fixes:
  ;;     (a) Exact Nexus Recall (`3757`) radius (`2.5t`) + post-teleport arrival stun at Nexus `(nx, ny)`
  ;;         through `cast+108` (`0` `23:88` on recalled units, `0` false-freeze on unrecalled allies `5.5t` away!)
  ;;         + ground-only attacker guard against flying enemies (`113:MustTargetGroundUnits`),
  ;;     (b) Loop-0 MULE dedup (`saturate` preserves same-loop `SC2-MACRO-ABILITY-LAST-LOOP`) + emergency
  ;;         P0 Terran OC `Scanner Sweep (399)` vs `cloak=1` DTs in `12a` (with effect-6 non-duplication),
  ;;     (c) Overseer (`129`) preserves energy for `Contaminate (1825)` (Tier P0) instead of spamming `181`
  ;;         near uncontaminated enemy production/tech structures (`<= 24t`),
  ;;     (d) Immobile burrowed/sieged units (`503` Lurker) drop `Move (16)` & wrong-polarity `2108`
  ;;         (`2:NotSupported`), while burrow-moving `118` Roach keeps `16`, and active burrow transitions
  ;;         drop duplicate `1386`/`3662` (`4:CantQueueThatOrder`),
  ;;     (e) Burrowed `InfestorBurrowed (127)` drops `74` (`2:NotSupported`) & `4111` (`211:TargetIsOutOfArc`)
  ;;         while keeping `249` Neural Parasite & `3662` Unburrow (and unburrowed `111` still casts `74`/`4111`)!

  ;; (17a) Nexus Recall exact radius + post-teleport Nexus arrival stun + ground-only vs flying guard
  (define l58p2-nx    (mk-l58-u 98501 59  1 30.0 30.0 #:hp 1000.0 #:en 100.0))
  (define l58p2-stk-c (mk-l58-u 98502 74  1 88.0 86.0 #:hp 80.0   #:en 0.0 #:en-max 0.0)) ;; inside 2.5t recall!
  (define l58p2-phx-o (mk-l58-u 98503 78  1 93.8 86.0 #:hp 120.0  #:en 100.0 #:fly #t))   ;; 5.8t away -> NOT recalled!
  (define l58p2-dt    (mk-l58-u 98504 76  1 82.0 86.0 #:hp 40.0   #:en 0.0 #:en-max 0.0)) ;; 6.0t away -> NOT recalled!
  (define l58p2-eovs  (mk-l58-u 98511 129 4 95.0 86.0 #:hp 200.0  #:en 50.0 #:fly #t))
  (define l58p2-eroa  (mk-l58-u 98512 110 4 90.0 86.0 #:hp 145.0  #:en 0.0 #:en-max 0.0))
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 100 (list l55-min1))))
  ;; Cast Nexus Recall (3757) at (88, 86) on loop 6500
  (define l58p2-rc-cast
    (translate-bot-actions->sc2-raw-commands
     '((cast-spell 98501 mass-recall 88.0 86.0))
     (make-test-obs 6500 200 100 (list l58p2-nx l58p2-stk-c l58p2-phx-o l58p2-dt l58p2-eovs l58p2-eroa))))
  ;; Windup loop 6540 (+40): captured Stalker (98502) frozen, unrecalled Phoenix (98503) & DT (98504) free!
  ;; Also DT (98504) drops Attack (23) on flying Overseer (98511) while Phoenix (98503) attacks it!
  (define l58p2-rc-windup
    (translate-bot-actions->sc2-raw-commands
     '((attack-unit 98502 98512)
       (attack-unit 98503 98511)
       (attack-unit 98504 98511)
       (attack-unit 98504 98512))
     (make-test-obs 6540 200 100 (list l58p2-nx l58p2-stk-c l58p2-phx-o l58p2-dt l58p2-eovs l58p2-eroa))))
  ;; Post-teleport arrival stun loop 6592 (+92): Stalker teleported to Nexus (31, 31) -> STILL frozen (`0` 23:88)!
  (define l58p2-stk-home (mk-l58-u 98502 74 1 31.0 31.0 #:hp 80.0 #:en 0.0 #:en-max 0.0))
  (define l58p2-rc-arrive
    (translate-bot-actions->sc2-raw-commands
     '((attack-unit 98502 98512))
     (make-test-obs 6592 200 100 (list l58p2-nx l58p2-stk-home l58p2-eroa))))
  ;; Post-stun loop 6612 (+112): Stalker at Nexus unlocked cleanly!
  (define l58p2-rc-free
    (translate-bot-actions->sc2-raw-commands
     '((attack-unit 98502 98512))
     (make-test-obs 6612 200 100 (list l58p2-nx l58p2-stk-home l58p2-eroa))))
  (check-true "l58-p2-recall-exact-radius-nexus-arrival-stun-and-ground-vs-air-guard"
              (and (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 3757)))
                          l58p2-rc-cast)
                   (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (memv 98502 (sc2-raw-unit-command-unit-tags c))))
                               l58p2-rc-windup))
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                           (= (sc2-raw-unit-command-ability-id c) 23)
                                           (= (sc2-raw-unit-command-target-unit-tag c) 98511)
                                           (equal? (sc2-raw-unit-command-unit-tags c) '(98503))))
                          l58p2-rc-windup)
                   (not (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                                (= (sc2-raw-unit-command-ability-id c) 23)
                                                (= (sc2-raw-unit-command-target-unit-tag c) 98511)
                                                (memv 98504 (sc2-raw-unit-command-unit-tags c))))
                               l58p2-rc-windup))
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                           (= (sc2-raw-unit-command-ability-id c) 23)
                                           (= (sc2-raw-unit-command-target-unit-tag c) 98512)
                                           (equal? (sc2-raw-unit-command-unit-tags c) '(98504))))
                          l58p2-rc-windup)
                   (null? l58p2-rc-arrive)
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                           (= (sc2-raw-unit-command-ability-id c) 23)
                                           (equal? (sc2-raw-unit-command-unit-tags c) '(98502))))
                          l58p2-rc-free)))

  ;; (17b) Loop-0 MULE dedup across translate+saturate AND 12a emergency Terran OC Scanner Sweep (399) vs cloak=1 DT!
  (define l58p2-oc-100 (mk-l58-u 98521 132 1 30.0 30.0 #:hp 1500.0 #:en 100.0))
  (define l58p2-oc-50  (mk-l58-u 98521 132 1 30.0 30.0 #:hp 1500.0 #:en 50.0))
  (define l58p2-mar    (mk-l58-u 98522 48  1 34.0 30.0 #:hp 45.0   #:en 0.0 #:en-max 0.0))
  (define l58p2-min    (sc2-unit 1 3 98523 341 0 (sc2-point3d 25.0 30.0 8.0) 0.0 1.0 1.0 0 #f #t #f
                                 1000.0 1000.0 0.0 0.0 0.0 0.0 1500 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0 '() 0 0))
  (define l58p2-dt-cl1 (mk-l58-u 98524 76  4 40.0 30.0 #:hp 0.0 #:hp-max 40.0 #:en 0.0 #:en-max 0.0 #:cloak 1))
  (define l58p2-obs-l0 (make-test-obs 0 200 100 (list l58p2-oc-100 l58p2-mar l58p2-min)))
  (define l58p2-l0-tr  (translate-bot-actions->sc2-raw-commands '((cast-spell 98521 calldown-mule 98523)) l58p2-obs-l0))
  (define l58p2-l0-sat (saturate-workers-and-gas-commands l58p2-obs-l0))
  ;; Loop 4: cloak=1 (hp=0) DT enters sight -> 12a fires P0 emergency Scan (399) and suppresses competing 171!
  (define l58p2-obs-dt4 (make-test-obs 4 200 100 (list l58p2-oc-50 l58p2-mar l58p2-min l58p2-dt-cl1)))
  (define l58p2-dt4-cmds (translate-bot-actions->sc2-raw-commands '((cast-spell 98521 calldown-mule 98523)) l58p2-obs-dt4))
  ;; Loop 200 with active ScannerSweep effect (effect-id = 6) covering DT -> 0 duplicate 399!
  (define l58p2-obs-dt200
    (sc2-observation 200 (sc2-player-common 1 200 100 20 50 10 0 0 0 0 0)
                     (list l58p2-oc-50 l58p2-mar l58p2-min l58p2-dt-cl1)
                     '() '() #f '()
                     (list (sc2-effect 6 (list (sc2-point2d 40.0 30.0)) 1 1 13.0))
                     '() '() '() '()))
  (define l58p2-dt200-cmds (translate-bot-actions->sc2-raw-commands '() l58p2-obs-dt200))
  (check-true "l58-p2-t10-loop0-mule-dedup-and-12a-emergency-oc-scan-399"
              (and (= (count (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 171)))
                             l58p2-l0-tr)
                      1)
                   (null? (l55-mule-tags l58p2-l0-sat))
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                           (= (sc2-raw-unit-command-ability-id c) 399)
                                           (urgent-survival-cmd? c)
                                           (equal? (sc2-raw-unit-command-unit-tags c) '(98521))))
                          l58p2-dt4-cmds)
                   (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 171)))
                               l58p2-dt4-cmds))
                   (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 399)))
                               l58p2-dt200-cmds))))

  ;; (17c) Overseer (129) saves energy for Contaminate (1825, P0) instead of spamming 181 near enemy Stargate!
  (define l58p2-ov    (mk-l58-u 98531 129 1 82.0 86.0 #:hp 200.0 #:en 160.0 #:fly #t))
  (define l58p2-sg-u  (mk-l58-u 98532 67  4 92.0 86.0 #:hp 600.0 #:en 0.0 #:en-max 0.0))
  (define l58p2-sg-c  (mk-l58-u 98532 67  4 92.0 86.0 #:hp 600.0 #:en 0.0 #:en-max 0.0 #:buffs '(36)))
  (define l58p2-z06-uncontam
    (translate-bot-actions->sc2-raw-commands
     '((cast-deception-and-scout-spells)
       (cast-spell 98531 spawn-changeling)
       (cast-spell 98531 contaminate 98532))
     (make-test-obs 6700 200 100 (list l58p2-ov l58p2-sg-u))))
  (define l58p2-z06-contam
    (translate-bot-actions->sc2-raw-commands
     '((cast-deception-and-scout-spells))
     (make-test-obs 6720 200 100 (list l58p2-ov l58p2-sg-c))))
  (check-true "l58-p2-z06-overseer-blocks-181-near-uncontaminated-stargate-and-emits-1825-p0"
              (and (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 181)))
                               l58p2-z06-uncontam))
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                           (= (sc2-raw-unit-command-ability-id c) 1825)
                                           (= (wire-cmd-priority-tier c) 0)
                                           (= (sc2-raw-unit-command-target-unit-tag c) 98532)))
                          l58p2-z06-uncontam)
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 181)))
                          l58p2-z06-contam)))

  ;; (17d) LurkerMPBurrowed (503) drops Move (16) & BurrowDown (2108), RoachBurrowed (118) keeps Move (16),
  ;;       and mid-transition Roach (order 1386) drops duplicate 1386/3662 (`4:CantQueueThatOrder`)!
  (define l58p2-lurk-b (mk-l58-u 98541 503 1 84.0 86.0 #:hp 200.0 #:en 0.0 #:en-max 0.0 #:burr #t))
  (define l58p2-roa-b  (mk-l58-u 98542 118 1 85.0 86.0 #:hp 145.0 #:en 0.0 #:en-max 0.0 #:burr #t))
  (define l58p2-roa-tx (mk-l58-u 98543 110 1 86.0 86.0 #:hp 145.0 #:en 0.0 #:en-max 0.0
                                 #:orders (list (sc2-unit-order 1386 #f 0 0.4))))
  (define l58p2-roa-ok (mk-l58-u 98544 110 1 87.0 86.0 #:hp 145.0 #:en 0.0 #:en-max 0.0))
  (define l58p2-brw-cmds
    (translate-bot-actions->sc2-raw-commands
     '((move 98541 90.0 86.0)
       (burrow-down 98541)
       (cast-spell 98541 lurker-burrow)
       (burrow-up 98541)
       (move 98542 90.0 86.0)
       (burrow-down 98543 1386)
       (burrow-up 98543)
       (burrow-down 98544 1386)
       (burrow-down 98544 1386))
     (make-test-obs 6800 200 100 (list l58p2-lurk-b l58p2-roa-b l58p2-roa-tx l58p2-roa-ok))))
  (check-true "l58-p2-u07-z09-immobile-move-burrow-polarity-and-transition-dedup"
              (and (not (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                                (memv (sc2-raw-unit-command-ability-id c) '(16 2108))
                                                (memv 98541 (sc2-raw-unit-command-unit-tags c))))
                               l58p2-brw-cmds))
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                           (= (sc2-raw-unit-command-ability-id c) 2110)
                                           (equal? (sc2-raw-unit-command-unit-tags c) '(98541))))
                          l58p2-brw-cmds)
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                           (= (sc2-raw-unit-command-ability-id c) 16)
                                           (equal? (sc2-raw-unit-command-unit-tags c) '(98542))))
                          l58p2-brw-cmds)
                   (not (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                                (memv 98543 (sc2-raw-unit-command-unit-tags c))))
                               l58p2-brw-cmds))
                   (= (count (lambda (c) (and (sc2-raw-unit-command? c)
                                              (= (sc2-raw-unit-command-ability-id c) 1386)
                                              (equal? (sc2-raw-unit-command-unit-tags c) '(98544))))
                             l58p2-brw-cmds)
                      1)))

  ;; (17e) Burrowed Infestor (127) drops 74 (Fungal) & 4111 (Microbial Shroud) while keeping 249 (Neural) & 3662!
  (define l58p2-inf-b  (mk-l58-u 98551 127 1 84.0 86.0 #:hp 90.0 #:en 150.0 #:burr #t))
  (define l58p2-inf-u  (mk-l58-u 98552 111 1 83.0 86.0 #:hp 90.0 #:en 150.0))
  (define l58p2-etank  (mk-l58-u 98553 32  4 91.0 86.0 #:hp 175.0 #:en 0.0 #:en-max 0.0))
  (define l58p2-inf-cmds
    (translate-bot-actions->sc2-raw-commands
     '((cast-spell 98551 fungal-growth 91.0 86.0)
       (cast-spell 98551 microbial-shroud 84.0 86.0)
       (infestor-burrow-cast 98551 fungal-growth 91.0 86.0)
       (infestor-burrow-cast 98551 neural-parasite 98553)
       (burrow-up 98551)
       (cast-spell 98552 fungal-growth 91.0 86.0)
       (cast-spell 98552 microbial-shroud 83.0 86.0))
     (make-test-obs 6900 200 100 (list l58p2-inf-b l58p2-inf-u l58p2-etank))))
  ;; Clean rewind reset
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 100 (list l55-min1))))
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 100 (list l55-min1))))
  (check-true "l58-p2-u05-burrowed-infestor-drops-74-and-4111-while-keeping-249-and-3662"
              (and (not (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                                (memv (sc2-raw-unit-command-ability-id c) '(74 4111))
                                                (memv 98551 (sc2-raw-unit-command-unit-tags c))))
                               l58p2-inf-cmds))
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                           (= (sc2-raw-unit-command-ability-id c) 249)
                                           (equal? (sc2-raw-unit-command-unit-tags c) '(98551))))
                          l58p2-inf-cmds)
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                           (= (sc2-raw-unit-command-ability-id c) 3662)
                                           (equal? (sc2-raw-unit-command-unit-tags c) '(98551))))
                          l58p2-inf-cmds)
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                           (= (sc2-raw-unit-command-ability-id c) 74)
                                           (equal? (sc2-raw-unit-command-unit-tags c) '(98552))))
                          l58p2-inf-cmds)
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                           (= (sc2-raw-unit-command-ability-id c) 4111)
                                           (equal? (sc2-raw-unit-command-unit-tags c) '(98552))))
                          l58p2-inf-cmds)))

  ;; 18. L58-P3 (`#1451`): Arena Pass 3 wire fixes:
  ;;     (a) `sc2-ab-t10`: `>= 8` combat units & `0` Ravens/Turrets reserves Scan (`floor = 101.0e`) across
  ;;         BOTH `Case C (171)` & `L23-P0-1` even before contact / in multi-race batches, + `24f` MULE refractory,
  ;;     (b) `sc2-ab-z01`: weaponless spellcasters (`111` Infestor, `499` Viper, `56` Raven, `82` Observer,
  ;;         `129` Overseer, `81` WarpPrism, `694` Disruptor, `494` SwarmHost) strip `Attack (23)` without
  ;;         stealing `commanded-combat-tags`, so `cast-protective-buff-aura 'microbial-shroud` emits `4111`
  ;;         on unburrowed `111` (and skips burrowed `127`),
  ;;     (c) `sc2-real-p05`: incomplete non-structures (merging `Archon 141` `bp < 1.0`) & immobile morphed
  ;;         supports (`136`/`1911`/`1912`) strip both `Move (16)` & `Attack (23)` (`0` `2:NotSupported`),
  ;;     (d) `sc2-runby-ro01` & `sc2-ab-t01`: reloading burrowed `WidowMine (500, weapon-cooldown > 0)` drops
  ;;         `2099` (`6:Cooldown`), and `Viking` with active `403`/`405` order drops duplicate morph (`4:CantQueueThatOrder`)!

  ;; (18a) `sc2-ab-t10` scan reserve across unknown/Zerg race before contact + 24f MULE refractory
  (define l58p3-oc-100 (mk-l58-u 98601 132 1 30.0 30.0 #:hp 1500.0 #:en 100.0))
  (define l58p3-oc-105 (mk-l58-u 98601 132 1 30.0 30.0 #:hp 1500.0 #:en 105.0))
  (define l58p3-mars8
    (for/list ([i (in-range 8)])
      (mk-l58-u (+ 98610 i) 48 1 (+ 34.0 (* 0.4 i)) 30.0 #:hp 45.0 #:en 0.0 #:en-max 0.0)))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define l58p3-obs-100 (make-test-obs 2204 50 0 (append (list l58p3-oc-100 l58p2-min) l58p3-mars8)))
  (define l58p3-tr-100  (translate-bot-actions->sc2-raw-commands '((cast-spell 98601 calldown-mule 98523)) l58p3-obs-100 #:game-info l55-gi-z))
  (define l58p3-sat-100 (saturate-workers-and-gas-commands l58p3-obs-100 #:game-info l55-gi-z))
  ;; At 105e on loop 2208 -> drops 1 MULE; 16 loops later on loop 2224 (< 24f refractory!) -> drops 0 MULE!
  (define l58p3-obs-105a (make-test-obs 2208 50 0 (append (list l58p3-oc-105 l58p2-min) l58p3-mars8)))
  (define l58p3-sat-105a (saturate-workers-and-gas-commands l58p3-obs-105a #:game-info l55-gi-z))
  (define l58p3-obs-105b (make-test-obs 2224 50 0 (append (list l58p3-oc-105 l58p2-min) l58p3-mars8)))
  (define l58p3-sat-105b (saturate-workers-and-gas-commands l58p3-obs-105b #:game-info l55-gi-z))
  (check-true "l58-p3-t10-scan-reserve-across-unknown-race-and-24f-mule-refractory"
              (and (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 171))) l58p3-tr-100))
                   (null? (l55-mule-tags l58p3-sat-100))
                   (equal? (l55-mule-tags l58p3-sat-105a) '(98601))
                   (null? (l55-mule-tags l58p3-sat-105b))))

  ;; (18b) `sc2-ab-z01`: Infestor (111) strips bogus Attack (23) AND stays free for `4111` Microbial Shroud!
  (define l58p3-inf-u (mk-l58-u 98631 111 1 82.0 86.0 #:hp 90.0 #:en 120.0))
  (define l58p3-inf-b (mk-l58-u 98632 127 1 81.0 86.0 #:hp 90.0 #:en 120.0 #:burr #t))
  (define l58p3-hyd   (mk-l58-u 98633 107 1 83.0 86.0 #:hp 90.0 #:en 0.0 #:en-max 0.0))
  (define l58p3-ecar  (mk-l58-u 98639 79  4 92.0 86.0 #:hp 300.0 #:en 0.0 #:en-max 0.0 #:fly #t))
  (define l58p3-z01-cmds
    (translate-bot-actions->sc2-raw-commands
     '((attack-unit (98631 98633) 98639)
       (attack-pos (98631 98632) 92.0 86.0)
       (cast-protective-buff-aura microbial-shroud 83.0 86.0 3.5))
     (make-test-obs 7100 200 100 (list l58p3-inf-u l58p3-inf-b l58p3-hyd l58p3-ecar))))
  ;; Also verify `cast-protective-buff-aura 'microbial-shroud` NEVER picks burrowed 127 when only 127 exists!
  (define l58p3-z01-bur-only
    (translate-bot-actions->sc2-raw-commands
     '((cast-protective-buff-aura microbial-shroud 83.0 86.0 3.5))
     (make-test-obs 7104 200 100 (list l58p3-inf-b l58p3-ecar))))
  (check-true "l58-p3-z01-unarmed-infestor-strips-23-and-fires-4111-on-unburrowed-111-only"
              (and (not (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                                (= (sc2-raw-unit-command-ability-id c) 23)
                                                (or (memv 98631 (sc2-raw-unit-command-unit-tags c))
                                                    (memv 98632 (sc2-raw-unit-command-unit-tags c)))))
                               l58p3-z01-cmds))
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                           (= (sc2-raw-unit-command-ability-id c) 23)
                                           (equal? (sc2-raw-unit-command-unit-tags c) '(98633))))
                          l58p3-z01-cmds)
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                           (= (sc2-raw-unit-command-ability-id c) 4111)
                                           (equal? (sc2-raw-unit-command-unit-tags c) '(98631))))
                          l58p3-z01-cmds)
                   (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 4111)))
                               l58p3-z01-bur-only))))

  ;; (18c) `sc2-real-p05`: Merging Archon (141, bp=0.45) & WarpPrismPhasing (136) strip Move (16) & Attack (23),
  ;;       while completed Archon (141, bp=1.0) executes both cleanly!
  (define l58p3-arch-inc
    (sc2-unit 1 1 98641 141 1 (sc2-point3d 84.0 86.0 8.0) 0.0 1.0 0.45 0 #f #t #f
              10.0 10.0 350.0 350.0 0.0 0.0 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0 '() 0 0))
  (define l58p3-arch-ok (mk-l58-u 98642 141 1 85.0 86.0 #:hp 10.0 #:en 0.0 #:en-max 0.0))
  (define l58p3-wpp     (mk-l58-u 98643 136 1 83.0 86.0 #:hp 80.0 #:en 0.0 #:en-max 0.0 #:fly #t))
  (define l58p3-ehyd    (mk-l58-u 98649 107 4 91.0 86.0 #:hp 90.0 #:en 0.0 #:en-max 0.0))
  (define l58p3-p05-cmds
    (translate-bot-actions->sc2-raw-commands
     '((move (98641 98643) 90.0 86.0)
       (attack-unit (98641 98642 98643) 98649))
     (make-test-obs 7200 200 100 (list l58p3-arch-inc l58p3-arch-ok l58p3-wpp l58p3-ehyd))))
  (check-true "l58-p3-p05-merging-archon-and-phased-prism-strip-16-and-23"
              (and (not (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                                (memv (sc2-raw-unit-command-ability-id c) '(16 23))
                                                (or (memv 98641 (sc2-raw-unit-command-unit-tags c))
                                                    (memv 98643 (sc2-raw-unit-command-unit-tags c)))))
                               l58p3-p05-cmds))
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                           (= (sc2-raw-unit-command-ability-id c) 23)
                                           (equal? (sc2-raw-unit-command-unit-tags c) '(98642))))
                          l58p3-p05-cmds)))

  ;; (18d) `sc2-runby-ro01` WidowMine (500) weapon-cooldown > 0 drops `2099` (`6:Cooldown`) &
  ;;       `sc2-ab-t01` Viking already executing morph `403` drops duplicate `403`/`405` (`4:CantQueueThatOrder`)!
  (define l58p3-wm-cd
    (sc2-unit 1 1 98651 500 1 (sc2-point3d 84.0 86.0 8.0) 0.0 0.5 1.0 0 #f #t #f
              90.0 90.0 0.0 0.0 0.0 0.0 0 0 #f #t #f #t #f '() 0 '() 0 0 18.0 0 0 0 0 '() 0 0))
  (define l58p3-wm-ok (mk-l58-u 98652 500 1 85.0 86.0 #:hp 90.0 #:en 0.0 #:en-max 0.0 #:burr #t))
  (define l58p3-vik-tx
    (mk-l58-u 98653 35 1 83.0 86.0 #:hp 135.0 #:en 0.0 #:en-max 0.0 #:fly #t
              #:orders (list (sc2-unit-order 403 #f 0 0.3))))
  (define l58p3-vik-ok (mk-l58-u 98654 35 1 83.5 86.0 #:hp 135.0 #:en 0.0 #:en-max 0.0 #:fly #t))
  (define l58p3-edrn (mk-l58-u 98659 104 4 86.0 86.0 #:hp 40.0 #:en 0.0 #:en-max 0.0))
  (define l58p3-ro01-cmds
    (translate-bot-actions->sc2-raw-commands
     '((widow-mine-retarget 98651 98659)
       (attack-unit (98651 98652) 98659)
       (cast-spell (98653 98654) morph-viking-assault))
     (make-test-obs 7300 200 100 (list l58p3-wm-cd l58p3-wm-ok l58p3-vik-tx l58p3-vik-ok l58p3-edrn))))
  ;; Clean rewind reset
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 100 (list l55-min1))))
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 100 (list l55-min1))))
  (check-true "l58-p3-ro01-widow-mine-2099-cooldown-and-t01-viking-morph-order-dedup"
              (and (not (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                                (= (sc2-raw-unit-command-ability-id c) 2099)
                                                (memv 98651 (sc2-raw-unit-command-unit-tags c))))
                               l58p3-ro01-cmds))
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                           (= (sc2-raw-unit-command-ability-id c) 2099)
                                           (equal? (sc2-raw-unit-command-unit-tags c) '(98652))))
                          l58p3-ro01-cmds)
                   (not (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                                (= (sc2-raw-unit-command-ability-id c) 403)
                                                (memv 98653 (sc2-raw-unit-command-unit-tags c))))
                               l58p3-ro01-cmds))
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c)
                                           (= (sc2-raw-unit-command-ability-id c) 403)
                                           (equal? (sc2-raw-unit-command-unit-tags c) '(98654))))
                          l58p3-ro01-cmds)))

  ;; 19. L58-P3B (`#1469`): Quick 3-item wire polish:
  ;;     (a) `sc2-ab-z01`: Unit-targeted `Attack (23)` on untargetable `Interceptor (85)` auto-converts
  ;;         to point-target `Attack-Move` at Interceptor's `(x, y)` (`0` `2:NotSupported`), and `Medivac (54)`
  ;;         strips ALL `23` (both point-target & unit-target),
  ;;     (b) `sc2-ab-t10`: `>= 6` combat units (or latched enemy cloak sighting!) preserves Scan energy on
  ;;         top-1 OC even when combat units drop `< 6` mid-fight,
  ;;     (c) `sc2-real-t04` & `sc2-det-d12`: Medivac Heal (`386`) requires live damaged unhealed bio ally,
  ;;         auto-redirects Medivac #2 to a second wounded bio ally (`0` `206:AlreadyTargeted`), and skips
  ;;         full-HP / Mech targets!

  ;; (19a) Interceptor (85) unit-target Attack (23) -> Attack-Move point-target + Medivac (54) strips ALL 23
  (define l58p3b-hyd  (mk-l58-u 98701 107 1 83.0 86.0 #:hp 90.0 #:en 0.0 #:en-max 0.0))
  (define l58p3b-med  (mk-l58-u 98702 54  1 82.0 86.0 #:hp 150.0 #:en 100.0 #:fly #t))
  (define l58p3b-intc (mk-l58-u 98709 85  4 89.5 87.5 #:hp 40.0 #:en 0.0 #:en-max 0.0 #:fly #t))
  (define l58p3b-z01-cmds
    (translate-bot-actions->sc2-raw-commands
     '((attack-unit 98701 98709)
       (attack-pos 98702 89.5 87.5)
       (attack-unit 98702 98709))
     (make-test-obs 7400 200 100 (list l58p3b-hyd l58p3b-med l58p3b-intc))))
  (check-true "l58-p3b-z01-interceptor-85-converts-to-attack-move-and-medivac-strips-all-23"
              (and (ormap (lambda (c)
                            (and (sc2-raw-unit-command? c)
                                 (= (sc2-raw-unit-command-ability-id c) 23)
                                 (= (sc2-raw-unit-command-target-unit-tag c) 0)
                                 (sc2-point2d? (sc2-raw-unit-command-target-pos c))
                                 (< (abs (- (sc2-point2d-x (sc2-raw-unit-command-target-pos c)) 89.5)) 0.1)
                                 (equal? (sc2-raw-unit-command-unit-tags c) '(98701))))
                          l58p3b-z01-cmds)
                   (not (ormap (lambda (c)
                                 (and (sc2-raw-unit-command? c)
                                      (= (sc2-raw-unit-command-ability-id c) 23)
                                      (memv 98702 (sc2-raw-unit-command-unit-tags c))))
                               l58p3b-z01-cmds))))

  ;; (19b) 6-combat reserve + enemy cloak latch keeps OC at >= 50e even when Marines drop to 4 (< 6)!
  (define l58p3b-oc-100 (mk-l58-u 98711 132 1 30.0 30.0 #:hp 1500.0 #:en 100.0))
  (define l58p3b-oc-70  (mk-l58-u 98711 132 1 30.0 30.0 #:hp 1500.0 #:en 70.0))
  (define l58p3b-mars6  (for/list ([i (in-range 6)])
                          (mk-l58-u (+ 98720 i) 48 1 (+ 34.0 (* 0.4 i)) 30.0 #:hp 45.0 #:en 0.0 #:en-max 0.0)))
  (define l58p3b-mars4  (take l58p3b-mars6 4))
  (define l58p3b-dt-far (mk-l58-u 98729 76 4 120.0 120.0 #:hp 40.0 #:en 0.0 #:en-max 0.0 #:cloak 1))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define l58p3b-sat-6m
    (l55-mule-tags (saturate-workers-and-gas-commands
                    (make-test-obs 7450 50 0 (append (list l58p3b-oc-100 l58p2-min) l58p3b-mars6))
                    #:game-info l55-gi-z)))
  ;; Sight DT once (latches SC2-SAT-SEEN-ENEMY-CLOAK?), then next tick with only 4 Marines & 0 visible DTs -> 70e OC STILL holds Scan!
  (void (saturate-workers-and-gas-commands
         (make-test-obs 7454 50 0 (append (list l58p3b-oc-70 l58p2-min l58p3b-dt-far) l58p3b-mars4))
         #:game-info l55-gi-z))
  (define l58p3b-sat-4m-latched
    (l55-mule-tags (saturate-workers-and-gas-commands
                    (make-test-obs 7490 50 0 (append (list l58p3b-oc-70 l58p2-min) l58p3b-mars4))
                    #:game-info l55-gi-z)))
  (check-true "l58-p3b-t10-6-combat-and-cloak-latch-preserve-oc-scan-energy"
              (and (null? l58p3b-sat-6m)
                   (null? l58p3b-sat-4m-latched)))

  ;; (19c) Medivac Heal (386): bio-only damaged check + single-healer dedup + Medivac #2 auto-redirect!
  (define l58p3b-med1 (mk-l58-u 98731 54 1 82.0 86.0 #:hp 150.0 #:en 100.0 #:fly #t))
  (define l58p3b-med2 (mk-l58-u 98732 54 1 82.5 86.0 #:hp 150.0 #:en 100.0 #:fly #t))
  (define l58p3b-m1-w (mk-l58-u 98733 48 1 84.0 86.0 #:hp 20.0 #:hp-max 45.0 #:en 0.0 #:en-max 0.0))
  (define l58p3b-m2-w (mk-l58-u 98734 48 1 85.0 86.0 #:hp 25.0 #:hp-max 45.0 #:en 0.0 #:en-max 0.0))
  (define l58p3b-m3-f (mk-l58-u 98735 48 1 84.5 86.5 #:hp 45.0 #:hp-max 45.0 #:en 0.0 #:en-max 0.0))
  (define l58p3b-tnk  (mk-l58-u 98736 33 1 84.5 85.5 #:hp 80.0 #:hp-max 175.0 #:en 0.0 #:en-max 0.0))
  (define l58p3b-heal-cmds
    (translate-bot-actions->sc2-raw-commands
     '((cast-spell 98731 heal 98735)
       (cast-spell 98731 heal 98736)
       (cast-spell 98731 heal 98733)
       (cast-spell 98732 heal 98733))
     (make-test-obs 7500 200 100 (list l58p3b-med1 l58p3b-med2 l58p3b-m1-w l58p3b-m2-w l58p3b-m3-f l58p3b-tnk))))
  ;; Clean rewind reset
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 100 (list l55-min1))))
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 100 (list l55-min1))))
  (define l58p3b-386-cmds
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 386)))
            l58p3b-heal-cmds))
  (check-true "l58-p3b-t04-d12-medivac-heal-386-dedup-bio-only-and-auto-redirect"
              (and (= (length l58p3b-386-cmds) 2)
                   (not (ormap (lambda (c) (memv (sc2-raw-unit-command-target-unit-tag c) '(98735 98736)))
                               l58p3b-386-cmds))
                   (= (length (remove-duplicates (map sc2-raw-unit-command-target-unit-tag l58p3b-386-cmds))) 2)))

  (hash-clear! SC2-DEPOT-TOGGLE-COOLDOWN)
  (hash-clear! SC2-PROD-PLACEMENT-MISS-STREAK)
  (hash-clear! SC2-WATCHDOG-RING-EXPAND-SYMS))

;; =============================================================================
;; Loop 59 Package 1 (`L59-W1`, `#1507`): Pro APM/EPM/SPM + Base-Centered Camera
;; Hotkeys & Minimap Clicks + All `#1502`/`#1499` Tier-1 Wire Fixes
;; =============================================================================
(printf "[Loop 59] Testing L59-W1 Pro APM/SPM governor, base-centered camera hotkeys, minimap clicks, neutral-units/expansion-pads, forward Warp Prism priority, dropship rescue unload & all 11 TC<->WS aliases...\n")
(let ()
  (define (l59-dist x1 y1 x2 y2)
    (sqrt (+ (sqr (- x1 x2)) (sqr (- y1 y2)))))
  (define (mk-l59-u tag utype alliance x y
                    #:hp [hp 100.0] #:hp-max [hp-max hp]
                    #:sh [sh 0.0] #:sh-max [sh-max sh]
                    #:en [en 100.0] #:en-max [en-max 200.0]
                    #:fly [fly #f] #:burr [burr #f] #:powered [powered #t]
                    #:cloak [cloak 0]
                    #:rad [rad 0.75] #:bp [bp 1.0]
                    #:mins [mins 0] #:gas [gas 0]
                    #:orders [ords '()] #:buffs [buffs '()]
                    #:pax [pax '()] #:ctaken [ctaken 0] #:cmax [cmax 0])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 (if (= alliance 4) 2 0))
              (sc2-point3d x y 8.0) 0.0 rad bp cloak #f #t #f
              hp hp-max sh sh-max en en-max mins gas fly burr #f powered #f
              ords 0 buffs 0 0 0.0 0 0 0 0 pax ctaken cmax))

  ;; 1. Pro APM / EPM / SPM governor defaults + P2 Pro camera jump vs P4 legacy raw camera
  (define l59-gov (make-wire-apm-governor))
  (define l59-raw-cam (sc2-raw-camera-move 50.0 50.0 0.0))
  (define l59-pro-cam (mark-pro-camera-jump-cmd! (sc2-raw-camera-move 50.0 50.0 0.0)))
  (check-true "l59-w1-pro-apm-governor-defaults-and-dedup-dist"
              (and (= (wire-apm-governor-target-apm l59-gov) 530.0)
                   (= (wire-apm-governor-hard-cap-apm l59-gov) 595.0)
                   (= (wire-apm-governor-burst-capacity l59-gov) 36.0)
                   (= SC2-CAMERA-MOVE-DEDUP-DIST 8.0)
                   (= (wire-cmd-priority-tier l59-raw-cam) 4)
                   (= (wire-cmd-priority-tier l59-pro-cam) 2)
                   (not (pro-camera-jump-cmd? l59-raw-cam))
                   (pro-camera-jump-cmd? l59-pro-cam)))

  ;; 2. Pro camera cooldown: 18-loop routine base/minimap vs 6-loop crisis (>14t) vs 28-loop legacy,
  ;;    plus cross-step short non-base scroll-drift suppression (<= 8.0t) & 5:00+ combat saturation rescue!
  (define l59-gov-pro (make-wire-apm-governor))
  (define l59-cc-m (mk-l59-u 99001 18 1 28.5 28.5 #:hp 1500.0 #:en 0.0 #:en-max 0.0 #:rad 2.75))
  (define l59-cc-n (mk-l59-u 99002 18 1 64.5 28.5 #:hp 1500.0 #:en 0.0 #:en-max 0.0 #:rad 2.75))
  (define l59-cam-obs (make-test-obs 9000 200 100 (list l59-cc-m l59-cc-n)))
  (define c-pro-0
    (govern-sc2-wire-actions!
     l59-gov-pro
     (list (mark-pro-camera-jump-cmd! (sc2-raw-camera-move 80.0 80.0 0.0)))
     9000 l59-cam-obs))
  ;; +6 loops, distant crisis/minimap jump (40t > 14t) -> ALLOWED!
  (define c-pro-crisis
    (govern-sc2-wire-actions!
     l59-gov-pro
     (list (mark-pro-camera-jump-cmd! (sc2-raw-camera-move 120.0 80.0 0.0) 40.0 #:crisis? #t))
     9006 l59-cam-obs))
  ;; +12 loops, medium jump (10t <= 14t) -> blocked (needs 18 loops)
  (define c-pro-too-soon
    (govern-sc2-wire-actions!
     l59-gov-pro
     (list (mark-pro-camera-jump-cmd! (sc2-raw-camera-move 110.0 80.0 0.0)))
     9018 l59-cam-obs))
  ;; +18 loops from 9006 (= 9024), medium jump (10t > 8.0t) -> ALLOWED!
  (define c-pro-routine18
    (govern-sc2-wire-actions!
     l59-gov-pro
     (list (mark-pro-camera-jump-cmd! (sc2-raw-camera-move 110.0 80.0 0.0)))
     9024 l59-cam-obs))
  ;; +20 loops (= 9044), tiny non-base scroll drift (4.0t <= 8.0t) -> SUPPRESSED!
  (define c-pro-drift
    (govern-sc2-wire-actions!
     l59-gov-pro
     (list (mark-pro-camera-jump-cmd! (sc2-raw-camera-move 114.0 80.0 0.0)))
     9044 l59-cam-obs))
  ;; +30 loops (= 9054, overdue >= 28) under 40 P3 combat moves -> P2 Pro camera NOT starved & capped <= 1!
  (define p3-flood
    (for/list ([i (in-range 40)])
      (sc2-raw-unit-command 16 (sc2-point2d (+ 70.0 (* 0.5 i)) 70.0) 0 (list (+ 99500 i)) #f)))
  (define c-pro-midgame
    (govern-sc2-wire-actions!
     l59-gov-pro
     (append p3-flood
             (list (mark-pro-camera-jump-cmd! (sc2-raw-camera-move 28.5 28.5 0.0))
                   (mark-pro-camera-jump-cmd! (sc2-raw-camera-move 64.5 28.5 0.0))))
     9054 l59-cam-obs))
  (define c-pro-midgame-cams (filter sc2-raw-camera-move? c-pro-midgame))
  ;; Legacy unmarked raw camera still obeys 28-loop cooldown (blocked at +20, allowed at +28)
  (define l59-gov-leg (make-wire-apm-governor))
  (define c-leg-0  (govern-sc2-wire-actions! l59-gov-leg (list (sc2-raw-camera-move 40.0 40.0 0.0)) 1000))
  (define c-leg-20 (govern-sc2-wire-actions! l59-gov-leg (list (sc2-raw-camera-move 90.0 90.0 0.0)) 1020))
  (define c-leg-28 (govern-sc2-wire-actions! l59-gov-leg (list (sc2-raw-camera-move 90.0 90.0 0.0)) 1028))
  (check-true "l59-w1-pro-camera-cooldown-18-routine-6-crisis-drift-suppress-and-midgame-p2-survival"
              (and (= (length c-pro-0) 1)
                   (= (length c-pro-crisis) 1)
                   (null? c-pro-too-soon)
                   (= (length c-pro-routine18) 1)
                   (null? c-pro-drift)
                   (= (length c-pro-midgame-cams) 1)
                   (= (length c-leg-0) 1)
                   (null? c-leg-20)
                   (= (length c-leg-28) 1)))

  ;; 3. Base-Centered Camera Hotkeys (<= 16t snaps to exact townhall center) + Minimap Clicks vs Scroll Drift
  (define l59-cam-obs-at-80
    (sc2-observation 9100 (sc2-player-common 1 200 100 40 20 10 10 0 0 0 0)
                     (list l59-cc-m l59-cc-n) '() '()
                     (sc2-point3d 80.0 80.0 0.0) '() '() '() '() '() '()))
  (define l59-base-snap-cmds
    (translate-bot-actions->sc2-raw-commands
     '((camera-focus 36.0 34.0))
     l59-cam-obs-at-80))
  (define l59-base-cam (findf sc2-raw-camera-move? l59-base-snap-cmds))
  (define l59-drift-cmds
    (translate-bot-actions->sc2-raw-commands
     '((move-camera 84.0 81.0))
     l59-cam-obs-at-80))
  (define l59-minimap-cmds
    (translate-bot-actions->sc2-raw-commands
     '((move-camera 120.0 110.0))
     l59-cam-obs-at-80))
  (define l59-mm-cam (findf sc2-raw-camera-move? l59-minimap-cmds))
  (check-true "l59-w1-base-centered-camera-snap-and-minimap-vs-scroll-drift"
              (and (sc2-raw-camera-move? l59-base-cam)
                   (pro-camera-jump-cmd? l59-base-cam)
                   (< (abs (- (sc2-raw-camera-move-x l59-base-cam) 28.5)) 0.01)
                   (< (abs (- (sc2-raw-camera-move-y l59-base-cam) 28.5)) 0.01)
                   (not (ormap sc2-raw-camera-move? l59-drift-cmds))
                   (sc2-raw-camera-move? l59-mm-cam)
                   (pro-camera-jump-cmd? l59-mm-cam)
                   (< (abs (- (sc2-raw-camera-move-x l59-mm-cam) 120.0)) 0.01)
                   (< (abs (- (sc2-raw-camera-move-y l59-mm-cam) 110.0)) 0.01)))

  ;; 4. `sc2-observation->runtime-obs-hash` emits `'neutral-units` (minerals/walls/gold/geysers/rocks/towers,
  ;;    skipping critters) AND `'expansion-pads`!
  (define l59-neut-min   (mk-l59-u 99011 341  3 22.0 28.0 #:hp 1000.0 #:mins 1500))
  (define l59-neut-gold  (mk-l59-u 99012 146  3 72.0 28.0 #:hp 1000.0 #:mins 900))
  (define l59-neut-wall  (mk-l59-u 99013 1996 3 55.0 55.0 #:hp 1000.0 #:mins 5))
  (define l59-neut-gas   (mk-l59-u 99014 342  3 24.0 34.0 #:hp 1000.0 #:gas 2250))
  (define l59-neut-rock  (mk-l59-u 99015 367  3 60.0 60.0 #:hp 2000.0))
  (define l59-neut-ctwr  (mk-l59-u 99016 588  3 62.0 60.0 #:hp 500.0))
  (define l59-neut-xnt   (mk-l59-u 99017 149  3 64.0 64.0 #:hp 1000.0))
  (define l59-neut-crit  (mk-l59-u 99018 190  3 50.0 50.0 #:hp 10.0)) ;; critter -> excluded!
  ;; Add cluster of minerals for an expansion pad around (68, 28)
  (define l59-exp-mins
    (for/list ([y (in-list '(25.0 27.0 29.0 31.0))] [i (in-naturals 0)])
      (mk-l59-u (+ 99020 i) 341 3 72.0 y #:hp 1000.0 #:mins 1500)))
  (define l59-obs-neut
    (make-test-obs 400 200 100
                   (append (list l59-cc-m l59-neut-min l59-neut-gold l59-neut-wall
                                 l59-neut-gas l59-neut-rock l59-neut-ctwr l59-neut-xnt l59-neut-crit)
                           l59-exp-mins)))
  (define l59-obs-hash (sc2-observation->runtime-obs-hash l59-obs-neut))
  (define l59-neut-list (hash-ref l59-obs-hash 'neutral-units '()))
  (define l59-neut-tags (map (lambda (h) (hash-ref h 'id 0)) l59-neut-list))
  (define l59-exp-pads (hash-ref l59-obs-hash 'expansion-pads '()))
  (check-true "l59-w1-obs-hash-emits-neutral-units-and-expansion-pads"
              (and (memv 99011 l59-neut-tags)
                   (memv 99012 l59-neut-tags)
                   (memv 99013 l59-neut-tags)
                   (memv 99014 l59-neut-tags)
                   (memv 99015 l59-neut-tags)
                   (memv 99016 l59-neut-tags)
                   (memv 99017 l59-neut-tags)
                   (not (memv 99018 l59-neut-tags))
                   (let ([xnt (findf (lambda (h) (= (hash-ref h 'id 0) 99017)) l59-neut-list)])
                     (and xnt (eq? (hash-ref xnt 'type #f) 'xel-naga-tower)))
                   (list? l59-exp-pads)
                   (pair? l59-exp-pads)))

  ;; 5. Forward Phasing Warp Prism (136) Warp-In Priority:
  ;;    - Explicit `(warp-in wg-id dark-templar 100.0 100.0)` -> 1417 near Prism EVEN with 1 nearby Marine!
  ;;    - Explicit 4-arg `(train-unit wg-id zealot 100.0 100.0)` -> 1413 near Prism!
  ;;    - Offensive 2-arg `(train-unit wg-id stalker)` with uncontested Prism -> 1414 near Prism!
  ;;    - Routine `(train zealot)` -> keeps home Pylon `(30, 30)` priority!
  (define l59-nx   (mk-l59-u 99100 59  1 28.0 28.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75))
  (define l59-pyl  (mk-l59-u 99101 60  1 30.0 34.0 #:hp 200.0 #:sh 200.0 #:rad 1.0))
  (define l59-wg1  (mk-l59-u 99102 133 1 32.0 34.0 #:hp 500.0 #:sh 500.0 #:rad 1.5))
  (define l59-wg2  (mk-l59-u 99103 133 1 35.0 34.0 #:hp 500.0 #:sh 500.0 #:rad 1.5))
  (define l59-wg3  (mk-l59-u 99104 133 1 38.0 34.0 #:hp 500.0 #:sh 500.0 #:rad 1.5))
  (define l59-wg4  (mk-l59-u 99105 133 1 41.0 34.0 #:hp 500.0 #:sh 500.0 #:rad 1.5))
  (define l59-wpp  (mk-l59-u 99106 136 1 100.0 100.0 #:hp 80.0 #:sh 100.0 #:fly #t))
  (define l59-emar (mk-l59-u 99109 48  4 105.0 100.0 #:hp 45.0 #:en 0.0 #:en-max 0.0))
  (define l59-psrcs
    (list (sc2-power-source (sc2-point3d 30.0 34.0 8.0) 6.5 99101)
          (sc2-power-source (sc2-point3d 100.0 100.0 8.0) 3.75 99106)))
  (define l59-prism-obs-clean
    (sc2-observation 9200 (sc2-player-common 1 800 400 80 40 20 20 0 0 4 0)
                     (list l59-nx l59-pyl l59-wg1 l59-wg2 l59-wg3 l59-wg4 l59-wpp)
                     '(84) l59-psrcs #f '() '() '() '() '() '()))
  (define l59-prism-obs-cont
    (sc2-observation 9210 (sc2-player-common 1 800 400 80 40 20 20 0 0 4 0)
                     (list l59-nx l59-pyl l59-wg1 l59-wg2 l59-wg3 l59-wg4 l59-wpp l59-emar)
                     '(84) l59-psrcs #f '() '() '() '() '() '()))
  (define l59-wi-explicit-cmds
    (translate-bot-actions->sc2-raw-commands
     '((warp-in 99102 dark-templar 100.0 100.0)
       (train-unit 99103 zealot 100.0 100.0))
     l59-prism-obs-cont #:enemy-base '(108.0 . 108.0)))
  (define l59-wi-off-cmds
    (translate-bot-actions->sc2-raw-commands
     '((train-unit 99104 stalker)
       (train zealot))
     l59-prism-obs-clean #:enemy-base '(108.0 . 108.0)))
  (define c-dt-wi  (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1417))) l59-wi-explicit-cmds))
  (define c-zl-4a  (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1413))) l59-wi-explicit-cmds))
  (define c-st-2a  (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1414))) l59-wi-off-cmds))
  (define c-zl-hm  (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1413))) l59-wi-off-cmds))
  (check-true "l59-w1-forward-warp-prism-priority-explicit-offensive-and-home-routine"
              (and (sc2-raw-unit-command? c-dt-wi)
                   (<= (l59-dist (sc2-point2d-x (sc2-raw-unit-command-target-pos c-dt-wi))
                                 (sc2-point2d-y (sc2-raw-unit-command-target-pos c-dt-wi))
                                 100.0 100.0) 3.15)
                   (sc2-raw-unit-command? c-zl-4a)
                   (<= (l59-dist (sc2-point2d-x (sc2-raw-unit-command-target-pos c-zl-4a))
                                 (sc2-point2d-y (sc2-raw-unit-command-target-pos c-zl-4a))
                                 100.0 100.0) 3.15)
                   (sc2-raw-unit-command? c-st-2a)
                   (<= (l59-dist (sc2-point2d-x (sc2-raw-unit-command-target-pos c-st-2a))
                                 (sc2-point2d-y (sc2-raw-unit-command-target-pos c-st-2a))
                                 100.0 100.0) 3.15)
                   (sc2-raw-unit-command? c-zl-hm)
                   (<= (l59-dist (sc2-point2d-x (sc2-raw-unit-command-target-pos c-zl-hm))
                                 (sc2-point2d-y (sc2-raw-unit-command-target-pos c-zl-hm))
                                 30.0 34.0) 6.5)))

  ;; 6. Dropship Rescue Unload (`transport-juggle` 4-arg when passenger already carried -> UNLOAD_ALL_AT
  ;;    396/913/1408, NOT 3668!) + 3-arg `(attack uid x y)` -> 23 point + 2-arg `(harvest wid tid)` -> 3666!
  (define l59-med-loaded
    (mk-l59-u 99201 54 1 86.0 86.0 #:hp 150.0 #:fly #t #:ctaken 1 #:cmax 8
              #:pax (list (sc2-passenger-unit 99210 48 45.0 45.0 0.0 0.0 0.0 0.0))))
  (define l59-med-empty
    (mk-l59-u 99202 54 1 82.0 86.0 #:hp 150.0 #:fly #t #:ctaken 0 #:cmax 8))
  (define l59-mar-gnd (mk-l59-u 99211 48 1 82.5 86.0 #:hp 45.0 #:en 0.0 #:en-max 0.0))
  (define l59-mar-atk (mk-l59-u 99212 48 1 80.0 80.0 #:hp 45.0 #:en 0.0 #:en-max 0.0))
  (define l59-scv-har (mk-l59-u 99213 45 1 26.0 28.0 #:hp 45.0 #:en 0.0 #:en-max 0.0))
  (define l59-min-har (mk-l59-u 99214 341 3 22.0 28.0 #:hp 1000.0 #:mins 1500))
  (define l59-juggle-cmds
    (translate-bot-actions->sc2-raw-commands
     '((transport-juggle 99201 (99210) 88.0 88.0)
       (transport-juggle 99202 (99211) 88.0 88.0)
       (attack 99212 95.0 95.0)
       (harvest 99213 99214))
     (make-test-obs 9300 200 100 (list l59-med-loaded l59-med-empty l59-mar-gnd l59-mar-atk l59-scv-har l59-min-har))))
  (check-true "l59-w1-dropship-rescue-unload-3arg-attack-and-2arg-harvest"
              (and (ormap (lambda (c)
                            (and (sc2-raw-unit-command? c)
                                 (= (sc2-raw-unit-command-ability-id c) 396)
                                 (equal? (sc2-raw-unit-command-unit-tags c) '(99201))
                                 (sc2-point2d? (sc2-raw-unit-command-target-pos c))
                                 (< (abs (- (sc2-point2d-x (sc2-raw-unit-command-target-pos c)) 88.0)) 0.1)))
                          l59-juggle-cmds)
                   (not (ormap (lambda (c)
                                 (and (sc2-raw-unit-command? c)
                                      (= (sc2-raw-unit-command-ability-id c) 3668)
                                      (memv 99201 (sc2-raw-unit-command-unit-tags c))))
                               l59-juggle-cmds))
                   (ormap (lambda (c)
                            (and (sc2-raw-unit-command? c)
                                 (= (sc2-raw-unit-command-ability-id c) 3668)
                                 (equal? (sc2-raw-unit-command-unit-tags c) '(99202))
                                 (= (sc2-raw-unit-command-target-unit-tag c) 99211)))
                          l59-juggle-cmds)
                   (ormap (lambda (c)
                            (and (sc2-raw-unit-command? c)
                                 (= (sc2-raw-unit-command-ability-id c) 23)
                                 (equal? (sc2-raw-unit-command-unit-tags c) '(99212))
                                 (sc2-point2d? (sc2-raw-unit-command-target-pos c))
                                 (< (abs (- (sc2-point2d-x (sc2-raw-unit-command-target-pos c)) 95.0)) 0.1)))
                          l59-juggle-cmds)
                   (ormap (lambda (c)
                            (and (sc2-raw-unit-command? c)
                                 (= (sc2-raw-unit-command-ability-id c) 3666)
                                 (equal? (sc2-raw-unit-command-unit-tags c) '(99213))
                                 (= (sc2-raw-unit-command-target-unit-tag c) 99214)))
                          l59-juggle-cmds)))

  ;; 7. End-to-End Verification of ALL 11 Fixed TC<->WS Aliases + Standalone Heads
  ;;    (filter-valid-bot-actions -> translate-bot-actions->sc2-raw-commands -> encode-sc2-action: 0 rejects, 0 drops!)
  (define rej0  (get-total-bot-action-reject-count))
  (define drop0 (get-total-wire-action-drop-count))
  (define l59-a-gh1   (mk-l59-u 99301 50  1 50.0 50.0 #:hp 100.0 #:en 100.0))
  (define l59-a-gh2   (mk-l59-u 99302 50  1 52.0 50.0 #:hp 100.0 #:en 100.0))
  (define l59-a-sen   (mk-l59-u 99303 77  1 54.0 50.0 #:hp 40.0  #:en 100.0))
  (define l59-a-ora1  (mk-l59-u 99304 495 1 56.0 50.0 #:hp 100.0 #:en 100.0 #:fly #t))
  (define l59-a-ora2  (mk-l59-u 99305 495 1 58.0 50.0 #:hp 100.0 #:en 100.0 #:fly #t))
  (define l59-a-scv   (mk-l59-u 99306 45  1 30.0 30.0 #:hp 45.0  #:en 0.0 #:en-max 0.0))
  (define l59-a-tnk   (mk-l59-u 99307 33  1 31.0 30.0 #:hp 80.0  #:hp-max 175.0 #:en 0.0 #:en-max 0.0))
  (define l59-a-ovi   (mk-l59-u 99308 106 1 32.0 30.0 #:hp 200.0 #:fly #t))
  (define l59-a-gw    (mk-l59-u 99309 62  1 34.0 30.0 #:hp 500.0 #:sh 500.0 #:rad 1.5))
  (define l59-a-hyd   (mk-l59-u 99310 107 1 36.0 30.0 #:hp 90.0  #:en 0.0 #:en-max 0.0))
  (define l59-a-drn   (mk-l59-u 99311 104 1 28.0 34.0 #:hp 40.0  #:en 0.0 #:en-max 0.0))
  (define l59-a-hat   (mk-l59-u 99312 86  1 26.0 34.0 #:hp 1500.0 #:rad 2.75))
  (define l59-a-btl   (mk-l59-u 99313 37  1 38.0 30.0 #:hp 400.0 #:rad 1.0))
  (define l59-a-ftl   (mk-l59-u 99314 39  1 40.0 30.0 #:hp 400.0 #:rad 1.0))
  (define l59-a-cyb   (mk-l59-u 99315 72  1 42.0 30.0 #:hp 550.0 #:sh 550.0 #:rad 1.5))
  (define l59-a-ta    (mk-l59-u 99316 68  1 44.0 30.0 #:hp 500.0 #:sh 500.0 #:rad 1.5))
  (define l59-a-rch1  (mk-l59-u 99317 110 1 46.0 30.0 #:hp 145.0 #:en 0.0 #:en-max 0.0))
  (define l59-a-rch2  (mk-l59-u 99318 110 1 48.0 30.0 #:hp 145.0 #:en 0.0 #:en-max 0.0 #:burr #t))
  (define l59-a-med   (mk-l59-u 99319 54  1 30.0 32.0 #:hp 150.0 #:fly #t #:cmax 8))
  (define l59-a-mar   (mk-l59-u 99320 48  1 30.5 32.0 #:hp 45.0  #:en 0.0 #:en-max 0.0))
  (define l59-a-ezlt  (mk-l59-u 99329 73  4 60.0 54.0 #:hp 100.0 #:sh 50.0 #:en 0.0 #:en-max 0.0))
  (define l59-alias-cmds
    (translate-bot-actions->sc2-raw-commands
     '((cast-spell 99301 nuke-calldown 60.0 54.0)
       (cast-spell 99302 tac-nuke-strike 61.0 54.0)
       (cast-spell 99303 forcefield 58.0 52.0)
       (cast-spell 99304 revelation 60.0 54.0)
       (cast-spell 99306 effect-repair 99307)
       (morph 99308 dropperlord)
       (morph 99309 warpgate)
       (morph 99310 lurker-mp)
       (build lurker-den-mp 28.0 38.0)
       (research combat-shields)
       (research lock-on-range)
       (research hallucination)
       (research psistorm-tech)
       (burrow 99317)
       (unburrow 99318)
       (oracle-stasis-ward 99305 59.0 51.0)
       (load-transport 99319 99320))
     (make-test-obs 9400 2000 1000
                    (list l59-a-gh1 l59-a-gh2 l59-a-sen l59-a-ora1 l59-a-ora2
                          l59-a-scv l59-a-tnk l59-a-ovi l59-a-gw l59-a-hyd
                          l59-a-drn l59-a-hat l59-a-btl l59-a-ftl l59-a-cyb
                          l59-a-ta l59-a-rch1 l59-a-rch2 l59-a-med l59-a-mar l59-a-ezlt))))
  (define l59-alias-ab-ids
    (for/list ([c (in-list l59-alias-cmds)] #:when (sc2-raw-unit-command? c))
      (sc2-raw-unit-command-ability-id c)))
  (define l59-encoded-ok?
    (for/and ([c (in-list l59-alias-cmds)])
      (define bs (encode-sc2-action c))
      (and (bytes? bs) (> (bytes-length bs) 0))))
  ;; Clean rewind reset
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 100 (list l59-neut-min))))
  (check-true "l59-w1-all-11-aliases-and-standalone-heads-e2e-zero-rejects-zero-drops"
              (and (= (get-total-bot-action-reject-count) rej0)
                   (= (get-total-wire-action-drop-count) drop0)
                   l59-encoded-ok?
                   (memv 1622 l59-alias-ab-ids) ;; nuke-calldown / tac-nuke-strike
                   (memv 1526 l59-alias-ab-ids) ;; forcefield
                   (memv 2146 l59-alias-ab-ids) ;; revelation
                   (or (memv 316 l59-alias-ab-ids) (memv 3685 l59-alias-ab-ids)) ;; effect-repair
                   (memv 2708 l59-alias-ab-ids) ;; dropperlord
                   (memv 1518 l59-alias-ab-ids) ;; warpgate
                   (memv 2332 l59-alias-ab-ids) ;; lurker-mp
                   (memv 1163 l59-alias-ab-ids) ;; lurker-den-mp
                   (memv 731  l59-alias-ab-ids) ;; combat-shields
                   (memv 765  l59-alias-ab-ids) ;; lock-on-range
                   (memv 1571 l59-alias-ab-ids) ;; hallucination
                   (memv 1126 l59-alias-ab-ids) ;; psistorm-tech
                   (memv 3661 l59-alias-ab-ids) ;; burrow
                   (memv 3662 l59-alias-ab-ids) ;; unburrow
                   (memv 2505 l59-alias-ab-ids) ;; oracle-stasis-ward
                   (memv 3668 l59-alias-ab-ids))) ;; load-transport

  ;; ===========================================================================
  ;; Loop 59 Pass 2 (`L59-P2`, `#1533`): nc-09/nc-10 Destructible Rocks,
  ;; nc-07/nc-08 Thin Mineral Wall Persistence, n17 WarpGate CD / Rej-21 Lock,
  ;; h06 Scan vs MULE + Uphill Siege Reserve, & Live Div-5 Nuke Alert/Points!
  ;; ===========================================================================
  (printf "[Loop 59 Pass 2] Testing L59-P2 neutral rock attacks, thin mineral wall persistence, WarpGate rej-21 hard-lock, Scan-vs-MULE uphill reserve, & live nuke-alert/nuke-points...\n")

  ;; 8. `nc-09` & `nc-10`: Unit-targeted `(attack-unit ...)` / `(focus-fire ...)` on visible
  ;;    neutral Destructible Rock (367) & Collapsible Rock Tower (588) emits unit-targeted `23`!
  ;;    Air-only Phoenix (78) cannot target ground rocks; Minerals (341) & Watchtowers (149) stay non-attackable!
  (define p2-mar1 (mk-l59-u 99401 48  1 70.0 70.0 #:hp 45.0 #:en 0.0 #:en-max 0.0))
  (define p2-mar2 (mk-l59-u 99402 48  1 71.0 70.0 #:hp 45.0 #:en 0.0 #:en-max 0.0))
  (define p2-mdr1 (mk-l59-u 99403 51  1 72.0 70.0 #:hp 125.0 #:en 0.0 #:en-max 0.0))
  (define p2-phx1 (mk-l59-u 99404 78  1 73.0 70.0 #:hp 120.0 #:sh 60.0 #:fly #t))
  (define p2-rock (mk-l59-u 99410 367 3 75.0 70.0 #:hp 2000.0 #:hp-max 2000.0))
  (define p2-ctwr (mk-l59-u 99411 588 3 76.0 72.0 #:hp 500.0  #:hp-max 500.0))
  (define p2-xnt  (mk-l59-u 99412 149 3 78.0 72.0 #:hp 1000.0 #:hp-max 1000.0))
  (define p2-min  (mk-l59-u 99413 341 3 66.0 70.0 #:hp 1000.0 #:hp-max 1000.0 #:mins 1500))
  (define p2-rock-cmds
    (translate-bot-actions->sc2-raw-commands
     '((attack-unit (99401 99402 99404) 99410)
       (focus-fire 99403 99411)
       (attack-unit 99401 99412))
     (make-test-obs 9500 200 100 (list p2-mar1 p2-mar2 p2-mdr1 p2-phx1 p2-rock p2-ctwr p2-xnt p2-min))))
  (check-true "l59-p2-nc09-nc10-attack-unit-targets-visible-destructible-rock-and-collapsible-tower"
              (and (ormap (lambda (c)
                            (and (sc2-raw-unit-command? c)
                                 (= (sc2-raw-unit-command-ability-id c) 23)
                                 (= (sc2-raw-unit-command-target-unit-tag c) 99410)
                                 (equal? (sort (sc2-raw-unit-command-unit-tags c) <) '(99401 99402))))
                          p2-rock-cmds)
                   (ormap (lambda (c)
                            (and (sc2-raw-unit-command? c)
                                 (= (sc2-raw-unit-command-ability-id c) 23)
                                 (= (sc2-raw-unit-command-target-unit-tag c) 99411)
                                 (equal? (sc2-raw-unit-command-unit-tags c) '(99403))))
                          p2-rock-cmds)
                   (not (ormap (lambda (c)
                                 (and (sc2-raw-unit-command? c)
                                      (= (sc2-raw-unit-command-target-unit-tag c) 99412)))
                               p2-rock-cmds))
                   (not (ormap (lambda (c)
                                 (and (sc2-raw-unit-command? c)
                                      (memv 99404 (sc2-raw-unit-command-unit-tags c))))
                               p2-rock-cmds))))

  ;; 9. `nc-07` & `nc-08`: Thin mineral wall (`<= 150M`) harvest persistence:
  ;;    (a) Worker mining normal mineral (`1500M`) CAN switch to nearby thin wall (`5M`, dist < 14t),
  ;;    (b) Worker ALREADY harvesting thin wall (`5M`) does NOT get re-issued `3666` AND is added
  ;;        to `commanded-workers`, AND `saturate-workers-and-gas-commands` NEVER pulls it off!
  (define p2-nx-w   (mk-l59-u 99420 59 1 28.0 28.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75))
  (define p2-m-norm (mk-l59-u 99421 341 3 23.0 28.0 #:hp 1000.0 #:mins 1500))
  (define p2-m-wall (mk-l59-u 99422 1996 3 34.0 28.0 #:hp 1000.0 #:mins 5))
  (define p2-prb-norm
    (mk-l59-u 99423 84 1 25.0 28.0 #:hp 20.0 #:sh 20.0 #:en 0.0 #:en-max 0.0
              #:orders (list (sc2-unit-order 295 #f 99421 0.0))))
  (define p2-prb-exc
    (mk-l59-u 99424 84 1 33.0 28.0 #:hp 20.0 #:sh 20.0 #:en 0.0 #:en-max 0.0
              #:orders (list (sc2-unit-order 295 #f 99422 0.0))))
  (define p2-wall-obs
    (make-test-obs 9520 200 100 (list p2-nx-w p2-m-norm p2-m-wall p2-prb-norm p2-prb-exc)))
  (define p2-cmd-workers (mutable-seteqv))
  (define p2-wall-cmds
    (translate-bot-actions->sc2-raw-commands
     '((harvest-mineral (99423 99424) 99422))
     p2-wall-obs #:commanded-workers p2-cmd-workers))
  (define p2-sat-cmds
    (saturate-workers-and-gas-commands p2-wall-obs)) ;; even WITHOUT excluded-worker-tags!
  (check-true "l59-p2-nc07-nc08-thin-mineral-wall-harvest-switch-and-persistence"
              (and (ormap (lambda (c)
                            (and (sc2-raw-unit-command? c)
                                 (= (sc2-raw-unit-command-ability-id c) 3666)
                                 (= (sc2-raw-unit-command-target-unit-tag c) 99422)
                                 (equal? (sc2-raw-unit-command-unit-tags c) '(99423))))
                          p2-wall-cmds)
                   (not (ormap (lambda (c)
                                 (and (sc2-raw-unit-command? c)
                                      (memv 99424 (sc2-raw-unit-command-unit-tags c))))
                               p2-wall-cmds))
                   (set-member? p2-cmd-workers 99424)
                   (not (ormap (lambda (c)
                                 (and (sc2-raw-unit-command? c)
                                      (memv 99424 (sc2-raw-unit-command-unit-tags c))))
                               p2-sat-cmds))))

  ;; 10. `sc2-trn-n17`: WarpGate `627` Zealot CD, stale `warp_gate_count` guard (`< 32f`),
  ;;     `21:NotEnoughCharges` hard-lock (vs `47` placement unlock), & `'warp-in-dark-templar -> 1417`!
  (define p2-wg1 (mk-l59-u 99431 133 1 32.0 34.0 #:hp 500.0 #:sh 500.0 #:rad 1.5))
  (define p2-wg2 (mk-l59-u 99432 133 1 36.0 34.0 #:hp 500.0 #:sh 500.0 #:rad 1.5))
  (define p2-wpp (mk-l59-u 99433 136 1 100.0 100.0 #:hp 80.0 #:sh 100.0 #:fly #t))
  (define p2-ps  (list (sc2-power-source (sc2-point3d 100.0 100.0 8.0) 3.75 99433)))
  (define (mk-p2-wg-obs gl wgc errs)
    (sc2-observation gl (sc2-player-common 1 800 400 80 40 20 20 0 0 wgc 0)
                     (list p2-nx-w p2-wg1 p2-wg2 p2-wpp) '(84) p2-ps #f '() '() '() errs '() '()))
  ;; Step 1 (loop 9600): Warp 1 Zealot on wg1 + 1 `'warp-in-dark-templar` on wg2
  (define p2-wg-c1
    (translate-bot-actions->sc2-raw-commands
     '((warp-in 99431 zealot 100.0 100.0)
       (train-unit 99432 warp-in-dark-templar 100.0 100.0))
     (mk-p2-wg-obs 9600 2 '())))
  ;; Step 2 (loop 9604, +4f < 32f): Even if SC2 still reports stale `warp_gate_count = 2`, BOTH stay locked!
  (define p2-wg-c2
    (translate-bot-actions->sc2-raw-commands
     '((warp-in 99431 zealot 100.0 100.0))
     (mk-p2-wg-obs 9604 2 '())))
  ;; Step 3 (loop 9640): SC2 reports `res = 21 (NotEnoughCharges)` on wg1 with stale `warp_gate_count = 2` -> HARD-LOCKED!
  (define p2-wg-c3
    (translate-bot-actions->sc2-raw-commands
     '((warp-in 99431 zealot 100.0 100.0))
     (mk-p2-wg-obs 9640 2 (list (hash 'unit-tag 99431 'ability-id 1413 'result 21)))))
  ;; Step 4 (loop 9644): SC2 reports `res = 47` (placement miss) on wg2 -> STILL unlocks wg2 immediately!
  (define p2-wg-c4
    (translate-bot-actions->sc2-raw-commands
     '((warp-in 99432 dark-templar 100.0 100.0))
     (mk-p2-wg-obs 9644 2 (list (hash 'unit-tag 99432 'ability-id 1417 'result 47)))))
  (check-true "l59-p2-n17-warpgate-cd-627-stale-wgc-guard-rej21-hard-lock-and-warp-in-dt-1417"
              (and (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1413))) p2-wg-c1)
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1417))) p2-wg-c1)
                   (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1413))) p2-wg-c2))
                   (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1413))) p2-wg-c3))
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1417))) p2-wg-c4)))

  ;; 11. `sc2-rmp-h06`: Scan (399) beats same-step MULE (171) AND uphill Tank siege preserves Scan energy!
  (define p2-oc-100 (mk-l59-u 99441 132 1 30.0 30.0 #:hp 1500.0 #:en 100.0 #:rad 2.75))
  (define p2-oc-155 (mk-l59-u 99441 132 1 30.0 30.0 #:hp 1500.0 #:en 155.0 #:rad 2.75))
  (define p2-tk1    (mk-l59-u 99442 32  1 76.0 90.0 #:hp 175.0 #:en 0.0 #:en-max 0.0))
  (define p2-stk-hg
    (sc2-unit 1 4 99449 74 2 (sc2-point3d 80.0 96.0 10.0) 0.0 0.625 1.0 0 #f #t #f
              80.0 80.0 80.0 80.0 0.0 0.0 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0 '() 0 0))
  (define p2-h06-min (mk-l59-u 99448 341 3 24.0 30.0 #:hp 1000.0 #:mins 1500))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  ;; (a) Same-step MULE listed BEFORE Scan -> Scan wins, MULE stripped!
  (define p2-scan-vs-mule-cmds
    (translate-bot-actions->sc2-raw-commands
     '((cast-spell 99441 calldown-mule 99448)
       (cast-spell 99441 scanner-sweep 80.0 96.0))
     (make-test-obs 9700 200 100 (list p2-oc-100 p2-h06-min))))
  ;; (b) Auto-MULE at loop 9760 (past 24f cooldown) under uphill Tank siege (dz = +2.0, 0 air spotters):
  ;;     100e OC holds Scan (0 MULEs), while 155e OC STILL drops MULE cleanly!
  (define p2-sat-uphill-100
    (saturate-workers-and-gas-commands
     (make-test-obs 9760 200 100 (list p2-oc-100 p2-tk1 p2-stk-hg p2-h06-min))))
  (define p2-sat-uphill-155
    (saturate-workers-and-gas-commands
     (make-test-obs 9764 200 100 (list p2-oc-155 p2-tk1 p2-stk-hg p2-h06-min))))
  (check-true "l59-p2-h06-scan-399-beats-mule-171-and-uphill-siege-preserves-scan-energy"
              (and (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 399))) p2-scan-vs-mule-cmds)
                   (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 171))) p2-scan-vs-mule-cmds))
                   (not (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 171))) p2-sat-uphill-100))
                   (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 171))) p2-sat-uphill-155)))

  ;; 12. Live Div-5 Bug #1 (`#1531`): `'nuke-alert` & `'nuke-points` populated from EffectId=7
  ;;     (`NukePersistent`) AND `Alert.NuclearLaunchDetected (1)`!
  (define p2-obs-nuke-eff
    (sc2-observation 9800 (sc2-player-common 1 200 100 40 20 10 10 0 0 0 0)
                     (list l59-cc-m) '() '() #f '()
                     (list (sc2-effect 7 (list (sc2-point2d 88.5 42.0)) 4 2 8.0))
                     '() '() '() '()))
  (define p2-obs-nuke-alert
    (sc2-observation 9804 (sc2-player-common 1 200 100 40 20 10 10 0 0 0 0)
                     (list l59-cc-m) '() '() #f '() '() '() '() '() '(1)))
  (define p2-obs-no-nuke
    (make-test-obs 9808 200 100 (list l59-cc-m)))
  (define p2-nh-eff   (sc2-observation->runtime-obs-hash p2-obs-nuke-eff))
  (define p2-nh-alert (sc2-observation->runtime-obs-hash p2-obs-nuke-alert))
  (define p2-nh-clean (sc2-observation->runtime-obs-hash p2-obs-no-nuke))
  ;; Clean rewind reset
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 100 (list l59-neut-min))))
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 100 (list l59-neut-min))))
  (check-true "l59-p2-div5-nuke-alert-and-nuke-points-from-effect7-and-alert1"
              (and (eq? (hash-ref p2-nh-eff 'nuke-alert #f) #t)
                   (equal? (hash-ref p2-nh-eff 'nuke-points '()) '((88.5 . 42.0)))
                   (eq? (hash-ref p2-nh-alert 'nuke-alert #f) #t)
                   (null? (hash-ref p2-nh-alert 'nuke-points '()))
                   (eq? (hash-ref p2-nh-clean 'nuke-alert #t) #f)
                   (null? (hash-ref p2-nh-clean 'nuke-points '(bad)))))

  ;; ===========================================================================
  ;; Loop 59 Pass 3 (`L59-P3`, `#1553` Fix #1B & #2B):
  ;;   13. Early Terran pre-Starport Marines/Reapers near a ramp NEVER hit 150e MULE blackout,
  ;;       while Sieged Tank + uphill enemy (<=15t, dz>=1.5, 0 air spotters <=16t) OR 83 err (44f)
  ;;       reserves Scan cleanly!
  ;;   14. UnbuildablePlatesDestructible (474) / UnbuildableBricksDestructible (473) excluded from
  ;;       `'neutral-units` AND `live-visible-neutral-attackable-tags` (keeping real rocks 367/588)!
  ;; ===========================================================================
  (printf "[Loop 59 Pass 3] Testing L59-P3 early Terran MULE non-blackout + UnbuildablePlates/Bricks exclusion...\n")
  (define p3-oc-105 (mk-l59-u 99501 132 1 30.0 30.0 #:hp 1500.0 #:en 105.0 #:rad 2.75))
  (define p3-scv1   (mk-l59-u 99502 45  1 26.0 30.0 #:hp 45.0 #:en 0.0 #:en-max 0.0))
  (define p3-min1   (mk-l59-u 99503 341 3 24.0 30.0 #:hp 1000.0 #:mins 1500))
  (define p3-mars6  (for/list ([i (in-range 6)])
                      (mk-l59-u (+ 99510 i) 48 1 (+ 74.0 (* 0.5 i)) 90.0 #:hp 45.0 #:en 0.0 #:en-max 0.0)))
  (define p3-tk1    (mk-l59-u 99520 32  1 76.0 90.0 #:hp 175.0 #:en 0.0 #:en-max 0.0))
  (define p3-med1   (mk-l59-u 99521 54  1 78.0 92.0 #:hp 150.0 #:en 100.0 #:fly #t))
  (define p3-ehg
    (sc2-unit 1 4 99529 74 2 (sc2-point3d 80.0 96.0 10.0) 0.0 0.625 1.0 0 #f #t #f
              80.0 80.0 80.0 80.0 0.0 0.0 0 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0 '() 0 0))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  ;; (a) 6 Marines + SCV facing uphill Stalker (0 Tanks, 0 err-83, 0 air spotters) -> MULE FIRES at 105e!
  (define p3-sat-bio-ok
    (saturate-workers-and-gas-commands
     (make-test-obs 5000 200 100 (append (list p3-oc-105 p3-scv1 p3-min1 p3-ehg) p3-mars6))))
  ;; (b) Same check via explicit Case C `(cast-spell oc calldown-mule min)` at +30f -> MULE FIRES at 105e!
  (define p3-casec-bio-ok
    (translate-bot-actions->sc2-raw-commands
     '((cast-spell 99501 calldown-mule 99503))
     (make-test-obs 5030 200 100 (append (list p3-oc-105 p3-scv1 p3-min1 p3-ehg) p3-mars6))))
  ;; (c) Sieged Tank + uphill Stalker WITH Medivac spotter <= 16t -> MULE FIRES at 105e!
  (define p3-sat-tank-spotted-ok
    (saturate-workers-and-gas-commands
     (make-test-obs 5060 200 100 (list p3-oc-105 p3-scv1 p3-min1 p3-tk1 p3-med1 p3-ehg))))
  ;; (d) 83:MustTargetVisibleUnit error -> blocks MULE at 105e for 44f, then resumes at +48f!
  (define p3-obs-err83
    (sc2-observation 5100 (sc2-player-common 1 200 100 40 20 10 10 0 0 0 0)
                     (append (list p3-oc-105 p3-scv1 p3-min1 p3-ehg) p3-mars6)
                     '() '() #f '() '() '()
                     (list (hash 'unit-tag 99510 'ability-id 23 'result 83))
                     '() '()))
  (define p3-sat-err83-block (saturate-workers-and-gas-commands p3-obs-err83))
  (define p3-sat-err83-still (saturate-workers-and-gas-commands
                              (make-test-obs 5130 200 100 (append (list p3-oc-105 p3-scv1 p3-min1 p3-ehg) p3-mars6))))
  (define p3-sat-err83-clear (saturate-workers-and-gas-commands
                              (make-test-obs 5148 200 100 (append (list p3-oc-105 p3-scv1 p3-min1 p3-ehg) p3-mars6))))
  (define (has-mule-171? cs)
    (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 171))) cs))
  (check-true "l59-p3-fix1b-early-marines-never-blackout-mule-while-err83-44f-and-unspotted-tank-reserve-scan"
              (and (has-mule-171? p3-sat-bio-ok)
                   (has-mule-171? p3-casec-bio-ok)
                   (has-mule-171? p3-sat-tank-spotted-ok)
                   (not (has-mule-171? p3-sat-err83-block))
                   (not (has-mule-171? p3-sat-err83-still))
                   (has-mule-171? p3-sat-err83-clear)))

  ;; 14. Fix #2B: UnbuildablePlatesDestructible (474) / UnbuildableBricksDestructible (473) excluded!
  (define p3-plate (mk-l59-u 99541 474 3 36.0 30.0 #:hp 2000.0 #:hp-max 2000.0))
  (define p3-brick (mk-l59-u 99542 473 3 38.0 30.0 #:hp 2000.0 #:hp-max 2000.0))
  (define p3-rock  (mk-l59-u 99543 367 3 75.0 70.0 #:hp 2000.0 #:hp-max 2000.0))
  (define p3-obs-plates
    (make-test-obs 5200 200 100 (list p3-oc-105 (first p3-mars6) p3-plate p3-brick p3-rock)))
  (define p3-oh-plates (sc2-observation->runtime-obs-hash p3-obs-plates))
  (define p3-neut-ids (map (lambda (h) (hash-ref h 'id 0)) (hash-ref p3-oh-plates 'neutral-units '())))
  (define p3-plate-atk-cmds
    (translate-bot-actions->sc2-raw-commands
     '((attack-unit 99510 99541)
       (attack-unit 99510 99542))
     p3-obs-plates))
  ;; Clean rewind reset
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 100 (list l59-neut-min))))
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 100 (list l59-neut-min))))
  (check-true "l59-p3-fix2b-unbuildable-plates-and-bricks-excluded-from-neutral-units-and-attackable-tags"
              (and (memv 99543 p3-neut-ids)
                   (not (memv 99541 p3-neut-ids))
                   (not (memv 99542 p3-neut-ids))
                   (not (ormap (lambda (c)
                                 (and (sc2-raw-unit-command? c)
                                      (memv (sc2-raw-unit-command-target-unit-tag c) '(99541 99542))))
                               p3-plate-atk-cmds))))

  ;; ===========================================================================
  ;; Loop 59 APM-Cap Drop Telemetry (`L59-APM-LOG`, `#1562`):
  ;;   15. Exact per-governor APM-cap drop counters (`total`, `token_bucket`, `rolling_hard_cap`,
  ;;       `by_tier` P0..P4, `by_ability` incl. `"camera"`, `by_minute`), strictly excluding
  ;;       dedup/cooldown drops, `#:top-k` cap, `jsexpr?` validity, explicit reset & rewind reset!
  ;; ===========================================================================
  (printf "[Loop 59 APM-Log] Testing #1562 per-governor APM-cap drop stats (token_bucket / rolling_hard_cap / P0..P4 / by_ability / by_minute / rewind)...\n")
  ;; (a) Zero drops on normal batch + dedup/cooldown drops MUST NOT count as APM-cap drops!
  (define apm-gov-clean (make-wire-apm-governor #:target-apm 495.0 #:hard-cap-apm 595.0))
  (void (govern-sc2-wire-actions!
         apm-gov-clean
         (list (sc2-raw-unit-command 388 #f 0 '(99601) #f)
               (mark-urgent-survival-cmd! (sc2-raw-unit-command 23 (sc2-point2d 50.0 50.0) 0 '(99602) #f))
               (sc2-raw-camera-move 40.0 40.0 0.0))
         1000))
  ;; Repeat identical mode-switch `388` (+4f < 10f dedup), identical urgent `23` (+4f < 8f dedup),
  ;; and camera move (+4f < 28f cooldown) -> ALL blocked by dedup/cooldown, 0 APM-cap drops!
  (void (govern-sc2-wire-actions!
         apm-gov-clean
         (list (sc2-raw-unit-command 388 #f 0 '(99601) #f)
               (mark-urgent-survival-cmd! (sc2-raw-unit-command 23 (sc2-point2d 50.0 50.0) 0 '(99602) #f))
               (sc2-raw-camera-move 90.0 90.0 0.0))
         1004))
  (define st-clean (get-wire-apm-drop-stats apm-gov-clean))

  ;; (b) Token-bucket drops (high hard-cap 500, low target 200 -> tokens=24.0, burst=28.0) at minute 1 (loop 1500).
  ;;     Warm up `last-cam-loop` (loop 1470: +30f passes 28f cooldown, skips 44f overdue P4 rescue) and
  ;;     `LAST-P2-LOOP`/`LAST-P3-LOOP` (loop 1496: +4f skips 12f/24f overdue rescues) -> 0 warmup drops!
  (define apm-gov-tok (make-wire-apm-governor #:target-apm 200.0 #:hard-cap-apm 500.0))
  (void (govern-sc2-wire-actions! apm-gov-tok (list (sc2-raw-camera-move 30.0 30.0 0.0)) 1470))
  (void (govern-sc2-wire-actions!
         apm-gov-tok
         (list (sc2-raw-unit-command 23 (sc2-point2d 55.0 55.0) 0 '(99608) #f)
               (sc2-raw-unit-command 3666 #f 99698 '(99609) #f))
         1496))
  (define st-tok-warmup (get-wire-apm-drop-stats apm-gov-tok))
  (define tok-batch
    (append
     (for/list ([i (in-range 14)])
       (sc2-raw-unit-command 23 (sc2-point2d (+ 60.0 i) 60.0) 0 (list (+ 99610 i)) #f))
     (list (sc2-raw-unit-command 3666 #f 99699 '(99650) #f)
           (sc2-raw-unit-command 3666 #f 99697 '(99651) #f)
           (sc2-raw-camera-move 80.0 80.0 0.0))))
  (define tok-emitted (govern-sc2-wire-actions! apm-gov-tok tok-batch 1500))
  (define st-tok (get-wire-apm-drop-stats apm-gov-tok))
  (define st-tok-tier (hash-ref st-tok 'by_tier))
  (define st-tok-ab   (hash-ref st-tok 'by_ability))
  (define st-tok-min  (hash-ref st-tok 'by_minute))
  (define st-tok-top2 (get-wire-apm-drop-stats apm-gov-tok #:top-k 2))

  ;; (c) Rolling hard-cap drops (high target 495 -> plentiful tokens, hard-cap 12.0 minus 2.0 warmup = 10.0)
  ;;     at minute 3 (loop 4100). Warm up `LAST-P1-LOOP` at loop 4096 (+4f < 8f -> skips overdue P1-before-P0).
  (define apm-gov-cap (make-wire-apm-governor #:target-apm 495.0 #:hard-cap-apm 12.0))
  (void (govern-sc2-wire-actions! apm-gov-cap (list (sc2-raw-unit-command 171 #f 99798 '(99700) #f)) 4096))
  (define cap-batch
    (list (sc2-raw-unit-command 399 (sc2-point2d 80.0 80.0) 0 '(99701) #f)
          (sc2-raw-unit-command 399 (sc2-point2d 90.0 90.0) 0 '(99702) #f)
          (sc2-raw-unit-command 399 (sc2-point2d 100.0 100.0) 0 '(99703) #f)
          (sc2-raw-unit-command 399 (sc2-point2d 110.0 110.0) 0 '(99704) #f)
          (sc2-raw-unit-command 399 (sc2-point2d 120.0 120.0) 0 '(99705) #f)
          (sc2-raw-unit-command 399 (sc2-point2d 130.0 130.0) 0 '(99706) #f) ;; P0 6th cmd hits hard-cap 10!
          (sc2-raw-unit-command 171 #f 99799 '(99710) #f)                     ;; P1 MULE hits hard-cap!
          (sc2-raw-unit-command 16 (sc2-point2d 70.0 70.0) 0 '(99711) #f)))   ;; P2 Move hits hard-cap!
  (void (govern-sc2-wire-actions! apm-gov-cap cap-batch 4100))
  (define st-cap (get-wire-apm-drop-stats apm-gov-cap))
  (define st-cap-tier (hash-ref st-cap 'by_tier))
  (define st-cap-ab   (hash-ref st-cap 'by_ability))
  (define st-cap-min  (hash-ref st-cap 'by_minute))

  ;; (d) Rewind reset clears stats automatically AND explicit `reset-wire-apm-drop-stats!` clears stats!
  (void (govern-sc2-wire-actions! apm-gov-cap '() 100)) ;; rewind 4100 -> 100!
  (define st-cap-rewound (get-wire-apm-drop-stats apm-gov-cap))
  (reset-wire-apm-drop-stats! apm-gov-tok)
  (define st-tok-reset (get-wire-apm-drop-stats apm-gov-tok))

  (check-true "l59-apm-log-exact-token-cap-tier-ability-minute-exclusion-and-reset"
              (and (= (hash-ref st-clean 'total -1) 0)
                   (= (hash-ref st-tok-warmup 'total -1) 0)
                   (jsexpr? st-tok)
                   (jsexpr? st-cap)
                   (= (hash-ref st-tok 'total 0) 8)
                   (= (hash-ref st-tok 'total 0) (- (length tok-batch) (length tok-emitted)))
                   (= (hash-ref st-tok 'token_bucket 0) 8)
                   (= (hash-ref st-tok 'rolling_hard_cap 0) 0)
                   (= (hash-ref st-tok-tier 'P2 0) 5)
                   (= (hash-ref st-tok-tier 'P3 0) 2)
                   (= (hash-ref st-tok-tier 'P4 0) 1)
                   (= (+ (hash-ref st-tok-tier 'P0 0) (hash-ref st-tok-tier 'P1 0)
                         (hash-ref st-tok-tier 'P2 0) (hash-ref st-tok-tier 'P3 0)
                         (hash-ref st-tok-tier 'P4 0))
                      (hash-ref st-tok 'total 0))
                   (= (hash-ref st-tok-ab '|23| 0) 5)
                   (= (hash-ref st-tok-ab '|3666| 0) 2)
                   (= (hash-ref st-tok-ab 'camera 0) 1)
                   (= (hash-ref st-tok-min '|1| 0) 8)
                   (= (hash-count (hash-ref st-tok-top2 'by_ability)) 2)
                   (= (hash-ref st-cap 'total 0) 3)
                   (= (hash-ref st-cap 'rolling_hard_cap 0) 3)
                   (= (hash-ref st-cap 'token_bucket 0) 0)
                   (= (hash-ref st-cap-tier 'P0 0) 1)
                   (= (hash-ref st-cap-tier 'P1 0) 1)
                   (= (hash-ref st-cap-tier 'P2 0) 1)
                   (= (hash-ref st-cap-ab '|399| 0) 1)
                   (= (hash-ref st-cap-ab '|171| 0) 1)
                   (= (hash-ref st-cap-ab '|16| 0) 1)
                   (= (hash-ref st-cap-min '|3| 0) 3)
                   (= (hash-ref st-cap-rewound 'total -1) 0)
                   (= (hash-ref st-tok-reset 'total -1) 0)))

  ;; ===========================================================================
  ;; Loop 59C H2H Fix #3 (`L59C-MULE`, `#1565`/`#1566`):
  ;;   16. Unprovoked live TvT (2 OCs, >= 6 Marines, SCVs+Barracks, 0 Banshee/Ghost/Starport-TL)
  ;;       and unprovoked live TvZ (even with enemy CreepTumorBurrowed 137 visible!) MULE freely
  ;;       at 50e across BOTH `saturate-workers-and-gas-commands` AND `Case C (171)`; TvP >= 4:00
  ;;       holds ONLY 1 OC until >= 3 OCs; AND isolated Arena `sc2-ab-t10` (6 SCVs, 12 Marines,
  ;;       0 Barracks/Depots, 1 OC @ 100e) STILL reserves 101e Scan bank 100% intact!
  ;; ===========================================================================
  (printf "[Loop 59C MULE] Testing #1566 unprovoked TvT/TvZ 50e MULE, TvP 1-OC@4:00 / 2-OC@3-OC, CreepTumor non-latch, & sc2-ab-t10 101e preservation...\n")
  (define (mk-l59c-gi erace)
    (sc2-game-info "L59CTestMap" ""
                   (list (hash 'player-id 1 'race-requested 'Terran)
                         (hash 'player-id 2 'race-requested erace))
                   '(128 128) '(4 4 124 124) (list (sc2-point2d 100.0 100.0))
                   #f #f #f))
  (define l59c-gi-t (mk-l59c-gi 'Terran))
  (define l59c-gi-p (mk-l59c-gi 'Protoss))
  (define l59c-gi-z (mk-l59c-gi 'Zerg))
  (define (l59c-mule-tags cs)
    (for/list ([c (in-list cs)]
               #:when (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 171)))
      (car (sc2-raw-unit-command-unit-tags c))))
  (define l59c-oc1-65  (mk-l59-u 99801 132 1 30.0 30.0 #:hp 1500.0 #:en 65.0 #:rad 2.75))
  (define l59c-oc2-55  (mk-l59-u 99802 132 1 56.0 30.0 #:hp 1500.0 #:en 55.0 #:rad 2.75))
  (define l59c-oc1-100 (mk-l59-u 99801 132 1 30.0 30.0 #:hp 1500.0 #:en 100.0 #:rad 2.75))
  (define l59c-min1    (mk-l59-u 99808 341 3 25.0 30.0 #:hp 1800.0 #:en 0.0 #:en-max 0.0 #:mins 1500))
  (define l59c-min2    (mk-l59-u 99809 341 3 61.0 30.0 #:hp 1800.0 #:en 0.0 #:en-max 0.0 #:mins 1500))
  (define l59c-rax     (mk-l59-u 99810 21  1 38.0 34.0 #:hp 1000.0 #:en 0.0 #:en-max 0.0 #:rad 1.5))
  (define l59c-scvs12  (for/list ([i (in-range 12)])
                         (mk-l59-u (+ 99820 i) 45 1 (+ 27.0 (* 0.3 i)) 30.0 #:hp 45.0 #:en 0.0 #:en-max 0.0)))
  (define l59c-scvs6   (take l59c-scvs12 6))
  (define l59c-mars12  (for/list ([i (in-range 12)])
                         (mk-l59-u (+ 99840 i) 48 1 (+ 36.0 (* 0.4 i)) 30.0 #:hp 45.0 #:en 0.0 #:en-max 0.0)))
  (define l59c-mars6   (take l59c-mars12 6))
  (define l59c-etumor  (mk-l59-u 99860 137 4 70.0 70.0 #:hp 50.0 #:en 0.0 #:en-max 0.0 #:cloak 1 #:burr #t))
  (define l59c-elurk   (mk-l59-u 99861 504 4 95.0 95.0 #:hp 200.0 #:en 0.0 #:en-max 0.0 #:cloak 1 #:burr #t))
  ;; Clean rewind before live TvT check
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 100 (list l59c-min1)) #:game-info l59c-gi-t))
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 100 (list l59c-min1)) #:game-info l59c-gi-t))
  ;; (a) Live unprovoked TvT (`#002` at 225s = loop 5040): 2 OCs (65e & 55e) + 6 Marines + 12 SCVs + Barracks -> BOTH OCs MULE freely!
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define l59c-tvt-sat
    (l59c-mule-tags (saturate-workers-and-gas-commands
                     (make-test-obs 5040 200 100 (append (list l59c-oc1-65 l59c-oc2-55 l59c-rax l59c-min1 l59c-min2) l59c-scvs12 l59c-mars6))
                     #:game-info l59c-gi-t)))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define l59c-tvt-casec
    (l59c-mule-tags (translate-bot-actions->sc2-raw-commands
                     '((cast-spell 99801 calldown-mule 99808))
                     (make-test-obs 5080 200 100 (append (list l59c-oc1-65 l59c-oc2-55 l59c-rax l59c-min1 l59c-min2) l59c-scvs12 l59c-mars6))
                     #:game-info l59c-gi-t)))
  ;; (b) Live unprovoked TvZ WITH enemy CreepTumorBurrowed (137) visible: STILL MULEs freely at 55e/65e (tumor NEVER latches cloak)!
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define l59c-tvz-tumor-sat
    (l59c-mule-tags (saturate-workers-and-gas-commands
                     (make-test-obs 5600 200 100 (append (list l59c-oc1-65 l59c-oc2-55 l59c-rax l59c-min1 l59c-min2 l59c-etumor) l59c-scvs12 l59c-mars6))
                     #:game-info l59c-gi-z)))
  ;; (c) Live TvZ WITH enemy Burrowed Lurker (504) sighted -> holds Scan while visible (both OCs),
  ;;     and after Lurker leaves vision (`cloak_seen` latched, Loop 64 A5 `#1755`) top-2 OCs (99801/99802)
  ;;     hold 100e Scan while a 3rd OC (99803) still MULEs freely!
  (define l59c-oc3-55  (mk-l59-u 99803 132 1 36.0 34.0 #:hp 1500.0 #:en 55.0))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define l59c-tvz-lurker-vis
    (l59c-mule-tags (saturate-workers-and-gas-commands
                     (make-test-obs 5640 200 100 (append (list l59c-oc1-65 l59c-oc2-55 l59c-rax l59c-min1 l59c-min2 l59c-elurk) l59c-scvs12 l59c-mars6))
                     #:game-info l59c-gi-z)))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define l59c-tvz-lurker-latched
    (l59c-mule-tags (saturate-workers-and-gas-commands
                     (make-test-obs 5668 200 100 (append (list l59c-oc1-65 l59c-oc2-55 l59c-oc3-55 l59c-rax l59c-min1 l59c-min2) l59c-scvs12 l59c-mars6))
                     #:game-info l59c-gi-z)))
  ;; (d) Live TvP at 4:10 (loop 5680, after rewind clearing Lurker latch): 2 OCs -> ONLY top-1 OC (99801) holds Scan, OC #2 (99802) MULEs!
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 100 (list l59c-min1)) #:game-info l59c-gi-p))
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 100 (list l59c-min1)) #:game-info l59c-gi-p))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define l59c-tvp-2oc-sat
    (l59c-mule-tags (saturate-workers-and-gas-commands
                     (make-test-obs 5680 200 100 (append (list l59c-oc1-65 l59c-oc2-55 l59c-rax l59c-min1 l59c-min2) l59c-scvs12 l59c-mars6))
                     #:game-info l59c-gi-p)))
  ;; (e) Isolated Arena `sc2-ab-t10` exact unit composition (1 OC @ 100e + 6 SCVs + 12 Marines, 0 Barracks/Depots):
  ;;     STILL holds 101e Scan bank across BOTH `saturate` AND `Case C` even at loop 16!
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 50 0 (list l59c-min1)) #:game-info l59c-gi-p))
  (void (saturate-workers-and-gas-commands (make-test-obs 4 50 0 (list l59c-min1)) #:game-info l59c-gi-p))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define l59c-t10-obs
    (make-test-obs 16 50 0 (append (list l59c-oc1-100 l59c-min1) l59c-scvs6 l59c-mars12)))
  (define l59c-t10-sat   (l59c-mule-tags (saturate-workers-and-gas-commands l59c-t10-obs #:game-info l59c-gi-p)))
  (define l59c-t10-casec (l59c-mule-tags (translate-bot-actions->sc2-raw-commands '((cast-spell 99801 calldown-mule 99808)) l59c-t10-obs #:game-info l59c-gi-p)))
  ;; Final clean rewind
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 100 (list l59c-min1))))
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 100 (list l59c-min1))))
  (check-true "l59c-fix3-unprovoked-tvt-tvz-50e-mule-tvp-1oc-and-sc2-ab-t10-scan-bank-preserved"
              (and (equal? (sort l59c-tvt-sat <) '(99801 99802))
                   (equal? l59c-tvt-casec '(99801))
                   (equal? (sort l59c-tvz-tumor-sat <) '(99801 99802))
                   (null? l59c-tvz-lurker-vis)
                   (equal? l59c-tvz-lurker-latched '(99803))
                   (equal? l59c-tvp-2oc-sat '(99802))
                   (null? l59c-t10-sat)
                   (null? l59c-t10-casec)))

  ;; ===========================================================================
  ;; Loop 60 Wire Fixes (`L60-GOV-ANTIDT`, `#1580`/`#1582`):
  ;;   17. APM Governor P1 Purification & P0 Spell Protection (`3685` Repair P2 + coalesce +
  ;;       12f dedup; `3678` Land P2 + unchanged backoff; `framing-camera` P2; routine midgame
  ;;       `3666` P3; non-urgent P0 spell `-3.0` survives after urgent `23/16` capped at `-2.0`;
  ;;       `p2-large` stops at `0.0`; `target-apm = 530.0`) + Anti-DT 2-OC Scan on scouted
  ;;       WarpPrism / DarkShrine / DarkTemplar (`#74 TvP who`)!
  ;; ===========================================================================
  (printf "[Loop 60 Wire] Testing #1580 APM governor P1 purification, P0 spell protection, & Anti-DT 2-OC scan...\n")
  ;; (a) Tier purification: Repair 3685/316 -> P2, Land 3678 -> P2, framing-camera -> P2, queued 3666 -> P3,
  ;;     and coalesced midgame idle-worker 3666 (L61C `#1652`, 1 cmd/base) -> P1 (macro-econ-cmd?)!
  (define l60-rep-a (sc2-raw-unit-command 3685 #f 99901 '(99911) #f))
  (define l60-rep-b (sc2-raw-unit-command 3685 #f 99901 '(99912) #f))
  (define l60-land  (sc2-raw-unit-command 3678 (sc2-point2d 42.0 42.0) 0 '(99913) #f))
  (define l60-fcam  (mark-framing-camera-cmd! (sc2-raw-camera-move 60.0 60.0 0.0) 24.0))
  (define l60-q3666 (sc2-raw-unit-command 3666 #f 99808 '(99914) #t))
  (define l60-idle-late-scv (mk-l59-u 99915 45 1 28.0 30.0 #:hp 45.0 #:en 0.0 #:en-max 0.0))
  (define l60-idle-late-cmds
    (saturate-workers-and-gas-commands
     (make-test-obs 4000 200 100 (list l59c-oc1-65 l59c-min1 l60-idle-late-scv))
     #:game-info l59c-gi-t))
  (define l60-idle-late-3666
    (findf (lambda (c) (and (sc2-raw-unit-command? c)
                            (= (sc2-raw-unit-command-ability-id c) 3666)
                            (equal? (sc2-raw-unit-command-unit-tags c) '(99915))))
           l60-idle-late-cmds))
  ;; (b) Repair 3685 coalesces multi-SCV commands on same target AND dedupes identical repeat < 12f with 0 APM drops!
  (define l60-gov-rep (make-wire-apm-governor))
  (define l60-rep-out1 (govern-sc2-wire-actions! l60-gov-rep (list l60-rep-a l60-rep-b) 3000))
  (define l60-rep-out2 (govern-sc2-wire-actions! l60-gov-rep (list l60-rep-a l60-rep-b) 3008)) ;; +8f < 12f -> deduped!
  (define l60-rep-out3 (govern-sc2-wire-actions! l60-gov-rep (list l60-rep-a l60-rep-b) 3012)) ;; +12f >= 12f -> allowed!
  (define l60-rep-drops (hash-ref (get-wire-apm-drop-stats l60-gov-rep) 'total -1))
  ;; (c) Land 3678 gets unchanged-repeat backoff (`24f`) when flying Barracks remains unchanged in obs!
  (define l60-fly-rax (mk-l59-u 99913 46 1 42.0 42.0 #:hp 1000.0 #:en 0.0 #:en-max 0.0 #:fly #t))
  (define l60-gov-land (make-wire-apm-governor))
  (define l60-land-obs1 (make-test-obs 3100 200 100 (list l60-fly-rax)))
  (define l60-land-obs2 (make-test-obs 3108 200 100 (list l60-fly-rax)))
  (define l60-land-out1 (govern-sc2-wire-actions! l60-gov-land (list l60-land) 3100 l60-land-obs1))
  (define l60-land-out2 (govern-sc2-wire-actions! l60-gov-land (list l60-land) 3108 l60-land-obs2))
  ;; (d) P0 Spell Protection: urgent `23/16` caps overdraft at `-2.0` so non-urgent P0 spell `251` Inject (`-3.0`)
  ;;     STILL FIRES cleanly right after an urgent `23` burst!
  (define l60-gov-p0 (make-wire-apm-governor #:target-apm 200.0 #:hard-cap-apm 500.0 #:burst-capacity 4.0))
  (define l60-p0-batch
    (list (mark-urgent-survival-cmd! (sc2-raw-unit-command 23 (sc2-point2d 50.0 50.0) 0 '(99921) #f))
          (mark-urgent-survival-cmd! (sc2-raw-unit-command 23 (sc2-point2d 52.0 50.0) 0 '(99922) #f))
          (mark-urgent-survival-cmd! (sc2-raw-unit-command 23 (sc2-point2d 54.0 50.0) 0 '(99923) #f))
          (mark-urgent-survival-cmd! (sc2-raw-unit-command 23 (sc2-point2d 56.0 50.0) 0 '(99924) #f)) ;; blocked at -2.0!
          (sc2-raw-unit-command 251 #f 99999 '(99925) #f))) ;; Inject Larva (non-urgent P0) fires at -3.0!
  ;; Note: init tokens=4.0, 3 urgent 23 cmds cost 2+2+2=6 -> tokens=-2.0; 4th urgent 23 would hit -4.0 < -2.0 (blocked),
  ;; while 251 with same-sel or fresh? Wait: 251 with fresh tags costs 2 -> -2.0 - 2 = -4.0 < -3.0; if tokens starts at 5.0
  ;; (or 3 urgent cmds take 6 -> -1.0), 4th urgent (-1-2=-3 < -2) is BLOCKED and 251 (-1-2=-3 >= -3.0) FIRES!
  (define l60-gov-p0b (make-wire-apm-governor #:target-apm 200.0 #:hard-cap-apm 500.0 #:burst-capacity 5.0))
  (define l60-p0-out (govern-sc2-wire-actions! l60-gov-p0b l60-p0-batch 3200))
  (define l60-p0-has-inject?
    (ormap (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 251))) l60-p0-out))
  (define l60-p0-urgent-cnt
    (count (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 23))) l60-p0-out))
  ;; (e) Anti-DT 2-OC Scan (`#74 TvP who`): scouted WarpPrism (81) in TvP expands 2-OC scan reserve to BOTH OCs!
  (define l60-ewp (mk-l59-u 99930 81 4 90.0 90.0 #:hp 80.0 #:sh 100.0 #:en 0.0 #:en-max 0.0 #:fly #t))
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 100 (list l59c-min1)) #:game-info l59c-gi-p))
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 100 (list l59c-min1)) #:game-info l59c-gi-p))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define l60-tvp-wp-sat
    (l59c-mule-tags (saturate-workers-and-gas-commands
                     (make-test-obs 5150 200 100 (append (list l59c-oc1-65 l59c-oc2-55 l59c-rax l59c-min1 l59c-min2 l60-ewp) l59c-scvs12 l59c-mars6))
                     #:game-info l59c-gi-p)))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define l60-tvp-wp-casec
    (l59c-mule-tags (translate-bot-actions->sc2-raw-commands
                     '((cast-spell (99801 99802) calldown-mule 99808))
                     (make-test-obs 5180 200 100 (append (list l59c-oc1-65 l59c-oc2-55 l59c-rax l59c-min1 l59c-min2) l59c-scvs12 l59c-mars6))
                     #:game-info l59c-gi-p)))
  ;; Clean final rewind
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 100 (list l59c-min1))))
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 100 (list l59c-min1))))
  (check-true "l60-apm-gov-p1-purification-p0-spell-protection-and-anti-dt-2oc-scan"
              (and (= (wire-cmd-priority-tier l60-rep-a) 2)
                   (= (wire-cmd-priority-tier l60-land) 2)
                   (= (wire-cmd-priority-tier l60-fcam) 2)
                   (= (wire-cmd-priority-tier l60-q3666) 3)
                   (sc2-raw-unit-command? l60-idle-late-3666)
                   (macro-econ-cmd? l60-idle-late-3666)
                   (= (wire-cmd-priority-tier l60-idle-late-3666) 1)
                   (= (length l60-rep-out1) 1)
                   (equal? (sort (sc2-raw-unit-command-unit-tags (first l60-rep-out1)) <) '(99911 99912))
                   (null? l60-rep-out2)
                   (= (length l60-rep-out3) 1)
                   (= l60-rep-drops 0)
                   (= (length l60-land-out1) 1)
                   (null? l60-land-out2)
                   (= l60-p0-urgent-cnt 2)
                   l60-p0-has-inject?
                   (null? l60-tvp-wp-sat)
                   (null? l60-tvp-wp-casec))))

(printf "[Loop 61 Rally+Harvest] Testing #1609 3-race RALLY_WORKERS (3690), midgame 3666 coalescing/cooldowns, gas 112f anti-oscillation, & mineral-walk HARVEST_RETURN dedup...\n")
(let ()
  (define (mk-l61-u tag utype alliance x y
                    #:hp [hp 100.0] #:sh [sh 0.0] #:rad [rad 1.0]
                    #:bp [bp 1.0] #:fly [fly? #f] #:orders [ords '()]
                    #:assigned [asgn 0] #:ideal [idl 0] #:mins [mins 0] #:vesp [vesp 0])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 2)
              (sc2-point3d x y (if fly? 12.0 8.0)) 0.0 rad bp 0 #f #f #f
              hp hp sh sh 0.0 0.0 mins vesp fly? #f #f #t #f
              ords 0 '() asgn idl 0.0 0 0 0 0 '() 0 0))
  (define (rally-cmds cmds)
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 3690))) cmds))
  (define (gather-3666-cmds cmds)
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 3666))) cmds))

  ;; (0) SC2-NON-BLOCKING-RALLY-ABILITIES contains 199/203/207/3690 and excludes 3691 (BUILD_CREEPTUMOR)
  (check-true "l61-non-blocking-rally-abilities-fixed"
              (and (memv 199 SC2-NON-BLOCKING-RALLY-ABILITIES)
                   (memv 203 SC2-NON-BLOCKING-RALLY-ABILITIES)
                   (memv 207 SC2-NON-BLOCKING-RALLY-ABILITIES)
                   (memv 3690 SC2-NON-BLOCKING-RALLY-ABILITIES)
                   (not (memv 3691 SC2-NON-BLOCKING-RALLY-ABILITIES))))

  ;; (1) 3-race RALLY_WORKERS (3690): initial set, 0 re-emit while live, mined-out re-rally,
  ;;     saturated->nat with -2 hysteresis, CC fly+land reset, and combat-unsafe diversion!
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 0 (list (mk-l61-u 81001 341 3 22.0 30.0 #:mins 1500)))))
  (define l61-m1a (mk-l61-u 81010 341 3 23.0 30.0 #:mins 1800))
  (define l61-m1b (mk-l61-u 81011 341 3 22.0 32.0 #:mins 1500))
  (define l61-m2a (mk-l61-u 81020 341 3 66.0 30.0 #:mins 1800))
  (define l61-m2b (mk-l61-u 81021 341 3 67.0 32.0 #:mins 1500))
  ;; (1a) All 3 races (Nexus 59, CC/OC/PF 18/132/130, Hatch/Lair/Hive 86/100/101) emit 3690 on initial tick
  (define l61-all-races-ok?
    (for/and ([th-type (in-list '(59 18 132 130 86 100 101))]
              [idx (in-naturals)])
      (void (saturate-workers-and-gas-commands (make-test-obs 4 200 0 (list l61-m1a))))
      (define th (mk-l61-u (+ 81100 idx) th-type 1 28.5 30.0 #:hp 1500.0 #:rad 2.75 #:assigned 10 #:ideal 16))
      (define r1 (rally-cmds (saturate-workers-and-gas-commands (make-test-obs 200 200 0 (list th l61-m1a l61-m1b)))))
      ;; Subsequent tick 4f & 80f later while patch is alive -> 0 re-emits!
      (define r2 (rally-cmds (saturate-workers-and-gas-commands (make-test-obs 280 200 0 (list th l61-m1a l61-m1b)))))
      (and (= (length r1) 1)
           (= (sc2-raw-unit-command-target-unit-tag (first r1)) 81010)
           (equal? (sc2-raw-unit-command-unit-tags (first r1)) (list (+ 81100 idx)))
           (= (wire-cmd-priority-tier (first r1)) 1)
           (not (macro-econ-cmd? (first r1)))
           (null? r2))))
  (check-true "l61-rally-workers-3690-all-3-races-initial-and-zero-reemit" l61-all-races-ok?)

  ;; (1b) Mined-out patch (81010 -> mins=0) re-rallies onto remaining live patch 81011
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 0 (list l61-m1a))))
  (define l61-nx1 (mk-l61-u 81201 59 1 28.5 30.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75 #:assigned 12 #:ideal 16))
  (define r-init (rally-cmds (saturate-workers-and-gas-commands (make-test-obs 300 200 0 (list l61-nx1 l61-m1a l61-m1b)))))
  (define l61-m1a-empty (mk-l61-u 81010 341 3 23.0 30.0 #:mins 0))
  (define r-mined-out (rally-cmds (saturate-workers-and-gas-commands (make-test-obs 400 200 0 (list l61-nx1 l61-m1a-empty l61-m1b)))))
  (check-true "l61-rally-workers-rerallies-when-patch-mines-out"
              (and (= (length r-init) 1)
                   (= (sc2-raw-unit-command-target-unit-tag (first r-init)) 81010)
                   (= (length r-mined-out) 1)
                   (= (sc2-raw-unit-command-target-unit-tag (first r-mined-out)) 81011)))

  ;; (1c) Over-saturated Main (18/16, excess >= 2) rallies -> Natural (2/16, >= 3 open), holds at 14/16
  ;;      (-3 hysteresis) AND sticks to Natural even when a 3rd base (1/16) opens, enforces 224f routine
  ;;      cd, and switches back at 13/16!
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 0 (list l61-m1a))))
  (define l61-main-18 (mk-l61-u 81301 59 1 28.5 30.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75 #:assigned 18 #:ideal 16))
  (define l61-main-16 (mk-l61-u 81301 59 1 28.5 30.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75 #:assigned 16 #:ideal 16))
  (define l61-main-14 (mk-l61-u 81301 59 1 28.5 30.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75 #:assigned 14 #:ideal 16))
  (define l61-main-13 (mk-l61-u 81301 59 1 28.5 30.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75 #:assigned 13 #:ideal 16))
  (define l61-nat-2   (mk-l61-u 81302 59 1 60.5 30.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75 #:assigned 2 #:ideal 16))
  (define l61-3rd-1   (mk-l61-u 81303 59 1 92.5 30.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75 #:assigned 1 #:ideal 16))
  (define l61-m3a     (mk-l61-u 81030 341 3 98.0 30.0 #:mins 1800))
  (define r-sat-to-nat
    (rally-cmds (saturate-workers-and-gas-commands (make-test-obs 1000 200 0 (list l61-main-18 l61-nat-2 l61-m1a l61-m2a)))))
  ;; Sticky: even when 3rd (1/16) is more under-saturated than Nat (2/16) after +250f, Main stays rallied to Nat!
  (define r-sticky-nat
    (rally-cmds (saturate-workers-and-gas-commands (make-test-obs 1250 200 0 (list l61-main-18 l61-nat-2 l61-3rd-1 l61-m1a l61-m2a l61-m3a)))))
  ;; -3 hysteresis: Main at 14/16 (> 16-3 = 13) stays rallied to Nat!
  (define r-hyst-14
    (rally-cmds (saturate-workers-and-gas-commands (make-test-obs 1260 200 0 (list l61-main-14 l61-nat-2 l61-m1a l61-m2a)))))
  ;; 224f routine cooldown: dropping to 13/16 at >= +224f (1270) switches back; re-saturating to 18/16 at +100f (1370) is held; at >= +224f (1500) routes to Nat!
  (define r-back-13
    (rally-cmds (saturate-workers-and-gas-commands (make-test-obs 1270 200 0 (list l61-main-13 l61-nat-2 l61-m1a l61-m2a)))))
  (define r-cd-block-100
    (rally-cmds (saturate-workers-and-gas-commands (make-test-obs 1370 200 0 (list l61-main-18 l61-nat-2 l61-m1a l61-m2a)))))
  (define r-cd-allow-224
    (rally-cmds (saturate-workers-and-gas-commands (make-test-obs 1500 200 0 (list l61-main-18 l61-nat-2 l61-m1a l61-m2a)))))
  (check-true "l61-rally-workers-saturated-main-routes-to-nat-sticky-hysteresis-and-224f-cd"
              (and (ormap (lambda (c) (and (equal? (sc2-raw-unit-command-unit-tags c) '(81301))
                                           (= (sc2-raw-unit-command-target-unit-tag c) 81020)))
                          r-sat-to-nat)
                   (not (ormap (lambda (c) (equal? (sc2-raw-unit-command-unit-tags c) '(81301)))
                               r-sticky-nat))
                   (null? r-hyst-14)
                   (ormap (lambda (c) (and (equal? (sc2-raw-unit-command-unit-tags c) '(81301))
                                           (= (sc2-raw-unit-command-target-unit-tag c) 81010)))
                          r-back-13)
                   (null? r-cd-block-100)
                   (ormap (lambda (c) (and (equal? (sc2-raw-unit-command-unit-tags c) '(81301))
                                           (= (sc2-raw-unit-command-target-unit-tag c) 81020)))
                          r-cd-allow-224)))

  ;; (1d) Terran CC lifts off (`is-flying = #t`) and lands at expansion -> immediately re-rallies onto new base patch!
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 0 (list l61-m1a))))
  (define l61-cc-main (mk-l61-u 81401 18 1 28.5 30.0 #:hp 1500.0 #:rad 2.75 #:assigned 8 #:ideal 16))
  (define l61-cc-fly  (mk-l61-u 81401 36 1 44.0 30.0 #:hp 1500.0 #:rad 2.75 #:fly #t))
  (define l61-cc-land (mk-l61-u 81401 18 1 60.5 30.0 #:hp 1500.0 #:rad 2.75 #:assigned 0 #:ideal 16))
  (void (saturate-workers-and-gas-commands (make-test-obs 1500 200 0 (list l61-cc-main l61-m1a l61-m2a))))
  (void (saturate-workers-and-gas-commands (make-test-obs 1516 200 0 (list l61-cc-fly l61-m1a l61-m2a))))
  (define r-cc-landed
    (rally-cmds (saturate-workers-and-gas-commands (make-test-obs 1532 200 0 (list l61-cc-land l61-m1a l61-m2a)))))
  (check-true "l61-rally-workers-terran-cc-fly-and-land-rerallies-immediately"
              (and (= (length r-cc-landed) 1)
                   (equal? (sc2-raw-unit-command-unit-tags (first r-cc-landed)) '(81401))
                   (= (sc2-raw-unit-command-target-unit-tag (first r-cc-landed)) 81020)))

  ;; (1e) Combat-unsafe Main re-rallies onto safe Natural!
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 0 (list l61-m1a))))
  (define l61-enemies-at-main
    (for/list ([i (in-range 5)])
      (mk-l61-u (+ 81550 i) 74 4 (+ 27.0 (* 0.5 i)) 31.0 #:hp 80.0 #:sh 80.0 #:rad 0.625)))
  (define r-unsafe-divert
    (rally-cmds (saturate-workers-and-gas-commands
                 (make-test-obs 2000 200 0 (append (list l61-main-14 l61-nat-2 l61-m1a l61-m2a) l61-enemies-at-main)))))
  (check-true "l61-rally-workers-combat-unsafe-base-diverts-to-safe-base"
              (ormap (lambda (c) (and (equal? (sc2-raw-unit-command-unit-tags c) '(81301))
                                      (= (sc2-raw-unit-command-target-unit-tag c) 81020)))
                     r-unsafe-divert))

  ;; (2a) L61C (`#1652`): Midgame (cur-loop = 8000 > 4032): 0b offline evac of 8 workers emits 1 coalesced
  ;;      3666 cmd at Tier P1 (macro-econ-cmd?), throttles at +24f (< 32f!), and allows retry cleanly at +32f!
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 0 (list l61-m1a))))
  (define l61-evac-ws
    (for/list ([i (in-range 8)])
      (mk-l61-u (+ 81600 i) 84 1 (+ 25.0 (* 0.3 i)) 30.5 #:hp 20.0 #:sh 20.0 #:rad 0.375
                #:orders (list (sc2-unit-order 298 #f 81010 0.0)))))
  (define l61-evac-obs-1
    (make-test-obs 8000 200 0 (append (list l61-main-14 l61-nat-2 l61-m1a l61-m2a l61-m2b) l61-evac-ws l61-enemies-at-main)))
  (define l61-evac-obs-2
    (make-test-obs 8024 200 0 (append (list l61-main-14 l61-nat-2 l61-m1a l61-m2a l61-m2b) l61-evac-ws l61-enemies-at-main)))
  (define l61-evac-obs-3
    (make-test-obs 8032 200 0 (append (list l61-main-14 l61-nat-2 l61-m1a l61-m2a l61-m2b) l61-evac-ws l61-enemies-at-main)))
  (define evac-c1 (gather-3666-cmds (saturate-workers-and-gas-commands l61-evac-obs-1)))
  (define evac-c2 (gather-3666-cmds (saturate-workers-and-gas-commands l61-evac-obs-2)))
  (define evac-c3 (gather-3666-cmds (saturate-workers-and-gas-commands l61-evac-obs-3)))
  (check-true "l61-midgame-0b-evac-coalesced-1-cmd-p1-and-32f-throttled"
              (and (= (length evac-c1) 1)
                   (= (length (sc2-raw-unit-command-unit-tags (first evac-c1))) 8)
                   (macro-econ-cmd? (first evac-c1))
                   (= (wire-cmd-priority-tier (first evac-c1)) 1)
                   (null? evac-c2)
                   (= (length evac-c3) 1)
                   (macro-econ-cmd? (first evac-c3))
                   (= (wire-cmd-priority-tier (first evac-c3)) 1)))

  ;; (2b) Midgame (cur-loop = 8050 > 6048): Sec 3 disables donor-candidates stripping at 15/16,
  ;;      only transfers strictly over-sat (18/16 -> 1 coalesced cmd P3), and throttles 48f per base!
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 0 (list l61-m1a))))
  (define l61-nat-mins-4
    (for/list ([i (in-range 4)])
      (mk-l61-u (+ 81720 i) 341 3 66.0 (+ 27.0 (* 1.5 i)) #:mins 1500)))
  (define l61-main-scvs-15
    (for/list ([i (in-range 15)])
      (mk-l61-u (+ 81730 i) 45 1 (+ 24.0 (* 0.25 (modulo i 5))) (+ 28.0 (* 0.5 (quotient i 5)))
                #:hp 45.0 #:rad 0.375 #:orders (list (sc2-unit-order 295 #f 81010 0.0)))))
  (define l61-main-cc-15 (mk-l61-u 81701 18 1 28.5 30.0 #:hp 1500.0 #:rad 2.75 #:assigned 15 #:ideal 16))
  (define l61-main-cc-18 (mk-l61-u 81701 18 1 28.5 30.0 #:hp 1500.0 #:rad 2.75 #:assigned 18 #:ideal 16))
  (define l61-nat-cc-2   (mk-l61-u 81702 18 1 60.5 30.0 #:hp 1500.0 #:rad 2.75 #:assigned 2 #:ideal 16))
  (define xfer-donor-mid
    (gather-3666-cmds (saturate-workers-and-gas-commands
                       (make-test-obs 8050 200 0 (append (list l61-main-cc-15 l61-nat-cc-2 l61-m1a) l61-nat-mins-4 l61-main-scvs-15)))))
  (define xfer-over-1
    (gather-3666-cmds (saturate-workers-and-gas-commands
                       (make-test-obs 8054 200 0 (append (list l61-main-cc-18 l61-nat-cc-2 l61-m1a) l61-nat-mins-4 l61-main-scvs-15)))))
  (define xfer-over-2
    (gather-3666-cmds (saturate-workers-and-gas-commands
                       (make-test-obs 8058 200 0 (append (list l61-main-cc-18 l61-nat-cc-2 l61-m1a) l61-nat-mins-4 l61-main-scvs-15)))))
  (check-true "l61-midgame-sec3-disables-donor-strip-coalesces-oversat-and-48f-per-base-cd"
              (and (null? xfer-donor-mid)
                   (= (length xfer-over-1) 1)
                   (= (length (sc2-raw-unit-command-unit-tags (first xfer-over-1))) 2)
                   (= (wire-cmd-priority-tier (first xfer-over-1)) 3)
                   (null? xfer-over-2)))

  ;; (2c) L61B/L61C (`#1641`/`#1652`): GRMS urgent pull (210G/95M on 2 bases midgame) fires at Tier P1,
  ;;      routine non-GRMS pull (265G/140M) fires at Tier P3, `112f` opposite-direction cooldown blocks
  ;;      re-fill at +40f, and low-gas re-fill at +120f (130G < 180G) fires ONE coalesced 2-worker cmd at Tier P1!
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 0 (list l61-m1a))))
  (define l61-ref-3 (mk-l61-u 81802 20 1 25.0 24.0 #:hp 500.0 #:rad 1.5 #:assigned 3 #:ideal 3 #:vesp 1800))
  (define l61-ref-1 (mk-l61-u 81802 20 1 25.0 24.0 #:hp 500.0 #:rad 1.5 #:assigned 1 #:ideal 3 #:vesp 1800))
  (define l61-gws-3
    (for/list ([i (in-range 3)])
      (mk-l61-u (+ 81810 i) 45 1 (+ 25.0 (* 0.2 i)) 25.0 #:hp 45.0 #:rad 0.375
                #:orders (list (sc2-unit-order 295 #f 81802 0.0)))))
  (define l61-pull-grms-p1
    (gather-3666-cmds (saturate-workers-and-gas-commands
                       (make-test-obs 8200 95 210 (append (list l61-main-cc-15 l61-nat-cc-2 l61-ref-3 l61-m1a) l61-nat-mins-4 l61-gws-3 l61-main-scvs-15)))))
  (define l61-refill-8240
    (gather-3666-cmds (saturate-workers-and-gas-commands
                       (make-test-obs 8240 400 130 (append (list l61-main-cc-15 l61-nat-cc-2 l61-ref-1 l61-m1a) l61-nat-mins-4 (list (first l61-gws-3)) l61-main-scvs-15)))))
  (define l61-refill-8320
    (gather-3666-cmds (saturate-workers-and-gas-commands
                       (make-test-obs 8320 400 130 (append (list l61-main-cc-15 l61-nat-cc-2 l61-ref-1 l61-m1a) l61-nat-mins-4 (list (first l61-gws-3)) l61-main-scvs-15)))))
  ;; Routine non-GRMS 2-base pull (`265G / 140M`, `min >= 110`) after `>= 112f` fires at Tier P3!
  (define l61-pull-routine-p3
    (gather-3666-cmds (saturate-workers-and-gas-commands
                       (make-test-obs 8450 140 265 (append (list l61-main-cc-15 l61-nat-cc-2 l61-ref-3 l61-m1a) l61-nat-mins-4 l61-gws-3 l61-main-scvs-15)))))
  (check-true "l61b-grms-urgent-pull-p1-routine-pull-p3-and-112f-opposite-cd"
              (and (= (length l61-pull-grms-p1) 1)
                   (macro-econ-cmd? (first l61-pull-grms-p1))
                   (= (wire-cmd-priority-tier (first l61-pull-grms-p1)) 1)
                   (not (ormap (lambda (c) (= (sc2-raw-unit-command-target-unit-tag c) 81802)) l61-refill-8240))
                   (= (length (filter (lambda (c) (= (sc2-raw-unit-command-target-unit-tag c) 81802)) l61-refill-8320)) 1)
                   (ormap (lambda (c) (and (= (sc2-raw-unit-command-target-unit-tag c) 81802)
                                           (= (length (sc2-raw-unit-command-unit-tags c)) 2)
                                           (macro-econ-cmd? c)
                                           (= (wire-cmd-priority-tier c) 1)))
                          l61-refill-8320)
                   (= (length l61-pull-routine-p3) 1)
                   (= (wire-cmd-priority-tier (first l61-pull-routine-p3)) 3)))

  ;; (2d) `mineral-walk` HARVEST_RETURN dedup: returning Probe <= 9t of home mineral patch emits 0 `3666`,
  ;;      while fleeing Probe > 9t away at mid-map STILL emits urgent P0 `3666`!
  (define l61-probe-home-ret
    (mk-l61-u 81901 84 1 25.0 30.0 #:hp 10.0 #:sh 5.0 #:rad 0.375
              #:orders (list (sc2-unit-order 299 #f 81301 0.0))))
  (define l61-probe-far-flee
    (mk-l61-u 81902 84 1 80.0 80.0 #:hp 10.0 #:sh 5.0 #:rad 0.375
              #:orders (list (sc2-unit-order 299 #f 81301 0.0))))
  (define l61-mw-obs (make-test-obs 5000 200 100 (list l61-main-14 l61-m1a l61-probe-home-ret l61-probe-far-flee)))
  (define l61-mw-home (gather-3666-cmds (translate-bot-actions->sc2-raw-commands '((mineral-walk 81901 23.0 30.0)) l61-mw-obs)))
  (define l61-mw-far  (gather-3666-cmds (translate-bot-actions->sc2-raw-commands '((mineral-walk 81902 23.0 30.0)) l61-mw-obs)))
  (check-true "l61-mineral-walk-skips-harvest-return-near-home-keeps-fleeing-far"
              (and (null? l61-mw-home)
                   (= (length l61-mw-far) 1)
                   (= (sc2-raw-unit-command-ability-id (first l61-mw-far)) 3666)
                   (urgent-survival-cmd? (first l61-mw-far))))

  ;; (2e) L61C (`#1652`): Symmetric Sec 2 coalesced gas refill — < 180G emits 1 coalesced P1 cmd (up to 3 workers),
  ;;      >= 180G refill emits 1 coalesced P3 cmd (2 workers for 1/3), and unchanged gb-asgn blocks at +24f & retries at +32f!
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 0 (list l61-m1a))))
  (define l61c-ref-0 (mk-l61-u 81802 20 1 25.0 24.0 #:hp 500.0 #:rad 1.5 #:assigned 0 #:ideal 3 #:vesp 1800))
  (define l61c-fill-p1
    (filter (lambda (c) (= (sc2-raw-unit-command-target-unit-tag c) 81802))
            (gather-3666-cmds
             (saturate-workers-and-gas-commands
              (make-test-obs 8600 400 120 (append (list l61-main-cc-15 l61-nat-cc-2 l61c-ref-0 l61-m1a) l61-nat-mins-4 l61-main-scvs-15))))))
  (define l61c-fill-p3
    (filter (lambda (c) (= (sc2-raw-unit-command-target-unit-tag c) 81802))
            (gather-3666-cmds
             (saturate-workers-and-gas-commands
              (make-test-obs 8632 400 210 (append (list l61-main-cc-15 l61-nat-cc-2 l61-ref-1 l61-m1a) l61-nat-mins-4 (list (first l61-gws-3)) l61-main-scvs-15))))))
  (check-true "l61c-sec2-coalesced-gas-refill-p1-below-180g-p3-above-180g-and-32f-retry"
              (and (= (length l61c-fill-p1) 1)
                   (= (length (sc2-raw-unit-command-unit-tags (first l61c-fill-p1))) 3)
                   (macro-econ-cmd? (first l61c-fill-p1))
                   (= (wire-cmd-priority-tier (first l61c-fill-p1)) 1)
                   (= (length l61c-fill-p3) 1)
                   (= (length (sc2-raw-unit-command-unit-tags (first l61c-fill-p3))) 2)
                   (not (macro-econ-cmd? (first l61c-fill-p3)))
                   (= (wire-cmd-priority-tier (first l61c-fill-p3)) 3)))
  ;; Unchanged gb-asgn=1 blocks retry at +24f (8656) and allows retry at +32f (8664)!
  (define l61c-fill-hold24
    (filter (lambda (c) (= (sc2-raw-unit-command-target-unit-tag c) 81802))
            (gather-3666-cmds
             (saturate-workers-and-gas-commands
              (make-test-obs 8656 400 210 (append (list l61-main-cc-15 l61-nat-cc-2 l61-ref-1 l61-m1a) l61-nat-mins-4 (list (first l61-gws-3)) l61-main-scvs-15))))))
  (define l61c-fill-retry32
    (filter (lambda (c) (= (sc2-raw-unit-command-target-unit-tag c) 81802))
            (gather-3666-cmds
             (saturate-workers-and-gas-commands
              (make-test-obs 8664 400 210 (append (list l61-main-cc-15 l61-nat-cc-2 l61-ref-1 l61-m1a) l61-nat-mins-4 (list (first l61-gws-3)) l61-main-scvs-15))))))
  (check-true "l61c-sec2-unchanged-asgn-throttles-at-24f-and-retries-at-32f"
              (and (null? l61c-fill-hold24)
                   (= (length l61c-fill-retry32) 1)))

  ;; (2f) L61C (`#1652`): Sec 1 midgame (> 4032f) idle recovery coalesces 4 idle workers into 1 P1 cmd,
  ;;      throttles retry at +24f (< 32f), and retries cleanly at +32f!
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 0 (list l61-m1a))))
  (define l61c-idle-4
    (for/list ([i (in-range 4)])
      (mk-l61-u (+ 81950 i) 45 1 (+ 26.0 (* 0.3 i)) 30.5 #:hp 45.0 #:rad 0.375)))
  (define l61c-idle-c1
    (gather-3666-cmds (saturate-workers-and-gas-commands
                       (make-test-obs 8800 200 100 (append (list l61-main-cc-15 l61-m1a l61-m1b) l61c-idle-4)))))
  (define l61c-idle-c2
    (gather-3666-cmds (saturate-workers-and-gas-commands
                       (make-test-obs 8824 200 100 (append (list l61-main-cc-15 l61-m1a l61-m1b) l61c-idle-4)))))
  (define l61c-idle-c3
    (gather-3666-cmds (saturate-workers-and-gas-commands
                       (make-test-obs 8832 200 100 (append (list l61-main-cc-15 l61-m1a l61-m1b) l61c-idle-4)))))
  (check-true "l61c-sec1-midgame-idle-coalesced-p1-and-32f-retry"
              (and (= (length l61c-idle-c1) 1)
                   (= (length (sc2-raw-unit-command-unit-tags (first l61c-idle-c1))) 4)
                   (macro-econ-cmd? (first l61c-idle-c1))
                   (= (wire-cmd-priority-tier (first l61c-idle-c1)) 1)
                   (null? l61c-idle-c2)
                   (= (length l61c-idle-c3) 1)
                   (macro-econ-cmd? (first l61c-idle-c3))
                   (= (wire-cmd-priority-tier (first l61c-idle-c3)) 1)))

  ;; (2g) L61C (`#1652`): RALLY_WORKERS `th-off?` uses `112f` (`5s`) cooldown tier (NOT `32f` urgent):
  ;;      already-rallied Main going combat-unsafe is held at +60f (< 112f) and diverts cleanly at +112f!
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 0 (list l61-m1a))))
  (define r-l61c-init
    (rally-cmds (saturate-workers-and-gas-commands
                 (make-test-obs 2000 200 0 (list l61-main-14 l61-nat-2 l61-m1a l61-m2a)))))
  (define r-l61c-hold60
    (rally-cmds (saturate-workers-and-gas-commands
                 (make-test-obs 2060 200 0 (append (list l61-main-14 l61-nat-2 l61-m1a l61-m2a) l61-enemies-at-main)))))
  (define r-l61c-divert112
    (rally-cmds (saturate-workers-and-gas-commands
                 (make-test-obs 2112 200 0 (append (list l61-main-14 l61-nat-2 l61-m1a l61-m2a) l61-enemies-at-main)))))
  (check-true "l61c-rally-workers-th-off-uses-112f-tier-not-32f"
              (and (ormap (lambda (c) (and (equal? (sc2-raw-unit-command-unit-tags c) '(81301))
                                           (= (sc2-raw-unit-command-target-unit-tag c) 81010)))
                          r-l61c-init)
                   (not (ormap (lambda (c) (equal? (sc2-raw-unit-command-unit-tags c) '(81301)))
                               r-l61c-hold60))
                   (ormap (lambda (c) (and (equal? (sc2-raw-unit-command-unit-tags c) '(81301))
                                           (= (sc2-raw-unit-command-target-unit-tag c) 81020)))
                          r-l61c-divert112)))

  ;; (2h) Loop 62 Phase 2 (`#1662`): Sec 6a (`saturate-workers-and-gas-commands`) and Case C
  ;;      (`translate-bot-actions->sc2-raw-commands` for `calldown-mule`) share `macro-ability-policy.rkt`
  ;;      and agree 100% across TvP 2-OC DT/Prism (101e), unprovoked TvT (50e), active cloak=1 hard-block,
  ;;      and isolated Arena `sc2-ab-t10` (100e hold / 101e allow)!
  (define (mk-p2-u tag utype alliance x y
                   #:hp [hp 100.0] #:en [en 0.0] #:en-max [en-max 0.0]
                   #:rad [rad 1.0] #:cloak [cloak 0] #:mins [mins 0])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 2)
              (sc2-point3d x y 8.0) 0.0 rad 1.0 cloak #f #f #f
              hp hp 0.0 0.0 en en-max mins 0 #f #f #f #t #f
              '() 0 '() 0 0 0.0 0 0 0 0 '() 0 0))
  (define (mule-171-tags cmds)
    (sort (append*
           (for/list ([c (in-list cmds)]
                      #:when (and (sc2-raw-unit-command? c)
                                  (= (sc2-raw-unit-command-ability-id c) 171)))
             (sc2-raw-unit-command-unit-tags c)))
          <))
  (define p2-gi-p (sc2-game-info "TestMap" '(160 . 160) '() #f #f #f
                                 (list (hasheq 'player-id 1 'race-actual 'Terran)
                                       (hasheq 'player-id 2 'race-actual 'Protoss))
                                 '() #f))
  (define p2-gi-t (sc2-game-info "TestMap" '(160 . 160) '() #f #f #f
                                 (list (hasheq 'player-id 1 'race-actual 'Terran)
                                       (hasheq 'player-id 2 'race-actual 'Terran))
                                 '() #f))
  (define p2-min1 (mk-p2-u 82010 341 3 23.0 30.0 #:mins 1500))
  (define p2-min2 (mk-p2-u 82011 341 3 66.0 30.0 #:mins 1500))
  (define p2-rax  (mk-p2-u 82020 21 1 35.0 30.0 #:hp 1000.0 #:rad 1.5))
  (define p2-scvs12
    (for/list ([i (in-range 12)])
      (mk-p2-u (+ 82030 i) 45 1 (+ 24.0 (* 0.2 i)) 30.0 #:hp 45.0 #:rad 0.375)))
  (define p2-mars6
    (for/list ([i (in-range 6)])
      (mk-p2-u (+ 82050 i) 48 1 (+ 40.0 (* 0.5 i)) 30.0 #:hp 45.0 #:rad 0.375)))
  (define p2-e-wp  (mk-p2-u 82090 81 4 95.0 95.0 #:hp 80.0))
  (define p2-e-mar (mk-p2-u 82091 48 4 95.0 95.0 #:hp 45.0))
  (define p2-e-dt  (mk-p2-u 82092 76 4 44.0 30.0 #:hp 40.0 #:cloak 1))

  ;; Case 1: TvP 2-OC DT/Prism reserve (101e floor on both OCs) + Unprovoked TvT (50e on both OCs)
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 100 (list p2-min1)) #:game-info p2-gi-p))
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 100 (list p2-min1)) #:game-info p2-gi-p))
  (define p2-oc1-100 (mk-p2-u 82001 132 1 28.5 30.0 #:hp 1500.0 #:en 100.0 #:en-max 200.0 #:rad 2.75))
  (define p2-oc2-90  (mk-p2-u 82002 132 1 60.5 30.0 #:hp 1500.0 #:en 90.0  #:en-max 200.0 #:rad 2.75))
  (define p2-oc1-101 (mk-p2-u 82001 132 1 28.5 30.0 #:hp 1500.0 #:en 101.0 #:en-max 200.0 #:rad 2.75))
  (define p2-tvp-obs-100 (make-test-obs 4200 200 100 (append (list p2-oc1-100 p2-oc2-90 p2-rax p2-min1 p2-min2 p2-e-wp) p2-scvs12 p2-mars6)))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define p2-tvp-sat-100 (mule-171-tags (saturate-workers-and-gas-commands p2-tvp-obs-100 #:game-info p2-gi-p)))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define p2-tvp-cc-100
    (mule-171-tags (translate-bot-actions->sc2-raw-commands
                    '((cast-spell (82001 82002) calldown-mule 82010))
                    p2-tvp-obs-100 #:game-info p2-gi-p)))
  ;; Next tick (WP left vision, latch persists!): OC1=101e allowed, OC2=90e still held by both!
  (define p2-tvp-obs-101 (make-test-obs 4240 200 100 (append (list p2-oc1-101 p2-oc2-90 p2-rax p2-min1 p2-min2) p2-scvs12 p2-mars6)))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define p2-tvp-sat-101 (mule-171-tags (saturate-workers-and-gas-commands p2-tvp-obs-101 #:game-info p2-gi-p)))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define p2-tvp-cc-101
    (mule-171-tags (translate-bot-actions->sc2-raw-commands
                    '((cast-spell (82001 82002) calldown-mule 82010))
                    p2-tvp-obs-101 #:game-info p2-gi-p)))
  ;; Rewind for Unprovoked TvT: both 55e & 50e OCs MULE freely in both Sec 6a and Case C!
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 100 (list p2-min1)) #:game-info p2-gi-t))
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 100 (list p2-min1)) #:game-info p2-gi-t))
  (define p2-oc1-55 (mk-p2-u 82001 132 1 28.5 30.0 #:hp 1500.0 #:en 55.0 #:en-max 200.0 #:rad 2.75))
  (define p2-oc2-50 (mk-p2-u 82002 132 1 60.5 30.0 #:hp 1500.0 #:en 50.0 #:en-max 200.0 #:rad 2.75))
  (define p2-tvt-obs (make-test-obs 5600 200 100 (append (list p2-oc1-55 p2-oc2-50 p2-rax p2-min1 p2-min2 p2-e-mar) p2-scvs12 p2-mars6)))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define p2-tvt-sat (mule-171-tags (saturate-workers-and-gas-commands p2-tvt-obs #:game-info p2-gi-t)))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define p2-tvt-cc
    (mule-171-tags (translate-bot-actions->sc2-raw-commands
                    '((cast-spell (82001 82002) calldown-mule 82010))
                    p2-tvt-obs #:game-info p2-gi-t)))
  (check-true "l62-p2-sec6a-and-casec-agree-tvp-dt-prism-101e-and-unprovoked-tvt-50e"
              (and (null? p2-tvp-sat-100)
                   (null? p2-tvp-cc-100)
                   (equal? p2-tvp-sat-101 '(82001))
                   (equal? p2-tvp-cc-101 '(82001))
                   (equal? p2-tvt-sat '(82001 82002))
                   (equal? p2-tvt-cc '(82001 82002))))

  ;; Case 2: Active uncovered cloak=1 hard-block (even at 200e!) + isolated Arena `sc2-ab-t10` (100e hold / 101e allow)
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 100 (list p2-min1)) #:game-info p2-gi-p))
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 100 (list p2-min1)) #:game-info p2-gi-p))
  (define p2-oc1-200 (mk-p2-u 82001 132 1 28.5 30.0 #:hp 1500.0 #:en 200.0 #:en-max 200.0 #:rad 2.75))
  (define p2-cloak-obs (make-test-obs 5800 200 100 (append (list p2-oc1-200 p2-rax p2-min1 p2-e-dt) p2-scvs12 p2-mars6)))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define p2-cloak-sat (mule-171-tags (saturate-workers-and-gas-commands p2-cloak-obs #:game-info p2-gi-p)))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define p2-cloak-cc
    (mule-171-tags (translate-bot-actions->sc2-raw-commands
                    '((cast-spell (82001) calldown-mule 82010))
                    p2-cloak-obs #:game-info p2-gi-p)))
  ;; Rewind for isolated Arena `sc2-ab-t10` (0 macro bldgs, <= 8 workers, >= 6 Marines, uncloaked enemy)
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 100 (list p2-min1)) #:game-info p2-gi-t))
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 100 (list p2-min1)) #:game-info p2-gi-t))
  (define p2-arena-obs-100 (make-test-obs 300 200 100 (append (list p2-oc1-100 p2-min1 p2-e-mar) p2-mars6)))
  (define p2-arena-obs-101 (make-test-obs 340 200 100 (append (list p2-oc1-101 p2-min1 p2-e-mar) p2-mars6)))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define p2-arena-sat-100 (mule-171-tags (saturate-workers-and-gas-commands p2-arena-obs-100 #:game-info p2-gi-t)))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define p2-arena-cc-100
    (mule-171-tags (translate-bot-actions->sc2-raw-commands
                    '((cast-spell (82001) calldown-mule 82010))
                    p2-arena-obs-100 #:game-info p2-gi-t)))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define p2-arena-sat-101 (mule-171-tags (saturate-workers-and-gas-commands p2-arena-obs-101 #:game-info p2-gi-t)))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define p2-arena-cc-101
    (mule-171-tags (translate-bot-actions->sc2-raw-commands
                    '((cast-spell (82001) calldown-mule 82010))
                    p2-arena-obs-101 #:game-info p2-gi-t)))
  (check-true "l62-p2-sec6a-and-casec-agree-active-cloak1-hardblock-and-ab-t10-arena"
              (and (null? p2-cloak-sat)
                   (null? p2-cloak-cc)
                   (null? p2-arena-sat-100)
                   (null? p2-arena-cc-100)
                   (equal? p2-arena-sat-101 '(82001))
                   (equal? p2-arena-cc-101 '(82001))))

  ;; (2i) Loop 63 (`#1704`): Pro-Rate RALLY_WORKERS — requires own excess >= 2 (18/16), target >= 3
  ;;      open slots (13/16 or less), and blocks cross-rally ping-pong (A->B while B->A)!
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 0 (list l61-m1a))))
  (define l63-main-17 (mk-l61-u 81301 59 1 28.5 30.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75 #:assigned 17 #:ideal 16))
  (define l63-nat-14  (mk-l61-u 81302 59 1 60.5 30.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75 #:assigned 14 #:ideal 16))
  (define l63-nat-13  (mk-l61-u 81302 59 1 60.5 30.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75 #:assigned 13 #:ideal 16))
  (define l63-nat-18  (mk-l61-u 81302 59 1 60.5 30.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75 #:assigned 18 #:ideal 16))
  ;; Initial tick: Main 16/16 (excess 0) & Nat 2/16 -> Main stays on Main (81010), NOT Nat!
  (define r63-ex0 (rally-cmds (saturate-workers-and-gas-commands (make-test-obs 1000 200 0 (list l61-main-16 l61-nat-2 l61-m1a l61-m2a)))))
  ;; +250f: Main 17/16 (excess 1 < 2) -> still stays on Main (0 re-rally)!
  (define r63-ex1 (rally-cmds (saturate-workers-and-gas-commands (make-test-obs 1250 200 0 (list l63-main-17 l61-nat-2 l61-m1a l61-m2a)))))
  ;; +500f: Main 18/16 (excess 2) but Nat 14/16 (only 2 open slots < 3) -> still stays on Main (0 re-rally)!
  (define r63-open2 (rally-cmds (saturate-workers-and-gas-commands (make-test-obs 1500 200 0 (list l61-main-18 l63-nat-14 l61-m1a l61-m2a)))))
  ;; +750f: Main 18/16 (excess 2) & Nat 13/16 (3 open slots >= 3) -> routes to Nat (81020)!
  (define r63-open3 (rally-cmds (saturate-workers-and-gas-commands (make-test-obs 1750 200 0 (list l61-main-18 l63-nat-13 l61-m1a l61-m2a)))))
  ;; Anti-ping-pong: Main is currently rallied -> Nat (at 1750); at 1850 (+100f < 224f so Main is still
  ;; rallied -> Nat, while Nat hasn't re-rallied since 1000 -> +850f >= 224f!), Nat (18/16) MUST NOT
  ;; cross-rally back onto Main (13/16) while Main's target is Nat!
  (define r63-no-pp (rally-cmds (saturate-workers-and-gas-commands (make-test-obs 1850 200 0 (list l61-main-13 l63-nat-18 l61-m1a l61-m2a)))))
  (check-true "l63-rally-workers-requires-excess2-target-open3-and-no-ping-pong"
              (and (ormap (lambda (c) (and (equal? (sc2-raw-unit-command-unit-tags c) '(81301))
                                           (= (sc2-raw-unit-command-target-unit-tag c) 81010)))
                          r63-ex0)
                   (null? r63-ex1)
                   (null? r63-open2)
                   (ormap (lambda (c) (and (equal? (sc2-raw-unit-command-unit-tags c) '(81301))
                                           (= (sc2-raw-unit-command-target-unit-tag c) 81020)))
                          r63-open3)
                   (not (ormap (lambda (c) (and (equal? (sc2-raw-unit-command-unit-tags c) '(81302))
                                                (= (sc2-raw-unit-command-target-unit-tag c) 81010)))
                               r63-no-pp))))

  ;; (2j) Loop 63 (`#1704`): GRMS urgent pull (`>= 200G & < 110M`, P1) bypasses recent geyser-fill
  ;;      `112f` opposite-direction cooldown and fires ONE coalesced 3-worker P1 cmd immediately,
  ;;      while routine non-GRMS pull (`265G / 140M`) still respects `112f` opp-cd!
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 0 (list l61-m1a))))
  (define l63-ref1-full (mk-l61-u 81802 20 1 25.0 24.0 #:hp 500.0 #:rad 1.5 #:assigned 3 #:ideal 3 #:vesp 1800))
  (define l63-ref2-empty (mk-l61-u 81803 20 1 31.0 24.0 #:hp 500.0 #:rad 1.5 #:assigned 0 #:ideal 3 #:vesp 1800))
  (define l63-ref2-full (mk-l61-u 81803 20 1 31.0 24.0 #:hp 500.0 #:rad 1.5 #:assigned 3 #:ideal 3 #:vesp 1800))
  (define l63-gws-6
    (append
     (for/list ([i (in-range 3)])
       (mk-l61-u (+ 81810 i) 45 1 (+ 25.0 (* 0.2 i)) 25.0 #:hp 45.0 #:rad 0.375
                 #:orders (list (sc2-unit-order 295 #f 81802 0.0))))
     (for/list ([i (in-range 3)])
       (mk-l61-u (+ 81820 i) 45 1 (+ 31.0 (* 0.2 i)) 25.0 #:hp 45.0 #:rad 0.375
                 #:orders (list (sc2-unit-order 295 #f 81803 0.0))))))
  (define l63-min-scvs-20
    (for/list ([i (in-range 20)])
      (mk-l61-u (+ 81830 i) 45 1 (+ 24.0 (* 0.2 (modulo i 5))) (+ 28.0 (* 0.4 (quotient i 5)))
                #:hp 45.0 #:rad 0.375 #:orders (list (sc2-unit-order 295 #f 81010 0.0)))))
  ;; Tick 9000: Sec 2 fills 2nd Refinery (`81803`), setting SC2-SAT-GAS-LAST-FILL-GLOBAL = 9000.
  (define l63-fill-9000
    (gather-3666-cmds (saturate-workers-and-gas-commands
                       (make-test-obs 9000 320 120 (append (list l61-main-cc-15 l61-nat-cc-2 l63-ref1-full l63-ref2-empty l61-m1a) l61-nat-mins-4 (take l63-gws-6 3) l63-min-scvs-20)))))
  ;; Tick 9020 (+20f < 112f): routine non-GRMS pull (`265G / 140M`) STILL blocked by 112f opp-cd!
  (define l63-routine-blocked-9020
    (gather-3666-cmds (saturate-workers-and-gas-commands
                       (make-test-obs 9020 140 265 (append (list l61-main-cc-15 l61-nat-cc-2 l63-ref1-full l63-ref2-full l61-m1a) l61-nat-mins-4 l63-gws-6 l63-min-scvs-20)))))
  ;; Tick 9024 (+24f < 112f): genuine GRMS (`210G / 95M`) with 6 active gas workers bypasses opp-cd
  ;; and fires ONE coalesced P1 cmd pulling 3 workers immediately!
  (define l63-grms-bypass-9024
    (gather-3666-cmds (saturate-workers-and-gas-commands
                       (make-test-obs 9024 95 210 (append (list l61-main-cc-15 l61-nat-cc-2 l63-ref1-full l63-ref2-full l61-m1a) l61-nat-mins-4 l63-gws-6 l63-min-scvs-20)))))
  (check-true "l63-grms-urgent-pull-bypasses-fill-opp-cd-at-p1"
              (and (ormap (lambda (c) (= (sc2-raw-unit-command-target-unit-tag c) 81803)) l63-fill-9000)
                   (null? l63-routine-blocked-9020)
                   (= (length l63-grms-bypass-9024) 1)
                   (macro-econ-cmd? (first l63-grms-bypass-9024))
                   (= (wire-cmd-priority-tier (first l63-grms-bypass-9024)) 1)
                   (= (length (sc2-raw-unit-command-unit-tags (first l63-grms-bypass-9024))) 3)))

  ;; Clean final rewind
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 0 (list l61-m1a))))
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 0 (list l61-m1a)))))

(printf "[Loop 63B Bug #2C] Testing obs->snapshot energy floor (49.6->49), 4126 edge-to-edge range + Tier P1 + 1344f wire cooldown & Sec 6b yield handoff...\n")
(let ()
  (define (mk-l63b-u tag utype alliance x y
                     #:hp [hp 100.0] #:sh [sh 0.0] #:rad [rad 1.0]
                     #:en [en 0.0] #:en-max [en-max 200.0]
                     #:bp [bp 1.0] #:fly [fly? #f] #:orders [ords '()]
                     #:mins [mins 0] #:pax [pax '()])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 2)
              (sc2-point3d x y (if fly? 12.0 8.0)) 0.0 rad bp 0 #f #f #f
              hp hp sh sh en en-max mins 0 fly? #f #f #t #f
              ords 0 '() 0 0 0.0 0 0 0 0 pax (length pax) (if (null? pax) 0 8)))
  (define (er-4126-cmds cmds)
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 4126))) cmds))
  (define (chrono-3755-cmds cmds)
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 3755))) cmds))
  (define l63b-min (mk-l63b-u 83001 341 3 23.0 30.0 #:mins 1500 #:en 0.0 #:en-max 0.0))

  ;; (1) `sc2-observation->runtime-obs-hash` floors self building, self unit, & passenger energy
  ;;     so `49.6e` / `49.99e` / `74.6e` NEVER round up to `50` / `75` and cause phantom cooldown claims!
  (reset-sc2-live-response-data!)
  (define l63b-nx-496  (mk-l63b-u 83101 59 1 30.0 30.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75 #:en 49.6))
  (define l63b-nx-4999 (mk-l63b-u 83102 59 1 42.0 30.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75 #:en 49.99))
  (define l63b-nx-500  (mk-l63b-u 83103 59 1 54.0 30.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75 #:en 50.0))
  (define l63b-sen-496 (mk-l63b-u 83104 77 1 36.0 30.0 #:hp 40.0 #:sh 40.0 #:rad 0.5 #:en 49.6))
  (define l63b-sen-500 (mk-l63b-u 83105 77 1 38.0 30.0 #:hp 40.0 #:sh 40.0 #:rad 0.5 #:en 50.0))
  (define l63b-wp-pax  (mk-l63b-u 83106 81 1 40.0 30.0 #:hp 80.0 #:sh 100.0 #:rad 1.0 #:fly #t #:en 0.0 #:en-max 0.0
                                  #:pax (list (sc2-passenger-unit 83107 75 40.0 40.0 40.0 40.0 74.6 200.0))))
  (define l63b-snap
    (sc2-observation->runtime-obs-hash
     (make-test-obs 2000 100 50 (list l63b-nx-496 l63b-nx-4999 l63b-nx-500 l63b-sen-496 l63b-sen-500 l63b-wp-pax l63b-min))))
  (define (find-by-id lst id)
    (findf (lambda (h) (= (hash-ref h 'id -1) id)) lst))
  (define snap-b (hash-ref l63b-snap 'ally-buildings '()))
  (define snap-u (hash-ref l63b-snap 'ally-units '()))
  (define snap-wp (find-by-id snap-u 83106))
  (define snap-pax (and snap-wp (find-by-id (hash-ref snap-wp 'passengers '()) 83107)))
  (check-true "l63b-obs-energy-floors-49-6-to-49-building-unit-and-passenger"
              (and (equal? (hash-ref (find-by-id snap-b 83101) 'energy #f) 49)
                   (equal? (hash-ref (find-by-id snap-b 83102) 'energy #f) 49)
                   (equal? (hash-ref (find-by-id snap-b 83103) 'energy #f) 50)
                   (equal? (hash-ref (find-by-id snap-u 83104) 'energy #f) 49)
                   (equal? (hash-ref (find-by-id snap-u 83105) 'energy #f) 50)
                   (equal? (and snap-pax (hash-ref snap-pax 'energy #f)) 74)))

  ;; (2) Wire `4126` uses true edge-to-edge range `15.0 + rad(nx) + rad(tgt) - 0.25` (Nexus 2.75 + Sentry 0.5
  ;;     => 18.0t center-to-center -> emits at 16.6t, rejects at 20.0t), wraps in Tier P1 `mark-macro-econ-cmd!`,
  ;;     records `SC2-NEXUS-RECHARGE-LAST-LOOP` ONLY upon real emission, blocks repeats for `< 1344f`, and allows
  ;;     again at `>= +1344f`!
  (reset-sc2-live-response-data!)
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 100 50 (list l63b-min))))
  (void (saturate-workers-and-gas-commands (make-test-obs 4 100 50 (list l63b-min))))
  (define l63b-nx-50   (mk-l63b-u 83201 59 1 30.0 30.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75 #:en 50.0))
  (define l63b-nx-496b (mk-l63b-u 83202 59 1 30.0 30.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75 #:en 49.6))
  (define l63b-sen-166 (mk-l63b-u 83203 77 1 46.6 30.0 #:hp 40.0 #:sh 40.0 #:rad 0.5 #:en 25.0))
  (define l63b-sen-200 (mk-l63b-u 83204 77 1 50.0 30.0 #:hp 40.0 #:sh 40.0 #:rad 0.5 #:en 25.0))
  ;; Rejected casts (`49.6e` or `20.0t` out-of-range) emit 0 cmds and MUST NOT trip the 1344f latch!
  (define l63b-rej-cmds
    (er-4126-cmds
     (translate-bot-actions->sc2-raw-commands
      '((cast-spell 83202 nexus-energy-recharge 83203)
        (cast-spell 83201 nexus-energy-recharge 83204))
      (make-test-obs 5000 100 50 (list l63b-nx-50 l63b-nx-496b l63b-sen-166 l63b-sen-200)))))
  (define l63b-ready-after-rej? (sc2-nexus-recharge-cooldown-ready? 5004))
  ;; Valid cast at 16.6t (`> 15.0` old cap, `<= 18.0` edge-to-edge) succeeds at Tier P1 & latches 5010!
  (define l63b-emit-5010
    (er-4126-cmds
     (translate-bot-actions->sc2-raw-commands
      '((cast-spell 83201 nexus-energy-recharge 83203))
      (make-test-obs 5010 100 50 (list l63b-nx-50 l63b-sen-166)))))
  (define l63b-ready-5100? (sc2-nexus-recharge-cooldown-ready? 5100))
  (define l63b-ready-6353? (sc2-nexus-recharge-cooldown-ready? 6353))
  (define l63b-ready-6354? (sc2-nexus-recharge-cooldown-ready? 6354))
  ;; Second cast within `< 1344f` (both `cast-spell` & direct `nexus-energy-recharge` form) is blocked!
  (define l63b-blocked-5100
    (er-4126-cmds
     (translate-bot-actions->sc2-raw-commands
      '((cast-spell 83201 nexus-energy-recharge 83203)
        (nexus-energy-recharge 83201 83203))
      (make-test-obs 5100 100 50 (list l63b-nx-50 l63b-sen-166)))))
  ;; Sec 6b Probe Chrono (`3755`) MUST NOT yield to `4126` while `4126` is on its 1344f wire cooldown!
  (define l63b-nx-prb-75
    (mk-l63b-u 83210 59 1 30.0 30.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75 #:en 75.0
               #:orders (list (sc2-unit-order 1006 #f 0 0.25))))
  (define l63b-sen-near (mk-l63b-u 83211 77 1 35.0 30.0 #:hp 40.0 #:sh 40.0 #:rad 0.5 #:en 25.0))
  (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
  (define l63b-chrono-on-cd
    (chrono-3755-cmds
     (saturate-workers-and-gas-commands
      (make-test-obs 5110 100 50 (list l63b-nx-prb-75 l63b-sen-near l63b-min)))))
  ;; At `+1344f` (`6354`), `4126` unlocks cleanly and emits again at Tier P1 (including direct action form)!
  (define l63b-emit-6354
    (er-4126-cmds
     (translate-bot-actions->sc2-raw-commands
      '((nexus-energy-recharge 83201 83203))
      (make-test-obs 6354 100 50 (list l63b-nx-50 l63b-sen-166)))))
  ;; Rewind (`cur-loop = 4`) & `reset-sc2-live-response-data!` reset `SC2-NEXUS-RECHARGE-LAST-LOOP`!
  (define l63b-cd-after-6354? (sc2-nexus-recharge-cooldown-ready? 6400))
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 100 50 (list l63b-min))))
  (define l63b-ready-after-rewind? (sc2-nexus-recharge-cooldown-ready? 500))
  (set-box! SC2-NEXUS-RECHARGE-LAST-LOOP 5000)
  (reset-sc2-live-response-data!)
  (define l63b-ready-after-reset? (sc2-nexus-recharge-cooldown-ready? 5100))
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 0 (list l63b-min))))
  (check-true "l63b-nexus-recharge-4126-edge-to-edge-p1-1344f-cd-and-sec6b-handoff"
              (and (null? l63b-rej-cmds)
                   l63b-ready-after-rej?
                   (= (length l63b-emit-5010) 1)
                   (macro-econ-cmd? (first l63b-emit-5010))
                   (= (wire-cmd-priority-tier (first l63b-emit-5010)) 1)
                   (not l63b-ready-5100?)
                   (not l63b-ready-6353?)
                   l63b-ready-6354?
                   (null? l63b-blocked-5100)
                   (= (length l63b-chrono-on-cd) 1)
                   (= (length l63b-emit-6354) 1)
                   (macro-econ-cmd? (first l63b-emit-6354))
                   (= (wire-cmd-priority-tier (first l63b-emit-6354)) 1)
                   (not l63b-cd-after-6354?)
                   l63b-ready-after-rewind?
                   l63b-ready-after-reset?)))

(printf "[Loop 64 Lane C] Testing #1787 L0 live-data predicates, 3-mine centroid Scan 399, 12a 2-detector spread, <4:30 Bunker P0 repair, 1733->1694 Creep Tumor spread, & Supply Drop 255 P1...\n")
(let ()
  (define (mk-l64-u tag utype alliance x y
                    #:hp [hp 100.0] #:hp-max [hp-max hp] #:sh [sh 0.0] #:rad [rad 1.0]
                    #:en [en 0.0] #:en-max [en-max 200.0] #:bp [bp 1.0]
                    #:fly [fly? #f] #:burr [burr? #f] #:cloak [cloak 0]
                    #:orders [ords '()] #:mins [mins 0])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 2)
              (sc2-point3d x y (if fly? 12.0 8.0)) 0.0 rad bp cloak #f #f burr?
              hp hp-max sh sh en en-max mins 0 fly? #f #f #t #f
              ords 0 '() 0 0 0.0 0 0 0 0 '() 0 0))
  (define l64-min (mk-l64-u 84001 341 3 23.0 30.0 #:mins 1500 #:en 0.0 #:en-max 0.0))

  ;; L64-C0: L0 `lib/sc2-game-constants.rkt` owns `sc2-ability-live-available?`,
  ;;         `sc2-upgrade-defined-in-live-data?`, `sc2-upgrade-live-available?`, and
  ;;         `sc2-nexus-recharge-cooldown-ready?` (re-exported identically from `sc2-protobuf-ws.rkt`)
  ;;         and populates cleanly via `register-sc2-response-data!`!
  (reset-sc2-live-response-data!)
  (define l0-avail-fn l0:sc2-ability-live-available?)
  (define l0-upg-fn   l0:sc2-upgrade-defined-in-live-data?)
  (define l0-rech-fn  l0:sc2-nexus-recharge-cooldown-ready?)
  (define l64-data
    (sc2-data (list (sc2-ability-data-entry 4107 "BatteryOvercharge" #f)
                    (sc2-ability-data-entry 4126 "EnergyRecharge" #t)
                    (sc2-ability-data-entry 255 "SupplyDrop" #t))
              '()
              (list (sc2-upgrade-data-entry 84 "WarpGateResearch" 50 50 1120 1568))
              '() '()))
  (register-sc2-response-data! l64-data)
  (define l64-c0-live-4107? (l0-avail-fn 4107))
  (define l64-c0-live-4126? (l0-avail-fn 4126))
  (define l64-c0-live-wg?   (l0-upg-fn 'warp-gate-research))
  (define l64-c0-live-pg?   (l0-upg-fn 'pathogen-glands))
  (record-sc2-nexus-recharge-loop! 5000)
  (define l64-c0-rech-cd?   (l0-rech-fn 5100))
  (reset-sc2-live-response-data!)
  (define l64-c0-reset-ok?  (and (l0-avail-fn 4107) (not (l0-upg-fn 'warp-gate-research)) (l0-rech-fn 5100)))
  (check-true "l64-c0-l0-live-data-predicates-owned-by-constants-and-hydrated"
              (and (eq? l0-avail-fn sc2-ability-live-available?)
                   (eq? l0-upg-fn sc2-upgrade-defined-in-live-data?)
                   (eq? l0-rech-fn sc2-nexus-recharge-cooldown-ready?)
                   (not l64-c0-live-4107?)
                   l64-c0-live-4126?
                   l64-c0-live-wg?
                   (not l64-c0-live-pg?)
                   (not l64-c0-rech-cd?)
                   l64-c0-reset-ok?))

  ;; L64-C1: 3-mine cluster-centroid Scan `399` (`1.5x` weight on burrowed Widow Mines `500`
  ;;         near workers / `>= 3` combat units beats lone distant Banshee & lands on centroid!)
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 100 (list l64-min))))
  (define l64-oc    (mk-l64-u 84101 132 1 30.0 30.0 #:hp 1500.0 #:rad 2.75 #:en 60.0))
  (define l64-scv-w (mk-l64-u 84102 45  1 35.0 30.0 #:hp 45.0   #:rad 0.375 #:en 0.0 #:en-max 0.0))
  (define l64-m-far (mk-l64-u 84103 48  1 68.0 70.0 #:hp 45.0   #:rad 0.375 #:en 0.0 #:en-max 0.0))
  (define l64-wm1   (mk-l64-u 84111 500 4 38.0 30.0 #:hp 0.0    #:hp-max 0.0 #:burr #t #:cloak 1))
  (define l64-wm2   (mk-l64-u 84112 500 4 44.0 30.0 #:hp 0.0    #:hp-max 0.0 #:burr #t #:cloak 1))
  (define l64-wm3   (mk-l64-u 84113 500 4 41.0 35.0 #:hp 0.0    #:hp-max 0.0 #:burr #t #:cloak 1))
  (define l64-bsh   (mk-l64-u 84114 55  4 70.0 70.0 #:hp 0.0    #:hp-max 0.0 #:fly #t #:cloak 1))
  (define l64-scan-cmds
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 399)))
            (translate-bot-actions->sc2-raw-commands
             '()
             (make-test-obs 7000 200 100 (list l64-oc l64-scv-w l64-m-far l64-bsh l64-wm1 l64-wm2 l64-wm3 l64-min)))))
  (define l64-scan-pt (and (= (length l64-scan-cmds) 1)
                           (sc2-raw-unit-command-target-pos (first l64-scan-cmds))))
  (check-true "l64-c1-3-mine-cluster-centroid-scan-399"
              (and (sc2-point2d? l64-scan-pt)
                   (< (abs (- (sc2-point2d-x l64-scan-pt) 41.0)) 0.25)
                   (< (abs (- (sc2-point2d-y l64-scan-pt) 31.6667)) 0.25)
                   (<= (sqrt (+ (sqr (- (sc2-point2d-x l64-scan-pt) 38.0)) (sqr (- (sc2-point2d-y l64-scan-pt) 30.0)))) 4.0)
                   (<= (sqrt (+ (sqr (- (sc2-point2d-x l64-scan-pt) 44.0)) (sqr (- (sc2-point2d-y l64-scan-pt) 30.0)))) 4.0)
                   (<= (sqrt (+ (sqr (- (sc2-point2d-x l64-scan-pt) 41.0)) (sqr (- (sc2-point2d-y l64-scan-pt) 35.0)))) 4.0)))

  ;; L64-C2: Section `12a` 2-detector spread across 2 separated Widow Mines + `-4.0t` WM priority bonus!
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 100 (list l64-min))))
  (define l64-nx    (mk-l64-u 84201 59  1 30.0 30.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75))
  (define l64-obs1  (mk-l64-u 84202 82  1 32.0 30.0 #:hp 40.0   #:sh 20.0   #:fly #t))
  (define l64-obs2  (mk-l64-u 84203 82  1 34.0 30.0 #:hp 40.0   #:sh 20.0   #:fly #t))
  (define l64-wm-a  (mk-l64-u 84211 500 4 45.0 30.0 #:hp 0.0    #:hp-max 0.0 #:burr #t #:cloak 1))
  (define l64-wm-b  (mk-l64-u 84212 500 4 68.0 30.0 #:hp 0.0    #:hp-max 0.0 #:burr #t #:cloak 1))
  (define l64-2det-cmds
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 16)))
            (translate-bot-actions->sc2-raw-commands
             '()
             (make-test-obs 7100 200 100 (list l64-nx l64-obs1 l64-obs2 l64-wm-a l64-wm-b l64-min)))))
  (define l64-2det-xs (sort (map (lambda (c) (sc2-point2d-x (sc2-raw-unit-command-target-pos c))) l64-2det-cmds) <))
  ;; `-4.0t` priority bonus: 1 Observer picks burrowed WM at 42.0 (dist=12, eff=8.0) over DT at 40.0 (dist=10, eff=10.0)!
  (define l64-dt-10 (mk-l64-u 84213 76  4 40.0 30.0 #:hp 0.0    #:hp-max 0.0 #:cloak 1))
  (define l64-wm-12 (mk-l64-u 84214 500 4 30.0 42.0 #:hp 0.0    #:hp-max 0.0 #:burr #t #:cloak 1))
  (define l64-1det-prio
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 16)))
            (translate-bot-actions->sc2-raw-commands
             '()
             (make-test-obs 7120 200 100 (list l64-nx l64-obs1 l64-dt-10 l64-wm-12 l64-min)))))
  (check-true "l64-c2-12a-2-detector-spread-and-widow-mine-4t-priority-bonus"
              (and (= (length l64-2det-cmds) 2)
                   (not (equal? (sc2-raw-unit-command-unit-tags (first l64-2det-cmds))
                                (sc2-raw-unit-command-unit-tags (second l64-2det-cmds))))
                   (< (abs (- (first l64-2det-xs) 45.0)) 2.5)
                   (< (abs (- (second l64-2det-xs) 68.0)) 2.5)
                   (= (length l64-1det-prio) 1)
                   (< (abs (- (sc2-point2d-y (sc2-raw-unit-command-target-pos (first l64-1det-prio))) 42.0)) 2.5)))

  ;; L64-C3: `< 4:30` (`cur-loop < 6048`) damaged Bunker `3685` P0 promotion (`<= 4` SCVs, `22f` cd)
  ;;         vs SCV #5 P2, `>= 4:30` Bunker P2, and non-Bunker Tank P2 (`L60 #1580` preserved!)
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 100 (list l64-min))))
  (define l64-bkr-dmg (mk-l64-u 84301 24 1 35.0 30.0 #:hp 240.0 #:hp-max 400.0 #:en 0.0 #:en-max 0.0))
  (define l64-tnk-dmg (mk-l64-u 84302 33 1 38.0 30.0 #:hp 100.0 #:hp-max 175.0 #:en 0.0 #:en-max 0.0))
  (define l64-scvs-5
    (for/list ([i (in-range 5)])
      (mk-l64-u (+ 84310 i) 45 1 (+ 33.0 (* 0.4 i)) 30.0 #:hp 45.0 #:en 0.0 #:en-max 0.0)))
  (define l64-rep-early5
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 3685)))
            (translate-bot-actions->sc2-raw-commands
             '((repair 84310 84301) (repair 84311 84301) (repair 84312 84301)
               (repair 84313 84301) (repair 84314 84301))
             (make-test-obs 4000 200 100 (append (list l64-bkr-dmg l64-tnk-dmg l64-min) l64-scvs-5)))))
  ;; Within 22f cooldown (4008): SCV 84310 stays P2!
  (define l64-rep-cd
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 3685)))
            (translate-bot-actions->sc2-raw-commands
             '((repair 84310 84301))
             (make-test-obs 4008 200 100 (append (list l64-bkr-dmg l64-min) l64-scvs-5)))))
  ;; After 22f cooldown (4024): SCV 84310 promotes to P0 again!
  (define l64-rep-reopen
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 3685)))
            (translate-bot-actions->sc2-raw-commands
             '((repair 84310 84301))
             (make-test-obs 4024 200 100 (append (list l64-bkr-dmg l64-min) l64-scvs-5)))))
  ;; Non-Bunker (Tank 33) at 4024 stays P2; Bunker at `>= 6048` (`4:30`) stays P2!
  (define l64-rep-tank
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 3685)))
            (translate-bot-actions->sc2-raw-commands
             '((repair 84311 84302))
             (make-test-obs 4024 200 100 (append (list l64-tnk-dmg l64-min) l64-scvs-5)))))
  (define l64-rep-late
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 3685)))
            (translate-bot-actions->sc2-raw-commands
             '((repair 84310 84301))
             (make-test-obs 6048 200 100 (append (list l64-bkr-dmg l64-min) l64-scvs-5)))))
  (check-true "l64-c3-early-damaged-bunker-repair-p0-cap4-22f-cd-vs-p2-default"
              (and (= (length l64-rep-early5) 5)
                   (= (count (lambda (c) (= (wire-cmd-priority-tier c) 0)) l64-rep-early5) 4)
                   (= (count (lambda (c) (= (wire-cmd-priority-tier c) 2)) l64-rep-early5) 1)
                   (= (length l64-rep-cd) 1)
                   (= (wire-cmd-priority-tier (first l64-rep-cd)) 2)
                   (= (length l64-rep-reopen) 1)
                   (= (wire-cmd-priority-tier (first l64-rep-reopen)) 0)
                   (= (length l64-rep-tank) 1)
                   (= (wire-cmd-priority-tier (first l64-rep-tank)) 2)
                   (= (length l64-rep-late) 1)
                   (= (wire-cmd-priority-tier (first l64-rep-late)) 2)))

  ;; L64-C4: Zerg Creep Tumor `1733` spread queries `1694` placement (`<= 9.8t`), emits `1733`,
  ;;         and NEVER permanently bans the tumor on an immature or single post-maturity emit!
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 100 (list l64-min))))
  (hash-clear! SC2-TUMOR-PLACEMENT-CACHE)
  (set-box! SC2-LAST-TUMOR-RPC-LOOP -9999)
  (define l64-queried-ab-ids (box '()))
  (define l64-queried-pts (box '()))
  (define-values (c4-in s4-out) (make-pipe))
  (define-values (s4-in c4-out) (make-pipe))
  (define c4-ws (sc2-ws-conn "127.0.0.1" 0 "/sc2api" c4-in c4-out #f 1))
  (define c4-thd
    (thread
     (lambda ()
       (let lp ()
         (define hdr2 (read-bytes 2 s4-in))
         (unless (eof-object? hdr2)
           (define b0 (bytes-ref hdr2 0))
           (define b1 (bytes-ref hdr2 1))
           (define opcode (bitwise-and b0 #x0F))
           (define masked? (not (zero? (bitwise-and b1 #x80))))
           (define len7 (bitwise-and b1 #x7F))
           (define plen
             (cond [(< len7 126) len7]
                   [(= len7 126) (integer-bytes->integer (read-bytes 2 s4-in) #f #t)]
                   [else (integer-bytes->integer (read-bytes 8 s4-in) #f #t)]))
           (define mkey (if masked? (read-bytes 4 s4-in) #f))
           (define raw (read-bytes plen s4-in))
           (define payload (if masked? (mask-ws-payload raw mkey) raw))
           (when (= opcode 2)
             (define req-f (decode-protobuf-message payload))
             (define req-id-p (assoc 97 req-f))
             (define id-b (if req-id-p (encode-uint32 97 (third req-id-p)) #""))
             (define q-p (assoc 14 req-f))
             (when q-p
               (define qf (decode-protobuf-message (third q-p)))
               (define p-items (filter (lambda (e) (= (first e) 3)) qf))
               (for ([it (in-list p-items)])
                 (define pf (decode-protobuf-message (third it)))
                 (define ab-f (assoc 1 pf))
                 (define pt-f (assoc 2 pf))
                 (when ab-f
                   (set-box! l64-queried-ab-ids (cons (third ab-f) (unbox l64-queried-ab-ids))))
                 (when pt-f
                   (define ptf (decode-protobuf-message (third pt-f)))
                   (define xf (assoc 1 ptf))
                   (define yf (assoc 2 ptf))
                   (when (and xf yf)
                     (set-box! l64-queried-pts
                               (cons (cons (floating-point-bytes->real (third xf) #f)
                                           (floating-point-bytes->real (third yf) #f))
                                     (unbox l64-queried-pts))))))
               (define res-b
                 (apply bytes-append
                        (for/list ([_it (in-list p-items)])
                          (encode-submessage-field 3 (encode-int32 1 1)))))
               (define resp (bytes-append (encode-submessage-field 14 res-b) id-b (encode-int32 99 3)))
               (define rlen (bytes-length resp))
               (define rhdr
                 (cond [(< rlen 126) (bytes #x82 rlen)]
                       [(<= rlen 65535) (bytes-append (bytes #x82 126) (integer->integer-bytes rlen 2 #f #t))]
                       [else (bytes-append (bytes #x82 127) (integer->integer-bytes rlen 8 #f #t))]))
               (write-bytes rhdr s4-out)
               (write-bytes resp s4-out)
               (flush-output s4-out))
             (lp)))))))
  (define l64-hatch (mk-l64-u 84401 86  1 32.5 32.5 #:hp 1500.0 #:rad 2.75))
  (define l64-tumor (mk-l64-u 84402 137 1 40.0 34.0 #:hp 50.0   #:rad 0.5 #:burr #t))
  (define l64-used-tumors (mutable-seteqv))
  ;; Immature emit at 5000 (age=0 < 264): queries 1694, emits 1733, MUST NOT ban in `used-tumors`!
  (define l64-t-e0
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1733)))
            (translate-bot-actions->sc2-raw-commands
             '((cast 84402 spread-creep-tumor 48.0 34.0))
             (make-test-obs 5000 300 100 (list l64-hatch l64-tumor))
             #:ws-conn c4-ws #:game-info w3-ginfo #:used-creep-tumors l64-used-tumors)))
  (define l64-used-after-e0? (set-member? l64-used-tumors 84402))
  ;; Post-maturity emit #1 at 5264 (`age = 264 >= 264`): emits 1733, still NOT in `used-tumors` (`cnt = 1`)!
  (define l64-t-e1
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1733)))
            (translate-bot-actions->sc2-raw-commands
             '((cast 84402 spread-creep-tumor 48.0 34.0))
             (make-test-obs 5264 300 100 (list l64-hatch l64-tumor))
             #:ws-conn c4-ws #:game-info w3-ginfo #:used-creep-tumors l64-used-tumors)))
  (define l64-used-after-e1? (set-member? l64-used-tumors 84402))
  ;; Post-maturity emit #2 at 5308 (`+44f` cooldown): emits 1733, NOW added to `used-tumors` (`cnt = 2`)!
  (define l64-t-e2
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1733)))
            (translate-bot-actions->sc2-raw-commands
             '((cast 84402 spread-creep-tumor 48.0 34.0))
             (make-test-obs 5308 300 100 (list l64-hatch l64-tumor))
             #:ws-conn c4-ws #:game-info w3-ginfo #:used-creep-tumors l64-used-tumors)))
  (define l64-used-after-e2? (set-member? l64-used-tumors 84402))
  (close-output-port c4-out)
  (close-input-port c4-in)
  (thread-wait c4-thd)
  (check-true "l64-c4-creep-tumor-1733-queries-1694-le-9-8t-and-non-premature-used-tumors"
              (and (pair? (unbox l64-queried-ab-ids))
                   (andmap (lambda (id) (= id 1694)) (unbox l64-queried-ab-ids))
                   (pair? (unbox l64-queried-pts))
                   (andmap (lambda (p)
                             (<= (sqrt (+ (sqr (- (car p) 40.0)) (sqr (- (cdr p) 34.0)))) 9.8))
                           (unbox l64-queried-pts))
                   (= (length l64-t-e0) 1)
                   (not l64-used-after-e0?)
                   (= (length l64-t-e1) 1)
                   (not l64-used-after-e1?)
                   (= (length l64-t-e2) 1)
                   l64-used-after-e2?))

  ;; L64-C5: Terran Supply Drop (`calldown-extra-supplies` / `supply-drop` -> SC2 `255` Tier P1)
  ;;         + already-dropped Depot (`health-max >= 500` or duplicate tag) guard!
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 100 (list l64-min))))
  (define l64-sd-oc1   (mk-l64-u 84501 132 1 30.0 30.0 #:hp 1500.0 #:rad 2.75 #:en 75.0))
  (define l64-sd-oc2   (mk-l64-u 84504 132 1 55.0 30.0 #:hp 1500.0 #:rad 2.75 #:en 60.0))
  (define l64-sd-dep1  (mk-l64-u 84502 19  1 34.0 30.0 #:hp 400.0  #:hp-max 400.0 #:en 0.0 #:en-max 0.0))
  (define l64-sd-dep2  (mk-l64-u 84503 19  1 36.0 30.0 #:hp 500.0  #:hp-max 500.0 #:en 0.0 #:en-max 0.0))
  (define l64-sd-dep3  (mk-l64-u 84505 47  1 38.0 30.0 #:hp 400.0  #:hp-max 400.0 #:en 0.0 #:en-max 0.0))
  (define l64-sd-cmds
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 255)))
            (translate-bot-actions->sc2-raw-commands
             '((cast-spell 84501 calldown-extra-supplies 84502)
               (cast-spell 84504 calldown-extra-supplies 84502)
               (cast-spell 84504 calldown-extra-supplies 84503)
               (supply-drop 84504 84505))
             (make-test-obs 7500 200 100 (list l64-sd-oc1 l64-sd-oc2 l64-sd-dep1 l64-sd-dep2 l64-sd-dep3 l64-min)))))
  (check-true "l64-c5-supply-drop-255-p1-and-already-dropped-depot-guard"
              (and (= (length l64-sd-cmds) 2)
                   (andmap macro-econ-cmd? l64-sd-cmds)
                   (andmap (lambda (c) (= (wire-cmd-priority-tier c) 1)) l64-sd-cmds)
                   (equal? (map sc2-raw-unit-command-target-unit-tag l64-sd-cmds) '(84502 84505))))

  ;; Clean final rewind
  (reset-sc2-live-response-data!)
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 0 (list l64-min))))
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 0 (list l64-min)))))

(printf "[Loop 65 Lane C] Testing #1830 Gap C7 cluster-centroid concave arc, 2-prong >=25t APM batching, Banshee-on-workers cloak priority, & Supply Drop 64f retry...\n")
(let ()
  (define (mk-l65-u tag utype alliance x y
                    #:hp [hp 100.0] #:hp-max [hp-max hp] #:sh [sh 0.0] #:rad [rad 1.0]
                    #:en [en 0.0] #:en-max [en-max 200.0] #:bp [bp 1.0]
                    #:fly [fly? #f] #:burr [burr? #f] #:cloak [cloak 0] #:mins [mins 0])
    (sc2-unit 1 alliance tag utype (if (= alliance 1) 1 2)
              (sc2-point3d x y (if fly? 12.0 8.0)) 0.0 rad bp cloak #f #f burr?
              hp hp-max sh sh en en-max mins 0 fly? #f #f #t #f
              '() 0 '() 0 0 0.0 0 0 0 0 '() 0 0))
  (define l65-min (mk-l65-u 85001 341 3 23.0 30.0 #:mins 1500 #:en 0.0 #:en-max 0.0))

  ;; L65-C1 (Gap C7): `'form-concave-arc` orients arc from approaching cluster centroid
  ;;         (north of enemy `(90, 100)` -> `(90, 90)`) instead of hardcoded `home-x/y = (30, 30)`,
  ;;         and triggers on `1.4t` neighbor spacing (`< 1.65t` new cap, `> 1.15t` old cap)!
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 100 (list l65-min))))
  (define l65-th-sw (mk-l65-u 85100 59 1 30.0 30.0 #:hp 1000.0 #:sh 1000.0 #:rad 2.75))
  (define l65-stks-n
    (list (mk-l65-u 85101 74 1 88.6 100.0 #:hp 80.0 #:sh 80.0)
          (mk-l65-u 85102 74 1 90.0 100.0 #:hp 80.0 #:sh 80.0)
          (mk-l65-u 85103 74 1 91.4 100.0 #:hp 80.0 #:sh 80.0)
          (mk-l65-u 85104 74 1 90.0 101.4 #:hp 80.0 #:sh 80.0)))
  (define l65-enemy-mid (mk-l65-u 85110 48 4 90.0 90.0 #:hp 45.0))
  (define l65-arc-cmds
    (filter (lambda (c)
              (and (sc2-raw-unit-command? c)
                   (= (sc2-raw-unit-command-ability-id c) 23)
                   (sc2-point2d? (sc2-raw-unit-command-target-pos c))))
            (translate-bot-actions->sc2-raw-commands
             '((form-concave-arc 90.0 90.0 8.0 120))
             (make-test-obs 7200 200 100 (append (list l65-th-sw l65-enemy-mid l65-min) l65-stks-n)))))
  (check-true "l65-c1-form-concave-arc-uses-cluster-centroid-angle-and-1-65t-spacing"
              (and (= (length l65-arc-cmds) 4)
                   (andmap (lambda (c)
                             (> (sc2-point2d-y (sc2-raw-unit-command-target-pos c)) 92.0))
                           l65-arc-cmds)))

  ;; L65-C2: Simultaneous 2-prong attacks (`>= 25t` apart: 10-unit Main Army at `(140, 40)` +
  ;;         4-unit Runby at `(40, 140)`) NEVER coalesce AND BOTH emit in the SAME step even
  ;;         under tight APM governor tokens (`tokens < 6.0` where old `max-count = 1` dropped Prong B)!
  (define l65-prong-a (sc2-raw-unit-command 23 (sc2-point2d 140.0 40.0) 0 (for/list ([i (in-range 10)]) (+ 85200 i)) #f))
  (define l65-prong-b (sc2-raw-unit-command 23 (sc2-point2d 40.0 140.0) 0 (for/list ([i (in-range 4)])  (+ 85220 i)) #f))
  (define l65-coal (coalesce-sc2-raw-commands (list l65-prong-a l65-prong-b) (seteqv 16 23) #f))
  (define l65-gov (make-wire-apm-governor #:target-apm 410.0 #:hard-cap-apm 485.0 #:burst-capacity 3.5))
  ;; Warm P1 at loop 196 so `1a-pre` overdue P1 doesn't run before `1b`, leaving `tokens < 6.0`!
  (void (govern-sc2-wire-actions! l65-gov (list (sc2-raw-unit-command 1343 #f 0 '(85239) #f)) 196))
  (define l65-p1-noise
    (for/list ([i (in-range 4)])
      (sc2-raw-unit-command 1343 #f 0 (list (+ 85240 i)) #f)))
  (define l65-gov-out
    (govern-sc2-wire-actions! l65-gov (append l65-p1-noise (list l65-prong-a l65-prong-b)) 200))
  (define l65-emitted-23
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 23))) l65-gov-out))
  (check-true "l65-c2-two-prong-25t-apart-never-coalesce-and-both-emit-under-tight-tokens"
              (and (= (length l65-coal) 2)
                   (= (length l65-emitted-23) 2)
                   (ormap (lambda (c) (= (sc2-point2d-x (sc2-raw-unit-command-target-pos c)) 140.0)) l65-emitted-23)
                   (ormap (lambda (c) (= (sc2-point2d-x (sc2-raw-unit-command-target-pos c)) 40.0)) l65-emitted-23)))

  ;; L65-C3: Live Cloaked Banshee (`55`) raiding workers beats distant Widow Mine (`500`) for
  ;;         BOTH `12a` 1-detector intercept AND `399` 1-OC Scan; plus Supply Drop `255` `64f`
  ;;         refractory allows retry when Depot is still `400.0` max-HP & blocks at `500.0` max-HP!
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 100 (list l65-min))))
  (define l65-oc   (mk-l65-u 85301 132 1 30.0 30.0 #:hp 1500.0 #:rad 2.75 #:en 60.0))
  (define l65-scv  (mk-l65-u 85302 45  1 26.0 30.0 #:hp 45.0   #:rad 0.375 #:en 0.0 #:en-max 0.0))
  (define l65-mar  (mk-l65-u 85303 48  1 54.0 30.0 #:hp 45.0   #:rad 0.375 #:en 0.0 #:en-max 0.0))
  (define l65-obs  (mk-l65-u 85304 82  1 40.0 30.0 #:hp 40.0   #:sh 20.0   #:fly #t))
  (define l65-bsh  (mk-l65-u 85311 55  4 26.0 34.0 #:hp 0.0    #:hp-max 0.0 #:fly #t #:cloak 1))
  (define l65-wm   (mk-l65-u 85312 500 4 56.0 30.0 #:hp 0.0    #:hp-max 0.0 #:burr #t #:cloak 1))
  (define l65-cloak-cmds
    (translate-bot-actions->sc2-raw-commands
     '()
     (make-test-obs 7400 200 100 (list l65-oc l65-scv l65-mar l65-obs l65-bsh l65-wm l65-min))))
  (define l65-12a-mv (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 16))) l65-cloak-cmds))
  (define l65-399-sc (findf (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 399))) l65-cloak-cmds))
  (define l65-dep-400 (mk-l65-u 85320 19 1 34.0 30.0 #:hp 400.0 #:hp-max 400.0 #:en 0.0 #:en-max 0.0))
  (define l65-dep-500 (mk-l65-u 85320 19 1 34.0 30.0 #:hp 500.0 #:hp-max 500.0 #:en 0.0 #:en-max 0.0))
  (define (sd-cnt cmds)
    (count (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 255))) cmds))
  (define sd-t0 (sd-cnt (translate-bot-actions->sc2-raw-commands '((cast-spell 85301 calldown-extra-supplies 85320)) (make-test-obs 8000 200 100 (list l65-oc l65-dep-400 l65-min)))))
  (define sd-t32 (sd-cnt (translate-bot-actions->sc2-raw-commands '((cast-spell 85301 calldown-extra-supplies 85320)) (make-test-obs 8032 200 100 (list l65-oc l65-dep-400 l65-min)))))
  (define sd-t64 (sd-cnt (translate-bot-actions->sc2-raw-commands '((cast-spell 85301 calldown-extra-supplies 85320)) (make-test-obs 8064 200 100 (list l65-oc l65-dep-400 l65-min)))))
  (define sd-t140-upg (sd-cnt (translate-bot-actions->sc2-raw-commands '((cast-spell 85301 calldown-extra-supplies 85320)) (make-test-obs 8140 200 100 (list l65-oc l65-dep-500 l65-min)))))
  (check-true "l65-c3-banshee-on-workers-beats-mine-and-supply-drop-64f-retry"
              (and l65-12a-mv
                   (< (abs (- (sc2-point2d-x (sc2-raw-unit-command-target-pos l65-12a-mv)) 26.0)) 3.0)
                   l65-399-sc
                   (< (abs (- (sc2-point2d-x (sc2-raw-unit-command-target-pos l65-399-sc)) 26.0)) 1.0)
                   (= sd-t0 1)
                   (= sd-t32 0)
                   (= sd-t64 1)
                   (= sd-t140-upg 0)))

  ;; L65-C4 (Addendum `#1844` — Steven's Directive): Pure `point-blocks-canonical-townhall?`
  ;;         (`<= 3.6t` Chebyshev box) + BOTH Queen initial Creep Tumor (`1694`) AND Tumor-to-Tumor
  ;;         spread (`1733`) reject coordinates inside a canonical expansion TownHall `3.6t` box
  ;;         and cleanly pick a safe adjacent point outside the box (even across cached map pads)!
  (define l65-exp-pad (cons 50.5 34.5))
  (define l65-exp-locs (list l65-exp-pad (cons 80.5 34.5)))
  (check-true "l65-c4a-point-blocks-canonical-townhall-helper"
              (and (point-blocks-canonical-townhall? 50.5 34.5 l65-exp-locs)
                   (point-blocks-canonical-townhall? 54.0 38.0 l65-exp-locs) ;; dx=3.5, dy=3.5 <= 3.6 -> blocked!
                   (not (point-blocks-canonical-townhall? 54.5 34.5 l65-exp-locs)) ;; dx=4.0 > 3.6 -> clear!
                   (not (point-blocks-canonical-townhall? 50.5 34.5 l65-exp-locs (list l65-exp-pad)))))
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 100 (list l65-min))))
  (hash-clear! SC2-TUMOR-PLACEMENT-CACHE)
  (set-box! SC2-CACHED-MAP-BASE-CLUSTERS (list (list 50.5 34.5 '()) (list 80.5 34.5 '())))
  ;; Queen (`126`) near expansion `(50.5, 34.5)` instructed to place `1694` directly ON `(50.5, 34.5)`
  ;; -> MUST NOT emit inside `3.6t` box and MUST pick a safe spot outside `3.6t`!
  (define l65-ht-exp (mk-l65-u 85401 86  1 42.5 34.5 #:hp 1500.0 #:rad 2.75))
  (define l65-qn-exp (mk-l65-u 85402 126 1 46.0 34.5 #:hp 175.0  #:rad 0.875 #:en 50.0))
  (define l65-tm-exp (mk-l65-u 85403 137 1 44.0 34.5 #:hp 50.0   #:rad 0.5 #:burr #t))
  (define l65-qn-cmds
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1694)))
            (translate-bot-actions->sc2-raw-commands
             '((cast 85402 spawn-creep-tumor 50.5 34.5))
             (make-test-obs 7600 300 100 (list l65-ht-exp l65-qn-exp l65-min))
             #:game-info w3-ginfo)))
  (define l65-qn-pt (and (= (length l65-qn-cmds) 1) (sc2-raw-unit-command-target-pos (first l65-qn-cmds))))
  ;; Burrowed Tumor (`137`) spreading `1733` directly ON `(50.5, 34.5)` (and `(52.5, 36.5)` inside box)
  ;; -> MUST NOT emit inside `3.6t` box and MUST pick a safe spot outside `3.6t` (still `<= 9.8t`)!
  (define l65-tm-cmds
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1733)))
            (translate-bot-actions->sc2-raw-commands
             '((cast 85403 spread-creep-tumor 50.5 34.5))
             (make-test-obs 7648 300 100 (list l65-ht-exp l65-tm-exp l65-min))
             #:game-info w3-ginfo)))
  (define l65-tm-pt (and (= (length l65-tm-cmds) 1) (sc2-raw-unit-command-target-pos (first l65-tm-cmds))))
  (check-true "l65-c4b-queen-1694-and-tumor-1733-never-block-canonical-expansion-3-6t-box"
              (and (sc2-point2d? l65-qn-pt)
                   (not (point-blocks-canonical-townhall? (sc2-point2d-x l65-qn-pt)
                                                          (sc2-point2d-y l65-qn-pt)
                                                          l65-exp-locs))
                   (sc2-point2d? l65-tm-pt)
                   (not (point-blocks-canonical-townhall? (sc2-point2d-x l65-tm-pt)
                                                          (sc2-point2d-y l65-tm-pt)
                                                          l65-exp-locs))
                   (<= (sqrt (+ (sqr (- (sc2-point2d-x l65-tm-pt) 44.0))
                                (sqr (- (sc2-point2d-y l65-tm-pt) 34.5))))
                       9.8)))

  ;; L65D Lane 3 (`#1891`/`#1892`):
  ;;   1. `claim-combat-tags-for-order!` emits explicit per-unit combat/tactical orders for
  ;;      `'strike-group` (55), `'staging-group` (50), and `'spotter` (68) leases while strictly
  ;;      blocking non-combat utility leases (`'builder` 100, `'door-guard` 90, `'scout` 70, `'creep-queen` 65),
  ;;      and keeping generic idle wire sweeps (`combat-units` at `'army`) from hijacking leased units!
  ;;   2. Phased Warp Prism `(warp-in wgid 'zealot wx wy)` over Zerg creep (`pl-grid = 0, path-grid = 1`)
  ;;      warps under the Prism instead of silently falling back to a home Pylon, while still rejecting
  ;;      unpathable cliffs (`path-grid = 0`).
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 100 (list l65-min))))
  (define l65d-leases (make-hasheqv))
  (acquire-unit-lease! l65d-leases 86001 'strike-group  8000 40 #:x 90.0 #:y 90.0)
  (acquire-unit-lease! l65d-leases 86002 'staging-group 8000 40 #:x 88.0 #:y 88.0)
  (acquire-unit-lease! l65d-leases 86003 'spotter       8000 40 #:x 95.0 #:y 95.0)
  (acquire-unit-lease! l65d-leases 86004 'strike-group  8000 40 #:x 92.0 #:y 92.0)
  (acquire-unit-lease! l65d-leases 86011 'builder       8000 40 #:x 30.0 #:y 30.0)
  (acquire-unit-lease! l65d-leases 86012 'door-guard    8000 40 #:x 34.0 #:y 34.0)
  (acquire-unit-lease! l65d-leases 86013 'scout         8000 40 #:x 70.0 #:y 70.0)
  (acquire-unit-lease! l65d-leases 86014 'creep-queen   8000 40 #:x 40.0 #:y 40.0)
  (define l65d-lease-units
    (list (mk-l65-u 86000 59  1 24.0 24.0 #:hp 1000.0 #:rad 2.75) ;; Nexus
          (mk-l65-u 86001 81  1 32.0 32.0 #:hp 80.0   #:rad 0.75 #:fly #t) ;; WarpPrism (strike-group)
          (mk-l65-u 86002 74  1 34.0 32.0 #:hp 80.0   #:rad 0.625) ;; Stalker (staging-group)
          (mk-l65-u 86003 82  1 36.0 32.0 #:hp 40.0   #:rad 0.5 #:fly #t) ;; Observer (spotter)
          (mk-l65-u 86004 74  1 38.0 32.0 #:hp 80.0   #:rad 0.625) ;; Stalker (strike-group)
          (mk-l65-u 86005 74  1 40.0 32.0 #:hp 80.0   #:rad 0.625) ;; Unleased Stalker
          (mk-l65-u 86011 84  1 26.0 26.0 #:hp 20.0   #:rad 0.375) ;; Probe (builder)
          (mk-l65-u 86012 73  1 30.0 30.0 #:hp 100.0  #:rad 0.5)   ;; Zealot (door-guard)
          (mk-l65-u 86013 84  1 28.0 26.0 #:hp 20.0   #:rad 0.375) ;; Probe (scout)
          (mk-l65-u 86014 126 1 32.0 26.0 #:hp 175.0  #:rad 0.875) ;; Queen (creep-queen)
          (mk-l65-u 86999 74  4 50.0 50.0 #:hp 80.0   #:rad 0.625) ;; Visible enemy Stalker
          l65-min))
  (define l65d-lease-cmds
    (translate-bot-actions->sc2-raw-commands
     '((move 86001 90.0 90.0)
       (attack-pos 86002 88.0 88.0)
       (move 86003 95.0 95.0)
       (attack-unit 86004 86999)
       (move 86011 80.0 80.0)
       (attack-pos 86012 85.0 85.0)
       (move 86013 75.0 75.0)
       (attack-pos 86014 85.0 85.0))
     (make-test-obs 8000 400 200 l65d-lease-units)
     #:game-info w3-ginfo
     #:role-leases l65d-leases))
  (define (l65d-has-cmd? cmds tag ab)
    (ormap (lambda (c)
             (and (sc2-raw-unit-command? c)
                  (= (sc2-raw-unit-command-ability-id c) ab)
                  (memv tag (sc2-raw-unit-command-unit-tags c))))
           cmds))
  (define (l65d-any-cmd-for? cmds tag)
    (ormap (lambda (c)
             (and (sc2-raw-unit-command? c)
                  (memv tag (sc2-raw-unit-command-unit-tags c))))
           cmds))
  ;; Verify generic wire army sweep does NOT hijack leased tactical units (`combat-units` stays at `'army`)
  (define l65d-sweep-cmds
    (translate-bot-actions->sc2-raw-commands
     '((attack-enemy 85.0 85.0))
     (make-test-obs 8008 400 200 l65d-lease-units)
     #:game-info w3-ginfo
     #:role-leases l65d-leases))
  (check-true "l65d-c1-tactical-leases-emit-explicit-orders-while-utility-leases-blocked"
              (and (l65d-has-cmd? l65d-lease-cmds 86001 16)
                   (l65d-has-cmd? l65d-lease-cmds 86002 23)
                   (l65d-has-cmd? l65d-lease-cmds 86003 16)
                   (l65d-has-cmd? l65d-lease-cmds 86004 23)
                   (not (l65d-any-cmd-for? l65d-lease-cmds 86011))
                   (not (l65d-any-cmd-for? l65d-lease-cmds 86012))
                   (not (l65d-any-cmd-for? l65d-lease-cmds 86013))
                   (not (l65d-any-cmd-for? l65d-lease-cmds 86014))
                   (l65d-has-cmd? l65d-sweep-cmds 86005 23)
                   (not (l65d-any-cmd-for? l65d-sweep-cmds 86001))
                   (not (l65d-any-cmd-for? l65d-sweep-cmds 86002))
                   (not (l65d-any-cmd-for? l65d-sweep-cmds 86003))
                   (not (l65d-any-cmd-for? l65d-sweep-cmds 86004))))

  ;; L65D-C2: Phased Warp Prism over Zerg creep (`pl-grid = 0, path-grid = 1`) warps under Prism,
  ;; while unpathable chasm (`path-grid = 0`) remains strictly rejected!
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 100 (list l65-min))))
  (define l65d-path-bytes (make-bytes (* 128 128) 1))
  (define l65d-pl-bytes   (make-bytes (* 128 128) 0))
  (for* ([y (in-range 128)] [x (in-range 128)])
    (when (>= x 110) (bytes-set! l65d-path-bytes (+ x (* y 128)) 0)) ;; cliff/chasm at x >= 110
    (when (< x 50)   (bytes-set! l65d-pl-bytes   (+ x (* y 128)) 1))) ;; creep (pl=0) for x >= 50
  (define l65d-gi
    (sc2-game-info "L65DCreepWarpMap" "" '() '(128 . 128) '(4 4 124 124) '()
                   (sc2-image-grid 8 128 128 l65d-path-bytes #f #f)
                   #f
                   (sc2-image-grid 8 128 128 l65d-pl-bytes #f #f)))
  (define l65d-warp-obs
    (sc2-observation
     8100
     (sc2-player-common 1 600 200 60 100 30 30 0 10 2 0)
     (list (mk-l65-u 86100 59  1 24.0 24.0 #:hp 1000.0 #:rad 2.75) ;; Home Nexus
           (mk-l65-u 86102 60  1 28.0 24.0 #:hp 200.0  #:rad 1.0)  ;; Home Pylon (pl=1)
           (mk-l65-u 86101 133 1 20.0 28.0 #:hp 500.0  #:rad 1.5)  ;; WarpGate #1
           (mk-l65-u 86104 133 1 23.0 28.0 #:hp 500.0  #:rad 1.5)  ;; WarpGate #2
           (mk-l65-u 86103 136 1 92.0 92.0 #:hp 80.0   #:rad 0.75 #:fly #t)) ;; Phased Prism on creep (pl=0, path=1)
     '(84)
     (list (sc2-power-source (sc2-point3d 28.0 24.0 8.0) 6.5  86102)
           (sc2-power-source (sc2-point3d 92.0 92.0 8.0) 3.75 86103))
     (sc2-point3d 24.0 24.0 0.0) '() '() '() '() '() '()))
  (define l65d-warp-cmds
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1413)))
            (translate-bot-actions->sc2-raw-commands
             '((warp-in 86101 zealot 92.0 92.0))
             l65d-warp-obs
             #:game-info l65d-gi)))
  (define l65d-warp-pt
    (and (= (length l65d-warp-cmds) 1)
         (sc2-raw-unit-command-target-pos (first l65d-warp-cmds))))
  ;; Unpathable chasm prism at x=115 (`path=0, pl=0`) MUST NOT warp onto chasm (`x < 110`)
  (define l65d-chasm-obs
    (sc2-observation
     8140
     (sc2-player-common 1 600 200 60 100 30 30 0 10 2 0)
     (list (mk-l65-u 86100 59  1 24.0 24.0 #:hp 1000.0 #:rad 2.75)
           (mk-l65-u 86102 60  1 28.0 24.0 #:hp 200.0  #:rad 1.0)
           (mk-l65-u 86104 133 1 23.0 28.0 #:hp 500.0  #:rad 1.5)
           (mk-l65-u 86105 136 1 115.0 92.0 #:hp 80.0  #:rad 0.75 #:fly #t)) ;; Phased Prism over unpathable chasm!
     '(84)
     (list (sc2-power-source (sc2-point3d 28.0 24.0 8.0) 6.5  86102)
           (sc2-power-source (sc2-point3d 115.0 92.0 8.0) 3.75 86105))
     (sc2-point3d 24.0 24.0 0.0) '() '() '() '() '() '()))
  (define l65d-chasm-cmds
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 1413)))
            (translate-bot-actions->sc2-raw-commands
             '((warp-in 86104 zealot 115.0 92.0))
             l65d-chasm-obs
             #:game-info l65d-gi)))
  (define l65d-chasm-pt
    (and (= (length l65d-chasm-cmds) 1)
         (sc2-raw-unit-command-target-pos (first l65d-chasm-cmds))))
  (check-true "l65d-c2-phased-warp-prism-over-creep-warps-at-prism-and-rejects-unpathable-chasm"
              (and (sc2-point2d? l65d-warp-pt)
                   (<= (sqrt (+ (sqr (- (sc2-point2d-x l65d-warp-pt) 92.0))
                                (sqr (- (sc2-point2d-y l65d-warp-pt) 92.0))))
                       3.5)
                   (sc2-point2d? l65d-chasm-pt)
                   (< (sc2-point2d-x l65d-chasm-pt) 110.0)))

  ;; Loop 66 Lane C (`#1989`): Pre-translation Scan-vs-MULE upfront preemption (emergency + auto-pick),
  ;; scout-vs-detector upfront preemption (zero stale scout MOVE 16), & `#:gas-starvation-boost? #t`
  ;; end-to-end through `saturate-workers-and-gas-commands`!
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 0 (list l65-min))))
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 0 (list l65-min))))

  ;; L66-C1: Same-step explicit MULE + Emergency Scan (and symbol auto-pick Scan) on same OC
  ;;         emits ONLY `399` Scan and NEVER emits `171` MULE (zero retroactive wire-buffer strip).
  (define l66-oc   (mk-l65-u 86601 132 1 30.0 30.0 #:hp 1500.0 #:rad 2.75 #:en 55.0))
  (define l66-mar  (mk-l65-u 86602 48  1 34.0 30.0 #:hp 45.0   #:rad 0.375 #:en 0.0 #:en-max 0.0))
  (define l66-dt   (mk-l65-u 86603 76  4 39.0 30.0 #:hp 0.0    #:hp-max 40.0 #:en 0.0 #:en-max 0.0 #:cloak 1))
  (define l66-min1 (sc2-unit 1 3 86609 341 0 (sc2-point3d 25.0 30.0 8.0) 0.0 1.0 1.0 0 #f #t #f
                             1000.0 1000.0 0.0 0.0 0.0 0.0 1500 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0 '() 0 0))
  (define l66-emerg-cmds
    (translate-bot-actions->sc2-raw-commands
     '((cast-spell 86601 calldown-mule 86609))
     (make-test-obs 9000 200 100 (list l66-oc l66-mar l66-dt l66-min1))
     #:arbiter-ledger (make-arbiter-ledger)))
  (define l66-autopick-cmds
    (translate-bot-actions->sc2-raw-commands
     '((cast-spell 86601 calldown-mule 86609)
       (cast-spell orbital-command scanner-sweep 42.0 30.0))
     (make-test-obs 9200 200 100 (list l66-oc l66-mar l66-min1))
     #:arbiter-ledger (make-arbiter-ledger)))
  (check-true "l66-c1-same-step-mule-and-scan-upfront-preemption-emergency-and-autopick"
              (and (= (count (lambda (c) (and (sc2-raw-unit-command? c)
                                              (= (sc2-raw-unit-command-ability-id c) 399)
                                              (urgent-survival-cmd? c)
                                              (equal? (sc2-raw-unit-command-unit-tags c) '(86601))))
                             l66-emerg-cmds)
                      1)
                   (= (count (lambda (c) (and (sc2-raw-unit-command? c)
                                              (= (sc2-raw-unit-command-ability-id c) 171)))
                             l66-emerg-cmds)
                      0)
                   (= (count (lambda (c) (and (sc2-raw-unit-command? c)
                                              (= (sc2-raw-unit-command-ability-id c) 399)
                                              (equal? (sc2-raw-unit-command-unit-tags c) '(86601))))
                             l66-autopick-cmds)
                      1)
                   (= (count (lambda (c) (and (sc2-raw-unit-command? c)
                                              (= (sc2-raw-unit-command-ability-id c) 171)))
                             l66-autopick-cmds)
                      0)))

  ;; L66-C2: Same-step scout `MOVE 16` (`overlord-scout` / `periodic-scout` / `cast-deception-and-scout-spells`)
  ;;         + uncovered cloaked Banshee/DT emits ONLY P0 detector intercept (zero stale scout `MOVE 16`!).
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 0 (list l65-min))))
  (define l66-hatch (mk-l65-u 86620 86  1 30.0 30.0 #:hp 1500.0 #:rad 2.75))
  (define l66-ovs   (mk-l65-u 86621 129 1 36.0 32.0 #:hp 200.0  #:rad 1.0  #:fly #t #:en 50.0))
  (define l66-obs   (mk-l65-u 86622 82  1 38.0 32.0 #:hp 40.0   #:sh 20.0  #:rad 0.5 #:fly #t))
  (define l66-ban   (mk-l65-u 86623 55  4 34.0 36.0 #:hp 0.0    #:hp-max 140.0 #:fly #t #:cloak 1))
  (define l66-dt2   (mk-l65-u 86624 76  4 60.0 36.0 #:hp 0.0    #:hp-max 40.0  #:cloak 1))
  (define l66-det-cmds
    (translate-bot-actions->sc2-raw-commands
     '((overlord-scout 86621 160.0 160.0)
       (periodic-scout 86622 160.0 160.0)
       (cast-deception-and-scout-spells))
     (make-test-obs 9300 300 200 (list l66-hatch l66-ovs l66-obs l66-ban l66-dt2 l66-min1))
     #:arbiter-ledger (make-arbiter-ledger)))
  (define l66-det-moves
    (filter (lambda (c) (and (sc2-raw-unit-command? c) (= (sc2-raw-unit-command-ability-id c) 16)))
            l66-det-cmds))
  ;; Also verify a `'detector-escort`-leased Overseer receiving `(move ...)` + `(cast-spell ... morph-oversight-mode)`
  ;; is NOT blocked by `explicit-combat-tags` and emits P0 urgent intercept `MOVE 16` toward the cloaked Banshee!
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 0 (list l65-min))))
  (define l66-leased-det-cmds
    (translate-bot-actions->sc2-raw-commands
     '((cast-spell 86621 morph-oversight-mode)
       (move 86621 105.5 116.5))
     (make-test-obs 9320 300 200 (list l66-hatch l66-ovs l66-ban l66-min1))
     #:role-leases (hasheqv 86621 (unit-role-lease 'detector-escort 75 0 34.0 36.0 9360))
     #:arbiter-ledger (make-arbiter-ledger)))
  (define l66-leased-det-mv
    (findf (lambda (c) (and (sc2-raw-unit-command? c)
                            (= (sc2-raw-unit-command-ability-id c) 16)
                            (memv 86621 (sc2-raw-unit-command-unit-tags c))))
           l66-leased-det-cmds))
  (check-true "l66-c2-same-step-scout-move-and-cloaked-threat-upfront-preemption"
              (and (= (length l66-det-moves) 2)
                   (for/and ([c (in-list l66-det-moves)])
                     (and (urgent-survival-cmd? c)
                          (sc2-point2d? (sc2-raw-unit-command-target-pos c))
                          (< (sc2-point2d-x (sc2-raw-unit-command-target-pos c)) 100.0)))
                   (sc2-raw-unit-command? l66-leased-det-mv)
                   (urgent-survival-cmd? l66-leased-det-mv)
                   (<= (sqrt (+ (sqr (- (sc2-point2d-x (sc2-raw-unit-command-target-pos l66-leased-det-mv)) 34.0))
                                (sqr (- (sc2-point2d-y (sc2-raw-unit-command-target-pos l66-leased-det-mv)) 36.0))))
                       12.0)))

  ;; L66-C3: `#:gas-starvation-boost? #t` flows end-to-end through `saturate-workers-and-gas-commands`:
  ;;         (a) suppresses `< 300G` gas pullback even with hysteresis latch latched,
  ;;         (b) refills `>= 2` workers/step onto a live empty Refinery at `< 300G`!
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 0 (list l66-min1))))
  (define l66-cc1   (sc2-unit 1 1 86640 18 1 (sc2-point3d 30.0 30.0 8.0) 0.0 2.75 1.0 0 #f #t #f
                              1500.0 1500.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #f '() 0 '() 15 16 0.0 0 0 0 0 '() 0 0))
  (define l66-cc2   (sc2-unit 1 1 86641 18 1 (sc2-point3d 62.0 30.0 8.0) 0.0 2.75 1.0 0 #f #t #f
                              1500.0 1500.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #f '() 0 '() 10 16 0.0 0 0 0 0 '() 0 0))
  (define l66-min2  (sc2-unit 1 3 86642 341 0 (sc2-point3d 68.0 30.0 8.0) 0.0 1.0 1.0 0 #f #t #f
                              1000.0 1000.0 0.0 0.0 0.0 0.0 1500 0 #f #f #f #t #f '() 0 '() 0 0 0.0 0 0 0 0 '() 0 0))
  (define l66-ref-3 (sc2-unit 1 1 86643 20 1 (sc2-point3d 25.0 24.0 8.0) 0.0 1.5 1.0 0 #f #t #f
                              500.0 500.0 0.0 0.0 0.0 0.0 0 1800 #f #f #f #t #f '() 0 '() 3 3 0.0 0 0 0 0 '() 0 0))
  (define l66-ref-0 (sc2-unit 1 1 86643 20 1 (sc2-point3d 25.0 24.0 8.0) 0.0 1.5 1.0 0 #f #t #f
                              500.0 500.0 0.0 0.0 0.0 0.0 0 1800 #f #f #f #t #f '() 0 '() 0 3 0.0 0 0 0 0 '() 0 0))
  (define l66-gws
    (for/list ([i (in-range 3)])
      (sc2-unit 1 1 (+ 86650 i) 45 1 (sc2-point3d (+ 25.0 (* 0.2 i)) 25.0 8.0) 0.0 0.375 1.0 0 #f #t #f
                45.0 45.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #f
                (list (sc2-unit-order 295 #f 86643 0.0)) 0 '() 0 0 0.0 0 0 0 0 '() 0 0)))
  (define l66-mws
    (for/list ([i (in-range 16)])
      (sc2-unit 1 1 (+ 86660 i) 45 1 (sc2-point3d (+ 26.0 (* 0.25 (modulo i 4))) (+ 30.0 (* 0.3 (quotient i 4))) 8.0)
                0.0 0.375 1.0 0 #f #t #f
                45.0 45.0 0.0 0.0 0.0 0.0 0 0 #f #f #f #t #f
                (list (sc2-unit-order 295 #f 86609 0.0)) 0 '() 0 0 0.0 0 0 0 0 '() 0 0)))
  (set-box! SC2-GAS-PULL-HYSTERESIS-LATCH #t)
  (define l66-boost-no-pull
    (saturate-workers-and-gas-commands
     (make-test-obs 9400 95 210 (append (list l66-cc1 l66-cc2 l66-ref-3 l66-min1 l66-min2) l66-gws l66-mws))
     #:gas-starvation-boost? #t))
  (define l66-boost-pulled-gas?
    (ormap (lambda (c)
             (and (sc2-raw-unit-command? c)
                  (= (sc2-raw-unit-command-ability-id c) 3666)
                  (ormap (lambda (wt) (memv wt '(86650 86651 86652)))
                         (sc2-raw-unit-command-unit-tags c))))
           l66-boost-no-pull))
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 0 (list l66-min1))))
  (define l66-boost-refill
    (saturate-workers-and-gas-commands
     (make-test-obs 9500 150 80 (append (list l66-cc1 l66-cc2 l66-ref-0 l66-min1 l66-min2) l66-mws))
     #:gas-starvation-boost? #t))
  (define l66-boost-refill-cnt
    (for/sum ([c (in-list l66-boost-refill)]
              #:when (and (sc2-raw-unit-command? c)
                          (= (sc2-raw-unit-command-ability-id c) 3666)
                          (= (sc2-raw-unit-command-target-unit-tag c) 86643)))
      (length (sc2-raw-unit-command-unit-tags c))))
  (check-true "l66-c3-gas-starvation-boost-end-to-end-suppresses-pull-and-refills-2plus"
              (and (not l66-boost-pulled-gas?)
                   (>= l66-boost-refill-cnt 2)))

  ;; Clean final rewind
  (reset-sc2-live-response-data!)
  (void (translate-bot-actions->sc2-raw-commands '() (make-test-obs 4 200 0 (list l65-min))))
  (void (saturate-workers-and-gas-commands (make-test-obs 4 200 0 (list l65-min)))))

(printf "-----------------------------------------------------------------\n")
(printf "Pure-Racket SC2 Protobuf + WebSocket Checks: ~a/~a passed (~a failed)\n"
        (- total-checks failed-checks)
        total-checks
        failed-checks)
(printf "=================================================================\n")

(when (> failed-checks 0)
  (exit 1))
