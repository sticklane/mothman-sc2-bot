#lang racket/base

;; =============================================================================
;; Pure-Racket Blizzard MPQ Archive Reader & S2Protocol Replay Parser
;; (`lib/sc2-mpq-replay-parser.rkt`)
;;
;; Zero-Python, zero-external-package `.SC2Replay` binary parser:
;;   1. Blizzard StormLib MPQ decryption (`STORM-CRYPT`, `mpq-hash`, `mpq-decrypt`)
;;   2. Sector decompression:
;;        - `0x02` zlib via `file/gunzip`'s `inflate` (after RFC 1950 header)
;;        - `0x10` bzip2 via `/usr/bin/bzip2 -dc` subprocess pipe
;;   3. S2Protocol `decode-versioned` & `decode-tracker-stream` (`replay.details`,
;;      `replay.initData`, `replay.tracker.events`, and MPQ user-data header)
;;   4. High-level `parse-sc2-replay` structured summary (players, actual rolled
;;      races, map, result, duration, expansions, tech morphs, upgrades, unit
;;      births/deaths, supply blocks, and minute-by-minute economy/army stats).
;; =============================================================================

(require racket/file
         racket/list
         racket/math
         racket/path
         racket/port
         racket/string
         file/gunzip)

(provide STORM-CRYPT
         mpq-hash
         mpq-decrypt
         decompress-mpq-sector
         read-mpq-files
         read-vint
         decode-versioned
         decode-tracker-stream
         parse-sc2-replay
         TH-NAMES
         TECH-MORPH-NAMES
         NON-COMBAT-DEATHS)

;; -----------------------------------------------------------------------------
;; 1. Blizzard MPQ Crypt Table, Hashing & Block Decryption
;; -----------------------------------------------------------------------------

