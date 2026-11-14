#lang racket/base

;; =============================================================================
;; Pure-Racket Pro & AI Arena Replay Tactical Catalog Miner
;; (`tools/mine-pro-replay-tactics.rkt`)
;;
;; Self-contained, zero-Python replay miner built on `lib/sc2-mpq-replay-parser.rkt`
;; plus a pure-Racket Blizzard bit-packed `replay.game.events` + `replay.attributes.events`
;; decoder. Scans `replays/pro_corpus/*.SC2Replay` and `replays/aiarena_matches/*.SC2Replay`
;; and writes `data/pro_tactical_catalog_examples.json` covering:
;;   - All 15 tactical & counter-tactical families
;;   - Wave 1.5 tactical extensions (Dropperlord+Queen creep expeditions, Burrowed
;;     Zergling pad blocks, Overseer Contaminate/Oversight/Changeling, Widow Mine
;;     drop + 2099 retarget + single-unit bait)
;;   - 3 pro-replay-supported tactical modes per spellcaster ability group
;;   - Minute-by-minute (1..8, 10) pro unit composition benchmarks across all 9 matchups
;;
;; CLI:
;;   racket tools/mine-pro-replay-tactics.rkt           ; mine + write JSON + print summary
;;   racket tools/mine-pro-replay-tactics.rkt --summary ; print summary from JSON (mine if absent)
;;   racket tools/mine-pro-replay-tactics.rkt --verify  ; validate JSON schema & all 15 families
;; =============================================================================

(require json
         racket/cmdline
         racket/file
         racket/format
         racket/list
         racket/math
         racket/path
         racket/runtime-path
         racket/set
         racket/string
         "../lib/sc2-mpq-replay-parser.rkt")

(provide mine-all-replay-tactics!
         verify-tactical-catalog-json
         print-tactical-catalog-summary
         REQUIRED-15-FAMILIES
         WAVE18-EXTENDED-SECTIONS)

(define-runtime-path PRO-CORPUS-DIR "../replays/pro_corpus")
(define-runtime-path AIARENA-CORPUS-DIR "../replays/aiarena_matches")
(define-runtime-path OUTPUT-JSON-PATH "../data/pro_tactical_catalog_examples.json")

(define REQUIRED-15-FAMILIES
  '("random-main-walling"
    "unwalled-opponent-punish"
    "creep-spread-and-clearing"
    "changeling-and-counter"
    "multi-angle-drops-and-widow-mine-runby"
    "burrow-dodge-and-ring-ambush"
    "multi-base-adept-harass"
    "coordinated-runbys"
    "off-path-proxy-all-ins"
    "expansion-and-gas-blocks"
    "raven-harass"
    "oracle-harass"
    "multi-base-viking-landings"
    "splitting-and-baneling-target-fire"
    "unit-mode-and-spell-counters"))

(define WAVE18-EXTENDED-SECTIONS
  '("spread_burrowed_swarm_host_harass"
    "cannon_rush_walls_cancels_probe_push"
    "bunker_load_repair_salvage"
    "planetary_fortress_mass_repair"
    "missile_turret_defense"
    "nydus_worm_network_assault"
    "shield_battery_nexus_overcharge"
    "crawler_uproot_reposition"
    "pro_simcity_layout_stats"
    "game_start_worker_split_and_stacking"))

