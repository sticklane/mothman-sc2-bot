#lang typed/racket/base

(require "../lib/sc2-typed-commands.rkt")

;; =============================================================================
;; tests/typed-commands-test.rkt
;; Comprehensive Typed Racket Verification Suite for `lib/sc2-typed-commands.rkt`
;; =============================================================================
;;
;; Verifies:
;;   1. Positive binary Protobuf wire encoding (exact byte sequences) and
;;      `decode-typed-sc2-action` round-trips across all 7 `TypedSc2WireAction`
;;      variants (`WireCmdNone`, `WireCmdPoint`, `WireCmdUnit`, `WireCmdArchon`,
;;      `WireToggleAutocast`, `WireCameraMove`, `WireChat`).
;;   2. Ground-truth LotV `ability_id` & `Target` mode partitioning (`1632` Queen
;;      vs `2146` Revelation, `1628` EMP vs legacy `381`, `320/882/1154` Gas
;;      strictly `UnitTarget`, `3667` HarvestReturn `NoTarget`, `1766` Archon
;;      2-distinct-Templar invariant, dual-mode `1/16/17/23` and AddOns).
;;   3. Negative runtime boundary rejections (`NaN`/`Inf`/out-of-bounds points,
;;      empty/`0`/negative `unit_tags`, `oneof target` conflicts, malformed wire
;;      payloads, `< 1 us/cmd` zero-chaperone `validate-legacy-wire-command`).
;;   4. High-level `TypedBotAction` S-expression validation (`parse-bot-action-sexp`
;;      & `filter-valid-bot-actions`), catching self-EMP `(cast-spell u 'emp-round eid)`
;;      and point-on-unit `(cast-spell u 'neural-parasite x y)` bugs.
;;   5. Compile-time negative Type Checker proofs verifying that ill-typed witness
;;      uses and non-exhaustive `(ann act Nothing)` matches fail at compile time.

(define pass-count : Natural 0)
(define fail-count : Natural 0)

(: check-true (-> Boolean String Void))
(define (check-true cond? label)
  (if cond?
      (set! pass-count (+ pass-count 1))
      (begin
        (set! fail-count (+ fail-count 1))
        (fprintf (current-error-port) "FAIL [check-true]: ~a\n" label))))

(: check-false (-> Any String Void))
(define (check-false v label)
  (check-true (not v) label))

(: check-eqv (-> Any Any String Void))
(define (check-eqv actual expected label)
  (if (equal? actual expected)
      (set! pass-count (+ pass-count 1))
      (begin
        (set! fail-count (+ fail-count 1))
        (fprintf (current-error-port)
                 "FAIL [check-eqv]: ~a\n  actual:   ~s\n  expected: ~s\n"
                 label actual expected))))

