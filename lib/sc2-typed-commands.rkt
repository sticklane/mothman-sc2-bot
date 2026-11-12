#lang typed/racket/base

(require racket/math)

;; =============================================================================
;; lib/sc2-typed-commands.rkt
;; Sound, Zero-Slop Static Command Type System & Binary Protobuf Wire Serializer
;; =============================================================================
;;
;; Enforces SC2 LotV (`s2clientprotocol`) command invariants statically in
;; `#lang typed/racket/base`:
;;   1. Sealed capability/witness types (`NoTargetAbility`, `PointTargetAbility`,
;;      `UnitTargetAbility`, `AutocastAbility`, `WorldPoint2D`, `NonEmptyUnitTags`)
;;      with unexported raw constructors so invalid ability target modes,
;;      `NaN`/`Inf`/out-of-bounds coordinates, and empty `unit_tags` lists
;;      (`raw_affects_selection = #t` selection-wipe bug) are unrepresentable.
;;   2. Sealed `TypedSc2WireAction` ADT (`WireCmdNone`, `WireCmdPoint`,
;;      `WireCmdUnit`, `WireCmdArchon`, `WireToggleAutocast`, `WireCameraMove`,
;;      `WireChat`) with compile-time exhaustiveness proof `(ann act Nothing)`
;;      in `encode-typed-sc2-action` and round-trip `decode-typed-sc2-action`.
;;   3. Flat-primitive, zero-chaperone bridge `validate-legacy-wire-command`
;;      (`< 0.2 us` per call, `O(1)` vector witness lookup).
;;   4. High-level `TypedBotAction` ADT + total validator `parse-bot-action-sexp`
;;      and `filter-valid-bot-actions` eliminating self-EMP (`emp-round` given
;;      unit ID) and invalid point-on-unit spells (`neural-parasite` given X/Y).

(provide
 ;; Witness & Capability Types (raw struct constructors intentionally unexported!)
 UnitTag
 SC2-MAX-UINT64
 SC2-WORLD-COORD-MIN
 SC2-WORLD-COORD-MAX
 NoTargetAbility
 NoTargetAbility?
 NoTargetAbility-id
 PointTargetAbility
 PointTargetAbility?
 PointTargetAbility-id
 UnitTargetAbility
 UnitTargetAbility?
 UnitTargetAbility-id
 AutocastAbility
 AutocastAbility?
 AutocastAbility-id
 WorldPoint2D
 WorldPoint2D?
 WorldPoint2D-x
 WorldPoint2D-y
 NonEmptyUnitTags
 NonEmptyUnitTags?
 NonEmptyUnitTags-head
 NonEmptyUnitTags-tail
 non-empty-unit-tags->list

 ;; Total Smart Constructors & O(1) Ability Witness Lookups
 make-unit-tag
 make-non-empty-unit-tags
 filter-non-empty-unit-tags
 make-world-point2d
 lookup-no-target-ability
 lookup-point-target-ability
 lookup-unit-target-ability
 lookup-autocast-ability
 canonicalize-harvest-return-ability-id
 canonicalize-harvest-gather-ability-id

 ;; Sealed Wire-Level Action Union (`s2clientprotocol.Action`)
 (struct-out WireCmdNone)
 (struct-out WireCmdPoint)
 (struct-out WireCmdUnit)
 WireCmdArchon
 WireCmdArchon?
 WireCmdArchon-templar-a
 WireCmdArchon-templar-b
 WireCmdArchon-queue?
 (struct-out WireToggleAutocast)
 WireCameraMove
 WireCameraMove?
 WireCameraMove-center
 WireCameraMove-z
 WireChat
 WireChat?
 WireChat-team?
 WireChat-message
 TypedSc2WireAction
 TypedSc2WireAction?
 make-wire-cmd-unit
 make-wire-cmd-archon
 make-wire-camera-move
 make-wire-chat

 ;; Pure Typed Racket Protobuf Wire Codec & Zero-Chaperone Flat Bridge
 encode-typed-sc2-action
 decode-typed-sc2-action
 validate-legacy-wire-command

 ;; High-Level Bot Action ADT & Total S-Expression Validator
 (struct-out BotBuildStructure)
 (struct-out BotBuildGas)
 (struct-out BotBuildAddon)
 (struct-out BotBuildNydusWorm)
 (struct-out BotExpand)
 (struct-out BotTrain)
 (struct-out BotResearch)
 (struct-out BotMorph)
 (struct-out BotCastSelf)
 (struct-out BotCastPoint)
 (struct-out BotCastUnit)
 (struct-out BotAttackUnit)
 (struct-out BotAttackPos)
 (struct-out BotMoveOrder)
 (struct-out BotHoldPosition)
 (struct-out BotCancelBuilding)
 (struct-out BotModeSwitch)
 (struct-out BotHarvest)
 (struct-out BotWorkerMechanic)
 (struct-out BotTransportAction)
 (struct-out BotTerranAddonSwap)
 (struct-out BotTacticalManeuver)
 (struct-out BotCameraAction)
 (struct-out BotTelemetryDirective)
 TypedBotAction
 TypedBotAction?
 (struct-out BotActionReject)
 parse-bot-action-sexp
 typed-bot-action->sexp
 filter-valid-bot-actions)

;; =============================================================================
;; 1. Sealed Capability / Witness Types & Total Smart Constructors
;; =============================================================================

(define-type UnitTag Positive-Integer)

