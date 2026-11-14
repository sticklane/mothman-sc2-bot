#lang racket/base

;; =============================================================================
;; lib/sc2-proto-wire-verifier.rkt
;; Independent Binary `s2clientprotocol` Wire & Schema Verifier
;; =============================================================================
;;
;; Clean-room, zero-shared-code binary Protobuf wire parser and semantic schema
;; verifier for outgoing StarCraft II (`SC2APIProtocol`) `Request` and `Action`
;; messages (`data/proto/sc2api.proto`, `raw.proto`, `query.proto`, `ui.proto`,
;; `common.proto`).
;;
;; Intentionally shares ZERO encoding/decoding functions with
;; `lib/sc2-typed-commands.rkt` or `lib/sc2-protobuf-ws.rkt` so it serves as an
;; independent differential oracle during fuzzing and CI verification.

(require racket/math)

(provide
 verify-sc2-request-bytes
 verify-sc2-action-bytes
 verify-sc2-point2d-bytes
 verify-sc2-point-bytes)

;; =============================================================================
;; 1. Independent LotV `ability_id` Target-Mode & Autocast Tables
;; =============================================================================

(define VERIFIER-ABILITY-VEC-SIZE 4200)
(define VERIFIER-MAX-UINT32 #xFFFFFFFF)
(define VERIFIER-MAX-INT32  #x7FFFFFFF)
(define VERIFIER-MAX-UINT64 #xFFFFFFFFFFFFFFFF)
(define VERIFIER-MAX-FIELD  #x1FFFFFFF)

(define ABILITY-TARGET-MODE-VEC (make-vector VERIFIER-ABILITY-VEC-SIZE #f))
(define AUTOCAST-ALLOWED-VEC    (make-vector VERIFIER-ABILITY-VEC-SIZE #f))

(let ([register-mode!
       (lambda (mode ids)
         (for ([id (in-list ids)])
           (when (and (> id 0) (< id VERIFIER-ABILITY-VEC-SIZE))
             (vector-set! ABILITY-TARGET-MODE-VEC id mode))))])
  ;; 1A. Strict NoTarget abilities (excludes 1766 MORPH_ARCHON)
  (register-mode!
   'strict-no-target
   '(4 11 18 32
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
     1342 1343 1344 1345 1346 1348 1351 1352 1353 1354 1356 1632
     80 1216 1218 1220 1372 1448 1725 1727 2112 2330 2332 2708 3743 3745
     524 560 561 562 563 591 594 595 596 597 614 620 621 622 623 624 626 710
     388 390 403 405 417 452 485 518 556 558
     1450 1516 1522 1978 1998 2362 2364 2560 3679
     110 916 917 919 920 921 922 946 948 950 954 955 976 977 978 979 994 1006
     1042 1518 1520 1528 1530 3739 3741
     76 146 148 150 152 154 156 158 160 162 164 181
     253 380 382 383 392 393
     1374 1376 1378 1380 1382 1384 1386 1388 1390 1392
     1433 1435 1444 1446 1512 1514 1683 1684
     2014 2016 2095 2097 2108 2110 2114 2116
     2328 2340 2342 2375 2376 2389 2391 2393
     3661 3662 3675 3676 3677 4124
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

  ;; 1B. Archon Morph (1766): NoTarget + exact 2 distinct unit_tags
  (register-mode! 'archon-1766 '(1766))

  ;; 1C. PointOrNone (Terran AddOns & Spine/Spore Root/Uproot)
  (register-mode!
   'point-or-none
   '(421 422 454 455 487 488 3680 3681 3682 3683))

  ;; 1D. Strict PointTarget (ground buildings, warp-ins, Nydus Worm 1768, area spells)
  (register-mode!
   'strict-point
   '(1152 1155 1156 1157 1158 1159 1160 1161 1162 1163 1165 1166 1167
     1694 1729 1731 1733 1768 3691
     318 319 321 322 323 324 326 327 328 329 331 333
     419 520 522 554 1524 3678
     880 881 883 884 885 886 887 889 890 891 892 893 894 895
     1413 1414 1416 1417 1418 1419
     74 142 349 399 1036 1442 1526 1622 1628 1764 1990
     2063 2146 2338 2346 2358 2368 2505 2544 2545 2558 2588 2698 2700
     3684 3686 3687 3757))

  ;; 1E. PointOrUnit (Smart, Move, Patrol, Attack, Rallies, UnloadAllAt)
  (register-mode!
   'point-or-unit
   '(1 16 17 23 24 25
     195 199 203 207 211 212
     396 913 1408
     3669 3673 3674 3690 3794 3795))

  ;; 1F. Strict UnitTarget (Gas 320/882/1154, Gather 3666, Load, Inject 251, Chrono 3755, Neural 249, etc.)
  (register-mode!
   'strict-unit
   '(320 882 1154
     166 295 298 1183 3666
     394 407 911 1406 1437 2370 3668
     78 140 171 173 249 251 255 261 316 384 386 401
     1664 1819 1825 2067 2069 2073 2099 2324 2350 2542 2714
     3685 3747 3751 3753 3755 4107 4113 4126))

  ;; 1G. Autocast toggleable abilities
  (for ([id (in-list '(78 316 386 1042 1819 1990 2099 2328 2350 3685 4113))])
    (vector-set! AUTOCAST-ALLOWED-VEC id #t)))

;; =============================================================================
;; 2. Clean-Room Binary Protobuf Wire Reader
;; =============================================================================

(struct raw-wire-field (num wtype val) #:transparent)

;; Returns (values ok? val-or-reason next-pos)
(define (read-wire-varint bs pos end)
  (let loop ([i pos]
             [shift 0]
             [acc 0])
    (cond
      [(>= i end)
       (values #f 'truncated-varint i)]
      [(> shift 63)
       (values #f 'overlong-varint i)]
      [else
       (define b (bytes-ref bs i))
       (cond
         [(and (= shift 63) (> b 1))
          (values #f 'uint64-varint-overflow i)]
         [else
          (define next-acc
            (bitwise-ior acc (arithmetic-shift (bitwise-and b #x7F) shift)))
          (if (zero? (bitwise-and b #x80))
              (values #t next-acc (add1 i))
              (loop (add1 i) (+ shift 7) next-acc))])])))

;; Parses all fields in bs[start..end) into a list of `raw-wire-field`.
;; Rejects truncated payloads, overlong/overflowing varints, field number 0,
;; field numbers > 2^29-1, and deprecated/invalid wire types (3, 4, 6, 7).
(define (parse-wire-slice bs start end)
  (let loop ([pos start]
             [rev '()])
    (cond
      [(= pos end)
       (values #t (reverse rev))]
      [(> pos end)
       (values #f 'slice-out-of-bounds)]
      [else
       (define-values (ok-tag? tag pos1) (read-wire-varint bs pos end))
       (cond
         [(not ok-tag?)
          (values #f tag)]
         [else
          (define fnum (arithmetic-shift tag -3))
          (define wtype (bitwise-and tag #x07))
          (cond
            [(or (<= fnum 0) (> fnum VERIFIER-MAX-FIELD))
             (values #f 'invalid-field-number)]
            [(= wtype 0)
             (define-values (ok-v? v pos2) (read-wire-varint bs pos1 end))
             (if ok-v?
                 (loop pos2 (cons (raw-wire-field fnum 0 v) rev))
                 (values #f v))]
            [(= wtype 1)
             (define pos2 (+ pos1 8))
             (if (<= pos2 end)
                 (loop pos2 (cons (raw-wire-field fnum 1 (subbytes bs pos1 pos2)) rev))
                 (values #f 'truncated-fixed64))]
            [(= wtype 2)
             (define-values (ok-len? len pos2) (read-wire-varint bs pos1 end))
             (cond
               [(not ok-len?)
                (values #f len)]
               [(> (+ pos2 len) end)
                (values #f 'truncated-length-delimited)]
               [else
                (define pos3 (+ pos2 len))
                (loop pos3 (cons (raw-wire-field fnum 2 (subbytes bs pos2 pos3)) rev))])]
            [(= wtype 5)
             (define pos2 (+ pos1 4))
             (if (<= pos2 end)
                 (loop pos2 (cons (raw-wire-field fnum 5 (subbytes bs pos1 pos2)) rev))
                 (values #f 'truncated-fixed32))]
            [else
             (values #f 'deprecated-or-invalid-wire-type)])])])))

(define (parse-wire-bytes bs)
  (if (bytes? bs)
      (parse-wire-slice bs 0 (bytes-length bs))
      (values #f 'not-bytes)))

(define (decode-ieee754-f32-le b4)
  (floating-point-bytes->real b4 #f 0 4))

(define (finite-real? v)
  (and (real? v) (not (nan? v)) (not (infinite? v))))

(define (in-world-bounds? v)
  (and (finite-real? v) (>= v 0.0) (<= v 256.0)))

(define (valid-utf8-slice? bs min-len max-len)
  (define len (bytes-length bs))
  (and (>= len min-len)
       (<= len max-len)
       (with-handlers ([exn:fail? (lambda (_e) #f)])
         (string? (bytes->string/utf-8 bs)))))

(define (strictly-unique-positive-u64-tags? tags)
  (and (pair? tags)
       (let loop ([rest tags]
                  [seen '()])
         (cond
           [(null? rest) #t]
           [else
            (define t (car rest))
            (if (and (exact-integer? t)
                     (> t 0)
                     (<= t VERIFIER-MAX-UINT64)
                     (not (memv t seen)))
                (loop (cdr rest) (cons t seen))
                #f)]))))

;; =============================================================================
;; 3. Geometry Submessage Verifiers (`Point2D`, `Point`)
;; =============================================================================

;; Shared decoder/verifier for `Point2D` (x, y) and `Point` (x, y, optional z).
(define (verify-sc2-point-coords bs allow-z?
                                 missing-err bounds-err bad-wt-err
                                 dup-x-err dup-y-err dup-z-err unknown-err)
  (define-values (ok? fields) (parse-wire-bytes bs))
  (cond
    [(not ok?) (values #f fields)]
    [else
     (let loop ([fs fields]
                [has-x? #f] [x 0.0]
                [has-y? #f] [y 0.0]
                [has-z? #f] [z 0.0])
       (cond
         [(null? fs)
          (cond
            [(or (not has-x?) (not has-y?))
             (values #f missing-err)]
            [(or (not (in-world-bounds? x)) (not (in-world-bounds? y)))
             (values #f bounds-err)]
            [(and allow-z? has-z? (not (finite-real? z)))
             (values #f 'point-z-nonfinite)]
            [else
             (values #t (if allow-z? (list 'point x y z) (list 'point2d x y)))])]
         [else
          (define f (car fs))
          (define fn (raw-wire-field-num f))
          (define wt (raw-wire-field-wtype f))
          (cond
            [(not (= wt 5))
             (values #f bad-wt-err)]
            [(= fn 1)
             (if has-x?
                 (values #f dup-x-err)
                 (loop (cdr fs) #t (decode-ieee754-f32-le (raw-wire-field-val f)) has-y? y has-z? z))]
            [(= fn 2)
             (if has-y?
                 (values #f dup-y-err)
                 (loop (cdr fs) has-x? x #t (decode-ieee754-f32-le (raw-wire-field-val f)) has-z? z))]
            [(and allow-z? (= fn 3))
             (if has-z?
                 (values #f dup-z-err)
                 (loop (cdr fs) has-x? x has-y? y #t (decode-ieee754-f32-le (raw-wire-field-val f))))]
            [else
             (values #f unknown-err)])]))]))

(define (verify-sc2-point2d-bytes bs)
  (verify-sc2-point-coords bs #f
                           'point2d-missing-coord 'point2d-out-of-bounds-or-nonfinite
                           'point2d-bad-wire-type 'point2d-duplicate-x
                           'point2d-duplicate-y #f 'point2d-unknown-field))

(define (verify-sc2-point-bytes bs)
  (verify-sc2-point-coords bs #t
                           'point-missing-xy 'point-xy-out-of-bounds-or-nonfinite
                           'point-bad-wire-type 'point-duplicate-x
                           'point-duplicate-y 'point-duplicate-z 'point-unknown-field))

;; =============================================================================
;; 4. `Action` Submessage Verifiers (`raw.proto`, `ui.proto`, `sc2api.proto`)
;; =============================================================================

(define (verify-unit-command-bytes bs)
  (define-values (ok? fields) (parse-wire-bytes bs))
  (cond
    [(not ok?) (values #f fields)]
    [else
     (let loop ([fs fields]
                [has-ab? #f]
                [ab-id 0]
                [has-pos? #f]
                [pos-bs #""]
                [has-tgt? #f]
                [tgt-tag 0]
                [rev-tags '()]
                [has-q? #f]
                [q-flag #f])
       (cond
         [(null? fs)
          (cond
            [(not has-ab?)
             (values #f 'unit-cmd-missing-ability-id)]
            [(or (<= ab-id 0) (>= ab-id VERIFIER-ABILITY-VEC-SIZE))
             (values #f 'unit-cmd-unrecognized-ability-id)]
            [else
             (define mode (vector-ref ABILITY-TARGET-MODE-VEC ab-id))
             (define tags (reverse rev-tags))
             (cond
               [(not mode)
                (values #f 'unit-cmd-unrecognized-ability-id)]
               [(and has-pos? has-tgt?)
                (values #f 'unit-cmd-oneof-target-collision)]
               [(not (strictly-unique-positive-u64-tags? tags))
                (values #f 'unit-cmd-invalid-or-duplicate-unit-tags)]
               [else
                (define-values (pos-ok? pos-dec)
                  (if has-pos?
                      (verify-sc2-point2d-bytes pos-bs)
                      (values #t #f)))
                (cond
                  [(not pos-ok?)
                   (values #f pos-dec)]
                  [(and has-tgt? (or (<= tgt-tag 0) (> tgt-tag VERIFIER-MAX-UINT64)))
                   (values #f 'unit-cmd-invalid-target-unit-tag)]
                  [else
                   (case mode
                     [(strict-no-target)
                      (if (or has-pos? has-tgt?)
                          (values #f 'unit-cmd-no-target-has-target)
                          (values #t (list 'unit-cmd-none ab-id tags q-flag)))]
                     [(archon-1766)
                      (cond
                        [(or has-pos? has-tgt?)
                         (values #f 'archon-1766-has-target)]
                        [(not (= (length tags) 2))
                         (values #f 'archon-1766-requires-exact-2-tags)]
                        [else
                         (values #t (list 'unit-cmd-archon 1766 tags q-flag))])]
                     [(strict-point)
                      (if (and has-pos? (not has-tgt?))
                          (values #t (list 'unit-cmd-point ab-id pos-dec tags q-flag))
                          (values #f 'unit-cmd-point-target-mismatch))]
                     [(strict-unit)
                      (if (and has-tgt? (not has-pos?))
                          (values #t (list 'unit-cmd-unit ab-id tgt-tag tags q-flag))
                          (values #f 'unit-cmd-unit-target-mismatch))]
                     [(point-or-unit)
                      (if (or (and has-pos? (not has-tgt?))
                              (and has-tgt? (not has-pos?)))
                          (values #t (list 'unit-cmd-dual ab-id (or pos-dec tgt-tag) tags q-flag))
                          (values #f 'unit-cmd-point-or-unit-requires-xor-target))]
                     [(point-or-none)
                      (if has-tgt?
                          (values #f 'unit-cmd-point-or-none-forbids-unit-tag)
                          (values #t (list 'unit-cmd-point-or-none ab-id pos-dec tags q-flag)))]
                     [else
                      (values #f 'unit-cmd-unknown-mode)])])])])]
         [else
          (define f (car fs))
          (define fn (raw-wire-field-num f))
          (define wt (raw-wire-field-wtype f))
          (define v (raw-wire-field-val f))
          (case fn
            [(1)
             (if (or (not (= wt 0)) has-ab?)
                 (values #f 'unit-cmd-bad-ability-field)
                 (loop (cdr fs) #t v has-pos? pos-bs has-tgt? tgt-tag rev-tags has-q? q-flag))]
            [(2)
             (if (or (not (= wt 2)) has-pos?)
                 (values #f 'unit-cmd-bad-pos-field)
                 (loop (cdr fs) has-ab? ab-id #t v has-tgt? tgt-tag rev-tags has-q? q-flag))]
            [(3)
             (if (or (not (= wt 0)) has-tgt?)
                 (values #f 'unit-cmd-bad-target-tag-field)
                 (loop (cdr fs) has-ab? ab-id has-pos? pos-bs #t v rev-tags has-q? q-flag))]
            [(4)
             (if (not (= wt 0))
                 (values #f 'unit-cmd-bad-unit-tags-wire-type)
                 (loop (cdr fs) has-ab? ab-id has-pos? pos-bs has-tgt? tgt-tag (cons v rev-tags) has-q? q-flag))]
            [(5)
             (if (or (not (= wt 0)) has-q? (not (or (= v 0) (= v 1))))
                 (values #f 'unit-cmd-bad-queue-field)
                 (loop (cdr fs) has-ab? ab-id has-pos? pos-bs has-tgt? tgt-tag rev-tags #t (= v 1)))]
            [else
             (values #f 'unit-cmd-unknown-field)])]))]))

(define (verify-camera-move-bytes bs)
  (define-values (ok? fields) (parse-wire-bytes bs))
  (cond
    [(not ok?) (values #f fields)]
    [(not (and (pair? fields) (null? (cdr fields))))
     (values #f 'camera-move-must-have-single-center-field)]
    [else
     (define f (car fields))
     (if (and (= (raw-wire-field-num f) 1) (= (raw-wire-field-wtype f) 2))
         (let-values ([(pt-ok? pt-dec) (verify-sc2-point-bytes (raw-wire-field-val f))])
           (if pt-ok?
               (values #t (list 'camera-move pt-dec))
               (values #f pt-dec)))
         (values #f 'camera-move-unknown-or-bad-field))]))

(define (verify-toggle-autocast-bytes bs)
  (define-values (ok? fields) (parse-wire-bytes bs))
  (cond
    [(not ok?) (values #f fields)]
    [else
     (let loop ([fs fields]
                [has-ab? #f]
                [ab-id 0]
                [rev-tags '()])
       (cond
         [(null? fs)
          (define tags (reverse rev-tags))
          (cond
            [(not has-ab?)
             (values #f 'autocast-missing-ability-id)]
            [(or (<= ab-id 0)
                 (>= ab-id VERIFIER-ABILITY-VEC-SIZE)
                 (not (vector-ref AUTOCAST-ALLOWED-VEC ab-id)))
             (values #f 'autocast-invalid-ability-id)]
            [(not (strictly-unique-positive-u64-tags? tags))
             (values #f 'autocast-invalid-or-duplicate-unit-tags)]
            [else
             (values #t (list 'toggle-autocast ab-id tags))])]
         [else
          (define f (car fs))
          (define fn (raw-wire-field-num f))
          (define wt (raw-wire-field-wtype f))
          (define v (raw-wire-field-val f))
          (cond
            [(not (= wt 0))
             (values #f 'autocast-bad-wire-type)]
            [(= fn 1)
             (if has-ab?
                 (values #f 'autocast-duplicate-ability-id)
                 (loop (cdr fs) #t v rev-tags))]
            [(= fn 2)
             (loop (cdr fs) has-ab? ab-id (cons v rev-tags))]
            [else
             (values #f 'autocast-unknown-field)])]))]))

(define (verify-action-raw-bytes bs)
  (define-values (ok? fields) (parse-wire-bytes bs))
  (cond
    [(not ok?) (values #f fields)]
    [(null? fields)
     (values #f 'action-raw-empty-oneof)]
    [(not (null? (cdr fields)))
     (values #f 'action-raw-multiple-oneof-fields)]
    [else
     (define f (car fields))
     (define fn (raw-wire-field-num f))
     (define wt (raw-wire-field-wtype f))
     (define sub (raw-wire-field-val f))
     (cond
       [(not (= wt 2))
        (values #f 'action-raw-bad-wire-type)]
       [(= fn 1) (verify-unit-command-bytes sub)]
       [(= fn 2) (verify-camera-move-bytes sub)]
       [(= fn 3) (verify-toggle-autocast-bytes sub)]
       [else (values #f 'action-raw-unknown-field)])]))

(define (verify-control-group-bytes bs)
  (define-values (ok? fields) (parse-wire-bytes bs))
  (cond
    [(not ok?) (values #f fields)]
    [else
     (let loop ([fs fields]
                [has-act? #f]
                [act-enum 0]
                [has-idx? #f]
                [grp-idx 0])
       (cond
         [(null? fs)
          (if (and has-act? (<= 1 act-enum 5) has-idx? (<= 0 grp-idx 9))
              (values #t (list 'control-group act-enum grp-idx))
              (values #f 'control-group-invalid-fields))]
         [else
          (define f (car fs))
          (define fn (raw-wire-field-num f))
          (define wt (raw-wire-field-wtype f))
          (define v (raw-wire-field-val f))
          (cond
            [(not (= wt 0))
             (values #f 'control-group-bad-wire-type)]
            [(= fn 1)
             (if has-act?
                 (values #f 'control-group-duplicate-action)
                 (loop (cdr fs) #t v has-idx? grp-idx))]
            [(= fn 2)
             (if has-idx?
                 (values #f 'control-group-duplicate-index)
                 (loop (cdr fs) has-act? act-enum #t v))]
            [else
             (values #f 'control-group-unknown-field)])]))]))

(define (verify-action-ui-bytes bs)
  (define-values (ok? fields) (parse-wire-bytes bs))
  (cond
    [(not ok?) (values #f fields)]
    [(not (and (pair? fields) (null? (cdr fields))))
     (values #f 'action-ui-must-have-single-oneof)]
    [else
     (define f (car fields))
     (if (and (= (raw-wire-field-num f) 1) (= (raw-wire-field-wtype f) 2))
         (verify-control-group-bytes (raw-wire-field-val f))
         (values #f 'action-ui-unsupported-or-unknown-field))]))

(define (verify-action-chat-bytes bs)
  (define-values (ok? fields) (parse-wire-bytes bs))
  (cond
    [(not ok?) (values #f fields)]
    [else
     (let loop ([fs fields]
                [has-chan? #f]
                [chan 0]
                [has-msg? #f]
                [msg-bs #""])
       (cond
         [(null? fs)
          (cond
            [(or (not has-chan?) (not (or (= chan 1) (= chan 2))))
             (values #f 'action-chat-invalid-channel)]
            [(or (not has-msg?) (not (valid-utf8-slice? msg-bs 1 256)))
             (values #f 'action-chat-invalid-message)]
            [else
             (values #t (list 'chat chan (bytes->string/utf-8 msg-bs)))])]
         [else
          (define f (car fs))
          (define fn (raw-wire-field-num f))
          (define wt (raw-wire-field-wtype f))
          (define v (raw-wire-field-val f))
          (cond
            [(and (= fn 1) (= wt 0) (not has-chan?))
             (loop (cdr fs) #t v has-msg? msg-bs)]
            [(and (= fn 2) (= wt 2) (not has-msg?))
             (loop (cdr fs) has-chan? chan #t v)]
            [else
             (values #f 'action-chat-unknown-or-duplicate-field)])]))]))

(define (verify-sc2-action-bytes bs)
  (cond
    [(or (not (bytes? bs)) (zero? (bytes-length bs)))
     (values #f 'action-empty-or-not-bytes)]
    [else
     (define-values (ok? fields) (parse-wire-bytes bs))
     (cond
       [(not ok?) (values #f fields)]
       [(null? fields)
        (values #f 'action-empty)]
       [(not (null? (cdr fields)))
        (values #f 'action-conflicting-or-duplicate-payloads)]
       [else
        (define f (car fields))
        (define fn (raw-wire-field-num f))
        (define wt (raw-wire-field-wtype f))
        (define sub (raw-wire-field-val f))
        (cond
          [(not (= wt 2))
           (values #f 'action-bad-wire-type)]
          [(= fn 1) (verify-action-raw-bytes sub)]
          [(= fn 4) (verify-action-ui-bytes sub)]
          [(= fn 6) (verify-action-chat-bytes sub)]
          [else (values #f 'action-unknown-or-disallowed-field)])])]))

;; =============================================================================
;; 5. `Request` Submessage Verifiers (`sc2api.proto`, `query.proto`)
;; =============================================================================

(define (verify-empty-submsg bs err-sym)
  (define-values (ok? fields) (parse-wire-bytes bs))
  (cond
    [(not ok?) (values #f fields)]
    [(null? fields) (values #t 'empty)]
    [else (values #f err-sym)]))

(define (verify-request-action-bytes bs)
  (define-values (ok? fields) (parse-wire-bytes bs))
  (cond
    [(not ok?) (values #f fields)]
    [else
     (let loop ([fs fields]
                [rev-acts '()])
       (cond
         [(null? fs)
          (if (null? rev-acts)
              (values #f 'request-action-empty)
              (values #t (list 'request-action (reverse rev-acts))))]
         [else
          (define f (car fs))
          (cond
            [(and (= (raw-wire-field-num f) 1) (= (raw-wire-field-wtype f) 2))
             (define-values (act-ok? act-dec) (verify-sc2-action-bytes (raw-wire-field-val f)))
             (if act-ok?
                 (loop (cdr fs) (cons act-dec rev-acts))
                 (values #f act-dec))]
            [else
             (values #f 'request-action-unknown-or-bad-field)])]))]))

(define (verify-request-step-bytes bs)
  (define-values (ok? fields) (parse-wire-bytes bs))
  (cond
    [(not ok?) (values #f fields)]
    [(not (and (pair? fields) (null? (cdr fields))))
     (values #f 'request-step-must-have-single-count-field)]
    [else
     (define f (car fields))
     (define v (raw-wire-field-val f))
     (if (and (= (raw-wire-field-num f) 1)
              (= (raw-wire-field-wtype f) 0)
              (>= v 1)
              (<= v 65535))
         (values #t (list 'request-step v))
         (values #f 'request-step-invalid-count))]))

(define (verify-query-placement-item-bytes bs)
  (define-values (ok? fields) (parse-wire-bytes bs))
  (cond
    [(not ok?) (values #f fields)]
    [else
     (let loop ([fs fields]
                [has-ab? #f]
                [ab-id 0]
                [has-pos? #f]
                [pos-bs #""]
                [has-tag? #f]
                [utag 0])
       (cond
         [(null? fs)
          (cond
            [(or (not has-ab?) (<= ab-id 0) (> ab-id VERIFIER-MAX-INT32))
             (values #f 'query-placement-invalid-ability-id)]
            [(not has-pos?)
             (values #f 'query-placement-missing-target-pos)]
            [(and has-tag? (or (<= utag 0) (> utag VERIFIER-MAX-UINT64)))
             (values #f 'query-placement-invalid-unit-tag)]
            [else
             (define-values (pt-ok? pt-dec) (verify-sc2-point2d-bytes pos-bs))
             (if pt-ok?
                 (values #t (list 'placement ab-id pt-dec (and has-tag? utag)))
                 (values #f pt-dec))])]
         [else
          (define f (car fs))
          (define fn (raw-wire-field-num f))
          (define wt (raw-wire-field-wtype f))
          (define v (raw-wire-field-val f))
          (cond
            [(and (= fn 1) (= wt 0) (not has-ab?))
             (loop (cdr fs) #t v has-pos? pos-bs has-tag? utag)]
            [(and (= fn 2) (= wt 2) (not has-pos?))
             (loop (cdr fs) has-ab? ab-id #t v has-tag? utag)]
            [(and (= fn 3) (= wt 0) (not has-tag?))
             (loop (cdr fs) has-ab? ab-id has-pos? pos-bs #t v)]
            [else
             (values #f 'query-placement-unknown-or-duplicate-field)])]))]))

(define (verify-request-query-bytes bs)
  (define-values (ok? fields) (parse-wire-bytes bs))
  (cond
    [(not ok?) (values #f fields)]
    [else
     (let loop ([fs fields]
                [rev-placements '()]
                [has-ign? #f]
                [ign? #f])
       (cond
         [(null? fs)
          (if (null? rev-placements)
              (values #f 'request-query-empty-placements)
              (values #t (list 'request-query (reverse rev-placements) ign?)))]
         [else
          (define f (car fs))
          (define fn (raw-wire-field-num f))
          (define wt (raw-wire-field-wtype f))
          (define v (raw-wire-field-val f))
          (cond
            [(and (= fn 3) (= wt 2))
             (define-values (p-ok? p-dec) (verify-query-placement-item-bytes v))
             (if p-ok?
                 (loop (cdr fs) (cons p-dec rev-placements) has-ign? ign?)
                 (values #f p-dec))]
            [(and (= fn 4) (= wt 0) (not has-ign?) (or (= v 0) (= v 1)))
             (loop (cdr fs) rev-placements #t (= v 1))]
            [else
             (values #f 'request-query-unknown-or-bad-field)])]))]))

(define (verify-request-observation-bytes bs)
  (define-values (ok? fields) (parse-wire-bytes bs))
  (cond
    [(not ok?) (values #f fields)]
    [else
     (let loop ([fs fields]
                [has-fog? #f]
                [has-loop? #f])
       (cond
         [(null? fs)
          (values #t 'request-observation)]
         [else
          (define f (car fs))
          (define fn (raw-wire-field-num f))
          (define wt (raw-wire-field-wtype f))
          (define v (raw-wire-field-val f))
          (cond
            [(and (= fn 1) (= wt 0) (not has-fog?) (or (= v 0) (= v 1)))
             (loop (cdr fs) #t has-loop?)]
            [(and (= fn 2) (= wt 0) (not has-loop?) (<= 0 v VERIFIER-MAX-UINT32))
             (loop (cdr fs) has-fog? #t)]
            [else
             (values #f 'request-observation-unknown-or-bad-field)])]))]))

;; Shared verifier for messages consisting solely of unique boolean (0/1) varint flags.
(define (verify-bool-flag-fields bs max-field allowed-field? ok-sym err-sym)
  (define-values (ok? fields) (parse-wire-bytes bs))
  (cond
    [(not ok?) (values #f fields)]
    [else
     (define seen (make-vector (add1 max-field) #f))
     (let loop ([fs fields])
       (cond
         [(null? fs) (values #t ok-sym)]
         [else
          (define f (car fs))
          (define fn (raw-wire-field-num f))
          (define wt (raw-wire-field-wtype f))
          (define v (raw-wire-field-val f))
          (if (and (allowed-field? fn)
                   (= wt 0)
                   (not (vector-ref seen fn))
                   (or (= v 0) (= v 1)))
              (begin
                (vector-set! seen fn #t)
                (loop (cdr fs)))
              (values #f err-sym))]))]))

(define (verify-request-data-bytes bs)
  (verify-bool-flag-fields bs 5 (lambda (fn) (<= 1 fn 5))
                           'request-data 'request-data-unknown-or-bad-field))

(define (verify-interface-options-bytes bs)
  (verify-bool-flag-fields bs 9 (lambda (fn) (and (memv fn '(1 2 5 6 7 8 9)) #t))
                           'interface-options 'interface-options-unknown-or-bad-field))

(define (verify-port-set-bytes bs)
  (define-values (ok? fields) (parse-wire-bytes bs))
  (cond
    [(not ok?) (values #f fields)]
    [else
     (let loop ([fs fields]
                [has-gp? #f]
                [has-bp? #f])
       (cond
         [(null? fs)
          (if (and has-gp? has-bp?)
              (values #t 'port-set)
              (values #f 'port-set-missing-port))]
         [else
          (define f (car fs))
          (define fn (raw-wire-field-num f))
          (define wt (raw-wire-field-wtype f))
          (define v (raw-wire-field-val f))
          (cond
            [(and (= fn 1) (= wt 0) (not has-gp?) (<= 1 v 65535))
             (loop (cdr fs) #t has-bp?)]
            [(and (= fn 2) (= wt 0) (not has-bp?) (<= 1 v 65535))
             (loop (cdr fs) has-gp? #t)]
            [else
             (values #f 'port-set-unknown-or-bad-field)])]))]))

(define (verify-request-join-game-bytes bs)
  (define-values (ok? fields) (parse-wire-bytes bs))
  (cond
    [(not ok?) (values #f fields)]
    [else
     (let loop ([fs fields]
                [has-race? #f]
                [has-obs? #f]
                [has-opts? #f]
                [has-sp? #f]
                [has-shared? #f]
                [has-name? #f]
                [has-ip? #f])
       (cond
         [(null? fs)
          (cond
            [(not (not (eq? has-race? has-obs?)))
             (values #f 'join-game-participation-oneof-violation)]
            [(not has-opts?)
             (values #f 'join-game-missing-interface-options)]
            [else
             (values #t 'request-join-game)])]
         [else
          (define f (car fs))
          (define fn (raw-wire-field-num f))
          (define wt (raw-wire-field-wtype f))
          (define v (raw-wire-field-val f))
          (cond
            [(and (= fn 1) (= wt 0) (not has-race?) (<= 1 v 4))
             (loop (cdr fs) #t has-obs? has-opts? has-sp? has-shared? has-name? has-ip?)]
            [(and (= fn 2) (= wt 0) (not has-obs?) (<= 1 v VERIFIER-MAX-UINT32))
             (loop (cdr fs) has-race? #t has-opts? has-sp? has-shared? has-name? has-ip?)]
            [(and (= fn 3) (= wt 2) (not has-opts?))
             (define-values (io-ok? io-dec) (verify-interface-options-bytes v))
             (if io-ok?
                 (loop (cdr fs) has-race? has-obs? #t has-sp? has-shared? has-name? has-ip?)
                 (values #f io-dec))]
            [(and (= fn 4) (= wt 2) (not has-sp?))
             (define-values (ps-ok? ps-dec) (verify-port-set-bytes v))
             (if ps-ok?
                 (loop (cdr fs) has-race? has-obs? has-opts? #t has-shared? has-name? has-ip?)
                 (values #f ps-dec))]
            [(and (= fn 5) (= wt 2))
             (define-values (cp-ok? cp-dec) (verify-port-set-bytes v))
             (if cp-ok?
                 (loop (cdr fs) has-race? has-obs? has-opts? has-sp? has-shared? has-name? has-ip?)
                 (values #f cp-dec))]
            [(and (= fn 6) (= wt 0) (not has-shared?) (<= 1 v 65535))
             (loop (cdr fs) has-race? has-obs? has-opts? has-sp? #t has-name? has-ip?)]
            [(and (= fn 7) (= wt 2) (not has-name?) (valid-utf8-slice? v 1 256))
             (loop (cdr fs) has-race? has-obs? has-opts? has-sp? has-shared? #t has-ip?)]
            [(and (= fn 8) (= wt 2) (not has-ip?) (valid-utf8-slice? v 1 256))
             (loop (cdr fs) has-race? has-obs? has-opts? has-sp? has-shared? has-name? #t)]
            [else
             (values #f 'join-game-unknown-or-bad-field)])]))]))

(define (verify-local-map-bytes bs)
  (define-values (ok? fields) (parse-wire-bytes bs))
  (cond
    [(not ok?) (values #f fields)]
    [else
     (let loop ([fs fields]
                [has-path? #f]
                [has-data? #f])
       (cond
         [(null? fs)
          (if (or has-path? has-data?)
              (values #t 'local-map)
              (values #f 'local-map-empty))]
         [else
          (define f (car fs))
          (define fn (raw-wire-field-num f))
          (define wt (raw-wire-field-wtype f))
          (define v (raw-wire-field-val f))
          (cond
            [(and (= fn 1) (= wt 2) (not has-path?) (valid-utf8-slice? v 1 260))
             (loop (cdr fs) #t has-data?)]
            [(and (= fn 7) (= wt 2) (not has-data?))
             (loop (cdr fs) has-path? #t)]
            [else
             (values #f 'local-map-unknown-or-bad-field)])]))]))

(define (verify-player-setup-bytes bs)
  (define-values (ok? fields) (parse-wire-bytes bs))
  (cond
    [(not ok?) (values #f fields)]
    [else
     (let loop ([fs fields]
                [has-type? #f]
                [has-race? #f]
                [has-diff? #f]
                [has-name? #f]
                [has-build? #f])
       (cond
         [(null? fs)
          (if has-type?
              (values #t 'player-setup)
              (values #f 'player-setup-missing-type))]
         [else
          (define f (car fs))
          (define fn (raw-wire-field-num f))
          (define wt (raw-wire-field-wtype f))
          (define v (raw-wire-field-val f))
          (cond
            [(and (= fn 1) (= wt 0) (not has-type?) (<= 1 v 3))
             (loop (cdr fs) #t has-race? has-diff? has-name? has-build?)]
            [(and (= fn 2) (= wt 0) (not has-race?) (<= 0 v 4))
             (loop (cdr fs) has-type? #t has-diff? has-name? has-build?)]
            [(and (= fn 3) (= wt 0) (not has-diff?) (<= 1 v 10))
             (loop (cdr fs) has-type? has-race? #t has-name? has-build?)]
            [(and (= fn 4) (= wt 2) (not has-name?) (valid-utf8-slice? v 1 256))
             (loop (cdr fs) has-type? has-race? has-diff? #t has-build?)]
            [(and (= fn 5) (= wt 0) (not has-build?) (<= 1 v 6))
             (loop (cdr fs) has-type? has-race? has-diff? has-name? #t)]
            [else
             (values #f 'player-setup-unknown-or-bad-field)])]))]))

(define (verify-request-create-game-bytes bs)
  (define-values (ok? fields) (parse-wire-bytes bs))
  (cond
    [(not ok?) (values #f fields)]
    [else
     (let loop ([fs fields]
                [has-local? #f]
                [has-bnet? #f]
                [setup-count 0]
                [has-fog? #f]
                [has-seed? #f]
                [has-rt? #f])
       (cond
         [(null? fs)
          (cond
            [(not (not (eq? has-local? has-bnet?)))
             (values #f 'create-game-map-oneof-violation)]
            [(< setup-count 1)
             (values #f 'create-game-missing-player-setup)]
            [else
             (values #t 'request-create-game)])]
         [else
          (define f (car fs))
          (define fn (raw-wire-field-num f))
          (define wt (raw-wire-field-wtype f))
          (define v (raw-wire-field-val f))
          (cond
            [(and (= fn 1) (= wt 2) (not has-local?))
             (define-values (lm-ok? lm-dec) (verify-local-map-bytes v))
             (if lm-ok?
                 (loop (cdr fs) #t has-bnet? setup-count has-fog? has-seed? has-rt?)
                 (values #f lm-dec))]
            [(and (= fn 2) (= wt 2) (not has-bnet?) (valid-utf8-slice? v 1 260))
             (loop (cdr fs) has-local? #t setup-count has-fog? has-seed? has-rt?)]
            [(and (= fn 3) (= wt 2))
             (define-values (ps-ok? ps-dec) (verify-player-setup-bytes v))
             (if ps-ok?
                 (loop (cdr fs) has-local? has-bnet? (add1 setup-count) has-fog? has-seed? has-rt?)
                 (values #f ps-dec))]
            [(and (= fn 4) (= wt 0) (not has-fog?) (or (= v 0) (= v 1)))
             (loop (cdr fs) has-local? has-bnet? setup-count #t has-seed? has-rt?)]
            [(and (= fn 5) (= wt 0) (not has-seed?) (<= 0 v VERIFIER-MAX-UINT32))
             (loop (cdr fs) has-local? has-bnet? setup-count has-fog? #t has-rt?)]
            [(and (= fn 6) (= wt 0) (not has-rt?) (or (= v 0) (= v 1)))
             (loop (cdr fs) has-local? has-bnet? setup-count has-fog? has-seed? #t)]
            [else
             (values #f 'create-game-unknown-or-bad-field)])]))]))

(define (verify-sc2-request-bytes bs)
  (cond
    [(or (not (bytes? bs)) (zero? (bytes-length bs)))
     (values #f 'request-empty-or-not-bytes)]
    [else
     (define-values (ok? fields) (parse-wire-bytes bs))
     (cond
       [(not ok?) (values #f fields)]
       [else
        (let loop ([fs fields]
                   [req-fnum #f]
                   [req-sub #""]
                   [has-id? #f]
                   [req-id #f])
          (cond
            [(null? fs)
             (cond
               [(not req-fnum)
                (values #f 'request-missing-oneof-payload)]
               [else
                (define-values (sub-ok? sub-dec)
                  (case req-fnum
                    [(1)  (verify-request-create-game-bytes req-sub)]
                    [(2)  (verify-request-join-game-bytes req-sub)]
                    [(5)  (verify-empty-submsg req-sub 'request-leave-game-nonempty)]
                    [(8)  (verify-empty-submsg req-sub 'request-quit-nonempty)]
                    [(9)  (verify-empty-submsg req-sub 'request-game-info-nonempty)]
                    [(10) (verify-request-observation-bytes req-sub)]
                    [(11) (verify-request-action-bytes req-sub)]
                    [(12) (verify-request-step-bytes req-sub)]
                    [(13) (verify-request-data-bytes req-sub)]
                    [(14) (verify-request-query-bytes req-sub)]
                    [(15) (verify-empty-submsg req-sub 'request-save-replay-nonempty)]
                    [(19) (verify-empty-submsg req-sub 'request-ping-nonempty)]
                    [else (values #f 'request-unsupported-oneof-field)]))
                (if sub-ok?
                    (values #t (list 'request req-fnum req-id sub-dec))
                    (values #f sub-dec))])]
            [else
             (define f (car fs))
             (define fn (raw-wire-field-num f))
             (define wt (raw-wire-field-wtype f))
             (define v (raw-wire-field-val f))
             (cond
               [(= fn 97)
                (if (or (not (= wt 0)) has-id? (> v VERIFIER-MAX-UINT32))
                    (values #f 'request-invalid-or-duplicate-id)
                    (loop (cdr fs) req-fnum req-sub #t v))]
               [(memv fn '(1 2 5 8 9 10 11 12 13 14 15 19))
                (cond
                  [(not (= wt 2))
                   (values #f 'request-oneof-bad-wire-type)]
                  [req-fnum
                   (values #f 'request-multiple-oneof-fields)]
                  [else
                   (loop (cdr fs) fn v has-id? req-id)])]
               [else
                (values #f 'request-unknown-field)])]))])]))
