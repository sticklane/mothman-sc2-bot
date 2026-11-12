#lang racket/base

;; =============================================================================
;; tools/fuzz-sc2-protobuf-output.rkt
;; Adversarial Protobuf Output Differential & Schema Fuzzer (`s2clientprotocol`)
;; =============================================================================
;;
;; Executes 4 deterministic fuzz campaigns (default: 154,000 cases in < 6s):
;;   - Campaign 1 (60,000 cases): Hostile boundary inputs (NaN, +-Inf, -0.0,
;;     subnormals, out-of-bounds floats, negative/overflow uint64 tags, empty or
;;     duplicate tag lists, oneof collisions, mismatched ability target modes,
;;     unknown ability IDs, invalid/overlong UTF-8 strings, wrong Racket types)
;;     across ALL outgoing `encode-*` and `make-request-*` encoders.
;;     Asserts 0 crashes AND 100% of emitted byteframes pass independent
;;     `lib/sc2-proto-wire-verifier.rkt` (`verify-sc2-request-bytes` /
;;     `verify-sc2-action-bytes` / `verify-sc2-point2d-bytes` /
;;     `verify-sc2-point-bytes`).
;;   - Campaign 2 (50,000 cases): Adversarial mutated S-expressions across 45+
;;     bot action heads + corrupted `sc2-observation` & hash game states ->
;;     `translate-bot-actions->sc2-raw-commands` -> `govern-sc2-wire-actions!`
;;     -> `make-request-action`. Asserts 0 crashes AND 100% valid `RequestAction`
;;     protos on the wire.
;;   - Campaign 3 (4,000 steps): Chaos-monkey live `step-live-bot-runtime!`
;;     steps across `Zerg`, `Terran`, `Protoss`, and `Random` (openings, worker
;;     rush/cannon rush/gas steal, walls, expansions, creep/inject/overseers,
;;     siege/widow-mine/MULE/lift-land/addon-swap, warp-in/PsiStorm/Archon/
;;     juggle, T3 transitions, and anti-tie sweeps). Asserts 0 `BotActionReject`s
;;     from our brain, 0 wire drops, and 100% valid `RequestAction` protos!
;;   - Campaign 4 (40,000 cases): Negative binary mutation/corruption differential
;;     tests on `verify-sc2-request-bytes`, `verify-sc2-action-bytes`, and
;;     `decode-typed-sc2-action` (truncated frames, overlong/overflowing varints,
;;     field 0, deprecated wire types 3/4/6/7, unknown field numbers, NaN/Inf/OOB
;;     IEEE-754 float32s, injected dual `oneof` collisions, stripped/zero/dup
;;     `unit_tags`, 1-tag `1766` Archon, and ability target-mode swaps).
;;     Asserts 100% rejection (0 false negatives, 0 crashes)!

(require racket/bytes
         racket/cmdline
         racket/format
         racket/list
         racket/match
         racket/math
         racket/place
         racket/runtime-path
         racket/vector
         "../lib/sc2-typed-commands.rkt"
         "../lib/sc2-protobuf-ws.rkt"
         "../lib/sc2-proto-wire-verifier.rkt"
         "../lib/bot-runtime.rkt")

(provide
 (struct-out proto-fuzz-summary)
 protobuf-fuzz-place-worker
 run-protobuf-output-fuzz-campaigns)

(define-runtime-path SELF-MOD-PATH "fuzz-sc2-protobuf-output.rkt")

