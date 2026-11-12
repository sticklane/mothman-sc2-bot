#lang racket/base

;; =============================================================================
;; Pure-Racket Native StarCraft II WebSocket + Protobuf (`s2clientprotocol`)
;; Client, Wire Codec, Canonical ID Tables, Observation Converter & Actuator
;; =============================================================================
;; Implements direct communication with `SC2_x64` over `ws://127.0.0.1:<port>/sc2api`
;; using only standard libraries bundled in the minimal Racket runtime.

(require racket/tcp
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
         "sc2-typed-commands.rkt")

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
 (struct-out sc2-unit)
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
 solve-all-map-expansion-bases
 order-expansions-from-origin
 sc2-observation->runtime-obs-hash
 sc2-observation->frame-state-sexp
 collect-spiral-candidates
 find-spiral-building-placement
 find-verified-building-placement
 select-producer-tags-for-unit
 frame0-pro-worker-split-commands
 pick-safe-mule-mineral-patch
 saturate-workers-and-gas-commands
 translate-bot-actions->sc2-raw-commands
 get-last-bot-action-rejects
 get-total-bot-action-reject-count
 get-total-wire-action-drop-count
 reset-typed-command-gate-stats!
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
  (define h (make-hash))
  (for ([entry (in-list fields)])
    (match-define (list fnum wtype val) entry)
    (hash-update! h fnum (lambda (prev) (append prev (list (cons wtype val)))) '()))
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
          (morph-thor-explosive 2364 #t)
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
          (heal 386 #t)
          (emp-round 1628 #t)
          (emp 1628 #f)
          (steady-targeting 2714 #t)
          (snipe 2714 #f)
          (cloak-banshee 392 #t)
          (decloak-banshee 393 #t)
          (yamato-cannon 401 #t)
          (tactical-jump 2358 #t)
          (kd8-charge 2588 #t)
          (interference-matrix 3747 #t)
          (anti-armor-missile 3753 #t)
          (auto-turret 349 #t)
          (repair 3685 #t)
          (salvage 32 #t)
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

(define (normalize-sc2-name->symbol v)
  (cond
    [(symbol? v)
     (string->symbol
      (string-replace (string-downcase (symbol->string v)) "_" "-"))]
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
  (define norm (normalize-sc2-name->symbol unit-sym))
  (define prefixed (string->symbol (format "train-~a" norm)))
  (or (hash-ref SC2-ABILITY-SYM->ID prefixed #f)
      (hash-ref SC2-ABILITY-SYM->ID norm #f)
      (hash-ref SC2-ABILITY-SYM->ID (string->symbol (format "morph-~a" norm)) #f)))

(define (build-symbol->ability-id bldg-sym)
  (define norm (normalize-sc2-name->symbol bldg-sym))
  (define prefixed (string->symbol (format "build-~a" norm)))
  (or (hash-ref SC2-ABILITY-SYM->ID prefixed #f)
      (hash-ref SC2-ABILITY-SYM->ID (string->symbol (format "morph-~a" norm)) #f)
      (hash-ref SC2-ABILITY-SYM->ID norm #f)))

(define (research-symbol->ability-id upg-sym)
  (define norm (normalize-sc2-name->symbol upg-sym))
  (define prefixed (string->symbol (format "research-~a" norm)))
  (or (hash-ref SC2-ABILITY-SYM->ID prefixed #f)
      (hash-ref SC2-ABILITY-SYM->ID norm #f)))

(define (morph-symbol->ability-id target-sym)
  (define norm (normalize-sc2-name->symbol target-sym))
  (cond
    [(memq norm '(lurker-den lurker-den-mp)) 1163]
    [else
     (define prefixed (string->symbol (format "morph-~a" norm)))
     (or (hash-ref SC2-ABILITY-SYM->ID prefixed #f)
         (hash-ref SC2-ABILITY-SYM->ID (string->symbol (format "build-~a" norm)) #f)
         (hash-ref SC2-ABILITY-SYM->ID norm #f))]))

(define (spell-symbol->ability-id spell-sym)
  (define norm (normalize-sc2-name->symbol spell-sym))
  (or (hash-ref SC2-ABILITY-SYM->ID norm #f)
      (hash-ref SC2-ABILITY-SYM->ID (string->symbol (format "effect-~a" norm)) #f)))

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
   shield-upgrade-level)
  #:transparent)

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

(define (decode-point2d-bytes bstr [start 0] [end (bytes-length bstr)])
  (define x #f)
  (define y #f)
  (let loop ([pos start])
    (when (< pos end)
      (define-values (tag next-pos) (decode-varint bstr pos))
      (define field-num (arithmetic-shift tag -3))
      (define wire-type (bitwise-and tag #x07))
      (cond
        [(and (= wire-type 5) (<= (+ next-pos 4) end))
         (case field-num
           [(1) (unless x (set! x (decode-float32 bstr next-pos)))]
           [(2) (unless y (set! y (decode-float32 bstr next-pos)))])
         (loop (+ next-pos 4))]
        [else
         (loop (skip-protobuf-wire-value bstr wire-type next-pos end))])))
  (sc2-point2d (or x 0.0) (or y 0.0)))

(define (decode-point3d-bytes bstr [start 0] [end (bytes-length bstr)])
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
           [(3) (unless z (set! z (decode-float32 bstr next-pos)))])
         (loop (+ next-pos 4))]
        [else
         (loop (skip-protobuf-wire-value bstr wire-type next-pos end))])))
  (sc2-point3d (or x 0.0) (or y 0.0) (or z 0.0)))

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
  (sc2-unit
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
   (or f-shield-upgrade-level 0)))

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
                   [event-b (field-first-bytes raw-fields 4 #f)]
                   [event-fields (if event-b (decode-protobuf-message event-b) '())]
                   [dead-tags (decode-packed-or-unpacked-varints event-fields 1)]
                   [effects (map decode-effect-bytes (field-all-bytes raw-fields 5))])
              (sc2-observation game-loop pc units upgrade-ids power-sources camera
                               dead-tags effects player-results action-errors chat-msgs alerts))))))

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
    (calibrate-image-grid-orientation! pathing-grid start-locs))
  (when terrain-height
    (calibrate-image-grid-orientation! terrain-height start-locs)
    (when (and placement-grid (sc2-image-grid-y-flip? placement-grid))
      (set-sc2-image-grid-y-flip?! terrain-height #t)))
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
                           (normalize-sc2-name->symbol name) id #:primary? #f)))))

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

(define (sc2-unit-is-structure? u)
  (define sym (if (symbol? u) u (sc2-id->unit-symbol (sc2-unit-unit-type u))))
  (set-member? STRUCTURE-SYMS sym))

(define (sc2-unit-is-townhall? u)
  (define sym (if (symbol? u) u (sc2-id->unit-symbol (sc2-unit-unit-type u))))
  (set-member? TOWNHALL-SYMS sym))

(define (sc2-unit-is-worker? u)
  (define sym (if (symbol? u) u (sc2-id->unit-symbol (sc2-unit-unit-type u))))
  (set-member? WORKER-SYMS sym))

(define (sc2-unit-is-mineral-field? u)
  (define sym (if (symbol? u) u (sc2-id->unit-symbol (sc2-unit-unit-type u))))
  (set-member? MINERAL-FIELD-SYMS sym))

(define (sc2-unit-is-vespene-geyser? u)
  (define sym (if (symbol? u) u (sc2-id->unit-symbol (sc2-unit-unit-type u))))
  (set-member? VESPENE-GEYSER-SYMS sym))

(define (sc2-unit-is-gas-building? u)
  (define sym (if (symbol? u) u (sc2-id->unit-symbol (sc2-unit-unit-type u))))
  (set-member? GAS-BUILDING-SYMS sym))

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

(define (image-grid-signature grid)
  (and (sc2-image-grid? grid)
       (let* ([bs (sc2-image-grid-data grid)]
              [blen (if (bytes? bs) (bytes-length bs) 0)]
              [stride (max 1 (quotient blen 32))]
              [bhash
               (if (<= blen 0)
                   0
                   (for/fold ([h blen])
                             ([i (in-range 0 blen stride)])
                     (bitwise-and #x3fffffff
                                  (+ (* h 131) (bytes-ref bs i) i))))])
         (list (sc2-image-grid-width grid)
               (sc2-image-grid-height grid)
               (sc2-image-grid-bits-per-pixel grid)
               (sc2-image-grid-y-flip? grid)
               (sc2-image-grid-lsb-first? grid)
               blen
               bhash))))

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
  (lambda (self tx ty [ring-r 0])
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
          (if (< best INF) (/ (exact->inexact best) 10.0) +inf.0)])])))

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
        ;; Ensure origin cell (and 5x5 friendly main pad where static pathing_grid=1) is unblocked
        (bytes-set! walk (+ hix (* hiy w)) 1)
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

(define (resource-unit-cell-key u kind-code)
  (define p (sc2-unit-pos u))
  (+ kind-code
     (* 8 (+ (inexact->exact (round (* 2.0 (sc2-point3d-x p))))
             (* 4096 (inexact->exact (round (* 2.0 (sc2-point3d-y p)))))))))

(define (refresh-cached-expansion-bases cached-pads base-minerals geysers)
  (define n-pads (length cached-pads))
  (cond
    [(zero? n-pads) '()]
    [else
     (define pad-vec (list->vector cached-pads))
     (define mins-vec (make-vector n-pads '()))
     (define geys-vec (make-vector n-pads '()))
     (for ([m (in-list (reverse base-minerals))])
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
       (when best-i
         (vector-set! mins-vec best-i (cons m (vector-ref mins-vec best-i)))))
     (for ([g (in-list (reverse geysers))])
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
       (when best-i
         (vector-set! geys-vec best-i (cons g (vector-ref geys-vec best-i)))))
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
             'minerals (vector-ref mins-vec i)
             'geysers (vector-ref geys-vec i)))]))

;; Connected-component resource clustering + exact 5x5 TownHall pad solver:
;; Filters mineral-wall blockers (`mineral-field-450`, `lab-mineral-field*`) and nubs (< 150 minerals),
;; builds transitive mineral components (center dist <= 5.2), attaches each geyser within 10.5 tiles
;; to its single nearest mineral component, and solves the exact 5x5 TownHall pad for each base.
;; Memoizes solved canonical pads per map (keyed by StartRaw grid signature + fallback synthetic
;; resource signature when `game-info = #f`) and refreshes live mineral/geyser counts in O(resources).
(define (solve-all-map-expansion-bases neutral-units [game-info #f])
  (define base-minerals
    (filter (lambda (u)
              (and (sc2-unit-is-mineral-field? u)
                   (not (memq (sc2-id->unit-symbol (sc2-unit-unit-type u))
                              '(mineral-field-450 lab-mineral-field lab-mineral-field-750)))
                   (let ([mc (sc2-unit-mineral-contents u)])
                     (or (= mc 0) (>= mc 150)))))
            neutral-units))
  (define geysers
    (filter (lambda (u)
              (and (sc2-unit-is-vespene-geyser? u)
                   (let ([vc (sc2-unit-vespene-contents u)])
                     (or (= vc 0) (> vc 0)))))
            neutral-units))
  (cond
    [(and (null? base-minerals) (null? geysers)) '()]
    [else
     (define all-blocking-res
       (filter (lambda (u)
                 (or (sc2-unit-is-mineral-field? u)
                     (sc2-unit-is-vespene-geyser? u)))
               neutral-units))
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
                          ([u (in-list all-blocking-res)])
                  (define k
                    (resource-unit-cell-key
                     u
                     (cond
                       [(sc2-unit-is-vespene-geyser? u) 2]
                       [(memq u base-minerals) 1]
                       [else 3])))
                  (if (set-member? seen k)
                      (values xh sh)
                      (begin
                        (set-add! seen k)
                        (values (bitwise-xor xh (bitwise-and #x3fffffff (* k 26544357)))
                                (bitwise-and #x3fffffff (+ sh k)))))))
              (list 'synthetic-res (set-count seen) xor-h sum-h))))
     (define cache-key (or static-grid-key fallback-res-key))
     (define cached-entry (and cache-key (hash-ref SC2-EXPANSION-BASES-CACHE cache-key #f)))
     (define cache-valid?
       (and cached-entry
            (let ([known-cells (cdr cached-entry)])
              (and (for/and ([m (in-list base-minerals)])
                     (set-member? known-cells (resource-unit-cell-key m 1)))
                   (for/and ([g (in-list geysers)])
                     (set-member? known-cells (resource-unit-cell-key g 2)))))))
     (cond
       [cache-valid?
        (refresh-cached-expansion-bases (car cached-entry) base-minerals geysers)]
       [else
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
          (define known-cells
            (set-union
             (for/seteqv ([m (in-list base-minerals)])
               (resource-unit-cell-key m 1))
             (for/seteqv ([g (in-list geysers)])
               (resource-unit-cell-key g 2))))
          (define pads (for/list ([b (in-list ordered)]) (hash-ref b 'pad)))
          (hash-set! SC2-EXPANSION-BASES-CACHE cache-key (cons pads known-cells)))
        ordered])]))

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

(define SC2-WARPGATE-LAST-LOOP (box 0))
(define SC2-WARPGATE-COOLDOWN-UNTIL (make-hasheqv))
(define SC2-WORKER-BUILD-ORDER-START (make-hasheqv))
(define SC2-HOME-BASE-ANCHOR (box #f))
(define SC2-CLEARED-ENEMY-BASES (box '()))
(define SC2-CACHED-MAP-BASE-CLUSTERS (box '()))
(define SC2-CORNER-SCAN-LAST-LOOP (box -9999))
(define SC2-ACTIVE-GAME-INFO (box #f))

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

(define (order-expansions-from-origin solved-bases origin-x origin-y pathing-grid neutral-units)
  (define non-main
    (filter (lambda (b)
              (> (pt-dist origin-x origin-y (hash-ref b 'x) (hash-ref b 'y)) 10.0))
            solved-bases))
  (define bfs (compute-ground-bfs-distances pathing-grid origin-x origin-y neutral-units))
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

(define (sc2-observation->runtime-obs-hash obs
                                           #:game-info [game-info #f]
                                           #:our-player-id [our-player-id 1]
                                           #:configured-race [configured-race 'Random]
                                           #:used-creep-tumors [used-tumors (seteqv)])
  (define cur-loop (sc2-observation-game-loop obs))
  (when (sc2-game-info? game-info)
    (set-box! SC2-ACTIVE-GAME-INFO game-info))
  (when (< cur-loop (unbox SC2-WARPGATE-LAST-LOOP))
    (hash-clear! SC2-WARPGATE-COOLDOWN-UNTIL)
    (hash-clear! SC2-WORKER-BUILD-ORDER-START)
    (set-box! SC2-HOME-BASE-ANCHOR #f)
    (set-box! SC2-CLEARED-ENEMY-BASES '())
    (set-box! SC2-CACHED-MAP-BASE-CLUSTERS '())
    (set-box! SC2-CORNER-SCAN-LAST-LOOP -9999))
  (set-box! SC2-WARPGATE-LAST-LOOP cur-loop)
  (define pc (sc2-observation-player-common obs))
  (define units (sc2-observation-units obs))
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
  (define self-units
    (filter (lambda (u) (and (= (sc2-unit-alliance u) 1)
                             (not (= (sc2-unit-display-type u) 4))))
            units))
  (define enemy-all
    (filter (lambda (u) (and (= (sc2-unit-alliance u) 4)
                             (not (= (sc2-unit-display-type u) 4))))
            units))
  (define neutral-all (filter (lambda (u) (= (sc2-unit-alliance u) 3)) units))

  (define mineral-fields (filter sc2-unit-is-mineral-field? neutral-all))
  (define live-resource-units
    (filter (lambda (u) (or (sc2-unit-is-mineral-field? u) (sc2-unit-is-vespene-geyser? u)))
            neutral-all))
  (define solved-bases (solve-all-map-expansion-bases neutral-all game-info))
  (define raw-my-townhalls (filter sc2-unit-is-townhall? self-units))
  (when (and (= (length raw-my-townhalls) 1)
             (or (not (unbox SC2-HOME-BASE-ANCHOR))
                 (<= cur-loop 20)))
    (define p0 (sc2-unit-pos (first raw-my-townhalls)))
    (set-box! SC2-HOME-BASE-ANCHOR (cons (sc2-point3d-x p0) (sc2-point3d-y p0)))
    (set-box! SC2-CLEARED-ENEMY-BASES '())
    (set-box! SC2-CACHED-MAP-BASE-CLUSTERS '())
    (set-box! SC2-CORNER-SCAN-LAST-LOOP -9999))
  (when (not (null? live-resource-units))
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

  ;; Exact 5x5 TownHall pads ordered by ground BFS distance from Main (and from Enemy Main)
  (define dx (- enemy-x base-x))
  (define dy (- enemy-y base-y))
  (define d-norm (max 1.0 (sqrt (+ (sqr dx) (sqr dy)))))
  (define ux (/ dx d-norm))
  (define uy (/ dy d-norm))
  (define path-grid (and (sc2-game-info? game-info) (sc2-game-info-pathing-grid game-info)))
  (define ordered-home-exps
    (order-expansions-from-origin solved-bases base-x base-y path-grid neutral-all))
  (define ordered-enemy-exps
    (order-expansions-from-origin solved-bases enemy-x enemy-y path-grid neutral-all))
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
  (define pending-supply
    (+ (for/sum ([u (in-list self-units)]
                 #:when (and (memq (sc2-id->unit-symbol (sc2-unit-unit-type u))
                                   '(supply-depot supply-depot-lowered pylon pylon-overcharged))
                             (< (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)))
         1)
       (for/sum ([w (in-list my-workers)]
                 #:when (not (worker-build-order-stuck? w cur-loop)))
         (count (lambda (o)
                  (memv (sc2-unit-order-ability-id o) '(319 881))) ;; TERRANBUILD_SUPPLYDEPOT=319, PROTOSSBUILD_PYLON=881
                (sc2-unit-orders w)))
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
             'flying? (sc2-unit-is-flying u)
             'cloak cloak-st
             'cloaked (or (= cloak-st 1) (= cloak-st 2))
             'is-burrowed is-burr?
             'burrowed is-burr?
             'is-hallucination is-halluc?
             'hallucination is-halluc?
             'sieged (not (not (memq utype-sym '(siege-tank-sieged liberator-ag widow-mine-burrowed lurker-burrowed lurker-mp-burrowed))))
             'weapon-cooldown (sc2-unit-weapon-cooldown u)
             'engaged-target-tag (sc2-unit-engaged-target-tag u)
             'buffs u-buffs
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
             'busy? (or wg-busy? (pair? b-ords))
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
            'weapon-cooldown (sc2-unit-weapon-cooldown eu)
            'engaged-target-tag (sc2-unit-engaged-target-tag eu))))

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
      (define disp-type (sc2-unit-display-type eb))
      (define cloak-st (sc2-unit-cloak eb))
      (define is-halluc? (sc2-unit-is-hallucination eb))
      (define is-burr? (sc2-unit-is-burrowed eb))
      (hash 'id (sc2-unit-tag eb)
            'type (sc2-id->unit-symbol (sc2-unit-unit-type eb))
            'x (sc2-point3d-x p)
            'y (sc2-point3d-y p)
            'z (sc2-point3d-z p)
            'hp (max 1 (exact-round (sc2-unit-health eb)))
            'build-progress (max 0.0 (min 1.0 (sc2-unit-build-progress eb)))
            'display-type disp-type
            'snapshot? (not (= disp-type 1))
            'cloak cloak-st
            'cloaked (or (= cloak-st 1) (= cloak-st 2))
            'is-burrowed is-burr?
            'burrowed is-burr?
            'is-hallucination is-halluc?
            'hallucination is-halluc?
            'engaged-target-tag (sc2-unit-engaged-target-tag eb))))

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
      (hash 'id (sc2-unit-tag m)
            'x (sc2-point3d-x mp)
            'y (sc2-point3d-y mp)
            'minerals (sc2-unit-mineral-contents m))))

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

  (define supply-cap (min SC2-MAX-SUPPLY (max 0 (sc2-player-common-food-cap pc))))
  (define supply-used (max 0 (sc2-player-common-food-used pc)))
  (define supply-left (max 0 (- supply-cap supply-used)))

  (hash 'frame cur-loop
        'race actual-race
        'opponent-requested-race opponent-requested-race
        'map-grids map-grids
        'minerals (max 0 (- (sc2-player-common-minerals pc) in-transit-min-cost))
        'gas (max 0 (- (sc2-player-common-vespene pc) in-transit-gas-cost))
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
        'enemy-third-x enemy-third-x
        'enemy-third-y enemy-third-y
        'enemy-fourth-x enemy-fourth-x
        'enemy-fourth-y enemy-fourth-y
        'mineral-patch-id closest-mineral-patch-id
        'mineral-patches mineral-patch-records
        'ally-units ally-unit-records
        'ally-creep-tumors ally-creep-tumor-records
        'ally-buildings ally-bldg-records
        'enemy-units enemy-unit-records
        'enemy-buildings enemy-bldg-records
        'shimmer-and-burrow-ripples shimmer-and-burrow-ripples
        'free-addons free-addons
        'effects effect-records
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
        'army-supply (max 0 (sc2-player-common-food-army pc))))

(define (sc2-observation->frame-state-sexp obs
                                           #:game-info [game-info #f]
                                           #:our-player-id [our-player-id 1]
                                           #:configured-race [configured-race 'Random]
                                           #:used-creep-tumors [used-tumors (seteqv)])
  (define h (sc2-observation->runtime-obs-hash obs
                                               #:game-info game-info
                                               #:our-player-id our-player-id
                                               #:configured-race configured-race
                                               #:used-creep-tumors used-tumors))
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

(define (static-footprint-placement-ok? pl-grid cx cy hw hh)
  (cond
    [(not (sc2-image-grid? pl-grid)) #t]
    [else
     (define gw (sc2-image-grid-width pl-grid))
     (define gh (sc2-image-grid-height pl-grid))
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
     (and (>= x0 0) (>= y0 0) (< x1 gw) (< y1 gh)
          (for*/and ([ix (in-range x0 (add1 x1))]
                     [iy (in-range y0 (add1 y1))])
            (= (sc2-grid-ref pl-grid ix iy) 1)))]))

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
     (define neutrals
       (filter (lambda (u) (and (sc2-unit? u) (= (sc2-unit-alliance u) 3)))
               existing-units))
     (define bfs (compute-ground-bfs-distances path-grid ref-x ref-y neutrals))
     (and bfs
          (< (bfs ref-x ref-y 4) +inf.0)
          bfs)]))

(define (dedup-point2ds pts)
  (define seen (make-hash))
  (filter (lambda (pt)
            (define k (cons (round (* 4.0 (sc2-point2d-x pt)))
                            (round (* 4.0 (sc2-point2d-y pt)))))
            (if (hash-has-key? seen k)
                #f
                (begin (hash-set! seen k #t) #t)))
          pts))

(define (collect-spiral-candidates anchor-x anchor-y existing-units
                                   #:min-spacing [min-spacing 3.5]
                                   #:max-radius [max-radius 14.0]
                                   #:step [step 2.0]
                                   #:limit [limit 24]
                                   #:extra-reserved-points [extra-reserved-points '()]
                                   #:ws-active-placement? [ws-active-placement? #f]
                                   #:reserved-aabbs [reserved-aabbs '()]
                                   #:expansion-pads [expansion-pads '()]
                                   #:bldg-sym [bldg-sym #f]
                                   #:game-info [game-info #f])
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
  (define base-ref
    (if (and (not is-creep-tumor?) (sc2-game-info? game-info))
        (friendly-safe-base-anchor existing-units anchor-x anchor-y)
        (cons anchor-x anchor-y)))
  (define check-bfs
    (and (not is-creep-tumor?)
         (ground-reachability-checker game-info existing-units (car base-ref) (cdr base-ref))))

  ;; Collect in-transit worker build target points and existing + in-transit Terran East (+X) add-on footprints
  (define in-transit-build-pts
    (for*/list ([u (in-list existing-units)]
                #:when (sc2-unit-is-worker? u)
                [o (in-list (sc2-unit-orders u))]
                [ab-sym (in-value (sc2-id->ability-symbol (sc2-unit-order-ability-id o) #f))]
                #:when (and ab-sym
                            (string-prefix? (symbol->string ab-sym) "build-")
                            (any-point? (sc2-unit-order-target-pos o))))
      (define tp (sc2-unit-order-target-pos o))
      (sc2-point2d (any-point-x tp) (any-point-y tp))))
  (define in-transit-terran-addon-pts
    (for*/list ([u (in-list existing-units)]
                #:when (sc2-unit-is-worker? u)
                [o (in-list (sc2-unit-orders u))]
                #:when (and (memv (sc2-unit-order-ability-id o) '(321 328 329))
                            (any-point? (sc2-unit-order-target-pos o))))
      (define tp (sc2-unit-order-target-pos o))
      (sc2-point2d (+ (any-point-x tp) SC2-TERRAN-ADDON-OFFSET-X)
                   (+ (any-point-y tp) SC2-TERRAN-ADDON-OFFSET-Y))))
  (define terran-addon-pts
    (for/list ([u (in-list existing-units)]
               #:when (memq (sc2-id->unit-symbol (sc2-unit-unit-type u))
                            '(barracks factory starport)))
      (define p (sc2-unit-pos u))
      (sc2-point2d (+ (sc2-point3d-x p) SC2-TERRAN-ADDON-OFFSET-X)
                   (+ (sc2-point3d-y p) SC2-TERRAN-ADDON-OFFSET-Y))))
  (define all-reserved-pts
    (append extra-reserved-points in-transit-build-pts in-transit-terran-addon-pts terran-addon-pts))

  (define (clear-spot? cx cy)
    (and (>= cx SC2-MAP-PLAYABLE-MIN-COORD) (<= cx SC2-MAP-PLAYABLE-MAX-COORD)
         (>= cy SC2-MAP-PLAYABLE-MIN-COORD) (<= cy SC2-MAP-PLAYABLE-MAX-COORD)
         ;; Static footprint placement_grid & ground-reachability pre-filter when StartRaw grids are available
         (static-footprint-placement-ok? pl-grid cx cy cand-hw cand-hh)
         (or (not check-bfs)
             (< (check-bfs cx cy 4) +inf.0))
         ;; Expansion Pad Protection: non-TownHall structures/turrets/pylons/depots/tumors must stay >= 4.5 Chebyshev tiles off solved pads
         (or is-townhall-build?
             (for/and ([ep (in-list expansion-pads)])
               (define px (if (pair? ep) (car ep) (any-point-x ep)))
               (define py (if (pair? ep) (cdr ep) (any-point-y ep)))
               (>= (max (abs (- cx px)) (abs (- cy py))) 4.5)))
         ;; Reserved Chebyshev AABB exclusion (door gap, wall slots, ramp corridor, add-on footprints)
         (for/and ([b (in-list reserved-aabbs)]
                   #:when (reserved-aabb? b))
           (not (aabb-overlaps? cx cy cand-hw cand-hh b)))
         (for/and ([u (in-list existing-units)]
                   #:when (or (sc2-unit-is-structure? u)
                              (sc2-unit-is-mineral-field? u)
                              (sc2-unit-is-vespene-geyser? u)))
           (define p (sc2-unit-pos u))
           (> (pt-dist cx cy (sc2-point3d-x p) (sc2-point3d-y p))
              (if ws-active-placement?
                  (max 2.0 (+ 0.85 (max 0.5 (sc2-unit-radius u))))
                  (+ min-spacing (max 0.5 (sc2-unit-radius u))))))
         (for/and ([rp (in-list all-reserved-pts)]
                   #:when (any-point? rp))
           (> (pt-dist cx cy (any-point-x rp) (any-point-y rp))
              (max 2.5 min-spacing)))))
  (define acc '())
  (when (clear-spot? anchor-x anchor-y)
    (set! acc (cons (sc2-point2d anchor-x anchor-y) acc)))
  (let r-loop ([r step])
    (when (and (<= r max-radius) (< (length acc) limit))
      (let d-loop ([dx (- r)])
        (when (and (<= dx r) (< (length acc) limit))
          (let y-loop ([dy (- r)])
            (when (and (<= dy r) (< (length acc) limit))
              (when (and (or (>= (abs dx) r) (>= (abs dy) r))
                         (clear-spot? (+ anchor-x dx) (+ anchor-y dy)))
                (set! acc (cons (sc2-point2d (+ anchor-x dx) (+ anchor-y dy)) acc)))
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

(define (find-verified-building-placement ws-conn ab-id anchor-x anchor-y existing-units
                                          #:min-spacing [min-spacing 3.5]
                                          #:max-radius [max-radius 14.0]
                                          #:step [step 2.0]
                                          #:extra-reserved-points [extra-reserved-points '()]
                                          #:anchor-points [anchor-points #f]
                                          #:reserved-aabbs [reserved-aabbs '()]
                                          #:expansion-pads [expansion-pads '()]
                                          #:bldg-sym [bldg-sym #f]
                                          #:game-info [game-info #f])
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
  (define-values (cand-hw cand-hh)
    (sc2-structure-half-dims (or canon-bldg 'barracks)))
  (define is-townhall-build?
    (and canon-bldg (set-member? SC2-TOWNHALL-STRUCTURE-SYMS canon-bldg)))
  (define is-creep-tumor?
    (memq canon-bldg '(creep-tumor creep-tumor-burrowed creep-tumor-queen)))
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
  (define check-bfs
    (and (not is-creep-tumor?)
         (ground-reachability-checker game-info existing-units
                                      (car safe-base-anchor) (cdr safe-base-anchor))))

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
  (define matched-wall-slot-ok?
    (and matched-wall-slot
         (>= wall-ref-x SC2-MAP-PLAYABLE-MIN-COORD) (<= wall-ref-x SC2-MAP-PLAYABLE-MAX-COORD)
         (>= wall-ref-y SC2-MAP-PLAYABLE-MIN-COORD) (<= wall-ref-y SC2-MAP-PLAYABLE-MAX-COORD)
         (static-footprint-placement-ok? pl-grid wall-ref-x wall-ref-y cand-hw cand-hh)
         (or (not check-bfs) (< (check-bfs wall-ref-x wall-ref-y 4) +inf.0))))

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
    (and first-rax?
         (or (and matched-wall-slot #t)
             east-addon-overhangs-terrain?
             (> (pt-dist wall-ref-x wall-ref-y
                         (car safe-base-anchor) (cdr safe-base-anchor))
                6.0))))

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

  (define (filter-addon-clear c-list)
    (filter (lambda (pt)
              (define ax (+ (sc2-point2d-x pt) SC2-TERRAN-ADDON-OFFSET-X))
              (define ay (+ (sc2-point2d-y pt) SC2-TERRAN-ADDON-OFFSET-Y))
              (and (<= ax SC2-MAP-PLAYABLE-MAX-COORD)
                   (>= ay SC2-MAP-PLAYABLE-MIN-COORD)
                   (static-footprint-placement-ok? pl-grid ax ay 1.0 1.0)
                   (for/and ([b (in-list eff-reserved-aabbs)]
                             #:when (reserved-aabb? b))
                     (not (aabb-overlaps? ax ay 1.0 1.0 b)))
                   (for/and ([ep (in-list expansion-pads)])
                     (define px (if (pair? ep) (car ep) (any-point-x ep)))
                     (define py (if (pair? ep) (cdr ep) (any-point-y ep)))
                     (>= (max (abs (- ax px)) (abs (- ay py))) 4.0))
                   (for/and ([u (in-list existing-units)]
                             #:when (or (sc2-unit-is-structure? u)
                                        (sc2-unit-is-mineral-field? u)
                                        (sc2-unit-is-vespene-geyser? u)))
                     (define p (sc2-unit-pos u))
                     (> (pt-dist ax ay (sc2-point3d-x p) (sc2-point3d-y p))
                        (+ SC2-ADDON-FOOTPRINT-HALF-SIZE (max 0.5 (sc2-unit-radius u)))))))
            c-list))

  (define has-completed-pylon?
    (and requires-pylon-power?
         (ormap (lambda (u)
                  (and (= (sc2-unit-alliance u) 1)
                       (not (= (sc2-unit-display-type u) 4))
                       (memq (sc2-id->unit-symbol (sc2-unit-unit-type u) 'unknown)
                             '(pylon pylon-overcharged warp-prism-phasing))
                       (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)))
                existing-units)))
  (define anchors
    (if (and requires-pylon-power? has-completed-pylon?)
        anchors0
        (remove-duplicates (append anchors0 (list safe-base-anchor)))))

  (define spiral-cands
    (let ([all-pts
           (append*
            (for/list ([ap (in-list anchors)])
              (collect-spiral-candidates (car ap) (cdr ap) existing-units
                                         #:min-spacing min-spacing
                                         #:max-radius max-radius
                                         #:step step
                                         #:limit 48
                                         #:extra-reserved-points extra-reserved-points
                                         #:ws-active-placement? ws-active?
                                         #:reserved-aabbs eff-reserved-aabbs
                                         #:expansion-pads expansion-pads
                                         #:bldg-sym canon-bldg
                                         #:game-info game-info)))])
      (dedup-point2ds (take all-pts (min 96 (length all-pts))))))

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
         (if (not (null? addon-clear)) addon-clear raw-cands))]
      [else raw-cands]))

  (define (near-base-emergency-cands)
    (define em-anchor
      (if (and requires-pylon-power? has-completed-pylon?)
          (first anchors)
          safe-base-anchor))
    (collect-spiral-candidates (car em-anchor) (cdr em-anchor) existing-units
                               #:min-spacing (min 2.5 min-spacing)
                               #:max-radius 18.0
                               #:step 1.0
                               #:limit 64
                               #:extra-reserved-points extra-reserved-points
                               #:ws-active-placement? ws-active?
                               #:reserved-aabbs '()
                               #:expansion-pads expansion-pads
                               #:bldg-sym canon-bldg
                               #:game-info game-info))

  (cond
    [(null? cands)
     (define em-cands (near-base-emergency-cands))
     (cond
       [(and ws-active? (not (null? em-cands)))
        (define q-items
          (for/list ([pt (in-list em-cands)])
            (sc2-query-placement ab-id (sc2-point2d-x pt) (sc2-point2d-y pt) 0)))
        (define q-resp
          (sc2-ws-rpc! ws-conn
                       (make-request-query-placement q-items
                                                     #:ignore-resource-requirements? #t)))
        (define q-results (sc2-response-query-placements q-resp))
        (or (for/first ([pt (in-list em-cands)]
                        [res (in-list q-results)]
                        #:when (= res 1))
              pt)
            (first em-cands))]
       [(not (null? em-cands)) (first em-cands)]
       [(and (static-footprint-placement-ok? pl-grid anchor-x anchor-y cand-hw cand-hh)
             (or (not check-bfs) (< (check-bfs anchor-x anchor-y 4) +inf.0)))
        (sc2-point2d anchor-x anchor-y)]
       [else
        (sc2-point2d (car safe-base-anchor) (cdr safe-base-anchor))])]
    [ws-active?
     (cond
       [needs-terran-addon-clearance?
        ;; Dual QueryPlacement: verify both the 3x3 facility at (cx, cy) AND a 2x2 Supply Depot (319)
        ;; at the East (+X) add-on slot (cx + 2.5, cy - 0.5) so add-ons are never blocked by terrain/walls!
        (define (query-dual-batch batch)
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
          (sc2-response-query-placements q-resp))
        (define q-results (query-dual-batch cands))
        (cond
          [(>= (length q-results) (* 2 (length cands)))
           (define wall-seal-pt
             (and first-rax-allow-wall-3x3?
                  (let ([valid-wall-pts
                         (for/list ([pt (in-list cands)]
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
             (for/first ([pt (in-list cands)]
                         [idx (in-naturals 0)]
                         #:when (and (= (list-ref q-results (* 2 idx)) 1)
                                     (= (list-ref q-results (+ (* 2 idx) 1)) 1)))
               pt))
           (define main-valid-pt
             (for/first ([pt (in-list cands)]
                         [idx (in-naturals 0)]
                         #:when (= (list-ref q-results (* 2 idx)) 1))
               pt))
           (cond
             [wall-seal-pt wall-seal-pt]
             [both-valid-pt both-valid-pt]
             [else
              ;; Expand search radius across all anchors (including safe-base-anchor) to find a spot where BOTH 3x3 + East 2x2 add-on fit!
              (define wide-raw
                (let ([pts
                       (append*
                        (for/list ([ap (in-list anchors)])
                          (collect-spiral-candidates (car ap) (cdr ap) existing-units
                                                     #:min-spacing min-spacing
                                                     #:max-radius (max 18.0 (+ max-radius 4.0))
                                                     #:step 2.0
                                                     #:limit 64
                                                     #:extra-reserved-points extra-reserved-points
                                                     #:ws-active-placement? ws-active?
                                                     #:reserved-aabbs eff-reserved-aabbs
                                                     #:expansion-pads expansion-pads
                                                     #:bldg-sym canon-bldg
                                                     #:game-info game-info)))])
                  (dedup-point2ds (take pts (min 96 (length pts))))))
              (define wide-cands
                (let ([ac (filter-addon-clear wide-raw)])
                  (if (not (null? ac)) ac wide-raw)))
              (define-values (wide-both wide-main)
                (if (null? wide-cands)
                    (values #f #f)
                    (let ([w-res (query-dual-batch wide-cands)])
                      (if (>= (length w-res) (* 2 (length wide-cands)))
                          (values
                           (for/first ([pt (in-list wide-cands)]
                                       [idx (in-naturals 0)]
                                       #:when (and (= (list-ref w-res (* 2 idx)) 1)
                                                   (= (list-ref w-res (+ (* 2 idx) 1)) 1)))
                             pt)
                           (for/first ([pt (in-list wide-cands)]
                                       [idx (in-naturals 0)]
                                       #:when (= (list-ref w-res (* 2 idx)) 1))
                             pt))
                          (values #f #f)))))
              (or wide-both
                  main-valid-pt
                  wide-main
                  (let ([em-cands (near-base-emergency-cands)])
                    (and (not (null? em-cands))
                         (let ([em-res (query-dual-batch em-cands)])
                           (and (>= (length em-res) (* 2 (length em-cands)))
                                (or (for/first ([pt (in-list em-cands)]
                                                [idx (in-naturals 0)]
                                                #:when (and (= (list-ref em-res (* 2 idx)) 1)
                                                            (= (list-ref em-res (+ (* 2 idx) 1)) 1)))
                                      pt)
                                    (for/first ([pt (in-list em-cands)]
                                                [idx (in-naturals 0)]
                                                #:when (= (list-ref em-res (* 2 idx)) 1))
                                      pt))))))
                  (if (not (null? spiral-cands)) (first spiral-cands) (first cands)))])]
          [else
           (or (for/first ([pt (in-list cands)]
                           [res (in-list q-results)]
                           #:when (= res 1))
                 pt)
               (if (not (null? spiral-cands)) (first spiral-cands) (first cands)))])]
       [else
        (define (query-single-batch batch)
          (define q-items
            (for/list ([pt (in-list batch)])
              (sc2-query-placement ab-id (sc2-point2d-x pt) (sc2-point2d-y pt) 0)))
          (define q-resp
            (sc2-ws-rpc! ws-conn
                         (make-request-query-placement q-items
                                                       #:ignore-resource-requirements? #t)))
          (define q-results (sc2-response-query-placements q-resp))
          (for/first ([pt (in-list batch)]
                      [res (in-list q-results)]
                      #:when (= res 1))
            pt))
        (define verified-pt (query-single-batch cands))
        (or verified-pt
            (let* ([wide-pts
                    (append*
                     (for/list ([ap (in-list anchors)])
                       (collect-spiral-candidates (car ap) (cdr ap) existing-units
                                                  #:min-spacing min-spacing
                                                  #:max-radius (max 18.0 (+ max-radius 4.0))
                                                  #:step 2.0
                                                  #:limit 64
                                                  #:extra-reserved-points extra-reserved-points
                                                  #:ws-active-placement? ws-active?
                                                  #:reserved-aabbs eff-reserved-aabbs
                                                  #:expansion-pads expansion-pads
                                                  #:bldg-sym canon-bldg
                                                  #:game-info game-info)))]
                   [wide-cands (dedup-point2ds (take wide-pts (min 96 (length wide-pts))))])
              (and (not (null? wide-cands))
                   (query-single-batch wide-cands)))
            (let ([em-cands (near-base-emergency-cands)])
              (and (not (null? em-cands))
                   (query-single-batch em-cands)))
            (if (not (null? spiral-cands)) (first spiral-cands) (first cands)))])]
    [else
     (first cands)]))

(define (find-best-expansion-placement ws-conn th-ab home-x home-y units
                                       #:req-x [req-x #f]
                                       #:req-y [req-y #f]
                                       #:game-info [game-info #f]
                                       #:remembered-enemies [remembered-enemies #f])
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
                                       #:bldg-sym 'hatchery #:game-info game-info)]
    [(and (sc2-ws-conn? ws-conn) (not (sc2-ws-conn-closed? ws-conn)))
     ;; Try up to 6 BFS-ordered open bases until QueryPlacement confirms a valid (= 1) pad!
     (define subset (take candidate-bases (min 6 (length candidate-bases))))
     (define fallback-pt #f)
     (or (for/or ([b (in-list subset)])
           (define cands (pad-candidates-for-base b))
           (when (not fallback-pt)
             (set! fallback-pt (first cands)))
           (and (not (null? cands))
                (let* ([batch (take cands (min 64 (length cands)))]
                       [q-items (for/list ([pt (in-list batch)])
                                  (sc2-query-placement th-ab (sc2-point2d-x pt) (sc2-point2d-y pt) 0))]
                       [q-resp (sc2-ws-rpc! ws-conn
                                            (make-request-query-placement q-items
                                                                          #:ignore-resource-requirements? #t))]
                       [q-results (sc2-response-query-placements q-resp)])
                  (for/first ([pt (in-list batch)]
                              [res (in-list q-results)]
                              #:when (= res 1))
                    pt))))
         fallback-pt
         (sc2-point2d (+ home-x 20.0) (+ home-y 20.0)))]
    [else
     (first (pad-candidates-for-base (first candidate-bases)))]))

(define (select-producer-tags-for-unit unit-sym self-units [enemy-units '()])
  (define norm (normalize-sc2-name->symbol unit-sym))
  ;; Lazily map unit tags to unit structs only when an attached add-on tag (> 0) or unit position is inspected
  (define unit-by-tag-cache #f)
  (define (get-unit-by-tag)
    (or unit-by-tag-cache
        (let ([h (for/hasheqv ([u (in-list self-units)]
                               #:when (not (= (sc2-unit-display-type u) 4)))
                   (values (sc2-unit-tag u) u))])
          (set! unit-by-tag-cache h)
          h)))
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
    (define zero-order-tags '())
    (define second-slot-reactor-tags '())
    (for ([u (in-list self-units)]
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
      (define n-orders (if wg-busy? (max 1 (length (sc2-unit-orders u))) (length (sc2-unit-orders u))))
      (define has-reactor? (and (not needs-techlab?) (facility-has-reactor? u)))
      (define utag (sc2-unit-tag u))
      (cond
        [(= n-orders 0)
         (set! zero-order-tags (cons utag zero-order-tags))
         (when has-reactor?
           (set! second-slot-reactor-tags (cons utag second-slot-reactor-tags)))]
        [(and (= n-orders 1) has-reactor?)
         (set! second-slot-reactor-tags (cons utag second-slot-reactor-tags))]))
    (append (reverse zero-order-tags) (reverse second-slot-reactor-tags)))
  (cond
    ;; Zerg larva-trained units
    [(memq norm '(drone overlord zergling roach hydralisk mutalisk corruptor
                  infestor swarm-host swarmhost ultralisk viper))
     (for/list ([u (in-list self-units)]
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
     (idle-ready-of-types '(zergling))]
    [(eq? norm 'ravager)
     (idle-ready-of-types '(roach))]
    [(memq norm '(lurker lurker-mp))
     (idle-ready-of-types '(hydralisk))]
    [(memq norm '(brood-lord broodlord))
     (idle-ready-of-types '(corruptor))]
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
     (define gws (idle-ready-of-types '(gateway)))
     (if (not (null? gws))
         gws
         (idle-ready-of-types '(warp-gate warpgate)))]
    [(memq norm '(observer immortal warp-prism colossus disruptor))
     (idle-ready-of-types '(robotics-facility))]
    [(memq norm '(phoenix void-ray voidray oracle carrier tempest))
     (idle-ready-of-types '(stargate))]
    [(eq? norm 'archon)
     ;; Safe Archon fusion: ONLY fuse Dark Templar OR non-Storm-ready High Templar (< 75 energy, never >= 75 Storm-ready HTs!)
     ;; and choose the closest/most-depleted eligible pair within 10.0 tiles!
     (define cand-tags (idle-ready-of-types '(high-templar dark-templar)))
     (define ubt (get-unit-by-tag))
     (define eligible-templars
       (filter (lambda (u)
                 (define usym (sc2-id->unit-symbol (sc2-unit-unit-type u)))
                 (or (eq? usym 'dark-templar)
                     (< (sc2-unit-energy u) 75.0)))
               (filter-map (lambda (t) (hash-ref ubt t #f)) cand-tags)))
     (define best-pair #f)
     (define best-score +inf.0)
     (for* ([i (in-range (length eligible-templars))]
            [j (in-range (add1 i) (length eligible-templars))])
       (define u1 (list-ref eligible-templars i))
       (define u2 (list-ref eligible-templars j))
       (define p1 (sc2-unit-pos u1))
       (define p2 (sc2-unit-pos u2))
       (define d (pt-dist (sc2-point3d-x p1) (sc2-point3d-y p1)
                          (sc2-point3d-x p2) (sc2-point3d-y p2)))
       (when (<= d 10.0)
         (define score (+ d (* 0.02 (+ (sc2-unit-energy u1) (sc2-unit-energy u2)))))
         (when (< score best-score)
           (set! best-score score)
           (set! best-pair (list (sc2-unit-tag u1) (sc2-unit-tag u2))))))
     (or best-pair '())]
    [else '()]))

(define (select-researcher-tag upg-sym self-units)
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
  (for/first ([u (in-list self-units)]
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

(define (worker-has-build-order? w)
  (and (not (worker-build-order-stuck? w))
       (ormap (lambda (o)
                (define ab-sym (sc2-id->ability-symbol (sc2-unit-order-ability-id o) #f))
                (and ab-sym (string-prefix? (symbol->string ab-sym) "build-")))
              (sc2-unit-orders w))))

;; Exact Frame-0 Pro Worker Split (`4x2` close patches + `4x1` far patches):
;; Solves exact minimum-sum-Euclidean-distance worker-to-mineral-slot bipartite matching
;; and emits `<= 8` coalesced `HARVEST_GATHER (3666)` wire commands on the opening frame.
(define (frame0-pro-worker-split-commands obs)
  (cond
    [(not (sc2-observation? obs)) '()]
    [else
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
        (define tp0 (sc2-unit-pos th0))
        (define hx (sc2-point3d-x tp0))
        (define hy (sc2-point3d-y tp0))
        (define local-mins
          (sort (filter (lambda (m)
                          (define mp (sc2-unit-pos m))
                          (<= (pt-dist hx hy (sc2-point3d-x mp) (sc2-point3d-y mp)) 11.0))
                        mineral-fields)
                <
                #:key (lambda (m)
                        (define mp (sc2-unit-pos m))
                        (pt-dist hx hy (sc2-point3d-x mp) (sc2-point3d-y mp)))))
        (define base-mins (take local-mins (min 8 (length local-mins))))
        (cond
          [(null? base-mins) '()]
          [else
           (define n (length workers))
           (define n-mins (length base-mins))
           ;; Build `n` target slots: for standard 12 workers & 8 patches -> 4 closest patches get 2 slots, 4 far patches get 1 slot
           (define slots-list
             (cond
               [(<= n n-mins)
                (take base-mins n)]
               [else
                (define extra (- n n-mins))
                (define double-count (min n-mins extra))
                (define base-plus-close
                  (append base-mins (take base-mins double-count)))
                (if (= (length base-plus-close) n)
                    base-plus-close
                    (append base-plus-close
                            (for/list ([k (in-range (- n (length base-plus-close)))])
                              (list-ref base-mins (modulo k n-mins)))))]))
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
             (hash-set! by-patch ptag (cons wtag (hash-ref by-patch ptag '()))))
           (filter-map
            (lambda (m)
              (define ptag (sc2-unit-tag m))
              (define wtags (reverse (hash-ref by-patch ptag '())))
              (and (pair? wtags)
                   (sc2-raw-unit-command 3666 #f ptag wtags #f)))
            base-mins)])])]))

(define SC2-WORKER-TRANSFER-LAST-LOOP (box 0))
(define SC2-WORKER-TRANSFER-COOLDOWN-UNTIL (make-hasheqv))

(define (saturate-workers-and-gas-commands obs
                                           #:excluded-worker-tags [excluded-worker-tags (seteqv)]
                                           #:role-leases [role-leases #f]
                                           #:reserved-aabbs [reserved-aabbs '()]
                                           #:game-info [game-info #f])
  (void reserved-aabbs game-info)
  (define cur-loop (sc2-observation-game-loop obs))
  (when (or (<= cur-loop 8) (< cur-loop (unbox SC2-WORKER-TRANSFER-LAST-LOOP)))
    (hash-clear! SC2-WORKER-TRANSFER-COOLDOWN-UNTIL))
  (set-box! SC2-WORKER-TRANSFER-LAST-LOOP cur-loop)

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
  (define ready-townhalls
    (sort-townhalls-main-first
     (filter (lambda (u)
               (and (sc2-unit-is-townhall? u)
                    (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)
                    (not (sc2-unit-is-flying u))
                    (not (memq (sc2-id->unit-symbol (sc2-unit-unit-type u))
                               '(command-center-flying orbital-command-flying)))))
             self-units)))
  (define ready-gas-bldgs
    (filter (lambda (u)
              (and (sc2-unit-is-gas-building? u)
                   (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)))
            self-units))
  (define all-gas-tags (list->seteqv (map sc2-unit-tag ready-gas-bldgs)))

  (define (worker-returning-cargo? w)
    (or (ormap (lambda (bid) (memv bid '(271 272 273 274 275)))
               (sc2-unit-buff-ids w))
        (ormap (lambda (o)
                 (eq? (sc2-canonical-order-ability (sc2-unit-order-ability-id o))
                      'harvest-return))
               (sc2-unit-orders w))))

  (define workers
    (filter (lambda (w)
              (define wtag (sc2-unit-tag w))
              (and (sc2-unit-is-worker? w)
                   (not (memv 57 (sc2-unit-buff-ids w)))
                   (not (set-member? excluded-worker-tags wtag))
                   (not (and (hash? role-leases)
                             (unit-leased-above? role-leases wtag 'harvester cur-loop)))
                   (not (worker-has-build-order? w))))
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

  ;; Helper: live mineral fields strictly near a specific TownHall (NEVER falls back to cross-map unowned patches!)
  (define (minerals-near-townhall th)
    (define tp (sc2-unit-pos th))
    (filter (lambda (m)
              (define mp (sc2-unit-pos m))
              (<= (pt-dist (sc2-point3d-x tp) (sc2-point3d-y tp)
                           (sc2-point3d-x mp) (sc2-point3d-y mp))
                  SC2-BASE-RESOURCE-RADIUS))
            mineral-fields))

  (define owned-base-minerals
    (if (null? ready-townhalls)
        mineral-fields
        (remove-duplicates (append* (map minerals-near-townhall ready-townhalls)))))

  (define under-gas
    (filter (lambda (u)
              (define gp (sc2-unit-pos u))
              (define eff-assigned
                (max (sc2-unit-assigned-harvesters u)
                     (in-flight-workers-targeting-tag (sc2-unit-tag u))))
              (and (< eff-assigned
                      (max SC2-IDEAL-WORKERS-PER-GEYSER (sc2-unit-ideal-harvesters u)))
                   (or (null? ready-townhalls)
                       (ormap (lambda (th)
                                (define tp (sc2-unit-pos th))
                                (<= (pt-dist (sc2-point3d-x gp) (sc2-point3d-y gp)
                                             (sc2-point3d-x tp) (sc2-point3d-y tp))
                                    SC2-BASE-RESOURCE-RADIUS))
                              ready-townhalls))))
            ready-gas-bldgs))
  (define under-townhalls
    (filter (lambda (th)
              (define ih (sc2-unit-ideal-harvesters th))
              (and (not (null? (minerals-near-townhall th)))
                   (< (sc2-unit-assigned-harvesters th)
                      (if (> ih 0) ih SC2-IDEAL-WORKERS-PER-MINERAL-LINE))))
            ready-townhalls))
  (define over-townhalls
    (filter (lambda (th)
              (define ih (sc2-unit-ideal-harvesters th))
              (> (sc2-unit-assigned-harvesters th)
                 (if (> ih 0) ih SC2-IDEAL-WORKERS-PER-MINERAL-LINE)))
            ready-townhalls))

  (define commanded-this-frame (mutable-seteqv))
  (define cmds '())
  (define (issue-gather! w target-tag)
    (set-add! commanded-this-frame (sc2-unit-tag w))
    (set! cmds
          (cons (sc2-raw-unit-command 3666 #f target-tag (list (sc2-unit-tag w)) #f)
                cmds)))

  ;; 1. Send idle workers to mineral patches at under-saturated owned TownHalls first, or closest owned mineral patch;
  ;;    if no owned mineral patches exist, cancel any expired stuck build order via Stop (3665).
  (cond
    [(and (not (null? idle-workers)) (not (null? owned-base-minerals)))
     (define candidate-mins
       (if (not (null? under-townhalls))
           (minerals-near-townhall (first under-townhalls))
           owned-base-minerals))
     (for ([w (in-list idle-workers)]
           #:when (not (worker-returning-cargo? w)))
       (define wp (sc2-unit-pos w))
       (define best-min
         (argmin (lambda (m)
                   (define mp (sc2-unit-pos m))
                   (pt-dist (sc2-point3d-x wp) (sc2-point3d-y wp)
                            (sc2-point3d-x mp) (sc2-point3d-y mp)))
                 candidate-mins))
       (issue-gather! w (sc2-unit-tag best-min)))]
    [(and (not (null? idle-workers)) (null? owned-base-minerals))
     (for ([w (in-list idle-workers)]
           #:when (worker-build-order-stuck? w cur-loop))
       (set-add! commanded-this-frame (sc2-unit-tag w))
       (set! cmds
             (cons (sc2-raw-unit-command 3665 #f 0 (list (sc2-unit-tag w)) #f)
                   cmds)))])

  ;; 2. Assign 1 worker per step to under-saturated gas building, unified with 350G/600G float caps
  ;;    and graduated mineral-worker floor (0 gas -> >= 6 min workers, 1 gas -> >= 8, >= 2 gas -> >= 10).
  (define gas-over-banked?
    (or (and (>= cur-gas SC2-GAS-FLOAT-REBALANCE-THRESH)
             (< cur-min 250))
        (and (> cur-gas SC2-GAS-FLOAT-PULL-THRESHOLD)
             (< cur-min 450))))
  (define active-gas-worker-count
    (count (lambda (w)
             (or (ormap (lambda (bid) (memv bid '(273 274 275))) (sc2-unit-buff-ids w))
                 (ormap (lambda (o)
                          (set-member? all-gas-tags (sc2-unit-order-target-unit-tag o)))
                        (sc2-unit-orders w))))
           workers))
  (define min-mineral-workers-for-next-gas
    (cond
      [(= active-gas-worker-count 0) 6]
      [(= active-gas-worker-count 1) 8]
      [else 10]))
  (when (and (not (null? under-gas))
             (or (null? owned-base-minerals)
                 (>= (- (length workers) active-gas-worker-count)
                     min-mineral-workers-for-next-gas))
             (not gas-over-banked?))
    (define gb (first under-gas))
    (define gp (sc2-unit-pos gb))
    (define (eligible-for-gas? w)
      (and (not (set-member? commanded-this-frame (sc2-unit-tag w)))
           (not (worker-returning-cargo? w))
           (not (ormap (lambda (o)
                         (set-member? all-gas-tags (sc2-unit-order-target-unit-tag o)))
                       (sc2-unit-orders w)))
           (or (null? (sc2-unit-orders w))
               (for/and ([other-gb (in-list ready-gas-bldgs)])
                 (define ogp (sc2-unit-pos other-gb))
                 (define wp (sc2-unit-pos w))
                 (> (pt-dist (sc2-point3d-x ogp) (sc2-point3d-y ogp)
                             (sc2-point3d-x wp) (sc2-point3d-y wp))
                    SC2-GAS-HARVESTER-EXCLUSION-RADIUS)))))
    (define eligible-idle (filter eligible-for-gas? idle-workers))
    (define eligible-all (filter eligible-for-gas? workers))
    (define candidate-workers
      (if (not (null? eligible-idle)) eligible-idle eligible-all))
    (when (not (null? candidate-workers))
      (define best-w
        (argmin (lambda (w)
                  (define wp (sc2-unit-pos w))
                  (pt-dist (sc2-point3d-x gp) (sc2-point3d-y gp)
                           (sc2-point3d-x wp) (sc2-point3d-y wp)))
                candidate-workers))
      (issue-gather! best-w (sc2-unit-tag gb))))

  ;; 3. Transfer 1 worker per step from over-saturated TownHall to under-saturated expansion,
  ;;    enforcing a >= 2 imbalance deadband + 48-loop per-worker transfer cooldown to prevent ping-pong!
  (when (and (not (null? over-townhalls))
             (not (null? under-townhalls))
             (not (null? owned-base-minerals)))
    (define src-th (first over-townhalls))
    (define dst-th (first under-townhalls))
    (define sp (sc2-unit-pos src-th))
    (define dp (sc2-unit-pos dst-th))
    (define src-ih (let ([ih (sc2-unit-ideal-harvesters src-th)])
                     (if (> ih 0) ih SC2-IDEAL-WORKERS-PER-MINERAL-LINE)))
    (define dst-ih (let ([ih (sc2-unit-ideal-harvesters dst-th)])
                     (if (> ih 0) ih SC2-IDEAL-WORKERS-PER-MINERAL-LINE)))
    (define src-surplus (max 0 (- (sc2-unit-assigned-harvesters src-th) src-ih)))
    (define dst-deficit (max 0 (- dst-ih (sc2-unit-assigned-harvesters dst-th))))
    (define dst-mins (minerals-near-townhall dst-th))
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
    (define transferable
      (filter (lambda (w)
                (define wp (sc2-unit-pos w))
                (define wtag (sc2-unit-tag w))
                (and (not (set-member? commanded-this-frame wtag))
                     (>= cur-loop (hash-ref SC2-WORKER-TRANSFER-COOLDOWN-UNTIL wtag 0))
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
    (when (and (>= (+ src-surplus dst-deficit) 2)
               (> src-surplus in-flight-to-dst)
               (> dst-deficit in-flight-to-dst)
               (not (null? transferable))
               (not (null? dst-mins)))
      (define chosen-w (first transferable))
      (hash-set! SC2-WORKER-TRANSFER-COOLDOWN-UNTIL (sc2-unit-tag chosen-w) (+ cur-loop 48))
      (issue-gather! chosen-w (sc2-unit-tag (first dst-mins)))))

  ;; 4. Pull 1 gas worker back to owned minerals when floating gas while mineral-starved
  (when (and gas-over-banked? (not (null? owned-base-minerals)) (not (null? ready-gas-bldgs)))
    (define cand-mins
      (if (not (null? under-townhalls))
          (minerals-near-townhall (first under-townhalls))
          owned-base-minerals))
    (define gas-worker
      (for/first ([w (in-list workers)]
                  #:when (and (not (set-member? commanded-this-frame (sc2-unit-tag w)))
                              (not (worker-returning-cargo? w))
                              (ormap (lambda (o)
                                       (set-member? all-gas-tags (sc2-unit-order-target-unit-tag o)))
                                     (sc2-unit-orders w))))
        w))
    (when (and gas-worker (not (null? cand-mins)))
      (define wp (sc2-unit-pos gas-worker))
      (define best-min
        (argmin (lambda (m)
                  (define mp (sc2-unit-pos m))
                  (pt-dist (sc2-point3d-x wp) (sc2-point3d-y wp)
                           (sc2-point3d-x mp) (sc2-point3d-y mp)))
                cand-mins))
      (issue-gather! gas-worker (sc2-unit-tag best-min))))

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
              (cons (sc2-raw-unit-command 3666 #f (sc2-unit-tag best-m) (list (sc2-unit-tag u)) #f)
                    cmds)))))

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
(define SC2-LAST-BOT-ACTION-REJECTS (box '()))
(define SC2-TOTAL-BOT-ACTION-REJECT-COUNT (box 0))

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
                                                 #:game-info [game-info #f])
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
        (unbox SC2-ACTIVE-GAME-INFO)))
  (when (sc2-observation? obs)
    (when (or (< cur-loop (unbox SC2-ENEMY-POS-LAST-LOOP))
              (and (<= cur-loop 8) (> (unbox SC2-ENEMY-POS-LAST-LOOP) 8)))
      (hash-clear! SC2-LAST-KNOWN-ENEMY-POS)
      (hash-clear! SC2-DEPOT-TOGGLE-COOLDOWN)
      (set-box! SC2-CLEARED-ENEMY-BASES '())
      (set-box! SC2-CACHED-MAP-BASE-CLUSTERS '())
      (set-box! SC2-CORNER-SCAN-LAST-LOOP -9999))
    (set-box! SC2-ENEMY-POS-LAST-LOOP cur-loop)
    (define raw-dead (sc2-observation-dead-unit-tags obs))
    (when (list? raw-dead)
      (for ([dtag (in-list raw-dead)]
            #:when (valid-u64-tag? dtag))
        (hash-remove! SC2-LAST-KNOWN-ENEMY-POS dtag))))
  (define units
    (if (and (sc2-observation? obs) (list? (sc2-observation-units obs)))
        (filter-map sanitize-obs-unit (sc2-observation-units obs))
        '()))
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
  (define self-units
    (filter (lambda (u)
              (and (= (sc2-unit-alliance u) 1)
                  (not (= (sc2-unit-display-type u) 4))))
            units))
  (define enemy-units
    (filter (lambda (u)
              (and (= (sc2-unit-alliance u) 4)
                   (not (= (sc2-unit-display-type u) 4))))
            units))
  (define neutral-units (filter (lambda (u) (= (sc2-unit-alliance u) 3)) units))
  (define mineral-fields (filter sc2-unit-is-mineral-field? neutral-units))
  (define step-resource-units
    (filter (lambda (u) (or (sc2-unit-is-mineral-field? u) (sc2-unit-is-vespene-geyser? u)))
            neutral-units))
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
  (for ([eu (in-list enemy-units)])
    (define etag (sc2-unit-tag eu))
    (define ep (sc2-unit-pos eu))
    (when (valid-u64-tag? etag)
      (hash-set! SC2-LAST-KNOWN-ENEMY-POS etag
                 (cons (sc2-point3d-x ep) (sc2-point3d-y ep)))
      (when (and (= (sc2-unit-display-type eu) 1)
                 (> (+ (sc2-unit-health eu) (sc2-unit-shield eu)) 0.0))
        (set-add! live-visible-enemy-tags etag))))
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
  ;; Purge stale remembered enemy coordinates once friendly vision covers their tile with no live unit present
  (when (not (null? self-units))
    (define stale-etags
      (for/list ([(etag pt) (in-hash SC2-LAST-KNOWN-ENEMY-POS)]
                 #:when (and (pair? pt)
                             (not (set-member? live-visible-enemy-tags etag))
                             (ormap (lambda (u)
                                      (define up (sc2-unit-pos u))
                                      (<= (pt-dist (sc2-point3d-x up) (sc2-point3d-y up)
                                                   (car pt) (cdr pt))
                                          7.0))
                                    self-units)))
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
  (define workers
    (filter (lambda (w)
              (and (sc2-unit-is-worker? w)
                   (not (memv 57 (sc2-unit-buff-ids w)))))
            self-units))
  (define active-friendly-th-build-pads
    (for*/list ([w (in-list workers)]
                #:when (not (worker-build-order-stuck? w))
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
  (define townhalls (sort-townhalls-main-first (filter sc2-unit-is-townhall? self-units)))
  (define combat-units
    (filter (lambda (u)
              (define sym (sc2-id->unit-symbol (sc2-unit-unit-type u)))
              (and (not (sc2-unit-is-structure? u))
                   (not (sc2-unit-is-worker? u))
                   (not (memv 57 (sc2-unit-buff-ids u)))
                   (not (sc2-non-combat-or-summon-sym? sym))
                   (not (memq sym '(larva egg queen)))
                   (not (and (hash? role-leases)
                             (unit-leased-above? role-leases (sc2-unit-tag u) 'army cur-loop)))))
            self-units))
  (define total-combat-supply
    (for/sum ([u (in-list combat-units)])
      (define sym (sc2-id->unit-symbol (sc2-unit-unit-type u)))
      (max 1 (sc2-supply-cost sym))))
  (define can-push-or-sweep?
    (or (>= (length combat-units) 14)
        (>= total-combat-supply 20)
        (and (>= cur-loop 6000)
             (null? enemy-units)
             (>= (length combat-units) 4))))
  (define sweep-context-active?
    (or (not (null? mineral-fields))
        (not (null? (unbox SC2-CACHED-MAP-BASE-CLUSTERS)))
        (>= cur-loop 6000)
        (sc2-game-info? eff-game-info)))
  (define self-unit-by-tag
    (for/hasheqv ([u (in-list self-units)])
      (values (sc2-unit-tag u) u)))

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
  (define step-reserved-build-pts '())
  (define last-cam-pt #f)

  (define step-scout-worker-tags
    (for/fold ([s (seteqv)]) ([act (in-list (if (list? actions) actions '()))])
      (match act
        [(list (or 'worker-scout 'worker-harass) (? exact-integer? wid) _ _)
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

  (define (record-unit-used! utag)
    (when utag
      (set-add! commanded-combat-tags utag)))

  (define gas-bldg-tags-set
    (for/seteqv ([u (in-list self-units)]
                 #:when (sc2-unit-is-gas-building? u))
      (sc2-unit-tag u)))

  (define (worker-carrying-cargo? w)
    (or (ormap (lambda (bid) (memv bid '(271 272 273 274 275)))
               (sc2-unit-buff-ids w))
        (and (pair? (sc2-unit-orders w))
             (eq? (sc2-canonical-order-ability
                   (sc2-unit-order-ability-id (first (sc2-unit-orders w))))
                  'harvest-return))))

  (define (worker-is-gas-harvester? w)
    (ormap (lambda (o)
             (set-member? gas-bldg-tags-set (sc2-unit-order-target-unit-tag o)))
           (sc2-unit-orders w)))

  (define (pick-worker-near tx ty)
    (define non-scout-avail
      (filter (lambda (w)
                (define wtag (sc2-unit-tag w))
                (define wp (sc2-unit-pos w))
                (define wx (sc2-point3d-x wp))
                (define wy (sc2-point3d-y wp))
                (and (not (set-member? used-worker-tags wtag))
                     (not (set-member? builder-worker-tags wtag))
                     (not (worker-has-build-order? w))
                     (not (set-member? step-scout-worker-tags wtag))
                     (not (worker-is-gas-harvester? w))
                     (not (and (hash? role-leases)
                               (unit-leased-above? role-leases wtag 'harvester cur-loop)))
                     (or (<= (pt-dist home-x home-y wx wy) 28.0)
                         (<= (pt-dist tx ty wx wy) 24.0))))
              workers))
    (define pool
      (if (not (null? non-scout-avail))
          non-scout-avail
          (filter (lambda (w)
                    (define wtag (sc2-unit-tag w))
                    (and (not (set-member? used-worker-tags wtag))
                         (not (set-member? builder-worker-tags wtag))
                         (not (worker-has-build-order? w))
                         (not (set-member? step-scout-worker-tags wtag))
                         (not (and (hash? role-leases)
                                   (unit-leased-above? role-leases wtag 'door-guard cur-loop)))))
                  workers)))
    (if (null? pool)
        #f
        (let ([chosen
               (sc2-unit-tag
                (argmin (lambda (w)
                          (define wp (sc2-unit-pos w))
                          (+ (pt-dist tx ty (sc2-point3d-x wp) (sc2-point3d-y wp))
                             (if (null? (sc2-unit-orders w)) 0.0 4.0)
                             (if (worker-carrying-cargo? w) 25.0 0.0)
                             (if (worker-is-gas-harvester? w) 12.0 0.0)))
                        pool))])
          (record-worker-used! chosen #t)
          (when (hash? role-leases)
            (acquire-unit-lease! role-leases chosen 'builder cur-loop 224 #:x tx #:y ty))
          chosen)))

  (define (find-open-geyser near-x near-y)
    (define geysers (filter sc2-unit-is-vespene-geyser? neutral-units))
    (define gas-bldgs (filter sc2-unit-is-gas-building? self-units))
    (define in-flight-geyser-tags
      (for*/seteqv ([w (in-list workers)]
                    [o (in-list (sc2-unit-orders w))]
                    #:when (> (sc2-unit-order-target-unit-tag o) 0))
        (sc2-unit-order-target-unit-tag o)))
    (define open-all
      (filter (lambda (g)
                (define gp (sc2-unit-pos g))
                (define gtag (sc2-unit-tag g))
                (and (not (set-member? used-geyser-tags gtag))
                     (not (set-member? in-flight-geyser-tags gtag))
                     (not (ormap (lambda (gb)
                                   (define bp (sc2-unit-pos gb))
                                   (<= (pt-dist (sc2-point3d-x gp) (sc2-point3d-y gp)
                                                (sc2-point3d-x bp) (sc2-point3d-y bp))
                                       SC2-GEYSER-OCCUPIED-RADIUS))
                                 gas-bldgs))))
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
      (for/list ([u (in-list self-units)]
                 #:when (and (memq (sc2-id->unit-symbol (sc2-unit-unit-type u))
                                   '(pylon pylon-overcharged warp-prism-phasing))
                             (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)))
        (define p (sc2-unit-pos u))
        (cons (sc2-point3d-x p) (sc2-point3d-y p))))
    (define combined (remove-duplicates (append ps-pts pylon-pts)))
    (if (null? combined)
        (list (cons near-x near-y))
        (sort combined
              <
              #:key (lambda (pt) (pt-dist near-x near-y (car pt) (cdr pt))))))

  (define (pylon-power-anchor [near-x home-x] [near-y home-y])
    (define anchors (pylon-power-anchors near-x near-y))
    (values (caar anchors) (cdar anchors)))

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
                   (not (and u (worker-has-build-order? u)))
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
                     (not (set-member? commanded-combat-tags t))
                     (not (set-member? used-worker-tags t))
                     (not (and u (worker-has-build-order? u)))
                     (not (unit-has-protected-order? t))
                     (not (and (hash? role-leases)
                               (unit-leased-above? role-leases t 'army cur-loop)))))
              (if (list? raw-ids) raw-ids (list raw-ids))))
    (for/list ([t (in-list candidates)]
               #:when (begin
                        (set-add! commanded-combat-tags t)
                        (not (unit-already-executing-order? t ab-id target-pt target-unit-id))))
      t))

  (define raw-cmds '())
  (define (emit! cmd)
    (when cmd
      (set! raw-cmds (cons cmd raw-cmds))))

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
        (emit! (sc2-raw-unit-command 399 (sc2-point2d cx cy) 0 (list (sc2-unit-tag ready-oc)) #f)))))

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
               (or (>= cur-loop 6000)
                   (null? mineral-fields)
                   (not (memq usym '(medivac warp-prism))))))
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
      (emit! (sc2-raw-camera-move cx cy 0.0))))

  ;; Partition actions so that:
  ;;   1. Priority worker build/expand/scout/harass and tactical recon/harass actions execute first
  ;;      (claiming their worker and raider tags in `used-worker-tags` / `commanded-combat-tags`),
  ;;   2. Standard production, upgrade, micro, and spatial maneuvers execute second, and
  ;;   3. Routine mineral/gas harvest actions execute last (and skip any claimed/building worker).
  (define (priority-first-action? a)
    (and (pair? a)
         (memq (car a)
               '(build build-nydus-worm expand resume-halted-building
                 worker-scout overlord-scout periodic-scout scout-sector
                 mineral-harass worker-harass harass-workers
                 patrol-block-expansion burrow-block clear-expansion-block
                 cast-deception-and-scout-spells
                 pull-workers-attack worker-drill-stack-attack mineral-walk))))
  (define (routine-harvest-action? a)
    (and (pair? a)
         (memq (car a) '(harvest-mineral harvest-gas rebalance-gas-to-minerals))))
  (define ordered-actions
    (append (filter priority-first-action? actions)
            (filter (lambda (a)
                      (and (not (priority-first-action? a))
                           (not (routine-harvest-action? a))))
                    actions)
            (filter routine-harvest-action? actions)))

  (for ([act (in-list ordered-actions)])
    (match act
      ;; 1. Train unit: `(train <unit-sym>)` or `(train-unit <prod-id> <unit-sym>)`
      [(or (list 'train unit-sym)
           (list 'train-unit _ unit-sym))
       (define ab-id (train-symbol->ability-id unit-sym))
       (define all-prod-tags (select-producer-tags-for-unit unit-sym self-units enemy-units))
       (define prod-tags
         (filter (lambda (t)
                   (< (hash-ref used-producer-counts t 0)
                      (count (lambda (x) (= x t)) all-prod-tags)))
                 all-prod-tags))
       (when (and ab-id (not (null? prod-tags)))
         (define ptag (first prod-tags))
         (hash-set! used-producer-counts ptag (add1 (hash-ref used-producer-counts ptag 0)))
         (set-add! used-producer-tags ptag)
         (define prod-u (hash-ref self-unit-by-tag ptag #f))
         ;; Bug #17 fix: if producer is a WarpGate (133), issue WARP_IN_* at an open Pylon power-field point
         ;; (never pass unit warp-in ability IDs 1413..1419 to RequestQueryBuildingPlacement, which rejects non-buildings
         ;; and falls back to the Pylon center!)
         (cond
           [(and prod-u (= (sc2-unit-unit-type prod-u) 133))
            (define wg-cd-loops
              (case (normalize-sc2-name->symbol unit-sym)
                [(zealot adept)               448]
                [(stalker sentry)             515]
                [(high-templar dark-templar)  717]
                [else                         515]))
            (when (and (sc2-observation? obs) (> (sc2-observation-game-loop obs) 0))
              (set-box! SC2-WARPGATE-LAST-LOOP (sc2-observation-game-loop obs))
              (hash-set! SC2-WARPGATE-COOLDOWN-UNTIL ptag
                         (+ (sc2-observation-game-loop obs) wg-cd-loops)))
            (define warp-ab (or (unit-symbol->warp-in-ability-id unit-sym) ab-id))
            (define-values (px py) (pylon-power-anchor))
            (define anchors (pylon-power-anchors px py))
            (define (valid-warp-spot? wx wy ax ay)
              (define adist (pt-dist wx wy ax ay))
              (and (>= wx SC2-MAP-PLAYABLE-MIN-COORD) (<= wx SC2-MAP-PLAYABLE-MAX-COORD)
                   (>= wy SC2-MAP-PLAYABLE-MIN-COORD) (<= wy SC2-MAP-PLAYABLE-MAX-COORD)
                   (>= adist 2.0) (<= adist 5.5)
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
            (define warp-pt
              (or (for*/first ([ap (in-list anchors)]
                               [r (in-list '(2.5 3.5 4.5 5.2))]
                               [dx (in-range (- r) (+ r 0.01) 1.0)]
                               [dy (in-range (- r) (+ r 0.01) 1.0)]
                               #:when (or (>= (abs dx) (- r 0.5)) (>= (abs dy) (- r 0.5)))
                               [wx (in-value (+ (car ap) dx))]
                               [wy (in-value (+ (cdr ap) dy))]
                               #:when (valid-warp-spot? wx wy (car ap) (cdr ap)))
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
       (when ab-id
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
              (set-add! used-producer-tags nydus-net-tag)
              (hash-set! used-producer-counts nydus-net-tag
                         (add1 (hash-ref used-producer-counts nydus-net-tag 0)))
              (define worm-pt
                (find-verified-building-placement ws-conn 1768 req-x req-y units
                                                  #:min-spacing 2.0
                                                  #:max-radius 10.0
                                                  #:step 1.0
                                                  #:extra-reserved-points step-reserved-build-pts
                                                  #:reserved-aabbs reserved-aabbs
                                                  #:expansion-pads all-expansion-pads
                                                  #:bldg-sym 'nydus-worm
                                                  #:game-info eff-game-info))
              (reserve-step-build-pt! worm-pt 1768)
              (emit! (sc2-raw-unit-command 1768 worm-pt 0 (list nydus-net-tag) #f)))]

           ;; Morph-in-place townhall/spire upgrades (Lair, Hive, Greater Spire, Orbital, Planetary)
           [(memq norm '(lair hive greater-spire orbital-command planetary-fortress))
            (define src-types
              (case norm
                [(lair) '(hatchery)]
                [(hive) '(lair)]
                [(greater-spire) '(spire)]
                [(orbital-command planetary-fortress) '(command-center)]
                [else '()]))
            (define src-u
              (for/first ([u (in-list self-units)]
                          #:when (and (memq (sc2-id->unit-symbol (sc2-unit-unit-type u)) src-types)
                                      (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)
                                      (null? (sc2-unit-orders u))
                                      (not (set-member? used-producer-tags (sc2-unit-tag u)))))
                u))
            (when src-u
              (set-add! used-producer-tags (sc2-unit-tag src-u))
              (hash-set! used-producer-counts (sc2-unit-tag src-u)
                         (add1 (hash-ref used-producer-counts (sc2-unit-tag src-u) 0)))
              (emit! (sc2-raw-unit-command ab-id #f 0 (list (sc2-unit-tag src-u)) #f)))]

           ;; Terran Add-ons (Tech Lab & Reactor) built directly by an idle un-attached facility
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
                             (null? (sc2-unit-orders u))
                             (not (set-member? used-producer-tags (sc2-unit-tag u)))))
                      self-units))
            (define fac-u
              (cond
                [(null? cand-facs) #f]
                [(and (sc2-ws-conn? ws-conn) (not (sc2-ws-conn-closed? ws-conn)))
                 (define q-items
                   (for/list ([u (in-list cand-facs)])
                     (define p (sc2-unit-pos u))
                     (sc2-query-placement 319
                                          (+ (sc2-point3d-x p) SC2-TERRAN-ADDON-OFFSET-X)
                                          (+ (sc2-point3d-y p) SC2-TERRAN-ADDON-OFFSET-Y)
                                          0)))
                 (define q-resp
                   (sc2-ws-rpc! ws-conn
                                (make-request-query-placement q-items
                                                              #:ignore-resource-requirements? #t)))
                 (define q-results (sc2-response-query-placements q-resp))
                 (if (= (length q-results) (length cand-facs))
                     (for/first ([u (in-list cand-facs)]
                                 [res (in-list q-results)]
                                 #:when (= res 1))
                       u)
                     (first cand-facs))]
                [else (first cand-facs)]))
            (when fac-u
              (set-add! used-producer-tags (sc2-unit-tag fac-u))
              (hash-set! used-producer-counts (sc2-unit-tag fac-u)
                         (add1 (hash-ref used-producer-counts (sc2-unit-tag fac-u) 0)))
              (emit! (sc2-raw-unit-command ab-id #f 0 (list (sc2-unit-tag fac-u)) #f)))]

           ;; Vespene gas building targets a neutral geyser unit tag
           [(memq norm '(extractor refinery assimilator))
            (define geyser (find-open-geyser req-x req-y))
            (when geyser
              (define gp (sc2-unit-pos geyser))
              (define wtag (pick-worker-near (sc2-point3d-x gp) (sc2-point3d-y gp)))
              (when wtag
                (emit! (sc2-raw-unit-command ab-id #f (sc2-unit-tag geyser) (list wtag) #f))))]

           ;; Protoss structures requiring Pylon power field (searches across all Pylons)
           [(memq norm '(gateway forge cybernetics-core photon-cannon shield-battery
                         twilight-council robotics-facility robotics-bay robotics-support-bay
                         stargate templar-archive templar-archives dark-shrine fleet-beacon))
            (define-values (px py) (pylon-power-anchor req-x req-y))
            (define place-pt
              (find-verified-building-placement ws-conn ab-id px py units
                                                #:min-spacing 2.0
                                                #:max-radius 6.5
                                                #:step 1.0
                                                #:extra-reserved-points step-reserved-build-pts
                                                #:anchor-points (pylon-power-anchors req-x req-y)
                                                #:reserved-aabbs reserved-aabbs
                                                #:expansion-pads all-expansion-pads
                                                #:bldg-sym norm
                                                #:game-info eff-game-info))
            (reserve-step-build-pt! place-pt ab-id)
            (define wtag (pick-worker-near (sc2-point2d-x place-pt) (sc2-point2d-y place-pt)))
            (when wtag
              (emit! (sc2-raw-unit-command ab-id place-pt 0 (list wtag) #f)))]

           ;; Zerg structures requiring Creep (including Lurker Den built by Drone via 1163!)
           [(memq norm '(spawning-pool evolution-chamber roach-warren baneling-nest
                         hydralisk-den lurker-den lurker-den-mp spire infestation-pit ultralisk-cavern
                         nydus-network spine-crawler spore-crawler))
            (define safe-creep-pts (ordered-zerg-creep-anchors req-x req-y))
            (define cx (caar safe-creep-pts))
            (define cy (cdar safe-creep-pts))
            (define place-pt
              (find-verified-building-placement ws-conn ab-id cx cy units
                                                #:min-spacing 2.0
                                                #:max-radius 8.5
                                                #:step 1.0
                                                #:extra-reserved-points step-reserved-build-pts
                                                #:anchor-points safe-creep-pts
                                                #:reserved-aabbs reserved-aabbs
                                                #:expansion-pads all-expansion-pads
                                                #:bldg-sym norm
                                                #:game-info eff-game-info))
            (reserve-step-build-pt! place-pt ab-id)
            (define wtag (pick-worker-near (sc2-point2d-x place-pt) (sc2-point2d-y place-pt)))
            (when wtag
              (emit! (sc2-raw-unit-command ab-id place-pt 0 (list wtag) #f)))]

           ;; Standard ground building placement (Pylons, Supply Depots, Barracks, Factories, Starports, etc.)
           [else
            (define std-anchors
              (remove-duplicates (list (cons req-x req-y) (cons home-x home-y))))
            (define place-pt
              (find-verified-building-placement ws-conn ab-id req-x req-y units
                                                #:min-spacing 3.0
                                                #:max-radius 14.0
                                                #:step 2.0
                                                #:extra-reserved-points step-reserved-build-pts
                                                #:anchor-points std-anchors
                                                #:reserved-aabbs reserved-aabbs
                                                #:expansion-pads all-expansion-pads
                                                #:bldg-sym norm
                                                #:game-info eff-game-info))
            (reserve-step-build-pt! place-pt ab-id)
            (define wtag (pick-worker-near (sc2-point2d-x place-pt) (sc2-point2d-y place-pt)))
            (when wtag
              (emit! (sc2-raw-unit-command ab-id place-pt 0 (list wtag) #f)))]))]

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
         (set-add! used-producer-tags nydus-net-tag)
         (hash-set! used-producer-counts nydus-net-tag
                    (add1 (hash-ref used-producer-counts nydus-net-tag 0)))
         (define worm-pt
           (find-verified-building-placement ws-conn 1768 req-x req-y units
                                             #:min-spacing 2.0
                                             #:max-radius 10.0
                                             #:step 1.0
                                             #:extra-reserved-points step-reserved-build-pts
                                             #:reserved-aabbs reserved-aabbs
                                             #:expansion-pads all-expansion-pads
                                             #:bldg-sym 'nydus-worm
                                             #:game-info eff-game-info))
         (reserve-step-build-pt! worm-pt 1768)
         (emit! (sc2-raw-unit-command 1768 worm-pt 0 (list nydus-net-tag) #f)))]

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
                                        #:remembered-enemies SC2-LAST-KNOWN-ENEMY-POS))
       (reserve-step-build-pt! exp-pt th-ab)
       (define wtag (pick-worker-near (sc2-point2d-x exp-pt) (sc2-point2d-y exp-pt)))
       (when wtag
         (set! active-friendly-th-build-pads
               (cons (cons (sc2-point2d-x exp-pt) (sc2-point2d-y exp-pt))
                     active-friendly-th-build-pads))
         (emit! (sc2-raw-unit-command th-ab exp-pt 0 (list wtag) #f)))]

      ;; 4. Research upgrade: `(research <upg-sym>)`
      [(list 'research upg-sym)
       (define ab-id (research-symbol->ability-id upg-sym))
       (define rtag (select-researcher-tag upg-sym self-units))
       (when (and ab-id rtag (not (set-member? used-producer-tags rtag)))
         (set-add! used-producer-tags rtag)
         (hash-set! used-producer-counts rtag (add1 (hash-ref used-producer-counts rtag 0)))
         (emit! (sc2-raw-unit-command ab-id #f 0 (list rtag) #f)))]

      ;; 5. Morph unit/structure: `(morph <unit-id-or-ids> <target-sym>)` or `(morph <target-sym>)`
      [(list 'morph uid target-sym)
       (define norm-target (normalize-sc2-name->symbol target-sym))
       (cond
         [(memq norm-target '(lurker-den lurker-den-mp))
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
                                              #:game-info eff-game-info))
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
            (emit! (sc2-raw-unit-command 1163 place-pt 0 (list wtag) #f)))]
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
               (let* ([extra (filter (lambda (t)
                                       (and (not (set-member? used-producer-tags t))
                                            (not (memv t raw-uid-list))))
                                     (select-producer-tags-for-unit 'archon self-units enemy-units))]
                      [combined (remove-duplicates (append raw-uid-list extra))])
                 (if (>= (length combined) 2) (take combined 2) '()))]
              [(and (not (null? self-units))
                    (memq norm-target '(lair hive greater-spire orbital-command planetary-fortress warp-gate warpgate)))
               (define valid-idle
                 (filter (lambda (t)
                           (define su (hash-ref self-unit-by-tag t #f))
                           (and su
                                (>= (sc2-unit-build-progress su) SC2-BUILD-COMPLETE-PROGRESS)
                                (not (sc2-unit-is-flying su))
                                (null? (sc2-unit-orders su))))
                         raw-uid-list))
               (if (not (null? valid-idle))
                   valid-idle
                   (let ([fb (filter (lambda (t) (not (set-member? used-producer-tags t)))
                                     (select-producer-tags-for-unit norm-target self-units enemy-units))])
                     (if (not (null? fb)) (list (first fb)) '())))]
              [else raw-uid-list]))
          (when (and ab-id (not (null? uid-list)))
            (for ([t (in-list uid-list)])
              (set-add! used-producer-tags t)
              (hash-set! used-producer-counts t (add1 (hash-ref used-producer-counts t 0))))
            (emit! (sc2-raw-unit-command ab-id #f 0 uid-list #f)))])]
      [(list 'morph target-sym)
       (define norm-target (normalize-sc2-name->symbol target-sym))
       (cond
         [(memq norm-target '(lurker-den lurker-den-mp))
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
                                              #:game-info eff-game-info))
          (reserve-step-build-pt! place-pt 1163)
          (define wtag (pick-worker-near (sc2-point2d-x place-pt) (sc2-point2d-y place-pt)))
          (when wtag
            (emit! (sc2-raw-unit-command 1163 place-pt 0 (list wtag) #f)))]
         [(eq? norm-target 'archon)
          (define ab-id (morph-symbol->ability-id norm-target))
          (define ptags
            (remove-duplicates
             (filter (lambda (t) (not (set-member? used-producer-tags t)))
                     (select-producer-tags-for-unit norm-target self-units enemy-units))))
          (when (and ab-id (>= (length ptags) 2))
            (define chosen2 (take ptags 2))
            (for ([t (in-list chosen2)])
              (set-add! used-producer-tags t)
              (hash-set! used-producer-counts t (add1 (hash-ref used-producer-counts t 0))))
            (emit! (sc2-raw-unit-command ab-id #f 0 chosen2 #f)))]
         [else
          (define ab-id (morph-symbol->ability-id norm-target))
          (define ptags
            (filter (lambda (t) (not (set-member? used-producer-tags t)))
                    (select-producer-tags-for-unit norm-target self-units enemy-units)))
          (when (and ab-id (not (null? ptags)))
            (define ptag (first ptags))
            (set-add! used-producer-tags ptag)
            (hash-set! used-producer-counts ptag (add1 (hash-ref used-producer-counts ptag 0)))
            (emit! (sc2-raw-unit-command ab-id #f 0 (list ptag) #f)))])]

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
            (emit! (sc2-raw-unit-command 23 #f target-id tag-list #f)))]
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

      [(list 'focus-fire uid target-id rest ...)
       #:when (and (or (exact-integer? uid) (list? uid)) (exact-integer? target-id))
       (cond
         [(or (not enforce-live-enemy-tag-filter?)
              (set-member? live-visible-enemy-tags target-id))
          (define tag-list (claim-combat-tags-for-order! uid 23 #f target-id))
          (when (not (null? tag-list))
            (emit! (sc2-raw-unit-command 23 #f target-id tag-list #f)))]
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
              (emit! (sc2-raw-unit-command 3666 #f patch-id need-cmd #f)))]
           [else
            (define target-pt (sc2-point2d tx ty))
            (define need-cmd
              (filter (lambda (wt)
                        (not (unit-already-executing-order? wt 16 target-pt 0)))
                      wlist))
            (when (not (null? need-cmd))
              (emit! (sc2-raw-unit-command 16 target-pt 0 need-cmd #f)))]))]

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
              (emit! (sc2-raw-unit-command 3666 #f best-min-tag need-cmd #f))))]
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
              (emit! (sc2-raw-unit-command 16 target-pt 0 need-cmd #f))))])]

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
                        (not (set-member? used-worker-tags t))
                        (not (and u (worker-has-build-order? u)))
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
                     cloak-banshee medivac-boost immortal-barrier prismatic-alignment
                     build-interceptors pulsar-beam pulsar-beam-on pulsar-beam-off)))
           (unless off-gcd-buff?
             (for ([cid (in-list caster-ids)])
               (set-add! commanded-combat-tags cid)))
           (cond
             ;; Case A: Ability requires NO target (Stimpack, Guardian Shield, Siege/Unsiege, Burrow, Cloak, Build Interceptors, Pulsar Beam, etc.)
             [(set-member? SC2-NO-TARGET-ABILITY-IDS ab-id)
              (if (= ab-id 1766)
                  (when (>= (length caster-ids) 2)
                    (emit! (sc2-raw-unit-command 1766 #f 0 (take caster-ids 2) #f)))
                  (emit! (sc2-raw-unit-command ab-id #f 0 caster-ids #f)))]

             ;; Case B: Creep Tumor placement (verified radial fan on Creep; never consume 1733 cooldown if unplaceable)
             [(memv ab-id '(1662 1694 1733 3691))
              (unless (and (memv ab-id '(1662 1694 3691)) (unit-has-protected-order? caster-id))
                (define raw-x (if (>= (length rest) 2) (first rest) home-x))
                (define raw-y (if (>= (length rest) 2) (second rest) home-y))
                (define tx (scale-bot-coord-to-world raw-x home-x))
                (define ty (scale-bot-coord-to-world raw-y home-y))
                (define-values (ox oy)
                  (if caster-u
                      (let ([cp (sc2-unit-pos caster-u)])
                        (values (sc2-point3d-x cp) (sc2-point3d-y cp)))
                      (values tx ty)))
                (define base-ang
                  (let ([dx (- tx ox)]
                        [dy (- ty oy)])
                    (if (< (+ (* dx dx) (* dy dy)) 0.25)
                        (atan (- (* 0.5 SC2-DEFAULT-MAP-HEIGHT) oy)
                              (- (* 0.5 SC2-DEFAULT-MAP-WIDTH) ox))
                        (atan dy dx))))
                (define (tumor-cand-clear? px py)
                  (and (>= px SC2-MAP-PLAYABLE-MIN-COORD) (<= px SC2-MAP-PLAYABLE-MAX-COORD)
                       (>= py SC2-MAP-PLAYABLE-MIN-COORD) (<= py SC2-MAP-PLAYABLE-MAX-COORD)
                       (for/and ([ep (in-list all-expansion-pads)])
                         (>= (max (abs (- px (car ep))) (abs (- py (cdr ep)))) 4.5))
                       (for/and ([rp (in-list step-reserved-build-pts)]
                                 #:when (any-point? rp))
                         (> (pt-dist px py (any-point-x rp) (any-point-y rp)) 1.5))
                       (for/and ([u (in-list units)]
                                 #:when (and (not (sc2-unit-is-flying u))
                                             (or (sc2-unit-is-structure? u)
                                                 (sc2-unit-is-mineral-field? u)
                                                 (sc2-unit-is-vespene-geyser? u))))
                         (define up (sc2-unit-pos u))
                         (> (pt-dist px py (sc2-point3d-x up) (sc2-point3d-y up))
                            (+ 0.75 (max 0.5 (sc2-unit-radius u)))))))
                (define fan-cands
                  (if (= ab-id 1733)
                      (for*/list ([r (in-list '(9.5 8.5 7.5 6.5 5.5))]
                                  [da (in-list '(0.0 0.26 -0.26 0.52 -0.52 0.78 -0.78 1.05 -1.05 1.31 -1.31))]
                                  [px (in-value (+ (floor (+ ox (* r (cos (+ base-ang da))))) 0.5))]
                                  [py (in-value (+ (floor (+ oy (* r (sin (+ base-ang da))))) 0.5))]
                                  #:when (tumor-cand-clear? px py))
                        (sc2-point2d px py))
                      (for*/list ([r (in-list '(3.5 2.5 4.2 1.8))]
                                  [da (in-list '(0.0 0.52 -0.52 1.05 -1.05 1.57 -1.57 2.09 -2.09 2.62 -2.62 3.14))]
                                  [px (in-value (+ (floor (+ ox (* r (cos (+ base-ang da))))) 0.5))]
                                  [py (in-value (+ (floor (+ oy (* r (sin (+ base-ang da))))) 0.5))]
                                  #:when (tumor-cand-clear? px py))
                        (sc2-point2d px py))))
                (define dedup-fan
                  (let ([seen (make-hash)])
                    (filter (lambda (pt)
                              (define k (cons (sc2-point2d-x pt) (sc2-point2d-y pt)))
                              (if (hash-has-key? seen k) #f (begin (hash-set! seen k #t) #t)))
                            fan-cands)))
                (define verified-tumor-pt
                  (cond
                    [(null? dedup-fan) #f]
                    [(and (sc2-ws-conn? ws-conn) (not (sc2-ws-conn-closed? ws-conn)))
                     (define q-items
                       (for/list ([pt (in-list dedup-fan)])
                         (sc2-query-placement ab-id (sc2-point2d-x pt) (sc2-point2d-y pt) 0)))
                     (define q-resp
                       (sc2-ws-rpc! ws-conn
                                    (make-request-query-placement q-items
                                                                  #:ignore-resource-requirements? #t)))
                     (define q-results (sc2-response-query-placements q-resp))
                     (for/first ([pt (in-list dedup-fan)]
                                 [res (in-list q-results)]
                                 #:when (= res 1))
                       pt)]
                    [else (first dedup-fan)]))
                (when verified-tumor-pt
                  (reserve-step-build-pt! verified-tumor-pt ab-id)
                  (when (and (= ab-id 1733) (set-mutable? used-tumors))
                    (for ([cid (in-list caster-ids)])
                      (set-add! used-tumors cid)))
                  (emit! (sc2-raw-unit-command ab-id verified-tumor-pt 0 caster-ids #f))))]

             ;; Case C: Orbital Command Calldown MULE (171) -> resolve ONLY to safe friendly-base mineral field tag
             [(= ab-id 171)
              (cond
                [(not (null? townhalls))
                 (define safe-min-tag (pick-safe-mule-mineral-patch caster-u self-units mineral-fields enemy-units))
                 (when (and (exact-integer? safe-min-tag) (> safe-min-tag 0))
                   (emit! (sc2-raw-unit-command ab-id #f safe-min-tag caster-ids #f)))]
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
                   (emit! (sc2-raw-unit-command ab-id #f resolved-min-tag caster-ids #f)))])]

             ;; Case C2: Nydus Worm (1768) -> must be cast ONLY by a completed Nydus Network (unit-type = 95), NEVER a worker
             [(= ab-id 1768)
              (define nydus-actor-id
                (cond
                  [(and caster-u (= caster-utype 95)) caster-id]
                  [(not (null? self-units))
                   (for/first ([u (in-list self-units)]
                               #:when (and (= (sc2-unit-unit-type u) 95)
                                           (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)
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
                   (define tu (for/first ([u (in-list units)] #:when (= (sc2-unit-tag u) tid)) u))
                   (if tu
                       (let ([p (sc2-unit-pos tu)])
                         (values (sc2-point3d-x p) (sc2-point3d-y p)))
                       (values home-x home-y))]
                  [else (values home-x home-y)]))
              (emit! (sc2-raw-unit-command ab-id (sc2-point2d tx ty) 0 caster-ids #f))]

             ;; Case E: Unit-target ability (Inject Larva, Chrono Boost, Transfusion, Feedback, Snipe, Yamato, Abduct, Neural Parasite, Repair, etc.)
             ;;         NEVER fall back to TargetNone (0) — if target-id <= 0, drop cleanly!
             [(set-member? SC2-UNIT-TARGET-ABILITY-IDS ab-id)
              (unless (and (= ab-id 251) (unit-has-protected-order? caster-id))
                (define target-id (if (pair? rest) (first rest) 0))
                (when (and (exact-integer? target-id) (> target-id 0))
                  (emit! (sc2-raw-unit-command ab-id #f target-id caster-ids #f))))]

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
         (filter (lambda (t) (and (exact-integer? t) (> t 0)))
                 (if (list? worker-ids) worker-ids (list worker-ids))))
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
       (define drill-wids '())
       (define strike-wids '())
       (for ([wid (in-list wlist)])
         (record-worker-used! wid)
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
         (if (and (> eff-patch-id 0) (> (pt-dist wx wy tx ty) 1.5))
             (set! drill-wids (cons wid drill-wids))
             (set! strike-wids (cons wid strike-wids))))
       (when (not (null? drill-wids))
         (emit! (sc2-raw-unit-command 3666 #f eff-patch-id (reverse drill-wids) #f)))
       (when (not (null? strike-wids))
         (if (and (exact-integer? target-id) (> target-id 0))
             (emit! (sc2-raw-unit-command 23 #f target-id (reverse strike-wids) #f))
             (emit! (sc2-raw-unit-command 23 (sc2-point2d tx ty) 0 (reverse strike-wids) #f))))]

      [(list 'harvest-mineral wid patch-id)
       (define wlist
         (filter (lambda (t)
                   (define u (and (exact-integer? t) (hash-ref self-unit-by-tag t #f)))
                   (define uh (and (exact-integer? t) (hash-ref hash-ally-by-id t #f)))
                   (define already-harvesting-or-building?
                     (or (and u (worker-has-build-order? u))
                         (and uh (hash-ref uh 'has-build-order? #f))
                         (and u
                              (pair? (sc2-unit-orders u))
                              (memv (sc2-unit-order-ability-id (first (sc2-unit-orders u)))
                                    '(295 296 298 299 1183 1184 3666 3667)))))
                   (and (exact-integer? t)
                        (> t 0)
                        (not (set-member? used-worker-tags t))
                        (not already-harvesting-or-building?)))
                 (if (list? wid) wid (list wid))))
       (define eff-patch-id
         (cond
           [(and (exact-integer? patch-id)
                 (ormap (lambda (m) (= (sc2-unit-tag m) patch-id)) mineral-fields))
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
                     (or (and u (worker-has-build-order? u))
                         (and uh (hash-ref uh 'has-build-order? #f))
                         (and u
                              (pair? (sc2-unit-orders u))
                              (memv (sc2-unit-order-ability-id (first (sc2-unit-orders u)))
                                    '(295 296 298 299 1183 1184 3666 3667)))))
                   (and (exact-integer? t)
                        (> t 0)
                        (not (set-member? used-worker-tags t))
                        (not already-busy?)))
                 (if (list? wid) wid (list wid))))
       (define gas-bldgs
         (filter (lambda (u)
                   (and (sc2-unit-is-gas-building? u)
                        (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)))
                 self-units))
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
         (unless (or (set-member? used-worker-tags wid)
                     (set-member? builder-worker-tags wid)
                     (and u (worker-has-build-order? u))
                     (and uh (hash-ref uh 'has-build-order? #f)))
           (record-worker-used! wid)
           (define tx (scale-bot-coord-to-world raw-x home-x))
           (define ty (scale-bot-coord-to-world raw-y home-y))
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
         (unless (and is-worker?
                      (or (set-member? used-worker-tags uid)
                          (set-member? builder-worker-tags uid)
                          (and u (worker-has-build-order? u))
                          (and uh (hash-ref uh 'has-build-order? #f))))
           (if is-worker?
               (record-worker-used! uid)
               (record-unit-used! uid))
           (define tx (scale-bot-coord-to-world raw-x home-x))
           (define ty (scale-bot-coord-to-world raw-y home-y))
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
                     (and u (worker-has-build-order? u))
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
         (record-unit-used! bid)
         (define tx (scale-bot-coord-to-world raw-x home-x))
         (define ty (scale-bot-coord-to-world raw-y home-y))
         (define target-pt (sc2-point2d tx ty))
         (unless (unit-already-executing-order? bid 17 target-pt 0)
           (emit! (sc2-raw-unit-command 17 target-pt 0 (list bid) #f))))]

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
       ;; 1. Sentry Hallucination Phoenix (154) when energy >= 75 and no enemies within 12 tiles
       (define sentry-u
         (for/first ([u (in-list self-units)]
                     #:when (and (= (sc2-unit-unit-type u) 77)
                                 (>= (sc2-unit-energy u) 75.0)
                                 (null? (sc2-unit-orders u))
                                 (not (set-member? commanded-combat-tags (sc2-unit-tag u)))))
           u))
       (when sentry-u
         (record-unit-used! (sc2-unit-tag sentry-u))
         (emit! (sc2-raw-unit-command 154 #f 0 (list (sc2-unit-tag sentry-u)) #f)))
       ;; 2. Overseer Spawn Changeling (181) when energy >= 50
       (define overseer-u
         (for/first ([u (in-list self-units)]
                     #:when (and (= (sc2-unit-unit-type u) 129)
                                 (>= (sc2-unit-energy u) 50.0)
                                 (null? (sc2-unit-orders u))))
           u))
       (when overseer-u
         (emit! (sc2-raw-unit-command 181 #f 0 (list (sc2-unit-tag overseer-u)) #f)))
       ;; 3. Idle Observer (82) or Hallucinated/Changeling scout moves toward enemy base
       (for ([u (in-list self-units)]
             #:when (and (memv (sc2-unit-unit-type u) '(82 12 13 14 15 16 17))
                         (null? (sc2-unit-orders u))))
         (emit! (sc2-raw-unit-command 16 (sc2-point2d eb-x eb-y) 0 (list (sc2-unit-tag u)) #f)))
       ;; 4. Orbital Command Scanner Sweep (399) at enemy base when energy >= 125 and 0 enemies visible
       (when (null? enemy-units)
         (define orbital-u
           (for/first ([u (in-list self-units)]
                       #:when (and (= (sc2-unit-unit-type u) 132)
                                   (>= (sc2-unit-energy u) 125.0)))
             u))
         (when orbital-u
           (emit! (sc2-raw-unit-command 399 (sc2-point2d eb-x eb-y) 0 (list (sc2-unit-tag orbital-u)) #f))))]

      [(list (or 'evacuate-workers-from-stasis-ward
                 'trigger-stasis-ward-single-unit
                 'counter-enemy-worker-drill
                 'stasis-worker-stoppage-compensation
                 'return-workers-to-gather) _ ...)
       (void)]

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

      [(list 'burrow-down uid _ ...)
       (when (and (exact-integer? uid) (> uid 0))
         (record-unit-used! uid)
         (emit! (sc2-raw-unit-command 3661 #f 0 (list uid) #f)))]

      [(list 'burrow-up uid _ ...)
       (when (and (exact-integer? uid) (> uid 0))
         (record-unit-used! uid)
         (emit! (sc2-raw-unit-command 3662 #f 0 (list uid) #f)))]

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
         (record-unit-used! uid)
         (emit! (sc2-raw-unit-command ability-id
                                      (sc2-point2d (scale-bot-coord-to-world raw-x home-x)
                                                   (scale-bot-coord-to-world raw-y home-y))
                                      0 (list uid) #f)))]

      [(list 'emergency-detector-response _ ...)
       (void)]

      [(list 'rebalance-gas-to-minerals wid patch-id)
       (define gas-bldg-tags
         (list->seteqv (map sc2-unit-tag (filter sc2-unit-is-gas-building? self-units))))
       (define wlist
         (filter (lambda (t)
                   (define u (and (exact-integer? t) (hash-ref self-unit-by-tag t #f)))
                   (define uh (and (exact-integer? t) (hash-ref hash-ally-by-id t #f)))
                   (and (exact-integer? t)
                        (> t 0)
                        (not (set-member? used-worker-tags t))
                        (not (and u (worker-has-build-order? u)))
                        (not (and uh (hash-ref uh 'has-build-order? #f)))
                        (or (null? self-units)
                            (and u
                                 (not (ormap (lambda (bid) (memv bid '(273 274 275)))
                                             (sc2-unit-buff-ids u)))
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
                    (ormap (lambda (m) (= (sc2-unit-tag m) patch-id)) mineral-fields))
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
                                                #:game-info eff-game-info)]
             [(eq? bsym 'factory-flying)
              (find-verified-building-placement ws-conn 328 lx0 ly0 units
                                                #:min-spacing 3.0 #:max-radius 14.0 #:step 2.0
                                                #:extra-reserved-points step-reserved-build-pts
                                                #:reserved-aabbs reserved-aabbs
                                                #:expansion-pads all-expansion-pads
                                                #:bldg-sym 'factory
                                                #:game-info eff-game-info)]
             [(eq? bsym 'starport-flying)
              (find-verified-building-placement ws-conn 329 lx0 ly0 units
                                                #:min-spacing 3.0 #:max-radius 14.0 #:step 2.0
                                                #:extra-reserved-points step-reserved-build-pts
                                                #:reserved-aabbs reserved-aabbs
                                                #:expansion-pads all-expansion-pads
                                                #:bldg-sym 'starport
                                                #:game-info eff-game-info)]
             [(memq bsym '(command-center-flying orbital-command-flying))
              (if (> (pt-dist home-x home-y lx0 ly0) SC2-BASE-RESOURCE-RADIUS)
                  (find-best-expansion-placement ws-conn 318 home-x home-y units
                                                 #:req-x lx0 #:req-y ly0
                                                 #:game-info eff-game-info
                                                 #:remembered-enemies SC2-LAST-KNOWN-ENEMY-POS)
                  (find-verified-building-placement ws-conn 318 lx0 ly0 units
                                                    #:min-spacing 4.5 #:max-radius 12.0 #:step 1.0
                                                    #:extra-reserved-points step-reserved-build-pts
                                                    #:reserved-aabbs reserved-aabbs
                                                    #:bldg-sym 'command-center
                                                    #:game-info eff-game-info))]
             [else (sc2-point2d lx0 ly0)]))
         (reserve-step-build-pt! land-pt (case bsym
                                           [(barracks-flying) 321]
                                           [(factory-flying) 328]
                                           [(starport-flying) 329]
                                           [else 0]))
         (emit! (sc2-raw-unit-command 3678 land-pt 0 (list bldg-id) #f)))]

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
       (define targetable-enemies-now
         (filter (lambda (e)
                   (sc2-enemy-unit-targetable? (sc2-id->unit-symbol (sc2-unit-unit-type e))))
                 enemy-units))
       (define ignore-phantom-pullback?
         (and (eq? maneuver-sym 'pre-rotate-intercept-incoming-threat)
              (null? enemy-units)
              (>= cur-loop 6000)))
       (define eff-maneuver-sym
         (if ignore-phantom-pullback?
             'multiprong-rotate-and-pin
             maneuver-sym))
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
             (and (>= cur-loop 6000) (null? enemy-units) (>= (length home-staged-combat-sp) 2))
             (null? townhalls)))
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
              (emit! (sc2-raw-unit-command 23 target-pt 0 ctags #f)))]))]

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
         (define plist
           (filter (lambda (t) (and (exact-integer? t) (> t 0) (not (= t tr-id))))
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
           (emit! (sc2-raw-unit-command 16 (sc2-point2d tx ty) 0 (list tr-id) #t))))]

      [(list 'transport-juggle tr-id (? real? raw-x) (? real? raw-y))
       (when (and (exact-integer? tr-id) (> tr-id 0))
         (record-unit-used! tr-id)
         (define tx (scale-bot-coord-to-world raw-x home-x))
         (define ty (scale-bot-coord-to-world raw-y home-y))
         ;; UNLOAD_ALL_AT (3669) is a PointTargetAbility at (tx, ty)
         (emit! (sc2-raw-unit-command 3669 (sc2-point2d tx ty) 0 (list tr-id) #f)))]

      [(or (list 'scout-sector _ (? real? raw-x) (? real? raw-y))
           (list 'scout-sector (? real? raw-x) (? real? raw-y)))
       (define tx (scale-bot-coord-to-world raw-x home-x))
       (define ty (scale-bot-coord-to-world raw-y home-y))
       (define target-pt (sc2-point2d tx ty))
       (define idle-scout
         (or (for/first ([u (in-list self-units)]
                         #:when (and (memv (sc2-unit-unit-type u) '(82 129 12 13 14 15 16 17))
                                     (null? (sc2-unit-orders u))
                                     (not (set-member? commanded-combat-tags (sc2-unit-tag u)))))
               u)
             (and (< cur-loop 3600)
                  (for/first ([u (in-list self-units)]
                              #:when (and (= (sc2-unit-unit-type u) 106)
                                          (null? (sc2-unit-orders u))
                                          (not (set-member? commanded-combat-tags (sc2-unit-tag u)))))
                    u))
             (for/first ([u (in-list combat-units)]
                         #:when (and (null? (sc2-unit-orders u))
                                     (not (set-member? commanded-combat-tags (sc2-unit-tag u)))
                                     (not (memv (sc2-unit-unit-type u) '(32 126 500 503)))))
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

      [(list 'high-ground-tactics _ (? real? raw-x) (? real? raw-y) spot-flag)
       (define tx (scale-bot-coord-to-world raw-x home-x))
       (define ty (scale-bot-coord-to-world raw-y home-y))
       (define target-pt (sc2-point2d tx ty))
       (when spot-flag
         (define air-spotter
           (for/first ([u (in-list self-units)]
                       #:when (and (sc2-unit-is-flying u)
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
         (emit! (sc2-raw-unit-command 23 target-pt 0 hg-tags #f)))]

      ;; 11. Control Groups (`ActionUI.control_group` is a wire no-op in Raw mode!) & Camera Saccades
      [(list (or 'control-group-set 'control-group-append 'control-group-steal
                 'control-group-append-steal 'control-group-recall) _ ...)
       (void)]

      [(list 'camera-focus _ raw-x raw-y)
       (emit-camera-move! raw-x raw-y)]
      [(list 'camera-focus raw-x raw-y)
       (emit-camera-move! raw-x raw-y)]
      [(list 'move-camera raw-x raw-y)
       (emit-camera-move! raw-x raw-y)]
      [(list 'camera-bookmark-jump _ raw-x raw-y)
       (emit-camera-move! raw-x raw-y)]

      [_ (void)]))

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
                        (not (worker-has-build-order? u))
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
  (for ([u (in-list self-units)]
        #:when (and (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)
                    (null? (sc2-unit-orders u))))
    (define utype (sc2-unit-unit-type u))
    (define utag (sc2-unit-tag u))
    (when (and (or (= utype 19) (= utype 47)) ;; 19 = SupplyDepot (raised), 47 = SupplyDepotLowered
               (>= cur-loop (hash-ref SC2-DEPOT-TOGGLE-COOLDOWN utag 0)))
      (define dp (sc2-unit-pos u))
      (define enemy-ground-within-raise?
        (ormap (lambda (e)
                 (and (not (sc2-unit-is-flying e))
                      (let ([ep (sc2-unit-pos e)])
                        (<= (pt-dist (sc2-point3d-x dp) (sc2-point3d-y dp)
                                     (sc2-point3d-x ep) (sc2-point3d-y ep))
                            10.5))))
               enemy-units))
      (define enemy-ground-within-keep-up?
        (ormap (lambda (e)
                 (and (not (sc2-unit-is-flying e))
                      (let ([ep (sc2-unit-pos e)])
                        (<= (pt-dist (sc2-point3d-x dp) (sc2-point3d-y dp)
                                     (sc2-point3d-x ep) (sc2-point3d-y ep))
                            14.5))))
               enemy-units))
      (cond
        [(and (= utype 19) (not enemy-ground-within-keep-up?))
         (hash-set! SC2-DEPOT-TOGGLE-COOLDOWN utag (+ cur-loop 32))
         (emit! (sc2-raw-unit-command 556 #f 0 (list utag) #f))] ;; MORPH_SUPPLYDEPOT_LOWER
        [(and (= utype 47) enemy-ground-within-raise?)
         (hash-set! SC2-DEPOT-TOGGLE-COOLDOWN utag (+ cur-loop 32))
         (emit! (sc2-raw-unit-command 558 #f 0 (list utag) #f))])) ;; MORPH_SUPPLYDEPOT_RAISE
    ;; Automatically unsiege idle `siege-tank-sieged` (32) only when no enemy unit/structure is within 15.5 tiles
    (when (and (= utype 32)
               (not (set-member? commanded-combat-tags utag)))
      (define tp (sc2-unit-pos u))
      (define enemy-in-siege-range?
        (ormap (lambda (e)
                 (define ep (sc2-unit-pos e))
                 (<= (pt-dist (sc2-point3d-x tp) (sc2-point3d-y tp)
                              (sc2-point3d-x ep) (sc2-point3d-y ep))
                     15.5))
               enemy-units))
      (unless enemy-in-siege-range?
        (set-add! commanded-combat-tags utag)
        (emit! (sc2-raw-unit-command 390 #f 0 (list utag) #f))))
    ;; Automatically unburrow idle `lurker-burrowed` (503 -> 2110) only when no ground enemy is within 12.5 tiles
    (when (and (= utype 503)
               (not (set-member? commanded-combat-tags utag)))
      (define lp (sc2-unit-pos u))
      (define ground-enemy-in-lurker-range?
        (ormap (lambda (e)
                 (and (not (sc2-unit-is-flying e))
                      (let ([ep (sc2-unit-pos e)])
                        (<= (pt-dist (sc2-point3d-x lp) (sc2-point3d-y lp)
                                     (sc2-point3d-x ep) (sc2-point3d-y ep))
                            12.5))))
               enemy-units))
      (unless ground-enemy-in-lurker-range?
        (set-add! commanded-combat-tags utag)
        (emit! (sc2-raw-unit-command 2110 #f 0 (list utag) #f))))
    ;; Automatically unburrow idle `widow-mine-burrowed` (500 -> 2097) only when no enemy <= 13.5 AND no friendly TownHall <= 12.0
    (when (and (= utype 500)
               (not (set-member? commanded-combat-tags utag)))
      (define mp (sc2-unit-pos u))
      (define enemy-in-mine-range?
        (ormap (lambda (e)
                 (define ep (sc2-unit-pos e))
                 (<= (pt-dist (sc2-point3d-x mp) (sc2-point3d-y mp)
                              (sc2-point3d-x ep) (sc2-point3d-y ep))
                     13.5))
               enemy-units))
      (define defending-mineral-line?
        (ormap (lambda (th)
                 (define tp (sc2-unit-pos th))
                 (<= (pt-dist (sc2-point3d-x mp) (sc2-point3d-y mp)
                              (sc2-point3d-x tp) (sc2-point3d-y tp))
                     12.0))
               townhalls))
      (unless (or enemy-in-mine-range? defending-mineral-line?)
        (set-add! commanded-combat-tags utag)
        (emit! (sc2-raw-unit-command 2097 #f 0 (list utag) #f)))))

  (define targetable-enemy-units
    (filter (lambda (e)
              (sc2-enemy-unit-targetable? (sc2-id->unit-symbol (sc2-unit-unit-type e))))
            enemy-units))
  (define idle-combat-units
    (filter (lambda (u)
              (and (null? (sc2-unit-orders u))
                   (not (set-member? commanded-combat-tags (sc2-unit-tag u)))
                   (not (memv (sc2-unit-unit-type u) '(32 500 503)))
                   (not (eq? (sc2-id->unit-symbol (sc2-unit-unit-type u)) 'queen))))
            combat-units))
  (define-values (default-eb-x default-eb-y)
    (if (and (list? enemy-base) (>= (length enemy-base) 2))
        (values (exact->inexact (first enemy-base))
                (exact->inexact (second enemy-base)))
        (values (- SC2-DEFAULT-MAP-WIDTH home-x)
                (- SC2-DEFAULT-MAP-HEIGHT home-y))))
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
    (define-values (stage-x0 stage-y0)
      (let* ([dx (- att-x home-x)]
             [dy (- att-y home-y)]
             [d (max 1.0 (sqrt (+ (sqr dx) (sqr dy))))]
             [step-d (min 18.0 (* 0.25 d))])
        (values (+ home-x (* step-d (/ dx d)))
                (+ home-y (* step-d (/ dy d))))))
    ;; Push staging point >= 6.5 tiles away from any solved expansion pad within 6.0 tiles
    (define-values (stage-x stage-y)
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
          (and (>= cur-loop 6000) (null? enemy-units) (>= (length home-staged-combat) 2))
          (null? townhalls)))
    (cond
      [base-threat
       (define ep (sc2-unit-pos base-threat))
       (emit! (sc2-raw-unit-command 23
                                    (sc2-point2d (sc2-point3d-x ep) (sc2-point3d-y ep))
                                    0 idle-tags #f))]
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
                               (and (<= (pt-dist home-x home-y (sc2-point3d-x up) (sc2-point3d-y up)) 48.0)
                                    (> (pt-dist stage-x stage-y (sc2-point3d-x up) (sc2-point3d-y up)) 8.0))))
             (sc2-unit-tag u)))
         (when (not (null? home-idle-tags))
           (emit! (sc2-raw-unit-command 23 (sc2-point2d stage-x stage-y) 0 home-idle-tags #f))))]
      [(and can-push-or-sweep? home-wave-ready?)
       (emit! (sc2-raw-unit-command 23
                                    (sc2-point2d att-x att-y)
                                    0 idle-tags #f))]
      [can-push-or-sweep?
       ;; Forward units (> 48 tiles from home) continue attacking; newly spawned home units stage at natural choke
       (define forward-idle-tags
         (for/list ([u (in-list idle-combat-units)]
                    #:when (> (let ([up (sc2-unit-pos u)])
                                (pt-dist home-x home-y (sc2-point3d-x up) (sc2-point3d-y up)))
                              48.0))
           (sc2-unit-tag u)))
       (define home-idle-tags
         (for/list ([u (in-list idle-combat-units)]
                    #:when (let ([up (sc2-unit-pos u)])
                             (and (<= (pt-dist home-x home-y (sc2-point3d-x up) (sc2-point3d-y up)) 48.0)
                                  (> (pt-dist stage-x stage-y (sc2-point3d-x up) (sc2-point3d-y up)) 8.0))))
           (sc2-unit-tag u)))
       (when (not (null? forward-idle-tags))
         (emit! (sc2-raw-unit-command 23 (sc2-point2d att-x att-y) 0 forward-idle-tags #f)))
       (when (not (null? home-idle-tags))
         (emit! (sc2-raw-unit-command 23 (sc2-point2d stage-x stage-y) 0 home-idle-tags #f)))]
      [else
       ;; Army below push threshold: rally idle units that spawned at main base (> 8 tiles from front stage) to natural choke
       (define unplaced-home-tags
         (for/list ([u (in-list idle-combat-units)]
                    #:when (let ([up (sc2-unit-pos u)])
                             (and (<= (pt-dist home-x home-y (sc2-point3d-x up) (sc2-point3d-y up)) 48.0)
                                  (> (pt-dist stage-x stage-y (sc2-point3d-x up) (sc2-point3d-y up)) 8.0))))
           (sc2-unit-tag u)))
       (when (and (not (null? unplaced-home-tags)) (not (null? townhalls)))
         (emit! (sc2-raw-unit-command 23 (sc2-point2d stage-x stage-y) 0 unplaced-home-tags #f)))]))

  ;; 13. Multi-Tag Wire Command Coalescing:
  ;;     Merge compatible combat/stance/spell/depot/unburrow `sc2-raw-unit-command` packets
  ;;     that share `(ability-id, target-pos, target-unit-tag, queue?)` into a single multi-tag packet
  ;;     to eliminate per-unit command duplication while preserving Reactor multi-slot train queues.
  (define coalescable-abilities
    (seteqv 16 17 18 23 76 171 380 388 390 556 558 1036 1042 1442 1526 2095 2097 2108 2110 2328 2338 2346 2375 2393 3661 3662 3665 3666 3667 3674 3675 3687))
  (define ordered-cmds (reverse raw-cmds))
  (let coalesce-loop ([rem ordered-cmds]
                      [acc '()])
    (if (null? rem)
        (reverse acc)
        (let ([c (car rem)])
          (if (and (sc2-raw-unit-command? c)
                   (set-member? coalescable-abilities (sc2-raw-unit-command-ability-id c)))
              (let ([ab (sc2-raw-unit-command-ability-id c)]
                    [tp (sc2-raw-unit-command-target-pos c)]
                    [tu (sc2-raw-unit-command-target-unit-tag c)]
                    [q? (sc2-raw-unit-command-queue? c)])
                (define-values (matching others)
                  (partition (lambda (x)
                               (and (sc2-raw-unit-command? x)
                                    (= (sc2-raw-unit-command-ability-id x) ab)
                                    (equal? (sc2-raw-unit-command-target-pos x) tp)
                                    (= (sc2-raw-unit-command-target-unit-tag x) tu)
                                    (equal? (sc2-raw-unit-command-queue? x) q?)))
                             (cdr rem)))
                (define merged-tags
                  (remove-duplicates
                   (append (sc2-raw-unit-command-unit-tags c)
                           (append* (map sc2-raw-unit-command-unit-tags matching)))))
                (coalesce-loop others
                               (cons (sc2-raw-unit-command ab tp tu merged-tags q?) acc)))
              (coalesce-loop (cdr rem) (cons c acc)))))))

;; =============================================================================
;; 14. Wire-Level Token-Bucket & Rolling-Window APM Governor
;; =============================================================================

(define SC2-FASTER-LOOPS-PER-MINUTE 1344.0)
(define SC2-WIRE-COALESCABLE-ABILITIES
  (seteqv 16 17 18 23 76 171 380 388 390 556 558 1036 1042 1442 1526
          2095 2097 2108 2110 2328 2338 2346 2375 2393
          3661 3662 3665 3666 3667 3674 3675 3687))

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
      ;; P0: Life-or-death survival, tactical spells, cancel, mode-switches & defensive depot raise
      [(memv ab '(32 314 380 3675 1442 3687 74 76 140 249 251 399 401
                  1036 1526 1628 1664 2063 2067 2069 2073 2146 2338 2346 2505
                  2542 2545 2714 3668 3669 3755 3757 142 3686 388 390 2095 2097 2108 2110
                  403 405 2362 2364 558))
       0]
      ;; P3: Routine harvest / worker rebalance / depot lower
      [(memv ab '(166 167 295 296 298 299 1183 1184 3666 3667 556))
       3]
      ;; P2: Combat attack, move, kite, hold-position, patrol, stop
      [(memv ab '(4 5 6 7 16 17 18 19 20 23 24 25 2099 3665 3674 3771 3793 3794 3795))
       2]
      ;; P1: Macro build, expand, morph, train, warp-in, research, tumor, MULE
      [else 1]))
  (cond
    [(or (sc2-raw-camera-move? cmd) (WireCameraMove? cmd)) 4]
    [(sc2-raw-unit-command? cmd) (ab-tier (sc2-raw-unit-command-ability-id cmd))]
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

(define (govern-sc2-wire-actions! gov raw-cmds game-loop [_obs #f])
  (define cur-loop (if (exact-integer? game-loop) (max 0 game-loop) 0))
  ;; Auto-reset state across sequential matches when game-loop rewinds
  (when (and (>= (wire-apm-governor-last-loop gov) 0)
             (< cur-loop (wire-apm-governor-last-loop gov)))
    (set-wire-apm-governor-tokens! gov 24.0)
    (set-wire-apm-governor-last-loop! gov -1)
    (set-wire-apm-governor-last-cam-loop! gov -1000)
    (set-wire-apm-governor-last-selected-tags! gov #f)
    (set-wire-apm-governor-rolling-events! gov '()))

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

  ;; 3. Strip Raw-mode no-op UI control-group commands, rate-limit camera moves (<= 1 per 28 loops),
  ;;    coalesce compatible unit commands, canonicalize sorted tag lists, and chunk to <= 64 tags.
  (define cam-allowed? (>= (- cur-loop (wire-apm-governor-last-cam-loop gov)) 28))
  (define cam-seen? #f)
  (define filtered0
    (for/list ([c (in-list (if (list? raw-cmds) raw-cmds '()))]
               #:when (cond
                        [(sc2-ui-control-group? c) #f]
                        [(sc2-chat-action? c) #t]
                        [(sc2-raw-camera-move? c)
                         (if (and cam-allowed? (not cam-seen?))
                             (begin (set! cam-seen? #t) #t)
                             #f)]
                        [(sc2-raw-unit-command? c)
                         (pair? (sc2-raw-unit-command-unit-tags c))]
                        [else #f]))
      c))

  (define coalesced
    (let loop ([rem filtered0] [acc '()])
      (if (null? rem)
          (reverse acc)
          (let ([c (car rem)])
            (if (and (sc2-raw-unit-command? c)
                     (set-member? SC2-WIRE-COALESCABLE-ABILITIES
                                  (sc2-raw-unit-command-ability-id c)))
                (let ([ab (sc2-raw-unit-command-ability-id c)]
                      [tp (sc2-raw-unit-command-target-pos c)]
                      [tu (sc2-raw-unit-command-target-unit-tag c)]
                      [q? (sc2-raw-unit-command-queue? c)])
                  (define-values (matching others)
                    (partition (lambda (x)
                                 (and (sc2-raw-unit-command? x)
                                      (= (sc2-raw-unit-command-ability-id x) ab)
                                      (equal? (sc2-raw-unit-command-target-pos x) tp)
                                      (= (sc2-raw-unit-command-target-unit-tag x) tu)
                                      (equal? (sc2-raw-unit-command-queue? x) q?)))
                               (cdr rem)))
                  (define merged-tags
                    (sort (remove-duplicates
                           (append (sc2-raw-unit-command-unit-tags c)
                                   (append* (map sc2-raw-unit-command-unit-tags matching))))
                          <))
                  (define chunks (chunk-tag-list merged-tags 64))
                  (loop others
                        (append (reverse
                                 (for/list ([ch (in-list chunks)])
                                   (sc2-raw-unit-command ab tp tu ch q?)))
                                acc)))
                (if (sc2-raw-unit-command? c)
                    (let* ([canon-tags (sort (remove-duplicates (sc2-raw-unit-command-unit-tags c)) <)]
                           [chunks (chunk-tag-list canon-tags 64)])
                      (loop (cdr rem)
                            (append (reverse
                                     (for/list ([ch (in-list chunks)])
                                       (sc2-raw-unit-command
                                        (sc2-raw-unit-command-ability-id c)
                                        (sc2-raw-unit-command-target-pos c)
                                        (sc2-raw-unit-command-target-unit-tag c)
                                        ch
                                        (sc2-raw-unit-command-queue? c))))
                                    acc)))
                    (loop (cdr rem) (cons c acc))))))))

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
  (define emitted '())
  (define (tier-token-floor tier)
    (case tier
      [(0) -8.0]  ;; P0 survival/spells may borrow up to 8 tokens (repaid by throttling P2..P4)
      [(1)  2.0]  ;; P1 macro leaves >= 2 tokens for P0
      [(2)  4.0]  ;; P2 combat leaves >= 4 tokens for P0/P1
      [(3)  8.0]  ;; P3 harvest/lower leaves >= 8 tokens for P0/P1/P2
      [else 10.0]))
  (define (tier-headroom-floor tier)
    (case tier
      [(0)  0.0]  ;; P0 strictly obeys rolling 60s hard-cap-apm
      [(1)  6.0]
      [(2) 12.0]
      [(3) 24.0]
      [else 30.0]))

  (for ([tier (in-range 0 5)])
    (define tok-floor (tier-token-floor tier))
    (define hr-floor (tier-headroom-floor tier))
    (define tier-cmds
      (filter (lambda (c) (= (wire-cmd-priority-tier c) tier)) coalesced))
    (let tier-loop ([rem tier-cmds])
      (unless (null? rem)
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
        (when (or (= ev-cost 0)
                  (and (>= (- rem-headroom cost-fl) hr-floor)
                       (>= (- (wire-apm-governor-tokens gov) cost-fl) tok-floor)))
          (when (> ev-cost 0)
            (set! rem-headroom (- rem-headroom cost-fl))
            (set-wire-apm-governor-tokens!
             gov
             (max -8.0 (- (wire-apm-governor-tokens gov) cost-fl)))
            (set! new-events (cons (cons cur-loop ev-cost) new-events)))
          (cond
            [(sc2-raw-camera-move? chosen)
             (set-wire-apm-governor-last-cam-loop! gov cur-loop)]
            [(sc2-raw-unit-command? chosen)
             (set! cur-sel (sc2-raw-unit-command-unit-tags chosen))
             (set-wire-apm-governor-last-selected-tags! gov cur-sel)])
          (set! emitted (cons chosen emitted)))
        (tier-loop rest-rem))))

  (when (not (null? new-events))
    (set-wire-apm-governor-rolling-events!
     gov
     (append (reverse new-events) (wire-apm-governor-rolling-events gov))))

  (reverse emitted))
