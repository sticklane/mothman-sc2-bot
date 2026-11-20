#lang racket/base

;; =============================================================================
;; Pure-Racket Native StarCraft II WebSocket + Protobuf (`s2clientprotocol`)
;; Client, Wire Codec, Canonical ID Tables, Observation Converter & Actuator
;; =============================================================================
;; Implements direct communication with `SC2_x64` over `ws://127.0.0.1:<port>/sc2api`
;; using only standard libraries bundled in the minimal Racket runtime.

(require (for-syntax racket/base racket/struct-info)
         racket/tcp
         racket/port
         racket/bytes
         racket/list
         racket/match
         racket/math
         racket/set
         racket/string
         racket/vector
         file/sha1
         net/base64
         "sc2-game-constants.rkt"
         "sc2-typed-commands.rkt"
         (only-in "sc2-placement.rkt"
                  sc2-symmetry-reflect-point
                  sc2-detect-map-symmetry
                  sc2-ground-bfs-dist-at
                  sc2-ground-territory-margin)
         (only-in "sc2-common.rkt"
                  SC2-SINGLETON-TECH-BUILDINGS
                  SC2-DUAL-CAP-TECH-BUILDINGS))

(provide
 ;; RFC 6455 WebSocket Client
 (struct-out sc2-ws-conn)
 compute-ws-accept-key
 mask-ws-payload
 sc2-ws-connect
 sc2-ws-send-frame!
 sc2-ws-send-binary!
 sc2-ws-recv-binary!
 sc2-ws-rpc!
 sc2-ws-close!

 ;; Protobuf Wire Format Codec
 encode-varint
 decode-varint
 encode-tag
 encode-int32
 encode-uint32
 encode-uint64
 encode-bool
 encode-float32
 decode-float32
 encode-bytes-field
 encode-string-field
 encode-submessage-field
 decode-protobuf-message
 decode-packed-or-unpacked-varints
 protobuf-fields->hash

 ;; s2clientprotocol Structs
 (struct-out sc2-point2d)
 (struct-out sc2-point3d)
 (struct-out sc2-unit-order)
 (struct-out sc2-passenger-unit)
 (except-out (struct-out sc2-unit) sc2-unit raw-sc2-unit)
 (rename-out [sc2-unit-id sc2-unit])
 (struct-out sc2-effect)
 (struct-out sc2-power-source)
 (struct-out sc2-player-common)
 (struct-out sc2-player-result)
 (struct-out sc2-observation)
 (struct-out sc2-image-grid)
 (except-out (struct-out sc2-game-info) raw-sc2-game-info sc2-game-info)
 (rename-out [make-sc2-game-info sc2-game-info])
 (struct-out sc2-data-entry)
 (struct-out sc2-data)
 (struct-out sc2-response)
 (struct-out sc2-raw-unit-command)
 (struct-out sc2-raw-camera-move)
 (struct-out sc2-ui-control-group)
 (struct-out sc2-chat-action)
 (struct-out sc2-query-placement)

 ;; s2clientprotocol Request Builders & Response Decoder
 make-request-create-game
 make-request-join-game
 make-request-game-info
 make-request-data
 make-request-observation
 make-request-action
 make-request-step
 make-request-query-placement
 encode-debug-create-unit
 encode-debug-kill-unit
 encode-debug-test-process
 encode-request-debug
 make-request-debug
 make-request-save-replay
 decode-response-save-replay-bytes
 sc2-ws-save-replay!
 make-request-leave-game
 make-request-quit
 make-request-ping
 encode-point2d
 encode-point3d
 encode-point
 encode-action-raw-unit-command
 encode-action-raw-camera-move
 encode-action-ui-control-group
 legacy-wire-action->typed-sc2-action
 encode-sc2-action
 decode-sc2-response
 decode-image-grid-bytes
 sc2-grid-ref
 calibrate-image-grid-orientation!

 ;; Canonical Unit / Ability / Upgrade / Buff / Effect Tables
 SC2-UNIT-SYM->ID
 SC2-UNIT-ID->SYM
 SC2-ABILITY-SYM->ID
 SC2-ABILITY-ID->SYM
 SC2-UPGRADE-SYM->ID
 SC2-UPGRADE-ID->SYM
 SC2-BUFF-SYM->ID
 SC2-BUFF-ID->SYM
 SC2-EFFECT-SYM->ID
 SC2-EFFECT-ID->SYM
 unit-symbol->sc2-id
 sc2-id->unit-symbol
 ability-symbol->sc2-id
 sc2-id->ability-symbol
 train-symbol->ability-id
 build-symbol->ability-id
 research-symbol->ability-id
 morph-symbol->ability-id
 spell-symbol->ability-id
 upgrade-symbol->sc2-id
 sc2-id->upgrade-symbol
 buff-id->symbol
 effect-id->symbol
 result-enum->symbol
 register-sc2-response-data!

 ;; Observation Converter & S-Expression Actuator
 sc2-unit-is-structure?
 sc2-unit-is-townhall?
 sc2-unit-is-worker?
 sc2-unit-is-mineral-field?
 sc2-unit-is-vespene-geyser?
 sc2-unit-is-gas-building?
 sc2-townhall-resource-legal?
 sc2-townhall-all-resources-legal?
 solve-exact-townhall-pad
 compute-ground-bfs-distances
 sc2-symmetry-reflect-point
 sc2-detect-map-symmetry
 sc2-ground-bfs-dist-at
 sc2-ground-territory-margin
 SC2-TERRITORY-FIELD-CACHE
 solve-all-map-expansion-bases
 order-expansions-from-origin
 sc2-weapon-cooldown-loops->seconds
 sc2-observation->runtime-obs-hash
 sc2-observation->frame-state-sexp
 enemy-structure-is-proxy?
 placement-preserves-base-exit-and-spawn?
 collect-spiral-candidates
 find-spiral-building-placement
 find-verified-building-placement
 find-best-expansion-placement
 interleave-lists
 SC2-PLACEMENT-NEG-COOLDOWN
 SC2-PLACEMENT-POS-CACHE
 SC2-ADDON-SLOT-BLOCKED-CACHE
 SC2-TERRAN-5X3-MISS-CACHE
 SC2-TUMOR-PLACEMENT-CACHE
 SC2-PLACEMENT-CACHE-TTL
 SC2-LAST-TUMOR-RPC-LOOP
 SC2-ZERG-TH-MORPH-RESERVE-LOOP
 SC2-WARPGATE-LAST-LOOP
 SC2-PROTOSS-POWER-PLACEMENT-FAIL-LOOP
 SC2-GAS-PULL-HYSTERESIS-LATCH
 SC2-MACRO-ABILITY-LAST-LOOP
 select-producer-tags-for-unit
 frame0-pro-worker-split-commands
 compute-initial-worker-split-commands
 classify-townhall-mineral-patches
 townhall-offline?
 pick-safe-mule-mineral-patch
 worker-carrying-cargo?
 pick-far-patch-scout-worker
 saturate-workers-and-gas-commands
 translate-bot-actions->sc2-raw-commands
 get-last-bot-action-rejects
 get-total-bot-action-reject-count
 get-total-wire-action-drop-count
 reset-typed-command-gate-stats!
 mark-urgent-survival-cmd!
 urgent-survival-cmd?
 mark-macro-econ-cmd!
 macro-econ-cmd?
 mark-framing-camera-cmd!
 framing-camera-cmd?
 friendly-unit-on-depot-footprint?
 friendly-unit-requesting-depot-transit?
 wire-cmd-priority-tier
 coalesce-sc2-raw-commands
 make-wire-apm-governor
 govern-sc2-wire-actions!)

;; =============================================================================
;; 1. RFC 6455 WebSocket Client over `racket/tcp`
;; =============================================================================

(define WS-GUID "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")

(struct sc2-ws-conn
  (host port path in out closed? next-req-id)
  #:mutable
  #:transparent)

(define (compute-ws-accept-key client-key-str)
  (define combined (string->bytes/utf-8 (string-append (string-trim client-key-str) WS-GUID)))
  (define digest (sha1-bytes (open-input-bytes combined)))
  (bytes->string/utf-8 (base64-encode digest #"")))

(define (generate-ws-client-key)
  (define raw (make-bytes 16))
  (for ([i (in-range 16)])
    (bytes-set! raw i (random 256)))
  (bytes->string/utf-8 (base64-encode raw #"")))

(define (generate-ws-mask-key)
  (bytes (add1 (random 255))
         (add1 (random 255))
         (add1 (random 255))
         (add1 (random 255))))

(define (mask-ws-payload payload mask-key)
  (define len (bytes-length payload))
  (define out (make-bytes len))
  (define k0 (bytes-ref mask-key 0))
  (define k1 (bytes-ref mask-key 1))
  (define k2 (bytes-ref mask-key 2))
  (define k3 (bytes-ref mask-key 3))
  (for ([i (in-range len)])
    (define k
      (case (bitwise-and i 3)
        [(0) k0]
        [(1) k1]
        [(2) k2]
        [else k3]))
    (bytes-set! out i (bitwise-xor (bytes-ref payload i) k)))
  out)

(define (sc2-ws-connect host port #:path [path "/sc2api"])
  (define-values (in out) (tcp-connect host port))
  (define client-key (generate-ws-client-key))
  (define req-str
    (string-append
     "GET " path " HTTP/1.1\r\n"
     "Host: " host ":" (number->string port) "\r\n"
     "Upgrade: websocket\r\n"
     "Connection: Upgrade\r\n"
     "Sec-WebSocket-Key: " client-key "\r\n"
     "Sec-WebSocket-Version: 13\r\n"
     "\r\n"))
  (write-bytes (string->bytes/utf-8 req-str) out)
  (flush-output out)

  (define status-line (read-line in 'any))
  (when (eof-object? status-line)
    (close-input-port in)
    (close-output-port out)
    (error 'sc2-ws-connect "EOF reading HTTP Upgrade status line from ~a:~a" host port))
  (unless (or (string-contains? status-line "101")
              (string-contains? (string-downcase status-line) "switching protocols"))
    (close-input-port in)
    (close-output-port out)
    (error 'sc2-ws-connect "Expected 101 Switching Protocols, got: ~a" status-line))

  ;; Consume remaining HTTP headers until blank line
  (let loop ()
    (define hdr-line (read-line in 'any))
    (unless (or (eof-object? hdr-line)
                (string=? (string-trim hdr-line) ""))
      (loop)))

  (sc2-ws-conn host port path in out #f 1))

(define (sc2-ws-send-frame! conn opcode payload
                            #:fin? [fin? #t]
                            #:mask-key [mask-key #f])
  (when (sc2-ws-conn-closed? conn)
    (error 'sc2-ws-send-frame! "WebSocket connection is closed"))
  (define out (sc2-ws-conn-out conn))
  (define raw-payload
    (cond
      [(bytes? payload) payload]
      [(string? payload) (string->bytes/utf-8 payload)]
      [else #""]))
  (define len (bytes-length raw-payload))
  (define b0 (bitwise-ior (if fin? #x80 0) (bitwise-and opcode #x0F)))
  (define header-bytes
    (cond
      [(< len 126)
       (bytes b0 (bitwise-ior #x80 len))]
      [(<= len 65535)
       (bytes-append (bytes b0 (bitwise-ior #x80 126))
                     (integer->integer-bytes len 2 #f #t))]
      [else
       (bytes-append (bytes b0 (bitwise-ior #x80 127))
                     (integer->integer-bytes len 8 #f #t))]))
  (define mkey (if (and (bytes? mask-key) (= (bytes-length mask-key) 4))
                   mask-key
                   (generate-ws-mask-key)))
  (define masked (mask-ws-payload raw-payload mkey))
  (write-bytes header-bytes out)
  (write-bytes mkey out)
  (write-bytes masked out)
  (flush-output out))

(define (sc2-ws-send-binary! conn payload #:mask-key [mask-key #f])
  (sc2-ws-send-frame! conn 2 payload #:fin? #t #:mask-key mask-key))

(define (read-exact-bytes in n)
  (with-handlers ([exn:fail? (lambda (_e) eof)])
    (cond
      [(<= n 0) #""]
      [else
       (define b (read-bytes n in))
       (cond
         [(eof-object? b) eof]
         [(= (bytes-length b) n) b]
         [else
          (let loop ([acc (list b)]
                     [rem (- n (bytes-length b))])
            (if (<= rem 0)
                (apply bytes-append (reverse acc))
                (let ([chunk (read-bytes rem in)])
                  (if (eof-object? chunk)
                      eof
                      (loop (cons chunk acc) (- rem (bytes-length chunk)))))))])])))

(define (sc2-ws-recv-binary! conn)
  (if (sc2-ws-conn-closed? conn)
      eof
      (with-handlers ([exn:fail? (lambda (_e)
                                   (set-sc2-ws-conn-closed?! conn #t)
                                   eof)])
        (let ([in (sc2-ws-conn-in conn)])
          (let loop ([fragments '()])
            (define hdr2 (read-exact-bytes in 2))
            (cond
              [(eof-object? hdr2)
               (set-sc2-ws-conn-closed?! conn #t)
               eof]
            [else
             (define b0 (bytes-ref hdr2 0))
             (define b1 (bytes-ref hdr2 1))
             (define fin? (not (zero? (bitwise-and b0 #x80))))
             (define opcode (bitwise-and b0 #x0F))
             (define masked? (not (zero? (bitwise-and b1 #x80))))
             (define len7 (bitwise-and b1 #x7F))
             (define payload-len
               (cond
                 [(< len7 126) len7]
                 [(= len7 126)
                  (define ext2 (read-exact-bytes in 2))
                  (if (eof-object? ext2) -1 (integer-bytes->integer ext2 #f #t))]
                 [else
                  (define ext8 (read-exact-bytes in 8))
                  (if (eof-object? ext8) -1 (integer-bytes->integer ext8 #f #t))]))
             (cond
               [(< payload-len 0)
                (set-sc2-ws-conn-closed?! conn #t)
                eof]
               [else
                (define mask-key
                  (if masked? (read-exact-bytes in 4) #f))
                (define raw-data (read-exact-bytes in payload-len))
                (cond
                  [(or (eof-object? mask-key) (eof-object? raw-data))
                   (set-sc2-ws-conn-closed?! conn #t)
                   eof]
                  [else
                   (define data
                     (if masked? (mask-ws-payload raw-data mask-key) raw-data))
                   (case opcode
                     [(8) ;; Close
                      (set-sc2-ws-conn-closed?! conn #t)
                      eof]
                     [(9) ;; Ping -> automatically answer with masked Pong (opcode 10)
                      (with-handlers ([exn:fail? void])
                        (sc2-ws-send-frame! conn 10 data #:fin? #t))
                      (loop fragments)]
                     [(10) ;; Pong -> ignore
                      (loop fragments)]
                     [(0 1 2) ;; Continuation / Text / Binary
                      (define next-frags (cons data fragments))
                      (if fin?
                          (apply bytes-append (reverse next-frags))
                          (loop next-frags))]
                     [else
                      (loop fragments)])])])]))))))

(define (sc2-ws-close! conn)
  (unless (sc2-ws-conn-closed? conn)
    (with-handlers ([exn:fail? void])
      (sc2-ws-send-frame! conn 8 #"\x03\xe8" #:fin? #t))
    (set-sc2-ws-conn-closed?! conn #t)
    (with-handlers ([exn:fail? void])
      (close-input-port (sc2-ws-conn-in conn)))
    (with-handlers ([exn:fail? void])
      (close-output-port (sc2-ws-conn-out conn)))))

(define (sc2-ws-rpc! conn request-bytes)
  (cond
    [(or (not (bytes? request-bytes)) (zero? (bytes-length request-bytes)))
     (sc2-response #f 'in-game '("Skipped empty request") #f #f #f #f #f #f '() #f #f '() #f)]
    [else
     (sc2-ws-send-binary! conn request-bytes)
     (define resp-bytes (sc2-ws-recv-binary! conn))
     (if (eof-object? resp-bytes)
         (sc2-response #f 'ended '("WebSocket EOF") #f #f #f #f #f #f '() #f #f '() #f)
         (decode-sc2-response resp-bytes))]))

;; =============================================================================
;; 2. Protobuf Wire Format Encoder & Decoder
;; =============================================================================

(define SC2-PROTO-FLOAT32-MAX 3.4028234e38)

(define (sanitize-uint64-wire n [default 0])
  (cond
    [(exact-integer? n)
     (bitwise-and n #xFFFFFFFFFFFFFFFF)]
    [(and (real? n) (not (nan? n)) (not (infinite? n)))
     (bitwise-and (exact-round n) #xFFFFFFFFFFFFFFFF)]
    [else default]))

(define (sanitize-uint32-wire n [default 0])
  (cond
    [(exact-integer? n)
     (bitwise-and n #xFFFFFFFF)]
    [(and (real? n) (not (nan? n)) (not (infinite? n)))
     (bitwise-and (exact-round n) #xFFFFFFFF)]
    [else default]))

(define (sanitize-int32-wire n [default 0])
  (define raw
    (cond
      [(exact-integer? n) n]
      [(and (real? n) (not (nan? n)) (not (infinite? n)))
       (exact-round n)]
      [else default]))
  (define u32 (bitwise-and raw #xFFFFFFFF))
  (if (>= u32 #x80000000)
      (bitwise-ior u32 #xFFFFFFFF00000000)
      u32))

(define (sanitize-finite-float32 val [default 0.0])
  (cond
    [(and (real? val) (not (nan? val)) (not (infinite? val)))
     (define f (real->double-flonum val))
     (cond
       [(> f SC2-PROTO-FLOAT32-MAX) SC2-PROTO-FLOAT32-MAX]
       [(< f (- SC2-PROTO-FLOAT32-MAX)) (- SC2-PROTO-FLOAT32-MAX)]
       [(= f 0.0) 0.0]
       [else f])]
    [else default]))

(define (encode-varint n)
  (define u (sanitize-uint64-wire n 0))
  (let loop ([val u]
             [acc '()])
    (define low7 (bitwise-and val #x7F))
    (define rest (arithmetic-shift val -7))
    (if (zero? rest)
        (list->bytes (reverse (cons low7 acc)))
        (loop rest (cons (bitwise-ior low7 #x80) acc)))))

(define (decode-varint bstr [offset 0])
  (define len (bytes-length bstr))
  (let loop ([idx offset]
             [shift 0]
             [acc 0])
    (when (>= idx len)
      (error 'decode-varint "Truncated varint at offset ~a (len ~a)" idx len))
    (when (> shift 63)
      (error 'decode-varint "Overlong varint (>10 bytes) at offset ~a" offset))
    (define b (bytes-ref bstr idx))
    (when (and (= shift 63) (> b 1))
      (error 'decode-varint "Varint overflows uint64 at offset ~a" offset))
    (define next-acc (bitwise-ior acc (arithmetic-shift (bitwise-and b #x7F) shift)))
    (if (zero? (bitwise-and b #x80))
        (values next-acc (add1 idx))
        (loop (add1 idx) (+ shift 7) next-acc))))

(define (encode-tag field-number wire-type)
  (define fn
    (if (and (exact-integer? field-number) (<= 1 field-number #x1FFFFFFF))
        field-number
        1))
  (define wt
    (if (memv wire-type '(0 1 2 5))
        wire-type
        0))
  (encode-varint (bitwise-ior (arithmetic-shift fn 3) wt)))

(define encode-int32
  (case-lambda
    [(val) (encode-varint (sanitize-int32-wire val 0))]
    [(field-number val)
     (bytes-append (encode-tag field-number 0)
                   (encode-varint (sanitize-int32-wire val 0)))]))

(define encode-uint32
  (case-lambda
    [(val) (encode-varint (sanitize-uint32-wire val 0))]
    [(field-number val)
     (bytes-append (encode-tag field-number 0)
                   (encode-varint (sanitize-uint32-wire val 0)))]))

(define encode-uint64
  (case-lambda
    [(val) (encode-varint (sanitize-uint64-wire val 0))]
    [(field-number val)
     (bytes-append (encode-tag field-number 0)
                   (encode-varint (sanitize-uint64-wire val 0)))]))

(define encode-bool
  (case-lambda
    [(b) (bytes (if b 1 0))]
    [(field-number b)
     (bytes-append (encode-tag field-number 0) (bytes (if b 1 0)))]))

(define encode-float32
  (case-lambda
    [(val)
     (real->floating-point-bytes (sanitize-finite-float32 val 0.0) 4 #f)]
    [(field-number val)
     (bytes-append (encode-tag field-number 5)
                   (real->floating-point-bytes (sanitize-finite-float32 val 0.0) 4 #f))]))

(define (decode-float32 bstr [offset 0])
  (floating-point-bytes->real bstr #f offset (+ offset 4)))

(define (encode-bytes-field field-number raw-bytes)
  (define b (if (bytes? raw-bytes) raw-bytes #""))
  (bytes-append (encode-tag field-number 2)
                (encode-varint (bytes-length b))
                b))

(define (encode-string-field field-number str)
  (define s (if (string? str) str (format "~a" str)))
  (encode-bytes-field field-number (string->bytes/utf-8 s)))

(define (encode-submessage-field field-number submsg-bytes)
  (encode-bytes-field field-number submsg-bytes))

(define (decode-protobuf-message bstr [start 0] [end (bytes-length bstr)])
  (let loop ([pos start]
             [acc '()])
    (if (>= pos end)
        (reverse acc)
        (let-values ([(tag next-pos) (decode-varint bstr pos)])
          (define field-num (arithmetic-shift tag -3))
          (define wire-type (bitwise-and tag #x07))
          (case wire-type
            [(0) ;; Varint
             (define-values (v pos2) (decode-varint bstr next-pos))
             (loop pos2 (cons (list field-num 0 v) acc))]
            [(1) ;; 64-bit fixed
             (define pos2 (+ next-pos 8))
             (when (> pos2 end)
               (error 'decode-protobuf-message "Truncated fixed64 field ~a" field-num))
             (loop pos2 (cons (list field-num 1 (subbytes bstr next-pos pos2)) acc))]
            [(2) ;; Length-delimited
             (define-values (len pos-len) (decode-varint bstr next-pos))
             (define pos2 (+ pos-len len))
             (when (> pos2 end)
               (error 'decode-protobuf-message "Truncated length-delimited field ~a (len ~a)" field-num len))
             (loop pos2 (cons (list field-num 2 (subbytes bstr pos-len pos2)) acc))]
            [(5) ;; 32-bit fixed / float
             (define pos2 (+ next-pos 4))
             (when (> pos2 end)
               (error 'decode-protobuf-message "Truncated fixed32 field ~a" field-num))
             (loop pos2 (cons (list field-num 5 (subbytes bstr next-pos pos2)) acc))]
            [else
             (error 'decode-protobuf-message "Unsupported protobuf wire-type ~a for field ~a" wire-type field-num)])))))

(define (decode-packed-or-unpacked-varints fields target-field-num)
  (let loop ([rem fields]
             [acc '()])
    (match rem
      ['() (reverse acc)]
      [(cons (list fnum wtype val) rest)
       (cond
         [(not (= fnum target-field-num))
          (loop rest acc)]
         [(= wtype 0)
          (loop rest (cons val acc))]
         [(= wtype 2)
          ;; Packed repeated varints inside length-delimited bytes
          (define len (bytes-length val))
          (define unpacked
            (let p-loop ([p 0] [p-acc '()])
              (if (>= p len)
                  (reverse p-acc)
                  (let-values ([(v next-p) (decode-varint val p)])
                    (p-loop next-p (cons v p-acc))))))
          (loop rest (append (reverse unpacked) acc))]
         [else
          (loop rest acc)])])))

(define (protobuf-fields->hash fields)
  (define h (make-hasheqv))
  (for ([entry (in-list fields)])
    (match-define (list fnum wtype val) entry)
    (hash-update! h fnum (lambda (prev) (cons (cons wtype val) prev)) '()))
  (for ([(k v) (in-hash h)])
    (hash-set! h k (reverse v)))
  h)

(define (field-first-varint fields target-fnum [default #f])
  (let loop ([rem fields])
    (match rem
      ['() default]
      [(cons (list fnum 0 val) _) #:when (= fnum target-fnum) val]
      [(cons _ rest) (loop rest)])))

(define (field-first-bool fields target-fnum [default #f])
  (define v (field-first-varint fields target-fnum #f))
  (if v (not (zero? v)) default))

(define (field-first-float32 fields target-fnum [default 0.0])
  (let loop ([rem fields])
    (match rem
      ['() default]
      [(cons (list fnum 5 b4) _) #:when (= fnum target-fnum) (decode-float32 b4 0)]
      [(cons _ rest) (loop rest)])))

(define (field-first-bytes fields target-fnum [default #f])
  (let loop ([rem fields])
    (match rem
      ['() default]
      [(cons (list fnum 2 b) _) #:when (= fnum target-fnum) b]
      [(cons _ rest) (loop rest)])))

(define (field-first-string fields target-fnum [default ""])
  (define b (field-first-bytes fields target-fnum #f))
  (if b (bytes->string/utf-8 b #\?) default))

(define (field-all-bytes fields target-fnum)
  (for/list ([entry (in-list fields)]
             #:when (and (= (first entry) target-fnum)
                         (= (second entry) 2)))
    (third entry)))

;; =============================================================================
;; 3. Canonical Unit / Ability / Upgrade / Buff / Effect Tables
;; =============================================================================

(define SC2-UNIT-SYM->ID (make-hasheq))
(define SC2-UNIT-ID->SYM (make-hasheqv))

(define SC2-ABILITY-SYM->ID (make-hasheq))
(define SC2-ABILITY-ID->SYM (make-hasheqv))

(define SC2-UPGRADE-SYM->ID (make-hasheq))
(define SC2-UPGRADE-ID->SYM (make-hasheqv))

(define SC2-BUFF-SYM->ID (make-hasheq))
(define SC2-BUFF-ID->SYM (make-hasheqv))

(define SC2-EFFECT-SYM->ID (make-hasheq))
(define SC2-EFFECT-ID->SYM (make-hasheqv))

(define (register-id-pair! sym->id id->sym sym id #:primary? [primary? #t])
  (hash-set! sym->id sym id)
  (when (or primary? (not (hash-has-key? id->sym id)))
    (hash-set! id->sym id sym)))

;; Populate Canonical UnitTypeId Table (Verified against Blizzard / burnysc2 data/proto/unit_typeid.py)
(for ([entry
       (in-list
        '(;; Zerg Units
          (larva 151 #t)
          (egg 103 #t)
          (drone 104 #t)
          (drone-burrowed 116 #t)
          (overlord 106 #t)
          (overlord-cocoon 128 #t)
          (transport-overlord-cocoon 892 #t)
          (overlord-transport 893 #t)
          (overseer 129 #t)
          (overseer-siege-mode 1912 #t)
          (zergling 105 #t)
          (zergling-burrowed 119 #t)
          (baneling-cocoon 8 #t)
          (baneling 9 #t)
          (baneling-burrowed 115 #t)
          (roach 110 #t)
          (roach-burrowed 118 #t)
          (ravager-cocoon 687 #t)
          (ravager 688 #t)
          (ravager-burrowed 690 #t)
          (hydralisk 107 #t)
          (hydralisk-burrowed 117 #t)
          (lurker-egg 501 #t)
          (lurker-mp-egg 501 #f)
          (lurker 502 #t)
          (lurker-mp 502 #f)
          (lurker-burrowed 503 #t)
          (lurker-mp-burrowed 503 #f)
          (mutalisk 108 #t)
          (corruptor 112 #t)
          (brood-lord-cocoon 113 #t)
          (brood-lord 114 #t)
          (broodlord 114 #f)
          (queen 126 #t)
          (queen-burrowed 125 #t)
          (infestor 111 #t)
          (infestor-burrowed 127 #t)
          (swarm-host 494 #t)
          (swarmhost 494 #f)
          (swarm-host-burrowed 493 #t)
          (ultralisk 109 #t)
          (ultralisk-burrowed 131 #t)
          (viper 499 #t)
          (changeling 12 #t)
          (changeling-zealot 13 #t)
          (changeling-marine-shield 14 #t)
          (changeling-marine 15 #t)
          (changeling-zergling-wings 16 #t)
          (changeling-zergling 17 #t)
          (locust 489 #t)
          (locust-flying 693 #t)
          (broodling 289 #t)
          (broodling-escort 143 #t)
          (parasitic-bomb-dummy 824 #t)
          ;; Zerg Structures
          (hatchery 86 #t)
          (lair 100 #t)
          (hive 101 #t)
          (extractor 88 #t)
          (extractor-rich 1995 #t)
          (spawning-pool 89 #t)
          (evolution-chamber 90 #t)
          (roach-warren 97 #t)
          (baneling-nest 96 #t)
          (hydralisk-den 91 #t)
          (lurker-den 504 #t)
          (lurker-den-mp 504 #f)
          (spire 92 #t)
          (greater-spire 102 #t)
          (infestation-pit 94 #t)
          (ultralisk-cavern 93 #t)
          (nydus-network 95 #t)
          (nydus-worm 142 #t)
          (nydus-canal 142 #f)
          (spine-crawler 98 #t)
          (spine-crawler-uprooted 139 #t)
          (spore-crawler 99 #t)
          (spore-crawler-uprooted 140 #t)
          (creep-tumor 87 #t)
          (creep-tumor-burrowed 137 #t)
          (creep-tumor-queen 138 #t)
          ;; Terran Units
          (scv 45 #t)
          (mule 268 #t)
          (marine 48 #t)
          (marauder 51 #t)
          (reaper 49 #t)
          (ghost 50 #t)
          (hellion 53 #t)
          (hellbat 484 #t)
          (hellion-tank 484 #f)
          (widow-mine 498 #t)
          (widow-mine-burrowed 500 #t)
          (siege-tank 33 #t)
          (siege-tank-sieged 32 #t)
          (cyclone 692 #t)
          (thor 52 #t)
          (thor-ap 691 #t)
          (viking 35 #t)
          (viking-fighter 35 #f)
          (viking-assault 34 #t)
          (medivac 54 #t)
          (liberator 689 #t)
          (liberator-ag 734 #t)
          (raven 56 #t)
          (banshee 55 #t)
          (battlecruiser 57 #t)
          (auto-turret 31 #t)
          (point-defense-drone 11 #t)
          (kd8-charge 830 #t)
          (raven-repair-drone 1913 #t)
          ;; Terran Structures
          (command-center 18 #t)
          (command-center-flying 36 #t)
          (orbital-command 132 #t)
          (orbital-command-flying 134 #t)
          (planetary-fortress 130 #t)
          (supply-depot 19 #t)
          (supply-depot-lowered 47 #t)
          (refinery 20 #t)
          (refinery-rich 1943 #t)
          (barracks 21 #t)
          (barracks-flying 46 #t)
          (factory 27 #t)
          (factory-flying 43 #t)
          (starport 28 #t)
          (starport-flying 44 #t)
          (engineering-bay 22 #t)
          (armory 29 #t)
          (bunker 24 #t)
          (missile-turret 23 #t)
          (sensor-tower 25 #t)
          (ghost-academy 26 #t)
          (fusion-core 30 #t)
          (tech-lab 5 #t)
          (techlab 5 #f)
          (reactor 6 #t)
          (barracks-tech-lab 37 #t)
          (barracks-techlab 37 #f)
          (barracks-reactor 38 #t)
          (factory-tech-lab 39 #t)
          (factory-techlab 39 #f)
          (factory-reactor 40 #t)
          (starport-tech-lab 41 #t)
          (starport-techlab 41 #f)
          (starport-reactor 42 #t)
          ;; Protoss Units
          (probe 84 #t)
          (zealot 73 #t)
          (stalker 74 #t)
          (sentry 77 #t)
          (adept 311 #t)
          (adept-phase-shift 801 #t)
          (high-templar 75 #t)
          (dark-templar 76 #t)
          (archon 141 #t)
          (immortal 83 #t)
          (observer 82 #t)
          (observer-siege-mode 1911 #t)
          (warp-prism 81 #t)
          (warp-prism-phasing 136 #t)
          (colossus 4 #t)
          (disruptor 694 #t)
          (disruptor-phased 733 #t)
          (phoenix 78 #t)
          (void-ray 80 #t)
          (voidray 80 #f)
          (oracle 495 #t)
          (carrier 79 #t)
          (tempest 496 #t)
          (mothership 10 #t)
          (mothership-core 488 #t)
          (interceptor 85 #t)
          ;; Protoss Structures
          (nexus 59 #t)
          (pylon 60 #t)
          (pylon-overcharged 894 #t)
          (assimilator 61 #t)
          (assimilator-rich 1994 #t)
          (gateway 62 #t)
          (warp-gate 133 #t)
          (warpgate 133 #f)
          (forge 63 #t)
          (cybernetics-core 72 #t)
          (photon-cannon 66 #t)
          (shield-battery 1910 #t)
          (twilight-council 65 #t)
          (robotics-facility 71 #t)
          (robotics-bay 70 #t)
          (robotics-support-bay 70 #f)
          (stargate 67 #t)
          (templar-archive 68 #t)
          (templar-archives 68 #f)
          (dark-shrine 69 #t)
          (fleet-beacon 64 #t)
          (oracle-stasis-trap 732 #t)
          ;; Neutral Mineral Fields & Vespene Geysers
          (mineral-field 341 #t)
          (mineral-field-750 483 #t)
          (mineral-field-450 1996 #t)
          (lab-mineral-field 665 #t)
          (lab-mineral-field-750 666 #t)
          (rich-mineral-field 146 #t)
          (rich-mineral-field-750 147 #t)
          (purifier-mineral-field 884 #t)
          (purifier-mineral-field-750 885 #t)
          (purifier-rich-mineral-field 796 #t)
          (purifier-rich-mineral-field-750 797 #t)
          (battle-station-mineral-field 886 #t)
          (battle-station-mineral-field-750 887 #t)
          (vespene-geyser 342 #t)
          (space-platform-geyser 343 #t)
          (rich-vespene-geyser 344 #t)
          (protoss-vespene-geyser 608 #t)
          (purifier-vespene-geyser 880 #t)
          (shakuras-vespene-geyser 881 #t)))])
  (match-define (list sym id prim?) entry)
  (register-id-pair! SC2-UNIT-SYM->ID SC2-UNIT-ID->SYM sym id #:primary? prim?))

;; Populate Canonical AbilityId Table
(for ([entry
       (in-list
        '(;; Basic Orders
          (smart 1 #t)
          (stop 3665 #t)
          (stop-stop 4 #t)
          (move 16 #t)
          (move-general 3794 #t)
          (patrol 17 #t)
          (patrol-general 3795 #t)
          (hold-position 18 #t)
          (hold-position-general 3793 #t)
          (attack 23 #t)
          (attack-attack 23 #f)
          (attack-general 3674 #t)
          (harvest-gather 3666 #t)
          (harvest-return 3667 #t)
          (harvest-gather-drone 1183 #t)
          (harvest-return-drone 1184 #t)
          (harvest-gather-scv 295 #t)
          (harvest-return-scv 296 #t)
          (harvest-gather-probe 298 #t)
          (harvest-return-probe 299 #t)
          (cancel 3659 #t)
          (cancel-build-in-progress 314 #t)
          (cancel-last 3671 #t)
          (rally-units 3673 #t)
          (rally-workers 3690 #t)
          ;; Zerg Training (36 Trainable Units across Z/T/P)
          (train-drone 1342 #t)
          (train-overlord 1344 #t)
          (train-zergling 1343 #t)
          (train-roach 1351 #t)
          (train-hydralisk 1345 #t)
          (train-mutalisk 1346 #t)
          (train-corruptor 1353 #t)
          (train-infestor 1352 #t)
          (train-swarm-host 1356 #t)
          (train-swarmhost 1356 #f)
          (train-ultralisk 1348 #t)
          (train-viper 1354 #t)
          (train-queen 1632 #t)
          ;; Zerg Morphs
          (morph-baneling 80 #t)
          (train-baneling 80 #f)
          (morph-ravager 2330 #t)
          (train-ravager 2330 #f)
          (morph-lurker 2332 #t)
          (train-lurker 2332 #f)
          (morph-brood-lord 1372 #t)
          (morph-broodlord 1372 #f)
          (train-brood-lord 1372 #f)
          (morph-overseer 1448 #t)
          (train-overseer 1448 #f)
          (morph-overlord-transport 2708 #t)
          (morph-lair 1216 #t)
          (build-lair 1216 #f)
          (morph-hive 1218 #t)
          (build-hive 1218 #f)
          (morph-greater-spire 1220 #t)
          (build-greater-spire 1220 #f)
          (morph-lurker-den 2112 #t)
          ;; Zerg Building Construction
          (build-hatchery 1152 #t)
          (build-extractor 1154 #t)
          (build-spawning-pool 1155 #t)
          (build-evolution-chamber 1156 #t)
          (build-roach-warren 1165 #t)
          (build-baneling-nest 1162 #t)
          (build-hydralisk-den 1157 #t)
          (build-lurker-den 1163 #t)
          (build-spire 1158 #t)
          (build-infestation-pit 1160 #t)
          (build-ultralisk-cavern 1159 #t)
          (build-nydus-network 1161 #t)
          (build-nydus-worm 1768 #t)
          (build-nydus-canal 1768 #f)
          (build-spine-crawler 1166 #t)
          (build-spore-crawler 1167 #t)
          (build-creep-tumor 3691 #t)
          (build-creep-tumor-queen 1694 #t)
          (spawn-creep-tumor-queen 1662 #t)
          (build-creep-tumor-tumor 1733 #t)
          ;; Terran Training
          (train-scv 524 #t)
          (train-marine 560 #t)
          (train-marauder 563 #t)
          (train-reaper 561 #t)
          (train-ghost 562 #t)
          (train-hellion 595 #t)
          (train-hellbat 596 #t)
          (train-widow-mine 614 #t)
          (train-siege-tank 591 #t)
          (train-cyclone 597 #t)
          (train-thor 594 #t)
          (train-viking 624 #t)
          (train-viking-fighter 624 #f)
          (train-medivac 620 #t)
          (train-liberator 626 #t)
          (train-raven 622 #t)
          (train-banshee 621 #t)
          (train-battlecruiser 623 #t)
          ;; Terran Morphs & Modes
          (morph-orbital-command 1516 #t)
          (build-orbital-command 1516 #f)
          (morph-planetary-fortress 1450 #t)
          (build-planetary-fortress 1450 #f)
          (morph-siege-mode 388 #t)
          (siege-mode 388 #f)
          (morph-unsiege 390 #t)
          (unsiege 390 #f)
          (unsiege-mode 390 #f)
          (morph-hellbat 1998 #t)
          (morph-hellion 1978 #t)
          (morph-viking-assault 403 #t)
          (morph-viking-fighter 405 #t)
          (morph-liberator-ag 2558 #t)
          (morph-liberator-aa 2560 #t)
          (morph-thor-high-impact 2362 #t)
          (morph-thor-high-impact-mode 2362 #f)
          (morph-thor-explosive 2364 #t)
          (morph-thor-explosive-mode 2364 #f)
          (morph-supply-depot-lower 556 #t)
          (morph-supply-depot-raise 558 #t)
          (burrow-widow-mine 2095 #t)
          (unburrow-widow-mine 2097 #t)
          (lift 3679 #t)
          (land 3678 #t)
          ;; Terran Building Construction
          (build-command-center 318 #t)
          (build-supply-depot 319 #t)
          (build-refinery 320 #t)
          (build-barracks 321 #t)
          (build-factory 328 #t)
          (build-starport 329 #t)
          (build-engineering-bay 322 #t)
          (build-armory 331 #t)
          (build-bunker 324 #t)
          (build-missile-turret 323 #t)
          (build-sensor-tower 326 #t)
          (build-ghost-academy 327 #t)
          (build-fusion-core 333 #t)
          (build-tech-lab 3682 #t)
          (build-techlab 3682 #f)
          (build-barracks-tech-lab 421 #t)
          (build-barracks-techlab 421 #f)
          (build-factory-tech-lab 454 #t)
          (build-factory-techlab 454 #f)
          (build-starport-tech-lab 487 #t)
          (build-starport-techlab 487 #f)
          (build-reactor 3683 #t)
          (build-barracks-reactor 422 #t)
          (build-factory-reactor 455 #t)
          (build-starport-reactor 488 #t)
          ;; Protoss Training & Warp-In
          (train-probe 1006 #t)
          (train-zealot 916 #t)
          (train-stalker 917 #t)
          (train-sentry 921 #t)
          (train-adept 922 #t)
          (train-high-templar 919 #t)
          (train-dark-templar 920 #t)
          (warp-in-zealot 1413 #t)
          (warp-in-stalker 1414 #t)
          (warp-in-sentry 1418 #t)
          (warp-in-adept 1419 #t)
          (warp-in-high-templar 1416 #t)
          (warp-in-dark-templar 1417 #t)
          (train-observer 977 #t)
          (train-immortal 979 #t)
          (train-warp-prism 976 #t)
          (train-colossus 978 #t)
          (train-disruptor 994 #t)
          (train-phoenix 946 #t)
          (train-void-ray 950 #t)
          (train-voidray 950 #f)
          (train-oracle 954 #t)
          (train-carrier 948 #t)
          (train-tempest 955 #t)
          (train-mothership 110 #t)
          ;; Protoss Morphs
          (morph-archon 1766 #t)
          (train-archon 1766 #f)
          (morph-warp-gate 1518 #t)
          (morph-gateway 1520 #t)
          (morph-warp-prism-phasing 1528 #t)
          (morph-warp-prism-transport 1530 #t)
          (morph-observer-siege-mode 3741 #t)
          ;; Protoss Building Construction
          (build-nexus 880 #t)
          (build-pylon 881 #t)
          (build-assimilator 882 #t)
          (build-gateway 883 #t)
          (build-forge 884 #t)
          (build-cybernetics-core 894 #t)
          (build-photon-cannon 887 #t)
          (build-shield-battery 895 #t)
          (build-twilight-council 886 #t)
          (build-robotics-facility 893 #t)
          (build-robotics-bay 892 #t)
          (build-robotics-support-bay 892 #f)
          (build-stargate 889 #t)
          (build-templar-archive 890 #t)
          (build-templar-archives 890 #f)
          (build-dark-shrine 891 #t)
          (build-fleet-beacon 885 #t)
          ;; Spells & Active Abilities
          (inject-larva 251 #t)
          (transfusion 1664 #t)
          (transfuse 1664 #f)
          (corrosive-bile 2338 #t)
          (fungal-growth 74 #t)
          (microbial-shroud 2545 #t)
          (neural-parasite 249 #t)
          (abduct 2067 #t)
          (blinding-cloud 2063 #t)
          (parasitic-bomb 2542 #t)
          (viper-consume 2073 #t)
          (consume 2073 #f)
          (viper-consume-structure 2069 #t)
          (spawn-locusts 1990 #t)
          (spawn-changeling 181 #t)
          (contaminate 1825 #t)
          (caustic-spray 2324 #t)
          (spread-creep-tumor 1694 #t)
          (spawn-creep-tumor 1694 #f)
          (burrow-down 3661 #t)
          (burrow 3661 #f)
          (burrow-up 3662 #t)
          (unburrow 3662 #f)
          (burrow-widow-mine 2095 #t)
          (unburrow-widow-mine 2097 #t)
          (burrow-lurker 2108 #t)
          (unburrow-lurker 2110 #t)
          (calldown-mule 171 #t)
          (mule-drop 171 #f)
          (scanner-sweep 399 #t)
          (scan 399 #f)
          (supply-drop 255 #t)
          (stimpack 3675 #t)
          (stim 3675 #f)
          (stim-marine 380 #t)
          (stim-marauder 253 #t)
          (medivac-boost 2116 #t)
          (lock-on 2350 #t)
          (heal 386 #t)
          (emp-round 1628 #t)
          (emp 1628 #f)
          (steady-targeting 2714 #t)
          (snipe 2714 #f)
          (cloak-ghost 382 #t)
          (decloak-ghost 383 #t)
          (cloak-banshee 392 #t)
          (decloak-banshee 393 #t)
          (yamato-cannon 401 #t)
          (yamato-gun 401 #f)
          (yamato 401 #f)
          (tactical-jump 2358 #t)
          (kd8-charge 2588 #t)
          (interference-matrix 3747 #t)
          (anti-armor-missile 3753 #t)
          (auto-turret 349 #t)
          (repair 3685 #t)
          (salvage 32 #t)
          (load-transport 3668 #t)
          (unload-all-at 3669 #t)
          (medivac-unload-all-at 396 #t)
          (warp-prism-unload-all-at 913 #t)
          (overlord-unload-all-at 1408 #t)
          (chrono-boost 3755 #t)
          (chronoboost 3755 #f)
          (battery-overcharge 4107 #t)
          (mass-recall 3757 #t)
          (blink 3687 #t)
          (blink-stalker 1442 #t)
          (adept-phase-shift 2544 #t)
          (psionic-transfer 2544 #f)
          (force-field 1526 #t)
          (guardian-shield 76 #t)
          (hallucination-phoenix 154 #t)
          (hallucination-archon 146 #t)
          (psi-storm 1036 #t)
          (psistorm 1036 #f)
          (feedback 140 #t)
          (immortal-barrier 2328 #t)
          (purification-nova 2346 #t)
          (graviton-beam 173 #t)
          (prismatic-alignment 2393 #t)
          (pulsar-beam 2375 #t)
          (pulsar-beam-on 2375 #f)
          (pulsar-beam-off 2376 #t)
          (oracle-revelation 2146 #t)
          (stasis-ward 2505 #t)
          (oracle-stasis-ward 2505 #f)
          (build-stasis-trap 2505 #f)
          (build-interceptors 1042 #t)
          (overlord-generate-creep 1882 #t)
          (generate-creep 1882 #f)
          (time-warp 2244 #t)
          (nexus-mass-recall 3757 #f)
          (mothership-mass-recall 2368 #t)
          (nexus-energy-recharge 4126 #t)
          (energy-recharge 4126 #f)
          (shield-battery-recharge 4113 #t)
          (shield-battery-restore 4113 #f)
          (shield-battery-restore-legacy 3751 #t)
          (bunker-load 407 #t)
          (bunker-unload 408 #t)
          (nydus-load 1437 #t)
          (nydus-unload 1438 #t)
          (nydus-worm-load 2370 #t)
          (nydus-worm-unload 2371 #t)
          (effect-repair 316 #t)
          (repair-scv 316 #f)
          (salvage-bunker 32 #f)
          (spine-crawler-uproot 1725 #t)
          (spine-crawler-root 1729 #t)
          (spore-crawler-uproot 1727 #t)
          (spore-crawler-root 1731 #t)
          (uproot 3681 #t)
          (root 3680 #t)
          (baneling-explode 42 #t)
          (widow-mine-attack 2099 #t)
          (widow-mine-retarget 2099 #f)
          (spawn-locusts-flying 2704 #t)
          (swarm-host-spawn-locusts 2704 #f)
          (locust-swoop 2706 #t)
          (cancel-adept-phase-shift 2594 #t)
          (cancel-phase-shift 2594 #f)
          (cancel-adept-shade 2546 #t)
          (cancel-build 314 #f)
          (cancel-building 314 #f)
          (shadow-stride 2700 #t)
          (morph-observer-mode 3739 #t)
          (morph-overseer-mode 3743 #t)
          (morph-oversight-mode 3745 #t)
          ;; Research Abilities
          (research-zergling-movementspeed 1253 #t)
          (research-metabolic-boost 1253 #f)
          (research-zergling-attackspeed 1252 #t)
          (research-adrenal-glands 1252 #f)
          (research-glial-reconstitution 216 #t)
          (research-tunneling-claws 217 #t)
          (research-centrifugal-hooks 1482 #t)
          (research-centrifical-hooks 1482 #f)
          (research-grooved-spines 1282 #t)
          (research-muscular-augments 1283 #t)
          (research-adaptive-talons 3709 #t)
          (research-lurker-range 3710 #t)
          (research-seismic-spines 3710 #f)
          (research-chitinous-plating 265 #t)
          (research-anabolic-synthesis 263 #t)
          (research-burrow 1225 #t)
          (research-pneumatized-carapace 1223 #t)
          (research-overlord-speed 1223 #f)
          (research-overlordspeed 1223 #f)
          (research-neural-parasite 1455 #t)
          (research-zerg-melee-weapons-1 1186 #t)
          (research-melee-attacks-1 1186 #f)
          (research-zerg-melee-weapons-2 1187 #t)
          (research-melee-attacks-2 1187 #f)
          (research-zerg-melee-weapons-3 1188 #t)
          (research-melee-attacks-3 1188 #f)
          (research-zerg-missile-weapons-1 1192 #t)
          (research-missile-attacks-1 1192 #f)
          (research-zerg-missile-weapons-2 1193 #t)
          (research-missile-attacks-2 1193 #f)
          (research-zerg-missile-weapons-3 1194 #t)
          (research-missile-attacks-3 1194 #f)
          (research-zerg-ground-armor-1 1189 #t)
          (research-ground-carapace-1 1189 #f)
          (research-zerg-ground-carapace-1 1189 #f)
          (research-zerg-ground-armor-2 1190 #t)
          (research-ground-carapace-2 1190 #f)
          (research-zerg-ground-carapace-2 1190 #f)
          (research-zerg-ground-armor-3 1191 #t)
          (research-ground-carapace-3 1191 #f)
          (research-zerg-ground-carapace-3 1191 #f)
          (research-zerg-flyer-weapons-1 1312 #t)
          (research-flyer-attacks-1 1312 #f)
          (research-zerg-flyer-weapons-2 1313 #t)
          (research-flyer-attacks-2 1313 #f)
          (research-zerg-flyer-weapons-3 1314 #t)
          (research-flyer-attacks-3 1314 #f)
          (research-zerg-flyer-armor-1 1315 #t)
          (research-flyer-carapace-1 1315 #f)
          (research-zerg-flyer-armor-2 1316 #t)
          (research-flyer-carapace-2 1316 #f)
          (research-zerg-flyer-armor-3 1317 #t)
          (research-flyer-carapace-3 1317 #f)
          (research-stimpack 730 #t)
          (research-combat-shield 731 #t)
          (research-concussive-shells 732 #t)
          (research-infernal-preigniter 761 #t)
          (research-infernal-pre-igniter 761 #f)
          (research-drilling-claws 764 #t)
          (research-smart-servos 766 #t)
          (research-cyclone-lock-on-damage 769 #t)
          (research-mag-field-accelerator 769 #f)
          (research-banshee-cloak 790 #t)
          (research-cloaking-field 790 #f)
          (research-hyperflight-rotors 799 #t)
          (research-advanced-ballistics 805 #t)
          (research-personal-cloaking 820 #t)
          (research-weapon-refit 1532 #t)
          (research-terran-infantry-weapons-1 652 #t)
          (research-infantry-weapons-1 652 #f)
          (research-terran-infantry-weapons-2 653 #t)
          (research-infantry-weapons-2 653 #f)
          (research-terran-infantry-weapons-3 654 #t)
          (research-infantry-weapons-3 654 #f)
          (research-terran-infantry-armor-1 656 #t)
          (research-infantry-armor-1 656 #f)
          (research-terran-infantry-armor-2 657 #t)
          (research-infantry-armor-2 657 #f)
          (research-terran-infantry-armor-3 658 #t)
          (research-infantry-armor-3 658 #f)
          (research-terran-vehicle-weapons-1 855 #t)
          (research-vehicle-weapons-1 855 #f)
          (research-terran-vehicle-weapons-2 856 #t)
          (research-vehicle-weapons-2 856 #f)
          (research-terran-vehicle-weapons-3 857 #t)
          (research-vehicle-weapons-3 857 #f)
          (research-terran-vehicle-plating-1 864 #t)
          (research-terran-vehicle-and-ship-plating-1 864 #f)
          (research-vehicle-and-ship-plating-1 864 #f)
          (research-terran-vehicle-plating-2 865 #t)
          (research-terran-vehicle-and-ship-plating-2 865 #f)
          (research-vehicle-and-ship-plating-2 865 #f)
          (research-terran-vehicle-plating-3 866 #t)
          (research-terran-vehicle-and-ship-plating-3 866 #f)
          (research-vehicle-and-ship-plating-3 866 #f)
          (research-terran-ship-weapons-1 861 #t)
          (research-ship-weapons-1 861 #f)
          (research-terran-ship-weapons-2 862 #t)
          (research-ship-weapons-2 862 #f)
          (research-terran-ship-weapons-3 863 #t)
          (research-ship-weapons-3 863 #f)
          (research-warpgate 1568 #t)
          (research-warp-gate 1568 #f)
          (research-warp-gate-research 1568 #f)
          (research-warpgate-research 1568 #f)
          (research-charge 1592 #t)
          (research-blink 1593 #t)
          (research-blink-tech 1593 #f)
          (research-resonating-glaives 1594 #t)
          (research-adept-piercing-attack 1594 #f)
          (research-psi-storm 1126 #t)
          (research-psistorm 1126 #f)
          (research-psi-storm-tech 1126 #f)
          (research-shadow-strike 2720 #t)
          (research-shadow-stride 2720 #f)
          (research-extended-thermal-lance 1097 #t)
          (research-gravitic-booster 1093 #t)
          (research-gravitic-boosters 1093 #f)
          (research-gravitic-drive 1094 #t)
          (research-flux-vanes 48 #t)
          (research-protoss-ground-weapons-1 1062 #t)
          (research-ground-weapons-1 1062 #f)
          (research-protoss-ground-weapons-2 1063 #t)
          (research-ground-weapons-2 1063 #f)
          (research-protoss-ground-weapons-3 1064 #t)
          (research-ground-weapons-3 1064 #f)
          (research-protoss-ground-armor-1 1065 #t)
          (research-ground-armor-1 1065 #f)
          (research-protoss-ground-armor-2 1066 #t)
          (research-ground-armor-2 1066 #f)
          (research-protoss-ground-armor-3 1067 #t)
          (research-ground-armor-3 1067 #f)
          (research-protoss-shields-1 1068 #t)
          (research-shields-1 1068 #f)
          (research-protoss-shields-2 1069 #t)
          (research-shields-2 1069 #f)
          (research-protoss-shields-3 1070 #t)
          (research-shields-3 1070 #f)
          (research-protoss-air-weapons-1 1562 #t)
          (research-air-weapons-1 1562 #f)
          (research-protoss-air-weapons-2 1563 #t)
          (research-air-weapons-2 1563 #f)
          (research-protoss-air-weapons-3 1564 #t)
          (research-air-weapons-3 1564 #f)
          (research-protoss-air-armor-1 1565 #t)
          (research-air-armor-1 1565 #f)
          (research-protoss-air-armor-2 1566 #t)
          (research-air-armor-2 1566 #f)
          (research-protoss-air-armor-3 1567 #t)
          (research-air-armor-3 1567 #f)))])
  (match-define (list sym id prim?) entry)
  (register-id-pair! SC2-ABILITY-SYM->ID SC2-ABILITY-ID->SYM sym id #:primary? prim?))

;; Decode-only variant ability ID aliases observed in `#115` pro-replay telemetry
;; (preserve canonical outbound IDs 2545 / 349 in SC2-ABILITY-SYM->ID).
(hash-set! SC2-ABILITY-ID->SYM 3807 'microbial-shroud)
(hash-set! SC2-ABILITY-ID->SYM 3829 'microbial-shroud)
(hash-set! SC2-ABILITY-ID->SYM 379 'auto-turret)

;; Populate Canonical UpgradeId Table
(for ([entry
       (in-list
        '((zergling-movementspeed 66 #t)
          (metabolic-boost 66 #f)
          (zergling-attackspeed 65 #t)
          (adrenal-glands 65 #f)
          (glial-reconstitution 2 #t)
          (tunneling-claws 3 #t)
          (centrifugal-hooks 75 #t)
          (centrifical-hooks 75 #f)
          (grooved-spines 134 #t)
          (muscular-augments 135 #t)
          (adaptive-talons 293 #t)
          (lurker-range 127 #t)
          (seismic-spines 127 #f)
          (chitinous-plating 4 #t)
          (anabolic-synthesis 88 #t)
          (burrow 64 #t)
          (overlord-speed 62 #t)
          (pneumatized-carapace 62 #f)
          (overlordspeed 62 #f)
          (neural-parasite 101 #t)
          (zerg-melee-weapons-1 53 #t)
          (melee-attacks-1 53 #f)
          (zerg-melee-weapons-2 54 #t)
          (melee-attacks-2 54 #f)
          (zerg-melee-weapons-3 55 #t)
          (melee-attacks-3 55 #f)
          (zerg-missile-weapons-1 59 #t)
          (missile-attacks-1 59 #f)
          (zerg-missile-weapons-2 60 #t)
          (missile-attacks-2 60 #f)
          (zerg-missile-weapons-3 61 #t)
          (missile-attacks-3 61 #f)
          (zerg-ground-armor-1 56 #t)
          (ground-carapace-1 56 #f)
          (zerg-ground-carapace-1 56 #f)
          (zerg-ground-armor-2 57 #t)
          (ground-carapace-2 57 #f)
          (zerg-ground-carapace-2 57 #f)
          (zerg-ground-armor-3 58 #t)
          (ground-carapace-3 58 #f)
          (zerg-ground-carapace-3 58 #f)
          (zerg-flyer-weapons-1 68 #t)
          (flyer-attacks-1 68 #f)
          (zerg-flyer-weapons-2 69 #t)
          (flyer-attacks-2 69 #f)
          (zerg-flyer-weapons-3 70 #t)
          (flyer-attacks-3 70 #f)
          (zerg-flyer-armor-1 71 #t)
          (flyer-carapace-1 71 #f)
          (zerg-flyer-armor-2 72 #t)
          (flyer-carapace-2 72 #f)
          (zerg-flyer-armor-3 73 #t)
          (flyer-carapace-3 73 #f)
          (stimpack 15 #t)
          (combat-shield 16 #t)
          (shield-wall 16 #f)
          (concussive-shells 17 #t)
          (punisher-grenades 17 #f)
          (infernal-preigniter 19 #t)
          (infernal-pre-igniter 19 #f)
          (drilling-claws 122 #t)
          (smart-servos 289 #t)
          (cyclone-lock-on-damage 144 #t)
          (mag-field-accelerator 144 #f)
          (banshee-cloak 20 #t)
          (cloaking-field 20 #f)
          (personal-cloaking 25 #t)
          (weapon-refit 76 #t)
          (hyperflight-rotors 138 #t)
          (advanced-ballistics 140 #t)
          (terran-infantry-weapons-1 7 #t)
          (infantry-weapons-1 7 #f)
          (terran-infantry-weapons-2 8 #t)
          (infantry-weapons-2 8 #f)
          (terran-infantry-weapons-3 9 #t)
          (infantry-weapons-3 9 #f)
          (terran-infantry-armor-1 11 #t)
          (infantry-armor-1 11 #f)
          (terran-infantry-armor-2 12 #t)
          (infantry-armor-2 12 #f)
          (terran-infantry-armor-3 13 #t)
          (infantry-armor-3 13 #f)
          (terran-vehicle-weapons-1 30 #t)
          (vehicle-weapons-1 30 #f)
          (terran-vehicle-weapons-2 31 #t)
          (vehicle-weapons-2 31 #f)
          (terran-vehicle-weapons-3 32 #t)
          (vehicle-weapons-3 32 #f)
          (terran-vehicle-plating-1 116 #t)
          (terran-vehicle-and-ship-plating-1 116 #f)
          (vehicle-and-ship-plating-1 116 #f)
          (terran-vehicle-plating-2 117 #t)
          (terran-vehicle-and-ship-plating-2 117 #f)
          (vehicle-and-ship-plating-2 117 #f)
          (terran-vehicle-plating-3 118 #t)
          (terran-vehicle-and-ship-plating-3 118 #f)
          (vehicle-and-ship-plating-3 118 #f)
          (terran-ship-weapons-1 36 #t)
          (ship-weapons-1 36 #f)
          (terran-ship-weapons-2 37 #t)
          (ship-weapons-2 37 #f)
          (terran-ship-weapons-3 38 #t)
          (ship-weapons-3 38 #f)
          (warpgate 84 #t)
          (warp-gate 84 #f)
          (warp-gate-research 84 #f)
          (warpgate-research 84 #f)
          (charge 86 #t)
          (blink 87 #t)
          (blink-tech 87 #f)
          (resonating-glaives 130 #t)
          (adept-piercing-attack 130 #f)
          (psi-storm 52 #t)
          (psistorm 52 #f)
          (psistorm-tech 52 #f)
          (psi-storm-tech 52 #f)
          (shadow-strike 141 #t)
          (shadow-stride 141 #f)
          (extended-thermal-lance 50 #t)
          (gravitic-booster 48 #t)
          (gravitic-boosters 48 #f)
          (gravitic-drive 49 #t)
          (flux-vanes 288 #t)
          (protoss-ground-weapons-1 39 #t)
          (ground-weapons-1 39 #f)
          (protoss-ground-weapons-2 40 #t)
          (ground-weapons-2 40 #f)
          (protoss-ground-weapons-3 41 #t)
          (ground-weapons-3 41 #f)
          (protoss-ground-armor-1 42 #t)
          (ground-armor-1 42 #f)
          (protoss-ground-armor-2 43 #t)
          (ground-armor-2 43 #f)
          (protoss-ground-armor-3 44 #t)
          (ground-armor-3 44 #f)
          (protoss-shields-1 45 #t)
          (shields-1 45 #f)
          (protoss-shields-2 46 #t)
          (shields-2 46 #f)
          (protoss-shields-3 47 #t)
          (shields-3 47 #f)
          (protoss-air-weapons-1 78 #t)
          (air-weapons-1 78 #f)
          (protoss-air-weapons-2 79 #t)
          (air-weapons-2 79 #f)
          (protoss-air-weapons-3 80 #t)
          (air-weapons-3 80 #f)
          (protoss-air-armor-1 81 #t)
          (air-armor-1 81 #f)
          (protoss-air-armor-2 82 #t)
          (air-armor-2 82 #f)
          (protoss-air-armor-3 83 #t)
          (air-armor-3 83 #f)))])
  (match-define (list sym id prim?) entry)
  (register-id-pair! SC2-UPGRADE-SYM->ID SC2-UPGRADE-ID->SYM sym id #:primary? prim?))

;; Populate Canonical BuffId Table
(for ([entry
       (in-list
        '((banshee-cloak 7 #t)
          (ghost-cloak 8 #t)
          (queen-spawn-larva-timer 11 #t)
          (fungal-growth 17 #t)
          (guardian-shield 18 #t)
          (neural-parasite 22 #t)
          (stimpack-marauder 24 #t)
          (stimpack 27 #t)
          (transfusion 28 #t)
          (oracle-revelation 49 #t)
          (oracle-cloak-field 55 #t)
          (oracle-weapon 56 #t)
          (pulsar-beam 56 #f)
          (oracle-stasis-trap-target 57 #t)
          (stasis-ward-target 57 #f)
          (blinding-cloud 83 #t)
          (medivac-speed-boost 89 #t)
          (immortal-overload 102 #t)
          (lock-on 116 #t)
          (parasitic-bomb 132 #t)
          (carry-mineral-field-minerals 271 #t)
          (carry-high-yield-mineral-field-minerals 272 #t)
          (carry-vespene-geyser-gas 273 #t)
          (carry-vespene-geyser-gas-protoss 274 #t)
          (carry-vespene-geyser-gas-zerg 275 #t)
          (chrono-boost 281 #t)
          (battery-overcharge 301 #t)))])
  (match-define (list sym id prim?) entry)
  (register-id-pair! SC2-BUFF-SYM->ID SC2-BUFF-ID->SYM sym id #:primary? prim?))

;; Populate Canonical EffectId Table
(for ([entry
       (in-list
        '((none 0 #t)
          (psi-storm 1 #t)
          (guardian-shield 2 #t)
          (temporal-field-growing 3 #t)
          (temporal-field 4 #t)
          (thermal-lances 5 #t)
          (scanner-sweep 6 #t)
          (nuke-persistent 7 #t)
          (liberator-defender-zone-setup 8 #t)
          (liberator-defender-zone 9 #t)
          (blinding-cloud 10 #t)
          (corrosive-bile 11 #t)
          (lurker-spines 12 #t)))])
  (match-define (list sym id prim?) entry)
  (register-id-pair! SC2-EFFECT-SYM->ID SC2-EFFECT-ID->SYM sym id #:primary? prim?))

(define ABILITY-CACHE-MISS (gensym 'ability-cache-miss))
(define NORMALIZE-SYM-CACHE (make-hasheq))
(define TRAIN-ABILITY-CACHE (make-hasheq))
(define BUILD-ABILITY-CACHE (make-hasheq))
(define RESEARCH-ABILITY-CACHE (make-hasheq))
(define MORPH-ABILITY-CACHE (make-hasheq))
(define SPELL-ABILITY-CACHE (make-hasheq))

(define-syntax-rule (with-symbol-cache cache key-expr body ...)
  (let ([k key-expr])
    (if (symbol? k)
        (let ([cached (hash-ref cache k ABILITY-CACHE-MISS)])
          (if (eq? cached ABILITY-CACHE-MISS)
              (let ([res (let () body ...)])
                (hash-set! cache k res)
                res)
              cached))
        (let () body ...))))

(define (normalize-sc2-name->symbol v)
  (cond
    [(symbol? v)
     (let ([cached (hash-ref NORMALIZE-SYM-CACHE v ABILITY-CACHE-MISS)])
       (if (eq? cached ABILITY-CACHE-MISS)
           (let ([res (string->symbol
                       (string-replace (string-downcase (symbol->string v)) "_" "-"))])
             (hash-set! NORMALIZE-SYM-CACHE v res)
             res)
           cached))]
    [(string? v)
     (string->symbol
      (string-replace (string-downcase (string-trim v)) "_" "-"))]
    [else 'unknown]))

(define (unit-symbol->sc2-id sym [default 0])
  (hash-ref SC2-UNIT-SYM->ID (normalize-sc2-name->symbol sym) default))

(define (sc2-id->unit-symbol id [default 'unknown])
  (hash-ref SC2-UNIT-ID->SYM id default))

(define (ability-symbol->sc2-id sym [default 1])
  (hash-ref SC2-ABILITY-SYM->ID (normalize-sc2-name->symbol sym) default))

(define (sc2-id->ability-symbol id [default 'smart])
  (hash-ref SC2-ABILITY-ID->SYM id default))

(define (train-symbol->ability-id unit-sym)
  (with-symbol-cache TRAIN-ABILITY-CACHE unit-sym
    (define norm (normalize-sc2-name->symbol unit-sym))
    (define prefixed (string->symbol (format "train-~a" norm)))
    (or (hash-ref SC2-ABILITY-SYM->ID prefixed #f)
        (hash-ref SC2-ABILITY-SYM->ID norm #f)
        (hash-ref SC2-ABILITY-SYM->ID (string->symbol (format "morph-~a" norm)) #f))))

(define (build-symbol->ability-id bldg-sym)
  (with-symbol-cache BUILD-ABILITY-CACHE bldg-sym
    (define norm (normalize-sc2-name->symbol bldg-sym))
    (define prefixed (string->symbol (format "build-~a" norm)))
    (or (hash-ref SC2-ABILITY-SYM->ID prefixed #f)
        (hash-ref SC2-ABILITY-SYM->ID (string->symbol (format "morph-~a" norm)) #f)
        (hash-ref SC2-ABILITY-SYM->ID norm #f))))

(define (research-symbol->ability-id upg-sym)
  (with-symbol-cache RESEARCH-ABILITY-CACHE upg-sym
    (define norm (normalize-sc2-name->symbol upg-sym))
    (define prefixed (string->symbol (format "research-~a" norm)))
    (or (hash-ref SC2-ABILITY-SYM->ID prefixed #f)
        (hash-ref SC2-ABILITY-SYM->ID norm #f))))

(define (morph-symbol->ability-id target-sym)
  (with-symbol-cache MORPH-ABILITY-CACHE target-sym
    (define norm (normalize-sc2-name->symbol target-sym))
    (cond
      [(memq norm '(lurker-den lurker-den-mp)) 1163]
      [else
       (define prefixed (string->symbol (format "morph-~a" norm)))
       (or (hash-ref SC2-ABILITY-SYM->ID prefixed #f)
           (hash-ref SC2-ABILITY-SYM->ID (string->symbol (format "build-~a" norm)) #f)
           (hash-ref SC2-ABILITY-SYM->ID norm #f))])))

(define (spell-symbol->ability-id spell-sym)
  (with-symbol-cache SPELL-ABILITY-CACHE spell-sym
    (define norm (normalize-sc2-name->symbol spell-sym))
    (or (hash-ref SC2-ABILITY-SYM->ID norm #f)
        (hash-ref SC2-ABILITY-SYM->ID (string->symbol (format "effect-~a" norm)) #f)
        (hash-ref SC2-SPELL-ABILITY-IDS norm #f))))

(define (upgrade-symbol->sc2-id upg-sym [default 0])
  (hash-ref SC2-UPGRADE-SYM->ID (normalize-sc2-name->symbol upg-sym) default))

(define (sc2-id->upgrade-symbol id [default #f])
  (hash-ref SC2-UPGRADE-ID->SYM id default))

(define (buff-id->symbol id [default 'unknown-buff])
  (hash-ref SC2-BUFF-ID->SYM id default))

(define (effect-id->symbol id [default 'none])
  (hash-ref SC2-EFFECT-ID->SYM id default))

;; =============================================================================
;; 4. `s2clientprotocol` Structs, Request Builders & Response Decoder
;; =============================================================================

(struct sc2-point2d (x y) #:transparent)
(struct sc2-point3d (x y z) #:transparent)
(struct sc2-unit-order (ability-id target-pos target-unit-tag progress) #:transparent)
(struct sc2-passenger-unit
  (tag unit-type health health-max shield shield-max energy energy-max)
  #:transparent)
(struct sc2-unit
  (display-type
   alliance
   tag
   unit-type
   owner
   pos
   facing
   radius
   build-progress
   cloak
   is-selected
   is-on-screen
   is-blip
   health
   health-max
   shield
   shield-max
   energy
   energy-max
   mineral-contents
   vespene-contents
   is-flying
   is-burrowed
   is-hallucination
   is-powered
   is-active
   orders
   add-on-tag
   buff-ids
   assigned-harvesters
   ideal-harvesters
   weapon-cooldown
   engaged-target-tag
   attack-upgrade-level
   armor-upgrade-level
   shield-upgrade-level
   passengers
   cargo-space-taken
   cargo-space-max)
  #:constructor-name raw-sc2-unit
  #:transparent)

(define make-sc2-unit
  (case-lambda
    [(display-type alliance tag unit-type owner pos facing radius build-progress
      cloak is-selected is-on-screen is-blip health health-max shield shield-max
      energy energy-max mineral-contents vespene-contents is-flying is-burrowed
      is-hallucination is-powered is-active orders add-on-tag buff-ids
      assigned-harvesters ideal-harvesters weapon-cooldown engaged-target-tag
      attack-upgrade-level armor-upgrade-level shield-upgrade-level)
     (raw-sc2-unit display-type alliance tag unit-type owner pos facing radius build-progress
                   cloak is-selected is-on-screen is-blip health health-max shield shield-max
                   energy energy-max mineral-contents vespene-contents is-flying is-burrowed
                   is-hallucination is-powered is-active orders add-on-tag buff-ids
                   assigned-harvesters ideal-harvesters weapon-cooldown engaged-target-tag
                   attack-upgrade-level armor-upgrade-level shield-upgrade-level
                   '() 0 0)]
    [(display-type alliance tag unit-type owner pos facing radius build-progress
      cloak is-selected is-on-screen is-blip health health-max shield shield-max
      energy energy-max mineral-contents vespene-contents is-flying is-burrowed
      is-hallucination is-powered is-active orders add-on-tag buff-ids
      assigned-harvesters ideal-harvesters weapon-cooldown engaged-target-tag
      attack-upgrade-level armor-upgrade-level shield-upgrade-level
      passengers cargo-space-taken cargo-space-max)
     (raw-sc2-unit display-type alliance tag unit-type owner pos facing radius build-progress
                   cloak is-selected is-on-screen is-blip health health-max shield shield-max
                   energy energy-max mineral-contents vespene-contents is-flying is-burrowed
                   is-hallucination is-powered is-active orders add-on-tag buff-ids
                   assigned-harvesters ideal-harvesters weapon-cooldown engaged-target-tag
                   attack-upgrade-level armor-upgrade-level shield-upgrade-level
                   passengers cargo-space-taken cargo-space-max)]))

(begin-for-syntax
  (struct sc2-unit-tx (info)
    #:property prop:struct-info (lambda (self) (sc2-unit-tx-info self))
    #:property prop:procedure
    (lambda (_self stx)
      (syntax-case stx ()
        [(_ arg ...) #'(make-sc2-unit arg ...)]
        [_ #'make-sc2-unit]))))

(define-syntax sc2-unit-id
  (let ([info (extract-struct-info (syntax-local-value #'sc2-unit))])
    (sc2-unit-tx
     (list (list-ref info 0)
           #'raw-sc2-unit
           (list-ref info 2)
           (list-ref info 3)
           (list-ref info 4)
           (list-ref info 5)))))

(struct sc2-effect (effect-id positions alliance owner radius) #:transparent)
(struct sc2-power-source (pos radius tag) #:transparent)
(struct sc2-player-common
  (player-id
   minerals
   vespene
   food-cap
   food-used
   food-army
   food-workers
   idle-worker-count
   army-count
   warp-gate-count
   larva-count)
  #:transparent)

(struct sc2-player-result (player-id result) #:transparent)
(struct sc2-observation
  (game-loop
   player-common
   units
   upgrade-ids
   power-sources
   camera
   dead-unit-tags
   effects
   player-results
   action-errors
   chat
   alerts)
  #:transparent)

(struct sc2-image-grid
  (bits-per-pixel
   width
   height
   data
   y-flip?
   lsb-first?)
  #:mutable
  #:transparent)

(struct sc2-game-info
  (map-name
   local-map-path
   player-info
   map-size
   playable-area
   start-locations
   pathing-grid
   terrain-height
   placement-grid)
  #:constructor-name raw-sc2-game-info
  #:transparent)

(define make-sc2-game-info
  (case-lambda
    [(map-name local-map-path player-info map-size playable-area start-locations)
     (raw-sc2-game-info map-name local-map-path player-info map-size playable-area
                        start-locations #f #f #f)]
    [(map-name local-map-path player-info map-size playable-area start-locations
               pathing-grid terrain-height placement-grid)
     (raw-sc2-game-info map-name local-map-path player-info map-size playable-area
                        start-locations pathing-grid terrain-height placement-grid)]))

(struct sc2-data-entry (id name) #:transparent)
(struct sc2-data (abilities units upgrades buffs effects) #:transparent)

(struct sc2-response
  (id
   status
   errors
   create-game
   join-game
   leave-game
   quit
   game-info
   observation
   action-results
   step-simulation-loop
   data
   query-placements
   ping)
  #:transparent)

(struct sc2-raw-unit-command
  (ability-id target-pos target-unit-tag unit-tags queue?)
  #:transparent)

(struct sc2-raw-camera-move (x y z) #:transparent)
(struct sc2-ui-control-group (action control-group-index) #:transparent)
(struct sc2-chat-action (channel message) #:transparent)
(struct sc2-query-placement (ability-id x y placing-unit-tag) #:transparent)

(define (race->sc2-enum r)
  (cond
    [(and (exact-integer? r) (<= 1 r 4)) r]
    [else
     (case (normalize-sc2-name->symbol r)
       [(terran) 1]
       [(zerg) 2]
       [(protoss) 3]
       [(random) 4]
       [else 4])]))

(define (sc2-enum->race id)
  (case id
    [(1) 'Terran]
    [(2) 'Zerg]
    [(3) 'Protoss]
    [(4) 'Random]
    [else 'Zerg]))

(define (difficulty->sc2-enum d)
  (cond
    [(and (exact-integer? d) (<= 1 d 10)) d]
    [else
     (case (normalize-sc2-name->symbol d)
       [(veryeasy very-easy) 1]
       [(easy) 2]
       [(medium) 3]
       [(mediumhard medium-hard) 4]
       [(hard) 5]
       [(harder) 6]
       [(veryhard very-hard) 7]
       [(cheatvision cheat-vision) 8]
       [(cheatmoney cheat-money) 9]
       [(cheatinsane cheat-insane) 10]
       [else 7])]))

(define (status-enum->symbol s)
  (case s
    [(1) 'launched]
    [(2) 'init-game]
    [(3) 'in-game]
    [(4) 'in-replay]
    [(5) 'ended]
    [(6) 'quit]
    [else 'unknown]))

(define (result-enum->symbol r)
  (case r
    [(1) 'Victory]
    [(2) 'Defeat]
    [(3) 'Tie]
    [(4) 'Undecided]
    [else 'Undecided]))

(define (wrap-sc2-request field-num submsg-bytes [req-id #f])
  (bytes-append
   (encode-submessage-field field-num submsg-bytes)
   (if (and (exact-integer? req-id) (<= 0 req-id #xFFFFFFFF))
       (encode-uint32 97 req-id)
       #"")))

(define (sanitize-world-coord v [default 0.0])
  (cond
    [(and (real? v) (not (nan? v)) (not (infinite? v)))
     (define f (real->double-flonum v))
     (cond
       [(< f 0.0) 0.0]
       [(> f 256.0) 256.0]
       [(= f 0.0) 0.0]
       [else f])]
    [else default]))

(define (valid-world-coord? v)
  (and (real? v)
       (not (nan? v))
       (not (infinite? v))
       (let ([f (real->double-flonum v)])
         (and (>= f 0.0) (<= f 256.0)))))

(define (valid-nonempty-utf8-str? s [max-bytes 256])
  (and (string? s)
       (let ([blen (bytes-length (string->bytes/utf-8 s))])
         (and (> blen 0) (<= blen max-bytes)))))

(define (valid-tcp-port? p)
  (and (exact-integer? p) (<= 1 p 65535)))

(define (encode-point2d x y)
  (bytes-append (encode-float32 1 (sanitize-world-coord x 0.0))
                (encode-float32 2 (sanitize-world-coord y 0.0))))

(define (encode-point3d x y [z 0.0])
  (bytes-append (encode-float32 1 (sanitize-world-coord x 0.0))
                (encode-float32 2 (sanitize-world-coord y 0.0))
                (encode-float32 3 (sanitize-finite-float32 z 0.0))))

(define encode-point encode-point3d)

(define (encode-player-setup type race [difficulty #f] [player-name #f])
  (define eff-type
    (if (and (exact-integer? type) (<= 1 type 3)) type 1))
  (bytes-append
   (encode-int32 1 eff-type)
   (encode-int32 2 (race->sc2-enum race))
   (if difficulty (encode-int32 3 (difficulty->sc2-enum difficulty)) #"")
   (if (valid-nonempty-utf8-str? player-name 256)
       (encode-string-field 4 player-name)
       #"")))

(define (make-request-create-game #:map-path [map-path "Simple64.SC2Map"]
                                  #:battlenet-map-name [bnet-map #f]
                                  #:include-map-data? [include-map-data? #f]
                                  #:player-setups [player-setups #f]
                                  #:our-race [our-race 'Random]
                                  #:computer-race [computer-race 'Protoss]
                                  #:computer-difficulty [computer-difficulty 'VeryHard]
                                  #:realtime? [realtime? #f]
                                  #:disable-fog? [disable-fog? #f]
                                  #:random-seed [random-seed #f]
                                  #:id [req-id #f])
  (define eff-map-path
    (if (valid-nonempty-utf8-str? map-path 260)
        map-path
        "Simple64.SC2Map"))
  (define map-data-bytes
    (if (and include-map-data? (string? map-path) (file-exists? map-path))
        (with-handlers ([exn:fail? (lambda (_e) #"")])
          (encode-bytes-field 7 (call-with-input-file map-path port->bytes)))
        #""))
  (define map-part
    (if (valid-nonempty-utf8-str? bnet-map 260)
        (encode-string-field 2 bnet-map)
        (encode-submessage-field 1
                                 (bytes-append (encode-string-field 1 eff-map-path)
                                               map-data-bytes))))
  (define valid-custom-setups
    (if (and (list? player-setups) (not (null? player-setups)))
        (filter-map
         (lambda (ps)
           (match ps
             [(list type race diff name)
              (encode-submessage-field 3 (encode-player-setup type race diff name))]
             [(list type race diff)
              (encode-submessage-field 3 (encode-player-setup type race diff))]
             [(list type race)
              (encode-submessage-field 3 (encode-player-setup type race))]
             [_ #f]))
         player-setups)
        '()))
  (define setups-bytes
    (if (not (null? valid-custom-setups))
        (apply bytes-append valid-custom-setups)
        (bytes-append
         (encode-submessage-field 3 (encode-player-setup 1 our-race))
         (encode-submessage-field 3 (encode-player-setup 2 computer-race computer-difficulty)))))
  (define body
    (bytes-append
     map-part
     setups-bytes
     (if disable-fog? (encode-bool 4 #t) #"")
     (if (and (exact-integer? random-seed) (<= 0 random-seed #xFFFFFFFF))
         (encode-uint32 5 random-seed)
         #"")
     (encode-bool 6 (not (not realtime?)))))
  (wrap-sc2-request 1 body req-id))

(define (encode-port-set game-port base-port)
  (bytes-append (encode-int32 1 game-port)
                (encode-int32 2 base-port)))

(define (make-request-join-game #:race [race 'Random]
                                #:observed-player-id [obs-id #f]
                                #:shared-port [shared-port #f]
                                #:server-ports [server-ports #f]
                                #:client-ports [client-ports '()]
                                #:player-name [player-name #f]
                                #:host-ip [host-ip #f]
                                #:raw? [raw? #t]
                                #:score? [score? #t]
                                #:show-cloaked? [show-cloaked? #t]
                                #:raw-affects-selection? [raw-affects-selection? #t]
                                #:raw-crop-to-playable-area? [raw-crop-to-playable-area? #t]
                                #:show-placeholders? [show-placeholders? #t]
                                #:show-burrowed-shadows? [show-burrowed-shadows? #t]
                                #:id [req-id #f])
  ;; InterfaceOptions (sc2api.proto):
  ;; raw=1, score=2, show_cloaked=5, raw_affects_selection=6,
  ;; raw_crop_to_playable_area=7, show_placeholders=8, show_burrowed_shadows=9
  (define iface-options
    (bytes-append
     (encode-bool 1 (not (not raw?)))
     (encode-bool 2 (not (not score?)))
     (encode-bool 5 (not (not show-cloaked?)))
     (encode-bool 6 (not (not raw-affects-selection?)))
     (encode-bool 7 (not (not raw-crop-to-playable-area?)))
     (encode-bool 8 (not (not show-placeholders?)))
     (encode-bool 9 (not (not show-burrowed-shadows?)))))
  (define participant-part
    (if (and (exact-integer? obs-id) (<= 1 obs-id #xFFFFFFFF))
        (encode-uint32 2 obs-id)
        (encode-int32 1 (race->sc2-enum race))))
  (define server-ports-part
    (match server-ports
      [(or (list (? valid-tcp-port? gp) (? valid-tcp-port? bp))
           (cons (? valid-tcp-port? gp) (? valid-tcp-port? bp)))
       (encode-submessage-field 4 (encode-port-set gp bp))]
      [_ #""]))
  (define client-ports-part
    (apply bytes-append
           (for/list ([cp (in-list (if (list? client-ports) client-ports '()))])
             (match cp
               [(or (list (? valid-tcp-port? gp) (? valid-tcp-port? bp))
                    (cons (? valid-tcp-port? gp) (? valid-tcp-port? bp)))
                (encode-submessage-field 5 (encode-port-set gp bp))]
               [_ #""]))))
  (define body
    (bytes-append
     participant-part
     (encode-submessage-field 3 iface-options)
     server-ports-part
     client-ports-part
     (if (valid-tcp-port? shared-port) (encode-int32 6 shared-port) #"")
     (if (valid-nonempty-utf8-str? player-name 256) (encode-string-field 7 player-name) #"")
     (if (valid-nonempty-utf8-str? host-ip 256) (encode-string-field 8 host-ip) #"")))
  (wrap-sc2-request 2 body req-id))

(define (make-request-leave-game #:id [req-id #f])
  (wrap-sc2-request 5 #"" req-id))

(define (make-request-quit #:id [req-id #f])
  (wrap-sc2-request 8 #"" req-id))

(define (make-request-game-info #:id [req-id #f])
  (wrap-sc2-request 9 #"" req-id))

(define (make-request-observation #:disable-fog? [disable-fog? #f]
                                  #:game-loop [game-loop #f]
                                  #:id [req-id #f])
  (define body
    (bytes-append
     (if disable-fog? (encode-bool 1 #t) #"")
     (if (and (exact-integer? game-loop) (<= 0 game-loop #xFFFFFFFF))
         (encode-uint32 2 game-loop)
         #"")))
  (wrap-sc2-request 10 body req-id))

(define (extract-nested-submsg-bytes action-bytes outer-fnum inner-fnum)
  (with-handlers ([exn:fail? (lambda (_e) #"")])
    (define top (decode-protobuf-message action-bytes))
    (define outer (assoc outer-fnum top))
    (if (and outer (= (second outer) 2))
        (let* ([inner-fields (decode-protobuf-message (third outer))]
               [inner (assoc inner-fnum inner-fields)])
          (if (and inner (= (second inner) 2))
              (third inner)
              #""))
        #"")))

(define (encode-action-raw-unit-command cmd)
  (define typed (and (sc2-raw-unit-command? cmd)
                     (legacy-wire-action->typed-sc2-action cmd)))
  (if (and typed
           (or (WireCmdNone? typed)
               (WireCmdPoint? typed)
               (WireCmdUnit? typed)
               (WireCmdArchon? typed)))
      (extract-nested-submsg-bytes (encode-typed-sc2-action typed) 1 1)
      #""))

(define (encode-action-raw-camera-move cm)
  (define typed (and (sc2-raw-camera-move? cm)
                     (legacy-wire-action->typed-sc2-action cm)))
  (if (and typed (WireCameraMove? typed))
      (extract-nested-submsg-bytes (encode-typed-sc2-action typed) 1 2)
      #""))

;; ActionControlGroup (data/proto/ui.proto):
;;   Action.action_ui = 4 (sc2api.proto:634)
;;   ActionUI.control_group = 1 (ui.proto:79)
;;   ActionControlGroup:
;;     field 1 = action (ControlGroupAction enum: 1=Recall, 2=Set, 3=Append, 4=SetAndSteal, 5=AppendAndSteal)
;;     field 2 = control_group_index (uint32 0..9)
(define (encode-action-ui-control-group cg)
  (match cg
    [(sc2-ui-control-group (? exact-integer? act-enum) (? exact-integer? grp-idx))
     #:when (and (<= 1 act-enum 5) (<= 0 grp-idx 9))
     (bytes-append
      (encode-int32 1 act-enum)
      (encode-uint32 2 grp-idx))]
    [_ #""]))

(define SC2-TOTAL-WIRE-ACTION-DROP-COUNT (box 0))

(define (get-total-wire-action-drop-count)
  (unbox SC2-TOTAL-WIRE-ACTION-DROP-COUNT))

(define (legacy-wire-action->typed-sc2-action act)
  (cond
    [(TypedSc2WireAction? act) act]
    [(sc2-raw-unit-command? act)
     (match-define (sc2-raw-unit-command ab-id target-pos target-tag unit-tags queue?) act)
     (define-values (pos-mode px py)
       (match target-pos
         [(sc2-point2d (? real? x) (? real? y))
          (values #t (real->double-flonum x) (real->double-flonum y))]
         [(sc2-point3d (? real? x) (? real? y) _)
          (values #t (real->double-flonum x) (real->double-flonum y))]
         [(or (list (? real? x) (? real? y))
              (cons (? real? x) (? real? y)))
          (values #t (real->double-flonum x) (real->double-flonum y))]
         [#f
          (values #f 0.0 0.0)]
         [_
          (values 'invalid 0.0 0.0)]))
     (define eff-tgt-tag (if (eq? target-tag #f) 0 target-tag))
     (if (and (boolean? pos-mode)
              (exact-integer? ab-id)
              (exact-integer? eff-tgt-tag)
              (list? unit-tags)
              (pair? unit-tags)
              (andmap exact-integer? unit-tags))
         (validate-legacy-wire-command ab-id pos-mode px py eff-tgt-tag unit-tags (not (not queue?)))
         #f)]
    [(sc2-raw-camera-move? act)
     (match-define (sc2-raw-camera-move x y z) act)
     (and (real? x) (real? y) (real? z)
          (make-wire-camera-move x y z))]
    [(sc2-chat-action? act)
     (match-define (sc2-chat-action chan msg) act)
     (and (memv chan '(1 2))
          (string? msg)
          (make-wire-chat (= chan 2) msg))]
    [(bytes? act)
     (decode-typed-sc2-action act)]
    [else #f]))

(define (encode-sc2-action act)
  (cond
    [(sc2-ui-control-group? act)
     ;; Action.action_ui (field 4 in sc2api.proto) -> ActionUI.control_group (field 1 in ui.proto) -> ActionControlGroup
     (define cg-bytes (encode-action-ui-control-group act))
     (cond
       [(> (bytes-length cg-bytes) 0)
        (encode-submessage-field 4 (encode-submessage-field 1 cg-bytes))]
       [else
        (set-box! SC2-TOTAL-WIRE-ACTION-DROP-COUNT
                  (add1 (unbox SC2-TOTAL-WIRE-ACTION-DROP-COUNT)))
        #""])]
    [else
     (define typed-act (legacy-wire-action->typed-sc2-action act))
     (cond
       [typed-act
        (encode-typed-sc2-action typed-act)]
       [else
        (unless (or (eq? act #f)
                    (and (bytes? act) (zero? (bytes-length act))))
          (set-box! SC2-TOTAL-WIRE-ACTION-DROP-COUNT
                    (add1 (unbox SC2-TOTAL-WIRE-ACTION-DROP-COUNT))))
        #""])]))

(define (make-request-action actions #:id [req-id #f])
  (define body
    (apply bytes-append
           (for/list ([a (in-list (if (list? actions) actions '()))])
             (define act-bs (encode-sc2-action a))
             (if (> (bytes-length act-bs) 0)
                 (encode-submessage-field 1 act-bs)
                 #""))))
  (if (> (bytes-length body) 0)
      (wrap-sc2-request 11 body req-id)
      #""))

(define (make-request-step [count 'unset] #:count [kw-count 'unset] #:id [req-id #f])
  (define eff-c
    (cond
      [(not (eq? kw-count 'unset))
       (if (and (exact-integer? kw-count) (<= 1 kw-count 65535)) kw-count 1)]
      [(not (eq? count 'unset))
       (if (and (exact-integer? count) (<= 1 count 65535)) count 1)]
      [else 4]))
  (wrap-sc2-request 12 (encode-uint32 1 eff-c) req-id))

(define (make-request-data #:ability-id? [ability-id? #t]
                           #:unit-type-id? [unit-type-id? #t]
                           #:upgrade-id? [upgrade-id? #t]
                           #:buff-id? [buff-id? #t]
                           #:effect-id? [effect-id? #t]
                           #:id [req-id #f])
  (define body
    (bytes-append
     (if ability-id? (encode-bool 1 #t) #"")
     (if unit-type-id? (encode-bool 2 #t) #"")
     (if upgrade-id? (encode-bool 3 #t) #"")
     (if buff-id? (encode-bool 4 #t) #"")
     (if effect-id? (encode-bool 5 #t) #"")))
  (wrap-sc2-request 13 body req-id))

(define (encode-valid-query-placement-item p)
  (define parsed
    (match p
      [(sc2-query-placement ab x0 y0 ut) (list ab x0 y0 ut)]
      [(list ab x0 y0 ut) (list ab x0 y0 ut)]
      [(list ab x0 y0) (list ab x0 y0 #f)]
      [_ #f]))
  (and parsed
       (match-let ([(list ab-id x y unit-tag) parsed])
         (define valid-ab?
           (and (exact-positive-integer? ab-id) (<= ab-id #x7FFFFFFF)))
         (define valid-xy?
           (and (valid-world-coord? x) (valid-world-coord? y)))
         (define valid-tag?
           (or (eq? unit-tag #f)
               (and (exact-integer? unit-tag) (= unit-tag 0))
               (and (exact-integer? unit-tag)
                    (> unit-tag 0)
                    (<= unit-tag #xFFFFFFFFFFFFFFFF))))
         (and valid-ab? valid-xy? valid-tag?
              (let ([sub
                     (bytes-append
                      (encode-int32 1 ab-id)
                      (encode-submessage-field 2 (encode-point2d x y))
                      (if (and (exact-integer? unit-tag) (> unit-tag 0))
                          (encode-uint64 3 unit-tag)
                          #""))])
                ;; query.proto field 3 is `placements`
                (encode-submessage-field 3 sub))))))

(define (make-request-query-placement placements
                                      #:ignore-resource-requirements? [ignore-res? #f]
                                      #:id [req-id #f])
  (define valid-subs
    (if (list? placements)
        (filter-map encode-valid-query-placement-item placements)
        '()))
  (if (null? valid-subs)
      #""
      (let ([body (bytes-append
                   (apply bytes-append valid-subs)
                   (if ignore-res? (encode-bool 4 #t) #""))])
        (wrap-sc2-request 14 body req-id))))

;; =============================================================================
;; `s2clientprotocol/debug.proto` RequestDebug Builders (Request.debug = field 20)
;; =============================================================================

;; Encodes DebugCommand { create_unit = 3 (DebugCreateUnit { unit_type=1, owner=2, pos=3, quantity=4 }) }.
(define (encode-debug-create-unit unit-type owner x-or-pos [y-or-qty 1] [opt-qty 1])
  (define unit-id
    (if (exact-integer? unit-type)
        unit-type
        (unit-symbol->sc2-id unit-type 0)))
  (define-values (px py qty)
    (cond
      [(any-point? x-or-pos)
       (values (any-point-x x-or-pos)
               (any-point-y x-or-pos)
               (if (exact-positive-integer? y-or-qty) y-or-qty 1))]
      [else
       (values x-or-pos
               (if (real? y-or-qty) y-or-qty 0.0)
               (if (exact-positive-integer? opt-qty) opt-qty 1))]))
  (if (and (exact-positive-integer? unit-id)
           (<= unit-id #xFFFFFFFF)
           (exact-integer? owner)
           (valid-world-coord? px)
           (valid-world-coord? py)
           (exact-positive-integer? qty)
           (<= qty #xFFFFFFFF))
      (let ([create-bs
             (bytes-append
              (encode-uint32 1 unit-id)
              (encode-int32 2 owner)
              (encode-submessage-field 3 (encode-point2d px py))
              (encode-uint32 4 qty))])
        (encode-submessage-field 3 create-bs))
      #""))

;; Encodes DebugCommand { kill_unit = 4 (DebugKillUnit { repeated uint64 tag = 1 }) }.
(define (encode-debug-kill-unit tags)
  (define raw-tags (if (list? tags) tags (list tags)))
  (define valid-tags
    (for/list ([t (in-list raw-tags)]
               #:when (and (exact-integer? t)
                           (> t 0)
                           (<= t #xFFFFFFFFFFFFFFFF)))
      t))
  (if (null? valid-tags)
      #""
      (let ([kill-bs
             (apply bytes-append
                    (for/list ([t (in-list valid-tags)])
                      (encode-uint64 1 t)))])
        (encode-submessage-field 4 kill-bs))))

;; Encodes DebugCommand { test_process = 5 (DebugTestProcess { test=1 (hang=1, crash=2, exit=3), delay_ms=2 }) }.
(define (encode-debug-test-process [test-type 'exit] [delay-ms #f])
  (define test-enum
    (cond
      [(and (exact-integer? test-type) (<= 1 test-type 3)) test-type]
      [(symbol? test-type)
       (case (normalize-sc2-name->symbol test-type)
         [(hang) 1]
         [(crash) 2]
         [(exit) 3]
         [else #f])]
      [else #f]))
  (if test-enum
      (let ([tp-bs
             (bytes-append
              (encode-int32 1 test-enum)
              (if (and (exact-integer? delay-ms) (>= delay-ms 0) (<= delay-ms #x7FFFFFFF))
                  (encode-int32 2 delay-ms)
                  #""))])
        (encode-submessage-field 5 tp-bs))
      #""))

;; Encodes Request { RequestDebug debug = 20 { repeated DebugCommand debug = 1 } } (data/proto/sc2api.proto:116,505).
(define (encode-request-debug debug-cmds #:id [req-id #f])
  (define cmd-list
    (cond
      [(list? debug-cmds) debug-cmds]
      [(bytes? debug-cmds) (list debug-cmds)]
      [(pair? debug-cmds) (list debug-cmds)]
      [else '()]))
  (define body
    (apply bytes-append
           (for/list ([c (in-list cmd-list)])
             (define bs
               (cond
                 [(bytes? c) c]
                 [else
                  (match c
                    [(list 'create-unit ut owner x y qty)
                     (encode-debug-create-unit ut owner x y qty)]
                    [(list 'create-unit ut owner x y)
                     (encode-debug-create-unit ut owner x y 1)]
                    [(list 'create-unit ut owner pos)
                     (encode-debug-create-unit ut owner pos 1)]
                    [(list 'kill-unit tags)
                     (encode-debug-kill-unit tags)]
                    [(list 'test-process test-sym delay-ms)
                     (encode-debug-test-process test-sym delay-ms)]
                    [(list 'test-process test-sym)
                     (encode-debug-test-process test-sym)]
                    [_ #""])]))
             (if (and (bytes? bs) (> (bytes-length bs) 0))
                 (encode-submessage-field 1 bs)
                 #""))))
  (if (> (bytes-length body) 0)
      (wrap-sc2-request 20 body req-id)
      #""))

(define make-request-debug encode-request-debug)

(define (make-request-save-replay #:id [req-id #f])
  (wrap-sc2-request 15 #"" req-id))

(define (decode-response-save-replay-bytes bstr)
  (and (bytes? bstr)
       (let* ([fields (decode-protobuf-message bstr)]
              [sr-b (field-first-bytes fields 15 #f)])
         (and sr-b
              (let ([sr-fields (decode-protobuf-message sr-b)])
                (field-first-bytes sr-fields 1 #f))))))

(define (sc2-ws-save-replay! conn replay-path #:id [req-id #f])
  (sc2-ws-send-binary! conn (make-request-save-replay #:id req-id))
  (define resp-bytes (sc2-ws-recv-binary! conn))
  (define replay-bytes (and (bytes? resp-bytes) (decode-response-save-replay-bytes resp-bytes)))
  (cond
    [(and (bytes? replay-bytes) (> (bytes-length replay-bytes) 0))
     (call-with-output-file replay-path
       (lambda (out) (write-bytes replay-bytes out))
       #:exists 'replace)
     (bytes-length replay-bytes)]
    [else #f]))

(define (make-request-ping #:id [req-id #f])
  (wrap-sc2-request 19 #"" req-id))

;; =============================================================================
;; 5. `s2clientprotocol` Response Decoders
;; =============================================================================

(define (skip-protobuf-wire-value bstr wire-type next-pos end)
  (case wire-type
    [(0)
     (define-values (_v pos2) (decode-varint bstr next-pos))
     pos2]
    [(1)
     (define pos2 (+ next-pos 8))
     (when (> pos2 end)
       (error 'decode-protobuf-message "Truncated fixed64 field"))
     pos2]
    [(2)
     (define-values (len pos-len) (decode-varint bstr next-pos))
     (define pos2 (+ pos-len len))
     (when (> pos2 end)
       (error 'decode-protobuf-message "Truncated length-delimited field"))
     pos2]
    [(5)
     (define pos2 (+ next-pos 4))
     (when (> pos2 end)
       (error 'decode-protobuf-message "Truncated fixed32 field"))
     pos2]
    [else
     (error 'decode-protobuf-message "Unsupported protobuf wire-type ~a" wire-type)]))

;; Shared decoder for Point2D (fields 1, 2) and Point (fields 1, 2, 3).
(define (decode-point-coords bstr start end allow-z?)
  (define x #f)
  (define y #f)
  (define z #f)
  (let loop ([pos start])
    (when (< pos end)
      (define-values (tag next-pos) (decode-varint bstr pos))
      (define field-num (arithmetic-shift tag -3))
      (define wire-type (bitwise-and tag #x07))
      (cond
        [(and (= wire-type 5) (<= (+ next-pos 4) end))
         (case field-num
           [(1) (unless x (set! x (decode-float32 bstr next-pos)))]
           [(2) (unless y (set! y (decode-float32 bstr next-pos)))]
           [(3) (when (and allow-z? (not z)) (set! z (decode-float32 bstr next-pos)))])
         (loop (+ next-pos 4))]
        [else
         (loop (skip-protobuf-wire-value bstr wire-type next-pos end))])))
  (values (or x 0.0) (or y 0.0) (or z 0.0)))

(define (decode-point2d-bytes bstr [start 0] [end (bytes-length bstr)])
  (define-values (x y _z) (decode-point-coords bstr start end #f))
  (sc2-point2d x y))

(define (decode-point3d-bytes bstr [start 0] [end (bytes-length bstr)])
  (define-values (x y z) (decode-point-coords bstr start end #t))
  (sc2-point3d x y z))

(define (decode-unit-order-bytes bstr [start 0] [end (bytes-length bstr)])
  (define ab-id #f)
  (define target-pos #f)
  (define target-tag #f)
  (define progress #f)
  (let loop ([pos start])
    (when (< pos end)
      (define-values (tag next-pos) (decode-varint bstr pos))
      (define field-num (arithmetic-shift tag -3))
      (define wire-type (bitwise-and tag #x07))
      (case wire-type
        [(0)
         (define-values (v pos2) (decode-varint bstr next-pos))
         (case field-num
           [(1) (unless ab-id (set! ab-id v))]
           [(3) (unless target-tag (set! target-tag v))])
         (loop pos2)]
        [(2)
         (define-values (len pos-len) (decode-varint bstr next-pos))
         (define pos2 (+ pos-len len))
         (when (> pos2 end)
           (error 'decode-protobuf-message "Truncated length-delimited field ~a" field-num))
         (when (and (= field-num 2) (not target-pos))
           (set! target-pos (decode-point3d-bytes bstr pos-len pos2)))
         (loop pos2)]
        [(5)
         (define pos2 (+ next-pos 4))
         (when (> pos2 end)
           (error 'decode-protobuf-message "Truncated fixed32 field ~a" field-num))
         (when (and (= field-num 4) (not progress))
           (set! progress (decode-float32 bstr next-pos)))
         (loop pos2)]
        [else
         (loop (skip-protobuf-wire-value bstr wire-type next-pos end))])))
  (sc2-unit-order (or ab-id 0) target-pos (or target-tag 0) (or progress 0.0)))

(define (decode-passenger-unit-bytes bstr start end)
  (define f-tag #f)
  (define f-unit-type #f)
  (define f-unit-type-fallback #f)
  (define f-health #f)
  (define f-health-max #f)
  (define f-shield #f)
  (define f-shield-max #f)
  (define f-energy #f)
  (define f-energy-max #f)
  (let loop ([pos start])
    (when (< pos end)
      (define-values (tag next-pos) (decode-varint bstr pos))
      (define field-num (arithmetic-shift tag -3))
      (define wire-type (bitwise-and tag #x07))
      (case wire-type
        [(0)
         (define-values (v pos2) (decode-varint bstr next-pos))
         (case field-num
           [(1) (unless f-tag (set! f-tag v))]
           [(6) (unless f-unit-type (set! f-unit-type v))]
           ;; Compatibility fallback when synthetic fixtures encode unit_type as varint field 8
           ;; (official raw.proto field 8 is float energy_max, wire-type 5).
           [(8) (unless f-unit-type-fallback (set! f-unit-type-fallback v))])
         (loop pos2)]
        [(5)
         (define pos2 (+ next-pos 4))
         (when (> pos2 end)
           (error 'decode-protobuf-message "Truncated fixed32 passenger field ~a" field-num))
         (case field-num
           [(2) (unless f-health (set! f-health (decode-float32 bstr next-pos)))]
           [(3) (unless f-health-max (set! f-health-max (decode-float32 bstr next-pos)))]
           [(4) (unless f-shield (set! f-shield (decode-float32 bstr next-pos)))]
           [(5) (unless f-energy (set! f-energy (decode-float32 bstr next-pos)))]
           [(7) (unless f-shield-max (set! f-shield-max (decode-float32 bstr next-pos)))]
           [(8) (unless f-energy-max (set! f-energy-max (decode-float32 bstr next-pos)))])
         (loop pos2)]
        [else
         (loop (skip-protobuf-wire-value bstr wire-type next-pos end))])))
  (sc2-passenger-unit (or f-tag 0)
                      (or f-unit-type f-unit-type-fallback 0)
                      (or f-health 0.0)
                      (or f-health-max 0.0)
                      (or f-shield 0.0)
                      (or f-shield-max 0.0)
                      (or f-energy 0.0)
                      (or f-energy-max 0.0)))

(define (decode-unit-bytes bstr [start 0] [end (bytes-length bstr)])
  (define f-display-type #f)
  (define f-alliance #f)
  (define f-tag #f)
  (define f-unit-type #f)
  (define f-owner #f)
  (define f-pos #f)
  (define f-facing #f)
  (define f-radius #f)
  (define f-build-progress #f)
  (define f-cloak #f)
  (define f-is-selected #f)
  (define f-is-on-screen #f)
  (define f-is-blip #f)
  (define f-health #f)
  (define f-health-max #f)
  (define f-shield #f)
  (define f-shield-max #f)
  (define f-energy #f)
  (define f-energy-max #f)
  (define f-mineral-contents #f)
  (define f-vespene-contents #f)
  (define f-is-flying #f)
  (define f-is-burrowed #f)
  (define f-is-hallucination #f)
  (define f-is-powered #f)
  (define f-is-active #f)
  (define rev-orders '())
  (define f-add-on-tag #f)
  (define rev-passengers '())
  (define f-cargo-space-taken #f)
  (define f-cargo-space-max #f)
  (define rev-buff-ids '())
  (define f-assigned-harvesters #f)
  (define f-ideal-harvesters #f)
  (define f-weapon-cooldown #f)
  (define f-engaged-target-tag #f)
  (define f-attack-upgrade-level #f)
  (define f-armor-upgrade-level #f)
  (define f-shield-upgrade-level #f)
  (let loop ([pos start])
    (when (< pos end)
      (define-values (tag next-pos) (decode-varint bstr pos))
      (define field-num (arithmetic-shift tag -3))
      (define wire-type (bitwise-and tag #x07))
      (case wire-type
        [(0)
         (define-values (v pos2) (decode-varint bstr next-pos))
         (case field-num
           [(1)  (unless f-display-type (set! f-display-type v))]
           [(2)  (unless f-alliance (set! f-alliance v))]
           [(3)  (unless f-tag (set! f-tag v))]
           [(4)  (unless f-unit-type (set! f-unit-type v))]
           [(5)  (unless f-owner (set! f-owner v))]
           [(10) (unless f-cloak (set! f-cloak v))]
           [(11) (unless f-is-selected (set! f-is-selected v))]
           [(12) (unless f-is-on-screen (set! f-is-on-screen v))]
           [(13) (unless f-is-blip (set! f-is-blip v))]
           [(18) (unless f-mineral-contents (set! f-mineral-contents v))]
           [(19) (unless f-vespene-contents (set! f-vespene-contents v))]
           [(20) (unless f-is-flying (set! f-is-flying v))]
           [(21) (unless f-is-burrowed (set! f-is-burrowed v))]
           [(23) (unless f-add-on-tag (set! f-add-on-tag v))]
           [(25) (unless f-cargo-space-taken (set! f-cargo-space-taken v))]
           [(26) (unless f-cargo-space-max (set! f-cargo-space-max v))]
           [(27) (set! rev-buff-ids (cons v rev-buff-ids))]
           [(28) (unless f-assigned-harvesters (set! f-assigned-harvesters v))]
           [(29) (unless f-ideal-harvesters (set! f-ideal-harvesters v))]
           [(34) (unless f-engaged-target-tag (set! f-engaged-target-tag v))]
           [(35) (unless f-is-powered (set! f-is-powered v))]
           [(38) (unless f-is-hallucination (set! f-is-hallucination v))]
           [(39) (unless f-is-active (set! f-is-active v))]
           [(40) (unless f-attack-upgrade-level (set! f-attack-upgrade-level v))]
           [(41) (unless f-armor-upgrade-level (set! f-armor-upgrade-level v))]
           [(42) (unless f-shield-upgrade-level (set! f-shield-upgrade-level v))])
         (loop pos2)]
        [(2)
         (define-values (len pos-len) (decode-varint bstr next-pos))
         (define pos2 (+ pos-len len))
         (when (> pos2 end)
           (error 'decode-protobuf-message "Truncated length-delimited field ~a (len ~a)" field-num len))
         (case field-num
           [(6)
            (unless f-pos
              (set! f-pos (decode-point3d-bytes bstr pos-len pos2)))]
           [(22)
            (set! rev-orders (cons (decode-unit-order-bytes bstr pos-len pos2) rev-orders))]
           [(24)
            (set! rev-passengers (cons (decode-passenger-unit-bytes bstr pos-len pos2) rev-passengers))]
           [(27)
            (let p-loop ([p pos-len])
              (when (< p pos2)
                (define-values (bv next-p) (decode-varint bstr p))
                (set! rev-buff-ids (cons bv rev-buff-ids))
                (p-loop next-p)))])
         (loop pos2)]
        [(5)
         (define pos2 (+ next-pos 4))
         (when (> pos2 end)
           (error 'decode-protobuf-message "Truncated fixed32 field ~a" field-num))
         (case field-num
           [(7)  (unless f-facing (set! f-facing (decode-float32 bstr next-pos)))]
           [(8)  (unless f-radius (set! f-radius (decode-float32 bstr next-pos)))]
           [(9)  (unless f-build-progress (set! f-build-progress (decode-float32 bstr next-pos)))]
           [(14) (unless f-health (set! f-health (decode-float32 bstr next-pos)))]
           [(15) (unless f-health-max (set! f-health-max (decode-float32 bstr next-pos)))]
           [(16) (unless f-shield (set! f-shield (decode-float32 bstr next-pos)))]
           [(17) (unless f-energy (set! f-energy (decode-float32 bstr next-pos)))]
           [(30) (unless f-weapon-cooldown (set! f-weapon-cooldown (decode-float32 bstr next-pos)))]
           [(36) (unless f-shield-max (set! f-shield-max (decode-float32 bstr next-pos)))]
           [(37) (unless f-energy-max (set! f-energy-max (decode-float32 bstr next-pos)))])
         (loop pos2)]
        [else
         (loop (skip-protobuf-wire-value bstr wire-type next-pos end))])))
  (raw-sc2-unit
   (or f-display-type 1)
   (or f-alliance 1)
   (or f-tag 0)
   (or f-unit-type 0)
   (or f-owner 1)
   (or f-pos (sc2-point3d 0.0 0.0 0.0))
   (or f-facing 0.0)
   (or f-radius 0.5)
   (or f-build-progress 1.0)
   (or f-cloak 3)
   (if f-is-selected (not (zero? f-is-selected)) #f)
   (if f-is-on-screen (not (zero? f-is-on-screen)) #f)
   (if f-is-blip (not (zero? f-is-blip)) #f)
   (or f-health 1.0)
   (or f-health-max 1.0)
   (or f-shield 0.0)
   (or f-shield-max 0.0)
   (or f-energy 0.0)
   (or f-energy-max 0.0)
   (or f-mineral-contents 0)
   (or f-vespene-contents 0)
   (if f-is-flying (not (zero? f-is-flying)) #f)
   (if f-is-burrowed (not (zero? f-is-burrowed)) #f)
   (if f-is-hallucination (not (zero? f-is-hallucination)) #f)
   (if f-is-powered (not (zero? f-is-powered)) #t)
   (if f-is-active (not (zero? f-is-active)) #f)
   (if (null? rev-orders) '() (reverse rev-orders))
   (or f-add-on-tag 0)
   (if (null? rev-buff-ids) '() (reverse rev-buff-ids))
   (or f-assigned-harvesters 0)
   (or f-ideal-harvesters 0)
   (or f-weapon-cooldown 0.0)
   (or f-engaged-target-tag 0)
   (or f-attack-upgrade-level 0)
   (or f-armor-upgrade-level 0)
   (or f-shield-upgrade-level 0)
   (if (null? rev-passengers) '() (reverse rev-passengers))
   (or f-cargo-space-taken 0)
   (or f-cargo-space-max 0)))

(define (decode-effect-bytes bstr)
  (define fields (decode-protobuf-message bstr))
  (define eff-id (field-first-varint fields 1 0))
  (define positions (map decode-point2d-bytes (field-all-bytes fields 2)))
  (define alliance (field-first-varint fields 3 4))
  (define owner (field-first-varint fields 4 2))
  (define radius (field-first-float32 fields 5 1.5))
  (sc2-effect eff-id positions alliance owner radius))

(define (decode-power-source-bytes bstr)
  (define fields (decode-protobuf-message bstr))
  (define pos-b (field-first-bytes fields 1 #f))
  (sc2-power-source
   (if pos-b (decode-point3d-bytes pos-b) (sc2-point3d 0.0 0.0 0.0))
   (field-first-float32 fields 2 6.5)
   (field-first-varint fields 3 0)))

(define (decode-player-common-bytes bstr)
  (define fields (decode-protobuf-message bstr))
  (sc2-player-common
   (field-first-varint fields 1 1)
   (field-first-varint fields 2 50)
   (field-first-varint fields 3 0)
   (field-first-varint fields 4 15)
   (field-first-varint fields 5 12)
   (field-first-varint fields 6 0)
   (field-first-varint fields 7 12)
   (field-first-varint fields 8 0)
   (field-first-varint fields 9 0)
   (field-first-varint fields 10 0)
   (field-first-varint fields 11 0)))

(define (decode-response-observation-bytes bstr)
  (define resp-obs-fields (decode-protobuf-message bstr))
  (define player-results
    (for/list ([pr-b (in-list (field-all-bytes resp-obs-fields 4))])
      (define pr-f (decode-protobuf-message pr-b))
      (sc2-player-result (field-first-varint pr-f 1 1)
                         (result-enum->symbol (field-first-varint pr-f 2 4)))))
  (define action-errors
    (for/list ([ae-b (in-list (field-all-bytes resp-obs-fields 2))])
      (define ae-f (decode-protobuf-message ae-b))
      (hash 'unit-tag (field-first-varint ae-f 1 0)
            'ability-id (field-first-varint ae-f 2 0)
            'result (field-first-varint ae-f 3 0))))
  (define chat-msgs
    (for/list ([ch-b (in-list (field-all-bytes resp-obs-fields 5))])
      (define ch-f (decode-protobuf-message ch-b))
      (hash 'player-id (field-first-varint ch-f 1 0)
            'message (field-first-string ch-f 2 ""))))

  (define obs-b (field-first-bytes resp-obs-fields 3 #f))
  (if (not obs-b)
      (sc2-observation 0 (sc2-player-common 1 50 0 15 12 0 12 0 0 0 0)
                       '() '() '() (sc2-point3d 0.0 0.0 0.0) '() '()
                       player-results action-errors chat-msgs '())
      (let* ([obs-fields (decode-protobuf-message obs-b)]
             [game-loop (field-first-varint obs-fields 9 0)]
             [pc-b (field-first-bytes obs-fields 1 #f)]
             [pc (if pc-b
                     (decode-player-common-bytes pc-b)
                     (sc2-player-common 1 50 0 15 12 0 12 0 0 0 0))]
             [alerts (decode-packed-or-unpacked-varints obs-fields 10)]
             [raw-b (field-first-bytes obs-fields 5 #f)])
        (if (not raw-b)
            (sc2-observation game-loop pc '() '() '() (sc2-point3d 0.0 0.0 0.0)
                             '() '() player-results action-errors chat-msgs alerts)
            (let* ([raw-fields (decode-protobuf-message raw-b)]
                   [player-raw-b (field-first-bytes raw-fields 1 #f)]
                   [player-raw-fields (if player-raw-b (decode-protobuf-message player-raw-b) '())]
                   [power-sources (map decode-power-source-bytes (field-all-bytes player-raw-fields 1))]
                   [cam-b (field-first-bytes player-raw-fields 2 #f)]
                   [camera (if cam-b (decode-point3d-bytes cam-b) (sc2-point3d 0.0 0.0 0.0))]
                   [upgrade-ids (decode-packed-or-unpacked-varints player-raw-fields 3)]
                   [units (map decode-unit-bytes (field-all-bytes raw-fields 2))]
                   [map-state-b (field-first-bytes raw-fields 3 #f)]
                   [map-state-fields (if map-state-b (decode-protobuf-message map-state-b) '())]
                   [creep-grid (and map-state-b
                                    (decode-image-grid-bytes (field-first-bytes map-state-fields 2 #f)))]
                   [event-b (field-first-bytes raw-fields 4 #f)]
                   [event-fields (if event-b (decode-protobuf-message event-b) '())]
                   [dead-tags (decode-packed-or-unpacked-varints event-fields 1)]
                   [effects (map decode-effect-bytes (field-all-bytes raw-fields 5))]
                   [obs-res (sc2-observation game-loop pc units upgrade-ids power-sources camera
                                             dead-tags effects player-results action-errors chat-msgs alerts)])
              (when creep-grid
                (hash-set! SC2-OBS-CREEP-GRIDS obs-res creep-grid))
              obs-res)))))

(define SC2-OBS-CREEP-GRIDS (make-weak-hasheq))

(define (decode-image-grid-bytes bstr)
  (and (bytes? bstr)
       (> (bytes-length bstr) 0)
       (let* ([fields (decode-protobuf-message bstr)]
              [bpp (field-first-varint fields 1 0)]
              [sz-b (field-first-bytes fields 2 #f)]
              [sz-f (if sz-b (decode-protobuf-message sz-b) '())]
              [w (field-first-varint sz-f 1 0)]
              [h (field-first-varint sz-f 2 0)]
              [data (field-first-bytes fields 3 #"")])
         (and (> bpp 0)
              (> w 0)
              (> h 0)
              (> (bytes-length data) 0)
              (sc2-image-grid bpp w h data #f #f)))))

(define (sc2-grid-ref grid ix iy)
  (cond
    [(not (sc2-image-grid? grid)) 0]
    [else
     (define x (if (exact-integer? ix) ix (inexact->exact (floor ix))))
     (define y (if (exact-integer? iy) iy (inexact->exact (floor iy))))
     (define w (sc2-image-grid-width grid))
     (define h (sc2-image-grid-height grid))
     (cond
       [(or (< x 0) (< y 0) (>= x w) (>= y h)) 0]
       [else
        (define eff-y (if (sc2-image-grid-y-flip? grid) (- h 1 y) y))
        (define pidx (+ x (* eff-y w)))
        (define bpp (sc2-image-grid-bits-per-pixel grid))
        (define data (sc2-image-grid-data grid))
        (cond
          [(= bpp 8)
           (if (< pidx (bytes-length data))
               (bytes-ref data pidx)
               0)]
          [(= bpp 1)
           (define byte-idx (quotient pidx 8))
           (if (< byte-idx (bytes-length data))
               (let* ([rem (bitwise-and pidx 7)]
                      [bit-pos (if (sc2-image-grid-lsb-first? grid) rem (- 7 rem))])
                 (bitwise-and 1 (arithmetic-shift (bytes-ref data byte-idx) (- bit-pos))))
               0)]
          [else 0])])]))

(define (image-grid-pixel-set? grid px py)
  (> (sc2-grid-ref grid px py) 0))

(define (calibrate-image-grid-orientation! grid start-locs)
  (define (loc-xy sl)
    (cond
      [(sc2-point2d? sl) (values (sc2-point2d-x sl) (sc2-point2d-y sl))]
      [(sc2-point3d? sl) (values (sc2-point3d-x sl) (sc2-point3d-y sl))]
      [(pair? sl) (values (car sl) (cdr sl))]
      [else (values #f #f)]))
  (when (and (sc2-image-grid? grid) (pair? start-locs))
    (define bpp (sc2-image-grid-bits-per-pixel grid))
    (cond
      [(= bpp 1)
       (define best-yf (sc2-image-grid-y-flip? grid))
       (define best-lsb (sc2-image-grid-lsb-first? grid))
       (define best-score -1)
       (for* ([yf (in-list '(#f #t))]
              [lsb (in-list '(#f #t))])
         (set-sc2-image-grid-y-flip?! grid yf)
         (set-sc2-image-grid-lsb-first?! grid lsb)
         (define sc
           (for/sum ([sl (in-list start-locs)])
             (define-values (sx sy) (loc-xy sl))
             (if (and (real? sx) (real? sy))
                 (let ([cx (inexact->exact (floor sx))]
                       [cy (inexact->exact (floor sy))])
                   (for*/sum ([dx (in-range -2 3)]
                              [dy (in-range -2 3)])
                     (sc2-grid-ref grid (+ cx dx) (+ cy dy))))
                 0)))
         (when (> sc best-score)
           (set! best-score sc)
           (set! best-yf yf)
           (set! best-lsb lsb)))
       (set-sc2-image-grid-y-flip?! grid best-yf)
       (set-sc2-image-grid-lsb-first?! grid best-lsb)]
      [(= bpp 8)
       (define best-yf (sc2-image-grid-y-flip? grid))
       (define best-spread +inf.0)
       (for ([yf (in-list '(#f #t))])
         (set-sc2-image-grid-y-flip?! grid yf)
         (define spread
           (for/sum ([sl (in-list start-locs)])
             (define-values (sx sy) (loc-xy sl))
             (if (and (real? sx) (real? sy))
                 (let ([cx (inexact->exact (floor sx))]
                       [cy (inexact->exact (floor sy))]
                       [min-h 255]
                       [max-h 0])
                   (for* ([dx (in-range -2 3)]
                          [dy (in-range -2 3)])
                     (define hv (sc2-grid-ref grid (+ cx dx) (+ cy dy)))
                     (when (< hv min-h) (set! min-h hv))
                     (when (> hv max-h) (set! max-h hv)))
                   (- max-h min-h))
                 0)))
         (when (< spread best-spread)
           (set! best-spread spread)
           (set! best-yf yf)))
       (set-sc2-image-grid-y-flip?! grid best-yf)]))
  grid)

(define (decode-response-game-info-bytes bstr)
  (define fields (decode-protobuf-message bstr))
  (define map-name (field-first-string fields 1 "Simple64"))
  (define local-map-path (field-first-string fields 2 ""))
  (define player-info
    (for/list ([pi-b (in-list (field-all-bytes fields 3))])
      (define pi-f (decode-protobuf-message pi-b))
      (hash 'player-id (field-first-varint pi-f 1 1)
            'type (field-first-varint pi-f 2 1)
            'race-requested (sc2-enum->race (field-first-varint pi-f 3 4))
            'race-actual (sc2-enum->race (field-first-varint pi-f 4 2))
            'difficulty (field-first-varint pi-f 5 0)
            'player-name (field-first-string pi-f 6 ""))))
  (define start-raw-b (field-first-bytes fields 4 #f))
  (define start-raw-fields (if start-raw-b (decode-protobuf-message start-raw-b) '()))
  (define map-size-b (field-first-bytes start-raw-fields 1 #f))
  (define map-size
    (if map-size-b
        (let ([ms-f (decode-protobuf-message map-size-b)])
          (cons (field-first-varint ms-f 1 176)
                (field-first-varint ms-f 2 176)))
        (cons 176 176)))
  (define pathing-grid
    (decode-image-grid-bytes (field-first-bytes start-raw-fields 2 #f)))
  (define terrain-height
    (decode-image-grid-bytes (field-first-bytes start-raw-fields 3 #f)))
  (define placement-grid
    (decode-image-grid-bytes (field-first-bytes start-raw-fields 4 #f)))
  (define pa-b (field-first-bytes start-raw-fields 5 #f))
  (define playable-area
    (if pa-b
        (let* ([pa-f (decode-protobuf-message pa-b)]
               [p0-b (field-first-bytes pa-f 1 #f)]
               [p1-b (field-first-bytes pa-f 2 #f)]
               [p0-f (if p0-b (decode-protobuf-message p0-b) '())]
               [p1-f (if p1-b (decode-protobuf-message p1-b) '())])
          (hash 'x0 (field-first-varint p0-f 1 8)
                'y0 (field-first-varint p0-f 2 8)
                'x1 (field-first-varint p1-f 1 168)
                'y1 (field-first-varint p1-f 2 168)))
        (hash 'x0 8 'y0 8 'x1 168 'y1 168)))
  (define start-locs
    (map decode-point2d-bytes (field-all-bytes start-raw-fields 6)))
  (when placement-grid
    (calibrate-image-grid-orientation! placement-grid start-locs))
  (when pathing-grid
    (cond
      [placement-grid
       ;; StartRaw.start_locations are pre-placed 5x5 TownHall pads where placement_grid=1
       ;; AND pathing_grid=0. Copy calibrated orientation from placement_grid so pathing_grid
       ;; is never inverted by maximizing 1-bits on TownHall footprints.
       (set-sc2-image-grid-y-flip?! pathing-grid (sc2-image-grid-y-flip? placement-grid))
       (set-sc2-image-grid-lsb-first?! pathing-grid (sc2-image-grid-lsb-first? placement-grid))]
      [else
       (calibrate-image-grid-orientation! pathing-grid start-locs)]))
  (when terrain-height
    (if placement-grid
        (set-sc2-image-grid-y-flip?! terrain-height (sc2-image-grid-y-flip? placement-grid))
        (calibrate-image-grid-orientation! terrain-height start-locs)))
  (make-sc2-game-info map-name local-map-path player-info map-size playable-area start-locs
                      pathing-grid terrain-height placement-grid))

(define (decode-data-entries raw-bytes-list id-field name-field)
  (for/list ([b (in-list raw-bytes-list)])
    (define f (decode-protobuf-message b))
    (sc2-data-entry (field-first-varint f id-field 0)
                    (field-first-string f name-field ""))))

(define (decode-response-data-bytes bstr)
  (define fields (decode-protobuf-message bstr))
  ;; data.proto: AbilityData ability_id=1, link_name=2, friendly_name=5
  ;; UnitTypeData unit_id=1, name=2
  ;; UpgradeData upgrade_id=1, name=2
  ;; BuffData buff_id=1, name=2
  ;; EffectData effect_id=1, name=2, friendly_name=3
  (define abilities
    (for/list ([b (in-list (field-all-bytes fields 1))])
      (define f (decode-protobuf-message b))
      (define id (field-first-varint f 1 0))
      (define fname (field-first-string f 5 ""))
      (define lname (field-first-string f 2 ""))
      (sc2-data-entry id (if (string=? fname "") lname fname))))
  (define units (decode-data-entries (field-all-bytes fields 2) 1 2))
  (define upgrades (decode-data-entries (field-all-bytes fields 3) 1 2))
  (define buffs (decode-data-entries (field-all-bytes fields 4) 1 2))
  (define effects (decode-data-entries (field-all-bytes fields 5) 1 2))
  (sc2-data abilities units upgrades buffs effects))

(define (register-sc2-response-data! data)
  (when (sc2-data? data)
    (for ([e (in-list (sc2-data-units data))])
      (define id (sc2-data-entry-id e))
      (define name (sc2-data-entry-name e))
      (when (and (> id 0) (not (string=? name "")))
        (register-id-pair! SC2-UNIT-SYM->ID SC2-UNIT-ID->SYM
                           (normalize-sc2-name->symbol name) id #:primary? #f)))
    (for ([e (in-list (sc2-data-upgrades data))])
      (define id (sc2-data-entry-id e))
      (define name (sc2-data-entry-name e))
      (when (and (> id 0) (not (string=? name "")))
        (register-id-pair! SC2-UPGRADE-SYM->ID SC2-UPGRADE-ID->SYM
                           (normalize-sc2-name->symbol name) id #:primary? #f)))
    (for ([e (in-list (sc2-data-buffs data))])
      (define id (sc2-data-entry-id e))
      (define name (sc2-data-entry-name e))
      (when (and (> id 0) (not (string=? name "")))
        (register-id-pair! SC2-BUFF-SYM->ID SC2-BUFF-ID->SYM
                           (normalize-sc2-name->symbol name) id #:primary? #f)))
    (for ([e (in-list (sc2-data-effects data))])
      (define id (sc2-data-entry-id e))
      (define name (sc2-data-entry-name e))
      (when (and (> id 0) (not (string=? name "")))
        (register-id-pair! SC2-EFFECT-SYM->ID SC2-EFFECT-ID->SYM
                           (normalize-sc2-name->symbol name) id #:primary? #f)))
    (hash-clear! NORMALIZE-SYM-CACHE)
    (hash-clear! TRAIN-ABILITY-CACHE)
    (hash-clear! BUILD-ABILITY-CACHE)
    (hash-clear! RESEARCH-ABILITY-CACHE)
    (hash-clear! MORPH-ABILITY-CACHE)
    (hash-clear! SPELL-ABILITY-CACHE)))

(define (decode-sc2-response bstr)
  (define fields (decode-protobuf-message bstr))
  (define req-id (field-first-varint fields 97 #f))
  (define status (status-enum->symbol (field-first-varint fields 99 99)))
  (define errors
    (for/list ([eb (in-list (field-all-bytes fields 98))])
      (bytes->string/utf-8 eb #\?)))

  (define create-b (field-first-bytes fields 1 #f))
  (define create-game
    (and create-b
         (let ([cf (decode-protobuf-message create-b)])
           (hash 'error (field-first-varint cf 1 0)
                 'error-details (field-first-string cf 2 "")))))

  (define join-b (field-first-bytes fields 2 #f))
  (define join-game
    (and join-b
         (let ([jf (decode-protobuf-message join-b)])
           (hash 'player-id (field-first-varint jf 1 1)
                 'error (field-first-varint jf 2 0)
                 'error-details (field-first-string jf 3 "")))))

  (define leave-b (field-first-bytes fields 5 #f))
  (define quit-b (field-first-bytes fields 8 #f))

  (define gi-b (field-first-bytes fields 9 #f))
  (define game-info (and gi-b (decode-response-game-info-bytes gi-b)))

  (define obs-b (field-first-bytes fields 10 #f))
  (define observation (and obs-b (decode-response-observation-bytes obs-b)))

  (define act-b (field-first-bytes fields 11 #f))
  (define action-results
    (if act-b
        (decode-packed-or-unpacked-varints (decode-protobuf-message act-b) 1)
        '()))

  (define step-b (field-first-bytes fields 12 #f))
  (define step-sim-loop
    (and step-b
         (field-first-varint (decode-protobuf-message step-b) 1 0)))

  (define data-b (field-first-bytes fields 13 #f))
  (define data (and data-b (decode-response-data-bytes data-b)))

  (define query-b (field-first-bytes fields 14 #f))
  (define query-placements
    (if query-b
        (let* ([qf (decode-protobuf-message query-b)]
               [p-bytes (append (field-all-bytes qf 3) (field-all-bytes qf 2))])
          (for/list ([pb (in-list p-bytes)])
            (field-first-varint (decode-protobuf-message pb) 1 1)))
        '()))

  (define ping-b (field-first-bytes fields 19 #f))
  (define ping
    (and ping-b
         (let ([pf (decode-protobuf-message ping-b)])
           (hash 'game-version (field-first-string pf 1 "")
                 'data-version (field-first-string pf 2 "")
                 'data-build (field-first-varint pf 3 0)
                 'base-build (field-first-varint pf 4 0)))))

  (sc2-response req-id
                status
                errors
                create-game
                join-game
                (not (not leave-b))
                (not (not quit-b))
                game-info
                observation
                action-results
                step-sim-loop
                data
                query-placements
                ping))

;; =============================================================================
;; 6. Observation Converter (`sc2-observation` -> `bot-runtime.rkt` State)
;; =============================================================================

(define STRUCTURE-SYMS
  (list->seteq
   '(hatchery lair hive extractor extractor-rich spawning-pool evolution-chamber
     roach-warren baneling-nest hydralisk-den lurker-den lurker-den-mp spire greater-spire
     infestation-pit ultralisk-cavern nydus-network nydus-worm nydus-canal
     spine-crawler spine-crawler-uprooted spore-crawler spore-crawler-uprooted
     creep-tumor creep-tumor-burrowed creep-tumor-queen
     command-center command-center-flying orbital-command orbital-command-flying planetary-fortress
     supply-depot supply-depot-lowered refinery refinery-rich
     barracks barracks-flying factory factory-flying starport starport-flying
     engineering-bay armory bunker missile-turret sensor-tower ghost-academy fusion-core
     tech-lab techlab reactor
     barracks-tech-lab barracks-techlab barracks-reactor
     factory-tech-lab factory-techlab factory-reactor
     starport-tech-lab starport-techlab starport-reactor
     nexus pylon pylon-overcharged assimilator assimilator-rich gateway warp-gate warpgate
     forge cybernetics-core photon-cannon shield-battery twilight-council
     robotics-facility robotics-bay robotics-support-bay stargate templar-archive templar-archives
     dark-shrine fleet-beacon oracle-stasis-trap)))

(define TOWNHALL-SYMS
  (list->seteq
   '(hatchery lair hive
     command-center command-center-flying orbital-command orbital-command-flying planetary-fortress
     nexus)))

(define WORKER-SYMS (list->seteq '(drone drone-burrowed scv probe)))

(define MINERAL-FIELD-SYMS
  (list->seteq
   '(mineral-field mineral-field-750 mineral-field-450
     lab-mineral-field lab-mineral-field-750
     rich-mineral-field rich-mineral-field-750
     purifier-mineral-field purifier-mineral-field-750
     purifier-rich-mineral-field purifier-rich-mineral-field-750
     battle-station-mineral-field battle-station-mineral-field-750)))

(define VESPENE-GEYSER-SYMS
  (list->seteq
   '(vespene-geyser space-platform-geyser rich-vespene-geyser
     protoss-vespene-geyser purifier-vespene-geyser shakuras-vespene-geyser)))

(define GAS-BUILDING-SYMS
  (list->seteq
   '(extractor extractor-rich refinery refinery-rich assimilator assimilator-rich)))

(define PRODUCTION-FACILITY-SYMS
  (list->seteq
   '(barracks factory starport gateway warp-gate warpgate robotics-facility stargate)))

(define STRUCTURE-ID-SET (mutable-seteqv))
(define TOWNHALL-ID-SET (mutable-seteqv))
(define WORKER-ID-SET (mutable-seteqv))
(define MINERAL-FIELD-ID-SET (mutable-seteqv))
(define VESPENE-GEYSER-ID-SET (mutable-seteqv))
(define GAS-BUILDING-ID-SET (mutable-seteqv))
(define SC2-UNIT-ID-SETS-COUNT -1)

(define (ensure-unit-id-sets!)
  (define cur-cnt (hash-count SC2-UNIT-ID->SYM))
  (unless (= cur-cnt SC2-UNIT-ID-SETS-COUNT)
    (for ([s (in-list (list STRUCTURE-ID-SET TOWNHALL-ID-SET WORKER-ID-SET
                            MINERAL-FIELD-ID-SET VESPENE-GEYSER-ID-SET GAS-BUILDING-ID-SET))])
      (set-clear! s))
    (for ([(id sym) (in-hash SC2-UNIT-ID->SYM)])
      (when (set-member? STRUCTURE-SYMS sym) (set-add! STRUCTURE-ID-SET id))
      (when (set-member? TOWNHALL-SYMS sym) (set-add! TOWNHALL-ID-SET id))
      (when (set-member? WORKER-SYMS sym) (set-add! WORKER-ID-SET id))
      (when (set-member? MINERAL-FIELD-SYMS sym) (set-add! MINERAL-FIELD-ID-SET id))
      (when (set-member? VESPENE-GEYSER-SYMS sym) (set-add! VESPENE-GEYSER-ID-SET id))
      (when (set-member? GAS-BUILDING-SYMS sym) (set-add! GAS-BUILDING-ID-SET id)))
    (set! SC2-UNIT-ID-SETS-COUNT cur-cnt)))

(define (sc2-unit-is-structure? u)
  (if (symbol? u)
      (set-member? STRUCTURE-SYMS u)
      (begin (ensure-unit-id-sets!) (set-member? STRUCTURE-ID-SET (sc2-unit-unit-type u)))))

(define (sc2-unit-is-townhall? u)
  (if (symbol? u)
      (set-member? TOWNHALL-SYMS u)
      (begin (ensure-unit-id-sets!) (set-member? TOWNHALL-ID-SET (sc2-unit-unit-type u)))))

(define (sc2-unit-is-worker? u)
  (if (symbol? u)
      (set-member? WORKER-SYMS u)
      (begin (ensure-unit-id-sets!) (set-member? WORKER-ID-SET (sc2-unit-unit-type u)))))

(define (sc2-unit-is-mineral-field? u)
  (if (symbol? u)
      (set-member? MINERAL-FIELD-SYMS u)
      (begin (ensure-unit-id-sets!) (set-member? MINERAL-FIELD-ID-SET (sc2-unit-unit-type u)))))

(define (sc2-unit-is-vespene-geyser? u)
  (if (symbol? u)
      (set-member? VESPENE-GEYSER-SYMS u)
      (begin (ensure-unit-id-sets!) (set-member? VESPENE-GEYSER-ID-SET (sc2-unit-unit-type u)))))

(define (sc2-unit-is-gas-building? u)
  (if (symbol? u)
      (set-member? GAS-BUILDING-SYMS u)
      (begin (ensure-unit-id-sets!) (set-member? GAS-BUILDING-ID-SET (sc2-unit-unit-type u)))))

(define (pt-dist x1 y1 x2 y2)
  (sqrt (+ (sqr (- x2 x1)) (sqr (- y2 y1)))))

(define (detect-actual-race-from-units units game-info our-player-id configured-race)
  (define from-gi
    (and (sc2-game-info? game-info)
         (for/first ([pi (in-list (sc2-game-info-player-info game-info))]
                     #:when (= (hash-ref pi 'player-id 0) our-player-id))
           (hash-ref pi 'race-actual #f))))
  (cond
    [(and from-gi (not (eq? from-gi 'Random))) from-gi]
    [else
     (define my-syms
      (for/list ([u (in-list units)]
                 #:when (and (= (sc2-unit-alliance u) 1)
                             (not (= (sc2-unit-display-type u) 4))))
        (sc2-id->unit-symbol (sc2-unit-unit-type u))))
     (cond
       [(ormap (lambda (s) (memq s '(hatchery lair hive drone overlord larva))) my-syms) 'Zerg]
       [(ormap (lambda (s) (memq s '(command-center orbital-command planetary-fortress scv marine))) my-syms) 'Terran]
       [(ormap (lambda (s) (memq s '(nexus probe pylon gateway))) my-syms) 'Protoss]
       [(memq configured-race '(Zerg Terran Protoss)) configured-race]
       [else 'Zerg])]))

(define (any-point? pt)
  (or (sc2-point2d? pt)
      (sc2-point3d? pt)
      (and (pair? pt) (real? (car pt)) (real? (if (pair? (cdr pt)) (cadr pt) (cdr pt))))))

(define (any-point-x pt)
  (cond
    [(sc2-point2d? pt) (sc2-point2d-x pt)]
    [(sc2-point3d? pt) (sc2-point3d-x pt)]
    [(pair? pt) (exact->inexact (car pt))]
    [else 0.0]))

(define (any-point-y pt)
  (cond
    [(sc2-point2d? pt) (sc2-point2d-y pt)]
    [(sc2-point3d? pt) (sc2-point3d-y pt)]
    [(and (pair? pt) (pair? (cdr pt))) (exact->inexact (cadr pt))]
    [(pair? pt) (exact->inexact (cdr pt))]
    [else 0.0]))

;; Exact SC2 5x5 TownHall resource exclusion octagon (`Footprint5x5ResourceDropOff`):
;; Orthogonal standoff >= 3.0 tiles OR 45-degree beveled corner (dx >= 1.0, dy >= 1.0, dx + dy >= 4.0).
(define (sc2-townhall-resource-legal? cx cy rx ry [hw-x 1.0] [hw-y 0.5])
  (define raw-dx (- (abs (- cx rx)) (+ 2.5 hw-x)))
  (define raw-dy (- (abs (- cy ry)) (+ 2.5 hw-y)))
  (and (not (and (< raw-dx -1e-4) (< raw-dy -1e-4)))
       (let ([dx (max 0.0 raw-dx)]
             [dy (max 0.0 raw-dy)])
         (or (>= dx (- 3.0 1e-4))
             (>= dy (- 3.0 1e-4))
             (and (>= dx (- 1.0 1e-4))
                  (>= dy (- 1.0 1e-4))
                  (>= (+ dx dy) (- 4.0 1e-4)))))))

(define (resource-item-xy-dims r)
  (cond
    [(sc2-unit? r)
     (define p (sc2-unit-pos r))
     (if (sc2-unit-is-vespene-geyser? r)
         (values (sc2-point3d-x p) (sc2-point3d-y p) 1.5 1.5 #t)
         (values (sc2-point3d-x p) (sc2-point3d-y p) 1.0 0.5 #f))]
    [(hash? r)
     (define rx (exact->inexact (hash-ref r 'x 0.0)))
     (define ry (exact->inexact (hash-ref r 'y 0.0)))
     (define rtype (hash-ref r 'type 'mineral-field))
     (define geyser?
       (or (set-member? VESPENE-GEYSER-SYMS rtype)
           (eq? rtype 'geyser)))
     (if geyser?
         (values rx ry 1.5 1.5 #t)
         (values rx ry 1.0 0.5 #f))]
    [(any-point? r)
     (values (any-point-x r) (any-point-y r) 1.0 0.5 #f)]
    [else
     (values 0.0 0.0 1.0 0.5 #f)]))

(define (sc2-townhall-all-resources-legal? cx cy res-items)
  (for/and ([r (in-list (if (list? res-items) res-items '()))])
    (define-values (rx ry hw-x hw-y _g?) (resource-item-xy-dims r))
    (or (>= (abs (- cx rx)) 7.1)
        (>= (abs (- cy ry)) 7.1)
        (sc2-townhall-resource-legal? cx cy rx ry hw-x hw-y))))

(define SC2-IMAGE-GRID-SIG-MEMO (make-weak-hasheq))

(define (image-grid-signature grid)
  (and (sc2-image-grid? grid)
       (or (hash-ref SC2-IMAGE-GRID-SIG-MEMO grid #f)
           (let* ([bs (sc2-image-grid-data grid)]
                  [blen (if (bytes? bs) (bytes-length bs) 0)]
                  [stride (max 1 (quotient blen 32))]
                  [bhash
                   (if (<= blen 0)
                       0
                       (for/fold ([h blen])
                                 ([i (in-range 0 blen stride)])
                         (bitwise-and #x3fffffff
                                      (+ (* h 131) (bytes-ref bs i) i))))]
                  [sig
                   (list (sc2-image-grid-width grid)
                         (sc2-image-grid-height grid)
                         (sc2-image-grid-bits-per-pixel grid)
                         (sc2-image-grid-y-flip? grid)
                         (sc2-image-grid-lsb-first? grid)
                         blen
                         bhash)])
             (hash-set! SC2-IMAGE-GRID-SIG-MEMO grid sig)
             sig))))

(define (solve-exact-townhall-pad minerals-or-resources
                                  [geysers-or-placement '()]
                                  [opt-placement-or-height #f]
                                  [opt-height #f]
                                  #:all-resources [kw-all-resources #f]
                                  #:placement-grid [kw-placement-grid #f]
                                  #:terrain-height [kw-terrain-height #f])
  (define-values (comp-mins comp-geysers placement-grid terrain-height)
    (if (or (sc2-image-grid? geysers-or-placement) (eq? geysers-or-placement #f))
        (let-values ([(gs ms)
                      (partition (lambda (r)
                                   (define-values (_x _y _hx _hy g?) (resource-item-xy-dims r))
                                   g?)
                                 (if (list? minerals-or-resources) minerals-or-resources '()))])
          (values ms gs
                  (or kw-placement-grid geysers-or-placement)
                  (or kw-terrain-height opt-placement-or-height)))
        (values (if (list? minerals-or-resources) minerals-or-resources '())
                (if (list? geysers-or-placement) geysers-or-placement '())
                (or kw-placement-grid opt-placement-or-height)
                (or kw-terrain-height opt-height))))
  (define comp-all (append comp-mins comp-geysers))
  (cond
    [(null? comp-all) #f]
    [else
     (define all-res (or kw-all-resources comp-all))
     (define n-comp (exact->inexact (length comp-all)))
     (define rcx
       (/ (for/sum ([r (in-list comp-all)])
            (define-values (rx _ry _hx _hy _g?) (resource-item-xy-dims r))
            rx)
          n-comp))
     (define rcy
       (/ (for/sum ([r (in-list comp-all)])
            (define-values (_rx ry _hx _hy _g?) (resource-item-xy-dims r))
            ry)
          n-comp))
     (define local-res
       (filter (lambda (r)
                 (define-values (rx ry _hx _hy _g?) (resource-item-xy-dims r))
                 (<= (pt-dist rcx rcy rx ry) 18.0))
               all-res))
     (define res-heights
       (if (sc2-image-grid? terrain-height)
           (for/list ([r (in-list comp-all)])
             (define-values (rx ry _hx _hy _g?) (resource-item-xy-dims r))
             (sc2-grid-ref terrain-height (inexact->exact (floor rx)) (inexact->exact (floor ry))))
           '()))
     (define base-ix (inexact->exact (floor rcx)))
     (define base-iy (inexact->exact (floor rcy)))
     (define best-pt #f)
     (define best-score +inf.0)
     (for* ([dx (in-range -11 12)]
            [dy (in-range -11 12)])
       (define ix (+ base-ix dx))
       (define iy (+ base-iy dy))
       (define cx (+ (exact->inexact ix) 0.5))
       (define cy (+ (exact->inexact iy) 0.5))
       (define bounds-ok?
         (if (sc2-image-grid? placement-grid)
             (and (>= (- ix 2) 0)
                  (>= (- iy 2) 0)
                  (< (+ ix 2) (sc2-image-grid-width placement-grid))
                  (< (+ iy 2) (sc2-image-grid-height placement-grid)))
             (and (>= cx SC2-MAP-PLAYABLE-MIN-COORD) (<= cx SC2-MAP-PLAYABLE-MAX-COORD)
                  (>= cy SC2-MAP-PLAYABLE-MIN-COORD) (<= cy SC2-MAP-PLAYABLE-MAX-COORD))))
       (when bounds-ok?
         (define placement-ok?
           (or (not (sc2-image-grid? placement-grid))
               (for*/and ([ox (in-range -2 3)]
                          [oy (in-range -2 3)])
                 (= (sc2-grid-ref placement-grid (+ ix ox) (+ iy oy)) 1))))
         (when placement-ok?
           (define height-ok?
             (or (not (sc2-image-grid? terrain-height))
                 (let ([min-h 255]
                       [max-h 0]
                       [pad-h (sc2-grid-ref terrain-height ix iy)])
                   (for* ([ox (in-range -2 3)]
                          [oy (in-range -2 3)])
                     (define hv (sc2-grid-ref terrain-height (+ ix ox) (+ iy oy)))
                     (when (< hv min-h) (set! min-h hv))
                     (when (> hv max-h) (set! max-h hv)))
                   (and (<= (- max-h min-h) 2)
                        (or (null? res-heights)
                            (ormap (lambda (rh) (<= (abs (- pad-h rh)) 6)) res-heights))))))
           (when height-ok?
             (define res-legal?
               (sc2-townhall-all-resources-legal? cx cy local-res))
             (when res-legal?
               (define sum-min-d
                 (for/sum ([m (in-list comp-mins)])
                   (define-values (mx my _hx _hy _g?) (resource-item-xy-dims m))
                   (pt-dist cx cy mx my)))
               (define sum-gey-d
                 (for/sum ([g (in-list comp-geysers)])
                   (define-values (gx gy _hx _hy _g?) (resource-item-xy-dims g))
                   (pt-dist cx cy gx gy)))
               (define avg-d (/ (+ sum-min-d sum-gey-d) n-comp))
               (when (<= avg-d 9.5)
                 (define score (+ sum-min-d (* 1.25 sum-gey-d)))
                 (when (< score best-score)
                   (set! best-score score)
                   (set! best-pt (sc2-point2d cx cy)))))))))
     best-pt]))

(struct sc2-ground-bfs
  (width height dists)
  #:transparent
  #:property prop:procedure
  (case-lambda
    [(self tx ty)
     (define w (sc2-ground-bfs-width self))
     (define h (sc2-ground-bfs-height self))
     (define ix (if (exact-integer? tx) tx (inexact->exact (floor tx))))
     (define iy (if (exact-integer? ty) ty (inexact->exact (floor ty))))
     (if (or (< ix 0) (< iy 0) (>= ix w) (>= iy h))
         +inf.0
         (let ([d0 (vector-ref (sc2-ground-bfs-dists self) (+ ix (* iy w)))])
           (if (< d0 999999999) (/ (exact->inexact d0) 10.0) +inf.0)))]
    [(self tx ty ring-r)
     (define w (sc2-ground-bfs-width self))
     (define h (sc2-ground-bfs-height self))
     (define dists (sc2-ground-bfs-dists self))
     (define ix (if (exact-integer? tx) tx (inexact->exact (floor tx))))
     (define iy (if (exact-integer? ty) ty (inexact->exact (floor ty))))
     (define INF 999999999)
     (cond
       [(or (< ix 0) (< iy 0) (>= ix w) (>= iy h)) +inf.0]
       [else
        (define d0 (vector-ref dists (+ ix (* iy w))))
        (cond
          [(< d0 INF) (/ (exact->inexact d0) 10.0)]
          [(<= ring-r 0) +inf.0]
          [else
           (define best INF)
           (for* ([ox (in-range (- ring-r) (add1 ring-r))]
                  [oy (in-range (- ring-r) (add1 ring-r))])
             (define nx (+ ix ox))
             (define ny (+ iy oy))
             (when (and (>= nx 0) (>= ny 0) (< nx w) (< ny h))
               (define dv (vector-ref dists (+ nx (* ny w))))
               (when (< dv best)
                 (set! best dv))))
           (if (< best INF) (/ (exact->inexact best) 10.0) +inf.0)])])]))

(define SC2-PATHING-WALK-CACHE (make-hash))
(define SC2-GROUND-BFS-CACHE (make-hash))

(define (neutral-unit-is-pathing-blocker? u)
  (cond
    [(sc2-unit-is-mineral-field? u) #t]
    [(sc2-unit-is-vespene-geyser? u) #t]
    [else
     (define sym (sc2-id->unit-symbol (sc2-unit-unit-type u) 'unknown))
     (define s (symbol->string sym))
     (and (or (string-contains? s "destructible")
              (string-contains? s "rock")
              (string-contains? s "debris")
              (string-contains? s "mineral-wall"))
          (not (string-contains? s "unbuildable"))
          (not (string-contains? s "plate"))
          (not (string-contains? s "brick"))
          (not (string-contains? s "tower")))]))

(define (compute-ground-bfs-distances pathing-grid home-x home-y [neutral-units '()])
  (cond
    [(not (sc2-image-grid? pathing-grid)) #f]
    [else
     (define w (sc2-image-grid-width pathing-grid))
     (define h (sc2-image-grid-height pathing-grid))
     (define hix (max 0 (min (sub1 w) (if (exact-integer? home-x) home-x (inexact->exact (floor home-x))))))
     (define hiy (max 0 (min (sub1 h) (if (exact-integer? home-y) home-y (inexact->exact (floor home-y))))))
     (define grid-sig (image-grid-signature pathing-grid))
     ;; Hash blocker footprints by quantized map coordinates + kind (NOT ephemeral fogged snapshot unit tags!)
     (define seen-blocker-cells (mutable-seteqv))
     (define blocker-sig
       (for/fold ([acc 0])
                 ([u (in-list neutral-units)]
                  #:when (and (sc2-unit? u) (neutral-unit-is-pathing-blocker? u)))
         (define p (sc2-unit-pos u))
         (define ux (sc2-point3d-x p))
         (define uy (sc2-point3d-y p))
         (define cell-k
           (cond
             [(sc2-unit-is-mineral-field? u)
              (+ 1 (* 16 (+ (inexact->exact (round (* 2.0 ux)))
                            (* 4096 (inexact->exact (floor uy))))))]
             [(sc2-unit-is-vespene-geyser? u)
              (+ 2 (* 16 (+ (inexact->exact (floor ux))
                            (* 4096 (inexact->exact (floor uy))))))]
             [else
              (define rad (max 1 (min 4 (inexact->exact (floor (max 1.0 (sc2-unit-radius u)))))))
              (+ 4 rad (* 16 (+ (inexact->exact (floor ux))
                                (* 4096 (inexact->exact (floor uy))))))]))
         (if (set-member? seen-blocker-cells cell-k)
             acc
             (begin
               (set-add! seen-blocker-cells cell-k)
               (bitwise-xor acc (bitwise-and #x3fffffff (* cell-k 26544357)) (set-count seen-blocker-cells))))))
     (define cache-key (list grid-sig hix hiy blocker-sig))
     (cond
       [(hash-ref SC2-GROUND-BFS-CACHE cache-key #f) => values]
       [else
        (when (> (hash-count SC2-GROUND-BFS-CACHE) 32)
          (hash-clear! SC2-GROUND-BFS-CACHE))
        (define n (* w h))
        (define base-walk
          (cond
            [(hash-ref SC2-PATHING-WALK-CACHE grid-sig #f) => values]
            [else
             (when (> (hash-count SC2-PATHING-WALK-CACHE) 8)
               (hash-clear! SC2-PATHING-WALK-CACHE))
             (define bw (make-bytes n 0))
             (for* ([y (in-range h)]
                    [x (in-range w)])
               (bytes-set! bw (+ x (* y w)) (sc2-grid-ref pathing-grid x y)))
             (hash-set! SC2-PATHING-WALK-CACHE grid-sig bw)
             bw]))
        (define walk (bytes-copy base-walk))
        ;; Stamp alive neutral minerals (2x1), geysers (3x3), and destructible rock blockers
        (for ([u (in-list neutral-units)]
              #:when (and (sc2-unit? u) (neutral-unit-is-pathing-blocker? u)))
          (define p (sc2-unit-pos u))
          (define ux (sc2-point3d-x p))
          (define uy (sc2-point3d-y p))
          (cond
            [(sc2-unit-is-mineral-field? u)
             (define my (inexact->exact (floor uy)))
             (define mx0 (inexact->exact (floor (- ux 0.5))))
             (define mx1 (inexact->exact (floor (+ ux 0.5))))
             (when (and (>= my 0) (< my h))
               (when (and (>= mx0 0) (< mx0 w)) (bytes-set! walk (+ mx0 (* my w)) 0))
               (when (and (>= mx1 0) (< mx1 w)) (bytes-set! walk (+ mx1 (* my w)) 0)))]
            [(sc2-unit-is-vespene-geyser? u)
             (define gx (inexact->exact (floor ux)))
             (define gy (inexact->exact (floor uy)))
             (for* ([ox (in-range -1 2)]
                    [oy (in-range -1 2)])
               (define nx (+ gx ox))
               (define ny (+ gy oy))
               (when (and (>= nx 0) (>= ny 0) (< nx w) (< ny h))
                 (bytes-set! walk (+ nx (* ny w)) 0)))]
            [else
             (define rx (inexact->exact (floor ux)))
             (define ry (inexact->exact (floor uy)))
             (define rad (max 1 (min 4 (inexact->exact (floor (max 1.0 (sc2-unit-radius u)))))))
             (for* ([ox (in-range (- rad) (add1 rad))]
                    [oy (in-range (- rad) (add1 rad))])
               (define nx (+ rx ox))
               (define ny (+ ry oy))
               (when (and (>= nx 0) (>= ny 0) (< nx w) (< ny h))
                 (bytes-set! walk (+ nx (* ny w)) 0)))]))
        ;; Ensure 5x5 friendly main TownHall pad (where StartRaw.pathing_grid=0) is unblocked so BFS escapes
        (for* ([ox (in-range -2 3)]
               [oy (in-range -2 3)])
          (define nx (+ hix ox))
          (define ny (+ hiy oy))
          (when (and (>= nx 0) (>= ny 0) (< nx w) (< ny h))
            (bytes-set! walk (+ nx (* ny w)) 1)))
        (define INF 999999999)
        (define dists (make-vector n INF))
        (define buckets (make-vector 64 '()))
        (define start-idx (+ hix (* hiy w)))
        (vector-set! dists start-idx 0)
        (vector-set! buckets 0 (list start-idx))
        (define remaining 1)
        (define cur-d 0)
        (let dial-loop ()
          (when (> remaining 0)
            (define bidx (bitwise-and cur-d 63))
            (define cell-list (vector-ref buckets bidx))
            (cond
              [(null? cell-list)
               (set! cur-d (add1 cur-d))
               (dial-loop)]
              [else
               (define u-idx (car cell-list))
               (vector-set! buckets bidx (cdr cell-list))
               (set! remaining (sub1 remaining))
               (when (= (vector-ref dists u-idx) cur-d)
                 (define ux (remainder u-idx w))
                 (define uy (quotient u-idx w))
                 (define (relax! nx ny step-cost)
                   (define n-idx (+ nx (* ny w)))
                   (when (= (bytes-ref walk n-idx) 1)
                     (define nd (+ cur-d step-cost))
                     (when (< nd (vector-ref dists n-idx))
                       (vector-set! dists n-idx nd)
                       (define nb (bitwise-and nd 63))
                       (vector-set! buckets nb (cons n-idx (vector-ref buckets nb)))
                       (set! remaining (add1 remaining)))))
                 ;; 4 orthogonal neighbors (+10)
                 (define e-ok? (and (< (add1 ux) w) (= (bytes-ref walk (+ (add1 ux) (* uy w))) 1)))
                 (define w-ok? (and (> ux 0) (= (bytes-ref walk (+ (sub1 ux) (* uy w))) 1)))
                 (define n-ok? (and (< (add1 uy) h) (= (bytes-ref walk (+ ux (* (add1 uy) w))) 1)))
                 (define s-ok? (and (> uy 0) (= (bytes-ref walk (+ ux (* (sub1 uy) w))) 1)))
                 (when e-ok? (relax! (add1 ux) uy 10))
                 (when w-ok? (relax! (sub1 ux) uy 10))
                 (when n-ok? (relax! ux (add1 uy) 10))
                 (when s-ok? (relax! ux (sub1 uy) 10))
                 ;; 4 diagonal neighbors (+14) strictly without corner cutting
                 (when (and e-ok? n-ok?) (relax! (add1 ux) (add1 uy) 14))
                 (when (and e-ok? s-ok?) (relax! (add1 ux) (sub1 uy) 14))
                 (when (and w-ok? n-ok?) (relax! (sub1 ux) (add1 uy) 14))
                 (when (and w-ok? s-ok?) (relax! (sub1 ux) (sub1 uy) 14)))
               (dial-loop)])))
        (define bfs-obj (sc2-ground-bfs w h dists))
        (hash-set! SC2-GROUND-BFS-CACHE cache-key bfs-obj)
        bfs-obj])]))

;; Bounded per-map canonical expansion pad cache:
;; Canonical 5x5 TownHall pad coordinates `(exact-x, exact-y)` never move during a match;
;; only each base's live mineral/geyser lists change as patches mine out.
(define SC2-EXPANSION-BASES-CACHE (make-hash))
(define SC2-LAST-SOLVED-EXP-BASES-BOX (box #f))

(define (resource-unit-cell-key u kind-code)
  (define p (sc2-unit-pos u))
  (+ kind-code
     (* 8 (+ (inexact->exact (round (* 2.0 (sc2-point3d-x p))))
             (* 4096 (inexact->exact (round (* 2.0 (sc2-point3d-y p)))))))))

(define (build-resource-pad-index pad-vec base-minerals geysers)
  (define n-pads (vector-length pad-vec))
  (define cell->pad-idx (make-hasheqv))
  (for ([m (in-list base-minerals)])
    (define mp (sc2-unit-pos m))
    (define mx (sc2-point3d-x mp))
    (define my (sc2-point3d-y mp))
    (define best-i #f)
    (define best-d 11.5)
    (for ([i (in-range n-pads)])
      (define pad (vector-ref pad-vec i))
      (define d (pt-dist mx my (sc2-point2d-x pad) (sc2-point2d-y pad)))
      (when (<= d best-d)
        (set! best-d d)
        (set! best-i i)))
    (hash-set! cell->pad-idx (resource-unit-cell-key m 1) (or best-i 'unattached)))
  (for ([g (in-list geysers)])
    (define gp (sc2-unit-pos g))
    (define gx (sc2-point3d-x gp))
    (define gy (sc2-point3d-y gp))
    (define best-i #f)
    (define best-d 12.0)
    (for ([i (in-range n-pads)])
      (define pad (vector-ref pad-vec i))
      (define d (pt-dist gx gy (sc2-point2d-x pad) (sc2-point2d-y pad)))
      (when (<= d best-d)
        (set! best-d d)
        (set! best-i i)))
    (hash-set! cell->pad-idx (resource-unit-cell-key g 2) (or best-i 'unattached)))
  cell->pad-idx)

(define (refresh-cached-expansion-bases cached-pads base-minerals geysers [cell->pad-idx #f])
  (define pad-vec
    (if (vector? cached-pads)
        cached-pads
        (list->vector cached-pads)))
  (define n-pads (vector-length pad-vec))
  (cond
    [(zero? n-pads) '()]
    [else
     (define idx-map
       (or cell->pad-idx
           (build-resource-pad-index pad-vec base-minerals geysers)))
     (define mins-vec (make-vector n-pads '()))
     (define geys-vec (make-vector n-pads '()))
     (define valid?
       (and (for/and ([m (in-list base-minerals)])
              (define v (hash-ref idx-map (resource-unit-cell-key m 1) #f))
              (cond
                [(not v) #f]
                [else
                 (when (exact-nonnegative-integer? v)
                   (vector-set! mins-vec v (cons m (vector-ref mins-vec v))))
                 #t]))
            (for/and ([g (in-list geysers)])
              (define v (hash-ref idx-map (resource-unit-cell-key g 2) #f))
              (cond
                [(not v) #f]
                [else
                 (when (exact-nonnegative-integer? v)
                   (vector-set! geys-vec v (cons g (vector-ref geys-vec v))))
                 #t]))))
     (and valid?
          (for/list ([i (in-range n-pads)]
                     #:when (let ([ms (vector-ref mins-vec i)]
                                  [gs (vector-ref geys-vec i)])
                              (or (>= (length ms) 4)
                                  (and (pair? ms) (>= (length gs) 1))
                                  (>= (length gs) 2))))
            (define pad (vector-ref pad-vec i))
            (hash 'pad pad
                  'x (sc2-point2d-x pad)
                  'y (sc2-point2d-y pad)
                  'minerals (reverse (vector-ref mins-vec i))
                  'geysers (reverse (vector-ref geys-vec i)))))]))

;; Connected-component resource clustering + exact 5x5 TownHall pad solver:
;; Filters mineral-wall blockers (`mineral-field-450`, `lab-mineral-field*`) and nubs (< 150 minerals),
;; builds transitive mineral components (center dist <= 5.2), attaches each geyser within 10.5 tiles
;; to its single nearest mineral component, and solves the exact 5x5 TownHall pad for each base.
;; Memoizes solved canonical pads per map (keyed by StartRaw grid signature + fallback synthetic
;; resource signature when `game-info = #f`) and refreshes live mineral/geyser counts in O(resources).
(define (solve-all-map-expansion-bases neutral-units [game-info #f])
  (define (base-mineral-eligible? u)
    (and (sc2-unit-is-mineral-field? u)
         (not (memq (sc2-id->unit-symbol (sc2-unit-unit-type u))
                    '(mineral-field-450 lab-mineral-field lab-mineral-field-750)))
         (let ([mc (sc2-unit-mineral-contents u)])
           (or (= mc 0) (>= mc 150)))))
  (define base-minerals-rev '())
  (define geysers-rev '())
  (define all-blocking-res-rev '())
  (define res-cnt 0)
  (define res-xor 0)
  (define res-sum 0)
  (for ([u (in-list neutral-units)])
    (define min? (sc2-unit-is-mineral-field? u))
    (define gey? (and (not min?) (sc2-unit-is-vespene-geyser? u)))
    (when (or min? gey?)
      (set! all-blocking-res-rev (cons u all-blocking-res-rev))
      (define mc (sc2-unit-mineral-contents u))
      (define vc (sc2-unit-vespene-contents u))
      (define p (sc2-unit-pos u))
      (define h-item
        (bitwise-and
         #x3fffffff
         (+ (* (bitwise-and #xfffff (sc2-unit-tag u)) 26544357)
            (* (sc2-unit-unit-type u) 4099)
            (* mc 131)
            (* vc 257)
            (* (inexact->exact (round (* 2.0 (sc2-point3d-x p)))) 521)
            (* (inexact->exact (round (* 2.0 (sc2-point3d-y p)))) 1031))))
      (set! res-cnt (add1 res-cnt))
      (set! res-xor (bitwise-xor res-xor h-item))
      (set! res-sum (bitwise-and #x3fffffff (+ res-sum h-item)))
      (cond
        [(and min? (base-mineral-eligible? u))
         (set! base-minerals-rev (cons u base-minerals-rev))]
        [gey?
         (set! geysers-rev (cons u geysers-rev))])))
  (define base-minerals (reverse base-minerals-rev))
  (define geysers (reverse geysers-rev))
  (cond
    [(and (null? base-minerals) (null? geysers)) '()]
    [else
     (define pl-grid (and (sc2-game-info? game-info) (sc2-game-info-placement-grid game-info)))
     (define path-grid (and (sc2-game-info? game-info) (sc2-game-info-pathing-grid game-info)))
     (define th-grid (and (sc2-game-info? game-info) (sc2-game-info-terrain-height game-info)))
     (define static-grid-key
       (and (or (sc2-image-grid? pl-grid)
                (sc2-image-grid? path-grid)
                (sc2-image-grid? th-grid))
            (list 'start-raw-grids
                  (if (sc2-game-info? game-info) (sc2-game-info-map-name game-info) #f)
                  (image-grid-signature pl-grid)
                  (image-grid-signature path-grid)
                  (image-grid-signature th-grid))))
     (define fallback-res-key
       (and (not static-grid-key)
            (let ([seen (mutable-seteqv)])
              (define-values (xor-h sum-h)
                (for/fold ([xh 0] [sh 0])
                          ([u (in-list all-blocking-res-rev)])
                  (define k
                    (resource-unit-cell-key
                     u
                     (cond
                       [(sc2-unit-is-vespene-geyser? u) 2]
                       [(base-mineral-eligible? u) 1]
                       [else 3])))
                  (if (set-member? seen k)
                      (values xh sh)
                      (begin
                        (set-add! seen k)
                        (values (bitwise-xor xh (bitwise-and #x3fffffff (* k 26544357)))
                                (bitwise-and #x3fffffff (+ sh k)))))))
              (list 'synthetic-res (set-count seen) xor-h sum-h))))
     (define cache-key (or static-grid-key fallback-res-key))
     (define full-sig (and cache-key (list cache-key res-cnt res-xor res-sum)))
     (define last-solved (unbox SC2-LAST-SOLVED-EXP-BASES-BOX))
     (cond
       [(and full-sig last-solved (equal? (car last-solved) full-sig))
        (cdr last-solved)]
       [else
        (define cached-entry (and cache-key (hash-ref SC2-EXPANSION-BASES-CACHE cache-key #f)))
        (define refreshed
          (and cached-entry
               (refresh-cached-expansion-bases (vector-ref cached-entry 0)
                                               base-minerals
                                               geysers
                                               (vector-ref cached-entry 1))))
        (define result
          (cond
            [refreshed refreshed]
            [else
             (define all-blocking-res (reverse all-blocking-res-rev))
             (define visited (mutable-seteqv))
             (define raw-min-comps '())
             (for ([m0 (in-list base-minerals)]
                   #:when (not (set-member? visited (sc2-unit-tag m0))))
               (set-add! visited (sc2-unit-tag m0))
               (define comp
                 (let bfs ([queue (list m0)]
                           [acc (list m0)])
                   (if (null? queue)
                       acc
                       (let* ([cur (car queue)]
                              [cp (sc2-unit-pos cur)]
                              [cx (sc2-point3d-x cp)]
                              [cy (sc2-point3d-y cp)]
                              [nbrs (filter (lambda (m)
                                              (and (not (set-member? visited (sc2-unit-tag m)))
                                                   (let ([mp (sc2-unit-pos m)])
                                                     (<= (pt-dist cx cy (sc2-point3d-x mp) (sc2-point3d-y mp))
                                                         5.2))))
                                            base-minerals)])
                         (for ([nb (in-list nbrs)])
                           (set-add! visited (sc2-unit-tag nb)))
                         (bfs (append (cdr queue) nbrs) (append nbrs acc))))))
               (set! raw-min-comps (cons comp raw-min-comps)))
             (define min-comps (reverse raw-min-comps))
             (define comp-geysers-vec (make-vector (length min-comps) '()))
             (for ([g (in-list geysers)])
               (define gp (sc2-unit-pos g))
               (define gx (sc2-point3d-x gp))
               (define gy (sc2-point3d-y gp))
               (define best-idx #f)
               (define best-d 12.5)
               (for ([comp (in-list min-comps)]
                     [idx (in-naturals 0)])
                 (for ([m (in-list comp)])
                   (define mp (sc2-unit-pos m))
                   (define d (pt-dist gx gy (sc2-point3d-x mp) (sc2-point3d-y mp)))
                   (when (<= d best-d)
                     (set! best-d d)
                     (set! best-idx idx))))
               (when best-idx
                 (vector-set! comp-geysers-vec best-idx
                              (cons g (vector-ref comp-geysers-vec best-idx)))))
             (define bases '())
             (for ([comp-mins (in-list min-comps)]
                   [idx (in-naturals 0)])
               (define c-geys (vector-ref comp-geysers-vec idx))
               (when (or (>= (length c-geys) 1) (>= (length comp-mins) 4))
                 (define pad
                   (solve-exact-townhall-pad comp-mins c-geys pl-grid th-grid
                                             #:all-resources all-blocking-res))
                 (when pad
                   (set! bases
                         (cons (hash 'pad pad
                                     'x (sc2-point2d-x pad)
                                     'y (sc2-point2d-y pad)
                                     'minerals comp-mins
                                     'geysers c-geys)
                               bases)))))
             ;; Also handle geyser-only bases when all minerals were mined out
             (define attached-geyser-tags
               (for*/seteqv ([idx (in-range (vector-length comp-geysers-vec))]
                             [g (in-list (vector-ref comp-geysers-vec idx))])
                 (sc2-unit-tag g)))
             (define orphan-geysers
               (filter (lambda (g) (not (set-member? attached-geyser-tags (sc2-unit-tag g)))) geysers))
             (when (>= (length orphan-geysers) 2)
               (define visited-g (mutable-seteqv))
               (for ([g0 (in-list orphan-geysers)]
                     #:when (not (set-member? visited-g (sc2-unit-tag g0))))
                 (define gp0 (sc2-unit-pos g0))
                 (define grp
                   (filter (lambda (g)
                             (define gp (sc2-unit-pos g))
                             (<= (pt-dist (sc2-point3d-x gp0) (sc2-point3d-y gp0)
                                          (sc2-point3d-x gp) (sc2-point3d-y gp))
                                 13.0))
                           orphan-geysers))
                 (for ([g (in-list grp)]) (set-add! visited-g (sc2-unit-tag g)))
                 (when (>= (length grp) 2)
                   (define pad
                     (solve-exact-townhall-pad '() grp pl-grid th-grid
                                               #:all-resources all-blocking-res))
                   (when pad
                     (set! bases
                           (cons (hash 'pad pad
                                       'x (sc2-point2d-x pad)
                                       'y (sc2-point2d-y pad)
                                       'minerals '()
                                       'geysers grp)
                                 bases))))))
             (define ordered (reverse bases))
             (when cache-key
               (when (> (hash-count SC2-EXPANSION-BASES-CACHE) 16)
                 (hash-clear! SC2-EXPANSION-BASES-CACHE))
               (define pad-vec (for/vector ([b (in-list ordered)]) (hash-ref b 'pad)))
               (define cell->pad-idx (build-resource-pad-index pad-vec base-minerals geysers))
               (hash-set! SC2-EXPANSION-BASES-CACHE cache-key (vector pad-vec cell->pad-idx)))
             ordered]))
        (when full-sig
          (set-box! SC2-LAST-SOLVED-EXP-BASES-BOX (cons full-sig result)))
        result])]))

(define (cluster-resource-centroids resources [game-info #f])
  (define solved (solve-all-map-expansion-bases resources game-info))
  (cond
    [(not (null? solved))
     (for/list ([b (in-list solved)])
       (define members (append (hash-ref b 'minerals '()) (hash-ref b 'geysers '())))
       (list (hash-ref b 'x) (hash-ref b 'y) members))]
    [else
     (define clusters '())
     (for ([r (in-list resources)])
       (define rp (sc2-unit-pos r))
       (define rx (sc2-point3d-x rp))
       (define ry (sc2-point3d-y rp))
       (define matched?
         (for/first ([c (in-list clusters)]
                     #:when (<= (pt-dist rx ry (first c) (second c)) SC2-RESOURCE-CLUSTER-RADIUS))
           c))
       (unless matched?
         (define members
           (filter (lambda (m)
                     (define mp (sc2-unit-pos m))
                     (<= (pt-dist rx ry (sc2-point3d-x mp) (sc2-point3d-y mp))
                         SC2-RESOURCE-CLUSTER-RADIUS))
                   resources))
         (when (>= (length members) 4)
           (define cx (/ (apply + (map (lambda (m) (sc2-point3d-x (sc2-unit-pos m))) members))
                         (exact->inexact (length members))))
           (define cy (/ (apply + (map (lambda (m) (sc2-point3d-y (sc2-unit-pos m))) members))
                         (exact->inexact (length members))))
           (set! clusters (cons (list cx cy members) clusters)))))
     (reverse clusters)]))

(define (pick-safe-mule-mineral-patch orbital-u self-units mineral-fields enemy-units)
  (define completed-grounded-ths
    (filter (lambda (u)
              (and (sc2-unit-is-townhall? u)
                   (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)
                   (not (sc2-unit-is-flying u))
                   (not (memq (sc2-id->unit-symbol (sc2-unit-unit-type u))
                              '(command-center-flying orbital-command-flying)))))
            self-units))
  (cond
    [(or (null? completed-grounded-ths) (null? mineral-fields)) 0]
    [else
     (define dangerous-enemies
       (filter (lambda (e)
                 (define esym (sc2-id->unit-symbol (sc2-unit-unit-type e) 'unknown))
                 (not (memq esym '(drone scv probe overlord overlord-cocoon
                                   overseer overseer-siege-mode observer observer-siege-mode
                                   changeling changeling-zealot changeling-marine-shield
                                   changeling-marine changeling-zergling-wings changeling-zergling))))
               enemy-units))
     (define safe-ths
       (filter (lambda (th)
                 (define tp (sc2-unit-pos th))
                 (define tx (sc2-point3d-x tp))
                 (define ty (sc2-point3d-y tp))
                 (not (ormap (lambda (e)
                               (define ep (sc2-unit-pos e))
                               (<= (pt-dist tx ty (sc2-point3d-x ep) (sc2-point3d-y ep)) 12.5))
                             dangerous-enemies)))
               completed-grounded-ths))
     (cond
       [(null? safe-ths) 0]
       [else
        (define ref-u
          (or (and (sc2-unit? orbital-u) orbital-u)
              (findf (lambda (u) (= (sc2-unit-unit-type u) 132)) safe-ths)
              (first safe-ths)))
        (define rp (sc2-unit-pos ref-u))
        (define rx (sc2-point3d-x rp))
        (define ry (sc2-point3d-y rp))
        (define safe-live-mins
          (filter (lambda (m)
                    (define mp (sc2-unit-pos m))
                    (define mx (sc2-point3d-x mp))
                    (define my (sc2-point3d-y mp))
                    (define mc (sc2-unit-mineral-contents m))
                    (and (= (sc2-unit-display-type m) 1)
                         (or (= mc 0) (>= mc 150))
                         (ormap (lambda (th)
                                  (define tp (sc2-unit-pos th))
                                  (<= (pt-dist mx my (sc2-point3d-x tp) (sc2-point3d-y tp)) 12.0))
                                safe-ths)
                         (not (ormap (lambda (e)
                                       (define ep (sc2-unit-pos e))
                                       (<= (pt-dist mx my (sc2-point3d-x ep) (sc2-point3d-y ep)) 11.0))
                                     dangerous-enemies))))
                  mineral-fields))
        (if (null? safe-live-mins)
            0
            (sc2-unit-tag
             (argmin (lambda (m)
                       (define mp (sc2-unit-pos m))
                       (define mc (sc2-unit-mineral-contents m))
                       (- (* 0.35 (pt-dist rx ry (sc2-point3d-x mp) (sc2-point3d-y mp)))
                          (* 0.002 (if (= mc 0) 1500 mc))))
                     safe-live-mins)))])]))

(define (worker-carrying-cargo? w)
  (cond
    [(sc2-unit? w)
     (or (ormap (lambda (bid) (memv bid '(271 272 273 274 275 276)))
                (sc2-unit-buff-ids w))
         (ormap (lambda (o)
                  (let ([ab (sc2-unit-order-ability-id o)])
                    (or (memv ab '(296 299 1184 3667))
                        (memq (sc2-canonical-order-ability ab)
                              '(harvest-return harvest-return-drone harvest-return-scv harvest-return-probe)))))
                (sc2-unit-orders w)))]
    [(hash? w)
     (or (eq? (hash-ref w 'carrying-cargo? #f) #t)
         (eq? (hash-ref w 'has-cargo? #f) #t)
         (ormap (lambda (bid) (memv bid '(271 272 273 274 275 276)))
                (hash-ref w 'buff-ids '()))
         (memq (hash-ref w 'order-ability #f)
               '(harvest-return harvest-return-drone harvest-return-scv harvest-return-probe)))]
    [else #f]))

(define (pick-far-patch-scout-worker workers townhalls mineral-patches)
  (define (u-xy u)
    (cond
      [(sc2-unit? u)
       (define p (sc2-unit-pos u))
       (values (any-point-x p) (if (sc2-point3d? p) (sc2-point3d-y p) (if (sc2-point2d? p) (sc2-point2d-y p) 0.0)))]
      [(hash? u)
       (values (exact->inexact (hash-ref u 'x 0.0))
               (exact->inexact (hash-ref u 'y 0.0)))]
      [else (values 0.0 0.0)]))
  (define (u-tag u)
    (cond
      [(sc2-unit? u) (sc2-unit-tag u)]
      [(hash? u) (hash-ref u 'tag (hash-ref u 'id 0))]
      [else 0]))
  (define (u-target-tag u)
    (cond
      [(sc2-unit? u)
       (define os (sc2-unit-orders u))
       (if (pair? os) (sc2-unit-order-target-unit-tag (first os)) 0)]
      [(hash? u) (hash-ref u 'order-target-tag 0)]
      [else 0]))
  (define (nearest-th-dist x y)
    (if (null? townhalls)
        9.0
        (for/fold ([bd +inf.0]) ([th (in-list townhalls)])
          (define-values (tx ty) (u-xy th))
          (min bd (pt-dist x y tx ty)))))
  (cond
    [(or (not (list? workers)) (null? workers)) #f]
    [else
     (define clean (filter (lambda (w) (not (worker-carrying-cargo? w))) workers))
     (define cand-workers (if (pair? clean) clean workers))
     (define scored-patches
       (for/list ([m (in-list (if (list? mineral-patches) mineral-patches '()))])
         (define-values (mx my) (u-xy m))
         (list m (u-tag m) mx my (nearest-th-dist mx my))))
     (define in-band-patches
       (filter (lambda (p) (<= 6.5 (fifth p) 13.5)) scored-patches))
     (define far-patches
       (cond
         [(pair? in-band-patches)
          (define max-d (apply max (map fifth in-band-patches)))
          (define outer (filter (lambda (p) (>= (fifth p) (- max-d 0.75))) in-band-patches))
          (if (pair? outer) outer in-band-patches)]
         [(pair? scored-patches)
          (define max-d (apply max (map fifth scored-patches)))
          (filter (lambda (p) (>= (fifth p) (- max-d 0.75))) scored-patches)]
         [else '()]))
     (define far-patch-tags (list->seteqv (map second far-patches)))
     (define-values (best-w _best-score)
       (for/fold ([bw #f] [bsc -inf.0]) ([w (in-list cand-workers)])
         (define-values (wx wy) (u-xy w))
         (define wtgt (u-target-tag w))
         (define th-d (nearest-th-dist wx wy))
         (define min-far-d
           (if (null? far-patches)
               th-d
               (for/fold ([md +inf.0]) ([p (in-list far-patches)])
                 (min md (pt-dist wx wy (third p) (fourth p))))))
         (define on-far-tag? (and (> wtgt 0) (set-member? far-patch-tags wtgt)))
         (define near-far-patch? (and (pair? far-patches) (<= min-far-d 2.5)))
         (define in-far-band? (<= 6.5 th-d 13.5))
         ;; Higher score is better: mining/near a far patch beats inner patch; within band [6.5,13.5] farther beats closer.
         (define sc
           (+ (if on-far-tag? 1000.0 0.0)
              (if near-far-patch? (- 400.0 (* 10.0 min-far-d)) 0.0)
              (if in-far-band? (* 5.0 th-d) (- th-d))
              (if (pair? far-patches) (- (* 2.0 min-far-d)) 0.0)))
         (if (or (not bw) (> sc bsc))
             (values w sc)
             (values bw bsc))))
     best-w]))

(define SC2-WARPGATE-LAST-LOOP (box 0))
(define SC2-WARPGATE-COOLDOWN-UNTIL (make-hasheqv))
(define SC2-WARP-IN-ABILITY-IDS '(1413 1414 1416 1417 1418 1419))
;; W11-P0-3-wire: Reconcile client-side WarpGate cooldown estimates against SC2 `action-errors`
;; (rejected warp-ins must NEVER lock out a WarpGate for 23s!) and live `player_common.warp_gate_count`
;; (ground-truth off-cooldown WarpGate count, accounting for Chronoboost or governor drops).
(define (reconcile-warpgate-cooldowns! obs units cur-loop [our-player-id #f])
  (when (sc2-observation? obs)
    (define act-errs (sc2-observation-action-errors obs))
    (when (list? act-errs)
      (for ([ae (in-list act-errs)]
            #:when (hash? ae))
        (define ab (hash-ref ae 'ability-id 0))
        (define res (hash-ref ae 'result 0))
        ;; W17-P0-1-wire: Targeted positive-cache invalidation for ONLY the failed `(bldg, anchor)`
        ;; entry (NEVER global `hash-clear!` that thrashes unrelated buildings like Gateways/Barracks!);
        ;; record Terran 5x3 misses for 1-miss 3x3/overflow fallback; mark blocked East add-on slots
        ;; and release wire nonstack cooldowns on failed add-ons or building morphs!
        (when (and (not (= res 1))
                   (let ([ab-sym (sc2-id->ability-symbol ab #f)])
                     (and ab-sym (string-prefix? (symbol->string ab-sym) "build-"))))
          (define ab-sym (sc2-id->ability-symbol ab #f))
          (define utag (hash-ref ae 'unit-tag 0))
          (define has-utag? (and (exact-integer? utag) (> utag 0)))
          (define act-u (and has-utag? (findf (lambda (u) (= (sc2-unit-tag u) utag)) units)))
          (define is-terran-addon-ab? (memv ab '(421 422 454 455 487 488 3682 3683)))
          (define target-bldgs
            (cond
              [(memv ab '(421 422)) '(barracks)]
              [(memv ab '(454 455)) '(factory)]
              [(memv ab '(487 488)) '(starport)]
              [(memv ab '(3682 3683))
               (if act-u
                   (list (sc2-id->unit-symbol (sc2-unit-unit-type act-u)))
                   '(barracks factory starport))]
              [else
               (define raw-bldg-str (substring (symbol->string ab-sym) 6))
               (list (sc2-canonical-structure-sym (string->symbol raw-bldg-str)))]))
          (define-values (fail-x fail-y)
            (let ([br (and has-utag? (hash-ref SC2-BUILDER-RESERVATION utag #f))])
              (cond
                [(and (list? br) (>= (length br) 4) (real? (third br)) (real? (fourth br)))
                 (values (exact->inexact (third br)) (exact->inexact (fourth br)))]
                [act-u
                 (define ap (sc2-unit-pos act-u))
                 (values (sc2-point3d-x ap) (sc2-point3d-y ap))]
                [else (values #f #f)])))
          (define stale-pos-keys
            (for/list ([(k v) (in-hash SC2-PLACEMENT-POS-CACHE)]
                       #:when (and (pair? k)
                                   (memq (car k) target-bldgs)
                                   (or (not fail-x)
                                       (not fail-y)
                                       (and (pair? v)
                                            (>= (length v) 2)
                                            (sc2-point2d? (cadr v))
                                            (<= (pt-dist fail-x fail-y
                                                         (sc2-point2d-x (cadr v))
                                                         (sc2-point2d-y (cadr v)))
                                                8.0))
                                       (and (>= (length k) 3)
                                            (real? (second k))
                                            (real? (third k))
                                            (<= (pt-dist fail-x fail-y
                                                         (exact->inexact (second k))
                                                         (exact->inexact (third k)))
                                                (max 16.0
                                                     (if (and (>= (length k) 4) (real? (fourth k)))
                                                         (+ (exact->inexact (fourth k)) 2.0)
                                                         16.0)))))))
              k))
          (for ([k (in-list stale-pos-keys)])
            (hash-remove! SC2-PLACEMENT-POS-CACHE k))
          (when (memv ab '(321 328 329))
            (define tb (car target-bldgs))
            (hash-set! SC2-TERRAN-5X3-MISS-CACHE
                       (if (and fail-x fail-y)
                           (list tb (inexact->exact (round fail-x)) (inexact->exact (round fail-y)))
                           (list tb 'any))
                       cur-loop))
          (when is-terran-addon-ab?
            (when has-utag?
              (when act-u
                (define fp (sc2-unit-pos act-u))
                (hash-set! SC2-ADDON-SLOT-BLOCKED-CACHE
                           (list utag
                                 (inexact->exact (round (sc2-point3d-x fp)))
                                 (inexact->exact (round (sc2-point3d-y fp))))
                           cur-loop))
              (for ([k (in-list (for/list ([kk (in-hash-keys SC2-WIRE-NONSTACK-CMD-COOLDOWN)]
                                           #:when (and (list? kk)
                                                       (= (length kk) 3)
                                                       (eq? (first kk) 'wire-addon)
                                                       (equal? (third kk) utag)))
                                  kk))])
                (hash-remove! SC2-WIRE-NONSTACK-CMD-COOLDOWN k)))))
        ;; W17-P0-2-wire: Failed TownHall/Spire morphs (Lair=1216, Hive=1218, GreaterSpire=1220,
        ;; Orbital=1516, Planetary=1450) immediately release their wire nonstack cooldown!
        (when (and (not (= res 1))
                   (memv ab '(1216 1218 1220 1450 1516)))
          (define utag (hash-ref ae 'unit-tag 0))
          (when (and (exact-integer? utag) (> utag 0))
            (for ([k (in-list (for/list ([kk (in-hash-keys SC2-WIRE-NONSTACK-CMD-COOLDOWN)]
                                         #:when (and (list? kk)
                                                     (= (length kk) 3)
                                                     (or (and (eq? (first kk) 'wire-build-morph)
                                                              (equal? (third kk) utag))
                                                         (and (eq? (first kk) 'wire-morph)
                                                              (list? (third kk))
                                                              (memv utag (third kk))))))
                                kk))])
              (hash-remove! SC2-WIRE-NONSTACK-CMD-COOLDOWN k))))
        (when (and (memv ab SC2-WARP-IN-ABILITY-IDS) (not (= res 1)))
          (define utag (hash-ref ae 'unit-tag 0))
          (cond
            [(and (exact-integer? utag) (> utag 0))
             (hash-remove! SC2-WARPGATE-COOLDOWN-UNTIL utag)]
            [else
             ;; Action error omitted unit-tag: release any WarpGate locked within the last ~24 loops
             (define stale-keys
               (for/list ([(k v) (in-hash SC2-WARPGATE-COOLDOWN-UNTIL)]
                          #:when (> (- v cur-loop) 420))
                 k))
             (for ([k (in-list stale-keys)])
               (hash-remove! SC2-WARPGATE-COOLDOWN-UNTIL k))]))))
    (define pc (sc2-observation-player-common obs))
    (define live-wg-ready (if (sc2-player-common? pc) (sc2-player-common-warp-gate-count pc) 0))
    (when (and (exact-integer? live-wg-ready) (> live-wg-ready 0) (list? units))
      (define est-ready-cnt 0)
      (define est-busy '())
      (for ([u (in-list units)]
            #:when (and (sc2-unit? u)
                        (= (sc2-unit-unit-type u) 133)
                        (= (sc2-unit-alliance u) 1)
                        (not (= (sc2-unit-display-type u) 4))
                        (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)
                        (sc2-unit-is-powered u)
                        (or (not our-player-id) (= (sc2-unit-owner u) our-player-id) (= (sc2-unit-owner u) 1))))
        (define tag (sc2-unit-tag u))
        (define until (hash-ref SC2-WARPGATE-COOLDOWN-UNTIL tag 0))
        (if (< cur-loop until)
            (set! est-busy (cons (cons tag until) est-busy))
            (set! est-ready-cnt (add1 est-ready-cnt))))
      (define deficit (- live-wg-ready est-ready-cnt))
      (when (and (> deficit 0) (pair? est-busy))
        (define sorted-busy (sort est-busy < #:key cdr))
        (for ([pair (in-list (take sorted-busy (min deficit (length sorted-busy))))])
          (hash-remove! SC2-WARPGATE-COOLDOWN-UNTIL (car pair)))))))
(define SC2-WORKER-BUILD-ORDER-START (make-hasheqv))
(define SC2-HOME-BASE-ANCHOR (box #f))
(define SC2-CLEARED-ENEMY-BASES (box '()))
(define SC2-ENEMY-MAIN-CLEARED-AT (box #f))
(define SC2-EVER-SAW-MINERALS? (box #f))
(define SC2-WIRE-HOLD-POSTURE-STATE (box #f))
(define SC2-WIRE-OFFENSIVE-PUSH-STATE (box #f))
(define SC2-CACHED-MAP-BASE-CLUSTERS (box '()))
(define SC2-CORNER-SCAN-LAST-LOOP (box -9999))
(define SC2-ACTIVE-GAME-INFO (box #f))
(define SC2-PLACEMENT-NEG-COOLDOWN (make-hash))
(define SC2-PLACEMENT-POS-CACHE (make-hash))
(define SC2-ADDON-SLOT-BLOCKED-CACHE (make-hash))
(define SC2-TERRAN-5X3-MISS-CACHE (make-hash))
(define SC2-TUMOR-PLACEMENT-CACHE (make-hash))
(define SC2-MACRO-ABILITY-LAST-LOOP (make-hash))

(define (terran-5x3-miss-active? canon-bldg ax ay cur-loop)
  (and (memq canon-bldg '(barracks factory starport))
       (for/or ([(k v) (in-hash SC2-TERRAN-5X3-MISS-CACHE)])
         (and (pair? k)
              (eq? (car k) canon-bldg)
              (exact-integer? v)
              (>= cur-loop v)
              (< (- cur-loop v) SC2-PLACEMENT-CACHE-TTL)
              (or (and (>= (length k) 2) (eq? (second k) 'any))
                  (and (>= (length k) 3)
                       (real? (second k))
                       (real? (third k))
                       (<= (pt-dist ax ay
                                    (exact->inexact (second k))
                                    (exact->inexact (third k)))
                           16.0)))))))
(define SC2-LAST-TUMOR-RPC-LOOP (box -9999))
(define SC2-ZERG-TH-MORPH-RESERVE-LOOP (box #f))
(define SC2-ENEMY-POS-PURGE-LAST-LOOP (box -9999))
(define SC2-PLACEMENT-CACHE-SIG (box #f))
(define SC2-PROTOSS-POWER-PLACEMENT-FAIL-LOOP (box -9999))

(define (worker-build-order-stuck? w [cur-loop (unbox SC2-WARPGATE-LAST-LOOP)])
  (define entry (hash-ref SC2-WORKER-BUILD-ORDER-START (sc2-unit-tag w) #f))
  (and entry
       (or (> (- cur-loop (second entry)) 112)
           (and (>= (length entry) 8)
                (> (- cur-loop (eighth entry)) 168)))))

(define (sort-townhalls-main-first ths)
  (define anchor (unbox SC2-HOME-BASE-ANCHOR))
  (sort ths
        <
        #:key (lambda (u)
                (define p (sc2-unit-pos u))
                (define incomplete-penalty
                  (if (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS) 0.0 10000.0))
                (define dist-score
                  (if anchor
                      (pt-dist (car anchor) (cdr anchor) (sc2-point3d-x p) (sc2-point3d-y p))
                      0.0))
                (+ incomplete-penalty
                   dist-score
                   (/ (modulo (sc2-unit-tag u) 1000000) 100000000.0)))))

(define (order-expansions-from-origin solved-bases origin-x origin-y pathing-grid neutral-units
                                      #:bfs [pre-bfs #f])
  (define non-main
    (filter (lambda (b)
              (> (pt-dist origin-x origin-y (hash-ref b 'x) (hash-ref b 'y)) 10.0))
            solved-bases))
  (define bfs (or pre-bfs (compute-ground-bfs-distances pathing-grid origin-x origin-y neutral-units)))
  (cond
    [bfs
     (define scored
       (for/list ([b (in-list non-main)])
         (define bx (hash-ref b 'x))
         (define by (hash-ref b 'y))
         (cons b (bfs bx by 3))))
     (define reachable (filter (lambda (pr) (< (cdr pr) +inf.0)) scored))
     (define pool (if (not (null? reachable)) reachable scored))
     (map car
          (sort pool <
                #:key (lambda (pr)
                        (define b (car pr))
                        (define gd (cdr pr))
                        (if (< gd +inf.0)
                            gd
                            (+ 100000.0 (pt-dist origin-x origin-y (hash-ref b 'x) (hash-ref b 'y)))))))]
    [else
     (sort non-main <
           #:key (lambda (b)
                   (pt-dist origin-x origin-y (hash-ref b 'x) (hash-ref b 'y))))]))

(define SC2-NON-PROXY-ENEMY-STRUCTURE-SYMS
  '(creep-tumor
    creep-tumor-burrowed
    creep-tumor-queen
    oracle-stasis-trap
    stasis-ward
    auto-turret
    point-defense-drone
    kd8-charge))

(define SC2-CACHED-GROUND-BFS (box #f))
(define SC2-TERRITORY-FIELD-CACHE (box #f))

;; Weak-key tag table for emergency survival wire commands (e.g. bruised-worker & scout `mineral-walk`
;; escapes), elevating them from routine P3 harvest (`3666`) to Tier `P0` in `govern-sc2-wire-actions!`.
(define SC2-URGENT-SURVIVAL-CMDS (make-weak-hasheq))
(define (mark-urgent-survival-cmd! cmd)
  (when (sc2-raw-unit-command? cmd)
    (hash-set! SC2-URGENT-SURVIVAL-CMDS cmd #t))
  cmd)
(define (urgent-survival-cmd? cmd)
  (and (sc2-raw-unit-command? cmd)
       (eq? (hash-ref SC2-URGENT-SURVIVAL-CMDS cmd #f) #t)))

;; W18-P0-2-wire: Weak-key tag table for critical macro-economy recovery commands (gas saturation/
;; resaturation, idle-worker recovery, offline-base evacuation, and gas-float mineral rebalance),
;; elevating them from routine P3 (`3666`) to Tier `P1` in `govern-sc2-wire-actions!` so continuous
;; `P2` combat micro NEVER starves gas resaturation or worker recovery!
(define SC2-MACRO-ECON-CMDS (make-weak-hasheq))
(define (mark-macro-econ-cmd! cmd)
  (when (sc2-raw-unit-command? cmd)
    (hash-set! SC2-MACRO-ECON-CMDS cmd #t))
  cmd)
(define (macro-econ-cmd? cmd)
  (and (sc2-raw-unit-command? cmd)
       (eq? (hash-ref SC2-MACRO-ECON-CMDS cmd #f) #t)))

(define SC2-FRAMING-CAMERA-CMDS (make-weak-hasheq))
(define (mark-framing-camera-cmd! cmd [jump-dist #f])
  (when (sc2-raw-camera-move? cmd)
    (hash-set! SC2-FRAMING-CAMERA-CMDS cmd
               (if (and (real? jump-dist) (not (nan? jump-dist)) (not (infinite? jump-dist)))
                   (exact->inexact jump-dist)
                   #t)))
  cmd)
(define (framing-camera-cmd? cmd)
  (and (sc2-raw-camera-move? cmd)
       (not (not (hash-ref SC2-FRAMING-CAMERA-CMDS cmd #f)))))
(define SC2-CMD-FRAMING-CAM (make-weak-hasheq))

;; Structural 3-Base Proxy Invariant:
;; An observed enemy building is a proxy iff it is a real structure (excluding creep tumors / traps / turrets)
;; and its position `(bx, by)` is NOT inside (`<= base-radius`, default 28.0 tiles) the opponent's
;; `main`, `natural`, or `3rd` base location.
(define (enemy-structure-is-proxy? bsym bx by
                                   enemy-x enemy-y
                                   enemy-nat-x enemy-nat-y
                                   enemy-third-x enemy-third-y
                                   [base-radius 28.0])
  (define canon (sc2-canonical-structure-sym bsym))
  (and (symbol? canon)
       (not (memq canon SC2-NON-PROXY-ENEMY-STRUCTURE-SYMS))
       (real? bx) (real? by)
       (> (min (pt-dist bx by enemy-x enemy-y)
               (pt-dist bx by enemy-nat-x enemy-nat-y)
               (pt-dist bx by enemy-third-x enemy-third-y))
          base-radius)))

;; SC2 `raw.proto` `Unit.weapon_cooldown` is reported in game loops (`22.4` loops/sec at Faster speed).
;; Normalize to Faster-speed seconds at the wire boundary so runtime combat micro, order-ledger swing
;; protection, and minimax rollouts consume consistent seconds.
(define (sc2-weapon-cooldown-loops->seconds raw-cd)
  (if (and (real? raw-cd) (not (nan? raw-cd)) (not (infinite? raw-cd)))
      (/ (max 0.0 (exact->inexact raw-cd)) SC2-FASTER-FPS)
      0.0))

(define (sc2-passenger-unit->runtime-hash pu)
  (hasheq 'id (sc2-passenger-unit-tag pu)
          'tag (sc2-passenger-unit-tag pu)
          'type (sc2-id->unit-symbol (sc2-passenger-unit-unit-type pu))
          'hp (max 1 (exact-round (+ (sc2-passenger-unit-health pu)
                                     (sc2-passenger-unit-shield pu))))
          'hull-hp (max 1 (exact-round (sc2-passenger-unit-health pu)))
          'max-hp (max 1 (exact-round (+ (sc2-passenger-unit-health-max pu)
                                         (sc2-passenger-unit-shield-max pu))))
          'shield (max 0 (exact-round (sc2-passenger-unit-shield pu)))
          'energy (max 0 (exact-round (sc2-passenger-unit-energy pu)))
          'energy-max (max 0 (exact-round (sc2-passenger-unit-energy-max pu)))))

(define (sc2-observation->runtime-obs-hash obs
                                           #:game-info [game-info #f]
                                           #:our-player-id [our-player-id 1]
                                           #:configured-race [configured-race 'Random]
                                           #:used-creep-tumors [used-tumors (seteqv)]
                                           #:defer-expansions? [defer-expansions? #f])
  (define cur-loop (sc2-observation-game-loop obs))
  (when (sc2-game-info? game-info)
    (set-box! SC2-ACTIVE-GAME-INFO game-info))
  (when (< cur-loop (unbox SC2-WARPGATE-LAST-LOOP))
    (hash-clear! SC2-WARPGATE-COOLDOWN-UNTIL)
    (hash-clear! SC2-WORKER-BUILD-ORDER-START)
    (set-box! SC2-HOME-BASE-ANCHOR #f)
    (set-box! SC2-CLEARED-ENEMY-BASES '())
    (set-box! SC2-ENEMY-MAIN-CLEARED-AT #f)
    (set-box! SC2-EVER-SAW-MINERALS? #f)
    (set-box! SC2-WIRE-HOLD-POSTURE-STATE #f)
    (set-box! SC2-WIRE-OFFENSIVE-PUSH-STATE #f)
    (set-box! SC2-CACHED-MAP-BASE-CLUSTERS '())
    (set-box! SC2-CACHED-GROUND-BFS #f)
    (set-box! SC2-TERRITORY-FIELD-CACHE #f)
    (set-box! SC2-CORNER-SCAN-LAST-LOOP -9999)
    (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
    (hash-clear! SC2-PLACEMENT-POS-CACHE)
    (hash-clear! SC2-ADDON-SLOT-BLOCKED-CACHE)
    (hash-clear! SC2-TERRAN-5X3-MISS-CACHE)
    (hash-clear! SC2-TUMOR-PLACEMENT-CACHE)
    (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
    (set-box! SC2-LAST-TUMOR-RPC-LOOP -9999)
    (set-box! SC2-ZERG-TH-MORPH-RESERVE-LOOP #f)
    (set-box! SC2-ENEMY-POS-PURGE-LAST-LOOP -9999)
    (set-box! SC2-PLACEMENT-CACHE-SIG #f)
    (set-box! SC2-PROTOSS-POWER-PLACEMENT-FAIL-LOOP -9999))
  (set-box! SC2-WARPGATE-LAST-LOOP cur-loop)
  (define pc (sc2-observation-player-common obs))
  (define units (sc2-observation-units obs))
  (reconcile-warpgate-cooldowns! obs units cur-loop our-player-id)
  (define actual-race
    (detect-actual-race-from-units units game-info our-player-id configured-race))
  (define opponent-requested-race
    (or (and (sc2-game-info? game-info)
             (for/first ([pi (in-list (sc2-game-info-player-info game-info))]
                         #:when (not (= (hash-ref pi 'player-id 0) our-player-id)))
               (hash-ref pi 'race-requested 'Random)))
        'Random))
  (define map-grids
    (and (sc2-game-info? game-info)
         (let ([pg (sc2-game-info-pathing-grid game-info)]
               [plg (sc2-game-info-placement-grid game-info)]
               [thg (sc2-game-info-terrain-height game-info)])
           (and (or pg plg thg)
                (let* ([ref-g (or pg plg thg)]
                       [w (sc2-image-grid-width ref-g)]
                       [h (sc2-image-grid-height ref-g)])
                  (hash 'width w
                        'height h
                        'pathing-grid pg
                        'placement-grid plg
                        'terrain-height thg
                        'pathing-ref (lambda (ix iy) (sc2-grid-ref pg ix iy))
                        'placement-ref (lambda (ix iy) (sc2-grid-ref plg ix iy))
                        'height-ref (lambda (ix iy) (sc2-grid-ref thg ix iy))))))))

  ;; Filter out DisplayType.Placeholder (= 4) ghosts whose unset build_progress defaults to 1.0!
  (define-values (self-units enemy-all neutral-all)
    (let-values ([(su ea na)
                  (for/fold ([su '()] [ea '()] [na '()])
                            ([u (in-list units)])
                    (define al (sc2-unit-alliance u))
                    (cond
                      [(and (= al 1) (not (= (sc2-unit-display-type u) 4)))
                       (values (cons u su) ea na)]
                      [(and (= al 4) (not (= (sc2-unit-display-type u) 4)))
                       (values su (cons u ea) na)]
                      [(= al 3)
                       (values su ea (cons u na))]
                      [else
                       (values su ea na)]))])
      (values (reverse su) (reverse ea) (reverse na))))

  (define-values (mineral-fields live-resource-units)
    (let-values ([(mf lru)
                  (for/fold ([mf '()] [lru '()])
                            ([u (in-list neutral-all)])
                    (cond
                      [(sc2-unit-is-mineral-field? u)
                       (values (cons u mf) (cons u lru))]
                      [(sc2-unit-is-vespene-geyser? u)
                       (values mf (cons u lru))]
                      [else
                       (values mf lru)]))])
      (values (reverse mf) (reverse lru))))
  (define solved-bases
    (if defer-expansions?
        '()
        (solve-all-map-expansion-bases neutral-all game-info)))
  (define raw-my-townhalls (filter sc2-unit-is-townhall? self-units))
  (when (and (= (length raw-my-townhalls) 1)
             (or (not (unbox SC2-HOME-BASE-ANCHOR))
                 (<= cur-loop 20)))
    (define p0 (sc2-unit-pos (first raw-my-townhalls)))
    (define new-anchor (cons (sc2-point3d-x p0) (sc2-point3d-y p0)))
    (define old-anchor (unbox SC2-HOME-BASE-ANCHOR))
    (set-box! SC2-HOME-BASE-ANCHOR new-anchor)
    (set-box! SC2-CLEARED-ENEMY-BASES '())
    (set-box! SC2-ENEMY-MAIN-CLEARED-AT #f)
    (set-box! SC2-EVER-SAW-MINERALS? #f)
    (set-box! SC2-WIRE-HOLD-POSTURE-STATE #f)
    (set-box! SC2-WIRE-OFFENSIVE-PUSH-STATE #f)
    (set-box! SC2-CACHED-MAP-BASE-CLUSTERS '())
    (when (or (not old-anchor)
              (> (pt-dist (car old-anchor) (cdr old-anchor) (car new-anchor) (cdr new-anchor)) 2.0))
      (set-box! SC2-TERRITORY-FIELD-CACHE #f))
    (set-box! SC2-CORNER-SCAN-LAST-LOOP -9999))
  (when (not (null? mineral-fields))
    (set-box! SC2-EVER-SAW-MINERALS? #t))
  (when (and (not defer-expansions?) (not (null? live-resource-units)))
    (define live-clusters
      (if (not (null? solved-bases))
          (for/list ([b (in-list solved-bases)])
            (list (hash-ref b 'x)
                  (hash-ref b 'y)
                  (append (hash-ref b 'minerals '()) (hash-ref b 'geysers '()))))
          (cluster-resource-centroids live-resource-units game-info)))
    (when (> (length live-clusters) (length (unbox SC2-CACHED-MAP-BASE-CLUSTERS)))
      (set-box! SC2-CACHED-MAP-BASE-CLUSTERS live-clusters)))
  (define my-townhalls (sort-townhalls-main-first raw-my-townhalls))
  ;; Exclude flying townhalls so lifted CCs/OCs never add +16 phantom ideal harvesters or rally SCVs!
  (define ready-townhalls
    (filter (lambda (u)
              (and (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)
                   (not (sc2-unit-is-flying u))
                   (not (memq (sc2-id->unit-symbol (sc2-unit-unit-type u))
                              '(command-center-flying orbital-command-flying)))))
            my-townhalls))
  (define my-gas-bldgs (filter sc2-unit-is-gas-building? self-units))
  (define ready-gas-bldgs
    (filter (lambda (u) (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)) my-gas-bldgs))
  (define my-workers (filter sc2-unit-is-worker? self-units))

  ;; Update worker build-order movement/construction timestamps across ALL queued orders:
  ;; A worker is NEVER stuck while actively constructing or making real distance progress toward
  ;; its build site; it expires after standing still > 112 loops (~5s) or pacing > 168 loops (~7.5s)
  ;; without closing distance to `(tx, ty)`.
  (for ([w (in-list my-workers)])
    (define wtag (sc2-unit-tag w))
    (define build-ord
      (findf (lambda (o)
               (define s (sc2-id->ability-symbol (sc2-unit-order-ability-id o) #f))
               (and s (string-prefix? (symbol->string s) "build-")))
             (sc2-unit-orders w)))
    (cond
      [build-ord
       (define ab-id (sc2-unit-order-ability-id build-ord))
       (define ab-sym (sc2-id->ability-symbol ab-id #f))
       (define ab-str (if ab-sym (symbol->string ab-sym) ""))
       (define bsym (sc2-canonical-structure-sym (string->symbol (substring ab-str 6))))
       (define wp (sc2-unit-pos w))
       (define wx (sc2-point3d-x wp))
       (define wy (sc2-point3d-y wp))
       (define tpos (sc2-unit-order-target-pos build-ord))
       (define tgt-tag (sc2-unit-order-target-unit-tag build-ord))
       (define tx (if (any-point? tpos) (any-point-x tpos) wx))
       (define ty (if (any-point? tpos) (any-point-y tpos) wy))
       (define cur-dist (pt-dist wx wy tx ty))
       (define actively-constructing?
         (ormap (lambda (b)
                  (define bp (sc2-unit-pos b))
                  (and (sc2-structure-matches-target?
                        (sc2-id->unit-symbol (sc2-unit-unit-type b))
                        bsym)
                       (< (sc2-unit-build-progress b) SC2-BUILD-COMPLETE-PROGRESS)
                       (or (= tgt-tag (sc2-unit-tag b))
                           (<= (pt-dist tx ty (sc2-point3d-x bp) (sc2-point3d-y bp)) 6.0)
                           (<= (pt-dist wx wy (sc2-point3d-x bp) (sc2-point3d-y bp)) 6.0))))
                self-units))
       (define prev (hash-ref SC2-WORKER-BUILD-ORDER-START wtag #f))
       (cond
         [(or actively-constructing?
              (not prev)
              (< (length prev) 6)
              (not (= (first prev) ab-id))
              (> (pt-dist tx ty (third prev) (fourth prev)) 2.0))
          (hash-set! SC2-WORKER-BUILD-ORDER-START wtag
                     (list ab-id cur-loop tx ty wx wy cur-dist cur-loop))]
         [else
          (define moved? (> (pt-dist wx wy (fifth prev) (sixth prev)) 0.5))
          (define prev-best-d (if (>= (length prev) 8) (seventh prev) cur-dist))
          (define prev-best-l (if (>= (length prev) 8) (eighth prev) (second prev)))
          (define closer? (< cur-dist (- prev-best-d 0.75)))
          (hash-set! SC2-WORKER-BUILD-ORDER-START wtag
                     (list ab-id
                           (if moved? cur-loop (second prev))
                           tx ty
                           (if moved? wx (fifth prev))
                           (if moved? wy (sixth prev))
                           (if closer? cur-dist prev-best-d)
                           (if closer? cur-loop prev-best-l)))])]
      [else
       (hash-remove! SC2-WORKER-BUILD-ORDER-START wtag)]))

  ;; Determine start-pos & enemy-base (Bug #12 fix: choose start-location farthest from base)
  (define-values (base-x base-y)
    (if (not (null? my-townhalls))
        (let ([p (sc2-unit-pos (first my-townhalls))])
          (values (sc2-point3d-x p) (sc2-point3d-y p)))
        (let ([anchor (unbox SC2-HOME-BASE-ANCHOR)])
          (if anchor
              (values (car anchor) (cdr anchor))
              (values SC2-DEFAULT-HOME-BASE-X SC2-DEFAULT-HOME-BASE-Y)))))

  (define-values (enemy-x enemy-y)
    (cond
      [(and (sc2-game-info? game-info)
            (not (null? (sc2-game-info-start-locations game-info))))
       (define sl
         (argmax (lambda (s)
                   (pt-dist base-x base-y (sc2-point2d-x s) (sc2-point2d-y s)))
                 (sc2-game-info-start-locations game-info)))
       (values (sc2-point2d-x sl) (sc2-point2d-y sl))]
      [(not (null? enemy-all))
       (define p (sc2-unit-pos (first enemy-all)))
       (values (sc2-point3d-x p) (sc2-point3d-y p))]
      [else
       (values SC2-DEFAULT-ENEMY-BASE-X SC2-DEFAULT-ENEMY-BASE-Y)]))

  ;; Exact 5x5 TownHall pads ordered by ground BFS distance from Main (and from Enemy Main);
  ;; when `defer-expansions?` is `#t` on Frame 0, use O(1) vector fallbacks and solve on step 1!
  (define dx (- enemy-x base-x))
  (define dy (- enemy-y base-y))
  (define d-norm (max 1.0 (sqrt (+ (sqr dx) (sqr dy)))))
  (define ux (/ dx d-norm))
  (define uy (/ dy d-norm))
  (define path-grid (and (sc2-game-info? game-info) (sc2-game-info-pathing-grid game-info)))

  ;; W15-P0-2-wire / W16-P1-2-wire: Compute/lookup match-start map-symmetry & dual Ground-BFS
  ;; BEFORE `order-expansions-from-origin` so expansion ordering reuses the cached match-start BFS
  ;; in O(1) (`0ms`/step, zero redundant 200x200 Dial BFS runs as mineral patches mine out!).
  (define-values (map-symmetry-kind our-ground-bfs enemy-ground-bfs)
    (let* ([grid-sig (and (sc2-image-grid? path-grid) (image-grid-signature path-grid))]
           [base-key (list grid-sig
                           (exact-round base-x) (exact-round base-y)
                           (exact-round enemy-x) (exact-round enemy-y))]
           [has-pads? (pair? solved-bases)]
           [cached (unbox SC2-TERRITORY-FIELD-CACHE)])
      (cond
        [(and (list? cached)
              (= (length cached) 5)
              (equal? (first cached) base-key)
              (or (second cached) (not has-pads?))
              (or defer-expansions?
                  (not (sc2-image-grid? path-grid))
                  (and (fourth cached) (fifth cached))))
         (values (third cached) (fourth cached) (fifth cached))]
        [else
         (define-values (play-x0 play-y0 play-w play-h)
           (cond
             [(sc2-game-info? game-info)
              (define pa (sc2-game-info-playable-area game-info))
              (define ms (sc2-game-info-map-size game-info))
              (cond
                [(and (hash? pa)
                      (real? (hash-ref pa 'x0 #f)) (real? (hash-ref pa 'y0 #f))
                      (real? (hash-ref pa 'x1 #f)) (real? (hash-ref pa 'y1 #f)))
                 (define px0 (exact->inexact (hash-ref pa 'x0)))
                 (define py0 (exact->inexact (hash-ref pa 'y0)))
                 (define px1 (exact->inexact (hash-ref pa 'x1)))
                 (define py1 (exact->inexact (hash-ref pa 'y1)))
                 (values px0 py0 (max 1.0 (- px1 px0)) (max 1.0 (- py1 py0)))]
                [(and (list? pa) (>= (length pa) 4)
                      (real? (first pa)) (real? (second pa))
                      (real? (third pa)) (real? (fourth pa)))
                 (define px0 (exact->inexact (first pa)))
                 (define py0 (exact->inexact (second pa)))
                 (define px1 (exact->inexact (third pa)))
                 (define py1 (exact->inexact (fourth pa)))
                 (values px0 py0 (max 1.0 (- px1 px0)) (max 1.0 (- py1 py0)))]
                [(and (pair? ms) (real? (car ms)) (real? (cdr ms)))
                 (values 0.0 0.0 (exact->inexact (car ms)) (exact->inexact (cdr ms)))]
                [(sc2-image-grid? path-grid)
                 (values 0.0 0.0
                         (exact->inexact (sc2-image-grid-width path-grid))
                         (exact->inexact (sc2-image-grid-height path-grid)))]
                [else (values 0.0 0.0 200.0 200.0)])]
             [(sc2-image-grid? path-grid)
              (values 0.0 0.0
                      (exact->inexact (sc2-image-grid-width path-grid))
                      (exact->inexact (sc2-image-grid-height path-grid)))]
             [else (values 0.0 0.0 200.0 200.0)]))
         (define pad-pts
           (if has-pads?
               (for/list ([b (in-list solved-bases)])
                 (cons (hash-ref b 'x) (hash-ref b 'y)))
               '()))
         (define sym-k
           (sc2-detect-map-symmetry (cons base-x base-y) (cons enemy-x enemy-y)
                                    play-w play-h pad-pts
                                    #:x0 play-x0 #:y0 play-y0))
         (cond
           [(and (not defer-expansions?) (sc2-image-grid? path-grid))
            (define obfs (compute-ground-bfs-distances path-grid base-x base-y neutral-all))
            (define ebfs (compute-ground-bfs-distances path-grid enemy-x enemy-y neutral-all))
            (set-box! SC2-TERRITORY-FIELD-CACHE (list base-key has-pads? sym-k obfs ebfs))
            (values sym-k obfs ebfs)]
           [else
            (when (not (sc2-image-grid? path-grid))
              (set-box! SC2-TERRITORY-FIELD-CACHE (list base-key has-pads? sym-k #f #f)))
            (values sym-k #f #f)])])))
  (define ordered-home-exps
    (if defer-expansions?
        '()
        (order-expansions-from-origin solved-bases base-x base-y path-grid neutral-all
                                      #:bfs our-ground-bfs)))
  (define ordered-enemy-exps
    (if defer-expansions?
        '()
        (order-expansions-from-origin solved-bases enemy-x enemy-y path-grid neutral-all
                                      #:bfs enemy-ground-bfs)))
  (define expansion-candidates
    (for/list ([b (in-list ordered-home-exps)])
      (cons (hash-ref b 'x) (hash-ref b 'y))))
  (define-values (nat-x nat-y)
    (if (>= (length ordered-home-exps) 1)
        (let ([b (first ordered-home-exps)])
          (values (hash-ref b 'x) (hash-ref b 'y)))
        (values (+ base-x (* SC2-NATURAL-VECTOR-OFFSET-TILES ux))
                (+ base-y (* SC2-NATURAL-VECTOR-OFFSET-TILES uy)))))
  (define-values (third-x third-y)
    (if (>= (length ordered-home-exps) 2)
        (let ([b (second ordered-home-exps)])
          (values (hash-ref b 'x) (hash-ref b 'y)))
        (values (+ base-x (* SC2-THIRD-VECTOR-OFFSET-TILES ux))
                (+ base-y (* SC2-THIRD-VECTOR-OFFSET-TILES uy)))))
  (define-values (fourth-x fourth-y)
    (if (>= (length ordered-home-exps) 3)
        (let ([b (third ordered-home-exps)])
          (values (hash-ref b 'x) (hash-ref b 'y)))
        (values (+ third-x (* 12.0 ux))
                (+ third-y (* 12.0 uy)))))
  (define-values (enemy-nat-x enemy-nat-y)
    (if (>= (length ordered-enemy-exps) 1)
        (let ([b (first ordered-enemy-exps)])
          (values (hash-ref b 'x) (hash-ref b 'y)))
        (values (- enemy-x (* SC2-NATURAL-VECTOR-OFFSET-TILES ux))
                (- enemy-y (* SC2-NATURAL-VECTOR-OFFSET-TILES uy)))))
  (define-values (enemy-third-x enemy-third-y)
    (if (>= (length ordered-enemy-exps) 2)
        (let ([b (second ordered-enemy-exps)])
          (values (hash-ref b 'x) (hash-ref b 'y)))
        (values (- enemy-x (* SC2-THIRD-VECTOR-OFFSET-TILES ux))
                (- enemy-y (* SC2-THIRD-VECTOR-OFFSET-TILES uy)))))
  (define-values (enemy-fourth-x enemy-fourth-y)
    (if (>= (length ordered-enemy-exps) 3)
        (let ([b (third ordered-enemy-exps)])
          (values (hash-ref b 'x) (hash-ref b 'y)))
        (values (- enemy-third-x (* 12.0 ux))
                (- enemy-third-y (* 12.0 uy)))))

  ;; Safe live mineral patch tag for Orbital Command MULE calldowns (`0` when no safe completed base patch exists)
  (define safe-mule-patch-id
    (pick-safe-mule-mineral-patch #f self-units mineral-fields enemy-all))
  (define closest-mineral-patch-id
    (cond
      [(not (null? my-townhalls)) safe-mule-patch-id]
      [(not (null? mineral-fields))
       (sc2-unit-tag
        (argmin (lambda (m)
                  (define mp (sc2-unit-pos m))
                  (pt-dist base-x base-y (sc2-point3d-x mp) (sc2-point3d-y mp)))
                mineral-fields))]
      [else 0]))

  ;; Pending supply (Overlord eggs / in-progress Depots / in-progress Pylons / in-transit worker build orders)
  (define in-progress-pylons
    (filter (lambda (u)
              (and (memq (sc2-id->unit-symbol (sc2-unit-unit-type u))
                         '(pylon pylon-overcharged))
                   (< (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)))
            self-units))
  (define in-progress-depots
    (filter (lambda (u)
              (and (memq (sc2-id->unit-symbol (sc2-unit-unit-type u))
                         '(supply-depot supply-depot-lowered))
                   (< (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)))
            self-units))
  (define active-depot-worker-orders
    (for/sum ([w (in-list my-workers)]
              #:when (not (worker-build-order-stuck? w cur-loop)))
      (count (lambda (o) (= (sc2-unit-order-ability-id o) 319))
             (sc2-unit-orders w))))
  (define in-transit-pylon-worker-orders
    (for*/sum ([w (in-list my-workers)]
               #:when (not (worker-build-order-stuck? w cur-loop))
               [o (in-list (sc2-unit-orders w))]
               #:when (= (sc2-unit-order-ability-id o) 881))
      (define tp (sc2-unit-order-target-pos o))
      (if (and (any-point? tp)
               (ormap (lambda (p)
                        (define pp (sc2-unit-pos p))
                        (<= (pt-dist (any-point-x tp) (any-point-y tp)
                                     (sc2-point3d-x pp) (sc2-point3d-y pp))
                            2.5))
                      in-progress-pylons))
          0
          1)))
  (define pending-supply
    (+ (length in-progress-pylons)
       in-transit-pylon-worker-orders
       (if (> active-depot-worker-orders 0)
           active-depot-worker-orders
           (if (or (null? my-workers) (< cur-loop 8))
               (length in-progress-depots)
               0))
       (for/sum ([u (in-list self-units)]
                 #:when (= (sc2-unit-unit-type u) 103)) ;; EGG
         (if (ormap (lambda (o) (= (sc2-unit-order-ability-id o) 1344))
                    (sc2-unit-orders u))
             1
             0))))

  ;; Pending workers (all queued SCV / Probe train orders + Drone eggs)
  (define pending-workers
    (+ (for/sum ([th (in-list ready-townhalls)])
         (count (lambda (o)
                  (memv (sc2-unit-order-ability-id o) '(524 1006))) ;; TRAIN_SCV=524, TRAIN_PROBE=1006
                (sc2-unit-orders th)))
       (for/sum ([u (in-list self-units)]
                 #:when (and (= (sc2-unit-unit-type u) 103)
                             (ormap (lambda (o) (= (sc2-unit-order-ability-id o) 1342))
                                    (sc2-unit-orders u)))) ;; TRAIN_DRONE=1342
         1)))

  ;; Mature unused burrowed creep tumors strictly restricted to `unit-type = 137` (`creep-tumor-burrowed`)
  (define ally-creep-tumor-records
    (for/list ([u (in-list self-units)]
               #:when (and (= (sc2-unit-unit-type u) 137)
                           (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)
                           (not (set-member? used-tumors (sc2-unit-tag u)))))
      (define p (sc2-unit-pos u))
      (hash 'id (sc2-unit-tag u)
            'type 'creep-tumor-burrowed
            'x (sc2-point3d-x p)
            'y (sc2-point3d-y p)
            'z (sc2-point3d-z p)
            'hp (max 1 (exact-round (sc2-unit-health u)))
            'energy 0
            'is-burrowed #t
            'burrowed #t
            'is-hallucination #f
            'hallucination #f
            'cloak (sc2-unit-cloak u)
            'engaged-target-tag (sc2-unit-engaged-target-tag u)
            'buffs '())))

  ;; Convert ally mobile units (plus ready unused mature creep tumors for tumor spread!)
  (define ally-unit-records
    (append
     (for/list ([u (in-list self-units)]
                #:when (and (not (sc2-unit-is-structure? u))
                            (not (memq (sc2-id->unit-symbol (sc2-unit-unit-type u))
                                       '(larva egg)))))
       (define p (sc2-unit-pos u))
       (define utype-sym (sc2-id->unit-symbol (sc2-unit-unit-type u)))
       (define ords (sc2-unit-orders u))
       (define ord0 (and (pair? ords) (first ords)))
       (define ord0-pos (and ord0 (sc2-unit-order-target-pos ord0)))
       (define u-buffs
         (filter-map (lambda (bid) (buff-id->symbol bid #f))
                     (sc2-unit-buff-ids u)))
       (define build-ord
         (and (not (worker-build-order-stuck? u cur-loop))
              (findf (lambda (o)
                       (define s (sc2-id->ability-symbol (sc2-unit-order-ability-id o) #f))
                       (and s (string-prefix? (symbol->string s) "build-")))
                     ords)))
       (define build-target-sym
         (and build-ord
              (let* ([s (sc2-id->ability-symbol (sc2-unit-order-ability-id build-ord) #f)]
                     [st (if s (symbol->string s) "")])
                (and (string-prefix? st "build-")
                     (sc2-canonical-structure-sym (string->symbol (substring st 6)))))))
       (define is-halluc? (sc2-unit-is-hallucination u))
       (define is-burr? (sc2-unit-is-burrowed u))
       (define cloak-st (sc2-unit-cloak u))
       (define raw-pax (sc2-unit-passengers u))
       (define pax-hashes
         (if (null? raw-pax) '() (map sc2-passenger-unit->runtime-hash raw-pax)))
       (define eff-cargo-taken
         (max (sc2-unit-cargo-space-taken u) (length raw-pax)))
       (hash 'id (sc2-unit-tag u)
             'type utype-sym
             'x (sc2-point3d-x p)
             'y (sc2-point3d-y p)
             'z (sc2-point3d-z p)
             'hp (max 1 (exact-round (+ (sc2-unit-health u) (sc2-unit-shield u))))
             'hull-hp (max 1 (exact-round (sc2-unit-health u)))
             'max-hp (max 1 (exact-round (+ (sc2-unit-health-max u) (sc2-unit-shield-max u))))
             'shield (max 0 (exact-round (sc2-unit-shield u)))
             'energy (max 0 (exact-round (sc2-unit-energy u)))
             'energy-max (max 0 (exact-round (sc2-unit-energy-max u)))
             'cargo-space-taken eff-cargo-taken
             'cargo-space-max (sc2-unit-cargo-space-max u)
             'passengers pax-hashes
             'flying? (sc2-unit-is-flying u)
             'cloak cloak-st
             'cloaked (or (= cloak-st 1) (= cloak-st 2))
             'is-burrowed is-burr?
             'burrowed is-burr?
             'is-hallucination is-halluc?
             'hallucination is-halluc?
             'sieged (not (not (memq utype-sym '(siege-tank-sieged liberator-ag widow-mine-burrowed lurker-burrowed lurker-mp-burrowed))))
             'facing (sc2-unit-facing u)
             'radius (sc2-unit-radius u)
             'weapon-cooldown (sc2-weapon-cooldown-loops->seconds (sc2-unit-weapon-cooldown u))
             'engaged-target-tag (sc2-unit-engaged-target-tag u)
             'buffs u-buffs
             'orders
             (for/list ([o (in-list ords)])
               (define o-aid (sc2-unit-order-ability-id o))
               (define o-ab (sc2-id->ability-symbol o-aid #f))
               (define o-pos (sc2-unit-order-target-pos o))
               (define ox (and (any-point? o-pos) (any-point-x o-pos)))
               (define oy (and (any-point? o-pos) (any-point-y o-pos)))
               (hasheq 'ability_id o-aid
                       'ability o-ab
                       'ability-id o-aid
                       'ability-sym o-ab
                       'target_x ox
                       'target_y oy
                       'tx ox
                       'ty oy
                       'target_tag (sc2-unit-order-target-unit-tag o)
                       'progress (sc2-unit-order-progress o)))
             'order-count (length ords)
             'order-ability-id (if ord0 (sc2-unit-order-ability-id ord0) 0)
             'order-ability-sym (if ord0 (sc2-id->ability-symbol (sc2-unit-order-ability-id ord0) #f) #f)
             'order-target-id (if ord0 (sc2-unit-order-target-unit-tag ord0) 0)
             'order-target-x (and (any-point? ord0-pos) (any-point-x ord0-pos))
             'order-target-y (and (any-point? ord0-pos) (any-point-y ord0-pos))
             'order-progress (if ord0 (sc2-unit-order-progress ord0) 0.0)
             'has-build-order? (not (not build-ord))
             'build-target build-target-sym))
     ally-creep-tumor-records))

  ;; Convert ally buildings (plus in-transit worker build orders across ALL queued worker orders
  ;; so buildings aren't spammed while the worker finishes a mineral return or walks to the site)
  (define in-transit-bldg-records
    (append*
     (for/list ([w (in-list my-workers)]
                #:when (and (pair? (sc2-unit-orders w))
                            (not (worker-build-order-stuck? w cur-loop))))
       (define wp (sc2-unit-pos w))
       (define wx (sc2-point3d-x wp))
       (define wy (sc2-point3d-y wp))
       (define wz (sc2-point3d-z wp))
       (define build-ords
         (filter (lambda (o)
                   (define s (sc2-id->ability-symbol (sc2-unit-order-ability-id o) #f))
                   (and s (string-prefix? (symbol->string s) "build-")))
                 (sc2-unit-orders w)))
       (filter-map
        (lambda (ord b-idx)
          (define ab-id (sc2-unit-order-ability-id ord))
          (define ab-sym (sc2-id->ability-symbol ab-id #f))
          (define ab-str (if ab-sym (symbol->string ab-sym) ""))
          (define bsym (sc2-canonical-structure-sym (string->symbol (substring ab-str 6))))
          (define tpos (sc2-unit-order-target-pos ord))
          (define tgt-tag (sc2-unit-order-target-unit-tag ord))
          (define tx (if (any-point? tpos) (any-point-x tpos) wx))
          (define ty (if (any-point? tpos) (any-point-y tpos) wy))
          ;; Synthesize only while no under-construction footprint of an equivalent type exists at (tx, ty)
          (and (not (ormap (lambda (b)
                             (define bp (sc2-unit-pos b))
                             (and (sc2-structure-matches-target?
                                   (sc2-id->unit-symbol (sc2-unit-unit-type b))
                                   bsym)
                                  (< (sc2-unit-build-progress b) SC2-BUILD-COMPLETE-PROGRESS)
                                  (or (= tgt-tag (sc2-unit-tag b))
                                      (<= (pt-dist tx ty (sc2-point3d-x bp) (sc2-point3d-y bp)) 6.0)
                                      (<= (pt-dist wx wy (sc2-point3d-x bp) (sc2-point3d-y bp)) 6.0))))
                           self-units))
               (hash 'id (+ 9000000 (* b-idx 100000) (sc2-unit-tag w))
                     'type bsym
                     'x tx
                     'y ty
                     'z wz
                     'hp SC2-PYLON-HULL-MAX-HP
                     'max-hp (max 500 SC2-PYLON-HULL-MAX-HP)
                     'hp-pct 1.0
                     'build-progress SC2-IN-TRANSIT-BUILD-PROGRESS
                     'vespene-contents 2250
                     'in-transit? #t
                     'powered? #t
                     'addon-ready? #f
                     'orders '()
                     'halted #f
                     'buffs '())))
        build-ords
        (range (length build-ords))))))

  (define sorted-self-structures
    (sort-townhalls-main-first (filter sc2-unit-is-structure? self-units)))
  (define ally-bldg-records
    (append
     (for/list ([b (in-list sorted-self-structures)])
       (define p (sc2-unit-pos b))
       (define bx (sc2-point3d-x p))
       (define by (sc2-point3d-y p))
       (define bz (sc2-point3d-z p))
       (define bsym (sc2-id->unit-symbol (sc2-unit-unit-type b)))
       (define bprog (max 0.0 (min 1.0 (sc2-unit-build-progress b))))
       (define hp-max (max 1.0 (+ (sc2-unit-health-max b) (sc2-unit-shield-max b))))
       (define cur-hp+sh (+ (sc2-unit-health b) (sc2-unit-shield b)))
       (define raw-pct (/ cur-hp+sh hp-max))
       (define expected-frac (+ 0.10 (* 0.90 bprog)))
       (define eff-hp-pct
         (if (< bprog SC2-BUILD-COMPLETE-PROGRESS)
             (min 1.0 (/ raw-pct (max 0.10 expected-frac)))
             raw-pct))
       (define halted?
         (and (eq? actual-race 'Terran)
              (< bprog SC2-BUILD-COMPLETE-PROGRESS)
              (not (memq bsym '(barracks-tech-lab barracks-techlab barracks-reactor
                                factory-tech-lab factory-techlab factory-reactor
                                starport-tech-lab starport-techlab starport-reactor
                                orbital-command planetary-fortress)))
              (not (ormap (lambda (w)
                            (define wp (sc2-unit-pos w))
                            (<= (pt-dist bx by (sc2-point3d-x wp) (sc2-point3d-y wp))
                                SC2-TERRAN-BUILDER-RADIUS))
                          my-workers))))
       (define addon-tag (sc2-unit-add-on-tag b))
       (define addon-unit
         (and (> addon-tag 0)
              (for/first ([au (in-list self-units)] #:when (= (sc2-unit-tag au) addon-tag)) au)))
       (define addon-sym
         (and addon-unit (sc2-id->unit-symbol (sc2-unit-unit-type addon-unit))))
       (define addon-ready?
         (and (not (not addon-unit))
              (>= (sc2-unit-build-progress addon-unit) SC2-BUILD-COMPLETE-PROGRESS)))
       (define raw-addon-kind
         (cond
           [(memq addon-sym '(barracks-reactor factory-reactor starport-reactor reactor)) 'reactor]
           [(memq addon-sym '(barracks-tech-lab barracks-techlab
                              factory-tech-lab factory-techlab
                              starport-tech-lab starport-techlab tech-lab techlab)) 'techlab]
           [else #f]))
       (define addon-kind
         (cond
           [(not raw-addon-kind) #f]
           [addon-ready? raw-addon-kind]
           [else 'addon-building]))
       (define b-ords (sc2-unit-orders b))
       (define b-ord0 (and (pair? b-ords) (first b-ords)))
       (define b-order-records
         (for/list ([o (in-list b-ords)])
           (define o-aid (sc2-unit-order-ability-id o))
           (define o-pos (sc2-unit-order-target-pos o))
           (hasheq 'ability-id o-aid
                   'ability-sym (sc2-id->ability-symbol o-aid #f)
                   'target-id (sc2-unit-order-target-unit-tag o)
                   'target-x (and (any-point? o-pos) (any-point-x o-pos))
                   'target-y (and (any-point? o-pos) (any-point-y o-pos))
                   'progress (sc2-unit-order-progress o))))
       (define wg-busy?
         (and (= (sc2-unit-unit-type b) 133)
              (< cur-loop (hash-ref SC2-WARPGATE-COOLDOWN-UNTIL (sc2-unit-tag b) 0))))
       (define eff-order-count (if wg-busy? (max 1 (length b-ords)) (length b-ords)))
       (define b-buffs
         (filter-map (lambda (bid) (buff-id->symbol bid #f))
                     (sc2-unit-buff-ids b)))
       (define eff-vespene-contents
         (if (and (sc2-unit-is-gas-building? b)
                  (< bprog SC2-BUILD-COMPLETE-PROGRESS)
                  (= (sc2-unit-vespene-contents b) 0))
             2250
             (sc2-unit-vespene-contents b)))
       (hash 'id (sc2-unit-tag b)
             'type bsym
             'x bx
             'y by
             'z bz
             'hp (max 1 (exact-round cur-hp+sh))
             'max-hp (max 1 (exact-round hp-max))
             'hp-pct eff-hp-pct
             'energy (exact-round (sc2-unit-energy b))
             'energy-max (max 0 (exact-round (sc2-unit-energy-max b)))
             'cargo-space-taken (max (sc2-unit-cargo-space-taken b)
                                     (length (sc2-unit-passengers b)))
             'cargo-space-max (sc2-unit-cargo-space-max b)
             'passengers (if (null? (sc2-unit-passengers b))
                             '()
                             (map sc2-passenger-unit->runtime-hash (sc2-unit-passengers b)))
             'build-progress bprog
             'vespene-contents eff-vespene-contents
             'halted halted?
             'flying? (sc2-unit-is-flying b)
             'is-burrowed (sc2-unit-is-burrowed b)
             'burrowed (sc2-unit-is-burrowed b)
             'cloak (sc2-unit-cloak b)
             'engaged-target-tag (sc2-unit-engaged-target-tag b)
             'powered? (if (sc2-structure-requires-pylon-power? bsym)
                           (sc2-unit-is-powered b)
                           #t)
             'has-addon? (> addon-tag 0)
             'add-on-tag addon-tag
             'addon addon-kind
             'addon-ready? addon-ready?
             'addon-type addon-sym
             'buffs b-buffs
             'orders b-order-records
             'order-count eff-order-count
             'busy? (or wg-busy? (>= eff-order-count (if (eq? addon-kind 'reactor) 2 1)))
             'order-ability-id (if b-ord0 (sc2-unit-order-ability-id b-ord0) 0)
             'order-ability-sym (if b-ord0 (sc2-id->ability-symbol (sc2-unit-order-ability-id b-ord0) #f) #f)))
     in-transit-bldg-records))

  ;; Enemy units & buildings (including subtle shimmer / display_type = Hidden (2), hallucination, cloak & burrow)
  (define enemy-unit-records
    (for/list ([eu (in-list enemy-all)]
               #:when (not (sc2-unit-is-structure? eu)))
      (define p (sc2-unit-pos eu))
      (define utype (sc2-id->unit-symbol (sc2-unit-unit-type eu)))
      (define disp-type (sc2-unit-display-type eu))
      (define cloak-st (sc2-unit-cloak eu))
      (define is-halluc? (sc2-unit-is-hallucination eu))
      (define is-burr? (sc2-unit-is-burrowed eu))
      (define shimmer?
        (or (= disp-type SC2-SHIMMER-DISPLAY-TYPE-HIDDEN)
            (= cloak-st 2)))
      (define changeling?
        (not (not (memq utype SC2-CHANGELING-UNIT-SYMS))))
      (hash 'id (sc2-unit-tag eu)
            'type utype
            'x (sc2-point3d-x p)
            'y (sc2-point3d-y p)
            'z (sc2-point3d-z p)
            'hp (max 1 (exact-round (+ (sc2-unit-health eu) (sc2-unit-shield eu))))
            'hull-hp (max 1 (exact-round (sc2-unit-health eu)))
            'max-hp (max 1 (exact-round (+ (sc2-unit-health-max eu) (sc2-unit-shield-max eu))))
            'shield (max 0 (exact-round (sc2-unit-shield eu)))
            'energy (max 0 (exact-round (sc2-unit-energy eu)))
            'energy-max (max 0 (exact-round (sc2-unit-energy-max eu)))
            'build-progress (max 0.0 (min 1.0 (sc2-unit-build-progress eu)))
            'flying? (sc2-unit-is-flying eu)
            'display-type disp-type
            'cloak cloak-st
            'cloak-state cloak-st
            'is-shimmer? shimmer?
            'changeling? changeling?
            'is-hallucination is-halluc?
            'hallucination is-halluc?
            'cloaked (or (= cloak-st 1) (= cloak-st 2) shimmer?)
            'is-burrowed is-burr?
            'burrowed is-burr?
            'facing (sc2-unit-facing eu)
            'radius (sc2-unit-radius eu)
            'buffs (filter-map (lambda (bid) (buff-id->symbol bid #f))
                               (sc2-unit-buff-ids eu))
            'weapon-cooldown (sc2-weapon-cooldown-loops->seconds (sc2-unit-weapon-cooldown eu))
            'engaged-target-tag (sc2-unit-engaged-target-tag eu)
            'attack-upgrade-level (sc2-unit-attack-upgrade-level eu)
            'armor-upgrade-level (sc2-unit-armor-upgrade-level eu)
            'shield-upgrade-level (sc2-unit-shield-upgrade-level eu))))

  (define shimmer-and-burrow-ripples
    (filter (lambda (eu)
              (or (hash-ref eu 'is-shimmer? #f)
                  (hash-ref eu 'burrowed #f)))
            enemy-unit-records))

  (define attached-addon-tags
    (list->seteqv
     (filter (lambda (t) (> t 0))
             (map (lambda (b) (hash-ref b 'add-on-tag 0)) ally-bldg-records))))
  (define free-addons
    (filter (lambda (b)
              (and (memq (hash-ref b 'type 'unknown)
                         '(barracks-techlab barracks-tech-lab barracks-reactor
                           factory-techlab factory-tech-lab factory-reactor
                           starport-techlab starport-tech-lab starport-reactor
                           tech-lab techlab reactor))
                   (>= (hash-ref b 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS)
                   (not (set-member? attached-addon-tags (hash-ref b 'id 0)))))
            ally-bldg-records))

  (define enemy-bldg-records
    (for/list ([eb (in-list enemy-all)]
               #:when (sc2-unit-is-structure? eb))
      (define p (sc2-unit-pos eb))
      (define ebx (sc2-point3d-x p))
      (define eby (sc2-point3d-y p))
      (define btype (sc2-id->unit-symbol (sc2-unit-unit-type eb)))
      (define disp-type (sc2-unit-display-type eb))
      (define cloak-st (sc2-unit-cloak eb))
      (define is-halluc? (sc2-unit-is-hallucination eb))
      (define is-burr? (sc2-unit-is-burrowed eb))
      (define canon-btype (sc2-canonical-structure-sym btype))
      (define is-proxy?
        (and (not is-halluc?)
             (not (and (>= cur-loop 3360)
                       (set-member? SC2-TOWNHALL-STRUCTURE-SYMS canon-btype)))
             (enemy-structure-is-proxy? btype ebx eby
                                        enemy-x enemy-y
                                        enemy-nat-x enemy-nat-y
                                        enemy-third-x enemy-third-y)))
      (define eb-hp (max 1 (exact-round (sc2-unit-health eb))))
      (define eb-raw-max (exact-round (sc2-unit-health-max eb)))
      (define eb-max-hp (if (> eb-raw-max 0) eb-raw-max (max 500 eb-hp)))
      (define eb-hp-pct (max 0.0 (min 1.0 (/ (exact->inexact eb-hp) (exact->inexact eb-max-hp)))))
      (hash 'id (sc2-unit-tag eb)
            'type btype
            'x ebx
            'y eby
            'z (sc2-point3d-z p)
            'hp eb-hp
            'max-hp eb-max-hp
            'hp-pct eb-hp-pct
            'build-progress (max 0.0 (min 1.0 (sc2-unit-build-progress eb)))
            'display-type disp-type
            'snapshot? (not (= disp-type 1))
            'cloak cloak-st
            'cloaked (or (= cloak-st 1) (= cloak-st 2))
            'is-burrowed is-burr?
            'burrowed is-burr?
            'is-hallucination is-halluc?
            'hallucination is-halluc?
            'is-proxy? is-proxy?
            'vespene-contents (sc2-unit-vespene-contents eb)
            'active? (sc2-unit-is-active eb)
            'add-on-tag (sc2-unit-add-on-tag eb)
            'buffs (filter-map (lambda (bid) (buff-id->symbol bid #f))
                               (sc2-unit-buff-ids eb))
            'engaged-target-tag (sc2-unit-engaged-target-tag eb))))
  (define enemy-proxy-bldg-records
    (filter (lambda (eb) (eq? (hash-ref eb 'is-proxy? #f) #t)) enemy-bldg-records))

  ;; Persistent effects
  (define effect-records
    (apply append
           (for/list ([eff (in-list (sc2-observation-effects obs))])
             (define esym (effect-id->symbol (sc2-effect-effect-id eff)))
             (for/list ([pt (in-list (sc2-effect-positions eff))])
               (hash 'type (if (memq esym '(temporal-field temporal-field-growing)) 'force-field esym)
                     'x (sc2-point2d-x pt)
                     'y (sc2-point2d-y pt))))))

  ;; Expand upgrade aliases so both canonical and short names are recognized
  (define (expand-upgrade-aliases upgs)
    (remove-duplicates
     (append*
      (for/list ([u (in-list upgs)])
        (case u
          [(warpgate warp-gate warp-gate-research warpgate-research)
           '(warpgate warp-gate warp-gate-research warpgate-research)]
          [(zergling-movementspeed metabolic-boost) '(zergling-movementspeed metabolic-boost)]
          [(zergling-attackspeed adrenal-glands) '(zergling-attackspeed adrenal-glands)]
          [(centrifugal-hooks centrifical-hooks) '(centrifugal-hooks centrifical-hooks)]
          [(lurker-range seismic-spines) '(lurker-range seismic-spines)]
          [(overlord-speed pneumatized-carapace) '(overlord-speed pneumatized-carapace)]
          [(zerg-melee-weapons-1 melee-attacks-1) '(zerg-melee-weapons-1 melee-attacks-1)]
          [(zerg-melee-weapons-2 melee-attacks-2) '(zerg-melee-weapons-2 melee-attacks-2)]
          [(zerg-melee-weapons-3 melee-attacks-3) '(zerg-melee-weapons-3 melee-attacks-3)]
          [(zerg-missile-weapons-1 missile-attacks-1) '(zerg-missile-weapons-1 missile-attacks-1)]
          [(zerg-missile-weapons-2 missile-attacks-2) '(zerg-missile-weapons-2 missile-attacks-2)]
          [(zerg-missile-weapons-3 missile-attacks-3) '(zerg-missile-weapons-3 missile-attacks-3)]
          [(zerg-ground-armor-1 zerg-ground-carapace-1 ground-carapace-1)
           '(zerg-ground-armor-1 zerg-ground-carapace-1 ground-carapace-1)]
          [(zerg-ground-armor-2 zerg-ground-carapace-2 ground-carapace-2)
           '(zerg-ground-armor-2 zerg-ground-carapace-2 ground-carapace-2)]
          [(zerg-ground-armor-3 zerg-ground-carapace-3 ground-carapace-3)
           '(zerg-ground-armor-3 zerg-ground-carapace-3 ground-carapace-3)]
          [(zerg-flyer-weapons-1 flyer-attacks-1) '(zerg-flyer-weapons-1 flyer-attacks-1)]
          [(zerg-flyer-weapons-2 flyer-attacks-2) '(zerg-flyer-weapons-2 flyer-attacks-2)]
          [(zerg-flyer-weapons-3 flyer-attacks-3) '(zerg-flyer-weapons-3 flyer-attacks-3)]
          [(zerg-flyer-armor-1 zerg-flyer-carapace-1 flyer-carapace-1)
           '(zerg-flyer-armor-1 zerg-flyer-carapace-1 flyer-carapace-1)]
          [(zerg-flyer-armor-2 zerg-flyer-carapace-2 flyer-carapace-2)
           '(zerg-flyer-armor-2 zerg-flyer-carapace-2 flyer-carapace-2)]
          [(zerg-flyer-armor-3 zerg-flyer-carapace-3 flyer-carapace-3)
           '(zerg-flyer-armor-3 zerg-flyer-carapace-3 flyer-carapace-3)]
          [(infernal-preigniter infernal-pre-igniter) '(infernal-preigniter infernal-pre-igniter)]
          [(banshee-cloak cloaking-field) '(banshee-cloak cloaking-field)]
          [(terran-infantry-weapons-1 infantry-weapons-1) '(terran-infantry-weapons-1 infantry-weapons-1)]
          [(terran-infantry-weapons-2 infantry-weapons-2) '(terran-infantry-weapons-2 infantry-weapons-2)]
          [(terran-infantry-weapons-3 infantry-weapons-3) '(terran-infantry-weapons-3 infantry-weapons-3)]
          [(terran-infantry-armor-1 infantry-armor-1) '(terran-infantry-armor-1 infantry-armor-1)]
          [(terran-infantry-armor-2 infantry-armor-2) '(terran-infantry-armor-2 infantry-armor-2)]
          [(terran-infantry-armor-3 infantry-armor-3) '(terran-infantry-armor-3 infantry-armor-3)]
          [(terran-vehicle-weapons-1 vehicle-weapons-1) '(terran-vehicle-weapons-1 vehicle-weapons-1)]
          [(terran-vehicle-weapons-2 vehicle-weapons-2) '(terran-vehicle-weapons-2 vehicle-weapons-2)]
          [(terran-vehicle-weapons-3 vehicle-weapons-3) '(terran-vehicle-weapons-3 vehicle-weapons-3)]
          [(terran-vehicle-plating-1 terran-vehicle-and-ship-plating-1 vehicle-and-ship-plating-1)
           '(terran-vehicle-plating-1 terran-vehicle-and-ship-plating-1 vehicle-and-ship-plating-1)]
          [(terran-vehicle-plating-2 terran-vehicle-and-ship-plating-2 vehicle-and-ship-plating-2)
           '(terran-vehicle-plating-2 terran-vehicle-and-ship-plating-2 vehicle-and-ship-plating-2)]
          [(terran-vehicle-plating-3 terran-vehicle-and-ship-plating-3 vehicle-and-ship-plating-3)
           '(terran-vehicle-plating-3 terran-vehicle-and-ship-plating-3 vehicle-and-ship-plating-3)]
          [(terran-ship-weapons-1 ship-weapons-1) '(terran-ship-weapons-1 ship-weapons-1)]
          [(terran-ship-weapons-2 ship-weapons-2) '(terran-ship-weapons-2 ship-weapons-2)]
          [(terran-ship-weapons-3 ship-weapons-3) '(terran-ship-weapons-3 ship-weapons-3)]
          [(psi-storm psistorm psistorm-tech psi-storm-tech)
           '(psi-storm psistorm psistorm-tech psi-storm-tech)]
          [(blink blink-tech) '(blink blink-tech)]
          [(shadow-strike shadow-stride) '(shadow-strike shadow-stride)]
          [(gravitic-booster gravitic-boosters) '(gravitic-booster gravitic-boosters)]
          [(resonating-glaives adept-piercing-attack) '(resonating-glaives adept-piercing-attack)]
          [(protoss-ground-weapons-1 ground-weapons-1) '(protoss-ground-weapons-1 ground-weapons-1)]
          [(protoss-ground-weapons-2 ground-weapons-2) '(protoss-ground-weapons-2 ground-weapons-2)]
          [(protoss-ground-weapons-3 ground-weapons-3) '(protoss-ground-weapons-3 ground-weapons-3)]
          [(protoss-ground-armor-1 ground-armor-1) '(protoss-ground-armor-1 ground-armor-1)]
          [(protoss-ground-armor-2 ground-armor-2) '(protoss-ground-armor-2 ground-armor-2)]
          [(protoss-ground-armor-3 ground-armor-3) '(protoss-ground-armor-3 ground-armor-3)]
          [(protoss-shields-1 shields-1) '(protoss-shields-1 shields-1)]
          [(protoss-shields-2 shields-2) '(protoss-shields-2 shields-2)]
          [(protoss-shields-3 shields-3) '(protoss-shields-3 shields-3)]
          [(protoss-air-weapons-1 air-weapons-1) '(protoss-air-weapons-1 air-weapons-1)]
          [(protoss-air-weapons-2 air-weapons-2) '(protoss-air-weapons-2 air-weapons-2)]
          [(protoss-air-weapons-3 air-weapons-3) '(protoss-air-weapons-3 air-weapons-3)]
          [(protoss-air-armor-1 air-armor-1) '(protoss-air-armor-1 air-armor-1)]
          [(protoss-air-armor-2 air-armor-2) '(protoss-air-armor-2 air-armor-2)]
          [(protoss-air-armor-3 air-armor-3) '(protoss-air-armor-3 air-armor-3)]
          [else (list u)])))))

  ;; Researched & pending upgrades
  (define researched-upgrades
    (expand-upgrade-aliases
     (filter-map (lambda (uid) (sc2-id->upgrade-symbol uid #f))
                 (sc2-observation-upgrade-ids obs))))

  (define pending-upgrades
    (expand-upgrade-aliases
     (append*
      (for/list ([b (in-list self-units)]
                 #:when (sc2-unit-is-structure? b))
        (filter-map
         (lambda (o)
           (define ab-id (sc2-unit-order-ability-id o))
           (define ab-sym (sc2-id->ability-symbol ab-id #f))
           (define ab-str (if ab-sym (symbol->string ab-sym) ""))
           (cond
             [(string-prefix? ab-str "research-")
              (string->symbol (substring ab-str 9))]
             [(eq? ab-sym 'weapon-refit)
              'weapon-refit]
             [else #f]))
         (sc2-unit-orders b))))))

  ;; Stasis-frozen friendly unit & worker tracking (Oracle Stasis Ward buff 57 = 21.4s / 480 frames)
  (define (unit-record-stasis-frozen? u)
    (define bfs (hash-ref u 'buffs '()))
    (or (memq 'oracle-stasis-trap-target bfs)
        (memq 'stasis-ward-target bfs)))
  (define stasis-frozen-unit-ids
    (for/list ([u (in-list ally-unit-records)]
               #:when (unit-record-stasis-frozen? u))
      (hash-ref u 'id 0)))
  (define stasis-frozen-worker-count
    (for/sum ([u (in-list ally-unit-records)]
              #:when (and (memq (hash-ref u 'type 'unknown) '(drone probe scv))
                          (unit-record-stasis-frozen? u)))
      1))

  (define mineral-patch-records
    (for/list ([m (in-list mineral-fields)])
      (define mp (sc2-unit-pos m))
      (define mtype (sc2-unit-unit-type m))
      (hash 'id (sc2-unit-tag m)
            'type (sc2-id->unit-symbol mtype 'mineral-field)
            'unit-type-id mtype
            'x (sc2-point3d-x mp)
            'y (sc2-point3d-y mp)
            'minerals (sc2-unit-mineral-contents m))))

  (define geyser-records
    (for/list ([u (in-list live-resource-units)]
               #:when (sc2-unit-is-vespene-geyser? u))
      (define gp (sc2-unit-pos u))
      (define gtype (sc2-unit-unit-type u))
      (hash 'id (sc2-unit-tag u)
            'type (sc2-id->unit-symbol gtype 'vespene-geyser)
            'unit-type-id gtype
            'x (sc2-point3d-x gp)
            'y (sc2-point3d-y gp)
            'vespene-contents (sc2-unit-vespene-contents u))))

  ;; Harvester & depletion metrics (deduct stasis-frozen workers from active mineral-harvesters
  ;; so the economy layer immediately trains/transfers replacement workers during a 21.4s stasis freeze!)
  (define raw-min-harvesters
    (for/sum ([th (in-list ready-townhalls)])
      (max 0 (sc2-unit-assigned-harvesters th))))
  (define min-harvesters
    (max 0 (- raw-min-harvesters stasis-frozen-worker-count)))
  (define ideal-min-harvesters
    (for/sum ([th (in-list ready-townhalls)])
      (max 0 (let ([ih (sc2-unit-ideal-harvesters th)])
               (if (> ih 0) ih SC2-IDEAL-WORKERS-PER-MINERAL-LINE)))))
  (define gas-harvesters
    (for/sum ([gb (in-list ready-gas-bldgs)])
      (max 0 (sc2-unit-assigned-harvesters gb))))
  (define ideal-gas-harvesters
    (for/sum ([gb (in-list ready-gas-bldgs)])
      (max 0 (let ([ih (sc2-unit-ideal-harvesters gb)])
               (if (> ih 0) ih SC2-IDEAL-WORKERS-PER-GEYSER)))))

  (define depleting-bases
    (for/sum ([th (in-list ready-townhalls)])
      (define p (sc2-unit-pos th))
      (define close-mins
        (filter (lambda (m)
                  (define mp (sc2-unit-pos m))
                  (<= (pt-dist (sc2-point3d-x p) (sc2-point3d-y p)
                               (sc2-point3d-x mp) (sc2-point3d-y mp))
                      SC2-BASE-RESOURCE-RADIUS))
                mineral-fields))
      (define rem-min (for/sum ([m (in-list close-mins)]) (sc2-unit-mineral-contents m)))
      ;; Proactive 90s pre-depletion trigger (< 2,400M remaining) so replacement TownHall finishes before mining out!
      (if (and (not (null? close-mins)) (< rem-min SC2-PRE-DEPLETION-PROACTIVE-MINERAL-THRESH)) 1 0)))

  (define pre-depleting-bases depleting-bases)

  (define busy-facilities
    (for/sum ([b (in-list self-units)]
              #:when (and (set-member? PRODUCTION-FACILITY-SYMS
                                       (sc2-id->unit-symbol (sc2-unit-unit-type b)))
                          (>= (sc2-unit-build-progress b) SC2-BUILD-COMPLETE-PROGRESS)
                          (or (pair? (sc2-unit-orders b))
                              (and (= (sc2-unit-unit-type b) 133)
                                   (< cur-loop (hash-ref SC2-WARPGATE-COOLDOWN-UNTIL (sc2-unit-tag b) 0))))))
      1))

  (define busy-townhalls
    (for/sum ([th (in-list ready-townhalls)]
              #:when (pair? (sc2-unit-orders th)))
      1))

  ;; Deduct unpaid mineral/gas cost of walking builders in `in-transit-bldg-records`
  ;; because SC2 does not deduct building cost from `player_common` until the worker arrives at the build site!
  (define in-transit-min-cost
    (for/sum ([b (in-list in-transit-bldg-records)])
      (sc2-min-cost (hash-ref b 'type 'pylon) 0)))
  (define in-transit-gas-cost
    (for/sum ([b (in-list in-transit-bldg-records)])
      (sc2-gas-cost (hash-ref b 'type 'pylon) 0)))

  (define clean-loop
    (if (exact-integer? cur-loop)
        (max 0 cur-loop)
        (max 0 (inexact->exact (floor cur-loop)))))
  (define clean-minerals (max 0 (exact-round (- (sc2-player-common-minerals pc) in-transit-min-cost))))
  (define clean-gas (max 0 (exact-round (- (sc2-player-common-vespene pc) in-transit-gas-cost))))
  (define supply-cap (min SC2-MAX-SUPPLY (max 0 (exact-round (sc2-player-common-food-cap pc)))))
  (define supply-used (max 0 (exact-round (sc2-player-common-food-used pc))))
  (define supply-left (max 0 (- supply-cap supply-used)))

  (hash 'frame clean-loop
        'race actual-race
        'opponent-requested-race opponent-requested-race
        'map-grids map-grids
        'map-symmetry-kind map-symmetry-kind
        'our-ground-bfs our-ground-bfs
        'enemy-ground-bfs enemy-ground-bfs
        'minerals clean-minerals
        'gas clean-gas
        'supply-used supply-used
        'supply-cap supply-cap
        'supply-left supply-left
        'pending-supply pending-supply
        'pending-workers pending-workers
        'base-x base-x
        'base-y base-y
        'natural-x nat-x
        'natural-y nat-y
        'third-x third-x
        'third-y third-y
        'fourth-x fourth-x
        'fourth-y fourth-y
        'expansion-candidates expansion-candidates
        'enemy-x enemy-x
        'enemy-y enemy-y
        'enemy-base (list enemy-x enemy-y)
        'enemy-natural-x enemy-nat-x
        'enemy-natural-y enemy-nat-y
        'enemy-expand-x enemy-nat-x
        'enemy-exp-x enemy-nat-x
        'enemy-expand-y enemy-nat-y
        'enemy-exp-y enemy-nat-y
        'enemy-third-x enemy-third-x
        'enemy-third-y enemy-third-y
        'enemy-fourth-x enemy-fourth-x
        'enemy-fourth-y enemy-fourth-y
        'mineral-patch-id closest-mineral-patch-id
        'mineral-patches mineral-patch-records
        'geysers geyser-records
        'ally-units ally-unit-records
        'ally-creep-tumors ally-creep-tumor-records
        'ally-buildings ally-bldg-records
        'enemy-units enemy-unit-records
        'enemy-buildings enemy-bldg-records
        'enemy-proxy-buildings enemy-proxy-bldg-records
        'shimmer-and-burrow-ripples shimmer-and-burrow-ripples
        'free-addons free-addons
        'effects effect-records
        'dead-unit-tags (or (sc2-observation-dead-unit-tags obs) '())
        'researched-upgrades researched-upgrades
        'pending-upgrades pending-upgrades
        'depleting-bases depleting-bases
        'pre-depleting-bases pre-depleting-bases
        'stasis-frozen-worker-count stasis-frozen-worker-count
        'stasis-frozen-unit-ids stasis-frozen-unit-ids
        'raw-mineral-harvesters raw-min-harvesters
        'mineral-harvesters min-harvesters
        'ideal-mineral-harvesters ideal-min-harvesters
        'gas-harvesters gas-harvesters
        'ideal-gas-harvesters ideal-gas-harvesters
        'busy-facilities busy-facilities
        'busy-townhalls busy-townhalls
        'enemy-workers-killed 0
        'visible-sectors '(0 1 2 3)
        'nuke-alert #f
        'army-supply (max 0 (exact-round (sc2-player-common-food-army pc)))
        'power-placement-failed?
        (let ([fl (unbox SC2-PROTOSS-POWER-PLACEMENT-FAIL-LOOP)])
          (and (>= fl 0) (<= (- cur-loop fl) 96)))
        'addon-blocked-facility-ids
        (remove-duplicates
         (for/list ([(k bloop) (in-hash SC2-ADDON-SLOT-BLOCKED-CACHE)]
                    #:when (and (list? k)
                                (= (length k) 3)
                                (exact-integer? bloop)
                                (>= cur-loop bloop)
                                (< (- cur-loop bloop) 48)))
           (first k)))
        '__sanitized? #t))

(define (sc2-observation->frame-state-sexp obs
                                           #:game-info [game-info #f]
                                           #:our-player-id [our-player-id 1]
                                           #:configured-race [configured-race 'Random]
                                           #:used-creep-tumors [used-tumors (seteqv)]
                                           #:defer-expansions? [defer-expansions? #f])
  (define h (sc2-observation->runtime-obs-hash obs
                                               #:game-info game-info
                                               #:our-player-id our-player-id
                                               #:configured-race configured-race
                                               #:used-creep-tumors used-tumors
                                               #:defer-expansions? defer-expansions?))
  (list 'frame-state
        '#:frame (hash-ref h 'frame 0)
        '#:race (hash-ref h 'race 'Zerg)
        '#:minerals (hash-ref h 'minerals SC2-STARTING-MINERALS)
        '#:gas (hash-ref h 'gas SC2-STARTING-GAS)
        '#:supply-used (hash-ref h 'supply-used SC2-STARTING-WORKERS)
        '#:supply-cap (hash-ref h 'supply-cap SC2-TOWN-HALL-SUPPLY-PROVIDED)
        '#:supply-left (hash-ref h 'supply-left 3)
        '#:pending-supply (hash-ref h 'pending-supply 0)
        '#:start-pos (list (hash-ref h 'base-x SC2-DEFAULT-HOME-BASE-X)
                           (hash-ref h 'base-y SC2-DEFAULT-HOME-BASE-Y))
        '#:natural-pos (list (hash-ref h 'natural-x SC2-DEFAULT-NATURAL-X)
                             (hash-ref h 'natural-y SC2-DEFAULT-NATURAL-Y))
        '#:third-pos (list (hash-ref h 'third-x SC2-DEFAULT-THIRD-X)
                           (hash-ref h 'third-y SC2-DEFAULT-THIRD-Y))
        '#:enemy-base (list (hash-ref h 'enemy-x SC2-DEFAULT-ENEMY-BASE-X)
                            (hash-ref h 'enemy-y SC2-DEFAULT-ENEMY-BASE-Y))
        '#:my-units
        (for/list ([u (in-list (hash-ref h 'ally-units '()))])
          (list (hash-ref u 'id) (hash-ref u 'type) (hash-ref u 'x) (hash-ref u 'y)
                (hash-ref u 'hp) (hash-ref u 'energy 0)))
        '#:my-buildings
        (for/list ([b (in-list (hash-ref h 'ally-buildings '()))])
          (list (hash-ref b 'id) (hash-ref b 'type) (hash-ref b 'x) (hash-ref b 'y)
                (hash-ref b 'hp-pct 1.0) (hash-ref b 'build-progress 1.0) (hash-ref b 'halted #f)))
        '#:enemy-units
        (for/list ([eu (in-list (hash-ref h 'enemy-units '()))])
          (list (hash-ref eu 'id) (hash-ref eu 'type) (hash-ref eu 'x) (hash-ref eu 'y)
                (hash-ref eu 'hp)))
        '#:enemy-buildings
        (for/list ([eb (in-list (hash-ref h 'enemy-buildings '()))])
          (list (hash-ref eb 'id) (hash-ref eb 'type) (hash-ref eb 'x) (hash-ref eb 'y)
                (hash-ref eb 'hp)))
        '#:effects
        (for/list ([ef (in-list (hash-ref h 'effects '()))])
          (list (hash-ref ef 'type) (hash-ref ef 'x) (hash-ref ef 'y)))
        '#:researched-upgrades (hash-ref h 'researched-upgrades '())
        '#:pending-upgrades (hash-ref h 'pending-upgrades '())
        '#:depleting-bases (hash-ref h 'depleting-bases 0)
        '#:mineral-harvesters (hash-ref h 'mineral-harvesters 0)
        '#:ideal-mineral-harvesters (hash-ref h 'ideal-mineral-harvesters SC2-IDEAL-WORKERS-PER-MINERAL-LINE)
        '#:gas-harvesters (hash-ref h 'gas-harvesters 0)
        '#:ideal-gas-harvesters (hash-ref h 'ideal-gas-harvesters 0)
        '#:busy-facilities (hash-ref h 'busy-facilities 0)
        '#:busy-townhalls (hash-ref h 'busy-townhalls 0)
        '#:army-supply (hash-ref h 'army-supply 0)))

;; =============================================================================
;; 7. Spiral Placement Finder, Worker Saturation & S-Expression Actuator
;; =============================================================================

(define (scale-bot-coord-to-world c anchor-world-coord)
  (define v (if (and (number? c) (real? c) (not (nan? c)) (not (infinite? c)))
                (exact->inexact c)
                anchor-world-coord))
  ;; All bot coordinates live in SC2 world space (0.0..256.0); clamp to playable bounds.
  (max SC2-MAP-SAFE-MIN-COORD (min SC2-MAP-SAFE-MAX-COORD v)))

(define (footprint-tile-bounds cx cy hw hh)
  (define-values (x0 x1)
    (if (>= (abs (- hw (round hw))) 0.25)
        (let ([ix (exact-floor cx)]
              [rx (inexact->exact (round (- hw 0.5)))])
          (values (- ix rx) (+ ix rx)))
        (let ([ix (inexact->exact (round cx))]
              [rx (max 1 (inexact->exact (round hw)))])
          (values (- ix rx) (- (+ ix rx) 1)))))
  (define-values (y0 y1)
    (if (>= (abs (- hh (round hh))) 0.25)
        (let ([iy (exact-floor cy)]
              [ry (inexact->exact (round (- hh 0.5)))])
          (values (- iy ry) (+ iy ry)))
        (let ([iy (inexact->exact (round cy))]
              [ry (max 1 (inexact->exact (round hh)))])
          (values (- iy ry) (- (+ iy ry) 1)))))
  (values x0 x1 y0 y1))

(define (static-footprint-placement-ok? pl-grid cx cy hw hh)
  (cond
    [(not (sc2-image-grid? pl-grid)) #t]
    [else
     (define gw (sc2-image-grid-width pl-grid))
     (define gh (sc2-image-grid-height pl-grid))
     (define-values (x0 x1 y0 y1) (footprint-tile-bounds cx cy hw hh))
     (and (>= x0 0) (>= y0 0) (< x1 gw) (< y1 gh)
          (for*/and ([ix (in-range x0 (add1 x1))]
                     [iy (in-range y0 (add1 y1))])
            (= (sc2-grid-ref pl-grid ix iy) 1)))]))

(define (point-to-segment-dist px py ax ay bx by)
  (define dx (- bx ax))
  (define dy (- by ay))
  (define len2 (+ (* dx dx) (* dy dy)))
  (if (<= len2 1e-6)
      (pt-dist px py ax ay)
      (let ([t (max 0.0 (min 1.0 (/ (+ (* (- px ax) dx) (* (- py ay) dy)) len2)))])
        (pt-dist px py (+ ax (* t dx)) (+ ay (* t dy))))))

(define SC2-SPAWN-EXIT-PRODUCTION-SYMS
  '(gateway warp-gate barracks factory starport robotics-facility))

(define (has-adjacent-2x2-open-exit? x0 x1 y0 y1 open-cell? [reach-cell? #f])
  (or
   ;; North or South 2x2 exit block along `[x0 .. x1]`
   (for*/or ([by (in-list (list (- y0 2) (+ y1 1)))]
             [bx (in-range (sub1 x0) (add1 x1))])
     (and (open-cell? bx by)
          (open-cell? (add1 bx) by)
          (open-cell? bx (add1 by))
          (open-cell? (add1 bx) (add1 by))
          (or (not reach-cell?) (reach-cell? bx by))))
   ;; West or East 2x2 exit block along `[y0 .. y1]`
   (for*/or ([bx (in-list (list (- x0 2) (+ x1 1)))]
             [by (in-range (sub1 y0) (add1 y1))])
     (and (open-cell? bx by)
          (open-cell? (add1 bx) by)
          (open-cell? bx (add1 by))
          (open-cell? (add1 bx) (add1 by))
          (or (not reach-cell?) (reach-cell? bx by))))))

;; Precomputes mineral-lane segments, stamped pathing occupancy, and a baseline
;; shortest-path witness from the friendly base anchor to an exterior open tile
;; so spiral placement never:
;;   (a) blocks worker mining lanes,
;;   (b) traps spawned units (or building workers) in sealed cliff/mineral/building pockets, or
;;   (c) walls off the base exit so ground units cannot get out of the base!
(define SC2-BASE-SAFETY-CHECKER-CACHE (make-hash))

(define (make-base-layout-safety-checker game-info existing-units base-x base-y check-bfs)
  (define path-grid
    (and (sc2-game-info? game-info)
         (sc2-game-info-pathing-grid game-info)))
  (define has-grid? (sc2-image-grid? path-grid))
  (define path-sig (and has-grid? (image-grid-signature path-grid)))
  (define-values (sig-cnt sig-xor sig-sum)
    (for/fold ([cnt 0] [xh 0] [sh 0])
              ([u (in-list existing-units)]
               #:when (and (sc2-unit? u)
                           (not (= (sc2-unit-display-type u) 4))
                           (not (sc2-unit-is-flying u))
                           (or (sc2-unit-is-mineral-field? u)
                               (sc2-unit-is-vespene-geyser? u)
                               (sc2-unit-is-structure? u))))
      (define p (sc2-unit-pos u))
      (define h-item
        (bitwise-and
         #x3fffffff
         (+ (* (bitwise-and #xfffff (sc2-unit-tag u)) 26544357)
            (* (sc2-unit-unit-type u) 4099)
            (* (sc2-unit-alliance u) 97)
            (* (inexact->exact (round (* 2.0 (sc2-point3d-x p)))) 131)
            (* (inexact->exact (round (* 2.0 (sc2-point3d-y p)))) 257))))
      (values (add1 cnt)
              (bitwise-xor xh h-item)
              (bitwise-and #x3fffffff (+ sh h-item)))))
  (define cache-key
    (list path-sig
          (inexact->exact (round base-x))
          (inexact->exact (round base-y))
          sig-cnt sig-xor sig-sum))
  (define cached-entry
    (or (hash-ref SC2-BASE-SAFETY-CHECKER-CACHE cache-key #f)
        (let ()
          (define grounded-ths '())
          (define local-resources '())
          (for ([u (in-list existing-units)]
                #:when (and (sc2-unit? u)
                            (not (sc2-unit-is-flying u))))
            (when (or (sc2-unit-is-mineral-field? u)
                      (sc2-unit-is-vespene-geyser? u))
              (set! local-resources (cons u local-resources)))
            (when (and (= (sc2-unit-alliance u) 1)
                       (not (= (sc2-unit-display-type u) 4))
                       (sc2-unit-is-townhall? u))
              (set! grounded-ths (cons u grounded-ths))))
          (define mining-segments
            (for*/list ([th (in-list grounded-ths)]
                        [tp (in-value (sc2-unit-pos th))]
                        [tx (in-value (sc2-point3d-x tp))]
                        [ty (in-value (sc2-point3d-y tp))]
                        [res (in-list local-resources)]
                        [rp (in-value (sc2-unit-pos res))]
                        [rx (in-value (sc2-point3d-x rp))]
                        [ry (in-value (sc2-point3d-y rp))]
                        #:when (<= (pt-dist tx ty rx ry) 11.0))
              (list (+ tx (* 0.28 (- rx tx)))
                    (+ ty (* 0.28 (- ry ty)))
                    (+ tx (* 0.82 (- rx tx)))
                    (+ ty (* 0.82 (- ry ty))))))
          (define built
            (cond
              [(not has-grid?)
               (vector 'no-grid mining-segments)]
              [else
               (define gw (sc2-image-grid-width path-grid))
               (define gh (sc2-image-grid-height path-grid))
               (define bx-i (max 0 (min (sub1 gw) (exact-floor base-x))))
               (define by-i (max 0 (min (sub1 gh) (exact-floor base-y))))
               (define win-r 34)
               (define wx0 (max 0 (- bx-i win-r)))
               (define wx1 (min (sub1 gw) (+ bx-i win-r)))
               (define wy0 (max 0 (- by-i win-r)))
               (define wy1 (min (sub1 gh) (+ by-i win-r)))
               (define ww (add1 (- wx1 wx0)))
               (define wh (add1 (- wy1 wy0)))
               (define wsize (* ww wh))
               (define (in-win? ix iy)
                 (and (>= ix wx0) (<= ix wx1) (>= iy wy0) (<= iy wy1)))
               (define (win-idx ix iy)
                 (+ (- ix wx0) (* (- iy wy0) ww)))
               (define blocked-grid (make-bytes wsize 0))
               (for* ([iy (in-range wy0 (add1 wy1))]
                      [ix (in-range wx0 (add1 wx1))])
                 (when (= (sc2-grid-ref path-grid ix iy) 0)
                   (bytes-set! blocked-grid (win-idx ix iy) 1)))

               (define existing-prod-boxes '())
               (for ([u (in-list existing-units)]
                     #:when (and (sc2-unit? u)
                                 (not (= (sc2-unit-display-type u) 4))
                                 (not (sc2-unit-is-flying u))))
                 (define usym (sc2-id->unit-symbol (sc2-unit-unit-type u) 'unknown))
                 (define canon-u (sc2-canonical-structure-sym usym))
                 (define stamp?
                   (or (sc2-unit-is-mineral-field? u)
                       (sc2-unit-is-vespene-geyser? u)
                       (and (sc2-unit-is-structure? u)
                            (not (memq usym '(supply-depot-lowered
                                              creep-tumor creep-tumor-burrowed creep-tumor-queen))))))
                 (when stamp?
                   (define p (sc2-unit-pos u))
                   (define ux (sc2-point3d-x p))
                   (define uy (sc2-point3d-y p))
                   (define-values (uhw uhh)
                     (cond
                       [(sc2-unit-is-mineral-field? u) (values 1.0 0.5)]
                       [(sc2-unit-is-vespene-geyser? u) (values 1.5 1.5)]
                       [else (sc2-structure-half-dims canon-u)]))
                   (define-values (ux0 ux1 uy0 uy1) (footprint-tile-bounds ux uy uhw uhh))
                   (for* ([iy (in-range (max wy0 uy0) (min (add1 wy1) (add1 uy1)))]
                          [ix (in-range (max wx0 ux0) (min (add1 wx1) (add1 ux1)))])
                     (bytes-set! blocked-grid (win-idx ix iy) 1))
                   (when (and (= (sc2-unit-alliance u) 1)
                              (memq canon-u SC2-SPAWN-EXIT-PRODUCTION-SYMS))
                     (set! existing-prod-boxes
                           (cons (list ux0 ux1 uy0 uy1 ux uy) existing-prod-boxes)))))

               (define (base-open-cell? ix iy)
                 (and (>= ix 0) (< ix gw) (>= iy 0) (< iy gh)
                      (if (in-win? ix iy)
                          (= (bytes-ref blocked-grid (win-idx ix iy)) 0)
                          (not (= (sc2-grid-ref path-grid ix iy) 0)))))
               (define active-prod-boxes
                 (filter (lambda (pb)
                           (has-adjacent-2x2-open-exit?
                            (first pb) (second pb) (third pb) (fourth pb) base-open-cell?))
                         existing-prod-boxes))

               ;; Find walkable interior seed `(sx, sy)` right beside `(base-x, base-y)` and run 1 bounded BFS
               ;; to record a shortest-path witness to an exterior tile `>= 15` tiles away (`>= 8` on small test grids).
               (define start-cell
                 (let ([near
                        (sort
                         (for*/list ([dy (in-range -5 6)]
                                     [dx (in-range -5 6)]
                                     [ix (in-value (+ bx-i dx))]
                                     [iy (in-value (+ by-i dy))]
                                     #:when (base-open-cell? ix iy))
                           (cons ix iy))
                         <
                         #:key (lambda (c) (+ (sqr (- (car c) bx-i)) (sqr (- (cdr c) by-i)))))])
                   (and (pair? near) (first near))))

               (define min-exit-dist (if (and (>= gw 48) (>= gh 48)) 15.0 8.5))
               (define map-cx (* 0.5 gw))
               (define map-cy (* 0.5 gh))

               (define witness-mask (make-bytes wsize 0))
               (define exit-cell
                 (and start-cell
                      (in-win? (car start-cell) (cdr start-cell))
                      (let* ([sx (car start-cell)]
                             [sy (cdr start-cell)]
                             [parent (make-vector wsize -1)]
                             [q (make-vector wsize 0)]
                             [s-widx (win-idx sx sy)])
                        (vector-set! parent s-widx s-widx)
                        (vector-set! q 0 s-widx)
                        (define best-e #f)
                        (define best-score -1e9)
                        (let bfs-loop ([head 0] [tail 1])
                          (when (< head tail)
                            (define cur (vector-ref q head))
                            (define cx0 (+ wx0 (remainder cur ww)))
                            (define cy0 (+ wy0 (quotient cur ww)))
                            (define d-base (pt-dist (+ cx0 0.5) (+ cy0 0.5) base-x base-y))
                            (when (and (>= d-base min-exit-dist) (<= d-base 30.0))
                              ;; Prefer exterior tiles toward map center that also sit in an open 2x2 area
                              (define center-gain (- (pt-dist base-x base-y map-cx map-cy)
                                                     (pt-dist (+ cx0 0.5) (+ cy0 0.5) map-cx map-cy)))
                              (define open2x2-bonus
                                (if (and (base-open-cell? (add1 cx0) cy0)
                                         (base-open-cell? cx0 (add1 cy0))
                                         (base-open-cell? (add1 cx0) (add1 cy0)))
                                    8.0
                                    0.0))
                              (define sc (+ d-base (* 0.5 center-gain) open2x2-bonus))
                              (when (> sc best-score)
                                (set! best-score sc)
                                (set! best-e (cons cx0 cy0))))
                            (define next-tail
                              (for/fold ([tl tail])
                                        ([dxy (in-list '((1 . 0) (-1 . 0) (0 . 1) (0 . -1)))])
                                (define nx (+ cx0 (car dxy)))
                                (define ny (+ cy0 (cdr dxy)))
                                (if (in-win? nx ny)
                                    (let ([nidx (win-idx nx ny)])
                                      (if (and (= (bytes-ref blocked-grid nidx) 0)
                                               (= (vector-ref parent nidx) -1))
                                          (begin
                                            (vector-set! parent nidx cur)
                                            (vector-set! q tl nidx)
                                            (add1 tl))
                                          tl))
                                    tl)))
                            (bfs-loop (add1 head) next-tail)))
                        (when best-e
                          (let trace ([idx (win-idx (car best-e) (cdr best-e))])
                            (bytes-set! witness-mask idx 1)
                            (define p (vector-ref parent idx))
                            (when (and (>= p 0) (not (= p idx)))
                              (trace p))))
                        best-e)))

               ;; Reused across all candidate evaluations within this safety-checker cache entry
               (define shared-vis (make-bytes wsize 0))
               (define shared-vis-q (make-vector wsize 0))
               (vector 'grid mining-segments gw gh wx0 wx1 wy0 wy1 ww wh
                       blocked-grid active-prod-boxes start-cell exit-cell
                       witness-mask shared-vis shared-vis-q)]))
          (when (> (hash-count SC2-BASE-SAFETY-CHECKER-CACHE) 32)
            (hash-clear! SC2-BASE-SAFETY-CHECKER-CACHE))
          (hash-set! SC2-BASE-SAFETY-CHECKER-CACHE cache-key built)
          built)))
  (define mining-segments (vector-ref cached-entry 1))
  (cond
    [(eq? (vector-ref cached-entry 0) 'no-grid)
     (lambda (cx cy canon-bldg cand-hw cand-hh)
       (define is-gas-bldg?
         (memq canon-bldg '(extractor refinery assimilator extractor-rich refinery-rich assimilator-rich)))
       (define is-static-def?
         (memq canon-bldg '(spore-crawler missile-turret photon-cannon shield-battery spine-crawler bunker)))
       (define lane-clear
         (+ (max cand-hw cand-hh) (if is-static-def? 0.25 0.95)))
       (or is-gas-bldg?
           (for/and ([seg (in-list mining-segments)])
             (>= (point-to-segment-dist cx cy (first seg) (second seg) (third seg) (fourth seg))
                 lane-clear))))]
    [else
     (define gw (vector-ref cached-entry 2))
     (define gh (vector-ref cached-entry 3))
     (define wx0 (vector-ref cached-entry 4))
     (define wx1 (vector-ref cached-entry 5))
     (define wy0 (vector-ref cached-entry 6))
     (define wy1 (vector-ref cached-entry 7))
     (define ww (vector-ref cached-entry 8))
     (define blocked-grid (vector-ref cached-entry 10))
     (define active-prod-boxes (vector-ref cached-entry 11))
     (define start-cell (vector-ref cached-entry 12))
     (define exit-cell (vector-ref cached-entry 13))
     (define witness-mask (vector-ref cached-entry 14))
     (define shared-vis (vector-ref cached-entry 15))
     (define shared-vis-q (vector-ref cached-entry 16))
     (define (in-win? ix iy)
       (and (>= ix wx0) (<= ix wx1) (>= iy wy0) (<= iy wy1)))
     (define (win-idx ix iy)
       (+ (- ix wx0) (* (- iy wy0) ww)))
     (define (still-connected-to-exit? x0 x1 y0 y1 cand-open-cell?)
       (cond
         [(or (not start-cell) (not exit-cell)) #t]
         [else
          (define touches-witness?
            (for*/or ([iy (in-range (max wy0 y0) (min (add1 wy1) (add1 y1)))]
                      [ix (in-range (max wx0 x0) (min (add1 wx1) (add1 x1)))])
              (= (bytes-ref witness-mask (win-idx ix iy)) 1)))
          (if (not touches-witness?)
              #t
              (let* ([pick-near-open
                      (lambda (ox oy max-r)
                        (if (cand-open-cell? ox oy)
                            (cons ox oy)
                            (for*/first ([r (in-range 1 (add1 max-r))]
                                         [dy (in-range (- r) (add1 r))]
                                         [dx (in-range (- r) (add1 r))]
                                         #:when (cand-open-cell? (+ ox dx) (+ oy dy)))
                              (cons (+ ox dx) (+ oy dy)))))]
                     [s-pt (pick-near-open (car start-cell) (cdr start-cell) 3)]
                     [e-pt (pick-near-open (car exit-cell) (cdr exit-cell) 2)])
                (and s-pt e-pt
                     (or (not (in-win? (car s-pt) (cdr s-pt)))
                         (not (in-win? (car e-pt) (cdr e-pt)))
                         (let* ([s-idx (win-idx (car s-pt) (cdr s-pt))]
                                [e-idx (win-idx (car e-pt) (cdr e-pt))])
                           (bytes-fill! shared-vis 0)
                           (bytes-set! shared-vis s-idx 1)
                           (vector-set! shared-vis-q 0 s-idx)
                           (let loop ([head 0] [tail 1])
                             (cond
                               [(>= head tail) #f]
                               [(= (vector-ref shared-vis-q head) e-idx) #t]
                               [else
                                (define cur (vector-ref shared-vis-q head))
                                (define cx0 (+ wx0 (remainder cur ww)))
                                (define cy0 (+ wy0 (quotient cur ww)))
                                (define next-tail
                                  (for/fold ([tl tail])
                                            ([dxy (in-list '((1 . 0) (-1 . 0) (0 . 1) (0 . -1)))])
                                    (define nx (+ cx0 (car dxy)))
                                    (define ny (+ cy0 (cdr dxy)))
                                    (if (in-win? nx ny)
                                        (let ([nidx (win-idx nx ny)])
                                          (if (and (= (bytes-ref shared-vis nidx) 0)
                                                   (cand-open-cell? nx ny))
                                              (begin
                                                (bytes-set! shared-vis nidx 1)
                                                (vector-set! shared-vis-q tl nidx)
                                                (add1 tl))
                                              tl))
                                        tl)))
                                (loop (add1 head) next-tail)])))))))]))

     (lambda (cx cy canon-bldg cand-hw cand-hh)
       (define is-gas-bldg?
         (memq canon-bldg '(extractor refinery assimilator extractor-rich refinery-rich assimilator-rich)))
       (define is-static-def?
         (memq canon-bldg '(spore-crawler missile-turret photon-cannon shield-battery spine-crawler bunker)))
       (define lane-clear
         (+ (max cand-hw cand-hh) (if is-static-def? 0.25 0.95)))
       (and (or is-gas-bldg?
                (for/and ([seg (in-list mining-segments)])
                  (>= (point-to-segment-dist cx cy (first seg) (second seg) (third seg) (fourth seg))
                      lane-clear)))
            (let-values ([(x0 x1 y0 y1) (footprint-tile-bounds cx cy cand-hw cand-hh)])
              (define (cand-open-cell? ix iy)
                (and (>= ix 0) (< ix gw) (>= iy 0) (< iy gh)
                     (if (in-win? ix iy)
                         (= (bytes-ref blocked-grid (win-idx ix iy)) 0)
                         (not (= (sc2-grid-ref path-grid ix iy) 0)))
                     (not (and (>= ix x0) (<= ix x1) (>= iy y0) (<= iy y1)))))
              (define (reach-2x2? bx by)
                (or (not check-bfs)
                    (< (check-bfs (+ bx 0.5) (+ by 0.5) 1) +inf.0)))
              ;; 1. Spawn / worker pocket anti-trap check
              (and (if (memq canon-bldg SC2-SPAWN-EXIT-PRODUCTION-SYMS)
                       (has-adjacent-2x2-open-exit? x0 x1 y0 y1 cand-open-cell? reach-2x2?)
                       (>= (for*/sum ([iy (in-range (sub1 y0) (+ y1 2))]
                                      [ix (in-range (sub1 x0) (+ x1 2))]
                                      #:when (and (not (and (>= ix x0) (<= ix x1) (>= iy y0) (<= iy y1)))
                                                  (cand-open-cell? ix iy)
                                                  (or (not check-bfs)
                                                      (< (check-bfs (+ ix 0.5) (+ iy 0.5) 1) +inf.0))))
                             1)
                           3))
                   ;; 2. Never seal off an existing nearby production facility's last 2x2 spawn exit
                   (for/and ([pb (in-list active-prod-boxes)]
                             #:when (<= (pt-dist cx cy (fifth pb) (sixth pb)) 7.5))
                     (has-adjacent-2x2-open-exit?
                      (first pb) (second pb) (third pb) (fourth pb) cand-open-cell?))
                   ;; 3. Never wall off the ground exit corridor out of the base
                   (still-connected-to-exit? x0 x1 y0 y1 cand-open-cell?)))))]))

(define (placement-preserves-base-exit-and-spawn? cx cy bldg-sym existing-units
                                                  #:game-info [game-info #f]
                                                  #:base-x [base-x #f]
                                                  #:base-y [base-y #f])
  (define canon-bldg (sc2-canonical-structure-sym (or bldg-sym 'barracks)))
  (define-values (cand-hw cand-hh) (sc2-structure-half-dims canon-bldg))
  (define ref
    (if (and (real? base-x) (real? base-y))
        (cons base-x base-y)
        (friendly-safe-base-anchor existing-units cx cy)))
  (define check-bfs (ground-reachability-checker game-info existing-units (car ref) (cdr ref)))
  (define safety-ok?
    (make-base-layout-safety-checker game-info existing-units (car ref) (cdr ref) check-bfs))
  (safety-ok? cx cy canon-bldg cand-hw cand-hh))

(define (friendly-safe-base-anchor existing-units fallback-x fallback-y)
  (define friendly-ths
    (sort-townhalls-main-first
     (filter (lambda (u)
               (and (= (sc2-unit-alliance u) 1)
                    (not (= (sc2-unit-display-type u) 4))
                    (sc2-unit-is-townhall? u)
                    (not (sc2-unit-is-flying u))))
             existing-units)))
  (cond
    [(not (null? friendly-ths))
     (define p (sc2-unit-pos (first friendly-ths)))
     (cons (sc2-point3d-x p) (sc2-point3d-y p))]
    [(unbox SC2-HOME-BASE-ANCHOR) => values]
    [else (cons fallback-x fallback-y)]))

(define (ground-reachability-checker game-info existing-units ref-x ref-y)
  (define path-grid
    (and (sc2-game-info? game-info)
         (sc2-game-info-pathing-grid game-info)))
  (cond
    [(not (sc2-image-grid? path-grid)) #f]
    [else
     ;; W16-P1-2-wire: Fast O(1) reuse of match-start `our-ground-bfs` when `(ref-x, ref-y)` is
     ;; within 2.5 tiles of our cached home anchor, AND restrict neutral blocker signature to real
     ;; pathing blockers only (never busting BFS cache whenever a map critter walks 0.5 tiles!).
     (define terr-cached (unbox SC2-TERRITORY-FIELD-CACHE))
     (define terr-bfs-hit
       (and (list? terr-cached)
            (= (length terr-cached) 5)
            (let* ([bk (first terr-cached)]
                   [obfs (fourth terr-cached)])
              (and (list? bk)
                   (= (length bk) 5)
                   (procedure? obfs)
                   (equal? (first bk) (image-grid-signature path-grid))
                   (<= (pt-dist ref-x ref-y (second bk) (third bk)) 2.5)
                   (< (obfs ref-x ref-y 4) +inf.0)
                   obfs))))
     (cond
       [terr-bfs-hit terr-bfs-hit]
       [else
        (define neutrals
          (filter (lambda (u)
                    (and (sc2-unit? u)
                         (= (sc2-unit-alliance u) 3)
                         (neutral-unit-is-pathing-blocker? u)))
                  existing-units))
        (define neutral-sig
          (for/fold ([h (length neutrals)]) ([u (in-list neutrals)])
            (define p (sc2-unit-pos u))
            (bitwise-xor (* h 31)
                         (sc2-unit-tag u)
                         (exact-round (* 2.0 (sc2-point3d-x p)))
                         (exact-round (* 2.0 (sc2-point3d-y p))))))
        (define subkey (list (exact-round ref-x) (exact-round ref-y) neutral-sig))
        (define cached (unbox SC2-CACHED-GROUND-BFS))
        (cond
          [(and (pair? cached)
                (eq? (car (car cached)) game-info)
                (equal? (cdr (car cached)) subkey))
           (cdr cached)]
          [else
           (define bfs0 (compute-ground-bfs-distances path-grid ref-x ref-y neutrals))
           (define res
             (and bfs0
                  (< (bfs0 ref-x ref-y 4) +inf.0)
                  bfs0))
           (set-box! SC2-CACHED-GROUND-BFS (cons (cons game-info subkey) res))
           res])])]))

(define (dedup-point2ds pts)
  (define seen (make-hash))
  (filter (lambda (pt)
            (define k (cons (round (* 4.0 (sc2-point2d-x pt)))
                            (round (* 4.0 (sc2-point2d-y pt)))))
            (if (hash-has-key? seen k)
                #f
                (begin (hash-set! seen k #t) #t)))
          pts))

(define SC2-STEP-PLACEMENT-FAIL-LOOP (box -1))
(define SC2-STEP-PLACEMENT-FAIL-CACHE (make-hash))

(define (collect-spiral-candidates anchor-x anchor-y existing-units
                                   #:min-spacing [min-spacing 3.5]
                                   #:max-radius [max-radius 14.0]
                                   #:step [step 2.0]
                                   #:limit [limit 24]
                                   #:max-evals [max-evals 96]
                                   #:eval-budget [eval-budget #f]
                                   #:extra-reserved-points [extra-reserved-points '()]
                                   #:ws-active-placement? [ws-active-placement? #f]
                                   #:reserved-aabbs [reserved-aabbs '()]
                                   #:expansion-pads [expansion-pads '()]
                                   #:min-pad-clearance [min-pad-clearance 4.5]
                                   #:bldg-sym [bldg-sym #f]
                                   #:game-info [game-info #f]
                                   #:check-bfs [pre-check-bfs 'auto]
                                   #:layout-safety-ok? [pre-layout-safety-ok? 'auto]
                                   #:skip-terran-addon-reserve? [skip-terran-addon-reserve? #f])
  (define canon-bldg (and bldg-sym (sc2-canonical-structure-sym bldg-sym)))
  (define-values (cand-hw cand-hh)
    (sc2-structure-half-dims (or canon-bldg 'barracks)))
  (define is-townhall-build?
    (and canon-bldg (set-member? SC2-TOWNHALL-STRUCTURE-SYMS canon-bldg)))
  (define is-creep-tumor?
    (memq canon-bldg '(creep-tumor creep-tumor-burrowed creep-tumor-queen)))
  (define pl-grid
    (and (not is-creep-tumor?)
         (sc2-game-info? game-info)
         (sc2-game-info-placement-grid game-info)))
  (define-values (play-x0 play-y0 play-x1 play-y1)
    (cond
      [(sc2-game-info? game-info)
       (define pa (sc2-game-info-playable-area game-info))
       (define ms (sc2-game-info-map-size game-info))
       (cond
         [(hash? pa)
          (values (max 1.0 (exact->inexact (hash-ref pa 'x0 SC2-MAP-PLAYABLE-MIN-COORD)))
                  (max 1.0 (exact->inexact (hash-ref pa 'y0 SC2-MAP-PLAYABLE-MIN-COORD)))
                  (exact->inexact (hash-ref pa 'x1 SC2-MAP-PLAYABLE-MAX-COORD))
                  (exact->inexact (hash-ref pa 'y1 SC2-MAP-PLAYABLE-MAX-COORD)))]
         [(and (list? pa) (>= (length pa) 4))
          (values (max 1.0 (exact->inexact (first pa)))
                  (max 1.0 (exact->inexact (second pa)))
                  (exact->inexact (third pa))
                  (exact->inexact (fourth pa)))]
         [(pair? ms)
          (values 2.0 2.0
                  (exact->inexact (max 16 (- (car ms) 2)))
                  (exact->inexact (max 16 (- (cdr ms) 2))))]
         [else
          (values SC2-MAP-PLAYABLE-MIN-COORD SC2-MAP-PLAYABLE-MIN-COORD
                  SC2-MAP-PLAYABLE-MAX-COORD SC2-MAP-PLAYABLE-MAX-COORD)])]
      [else
       (values SC2-MAP-PLAYABLE-MIN-COORD SC2-MAP-PLAYABLE-MIN-COORD
               SC2-MAP-PLAYABLE-MAX-COORD SC2-MAP-PLAYABLE-MAX-COORD)]))
  (define base-ref
    (if (and (not is-creep-tumor?) (sc2-game-info? game-info))
        (friendly-safe-base-anchor existing-units anchor-x anchor-y)
        (cons anchor-x anchor-y)))
  (define check-bfs
    (if (not (eq? pre-check-bfs 'auto))
        pre-check-bfs
        (and (not is-creep-tumor?)
             (ground-reachability-checker game-info existing-units (car base-ref) (cdr base-ref)))))
  (define layout-safety-ok?
    (if (not (eq? pre-layout-safety-ok? 'auto))
        pre-layout-safety-ok?
        (and (not is-townhall-build?)
             (not is-creep-tumor?)
             (make-base-layout-safety-checker game-info existing-units (car base-ref) (cdr base-ref) check-bfs))))

  ;; Single-pass extraction of blocking unit circles, in-transit worker build targets, and Terran East (+X) add-on footprints
  (define in-transit-build-pts '())
  (define in-transit-terran-addon-pts '())
  (define terran-addon-pts '())
  (define blocking-circles '())
  (define blocking-aabbs '())
  (define local-blocking-res '())
  (for ([u (in-list existing-units)])
    (define is-struct? (sc2-unit-is-structure? u))
    (define is-res?
      (or (sc2-unit-is-mineral-field? u)
          (sc2-unit-is-vespene-geyser? u)))
    ;; W12-P0-3-wire: Live non-flying enemy units block SC2 building placement & kill builders;
    ;; skip enemy-occupied tiles during spiral search so emergency rush placements never waste RPC slots!
    (when (and (not is-struct?)
               (not is-res?)
               (= (sc2-unit-alliance u) 4)
               (not (= (sc2-unit-display-type u) 4))
               (not (sc2-unit-is-flying u)))
      (define ep (sc2-unit-pos u))
      (define req-ed (+ (max cand-hw cand-hh) 0.65 (max 0.375 (sc2-unit-radius u))))
      (set! blocking-circles
            (cons (vector (sc2-point3d-x ep) (sc2-point3d-y ep) (sqr req-ed))
                  blocking-circles)))
    (when (or is-struct? is-res?)
      (define p (sc2-unit-pos u))
      (define px (sc2-point3d-x p))
      (define py (sc2-point3d-y p))
      (when (and is-townhall-build?
                 is-res?
                 (<= (pt-dist anchor-x anchor-y px py) 25.0))
        (set! local-blocking-res (cons u local-blocking-res)))
      (define req-d
        (if ws-active-placement?
            (max 2.0 (+ 0.85 (max 0.5 (sc2-unit-radius u))))
            (+ min-spacing (max 0.5 (sc2-unit-radius u)))))
      (set! blocking-circles (cons (vector px py (sqr req-d)) blocking-circles))
      (when (and ws-active-placement? (not (sc2-unit-is-flying u)))
        (define usym (sc2-id->unit-symbol (sc2-unit-unit-type u) 'unknown))
        (define-values (u-hw u-hh)
          (cond
            [(sc2-unit-is-mineral-field? u) (values 1.0 0.5)]
            [(sc2-unit-is-vespene-geyser? u) (values 1.5 1.5)]
            [(memq usym '(creep-tumor creep-tumor-burrowed creep-tumor-queen)) (values 0.5 0.5)]
            [else (sc2-structure-half-dims usym)]))
        (set! blocking-aabbs
              (cons (vector px py (- (+ cand-hw u-hw) 0.05) (- (+ cand-hh u-hh) 0.05))
                    blocking-aabbs)))
      (when (and is-struct?
                 (not skip-terran-addon-reserve?)
                 (memq (sc2-id->unit-symbol (sc2-unit-unit-type u))
                       '(barracks factory starport)))
        (set! terran-addon-pts
              (cons (sc2-point2d (+ px SC2-TERRAN-ADDON-OFFSET-X)
                                 (+ py SC2-TERRAN-ADDON-OFFSET-Y))
                    terran-addon-pts))))
    (when (sc2-unit-is-worker? u)
      (for ([o (in-list (sc2-unit-orders u))])
        (define tp (sc2-unit-order-target-pos o))
        (when (any-point? tp)
          (define ab-id (sc2-unit-order-ability-id o))
          (define ab-sym (sc2-id->ability-symbol ab-id #f))
          (when (and ab-sym (string-prefix? (symbol->string ab-sym) "build-"))
            (set! in-transit-build-pts
                  (cons (sc2-point2d (any-point-x tp) (any-point-y tp))
                        in-transit-build-pts)))
          (when (and (not skip-terran-addon-reserve?)
                     (memv ab-id '(321 328 329)))
            (set! in-transit-terran-addon-pts
                  (cons (sc2-point2d (+ (any-point-x tp) SC2-TERRAN-ADDON-OFFSET-X)
                                     (+ (any-point-y tp) SC2-TERRAN-ADDON-OFFSET-Y))
                        in-transit-terran-addon-pts)))))))
  (define all-reserved-xys
    (for/list ([rp (in-list (append extra-reserved-points
                                    in-transit-build-pts
                                    in-transit-terran-addon-pts
                                    terran-addon-pts))]
               #:when (any-point? rp))
      (cons (any-point-x rp) (any-point-y rp))))
  (define reserved-dist-sq
    (sqr (if (< min-spacing 2.0) (max 1.5 min-spacing) (max 2.5 min-spacing))))
  (define exp-pad-xys
    (if is-townhall-build?
        '()
        (for/list ([ep (in-list expansion-pads)])
          (if (pair? ep)
              (cons (car ep) (cdr ep))
              (cons (any-point-x ep) (any-point-y ep))))))
  (define valid-reserved-aabbs
    (filter reserved-aabb? reserved-aabbs))

  (define (fast-spot-ok? cx cy)
    (and (>= cx play-x0) (<= cx play-x1)
         (>= cy play-y0) (<= cy play-y1)
         ;; Static footprint placement_grid pre-filter when StartRaw grids are available
         (static-footprint-placement-ok? pl-grid cx cy cand-hw cand-hh)
         ;; Expansion Pad Protection: non-TownHall structures must stay >= min-pad-clearance (default 4.5, tight creep 3.95/3.45) off solved pads
         (for/and ([ep (in-list exp-pad-xys)])
           (>= (max (abs (- cx (car ep))) (abs (- cy (cdr ep)))) min-pad-clearance))
         ;; TownHall placements must respect SC2's hard resource minimum distance rule
         (or (not is-townhall-build?)
             (sc2-townhall-all-resources-legal? cx cy local-blocking-res))
         ;; Reserved Chebyshev AABB exclusion (door gap, wall slots, ramp corridor, add-on footprints)
         (for/and ([b (in-list valid-reserved-aabbs)])
           (not (aabb-overlaps? cx cy cand-hw cand-hh b)))
         (for/and ([rp (in-list all-reserved-xys)])
           (> (+ (sqr (- cx (car rp))) (sqr (- cy (cdr rp)))) reserved-dist-sq))
         (for/and ([bc (in-list blocking-circles)])
           (> (+ (sqr (- cx (vector-ref bc 0))) (sqr (- cy (vector-ref bc 1))))
              (vector-ref bc 2)))
         (for/and ([ba (in-list blocking-aabbs)])
           (not (and (< (abs (- cx (vector-ref ba 0))) (vector-ref ba 2))
                     (< (abs (- cy (vector-ref ba 1))) (vector-ref ba 3)))))))
  (define (clear-spot? cx cy)
    (and (or (not check-bfs)
             (< (check-bfs cx cy 4) +inf.0))
         (or (not layout-safety-ok?)
             (layout-safety-ok? cx cy (or canon-bldg 'barracks) cand-hw cand-hh))))
  (define snap-to-grid? (and canon-bldg (not is-creep-tumor?)))
  (define snap-x-half? (>= (abs (- cand-hw (round cand-hw))) 0.25))
  (define snap-y-half? (>= (abs (- cand-hh (round cand-hh))) 0.25))
  (define (snap-cand-x v)
    (cond
      [(not snap-to-grid?) v]
      [snap-x-half? (+ (exact->inexact (floor v)) 0.5)]
      [else (exact->inexact (round v))]))
  (define (snap-cand-y v)
    (cond
      [(not snap-to-grid?) v]
      [snap-y-half? (+ (exact->inexact (floor v)) 0.5)]
      [else (exact->inexact (round v))]))
  (define seen-pts (make-hash))
  (define acc '())
  (define acc-len 0)
  (define eval-count 0)
  (define (budget-ok?)
    (and (< acc-len limit)
         (< eval-count max-evals)
         (or (not (box? eval-budget))
             (> (unbox eval-budget) 0))))
  (define (try-add-cand! raw-cx raw-cy)
    (when (budget-ok?)
      (define cx (snap-cand-x raw-cx))
      (define cy (snap-cand-y raw-cy))
      (define k (cons (inexact->exact (round (* 4.0 cx)))
                      (inexact->exact (round (* 4.0 cy)))))
      (unless (hash-has-key? seen-pts k)
        (hash-set! seen-pts k #t)
        (when (fast-spot-ok? cx cy)
          (set! eval-count (add1 eval-count))
          (when (box? eval-budget)
            (set-box! eval-budget (sub1 (unbox eval-budget))))
          (when (clear-spot? cx cy)
            (set! acc (cons (sc2-point2d cx cy) acc))
            (set! acc-len (add1 acc-len)))))))
  (try-add-cand! anchor-x anchor-y)
  (let r-loop ([r step])
    (when (and (<= r max-radius) (budget-ok?))
      (let d-loop ([dx (- r)])
        (when (and (<= dx r) (budget-ok?))
          (let y-loop ([dy (- r)])
            (when (and (<= dy r) (budget-ok?))
              (when (or (>= (abs dx) r) (>= (abs dy) r))
                (try-add-cand! (+ anchor-x dx) (+ anchor-y dy)))
              (y-loop (+ dy step))))
          (d-loop (+ dx step))))
      (r-loop (+ r step))))
  (reverse acc))

(define (find-spiral-building-placement anchor-x anchor-y existing-units
                                        #:min-spacing [min-spacing 3.5]
                                        #:max-radius [max-radius 14.0]
                                        #:step [step 2.0]
                                        #:extra-reserved-points [extra-reserved-points '()]
                                        #:reserved-aabbs [reserved-aabbs '()]
                                        #:expansion-pads [expansion-pads '()]
                                        #:bldg-sym [bldg-sym #f]
                                        #:game-info [game-info #f])
  (define cands
    (collect-spiral-candidates anchor-x anchor-y existing-units
                               #:min-spacing min-spacing
                               #:max-radius max-radius
                               #:step step
                               #:limit 1
                               #:extra-reserved-points extra-reserved-points
                               #:reserved-aabbs reserved-aabbs
                               #:expansion-pads expansion-pads
                               #:bldg-sym bldg-sym
                               #:game-info game-info))
  (if (not (null? cands))
      (first cands)
      (sc2-point2d anchor-x anchor-y)))

(define (interleave-lists xss)
  (let loop ([qs (filter pair? xss)] [acc '()])
    (if (null? qs)
        (reverse acc)
        (loop (for/list ([q (in-list qs)] #:when (pair? (cdr q))) (cdr q))
              (foldl cons acc (map car qs))))))

(define SC2-PLACEMENT-CACHE-TTL 64)

(define (consume-placement-rpc-budget! budget-box)
  (cond
    [(not (box? budget-box)) #t]
    [(> (unbox budget-box) 0)
     (set-box! budget-box (sub1 (unbox budget-box)))
     #t]
    [else #f]))

(define (find-verified-building-placement ws-conn ab-id anchor-x anchor-y existing-units
                                          #:min-spacing [min-spacing 3.5]
                                          #:max-radius [max-radius 14.0]
                                          #:step [step 2.0]
                                          #:extra-reserved-points [extra-reserved-points '()]
                                          #:anchor-points [anchor-points #f]
                                          #:reserved-aabbs [reserved-aabbs '()]
                                          #:expansion-pads [expansion-pads '()]
                                          #:bldg-sym [bldg-sym #f]
                                          #:game-info [game-info #f]
                                          #:power-sources [power-sources '()]
                                          #:rpc-budget [rpc-budget #f]
                                          #:cur-loop [cur-loop-arg #f]
                                          #:require-addon-clear? [require-addon-clear? #f]
                                          #:prefer-3x3-fallback? [prefer-3x3-fallback? #f])
  ;; For Terran production facilities (Barracks=321, Factory=328, Starport=329), also filter out
  ;; candidates whose East (+X) add-on footprint at (cx + 2.5, cy - 0.5) collides with structures or reserved AABBs,
  ;; EXCEPT when sealing the main-ramp wall with the 1st Barracks (`existing-rax == 0`), where an East-facing
  ;; ramp slope overhangs `(+2.5, -0.5)` and `3x3` wall placement must seal the ramp!
  (define needs-terran-addon-clearance? (memv ab-id '(321 328 329)))
  (define ws-active? (and (sc2-ws-conn? ws-conn) (not (sc2-ws-conn-closed? ws-conn))))
  (define canon-bldg
    (or (and bldg-sym (sc2-canonical-structure-sym bldg-sym))
        (case ab-id
          [(318) 'command-center]
          [(880) 'nexus]
          [(1152) 'hatchery]
          [(319) 'supply-depot]
          [(881) 'pylon]
          [(321) 'barracks]
          [(328) 'factory]
          [(329) 'starport]
          [(1694 1733) 'creep-tumor]
          [else #f])))
  (define neg-cd-cur-loop
    (if (and (exact-integer? cur-loop-arg) (>= cur-loop-arg 0))
        cur-loop-arg
        (unbox SC2-WARPGATE-LAST-LOOP)))
  (define neg-cd-key
    (and ws-active? canon-bldg
         (if require-addon-clear?
             (list canon-bldg
                   (inexact->exact (round anchor-x))
                   (inexact->exact (round anchor-y))
                   'addon-req)
             (list canon-bldg
                   (inexact->exact (round anchor-x))
                   (inexact->exact (round anchor-y))))))
  (define step-fail-key
    (and ws-active? canon-bldg
         (if require-addon-clear?
             (list canon-bldg
                   (inexact->exact (round anchor-x))
                   (inexact->exact (round anchor-y))
                   (inexact->exact (round max-radius))
                   'addon-req)
             (list canon-bldg
                   (inexact->exact (round anchor-x))
                   (inexact->exact (round anchor-y))
                   (inexact->exact (round max-radius))))))
  (define pos-cache-key step-fail-key)
  (define cur-struct-sig
    (and (or ws-active? step-fail-key)
         (for/fold ([p 0] [th 0] [tm 0] [tot 0] #:result (list p th tm tot))
                   ([u (in-list existing-units)]
                    #:when (and (= (sc2-unit-alliance u) 1)
                                (not (= (sc2-unit-display-type u) 4))
                                (sc2-unit-is-structure? u)))
           (define usym (sc2-id->unit-symbol (sc2-unit-unit-type u) 'unknown))
           (cond
             [(memq usym '(pylon pylon-overcharged warp-prism-phasing))
              (values (add1 p) th tm (add1 tot))]
             [(sc2-unit-is-townhall? u)
              (values p (add1 th) tm (add1 tot))]
             [(memq usym '(creep-tumor creep-tumor-burrowed creep-tumor-queen))
              (values p th (add1 tm) (add1 tot))]
             [else (values p th tm (add1 tot))]))))
  (when (and cur-struct-sig
             (not (equal? cur-struct-sig (unbox SC2-PLACEMENT-CACHE-SIG))))
    (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
    (hash-clear! SC2-PLACEMENT-POS-CACHE)
    (hash-clear! SC2-ADDON-SLOT-BLOCKED-CACHE)
    (hash-clear! SC2-TERRAN-5X3-MISS-CACHE)
    (hash-clear! SC2-STEP-PLACEMENT-FAIL-CACHE)
    (set-box! SC2-PLACEMENT-CACHE-SIG cur-struct-sig))
  (when (not (= neg-cd-cur-loop (unbox SC2-STEP-PLACEMENT-FAIL-LOOP)))
    (hash-clear! SC2-STEP-PLACEMENT-FAIL-CACHE)
    (set-box! SC2-STEP-PLACEMENT-FAIL-LOOP neg-cd-cur-loop))
  ;; W17-P0-1-wire: Keep fast 12-loop recovery for supply (`pylon`/`supply-depot`) and early-rush
  ;; static defense (`< 5400f` / `< 4:00`); restore `>= 48`-loop TTL for Terran production
  ;; (`barracks`/`factory`/`starport`) and `64`-loop TTL for late-game static defense (`photon-cannon`
  ;; / `bunker` / etc.) so crowded late-game bases never thrash spiral+RPC every 3 steps!
  (define emergency-supply-bldg?
    (and canon-bldg (memq canon-bldg '(pylon supply-depot))))
  (define static-def-bldg?
    (and canon-bldg
         (memq canon-bldg '(bunker shield-battery photon-cannon spine-crawler spore-crawler))))
  (define emergency-rush-bldg?
    (or emergency-supply-bldg?
        (and static-def-bldg? (< neg-cd-cur-loop 5400))))
  (define terran-prod-bldg?
    (and canon-bldg (memq canon-bldg '(barracks factory starport))))
  (define neg-cd-ttl
    (cond
      [emergency-rush-bldg? 12]
      [terran-prod-bldg? 48]
      [else SC2-PLACEMENT-CACHE-TTL]))
  (define late-all-pylons-neg-key
    (and ws-active?
         canon-bldg
         static-def-bldg?
         (>= neg-cd-cur-loop 5400)
         (memq canon-bldg '(photon-cannon shield-battery))
         (list? anchor-points)
         (>= (length anchor-points) 2)
         (list canon-bldg 'all-pylons)))
  (define neg-cd-hit?
    (or (and step-fail-key
             (hash-has-key? SC2-STEP-PLACEMENT-FAIL-CACHE step-fail-key))
        (and ws-active?
             neg-cd-key
             (let ([exp-loop (hash-ref SC2-PLACEMENT-NEG-COOLDOWN neg-cd-key #f)])
               (and exp-loop
                    (>= neg-cd-cur-loop exp-loop)
                    (< (- neg-cd-cur-loop exp-loop) neg-cd-ttl))))
        (and late-all-pylons-neg-key
             (let ([exp-loop (hash-ref SC2-PLACEMENT-NEG-COOLDOWN late-all-pylons-neg-key #f)])
               (and exp-loop
                    (>= neg-cd-cur-loop exp-loop)
                    (< (- neg-cd-cur-loop exp-loop) neg-cd-ttl))))))
  (if neg-cd-hit?
      #f
      (let ()
  (define-values (cand-hw cand-hh)
    (sc2-structure-half-dims (or canon-bldg 'barracks)))
  (define is-townhall-build?
    (and canon-bldg (set-member? SC2-TOWNHALL-STRUCTURE-SYMS canon-bldg)))
  (define is-creep-tumor?
    (memq canon-bldg '(creep-tumor creep-tumor-burrowed creep-tumor-queen)))
  (define is-zerg-creep-bldg?
    (memq canon-bldg
          '(spawning-pool evolution-chamber roach-warren baneling-nest
            hydralisk-den lurker-den lurker-den-mp spire infestation-pit
            ultralisk-cavern nydus-network spine-crawler spore-crawler)))
  (define tight-pad-clearance
    (if is-zerg-creep-bldg?
        (max 3.45 (- (+ 2.5 (max cand-hw cand-hh)) 0.05))
        4.5))
  (define requires-pylon-power?
    (memq canon-bldg
          '(gateway forge cybernetics-core photon-cannon shield-battery
            twilight-council robotics-facility robotics-bay robotics-support-bay
            stargate templar-archive templar-archives dark-shrine fleet-beacon)))
  (define pl-grid
    (and (not is-creep-tumor?)
         (sc2-game-info? game-info)
         (sc2-game-info-placement-grid game-info)))
  (define anchors0
    (if (and (list? anchor-points) (not (null? anchor-points)))
        anchor-points
        (list (cons anchor-x anchor-y))))
  (define last-ap (last anchors0))
  (define safe-base-anchor
    (friendly-safe-base-anchor existing-units (car last-ap) (cdr last-ap)))

  ;; Count existing or in-transit friendly Barracks so ONLY the 1st Barracks (`existing-rax == 0`)
  ;; may seal an East-facing ramp wall without East `(+2.5, -0.5)` add-on clearance.
  (define existing-rax
    (if (= ab-id 321)
        (for/sum ([u (in-list existing-units)]
                  #:when (and (= (sc2-unit-alliance u) 1)
                              (not (= (sc2-unit-display-type u) 4))))
          (define usym (sc2-id->unit-symbol (sc2-unit-unit-type u) 'unknown))
          (cond
            [(memq usym '(barracks barracks-flying)) 1]
            [(and (sc2-unit-is-worker? u)
                  (not (worker-build-order-stuck? u))
                  (ormap (lambda (o) (= (sc2-unit-order-ability-id o) 321))
                         (sc2-unit-orders u)))
             1]
            [else 0]))
        0))

  ;; If this build specifically targets a reserved wall-slot AABB matching our footprint dims,
  ;; exclude that slot (and its own paired `terran-addon-pad` AABB) from self-repulsion.
  (define matched-wall-slot
    (for/first ([b (in-list reserved-aabbs)]
                #:when (and (reserved-aabb? b)
                            (eq? (reserved-aabb-kind b) 'wall-slot)
                            (<= (pt-dist anchor-x anchor-y (reserved-aabb-cx b) (reserved-aabb-cy b)) 3.0)
                            (<= (abs (- (reserved-aabb-half-w b) cand-hw)) 0.35)
                            (<= (abs (- (reserved-aabb-half-h b) cand-hh)) 0.35)))
      b))
  (define eff-reserved-aabbs
    (if matched-wall-slot
        (let ([wx (reserved-aabb-cx matched-wall-slot)]
              [wy (reserved-aabb-cy matched-wall-slot)])
          (filter (lambda (b)
                    (not (or (equal? b matched-wall-slot)
                             (and needs-terran-addon-clearance?
                                  (reserved-aabb? b)
                                  (eq? (reserved-aabb-kind b) 'terran-addon-pad)
                                  (<= (pt-dist (+ wx SC2-TERRAN-ADDON-OFFSET-X)
                                               (+ wy SC2-TERRAN-ADDON-OFFSET-Y)
                                               (reserved-aabb-cx b)
                                               (reserved-aabb-cy b))
                                      2.0)))))
                  reserved-aabbs))
        reserved-aabbs))

  (define wall-ref-x (if matched-wall-slot (reserved-aabb-cx matched-wall-slot) anchor-x))
  (define wall-ref-y (if matched-wall-slot (reserved-aabb-cy matched-wall-slot) anchor-y))
  (define first-rax?
    (and (= ab-id 321) (= existing-rax 0)))
  (define east-addon-overhangs-terrain?
    (and (sc2-image-grid? pl-grid)
         (not (static-footprint-placement-ok?
               pl-grid
               (+ wall-ref-x SC2-TERRAN-ADDON-OFFSET-X)
               (+ wall-ref-y SC2-TERRAN-ADDON-OFFSET-Y)
               1.0 1.0))))
  (define first-rax-allow-wall-3x3?
    (and (not require-addon-clear?)
         first-rax?
         (or (and matched-wall-slot #t)
             east-addon-overhangs-terrain?
             (> (pt-dist wall-ref-x wall-ref-y
                         (car safe-base-anchor) (cdr safe-base-anchor))
                6.0))))

  (define (filter-addon-clear c-list #:ignore-reserved-aabbs? [ignore-reserved-aabbs? #f])
    (define addon-pad-clr (if ignore-reserved-aabbs? tight-pad-clearance 4.0))
    (filter (lambda (pt)
              (define ax (+ (sc2-point2d-x pt) SC2-TERRAN-ADDON-OFFSET-X))
              (define ay (+ (sc2-point2d-y pt) SC2-TERRAN-ADDON-OFFSET-Y))
              (and (<= ax SC2-MAP-PLAYABLE-MAX-COORD)
                   (>= ay SC2-MAP-PLAYABLE-MIN-COORD)
                   (static-footprint-placement-ok? pl-grid ax ay 1.0 1.0)
                   (or ignore-reserved-aabbs?
                       (for/and ([b (in-list eff-reserved-aabbs)]
                                 #:when (reserved-aabb? b))
                         (not (aabb-overlaps? ax ay 1.0 1.0 b))))
                   (for/and ([ep (in-list expansion-pads)])
                     (define px (if (pair? ep) (car ep) (any-point-x ep)))
                     (define py (if (pair? ep) (cdr ep) (any-point-y ep)))
                     (>= (max (abs (- ax px)) (abs (- ay py))) addon-pad-clr))
                   (for/and ([u (in-list existing-units)]
                             #:when (and (not (sc2-unit-is-flying u))
                                         (or (sc2-unit-is-structure? u)
                                             (sc2-unit-is-mineral-field? u)
                                             (sc2-unit-is-vespene-geyser? u))))
                     (define p (sc2-unit-pos u))
                     (> (pt-dist ax ay (sc2-point3d-x p) (sc2-point3d-y p))
                        (+ SC2-ADDON-FOOTPRINT-HALF-SIZE (max 0.5 (sc2-unit-radius u)))))))
            c-list))

  (define completed-power-pylons
    (if requires-pylon-power?
        (filter (lambda (u)
                  (and (= (sc2-unit-alliance u) 1)
                       (not (= (sc2-unit-display-type u) 4))
                       (memq (sc2-id->unit-symbol (sc2-unit-unit-type u) 'unknown)
                             '(pylon pylon-overcharged warp-prism-phasing))
                       (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)))
                existing-units)
        '()))
  (define has-completed-pylon?
    (and requires-pylon-power?
         (or (and (list? power-sources) (pair? power-sources))
             (pair? completed-power-pylons))))
  (define (pt-in-completed-pylon-power? px py)
    (or (not requires-pylon-power?)
        (not has-completed-pylon?)
        (and (list? power-sources)
             (ormap (lambda (ps)
                      (and (sc2-power-source? ps)
                           (let ([p (sc2-power-source-pos ps)])
                             (<= (pt-dist px py (sc2-point3d-x p) (sc2-point3d-y p))
                                 (sc2-power-source-radius ps)))))
                    power-sources))
        (ormap (lambda (u)
                 (define p (sc2-unit-pos u))
                 (define usym (sc2-id->unit-symbol (sc2-unit-unit-type u) 'unknown))
                 (define prad (if (eq? usym 'warp-prism-phasing) 3.75 6.5))
                 (<= (pt-dist px py (sc2-point3d-x p) (sc2-point3d-y p)) prad))
               completed-power-pylons)))
  (define (filter-pylon-powered pts)
    (if (and requires-pylon-power? has-completed-pylon?)
        (let ([powered (filter (lambda (pt)
                                 (pt-in-completed-pylon-power? (sc2-point2d-x pt)
                                                               (sc2-point2d-y pt)))
                               pts)])
          (if (pair? powered) powered pts))
        pts))

  ;; Fast positive verified-placement cache lookup (0 RPCs, 0 BFS, 0 spiral search when still locally clear)
  (define (cached-pt-still-fresh? cpt)
    (and (sc2-point2d? cpt)
         (let ([cx (sc2-point2d-x cpt)]
               [cy (sc2-point2d-y cpt)]
               [res-dist (max 2.5 min-spacing)])
           (and (>= cx SC2-MAP-PLAYABLE-MIN-COORD) (<= cx SC2-MAP-PLAYABLE-MAX-COORD)
                (>= cy SC2-MAP-PLAYABLE-MIN-COORD) (<= cy SC2-MAP-PLAYABLE-MAX-COORD)
                (or is-townhall-build?
                    (for/and ([ep (in-list expansion-pads)])
                      (define px (if (pair? ep) (car ep) (any-point-x ep)))
                      (define py (if (pair? ep) (cdr ep) (any-point-y ep)))
                      (>= (max (abs (- cx px)) (abs (- cy py))) tight-pad-clearance)))
                (for/and ([b (in-list eff-reserved-aabbs)]
                          #:when (and (reserved-aabb? b)
                                      (not (and first-rax-allow-wall-3x3?
                                                (eq? (reserved-aabb-kind b) 'terran-addon-pad)))))
                  (not (aabb-overlaps? cx cy cand-hw cand-hh b)))
                (for/and ([rp (in-list extra-reserved-points)]
                          #:when (any-point? rp))
                  (> (pt-dist cx cy (any-point-x rp) (any-point-y rp)) res-dist))
                (for/and ([u (in-list existing-units)])
                  (cond
                    [(and (not (sc2-unit-is-flying u))
                          (or (sc2-unit-is-structure? u)
                              (sc2-unit-is-mineral-field? u)
                              (sc2-unit-is-vespene-geyser? u)))
                     (define p (sc2-unit-pos u))
                     (define ux (sc2-point3d-x p))
                     (define uy (sc2-point3d-y p))
                     (define usym (sc2-id->unit-symbol (sc2-unit-unit-type u) 'unknown))
                     (define-values (u-hw u-hh)
                       (cond
                         [(sc2-unit-is-mineral-field? u) (values 1.0 0.5)]
                         [(sc2-unit-is-vespene-geyser? u) (values 1.5 1.5)]
                         [else (sc2-structure-half-dims usym)]))
                     (not (and (< (abs (- cx ux)) (- (+ cand-hw u-hw) 0.05))
                               (< (abs (- cy uy)) (- (+ cand-hh u-hh) 0.05))))]
                    [(and (sc2-unit-is-worker? u)
                          (not (worker-build-order-stuck? u)))
                     (for/and ([o (in-list (sc2-unit-orders u))])
                       (define tp (sc2-unit-order-target-pos o))
                       (define ab-sym (and (any-point? tp)
                                           (sc2-id->ability-symbol (sc2-unit-order-ability-id o) #f)))
                       (or (not (and ab-sym (string-prefix? (symbol->string ab-sym) "build-")))
                           (> (pt-dist cx cy (any-point-x tp) (any-point-y tp)) res-dist)))]
                    [else #t]))
                (or (not requires-pylon-power?) (pt-in-completed-pylon-power? cx cy))
                ;; W17-P0-1-wire: Preserve cached `3x3` Terran fallback spots unless `require-addon-clear?`
                ;; is explicitly required (add-on relocation), eliminating needless cache-miss thrashing!
                (or (not require-addon-clear?)
                    (pair? (filter-addon-clear (list cpt) #:ignore-reserved-aabbs? #t)))))))
  (define pos-cache-hit
    (and ws-active?
         pos-cache-key
         (let ([entry (hash-ref SC2-PLACEMENT-POS-CACHE pos-cache-key #f)])
           (and (pair? entry)
                (>= neg-cd-cur-loop (car entry))
                (< (- neg-cd-cur-loop (car entry)) SC2-PLACEMENT-CACHE-TTL)
                (cached-pt-still-fresh? (cadr entry))
                (cadr entry)))))
  (if pos-cache-hit
      pos-cache-hit
      (let ()
  (define check-bfs
    (and (not is-creep-tumor?)
         (ground-reachability-checker game-info existing-units
                                      (car safe-base-anchor) (cdr safe-base-anchor))))
  (define matched-wall-slot-ok?
    (and matched-wall-slot
         (>= wall-ref-x SC2-MAP-PLAYABLE-MIN-COORD) (<= wall-ref-x SC2-MAP-PLAYABLE-MAX-COORD)
         (>= wall-ref-y SC2-MAP-PLAYABLE-MIN-COORD) (<= wall-ref-y SC2-MAP-PLAYABLE-MAX-COORD)
         (static-footprint-placement-ok? pl-grid wall-ref-x wall-ref-y cand-hw cand-hh)
         (or (not check-bfs) (< (check-bfs wall-ref-x wall-ref-y 4) +inf.0))))

  (define (wall-slot-3x3-spot-clear? cx cy)
    (and (>= cx SC2-MAP-PLAYABLE-MIN-COORD) (<= cx SC2-MAP-PLAYABLE-MAX-COORD)
         (>= cy SC2-MAP-PLAYABLE-MIN-COORD) (<= cy SC2-MAP-PLAYABLE-MAX-COORD)
         (static-footprint-placement-ok? pl-grid cx cy cand-hw cand-hh)
         (or (not check-bfs) (< (check-bfs cx cy 4) +inf.0))
         (or is-townhall-build?
             (for/and ([ep (in-list expansion-pads)])
               (define px (if (pair? ep) (car ep) (any-point-x ep)))
               (define py (if (pair? ep) (cdr ep) (any-point-y ep)))
               (>= (max (abs (- cx px)) (abs (- cy py))) 4.5)))
         (for/and ([b (in-list eff-reserved-aabbs)]
                   #:when (and (reserved-aabb? b)
                               (not (and first-rax-allow-wall-3x3?
                                         (eq? (reserved-aabb-kind b) 'terran-addon-pad)))))
           (not (aabb-overlaps? cx cy cand-hw cand-hh b)))
         (for/and ([u (in-list existing-units)]
                   #:when (or (sc2-unit-is-structure? u)
                              (sc2-unit-is-mineral-field? u)
                              (sc2-unit-is-vespene-geyser? u)))
           (define p (sc2-unit-pos u))
           (define ux (sc2-point3d-x p))
           (define uy (sc2-point3d-y p))
           (define usym (sc2-id->unit-symbol (sc2-unit-unit-type u) 'unknown))
           (define-values (u-hw u-hh)
             (cond
               [(sc2-unit-is-mineral-field? u) (values 1.0 0.5)]
               [(sc2-unit-is-vespene-geyser? u) (values 1.5 1.5)]
               [else (sc2-structure-half-dims usym)]))
           (not (and (< (abs (- cx ux)) (- (+ cand-hw u-hw) 0.05))
                     (< (abs (- cy uy)) (- (+ cand-hh u-hh) 0.05)))))
         (for/and ([rp (in-list extra-reserved-points)]
                   #:when (any-point? rp))
           (> (pt-dist cx cy (any-point-x rp) (any-point-y rp)) 2.0))))

  ;; Tight <= 2.5-tile grid-aligned candidates around wall slot for 1st Barracks / matched wall builds
  (define wall-tight-cands
    (if (or matched-wall-slot-ok? first-rax-allow-wall-3x3?)
        (let* ([snap-base-x (if (>= (abs (- cand-hw (round cand-hw))) 0.25)
                                (+ (floor wall-ref-x) 0.5)
                                (exact->inexact (round wall-ref-x)))]
               [snap-base-y (if (>= (abs (- cand-hh (round cand-hh))) 0.25)
                                (+ (floor wall-ref-y) 0.5)
                                (exact->inexact (round wall-ref-y)))]
               [neighbors
                (sort
                 (for*/list ([dx (in-list '(-2.0 -1.0 0.0 1.0 2.0))]
                             [dy (in-list '(-2.0 -1.0 0.0 1.0 2.0))]
                             [px (in-value (+ snap-base-x dx))]
                             [py (in-value (+ snap-base-y dy))]
                             #:when (and (<= (pt-dist wall-ref-x wall-ref-y px py) 2.5)
                                         (wall-slot-3x3-spot-clear? px py)))
                   (sc2-point2d px py))
                 <
                 #:key (lambda (pt)
                         (pt-dist wall-ref-x wall-ref-y
                                  (sc2-point2d-x pt) (sc2-point2d-y pt))))]
               [exact-list
                (if (wall-slot-3x3-spot-clear? wall-ref-x wall-ref-y)
                    (list (sc2-point2d wall-ref-x wall-ref-y))
                    '())])
          (dedup-point2ds (append exact-list neighbors)))
        '()))

  (define anchors-raw
    (if (and requires-pylon-power? has-completed-pylon?)
        anchors0
        (remove-duplicates (append anchors0 (list safe-base-anchor)))))
  ;; Cap priority-sorted anchors to top 8 so late-game 20-pylon / 25-tumor bases never explode spiral CPU
  (define anchors
    (if (> (length anchors-raw) 8)
        (take anchors-raw 8)
        anchors-raw))

  (define is-townhall-target?
    (set-member? SC2-TOWNHALL-STRUCTURE-SYMS canon-bldg))
  (define is-creep-tumor-target?
    (memq canon-bldg '(creep-tumor creep-tumor-burrowed creep-tumor-queen)))
  (define shared-base-ref
    (if (and (not is-creep-tumor-target?) (sc2-game-info? game-info))
        safe-base-anchor
        (cons anchor-x anchor-y)))
  (define shared-check-bfs
    (and (not is-creep-tumor-target?)
         (or check-bfs
             (ground-reachability-checker game-info existing-units
                                          (car shared-base-ref) (cdr shared-base-ref)))))
  (define shared-layout-safety-ok?
    (and (not is-townhall-target?)
         (not is-creep-tumor-target?)
         (make-base-layout-safety-checker game-info existing-units
                                          (car shared-base-ref) (cdr shared-base-ref)
                                          shared-check-bfs)))

  ;; W16-P1-2-wire: Cap primary BFS-checked spiral eval budget (`160` vs `480`) and per-anchor limit under
  ;; `ws-active?` so crowded mains never burn 35-43ms in redundant `still-connected-to-exit?` sweeps while
  ;; still filling all 48/64 single-RPC slots via fast `relaxed-safety-cands` + `near-base-emergency-cands`.
  (define spiral-eval-budget (box (if ws-active? 160 600)))
  (define primary-cand-limit
    (if ws-active?
        (min 20 (max 8 (quotient 36 (max 1 (length anchors)))))
        (if (or first-rax-allow-wall-3x3? needs-terran-addon-clearance?) 8 2)))
  (define spiral-cands
    (let ([all-pts
           (interleave-lists
            (for/list ([ap (in-list anchors)]
                       #:break (<= (unbox spiral-eval-budget) 0))
              (collect-spiral-candidates (car ap) (cdr ap) existing-units
                                         #:min-spacing min-spacing
                                         #:max-radius max-radius
                                         #:step step
                                         #:limit primary-cand-limit
                                         #:max-evals (if ws-active? 64 450)
                                         #:eval-budget spiral-eval-budget
                                         #:extra-reserved-points extra-reserved-points
                                         #:ws-active-placement? ws-active?
                                         #:reserved-aabbs eff-reserved-aabbs
                                         #:expansion-pads expansion-pads
                                         #:min-pad-clearance 4.5
                                         #:bldg-sym canon-bldg
                                         #:game-info game-info
                                         #:check-bfs shared-check-bfs
                                         #:layout-safety-ok? shared-layout-safety-ok?)))])
      (dedup-point2ds (take all-pts (min 64 (length all-pts))))))

  (define raw-cands
    (dedup-point2ds (append wall-tight-cands spiral-cands)))
  (define cands
    (cond
      [first-rax-allow-wall-3x3?
       (define addon-clear-rest (filter-addon-clear spiral-cands))
       (dedup-point2ds
        (append wall-tight-cands
                (if (not (null? addon-clear-rest)) addon-clear-rest spiral-cands)))]
      [needs-terran-addon-clearance?
       (let ([addon-clear (filter-addon-clear raw-cands)])
         (if (not (null? addon-clear))
             (dedup-point2ds (append addon-clear raw-cands))
             raw-cands))]
      [else raw-cands]))

  (define queried-keys (make-hash))
  (define (pt-key pt)
    (cons (inexact->exact (round (* 4.0 (sc2-point2d-x pt))))
          (inexact->exact (round (* 4.0 (sc2-point2d-y pt))))))
  (define (filter-unqueried pts)
    (for/list ([pt (in-list (dedup-point2ds pts))]
               #:unless (hash-has-key? queried-keys (pt-key pt)))
      pt))
  (define (merge-priority-batches tier-specs max-total)
    (define seen (make-hash))
    (define acc '())
    (define total 0)
    (for ([spec (in-list tier-specs)]
          #:break (>= total max-total))
      (define pts (car spec))
      (define cap (cdr spec))
      (define added 0)
      (for ([pt (in-list pts)]
            #:break (or (>= added cap) (>= total max-total)))
        (define k (pt-key pt))
        (unless (hash-has-key? seen k)
          (hash-set! seen k #t)
          (set! acc (cons pt acc))
          (set! added (add1 added))
          (set! total (add1 total)))))
    (reverse acc))

  ;; Relaxed safety fallback: preserves terrain `placement_grid`, relaxes BFS/layout-safety (and
  ;; AABBs for Terran production, Bunker/MissileTurret/GhostAcademy) when strict checks fail;
  ;; widens Terran production fallback rings to `22.0` so crowded mains never deadlock!
  (define (relaxed-safety-cands)
    (define relax-aabbs?
      (or needs-terran-addon-clearance?
          (memq canon-bldg '(bunker missile-turret ghost-academy))))
    (define rel-rad
      (cond
        [(and requires-pylon-power? has-completed-pylon?) 6.5]
        [needs-terran-addon-clearance? (max 22.0 max-radius)]
        [else (max 18.0 max-radius)]))
    (define rel-spacing
      (if (or needs-terran-addon-clearance?
              (memq canon-bldg '(bunker missile-turret ghost-academy)))
          (min 1.5 min-spacing)
          min-spacing))
    (define rel-pad-clr
      (if (or is-zerg-creep-bldg? needs-terran-addon-clearance?)
          tight-pad-clearance
          4.5))
    (define rel-budget (box 260))
    (define raw-rel
      (interleave-lists
       (for/list ([ap (in-list anchors)]
                  #:break (<= (unbox rel-budget) 0))
         (collect-spiral-candidates (car ap) (cdr ap) existing-units
                                    #:min-spacing rel-spacing
                                    #:max-radius rel-rad
                                    #:step 1.0
                                    #:limit (if ws-active? 16 4)
                                    #:max-evals 140
                                    #:eval-budget rel-budget
                                    #:extra-reserved-points extra-reserved-points
                                    #:ws-active-placement? ws-active?
                                    #:reserved-aabbs (if relax-aabbs? '() eff-reserved-aabbs)
                                    #:expansion-pads expansion-pads
                                    #:min-pad-clearance rel-pad-clr
                                    #:bldg-sym canon-bldg
                                    #:game-info game-info
                                    #:check-bfs #f
                                    #:layout-safety-ok? #f))))
    (dedup-point2ds (take raw-rel (min 36 (length raw-rel)))))

  (define (compute-inmain-safe-anchors base-pt)
    (define bx (car base-pt))
    (define by (cdr base-pt))
    (define near-mins
      (for/list ([u (in-list existing-units)]
                 #:when (and (sc2-unit-is-mineral-field? u)
                             (let ([p (sc2-unit-pos u)])
                               (<= (pt-dist bx by (sc2-point3d-x p) (sc2-point3d-y p)) 13.0))))
        (sc2-unit-pos u)))
    (define-values (ux uy)
      (if (pair? near-mins)
          (let* ([cnt (length near-mins)]
                 [mcx (/ (for/sum ([p (in-list near-mins)]) (sc2-point3d-x p)) cnt)]
                 [mcy (/ (for/sum ([p (in-list near-mins)]) (sc2-point3d-y p)) cnt)]
                 [dx (- bx mcx)]
                 [dy (- by mcy)]
                 [d (max 0.5 (sqrt (+ (* dx dx) (* dy dy))))])
            (values (/ dx d) (/ dy d)))
          (values 0.7071 0.7071)))
    (define enemy-gnd-pts
      (for/list ([u (in-list existing-units)]
                 #:when (and (= (sc2-unit-alliance u) 4)
                             (not (= (sc2-unit-display-type u) 4))
                             (not (sc2-unit-is-flying u))))
        (define p (sc2-unit-pos u))
        (cons (sc2-point3d-x p) (sc2-point3d-y p))))
    (define raw-pts
      (for/list ([ang (in-list '(0.0 0.65 -0.65 1.30 -1.30))])
        (define ca (cos ang))
        (define sa (sin ang))
        (define rx (- (* ux ca) (* uy sa)))
        (define ry (+ (* ux sa) (* uy ca)))
        (cons (max SC2-MAP-PLAYABLE-MIN-COORD (min SC2-MAP-PLAYABLE-MAX-COORD (+ bx (* 6.0 rx))))
              (max SC2-MAP-PLAYABLE-MIN-COORD (min SC2-MAP-PLAYABLE-MAX-COORD (+ by (* 6.0 ry)))))))
    (define-values (safe-pts cont-pts)
      (partition (lambda (pt)
                   (for/and ([ep (in-list enemy-gnd-pts)])
                     (> (pt-dist (car pt) (cdr pt) (car ep) (cdr ep)) 5.5)))
                 raw-pts))
    (append safe-pts cont-pts))

  (define (near-base-emergency-cands)
    (define inmain-em-pts
      (if (and emergency-rush-bldg? (not (and requires-pylon-power? has-completed-pylon?)))
          (take (compute-inmain-safe-anchors safe-base-anchor) 3)
          '()))
    ;; W16-P1-2-wire: Extract ALL grounded friendly TownHalls (main/natural/3rd, uncontested & least-crowded
    ;; first) so crowded-main Terran Barracks/Factory/Starport ALWAYS have overflow `5x3`/`3x3` anchors!
    (define th-em-anchors
      (if needs-terran-addon-clearance?
          (let* ([ths
                  (for/list ([u (in-list existing-units)]
                             #:when (and (= (sc2-unit-alliance u) 1)
                                         (not (= (sc2-unit-display-type u) 4))
                                         (sc2-unit-is-townhall? u)
                                         (not (sc2-unit-is-flying u))
                                         (>= (sc2-unit-build-progress u) 0.50)))
                    (define p (sc2-unit-pos u))
                    (cons (sc2-point3d-x p) (sc2-point3d-y p)))]
                 [enemy-gnd
                  (for/list ([u (in-list existing-units)]
                             #:when (and (= (sc2-unit-alliance u) 4)
                                         (not (= (sc2-unit-display-type u) 4))
                                         (not (sc2-unit-is-flying u))
                                         (not (sc2-unit-is-structure? u))))
                    (define p (sc2-unit-pos u))
                    (cons (sc2-point3d-x p) (sc2-point3d-y p)))]
                 [ally-structs
                  (for/list ([u (in-list existing-units)]
                             #:when (and (= (sc2-unit-alliance u) 1)
                                         (not (= (sc2-unit-display-type u) 4))
                                         (sc2-unit-is-structure? u)
                                         (not (sc2-unit-is-flying u))))
                    (define p (sc2-unit-pos u))
                    (cons (sc2-point3d-x p) (sc2-point3d-y p)))]
                 [scored
                  (for/list ([tp (in-list ths)])
                    (define cont?
                      (ormap (lambda (ep) (<= (pt-dist (car tp) (cdr tp) (car ep) (cdr ep)) 10.0))
                             enemy-gnd))
                    (define crowd
                      (count (lambda (sp) (<= (pt-dist (car tp) (cdr tp) (car sp) (cdr sp)) 12.0))
                             ally-structs))
                    (list tp (if cont? 1 0) crowd))])
            (map first
                 (sort scored
                       (lambda (a b)
                         (if (= (second a) (second b))
                             (< (third a) (third b))
                             (< (second a) (second b)))))))
          '()))
    (define em-anchors
      (let* ([raw
              (remove-duplicates
               (cond
                 [(null? anchors) (append inmain-em-pts th-em-anchors (list safe-base-anchor))]
                 [needs-terran-addon-clearance?
                  (append th-em-anchors anchors (list safe-base-anchor))]
                 [emergency-rush-bldg?
                  (append inmain-em-pts anchors (list safe-base-anchor))]
                 [else anchors]))]
             [em-cap (if needs-terran-addon-clearance? 5 12)])
        (if (> (length raw) em-cap) (take raw em-cap) raw)))
    (define em-rad
      (cond
        [(and requires-pylon-power? has-completed-pylon?) 6.5]
        [is-zerg-creep-bldg? 8.5]
        [needs-terran-addon-clearance? 22.0]
        [else 18.0]))
    (define em-spacing
      (cond
        [is-zerg-creep-bldg? (min 1.15 min-spacing)]
        [needs-terran-addon-clearance? (min 1.25 min-spacing)]
        [else (min 2.0 min-spacing)]))
    (define em-pad-clr
      (if (or is-zerg-creep-bldg? needs-terran-addon-clearance?)
          tight-pad-clearance
          4.5))
    (define (collect-em gi)
      (define em-budget (box 300))
      (define raw-em
        (interleave-lists
         (for/list ([ap (in-list em-anchors)]
                    #:break (<= (unbox em-budget) 0))
           (collect-spiral-candidates (car ap) (cdr ap) existing-units
                                      #:min-spacing em-spacing
                                      #:max-radius em-rad
                                      #:step 1.0
                                      #:limit (if ws-active? 16 4)
                                      #:max-evals 140
                                      #:eval-budget em-budget
                                      #:extra-reserved-points extra-reserved-points
                                      #:ws-active-placement? ws-active?
                                      #:reserved-aabbs '()
                                      #:expansion-pads expansion-pads
                                      #:min-pad-clearance em-pad-clr
                                      #:bldg-sym canon-bldg
                                      #:game-info gi
                                      #:check-bfs #f
                                      #:layout-safety-ok? #f
                                      #:skip-terran-addon-reserve? (and needs-terran-addon-clearance?
                                                                        (not require-addon-clear?))))))
      (dedup-point2ds (take raw-em (min 48 (length raw-em)))))
    ;; W12-P0-3-wire: Preserve `game-info` (`pl-grid`) first so emergency batches only query buildable
    ;; ground (never cliffs/void); only drop `game-info` if `pl-grid` yielded zero spots!
    (define grid-em (if game-info (collect-em game-info) '()))
    (if (pair? grid-em) grid-em (collect-em #f)))

  (define (collect-creep-tight-cands max-r safety? gi?)
    (define creep-budget (box 240))
    (define pts
      (interleave-lists
       (for/list ([ap (in-list anchors)]
                  #:break (<= (unbox creep-budget) 0))
         (collect-spiral-candidates (car ap) (cdr ap) existing-units
                                    #:min-spacing (min 1.15 min-spacing)
                                    #:max-radius max-r
                                    #:step 1.0
                                    #:limit (if ws-active? 16 4)
                                    #:max-evals 120
                                    #:eval-budget creep-budget
                                    #:extra-reserved-points extra-reserved-points
                                    #:ws-active-placement? ws-active?
                                    #:reserved-aabbs eff-reserved-aabbs
                                    #:expansion-pads expansion-pads
                                    #:min-pad-clearance tight-pad-clearance
                                    #:bldg-sym canon-bldg
                                    #:game-info (and gi? game-info)
                                    #:check-bfs (and gi? safety? shared-check-bfs)
                                    #:layout-safety-ok? (and safety? shared-layout-safety-ok?)))))
    (dedup-point2ds (take pts (min 36 (length pts)))))

  (define rpc-deferred-by-budget? (box #f))

  (define (query-single-batch batch0)
    (define batch (filter-unqueried batch0))
    (cond
      [(null? batch) #f]
      [(not (consume-placement-rpc-budget! rpc-budget))
       (set-box! rpc-deferred-by-budget? #t)
       #f]
      [else
       (for ([pt (in-list batch)])
         (hash-set! queried-keys (pt-key pt) #t))
       (define q-items
         (for/list ([pt (in-list batch)])
           (sc2-query-placement ab-id (sc2-point2d-x pt) (sc2-point2d-y pt) 0)))
       (define q-resp
         (sc2-ws-rpc! ws-conn
                      (make-request-query-placement q-items
                                                    #:ignore-resource-requirements? #t)))
       (define q-results (sc2-response-query-placements q-resp))
       (cond
         [(and (null? q-results) (pair? batch)) (first batch)]
         [else
          (for/first ([pt (in-list batch)]
                      [res (in-list q-results)]
                      #:when (= res 1))
            pt)])]))

  (define (query-dual-batch batch0)
    (define batch (filter-unqueried batch0))
    (cond
      [(null? batch) (values '() '())]
      [(not (consume-placement-rpc-budget! rpc-budget))
       (set-box! rpc-deferred-by-budget? #t)
       (values '() '())]
      [else
       (for ([pt (in-list batch)])
         (hash-set! queried-keys (pt-key pt) #t))
       (define q-items
         (append*
          (for/list ([pt (in-list batch)])
            (define cx (sc2-point2d-x pt))
            (define cy (sc2-point2d-y pt))
            (list (sc2-query-placement ab-id cx cy 0)
                  (sc2-query-placement 319
                                       (+ cx SC2-TERRAN-ADDON-OFFSET-X)
                                       (+ cy SC2-TERRAN-ADDON-OFFSET-Y)
                                       0)))))
       (define q-resp
         (sc2-ws-rpc! ws-conn
                      (make-request-query-placement q-items
                                                    #:ignore-resource-requirements? #t)))
       (values batch (sc2-response-query-placements q-resp))]))

  ;; Single batched RequestQuery RPC under `ws-active?`: combines primary, relaxed/creep-tight,
  ;; and near-base emergency tiers in priority order into ONE RPC instead of 4-8 serial cascades.
  (define resolved-pt
    (cond
      [ws-active?
       (cond
         [needs-terran-addon-clearance?
          ;; Dual QueryPlacement: verify both the 3x3 facility at (cx, cy) AND a 2x2 Supply Depot (319)
          ;; at the East (+X) add-on slot (cx + 2.5, cy - 0.5) in ONE single batched RPC!
          ;; W17-P0-1-wire: After 1 `5x3` miss (`SC2-TERRAN-5X3-MISS-CACHE`, cleared on structure-sig
          ;; change), immediately fall back to a 64-slot pure `3x3` single-query batch prioritizing
          ;; least-crowded overflow bases (`th-em-anchors`) instead of stalling in `5x3` retries!
          ;; Strictly enforces `both-valid-pt` when `require-addon-clear?` is `#t` (add-on relocation).
          (define use-fast-3x3-fallback?
            (and (not require-addon-clear?)
                 (not first-rax-allow-wall-3x3?)
                 (or prefer-3x3-fallback?
                     (terran-5x3-miss-active? canon-bldg anchor-x anchor-y neg-cd-cur-loop))))
          (cond
            [use-fast-3x3-fallback?
             (define em-raw (near-base-emergency-cands))
             (define rel-raw (relaxed-safety-cands))
             (define unified-3x3
               (merge-priority-batches
                (list (cons em-raw 36)
                      (cons rel-raw 16)
                      (cons raw-cands 64))
                64))
             (query-single-batch unified-3x3)]
            [else
             (define rel-raw (relaxed-safety-cands))
             (define rel-pts
               (let ([ac (filter-addon-clear rel-raw #:ignore-reserved-aabbs? #t)])
                 (if (pair? ac) (append ac rel-raw) rel-raw)))
             (define em-raw (near-base-emergency-cands))
             (define em-ac (filter-addon-clear em-raw #:ignore-reserved-aabbs? #t))
             (define unified-dual
               (merge-priority-batches
                (list (cons cands 20)
                      (cons rel-pts 10)
                      (cons em-ac 10)
                      (cons em-raw 48))
                48))
             (define-values (cands-q q-results) (query-dual-batch unified-dual))
             (define (record-5x3-miss!)
               (when (and canon-bldg (not require-addon-clear?))
                 (hash-set! SC2-TERRAN-5X3-MISS-CACHE
                            (list canon-bldg
                                  (inexact->exact (round anchor-x))
                                  (inexact->exact (round anchor-y)))
                            neg-cd-cur-loop)))
             (cond
               [(null? cands-q) #f]
               [(null? q-results) (first cands-q)]
               [(>= (length q-results) (* 2 (length cands-q)))
                (define wall-seal-pt
                  (and first-rax-allow-wall-3x3?
                       (let ([valid-wall-pts
                              (for/list ([pt (in-list cands-q)]
                                         [idx (in-naturals 0)]
                                         #:when (and (<= (pt-dist wall-ref-x wall-ref-y
                                                                  (sc2-point2d-x pt) (sc2-point2d-y pt))
                                                         2.55)
                                                     (= (list-ref q-results (* 2 idx)) 1)))
                                (cons pt (= (list-ref q-results (+ (* 2 idx) 1)) 1)))])
                         (and (not (null? valid-wall-pts))
                              (car (argmin (lambda (entry)
                                             (define pt (car entry))
                                             (define addon-ok? (cdr entry))
                                             (- (* 10.0 (pt-dist wall-ref-x wall-ref-y
                                                                 (sc2-point2d-x pt) (sc2-point2d-y pt)))
                                                (if addon-ok? 0.25 0.0)))
                                           valid-wall-pts))))))
                (define both-valid-pt
                  (for/first ([pt (in-list cands-q)]
                              [idx (in-naturals 0)]
                              #:when (and (= (list-ref q-results (* 2 idx)) 1)
                                          (= (list-ref q-results (+ (* 2 idx) 1)) 1)))
                    pt))
                (define main-valid-pt
                  (for/first ([pt (in-list cands-q)]
                              [idx (in-naturals 0)]
                              #:when (= (list-ref q-results (* 2 idx)) 1))
                    pt))
                (when (and (not both-valid-pt) (not wall-seal-pt))
                  (record-5x3-miss!))
                (cond
                  [require-addon-clear? both-valid-pt]
                  [(or wall-seal-pt both-valid-pt main-valid-pt) => values]
                  [else
                   ;; 1-miss immediate 3x3 overflow fallback across unqueried emergency/relaxed candidates
                   (define unq-3x3
                     (filter-unqueried
                      (merge-priority-batches (list (cons em-raw 48) (cons rel-raw 64)) 64)))
                   (and (pair? unq-3x3)
                        (query-single-batch unq-3x3))])]
               [else
                (for/first ([pt (in-list cands-q)]
                            [res (in-list q-results)]
                            #:when (= res 1))
                  pt)])])]
         [else
          (define p1 (filter-pylon-powered cands))
          (define p2
            (cond
              [is-zerg-creep-bldg?
               (append (if (null? p1) (collect-creep-tight-cands 8.5 #t #t) '())
                       (collect-creep-tight-cands 14.0 #f #t))]
              [else
               (filter-pylon-powered (relaxed-safety-cands))]))
          (define p3 (filter-pylon-powered (near-base-emergency-cands)))
          (define unified-single
            (merge-priority-batches
             (list (cons p1 36)
                   (cons p2 16)
                   (cons p3 64))
             64))
          (query-single-batch unified-single)])]
      [require-addon-clear?
       (define ac-primary (filter-addon-clear cands))
       (cond
         [(pair? ac-primary) (first ac-primary)]
         [else
          (define ac-fallback
            (filter-addon-clear
             (dedup-point2ds (append (relaxed-safety-cands) (near-base-emergency-cands)))
             #:ignore-reserved-aabbs? #t))
          (and (pair? ac-fallback) (first ac-fallback))])]
      [(null? cands)
       (define em-cands
         (if is-zerg-creep-bldg?
             (let ([t1 (collect-creep-tight-cands 8.5 #t #t)])
               (if (pair? t1)
                   t1
                   (let ([t2 (collect-creep-tight-cands 8.5 #f #t)])
                     (if (pair? t2) t2 (near-base-emergency-cands)))))
             (dedup-point2ds (append (relaxed-safety-cands) (near-base-emergency-cands)))))
       (cond
         [(not (null? em-cands)) (first em-cands)]
         [(and (static-footprint-placement-ok? pl-grid anchor-x anchor-y cand-hw cand-hh)
               (or (not check-bfs) (< (check-bfs anchor-x anchor-y 4) +inf.0)))
          (sc2-point2d anchor-x anchor-y)]
         [else
          (sc2-point2d (car safe-base-anchor) (cdr safe-base-anchor))])]
      [else
       (first cands)]))
  (cond
    [(and ws-active? resolved-pt pos-cache-key)
     (when (> (hash-count SC2-PLACEMENT-POS-CACHE) 256)
       (hash-clear! SC2-PLACEMENT-POS-CACHE))
     (hash-set! SC2-PLACEMENT-POS-CACHE pos-cache-key (list neg-cd-cur-loop resolved-pt))]
    [(and (not resolved-pt) (not (unbox rpc-deferred-by-budget?)))
     (when step-fail-key
       (hash-set! SC2-STEP-PLACEMENT-FAIL-CACHE step-fail-key #t))
     (when (and ws-active? neg-cd-key)
       (hash-set! SC2-PLACEMENT-NEG-COOLDOWN neg-cd-key neg-cd-cur-loop))
     (when late-all-pylons-neg-key
       (hash-set! SC2-PLACEMENT-NEG-COOLDOWN late-all-pylons-neg-key neg-cd-cur-loop))])
  resolved-pt)))))

(define (find-best-expansion-placement ws-conn th-ab home-x home-y units
                                       #:req-x [req-x #f]
                                       #:req-y [req-y #f]
                                       #:game-info [game-info #f]
                                       #:remembered-enemies [remembered-enemies #f]
                                       #:rpc-budget [rpc-budget #f]
                                       #:cur-loop [cur-loop-arg #f])
  (define self-units
    (filter (lambda (u) (and (= (sc2-unit-alliance u) 1)
                             (not (= (sc2-unit-display-type u) 4))))
            units))
  (define neutral-units (filter (lambda (u) (= (sc2-unit-alliance u) 3)) units))
  (define enemy-units
    (filter (lambda (u) (and (= (sc2-unit-alliance u) 4)
                             (not (= (sc2-unit-display-type u) 4))))
            units))
  (define all-townhalls
    (filter (lambda (u)
              (and (sc2-unit-is-townhall? u)
                   (not (= (sc2-unit-display-type u) 4))))
            units))
  (define in-flight-th-targets
    (for*/list ([w (in-list self-units)]
                #:when (and (sc2-unit-is-worker? w)
                            (not (worker-build-order-stuck? w)))
                [o (in-list (sc2-unit-orders w))]
                #:when (and (memv (sc2-unit-order-ability-id o) '(318 880 1152))
                            (any-point? (sc2-unit-order-target-pos o))))
      (define tp (sc2-unit-order-target-pos o))
      (cons (any-point-x tp) (any-point-y tp))))
  (define all-blocking-res
    (filter (lambda (u)
              (or (sc2-unit-is-mineral-field? u)
                  (sc2-unit-is-vespene-geyser? u)))
            neutral-units))
  (define path-grid (and (sc2-game-info? game-info) (sc2-game-info-pathing-grid game-info)))
  (define solved-bases (solve-all-map-expansion-bases neutral-units game-info))
  (define ordered-bases
    (if (not (null? solved-bases))
        (order-expansions-from-origin solved-bases home-x home-y path-grid neutral-units)
        ;; Minimal synthetic fallback if < 4 minerals and 0 geysers
        (for/list ([c (in-list (cluster-resource-centroids all-blocking-res game-info))]
                   #:when (> (pt-dist home-x home-y (first c) (second c)) SC2-BASE-RESOURCE-RADIUS))
          (hash 'x (first c) 'y (second c) 'minerals (third c) 'geysers '()))))

  ;; 1. Filter out already-occupied or in-flight-expanding bases
  (define raw-open-bases
    (filter (lambda (b)
              (define bx (hash-ref b 'x))
              (define by (hash-ref b 'y))
              (and (> (pt-dist home-x home-y bx by) SC2-BASE-RESOURCE-RADIUS)
                   (not (ormap (lambda (th)
                                 (define tp (sc2-unit-pos th))
                                 (<= (pt-dist bx by (sc2-point3d-x tp) (sc2-point3d-y tp))
                                     SC2-TOWNHALL-EXCLUSION-RADIUS))
                               all-townhalls))
                   (not (ormap (lambda (tp)
                                 (<= (pt-dist bx by (car tp) (cdr tp)) 10.0))
                               in-flight-th-targets))))
            ordered-bases))

  ;; 2. Exclude bases camped by live enemies OR remembered enemy structures/units
  (define (base-camped-by-live-enemy? bx by)
    (ormap (lambda (e)
             (define ep (sc2-unit-pos e))
             (define esym (sc2-id->unit-symbol (sc2-unit-unit-type e) 'unknown))
             (define d (pt-dist bx by (sc2-point3d-x ep) (sc2-point3d-y ep)))
             (cond
               [(memq esym '(overlord overlord-cocoon overseer overseer-siege-mode
                             observer observer-siege-mode changeling changeling-zealot
                             changeling-marine-shield changeling-marine
                             changeling-zergling-wings changeling-zergling))
                #f]
               [(sc2-unit-is-worker? e)
                (<= d 4.5)]
               [else
                (<= d 11.5)]))
           enemy-units))
  (define (base-camped-by-remembered-enemy? bx by)
    (and (hash? remembered-enemies)
         (for/or ([(_etag pt) (in-hash remembered-enemies)])
           (and (pair? pt)
                (<= (pt-dist bx by (car pt) (cdr pt)) 11.5)))))

  (define uncamped-open-bases
    (filter (lambda (b)
              (define bx (hash-ref b 'x))
              (define by (hash-ref b 'y))
              (and (not (base-camped-by-live-enemy? bx by))
                   (not (base-camped-by-remembered-enemy? bx by))))
            raw-open-bases))
  (define live-uncamped-open-bases
    (filter (lambda (b)
              (not (base-camped-by-live-enemy? (hash-ref b 'x) (hash-ref b 'y))))
            raw-open-bases))
  (define candidate-bases0
    (cond
      [(not (null? uncamped-open-bases)) uncamped-open-bases]
      [(not (null? live-uncamped-open-bases)) live-uncamped-open-bases]
      [else raw-open-bases]))

  ;; 3. Honor explicit `(expand req-x req-y)` when it matches an open, uncamped solved pad within 8.5 tiles
  (define candidate-bases
    (if (and (real? req-x) (real? req-y)
             (> (pt-dist home-x home-y req-x req-y) SC2-BASE-RESOURCE-RADIUS)
             (not (null? candidate-bases0)))
        (let ([matched
               (argmin (lambda (b) (pt-dist req-x req-y (hash-ref b 'x) (hash-ref b 'y)))
                       candidate-bases0)])
          (if (<= (pt-dist req-x req-y (hash-ref matched 'x) (hash-ref matched 'y)) 8.5)
              (cons matched (filter (lambda (b) (not (eq? b matched))) candidate-bases0))
              candidate-bases0))
        candidate-bases0))

  ;; Generate exact solved pad first, followed by tight legal 5x5 octagon half-tile offsets around (bx, by)
  (define pl-grid (and (sc2-game-info? game-info) (sc2-game-info-placement-grid game-info)))
  (define (pad-candidates-for-base b)
    (define bx (hash-ref b 'x))
    (define by (hash-ref b 'y))
    (define exact-pt (sc2-point2d bx by))
    (define local-blocking-res
      (filter (lambda (r)
                (define p (sc2-unit-pos r))
                (<= (pt-dist bx by (sc2-point3d-x p) (sc2-point3d-y p)) 20.0))
              all-blocking-res))
    (define raw-nearby-legal
      (sort
       (for*/list ([dx (in-range -4.0 4.1 1.0)]
                   [dy (in-range -4.0 4.1 1.0)]
                   #:when (not (and (= dx 0.0) (= dy 0.0)))
                   [px (in-value (+ (floor bx) 0.5 dx))]
                   [py (in-value (+ (floor by) 0.5 dy))]
                   #:when (and (>= px SC2-MAP-PLAYABLE-MIN-COORD) (<= px SC2-MAP-PLAYABLE-MAX-COORD)
                               (>= py SC2-MAP-PLAYABLE-MIN-COORD) (<= py SC2-MAP-PLAYABLE-MAX-COORD)
                               (sc2-townhall-all-resources-legal? px py local-blocking-res)))
         (sc2-point2d px py))
       <
       #:key (lambda (pt) (pt-dist bx by (sc2-point2d-x pt) (sc2-point2d-y pt)))))
    (define nearby-legal
      (if (sc2-image-grid? pl-grid)
          (let ([grid-ok (filter (lambda (pt)
                                   (static-footprint-placement-ok?
                                    pl-grid (sc2-point2d-x pt) (sc2-point2d-y pt) 2.5 2.5))
                                 raw-nearby-legal)])
            (if (not (null? grid-ok)) grid-ok raw-nearby-legal))
          raw-nearby-legal))
    (if (sc2-townhall-all-resources-legal? bx by local-blocking-res)
        (cons exact-pt nearby-legal)
        (if (not (null? nearby-legal)) nearby-legal (list exact-pt))))

  (cond
    [(null? candidate-bases)
     (find-verified-building-placement ws-conn th-ab (+ home-x 20.0) (+ home-y 20.0) units
                                       #:min-spacing 4.5 #:max-radius 12.0 #:step 1.0
                                       #:bldg-sym 'hatchery #:game-info game-info
                                       #:rpc-budget rpc-budget #:cur-loop cur-loop-arg)]
    [(and (sc2-ws-conn? ws-conn) (not (sc2-ws-conn-closed? ws-conn)))
     ;; Batch up to 6 BFS-ordered open bases into ONE single prioritized RequestQuery RPC (<= 64 items)
     ;; preserving base #0's exact pad + octagon fallbacks first!
     (define subset (take candidate-bases (min 6 (length candidate-bases))))
     (define fallback-pt #f)
     (define seen-pts (make-hash))
     (define rev-batch '())
     (define batch-len 0)
     (for ([b (in-list subset)]
           [b-idx (in-naturals 0)]
           #:break (>= batch-len 64))
       (define cands (pad-candidates-for-base b))
       (when (and (not fallback-pt) (pair? cands))
         (set! fallback-pt (first cands)))
       (define per-base-cap (if (= b-idx 0) 24 8))
       (define added 0)
       (for ([pt (in-list cands)]
             #:break (or (>= added per-base-cap) (>= batch-len 64)))
         (define k (cons (inexact->exact (round (* 4.0 (sc2-point2d-x pt))))
                         (inexact->exact (round (* 4.0 (sc2-point2d-y pt))))))
         (unless (hash-has-key? seen-pts k)
           (hash-set! seen-pts k #t)
           (set! rev-batch (cons pt rev-batch))
           (set! added (add1 added))
           (set! batch-len (add1 batch-len)))))
     (define batch (reverse rev-batch))
     (cond
       [(null? batch)
        (or fallback-pt (sc2-point2d (+ home-x 20.0) (+ home-y 20.0)))]
       [(not (consume-placement-rpc-budget! rpc-budget))
        #f]
       [else
        (define q-items
          (for/list ([pt (in-list batch)])
            (sc2-query-placement th-ab (sc2-point2d-x pt) (sc2-point2d-y pt) 0)))
        (define q-resp
          (sc2-ws-rpc! ws-conn
                       (make-request-query-placement q-items
                                                     #:ignore-resource-requirements? #t)))
        (define q-results (sc2-response-query-placements q-resp))
        (or (for/first ([pt (in-list batch)]
                        [res (in-list q-results)]
                        #:when (= res 1))
              pt)
            fallback-pt
            (sc2-point2d (+ home-x 20.0) (+ home-y 20.0)))])]
    [else
     (first (pad-candidates-for-base (first candidate-bases)))]))

;; W4-TAC-2-wire: Shared Archon-merge safety guards (never merge armed HTs >= 50en when enemies are
;; present or > 50en unconditionally, and never merge any Templar pair while targetable enemy combat
;; units are within 8.5t of the merge midpoint). Preserves safe home warp-in Archons (50.0en with
;; 0 visible combat enemies) and >= 3 Mutalisk AA-Archon emergency fusion (> 4.5t from Mutalisks).
(define SC2-ARCHON-MERGE-NONCOMBAT-SYMS
  '(larva egg cocoon
    overlord overlord-cocoon overlord-transport overlord-transport-cocoon
    overseer overseer-siege-mode
    observer observer-siege-mode
    warp-prism warp-prism-phasing medivac
    changeling changeling-zealot changeling-marine-shield changeling-marine
    changeling-zergling-wings changeling-zergling
    creep-tumor creep-tumor-burrowed creep-tumor-queen
    nydus-canal mule))

(define SC2-ARCHON-MERGE-DEFENSIVE-BLDG-SYMS
  '(photon-cannon spine-crawler spore-crawler bunker missile-turret planetary-fortress))

(define (sc2-unit-targetable-enemy-combat? e)
  (and (sc2-unit? e)
       (= (sc2-unit-alliance e) 4)
       (not (= (sc2-unit-display-type e) 4))
       (not (= (sc2-unit-display-type e) 2))
       (not (= (sc2-unit-cloak e) 1))
       (not (sc2-unit-is-worker? e))
       (let ([esym (sc2-id->unit-symbol (sc2-unit-unit-type e) 'unknown)])
         (and (not (memq esym SC2-ARCHON-MERGE-NONCOMBAT-SYMS))
              (or (not (sc2-unit-is-structure? e))
                  (memq esym SC2-ARCHON-MERGE-DEFENSIVE-BLDG-SYMS))))))

(define (sc2-templar-energy-allows-archon-merge? u enemy-combat enemy-muta-cnt)
  (define usym (sc2-id->unit-symbol (sc2-unit-unit-type u) 'unknown))
  (cond
    [(not (eq? usym 'high-templar)) #t]
    [(>= enemy-muta-cnt 3) #t]
    [(> (sc2-unit-energy u) 50.0) #f]
    [(and (>= (sc2-unit-energy u) 50.0) (pair? enemy-combat)) #f]
    [else #t]))

(define (sc2-archon-merge-midpoint-safe? u1 u2 enemy-combat enemy-muta-cnt)
  (define p1 (sc2-unit-pos u1))
  (define p2 (sc2-unit-pos u2))
  (define mx (* 0.5 (+ (sc2-point3d-x p1) (sc2-point3d-x p2))))
  (define my (* 0.5 (+ (sc2-point3d-y p1) (sc2-point3d-y p2))))
  (not (ormap (lambda (e)
                (define ep (sc2-unit-pos e))
                (define esym (sc2-id->unit-symbol (sc2-unit-unit-type e) 'unknown))
                (define danger-r
                  (if (and (>= enemy-muta-cnt 3) (eq? esym 'mutalisk))
                      4.5
                      8.5))
                (<= (pt-dist mx my (sc2-point3d-x ep) (sc2-point3d-y ep)) danger-r))
              enemy-combat)))

(define (sc2-archon-merge-pair-safe? u1 u2 enemy-units)
  (define enemy-combat (filter sc2-unit-targetable-enemy-combat? enemy-units))
  (define enemy-muta-cnt
    (count (lambda (e) (eq? (sc2-id->unit-symbol (sc2-unit-unit-type e) 'unknown) 'mutalisk))
           enemy-combat))
  (and (sc2-templar-energy-allows-archon-merge? u1 enemy-combat enemy-muta-cnt)
       (sc2-templar-energy-allows-archon-merge? u2 enemy-combat enemy-muta-cnt)
       (sc2-archon-merge-midpoint-safe? u1 u2 enemy-combat enemy-muta-cnt)))

;; W6-TAC-2: Zerg combat morph safety guard (`baneling`, `ravager`, `lurker`, `brood-lord`).
;; Never morph a fighting unit into an immobile 12-24s cocoon while a live targetable enemy
;; combat unit sits within 10.0 tiles (`100.0` sq-dist). Prefers rear/idle units first.
(define SC2-ZERG-COMBAT-MORPH-SYMS
  '(baneling ravager lurker lurker-mp brood-lord broodlord))

(define SC2-ZERG-COMBAT-MORPH-DANGER-RADIUS-SQ 100.0)

(define (sc2-unit-nearest-enemy-combat-dist-sq u enemy-combat)
  (if (null? enemy-combat)
      +inf.0
      (let* ([up (sc2-unit-pos u)]
             [ux (sc2-point3d-x up)]
             [uy (sc2-point3d-y up)])
        (for/fold ([best-d2 +inf.0]) ([e (in-list enemy-combat)])
          (define ep (sc2-unit-pos e))
          (define dx (- ux (sc2-point3d-x ep)))
          (define dy (- uy (sc2-point3d-y ep)))
          (define d2 (+ (* dx dx) (* dy dy)))
          (if (< d2 best-d2) d2 best-d2)))))

(define (sc2-zerg-combat-morph-unit-safe? u enemy-combat)
  (> (sc2-unit-nearest-enemy-combat-dist-sq u enemy-combat)
     SC2-ZERG-COMBAT-MORPH-DANGER-RADIUS-SQ))

;; Instant rally abilities never occupy a facility production or morph queue.
(define SC2-NON-BLOCKING-RALLY-ABILITIES '(195 211 212 3673 3690 3691))
(define (unit-blocking-order-count u)
  (count (lambda (o)
           (not (memv (sc2-unit-order-ability-id o) SC2-NON-BLOCKING-RALLY-ABILITIES)))
         (sc2-unit-orders u)))

(define (select-producer-tags-for-unit unit-sym self-units [enemy-units '()]
                                       #:unit-by-tag [pre-unit-by-tag #f]
                                       #:units-by-sym [units-by-sym #f])
  (define norm (normalize-sc2-name->symbol unit-sym))
  ;; Lazily map unit tags to unit structs only when an attached add-on tag (> 0) or unit position is inspected
  (define unit-by-tag-cache pre-unit-by-tag)
  (define (get-unit-by-tag)
    (or unit-by-tag-cache
        (let ([h (for/hasheqv ([u (in-list self-units)]
                               #:when (not (= (sc2-unit-display-type u) 4)))
                   (values (sc2-unit-tag u) u))])
          (set! unit-by-tag-cache h)
          h)))
  (define (units-of-types syms)
    (cond
      [(not (hash? units-by-sym)) self-units]
      [(and (pair? syms) (null? (cdr syms))) (hash-ref units-by-sym (car syms) '())]
      [else (for*/list ([s (in-list syms)]
                        [u (in-list (hash-ref units-by-sym s '()))])
              u)]))
  (define (facility-has-reactor? u)
    (define addon-tag (sc2-unit-add-on-tag u))
    (and (> addon-tag 0)
         (let ([addon-u (hash-ref (get-unit-by-tag) addon-tag #f)])
           (and addon-u
                (>= (sc2-unit-build-progress addon-u) SC2-BUILD-COMPLETE-PROGRESS)
                (not (not (memq (sc2-id->unit-symbol (sc2-unit-unit-type addon-u))
                                '(barracks-reactor factory-reactor starport-reactor reactor))))))))
  (define (facility-has-techlab? u)
    (define addon-tag (sc2-unit-add-on-tag u))
    (and (> addon-tag 0)
         (let ([addon-u (hash-ref (get-unit-by-tag) addon-tag #f)])
           (and addon-u
                (>= (sc2-unit-build-progress addon-u) SC2-BUILD-COMPLETE-PROGRESS)
                (not (not (memq (sc2-id->unit-symbol (sc2-unit-unit-type addon-u))
                                '(barracks-tech-lab barracks-techlab
                                  factory-tech-lab factory-techlab
                                  starport-tech-lab starport-techlab
                                  tech-lab techlab))))))))
  (define needs-techlab? (sc2-unit-requires-techlab? norm))
  ;; Returns producer tags ordered with completely idle (0-order) facilities first,
  ;; and includes a 0-order Reactor facility's tag twice so multi-unit production waves
  ;; can utilize both Reactor queue slots in a single step.
  (define (idle-ready-of-types syms)
    (define reactor-both-tags '())
    (define reactor-one-tags '())
    (define bare-zero-tags '())
    (define techlab-zero-tags '())
    (for ([u (in-list (units-of-types syms))]
          #:when (let ([usym (sc2-id->unit-symbol (sc2-unit-unit-type u))])
                   (and (not (= (sc2-unit-display-type u) 4))
                        (memq usym syms)
                        (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)
                        (not (and (sc2-unit-is-structure? u) (sc2-unit-is-flying u)))
                        (or (not (memq usym '(gateway warp-gate warpgate robotics-facility stargate)))
                            (sc2-unit-is-powered u))
                        (or (not needs-techlab?)
                            (facility-has-techlab? u)))))
      (define wg-busy?
        (and (= (sc2-unit-unit-type u) 133)
             (< (unbox SC2-WARPGATE-LAST-LOOP)
                (hash-ref SC2-WARPGATE-COOLDOWN-UNTIL (sc2-unit-tag u) 0))))
      (define raw-blocking-orders (unit-blocking-order-count u))
      (define n-orders (if wg-busy? (max 1 raw-blocking-orders) raw-blocking-orders))
      (define has-reactor? (and (not needs-techlab?) (facility-has-reactor? u)))
      (define has-tl? (facility-has-techlab? u))
      (define utag (sc2-unit-tag u))
      (cond
        [(and has-reactor? (= n-orders 0))
         (set! reactor-both-tags (cons utag (cons utag reactor-both-tags)))]
        [(and has-reactor? (= n-orders 1))
         (set! reactor-one-tags (cons utag reactor-one-tags))]
        [(and (= n-orders 0) (not has-tl?))
         (set! bare-zero-tags (cons utag bare-zero-tags))]
        [(= n-orders 0)
         (set! techlab-zero-tags (cons utag techlab-zero-tags))]))
    (if (and (not needs-techlab?)
             (ormap (lambda (s) (memq s '(barracks factory starport))) syms))
        (append (reverse reactor-both-tags)
                (reverse reactor-one-tags)
                (reverse bare-zero-tags)
                (reverse techlab-zero-tags))
        (append (reverse reactor-both-tags)
                (reverse bare-zero-tags)
                (reverse techlab-zero-tags)
                (reverse reactor-one-tags))))
  (define (morph-ready-of-types syms)
    (define enemy-combat
      (if (null? enemy-units)
          '()
          (filter sc2-unit-targetable-enemy-combat? enemy-units)))
    (define has-enemies? (pair? enemy-combat))
    (define zero-order-cands '())
    (define active-combat-cands '())
    (for ([u (in-list (units-of-types syms))]
          #:when (let ([usym (sc2-id->unit-symbol (sc2-unit-unit-type u))])
                   (and (not (= (sc2-unit-display-type u) 4))
                        (memq usym syms)
                        (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)
                        (not (sc2-unit-is-hallucination u))
                        (not (sc2-unit-is-burrowed u)))))
      (define ords (sc2-unit-orders u))
      (define first-ab (if (pair? ords) (sc2-unit-order-ability-id (car ords)) 0))
      (define first-sym (and (> first-ab 0) (sc2-id->ability-symbol first-ab #f)))
      (define prot (and (> first-ab 0) (sc2-order-protection-class first-ab)))
      (unless (or (memq prot '(morph channel cast-walk))
                  (and first-sym (string-prefix? (symbol->string first-sym) "morph-")))
        (define d2 (if has-enemies? (sc2-unit-nearest-enemy-combat-dist-sq u enemy-combat) +inf.0))
        (when (> d2 SC2-ZERG-COMBAT-MORPH-DANGER-RADIUS-SQ)
          (define utag (sc2-unit-tag u))
          (if (null? ords)
              (set! zero-order-cands (cons (cons utag d2) zero-order-cands))
              (set! active-combat-cands (cons (cons utag d2) active-combat-cands))))))
    (define (order-tags cands)
      (if (and has-enemies? (pair? cands) (pair? (cdr cands)))
          (map car (sort cands > #:key cdr))
          (map car (reverse cands))))
    (append (order-tags zero-order-cands) (order-tags active-combat-cands)))
  (cond
    ;; Zerg larva-trained units
    [(memq norm '(drone overlord zergling roach hydralisk mutalisk corruptor
                  infestor swarm-host swarmhost ultralisk viper))
     (for/list ([u (in-list (if (hash? units-by-sym) (hash-ref units-by-sym 'larva '()) self-units))]
                #:when (and (= (sc2-unit-unit-type u) 151)
                            (not (= (sc2-unit-display-type u) 4)))) ;; LARVA
       (sc2-unit-tag u))]
    [(eq? norm 'queen)
     (idle-ready-of-types '(hatchery lair hive))]
    [(eq? norm 'lair)
     (idle-ready-of-types '(hatchery))]
    [(eq? norm 'hive)
     (idle-ready-of-types '(lair))]
    [(eq? norm 'greater-spire)
     (idle-ready-of-types '(spire))]
    [(memq norm '(lurker-den lurker-den-mp))
     (idle-ready-of-types '(drone))]
    [(eq? norm 'baneling)
     (morph-ready-of-types '(zergling))]
    [(eq? norm 'ravager)
     (morph-ready-of-types '(roach))]
    [(memq norm '(lurker lurker-mp))
     (morph-ready-of-types '(hydralisk))]
    [(memq norm '(brood-lord broodlord))
     (morph-ready-of-types '(corruptor))]
    [(eq? norm 'overseer)
     ;; Safe Overlord morph: never morph an Overlord within 12 tiles of enemy anti-air; sort closest to army/Main
     (define cand-tags (idle-ready-of-types '(overlord overlord-transport)))
     (define ubt (get-unit-by-tag))
     (define cand-units (filter-map (lambda (t) (hash-ref ubt t #f)) cand-tags))
     (define aa-enemies
       (filter (lambda (e)
                 (define esym (sc2-id->unit-symbol (sc2-unit-unit-type e) 'unknown))
                 (or (memq esym '(missile-turret photon-cannon spore-crawler bunker
                                  queen marine stalker hydralisk viking viking-fighter
                                  phoenix void-ray voidray corruptor mutalisk thor thor-ap
                                  cyclone archon sentry ghost battlecruiser carrier tempest
                                  widow-mine-burrowed))
                     (> (hash-ref (sc2-unit-combat-stats esym) 'air-dps 0.0) 0.0)))
               enemy-units))
     (define safe-ovies
       (filter (lambda (u)
                 (define up (sc2-unit-pos u))
                 (not (ormap (lambda (e)
                               (define ep (sc2-unit-pos e))
                               (<= (pt-dist (sc2-point3d-x up) (sc2-point3d-y up)
                                            (sc2-point3d-x ep) (sc2-point3d-y ep))
                                   12.0))
                             aa-enemies)))
               cand-units))
     (define army-units
       (filter (lambda (u)
                 (define sym (sc2-id->unit-symbol (sc2-unit-unit-type u)))
                 (and (not (sc2-unit-is-structure? u))
                      (not (sc2-unit-is-worker? u))
                      (not (sc2-non-combat-or-summon-sym? sym))))
               self-units))
     (define-values (ref-x ref-y)
       (cond
         [(not (null? army-units))
          (define n (exact->inexact (length army-units)))
          (values (/ (for/sum ([u (in-list army-units)]) (sc2-point3d-x (sc2-unit-pos u))) n)
                  (/ (for/sum ([u (in-list army-units)]) (sc2-point3d-y (sc2-unit-pos u))) n))]
         [else
          (define ths (sort-townhalls-main-first (filter sc2-unit-is-townhall? self-units)))
          (if (not (null? ths))
              (let ([tp (sc2-unit-pos (first ths))])
                (values (sc2-point3d-x tp) (sc2-point3d-y tp)))
              (values SC2-DEFAULT-HOME-BASE-X SC2-DEFAULT-HOME-BASE-Y))]))
     (map sc2-unit-tag
          (sort safe-ovies <
                #:key (lambda (u)
                        (define up (sc2-unit-pos u))
                        (pt-dist ref-x ref-y (sc2-point3d-x up) (sc2-point3d-y up)))))]
    [(eq? norm 'overlord-transport)
     (idle-ready-of-types '(overlord))]
    ;; Terran
    [(eq? norm 'scv)
     (idle-ready-of-types '(command-center orbital-command planetary-fortress))]
    [(memq norm '(orbital-command planetary-fortress))
     (idle-ready-of-types '(command-center))]
    [(memq norm '(marine marauder reaper ghost))
     (idle-ready-of-types '(barracks))]
    [(memq norm '(hellion hellbat widow-mine siege-tank cyclone thor))
     (idle-ready-of-types '(factory))]
    [(memq norm '(viking viking-fighter medivac liberator raven banshee battlecruiser))
     (idle-ready-of-types '(starport))]
    ;; Protoss
    [(memq norm '(probe mothership))
     (idle-ready-of-types '(nexus))]
    [(memq norm '(warp-gate warpgate))
     (idle-ready-of-types '(gateway))]
    [(memq norm '(zealot stalker sentry adept high-templar dark-templar))
     ;; W11-P0-3-wire: Prefer ready powered WarpGates BEFORE un-morphed Gateways for faster
     ;; 3.6s warp-in delivery and so idle Gateways stay free to morph into WarpGates (1518).
     (append (idle-ready-of-types '(warp-gate warpgate))
             (idle-ready-of-types '(gateway)))]
    [(memq norm '(observer immortal warp-prism colossus disruptor))
     (idle-ready-of-types '(robotics-facility))]
    [(memq norm '(phoenix void-ray voidray oracle carrier tempest))
     (idle-ready-of-types '(stargate))]
    [(eq? norm 'archon)
     ;; Safe Archon fusion (W4-TAC-2-wire): include moving/attacking combat Templars, NEVER merge
     ;; armed HTs (>= 50en with combat enemies visible or > 50en unconditionally, except >= 3 Mutalisks),
     ;; and NEVER merge any Templar pair while targetable enemy combat units sit within 8.5t of the midpoint!
     (define enemy-combat (filter sc2-unit-targetable-enemy-combat? enemy-units))
     (define enemy-muta-cnt
       (count (lambda (e)
                (eq? (sc2-id->unit-symbol (sc2-unit-unit-type e) 'unknown) 'mutalisk))
              enemy-combat))
     (define eligible-templars
       (filter (lambda (u)
                 (define usym (sc2-id->unit-symbol (sc2-unit-unit-type u) 'unknown))
                 (define ords (sc2-unit-orders u))
                 (define first-ab (if (pair? ords) (sc2-unit-order-ability-id (car ords)) 0))
                 (and (memq usym '(high-templar dark-templar))
                      (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)
                      (not (= (sc2-unit-display-type u) 4))
                      (not (sc2-unit-is-hallucination u))
                      (not (memv first-ab '(1766 1767 1036 140)))
                      (sc2-templar-energy-allows-archon-merge? u enemy-combat enemy-muta-cnt)))
               (units-of-types '(high-templar dark-templar))))
     (define best-pair #f)
     (define best-score +inf.0)
     (define best-any-pair #f)
     (define best-any-dist +inf.0)
     (for* ([i (in-range (length eligible-templars))]
            [j (in-range (add1 i) (length eligible-templars))])
       (define u1 (list-ref eligible-templars i))
       (define u2 (list-ref eligible-templars j))
       (when (sc2-archon-merge-midpoint-safe? u1 u2 enemy-combat enemy-muta-cnt)
         (define p1 (sc2-unit-pos u1))
         (define p2 (sc2-unit-pos u2))
         (define d (pt-dist (sc2-point3d-x p1) (sc2-point3d-y p1)
                            (sc2-point3d-x p2) (sc2-point3d-y p2)))
         (when (< d best-any-dist)
           (set! best-any-dist d)
           (set! best-any-pair (list (sc2-unit-tag u1) (sc2-unit-tag u2))))
         (when (<= d 24.0)
           (define score (+ d (* 0.02 (+ (sc2-unit-energy u1) (sc2-unit-energy u2)))))
           (when (< score best-score)
             (set! best-score score)
             (set! best-pair (list (sc2-unit-tag u1) (sc2-unit-tag u2)))))))
     (or best-pair best-any-pair '())]
    [else '()]))

(define (select-researcher-tag upg-sym self-units #:units-by-sym [units-by-sym #f])
  (define norm (normalize-sc2-name->symbol upg-sym))
  (define str (symbol->string norm))
  (define target-bldgs
    (cond
      [(or (memq norm '(zergling-movementspeed metabolic-boost zergling-attackspeed adrenal-glands))
           (string-contains? str "zergling"))
       '(spawning-pool)]
      [(memq norm '(glial-reconstitution tunneling-claws))
       '(roach-warren)]
      [(memq norm '(centrifugal-hooks centrifical-hooks))
       '(baneling-nest)]
      [(memq norm '(grooved-spines muscular-augments))
       '(hydralisk-den)]
      [(memq norm '(adaptive-talons lurker-range seismic-spines))
       '(lurker-den lurker-den-mp)]
      [(memq norm '(neural-parasite pathogen-glands microbial-shroud))
       '(infestation-pit)]
      [(memq norm '(chitinous-plating anabolic-synthesis))
       '(ultralisk-cavern)]
      [(or (string-contains? str "zerg-flyer")
           (string-contains? str "flyer-attacks")
           (string-contains? str "flyer-carapace"))
       '(spire greater-spire)]
      [(or (string-contains? str "zerg-melee")
           (string-contains? str "melee-attacks")
           (string-contains? str "zerg-missile")
           (string-contains? str "missile-attacks")
           (string-contains? str "zerg-ground")
           (string-contains? str "ground-carapace"))
       '(evolution-chamber)]
      [(memq norm '(burrow overlord-speed overlordspeed pneumatized-carapace))
       '(hatchery lair hive)]
      ;; Attached TechLabs only — unattached 'tech-lab (5) cannot research!
      [(memq norm '(stimpack combat-shield concussive-shells))
       '(barracks-tech-lab barracks-techlab)]
      [(memq norm '(infernal-preigniter infernal-pre-igniter drilling-claws
                    cyclone-lock-on-damage mag-field-accelerator smart-servos))
       '(factory-tech-lab factory-techlab)]
      [(memq norm '(banshee-cloak cloaking-field hyperflight-rotors
                    corvid-reactor caduceus-reactor medivac-caduceus-reactor
                    advanced-ballistics interference-matrix hurricane-thrusters))
       '(starport-tech-lab starport-techlab)]
      [(eq? norm 'personal-cloaking)
       '(ghost-academy)]
      [(memq norm '(weapon-refit yamato-cannon behemoth-reactor))
       '(fusion-core)]
      [(or (string-contains? str "terran-infantry")
           (string-contains? str "infantry-weapons")
           (string-contains? str "infantry-armor")
           (memq norm '(hi-sec-auto-tracking hisec-auto-tracking neosteel-armor)))
       '(engineering-bay)]
      [(or (string-contains? str "terran-vehicle")
           (string-contains? str "vehicle-weapons")
           (string-contains? str "vehicle-plating")
           (string-contains? str "vehicle-and-ship-plating")
           (string-contains? str "terran-ship")
           (string-contains? str "ship-weapons"))
       '(armory)]
      [(memq norm '(warpgate warp-gate warp-gate-research warpgate-research))
       '(cybernetics-core)]
      [(memq norm '(charge blink blink-tech resonating-glaives adept-piercing-attack))
       '(twilight-council)]
      [(memq norm '(psi-storm psistorm psistorm-tech psi-storm-tech psionic-storm))
       '(templar-archive templar-archives)]
      [(memq norm '(shadow-strike shadow-stride))
       '(dark-shrine)]
      [(memq norm '(extended-thermal-lance gravitic-booster gravitic-boosters gravitic-drive))
       '(robotics-bay robotics-support-bay)]
      [(memq norm '(flux-vanes anion-pulse-crystals tectonic-destabilizers))
       '(fleet-beacon)]
      [(or (string-contains? str "protoss-ground")
           (string-contains? str "ground-weapons")
           (string-contains? str "ground-armor")
           (string-contains? str "protoss-shields")
           (string-contains? str "shields-"))
       '(forge)]
      [(or (string-contains? str "protoss-air")
           (string-contains? str "air-weapons")
           (string-contains? str "air-armor"))
       '(cybernetics-core)]
      [else '()]))
  (define cand-research-units
    (cond
      [(not (hash? units-by-sym)) self-units]
      [(and (pair? target-bldgs) (null? (cdr target-bldgs)))
       (hash-ref units-by-sym (car target-bldgs) '())]
      [else (for*/list ([s (in-list target-bldgs)]
                        [u (in-list (hash-ref units-by-sym s '()))])
              u)]))
  (for/first ([u (in-list cand-research-units)]
              #:when (let ([usym (sc2-id->unit-symbol (sc2-unit-unit-type u))])
                       (and (not (= (sc2-unit-display-type u) 4))
                            (memq usym target-bldgs)
                            (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)
                            (not (sc2-unit-is-flying u))
                            (or (not (memq usym '(cybernetics-core forge twilight-council
                                                  templar-archive templar-archives dark-shrine
                                                  robotics-bay robotics-support-bay fleet-beacon)))
                                (sc2-unit-is-powered u))
                            (null? (sc2-unit-orders u)))))
    (sc2-unit-tag u)))

(define SC2-BUILDER-RESERVATION (make-hasheqv))

;; Checks active SC2 build/morph/resume orders on a worker (excluding stuck orders).
(define (worker-has-explicit-build-order? w [cur-loop (unbox SC2-WARPGATE-LAST-LOOP)])
  (and (not (worker-build-order-stuck? w cur-loop))
       (ormap (lambda (o)
                (define ab (sc2-unit-order-ability-id o))
                (define ab-sym (sc2-id->ability-symbol ab #f))
                (or (and ab-sym (string-prefix? (symbol->string ab-sym) "build-"))
                    (memq (sc2-order-protection-class ab) '(build-structure resume-building))))
              (sc2-unit-orders w))))

;; Returns #t if `w` holds an active SC2 build order or an unexpired wire builder reservation.
(define (worker-has-build-order? w [cur-loop #f] [self-structures #f])
  (define wtag (sc2-unit-tag w))
  (cond
    [(worker-has-explicit-build-order? w (or cur-loop (unbox SC2-WARPGATE-LAST-LOOP)))
     (when (and cur-loop (hash-has-key? SC2-BUILDER-RESERVATION wtag))
       (hash-remove! SC2-BUILDER-RESERVATION wtag))
     #t]
    [cur-loop
     (define res (hash-ref SC2-BUILDER-RESERVATION wtag #f))
     (and res
          (let ([issued-loop (first res)]
                [expires-loop (second res)]
                [tx (third res)]
                [ty (fourth res)])
            (cond
              [(or (<= cur-loop issued-loop) (>= cur-loop expires-loop))
               (when (>= cur-loop expires-loop)
                 (hash-remove! SC2-BUILDER-RESERVATION wtag))
               #f]
              [(and (list? self-structures)
                    (ormap (lambda (su)
                             (define sp (sc2-unit-pos su))
                             (<= (pt-dist tx ty (sc2-point3d-x sp) (sc2-point3d-y sp)) 1.25))
                           self-structures))
               (hash-remove! SC2-BUILDER-RESERVATION wtag)
               #f]
              [else #t])))]
    [else #f]))

;; Returns #t if `u` is carrying cargo (including Harvest.Return orders) or already gathering
;; gas / a mineral patch at the same base as `patch-id` (permitting explicit cross-base transfers).
(define (worker-busy-harvesting-mineral? u patch-id mineral-by-tag gas-bldg-tags-set mineral-fields)
  (or (worker-carrying-cargo? u)
      (ormap (lambda (o)
               (define ab (sc2-unit-order-ability-id o))
               (and (memv ab '(166 295 298 1183 3666))
                    (let ([otag (sc2-unit-order-target-unit-tag o)])
                      (cond
                        [(and (exact-integer? patch-id) (= otag patch-id)) #t]
                        [(set-member? gas-bldg-tags-set otag) #t]
                        [(null? mineral-fields) #t]
                        [else
                         (define cur-m (hash-ref mineral-by-tag otag #f))
                         (define tgt-m (and (exact-integer? patch-id) (hash-ref mineral-by-tag patch-id #f)))
                         (cond
                           [(not cur-m) #f]
                           [(not tgt-m) #t]
                           [else
                            (define cp (sc2-unit-pos cur-m))
                            (define tp (sc2-unit-pos tgt-m))
                            (<= (pt-dist (sc2-point3d-x cp) (sc2-point3d-y cp)
                                         (sc2-point3d-x tp) (sc2-point3d-y tp))
                                14.0)])]))))
             (sc2-unit-orders u))))

;; Exact Frame-0 Pro Worker Split (`4x2` close patches + `4x1` far patches):
;; Solves exact minimum-sum-Euclidean-distance worker-to-mineral-slot bipartite matching
;; and emits `<= 8` coalesced `HARVEST_GATHER (3666)` wire commands on the opening frame.
(define SC2-WORKER-ASSIGN-LAST-LOOP (box 0))
(define SC2-WORKER-PATCH-ASSIGNMENT (make-hasheqv))
(define SC2-WORKER-ANTIBOUNCE-COOLDOWN (make-hasheqv))

(define (classify-townhall-mineral-patches th mineral-fields [radius 11.5] [max-patches 8])
  (define tp (sc2-unit-pos th))
  (define hx (sc2-point3d-x tp))
  (define hy (sc2-point3d-y tp))
  (define with-dist
    (for/list ([m (in-list mineral-fields)]
               #:when (let* ([mp (sc2-unit-pos m)]
                             [d (pt-dist hx hy (sc2-point3d-x mp) (sc2-point3d-y mp))])
                        (<= d radius)))
      (define mp (sc2-unit-pos m))
      (cons (pt-dist hx hy (sc2-point3d-x mp) (sc2-point3d-y mp)) m)))
  (define sorted-pairs (sort with-dist < #:key car))
  (define capped
    (map cdr (if (> (length sorted-pairs) max-patches)
                 (take sorted-pairs max-patches)
                 sorted-pairs)))
  (define near-cnt (quotient (length capped) 2))
  (values (take capped near-cnt) (drop capped near-cnt) capped))

(define (townhall-combat-metrics th enemy-combat-units ally-combat-units radius)
  (define tp (sc2-unit-pos th))
  (define tx (sc2-point3d-x tp))
  (define ty (sc2-point3d-y tp))
  (define e-cnt 0)
  (define e-hp 0.0)
  (define a-hp 0.0)
  (for ([u (in-list enemy-combat-units)])
    (define up (sc2-unit-pos u))
    (when (<= (pt-dist tx ty (sc2-point3d-x up) (sc2-point3d-y up)) radius)
      (set! e-cnt (add1 e-cnt))
      (set! e-hp (+ e-hp (sc2-unit-health u) (sc2-unit-shield u)))))
  (for ([u (in-list ally-combat-units)])
    (define up (sc2-unit-pos u))
    (when (<= (pt-dist tx ty (sc2-point3d-x up) (sc2-point3d-y up)) radius)
      (set! a-hp (+ a-hp (sc2-unit-health u) (sc2-unit-shield u)))))
  (values e-cnt e-hp a-hp))

(define (townhall-offline? th mineral-fields enemy-units [ally-units '()])
  (define-values (_near _far local-mins)
    (classify-townhall-mineral-patches th mineral-fields 11.5 8))
  (define enemy-combat-units
    (filter (lambda (u)
              (and (not (sc2-unit-is-worker? u))
                   (not (sc2-unit-is-structure? u))))
            enemy-units))
  (define ally-combat-units
    (filter (lambda (u)
              (define sym (sc2-id->unit-symbol (sc2-unit-unit-type u)))
              (and (not (sc2-unit-is-worker? u))
                   (not (sc2-unit-is-structure? u))
                   (not (memq sym '(larva egg overlord overseer observer warp-prism mule)))))
            ally-units))
  (define-values (e-cnt e-hp a-hp)
    (townhall-combat-metrics th enemy-combat-units ally-combat-units 10.5))
  (define-values (e-cnt-fire _e-hp-fire _a-hp-fire)
    (townhall-combat-metrics th enemy-combat-units ally-combat-units 15.0))
  (define max-hp (sc2-unit-health-max th))
  (or (null? local-mins)
      (and (>= e-cnt 2) (> e-hp (* 1.3 a-hp)))
      (and (> max-hp 0.0)
           (< (sc2-unit-health th) (* 0.30 max-hp))
           (>= e-cnt-fire 1))))

(define (frame0-pro-worker-split-commands obs)
  (cond
    [(not (sc2-observation? obs)) '()]
    [else
     (define obs-loop (sc2-observation-game-loop obs))
     (when (or (<= obs-loop 8) (< obs-loop (unbox SC2-WORKER-ASSIGN-LAST-LOOP)))
       (hash-clear! SC2-WORKER-PATCH-ASSIGNMENT)
       (hash-clear! SC2-WORKER-ANTIBOUNCE-COOLDOWN))
     (set-box! SC2-WORKER-ASSIGN-LAST-LOOP obs-loop)
     (define units (sc2-observation-units obs))
     (define self-units
       (filter (lambda (u) (and (= (sc2-unit-alliance u) 1)
                                (not (= (sc2-unit-display-type u) 4))))
               units))
     (define neutral-units (filter (lambda (u) (= (sc2-unit-alliance u) 3)) units))
     (define townhalls (sort-townhalls-main-first (filter sc2-unit-is-townhall? self-units)))
     (define workers
       (sort (filter (lambda (w)
                       (and (sc2-unit-is-worker? w)
                            (not (memv 57 (sc2-unit-buff-ids w)))))
                     self-units)
             <
             #:key sc2-unit-tag))
     (define mineral-fields
       (filter (lambda (m)
                 (and (sc2-unit-is-mineral-field? m)
                      (= (sc2-unit-display-type m) 1)
                      (not (memq (sc2-id->unit-symbol (sc2-unit-unit-type m))
                                 '(mineral-field-450 lab-mineral-field lab-mineral-field-750)))))
               neutral-units))
     (cond
       [(or (null? townhalls) (null? workers) (> (length workers) 16) (null? mineral-fields))
        '()]
       [else
        (define th0 (first townhalls))
        (define-values (near-mins far-mins base-mins)
          (classify-townhall-mineral-patches th0 mineral-fields 11.5 8))
        (cond
          [(null? base-mins) '()]
          [else
           (define n (length workers))
           (define n-mins (length base-mins))
           (define near-cnt (length near-mins))
           ;; Build `n` target slots: 1st Near -> 1st Far -> 2nd Near -> 2nd Far
           ;; For 12 workers on 8 patches: 4 Near Patches x2 (8) + 4 Far Patches x1 (4).
           (define slots-list
             (cond
               [(<= n n-mins)
                (take base-mins n)]
               [else
                (define extra (- n n-mins))
                (define near-extra (min near-cnt extra))
                (define far-extra (- extra near-extra))
                (append base-mins
                        (take near-mins near-extra)
                        (if (and (> far-extra 0) (pair? far-mins))
                            (for/list ([k (in-range far-extra)])
                              (list-ref far-mins (modulo k (length far-mins))))
                            '()))]))
           (define workers-vec (list->vector workers))
           (define slots-vec (list->vector slots-list))
           (define dist-mat (make-vector (* n n) 0.0))
           (for* ([i (in-range n)]
                  [j (in-range n)])
             (define wp (sc2-unit-pos (vector-ref workers-vec i)))
             (define mp (sc2-unit-pos (vector-ref slots-vec j)))
             (vector-set! dist-mat (+ (* i n) j)
                          (pt-dist (sc2-point3d-x wp) (sc2-point3d-y wp)
                                   (sc2-point3d-x mp) (sc2-point3d-y mp))))
           (define (d-ref i j) (vector-ref dist-mat (+ (* i n) j)))
           (define assign-vec (make-vector n 0))
           (cond
             [(<= n 14)
              ;; Exact O(n * 2^n) bitmask DP (4,096 states for n=12, < 0.1ms)
              (define (popcount m)
                (let lp ([x m] [c 0])
                  (if (zero? x) c (lp (bitwise-and x (sub1 x)) (add1 c)))))
              (define num-masks (arithmetic-shift 1 n))
              (define dp (make-vector num-masks +inf.0))
              (define choice (make-vector num-masks -1))
              (vector-set! dp 0 0.0)
              (for ([mask (in-range 0 (sub1 num-masks))])
                (define cur-c (vector-ref dp mask))
                (when (< cur-c +inf.0)
                  (define w-idx (popcount mask))
                  (for ([j (in-range n)]
                        #:when (not (bitwise-bit-set? mask j)))
                    (define nxt (bitwise-ior mask (arithmetic-shift 1 j)))
                    (define cand (+ cur-c (d-ref w-idx j)))
                    (when (< cand (vector-ref dp nxt))
                      (vector-set! dp nxt cand)
                      (vector-set! choice nxt j)))))
              (let bt ([w-idx (sub1 n)]
                       [mask (sub1 num-masks)])
                (when (>= w-idx 0)
                  (define j (max 0 (vector-ref choice mask)))
                  (vector-set! assign-vec w-idx j)
                  (bt (sub1 w-idx) (bitwise-xor mask (arithmetic-shift 1 j)))))]
             [else
              ;; Greedy closest-pair + 2-opt swap refinement for n = 15..16
              (define used-s (make-vector n #f))
              (for ([i (in-range n)])
                (define best-j 0)
                (define best-d +inf.0)
                (for ([j (in-range n)]
                      #:when (not (vector-ref used-s j)))
                  (when (< (d-ref i j) best-d)
                    (set! best-d (d-ref i j))
                    (set! best-j j)))
                (vector-set! used-s best-j #t)
                (vector-set! assign-vec i best-j))
              (let opt-lp ([iter 0])
                (when (< iter 24)
                  (define improved? #f)
                  (for* ([i (in-range n)]
                         [k (in-range (add1 i) n)])
                    (define ji (vector-ref assign-vec i))
                    (define jk (vector-ref assign-vec k))
                    (when (< (+ (d-ref i jk) (d-ref k ji) 1e-9)
                             (+ (d-ref i ji) (d-ref k jk)))
                      (vector-set! assign-vec i jk)
                      (vector-set! assign-vec k ji)
                      (set! improved? #t)))
                  (when improved? (opt-lp (add1 iter)))))])
           ;; Coalesce assigned workers per target mineral patch tag (<= 8 commands)
           (define by-patch (make-hasheqv))
           (for ([i (in-range n)])
             (define wtag (sc2-unit-tag (vector-ref workers-vec i)))
             (define ptag (sc2-unit-tag (vector-ref slots-vec (vector-ref assign-vec i))))
             (hash-set! SC2-WORKER-PATCH-ASSIGNMENT wtag ptag)
             (hash-set! by-patch ptag (cons wtag (hash-ref by-patch ptag '()))))
           (filter-map
            (lambda (m)
              (define ptag (sc2-unit-tag m))
              (define wtags (reverse (hash-ref by-patch ptag '())))
              (and (pair? wtags)
                   (mark-urgent-survival-cmd!
                    (sc2-raw-unit-command 3666 #f ptag wtags #f))))
            base-mins)])])]))

(define compute-initial-worker-split-commands frame0-pro-worker-split-commands)

(define SC2-WORKER-TRANSFER-LAST-LOOP (box 0))
(define SC2-WORKER-TRANSFER-COOLDOWN-UNTIL (make-hasheqv))
(define SC2-GAS-PULL-HYSTERESIS-LATCH (box #f))

(define (saturate-workers-and-gas-commands obs
                                           #:excluded-worker-tags [excluded-worker-tags (seteqv)]
                                           #:role-leases [role-leases #f]
                                           #:reserved-aabbs [reserved-aabbs '()]
                                           #:game-info [game-info #f])
  (void reserved-aabbs game-info)
  (define cur-loop (sc2-observation-game-loop obs))
  (when (or (<= cur-loop 8) (< cur-loop (unbox SC2-WORKER-TRANSFER-LAST-LOOP)))
    (hash-clear! SC2-WORKER-TRANSFER-COOLDOWN-UNTIL)
    (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
    (set-box! SC2-GAS-PULL-HYSTERESIS-LATCH #f))
  (set-box! SC2-WORKER-TRANSFER-LAST-LOOP cur-loop)
  (when (< cur-loop (unbox SC2-WORKER-ASSIGN-LAST-LOOP))
    (hash-clear! SC2-WORKER-PATCH-ASSIGNMENT)
    (hash-clear! SC2-WORKER-ANTIBOUNCE-COOLDOWN))
  (set-box! SC2-WORKER-ASSIGN-LAST-LOOP cur-loop)

  (define pc (sc2-observation-player-common obs))
  (define cur-min (sc2-player-common-minerals pc))
  (define cur-gas (sc2-player-common-vespene pc))
  (define units (sc2-observation-units obs))
  (define self-units
    (filter (lambda (u) (and (= (sc2-unit-alliance u) 1)
                             (not (= (sc2-unit-display-type u) 4))))
            units))
  (define neutral-units (filter (lambda (u) (= (sc2-unit-alliance u) 3)) units))
  (define mineral-fields
    (filter (lambda (m)
              (and (sc2-unit-is-mineral-field? m)
                   (= (sc2-unit-display-type m) 1)))
            neutral-units))
  (define enemy-units
    (filter (lambda (u) (and (= (sc2-unit-alliance u) 4)
                             (not (= (sc2-unit-display-type u) 4))))
            units))
  (define enemy-combat-units
    (filter (lambda (u)
              (and (not (sc2-unit-is-worker? u))
                   (not (sc2-unit-is-structure? u))))
            enemy-units))
  (define ally-combat-units
    (filter (lambda (u)
              (define sym (sc2-id->unit-symbol (sc2-unit-unit-type u)))
              (and (not (sc2-unit-is-worker? u))
                   (not (sc2-unit-is-structure? u))
                   (not (memq sym '(larva egg overlord overseer observer warp-prism mule)))))
            self-units))
  (define (th-is-nonflying? u)
    (and (sc2-unit-is-townhall? u)
         (not (sc2-unit-is-flying u))
         (not (memq (sc2-id->unit-symbol (sc2-unit-unit-type u))
                    '(command-center-flying orbital-command-flying)))))
  (define ready-townhalls
    (sort-townhalls-main-first
     (filter (lambda (u)
               (and (th-is-nonflying? u)
                    (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)))
             self-units)))
  (define all-ready-gas-bldgs
    (filter (lambda (u)
              (and (sc2-unit-is-gas-building? u)
                   (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)))
            self-units))
  ;; Exclude depleted Vespene geysers (vespene-contents == 0 && ideal-harvesters == 0 in live SC2, #5129552)
  ;; so a mined-out main Extractor never pins `(first under-gas)` and starves remaining Extractors at 0G/min!
  (define ready-gas-bldgs
    (filter (lambda (u)
              (or (> (sc2-unit-vespene-contents u) 0)
                  (> (sc2-unit-ideal-harvesters u) 0)))
            all-ready-gas-bldgs))
  (define depleted-gas-tags
    (for/seteqv ([u (in-list all-ready-gas-bldgs)]
                 #:when (and (<= (sc2-unit-vespene-contents u) 0)
                             (<= (sc2-unit-ideal-harvesters u) 0)))
      (sc2-unit-tag u)))
  (define all-gas-tags (list->seteqv (map sc2-unit-tag ready-gas-bldgs)))

  (define (worker-returning-cargo? w)
    (worker-carrying-cargo? w))

  (define sat-self-structures
    (filter sc2-unit-is-structure? self-units))
  (define workers
    (filter (lambda (w)
              (define wtag (sc2-unit-tag w))
              (and (sc2-unit-is-worker? w)
                   (not (memv 57 (sc2-unit-buff-ids w)))
                   (not (set-member? excluded-worker-tags wtag))
                   (not (and (hash? role-leases)
                             (unit-leased-above? role-leases wtag 'harvester cur-loop)))
                   (not (worker-has-build-order? w cur-loop sat-self-structures))))
            self-units))
  (define idle-workers
    (filter (lambda (w)
              (or (null? (sc2-unit-orders w))
                  (worker-build-order-stuck? w cur-loop)))
            workers))
  (define (in-flight-workers-targeting-tag tag)
    (count (lambda (w)
             (ormap (lambda (o) (= (sc2-unit-order-target-unit-tag o) tag))
                    (sc2-unit-orders w)))
           workers))

  ;; Helper: live mineral fields strictly near a specific TownHall (<= 11.5 tiles, capped to 8 patches).
  (define (minerals-near-townhall th)
    (define-values (_near _far sorted)
      (classify-townhall-mineral-patches th mineral-fields 11.5 8))
    sorted)

  (define (th-combat-unsafe? th)
    (define-values (e-cnt e-hp a-hp)
      (townhall-combat-metrics th enemy-combat-units ally-combat-units 10.5))
    (define-values (e-cnt-fire _ef _af)
      (townhall-combat-metrics th enemy-combat-units ally-combat-units 15.0))
    (define max-hp (sc2-unit-health-max th))
    (or (and (>= e-cnt 2) (> e-hp (* 1.3 a-hp)))
        (and (> max-hp 0.0)
             (< (sc2-unit-health th) (* 0.30 max-hp))
             (>= e-cnt-fire 1))))

  (define (th-local-offline? th)
    (define-values (_near _far local-mins)
      (classify-townhall-mineral-patches th mineral-fields 11.5 8))
    (or (null? local-mins)
        (th-combat-unsafe? th)))

  (define safe-gas-ready-townhalls
    (filter (lambda (th) (not (th-combat-unsafe? th))) ready-townhalls))

  (define (th-coming-online-safe? th)
    (define bp (sc2-unit-build-progress th))
    (and (th-is-nonflying? th)
         (>= bp 0.85)
         (< bp SC2-BUILD-COMPLETE-PROGRESS)
         (not (null? (minerals-near-townhall th)))
         (let-values ([(e-cnt e-hp a-hp)
                       (townhall-combat-metrics th enemy-combat-units ally-combat-units 12.0)])
           (or (= e-cnt 0)
               (and (< e-cnt 2) (<= e-hp (max 80.0 (* 1.0 a-hp))))))))

  (define (th-safety-score th)
    (define-values (e-cnt e-hp a-hp)
      (townhall-combat-metrics th enemy-combat-units ally-combat-units 12.0))
    (+ (* 1000.0 e-cnt) (max 0.0 (- e-hp (* 0.5 a-hp)))))

  (define-values (offline-townhalls online-ready-townhalls)
    (let lp ([rem ready-townhalls] [off '()] [on '()])
      (cond
        [(null? rem) (values (reverse off) (reverse on))]
        [(th-local-offline? (car rem))
         (lp (cdr rem) (cons (car rem) off) on)]
        [else
         (lp (cdr rem) off (cons (car rem) on))])))

  (define coming-online-townhalls
    (sort-townhalls-main-first (filter th-coming-online-safe? self-units)))

  (define online-townhalls
    (append online-ready-townhalls coming-online-townhalls))
  (define safe-online-townhalls
    (sort online-townhalls < #:key th-safety-score))

  (define owned-base-minerals
    (cond
      [(not (null? online-townhalls))
       (remove-duplicates (append* (map minerals-near-townhall online-townhalls)))]
      [(null? ready-townhalls) mineral-fields]
      [else '()]))

  (define th-near-ht (make-hasheqv))
  (define th-far-ht (make-hasheqv))
  (define th-min-tags-ht (make-hasheqv))
  (define min-is-far-ht (make-hasheqv))
  (define min-th-dist-online (make-hasheqv))
  (for ([th (in-list online-townhalls)])
    (define th-tag (sc2-unit-tag th))
    (define tp (sc2-unit-pos th))
    (define tx (sc2-point3d-x tp))
    (define ty (sc2-point3d-y tp))
    (define-values (near-m far-m all-m)
      (classify-townhall-mineral-patches th mineral-fields 11.5 8))
    (hash-set! th-near-ht th-tag near-m)
    (hash-set! th-far-ht th-tag far-m)
    (hash-set! th-min-tags-ht th-tag (list->seteqv (map sc2-unit-tag all-m)))
    (for ([m (in-list all-m)])
      (define mtag (sc2-unit-tag m))
      (define mp (sc2-unit-pos m))
      (define d (pt-dist tx ty (sc2-point3d-x mp) (sc2-point3d-y mp)))
      (define prev-d (hash-ref min-th-dist-online mtag +inf.0))
      (when (< d prev-d)
        (hash-set! min-th-dist-online mtag d)
        (hash-set! min-is-far-ht mtag (and (memq m far-m) #t)))))

  (define (th-effective-ideal th)
    (define ih (sc2-unit-ideal-harvesters th))
    (if (> ih 0)
        ih
        (min SC2-IDEAL-WORKERS-PER-MINERAL-LINE
             (* 2 (length (minerals-near-townhall th))))))

  (define (th-workers-targeting-mins th)
    (define tset (hash-ref th-min-tags-ht (sc2-unit-tag th) (seteqv)))
    (count (lambda (w)
             (ormap (lambda (o)
                      (and (memv (sc2-unit-order-ability-id o) '(166 295 298 1183 3666))
                           (set-member? tset (sc2-unit-order-target-unit-tag o))))
                    (sc2-unit-orders w)))
           workers))

  (define (th-effective-assigned th)
    (if (< (sc2-unit-build-progress th) SC2-BUILD-COMPLETE-PROGRESS)
        (max (sc2-unit-assigned-harvesters th)
             (th-workers-targeting-mins th))
        (sc2-unit-assigned-harvesters th)))

  (define (gas-eff-assigned u)
    (max (sc2-unit-assigned-harvesters u)
         (in-flight-workers-targeting-tag (sc2-unit-tag u))))

  (define active-gas-worker-count
    (count (lambda (w)
             (or (ormap (lambda (bid) (memv bid '(273 274 275))) (sc2-unit-buff-ids w))
                 (ormap (lambda (o)
                          (set-member? all-gas-tags (sc2-unit-order-target-unit-tag o)))
                        (sc2-unit-orders w))))
           workers))
  (define eff-active-gas-workers
    (max active-gas-worker-count
         (for/sum ([g (in-list ready-gas-bldgs)]) (gas-eff-assigned g))))

  (define (gas-near-any-th? gb th-list)
    (or (null? ready-townhalls)
        (let ([gp (sc2-unit-pos gb)])
          (ormap (lambda (th)
                   (define tp (sc2-unit-pos th))
                   (<= (pt-dist (sc2-point3d-x gp) (sc2-point3d-y gp)
                                (sc2-point3d-x tp) (sc2-point3d-y tp))
                       SC2-BASE-RESOURCE-RADIUS))
                 th-list))))

  (define (gas-bldg-threat-score gb)
    (define-values (e-cnt e-hp a-hp)
      (townhall-combat-metrics gb enemy-combat-units ally-combat-units 12.0))
    (define-values (close-gnd-cnt _cghp _cahp)
      (townhall-combat-metrics gb
                               (filter (lambda (e) (not (sc2-unit-is-flying e))) enemy-combat-units)
                               ally-combat-units
                               7.0))
    (+ (* 5000.0 close-gnd-cnt) (* 1000.0 e-cnt) (max 0.0 (- e-hp (* 0.5 a-hp)))))

  (define safe-ready-gas-bldgs
    (filter (lambda (u) (gas-near-any-th? u safe-gas-ready-townhalls))
            ready-gas-bldgs))
  (define safe-under-gas
    (sort
     (filter (lambda (u)
               (< (gas-eff-assigned u)
                  (max SC2-IDEAL-WORKERS-PER-GEYSER (sc2-unit-ideal-harvesters u))))
             safe-ready-gas-bldgs)
     <
     #:key gas-eff-assigned))

  ;; W17-P0-3 / L20-P0-1 (`#28` `GasZeroFreeze` 1 -> 0): When no ready gas building sits at a
  ;; combat-safe TownHall and vespene is critically low, score ALL live `ready-gas-bldgs` with a
  ;; unified threat score (`+150.0` mild preference for geysers near a surviving TownHall) so
  ;; zero-threat live Extractors/Refineries/Assimilators (`150`) ALWAYS beat enemy-camped geysers
  ;; (`26,000+`), and protect those fallback geysers from `0b` evacuation up to 300G.
  (define (emergency-gas-score gb)
    (+ (gas-bldg-threat-score gb)
       (if (gas-near-any-th? gb ready-townhalls) 0.0 150.0)))
  (define emergency-protected-gas-bldgs
    (if (and (null? safe-ready-gas-bldgs)
             (< cur-gas 300)
             (not (null? ready-gas-bldgs)))
        (let ([sorted (sort ready-gas-bldgs < #:key emergency-gas-score)])
          (take sorted (min 2 (length sorted))))
        '()))
  (define under-gas
    (cond
      [(pair? safe-under-gas) safe-under-gas]
      [(and (< cur-gas 250)
            (< eff-active-gas-workers 3)
            (pair? emergency-protected-gas-bldgs))
       (sort
        (filter (lambda (u)
                  (< (gas-eff-assigned u)
                     (max SC2-IDEAL-WORKERS-PER-GEYSER (sc2-unit-ideal-harvesters u))))
                emergency-protected-gas-bldgs)
        (lambda (a b)
          (define sa (emergency-gas-score a))
          (define sb (emergency-gas-score b))
          (if (< (abs (- sa sb)) 200.0)
              (< (gas-eff-assigned a) (gas-eff-assigned b))
              (< sa sb))))]
      [else '()]))
  (define under-townhalls
    (sort
     (filter (lambda (th)
               (and (not (null? (minerals-near-townhall th)))
                    (< (th-effective-assigned th) (th-effective-ideal th))))
             online-townhalls)
     <
     #:key th-safety-score))
  (define over-townhalls
    (filter (lambda (th)
              (> (sc2-unit-assigned-harvesters th) (th-effective-ideal th)))
            online-ready-townhalls))

  (define commanded-this-frame (mutable-seteqv))
  (define cmds '())
  (define (issue-gather! w target-tag
                         #:macro-econ? [macro-econ? #f]
                         #:allow-carrying-mineral? [allow-carrying-mineral? #f]
                         #:allow-carrying-gas? [allow-carrying-gas? #f])
    (when (or (not (worker-carrying-cargo? w))
              (and allow-carrying-mineral? (not (worker-carrying-gas? w)))
              allow-carrying-gas?)
      (set-add! commanded-this-frame (sc2-unit-tag w))
      (define raw-c (sc2-raw-unit-command 3666 #f target-tag (list (sc2-unit-tag w)) #f))
      (set! cmds
            (cons (if macro-econ? (mark-macro-econ-cmd! raw-c) raw-c)
                  cmds))))
  (define (worker-carrying-gas? w)
    (or (ormap (lambda (bid) (memv bid '(273 274 275)))
               (sc2-unit-buff-ids w))
        (ormap (lambda (o)
                 (and (eq? (sc2-canonical-order-ability (sc2-unit-order-ability-id o))
                           'harvest-return)
                      (set-member? all-gas-tags (sc2-unit-order-target-unit-tag o))))
               (sc2-unit-orders w))))
  (define (worker-carrying-mineral? w)
    (and (not (worker-carrying-gas? w))
         (or (ormap (lambda (bid) (memv bid '(271 272 276)))
                    (sc2-unit-buff-ids w))
             (ormap (lambda (o)
                      (eq? (sc2-canonical-order-ability (sc2-unit-order-ability-id o))
                           'harvest-return))
                    (sc2-unit-orders w)))))
  (define owned-min-by-tag
    (for/hasheqv ([m (in-list owned-base-minerals)])
      (values (sc2-unit-tag m) m)))
  (define min-th-dist
    (for/hasheqv ([m (in-list owned-base-minerals)])
      (define mtag (sc2-unit-tag m))
      (define mp (sc2-unit-pos m))
      (define mx (sc2-point3d-x mp))
      (define my (sc2-point3d-y mp))
      (define th-d
        (if (hash-has-key? min-th-dist-online mtag)
            (hash-ref min-th-dist-online mtag)
            (if (null? ready-townhalls)
                0.0
                (apply min
                       (map (lambda (th)
                              (define tp (sc2-unit-pos th))
                              (pt-dist (sc2-point3d-x tp) (sc2-point3d-y tp) mx my))
                            ready-townhalls)))))
      (values mtag th-d)))
  (define patch-worker-counts (make-hasheqv))
  (for ([w (in-list workers)])
    (define wtag (sc2-unit-tag w))
    (define ord-tgt
      (for/first ([o (in-list (sc2-unit-orders w))]
                  #:when (and (memv (sc2-unit-order-ability-id o) '(166 295 298 1183 3666))
                              (hash-has-key? owned-min-by-tag (sc2-unit-order-target-unit-tag o))))
        (sc2-unit-order-target-unit-tag o)))
    (define eff-tgt
      (or ord-tgt
          (let ([a (hash-ref SC2-WORKER-PATCH-ASSIGNMENT wtag #f)])
            (and a (hash-has-key? owned-min-by-tag a) a))))
    (when eff-tgt
      (hash-set! patch-worker-counts eff-tgt (add1 (hash-ref patch-worker-counts eff-tgt 0)))))

  ;; Priority slot selector: 1st Near -> 1st Far -> 2nd Near -> 2nd Far
  (define (pick-best-slot-patch w cand-mins)
    (define wp (sc2-unit-pos w))
    (define wx (sc2-point3d-x wp))
    (define wy (sc2-point3d-y wp))
    (define under2-mins
      (filter (lambda (m) (< (hash-ref patch-worker-counts (sc2-unit-tag m) 0) 2))
              cand-mins))
    (if (pair? under2-mins)
        (argmin (lambda (m)
                  (define mtag (sc2-unit-tag m))
                  (define mp (sc2-unit-pos m))
                  (define cnt (hash-ref patch-worker-counts mtag 0))
                  (define far? (hash-ref min-is-far-ht mtag #f))
                  (+ (* 100.0 (exact->inexact cnt))
                     (if far? 25.0 0.0)
                     (* 1.0 (hash-ref min-th-dist mtag 0.0))
                     (* 0.05 (pt-dist wx wy (sc2-point3d-x mp) (sc2-point3d-y mp)))))
                under2-mins)
        (argmin (lambda (m)
                  (define mtag (sc2-unit-tag m))
                  (define mp (sc2-unit-pos m))
                  (define cnt (hash-ref patch-worker-counts mtag 0))
                  (define far? (hash-ref min-is-far-ht mtag #f))
                  (+ (* 100.0 (exact->inexact cnt))
                     (if far? 25.0 0.0)
                     (* 0.1 (pt-dist wx wy (sc2-point3d-x mp) (sc2-point3d-y mp)))))
                cand-mins)))

  ;; 0b. Offline Base Evacuation & Orphaned Worker Recovery:
  ;;     Immediately evacuate mineral workers from combat-offline or mined-out TownHalls
  ;;     and orphaned harvest workers to the safest online under-saturated TownHall's Near Patches.
  (when (and (not (null? owned-base-minerals)) (not (null? safe-online-townhalls)))
    (define evac-dst-th
      (if (not (null? under-townhalls)) (first under-townhalls) (first safe-online-townhalls)))
    (define evac-cand-mins (minerals-near-townhall evac-dst-th))
    (define offline-min-tags
      (for/fold ([s (seteqv)]) ([oth (in-list offline-townhalls)])
        (for/fold ([s2 s]) ([m (in-list (minerals-near-townhall oth))])
          (define mtag (sc2-unit-tag m))
          (if (hash-has-key? owned-min-by-tag mtag)
              s2
              (set-add s2 mtag)))))
    (define online-gas-tags
      (for/seteqv ([gb (in-list (append safe-ready-gas-bldgs emergency-protected-gas-bldgs))])
        (sc2-unit-tag gb)))
    (define all-owned-ths (append ready-townhalls coming-online-townhalls))
    (when (not (null? evac-cand-mins))
      (for ([w (in-list workers)]
            #:when (let* ([wtag (sc2-unit-tag w)]
                          [wp (sc2-unit-pos w)]
                          [wx (sc2-point3d-x wp)]
                          [wy (sc2-point3d-y wp)]
                          [orders (sc2-unit-orders w)]
                          [targeting-online-min?
                           (ormap (lambda (o)
                                    (and (memv (sc2-unit-order-ability-id o) '(166 295 298 1183 3666))
                                         (hash-has-key? owned-min-by-tag (sc2-unit-order-target-unit-tag o))))
                                  orders)]
                          [targeting-online-gas?
                           (ormap (lambda (o) (set-member? online-gas-tags (sc2-unit-order-target-unit-tag o)))
                                  orders)]
                          [targeting-depleted-gas?
                           (ormap (lambda (o) (set-member? depleted-gas-tags (sc2-unit-order-target-unit-tag o)))
                                  orders)]
                          [unleashed-attack-chase?
                           (and (not (null? all-owned-ths))
                                (ormap (lambda (o)
                                         (memv (sc2-unit-order-ability-id o) '(23 3674 3675)))
                                       orders)
                                (for/and ([th (in-list all-owned-ths)])
                                  (define tp (sc2-unit-pos th))
                                  (> (pt-dist wx wy (sc2-point3d-x tp) (sc2-point3d-y tp)) 22.0)))]
                          [targeting-offline-or-orphan-min?
                           (ormap (lambda (o)
                                    (define ab (sc2-unit-order-ability-id o))
                                    (define tgt (sc2-unit-order-target-unit-tag o))
                                    (and (memv ab '(166 295 298 1183 3666))
                                         (or (set-member? offline-min-tags tgt)
                                             (and (> tgt 0)
                                                  (not (set-member? all-gas-tags tgt))
                                                  (not (hash-has-key? owned-min-by-tag tgt))))))
                                  orders)]
                          [near-offline-th?
                           (and (not (null? offline-townhalls))
                                (ormap (lambda (oth)
                                         (define tp (sc2-unit-pos oth))
                                         (<= (pt-dist wx wy (sc2-point3d-x tp) (sc2-point3d-y tp))
                                             SC2-BASE-RESOURCE-RADIUS))
                                       offline-townhalls)
                                (for/and ([onth (in-list online-townhalls)])
                                  (define tp (sc2-unit-pos onth))
                                  (> (pt-dist wx wy (sc2-point3d-x tp) (sc2-point3d-y tp))
                                     SC2-BASE-RESOURCE-RADIUS)))])
                     (and (not (set-member? commanded-this-frame wtag))
                          (not (worker-carrying-gas? w))
                          (not targeting-online-gas?)
                          (not targeting-online-min?)
                          (or targeting-offline-or-orphan-min?
                              targeting-depleted-gas?
                              unleashed-attack-chase?
                              (and near-offline-th? (not (worker-returning-cargo? w)))))))
        (define wtag (sc2-unit-tag w))
        (define best-min (pick-best-slot-patch w evac-cand-mins))
        (define bmtag (sc2-unit-tag best-min))
        (hash-set! patch-worker-counts bmtag (add1 (hash-ref patch-worker-counts bmtag 0)))
        (hash-set! SC2-WORKER-PATCH-ASSIGNMENT wtag bmtag)
        (issue-gather! w bmtag #:macro-econ? #t))))

  ;; 1. Send idle workers to mineral patches at under-saturated online TownHalls first
  ;;    using capacity-aware per-patch pairing (1st Near -> 1st Far -> 2nd Near -> 2nd Far);
  ;;    if no online mineral patches exist, cancel any expired stuck build order via Stop (3665).
  (cond
    [(and (not (null? idle-workers)) (not (null? owned-base-minerals)))
     (define candidate-mins
       (if (not (null? under-townhalls))
           (minerals-near-townhall (first under-townhalls))
           owned-base-minerals))
     (define sorted-cand-mins
       (sort candidate-mins < #:key (lambda (m) (hash-ref min-th-dist (sc2-unit-tag m) 999.0))))
     (for ([w (in-list idle-workers)]
           #:when (and (not (set-member? commanded-this-frame (sc2-unit-tag w)))
                       (not (worker-returning-cargo? w))))
       (define wtag (sc2-unit-tag w))
       (define best-min (pick-best-slot-patch w sorted-cand-mins))
       (define bmtag (sc2-unit-tag best-min))
       (hash-set! patch-worker-counts bmtag (add1 (hash-ref patch-worker-counts bmtag 0)))
       (hash-set! SC2-WORKER-PATCH-ASSIGNMENT wtag bmtag)
       (issue-gather! w bmtag #:macro-econ? #t))]
    [(and (not (null? idle-workers)) (null? owned-base-minerals))
     (for ([w (in-list idle-workers)]
           #:when (worker-build-order-stuck? w cur-loop))
       (set-add! commanded-this-frame (sc2-unit-tag w))
       (set! cmds
             (cons (sc2-raw-unit-command 3665 #f 0 (list (sc2-unit-tag w)) #f)
                   cmds)))])

  ;; 1b. Opening Anti-Bounce Close-Patch Lock (`cur-loop <= 336`):
  ;;     Prevent SC2 auto-bounce from kicking Frame-0 workers off their assigned close patch.
  (when (and (> cur-loop 4) (<= cur-loop 336) (not (null? owned-base-minerals)))
    (for ([w (in-list workers)]
          #:when (let ([wtag (sc2-unit-tag w)])
                   (and (not (set-member? commanded-this-frame wtag))
                        (not (worker-returning-cargo? w))
                        (>= cur-loop (hash-ref SC2-WORKER-ANTIBOUNCE-COOLDOWN wtag 0)))))
      (define wtag (sc2-unit-tag w))
      (define assigned-ptag (hash-ref SC2-WORKER-PATCH-ASSIGNMENT wtag #f))
      (when (and assigned-ptag (hash-has-key? owned-min-by-tag assigned-ptag))
        (define active-tgt
          (for/first ([o (in-list (sc2-unit-orders w))]
                      #:when (memv (sc2-unit-order-ability-id o) '(166 295 298 1183 3666)))
            (sc2-unit-order-target-unit-tag o)))
        (when (and active-tgt
                   (> active-tgt 0)
                   (not (= active-tgt assigned-ptag))
                   (hash-has-key? owned-min-by-tag active-tgt)
                   (or (< (hash-ref min-th-dist assigned-ptag 999.0)
                          (- (hash-ref min-th-dist active-tgt 0.0) 0.25))
                       (> (hash-ref patch-worker-counts active-tgt 0) 2)))
          (hash-set! SC2-WORKER-ANTIBOUNCE-COOLDOWN wtag (+ cur-loop 12))
          (set-add! commanded-this-frame wtag)
          (set! cmds
                (cons (mark-urgent-survival-cmd!
                       (sc2-raw-unit-command 3666 #f assigned-ptag (list wtag) #f))
                      cmds))))))

  ;; 2. Assign 1 worker per step to under-saturated gas building, unified with 350G/600G float caps
  ;;    and graduated mineral-worker floor (0 gas -> >= 6 min workers, 1 gas -> >= 8, >= 2 gas -> >= 10).
  ;;    During an early worker rush (`>= 5` enemy workers within 22 tiles of TownHall, `food-army < 4`),
  ;;    evacuate gas geysers to minerals so workers never vanish inside Assimilators/Refineries/Extractors!
  (define worker-rush-evacuate-gas?
    (and (< cur-loop 3600)
         (< (sc2-player-common-food-army pc) 4)
         (not (null? ready-townhalls))
         (>= (count (lambda (u)
                      (and (= (sc2-unit-alliance u) 4)
                           (sc2-unit-is-worker? u)
                           (let ([up (sc2-unit-pos u)])
                             (ormap (lambda (th)
                                      (define tp (sc2-unit-pos th))
                                      (<= (pt-dist (sc2-point3d-x up) (sc2-point3d-y up)
                                                   (sc2-point3d-x tp) (sc2-point3d-y tp))
                                          22.0))
                                    ready-townhalls))))
                    units)
             5)))
  (when (and worker-rush-evacuate-gas? (not (null? owned-base-minerals)))
    (for ([w (in-list workers)]
          #:when (and (not (set-member? commanded-this-frame (sc2-unit-tag w)))
                      (not (worker-carrying-cargo? w))
                      (ormap (lambda (o)
                               (set-member? all-gas-tags (sc2-unit-order-target-unit-tag o)))
                             (sc2-unit-orders w))))
      (define wp (sc2-unit-pos w))
      (define best-min
        (argmin (lambda (m)
                  (define mp (sc2-unit-pos m))
                  (pt-dist (sc2-point3d-x wp) (sc2-point3d-y wp)
                           (sc2-point3d-x mp) (sc2-point3d-y mp)))
                owned-base-minerals))
      (issue-gather! w (sc2-unit-tag best-min) #:macro-econ? #t)))

  (define self-is-zerg?
    (ormap (lambda (u) (memv (sc2-unit-unit-type u) '(86 100 101 104 88))) self-units))
  ;; L22-P0-1: Tighten midgame gas-to-mineral rebalance (`GasRichMinStarved` 2 -> 0, GasZeroFreeze=0):
  ;;   Pull ON:     (>= 180G & < 160M) OR (>= 350G & < 250M) OR (> 600G & < 450M)
  ;;   Pull OFF:    (>= 450M) OR (<= 600G & (< 130G OR >= 280M))
  ;;   Zero-Floor:  >= 260G & < 120M (or >= 300G latched, or worker-rush/crisis); strictly preserves
  ;;                >= 1 gas harvester below 260G (and < 300G when >= 120M) with P1 resaturation!
  (cond
    [(or (and (>= cur-gas 180) (< cur-min 160))
         (and (>= cur-gas SC2-GAS-FLOAT-REBALANCE-THRESH) (< cur-min 250))
         (and (> cur-gas SC2-GAS-FLOAT-PULL-THRESHOLD) (< cur-min 450)))
     (set-box! SC2-GAS-PULL-HYSTERESIS-LATCH #t)]
    [(or (>= cur-min 450)
         (and (<= cur-gas SC2-GAS-FLOAT-PULL-THRESHOLD)
              (or (< cur-gas 130)
                  (>= cur-min 280))))
     (set-box! SC2-GAS-PULL-HYSTERESIS-LATCH #f)])
  ;; Zerg Post-Ling-Speed Mineral Surge: below 28 Drones on 2+ bases (< 3:45), once >= 108G is banked
  ;; while minerals < 250M, keep 1 Drone on gas and pull 2 back to minerals; auto-resaturate to 3/3
  ;; once workers >= 28, cur-gas < 75, or cur-min >= 325!
  (define zerg-post-speed-surge-active?
    (and self-is-zerg?
         (< cur-loop 5040)
         (>= (length online-townhalls) 2)
         (< (length workers) 28)
         (< cur-min 250)
         (>= cur-gas 108)))
  ;; L20-P0-1 (`#29` crushed worker economy `<= 12w`): when worker count is crushed (`<= 12`)
  ;; with `>= 150G` banked and `< 120M`, evacuate gas all the way to `0` so every surviving
  ;; worker rebuilds minerals/economy instead of stranding 20% of workers on unneeded gas!
  (define worker-crisis-gas-evac?
    (and (<= (length workers) 12)
         (>= cur-gas 150)
         (< cur-min 120)))
  (define gas-over-banked?
    (or worker-rush-evacuate-gas?
        worker-crisis-gas-evac?
        (unbox SC2-GAS-PULL-HYSTERESIS-LATCH)))
  (define gas-pull-to-zero-now?
    (or worker-rush-evacuate-gas?
        worker-crisis-gas-evac?
        (and gas-over-banked?
             (or (>= cur-gas 300)
                 (and (>= cur-gas 260) (< cur-min 120))))))
  (define gas-resaturate-blocked?
    (or gas-pull-to-zero-now?
        (and gas-over-banked? (>= eff-active-gas-workers 1))
        (and zerg-post-speed-surge-active? (>= eff-active-gas-workers 1))))
  ;; L19-P0-1: Protect mineral saturation on 1-2 bases using `eff-active-gas-workers`
  ;; (counting workers currently inside refineries!): 2nd geyser (slots 3..5) requires >= 18
  ;; mineral workers when < 300M, and 3rd+ geyser (slots 6+) requires >= 28 when < 400M.
  (define min-mineral-workers-for-next-gas
    (cond
      [(= eff-active-gas-workers 0) 6]
      [(= eff-active-gas-workers 1) 8]
      [(= eff-active-gas-workers 2) 10]
      [(< eff-active-gas-workers 6) (if (>= cur-min 300) 10 18)]
      [else                         (if (>= cur-min 400) 14 28)]))
  (when (and (not (null? under-gas))
             (or (null? owned-base-minerals)
                 (>= (- (length workers) active-gas-worker-count)
                     min-mineral-workers-for-next-gas))
             (not gas-resaturate-blocked?))
    (define gb (first under-gas))
    (define gp (sc2-unit-pos gb))
    (define zero-gas-workers-now? (= eff-active-gas-workers 0))
    (define (eligible-for-gas? w)
      (and (not (set-member? commanded-this-frame (sc2-unit-tag w)))
           (not (worker-carrying-cargo? w))
           (not (worker-returning-cargo? w))
           (not (ormap (lambda (o)
                         (set-member? all-gas-tags (sc2-unit-order-target-unit-tag o)))
                       (sc2-unit-orders w)))
           (or zero-gas-workers-now?
               (null? (sc2-unit-orders w))
               (for/and ([other-gb (in-list ready-gas-bldgs)])
                 (define ogp (sc2-unit-pos other-gb))
                 (define wp (sc2-unit-pos w))
                 (> (pt-dist (sc2-point3d-x ogp) (sc2-point3d-y ogp)
                             (sc2-point3d-x wp) (sc2-point3d-y wp))
                    SC2-GAS-HARVESTER-EXCLUSION-RADIUS)))))
    (define eligible-idle (filter eligible-for-gas? idle-workers))
    (define eligible-all (filter eligible-for-gas? workers))
    (define fallback-carrying-min
      (if (and (null? eligible-idle)
               (null? eligible-all)
               zero-gas-workers-now?
               (< cur-gas 180))
          (filter (lambda (w)
                    (and (not (set-member? commanded-this-frame (sc2-unit-tag w)))
                         (not (worker-carrying-gas? w))
                         (not (ormap (lambda (o)
                                       (set-member? all-gas-tags (sc2-unit-order-target-unit-tag o)))
                                     (sc2-unit-orders w)))))
                  workers)
          '()))
    (define-values (candidate-workers allow-carry?)
      (cond
        [(not (null? eligible-idle)) (values eligible-idle #f)]
        [(not (null? eligible-all)) (values eligible-all #f)]
        [else (values fallback-carrying-min #t)]))
    (when (not (null? candidate-workers))
      (define best-w
        (argmin (lambda (w)
                  (define wp (sc2-unit-pos w))
                  (pt-dist (sc2-point3d-x gp) (sc2-point3d-y gp)
                           (sc2-point3d-x wp) (sc2-point3d-y wp)))
                candidate-workers))
      (issue-gather! best-w (sc2-unit-tag gb)
                     #:macro-econ? #t
                     #:allow-carrying-mineral? allow-carry?)))

  ;; 3. L23-P0-1: Transfer up to 2 far-patch non-carrying workers/step from over-saturated TownHall OR
  ;;    donor base (`>= 12w` during `0:00-4:30` natural ramp, keeping `>= 10` at main; `>= 14w` later)
  ;;    to the safest MOST-UNDER-SATURATED expansion's Near Patches (`bp >= 0.85` included!) at Tier P1
  ;;    when ramping early/fresh expansions, enforcing cooldown + in-flight deduplication!
  (when (and (not (null? under-townhalls))
             (not (null? owned-base-minerals)))
    (define dst-th
      (argmin (lambda (th)
                (+ (* 1000.0 (th-safety-score th))
                   (exact->inexact (th-effective-assigned th))))
              under-townhalls))
    (define dp (sc2-unit-pos dst-th))
    (define dst-ih (th-effective-ideal dst-th))
    (define dst-deficit (max 0 (- dst-ih (th-effective-assigned dst-th))))
    (define dst-mins (minerals-near-townhall dst-th))
    (define dst-near-mins (hash-ref th-near-ht (sc2-unit-tag dst-th) '()))
    (define dst-min-tags (list->seteqv (map sc2-unit-tag dst-mins)))
    (define in-flight-to-dst
      (count (lambda (w)
               (define wp (sc2-unit-pos w))
               (and (> (pt-dist (sc2-point3d-x dp) (sc2-point3d-y dp)
                                (sc2-point3d-x wp) (sc2-point3d-y wp))
                       8.0)
                    (ormap (lambda (o)
                             (set-member? dst-min-tags (sc2-unit-order-target-unit-tag o)))
                           (sc2-unit-orders w))))
             workers))
    (define dst-near-slots-needed
      (for/sum ([m (in-list dst-near-mins)])
        (max 0 (- 2 (hash-ref patch-worker-counts (sc2-unit-tag m) 0)))))
    (define early-natural-split?
      (and (<= cur-loop 6048)
           (>= (length dst-mins) 4)
           (< (th-effective-assigned dst-th) 8)))
    (define donor-min-workers (if early-natural-split? 12 14))
    (define donor-keep-workers (if early-natural-split? 10 13))
    (define donor-candidates
      (filter (lambda (th)
                (and (not (= (sc2-unit-tag th) (sc2-unit-tag dst-th)))
                     (>= (th-effective-assigned th) donor-min-workers)))
              online-ready-townhalls))
    (define-values (src-th src-surplus transfer-limit transfer-eligible?)
      (cond
        [(not (null? over-townhalls))
         (define sth (first over-townhalls))
         (define sth-surp (max 0 (- (sc2-unit-assigned-harvesters sth) (th-effective-ideal sth))))
         (define rem-surp (max 0 (- sth-surp in-flight-to-dst)))
         (define rem-def (max 0 (- dst-deficit in-flight-to-dst)))
         (define lim (min (if (or early-natural-split? (>= rem-surp 2)) 2 1) rem-surp rem-def))
         (values sth
                 sth-surp
                 lim
                 (and (not (= (sc2-unit-tag sth) (sc2-unit-tag dst-th)))
                      (>= (+ sth-surp dst-deficit) 2)
                      (> lim 0)))]
        [(and (pair? donor-candidates) (> dst-near-slots-needed 0))
         (define sth (argmax th-effective-assigned donor-candidates))
         (define sth-surp (max 0 (- (th-effective-assigned sth) donor-keep-workers)))
         (define rem-near (max 0 (- dst-near-slots-needed in-flight-to-dst)))
         (define rem-surp (max 0 (- sth-surp in-flight-to-dst)))
         (define rem-def (max 0 (- dst-deficit in-flight-to-dst)))
         (define lim (min (if (or early-natural-split? (>= rem-surp 2)) 2 1) rem-near rem-surp rem-def))
         (values sth sth-surp lim (> lim 0))]
        [else (values #f 0 0 #f)]))
    (when (and src-th transfer-eligible? (not (null? dst-mins)))
      (define sp (sc2-unit-pos src-th))
      (define transferable
        (filter (lambda (w)
                  (define wp (sc2-unit-pos w))
                  (define wtag (sc2-unit-tag w))
                  (and (not (set-member? commanded-this-frame wtag))
                       (>= cur-loop (hash-ref SC2-WORKER-TRANSFER-COOLDOWN-UNTIL wtag 0))
                       (not (worker-carrying-cargo? w))
                       (not (worker-returning-cargo? w))
                       (not (ormap (lambda (o)
                                     (or (set-member? all-gas-tags (sc2-unit-order-target-unit-tag o))
                                         (set-member? dst-min-tags (sc2-unit-order-target-unit-tag o))))
                                   (sc2-unit-orders w)))
                       (<= (pt-dist (sc2-point3d-x sp) (sc2-point3d-y sp)
                                    (sc2-point3d-x wp) (sc2-point3d-y wp))
                           SC2-BASE-RESOURCE-RADIUS)
                       (for/and ([gb (in-list ready-gas-bldgs)])
                         (define gp (sc2-unit-pos gb))
                         (> (pt-dist (sc2-point3d-x gp) (sc2-point3d-y gp)
                                     (sc2-point3d-x wp) (sc2-point3d-y wp))
                            SC2-GAS-HARVESTER-EXCLUSION-RADIUS))))
                workers))
      (when (not (null? transferable))
        (define (xfer-worker-score w)
          (define wp (sc2-unit-pos w))
          (define wtag (sc2-unit-tag w))
          (define ord-tgt
            (for/first ([o (in-list (sc2-unit-orders w))]
                        #:when (memv (sc2-unit-order-ability-id o) '(166 295 298 1183 3666)))
              (sc2-unit-order-target-unit-tag o)))
          (define eff-tgt (or ord-tgt (hash-ref SC2-WORKER-PATCH-ASSIGNMENT wtag #f)))
          (define patch-far?
            (if (and eff-tgt (hash-has-key? min-is-far-ht eff-tgt))
                (hash-ref min-is-far-ht eff-tgt #f)
                (>= (pt-dist (sc2-point3d-x sp) (sc2-point3d-y sp)
                             (sc2-point3d-x wp) (sc2-point3d-y wp))
                    6.75)))
          (+ (if patch-far? -25.0 25.0)
             (if (null? (sc2-unit-orders w)) -5.0 0.0)
             (* 0.1 (pt-dist (sc2-point3d-x dp) (sc2-point3d-y dp)
                             (sc2-point3d-x wp) (sc2-point3d-y wp)))))
        (define ranked-xfers (sort transferable < #:key xfer-worker-score))
        (define xfer-macro-econ?
          (or early-natural-split?
              (< cur-loop 6720)
              (< (th-effective-assigned dst-th) 8)))
        (for ([chosen-w (in-list (take ranked-xfers (min transfer-limit (length ranked-xfers))))])
          (define best-dst-min (pick-best-slot-patch chosen-w dst-mins))
          (define bmtag (sc2-unit-tag best-dst-min))
          (hash-set! patch-worker-counts bmtag (add1 (hash-ref patch-worker-counts bmtag 0)))
          (hash-set! SC2-WORKER-PATCH-ASSIGNMENT (sc2-unit-tag chosen-w) bmtag)
          (hash-set! SC2-WORKER-TRANSFER-COOLDOWN-UNTIL (sc2-unit-tag chosen-w) (+ cur-loop 48))
          (issue-gather! chosen-w bmtag #:macro-econ? xfer-macro-econ?)))))

  ;; 4. Pull up to 2 gas workers/step (up to 3/step when >= 4 active gas workers!) back to owned
  ;;    minerals when floating gas while mineral-starved, keeping >= 1 harvester strictly below 260G
  ;;    (and < 300G when >= 120M) so `GasZeroFreeze = 0` holds, and pulling to 0 at >= 260G & < 120M
  ;;    (or >= 300G latched / worker-crisis); pulls non-carrying gas workers first, and also pulls
  ;;    carrying gas workers (`buff 273/274/275`) whenever `>= 200G & < 120M` or worker-crisis!
  (define gas-pull-target-floor
    (cond
      [gas-pull-to-zero-now? 0]
      [(or gas-over-banked? zerg-post-speed-surge-active?) 1]
      [else eff-active-gas-workers]))
  (define max-gas-pulls-this-step
    (if (or gas-over-banked? zerg-post-speed-surge-active?)
        (let ([per-step-cap (if (>= eff-active-gas-workers 4) 3 2)])
          (min per-step-cap (max 0 (- eff-active-gas-workers gas-pull-target-floor))))
        0))
  (when (and (> max-gas-pulls-this-step 0)
             (not (null? owned-base-minerals))
             (not (null? ready-gas-bldgs)))
    (define cand-mins
      (if (not (null? under-townhalls))
          (minerals-near-townhall (first under-townhalls))
          owned-base-minerals))
    (when (not (null? cand-mins))
      (define (targeting-gas-bldg? w)
        (ormap (lambda (o)
                 (set-member? all-gas-tags (sc2-unit-order-target-unit-tag o)))
               (sc2-unit-orders w)))
      (define allow-carrying-gas-pull?
        (or (and (>= cur-gas 200) (< cur-min 120))
            worker-crisis-gas-evac?))
      (define non-carrying-gas-workers
        (filter (lambda (w)
                  (and (not (set-member? commanded-this-frame (sc2-unit-tag w)))
                       (not (worker-carrying-cargo? w))
                       (not (worker-returning-cargo? w))
                       (targeting-gas-bldg? w)))
                workers))
      (define carrying-gas-workers
        (if allow-carrying-gas-pull?
            (filter (lambda (w)
                      (and (not (set-member? commanded-this-frame (sc2-unit-tag w)))
                           (or (worker-carrying-gas? w)
                               (and (or (worker-carrying-cargo? w) (worker-returning-cargo? w))
                                    (targeting-gas-bldg? w)))))
                    workers)
            '()))
      (define pull-candidates
        (append non-carrying-gas-workers carrying-gas-workers))
      (for ([gw (in-list (take pull-candidates (min max-gas-pulls-this-step (length pull-candidates))))])
        (define best-min (pick-best-slot-patch gw cand-mins))
        (define bmtag (sc2-unit-tag best-min))
        (hash-set! patch-worker-counts bmtag (add1 (hash-ref patch-worker-counts bmtag 0)))
        (hash-set! SC2-WORKER-PATCH-ASSIGNMENT (sc2-unit-tag gw) bmtag)
        (issue-gather! gw bmtag
                       #:macro-econ? #t
                       #:allow-carrying-gas? allow-carrying-gas-pull?))))

  ;; 5. Idle MULE Re-Tasking: re-task idle MULEs (268) ONLY onto live mineral patches within 12 tiles
  ;;    of a completed grounded friendly TownHall and within 14 tiles of the MULE (never cross-map!).
  (when (not (null? owned-base-minerals))
    (for ([u (in-list self-units)]
          #:when (and (= (sc2-unit-unit-type u) 268)
                      (null? (sc2-unit-orders u))))
      (define up (sc2-unit-pos u))
      (define ux (sc2-point3d-x up))
      (define uy (sc2-point3d-y up))
      (define near-owned-mins
        (filter (lambda (m)
                  (define mp (sc2-unit-pos m))
                  (define mx (sc2-point3d-x mp))
                  (define my (sc2-point3d-y mp))
                  (and (<= (pt-dist ux uy mx my) 14.0)
                       (or (null? ready-townhalls)
                           (ormap (lambda (th)
                                    (define tp (sc2-unit-pos th))
                                    (<= (pt-dist mx my (sc2-point3d-x tp) (sc2-point3d-y tp)) 12.0))
                                  ready-townhalls))))
                owned-base-minerals))
      (when (not (null? near-owned-mins))
        (define best-m
          (argmin (lambda (m)
                    (define mp (sc2-unit-pos m))
                    (pt-dist ux uy (sc2-point3d-x mp) (sc2-point3d-y mp)))
                  near-owned-mins))
        (set! cmds
              (cons (mark-macro-econ-cmd!
                     (sc2-raw-unit-command 3666 #f (sc2-unit-tag best-m) (list (sc2-unit-tag u)) #f))
                    cmds)))))

  ;; 6. L23-P0-1: Unstarvable Tier-P1 Macro-Energy Safety Net (`Orbital Command MULE` 171 &
  ;;    `0:00-5:00` Probe-training `Nexus ChronoBoost` 3755). Deduplicated with Layer 2 via
  ;;    `SC2-MACRO-ABILITY-LAST-LOOP` (`16f` cooldown) so zero duplicate commands or rejects occur!
  ;; 6a. Orbital Command MULE (`171`): cast at >= 50 energy when no cloaked/burrowed threat exists
  ;;     (or >= 100 energy to preserve 50-energy Scan reserve under cloak threat).
  (when (not (null? owned-base-minerals))
    (define enemy-cloak-threat?
      (ormap (lambda (e)
               (or (memv (sc2-unit-cloak e) '(1 2))
                   (sc2-unit-is-burrowed e)
                   (memv (sc2-unit-unit-type e) '(50 55 69 76 498 502 503 504))))
             enemy-units))
    (define mule-energy-floor (if enemy-cloak-threat? 100.0 50.0))
    (for ([oc (in-list ready-townhalls)]
          #:when (and (= (sc2-unit-unit-type oc) 132)
                      (>= (sc2-unit-energy oc) mule-energy-floor)
                      (>= (- cur-loop (hash-ref SC2-MACRO-ABILITY-LAST-LOOP (cons 'mule (sc2-unit-tag oc)) -1000)) 16)))
      (define safe-min-tag (pick-safe-mule-mineral-patch oc self-units mineral-fields enemy-units))
      (when (and (exact-integer? safe-min-tag) (> safe-min-tag 0))
        (hash-set! SC2-MACRO-ABILITY-LAST-LOOP (cons 'mule (sc2-unit-tag oc)) cur-loop)
        (set! cmds
              (cons (mark-macro-econ-cmd!
                     (sc2-raw-unit-command 171 #f safe-min-tag (list (sc2-unit-tag oc)) #f))
                    cmds)))))
  ;; 6b. Early Nexus ChronoBoost (`3755`): `0:00-5:00` (`< 6720f`) & `< 50` Probes — keep active
  ;;     Probe-training Nexuses boosted at Tier P1 (`+4-5` Probes by `4:00`)!
  (when (and (< cur-loop 6720)
             (< (length workers) 50))
    (define ready-nexuses
      (filter (lambda (th) (= (sc2-unit-unit-type th) 59)) ready-townhalls))
    (define probe-training-unboosted-nexuses
      (filter (lambda (nx)
                (define ntag (sc2-unit-tag nx))
                (and (ormap (lambda (o) (= (sc2-unit-order-ability-id o) 1006)) (sc2-unit-orders nx))
                     (not (memv 281 (sc2-unit-buff-ids nx)))
                     (>= (- cur-loop (hash-ref SC2-MACRO-ABILITY-LAST-LOOP (cons 'chrono-tgt ntag) -1000)) 16)))
              ready-nexuses))
    (when (pair? probe-training-unboosted-nexuses)
      (define claimed-chrono-tgts (mutable-seteqv))
      (for ([caster-nx (in-list ready-nexuses)]
            #:when (and (>= (sc2-unit-energy caster-nx) 50.0)
                        (>= (- cur-loop (hash-ref SC2-MACRO-ABILITY-LAST-LOOP (cons 'chrono (sc2-unit-tag caster-nx)) -1000)) 16)))
        (define ctag (sc2-unit-tag caster-nx))
        (define tgt-nx
          (or (findf (lambda (nx)
                       (and (= (sc2-unit-tag nx) ctag)
                            (not (set-member? claimed-chrono-tgts ctag))))
                     probe-training-unboosted-nexuses)
              (findf (lambda (nx)
                       (not (set-member? claimed-chrono-tgts (sc2-unit-tag nx))))
                     probe-training-unboosted-nexuses)))
        (when tgt-nx
          (define ttag (sc2-unit-tag tgt-nx))
          (set-add! claimed-chrono-tgts ttag)
          (hash-set! SC2-MACRO-ABILITY-LAST-LOOP (cons 'chrono ctag) cur-loop)
          (hash-set! SC2-MACRO-ABILITY-LAST-LOOP (cons 'chrono-tgt ttag) cur-loop)
          (set! cmds
                (cons (mark-macro-econ-cmd!
                       (sc2-raw-unit-command 3755 #f ttag (list ctag) #f))
                      cmds))))))

  (reverse cmds))

(define (unit-symbol->warp-in-ability-id unit-sym)
  (case (normalize-sc2-name->symbol unit-sym)
    [(zealot)       1413]
    [(stalker)      1414]
    [(high-templar) 1416]
    [(dark-templar) 1417]
    [(sentry)       1418]
    [(adept)        1419]
    [else           #f]))

(define SC2-LAST-KNOWN-ENEMY-POS (make-hasheqv))
(define SC2-ENEMY-POS-LAST-LOOP (box 0))
(define SC2-DEPOT-TOGGLE-COOLDOWN (make-hasheqv))
(define SC2-MODE-TOGGLE-COOLDOWN (make-hasheqv))
(define SC2-MINE-CLEAR-SINCE-LOOP (make-hasheqv))
(define SC2-MINE-LAST-TYPE (make-hasheqv))
(define SC2-CREEP-TUMOR-COOLDOWN (make-hasheqv))
(define SC2-WIRE-NONSTACK-CMD-COOLDOWN (make-hash))
(define SC2-WIRE-LAST-LOOP-BOX (box -1))
(define SC2-CONTROL-GROUPED-TAGS (box (hasheqv)))
(define SC2-GOV-LAST-CAM-X (box #f))
(define SC2-GOV-LAST-CAM-Y (box #f))
(define SC2-TRANS-LAST-CAM-X (box #f))
(define SC2-TRANS-LAST-CAM-Y (box #f))
(define SC2-TRANS-LAST-CAM-LOOP (box -1000))
(define SC2-LAST-BOT-ACTION-REJECTS (box '()))
(define SC2-TOTAL-BOT-ACTION-REJECT-COUNT (box 0))

;; Verify whether `(px, py)` lies inside any completed power field (`power-sources` when populated,
;; or completed friendly Pylon / WarpPrism-Phasing units as fallback).
(define (point-in-completed-power-field? px py power-sources [completed-pylons '()])
  (cond
    [(pair? power-sources)
     (for/or ([ps (in-list power-sources)])
       (define p (sc2-power-source-pos ps))
       (define rad (sc2-power-source-radius ps))
       (<= (pt-dist px py (sc2-point3d-x p) (sc2-point3d-y p))
           (if (> rad 0.0) rad 6.5)))]
    [(pair? completed-pylons)
     (for/or ([pylon-u (in-list completed-pylons)])
       (define p (sc2-unit-pos pylon-u))
       (define rad (if (= (sc2-unit-unit-type pylon-u) 136) 3.75 6.5))
       (<= (pt-dist px py (sc2-point3d-x p) (sc2-point3d-y p)) rad))]
    [else #f]))

(define (friendly-unit-on-depot-footprint? dx dy self-units)
  (for/or ([u (in-list self-units)])
    (and (not (sc2-unit-is-structure? u))
         (not (sc2-unit-is-flying u))
         (let ([up (sc2-unit-pos u)])
           (and (<= (abs (- (sc2-point3d-x up) dx)) 1.40)
                (<= (abs (- (sc2-point3d-y up) dy)) 1.40))))))

(define (friendly-unit-requesting-depot-transit? dx dy self-units
                                                 [builder-worker-tags (seteqv)]
                                                 [commanded-combat-tags (seteqv)]
                                                 #:unit-pos-by-tag [pre-pos-ht #f])
  (define unit-pos-by-tag
    (or pre-pos-ht
        (for/hasheqv ([u (in-list self-units)])
          (define p (sc2-unit-pos u))
          (values (sc2-unit-tag u) (cons (sc2-point3d-x p) (sc2-point3d-y p))))))
  (define (unit-active-non-hold-worker-transit? u ux uy)
    (define ords (sc2-unit-orders u))
    (and (pair? ords)
         (let* ([o (car ords)]
                [ab (sc2-unit-order-ability-id o)]
                [tp (sc2-unit-order-target-pos o)]
                [tt (sc2-unit-order-target-unit-tag o)]
                [is-transit-ab?
                 (or (memv ab '(16 23 295 296 298 299 1183 1184 3666 3667))
                     (eq? (sc2-order-protection-class (sc2-canonical-order-ability ab))
                          'build-structure)
                     (worker-has-build-order? u))])
           (and (not (= ab 18))
                is-transit-ab?
                (let-values ([(tx ty)
                              (cond
                                [(any-point? tp) (values (any-point-x tp) (any-point-y tp))]
                                [(and (> tt 0) (hash-has-key? unit-pos-by-tag tt))
                                 (let ([p (hash-ref unit-pos-by-tag tt)])
                                   (values (car p) (cdr p)))]
                                [else (values #f #f)])])
                  (or (not (and tx ty))
                      (> (pt-dist ux uy tx ty) 2.0)
                      (< (+ (* (- tx dx) (- ux dx))
                            (* (- ty dy) (- uy dy)))
                         0.0)))))))
  (for/or ([u (in-list self-units)])
    (and (not (sc2-unit-is-structure? u))
         (not (sc2-unit-is-flying u))
         (let* ([up (sc2-unit-pos u)]
                [ux (sc2-point3d-x up)]
                [uy (sc2-point3d-y up)]
                [utag (sc2-unit-tag u)]
                [ords (sc2-unit-orders u)])
           (and (<= (pt-dist ux uy dx dy) 4.2)
                (or (and (<= (abs (- ux dx)) 1.45)
                         (<= (abs (- uy dy)) 1.45))
                    (and (sc2-unit-is-worker? u)
                         (or (set-member? builder-worker-tags utag)
                             (worker-has-build-order? u)
                             (unit-active-non-hold-worker-transit? u ux uy)))
                    (and (or (set-member? commanded-combat-tags utag)
                             (pair? ords))
                         (or (null? ords)
                             (not (= (sc2-unit-order-ability-id (car ords)) 18))))))))))

(define (get-last-bot-action-rejects)
  (unbox SC2-LAST-BOT-ACTION-REJECTS))

(define (get-total-bot-action-reject-count)
  (unbox SC2-TOTAL-BOT-ACTION-REJECT-COUNT))

(define (reset-typed-command-gate-stats!)
  (set-box! SC2-LAST-BOT-ACTION-REJECTS '())
  (set-box! SC2-TOTAL-BOT-ACTION-REJECT-COUNT 0)
  (set-box! SC2-TOTAL-WIRE-ACTION-DROP-COUNT 0))

(define (translate-bot-actions->sc2-raw-commands raw-actions obs
                                                 #:used-creep-tumors [used-tumors #f]
                                                 #:ws-conn [ws-conn #f]
                                                 #:enemy-base [enemy-base #f]
                                                 #:commanded-workers [commanded-workers #f]
                                                 #:used-worker-tags [external-used-worker-tags #f]
                                                 #:role-leases [role-leases #f]
                                                 #:reserved-aabbs [reserved-aabbs '()]
                                                 #:game-info [game-info #f]
                                                 #:suppress-attack? [suppress-attack-kw #f]
                                                 #:tactical-posture [tactical-posture-kw #f]
                                                 #:endgame-cleanup? [endgame-cleanup-kw #f])
  (define-values (actions step-action-rejects)
    (filter-valid-bot-actions (if (list? raw-actions) raw-actions '())))
  (set-box! SC2-LAST-BOT-ACTION-REJECTS step-action-rejects)
  (when (pair? step-action-rejects)
    (set-box! SC2-TOTAL-BOT-ACTION-REJECT-COUNT
              (+ (unbox SC2-TOTAL-BOT-ACTION-REJECT-COUNT) (length step-action-rejects))))
  (define (finite-world-coord? v)
    (and (real? v) (not (nan? v)) (not (infinite? v)) (>= v 0.0) (<= v 256.0)))
  (define (finite-num? v)
    (and (real? v) (not (nan? v)) (not (infinite? v))))
  (define (valid-u64-tag? t)
    (and (exact-integer? t) (> t 0) (<= t #xFFFFFFFFFFFFFFFF)))
  (define (sanitize-obs-unit u)
    (and (sc2-unit? u)
         (valid-u64-tag? (sc2-unit-tag u))
         (exact-integer? (sc2-unit-alliance u))
         (exact-integer? (sc2-unit-display-type u))
         (exact-nonnegative-integer? (sc2-unit-unit-type u))
         (let ([p (sc2-unit-pos u)])
           (and (sc2-point3d? p)
                (finite-num? (sc2-point3d-x p))
                (finite-num? (sc2-point3d-y p))
                (let ([px (sc2-point3d-x p)]
                      [py (sc2-point3d-y p)]
                      [pz (sc2-point3d-z p)]
                      [rad (sc2-unit-radius u)]
                      [bp (sc2-unit-build-progress u)]
                      [hp (sc2-unit-health u)]
                      [sh (sc2-unit-shield u)]
                      [en (sc2-unit-energy u)]
                      [ords (sc2-unit-orders u)]
                      [bIds (sc2-unit-buff-ids u)])
                  (if (and (>= px 0.0) (<= px 256.0)
                           (>= py 0.0) (<= py 256.0)
                           (finite-num? pz)
                           (finite-num? rad) (>= rad 0.0)
                           (finite-num? bp)
                           (finite-num? hp)
                           (finite-num? sh)
                           (finite-num? en)
                           (list? ords) (andmap sc2-unit-order? ords)
                           (list? bIds))
                      u
                      (struct-copy
                       sc2-unit u
                       [pos (sc2-point3d (max 0.0 (min 256.0 (exact->inexact px)))
                                         (max 0.0 (min 256.0 (exact->inexact py)))
                                         (if (finite-num? pz) (exact->inexact pz) 0.0))]
                       [radius (if (and (finite-num? rad) (>= rad 0.0)) (exact->inexact rad) 0.5)]
                       [build-progress (if (finite-num? bp) (max 0.0 (min 1.0 (exact->inexact bp))) 1.0)]
                       [health (if (finite-num? hp) (max 0.0 (exact->inexact hp)) 1.0)]
                       [shield (if (finite-num? sh) (max 0.0 (exact->inexact sh)) 0.0)]
                       [energy (if (finite-num? en) (max 0.0 (exact->inexact en)) 0.0)]
                       [orders (if (list? ords)
                                   (filter (lambda (o)
                                             (and (sc2-unit-order? o)
                                                  (exact-integer? (sc2-unit-order-ability-id o))
                                                  (exact-integer? (sc2-unit-order-target-unit-tag o))
                                                  (let ([tp (sc2-unit-order-target-pos o)])
                                                    (or (not tp)
                                                        (and (sc2-point2d? tp)
                                                             (finite-world-coord? (sc2-point2d-x tp))
                                                             (finite-world-coord? (sc2-point2d-y tp)))
                                                        (and (sc2-point3d? tp)
                                                             (finite-world-coord? (sc2-point3d-x tp))
                                                             (finite-world-coord? (sc2-point3d-y tp)))))))
                                           ords)
                                   '())]
                       [buff-ids (if (list? bIds) (filter exact-integer? bIds) '())])))))))
  (define cur-loop
    (cond
      [(sc2-observation? obs)
       (let ([gl (sc2-observation-game-loop obs)])
         (if (and (exact-integer? gl) (>= gl 0)) gl 0))]
      [(hash? obs)
       (let ([fr (hash-ref obs 'frame 0)])
         (if (and (exact-integer? fr) (>= fr 0)) fr 0))]
      [else 0]))
  (when (sc2-game-info? game-info)
    (set-box! SC2-ACTIVE-GAME-INFO game-info))
  (define eff-game-info
    (if (sc2-game-info? game-info)
        game-info
        (let ([cached-gi (unbox SC2-ACTIVE-GAME-INFO)])
          (and (sc2-game-info? cached-gi)
               (let ([ms (sc2-game-info-map-size cached-gi)])
                 (or (not (and (pair? ms) (real? (car ms)) (real? (cdr ms))))
                     (not (sc2-observation? obs))
                     (for/and ([u (in-list (sc2-observation-units obs))])
                       (define p (and (sc2-unit? u) (sc2-unit-pos u)))
                       (or (not (sc2-point3d? p))
                           (and (>= (sc2-point3d-x p) 0.0) (<= (sc2-point3d-x p) (car ms))
                                (>= (sc2-point3d-y p) 0.0) (<= (sc2-point3d-y p) (cdr ms)))))))
               cached-gi))))
  (let ([prev-wire-loop (unbox SC2-WIRE-LAST-LOOP-BOX)])
    (when (and (>= prev-wire-loop 0)
               (or (< cur-loop prev-wire-loop)
                   (and (<= cur-loop 8) (> prev-wire-loop 8))))
      (hash-clear! SC2-MODE-TOGGLE-COOLDOWN)
      (hash-clear! SC2-WIRE-NONSTACK-CMD-COOLDOWN)
      (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
      (hash-clear! SC2-PLACEMENT-POS-CACHE)
      (hash-clear! SC2-ADDON-SLOT-BLOCKED-CACHE)
      (hash-clear! SC2-TERRAN-5X3-MISS-CACHE)
      (hash-clear! SC2-TUMOR-PLACEMENT-CACHE)
      (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
      (set-box! SC2-LAST-TUMOR-RPC-LOOP -9999)
      (set-box! SC2-ZERG-TH-MORPH-RESERVE-LOOP #f)
      (set-box! SC2-ENEMY-POS-PURGE-LAST-LOOP -9999)
      (set-box! SC2-PLACEMENT-CACHE-SIG #f)
      (set-box! SC2-ENEMY-MAIN-CLEARED-AT #f)
      (set-box! SC2-EVER-SAW-MINERALS? #f)
      (set-box! SC2-WIRE-HOLD-POSTURE-STATE #f)
      (set-box! SC2-WIRE-OFFENSIVE-PUSH-STATE #f)
      (set-box! SC2-TERRITORY-FIELD-CACHE #f))
    (set-box! SC2-WIRE-LAST-LOOP-BOX cur-loop))
  (when (sc2-observation? obs)
    (when (or (< cur-loop (unbox SC2-ENEMY-POS-LAST-LOOP))
              (and (<= cur-loop 8) (> (unbox SC2-ENEMY-POS-LAST-LOOP) 8)))
      (hash-clear! SC2-LAST-KNOWN-ENEMY-POS)
      (hash-clear! SC2-WARPGATE-COOLDOWN-UNTIL)
      (hash-clear! SC2-DEPOT-TOGGLE-COOLDOWN)
      (hash-clear! SC2-MODE-TOGGLE-COOLDOWN)
      (hash-clear! SC2-MINE-CLEAR-SINCE-LOOP)
      (hash-clear! SC2-MINE-LAST-TYPE)
      (hash-clear! SC2-CREEP-TUMOR-COOLDOWN)
      (hash-clear! SC2-BUILDER-RESERVATION)
      (hash-clear! SC2-WIRE-NONSTACK-CMD-COOLDOWN)
      (hash-clear! SC2-STEP-PLACEMENT-FAIL-CACHE)
      (hash-clear! SC2-PLACEMENT-NEG-COOLDOWN)
      (hash-clear! SC2-PLACEMENT-POS-CACHE)
      (hash-clear! SC2-ADDON-SLOT-BLOCKED-CACHE)
      (hash-clear! SC2-TERRAN-5X3-MISS-CACHE)
      (hash-clear! SC2-TUMOR-PLACEMENT-CACHE)
      (hash-clear! SC2-MACRO-ABILITY-LAST-LOOP)
      (set-box! SC2-LAST-TUMOR-RPC-LOOP -9999)
      (set-box! SC2-ZERG-TH-MORPH-RESERVE-LOOP #f)
      (set-box! SC2-ENEMY-POS-PURGE-LAST-LOOP -9999)
      (set-box! SC2-PLACEMENT-CACHE-SIG #f)
      (hash-clear! SC2-BASE-SAFETY-CHECKER-CACHE)
      (set-box! SC2-CONTROL-GROUPED-TAGS (hasheqv))
      (set-box! SC2-GOV-LAST-CAM-X #f)
      (set-box! SC2-GOV-LAST-CAM-Y #f)
      (set-box! SC2-TRANS-LAST-CAM-X #f)
      (set-box! SC2-TRANS-LAST-CAM-Y #f)
      (set-box! SC2-TRANS-LAST-CAM-LOOP -1000)
      (set-box! SC2-CLEARED-ENEMY-BASES '())
      (set-box! SC2-ENEMY-MAIN-CLEARED-AT #f)
      (set-box! SC2-EVER-SAW-MINERALS? #f)
      (set-box! SC2-WIRE-HOLD-POSTURE-STATE #f)
      (set-box! SC2-WIRE-OFFENSIVE-PUSH-STATE #f)
      (set-box! SC2-CACHED-MAP-BASE-CLUSTERS '())
      (set-box! SC2-TERRITORY-FIELD-CACHE #f)
      (set-box! SC2-CORNER-SCAN-LAST-LOOP -9999))
    (set-box! SC2-ENEMY-POS-LAST-LOOP cur-loop)
    (when (< cur-loop (unbox SC2-WARPGATE-LAST-LOOP))
      (hash-clear! SC2-WARPGATE-COOLDOWN-UNTIL))
    (set-box! SC2-WARPGATE-LAST-LOOP cur-loop)
    (define raw-dead (sc2-observation-dead-unit-tags obs))
    (when (list? raw-dead)
      (for ([dtag (in-list raw-dead)]
            #:when (valid-u64-tag? dtag))
        (hash-remove! SC2-LAST-KNOWN-ENEMY-POS dtag)
        (hash-remove! SC2-WARPGATE-COOLDOWN-UNTIL dtag))))
  (define units
    (if (and (sc2-observation? obs) (list? (sc2-observation-units obs)))
        (filter-map sanitize-obs-unit (sc2-observation-units obs))
        '()))
  (reconcile-warpgate-cooldowns! obs units cur-loop)
  (define step-pl-grid
    (and (sc2-game-info? eff-game-info)
         (sc2-game-info-placement-grid eff-game-info)))
  (define step-path-grid
    (and (sc2-game-info? eff-game-info)
         (sc2-game-info-pathing-grid eff-game-info)))
  (define step-creep-grid
    (let ([cg (and (sc2-observation? obs) (hash-ref SC2-OBS-CREEP-GRIDS obs #f))])
      (when cg
        (define ref-g (or step-pl-grid step-path-grid))
        (when (sc2-image-grid? ref-g)
          (set-sc2-image-grid-y-flip?! cg (sc2-image-grid-y-flip? ref-g))
          (set-sc2-image-grid-lsb-first?! cg (sc2-image-grid-lsb-first? ref-g))))
      cg))
  (define power-sources
    (if (and (sc2-observation? obs) (list? (sc2-observation-power-sources obs)))
        (filter (lambda (ps)
                  (and (sc2-power-source? ps)
                       (finite-num? (sc2-power-source-radius ps))
                       (>= (sc2-power-source-radius ps) 0.0)
                       (let ([p (sc2-power-source-pos ps)])
                         (and (sc2-point3d? p)
                              (finite-world-coord? (sc2-point3d-x p))
                              (finite-world-coord? (sc2-point3d-y p))))))
                (sc2-observation-power-sources obs))
        '()))
  ;; Single-pass bucketing across `units`, `neutral-units`, `enemy-units`, and `self-units`
  (define all-unit-by-tag (make-hasheqv))
  (define rev-self-units '())
  (define rev-enemy-units '())
  (define rev-neutral-units '())
  (define rev-blocking-unit-circles '())
  (for ([u (in-list units)])
    (define utag (sc2-unit-tag u))
    (define al (sc2-unit-alliance u))
    (define dt (sc2-unit-display-type u))
    (define utype (sc2-unit-unit-type u))
    (hash-set! all-unit-by-tag utag u)
    ;; Skip non-blocking enemy CreepTumors (87/137/138) and lowered SupplyDepots (47) so ZvZ late-game
    ;; doesn't bloat `blocking-unit-circles` with 300+ non-blocking tumor circles.
    (when (and (not (sc2-unit-is-flying u))
               (not (= utype 47))
               (not (and (= al 4) (memv utype '(87 137 138))))
               (or (sc2-unit-is-structure? u)
                   (sc2-unit-is-mineral-field? u)
                   (sc2-unit-is-vespene-geyser? u)))
      (define up (sc2-unit-pos u))
      (set! rev-blocking-unit-circles
            (cons (vector (sc2-point3d-x up) (sc2-point3d-y up) (sc2-unit-radius u))
                  rev-blocking-unit-circles)))
    (cond
      [(and (= al 1) (not (= dt 4)))
       (set! rev-self-units (cons u rev-self-units))]
      [(and (= al 4) (not (= dt 4)))
       (set! rev-enemy-units (cons u rev-enemy-units))]
      [(= al 3)
       (set! rev-neutral-units (cons u rev-neutral-units))]))
  (define self-units (reverse rev-self-units))
  (define enemy-units (reverse rev-enemy-units))
  (define neutral-units (reverse rev-neutral-units))
  (define blocking-unit-circles (reverse rev-blocking-unit-circles))
  (define mineral-fields '())
  (define geysers '())
  (define mineral-by-tag (make-hasheqv))
  (define step-resource-units '())
  (for ([u (in-list rev-neutral-units)])
    (define min? (sc2-unit-is-mineral-field? u))
    (define gey? (and (not min?) (sc2-unit-is-vespene-geyser? u)))
    (when min?
      (set! mineral-fields (cons u mineral-fields))
      (hash-set! mineral-by-tag (sc2-unit-tag u) u))
    (when gey?
      (set! geysers (cons u geysers)))
    (when (or min? gey?)
      (set! step-resource-units (cons u step-resource-units))))
  (define solved-exp-bases
    (if (not (null? neutral-units))
        (solve-all-map-expansion-bases neutral-units eff-game-info)
        '()))
  (define all-expansion-pads
    (for/list ([b (in-list solved-exp-bases)])
      (cons (hash-ref b 'x) (hash-ref b 'y))))
  (define step-clusters
    (cond
      [(not (null? solved-exp-bases))
       (for/list ([b (in-list solved-exp-bases)])
         (list (hash-ref b 'x)
               (hash-ref b 'y)
               (append (hash-ref b 'minerals '())
                       (hash-ref b 'geysers '()))))]
      [(not (null? step-resource-units))
       (cluster-resource-centroids step-resource-units eff-game-info)]
      [else '()]))
  (when (> (length step-clusters) (length (unbox SC2-CACHED-MAP-BASE-CLUSTERS)))
    (set-box! SC2-CACHED-MAP-BASE-CLUSTERS step-clusters))
  (define live-visible-enemy-tags (mutable-seteqv))
  (define enemy-ground-units '())
  (define enemy-fast-breach-units '())
  (define enemy-gas-bldgs '())
  (define enemy-combat-for-geyser '())
  (for ([eu (in-list rev-enemy-units)])
    (define etag (sc2-unit-tag eu))
    (define ep (sc2-unit-pos eu))
    (define utype (sc2-unit-unit-type eu))
    (define esym (sc2-id->unit-symbol utype))
    (define struct? (sc2-unit-is-structure? eu))
    (define worker? (sc2-unit-is-worker? eu))
    (define non-combat-tumor? (memv utype '(87 137 138)))
    (define non-combat-egg? (memv utype '(151 103)))
    (when (valid-u64-tag? etag)
      (unless (or non-combat-tumor? non-combat-egg?)
        (hash-set! SC2-LAST-KNOWN-ENEMY-POS etag
                   (cons (sc2-point3d-x ep) (sc2-point3d-y ep))))
      (when (and (= (sc2-unit-display-type eu) 1)
                 (> (+ (sc2-unit-health eu) (sc2-unit-shield eu)) 0.0))
        (set-add! live-visible-enemy-tags etag)))
    (when (and (not (sc2-unit-is-flying eu)) (not non-combat-tumor?))
      (set! enemy-ground-units (cons eu enemy-ground-units))
      (when (memq esym '(zergling baneling reaper hellion hellbat adept zealot dark-templar))
        (set! enemy-fast-breach-units (cons eu enemy-fast-breach-units))))
    (when (sc2-unit-is-gas-building? eu)
      (set! enemy-gas-bldgs (cons eu enemy-gas-bldgs)))
    (when (and (not struct?)
               (not worker?)
               (not (memq esym '(overlord overseer observer larva egg))))
      (set! enemy-combat-for-geyser (cons eu enemy-combat-for-geyser))))
  (when (hash? obs)
    (define raw-eh-units (hash-ref obs 'enemy-units '()))
    (define raw-eh-bldgs (hash-ref obs 'enemy-buildings '()))
    (for ([eh (in-list (append (if (list? raw-eh-units) raw-eh-units '())
                               (if (list? raw-eh-bldgs) raw-eh-bldgs '())))]
          #:when (hash? eh))
      (define eid (hash-ref eh 'id 0))
      (when (valid-u64-tag? eid)
        (define ex (hash-ref eh 'x #f))
        (define ey (hash-ref eh 'y #f))
        (when (and (finite-world-coord? ex) (finite-world-coord? ey))
          (hash-set! SC2-LAST-KNOWN-ENEMY-POS eid
                     (cons (exact->inexact ex) (exact->inexact ey))))
        (define ehp (hash-ref eh 'hp 1))
        (when (and (finite-num? ehp) (> ehp 0)
                   (not (eq? (hash-ref eh 'snapshot? #f) #t))
                   (equal? (hash-ref eh 'display-type 1) 1))
          (set-add! live-visible-enemy-tags eid)))))
  ;; Purge stale remembered enemy coordinates once friendly vision covers their tile with no live unit present.
  ;; Runs at most once per 8 game loops using squared-distance + Chebyshev reject (avoids O(|M|*|N|) sqrt every step).
  (when (and (not (null? self-units))
             (> (hash-count SC2-LAST-KNOWN-ENEMY-POS) 0)
             (let ([last-p (unbox SC2-ENEMY-POS-PURGE-LAST-LOOP)])
               (or (< cur-loop last-p) (>= (- cur-loop last-p) 8))))
    (set-box! SC2-ENEMY-POS-PURGE-LAST-LOOP cur-loop)
    (define stale-etags
      (for/list ([(etag pt) (in-hash SC2-LAST-KNOWN-ENEMY-POS)]
                 #:when (and (pair? pt)
                             (not (set-member? live-visible-enemy-tags etag))
                             (let ([px (car pt)] [py (cdr pt)])
                               (ormap (lambda (u)
                                        (define up (sc2-unit-pos u))
                                        (define dx (- (sc2-point3d-x up) px))
                                        (define dy (- (sc2-point3d-y up) py))
                                        (and (<= (abs dx) 7.0)
                                             (<= (abs dy) 7.0)
                                             (<= (+ (* dx dx) (* dy dy)) 49.0)))
                                      self-units))))
        etag))
    (for ([etag (in-list stale-etags)])
      (hash-remove! SC2-LAST-KNOWN-ENEMY-POS etag)))
  ;; Synthetic test compatibility: if `obs` has neither `sc2-observation` units nor explicit
  ;; `enemy-units`/`enemy-buildings` keys, treat explicit integer target tags as valid unless cached stale.
  (define enforce-live-enemy-tag-filter?
    (or (sc2-observation? obs)
        (and (hash? obs)
             (or (hash-has-key? obs 'enemy-units)
                 (hash-has-key? obs 'enemy-buildings)))))
  (define hash-mineral-patches
    (if (hash? obs)
        (let ([mp1 (hash-ref obs 'mineral-patches '())]
              [mp2 (hash-ref obs 'mineral-fields '())])
          (filter (lambda (m)
                    (and (hash? m)
                         (valid-u64-tag? (hash-ref m 'id #f))))
                  (append (if (list? mp1) mp1 '())
                          (if (list? mp2) mp2 '()))))
        '()))
  (define hash-ally-by-id
    (if (hash? obs)
        (let ([au (hash-ref obs 'ally-units '())])
          (for/hasheqv ([u (in-list (if (list? au) au '()))]
                        #:when (and (hash? u) (valid-u64-tag? (hash-ref u 'id #f))))
            (values (hash-ref u 'id) u)))
        (hasheqv)))
  ;; Single-pass bucketing across `self-units` (iterating `rev-self-units` preserves exact list order)
  (define self-unit-by-tag (make-hasheqv))
  (define self-unit-pos-by-tag (make-hasheqv))
  (define self-units-by-sym (make-hasheq))
  (define self-structures '())
  (define self-gas-bldgs '())
  (define completed-gas-buildings '())
  (define gas-bldg-tags-set (mutable-seteqv))
  (define completed-pylons '())
  (define creep-source-circles '())
  (define self-ground-nonstruct-units '())
  (define self-mode-toggle-units '())
  (define workers '())
  (define townhalls-unsorted '())
  (define combat-units '())
  (define total-combat-supply 0)
  (for ([u (in-list rev-self-units)])
    (define utag (sc2-unit-tag u))
    (define utype (sc2-unit-unit-type u))
    (define usym (sc2-id->unit-symbol utype))
    (define up (sc2-unit-pos u))
    (define ux (sc2-point3d-x up))
    (define uy (sc2-point3d-y up))
    (define prog (sc2-unit-build-progress u))
    (define complete? (>= prog SC2-BUILD-COMPLETE-PROGRESS))
    (define struct? (sc2-unit-is-structure? u))
    (define worker? (sc2-unit-is-worker? u))
    (define flying? (sc2-unit-is-flying u))
    (define stasis? (memv 57 (sc2-unit-buff-ids u)))
    (hash-set! self-unit-by-tag utag u)
    (hash-set! self-unit-pos-by-tag utag (cons ux uy))
    (hash-update! self-units-by-sym usym (lambda (xs) (cons u xs)) '())
    (when struct?
      (set! self-structures (cons u self-structures))
      (when (sc2-unit-is-gas-building? u)
        (set! self-gas-bldgs (cons u self-gas-bldgs))
        (set-add! gas-bldg-tags-set utag)
        (when complete?
          (set! completed-gas-buildings (cons u completed-gas-buildings))))
      (when (memq usym '(hatchery lair hive))
        (set! creep-source-circles (cons (vector ux uy 12.0) creep-source-circles)))
      (when (or (eq? usym 'creep-tumor-burrowed)
                (and complete? (memq usym '(creep-tumor creep-tumor-queen))))
        (set! creep-source-circles (cons (vector ux uy 10.0) creep-source-circles))))
    (when (and complete? (memq usym '(pylon pylon-overcharged warp-prism-phasing)))
      (set! completed-pylons (cons u completed-pylons)))
    (when (and (not struct?) (not flying?))
      (set! self-ground-nonstruct-units (cons u self-ground-nonstruct-units)))
    (when (memv utype '(19 47 32 33 498 500 502 503))
      (set! self-mode-toggle-units (cons u self-mode-toggle-units)))
    (when (and worker? (not stasis?))
      (set! workers (cons u workers)))
    (when (sc2-unit-is-townhall? u)
      (set! townhalls-unsorted (cons u townhalls-unsorted)))
    (when (and (not struct?)
               (not worker?)
               (not stasis?)
               (not (sc2-non-combat-or-summon-sym? usym))
               (not (memq usym '(larva egg queen)))
               (not (and (hash? role-leases)
                         (unit-leased-above? role-leases utag 'army cur-loop))))
      (set! combat-units (cons u combat-units))
      (set! total-combat-supply (+ total-combat-supply (max 1 (sc2-supply-cost usym))))))
  (define active-friendly-th-build-pads
    (for*/list ([w (in-list workers)]
                #:when (not (worker-build-order-stuck? w cur-loop))
                [o (in-list (sc2-unit-orders w))]
                #:when (and (memv (sc2-unit-order-ability-id o) '(318 880 1152))
                            (any-point? (sc2-unit-order-target-pos o))
                            (let ([wp (sc2-unit-pos w)]
                                  [tp (sc2-unit-order-target-pos o)])
                              (<= (pt-dist (sc2-point3d-x wp) (sc2-point3d-y wp)
                                           (any-point-x tp) (any-point-y tp))
                                  12.0))))
      (define tp (sc2-unit-order-target-pos o))
      (cons (any-point-x tp) (any-point-y tp))))
  (define townhalls (sort-townhalls-main-first townhalls-unsorted))

  (define (unit-has-protected-order? t)
    (define u (hash-ref self-unit-by-tag t #f))
    (and u
         (pair? (sc2-unit-orders u))
         (sc2-order-protection-class (sc2-unit-order-ability-id (first (sc2-unit-orders u))))))
  (define unit-has-protected-queen-order? unit-has-protected-order?)

  (define-values (home-x home-y)
    (if (not (null? townhalls))
        (let ([p (sc2-unit-pos (first townhalls))])
          (values (sc2-point3d-x p) (sc2-point3d-y p)))
        (let ([anchor (unbox SC2-HOME-BASE-ANCHOR)])
          (if anchor
              (values (car anchor) (cdr anchor))
              (values SC2-DEFAULT-HOME-BASE-X SC2-DEFAULT-HOME-BASE-Y)))))

  (define-values (default-eb-x default-eb-y)
    (if (and (list? enemy-base) (>= (length enemy-base) 2))
        (values (exact->inexact (first enemy-base))
                (exact->inexact (second enemy-base)))
        (values (- SC2-DEFAULT-MAP-WIDTH home-x)
                (- SC2-DEFAULT-MAP-HEIGHT home-y))))

  (define targetable-enemy-units
    (filter (lambda (e)
              (sc2-enemy-unit-targetable? (sc2-id->unit-symbol (sc2-unit-unit-type e))))
            enemy-units))

  ;; W8-P0-4-wire: Identify live enemy units threatening any of our TownHalls (<= 24.0t, 576.0 sq-dist)
  ;; so own-base defensive `attack-unit` commands are promoted to P0 urgent survival (strictly above
  ;; P1 macro, P2 worker-scout/harass, and P3 harvest) and home workers aren't sent cross-map mid-rush.
  (define enemy-near-own-base-tags (mutable-seteqv))
  (define enemy-combat-near-own-base? #f)
  (when (and (pair? townhalls) (pair? targetable-enemy-units))
    (for ([eu (in-list targetable-enemy-units)])
      (define ep (sc2-unit-pos eu))
      (define ex (sc2-point3d-x ep))
      (define ey (sc2-point3d-y ep))
      (when (for/or ([th (in-list townhalls)])
              (define tp (sc2-unit-pos th))
              (define dx (- ex (sc2-point3d-x tp)))
              (define dy (- ey (sc2-point3d-y tp)))
              (and (<= (abs dx) 24.0) (<= (abs dy) 24.0)
                   (<= (+ (* dx dx) (* dy dy)) 576.0)))
        (set-add! enemy-near-own-base-tags (sc2-unit-tag eu))
        (when (sc2-unit-targetable-enemy-combat? eu)
          (set! enemy-combat-near-own-base? #t)))))

  (define combat-unit-tags-set
    (for/seteqv ([u (in-list combat-units)])
      (sc2-unit-tag u)))

  (define (compute-home-staging-point ref-x ref-y)
    (define-values (stage-x0 stage-y0)
      (let* ([dx (- ref-x home-x)]
             [dy (- ref-y home-y)]
             [d (max 1.0 (sqrt (+ (sqr dx) (sqr dy))))]
             [step-d (min 18.0 (* 0.25 d))])
        (values (+ home-x (* step-d (/ dx d)))
                (+ home-y (* step-d (/ dy d))))))
    ;; Push staging point >= 6.5 tiles away from any solved expansion pad within 6.0 tiles
    (let ([near-pad
           (for/first ([ep (in-list all-expansion-pads)]
                       #:when (< (pt-dist stage-x0 stage-y0 (car ep) (cdr ep)) 6.0))
             ep)])
      (if near-pad
          (let* ([px (car near-pad)]
                 [py (cdr near-pad)]
                 [dx (- stage-x0 px)]
                 [dy (- stage-y0 py)]
                 [d (sqrt (+ (* dx dx) (* dy dy)))]
                 [ux (if (< d 0.25) 1.0 (/ dx d))]
                 [uy (if (< d 0.25) 0.0 (/ dy d))])
            (values (max SC2-MAP-PLAYABLE-MIN-COORD (min SC2-MAP-PLAYABLE-MAX-COORD (+ px (* 6.5 ux))))
                    (max SC2-MAP-PLAYABLE-MIN-COORD (min SC2-MAP-PLAYABLE-MAX-COORD (+ py (* 6.5 uy))))))
          (values stage-x0 stage-y0))))

  (define-values (default-stage-x default-stage-y)
    (compute-home-staging-point default-eb-x default-eb-y))

  ;; Track verified enemy-main clearance:
  ;;   - Reset if any live/snapshot enemy unit or building is seen within 22 tiles of enemy main.
  ;;   - Set ONLY once our combat force actually visits enemy main (`<= 12` tiles) at `cur-loop >= 4480`
  ;;     with zero visible/snapshot enemy units or structures anywhere on the map.
  (define enemy-present-near-eb?
    (ormap (lambda (e)
             (define ep (sc2-unit-pos e))
             (<= (pt-dist default-eb-x default-eb-y (sc2-point3d-x ep) (sc2-point3d-y ep)) 22.0))
           enemy-units))
  (cond
    [enemy-present-near-eb?
     (set-box! SC2-ENEMY-MAIN-CLEARED-AT #f)]
    [(and (null? enemy-units)
          (>= cur-loop 4480))
     (define combat-at-eb-count
       (count (lambda (u)
                (define up (sc2-unit-pos u))
                (<= (pt-dist default-eb-x default-eb-y (sc2-point3d-x up) (sc2-point3d-y up)) 12.0))
              combat-units))
     (when (or (>= combat-at-eb-count 2)
               (and (>= cur-loop 6000) (>= combat-at-eb-count 1)))
       (set-box! SC2-ENEMY-MAIN-CLEARED-AT (cons default-eb-x default-eb-y))
       (define cur-cleared (unbox SC2-CLEARED-ENEMY-BASES))
       (unless (ormap (lambda (old)
                        (and (pair? old)
                             (<= (pt-dist default-eb-x default-eb-y (car old) (cdr old)) 7.5)))
                      cur-cleared)
         (set-box! SC2-CLEARED-ENEMY-BASES
                   (cons (cons default-eb-x default-eb-y) cur-cleared))))])

  (define enemy-main-cleared?
    (or (let ([cm (unbox SC2-ENEMY-MAIN-CLEARED-AT)])
          (and (pair? cm)
               (<= (pt-dist default-eb-x default-eb-y (car cm) (cdr cm)) 12.0)))
        (ormap (lambda (old)
                 (and (pair? old)
                      (<= (pt-dist default-eb-x default-eb-y (car old) (cdr old)) 12.0)))
               (unbox SC2-CLEARED-ENEMY-BASES))))
  (when (not (null? mineral-fields))
    (set-box! SC2-EVER-SAW-MINERALS? #t))
  (define map-mined-out-cleanup?
    (and (>= cur-loop 6000)
         (null? enemy-units)
         (null? mineral-fields)
         (or (unbox SC2-EVER-SAW-MINERALS?)
             (not (null? (unbox SC2-CACHED-MAP-BASE-CLUSTERS))))))
  (define explicit-endgame-cleanup?
    (or (eq? endgame-cleanup-kw #t)
        (and (hash? obs) (eq? (hash-ref obs 'endgame-cleanup? #f) #t))
        (eq? tactical-posture-kw 'endgame-cleanup)
        (and (hash? obs) (eq? (hash-ref obs 'tactical-posture #f) 'endgame-cleanup))))
  (define verified-endgame-map-state?
    (or enemy-main-cleared? map-mined-out-cleanup? explicit-endgame-cleanup?))

  ;; Detect Layer 3/4 hold / defend / suppress-attack posture signals so the wire fallback
  ;; NEVER overrides a tactical hold/rally decision by marching or scattering units cross-map.
  (define (defensive-hold-posture-sym? s)
    (and (symbol? s)
         (not (not (memq s '(hold defend retreat suppress-attack
                             EarlyScoutCrisis CrisisZealotRush CrisisZerglingFlood CrisisEarlyBust))))))
  (define (hard-defensive-spatial-maneuver-sym? s)
    (and (symbol? s)
         (not (not (memq s '(hold defend retreat regroup suppress-attack))))))
  (define (defensive-spatial-maneuver-sym? s)
    (and (symbol? s)
         (not (not (memq s '(pre-rotate-intercept-incoming-threat
                             safe-to-expand-enemy-pinned-far
                             hold defend retreat regroup suppress-attack))))))
  (define (point-on-home-side? x y)
    (let ([d-home (pt-dist home-x home-y x y)]
          [d-eb (pt-dist default-eb-x default-eb-y x y)])
      (and (<= d-home 52.0)
           (< d-home (* 0.85 d-eb)))))
  (define (count-combat-tags raw-ids)
    (for/sum ([t (in-list (if (list? raw-ids) raw-ids (list raw-ids)))])
      (if (and (exact-integer? t) (set-member? combat-unit-tags-set t)) 1 0)))

  (define action-explicit-suppress? #f)
  (define hold-pos-combat-count 0)
  (define home-move-combat-count 0)
  (define action-has-offensive-push? #f)
  (define action-has-defensive-spatial-maneuver? #f)
  (define action-has-home-spatial-target? #f)
  (define action-has-hg-hold? #f)
  (define action-defensive-maneuver-pt #f)
  (define action-hg-hold-pt #f)
  (define step-wants-lair? #f)
  (define step-wants-hive? #f)
  (for ([act (in-list actions)]
        #:when (pair? act))
    (case (car act)
      [(build morph)
       (define tgt-sym
         (cond
           [(and (eq? (car act) 'build) (pair? (cdr act)))
            (normalize-sc2-name->symbol (cadr act))]
           [(and (eq? (car act) 'morph) (= (length act) 2))
            (normalize-sc2-name->symbol (cadr act))]
           [(and (eq? (car act) 'morph) (= (length act) 3))
            (normalize-sc2-name->symbol (caddr act))]
           [else #f]))
       (cond
         [(eq? tgt-sym 'lair) (set! step-wants-lair? #t)]
         [(eq? tgt-sym 'hive) (set! step-wants-hive? #t)])]
      [(posture-transition execute-spatial-maneuver mirror-spatial-maneuver
        high-ground-tactics retreat hold-position move attack-pos)
       (match act
         [(list 'posture-transition p)
          (when (defensive-hold-posture-sym? p)
            (set! action-explicit-suppress? #t))]
         [(or (list (or 'execute-spatial-maneuver 'mirror-spatial-maneuver) msym raw-x raw-y)
              (and (list 'execute-spatial-maneuver (? real? raw-x) (? real? raw-y) (? real? _) (? real? _))
                   (app (lambda (_) 'multiprong-rotate-and-pin) msym)))
          (define tx (scale-bot-coord-to-world raw-x home-x))
          (define ty (scale-bot-coord-to-world raw-y home-y))
          (cond
            [(hard-defensive-spatial-maneuver-sym? msym)
             (set! action-explicit-suppress? #t)
             (set! action-has-defensive-spatial-maneuver? #t)
             (set! action-defensive-maneuver-pt (cons tx ty))]
            [(defensive-spatial-maneuver-sym? msym)
             (set! action-has-defensive-spatial-maneuver? #t)
             (set! action-defensive-maneuver-pt (cons tx ty))]
            [(point-on-home-side? tx ty)
             (set! action-has-home-spatial-target? #t)
             (unless action-defensive-maneuver-pt
               (set! action-defensive-maneuver-pt (cons tx ty)))]
            [else
             (set! action-has-offensive-push? #t)])]
         [(list 'high-ground-tactics 'hold-high-ground-ramp-arc (? real? raw-x) (? real? raw-y) _)
          (define tx (scale-bot-coord-to-world raw-x home-x))
          (define ty (scale-bot-coord-to-world raw-y home-y))
          (set! action-has-hg-hold? #t)
          (set! action-hg-hold-pt (cons tx ty))]
         [(list 'retreat uid (? real? raw-x) (? real? raw-y))
          (when (> (count-combat-tags uid) 0)
            (set! action-explicit-suppress? #t)
            (define tx (scale-bot-coord-to-world raw-x home-x))
            (define ty (scale-bot-coord-to-world raw-y home-y))
            (when (and (point-on-home-side? tx ty) (not action-defensive-maneuver-pt))
              (set! action-defensive-maneuver-pt (cons tx ty))))]
         [(list 'hold-position uid rest ...)
          (define cnt (count-combat-tags uid))
          (when (> cnt 0)
            (set! hold-pos-combat-count (+ hold-pos-combat-count cnt))
            (when (and (>= (length rest) 2) (real? (first rest)) (real? (second rest))
                       (not action-defensive-maneuver-pt))
              (define tx (scale-bot-coord-to-world (first rest) home-x))
              (define ty (scale-bot-coord-to-world (second rest) home-y))
              (when (point-on-home-side? tx ty)
                (set! action-defensive-maneuver-pt (cons tx ty)))))]
         [(list 'move uid (? real? raw-x) (? real? raw-y))
          (define cnt (count-combat-tags uid))
          (when (> cnt 0)
            (define tx (scale-bot-coord-to-world raw-x home-x))
            (define ty (scale-bot-coord-to-world raw-y home-y))
            (when (point-on-home-side? tx ty)
              (set! home-move-combat-count (+ home-move-combat-count cnt))
              (unless action-defensive-maneuver-pt
                (set! action-defensive-maneuver-pt (cons tx ty)))))]
         [(list 'attack-pos ids (? real? raw-x) (? real? raw-y))
          (when (> (count-combat-tags ids) 0)
            (define tx (scale-bot-coord-to-world raw-x home-x))
            (define ty (scale-bot-coord-to-world raw-y home-y))
            (unless (point-on-home-side? tx ty)
              (set! action-has-offensive-push? #t)))]
         [_ (void)])]
      [else (void)]))
  (when step-wants-lair?
    (set-box! SC2-ZERG-TH-MORPH-RESERVE-LOOP (cons 'lair cur-loop)))
  (when step-wants-hive?
    (set-box! SC2-ZERG-TH-MORPH-RESERVE-LOOP (cons 'hive cur-loop)))

  (define army-hold-quorum (max 2 (quotient (length combat-units) 3)))
  (define explicit-hold-or-suppress?
    (or (eq? suppress-attack-kw #t)
        (defensive-hold-posture-sym? tactical-posture-kw)
        (and (hash? obs)
             (or (eq? (hash-ref obs 'combat-suppress-attack? #f) #t)
                 (eq? (hash-ref obs 'suppress-attack? #f) #t)
                 (defensive-hold-posture-sym? (hash-ref obs 'tactical-posture #f))
                 (defensive-hold-posture-sym? (hash-ref obs 'posture #f))))
        action-explicit-suppress?
        (>= hold-pos-combat-count army-hold-quorum)
        (and (not action-has-offensive-push?)
             (>= home-move-combat-count army-hold-quorum))))

  (define can-push-or-sweep?
    (or (>= (length combat-units) 14)
        (>= total-combat-supply 20)
        (and (>= cur-loop 6000)
             (null? enemy-units)
             verified-endgame-map-state?
             (>= (length combat-units) 4))))
  (define decisive-cleanup-army?
    (or (>= total-combat-supply 20)
        (>= (length combat-units) 14)
        (and (>= cur-loop 6000)
             (>= (length combat-units) 4))))
  ;; Strictly gate multi-waypoint fan-out splitting to verified endgame building-cleanup conditions
  ;; (enemy main verified cleared + decisive army, mined-out late-game map, or explicit endgame cleanup),
  ;; NEVER bare presence of `mineral-fields` or `sc2-game-info?` during normal early/midgame play!
  (define sweep-context-active?
    (and (null? targetable-enemy-units)
         (null? enemy-units)
         (not explicit-hold-or-suppress?)
         (or (and enemy-main-cleared? decisive-cleanup-army?)
             (and map-mined-out-cleanup? can-push-or-sweep?)
             (and explicit-endgame-cleanup? can-push-or-sweep?))))

  ;; W7-P0-2-wire: Never let transient `sticky-hold-pt` or `action-has-hg-hold?` pull idle
  ;; maxed/dominant armies (>= 40 combat supply, no explicit hold/suppress) backward to home
  ;; staging when `targetable-enemy-units` is empty and an offensive push or `enemy-main-cleared?`
  ;; is/was active!
  (define offensive-push-entry (unbox SC2-WIRE-OFFENSIVE-PUSH-STATE))
  (define recent-offensive-push-active?
    (or action-has-offensive-push?
        (and (list? offensive-push-entry)
             (= (length offensive-push-entry) 4)
             (>= cur-loop (first offensive-push-entry))
             (<= cur-loop (second offensive-push-entry))
             (<= (pt-dist home-x home-y (third offensive-push-entry) (fourth offensive-push-entry)) 6.0))))
  (define maxed-army-push-suppresses-home-hold?
    (and (>= total-combat-supply 40)
         (not explicit-hold-or-suppress?)
         (null? targetable-enemy-units)
         (or recent-offensive-push-active?
             enemy-main-cleared?
             map-mined-out-cleanup?
             explicit-endgame-cleanup?)))

  (define sticky-hold-entry (unbox SC2-WIRE-HOLD-POSTURE-STATE))
  (define sticky-hold-pt
    (and (not sweep-context-active?)
         (not action-has-offensive-push?)
         (not maxed-army-push-suppresses-home-hold?)
         (list? sticky-hold-entry)
         (= (length sticky-hold-entry) 6)
         (> cur-loop (first sticky-hold-entry))
         (<= cur-loop (second sticky-hold-entry))
         (<= (pt-dist home-x home-y (fifth sticky-hold-entry) (sixth sticky-hold-entry)) 6.0)
         (cons (third sticky-hold-entry) (fourth sticky-hold-entry))))
  (define action-defensive-maneuver-active?
    (and (not sweep-context-active?)
         (not (null? townhalls))
         (or action-has-defensive-spatial-maneuver?
             (and (not action-has-offensive-push?)
                  (not maxed-army-push-suppresses-home-hold?)
                  (or action-has-home-spatial-target?
                      action-has-hg-hold?)))))
  (define tactical-hold-posture?
    (or explicit-hold-or-suppress?
        action-defensive-maneuver-active?
        (and sticky-hold-pt #t)))
  (define-values (eff-hold-x eff-hold-y)
    (cond
      [(pair? action-defensive-maneuver-pt)
       (values (car action-defensive-maneuver-pt) (cdr action-defensive-maneuver-pt))]
      [(and action-has-hg-hold?
            (not action-has-offensive-push?)
            (not maxed-army-push-suppresses-home-hold?)
            (pair? action-hg-hold-pt))
       (values (car action-hg-hold-pt) (cdr action-hg-hold-pt))]
      [(pair? sticky-hold-pt)
       (values (car sticky-hold-pt) (cdr sticky-hold-pt))]
      [else
       (values default-stage-x default-stage-y)]))
  (cond
    [(and (or action-has-offensive-push?
              sweep-context-active?
              maxed-army-push-suppresses-home-hold?)
          (not explicit-hold-or-suppress?))
     (set-box! SC2-WIRE-HOLD-POSTURE-STATE #f)]
    [(or explicit-hold-or-suppress? action-defensive-maneuver-active?)
     (set-box! SC2-WIRE-HOLD-POSTURE-STATE
               (list cur-loop (+ cur-loop 36) eff-hold-x eff-hold-y home-x home-y))])
  (cond
    [explicit-hold-or-suppress?
     (set-box! SC2-WIRE-OFFENSIVE-PUSH-STATE #f)]
    [action-has-offensive-push?
     (set-box! SC2-WIRE-OFFENSIVE-PUSH-STATE
               (list cur-loop (+ cur-loop 64) home-x home-y))])

  ;; Playable-area sweep bounds derived strictly from `sc2-game-info` `playable-area` / `map-size`
  ;; (NEVER hardcoded `240.0`!), inset by `3.5` tiles so both ground and air sweepers stay inside bounds.
  (define (playable-sweep-bounds)
    (define-values (px0 py0 px1 py1)
      (cond
        [(sc2-game-info? eff-game-info)
         (define pa (sc2-game-info-playable-area eff-game-info))
         (define ms (sc2-game-info-map-size eff-game-info))
         (cond
           [(hash? pa)
            (values (exact->inexact (hash-ref pa 'x0 8))
                    (exact->inexact (hash-ref pa 'y0 8))
                    (exact->inexact (hash-ref pa 'x1 168))
                    (exact->inexact (hash-ref pa 'y1 168)))]
           [(and (list? pa) (>= (length pa) 4))
            (values (exact->inexact (first pa))
                    (exact->inexact (second pa))
                    (exact->inexact (third pa))
                    (exact->inexact (fourth pa)))]
           [(pair? ms)
            (values 8.0 8.0
                    (exact->inexact (max 32 (- (car ms) 8)))
                    (exact->inexact (max 32 (- (cdr ms) 8))))]
           [else (values 8.0 8.0 168.0 168.0)])]
        [(and (hash? obs) (hash? (hash-ref obs 'playable-area #f)))
         (define pa (hash-ref obs 'playable-area))
         (values (exact->inexact (hash-ref pa 'x0 8))
                 (exact->inexact (hash-ref pa 'y0 8))
                 (exact->inexact (hash-ref pa 'x1 168))
                 (exact->inexact (hash-ref pa 'y1 168)))]
        [else (values 8.0 8.0 168.0 168.0)]))
    (define cx0 (+ px0 3.5))
    (define cy0 (+ py0 3.5))
    (define cx1 (max (+ cx0 8.0) (- px1 3.5)))
    (define cy1 (max (+ cy0 8.0) (- py1 3.5)))
    (values cx0 cy0 cx1 cy1))

  ;; Multi-base, back-of-main (`+-12` tiles), and playable-corner/edge endgame sweep planner:
  ;;   - Combines live resource clusters + `SC2-CACHED-MAP-BASE-CLUSTERS` (mined-out maps stay active!)
  ;;   - Does NOT exclude bases within `14.0` tiles of friendly `townhalls` (`sight-range = 11`!)
  ;;   - Appends `+-12`-tile back-of-main/geyser offsets around `(eb-x, eb-y)` plus playable-area
  ;;     `4` corners and `4` edge midpoints.
  ;;   - Returns `(values top-waypoints flyer-waypoints corner-unvisited)` where each waypoint is `(cons x y)`.
  (define (compute-endgame-sweep-plan eb-x eb-y)
    (define-values (cx0 cy0 cx1 cy1) (playable-sweep-bounds))
    (define (clamp-x v) (max cx0 (min cx1 (exact->inexact v))))
    (define (clamp-y v) (max cy0 (min cy1 (exact->inexact v))))
    (define live-clusters step-clusters)
    (define raw-clusters
      (append live-clusters (unbox SC2-CACHED-MAP-BASE-CLUSTERS)))
    (define sorted-clusters
      (sort raw-clusters <
            #:key (lambda (c) (pt-dist eb-x eb-y (first c) (second c)))))
    (define raw-wps
      (append
       (list (list (clamp-x eb-x) (clamp-y eb-y) 'base)
             (list (clamp-x (+ eb-x 12.0)) (clamp-y eb-y) 'back-of-main)
             (list (clamp-x (- eb-x 12.0)) (clamp-y eb-y) 'back-of-main)
             (list (clamp-x eb-x) (clamp-y (+ eb-y 12.0)) 'back-of-main)
             (list (clamp-x eb-x) (clamp-y (- eb-y 12.0)) 'back-of-main)
             (list (clamp-x (+ eb-x 10.0)) (clamp-y (+ eb-y 10.0)) 'back-of-main)
             (list (clamp-x (- eb-x 10.0)) (clamp-y (- eb-y 10.0)) 'back-of-main))
       (for/list ([c (in-list sorted-clusters)])
         (list (clamp-x (first c)) (clamp-y (second c)) 'base))
       (let ([mx (* 0.5 (+ cx0 cx1))]
             [my (* 0.5 (+ cy0 cy1))])
         (list (list cx0 cy0 'corner)
               (list cx1 cy1 'corner)
               (list cx0 cy1 'corner)
               (list cx1 cy0 'corner)
               (list mx cy0 'edge)
               (list mx cy1 'edge)
               (list cx0 my 'edge)
               (list cx1 my 'edge)))))
    ;; Deduplicate candidate waypoints within 6.0 tiles
    (define deduped-wps
      (reverse
       (for/fold ([acc '()]) ([wp (in-list raw-wps)])
         (define wx (first wp))
         (define wy (second wp))
         (if (ormap (lambda (prev) (<= (pt-dist wx wy (first prev) (second prev)) 6.0)) acc)
             acc
             (cons wp acc)))))
    ;; Mark any waypoint within `8.5` tiles of a friendly unit as cleared when `0` enemies are visible
    (define cur-cleared (unbox SC2-CLEARED-ENEMY-BASES))
    (when (null? enemy-units)
      (for ([wp (in-list deduped-wps)])
        (define wx (first wp))
        (define wy (second wp))
        (define friendly-gives-vision?
          (ormap (lambda (u)
                   (define up (sc2-unit-pos u))
                   (<= (pt-dist wx wy (sc2-point3d-x up) (sc2-point3d-y up)) 8.5))
                 self-units))
        (when (and friendly-gives-vision?
                   (not (ormap (lambda (old) (<= (pt-dist wx wy (car old) (cdr old)) 7.5))
                               cur-cleared)))
          (set! cur-cleared (cons (cons wx wy) cur-cleared))))
      (set-box! SC2-CLEARED-ENEMY-BASES cur-cleared))
    (define (wp-unvisited? wp)
      (not (ormap (lambda (old) (<= (pt-dist (first wp) (second wp) (car old) (cdr old)) 7.5))
                  cur-cleared)))
    (define unvisited-all (filter wp-unvisited? deduped-wps))
    (define active-wps
      (if (not (null? unvisited-all))
          unvisited-all
          (begin
            (set-box! SC2-CLEARED-ENEMY-BASES '())
            deduped-wps)))
    (define top-pts
      (for/list ([wp (in-list (take active-wps (min 6 (length active-wps))))])
        (cons (first wp) (second wp))))
    (define corner-edge-wps
      (filter (lambda (wp) (memq (third wp) '(corner edge))) active-wps))
    (define corner-only-wps
      (filter (lambda (wp) (eq? (third wp) 'corner)) active-wps))
    (define flyer-pts
      (if (not (null? corner-edge-wps))
          (for/list ([wp (in-list (take corner-edge-wps (min 4 (length corner-edge-wps))))])
            (cons (first wp) (second wp)))
          top-pts))
    (define corner-pts
      (for/list ([wp (in-list corner-only-wps)])
        (cons (first wp) (second wp))))
    (values top-pts flyer-pts corner-pts))

  ;; Track producer, worker, geyser, combat tags, and build-site reservations within this step
  (define used-producer-tags (mutable-seteqv))
  (define used-producer-counts (make-hasheqv))
  (define used-worker-tags (mutable-seteqv))
  (define builder-worker-tags (mutable-seteqv))
  (define used-geyser-tags (mutable-seteqv))
  (define commanded-combat-tags (mutable-seteqv))
  ;; Per-step placement RPC budget (<= 2 RPCs/step; P1 macro builds run first in `ordered-actions`)
  ;; and Creep Tumor throttle (<= 1 fan search/step & <= 1 RPC per 8 loops) to keep late-Zerg tr < 4.5ms.
  (define step-placement-rpc-budget (box 2))
  (define step-tumor-rpc-count 0)
  (define step-tumor-placement-count 0)
  (define step-reserved-build-pts '())
  (define step-built-structure-counts (make-hasheq))
  (define last-cam-pt #f)

  (define (wire-nonstack-allow?! key cd-loops)
    (cond
      [(<= cur-loop 0) #t]
      [else
       (define ready-loop (hash-ref SC2-WIRE-NONSTACK-CMD-COOLDOWN key -1))
       (if (>= cur-loop ready-loop)
           (begin
             (hash-set! SC2-WIRE-NONSTACK-CMD-COOLDOWN key (+ cur-loop cd-loops))
             #t)
           #f)]))

  (define (structure-total-with-pending bsym)
    (define canon (sc2-canonical-structure-sym bsym))
    (define existing-matching
      (filter (lambda (u)
                (sc2-structure-matches-target?
                 (sc2-id->unit-symbol (sc2-unit-unit-type u))
                 canon #f))
              self-structures))
    (define incomplete-matching
      (filter (lambda (u) (< (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS))
              existing-matching))
    (define in-transit-worker-cnt
      (count (lambda (w)
               (define wtag (sc2-unit-tag w))
               (define wp (sc2-unit-pos w))
               (define wx (sc2-point3d-x wp))
               (define wy (sc2-point3d-y wp))
               (define order-transit?
                 (and (not (worker-build-order-stuck? w cur-loop))
                      (ormap (lambda (o)
                               (define s (sc2-id->ability-symbol (sc2-unit-order-ability-id o) #f))
                               (define st (if s (symbol->string s) ""))
                               (define ord-pos (sc2-unit-order-target-pos o))
                               (define tx (if (any-point? ord-pos) (any-point-x ord-pos) wx))
                               (define ty (if (any-point? ord-pos) (any-point-y ord-pos) wy))
                               (define tgt-tag (sc2-unit-order-target-unit-tag o))
                               (and (string-prefix? st "build-")
                                    (sc2-structure-matches-target?
                                     (sc2-canonical-structure-sym (string->symbol (substring st 6)))
                                     canon #f)
                                    (not (ormap (lambda (b)
                                                  (define bp (sc2-unit-pos b))
                                                  (or (= tgt-tag (sc2-unit-tag b))
                                                      (<= (pt-dist tx ty (sc2-point3d-x bp) (sc2-point3d-y bp)) 6.0)
                                                      (<= (pt-dist wx wy (sc2-point3d-x bp) (sc2-point3d-y bp)) 6.0)))
                                                incomplete-matching))))
                             (sc2-unit-orders w))))
               (or order-transit?
                   (let ([res (hash-ref SC2-BUILDER-RESERVATION wtag #f)])
                     (and res
                          (> cur-loop (first res))
                          (< cur-loop (second res))
                          (let* ([rx (third res)]
                                 [ry (fourth res)]
                                 [rab (fifth res)]
                                 [rsym (sc2-id->ability-symbol rab #f)]
                                 [rstr (if rsym (symbol->string rsym) "")])
                            (and (string-prefix? rstr "build-")
                                 (sc2-structure-matches-target?
                                  (sc2-canonical-structure-sym (string->symbol (substring rstr 6)))
                                  canon #f)
                                 (not (ormap (lambda (b)
                                               (define bp (sc2-unit-pos b))
                                               (<= (pt-dist rx ry (sc2-point3d-x bp) (sc2-point3d-y bp)) 6.0))
                                             incomplete-matching))))))))
             workers))
    (+ (length existing-matching)
       in-transit-worker-cnt
       (hash-ref step-built-structure-counts canon 0)))

  (define (tech-cap-allows-build? bsym)
    (define canon (sc2-canonical-structure-sym bsym))
    (define cap
      (cond
        [(or (memq canon SC2-SINGLETON-TECH-BUILDINGS)
             (memq bsym SC2-SINGLETON-TECH-BUILDINGS)) 1]
        [(or (memq canon SC2-DUAL-CAP-TECH-BUILDINGS)
             (memq bsym SC2-DUAL-CAP-TECH-BUILDINGS)) 2]
        [else #f]))
    (or (not cap) (< (structure-total-with-pending bsym) cap)))

  (define (record-step-built-structure! bsym)
    (define canon (sc2-canonical-structure-sym bsym))
    (hash-set! step-built-structure-counts canon
               (add1 (hash-ref step-built-structure-counts canon 0))))

  (define step-scout-worker-tags
    (for/fold ([s (seteqv)]) ([act (in-list (if (list? actions) actions '()))])
      (match act
        [(list (or 'worker-scout 'worker-harass 'mineral-walk) (? exact-integer? wid) _ _)
         (set-add s wid)]
        [(list 'mineral-walk (? exact-integer? wid) _ _ _)
         (set-add s wid)]
        [(list 'mineral-harass (? exact-integer? wid) _ _ _ _)
         (set-add s wid)]
        [_ s])))

  (define (reserve-step-build-pt! pt [ab-id 0])
    (when (sc2-point2d? pt)
      (set! step-reserved-build-pts (cons pt step-reserved-build-pts))
      (when (memv ab-id '(321 328 329))
        (set! step-reserved-build-pts
              (cons (sc2-point2d (+ (sc2-point2d-x pt) SC2-TERRAN-ADDON-OFFSET-X)
                                 (+ (sc2-point2d-y pt) SC2-TERRAN-ADDON-OFFSET-Y))
                    step-reserved-build-pts)))))

  (define (record-worker-used! wtag [is-builder? #f])
    (when wtag
      (set-add! used-worker-tags wtag)
      (when is-builder?
        (set-add! builder-worker-tags wtag))
      (when (set-mutable? commanded-workers)
        (set-add! commanded-workers wtag))
      (when (set-mutable? external-used-worker-tags)
        (set-add! external-used-worker-tags wtag))))

  (define (record-builder-reservation! wtag tx ty ab-id)
    (when (and (exact-integer? wtag) (> wtag 0) (>= cur-loop 0))
      (hash-set! SC2-BUILDER-RESERVATION wtag
                 (list cur-loop (+ cur-loop 32) tx ty ab-id))))

  (define (record-unit-used! utag)
    (when utag
      (set-add! commanded-combat-tags utag)))

  (define (worker-is-gas-harvester? w)
    (ormap (lambda (o)
             (set-member? gas-bldg-tags-set (sc2-unit-order-target-unit-tag o)))
           (sc2-unit-orders w)))

  (define step-patch-role-ht (make-hasheqv))
  (define step-min-th-dist-ht (make-hasheqv))
  (for ([th (in-list townhalls)])
    (define tp (sc2-unit-pos th))
    (define tx (sc2-point3d-x tp))
    (define ty (sc2-point3d-y tp))
    (define-values (near-m far-m all-m)
      (classify-townhall-mineral-patches th mineral-fields 11.5 8))
    (for ([m (in-list all-m)])
      (define mtag (sc2-unit-tag m))
      (define mp (sc2-unit-pos m))
      (define d (pt-dist tx ty (sc2-point3d-x mp) (sc2-point3d-y mp)))
      (when (< d (hash-ref step-min-th-dist-ht mtag +inf.0))
        (hash-set! step-min-th-dist-ht mtag d)
        (hash-set! step-patch-role-ht mtag (if (memq m far-m) 'far 'near)))))

  (define (worker-patch-role w)
    (define wtag (sc2-unit-tag w))
    (define wp (sc2-unit-pos w))
    (define wx (sc2-point3d-x wp))
    (define wy (sc2-point3d-y wp))
    (define ord-tgt
      (for/first ([o (in-list (sc2-unit-orders w))]
                  #:when (memv (sc2-unit-order-ability-id o) '(166 295 298 1183 3666)))
        (sc2-unit-order-target-unit-tag o)))
    (define eff-tgt (or ord-tgt (hash-ref SC2-WORKER-PATCH-ASSIGNMENT wtag #f)))
    (cond
      [(and eff-tgt (hash-ref step-patch-role-ht eff-tgt #f))
       => values]
      [(and eff-tgt (hash-ref step-min-th-dist-ht eff-tgt #f))
       => (lambda (d) (if (>= d 6.75) 'far 'near))]
      [(not (null? townhalls))
       (define d-th
         (apply min (map (lambda (th)
                           (define tp (sc2-unit-pos th))
                           (pt-dist wx wy (sc2-point3d-x tp) (sc2-point3d-y tp)))
                         townhalls)))
       (cond
         [(and (>= d-th 6.75) (<= d-th 11.5)) 'far]
         [(and (>= d-th 3.25) (< d-th 6.75))  'near]
         [else                               'neutral])]
      [else 'neutral]))

  (define (pick-worker-near tx ty)
    (define non-scout-avail
      (filter (lambda (w)
                (define wtag (sc2-unit-tag w))
                (define wp (sc2-unit-pos w))
                (define wx (sc2-point3d-x wp))
                (define wy (sc2-point3d-y wp))
                (and (not (set-member? used-worker-tags wtag))
                     (not (set-member? builder-worker-tags wtag))
                     (not (worker-has-build-order? w cur-loop self-structures))
                     (not (set-member? step-scout-worker-tags wtag))
                     (not (worker-is-gas-harvester? w))
                     (not (and (hash? role-leases)
                               (unit-leased-above? role-leases wtag 'harvester cur-loop)))
                     (or (<= (pt-dist home-x home-y wx wy) 28.0)
                         (<= (pt-dist tx ty wx wy) 24.0))))
              workers))
    (define raw-pool
      (if (not (null? non-scout-avail))
          non-scout-avail
          (filter (lambda (w)
                    (define wtag (sc2-unit-tag w))
                    (and (not (set-member? used-worker-tags wtag))
                         (not (set-member? builder-worker-tags wtag))
                         (not (worker-has-build-order? w cur-loop self-structures))
                         (not (set-member? step-scout-worker-tags wtag))
                         (not (and (hash? role-leases)
                                   (unit-leased-above? role-leases wtag 'door-guard cur-loop)))))
                  workers)))
    (define non-carrying-pool
      (filter (lambda (w) (not (worker-carrying-cargo? w))) raw-pool))
    (define pool
      (if (null? non-carrying-pool) raw-pool non-carrying-pool))
    (if (null? pool)
        #f
        (let ([chosen
               (sc2-unit-tag
                (argmin (lambda (w)
                          (define wp (sc2-unit-pos w))
                          (define carrying? (worker-carrying-cargo? w))
                          (define gas-harv? (worker-is-gas-harvester? w))
                          (define role (worker-patch-role w))
                          (+ (pt-dist tx ty (sc2-point3d-x wp) (sc2-point3d-y wp))
                             (if (null? (sc2-unit-orders w)) 0.0 4.0)
                             (if carrying? 5000.0 0.0)
                             (if gas-harv? 500.0 0.0)
                             (cond
                               [(and (not carrying?) (eq? role 'far)) -18.0]
                               [(eq? role 'near) 14.0]
                               [else 0.0])))
                        pool))])
          (record-worker-used! chosen #t)
          (when (hash? role-leases)
            (acquire-unit-lease! role-leases chosen 'builder cur-loop 224 #:x tx #:y ty))
          chosen)))

  (define (find-open-geyser near-x near-y)
    (define gas-bldgs self-gas-bldgs)
    ;; Preserve synthetic test fixtures where neither geysers nor gas buildings populate vespene contents (`0`).
    (define resource-contents-populated?
      (or (ormap (lambda (g) (> (sc2-unit-vespene-contents g) 0)) geysers)
          (ormap (lambda (gb) (> (sc2-unit-vespene-contents gb) 0)) gas-bldgs)
          (ormap (lambda (eb) (> (sc2-unit-vespene-contents eb) 0)) enemy-gas-bldgs)))
    (define in-flight-geyser-tags
      (for*/seteqv ([w (in-list workers)]
                    [o (in-list (sc2-unit-orders w))]
                    #:when (> (sc2-unit-order-target-unit-tag o) 0))
        (sc2-unit-order-target-unit-tag o)))
    (define open-all
      (filter (lambda (g)
                (define gp (sc2-unit-pos g))
                (define gx (sc2-point3d-x gp))
                (define gy (sc2-point3d-y gp))
                (define gtag (sc2-unit-tag g))
                (and (not (set-member? used-geyser-tags gtag))
                     (not (set-member? in-flight-geyser-tags gtag))
                     (or (not resource-contents-populated?)
                         (> (sc2-unit-vespene-contents g) 0))
                     (not (ormap (lambda (gb)
                                   (define bp (sc2-unit-pos gb))
                                   (<= (pt-dist gx gy
                                                (sc2-point3d-x bp) (sc2-point3d-y bp))
                                       SC2-GEYSER-OCCUPIED-RADIUS))
                                 gas-bldgs))
                     (not (ormap (lambda (eb)
                                   (define bp (sc2-unit-pos eb))
                                   (<= (pt-dist gx gy
                                                (sc2-point3d-x bp) (sc2-point3d-y bp))
                                       SC2-GEYSER-OCCUPIED-RADIUS))
                                 enemy-gas-bldgs))
                     (not (ormap (lambda (ec)
                                   (define ep (sc2-unit-pos ec))
                                   (<= (pt-dist gx gy
                                                (sc2-point3d-x ep) (sc2-point3d-y ep))
                                       9.0))
                                 enemy-combat-for-geyser))))
              geysers))
    (define mature-ths
      (filter (lambda (th) (>= (sc2-unit-build-progress th) 0.70)) townhalls))
    (define geyser-ths (if (not (null? mature-ths)) mature-ths townhalls))
    (define open-near-th
      (if (null? geyser-ths)
          open-all
          (filter (lambda (g)
                    (define gp (sc2-unit-pos g))
                    (ormap (lambda (th)
                             (define tp (sc2-unit-pos th))
                             (<= (pt-dist (sc2-point3d-x gp) (sc2-point3d-y gp)
                                          (sc2-point3d-x tp) (sc2-point3d-y tp))
                                 SC2-BASE-RESOURCE-RADIUS))
                           geyser-ths))
                  open-all)))
    ;; Never fall back to `open-all` across the map when owned TownHalls exist!
    (define open (if (null? geyser-ths) open-all open-near-th))
    (if (null? open)
        #f
        (let ([chosen
               (argmin (lambda (g)
                         (define gp (sc2-unit-pos g))
                         (pt-dist near-x near-y (sc2-point3d-x gp) (sc2-point3d-y gp)))
                       open)])
          (set-add! used-geyser-tags (sc2-unit-tag chosen))
          chosen)))

  (define (pylon-power-anchors [near-x home-x] [near-y home-y])
    (define ps-pts
      (for/list ([ps (in-list power-sources)])
        (define p (sc2-power-source-pos ps))
        (cons (sc2-point3d-x p) (sc2-point3d-y p))))
    (define pylon-pts
      (for/list ([u (in-list completed-pylons)])
        (define p (sc2-unit-pos u))
        (cons (sc2-point3d-x p) (sc2-point3d-y p))))
    (define combined (remove-duplicates (append ps-pts pylon-pts)))
    (if (null? combined)
        '()
        (sort combined
              <
              #:key (lambda (pt) (pt-dist near-x near-y (car pt) (cdr pt))))))

  (define (pylon-power-anchor [near-x home-x] [near-y home-y])
    (define anchors (pylon-power-anchors near-x near-y))
    (if (null? anchors)
        (values near-x near-y)
        (values (caar anchors) (cdar anchors))))

  ;; Partitions Zerg creep anchors so uncontested completed TownHalls (no non-worker enemy combat unit
  ;; within 14.0 tiles) come FIRST (sorted by distance to (near-x, near-y)), followed by uncontested
  ;; completed `creep-tumor-burrowed`, falling back to contested anchors only if all bases are contested.
  (define (ordered-zerg-creep-anchors [near-x home-x] [near-y home-y])
    (define non-combat-passive-syms
      '(larva egg cocoon overlord overlord-cocoon overlord-transport
        overseer overseer-siege-mode observer observer-siege-mode
        warp-prism warp-prism-phasing medivac
        changeling changeling-zealot changeling-marine-shield
        changeling-marine changeling-zergling-wings changeling-zergling))
    (define non-worker-enemy-combat-pts
      (append
       (for/list ([eu (in-list enemy-units)]
                  #:when (let ([esym (sc2-id->unit-symbol (sc2-unit-unit-type eu))])
                           (and (not (sc2-unit-is-worker? eu))
                                (not (sc2-unit-is-structure? eu))
                                (not (memq esym non-combat-passive-syms)))))
         (define ep (sc2-unit-pos eu))
         (cons (sc2-point3d-x ep) (sc2-point3d-y ep)))
       (if (hash? obs)
           (for/list ([eh (in-list (hash-ref obs 'enemy-units '()))]
                      #:when (and (hash? eh)
                                  (real? (hash-ref eh 'x #f))
                                  (real? (hash-ref eh 'y #f))
                                  (let ([esym (hash-ref eh 'type 'unknown)])
                                    (and (not (memq esym '(drone scv probe mule)))
                                         (not (memq esym non-combat-passive-syms))))))
             (cons (exact->inexact (hash-ref eh 'x))
                   (exact->inexact (hash-ref eh 'y))))
           '())))
    (define (anchor-uncontested? ax ay)
      (for/and ([ept (in-list non-worker-enemy-combat-pts)])
        (> (pt-dist ax ay (car ept) (cdr ept)) 14.0)))
    (define (sort-by-near pts)
      (sort pts < #:key (lambda (pt) (pt-dist near-x near-y (car pt) (cdr pt)))))
    (define completed-ths
      (for/list ([u (in-list self-units)]
                 #:when (and (memq (sc2-id->unit-symbol (sc2-unit-unit-type u))
                                   '(hatchery lair hive))
                             (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)))
        (define p (sc2-unit-pos u))
        (cons (sc2-point3d-x p) (sc2-point3d-y p))))
    (define completed-tumors
      (for/list ([u (in-list self-units)]
                 #:when (and (eq? (sc2-id->unit-symbol (sc2-unit-unit-type u))
                                  'creep-tumor-burrowed)
                             (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)))
        (define p (sc2-unit-pos u))
        (cons (sc2-point3d-x p) (sc2-point3d-y p))))
    (define-values (uncontested-ths contested-ths)
      (partition (lambda (pt) (anchor-uncontested? (car pt) (cdr pt))) completed-ths))
    (define-values (uncontested-tumors contested-tumors)
      (partition (lambda (pt) (anchor-uncontested? (car pt) (cdr pt))) completed-tumors))
    (define uncontested-ordered
      (remove-duplicates
       (append (sort-by-near uncontested-ths)
               (sort-by-near uncontested-tumors))))
    (define contested-ordered
      (remove-duplicates
       (sort-by-near (append contested-ths contested-tumors))))
    (define ordered
      (remove-duplicates (append uncontested-ordered contested-ordered)))
    (if (null? ordered)
        (list (cons near-x near-y))
        ordered))

  (define (valid-non-builder-worker-tags raw-ids)
    (filter (lambda (wt)
              (define u (and (exact-integer? wt) (hash-ref self-unit-by-tag wt #f)))
              (define uh (and (exact-integer? wt) (hash-ref hash-ally-by-id wt #f)))
              (and (exact-integer? wt)
                   (> wt 0)
                   (not (set-member? builder-worker-tags wt))
                   (not (and u (worker-has-build-order? u cur-loop self-structures)))
                   (not (and uh (hash-ref uh 'has-build-order? #f)))))
            (if (list? raw-ids) raw-ids (list raw-ids))))

  ;; Checks whether unit `t` is already executing an equivalent order in `self-units`
  ;; (canonicalizing generic vs race-specific ability IDs) so we do not spam redundant orders.
  (define (unit-already-executing-order? t ab-id target-pt target-unit-id)
    (define u (hash-ref self-unit-by-tag t #f))
    (define canon-req (sc2-canonical-order-ability ab-id))
    (and u
         (pair? (sc2-unit-orders u))
         (let* ([o (first (sc2-unit-orders u))]
                [canon-cur (sc2-canonical-order-ability (sc2-unit-order-ability-id o))])
           (and (equal? canon-cur canon-req)
                (cond
                  [(> target-unit-id 0)
                   (= (sc2-unit-order-target-unit-tag o) target-unit-id)]
                  [(any-point? target-pt)
                   (define op (sc2-unit-order-target-pos o))
                   (and (any-point? op)
                        (<= (pt-dist (any-point-x target-pt) (any-point-y target-pt)
                                     (any-point-x op) (any-point-y op))
                            SC2-ORDER-EQUIV-DIST-TOLERANCE))]
                  [(memq canon-req '(hold-position stop)) #t]
                  [else #f])))))

  ;; W12-P0-3-wire (`w12-tac-1`): Pre-scan Oracles activating Pulsar Beam (2375) this step
  ;; so weaponless beam-off Oracles (`utype=495` without buff `56` and without `2375` this step)
  ;; NEVER emit suicide `ATTACK (23)` commands!
  (define step-activating-pulsar-beam-tags
    (for/seteqv ([a (in-list actions)]
                 #:when (and (pair? a)
                             (memq (car a) '(cast cast-spell))
                             (pair? (cdr a))
                             (pair? (cddr a))
                             (memq (normalize-sc2-name->symbol (caddr a))
                                   '(pulsar-beam pulsar-beam-on)))
                 [cid (in-list (let ([raw (cadr a)])
                                 (if (list? raw) raw (list raw))))]
                 #:when (and (exact-integer? cid) (> cid 0)))
      cid))
  (define (weaponless-beam-off-oracle-tag? t)
    (define u (hash-ref self-unit-by-tag t #f))
    (and u
         (= (sc2-unit-unit-type u) 495)
         (not (memv 56 (sc2-unit-buff-ids u)))
         (not (set-member? step-activating-pulsar-beam-tags t))))

  ;; Filters a list of combat unit tags:
  ;;   1. Skips tags already commanded earlier in this step (`commanded-combat-tags`).
  ;;   2. Skips units with protected active morph/channel/mode-switch/cast-walk orders or higher role leases.
  ;;   3. Marks remaining tags as commanded so lower-priority maneuvers cannot overwrite them.
  ;;   4. Skips re-issuing an order that is already active on the unit in SC2.
  (define (claim-combat-tags-for-order! raw-ids ab-id target-pt target-unit-id)
    (define candidates
      (filter (lambda (t)
                (define u (and (exact-integer? t) (hash-ref self-unit-by-tag t #f)))
                (and (exact-integer? t)
                     (> t 0)
                     (not (and (= ab-id 23) (weaponless-beam-off-oracle-tag? t)))
                     (not (set-member? commanded-combat-tags t))
                     (not (set-member? used-producer-tags t))
                     (not (set-member? used-worker-tags t))
                     (not (and u (sc2-unit-is-worker? u) (worker-has-build-order? u cur-loop self-structures)))
                     (not (unit-has-protected-order? t))
                     (not (and (hash? role-leases)
                               (unit-leased-above? role-leases t 'army cur-loop)))))
              (if (list? raw-ids) raw-ids (list raw-ids))))
    (for/list ([t (in-list candidates)]
               #:when (begin
                        (set-add! commanded-combat-tags t)
                        (not (unit-already-executing-order? t ab-id target-pt target-unit-id))))
      t))

  (define (rebuild-all-control-grouped-tags)
    (define ht (unbox SC2-CONTROL-GROUPED-TAGS))
    (for/fold ([acc (seteqv)]) ([(_g s) (in-hash ht)])
      (set-union acc s)))
  (define all-control-grouped-tags (rebuild-all-control-grouped-tags))
  (define (control-grouped-tag? tag)
    (set-member? all-control-grouped-tags tag))
  (define (update-control-grouped-tags! op g raw-tags)
    (when (exact-integer? g)
      (define tags
        (for/list ([t (in-list (if (list? raw-tags) raw-tags (list raw-tags)))]
                   #:when (and (exact-integer? t) (> t 0)))
          t))
      (define tset (list->seteqv tags))
      (define cur (unbox SC2-CONTROL-GROUPED-TAGS))
      (case op
        [(control-group-set)
         (set-box! SC2-CONTROL-GROUPED-TAGS (hash-set cur g tset))]
        [(control-group-append)
         (set-box! SC2-CONTROL-GROUPED-TAGS
                   (hash-set cur g (set-union (hash-ref cur g (seteqv)) tset)))]
        [(control-group-steal)
         (define stripped
           (for/hasheqv ([(kg vs) (in-hash cur)])
             (values kg (if (= kg g) tset (set-subtract vs tset)))))
         (set-box! SC2-CONTROL-GROUPED-TAGS (hash-set stripped g tset))]
        [(control-group-append-steal)
         (define merged (set-union (hash-ref cur g (seteqv)) tset))
         (define stripped
           (for/hasheqv ([(kg vs) (in-hash cur)])
             (values kg (if (= kg g) merged (set-subtract vs tset)))))
         (set-box! SC2-CONTROL-GROUPED-TAGS (hash-set stripped g merged))]
        [else (void)])
      (set! all-control-grouped-tags (rebuild-all-control-grouped-tags))))
  (define raw-cmds '())
  (define step-obs-cam-pt
    (let ([cam (and (sc2-observation? obs) (sc2-observation-camera obs))])
      (and (sc2-point3d? cam)
           (finite-world-coord? (sc2-point3d-x cam))
           (finite-world-coord? (sc2-point3d-y cam))
           (or (> (sc2-point3d-x cam) 0.5) (> (sc2-point3d-y cam) 0.5))
           (cons (exact->inexact (sc2-point3d-x cam))
                 (exact->inexact (sc2-point3d-y cam))))))
  (define (maybe-emit-framing-cam-before! cmd)
    (when (sc2-raw-unit-command? cmd)
      (define ab (sc2-raw-unit-command-ability-id cmd))
      (define macro-ab?
        (memv ab '(314 556 558 1216 1218 1450 1452 1518 1520 1768 3678 3679)))
      (define ungrouped-tag
        (and (not macro-ab?)
             (for/or ([t (in-list (sc2-raw-unit-command-unit-tags cmd))])
               (and (not (control-grouped-tag? t))
                    (let ([u (hash-ref self-unit-by-tag t #f)])
                      (if u
                          (and (not (sc2-unit-is-structure? u)) t)
                          (and (sc2-raw-unit-command-target-pos cmd) t)))))))
      (when ungrouped-tag
        (define focus-pt
          (let ([u (hash-ref self-unit-by-tag ungrouped-tag #f)])
            (cond
              [u
               (let ([p (sc2-unit-pos u)])
                 (cons (sc2-point3d-x p) (sc2-point3d-y p)))]
              [(any-point? (sc2-raw-unit-command-target-pos cmd))
               (let ([tp (sc2-raw-unit-command-target-pos cmd)])
                 (cons (any-point-x tp) (any-point-y tp)))]
              [else #f])))
        (when focus-pt
          (define fx (car focus-pt))
          (define fy (cdr focus-pt))
          (define ref-cam-pt
            (cond
              [(pair? last-cam-pt) last-cam-pt]
              [(and (real? (unbox SC2-TRANS-LAST-CAM-X))
                    (real? (unbox SC2-TRANS-LAST-CAM-Y))
                    (<= (- cur-loop (unbox SC2-TRANS-LAST-CAM-LOOP)) 6))
               (cons (unbox SC2-TRANS-LAST-CAM-X) (unbox SC2-TRANS-LAST-CAM-Y))]
              [(and (real? (unbox SC2-GOV-LAST-CAM-X))
                    (real? (unbox SC2-GOV-LAST-CAM-Y)))
               (cons (unbox SC2-GOV-LAST-CAM-X) (unbox SC2-GOV-LAST-CAM-Y))]
              [step-obs-cam-pt step-obs-cam-pt]
              [(and (real? (unbox SC2-TRANS-LAST-CAM-X))
                    (real? (unbox SC2-TRANS-LAST-CAM-Y)))
               (cons (unbox SC2-TRANS-LAST-CAM-X) (unbox SC2-TRANS-LAST-CAM-Y))]
              [(not (null? townhalls)) (cons home-x home-y)]
              [else #f]))
          (define ref-cam-x (and ref-cam-pt (car ref-cam-pt)))
          (define ref-cam-y (and ref-cam-pt (cdr ref-cam-pt)))
          (when (and ref-cam-x
                     ref-cam-y
                     (or (> (abs (- fx ref-cam-x)) 12.0)
                         (> (abs (- fy ref-cam-y)) 9.0)))
            (define jump-from-gov
              (if (and (real? (unbox SC2-GOV-LAST-CAM-X))
                       (real? (unbox SC2-GOV-LAST-CAM-Y)))
                  (pt-dist fx fy (unbox SC2-GOV-LAST-CAM-X) (unbox SC2-GOV-LAST-CAM-Y))
                  (pt-dist fx fy ref-cam-x ref-cam-y)))
            (define cam-cmd
              (mark-framing-camera-cmd! (sc2-raw-camera-move fx fy 0.0) jump-from-gov))
            (hash-set! SC2-CMD-FRAMING-CAM cmd cam-cmd)
            (set! last-cam-pt (cons fx fy))
            (set-box! SC2-TRANS-LAST-CAM-X fx)
            (set-box! SC2-TRANS-LAST-CAM-Y fy)
            (set-box! SC2-TRANS-LAST-CAM-LOOP cur-loop)
            (set! raw-cmds (cons cam-cmd raw-cmds)))))))
  (define (emit! cmd)
    (when cmd
      (maybe-emit-framing-cam-before! cmd)
      (set! raw-cmds (cons cmd raw-cmds))))

  ;; W9-TAC-3 & W9-TAC-4: Per-step deduplication for Orbital Scanner Sweep (399) and Overseer Spawn Changeling (181)
  (define emitted-scan-oc-tags (mutable-seteqv))
  (define emitted-scan-pts '())
  (define (emit-scanner-sweep-deduped! oc-tags tx ty)
    (define fresh-ocs
      (filter (lambda (t) (and (exact-integer? t) (> t 0) (not (set-member? emitted-scan-oc-tags t))))
              (if (list? oc-tags) oc-tags (list oc-tags))))
    (define near-existing-scan?
      (ormap (lambda (pt)
               (define dx (- tx (car pt)))
               (define dy (- ty (cdr pt)))
               (and (<= (abs dx) 10.0) (<= (abs dy) 10.0)
                    (<= (+ (* dx dx) (* dy dy)) 100.0)))
             emitted-scan-pts))
    (when (and (pair? fresh-ocs) (not near-existing-scan?))
      (define chosen-oc (first fresh-ocs))
      (set-add! emitted-scan-oc-tags chosen-oc)
      (set! emitted-scan-pts (cons (cons tx ty) emitted-scan-pts))
      (emit! (sc2-raw-unit-command 399 (sc2-point2d tx ty) 0 (list chosen-oc) #f))))

  (define emitted-changeling-tags (mutable-seteqv))
  ;; W11-P0-4-wire (`w11-tac-4`): Active uncovered cloaked (`cloak=1`) or undetected burrowed
  ;; combat threats (excluding Creep Tumors / Larva) demand mobile detector flight — NEVER
  ;; freeze Overseers/Observers in Oversight/Siege mode (3745/3741) or waste an Overseer's turn
  ;; on Spawn Changeling (181) while an active stealth threat is uncovered!
  (define ally-detector-units
    (filter (lambda (u)
              (and (memv (sc2-unit-unit-type u) '(82 1911 129 1912 56 23 66 99))
                   (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)
                   (not (sc2-unit-is-hallucination u))
                   (not (= (sc2-unit-display-type u) 4))))
            self-units))
  (define (enemy-covered-by-ally-detector? e)
    (or (= (sc2-unit-cloak e) 2)
        (and (not (= (sc2-unit-cloak e) 1))
             (let* ([ep (sc2-unit-pos e)]
                    [ex (sc2-point3d-x ep)]
                    [ey (sc2-point3d-y ep)])
               (ormap (lambda (d)
                        (define dp (sc2-unit-pos d))
                        (define dx (- ex (sc2-point3d-x dp)))
                        (define dy (- ey (sc2-point3d-y dp)))
                        (and (<= (abs dx) 10.5) (<= (abs dy) 10.5)
                             (<= (+ (* dx dx) (* dy dy)) 110.25)))
                      ally-detector-units)))))
  (define uncovered-stealth-enemies
    (filter (lambda (e)
              (define etype (sc2-unit-unit-type e))
              (and (not (= (sc2-unit-display-type e) 4))
                   (not (memv etype '(87 137 151)))
                   (or (= (sc2-unit-cloak e) 1)
                       (and (sc2-unit-is-burrowed e)
                            (not (enemy-covered-by-ally-detector? e))))))
            enemy-units))
  (define uncovered-stealth-present? (pair? uncovered-stealth-enemies))

  (define (emit-spawn-changeling-deduped! overseer-tags)
    (unless uncovered-stealth-present?
      (define fresh-os
        (filter (lambda (t) (and (exact-integer? t) (> t 0) (not (set-member? emitted-changeling-tags t))))
                (if (list? overseer-tags) overseer-tags (list overseer-tags))))
      (when (pair? fresh-os)
        (for ([t (in-list fresh-os)])
          (set-add! emitted-changeling-tags t)
          (record-unit-used! t))
        (emit! (sc2-raw-unit-command 181 #f 0 fresh-os #f)))))

  ;; W12-P0-3-wire (`w12-tac-1..4`): Defense-in-depth per-step deduplication & buff hygiene for
  ;; Oracle Revelation (2146, buff=49), Cyclone Lock-On (2350, buff=116), Viking morph (403/405),
  ;; Void Ray Prismatic Alignment (2393), and Reaper KD8 Charge (2588).
  (define emitted-revelation-tags (mutable-seteqv))
  (define emitted-revelation-pts '())
  (define (emit-oracle-revelation-deduped! oracle-tags tx ty)
    (define fresh-oracles
      (filter (lambda (t) (and (exact-integer? t) (> t 0) (not (set-member? emitted-revelation-tags t))))
              (if (list? oracle-tags) oracle-tags (list oracle-tags))))
    (define near-existing-rev?
      (ormap (lambda (pt)
               (define dx (- tx (car pt)))
               (define dy (- ty (cdr pt)))
               (and (<= (abs dx) 6.0) (<= (abs dy) 6.0)
                    (<= (+ (* dx dx) (* dy dy)) 36.0)))
             emitted-revelation-pts))
    (define enemies-in-rev-aoe
      (filter (lambda (e)
                (define ep (sc2-unit-pos e))
                (define dx (- tx (sc2-point3d-x ep)))
                (define dy (- ty (sc2-point3d-y ep)))
                (and (not (= (sc2-unit-display-type e) 4))
                     (<= (abs dx) 6.5) (<= (abs dy) 6.5)
                     (<= (+ (* dx dx) (* dy dy)) 42.25)))
              enemy-units))
    (define all-near-already-revealed?
      (and (pair? enemies-in-rev-aoe)
           (andmap (lambda (e) (and (memv 49 (sc2-unit-buff-ids e)) #t))
                   enemies-in-rev-aoe)))
    (when (and (pair? fresh-oracles) (not near-existing-rev?) (not all-near-already-revealed?))
      (define chosen-o (first fresh-oracles))
      (set-add! emitted-revelation-tags chosen-o)
      (set-add! commanded-combat-tags chosen-o)
      (set! emitted-revelation-pts (cons (cons tx ty) emitted-revelation-pts))
      (emit! (sc2-raw-unit-command 2146 (sc2-point2d tx ty) 0 (list chosen-o) #f))))

  (define emitted-lockon-caster-tags (mutable-seteqv))
  (define emitted-lockon-target-tags (mutable-seteqv))
  (define (emit-cyclone-lock-on-deduped! cyclone-tags target-id)
    (define tu (hash-ref all-unit-by-tag target-id #f))
    (define already-locked?
      (or (set-member? emitted-lockon-target-tags target-id)
          (and tu (memv 116 (sc2-unit-buff-ids tu)) #t)))
    (define fresh-cs
      (filter (lambda (t) (and (exact-integer? t) (> t 0) (not (set-member? emitted-lockon-caster-tags t))))
              (if (list? cyclone-tags) cyclone-tags (list cyclone-tags))))
    (when (and (> target-id 0) (not already-locked?) (pair? fresh-cs))
      (define chosen-c (first fresh-cs))
      (set-add! emitted-lockon-caster-tags chosen-c)
      (set-add! emitted-lockon-target-tags target-id)
      (set-add! commanded-combat-tags chosen-c)
      (emit! (sc2-raw-unit-command 2350 #f target-id (list chosen-c) #f))))

  (define emitted-viking-morph-tags (mutable-seteqv))
  (define (emit-viking-morph-deduped! ab-id raw-tags)
    (define fresh-vs
      (filter (lambda (t)
                (define vu (hash-ref self-unit-by-tag t #f))
                (and (exact-integer? t) (> t 0)
                     (not (set-member? emitted-viking-morph-tags t))
                     (or (not vu)
                         (not (or (and (= ab-id 405) (= (sc2-unit-unit-type vu) 35))
                                  (and (= ab-id 403) (= (sc2-unit-unit-type vu) 34)))))))
              (if (list? raw-tags) raw-tags (list raw-tags))))
    (when (pair? fresh-vs)
      (for ([t (in-list fresh-vs)])
        (set-add! emitted-viking-morph-tags t)
        (set-add! commanded-combat-tags t))
      (emit! (sc2-raw-unit-command ab-id #f 0 fresh-vs #f))))

  (define emitted-prismatic-tags (mutable-seteqv))
  (define emitted-kd8-tags (mutable-seteqv))

  ;; W9-TAC-5-wire: Never cancel a unit actively channeling Steady Targeting (2714) or another
  ;; protected `'channel` spell via LOAD_TRANSPORT (3668/394/911/1406) unless an enemy combat
  ;; unit sits in immediate melee danger (<= 2.5t, sq-dist <= 6.25).
  (define (passenger-protected-channeling-safe? ptag)
    (define pu (hash-ref self-unit-by-tag ptag #f))
    (and pu
         (pair? (sc2-unit-orders pu))
         (let ([ab (sc2-unit-order-ability-id (first (sc2-unit-orders pu)))])
           (or (= ab 2714)
               (eq? (sc2-order-protection-class ab) 'channel)))
         (let* ([pp (sc2-unit-pos pu)]
                [px (sc2-point3d-x pp)]
                [py (sc2-point3d-y pp)])
           (not (ormap (lambda (e)
                         (and (sc2-unit-targetable-enemy-combat? e)
                              (let* ([ep (sc2-unit-pos e)]
                                     [dx (- px (sc2-point3d-x ep))]
                                     [dy (- py (sc2-point3d-y ep))])
                                (and (<= (abs dx) 2.5) (<= (abs dy) 2.5)
                                     (<= (+ (* dx dx) (* dy dy)) 6.25)))))
                       enemy-units)))))

  ;; W10-TAC-3: Resolve race-specific UNLOAD_ALL_AT ability ID (SC2 4.10.0 ignores generic 3669!)
  ;; and verify the transport carries cargo when live cargo metadata (`cargo-space-max > 0`) is present.
  (define (transport-unload-ability-id tr-u)
    (define tr-utype (if tr-u (sc2-unit-unit-type tr-u) 0))
    (cond
      [(= tr-utype 54) 396]
      [(or (= tr-utype 81) (= tr-utype 136)) 913]
      [(= tr-utype 893) 1408]
      [else 3669]))
  (define (transport-has-cargo-to-unload? tr-u)
    (or (not tr-u)
        (and (<= (sc2-unit-cargo-space-max tr-u) 0) (null? (sc2-unit-passengers tr-u)))
        (> (sc2-unit-cargo-space-taken tr-u) 0)
        (pair? (sc2-unit-passengers tr-u))))

  ;; W10-TAC-6: Detect visible cloaked/burrowed enemies or known cloak/burrow threat units/structures
  ;; so detectors (Observer 82 / Overseer 129) are NEVER sent cross-map away from defense!
  (define cloaked-or-burrowed-threat-present?
    (or (and (hash? obs)
             (or (eq? (hash-ref obs 'requires-detection? #f) #t)
                 (eq? (hash-ref obs 'visible-cloaked-or-burrowed-enemy? #f) #t)
                 (eq? (hash-ref obs 'enemy-cloaked-threat? #f) #t)))
        (ormap (lambda (e)
                 (define esym (sc2-id->unit-symbol (sc2-unit-unit-type e) 'unknown))
                 (or (memv (sc2-unit-cloak e) '(1 2))
                     (sc2-unit-is-burrowed e)
                     (memq esym '(dark-templar dark-shrine banshee ghost
                                  widow-mine widow-mine-burrowed
                                  lurker lurker-mp lurker-burrowed lurker-mp-burrowed
                                  lurker-den lurker-den-mp))))
               enemy-units)))

  (define (maybe-emit-corner-scan! corner-pts)
    (when (and (>= cur-loop 6000)
               (null? enemy-units)
               (pair? corner-pts)
               (>= (- cur-loop (unbox SC2-CORNER-SCAN-LAST-LOOP)) 160))
      (define ready-oc
        (findf (lambda (u)
                 (define utag (sc2-unit-tag u))
                 (and (= (sc2-unit-unit-type u) 132) ;; orbital-command
                      (not (sc2-unit-is-flying u))
                      (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)
                      (>= (sc2-unit-energy u) 100.0)
                      (not (set-member? emitted-scan-oc-tags utag))
                      (not (ormap (lambda (c)
                                    (and (sc2-raw-unit-command? c)
                                         (memv (sc2-raw-unit-command-ability-id c) '(171 259 399))
                                         (memv utag (sc2-raw-unit-command-unit-tags c))))
                                  raw-cmds))))
               self-units))
      (when ready-oc
        (define cpt (first corner-pts))
        (define cx (car cpt))
        (define cy (cdr cpt))
        (set-box! SC2-CORNER-SCAN-LAST-LOOP cur-loop)
        (set-box! SC2-CLEARED-ENEMY-BASES
                  (cons (cons cx cy) (unbox SC2-CLEARED-ENEMY-BASES)))
        (emit-scanner-sweep-deduped! (sc2-unit-tag ready-oc) cx cy))))

  (define (emit-unroot-for-push! unit-list)
    (define sieged-tank-tags
      (for/list ([u (in-list unit-list)]
                 #:when (= (sc2-unit-unit-type u) 32))
        (set-add! commanded-combat-tags (sc2-unit-tag u))
        (sc2-unit-tag u)))
    (when (not (null? sieged-tank-tags))
      (emit! (sc2-raw-unit-command 390 #f 0 sieged-tank-tags #f)))
    (define burrowed-lurker-tags
      (for/list ([u (in-list unit-list)]
                 #:when (= (sc2-unit-unit-type u) 503))
        (set-add! commanded-combat-tags (sc2-unit-tag u))
        (sc2-unit-tag u)))
    (when (not (null? burrowed-lurker-tags))
      (emit! (sc2-raw-unit-command 2110 #f 0 burrowed-lurker-tags #f)))
    (define burrowed-mine-tags
      (for/list ([u (in-list unit-list)]
                 #:when (= (sc2-unit-unit-type u) 500))
        (set-add! commanded-combat-tags (sc2-unit-tag u))
        (sc2-unit-tag u)))
    (when (not (null? burrowed-mine-tags))
      (emit! (sc2-raw-unit-command 2097 #f 0 burrowed-mine-tags #f))))

  (define (emit-fan-out-sweep! unit-list eb-x eb-y)
    (define-values (top-wps flyer-wps corner-wps)
      (compute-endgame-sweep-plan eb-x eb-y))
    (maybe-emit-corner-scan! corner-wps)
    (when (and (pair? unit-list) (pair? top-wps))
      (emit-unroot-for-push! unit-list)
      (define mobile-units
        (filter (lambda (u) (not (memv (sc2-unit-unit-type u) '(32 500 503))))
                unit-list))
      (define bucket-order '())
      (define bucket-tags (make-hash))
      (for ([u (in-list mobile-units)])
        (define utag (sc2-unit-tag u))
        (define usym (sc2-id->unit-symbol (sc2-unit-unit-type u)))
        (define use-flyer-pool?
          (and (sc2-unit-is-flying u)
               (pair? flyer-wps)
               (not (memq usym '(medivac warp-prism overlord overlord-transport)))))
        (define pool (if use-flyer-pool? flyer-wps top-wps))
        (define wp (list-ref pool (modulo utag (length pool))))
        (define wx (car wp))
        (define wy (cdr wp))
        (define already-en-route?
          (and (pair? (sc2-unit-orders u))
               (let* ([o (first (sc2-unit-orders u))]
                      [ab (sc2-unit-order-ability-id o)]
                      [tp (sc2-unit-order-target-pos o)])
                 (and (eq? (sc2-canonical-order-ability ab) 'attack)
                      (any-point? tp)
                      (<= (pt-dist wx wy (any-point-x tp) (any-point-y tp)) 8.0)))))
        (cond
          [already-en-route?
           (set-add! commanded-combat-tags utag)]
          [else
           (unless (hash-has-key? bucket-tags wp)
             (set! bucket-order (cons wp bucket-order)))
           (hash-set! bucket-tags wp (cons utag (hash-ref bucket-tags wp '())))]))
      (for ([wp (in-list (reverse bucket-order))])
        (define target-pt (sc2-point2d (car wp) (cdr wp)))
        (define raw-btags (reverse (hash-ref bucket-tags wp '())))
        (define ctags (claim-combat-tags-for-order! raw-btags 23 target-pt 0))
        (when (not (null? ctags))
          (emit! (sc2-raw-unit-command 23 target-pt 0 ctags #f))))))

  (define (emit-camera-move! raw-x raw-y)
    (define cx (scale-bot-coord-to-world raw-x home-x))
    (define cy (scale-bot-coord-to-world raw-y home-y))
    (when (or (not last-cam-pt)
              (> (pt-dist cx cy (car last-cam-pt) (cdr last-cam-pt))
                 SC2-CAMERA-MOVE-DEDUP-DIST))
      (set! last-cam-pt (cons cx cy))
      (set-box! SC2-TRANS-LAST-CAM-X cx)
      (set-box! SC2-TRANS-LAST-CAM-Y cy)
      (set-box! SC2-TRANS-LAST-CAM-LOOP cur-loop)
      (emit! (sc2-raw-camera-move cx cy 0.0))))

  ;; Partition actions so that:
  ;;   1. Emergency/macro structure builds, cancels, and bunker-loads execute FIRST (W12-P0-3-wire:
  ;;      STRICTLY before `pull-workers-attack` / `worker-drill-stack-attack` / `mineral-walk`, so an
  ;;      active 12-Pool worker pull NEVER starves an emergency Pylon/SupplyDepot/Bunker/Battery/Spine
  ;;      of a builder worker while leaving all remaining N-1 workers free to fight!),
  ;;   2. Worker defense pulls, harass, and priority tactical actions execute second,
  ;;   3. Morphs and standard production, upgrade, micro, and spatial maneuvers execute third,
  ;;   4. Post-combat recon/patrol executes fourth, and routine harvest executes last.
  ;; W16-P1-2-wire: Sub-order `build-priority-action?` so urgent control (`cancel`/`bunker-load`),
  ;; supply (`pylon`/`supply-depot`), TownHalls (`expand`), and core production (`barracks`/`gateway`/
  ;; `factory`/`starport`/`spawning-pool`) ALWAYS claim the 2-RPC/step placement budget ahead of
  ;; secondary structures (`bunker`/`engineering-bay`/`missile-turret`/addons/tech buildings).
  (define (build-urgent-control-action? a)
    (and (pair? a)
         (memq (car a)
               '(cancel cancel-building salvage salvage-bunker bunker-load
                 resume-halted-building push-probe-with-building))))
  (define (build-core-macro-action? a)
    (and (pair? a)
         (or (eq? (car a) 'expand)
             (and (eq? (car a) 'build)
                  (pair? (cdr a))
                  (memq (normalize-sc2-name->symbol (cadr a))
                        '(pylon supply-depot
                          command-center nexus hatchery
                          orbital-command planetary-fortress lair hive
                          barracks gateway factory starport spawning-pool))))))
  (define (build-priority-action? a)
    (and (pair? a)
         (memq (car a)
               '(build build-nydus-worm expand resume-halted-building
                 push-probe-with-building cancel cancel-building salvage salvage-bunker bunker-load))))
  (define (build-secondary-action? a)
    (and (build-priority-action? a)
         (not (build-urgent-control-action? a))
         (not (build-core-macro-action? a))))
  (define (priority-first-action? a)
    (and (pair? a)
         (memq (car a)
               '(baneling-explode
                 overlord-scout
                 mineral-harass worker-harass
                 burrow-block clear-expansion-block
                 pull-workers-attack worker-drill-stack-attack mineral-walk))))
  (define (morph-action? a)
    (and (pair? a) (eq? (car a) 'morph)))
  ;; W6-TAC-4-wire / W8-P0-4-wire: Expansion patrol, cross-map scouting, harass, and deception spells
  ;; run AFTER standard combat / bunker-load / spell orders (never preempting fighting or defending units)
  ;; and BEFORE routine worker harvest.
  (define (post-combat-recon-action? a)
    (and (pair? a)
         (memq (car a)
               '(patrol-block-expansion
                 worker-scout periodic-scout scout-sector
                 harass-workers
                 cast-deception-and-scout-spells))))
  (define (routine-harvest-action? a)
    (and (pair? a)
         (memq (car a) '(harvest-mineral harvest-gas rebalance-gas-to-minerals))))
  (define ordered-actions
    (append (filter build-urgent-control-action? actions)
            (filter build-core-macro-action? actions)
            (filter build-secondary-action? actions)
            (filter priority-first-action? actions)
            (filter morph-action? actions)
            (filter (lambda (a)
                      (and (not (build-priority-action? a))
                           (not (priority-first-action? a))
                           (not (morph-action? a))
                           (not (post-combat-recon-action? a))
                           (not (routine-harvest-action? a))))
                    actions)
            (filter post-combat-recon-action? actions)
            (filter routine-harvest-action? actions)))

  ;; W5-P0-1a-wire: Reserve 1 safe idle Hatchery (for Lair) or Lair (for Hive) against `(train queen)`
  ;; whenever Lair/Hive is requested this step or within the last 64 loops (and not yet built/morphing),
  ;; so continuous Queen training NEVER starves Lair/Hive indefinitely!
  (define active-zerg-th-morph-reserve
    (let* ([entry (unbox SC2-ZERG-TH-MORPH-RESERVE-LOOP)]
           [res-sym
            (cond
              [step-wants-lair? 'lair]
              [step-wants-hive? 'hive]
              [(and (pair? entry)
                    (>= cur-loop (cdr entry))
                    (< (- cur-loop (cdr entry)) SC2-PLACEMENT-CACHE-TTL))
               (car entry)]
              [else #f])])
      (cond
        [(eq? res-sym 'lair)
         (define has-or-morphing-lair?
           (or (pair? (hash-ref self-units-by-sym 'lair '()))
               (pair? (hash-ref self-units-by-sym 'hive '()))
               (ormap (lambda (u)
                        (ormap (lambda (o) (= (sc2-unit-order-ability-id o) 1216))
                               (sc2-unit-orders u)))
                      (hash-ref self-units-by-sym 'hatchery '()))))
         (if has-or-morphing-lair?
             (begin (set-box! SC2-ZERG-TH-MORPH-RESERVE-LOOP #f) #f)
             'lair)]
        [(eq? res-sym 'hive)
         (define has-or-morphing-hive?
           (or (pair? (hash-ref self-units-by-sym 'hive '()))
               (ormap (lambda (u)
                        (ormap (lambda (o) (= (sc2-unit-order-ability-id o) 1218))
                               (sc2-unit-orders u)))
                      (hash-ref self-units-by-sym 'lair '()))))
         (if has-or-morphing-hive?
             (begin (set-box! SC2-ZERG-TH-MORPH-RESERVE-LOOP #f) #f)
             'hive)]
        [else #f])))

  (for ([act (in-list ordered-actions)])
    (cond
      ;; Fast-path O(1) dispatch for high-frequency per-unit `attack` / `attack-unit` actions
      ;; (avoids scanning 15+ complex `match` clauses on 130+ micro actions per late-game step)
      [(and (pair? act)
            (memq (car act) '(attack attack-unit))
            (pair? (cdr act))
            (pair? (cddr act))
            (null? (cdddr act))
            (let ([uid (cadr act)] [target-id (caddr act)])
              (and (or (exact-integer? uid) (list? uid))
                   (exact-integer? target-id))))
       (define uid (cadr act))
       (define target-id (caddr act))
       (cond
         [(or (not enforce-live-enemy-tag-filter?)
              (set-member? live-visible-enemy-tags target-id))
          (define tag-list (claim-combat-tags-for-order! uid 23 #f target-id))
          (when (not (null? tag-list))
            (define raw-atk (sc2-raw-unit-command 23 #f target-id tag-list #f))
            (emit! (if (set-member? enemy-near-own-base-tags target-id)
                       (mark-urgent-survival-cmd! raw-atk)
                       raw-atk)))]
         [else
          (define cached-pt (hash-ref SC2-LAST-KNOWN-ENEMY-POS target-id #f))
          (define fallback-pt
            (if (pair? cached-pt)
                (sc2-point2d (car cached-pt) (cdr cached-pt))
                (sc2-point2d default-eb-x default-eb-y)))
          (define tag-list (claim-combat-tags-for-order! uid 23 fallback-pt 0))
          (when (not (null? tag-list))
            (emit! (sc2-raw-unit-command 23 fallback-pt 0 tag-list #f)))])]
      [else
    (match act
      ;; 1. Train unit: `(train <unit-sym>)` or `(train-unit <prod-id> <unit-sym>)`
      [(or (list 'train unit-sym)
           (list 'train-unit _ unit-sym))
       (define explicit-prod-id (and (eq? (car act) 'train-unit) (second act)))
       (define norm-train-sym (normalize-sc2-name->symbol unit-sym))
       (define ab-id (train-symbol->ability-id unit-sym))
       (define all-prod-tags (select-producer-tags-for-unit unit-sym self-units enemy-units #:units-by-sym self-units-by-sym))
       (define zerg-combat-morph? (not (not (memq norm-train-sym SC2-ZERG-COMBAT-MORPH-SYMS))))
       (define raw-prod-tags
         (filter (lambda (t)
                   (and (< (hash-ref used-producer-counts t 0)
                           (count (lambda (x) (= x t)) all-prod-tags))
                        (or (not zerg-combat-morph?)
                            (not (set-member? commanded-combat-tags t)))))
                 all-prod-tags))
       (define prod-tags
         (cond
           [(and (eq? norm-train-sym 'queen)
                 (eq? active-zerg-th-morph-reserve 'lair))
            (define idle-hatch-tags
              (filter (lambda (t)
                        (define u (hash-ref self-unit-by-tag t #f))
                        (and u (eq? (sc2-id->unit-symbol (sc2-unit-unit-type u)) 'hatchery)))
                      raw-prod-tags))
            (define non-hatch-tags
              (filter (lambda (t) (not (memv t idle-hatch-tags))) raw-prod-tags))
            (cond
              [(pair? non-hatch-tags) non-hatch-tags]
              [(<= (length idle-hatch-tags) 1) '()] ;; preserve the last idle Hatchery for Lair morph!
              [else
               ;; Keep the Hatchery closest to home-x/home-y free for Lair, train Queen on another Hatchery
               (define sorted-h
                 (sort idle-hatch-tags <
                       #:key (lambda (t)
                               (define p (sc2-unit-pos (hash-ref self-unit-by-tag t)))
                               (pt-dist home-x home-y (sc2-point3d-x p) (sc2-point3d-y p)))))
               (cdr sorted-h)])]
           [(and (eq? norm-train-sym 'queen)
                 (eq? active-zerg-th-morph-reserve 'hive))
            (define idle-lair-tags
              (filter (lambda (t)
                        (define u (hash-ref self-unit-by-tag t #f))
                        (and u (eq? (sc2-id->unit-symbol (sc2-unit-unit-type u)) 'lair)))
                      raw-prod-tags))
            (define non-lair-tags
              (filter (lambda (t) (not (memv t idle-lair-tags))) raw-prod-tags))
            (cond
              [(pair? non-lair-tags) non-lair-tags]
              [(<= (length idle-lair-tags) 1) '()]
              [else (cdr idle-lair-tags)])]
           [else raw-prod-tags]))
       (when (and ab-id (not (null? prod-tags)))
         (define ptag
           (if (and (exact-integer? explicit-prod-id)
                    (memv explicit-prod-id prod-tags))
               explicit-prod-id
               (first prod-tags)))
         (hash-set! used-producer-counts ptag (add1 (hash-ref used-producer-counts ptag 0)))
         (set-add! used-producer-tags ptag)
         (when zerg-combat-morph?
           (set-add! commanded-combat-tags ptag))
         (define prod-u (hash-ref self-unit-by-tag ptag #f))
         ;; Bug #17 fix: if producer is a WarpGate (133), issue WARP_IN_* at an open Pylon power-field point
         ;; (never pass unit warp-in ability IDs 1413..1419 to RequestQueryBuildingPlacement, which rejects non-buildings
         ;; and falls back to the Pylon center!)
         (cond
           [(and prod-u (= (sc2-unit-unit-type prod-u) 133))
            ;; W11-P0-3-wire: Accurate WarpGate cooldown (respecting Chronoboost buff 281),
            ;; radius-aware power anchors (Pylon 6.5 vs Phasing WarpPrism 3.75), grid-verified
            ;; pathable/buildable polar ring search, and non-overlapping multi-gate batching!
            (define base-wg-cd-loops
              (case (normalize-sc2-name->symbol unit-sym)
                [(zealot adept)               448]
                [(stalker sentry)             515]
                [(high-templar dark-templar)  717]
                [else                         515]))
            (define wg-cd-loops
              (if (memv 281 (sc2-unit-buff-ids prod-u))
                  (inexact->exact (round (* base-wg-cd-loops 2/3)))
                  base-wg-cd-loops))
            (when (and (sc2-observation? obs) (> (sc2-observation-game-loop obs) 0))
              (set-box! SC2-WARPGATE-LAST-LOOP (sc2-observation-game-loop obs))
              (hash-set! SC2-WARPGATE-COOLDOWN-UNTIL ptag
                         (+ (sc2-observation-game-loop obs) wg-cd-loops)))
            (define warp-ab (or (unit-symbol->warp-in-ability-id unit-sym) ab-id))
            (define raw-warp-anchors
              (append
               (for/list ([ps (in-list power-sources)]
                          #:when (> (sc2-power-source-radius ps) 1.5))
                 (define p (sc2-power-source-pos ps))
                 (list (sc2-point3d-x p) (sc2-point3d-y p) (exact->inexact (sc2-power-source-radius ps))))
               (for/list ([u (in-list completed-pylons)])
                 (define p (sc2-unit-pos u))
                 (list (sc2-point3d-x p) (sc2-point3d-y p) 6.5))
               (for/list ([u (in-list self-units)]
                          #:when (and (= (sc2-unit-unit-type u) 136) ;; WarpPrism Phasing
                                      (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)))
                 (define p (sc2-unit-pos u))
                 (list (sc2-point3d-x p) (sc2-point3d-y p) 3.75))))
            (define deduped-warp-anchors
              (for/fold ([acc '()] #:result (reverse acc))
                        ([a (in-list raw-warp-anchors)])
                (define ax (first a))
                (define ay (second a))
                (if (ormap (lambda (b)
                             (and (<= (abs (- ax (first b))) 0.5)
                                  (<= (abs (- ay (second b))) 0.5)))
                           acc)
                    acc
                    (cons a acc))))
            (define enemy-combat-pts-for-warp
              (for/list ([e (in-list enemy-units)]
                         #:when (sc2-unit-targetable-enemy-combat? e))
                (define ep (sc2-unit-pos e))
                (cons (sc2-point3d-x ep) (sc2-point3d-y ep))))
            (define (warp-anchor-contested? a)
              (define ax (first a))
              (define ay (second a))
              (ormap (lambda (ept)
                       (define dx (- ax (car ept)))
                       (define dy (- ay (cdr ept)))
                       (and (<= (abs dx) 9.0) (<= (abs dy) 9.0)
                            (<= (+ (* dx dx) (* dy dy)) 81.0)))
                     enemy-combat-pts-for-warp))
            (define sorted-warp-anchors
              (let-values ([(safe-a cont-a) (partition (lambda (a) (not (warp-anchor-contested? a)))
                                                       deduped-warp-anchors)])
                (append (sort safe-a < #:key (lambda (a) (pt-dist home-x home-y (first a) (second a))))
                        (sort cont-a < #:key (lambda (a) (pt-dist home-x home-y (first a) (second a)))))))
            (define-values (px py)
              (if (pair? sorted-warp-anchors)
                  (values (first (car sorted-warp-anchors)) (second (car sorted-warp-anchors)))
                  (pylon-power-anchor)))
            (define (warp-spot-grid-ok? wx wy require-pl?)
              (define path-ok?
                (or (not (sc2-image-grid? step-path-grid))
                    (and (= (sc2-grid-ref step-path-grid wx wy) 1)
                         (= (sc2-grid-ref step-path-grid (- wx 0.45) (- wy 0.45)) 1)
                         (= (sc2-grid-ref step-path-grid (+ wx 0.45) (- wy 0.45)) 1)
                         (= (sc2-grid-ref step-path-grid (- wx 0.45) (+ wy 0.45)) 1)
                         (= (sc2-grid-ref step-path-grid (+ wx 0.45) (+ wy 0.45)) 1))))
              (define pl-ok?
                (or (not require-pl?)
                    (not (sc2-image-grid? step-pl-grid))
                    (= (sc2-grid-ref step-pl-grid wx wy) 1)))
              (and path-ok? pl-ok?))
            (define (valid-warp-spot? wx wy ax ay arad require-pl?)
              (define adist (pt-dist wx wy ax ay))
              (define max-r (max 2.0 (- arad 0.65)))
              (and (>= wx SC2-MAP-PLAYABLE-MIN-COORD) (<= wx SC2-MAP-PLAYABLE-MAX-COORD)
                   (>= wy SC2-MAP-PLAYABLE-MIN-COORD) (<= wy SC2-MAP-PLAYABLE-MAX-COORD)
                   (>= adist 1.85) (<= adist max-r)
                   (warp-spot-grid-ok? wx wy require-pl?)
                   (for/and ([u (in-list units)]
                             #:when (not (sc2-unit-is-flying u)))
                     (define up (sc2-unit-pos u))
                     (define min-r
                       (if (or (sc2-unit-is-structure? u)
                               (sc2-unit-is-mineral-field? u)
                               (sc2-unit-is-vespene-geyser? u))
                           (+ 1.1 (max 0.75 (sc2-unit-radius u)))
                           (+ 0.85 (max 0.375 (sc2-unit-radius u)))))
                     (> (pt-dist wx wy (sc2-point3d-x up) (sc2-point3d-y up)) min-r))
                   (for/and ([rp (in-list step-reserved-build-pts)]
                             #:when (any-point? rp))
                     (> (pt-dist wx wy (any-point-x rp) (any-point-y rp)) 1.5))))
            (define (search-warp-spot require-pl?)
              (for*/first ([a (in-list sorted-warp-anchors)]
                           [ax (in-value (first a))]
                           [ay (in-value (second a))]
                           [arad (in-value (third a))]
                           [r (in-list '(2.2 3.0 3.8 4.6 5.4))]
                           #:when (<= r (- arad 0.65))
                           [k (in-range 16)]
                           [ang (in-value (* k (/ (* 2.0 pi) 16.0)))]
                           [wx (in-value (+ ax (* r (cos ang))))]
                           [wy (in-value (+ ay (* r (sin ang))))]
                           #:when (valid-warp-spot? wx wy ax ay arad require-pl?))
                (sc2-point2d wx wy)))
            (define warp-pt
              (or (search-warp-spot #t)
                  (search-warp-spot #f)
                  ;; Non-overlapping fallback around anchor so multi-gate batches never collide on one tile
                  (for*/first ([k (in-range 16)]
                               [ang (in-value (* k (/ (* 2.0 pi) 16.0)))]
                               [wx (in-value (max SC2-MAP-PLAYABLE-MIN-COORD
                                                  (min SC2-MAP-PLAYABLE-MAX-COORD (+ px (* 2.5 (cos ang))))))]
                               [wy (in-value (max SC2-MAP-PLAYABLE-MIN-COORD
                                                  (min SC2-MAP-PLAYABLE-MAX-COORD (+ py (* 2.5 (sin ang))))))]
                               #:when (for/and ([rp (in-list step-reserved-build-pts)]
                                                #:when (any-point? rp))
                                        (> (pt-dist wx wy (any-point-x rp) (any-point-y rp)) 1.5)))
                    (sc2-point2d wx wy))
                  (sc2-point2d (+ px 2.5) (+ py 2.5))))
            (reserve-step-build-pt! warp-pt warp-ab)
            (emit! (sc2-raw-unit-command warp-ab warp-pt 0 (list ptag) #f))]
           [else
            (emit! (sc2-raw-unit-command ab-id #f 0 (list ptag) #f))]))]

      ;; 2. Build structure: `(build <bldg-sym> <x> <y>)` or `(build <bldg-sym>)`
      [(or (list 'build bldg-sym _ _)
           (list 'build bldg-sym))
       (define norm (normalize-sc2-name->symbol bldg-sym))
       (define ab-id (build-symbol->ability-id norm))
       (define req-x
         (if (pair? (cddr act))
             (scale-bot-coord-to-world (third act) home-x)
             home-x))
       (define req-y
         (if (pair? (cddr act))
             (scale-bot-coord-to-world (fourth act) home-y)
             home-y))
       (when (and ab-id (tech-cap-allows-build? norm))
         (cond
           ;; Nydus Worm / Canal (1768): MUST be cast by a completed allied Nydus Network (unit-type = 95), NEVER a worker!
           [(memq norm '(nydus-worm nydus-canal build-nydus-worm))
            (define nydus-net-tag
              (or (for/first ([u (in-list self-units)]
                              #:when (and (= (sc2-unit-unit-type u) 95)
                                          (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)
                                          (not (set-member? used-producer-tags (sc2-unit-tag u)))))
                    (sc2-unit-tag u))
                  (and (hash? obs)
                       (for/first ([b (in-list (hash-ref obs 'ally-buildings '()))]
                                   #:when (and (hash? b)
                                               (eq? (normalize-sc2-name->symbol (hash-ref b 'type 'unknown)) 'nydus-network)
                                               (>= (hash-ref b 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS)
                                               (exact-integer? (hash-ref b 'id #f))
                                               (> (hash-ref b 'id 0) 0)
                                               (not (set-member? used-producer-tags (hash-ref b 'id)))))
                         (hash-ref b 'id)))))
            (when nydus-net-tag
              (define worm-pt
                (find-verified-building-placement ws-conn 1768 req-x req-y units
                                                  #:min-spacing 2.0
                                                  #:max-radius 10.0
                                                  #:step 1.0
                                                  #:extra-reserved-points step-reserved-build-pts
                                                  #:reserved-aabbs reserved-aabbs
                                                  #:expansion-pads all-expansion-pads
                                                  #:bldg-sym 'nydus-worm
                                                  #:game-info eff-game-info
                                                  #:rpc-budget step-placement-rpc-budget
                                                  #:cur-loop cur-loop))
              (when worm-pt
                (set-add! used-producer-tags nydus-net-tag)
                (hash-set! used-producer-counts nydus-net-tag
                           (add1 (hash-ref used-producer-counts nydus-net-tag 0)))
                (reserve-step-build-pt! worm-pt 1768)
                (record-step-built-structure! norm)
                (emit! (sc2-raw-unit-command 1768 worm-pt 0 (list nydus-net-tag) #f))))]

           ;; Morph-in-place townhall/spire upgrades (Lair, Hive, Greater Spire, Orbital, Planetary)
           [(memq norm '(lair hive greater-spire orbital-command planetary-fortress))
            (define src-types
              (case norm
                [(lair) '(hatchery)]
                [(hive) '(lair)]
                [(greater-spire) '(spire)]
                [(orbital-command planetary-fortress) '(command-center)]
                [else '()]))
            (define idle-src-cands
              (for/list ([u (in-list self-units)]
                         #:when (and (memq (sc2-id->unit-symbol (sc2-unit-unit-type u)) src-types)
                                     (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)
                                     (= (unit-blocking-order-count u) 0)
                                     (not (set-member? used-producer-tags (sc2-unit-tag u)))
                                     (or (<= cur-loop 0)
                                         (>= cur-loop
                                             (hash-ref SC2-WIRE-NONSTACK-CMD-COOLDOWN
                                                       (list 'wire-build-morph norm (sc2-unit-tag u))
                                                       -1)))))
                u))
            ;; Prefer the idle Hatchery/Lair closest to home main base (safest Lair/Hive tech site)
            (define src-u
              (and (pair? idle-src-cands)
                   (argmin (lambda (u)
                             (define up (sc2-unit-pos u))
                             (pt-dist home-x home-y (sc2-point3d-x up) (sc2-point3d-y up)))
                           idle-src-cands)))
            (when (and src-u (wire-nonstack-allow?! (list 'wire-build-morph norm (sc2-unit-tag src-u)) 24))
              (set-add! used-producer-tags (sc2-unit-tag src-u))
              (hash-set! used-producer-counts (sc2-unit-tag src-u)
                         (add1 (hash-ref used-producer-counts (sc2-unit-tag src-u) 0)))
              (record-step-built-structure! norm)
              (emit! (sc2-raw-unit-command ab-id #f 0 (list (sc2-unit-tag src-u)) #f)))]

           ;; Terran Add-ons (Tech Lab & Reactor) built directly by an idle un-attached facility.
           ;; W16-P1-2-wire (`#17` add-on stall & backoff): Verify East add-on slot `(fx+2.5, fy-0.5)`
           ;; even for a SINGLE facility (`length == 1`); if all candidates have blocked East slots,
           ;; relocate cleanly via SC2's dual-mode `PointOrNone` (`421/422/454/455/487/488/3682/3683`
           ;; + verified `5x3` landing point), and if no `5x3` spot exists, apply a 64-loop per-tag
           ;; backoff so wire NEVER spams doomed addon orders every tick!
           [(memq norm '(barracks-tech-lab barracks-techlab barracks-reactor
                         factory-tech-lab factory-techlab factory-reactor
                         starport-tech-lab starport-techlab starport-reactor
                         tech-lab techlab reactor))
            (define fac-types
              (cond
                [(memq norm '(barracks-tech-lab barracks-techlab barracks-reactor)) '(barracks)]
                [(memq norm '(factory-tech-lab factory-techlab factory-reactor)) '(factory)]
                [(memq norm '(starport-tech-lab starport-techlab starport-reactor)) '(starport)]
                [else '(barracks factory starport)]))
            (define cand-facs
              (filter (lambda (u)
                        (and (memq (sc2-id->unit-symbol (sc2-unit-unit-type u)) fac-types)
                             (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)
                             (= (sc2-unit-add-on-tag u) 0)
                             (= (unit-blocking-order-count u) 0)
                             (not (set-member? used-producer-tags (sc2-unit-tag u)))
                             (or (<= cur-loop 0)
                                 (>= cur-loop
                                     (hash-ref SC2-WIRE-NONSTACK-CMD-COOLDOWN
                                               (list 'wire-addon norm (sc2-unit-tag u))
                                               -1)))))
                      self-units))
            (define (fac-addon-block-key u)
              (define p (sc2-unit-pos u))
              (list (sc2-unit-tag u)
                    (inexact->exact (round (sc2-point3d-x p)))
                    (inexact->exact (round (sc2-point3d-y p)))))
            (define (fac-addon-cached-blocked? u)
              (and (> cur-loop 0)
                   (let ([bloop (hash-ref SC2-ADDON-SLOT-BLOCKED-CACHE (fac-addon-block-key u) #f)])
                     (and bloop
                          (>= cur-loop bloop)
                          (< (- cur-loop bloop) 48)))))
            (define (fac-addon-slot-locally-clear? u)
              (define p (sc2-unit-pos u))
              (define ax (+ (sc2-point3d-x p) SC2-TERRAN-ADDON-OFFSET-X))
              (define ay (+ (sc2-point3d-y p) SC2-TERRAN-ADDON-OFFSET-Y))
              (and (>= ax SC2-MAP-PLAYABLE-MIN-COORD) (<= ax SC2-MAP-PLAYABLE-MAX-COORD)
                   (>= ay SC2-MAP-PLAYABLE-MIN-COORD) (<= ay SC2-MAP-PLAYABLE-MAX-COORD)
                   (static-footprint-placement-ok? step-pl-grid ax ay 1.0 1.0)
                   (for/and ([ou (in-list units)]
                             #:when (and (not (= (sc2-unit-tag ou) (sc2-unit-tag u)))
                                         (not (sc2-unit-is-flying ou))
                                         (or (sc2-unit-is-structure? ou)
                                             (sc2-unit-is-mineral-field? ou)
                                             (sc2-unit-is-vespene-geyser? ou))))
                     (define op (sc2-unit-pos ou))
                     (define osym (sc2-id->unit-symbol (sc2-unit-unit-type ou) 'unknown))
                     (define-values (o-hw o-hh)
                       (cond
                         [(sc2-unit-is-mineral-field? ou) (values 1.0 0.5)]
                         [(sc2-unit-is-vespene-geyser? ou) (values 1.5 1.5)]
                         [else (sc2-structure-half-dims osym)]))
                     (not (and (< (abs (- ax (sc2-point3d-x op))) (- (+ 1.0 o-hw) 0.05))
                               (< (abs (- ay (sc2-point3d-y op))) (- (+ 1.0 o-hh) 0.05)))))))
            (define (fac-base-bldg-ab-and-sym u)
              (case (sc2-id->unit-symbol (sc2-unit-unit-type u))
                [(barracks) (values 321 'barracks)]
                [(factory)  (values 328 'factory)]
                [(starport) (values 329 'starport)]
                [else       (values 321 'barracks)]))
            (define (find-addon-reloc-pt fac0)
              (define-values (base-fac-ab base-fac-sym) (fac-base-bldg-ab-and-sym fac0))
              (define fp (sc2-unit-pos fac0))
              (define fx (sc2-point3d-x fp))
              (define fy (sc2-point3d-y fp))
              (define th-anchors
                (let* ([raw-ths
                        (for/list ([th (in-list townhalls)]
                                   #:when (and (>= (sc2-unit-build-progress th) 0.50)
                                               (not (sc2-unit-is-flying th))))
                          (define tp (sc2-unit-pos th))
                          (cons (sc2-point3d-x tp) (sc2-point3d-y tp)))]
                       [enemy-gnd
                        (for/list ([e (in-list enemy-units)]
                                   #:when (and (not (sc2-unit-is-flying e))
                                               (sc2-unit-targetable-enemy-combat? e)))
                          (define ep (sc2-unit-pos e))
                          (cons (sc2-point3d-x ep) (sc2-point3d-y ep)))]
                       [struct-pts
                        (for/list ([s (in-list self-structures)]
                                   #:when (not (sc2-unit-is-flying s)))
                          (define sp (sc2-unit-pos s))
                          (cons (sc2-point3d-x sp) (sc2-point3d-y sp)))])
                  (map first
                       (sort
                        (for/list ([tp (in-list raw-ths)])
                          (define cont?
                            (ormap (lambda (ep) (<= (pt-dist (car tp) (cdr tp) (car ep) (cdr ep)) 10.0))
                                   enemy-gnd))
                          (define crowd
                            (count (lambda (sp) (<= (pt-dist (car tp) (cdr tp) (car sp) (cdr sp)) 12.0))
                                   struct-pts))
                          (list tp (if cont? 1 0) crowd (pt-dist fx fy (car tp) (cdr tp))))
                        (lambda (a b)
                          (cond
                            [(not (= (second a) (second b))) (< (second a) (second b))]
                            [(not (= (third a) (third b))) (< (third a) (third b))]
                            [else (< (fourth a) (fourth b))]))))))
              (define reloc-anchors
                (remove-duplicates (append (list (cons fx fy)) th-anchors (list (cons home-x home-y)))))
              (define bud-before (unbox step-placement-rpc-budget))
              (define pt
                (find-verified-building-placement ws-conn base-fac-ab fx fy (remq fac0 units)
                                                  #:min-spacing 2.0
                                                  #:max-radius 18.0
                                                  #:step 1.0
                                                  #:extra-reserved-points step-reserved-build-pts
                                                  #:anchor-points reloc-anchors
                                                  #:reserved-aabbs reserved-aabbs
                                                  #:expansion-pads all-expansion-pads
                                                  #:bldg-sym base-fac-sym
                                                  #:game-info eff-game-info
                                                  #:rpc-budget step-placement-rpc-budget
                                                  #:cur-loop cur-loop
                                                  #:require-addon-clear? #t))
              (values base-fac-ab pt (and (not pt) (<= bud-before 0))))
            (define (mark-addon-tag-backoff! fac0)
              (when (> cur-loop 0)
                (hash-set! SC2-ADDON-SLOT-BLOCKED-CACHE (fac-addon-block-key fac0) cur-loop)
                (hash-set! SC2-WIRE-NONSTACK-CMD-COOLDOWN
                           (list 'wire-addon norm (sc2-unit-tag fac0))
                           (+ cur-loop 64))))
            (define ws-active-addon?
              (and (sc2-ws-conn? ws-conn) (not (sc2-ws-conn-closed? ws-conn))))
            (define locally-clear-facs
              (filter (lambda (u)
                        (and (fac-addon-slot-locally-clear? u)
                             (not (fac-addon-cached-blocked? u))))
                      cand-facs))
            (define-values (fac-u addon-target-pt addon-reloc-ab addon-cd)
              (cond
                [(null? cand-facs) (values #f #f 0 24)]
                [ws-active-addon?
                 (cond
                   [(pair? locally-clear-facs)
                    (if (consume-placement-rpc-budget! step-placement-rpc-budget)
                        (let* ([q-items
                                (for/list ([u (in-list locally-clear-facs)])
                                  (define p (sc2-unit-pos u))
                                  (sc2-query-placement 319
                                                       (+ (sc2-point3d-x p) SC2-TERRAN-ADDON-OFFSET-X)
                                                       (+ (sc2-point3d-y p) SC2-TERRAN-ADDON-OFFSET-Y)
                                                       0))]
                               [q-resp
                                (sc2-ws-rpc! ws-conn
                                             (make-request-query-placement q-items
                                                                           #:ignore-resource-requirements? #t))]
                               [q-results (sc2-response-query-placements q-resp)])
                          (cond
                            [(not (= (length q-results) (length locally-clear-facs)))
                             (values (first locally-clear-facs) #f 0 24)]
                            [(for/first ([u (in-list locally-clear-facs)]
                                         [res (in-list q-results)]
                                         #:when (= res 1))
                               u)
                             => (lambda (clear-u) (values clear-u #f 0 24))]
                            ;; W18-P0-3-wire (`#14` factory-techlab stall): If a locally-clear East slot
                            ;; failed `QueryPlacement 319` ONLY because a friendly mobile ground unit
                            ;; (SCV/Marine/Hellion) walked across `(fx+2.5, fy-0.5)`, issue in-place
                            ;; add-on build directly (SC2 nudges friendly units aside) instead of lifting
                            ;; off or locking out for 64 loops!
                            [(for/first ([u (in-list locally-clear-facs)]
                                         #:when (let* ([p (sc2-unit-pos u)]
                                                       [ax (+ (sc2-point3d-x p) SC2-TERRAN-ADDON-OFFSET-X)]
                                                       [ay (+ (sc2-point3d-y p) SC2-TERRAN-ADDON-OFFSET-Y)])
                                                  (ormap (lambda (fu)
                                                           (and (not (sc2-unit-is-structure? fu))
                                                                (not (sc2-unit-is-flying fu))
                                                                (let ([fp (sc2-unit-pos fu)])
                                                                  (<= (pt-dist ax ay (sc2-point3d-x fp) (sc2-point3d-y fp))
                                                                      2.25))))
                                                         self-units)))
                               u)
                             => (lambda (nudgable-u) (values nudgable-u #f 0 16))]
                            [else
                             (for ([u (in-list locally-clear-facs)])
                               (hash-set! SC2-ADDON-SLOT-BLOCKED-CACHE (fac-addon-block-key u) cur-loop))
                             (define reloc-u (first cand-facs))
                             (define-values (r-ab r-pt bud-def?) (find-addon-reloc-pt reloc-u))
                             (cond
                               [r-pt (values reloc-u r-pt r-ab 48)]
                               [else
                                (unless bud-def? (mark-addon-tag-backoff! reloc-u))
                                (values #f #f 0 24)])]))
                        (values #f #f 0 24))]
                   [else
                    (define reloc-u (first cand-facs))
                    (define-values (r-ab r-pt bud-def?) (find-addon-reloc-pt reloc-u))
                    (cond
                      [r-pt (values reloc-u r-pt r-ab 48)]
                      [else
                       (unless bud-def? (mark-addon-tag-backoff! reloc-u))
                       (values #f #f 0 24)])])]
                [(pair? locally-clear-facs)
                 (values (first locally-clear-facs) #f 0 24)]
                [else
                 (define reloc-u (first cand-facs))
                 (define-values (r-ab r-pt _bud-def?) (find-addon-reloc-pt reloc-u))
                 (cond
                   [r-pt (values reloc-u r-pt r-ab 48)]
                   [else
                    (mark-addon-tag-backoff! reloc-u)
                    (values #f #f 0 24)])]))
            (when (and fac-u (wire-nonstack-allow?! (list 'wire-addon norm (sc2-unit-tag fac-u)) addon-cd))
              (set-add! used-producer-tags (sc2-unit-tag fac-u))
              (hash-set! used-producer-counts (sc2-unit-tag fac-u)
                         (add1 (hash-ref used-producer-counts (sc2-unit-tag fac-u) 0)))
              (when (sc2-point2d? addon-target-pt)
                (reserve-step-build-pt! addon-target-pt addon-reloc-ab))
              (record-step-built-structure! norm)
              (emit! (sc2-raw-unit-command ab-id addon-target-pt 0 (list (sc2-unit-tag fac-u)) #f)))]

           ;; Vespene gas building targets a neutral geyser unit tag (capped at <= 2 * active TownHalls)
           [(memq norm '(extractor refinery assimilator))
            (define active-townhalls-cnt
              (max 1 (count (lambda (th)
                              (and (not (sc2-unit-is-flying th))
                                   (>= (sc2-unit-build-progress th) 0.50)))
                            townhalls)))
            (define cur-gas-total
              (max (structure-total-with-pending norm)
                   (+ (count sc2-unit-is-gas-building? self-units)
                      (hash-ref step-built-structure-counts 'extractor 0)
                      (hash-ref step-built-structure-counts 'refinery 0)
                      (hash-ref step-built-structure-counts 'assimilator 0))))
            (when (< cur-gas-total (* 2 active-townhalls-cnt))
              (define geyser (find-open-geyser req-x req-y))
              (when geyser
                (define gp (sc2-unit-pos geyser))
                (define wtag (pick-worker-near (sc2-point3d-x gp) (sc2-point3d-y gp)))
                (when wtag
                  (record-step-built-structure! norm)
                  (record-builder-reservation! wtag (sc2-point3d-x gp) (sc2-point3d-y gp) ab-id)
                  (emit! (sc2-raw-unit-command ab-id #f (sc2-unit-tag geyser) (list wtag) #f)))))]

           ;; Protoss structures requiring Pylon power field (searches across all Pylons)
           [(memq norm '(gateway forge cybernetics-core photon-cannon shield-battery
                         twilight-council robotics-facility robotics-bay robotics-support-bay
                         stargate templar-archive templar-archives dark-shrine fleet-beacon))
            (define has-unit-map? (or (pair? power-sources) (pair? units)))
            (define has-power-src? (or (pair? power-sources) (pair? completed-pylons)))
            (define skip-unpowered-cannon?
              (and (eq? norm 'photon-cannon) has-unit-map? (not has-power-src?)))
            (define raw-pylon-anchors (if skip-unpowered-cannon? '() (pylon-power-anchors req-x req-y)))
            ;; W18-P0-1-wire (`<3:30` early Ling rush `#36 P`): Partition uncontested Pylons FIRST
            ;; (no non-flying enemy combat unit within 6.5t) and extend `req-contested?` to core
            ;; production (`gateway`/`cybernetics-core`/`robotics-facility`/`stargate`) so a 2nd Gateway
            ;; builds safely behind an in-main Pylon instead of walking Probes into Zerglings!
            (define req-contested?
              (and (memq norm '(gateway cybernetics-core robotics-facility stargate
                                shield-battery photon-cannon))
                   (ormap (lambda (e)
                            (and (not (sc2-unit-is-flying e))
                                 (sc2-unit-targetable-enemy-combat? e)
                                 (let ([ep (sc2-unit-pos e)])
                                   (<= (pt-dist req-x req-y (sc2-point3d-x ep) (sc2-point3d-y ep)) 6.0))))
                          enemy-units)))
            (define pylon-anchors
              (if (or (null? raw-pylon-anchors) (null? enemy-units))
                  raw-pylon-anchors
                  (let-values ([(safe-p cont-p)
                                (partition (lambda (pt)
                                             (not (ormap (lambda (e)
                                                           (and (not (sc2-unit-is-flying e))
                                                                (sc2-unit-targetable-enemy-combat? e)
                                                                (let ([ep (sc2-unit-pos e)])
                                                                  (<= (pt-dist (car pt) (cdr pt)
                                                                               (sc2-point3d-x ep) (sc2-point3d-y ep))
                                                                      6.5))))
                                                         enemy-units)))
                                           raw-pylon-anchors)])
                    (define ordered-safe
                      (if (and req-contested? (< cur-loop 5400) (pair? safe-p) (pair? (cdr safe-p)))
                          (sort safe-p < #:key (lambda (pt) (pt-dist home-x home-y (car pt) (cdr pt))))
                          safe-p))
                    (append ordered-safe cont-p))))
            (define search-anchors (if (pair? pylon-anchors) pylon-anchors (list (cons req-x req-y))))
            (define-values (px py)
              (values (caar search-anchors) (cdar search-anchors)))
            (define req-powered?
              (point-in-completed-power-field? req-x req-y power-sources completed-pylons))
            (define (powered-place-pt? pt)
              (and pt
                   (or (not (or has-power-src? (and (eq? norm 'photon-cannon) has-unit-map?)))
                       (point-in-completed-power-field? (sc2-point2d-x pt)
                                                        (sc2-point2d-y pt)
                                                        power-sources
                                                        completed-pylons))))
            (define primary-x (if (and req-powered? (not req-contested?)) req-x px))
            (define primary-y (if (and req-powered? (not req-contested?)) req-y py))
            (define eff-anchors
              (if (and req-powered? (not req-contested?))
                  (remove-duplicates (cons (cons req-x req-y) search-anchors))
                  (remove-duplicates (append search-anchors (if req-powered? (list (cons req-x req-y)) '())))))
            (define protoss-budget-before (unbox step-placement-rpc-budget))
            (define place-pt0
              (and (not skip-unpowered-cannon?)
                   (find-verified-building-placement ws-conn ab-id primary-x primary-y units
                                                     #:min-spacing 2.0
                                                     #:max-radius 6.5
                                                     #:step 1.0
                                                     #:extra-reserved-points step-reserved-build-pts
                                                     #:anchor-points eff-anchors
                                                     #:reserved-aabbs reserved-aabbs
                                                     #:expansion-pads all-expansion-pads
                                                     #:bldg-sym norm
                                                     #:game-info eff-game-info
                                                     #:power-sources power-sources
                                                     #:rpc-budget step-placement-rpc-budget
                                                     #:cur-loop cur-loop)))
            (define place-pt
              (cond
                [skip-unpowered-cannon? #f]
                [(powered-place-pt? place-pt0) place-pt0]
                ;; Only run secondary anchor search if `place-pt0` returned an unpowered non-#f point;
                ;; if `place-pt0` was #f, `eff-anchors` already searched all Pylons in one batched RPC!
                [(and place-pt0 (not (and (= primary-x px) (= primary-y py))))
                 (define pt1
                   (find-verified-building-placement ws-conn ab-id px py units
                                                     #:min-spacing 2.0
                                                     #:max-radius 6.5
                                                     #:step 1.0
                                                     #:extra-reserved-points step-reserved-build-pts
                                                     #:anchor-points search-anchors
                                                     #:reserved-aabbs reserved-aabbs
                                                     #:expansion-pads all-expansion-pads
                                                     #:bldg-sym norm
                                                     #:game-info eff-game-info
                                                     #:power-sources power-sources
                                                     #:rpc-budget step-placement-rpc-budget
                                                     #:cur-loop cur-loop))
                 (and (powered-place-pt? pt1) pt1)]
                [else #f]))
            (cond
              [place-pt
               (set-box! SC2-PROTOSS-POWER-PLACEMENT-FAIL-LOOP -9999)
               (reserve-step-build-pt! place-pt ab-id)
               (define wtag (pick-worker-near (sc2-point2d-x place-pt) (sc2-point2d-y place-pt)))
               (when wtag
                 (record-step-built-structure! norm)
                 (record-builder-reservation! wtag (sc2-point2d-x place-pt) (sc2-point2d-y place-pt) ab-id)
                 (emit! (sc2-raw-unit-command ab-id place-pt 0 (list wtag) #f)))]
              [(and (or (> protoss-budget-before 0)
                        (not (and (sc2-ws-conn? ws-conn) (not (sc2-ws-conn-closed? ws-conn)))))
                    (or (sc2-observation? obs)
                        (and (sc2-ws-conn? ws-conn) (not (sc2-ws-conn-closed? ws-conn)))))
               (set-box! SC2-PROTOSS-POWER-PLACEMENT-FAIL-LOOP
                         (if (sc2-observation? obs)
                             (sc2-observation-game-loop obs)
                             (unbox SC2-WARPGATE-LAST-LOOP)))])]

           ;; Zerg structures requiring Creep (including Lurker Den built by Drone via 1163!)
           [(memq norm '(spawning-pool evolution-chamber roach-warren baneling-nest
                         hydralisk-den lurker-den lurker-den-mp spire infestation-pit ultralisk-cavern
                         nydus-network spine-crawler spore-crawler))
            (define safe-creep-pts (ordered-zerg-creep-anchors req-x req-y))
            (define cx (caar safe-creep-pts))
            (define cy (cdar safe-creep-pts))
            (define creep-bud-before (unbox step-placement-rpc-budget))
            (define place-pt0
              (find-verified-building-placement ws-conn ab-id cx cy units
                                                #:min-spacing 2.0
                                                #:max-radius 8.5
                                                #:step 1.0
                                                #:extra-reserved-points step-reserved-build-pts
                                                #:anchor-points safe-creep-pts
                                                #:reserved-aabbs reserved-aabbs
                                                #:expansion-pads all-expansion-pads
                                                #:bldg-sym norm
                                                #:game-info eff-game-info
                                                #:rpc-budget step-placement-rpc-budget
                                                #:cur-loop cur-loop))
            ;; L24-P0-1 (`#52` SpireDrop=14t): For high-priority Zerg tech (`spire`, `hydralisk-den`,
            ;; `lurker-den`, `lurker-den-mp`), when default `8.5t` search actively tried and failed,
            ;; expand search radius `8.5 -> 11.5` across ALL completed Hatchery/Lair/Hive creep anchors
            ;; (plus outer `9.5t` creep-ring offsets so crowded inner rings never exhaust candidate limit)!
            (define creep-85-tried?
              (or (< (unbox step-placement-rpc-budget) creep-bud-before)
                  (not (and (sc2-ws-conn? ws-conn) (not (sc2-ws-conn-closed? ws-conn))))))
            (define place-pt
              (or place-pt0
                  (and creep-85-tried?
                       (memq norm '(spire hydralisk-den lurker-den lurker-den-mp))
                       (let* ([completed-th-pts
                               (for/list ([u (in-list self-units)]
                                          #:when (and (memq (sc2-id->unit-symbol (sc2-unit-unit-type u))
                                                            '(hatchery lair hive))
                                                      (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)))
                                 (define p (sc2-unit-pos u))
                                 (cons (sc2-point3d-x p) (sc2-point3d-y p)))]
                              [ordered-th-pts
                               (remove-duplicates
                                (append (filter (lambda (pt) (member pt completed-th-pts)) safe-creep-pts)
                                        completed-th-pts))]
                              [other-th-pts
                               (filter (lambda (pt) (> (pt-dist cx cy (car pt) (cdr pt)) 2.0)) ordered-th-pts)]
                              [outer-ring-pts
                               (append*
                                (for/list ([thp (in-list (if (pair? ordered-th-pts) ordered-th-pts (list (cons cx cy))))])
                                  (for/list ([off (in-list '((9.5 . 0.0) (-9.5 . 0.0) (0.0 . 9.5) (0.0 . -9.5)))])
                                    (cons (max SC2-MAP-PLAYABLE-MIN-COORD
                                               (min SC2-MAP-PLAYABLE-MAX-COORD (+ (car thp) (car off))))
                                          (max SC2-MAP-PLAYABLE-MIN-COORD
                                               (min SC2-MAP-PLAYABLE-MAX-COORD (+ (cdr thp) (cdr off))))))))]
                              [expanded-creep-pts
                               (remove-duplicates
                                (append other-th-pts outer-ring-pts ordered-th-pts safe-creep-pts))]
                              [ex-cx (caar expanded-creep-pts)]
                              [ex-cy (cdar expanded-creep-pts)])
                         (hash-remove! SC2-PLACEMENT-NEG-COOLDOWN
                                       (list norm (inexact->exact (round cx)) (inexact->exact (round cy))))
                         (hash-remove! SC2-PLACEMENT-NEG-COOLDOWN
                                       (list norm (inexact->exact (round ex-cx)) (inexact->exact (round ex-cy))))
                         (find-verified-building-placement ws-conn ab-id ex-cx ex-cy units
                                                           #:min-spacing 2.0
                                                           #:max-radius 11.5
                                                           #:step 2.0
                                                           #:extra-reserved-points step-reserved-build-pts
                                                           #:anchor-points expanded-creep-pts
                                                           #:reserved-aabbs reserved-aabbs
                                                           #:expansion-pads all-expansion-pads
                                                           #:bldg-sym norm
                                                           #:game-info eff-game-info
                                                           #:rpc-budget step-placement-rpc-budget
                                                           #:cur-loop cur-loop)))))
            (when place-pt
              (reserve-step-build-pt! place-pt ab-id)
              (define wtag (pick-worker-near (sc2-point2d-x place-pt) (sc2-point2d-y place-pt)))
              (when wtag
                (record-step-built-structure! norm)
                (record-builder-reservation! wtag (sc2-point2d-x place-pt) (sc2-point2d-y place-pt) ab-id)
                (emit! (sc2-raw-unit-command ab-id place-pt 0 (list wtag) #f))))]

           ;; Standard ground building placement (Pylons, Supply Depots, Barracks, Factories, Starports, etc.)
           ;; W16-P1-2-wire (`#17`): Include all grounded maturing/completed TownHalls (>= 0.50),
           ;; sorted uncontested-first and (for Terran production) least-crowded-first so crowded mains
           ;; overflow cleanly to natural/3rd with 5x3 clearance (falling back to 3x3 only when all 5x3 fail)!
           [else
            (define is-terran-prod-bldg? (memq norm '(barracks factory starport)))
            (define th-overflow-anchors
              (let* ([raw-ths
                      (for/list ([th (in-list townhalls)]
                                 #:when (and (>= (sc2-unit-build-progress th) 0.50)
                                             (not (sc2-unit-is-flying th))))
                        (define tp (sc2-unit-pos th))
                        (cons (sc2-point3d-x tp) (sc2-point3d-y tp)))]
                     [enemy-gnd
                      (for/list ([e (in-list enemy-units)]
                                 #:when (and (not (sc2-unit-is-flying e))
                                             (sc2-unit-targetable-enemy-combat? e)))
                        (define ep (sc2-unit-pos e))
                        (cons (sc2-point3d-x ep) (sc2-point3d-y ep)))]
                     [struct-pts
                      (if is-terran-prod-bldg?
                          (for/list ([s (in-list self-structures)]
                                     #:when (not (sc2-unit-is-flying s)))
                            (define sp (sc2-unit-pos s))
                            (cons (sc2-point3d-x sp) (sc2-point3d-y sp)))
                          '())])
                (if (null? raw-ths)
                    '()
                    (map first
                         (sort
                          (for/list ([tp (in-list raw-ths)])
                            (define cont?
                              (ormap (lambda (ep)
                                       (<= (pt-dist (car tp) (cdr tp) (car ep) (cdr ep)) 10.0))
                                     enemy-gnd))
                            (define crowd
                              (if is-terran-prod-bldg?
                                  (count (lambda (sp)
                                           (<= (pt-dist (car tp) (cdr tp) (car sp) (cdr sp)) 12.0))
                                         struct-pts)
                                  0))
                            (list tp (if cont? 1 0) crowd (pt-dist req-x req-y (car tp) (cdr tp))))
                          (lambda (a b)
                            (cond
                              [(not (= (second a) (second b))) (< (second a) (second b))]
                              [(and is-terran-prod-bldg? (not (= (third a) (third b))))
                               (< (third a) (third b))]
                              [else (< (fourth a) (fourth b))])))))))
            ;; W12-P0-3-wire / W16-P1-2-wire: For emergency supply/defense/production structures
            ;; (`pylon`, `supply-depot`, `bunker`, `barracks`, `factory`, `starport`), compute safe
            ;; in-main fallback anchors stepped away from the mineral line; if enemy ground combat units
            ;; sit within <= 5.5t of `(req-x, req-y)`, pivot safely without stalling!
            (define is-rush-supply-or-bunker?
              (memq norm '(pylon supply-depot bunker barracks factory starport)))
            (define inmain-safe-anchors
              (if is-rush-supply-or-bunker?
                  (let* ([near-mins
                          (filter (lambda (m)
                                    (define mp (sc2-unit-pos m))
                                    (<= (pt-dist home-x home-y (sc2-point3d-x mp) (sc2-point3d-y mp)) 13.0))
                                  mineral-fields)]
                         [ux-uy
                          (if (pair? near-mins)
                              (let* ([cnt (length near-mins)]
                                     [mcx (/ (for/sum ([m (in-list near-mins)]) (sc2-point3d-x (sc2-unit-pos m))) cnt)]
                                     [mcy (/ (for/sum ([m (in-list near-mins)]) (sc2-point3d-y (sc2-unit-pos m))) cnt)]
                                     [dx (- home-x mcx)]
                                     [dy (- home-y mcy)]
                                     [d (max 0.5 (sqrt (+ (* dx dx) (* dy dy))))])
                                (cons (/ dx d) (/ dy d)))
                              (cons 0.7071 0.7071))]
                         [ux (car ux-uy)]
                         [uy (cdr ux-uy)]
                         [cands
                          (for/list ([ang (in-list '(0.0 0.65 -0.65 1.30 -1.30))])
                            (define ca (cos ang))
                            (define sa (sin ang))
                            (define rx (- (* ux ca) (* uy sa)))
                            (define ry (+ (* ux sa) (* uy ca)))
                            (cons (max SC2-MAP-PLAYABLE-MIN-COORD (min SC2-MAP-PLAYABLE-MAX-COORD (+ home-x (* 6.0 rx))))
                                  (max SC2-MAP-PLAYABLE-MIN-COORD (min SC2-MAP-PLAYABLE-MAX-COORD (+ home-y (* 6.0 ry))))))])
                    (let-values ([(safe-c cont-c)
                                  (partition (lambda (pt)
                                               (not (ormap (lambda (e)
                                                             (and (not (sc2-unit-is-flying e))
                                                                  (sc2-unit-targetable-enemy-combat? e)
                                                                  (let ([ep (sc2-unit-pos e)])
                                                                    (<= (pt-dist (car pt) (cdr pt)
                                                                                 (sc2-point3d-x ep) (sc2-point3d-y ep))
                                                                        5.5))))
                                                           enemy-units)))
                                             cands)])
                      (append safe-c cont-c)))
                  '()))
            ;; L24-P0-1 (`#51` 3D Visual-QA Repower Guarantee): When building a `pylon` and ANY owned
            ;; Protoss production/tech structure (`gateway`, `warp-gate`, `robotics-facility`, `stargate`,
            ;; `cybernetics-core`, `twilight-council`, `forge`) is unpowered (with no pending Pylon already
            ;; warping in within <= 6.0t), ALWAYS try safe repower anchors strictly within <= 5.5t (inside
            ;; 6.5t Pylon radius), preferring home-side & away from enemy ground units, BEFORE
            ;; `early-rush-1base-inmain?` can displace the Pylon > 6.0t away!
            (define (unpowered-protoss-prod-prio sym)
              (case sym
                [(gateway warp-gate)  1]
                [(robotics-facility)  2]
                [(stargate)           3]
                [(cybernetics-core)   4]
                [(twilight-council)   5]
                [(forge)              6]
                [else                #f]))
            (define repower-target
              (and (eq? norm 'pylon)
                   (let* ([pending-pylons
                           (filter (lambda (s)
                                     (and (= (sc2-unit-unit-type s) 60)
                                          (< (sc2-unit-build-progress s) SC2-BUILD-COMPLETE-PROGRESS)))
                                   self-structures)]
                          [unpowered-cands
                           (for/list ([s (in-list self-structures)]
                                      #:when (let* ([ssym (sc2-id->unit-symbol (sc2-unit-unit-type s) 'unknown)]
                                                    [prio (unpowered-protoss-prod-prio ssym)]
                                                    [sp (sc2-unit-pos s)]
                                                    [sx (sc2-point3d-x sp)]
                                                    [sy (sc2-point3d-y sp)])
                                               (and prio
                                                    (not (sc2-unit-is-flying s))
                                                    (not (sc2-unit-is-powered s))
                                                    (not (point-in-completed-power-field? sx sy power-sources completed-pylons))
                                                    (not (ormap (lambda (pp)
                                                                  (define ppp (sc2-unit-pos pp))
                                                                  (<= (pt-dist sx sy (sc2-point3d-x ppp) (sc2-point3d-y ppp)) 6.0))
                                                                pending-pylons)))))
                             (define sp (sc2-unit-pos s))
                             (define ssym (sc2-id->unit-symbol (sc2-unit-unit-type s) 'unknown))
                             (list s
                                   (unpowered-protoss-prod-prio ssym)
                                   (pt-dist home-x home-y (sc2-point3d-x sp) (sc2-point3d-y sp))))])
                     (and (pair? unpowered-cands)
                          (first
                           (first
                            (sort unpowered-cands
                                  (lambda (a b)
                                    (if (not (= (second a) (second b)))
                                        (< (second a) (second b))
                                        (< (third a) (third b)))))))))))
            (define-values (repower-ux repower-uy repower-anchors)
              (if repower-target
                  (let* ([up (sc2-unit-pos repower-target)]
                         [ux (sc2-point3d-x up)]
                         [uy (sc2-point3d-y up)]
                         [hx (- home-x ux)]
                         [hy (- home-y uy)]
                         [hd (sqrt (+ (* hx hx) (* hy hy)))]
                         [dx (if (> hd 0.5) (/ hx hd) -0.7071)]
                         [dy (if (> hd 0.5) (/ hy hd) -0.7071)]
                         [raw-ring
                          (for/list ([ang (in-list '(0.0 0.55 -0.55 1.10 -1.10 1.65 -1.65 2.20 -2.20 3.14159))])
                            (define ca (cos ang))
                            (define sa (sin ang))
                            (define rx (- (* dx ca) (* dy sa)))
                            (define ry (+ (* dx sa) (* dy ca)))
                            (cons (max SC2-MAP-PLAYABLE-MIN-COORD (min SC2-MAP-PLAYABLE-MAX-COORD (+ ux (* 3.5 rx))))
                                  (max SC2-MAP-PLAYABLE-MIN-COORD (min SC2-MAP-PLAYABLE-MAX-COORD (+ uy (* 3.5 ry))))))]
                         [enemy-gnd
                          (for/list ([e (in-list enemy-units)]
                                     #:when (and (not (sc2-unit-is-flying e))
                                                 (sc2-unit-targetable-enemy-combat? e)))
                            (define ep (sc2-unit-pos e))
                            (cons (sc2-point3d-x ep) (sc2-point3d-y ep)))])
                    (define-values (safe-r cont-r)
                      (partition (lambda (pt)
                                   (not (ormap (lambda (ep)
                                                 (<= (pt-dist (car pt) (cdr pt) (car ep) (cdr ep)) 4.5))
                                               enemy-gnd)))
                                 raw-ring))
                    (define ordered-r (remove-duplicates (append safe-r cont-r)))
                    (values ux uy (take ordered-r (min 8 (length ordered-r)))))
                  (values 0.0 0.0 '())))
            (define repower-place-pt
              (and repower-target
                   (pair? repower-anchors)
                   (let ([pt (find-verified-building-placement ws-conn ab-id
                                                               (caar repower-anchors)
                                                               (cdar repower-anchors)
                                                               units
                                                               #:min-spacing 2.0
                                                               #:max-radius 2.0
                                                               #:step 1.0
                                                               #:extra-reserved-points step-reserved-build-pts
                                                               #:anchor-points repower-anchors
                                                               #:reserved-aabbs reserved-aabbs
                                                               #:expansion-pads all-expansion-pads
                                                               #:bldg-sym norm
                                                               #:game-info eff-game-info
                                                               #:rpc-budget step-placement-rpc-budget
                                                               #:cur-loop cur-loop)])
                     (and (sc2-point2d? pt)
                          (<= (pt-dist (sc2-point2d-x pt) (sc2-point2d-y pt) repower-ux repower-uy) 6.0)
                          pt))))
            (define req-contested-by-rush?
              (and (memq norm '(pylon supply-depot barracks factory starport))
                   (ormap (lambda (e)
                            (and (not (sc2-unit-is-flying e))
                                 (sc2-unit-targetable-enemy-combat? e)
                                 (let ([ep (sc2-unit-pos e)])
                                   (<= (pt-dist req-x req-y (sc2-point3d-x ep) (sc2-point3d-y ep)) 5.5))))
                          enemy-units)))
            (define terran-5x3-missed?
              (and is-terran-prod-bldg?
                   (terran-5x3-miss-active? norm req-x req-y cur-loop)))
            (define early-rush-1base-inmain?
              (and req-contested-by-rush?
                   (< cur-loop 5400)
                   (<= (length th-overflow-anchors) 1)
                   (pair? inmain-safe-anchors)))
            (define eff-req-x
              (cond
                [early-rush-1base-inmain? (caar inmain-safe-anchors)]
                [(and (or req-contested-by-rush? terran-5x3-missed?)
                      is-terran-prod-bldg?
                      (pair? th-overflow-anchors))
                 (caar th-overflow-anchors)]
                [(and req-contested-by-rush? (pair? inmain-safe-anchors))
                 (caar inmain-safe-anchors)]
                [else req-x]))
            (define eff-req-y
              (cond
                [early-rush-1base-inmain? (cdar inmain-safe-anchors)]
                [(and (or req-contested-by-rush? terran-5x3-missed?)
                      is-terran-prod-bldg?
                      (pair? th-overflow-anchors))
                 (cdar th-overflow-anchors)]
                [(and req-contested-by-rush? (pair? inmain-safe-anchors))
                 (cdar inmain-safe-anchors)]
                [else req-y]))
            (define std-anchors
              (remove-duplicates
               (cond
                 [early-rush-1base-inmain?
                  (append inmain-safe-anchors
                          th-overflow-anchors
                          (list (cons home-x home-y) (cons req-x req-y)))]
                 [(and (or req-contested-by-rush? terran-5x3-missed?) is-terran-prod-bldg?)
                  (append th-overflow-anchors
                          inmain-safe-anchors
                          (list (cons home-x home-y) (cons req-x req-y)))]
                 [req-contested-by-rush?
                  (append inmain-safe-anchors
                          (list (cons home-x home-y) (cons req-x req-y))
                          th-overflow-anchors)]
                 [is-terran-prod-bldg?
                  (append (list (cons req-x req-y))
                          th-overflow-anchors
                          (list (cons home-x home-y))
                          (take inmain-safe-anchors (min 2 (length inmain-safe-anchors))))]
                 [else
                  (append (list (cons req-x req-y))
                          inmain-safe-anchors
                          (list (cons home-x home-y))
                          th-overflow-anchors)])))
            (define place-pt
              (or repower-place-pt
                  (and (memq norm '(command-center nexus hatchery))
                       (> (pt-dist home-x home-y req-x req-y) SC2-BASE-RESOURCE-RADIUS)
                       (find-best-expansion-placement ws-conn ab-id home-x home-y units
                                                      #:req-x req-x
                                                      #:req-y req-y
                                                      #:game-info eff-game-info
                                                      #:remembered-enemies SC2-LAST-KNOWN-ENEMY-POS
                                                      #:rpc-budget step-placement-rpc-budget
                                                      #:cur-loop cur-loop))
                  (find-verified-building-placement ws-conn ab-id eff-req-x eff-req-y units
                                                    #:min-spacing 2.0
                                                    #:max-radius 15.0
                                                    #:step 1.0
                                                    #:extra-reserved-points step-reserved-build-pts
                                                    #:anchor-points std-anchors
                                                    #:reserved-aabbs reserved-aabbs
                                                    #:expansion-pads all-expansion-pads
                                                    #:bldg-sym norm
                                                    #:game-info eff-game-info
                                                    #:rpc-budget step-placement-rpc-budget
                                                    #:cur-loop cur-loop
                                                    #:prefer-3x3-fallback? terran-5x3-missed?)))
            (when place-pt
              (reserve-step-build-pt! place-pt ab-id)
              (define wtag (pick-worker-near (sc2-point2d-x place-pt) (sc2-point2d-y place-pt)))
              (when wtag
                (record-step-built-structure! norm)
                (record-builder-reservation! wtag (sc2-point2d-x place-pt) (sc2-point2d-y place-pt) ab-id)
                (emit! (sc2-raw-unit-command ab-id place-pt 0 (list wtag) #f))))]))]

      ;; 2b. Dedicated Nydus Worm intent: `(build-nydus-worm <x> <y>)` or `(build-nydus-worm <nydus-id> <x> <y>)`
      [(or (list 'build-nydus-worm (? exact-integer? explicit-nid) (? real? raw-x) (? real? raw-y))
           (and (list 'build-nydus-worm (? real? raw-x) (? real? raw-y))
                (app (lambda (_) #f) explicit-nid)))
       (define req-x (scale-bot-coord-to-world raw-x home-x))
       (define req-y (scale-bot-coord-to-world raw-y home-y))
       (define nydus-net-tag
         (cond
           [(and explicit-nid
                 (> explicit-nid 0)
                 (not (set-member? used-producer-tags explicit-nid))
                 (let ([nu (hash-ref self-unit-by-tag explicit-nid #f)])
                   (if nu
                       (and (= (sc2-unit-unit-type nu) 95)
                            (>= (sc2-unit-build-progress nu) SC2-BUILD-COMPLETE-PROGRESS))
                       (null? self-units))))
            explicit-nid]
           [else
            (or (for/first ([u (in-list self-units)]
                            #:when (and (= (sc2-unit-unit-type u) 95)
                                        (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)
                                        (not (set-member? used-producer-tags (sc2-unit-tag u)))))
                  (sc2-unit-tag u))
                (and (hash? obs)
                     (for/first ([b (in-list (hash-ref obs 'ally-buildings '()))]
                                 #:when (and (hash? b)
                                             (eq? (normalize-sc2-name->symbol (hash-ref b 'type 'unknown)) 'nydus-network)
                                             (>= (hash-ref b 'build-progress 1.0) SC2-BUILD-COMPLETE-PROGRESS)
                                             (exact-integer? (hash-ref b 'id #f))
                                             (> (hash-ref b 'id 0) 0)
                                             (not (set-member? used-producer-tags (hash-ref b 'id)))))
                       (hash-ref b 'id))))]))
       (when nydus-net-tag
         (define worm-pt
           (find-verified-building-placement ws-conn 1768 req-x req-y units
                                             #:min-spacing 2.0
                                             #:max-radius 10.0
                                             #:step 1.0
                                             #:extra-reserved-points step-reserved-build-pts
                                             #:reserved-aabbs reserved-aabbs
                                             #:expansion-pads all-expansion-pads
                                             #:bldg-sym 'nydus-worm
                                             #:game-info eff-game-info
                                             #:rpc-budget step-placement-rpc-budget
                                             #:cur-loop cur-loop))
         (when worm-pt
           (set-add! used-producer-tags nydus-net-tag)
           (hash-set! used-producer-counts nydus-net-tag
                      (add1 (hash-ref used-producer-counts nydus-net-tag 0)))
           (reserve-step-build-pt! worm-pt 1768)
           (emit! (sc2-raw-unit-command 1768 worm-pt 0 (list nydus-net-tag) #f))))]

      ;; 3. Expand: `(expand <x> <y>)` or `(expand <th-sym> <x> <y>)`
      [(or (list 'expand _ _)
           (list 'expand _ _ _))
       (define-values (req-x req-y)
         (match act
           [(list 'expand (? real? rx) (? real? ry))
            (values (scale-bot-coord-to-world rx home-x)
                    (scale-bot-coord-to-world ry home-y))]
           [(list 'expand _ (? real? rx) (? real? ry))
            (values (scale-bot-coord-to-world rx home-x)
                    (scale-bot-coord-to-world ry home-y))]
           [_ (values #f #f)]))
       (define th-ab
         (cond
           [(ormap (lambda (u) (memq (sc2-id->unit-symbol (sc2-unit-unit-type u)) '(hatchery lair hive drone))) self-units)
            1152] ;; ZERGBUILD_HATCHERY
           [(ormap (lambda (u) (memq (sc2-id->unit-symbol (sc2-unit-unit-type u)) '(command-center orbital-command scv))) self-units)
            318]  ;; TERRANBUILD_COMMANDCENTER
           [else
            880])) ;; PROTOSSBUILD_NEXUS
       (define exp-pt
         (find-best-expansion-placement ws-conn th-ab home-x home-y units
                                        #:req-x req-x
                                        #:req-y req-y
                                        #:game-info eff-game-info
                                        #:remembered-enemies SC2-LAST-KNOWN-ENEMY-POS
                                        #:rpc-budget step-placement-rpc-budget
                                        #:cur-loop cur-loop))
       (when (sc2-point2d? exp-pt)
         (reserve-step-build-pt! exp-pt th-ab)
         (define wtag (pick-worker-near (sc2-point2d-x exp-pt) (sc2-point2d-y exp-pt)))
         (when wtag
           (set! active-friendly-th-build-pads
                 (cons (cons (sc2-point2d-x exp-pt) (sc2-point2d-y exp-pt))
                       active-friendly-th-build-pads))
           (record-builder-reservation! wtag (sc2-point2d-x exp-pt) (sc2-point2d-y exp-pt) th-ab)
           (emit! (sc2-raw-unit-command th-ab exp-pt 0 (list wtag) #f))))]

      ;; 4. Research upgrade: `(research <upg-sym>)`
      [(list 'research upg-sym)
       (define ab-id (research-symbol->ability-id upg-sym))
       (define rtag (select-researcher-tag upg-sym self-units #:units-by-sym self-units-by-sym))
       (when (and ab-id rtag
                  (not (set-member? used-producer-tags rtag))
                  (wire-nonstack-allow?! (list 'wire-research (normalize-sc2-name->symbol upg-sym) rtag) 24))
         (set-add! used-producer-tags rtag)
         (hash-set! used-producer-counts rtag (add1 (hash-ref used-producer-counts rtag 0)))
         (emit! (sc2-raw-unit-command ab-id #f 0 (list rtag) #f)))]

      ;; 5. Morph unit/structure: `(morph <unit-id-or-ids> <target-sym>)` or `(morph <target-sym>)`
      [(list 'morph uid target-sym)
       (define norm-target (normalize-sc2-name->symbol target-sym))
       (cond
         [(memq norm-target '(lurker-den lurker-den-mp))
          (when (tech-cap-allows-build? norm-target)
            (define safe-creep-pts (ordered-zerg-creep-anchors home-x home-y))
            (define cx (caar safe-creep-pts))
            (define cy (cdar safe-creep-pts))
            (define place-pt
              (find-verified-building-placement ws-conn 1163 cx cy units
                                                #:min-spacing 2.0
                                                #:max-radius 8.5
                                                #:step 1.0
                                                #:extra-reserved-points step-reserved-build-pts
                                                #:anchor-points safe-creep-pts
                                                #:reserved-aabbs reserved-aabbs
                                                #:expansion-pads all-expansion-pads
                                                #:bldg-sym norm-target
                                                #:game-info eff-game-info
                                                #:rpc-budget step-placement-rpc-budget
                                                #:cur-loop cur-loop))
            (when place-pt
              (reserve-step-build-pt! place-pt 1163)
              (define explicit-drone-tag
                (for/first ([t (in-list (if (list? uid) uid (list uid)))]
                            #:when (and (exact-integer? t)
                                        (> t 0)
                                        (not (set-member? used-worker-tags t))
                                        (let ([du (hash-ref self-unit-by-tag t #f)])
                                          (and du (sc2-unit-is-worker? du)))))
                  t))
              (define wtag
                (if explicit-drone-tag
                    (begin (record-worker-used! explicit-drone-tag #t) explicit-drone-tag)
                    (pick-worker-near (sc2-point2d-x place-pt) (sc2-point2d-y place-pt))))
              (when wtag
                (record-step-built-structure! norm-target)
                (record-builder-reservation! wtag (sc2-point2d-x place-pt) (sc2-point2d-y place-pt) 1163)
                (emit! (sc2-raw-unit-command 1163 place-pt 0 (list wtag) #f)))))]
         [else
          (define ab-id (morph-symbol->ability-id norm-target))
          (define raw-uid-list
            (remove-duplicates
             (filter (lambda (t)
                       (and (exact-integer? t)
                            (> t 0)
                            (not (set-member? used-producer-tags t))))
                     (if (list? uid) uid (list uid)))))
          (define uid-list
            (cond
              [(eq? norm-target 'archon)
               (define (archon-pair-safe? pair-tags)
                 (and (= (length pair-tags) 2)
                      (let ([u1 (hash-ref self-unit-by-tag (first pair-tags) #f)]
                            [u2 (hash-ref self-unit-by-tag (second pair-tags) #f)])
                        (cond
                          [(and u1 u2) (sc2-archon-merge-pair-safe? u1 u2 enemy-units)]
                          [(null? self-units) #t]
                          [else #f]))))
               (cond
                 [(and (>= (length raw-uid-list) 2)
                       (archon-pair-safe? (take raw-uid-list 2)))
                  (take raw-uid-list 2)]
                 [else
                  (define fb
                    (filter (lambda (t) (not (set-member? used-producer-tags t)))
                            (select-producer-tags-for-unit 'archon self-units enemy-units #:units-by-sym self-units-by-sym)))
                  (if (>= (length fb) 2) (take fb 2) '())])]
              [(and (not (null? self-units))
                    (memq norm-target SC2-ZERG-COMBAT-MORPH-SYMS))
               (define enemy-combat
                 (if (null? enemy-units)
                     '()
                     (filter sc2-unit-targetable-enemy-combat? enemy-units)))
               (define safe-explicit
                 (filter (lambda (t)
                           (define su (hash-ref self-unit-by-tag t #f))
                           (and su
                                (>= (sc2-unit-build-progress su) SC2-BUILD-COMPLETE-PROGRESS)
                                (not (sc2-unit-is-hallucination su))
                                (not (sc2-unit-is-burrowed su))
                                (sc2-zerg-combat-morph-unit-safe? su enemy-combat)))
                         raw-uid-list))
               (if (not (null? safe-explicit))
                   safe-explicit
                   (let ([fb (filter (lambda (t) (not (set-member? used-producer-tags t)))
                                     (select-producer-tags-for-unit norm-target self-units enemy-units #:units-by-sym self-units-by-sym))])
                     (if (not (null? fb)) (list (first fb)) '())))]
              [(and (not (null? self-units))
                    (memq norm-target '(lair hive greater-spire orbital-command planetary-fortress warp-gate warpgate)))
               (define (morph-tag-cd-ready? t)
                 (or (<= cur-loop 0)
                     (and (>= cur-loop
                              (hash-ref SC2-WIRE-NONSTACK-CMD-COOLDOWN
                                        (list 'wire-morph norm-target (list t))
                                        -1))
                          (>= cur-loop
                              (hash-ref SC2-WIRE-NONSTACK-CMD-COOLDOWN
                                        (list 'wire-build-morph norm-target t)
                                        -1)))))
               (define valid-idle
                 (filter (lambda (t)
                           (define su (hash-ref self-unit-by-tag t #f))
                           (and su
                                (>= (sc2-unit-build-progress su) SC2-BUILD-COMPLETE-PROGRESS)
                                (not (sc2-unit-is-flying su))
                                (= (unit-blocking-order-count su) 0)
                                (morph-tag-cd-ready? t)))
                         raw-uid-list))
               (if (not (null? valid-idle))
                   valid-idle
                   (let* ([fb0 (filter (lambda (t)
                                         (and (not (set-member? used-producer-tags t))
                                              (morph-tag-cd-ready? t)))
                                       (select-producer-tags-for-unit norm-target self-units enemy-units #:units-by-sym self-units-by-sym))]
                          [fb (if (memq norm-target '(lair hive greater-spire orbital-command planetary-fortress))
                                  (sort fb0 <
                                        #:key (lambda (t)
                                                (define su (hash-ref self-unit-by-tag t #f))
                                                (if su
                                                    (let ([up (sc2-unit-pos su)])
                                                      (pt-dist home-x home-y (sc2-point3d-x up) (sc2-point3d-y up)))
                                                    9999.0)))
                                  fb0)])
                     (if (not (null? fb)) (list (first fb)) '())))]
              [else raw-uid-list]))
          (when (and ab-id (not (null? uid-list))
                     (or (memv ab-id '(403 405))
                         (wire-nonstack-allow?! (list 'wire-morph norm-target uid-list) 24)))
            (cond
              [(memv ab-id '(403 405))
               (emit-viking-morph-deduped! ab-id uid-list)]
              [else
               (for ([t (in-list uid-list)])
                 (set-add! used-producer-tags t)
                 (set-add! commanded-combat-tags t)
                 (hash-set! used-producer-counts t (add1 (hash-ref used-producer-counts t 0))))
               (emit! (sc2-raw-unit-command ab-id #f 0 uid-list #f))]))])]
      [(list 'morph target-sym)
       (define norm-target (normalize-sc2-name->symbol target-sym))
       (cond
         [(memq norm-target '(lurker-den lurker-den-mp))
          (when (tech-cap-allows-build? norm-target)
            (define safe-creep-pts (ordered-zerg-creep-anchors home-x home-y))
            (define cx (caar safe-creep-pts))
            (define cy (cdar safe-creep-pts))
            (define place-pt
              (find-verified-building-placement ws-conn 1163 cx cy units
                                                #:min-spacing 2.0
                                                #:max-radius 8.5
                                                #:step 1.0
                                                #:extra-reserved-points step-reserved-build-pts
                                                #:anchor-points safe-creep-pts
                                                #:reserved-aabbs reserved-aabbs
                                                #:expansion-pads all-expansion-pads
                                                #:bldg-sym norm-target
                                                #:game-info eff-game-info
                                                #:rpc-budget step-placement-rpc-budget
                                                #:cur-loop cur-loop))
            (when place-pt
              (reserve-step-build-pt! place-pt 1163)
              (define wtag (pick-worker-near (sc2-point2d-x place-pt) (sc2-point2d-y place-pt)))
              (when wtag
                (record-step-built-structure! norm-target)
                (record-builder-reservation! wtag (sc2-point2d-x place-pt) (sc2-point2d-y place-pt) 1163)
                (emit! (sc2-raw-unit-command 1163 place-pt 0 (list wtag) #f)))))]
         [(eq? norm-target 'archon)
          (define ab-id (morph-symbol->ability-id norm-target))
          (define ptags
            (remove-duplicates
             (filter (lambda (t) (not (set-member? used-producer-tags t)))
                     (select-producer-tags-for-unit norm-target self-units enemy-units #:units-by-sym self-units-by-sym))))
          (when (and ab-id (>= (length ptags) 2))
            (define chosen2 (take ptags 2))
            (for ([t (in-list chosen2)])
              (set-add! used-producer-tags t)
              (set-add! commanded-combat-tags t)
              (hash-set! used-producer-counts t (add1 (hash-ref used-producer-counts t 0))))
            (emit! (sc2-raw-unit-command ab-id #f 0 chosen2 #f)))]
         [else
          (define ab-id (morph-symbol->ability-id norm-target))
          (define is-bldg-morph?
            (memq norm-target '(lair hive greater-spire orbital-command planetary-fortress)))
          (define raw-ptags
            (filter (lambda (t)
                      (and (not (set-member? used-producer-tags t))
                           (or (not is-bldg-morph?)
                               (<= cur-loop 0)
                               (and (>= cur-loop
                                        (hash-ref SC2-WIRE-NONSTACK-CMD-COOLDOWN
                                                  (list 'wire-morph norm-target (list t))
                                                  -1))
                                    (>= cur-loop
                                        (hash-ref SC2-WIRE-NONSTACK-CMD-COOLDOWN
                                                  (list 'wire-build-morph norm-target t)
                                                  -1))))))
                    (select-producer-tags-for-unit norm-target self-units enemy-units #:units-by-sym self-units-by-sym)))
          (define ptags
            (if (and is-bldg-morph? (pair? raw-ptags) (pair? (cdr raw-ptags)))
                (sort raw-ptags <
                      #:key (lambda (t)
                              (define su (hash-ref self-unit-by-tag t #f))
                              (if su
                                  (let ([up (sc2-unit-pos su)])
                                    (pt-dist home-x home-y (sc2-point3d-x up) (sc2-point3d-y up)))
                                  9999.0)))
                raw-ptags))
          (when (and ab-id (not (null? ptags)))
            (define ptag (first ptags))
            (when (wire-nonstack-allow?! (list 'wire-morph norm-target (list ptag)) 24)
              (set-add! used-producer-tags ptag)
              (set-add! commanded-combat-tags ptag)
              (hash-set! used-producer-counts ptag (add1 (hash-ref used-producer-counts ptag 0)))
              (emit! (sc2-raw-unit-command ab-id #f 0 (list ptag) #f))))])]

      ;; 6. Attack / Move / Kite / Hold-Position / Retreat (with per-step & in-flight order deduplication)
      [(list 'attack-pos ids raw-x raw-y)
       (define tx (scale-bot-coord-to-world raw-x home-x))
       (define ty (scale-bot-coord-to-world raw-y home-y))
       (define target-pt (sc2-point2d tx ty))
       (define tag-list (claim-combat-tags-for-order! ids 23 target-pt 0))
       (when (not (null? tag-list))
         (emit! (sc2-raw-unit-command 23 target-pt 0 tag-list #f)))]

      [(list (or 'attack 'attack-unit) uid target-id)
       #:when (and (or (exact-integer? uid) (list? uid)) (exact-integer? target-id))
       (cond
         [(or (not enforce-live-enemy-tag-filter?)
              (set-member? live-visible-enemy-tags target-id))
          (define tag-list (claim-combat-tags-for-order! uid 23 #f target-id))
          (when (not (null? tag-list))
            (define raw-atk (sc2-raw-unit-command 23 #f target-id tag-list #f))
            (emit! (if (set-member? enemy-near-own-base-tags target-id)
                       (mark-urgent-survival-cmd! raw-atk)
                       raw-atk)))]
         [else
          (define cached-pt (hash-ref SC2-LAST-KNOWN-ENEMY-POS target-id #f))
          (define fallback-pt
            (if (pair? cached-pt)
                (sc2-point2d (car cached-pt) (cdr cached-pt))
                (let ([ebx (if (and (list? enemy-base) (>= (length enemy-base) 2))
                               (exact->inexact (first enemy-base))
                               (- SC2-DEFAULT-MAP-WIDTH home-x))]
                      [eby (if (and (list? enemy-base) (>= (length enemy-base) 2))
                               (exact->inexact (second enemy-base))
                               (- SC2-DEFAULT-MAP-HEIGHT home-y))])
                  (sc2-point2d ebx eby))))
          (define tag-list (claim-combat-tags-for-order! uid 23 fallback-pt 0))
          (when (not (null? tag-list))
            (emit! (sc2-raw-unit-command 23 fallback-pt 0 tag-list #f)))])]

      [(list (or 'focus-fire 'cannon-focus-fire) uid target-id rest ...)
       #:when (and (or (exact-integer? uid) (list? uid)) (exact-integer? target-id))
       (cond
         [(or (not enforce-live-enemy-tag-filter?)
              (set-member? live-visible-enemy-tags target-id))
          (define tag-list (claim-combat-tags-for-order! uid 23 #f target-id))
          (when (not (null? tag-list))
            (define raw-atk (sc2-raw-unit-command 23 #f target-id tag-list #f))
            (emit! (if (set-member? enemy-near-own-base-tags target-id)
                       (mark-urgent-survival-cmd! raw-atk)
                       raw-atk)))]
         [else
          (define cached-pt (hash-ref SC2-LAST-KNOWN-ENEMY-POS target-id #f))
          (define fallback-pt
            (cond
              [(pair? cached-pt)
               (sc2-point2d (car cached-pt) (cdr cached-pt))]
              [(and (>= (length rest) 2) (real? (first rest)) (real? (second rest)))
               (sc2-point2d (scale-bot-coord-to-world (first rest) home-x)
                            (scale-bot-coord-to-world (second rest) home-y))]
              [else
               (sc2-point2d (- SC2-DEFAULT-MAP-WIDTH home-x)
                            (- SC2-DEFAULT-MAP-HEIGHT home-y))]))
          (define tag-list (claim-combat-tags-for-order! uid 23 fallback-pt 0))
          (when (not (null? tag-list))
            (emit! (sc2-raw-unit-command 23 fallback-pt 0 tag-list #f)))])]

      [(list 'mineral-walk uid patch-id raw-x raw-y)
       (define tx (scale-bot-coord-to-world raw-x home-x))
       (define ty (scale-bot-coord-to-world raw-y home-y))
       (define wlist (valid-non-builder-worker-tags uid))
       (when (not (null? wlist))
         (for ([wt (in-list wlist)])
           (record-worker-used! wt)
           (set-add! commanded-combat-tags wt))
         (cond
           [(and (exact-integer? patch-id) (> patch-id 0))
            (define need-cmd
              (filter (lambda (wt)
                        (not (unit-already-executing-order? wt 3666 #f patch-id)))
                      wlist))
            (when (not (null? need-cmd))
              (emit! (mark-urgent-survival-cmd!
                      (sc2-raw-unit-command 3666 #f patch-id need-cmd #f))))]
           [else
            (define target-pt (sc2-point2d tx ty))
            (define need-cmd
              (filter (lambda (wt)
                        (not (unit-already-executing-order? wt 16 target-pt 0)))
                      wlist))
            (when (not (null? need-cmd))
              (emit! (mark-urgent-survival-cmd!
                      (sc2-raw-unit-command 16 target-pt 0 need-cmd #f))))]))]

      [(list 'mineral-walk uid raw-x raw-y)
       (define tx (scale-bot-coord-to-world raw-x home-x))
       (define ty (scale-bot-coord-to-world raw-y home-y))
       (define best-min-tag
         (cond
           [(not (null? mineral-fields))
            (sc2-unit-tag
             (argmin (lambda (m)
                       (define mp (sc2-unit-pos m))
                       (pt-dist tx ty (sc2-point3d-x mp) (sc2-point3d-y mp)))
                     mineral-fields))]
           [(not (null? hash-mineral-patches))
            (hash-ref
             (argmin (lambda (m)
                       (pt-dist tx ty
                                (exact->inexact (hash-ref m 'x home-x))
                                (exact->inexact (hash-ref m 'y home-y))))
                     hash-mineral-patches)
             'id 0)]
           [else 0]))
       (cond
         [(> best-min-tag 0)
          (define wlist (valid-non-builder-worker-tags uid))
          (when (not (null? wlist))
            (for ([wt (in-list wlist)])
              (record-worker-used! wt)
              (set-add! commanded-combat-tags wt))
            (define need-cmd
              (filter (lambda (wt)
                        (not (unit-already-executing-order? wt 3666 #f best-min-tag)))
                      wlist))
            (when (not (null? need-cmd))
              (emit! (mark-urgent-survival-cmd!
                      (sc2-raw-unit-command 3666 #f best-min-tag need-cmd #f)))))]
         [else
          (define target-pt (sc2-point2d tx ty))
          (define wlist (valid-non-builder-worker-tags uid))
          (when (not (null? wlist))
            (for ([wt (in-list wlist)])
              (record-worker-used! wt)
              (set-add! commanded-combat-tags wt))
            (define need-cmd
              (filter (lambda (wt)
                        (not (unit-already-executing-order? wt 16 target-pt 0)))
                      wlist))
            (when (not (null? need-cmd))
              (emit! (mark-urgent-survival-cmd!
                      (sc2-raw-unit-command 16 target-pt 0 need-cmd #f)))))])]

      [(list (or 'move 'kite 'retreat 'worker-harass 'multi-prong-drop) uid raw-x raw-y)
       (define tx (scale-bot-coord-to-world raw-x home-x))
       (define ty (scale-bot-coord-to-world raw-y home-y))
       (define target-pt (sc2-point2d tx ty))
       (define tag-list (claim-combat-tags-for-order! uid 16 target-pt 0))
       (when (not (null? tag-list))
         (emit! (sc2-raw-unit-command 16 target-pt 0 tag-list #f)))]

      [(list 'hold-position uid rest ...)
       (define candidates
         (filter (lambda (t)
                   (define u (and (exact-integer? t) (hash-ref self-unit-by-tag t #f)))
                   (and (exact-integer? t)
                        (> t 0)
                        (not (set-member? commanded-combat-tags t))
                        (not (set-member? used-producer-tags t))
                        (not (set-member? used-worker-tags t))
                        (not (and u (worker-has-build-order? u cur-loop self-structures)))
                        (not (unit-has-protected-order? t))))
                 (if (list? uid) uid (list uid))))
       (for ([t (in-list candidates)])
         (set-add! commanded-combat-tags t))
       (cond
         [(and (>= (length rest) 2) (real? (first rest)) (real? (second rest)))
          (define tx (scale-bot-coord-to-world (first rest) home-x))
          (define ty (scale-bot-coord-to-world (second rest) home-y))
          (define target-pt (sc2-point2d tx ty))
          (define move-then-hold-tags '())
          (define hold-now-tags '())
          (for ([t (in-list candidates)])
            (define u (hash-ref self-unit-by-tag t #f))
            (cond
              [(and u (> (pt-dist tx ty (sc2-point3d-x (sc2-unit-pos u)) (sc2-point3d-y (sc2-unit-pos u))) 0.65))
               (unless (unit-already-executing-order? t 16 target-pt 0)
                 (set! move-then-hold-tags (cons t move-then-hold-tags)))]
              [else
               (unless (unit-already-executing-order? t 18 #f 0)
                 (set! hold-now-tags (cons t hold-now-tags)))]))
          (when (not (null? move-then-hold-tags))
            (define mtags (reverse move-then-hold-tags))
            (emit! (sc2-raw-unit-command 16 target-pt 0 mtags #f))
            (emit! (sc2-raw-unit-command 18 #f 0 mtags #t)))
          (when (not (null? hold-now-tags))
            (emit! (sc2-raw-unit-command 18 #f 0 (reverse hold-now-tags) #f)))]
         [else
          (define hold-tags
            (filter (lambda (t) (not (unit-already-executing-order? t 18 #f 0))) candidates))
          (when (not (null? hold-tags))
            (emit! (sc2-raw-unit-command 18 #f 0 hold-tags #f)))])]

      [(list (or 'cancel 'cancel-building) uid)
       #:when (exact-integer? uid)
       (emit! (sc2-raw-unit-command 314 #f 0 (list uid) #f))]

      [(list 'patrol uid raw-x raw-y)
       (when (and (real? raw-x) (real? raw-y))
         (define tx (scale-bot-coord-to-world raw-x home-x))
         (define ty (scale-bot-coord-to-world raw-y home-y))
         (define target-pt (sc2-point2d tx ty))
         (define tag-list (claim-combat-tags-for-order! uid 17 target-pt 0))
         (when (not (null? tag-list))
           (emit! (sc2-raw-unit-command 17 target-pt 0 tag-list #f))))]

      [(list 'baneling-explode raw-uid)
       (define blist
         (remove-duplicates
          (filter (lambda (t) (and (exact-integer? t) (> t 0)))
                  (if (list? raw-uid) raw-uid (list raw-uid)))))
       (when (not (null? blist))
         (for ([t (in-list blist)])
           (set-add! commanded-combat-tags t))
         (emit! (mark-urgent-survival-cmd! (sc2-raw-unit-command 42 #f 0 blist #f))))]

      [(list 'widow-mine-retarget uid target-id)
       (when (and (exact-integer? uid) (> uid 0)
                  (exact-integer? target-id) (> target-id 0)
                  (or (not enforce-live-enemy-tag-filter?)
                      (set-member? live-visible-enemy-tags target-id)))
         (set-add! commanded-combat-tags uid)
         (unless (unit-already-executing-order? uid 2099 #f target-id)
           (emit! (sc2-raw-unit-command 2099 #f target-id (list uid) #f))))]

      [(list 'purification-nova uid raw-x raw-y)
       (when (and (exact-integer? uid) (> uid 0) (real? raw-x) (real? raw-y))
         (define u (hash-ref self-unit-by-tag uid #f))
         (define phased? (and u (= (sc2-unit-unit-type u) 733)))
         (define ab-id (if phased? 16 2346))
         (define tx (scale-bot-coord-to-world raw-x home-x))
         (define ty (scale-bot-coord-to-world raw-y home-y))
         (define target-pt (sc2-point2d tx ty))
         (unless phased?
           (set-add! commanded-combat-tags uid))
         (unless (unit-already-executing-order? uid ab-id target-pt 0)
           (emit! (sc2-raw-unit-command ab-id target-pt 0 (list uid) #f))))]

      [(list 'locust-swoop uid raw-x raw-y)
       (when (and (exact-integer? uid) (> uid 0) (real? raw-x) (real? raw-y))
         (define tx (scale-bot-coord-to-world raw-x home-x))
         (define ty (scale-bot-coord-to-world raw-y home-y))
         (define target-pt (sc2-point2d tx ty))
         (set-add! commanded-combat-tags uid)
         (unless (unit-already-executing-order? uid 2706 target-pt 0)
           (emit! (sc2-raw-unit-command 2706 target-pt 0 (list uid) #f))))]

      ;; W17-P0-2-wire (`#17` 143s & `#11` 55s freeze defense-in-depth): NEVER mark routine Bunker
      ;; Salvage (`32`) as P0 urgent survival! Require an empty completed Bunker (cargo == 0), skip
      ;; if already salvaging, and enforce a 112-loop (5s) per-Bunker wire cooldown so repeated
      ;; `(salvage bid)` intents can NEVER burn APM headroom or starve P1 macro!
      [(list (or 'salvage 'salvage-bunker) bid)
       (when (and (exact-integer? bid) (> bid 0))
         (define bu (hash-ref self-unit-by-tag bid #f))
         (when (and (or (not bu)
                        (and (= (sc2-unit-unit-type bu) 24)
                             (>= (sc2-unit-build-progress bu) SC2-BUILD-COMPLETE-PROGRESS)
                             (= (sc2-unit-cargo-space-taken bu) 0)))
                    (not (unit-already-executing-order? bid 32 #f 0))
                    (wire-nonstack-allow?! (list 'wire-salvage bid) 112))
           (emit! (sc2-raw-unit-command 32 #f 0 (list bid) #f))))]

      [(list 'repair scv-id target-id)
       (when (and (exact-integer? scv-id) (> scv-id 0)
                  (exact-integer? target-id) (> target-id 0))
         (record-worker-used! scv-id)
         (unless (unit-already-executing-order? scv-id 3685 #f target-id)
           (emit! (sc2-raw-unit-command 3685 #f target-id (list scv-id) #f))))]

      [(list (or 'shield-battery-restore 'shield-battery-recharge) bat-id target-id)
       (when (and (exact-integer? bat-id) (> bat-id 0)
                  (exact-integer? target-id) (> target-id 0))
         (unless (unit-already-executing-order? bat-id 4113 #f target-id)
           (emit! (sc2-raw-unit-command 4113 #f target-id (list bat-id) #f))))]

      [(list 'bunker-load bid raw-uid)
       (when (and (exact-integer? bid) (> bid 0))
         (define b-u (hash-ref self-unit-by-tag bid #f))
         (define bunker-ready-with-room?
           (or (not b-u)
               (and (>= (sc2-unit-build-progress b-u) SC2-BUILD-COMPLETE-PROGRESS)
                    (or (<= (sc2-unit-cargo-space-max b-u) 0)
                        (< (sc2-unit-cargo-space-taken b-u) (sc2-unit-cargo-space-max b-u))))))
         (when bunker-ready-with-room?
           (define pax-tags
             (if b-u
                 (for/seteqv ([p (in-list (sc2-unit-passengers b-u))])
                   (sc2-passenger-unit-tag p))
                 (seteqv)))
           (define ulist
             (filter (lambda (u)
                       (and (exact-integer? u) (> u 0)
                            (not (= bid u))
                            (not (set-member? pax-tags u))))
                     (if (list? raw-uid) raw-uid (list raw-uid))))
           (for ([u (in-list ulist)])
             (record-unit-used! u)
             (emit! (mark-urgent-survival-cmd! (sc2-raw-unit-command 407 #f u (list bid) #f))))))]

      [(list 'bunker-unload bid _ ...)
       (when (and (exact-integer? bid) (> bid 0))
         (emit! (mark-urgent-survival-cmd! (sc2-raw-unit-command 408 #f 0 (list bid) #f))))]

      [(list 'nydus-load net-id uid)
       (when (and (exact-integer? net-id) (> net-id 0)
                  (exact-integer? uid) (> uid 0)
                  (not (= net-id uid)))
         (define net-u (hash-ref self-unit-by-tag net-id #f))
         (define ab-id (if (and net-u (= (sc2-unit-unit-type net-u) 142)) 2370 1437))
         (record-unit-used! uid)
         (emit! (sc2-raw-unit-command ab-id #f uid (list net-id) #f)))]

      [(list 'nydus-unload net-id _ ...)
       (when (and (exact-integer? net-id) (> net-id 0))
         (define net-u (hash-ref self-unit-by-tag net-id #f))
         (define ab-id (if (and net-u (= (sc2-unit-unit-type net-u) 142)) 2371 1438))
         (emit! (sc2-raw-unit-command ab-id #f 0 (list net-id) #f)))]

      [(or (list* 'load-unit tr-id ptag _rest)
           (list* 'load-transport tr-id ptag _rest))
       (when (and (exact-integer? tr-id) (> tr-id 0)
                  (exact-integer? ptag) (> ptag 0)
                  (not (= ptag tr-id))
                  (not (passenger-protected-channeling-safe? ptag)))
         (record-unit-used! tr-id)
         (record-unit-used! ptag)
         (emit! (sc2-raw-unit-command 3668 #f ptag (list tr-id) #f)))]

      [(list* (or 'unload-unit 'unload-all-at) tr-id rest)
       (when (and (exact-integer? tr-id) (> tr-id 0))
         (record-unit-used! tr-id)
         (define tr-u (hash-ref self-unit-by-tag tr-id #f))
         (define tr-utype (if tr-u (sc2-unit-unit-type tr-u) 0))
         (define unload-ab-id
           (cond
             [(= tr-utype 54) 396]
             [(or (= tr-utype 81) (= tr-utype 136)) 913]
             [(= tr-utype 893) 1408]
             [else 3669]))
         (if (and (>= (length rest) 2) (real? (first rest)) (real? (second rest)))
             (emit! (sc2-raw-unit-command
                     unload-ab-id
                     (sc2-point2d (scale-bot-coord-to-world (first rest) home-x)
                                  (scale-bot-coord-to-world (second rest) home-y))
                     0 (list tr-id) #f))
             (emit! (sc2-raw-unit-command unload-ab-id #f tr-id (list tr-id) #f))))]

      [(list 'spine-crawler-uproot uid)
       (when (and (exact-integer? uid) (> uid 0))
         (emit! (sc2-raw-unit-command 1725 #f 0 (list uid) #f)))]

      [(list 'spore-crawler-uproot uid)
       (when (and (exact-integer? uid) (> uid 0))
         (emit! (sc2-raw-unit-command 1727 #f 0 (list uid) #f)))]

      [(list 'uproot uid)
       (when (and (exact-integer? uid) (> uid 0))
         (define u (hash-ref self-unit-by-tag uid #f))
         (define ab-id
           (case (and u (sc2-unit-unit-type u))
             [(98 139) 1725]
             [(99 140) 1727]
             [else 3681]))
         (emit! (sc2-raw-unit-command ab-id #f 0 (list uid) #f)))]

      [(list 'spine-crawler-root uid raw-x raw-y)
       (when (and (exact-integer? uid) (> uid 0) (real? raw-x) (real? raw-y))
         (emit! (sc2-raw-unit-command
                 1729
                 (sc2-point2d (scale-bot-coord-to-world raw-x home-x)
                              (scale-bot-coord-to-world raw-y home-y))
                 0 (list uid) #f)))]

      [(list 'spore-crawler-root uid raw-x raw-y)
       (when (and (exact-integer? uid) (> uid 0) (real? raw-x) (real? raw-y))
         (emit! (sc2-raw-unit-command
                 1731
                 (sc2-point2d (scale-bot-coord-to-world raw-x home-x)
                              (scale-bot-coord-to-world raw-y home-y))
                 0 (list uid) #f)))]

      [(list 'root uid raw-x raw-y)
       (when (and (exact-integer? uid) (> uid 0) (real? raw-x) (real? raw-y))
         (define u (hash-ref self-unit-by-tag uid #f))
         (define ab-id
           (case (and u (sc2-unit-unit-type u))
             [(98 139) 1729]
             [(99 140) 1731]
             [else 3680]))
         (emit! (sc2-raw-unit-command
                 ab-id
                 (sc2-point2d (scale-bot-coord-to-world raw-x home-x)
                              (scale-bot-coord-to-world raw-y home-y))
                 0 (list uid) #f)))]

      [(list 'push-probe-with-building pid bldg-sym raw-wx raw-wy raw-sx raw-sy)
       (when (and (exact-integer? pid) (> pid 0)
                  (real? raw-wx) (real? raw-wy) (real? raw-sx) (real? raw-sy))
         (define norm (normalize-sc2-name->symbol bldg-sym))
         (define ab-id (or (build-symbol->ability-id norm) 881))
         (define wx (scale-bot-coord-to-world raw-wx home-x))
         (define wy (scale-bot-coord-to-world raw-wy home-y))
         (define sx (scale-bot-coord-to-world raw-sx home-x))
         (define sy (scale-bot-coord-to-world raw-sy home-y))
         (define u (hash-ref self-unit-by-tag pid #f))
         (unless (or (set-member? used-worker-tags pid)
                     (set-member? builder-worker-tags pid)
                     (and u (worker-has-build-order? u cur-loop self-structures)))
           (record-worker-used! pid)
           (set-add! builder-worker-tags pid)
           (record-step-built-structure! norm)
           (define bpt (sc2-point2d wx wy))
           (reserve-step-build-pt! bpt ab-id)
           (define d-bldg
             (if u
                 (let ([up (sc2-unit-pos u)])
                   (pt-dist wx wy (sc2-point3d-x up) (sc2-point3d-y up)))
                 0.0))
           (cond
             [(< d-bldg 1.5)
              (emit! (mark-urgent-survival-cmd!
                      (sc2-raw-unit-command 16 (sc2-point2d sx sy) 0 (list pid) #f)))
              (emit! (sc2-raw-unit-command ab-id bpt 0 (list pid) #t))]
             [else
              (emit! (sc2-raw-unit-command ab-id bpt 0 (list pid) #f))])))]

      ;; 7. Queen Inject Larva: `(inject-larva <queen-id> <hatch-id>)`
      [(list 'inject-larva queen-id hatch-id)
       (when (and (exact-integer? queen-id) (> queen-id 0)
                  (exact-integer? hatch-id) (> hatch-id 0))
         (set-add! commanded-combat-tags queen-id)
         (unless (unit-has-protected-order? queen-id)
           (emit! (sc2-raw-unit-command 251 #f hatch-id (list queen-id) #f))))]

      ;; 8. Spells: `(cast <caster-id-or-ids> <spell-sym> ...)` or `(cast-spell <caster-id-or-ids> <spell-sym> ...)`
      ;;    Enforces canonical SC2 ability target mode (Target.None / Target.Point / Target.Unit)
      ;;    and verifies creep tumor placement & MULE mineral patch targets.
      [(list (or 'cast 'cast-spell) raw-caster-id spell-sym rest ...)
       (define caster-ids
         (remove-duplicates
          (filter (lambda (t) (and (exact-integer? t) (> t 0)))
                  (if (list? raw-caster-id) raw-caster-id (list raw-caster-id)))))
       (when (not (null? caster-ids))
         (define caster-id (first caster-ids))
         (define norm-spell (normalize-sc2-name->symbol spell-sym))
         (define caster-u (hash-ref self-unit-by-tag caster-id #f))
         (define caster-utype (if caster-u (sc2-unit-unit-type caster-u) 0))
         (define ab-id
           (cond
             [(memq norm-spell '(spread-creep-tumor spawn-creep-tumor build-creep-tumor))
              (if (and caster-u (memq (sc2-id->unit-symbol caster-utype)
                                      '(creep-tumor creep-tumor-burrowed creep-tumor-queen)))
                  1733  ;; BUILD_CREEPTUMOR_TUMOR (marked in used-tumors ONLY after verified placement!)
                  1694)] ;; BUILD_CREEPTUMOR_QUEEN
             [(and (memq norm-spell '(burrow widow-mine-burrow))
                   (or (= caster-utype 498) (= caster-utype 500)))
              2095] ;; BURROWDOWN_WIDOWMINE
             [(and (memq norm-spell '(unburrow widow-mine-unburrow))
                   (or (= caster-utype 498) (= caster-utype 500)))
              2097] ;; BURROWUP_WIDOWMINE
             [(and (memq norm-spell '(burrow lurker-burrow))
                   (or (= caster-utype 502) (= caster-utype 503)))
              2108] ;; BURROWDOWN_LURKER
             [(and (memq norm-spell '(unburrow lurker-unburrow))
                   (or (= caster-utype 502) (= caster-utype 503)))
              2110] ;; BURROWUP_LURKER
             [else (spell-symbol->ability-id norm-spell)]))
         (when ab-id
           ;; Off-GCD instant 0-cast-point buffs do NOT lock the unit out of attacking/kiting on the same frame
           (define off-gcd-buff?
             (memq norm-spell
                   '(stimpack stim stim-marine stim-marauder
                     cloak-banshee cloak-ghost decloak-ghost
                     medivac-boost guardian-shield
                     hallucination-phoenix hallucination-archon
                     immortal-barrier prismatic-alignment
                     build-interceptors pulsar-beam pulsar-beam-on pulsar-beam-off)))
           (unless (or off-gcd-buff? (memv ab-id '(1766 181 403 405 2146 2350 2588 3741 3745)))
             (for ([cid (in-list caster-ids)])
               (set-add! commanded-combat-tags cid)))
           (cond
             ;; Case A: Ability requires NO target (Stimpack, Guardian Shield, Siege/Unsiege, Burrow, Cloak, Build Interceptors, Pulsar Beam, etc.)
             [(set-member? SC2-NO-TARGET-ABILITY-IDS ab-id)
              (cond
                [(= ab-id 1766)
                 (when (>= (length caster-ids) 2)
                   (define chosen2 (take caster-ids 2))
                   (define u1 (hash-ref self-unit-by-tag (first chosen2) #f))
                   (define u2 (hash-ref self-unit-by-tag (second chosen2) #f))
                   (when (cond
                           [(and u1 u2) (sc2-archon-merge-pair-safe? u1 u2 enemy-units)]
                           [(null? self-units) #t]
                           [else #f])
                     (for ([cid (in-list chosen2)])
                       (set-add! commanded-combat-tags cid))
                     (emit! (sc2-raw-unit-command 1766 #f 0 chosen2 #f))))]
                ;; W12-P0-3-wire (`w12-tac-3`): Dedupe Viking Fighter/Assault morphs (`405`/`403`) to <= 1/unit/step
                [(memv ab-id '(403 405))
                 (emit-viking-morph-deduped! ab-id caster-ids)]
                ;; W12-P0-3-wire (`w12-tac-4`): Dedupe Void Ray Prismatic Alignment (`2393`) to <= 1/unit/step
                [(= ab-id 2393)
                 (define fresh-vrs
                   (filter (lambda (cid) (not (set-member? emitted-prismatic-tags cid))) caster-ids))
                 (when (pair? fresh-vrs)
                   (for ([cid (in-list fresh-vrs)])
                     (set-add! emitted-prismatic-tags cid))
                   (emit! (sc2-raw-unit-command 2393 #f 0 fresh-vrs #f)))]
                ;; W11-P0-4-wire (`w11-tac-4`): NEVER immobilize an Overseer (3745) or Observer (3741)
                ;; into stationary mode while an uncovered cloaked/burrowed threat needs mobile detection!
                [(memv ab-id '(3741 3745))
                 (unless uncovered-stealth-present?
                   (for ([cid (in-list caster-ids)])
                     (set-add! commanded-combat-tags cid))
                   (emit! (sc2-raw-unit-command ab-id #f 0 caster-ids #f)))]
                ;; Mode-toggle hysteresis cooldown (>= 44 game loops; 66 loops clear before unburrowing WidowMine)
                [(memv ab-id '(388 390 2095 2097))
                 (define ready-ids
                   (filter (lambda (cid)
                             (and (>= cur-loop (hash-ref SC2-MODE-TOGGLE-COOLDOWN cid -1))
                                  (or (not (= ab-id 2097))
                                      (let ([cs (hash-ref SC2-MINE-CLEAR-SINCE-LOOP cid #f)])
                                        (or (not cs) (>= (- cur-loop cs) 66))))))
                           caster-ids))
                 (when (pair? ready-ids)
                   (for ([cid (in-list ready-ids)])
                     (hash-set! SC2-MODE-TOGGLE-COOLDOWN cid (+ cur-loop 44))
                     (cond
                       [(= ab-id 2095) (hash-set! SC2-MINE-CLEAR-SINCE-LOOP cid cur-loop)]
                       [(= ab-id 2097) (hash-remove! SC2-MINE-CLEAR-SINCE-LOOP cid)]))
                   (emit! (sc2-raw-unit-command ab-id #f 0 ready-ids #f)))]
                [(memv ab-id '(556 558))
                 (define ready-ids
                   (filter (lambda (cid)
                             (>= cur-loop (hash-ref SC2-DEPOT-TOGGLE-COOLDOWN cid 0)))
                           caster-ids))
                 (when (pair? ready-ids)
                   (for ([cid (in-list ready-ids)])
                     (hash-set! SC2-DEPOT-TOGGLE-COOLDOWN cid (+ cur-loop 44)))
                   (emit! (sc2-raw-unit-command ab-id #f 0 ready-ids #f)))]
                [(= ab-id 181)
                 (unless uncovered-stealth-present?
                   (for ([cid (in-list caster-ids)])
                     (set-add! commanded-combat-tags cid))
                   (emit-spawn-changeling-deduped! caster-ids))]
                [else
                 (emit! (sc2-raw-unit-command ab-id #f 0 caster-ids #f))])]

             ;; Case B: Creep Tumor placement (verified creep, passable, unblocked, energy >= 25, off cooldown)
             ;; W5-P0-1a-wire: Throttle BEFORE building nearby-blockers/fan-cands (<= 1 tumor placement/step,
             ;; <= 1 tumor RPC per 8 game loops, compact <= 16 fan probes) so late-Zerg tr stays < 4.5ms!
             [(memv ab-id '(1662 1694 1733 3691))
              (define queen-cast? (memv ab-id '(1662 1694 3691)))
              (define tumor-ready?
                (and (< step-tumor-placement-count 1)
                     (not (unit-has-protected-order? caster-id))
                     (>= (- cur-loop (hash-ref SC2-CREEP-TUMOR-COOLDOWN caster-id -9999))
                         (if queen-cast? 24 44))
                     (or (not queen-cast?)
                         (not caster-u)
                         (>= (sc2-unit-energy caster-u) 25.0))))
              (when tumor-ready?
                (define raw-x (if (>= (length rest) 2) (first rest) home-x))
                (define raw-y (if (>= (length rest) 2) (second rest) home-y))
                (define tx (scale-bot-coord-to-world raw-x home-x))
                (define ty (scale-bot-coord-to-world raw-y home-y))
                (define-values (ox oy)
                  (if caster-u
                      (let ([cp (sc2-unit-pos caster-u)])
                        (values (sc2-point3d-x cp) (sc2-point3d-y cp)))
                      (values tx ty)))
                (define tumor-ws-active? (and (sc2-ws-conn? ws-conn) (not (sc2-ws-conn-closed? ws-conn))))
                (define tumor-cache-key
                  (and tumor-ws-active?
                       (list ab-id
                             (inexact->exact (round (* 0.5 ox)))
                             (inexact->exact (round (* 0.5 oy)))
                             (inexact->exact (round (* 0.5 tx)))
                             (inexact->exact (round (* 0.5 ty))))))
                (define tumor-cache-entry
                  (and tumor-cache-key
                       (let ([entry (hash-ref SC2-TUMOR-PLACEMENT-CACHE tumor-cache-key #f)])
                         (and (pair? entry)
                              (>= cur-loop (car entry))
                              (< (- cur-loop (car entry)) SC2-PLACEMENT-CACHE-TTL)
                              entry))))
                (define tumor-cached-neg?
                  (and tumor-cache-entry (not (cadr tumor-cache-entry))))
                (define tumor-cached-raw-pos
                  (and tumor-cache-entry
                       (sc2-point2d? (cadr tumor-cache-entry))
                       (cadr tumor-cache-entry)))
                (define last-tumor-rpc-l (unbox SC2-LAST-TUMOR-RPC-LOOP))
                (define tumor-rpc-window-open?
                  (and (< step-tumor-rpc-count 1)
                       (> (unbox step-placement-rpc-budget) 0)
                       (or (< cur-loop last-tumor-rpc-l)
                           (>= (- cur-loop last-tumor-rpc-l) 8))))
                ;; Skip ALL fan/blocker work immediately on negative cache hit or when RPC window is closed!
                (when (and (not tumor-cached-neg?)
                           (or (not tumor-ws-active?)
                               tumor-cached-raw-pos
                               tumor-rpc-window-open?))
                  (set! step-tumor-placement-count (add1 step-tumor-placement-count))
                  (define base-ang
                    (let ([dx (- tx ox)]
                          [dy (- ty oy)])
                      (if (< (+ (* dx dx) (* dy dy)) 0.25)
                          (atan (- (* 0.5 SC2-DEFAULT-MAP-HEIGHT) oy)
                                (- (* 0.5 SC2-DEFAULT-MAP-WIDTH) ox))
                          (atan dy dx))))
                  (define nearby-blockers
                    (for/list ([bc (in-list blocking-unit-circles)]
                               #:when (let ([dx (- ox (vector-ref bc 0))]
                                            [dy (- oy (vector-ref bc 1))])
                                        (and (<= (abs dx) 14.5)
                                             (<= (abs dy) 14.5)
                                             (<= (+ (* dx dx) (* dy dy)) 210.25))))
                      bc))
                  (define (point-on-creep? px py)
                    (cond
                      [step-creep-grid (image-grid-pixel-set? step-creep-grid px py)]
                      [(pair? creep-source-circles)
                       (for/or ([cs (in-list creep-source-circles)])
                         (define dx (- px (vector-ref cs 0)))
                         (define dy (- py (vector-ref cs 1)))
                         (define r (vector-ref cs 2))
                         (and (<= (abs dx) r)
                              (<= (abs dy) r)
                              (<= (+ (* dx dx) (* dy dy)) (* r r))))]
                      [else (null? self-units)]))
                  (define (tumor-cand-clear? px py)
                    (and (>= px SC2-MAP-PLAYABLE-MIN-COORD) (<= px SC2-MAP-PLAYABLE-MAX-COORD)
                         (>= py SC2-MAP-PLAYABLE-MIN-COORD) (<= py SC2-MAP-PLAYABLE-MAX-COORD)
                         (or (not step-path-grid) (image-grid-pixel-set? step-path-grid px py))
                         (or (not step-pl-grid) (image-grid-pixel-set? step-pl-grid px py))
                         (point-on-creep? px py)
                         (for/and ([ep (in-list all-expansion-pads)])
                           (>= (max (abs (- px (car ep))) (abs (- py (cdr ep)))) 4.5))
                         (for/and ([rp (in-list step-reserved-build-pts)]
                                   #:when (any-point? rp))
                           (> (pt-dist px py (any-point-x rp) (any-point-y rp)) 1.5))
                         (for/and ([bc (in-list nearby-blockers)])
                           (define dx (- px (vector-ref bc 0)))
                           (define dy (- py (vector-ref bc 1)))
                           (define mr (+ 0.75 (max 0.5 (vector-ref bc 2))))
                           (> (+ (* dx dx) (* dy dy)) (* mr mr)))))
                  (define tumor-cached-pos
                    (and tumor-cached-raw-pos
                         (or (not (= ab-id 1733))
                             (<= (pt-dist ox oy (sc2-point2d-x tumor-cached-raw-pos) (sc2-point2d-y tumor-cached-raw-pos)) 10.5))
                         (tumor-cand-clear? (sc2-point2d-x tumor-cached-raw-pos) (sc2-point2d-y tumor-cached-raw-pos))
                         tumor-cached-raw-pos))
                  (define verified-tumor-pt
                    (cond
                      [tumor-cached-pos tumor-cached-pos]
                      [else
                       (define stx (+ (floor tx) 0.5))
                       (define sty (+ (floor ty) 0.5))
                       (define target-cand
                         (if (and (or (not (= ab-id 1733)) (<= (pt-dist ox oy stx sty) 10.0))
                                  (tumor-cand-clear? stx sty))
                             (list (sc2-point2d stx sty))
                             '()))
                       ;; Compact <= 16 candidate fan (3 radii x 5 angles + target-cand)
                       (define fan-cands
                         (append
                          target-cand
                          (if (= ab-id 1733)
                              (for*/list ([r (in-list '(9.5 8.0 6.5))]
                                          [da (in-list '(0.0 0.35 -0.35 0.78 -0.78))]
                                          [px (in-value (+ (floor (+ ox (* r (cos (+ base-ang da))))) 0.5))]
                                          [py (in-value (+ (floor (+ oy (* r (sin (+ base-ang da))))) 0.5))]
                                          #:when (tumor-cand-clear? px py))
                                (sc2-point2d px py))
                              (for*/list ([r (in-list '(3.5 2.5 4.2))]
                                          [da (in-list '(0.0 0.78 -0.78 1.57 -1.57))]
                                          [px (in-value (+ (floor (+ ox (* r (cos (+ base-ang da))))) 0.5))]
                                          [py (in-value (+ (floor (+ oy (* r (sin (+ base-ang da))))) 0.5))]
                                          #:when (tumor-cand-clear? px py))
                                (sc2-point2d px py)))))
                       (define dedup-fan
                         (let ([seen (make-hash)])
                           (filter (lambda (pt)
                                     (define k (cons (sc2-point2d-x pt) (sc2-point2d-y pt)))
                                     (if (hash-has-key? seen k) #f (begin (hash-set! seen k #t) #t)))
                                   fan-cands)))
                       (define capped-fan (if (> (length dedup-fan) 16) (take dedup-fan 16) dedup-fan))
                       (cond
                         [(null? capped-fan) #f]
                         [tumor-ws-active?
                          (cond
                            [(and tumor-rpc-window-open?
                                  (consume-placement-rpc-budget! step-placement-rpc-budget))
                             (set! step-tumor-rpc-count (add1 step-tumor-rpc-count))
                             (set-box! SC2-LAST-TUMOR-RPC-LOOP cur-loop)
                             (define q-items
                               (for/list ([pt (in-list capped-fan)])
                                 (sc2-query-placement ab-id (sc2-point2d-x pt) (sc2-point2d-y pt) 0)))
                             (define q-resp
                               (sc2-ws-rpc! ws-conn
                                            (make-request-query-placement q-items
                                                                          #:ignore-resource-requirements? #t)))
                             (define q-results (sc2-response-query-placements q-resp))
                             (define found-pt
                               (for/first ([pt (in-list capped-fan)]
                                           [res (in-list q-results)]
                                           #:when (= res 1))
                                 pt))
                             (when tumor-cache-key
                               (when (> (hash-count SC2-TUMOR-PLACEMENT-CACHE) 512)
                                 (hash-clear! SC2-TUMOR-PLACEMENT-CACHE))
                               (hash-set! SC2-TUMOR-PLACEMENT-CACHE tumor-cache-key (list cur-loop found-pt)))
                             found-pt]
                            [else #f])]
                         [else (first capped-fan)])]))
                  (when verified-tumor-pt
                    (reserve-step-build-pt! verified-tumor-pt ab-id)
                    (for ([cid (in-list caster-ids)])
                      (hash-set! SC2-CREEP-TUMOR-COOLDOWN cid cur-loop))
                    (when (and (= ab-id 1733) (set-mutable? used-tumors))
                      (for ([cid (in-list caster-ids)])
                        (set-add! used-tumors cid)))
                    (emit! (sc2-raw-unit-command ab-id verified-tumor-pt 0 caster-ids #f)))))]

             ;; Case C: Orbital Command Calldown MULE (171) -> resolve ONLY to safe friendly-base mineral field tag (P1 macro-econ!)
             [(= ab-id 171)
              (cond
                [(not (null? townhalls))
                 (define safe-min-tag (pick-safe-mule-mineral-patch caster-u self-units mineral-fields enemy-units))
                 (when (and (exact-integer? safe-min-tag) (> safe-min-tag 0))
                   (for ([cid (in-list caster-ids)])
                     (hash-set! SC2-MACRO-ABILITY-LAST-LOOP (cons 'mule cid) cur-loop))
                   (emit! (mark-macro-econ-cmd! (sc2-raw-unit-command ab-id #f safe-min-tag caster-ids #f))))]
                [else
                 (define arg-tag (if (pair? rest) (first rest) 0))
                 (define valid-min?
                   (and (exact-integer? arg-tag)
                        (ormap (lambda (m) (= (sc2-unit-tag m) arg-tag)) mineral-fields)))
                 (define resolved-min-tag
                   (cond
                     [valid-min? arg-tag]
                     [(not (null? mineral-fields))
                      (sc2-unit-tag
                       (argmin (lambda (m)
                                 (define mp (sc2-unit-pos m))
                                 (pt-dist home-x home-y (sc2-point3d-x mp) (sc2-point3d-y mp)))
                               mineral-fields))]
                     [(and (exact-integer? arg-tag) (> arg-tag 0)) arg-tag]
                     [else 0]))
                 (when (> resolved-min-tag 0)
                   (for ([cid (in-list caster-ids)])
                     (hash-set! SC2-MACRO-ABILITY-LAST-LOOP (cons 'mule cid) cur-loop))
                   (emit! (mark-macro-econ-cmd! (sc2-raw-unit-command ab-id #f resolved-min-tag caster-ids #f))))])]

             ;; Case C2: Nydus Worm (1768) -> must be cast ONLY by a completed Nydus Network (unit-type = 95), NEVER a worker
             [(= ab-id 1768)
              (define nydus-actor-id
                (cond
                  [(and caster-u (= caster-utype 95)) caster-id]
                  [(not (null? self-units))
                   (for/first ([u (in-list (hash-ref self-units-by-sym 'nydus-network '()))]
                               #:when (and (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)
                                           (not (set-member? used-producer-tags (sc2-unit-tag u)))))
                     (sc2-unit-tag u))]
                  [else caster-id]))
              (when (and nydus-actor-id (>= (length rest) 2)
                         (real? (first rest)) (real? (second rest)))
                (set-add! used-producer-tags nydus-actor-id)
                (define tx (scale-bot-coord-to-world (first rest) home-x))
                (define ty (scale-bot-coord-to-world (second rest) home-y))
                (emit! (sc2-raw-unit-command 1768 (sc2-point2d tx ty) 0 (list nydus-actor-id) #f)))]

             ;; Case D: Point-target ability (Blink, Force Field, Psi Storm, Corrosive Bile, EMP, Scanner Sweep, Phase Shift, Purification Nova, Stasis Ward)
             [(set-member? SC2-POINT-TARGET-ABILITY-IDS ab-id)
              (define-values (tx ty)
                (cond
                  [(and (>= (length rest) 2) (real? (first rest)) (real? (second rest)))
                   (values (scale-bot-coord-to-world (first rest) home-x)
                           (scale-bot-coord-to-world (second rest) home-y))]
                  [(and (= (length rest) 1) (exact-integer? (first rest)))
                   (define tid (first rest))
                   (define tu (hash-ref all-unit-by-tag tid #f))
                   (if tu
                       (let ([p (sc2-unit-pos tu)])
                         (values (sc2-point3d-x p) (sc2-point3d-y p)))
                       (values home-x home-y))]
                  [else (values home-x home-y)]))
              (cond
                [(= ab-id 399)
                 (for ([cid (in-list caster-ids)])
                   (hash-set! SC2-MACRO-ABILITY-LAST-LOOP (cons 'mule cid) cur-loop))
                 (emit-scanner-sweep-deduped! caster-ids tx ty)]
                [(= ab-id 2146)
                 (emit-oracle-revelation-deduped! caster-ids tx ty)]
                [(= ab-id 2588)
                 (define fresh-reapers
                   (filter (lambda (cid) (not (set-member? emitted-kd8-tags cid))) caster-ids))
                 (when (pair? fresh-reapers)
                   (for ([cid (in-list fresh-reapers)])
                     (set-add! emitted-kd8-tags cid)
                     (set-add! commanded-combat-tags cid))
                   (emit! (sc2-raw-unit-command 2588 (sc2-point2d tx ty) 0 fresh-reapers #f)))]
                [else
                 (emit! (sc2-raw-unit-command ab-id (sc2-point2d tx ty) 0 caster-ids #f))])]

             ;; Case E: Unit-target ability (Inject Larva, Chrono Boost, Transfusion, Feedback, Snipe, Yamato, Abduct, Neural Parasite, Repair, etc.)
             ;;         NEVER fall back to TargetNone (0) — if target-id <= 0, drop cleanly!
             [(set-member? SC2-UNIT-TARGET-ABILITY-IDS ab-id)
              (unless (and (= ab-id 251) (unit-has-protected-order? caster-id))
                (define target-id (if (pair? rest) (first rest) 0))
                (cond
                  [(= ab-id 2350)
                   (when (and (exact-integer? target-id) (> target-id 0))
                     (emit-cyclone-lock-on-deduped! caster-ids target-id))]
                  [(and (exact-integer? target-id) (> target-id 0)
                        (not (and (memv ab-id '(394 911 1406 3668))
                                  (passenger-protected-channeling-safe? target-id))))
                   (define eff-cids
                     (if (memv ab-id '(295 298 1183 3666))
                         (filter (lambda (cid)
                                   (define cu (hash-ref self-unit-by-tag cid #f))
                                   (not (and cu (worker-busy-harvesting-mineral? cu target-id mineral-by-tag gas-bldg-tags-set mineral-fields))))
                                 caster-ids)
                         caster-ids))
                   (when (pair? eff-cids)
                     (define raw-u-cmd (sc2-raw-unit-command ab-id #f target-id eff-cids #f))
                     (when (memv ab-id '(3755 3686 4107))
                       (for ([cid (in-list eff-cids)])
                         (hash-set! SC2-MACRO-ABILITY-LAST-LOOP (cons 'chrono cid) cur-loop)))
                     (when (= ab-id 3755)
                       (hash-set! SC2-MACRO-ABILITY-LAST-LOOP (cons 'chrono-tgt target-id) cur-loop)
                       (mark-macro-econ-cmd! raw-u-cmd))
                     (when (= ab-id 257)
                       (for ([cid (in-list eff-cids)])
                         (hash-set! SC2-MACRO-ABILITY-LAST-LOOP (cons 'mule cid) cur-loop)))
                     (emit! raw-u-cmd))]))]

             [else (void)])))]

      ;; 9. Anti-cheese & Pro-mechanics
      [(list 'pull-workers-attack worker-ids target-id raw-x raw-y)
       (define tx (scale-bot-coord-to-world raw-x home-x))
       (define ty (scale-bot-coord-to-world raw-y home-y))
       (define wlist (valid-non-builder-worker-tags worker-ids))
       (when (not (null? wlist))
         (for ([wt (in-list wlist)])
           (record-worker-used! wt)
           (set-add! commanded-combat-tags wt))
         (define valid-unit-tgt?
           (and (exact-integer? target-id)
                (> target-id 0)
                (or (not enforce-live-enemy-tag-filter?)
                    (set-member? live-visible-enemy-tags target-id))))
         (define eff-tgt-id (if valid-unit-tgt? target-id 0))
         (define target-pt (if valid-unit-tgt? #f (sc2-point2d tx ty)))
         (define need-cmd
           (filter (lambda (wt)
                     (not (unit-already-executing-order? wt 23 target-pt eff-tgt-id)))
                   wlist))
         (when (not (null? need-cmd))
           (emit! (sc2-raw-unit-command 23 target-pt eff-tgt-id need-cmd #f))))]

      [(list 'pull-workers-attack worker-ids raw-x raw-y)
       (define tx (scale-bot-coord-to-world raw-x home-x))
       (define ty (scale-bot-coord-to-world raw-y home-y))
       (define target-pt (sc2-point2d tx ty))
       (define wlist (valid-non-builder-worker-tags worker-ids))
       (when (not (null? wlist))
         (for ([wt (in-list wlist)])
           (record-worker-used! wt)
           (set-add! commanded-combat-tags wt))
         (define need-cmd
           (filter (lambda (wt)
                     (not (unit-already-executing-order? wt 23 target-pt 0)))
                   wlist))
         (when (not (null? need-cmd))
           (emit! (sc2-raw-unit-command 23 target-pt 0 need-cmd #f))))]

      [(list 'worker-drill-stack-attack worker-ids patch-id target-id raw-x raw-y)
       (define tx (scale-bot-coord-to-world raw-x home-x))
       (define ty (scale-bot-coord-to-world raw-y home-y))
       (define wlist
         (filter (lambda (t)
                   (and (not (set-member? commanded-combat-tags t))
                        (not (set-member? used-producer-tags t))))
                 (valid-non-builder-worker-tags worker-ids)))
       (when (not (null? wlist))
         (define eff-patch-id
           (cond
             [(and (exact-integer? patch-id) (> patch-id 0))
              (if (and (not (null? mineral-fields))
                       (not (ormap (lambda (m) (= (sc2-unit-tag m) patch-id)) mineral-fields)))
                  (sc2-unit-tag
                   (argmin (lambda (m)
                             (define mp (sc2-unit-pos m))
                             (pt-dist tx ty (sc2-point3d-x mp) (sc2-point3d-y mp)))
                           mineral-fields))
                  patch-id)]
             [else 0]))
         (define patch-u
           (and (> eff-patch-id 0)
                (for/first ([m (in-list mineral-fields)]
                            #:when (= (sc2-unit-tag m) eff-patch-id))
                  m)))
         (define-values (px py patch-known?)
           (if patch-u
               (let ([pp (sc2-unit-pos patch-u)])
                 (values (sc2-point3d-x pp) (sc2-point3d-y pp) #t))
               (values tx ty #f)))
         ;; Never mineral-walk workers when enemy stack is near TownHall / far from `drill-patch-id`!
         (define target-near-patch?
           (or (not patch-known?)
               (<= (pt-dist tx ty px py) 4.0)))
         (define enemy-combat-pts
           (for/list ([eu (in-list enemy-units)]
                      #:when (not (sc2-unit-is-structure? eu)))
             (define ep (sc2-unit-pos eu))
             (cons (sc2-point3d-x ep) (sc2-point3d-y ep))))
         (define drill-wids '())
         (define strike-wids '())
         (for ([wid (in-list wlist)])
           (record-worker-used! wid)
           (set-add! commanded-combat-tags wid)
           (define-values (wx wy)
             (cond
               [(hash-ref self-unit-by-tag wid #f)
                => (lambda (u)
                     (define p (sc2-unit-pos u))
                     (values (sc2-point3d-x p) (sc2-point3d-y p)))]
               [(hash-ref hash-ally-by-id wid #f)
                => (lambda (u)
                     (values (exact->inexact (hash-ref u 'x home-x))
                             (exact->inexact (hash-ref u 'y home-y))))]
               [else (values home-x home-y)]))
           (define worker-near-patch?
             (or (not patch-known?)
                 (<= (pt-dist wx wy px py) 6.5)))
           (define in-melee-range?
             (or (<= (pt-dist wx wy tx ty) 2.0)
                 (for/or ([ep (in-list enemy-combat-pts)])
                   (<= (pt-dist wx wy (car ep) (cdr ep)) 2.0))))
           (if (and (> eff-patch-id 0)
                    target-near-patch?
                    worker-near-patch?
                    (not in-melee-range?)
                    (> (pt-dist wx wy tx ty) 2.0))
               (set! drill-wids (cons wid drill-wids))
               (set! strike-wids (cons wid strike-wids))))
         (define need-drill
           (filter (lambda (wid)
                     (not (unit-already-executing-order? wid 3666 #f eff-patch-id)))
                   (reverse drill-wids)))
         (when (not (null? need-drill))
           (emit! (mark-urgent-survival-cmd!
                   (sc2-raw-unit-command 3666 #f eff-patch-id need-drill #f))))
         (define valid-unit-tgt?
           (and (exact-integer? target-id)
                (> target-id 0)
                (or (not enforce-live-enemy-tag-filter?)
                    (set-member? live-visible-enemy-tags target-id))))
         (define eff-tgt-id (if valid-unit-tgt? target-id 0))
         (define target-pt (if valid-unit-tgt? #f (sc2-point2d tx ty)))
         (define need-strike
           (filter (lambda (wid)
                     (not (unit-already-executing-order? wid 23 target-pt eff-tgt-id)))
                   (reverse strike-wids)))
         (when (not (null? need-strike))
           (emit! (mark-urgent-survival-cmd!
                   (sc2-raw-unit-command 23 target-pt eff-tgt-id need-strike #f)))))]

      [(list 'harvest-mineral wid patch-id)
       (define wlist
         (filter (lambda (t)
                   (define u (and (exact-integer? t) (hash-ref self-unit-by-tag t #f)))
                   (define uh (and (exact-integer? t) (hash-ref hash-ally-by-id t #f)))
                   (define already-harvesting-or-building?
                     (or (and u (worker-has-build-order? u cur-loop self-structures))
                         (and uh (hash-ref uh 'has-build-order? #f))
                         (and u (worker-busy-harvesting-mineral? u patch-id mineral-by-tag gas-bldg-tags-set mineral-fields))))
                   (and (exact-integer? t)
                        (> t 0)
                        (not (set-member? used-worker-tags t))
                        (not already-harvesting-or-building?)))
                 (if (list? wid) wid (list wid))))
       (define eff-patch-id
         (cond
           [(and (exact-integer? patch-id)
                 (hash-has-key? mineral-by-tag patch-id))
            patch-id]
           [(not (null? mineral-fields))
            (sc2-unit-tag
             (argmin (lambda (m)
                       (define mp (sc2-unit-pos m))
                       (pt-dist home-x home-y (sc2-point3d-x mp) (sc2-point3d-y mp)))
                     mineral-fields))]
           [(and (exact-integer? patch-id) (> patch-id 0)) patch-id]
           [else 0]))
       (when (and (not (null? wlist)) (> eff-patch-id 0))
         (for ([wt (in-list wlist)])
           (record-worker-used! wt))
         (emit! (sc2-raw-unit-command 3666 #f eff-patch-id wlist #f)))]

      [(list 'harvest-gas wid gas-id)
       (define wlist
         (filter (lambda (t)
                   (define u (and (exact-integer? t) (hash-ref self-unit-by-tag t #f)))
                   (define uh (and (exact-integer? t) (hash-ref hash-ally-by-id t #f)))
                   (define already-busy?
                     (or (and u (worker-has-build-order? u cur-loop self-structures))
                         (and uh (hash-ref uh 'has-build-order? #f))
                         (and u (worker-carrying-cargo? u))
                         (and u
                              (pair? (sc2-unit-orders u))
                              (memv (sc2-unit-order-ability-id (first (sc2-unit-orders u)))
                                    '(295 296 298 299 1183 1184 3666 3667)))))
                   (and (exact-integer? t)
                        (> t 0)
                        (not (set-member? used-worker-tags t))
                        (not already-busy?)))
                 (if (list? wid) wid (list wid))))
       (define gas-bldgs completed-gas-buildings)
       (define eff-gas-id
         (cond
           [(and (exact-integer? gas-id)
                 (ormap (lambda (g) (= (sc2-unit-tag g) gas-id)) gas-bldgs))
            gas-id]
           [(not (null? gas-bldgs))
            (sc2-unit-tag (first gas-bldgs))]
           [(and (exact-integer? gas-id) (> gas-id 0) (null? self-units))
            gas-id]
           [else 0]))
       (when (and (not (null? wlist)) (> eff-gas-id 0))
         (for ([wt (in-list wlist)])
           (record-worker-used! wt))
         (emit! (sc2-raw-unit-command 3666 #f eff-gas-id wlist #f)))]

      [(list 'worker-scout wid raw-x raw-y)
       (when (and (exact-integer? wid) (> wid 0))
         (define u (hash-ref self-unit-by-tag wid #f))
         (define uh (hash-ref hash-ally-by-id wid #f))
         (define tx (scale-bot-coord-to-world raw-x home-x))
         (define ty (scale-bot-coord-to-world raw-y home-y))
         (define suppress-rush-cross-map-scout?
           (and enemy-combat-near-own-base?
                (> (pt-dist home-x home-y tx ty) 50.0)
                (or (not u)
                    (let ([up (sc2-unit-pos u)])
                      (<= (pt-dist home-x home-y (sc2-point3d-x up) (sc2-point3d-y up)) 24.0)))))
         (unless (or suppress-rush-cross-map-scout?
                     (set-member? commanded-combat-tags wid)
                     (set-member? used-worker-tags wid)
                     (set-member? builder-worker-tags wid)
                     (and u (worker-has-build-order? u cur-loop self-structures))
                     (and uh (hash-ref uh 'has-build-order? #f)))
           (record-worker-used! wid)
           (define target-pt (sc2-point2d tx ty))
           (unless (unit-already-executing-order? wid 16 target-pt 0)
             (emit! (sc2-raw-unit-command 16 target-pt 0 (list wid) #f)))))]

      [(list 'overlord-scout oid raw-x raw-y)
       (when (and (exact-integer? oid) (> oid 0))
         (record-unit-used! oid)
         (define tx (scale-bot-coord-to-world raw-x home-x))
         (define ty (scale-bot-coord-to-world raw-y home-y))
         (define target-pt (sc2-point2d tx ty))
         (unless (unit-already-executing-order? oid 16 target-pt 0)
           (emit! (sc2-raw-unit-command 16 target-pt 0 (list oid) #f))))]

      [(list 'periodic-scout uid raw-x raw-y)
       (when (and (exact-integer? uid) (> uid 0))
         (define u (hash-ref self-unit-by-tag uid #f))
         (define uh (hash-ref hash-ally-by-id uid #f))
         (define is-worker?
           (or (and u (sc2-unit-is-worker? u))
               (and uh (memq (hash-ref uh 'type 'unknown) '(drone probe scv)))))
         (define tx (scale-bot-coord-to-world raw-x home-x))
         (define ty (scale-bot-coord-to-world raw-y home-y))
         (define suppress-rush-worker-scout?
           (and is-worker?
                enemy-combat-near-own-base?
                (> (pt-dist home-x home-y tx ty) 50.0)
                (or (not u)
                    (let ([up (sc2-unit-pos u)])
                      (<= (pt-dist home-x home-y (sc2-point3d-x up) (sc2-point3d-y up)) 24.0)))))
         (unless (or suppress-rush-worker-scout?
                     (set-member? commanded-combat-tags uid)
                     (unit-has-protected-order? uid)
                     (and is-worker?
                          (or (set-member? used-worker-tags uid)
                              (set-member? builder-worker-tags uid)
                              (and u (worker-has-build-order? u cur-loop self-structures))
                              (and uh (hash-ref uh 'has-build-order? #f)))))
           (if is-worker?
               (record-worker-used! uid)
               (record-unit-used! uid))
           (define target-pt (sc2-point2d tx ty))
           (unless (unit-already-executing-order? uid 16 target-pt 0)
             (emit! (sc2-raw-unit-command 16 target-pt 0 (list uid) #f)))))]

      [(list 'mineral-harass wid raw-ex raw-ey raw-exp-x raw-exp-y)
       (when (and (exact-integer? wid) (> wid 0))
         (define u (hash-ref self-unit-by-tag wid #f))
         (define uh (hash-ref hash-ally-by-id wid #f))
         (define already-used-nonbuilder?
           (and (set-member? used-worker-tags wid)
                (not (set-member? builder-worker-tags wid))))
         (unless (or (set-member? builder-worker-tags wid)
                     (and u (worker-has-build-order? u cur-loop self-structures))
                     (and uh (hash-ref uh 'has-build-order? #f)))
           (define ex (scale-bot-coord-to-world raw-ex home-x))
           (define ey (scale-bot-coord-to-world raw-ey home-y))
           (define exp-x (scale-bot-coord-to-world raw-exp-x home-x))
           (define exp-y (scale-bot-coord-to-world raw-exp-y home-y))
           (define-values (wx wy whp)
             (cond
               [u (let ([p (sc2-unit-pos u)])
                    (values (sc2-point3d-x p) (sc2-point3d-y p)
                            (+ (sc2-unit-health u) (sc2-unit-shield u))))]
               [uh (values (exact->inexact (hash-ref uh 'x ex))
                           (exact->inexact (hash-ref uh 'y ey))
                           (exact->inexact (hash-ref uh 'hp 40.0)))]
               [else (values ex ey 40.0)]))
           ;; Find enemy mineral patch near enemy base for pro mineral-walk worker phasing & mining disruption
           (define enemy-min-patch
             (and (not (null? mineral-fields))
                  (let ([near-mins
                         (filter (lambda (m)
                                   (define mp (sc2-unit-pos m))
                                   (<= (pt-dist ex ey (sc2-point3d-x mp) (sc2-point3d-y mp)) 18.0))
                                 mineral-fields)])
                    (and (not (null? near-mins))
                         (argmax (lambda (m)
                                   (define mp (sc2-unit-pos m))
                                   (pt-dist wx wy (sc2-point3d-x mp) (sc2-point3d-y mp)))
                                 near-mins)))))
           ;; Find exposed enemy buildingSCV / worker near enemy base
           (define exposed-enemy-worker
             (for/first ([e (in-list enemy-units)]
                         #:when (and (sc2-unit-is-worker? e)
                                     (let ([ep (sc2-unit-pos e)])
                                       (<= (pt-dist wx wy (sc2-point3d-x ep) (sc2-point3d-y ep)) 8.0))))
               e))
           (define home-min-patch
             (and (not (null? mineral-fields))
                  (let ([h-mins
                         (filter (lambda (m)
                                   (define mp (sc2-unit-pos m))
                                   (<= (pt-dist home-x home-y (sc2-point3d-x mp) (sc2-point3d-y mp)) 12.0))
                                 mineral-fields)])
                    (and (not (null? h-mins))
                         (argmin (lambda (m)
                                   (define mp (sc2-unit-pos m))
                                   (pt-dist home-x home-y (sc2-point3d-x mp) (sc2-point3d-y mp)))
                                 h-mins)))))
           (when (or (not already-used-nonbuilder?)
                     (< whp 25.0)
                     exposed-enemy-worker
                     (and enemy-min-patch (<= (pt-dist wx wy ex ey) 22.0)))
             (record-worker-used! wid)
             (cond
               ;; Low HP scout (< 25 HP): mineral-walk HOME to our own mineral patch (never into enemy mineral line!)
               [(< whp 25.0)
                (if home-min-patch
                    (let ([hmtag (sc2-unit-tag home-min-patch)])
                      (unless (unit-already-executing-order? wid 3666 #f hmtag)
                        (emit! (sc2-raw-unit-command 3666 #f hmtag (list wid) #f))))
                    (let ([hpt (sc2-point2d home-x home-y)])
                      (unless (unit-already-executing-order? wid 16 hpt 0)
                        (emit! (sc2-raw-unit-command 16 hpt 0 (list wid) #f)))))]
               ;; Otherwise if an exposed enemy worker/builder is within 8 tiles and our scout is healthy, poke it!
               [exposed-enemy-worker
                (define etag (sc2-unit-tag exposed-enemy-worker))
                (unless (unit-already-executing-order? wid 23 #f etag)
                  (emit! (sc2-raw-unit-command 23 #f etag (list wid) #f)))]
               ;; Otherwise if enemy mineral patch is visible, mineral-walk to disrupt mineral line!
               [enemy-min-patch
                (define mtag (sc2-unit-tag enemy-min-patch))
                (unless (unit-already-executing-order? wid 3666 #f mtag)
                  (emit! (sc2-raw-unit-command 3666 #f mtag (list wid) #f)))]
               ;; Otherwise orbit between enemy main and enemy natural expansion
               [else
                (define dest-pt
                  (if (<= (pt-dist wx wy ex ey) 7.0)
                      (sc2-point2d exp-x exp-y)
                      (sc2-point2d ex ey)))
                (unless (unit-already-executing-order? wid 16 dest-pt 0)
                  (emit! (sc2-raw-unit-command 16 dest-pt 0 (list wid) #f)))]))))]

      [(list 'harass-workers raider-ids raw-x raw-y)
       (define tx (scale-bot-coord-to-world raw-x home-x))
       (define ty (scale-bot-coord-to-world raw-y home-y))
       (define target-pt (sc2-point2d tx ty))
       (define rlist
         (let ([all-r (if (list? raider-ids) raider-ids (list raider-ids))])
           (take all-r (min 4 (length all-r)))))
       (define tag-list (claim-combat-tags-for-order! rlist 23 target-pt 0))
       (when (not (null? tag-list))
         (emit! (sc2-raw-unit-command 23 target-pt 0 tag-list #f)))]

      [(list 'patrol-block-expansion bid raw-x raw-y)
       (when (and (exact-integer? bid) (> bid 0))
         (define tx (scale-bot-coord-to-world raw-x home-x))
         (define ty (scale-bot-coord-to-world raw-y home-y))
         (define target-pt (sc2-point2d tx ty))
         (define was-claimed? (set-member? commanded-combat-tags bid))
         (define tag-list (claim-combat-tags-for-order! bid 17 target-pt 0))
         (when (and (not was-claimed?)
                    (set-member? commanded-combat-tags bid))
           (define u (hash-ref self-unit-by-tag bid #f))
           (when (and u (sc2-unit-is-worker? u))
             (record-worker-used! bid)))
         (when (not (null? tag-list))
           (emit! (sc2-raw-unit-command 17 target-pt 0 tag-list #f))))]

      [(list 'burrow-block bid raw-x raw-y)
       (when (and (exact-integer? bid) (> bid 0))
         (record-unit-used! bid)
         (define tx (scale-bot-coord-to-world raw-x home-x))
         (define ty (scale-bot-coord-to-world raw-y home-y))
         (define target-pt (sc2-point2d tx ty))
         (define u (hash-ref self-unit-by-tag bid #f))
         (if (and u
                  (let ([up (sc2-unit-pos u)])
                    (<= (pt-dist tx ty (sc2-point3d-x up) (sc2-point3d-y up)) 2.5)))
             (emit! (sc2-raw-unit-command 3661 #f 0 (list bid) #f))
             (unless (unit-already-executing-order? bid 16 target-pt 0)
               (emit! (sc2-raw-unit-command 16 target-pt 0 (list bid) #f)))))]

      [(list 'cast-deception-and-scout-spells _ ...)
       (define-values (eb-x eb-y)
         (if (and (list? enemy-base) (>= (length enemy-base) 2))
             (values (exact->inexact (first enemy-base))
                     (exact->inexact (second enemy-base)))
             (values (- SC2-DEFAULT-MAP-WIDTH home-x)
                     (- SC2-DEFAULT-MAP-HEIGHT home-y))))
       ;; 1. Sentry Hallucination Phoenix (154) when energy >= 75 and no live enemy combat within 16 tiles (or energy >= 150)
       (define sentry-u
         (for/first ([u (in-list self-units)]
                     #:when (and (= (sc2-unit-unit-type u) 77)
                                 (>= (sc2-unit-energy u) 75.0)
                                 (null? (sc2-unit-orders u))
                                 (not (set-member? commanded-combat-tags (sc2-unit-tag u)))
                                 (or (>= (sc2-unit-energy u) 150.0)
                                     (let ([up (sc2-unit-pos u)])
                                       (not (ormap (lambda (e)
                                                     (and (sc2-unit-targetable-enemy-combat? e)
                                                          (let* ([ep (sc2-unit-pos e)]
                                                                 [dx (- (sc2-point3d-x up) (sc2-point3d-x ep))]
                                                                 [dy (- (sc2-point3d-y up) (sc2-point3d-y ep))])
                                                            (and (<= (abs dx) 16.0) (<= (abs dy) 16.0)
                                                                 (<= (+ (* dx dx) (* dy dy)) 256.0)))))
                                                   enemy-units))))))
           u))
       (when sentry-u
         (record-unit-used! (sc2-unit-tag sentry-u))
         (emit! (sc2-raw-unit-command 154 #f 0 (list (sc2-unit-tag sentry-u)) #f)))
       ;; 2. Overseer Spawn Changeling (181) when energy >= 50 (deduped <= 1 per Overseer per step)
       (define overseer-u
         (for/first ([u (in-list self-units)]
                     #:when (and (= (sc2-unit-unit-type u) 129)
                                 (>= (sc2-unit-energy u) 50.0)
                                 (null? (sc2-unit-orders u))
                                 (not (set-member? emitted-changeling-tags (sc2-unit-tag u)))
                                 (not (set-member? commanded-combat-tags (sc2-unit-tag u)))))
           u))
       (when overseer-u
         (emit-spawn-changeling-deduped! (sc2-unit-tag overseer-u)))
       ;; 3. Idle Observer (82) or Hallucinated/Changeling scout moves toward enemy base
       ;; W10-TAC-6: NEVER overwrite a unit already commanded this step (`commanded-combat-tags` /
       ;; `used-producer-tags`), and NEVER send an Observer (82) cross-map during cloaked/burrowed threats!
       (for ([u (in-list self-units)]
             #:when (let ([utype (sc2-unit-unit-type u)]
                          [utag (sc2-unit-tag u)])
                      (and (memv utype '(82 12 13 14 15 16 17))
                           (null? (sc2-unit-orders u))
                           (not (set-member? commanded-combat-tags utag))
                           (not (set-member? used-producer-tags utag))
                           (not (and (= utype 82) cloaked-or-burrowed-threat-present?)))))
         (define utag (sc2-unit-tag u))
         (record-unit-used! utag)
         (emit! (sc2-raw-unit-command 16 (sc2-point2d eb-x eb-y) 0 (list utag) #f)))
       ;; 4. Orbital Command Scanner Sweep (399) at enemy base when energy >= 125 and 0 enemies visible
       (when (null? enemy-units)
         (define orbital-u
           (for/first ([u (in-list self-units)]
                       #:when (and (= (sc2-unit-unit-type u) 132)
                                   (>= (sc2-unit-energy u) 125.0)
                                   (not (set-member? emitted-scan-oc-tags (sc2-unit-tag u)))))
             u))
         (when orbital-u
           (emit-scanner-sweep-deduped! (sc2-unit-tag orbital-u) eb-x eb-y)))]

      [(list (or 'evacuate-workers-from-stasis-ward
                 'trigger-stasis-ward-single-unit
                 'counter-enemy-worker-drill
                 'stasis-worker-stoppage-compensation
                 'return-workers-to-gather
                 'printf-high-ground-vision-probe
                 'printf-lg-pylon-hg-cannon
                 'printf-rewall-1hex-back
                 'printf-3pylon-ramp-block
                 'printf-assimilator-wedge
                 'printf-robo-immortal-prism-contain
                 'printf-stargate-tempest-battery-contain
                 'printf-battery-contain-leash
                 'printf-prism-contain-pickup
                 'printf-multi-probe-chase
                 'printf-abort-walled-cannon-pull) _ ...)
       (void)]

      [(list 'swap-bunker-builder-scv low-scv fresh-scv bnk-id)
       (when (and (exact-integer? low-scv) (> low-scv 0))
         (record-worker-used! low-scv)
         (emit! (sc2-raw-unit-command 16 (sc2-point2d home-x home-y) 0 (list low-scv) #f)))
       (when (and (exact-integer? fresh-scv) (> fresh-scv 0)
                  (exact-integer? bnk-id) (> bnk-id 0))
         (record-worker-used! fresh-scv)
         (emit! (sc2-raw-unit-command 1 #f bnk-id (list fresh-scv) #f)))]

      [(list 'resume-halted-building scv-id bldg-id)
       (record-worker-used! scv-id)
       (emit! (sc2-raw-unit-command 1 #f bldg-id (list scv-id) #f))]

      [(list 'clear-gas-steal enemy-gas-id raw-x raw-y)
       (define ctags (map sc2-unit-tag combat-units))
       (when (not (null? ctags))
         (if (and (exact-integer? enemy-gas-id)
                  (> enemy-gas-id 0)
                  (or (not enforce-live-enemy-tag-filter?)
                      (set-member? live-visible-enemy-tags enemy-gas-id)))
             (emit! (sc2-raw-unit-command 23 #f enemy-gas-id ctags #f))
             (emit! (sc2-raw-unit-command 23
                                          (sc2-point2d (scale-bot-coord-to-world raw-x home-x)
                                                       (scale-bot-coord-to-world raw-y home-y))
                                          0 ctags #f))))]

      [(list 'snipe-enemy-changeling changeling-id rest ...)
       (define ctags (map sc2-unit-tag (if (not (null? combat-units)) combat-units workers)))
       (when (and (not (null? ctags)) (exact-integer? changeling-id))
         (cond
           [(and (> changeling-id 0)
                 (or (not enforce-live-enemy-tag-filter?)
                     (set-member? live-visible-enemy-tags changeling-id)))
            (emit! (sc2-raw-unit-command 23 #f changeling-id (list (first ctags)) #f))]
           [else
            (define cached-pt (hash-ref SC2-LAST-KNOWN-ENEMY-POS changeling-id #f))
            (define fallback-pt
              (cond
                [(pair? cached-pt)
                 (sc2-point2d (car cached-pt) (cdr cached-pt))]
                [(and (>= (length rest) 2) (real? (first rest)) (real? (second rest)))
                 (sc2-point2d (scale-bot-coord-to-world (first rest) home-x)
                              (scale-bot-coord-to-world (second rest) home-y))]
                [else
                 (sc2-point2d home-x home-y)]))
            (emit! (sc2-raw-unit-command 23 fallback-pt 0 (list (first ctags)) #f))]))]

      [(list 'burrow-down uid rest ...)
       (when (and (exact-integer? uid) (> uid 0))
         (record-unit-used! uid)
         (define explicit-ab
           (for/first ([a (in-list rest)]
                       #:when (and (exact-integer? a) (> a 0)))
             a))
         (define u (hash-ref self-unit-by-tag uid #f))
         (define utype (if u (sc2-unit-unit-type u) 0))
         (define ab-id
           (or explicit-ab
               (case utype
                 [(498 500) 2095]
                 [(502 503) 2108]
                 [else 3661])))
         (emit! (sc2-raw-unit-command ab-id #f 0 (list uid) #f)))]

      [(list 'burrow-up uid rest ...)
       (when (and (exact-integer? uid) (> uid 0))
         (record-unit-used! uid)
         (define explicit-ab
           (for/first ([a (in-list rest)]
                       #:when (and (exact-integer? a) (> a 0)))
             a))
         (define u (hash-ref self-unit-by-tag uid #f))
         (define utype (if u (sc2-unit-unit-type u) 0))
         (define ab-id
           (or explicit-ab
               (case utype
                 [(498 500) 2097]
                 [(502 503) 2110]
                 [else 3662])))
         (emit! (sc2-raw-unit-command ab-id #f 0 (list uid) #f)))]

      [(list (or 'roach-tunnel-move 'infestor-burrow-move) uid raw-x raw-y)
       (when (and (exact-integer? uid) (> uid 0))
         (record-unit-used! uid)
         (emit! (sc2-raw-unit-command 16
                                      (sc2-point2d (scale-bot-coord-to-world raw-x home-x)
                                                   (scale-bot-coord-to-world raw-y home-y))
                                      0 (list uid) #f)))]

      [(list 'infestor-burrow-cast uid 'neural-parasite target-id)
       (when (and (exact-integer? uid) (> uid 0)
                  (exact-integer? target-id) (> target-id 0))
         (record-unit-used! uid)
         (emit! (sc2-raw-unit-command 249 #f target-id (list uid) #f)))]

      [(list 'infestor-burrow-cast uid spell-sym (? real? raw-x) (? real? raw-y))
       (when (and (exact-integer? uid) (> uid 0)
                  (not (eq? spell-sym 'neural-parasite)))
         (record-unit-used! uid)
         (emit! (sc2-raw-unit-command 74
                                      (sc2-point2d (scale-bot-coord-to-world raw-x home-x)
                                                   (scale-bot-coord-to-world raw-y home-y))
                                      0 (list uid) #f)))]

      [(list 'blind-skillshot-shimmer uid spell-sym raw-x raw-y)
       (when (and (exact-integer? uid) (> uid 0))
         (define ability-id
           (case spell-sym
             [(corrosive-bile) 2338]
             [(psi-storm) 1036]
             [(fungal-growth) 74]
             [(purification-nova) 2346]
             [(emp-round) 1628]
             [(scanner-sweep) 399]
             [(oracle-revelation) 2146]
             [else 2338]))
         (define tx (scale-bot-coord-to-world raw-x home-x))
         (define ty (scale-bot-coord-to-world raw-y home-y))
         (cond
           [(= ability-id 399)
            (record-unit-used! uid)
            (emit-scanner-sweep-deduped! uid tx ty)]
           [(= ability-id 2146)
            (emit-oracle-revelation-deduped! uid tx ty)]
           [else
            (record-unit-used! uid)
            (emit! (sc2-raw-unit-command ability-id (sc2-point2d tx ty) 0 (list uid) #f))]))]

      [(list 'emergency-detector-response _ ...)
       (void)]

      [(list 'rebalance-gas-to-minerals wid patch-id)
       (define gas-bldg-tags gas-bldg-tags-set)
       (define wlist
         (filter (lambda (t)
                   (define u (and (exact-integer? t) (hash-ref self-unit-by-tag t #f)))
                   (define uh (and (exact-integer? t) (hash-ref hash-ally-by-id t #f)))
                   (and (exact-integer? t)
                        (> t 0)
                        (not (set-member? used-worker-tags t))
                        (not (and u (worker-has-build-order? u cur-loop self-structures)))
                        (not (and uh (hash-ref uh 'has-build-order? #f)))
                        (or (null? self-units)
                            (and u
                                 (not (worker-carrying-cargo? u))
                                 (ormap (lambda (o)
                                          (set-member? gas-bldg-tags (sc2-unit-order-target-unit-tag o)))
                                        (sc2-unit-orders u))))))
                 (if (list? wid) wid (list wid))))
       (cond
         [(and (not (null? self-units))
               (not (null? wlist))
               (not (null? mineral-fields)))
          (for ([wt (in-list wlist)])
            (define u (hash-ref self-unit-by-tag wt #f))
            (define wp (and u (sc2-unit-pos u)))
            (define best-min
              (argmin (lambda (m)
                        (define mp (sc2-unit-pos m))
                        (pt-dist (if wp (sc2-point3d-x wp) home-x)
                                 (if wp (sc2-point3d-y wp) home-y)
                                 (sc2-point3d-x mp)
                                 (sc2-point3d-y mp)))
                      mineral-fields))
            (record-worker-used! wt)
            (emit! (sc2-raw-unit-command 3666 #f (sc2-unit-tag best-min) (list wt) #f)))]
         [else
          (define eff-patch-id
            (cond
              [(and (exact-integer? patch-id)
                    (hash-has-key? mineral-by-tag patch-id))
               patch-id]
              [(not (null? mineral-fields))
               (sc2-unit-tag
                (argmin (lambda (m)
                          (define mp (sc2-unit-pos m))
                          (pt-dist home-x home-y (sc2-point3d-x mp) (sc2-point3d-y mp)))
                        mineral-fields))]
              [(and (exact-integer? patch-id) (> patch-id 0)) patch-id]
              [else 0]))
          (when (and (not (null? wlist)) (> eff-patch-id 0))
            (for ([wt (in-list wlist)])
              (record-worker-used! wt))
            (emit! (sc2-raw-unit-command 3666 #f eff-patch-id wlist #f)))])]

      [(list 'land-building bldg-id raw-x raw-y)
       (when (and (exact-integer? bldg-id) (> bldg-id 0) (real? raw-x) (real? raw-y))
         (define lx0 (scale-bot-coord-to-world raw-x home-x))
         (define ly0 (scale-bot-coord-to-world raw-y home-y))
         (define bldg-u (hash-ref self-unit-by-tag bldg-id #f))
         (define bsym (and bldg-u (sc2-id->unit-symbol (sc2-unit-unit-type bldg-u))))
         (define land-pt
           (cond
             [(eq? bsym 'barracks-flying)
              (find-verified-building-placement ws-conn 321 lx0 ly0 units
                                                #:min-spacing 3.0 #:max-radius 14.0 #:step 2.0
                                                #:extra-reserved-points step-reserved-build-pts
                                                #:reserved-aabbs reserved-aabbs
                                                #:expansion-pads all-expansion-pads
                                                #:bldg-sym 'barracks
                                                #:game-info eff-game-info
                                                #:rpc-budget step-placement-rpc-budget
                                                #:cur-loop cur-loop)]
             [(eq? bsym 'factory-flying)
              (find-verified-building-placement ws-conn 328 lx0 ly0 units
                                                #:min-spacing 3.0 #:max-radius 14.0 #:step 2.0
                                                #:extra-reserved-points step-reserved-build-pts
                                                #:reserved-aabbs reserved-aabbs
                                                #:expansion-pads all-expansion-pads
                                                #:bldg-sym 'factory
                                                #:game-info eff-game-info
                                                #:rpc-budget step-placement-rpc-budget
                                                #:cur-loop cur-loop)]
             [(eq? bsym 'starport-flying)
              (find-verified-building-placement ws-conn 329 lx0 ly0 units
                                                #:min-spacing 3.0 #:max-radius 14.0 #:step 2.0
                                                #:extra-reserved-points step-reserved-build-pts
                                                #:reserved-aabbs reserved-aabbs
                                                #:expansion-pads all-expansion-pads
                                                #:bldg-sym 'starport
                                                #:game-info eff-game-info
                                                #:rpc-budget step-placement-rpc-budget
                                                #:cur-loop cur-loop)]
             [(memq bsym '(command-center-flying orbital-command-flying))
              (if (> (pt-dist home-x home-y lx0 ly0) SC2-BASE-RESOURCE-RADIUS)
                  (find-best-expansion-placement ws-conn 318 home-x home-y units
                                                 #:req-x lx0 #:req-y ly0
                                                 #:game-info eff-game-info
                                                 #:remembered-enemies SC2-LAST-KNOWN-ENEMY-POS
                                                 #:rpc-budget step-placement-rpc-budget
                                                 #:cur-loop cur-loop)
                  (find-verified-building-placement ws-conn 318 lx0 ly0 units
                                                    #:min-spacing 4.5 #:max-radius 12.0 #:step 1.0
                                                    #:extra-reserved-points step-reserved-build-pts
                                                    #:reserved-aabbs reserved-aabbs
                                                    #:bldg-sym 'command-center
                                                    #:game-info eff-game-info
                                                    #:rpc-budget step-placement-rpc-budget
                                                    #:cur-loop cur-loop))]
             [else (sc2-point2d lx0 ly0)]))
         (when (sc2-point2d? land-pt)
           (reserve-step-build-pt! land-pt (case bsym
                                             [(barracks-flying) 321]
                                             [(factory-flying) 328]
                                             [(starport-flying) 329]
                                             [else 0]))
           (emit! (sc2-raw-unit-command 3678 land-pt 0 (list bldg-id) #f))))]

      [(list 'terran-addon-swap lift-bldg-id land-bldg-id addon-x addon-y)
       (when (and (exact-integer? lift-bldg-id) (> lift-bldg-id 0))
         (emit! (sc2-raw-unit-command 3679 #f 0 (list lift-bldg-id) #f)))
       (when (and (exact-integer? land-bldg-id) (> land-bldg-id 0)
                  (real? addon-x) (real? addon-y))
         (define land-u (hash-ref self-unit-by-tag land-bldg-id #f))
         (if (and (= lift-bldg-id 0)
                  land-u
                  (not (sc2-unit-is-flying land-u))
                  (not (memq (sc2-id->unit-symbol (sc2-unit-unit-type land-u))
                             '(barracks-flying factory-flying starport-flying command-center-flying orbital-command-flying))))
             (emit! (sc2-raw-unit-command 3679 #f 0 (list land-bldg-id) #f))
             (emit! (sc2-raw-unit-command 3678
                                          (sc2-point2d (- (exact->inexact addon-x) 2.5)
                                                       (+ (exact->inexact addon-y) 0.5))
                                          0 (list land-bldg-id) #f))))]

      [(list 'swap-addon lift-bldg-id land-bldg-id)
       (when (and (exact-integer? lift-bldg-id) (> lift-bldg-id 0))
         (emit! (sc2-raw-unit-command 3679 #f 0 (list lift-bldg-id) #f)))
       (when (and (exact-integer? land-bldg-id) (> land-bldg-id 0))
         (define lift-u (and (exact-integer? lift-bldg-id) (hash-ref self-unit-by-tag lift-bldg-id #f)))
         (define land-u (hash-ref self-unit-by-tag land-bldg-id #f))
         (define land-flying?
           (and land-u
                (or (sc2-unit-is-flying land-u)
                    (memq (sc2-id->unit-symbol (sc2-unit-unit-type land-u))
                          '(barracks-flying factory-flying starport-flying command-center-flying orbital-command-flying)))))
         (cond
           [(and land-flying? lift-u)
            (define lp (sc2-unit-pos lift-u))
            (emit! (sc2-raw-unit-command 3678
                                         (sc2-point2d (sc2-point3d-x lp) (sc2-point3d-y lp))
                                         0 (list land-bldg-id) #f))]
           [else
            (emit! (sc2-raw-unit-command 3679 #f 0 (list land-bldg-id) #f))]))]

      ;; 10. Spatial maneuvers: `(execute-spatial-maneuver <name> <x> <y>)` or `(mirror-spatial-maneuver ...)`
      ;;     Bug #11 fix: never overwrite units that already received individual micro orders in this step,
      ;;     exclude Queens and units currently engaged in local combat within 16 tiles of an enemy,
      ;;     and prevent 1-by-1 reinforcement streaming ("conga line of death") by requiring units near
      ;;     home (`<= 48` tiles) to gather into a wave of `>= SC2-ATTACK-WAVE-MIN-COMBAT-UNITS` before
      ;;     marching across the map.
      [(or (list (or 'execute-spatial-maneuver 'mirror-spatial-maneuver) maneuver-sym raw-x raw-y)
           (and (list 'execute-spatial-maneuver (? real? raw-x) (? real? raw-y) (? real? _) (? real? _))
                (app (lambda (_) 'multiprong-rotate-and-pin) maneuver-sym)))
       (define tx0 (scale-bot-coord-to-world raw-x home-x))
       (define ty0 (scale-bot-coord-to-world raw-y home-y))
       (define targetable-enemies-now targetable-enemy-units)
       (define ignore-phantom-pullback?
         (and (eq? maneuver-sym 'pre-rotate-intercept-incoming-threat)
              sweep-context-active?))
       (define eff-maneuver-sym
         (if ignore-phantom-pullback?
             'multiprong-rotate-and-pin
             maneuver-sym))
       (define defensive-maneuver-now?
         (or explicit-hold-or-suppress?
             (and (not ignore-phantom-pullback?)
                  (not (null? townhalls))
                  (or (defensive-spatial-maneuver-sym? eff-maneuver-sym)
                      (point-on-home-side? tx0 ty0)))))
       (define-values (eb-x eb-y)
         (if (and (list? enemy-base) (>= (length enemy-base) 2))
             (values (exact->inexact (first enemy-base))
                     (exact->inexact (second enemy-base)))
             (values tx0 ty0)))
       (define home-staged-combat-sp
         (filter (lambda (u)
                   (define up (sc2-unit-pos u))
                   (<= (pt-dist home-x home-y (sc2-point3d-x up) (sc2-point3d-y up)) 48.0))
                 combat-units))
       (define home-staged-supply-sp
         (for/sum ([u (in-list home-staged-combat-sp)])
           (max 1 (sc2-supply-cost (sc2-id->unit-symbol (sc2-unit-unit-type u))))))
       (define home-wave-ready-sp?
         (or (>= (length home-staged-combat-sp) SC2-ATTACK-WAVE-MIN-COMBAT-UNITS)
             (>= home-staged-supply-sp 16)
             (and (>= cur-loop 6000)
                  (null? enemy-units)
                  verified-endgame-map-state?
                  (>= (length home-staged-combat-sp) 2))
             (null? townhalls)))
       (cond
         [defensive-maneuver-now?
          ;; Respect Layer 3/4 hold / defend / suppress-attack / staging posture:
          ;; NEVER scatter cross-map or push past our defensive rally point!
          (define-values (def-tx def-ty)
            (if (and explicit-hold-or-suppress?
                     (not (defensive-spatial-maneuver-sym? eff-maneuver-sym))
                     (not (point-on-home-side? tx0 ty0)))
                (values eff-hold-x eff-hold-y)
                (values tx0 ty0)))
          (define def-target-pt (sc2-point2d def-tx def-ty))
          (define def-eligible
            (filter (lambda (u)
                      (define up (sc2-unit-pos u))
                      (and (not (set-member? commanded-combat-tags (sc2-unit-tag u)))
                           (not (eq? (sc2-id->unit-symbol (sc2-unit-unit-type u)) 'queen))
                           (not (ormap (lambda (e)
                                         (define ep (sc2-unit-pos e))
                                         (<= (pt-dist (sc2-point3d-x up) (sc2-point3d-y up)
                                                      (sc2-point3d-x ep) (sc2-point3d-y ep))
                                             16.0))
                                       enemy-units))))
                    combat-units))
          (define (already-at-or-moving-to-def? u)
            (define up (sc2-unit-pos u))
            (or (<= (pt-dist def-tx def-ty (sc2-point3d-x up) (sc2-point3d-y up)) 8.0)
                (and (pair? (sc2-unit-orders u))
                     (let* ([o (first (sc2-unit-orders u))]
                            [ab (sc2-unit-order-ability-id o)]
                            [tp (sc2-unit-order-target-pos o)])
                       (and (memq (sc2-canonical-order-ability ab) '(attack move))
                            (any-point? tp)
                            (<= (pt-dist def-tx def-ty (any-point-x tp) (any-point-y tp)) 8.0))))))
          (for ([u (in-list def-eligible)]
                #:when (already-at-or-moving-to-def? u))
            (set-add! commanded-combat-tags (sc2-unit-tag u)))
          (define mobile-needs-def
            (filter (lambda (u)
                      (and (not (already-at-or-moving-to-def? u))
                           (not (memv (sc2-unit-unit-type u) '(32 500 503)))))
                    def-eligible))
          (define ctags
            (claim-combat-tags-for-order! (map sc2-unit-tag mobile-needs-def) 23 def-target-pt 0))
          (when (not (null? ctags))
            (emit! (sc2-raw-unit-command 23 def-target-pt 0 ctags #f)))]
         [else
          (define eligible-combat
            (filter (lambda (u)
                      (define up (sc2-unit-pos u))
                      (define near-home?
                        (<= (pt-dist home-x home-y (sc2-point3d-x up) (sc2-point3d-y up)) 48.0))
                      (and (not (set-member? commanded-combat-tags (sc2-unit-tag u)))
                           (not (eq? (sc2-id->unit-symbol (sc2-unit-unit-type u)) 'queen))
                           (or (not near-home?) home-wave-ready-sp?)
                           (not (ormap (lambda (e)
                                         (define ep (sc2-unit-pos e))
                                         (<= (pt-dist (sc2-point3d-x up) (sc2-point3d-y up)
                                                      (sc2-point3d-x ep) (sc2-point3d-y ep))
                                             16.0))
                                       enemy-units))))
                    combat-units))
          (when (and (not (null? eligible-combat))
                     (or can-push-or-sweep? (null? townhalls)))
            (cond
              [(and (null? targetable-enemies-now)
                    sweep-context-active?
                    (not (eq? eff-maneuver-sym 'pre-rotate-intercept-incoming-threat)))
               (emit-fan-out-sweep! eligible-combat eb-x eb-y)]
              [else
               (define-values (tx ty)
                 (if (and (not (null? targetable-enemies-now))
                          (not (eq? eff-maneuver-sym 'pre-rotate-intercept-incoming-threat)))
                     (let* ([nearest-e
                             (argmin (lambda (e)
                                       (define ep (sc2-unit-pos e))
                                       (pt-dist home-x home-y (sc2-point3d-x ep) (sc2-point3d-y ep)))
                                     targetable-enemies-now)]
                            [ep (sc2-unit-pos nearest-e)])
                       (values (sc2-point3d-x ep) (sc2-point3d-y ep)))
                     (values tx0 ty0)))
               (define target-pt (sc2-point2d tx ty))
               (define (already-moving-to-target? u)
                 (and (pair? (sc2-unit-orders u))
                      (let* ([o (first (sc2-unit-orders u))]
                             [ab (sc2-unit-order-ability-id o)]
                             [tp (sc2-unit-order-target-pos o)])
                        (and (eq? (sc2-canonical-order-ability ab) 'attack)
                             (any-point? tp)
                             (<= (pt-dist tx ty (any-point-x tp) (any-point-y tp)) 8.0)))))
               (for ([u (in-list eligible-combat)]
                     #:when (already-moving-to-target? u))
                 (set-add! commanded-combat-tags (sc2-unit-tag u)))
               (define needs-order-combat
                 (filter (lambda (u) (not (already-moving-to-target? u))) eligible-combat))
               (emit-unroot-for-push! needs-order-combat)
               (define mobile-needs-order
                 (filter (lambda (u) (not (memv (sc2-unit-unit-type u) '(32 500 503))))
                         needs-order-combat))
               (define ctags
                 (claim-combat-tags-for-order! (map sc2-unit-tag mobile-needs-order) 23 target-pt 0))
               (when (not (null? ctags))
                 (emit! (sc2-raw-unit-command 23 target-pt 0 ctags #f)))]))])]

      ;; 10b. Pro Anti-Splash Pre-Split 3-Wing, Concave Arc, and Inside-Aura Splash-Spread Translation
      [(list 'pre-split-wings lx ly mx my rx ry)
       (define splash-enemy-near?
         (ormap (lambda (e)
                  (define esym (sc2-id->unit-symbol (sc2-unit-unit-type e)))
                  (and (memq esym '(baneling siege-tank siege-tank-sieged colossus
                                    lurker lurker-burrowed widow-mine widow-mine-burrowed
                                    disruptor disruptor-phased high-templar archon
                                    hellion hellbat thor ultralisk ravager))
                       (let ([ep (sc2-unit-pos e)])
                         (ormap (lambda (u)
                                  (define up (sc2-unit-pos u))
                                  (<= (pt-dist (sc2-point3d-x up) (sc2-point3d-y up)
                                               (sc2-point3d-x ep) (sc2-point3d-y ep))
                                      16.0))
                                combat-units))))
                enemy-units))
       (when splash-enemy-near?
         (define uncommitted
           (filter (lambda (u)
                     (and (not (set-member? commanded-combat-tags (sc2-unit-tag u)))
                          (not (memv (sc2-unit-unit-type u) '(32 500 503)))
                          (not (eq? (sc2-id->unit-symbol (sc2-unit-unit-type u)) 'queen))))
                   combat-units))
         (when (>= (length uncommitted) 6)
           (define l-pt (sc2-point2d (scale-bot-coord-to-world lx home-x)
                                     (scale-bot-coord-to-world ly home-y)))
           (define m-pt (sc2-point2d (scale-bot-coord-to-world mx home-x)
                                     (scale-bot-coord-to-world my home-y)))
           (define r-pt (sc2-point2d (scale-bot-coord-to-world rx home-x)
                                     (scale-bot-coord-to-world ry home-y)))
           (define wing-l '())
           (define wing-m '())
           (define wing-r '())
           (for ([u (in-list uncommitted)]
                 [idx (in-naturals)])
             (case (modulo idx 3)
               [(0) (set! wing-l (cons (sc2-unit-tag u) wing-l))]
               [(1) (set! wing-m (cons (sc2-unit-tag u) wing-m))]
               [else (set! wing-r (cons (sc2-unit-tag u) wing-r))]))
           (define l-tags (claim-combat-tags-for-order! (reverse wing-l) 23 l-pt 0))
           (define m-tags (claim-combat-tags-for-order! (reverse wing-m) 23 m-pt 0))
           (define r-tags (claim-combat-tags-for-order! (reverse wing-r) 23 r-pt 0))
           (when (not (null? l-tags)) (emit! (sc2-raw-unit-command 23 l-pt 0 l-tags #f)))
           (when (not (null? m-tags)) (emit! (sc2-raw-unit-command 23 m-pt 0 m-tags #f)))
           (when (not (null? r-tags)) (emit! (sc2-raw-unit-command 23 r-pt 0 r-tags #f)))))]

      [(list 'form-concave-arc raw-ex raw-ey arc-radius _ ...)
       (define ex (scale-bot-coord-to-world raw-ex home-x))
       (define ey (scale-bot-coord-to-world raw-ey home-y))
       (define r (if (and (real? arc-radius) (> arc-radius 2.0)) (exact->inexact arc-radius) 8.0))
       (define uncommitted
         (filter (lambda (u)
                   (define up (sc2-unit-pos u))
                   (and (not (set-member? commanded-combat-tags (sc2-unit-tag u)))
                        (not (memv (sc2-unit-unit-type u) '(32 500 503)))
                        (not (eq? (sc2-id->unit-symbol (sc2-unit-unit-type u)) 'queen))
                        (<= (pt-dist ex ey (sc2-point3d-x up) (sc2-point3d-y up)) 14.0)
                        (ormap (lambda (other)
                                 (and (not (= (sc2-unit-tag other) (sc2-unit-tag u)))
                                      (let ([op (sc2-unit-pos other)])
                                        (< (pt-dist (sc2-point3d-x up) (sc2-point3d-y up)
                                                    (sc2-point3d-x op) (sc2-point3d-y op))
                                           1.15))))
                               combat-units)))
                 combat-units))
       (when (and (not (null? enemy-units)) (>= (length uncommitted) 4))
         (define base-ang (atan (- home-y ey) (- home-x ex)))
         (define n (length uncommitted))
         (for ([u (in-list uncommitted)]
               [i (in-naturals)])
           (define frac (- (/ (+ i 0.5) n) 0.5))
           (define ang (+ base-ang (* frac 1.4)))
           (define ax (scale-bot-coord-to-world (+ ex (* r (cos ang))) home-x))
           (define ay (scale-bot-coord-to-world (+ ey (* r (sin ang))) home-y))
           (define apt (sc2-point2d ax ay))
           (define tags (claim-combat-tags-for-order! (list (sc2-unit-tag u)) 23 apt 0))
           (when (not (null? tags))
             (emit! (sc2-raw-unit-command 23 apt 0 tags #f)))))]

      [(list 'position-in-buff-aura-with-splash-spread _ raw-cx raw-cy _ min-sep _)
       (define cx (scale-bot-coord-to-world raw-cx home-x))
       (define cy (scale-bot-coord-to-world raw-cy home-y))
       (define sep (if (and (real? min-sep) (> min-sep 0.5)) (exact->inexact min-sep) 1.5))
       (when (not (null? enemy-units))
         (for ([u (in-list combat-units)]
               #:when (and (not (set-member? commanded-combat-tags (sc2-unit-tag u)))
                           (not (memv (sc2-unit-unit-type u) '(32 500 503)))))
           (define up (sc2-unit-pos u))
           (define ux (sc2-point3d-x up))
           (define uy (sc2-point3d-y up))
           (define cramped-neighbor
             (for/first ([other (in-list combat-units)]
                         #:when (and (not (= (sc2-unit-tag other) (sc2-unit-tag u)))
                                     (let ([op (sc2-unit-pos other)])
                                       (< (pt-dist ux uy (sc2-point3d-x op) (sc2-point3d-y op))
                                          (* 0.65 sep)))))
               other))
           (when cramped-neighbor
             (define op (sc2-unit-pos cramped-neighbor))
             (define dx (- ux (sc2-point3d-x op)))
             (define dy (- uy (sc2-point3d-y op)))
             (define d (max 0.25 (sqrt (+ (sqr dx) (sqr dy)))))
             (define sx (scale-bot-coord-to-world (+ ux (* sep (/ dx d))) cx))
             (define sy (scale-bot-coord-to-world (+ uy (* sep (/ dy d))) cy))
             (define spt (sc2-point2d sx sy))
             (define tags (claim-combat-tags-for-order! (list (sc2-unit-tag u)) 23 spt 0))
             (when (not (null? tags))
               (emit! (sc2-raw-unit-command 23 spt 0 tags #f))))))]

      ;; 10c. Previously-dropped tactical & recon intents (clear-expansion-block, transport-juggle,
      ;;      scout-sector, cast-protective-buff-aura, high-ground-tactics)
      [(or (list 'clear-expansion-block (? exact-integer? opt-blk-eid) (? real? raw-x) (? real? raw-y))
           (and (list 'clear-expansion-block (? real? raw-x) (? real? raw-y))
                (app (lambda (_) 0) opt-blk-eid)))
       (define tx (scale-bot-coord-to-world raw-x home-x))
       (define ty (scale-bot-coord-to-world raw-y home-y))
       (define uncommitted-combat
         (let ([cands
                (sort
                 (filter (lambda (u)
                           (and (not (set-member? commanded-combat-tags (sc2-unit-tag u)))
                                (not (memv (sc2-unit-unit-type u)
                                           '(32 500 503 56 75 77 111 126 127 495 499)))))
                         combat-units)
                 <
                 #:key (lambda (u)
                         (let* ([up (sc2-unit-pos u)]
                                [dx (- (sc2-point3d-x up) tx)]
                                [dy (- (sc2-point3d-y up) ty)])
                           (+ (* dx dx) (* dy dy)))))])
           (take cands (min 4 (length cands)))))
       (cond
         [(not (null? uncommitted-combat))
          (define valid-unit-tgt?
            (and (> opt-blk-eid 0)
                 (or (not enforce-live-enemy-tag-filter?)
                     (set-member? live-visible-enemy-tags opt-blk-eid))))
          (define eff-tgt-id (if valid-unit-tgt? opt-blk-eid 0))
          (define tgt-pt (if valid-unit-tgt? #f (sc2-point2d tx ty)))
          (define ctags
            (claim-combat-tags-for-order! (map sc2-unit-tag uncommitted-combat) 23 tgt-pt eff-tgt-id))
          (when (not (null? ctags))
            (emit! (sc2-raw-unit-command 23 tgt-pt eff-tgt-id ctags #f)))]
         [else
          (define wtag (pick-worker-near tx ty))
          (when wtag
            (if (and (> opt-blk-eid 0)
                     (or (not enforce-live-enemy-tag-filter?)
                         (set-member? live-visible-enemy-tags opt-blk-eid)))
                (emit! (sc2-raw-unit-command 23 #f opt-blk-eid (list wtag) #f))
                (emit! (sc2-raw-unit-command 23 (sc2-point2d tx ty) 0 (list wtag) #f))))])]

      [(list 'transport-juggle tr-id pass-ids (? real? raw-x) (? real? raw-y))
       (when (and (exact-integer? tr-id) (> tr-id 0))
         (define self-drop?
           (or (equal? pass-ids tr-id)
               (and (list? pass-ids)
                    (= (length pass-ids) 1)
                    (equal? (car pass-ids) tr-id))))
         (cond
           [self-drop?
            (record-unit-used! tr-id)
            (define tr-u (hash-ref self-unit-by-tag tr-id #f))
            (define tr-utype (if tr-u (sc2-unit-unit-type tr-u) 0))
            (define unload-ab-id
              (cond
                [(= tr-utype 54) 396]
                [(or (= tr-utype 81) (= tr-utype 136)) 913]
                [(= tr-utype 893) 1408]
                [else 3669]))
            ;; Moving self-drop: UnloadAllAt targeting the transport's own UnitTag (#f pos)
            (emit! (sc2-raw-unit-command unload-ab-id #f tr-id (list tr-id) #f))]
           [else
            (define plist
              (filter (lambda (t)
                        (and (exact-integer? t) (> t 0) (not (= t tr-id))
                             (not (passenger-protected-channeling-safe? t))))
                      (if (list? pass-ids) pass-ids (list pass-ids))))
            (when (not (null? plist))
              (record-unit-used! tr-id)
              (for ([ptag (in-list plist)]
                    [idx (in-naturals)])
                (record-unit-used! ptag)
                ;; LOAD_TRANSPORT (3668) is a UnitTargetAbility on the passenger unit tag
                (emit! (sc2-raw-unit-command 3668 #f ptag (list tr-id) (> idx 0))))
              (define tx (scale-bot-coord-to-world raw-x home-x))
              (define ty (scale-bot-coord-to-world raw-y home-y))
              (emit! (sc2-raw-unit-command 16 (sc2-point2d tx ty) 0 (list tr-id) #t)))]))]

      [(list 'transport-juggle tr-id (? real? raw-x) (? real? raw-y))
       (when (and (exact-integer? tr-id) (> tr-id 0))
         (define tr-u (hash-ref self-unit-by-tag tr-id #f))
         (when (transport-has-cargo-to-unload? tr-u)
           (record-unit-used! tr-id)
           (define unload-ab-id (transport-unload-ability-id tr-u))
           (define tx (scale-bot-coord-to-world raw-x home-x))
           (define ty (scale-bot-coord-to-world raw-y home-y))
           (emit! (sc2-raw-unit-command unload-ab-id (sc2-point2d tx ty) 0 (list tr-id) #f))))]

      [(list* 'transport-drop-moving tr-id maybe-tgt)
       (when (and (exact-integer? tr-id) (> tr-id 0))
         (define tr-u (hash-ref self-unit-by-tag tr-id #f))
         (when (transport-has-cargo-to-unload? tr-u)
           (define tgt-id (and (pair? maybe-tgt) (car maybe-tgt)))
           (record-unit-used! tr-id)
           (define unload-ab-id (transport-unload-ability-id tr-u))
           (define eff-tgt
             (if (and (exact-integer? tgt-id) (> tgt-id 0)) tgt-id tr-id))
           (emit! (sc2-raw-unit-command unload-ab-id #f eff-tgt (list tr-id) #f))))]

      [(or (list* 'transport-pickup tr-id ptag _rest)
           (list* 'load tr-id ptag _rest))
       (when (and (exact-integer? tr-id) (> tr-id 0)
                  (exact-integer? ptag) (> ptag 0) (not (= ptag tr-id))
                  (not (passenger-protected-channeling-safe? ptag)))
         (record-unit-used! tr-id)
         (record-unit-used! ptag)
         (emit! (sc2-raw-unit-command 3668 #f ptag (list tr-id) #f)))]

      [(or (list 'scout-sector _ (? real? raw-x) (? real? raw-y))
           (list 'scout-sector (? real? raw-x) (? real? raw-y)))
       (define tx (scale-bot-coord-to-world raw-x home-x))
       (define ty (scale-bot-coord-to-world raw-y home-y))
       (define target-pt (sc2-point2d tx ty))
       (define idle-scout
         (or (for/first ([u (in-list self-units)]
                         #:when (let ([utype (sc2-unit-unit-type u)])
                                  (and (memv utype '(82 129 12 13 14 15 16 17))
                                       (null? (sc2-unit-orders u))
                                       (not (set-member? commanded-combat-tags (sc2-unit-tag u)))
                                       (not (and (memv utype '(82 129))
                                                 cloaked-or-burrowed-threat-present?)))))
               u)
             (for/first ([u (in-list combat-units)]
                         #:when (and (null? (sc2-unit-orders u))
                                     (not (set-member? commanded-combat-tags (sc2-unit-tag u)))
                                     (not (memv (sc2-unit-unit-type u) '(32 106 126 129 500 503)))))
               u)))
       (when idle-scout
         (define stag (sc2-unit-tag idle-scout))
         (record-unit-used! stag)
         (unless (unit-already-executing-order? stag 16 target-pt 0)
           (emit! (sc2-raw-unit-command 16 target-pt 0 (list stag) #f))))]

      [(list 'cast-protective-buff-aura aura-sym (? real? raw-x) (? real? raw-y) _)
       (define norm-aura (normalize-sc2-name->symbol aura-sym))
       (define tx (scale-bot-coord-to-world raw-x home-x))
       (define ty (scale-bot-coord-to-world raw-y home-y))
       (cond
         [(eq? norm-aura 'guardian-shield)
          (define sentry-u
            (for/first ([u (in-list self-units)]
                        #:when (and (= (sc2-unit-unit-type u) 77)
                                    (>= (sc2-unit-energy u) 75.0)
                                    (not (set-member? commanded-combat-tags (sc2-unit-tag u)))))
              u))
          (when sentry-u
            (define stag (sc2-unit-tag sentry-u))
            (record-unit-used! stag)
            (emit! (sc2-raw-unit-command 76 #f 0 (list stag) #f)))]
         [(eq? norm-aura 'microbial-shroud)
          (define infestor-u
            (for/first ([u (in-list self-units)]
                        #:when (and (memv (sc2-unit-unit-type u) '(111 127))
                                    (>= (sc2-unit-energy u) 75.0)
                                    (not (set-member? commanded-combat-tags (sc2-unit-tag u)))))
              u))
          (when infestor-u
            (define itag (sc2-unit-tag infestor-u))
            (record-unit-used! itag)
            (emit! (sc2-raw-unit-command 2545 (sc2-point2d tx ty) 0 (list itag) #f)))])]

      [(list 'high-ground-tactics hg-mode (? real? raw-x) (? real? raw-y) spot-flag)
       (define tx (scale-bot-coord-to-world raw-x home-x))
       (define ty (scale-bot-coord-to-world raw-y home-y))
       (unless (and (eq? hg-mode 'hold-high-ground-ramp-arc)
                    maxed-army-push-suppresses-home-hold?
                    (point-on-home-side? tx ty))
         (define target-pt (sc2-point2d tx ty))
         (when spot-flag
           (define air-spotter
             (for/first ([u (in-list self-units)]
                         #:when (and (sc2-unit-is-flying u)
                                     (not (sc2-unit-is-structure? u))
                                     (not (memv (sc2-unit-unit-type u) '(106 129)))
                                     (not (set-member? commanded-combat-tags (sc2-unit-tag u)))
                                     (null? (sc2-unit-orders u))))
               u))
           (when air-spotter
             (define astag (sc2-unit-tag air-spotter))
             (record-unit-used! astag)
             (emit! (sc2-raw-unit-command 16 target-pt 0 (list astag) #f))))
         (define hg-combat
           (filter (lambda (u)
                     (define up (sc2-unit-pos u))
                     (and (not (set-member? commanded-combat-tags (sc2-unit-tag u)))
                          (not (memv (sc2-unit-unit-type u) '(32 126 500 503)))
                          (<= (pt-dist tx ty (sc2-point3d-x up) (sc2-point3d-y up)) 22.0)))
                   combat-units))
         (define hg-tags (claim-combat-tags-for-order! (map sc2-unit-tag hg-combat) 23 target-pt 0))
         (when (not (null? hg-tags))
           (emit! (sc2-raw-unit-command 23 target-pt 0 hg-tags #f))))]

      ;; 11. Control Groups (`ActionUI.control_group` is a wire no-op in Raw mode!) & Camera Saccades
      [(list (and op (or 'control-group-set 'control-group-append 'control-group-steal
                         'control-group-append-steal))
             (? exact-integer? g) raw-tags _ ...)
       (update-control-grouped-tags! op g raw-tags)
       (void)]
      [(list 'control-group-recall _ ...)
       (void)]

      [(list 'camera-focus _ raw-x raw-y)
       (emit-camera-move! raw-x raw-y)]
      [(list 'camera-focus raw-x raw-y)
       (emit-camera-move! raw-x raw-y)]
      [(list 'move-camera raw-x raw-y)
       (emit-camera-move! raw-x raw-y)]
      [(list 'camera-bookmark-jump _ raw-x raw-y)
       (emit-camera-move! raw-x raw-y)]

      [_ (void)])]))

  ;; 11b. Friendly Expansion Pad Clearance:
  ;;      When a friendly worker is actively walking to build a TownHall at `(px, py)`,
  ;;      push any non-builder friendly ground unit standing inside `Chebyshev <= 3.5` of `(px, py)`
  ;;      `5.0` tiles outward so our own army never body-blocks our expanding worker!
  (for ([pad (in-list (remove-duplicates active-friendly-th-build-pads))])
    (define px (car pad))
    (define py (cdr pad))
    (for ([u (in-list self-units)]
          #:when (let ([utag (sc2-unit-tag u)]
                       [up (sc2-unit-pos u)])
                   (and (not (sc2-unit-is-structure? u))
                        (not (sc2-unit-is-flying u))
                        (not (memv 57 (sc2-unit-buff-ids u)))
                        (not (memv (sc2-unit-unit-type u) '(32 500 503 151)))
                        (not (set-member? builder-worker-tags utag))
                        (not (worker-has-build-order? u cur-loop self-structures))
                        (not (set-member? commanded-combat-tags utag))
                        (not (unit-has-protected-order? utag))
                        (<= (max (abs (- (sc2-point3d-x up) px))
                                 (abs (- (sc2-point3d-y up) py)))
                            3.5))))
      (define utag (sc2-unit-tag u))
      (define up (sc2-unit-pos u))
      (define ux (sc2-point3d-x up))
      (define uy (sc2-point3d-y up))
      (define dx0 (- ux px))
      (define dy0 (- uy py))
      (define d0 (sqrt (+ (* dx0 dx0) (* dy0 dy0))))
      (define-values (ux-dir uy-dir)
        (if (< d0 0.25)
            (let* ([hx (- home-x px)]
                   [hy (- home-y py)]
                   [hd (max 1.0 (sqrt (+ (* hx hx) (* hy hy))))])
              (values (/ hx hd) (/ hy hd)))
            (values (/ dx0 d0) (/ dy0 d0))))
      (define clear-pt
        (sc2-point2d
         (max SC2-MAP-PLAYABLE-MIN-COORD (min SC2-MAP-PLAYABLE-MAX-COORD (+ px (* 5.0 ux-dir))))
         (max SC2-MAP-PLAYABLE-MIN-COORD (min SC2-MAP-PLAYABLE-MAX-COORD (+ py (* 5.0 uy-dir))))))
      (set-add! commanded-combat-tags utag)
      (when (sc2-unit-is-worker? u)
        (record-worker-used! utag))
      (unless (unit-already-executing-order? utag 16 clear-pt 0)
        (emit! (sc2-raw-unit-command 16 clear-pt 0 (list utag) #f)))))

  ;; 12. Automatic Terran Supply Depot Hysteresis, Siege Tank Unsiege, & Lurker / Widow Mine Unburrow
  (for ([u (in-list self-mode-toggle-units)]
        #:when (and (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)
                    (null? (sc2-unit-orders u))))
    (define utype (sc2-unit-unit-type u))
    (define utag (sc2-unit-tag u))
    (when (and (or (= utype 19) (= utype 47)) ;; 19 = SupplyDepot (raised), 47 = SupplyDepotLowered
               (not (set-member? commanded-combat-tags utag))
               (>= cur-loop (hash-ref SC2-DEPOT-TOGGLE-COOLDOWN utag 0)))
      (define dp (sc2-unit-pos u))
      (define dx (sc2-point3d-x dp))
      (define dy (sc2-point3d-y dp))
      (define min-ground-enemy-dist
        (for/fold ([best +inf.0])
                  ([e (in-list enemy-ground-units)])
          (define ep (sc2-unit-pos e))
          (min best (pt-dist dx dy (sc2-point3d-x ep) (sc2-point3d-y ep)))))
      (define fast-breach-near?
        (for/or ([e (in-list enemy-fast-breach-units)])
          (define ep (sc2-unit-pos e))
          (<= (pt-dist dx dy (sc2-point3d-x ep) (sc2-point3d-y ep)) 17.0)))
      (define depot-raise-dist (if fast-breach-near? 16.0 14.0))
      (define depot-lower-clear-dist (if fast-breach-near? 17.5 15.5))
      (define friendly-on-footprint?
        (friendly-unit-on-depot-footprint? dx dy self-ground-nonstruct-units))
      (define friendly-transit?
        (friendly-unit-requesting-depot-transit?
         dx dy self-ground-nonstruct-units builder-worker-tags commanded-combat-tags
         #:unit-pos-by-tag self-unit-pos-by-tag))
      (cond
        [(and (= utype 19)
              (> min-ground-enemy-dist depot-lower-clear-dist))
         (hash-set! SC2-DEPOT-TOGGLE-COOLDOWN utag (+ cur-loop (if friendly-transit? 36 44)))
         (emit! (sc2-raw-unit-command 556 #f 0 (list utag) #f))] ;; MORPH_SUPPLYDEPOT_LOWER
        [(and (= utype 47)
              (<= min-ground-enemy-dist depot-raise-dist)
              (not friendly-on-footprint?)
              (or (<= min-ground-enemy-dist 5.5) (not friendly-transit?)))
         (hash-set! SC2-DEPOT-TOGGLE-COOLDOWN utag (+ cur-loop (if (<= min-ground-enemy-dist 5.5) 40 44)))
         (emit! (sc2-raw-unit-command 558 #f 0 (list utag) #f))])) ;; MORPH_SUPPLYDEPOT_RAISE
    ;; Automatically unsiege idle `siege-tank-sieged` (32) with >= 44-loop cooldown when no enemy within 15.5 tiles
    (when (and (= utype 32)
               (not (set-member? commanded-combat-tags utag))
               (>= cur-loop (hash-ref SC2-MODE-TOGGLE-COOLDOWN utag -1)))
      (define tp (sc2-unit-pos u))
      (define enemy-in-siege-range?
        (ormap (lambda (e)
                 (define ep (sc2-unit-pos e))
                 (<= (pt-dist (sc2-point3d-x tp) (sc2-point3d-y tp)
                              (sc2-point3d-x ep) (sc2-point3d-y ep))
                     15.5))
               enemy-units))
      (unless enemy-in-siege-range?
        (hash-set! SC2-MODE-TOGGLE-COOLDOWN utag (+ cur-loop 44))
        (set-add! commanded-combat-tags utag)
        (emit! (sc2-raw-unit-command 390 #f 0 (list utag) #f))))
    ;; Automatically unburrow idle `lurker-burrowed` (503 -> 2110) only when no ground enemy is within 12.5 tiles
    (when (and (= utype 503)
               (not (set-member? commanded-combat-tags utag))
               (>= cur-loop (hash-ref SC2-MODE-TOGGLE-COOLDOWN utag -1)))
      (define lp (sc2-unit-pos u))
      (define ground-enemy-in-lurker-range?
        (ormap (lambda (e)
                 (define ep (sc2-unit-pos e))
                 (<= (pt-dist (sc2-point3d-x lp) (sc2-point3d-y lp)
                              (sc2-point3d-x ep) (sc2-point3d-y ep))
                     12.5))
               enemy-ground-units))
      (unless ground-enemy-in-lurker-range?
        (hash-set! SC2-MODE-TOGGLE-COOLDOWN utag (+ cur-loop 44))
        (set-add! commanded-combat-tags utag)
        (emit! (sc2-raw-unit-command 2110 #f 0 (list utag) #f))))
    ;; WidowMine (498 / 500) hysteresis: burrow <= 11.0 tiles; unburrow (2097) only when no enemy <= 15.5
    ;; continuously for >= 66 loops AND no friendly TownHall <= 12.0, with >= 44-loop toggle cooldown.
    (when (or (= utype 498) (= utype 500))
      (define prev-mine-type (hash-ref SC2-MINE-LAST-TYPE utag #f))
      (hash-set! SC2-MINE-LAST-TYPE utag utype)
      (define mp (sc2-unit-pos u))
      (define mx (sc2-point3d-x mp))
      (define my (sc2-point3d-y mp))
      (define min-enemy-dist
        (for/fold ([best +inf.0]) ([e (in-list enemy-units)])
          (define ep (sc2-unit-pos e))
          (min best (pt-dist mx my (sc2-point3d-x ep) (sc2-point3d-y ep)))))
      (when (and (= utype 500)
                 (or (<= min-enemy-dist 15.5)
                     (and (eqv? prev-mine-type 498)
                          (not (hash-has-key? SC2-MINE-CLEAR-SINCE-LOOP utag)))))
        (hash-set! SC2-MINE-CLEAR-SINCE-LOOP utag cur-loop))
      (cond
        [(and (= utype 498)
              (not (set-member? commanded-combat-tags utag))
              (>= cur-loop (hash-ref SC2-MODE-TOGGLE-COOLDOWN utag -1))
              (<= min-enemy-dist 11.0))
         (hash-set! SC2-MODE-TOGGLE-COOLDOWN utag (+ cur-loop 44))
         (hash-set! SC2-MINE-CLEAR-SINCE-LOOP utag cur-loop)
         (set-add! commanded-combat-tags utag)
         (emit! (sc2-raw-unit-command 2095 #f 0 (list utag) #f))]
        [(and (= utype 500)
              (not (set-member? commanded-combat-tags utag))
              (>= cur-loop (hash-ref SC2-MODE-TOGGLE-COOLDOWN utag -1))
              (> min-enemy-dist 15.5))
         (define clear-since (hash-ref SC2-MINE-CLEAR-SINCE-LOOP utag #f))
         (define clear-duration-ok? (or (not clear-since) (>= (- cur-loop clear-since) 66)))
         (define defending-mineral-line?
           (ormap (lambda (th)
                    (define tp (sc2-unit-pos th))
                    (<= (pt-dist mx my (sc2-point3d-x tp) (sc2-point3d-y tp)) 12.0))
                  townhalls))
         (when (and clear-duration-ok? (not defending-mineral-line?))
           (hash-set! SC2-MODE-TOGGLE-COOLDOWN utag (+ cur-loop 44))
           (hash-set! SC2-MINE-CLEAR-SINCE-LOOP utag cur-loop)
           (set-add! commanded-combat-tags utag)
           (emit! (sc2-raw-unit-command 2097 #f 0 (list utag) #f)))])))

  ;; 12a. W11-P0-4-wire (`w11-tac-4`): Emergency mobile detector intercept!
  ;;      When any uncovered cloaked (`cloak=1`) or undetected burrowed combat enemy is active,
  ;;      immediately fly the closest uncommanded mobile detector (`Overseer 129` / `Observer 82`)
  ;;      directly to reveal it (or unmorph stationary `OverseerSiege 1912` / `ObserverSiege 1911`)
  ;;      as a P0 urgent survival order so detectors are NEVER paralyzed while cloaked Banshees/DTs kill our army!
  (when uncovered-stealth-present?
    (define mobile-or-sieged-detectors
      (filter (lambda (u) (memv (sc2-unit-unit-type u) '(129 82 1912 1911)))
              ally-detector-units))
    (when (pair? mobile-or-sieged-detectors)
      (define det-tag-set (for/seteqv ([d (in-list mobile-or-sieged-detectors)]) (sc2-unit-tag d)))
      (define already-heading-pts
        (for/fold ([pts '()]) ([c (in-list raw-cmds)]
                               #:when (and (sc2-raw-unit-command? c)
                                           (= (sc2-raw-unit-command-ability-id c) 16)
                                           (any-point? (sc2-raw-unit-command-target-pos c))
                                           (ormap (lambda (t) (set-member? det-tag-set t))
                                                  (sc2-raw-unit-command-unit-tags c))))
          (define tp (sc2-raw-unit-command-target-pos c))
          (cons (cons (any-point-x tp) (any-point-y tp)) pts)))
      (define assigned-det-tags (mutable-seteqv))
      (for ([d (in-list mobile-or-sieged-detectors)])
        (when (set-member? commanded-combat-tags (sc2-unit-tag d))
          (set-add! assigned-det-tags (sc2-unit-tag d))))
      (define (stealth-priority-dist se)
        (define ep (sc2-unit-pos se))
        (define ex (sc2-point3d-x ep))
        (define ey (sc2-point3d-y ep))
        (define th-d
          (for/fold ([best +inf.0]) ([th (in-list townhalls)])
            (define tp (sc2-unit-pos th))
            (min best (pt-dist ex ey (sc2-point3d-x tp) (sc2-point3d-y tp)))))
        (define army-d
          (for/fold ([best +inf.0]) ([cu (in-list combat-units)])
            (define cp (sc2-unit-pos cu))
            (min best (pt-dist ex ey (sc2-point3d-x cp) (sc2-point3d-y cp)))))
        (min th-d army-d))
      (define sorted-stealth
        (sort uncovered-stealth-enemies < #:key stealth-priority-dist))
      (for ([se (in-list sorted-stealth)])
        (define ep (sc2-unit-pos se))
        (define ex (sc2-point3d-x ep))
        (define ey (sc2-point3d-y ep))
        (define covered-by-heading?
          (ormap (lambda (pt) (<= (pt-dist ex ey (car pt) (cdr pt)) 10.5))
                 already-heading-pts))
        (unless covered-by-heading?
          (define free-dets
            (filter (lambda (d) (not (set-member? assigned-det-tags (sc2-unit-tag d))))
                    mobile-or-sieged-detectors))
          (when (pair? free-dets)
            (define chosen-det
              (argmin (lambda (d)
                        (define dp (sc2-unit-pos d))
                        (define base-d (pt-dist ex ey (sc2-point3d-x dp) (sc2-point3d-y dp)))
                        (if (memv (sc2-unit-unit-type d) '(129 82)) base-d (+ base-d 15.0)))
                      free-dets))
            (define dtag (sc2-unit-tag chosen-det))
            (define dutype (sc2-unit-unit-type chosen-det))
            (set-add! assigned-det-tags dtag)
            (set-add! commanded-combat-tags dtag)
            (cond
              [(= dutype 1912)
               (emit! (mark-urgent-survival-cmd!
                       (sc2-raw-unit-command 3743 #f 0 (list dtag) #f)))]
              [(= dutype 1911)
               (emit! (mark-urgent-survival-cmd!
                       (sc2-raw-unit-command 3739 #f 0 (list dtag) #f)))]
              [else
               ;; Aim directly over the stealth enemy (pulled <= 2.0t toward nearby allied combat
               ;; if present, well inside 11.0t detection radius and <= 15.0t intercept bound)
               (define near-ally
                 (for/fold ([best-u #f] [best-d 20.0] #:result best-u)
                           ([cu (in-list combat-units)])
                   (define cp (sc2-unit-pos cu))
                   (define cd (pt-dist ex ey (sc2-point3d-x cp) (sc2-point3d-y cp)))
                   (if (< cd best-d) (values cu cd) (values best-u best-d))))
               (define-values (tx ty)
                 (if near-ally
                     (let* ([ap (sc2-unit-pos near-ally)]
                            [ax (sc2-point3d-x ap)]
                            [ay (sc2-point3d-y ap)]
                            [d (max 1.0 (pt-dist ex ey ax ay))]
                            [pull (min 2.0 (* 0.4 d))])
                       (values (max SC2-MAP-PLAYABLE-MIN-COORD
                                    (min SC2-MAP-PLAYABLE-MAX-COORD (+ ex (* pull (/ (- ax ex) d)))))
                               (max SC2-MAP-PLAYABLE-MIN-COORD
                                    (min SC2-MAP-PLAYABLE-MAX-COORD (+ ey (* pull (/ (- ay ey) d)))))))
                     (values (max SC2-MAP-PLAYABLE-MIN-COORD (min SC2-MAP-PLAYABLE-MAX-COORD ex))
                             (max SC2-MAP-PLAYABLE-MIN-COORD (min SC2-MAP-PLAYABLE-MAX-COORD ey)))))
               (define dest-pt (sc2-point2d tx ty))
               (set! already-heading-pts (cons (cons tx ty) already-heading-pts))
               (unless (unit-already-executing-order? dtag 16 dest-pt 0)
                 (emit! (mark-urgent-survival-cmd!
                         (sc2-raw-unit-command 16 dest-pt 0 (list dtag) #f))))]))))))

  (define idle-combat-units
    (filter (lambda (u)
              (and (null? (sc2-unit-orders u))
                   (not (set-member? commanded-combat-tags (sc2-unit-tag u)))
                   (not (memv (sc2-unit-unit-type u) '(32 500 503 694 733)))
                   (not (eq? (sc2-id->unit-symbol (sc2-unit-unit-type u)) 'queen))))
            combat-units))
  (when (and (>= cur-loop 6000) (null? enemy-units) sweep-context-active?)
    (define-values (_tw _fw corner-wps-now)
      (compute-endgame-sweep-plan default-eb-x default-eb-y))
    (maybe-emit-corner-scan! corner-wps-now))
  (when (not (null? idle-combat-units))
    (define idle-tags (map sc2-unit-tag idle-combat-units))
    (define base-threat
      (for/first ([e (in-list targetable-enemy-units)]
                  #:when (let ([ep (sc2-unit-pos e)])
                           (ormap (lambda (th)
                                    (define tp (sc2-unit-pos th))
                                    (<= (pt-dist (sc2-point3d-x ep) (sc2-point3d-y ep)
                                                 (sc2-point3d-x tp) (sc2-point3d-y tp))
                                        SC2-BASE-DEFENSE-RADIUS))
                                  townhalls)))
        e))
    (define-values (att-x att-y)
      (cond
        [(not (null? targetable-enemy-units))
         (define nearest-e
           (argmin (lambda (e)
                     (define ep (sc2-unit-pos e))
                     (pt-dist home-x home-y (sc2-point3d-x ep) (sc2-point3d-y ep)))
                   targetable-enemy-units))
         (define ep (sc2-unit-pos nearest-e))
         (values (sc2-point3d-x ep) (sc2-point3d-y ep))]
        [sweep-context-active?
         (define-values (top-wps _fw _cw)
           (compute-endgame-sweep-plan default-eb-x default-eb-y))
         (if (pair? top-wps)
             (values (caar top-wps) (cdar top-wps))
             (values default-eb-x default-eb-y))]
        [else
         (values default-eb-x default-eb-y)]))
    (define-values (stage-x stage-y)
      (compute-home-staging-point att-x att-y))
    (define home-staged-combat
      (filter (lambda (u)
                (define up (sc2-unit-pos u))
                (<= (pt-dist home-x home-y (sc2-point3d-x up) (sc2-point3d-y up)) 48.0))
              combat-units))
    (define home-staged-supply
      (for/sum ([u (in-list home-staged-combat)])
        (max 1 (sc2-supply-cost (sc2-id->unit-symbol (sc2-unit-unit-type u))))))
    (define home-wave-ready?
      (or (>= (length home-staged-combat) SC2-ATTACK-WAVE-MIN-COMBAT-UNITS)
          (>= home-staged-supply 16)
          (and (>= cur-loop 6000)
               (null? enemy-units)
               verified-endgame-map-state?
               (>= (length home-staged-combat) 2))
          (null? townhalls)))
    ;; W9-TAC-1: Shared helper so NO idle rally fallback (`tactical-hold-posture?`, `can-push-or-sweep?`,
    ;; or below-push-threshold `[else]`) EVER yanks a frontline unit within <= 16.0t of live enemy combat
    ;; 40+ tiles backward to home staging!
    (define idle-enemy-combat
      (if (null? enemy-units) '() (filter sc2-unit-targetable-enemy-combat? enemy-units)))
    (define (nearest-enemy-combat-within-16 u)
      (and (pair? idle-enemy-combat)
           (let* ([up (sc2-unit-pos u)]
                  [ux (sc2-point3d-x up)]
                  [uy (sc2-point3d-y up)])
             (for/fold ([best-e #f] [best-d2 256.01] #:result best-e)
                       ([e (in-list idle-enemy-combat)])
               (define ep (sc2-unit-pos e))
               (define dx (- ux (sc2-point3d-x ep)))
               (define dy (- uy (sc2-point3d-y ep)))
               (if (and (<= (abs dx) 16.0) (<= (abs dy) 16.0))
                   (let ([d2 (+ (* dx dx) (* dy dy))])
                     (if (< d2 best-d2) (values e d2) (values best-e best-d2)))
                   (values best-e best-d2))))))
    (define (emit-frontline-local-engage! fl-pairs)
      (for ([p (in-list fl-pairs)])
        (define fl-u (car p))
        (define fl-sym (sc2-id->unit-symbol (sc2-unit-unit-type fl-u)))
        (unless (or (memq fl-sym '(high-templar disruptor infestor viper raven medivac
                                   warp-prism warp-prism-phasing observer overseer swarm-host))
                    (weaponless-beam-off-oracle-tag? (sc2-unit-tag fl-u)))
          (define fl-ep (sc2-unit-pos (cdr p)))
          (emit! (sc2-raw-unit-command 23
                                       (sc2-point2d (sc2-point3d-x fl-ep) (sc2-point3d-y fl-ep))
                                       0 (list (sc2-unit-tag fl-u)) #f)))))
    (cond
      [base-threat
       (define ep (sc2-unit-pos base-threat))
       (emit! (mark-urgent-survival-cmd!
               (sc2-raw-unit-command 23
                                     (sc2-point2d (sc2-point3d-x ep) (sc2-point3d-y ep))
                                     0 idle-tags #f)))]
      [tactical-hold-posture?
       ;; Layer 3/4 hold / defend / suppress-attack posture: never scatter or push cross-map;
       ;; cohesively rally any idle combat units (> 8 tiles from defensive hold point) to `(eff-hold-x, eff-hold-y)`.
       (define-values (frontline-idle-pairs rally-idle-tags)
         (for/fold ([fl '()] [rl '()] #:result (values (reverse fl) (reverse rl)))
                   ([u (in-list idle-combat-units)])
           (define near-enemy (nearest-enemy-combat-within-16 u))
           (cond
             [near-enemy (values (cons (cons u near-enemy) fl) rl)]
             [(let ([up (sc2-unit-pos u)])
                (> (pt-dist eff-hold-x eff-hold-y (sc2-point3d-x up) (sc2-point3d-y up)) 8.0))
              (values fl (cons (sc2-unit-tag u) rl))]
             [else (values fl rl)])))
       (emit-frontline-local-engage! frontline-idle-pairs)
       (when (and (not (null? rally-idle-tags)) (not (null? townhalls)))
         (emit! (sc2-raw-unit-command 23 (sc2-point2d eff-hold-x eff-hold-y) 0 rally-idle-tags #f)))]
      [(and can-push-or-sweep?
            (null? targetable-enemy-units)
            sweep-context-active?)
       (define sweepable-idle
         (if home-wave-ready?
             idle-combat-units
             (filter (lambda (u)
                       (define up (sc2-unit-pos u))
                       (> (pt-dist home-x home-y (sc2-point3d-x up) (sc2-point3d-y up)) 48.0))
                     idle-combat-units)))
       (when (not (null? sweepable-idle))
         (emit-fan-out-sweep! sweepable-idle default-eb-x default-eb-y))
       (unless home-wave-ready?
         (define home-idle-tags
           (for/list ([u (in-list idle-combat-units)]
                      #:when (let ([up (sc2-unit-pos u)])
                               (and (not (nearest-enemy-combat-within-16 u))
                                    (<= (pt-dist home-x home-y (sc2-point3d-x up) (sc2-point3d-y up)) 48.0)
                                    (> (pt-dist stage-x stage-y (sc2-point3d-x up) (sc2-point3d-y up)) 8.0))))
             (sc2-unit-tag u)))
         (when (not (null? home-idle-tags))
           (emit! (sc2-raw-unit-command 23 (sc2-point2d stage-x stage-y) 0 home-idle-tags #f))))]
      [(and can-push-or-sweep? home-wave-ready?)
       (emit! (sc2-raw-unit-command 23
                                    (sc2-point2d att-x att-y)
                                    0 idle-tags #f))]
      [can-push-or-sweep?
       ;; Forward units (> 48 tiles from home) continue cohesively toward single target `(att-x, att-y)`;
       ;; newly spawned home units stage cohesively at natural choke (never yanking units actively in combat!)
       (define-values (fl-pairs forward-idle-tags home-idle-tags)
         (for/fold ([fl '()] [fwd '()] [hm '()]
                    #:result (values (reverse fl) (reverse fwd) (reverse hm)))
                   ([u (in-list idle-combat-units)])
           (define near-enemy (nearest-enemy-combat-within-16 u))
           (define up (sc2-unit-pos u))
           (define ux (sc2-point3d-x up))
           (define uy (sc2-point3d-y up))
           (cond
             [near-enemy (values (cons (cons u near-enemy) fl) fwd hm)]
             [(> (pt-dist home-x home-y ux uy) 48.0)
              (values fl (cons (sc2-unit-tag u) fwd) hm)]
             [(> (pt-dist stage-x stage-y ux uy) 8.0)
              (values fl fwd (cons (sc2-unit-tag u) hm))]
             [else (values fl fwd hm)])))
       (emit-frontline-local-engage! fl-pairs)
       (when (not (null? forward-idle-tags))
         (emit! (sc2-raw-unit-command 23 (sc2-point2d att-x att-y) 0 forward-idle-tags #f)))
       (when (not (null? home-idle-tags))
         (emit! (sc2-raw-unit-command 23 (sc2-point2d stage-x stage-y) 0 home-idle-tags #f)))]
      [else
       ;; Army below push threshold: rally idle units that spawned at main base (> 8 tiles from front stage)
       ;; to natural choke; frontline units within <= 16.0t of enemy combat engage locally instead!
       (define-values (fl-pairs unplaced-home-tags)
         (for/fold ([fl '()] [rl '()] #:result (values (reverse fl) (reverse rl)))
                   ([u (in-list idle-combat-units)])
           (define near-enemy (nearest-enemy-combat-within-16 u))
           (cond
             [near-enemy (values (cons (cons u near-enemy) fl) rl)]
             [(let ([up (sc2-unit-pos u)])
                (and (<= (pt-dist home-x home-y (sc2-point3d-x up) (sc2-point3d-y up)) 48.0)
                     (> (pt-dist stage-x stage-y (sc2-point3d-x up) (sc2-point3d-y up)) 8.0)))
              (values fl (cons (sc2-unit-tag u) rl))]
             [else (values fl rl)])))
       (emit-frontline-local-engage! fl-pairs)
       (when (and (not (null? unplaced-home-tags)) (not (null? townhalls)))
         (emit! (sc2-raw-unit-command 23 (sc2-point2d stage-x stage-y) 0 unplaced-home-tags #f)))]))

  ;; 13. Multi-Tag Wire Command Coalescing:
  ;;     Merge compatible combat/stance/spell/depot/unburrow `sc2-raw-unit-command` packets
  ;;     that share `(ability-id, target-pos, target-unit-tag, queue?)` into a single multi-tag packet
  ;;     to eliminate per-unit command duplication while preserving Reactor multi-slot train queues.
  (coalesce-sc2-raw-commands (reverse raw-cmds) SC2-COALESCABLE-ABILITIES #f))

(define SC2-COALESCABLE-ABILITIES
  (seteqv 16 17 18 23 76 171 380 388 390 403 405 556 558 1036 1042 1442 1526 2095 2097 2108 2110 2328 2338 2346 2375 2393 3661 3662 3665 3666 3667 3674 3675 3687))

;; Shared O(C) raw unit command coalescer preserving first-appearance command order.
;; When `chunk-fn` is provided, also sorts/dedups/chunks all unit command tag lists to `<= 64` tags.
(define (coalesce-sc2-raw-commands cmds able-set [chunk-fn #f])
  (define groups (make-hash))
  (define rev-slots '())
  (define (dedup-tags tags)
    (cond
      [(or (null? tags) (null? (cdr tags))) tags]
      [else
       (define seen (mutable-seteqv))
       (for/fold ([acc '()] #:result (reverse acc))
                 ([t (in-list tags)])
         (if (set-member? seen t)
             acc
             (begin
               (set-add! seen t)
               (cons t acc))))]))
  (define (emit-cmd ab tp tu tags q? urgent? macro-econ? paired-cam out-rev)
    (define eff-tags
      (if chunk-fn
          (sort (dedup-tags tags) <)
          (dedup-tags tags)))
    (define tag-batches (if chunk-fn (chunk-fn eff-tags 64) (list eff-tags)))
    (for/fold ([acc out-rev]) ([ch (in-list tag-batches)])
      (define cc (sc2-raw-unit-command ab tp tu ch q?))
      (when paired-cam
        (hash-set! SC2-CMD-FRAMING-CAM cc paired-cam))
      (when urgent? (mark-urgent-survival-cmd! cc))
      (when macro-econ? (mark-macro-econ-cmd! cc))
      (cons cc acc)))
  (for ([c (in-list cmds)])
    (cond
      [(and (sc2-raw-unit-command? c)
            (set-member? able-set (sc2-raw-unit-command-ability-id c)))
       (define ab (sc2-raw-unit-command-ability-id c))
       (define tp (sc2-raw-unit-command-target-pos c))
       (define tu (sc2-raw-unit-command-target-unit-tag c))
       (define q? (and (sc2-raw-unit-command-queue? c) #t))
       (define tp-k (and (any-point? tp) (cons (any-point-x tp) (any-point-y tp))))
       (define key (list ab tp-k tu q?))
       (define g (hash-ref groups key #f))
       (define c-tags (sc2-raw-unit-command-unit-tags c))
       (define c-urg? (urgent-survival-cmd? c))
       (define c-econ? (macro-econ-cmd? c))
       (define c-cam (hash-ref SC2-CMD-FRAMING-CAM c #f))
       (cond
         [g
          (vector-set! g 4 (append (reverse c-tags) (vector-ref g 4)))
          (when c-urg? (vector-set! g 5 #t))
          (when c-econ? (vector-set! g 7 #t))
          (when (and c-cam (not (vector-ref g 6)))
            (vector-set! g 6 c-cam))]
         [else
          (define ng (vector ab tp tu q? (reverse c-tags) c-urg? c-cam c-econ?))
          (hash-set! groups key ng)
          (set! rev-slots (cons ng rev-slots))])]
      [else
       (set! rev-slots (cons c rev-slots))]))
  (reverse
   (for/fold ([out-rev '()]) ([slot (in-list (reverse rev-slots))])
     (cond
       [(vector? slot)
        (emit-cmd (vector-ref slot 0)
                  (vector-ref slot 1)
                  (vector-ref slot 2)
                  (reverse (vector-ref slot 4))
                  (vector-ref slot 3)
                  (vector-ref slot 5)
                  (vector-ref slot 7)
                  (vector-ref slot 6)
                  out-rev)]
       [(and chunk-fn (sc2-raw-unit-command? slot))
        (emit-cmd (sc2-raw-unit-command-ability-id slot)
                  (sc2-raw-unit-command-target-pos slot)
                  (sc2-raw-unit-command-target-unit-tag slot)
                  (sc2-raw-unit-command-unit-tags slot)
                  (sc2-raw-unit-command-queue? slot)
                  (urgent-survival-cmd? slot)
                  (macro-econ-cmd? slot)
                  (hash-ref SC2-CMD-FRAMING-CAM slot #f)
                  out-rev)]
       [else (cons slot out-rev)]))))

;; =============================================================================
;; 14. Wire-Level Token-Bucket & Rolling-Window APM Governor
;; =============================================================================

(define SC2-FASTER-LOOPS-PER-MINUTE 1344.0)
(define SC2-WIRE-COALESCABLE-ABILITIES
  (seteqv 16 17 18 23 42 76 171 380 388 390 403 405 556 558 1036 1042 1442 1526
          1725 1727 1729 1731 1882 2095 2097 2108 2110 2244 2328 2338 2346 2375 2393 2706
          3661 3662 3665 3666 3667 3674 3675 3680 3681 3687))

(struct wire-apm-governor
  (target-apm
   hard-cap-apm
   tokens
   burst-capacity
   last-loop
   last-cam-loop
   last-selected-tags
   rolling-events)
  #:mutable
  #:transparent)

(define (make-wire-apm-governor #:target-apm [target-apm 410.0]
                                #:hard-cap-apm [hard-cap-apm 485.0])
  (wire-apm-governor (exact->inexact target-apm)
                     (exact->inexact hard-cap-apm)
                     24.0
                     28.0
                     -1
                     -1000
                     #f
                     '()))

(define (wire-cmd-priority-tier cmd)
  (define (ab-tier ab)
    (cond
      ;; P0: Life-or-death survival, tactical spells, cancel, mode-switches & depot raise/lower
      [(memv ab '(42 314 349 380 382 383 396 407 408 913 1408 1437 1438 1882 2244
                  2368 2370 2371 2546 2594 2706 3675 1442 3687 74 76 140 249 251 399 401
                  1036 1526 1528 1530 1628 1664 1978 1998 2063 2067 2069 2073 2116 2146
                  2324 2338 2346 2350 2358 2375 2376 2393 2505 2542 2545 2588 2714 3668 3669
                  3747 3751 3753 3755 3757 4107 4113 4126 142 3686 388 390
                  2095 2097 2108 2110 403 405 2362 2364 556 558))
       0]
      ;; P3: Routine harvest, worker rebalance & non-urgent Bunker Salvage (`32`)
      [(memv ab '(32 166 167 295 296 298 299 1183 1184 3666 3667))
       3]
      ;; P2: Combat attack, move, kite, hold-position, patrol, stop
      [(memv ab '(4 5 6 7 16 17 18 19 20 23 24 25 2099 3665 3674 3771 3793 3794 3795))
       2]
      ;; P1: Macro build, expand, morph, train, warp-in, research, tumor, MULE
      [else 1]))
  (cond
    [(framing-camera-cmd? cmd) 1]
    [(or (sc2-raw-camera-move? cmd) (WireCameraMove? cmd)) 4]
    [(urgent-survival-cmd? cmd) 0]
    [(macro-econ-cmd? cmd) 1]
    [(sc2-raw-unit-command? cmd)
     (define ab (sc2-raw-unit-command-ability-id cmd))
     (if (and (sc2-raw-unit-command-queue? cmd) (memv ab '(3666 3667)))
         2
         (ab-tier ab))]
    [(WireCmdNone? cmd) (ab-tier (NoTargetAbility-id (WireCmdNone-ability cmd)))]
    [(WireCmdPoint? cmd) (ab-tier (PointTargetAbility-id (WireCmdPoint-ability cmd)))]
    [(WireCmdUnit? cmd) (ab-tier (UnitTargetAbility-id (WireCmdUnit-ability cmd)))]
    [(WireCmdArchon? cmd) 1]
    [(WireToggleAutocast? cmd) 1]
    [else 4]))

(define (chunk-tag-list tags max-chunk)
  (let loop ([rem tags] [acc '()])
    (cond
      [(null? rem) (reverse acc)]
      [(<= (length rem) max-chunk) (reverse (cons rem acc))]
      [else
       (define-values (hd tl) (split-at rem max-chunk))
       (loop tl (cons hd acc))])))

(define SC2-GOV-LAST-P1-LOOP (make-weak-hasheq))
(define SC2-GOV-LAST-P2-LOOP (make-weak-hasheq))
(define SC2-GOV-LAST-P3-LOOP (make-weak-hasheq))

(define (govern-sc2-wire-actions! gov raw-cmds game-loop [_obs #f])
  (define cur-loop (if (exact-integer? game-loop) (max 0 game-loop) 0))
  ;; Auto-reset state across sequential matches when game-loop rewinds
  (when (and (>= (wire-apm-governor-last-loop gov) 0)
             (< cur-loop (wire-apm-governor-last-loop gov)))
    (set-wire-apm-governor-tokens! gov 24.0)
    (set-wire-apm-governor-last-loop! gov -1)
    (set-wire-apm-governor-last-cam-loop! gov -1000)
    (set-wire-apm-governor-last-selected-tags! gov #f)
    (set-wire-apm-governor-rolling-events! gov '())
    (set-box! SC2-GOV-LAST-CAM-X #f)
    (set-box! SC2-GOV-LAST-CAM-Y #f)
    (hash-set! SC2-GOV-LAST-P1-LOOP gov -1000)
    (hash-set! SC2-GOV-LAST-P2-LOOP gov -1000)
    (hash-set! SC2-GOV-LAST-P3-LOOP gov -1000))

  ;; 1. Refill token bucket purely from game-loop delta (22.4 loops/sec = 1344 loops/min)
  (define prev-loop (wire-apm-governor-last-loop gov))
  (when (>= prev-loop 0)
    (define dloops (max 0 (- cur-loop prev-loop)))
    (define added (* (exact->inexact dloops)
                     (/ (wire-apm-governor-target-apm gov) SC2-FASTER-LOOPS-PER-MINUTE)))
    (set-wire-apm-governor-tokens!
     gov
     (min (wire-apm-governor-burst-capacity gov)
          (+ (wire-apm-governor-tokens gov) added))))
  (set-wire-apm-governor-last-loop! gov cur-loop)

  ;; 2. Prune rolling 1344-loop (60.0s) replay event window and compute strict cap headroom
  (define win-floor (- cur-loop 1344))
  (define pruned-events
    (filter (lambda (ev) (> (car ev) win-floor))
            (wire-apm-governor-rolling-events gov)))
  (set-wire-apm-governor-rolling-events! gov pruned-events)
  (define rolling-used
    (for/sum ([ev (in-list pruned-events)]) (cdr ev)))
  (define rolling-headroom
    (max 0.0 (- (wire-apm-governor-hard-cap-apm gov) (exact->inexact rolling-used))))

  ;; 3. Strip Raw-mode no-op UI control-group commands, rate-limit camera moves
  ;;    (>= 28 loops routine, >= 6 loops for framing camera moves jumping > 10.0 tiles),
  ;;    coalesce compatible unit commands, canonicalize sorted tag lists, and chunk to <= 64 tags.
  (define (cam-cmd-cooldown-ok? c)
    (define dloop (- cur-loop (wire-apm-governor-last-cam-loop gov)))
    (define gov-cx (unbox SC2-GOV-LAST-CAM-X))
    (define gov-cy (unbox SC2-GOV-LAST-CAM-Y))
    (define jump-dist
      (cond
        [(and (real? gov-cx) (real? gov-cy))
         (pt-dist (sc2-raw-camera-move-x c)
                  (sc2-raw-camera-move-y c)
                  gov-cx
                  gov-cy)]
        [(real? (hash-ref SC2-FRAMING-CAMERA-CMDS c #f))
         (hash-ref SC2-FRAMING-CAMERA-CMDS c)]
        [else 0.0]))
    (define needed-cd
      (if (and (framing-camera-cmd? c) (> jump-dist 10.0)) 6 28))
    (>= dloop needed-cd))
  (define raw-cmd-list (if (list? raw-cmds) raw-cmds '()))
  (define has-allowed-framing-cam?
    (for/or ([c (in-list raw-cmd-list)])
      (and (framing-camera-cmd? c) (cam-cmd-cooldown-ok? c))))
  (define cam-seen? #f)
  (define filtered0
    (for/list ([c (in-list raw-cmd-list)]
               #:when (cond
                        [(sc2-ui-control-group? c) #f]
                        [(sc2-chat-action? c) #t]
                        [(sc2-raw-camera-move? c)
                         (define framing? (framing-camera-cmd? c))
                         (if (and (not cam-seen?)
                                  (cam-cmd-cooldown-ok? c)
                                  (or framing? (not has-allowed-framing-cam?)))
                             (begin (set! cam-seen? #t) #t)
                             #f)]
                        [(sc2-raw-unit-command? c)
                         (pair? (sc2-raw-unit-command-unit-tags c))]
                        [else #f]))
      c))

  ;; Link any immediately preceding framing camera move to its target unit command if unlinked
  (let link-loop ([rem filtered0] [prev #f])
    (unless (null? rem)
      (define cur (car rem))
      (when (and (sc2-raw-unit-command? cur)
                 (framing-camera-cmd? prev)
                 (not (hash-ref SC2-CMD-FRAMING-CAM cur #f)))
        (hash-set! SC2-CMD-FRAMING-CAM cur prev))
      (link-loop (cdr rem) cur)))

  (define coalesced
    (coalesce-sc2-raw-commands filtered0 SC2-WIRE-COALESCABLE-ABILITIES chunk-tag-list))

  ;; 4. Emit by priority tier P0..P4 with tiered QoS reserve floors, selection-affinity grouping,
  ;;    and exact replay event cost accounting:
  ;;    - `sc2-raw-unit-command` with `unit-tags == last-selected-tags` costs 1 replay event (`SCmdEvent` only)
  ;;    - `sc2-raw-unit-command` with a new selection costs 2 replay events (`SSelectionDeltaEvent` + `SCmdEvent`)
  ;;    - `sc2-raw-camera-move` costs 1 replay event (`SCameraUpdateEvent`)
  ;;    Low-priority P2/P3/P4 traffic leaves a token + rolling-window reserve so P0 survival/spells
  ;;    and P1 macro are never starved by prior-frame worker/camera spam, while rolling 60s APM
  ;;    is strictly bounded by `hard-cap-apm`.
  (define rem-headroom rolling-headroom)
  (define cur-sel (wire-apm-governor-last-selected-tags gov))
  (define new-events '())
  (define (opening-worker-split-cmd? c)
    (and (<= cur-loop 12)
         (sc2-raw-unit-command? c)
         (= (sc2-raw-unit-command-ability-id c) 3666)))
  (define (eff-cmd-tier c)
    (if (opening-worker-split-cmd? c)
        0
        (wire-cmd-priority-tier c)))
  (define emitted '())
  (define emitted-set (make-hasheq))
  (define (tier-token-floor tier cmd)
    (case tier
      [(0)  (if (or (urgent-survival-cmd? cmd) (opening-worker-split-cmd? cmd)) -4.0 -1.0)]
      [(1)  0.0]  ;; P1 macro executes whenever >= ev-cost tokens remain (never starved behind P2!)
      [(2)  4.0]  ;; P2 combat leaves >= 4 tokens for P0/P1
      [(3)  8.0]  ;; P3 harvest/lower leaves >= 8 tokens for P0/P1/P2
      [else 10.0]))
  (define (tier-headroom-floor tier)
    (case tier
      [(0)  0.0]  ;; P0 strictly obeys rolling 60s hard-cap-apm
      [(1)  2.0]
      [(2) 12.0]
      [(3) 24.0]
      [else 30.0]))
  (define (run-cmd-list! cmds tok-floor-fn hr-floor-fn #:max-count [max-count #f])
    (let tier-loop ([rem (filter (lambda (c) (not (hash-has-key? emitted-set c))) cmds)]
                    [emitted-here 0])
      (unless (or (null? rem)
                  (and max-count (>= emitted-here max-count)))
        ;; Prefer a command in this tier whose unit-tags match `cur-sel` (saves 1 selection-delta event!)
        (define same-sel-cmd
          (and cur-sel
               (for/first ([c (in-list rem)]
                           #:when (and (sc2-raw-unit-command? c)
                                       (equal? (sc2-raw-unit-command-unit-tags c) cur-sel)))
                 c)))
        (define chosen (or same-sel-cmd (car rem)))
        (define rest-rem
          (let rem-one ([xs rem])
            (cond
              [(null? xs) '()]
              [(eq? (car xs) chosen) (cdr xs)]
              [else (cons (car xs) (rem-one (cdr xs)))])))
        (define ev-cost
          (cond
            [(sc2-chat-action? chosen) 0]
            [(sc2-raw-camera-move? chosen) 1]
            [(and cur-sel
                  (sc2-raw-unit-command? chosen)
                  (equal? (sc2-raw-unit-command-unit-tags chosen) cur-sel))
             1]
            [else 2]))
        (define cost-fl (exact->inexact ev-cost))
        (define tok-floor (tok-floor-fn chosen))
        (define hr-floor (hr-floor-fn chosen))
        (define did-emit?
          (and (or (= ev-cost 0)
                   (and (>= (- rem-headroom cost-fl) hr-floor)
                        (>= (- (wire-apm-governor-tokens gov) cost-fl) tok-floor)))
               #t))
        (when did-emit?
          (when (> ev-cost 0)
            (set! rem-headroom (- rem-headroom cost-fl))
            (set-wire-apm-governor-tokens!
             gov
             (max -4.0 (- (wire-apm-governor-tokens gov) cost-fl)))
            (set! new-events (cons (cons cur-loop ev-cost) new-events)))
          (cond
            [(sc2-raw-camera-move? chosen)
             (set-wire-apm-governor-last-cam-loop! gov cur-loop)
             (set-box! SC2-GOV-LAST-CAM-X (sc2-raw-camera-move-x chosen))
             (set-box! SC2-GOV-LAST-CAM-Y (sc2-raw-camera-move-y chosen))]
            [(sc2-raw-unit-command? chosen)
             (set! cur-sel (sc2-raw-unit-command-unit-tags chosen))
             (set-wire-apm-governor-last-selected-tags! gov cur-sel)])
          (when (and (= (eff-cmd-tier chosen) 1) (not (sc2-raw-camera-move? chosen)))
            (hash-set! SC2-GOV-LAST-P1-LOOP gov cur-loop))
          (when (= (eff-cmd-tier chosen) 2)
            (hash-set! SC2-GOV-LAST-P2-LOOP gov cur-loop))
          (when (= (eff-cmd-tier chosen) 3)
            (hash-set! SC2-GOV-LAST-P3-LOOP gov cur-loop))
          (hash-set! emitted-set chosen #t)
          (set! emitted (cons chosen emitted)))
        (tier-loop rest-rem (if did-emit? (add1 emitted-here) emitted-here)))))

  (define (cmds-for-tier tier)
    (filter (lambda (c) (= (eff-cmd-tier c) tier)) coalesced))

  ;; 1. Run P0 urgent survival/spells first.
  (run-cmd-list! (cmds-for-tier 0)
                 (lambda (c) (tier-token-floor 0 c))
                 (lambda (_) (tier-headroom-floor 0)))

  ;; 1b. W7-P0-2-wire: Guaranteed overdue rescue slot for large multi-unit P2 combat march/attack
  ;;     commands (>= 8 tags, AB 23/16) when >= 8 loops have elapsed since last P2 emission, so
  ;;     late-game P1 creep-tumor / macro bursts NEVER starve army-wide marches or endgame hunts!
  (define p2-cmds (cmds-for-tier 2))
  (define p2-large-cmds
    (sort
     (filter (lambda (c)
               (and (sc2-raw-unit-command? c)
                    (memv (sc2-raw-unit-command-ability-id c) '(23 16))
                    (>= (length (sc2-raw-unit-command-unit-tags c)) 8)))
             p2-cmds)
     >
     #:key (lambda (c) (length (sc2-raw-unit-command-unit-tags c)))))
  (when (and (pair? p2-large-cmds)
             (>= (- cur-loop (hash-ref SC2-GOV-LAST-P2-LOOP gov -1000)) 8))
    (run-cmd-list! p2-large-cmds (lambda (_) -2.0) (lambda (_) 2.0) #:max-count 4))

  ;; 2. Run P1 macro (`train`, `warp-in`, `build`, `expand`, `morph`, `research`, `MULE`) BEFORE P2/P4 rescue
  ;;    so continuous P0/P2 combat micro NEVER starves macro production, expansions, or upgrades (#5130439, #5131238)!
  (define p1-cmds (cmds-for-tier 1))
  (run-cmd-list! p1-cmds
                 (lambda (c) (tier-token-floor 1 c))
                 (lambda (_) (tier-headroom-floor 1)))
  (define p1-macro-rem
    (filter (lambda (c) (and (not (hash-has-key? emitted-set c)) (not (sc2-raw-camera-move? c))))
            p1-cmds))
  (when (and (pair? p1-macro-rem)
             (>= (- cur-loop (hash-ref SC2-GOV-LAST-P1-LOOP gov -1000)) 8))
    (run-cmd-list! p1-macro-rem (lambda (_) -3.0) (lambda (_) 2.0) #:max-count 4))

  ;; 3. Bounded anti-starvation rescue for overdue P2 combat (>= 12 loops stale), overdue P3 routine
  ;;    worker/transfer (>= 24 loops stale, W18-P0-2-wire), and 1 overdue routine P4 camera (>= 44 loops).
  (when (and (pair? p2-cmds)
             (>= (- cur-loop (hash-ref SC2-GOV-LAST-P2-LOOP gov -1000)) 12))
    (run-cmd-list! p2-cmds (lambda (_) 1.5) (lambda (_) 6.0) #:max-count 3))
  (define p3-cmds (cmds-for-tier 3))
  (when (and (pair? p3-cmds)
             (>= (- cur-loop (hash-ref SC2-GOV-LAST-P3-LOOP gov -1000)) 24))
    (run-cmd-list! p3-cmds (lambda (_) 1.5) (lambda (_) 8.0) #:max-count 1))
  (define p4-cam-cmds
    (filter sc2-raw-camera-move? (cmds-for-tier 4)))
  (when (and (pair? p4-cam-cmds)
             (>= (- cur-loop (wire-apm-governor-last-cam-loop gov)) 44))
    (run-cmd-list! p4-cam-cmds (lambda (_) 0.0) (lambda (_) 6.0) #:max-count 1))

  ;; 4. Normal tier drain P2..P4 (`emitted-set` prevents re-emitting rescued P2/P4 commands).
  (for ([tier (in-range 2 5)])
    (define hr-floor (tier-headroom-floor tier))
    (run-cmd-list! (cmds-for-tier tier)
                   (lambda (c) (tier-token-floor tier c))
                   (lambda (_) hr-floor)))

  ;; W11-P0-3-wire: If APM throttling dropped any WarpGate warp-in command (1413..1419),
  ;; immediately release its client-side cooldown lock so it retries on the next step instead
  ;; of being falsely locked out for 23 seconds!
  (for ([c (in-list coalesced)]
        #:when (and (sc2-raw-unit-command? c)
                    (memv (sc2-raw-unit-command-ability-id c) SC2-WARP-IN-ABILITY-IDS)
                    (not (hash-has-key? emitted-set c))))
    (for ([t (in-list (sc2-raw-unit-command-unit-tags c))])
      (hash-remove! SC2-WARPGATE-COOLDOWN-UNTIL t)))

  (when (not (null? new-events))
    (set-wire-apm-governor-rolling-events!
     gov
     (append (reverse new-events) (wire-apm-governor-rolling-events gov))))

  ;; Preserve ordering so each emitted framing camera move immediately precedes the unit command it frames.
  (define chron (reverse emitted))
  (define emitted-framing-cams
    (for/hasheq ([uc (in-list chron)]
                 #:do [(define fc (and (sc2-raw-unit-command? uc)
                                       (hash-ref SC2-CMD-FRAMING-CAM uc #f)))]
                 #:when (and fc (memq fc chron)))
      (values fc #t)))
  (cond
    [(zero? (hash-count emitted-framing-cams)) chron]
    [else
     (define placed-cams (make-hasheq))
     (for/fold ([acc '()] #:result (reverse acc))
               ([c (in-list chron)])
       (cond
         [(and (framing-camera-cmd? c) (hash-has-key? emitted-framing-cams c))
          acc]
         [(and (sc2-raw-unit-command? c)
               (let ([fc (hash-ref SC2-CMD-FRAMING-CAM c #f)])
                 (and fc
                      (hash-has-key? emitted-framing-cams fc)
                      (not (hash-has-key? placed-cams fc))
                      fc)))
          => (lambda (fc)
               (hash-set! placed-cams fc #t)
               (cons c (cons fc acc)))]
         [else (cons c acc)]))]))