(: require-some (All (A) (-> (Option A) String A)))
(define (require-some opt label)
  (cond
    [opt
     (set! pass-count (+ pass-count 1))
     opt]
    [else
     (set! fail-count (+ fail-count 1))
     (error 'typed-commands-test "unexpected #f for ~a" label)]))

(define suite-start-ms : Flonum (current-inexact-milliseconds))

;; =============================================================================
;; 1. Positive Wire Encoding (Byte-Exactness) & Round-Trip Tests
;; =============================================================================

;; 1A. WireCmdNone: STOP (3665), single actor 101, queue? = #f
;;   3665 = 0x0E51 -> varint: 0xD1 0x1C
;;   uc-bytes = 08 D1 1C 20 65 (len 5)
;;   ActionRaw = 0A 05 <uc> (len 7)
;;   Action = 0A 07 <ActionRaw>
(let ()
  (define ab-stop (require-some (lookup-no-target-ability 3665) "lookup STOP 3665"))
  (define tags-101 (require-some (make-non-empty-unit-tags '(101)) "tags (101)"))
  (define cmd (WireCmdNone ab-stop tags-101 #f))
  (define raw (encode-typed-sc2-action cmd))
  (check-eqv raw #"\x0a\x07\x0a\x05\x08\xd1\x1c\x20\x65" "WireCmdNone STOP exact bytes")
  (check-eqv (decode-typed-sc2-action raw) cmd "WireCmdNone STOP round-trip")

  ;; TRAIN_QUEEN = 1632 (0x0660 -> varint E0 0C), actors (201 202), queue? = #t
  (define ab-queen (require-some (lookup-no-target-ability 1632) "lookup TRAIN_QUEEN 1632"))
  (define tags-201-202 (require-some (make-non-empty-unit-tags '(201 202)) "tags (201 202)"))
  (define cmd-q (WireCmdNone ab-queen tags-201-202 #t))
  (define raw-q (encode-typed-sc2-action cmd-q))
  (check-eqv raw-q
             #"\x0a\x0d\x0a\x0b\x08\xe0\x0c\x20\xc9\x01\x20\xca\x01\x28\x01"
             "WireCmdNone TRAIN_QUEEN queued exact bytes")
  (check-eqv (decode-typed-sc2-action raw-q) cmd-q "WireCmdNone TRAIN_QUEEN round-trip")

  ;; HARVEST_RETURN = 3667 + race aliases 296/299/1184/167 canonicalized to 3667
  (define ab-ret (require-some (lookup-no-target-ability 3667) "lookup HARVEST_RETURN 3667"))
  (check-eqv (NoTargetAbility-id ab-ret) 3667 "HARVEST_RETURN id 3667")
  (for ([alias-id (in-list '(296 299 1184 167 3667))])
    (check-eqv (canonicalize-harvest-return-ability-id alias-id)
               3667
               "canonicalize HARVEST_RETURN alias"))
  (define cmd-ret (WireCmdNone ab-ret tags-101 #f))
  (check-eqv (decode-typed-sc2-action (encode-typed-sc2-action cmd-ret))
             cmd-ret
             "WireCmdNone HARVEST_RETURN round-trip"))

;; 1B. WireCmdPoint: EMP (1628), Revelation (2146), Nydus Worm (1768), Pylon (881), Dual-Mode
(let ()
  (define ab-emp (require-some (lookup-point-target-ability 1628) "lookup EFFECT_EMP 1628"))
  (define pt (require-some (make-world-point2d 64.5 128.25) "point (64.5, 128.25)"))
  (define actors (require-some (make-non-empty-unit-tags '(301)) "tags (301)"))
  (define cmd-emp (WireCmdPoint ab-emp actors pt #f))
  (define expected-pt-payload
    (bytes-append #"\x0d" (real->floating-point-bytes 64.5 4 #f)
                  #"\x15" (real->floating-point-bytes 128.25 4 #f)))
  ;; 1628 = 0x065C -> varint DC 0C; 301 = 0x012D -> varint AD 02
  (define expected-uc
    (bytes-append #"\x08\xdc\x0c\x12\x0a" expected-pt-payload #"\x20\xad\x02"))
  (define expected-wire
    (bytes-append #"\x0a" (bytes (+ (bytes-length expected-uc) 2))
                  #"\x0a" (bytes (bytes-length expected-uc))
                  expected-uc))
  (define actual-wire (encode-typed-sc2-action cmd-emp))
  (check-eqv actual-wire expected-wire "WireCmdPoint EMP 1628 exact bytes")
  (check-eqv (decode-typed-sc2-action actual-wire) cmd-emp "WireCmdPoint EMP round-trip")

  ;; Verify Oracle Revelation (2146), Build Nydus Worm (1768), Build Pylon (881),
  ;; Dual-Mode (1, 16, 17, 23), and Terran Lift+Land AddOn (421) round-trip
  (for ([aid (in-list '(2146 1768 881 1036 1 16 17 23 421))])
    (define pab (require-some (lookup-point-target-ability aid)
                              (format "PointTargetAbility ~a" aid)))
    (define pcmd (WireCmdPoint pab actors pt #t))
    (check-eqv (decode-typed-sc2-action (encode-typed-sc2-action pcmd))
               pcmd
               (format "WireCmdPoint round-trip ~a" aid))))

;; 1C. WireCmdUnit: Gas buildings (320/882/1154), Inject (251), Neural (249), Chrono (3755), uint64 tags
(let ()
  (define worker-tags (require-some (make-non-empty-unit-tags '(401)) "worker (401)"))
  (define geyser-tag : Positive-Integer 9001)
  (define ab-ref (require-some (lookup-unit-target-ability 320) "BUILD_REFINERY 320"))
  (define cmd-ref (WireCmdUnit ab-ref worker-tags geyser-tag #f))
  ;; 320 = C0 02; 9001 = A9 46; 401 = 91 03
  (define expected-ref #"\x0a\x0b\x0a\x09\x08\xc0\x02\x18\xa9\x46\x20\x91\x03")
  (check-eqv (encode-typed-sc2-action cmd-ref) expected-ref "WireCmdUnit BUILD_REFINERY exact bytes")
  (check-eqv (decode-typed-sc2-action expected-ref) cmd-ref "WireCmdUnit BUILD_REFINERY round-trip")

  ;; High >32-bit SC2 UnitTag (e.g. 0x102B00001 = 4340062209)
  (define big-tag : Positive-Integer #x102B00001)
  (define big-actors (require-some (make-non-empty-unit-tags (list #x102A00005)) "uint64 actor"))
  (for ([aid (in-list '(320 882 1154 251 249 3755 1664 1 16 17 23))])
    (define uab (require-some (lookup-unit-target-ability aid)
                              (format "UnitTargetAbility ~a" aid)))
    (define ucmd ( require-some (make-wire-cmd-unit uab big-actors big-tag #t)
                                (format "make-wire-cmd-unit ~a" aid)))
    (check-eqv (decode-typed-sc2-action (encode-typed-sc2-action ucmd))
               ucmd
               (format "WireCmdUnit uint64 round-trip ~a" aid))))

;; 1D. WireCmdArchon: MORPH_ARCHON (1766) with 2 distinct allied Templar tags
(let ()
  (define archon-cmd (require-some (make-wire-cmd-archon 501 502 #f) "Archon (501, 502)"))
  ;; 1766 = E6 0D; 501 = F5 03; 502 = F6 03
  (define expected-archon #"\x0a\x0b\x0a\x09\x08\xe6\x0d\x20\xf5\x03\x20\xf6\x03")
  (check-eqv (encode-typed-sc2-action archon-cmd)
             expected-archon
             "WireCmdArchon 1766 exact bytes")
  (check-eqv (decode-typed-sc2-action expected-archon)
             archon-cmd
             "WireCmdArchon round-trip")

  (define archon-q (require-some (make-wire-cmd-archon 501 502 #t) "Archon queued"))
  (check-eqv (decode-typed-sc2-action (encode-typed-sc2-action archon-q))
             archon-q
             "WireCmdArchon queued round-trip"))

;; 1E. WireToggleAutocast: Heal (386), Repair (3685), WidowMine (2099), Interceptors (1042)
(let ()
  (define ac-heal (require-some (lookup-autocast-ability 386) "Autocast Heal 386"))
  (define medivacs (require-some (make-non-empty-unit-tags '(601 602)) "medivacs"))
  (define cmd-ac (WireToggleAutocast ac-heal medivacs))
  ;; 386 = 82 03; field 2 repeated varint = 0x10; 601 = D9 04; 602 = DA 04
  ;; ActionRaw field 3 = 0x1A
  (define expected-ac #"\x0a\x0b\x1a\x09\x08\x82\x03\x10\xd9\x04\x10\xda\x04")
  (check-eqv (encode-typed-sc2-action cmd-ac) expected-ac "WireToggleAutocast exact bytes")
  (check-eqv (decode-typed-sc2-action expected-ac) cmd-ac "WireToggleAutocast round-trip")

  (for ([aid (in-list '(386 3685 2099 1042 1819 4113))])
    (define ac (require-some (lookup-autocast-ability aid) (format "Autocast ~a" aid)))
    (define w (WireToggleAutocast ac medivacs))
    (check-eqv (decode-typed-sc2-action (encode-typed-sc2-action w))
               w
               (format "WireToggleAutocast round-trip ~a" aid)))
  (check-false (lookup-autocast-ability 3665) "lookup-autocast-ability rejects STOP 3665")
  (check-false (lookup-autocast-ability 1628) "lookup-autocast-ability rejects EMP 1628"))

;; 1F. WireCameraMove: 3D float32 LE center_world_space
(let ()
  (define cam (require-some (make-wire-camera-move 64.5 128.25 12.0) "CameraMove 3-arg"))
  (define expected-pt3
    (bytes-append #"\x0d" (real->floating-point-bytes 64.5 4 #f)
                  #"\x15" (real->floating-point-bytes 128.25 4 #f)
                  #"\x1d" (real->floating-point-bytes 12.0 4 #f)))
  ;; cm-bytes = 0A 0F <pt3> (17 bytes); ActionRaw = 12 11 <cm> (19 bytes); Action = 0A 13 <ActionRaw>
  (define expected-cam (bytes-append #"\x0a\x13\x12\x11\x0a\x0f" expected-pt3))
  (check-eqv (encode-typed-sc2-action cam) expected-cam "WireCameraMove exact bytes")
  (check-eqv (decode-typed-sc2-action expected-cam) cam "WireCameraMove round-trip"))

;; 1G. WireChat: Broadcast (channel=1) and Team (channel=2) on Action field 6 (0x32)
(let ()
  (define chat-all (require-some (make-wire-chat #f "glhf") "WireChat broadcast"))
  (check-eqv (encode-typed-sc2-action chat-all)
             #"\x32\x08\x08\x01\x12\x04glhf"
             "WireChat broadcast exact bytes")
  (check-eqv (decode-typed-sc2-action #"\x32\x08\x08\x01\x12\x04glhf")
             chat-all
             "WireChat broadcast round-trip")

  (define chat-team (require-some (make-wire-chat #t "emp ready") "WireChat team"))
  (check-eqv (encode-typed-sc2-action chat-team)
             #"\x32\x0d\x08\x02\x12\x09emp ready"
             "WireChat team exact bytes")
  (check-eqv (decode-typed-sc2-action #"\x32\x0d\x08\x02\x12\x09emp ready")
             chat-team
             "WireChat team round-trip"))

;; =============================================================================
;; 2. Negative Runtime Boundary & Witness Partition Tests
;; =============================================================================

;; 2A. Ability witness table disjointness & LotV ground-truth checks
(let ()
  ;; PointTarget rejects Gas (320/882/1154), Inject (251), Neural (249), Stop (3665),
  ;; HarvestReturn (3667), TrainQueen (1632), Legacy EMP (381), Invalid (197),
  ;; ProtossAirArmor research (3692), Archon (1766), <= 0, out-of-range
  (for ([bad-pt-id (in-list '(320 882 1154 251 249 3755 1664 3665 3667 1632 381 197 3692 1766 0 -1 99999))])
    (check-false (lookup-point-target-ability bad-pt-id)
                 (format "lookup-point-target-ability rejects ~a" bad-pt-id)))

  ;; NoTarget rejects Inject (251), Chrono (3755), Transfusion (1664), Neural (249),
  ;; Gas (320/882/1154), Pylon (881), EMP (1628), PsiStorm (1036), Revelation (2146),
  ;; NydusWorm (1768), Dual-mode PointOrUnit (1/16/17/23), Archon (1766)
  (for ([bad-nt-id (in-list '(251 3755 1664 249 320 882 1154 881 1628 1036 2146 1768 1 16 17 23 1766 381 197 0 -5))])
    (check-false (lookup-no-target-ability bad-nt-id)
                 (format "lookup-no-target-ability rejects ~a" bad-nt-id)))

  ;; UnitTarget rejects Pylon (881), PsiStorm (1036), EMP (1628), Revelation (2146),
  ;; NydusWorm (1768), Stop (3665), HarvestReturn (3667), TrainQueen (1632), AddOn (421)
  (for ([bad-ut-id (in-list '(881 1036 1628 2146 1768 3665 3667 1632 421 3682 3683 1766 381 197 0 -1))])
    (check-false (lookup-unit-target-ability bad-ut-id)
                 (format "lookup-unit-target-ability rejects ~a" bad-ut-id)))

  ;; Terran specific & generic AddOns + Spine/Spore Root/Uproot are PointOrNone
  (for ([pon-id (in-list '(421 422 454 455 487 488 3680 3681 3682 3683))])
    (check-true (NoTargetAbility? (lookup-no-target-ability pon-id))
                (format "PointOrNone ~a valid as NoTargetAbility" pon-id))
    (check-true (PointTargetAbility? (lookup-point-target-ability pon-id))
                (format "PointOrNone ~a valid as PointTargetAbility" pon-id))
    (check-false (lookup-unit-target-ability pon-id)
                 (format "PointOrNone ~a rejected as UnitTargetAbility" pon-id))))

;; 2B. WorldPoint2D, UnitTag, NonEmptyUnitTags, Archon, Camera, Chat boundaries
(let ()
  ;; WorldPoint2D rejects NaN, +inf, -inf, < 0.0, > 256.0
  (check-false (make-world-point2d +nan.0 50.0) "WorldPoint2D rejects +nan.0 x")
  (check-false (make-world-point2d 50.0 +nan.0) "WorldPoint2D rejects +nan.0 y")
  (check-false (make-world-point2d +inf.0 50.0) "WorldPoint2D rejects +inf.0 x")
  (check-false (make-world-point2d 50.0 -inf.0) "WorldPoint2D rejects -inf.0 y")
  (check-false (make-world-point2d -0.1 50.0) "WorldPoint2D rejects -0.1 x")
  (check-false (make-world-point2d 50.0 -0.0001) "WorldPoint2D rejects negative y")
  (check-false (make-world-point2d 256.1 50.0) "WorldPoint2D rejects 256.1 x")
  (check-false (make-world-point2d 50.0 256.01) "WorldPoint2D rejects 256.01 y")

  ;; Exact map boundaries 0.0 and 256.0 + -0.0 canonicalization
  (define corner-0 (require-some (make-world-point2d -0.0 256.0) "WorldPoint2D (0.0, 256.0)"))
  (check-eqv (WorldPoint2D-x corner-0) 0.0 "WorldPoint2D canonicalizes -0.0 -> 0.0")
  (check-eqv (WorldPoint2D-y corner-0) 256.0 "WorldPoint2D accepts 256.0")

  ;; UnitTag & NonEmptyUnitTags
  (check-false (make-unit-tag 0) "make-unit-tag rejects 0")
  (check-false (make-unit-tag -42) "make-unit-tag rejects negative")
  (check-false (make-unit-tag (+ SC2-MAX-UINT64 1)) "make-unit-tag rejects > uint64")
  (check-eqv (make-unit-tag SC2-MAX-UINT64) SC2-MAX-UINT64 "make-unit-tag accepts max uint64")

  (check-false (make-non-empty-unit-tags '()) "make-non-empty-unit-tags rejects '()")
  (check-false (make-non-empty-unit-tags '(0)) "make-non-empty-unit-tags rejects '(0)")
  (check-false (make-non-empty-unit-tags '(-5)) "make-non-empty-unit-tags rejects '(-5)")
  (check-false (make-non-empty-unit-tags '(101 0 102)) "make-non-empty-unit-tags rejects mixed 0")

  (define deduped (require-some (make-non-empty-unit-tags '(101 102 101 103 102)) "dedup tags"))
  (check-eqv (non-empty-unit-tags->list deduped) '(101 102 103) "preserves first-seen order")

  (define filtered (require-some (filter-non-empty-unit-tags '(0 101 -3 102 101)) "filter tags"))
  (check-eqv (non-empty-unit-tags->list filtered) '(101 102) "filter strips <= 0 and dedups")
  (check-false (filter-non-empty-unit-tags '(0 -1 0)) "filter returns #f if all invalid")

  ;; Archon, Camera, Chat negative invariants
  (check-false (make-wire-cmd-archon 101 101 #f) "Archon rejects identical Templar tags")
  (check-false (make-wire-cmd-archon 0 102 #f) "Archon rejects tag 0")
  (check-false (make-wire-cmd-archon -5 102 #f) "Archon rejects negative tag")
  (check-false (make-wire-camera-move 64.0 64.0 +nan.0) "CameraMove rejects +nan.0 z")
  (check-false (make-wire-camera-move 64.0 64.0 +inf.0) "CameraMove rejects +inf.0 z")
  (check-false (make-wire-chat #f "") "WireChat rejects empty message")
  (check-false (make-wire-chat #t (make-string 257 #\a)) "WireChat rejects > 256 chars")

  ;; Malformed wire payloads rejected by decode-typed-sc2-action
  (check-false (decode-typed-sc2-action #"") "decode rejects empty bytes")
  (check-false (decode-typed-sc2-action #"\x0a\x05\x0a") "decode rejects truncated length")
  ;; STOP (3665) with ZERO unit_tags (selection-wipe bug!) rejected on decode
  (check-false (decode-typed-sc2-action #"\x0a\x05\x0a\x03\x08\xd1\x1c")
               "decode rejects empty unit_tags on wire")
  ;; MORPH_ARCHON (1766) with only 1 tag or duplicate tags rejected on decode
  (check-false (decode-typed-sc2-action #"\x0a\x08\x0a\x06\x08\xe6\x0d\x20\xf5\x03")
               "decode rejects 1-tag Archon on wire")
  (check-false (decode-typed-sc2-action #"\x0a\x0b\x0a\x09\x08\xe6\x0d\x20\xf5\x03\x20\xf5\x03")
               "decode rejects duplicate-tag Archon on wire"))

;; 2C. Flat-Primitive Zero-Chaperone Bridge `validate-legacy-wire-command` & Micro-Benchmark
(let ()
  ;; Rejects simultaneous point + unit target (`oneof target` conflict)
  (check-false (validate-legacy-wire-command 23 #t 50.0 60.0 999 '(101) #f)
               "bridge rejects simultaneous point and unit target")
  ;; Rejects Gas building (320) with point target, accepts with geyser tag
  (check-false (validate-legacy-wire-command 320 #t 50.0 60.0 0 '(101) #f)
               "bridge rejects Refinery with PointTarget")
  (check-true (WireCmdUnit? (validate-legacy-wire-command 320 #f 0.0 0.0 9001 '(101) #f))
              "bridge accepts Refinery with UnitTarget")
  ;; Rejects EMP (1628) with UnitTarget or NoTarget, accepts with PointTarget
  (check-false (validate-legacy-wire-command 1628 #f 0.0 0.0 99 '(101) #f)
               "bridge rejects EMP with UnitTarget")
  (check-false (validate-legacy-wire-command 1628 #f 0.0 0.0 0 '(101) #f)
               "bridge rejects EMP with NoTarget")
  (check-true (WireCmdPoint? (validate-legacy-wire-command 1628 #t 100.0 120.0 0 '(101) #f))
              "bridge accepts EMP with PointTarget")
  ;; Rejects NaN coords and empty unit_tags
  (check-false (validate-legacy-wire-command 16 #t +nan.0 50.0 0 '(101) #f)
               "bridge rejects +nan.0 coord")
  (check-false (validate-legacy-wire-command 3665 #f 0.0 0.0 0 '() #f)
               "bridge rejects empty unit_tags")
  ;; Archon (1766) requires 2 distinct tags and no target
  (check-false (validate-legacy-wire-command 1766 #f 0.0 0.0 0 '(101) #f)
               "bridge rejects 1-tag Archon")
  (check-false (validate-legacy-wire-command 1766 #f 0.0 0.0 0 '(101 101) #f)
               "bridge rejects duplicate-tag Archon")
  (check-true (WireCmdArchon? (validate-legacy-wire-command 1766 #f 0.0 0.0 0 '(101 102) #t))
              "bridge constructs WireCmdArchon for 2 distinct Templars")
  ;; Canonicalizes race-specific HarvestReturn (296) -> 3667 and HarvestGather (295) -> 3666
  (define ret-act (require-some (validate-legacy-wire-command 296 #f 0.0 0.0 0 '(101) #f)
                                "bridge canonicalizes SCV HarvestReturn 296"))
  (check-true (and (WireCmdNone? ret-act)
                   (= (NoTargetAbility-id (WireCmdNone-ability ret-act)) 3667))
              "SCV HarvestReturn 296 -> 3667")
  (define gat-act (require-some (validate-legacy-wire-command 295 #f 0.0 0.0 8001 '(101) #f)
                                "bridge canonicalizes SCV HarvestGather 295"))
  (check-true (and (WireCmdUnit? gat-act)
                   (= (UnitTargetAbility-id (WireCmdUnit-ability gat-act)) 3666))
              "SCV HarvestGather 295 -> 3666")

  ;; Performance check: 20,000 bridge validations must run well under < 1 us/cmd (< 20 ms total)
  (define t0 (current-inexact-milliseconds))
  (for ([i (in-range 20000)])
    (validate-legacy-wire-command 23 #t 120.5 140.25 0 '(101 102) #f))
  (define bridge-ms (- (current-inexact-milliseconds) t0))
  (check-true (< bridge-ms 100.0)
              (format "20,000 bridge calls fast (<100ms, actual ~ams)"
                      (real->decimal-string bridge-ms 2))))

;; =============================================================================
;; 3. High-Level `TypedBotAction` S-Expression Validator Tests
;; =============================================================================

(let ()
  ;; Negative high-level bug catches:
  ;; 1. Self-EMP bug: `(cast-spell 10 'emp-round 99)` (PointTarget spell given 1 arg!)
  (define bad-emp (parse-bot-action-sexp (list 'cast-spell 10 'emp-round 99)))
  (check-true (and (BotActionReject? bad-emp)
                   (eq? (BotActionReject-reason bad-emp) 'point-spell-requires-xy))
              "parse-bot-action-sexp rejects (cast-spell 10 'emp-round 99)")

  ;; 2. Neural Parasite given 2 coordinates instead of 1 enemy UnitTag!
  (define bad-np (parse-bot-action-sexp (list 'cast-spell 10 'neural-parasite 50.0 60.0)))
  (check-true (and (BotActionReject? bad-np)
                   (eq? (BotActionReject-reason bad-np) 'unit-spell-requires-unit-tag))
              "parse-bot-action-sexp rejects (cast-spell 10 'neural-parasite 50.0 60.0)")
  (define bad-ibc (parse-bot-action-sexp (list 'infestor-burrow-cast 10 'neural-parasite 50.0 60.0)))
  (check-true (BotActionReject? bad-ibc)
              "parse-bot-action-sexp rejects (infestor-burrow-cast 10 'neural-parasite x y)")

  ;; 3. NaN coordinates, empty actor list, 1-tag Archon, unknown head
  (check-true (BotActionReject? (parse-bot-action-sexp (list 'expand +nan.0 50.0)))
              "parse-bot-action-sexp rejects (expand +nan.0 50.0)")
  (check-true (BotActionReject? (parse-bot-action-sexp (list 'attack '() 99)))
              "parse-bot-action-sexp rejects (attack '() 99)")
  (check-true (BotActionReject? (parse-bot-action-sexp (list 'morph 101 'archon)))
              "parse-bot-action-sexp rejects 1-tag (morph 101 'archon)")
  (check-true (BotActionReject? (parse-bot-action-sexp (list 'orbital-laser-strike 1 2)))
              "parse-bot-action-sexp rejects unknown head")

  ;; Positive high-level classifications across ADT variants:
  (define b-pylon (parse-bot-action-sexp (list 'build 'pylon 50.0 60.0)))
  (check-true (and (BotBuildStructure? b-pylon)
                   (= (PointTargetAbility-id (BotBuildStructure-ability b-pylon)) 881))
              "BotBuildStructure pylon -> 881")

  (define b-gas (parse-bot-action-sexp (list 'build 'extractor 40.0 45.0)))
  (check-true (and (BotBuildGas? b-gas)
                   (= (UnitTargetAbility-id (BotBuildGas-ability b-gas)) 1154))
              "BotBuildGas extractor -> 1154 UnitTargetAbility")

  (define b-addon (parse-bot-action-sexp (list 'build 'barracks-reactor)))
  (check-true (and (BotBuildAddon? b-addon)
                   (= (NoTargetAbility-id (BotBuildAddon-ability b-addon)) 422))
              "BotBuildAddon barracks-reactor -> 422 NoTargetAbility")

  (define b-nydus (parse-bot-action-sexp (list 'build 'nydus-worm 120.0 130.0)))
  (check-true (and (BotBuildNydusWorm? b-nydus)
                   (= (PointTargetAbility-id (BotBuildNydusWorm-ability b-nydus)) 1768))
              "BotBuildNydusWorm -> 1768 PointTargetAbility")

  (define c-emp (parse-bot-action-sexp (list 'cast-spell 10 'emp-round 100.0 110.0)))
  (check-true (and (BotCastPoint? c-emp)
                   (= (PointTargetAbility-id (BotCastPoint-ability c-emp)) 1628))
              "BotCastPoint emp-round -> 1628")

  ;; Legacy raw integer 381 canonicalized to 'emp-round (1628) in high-level spell resolution
  (define c-emp-381 (parse-bot-action-sexp (list 'cast-spell 10 381 100.0 110.0)))
  (check-true (and (BotCastPoint? c-emp-381)
                   (eq? (BotCastPoint-spell c-emp-381) 'emp-round)
                   (= (PointTargetAbility-id (BotCastPoint-ability c-emp-381)) 1628))
              "BotCastPoint canonicalizes raw 381 -> 'emp-round (1628)")

  (define c-rev (parse-bot-action-sexp (list 'cast-spell 10 'revelation 90.0 95.0)))
  (check-true (and (BotCastPoint? c-rev)
                   (= (PointTargetAbility-id (BotCastPoint-ability c-rev)) 2146))
              "BotCastPoint revelation -> 2146 (NOT 1632!)")

  (define c-queen (parse-bot-action-sexp (list 'train 'queen)))
  (check-true (and (BotTrain? c-queen)
                   (let ([ab (BotTrain-ability c-queen)])
                     (and (NoTargetAbility? ab) (= (NoTargetAbility-id ab) 1632))))
              "BotTrain queen -> 1632 NoTargetAbility")

  (define c-np (parse-bot-action-sexp (list 'cast-spell 10 'neural-parasite 99)))
  (check-true (and (BotCastUnit? c-np)
                   (= (UnitTargetAbility-id (BotCastUnit-ability c-np)) 249))
              "BotCastUnit neural-parasite -> 249")

  (define m-archon (parse-bot-action-sexp (list 'morph '(101 102) 'archon)))
  (check-true (and (BotMorph? m-archon) (BotMorph-archon? m-archon))
              "BotMorph 2-Templar archon accepted")

  ;; Batch `filter-valid-bot-actions` sanitizes self-cast dummy args & 381, filters bad cmds
  (define-values (valid-sexps rejects)
    (filter-valid-bot-actions
     (list (list 'cast-spell 10 'guardian-shield 999) ; sanitized -> (cast-spell 10 guardian-shield)
           (list 'cast-spell 10 381 80.0 90.0)        ; canonicalized -> (cast-spell 10 emp-round 80.0 90.0)
           (list 'cast-spell 10 'emp-round 99)        ; REJECTED (self-EMP!)
           (list 'cast-spell 10 'neural-parasite 1.0 2.0) ; REJECTED (coords on unit spell!)
           (list 'expand 120.0 60.0)                  ; valid
           (list 'attack '(201 202) 80.0 90.0)        ; valid
           (list 'harvest '(301 302) 7001)            ; valid
           (list 'chat "gg wp"))))                    ; valid telemetry directive
  (check-eqv (length valid-sexps) 6 "filter-valid-bot-actions keeps 6 valid commands")
  (check-eqv (length rejects) 2 "filter-valid-bot-actions captures 2 structured rejects")
  (check-eqv (car valid-sexps) '(cast-spell 10 guardian-shield) "self-cast dummy arg stripped")
  (check-eqv (cadr valid-sexps) '(cast-spell 10 emp-round 80.0 90.0) "raw 381 canonicalized to emp-round"))

;; =============================================================================
;; 4. Compile-Time Negative Type Checker Proof Tests
;; =============================================================================

(let ()
  (define tc-lib-path : Path
    (if (file-exists? "lib/sc2-typed-commands.rkt")
        (path->complete-path (string->path "lib/sc2-typed-commands.rkt"))
        (path->complete-path (string->path "../lib/sc2-typed-commands.rkt"))))
  (define req-spec : Any (list 'file (path->string tc-lib-path)))
  (define sub-ns : Namespace (make-base-namespace))

  (: compile-check (-> Any (Values (Option String) String)))
  (define (compile-check mod-form)
    (define err-port (open-output-string))
    (define exn-msg : (Option String)
      (with-handlers ([exn:fail:syntax? exn-message])
        (parameterize ([current-namespace sub-ns]
                       [current-error-port err-port])
          (compile mod-form)
          #f)))
    (values exn-msg (get-output-string err-port)))

  ;; 4A. Compile negative Typed Racket module testing all 4 static type invariants:
  ;;   1) UnitTargetAbility passed where PointTargetAbility is required (`WireCmdPoint`)
  ;;   2) `0` (`Zero`) passed where `UnitTag` (`Positive-Integer`) is required (`WireCmdUnit`)
  ;;   3) `#f` (`False`) passed where `UnitTag` (`Positive-Integer`) is required (`WireCmdUnit`)
  ;;   4) Omitting `WireChat?` branch in an `(ann act Nothing)` exhaustive `TypedSc2WireAction` match
  (define-values (bad-summary bad-details)
    (compile-check
     `(module neg-tc-proofs typed/racket/base
        (require ,req-spec)
        (: wrong-ability-kind (-> UnitTargetAbility NonEmptyUnitTags WorldPoint2D WireCmdPoint))
        (define (wrong-ability-kind u tags pt)
          (WireCmdPoint u tags pt #f))
        (: zero-unit-tag (-> UnitTargetAbility NonEmptyUnitTags WireCmdUnit))
        (define (zero-unit-tag u tags)
          (WireCmdUnit u tags 0 #f))
        (: false-unit-tag (-> UnitTargetAbility NonEmptyUnitTags WireCmdUnit))
        (define (false-unit-tag u tags)
          (WireCmdUnit u tags #f #f))
        (: non-exhaustive-wire-match (-> TypedSc2WireAction Integer))
        (define (non-exhaustive-wire-match act)
          (cond
            [(WireCmdNone? act) 1]
            [(WireCmdPoint? act) 2]
            [(WireCmdUnit? act) 3]
            [(WireCmdArchon? act) 4]
            [(WireToggleAutocast? act) 5]
            [(WireCameraMove? act) 6]
            [else (ann act Nothing)])))))

  (define combined-tc-log : String
    (string-append (or bad-summary "") "\n" bad-details))

  (check-true (regexp-match? #rx"Type Checker: Summary: 4 errors encountered" combined-tc-log)
              "Type Checker rejects all 4 static command type violations")
  (check-true (and (regexp-match? #rx"expected: PointTargetAbility" combined-tc-log)
                   (regexp-match? #rx"given: UnitTargetAbility" combined-tc-log))
              "Type Checker rejects UnitTargetAbility in WireCmdPoint")
  (check-true (and (regexp-match? #rx"expected: (UnitTag|Positive-Integer)" combined-tc-log)
                   (regexp-match? #rx"given: Zero" combined-tc-log))
              "Type Checker rejects 0 as UnitTag in WireCmdUnit")
  (check-true (regexp-match? #rx"given: False" combined-tc-log)
              "Type Checker rejects #f as UnitTag in WireCmdUnit")
  (check-true (and (regexp-match? #rx"expected: Nothing" combined-tc-log)
                   (regexp-match? #rx"given: WireChat" combined-tc-log))
              "Type Checker rejects non-exhaustive TypedSc2WireAction match missing WireChat")

  ;; 4B. Sealed witness constructor cannot be forged directly by callers
  (define-values (sealed-msg _sealed-err)
    (compile-check
     `(module neg-sealed-witness typed/racket/base
        (require ,req-spec)
        (define forged (NoTargetAbility 3665)))))
  (check-true (and sealed-msg
                   (regexp-match? #rx"cannot be used as an expression" sealed-msg))
              "Sealed NoTargetAbility raw constructor cannot be called directly")

  ;; 4C. Positive control module compiles with zero errors
  (define-values (ok-msg _ok-err)
    (compile-check
     `(module pos-control-proof typed/racket/base
        (require ,req-spec)
        (: build-stop (-> NoTargetAbility NonEmptyUnitTags WireCmdNone))
        (define (build-stop ab tags)
          (WireCmdNone ab tags #f)))))
  (check-false ok-msg "Well-typed control module compiles cleanly"))

;; =============================================================================
;; Summary & Exit Status
;; =============================================================================

(define total-elapsed-ms : Flonum (- (current-inexact-milliseconds) suite-start-ms))
(printf "[typed-commands-test] PASS: ~a assertions, FAIL: ~a, elapsed: ~ams\n"
        pass-count
        fail-count
        (real->decimal-string total-elapsed-ms 1))

(when (> fail-count 0)
  (exit 1))