(define (u32 x)
  (bitwise-and x #xFFFFFFFF))

(define (u16-le bstr off)
  (integer-bytes->integer bstr #f #f off (+ off 2)))

(define (u32-le bstr off)
  (integer-bytes->integer bstr #f #f off (+ off 4)))

(define STORM-CRYPT
  (let ([crypt (make-vector 1280 0)]
        [seed #x00100001])
    (for ([i (in-range 256)])
      (let ([idx i])
        (for ([_ (in-range 5)])
          (set! seed (modulo (+ (* seed 125) 3) #x2AAAAB))
          (define t1 (arithmetic-shift (bitwise-and seed #xFFFF) 16))
          (set! seed (modulo (+ (* seed 125) 3) #x2AAAAB))
          (define t2 (bitwise-and seed #xFFFF))
          (vector-set! crypt idx (bitwise-ior t1 t2))
          (set! idx (+ idx 256)))))
    crypt))

(define (mpq-hash s hash-type)
  (define bs (string->bytes/latin-1 (string-upcase s)))
  (define n (bytes-length bs))
  (let loop ([i 0]
             [seed1 #x7FED7FED]
             [seed2 #xEEEEEEEE])
    (if (= i n)
        seed1
        (let* ([ch (bytes-ref bs i)]
               [val (vector-ref STORM-CRYPT (+ (arithmetic-shift hash-type 8) ch))]
               [seed1* (u32 (bitwise-xor val (u32 (+ seed1 seed2))))]
               [seed2* (u32 (+ ch seed1* seed2 (arithmetic-shift seed2 5) 3))])
          (loop (add1 i) seed1* seed2*)))))

(define (mpq-decrypt data key)
  (define n (bitwise-and (bytes-length data) (bitwise-not 3)))
  (define out (make-bytes n 0))
  (let loop ([i 0]
             [seed1 (u32 key)]
             [seed2 #xEEEEEEEE])
    (if (= i n)
        out
        (let* ([seed2-a (u32 (+ seed2 (vector-ref STORM-CRYPT (+ #x400 (bitwise-and seed1 #xFF)))))]
               [enc-val (u32-le data i)]
               [val (u32 (bitwise-xor enc-val (u32 (+ seed1 seed2-a))))]
               [not-s1 (bitwise-xor seed1 #xFFFFFFFF)]
               [seed1* (bitwise-ior
                        (u32 (+ (arithmetic-shift not-s1 #x15) #x11111111))
                        (arithmetic-shift seed1 -11))]
               [seed2* (u32 (+ val seed2-a (arithmetic-shift seed2-a 5) 3))])
          (integer->integer-bytes val 4 #f #f out i)
          (loop (+ i 4) seed1* seed2*)))))

;; -----------------------------------------------------------------------------
;; 2. MPQ Sector Decompression (zlib via `file/gunzip` + bzip2 via `/usr/bin/bzip2`)
;; -----------------------------------------------------------------------------

(define (decompress-bzip2 payload)
  (define bzip2-bin
    (or (find-executable-path "bzip2")
        (and (file-exists? "/usr/bin/bzip2") (string->path "/usr/bin/bzip2"))
        (error 'decompress-bzip2 "bzip2 executable not found")))
  (define-values (sp stdout stdin stderr)
    (subprocess #f #f #f bzip2-bin "-dc"))
  (define writer-thd
    (thread
     (lambda ()
       (with-handlers ([exn:fail? void])
         (write-bytes payload stdin))
       (with-handlers ([exn:fail? void])
         (close-output-port stdin)))))
  (define out-bytes (port->bytes stdout))
  (define err-bytes (port->bytes stderr))
  (close-input-port stdout)
  (close-input-port stderr)
  (thread-wait writer-thd)
  (subprocess-wait sp)
  (unless (zero? (subprocess-status sp))
    (error 'decompress-bzip2
           "bzip2 -dc failed (status ~a): ~a"
           (subprocess-status sp)
           (bytes->string/utf-8 err-bytes #\?)))
  out-bytes)

(define (decompress-zlib payload)
  (when (< (bytes-length payload) 2)
    (error 'decompress-zlib "zlib payload shorter than 2-byte RFC 1950 header"))
  ;; RFC 1950: bit 5 of FLG (byte 1) indicates a 4-byte FDICT after the 2-byte header.
  (define fdict? (not (zero? (bitwise-and (bytes-ref payload 1) #x20))))
  (define hdr-len (if fdict? 6 2))
  (define in (open-input-bytes (subbytes payload hdr-len)))
  (define out (open-output-bytes))
  (inflate in out)
  (get-output-bytes out))

(define (decompress-mpq-sector raw expected-size)
  (cond
    [(>= (bytes-length raw) expected-size) raw]
    [(zero? (bytes-length raw)) #""]
    [else
     (define ctype (bytes-ref raw 0))
     (define payload (subbytes raw 1))
     (cond
       [(= ctype #x02) (decompress-zlib payload)]
       [(= ctype #x10) (decompress-bzip2 payload)]
       [else
        (error 'decompress-mpq-sector
               "Unsupported MPQ compression mask 0x~x (len=~a expected=~a)"
               ctype (bytes-length raw) expected-size)])]))

;; -----------------------------------------------------------------------------
;; 3. MPQ Archive Reader (`read-mpq-files`)
;; -----------------------------------------------------------------------------

(define (read-mpq-files path-or-bytes
                        #:filenames [filenames '("replay.details" "replay.tracker.events")])
  (define blob
    (cond
      [(bytes? path-or-bytes) path-or-bytes]
      [else (file->bytes path-or-bytes)]))
  (define blob-len (bytes-length blob))
  (cond
    [(< blob-len 64) #f]
    [else
     (define magic0 (subbytes blob 0 4))
     (define-values (mpq-offset user-data)
       (cond
         [(bytes=? magic0 #"MPQ\x1b")
          (define off (u32-le blob 8))
          (define ud-sz (u32-le blob 12))
          (define ud-end (min blob-len (+ 16 ud-sz)))
          (values off (subbytes blob 16 ud-end))]
         [(bytes=? magic0 #"MPQ\x1a")
          (values 0 #"")]
         [else (values #f #"")]))
     (cond
       [(or (not mpq-offset)
            (> (+ mpq-offset 32) blob-len)
            (not (bytes=? (subbytes blob mpq-offset (+ mpq-offset 4)) #"MPQ\x1a")))
        #f]
       [else
        (define sector-shift (u16-le blob (+ mpq-offset 14)))
        (define ht-off (u32-le blob (+ mpq-offset 16)))
        (define bt-off (u32-le blob (+ mpq-offset 20)))
        (define ht-entries (u32-le blob (+ mpq-offset 24)))
        (define bt-entries (u32-le blob (+ mpq-offset 28)))
        (define sector-size (arithmetic-shift 512 sector-shift))

        (define ht-start (+ mpq-offset ht-off))
        (define ht-end (+ ht-start (* ht-entries 16)))
        (define bt-start (+ mpq-offset bt-off))
        (define bt-end (+ bt-start (* bt-entries 16)))
        (when (or (> ht-end blob-len) (> bt-end blob-len))
          (error 'read-mpq-files "MPQ hash/block table exceeds archive bounds"))

        (define ht-raw
          (mpq-decrypt (subbytes blob ht-start ht-end)
                       (mpq-hash "(hash table)" 3)))
        (define bt-raw
          (mpq-decrypt (subbytes blob bt-start bt-end)
                       (mpq-hash "(block table)" 3)))

        (define hash-map (make-hash))
        (for ([i (in-range ht-entries)])
          (define base (* i 16))
          (define ha (u32-le ht-raw base))
          (define hb (u32-le ht-raw (+ base 4)))
          (define blk-idx (u32-le ht-raw (+ base 12)))
          (when (< blk-idx bt-entries)
            (hash-set! hash-map (cons ha hb) blk-idx)))

        (define out (make-hash))
        (hash-set! out "_user_data" user-data)

        (for ([fname (in-list filenames)])
          (define ha (mpq-hash fname 1))
          (define hb (mpq-hash fname 2))
          (define blk-idx (hash-ref hash-map (cons ha hb) #f))
          (when blk-idx
            (define bbase (* blk-idx 16))
            (define f-off (u32-le bt-raw bbase))
            (define arch-sz (u32-le bt-raw (+ bbase 4)))
            (define full-sz (u32-le bt-raw (+ bbase 8)))
            (define flags (u32-le bt-raw (+ bbase 12)))
            (when (not (zero? (bitwise-and flags #x80000000))) ; MPQ_FILE_EXISTS
              (define abs-off (+ mpq-offset f-off))
              (define raw-file (subbytes blob abs-off (min blob-len (+ abs-off arch-sz))))
              (define compressed? (not (zero? (bitwise-and flags #x00000200))))
              (define single-unit? (not (zero? (bitwise-and flags #x01000000))))
              (define content
                (cond
                  [(zero? full-sz) #""]
                  [single-unit?
                   (if compressed?
                       (decompress-mpq-sector raw-file full-sz)
                       (subbytes raw-file 0 (min (bytes-length raw-file) full-sz)))]
                  [compressed?
                   (define n-sectors (quotient (+ full-sz sector-size -1) sector-size))
                   (define offsets
                     (for/vector ([s (in-range (add1 n-sectors))])
                       (u32-le raw-file (* s 4))))
                   (define parts
                     (let sec-loop ([s-idx 0]
                                    [rem full-sz]
                                    [acc '()])
                       (if (= s-idx n-sectors)
                           (reverse acc)
                           (let* ([s-start (vector-ref offsets s-idx)]
                                  [s-end (vector-ref offsets (add1 s-idx))]
                                  [s-bytes (subbytes raw-file s-start s-end)]
                                  [want (min sector-size rem)]
                                  [dec (decompress-mpq-sector s-bytes want)])
                             (sec-loop (add1 s-idx) (- rem want) (cons dec acc))))))
                   (apply bytes-append parts)]
                  [else
                   (subbytes raw-file 0 (min (bytes-length raw-file) full-sz))]))
              (hash-set! out fname content))))
        out])]))

;; -----------------------------------------------------------------------------
;; 4. S2Protocol VersionedDecoder & Tracker Event Stream Decoder
;; -----------------------------------------------------------------------------

(define (read-vint buf pos)
  (let ([b0 (bytes-ref buf pos)])
    (define neg? (= (bitwise-and b0 1) 1))
    (let loop ([b b0]
               [p (add1 pos)]
               [res (bitwise-and (arithmetic-shift b0 -1) #x3F)]
               [bits 6])
      (if (zero? (bitwise-and b #x80))
          (values (if neg? (- res) res) p)
          (let ([bn (bytes-ref buf p)])
            (loop bn
                  (add1 p)
                  (bitwise-ior res (arithmetic-shift (bitwise-and bn #x7F) bits))
                  (+ bits 7)))))))

(define (decode-versioned buf [pos 0])
  (define tag (bytes-ref buf pos))
  (define p1 (add1 pos))
  (case tag
    [(0) ; array
     (define-values (n p2) (read-vint buf p1))
     (let loop ([i 0] [p p2] [acc '()])
       (if (= i n)
           (values (reverse acc) p)
           (let-values ([(v pn) (decode-versioned buf p)])
             (loop (add1 i) pn (cons v acc)))))]
    [(1) ; bitarray
     (define-values (nbits p2) (read-vint buf p1))
     (define nbytes (quotient (+ nbits 7) 8))
     (values (subbytes buf p2 (+ p2 nbytes)) (+ p2 nbytes))]
    [(2) ; blob
     (define-values (n p2) (read-vint buf p1))
     (values (subbytes buf p2 (+ p2 n)) (+ p2 n))]
    [(3) ; choice
     (define-values (flag p2) (read-vint buf p1))
     (define-values (v p3) (decode-versioned buf p2))
     (values (cons 'choice (cons flag v)) p3)]
    [(4) ; optional
     (define has (bytes-ref buf p1))
     (if (zero? has)
         (values #f (add1 p1))
         (decode-versioned buf (add1 p1)))]
    [(5) ; struct
     (define-values (nf p2) (read-vint buf p1))
     (let loop ([i 0] [p p2] [h (hasheqv)])
       (if (= i nf)
           (values h p)
           (let*-values ([(ftag p-mid) (read-vint buf p)]
                         [(v pn) (decode-versioned buf p-mid)])
             (loop (add1 i) pn (hash-set h ftag v)))))]
    [(6) ; u8
     (values (bytes-ref buf p1) (add1 p1))]
    [(7) ; u32 (big-endian)
     (values (integer-bytes->integer buf #f #t p1 (+ p1 4)) (+ p1 4))]
    [(8) ; u64 (big-endian)
     (values (integer-bytes->integer buf #f #t p1 (+ p1 8)) (+ p1 8))]
    [(9) ; vint
     (read-vint buf p1)]
    [else
     (error 'decode-versioned "Unknown S2Protocol versioned tag ~a at byte ~a" tag pos)]))

(define (unwrap-choice v)
  (if (and (pair? v) (eq? (car v) 'choice))
      (cddr v)
      v))

(define (decode-tracker-stream buf)
  (define n (bytes-length buf))
  (let loop ([pos 0]
             [gl 0]
             [acc '()])
    (if (>= pos n)
        (reverse acc)
        (let*-values ([(v0 p1) (decode-versioned buf pos)]
                      [(ev-raw p2) (decode-versioned buf p1)]
                      [(payload p3) (decode-versioned buf p2)])
          (define d-gl
            (cond
              [(hash? v0)
               (define inner (unwrap-choice (hash-ref v0 0 0)))
               (if (exact-integer? inner) inner 0)]
              [(and (pair? v0) (eq? (car v0) 'choice))
               (define inner (cddr v0))
               (if (exact-integer? inner) inner 0)]
              [(exact-integer? v0) v0]
              [else 0]))
          (define gl* (+ gl d-gl))
          (define ev-id (unwrap-choice ev-raw))
          (loop p3 gl* (cons (list gl* ev-id payload) acc))))))

;; -----------------------------------------------------------------------------
;; 5. High-Level Structured Replay Parser (`parse-sc2-replay`)
;; -----------------------------------------------------------------------------

(define TH-NAMES
  '("CommandCenter"
    "OrbitalCommand"
    "PlanetaryFortress"
    "Nexus"
    "Hatchery"
    "Lair"
    "Hive"))

(define TECH-MORPH-NAMES
  '("Lair"
    "Hive"
    "OrbitalCommand"
    "PlanetaryFortress"
    "GreaterSpire"
    "WarpGate"))

(define NON-COMBAT-DEATHS
  '("Larva"
    "Egg"
    "MULE"
    "CreepTumor"
    "CreepTumorBurrowed"
    "CreepTumorQueen"))

(define (round1 x)
  (/ (round (* 10.0 (exact->inexact x))) 10.0))

(define (bytes->utf8-clean v [fallback ""])
  (cond
    [(bytes? v) (bytes->string/utf-8 v #\?)]
    [(string? v) v]
    [else fallback]))

(define (clean-player-name raw-bytes fallback)
  (define s0 (bytes->utf8-clean raw-bytes ""))
  ;; Strip SC2 clan markup e.g. "&lt;Clan&gt;<sp/>BotName" while keeping plain names intact
  (define s1 (regexp-replace* #rx"<sp/>" s0 " "))
  (define s2 (regexp-replace* #rx"&lt;[^&]*&gt;" s1 ""))
  (define s3 (string-trim (regexp-replace* #rx"<[^>]+>" s2 "")))
  (if (string=? s3 "") fallback s3))

(define (normalize-race-bytes raw-bytes)
  (define r (bytes->utf8-clean raw-bytes ""))
  (cond
    [(or (string-contains? r "Terran") (string-contains? r "테란") (string-contains? r "人类")) "Terran"]
    [(or (string-contains? r "Zerg") (string-contains? r "저그") (string-contains? r "异虫")) "Zerg"]
    [(or (string-contains? r "Protoss") (string-contains? r "프로토스") (string-contains? r "星灵")) "Protoss"]
    [(string-contains? r "Random") "Random"]
    [else (if (string=? (string-trim r) "") "Unknown" (string-trim r))]))

(define (result-code->string code)
  (case code
    [(1) "Win"]
    [(2) "Loss"]
    [(3) "Tie"]
    [else "Unknown"]))

(define (parse-sc2-replay rep-path)
  (define mpq (read-mpq-files rep-path #:filenames '("replay.details" "replay.tracker.events")))
  (unless (and mpq
               (hash-has-key? mpq "replay.details")
               (hash-has-key? mpq "replay.tracker.events"))
    (error 'parse-sc2-replay "Missing replay.details or replay.tracker.events in ~a" rep-path))

  ;; Decode user-data header for exact elapsed game loops & SC2 baseBuild
  (define user-data (hash-ref mpq "_user_data" #""))
  (define-values (base-build header-loops)
    (if (> (bytes-length user-data) 0)
        (with-handlers ([exn:fail? (lambda (_e) (values 0 0))])
          (define-values (hdr _pos) (decode-versioned user-data 0))
          (define ver (if (hash? hdr) (hash-ref hdr 1 (hasheqv)) (hasheqv)))
          (values (if (hash? ver) (hash-ref ver 5 0) 0)
                  (if (hash? hdr) (hash-ref hdr 3 0) 0)))
        (values 0 0)))

  (define-values (details _dpos) (decode-versioned (hash-ref mpq "replay.details") 0))
  (define plist (if (hash? details) (hash-ref details 0 '()) '()))
  (define map-name
    (if (hash? details)
        (bytes->utf8-clean (hash-ref details 1 #"Unknown Map"))
        "Unknown Map"))

  (define tracker-events (decode-tracker-stream (hash-ref mpq "replay.tracker.events")))

  ;; Map slot -> tracker player_id and detect Frame-0 actual rolled race
  (define slot->pid (make-hasheqv))
  (define f0-rolled-race (make-hasheqv))
  (for ([ev (in-list tracker-events)]
        #:break (> (car ev) 0))
    (define ev-id (cadr ev))
    (define payload (caddr ev))
    (when (hash? payload)
      (cond
        [(= ev-id 9) ; SPlayerSetupEvent
         (define pid (hash-ref payload 0 0))
         (define ptype (hash-ref payload 1 0))
         (define slot (hash-ref payload 3 #f))
         (when (and (memv ptype '(1 2)) (exact-integer? slot) (< slot (length plist)))
           (hash-set! slot->pid slot pid))]
        [(= ev-id 1) ; SUnitBornEvent at gl=0
         (define cp (hash-ref payload 3 0))
         (define ut (bytes->utf8-clean (hash-ref payload 2 #"")))
         (when (> cp 0)
           (cond
             [(member ut '("Hatchery" "Drone")) (hash-set! f0-rolled-race cp "Zerg")]
             [(member ut '("CommandCenter" "SCV")) (hash-set! f0-rolled-race cp "Terran")]
             [(member ut '("Nexus" "Probe")) (hash-set! f0-rolled-race cp "Protoss")]))])))

  (define players (make-hasheqv))
  (for ([p (in-list plist)]
        [slot-idx (in-naturals)]
        #:when (< (hash-count players) 2))
    (when (hash? p)
      (define pid (hash-ref slot->pid slot-idx (add1 slot-idx)))
      (define pname (clean-player-name (hash-ref p 0 #"") (format "Player~a" pid)))
      (define decl-race (normalize-race-bytes (hash-ref p 2 #"")))
      (define rolled-race (hash-ref f0-rolled-race pid decl-race))
      (define res-str (result-code->string (hash-ref p 8 0)))
      (hash-set! players pid
                 (hasheq 'pid pid
                         'name pname
                         'declared_race decl-race
                         'actual_race (if (string=? rolled-race "Unknown") decl-race rolled-race)
                         'result res-str))))

  ;; Ensure PIDs 1 and 2 exist even on degenerate replays
  (for ([pid (in-list '(1 2))])
    (unless (hash-has-key? players pid)
      (hash-set! players pid
                 (hasheq 'pid pid
                         'name (format "Player~a" pid)
                         'declared_race "Unknown"
                         'actual_race (hash-ref f0-rolled-race pid "Unknown")
                         'result "Unknown"))))

  (define born (hash 1 (make-hash) 2 (make-hash)))
  (define upgrades (hash 1 '() 2 '()))
  (define townhall-timings (hash 1 '() 2 '()))
  (define tech-morphs (hash 1 '() 2 '()))
  (define stats-by-min (hash 1 (make-hasheqv) 2 (make-hasheqv)))
  (define supply-blocked-steps (make-hasheqv '((1 . 0) (2 . 0))))
  (define total-stat-events (make-hasheqv '((1 . 0) (2 . 0))))
  (define unit-owner (make-hasheqv))
  (define unit-type (make-hasheqv))
  (define deaths-by-min (hash 1 (make-hash) 2 (make-hash)))
  (define max-tracker-loop 0)

  (define mut-upgrades (make-hasheqv '((1 . ()) (2 . ()))))
  (define mut-th (make-hasheqv '((1 . ()) (2 . ()))))
  (define mut-morphs (make-hasheqv '((1 . ()) (2 . ()))))

  (for ([ev (in-list tracker-events)])
    (define loop-gl (car ev))
    (define ev-id (cadr ev))
    (define payload (caddr ev))
    (when (> loop-gl max-tracker-loop)
      (set! max-tracker-loop loop-gl))
    (when (hash? payload)
      (define sec (/ loop-gl 22.4))
      (case ev-id
        [(1 6) ; SUnitBornEvent (1) or SUnitInitEvent (6)
         (define tag (bitwise-ior (arithmetic-shift (hash-ref payload 0 0) 18)
                                  (hash-ref payload 1 0)))
         (define p (hash-ref payload 3 0))
         (define u (bytes->utf8-clean (hash-ref payload 2 #"")))
         (hash-set! unit-owner tag p)
         (hash-set! unit-type tag u)
         (when (memv p '(1 2))
           (hash-update! (hash-ref born p) u add1 0)
           (when (and (> loop-gl 0) (member u TH-NAMES))
             (define label (if (= ev-id 6) (string-append "init:" u) u))
             (hash-update! mut-th p (lambda (lst) (cons (list (round1 sec) label) lst)))))]
        [(3) ; SUnitOwnerChangeEvent
         (define tag (bitwise-ior (arithmetic-shift (hash-ref payload 0 0) 18)
                                  (hash-ref payload 1 0)))
         (define p (hash-ref payload 2 0))
         (hash-set! unit-owner tag p)]
        [(4) ; SUnitTypeChangeEvent
         (define tag (bitwise-ior (arithmetic-shift (hash-ref payload 0 0) 18)
                                  (hash-ref payload 1 0)))
         (define u (bytes->utf8-clean (hash-ref payload 2 #"")))
         (define p (hash-ref unit-owner tag #f))
         (when (not (string=? u ""))
           (hash-set! unit-type tag u))
         (when (and (memv p '(1 2)) (> loop-gl 0) (member u TECH-MORPH-NAMES))
           (hash-update! mut-morphs p (lambda (lst) (cons (list (round1 sec) u) lst))))]
        [(2) ; SUnitDiedEvent
         (define tag (bitwise-ior (arithmetic-shift (hash-ref payload 0 0) 18)
                                  (hash-ref payload 1 0)))
         (define p (hash-ref unit-owner tag #f))
         (define u (hash-ref unit-type tag "?"))
         (when (and (memv p '(1 2)) (not (member u NON-COMBAT-DEATHS)))
           (define m (exact-floor (/ sec 60.0)))
           (hash-update! (hash-ref deaths-by-min p) (cons m u) add1 0))]
        [(5) ; SUpgradeEvent
         (define p (hash-ref payload 0 0))
         (define upg (bytes->utf8-clean (hash-ref payload 1 #"")))
         (when (and (memv p '(1 2))
                    (not (string=? upg ""))
                    (not (string-prefix? upg "Spray"))
                    (not (string-prefix? upg "RewardDance")))
           (hash-update! mut-upgrades p (lambda (lst) (cons (list (round1 sec) upg) lst))))]
        [(0) ; SPlayerStatsEvent
         (define p (hash-ref payload 0 0))
         (define st (hash-ref payload 1 #f))
         (when (and (memv p '(1 2)) (hash? st))
           (define food-used (quotient (hash-ref st 29 0) 4096))
           (define food-made (quotient (hash-ref st 30 0) 4096))
           (hash-update! total-stat-events p add1 0)
           (when (and (>= food-used food-made) (< food-made 200) (> loop-gl 224))
             (hash-update! supply-blocked-steps p add1 0))
           (define minute (exact-floor (/ sec 60.0)))
           (define snap
             (hasheq 'sec (round1 sec)
                     'loop loop-gl
                     'min_cur (hash-ref st 0 0)
                     'gas_cur (hash-ref st 1 0)
                     'min_rate (hash-ref st 2 0)
                     'gas_rate (hash-ref st 3 0)
                     'workers (hash-ref st 4 0)
                     'food_used food-used
                     'food_made food-made
                     'army_min (hash-ref st 11 0)
                     'army_gas (hash-ref st 14 0)
                     'econ_min (hash-ref st 12 0)
                     'tech_min (hash-ref st 13 0)
                     'tech_gas (hash-ref st 16 0)
                     'lost_min (+ (hash-ref st 17 0) (hash-ref st 18 0))
                     'lost_gas (+ (hash-ref st 20 0) (hash-ref st 21 0))
                     'lost_tech_min (hash-ref st 19 0)
                     'lost_tech_gas (hash-ref st 22 0)
                     'killed_min (+ (hash-ref st 23 0) (hash-ref st 24 0) (hash-ref st 25 0))
                     'killed_gas (+ (hash-ref st 26 0) (hash-ref st 27 0) (hash-ref st 28 0))))
           (hash-set! (hash-ref stats-by-min p) minute snap))])))

  (define final-loops (max header-loops max-tracker-loop))
  (define duration-sec (round1 (/ final-loops 22.4)))

  (hasheq 'replay_path (if (path? rep-path) (path->string rep-path) rep-path)
          'base_build base-build
          'game_loops final-loops
          'duration_sec duration-sec
          'map_name map-name
          'players players
          'born born
          'townhall_timings (hasheqv 1 (reverse (hash-ref mut-th 1))
                                     2 (reverse (hash-ref mut-th 2)))
          'tech_morphs (hasheqv 1 (reverse (hash-ref mut-morphs 1))
                                2 (reverse (hash-ref mut-morphs 2)))
          'upgrades (hasheqv 1 (reverse (hash-ref mut-upgrades 1))
                             2 (reverse (hash-ref mut-upgrades 2)))
          'stats_by_min stats-by-min
          'deaths_by_min deaths-by-min
          'supply_blocked_steps (hasheqv 1 (hash-ref supply-blocked-steps 1)
                                         2 (hash-ref supply-blocked-steps 2))
          'total_stat_events (hasheqv 1 (hash-ref total-stat-events 1)
                                      2 (hash-ref total-stat-events 2))))
