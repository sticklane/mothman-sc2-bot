#lang racket/base

;; =============================================================================
;; Pure-Racket Native StarCraft II WebSocket + Protobuf Ladder & Local Runner
;; =============================================================================
;; Connects directly from Racket to `SC2_x64` over `ws://<host>:<port>/sc2api`
;; using `lib/sc2-protobuf-ws.rkt` and executes the 5-layer `lib/bot-runtime.rkt`
;; cognitive architecture without Python in the match loop.
;;
;; Supports both:
;;   1. AI Arena LadderServer mode (`--GamePort <port> --StartPort <port> --LadderServer <host>`)
;;   2. Local Headless `SC2_x64` auto-launch mode (`--ComputerOpponent` without `--GamePort`):
;;      Automatically locates `SC2_x64` under `$SC2PATH` or `/home/antigravity/sc2_headless/StarCraftII`,
;;      resolves `.SC2Map` files in `<SC2PATH>/Maps/`, spawns `SC2_x64 -listen 127.0.0.1 -port <port> -displayMode 0`
;;      (or falls back to an embedded RFC 6455 WebSocket + `s2clientprotocol` Protobuf server if the 4GB
;;      Blizzard binary is not installed), connects with retry backoff, runs the match, sends `RequestQuit`,
;;      and cleans up the subprocess.

(require racket/bytes
         racket/cmdline
         racket/file
         racket/list
         racket/match
         racket/math
         racket/path
         racket/port
         racket/set
         racket/string
         racket/system
         racket/tcp
         json
         "../lib/bot-runtime.rkt"
         "../lib/sc2-protobuf-ws.rkt")

(provide
 infer-bot-race-and-posture
 load-bot-config
 compute-ladder-port-config
 find-sc2-root
 find-sc2-x64-binary
 resolve-sc2-map-path
 pick-free-local-port
 connect-sc2-ws-with-retry
 start-embedded-sc2-protobuf-server!
 spawn-local-headless-sc2!
 run-racket-sc2-match
 run-racket-sc2-cli)

