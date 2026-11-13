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
         is-morph-death?
         compute-swarmy-win-chance
         compute-turning-points
         cluster-combat-engagements
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
    "BanelingCocoon"
    "RavagerCocoon"
    "LurkerMPEgg"
    "BroodLordCocoon"
    "OverlordCocoon"
    "TransportOverlordCocoon"
    "MULE"
    "CreepTumor"
    "CreepTumorBurrowed"
    "CreepTumorQueen"
    "Broodling"
    "Interceptor"
    "AutoTurret"
    "PointDefenseDrone"
    "Changeling"
    "ChangelingZealot"
    "ChangelingMarine"
    "ChangelingMarineShield"
    "ChangelingZergling"
    "ChangelingZerglingWings"))

(define PROXY-CANDIDATE-STRUCTURES
  '("Barracks"
    "Factory"
    "Starport"
    "Gateway"
    "RoboticsFacility"
    "Stargate"
    "SpawningPool"))

;; Approximate mineral+gas resource values for engagement clustering & ROI
(define UNIT-RESOURCE-VALUE
  (hash "Drone" 50 "SCV" 50 "Probe" 50
        "Zergling" 25 "Baneling" 50 "Queen" 150 "Roach" 100 "Ravager" 200
        "Hydralisk" 150 "LurkerMP" 300 "Mutalisk" 200 "Corruptor" 250
        "Infestor" 250 "SwarmHostMP" 200 "Ultralisk" 475 "Viper" 300 "BroodLord" 550
        "Overlord" 100 "Overseer" 200 "SpawningPool" 200 "RoachWarren" 150
        "BanelingNest" 150 "Hatchery" 300 "Lair" 550 "Hive" 900 "SpineCrawler" 100 "SporeCrawler" 75
        "Marine" 50 "Marauder" 125 "Reaper" 100 "Ghost" 275 "Hellion" 100 "HellionTank" 100
        "WidowMine" 100 "SiegeTank" 275 "SiegeTankSieged" 275 "Cyclone" 225 "Thor" 500 "ThorAP" 500
        "VikingFighter" 225 "VikingAssault" 225 "Medivac" 200 "Liberator" 300 "LiberatorAG" 300
        "Banshee" 250 "Raven" 250 "Battlecruiser" 700
        "CommandCenter" 400 "OrbitalCommand" 550 "PlanetaryFortress" 650
        "Barracks" 150 "Factory" 250 "Starport" 250 "Bunker" 100 "SupplyDepot" 100 "SupplyDepotLowered" 100
        "Zealot" 100 "Stalker" 175 "Sentry" 150 "Adept" 125 "HighTemplar" 200 "DarkTemplar" 250
        "Archon" 400 "Observer" 100 "WarpPrism" 250 "Immortal" 375 "Colossus" 500 "Disruptor" 300
        "Phoenix" 250 "VoidRay" 400 "Oracle" 300 "Tempest" 425 "Carrier" 600 "Mothership" 700
        "Nexus" 400 "Pylon" 100 "Gateway" 150 "WarpGate" 150 "CyberneticsCore" 150
        "Forge" 150 "PhotonCannon" 150 "ShieldBattery" 100 "RoboticsFacility" 250 "Stargate" 300))