(struct proto-fuzz-summary
  (seed
   c1-cases
   c1-valid-frames
   c2-cases
   c2-valid-requests
   c3-steps
   c3-brain-rejects
   c3-wire-drops
   c3-valid-requests
   c4-cases
   c4-rejected
   elapsed-ms)
  #:transparent)

;; =============================================================================
;; 1. Fast Deterministic SplitMix64 PRNG
;; =============================================================================

(define MASK64 #xFFFFFFFFFFFFFFFF)

(define (make-splitmix64 seed)
  (define state (bitwise-and (if (exact-integer? seed) seed #x5C2F022026) MASK64))
  (lambda ()
    (set! state (bitwise-and (+ state #x9E3779B97F4A7C15) MASK64))
    (define z1
      (bitwise-and (* (bitwise-xor state (arithmetic-shift state -30))
                      #xBF58476D1CE4E5B9)
                   MASK64))
    (define z2
      (bitwise-and (* (bitwise-xor z1 (arithmetic-shift z1 -27))
                      #x94D049BB133111EB)
                   MASK64))
    (bitwise-xor z2 (arithmetic-shift z2 -31))))

(define (rng-nat rng n)
  (modulo (rng) n))

(define (rng-pick-vec rng vec)
  (vector-ref vec (modulo (rng) (vector-length vec))))

(define (rng-bool rng)
  (= (bitwise-and (rng) 1) 1))

;; =============================================================================
;; 2. Adversarial Boundary Pools (Campaigns 1 & 2)
;; =============================================================================

(define HOSTILE-COORDS-VEC
  (vector +nan.0 +inf.0 -inf.0 -0.0 0.0 0.0001 -0.0001
          1e-42 -1e-44 ;; IEEE-754 float32 subnormals
          32.5 128.0 255.999 256.0 256.001 -1.0 -500.0 9999.0
          3.4028234e38 1e308 -1e308 ;; float64 > float32 max
          0 64 256 -10 65/2 1/3
          #f "bad-coord" 'nan '(32.0 32.0) 1+2i))

(define HOSTILE-SCALARS-VEC
  (vector 0 1 4 16 -1 -5 -999999999999
          42 255 65535 65536 #x7FFFFFFF #xFFFFFFFF
          #xFFFFFFFFFFFFFFFF (+ (expt 2 64) 7)
          +nan.0 +inf.0 -inf.0 3.5 #f #t "bad" 'sym '()))

(define HOSTILE-TAG-LISTS-VEC
  (vector '()
          '(0)
          '(-1)
          '(0 -3 0)
          '(-999999999999)
          (list (+ (expt 2 64) 7))
          '(42 42)          ;; duplicate tag!
          '(9 9)            ;; duplicate Archon tag!
          '(10 20 10)       ;; non-adjacent duplicate!
          '(10 -5 20)       ;; mixed negative!
          (list 10 (+ (expt 2 64) 7))
          '(9)              ;; single tag (invalid for 1766 Archon, valid for others)
          '(9 10)           ;; valid 2 distinct tags (valid for 1766 Archon!)
          '(101 102 103)    ;; 3 distinct tags (invalid for 1766 Archon, valid for others)
          (list #xFFFFFFFFFFFFFFFF 1)
          #f
          'not-a-list
          (cons 10 20)
          '("bad" #f)))

(define HOSTILE-ABILITIES-VEC
  (vector 0 -1 -5 197 381 999999 ;; invalid / unknown abilities
          ;; Strict NoTarget:
          380 556 558 3665 3692 1343 916
          ;; Archon 1766 (exact 2 tags, no target):
          1766
          ;; Strict PointTarget:
          318 321 880 1152 1036 1413 2338 1768
          ;; Strict UnitTarget (Gas 320/882/1154, Inject 251, Chrono 3755, Gather 3666, Neural 249, Load 3668):
          320 882 1154 251 3755 3666 249 3668 316
          ;; PointOrUnit:
          1 16 17 23
          ;; PointOrNone:
          421 422 454 3680 3682
          ;; Wrong types:
          +nan.0 #f "23" 'attack))

(define HOSTILE-STRINGS-VEC
  (vector ""
          "gl hf"
          "gg wp"
          "Simple64.SC2Map"
          (make-string 256 #\a)
          (make-string 257 #\b)
          (make-string 600 #\x)
          ;; 90 x 4-byte emoji = 360 UTF-8 bytes (> 256 bytes even though string-length is 90!)
          (apply string-append (make-list 90 "🔥"))
          ;; 60 x 4-byte emoji = 240 UTF-8 bytes (<= 256 bytes, valid!)
          (apply string-append (make-list 60 "⚡"))
          #f
          12345
          'not-string
          #"raw-bytes"))

(define (assert-verified-request! bs ctx)
  (when (not (bytes? bs))
    (error 'fuzz-sc2-protobuf-output "~a returned non-bytes: ~v" ctx bs))
  (when (> (bytes-length bs) 0)
    (define-values (ok? reason) (verify-sc2-request-bytes bs))
    (unless ok?
      (error 'fuzz-sc2-protobuf-output
             "BAD REQUEST PROTO EMITTED in ~a: verifier rejected with ~v (bytes=~v)"
             ctx reason bs)))
  (> (bytes-length bs) 0))

(define (assert-verified-action! bs ctx)
  (when (not (bytes? bs))
    (error 'fuzz-sc2-protobuf-output "~a returned non-bytes: ~v" ctx bs))
  (when (> (bytes-length bs) 0)
    (define-values (ok? reason) (verify-sc2-action-bytes bs))
    (unless ok?
      (error 'fuzz-sc2-protobuf-output
             "BAD ACTION PROTO EMITTED in ~a: verifier rejected with ~v (bytes=~v)"
             ctx reason bs)))
  (> (bytes-length bs) 0))

;; =============================================================================
;; 3. Campaign 1: Hostile Boundary Inputs -> ALL Outgoing Encoders
;; =============================================================================

(define (build-hostile-action-candidate rng case-idx)
  ;; Deterministically hit explicit adversarial combinations + random hostile combinations
  (case (modulo case-idx 22)
    ;; 0: 320 Refinery (UnitTarget) given Point2D -> MUST drop (#""), NEVER emit bad proto!
    [(0) (sc2-raw-unit-command 320 (sc2-point2d 50.0 60.0) 0 '(10) #f)]
    ;; 1: 251 InjectLarva (UnitTarget) given TargetNone -> MUST drop!
    [(1) (sc2-raw-unit-command 251 #f 0 '(104) #f)]
    ;; 2: 1036 PsiStorm (PointTarget) given UnitTag -> MUST drop!
    [(2) (sc2-raw-unit-command 1036 #f 9001 '(205) #f)]
    ;; 3: 1766 Archon with 1 tag -> MUST drop!
    [(3) (sc2-raw-unit-command 1766 #f 0 '(9) #f)]
    ;; 4: 1766 Archon with duplicate tags (9, 9) -> MUST drop!
    [(4) (sc2-raw-unit-command 1766 #f 0 '(9 9) #f)]
    ;; 5: 1766 Archon with valid 2 distinct tags (9, 10) -> MUST emit valid proto!
    [(5) (sc2-raw-unit-command 1766 #f 0 '(9 10) #f)]
    ;; 6: `oneof target` collision (both Point2D and target_unit_tag > 0) -> MUST drop!
    [(6) (sc2-raw-unit-command 23 (sc2-point2d 64.0 64.0) 999 '(101 102) #f)]
    ;; 7: 3692 CancelLast (NoTarget) with Point2D -> MUST drop!
    [(7) (sc2-raw-unit-command 3692 (sc2-point2d 32.0 32.0) 0 '(100) #f)]
    ;; 8: Duplicate unit_tags '(42 42) on valid Attack -> MUST drop or deduplicate cleanly!
    [(8) (sc2-raw-unit-command 23 (sc2-point2d 80.0 80.0) 0 '(42 42) #t)]
    ;; 9: Empty unit_tags '() -> MUST drop (prevents raw_affects_selection wipe)!
    [(9) (sc2-raw-unit-command 23 (sc2-point2d 80.0 80.0) 0 '() #f)]
    ;; 10: NaN / Inf / OOB coords in sc2-raw-unit-command -> MUST drop!
    [(10) (sc2-raw-unit-command 16
                                (sc2-point2d (rng-pick-vec rng HOSTILE-COORDS-VEC)
                                             (rng-pick-vec rng HOSTILE-COORDS-VEC))
                                0
                                '(101)
                                (rng-bool rng))]
    ;; 11: Hostile sc2-raw-camera-move (including NaN, Inf, 1e308 z overflow, valid)
    [(11) (sc2-raw-camera-move (rng-pick-vec rng HOSTILE-COORDS-VEC)
                               (rng-pick-vec rng HOSTILE-COORDS-VEC)
                               (rng-pick-vec rng HOSTILE-COORDS-VEC))]
    ;; 12: Hostile sc2-chat-action (empty, >256 UTF-8 emoji bytes, bad channel, valid)
    [(12) (sc2-chat-action (rng-pick-vec rng (vector 0 1 2 3 -1 +nan.0 'bad))
                           (rng-pick-vec rng HOSTILE-STRINGS-VEC))]
    ;; 13: Hostile sc2-ui-control-group (valid 1..5 / 0..9 + invalid 0, 6, -1, 99, NaN)
    [(13) (sc2-ui-control-group (rng-pick-vec rng (vector 0 1 2 3 4 5 6 -1 99 +nan.0 'bad))
                                (rng-pick-vec rng (vector -1 0 1 5 9 10 99 +inf.0 "bad")))]
    ;; 14: Valid / hostile TypedSc2WireAction via smart constructors -> encode-typed-sc2-action
    [(14)
     (define ab-id (rng-pick-vec rng (vector 23 16 320 251 1036 380 1766 421 0 -5 197 999999)))
     (define has-pt? (rng-bool rng))
     (define px (let ([c (rng-pick-vec rng HOSTILE-COORDS-VEC)])
                  (if (real? c) (real->double-flonum c) +nan.0)))
     (define py (let ([c (rng-pick-vec rng HOSTILE-COORDS-VEC)])
                  (if (real? c) (real->double-flonum c) +inf.0)))
     (define tgt (let ([s (rng-pick-vec rng HOSTILE-SCALARS-VEC)])
                   (if (exact-integer? s) s -1)))
     (define tags (let ([tl (rng-pick-vec rng HOSTILE-TAG-LISTS-VEC)])
                    (if (and (list? tl) (andmap exact-integer? tl)) tl '())))
     (or (validate-legacy-wire-command ab-id has-pt? px py tgt tags (rng-bool rng))
         (make-wire-camera-move px py (let ([z (rng-pick-vec rng HOSTILE-COORDS-VEC)])
                                        (if (real? z) z +nan.0)))
         (let ([s (rng-pick-vec rng HOSTILE-STRINGS-VEC)])
           (and (string? s) (make-wire-chat (rng-bool rng) s))))]
    ;; 15: Valid WireToggleAutocast via lookup-autocast-ability + make-non-empty-unit-tags
    [(15)
     (define autocast-id (rng-pick-vec rng (vector 78 316 386 1042 2099 3685 0 -1 23 320 999999)))
     (define ab (and (exact-integer? autocast-id) (lookup-autocast-ability autocast-id)))
     (define tl (rng-pick-vec rng HOSTILE-TAG-LISTS-VEC))
     (define actors (and (list? tl) (andmap exact-integer? tl) (make-non-empty-unit-tags tl)))
     (if (and ab actors)
         (WireToggleAutocast ab actors)
         (sc2-raw-unit-command autocast-id #f 0 (if (list? tl) tl '()) #f))]
    ;; 16..20: Fully random hostile `sc2-raw-unit-command` across all boundary vectors
    [(16 17 18 19 20)
     (define ab (rng-pick-vec rng HOSTILE-ABILITIES-VEC))
     (define pos-kind (rng-nat rng 5))
     (define pos
       (case pos-kind
         [(0) #f]
         [(1) (sc2-point2d (rng-pick-vec rng HOSTILE-COORDS-VEC)
                           (rng-pick-vec rng HOSTILE-COORDS-VEC))]
         [(2) (sc2-point3d (rng-pick-vec rng HOSTILE-COORDS-VEC)
                           (rng-pick-vec rng HOSTILE-COORDS-VEC)
                           (rng-pick-vec rng HOSTILE-COORDS-VEC))]
         [(3) (cons (rng-pick-vec rng HOSTILE-COORDS-VEC)
                    (rng-pick-vec rng HOSTILE-COORDS-VEC))]
         [else 'corrupted-pos]))
     (define tgt (rng-pick-vec rng HOSTILE-SCALARS-VEC))
     (define tags (rng-pick-vec rng HOSTILE-TAG-LISTS-VEC))
     (sc2-raw-unit-command ab pos tgt tags (rng-pick-vec rng (vector #f #t 0 1 'weird)))]
    ;; 21: Wrong Racket types directly into encode-sc2-action / make-request-action
    [else
     (rng-pick-vec rng (vector #f #t 0 -999 +nan.0 "garbage" 'bad-action
                               #"" #"\xFF\xFF\xFF" #"\x0a\x02\x08\x00"
                               '(1 2 3) (vector 'bad)))]))

(define (run-campaign-1! rng iters)
  (define valid-frames 0)
  (for ([i (in-range iters)])
    (define req-id (rng-pick-vec rng HOSTILE-SCALARS-VEC))
    (case (modulo i 12)
      ;; 0..3: encode-typed-sc2-action + encode-sc2-action + make-request-action
      [(0 1 2 3)
       (define cand1 (build-hostile-action-candidate rng i))
       (define cand2 (build-hostile-action-candidate rng (+ i 7)))
       (when (TypedSc2WireAction? cand1)
         (define tb (encode-typed-sc2-action cand1))
         (unless (and (> (bytes-length tb) 0)
                      (assert-verified-action! tb "encode-typed-sc2-action"))
           (error 'fuzz-c1 "TypedSc2WireAction failed wire verifier: ~v" cand1))
         (set! valid-frames (add1 valid-frames)))
       (define ab1 (encode-sc2-action cand1))
       (when (assert-verified-action! ab1 "encode-sc2-action")
         (set! valid-frames (add1 valid-frames)))
       (define batch
         (if (= (modulo i 4) 3)
             (rng-pick-vec rng (vector '() #f 'not-list (list cand1 cand2)))
             (list cand1 cand2)))
       (define rb (make-request-action batch #:id req-id))
       (when (assert-verified-request! rb "make-request-action")
         (set! valid-frames (add1 valid-frames)))]

      ;; 4..5: make-request-query-placement (single & batch, hostile coords/abilities/tags)
      [(4 5)
       (define p1
         (sc2-query-placement (rng-pick-vec rng HOSTILE-ABILITIES-VEC)
                              (rng-pick-vec rng HOSTILE-COORDS-VEC)
                              (rng-pick-vec rng HOSTILE-COORDS-VEC)
                              (rng-pick-vec rng HOSTILE-SCALARS-VEC)))
       (define p2
         (if (= (modulo i 2) 0)
             (list (rng-pick-vec rng (vector 318 880 1152 0 -5 +nan.0))
                   (rng-pick-vec rng HOSTILE-COORDS-VEC)
                   (rng-pick-vec rng HOSTILE-COORDS-VEC)
                   (rng-pick-vec rng (vector #f 0 101 -1 (+ (expt 2 64) 7))))
             'corrupted-placement-entry))
       (define placements
         (if (= (rng-nat rng 8) 0)
             (rng-pick-vec rng (vector '() #f 'not-a-list))
             (list p1 p2)))
       (define qb
         (make-request-query-placement placements
                                       #:ignore-resource-requirements? (rng-pick-vec rng (vector #f #t 'truthy))
                                       #:id req-id))
       (when (assert-verified-request! qb "make-request-query-placement")
         (set! valid-frames (add1 valid-frames)))]

      ;; 6: make-request-step (positional + keyword + hostile non-positive/overflow/NaN counts)
      [(6)
       (define cnt (rng-pick-vec rng HOSTILE-SCALARS-VEC))
       (define sb
         (if (rng-bool rng)
             (make-request-step cnt #:id req-id)
             (make-request-step #:count cnt #:id req-id)))
       (unless (and (> (bytes-length sb) 0)
                    (assert-verified-request! sb "make-request-step"))
         (error 'fuzz-c1 "make-request-step failed to produce non-empty valid Request on count=~v" cnt))
       (set! valid-frames (add1 valid-frames))]

      ;; 7: make-request-join-game (races, observer IDs, ports, host-ip, player-name)
      [(7)
       (define jb
         (make-request-join-game
          #:race (rng-pick-vec rng (vector 'Terran 'Zerg 'Protoss 'Random 0 1 4 99 -5 +nan.0 "zerg"))
          #:observed-player-id (rng-pick-vec rng (vector #f 0 1 2 -1 (+ (expt 2 64) 7) +nan.0))
          #:shared-port (rng-pick-vec rng (vector #f 0 -1 5001 65535 65536 999999 +nan.0))
          #:server-ports (rng-pick-vec rng (vector #f '(5002 5003) '(0 5003) '(-1 70000) 'bad '(5002)))
          #:client-ports (rng-pick-vec rng (vector '() '((5004 5005)) '((0 -5) (5006 5007)) #f 'bad))
          #:player-name (rng-pick-vec rng HOSTILE-STRINGS-VEC)
          #:host-ip (rng-pick-vec rng HOSTILE-STRINGS-VEC)
          #:raw? (rng-bool rng)
          #:raw-affects-selection? (rng-bool rng)
          #:id req-id))
       (unless (and (> (bytes-length jb) 0)
                    (assert-verified-request! jb "make-request-join-game"))
         (error 'fuzz-c1 "make-request-join-game emitted invalid bytes"))
       (set! valid-frames (add1 valid-frames))]

      ;; 8: make-request-create-game
      [(8)
       (define cgb
         (make-request-create-game
          #:map-path (rng-pick-vec rng HOSTILE-STRINGS-VEC)
          #:battlenet-map-name (rng-pick-vec rng HOSTILE-STRINGS-VEC)
          #:player-setups (rng-pick-vec rng (vector #f '() '((1 Zerg) (2 Terran VeryHard "AI"))
                                                    '((-5 99 -9 "") bad-entry)))
          #:our-race (rng-pick-vec rng (vector 'Zerg 'Terran 'Protoss 'Random -9 999 +nan.0))
          #:computer-race (rng-pick-vec rng (vector 'Protoss 'Zerg 0 99 #f))
          #:computer-difficulty (rng-pick-vec rng (vector 'VeryHard 'CheatInsane 0 -1 99 +inf.0))
          #:realtime? (rng-bool rng)
          #:disable-fog? (rng-bool rng)
          #:random-seed (rng-pick-vec rng HOSTILE-SCALARS-VEC)
          #:id req-id))
       (unless (and (> (bytes-length cgb) 0)
                    (assert-verified-request! cgb "make-request-create-game"))
         (error 'fuzz-c1 "make-request-create-game emitted invalid bytes"))
       (set! valid-frames (add1 valid-frames))]

      ;; 9: make-request-observation + make-request-data
      [(9)
       (define ob
         (make-request-observation #:disable-fog? (rng-pick-vec rng (vector #f #t 123))
                                   #:game-loop (rng-pick-vec rng HOSTILE-SCALARS-VEC)
                                   #:id req-id))
       (define db
         (make-request-data #:ability-id? (rng-bool rng)
                            #:unit-type-id? (rng-bool rng)
                            #:upgrade-id? (rng-bool rng)
                            #:buff-id? (rng-bool rng)
                            #:effect-id? (rng-bool rng)
                            #:id req-id))
       (unless (and (assert-verified-request! ob "make-request-observation")
                    (assert-verified-request! db "make-request-data"))
         (error 'fuzz-c1 "observation/data request invalid"))
       (set! valid-frames (+ valid-frames 2))]

      ;; 10: make-request-game-info, make-request-leave-game, make-request-quit,
      ;;     make-request-save-replay, make-request-ping
      [(10)
       (for ([b (in-list (list (make-request-game-info #:id req-id)
                               (make-request-leave-game #:id req-id)
                               (make-request-quit #:id req-id)
                               (make-request-save-replay #:id req-id)
                               (make-request-ping #:id req-id)))])
         (unless (assert-verified-request! b "singleton-request")
           (error 'fuzz-c1 "singleton request invalid"))
         (set! valid-frames (add1 valid-frames)))]

      ;; 11: encode-point2d & encode-point / encode-point3d directly against Point2D / Point verifiers
      [else
       (define x (rng-pick-vec rng HOSTILE-COORDS-VEC))
       (define y (rng-pick-vec rng HOSTILE-COORDS-VEC))
       (define z (rng-pick-vec rng HOSTILE-COORDS-VEC))
       (define p2 (encode-point2d x y))
       (define p3 (encode-point x y z))
       (define-values (ok2? r2) (verify-sc2-point2d-bytes p2))
       (define-values (ok3? r3) (verify-sc2-point-bytes p3))
       (unless (and ok2? ok3?)
         (error 'fuzz-c1 "encode-point2d/encode-point failed verification: ~v / ~v on (~v,~v,~v)"
                r2 r3 x y z))
       (set! valid-frames (+ valid-frames 2))]))
  valid-frames)

;; =============================================================================
;; 4. Campaign 2: 50,000 Mutated S-Expressions + Corrupted `sc2-observation`s
;; =============================================================================

(define BOT-ACTION-HEADS-VEC
  (vector
   'train 'build 'warp-in 'morph 'morph-archon 'expand 'research 'upgrade
   'attack 'attack-pos 'move 'retreat 'kite 'patrol 'hold-position 'stop
   'focus-fire 'snipe-vip 'cast 'cast-spell
   'burrow 'unburrow 'siege 'unsiege 'stim
   'lift-building 'land-building 'swap-addon 'build-addon 'salvage 'cancel 'cancel-last
   'rally 'rally-workers 'harvest 'gather 'return-cargo
   'mineral-walk 'mineral-harass 'worker-scout 'worker-harass
   'pull-workers-attack 'clear-expansion-block 'clear-gas-steal 'resume-halted-building
   'repair 'mule 'calldown-mule 'scan 'scanner-sweep 'supply-drop
   'chrono-boost 'inject-larva 'spread-creep 'spread-creep-tumor 'transfuse
   'abduct 'blinding-cloud 'fungal-growth 'neural-parasite 'corrosive-bile
   'psi-storm 'force-field 'guardian-shield 'feedback 'blink
   'purification-nova 'prismatic-alignment
   'load-transport 'unload-transport 'transport-juggle
   'toggle-autocast 'camera-focus 'camera-move 'chat
   'control-group-assign 'control-group-steal
   'unknown-slop-head))

(define BOT-UNIT-SYMS-VEC
  (vector 'drone 'zergling 'baneling 'roach 'ravager 'hydralisk 'lurker 'mutalisk 'corruptor
          'ultralisk 'viper 'infestor 'queen 'overlord 'overseer
          'scv 'marine 'marauder 'reaper 'ghost 'hellion 'widow-mine 'siege-tank 'thor
          'medivac 'viking 'liberator 'raven 'banshee 'battlecruiser
          'probe 'zealot 'stalker 'sentry 'adept 'high-templar 'dark-templar 'archon
          'immortal 'colossus 'disruptor 'warp-prism 'observer 'phoenix 'void-ray 'oracle 'tempest
          'hatchery 'lair 'hive 'extractor 'spawning-pool 'roach-warren 'spine-crawler 'nydus-worm
          'command-center 'orbital-command 'supply-depot 'refinery 'barracks 'factory 'starport
          'tech-lab 'reactor 'bunker 'missile-turret
          'nexus 'pylon 'assimilator 'gateway 'cybernetics-core 'robotics-facility 'stargate
          'templar-archive 'photon-cannon 'shield-battery
          'zergling-movementspeed 'stimpack 'combat-shield 'warpgate 'charge 'blink 'psi-storm
          'spread-creep-tumor 'spawn-changeling 'emp-round 'chrono-boost 'inject-larva
          'invalid-unit-xyz 0 #f))

(define (mk-fuzz-unit tag utype alliance x y
                      #:display-type [dtype 1]
                      #:hp [hp 100.0]
                      #:shield [sh 0.0]
                      #:energy [en 50.0]
                      #:progress [bp 1.0]
                      #:flying? [fly? #f]
                      #:burrowed? [bur? #f]
                      #:powered? [pow? #t]
                      #:orders [ords '()]
                      #:buffs [buffs '()]
                      #:radius [rad 1.0])
  (sc2-unit dtype alliance tag utype (if (= alliance 1) 1 2)
            (sc2-point3d x y 8.0)
            0.0 rad bp 0 #f #f #f
            hp (if (real? hp) (max 1.0 hp) 100.0)
            sh (if (real? sh) sh 0.0)
            en 200.0
            (if (= alliance 3) 1500 0)
            (if (= alliance 3) 2250 0)
            fly? bur? #f pow? #t
            ords 0 buffs 0 16 0.0 0 0 0 0))

(define (build-adversarial-obs-pool)
  (vector
   ;; 0: Rich Zerg observation + dead/placeholder/fogged enemies
   (sc2-observation
    600 (sc2-player-common 1 400 200 44 28 12 16 1 6 0 3)
    (list (mk-fuzz-unit 100 86 1 32.5 32.5 #:hp 1500.0 #:radius 2.75)
          (mk-fuzz-unit 101 89 1 36.5 34.5 #:hp 1000.0 #:radius 1.5)
          (mk-fuzz-unit 102 151 1 33.0 31.0 #:hp 25.0)
          (mk-fuzz-unit 103 104 1 30.5 31.5 #:hp 40.0)
          (mk-fuzz-unit 104 126 1 33.5 33.5 #:hp 175.0 #:energy 75.0)
          (mk-fuzz-unit 105 105 1 42.0 42.0 #:hp 35.0)
          (mk-fuzz-unit 106 688 1 44.0 44.0 #:hp 120.0 #:energy 100.0)
          (mk-fuzz-unit 137 137 1 40.5 40.5 #:hp 50.0 #:burrowed? #t)
          (mk-fuzz-unit 9001 73 4 80.0 80.0 #:hp 100.0)
          (mk-fuzz-unit 9002 60 4 82.0 82.0 #:display-type 2 #:hp 200.0) ;; fogged snapshot!
          (mk-fuzz-unit 9003 59 4 84.0 84.0 #:display-type 4 #:hp 0.0))  ;; placeholder!
    '(66) '() (sc2-point3d 32.5 32.5 10.0) '(9998 9999) '() '() '() '() '())
   ;; 1: Rich Terran observation (Orbital, Barracks, Factory, Tank, Widow Mine, Medivac)
   (sc2-observation
    1200 (sc2-player-common 1 350 150 46 34 18 16 0 8 0 0)
    (list (mk-fuzz-unit 300 132 1 32.5 32.5 #:hp 1500.0 #:energy 100.0 #:radius 2.75)
          (mk-fuzz-unit 301 19 1 37.0 36.0 #:hp 400.0 #:radius 1.0)
          (mk-fuzz-unit 302 21 1 39.5 36.5 #:hp 1000.0 #:radius 1.5)
          (mk-fuzz-unit 303 27 1 43.5 36.5 #:hp 1250.0 #:radius 1.5)
          (mk-fuzz-unit 304 45 1 31.5 32.5 #:hp 45.0)
          (mk-fuzz-unit 305 48 1 60.0 60.0 #:hp 45.0)
          (mk-fuzz-unit 306 50 1 61.0 60.0 #:hp 100.0 #:energy 125.0)
          (mk-fuzz-unit 307 33 1 59.0 60.0 #:hp 175.0)
          (mk-fuzz-unit 308 54 1 58.0 60.0 #:hp 150.0 #:flying? #t)
          (mk-fuzz-unit 9101 107 4 66.0 64.0 #:hp 90.0))
    '(1) '() (sc2-point3d 32.5 32.5 10.0) '() '() '() '() '() '())
   ;; 2: Rich Protoss observation (Nexus, Pylon, WarpGate, 2 High Templar, Sentry, Warp Prism)
   (sc2-observation
    1800 (sc2-player-common 1 500 300 62 44 26 18 0 10 2 0)
    (list (mk-fuzz-unit 400 59 1 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:energy 75.0 #:radius 2.75)
          (mk-fuzz-unit 401 60 1 37.0 36.0 #:hp 200.0 #:shield 200.0 #:radius 1.0)
          (mk-fuzz-unit 402 133 1 39.5 36.5 #:hp 500.0 #:shield 500.0 #:radius 1.5)
          (mk-fuzz-unit 403 84 1 31.5 32.5 #:hp 20.0 #:shield 20.0)
          (mk-fuzz-unit 404 74 1 70.0 70.0 #:hp 80.0 #:shield 80.0)
          (mk-fuzz-unit 405 77 1 69.5 70.0 #:hp 40.0 #:shield 40.0 #:energy 100.0)
          (mk-fuzz-unit 406 75 1 68.5 70.0 #:hp 40.0 #:shield 40.0 #:energy 100.0)
          (mk-fuzz-unit 407 75 1 68.0 70.5 #:hp 40.0 #:shield 40.0 #:energy 100.0)
          (mk-fuzz-unit 408 81 1 67.0 70.0 #:hp 80.0 #:shield 100.0 #:flying? #t)
          (mk-fuzz-unit 9201 51 4 76.0 74.0 #:hp 125.0))
    '(86) (list (sc2-power-source (sc2-point3d 37.0 36.0 8.0) 6.5 401))
    (sc2-point3d 32.5 32.5 10.0) '() '() '() '() '() '())
   ;; 3: CORRUPTED `sc2-observation` with NaN/Inf/OOB unit positions, 0/-5/2^64+7 tags, bad orders!
   (sc2-observation
    +nan.0
    (sc2-player-common 1 0 0 0 0 0 0 0 0 0 0)
    (list 'not-a-unit
          (mk-fuzz-unit 0 104 1 32.0 32.0)                  ;; invalid tag 0!
          (mk-fuzz-unit -7 104 1 32.0 32.0)                 ;; negative tag!
          (mk-fuzz-unit (+ (expt 2 64) 7) 105 1 40.0 40.0)  ;; > uint64 tag!
          (mk-fuzz-unit 501 104 1 +nan.0 32.0)              ;; NaN x!
          (mk-fuzz-unit 502 105 1 40.0 +inf.0)              ;; +Inf y!
          (mk-fuzz-unit 503 105 1 -500.0 9999.0             ;; OOB coords + corrupted orders/buffs!
                        #:hp +nan.0 #:orders (list 'bad (sc2-unit-order 16 (sc2-point2d +nan.0 50.0) 0 0.5))
                        #:buffs 'not-a-list)
          (mk-fuzz-unit 9501 73 4 +nan.0 -inf.0))
    'bad-upgs
    (list 'bad-ps (sc2-power-source (sc2-point3d +nan.0 36.0 8.0) +inf.0 0))
    #f
    (list -1 0 (+ (expt 2 64) 9) 'bad)
    '() '() '() '() '())
   ;; 4: Empty zero-resource, zero-unit wiped-out observation
   (sc2-observation
    9000 (sc2-player-common 1 0 0 0 0 0 0 0 0 0 0)
    '() '() '() #f '() '() '() '() '() '())
   ;; 5: Corrupted hash observation with NaN enemy coords, non-list fields, 0 resources
   (hash 'frame -50 'minerals 0 'gas 0
         'ally-units (list 'bad (hash 'id -5 'x +nan.0 'y +inf.0) (hash 'id 105 'x 40.0 'y 40.0))
         'enemy-units (list (hash 'id 9001 'x +nan.0 'y 80.0 'hp +inf.0)
                            (hash 'id 0 'x 50.0 'y 50.0)
                            (hash 'id 9005 'x 88.0 'y 88.0 'hp 50 'snapshot? #t))
         'mineral-patches 'corrupted)
   ;; 6: Garbage non-observation values
   #f
   'corrupted-obs-symbol))

(define NEUTRAL-CLUSTER-OBS
  (sc2-observation
   300 (sc2-player-common 1 450 200 24 30 10 14 0 0 0 2)
   (list (mk-fuzz-unit 100 86 1 32.5 32.5 #:hp 1500.0 #:radius 2.75)
         (mk-fuzz-unit 103 104 1 30.5 31.5 #:hp 40.0)
         (mk-fuzz-unit 200 341 3 26.5 32.5 #:hp 10000.0)
         (mk-fuzz-unit 201 342 3 32.5 25.5 #:hp 10000.0)
         (mk-fuzz-unit 202 341 3 50.5 32.5 #:hp 10000.0))
   '() '() (sc2-point3d 32.5 32.5 10.0) '() '() '() '() '() '()))

(define (generate-mutated-sexp rng)
  (define kind (rng-nat rng 12))
  (cond
    [(= kind 0)
     ;; Non-list / improper-list garbage
     (rng-pick-vec rng (vector #f 42 "attack" '() (cons 'attack 99) (cons 'build (cons 'pylon 32.0)) #(train marine)))]
    [else
     (define head (rng-pick-vec rng BOT-ACTION-HEADS-VEC))
     (define arity (rng-nat rng 7)) ;; 0..6 random args!
     (define (rand-arg slot)
       (case (modulo (+ (rng-nat rng 8) slot) 8)
         [(0) (rng-pick-vec rng BOT-UNIT-SYMS-VEC)]
         [(1) (rng-pick-vec rng (vector 100 103 104 105 300 304 305 400 406 407
                                        9001 9002 9003 0 -1 -999 (+ (expt 2 64) 7)))]
         [(2) (rng-pick-vec rng HOSTILE-COORDS-VEC)]
         [(3) (rng-pick-vec rng (vector '(105) '(406 407) '(406 406) '() '(0 -5) '(999999)))]
         [(4) (rng-pick-vec rng HOSTILE-COORDS-VEC)]
         [(5) (rng-pick-vec rng HOSTILE-STRINGS-VEC)]
         [(6) (rng-pick-vec rng (vector 1 2 0 9 -1 99))]
         [else (rng-pick-vec rng BOT-UNIT-SYMS-VEC)]))
     (cons head (for/list ([k (in-range arity)]) (rand-arg k)))]))

(define (run-campaign-2! rng total-sexp-cases)
  (define obs-pool (build-adversarial-obs-pool))
  (define gov (make-wire-apm-governor))
  (define valid-requests 0)
  ;; Group into batches of 1..6 mutated S-expressions per pipeline invocation
  ;; so all `total-sexp-cases` mutated S-expressions flow through
  ;; `translate-bot-actions->sc2-raw-commands` -> `govern-sc2-wire-actions!`
  ;; -> `make-request-action` -> `verify-sc2-request-bytes`!
  (let loop ([remaining total-sexp-cases]
             [batch-idx 0])
    (when (> remaining 0)
      (define batch-sz (min remaining (if (= (modulo batch-idx 12) 0) 1 24)))
      (define sexp-batch
        (if (= (modulo batch-idx 31) 30)
            'not-a-proper-action-list
            (for/list ([_ (in-range batch-sz)])
              (generate-mutated-sexp rng))))
      (define obs
        (if (= (modulo batch-idx 64) 0)
            NEUTRAL-CLUSTER-OBS
            (vector-ref obs-pool (modulo (+ batch-idx (rng-nat rng 3)) (vector-length obs-pool)))))
      (define raw-cmds (translate-bot-actions->sc2-raw-commands sexp-batch obs))
      (define loop-num (+ 16 (* batch-idx 4)))
      (define governed-cmds (govern-sc2-wire-actions! gov raw-cmds loop-num obs))
      (for ([gc (in-list governed-cmds)])
        (define ab (encode-sc2-action gc))
        (assert-verified-action! ab "campaign2-governed-action"))
      (define req-bs (make-request-action governed-cmds #:id (add1 (modulo batch-idx 50000))))
      (when (assert-verified-request! req-bs "campaign2-make-request-action")
        (set! valid-requests (add1 valid-requests)))
      (loop (- remaining batch-sz) (add1 batch-idx))))
  valid-requests)

;; =============================================================================
;; 5. Campaign 3: 4,000 Chaos-Monkey Live `step-live-bot-runtime!` Steps
;; =============================================================================

(define BUSY-BUILDER-ORDER (list (sc2-unit-order 1154 (sc2-point2d 32.5 25.5) 0 0.5)))

(define (build-race-50-templates actual-race)
  (for/vector ([ep-step (in-range 50)])
    (define rush?   (<= 6 ep-step 8))
    (define combat? (or (= ep-step 22) (= ep-step 33) (= ep-step 35)))
    (define scout-bldg? (or (= ep-step 20) (= ep-step 30) (= ep-step 41)))
    (define mid?    (>= ep-step 20))
    (define t3?     (>= ep-step 40))
    (define with-neutrals? (= ep-step 0))
    (define w-orders (if (zero? (bitwise-and ep-step 7)) '() BUSY-BUILDER-ORDER))
    (case actual-race
      [(Zerg)
       (define ally-u
         (cond
           [t3?
            (if (even? ep-step)
                (list (hash 'id 10 'type 'drone 'x 32.5 'y 32.5 'hp 40 'max-hp 40)
                      (hash 'id 112 'type 'viper 'x 51.0 'y 51.0 'hp 150 'energy 125 'flying? #t)
                      (hash 'id 114 'type 'ultralisk 'x 52.0 'y 52.0 'hp 500 'dps 55))
                (list (hash 'id 10 'type 'drone 'x 32.5 'y 32.5 'hp 40 'max-hp 40)
                      (hash 'id 104 'type 'queen 'x 33.5 'y 33.5 'hp 175 'energy 80)
                      (hash 'id 113 'type 'infestor 'x 50.5 'y 50.5 'hp 90 'energy 110)))]
           [(>= ep-step 30)
            (list (hash 'id 10 'type 'drone 'x 32.5 'y 32.5 'hp 40 'max-hp 40)
                  (hash 'id 108 'type 'ravager 'x 48.0 'y 48.0 'hp 120 'energy 100 'dps 20)
                  (hash 'id 111 'type 'overseer 'x 47.0 'y 47.0 'hp 200 'energy 75 'flying? #t))]
           [mid?
            (list (hash 'id 10 'type 'drone 'x 32.5 'y 32.5 'hp 40 'max-hp 40)
                  (hash 'id 104 'type 'queen 'x 33.5 'y 33.5 'hp 175 'energy 80)
                  (hash 'id 702 'type 'creep-tumor-burrowed 'x 42.5 'y 46.5 'hp 50))]
           [else
            (list (hash 'id 10 'type 'drone 'x 32.5 'y 32.5 'hp (if (= ep-step 9) 12 40) 'max-hp 40)
                  (hash 'id 105 'type 'zergling 'x 44.0 'y 44.0 'hp 35 'dps 10))]))
       (define ally-b
         (cond
           [(= ep-step 22)
            (list (hash 'id 100 'type 'lair 'x 32.5 'y 32.5 'hp 1500 'max-hp 1500 'build-progress 1.0)
                  (hash 'id 701 'type 'hatchery 'x 56.5 'y 32.5 'hp 45 'max-hp 1500
                        'hp-pct 0.08 'build-progress 0.40 'under-attack #t))]
           [else
            (list (hash 'id 100 'type (if t3? 'hive (if mid? 'lair 'hatchery))
                        'x 32.5 'y 32.5 'hp 1500 'max-hp 1500 'build-progress 1.0)
                  (hash 'id 101 'type 'spawning-pool 'x 36.5 'y 35.5 'hp 1000 'build-progress 1.0))]))
       (define enemy-u
         (cond
           [rush?   (list (hash 'id 8804 'type 'zealot 'x 35.5 'y 35.5 'hp 100 'dps 16))]
           [combat? (list (hash 'id 9002 'type 'siege-tank-sieged 'x 56.0 'y 56.0 'hp 175 'dps 40))]
           [else '()]))
       (define enemy-b
         (cond
           [rush? (list (hash 'id 8803 'type 'photon-cannon 'x 37.0 'y 37.0 'hp 150)
                        (hash 'id 8805 'type 'assimilator 'x 32.5 'y 25.5 'hp 450))]
           [scout-bldg?
            (list (hash 'id 9010 'type 'nexus 'x 144.5 'y 144.5 'hp 1000 'shield 1000))]
           [else '()]))
       (define w-units
         (append
          (list (mk-fuzz-unit 100 (if t3? 101 (if mid? 100 86)) 1 32.5 32.5 #:hp 1500.0 #:radius 2.75)
                (mk-fuzz-unit 150 151 1 33.0 31.0 #:hp 25.0)
                (mk-fuzz-unit 10 104 1 32.5 32.5 #:hp 40.0 #:orders w-orders)
                (mk-fuzz-unit 104 126 1 33.5 33.5 #:hp 175.0 #:energy 80.0))
          (cond
            [t3?  (list (mk-fuzz-unit 112 499 1 51.0 51.0 #:hp 150.0 #:energy 125.0 #:flying? #t)
                        (mk-fuzz-unit 113 111 1 50.5 50.5 #:hp 90.0 #:energy 110.0)
                        (mk-fuzz-unit 114 109 1 52.0 52.0 #:hp 500.0))]
            [(>= ep-step 30)
             (list (mk-fuzz-unit 108 688 1 48.0 48.0 #:hp 120.0 #:energy 100.0)
                   (mk-fuzz-unit 111 129 1 47.0 47.0 #:hp 200.0 #:energy 75.0 #:flying? #t))]
            [mid? (list (mk-fuzz-unit 702 137 1 42.5 46.5 #:hp 50.0 #:burrowed? #t)
                        (mk-fuzz-unit 701 86 1 56.5 32.5 #:hp 1500.0 #:radius 2.75))]
            [else (list (mk-fuzz-unit 105 105 1 44.0 44.0 #:hp 35.0))])
          (if with-neutrals?
              (list (mk-fuzz-unit 200 341 3 26.5 32.5 #:hp 10000.0)
                    (mk-fuzz-unit 201 342 3 32.5 25.5 #:hp 10000.0))
              '())
          (cond
            [rush?   (list (mk-fuzz-unit 8804 73 4 35.5 35.5 #:hp 100.0)
                           (mk-fuzz-unit 8805 61 4 32.5 25.5 #:hp 450.0))]
            [combat? (list (mk-fuzz-unit 9002 32 4 56.0 56.0 #:hp 175.0))]
            [else '()])))
       (cons
        (hash 'actual-race 'Zerg
              'mineral-harvesters 16
              'supply-used (if t3? 140 (if mid? 68 22))
              'supply-cap (if t3? 180 (if mid? 92 30))
              'supply-left (if t3? 40 12)
              'base-x 32.5 'base-y 32.5 'natural-x 56.5 'natural-y 32.5 'third-x 32.5 'third-y 64.5
              'enemy-x 144.5 'enemy-y 144.5
              'enable-worker-harass (= ep-step 9)
              'ally-units ally-u 'ally-buildings ally-b
              'enemy-units enemy-u 'enemy-buildings enemy-b)
        w-units)]

      [(Terran)
       (define ally-u
         (cond
           [t3?
            (if (even? ep-step)
                (list (hash 'id 10 'type 'scv 'x 32.5 'y 32.5 'hp 45 'max-hp 45)
                      (hash 'id 311 'type 'ghost 'x 51.0 'y 51.0 'hp 100 'energy 125 'dps 16)
                      (hash 'id 313 'type 'battlecruiser 'x 52.0 'y 52.0 'hp 550 'flying? #t 'dps 50))
                (list (hash 'id 10 'type 'scv 'x 32.5 'y 32.5 'hp 45 'max-hp 45)
                      (hash 'id 312 'type 'liberator 'x 51.5 'y 51.5 'hp 180 'flying? #t 'dps 30)))]
           [mid?
            (list (hash 'id 10 'type 'scv 'x 32.5 'y 32.5 'hp 45 'max-hp 45)
                  (hash 'id 308 'type 'siege-tank 'x 50.0 'y 50.0 'hp 175 'dps 25)
                  (hash 'id 309 'type 'widow-mine 'x 49.5 'y 49.5 'hp 90)
                  (hash 'id 310 'type 'medivac 'x 47.5 'y 47.5 'hp 150 'energy 80 'flying? #t))]
           [else
            (list (hash 'id 10 'type 'scv 'x 32.5 'y 32.5 'hp 45 'max-hp 45)
                  (hash 'id 305 'type 'marine 'x 48.0 'y 48.0 'hp 45 'dps 9))]))
       (define ally-b
         (cond
           [(= ep-step 14)
            (list (hash 'id 300 'type 'command-center 'x 32.5 'y 32.5 'hp 1500 'build-progress 1.0)
                  (hash 'id 399 'type 'factory 'x 43.5 'y 36.5 'hp 600 'build-progress 0.55 'halted #t))]
           [(= ep-step 16)
            (list (hash 'id 300 'type 'orbital-command 'x 32.5 'y 32.5 'hp 1500 'energy 75 'build-progress 1.0)
                  (hash 'id 302 'type 'barracks 'x 39.5 'y 36.5 'hp 1000 'addon 'reactor 'build-progress 1.0)
                  (hash 'id 303 'type 'factory 'x 43.5 'y 36.5 'hp 1250 'addon #f 'build-progress 1.0))]
           [else
            (list (hash 'id 300 'type (if mid? 'orbital-command 'command-center)
                        'x 32.5 'y 32.5 'hp 1500 'energy (if mid? 75 0) 'build-progress 1.0)
                  (hash 'id 302 'type 'barracks 'x 39.5 'y 36.5 'hp 1000 'build-progress 1.0))]))
       (define enemy-u
         (cond
           [rush?   (list (hash 'id 8901 'type 'zergling 'x 36.0 'y 36.0 'hp 35 'dps 10))]
           [combat? (list (hash 'id 9101 'type 'archon 'x 56.0 'y 56.0 'hp 10 'shield 350 'dps 35))]
           [else '()]))
       (define enemy-b
         (cond
           [(= ep-step 8) (list (hash 'id 8910 'type 'pylon 'x 56.5 'y 32.5 'hp 200))]
           [scout-bldg?
            (list (hash 'id 9110 'type 'nexus 'x 144.5 'y 144.5 'hp 1000 'shield 1000))]
           [else '()]))
       (define w-units
         (append
          (list (mk-fuzz-unit 300 (if mid? 132 18) 1 32.5 32.5 #:hp 1500.0 #:energy 75.0 #:radius 2.75)
                (mk-fuzz-unit 302 21 1 39.5 36.5 #:hp 1000.0 #:radius 1.5)
                (mk-fuzz-unit 10 45 1 32.5 32.5 #:hp 45.0 #:orders w-orders))
          (cond
            [(= ep-step 14) (list (mk-fuzz-unit 399 27 1 43.5 36.5 #:hp 600.0 #:progress 0.55 #:radius 1.5))]
            [(= ep-step 16) (list (mk-fuzz-unit 303 27 1 43.5 36.5 #:hp 1250.0 #:radius 1.5))]
            [t3?  (list (mk-fuzz-unit 311 50 1 51.0 51.0 #:hp 100.0 #:energy 125.0)
                        (mk-fuzz-unit 312 689 1 51.5 51.5 #:hp 180.0 #:flying? #t)
                        (mk-fuzz-unit 313 57 1 52.0 52.0 #:hp 550.0 #:flying? #t))]
            [mid? (list (mk-fuzz-unit 308 33 1 50.0 50.0 #:hp 175.0)
                        (mk-fuzz-unit 309 498 1 49.5 49.5 #:hp 90.0)
                        (mk-fuzz-unit 310 54 1 47.5 47.5 #:hp 150.0 #:energy 80.0 #:flying? #t))]
            [else (list (mk-fuzz-unit 305 48 1 48.0 48.0 #:hp 45.0))])
          (if with-neutrals?
              (list (mk-fuzz-unit 210 341 3 26.5 32.5 #:hp 10000.0)
                    (mk-fuzz-unit 211 342 3 32.5 25.5 #:hp 10000.0))
              '())
          (cond
            [(= ep-step 8) (list (mk-fuzz-unit 8901 105 4 36.0 36.0 #:hp 35.0)
                                 (mk-fuzz-unit 8910 60 4 56.5 32.5 #:hp 200.0))]
            [rush?   (list (mk-fuzz-unit 8901 105 4 36.0 36.0 #:hp 35.0))]
            [combat? (list (mk-fuzz-unit 9101 141 4 56.0 56.0 #:hp 10.0 #:shield 350.0))]
            [else '()])))
       (cons
        (hash 'actual-race 'Terran
              'mineral-harvesters 16
              'supply-used (if t3? 145 (if mid? 66 22))
              'supply-cap (if t3? 184 (if mid? 86 30))
              'supply-left (if t3? 39 10)
              'base-x 32.5 'base-y 32.5 'natural-x 56.5 'natural-y 32.5 'third-x 32.5 'third-y 64.5
              'enemy-x 144.5 'enemy-y 144.5
              'ally-units ally-u 'ally-buildings ally-b
              'enemy-units enemy-u 'enemy-buildings enemy-b)
        w-units)]

      [else ;; Protoss
       (define ally-u
         (cond
           [t3?
            (if (even? ep-step)
                (list (hash 'id 10 'type 'probe 'x 32.5 'y 32.5 'hp 20 'shield 20)
                      (hash 'id 411 'type 'colossus 'x 50.0 'y 50.0 'hp 200 'shield 150 'dps 32))
                (list (hash 'id 10 'type 'probe 'x 32.5 'y 32.5 'hp 20 'shield 20)
                      (hash 'id 412 'type 'tempest 'x 51.0 'y 51.0 'hp 200 'shield 125 'flying? #t 'dps 28)
                      (hash 'id 413 'type 'oracle 'x 50.5 'y 50.5 'hp 100 'shield 60 'energy 90 'flying? #t)))]
           [(= ep-step 33)
            (list (hash 'id 10 'type 'probe 'x 32.5 'y 32.5 'hp 20 'shield 20)
                  (hash 'id 409 'type 'warp-prism 'x 47.0 'y 47.0 'hp 80 'shield 100 'flying? #t)
                  (hash 'id 410 'type 'immortal 'x 47.5 'y 47.5 'hp 35 'max-hp 200 'shield 0 'dps 35))]
           [(>= ep-step 30)
            (list (hash 'id 10 'type 'probe 'x 32.5 'y 32.5 'hp 20 'shield 20)
                  (hash 'id 407 'type 'high-templar 'x 48.0 'y 48.0 'hp 40 'shield 40
                        'energy (if (= ep-step 35) 20 120))
                  (hash 'id 408 'type 'high-templar 'x 48.2 'y 48.2 'hp 40 'shield 40
                        'energy (if (= ep-step 35) 20 120)))]
           [mid?
            (list (hash 'id 10 'type 'probe 'x 32.5 'y 32.5 'hp 20 'shield 20)
                  (hash 'id 405 'type 'stalker 'x 49.0 'y 49.0 'hp 80 'shield 80 'dps 14)
                  (hash 'id 406 'type 'sentry 'x 48.5 'y 48.5 'hp 40 'shield 40 'energy 100))]
           [else
            (list (hash 'id 10 'type 'probe 'x 32.5 'y 32.5 'hp 20 'shield 20)
                  (hash 'id 404 'type 'zealot 'x 56.5 'y 32.5 'hp 100 'shield 50 'dps 16))]))
       (define ally-b
         (list (hash 'id 400 'type 'nexus 'x 32.5 'y 32.5 'hp 1000 'shield 1000 'energy 65 'build-progress 1.0)
               (hash 'id 401 'type 'pylon 'x 37.0 'y 36.0 'hp 200 'shield 200 'build-progress 1.0)
               (hash 'id 402 'type (if mid? 'warp-gate 'gateway)
                     'x 39.5 'y 36.5 'hp 500 'shield 500 'powered? #t 'build-progress 1.0)))
       (define enemy-u
         (cond
           [rush?   (list (hash 'id 9201 'type 'zergling 'x 36.0 'y 36.0 'hp 35 'dps 10))]
           [combat? (list (hash 'id 9205 'type 'lurker-burrowed 'x 55.0 'y 55.0 'hp 200 'cloaked #t 'is-burrowed #t))]
           [else '()]))
       (define enemy-b
         (cond
           [scout-bldg?
            (list (hash 'id 9210 'type 'lair 'x 144.5 'y 144.5 'hp 2000))]
           [else '()]))
       (define w-units
         (append
          (list (mk-fuzz-unit 400 59 1 32.5 32.5 #:hp 1000.0 #:shield 1000.0 #:energy 65.0 #:radius 2.75)
                (mk-fuzz-unit 401 60 1 37.0 36.0 #:hp 200.0 #:shield 200.0 #:radius 1.0)
                (mk-fuzz-unit 402 (if mid? 133 62) 1 39.5 36.5 #:hp 500.0 #:shield 500.0 #:radius 1.5)
                (mk-fuzz-unit 10 84 1 32.5 32.5 #:hp 20.0 #:shield 20.0 #:orders w-orders))
          (cond
            [t3?  (list (mk-fuzz-unit 411 4 1 50.0 50.0 #:hp 200.0 #:shield 150.0)
                        (mk-fuzz-unit 412 496 1 51.0 51.0 #:hp 200.0 #:shield 125.0 #:flying? #t)
                        (mk-fuzz-unit 413 495 1 50.5 50.5 #:hp 100.0 #:shield 60.0 #:energy 90.0 #:flying? #t))]
            [(= ep-step 33)
             (list (mk-fuzz-unit 409 81 1 47.0 47.0 #:hp 80.0 #:shield 100.0 #:flying? #t)
                   (mk-fuzz-unit 410 83 1 47.5 47.5 #:hp 35.0 #:shield 0.0))]
            [(>= ep-step 30)
             (list (mk-fuzz-unit 407 75 1 48.0 48.0 #:hp 40.0 #:shield 40.0 #:energy 120.0)
                   (mk-fuzz-unit 408 75 1 48.2 48.2 #:hp 40.0 #:shield 40.0 #:energy 120.0))]
            [mid? (list (mk-fuzz-unit 405 74 1 49.0 49.0 #:hp 80.0 #:shield 80.0)
                        (mk-fuzz-unit 406 77 1 48.5 48.5 #:hp 40.0 #:shield 40.0 #:energy 100.0))]
            [else (list (mk-fuzz-unit 404 73 1 56.5 32.5 #:hp 100.0 #:shield 50.0))])
          (if with-neutrals?
              (list (mk-fuzz-unit 220 341 3 26.5 32.5 #:hp 10000.0)
                    (mk-fuzz-unit 221 342 3 32.5 25.5 #:hp 10000.0))
              '())
          (cond
            [rush?   (list (mk-fuzz-unit 9201 105 4 36.0 36.0 #:hp 35.0))]
            [combat? (list (mk-fuzz-unit 9205 503 4 55.0 55.0 #:hp 200.0 #:burrowed? #t))]
            [else '()])))
       (cons
        (hash 'actual-race 'Protoss
              'mineral-harvesters 16
              'supply-used (if t3? 150 (if mid? 72 24))
              'supply-cap (if t3? 190 (if mid? 94 34))
              'supply-left (if t3? 40 10)
              'base-x 32.5 'base-y 32.5 'natural-x 56.5 'natural-y 32.5 'third-x 32.5 'third-y 64.5
              'enemy-x 144.5 'enemy-y 144.5
              'door-guard (= ep-step 15)
              'ally-units ally-u 'ally-buildings ally-b
              'enemy-units enemy-u 'enemy-buildings enemy-b)
        w-units)])))

(define ZERG-TEMPLATES    (build-race-50-templates 'Zerg))
(define TERRAN-TEMPLATES  (build-race-50-templates 'Terran))
(define PROTOSS-TEMPLATES (build-race-50-templates 'Protoss))
(define PROTOSS-POWER-SRC (list (sc2-power-source (sc2-point3d 37.0 36.0 8.0) 6.5 401)))

(define (run-campaign-3-race-list! seed race-specs)
  (reset-typed-command-gate-stats!)
  (define total-brain-rejects 0)
  (define total-wire-drops 0)
  (define valid-requests 0)

  (for ([spec (in-list race-specs)])
    (match-define (list bname brace race-steps salt) spec)
    (define rng (make-splitmix64 (bitwise-xor seed salt)))
    (define rt #f)
    (define gov (make-wire-apm-governor))
    (define actual-r brace)

    (define ep-len (max 1 (min race-steps 334)))
    (for ([s (in-range race-steps)])
      (define mstep (modulo s ep-len))
      ;; Start a fresh match trajectory every ep-len steps (3 matches per 1,000 steps so Random hits Z/T/P)
      (when (zero? mstep)
        (set! rt (make-live-bot-runtime #:bot-name bname #:race brace))
        (set! gov (make-wire-apm-governor))
        (set! actual-r
              (if (eq? brace 'Random)
                  (vector-ref '#(Zerg Terran Protoss) (modulo (quotient s ep-len) 3))
                  brace)))
      (define ep-step (min 49 (quotient (* mstep 50) ep-len)))
      ;; Monotonic ladder step_size=2 within each phase across opening/mid/T3/sweep epochs:
      (define epoch-base
        (cond
          [(>= ep-step 46) 9200]
          [(>= ep-step 40) 6000]
          [(>= ep-step 20) 2400]
          [else 4]))
      (define frame (+ epoch-base (* mstep 2)))
      (define mins
        (if (zero? (bitwise-and s 7))
            (+ 300 (* (rng-nat rng 8) 75))
            (+ 25 (* (rng-nat rng 5) 35))))
      (define gas
        (if (zero? (bitwise-and s 7))
            (+ 100 (* (rng-nat rng 6) 50))
            (* (rng-nat rng 3) 25)))
      (define tmpl-vec
        (case actual-r
          [(Zerg) ZERG-TEMPLATES]
          [(Terran) TERRAN-TEMPLATES]
          [else PROTOSS-TEMPLATES]))
      ;; Only include raw neutral mineral/geyser units on step 0 of each match to exercise expansion solver without O(N) map sweeps every frame
      (define tmpl-idx (if (and (zero? ep-step) (> mstep 0)) 1 ep-step))
      (define tmpl (vector-ref tmpl-vec tmpl-idx))
      (define rt-obs
        (hash-set* (car tmpl) 'frame frame 'minerals mins 'gas gas))
      (define wire-obs
        (sc2-observation frame
                         (sc2-player-common 1 mins gas 100 50 30 20 0 10
                                            (if (eq? actual-r 'Protoss) 2 0)
                                            (if (eq? actual-r 'Zerg) 2 0))
                         (cdr tmpl)
                         (case actual-r [(Zerg) '(66)] [(Terran) '(1)] [else '(86)])
                         (if (eq? actual-r 'Protoss) PROTOSS-POWER-SRC '())
                         (sc2-point3d 32.5 32.5 10.0)
                         '() '() '() '() '() '()))

      (define step-res (step-live-bot-runtime! rt rt-obs))
      (define brain-acts
        (append (hash-ref step-res 'actions '())
                (hash-ref step-res 'mirror-actions '())))
      (define-values (valid-sexps rejects) (filter-valid-bot-actions brain-acts))
      (when (pair? rejects)
        (set! total-brain-rejects (+ total-brain-rejects (length rejects)))
        (error 'fuzz-c3
               "Live brain (~a / ~a, step ~a, frame ~a) emitted BotActionRejects: ~v"
               bname actual-r s frame rejects))

      (define drops-before (get-total-wire-action-drop-count))
      (define raw-cmds (translate-bot-actions->sc2-raw-commands valid-sexps wire-obs))
      (define gov-cmds (govern-sc2-wire-actions! gov raw-cmds frame wire-obs))
      (when (zero? (bitwise-and s 7))
        (for ([gc (in-list gov-cmds)])
          (define ab (encode-sc2-action gc))
          (unless (assert-verified-action! ab "campaign3-live-action")
            (error 'fuzz-c3 "Empty/invalid Action in live step ~a: ~v" s gc))
          (unless (sc2-ui-control-group? gc)
            (define dec (decode-typed-sc2-action ab))
            (unless (TypedSc2WireAction? dec)
              (error 'fuzz-c3 "decode-typed-sc2-action failed round-trip on live action: ~v" gc)))))
      (define req-bs (make-request-action gov-cmds #:id (add1 s)))
      (when (assert-verified-request! req-bs "campaign3-live-request-action")
        (set! valid-requests (add1 valid-requests)))
      (define drops-after (get-total-wire-action-drop-count))
      (when (> drops-after drops-before)
        (set! total-wire-drops (+ total-wire-drops (- drops-after drops-before)))
        (error 'fuzz-c3
               "Live pipeline (~a / ~a, step ~a) dropped ~a wire actions! raw-cmds=~v"
               bname actual-r s (- drops-after drops-before) raw-cmds))))
  (values total-brain-rejects total-wire-drops valid-requests))

;; =============================================================================
;; 6. Campaign 4: 40,000 Negative Binary Mutation/Corruption Tests
;; =============================================================================

;; Raw binary helpers to craft exact adversarial wire mutations independently:
(define (raw-varint n)
  (let loop ([v n] [acc '()])
    (define b (bitwise-and v #x7F))
    (define r (arithmetic-shift v -7))
    (if (zero? r)
        (list->bytes (reverse (cons b acc)))
        (loop r (cons (bitwise-ior b #x80) acc)))))

(define (raw-len-field fnum payload)
  (bytes-append (raw-varint (bitwise-ior (arithmetic-shift fnum 3) 2))
                (raw-varint (bytes-length payload))
                payload))

(define (raw-varint-field fnum val)
  (bytes-append (raw-varint (arithmetic-shift fnum 3))
                (raw-varint val)))

(define (raw-f32-le-u32 u32)
  (bytes (bitwise-and u32 #xFF)
         (bitwise-and (arithmetic-shift u32 -8) #xFF)
         (bitwise-and (arithmetic-shift u32 -16) #xFF)
         (bitwise-and (arithmetic-shift u32 -24) #xFF)))

(define (raw-point2d-u32 ux uy)
  (bytes-append (bytes #x0D) (raw-f32-le-u32 ux)
                (bytes #x15) (raw-f32-le-u32 uy)))

(define (wrap-raw-uc->action uc-bs)
  (raw-len-field 1 (raw-len-field 1 uc-bs)))

(define (wrap-action->request act-bs)
  (raw-len-field 11 (raw-len-field 1 act-bs)))

(define BAD-F32-BITS-VEC
  (vector #x7FC00000 ;; quiet +NaN
          #x7F800001 ;; signaling +NaN
          #xFFC00001 ;; -NaN
          #x7F800000 ;; +Inf
          #xFF800000 ;; -Inf
          #xBF800000 ;; -1.0f (< 0.0)
          #xC3FA0000 ;; -500.0f (< 0.0)
          #x43800001 ;; 256.00003f (> 256.0)
          #x461C3C00 ;; 9999.0f (> 256.0)
          ))

(define VALID-POINT2D-OK
  (encode-point2d 64.5 128.25))

(define (generate-corrupted-proto-case rng i)
  ;; Returns (values target-kind corrupted-bytes label)
  ;; where target-kind is 'both (both Action and RequestAction) or 'request-only
  (case (modulo i 24)
    ;; 0: Empty or truncated mid-frame RequestAction (no trailing optional id)
    [(0)
     (define base
       (make-request-action
        (list (sc2-raw-unit-command 23 (sc2-point2d 48.5 64.0) 0 '(101 102) #f))))
     (define cut (rng-nat rng (bytes-length base))) ;; strictly < length (includes 0!)
     (values 'request-only (subbytes base 0 cut) 'truncated-request)]

    ;; 1: Truncated Action mid-varint / mid-fixed32 / mid-len
    [(1)
     (define base
       (encode-sc2-action (sc2-raw-unit-command 16 (sc2-point2d 32.0 64.0) 0 '(55) #t)))
     (define cut (rng-nat rng (bytes-length base)))
     (values 'action-only (subbytes base 0 cut) 'truncated-action)]

    ;; 2: Overlong 11-byte varint
    [(2)
     (define overlong (bytes #x08 #x80 #x80 #x80 #x80 #x80 #x80 #x80 #x80 #x80 #x80 #x01))
     (values 'both (wrap-raw-uc->action overlong) 'overlong-11byte-varint)]

    ;; 3: 10th byte > 1 overflowing uint64 (2^64)
    [(3)
     (define overflow64
       (bytes-append (raw-varint-field 1 380)
                     (bytes #x20 #x80 #x80 #x80 #x80 #x80 #x80 #x80 #x80 #x80 #x02)))
     (values 'both (wrap-raw-uc->action overflow64) 'uint64-varint-overflow)]

    ;; 4: Invalid field number 0 or > 2^29-1
    [(4)
     (define bad-tag
       (if (rng-bool rng)
           (bytes #x00 #x01)
           (bytes-append (raw-varint (bitwise-ior (arithmetic-shift #x20000000 3) 0)) (bytes #x01))))
     (values 'both (wrap-raw-uc->action bad-tag) 'invalid-field-number)]

    ;; 5: Deprecated / invalid wire types (3, 4, 6, 7)
    [(5)
     (define wt (rng-pick-vec rng '#(3 4 6 7)))
     (define bad-wt (bytes (bitwise-ior (arithmetic-shift 1 3) wt) #x00))
     (values 'both (wrap-raw-uc->action bad-wt) 'deprecated-wire-type)]

    ;; 6: Unknown field on ActionRawUnitCommand (e.g. field 6 or 99)
    [(6)
     (define uc
       (bytes-append (raw-varint-field 1 380)
                     (raw-varint-field 4 101)
                     (raw-varint-field (rng-pick-vec rng '#(6 7 99)) 1)))
     (values 'both (wrap-raw-uc->action uc) 'unknown-unit-cmd-field)]

    ;; 7: Unknown field on Point2D (e.g. z=field 3 injected into Point2D!)
    [(7)
     (define bad-p2 (bytes-append VALID-POINT2D-OK (encode-float32 3 8.0)))
     (define uc
       (bytes-append (raw-varint-field 1 16)
                     (raw-len-field 2 bad-p2)
                     (raw-varint-field 4 101)))
     (values 'both (wrap-raw-uc->action uc) 'point2d-unknown-z-field)]

    ;; 8: IEEE-754 NaN / +-Inf / <0 / >256 float32 in ActionRawUnitCommand Point2D
    [(8)
     (define bad-bits (rng-pick-vec rng BAD-F32-BITS-VEC))
     (define ok-bits #x42800000) ;; 64.0f
     (define p2
       (if (rng-bool rng)
           (raw-point2d-u32 bad-bits ok-bits)
           (raw-point2d-u32 ok-bits bad-bits)))
     (define uc
       (bytes-append (raw-varint-field 1 23)
                     (raw-len-field 2 p2)
                     (raw-varint-field 4 101)))
     (values 'both (wrap-raw-uc->action uc) 'point2d-nan-inf-oob)]

    ;; 9: IEEE-754 NaN / +-Inf in CameraMove Point (including z = NaN / Inf!)
    [(9)
     (define bad-bits (rng-pick-vec rng BAD-F32-BITS-VEC))
     (define ok-bits #x42800000)
     (define which (rng-nat rng 3))
     (define p3
       (bytes-append (bytes #x0D) (raw-f32-le-u32 (if (= which 0) bad-bits ok-bits))
                     (bytes #x15) (raw-f32-le-u32 (if (= which 1) bad-bits ok-bits))
                     (bytes #x1D) (raw-f32-le-u32 (if (= which 2) #x7FC00000 ok-bits))))
     (define act (raw-len-field 1 (raw-len-field 2 (raw-len-field 1 p3))))
     (values 'both act 'camera-point-nan-inf-oob)]

    ;; 10: `oneof target` collision: BOTH field 2 (Point2D) AND field 3 (target_unit_tag)
    [(10)
     (define uc
       (bytes-append (raw-varint-field 1 23)
                     (raw-len-field 2 VALID-POINT2D-OK)
                     (raw-varint-field 3 9001)
                     (raw-varint-field 4 101)))
     (values 'both (wrap-raw-uc->action uc) 'oneof-target-collision)]

    ;; 11: `ActionRaw` multiple oneof fields (unit_command + camera_move) or empty ActionRaw
    [(11)
     (define act
       (if (rng-bool rng)
           (raw-len-field 1 #"")
           (let ([uc (bytes-append (raw-varint-field 1 380) (raw-varint-field 4 101))]
                 [cm (raw-len-field 1 (encode-point 32.0 32.0 8.0))])
             (raw-len-field 1 (bytes-append (raw-len-field 1 uc) (raw-len-field 2 cm))))))
     (values 'both act 'action-raw-oneof-violation)]

    ;; 12: Stripped `unit_tags` (0 tags -> selection-wipe bug) or zero tag `[0]`
    [(12)
     (define uc
       (if (rng-bool rng)
           (bytes-append (raw-varint-field 1 23)
                         (raw-len-field 2 VALID-POINT2D-OK))
           (bytes-append (raw-varint-field 1 23)
                         (raw-len-field 2 VALID-POINT2D-OK)
                         (raw-varint-field 4 0))))
     (values 'both (wrap-raw-uc->action uc) 'missing-or-zero-unit-tags)]

    ;; 13: Duplicate `unit_tags` [42, 42] or [10, 20, 10]
    [(13)
     (define uc
       (bytes-append (raw-varint-field 1 23)
                     (raw-len-field 2 VALID-POINT2D-OK)
                     (raw-varint-field 4 42)
                     (raw-varint-field 4 42)))
     (values 'both (wrap-raw-uc->action uc) 'duplicate-unit-tags)]

    ;; 14: 1766 MORPH_ARCHON with 1 tag [9], 3 tags [9,10,11], dup [9,9], or Point2D
    [(14)
     (define uc
       (case (rng-nat rng 4)
         [(0) (bytes-append (raw-varint-field 1 1766) (raw-varint-field 4 9))]
         [(1) (bytes-append (raw-varint-field 1 1766)
                            (raw-varint-field 4 9) (raw-varint-field 4 10) (raw-varint-field 4 11))]
         [(2) (bytes-append (raw-varint-field 1 1766)
                            (raw-varint-field 4 9) (raw-varint-field 4 9))]
         [else (bytes-append (raw-varint-field 1 1766)
                             (raw-len-field 2 VALID-POINT2D-OK)
                             (raw-varint-field 4 9) (raw-varint-field 4 10))]))
     (values 'both (wrap-raw-uc->action uc) 'archon-1766-invariant-violation)]

    ;; 15: Target-mode swap: Gas 320/882/1154 with Point2D or TargetNone
    [(15)
     (define gas-ab (rng-pick-vec rng '#(320 882 1154)))
     (define uc
       (if (rng-bool rng)
           (bytes-append (raw-varint-field 1 gas-ab)
                         (raw-len-field 2 VALID-POINT2D-OK)
                         (raw-varint-field 4 10))
           (bytes-append (raw-varint-field 1 gas-ab)
                         (raw-varint-field 4 10))))
     (values 'both (wrap-raw-uc->action uc) 'gas-target-mode-swap)]

    ;; 16: Target-mode swap: Inject 251 / Chrono 3755 / Gather 3666 / Neural 249 with TargetNone or Point2D
    [(16)
     (define u-ab (rng-pick-vec rng '#(251 3755 3666 249 3668)))
     (define uc
       (if (rng-bool rng)
           (bytes-append (raw-varint-field 1 u-ab) (raw-varint-field 4 104))
           (bytes-append (raw-varint-field 1 u-ab)
                         (raw-len-field 2 VALID-POINT2D-OK)
                         (raw-varint-field 4 104))))
     (values 'both (wrap-raw-uc->action uc) 'unit-ability-given-none-or-point)]

    ;; 17: Target-mode swap: PointTarget (1036 PsiStorm / 1152 Hatchery) with UnitTag or TargetNone
    [(17)
     (define p-ab (rng-pick-vec rng '#(1036 1152 318 880 1413 2338)))
     (define uc
       (if (rng-bool rng)
           (bytes-append (raw-varint-field 1 p-ab)
                         (raw-varint-field 3 9001)
                         (raw-varint-field 4 406))
           (bytes-append (raw-varint-field 1 p-ab)
                         (raw-varint-field 4 406))))
     (values 'both (wrap-raw-uc->action uc) 'point-ability-given-unit-or-none)]

    ;; 18: Target-mode swap: NoTarget (3692 / 380 / 556) with Point2D or UnitTag,
    ;;     OR PointOrUnit (23 / 16) with TargetNone, OR PointOrNone (421) with UnitTag
    [(18)
     (define uc
       (case (rng-nat rng 3)
         [(0) (bytes-append (raw-varint-field 1 3692)
                            (raw-len-field 2 VALID-POINT2D-OK)
                            (raw-varint-field 4 100))]
         [(1) (bytes-append (raw-varint-field 1 23)
                            (raw-varint-field 4 105))]
         [else (bytes-append (raw-varint-field 1 421)
                             (raw-varint-field 3 999)
                             (raw-varint-field 4 302))]))
     (values 'both (wrap-raw-uc->action uc) 'notarget-or-dual-mode-swap)]

    ;; 19: Unrecognized ability_id (0, 197, 381, 999999) or bad ToggleAutocast ability
    [(19)
     (define act
       (if (rng-bool rng)
           (wrap-raw-uc->action
            (bytes-append (raw-varint-field 1 (rng-pick-vec rng '#(0 197 381 999999)))
                          (raw-varint-field 4 101)))
           (raw-len-field 1 (raw-len-field 3 (bytes-append (raw-varint-field 1 23)
                                                           (raw-varint-field 2 101))))))
     (values 'both act 'unrecognized-ability-id)]

    ;; 20: Invalid ActionChat (channel 0/3, empty message, 257-byte message, invalid UTF-8)
    [(20)
     (define chat-sub
       (case (rng-nat rng 4)
         [(0) (bytes-append (raw-varint-field 1 0) (raw-len-field 2 #"hi"))]
         [(1) (bytes-append (raw-varint-field 1 1) (raw-len-field 2 #""))]
         [(2) (bytes-append (raw-varint-field 1 1) (raw-len-field 2 (make-bytes 257 65)))]
         [else (bytes-append (raw-varint-field 1 1) (raw-len-field 2 #"\xFF\xFE\xFD"))]))
     (values 'both (raw-len-field 6 chat-sub) 'invalid-action-chat)]

    ;; 21: Invalid ActionUI / ActionControlGroup (action=0/6, index=10, or wrong ActionUI field 2)
    [(21)
     (define ui-act
       (case (rng-nat rng 3)
         [(0) (raw-len-field 4 (raw-len-field 1 (bytes-append (raw-varint-field 1 0)
                                                              (raw-varint-field 2 1))))]
         [(1) (raw-len-field 4 (raw-len-field 1 (bytes-append (raw-varint-field 1 2)
                                                              (raw-varint-field 2 10))))]
         [else (raw-len-field 4 (raw-len-field 2 #""))]))
     (values 'both ui-act 'invalid-action-ui-control-group)]

    ;; 22: Request-level violations: 0 oneof fields, 2 oneof fields (step + ping), unknown field, empty RequestAction
    [(22)
     (define bad-req
       (case (rng-nat rng 4)
         [(0) (raw-varint-field 97 1)] ;; id only, missing oneof request!
         [(1) (bytes-append (make-request-step 4 #:id 1) (raw-len-field 19 #""))] ;; 2 oneof fields!
         [(2) (bytes-append (make-request-ping #:id 1) (raw-varint-field 88 1))] ;; unknown Request field 88!
         [else (raw-len-field 11 #"")])) ;; empty RequestAction!
     (values 'request-only bad-req 'request-oneof-or-unknown-violation)]

    ;; 23: Corrupted RequestQuery (empty placements, ability_id=0, explicit placing_unit_tag=0, NaN Point2D)
    [else
     (define bad-rq
       (case (rng-nat rng 4)
         [(0) (raw-len-field 14 #"")]
         [(1) (raw-len-field 14 (raw-len-field 3 (bytes-append (raw-varint-field 1 0)
                                                               (raw-len-field 2 VALID-POINT2D-OK))))]
         [(2) (raw-len-field 14 (raw-len-field 3 (bytes-append (raw-varint-field 1 1152)
                                                               (raw-len-field 2 VALID-POINT2D-OK)
                                                               (raw-varint-field 3 0))))]
         [else (raw-len-field 14 (raw-len-field 3 (bytes-append (raw-varint-field 1 1152)
                                                                (raw-len-field 2 (raw-point2d-u32 #x7FC00000 #x42000000)))))]))
     (values 'request-only bad-rq 'corrupted-request-query)]))

(define (run-campaign-4! rng iters)
  (define rejected 0)
  (for ([i (in-range iters)])
    (define-values (kind bad-bs label) (generate-corrupted-proto-case rng i))
    (case kind
      [(action-only)
       (define-values (ok-a? _ra) (verify-sc2-action-bytes bad-bs))
       (define dec (decode-typed-sc2-action bad-bs))
       (when (or ok-a? dec)
         (error 'fuzz-c4
                "FALSE NEGATIVE on corrupted Action (~a, iter ~a): verify=~v decode=~v bytes=~v"
                label i ok-a? dec bad-bs))
       (set! rejected (add1 rejected))]

      [(request-only)
       (define-values (ok-r? _rr) (verify-sc2-request-bytes bad-bs))
       (when ok-r?
         (error 'fuzz-c4
                "FALSE NEGATIVE on corrupted Request (~a, iter ~a): bytes=~v"
                label i bad-bs))
       (set! rejected (add1 rejected))]

      [else ;; 'both: test standalone Action on BOTH verifiers AND wrapped inside RequestAction!
       (define-values (ok-a? _ra) (verify-sc2-action-bytes bad-bs))
       (define dec (decode-typed-sc2-action bad-bs))
       (define wrapped-req (wrap-action->request bad-bs))
       (define-values (ok-r? _rr) (verify-sc2-request-bytes wrapped-req))
       (when (or ok-a? dec ok-r?)
         (error 'fuzz-c4
                "FALSE NEGATIVE on corrupted Action/Request (~a, iter ~a): ok-a?=~v dec=~v ok-r?=~v bytes=~v"
                label i ok-a? dec ok-r? bad-bs))
       (set! rejected (add1 rejected))]))
  rejected)

;; =============================================================================
;; 7. Orchestrator, Parallel Place Worker, & CLI Entry Point
;; =============================================================================

(define (protobuf-fuzz-place-worker pch)
  (match-define (list seed c2-iters core2-specs) (place-channel-get pch))
  (define rng-c2 (make-splitmix64 (bitwise-xor seed #x5555666677778888)))
  (define tc2 (current-inexact-monotonic-milliseconds))
  (define c2-valid (run-campaign-2! rng-c2 c2-iters))
  (define c2-ms (- (current-inexact-monotonic-milliseconds) tc2))
  (define tc3b (current-inexact-monotonic-milliseconds))
  (define-values (c3b-rej c3b-drops c3b-valid)
    (run-campaign-3-race-list! seed core2-specs))
  (define c3b-ms (- (current-inexact-monotonic-milliseconds) tc3b))
  (reset-typed-command-gate-stats!)
  (place-channel-put pch (list c2-valid c2-ms c3b-rej c3b-drops c3b-valid c3b-ms)))

(define (run-protobuf-output-fuzz-campaigns
         #:seed [seed #x5C2F022026]
         #:c1-iters [c1-iters 60000]
         #:c2-iters [c2-iters 50000]
         #:c3-steps [c3-steps 4000]
         #:c4-iters [c4-iters 40000]
         #:quiet? [quiet? #f])
  (define t0 (current-inexact-monotonic-milliseconds))
  (define rng-c1 (make-splitmix64 (bitwise-xor seed #x1111222233334444)))
  (define rng-c2 (make-splitmix64 (bitwise-xor seed #x5555666677778888)))
  (define rng-c4 (make-splitmix64 (bitwise-xor seed #x9999AAAABBBBCCCC)))

  (define q (quotient c3-steps 4))
  (define rem (modulo c3-steps 4))
  (define z-steps (+ q (if (> rem 0) 1 0)))
  (define t-steps (+ q (if (> rem 1) 1 0)))
  (define p-steps (+ q (if (> rem 2) 1 0)))
  (define r-steps q)
  ;; Pair Protoss + 95% Random (1,950 steps) on Core 1,
  ;; and Zerg + Terran + 5% Random (2,050 steps) + C2 + place-init on Core 2:
  (define r1-steps (quotient (* r-steps 19) 20))
  (define r2-steps (- r-steps r1-steps))
  (define core1-specs
    (append (list (list 'Mothman-P 'Protoss p-steps  #xC33EF003))
            (if (> r1-steps 0)
                (list (list 'Mothman-R 'Random r1-steps #xD44FF004))
                '())))
  (define core2-specs
    (append (list (list 'Mothman-Z 'Zerg    z-steps  #xA11CE001)
                  (list 'Mothman-T 'Terran  t-steps  #xB22DF002))
            (if (> r2-steps 0)
                (list (list 'Mothman-R 'Random r2-steps #xE5500115))
                '())))
  (define single-specs
    (list (list 'Mothman-Z 'Zerg    z-steps #xA11CE001)
          (list 'Mothman-T 'Terran  t-steps #xB22DF002)
          (list 'Mothman-P 'Protoss p-steps #xC33EF003)
          (list 'Mothman-R 'Random  r-steps #xD44FF004)))

  (define-values (c1-valid c1-ms c2-valid c2-ms c3-rej c3-drops c3-valid c3-ms c4-rej c4-ms)
    (if (and (place-enabled?) (>= c3-steps 800))
        (let ([pl (dynamic-place SELF-MOD-PATH 'protobuf-fuzz-place-worker)])
          (place-channel-put pl (list seed c2-iters core2-specs))
          (define tc1 (current-inexact-monotonic-milliseconds))
          (define v-c1 (run-campaign-1! rng-c1 c1-iters))
          (define ms-c1 (- (current-inexact-monotonic-milliseconds) tc1))
          (define tc3a (current-inexact-monotonic-milliseconds))
          (define-values (r-3a d-3a v-3a) (run-campaign-3-race-list! seed core1-specs))
          (define ms-3a (- (current-inexact-monotonic-milliseconds) tc3a))
          (define tc4 (current-inexact-monotonic-milliseconds))
          (define v-c4 (run-campaign-4! rng-c4 c4-iters))
          (define ms-c4 (- (current-inexact-monotonic-milliseconds) tc4))
          (match-define (list v-c2 ms-c2 r-3b d-3b v-3b ms-3b) (place-channel-get pl))
          (place-wait pl)
          (values v-c1 ms-c1
                  v-c2 ms-c2
                  (+ r-3a r-3b) (+ d-3a d-3b) (+ v-3a v-3b) (max ms-3a ms-3b)
                  v-c4 ms-c4))
        (let ()
          (define tc1 (current-inexact-monotonic-milliseconds))
          (define v-c1 (run-campaign-1! rng-c1 c1-iters))
          (define ms-c1 (- (current-inexact-monotonic-milliseconds) tc1))
          (define tc2 (current-inexact-monotonic-milliseconds))
          (define v-c2 (run-campaign-2! rng-c2 c2-iters))
          (define ms-c2 (- (current-inexact-monotonic-milliseconds) tc2))
          (define tc3 (current-inexact-monotonic-milliseconds))
          (define-values (r-3 d-3 v-3)
            (run-campaign-3-race-list! seed single-specs))
          (define ms-c3 (- (current-inexact-monotonic-milliseconds) tc3))
          (define tc4 (current-inexact-monotonic-milliseconds))
          (define v-c4 (run-campaign-4! rng-c4 c4-iters))
          (define ms-c4 (- (current-inexact-monotonic-milliseconds) tc4))
          (values v-c1 ms-c1 v-c2 ms-c2 r-3 d-3 v-3 ms-c3 v-c4 ms-c4))))

  (unless quiet?
    (printf "  [Campaign 1] ~a hostile encoder boundary cases -> 0 crashes, ~a verified wire frames (~a ms)\n"
            c1-iters c1-valid (~r c1-ms #:precision 1))
    (printf "  [Campaign 2] ~a mutated S-exps + corrupted obs -> 0 crashes, ~a verified RequestAction frames (~a ms)\n"
            c2-iters c2-valid (~r c2-ms #:precision 1))
    (printf "  [Campaign 3] ~a chaos-monkey live Z/T/P/R steps -> ~a brain rejects, ~a wire drops, ~a verified RequestAction frames (~a ms)\n"
            c3-steps c3-rej c3-drops c3-valid (~r c3-ms #:precision 1))
    (printf "  [Campaign 4] ~a negative binary mutations -> ~a/~a rejected (0 false negatives, ~a ms)\n"
            c4-iters c4-rej c4-iters (~r c4-ms #:precision 1)))

  (define elapsed (- (current-inexact-monotonic-milliseconds) t0))
  (reset-typed-command-gate-stats!)
  (proto-fuzz-summary seed
                      c1-iters c1-valid
                      c2-iters c2-valid
                      c3-steps c3-rej c3-drops c3-valid
                      c4-iters c4-rej
                      elapsed))

(module+ main
  (define cli-seed #x5C2F022026)
  (define cli-total-iters #f)

  (command-line
   #:program "fuzz-sc2-protobuf-output"
   #:once-each
   [("--seed") s "Deterministic PRNG seed (integer)"
    (set! cli-seed (or (string->number s) #x5C2F022026))]
   [("--iterations") n "Total fuzz iterations across all 4 campaigns (default: 154000)"
    (set! cli-total-iters (string->number n))])

  (define-values (c1 c2 c3 c4)
    (if (and (exact-positive-integer? cli-total-iters) (not (= cli-total-iters 154000)))
        (let* ([scale (/ cli-total-iters 154000.0)]
               [n1 (max 24 (inexact->exact (round (* 60000 scale))))]
               [n2 (max 24 (inexact->exact (round (* 50000 scale))))]
               [n3 (max 16 (inexact->exact (round (* 4000 scale))))]
               [n4 (max 24 (- cli-total-iters (+ n1 n2 n3)))])
          (values n1 n2 n3 n4))
        (values 60000 50000 4000 40000)))

  (define total (+ c1 c2 c3 c4))
  (printf "=============================================================================\n")
  (printf " SC2 Protobuf Output Differential & Schema Fuzzer (seed=#x~x, total=~a)\n"
          cli-seed total)
  (printf "=============================================================================\n")
  (define summary
    (run-protobuf-output-fuzz-campaigns
     #:seed cli-seed
     #:c1-iters c1
     #:c2-iters c2
     #:c3-steps c3
     #:c4-iters c4
     #:quiet? #f))
  (printf "-----------------------------------------------------------------------------\n")
  (printf " PASS: ~a/4 campaigns (~a total fuzz cases, 0 crashes, 0 bad protos, ~a ms)\n"
          4 total (~r (proto-fuzz-summary-elapsed-ms summary) #:precision 1))
  (printf "=============================================================================\n"))