(define SC2-MAX-UINT64 : Positive-Integer #xFFFFFFFFFFFFFFFF)
(define SC2-WORLD-COORD-MIN : Flonum 0.0)
(define SC2-WORLD-COORD-MAX : Flonum 256.0)
(define SC2-ABILITY-TABLE-SIZE : Positive-Integer 4200)

(struct NoTargetAbility ([id : Positive-Integer])
  #:transparent
  #:constructor-name raw-NoTargetAbility)

(struct PointTargetAbility ([id : Positive-Integer])
  #:transparent
  #:constructor-name raw-PointTargetAbility)

(struct UnitTargetAbility ([id : Positive-Integer])
  #:transparent
  #:constructor-name raw-UnitTargetAbility)

(struct AutocastAbility ([id : Positive-Integer])
  #:transparent
  #:constructor-name raw-AutocastAbility)

(struct WorldPoint2D ([x : Flonum] [y : Flonum])
  #:transparent
  #:constructor-name raw-WorldPoint2D)

(struct NonEmptyUnitTags
  ([head : Positive-Integer]
   [tail : (Listof Positive-Integer)])
  #:transparent
  #:constructor-name raw-NonEmptyUnitTags)

(: non-empty-unit-tags->list
   (-> NonEmptyUnitTags (Pairof Positive-Integer (Listof Positive-Integer))))
(define (non-empty-unit-tags->list tags)
  (cons (NonEmptyUnitTags-head tags)
        (NonEmptyUnitTags-tail tags)))

(: make-unit-tag (-> Integer (Option Positive-Integer)))
(define (make-unit-tag raw)
  (if (and (> raw 0) (<= raw SC2-MAX-UINT64))
      raw
      #f))

(: memv-pos-int? (-> Positive-Integer (Listof Positive-Integer) Boolean))
(define (memv-pos-int? needle xs)
  (let loop ([cur : (Listof Positive-Integer) xs])
    (cond
      [(null? cur) #f]
      [(= (car cur) needle) #t]
      [else (loop (cdr cur))])))

;; Total smart constructor: requires ALL elements to be valid uint64 UnitTags (> 0),
;; deduplicates preserving first-seen order, and returns `#f` on empty or any <= 0 tag.
(: make-non-empty-unit-tags (-> (Listof Integer) (Option NonEmptyUnitTags)))
(define (make-non-empty-unit-tags raw-ids)
  (let loop ([rest : (Listof Integer) raw-ids]
             [rev-acc : (Listof Positive-Integer) '()])
    (cond
      [(null? rest)
       (define ordered (reverse rev-acc))
       (if (null? ordered)
           #f
           (raw-NonEmptyUnitTags (car ordered) (cdr ordered)))]
      [else
       (define valid (make-unit-tag (car rest)))
       (cond
         [(not valid) #f]
         [(memv-pos-int? valid rev-acc) (loop (cdr rest) rev-acc)]
         [else (loop (cdr rest) (cons valid rev-acc))])])))

;; Filtering companion for callers that want invalid/0 placeholders stripped before non-empty check.
(: filter-non-empty-unit-tags (-> (Listof Integer) (Option NonEmptyUnitTags)))
(define (filter-non-empty-unit-tags raw-ids)
  (let loop ([rest : (Listof Integer) raw-ids]
             [rev-acc : (Listof Positive-Integer) '()])
    (cond
      [(null? rest)
       (define ordered (reverse rev-acc))
       (if (null? ordered)
           #f
           (raw-NonEmptyUnitTags (car ordered) (cdr ordered)))]
      [else
       (define valid (make-unit-tag (car rest)))
       (cond
         [(not valid) (loop (cdr rest) rev-acc)]
         [(memv-pos-int? valid rev-acc) (loop (cdr rest) rev-acc)]
         [else (loop (cdr rest) (cons valid rev-acc))])])))

(: canonicalize-zero-flonum (-> Flonum Flonum))
(define (canonicalize-zero-flonum f)
  (if (= f 0.0) 0.0 f))

(: make-world-point2d (-> Real Real (Option WorldPoint2D)))
(define (make-world-point2d rx ry)
  (define fx : Flonum (real->double-flonum rx))
  (define fy : Flonum (real->double-flonum ry))
  (if (and (not (nan? fx))
           (not (infinite? fx))
           (not (nan? fy))
           (not (infinite? fy))
           (>= fx SC2-WORLD-COORD-MIN)
           (<= fx SC2-WORLD-COORD-MAX)
           (>= fy SC2-WORLD-COORD-MIN)
           (<= fy SC2-WORLD-COORD-MAX))
      (raw-WorldPoint2D (canonicalize-zero-flonum fx)
                        (canonicalize-zero-flonum fy))
      #f))

;; =============================================================================
;; 2. Ground-Truth LotV `ability_id` Witness Tables (`O(1)` Vector Dispatch)
;; =============================================================================
;;
;; Ground-truth verified against Blizzard `s2clientprotocol` LotV `ability_id`:
;;   - `1632` = `TRAINQUEEN_QUEEN` (`NoTarget`), NOT Oracle Revelation (`2146` `PointTarget`)!
;;   - `1628` = `EMP_EMP` (`PointTarget`); legacy `381` is NEVER accepted as a wire ability ID!
;;   - `3667` = `HARVEST_RETURN` (+ race aliases `167/296/299/1184`) is `NoTarget`!
;;   - `320` (`BUILD_REFINERY`), `882` (`BUILD_ASSIMILATOR`), `1154` (`BUILD_EXTRACTOR`)
;;     are strictly `UnitTarget` (vespene geyser `UnitTag`), NEVER `PointTarget`!
;;   - `1768` (`BUILD_NYDUSWORM`) is strictly `PointTarget`!
;;   - `1766` (`MORPH_ARCHON`) is excluded from `NoTargetAbility` so 1-Templar Archon morphs
;;     cannot bypass `WireCmdArchon` (`make-wire-cmd-archon` enforces 2 distinct Templar tags)!
;;   - `3692` is `RESEARCH_PROTOSSAIRARMOR` (`NoTarget`), NOT `BUILD_CREEPTUMOR_TUMOR` (`1733`)!
;;   - `1526` is `FORCEFIELD_FORCEFIELD` (`PointTarget`; `197` does not exist in LotV)!
;;   - Dual-mode `PointOrUnit`: `SMART (1)`, `MOVE (16, 3794)`, `PATROL (17, 3795)`,
;;     `ATTACK (23, 24, 25, 3674)`, `RALLY_* (195, 199, 203, 207, 211, 212, 3673, 3690)`,
;;     `UNLOADALLAT* (396, 913, 1408, 3669)`.
;;   - Dual-mode `PointOrNone`: Terran AddOns `421, 422, 454, 455, 487, 488, 3682, 3683`
;;     plus generic root/uproot `3680, 3681`.

(define NO-TARGET-ABILITY-VEC : (Vectorof (Option NoTargetAbility))
  (make-vector SC2-ABILITY-TABLE-SIZE #f))

(define POINT-TARGET-ABILITY-VEC : (Vectorof (Option PointTargetAbility))
  (make-vector SC2-ABILITY-TABLE-SIZE #f))

(define UNIT-TARGET-ABILITY-VEC : (Vectorof (Option UnitTargetAbility))
  (make-vector SC2-ABILITY-TABLE-SIZE #f))

(define AUTOCAST-ABILITY-VEC : (Vectorof (Option AutocastAbility))
  (make-vector SC2-ABILITY-TABLE-SIZE #f))

;; Strictly `NoTarget` abilities (excludes `1766` MORPH_ARCHON which requires `WireCmdArchon`)
(define STRICT-NO-TARGET-IDS : (Listof Positive-Integer)
  '(;; Stop / Hold / Return Cargo / Cancel / Salvage / LoadAll / UnloadAll
    4 11 18 32
    167 296 299 1184 3667
    304 306 308 310 312 314
    408 413 416
    451 484 517
    910 912 1038 1040 1182
    1217 1219 1221 1373 1411 1412 1438 1449 1451
    1517 1519 1521 1529 1531
    1623 1624 1626 1685 1686
    1724 1726 1728 1730 1732 1763 1798
    2051 2052 2075 2096 2107 2109 2113
    2331 2333 2354 2363 2365 2371
    2535 2594 2596 2709 2715
    3659 3663 3664 3665 3671 3688 3689 3707 3793
    4114 4122 4128 4130
    ;; Zerg Training (Larva + Queen 1632) & NoTarget Morphs
    1342 1343 1344 1345 1346 1348 1351 1352 1353 1354 1356 1632
    80 1216 1218 1220 1372 1448 1725 1727 2112 2330 2332 2708 3743 3745
    ;; Terran Training & NoTarget Morphs / Lift / Modes
    524 560 561 562 563 591 594 595 596 597 614 620 621 622 623 624 626 710
    388 390 403 405 417 452 485 518 556 558
    1450 1516 1522 1978 1998 2362 2364 2560 3679
    ;; Protoss Training & NoTarget Morphs / Modes
    110 916 917 919 920 921 922 946 948 950 954 955 976 977 978 979 994 1006
    1042 1518 1520 1528 1530 3739 3741
    ;; Self-Cast Buffs, Cloak, Burrow/Unburrow, Hallucinations
    76 146 148 150 152 154 156 158 160 162 164 181
    253 380 382 383 392 393
    1374 1376 1378 1380 1382 1384 1386 1388 1390 1392
    1433 1435 1444 1446 1512 1514 1683 1684
    2014 2016 2095 2097 2108 2110 2114 2116
    2328 2340 2342 2375 2376 2389 2391 2393
    3661 3662 3675 3676 3677 4124
    ;; Zerg / Terran / Protoss Research Abilities (including generic 3692..3706)
    44 48 216 217 263 265
    652 653 654 656 657 658
    730 731 732 761 764 765 766 769 790 799 805 820
    855 856 857 861 862 863 864 865 866
    1062 1063 1064 1065 1066 1067 1068 1069 1070
    1093 1094 1097 1126
    1186 1187 1188 1189 1190 1191 1192 1193 1194
    1223 1225 1252 1253 1282 1283
    1312 1313 1314 1315 1316 1317
    1455 1456 1482 1532
    1562 1563 1564 1565 1566 1567 1568 1571 1592 1593 1594
    2720
    3692 3693 3694 3695 3696 3697 3698 3699 3700 3701 3702 3703 3704 3705 3706
    3709 3710))

;; Dual-mode `PointOrNone` (Terran AddOns in-place or lift+land, plus generic 3680..3683)
(define POINT-OR-NONE-IDS : (Listof Positive-Integer)
  '(421 422 454 455 487 488 3680 3681 3682 3683))

;; Strictly `PointTarget` abilities (excludes gas 320/882/1154, excludes non-existent 197 & wrong 3692 & raw 381)
(define STRICT-POINT-TARGET-IDS : (Listof Positive-Integer)
  '(;; Zerg Ground Buildings, Nydus Worm (1768), Creep Tumors (1694, 1733, 3691), Crawler Root
    1152 1155 1156 1157 1158 1159 1160 1161 1162 1163 1165 1166 1167
    1694 1729 1731 1733 1768 3691
    ;; Terran Ground Buildings & Land
    318 319 321 322 323 324 326 327 328 329 331 333
    419 520 522 554 1524 3678
    ;; Protoss Ground Buildings & WarpGate Warp-Ins
    880 881 883 884 885 886 887 889 890 891 892 893 894 895
    1413 1414 1416 1417 1418 1419
    ;; Point-Target Active Spells & Area Effects
    74 142 349 399 1036 1442 1526 1622 1628 1764 1990
    2063 2146 2338 2346 2358 2368 2505 2544 2545 2558 2588 2698 2700
    3684 3686 3687 3757))

;; Dual-mode `PointOrUnit` (`SMART 1`, `MOVE 16/3794`, `PATROL 17/3795`, `ATTACK 23/24/25/3674`, Rallies, UnloadAllAt)
(define POINT-OR-UNIT-IDS : (Listof Positive-Integer)
  '(1 16 17 23 24 25
    195 199 203 207 211 212
    396 913 1408
    3669 3673 3674 3690 3794 3795))

;; Strictly `UnitTarget` abilities (Vespene Geysers 320/882/1154, Gather, Load, Unit Spells)
(define STRICT-UNIT-TARGET-IDS : (Listof Positive-Integer)
  '(;; Gas Buildings on Vespene Geyser UnitTag
    320 882 1154
    ;; Harvest Gather
    166 295 298 1183 3666
    ;; Transport / Bunker / Nydus Load
    394 407 911 1406 1437 2370 3668
    ;; Unit-Target Spells & Abilities
    78 140 171 173 249 251 255 261 316 384 386 401
    1664 1819 1825 2067 2069 2073 2099 2324 2350 2542 2714
    3685 3747 3751 3753 3755 4107 4113 4126))

;; Autocast-toggleable abilities (`ActionRawToggleAutocast`)
(define AUTOCAST-IDS : (Listof Positive-Integer)
  '(78 316 386 1042 1819 1990 2099 2328 2350 3685 4113))

(for ([id (in-list (append STRICT-NO-TARGET-IDS POINT-OR-NONE-IDS))])
  (when (< id SC2-ABILITY-TABLE-SIZE)
    (vector-set! NO-TARGET-ABILITY-VEC id (raw-NoTargetAbility id))))

(for ([id (in-list (append STRICT-POINT-TARGET-IDS POINT-OR-NONE-IDS POINT-OR-UNIT-IDS))])
  (when (< id SC2-ABILITY-TABLE-SIZE)
    (vector-set! POINT-TARGET-ABILITY-VEC id (raw-PointTargetAbility id))))

(for ([id (in-list (append STRICT-UNIT-TARGET-IDS POINT-OR-UNIT-IDS))])
  (when (< id SC2-ABILITY-TABLE-SIZE)
    (vector-set! UNIT-TARGET-ABILITY-VEC id (raw-UnitTargetAbility id))))

(for ([id (in-list AUTOCAST-IDS)])
  (when (< id SC2-ABILITY-TABLE-SIZE)
    (vector-set! AUTOCAST-ABILITY-VEC id (raw-AutocastAbility id))))

(: lookup-no-target-ability (-> Integer (Option NoTargetAbility)))
(define (lookup-no-target-ability id)
  (if (and (> id 0) (< id SC2-ABILITY-TABLE-SIZE))
      (vector-ref NO-TARGET-ABILITY-VEC id)
      #f))

(: lookup-point-target-ability (-> Integer (Option PointTargetAbility)))
(define (lookup-point-target-ability id)
  (if (and (> id 0) (< id SC2-ABILITY-TABLE-SIZE))
      (vector-ref POINT-TARGET-ABILITY-VEC id)
      #f))

(: lookup-unit-target-ability (-> Integer (Option UnitTargetAbility)))
(define (lookup-unit-target-ability id)
  (if (and (> id 0) (< id SC2-ABILITY-TABLE-SIZE))
      (vector-ref UNIT-TARGET-ABILITY-VEC id)
      #f))

(: lookup-autocast-ability (-> Integer (Option AutocastAbility)))
(define (lookup-autocast-ability id)
  (if (and (> id 0) (< id SC2-ABILITY-TABLE-SIZE))
      (vector-ref AUTOCAST-ABILITY-VEC id)
      #f))

(: canonicalize-harvest-return-ability-id (-> Integer Integer))
(define (canonicalize-harvest-return-ability-id ab-id)
  (case ab-id
    [(167 296 299 1184 3667) 3667]
    [else ab-id]))

(: canonicalize-harvest-gather-ability-id (-> Integer Integer))
(define (canonicalize-harvest-gather-ability-id ab-id)
  (case ab-id
    [(166 295 298 1183 3666) 3666]
    [else ab-id]))

;; =============================================================================
;; 3. Sealed `TypedSc2WireAction` ADT (`s2clientprotocol.Action`)
;; =============================================================================

(struct WireCmdNone
  ([ability : NoTargetAbility]
   [actors : NonEmptyUnitTags]
   [queue? : Boolean])
  #:transparent)

(struct WireCmdPoint
  ([ability : PointTargetAbility]
   [actors : NonEmptyUnitTags]
   [target : WorldPoint2D]
   [queue? : Boolean])
  #:transparent)

(struct WireCmdUnit
  ([ability : UnitTargetAbility]
   [actors : NonEmptyUnitTags]
   [target : Positive-Integer]
   [queue? : Boolean])
  #:transparent)

(struct WireCmdArchon
  ([templar-a : Positive-Integer]
   [templar-b : Positive-Integer]
   [queue? : Boolean])
  #:transparent
  #:constructor-name raw-WireCmdArchon)

(struct WireToggleAutocast
  ([ability : AutocastAbility]
   [actors : NonEmptyUnitTags])
  #:transparent)

(struct WireCameraMove
  ([center : WorldPoint2D]
   [z : Flonum])
  #:transparent
  #:constructor-name raw-WireCameraMove)

(struct WireChat
  ([team? : Boolean]
   [message : String])
  #:transparent
  #:constructor-name raw-WireChat)

(define-type TypedSc2WireAction
  (U WireCmdNone
     WireCmdPoint
     WireCmdUnit
     WireCmdArchon
     WireToggleAutocast
     WireCameraMove
     WireChat))

(: TypedSc2WireAction? (-> Any Boolean : TypedSc2WireAction))
(define (TypedSc2WireAction? v)
  (or (WireCmdNone? v)
      (WireCmdPoint? v)
      (WireCmdUnit? v)
      (WireCmdArchon? v)
      (WireToggleAutocast? v)
      (WireCameraMove? v)
      (WireChat? v)))

(: make-wire-cmd-unit
   (-> UnitTargetAbility NonEmptyUnitTags Integer Boolean (Option WireCmdUnit)))
(define (make-wire-cmd-unit ab actors raw-target queue?)
  (define tgt (make-unit-tag raw-target))
  (if tgt
      (WireCmdUnit ab actors tgt queue?)
      #f))

(: make-wire-cmd-archon (-> Integer Integer Boolean (Option WireCmdArchon)))
(define (make-wire-cmd-archon templar-a templar-b queue?)
  (define ta (make-unit-tag templar-a))
  (define tb (make-unit-tag templar-b))
  (if (and ta tb (not (= ta tb)))
      (raw-WireCmdArchon ta tb queue?)
      #f))

(define SC2-MAX-FLOAT32-ABS : Flonum 3.4028234e38)

(: make-wire-camera-move
   (case-> (-> WorldPoint2D Real (Option WireCameraMove))
           (-> Real Real Real (Option WireCameraMove))))
(define make-wire-camera-move
  (case-lambda
    [([center : WorldPoint2D] [rz : Real])
     (define fz : Flonum (real->double-flonum rz))
     (if (and (not (nan? fz)) (not (infinite? fz)) (<= (abs fz) SC2-MAX-FLOAT32-ABS))
         (raw-WireCameraMove center (canonicalize-zero-flonum fz))
         #f)]
    [([rx : Real] [ry : Real] [rz : Real])
     (define pt (make-world-point2d rx ry))
     (define fz : Flonum (real->double-flonum rz))
     (if (and pt (not (nan? fz)) (not (infinite? fz)) (<= (abs fz) SC2-MAX-FLOAT32-ABS))
         (raw-WireCameraMove pt (canonicalize-zero-flonum fz))
         #f)]))

(: make-wire-chat (-> Boolean String (Option WireChat)))
(define (make-wire-chat team? msg)
  (define blen (bytes-length (string->bytes/utf-8 msg)))
  (if (and (> blen 0) (<= blen 256))
      (raw-WireChat team? msg)
      #f))

;; =============================================================================
;; 4. Pure Typed Racket Binary Protobuf Codec (`s2clientprotocol.Action`)
;; =============================================================================
;;
;; Wire schema (`data/proto/sc2api.proto` & `data/proto/raw.proto`, matching
;; `lib/sc2-protobuf-ws.rkt:1846-1905` byte-for-byte):
;;   Action:
;;     field 1 (len-delimited #x0A) = ActionRaw
;;     field 6 (len-delimited #x32) = ActionChat
;;       ActionChat: field 1 (varint #x08) = Channel (1=Broadcast, 2=Team)
;;                   field 2 (len-delimited #x12) = message (UTF-8)
;;   ActionRaw:
;;     field 1 (len-delimited #x0A) = ActionRawUnitCommand
;;     field 2 (len-delimited #x12) = ActionRawCameraMove
;;     field 3 (len-delimited #x1A) = ActionRawToggleAutocast
;;   ActionRawUnitCommand:
;;     field 1 (varint #x08)        = ability_id
;;     field 2 (len-delimited #x12) = Point2D (field 1 float32 LE x, field 2 float32 LE y)
;;     field 3 (varint #x18)        = target_unit_tag (uint64)
;;     field 4 (varint #x20)        = repeated unit_tags (uint64)
;;     field 5 (varint #x28)        = queue_command (bool, omitted when #f)
;;   ActionRawCameraMove:
;;     field 1 (len-delimited #x0A) = Point (field 1 float32 LE x, field 2 y, field 3 z)
;;   ActionRawToggleAutocast:
;;     field 1 (varint #x08)        = ability_id
;;     field 2 (varint #x10)        = repeated unit_tags (uint64)

(: encode-varint-uint (-> Natural Bytes))
(define (encode-varint-uint n)
  (define masked : Natural (bitwise-and n #xFFFFFFFFFFFFFFFF))
  (let loop ([val : Natural masked]
             [rev-bytes : (Listof Byte) '()])
    (define low7 : Byte (bitwise-and val #x7F))
    (define rest : Natural (arithmetic-shift val -7))
    (if (zero? rest)
        (list->bytes (reverse (cons low7 rev-bytes)))
        (loop rest (cons (bitwise-ior low7 #x80) rev-bytes)))))

(: encode-varint-field (-> Positive-Integer Natural Bytes))
(define (encode-varint-field field-num val)
  (bytes-append (encode-varint-uint (arithmetic-shift field-num 3))
                (encode-varint-uint val)))

(: encode-float32-field (-> Positive-Integer Flonum Bytes))
(define (encode-float32-field field-num val)
  (bytes-append (encode-varint-uint (bitwise-ior (arithmetic-shift field-num 3) 5))
                (real->floating-point-bytes val 4 #f)))

(: encode-len-field (-> Positive-Integer Bytes Bytes))
(define (encode-len-field field-num payload)
  (bytes-append (encode-varint-uint (bitwise-ior (arithmetic-shift field-num 3) 2))
                (encode-varint-uint (bytes-length payload))
                payload))

(: encode-point2d-msg (-> WorldPoint2D Bytes))
(define (encode-point2d-msg pt)
  (bytes-append (encode-float32-field 1 (WorldPoint2D-x pt))
                (encode-float32-field 2 (WorldPoint2D-y pt))))

(: encode-point3d-msg (-> WorldPoint2D Flonum Bytes))
(define (encode-point3d-msg pt z)
  (bytes-append (encode-float32-field 1 (WorldPoint2D-x pt))
                (encode-float32-field 2 (WorldPoint2D-y pt))
                (encode-float32-field 3 z)))

(: encode-repeated-unit-tags (-> Positive-Integer NonEmptyUnitTags Bytes))
(define (encode-repeated-unit-tags field-num tags)
  (apply bytes-append
         (cons (encode-varint-field field-num (NonEmptyUnitTags-head tags))
               (for/list : (Listof Bytes) ([ut (in-list (NonEmptyUnitTags-tail tags))])
                 (encode-varint-field field-num ut)))))

(: wrap-action-raw-unit-command (-> Bytes Bytes))
(define (wrap-action-raw-unit-command uc-bytes)
  (encode-len-field 1 (encode-len-field 1 uc-bytes)))

(: encode-typed-sc2-action (-> TypedSc2WireAction Bytes))
(define (encode-typed-sc2-action act)
  (cond
    [(WireCmdNone? act)
     (define uc-bytes
       (bytes-append
        (encode-varint-field 1 (NoTargetAbility-id (WireCmdNone-ability act)))
        (encode-repeated-unit-tags 4 (WireCmdNone-actors act))
        (if (WireCmdNone-queue? act) #"\x28\x01" #"")))
     (wrap-action-raw-unit-command uc-bytes)]
    [(WireCmdPoint? act)
     (define uc-bytes
       (bytes-append
        (encode-varint-field 1 (PointTargetAbility-id (WireCmdPoint-ability act)))
        (encode-len-field 2 (encode-point2d-msg (WireCmdPoint-target act)))
        (encode-repeated-unit-tags 4 (WireCmdPoint-actors act))
        (if (WireCmdPoint-queue? act) #"\x28\x01" #"")))
     (wrap-action-raw-unit-command uc-bytes)]
    [(WireCmdUnit? act)
     (define tgt-u64 : Natural
       (bitwise-and (WireCmdUnit-target act) #xFFFFFFFFFFFFFFFF))
     (define uc-bytes
       (bytes-append
        (encode-varint-field 1 (UnitTargetAbility-id (WireCmdUnit-ability act)))
        (encode-varint-field 3 tgt-u64)
        (encode-repeated-unit-tags 4 (WireCmdUnit-actors act))
        (if (WireCmdUnit-queue? act) #"\x28\x01" #"")))
     (wrap-action-raw-unit-command uc-bytes)]
    [(WireCmdArchon? act)
     ;; MORPH_ARCHON = 1766, strictly 2 distinct allied Templar tags, no target
     (define uc-bytes
       (bytes-append
        (encode-varint-field 1 1766)
        (encode-varint-field 4 (WireCmdArchon-templar-a act))
        (encode-varint-field 4 (WireCmdArchon-templar-b act))
        (if (WireCmdArchon-queue? act) #"\x28\x01" #"")))
     (wrap-action-raw-unit-command uc-bytes)]
    [(WireToggleAutocast? act)
     (define ac-bytes
       (bytes-append
        (encode-varint-field 1 (AutocastAbility-id (WireToggleAutocast-ability act)))
        (encode-repeated-unit-tags 2 (WireToggleAutocast-actors act))))
     (encode-len-field 1 (encode-len-field 3 ac-bytes))]
    [(WireCameraMove? act)
     (define cm-bytes
       (encode-len-field 1 (encode-point3d-msg (WireCameraMove-center act)
                                               (WireCameraMove-z act))))
     (encode-len-field 1 (encode-len-field 2 cm-bytes))]
    [(WireChat? act)
     (define chan : Natural (if (WireChat-team? act) 2 1))
     (define chat-bytes
       (bytes-append
        (encode-varint-field 1 chan)
        (encode-len-field 2 (string->bytes/utf-8 (WireChat-message act)))))
     (encode-len-field 6 chat-bytes)]
    [else
     (ann act Nothing)]))

;; -----------------------------------------------------------------------------
;; Total Non-Throwing Binary Protobuf Decoder (`decode-typed-sc2-action`)
;; -----------------------------------------------------------------------------

(struct PbVarintField ([field : Natural] [val : Natural]) #:transparent)
(struct PbBytesField ([field : Natural] [data : Bytes]) #:transparent)
(struct PbFixed32Field ([field : Natural] [data : Bytes]) #:transparent)
(define-type PbField (U PbVarintField PbBytesField PbFixed32Field))

(: decode-varint-safe (-> Bytes Natural Natural (Values (Option Natural) Natural)))
(define (decode-varint-safe bstr start end)
  (let loop ([idx : Natural start]
             [shift : Natural 0]
             [acc : Natural 0])
    (cond
      [(or (>= idx end) (> shift 63)) (values #f idx)]
      [else
       (define b : Byte (bytes-ref bstr idx))
       (cond
         [(and (= shift 63) (> b 1))
          (values #f idx)]
         [else
          (define next-acc : Natural
            (bitwise-ior acc (arithmetic-shift (bitwise-and b #x7F) shift)))
          (if (zero? (bitwise-and b #x80))
              (values next-acc (add1 idx))
              (loop (add1 idx) (+ shift 7) next-acc))])])))

(: decode-pb-fields (-> Bytes (Option (Listof PbField))))
(define (decode-pb-fields bstr)
  (define end : Natural (bytes-length bstr))
  (let loop ([pos : Natural 0]
             [rev : (Listof PbField) '()])
    (cond
      [(= pos end) (reverse rev)]
      [(> pos end) #f]
      [else
       (define-values (tag next-pos) (decode-varint-safe bstr pos end))
       (cond
         [(not tag) #f]
         [else
          (define fnum : Natural (arithmetic-shift tag -3))
          (define wtype : Natural (bitwise-and tag #x07))
          (cond
            [(or (= fnum 0) (> fnum #x1FFFFFFF)) #f]
            [(= wtype 0)
             (define-values (v pos2) (decode-varint-safe bstr next-pos end))
             (if v
                 (loop pos2 (cons (PbVarintField fnum v) rev))
                 #f)]
            [(= wtype 2)
             (define-values (len pos-len) (decode-varint-safe bstr next-pos end))
             (if (and len (<= (+ pos-len len) end))
                 (loop (+ pos-len len)
                       (cons (PbBytesField fnum (subbytes bstr pos-len (+ pos-len len))) rev))
                 #f)]
            [(= wtype 5)
             (if (<= (+ next-pos 4) end)
                 (loop (+ next-pos 4)
                       (cons (PbFixed32Field fnum (subbytes bstr next-pos (+ next-pos 4))) rev))
                 #f)]
            [else #f])])])))

(: decode-float32-le (-> Bytes Flonum))
(define (decode-float32-le b4)
  (real->double-flonum (floating-point-bytes->real b4 #f 0 4)))

(: decode-point2d-bytes (-> Bytes (Option WorldPoint2D)))
(define (decode-point2d-bytes bstr)
  (define fields (decode-pb-fields bstr))
  (cond
    [(not fields) #f]
    [else
     (define x-box : (Option Flonum) #f)
     (define y-box : (Option Flonum) #f)
     (define bad? : Boolean #f)
     (for ([f (in-list fields)])
       (cond
         [(PbFixed32Field? f)
          (case (PbFixed32Field-field f)
            [(1)
             (if x-box
                 (set! bad? #t)
                 (set! x-box (decode-float32-le (PbFixed32Field-data f))))]
            [(2)
             (if y-box
                 (set! bad? #t)
                 (set! y-box (decode-float32-le (PbFixed32Field-data f))))]
            [else (set! bad? #t)])]
         [else (set! bad? #t)]))
     (define xv x-box)
     (define yv y-box)
     (if (and (not bad?) xv yv)
         (make-world-point2d xv yv)
         #f)]))

(: decode-point3d-bytes (-> Bytes (Option (Pairof WorldPoint2D Flonum))))
(define (decode-point3d-bytes bstr)
  (define fields (decode-pb-fields bstr))
  (cond
    [(not fields) #f]
    [else
     (define x-box : (Option Flonum) #f)
     (define y-box : (Option Flonum) #f)
     (define z-box : (Option Flonum) #f)
     (define bad? : Boolean #f)
     (for ([f (in-list fields)])
       (cond
         [(PbFixed32Field? f)
          (case (PbFixed32Field-field f)
            [(1)
             (if x-box
                 (set! bad? #t)
                 (set! x-box (decode-float32-le (PbFixed32Field-data f))))]
            [(2)
             (if y-box
                 (set! bad? #t)
                 (set! y-box (decode-float32-le (PbFixed32Field-data f))))]
            [(3)
             (if z-box
                 (set! bad? #t)
                 (set! z-box (decode-float32-le (PbFixed32Field-data f))))]
            [else (set! bad? #t)])]
         [else (set! bad? #t)]))
     (define xv x-box)
     (define yv y-box)
     (define zv (or z-box 0.0))
     (define pt (if (and (not bad?) xv yv) (make-world-point2d xv yv) #f))
     (if (and pt (not (nan? zv)) (not (infinite? zv)) (<= (abs zv) SC2-MAX-FLOAT32-ABS))
         (cons pt (canonicalize-zero-flonum zv))
         #f)]))

(: unique-positive-tags? (-> (Listof Integer) Boolean))
(define (unique-positive-tags? xs)
  (and (pair? xs)
       (let ([dedup (make-non-empty-unit-tags xs)])
         (and dedup
              (= (length (non-empty-unit-tags->list dedup)) (length xs))))))

(: decode-unit-command-bytes (-> Bytes (Option TypedSc2WireAction)))
(define (decode-unit-command-bytes bstr)
  (define fields (decode-pb-fields bstr))
  (cond
    [(not fields) #f]
    [else
     (define ab-id : Integer 0)
     (define has-ab-id? : Boolean #f)
     (define pos-bytes : (Option Bytes) #f)
     (define tgt-tag : Integer 0)
     (define has-tgt-tag? : Boolean #f)
     (define raw-actors : (Listof Integer) '())
     (define queue? : Boolean #f)
     (define has-queue? : Boolean #f)
     (define bad? : Boolean #f)
     (for ([f (in-list fields)])
       (cond
         [(PbVarintField? f)
          (case (PbVarintField-field f)
            [(1)
             (if has-ab-id?
                 (set! bad? #t)
                 (begin
                   (set! has-ab-id? #t)
                   (set! ab-id (PbVarintField-val f))))]
            [(3)
             (if has-tgt-tag?
                 (set! bad? #t)
                 (begin
                   (set! has-tgt-tag? #t)
                   (set! tgt-tag (PbVarintField-val f))))]
            [(4) (set! raw-actors (cons (PbVarintField-val f) raw-actors))]
            [(5)
             (define qv (PbVarintField-val f))
             (if (or has-queue? (> qv 1))
                 (set! bad? #t)
                 (begin
                   (set! has-queue? #t)
                   (set! queue? (= qv 1))))]
            [else (set! bad? #t)])]
         [(PbBytesField? f)
          (if (and (= (PbBytesField-field f) 2) (not pos-bytes))
              (set! pos-bytes (PbBytesField-data f))
              (set! bad? #t))]
         [else (set! bad? #t)]))
     (define pb pos-bytes)
     (define ht? has-tgt-tag?)
     (define tt tgt-tag)
     (define aid ab-id)
     (define acts (reverse raw-actors))
     (define q? queue?)
     (cond
       [(or bad? (not has-ab-id?) (not (unique-positive-tags? acts))) #f]
       [(and pb ht?) #f] ;; `oneof target` violation!
       [pb
        (define pt (decode-point2d-bytes pb))
        (if pt
            (validate-legacy-wire-command
             aid #t (WorldPoint2D-x pt) (WorldPoint2D-y pt) 0 acts q?)
            #f)]
       [ht?
        (if (<= tt 0)
            #f
            (validate-legacy-wire-command
             aid #f 0.0 0.0 tt acts q?))]
       [else
        ;; Strict wire check: do not accept harvest aliases as wrong target modes;
        ;; validate-legacy-wire-command checks lookup-no-target-ability
        (validate-legacy-wire-command
         aid #f 0.0 0.0 0 acts q?)])]))

(: decode-toggle-autocast-bytes (-> Bytes (Option TypedSc2WireAction)))
(define (decode-toggle-autocast-bytes bstr)
  (define fields (decode-pb-fields bstr))
  (cond
    [(not fields) #f]
    [else
     (define ab-id : Integer 0)
     (define has-ab-id? : Boolean #f)
     (define raw-actors : (Listof Integer) '())
     (define bad? : Boolean #f)
     (for ([f (in-list fields)])
       (if (PbVarintField? f)
           (case (PbVarintField-field f)
             [(1)
              (if has-ab-id?
                  (set! bad? #t)
                  (begin
                    (set! has-ab-id? #t)
                    (set! ab-id (PbVarintField-val f))))]
             [(2) (set! raw-actors (cons (PbVarintField-val f) raw-actors))]
             [else (set! bad? #t)])
           (set! bad? #t)))
     (define ab (lookup-autocast-ability ab-id))
     (define ordered-actors (reverse raw-actors))
     (define actors (make-non-empty-unit-tags ordered-actors))
     (if (and (not bad?)
              has-ab-id?
              ab
              actors
              (= (length (non-empty-unit-tags->list actors)) (length ordered-actors)))
         (WireToggleAutocast ab actors)
         #f)]))

(: decode-camera-move-bytes (-> Bytes (Option TypedSc2WireAction)))
(define (decode-camera-move-bytes bstr)
  (define fields (decode-pb-fields bstr))
  (cond
    [(and fields (pair? fields) (null? (cdr fields)))
     (define f0 (car fields))
     (if (and (PbBytesField? f0) (= (PbBytesField-field f0) 1))
         (let ([p3 (decode-point3d-bytes (PbBytesField-data f0))])
           (if p3
               (make-wire-camera-move (car p3) (cdr p3))
               #f))
         #f)]
    [else #f]))

(: decode-chat-bytes (-> Bytes (Option TypedSc2WireAction)))
(define (decode-chat-bytes bstr)
  (define fields (decode-pb-fields bstr))
  (cond
    [(not fields) #f]
    [else
     (define chan : Natural 0)
     (define has-chan? : Boolean #f)
     (define msg-bytes : (Option Bytes) #f)
     (define bad? : Boolean #f)
     (for ([f (in-list fields)])
       (cond
         [(and (PbVarintField? f) (= (PbVarintField-field f) 1) (not has-chan?))
          (set! has-chan? #t)
          (set! chan (PbVarintField-val f))]
         [(and (PbBytesField? f) (= (PbBytesField-field f) 2) (not msg-bytes))
          (set! msg-bytes (PbBytesField-data f))]
         [else (set! bad? #t)]))
     (define ch chan)
     (define mb msg-bytes)
     (if (and (not bad?) has-chan? mb (or (= ch 1) (= ch 2)))
         (with-handlers ([exn:fail? (lambda (_e) #f)])
           (make-wire-chat (= ch 2) (bytes->string/utf-8 mb)))
         #f)]))

(: decode-typed-sc2-action (-> Bytes (Option TypedSc2WireAction)))
(define (decode-typed-sc2-action bstr)
  (define top (decode-pb-fields bstr))
  (cond
    [(not (and top (pair? top) (null? (cdr top)))) #f]
    [else
     (define f0 (car top))
     (cond
       [(not (PbBytesField? f0)) #f]
       [(= (PbBytesField-field f0) 1)
        (define raw-fields (decode-pb-fields (PbBytesField-data f0)))
        (cond
          [(not (and raw-fields (pair? raw-fields) (null? (cdr raw-fields)))) #f]
          [else
           (define rf (car raw-fields))
           (cond
             [(not (PbBytesField? rf)) #f]
             [(= (PbBytesField-field rf) 1) (decode-unit-command-bytes (PbBytesField-data rf))]
             [(= (PbBytesField-field rf) 2) (decode-camera-move-bytes (PbBytesField-data rf))]
             [(= (PbBytesField-field rf) 3) (decode-toggle-autocast-bytes (PbBytesField-data rf))]
             [else #f])])]
       [(= (PbBytesField-field f0) 6)
        (decode-chat-bytes (PbBytesField-data f0))]
       [else #f])]))

;; -----------------------------------------------------------------------------
;; Zero-Chaperone Flat Bridge (`validate-legacy-wire-command`)
;; -----------------------------------------------------------------------------

(: validate-legacy-wire-command
   (-> Integer Boolean Flonum Flonum Integer (Listof Integer) Boolean
       (Option TypedSc2WireAction)))
(define (validate-legacy-wire-command ab-id has-point? px py target-tag unit-tags queue?)
  (cond
    [(< target-tag 0) #f]
    [(and has-point? (> target-tag 0)) #f] ;; `oneof target` mutual exclusion
    [(= ab-id 1766)
     ;; MORPH_ARCHON requires no target and strictly 2 distinct allied Templar tags
     (if (or has-point? (> target-tag 0))
         #f
         (let ([actors (make-non-empty-unit-tags unit-tags)])
           (if (and actors
                    (pair? (NonEmptyUnitTags-tail actors))
                    (null? (cdr (NonEmptyUnitTags-tail actors))))
               (make-wire-cmd-archon (NonEmptyUnitTags-head actors)
                                     (car (NonEmptyUnitTags-tail actors))
                                     queue?)
               #f)))]
    [has-point?
     (define ab (lookup-point-target-ability ab-id))
     (define pt (make-world-point2d px py))
     (define actors (make-non-empty-unit-tags unit-tags))
     (if (and ab pt actors)
         (WireCmdPoint ab actors pt queue?)
         #f)]
    [(> target-tag 0)
     (define eff-ab-id (canonicalize-harvest-gather-ability-id ab-id))
     (define ab (lookup-unit-target-ability eff-ab-id))
     (define tgt (make-unit-tag target-tag))
     (define actors (make-non-empty-unit-tags unit-tags))
     (if (and ab tgt actors)
         (WireCmdUnit ab actors tgt queue?)
         #f)]
    [else
     (define eff-ab-id (canonicalize-harvest-return-ability-id ab-id))
     (define ab (lookup-no-target-ability eff-ab-id))
     (define actors (make-non-empty-unit-tags unit-tags))
     (if (and ab actors)
         (WireCmdNone ab actors queue?)
         #f)]))

;; =============================================================================
;; 5. High-Level `TypedBotAction` ADT & Total S-Expression Validator
;; =============================================================================

(struct BotBuildStructure
  ([structure : Symbol]
   [pos : (Option WorldPoint2D)]
   [ability : PointTargetAbility])
  #:transparent)

(struct BotBuildGas
  ([gas-building : Symbol]
   [pos : (Option WorldPoint2D)]
   [ability : UnitTargetAbility])
  #:transparent)

(struct BotBuildAddon
  ([addon : Symbol]
   [pos : (Option WorldPoint2D)]
   [ability : NoTargetAbility])
  #:transparent)

(struct BotBuildNydusWorm
  ([actors : (Option NonEmptyUnitTags)]
   [target : WorldPoint2D]
   [ability : PointTargetAbility])
  #:transparent)

(struct BotExpand
  ([townhall : (Option Symbol)]
   [target : WorldPoint2D])
  #:transparent)

(struct BotTrain
  ([producer-id : (Option Positive-Integer)]
   [unit : Symbol]
   [ability : (U NoTargetAbility PointTargetAbility)])
  #:transparent)

(struct BotResearch
  ([upgrade : Symbol]
   [ability : NoTargetAbility])
  #:transparent)

(struct BotMorph
  ([actors : (Option NonEmptyUnitTags)]
   [target : Symbol]
   [ability : (U NoTargetAbility PointTargetAbility)]
   [archon? : Boolean])
  #:transparent)

(struct BotCastSelf
  ([actors : NonEmptyUnitTags]
   [spell : Symbol]
   [ability : NoTargetAbility])
  #:transparent)

(struct BotCastPoint
  ([actors : NonEmptyUnitTags]
   [spell : Symbol]
   [ability : PointTargetAbility]
   [target : WorldPoint2D])
  #:transparent)

(struct BotCastUnit
  ([actors : NonEmptyUnitTags]
   [spell : Symbol]
   [ability : UnitTargetAbility]
   [target : Positive-Integer])
  #:transparent)

(struct BotAttackUnit
  ([kind : Symbol]
   [actors : NonEmptyUnitTags]
   [target : Positive-Integer]
   [fallback : (Option WorldPoint2D)])
  #:transparent)

(struct BotAttackPos
  ([kind : Symbol]
   [actors : NonEmptyUnitTags]
   [target : WorldPoint2D])
  #:transparent)

(struct BotMoveOrder
  ([kind : Symbol]
   [actors : NonEmptyUnitTags]
   [target : WorldPoint2D])
  #:transparent)

(struct BotHoldPosition
  ([actors : NonEmptyUnitTags]
   [target : (Option WorldPoint2D)])
  #:transparent)

(struct BotCancelBuilding
  ([actor : Positive-Integer])
  #:transparent)

(struct BotModeSwitch
  ([mode : Symbol]
   [actors : NonEmptyUnitTags]
   [ability : NoTargetAbility])
  #:transparent)

(struct BotHarvest
  ([kind : Symbol]
   [workers : NonEmptyUnitTags]
   [target-id : Positive-Integer])
  #:transparent)

(struct BotWorkerMechanic
  ([kind : Symbol]
   [workers : NonEmptyUnitTags]
   [patch-id : (Option Positive-Integer)]
   [target-id : (Option Positive-Integer)]
   [target : WorldPoint2D]
   [secondary : (Option WorldPoint2D)])
  #:transparent)

(struct BotTransportAction
  ([kind : Symbol]
   [transport : Positive-Integer]
   [passengers : (Option NonEmptyUnitTags)]
   [target : (Option WorldPoint2D)])
  #:transparent)

(struct BotTerranAddonSwap
  ([lift-id : Natural]
   [land-id : Positive-Integer]
   [addon-pos : (Option WorldPoint2D)])
  #:transparent)

(struct BotTacticalManeuver
  ([kind : Symbol]
   [anchor : (Option WorldPoint2D)]
   [params : (Listof Any)])
  #:transparent)

(struct BotCameraAction
  ([kind : Symbol]
   [slot : (Option Natural)]
   [target : WorldPoint2D])
  #:transparent)

(struct BotTelemetryDirective
  ([head : Symbol]
   [payload : (Listof Any)])
  #:transparent)

(define-type TypedBotAction
  (U BotBuildStructure
     BotBuildGas
     BotBuildAddon
     BotBuildNydusWorm
     BotExpand
     BotTrain
     BotResearch
     BotMorph
     BotCastSelf
     BotCastPoint
     BotCastUnit
     BotAttackUnit
     BotAttackPos
     BotMoveOrder
     BotHoldPosition
     BotCancelBuilding
     BotModeSwitch
     BotHarvest
     BotWorkerMechanic
     BotTransportAction
     BotTerranAddonSwap
     BotTacticalManeuver
     BotCameraAction
     BotTelemetryDirective))

(: TypedBotAction? (-> Any Boolean : TypedBotAction))
(define (TypedBotAction? v)
  (or (BotBuildStructure? v)
      (BotBuildGas? v)
      (BotBuildAddon? v)
      (BotBuildNydusWorm? v)
      (BotExpand? v)
      (BotTrain? v)
      (BotResearch? v)
      (BotMorph? v)
      (BotCastSelf? v)
      (BotCastPoint? v)
      (BotCastUnit? v)
      (BotAttackUnit? v)
      (BotAttackPos? v)
      (BotMoveOrder? v)
      (BotHoldPosition? v)
      (BotCancelBuilding? v)
      (BotModeSwitch? v)
      (BotHarvest? v)
      (BotWorkerMechanic? v)
      (BotTransportAction? v)
      (BotTerranAddonSwap? v)
      (BotTacticalManeuver? v)
      (BotCameraAction? v)
      (BotTelemetryDirective? v)))

(struct BotActionReject
  ([reason : Symbol]
   [raw : Any])
  #:transparent)

;; -----------------------------------------------------------------------------
;; Canonical Symbol Normalization & High-Level Lookup Tables
;; -----------------------------------------------------------------------------

(: normalize-name-str (-> String String))
(define (normalize-name-str s)
  (define len (string-length s))
  (define out (make-string len #\a))
  (for ([i (in-range len)])
    (define ch (char-downcase (string-ref s i)))
    (string-set! out i (if (char=? ch #\_) #\- ch)))
  out)

(: extract-norm-symbol (-> Any (Option Symbol)))
(define (extract-norm-symbol v)
  (cond
    [(symbol? v)
     (string->symbol (normalize-name-str (symbol->string v)))]
    [(and (pair? v)
          (eq? (car v) 'quote)
          (pair? (cdr v))
          (null? (cddr v))
          (symbol? (cadr v)))
     (string->symbol (normalize-name-str (symbol->string (cadr v))))]
    [else #f]))

(: extract-actor-tags (-> Any (Option NonEmptyUnitTags)))
(define (extract-actor-tags v)
  (cond
    [(exact-integer? v)
     (define t (make-unit-tag v))
     (if t (raw-NonEmptyUnitTags t '()) #f)]
    [(and (pair? v) (list? v))
     (let loop ([cur : (Listof Any) v]
                [acc : (Listof Integer) '()])
       (cond
         [(null? cur) (make-non-empty-unit-tags (reverse acc))]
         [(exact-integer? (car cur))
          (loop (cdr cur) (cons (car cur) acc))]
         [else #f]))]
    [else #f]))

(: extract-unit-tag (-> Any (Option Positive-Integer)))
(define (extract-unit-tag v)
  (if (exact-integer? v)
      (make-unit-tag v)
      #f))

(: extract-optional-unit-tag (-> Any (Values Boolean (Option Positive-Integer))))
(define (extract-optional-unit-tag v)
  (cond
    [(not (exact-integer? v)) (values #f #f)]
    [(= v 0) (values #t #f)]
    [else
     (define t (make-unit-tag v))
     (if t (values #t t) (values #f #f))]))

(: extract-world-point2d (-> Any Any (Option WorldPoint2D)))
(define (extract-world-point2d rx ry)
  (if (and (real? rx) (real? ry))
      (make-world-point2d rx ry)
      #f))

;; Build tables
(define BUILD-POINT-TABLE : (Immutable-HashTable Symbol Positive-Integer)
  (make-immutable-hasheq
   '((hatchery . 1152)
     (spawning-pool . 1155)
     (evolution-chamber . 1156)
     (hydralisk-den . 1157)
     (spire . 1158)
     (ultralisk-cavern . 1159)
     (infestation-pit . 1160)
     (nydus-network . 1161)
     (baneling-nest . 1162)
     (lurker-den . 1163)
     (lurker-den-mp . 1163)
     (roach-warren . 1165)
     (spine-crawler . 1166)
     (spore-crawler . 1167)
     (creep-tumor . 3691)
     (command-center . 318)
     (supply-depot . 319)
     (barracks . 321)
     (engineering-bay . 322)
     (missile-turret . 323)
     (bunker . 324)
     (sensor-tower . 326)
     (ghost-academy . 327)
     (factory . 328)
     (starport . 329)
     (armory . 331)
     (fusion-core . 333)
     (nexus . 880)
     (pylon . 881)
     (gateway . 883)
     (forge . 884)
     (fleet-beacon . 885)
     (twilight-council . 886)
     (photon-cannon . 887)
     (stargate . 889)
     (templar-archive . 890)
     (templar-archives . 890)
     (dark-shrine . 891)
     (robotics-bay . 892)
     (robotics-support-bay . 892)
     (robotics-facility . 893)
     (cybernetics-core . 894)
     (shield-battery . 895))))

(define BUILD-GAS-TABLE : (Immutable-HashTable Symbol Positive-Integer)
  (make-immutable-hasheq
   '((refinery . 320)
     (assimilator . 882)
     (extractor . 1154))))

(define BUILD-ADDON-TABLE : (Immutable-HashTable Symbol Positive-Integer)
  (make-immutable-hasheq
   '((tech-lab . 3682)
     (techlab . 3682)
     (reactor . 3683)
     (barracks-tech-lab . 421)
     (barracks-techlab . 421)
     (barracks-reactor . 422)
     (factory-tech-lab . 454)
     (factory-techlab . 454)
     (factory-reactor . 455)
     (starport-tech-lab . 487)
     (starport-techlab . 487)
     (starport-reactor . 488))))

(define TRAIN-ABILITY-TABLE : (Immutable-HashTable Symbol Positive-Integer)
  (make-immutable-hasheq
   '((drone . 1342)
     (zergling . 1343)
     (overlord . 1344)
     (hydralisk . 1345)
     (mutalisk . 1346)
     (ultralisk . 1348)
     (roach . 1351)
     (infestor . 1352)
     (corruptor . 1353)
     (viper . 1354)
     (swarm-host . 1356)
     (swarmhost . 1356)
     (queen . 1632)
     (baneling . 80)
     (ravager . 2330)
     (lurker . 2332)
     (brood-lord . 1372)
     (broodlord . 1372)
     (overseer . 1448)
     (scv . 524)
     (marine . 560)
     (reaper . 561)
     (ghost . 562)
     (marauder . 563)
     (siege-tank . 591)
     (thor . 594)
     (hellion . 595)
     (hellbat . 596)
     (cyclone . 597)
     (widow-mine . 614)
     (medivac . 620)
     (banshee . 621)
     (raven . 622)
     (battlecruiser . 623)
     (viking . 624)
     (viking-fighter . 624)
     (liberator . 626)
     (probe . 1006)
     (zealot . 916)
     (stalker . 917)
     (high-templar . 919)
     (dark-templar . 920)
     (sentry . 921)
     (adept . 922)
     (warp-in-zealot . 1413)
     (warp-in-stalker . 1414)
     (warp-in-high-templar . 1416)
     (warp-in-dark-templar . 1417)
     (warp-in-sentry . 1418)
     (warp-in-adept . 1419)
     (warp-prism . 976)
     (observer . 977)
     (colossus . 978)
     (immortal . 979)
     (disruptor . 994)
     (phoenix . 946)
     (carrier . 948)
     (void-ray . 950)
     (voidray . 950)
     (oracle . 954)
     (tempest . 955)
     (mothership . 110))))

(define MORPH-ABILITY-TABLE : (Immutable-HashTable Symbol Positive-Integer)
  (make-immutable-hasheq
   '((baneling . 80)
     (ravager . 2330)
     (lurker . 2332)
     (lurker-mp . 2332)
     (brood-lord . 1372)
     (broodlord . 1372)
     (overseer . 1448)
     (overlord-transport . 2708)
     (dropperlord . 2708)
     (lair . 1216)
     (hive . 1218)
     (greater-spire . 1220)
     (lurker-den . 1163)
     (lurker-den-mp . 1163)
     (orbital-command . 1516)
     (planetary-fortress . 1450)
     (siege-mode . 388)
     (unsiege . 390)
     (unsiege-mode . 390)
     (hellbat . 1998)
     (hellion . 1978)
     (viking-assault . 403)
     (viking-fighter . 405)
     (liberator-aa . 2560)
     (thor-high-impact . 2362)
     (thor-explosive . 2364)
     (supply-depot-lower . 556)
     (supply-depot-raise . 558)
     (warp-gate . 1518)
     (warpgate . 1518)
     (gateway . 1520)
     (warp-prism-phasing . 1528)
     (warp-prism-transport . 1530)
     (observer-mode . 3739)
     (observer-siege-mode . 3741)
     (overseer-mode . 3743)
     (oversight-mode . 3745)
     (spine-crawler-uproot . 1725)
     (spore-crawler-uproot . 1727)
     (uproot . 3681))))

(define RESEARCH-ABILITY-TABLE : (Immutable-HashTable Symbol Positive-Integer)
  (make-immutable-hasheq
   '((zergling-movementspeed . 1253)
     (metabolic-boost . 1253)
     (zergling-attackspeed . 1252)
     (adrenal-glands . 1252)
     (glial-reconstitution . 216)
     (tunneling-claws . 217)
     (centrifugal-hooks . 1482)
     (centrifical-hooks . 1482)
     (grooved-spines . 1282)
     (muscular-augments . 1283)
     (adaptive-talons . 3709)
     (lurker-range . 3710)
     (seismic-spines . 3710)
     (chitinous-plating . 265)
     (anabolic-synthesis . 263)
     (burrow . 1225)
     (pneumatized-carapace . 1223)
     (overlord-speed . 1223)
     (overlordspeed . 1223)
     (neural-parasite . 1455)
     (zerg-melee-weapons-1 . 1186)
     (melee-attacks-1 . 1186)
     (zerg-melee-weapons-2 . 1187)
     (melee-attacks-2 . 1187)
     (zerg-melee-weapons-3 . 1188)
     (melee-attacks-3 . 1188)
     (zerg-missile-weapons-1 . 1192)
     (missile-attacks-1 . 1192)
     (zerg-missile-weapons-2 . 1193)
     (missile-attacks-2 . 1193)
     (zerg-missile-weapons-3 . 1194)
     (missile-attacks-3 . 1194)
     (zerg-ground-armor-1 . 1189)
     (ground-carapace-1 . 1189)
     (zerg-ground-carapace-1 . 1189)
     (zerg-ground-armor-2 . 1190)
     (ground-carapace-2 . 1190)
     (zerg-ground-carapace-2 . 1190)
     (zerg-ground-armor-3 . 1191)
     (ground-carapace-3 . 1191)
     (zerg-ground-carapace-3 . 1191)
     (zerg-flyer-weapons-1 . 1312)
     (flyer-attacks-1 . 1312)
     (zerg-flyer-weapons-2 . 1313)
     (flyer-attacks-2 . 1313)
     (zerg-flyer-weapons-3 . 1314)
     (flyer-attacks-3 . 1314)
     (zerg-flyer-armor-1 . 1315)
     (flyer-carapace-1 . 1315)
     (zerg-flyer-armor-2 . 1316)
     (flyer-carapace-2 . 1316)
     (zerg-flyer-armor-3 . 1317)
     (flyer-carapace-3 . 1317)
     (stimpack . 730)
     (combat-shield . 731)
     (combat-shields . 731)
     (concussive-shells . 732)
     (infernal-preigniter . 761)
     (infernal-pre-igniter . 761)
     (drilling-claws . 764)
     (lock-on-range . 765)
     (smart-servos . 766)
     (cyclone-lock-on-damage . 769)
     (mag-field-accelerator . 769)
     (banshee-cloak . 790)
     (cloaking-field . 790)
     (hyperflight-rotors . 799)
     (advanced-ballistics . 805)
     (personal-cloaking . 820)
     (weapon-refit . 1532)
     (terran-infantry-weapons-1 . 652)
     (infantry-weapons-1 . 652)
     (terran-infantry-weapons-2 . 653)
     (infantry-weapons-2 . 653)
     (terran-infantry-weapons-3 . 654)
     (infantry-weapons-3 . 654)
     (terran-infantry-armor-1 . 656)
     (infantry-armor-1 . 656)
     (terran-infantry-armor-2 . 657)
     (infantry-armor-2 . 657)
     (terran-infantry-armor-3 . 658)
     (infantry-armor-3 . 658)
     (terran-vehicle-weapons-1 . 855)
     (vehicle-weapons-1 . 855)
     (terran-vehicle-weapons-2 . 856)
     (vehicle-weapons-2 . 856)
     (terran-vehicle-weapons-3 . 857)
     (vehicle-weapons-3 . 857)
     (terran-vehicle-plating-1 . 864)
     (terran-vehicle-and-ship-plating-1 . 864)
     (vehicle-and-ship-plating-1 . 864)
     (terran-vehicle-plating-2 . 865)
     (terran-vehicle-and-ship-plating-2 . 865)
     (vehicle-and-ship-plating-2 . 865)
     (terran-vehicle-plating-3 . 866)
     (terran-vehicle-and-ship-plating-3 . 866)
     (vehicle-and-ship-plating-3 . 866)
     (terran-ship-weapons-1 . 861)
     (ship-weapons-1 . 861)
     (terran-ship-weapons-2 . 862)
     (ship-weapons-2 . 862)
     (terran-ship-weapons-3 . 863)
     (ship-weapons-3 . 863)
     (warpgate . 1568)
     (warp-gate . 1568)
     (warp-gate-research . 1568)
     (warpgate-research . 1568)
     (hallucination . 1571)
     (charge . 1592)
     (blink . 1593)
     (blink-tech . 1593)
     (resonating-glaives . 1594)
     (adept-piercing-attack . 1594)
     (psi-storm . 1126)
     (psistorm . 1126)
     (psi-storm-tech . 1126)
     (psistorm-tech . 1126)
     (shadow-strike . 2720)
     (shadow-stride . 2720)
     (extended-thermal-lance . 1097)
     (gravitic-booster . 1093)
     (gravitic-boosters . 1093)
     (gravitic-drive . 1094)
     (anion-pulse-crystals . 44)
     (flux-vanes . 48)
     (protoss-ground-weapons-1 . 1062)
     (ground-weapons-1 . 1062)
     (protoss-ground-weapons-2 . 1063)
     (ground-weapons-2 . 1063)
     (protoss-ground-weapons-3 . 1064)
     (ground-weapons-3 . 1064)
     (protoss-ground-armor-1 . 1065)
     (ground-armor-1 . 1065)
     (protoss-ground-armor-2 . 1066)
     (ground-armor-2 . 1066)
     (protoss-ground-armor-3 . 1067)
     (ground-armor-3 . 1067)
     (protoss-shields-1 . 1068)
     (shields-1 . 1068)
     (protoss-shields-2 . 1069)
     (shields-2 . 1069)
     (protoss-shields-3 . 1070)
     (shields-3 . 1070)
     (protoss-air-weapons-1 . 1562)
     (air-weapons-1 . 1562)
     (protoss-air-weapons-2 . 1563)
     (air-weapons-2 . 1563)
     (protoss-air-weapons-3 . 1564)
     (air-weapons-3 . 1564)
     (protoss-air-armor-1 . 1565)
     (air-armor-1 . 1565)
     (protoss-air-armor-2 . 1566)
     (air-armor-2 . 1566)
     (protoss-air-armor-3 . 1567)
     (air-armor-3 . 1567))))

(: lookup-research-id (-> Symbol (Option Positive-Integer)))
(define (lookup-research-id sym)
  (define direct (hash-ref RESEARCH-ABILITY-TABLE sym #f))
  (cond
    [direct direct]
    [else
     (define s (symbol->string sym))
     (if (and (> (string-length s) 9)
              (string=? (substring s 0 9) "research-"))
         (hash-ref RESEARCH-ABILITY-TABLE (string->symbol (substring s 9)) #f)
         #f)]))

;; Canonical Spell Resolution (`Self` vs `Point` vs `Unit`)
(struct CanonicalSpellSelf ([sym : Symbol] [ability : NoTargetAbility]) #:transparent)
(struct CanonicalSpellPoint ([sym : Symbol] [ability : PointTargetAbility]) #:transparent)
(struct CanonicalSpellUnit ([sym : Symbol] [ability : UnitTargetAbility]) #:transparent)
(define-type CanonicalSpell (U CanonicalSpellSelf CanonicalSpellPoint CanonicalSpellUnit))

(define SELF-SPELL-TABLE : (Immutable-HashTable Symbol (Pairof Symbol Positive-Integer))
  (make-immutable-hasheq
   '((stimpack . (stimpack . 3675))
     (stim . (stimpack . 3675))
     (stim-marine . (stim-marine . 380))
     (stim-marauder . (stim-marauder . 253))
     (guardian-shield . (guardian-shield . 76))
     (hallucination-phoenix . (hallucination-phoenix . 154))
     (hallucination-archon . (hallucination-archon . 146))
     (hallucination-colossus . (hallucination-colossus . 148))
     (hallucination-high-templar . (hallucination-high-templar . 150))
     (hallucination-immortal . (hallucination-immortal . 152))
     (hallucination-probe . (hallucination-probe . 156))
     (hallucination-stalker . (hallucination-stalker . 158))
     (hallucination-void-ray . (hallucination-void-ray . 160))
     (hallucination-warp-prism . (hallucination-warp-prism . 162))
     (hallucination-zealot . (hallucination-zealot . 164))
     (hallucination-oracle . (hallucination-oracle . 2114))
     (hallucination-disruptor . (hallucination-disruptor . 2389))
     (hallucination-adept . (hallucination-adept . 2391))
     (spawn-changeling . (spawn-changeling . 181))
     (burrow . (burrow-down . 3661))
     (burrow-down . (burrow-down . 3661))
     (unburrow . (burrow-up . 3662))
     (burrow-up . (burrow-up . 3662))
     (widow-mine-burrow . (burrow-widow-mine . 2095))
     (burrow-widow-mine . (burrow-widow-mine . 2095))
     (widow-mine-unburrow . (unburrow-widow-mine . 2097))
     (unburrow-widow-mine . (unburrow-widow-mine . 2097))
     (lurker-burrow . (burrow-lurker . 2108))
     (burrow-lurker . (burrow-lurker . 2108))
     (lurker-unburrow . (unburrow-lurker . 2110))
     (unburrow-lurker . (unburrow-lurker . 2110))
     (siege-mode . (siege-mode . 388))
     (morph-siege-mode . (siege-mode . 388))
     (unsiege . (unsiege-mode . 390))
     (unsiege-mode . (unsiege-mode . 390))
     (morph-unsiege . (unsiege-mode . 390))
     (cloak-banshee . (cloak-banshee . 392))
     (decloak-banshee . (decloak-banshee . 393))
     (cloak-ghost . (cloak-ghost . 382))
     (decloak-ghost . (decloak-ghost . 383))
     (medivac-boost . (medivac-boost . 2116))
     (ignite-afterburners . (medivac-boost . 2116))
     (morph-viking-assault . (morph-viking-assault . 403))
     (morph-viking-fighter . (morph-viking-fighter . 405))
     (morph-liberator-aa . (morph-liberator-aa . 2560))
     (morph-thor-high-impact . (morph-thor-high-impact . 2362))
     (morph-thor-explosive . (morph-thor-explosive . 2364))
     (morph-hellbat . (morph-hellbat . 1998))
     (morph-hellion . (morph-hellion . 1978))
     (morph-supply-depot-lower . (morph-supply-depot-lower . 556))
     (morph-supply-depot-raise . (morph-supply-depot-raise . 558))
     (immortal-barrier . (immortal-barrier . 2328))
     (prismatic-alignment . (prismatic-alignment . 2393))
     (pulsar-beam . (pulsar-beam . 2375))
     (pulsar-beam-on . (pulsar-beam . 2375))
     (pulsar-beam-off . (pulsar-beam-off . 2376))
     (build-interceptors . (build-interceptors . 1042))
     (salvage . (salvage . 32))
     (lift . (lift . 3679))
     (morph-warp-prism-phasing . (morph-warp-prism-phasing . 1528))
     (morph-warp-prism-transport . (morph-warp-prism-transport . 1530))
     (morph-observer-mode . (morph-observer-mode . 3739))
     (morph-observer-siege-mode . (morph-observer-siege-mode . 3741))
     (morph-overseer-mode . (morph-overseer-mode . 3743))
     (morph-oversight-mode . (morph-oversight-mode . 3745))
     (cancel-phase-shift . (cancel-adept-phase-shift . 2594))
     (cancel-adept-phase-shift . (cancel-adept-phase-shift . 2594)))))

(define POINT-SPELL-TABLE : (Immutable-HashTable Symbol (Pairof Symbol Positive-Integer))
  (make-immutable-hasheq
   '((emp-round . (emp-round . 1628))
     (emp . (emp-round . 1628))
     (psi-storm . (psi-storm . 1036))
     (psistorm . (psi-storm . 1036))
     (force-field . (force-field . 1526))
     (forcefield . (force-field . 1526))
     (blink . (blink . 3687))
     (blink-stalker . (blink-stalker . 1442))
     (shadow-stride . (shadow-stride . 2700))
     (adept-phase-shift . (adept-phase-shift . 2544))
     (psionic-transfer . (adept-phase-shift . 2544))
     (purification-nova . (purification-nova . 2346))
     (oracle-revelation . (oracle-revelation . 2146))
     (revelation . (oracle-revelation . 2146))
     (stasis-ward . (stasis-ward . 2505))
     (oracle-stasis-ward . (stasis-ward . 2505))
     (build-stasis-trap . (stasis-ward . 2505))
     (mass-recall . (mass-recall . 3757))
     (nexus-mass-recall . (mass-recall . 3757))
     (mothership-mass-recall . (mothership-mass-recall . 2368))
     (fungal-growth . (fungal-growth . 74))
     (microbial-shroud . (microbial-shroud . 2545))
     (corrosive-bile . (corrosive-bile . 2338))
     (blinding-cloud . (blinding-cloud . 2063))
     (spawn-locusts . (spawn-locusts . 1990))
     (spawn-creep-tumor . (spawn-creep-tumor . 1694))
     (spread-creep-tumor . (spread-creep-tumor . 1733))
     (build-creep-tumor . (build-creep-tumor . 3691))
     (build-nydus-worm . (build-nydus-worm . 1768))
     (scanner-sweep . (scanner-sweep . 399))
     (scan . (scanner-sweep . 399))
     (tactical-jump . (tactical-jump . 2358))
     (kd8-charge . (kd8-charge . 2588))
     (auto-turret . (auto-turret . 349))
     (build-auto-turret . (auto-turret . 349))
     (morph-liberator-ag . (morph-liberator-ag . 2558))
     (nuke-calldown . (nuke-calldown . 1622))
     (tac-nuke-strike . (nuke-calldown . 1622))
     (land . (land . 3678)))))

(define UNIT-SPELL-TABLE : (Immutable-HashTable Symbol (Pairof Symbol Positive-Integer))
  (make-immutable-hasheq
   '((inject-larva . (inject-larva . 251))
     (transfusion . (transfusion . 1664))
     (transfuse . (transfusion . 1664))
     (neural-parasite . (neural-parasite . 249))
     (abduct . (abduct . 2067))
     (parasitic-bomb . (parasitic-bomb . 2542))
     (viper-consume . (viper-consume . 2069))
     (consume . (viper-consume . 2069))
     (viper-consume-structure . (viper-consume-structure . 2073))
     (contaminate . (contaminate . 1825))
     (caustic-spray . (caustic-spray . 2324))
     (calldown-mule . (calldown-mule . 171))
     (mule-drop . (calldown-mule . 171))
     (supply-drop . (supply-drop . 255))
     (heal . (heal . 386))
     (repair . (repair . 3685))
     (steady-targeting . (steady-targeting . 2714))
     (snipe . (steady-targeting . 2714))
     (yamato-cannon . (yamato-cannon . 401))
     (yamato . (yamato-cannon . 401))
     (interference-matrix . (interference-matrix . 3747))
     (anti-armor-missile . (anti-armor-missile . 3753))
     (lock-on . (lock-on . 2350))
     (widow-mine-attack . (widow-mine-attack . 2099))
     (chrono-boost . (chrono-boost . 3755))
     (chronoboost . (chrono-boost . 3755))
     (battery-overcharge . (battery-overcharge . 4107))
     (feedback . (feedback . 140))
     (graviton-beam . (graviton-beam . 173))
     (charge . (charge . 1819)))))

(: resolve-canonical-spell (-> Any (Option CanonicalSpell)))
(define (resolve-canonical-spell raw-sp)
  (define sym : (Option Symbol)
    (cond
      ;; Legacy Ghost EMP integer `381` canonicalized to `'emp-round` -> `1628` (never raw `381`!)
      [(and (exact-integer? raw-sp) (= raw-sp 381)) 'emp-round]
      [else (extract-norm-symbol raw-sp)]))
  (cond
    [(not sym) #f]
    [(hash-ref SELF-SPELL-TABLE sym #f)
     => (lambda ([p : (Pairof Symbol Positive-Integer)])
          (define ab (lookup-no-target-ability (cdr p)))
          (if ab (CanonicalSpellSelf (car p) ab) #f))]
    [(hash-ref POINT-SPELL-TABLE sym #f)
     => (lambda ([p : (Pairof Symbol Positive-Integer)])
          (define ab (lookup-point-target-ability (cdr p)))
          (if ab (CanonicalSpellPoint (car p) ab) #f))]
    [(hash-ref UNIT-SPELL-TABLE sym #f)
     => (lambda ([p : (Pairof Symbol Positive-Integer)])
          (define ab (lookup-unit-target-ability (cdr p)))
          (if ab (CanonicalSpellUnit (car p) ab) #f))]
    [else #f]))

(define TELEMETRY-HEADS : (Immutable-HashTable Symbol Boolean)
  (make-immutable-hasheq
   '((control-group-set . #t)
     (control-group-append . #t)
     (control-group-steal . #t)
     (control-group-append-steal . #t)
     (control-group-recall . #t)
     (select-box . #t)
     (select-click . #t)
     (select-ctrl-type . #t)
     (deselect-ctrl-type . #t)
     (human-apm-discipline . #t)
     (posture-transition . #t)
     (mirror-prediction . #t)
     (mirror-macro-directive . #t)
     (mirror-tech-observation . #t)
     (mirror-zero-sum-exclusion . #t)
     (mirror-bo-tree-prediction . #t)
     (mirror-horizon-curve . #t)
     (evacuate-workers-from-stasis-ward . #t)
     (trigger-stasis-ward-single-unit . #t)
     (counter-enemy-worker-drill . #t)
     (stasis-worker-stoppage-compensation . #t)
     (return-workers-to-gather . #t)
     (emergency-detector-response . #t)
     (wall-off-natural . #t)
     (door-unit-hold . #t)
     (door-unit-open . #t)
     (chat . #t)
     (team-chat . #t)
     (log . #t)
     (noop . #t))))

(define MOVE-ORDER-HEADS : (Immutable-HashTable Symbol Boolean)
  (make-immutable-hasheq
   '((move . #t)
     (kite . #t)
     (retreat . #t)
     (worker-harass . #t)
     (multi-prong-drop . #t)
     (worker-scout . #t)
     (overlord-scout . #t)
     (periodic-scout . #t)
     (patrol-block-expansion . #t)
     (burrow-block . #t)
     (roach-tunnel-move . #t)
     (infestor-burrow-move . #t)
     (land-building . #t))))

;; -----------------------------------------------------------------------------
;; Total S-Expression Parser (`parse-bot-action-sexp`)
;; -----------------------------------------------------------------------------

(: parse-spell-rest
   (-> NonEmptyUnitTags CanonicalSpell (Listof Any) Any
       (U TypedBotAction BotActionReject)))
(define (parse-spell-rest actors csp rest raw)
  (cond
    [(CanonicalSpellSelf? csp)
     ;; Self-target buffs/modes accept 0 args or legacy trailing dummy target arg
     (BotCastSelf actors (CanonicalSpellSelf-sym csp) (CanonicalSpellSelf-ability csp))]
    [(CanonicalSpellPoint? csp)
     (cond
       [(not (= (length rest) 2))
        (BotActionReject 'point-spell-requires-xy raw)]
       [else
        (define pt (extract-world-point2d (car rest) (cadr rest)))
        (if pt
            (if (eq? (CanonicalSpellPoint-sym csp) 'build-nydus-worm)
                (BotBuildNydusWorm actors pt (CanonicalSpellPoint-ability csp))
                (BotCastPoint actors (CanonicalSpellPoint-sym csp) (CanonicalSpellPoint-ability csp) pt))
            (BotActionReject 'invalid-world-point raw))])]
    [(CanonicalSpellUnit? csp)
     (cond
       [(not (= (length rest) 1))
        (BotActionReject 'unit-spell-requires-unit-tag raw)]
       [else
        (define ut (extract-unit-tag (car rest)))
        (if ut
            (BotCastUnit actors (CanonicalSpellUnit-sym csp) (CanonicalSpellUnit-ability csp) ut)
            (BotActionReject 'invalid-target-unit-tag raw))])]))

(: parse-bot-action-sexp (-> Any (U TypedBotAction BotActionReject)))
(define (parse-bot-action-sexp raw)
  (cond
    [(or (not (pair? raw)) (not (list? raw)))
     (BotActionReject 'not-a-proper-list raw)]
    [(not (symbol? (car raw)))
     (BotActionReject 'head-not-symbol raw)]
    [else
     (define head : Symbol (car raw))
     (define args : (Listof Any) (cdr raw))
     (define nargs : Natural (length args))
     (cond
       ;; 1. Build (`build <sym>` or `build <sym> <x> <y>`)
       [(eq? head 'build)
        (cond
          [(not (or (= nargs 1) (= nargs 3)))
           (BotActionReject 'invalid-build-arity raw)]
          [else
           (define bsym (extract-norm-symbol (car args)))
           (define opt-pt : (Option WorldPoint2D)
             (if (= nargs 3)
                 (extract-world-point2d (cadr args) (caddr args))
                 #f))
           (cond
             [(not bsym)
              (BotActionReject 'invalid-build-symbol raw)]
             [(and (= nargs 3) (not opt-pt))
              (BotActionReject 'invalid-world-point raw)]
             [(eq? bsym 'nydus-worm)
              (define nw-ab (lookup-point-target-ability 1768))
              (if (and opt-pt nw-ab)
                  (BotBuildNydusWorm #f opt-pt nw-ab)
                  (BotActionReject 'nydus-worm-requires-xy raw))]
             [(hash-ref BUILD-GAS-TABLE bsym #f)
              => (lambda ([gid : Positive-Integer])
                   (define gab (lookup-unit-target-ability gid))
                   (if gab
                       (BotBuildGas bsym opt-pt gab)
                       (BotActionReject 'unknown-build-symbol raw)))]
             [(hash-ref BUILD-ADDON-TABLE bsym #f)
              => (lambda ([aid : Positive-Integer])
                   (define aab (lookup-no-target-ability aid))
                   (if aab
                       (BotBuildAddon bsym opt-pt aab)
                       (BotActionReject 'unknown-build-symbol raw)))]
             [(hash-ref BUILD-POINT-TABLE bsym #f)
              => (lambda ([pid : Positive-Integer])
                   (define pab (lookup-point-target-ability pid))
                   (if pab
                       (BotBuildStructure bsym opt-pt pab)
                       (BotActionReject 'unknown-build-symbol raw)))]
             [(memq bsym '(lair hive greater-spire orbital-command planetary-fortress))
              (define mid (hash-ref MORPH-ABILITY-TABLE bsym #f))
              (define mab (and mid (lookup-no-target-ability mid)))
              (if mab
                  (BotMorph #f bsym mab #f)
                  (BotActionReject 'unknown-build-symbol raw))]
             [else
              (BotActionReject 'unknown-build-symbol raw)])])]

       ;; 1b. Explicit Nydus Worm (`build-nydus-worm <x> <y>` or `build-nydus-worm <net-id> <x> <y>`)
       [(eq? head 'build-nydus-worm)
        (define nw-ab (lookup-point-target-ability 1768))
        (cond
          [(not nw-ab) (BotActionReject 'internal-ability-missing raw)]
          [(= nargs 2)
           (define pt (extract-world-point2d (car args) (cadr args)))
           (if pt
               (BotBuildNydusWorm #f pt nw-ab)
               (BotActionReject 'invalid-world-point raw))]
          [(= nargs 3)
           (define actors (extract-actor-tags (car args)))
           (define pt (extract-world-point2d (cadr args) (caddr args)))
           (cond
             [(not actors) (BotActionReject 'invalid-actor-tags raw)]
             [(not pt) (BotActionReject 'invalid-world-point raw)]
             [else (BotBuildNydusWorm actors pt nw-ab)])]
          [else (BotActionReject 'invalid-nydus-arity raw)])]

       ;; 2. Expand (`expand <x> <y>` or `expand <th-sym> <x> <y>`)
       [(eq? head 'expand)
        (cond
          [(= nargs 2)
           (define pt (extract-world-point2d (car args) (cadr args)))
           (if pt
               (BotExpand #f pt)
               (BotActionReject 'invalid-world-point raw))]
          [(= nargs 3)
           (define th (extract-norm-symbol (car args)))
           (define pt (extract-world-point2d (cadr args) (caddr args)))
           (cond
             [(not (and th (memq th '(hatchery nexus command-center))))
              (BotActionReject 'invalid-townhall-symbol raw)]
             [(not pt) (BotActionReject 'invalid-world-point raw)]
             [else (BotExpand th pt)])]
          [else (BotActionReject 'invalid-expand-arity raw)])]

       ;; 3. Train (`train <unit-sym>` or `train-unit <prod-id> <unit-sym>`)
       [(or (eq? head 'train) (eq? head 'train-unit))
        (cond
          [(and (eq? head 'train) (= nargs 1))
           (define usym (extract-norm-symbol (car args)))
           (define tid (and usym (hash-ref TRAIN-ABILITY-TABLE usym #f)))
           (define tab : (Option (U NoTargetAbility PointTargetAbility))
             (and tid (or (lookup-no-target-ability tid)
                          (lookup-point-target-ability tid))))
           (if (and usym tab)
               (BotTrain #f usym tab)
               (BotActionReject 'unknown-train-unit raw))]
          [(= nargs 2)
           (define pid (extract-unit-tag (car args)))
           (define usym (extract-norm-symbol (cadr args)))
           (define tid (and usym (hash-ref TRAIN-ABILITY-TABLE usym #f)))
           (define tab : (Option (U NoTargetAbility PointTargetAbility))
             (and tid (or (lookup-no-target-ability tid)
                          (lookup-point-target-ability tid))))
           (cond
             [(not pid) (BotActionReject 'invalid-producer-tag raw)]
             [(not (and usym tab)) (BotActionReject 'unknown-train-unit raw)]
             [else (BotTrain pid usym tab)])]
          [else (BotActionReject 'invalid-train-arity raw)])]

       ;; 4. Research (`research <upg-sym>`)
       [(eq? head 'research)
        (cond
          [(not (= nargs 1)) (BotActionReject 'invalid-research-arity raw)]
          [else
           (define upg (extract-norm-symbol (car args)))
           (define rid (and upg (lookup-research-id upg)))
           (define rab (and rid (lookup-no-target-ability rid)))
           (if (and upg rab)
               (BotResearch upg rab)
               (BotActionReject 'unknown-upgrade-symbol raw))])]

       ;; 5. Morph (`morph <target-sym>` or `morph <actors> <target-sym>`)
       [(eq? head 'morph)
        (cond
          [(= nargs 1)
           (define msym (extract-norm-symbol (car args)))
           (cond
             [(not msym) (BotActionReject 'invalid-morph-symbol raw)]
             [(eq? msym 'archon)
              ;; High-level `(morph 'archon)` picks 2 idle Templars in actuator; wire-level uses `WireCmdArchon`
              (define dummy-ab (assert (lookup-no-target-ability 3665) NoTargetAbility?))
              (BotMorph #f 'archon dummy-ab #t)]
             [else
              (define mid (hash-ref MORPH-ABILITY-TABLE msym #f))
              (define mab : (Option (U NoTargetAbility PointTargetAbility))
                (and mid (or (lookup-no-target-ability mid)
                             (lookup-point-target-ability mid))))
              (if mab
                  (BotMorph #f msym mab #f)
                  (BotActionReject 'unknown-morph-symbol raw))])]
          [(= nargs 2)
           (define actors (extract-actor-tags (car args)))
           (define msym (extract-norm-symbol (cadr args)))
           (cond
             [(not actors) (BotActionReject 'invalid-actor-tags raw)]
             [(not msym) (BotActionReject 'invalid-morph-symbol raw)]
             [(eq? msym 'archon)
              (define tail (NonEmptyUnitTags-tail actors))
              (if (and (pair? tail) (null? (cdr tail)))
                  (let ([dummy-ab (assert (lookup-no-target-ability 3665) NoTargetAbility?)])
                    (BotMorph actors 'archon dummy-ab #t))
                  (BotActionReject 'archon-requires-two-distinct-templars raw))]
             [else
              (define mid (hash-ref MORPH-ABILITY-TABLE msym #f))
              (define mab : (Option (U NoTargetAbility PointTargetAbility))
                (and mid (or (lookup-no-target-ability mid)
                             (lookup-point-target-ability mid))))
              (if mab
                  (BotMorph actors msym mab #f)
                  (BotActionReject 'unknown-morph-symbol raw))])]
          [else (BotActionReject 'invalid-morph-arity raw)])]

       ;; 6. Spells (`cast`, `cast-spell`, `inject-larva`, `blind-skillshot-shimmer`, `infestor-burrow-cast`)
       [(or (eq? head 'cast) (eq? head 'cast-spell))
        (cond
          [(< nargs 2) (BotActionReject 'invalid-cast-arity raw)]
          [else
           (define actors (extract-actor-tags (car args)))
           (define csp (resolve-canonical-spell (cadr args)))
           (cond
             [(not actors) (BotActionReject 'invalid-actor-tags raw)]
             [(not csp) (BotActionReject 'unknown-spell-symbol raw)]
             [else (parse-spell-rest actors csp (cddr args) raw)])])]

       [(eq? head 'inject-larva)
        (cond
          [(not (= nargs 2)) (BotActionReject 'invalid-inject-arity raw)]
          [else
           (define actors (extract-actor-tags (car args)))
           (define htag (extract-unit-tag (cadr args)))
           (define iab (lookup-unit-target-ability 251))
           (cond
             [(not actors) (BotActionReject 'invalid-actor-tags raw)]
             [(not htag) (BotActionReject 'invalid-target-unit-tag raw)]
             [(not iab) (BotActionReject 'internal-ability-missing raw)]
             [else (BotCastUnit actors 'inject-larva iab htag)])])]

       [(eq? head 'blind-skillshot-shimmer)
        (cond
          [(not (= nargs 4)) (BotActionReject 'invalid-skillshot-arity raw)]
          [else
           (define actors (extract-actor-tags (car args)))
           (define csp (resolve-canonical-spell (cadr args)))
           (cond
             [(not actors) (BotActionReject 'invalid-actor-tags raw)]
             [(not (CanonicalSpellPoint? csp))
              (BotActionReject 'skillshot-requires-point-spell raw)]
             [else (parse-spell-rest actors csp (cddr args) raw)])])]

       [(eq? head 'infestor-burrow-cast)
        (cond
          [(< nargs 3) (BotActionReject 'invalid-cast-arity raw)]
          [else
           (define actors (extract-actor-tags (car args)))
           (define csp (resolve-canonical-spell (cadr args)))
           (cond
             [(not actors) (BotActionReject 'invalid-actor-tags raw)]
             [(not csp) (BotActionReject 'unknown-spell-symbol raw)]
             [else (parse-spell-rest actors csp (cddr args) raw)])])]

       ;; 7. Attack Unit (`attack`, `attack-unit`, `focus-fire`) & 3-arg `attack <actors> <x> <y>`
       [(or (eq? head 'attack) (eq? head 'attack-unit))
        (cond
          [(= nargs 2)
           (define actors (extract-actor-tags (car args)))
           (define tgt (extract-unit-tag (cadr args)))
           (cond
             [(not actors) (BotActionReject 'invalid-actor-tags raw)]
             [(not tgt) (BotActionReject 'invalid-target-unit-tag raw)]
             [else (BotAttackUnit head actors tgt #f)])]
          [(and (eq? head 'attack) (= nargs 3))
           (define actors (extract-actor-tags (car args)))
           (define pt (extract-world-point2d (cadr args) (caddr args)))
           (cond
             [(not actors) (BotActionReject 'invalid-actor-tags raw)]
             [(not pt) (BotActionReject 'invalid-world-point raw)]
             [else (BotAttackPos 'attack-pos actors pt)])]
          [else (BotActionReject 'invalid-attack-arity raw)])]

       [(eq? head 'focus-fire)
        (cond
          [(= nargs 2)
           (define actors (extract-actor-tags (car args)))
           (define tgt (extract-unit-tag (cadr args)))
           (cond
             [(not actors) (BotActionReject 'invalid-actor-tags raw)]
             [(not tgt) (BotActionReject 'invalid-target-unit-tag raw)]
             [else (BotAttackUnit 'focus-fire actors tgt #f)])]
          [(= nargs 4)
           (define actors (extract-actor-tags (car args)))
           (define tgt (extract-unit-tag (cadr args)))
           (define fb (extract-world-point2d (caddr args) (cadddr args)))
           (cond
             [(not actors) (BotActionReject 'invalid-actor-tags raw)]
             [(not tgt) (BotActionReject 'invalid-target-unit-tag raw)]
             [(not fb) (BotActionReject 'invalid-world-point raw)]
             [else (BotAttackUnit 'focus-fire actors tgt fb)])]
          [else (BotActionReject 'invalid-focus-fire-arity raw)])]

       ;; 8. Attack Position (`attack-pos`, `harass-workers`)
       [(or (eq? head 'attack-pos) (eq? head 'harass-workers))
        (cond
          [(not (= nargs 3)) (BotActionReject 'invalid-attack-pos-arity raw)]
          [else
           (define actors (extract-actor-tags (car args)))
           (define pt (extract-world-point2d (cadr args) (caddr args)))
           (cond
             [(not actors) (BotActionReject 'invalid-actor-tags raw)]
             [(not pt) (BotActionReject 'invalid-world-point raw)]
             [else (BotAttackPos head actors pt)])])]

       ;; 9. Movement / Scouting / Walling / Land Orders
       [(hash-ref MOVE-ORDER-HEADS head #f)
        (cond
          [(not (= nargs 3)) (BotActionReject 'invalid-move-arity raw)]
          [else
           (define actors (extract-actor-tags (car args)))
           (define pt (extract-world-point2d (cadr args) (caddr args)))
           (cond
             [(not actors) (BotActionReject 'invalid-actor-tags raw)]
             [(not pt) (BotActionReject 'invalid-world-point raw)]
             [else (BotMoveOrder head actors pt)])])]

       ;; 10. Hold Position & Cancel Building & Burrow Mode Switch
       [(eq? head 'hold-position)
        (cond
          [(= nargs 1)
           (define actors (extract-actor-tags (car args)))
           (if actors
               (BotHoldPosition actors #f)
               (BotActionReject 'invalid-actor-tags raw))]
          [(= nargs 3)
           (define actors (extract-actor-tags (car args)))
           (define pt (extract-world-point2d (cadr args) (caddr args)))
           (cond
             [(not actors) (BotActionReject 'invalid-actor-tags raw)]
             [(not pt) (BotActionReject 'invalid-world-point raw)]
             [else (BotHoldPosition actors pt)])]
          [else (BotActionReject 'invalid-hold-arity raw)])]

       [(or (eq? head 'cancel) (eq? head 'cancel-building))
        (cond
          [(not (= nargs 1)) (BotActionReject 'invalid-cancel-arity raw)]
          [else
           (define uid (extract-unit-tag (car args)))
           (if uid
               (BotCancelBuilding uid)
               (BotActionReject 'invalid-actor-tags raw))])]

       [(or (eq? head 'burrow-down) (eq? head 'burrow-up))
        (cond
          [(< nargs 1) (BotActionReject 'invalid-burrow-arity raw)]
          [else
           (define actors (extract-actor-tags (car args)))
           (define ab-id : Positive-Integer (if (eq? head 'burrow-down) 3661 3662))
           (define ab (lookup-no-target-ability ab-id))
           (if (and actors ab)
               (BotModeSwitch head actors ab)
               (BotActionReject 'invalid-actor-tags raw))])]

       ;; 11. Harvest & Resume Building (`harvest`, `harvest-mineral`, `harvest-gas`, `rebalance-gas-to-minerals`, `resume-halted-building`)
       [(or (eq? head 'harvest)
            (eq? head 'harvest-mineral)
            (eq? head 'harvest-gas)
            (eq? head 'rebalance-gas-to-minerals)
            (eq? head 'resume-halted-building))
        (cond
          [(not (= nargs 2)) (BotActionReject 'invalid-harvest-arity raw)]
          [else
           (define workers (extract-actor-tags (car args)))
           (define tid (extract-unit-tag (cadr args)))
           (cond
             [(not workers) (BotActionReject 'invalid-actor-tags raw)]
             [(not tid) (BotActionReject 'invalid-target-unit-tag raw)]
             [else (BotHarvest head workers tid)])])]

       ;; 12. Worker Micro Mechanics (`mineral-walk`, `pull-workers-attack`, `worker-drill-stack-attack`, `mineral-harass`)
       [(eq? head 'mineral-walk)
        (cond
          [(= nargs 3)
           (define workers (extract-actor-tags (car args)))
           (define pt (extract-world-point2d (cadr args) (caddr args)))
           (cond
             [(not workers) (BotActionReject 'invalid-actor-tags raw)]
             [(not pt) (BotActionReject 'invalid-world-point raw)]
             [else (BotWorkerMechanic 'mineral-walk workers #f #f pt #f)])]
          [(= nargs 4)
           (define workers (extract-actor-tags (car args)))
           (define-values (patch-ok? patch-id) (extract-optional-unit-tag (cadr args)))
           (define pt (extract-world-point2d (caddr args) (cadddr args)))
           (cond
             [(not workers) (BotActionReject 'invalid-actor-tags raw)]
             [(not patch-ok?) (BotActionReject 'invalid-target-unit-tag raw)]
             [(not pt) (BotActionReject 'invalid-world-point raw)]
             [else (BotWorkerMechanic 'mineral-walk workers patch-id #f pt #f)])]
          [else (BotActionReject 'invalid-mineral-walk-arity raw)])]

       [(eq? head 'pull-workers-attack)
        (cond
          [(= nargs 3)
           (define workers (extract-actor-tags (car args)))
           (define pt (extract-world-point2d (cadr args) (caddr args)))
           (cond
             [(not workers) (BotActionReject 'invalid-actor-tags raw)]
             [(not pt) (BotActionReject 'invalid-world-point raw)]
             [else (BotWorkerMechanic 'pull-workers-attack workers #f #f pt #f)])]
          [(= nargs 4)
           (define workers (extract-actor-tags (car args)))
           (define-values (tgt-ok? tgt-id) (extract-optional-unit-tag (cadr args)))
           (define pt (extract-world-point2d (caddr args) (cadddr args)))
           (cond
             [(not workers) (BotActionReject 'invalid-actor-tags raw)]
             [(not tgt-ok?) (BotActionReject 'invalid-target-unit-tag raw)]
             [(not pt) (BotActionReject 'invalid-world-point raw)]
             [else (BotWorkerMechanic 'pull-workers-attack workers #f tgt-id pt #f)])]
          [else (BotActionReject 'invalid-pull-workers-arity raw)])]

       [(eq? head 'worker-drill-stack-attack)
        (cond
          [(not (= nargs 5)) (BotActionReject 'invalid-worker-drill-arity raw)]
          [else
           (define workers (extract-actor-tags (car args)))
           (define-values (patch-ok? patch-id) (extract-optional-unit-tag (cadr args)))
           (define-values (tgt-ok? tgt-id) (extract-optional-unit-tag (caddr args)))
           (define pt (extract-world-point2d (cadddr args) (car (cddddr args))))
           (cond
             [(not workers) (BotActionReject 'invalid-actor-tags raw)]
             [(or (not patch-ok?) (not tgt-ok?)) (BotActionReject 'invalid-target-unit-tag raw)]
             [(not pt) (BotActionReject 'invalid-world-point raw)]
             [else (BotWorkerMechanic 'worker-drill-stack-attack workers patch-id tgt-id pt #f)])])]

       [(eq? head 'mineral-harass)
        (cond
          [(not (= nargs 5)) (BotActionReject 'invalid-mineral-harass-arity raw)]
          [else
           (define workers (extract-actor-tags (car args)))
           (define pt1 (extract-world-point2d (cadr args) (caddr args)))
           (define pt2 (extract-world-point2d (cadddr args) (car (cddddr args))))
           (cond
             [(not workers) (BotActionReject 'invalid-actor-tags raw)]
             [(or (not pt1) (not pt2)) (BotActionReject 'invalid-world-point raw)]
             [else (BotWorkerMechanic 'mineral-harass workers #f #f pt1 pt2)])])]

       ;; 13. Transport Juggle / Load / Unload
       [(eq? head 'transport-juggle)
        (cond
          [(= nargs 4)
           (define tr-id (extract-unit-tag (car args)))
           (define pass (extract-actor-tags (cadr args)))
           (define pt (extract-world-point2d (caddr args) (cadddr args)))
           (cond
             [(not tr-id) (BotActionReject 'invalid-transport-tag raw)]
             [(not pass) (BotActionReject 'invalid-actor-tags raw)]
             [(not pt) (BotActionReject 'invalid-world-point raw)]
             [else (BotTransportAction 'transport-juggle tr-id pass pt)])]
          [(= nargs 3)
           (define tr-id (extract-unit-tag (car args)))
           (define pt (extract-world-point2d (cadr args) (caddr args)))
           (cond
             [(not tr-id) (BotActionReject 'invalid-transport-tag raw)]
             [(not pt) (BotActionReject 'invalid-world-point raw)]
             [else (BotTransportAction 'transport-juggle tr-id #f pt)])]
          [else (BotActionReject 'invalid-transport-arity raw)])]

       ;; 14. Terran Addon Swap (`terran-addon-swap` & legacy `swap-addon`)
       [(eq? head 'terran-addon-swap)
        (cond
          [(not (= nargs 4)) (BotActionReject 'invalid-addon-swap-arity raw)]
          [else
           (define-values (lift-ok? lift-opt) (extract-optional-unit-tag (car args)))
           (define land-id (extract-unit-tag (cadr args)))
           (define pt (extract-world-point2d (caddr args) (cadddr args)))
           (define lift-nat : Natural (if lift-opt lift-opt 0))
           (cond
             [(not lift-ok?) (BotActionReject 'invalid-actor-tags raw)]
             [(not land-id) (BotActionReject 'invalid-actor-tags raw)]
             [(= lift-nat land-id) (BotActionReject 'duplicate-swap-facility raw)]
             [(not pt) (BotActionReject 'invalid-world-point raw)]
             [else (BotTerranAddonSwap lift-nat land-id pt)])])]

       [(eq? head 'swap-addon)
        (cond
          [(not (= nargs 2)) (BotActionReject 'invalid-addon-swap-arity raw)]
          [else
           (define lift-id (extract-unit-tag (car args)))
           (define land-id (extract-unit-tag (cadr args)))
           (cond
             [(or (not lift-id) (not land-id)) (BotActionReject 'invalid-actor-tags raw)]
             [(= lift-id land-id) (BotActionReject 'duplicate-swap-facility raw)]
             [else (BotTerranAddonSwap lift-id land-id #f)])])]

       ;; 15. Tactical Army Maneuvers & Sweeps
       [(eq? head 'scout-sector)
        (cond
          [(= nargs 2)
           (define pt (extract-world-point2d (car args) (cadr args)))
           (if pt
               (BotTacticalManeuver 'scout-sector pt args)
               (BotActionReject 'invalid-world-point raw))]
          [(= nargs 3)
           (define s (car args))
           (define pt (extract-world-point2d (cadr args) (caddr args)))
           (if (and pt (or (exact-nonnegative-integer? s) (symbol? s)))
               (BotTacticalManeuver 'scout-sector pt args)
               (BotActionReject 'invalid-world-point raw))]
          [else (BotActionReject 'invalid-scout-sector-arity raw)])]

       [(or (eq? head 'execute-spatial-maneuver) (eq? head 'mirror-spatial-maneuver))
        (cond
          [(= nargs 3)
           (define msym (extract-norm-symbol (car args)))
           (define pt (extract-world-point2d (cadr args) (caddr args)))
           (cond
             [(not msym) (BotActionReject 'invalid-maneuver-symbol raw)]
             [(not pt) (BotActionReject 'invalid-world-point raw)]
             [else (BotTacticalManeuver head pt (list msym))])]
          [(and (eq? head 'mirror-spatial-maneuver)
                (= nargs 4)
                (extract-norm-symbol (car args))
                (real? (cadr args))
                (real? (caddr args))
                (real? (cadddr args)))
           (BotTelemetryDirective 'mirror-spatial-maneuver args)]
          [(= nargs 4)
           (define p1 (extract-world-point2d (car args) (cadr args)))
           (define p2 (extract-world-point2d (caddr args) (cadddr args)))
           (if (and p1 p2)
               (BotTacticalManeuver head p1 (list 'multiprong-rotate-and-pin))
               (BotActionReject 'invalid-world-point raw))]
          [else (BotActionReject 'invalid-maneuver-arity raw)])]

       [(eq? head 'pre-split-wings)
        (cond
          [(not (= nargs 6)) (BotActionReject 'invalid-pre-split-arity raw)]
          [else
           (define p1 (extract-world-point2d (car args) (cadr args)))
           (define p2 (extract-world-point2d (caddr args) (cadddr args)))
           (define rest4 (cddddr args))
           (define p3 (extract-world-point2d (car rest4) (cadr rest4)))
           (if (and p1 p2 p3)
               (BotTacticalManeuver 'pre-split-wings p2 (list p1 p2 p3))
               (BotActionReject 'invalid-world-point raw))])]

       [(eq? head 'form-concave-arc)
        (cond
          [(< nargs 3) (BotActionReject 'invalid-concave-arity raw)]
          [else
           (define pt (extract-world-point2d (car args) (cadr args)))
           (define r (caddr args))
           (if (and pt (real? r) (not (nan? (real->double-flonum r))) (not (infinite? (real->double-flonum r))) (> r 0))
               (BotTacticalManeuver 'form-concave-arc pt (cddr args))
               (BotActionReject 'invalid-world-point raw))])]

       [(eq? head 'position-in-buff-aura-with-splash-spread)
        (cond
          [(not (= nargs 6)) (BotActionReject 'invalid-aura-spread-arity raw)]
          [else
           (define pt (extract-world-point2d (cadr args) (caddr args)))
           (define r (cadddr args))
           (define sep (car (cddddr args)))
           (if (and pt
                    (real? r) (not (nan? (real->double-flonum r))) (not (infinite? (real->double-flonum r)))
                    (real? sep) (not (nan? (real->double-flonum sep))) (not (infinite? (real->double-flonum sep))))
               (BotTacticalManeuver 'position-in-buff-aura-with-splash-spread pt args)
               (BotActionReject 'invalid-world-point raw))])]

       [(eq? head 'cast-protective-buff-aura)
        (cond
          [(not (= nargs 4)) (BotActionReject 'invalid-buff-aura-arity raw)]
          [else
           (define asym (extract-norm-symbol (car args)))
           (define pt (extract-world-point2d (cadr args) (caddr args)))
           (define r (cadddr args))
           (if (and asym pt (real? r) (not (nan? (real->double-flonum r))) (not (infinite? (real->double-flonum r))))
               (BotTacticalManeuver 'cast-protective-buff-aura pt args)
               (BotActionReject 'invalid-world-point raw))])]

       [(eq? head 'high-ground-tactics)
        (cond
          [(not (= nargs 4)) (BotActionReject 'invalid-high-ground-arity raw)]
          [else
           (define msym (extract-norm-symbol (car args)))
           (define pt (extract-world-point2d (cadr args) (caddr args)))
           (if (and msym pt (boolean? (cadddr args)))
               (BotTacticalManeuver 'high-ground-tactics pt args)
               (BotActionReject 'invalid-world-point raw))])]

       [(eq? head 'cast-deception-and-scout-spells)
        (BotTacticalManeuver 'cast-deception-and-scout-spells #f args)]

       [(eq? head 'clear-gas-steal)
        (cond
          [(not (= nargs 3)) (BotActionReject 'invalid-clear-gas-arity raw)]
          [else
           (define-values (ok? gid) (extract-optional-unit-tag (car args)))
           (define pt (extract-world-point2d (cadr args) (caddr args)))
           (if (and ok? pt)
               (BotTacticalManeuver 'clear-gas-steal pt (list (or gid 0)))
               (BotActionReject 'invalid-clear-gas-args raw))])]

       [(eq? head 'clear-expansion-block)
        (cond
          [(= nargs 2)
           (define pt (extract-world-point2d (car args) (cadr args)))
           (if pt
               (BotTacticalManeuver 'clear-expansion-block pt '())
               (BotActionReject 'invalid-world-point raw))]
          [(= nargs 3)
           (define-values (ok? eid) (extract-optional-unit-tag (car args)))
           (define pt (extract-world-point2d (cadr args) (caddr args)))
           (if (and ok? pt)
               (BotTacticalManeuver 'clear-expansion-block pt (list (or eid 0)))
               (BotActionReject 'invalid-world-point raw))]
          [else (BotActionReject 'invalid-clear-expansion-arity raw)])]

       [(eq? head 'snipe-enemy-changeling)
        (cond
          [(= nargs 1)
           (define cid (extract-unit-tag (car args)))
           (if cid
               (BotTacticalManeuver 'snipe-enemy-changeling #f (list cid))
               (BotActionReject 'invalid-target-unit-tag raw))]
          [(= nargs 3)
           (define-values (ok? cid) (extract-optional-unit-tag (car args)))
           (define pt (extract-world-point2d (cadr args) (caddr args)))
           (if (and ok? pt)
               (BotTacticalManeuver 'snipe-enemy-changeling pt (list (or cid 0)))
               (BotActionReject 'invalid-world-point raw))]
          [else (BotActionReject 'invalid-snipe-changeling-arity raw)])]

       ;; 16. Camera Actions (`move-camera`, `camera-focus`, `camera-bookmark-jump`, `camera-bookmark-save`)
       [(or (eq? head 'move-camera) (eq? head 'camera-focus))
        (cond
          [(= nargs 2)
           (define pt (extract-world-point2d (car args) (cadr args)))
           (if pt
               (BotCameraAction head #f pt)
               (BotActionReject 'invalid-world-point raw))]
          [(and (eq? head 'camera-focus) (= nargs 3))
           (define pt (extract-world-point2d (cadr args) (caddr args)))
           (if pt
               (BotCameraAction 'camera-focus #f pt)
               (BotActionReject 'invalid-world-point raw))]
          [else (BotActionReject 'invalid-camera-arity raw)])]

       [(or (eq? head 'camera-bookmark-jump) (eq? head 'camera-bookmark-save))
        (cond
          [(not (= nargs 3)) (BotActionReject 'invalid-camera-arity raw)]
          [else
           (define slot (car args))
           (define pt (extract-world-point2d (cadr args) (caddr args)))
           (if (and (exact-nonnegative-integer? slot) (<= slot 9) pt)
               (BotCameraAction head slot pt)
               (BotActionReject 'invalid-camera-bookmark raw))])]

       ;; 17. Known Non-Wire Telemetry / UI Framing Directives
       [(hash-ref TELEMETRY-HEADS head #f)
        (BotTelemetryDirective head args)]

       ;; Unknown head -> deterministic structured rejection!
       [else
        (BotActionReject 'unknown-action-head raw)])]))

(: actors->sexp-arg (-> NonEmptyUnitTags (U Positive-Integer (Listof Positive-Integer))))
(define (actors->sexp-arg tags)
  (if (null? (NonEmptyUnitTags-tail tags))
      (NonEmptyUnitTags-head tags)
      (non-empty-unit-tags->list tags)))

(: typed-bot-action->sexp (-> TypedBotAction (Listof Any)))
(define (typed-bot-action->sexp act)
  (cond
    [(BotBuildStructure? act)
     (define pos (BotBuildStructure-pos act))
     (if pos
         (list 'build (BotBuildStructure-structure act) (WorldPoint2D-x pos) (WorldPoint2D-y pos))
         (list 'build (BotBuildStructure-structure act)))]
    [(BotBuildGas? act)
     (define pos (BotBuildGas-pos act))
     (if pos
         (list 'build (BotBuildGas-gas-building act) (WorldPoint2D-x pos) (WorldPoint2D-y pos))
         (list 'build (BotBuildGas-gas-building act)))]
    [(BotBuildAddon? act)
     (define pos (BotBuildAddon-pos act))
     (if pos
         (list 'build (BotBuildAddon-addon act) (WorldPoint2D-x pos) (WorldPoint2D-y pos))
         (list 'build (BotBuildAddon-addon act)))]
    [(BotBuildNydusWorm? act)
     (define actors (BotBuildNydusWorm-actors act))
     (define pt (BotBuildNydusWorm-target act))
     (if actors
         (list 'cast-spell (actors->sexp-arg actors) 'build-nydus-worm (WorldPoint2D-x pt) (WorldPoint2D-y pt))
         (list 'build 'nydus-worm (WorldPoint2D-x pt) (WorldPoint2D-y pt)))]
    [(BotExpand? act)
     (define th (BotExpand-townhall act))
     (define pt (BotExpand-target act))
     (if th
         (list 'expand th (WorldPoint2D-x pt) (WorldPoint2D-y pt))
         (list 'expand (WorldPoint2D-x pt) (WorldPoint2D-y pt)))]
    [(BotTrain? act)
     (define pid (BotTrain-producer-id act))
     (if pid
         (list 'train-unit pid (BotTrain-unit act))
         (list 'train (BotTrain-unit act)))]
    [(BotResearch? act)
     (list 'research (BotResearch-upgrade act))]
    [(BotMorph? act)
     (define actors (BotMorph-actors act))
     (if actors
         (list 'morph (actors->sexp-arg actors) (BotMorph-target act))
         (list 'morph (BotMorph-target act)))]
    [(BotCastSelf? act)
     (list 'cast-spell (actors->sexp-arg (BotCastSelf-actors act)) (BotCastSelf-spell act))]
    [(BotCastPoint? act)
     (define pt (BotCastPoint-target act))
     (list 'cast-spell
           (actors->sexp-arg (BotCastPoint-actors act))
           (BotCastPoint-spell act)
           (WorldPoint2D-x pt)
           (WorldPoint2D-y pt))]
    [(BotCastUnit? act)
     (list 'cast-spell
           (actors->sexp-arg (BotCastUnit-actors act))
           (BotCastUnit-spell act)
           (BotCastUnit-target act))]
    [(BotAttackUnit? act)
     (define fb (BotAttackUnit-fallback act))
     (if fb
         (list (BotAttackUnit-kind act)
               (actors->sexp-arg (BotAttackUnit-actors act))
               (BotAttackUnit-target act)
               (WorldPoint2D-x fb)
               (WorldPoint2D-y fb))
         (list (BotAttackUnit-kind act)
               (actors->sexp-arg (BotAttackUnit-actors act))
               (BotAttackUnit-target act)))]
    [(BotAttackPos? act)
     (define pt (BotAttackPos-target act))
     (list (BotAttackPos-kind act)
           (actors->sexp-arg (BotAttackPos-actors act))
           (WorldPoint2D-x pt)
           (WorldPoint2D-y pt))]
    [(BotMoveOrder? act)
     (define pt (BotMoveOrder-target act))
     (list (BotMoveOrder-kind act)
           (actors->sexp-arg (BotMoveOrder-actors act))
           (WorldPoint2D-x pt)
           (WorldPoint2D-y pt))]
    [(BotHoldPosition? act)
     (define pt (BotHoldPosition-target act))
     (if pt
         (list 'hold-position
               (actors->sexp-arg (BotHoldPosition-actors act))
               (WorldPoint2D-x pt)
               (WorldPoint2D-y pt))
         (list 'hold-position (actors->sexp-arg (BotHoldPosition-actors act))))]
    [(BotCancelBuilding? act)
     (list 'cancel-building (BotCancelBuilding-actor act))]
    [(BotModeSwitch? act)
     (list (BotModeSwitch-mode act) (actors->sexp-arg (BotModeSwitch-actors act)))]
    [(BotHarvest? act)
     (list (BotHarvest-kind act)
           (actors->sexp-arg (BotHarvest-workers act))
           (BotHarvest-target-id act))]
    [(BotWorkerMechanic? act)
     (define k (BotWorkerMechanic-kind act))
     (define w (actors->sexp-arg (BotWorkerMechanic-workers act)))
     (define p (BotWorkerMechanic-patch-id act))
     (define t (BotWorkerMechanic-target-id act))
     (define pt (BotWorkerMechanic-target act))
     (define pt2 (BotWorkerMechanic-secondary act))
     (cond
       [(and (eq? k 'mineral-harass) pt2)
        (list 'mineral-harass w (WorldPoint2D-x pt) (WorldPoint2D-y pt)
              (WorldPoint2D-x pt2) (WorldPoint2D-y pt2))]
       [(eq? k 'worker-drill-stack-attack)
        (list 'worker-drill-stack-attack w (or p 0) (or t 0)
              (WorldPoint2D-x pt) (WorldPoint2D-y pt))]
       [(eq? k 'pull-workers-attack)
        (if t
            (list 'pull-workers-attack w t (WorldPoint2D-x pt) (WorldPoint2D-y pt))
            (list 'pull-workers-attack w (WorldPoint2D-x pt) (WorldPoint2D-y pt)))]
       [else
        (if p
            (list 'mineral-walk w p (WorldPoint2D-x pt) (WorldPoint2D-y pt))
            (list 'mineral-walk w (WorldPoint2D-x pt) (WorldPoint2D-y pt)))])]
    [(BotTransportAction? act)
     (define pass (BotTransportAction-passengers act))
     (define pt (BotTransportAction-target act))
     (cond
       [(and pass pt)
        (list (BotTransportAction-kind act)
              (BotTransportAction-transport act)
              (actors->sexp-arg pass)
              (WorldPoint2D-x pt)
              (WorldPoint2D-y pt))]
       [pt
        (list (BotTransportAction-kind act)
              (BotTransportAction-transport act)
              (WorldPoint2D-x pt)
              (WorldPoint2D-y pt))]
       [else
        (list (BotTransportAction-kind act) (BotTransportAction-transport act))])]
    [(BotTerranAddonSwap? act)
     (define pt (BotTerranAddonSwap-addon-pos act))
     (if pt
         (list 'terran-addon-swap
               (BotTerranAddonSwap-lift-id act)
               (BotTerranAddonSwap-land-id act)
               (WorldPoint2D-x pt)
               (WorldPoint2D-y pt))
         (list 'swap-addon
               (BotTerranAddonSwap-lift-id act)
               (BotTerranAddonSwap-land-id act)))]
    [(BotTacticalManeuver? act)
     (define k (BotTacticalManeuver-kind act))
     (define pt (BotTacticalManeuver-anchor act))
     (define params (BotTacticalManeuver-params act))
     (cond
       [(and (or (eq? k 'execute-spatial-maneuver) (eq? k 'mirror-spatial-maneuver))
             pt (pair? params))
        (list k (car params) (WorldPoint2D-x pt) (WorldPoint2D-y pt))]
       [(and (eq? k 'pre-split-wings)
             (pair? params)
             (pair? (cdr params))
             (pair? (cddr params))
             (null? (cdddr params)))
        (define p1 (car params))
        (define p2 (cadr params))
        (define p3 (caddr params))
        (if (and (WorldPoint2D? p1) (WorldPoint2D? p2) (WorldPoint2D? p3))
            (list 'pre-split-wings
                  (WorldPoint2D-x p1) (WorldPoint2D-y p1)
                  (WorldPoint2D-x p2) (WorldPoint2D-y p2)
                  (WorldPoint2D-x p3) (WorldPoint2D-y p3))
            (cons k params))]
       [(and (eq? k 'form-concave-arc) pt)
        (list* 'form-concave-arc (WorldPoint2D-x pt) (WorldPoint2D-y pt) params)]
       [(and (eq? k 'clear-gas-steal) pt (pair? params))
        (list 'clear-gas-steal (car params) (WorldPoint2D-x pt) (WorldPoint2D-y pt))]
       [(and (eq? k 'clear-expansion-block) pt)
        (if (pair? params)
            (list 'clear-expansion-block (car params) (WorldPoint2D-x pt) (WorldPoint2D-y pt))
            (list 'clear-expansion-block (WorldPoint2D-x pt) (WorldPoint2D-y pt)))]
       [(eq? k 'snipe-enemy-changeling)
        (if (and pt (pair? params))
            (list 'snipe-enemy-changeling (car params) (WorldPoint2D-x pt) (WorldPoint2D-y pt))
            (cons 'snipe-enemy-changeling params))]
       [else (cons k params)])]
    [(BotCameraAction? act)
     (define slot (BotCameraAction-slot act))
     (define pt (BotCameraAction-target act))
     (if slot
         (list (BotCameraAction-kind act) slot (WorldPoint2D-x pt) (WorldPoint2D-y pt))
         (list (BotCameraAction-kind act) (WorldPoint2D-x pt) (WorldPoint2D-y pt)))]
    [(BotTelemetryDirective? act)
     (cons (BotTelemetryDirective-head act) (BotTelemetryDirective-payload act))]
    [else
     (ann act Nothing)]))

(: sanitize-validated-sexp (-> Any TypedBotAction Any))
(define (sanitize-validated-sexp raw parsed)
  (cond
    ;; Strip legacy dummy args on self-cast spells and canonicalize raw `381` -> `'emp-round`
    [(BotCastSelf? parsed)
     (typed-bot-action->sexp parsed)]
    [(and (BotCastPoint? parsed)
          (pair? raw) (list? raw) (>= (length raw) 3)
          (exact-integer? (cadr (cdr raw))))
     ;; Raw integer spell `381` was passed; emit canonical `'emp-round` symbol (`1628`)
     (typed-bot-action->sexp parsed)]
    [else raw]))

(: filter-valid-bot-actions
   (-> (Listof Any) (Values (Listof Any) (Listof BotActionReject))))
(define (filter-valid-bot-actions actions)
  (let loop ([rest : (Listof Any) actions]
             [rev-valid : (Listof Any) '()]
             [rev-rejects : (Listof BotActionReject) '()])
    (cond
      [(null? rest)
       (values (reverse rev-valid) (reverse rev-rejects))]
      [else
       (define raw (car rest))
       (define parsed (parse-bot-action-sexp raw))
       (if (BotActionReject? parsed)
           (loop (cdr rest) rev-valid (cons parsed rev-rejects))
           (loop (cdr rest)
                 (cons (sanitize-validated-sexp raw parsed) rev-valid)
                 rev-rejects))])))