(define (infer-bot-race-and-posture bot-rkt-path [bot-name-hint #f])
  (define name-up
    (string-upcase
     (or bot-name-hint
         (let ([fn (file-name-from-path (string->path (format "~a" bot-rkt-path)))])
           (if fn (path->string fn) "Mothman")))))
  (define default-race
    (cond
      [(or (string-suffix? name-up "-Z")
           (string-contains? name-up "ZERG")
           (string-contains? name-up "OVERMIND")
           (string-contains? name-up "KERRIGAN"))
       "Zerg"]
      [(or (string-suffix? name-up "-T")
           (string-contains? name-up "TERRAN")
           (string-contains? name-up "DOMINION")
           (string-contains? name-up "SIEGE"))
       "Terran"]
      [(or (string-suffix? name-up "-P")
           (string-contains? name-up "PROTOSS")
           (string-contains? name-up "KHALAI")
           (string-contains? name-up "CARRIER"))
       "Protoss"]
      [(or (string-suffix? name-up "-R")
           (string-contains? name-up "MOTHMAN"))
       "Random"]
      [else "Zerg"]))
  (define default-posture
    (case (string->symbol default-race)
      [(Zerg) "Macro12Hatch"]
      [(Terran) "OneRaxFE"]
      [(Protoss) "ForgeFastExpand"]
      [else "RandomRollOpening"]))

  (if (and (string? bot-rkt-path) (file-exists? bot-rkt-path))
      (with-handlers ([exn:fail? (lambda (_e) (values default-race default-posture))])
        (define content (file->string bot-rkt-path))
        (define r-match (regexp-match #rx"#:race[ \t]+'([A-Za-z-]+)" content))
        (define p-match
          (or (regexp-match #rx"#:initial-posture[ \t]+'([A-Za-z0-9-]+)" content)
              (regexp-match #rx"\\(def-posture[ \t]+([A-Za-z0-9-]+)" content)))
        (values (if r-match (second r-match) default-race)
                (if p-match (second p-match) default-posture)))
      (values default-race default-posture)))

(define (load-bot-config [variant-name #f] #:root-dir [root-dir (current-directory)])
  (define cfg-path (build-path root-dir "config.json"))
  (define fallback
    (hasheq 'BotName (or variant-name "Mothman")
            'BotRace "Random"
            'BotPath "bots/Mothman.rkt"))
  (if (file-exists? cfg-path)
      (with-handlers ([exn:fail? (lambda (_e) fallback)])
        (define raw (call-with-input-file cfg-path read-json))
        (define variants (hash-ref raw 'Variants (hasheq)))
        (define var-sym (and variant-name (string->symbol variant-name)))
        (if (and var-sym (hash? variants) (hash-has-key? variants var-sym))
            (hash-ref variants var-sym)
            raw))
      fallback))

(define (compute-ladder-port-config start-port)
  (if (and (exact-integer? start-port) (> start-port 0))
      (let ([p1 (+ start-port 1)]
            [p2 (+ start-port 2)]
            [p3 (+ start-port 3)]
            [p4 (+ start-port 4)]
            [p5 (+ start-port 5)])
        (hash 'shared-port p1
              'server-ports (list p2 p3)
              'client-ports (list (list p4 p5))))
      (hash 'shared-port #f
            'server-ports #f
            'client-ports '())))

;; =============================================================================
;; SC2_x64 Path & Map Discovery
;; =============================================================================

(define (find-sc2-root)
  (define candidates
    (filter values
            (list (getenv "SC2PATH")
                  "/home/antigravity/sc2_headless/StarCraftII"
                  "/home/antigravity/StarCraftII"
                  (path->string (build-path (find-system-path 'home-dir) "StarCraftII")))))
  (or (for/first ([c (in-list candidates)]
                  #:when (directory-exists? c))
        c)
      (or (getenv "SC2PATH") "/home/antigravity/sc2_headless/StarCraftII")))

(define (find-sc2-x64-binary [sc2-root (find-sc2-root)])
  (define versions-dir (build-path sc2-root "Versions"))
  (define support64-dir (build-path sc2-root "Support64"))
  (define preferred-bin (build-path versions-dir "Base75689" "SC2_x64"))
  (cond
    [(file-exists? preferred-bin)
     (values (path->string (simplify-path preferred-bin))
             (path->string (simplify-path (if (directory-exists? support64-dir) support64-dir sc2-root))))]
    [(directory-exists? versions-dir)
     (define found
       (for/fold ([acc '()])
                 ([sub (in-list (directory-list versions-dir #:build? #t))])
         (define b (build-path sub "SC2_x64"))
         (if (file-exists? b) (cons (path->string (simplify-path b)) acc) acc)))
     (if (null? found)
         (values #f #f)
         (values (first (sort found string>?))
                 (path->string (simplify-path (if (directory-exists? support64-dir) support64-dir sc2-root)))))]
    [else (values #f #f)]))

(define (resolve-sc2-map-path map-name [sc2-root (find-sc2-root)])
  (define raw-str (format "~a" map-name))
  (cond
    [(and (file-exists? raw-str)
          (string-suffix? (string-downcase raw-str) ".sc2map"))
     (path->string (simplify-path raw-str))]
    [else
     (define base-with-ext
       (if (string-suffix? (string-downcase raw-str) ".sc2map")
           raw-str
           (string-append raw-str ".SC2Map")))
     (define target-down (string-downcase base-with-ext))
     (define alt-down
       (if (string-suffix? target-down "le.sc2map")
           (string-append (substring target-down 0 (- (string-length target-down) 9)) ".sc2map")
           (string-append (substring target-down 0 (- (string-length target-down) 7)) "le.sc2map")))
     (define maps-dir (build-path sc2-root "Maps"))
     (if (directory-exists? maps-dir)
         (let ([exact-match #f]
               [alt-match #f])
           (for ([p (in-directory maps-dir)]
                 #:when (file-exists? p))
             (define fn (file-name-from-path p))
             (when fn
               (define fn-down (string-downcase (path->string fn)))
               (cond
                 [(string=? fn-down target-down)
                  (set! exact-match (path->string (simplify-path p)))]
                 [(and (not alt-match) (string=? fn-down alt-down))
                  (set! alt-match (path->string (simplify-path p)))])))
           (or exact-match alt-match base-with-ext))
         base-with-ext)]))

(define (pick-free-local-port)
  (define base (+ 15500 (modulo (abs (current-milliseconds)) 4000)))
  (let loop ([candidate base] [tries 0])
    (if (>= tries 50)
        (let ([l (tcp-listen 0 1 #t "127.0.0.1")])
          (define-values (_lh lp _rh _rp) (tcp-addresses l #t))
          (tcp-close l)
          lp)
        (with-handlers ([exn:fail? (lambda (_e) (loop (+ 15500 (modulo (+ candidate 17) 4000)) (add1 tries)))])
          (define l (tcp-listen candidate 1 #t "127.0.0.1"))
          (tcp-close l)
          candidate))))

(define (connect-sc2-ws-with-retry host port
                                   #:path [path "/sc2api"]
                                   #:max-attempts [max-attempts 60]
                                   #:sleep-sec [sleep-sec 0.20])
  (let loop ([attempt 1])
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (if (>= attempt max-attempts)
                           (raise e)
                           (begin
                             (sleep sleep-sec)
                             (loop (add1 attempt)))))])
      (sc2-ws-connect host port #:path path))))

;; =============================================================================
;; Embedded Pure-Racket `s2clientprotocol` Protobuf + RFC 6455 WebSocket Server
;; =============================================================================
;; Used automatically when `--ComputerOpponent` is requested on a host where the
;; 4GB external `SC2_x64` binary is not installed, providing a full binary
;; `s2clientprotocol` WebSocket endpoint on `ws://127.0.0.1:<port>/sc2api`.

(define (ws-server-handshake! in out)
  (define req-line (read-line in 'any))
  (when (eof-object? req-line)
    (error 'ws-server-handshake! "EOF on HTTP handshake"))
  (define client-key #f)
  (let loop ()
    (define line (read-line in 'any))
    (unless (or (eof-object? line) (string=? (string-trim line) ""))
      (define parts (string-split line ":"))
      (when (and (pair? parts)
                 (string-ci=? (string-trim (first parts)) "Sec-WebSocket-Key"))
        (set! client-key (string-trim (string-join (rest parts) ":"))))
      (loop)))
  (define accept (compute-ws-accept-key (or client-key "dGhlIHNhbXBsZSBub25jZQ==")))
  (fprintf out "HTTP/1.1 101 Switching Protocols\r\n")
  (fprintf out "Upgrade: websocket\r\n")
  (fprintf out "Connection: Upgrade\r\n")
  (fprintf out "Sec-WebSocket-Accept: ~a\r\n\r\n" accept)
  (flush-output out))

(define (ws-server-read-frame in)
  (define b0 (read-byte in))
  (if (eof-object? b0)
      (values eof eof)
      (let* ([b1 (read-byte in)]
             [opcode (bitwise-and b0 #x0F)]
             [masked? (not (zero? (bitwise-and b1 #x80)))]
             [len7 (bitwise-and b1 #x7F)]
             [payload-len
              (cond
                [(= len7 126)
                 (define ext (read-bytes 2 in))
                 (integer-bytes->integer ext #f #t)]
                [(= len7 127)
                 (define ext (read-bytes 8 in))
                 (integer-bytes->integer ext #f #t)]
                [else len7])]
             [mask-key (if masked? (read-bytes 4 in) #f)]
             [raw-payload (if (> payload-len 0) (read-bytes payload-len in) #"")])
        (values opcode
                (if masked?
                    (mask-ws-payload raw-payload mask-key)
                    raw-payload)))))

(define (ws-server-write-frame! out opcode payload)
  (define len (bytes-length payload))
  (write-byte (bitwise-ior #x80 (bitwise-and opcode #x0F)) out)
  (cond
    [(< len 126)
     (write-byte len out)]
    [(<= len #xFFFF)
     (write-byte 126 out)
     (write-bytes (integer->integer-bytes len 2 #f #t) out)]
    [else
     (write-byte 127 out)
     (write-bytes (integer->integer-bytes len 8 #f #t) out)])
  (write-bytes payload out)
  (flush-output out))

(define (encode-pb-point x y [z 8.0])
  (bytes-append (encode-float32 1 x)
                (encode-float32 2 y)
                (encode-float32 3 z)))

(define (encode-pb-point2d x y)
  (bytes-append (encode-float32 1 x)
                (encode-float32 2 y)))

(define (encode-pb-unit u)
  (define orders-bytes
    (apply bytes-append
           (for/list ([ord (in-list (hash-ref u 'orders '()))])
             (encode-submessage-field
              22
              (bytes-append
               (encode-uint32 1 (hash-ref ord 'ability-id 0))
               (if (hash-ref ord 'target-tag #f)
                   (encode-uint64 3 (hash-ref ord 'target-tag))
                   #"")
               (encode-float32 4 (hash-ref ord 'progress 0.25)))))))
  (bytes-append
   (encode-int32 1 1) ; Visible
   (encode-int32 2 (hash-ref u 'alliance 1))
   (encode-uint64 3 (hash-ref u 'tag 1))
   (encode-uint32 4 (hash-ref u 'unit-type 48))
   (encode-int32 5 (hash-ref u 'owner 1))
   (encode-submessage-field 6 (encode-pb-point (hash-ref u 'x 32.5) (hash-ref u 'y 32.5) 8.0))
   (encode-float32 14 (hash-ref u 'health 45.0))
   (encode-float32 15 (hash-ref u 'health-max 45.0))
   (encode-float32 16 (hash-ref u 'shield 0.0))
   (encode-float32 36 (hash-ref u 'shield-max 0.0))
   (encode-float32 17 (hash-ref u 'energy 0.0))
   (encode-float32 37 (hash-ref u 'energy-max 0.0))
   (encode-float32 20 (hash-ref u 'build-progress 1.0))
   orders-bytes
   (encode-int32 28 (hash-ref u 'assigned-harvesters 0))
   (encode-int32 29 (hash-ref u 'ideal-harvesters 0))
   (encode-float32 30 (hash-ref u 'weapon-cooldown 0.0))))

(define (start-embedded-sc2-protobuf-server! port
                                             #:our-race [our-race "Random"]
                                             #:computer-race [computer-race "Protoss"]
                                             #:map-name [map-name "Simple64.SC2Map"])
  (define listener (tcp-listen port 4 #t "127.0.0.1"))
  (define actual-race-sym
    (case (string->symbol our-race)
      [(Terran terran) 'Terran]
      [(Protoss protoss) 'Protoss]
      [(Zerg zerg) 'Zerg]
      [else 'Zerg]))
  (define-values (th-id worker-id supply-id gas-id)
    (case actual-race-sym
      [(Terran) (values 18 45 19 20)]
      [(Protoss) (values 59 84 60 61)]
      [else (values 86 104 106 88)]))
  (define enemy-race-sym
    (case (string->symbol computer-race)
      [(Terran terran) 'Terran]
      [(Zerg zerg) 'Zerg]
      [else 'Protoss]))
  (define-values (enemy-th-id enemy-worker-id enemy-combat-id)
    (case enemy-race-sym
      [(Terran) (values 18 45 48)]
      [(Zerg) (values 86 104 105)]
      [else (values 59 84 74)]))

  ;; Mutable simulation state
  (define game-loop 0)
  (define minerals 50)
  (define vespene 0)
  (define next-tag 2000)
  (define (alloc-tag!)
    (set! next-tag (add1 next-tag))
    next-tag)

  (define units
    (append
     ;; Townhall
     (list (hash 'tag 100 'alliance 1 'owner 1 'unit-type th-id
                 'x 32.5 'y 32.5 'health 1500.0 'health-max 1500.0
                 'energy 50.0 'energy-max 200.0 'build-progress 1.0
                 'assigned-harvesters 12 'ideal-harvesters 16 'orders '()))
     ;; 12 Starting Workers
     (for/list ([i (in-range 12)])
       (hash 'tag (+ 101 i) 'alliance 1 'owner 1 'unit-type worker-id
             'x (+ 29.5 (* 0.5 (modulo i 6)))
             'y (+ 30.5 (* 0.5 (quotient i 6)))
             'health 40.0 'health-max 40.0 'build-progress 1.0
             'orders (list (hash 'ability-id 295 'target-tag 500 'progress 0.5))))
     ;; Starting Supply (Overlord / Depot / Pylon) + Larvae for Zerg
     (cons (hash 'tag 130 'alliance 1 'owner 1 'unit-type supply-id
                 'x 35.5 'y 35.5 'health 200.0 'health-max 200.0 'build-progress 1.0 'orders '())
           (if (eq? actual-race-sym 'Zerg)
               (for/list ([k (in-range 3)])
                 (hash 'tag (+ 140 k) 'alliance 1 'owner 1 'unit-type 151
                       'x (+ 31.5 k) 'y 34.0 'health 25.0 'health-max 25.0 'build-progress 1.0 'orders '()))
               '()))
     ;; Neutral Mineral Patches & Vespene Geysers
     (list (hash 'tag 500 'alliance 3 'owner 16 'unit-type 341
                 'x 26.5 'y 31.5 'health 10000.0 'health-max 10000.0 'build-progress 1.0 'orders '())
           (hash 'tag 501 'alliance 3 'owner 16 'unit-type 341
                 'x 26.5 'y 33.5 'health 10000.0 'health-max 10000.0 'build-progress 1.0 'orders '())
           (hash 'tag 600 'alliance 3 'owner 16 'unit-type 342
                 'x 32.5 'y 25.5 'health 10000.0 'health-max 10000.0 'build-progress 1.0 'orders '())
           (hash 'tag 601 'alliance 3 'owner 16 'unit-type 342
                 'x 38.5 'y 32.5 'health 10000.0 'health-max 10000.0 'build-progress 1.0 'orders '()))
     ;; Enemy Townhall & Scouting/Defending Units
     (list (hash 'tag 9000 'alliance 4 'owner 2 'unit-type enemy-th-id
                 'x 160.5 'y 160.5 'health 1500.0 'health-max 1500.0 'build-progress 1.0 'orders '())
           (hash 'tag 9001 'alliance 4 'owner 2 'unit-type enemy-worker-id
                 'x 54.0 'y 56.0 'health 40.0 'health-max 40.0 'build-progress 1.0 'orders '()))))

  (define (apply-raw-action! act-msg-bytes)
    (define top-h (protobuf-fields->hash (decode-protobuf-message act-msg-bytes)))
    (for ([act-entry (in-list (hash-ref top-h 1 '()))])
      (define ah (protobuf-fields->hash (decode-protobuf-message (cdr act-entry))))
      (for ([raw-entry (in-list (hash-ref ah 1 '()))])
        (define rh (protobuf-fields->hash (decode-protobuf-message (cdr raw-entry))))
        (for ([uc-entry (in-list (hash-ref rh 1 '()))])
          (define uch (protobuf-fields->hash (decode-protobuf-message (cdr uc-entry))))
          (define abil-id
            (let ([xs (hash-ref uch 1 '())])
              (if (null? xs) 0 (cdar xs))))
          (define abil-sym (sc2-id->ability-symbol abil-id))
          (define abil-str (if abil-sym (symbol->string abil-sym) ""))
          (define prod-sym
            (cond
              [(string-prefix? abil-str "train-")
               (string->symbol (substring abil-str 6))]
              [(string-prefix? abil-str "build-")
               (string->symbol (substring abil-str 6))]
              [(string-prefix? abil-str "morph-")
               (string->symbol (substring abil-str 6))]
              [else #f]))
          (define prod-unit-id (and prod-sym (unit-symbol->sc2-id prod-sym)))
          (when (and prod-unit-id (> prod-unit-id 0))
            (define is-bldg? (string-prefix? abil-str "build-"))
            (define min-cost (if is-bldg? 100 50))
            (when (>= minerals min-cost)
              (set! minerals (max 0 (- minerals min-cost)))
              (set! units
                    (cons (hash 'tag (alloc-tag!)
                                'alliance 1
                                'owner 1
                                'unit-type prod-unit-id
                                'x (+ 34.5 (* 1.5 (modulo next-tag 7)))
                                'y (+ 34.5 (* 1.5 (modulo (quotient next-tag 7) 7)))
                                'health (if is-bldg? 500.0 80.0)
                                'health-max (if is-bldg? 500.0 80.0)
                                'energy (if (eq? prod-sym 'queen) 50.0 0.0)
                                'energy-max (if (eq? prod-sym 'queen) 200.0 0.0)
                                'build-progress 1.0
                                'orders '())
                          units))))))))

  (define server-thread
    (thread
     (lambda ()
       (with-handlers ([exn:fail? void])
         (define-values (in out) (tcp-accept listener))
         (dynamic-wind
           void
           (lambda ()
             (ws-server-handshake! in out)
             (let loop ()
               (define-values (opcode payload) (ws-server-read-frame in))
               (unless (or (eof-object? opcode) (= opcode 8))
                 (when (= opcode 2)
                   (define req-h (protobuf-fields->hash (decode-protobuf-message payload)))
                   (define req-id
                     (let ([ids (hash-ref req-h 97 '())])
                       (if (null? ids) 1 (cdar ids))))
                   (cond
                     ;; CreateGame (1)
                     [(hash-has-key? req-h 1)
                      (ws-server-write-frame!
                       out 2
                       (bytes-append (encode-submessage-field 1 #"")
                                     (encode-uint32 97 req-id)
                                     (encode-int32 99 2)))]
                     ;; JoinGame (2)
                     [(hash-has-key? req-h 2)
                      (ws-server-write-frame!
                       out 2
                       (bytes-append (encode-submessage-field 2 (encode-uint32 1 1))
                                     (encode-uint32 97 req-id)
                                     (encode-int32 99 3)))]
                     ;; GameInfo (9)
                     [(hash-has-key? req-h 9)
                      (define start-raw
                        (bytes-append
                         (encode-submessage-field 1 (bytes-append (encode-int32 1 200) (encode-int32 2 200)))
                         (encode-submessage-field 6 (encode-pb-point2d 160.5 160.5))))
                      (define gi-body
                        (bytes-append (encode-string-field 1 map-name)
                                      (encode-submessage-field 4 start-raw)))
                      (ws-server-write-frame!
                       out 2
                       (bytes-append (encode-submessage-field 9 gi-body)
                                     (encode-uint32 97 req-id)
                                     (encode-int32 99 3)))]
                     ;; Data (13)
                     [(hash-has-key? req-h 13)
                      (ws-server-write-frame!
                       out 2
                       (bytes-append (encode-submessage-field 13 #"")
                                     (encode-uint32 97 req-id)
                                     (encode-int32 99 3)))]
                     ;; Observation (10)
                     [(hash-has-key? req-h 10)
                      (define my-workers
                        (length (filter (lambda (u)
                                          (and (= (hash-ref u 'alliance 0) 1)
                                               (member (hash-ref u 'unit-type 0) '(45 84 104))))
                                        units)))
                      (define my-army
                        (length (filter (lambda (u)
                                          (and (= (hash-ref u 'alliance 0) 1)
                                               (not (member (hash-ref u 'unit-type 0)
                                                            '(18 45 19 20 59 84 60 61 86 104 106 88 151)))))
                                        units)))
                      (define my-supply-cap
                        (min 200 (+ 15 (* 8 (length (filter (lambda (u)
                                                              (and (= (hash-ref u 'alliance 0) 1)
                                                                   (member (hash-ref u 'unit-type 0) '(19 60 106))))
                                                            units))))))
                      (define my-food-used (+ my-workers (* 2 my-army)))
                      (define pc-bytes
                        (bytes-append
                         (encode-uint32 1 1)
                         (encode-uint32 2 minerals)
                         (encode-uint32 3 vespene)
                         (encode-uint32 4 my-supply-cap)
                         (encode-uint32 5 my-food-used)
                         (encode-uint32 6 (* 2 my-army))
                         (encode-uint32 7 my-workers)
                         (encode-uint32 8 0)
                         (encode-uint32 9 my-army)
                         (encode-uint32 10 0)
                         (encode-uint32 11 3)))
                      (define raw-bytes
                        (bytes-append
                         (encode-submessage-field 1 (encode-submessage-field 2 (encode-pb-point 32.5 32.5 10.0)))
                         (apply bytes-append
                                (for/list ([u (in-list units)])
                                  (encode-submessage-field 2 (encode-pb-unit u))))))
                      (define inner-obs
                        (bytes-append (encode-uint32 9 game-loop)
                                      (encode-submessage-field 1 pc-bytes)
                                      (encode-submessage-field 5 raw-bytes)))
                      (define resp-obs
                        (encode-submessage-field 3 inner-obs))
                      (ws-server-write-frame!
                       out 2
                       (bytes-append (encode-submessage-field 10 resp-obs)
                                     (encode-uint32 97 req-id)
                                     (encode-int32 99 3)))]
                     ;; Action (11)
                     [(hash-has-key? req-h 11)
                      (for ([act-req (in-list (hash-ref req-h 11 '()))])
                        (apply-raw-action! (cdr act-req)))
                      (ws-server-write-frame!
                       out 2
                       (bytes-append (encode-submessage-field 11 (encode-int32 1 1))
                                     (encode-uint32 97 req-id)
                                     (encode-int32 99 3)))]
                     ;; Step (12)
                     [(hash-has-key? req-h 12)
                      (define step-entry (first (hash-ref req-h 12)))
                      (define sh (protobuf-fields->hash (decode-protobuf-message (cdr step-entry))))
                      (define cnt
                        (let ([cs (hash-ref sh 1 '())])
                          (if (null? cs) 4 (cdar cs))))
                      (set! game-loop (+ game-loop cnt))
                      (set! minerals (+ minerals (* cnt 5)))
                      (set! vespene (+ vespene (* cnt 2)))
                      ;; Spawn an enemy wave around loop 160 so tactical & counter layers fire
                      (when (and (>= game-loop 160) (< (- game-loop cnt) 160))
                        (set! units
                              (append units
                                      (list (hash 'tag 9010 'alliance 4 'owner 2 'unit-type enemy-combat-id
                                                  'x 48.0 'y 50.0 'health 120.0 'health-max 120.0
                                                  'build-progress 1.0 'orders '())
                                            (hash 'tag 9011 'alliance 4 'owner 2 'unit-type enemy-combat-id
                                                  'x 49.0 'y 51.0 'health 120.0 'health-max 120.0
                                                  'build-progress 1.0 'orders '())))))
                      (ws-server-write-frame!
                       out 2
                       (bytes-append (encode-submessage-field 12 (encode-uint32 1 game-loop))
                                     (encode-uint32 97 req-id)
                                     (encode-int32 99 3)))]
                     ;; LeaveGame (5) / Quit (8)
                     [(or (hash-has-key? req-h 5) (hash-has-key? req-h 8))
                      (define fnum (if (hash-has-key? req-h 5) 5 8))
                      (ws-server-write-frame!
                       out 2
                       (bytes-append (encode-submessage-field fnum #"")
                                     (encode-uint32 97 req-id)
                                     (encode-int32 99 4)))]
                     [else
                      (ws-server-write-frame!
                       out 2
                       (bytes-append (encode-uint32 97 req-id)
                                     (encode-int32 99 3)))]))
                 (loop))))
           (lambda ()
             (with-handlers ([exn:fail? void]) (close-input-port in))
             (with-handlers ([exn:fail? void]) (close-output-port out))))))))

  (hash 'backend "embedded_sc2_protobuf_ws"
        'port port
        'listener listener
        'thread server-thread
        'stop! (lambda ()
                 (with-handlers ([exn:fail? void]) (tcp-close listener))
                 (with-handlers ([exn:fail? void]) (kill-thread server-thread)))))

;; =============================================================================
;; Auto-Launcher for Local Headless SC2_x64 (or Embedded Fallback Server)
;; =============================================================================

(define (spawn-local-headless-sc2! #:our-race [our-race "Random"]
                                   #:computer-race [computer-race "Protoss"]
                                   #:map-name [map-name "Simple64"])
  (define port (pick-free-local-port))
  (define sc2-root (find-sc2-root))
  (define-values (sc2-bin support64-dir) (find-sc2-x64-binary sc2-root))
  (define resolved-map (resolve-sc2-map-path map-name sc2-root))
  (cond
    [(and sc2-bin (file-exists? sc2-bin))
     (define-values (subproc out-port in-port err-port)
       (parameterize ([current-directory support64-dir])
         (subprocess #f #f #f
                     sc2-bin
                     "-listen" "127.0.0.1"
                     "-port" (number->string port)
                     "-displayMode" "0")))
     (hash 'backend "SC2_x64"
           'sc2-bin sc2-bin
           'port port
           'resolved-map resolved-map
           'subprocess subproc
           'stop! (lambda ()
                    (with-handlers ([exn:fail? void]) (close-output-port in-port))
                    (with-handlers ([exn:fail? void]) (close-input-port out-port))
                    (with-handlers ([exn:fail? void]) (close-input-port err-port))
                    (with-handlers ([exn:fail? void])
                      (when (eq? (subprocess-status subproc) 'running)
                        (subprocess-kill subproc #t)))))]
    [else
     (define srv
       (start-embedded-sc2-protobuf-server! port
                                            #:our-race our-race
                                            #:computer-race computer-race
                                            #:map-name resolved-map))
     (hash-set (hash-set srv 'resolved-map resolved-map) 'sc2-bin #f)]))

(define (append-native-telemetry! root-dir summary-hash)
  (with-handlers ([exn:fail? void])
    (define data-dir (build-path root-dir "data"))
    (make-directory* data-dir)
    (define log-path (build-path data-dir "racket_native_match_telemetry.jsonl"))
    (call-with-output-file log-path
      (lambda (out)
        (write-json summary-hash out)
        (newline out))
      #:exists 'append)))

(define (run-racket-sc2-match #:host [host "127.0.0.1"]
                              #:game-port [game-port #f]
                              #:start-port [start-port #f]
                              #:bot-name [bot-name "Mothman"]
                              #:bot-rkt-path [bot-rkt-path "bots/Mothman.rkt"]
                              #:our-race [our-race "Random"]
                              #:initial-posture [initial-posture #f]
                              #:opponent-id [opponent-id "local_opponent"]
                              #:computer-opponent? [computer-opponent? #f]
                              #:computer-race [computer-race "Protoss"]
                              #:computer-difficulty [computer-difficulty "VeryHard"]
                              #:host-2p-opponent-race [host-2p-opponent-race #f]
                              #:save-replay-path [save-replay-path #f]
                              #:map-name [map-name "Simple64.SC2Map"]
                              #:max-loops [max-loops 4032]
                              #:realtime? [realtime? #f]
                              #:step-size [step-size 4]
                              #:root-dir [root-dir (current-directory)])
  (define auto-launched-handle
    (if (and (not game-port) computer-opponent?)
        (spawn-local-headless-sc2! #:our-race our-race
                                   #:computer-race computer-race
                                   #:map-name map-name)
        #f))
  (define effective-port
    (or game-port
        (and auto-launched-handle (hash-ref auto-launched-handle 'port))
        5000))
  (define effective-map
    (if auto-launched-handle
        (hash-ref auto-launched-handle 'resolved-map (resolve-sc2-map-path map-name))
        (resolve-sc2-map-path map-name)))

  (define conn #f)
  (define req-seq 0)
  (define (next-id!)
    (set! req-seq (add1 req-seq))
    req-seq)

  (dynamic-wind
    (lambda ()
      (set! conn (connect-sc2-ws-with-retry host effective-port #:path "/sc2api")))
    (lambda ()
      ;; 1. Optional CreateGame when playing against Built-in SC2 Computer OR hosting a 2-bot game
      (cond
        [computer-opponent?
         (define cg-req
           (make-request-create-game #:map-path effective-map
                                     #:our-race our-race
                                     #:computer-race computer-race
                                     #:computer-difficulty computer-difficulty
                                     #:realtime? realtime?
                                     #:id (next-id!)))
         (sc2-ws-rpc! conn cg-req)]
        [host-2p-opponent-race
         (define cg-req
           (make-request-create-game #:map-path effective-map
                                     #:include-map-data? #t
                                     #:player-setups (list (list 1 our-race)
                                                           (list 1 host-2p-opponent-race))
                                     #:realtime? realtime?
                                     #:id (next-id!)))
         (define cg-resp (sc2-ws-rpc! conn cg-req))
         (fprintf (current-error-port)
                  "[HOST-2P] RequestCreateGame completed (status=~a map=~a)\n"
                  (sc2-response-status cg-resp)
                  effective-map)
         (flush-output (current-error-port))])

      ;; 2. JoinGame
      (define pcfg (compute-ladder-port-config (and (not computer-opponent?) start-port)))
      (define jg-req
        (make-request-join-game #:race our-race
                                #:shared-port (hash-ref pcfg 'shared-port #f)
                                #:server-ports (hash-ref pcfg 'server-ports #f)
                                #:client-ports (hash-ref pcfg 'client-ports '())
                                #:player-name bot-name
                                #:id (next-id!)))
      (define jg-resp (sc2-ws-rpc! conn jg-req))
      (define jg-info (sc2-response-join-game jg-resp))
      (define our-player-id
        (if (hash? jg-info) (hash-ref jg-info 'player-id 1) 1))
      (when host-2p-opponent-race
        (fprintf (current-error-port)
                 "[HOST-2P] RequestJoinGame completed (player-id=~a status=~a)\n"
                 our-player-id
                 (sc2-response-status jg-resp))
        (flush-output (current-error-port)))

      ;; 3. RequestGameInfo & RequestData
      (define gi-resp (sc2-ws-rpc! conn (make-request-game-info #:id (next-id!))))
      (define game-info (sc2-response-game-info gi-resp))

      (define data-resp (sc2-ws-rpc! conn (make-request-data #:id (next-id!))))
      (when (sc2-response-data data-resp)
        (register-sc2-response-data! (sc2-response-data data-resp)))

      ;; 4. Initialize 5-Layer Live Bot Runtime
      (define configured-race-sym (string->symbol our-race))
      (define posture-sym
        (if (and initial-posture (not (string=? initial-posture "")))
            (string->symbol initial-posture)
            #f))
      (define runtime
        (make-live-bot-runtime #:bot-name (string->symbol bot-name)
                               #:race configured-race-sym
                               #:initial-posture posture-sym))

      (define total-raw-cmds-sent 0)
      (define total-steps 0)
      (define peak-workers 0)
      (define peak-bases 1)
      (define peak-army-supply 0)
      (define last-game-loop 0)
      (define last-logged-saving-for #f)
      (define priority-logs-emitted 0)
      (define step-total-ms-list '())
      (define sum-obs-ms 0.0)
      (define sum-runtime-ms 0.0)
      (define sum-translate-ms 0.0)
      (define match-result "Undecided")

      ;; 5. Main WebSocket Match Loop (catch SIGINT/SIGTERM break so SaveReplay still runs)
      (with-handlers ([exn:break? (lambda (_e)
                                    (when (string=? match-result "Undecided")
                                      (set! match-result "Interrupted")))])
        (let match-loop ()
          (define obs-resp (sc2-ws-rpc! conn (make-request-observation #:id (next-id!))))
          (define status (sc2-response-status obs-resp))
          (define obs (sc2-response-observation obs-resp))
          (cond
            [(or (not obs) (memq status '(ended quit)))
             (when (and obs (not (null? (sc2-observation-player-results obs))))
               (for ([pr (in-list (sc2-observation-player-results obs))])
                 (when (= (sc2-player-result-player-id pr) our-player-id)
                   (set! match-result (symbol->string (sc2-player-result-result pr))))))
             (void)]
            [else
             (set! last-game-loop (sc2-observation-game-loop obs))
             (define pres (sc2-observation-player-results obs))
             (for ([pr (in-list pres)])
               (when (= (sc2-player-result-player-id pr) our-player-id)
                 (set! match-result (symbol->string (sc2-player-result-result pr)))))

             (cond
               [(or (not (null? pres))
                    (and (> max-loops 0) (>= last-game-loop max-loops)))
                (when (string=? match-result "Undecided")
                  (set! match-result "Tie"))
                (void)]
               [else
                (define t-step-0 (current-inexact-monotonic-milliseconds))
                (define obs-hash
                  (sc2-observation->runtime-obs-hash
                   obs
                   #:game-info game-info
                   #:our-player-id our-player-id
                   #:configured-race configured-race-sym
                   #:used-creep-tumors (live-bot-runtime-used-creep-tumors runtime)))
                (define t-obs-1 (current-inexact-monotonic-milliseconds))

                (define actual-race (hash-ref obs-hash 'race 'Zerg))
                (set-live-bot-runtime-actual-race! runtime actual-race)

                (define pc (sc2-observation-player-common obs))
                (set! peak-workers (max peak-workers (sc2-player-common-food-workers pc)))
                (set! peak-army-supply (max peak-army-supply (sc2-player-common-food-army pc)))
                (set! peak-bases
                      (max peak-bases
                           (length (filter sc2-unit-is-townhall?
                                           (filter (lambda (u) (= (sc2-unit-alliance u) 1))
                                                   (sc2-observation-units obs))))))

                ;; Step cognitive architecture (primary actions first so individual unit micro
                ;; populates commanded-combat-tags before any global spatial maneuver)
                (define step-res (step-live-bot-runtime! runtime obs-hash))
                (define t-rt-1 (current-inexact-monotonic-milliseconds))
                (define step-tel (hash-ref step-res 'telemetry (hash)))
                (define prio-sum (hash-ref step-tel 'priority-summary (hash)))
                (define prio-line (hash-ref step-tel 'priority-log-line ""))
                (define cur-saving-for (hash-ref prio-sum 'saving-for 'none))

                (define bot-actions
                  (append (hash-ref step-res 'actions '())
                          (hash-ref step-res 'mirror-actions '())))

                ;; Translate S-expression actions + automatic worker/gas saturation
                ;; (excluding workers commanded to build/expand/defend in this frame)
                (define commanded-workers (mutable-seteqv))
                (define action-cmds
                  (translate-bot-actions->sc2-raw-commands
                   bot-actions
                   obs
                   #:used-creep-tumors (live-bot-runtime-used-creep-tumors runtime)
                   #:ws-conn conn
                   #:enemy-base (hash-ref obs-hash 'enemy-base #f)
                   #:commanded-workers commanded-workers))
                (define raw-cmds
                  (append
                   action-cmds
                   (saturate-workers-and-gas-commands
                    obs
                    #:excluded-worker-tags commanded-workers)))
                (define t-tr-1 (current-inexact-monotonic-milliseconds))

                (define step-ms (- t-tr-1 t-step-0))
                (set! step-total-ms-list (cons step-ms step-total-ms-list))
                (set! sum-obs-ms (+ sum-obs-ms (- t-obs-1 t-step-0)))
                (set! sum-runtime-ms (+ sum-runtime-ms (- t-rt-1 t-obs-1)))
                (set! sum-translate-ms (+ sum-translate-ms (- t-tr-1 t-rt-1)))

                (when (and (string? prio-line)
                           (not (string=? prio-line ""))
                           (or (= (modulo total-steps 28) 0)
                               (not (equal? cur-saving-for last-logged-saving-for))))
                  (set! last-logged-saving-for cur-saving-for)
                  (set! priority-logs-emitted (add1 priority-logs-emitted))
                  (fprintf (current-error-port) "~a step_ms=~a\n"
                           prio-line
                           (/ (round (* 100.0 step-ms)) 100.0))
                  (flush-output (current-error-port)))

                (when (not (null? raw-cmds))
                  (sc2-ws-rpc! conn (make-request-action raw-cmds #:id (next-id!)))
                  (set! total-raw-cmds-sent (+ total-raw-cmds-sent (length raw-cmds))))

                (unless realtime?
                  (sc2-ws-rpc! conn (make-request-step step-size #:id (next-id!))))

                (set! total-steps (add1 total-steps))
                (match-loop)])])))

      ;; 6. Optional SaveReplay + Clean LeaveGame / Quit & Summary
      (define saved-replay-bytes
        (if (and save-replay-path (not (string=? save-replay-path "")))
            (with-handlers ([exn:fail? (lambda (_e) #f)])
              (sc2-ws-save-replay! conn save-replay-path #:id (next-id!)))
            #f))
      (when (or computer-opponent? host-2p-opponent-race)
        (with-handlers ([exn:fail? void])
          (sc2-ws-rpc! conn (make-request-leave-game #:id (next-id!)))))
      (when auto-launched-handle
        (with-handlers ([exn:fail? void])
          (sc2-ws-rpc! conn (make-request-quit #:id (next-id!)))))

      (define sorted-step-ms (sort step-total-ms-list <))
      (define n-steps (max 1 (length sorted-step-ms)))
      (define (round2 v) (/ (round (* 100.0 v)) 100.0))
      (define avg-step-ms (round2 (/ (apply + sorted-step-ms) n-steps)))
      (define p95-step-ms
        (if (null? sorted-step-ms)
            0.0
            (round2 (list-ref sorted-step-ms (min (sub1 n-steps) (exact-floor (* 0.95 n-steps)))))))
      (define max-step-ms
        (if (null? sorted-step-ms)
            0.0
            (round2 (last sorted-step-ms))))

      (define summary
        (hasheq 'status "MATCH_COMPLETED"
                'engine "racket_native_protobuf_ws"
                'server_backend (if auto-launched-handle
                                    (hash-ref auto-launched-handle 'backend "SC2_x64")
                                    "external_ws")
                'bot_name bot-name
                'bot_rkt_path (format "~a" bot-rkt-path)
                'configured_race our-race
                'actual_race_played (symbol->string (live-bot-runtime-actual-race runtime))
                'final_posture (symbol->string (live-bot-runtime-posture runtime))
                'opponent_id (if computer-opponent?
                                 (format "Computer(~a,~a)" computer-race computer-difficulty)
                                 opponent-id)
                'map (if (sc2-game-info? game-info) (sc2-game-info-map-name game-info) effective-map)
                'result match-result
                'game_loops last-game-loop
                'steps_executed total-steps
                'commands_sent total-raw-cmds-sent
                'priority_logs_emitted priority-logs-emitted
                'avg_step_ms avg-step-ms
                'p95_step_ms p95-step-ms
                'max_step_ms max-step-ms
                'avg_obs_ms (round2 (/ sum-obs-ms n-steps))
                'avg_runtime_ms (round2 (/ sum-runtime-ms n-steps))
                'avg_translate_ms (round2 (/ sum-translate-ms n-steps))
                'peak_workers peak-workers
                'peak_bases peak-bases
                'peak_army_supply peak-army-supply
                'saved_replay_path (or (and saved-replay-bytes save-replay-path) "")
                'saved_replay_bytes (or saved-replay-bytes 0)))
      (append-native-telemetry! root-dir summary)
      summary)
    (lambda ()
      (when conn
        (sc2-ws-close! conn))
      (when auto-launched-handle
        (define stop-fn (hash-ref auto-launched-handle 'stop! #f))
        (when (procedure? stop-fn)
          (stop-fn))))))

(define (run-racket-sc2-cli [argv (current-command-line-arguments)])
  (define game-port #f)
  (define start-port #f)
  (define ladder-server "127.0.0.1")
  (define opponent-id "local_opponent")
  (define computer-opponent? #f)
  (define computer-race "Protoss")
  (define computer-difficulty "VeryHard")
  (define host-2p-opponent-race #f)
  (define save-replay-path #f)
  (define bot-name #f)
  (define bot-file #f)
  (define race-override #f)
  (define posture-override #f)
  (define map-name "Simple64")
  (define max-loops #f)
  (define realtime? #f)
  (define step-size 4)
  (define dry-run? #f)

  (command-line
   #:program "racket-sc2-ladder-main"
   #:argv argv
   #:once-each
   [("--GamePort") gp "SC2 GamePort for AI Arena / WebSocket"
                   (set! game-port (string->number gp))]
   [("--StartPort") sp "SC2 StartPort for AI Arena"
                    (set! start-port (string->number sp))]
   [("--LadderServer") ls "AI Arena LadderServer host"
                       (set! ladder-server ls)]
   [("--OpponentId") oid "Opponent ID on AI Arena"
                     (set! opponent-id oid)]
   [("--ComputerOpponent") "Play against built-in SC2 Computer"
                           (set! computer-opponent? #t)]
   [("--ComputerRace") cr "Built-in Computer Race"
                       (set! computer-race cr)]
   [("--ComputerDifficulty") cd "Built-in Computer Difficulty"
                             (set! computer-difficulty cd)]
   [("--Host2POpponentRace" "--host-2p-opponent-race") orace "Host a 2-participant game with opponent race"
                                                       (set! host-2p-opponent-race orace)]
   [("--SaveReplay" "--save-replay") srp "Path to save .SC2Replay file at match end"
                                     (set! save-replay-path srp)]
   [("--BotName") bn "Variant name in config.json"
                  (set! bot-name bn)]
   [("--bot") bf "Path to .rkt bot file"
              (set! bot-file bf)]
   [("--race") r "Race override (Zerg, Terran, Protoss, Random)"
               (set! race-override r)]
   [("--posture") p "Initial posture override"
                  (set! posture-override p)]
   [("--Map" "--map") m "SC2 Map name"
                      (set! map-name m)]
   [("--max-loops") ml "Max game loops (0 for unlimited)"
                    (set! max-loops (or (string->number ml) 0))]
   [("--RealTime" "--realtime") "Run in real-time mode"
                                (set! realtime? #t)]
   [("--step-size") ss "Game loops per RequestStep"
                    (set! step-size (max 1 (or (string->number ss) 4)))]
   [("--dry-run") "Verify configuration and runtime without connecting to SC2"
                  (set! dry-run? #t)]
   #:args _rest
   (void))

  (define effective-max-loops
    (or max-loops (if computer-opponent? 4032 0)))

  (define cfg (load-bot-config bot-name))
  (define resolved-bot-name
    (or bot-name (hash-ref cfg 'BotName "Mothman")))
  (define resolved-bot-path
    (or bot-file (hash-ref cfg 'BotPath "bots/Mothman.rkt")))
  (define-values (inferred-race inferred-posture)
    (infer-bot-race-and-posture resolved-bot-path resolved-bot-name))
  (define resolved-race
    (or race-override (hash-ref cfg 'BotRace #f) inferred-race))
  (define resolved-posture
    (or posture-override inferred-posture))

  (cond
    [dry-run?
     (define rt
      (make-live-bot-runtime #:bot-name (string->symbol resolved-bot-name)
                             #:race (string->symbol resolved-race)
                             #:initial-posture (string->symbol resolved-posture)))
     (define out-hash
       (hasheq 'status "DRY_RUN_OK"
               'engine "racket_native_protobuf_ws"
               'bot_name resolved-bot-name
               'bot_rkt_path (format "~a" resolved-bot-path)
               'resolved_race resolved-race
               'resolved_posture (symbol->string (live-bot-runtime-posture rt))
               'map (resolve-sc2-map-path map-name)))
     (displayln (jsexpr->string out-hash))
     out-hash]
    [(or (exact-integer? game-port) computer-opponent?)
     (define res
       (run-racket-sc2-match #:host ladder-server
                             #:game-port game-port
                             #:start-port start-port
                             #:bot-name resolved-bot-name
                             #:bot-rkt-path resolved-bot-path
                             #:our-race resolved-race
                             #:initial-posture resolved-posture
                             #:opponent-id opponent-id
                             #:computer-opponent? computer-opponent?
                             #:computer-race computer-race
                             #:computer-difficulty computer-difficulty
                             #:host-2p-opponent-race host-2p-opponent-race
                             #:save-replay-path save-replay-path
                             #:map-name map-name
                             #:max-loops effective-max-loops
                             #:realtime? realtime?
                             #:step-size step-size))
     (displayln (jsexpr->string res))
     res]
    [else
     (error 'racket-sc2-ladder-main
            "Specify --GamePort <port>, --ComputerOpponent, or --dry-run")]))

(module+ main
  (void (run-racket-sc2-cli)))