;; Swarmy's `is_morph_death` filter: in SC2 tracker streams, a Drone morphing into a
;; structure or HT/DT merging into an Archon emits SUnitDiedEvent with killerPlayerId = #f.
(define (is-morph-death? unit-name killer-pid)
  (and (not killer-pid)
       (not (not (member unit-name '("Drone" "HighTemplar" "DarkTemplar"))))))

(define (base-tracker-unit-name u)
  (cond
    [(string=? u "SiegeTankSieged") "SiegeTank"]
    [(string=? u "VikingAssault") "VikingFighter"]
    [(string=? u "LiberatorAG") "Liberator"]
    [(string=? u "ThorAP") "Thor"]
    [(string=? u "WarpPrismPhasing") "WarpPrism"]
    [(string=? u "SupplyDepotLowered") "SupplyDepot"]
    [(string=? u "WarpGate") "Gateway"]
    [(and (string-suffix? u "Burrowed")
          (not (string-prefix? u "CreepTumor")))
     (substring u 0 (- (string-length u) 8))]
    [else u]))

;; Swarmy's calibrated 4-factor logistic win-chance coefficients `[army income workers trades]`
(define SWARMY-WIN-COEFFS
  '((3.0  0.231 0.761 0.454 3.786)
    (5.0  0.224 1.215 0.738 2.724)
    (7.0  0.501 1.024 1.202 2.429)
    (9.0  1.017 0.910 1.704 2.616)
    (11.0 1.546 1.290 1.829 2.969)
    (13.0 1.738 1.502 1.684 3.238)
    (15.0 1.878 1.540 1.590 3.732)
    (17.0 1.855 1.633 1.443 4.344)
    (19.0 1.692 1.194 1.461 4.017)
    (21.0 1.892 1.489 1.104 3.615)
    (23.0 2.047 1.415 1.198 3.651)
    (25.0 1.154 0.731 0.914 2.923)))

(define (interp-win-coeffs minute)
  (cond
    [(<= minute 3.0) (cdr (first SWARMY-WIN-COEFFS))]
    [(>= minute 25.0) (cdr (last SWARMY-WIN-COEFFS))]
    [else
     (let loop ([ prev (first SWARMY-WIN-COEFFS)]
                [rest (cdr SWARMY-WIN-COEFFS)])
       (cond
         [(null? rest) (cdr prev)]
         [(<= minute (car (car rest)))
          (define m0 (car prev))
          (define m1 (car (car rest)))
          (define w (/ (- minute m0) (- m1 m0)))
          (for/list ([c0 (in-list (cdr prev))]
                     [c1 (in-list (cdr (car rest)))])
            (+ c0 (* w (- c1 c0))))]
         [else (loop (car rest) (cdr rest))]))]))

(define (round3 x)
  (/ (round (* 1000.0 (exact->inexact x))) 1000.0))

(define (compute-swarmy-win-chance sec
                                   #:p1-army p1-army #:p2-army p2-army
                                   #:p1-income p1-inc #:p2-income p2-inc
                                   #:p1-workers p1-wrk #:p2-workers p2-wrk
                                   #:p1-killed p1-kil #:p2-killed p2-kil)
  (define minute (/ (max 0.0 (- (exact->inexact sec) 30.0)) 60.0))
  (define coeffs (interp-win-coeffs minute))
  (define c-army (first coeffs))
  (define c-inc (second coeffs))
  (define c-wrk (third coeffs))
  (define c-trd (fourth coeffs))
  (define (log-ratio a b off)
    (log (/ (+ (max 0.0 (exact->inexact a)) off)
            (+ (max 0.0 (exact->inexact b)) off))))
  (define k-denom (+ (max 0.0 (exact->inexact p1-kil))
                     (max 0.0 (exact->inexact p2-kil))
                     1000.0))
  (define log-odds
    (+ (* c-army (log-ratio p1-army p2-army 200.0))
       (* c-inc  (log-ratio p1-inc  p2-inc  100.0))
       (* c-wrk  (log-ratio p1-wrk  p2-wrk  5.0))
       (* c-trd  (/ (- (max 0.0 (exact->inexact p1-kil))
                       (max 0.0 (exact->inexact p2-kil)))
                    k-denom))))
  (round3 (/ 1.0 (+ 1.0 (exp (- log-odds))))))

(define (cluster-combat-engagements raw-deaths)
  ;; Each element of `raw-deaths` is `(list sec owner-pid unit x y cost)` sorted by `sec`
  (define groups
    (for/fold ([gs '()]) ([d (in-list raw-deaths)])
      (define sec (first d))
      (cond
        [(null? gs) (list (list d))]
        [else
         (define cur (car gs))
         (define last-sec (first (car cur)))
         (define first-sec (first (last cur)))
         (if (and (<= (- sec last-sec) 12.0)
                  (<= (- sec first-sec) 60.0))
             (cons (cons d cur) (cdr gs))
             (cons (list d) gs))])))
  (filter
   values
   (for/list ([rev-g (in-list (reverse groups))])
     (define g (reverse rev-g))
     (define total-cost (for/sum ([d (in-list g)]) (sixth d)))
     (and (>= total-cost 400)
          (let* ([n (max 1 (length g))]
                 [cx (round1 (/ (for/sum ([d (in-list g)]) (fourth d)) n))]
                 [cy (round1 (/ (for/sum ([d (in-list g)]) (fifth d)) n))]
                 [p1-lost (for/sum ([d (in-list g)] #:when (= (second d) 1)) (sixth d))]
                 [p2-lost (for/sum ([d (in-list g)] #:when (= (second d) 2)) (sixth d))])
            (hasheq 'start_sec (round1 (first (first g)))
                    'end_sec (round1 (first (last g)))
                    'center_x cx
                    'center_y cy
                    'p1_lost p1-lost
                    'p2_lost p2-lost))))))

(define (compute-turning-points win-curve)
  ;; `win-curve` is a list of `(hasheq 'sec s 'p1_chance p)`
  (define vec (list->vector win-curve))
  (define n (vector-length vec))
  (cond
    [(<= n 1) '()]
    [else
     (define candidates
       (for/list ([i (in-range 1 n)]
                  #:when (>= (abs (- (hash-ref (vector-ref vec i) 'p1_chance)
                                     (hash-ref (vector-ref vec (sub1 i)) 'p1_chance)))
                             0.15))
         (define prev (vector-ref vec (sub1 i)))
         (define cur (vector-ref vec i))
         (hasheq 'start_sec (hash-ref prev 'sec)
                 'end_sec (hash-ref cur 'sec)
                 'delta_p1_chance
                 (round3 (- (hash-ref cur 'p1_chance)
                            (hash-ref prev 'p1_chance))))))
     (take (sort candidates
                 (lambda (a b)
                   (> (abs (hash-ref a 'delta_p1_chance))
                      (abs (hash-ref b 'delta_p1_chance)))))
           (min 3 (length candidates)))]))

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

  ;; Map slot -> tracker player_id, detect Frame-0 rolled race, and capture start TownHall (x, y)
  (define slot->pid (make-hasheqv))
  (define f0-rolled-race (make-hasheqv))
  (define start-xy (make-hasheqv))
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
         (define ux (hash-ref payload 5 0))
         (define uy (hash-ref payload 6 0))
         (when (> cp 0)
           (when (member ut '("Hatchery" "CommandCenter" "Nexus"))
             (hash-set! start-xy cp (list ux uy)))
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
  (define unit-inits (hash 1 (make-hash) 2 (make-hash)))
  (define unit-dones (hash 1 (make-hash) 2 (make-hash)))
  (define killed-by (hash 1 (make-hash) 2 (make-hash)))
  (define stats-by-min (hash 1 (make-hasheqv) 2 (make-hasheqv)))
  (define supply-blocked-steps (make-hasheqv '((1 . 0) (2 . 0))))
  (define total-stat-events (make-hasheqv '((1 . 0) (2 . 0))))
  (define creep-placed (make-hasheqv '((1 . 0) (2 . 0))))
  (define creep-cleared (make-hasheqv '((1 . 0) (2 . 0))))
  (define unit-owner (make-hasheqv))
  (define unit-type (make-hasheqv))
  (define unit-was-init (make-hasheqv))
  (define deaths-by-min (hash 1 (make-hash) 2 (make-hash)))
  (define max-tracker-loop 0)

  (define mut-upgrades (make-hasheqv '((1 . ()) (2 . ()))))
  (define mut-th (make-hasheqv '((1 . ()) (2 . ()))))
  (define mut-morphs (make-hasheqv '((1 . ()) (2 . ()))))
  (define mut-proxies (make-hasheqv '((1 . ()) (2 . ()))))
  (define mut-bases-lost (make-hasheqv '((1 . ()) (2 . ()))))
  (define raw-deaths-rev '())

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
         (define ux (hash-ref payload 5 0))
         (define uy (hash-ref payload 6 0))
         (hash-set! unit-owner tag p)
         (hash-set! unit-type tag u)
         (when (= ev-id 6)
           (hash-set! unit-was-init tag #t))
         (when (memv p '(1 2))
           (hash-update! (hash-ref born p) u add1 0)
           (when (and (= ev-id 1) (string=? u "CreepTumorBurrowed"))
             (hash-update! creep-placed p add1 0))
           (when (= ev-id 6)
             (hash-update! (hash-ref unit-inits p) u add1 0)
             (when (and (<= sec 240.0)
                        (member u PROXY-CANDIDATE-STRUCTURES)
                        (hash-has-key? start-xy p))
               (define sxy (hash-ref start-xy p))
               (define dist (sqrt (+ (sqr (- ux (first sxy)))
                                     (sqr (- uy (second sxy))))))
               (when (> dist 50.0)
                 (hash-update! mut-proxies p
                               (lambda (lst) (cons (list (round1 sec) u (round1 dist)) lst))))))
           (when (and (> loop-gl 0) (member u TH-NAMES))
             (define label (if (= ev-id 6) (string-append "init:" u) u))
             (hash-update! mut-th p (lambda (lst) (cons (list (round1 sec) label) lst)))))]
        [(7) ; SUnitDoneEvent (construction completed)
         (define tag (bitwise-ior (arithmetic-shift (hash-ref payload 0 0) 18)
                                  (hash-ref payload 1 0)))
         (define p (hash-ref unit-owner tag #f))
         (define u (hash-ref unit-type tag #f))
         (when (and (memv p '(1 2)) (string? u) (hash-ref unit-was-init tag #f))
           (hash-update! (hash-ref unit-dones p) u add1 0))]
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
         (when (and (memv p '(1 2)) (string=? u "CreepTumorBurrowed"))
           (hash-update! creep-placed p add1 0))
         (when (and (memv p '(1 2)) (> loop-gl 0) (member u TECH-MORPH-NAMES))
           (hash-update! mut-morphs p (lambda (lst) (cons (list (round1 sec) u) lst))))]
        [(2) ; SUnitDiedEvent (0=tagIdx, 1=tagRec, 2=killerPid, 3=x, 4=y, 5=killerTagIdx, 6=killerTagRec)
         (define tag (bitwise-ior (arithmetic-shift (hash-ref payload 0 0) 18)
                                  (hash-ref payload 1 0)))
         (define p (hash-ref unit-owner tag #f))
         (define u (hash-ref unit-type tag "?"))
         (define killer-pid (hash-ref payload 2 #f))
         (define dx (hash-ref payload 3 0))
         (define dy (hash-ref payload 4 0))
         (define k-idx (hash-ref payload 5 #f))
         (define k-rec (hash-ref payload 6 #f))
         (define killer-tag
           (and (exact-integer? k-idx)
                (exact-integer? k-rec)
                (bitwise-ior (arithmetic-shift k-idx 18) k-rec)))
         (define killer-unit
           (if killer-tag
               (base-tracker-unit-name (hash-ref unit-type killer-tag "Unknown"))
               (if killer-pid "Unknown" "Canceled/Environment")))
         (when (and (memv p '(1 2))
                    (string=? u "CreepTumorBurrowed")
                    (equal? killer-pid (if (= p 1) 2 1)))
           (hash-update! creep-cleared p add1 0))
         (when (and (memv p '(1 2))
                    (not (member u NON-COMBAT-DEATHS))
                    (not (is-morph-death? u killer-pid)))
           (define m (exact-floor (/ sec 60.0)))
           (hash-update! (hash-ref deaths-by-min p) (cons m u) add1 0)
           (when killer-pid
             (hash-update! (hash-ref killed-by p) killer-unit add1 0))
           (when (member u TH-NAMES)
             (hash-update! mut-bases-lost p
                           (lambda (lst) (cons (list (round1 sec) u killer-unit) lst))))
           (define u-base (base-tracker-unit-name u))
           (define res-cost (hash-ref UNIT-RESOURCE-VALUE u-base 0))
           (when (> res-cost 0)
             (set! raw-deaths-rev (cons (list sec p u-base dx dy res-cost) raw-deaths-rev))))]
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

  ;; Compute incomplete/canceled/sniped structures (`init > done`) per player
  (define (incomplete-for p)
    (define inits-h (hash-ref unit-inits p))
    (define dones-h (hash-ref unit-dones p))
    (sort
     (for/list ([(u ic) (in-hash inits-h)]
                #:when (> ic (hash-ref dones-h u 0)))
       (list u ic (hash-ref dones-h u 0)))
     (lambda (a b) (string<? (car a) (car b)))))

  ;; Compute minute-by-minute Swarmy logistic win-chance curve (minutes >= 2)
  (define s1-mins (hash-ref stats-by-min 1))
  (define s2-mins (hash-ref stats-by-min 2))
  (define shared-mins
    (sort (filter (lambda (m) (and (>= m 2) (hash-has-key? s2-mins m)))
                  (hash-keys s1-mins))
          <))
  (define win-chance-curve
    (for/list ([m (in-list shared-mins)])
      (define a (hash-ref s1-mins m))
      (define b (hash-ref s2-mins m))
      (define p1c
        (compute-swarmy-win-chance
         (* m 60)
         #:p1-army (+ (hash-ref a 'army_min 0) (hash-ref a 'army_gas 0))
         #:p2-army (+ (hash-ref b 'army_min 0) (hash-ref b 'army_gas 0))
         #:p1-income (+ (hash-ref a 'min_rate 0) (hash-ref a 'gas_rate 0))
         #:p2-income (+ (hash-ref b 'min_rate 0) (hash-ref b 'gas_rate 0))
         #:p1-workers (hash-ref a 'workers 0)
         #:p2-workers (hash-ref b 'workers 0)
         #:p1-killed (+ (hash-ref a 'killed_min 0) (hash-ref a 'killed_gas 0))
         #:p2-killed (+ (hash-ref b 'killed_min 0) (hash-ref b 'killed_gas 0))))
      (hasheq 'sec (* m 60) 'p1_chance p1c)))

  (define engagements (cluster-combat-engagements (reverse raw-deaths-rev)))
  (define turning-points (compute-turning-points win-chance-curve))

  (define final-loops (max header-loops max-tracker-loop))
  (define duration-sec (round1 (/ final-loops 22.4)))

  (hasheq 'replay_path (if (path? rep-path) (path->string rep-path) rep-path)
          'base_build base-build
          'game_loops final-loops
          'duration_sec duration-sec
          'map_name map-name
          'players players
          'start_xy start-xy
          'born born
          'unit_inits unit-inits
          'unit_dones unit-dones
          'incomplete_structures (hasheqv 1 (incomplete-for 1)
                                          2 (incomplete-for 2))
          'proxy_structures (hasheqv 1 (reverse (hash-ref mut-proxies 1))
                                     2 (reverse (hash-ref mut-proxies 2)))
          'bases_lost (hasheqv 1 (reverse (hash-ref mut-bases-lost 1))
                               2 (reverse (hash-ref mut-bases-lost 2)))
          'killed_by killed-by
          'creep_tumors (hasheqv 1 (hasheq 'placed (hash-ref creep-placed 1)
                                           'cleared (hash-ref creep-cleared 1))
                                 2 (hasheq 'placed (hash-ref creep-placed 2)
                                           'cleared (hash-ref creep-cleared 2)))
          'engagements engagements
          'win_chance_curve win-chance-curve
          'turning_points turning-points
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