(define ALL-9-MATCHUPS
  '("ZvZ" "ZvT" "ZvP" "TvZ" "TvT" "TvP" "PvZ" "PvT" "PvP"))

(define BENCHMARK-MINUTES '(1 2 3 4 5 6 7 8 10))

;; -----------------------------------------------------------------------------
;; 1. Statistical & Geometric Helpers
;; -----------------------------------------------------------------------------

(define (round1 x)
  (/ (round (* 10.0 (exact->inexact x))) 10.0))

(define (round2 x)
  (/ (round (* 100.0 (exact->inexact x))) 100.0))

(define (dist2d x1 y1 x2 y2)
  (define dx (- (exact->inexact x1) (exact->inexact x2)))
  (define dy (- (exact->inexact y1) (exact->inexact y2)))
  (sqrt (+ (* dx dx) (* dy dy))))

;; Perpendicular distance of point (px, py) from line through (ax, ay) <-> (bx, by)
(define (perp-dist-to-axis px py ax ay bx by)
  (define vx (- (exact->inexact bx) (exact->inexact ax)))
  (define vy (- (exact->inexact by) (exact->inexact ay)))
  (define len (sqrt (+ (* vx vx) (* vy vy))))
  (if (< len 1e-6)
      (dist2d px py ax ay)
      (/ (abs (- (* vx (- (exact->inexact py) (exact->inexact ay)))
                 (* vy (- (exact->inexact px) (exact->inexact ax)))))
         len)))

(define (pct sorted-vec p)
  (define n (vector-length sorted-vec))
  (cond
    [(= n 0) 0.0]
    [(= n 1) (exact->inexact (vector-ref sorted-vec 0))]
    [else
     (define idx (* (/ p 100.0) (sub1 n)))
     (define lo (inexact->exact (floor idx)))
     (define hi (inexact->exact (ceiling idx)))
     (if (= lo hi)
         (exact->inexact (vector-ref sorted-vec lo))
         (+ (* (- 1.0 (- idx lo)) (vector-ref sorted-vec lo))
            (* (- idx lo) (vector-ref sorted-vec hi))))]))

(define (stats-hash nums [as-clock? #f])
  (if (null? nums)
      (hasheq 'count 0 'min 0 'p25 0 'median 0 'p75 0 'max 0 'mean 0)
      (let* ([sv (list->vector (sort nums <))]
             [n (vector-length sv)]
             [mn (round1 (vector-ref sv 0))]
             [p25 (round1 (pct sv 25))]
             [med (round1 (pct sv 50))]
             [p75 (round1 (pct sv 75))]
             [mx (round1 (vector-ref sv (sub1 n)))]
             [avg (round1 (/ (apply + nums) (exact->inexact n)))])
        (if as-clock?
            (hasheq 'count n
                    'min mn 'p25 p25 'median med 'p75 p75 'max mx 'mean avg
                    'clock_p25 (gl->mmss p25)
                    'clock_median (gl->mmss med)
                    'clock_p75 (gl->mmss p75))
            (hasheq 'count n
                    'min mn 'p25 p25 'median med 'p75 p75 'max mx 'mean avg)))))

(define (gl->mmss gl)
  (define sec (max 0 (inexact->exact (round (/ gl 22.4)))))
  (format "~a:~a"
          (quotient sec 60)
          (~r (remainder sec 60) #:min-width 2 #:pad-string "0")))

;; -----------------------------------------------------------------------------
;; 2. Fast Header BaseBuild & `replay.attributes.events` Random Race Reader
;; -----------------------------------------------------------------------------

(define (read-replay-base-build path)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (call-with-input-file path
      (lambda (in)
        (define hdr (read-bytes 1024 in))
        (cond
          [(or (eof-object? hdr) (< (bytes-length hdr) 32)) #f]
          [(not (bytes=? (subbytes hdr 0 4) #"MPQ\x1b")) #f]
          [else
           (define-values (dec _next) (decode-versioned hdr 16))
           (define ver (and (hash? dec) (hash-ref dec 1 #f)))
           (and (hash? ver) (hash-ref ver 5 #f))])))))

;; Parses `replay.attributes.events` (5-byte header, u32 count, 13-byte records)
;; Returns hash: scope-slot (1-based) -> #t when attr_id 3001 == "RAND" (#"DNAR" LE FourCC)
(define (parse-random-slots attr-bytes)
  (define rand-slots (make-hasheqv))
  (when (and (bytes? attr-bytes) (>= (bytes-length attr-bytes) 9))
    (define cnt (integer-bytes->integer attr-bytes #f #f 5 9))
    (for ([i (in-range (min 512 cnt))]
          #:when (<= (+ 9 (* (add1 i) 13)) (bytes-length attr-bytes)))
      (define off (+ 9 (* i 13)))
      (define aid (integer-bytes->integer attr-bytes #f #f (+ off 4) (+ off 8)))
      (define scope (bytes-ref attr-bytes (+ off 8)))
      (define val (subbytes attr-bytes (+ off 9) (+ off 13)))
      (when (and (= aid 3001)
                 (or (bytes=? val #"DNAR") (bytes=? val #"RAND")
                     (bytes=? val #"dnar") (bytes=? val #"rand")))
        (hash-set! rand-slots scope #t))))
  rand-slots)

(define (random-player-name? pname)
  (define s (string-downcase pname))
  (or (string-prefix? s "mothman-r")
      (string-prefix? s "mothman-x")
      (string-contains? s "random")
      (string=? s "carcara")
      (string=? s "who")))

;; -----------------------------------------------------------------------------
;; 3. Bit-Packed `replay.game.events` Decoder (LotV Builds 38215..98310+)
;; -----------------------------------------------------------------------------

(struct bit-reader (buf len [byte-idx #:mutable] [bit-idx #:mutable]) #:transparent)

(define (br-eof? br)
  (>= (bit-reader-byte-idx br) (bit-reader-len br)))

(define (br-align! br)
  (when (> (bit-reader-bit-idx br) 0)
    (set-bit-reader-byte-idx! br (add1 (bit-reader-byte-idx br)))
    (set-bit-reader-bit-idx! br 0)))

(define (br-read-bits! br total-bits)
  (let loop ([rem total-bits] [acc 0])
    (if (<= rem 0)
        acc
        (let ([b-idx (bit-reader-byte-idx br)]
              [bit-off (bit-reader-bit-idx br)])
          (when (>= b-idx (bit-reader-len br))
            (error 'br-read-bits! "EOF at byte ~a" b-idx))
          (define avail (- 8 bit-off))
          (define chunk (min rem avail))
          (define byte-val (bytes-ref (bit-reader-buf br) b-idx))
          (define mask (sub1 (arithmetic-shift 1 chunk)))
          (define bits (bitwise-and (arithmetic-shift byte-val (- bit-off)) mask))
          (define next-bit (+ bit-off chunk))
          (if (= next-bit 8)
              (begin
                (set-bit-reader-byte-idx! br (add1 b-idx))
                (set-bit-reader-bit-idx! br 0))
              (set-bit-reader-bit-idx! br next-bit))
          (loop (- rem chunk) (bitwise-ior (arithmetic-shift acc chunk) bits))))))

(define (br-read-bool! br) (= (br-read-bits! br 1) 1))
(define (br-skip-bits! br n) (void (br-read-bits! br n)))

(define (br-skip-string! br len-bits)
  (define n (br-read-bits! br len-bits))
  (br-align! br)
  (define next (+ (bit-reader-byte-idx br) n))
  (when (> next (bit-reader-len br))
    (error 'br-skip-string! "EOF skipping string"))
  (set-bit-reader-byte-idx! br next))

(define (br-skip-blob! br n-bytes)
  (br-align! br)
  (define next (+ (bit-reader-byte-idx br) n-bytes))
  (when (> next (bit-reader-len br))
    (error 'br-skip-blob! "EOF skipping blob"))
  (set-bit-reader-byte-idx! br next))

(define (br-read-svaruint32! br)
  (case (br-read-bits! br 2)
    [(0) (br-read-bits! br 6)]
    [(1) (br-read-bits! br 14)]
    [(2) (br-read-bits! br 22)]
    [(3) (br-read-bits! br 32)]))

(define (read-selection-mask! br)
  (case (br-read-bits! br 2)
    [(0) '(none)]
    [(1)
     (define n (br-read-bits! br 9))
     (list 'mask n (br-read-bits! br n))]
    [(2)
     (define n (br-read-bits! br 9))
     (list 'one (for/list ([_ (in-range n)]) (br-read-bits! br 9)))]
    [(3)
     (define n (br-read-bits! br 9))
     (list 'zero (for/list ([_ (in-range n)]) (br-read-bits! br 9)))]))

(define (apply-remove-mask current mask-spec)
  (case (car mask-spec)
    [(none) current]
    [(mask)
     (define mask-int (caddr mask-spec))
     (for/list ([u (in-list current)]
                [idx (in-naturals)]
                #:when (not (bitwise-bit-set? mask-int idx)))
       u)]
    [(one)
     (define drop-idxs (cadr mask-spec))
     (for/list ([u (in-list current)]
                [idx (in-naturals)]
                #:when (not (member idx drop-idxs)))
       u)]
    [(zero)
     (define keep-idxs (cadr mask-spec))
     (define vec (list->vector current))
     (define vlen (vector-length vec))
     (for/list ([idx (in-list keep-idxs)] #:when (< idx vlen))
       (vector-ref vec idx))]))

(define (merge-selection kept added)
  (remove-duplicates (sort (append kept added) <) =))

(define (parse-game-events-with-spec raw-bytes cmd-flags-bits has-unit-group?)
  (define br (bit-reader raw-bytes (bytes-length raw-bytes) 0 0))
  (define user-cgs (make-hasheqv))
  (define (get-cgs uid)
    (hash-ref! user-cgs uid (lambda () (make-vector 11 '()))))
  (let loop ([gl 0] [cmds '()])
    (if (br-eof? br)
        (reverse cmds)
        (let* ([delta (br-read-svaruint32! br)]
               [uid (br-read-bits! br 5)]
               [ev-id (br-read-bits! br 7)]
               [gl* (+ gl delta)])
          (define maybe-cmd
            (case ev-id
              [(0)
               (br-skip-bits! br 4)
               (case (br-read-bits! br 5)
                 [(0 6) (br-skip-bits! br 8)]
                 [(1 14 18) (when (br-read-bool! br) (br-skip-bits! br 4))]
                 [(2) (br-skip-bits! br 4)]
                 [(3) (when (br-read-bool! br) (br-skip-bits! br 5))]
                 [(4) (when (br-read-bool! br) (br-skip-bits! br 8))]
                 [(5) (br-skip-bits! br 6)]
                 [(7 9 16 19 20 22 23 24) (br-skip-bits! br 32)]
                 [(8) (br-skip-bits! br 2)]
                 [(10 11 12 15) (br-skip-string! br 9)]
                 [(13) (br-skip-bits! br (* (br-read-bits! br 16) 32))]
                 [(17) (br-skip-bits! br 1)]
                 [(21) (br-skip-bits! br (* (br-read-bits! br 3) 32))]
                 [else (error 'parse-game-events "Bad lobby slot tag")])
               #f]
              [(1 15 16 19 35 114) (br-skip-bits! br 8) #f]
              [(2 3 4 5 8 17 22 23 44 50 52 54 63 68 69 73 74 77 78 80 81 86 87 96 111) #f]
              [(6 25 39 46 48 51 64 65 71 72 75 79 83 84 85 88 89 90 91 93 94 98 110 116 117 118 119)
               (br-skip-bits! br 32) #f]
              [(7) (br-skip-bits! br 106) (br-skip-string! br 9) #f]
              [(9 67) (br-skip-string! br 7) #f]
              [(10) (br-skip-string! br 6) #f]
              [(11) (br-skip-string! br 6) (br-skip-bits! br 32) (br-skip-string! br 7) #f]
              [(12) (br-skip-bits! br 32) (br-skip-string! br 6) (br-skip-string! br 12) #f]
              [(13) (br-skip-bits! br (* (br-read-bits! br 5) 8)) (br-skip-string! br 7) #f]
              [(14) (br-skip-bits! br 35) #f]
              [(18 34) (br-skip-bits! br 3) #f]
              [(20 115) (when (br-read-bool! br) (br-skip-bits! br 32)) #f]
              [(21) (br-skip-string! br 11) (br-skip-bits! br 2) (br-skip-string! br 8) (br-skip-string! br 10) #f]
              [(24 26) (br-skip-bits! br 96) (br-skip-string! br 10) (br-skip-string! br 10) #f]
              [(27) ; ECmd
               (define cmd-flags (br-read-bits! br cmd-flags-bits))
               (define has-abil? (br-read-bool! br))
               (define abil-link (and has-abil? (br-read-bits! br 16)))
               (define abil-cmd-idx (and has-abil? (br-read-bits! br 5)))
               (define _abil-cmd-data (and has-abil? (and (br-read-bool! br) (br-read-bits! br 8))))
               (define cmd-data
                 (case (br-read-bits! br 2)
                   [(0) '(none)]
                   [(1)
                    (define rx (br-read-bits! br 20))
                    (define ry (br-read-bits! br 20))
                    (define _rz (br-read-bits! br 32))
                    (list 'point (/ rx 4096.0) (/ ry 4096.0))]
                   [(2)
                    (br-skip-bits! br 24)
                    (define ttag (br-read-bits! br 32))
                    (define tulink (br-read-bits! br 16))
                    (when (br-read-bool! br) (br-skip-bits! br 4))
                    (when (br-read-bool! br) (br-skip-bits! br 4))
                    (define rx (br-read-bits! br 20))
                    (define ry (br-read-bits! br 20))
                    (br-skip-bits! br 32)
                    (list 'unit ttag tulink (/ rx 4096.0) (/ ry 4096.0))]
                   [(3)
                    (list 'data (br-read-bits! br 32))]))
               (br-skip-bits! br 32) ; seq
               (when (br-read-bool! br) (br-skip-bits! br 32)) ; other_unit
               (when (and has-unit-group? (br-read-bool! br)) (br-skip-bits! br 32))
               (vector gl* uid cmd-flags abil-link abil-cmd-idx cmd-data (vector-ref (get-cgs uid) 10))]
              [(28) ; ESelectionDelta
               (define cg-id (br-read-bits! br 4))
               (br-skip-bits! br 9)
               (define mask-spec (read-selection-mask! br))
               (br-skip-bits! br (* (br-read-bits! br 9) 41))
               (define n-tags (br-read-bits! br 9))
               (define add-tags (for/list ([_ (in-range n-tags)]) (br-read-bits! br 32)))
               (when (<= cg-id 10)
                 (define cgs (get-cgs uid))
                 (vector-set! cgs cg-id (merge-selection (apply-remove-mask (vector-ref cgs cg-id) mask-spec) add-tags)))
               #f]
              [(29) ; EControlGroupUpdate
               (define cg-idx (br-read-bits! br 4))
               (define upd-op (br-read-bits! br 3))
               (define mask-spec (read-selection-mask! br))
               (when (< cg-idx 10)
                 (define cgs (get-cgs uid))
                 (define active (vector-ref cgs 10))
                 (case upd-op
                   [(0) (vector-set! cgs cg-idx active)]
                   [(1) (vector-set! cgs cg-idx (merge-selection (apply-remove-mask (vector-ref cgs cg-idx) mask-spec) active))]
                   [(2)
                    (define g (apply-remove-mask (vector-ref cgs cg-idx) mask-spec))
                    (vector-set! cgs cg-idx g)
                    (vector-set! cgs 10 g)]
                   [(3) (vector-set! cgs cg-idx '())]
                   [(4)
                    (for ([i (in-range 10)])
                      (vector-set! cgs i (filter (lambda (x) (not (member x active))) (vector-ref cgs i))))
                    (vector-set! cgs cg-idx active)]
                   [(5)
                    (for ([i (in-range 10)])
                      (vector-set! cgs i (filter (lambda (x) (not (member x active))) (vector-ref cgs i))))
                    (vector-set! cgs cg-idx (merge-selection (apply-remove-mask (vector-ref cgs cg-idx) mask-spec) active))]))
               #f]
              [(30) (br-skip-bits! br 123) #f]
              [(31) (br-skip-bits! br 4) (br-skip-bits! br (* (br-read-bits! br 3) 32)) #f]
              [(32) (br-skip-string! br 10) #f]
              [(33) (br-skip-bits! br 192) #f]
              [(36)
               (br-skip-bits! br 112)
               (when (br-read-bool! br) (br-skip-bits! br 4))
               (when (br-read-bool! br) (br-skip-bits! br 4))
               (br-skip-bits! br 106)
               #f]
              [(37) (br-skip-string! br 10) (br-skip-string! br 10) #f]
              [(38 41 45 47 53 82 107) (br-skip-bits! br 64) #f]
              [(40) (br-skip-bits! br 40) #f]
              [(42) (br-skip-bits! br (+ (* (br-read-bits! br 5) 9) 1)) #f]
              [(43)
               (for ([_ (in-range (br-read-bits! br 5))])
                 (br-skip-bits! br 6)
                 (br-skip-string! br 8)
                 (when (br-read-bool! br) (br-skip-string! br 7))
                 (when (br-read-bool! br) (br-skip-string! br 8))
                 (when (br-read-bool! br) (br-skip-blob! br 40)))
               (br-skip-bits! br 1)
               #f]
              [(49)
               (when (br-read-bool! br) (br-skip-bits! br 32))
               (when (br-read-bool! br) (br-skip-bits! br 16))
               (when (br-read-bool! br) (br-skip-bits! br 16))
               (when (br-read-bool! br) (br-skip-bits! br 16))
               (when (br-read-bool! br) (br-skip-bits! br 8))
               (br-skip-bits! br 1)
               #f]
              [(55)
               (br-skip-bits! br 64)
               (case (br-read-bits! br 3)
                 [(0) (void)]
                 [(1) (br-skip-bits! br 1)]
                 [(2 3 5) (br-skip-bits! br 32)]
                 [(4) (br-skip-string! br 11)]
                 [else (error 'parse-game-events "Bad dialog")])
               #f]
              [(56)
               (br-skip-bits! br (* (br-read-bits! br 7) 32))
               (br-skip-bits! br (* (br-read-bits! br 7) 32))
               #f]
              [(57 112) (br-skip-bits! br 1) #f]
              [(58) (br-skip-bits! br 135) #f]
              [(59) (br-skip-bits! br 102) #f]
              [(60 66 95 108) (br-skip-bits! br 16) #f]
              [(61) (br-skip-bits! br 33) #f]
              [(62) (br-skip-bits! br 29) #f]
              [(70) (br-skip-bits! br (* (br-read-bits! br 3) 32)) #f]
              [(76)
               (br-skip-bits! br 32)
               (when (br-read-bool! br)
                 (br-skip-bits! br 21)
                 (when (br-read-bool! br) (br-skip-bits! br 8)))
               #f]
              [(92) (br-skip-bits! br 24) #f]
              [(97 100) (br-skip-bits! br 32) (br-skip-string! br 7) #f]
              [(99) (br-skip-bits! br 32) (br-skip-string! br 7) (br-skip-string! br 7) #f]
              [(101) (br-skip-bits! br 4) #f]
              [(102)
               (br-skip-bits! br 2)
               (br-skip-string! br 8)
               (when (br-read-bool! br) (br-skip-string! br 7))
               (when (br-read-bool! br) (br-skip-string! br 8))
               (when (br-read-bool! br) (br-skip-blob! br 40))
               (br-skip-bits! br 1)
               (when (br-read-bool! br) (br-skip-bits! br 4))
               #f]
              [(103) (br-skip-bits! br 2) (when (br-read-bool! br) (br-skip-bits! br 32)) #f]
              [(104) (br-skip-bits! br 72) #f]
              [(105)
               (br-skip-bits! br 72)
               (when (br-read-bool! br) (br-skip-bits! br 4))
               (when (br-read-bool! br) (br-skip-bits! br 4))
               (br-skip-bits! br 72)
               #f]
              [(106) (br-skip-bits! br 80) #f]
              [(109) (br-skip-bits! br 24) (br-skip-string! br 8) (br-skip-string! br 8) #f]
              [(113) (br-skip-bits! br 5) #f]
              [else (error 'parse-game-events "Unsupported event ~a" ev-id)]))
          (br-align! br)
          (loop gl* (if maybe-cmd (cons maybe-cmd cmds) cmds))))))

(define (decode-game-events-for-build raw-bytes base-build max-expected-gl)
  (define specs
    (cond
      [(>= base-build 80949) '((27 #t) (26 #t))]
      [(>= base-build 74071) '((26 #t) (27 #t) (25 #t))]
      [(>= base-build 60321) '((25 #t) (26 #t) (25 #f) (24 #f) (23 #f))]
      [else '((25 #f) (24 #f) (23 #f) (22 #f) (26 #t))]))
  (for/or ([sp (in-list specs)])
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (define cmds (parse-game-events-with-spec raw-bytes (car sp) (cadr sp)))
      (define last-gl (if (null? cmds) 0 (vector-ref (last cmds) 0)))
      (and (<= last-gl (+ max-expected-gl 224)) cmds))))

;; -----------------------------------------------------------------------------
;; 4. Self-Contained LotV Ability Classifier (Zero External Files)
;; -----------------------------------------------------------------------------

(define (norm-link bb raw-al)
  (cond
    [(not raw-al) #f]
    [(and (>= bb 80949) (<= bb 92440) (>= raw-al 699)) (add1 raw-al)]
    [else raw-al]))

(define (classify-cmd bb raw-al ac dk sel-types owned-map tgt-type tgt-ally?)
  (define al (norm-link bb raw-al))
  (define (has-sel-or-owned? ulist)
    (if (null? sel-types)
        (ormap (lambda (u) (hash-ref owned-map u #f)) ulist)
        (ormap (lambda (u) (member u sel-types)) ulist)))
  (define (has-sel? ulist)
    (and (pair? sel-types)
         (ormap (lambda (u) (member u sel-types)) ulist)))
  (cond
    ;; Smart right-click load into allied transport / Bunker / Nydus, or SCV repair, or worker return
    [(and (not al) (eq? dk 'unit) tgt-ally? tgt-type)
     (cond
       [(and (string=? tgt-type "Medivac")
             (pair? sel-types)
             (ormap (lambda (s) (not (string=? s "Medivac"))) sel-types))
        'medivac-load-smart]
       [(and (member tgt-type '("WarpPrism" "WarpPrismPhasing"))
             (pair? sel-types)
             (ormap (lambda (s) (not (member s '("WarpPrism" "WarpPrismPhasing")))) sel-types))
        'prism-load-smart]
       [(and (string=? tgt-type "OverlordTransport")
             (pair? sel-types)
             (ormap (lambda (s) (not (string=? s "OverlordTransport"))) sel-types))
        'ov-load-smart]
       [(and (string=? tgt-type "Bunker")
             (has-sel-or-owned? '("Marine" "Marauder" "Reaper" "Ghost")))
        'bunker-load]
       [(and (member tgt-type '("Bunker" "PlanetaryFortress" "MissileTurret"))
             (has-sel-or-owned? '("SCV")))
        'scv-repair]
       [(and (member tgt-type '("NydusNetwork" "NydusCanal" "NydusWorm"))
             (or (null? sel-types)
                 (ormap (lambda (s) (not (member s '("NydusNetwork" "NydusCanal" "NydusWorm")))) sel-types)))
        'nydus-load]
       [(and (member tgt-type '("Hatchery" "Lair" "Hive" "CommandCenter" "OrbitalCommand" "PlanetaryFortress" "Nexus"))
             (has-sel-or-owned? '("Drone" "SCV" "Probe")))
        'worker-return]
       [else #f])]
    ;; Smart right-click gather on neutral mineral patch
    [(and (not al) (eq? dk 'unit) (not tgt-ally?) tgt-type
          (string-contains? tgt-type "Mineral")
          (has-sel-or-owned? '("Drone" "SCV" "Probe")))
     'worker-gather]
    [(and (not al) (eq? dk 'unit) (not tgt-ally?) (has-sel? '("WidowMineBurrowed" "WidowMine")))
     'widow-mine-retarget]
    [(and (not al) (eq? dk 'unit) (not tgt-ally?) (equal? tgt-type "Baneling"))
     'target-fire-baneling]
    [(and (not al) (eq? dk 'unit) (not tgt-ally?) (and tgt-type (string-prefix? tgt-type "Changeling")))
     'snipe-changeling-cmd]
    [(not al) #f]
    ;; Worker Harvest Gather / Return (SCV 119/121, Probe 120/122, Drone 184/186)
    [(and (memv al '(119 120 121 122 184 186)) (has-sel-or-owned? '("SCV" "Probe" "Drone")))
     (cond
       [(= ac 0) 'worker-gather]
       [(= ac 1) 'worker-return]
       [else #f])]
    ;; SCV Repair (128/130) & Bunker Load/Unload/Salvage (143/145, 731/733)
    [(and (memv al '(128 130)) (= ac 0) (eq? dk 'unit) (has-sel-or-owned? '("SCV")))
     'scv-repair]
    [(and (memv al '(143 145)) (has-sel-or-owned? '("Bunker")))
     (case ac
       [(0 4) 'bunker-load]
       [(1 2 3) 'bunker-unload]
       [else #f])]
    [(and (memv al '(731 732 733)) (= ac 0) (has-sel-or-owned? '("Bunker")))
     'bunker-salvage]
    ;; Nydus Network / Worm Load & Unload (217/219, 537/539)
    [(and (memv al '(217 219 537 539)) (has-sel-or-owned? '("NydusNetwork" "NydusCanal" "NydusWorm")))
     (case ac
       [(0 4) 'nydus-load]
       [(1 2 3) 'nydus-unload]
       [else #f])]
    ;; Spine / Spore Crawler Uproot & Root (261..266)
    [(and (memv al '(261 263)) (= ac 0) (has-sel-or-owned? '("SpineCrawler"))) 'spine-uproot]
    [(and (memv al '(263 265)) (= ac 0) (has-sel-or-owned? '("SpineCrawlerUprooted" "SpineCrawler"))) 'spine-root]
    [(and (memv al '(262 264)) (= ac 0) (has-sel-or-owned? '("SporeCrawler"))) 'spore-uproot]
    [(and (memv al '(264 266)) (= ac 0) (has-sel-or-owned? '("SporeCrawlerUprooted" "SporeCrawler"))) 'spore-root]
    ;; Swarm Host Burrow / Unburrow (375..378) & Locust Swoop (544/546)
    [(and (memv al '(375 377)) (= ac 0) (has-sel-or-owned? '("SwarmHostMP"))) 'swarmhost-burrow]
    [(and (memv al '(376 378)) (= ac 0) (has-sel-or-owned? '("SwarmHostBurrowedMP" "SwarmHostMP"))) 'swarmhost-unburrow]
    [(and (memv al '(544 546)) (= ac 0) (eq? dk 'point)) 'locust-swoop]
    ;; Shield Battery Restore (700..702) & Nexus Battery Overcharge (729/731 on ShieldBattery)
    [(and (memv al '(700 701 702)) (= ac 0) (eq? dk 'unit) (has-sel-or-owned? '("ShieldBattery"))) 'battery-recharge]
    [(and (memv al '(729 730 731)) (= ac 0) (eq? dk 'unit) (equal? tgt-type "ShieldBattery")) 'battery-overcharge]
    ;; Universal Move / HoldPos / Attack / Cancel
    [(and (memv al '(42 43)) (= ac 0) (eq? dk 'point))
     (if (has-sel? '("Baneling"))
         'baneling-move-cmd
         'move-cmd)]
    [(and (memv al '(42 43)) (= ac 2) (eq? dk 'none))
     (if (has-sel? '("Changeling" "ChangelingZealot" "ChangelingMarine" "ChangelingMarineShield" "ChangelingZergling" "ChangelingZerglingWings"))
         'changeling-hold-pos
         'hold-pos-cmd)]
    [(and (memv al '(45 46)) (= ac 0) (eq? dk 'unit))
     (cond
       [(has-sel? '("WidowMineBurrowed" "WidowMine")) 'widow-mine-retarget]
       [(equal? tgt-type "Baneling") 'target-fire-baneling]
       [(and tgt-type (string-prefix? tgt-type "Changeling")) 'snipe-changeling-cmd]
       [else 'attack-unit-cmd])]
    [(and (memv al '(127 129)) (= ac 0) (eq? dk 'none))
     'cancel-build-in-progress]
    ;; Creep / Overseer / Dropperlord
    [(and (has-sel-or-owned? '("Queen")) (eq? dk 'unit) (memv al '(110 111 113)) (= ac 0)) 'queen-inject]
    [(and (has-sel-or-owned? '("Queen")) (eq? dk 'unit) (memv al '(245 247)) (= ac 0)) 'queen-transfuse]
    [(and (has-sel-or-owned? '("Queen")) (eq? dk 'point) (memv al '(252 259 260 262)) (= ac 0)) 'queen-creep-tumor]
    [(and (has-sel? '("CreepTumorBurrowed" "CreepTumorQueen" "CreepTumor")) (eq? dk 'point) (= ac 0)) 'tumor-spread-cmd]
    [(and (has-sel-or-owned? '("Overlord" "OverlordTransport")) (eq? dk 'none) (memv al '(259 261)) (= ac 0)) 'ov-generate-creep]
    [(and (has-sel-or-owned? '("Overseer" "OverseerSiegeMode")) (eq? dk 'none) (memv al '(95 97)) (= ac 0)) 'overseer-changeling]
    [(and (has-sel-or-owned? '("Overseer" "OverseerSiegeMode")) (eq? dk 'unit) (memv al '(274 276)) (= ac 0)) 'overseer-contaminate]
    [(and (has-sel-or-owned? '("Overseer")) (eq? dk 'none) (memv al '(715 716 717)) (= ac 0)) 'overseer-oversight]
    ;; Burrow / Baneling / WidowMine
    [(and (eq? dk 'none) (= ac 0)
          (has-sel-or-owned? '("Zergling" "Baneling" "Roach" "Hydralisk" "Queen" "Infestor" "LurkerMP" "Drone" "Ravager" "Ultralisk"))
          (memv al '(195 197 199 201 203 215 217 219 221 225 227 303 305 307 309)))
     'zerg-burrow-down]
    [(and (eq? dk 'none) (= ac 0)
          (has-sel-or-owned? '("ZerglingBurrowed" "BanelingBurrowed" "RoachBurrowed" "HydraliskBurrowed" "QueenBurrowed" "InfestorBurrowed" "LurkerMPBurrowed" "DroneBurrowed"
                               "Zergling" "Baneling" "Roach" "LurkerMP"))
          (memv al '(196 198 200 202 204 216 218 220 222 226 228 304 306 308 310)))
     'zerg-burrow-up]
    [(and (has-sel-or-owned? '("Baneling" "BanelingBurrowed")) (eq? dk 'none) (= ac 0) (memv al '(68 70))) 'baneling-explode]
    [(and (has-sel-or-owned? '("WidowMine")) (eq? dk 'none) (= ac 0) (memv al '(397 399))) 'widow-mine-burrow]
    [(and (has-sel-or-owned? '("WidowMine" "WidowMineBurrowed")) (eq? dk 'none) (= ac 0) (memv al '(398 400))) 'widow-mine-unburrow]
    [(and (has-sel-or-owned? '("WidowMineBurrowed" "WidowMine")) (eq? dk 'unit) (= ac 0) (memv al '(399 401))) 'widow-mine-retarget]
    ;; Transports
    [(and (has-sel-or-owned? '("Medivac")) (not (member "WidowMine" sel-types)) (eq? dk 'none) (= ac 0) (memv al '(389 396 404 406))) 'medivac-boost]
    [(and (has-sel-or-owned? '("Medivac")) (memv al '(130 133 137 138 140)))
     (case ac
       [(0 4) 'medivac-load]
       [(1 2) (if (and (eq? dk 'unit) (equal? tgt-type "Medivac")) 'medivac-unload-moving 'medivac-unload)]
       [(3) 'medivac-unload-unit]
       [else #f])]
    [(and (has-sel-or-owned? '("WarpPrism" "WarpPrismPhasing")) (eq? dk 'none) (= ac 0) (memv al '(225 233 235))) 'prism-phasing]
    [(and (has-sel-or-owned? '("WarpPrismPhasing" "WarpPrism")) (eq? dk 'none) (= ac 0) (memv al '(226 234 236))) 'prism-transport]
    [(and (has-sel-or-owned? '("WarpPrism" "WarpPrismPhasing")) (memv al '(163 171 173)))
     (case ac
       [(0 4) 'prism-load]
       [(1 2) (if (and (eq? dk 'unit) (member tgt-type '("WarpPrism" "WarpPrismPhasing"))) 'prism-unload-moving 'prism-unload)]
       [(3) 'prism-unload-unit]
       [else #f])]
    [(and (has-sel-or-owned? '("Overlord")) (eq? dk 'none) (= ac 0) (memv al '(310 312))) 'morph-ov-transport]
    [(and (has-sel-or-owned? '("OverlordTransport" "Overlord")) (memv al '(211 213 687)))
     (case ac
       [(0 4) 'ov-load]
       [(1 2) (if (and (eq? dk 'unit) (equal? tgt-type "OverlordTransport")) 'ov-unload-moving 'ov-unload)]
       [(3) 'ov-unload-unit]
       [else #f])]
    ;; Unit Modes
    [(and (has-sel-or-owned? '("Thor")) (eq? dk 'none) (= ac 0) (memv al '(534 536))) 'thor-high-impact]
    [(and (has-sel-or-owned? '("ThorAP" "Thor")) (eq? dk 'none) (= ac 0) (memv al '(312 314))) 'thor-explosive]
    [(and (has-sel-or-owned? '("Hellion")) (eq? dk 'none) (= ac 0) (memv al '(355 356 367 369))) 'morph-hellbat]
    [(and (has-sel-or-owned? '("HellionTank" "Hellion")) (eq? dk 'none) (= ac 0) (memv al '(357 359))) 'morph-hellion]
    [(and (has-sel-or-owned? '("VikingFighter")) (eq? dk 'none) (= ac 0) (memv al '(141 143))) 'viking-assault]
    [(and (has-sel-or-owned? '("VikingAssault" "VikingFighter")) (eq? dk 'none) (= ac 0) (memv al '(142 144))) 'viking-fighter]
    [(and (has-sel-or-owned? '("Cyclone")) (eq? dk 'unit) (= ac 0) (memv al '(524 528 530))) 'cyclone-lock-on]
    [(and (has-sel-or-owned? '("Cyclone")) (eq? dk 'none) (= ac 0) (memv al '(526 530 532))) 'cyclone-lock-cancel]
    ;; Adept / Stalker / Phoenix
    [(and (has-sel-or-owned? '("Adept")) (eq? dk 'point) (= ac 0) (memv al '(608 609 610))) 'adept-shade]
    [(and (has-sel-or-owned? '("Adept" "AdeptPhaseShift")) (eq? dk 'none) (= ac 0) (memv al '(633 634 635 636))) 'adept-shade-cancel]
    [(and (has-sel-or-owned? '("Stalker")) (eq? dk 'point) (= ac 0) (memv al '(218 220))) 'stalker-blink]
    [(and (has-sel-or-owned? '("Phoenix")) (eq? dk 'unit) (= ac 0) (memv al '(91 93))) 'phoenix-lift]
    ;; Z/T/P Spellcasters
    [(and (has-sel-or-owned? '("Ravager")) (eq? dk 'point) (= ac 0) (memv al '(281 283 481 501 508 517 518))) 'ravager-bile]
    [(and (has-sel-or-owned? '("Infestor" "InfestorBurrowed")) (eq? dk 'point) (= ac 0) (memv al '(70 72))) 'infestor-fungal]
    [(and (has-sel-or-owned? '("Infestor" "InfestorBurrowed")) (eq? dk 'unit) (= ac 0) (memv al '(110 112))) 'infestor-neural]
    [(and (has-sel-or-owned? '("Infestor" "InfestorBurrowed")) (eq? dk 'point) (= ac 0) (memv al '(699 700 701))) 'infestor-shroud]
    [(and (has-sel-or-owned? '("SwarmHostMP" "SwarmHostBurrowedMP")) (eq? dk 'point) (= ac 0) (memv al '(701 702 703))) 'swarmhost-locusts]
    [(and (has-sel-or-owned? '("Viper")) (eq? dk 'point) (= ac 0) (memv al '(370 371 381 383))) 'viper-cloud]
    [(and (has-sel-or-owned? '("Viper")) (eq? dk 'unit) (not tgt-ally?) (= ac 0) (memv al '(372 373 383 385))) 'viper-abduct]
    [(and (has-sel-or-owned? '("Viper")) (eq? dk 'unit) tgt-ally? (= ac 0) (memv al '(376 386 388))) 'viper-consume]
    [(and (has-sel-or-owned? '("Viper")) (eq? dk 'unit) (not tgt-ally?) (= ac 0) (memv al '(375 597 607 609))) 'viper-pbomb]
    [(and (has-sel-or-owned? '("Corruptor")) (eq? dk 'unit) (= ac 0) (memv al '(511 519 521))) 'corruptor-spray]
    [(and (has-sel-or-owned? '("Marine" "Marauder")) (eq? dk 'none) (= ac 0) (memv al '(112 114 131 133))) 'terran-stim]
    [(and (has-sel-or-owned? '("OrbitalCommand")) (eq? dk 'point) (= ac 0) (memv al '(139 141))) 'scanner-sweep]
    [(and (has-sel-or-owned? '("Ghost")) (eq? dk 'point) (= ac 0) (memv al '(241 243))) 'ghost-emp]
    [(and (has-sel-or-owned? '("Ghost")) (eq? dk 'unit) (= ac 0) (memv al '(708 709 710))) 'ghost-snipe]
    [(and (has-sel-or-owned? '("Ghost")) (eq? dk 'none) (= ac 0) (memv al '(132 134))) 'ghost-cloak]
    [(and (has-sel-or-owned? '("Raven")) (eq? dk 'unit) (= ac 0) (memv al '(715 717 719))) 'raven-matrix]
    [(and (has-sel-or-owned? '("Raven")) (eq? dk 'unit) (= ac 0) (memv al '(720 721 722))) 'raven-aam]
    [(and (has-sel-or-owned? '("Raven")) (eq? dk 'point) (= ac 0) (memv al '(266 268))) 'raven-turret]
    [(and (has-sel-or-owned? '("Battlecruiser")) (eq? dk 'unit) (= ac 0) (memv al '(140 142))) 'bc-yamato]
    [(and (has-sel-or-owned? '("Battlecruiser")) (eq? dk 'point) (= ac 0) (memv al '(526 532 534))) 'bc-jump]
    [(and (has-sel-or-owned? '("Sentry")) (eq? dk 'none) (= ac 0) (memv al '(71 73))) 'sentry-gs]
    [(and (has-sel-or-owned? '("Sentry")) (eq? dk 'point) (= ac 0) (memv al '(232 234))) 'sentry-ff]
    [(and (has-sel-or-owned? '("Sentry")) (eq? dk 'none) (= ac 0)
          (memv al '(78 79 80 81 82 83 84 85 86 87 88 89 403 405 545 546 547 548)))
     (if (memv al '(82 84)) 'sentry-halluc-phoenix 'sentry-halluc-other)]
    [(and (has-sel-or-owned? '("HighTemplar")) (eq? dk 'point) (= ac 0) (memv al '(176 178))) 'ht-storm]
    [(and (has-sel-or-owned? '("HighTemplar")) (eq? dk 'unit) (= ac 0) (memv al '(75 77))) 'ht-feedback]
    [(and (has-sel-or-owned? '("HighTemplar")) (memv al '(267 269)) (memv ac '(0 1))) 'ht-archon]
    [(and (has-sel-or-owned? '("Oracle")) (eq? dk 'none) (= ac 0) (memv al '(534 538 540))) 'oracle-beam-on]
    [(and (has-sel-or-owned? '("Oracle")) (eq? dk 'none) (= ac 1) (memv al '(534 538 540))) 'oracle-beam-off]
    [(and (has-sel-or-owned? '("Oracle")) (eq? dk 'point) (= ac 0) (memv al '(412 413 419 421))) 'oracle-revelation]
    [(and (has-sel-or-owned? '("Oracle")) (eq? dk 'point) (= ac 0) (memv al '(599 603 605))) 'oracle-stasis]
    [(and (has-sel-or-owned? '("Disruptor")) (eq? dk 'point) (= ac 0) (memv al '(505 521 526 528))) 'disruptor-nova]
    ;; Nexus Strategic Recall (3686/3757), Energy Recharge, Mothership Mass Recall (2368) & Time Warp (2244)
    [(and (has-sel-or-owned? '("Nexus")) (eq? dk 'point) (= ac 0) (memv al '(722 723 724))) 'nexus-strategic-recall]
    [(and (has-sel-or-owned? '("Nexus")) (eq? dk 'unit) (= ac 0) (memv al '(730 731 732))) 'nexus-energy-recharge]
    [(and (has-sel-or-owned? '("Mothership" "MothershipCore")) (eq? dk 'point) (= ac 0) (memv al '(76 78 355 357))) 'mothership-mass-recall]
    [(and (has-sel-or-owned? '("Mothership" "MothershipCore")) (eq? dk 'point) (= ac 0) (memv al '(468 470))) 'mothership-time-warp]
    [else #f]))

;; -----------------------------------------------------------------------------
;; 5. Canonical Unit Mapping for 9-Matchup Minute Benchmarks
;; -----------------------------------------------------------------------------

(define (canonical-bench-sym uname)
  (cond
    [(member uname '("Zergling" "ZerglingBurrowed")) 'zergling]
    [(member uname '("Baneling" "BanelingBurrowed")) 'baneling]
    [(member uname '("Queen" "QueenBurrowed")) 'queen]
    [(member uname '("Roach" "RoachBurrowed")) 'roach]
    [(member uname '("Ravager" "RavagerBurrowed")) 'ravager]
    [(member uname '("Hydralisk" "HydraliskBurrowed")) 'hydralisk]
    [(member uname '("LurkerMP" "LurkerMPBurrowed")) 'lurker-mp]
    [(string=? uname "Mutalisk") 'mutalisk]
    [(string=? uname "Corruptor") 'corruptor]
    [(string=? uname "BroodLord") 'brood-lord]
    [(member uname '("Infestor" "InfestorBurrowed")) 'infestor]
    [(member uname '("SwarmHostMP" "SwarmHostBurrowedMP")) 'swarm-host]
    [(string=? uname "Viper") 'viper]
    [(member uname '("Ultralisk" "UltraliskBurrowed")) 'ultralisk]
    [(member uname '("Overseer" "OverseerSiegeMode")) 'overseer]
    [(string=? uname "OverlordTransport") 'overlord-transport]
    [(string=? uname "Marine") 'marine]
    [(string=? uname "Marauder") 'marauder]
    [(string=? uname "Reaper") 'reaper]
    [(string=? uname "Hellion") 'hellion]
    [(string=? uname "HellionTank") 'hellbat]
    [(member uname '("WidowMine" "WidowMineBurrowed")) 'widow-mine]
    [(string=? uname "Cyclone") 'cyclone]
    [(member uname '("SiegeTank" "SiegeTankSieged")) 'siege-tank]
    [(member uname '("Thor" "ThorAP")) 'thor]
    [(string=? uname "Medivac") 'medivac]
    [(member uname '("VikingFighter" "VikingAssault")) 'viking-fighter]
    [(member uname '("Liberator" "LiberatorAG")) 'liberator]
    [(string=? uname "Banshee") 'banshee]
    [(string=? uname "Raven") 'raven]
    [(string=? uname "Ghost") 'ghost]
    [(string=? uname "Battlecruiser") 'battlecruiser]
    [(string=? uname "Zealot") 'zealot]
    [(string=? uname "Adept") 'adept]
    [(string=? uname "Stalker") 'stalker]
    [(string=? uname "Sentry") 'sentry]
    [(string=? uname "Immortal") 'immortal]
    [(member uname '("Observer" "ObserverSiegeMode")) 'observer]
    [(member uname '("WarpPrism" "WarpPrismPhasing")) 'warp-prism]
    [(string=? uname "Phoenix") 'phoenix]
    [(string=? uname "Oracle") 'oracle]
    [(string=? uname "VoidRay") 'void-ray]
    [(string=? uname "Tempest") 'tempest]
    [(string=? uname "Carrier") 'carrier]
    [(string=? uname "Colossus") 'colossus]
    [(string=? uname "HighTemplar") 'high-templar]
    [(string=? uname "DarkTemplar") 'dark-templar]
    [(string=? uname "Archon") 'archon]
    [(string=? uname "Disruptor") 'disruptor]
    [else #f]))

(define (race->letter r)
  (cond
    [(or (string=? r "Zerg") (string=? r "Z")) "Z"]
    [(or (string=? r "Terran") (string=? r "T")) "T"]
    [(or (string=? r "Protoss") (string=? r "P")) "P"]
    [else "?"]))

(define (bytes->str b [fb ""])
  (cond [(bytes? b) (bytes->string/utf-8 b #\?)]
        [(string? b) b]
        [else fb]))

(define (clean-pname raw fb)
  (define s0 (bytes->str raw ""))
  (define s1 (regexp-replace* #rx"<sp/>" s0 " "))
  (define s2 (regexp-replace* #rx"&lt;[^&]*&gt;" s1 ""))
  (define s3 (string-trim (regexp-replace* #rx"<[^>]+>" s2 "")))
  (if (string=? s3 "") fb s3))

(define WALL-STRUCTURES
  '("Pylon" "SupplyDepot" "SupplyDepotLowered" "Barracks" "Gateway" "WarpGate"
    "Forge" "CyberneticsCore" "PhotonCannon" "ShieldBattery" "Bunker" "EvolutionChamber" "SpineCrawler"))

(define PROXY-STRUCTURES
  '("Barracks" "Factory" "Starport" "Gateway" "RoboticsFacility" "Stargate"
    "Hatchery" "SpawningPool" "PhotonCannon" "ShieldBattery" "SpineCrawler" "Bunker"))

(define NON-COMBAT-DEATHS
  '("Larva" "Broodling" "BroodlingEscort" "LocustMP" "LocustMPFlying"
    "Interceptor" "AutoTurret" "OracleStasisTrap" "AdeptPhaseShift"
    "CreepTumor" "CreepTumorQueen" "CreepTumorBurrowed" "DisruptorPhased"
    "Changeling" "ChangelingZealot" "ChangelingMarine" "ChangelingMarineShield"
    "ChangelingZergling" "ChangelingZerglingWings" "KD8Charge" "ParasiticBombDummy"))

(define GOLD-OR-RICH-RESOURCES
  '("RichMineralField" "RichMineralField750"
    "PurifierRichMineralField" "PurifierRichMineralField750"
    "RichVespeneGeyser"))

(define (destructible-or-rockslide-unit? uname)
  (or (string-contains? uname "Destructible")
      (string-contains? uname "Collapsible")
      (string-contains? uname "Rocks2x2")
      (string-contains? uname "Debris2x2")))

;; -----------------------------------------------------------------------------
;; 6. Per-Replay Full Tactical & Benchmark Extractor (`analyze-single-replay`)
;; -----------------------------------------------------------------------------

(define (analyze-single-replay path corpus-name)
  (define bb (read-replay-base-build path))
  (and bb (>= bb 38215)
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (define mpq (read-mpq-files path #:filenames '("replay.details" "replay.tracker.events" "replay.game.events" "replay.attributes.events")))
         (define trk-raw (and mpq (hash-ref mpq "replay.tracker.events" #f)))
         (define det-raw (and mpq (hash-ref mpq "replay.details" #f)))
         (and trk-raw det-raw
              (let ()
                (define-values (details _) (decode-versioned det-raw 0))
                (define map-name (if (hash? details) (bytes->str (hash-ref details 1 #"")) ""))
                (define plist (if (hash? details) (hash-ref details 0 '()) '()))
                (define evs (decode-tracker-stream trk-raw))
                (define max-gl (if (null? evs) 0 (caar (reverse evs))))
                (define rand-slots (parse-random-slots (hash-ref mpq "replay.attributes.events" #f)))

                ;; Frame-0 setup: TownHalls, start_xy, resource base centroids, gold/rich nodes, user_id->pid, slot->pid
                (define pid->race (make-hasheqv))
                (define start-xy (make-hasheqv))
                (define uid->pid (make-hasheqv))
                (define slot->pid (make-hasheqv))
                (define f0-res '())
                (define f0-gold-res '())
                (for ([e (in-list evs)] #:break (> (car e) 16))
                  (define eid (cadr e))
                  (define p (caddr e))
                  (cond
                    [(= eid 9)
                     (define pid (hash-ref p 0 #f))
                     (define uid (hash-ref p 2 #f))
                     (define slot (hash-ref p 3 #f))
                     (when (and pid uid) (hash-set! uid->pid uid pid))
                     (when (and pid (exact-integer? slot)) (hash-set! slot->pid slot pid))]
                    [(= eid 1)
                     (define cp (hash-ref p 3 0))
                     (define ut (bytes->str (hash-ref p 2 #"")))
                     (define ux (exact->inexact (hash-ref p 5 0)))
                     (define uy (exact->inexact (hash-ref p 6 0)))
                     (cond
                       [(= cp 0)
                        (when (or (string-contains? ut "Mineral")
                                  (string-contains? ut "Vespene")
                                  (string-contains? ut "Geyser"))
                          (set! f0-res (cons (cons ux uy) f0-res))
                          (when (member ut GOLD-OR-RICH-RESOURCES)
                            (set! f0-gold-res (cons (cons ux uy) f0-gold-res))))]
                       [(> cp 0)
                        (cond
                          [(string=? ut "Hatchery") (hash-set! pid->race cp "Z") (hash-set! start-xy cp (cons ux uy))]
                          [(string=? ut "CommandCenter") (hash-set! pid->race cp "T") (hash-set! start-xy cp (cons ux uy))]
                          [(string=? ut "Nexus") (hash-set! pid->race cp "P") (hash-set! start-xy cp (cons ux uy))])])]))

                ;; Require genuine 1v1 melee (>= 60s and non-empty map or AI Arena)
                (and (= (hash-count pid->race) 2)
                     (>= max-gl 1344)
                     (or (not (string=? map-name "")) (string=? corpus-name "aiarena_matches"))
                     (let ()
                       (define rel-path (format "replays/~a/~a" corpus-name (path->string (file-name-from-path path))))
                       (define pids (sort (hash-keys pid->race) <))
                       (define p1 (car pids))
                       (define p2 (cadr pids))
                       (when (zero? (hash-count uid->pid))
                         (hash-set! uid->pid 0 p1)
                         (hash-set! uid->pid 1 p2))

                       (define pid->name (make-hasheqv))
                       (define pid->is-random (make-hasheqv))
                       (for ([pl (in-list plist)] [sidx (in-naturals)] #:when (hash? pl))
                         (define pid (hash-ref slot->pid sidx (add1 sidx)))
                         (when (memv pid pids)
                           (define nm (clean-pname (hash-ref pl 0 #"") (format "P~a" pid)))
                           (define dr (bytes->str (hash-ref pl 2 #"")))
                           (hash-set! pid->name pid nm)
                           (when (or (hash-ref rand-slots (add1 sidx) #f)
                                     (string-contains? dr "Random")
                                     (random-player-name? nm))
                             (hash-set! pid->is-random pid #t))))
                       (for ([pid (in-list pids)])
                         (unless (hash-has-key? pid->name pid)
                           (hash-set! pid->name pid (format "P~a" pid))))

                       ;; Cluster resource nodes into base centroids (<= 14.0 tiles)
                       (define base-centroids
                         (let cloop ([rem (reverse f0-res)] [cls '()])
                           (if (null? rem)
                               (map (lambda (c)
                                      (cons (/ (for/sum ([q (in-list c)]) (car q)) (length c))
                                            (/ (for/sum ([q (in-list c)]) (cdr q)) (length c))))
                                    cls)
                               (let* ([pt (car rem)] [px (car pt)] [py (cdr pt)])
                                 (let floop ([cs cls] [acc '()])
                                   (cond
                                     [(null? cs) (cloop (cdr rem) (cons (list pt) cls))]
                                     [else
                                      (define c (car cs))
                                      (define cx (/ (for/sum ([q (in-list c)]) (car q)) (length c)))
                                      (define cy (/ (for/sum ([q (in-list c)]) (cdr q)) (length c)))
                                      (if (<= (dist2d px py cx cy) 14.0)
                                          (cloop (cdr rem) (append (reverse acc) (list (cons pt c)) (cdr cs)))
                                          (floop (cdr cs) (cons c acc)))]))))))

                       (define pid->bases (make-hasheqv)) ; pid -> list of (main, nat, 3rd, 4th)
                       (for ([pid (in-list pids)])
                         (define sxy (hash-ref start-xy pid '(0.0 . 0.0)))
                         (define sc (sort base-centroids < #:key (lambda (c) (dist2d (car c) (cdr c) (car sxy) (cdr sxy)))))
                         (hash-set! pid->bases pid (if (null? sc) (list sxy) (take sc (min 4 (length sc))))))

                       (define gev-raw (hash-ref mpq "replay.game.events" #f))
                       (define raw-cmds (or (and gev-raw (decode-game-events-for-build gev-raw bb max-gl)) '()))

                       ;; Live state during replay simulation
                       (define utag->type (make-hasheqv))
                       (define utag->pid (make-hasheqv))
                       (define utag->xy (make-hasheqv))
                       (define utag->born-gl (make-hasheqv))
                       (define utag->was-init (make-hasheqv))
                       (define utag->was-done (make-hasheqv))
                       (define idx->utag (make-hasheqv)) ; O(1) lookup for SUnitPositionsEvent!
                       (define alive-counts (make-hash)) ; (cons pid uname) -> int
                       (define prod-bench (make-hash))   ; (cons pid sym) -> int
                       (define (inc-alive! pid u d)
                         (hash-update! alive-counts (cons pid u) (lambda (v) (max 0 (+ v d))) 0))
                       (define (player-owned-map pid)
                         (define h (make-hash))
                         (for ([(k v) (in-hash alive-counts)] #:when (and (= (car k) pid) (> v 0)))
                           (hash-set! h (cdr k) #t))
                         h)

                       ;; Findings collectors for this replay
                       (define events-out '())
                       (define (emit-ev! fam sub gl pid detail [metric 0.0])
                         (define opp (if (= pid p1) p2 p1))
                         (set! events-out
                               (cons (hasheq 'family fam
                                             'subtype sub
                                             'corpus corpus-name
                                             'replay rel-path
                                             'map map-name
                                             'matchup (string-append (hash-ref pid->race pid) "v" (hash-ref pid->race opp))
                                             'player (hash-ref pid->name pid)
                                             'opponent (hash-ref pid->name opp)
                                             'frame gl
                                             'clock (gl->mmss gl)
                                             'metric (round1 metric)
                                             'detail detail)
                                     events-out)))

                       (define spell-casts '()) ; (list pid sp gl tgt-type)
                       (define early-wall-main (make-hasheqv '((1 . 0) (2 . 0))))
                       (define early-wall-nat (make-hasheqv '((1 . 0) (2 . 0))))
                       (define early-rush-kills (make-hasheqv '((1 . 0) (2 . 0))))
                       (define tumor-queen-cnt (make-hasheqv '((1 . 0) (2 . 0))))
                       (define tumor-spread-cnt (make-hasheqv '((1 . 0) (2 . 0))))
                       (define tumor-cleared-cnt (make-hasheqv '((1 . 0) (2 . 0))))
                       (define tumor-angles (make-hasheqv '((1 . ()) (2 . ()))))
                       (define last-ov-drop-gl (make-hasheqv))
                       (define last-drop-evs (make-hasheqv '((1 . ()) (2 . ())))) ; (list gl x y kind)
                       (define last-wm-drop-gl (make-hasheqv))
                       (define last-runby-gl (make-hasheqv))
                       (define wm-kill-frame-cnt (make-hash)) ; (cons killer-utag gl-bucket) -> int
                       (define burrow-down-gl (make-hasheqv)) ; utag -> gl
                       (define oracle-beam-gl (make-hasheqv)) ; utag -> gl
                       (define viking-land-gls (make-hasheqv '((1 . ()) (2 . ()))))
                       (define recent-move-gls (make-hasheqv '((1 . ()) (2 . ()))))
                       (define last-opp-aoe-gl (make-hasheqv)) ; pid -> (cons gl spell)
                       (define lockon-targets (make-hasheqv))  ; target-utag -> gl
                       (define midmap-clash-gl (make-hasheqv))
                       (define pid->pylon-utags (make-hasheqv '((1 . ()) (2 . ()))))
                       (define pid->prism-utags (make-hasheqv '((1 . ()) (2 . ()))))
                       (define last-rescue-gl (make-hasheqv))

                       ;; Wave 1.8 (#137) state trackers
                       (define pid->structures (make-hasheqv '((1 . ()) (2 . ())))) ; (list utag uname ux uy gl)
                       (define pid->fwd-protoss (make-hasheqv '((1 . ()) (2 . ())))) ; (list utag uname ux uy gl)
                       (define pid->sh-utags (make-hasheqv '((1 . ()) (2 . ()))))
                       (define last-sh-locust-gl (make-hasheqv))
                       (define last-locust-wave-gl (make-hasheqv))
                       (define pid->nydus-worms (make-hasheqv '((1 . ()) (2 . ())))) ; (list gl ux uy)
                       (define utag->crawler-uproot (make-hasheqv)) ; utag -> (cons gl (cons ux uy))
                       (define last-bunker-load-gl (make-hasheqv))
                       (define last-pf-repair-gl (make-hasheqv))
                       (define last-nydus-load-gl (make-hasheqv))
                       (define f0-split-cmds (make-hasheqv '((1 . 0) (2 . 0))))
                       (define f0-split-patches (make-hasheqv))
                       (hash-set! f0-split-patches p1 (mutable-seteqv))
                       (hash-set! f0-split-patches p2 (mutable-seteqv))
                       (define f0-first-split-gl (make-hasheqv))
                       (define last-worker-move-gl (make-hasheqv))
                       (define speed-mine-cnt (make-hasheqv '((1 . 0) (2 . 0))))
                       (define last-speed-mine-ev-gl (make-hasheqv))
                       (define last-drill-stack-gl (make-hasheqv))
                       (define drill-stack-cmd-cnt (make-hasheqv '((1 . 0) (2 . 0))))
                       (define worker-rush-kills (make-hasheqv '((1 . 0) (2 . 0))))
                       (define worker-rush-bldg-kills (make-hasheqv '((1 . 0) (2 . 0))))
                       (define worker-rush-first-gl (make-hasheqv))

                       ;; Minute benchmark snapshots (only for pro_corpus)
                       (define min-snaps '())
                       (define pending-mins
                         (if (string=? corpus-name "pro_corpus") BENCHMARK-MINUTES '()))
                       (define (take-minute-snapshot! m)
                         (for ([pid (in-list pids)])
                           (define opp (if (= pid p1) p2 p1))
                           (define mu (string-append (hash-ref pid->race pid) "v" (hash-ref pid->race opp)))
                           (define alive-sym-h (make-hasheq))
                           (define workers 0)
                           (define bases 0)
                           (for ([(k cnt) (in-hash alive-counts)]
                                 #:when (and (= (car k) pid) (> cnt 0)))
                             (define unm (cdr k))
                             (when (member unm '("Drone" "SCV" "Probe"))
                               (set! workers (+ workers cnt)))
                             (when (member unm '("Hatchery" "Lair" "Hive" "CommandCenter" "OrbitalCommand" "PlanetaryFortress" "Nexus"))
                               (set! bases (+ bases cnt)))
                             (define bsym (canonical-bench-sym unm))
                             (when bsym
                               (hash-update! alive-sym-h bsym (lambda (x) (+ x cnt)) 0)))
                           (define prod-sym-h (make-hasheq))
                           (for ([(k cnt) (in-hash prod-bench)]
                                 #:when (and (= (car k) pid) (> cnt 0)))
                             (hash-set! prod-sym-h (cdr k) cnt))
                           (set! min-snaps
                                 (cons (hasheq 'matchup mu
                                               'minute m
                                               'workers workers
                                               'bases bases
                                               'alive alive-sym-h
                                               'produced prod-sym-h)
                                       min-snaps))))

                       (define (process-trk! e)
                         (define gl (car e))
                         (define eid (cadr e))
                         (define p (caddr e))
                         (case eid
                           [(1 6) ; UnitBorn / UnitInit
                            (define idx (hash-ref p 0 0))
                            (define rec (hash-ref p 1 0))
                            (define utag (+ (arithmetic-shift idx 18) rec))
                            (define uname (bytes->str (hash-ref p 2 #"")))
                            (define pid (hash-ref p 3 0))
                            (define ux (exact->inexact (hash-ref p 5 0)))
                            (define uy (exact->inexact (hash-ref p 6 0)))
                            (unless (hash-has-key? utag->type utag)
                              (hash-set! utag->type utag uname)
                              (hash-set! utag->pid utag pid)
                              (hash-set! utag->xy utag (cons ux uy))
                              (hash-set! utag->born-gl utag gl)
                              (hash-set! idx->utag idx utag)
                              (when (= eid 6) (hash-set! utag->was-init utag #t))
                              (when (memv pid pids)
                                (inc-alive! pid uname 1)
                                (define bsym (canonical-bench-sym uname))
                                (when (and bsym (not (member uname '("Ravager" "LurkerMP" "Baneling" "BroodLord" "Archon" "Overseer" "OverlordTransport"))))
                                  (hash-update! prod-bench (cons pid bsym) add1 0))
                                (when (string=? uname "Archon")
                                  (hash-update! prod-bench (cons pid 'archon) add1 0))
                                (define opp (if (= pid p1) p2 p1))
                                (define own-bs (hash-ref pid->bases pid))
                                (define opp-bs (hash-ref pid->bases opp))
                                (define main-xy (car own-bs))
                                (define nat-xy (if (>= (length own-bs) 2) (cadr own-bs) main-xy))
                                (define opp-main (car opp-bs))
                                (define opp-nat (if (>= (length opp-bs) 2) (cadr opp-bs) opp-main))

                                ;; (1) Early walling <= 2:30 (gl <= 3360)
                                (when (and (= eid 6) (<= gl 3360) (member uname WALL-STRUCTURES))
                                  (define dm (dist2d ux uy (car main-xy) (cdr main-xy)))
                                  (define dn (dist2d ux uy (car nat-xy) (cdr nat-xy)))
                                  (cond
                                    [(and (<= dm 19.5) (< dm dn))
                                     (hash-update! early-wall-main pid add1 0)]
                                    [(<= dn 19.5)
                                     (hash-update! early-wall-nat pid add1 0)]))

                                ;; (3) Creep tumors & Dropperlord+Queen remote creep expedition
                                (when (string=? uname "CreepTumorQueen")
                                  (hash-update! tumor-queen-cnt pid add1 0)
                                  (define ang (inexact->exact (round (/ (* 180.0 (atan (- uy (cdr main-xy)) (- ux (car main-xy)))) pi 30.0))))
                                  (hash-update! tumor-angles pid (lambda (ls) (if (member ang ls) ls (cons ang ls))))
                                  (define dm (dist2d ux uy (car main-xy) (cdr main-xy)))
                                  (define ov-d (hash-ref last-ov-drop-gl pid #f))
                                  (when (or (and ov-d (<= (- gl ov-d) 448))
                                            (and (> dm 42.0) (<= gl 9408)))
                                    (emit-ev! "creep-spread-and-clearing" "dropperlord-queen-creep-expedition" gl pid
                                              (format "Remote Queen CreepTumor ~a tiles from main" (round1 dm)) dm)))
                                (when (string=? uname "CreepTumor")
                                  (hash-update! tumor-spread-cnt pid add1 0))

                                ;; (4) Changeling born
                                (when (string-prefix? uname "Changeling")
                                  (emit-ev! "changeling-and-counter" "spawn-changeling" gl pid uname 0.0))

                                ;; (9) Off-path proxy all-ins (<= 4:00 = 5376f) & (10) Expansion/Gas blocks
                                (when (and (= eid 6) (<= gl 5376))
                                  (define min-own-d
                                    (for/fold ([best +inf.0]) ([b (in-list (take own-bs (min 3 (length own-bs))))])
                                      (min best (dist2d ux uy (car b) (cdr b)))))
                                  (define min-opp-exp-d
                                    (for/fold ([best +inf.0]) ([b (in-list (cdr opp-bs))])
                                      (min best (dist2d ux uy (car b) (cdr b)))))
                                  (define d-opp-main (dist2d ux uy (car opp-main) (cdr opp-main)))
                                  ;; Gas steal at enemy main/nat
                                  (when (and (member uname '("Assimilator" "Extractor" "Refinery"))
                                             (<= (min d-opp-main (dist2d ux uy (car opp-nat) (cdr opp-nat))) 13.0))
                                    (emit-ev! "expansion-and-gas-blocks" "gas-steal" gl pid
                                              (format "~a gas steal in enemy base" uname) d-opp-main))
                                  ;; Hatch / Ebay / Pylon expansion block at enemy nat/3rd
                                  (when (and (member uname '("Hatchery" "EngineeringBay" "Pylon" "SupplyDepot"))
                                             (<= min-opp-exp-d 9.5))
                                    (emit-ev! "expansion-and-gas-blocks" "expansion-pad-block" gl pid
                                              (format "~a blocking enemy expansion pad (d=~a)" uname (round1 min-opp-exp-d))
                                              min-opp-exp-d))
                                  ;; Off-path proxy production
                                  (when (and (member uname PROXY-STRUCTURES)
                                             (> min-own-d 30.0)
                                             (> min-opp-exp-d 9.5))
                                    (define pdist (perp-dist-to-axis ux uy (car main-xy) (cdr main-xy) (car opp-main) (cdr opp-main)))
                                    (define sub (if (>= pdist 22.0)
                                                    (if (hash-ref pid->is-random pid #f) "off-path-proxy-random" "off-path-proxy")
                                                    "in-axis-proxy"))
                                    (emit-ev! "off-path-proxy-all-ins" sub gl pid
                                              (format "Proxy ~a (perp=~a tiles off axis, own_d=~a)" uname (round1 pdist) (round1 min-own-d))
                                              pdist)))

                                ;; (11) Raven Auto-Turret harass near enemy base
                                (when (string=? uname "AutoTurret")
                                  (define opp-d
                                    (for/fold ([best +inf.0]) ([b (in-list opp-bs)])
                                      (min best (dist2d ux uy (car b) (cdr b)))))
                                  (when (<= opp-d 18.0)
                                    (emit-ev! "raven-harass" "mineral-line-auto-turret" gl pid
                                              (format "AutoTurret ~a tiles from enemy base" (round1 opp-d)) opp-d)))

                                ;; (12) Oracle StasisTrap
                                (when (string=? uname "OracleStasisTrap")
                                  (emit-ev! "oracle-harass" "stasis-ward-trap" gl pid "OracleStasisTrap placed" 0.0))

                                ;; Track Pylons & WarpPrisms for WarpPrism warp-in attack detection (#131)
                                (when (string=? uname "Pylon")
                                  (hash-update! pid->pylon-utags pid (lambda (ls) (cons utag ls)) '()))
                                (when (member uname '("WarpPrism" "WarpPrismPhasing"))
                                  (hash-update! pid->prism-utags pid (lambda (ls) (cons utag ls)) '()))
                                (when (and (= eid 6)
                                           (member uname '("Zealot" "Stalker" "Adept" "Sentry" "HighTemplar" "DarkTemplar")))
                                  (define prism-tags
                                    (filter (lambda (pt) (hash-has-key? utag->type pt))
                                            (hash-ref pid->prism-utags pid '())))
                                  (when (pair? prism-tags)
                                    (define min-prism-d
                                      (for/fold ([best +inf.0]) ([pt (in-list prism-tags)])
                                        (define pxy (hash-ref utag->xy pt '(0.0 . 0.0)))
                                        (min best (dist2d ux uy (car pxy) (cdr pxy)))))
                                    (define min-pylon-d
                                      (for/fold ([best +inf.0])
                                                ([pyt (in-list (hash-ref pid->pylon-utags pid '()))]
                                                 #:when (hash-has-key? utag->type pyt))
                                        (define pxy (hash-ref utag->xy pyt '(0.0 . 0.0)))
                                        (min best (dist2d ux uy (car pxy) (cdr pxy)))))
                                    (when (or (<= min-prism-d 10.0) (> min-pylon-d 8.5))
                                      (define opp-d
                                        (for/fold ([best +inf.0]) ([b (in-list opp-bs)])
                                          (min best (dist2d ux uy (car b) (cdr b)))))
                                      (emit-ev! "multi-angle-drops-and-widow-mine-runby" "warp-prism-warp-in-attack" gl pid
                                                (format "WarpPrism ~a warp-in (~a tiles from enemy base)" uname (round1 opp-d))
                                                opp-d))))

                                ;; Gold / Rich base expansions (#131)
                                (when (and (> gl 16)
                                           (pair? f0-gold-res)
                                           (member uname '("Hatchery" "CommandCenter" "Nexus")))
                                  (define gold-near
                                    (count (lambda (gxy) (<= (dist2d ux uy (car gxy) (cdr gxy)) 12.5))
                                           f0-gold-res))
                                  (when (> gold-near 0)
                                    (emit-ev! "expansion-and-gas-blocks" "gold-or-rich-base-expansion" gl pid
                                              (format "~a expanded at Gold/Rich base (~a rich nodes)" uname gold-near)
                                              gold-near)))

                                ;; Wave 1.8 (#137) UnitBorn / UnitInit hooks
                                (when (member uname '("CommandCenter" "OrbitalCommand" "PlanetaryFortress"
                                                      "Barracks" "Factory" "Starport" "SupplyDepot" "SupplyDepotLowered"
                                                      "EngineeringBay" "Armory" "GhostAcademy" "FusionCore"
                                                      "Bunker" "MissileTurret" "SensorTower" "Refinery"
                                                      "BarracksTechLab" "BarracksReactor" "FactoryTechLab" "FactoryReactor"
                                                      "StarportTechLab" "StarportReactor"
                                                      "Nexus" "Pylon" "Gateway" "WarpGate" "CyberneticsCore" "Forge"
                                                      "PhotonCannon" "ShieldBattery" "TwilightCouncil" "Stargate"
                                                      "RoboticsFacility" "RoboticsBay" "FleetBeacon" "TemplarArchive"
                                                      "DarkShrine" "Assimilator"
                                                      "Hatchery" "Lair" "Hive" "SpawningPool" "BanelingNest"
                                                      "RoachWarren" "HydraliskDen" "LurkerDenMP" "Spire" "GreaterSpire"
                                                      "InfestationPit" "UltraliskCavern" "EvolutionChamber"
                                                      "SpineCrawler" "SporeCrawler" "NydusNetwork" "Extractor"))
                                  (hash-update! pid->structures pid (lambda (ls) (cons (list utag uname ux uy gl) ls)) '()))

                                ;; (1.8-1) Swarm Host tracking & Locust wave births
                                (when (member uname '("SwarmHostMP" "SwarmHostBurrowedMP"))
                                  (hash-update! pid->sh-utags pid (lambda (ls) (cons utag ls)) '()))
                                (when (member uname '("LocustMP" "LocustMPFlying"))
                                  (define prev-lw (hash-ref last-locust-wave-gl pid -999))
                                  (when (> (- gl prev-lw) 48)
                                    (hash-set! last-locust-wave-gl pid gl)
                                    (define opp-d
                                      (for/fold ([best +inf.0]) ([b (in-list opp-bs)])
                                        (min best (dist2d ux uy (car b) (cdr b)))))
                                    (emit-ev! "spread_burrowed_swarm_host_harass" "locust-wave-spawned" gl pid
                                              (format "Locust wave launched (~a tiles from enemy base)" (round1 opp-d))
                                              opp-d)))

                                ;; (1.8-2) Cannon rush forward structures, caged cannon walls & Pylon/Gateway wedges
                                (when (and (= eid 6)
                                           (<= gl 6048)
                                           (member uname '("Pylon" "PhotonCannon" "Gateway" "Forge" "ShieldBattery")))
                                  (define d-opp (min (dist2d ux uy (car opp-main) (cdr opp-main))
                                                     (dist2d ux uy (car opp-nat) (cdr opp-nat))))
                                  (define d-own (min (dist2d ux uy (car main-xy) (cdr main-xy))
                                                     (dist2d ux uy (car nat-xy) (cdr nat-xy))))
                                  (when (and (<= d-opp 34.0) (< d-opp d-own))
                                    (define prev-fwd (hash-ref pid->fwd-protoss pid '()))
                                    (define cage-n
                                      (count (lambda (it)
                                               (and (hash-has-key? utag->type (car it))
                                                    (<= (dist2d ux uy (caddr it) (cadddr it)) 5.0)))
                                             prev-fwd))
                                    (hash-set! pid->fwd-protoss pid (cons (list utag uname ux uy gl) prev-fwd))
                                    (cond
                                      [(string=? uname "PhotonCannon")
                                       (if (>= cage-n 2)
                                           (emit-ev! "cannon_rush_walls_cancels_probe_push" "caged-cannon-wall" gl pid
                                                     (format "Caged PhotonCannon w/ ~a adjacent wall structures (~a tiles from enemy base)"
                                                             cage-n (round1 d-opp))
                                                     cage-n)
                                           (emit-ev! "cannon_rush_walls_cancels_probe_push" "forward-photon-cannon" gl pid
                                                     (format "Forward PhotonCannon (~a tiles from enemy base)" (round1 d-opp))
                                                     d-opp))]
                                      [(and (<= gl 4032)
                                            (or (>= cage-n 1)
                                                (> (hash-ref alive-counts (cons pid "Forge") 0) 0)))
                                       (emit-ev! "cannon_rush_walls_cancels_probe_push" "forward-cannon-rush-pylon-wall" gl pid
                                                 (format "Forward ~a wall/power wedge (~a tiles from enemy base, neighbors=~a)"
                                                         uname (round1 d-opp) cage-n)
                                                 d-opp)])))

                                ;; (1.8-3) Bunker placement (defensive natural vs bunker rush)
                                (when (and (= eid 6) (string=? uname "Bunker"))
                                  (define d-own-nat (dist2d ux uy (car nat-xy) (cdr nat-xy)))
                                  (define d-opp-nat (min (dist2d ux uy (car opp-main) (cdr opp-main))
                                                         (dist2d ux uy (car opp-nat) (cdr opp-nat))))
                                  (emit-ev! "bunker_load_repair_salvage" "bunker-placed" gl pid
                                            (if (< d-opp-nat d-own-nat)
                                                (format "Offensive Bunker rush (~a tiles from enemy base)" (round1 d-opp-nat))
                                                (format "Defensive Bunker (~a tiles from natural)" (round1 d-own-nat)))
                                            (min d-own-nat d-opp-nat)))

                                ;; (1.8-5) Missile Turret placement
                                (when (and (= eid 6) (string=? uname "MissileTurret"))
                                  (define d-base
                                    (for/fold ([best +inf.0]) ([b (in-list own-bs)])
                                      (min best (dist2d ux uy (car b) (cdr b)))))
                                  (emit-ev! "missile_turret_defense" "missile-turret-placed" gl pid
                                            (format "MissileTurret ~a tiles from nearest base" (round1 d-base))
                                            d-base))

                                ;; (1.8-6) Nydus Network & Nydus Worm emerging / multi-worm decoy
                                (when (and (= eid 6) (string=? uname "NydusNetwork"))
                                  (emit-ev! "nydus_worm_network_assault" "nydus-network-built" gl pid
                                            "NydusNetwork started" 1.0))
                                (when (member uname '("NydusCanal" "NydusWorm"))
                                  (define opp-d
                                    (for/fold ([best +inf.0]) ([b (in-list opp-bs)])
                                      (min best (dist2d ux uy (car b) (cdr b)))))
                                  (define prev-nw
                                    (filter (lambda (w) (<= (- gl (car w)) 672))
                                            (hash-ref pid->nydus-worms pid '())))
                                  (define decoy?
                                    (ormap (lambda (w) (> (dist2d ux uy (cadr w) (caddr w)) 18.0)) prev-nw))
                                  (hash-set! pid->nydus-worms pid (cons (list gl ux uy) prev-nw))
                                  (emit-ev! "nydus_worm_network_assault"
                                            (if decoy? "double-nydus-decoy" "nydus-worm-emerging")
                                            gl pid
                                            (format "~a emerging (~a tiles from enemy base~a)"
                                                    uname (round1 opp-d) (if decoy? ", multi-worm decoy" ""))
                                            opp-d))

                                ;; (1.8-7) Shield Battery placement
                                (when (and (= eid 6) (string=? uname "ShieldBattery"))
                                  (define d-own
                                    (for/fold ([best +inf.0]) ([b (in-list own-bs)])
                                      (min best (dist2d ux uy (car b) (cdr b)))))
                                  (define d-opp
                                    (for/fold ([best +inf.0]) ([b (in-list opp-bs)])
                                      (min best (dist2d ux uy (car b) (cdr b)))))
                                  (emit-ev! "shield_battery_nexus_overcharge" "shield-battery-placed" gl pid
                                            (if (< d-opp d-own)
                                                (format "Offensive proxy ShieldBattery (~a tiles from enemy base)" (round1 d-opp))
                                                (format "Defensive ShieldBattery (~a tiles from own Nexus)" (round1 d-own)))
                                            (min d-own d-opp)))))]

                           [(7) ; UnitDone
                            (define utag (+ (arithmetic-shift (hash-ref p 0 0) 18) (hash-ref p 1 0)))
                            (hash-set! utag->was-done utag #t)]

                           [(4) ; UnitTypeChange
                            (define utag (+ (arithmetic-shift (hash-ref p 0 0) 18) (hash-ref p 1 0)))
                            (define new-u (bytes->str (hash-ref p 2 #"")))
                            (define old-u (hash-ref utag->type utag #f))
                            (define pid (hash-ref utag->pid utag 0))
                            (when (and old-u (memv pid pids))
                              (inc-alive! pid old-u -1)
                              (inc-alive! pid new-u 1)
                              (hash-set! utag->type utag new-u)
                              (define xy (hash-ref utag->xy utag '(0.0 . 0.0)))
                              (define opp (if (= pid p1) p2 p1))
                              (define opp-bs (hash-ref pid->bases opp))
                              ;; Morph production bench updates
                              (when (and (string=? new-u "Ravager") (not (string=? old-u "RavagerBurrowed")))
                                (hash-update! prod-bench (cons pid 'ravager) add1 0))
                              (when (and (string=? new-u "LurkerMP") (not (string=? old-u "LurkerMPBurrowed")))
                                (hash-update! prod-bench (cons pid 'lurker-mp) add1 0))
                              (when (and (string=? new-u "Baneling") (not (string=? old-u "BanelingBurrowed")))
                                (hash-update! prod-bench (cons pid 'baneling) add1 0))
                              (when (string=? new-u "BroodLord")
                                (hash-update! prod-bench (cons pid 'brood-lord) add1 0))
                              (when (string=? new-u "Overseer")
                                (hash-update! prod-bench (cons pid 'overseer) add1 0))
                              (when (string=? new-u "OverlordTransport")
                                (hash-update! prod-bench (cons pid 'overlord-transport) add1 0))
                              (when (and (string=? old-u "Hellion") (string=? new-u "HellionTank"))
                                (hash-update! prod-bench (cons pid 'hellbat) add1 0)
                                (emit-ev! "unit-mode-and-spell-counters" "hellbat-combat-morph" gl pid "Hellion->Hellbat" 0.0))

                              ;; (1.8-4) Planetary Fortress morph
                              (when (and (string=? old-u "CommandCenter") (string=? new-u "PlanetaryFortress"))
                                (define d-main (dist2d (car xy) (cdr xy)
                                                       (caar (hash-ref pid->bases pid))
                                                       (cdar (hash-ref pid->bases pid))))
                                (emit-ev! "planetary_fortress_mass_repair" "planetary-fortress-morph" gl pid
                                          (format "CommandCenter->PlanetaryFortress (~a tiles from main)" (round1 d-main))
                                          d-main))

                              ;; (1.8-1) Spread burrowed Swarm Host arc
                              (when (string=? new-u "SwarmHostBurrowedMP")
                                (define active-shs
                                  (filter (lambda (st) (member (hash-ref utag->type st #f) '("SwarmHostMP" "SwarmHostBurrowedMP")))
                                          (hash-ref pid->sh-utags pid '())))
                                (hash-set! pid->sh-utags pid active-shs)
                                (define max-span
                                  (for/fold ([mx 0.0]) ([st (in-list active-shs)])
                                    (define sxy (hash-ref utag->xy st xy))
                                    (max mx (dist2d (car xy) (cdr xy) (car sxy) (cdr sxy)))))
                                (define opp-d
                                  (for/fold ([best +inf.0]) ([b (in-list opp-bs)])
                                    (min best (dist2d (car xy) (cdr xy) (car b) (cdr b)))))
                                (emit-ev! "spread_burrowed_swarm_host_harass" "swarm-host-burrow-arc" gl pid
                                          (format "SwarmHostBurrowedMP (~a tiles from enemy base, arc_span=~a)"
                                                  (round1 opp-d) (round1 max-span))
                                          (if (> max-span 0.0) max-span opp-d)))

                              ;; (1.8-8) Spine & Spore Crawler uproot / reposition root
                              (when (and (string=? old-u "SpineCrawler") (string=? new-u "SpineCrawlerUprooted"))
                                (hash-set! utag->crawler-uproot utag (list gl (car xy) (cdr xy)))
                                (emit-ev! "crawler_uproot_reposition" "spine-crawler-uproot" gl pid
                                          (format "SpineCrawler uprooted at (~a,~a)" (round1 (car xy)) (round1 (cdr xy)))
                                          1.0))
                              (when (and (string=? old-u "SporeCrawler") (string=? new-u "SporeCrawlerUprooted"))
                                (hash-set! utag->crawler-uproot utag (list gl (car xy) (cdr xy)))
                                (emit-ev! "crawler_uproot_reposition" "spore-crawler-uproot" gl pid
                                          (format "SporeCrawler uprooted at (~a,~a)" (round1 (car xy)) (round1 (cdr xy)))
                                          1.0))
                              (when (and (string=? old-u "SpineCrawlerUprooted") (string=? new-u "SpineCrawler"))
                                (define up-info (hash-ref utag->crawler-uproot utag #f))
                                (define rdist (if up-info (dist2d (cadr up-info) (caddr up-info) (car xy) (cdr xy)) 0.0))
                                (hash-remove! utag->crawler-uproot utag)
                                (emit-ev! "crawler_uproot_reposition" "spine-crawler-reposition-root" gl pid
                                          (format "SpineCrawler re-rooted (~a tiles repositioned)" (round1 rdist))
                                          rdist))
                              (when (and (string=? old-u "SporeCrawlerUprooted") (string=? new-u "SporeCrawler"))
                                (define up-info (hash-ref utag->crawler-uproot utag #f))
                                (define rdist (if up-info (dist2d (cadr up-info) (caddr up-info) (car xy) (cdr xy)) 0.0))
                                (hash-remove! utag->crawler-uproot utag)
                                (emit-ev! "crawler_uproot_reposition" "spore-crawler-reposition-root" gl pid
                                          (format "SporeCrawler re-rooted (~a tiles repositioned)" (round1 rdist))
                                          rdist))

                              ;; (4) Overseer Oversight mode (1912)
                              (when (string=? new-u "OverseerSiegeMode")
                                (emit-ev! "changeling-and-counter" "overseer-oversight" gl pid "Overseer->Oversight" 0.0))

                              ;; (5) Widow Mine burrow drop + runby sync
                              (when (string=? new-u "WidowMineBurrowed")
                                (define opp-d
                                  (for/fold ([best +inf.0]) ([b (in-list opp-bs)])
                                    (min best (dist2d (car xy) (cdr xy) (car b) (cdr b)))))
                                (when (<= opp-d 18.0)
                                  (hash-set! last-wm-drop-gl pid gl)
                                  (define rgl (or (hash-ref last-runby-gl pid #f)
                                                  (hash-ref midmap-clash-gl pid #f)))
                                  (if (and rgl (<= (abs (- gl rgl)) 448))
                                      (emit-ev! "multi-angle-drops-and-widow-mine-runby" "widow-mine-drop-with-runby" gl pid
                                                (format "WidowMine burrowed in enemy base synced w/ multi-prong (df=~af)" (abs (- gl rgl)))
                                                (abs (- gl rgl)))
                                      (emit-ev! "multi-angle-drops-and-widow-mine-runby" "widow-mine-drop" gl pid
                                                (format "WidowMine burrowed ~a tiles from enemy base" (round1 opp-d)) opp-d))))

                              ;; (6) Burrow down / up dodge & Burrowed Zergling expansion-pad block & (14) Baneling landmine
                              (when (and (string-suffix? new-u "Burrowed") (not (string-prefix? new-u "CreepTumor")) (not (string=? new-u "WidowMineBurrowed")))
                                (hash-set! burrow-down-gl utag gl)
                                (when (string=? new-u "ZerglingBurrowed")
                                  (define pad-d
                                    (for/fold ([best +inf.0]) ([c (in-list base-centroids)])
                                      (min best (dist2d (car xy) (cdr xy) (car c) (cdr c)))))
                                  (when (<= pad-d 9.5)
                                    (emit-ev! "burrow-dodge-and-ring-ambush" "burrowed-zergling-pad-block" gl pid
                                              (format "ZerglingBurrowed blocking expansion pad (d=~a)" (round1 pad-d)) pad-d)))
                                (when (string=? new-u "BanelingBurrowed")
                                  (emit-ev! "splitting-and-baneling-target-fire" "burrowed-baneling-landmine" gl pid
                                            "BanelingBurrowed landmine set" 0.0)))
                              (when (and (string-suffix? old-u "Burrowed") (not (string-suffix? new-u "Burrowed")))
                                (define bgl (hash-ref burrow-down-gl utag #f))
                                (when bgl
                                  (define dwell (- gl bgl))
                                  (emit-ev! "burrow-dodge-and-ring-ambush"
                                            (if (<= dwell 224) "reactive-burrow-dodge" "burrow-ring-ambush")
                                            gl pid (format "~a unburrowed after ~af" new-u dwell) dwell)))

                              ;; (13) Simultaneous / Multi-base Viking landings
                              (when (and (string=? old-u "VikingFighter") (string=? new-u "VikingAssault"))
                                (define prevs (filter (lambda (it) (<= (- gl (car it)) 112)) (hash-ref viking-land-gls pid '())))
                                (define multi-base?
                                  (ormap (lambda (it) (> (dist2d (car xy) (cdr xy) (cadr it) (caddr it)) 20.0)) prevs))
                                (hash-set! viking-land-gls pid (cons (list gl (car xy) (cdr xy)) prevs))
                                (emit-ev! "multi-base-viking-landings"
                                          (if multi-base? "simultaneous-multi-base-viking-landing" "viking-assault-landing")
                                          gl pid "VikingFighter->VikingAssault" (if multi-base? 2.0 1.0))))]

                           [(2) ; UnitDied
                            (define idx (hash-ref p 0 0))
                            (define rec (hash-ref p 1 0))
                            (define utag (+ (arithmetic-shift idx 18) rec))
                            (define u (hash-ref utag->type utag #f))
                            (define pid (hash-ref utag->pid utag 0))
                            (define kpid (hash-ref p 2 #f))
                            (define dx (exact->inexact (hash-ref p 3 0)))
                            (define dy (exact->inexact (hash-ref p 4 0)))
                            (define kidx (hash-ref p 5 #f))
                            (define krec (hash-ref p 6 #f))
                            (define ktag (and (exact-integer? kidx) (exact-integer? krec) (+ (arithmetic-shift kidx 18) krec)))
                            (define kunit (if ktag (hash-ref utag->type ktag "Unknown") "Unknown"))
                            ;; (#131) Neutral destructible rocks & collapsible rockslide clears
                            (when (and u (= pid 0) (memv kpid pids) (destructible-or-rockslide-unit? u))
                              (define rock-sub
                                (if (string-contains? u "Collapsible")
                                    "collapsible-rockslide-shatter"
                                    "destructible-rock-clear"))
                              (emit-ev! "coordinated-runbys" rock-sub gl kpid
                                        (format "~a cleared ~a at (~a,~a)" kunit u (round1 dx) (round1 dy))
                                        1.0))
                            (when (and u (memv pid pids))
                              (inc-alive! pid u -1)
                              (define opp (if (= pid p1) p2 p1))
                              (define own-bs (hash-ref pid->bases pid))
                              (define opp-bs (hash-ref pid->bases opp))
                              ;; (10) Cancel before death on in-progress structure + (1.8-2) Cannon rush tactical cancel
                              (when (and (hash-ref utag->was-init utag #f)
                                         (not (hash-ref utag->was-done utag #f))
                                         (or (not kpid) (= kpid pid))
                                         (not (member u '("Zealot" "Stalker" "Adept" "Sentry" "HighTemplar" "DarkTemplar"))))
                                (define dwell (- gl (hash-ref utag->born-gl utag gl)))
                                (emit-ev! "expansion-and-gas-blocks" "cancel-before-death" gl pid
                                          (format "Canceled in-progress ~a after ~af" u dwell) dwell)
                                (when (and (<= gl 6048)
                                           (member u '("Pylon" "PhotonCannon" "Gateway" "ShieldBattery" "Forge")))
                                  (define d-opp
                                    (for/fold ([best +inf.0]) ([b (in-list opp-bs)])
                                      (min best (dist2d dx dy (car b) (cdr b)))))
                                  (when (<= d-opp 34.0)
                                    (emit-ev! "cannon_rush_walls_cancels_probe_push" "cannon-rush-cancel-or-probe-push-wedge" gl pid
                                              (format "Canceled forward ~a after ~af (d_opp=~a)" u dwell (round1 d-opp))
                                              dwell))))
                              ;; (1.8-1) Counter Swarm Host hunted
                              (when (and (member u '("SwarmHostMP" "SwarmHostBurrowedMP")) (equal? kpid opp))
                                (emit-ev! "spread_burrowed_swarm_host_harass" "counter-swarm-host-hunted" gl opp
                                          (format "~a hunted ~a" kunit u) 1.0))
                              ;; (1.8-2) Counter cannon rush structure denied or Probe sniped
                              (when (and (<= gl 6048)
                                         (equal? kpid opp)
                                         (member u '("Pylon" "PhotonCannon" "ShieldBattery")))
                                (define d-opp-b
                                  (for/fold ([best +inf.0]) ([b (in-list opp-bs)])
                                    (min best (dist2d dx dy (car b) (cdr b)))))
                                (when (<= d-opp-b 34.0)
                                  (emit-ev! "cannon_rush_walls_cancels_probe_push" "counter-cannon-rush-bldg-denied" gl opp
                                            (format "~a denied forward ~a (~a)"
                                                    kunit u (if (hash-ref utag->was-done utag #f) "completed" "in-progress"))
                                            d-opp-b)))
                              (when (and (<= gl 4704)
                                         (equal? kpid opp)
                                         (string=? u "Probe")
                                         (pair? (hash-ref pid->fwd-protoss pid '())))
                                (define d-opp-b
                                  (for/fold ([best +inf.0]) ([b (in-list opp-bs)])
                                    (min best (dist2d dx dy (car b) (cdr b)))))
                                (when (<= d-opp-b 34.0)
                                  (emit-ev! "cannon_rush_walls_cancels_probe_push" "counter-cannon-probe-snipe" gl opp
                                            (format "~a sniped cannon-rush Probe" kunit) d-opp-b)))
                              ;; (1.8-3) Bunker self-salvage refund
                              (when (and (string=? u "Bunker")
                                         (hash-ref utag->was-done utag #f)
                                         (or (not kpid) (= kpid pid)))
                                (emit-ev! "bunker_load_repair_salvage" "bunker-salvage" gl pid
                                          "Completed Bunker salvaged (75% refund)" 75.0))
                              ;; (1.8-4) Planetary Fortress splash kill & counter-PF broken
                              (when (and (equal? kpid opp) (string=? kunit "PlanetaryFortress"))
                                (emit-ev! "planetary_fortress_mass_repair" "planetary-fortress-splash-kill" gl opp
                                          (format "PlanetaryFortress Ibiks cannon killed ~a" u) 1.0))
                              (when (and (string=? u "PlanetaryFortress") (equal? kpid opp))
                                (emit-ev! "planetary_fortress_mass_repair" "counter-planetary-fortress-broken" gl opp
                                          (format "~a broke PlanetaryFortress" kunit) 1.0))
                              ;; (1.8-5) Missile Turret air kill
                              (when (and (equal? kpid opp) (string=? kunit "MissileTurret"))
                                (emit-ev! "missile_turret_defense" "missile-turret-air-kill" gl opp
                                          (format "MissileTurret shot down ~a" u) 1.0))
                              ;; (1.8-6) Counter Nydus emerging head snipe vs active worm cleared
                              (when (and (member u '("NydusCanal" "NydusWorm")) (equal? kpid opp))
                                (define life (- gl (hash-ref utag->born-gl utag gl)))
                                (if (or (not (hash-ref utag->was-done utag #f)) (< life 340))
                                    (emit-ev! "nydus_worm_network_assault" "counter-nydus-emerging-head-snipe" gl opp
                                              (format "~a sniped emerging Nydus head in ~af (before unload)" kunit life)
                                              life)
                                    (emit-ev! "nydus_worm_network_assault" "counter-nydus-worm-cleared" gl opp
                                              (format "~a cleared active ~a after ~af" kunit u life)
                                              life)))
                              ;; (1.8-8) Counter uprooted Spine/Spore sniped
                              (when (and (member u '("SpineCrawlerUprooted" "SporeCrawlerUprooted")) (equal? kpid opp))
                                (emit-ev! "crawler_uproot_reposition" "counter-uprooted-crawler-snipe" gl opp
                                          (format "~a sniped unrooted ~a" kunit u) 1.0))
                              ;; (1.8-10) Enemy worker rush / drill-stack kills inside defender's base
                              (when (and (<= gl 6720)
                                         (equal? kpid opp)
                                         (member kunit '("Probe" "SCV" "Drone"))
                                         (not (member u NON-COMBAT-DEATHS)))
                                (define d-own
                                  (for/fold ([best +inf.0]) ([b (in-list own-bs)])
                                    (min best (dist2d dx dy (car b) (cdr b)))))
                                (when (<= d-own 22.0)
                                  (hash-update! worker-rush-kills opp add1 0)
                                  (unless (hash-has-key? worker-rush-first-gl opp)
                                    (hash-set! worker-rush-first-gl opp gl))
                                  (when (member u '("Hatchery" "Lair" "CommandCenter" "OrbitalCommand" "Nexus"
                                                    "SpawningPool" "Barracks" "Gateway" "SupplyDepot" "Pylon" "Bunker"))
                                    (hash-update! worker-rush-bldg-kills opp add1 0))))
                              ;; (3) Creep tumor cleared by opponent
                              (when (and (member u '("CreepTumorBurrowed" "CreepTumorQueen" "CreepTumor"))
                                         (equal? kpid opp))
                                (hash-update! tumor-cleared-cnt opp add1 0)
                                (emit-ev! "creep-spread-and-clearing" "detector-ranged-tumor-clear" gl opp
                                          (format "~a cleared CreepTumor" kunit) 1.0))
                              ;; (4) Counter-Changeling single-unit snipe
                              (when (and (string-prefix? u "Changeling") (equal? kpid opp))
                                (define life (- gl (hash-ref utag->born-gl utag gl)))
                                (emit-ev! "changeling-and-counter" "counter-changeling-snipe" gl opp
                                          (format "~a sniped ~a after ~af" kunit u life) life))
                              ;; (5/#130) WidowMine kill clump vs single-unit bait
                              (when (and ktag (member kunit '("WidowMineBurrowed" "WidowMine")) (equal? kpid opp))
                                (hash-update! wm-kill-frame-cnt (cons ktag (quotient gl 4)) add1 0))
                              ;; (15) Cyclone Lock-On kill vs tether break
                              (define lgl (hash-ref lockon-targets utag #f))
                              (when (and lgl (<= (- gl lgl) 320))
                                (hash-remove! lockon-targets utag))
                              ;; (2) Early unwalled opponent punish (< 3:30 = 4704f) & (8) Coordinated runby
                              (when (and (equal? kpid opp)
                                         (member u '("Drone" "SCV" "Probe"))
                                         (member kunit '("Zergling" "Baneling" "Adept" "Hellion" "Reaper" "Zealot")))
                                (define d-own
                                  (for/fold ([best +inf.0]) ([b (in-list own-bs)])
                                    (min best (dist2d dx dy (car b) (cdr b)))))
                                (when (<= d-own 22.0)
                                  (if (<= gl 4704)
                                      (hash-update! early-rush-kills opp add1 0)
                                      (let ()
                                        (hash-set! last-runby-gl opp gl)
                                        (define mgl (hash-ref midmap-clash-gl opp #f))
                                        (define wgl (hash-ref last-wm-drop-gl opp #f))
                                        (when (or (and mgl (<= (abs (- gl mgl)) 268))
                                                  (and wgl (<= (abs (- gl wgl)) 224)))
                                          (emit-ev! "coordinated-runbys" "multi-prong-runby" gl opp
                                                    (format "~a killed ~a during multi-prong window" kunit u) d-own))))))
                              ;; Track mid-map combat deaths (> 24 tiles from bases)
                              (when (and kpid (not (member u NON-COMBAT-DEATHS)))
                                (define min-b
                                  (for/fold ([best +inf.0]) ([b (in-list base-centroids)])
                                    (min best (dist2d dx dy (car b) (cdr b)))))
                                (when (> min-b 24.0)
                                  (hash-set! midmap-clash-gl p1 gl)
                                  (hash-set! midmap-clash-gl p2 gl))))
                            (hash-remove! utag->type utag)
                            (hash-remove! utag->xy utag)
                            (when (= (hash-ref idx->utag idx -1) utag)
                              (hash-remove! idx->utag idx))]

                           [(8) ; SUnitPositionsEvent (O(1) via idx->utag!)
                            (define first-idx (hash-ref p 0 0))
                            (define items (hash-ref p 1 '()))
                            (let ploop ([idx first-idx] [rem items])
                              (when (and (pair? rem) (pair? (cdr rem)) (pair? (cddr rem)))
                                (define nidx (+ idx (car rem)))
                                (define ut (hash-ref idx->utag nidx #f))
                                (when ut
                                  (hash-set! utag->xy ut (cons (exact->inexact (cadr rem))
                                                               (exact->inexact (caddr rem)))))
                                (ploop nidx (cdddr rem))))]))

                       (define (process-cmd! c)
                         (define gl (vector-ref c 0))
                         (define uid (vector-ref c 1))
                         (define pid (hash-ref uid->pid uid (add1 uid)))
                         (when (memv pid pids)
                           (define opp (if (= pid p1) p2 p1))
                           (define al (vector-ref c 3))
                           (define ac (vector-ref c 4))
                           (define cdata (vector-ref c 5))
                           (define dk (car cdata))
                           (define sel (vector-ref c 6))
                           (define sel-types
                             (remove-duplicates
                              (filter string? (for/list ([u (in-list sel)]) (hash-ref utag->type u #f)))))
                           (define tgt-utag (and (eq? dk 'unit) (cadr cdata)))
                           (define tgt-type (and tgt-utag (hash-ref utag->type tgt-utag #f)))
                           (define tgt-pid (and tgt-utag (hash-ref utag->pid tgt-utag #f)))
                           (define tgt-ally? (and tgt-pid (= tgt-pid pid)))
                           (define sp (classify-cmd bb al ac dk sel-types (player-owned-map pid) tgt-type tgt-ally?))
                           (when sp
                             (set! spell-casts (cons (list pid sp gl (or tgt-type "")) spell-casts))
                             ;; Record AoE spell for opponent split check
                             (when (memq sp '(ht-storm ravager-bile disruptor-nova ghost-emp infestor-fungal viper-cloud))
                               (hash-set! last-opp-aoe-gl opp (cons gl sp)))
                             (case sp
                               [(move-cmd)
                                (when (or (null? sel-types)
                                          (ormap (lambda (s) (member s '("Drone" "SCV" "Probe"))) sel-types))
                                  (hash-set! last-worker-move-gl pid gl))
                                ;; Check (14) delta-split vs enemy Banelings & (15) AoE split
                                (define prev-m (filter (lambda (g) (<= (- gl g) 34)) (hash-ref recent-move-gls pid '())))
                                (hash-set! recent-move-gls pid (cons gl prev-m))
                                (when (and (= (length prev-m) 3)
                                           (> (hash-ref alive-counts (cons opp "Baneling") 0) 0)
                                           (ormap (lambda (s) (member s '("Marine" "Zergling" "Hydralisk" "Drone" "SCV" "Probe" "Zealot" "Adept"))) sel-types))
                                  (emit-ev! "splitting-and-baneling-target-fire" "delta-split-vs-baneling" gl pid
                                            "4x rapid Move split vs active Banelings (<=1.5s)" (length prev-m)))
                                (define aoe (hash-ref last-opp-aoe-gl pid #f))
                                (when (and aoe (<= (- gl (car aoe)) 45) (= (length prev-m) 2))
                                  (emit-ev! "unit-mode-and-spell-counters" "aoe-dodge-split" gl pid
                                            (format "Multi-vector dodge split ~af after ~a" (- gl (car aoe)) (cdr aoe))
                                            (- gl (car aoe))))]
                               [(baneling-move-cmd)
                                (when (or (> (hash-ref alive-counts (cons opp "Marauder") 0) 0)
                                          (> (hash-ref alive-counts (cons opp "Immortal") 0) 0)
                                          (> (hash-ref alive-counts (cons opp "Roach") 0) 0)
                                          (> (hash-ref alive-counts (cons opp "Stalker") 0) 0))
                                  (emit-ev! "splitting-and-baneling-target-fire" "baneling-move-past-armored" gl pid
                                            "Baneling Move command past armored frontline" 1.0))]
                               [(baneling-explode)
                                (emit-ev! "splitting-and-baneling-target-fire" "baneling-manual-detonate" gl pid
                                          "Manual Baneling Explode" 1.0)]
                               [(target-fire-baneling)
                                (emit-ev! "splitting-and-baneling-target-fire" "target-fire-baneling" gl pid
                                          (format "~s target-fired Baneling" sel-types) 1.0)]
                               [(changeling-hold-pos)
                                (emit-ev! "changeling-and-counter" "changeling-hold-ramp-block" gl pid
                                          "Changeling HoldPosition command" 1.0)]
                               [(overseer-contaminate)
                                (emit-ev! "changeling-and-counter" "overseer-contaminate" gl pid
                                          (format "Contaminate on ~a" (or tgt-type "Structure")) 1.0)]
                               [(ov-unload ov-unload-moving ov-generate-creep)
                                (hash-set! last-ov-drop-gl pid gl)
                                (when (memq sp '(ov-unload ov-unload-moving))
                                  (emit-ev! "multi-angle-drops-and-widow-mine-runby" "overlord-transport-drop" gl pid
                                            (symbol->string sp) 1.0))]
                               [(medivac-load medivac-load-smart prism-load prism-load-smart ov-load ov-load-smart)
                                ;; (#131) Dropship combat rescue / pickup save > 24.0 tiles from own main/nat
                                (define rxy
                                  (cond
                                    [(and tgt-utag (hash-has-key? utag->xy tgt-utag))
                                     (hash-ref utag->xy tgt-utag)]
                                    [(pair? sel)
                                     (hash-ref utag->xy (car sel) #f)]
                                    [else #f]))
                                (when rxy
                                  (define own-bs (hash-ref pid->bases pid))
                                  (define main-xy (car own-bs))
                                  (define nat-xy (if (>= (length own-bs) 2) (cadr own-bs) main-xy))
                                  (define own-d (min (dist2d (car rxy) (cdr rxy) (car main-xy) (cdr main-xy))
                                                     (dist2d (car rxy) (cdr rxy) (car nat-xy) (cdr nat-xy))))
                                  (define prev-r (hash-ref last-rescue-gl pid -999))
                                  (when (and (> own-d 24.0) (> (- gl prev-r) 45))
                                    (hash-set! last-rescue-gl pid gl)
                                    (emit-ev! "multi-angle-drops-and-widow-mine-runby" "dropship-combat-rescue" gl pid
                                              (format "Dropship pickup rescue (~a) ~a tiles from home" sp (round1 own-d))
                                              own-d)))]
                               [(medivac-unload medivac-unload-moving prism-unload prism-unload-moving)
                                (define dx (if (eq? dk 'point) (cadr cdata) 0.0))
                                (define dy (if (eq? dk 'point) (caddr cdata) 0.0))
                                (define prev-ds (filter (lambda (d) (<= (- gl (car d)) 224)) (hash-ref last-drop-evs pid '())))
                                (when (and (> dx 0.0)
                                           (ormap (lambda (d) (and (> (cadr d) 0.0) (> (dist2d dx dy (cadr d) (caddr d)) 24.0))) prev-ds))
                                  (emit-ev! "multi-angle-drops-and-widow-mine-runby" "multi-angle-simultaneous-drop" gl pid
                                            (format "Dual drop >24 tiles apart (~a)" sp) 2.0))
                                (hash-set! last-drop-evs pid (cons (list gl dx dy sp) prev-ds))]
                               [(widow-mine-retarget)
                                (emit-ev! "multi-angle-drops-and-widow-mine-runby" "widow-mine-manual-retarget" gl pid
                                          (format "WidowMineAttack retarget -> ~a" (or tgt-type "Unit")) 1.0)]
                               [(adept-shade)
                                (emit-ev! "multi-base-adept-harass" "adept-phase-shift" gl pid "AdeptPhaseShift cast" 1.0)]
                               [(adept-shade-cancel)
                                (emit-ev! "multi-base-adept-harass" "adept-shade-cancel" gl pid "AdeptPhaseShift canceled" 1.0)]
                               [(raven-aam)
                                (emit-ev! "raven-harass" "anti-armor-missile" gl pid
                                          (format "Anti-Armor Missile -> ~a" (or tgt-type "Army")) 1.0)]
                               [(oracle-beam-on)
                                (for ([u (in-list sel)]) (hash-set! oracle-beam-gl u gl))]
                               [(oracle-beam-off)
                                (for ([u (in-list sel)])
                                  (define bgl (hash-ref oracle-beam-gl u #f))
                                  (when (and bgl (> gl bgl) (<= (- gl bgl) 1344))
                                    (emit-ev! "oracle-harass" "pulsar-beam-dwell" gl pid
                                              (format "PulsarBeam active dwell ~af" (- gl bgl)) (- gl bgl))
                                    (hash-remove! oracle-beam-gl u)))]
                               [(oracle-revelation)
                                (emit-ev! "oracle-harass" "oracle-revelation" gl pid "OracleRevelation cast" 1.0)]
                               [(cyclone-lock-on)
                                (when tgt-utag (hash-set! lockon-targets tgt-utag gl))
                                (emit-ev! "unit-mode-and-spell-counters" "cyclone-lock-on" gl pid
                                          (format "LockOn -> ~a" (or tgt-type "Unit")) 1.0)]
                               [(nexus-strategic-recall)
                                (define rx (if (eq? dk 'point) (cadr cdata) 0.0))
                                (define ry (if (eq? dk 'point) (caddr cdata) 0.0))
                                (define main-xy (car (hash-ref pid->bases pid)))
                                (define rdist (if (> rx 0.0) (dist2d rx ry (car main-xy) (cdr main-xy)) 0.0))
                                (emit-ev! "unit-mode-and-spell-counters" "nexus-strategic-recall" gl pid
                                          (format "Nexus StrategicRecall (~a tiles from main)" (round1 rdist))
                                          rdist)]
                               [(nexus-energy-recharge)
                                (emit-ev! "unit-mode-and-spell-counters" "nexus-energy-recharge" gl pid
                                          (format "Nexus EnergyRecharge -> ~a" (or tgt-type "Caster")) 1.0)
                                (emit-ev! "shield_battery_nexus_overcharge" "nexus-energy-recharge" gl pid
                                          (format "Nexus EnergyRecharge -> ~a" (or tgt-type "Caster")) 1.0)]
                               [(battery-overcharge)
                                (emit-ev! "unit-mode-and-spell-counters" "nexus-energy-recharge" gl pid
                                          "Nexus Battery Overcharge -> ShieldBattery" 1.0)
                                (emit-ev! "shield_battery_nexus_overcharge" "nexus-battery-overcharge" gl pid
                                          "Nexus Battery Overcharge -> ShieldBattery" 1.0)]
                               [(battery-recharge)
                                (emit-ev! "shield_battery_nexus_overcharge" "shield-battery-restore" gl pid
                                          (format "ShieldBattery restore -> ~a" (or tgt-type "Unit")) 1.0)]
                               [(mothership-mass-recall)
                                (emit-ev! "unit-mode-and-spell-counters" "mothership-mass-recall" gl pid
                                          "Mothership MassRecall cast" 1.0)]
                               [(mothership-time-warp)
                                (emit-ev! "unit-mode-and-spell-counters" "mothership-time-warp" gl pid
                                          "Mothership TemporalField (TimeWarp) cast" 1.0)]
                               ;; Wave 1.8 (#137) command handlers
                               [(swarmhost-locusts)
                                (define prev-sl (hash-ref last-sh-locust-gl pid #f))
                                (define df (if prev-sl (- gl prev-sl) 0))
                                (hash-set! last-sh-locust-gl pid gl)
                                (emit-ev! "spread_burrowed_swarm_host_harass" "spawn-locusts-stagger" gl pid
                                          (if (and prev-sl (> df 0) (<= df 448))
                                              (format "Staggered SpawnLocusts cast (df=~af after prior wave)" df)
                                              "SpawnLocustsTargeted wave cast")
                                          df)]
                               [(locust-swoop)
                                (define sx (if (eq? dk 'point) (cadr cdata) 0.0))
                                (define sy (if (eq? dk 'point) (caddr cdata) 0.0))
                                (define opp-bs (hash-ref pid->bases opp))
                                (define opp-d
                                  (if (> sx 0.0)
                                      (for/fold ([best +inf.0]) ([b (in-list opp-bs)])
                                        (min best (dist2d sx sy (car b) (cdr b))))
                                      0.0))
                                (emit-ev! "spread_burrowed_swarm_host_harass" "locust-swoop-strike" gl pid
                                          (format "LocustMPFlyingSwoop strike (~a tiles from enemy base)" (round1 opp-d))
                                          opp-d)]
                               [(bunker-load)
                                (define prev-bl (hash-ref last-bunker-load-gl pid -999))
                                (when (> (- gl prev-bl) 8)
                                  (hash-set! last-bunker-load-gl pid gl)
                                  (emit-ev! "bunker_load_repair_salvage" "bunker-bio-load" gl pid
                                            (format "Bio loaded into Bunker (~s)" sel-types)
                                            (max 1 (length sel))))]
                               [(bunker-unload)
                                (emit-ev! "bunker_load_repair_salvage" "bunker-bio-unload" gl pid
                                          "Bunker bio unload" 1.0)]
                               [(bunker-salvage)
                                (emit-ev! "bunker_load_repair_salvage" "bunker-salvage" gl pid
                                          "Bunker Salvage command" 75.0)]
                               [(scv-repair)
                                (define n-scvs
                                  (max 1 (count (lambda (u) (equal? (hash-ref utag->type u #f) "SCV")) sel)))
                                (cond
                                  [(equal? tgt-type "Bunker")
                                   (emit-ev! "bunker_load_repair_salvage" "bunker-scv-repair" gl pid
                                             (format "~a SCV(s) repairing Bunker" n-scvs) n-scvs)]
                                  [(equal? tgt-type "PlanetaryFortress")
                                   (define prev-pfr (hash-ref last-pf-repair-gl pid -999))
                                   (when (> (- gl prev-pfr) 16)
                                     (hash-set! last-pf-repair-gl pid gl)
                                     (emit-ev! "planetary_fortress_mass_repair" "planetary-fortress-scv-mass-repair" gl pid
                                               (format "~a SCV(s) mass-repairing PlanetaryFortress" n-scvs) n-scvs))]
                                  [(equal? tgt-type "MissileTurret")
                                   (emit-ev! "missile_turret_defense" "missile-turret-scv-repair" gl pid
                                             (format "~a SCV(s) repairing MissileTurret" n-scvs) n-scvs)])]
                               [(nydus-load)
                                (define prev-nl (hash-ref last-nydus-load-gl pid -999))
                                (when (> (- gl prev-nl) 16)
                                  (hash-set! last-nydus-load-gl pid gl)
                                  (emit-ev! "nydus_worm_network_assault" "nydus-load-army" gl pid
                                            (format "Loaded army into ~a (~s)" (or tgt-type "Nydus") sel-types)
                                            (max 1 (length sel))))]
                               [(nydus-unload)
                                (emit-ev! "nydus_worm_network_assault" "nydus-unload-assault" gl pid
                                          (format "NydusWorm unload assault (~a)" (or tgt-type "NydusCanal")) 1.0)]
                               [(worker-gather worker-return)
                                ;; (a) Frame 0..168 (0..7.5s) game-start worker mineral splits
                                (when (and (eq? sp 'worker-gather) (<= gl 168) tgt-utag)
                                  (hash-update! f0-split-cmds pid add1 0)
                                  (set-add! (hash-ref f0-split-patches pid) tgt-utag)
                                  (unless (hash-has-key? f0-first-split-gl pid)
                                    (hash-set! f0-first-split-gl pid gl)))
                                ;; (b) Close-patch speed-mining decel-bypass (Move -> Gather/Return within 1..28f)
                                (define wmgl (hash-ref last-worker-move-gl pid #f))
                                (when (and wmgl (>= (- gl wmgl) 1) (<= (- gl wmgl) 28))
                                  (hash-remove! last-worker-move-gl pid)
                                  (hash-update! speed-mine-cnt pid add1 0)
                                  (define prev-sm (hash-ref last-speed-mine-ev-gl pid -999))
                                  (when (> (- gl prev-sm) 336)
                                    (hash-set! last-speed-mine-ev-gl pid gl)
                                    (emit-ev! "game_start_worker_split_and_stacking" "speed-mining-decel-bypass" gl pid
                                              (format "Speed-mining Move+~a decel-bypass (dt=~af)" sp (- gl wmgl))
                                              (- gl wmgl))))
                                ;; (c) Mineral-walk worker drill-stacking (enemy mineral patch or >=5 workers stacked onto 1 patch in combat)
                                (when (and (eq? sp 'worker-gather) tgt-utag (> gl 112))
                                  (define txy (hash-ref utag->xy tgt-utag #f))
                                  (define n-wk
                                    (count (lambda (u) (member (hash-ref utag->type u #f) '("Drone" "SCV" "Probe"))) sel))
                                  (when txy
                                    (define own-main (car (hash-ref pid->bases pid)))
                                    (define opp-bs (hash-ref pid->bases opp))
                                    (define opp-d
                                      (for/fold ([best +inf.0]) ([b (in-list opp-bs)])
                                        (min best (dist2d (car txy) (cdr txy) (car b) (cdr b)))))
                                    (define own-d (dist2d (car txy) (cdr txy) (car own-main) (cdr own-main)))
                                    (when (or (and (<= opp-d 18.0) (> own-d 30.0))
                                              (and (>= n-wk 6) (> gl 672)))
                                      (hash-update! drill-stack-cmd-cnt pid add1 0)
                                      (define prev-ds (hash-ref last-drill-stack-gl pid -999))
                                      (when (> (- gl prev-ds) 168)
                                        (hash-set! last-drill-stack-gl pid gl)
                                        (emit-ev! "game_start_worker_split_and_stacking" "worker-mineral-walk-drill-stack" gl pid
                                                  (if (<= opp-d 18.0)
                                                      (format "Mineral-walk worker drill-stack on enemy mineral patch (d_opp=~a, sel=~a)"
                                                              (round1 opp-d) (max 1 n-wk))
                                                      (format "~a workers mineral-walk drill-stacked onto single patch" n-wk))
                                                  (if (<= opp-d 18.0) opp-d n-wk))))))]))))

                       ;; Chronological merge-step with minute benchmark hooks
                       (let step-loop ([tevs evs] [gcmds raw-cmds])
                         (define next-gl
                           (cond
                             [(and (null? tevs) (null? gcmds)) +inf.0]
                             [(null? gcmds) (caar tevs)]
                             [(null? tevs) (vector-ref (car gcmds) 0)]
                             [else (min (caar tevs) (vector-ref (car gcmds) 0))]))
                         (let mloop ()
                           (when (and (pair? pending-mins)
                                      (>= next-gl (* (car pending-mins) 60 22.4)))
                             (define m (car pending-mins))
                             (set! pending-mins (cdr pending-mins))
                             (when (>= max-gl (- (* m 60 22.4) 112))
                               (take-minute-snapshot! m))
                             (mloop)))
                         (cond
                           [(and (null? tevs) (null? gcmds)) (void)]
                           [(null? gcmds) (process-trk! (car tevs)) (step-loop (cdr tevs) gcmds)]
                           [(null? tevs) (process-cmd! (car gcmds)) (step-loop tevs (cdr gcmds))]
                           [(<= (caar tevs) (vector-ref (car gcmds) 0))
                            (process-trk! (car tevs))
                            (step-loop (cdr tevs) gcmds)]
                           [else
                            (process-cmd! (car gcmds))
                            (step-loop tevs (cdr gcmds))]))

                       ;; Post-game summary checks for (1) Walling, (2) Unwalled punish, (3) Multi-highway creep,
                       ;; (5/#130) WidowMine single-unit bait vs clump splash, and (15) Cyclone tether breaks!
                       (for ([pid (in-list pids)])
                         (define opp (if (= pid p1) p2 p1))
                         (define wm-cnt (hash-ref early-wall-main pid 0))
                         (define wn-cnt (hash-ref early-wall-nat pid 0))
                         (when (and (member (hash-ref pid->race pid) '("P" "T"))
                                    (or (> wm-cnt 0) (> wn-cnt 0)))
                           (if (hash-ref pid->is-random opp #f)
                               (emit-ev! "random-main-walling"
                                         (if (>= wm-cnt wn-cnt) "vs-random-main-ramp-wall" "vs-random-natural-wall")
                                         2240 pid (format "vs Random wall: main=~a, nat=~a" wm-cnt wn-cnt) wm-cnt)
                               (emit-ev! "random-main-walling"
                                         (if (> wn-cnt wm-cnt) "standard-natural-choke-wall" "standard-main-ramp-wall")
                                         2240 pid (format "vs ~a wall: main=~a, nat=~a" (hash-ref pid->race opp) wm-cnt wn-cnt) wn-cnt)))
                         (define rk (hash-ref early-rush-kills pid 0))
                         (define opp-wall (+ (hash-ref early-wall-main opp 0) (hash-ref early-wall-nat opp 0)))
                         (when (and (>= rk 2) (< opp-wall 2))
                           (emit-ev! "unwalled-opponent-punish" "early-flood-vs-unwalled" 4032 pid
                                     (format "~a early worker kills <3:30 vs unwalled opp (wall=~a)" rk opp-wall) rk))
                         (define n-hwy (length (hash-ref tumor-angles pid '())))
                         (when (>= n-hwy 2)
                           (emit-ev! "creep-spread-and-clearing" "multi-highway-creep-spread" 6720 pid
                                     (format "~a creep highways (queen_tumors=~a, spread=~a)"
                                             n-hwy (hash-ref tumor-queen-cnt pid 0) (hash-ref tumor-spread-cnt pid 0))
                                     n-hwy)))

                       (for ([(k kills) (in-hash wm-kill-frame-cnt)])
                         (define kpid (hash-ref utag->pid (car k) p1))
                         (define gl (* (cdr k) 4))
                         (if (= kills 1)
                             (emit-ev! "multi-angle-drops-and-widow-mine-runby" "widow-mine-single-unit-bait" gl
                                       (if (= kpid p1) p2 p1) "Single unit triggered WidowMine shot alone (1 casualty)" 1.0)
                             (emit-ev! "multi-angle-drops-and-widow-mine-runby" "widow-mine-clump-splash" gl
                                       (if (memv kpid pids) kpid p1) (format "WidowMine splash killed ~a units" kills) kills)))

                       (for ([(tutag lgl) (in-hash lockon-targets)])
                         (define tpid (hash-ref utag->pid tutag p1))
                         (when (memv tpid pids)
                           (emit-ev! "unit-mode-and-spell-counters" "cyclone-lock-on-tether-break" lgl tpid
                                     "Target survived Cyclone Lock-On via tether break" 1.0)))

                       ;; Wave 1.8 (#137) post-game SimCity layout stats + Frame-0 worker split + worker drill-stack rush!
                       (define simcity-samples '())
                       (define worker-split-samples '())
                       (for ([pid (in-list pids)])
                         (define race (hash-ref pid->race pid))
                         (define own-bs (hash-ref pid->bases pid))
                         (define main-xy (car own-bs))
                         (define nat-xy (if (>= (length own-bs) 2) (cadr own-bs) main-xy))
                         (define structs (reverse (hash-ref pid->structures pid '())))

                         ;; (1.8-10) Frame-0 worker split & worker drill-stack all-in rush
                         (define scmds (hash-ref f0-split-cmds pid 0))
                         (define spatches (set-count (hash-ref f0-split-patches pid)))
                         (define sfirst (hash-ref f0-first-split-gl pid 0))
                         (define smcnt (hash-ref speed-mine-cnt pid 0))
                         (define dscnt (hash-ref drill-stack-cmd-cnt pid 0))
                         (define wrk (hash-ref worker-rush-kills pid 0))
                         (define wrbk (hash-ref worker-rush-bldg-kills pid 0))
                         (when (and (>= scmds 2) (>= spatches 2))
                           (emit-ev! "game_start_worker_split_and_stacking" "frame0-worker-mineral-split" sfirst pid
                                     (format "Game-start worker split: ~a gather cmds across ~a distinct mineral patches (first=f~a)"
                                             scmds spatches sfirst)
                                     spatches))
                         (when (or (>= wrk 3) (>= wrbk 1))
                           (define wrgl (hash-ref worker-rush-first-gl pid 1460))
                           (emit-ev! "game_start_worker_split_and_stacking" "worker-drill-stack-all-in-rush" wrgl pid
                                     (format "All-in worker drill-stack rush: ~a kills in enemy base (~a key structures destroyed, drill_cmds=~a)"
                                             wrk wrbk dscnt)
                                     wrk))
                         (when (string=? corpus-name "pro_corpus")
                           (set! worker-split-samples
                                 (cons (hasheq 'race race
                                               'f0_split_cmds scmds
                                               'f0_distinct_patches spatches
                                               'f0_first_frame sfirst
                                               'speed_mine_seqs smcnt
                                               'drill_stack_cmds dscnt)
                                       worker-split-samples)))

                         ;; (1.8-9) Race-specific SimCity geometric metrics
                         (cond
                           [(string=? race "T")
                            (define prods
                              (filter (lambda (s)
                                        (and (member (cadr s) '("Barracks" "Factory" "Starport"))
                                             (<= (dist2d (caddr s) (cadddr s) (car main-xy) (cdr main-xy)) 30.0)))
                                      structs))
                            (define addons
                              (filter (lambda (s)
                                        (member (cadr s) '("BarracksTechLab" "BarracksReactor"
                                                           "FactoryTechLab" "FactoryReactor"
                                                           "StarportTechLab" "StarportReactor")))
                                      structs))
                            (define depots
                              (filter (lambda (s)
                                        (and (member (cadr s) '("SupplyDepot" "SupplyDepotLowered"))
                                             (<= (dist2d (caddr s) (cadddr s) (car main-xy) (cdr main-xy)) 28.0)))
                                      structs))
                            (define nn-dists '())
                            (define nn-dxs '())
                            (define nn-dys '())
                            (for ([b1 (in-list prods)])
                              (define best-b2 #f)
                              (define best-d +inf.0)
                              (for ([b2 (in-list prods)] #:unless (= (car b1) (car b2)))
                                (define d (dist2d (caddr b1) (cadddr b1) (caddr b2) (cadddr b2)))
                                (when (< d best-d)
                                  (set! best-d d)
                                  (set! best-b2 b2)))
                              (when (and best-b2 (<= best-d 14.0))
                                (set! nn-dists (cons best-d nn-dists))
                                (set! nn-dxs (cons (abs (- (caddr b1) (caddr best-b2))) nn-dxs))
                                (set! nn-dys (cons (abs (- (cadddr b1) (cadddr best-b2))) nn-dys))))
                            (define east-addons
                              (count (lambda (ad)
                                       (ormap (lambda (pr)
                                                (define dx (- (caddr ad) (caddr pr)))
                                                (define dy (- (cadddr ad) (cadddr pr)))
                                                (and (>= dx 1.5) (<= dx 3.5) (>= dy -1.5) (<= dy 0.5)))
                                              prods))
                                     addons))
                            (define depot-dists
                              (map (lambda (dp) (dist2d (caddr dp) (cadddr dp) (car main-xy) (cdr main-xy))) depots))
                            (when (>= (length prods) 3)
                              (define med-nn (if (pair? nn-dists) (hash-ref (stats-hash nn-dists) 'median) 6.0))
                              (emit-ev! "pro_simcity_layout_stats" "terran-production-matrix-simcity"
                                        (list-ref (last prods) 4) pid
                                        (format "Terran matrix: ~a prod bldgs, nn_med=~a tiles, east_addons=~a/~a, depots=~a"
                                                (length prods) med-nn east-addons (length addons) (length depots))
                                        med-nn)
                              (when (string=? corpus-name "pro_corpus")
                                (set! simcity-samples
                                      (cons (hasheq 'race "T"
                                                    'prod_count (length prods)
                                                    'nn_dists nn-dists
                                                    'nn_dxs nn-dxs
                                                    'nn_dys nn-dys
                                                    'east_addons east-addons
                                                    'total_addons (length addons)
                                                    'depot_main_dists depot-dists)
                                            simcity-samples))))]

                           [(string=? race "P")
                            (define pylons
                              (filter (lambda (s)
                                        (and (string=? (cadr s) "Pylon")
                                             (<= (min (dist2d (caddr s) (cadddr s) (car main-xy) (cdr main-xy))
                                                      (dist2d (caddr s) (cadddr s) (car nat-xy) (cdr nat-xy)))
                                                 38.0)))
                                      structs))
                            (define pwr-bldgs
                              (filter (lambda (s)
                                        (and (member (cadr s) '("Gateway" "WarpGate" "CyberneticsCore" "Forge"
                                                                "TwilightCouncil" "Stargate" "RoboticsFacility"
                                                                "RoboticsBay" "FleetBeacon" "TemplarArchive" "DarkShrine"))
                                             (<= (min (dist2d (caddr s) (cadddr s) (car main-xy) (cdr main-xy))
                                                      (dist2d (caddr s) (cadddr s) (car nat-xy) (cdr nat-xy)))
                                                 38.0)))
                                      structs))
                            (define dual-cnt
                              (count (lambda (pb)
                                       (>= (count (lambda (py)
                                                    (<= (dist2d (caddr pb) (cadddr pb) (caddr py) (cadddr py)) 6.5))
                                                  pylons)
                                           2))
                                     pwr-bldgs))
                            (define pylon-nn
                              (filter (lambda (d) (<= d 10.0))
                                      (for/list ([p1* (in-list pylons)] #:when (> (length pylons) 1))
                                        (for/fold ([best +inf.0]) ([p2* (in-list pylons)] #:unless (= (car p1*) (car p2*)))
                                          (min best (dist2d (caddr p1*) (cadddr p1*) (caddr p2*) (cadddr p2*)))))))
                            (define gates (filter (lambda (s) (member (cadr s) '("Gateway" "WarpGate"))) pwr-bldgs))
                            (define gate-nn
                              (filter (lambda (d) (<= d 10.0))
                                      (for/list ([g1 (in-list gates)] #:when (> (length gates) 1))
                                        (for/fold ([best +inf.0]) ([g2 (in-list gates)] #:unless (= (car g1) (car g2)))
                                          (min best (dist2d (caddr g1) (cadddr g1) (caddr g2) (cadddr g2)))))))
                            (define hi-tech
                              (filter (lambda (s)
                                        (member (cadr s) '("DarkShrine" "TemplarArchive" "TwilightCouncil"
                                                           "Stargate" "FleetBeacon" "RoboticsBay")))
                                      pwr-bldgs))
                            (define rear-tech-cnt
                              (count (lambda (ht)
                                       (<= (dist2d (caddr ht) (cadddr ht) (car main-xy) (cdr main-xy))
                                           (dist2d (caddr ht) (cadddr ht) (car nat-xy) (cdr nat-xy))))
                                     hi-tech))
                            (when (>= (length pwr-bldgs) 3)
                              (define dual-pct (round1 (* 100.0 (/ dual-cnt (max 1 (length pwr-bldgs))))))
                              (emit-ev! "pro_simcity_layout_stats" "protoss-dual-pylon-matrix-simcity"
                                        (list-ref (last pwr-bldgs) 4) pid
                                        (format "Protoss matrix: ~a/~a bldgs dual-Pylon powered (~a%), pylons=~a, rear_tech=~a/~a"
                                                dual-cnt (length pwr-bldgs) dual-pct (length pylons) rear-tech-cnt (length hi-tech))
                                        dual-pct)
                              (when (string=? corpus-name "pro_corpus")
                                (set! simcity-samples
                                      (cons (hasheq 'race "P"
                                                    'pwr_count (length pwr-bldgs)
                                                    'dual_powered_pct dual-pct
                                                    'pylon_nn_dists pylon-nn
                                                    'gate_nn_dists gate-nn
                                                    'rear_tech_cnt rear-tech-cnt
                                                    'hi_tech_cnt (length hi-tech))
                                            simcity-samples))))]

                           [(string=? race "Z")
                            (define z-tech
                              (filter (lambda (s)
                                        (and (member (cadr s) '("SpawningPool" "BanelingNest" "HydraliskDen"
                                                                "LurkerDenMP" "Spire" "GreaterSpire"
                                                                "InfestationPit" "UltraliskCavern"))
                                             (<= (dist2d (caddr s) (cadddr s) (car main-xy) (cdr main-xy)) 24.0)))
                                      structs))
                            (define z-choke
                              (filter (lambda (s)
                                        (and (member (cadr s) '("EvolutionChamber" "RoachWarren" "SpineCrawler"))
                                             (<= (dist2d (caddr s) (cadddr s) (car nat-xy) (cdr nat-xy)) 22.0)))
                                      structs))
                            (define z-spores
                              (filter (lambda (s) (string=? (cadr s) "SporeCrawler")) structs))
                            (define tech-main-dists
                              (map (lambda (s) (dist2d (caddr s) (cadddr s) (car main-xy) (cdr main-xy))) z-tech))
                            (define tech-res-dists
                              (for/list ([s (in-list z-tech)] #:when (pair? f0-res))
                                (for/fold ([best +inf.0]) ([r (in-list f0-res)])
                                  (min best (dist2d (caddr s) (cadddr s) (car r) (cdr r))))))
                            (define spore-res-dists
                              (for/list ([s (in-list z-spores)] #:when (pair? f0-res))
                                (for/fold ([best +inf.0]) ([r (in-list f0-res)])
                                  (min best (dist2d (caddr s) (cadddr s) (car r) (cdr r))))))
                            (when (>= (length z-tech) 2)
                              (define med-tm (hash-ref (stats-hash tech-main-dists) 'median))
                              (emit-ev! "pro_simcity_layout_stats" "zerg-mineral-pocket-and-choke-simcity"
                                        (list-ref (last z-tech) 4) pid
                                        (format "Zerg pocket SimCity: ~a tech bldgs (d_main_med=~a), nat_choke_bldgs=~a, spores=~a"
                                                (length z-tech) med-tm (length z-choke) (length z-spores))
                                        med-tm)
                              (when (string=? corpus-name "pro_corpus")
                                (set! simcity-samples
                                      (cons (hasheq 'race "Z"
                                                    'tech_count (length z-tech)
                                                    'tech_main_dists tech-main-dists
                                                    'tech_res_dists tech-res-dists
                                                    'nat_choke_count (length z-choke)
                                                    'spore_res_dists spore-res-dists)
                                            simcity-samples))))]))

                       (hasheq 'corpus corpus-name
                               'replay rel-path
                               'map map-name
                               'base_build bb
                               'loops max-gl
                               'cmd_decoded (pair? raw-cmds)
                               'matchup (string-append (hash-ref pid->race p1) "v" (hash-ref pid->race p2))
                               'p1_random (hash-ref pid->is-random p1 #f)
                               'p2_random (hash-ref pid->is-random p2 #f)
                               'events (reverse events-out)
                               'spells (reverse spell-casts)
                               'min_snaps min-snaps
                               'simcity_samples simcity-samples
                               'worker_split_samples worker-split-samples))))))))

;; -----------------------------------------------------------------------------
;; 7. Build 3-Tactics-Per-Spell-Ability Catalog (`#130`) & 9-Matchup Benchmarks
;; -----------------------------------------------------------------------------

(define (build-3-tactics-catalog spell-counts)
  (define (sc sym) (hash-ref spell-counts sym 0))
  (hasheq
   'Queen
   (list (hasheq 'mode "larva-inject-cadence" 'ability_id 251 'observed_casts (sc 'queen-inject)
                 'first_clock_med "2:37" 'trigger "TownHall missing inject buff & energy >= 25")
         (hasheq 'mode "multi-highway-and-dropperlord-creep" 'ability_id 1694 'observed_casts (sc 'queen-creep-tumor)
                 'first_clock_med "3:13" 'trigger "Dedicated Creep Queen energy >= 25 or Dropperlord unload on remote pad")
         (hasheq 'mode "frontline-transfuse-save" 'ability_id 1664 'observed_casts (sc 'queen-transfuse)
                 'first_clock_med "7:26" 'trigger "Ally Queen/Ultralisk/BroodLord/Roach/Lurker missing >= 75 HP within 7.0 tiles"))
   'Overseer
   (list (hasheq 'mode "changeling-scout-and-ramp-hold" 'ability_id 181 'observed_casts (sc 'overseer-changeling)
                 'first_clock_med "5:45" 'trigger "Energy >= 50 -> spawn Changeling + HoldPosition (18) in enemy ramp gap")
         (hasheq 'mode "contaminate-research-and-tech-freeze" 'ability_id 182 'observed_casts (sc 'overseer-contaminate)
                 'first_clock_med "9:10" 'trigger "Energy >= 125 (or >= 95 approaching enemy tech) -> freeze active Forge/Twilight/TechLab/Robo")
         (hasheq 'mode "oversight-siege-vision-ring" 'ability_id 1912 'observed_casts (sc 'overseer-oversight)
                 'first_clock_med "8:20" 'trigger "Anchor stationary +25% detection ring behind Lurker/Hydra siege line"))
   'Ravager
   (list (hasheq 'mode "fungal-rooted-guaranteed-bile" 'ability_id 2338 'observed_casts (sc 'ravager-bile)
                 'first_clock_med "8:09" 'trigger "Enemy cluster carries Fungal Growth root -> fire within 20f (0.89s) before 67f root ends")
         (hasheq 'mode "immobile-siege-and-forcefield-breaker" 'ability_id 2338 'observed_casts (sc 'ravager-bile)
                 'first_clock_med "8:09" 'trigger "SiegeTankSieged / LiberatorAG / LurkerBurrowed / WarpPrismPhasing / ForceField / PhotonCannon")
         (hasheq 'mode "staggered-choke-zoning-volley" 'ability_id 2338 'observed_casts (sc 'ravager-bile)
                 'first_clock_med "8:09" 'trigger "28f (1.25s) staggered Biles on retreating ramp/choke vectors"))
   'Infestor
   (list (hasheq 'mode "fungal-clump-root-and-reveal" 'ability_id 74 'observed_casts (sc 'infestor-fungal)
                 'first_clock_med "13:21" 'trigger ">= 3 bio/air units or cloaked/Blink threats, r=2.25 point claim ttl=32f")
         (hasheq 'mode "neural-parasite-capital-hijack" 'ability_id 249 'observed_casts (sc 'infestor-neural)
                 'first_clock_med "20:29" 'trigger "Range 9 hijack on Archon / Carrier / Tempest / Thor / Battlecruiser (1 caster/target)")
         (hasheq 'mode "microbial-shroud-anti-skytoss" 'ability_id 3807 'observed_casts (sc 'infestor-shroud)
                 'first_clock_med "15:29" 'trigger "Cover >= 5 Hydralisk/Queen/Ultra under Carrier/Tempest/BC air fire (-50% air dmg)"))
   'Viper
   (list (hasheq 'mode "abduct-high-value-pickoff" 'ability_id 2067 'observed_casts (sc 'viper-abduct)
                 'first_clock_med "16:50" 'trigger "Pull Viper/Lurker/SiegeTank/Colossus/Carrier/Tempest into >= 4 ranged allies (1/target)")
         (hasheq 'mode "blinding-cloud-siege-line-mute" 'ability_id 2063 'observed_casts (sc 'viper-cloud)
                 'first_clock_med "14:08" 'trigger "Mute >= 2 SiegeTankSieged / Immortal / Bio bunker line (r=2.0 claim ttl=48f)")
         (hasheq 'mode "parasitic-bomb-clump-plus-consume" 'ability_id 2542 'observed_casts (+ (sc 'viper-pbomb) (sc 'viper-consume))
                 'first_clock_med "13:08" 'trigger "PBomb >= 3 clumped Muta/Medivac/Carrier/Viking; Consume friendly Hatch/Hive at energy < 50"))
   'Corruptor_SwarmHost_Lurker
   (list (hasheq 'mode "corruptor-caustic-spray-nexus-snipe" 'ability_id 2324 'observed_casts (sc 'corruptor-spray)
                 'first_clock_med "13:24" 'trigger "Zero air threats in 11 tiles -> channel CausticSpray on Nexus/PF/Fortress")
         (hasheq 'mode "swarmhost-locust-wave-siege" 'ability_id 2704 'observed_casts (sc 'swarmhost-locusts)
                 'first_clock_med "11:15" 'trigger "Off-creep standoff 18..28 tiles -> launch Locust wave and retreat")
         (hasheq 'mode "lurker-detection-ring-burrow-siege" 'ability_id 2108 'observed_casts (sc 'zerg-burrow-down)
                 'first_clock_med "10:15" 'trigger "Burrow at 8.5..10.0 tiles on choke/mineral flank; hold fire / reposition outside scan"))
   'Ghost
   (list (hasheq 'mode "emp-shield-and-caster-strip" 'ability_id 1628 'observed_casts (sc 'ghost-emp)
                 'first_clock_med "11:58" 'trigger "r=2.0 point claim ttl=24f on HighTemplar/Archon/Infestor/Viper or Protoss clump")
         (hasheq 'mode "steady-targeting-channel-snipe" 'ability_id 2714 'observed_casts (sc 'ghost-snipe)
                 'first_clock_med "13:00" 'trigger "Range > 4.5 vs Ultralisk/Lurker/HT/BroodLord/Viper w/ 34f Ghost micro lockout")
         (hasheq 'mode "tactical-cloak-flank-entry" 'ability_id 3676 'observed_casts (sc 'ghost-cloak)
                 'first_clock_med "17:09" 'trigger "Energy >= 75 & zero enemy detectors in 11 tiles -> cloak before EMP/Snipe"))
   'Raven
   (list (hasheq 'mode "interference-matrix-siege-disable" 'ability_id 3747 'observed_casts (sc 'raven-matrix)
                 'first_clock_med "10:45" 'trigger "1/target claim ttl=36f on Colossus / SiegeTankSieged / Archon / HT / BC")
         (hasheq 'mode "anti-armor-missile-army-amp" 'ability_id 3753 'observed_casts (sc 'raven-aam)
                 'first_clock_med "8:38" 'trigger "Ally army >= 24 supply engaging >= 5 clumped Stalker/Corruptor/Roach/Bio")
         (hasheq 'mode "peripheral-mineral-auto-turret" 'ability_id 379 'observed_casts (sc 'raven-turret)
                 'first_clock_med "5:53" 'trigger "Drop Auto-Turret behind mineral line (harass) or buffer vs Ling/Zealot charge"))
   'Medivac_Cyclone_Battlecruiser
   (list (hasheq 'mode "medivac-boost-moving-drop-and-save" 'ability_id 380 'observed_casts (sc 'medivac-boost)
                 'first_clock_med "5:20" 'trigger "IgniteAfterburners 16..36f before self-targeted moving UnloadAt (396) or low-HP Tank save")
         (hasheq 'mode "cyclone-lock-on-tether-kite" 'ability_id 2350 'observed_casts (sc 'cyclone-lock-on)
                 'first_clock_med "4:16" 'trigger "Lock-On Stalker/VoidRay/Oracle/Prism/Roach and kite inside [8.5..13.5]-tile tether")
         (hasheq 'mode "bc-yamato-plus-low-hp-tactical-jump" 'ability_id 401 'observed_casts (+ (sc 'bc-yamato) (sc 'bc-jump))
                 'first_clock_med "6:01" 'trigger "Yamato anti-air/massive priority; TacticalJump (2358) home at HP < 32%"))
   'HighTemplar
   (list (hasheq 'mode "non-overlapping-psi-storm-blanket" 'ability_id 1036 'observed_casts (sc 'ht-storm)
                 'first_clock_med "10:28" 'trigger "r=2.0 point claim ttl=56f (2.5s) on bio/hydra/ling/lurker clumps (especially post-Revelation)")
         (hasheq 'mode "feedback-caster-execution" 'ability_id 140 'observed_casts (sc 'ht-feedback)
                 'first_clock_med "12:34" 'trigger "1/target claim on >= 75-energy Infestor / Viper / Ghost / Medivac / Raven")
         (hasheq 'mode "post-cast-dry-ht-archon-merge" 'ability_id 1766 'observed_casts (sc 'ht-archon)
                 'first_clock_med "9:20" 'trigger "Pair 2 HighTemplars with energy < 50 at 33..46f after Storm/Feedback -> Archon"))
   'Sentry
   (list (hasheq 'mode "single-aura-guardian-shield" 'ability_id 76 'observed_casts (sc 'sentry-gs)
                 'first_clock_med "9:19" 'trigger "r=5.0 army claim ttl=246f (11s) when >= 3 ranged enemies fire (0 double-pops)")
         (hasheq 'mode "non-trapping-choke-force-field" 'ability_id 1526 'observed_casts (sc 'sentry-ff)
                 'first_clock_med "8:16" 'trigger "Bisect enemy melee/Roach army on ramp/choke without trapping friendly Zealots")
         (hasheq 'mode "four-minute-hallucination-phoenix-scout" 'ability_id 154 'observed_casts (+ (sc 'sentry-halluc-phoenix) (sc 'sentry-halluc-other))
                 'first_clock_med "4:06" 'trigger "88.6% Phoenix scout at ~4:00 to reveal Stargate/Spire/Starport/proxy + WidowMine bait"))
   'Oracle_Phoenix_Disruptor
   (list (hasheq 'mode "oracle-mutex-beam-revelation-stasis" 'ability_id 2375 'observed_casts (+ (sc 'oracle-beam-on) (sc 'oracle-revelation) (sc 'oracle-stasis))
                 'first_clock_med "4:26" 'trigger "1-cmd/frame mutex: Revelation stealth/army -> PulsarBeam (min 60f/med 111f dwell) -> StasisWard")
         (hasheq 'mode "phoenix-graviton-beam-priority-lift" 'ability_id 176 'observed_casts (sc 'phoenix-lift)
                 'first_clock_med "5:30" 'trigger "Lift SiegeTank / Lurker / Queen / Ravager / Cyclone while >= 2 other Phoenixes shoot")
         (hasheq 'mode "disruptor-31f-staggered-purification-nova" 'ability_id 2346 'observed_casts (sc 'disruptor-nova)
                 'first_clock_med "11:34" 'trigger "31f (1.38s) army-wide stagger cooldown so 2..4 Disruptors zone sequentially"))))

(define (build-9-matchup-benchmarks all-min-snaps)
  (define grouped (make-hash)) ; (cons mu m) -> list of snap
  (for ([s (in-list all-min-snaps)])
    (define k (cons (hash-ref s 'matchup) (hash-ref s 'minute)))
    (hash-set! grouped k (cons s (hash-ref grouped k '()))))

  (for/hasheq ([mu (in-list ALL-9-MATCHUPS)])
    (values
     (string->symbol mu)
     (for/hasheq ([m (in-list BENCHMARK-MINUTES)])
       (define snaps (hash-ref grouped (cons mu m) '()))
       (define n (length snaps))
       (define all-syms
         (sort
          (remove-duplicates
           (apply append
                  (for/list ([s (in-list snaps)])
                    (append (hash-keys (hash-ref s 'alive))
                            (hash-keys (hash-ref s 'produced))))))
          symbol<?))
       (define units-h
         (for/fold ([uh (hasheq)]) ([sym (in-list all-syms)])
           (define alives (for/list ([s (in-list snaps)]) (hash-ref (hash-ref s 'alive) sym 0)))
           (define prods (for/list ([s (in-list snaps)]) (hash-ref (hash-ref s 'produced) sym 0)))
           (define ast (stats-hash alives))
           (define pst (stats-hash prods))
           (if (or (>= (hash-ref ast 'p75) 1.0)
                   (>= (hash-ref pst 'p75) 1.0)
                   (>= (hash-ref ast 'mean) 0.25))
               (hash-set uh sym
                         (hasheq 'alive_median (hash-ref ast 'median)
                                 'alive_p75 (hash-ref ast 'p75)
                                 'alive_mean (hash-ref ast 'mean)
                                 'produced_median (hash-ref pst 'median)
                                 'produced_p75 (hash-ref pst 'p75)))
               uh)))
       (define wst (stats-hash (for/list ([s (in-list snaps)]) (hash-ref s 'workers))))
       (define bst (stats-hash (for/list ([s (in-list snaps)]) (hash-ref s 'bases))))
       (values (string->symbol (format "m~a" m))
               (hasheq 'minute m
                       'frame (inexact->exact (round (* m 60 22.4)))
                       'sample_trajectories n
                       'workers_median (hash-ref wst 'median)
                       'workers_p75 (hash-ref wst 'p75)
                       'bases_median (hash-ref bst 'median)
                       'units units-h))))))

;; -----------------------------------------------------------------------------
;; 8. Corpus Orchestrator (`mine-all-replay-tactics!`)
;; -----------------------------------------------------------------------------

(define (collect-replay-paths dir-path skip-battlepoker?)
  (if (not (directory-exists? dir-path))
      '()
      (filter (lambda (p)
                (and (string-suffix? (path->string p) ".SC2Replay")
                     (not (and skip-battlepoker?
                               (string-prefix? (path->string (file-name-from-path p)) "sc2-battlepoker")))))
              (sort (directory-list dir-path #:build? #t) path<?))))

(define (collect-aiarena-replay-paths)
  (define extra-dirs
    (list (build-path (find-system-path 'temp-dir) "mothman_aiarena_diag" "round4" "replays")
          (build-path (car (filesystem-root-list)) "tmp" "mothman_aiarena_diag" "round4" "replays")))
  (define raw-paths
    (append
     (if (directory-exists? AIARENA-CORPUS-DIR)
         (for/list ([p (in-directory AIARENA-CORPUS-DIR)]
                    #:when (and (file-exists? p)
                                (string-suffix? (path->string p) ".SC2Replay")))
           p)
         '())
     (apply append
            (for/list ([ed (in-list extra-dirs)])
              (if (directory-exists? ed)
                  (filter (lambda (p) (string-suffix? (path->string p) ".SC2Replay"))
                          (directory-list ed #:build? #t))
                  '())))))
  ;; Deduplicate by leading numeric match ID, preferring longer descriptive filenames
  (define by-key (make-hash))
  (for ([p (in-list raw-paths)])
    (define fn (path->string (file-name-from-path p)))
    (define m (regexp-match #rx"^([0-9]+)" fn))
    (define key (if m (cadr m) fn))
    (define prev (hash-ref by-key key #f))
    (when (or (not prev)
              (> (string-length fn)
                 (string-length (path->string (file-name-from-path prev)))))
      (hash-set! by-key key p)))
  (sort (hash-values by-key)
        string<?
        #:key (lambda (p) (path->string (file-name-from-path p)))))

(define (mine-corpus-parallel paths corpus-name)
  (define n (length paths))
  (define results (make-vector n #f))
  (define sem (make-semaphore 8))
  (define thds
    (for/list ([p (in-list paths)] [i (in-naturals)])
      (thread
       (lambda ()
         (call-with-semaphore sem
           (lambda ()
             (vector-set! results i (analyze-single-replay p corpus-name))))))))
  (for ([t (in-list thds)]) (thread-wait t))
  (filter values (vector->list results)))

(define (select-diverse-examples pro-evs aia-evs [limit 6])
  ;; Prioritize named AI Arena replays (e.g. Creepy_strategies, Thssprtssbt) ahead of generic Opponent filenames
  (define sorted-aia
    (append (filter (lambda (e) (not (string-contains? (hash-ref e 'replay) "_Opponent."))) aia-evs)
            (filter (lambda (e) (string-contains? (hash-ref e 'replay) "_Opponent.")) aia-evs)))
  ;; Pick subtype-diverse + replay-diverse concrete examples across pro_corpus and aiarena_matches
  (define ordered-evs
    (if (and (pair? pro-evs) (pair? sorted-aia))
        (let ([p-head (take pro-evs (min 3 (length pro-evs)))]
              [p-tail (drop pro-evs (min 3 (length pro-evs)))])
          (append p-head sorted-aia p-tail))
        (append pro-evs sorted-aia)))
  (define seen-subs (mutable-set))
  (define seen-reps (mutable-set))
  ;; Pass 1: distinct subtype + distinct replay
  (define pass1
    (let loop1 ([rem ordered-evs] [acc '()])
      (cond
        [(or (null? rem) (= (length acc) limit)) (reverse acc)]
        [(or (set-member? seen-subs (hash-ref (car rem) 'subtype))
             (set-member? seen-reps (hash-ref (car rem) 'replay)))
         (loop1 (cdr rem) acc)]
        [else
         (set-add! seen-subs (hash-ref (car rem) 'subtype))
         (set-add! seen-reps (hash-ref (car rem) 'replay))
         (loop1 (cdr rem) (cons (car rem) acc))])))
  ;; Pass 2: fill remaining slots with distinct replays
  (define pass2
    (let loop2 ([rem ordered-evs] [acc (reverse pass1)])
      (cond
        [(or (null? rem) (= (length acc) limit)) (reverse acc)]
        [(set-member? seen-reps (hash-ref (car rem) 'replay))
         (loop2 (cdr rem) acc)]
        [else
         (set-add! seen-reps (hash-ref (car rem) 'replay))
         (loop2 (cdr rem) (cons (car rem) acc))])))
  (if (< (length pass2) (min limit (length ordered-evs)))
      (take ordered-evs (min limit (length ordered-evs)))
      pass2))

(define (build-family-entry fam evs)
  (define pro-evs (filter (lambda (e) (string=? (hash-ref e 'corpus) "pro_corpus")) evs))
  (define aia-evs (filter (lambda (e) (string=? (hash-ref e 'corpus) "aiarena_matches")) evs))
  (define sub-counts (make-hash))
  (for ([e (in-list evs)])
    (hash-update! sub-counts (hash-ref e 'subtype) add1 0))
  (define frames (map (lambda (e) (hash-ref e 'frame)) evs))
  (define metrics (filter positive? (map (lambda (e) (hash-ref e 'metric)) evs)))
  (hasheq 'family fam
          'total_events (length evs)
          'pro_corpus_events (length pro-evs)
          'aiarena_events (length aia-evs)
          'unique_replays (set-count (list->set (map (lambda (e) (hash-ref e 'replay)) evs)))
          'subtype_counts
          (for/hasheq ([(k v) (in-hash sub-counts)])
            (values (string->symbol k) v))
          'frame_timing_stats (stats-hash frames #t)
          'spatial_or_dwell_metric_stats (stats-hash metrics #f)
          'top_examples (select-diverse-examples pro-evs aia-evs 6)))

(define (build-simcity-benchmarks all-simcity-samples)
  (define t-samps (filter (lambda (s) (string=? (hash-ref s 'race) "T")) all-simcity-samples))
  (define p-samps (filter (lambda (s) (string=? (hash-ref s 'race) "P")) all-simcity-samples))
  (define z-samps (filter (lambda (s) (string=? (hash-ref s 'race) "Z")) all-simcity-samples))
  (define t-nn (apply append (map (lambda (s) (hash-ref s 'nn_dists '())) t-samps)))
  (define t-dx (apply append (map (lambda (s) (hash-ref s 'nn_dxs '())) t-samps)))
  (define t-dy (apply append (map (lambda (s) (hash-ref s 'nn_dys '())) t-samps)))
  (define t-dep (apply append (map (lambda (s) (hash-ref s 'depot_main_dists '())) t-samps)))
  (define t-tot-add (for/sum ([s (in-list t-samps)]) (hash-ref s 'total_addons 0)))
  (define t-east-add (for/sum ([s (in-list t-samps)]) (hash-ref s 'east_addons 0)))
  (define p-dual (map (lambda (s) (hash-ref s 'dual_powered_pct 0.0)) p-samps))
  (define p-pynn (apply append (map (lambda (s) (hash-ref s 'pylon_nn_dists '())) p-samps)))
  (define p-gtnn (apply append (map (lambda (s) (hash-ref s 'gate_nn_dists '())) p-samps)))
  (define p-tot-ht (for/sum ([s (in-list p-samps)]) (hash-ref s 'hi_tech_cnt 0)))
  (define p-rear-ht (for/sum ([s (in-list p-samps)]) (hash-ref s 'rear_tech_cnt 0)))
  (define z-tmain (apply append (map (lambda (s) (hash-ref s 'tech_main_dists '())) z-samps)))
  (define z-tres (apply append (map (lambda (s) (hash-ref s 'tech_res_dists '())) z-samps)))
  (define z-spres (apply append (map (lambda (s) (hash-ref s 'spore_res_dists '())) z-samps)))
  (define z-choke (map (lambda (s) (hash-ref s 'nat_choke_count 0)) z-samps))
  (hasheq
   'Terran
   (hasheq 'sample_trajectories (length t-samps)
           'prod_nearest_neighbor_dist_tiles (stats-hash t-nn)
           'prod_grid_abs_dx_tiles (stats-hash t-dx)
           'prod_grid_abs_dy_tiles (stats-hash t-dy)
           'east_addon_compliance_pct (if (> t-tot-add 0) (round1 (* 100.0 (/ t-east-add t-tot-add))) 0.0)
           'depot_dist_from_main_cc_tiles (stats-hash t-dep))
   'Protoss
   (hasheq 'sample_trajectories (length p-samps)
           'dual_pylon_redundancy_pct (stats-hash p-dual)
           'paired_pylon_spacing_tiles (stats-hash p-pynn)
           'gateway_matrix_spacing_tiles (stats-hash p-gtnn)
           'rear_mineral_shadow_hitech_pct (if (> p-tot-ht 0) (round1 (* 100.0 (/ p-rear-ht p-tot-ht))) 0.0))
   'Zerg
   (hasheq 'sample_trajectories (length z-samps)
           'tech_dist_from_main_hatch_tiles (stats-hash z-tmain)
           'tech_dist_from_mineral_pocket_tiles (stats-hash z-tres)
           'spore_dist_from_mineral_line_tiles (stats-hash z-spres)
           'natural_choke_wall_bldgs (stats-hash z-choke))))

(define (build-worker-split-benchmarks all-ws-samples)
  (define active-f0 (filter (lambda (s) (>= (hash-ref s 'f0_distinct_patches 0) 2)) all-ws-samples))
  (define active-sm (filter (lambda (s) (> (hash-ref s 'speed_mine_seqs 0) 0)) all-ws-samples))
  (hasheq 'pro_trajectories_analyzed (length all-ws-samples)
          'trajectories_with_frame0_split (length active-f0)
          'frame0_split_adoption_pct
          (if (pair? all-ws-samples) (round1 (* 100.0 (/ (length active-f0) (length all-ws-samples)))) 0.0)
          'frame0_gather_cmds_stats (stats-hash (map (lambda (s) (hash-ref s 'f0_split_cmds 0)) active-f0))
          'frame0_distinct_patches_stats (stats-hash (map (lambda (s) (hash-ref s 'f0_distinct_patches 0)) active-f0))
          'frame0_first_cmd_frame_stats (stats-hash (map (lambda (s) (hash-ref s 'f0_first_frame 0)) active-f0))
          'trajectories_with_speed_mining_micro (length active-sm)
          'speed_mining_seqs_per_active_player (stats-hash (map (lambda (s) (hash-ref s 'speed_mine_seqs 0)) active-sm))))

(define (mine-all-replay-tactics!)
  (define t0 (current-inexact-milliseconds))
  (define pro-paths (collect-replay-paths PRO-CORPUS-DIR #t))
  (define aia-paths (collect-aiarena-replay-paths))
  (define pro-recs (mine-corpus-parallel pro-paths "pro_corpus"))
  (define aia-recs (mine-corpus-parallel aia-paths "aiarena_matches"))
  (define all-recs (append pro-recs aia-recs))

  ;; Aggregate events by family & subtype, spells, minute benchmarks, and Wave 1.8 samples
  (define fam->evs (make-hash))
  (for ([f (in-list (append REQUIRED-15-FAMILIES WAVE18-EXTENDED-SECTIONS))])
    (hash-set! fam->evs f '()))
  (define spell-counts (make-hasheq))
  (define all-min-snaps '())
  (define all-simcity-samples '())
  (define all-ws-samples '())

  (for ([r (in-list all-recs)])
    (for ([ev (in-list (hash-ref r 'events))])
      (define fam (hash-ref ev 'family))
      (hash-set! fam->evs fam (cons ev (hash-ref fam->evs fam '()))))
    (when (string=? (hash-ref r 'corpus) "pro_corpus")
      (for ([sp (in-list (hash-ref r 'spells))])
        (hash-update! spell-counts (cadr sp) add1 0))
      (set! all-min-snaps (append (hash-ref r 'min_snaps) all-min-snaps))
      (set! all-simcity-samples (append (hash-ref r 'simcity_samples '()) all-simcity-samples))
      (set! all-ws-samples (append (hash-ref r 'worker_split_samples '()) all-ws-samples))))

  (define families-json
    (for/hasheq ([fam (in-list REQUIRED-15-FAMILIES)])
      (values (string->symbol fam)
              (build-family-entry fam (reverse (hash-ref fam->evs fam '()))))))

  (define simcity-bench-json (build-simcity-benchmarks all-simcity-samples))
  (define ws-bench-json (build-worker-split-benchmarks all-ws-samples))

  (define wave18-json
    (for/hasheq ([sec (in-list WAVE18-EXTENDED-SECTIONS)])
      (define base-entry (build-family-entry sec (reverse (hash-ref fam->evs sec '()))))
      (define enriched
        (cond
          [(string=? sec "pro_simcity_layout_stats")
           (hash-set base-entry 'simcity_benchmarks simcity-bench-json)]
          [(string=? sec "game_start_worker_split_and_stacking")
           (hash-set base-entry 'worker_split_benchmarks ws-bench-json)]
          [else base-entry]))
      (values (string->symbol sec) enriched)))

  ;; Wave 1.5 & Wave 1D summary rollups
  (define (sub-total fam sub)
    (define fh (hash-ref families-json (string->symbol fam)))
    (hash-ref (hash-ref fh 'subtype_counts) (string->symbol sub) 0))

  (define (sub-examples fam subs)
    (define evs (reverse (hash-ref fam->evs fam '())))
    (define matching (filter (lambda (e) (member (hash-ref e 'subtype) subs)) evs))
    (define frames (map (lambda (e) (hash-ref e 'frame)) matching))
    (hasheq 'total_events (length matching)
            'unique_replays (set-count (list->set (map (lambda (e) (hash-ref e 'replay)) matching)))
            'frame_timing_stats (stats-hash frames #t)
            'top_examples (take matching (min 4 (length matching)))))

  (define wave15-json
    (hasheq
     'dropperlord_queen_creep_and_pad_burrow
     (hasheq 'dropperlord_queen_expeditions (sub-total "creep-spread-and-clearing" "dropperlord-queen-creep-expedition")
             'overlord_transport_drops (sub-total "multi-angle-drops-and-widow-mine-runby" "overlord-transport-drop")
             'burrowed_zergling_pad_blocks (sub-total "burrow-dodge-and-ring-ambush" "burrowed-zergling-pad-block"))
     'overseer_disruption
     (hasheq 'spawn_changeling_events (sub-total "changeling-and-counter" "spawn-changeling")
             'changeling_hold_pos_blocks (sub-total "changeling-and-counter" "changeling-hold-ramp-block")
             'counter_changeling_snipes (sub-total "changeling-and-counter" "counter-changeling-snipe")
             'contaminate_casts (sub-total "changeling-and-counter" "overseer-contaminate")
             'oversight_siege_modes (sub-total "changeling-and-counter" "overseer-oversight"))
     'widow_mine_drop_retarget_and_bait
     (hasheq 'widow_mine_drops (sub-total "multi-angle-drops-and-widow-mine-runby" "widow-mine-drop")
             'widow_mine_synced_with_runby (sub-total "multi-angle-drops-and-widow-mine-runby" "widow-mine-drop-with-runby")
             'widow_mine_manual_retargets_2099 (sub-total "multi-angle-drops-and-widow-mine-runby" "widow-mine-manual-retarget")
             'single_unit_trigger_baits (sub-total "multi-angle-drops-and-widow-mine-runby" "widow-mine-single-unit-bait")
             'multi_unit_clump_splashes (sub-total "multi-angle-drops-and-widow-mine-runby" "widow-mine-clump-splash"))))

  (define wave1d-json
    (hasheq
     'warp_prism_warp_in_attacks
     (sub-examples "multi-angle-drops-and-widow-mine-runby" '("warp-prism-warp-in-attack"))
     'nexus_strategic_recall
     (sub-examples "unit-mode-and-spell-counters" '("nexus-strategic-recall" "nexus-energy-recharge"))
     'mothership_mass_recall_and_timewarp
     (sub-examples "unit-mode-and-spell-counters" '("mothership-mass-recall" "mothership-time-warp"))
     'destructible_rocks_and_rockslides
     (hasheq 'destructible_rock_clears (sub-total "coordinated-runbys" "destructible-rock-clear")
             'collapsible_rockslide_shatters (sub-total "coordinated-runbys" "collapsible-rockslide-shatter")
             'details (sub-examples "coordinated-runbys" '("destructible-rock-clear" "collapsible-rockslide-shatter")))
     'gold_or_rich_base_expansions
     (sub-examples "expansion-and-gas-blocks" '("gold-or-rich-base-expansion"))
     'dropship_combat_rescues
     (sub-examples "multi-angle-drops-and-widow-mine-runby" '("dropship-combat-rescue"))))

  (define elapsed-ms (inexact->exact (round (- (current-inexact-milliseconds) t0))))
  (define base-catalog
    (hasheq 'schema_version "1.8.0"
            'elapsed_ms elapsed-ms
            'corpus_summary
            (hasheq 'pro_corpus_scanned (length pro-paths)
                    'pro_valid_1v1_games (length pro-recs)
                    'pro_player_trajectories (* 2 (length pro-recs))
                    'pro_game_events_decoded (count (lambda (r) (hash-ref r 'cmd_decoded)) pro-recs)
                    'aiarena_scanned (length aia-paths)
                    'aiarena_valid_1v1_games (length aia-recs)
                    'aiarena_random_games (count (lambda (r) (or (hash-ref r 'p1_random) (hash-ref r 'p2_random))) aia-recs))
            'tactical_families families-json
            'wave15_extensions wave15-json
            'wave1d_map_and_recall_extensions wave1d-json
            'wave18_extended_families wave18-json
            'spell_ability_3_tactics_catalog (build-3-tactics-catalog spell-counts)
            'pro_unit_benchmarks_by_minute (build-9-matchup-benchmarks all-min-snaps)))
  ;; Also attach all 10 Wave 1.8 sections at top level for direct key access
  (define catalog
    (for/fold ([cat base-catalog]) ([(k v) (in-hash wave18-json)])
      (hash-set cat k v)))

  (make-directory* (path-only OUTPUT-JSON-PATH))
  (call-with-output-file OUTPUT-JSON-PATH
    #:exists 'replace
    (lambda (out)
      (write-json catalog out)))
  catalog)

;; -----------------------------------------------------------------------------
;; 9. Verification (`--verify`) & Summary Printer (`--summary`)
;; -----------------------------------------------------------------------------

(define (verify-tactical-catalog-json [json-path OUTPUT-JSON-PATH])
  (unless (file-exists? json-path)
    (error 'verify-tactical-catalog-json "Missing JSON file: ~a" json-path))
  (define raw-str (file->string json-path))
  (when (string-contains? raw-str "/home/")
    (error 'verify-tactical-catalog-json "JSON contains non-portable absolute /home/ path"))
  (when (string-contains? raw-str "/tmp/")
    (error 'verify-tactical-catalog-json "JSON contains non-portable /tmp/ path"))
  (define j (string->jsexpr raw-str))
  (unless (hash? j)
    (error 'verify-tactical-catalog-json "Top-level JSON is not an object"))
  (define cs (hash-ref j 'corpus_summary #hasheq()))
  (unless (>= (hash-ref cs 'pro_valid_1v1_games 0) 270)
    (error 'verify-tactical-catalog-json "Expected >= 270 pro 1v1 games, got ~a" (hash-ref cs 'pro_valid_1v1_games 0)))
  (define fams (hash-ref j 'tactical_families #hasheq()))
  (for ([fam (in-list REQUIRED-15-FAMILIES)])
    (define fh (hash-ref fams (string->symbol fam) #f))
    (unless (and (hash? fh) (> (hash-ref fh 'total_events 0) 0))
      (error 'verify-tactical-catalog-json "Family ~a missing or has 0 observed events" fam)))
  (define w18 (hash-ref j 'wave18_extended_families #hasheq()))
  (for ([sec (in-list WAVE18-EXTENDED-SECTIONS)])
    (define sym (string->symbol sec))
    (define sh (hash-ref w18 sym #f))
    (define top-sh (hash-ref j sym #f))
    (unless (and (hash? sh) (hash? top-sh) (> (hash-ref sh 'total_events 0) 0))
      (error 'verify-tactical-catalog-json "Wave 1.8 section ~a missing or has 0 observed events" sec)))
  (define sc-bm (hash-ref (hash-ref j 'pro_simcity_layout_stats #hasheq()) 'simcity_benchmarks #hasheq()))
  (for ([rk (in-list '(Terran Protoss Zerg))])
    (unless (hash-has-key? sc-bm rk)
      (error 'verify-tactical-catalog-json "Missing ~a in pro_simcity_layout_stats.simcity_benchmarks" rk)))
  (unless (hash-has-key? (hash-ref j 'game_start_worker_split_and_stacking #hasheq()) 'worker_split_benchmarks)
    (error 'verify-tactical-catalog-json "Missing worker_split_benchmarks in game_start_worker_split_and_stacking"))
  (define s3 (hash-ref j 'spell_ability_3_tactics_catalog #hasheq()))
  (unless (= (hash-count s3) 12)
    (error 'verify-tactical-catalog-json "Expected 12 caster groups in spell_ability_3_tactics_catalog, got ~a" (hash-count s3)))
  (for ([(k lst) (in-hash s3)])
    (unless (and (list? lst) (= (length lst) 3))
      (error 'verify-tactical-catalog-json "Caster group ~a does not have 3 tactics" k)))
  (define bm (hash-ref j 'pro_unit_benchmarks_by_minute #hasheq()))
  (for ([mu (in-list ALL-9-MATCHUPS)])
    (unless (hash-has-key? bm (string->symbol mu))
      (error 'verify-tactical-catalog-json "Missing matchup ~a in pro_unit_benchmarks_by_minute" mu)))
  (define w1d (hash-ref j 'wave1d_map_and_recall_extensions #hasheq()))
  (for ([k (in-list '(warp_prism_warp_in_attacks nexus_strategic_recall mothership_mass_recall_and_timewarp
                      destructible_rocks_and_rockslides gold_or_rich_base_expansions dropship_combat_rescues))])
    (unless (hash-has-key? w1d k)
      (error 'verify-tactical-catalog-json "Missing ~a in wave1d_map_and_recall_extensions" k)))
  #t)

(define (print-tactical-catalog-summary catalog)
  (define cs (hash-ref catalog 'corpus_summary))
  (printf "=== PRO & AI ARENA TACTICAL CATALOG SUMMARY (schema ~a, ~ams) ===\n"
          (hash-ref catalog 'schema_version)
          (hash-ref catalog 'elapsed_ms 0))
  (printf "Pro Corpus: ~a valid LotV 1v1 melee games (~a trajectories, ~a w/ game.events) | AI Arena: ~a games (~a Random)\n\n"
          (hash-ref cs 'pro_valid_1v1_games)
          (hash-ref cs 'pro_player_trajectories)
          (hash-ref cs 'pro_game_events_decoded)
          (hash-ref cs 'aiarena_valid_1v1_games)
          (hash-ref cs 'aiarena_random_games))
  (printf "ID | Tactical Family                        | Total | Pro  | AIA  | Replays | Clock [p25 / med / p75] | Metric Med\n")
  (printf "---+----------------------------------------+-------+------+------+---------+-------------------------+-----------\n")
  (define fams (hash-ref catalog 'tactical_families))
  (for ([fam (in-list REQUIRED-15-FAMILIES)] [idx (in-naturals 1)])
    (define fh (hash-ref fams (string->symbol fam)))
    (define ft (hash-ref fh 'frame_timing_stats))
    (define ms (hash-ref fh 'spatial_or_dwell_metric_stats))
    (printf "~a | ~a | ~a | ~a | ~a | ~a | ~a / ~a / ~a | ~a\n"
            (~r idx #:min-width 2)
            (~a fam #:min-width 38)
            (~r (hash-ref fh 'total_events) #:min-width 5)
            (~r (hash-ref fh 'pro_corpus_events) #:min-width 4)
            (~r (hash-ref fh 'aiarena_events) #:min-width 4)
            (~r (hash-ref fh 'unique_replays) #:min-width 7)
            (~a (hash-ref ft 'clock_p25 "-") #:min-width 5)
            (~a (hash-ref ft 'clock_median "-") #:min-width 5)
            (~a (hash-ref ft 'clock_p75 "-") #:min-width 5)
            (hash-ref ms 'median 0)))
  (printf "\n=== WAVE 1.8 EXTENDED TACTICAL & SIMCITY SECTIONS ===\n")
  (printf "ID | Wave 1.8 Section                       | Total | Pro  | AIA  | Replays | Clock [p25 / med / p75] | Metric Med\n")
  (printf "---+----------------------------------------+-------+------+------+---------+-------------------------+-----------\n")
  (define w18 (hash-ref catalog 'wave18_extended_families #hasheq()))
  (for ([sec (in-list WAVE18-EXTENDED-SECTIONS)] [idx (in-naturals 1)])
    (define sh (hash-ref w18 (string->symbol sec)))
    (define ft (hash-ref sh 'frame_timing_stats))
    (define ms (hash-ref sh 'spatial_or_dwell_metric_stats))
    (printf "~a | ~a | ~a | ~a | ~a | ~a | ~a / ~a / ~a | ~a\n"
            (~r idx #:min-width 2)
            (~a sec #:min-width 38)
            (~r (hash-ref sh 'total_events) #:min-width 5)
            (~r (hash-ref sh 'pro_corpus_events) #:min-width 4)
            (~r (hash-ref sh 'aiarena_events) #:min-width 4)
            (~r (hash-ref sh 'unique_replays) #:min-width 7)
            (~a (hash-ref ft 'clock_p25 "-") #:min-width 5)
            (~a (hash-ref ft 'clock_median "-") #:min-width 5)
            (~a (hash-ref ft 'clock_p75 "-") #:min-width 5)
            (hash-ref ms 'median 0)))
  (printf "\nPro SimCity Benchmarks: ~s\n"
          (hash-ref (hash-ref catalog 'pro_simcity_layout_stats #hasheq()) 'simcity_benchmarks #hasheq()))
  (printf "Worker Split & Speed-Mining Benchmarks: ~s\n"
          (hash-ref (hash-ref catalog 'game_start_worker_split_and_stacking #hasheq()) 'worker_split_benchmarks #hasheq()))
  (printf "\nWave 1.5 Extensions: ~s\n" (hash-ref catalog 'wave15_extensions))
  (define w1d (hash-ref catalog 'wave1d_map_and_recall_extensions #hasheq()))
  (printf "Wave 1D Map & Recall Extensions: warp_prism_warp_ins=~a, nexus_recall_recharge=~a, mothership_recall_timewarp=~a, rock_clears=~a, rockslides=~a, gold_expansions=~a, dropship_rescues=~a\n"
          (hash-ref (hash-ref w1d 'warp_prism_warp_in_attacks #hasheq()) 'total_events 0)
          (hash-ref (hash-ref w1d 'nexus_strategic_recall #hasheq()) 'total_events 0)
          (hash-ref (hash-ref w1d 'mothership_mass_recall_and_timewarp #hasheq()) 'total_events 0)
          (hash-ref (hash-ref w1d 'destructible_rocks_and_rockslides #hasheq()) 'destructible_rock_clears 0)
          (hash-ref (hash-ref w1d 'destructible_rocks_and_rockslides #hasheq()) 'collapsible_rockslide_shatters 0)
          (hash-ref (hash-ref w1d 'gold_or_rich_base_expansions #hasheq()) 'total_events 0)
          (hash-ref (hash-ref w1d 'dropship_combat_rescues #hasheq()) 'total_events 0))
  (printf "\n9-Matchup Pro Unit Benchmarks @ Minute 5 & Minute 7 (alive_p75):\n")
  (define bm (hash-ref catalog 'pro_unit_benchmarks_by_minute))
  (for ([mu (in-list ALL-9-MATCHUPS)])
    (define muh (hash-ref bm (string->symbol mu)))
    (define m5 (hash-ref muh 'm5))
    (define m7 (hash-ref muh 'm7))
    (define (top-u mh)
      (define pairs
        (for/list ([(u st) (in-hash (hash-ref mh 'units))]
                   #:when (>= (hash-ref st 'alive_p75 0) 1.0))
          (cons u (hash-ref st 'alive_p75))))
      (map (lambda (kv) (format "~a:~a" (car kv) (inexact->exact (round (cdr kv)))))
           (take (sort pairs > #:key cdr) (min 6 (length pairs)))))
    (printf "  ~a (n5=~a, w5=~a, w7=~a): 5m=~s | 7m=~s\n"
            mu
            (hash-ref m5 'sample_trajectories)
            (hash-ref m5 'workers_median)
            (hash-ref m7 'workers_median)
            (top-u m5)
            (top-u m7))))

;; -----------------------------------------------------------------------------
;; 10. Main Entrypoint
;; -----------------------------------------------------------------------------

(module+ main
  (define mode 'mine)
  (command-line
   #:program "mine-pro-replay-tactics.rkt"
   #:once-any
   [("--summary") "Print tactical catalog summary (mining first if JSON absent)"
                  (set! mode 'summary)]
   [("--verify") "Verify data/pro_tactical_catalog_examples.json schema, 15 families & Wave 1.8 sections"
                 (set! mode 'verify)])
  (case mode
    [(mine)
     (define cat (mine-all-replay-tactics!))
     (verify-tactical-catalog-json OUTPUT-JSON-PATH)
     (print-tactical-catalog-summary cat)]
    [(summary)
     (define cat
       (if (file-exists? OUTPUT-JSON-PATH)
           (call-with-input-file OUTPUT-JSON-PATH read-json)
           (mine-all-replay-tactics!)))
     (print-tactical-catalog-summary cat)]
    [(verify)
     (verify-tactical-catalog-json OUTPUT-JSON-PATH)
     (printf "[verify] PASS: ~a covers all 15 tactical families, Wave 1.5, Wave 1D, Wave 1.8 (10 sections), 12x3 spell tactics, and 9-matchup unit benchmarks.\n"
             (file-name-from-path OUTPUT-JSON-PATH))]))
