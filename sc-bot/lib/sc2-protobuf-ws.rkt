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
         "sc2-game-constants.rkt")

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
 (struct-out sc2-game-info)
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
 encode-action-raw-unit-command
 encode-action-raw-camera-move
 encode-action-ui-control-group
 encode-sc2-action
 decode-sc2-response

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
 register-sc2-response-data!

 ;; Observation Converter & S-Expression Actuator
 sc2-unit-is-structure?
 sc2-unit-is-townhall?
 sc2-unit-is-worker?
 sc2-unit-is-mineral-field?
 sc2-unit-is-vespene-geyser?
 sc2-unit-is-gas-building?
 sc2-observation->runtime-obs-hash
 sc2-observation->frame-state-sexp
 collect-spiral-candidates
 find-spiral-building-placement
 find-verified-building-placement
 select-producer-tags-for-unit
 saturate-workers-and-gas-commands
 translate-bot-actions->sc2-raw-commands)

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
                    (loop (cons chunk acc) (- rem (bytes-length chunk)))))))])]))

(define (sc2-ws-recv-binary! conn)
  (if (sc2-ws-conn-closed? conn)
      eof
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
                      (loop fragments)])])])])))))

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
  (sc2-ws-send-binary! conn request-bytes)
  (define resp-bytes (sc2-ws-recv-binary! conn))
  (if (eof-object? resp-bytes)
      (sc2-response #f 'ended '("WebSocket EOF") #f #f #f #f #f #f '() #f #f '() #f)
      (decode-sc2-response resp-bytes)))

;; =============================================================================
;; 2. Protobuf Wire Format Encoder & Decoder
;; =============================================================================

(define (encode-varint n)
  (define u
    (if (< n 0)
        (bitwise-and (exact-round n) #xFFFFFFFFFFFFFFFF)
        (exact-round n)))
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
    (define b (bytes-ref bstr idx))
    (define next-acc (bitwise-ior acc (arithmetic-shift (bitwise-and b #x7F) shift)))
    (if (zero? (bitwise-and b #x80))
        (values next-acc (add1 idx))
        (loop (add1 idx) (+ shift 7) next-acc))))

(define (encode-tag field-number wire-type)
  (encode-varint (bitwise-ior (arithmetic-shift field-number 3)
                              (bitwise-and wire-type #x07))))

(define encode-int32
  (case-lambda
    [(val) (encode-varint val)]
    [(field-number val)
     (bytes-append (encode-tag field-number 0) (encode-varint val))]))

(define encode-uint32
  (case-lambda
    [(val) (encode-varint (bitwise-and (exact-round val) #xFFFFFFFF))]
    [(field-number val)
     (bytes-append (encode-tag field-number 0)
                   (encode-varint (bitwise-and (exact-round val) #xFFFFFFFF)))]))

(define encode-uint64
  (case-lambda
    [(val) (encode-varint (bitwise-and (exact-round val) #xFFFFFFFFFFFFFFFF))]
    [(field-number val)
     (bytes-append (encode-tag field-number 0)
                   (encode-varint (bitwise-and (exact-round val) #xFFFFFFFFFFFFFFFF)))]))

(define encode-bool
  (case-lambda
    [(b) (bytes (if b 1 0))]
    [(field-number b)
     (bytes-append (encode-tag field-number 0) (bytes (if b 1 0)))]))

(define encode-float32
  (case-lambda
    [(val)
     (real->floating-point-bytes (exact->inexact val) 4 #f)]
    [(field-number val)
     (bytes-append (encode-tag field-number 5)
                   (real->floating-point-bytes (exact->inexact val) 4 #f))]))

(define (decode-float32 bstr [offset 0])
  (floating-point-bytes->real bstr #f offset (+ offset 4)))

(define (encode-bytes-field field-number raw-bytes)
  (bytes-append (encode-tag field-number 2)
                (encode-varint (bytes-length raw-bytes))
                raw-bytes))

(define (encode-string-field field-number str)
  (encode-bytes-field field-number (string->bytes/utf-8 (format "~a" str))))

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
          (hydralisk 107 #t)
          (hydralisk-burrowed 117 #t)
          (lurker-egg 501 #t)
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
          (locust 489 #t)
          (locust-flying 693 #t)
          (broodling 289 #t)
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
          (build-spine-crawler 1166 #t)
          (build-spore-crawler 1167 #t)
          (build-creep-tumor 3691 #t)
          (build-creep-tumor-queen 1694 #t)
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
          (neural-parasite 249 #t)
          (abduct 2067 #t)
          (blinding-cloud 2063 #t)
          (parasitic-bomb 2542 #t)
          (viper-consume 2073 #t)
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
          (pulsar-beam-on 2375 #t)
          (pulsar-beam-off 2376 #t)
          (oracle-revelation 2146 #t)
          (stasis-ward 2505 #t)
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
          (research-zerg-flyer-armor-1 1315 #t)
          (research-flyer-carapace-1 1315 #f)
          (research-stimpack 730 #t)
          (research-combat-shield 731 #t)
          (research-concussive-shells 732 #t)
          (research-infernal-preigniter 761 #t)
          (research-infernal-pre-igniter 761 #f)
          (research-drilling-claws 764 #t)
          (research-cyclone-lock-on-damage 769 #t)
          (research-mag-field-accelerator 769 #f)
          (research-banshee-cloak 790 #t)
          (research-cloaking-field 790 #f)
          (research-hyperflight-rotors 799 #t)
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
          (research-terran-vehicle-plating-1 864 #t)
          (research-terran-vehicle-and-ship-plating-1 864 #f)
          (research-vehicle-and-ship-plating-1 864 #f)
          (research-terran-ship-weapons-1 861 #t)
          (research-ship-weapons-1 861 #f)
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
          (research-protoss-air-armor-1 1565 #t)
          (research-air-armor-1 1565 #f)))])
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
          (zerg-flyer-armor-1 71 #t)
          (flyer-carapace-1 71 #f)
          (stimpack 15 #t)
          (combat-shield 16 #t)
          (shield-wall 16 #f)
          (concussive-shells 17 #t)
          (punisher-grenades 17 #f)
          (infernal-preigniter 19 #t)
          (infernal-pre-igniter 19 #f)
          (drilling-claws 122 #t)
          (cyclone-lock-on-damage 144 #t)
          (mag-field-accelerator 144 #f)
          (banshee-cloak 20 #t)
          (cloaking-field 20 #f)
          (personal-cloaking 25 #t)
          (weapon-refit 69 #t)
          (hyperflight-rotors 138 #t)
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
          (terran-vehicle-plating-1 116 #t)
          (terran-vehicle-and-ship-plating-1 116 #f)
          (vehicle-and-ship-plating-1 116 #f)
          (terran-ship-weapons-1 36 #t)
          (ship-weapons-1 36 #f)
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
          (protoss-air-armor-1 81 #t)
          (air-armor-1 81 #f)))])
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
  (define prefixed (string->symbol (format "morph-~a" norm)))
  (or (hash-ref SC2-ABILITY-SYM->ID prefixed #f)
      (hash-ref SC2-ABILITY-SYM->ID (string->symbol (format "build-~a" norm)) #f)
      (hash-ref SC2-ABILITY-SYM->ID norm #f)))

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

(struct sc2-game-info
  (map-name
   local-map-path
   player-info
   map-size
   playable-area
   start-locations)
  #:transparent)

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
    [(exact-integer? r) r]
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
    [(exact-integer? d) d]
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
   (if (exact-integer? req-id)
       (encode-uint32 97 req-id)
       #"")))

(define (encode-point2d x y)
  (bytes-append (encode-float32 1 x)
                (encode-float32 2 y)))

(define (encode-point3d x y [z 0.0])
  (bytes-append (encode-float32 1 x)
                (encode-float32 2 y)
                (encode-float32 3 z)))

(define (encode-player-setup type race [difficulty #f] [player-name #f])
  (bytes-append
   (encode-int32 1 type)
   (encode-int32 2 (race->sc2-enum race))
   (if difficulty (encode-int32 3 (difficulty->sc2-enum difficulty)) #"")
   (if player-name (encode-string-field 4 player-name) #"")))

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
  (define map-data-bytes
    (if (and include-map-data? (string? map-path) (file-exists? map-path))
        (with-handlers ([exn:fail? (lambda (_e) #"")])
          (encode-bytes-field 7 (call-with-input-file map-path port->bytes)))
        #""))
  (define map-part
    (if bnet-map
        (encode-string-field 2 bnet-map)
        (encode-submessage-field 1
                                 (bytes-append (encode-string-field 1 map-path)
                                               map-data-bytes))))
  (define setups-bytes
    (if (and (list? player-setups) (not (null? player-setups)))
        (apply bytes-append
               (for/list ([ps (in-list player-setups)])
                 (match ps
                   [(list type race diff)
                    (encode-submessage-field 3 (encode-player-setup type race diff))]
                   [(list type race)
                    (encode-submessage-field 3 (encode-player-setup type race))]
                   [(? bytes? b)
                    (encode-submessage-field 3 b)]
                   [_ #""])))
        (bytes-append
         (encode-submessage-field 3 (encode-player-setup 1 our-race))
         (encode-submessage-field 3 (encode-player-setup 2 computer-race computer-difficulty)))))
  (define body
    (bytes-append
     map-part
     setups-bytes
     (if disable-fog? (encode-bool 4 #t) #"")
     (if (exact-integer? random-seed) (encode-uint32 5 random-seed) #"")
     (encode-bool 6 realtime?)))
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
     (encode-bool 1 raw?)
     (encode-bool 2 score?)
     (encode-bool 5 show-cloaked?)
     (encode-bool 6 raw-affects-selection?)
     (encode-bool 7 raw-crop-to-playable-area?)
     (encode-bool 8 show-placeholders?)
     (encode-bool 9 show-burrowed-shadows?)))
  (define participant-part
    (if (exact-integer? obs-id)
        (encode-uint32 2 obs-id)
        (encode-int32 1 (race->sc2-enum race))))
  (define server-ports-part
    (match server-ports
      [(or (list gp bp) (cons (? real? gp) (? real? bp)))
       (encode-submessage-field 4 (encode-port-set gp bp))]
      [_ #""]))
  (define client-ports-part
    (apply bytes-append
           (for/list ([cp (in-list (if (list? client-ports) client-ports '()))])
             (match cp
               [(or (list gp bp) (cons (? real? gp) (? real? bp)))
                (encode-submessage-field 5 (encode-port-set gp bp))]
               [_ #""]))))
  (define body
    (bytes-append
     participant-part
     (encode-submessage-field 3 iface-options)
     server-ports-part
     client-ports-part
     (if (exact-integer? shared-port) (encode-int32 6 shared-port) #"")
     (if player-name (encode-string-field 7 player-name) #"")
     (if host-ip (encode-string-field 8 host-ip) #"")))
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
     (if (exact-integer? game-loop) (encode-uint32 2 game-loop) #"")))
  (wrap-sc2-request 10 body req-id))

(define (encode-action-raw-unit-command cmd)
  (match-define (sc2-raw-unit-command ab-id target-pos target-tag unit-tags queue?) cmd)
  (define pos-part
    (match target-pos
      [(sc2-point2d x y) (encode-submessage-field 2 (encode-point2d x y))]
      [(or (list x y) (cons (? real? x) (? real? y))) (encode-submessage-field 2 (encode-point2d x y))]
      [_ #""]))
  (define tag-part
    (if (and (exact-integer? target-tag) (> target-tag 0))
        (encode-uint64 3 target-tag)
        #""))
  (define units-part
    (apply bytes-append
           (for/list ([ut (in-list (if (list? unit-tags) unit-tags '()))]
                      #:when (and (exact-integer? ut) (> ut 0)))
             (encode-uint64 4 ut))))
  (bytes-append
   (encode-int32 1 ab-id)
   pos-part
   tag-part
   units-part
   (if queue? (encode-bool 5 #t) #"")))

(define (encode-action-raw-camera-move cm)
  (match-define (sc2-raw-camera-move x y z) cm)
  (encode-submessage-field 1 (encode-point3d x y z)))

;; ActionControlGroup (ui.proto):
;;   field 1 = action (ControlGroupAction enum: 1=Recall, 2=Set, 3=Append, 4=SetAndSteal, 5=AppendAndSteal)
;;   field 2 = control_group_index (uint32 0..9)
(define (encode-action-ui-control-group cg)
  (match-define (sc2-ui-control-group act-enum grp-idx) cg)
  (bytes-append
   (encode-int32 1 act-enum)
   (encode-uint32 2 (max 0 (min 9 grp-idx)))))

(define (encode-sc2-action act)
  (cond
    [(sc2-raw-unit-command? act)
     (define uc-bytes (encode-action-raw-unit-command act))
     (define action-raw-bytes (encode-submessage-field 1 uc-bytes))
     (encode-submessage-field 1 action-raw-bytes)]
    [(sc2-raw-camera-move? act)
     (define cm-bytes (encode-action-raw-camera-move act))
     (define action-raw-bytes (encode-submessage-field 2 cm-bytes))
     (encode-submessage-field 1 action-raw-bytes)]
    [(sc2-ui-control-group? act)
     ;; Action.action_ui (field 3) -> ActionUI.control_group (field 1) -> ActionControlGroup
     (define cg-bytes (encode-action-ui-control-group act))
     (define action-ui-bytes (encode-submessage-field 1 cg-bytes))
     (encode-submessage-field 3 action-ui-bytes)]
    [(sc2-chat-action? act)
     (match-define (sc2-chat-action chan msg) act)
     (define chat-bytes
       (bytes-append (encode-int32 1 chan)
                     (encode-string-field 2 msg)))
     (encode-submessage-field 6 chat-bytes)]
    [(bytes? act) act]
    [else #""]))

(define (make-request-action actions #:id [req-id #f])
  (define body
    (apply bytes-append
           (for/list ([a (in-list actions)])
             (define enc (encode-sc2-action a))
             (if (zero? (bytes-length enc))
                 #""
                 (encode-submessage-field 1 enc)))))
  (wrap-sc2-request 11 body req-id))

(define (make-request-step [count 4] #:count [kw-count #f] #:id [req-id #f])
  (define c (or kw-count count 4))
  (wrap-sc2-request 12 (encode-uint32 1 (max 1 c)) req-id))

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

(define (make-request-query-placement placements
                                      #:ignore-resource-requirements? [ignore-res? #f]
                                      #:id [req-id #f])
  (define p-bytes
    (apply bytes-append
           (for/list ([p (in-list placements)])
             (match-define (sc2-query-placement ab-id x y unit-tag)
               (match p
                 [(? sc2-query-placement? qp) qp]
                 [(list ab x0 y0 ut) (sc2-query-placement ab x0 y0 ut)]
                 [(list ab x0 y0) (sc2-query-placement ab x0 y0 0)]))
             (define sub
               (bytes-append
                (encode-int32 1 ab-id)
                (encode-submessage-field 2 (encode-point2d x y))
                (if (and (exact-integer? unit-tag) (> unit-tag 0))
                    (encode-uint64 3 unit-tag)
                    #"")))
             ;; query.proto field 3 is `placements`
             (encode-submessage-field 3 sub))))
  (define body
    (bytes-append
     p-bytes
     (if ignore-res? (encode-bool 4 #t) #"")))
  (wrap-sc2-request 14 body req-id))

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

(define (decode-point2d-bytes bstr)
  (define fields (decode-protobuf-message bstr))
  (sc2-point2d (field-first-float32 fields 1 0.0)
               (field-first-float32 fields 2 0.0)))

(define (decode-point3d-bytes bstr)
  (define fields (decode-protobuf-message bstr))
  (sc2-point3d (field-first-float32 fields 1 0.0)
               (field-first-float32 fields 2 0.0)
               (field-first-float32 fields 3 0.0)))

(define (decode-unit-order-bytes bstr)
  (define fields (decode-protobuf-message bstr))
  (define ab-id (field-first-varint fields 1 0))
  (define pos-b (field-first-bytes fields 2 #f))
  (define target-pos (if pos-b (decode-point3d-bytes pos-b) #f))
  (define target-tag (field-first-varint fields 3 0))
  (define progress (field-first-float32 fields 4 0.0))
  (sc2-unit-order ab-id target-pos target-tag progress))

(define (decode-unit-bytes bstr)
  (define fields (decode-protobuf-message bstr))
  (define pos-b (field-first-bytes fields 6 #f))
  (define pos (if pos-b (decode-point3d-bytes pos-b) (sc2-point3d 0.0 0.0 0.0)))
  (define orders (map decode-unit-order-bytes (field-all-bytes fields 22)))
  (define buff-ids (decode-packed-or-unpacked-varints fields 27))
  (sc2-unit
   (field-first-varint fields 1 1)         ;; display_type
   (field-first-varint fields 2 1)         ;; alliance (1=Self, 2=Ally, 3=Neutral, 4=Enemy)
   (field-first-varint fields 3 0)         ;; tag
   (field-first-varint fields 4 0)         ;; unit_type
   (field-first-varint fields 5 1)         ;; owner
   pos                                     ;; pos
   (field-first-float32 fields 7 0.0)      ;; facing
   (field-first-float32 fields 8 0.5)      ;; radius
   (field-first-float32 fields 9 1.0)      ;; build_progress
   (field-first-varint fields 10 3)        ;; cloak
   (field-first-bool fields 11 #f)         ;; is_selected
   (field-first-bool fields 12 #f)         ;; is_on_screen
   (field-first-bool fields 13 #f)         ;; is_blip
   (field-first-float32 fields 14 1.0)     ;; health
   (field-first-float32 fields 15 1.0)     ;; health_max
   (field-first-float32 fields 16 0.0)     ;; shield
   (field-first-float32 fields 36 0.0)     ;; shield_max
   (field-first-float32 fields 17 0.0)     ;; energy
   (field-first-float32 fields 37 0.0)     ;; energy_max
   (field-first-varint fields 18 0)        ;; mineral_contents
   (field-first-varint fields 19 0)        ;; vespene_contents
   (field-first-bool fields 20 #f)         ;; is_flying
   (field-first-bool fields 21 #f)         ;; is_burrowed
   (field-first-bool fields 38 #f)         ;; is_hallucination
   (field-first-bool fields 35 #t)         ;; is_powered
   (field-first-bool fields 39 #f)         ;; is_active
   orders                                  ;; orders
   (field-first-varint fields 23 0)        ;; add_on_tag
   buff-ids                                ;; buff_ids
   (field-first-varint fields 28 0)        ;; assigned_harvesters
   (field-first-varint fields 29 0)        ;; ideal_harvesters
   (field-first-float32 fields 30 0.0)     ;; weapon_cooldown
   (field-first-varint fields 34 0)        ;; engaged_target_tag
   (field-first-varint fields 40 0)        ;; attack_upgrade_level
   (field-first-varint fields 41 0)        ;; armor_upgrade_level
   (field-first-varint fields 42 0)))      ;; shield_upgrade_level

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
  (sc2-game-info map-name local-map-path player-info map-size playable-area start-locs))

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
     tech-lab reactor barracks-tech-lab barracks-reactor factory-tech-lab factory-reactor
     starport-tech-lab starport-reactor
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
                  #:when (= (sc2-unit-alliance u) 1))
         (sc2-id->unit-symbol (sc2-unit-unit-type u))))
     (cond
       [(ormap (lambda (s) (memq s '(hatchery lair hive drone overlord larva))) my-syms) 'Zerg]
       [(ormap (lambda (s) (memq s '(command-center orbital-command planetary-fortress scv marine))) my-syms) 'Terran]
       [(ormap (lambda (s) (memq s '(nexus probe pylon gateway))) my-syms) 'Protoss]
       [(memq configured-race '(Zerg Terran Protoss)) configured-race]
       [else 'Zerg])]))

(define (cluster-resource-centroids resources)
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
  (reverse clusters))

(define SC2-WARPGATE-LAST-LOOP (box 0))
(define SC2-WARPGATE-COOLDOWN-UNTIL (make-hasheqv))
(define SC2-HOME-BASE-ANCHOR (box #f))

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

(define (any-point? pt)
  (or (sc2-point2d? pt) (sc2-point3d? pt)))

(define (any-point-x pt)
  (cond
    [(sc2-point2d? pt) (sc2-point2d-x pt)]
    [(sc2-point3d? pt) (sc2-point3d-x pt)]
    [else 0.0]))

(define (any-point-y pt)
  (cond
    [(sc2-point2d? pt) (sc2-point2d-y pt)]
    [(sc2-point3d? pt) (sc2-point3d-y pt)]
    [else 0.0]))

(define (sc2-observation->runtime-obs-hash obs
                                           #:game-info [game-info #f]
                                           #:our-player-id [our-player-id 1]
                                           #:configured-race [configured-race 'Random]
                                           #:used-creep-tumors [used-tumors (seteqv)])
  (define cur-loop (sc2-observation-game-loop obs))
  (when (< cur-loop (unbox SC2-WARPGATE-LAST-LOOP))
    (hash-clear! SC2-WARPGATE-COOLDOWN-UNTIL)
    (set-box! SC2-HOME-BASE-ANCHOR #f))
  (set-box! SC2-WARPGATE-LAST-LOOP cur-loop)
  (define pc (sc2-observation-player-common obs))
  (define units (sc2-observation-units obs))
  (define actual-race
    (detect-actual-race-from-units units game-info our-player-id configured-race))

  (define self-units (filter (lambda (u) (= (sc2-unit-alliance u) 1)) units))
  (define enemy-all (filter (lambda (u) (= (sc2-unit-alliance u) 4)) units))
  (define neutral-all (filter (lambda (u) (= (sc2-unit-alliance u) 3)) units))

  (define mineral-fields (filter sc2-unit-is-mineral-field? neutral-all))
  (define raw-my-townhalls (filter sc2-unit-is-townhall? self-units))
  (when (and (= (length raw-my-townhalls) 1)
             (or (not (unbox SC2-HOME-BASE-ANCHOR))
                 (<= cur-loop 20)))
    (define p0 (sc2-unit-pos (first raw-my-townhalls)))
    (set-box! SC2-HOME-BASE-ANCHOR (cons (sc2-point3d-x p0) (sc2-point3d-y p0))))
  (define my-townhalls (sort-townhalls-main-first raw-my-townhalls))
  (define ready-townhalls
    (filter (lambda (u) (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)) my-townhalls))
  (define my-gas-bldgs (filter sc2-unit-is-gas-building? self-units))
  (define ready-gas-bldgs
    (filter (lambda (u) (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)) my-gas-bldgs))
  (define my-workers (filter sc2-unit-is-worker? self-units))

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

  ;; Compute natural & third positions from actual expansion resource clusters when visible,
  ;; falling back to vector along (base -> enemy) when no expansion clusters exist (Bug #13 fix).
  (define dx (- enemy-x base-x))
  (define dy (- enemy-y base-y))
  (define d-norm (max 1.0 (sqrt (+ (sqr dx) (sqr dy)))))
  (define ux (/ dx d-norm))
  (define uy (/ dy d-norm))
  (define exp-clusters
    (sort (filter (lambda (c)
                    (> (pt-dist base-x base-y (first c) (second c)) SC2-BASE-RESOURCE-RADIUS))
                  (cluster-resource-centroids mineral-fields))
          <
          #:key (lambda (c) (pt-dist base-x base-y (first c) (second c)))))
  (define (cluster->townhall-seed c)
    (define cx (first c))
    (define cy (second c))
    (define dir-x (- SC2-DEFAULT-MAP-CENTER-X cx))
    (define dir-y (- SC2-DEFAULT-MAP-CENTER-Y cy))
    (define nd (max 1.0 (sqrt (+ (sqr dir-x) (sqr dir-y)))))
    (values (+ cx (* SC2-EXPANSION-SEED-OFFSET (/ dir-x nd)))
            (+ cy (* SC2-EXPANSION-SEED-OFFSET (/ dir-y nd)))))
  (define-values (nat-x nat-y)
    (if (not (null? exp-clusters))
        (cluster->townhall-seed (first exp-clusters))
        (values (+ base-x (* SC2-NATURAL-VECTOR-OFFSET-TILES ux))
                (+ base-y (* SC2-NATURAL-VECTOR-OFFSET-TILES uy)))))
  (define-values (third-x third-y)
    (if (>= (length exp-clusters) 2)
        (cluster->townhall-seed (second exp-clusters))
        (values (+ base-x (* SC2-THIRD-VECTOR-OFFSET-TILES ux))
                (+ base-y (* SC2-THIRD-VECTOR-OFFSET-TILES uy)))))

  ;; Closest real mineral patch tag for Orbital Command MULE calldowns (Bug #14 fix)
  (define closest-mineral-patch-id
    (if (not (null? mineral-fields))
        (sc2-unit-tag
         (argmin (lambda (m)
                   (define mp (sc2-unit-pos m))
                   (pt-dist base-x base-y (sc2-point3d-x mp) (sc2-point3d-y mp)))
                 mineral-fields))
        SC2-SYNTHETIC-MINERAL-PATCH-ID))

  ;; Pending supply (Overlord eggs / in-progress Depots / in-progress Pylons / in-transit worker build orders)
  (define pending-supply
    (+ (for/sum ([u (in-list self-units)]
                 #:when (and (memq (sc2-id->unit-symbol (sc2-unit-unit-type u))
                                   '(supply-depot pylon))
                             (< (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)))
         1)
       (for/sum ([w (in-list my-workers)]
                 #:when (and (pair? (sc2-unit-orders w))
                             (memq (sc2-unit-order-ability-id (first (sc2-unit-orders w)))
                                   '(319 881)))) ;; TERRANBUILD_SUPPLYDEPOT=319, PROTOSSBUILD_PYLON=881
         1)
       (for/sum ([u (in-list self-units)]
                 #:when (= (sc2-unit-unit-type u) 103)) ;; EGG
         (if (ormap (lambda (o) (= (sc2-unit-order-ability-id o) 1344))
                    (sc2-unit-orders u))
             1
             0))))

  ;; Pending workers (in-progress SCV / Probe / Drone eggs)
  (define pending-workers
    (+ (for/sum ([th (in-list ready-townhalls)]
                 #:when (and (pair? (sc2-unit-orders th))
                             (memq (sc2-unit-order-ability-id (first (sc2-unit-orders th)))
                                   '(524 1006)))) ;; TRAIN_SCV=524, TRAIN_PROBE=1006
         1)
       (for/sum ([u (in-list self-units)]
                 #:when (and (= (sc2-unit-unit-type u) 103)
                             (ormap (lambda (o) (= (sc2-unit-order-ability-id o) 1342))
                                    (sc2-unit-orders u)))) ;; TRAIN_DRONE=1342
         1)))

  ;; Convert ally mobile units (plus ready unused creep tumors for tumor spread!)
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
             'cloaked (or (= (sc2-unit-cloak u) 1) (= (sc2-unit-cloak u) 2))
             'burrowed (sc2-unit-is-burrowed u)
             'sieged (not (not (memq utype-sym '(siege-tank-sieged liberator-ag widow-mine-burrowed lurker-burrowed))))
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
             'has-build-order? (not (not (ormap (lambda (o)
                                                  (define s (sc2-id->ability-symbol (sc2-unit-order-ability-id o) #f))
                                                  (and s (string-prefix? (symbol->string s) "build-")))
                                                ords)))))
     (for/list ([u (in-list self-units)]
                #:when (and (memq (sc2-id->unit-symbol (sc2-unit-unit-type u))
                                  '(creep-tumor-burrowed creep-tumor-queen))
                            (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)
                            (not (set-member? used-tumors (sc2-unit-tag u)))))
       (define p (sc2-unit-pos u))
       (hash 'id (sc2-unit-tag u)
             'type 'creep-tumor-burrowed
             'x (sc2-point3d-x p)
             'y (sc2-point3d-y p)
             'hp (max 1 (exact-round (sc2-unit-health u)))
             'energy 0
             'buffs '()))))

  ;; Convert ally buildings (plus in-transit worker build orders at their target build coordinates
  ;; so buildings aren't spammed while the worker walks to the site)
  (define in-transit-bldg-records
    (filter-map
     (lambda (w)
       (and (pair? (sc2-unit-orders w))
            (let* ([ord (first (sc2-unit-orders w))]
                   [ab-id (sc2-unit-order-ability-id ord)]
                   [ab-sym (sc2-id->ability-symbol ab-id #f)]
                   [ab-str (if ab-sym (symbol->string ab-sym) "")])
              (and (string-prefix? ab-str "build-")
                   (let* ([bsym (string->symbol (substring ab-str 6))]
                          [wp (sc2-unit-pos w)]
                          [tpos (sc2-unit-order-target-pos ord)]
                          [tx (if (any-point? tpos) (any-point-x tpos) (sc2-point3d-x wp))]
                          [ty (if (any-point? tpos) (any-point-y tpos) (sc2-point3d-y wp))])
                     ;; Synthesize only while no under-construction footprint of this type exists at (tx, ty)
                     (and (not (ormap (lambda (b)
                                        (define bp (sc2-unit-pos b))
                                        (and (eq? (sc2-id->unit-symbol (sc2-unit-unit-type b)) bsym)
                                             (< (sc2-unit-build-progress b) SC2-BUILD-COMPLETE-PROGRESS)
                                             (<= (pt-dist tx ty (sc2-point3d-x bp) (sc2-point3d-y bp)) 5.0)))
                                      self-units))
                          (hash 'id (+ 9000000 (sc2-unit-tag w))
                                'type bsym
                                'x tx
                                'y ty
                                'hp SC2-PYLON-HULL-MAX-HP
                                'hp-pct 1.0
                                'build-progress SC2-IN-TRANSIT-BUILD-PROGRESS
                                'halted #f
                                'buffs '())))))))
     my-workers))

  (define sorted-self-structures
    (sort-townhalls-main-first (filter sc2-unit-is-structure? self-units)))
  (define ally-bldg-records
    (append
     (for/list ([b (in-list sorted-self-structures)])
       (define p (sc2-unit-pos b))
       (define bx (sc2-point3d-x p))
       (define by (sc2-point3d-y p))
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
       (define addon-kind
         (cond
           [(memq addon-sym '(barracks-reactor factory-reactor starport-reactor reactor)) 'reactor]
           [(memq addon-sym '(barracks-tech-lab barracks-techlab
                              factory-tech-lab factory-techlab
                              starport-tech-lab starport-techlab tech-lab techlab)) 'techlab]
           [else #f]))
       (define b-ords (sc2-unit-orders b))
       (define b-ord0 (and (pair? b-ords) (first b-ords)))
       (define wg-busy?
         (and (= (sc2-unit-unit-type b) 133)
              (< cur-loop (hash-ref SC2-WARPGATE-COOLDOWN-UNTIL (sc2-unit-tag b) 0))))
       (define eff-order-count (if wg-busy? (max 1 (length b-ords)) (length b-ords)))
       (define b-buffs
         (filter-map (lambda (bid) (buff-id->symbol bid #f))
                     (sc2-unit-buff-ids b)))
       (hash 'id (sc2-unit-tag b)
             'type bsym
             'x bx
             'y by
             'hp (max 1 (exact-round cur-hp+sh))
             'max-hp (max 1 (exact-round hp-max))
             'hp-pct eff-hp-pct
             'energy (exact-round (sc2-unit-energy b))
             'build-progress bprog
             'halted halted?
             'add-on-tag addon-tag
             'addon addon-kind
             'addon-type addon-sym
             'buffs b-buffs
             'order-count eff-order-count
             'busy? (or wg-busy? (pair? b-ords))
             'order-ability-id (if b-ord0 (sc2-unit-order-ability-id b-ord0) 0)
             'order-ability-sym (if b-ord0 (sc2-id->ability-symbol (sc2-unit-order-ability-id b-ord0) #f) #f)))
     in-transit-bldg-records))

  ;; Enemy units & buildings
  (define enemy-unit-records
    (for/list ([eu (in-list enemy-all)]
               #:when (not (sc2-unit-is-structure? eu)))
      (define p (sc2-unit-pos eu))
      (hash 'id (sc2-unit-tag eu)
            'type (sc2-id->unit-symbol (sc2-unit-unit-type eu))
            'x (sc2-point3d-x p)
            'y (sc2-point3d-y p)
            'z (sc2-point3d-z p)
            'hp (max 1 (exact-round (+ (sc2-unit-health eu) (sc2-unit-shield eu))))
            'hull-hp (max 1 (exact-round (sc2-unit-health eu)))
            'max-hp (max 1 (exact-round (+ (sc2-unit-health-max eu) (sc2-unit-shield-max eu))))
            'shield (max 0 (exact-round (sc2-unit-shield eu)))
            'flying? (sc2-unit-is-flying eu)
            'cloaked (or (= (sc2-unit-cloak eu) 1) (= (sc2-unit-cloak eu) 2))
            'burrowed (sc2-unit-is-burrowed eu)
            'weapon-cooldown (sc2-unit-weapon-cooldown eu)
            'engaged-target-tag (sc2-unit-engaged-target-tag eu))))

  (define enemy-bldg-records
    (for/list ([eb (in-list enemy-all)]
               #:when (sc2-unit-is-structure? eb))
      (define p (sc2-unit-pos eb))
      (hash 'id (sc2-unit-tag eb)
            'type (sc2-id->unit-symbol (sc2-unit-unit-type eb))
            'x (sc2-point3d-x p)
            'y (sc2-point3d-y p)
            'hp (max 1 (exact-round (sc2-unit-health eb))))))

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
          [(warpgate warp-gate-research) '(warpgate warp-gate-research)]
          [(zergling-movementspeed metabolic-boost) '(zergling-movementspeed metabolic-boost)]
          [(zergling-attackspeed adrenal-glands) '(zergling-attackspeed adrenal-glands)]
          [(centrifugal-hooks centrifical-hooks) '(centrifugal-hooks centrifical-hooks)]
          [(overlord-speed pneumatized-carapace) '(overlord-speed pneumatized-carapace)]
          [(zerg-melee-weapons-1 melee-attacks-1) '(zerg-melee-weapons-1 melee-attacks-1)]
          [(zerg-melee-weapons-2 melee-attacks-2) '(zerg-melee-weapons-2 melee-attacks-2)]
          [(zerg-melee-weapons-3 melee-attacks-3) '(zerg-melee-weapons-3 melee-attacks-3)]
          [(zerg-missile-weapons-1 missile-attacks-1) '(zerg-missile-weapons-1 missile-attacks-1)]
          [(zerg-missile-weapons-2 missile-attacks-2) '(zerg-missile-weapons-2 missile-attacks-2)]
          [(zerg-missile-weapons-3 missile-attacks-3) '(zerg-missile-weapons-3 missile-attacks-3)]
          [(zerg-ground-armor-1 ground-carapace-1) '(zerg-ground-armor-1 ground-carapace-1)]
          [(zerg-ground-armor-2 ground-carapace-2) '(zerg-ground-armor-2 ground-carapace-2)]
          [(zerg-ground-armor-3 ground-carapace-3) '(zerg-ground-armor-3 ground-carapace-3)]
          [(zerg-flyer-weapons-1 flyer-attacks-1) '(zerg-flyer-weapons-1 flyer-attacks-1)]
          [(zerg-flyer-armor-1 flyer-carapace-1) '(zerg-flyer-armor-1 flyer-carapace-1)]
          [(infernal-preigniter infernal-pre-igniter) '(infernal-preigniter infernal-pre-igniter)]
          [(banshee-cloak cloaking-field) '(banshee-cloak cloaking-field)]
          [(terran-infantry-weapons-1 infantry-weapons-1) '(terran-infantry-weapons-1 infantry-weapons-1)]
          [(terran-infantry-weapons-2 infantry-weapons-2) '(terran-infantry-weapons-2 infantry-weapons-2)]
          [(terran-infantry-weapons-3 infantry-weapons-3) '(terran-infantry-weapons-3 infantry-weapons-3)]
          [(terran-infantry-armor-1 infantry-armor-1) '(terran-infantry-armor-1 infantry-armor-1)]
          [(terran-infantry-armor-2 infantry-armor-2) '(terran-infantry-armor-2 infantry-armor-2)]
          [(terran-infantry-armor-3 infantry-armor-3) '(terran-infantry-armor-3 infantry-armor-3)]
          [(terran-vehicle-weapons-1 vehicle-weapons-1) '(terran-vehicle-weapons-1 vehicle-weapons-1)]
          [(terran-vehicle-and-ship-plating-1 vehicle-and-ship-plating-1)
           '(terran-vehicle-and-ship-plating-1 vehicle-and-ship-plating-1)]
          [(terran-ship-weapons-1 ship-weapons-1) '(terran-ship-weapons-1 ship-weapons-1)]
          [(psi-storm psistorm) '(psi-storm psistorm)]
          [(protoss-ground-weapons-1 ground-weapons-1) '(protoss-ground-weapons-1 ground-weapons-1)]
          [(protoss-ground-weapons-2 ground-weapons-2) '(protoss-ground-weapons-2 ground-weapons-2)]
          [(protoss-ground-weapons-3 ground-weapons-3) '(protoss-ground-weapons-3 ground-weapons-3)]
          [(protoss-ground-armor-1 ground-armor-1) '(protoss-ground-armor-1 ground-armor-1)]
          [(protoss-ground-armor-2 ground-armor-2) '(protoss-ground-armor-2 ground-armor-2)]
          [(protoss-ground-armor-3 ground-armor-3) '(protoss-ground-armor-3 ground-armor-3)]
          [(protoss-shields-1 shields-1) '(protoss-shields-1 shields-1)]
          [(protoss-air-weapons-1 air-weapons-1) '(protoss-air-weapons-1 air-weapons-1)]
          [(protoss-air-armor-1 air-armor-1) '(protoss-air-armor-1 air-armor-1)]
          [else (list u)])))))

  ;; Researched & pending upgrades
  (define researched-upgrades
    (expand-upgrade-aliases
     (filter-map (lambda (uid) (sc2-id->upgrade-symbol uid #f))
                 (sc2-observation-upgrade-ids obs))))

  (define pending-upgrades
    (expand-upgrade-aliases
     (filter-map
      (lambda (b)
        (and (sc2-unit-is-structure? b)
             (pair? (sc2-unit-orders b))
             (let* ([ab-id (sc2-unit-order-ability-id (first (sc2-unit-orders b)))]
                    [ab-sym (sc2-id->ability-symbol ab-id #f)]
                    [ab-str (if ab-sym (symbol->string ab-sym) "")])
               (if (string-prefix? ab-str "research-")
                   (string->symbol (substring ab-str 9))
                   #f))))
      self-units)))

  ;; Harvester & depletion metrics
  (define min-harvesters
    (for/sum ([th (in-list ready-townhalls)])
      (max 0 (sc2-unit-assigned-harvesters th))))
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
      (if (and (not (null? close-mins)) (< rem-min SC2-BASE-DEPLETION-MINERAL-THRESH)) 1 0)))

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
        'enemy-x enemy-x
        'enemy-y enemy-y
        'enemy-base (list enemy-x enemy-y)
        'mineral-patch-id closest-mineral-patch-id
        'ally-units ally-unit-records
        'ally-buildings ally-bldg-records
        'enemy-units enemy-unit-records
        'enemy-buildings enemy-bldg-records
        'effects effect-records
        'researched-upgrades researched-upgrades
        'pending-upgrades pending-upgrades
        'depleting-bases depleting-bases
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

(define (collect-spiral-candidates anchor-x anchor-y existing-units
                                   #:min-spacing [min-spacing 3.5]
                                   #:max-radius [max-radius 14.0]
                                   #:step [step 2.0]
                                   #:limit [limit 24]
                                   #:extra-reserved-points [extra-reserved-points '()]
                                   #:ws-active-placement? [ws-active-placement? #f])
  ;; Collect in-transit worker build target points and existing Terran East (+X) add-on footprints
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
  (define terran-addon-pts
    (for/list ([u (in-list existing-units)]
               #:when (memq (sc2-id->unit-symbol (sc2-unit-unit-type u))
                            '(barracks factory starport)))
      (define p (sc2-unit-pos u))
      (sc2-point2d (+ (sc2-point3d-x p) SC2-TERRAN-ADDON-OFFSET-X)
                   (+ (sc2-point3d-y p) SC2-TERRAN-ADDON-OFFSET-Y))))
  (define all-reserved-pts
    (append extra-reserved-points in-transit-build-pts terran-addon-pts))

  (define (clear-spot? cx cy)
    (and (>= cx SC2-MAP-PLAYABLE-MIN-COORD) (<= cx SC2-MAP-PLAYABLE-MAX-COORD)
         (>= cy SC2-MAP-PLAYABLE-MIN-COORD) (<= cy SC2-MAP-PLAYABLE-MAX-COORD)
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
                                        #:extra-reserved-points [extra-reserved-points '()])
  (define cands
    (collect-spiral-candidates anchor-x anchor-y existing-units
                               #:min-spacing min-spacing
                               #:max-radius max-radius
                               #:step step
                               #:limit 1
                               #:extra-reserved-points extra-reserved-points))
  (if (not (null? cands))
      (first cands)
      (sc2-point2d anchor-x anchor-y)))

(define (find-verified-building-placement ws-conn ab-id anchor-x anchor-y existing-units
                                          #:min-spacing [min-spacing 3.5]
                                          #:max-radius [max-radius 14.0]
                                          #:step [step 2.0]
                                          #:extra-reserved-points [extra-reserved-points '()]
                                          #:anchor-points [anchor-points #f])
  ;; For Terran production facilities (Barracks=321, Factory=328, Starport=329), also filter out
  ;; candidates whose East (+X) add-on footprint at (cx + 2.5, cy - 0.5) collides with structures.
  (define needs-terran-addon-clearance? (memv ab-id '(321 328 329)))
  (define ws-active? (and (sc2-ws-conn? ws-conn) (not (sc2-ws-conn-closed? ws-conn))))
  (define (filter-addon-clear c-list)
    (filter (lambda (pt)
              (define ax (+ (sc2-point2d-x pt) SC2-TERRAN-ADDON-OFFSET-X))
              (define ay (+ (sc2-point2d-y pt) SC2-TERRAN-ADDON-OFFSET-Y))
              (and (<= ax SC2-MAP-PLAYABLE-MAX-COORD)
                   (>= ay SC2-MAP-PLAYABLE-MIN-COORD)
                   (for/and ([u (in-list existing-units)]
                             #:when (or (sc2-unit-is-structure? u)
                                        (sc2-unit-is-mineral-field? u)
                                        (sc2-unit-is-vespene-geyser? u)))
                     (define p (sc2-unit-pos u))
                     (> (pt-dist ax ay (sc2-point3d-x p) (sc2-point3d-y p))
                        (+ SC2-ADDON-FOOTPRINT-HALF-SIZE (max 0.5 (sc2-unit-radius u)))))))
            c-list))
  (define anchors
    (if (and (list? anchor-points) (not (null? anchor-points)))
        anchor-points
        (list (cons anchor-x anchor-y))))
  (define raw-cands
    (let ([all-pts
           (append*
            (for/list ([ap (in-list anchors)])
              (collect-spiral-candidates (car ap) (cdr ap) existing-units
                                         #:min-spacing min-spacing
                                         #:max-radius max-radius
                                         #:step step
                                         #:limit 24
                                         #:extra-reserved-points extra-reserved-points
                                         #:ws-active-placement? ws-active?)))])
      (take all-pts (min 64 (length all-pts)))))
  (define cands
    (if needs-terran-addon-clearance?
        (let ([addon-clear (filter-addon-clear raw-cands)])
          (if (not (null? addon-clear)) addon-clear raw-cands))
        raw-cands))
  (cond
    [(null? cands)
     (sc2-point2d anchor-x anchor-y)]
    [(and (sc2-ws-conn? ws-conn) (not (sc2-ws-conn-closed? ws-conn)))
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
             [both-valid-pt both-valid-pt]
             [else
              ;; Expand search radius to find a spot where BOTH the 3x3 facility and East 2x2 add-on fit!
              (define wide-raw
                (collect-spiral-candidates anchor-x anchor-y existing-units
                                           #:min-spacing min-spacing
                                           #:max-radius (max 18.0 (+ max-radius 4.0))
                                           #:step 2.0
                                           #:limit 48
                                           #:extra-reserved-points extra-reserved-points))
              (define wide-cands (filter-addon-clear wide-raw))
              (define wide-both
                (and (not (null? wide-cands))
                     (let ([w-res (query-dual-batch wide-cands)])
                       (and (>= (length w-res) (* 2 (length wide-cands)))
                            (for/first ([pt (in-list wide-cands)]
                                        [idx (in-naturals 0)]
                                        #:when (and (= (list-ref w-res (* 2 idx)) 1)
                                                    (= (list-ref w-res (+ (* 2 idx) 1)) 1)))
                              pt)))))
              (or wide-both main-valid-pt (first cands))])]
          [else
           (or (for/first ([pt (in-list cands)]
                           [res (in-list q-results)]
                           #:when (= res 1))
                 pt)
               (first cands))])]
       [else
        (define q-items
          (for/list ([pt (in-list cands)])
            (sc2-query-placement ab-id (sc2-point2d-x pt) (sc2-point2d-y pt) 0)))
        (define q-resp
          (sc2-ws-rpc! ws-conn
                       (make-request-query-placement q-items
                                                     #:ignore-resource-requirements? #t)))
        (define q-results (sc2-response-query-placements q-resp))
        (define verified-pt
          (for/first ([pt (in-list cands)]
                      [res (in-list q-results)]
                      #:when (= res 1))
            pt))
        (or verified-pt (first cands))])]
    [else
     (first cands)]))

(define (find-best-expansion-placement ws-conn th-ab home-x home-y units)
  (define neutral-units (filter (lambda (u) (= (sc2-unit-alliance u) 3)) units))
  (define all-townhalls (filter sc2-unit-is-townhall? units))
  (define resources
    (filter (lambda (u)
              (or (sc2-unit-is-mineral-field? u)
                  (sc2-unit-is-vespene-geyser? u)))
            neutral-units))
  (define clusters (cluster-resource-centroids resources))

  ;; Filter to un-taken clusters (no existing TownHall within SC2-TOWNHALL-EXCLUSION-RADIUS)
  (define open-clusters
    (filter (lambda (c)
              (define cx (first c))
              (define cy (second c))
              (and (> (pt-dist home-x home-y cx cy) SC2-BASE-RESOURCE-RADIUS)
                   (not (ormap (lambda (th)
                                 (define tp (sc2-unit-pos th))
                                 (<= (pt-dist cx cy (sc2-point3d-x tp) (sc2-point3d-y tp))
                                     SC2-TOWNHALL-EXCLUSION-RADIUS))
                               all-townhalls))))
            clusters))

  (cond
    [(null? open-clusters)
     (find-verified-building-placement ws-conn th-ab (+ home-x 20.0) (+ home-y 20.0) units
                                       #:min-spacing 4.5 #:max-radius 12.0 #:step 1.0)]
    [else
     (define best-cluster
       (argmin (lambda (c) (pt-dist home-x home-y (first c) (second c)))
               open-clusters))
     (define cx (first best-cluster))
     (define cy (second best-cluster))
     (define members (third best-cluster))
     ;; Offset SC2-EXPANSION-SEED-OFFSET tiles from mineral centroid toward map center
     (define dir-x (- SC2-DEFAULT-MAP-CENTER-X cx))
     (define dir-y (- SC2-DEFAULT-MAP-CENTER-Y cy))
     (define norm-d (max 1.0 (sqrt (+ (sqr dir-x) (sqr dir-y)))))
     (define seed-x (+ cx (* SC2-EXPANSION-SEED-OFFSET (/ dir-x norm-d))))
     (define seed-y (+ cy (* SC2-EXPANSION-SEED-OFFSET (/ dir-y norm-d))))
     ;; Generate candidate half-tile centers around (seed-x, seed-y)
     (define cands
       (for*/list ([r (in-list '(0.0 1.0 2.0 3.0 4.0 5.0 6.0 7.0))]
                   [dx (in-range (- r) (+ r 0.1) 1.0)]
                   [dy (in-range (- r) (+ r 0.1) 1.0)]
                   #:when (or (= r 0.0) (= (abs dx) r) (= (abs dy) r))
                   [px (in-value (+ (floor seed-x) 0.5 dx))]
                   [py (in-value (+ (floor seed-y) 0.5 dy))]
                   #:when (and (>= px SC2-MAP-PLAYABLE-MIN-COORD) (<= px SC2-MAP-PLAYABLE-MAX-COORD)
                               (>= py SC2-MAP-PLAYABLE-MIN-COORD) (<= py SC2-MAP-PLAYABLE-MAX-COORD)
                               (for/and ([m (in-list members)])
                                 (define mp (sc2-unit-pos m))
                                 (>= (pt-dist px py (sc2-point3d-x mp) (sc2-point3d-y mp))
                                     SC2-EXPANSION-MINERAL-STANDOFF))))
         (sc2-point2d px py)))
     (cond
       [(null? cands)
        (sc2-point2d seed-x seed-y)]
       [(and (sc2-ws-conn? ws-conn) (not (sc2-ws-conn-closed? ws-conn)))
        (define batch (take cands (min 32 (length cands))))
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
            (first batch))]
       [else
        (first cands)])]))

(define (select-producer-tags-for-unit unit-sym self-units)
  (define norm (normalize-sc2-name->symbol unit-sym))
  ;; Map unit tags to unit structs so we can inspect attached add-on types (Reactor vs TechLab)
  (define unit-by-tag
    (for/hasheqv ([u (in-list self-units)])
      (values (sc2-unit-tag u) u)))
  (define (facility-has-reactor? u)
    (define addon-tag (sc2-unit-add-on-tag u))
    (and (> addon-tag 0)
         (let ([addon-u (hash-ref unit-by-tag addon-tag #f)])
           (if addon-u
               (memq (sc2-id->unit-symbol (sc2-unit-unit-type addon-u))
                     '(barracks-reactor factory-reactor starport-reactor reactor))
               ;; If add-on unit wasn't separately listed in synthetic unit test, treat positive add-on-tag
               ;; on non-TechLab-requiring units as Reactor-capable
               #t))))
  (define (facility-has-techlab? u)
    (define addon-tag (sc2-unit-add-on-tag u))
    (and (> addon-tag 0)
         (let ([addon-u (hash-ref unit-by-tag addon-tag #f)])
           (if addon-u
               (memq (sc2-id->unit-symbol (sc2-unit-unit-type addon-u))
                     '(barracks-tech-lab barracks-techlab
                       factory-tech-lab factory-techlab
                       starport-tech-lab starport-techlab
                       tech-lab techlab))
               #t))))
  (define needs-techlab? (sc2-unit-requires-techlab? norm))
  ;; Returns producer tags ordered with completely idle (0-order) facilities first,
  ;; and includes a 0-order Reactor facility's tag twice so multi-unit production waves
  ;; can utilize both Reactor queue slots in a single step.
  (define (idle-ready-of-types syms)
    (define any-addon-on-type?
      (ormap (lambda (u)
               (and (memq (sc2-id->unit-symbol (sc2-unit-unit-type u)) syms)
                    (> (sc2-unit-add-on-tag u) 0)))
             self-units))
    (define zero-order-tags '())
    (define second-slot-reactor-tags '())
    (for ([u (in-list self-units)]
          #:when (and (memq (sc2-id->unit-symbol (sc2-unit-unit-type u)) syms)
                      (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)
                      (or (not needs-techlab?)
                          (not any-addon-on-type?)
                          (facility-has-techlab? u))))
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
                #:when (= (sc2-unit-unit-type u) 151)) ;; LARVA
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
     (idle-ready-of-types '(hydralisk-den))]
    [(eq? norm 'baneling)
     (idle-ready-of-types '(zergling))]
    [(eq? norm 'ravager)
     (idle-ready-of-types '(roach))]
    [(memq norm '(lurker lurker-mp))
     (idle-ready-of-types '(hydralisk))]
    [(memq norm '(brood-lord broodlord))
     (idle-ready-of-types '(corruptor))]
    [(eq? norm 'overseer)
     (idle-ready-of-types '(overlord overlord-transport))]
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
     (define templars (idle-ready-of-types '(high-templar dark-templar)))
     (if (>= (length templars) 2) (take templars 2) '())]
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
      [(memq norm '(adaptive-talons lurker-range))
       '(lurker-den lurker-den-mp)]
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
      [(memq norm '(burrow overlord-speed pneumatized-carapace))
       '(hatchery lair hive)]
      [(memq norm '(stimpack combat-shield concussive-shells))
       '(barracks-tech-lab barracks-techlab tech-lab)]
      [(memq norm '(infernal-preigniter infernal-pre-igniter drilling-claws cyclone-lock-on-damage smart-servos))
       '(factory-tech-lab factory-techlab tech-lab)]
      [(memq norm '(banshee-cloak cloaking-field hyperflight-rotors))
       '(starport-tech-lab starport-techlab tech-lab)]
      [(eq? norm 'personal-cloaking)
       '(ghost-academy)]
      [(eq? norm 'weapon-refit)
       '(fusion-core)]
      [(or (string-contains? str "terran-infantry")
           (string-contains? str "infantry-weapons")
           (string-contains? str "infantry-armor")
           (memq norm '(hi-sec-auto-tracking neosteel-armor)))
       '(engineering-bay)]
      [(or (string-contains? str "terran-vehicle")
           (string-contains? str "vehicle-weapons")
           (string-contains? str "vehicle-and-ship-plating")
           (string-contains? str "terran-ship")
           (string-contains? str "ship-weapons"))
       '(armory)]
      [(memq norm '(warpgate warp-gate warp-gate-research))
       '(cybernetics-core)]
      [(memq norm '(charge blink resonating-glaives adept-piercing-attack))
       '(twilight-council)]
      [(memq norm '(psi-storm psistorm))
       '(templar-archive templar-archives)]
      [(eq? norm 'shadow-strike)
       '(dark-shrine)]
      [(memq norm '(extended-thermal-lance gravitic-booster gravitic-drive))
       '(robotics-bay robotics-support-bay)]
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
              #:when (and (memq (sc2-id->unit-symbol (sc2-unit-unit-type u)) target-bldgs)
                          (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)
                          (null? (sc2-unit-orders u))))
    (sc2-unit-tag u)))

(define (worker-has-build-order? w)
  (ormap (lambda (o)
           (define ab-sym (sc2-id->ability-symbol (sc2-unit-order-ability-id o) #f))
           (and ab-sym (string-prefix? (symbol->string ab-sym) "build-")))
         (sc2-unit-orders w)))

(define (saturate-workers-and-gas-commands obs
                                           #:excluded-worker-tags [excluded-worker-tags (seteqv)])
  (define pc (sc2-observation-player-common obs))
  (define cur-min (sc2-player-common-minerals pc))
  (define cur-gas (sc2-player-common-vespene pc))
  (define units (sc2-observation-units obs))
  (define self-units (filter (lambda (u) (= (sc2-unit-alliance u) 1)) units))
  (define neutral-units (filter (lambda (u) (= (sc2-unit-alliance u) 3)) units))
  (define mineral-fields (filter sc2-unit-is-mineral-field? neutral-units))
  (define ready-townhalls
    (sort-townhalls-main-first
     (filter (lambda (u)
               (and (sc2-unit-is-townhall? u)
                    (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)))
             self-units)))
  (define ready-gas-bldgs
    (filter (lambda (u)
              (and (sc2-unit-is-gas-building? u)
                   (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)))
            self-units))
  (define all-gas-tags (list->seteqv (map sc2-unit-tag ready-gas-bldgs)))

  (define workers
    (filter (lambda (w)
              (and (sc2-unit-is-worker? w)
                   (not (set-member? excluded-worker-tags (sc2-unit-tag w)))
                   (not (worker-has-build-order? w))))
            self-units))
  (define idle-workers (filter (lambda (w) (null? (sc2-unit-orders w))) workers))
  (define under-gas
    (filter (lambda (u)
              (define gp (sc2-unit-pos u))
              (and (< (sc2-unit-assigned-harvesters u)
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
              (< (sc2-unit-assigned-harvesters th)
                 (if (> ih 0) ih SC2-IDEAL-WORKERS-PER-MINERAL-LINE)))
            ready-townhalls))
  (define over-townhalls
    (filter (lambda (th)
              (define ih (sc2-unit-ideal-harvesters th))
              (> (sc2-unit-assigned-harvesters th)
                 (if (> ih 0) ih SC2-IDEAL-WORKERS-PER-MINERAL-LINE)))
            ready-townhalls))

  ;; Helper: mineral fields near a specific TownHall (or all mineral fields if none within radius)
  (define (minerals-near-townhall th)
    (define tp (sc2-unit-pos th))
    (define local
      (filter (lambda (m)
                (define mp (sc2-unit-pos m))
                (<= (pt-dist (sc2-point3d-x tp) (sc2-point3d-y tp)
                             (sc2-point3d-x mp) (sc2-point3d-y mp))
                    SC2-BASE-RESOURCE-RADIUS))
              mineral-fields))
    (if (not (null? local)) local mineral-fields))

  (define commanded-this-frame (mutable-seteqv))
  (define cmds '())
  (define (issue-gather! w target-tag)
    (set-add! commanded-this-frame (sc2-unit-tag w))
    (set! cmds
          (cons (sc2-raw-unit-command 3666 #f target-tag (list (sc2-unit-tag w)) #f)
                cmds)))

  ;; 1. Send idle workers to mineral patches at under-saturated TownHalls first, or closest mineral patch
  (when (and (not (null? idle-workers)) (not (null? mineral-fields)))
    (define candidate-mins
      (if (not (null? under-townhalls))
          (minerals-near-townhall (first under-townhalls))
          mineral-fields))
    (for ([w (in-list idle-workers)])
      (define wp (sc2-unit-pos w))
      (define best-min
        (argmin (lambda (m)
                  (define mp (sc2-unit-pos m))
                  (pt-dist (sc2-point3d-x wp) (sc2-point3d-y wp)
                           (sc2-point3d-x mp) (sc2-point3d-y mp)))
                candidate-mins))
      (issue-gather! w (sc2-unit-tag best-min))))

  ;; 2. Assign 1 worker per frame to under-saturated gas building (Bug #8 fix:
  ;;    never re-order workers already targeting gas, carrying gas buffs 273/274/275,
  ;;    returning cargo 3667, OR within SC2-GAS-HARVESTER-EXCLUSION-RADIUS of a gas building)
  (define gas-over-banked?
    (and (> cur-gas SC2-GAS-FLOAT-PULL-THRESHOLD)
         (< cur-min SC2-MINERAL-STARVED-THRESHOLD)))
  (when (and (not (null? under-gas))
             (>= (length workers) SC2-MIN-WORKERS-FOR-GAS)
             (not gas-over-banked?))
    (define gb (first under-gas))
    (define gp (sc2-unit-pos gb))
    (define (eligible-for-gas? w)
      (and (not (set-member? commanded-this-frame (sc2-unit-tag w)))
           (not (ormap (lambda (bid) (memv bid '(273 274 275)))
                       (sc2-unit-buff-ids w)))
           (not (ormap (lambda (o)
                         (or (set-member? all-gas-tags (sc2-unit-order-target-unit-tag o))
                             (memv (sc2-unit-order-ability-id o) '(296 299 1184 3667))))
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

  ;; 3. Transfer 1 worker per step from over-saturated / mined-out TownHall to under-saturated expansion (Bug #9 fix)
  (when (and (not (null? over-townhalls))
             (not (null? under-townhalls))
             (not (null? mineral-fields)))
    (define src-th (first over-townhalls))
    (define dst-th (first under-townhalls))
    (define sp (sc2-unit-pos src-th))
    (define dst-mins (minerals-near-townhall dst-th))
    (define transferable
      (filter (lambda (w)
                (define wp (sc2-unit-pos w))
                (and (not (set-member? commanded-this-frame (sc2-unit-tag w)))
                     (not (ormap (lambda (bid) (memv bid '(273 274 275)))
                                 (sc2-unit-buff-ids w)))
                     (not (ormap (lambda (o)
                                   (or (set-member? all-gas-tags (sc2-unit-order-target-unit-tag o))
                                       (memv (sc2-unit-order-ability-id o) '(296 299 1184 3667))))
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
    (when (and (not (null? transferable)) (not (null? dst-mins)))
      (issue-gather! (first transferable) (sc2-unit-tag (first dst-mins)))))

  ;; 4. Pull 1 gas worker back to minerals when floating >600 gas while <200 minerals (Bug #9 part 2)
  (when (and gas-over-banked? (not (null? mineral-fields)) (not (null? ready-gas-bldgs)))
    (define gas-worker
      (for/first ([w (in-list workers)]
                  #:when (and (not (set-member? commanded-this-frame (sc2-unit-tag w)))
                              (ormap (lambda (o)
                                       (set-member? all-gas-tags (sc2-unit-order-target-unit-tag o)))
                                     (sc2-unit-orders w))))
        w))
    (when gas-worker
      (define wp (sc2-unit-pos gas-worker))
      (define best-min
        (argmin (lambda (m)
                  (define mp (sc2-unit-pos m))
                  (pt-dist (sc2-point3d-x wp) (sc2-point3d-y wp)
                           (sc2-point3d-x mp) (sc2-point3d-y mp)))
                mineral-fields))
      (issue-gather! gas-worker (sc2-unit-tag best-min))))

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

(define (translate-bot-actions->sc2-raw-commands actions obs
                                                 #:used-creep-tumors [used-tumors #f]
                                                 #:ws-conn [ws-conn #f]
                                                 #:enemy-base [enemy-base #f]
                                                 #:commanded-workers [commanded-workers #f])
  (define units (if (sc2-observation? obs) (sc2-observation-units obs) '()))
  (define power-sources (if (sc2-observation? obs) (sc2-observation-power-sources obs) '()))
  (define self-units (filter (lambda (u) (= (sc2-unit-alliance u) 1)) units))
  (define enemy-units (filter (lambda (u) (= (sc2-unit-alliance u) 4)) units))
  (define neutral-units (filter (lambda (u) (= (sc2-unit-alliance u) 3)) units))
  (define mineral-fields (filter sc2-unit-is-mineral-field? neutral-units))
  (define workers (filter sc2-unit-is-worker? self-units))
  (define townhalls (sort-townhalls-main-first (filter sc2-unit-is-townhall? self-units)))
  (define combat-units
    (filter (lambda (u)
              (and (not (sc2-unit-is-structure? u))
                   (not (sc2-unit-is-worker? u))
                   (not (memq (sc2-id->unit-symbol (sc2-unit-unit-type u))
                              '(larva egg overlord queen overseer observer)))))
            self-units))
  (define self-unit-by-tag
    (for/hasheqv ([u (in-list self-units)])
      (values (sc2-unit-tag u) u)))

  (define (unit-has-protected-queen-order? t)
    (define u (hash-ref self-unit-by-tag t #f))
    (and u
         (pair? (sc2-unit-orders u))
         (memv (sc2-unit-order-ability-id (first (sc2-unit-orders u)))
               '(251 1694))))

  (define-values (home-x home-y)
    (if (not (null? townhalls))
        (let ([p (sc2-unit-pos (first townhalls))])
          (values (sc2-point3d-x p) (sc2-point3d-y p)))
        (let ([anchor (unbox SC2-HOME-BASE-ANCHOR)])
          (if anchor
              (values (car anchor) (cdr anchor))
              (values SC2-DEFAULT-HOME-BASE-X SC2-DEFAULT-HOME-BASE-Y)))))

  ;; Track producer, worker, geyser, combat tags, and build-site reservations within this step
  (define used-producer-tags (mutable-seteqv))
  (define used-producer-counts (make-hasheqv))
  (define used-worker-tags (mutable-seteqv))
  (define used-geyser-tags (mutable-seteqv))
  (define commanded-combat-tags (mutable-seteqv))
  (define step-reserved-build-pts '())
  (define last-cam-pt #f)

  (define (reserve-step-build-pt! pt [ab-id 0])
    (when (sc2-point2d? pt)
      (set! step-reserved-build-pts (cons pt step-reserved-build-pts))
      (when (memv ab-id '(321 328 329))
        (set! step-reserved-build-pts
              (cons (sc2-point2d (+ (sc2-point2d-x pt) SC2-TERRAN-ADDON-OFFSET-X)
                                 (+ (sc2-point2d-y pt) SC2-TERRAN-ADDON-OFFSET-Y))
                    step-reserved-build-pts)))))

  (define (record-worker-used! wtag)
    (when wtag
      (set-add! used-worker-tags wtag)
      (when (set-mutable? commanded-workers)
        (set-add! commanded-workers wtag))))

  (define (pick-worker-near tx ty)
    (define avail-workers
      (filter (lambda (w)
                (and (not (set-member? used-worker-tags (sc2-unit-tag w)))
                     (not (worker-has-build-order? w))))
              workers))
    (define pool (if (not (null? avail-workers)) avail-workers workers))
    (if (null? pool)
        #f
        (let ([chosen
               (sc2-unit-tag
                (argmin (lambda (w)
                          (define wp (sc2-unit-pos w))
                          (+ (pt-dist tx ty (sc2-point3d-x wp) (sc2-point3d-y wp))
                             (if (null? (sc2-unit-orders w)) 0.0 4.0)))
                        pool))])
          (record-worker-used! chosen)
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
    (define open (if (not (null? open-near-th)) open-near-th open-all))
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
                 #:when (and (eq? (sc2-id->unit-symbol (sc2-unit-unit-type u)) 'pylon)
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

  ;; Checks whether unit `t` is already executing an equivalent order in `self-units`
  ;; so we do not spam redundant orders that reset turn rate / movement acceleration.
  (define (unit-already-executing-order? t ab-id target-pt target-unit-id)
    (define u (hash-ref self-unit-by-tag t #f))
    (and u
         (pair? (sc2-unit-orders u))
         (let ([o (first (sc2-unit-orders u))])
           (and (= (sc2-unit-order-ability-id o) ab-id)
                (cond
                  [(> target-unit-id 0)
                   (= (sc2-unit-order-target-unit-tag o) target-unit-id)]
                  [(any-point? target-pt)
                   (define op (sc2-unit-order-target-pos o))
                   (and (any-point? op)
                        (<= (pt-dist (any-point-x target-pt) (any-point-y target-pt)
                                     (any-point-x op) (any-point-y op))
                            SC2-ORDER-EQUIV-DIST-TOLERANCE))]
                  [(= ab-id 18) #t]
                  [else #f])))))

  ;; Filters a list of combat unit tags:
  ;;   1. Skips tags already commanded earlier in this step (`commanded-combat-tags`).
  ;;   2. Skips Queens that are currently executing Inject Larva (251) or Spawn Creep Tumor (1694).
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
                     (not (unit-has-protected-queen-order? t))))
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

  (define (emit-camera-move! raw-x raw-y)
    (define cx (scale-bot-coord-to-world raw-x home-x))
    (define cy (scale-bot-coord-to-world raw-y home-y))
    (when (or (not last-cam-pt)
              (> (pt-dist cx cy (car last-cam-pt) (cdr last-cam-pt))
                 SC2-CAMERA-MOVE-DEDUP-DIST))
      (set! last-cam-pt (cons cx cy))
      (emit! (sc2-raw-camera-move cx cy 0.0))))

  (for ([act (in-list actions)])
    (match act
      ;; 1. Train unit: `(train <unit-sym>)`
      [(list 'train unit-sym)
       (define ab-id (train-symbol->ability-id unit-sym))
       (define all-prod-tags (select-producer-tags-for-unit unit-sym self-units))
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
         ;; Bug #17 fix: if producer is a WarpGate (133), issue WARP_IN_* at a verified Pylon power point
         (cond
           [(and prod-u (= (sc2-unit-unit-type prod-u) 133))
            (when (and (sc2-observation? obs) (> (sc2-observation-game-loop obs) 0))
              (set-box! SC2-WARPGATE-LAST-LOOP (sc2-observation-game-loop obs))
              (hash-set! SC2-WARPGATE-COOLDOWN-UNTIL ptag (+ (sc2-observation-game-loop obs) 515)))
            (define warp-ab (or (unit-symbol->warp-in-ability-id unit-sym) ab-id))
            (define-values (px py) (pylon-power-anchor))
            (define warp-pt
              (find-verified-building-placement ws-conn warp-ab px py units
                                                #:min-spacing 1.5
                                                #:max-radius 6.0
                                                #:step 1.5
                                                #:extra-reserved-points step-reserved-build-pts
                                                #:anchor-points (pylon-power-anchors px py)))
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
           ;; Morph-in-place townhall/spire upgrades (Lair, Hive, Greater Spire, Orbital, Planetary)
           [(memq norm '(lair hive greater-spire orbital-command planetary-fortress lurker-den lurker-den-mp))
            (define src-types
              (case norm
                [(lair) '(hatchery)]
                [(hive) '(lair)]
                [(greater-spire) '(spire)]
                [(orbital-command planetary-fortress) '(command-center)]
                [(lurker-den lurker-den-mp) '(hydralisk-den)]
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
                                                #:min-spacing 2.5
                                                #:max-radius 6.5
                                                #:step 1.5
                                                #:extra-reserved-points step-reserved-build-pts
                                                #:anchor-points (pylon-power-anchors req-x req-y)))
            (reserve-step-build-pt! place-pt ab-id)
            (define wtag (pick-worker-near (sc2-point2d-x place-pt) (sc2-point2d-y place-pt)))
            (when wtag
              (emit! (sc2-raw-unit-command ab-id place-pt 0 (list wtag) #f)))]

           ;; Zerg structures requiring Creep
           [(memq norm '(spawning-pool evolution-chamber roach-warren baneling-nest
                         hydralisk-den lurker-den-mp spire infestation-pit ultralisk-cavern
                         nydus-network spine-crawler spore-crawler))
            (define creep-anchors
              (filter (lambda (u)
                        (and (memq (sc2-id->unit-symbol (sc2-unit-unit-type u))
                                   '(hatchery lair hive creep-tumor-burrowed))
                             (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)))
                      self-units))
            (define-values (cx cy)
              (if (not (null? creep-anchors))
                  (let ([cp (sc2-unit-pos
                             (argmin (lambda (u)
                                       (define p (sc2-unit-pos u))
                                       (pt-dist req-x req-y (sc2-point3d-x p) (sc2-point3d-y p)))
                                     creep-anchors))])
                    (values (sc2-point3d-x cp) (sc2-point3d-y cp)))
                  (values req-x req-y)))
            (define place-pt
              (find-verified-building-placement ws-conn ab-id cx cy units
                                                #:min-spacing 3.0
                                                #:max-radius 7.5
                                                #:step 1.5
                                                #:extra-reserved-points step-reserved-build-pts))
            (reserve-step-build-pt! place-pt ab-id)
            (define wtag (pick-worker-near (sc2-point2d-x place-pt) (sc2-point2d-y place-pt)))
            (when wtag
              (emit! (sc2-raw-unit-command ab-id place-pt 0 (list wtag) #f)))]

           ;; Standard ground building placement (Pylons, Supply Depots, Barracks, Factories, Starports, etc.)
           [else
            (define place-pt
              (find-verified-building-placement ws-conn ab-id req-x req-y units
                                                #:min-spacing 3.0
                                                #:max-radius 14.0
                                                #:step 2.0
                                                #:extra-reserved-points step-reserved-build-pts))
            (reserve-step-build-pt! place-pt ab-id)
            (define wtag (pick-worker-near (sc2-point2d-x place-pt) (sc2-point2d-y place-pt)))
            (when wtag
              (emit! (sc2-raw-unit-command ab-id place-pt 0 (list wtag) #f)))]))]

      ;; 3. Expand: `(expand <x> <y>)` or `(expand <th-sym> <x> <y>)`
      [(or (list 'expand _ _)
           (list 'expand _ _ _))
       (define th-ab
         (cond
           [(ormap (lambda (u) (memq (sc2-id->unit-symbol (sc2-unit-unit-type u)) '(hatchery lair hive drone))) self-units)
            1152] ;; ZERGBUILD_HATCHERY
           [(ormap (lambda (u) (memq (sc2-id->unit-symbol (sc2-unit-unit-type u)) '(command-center orbital-command scv))) self-units)
            318]  ;; TERRANBUILD_COMMANDCENTER
           [else
            880])) ;; PROTOSSBUILD_NEXUS
       (define exp-pt (find-best-expansion-placement ws-conn th-ab home-x home-y units))
       (reserve-step-build-pt! exp-pt th-ab)
       (define wtag (pick-worker-near (sc2-point2d-x exp-pt) (sc2-point2d-y exp-pt)))
       (when wtag
         (emit! (sc2-raw-unit-command th-ab exp-pt 0 (list wtag) #f)))]

      ;; 4. Research upgrade: `(research <upg-sym>)`
      [(list 'research upg-sym)
       (define ab-id (research-symbol->ability-id upg-sym))
       (define rtag (select-researcher-tag upg-sym self-units))
       (when (and ab-id rtag (not (set-member? used-producer-tags rtag)))
         (set-add! used-producer-tags rtag)
         (hash-set! used-producer-counts rtag (add1 (hash-ref used-producer-counts rtag 0)))
         (emit! (sc2-raw-unit-command ab-id #f 0 (list rtag) #f)))]

      ;; 5. Morph unit/structure: `(morph <unit-id> <target-sym>)` or `(morph <target-sym>)`
      [(list 'morph uid target-sym)
       (define ab-id (morph-symbol->ability-id target-sym))
       (when (and ab-id (exact-integer? uid) (> uid 0) (not (set-member? used-producer-tags uid)))
         (set-add! used-producer-tags uid)
         (hash-set! used-producer-counts uid (add1 (hash-ref used-producer-counts uid 0)))
         (emit! (sc2-raw-unit-command ab-id #f 0 (list uid) #f)))]
      [(list 'morph target-sym)
       (define ab-id (morph-symbol->ability-id target-sym))
       (define ptags
         (filter (lambda (t) (not (set-member? used-producer-tags t)))
                 (select-producer-tags-for-unit target-sym self-units)))
       (when (and ab-id (not (null? ptags)))
         (define ptag (first ptags))
         (set-add! used-producer-tags ptag)
         (hash-set! used-producer-counts ptag (add1 (hash-ref used-producer-counts ptag 0)))
         (emit! (sc2-raw-unit-command ab-id #f 0 (list ptag) #f)))]

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
       (define tag-list (claim-combat-tags-for-order! uid 23 #f target-id))
       (when (not (null? tag-list))
         (emit! (sc2-raw-unit-command 23 #f target-id tag-list #f)))]

      [(list (or 'move 'kite 'retreat 'mineral-walk 'worker-harass 'multi-prong-drop) uid raw-x raw-y)
       (define tx (scale-bot-coord-to-world raw-x home-x))
       (define ty (scale-bot-coord-to-world raw-y home-y))
       (define target-pt (sc2-point2d tx ty))
       (define tag-list (claim-combat-tags-for-order! uid 16 target-pt 0))
       (when (not (null? tag-list))
         (emit! (sc2-raw-unit-command 16 target-pt 0 tag-list #f)))]

      [(list 'hold-position uid _ ...)
       (define tag-list (claim-combat-tags-for-order! uid 18 #f 0))
       (when (not (null? tag-list))
         (emit! (sc2-raw-unit-command 18 #f 0 tag-list #f)))]

      [(list 'cancel uid)
       #:when (exact-integer? uid)
       (emit! (sc2-raw-unit-command 314 #f 0 (list uid) #f))]

      ;; 7. Queen Inject Larva: `(inject-larva <queen-id> <hatch-id>)`
      [(list 'inject-larva queen-id hatch-id)
       (set-add! commanded-combat-tags queen-id)
       (unless (unit-has-protected-queen-order? queen-id)
         (emit! (sc2-raw-unit-command 251 #f hatch-id (list queen-id) #f)))]

      ;; 8. Spells: `(cast <caster-id> <spell-sym> ...)` or `(cast-spell <caster-id> <spell-sym> ...)`
      ;;    Enforces canonical SC2 ability target mode (Target.None / Target.Point / Target.Unit)
      ;;    and verifies creep tumor placement & MULE mineral patch targets (Bugs #14, #15, #19).
      [(list (or 'cast 'cast-spell) caster-id spell-sym rest ...)
       (define norm-spell (normalize-sc2-name->symbol spell-sym))
       (define caster-u (hash-ref self-unit-by-tag caster-id #f))
       (define caster-utype (if caster-u (sc2-unit-unit-type caster-u) 0))
       (define ab-id
         (cond
           [(memq norm-spell '(spread-creep-tumor spawn-creep-tumor))
            (if (and caster-u (memq (sc2-id->unit-symbol caster-utype)
                                    '(creep-tumor creep-tumor-burrowed creep-tumor-queen)))
                (begin
                  (when (set-mutable? used-tumors)
                    (set-add! used-tumors caster-id))
                  1733) ;; BUILD_CREEPTUMOR_TUMOR
                1694)]  ;; BUILD_CREEPTUMOR_QUEEN
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
         ;; Off-GCD instant self-buffs do NOT lock the unit out of attacking/kiting on the same frame
         (define off-gcd-buff?
           (memq norm-spell
                 '(stimpack stim stim-marine stim-marauder guardian-shield
                   cloak-banshee medivac-boost immortal-barrier prismatic-alignment)))
         (unless off-gcd-buff?
           (set-add! commanded-combat-tags caster-id))
         (cond
           ;; Case A: Ability requires NO target (Stimpack, Guardian Shield, Siege/Unsiege, Burrow, Cloak, etc.)
           [(set-member? SC2-NO-TARGET-ABILITY-IDS ab-id)
            (emit! (sc2-raw-unit-command ab-id #f 0 (list caster-id) #f))]

           ;; Case B: Creep Tumor placement (must be verified on Creep via QueryPlacement)
           [(or (= ab-id 1694) (= ab-id 1733))
            (unless (and (= ab-id 1694) (unit-has-protected-queen-order? caster-id))
              (define raw-x (if (>= (length rest) 2) (first rest) home-x))
              (define raw-y (if (>= (length rest) 2) (second rest) home-y))
              (define tx (scale-bot-coord-to-world raw-x home-x))
              (define ty (scale-bot-coord-to-world raw-y home-y))
              ;; For Queen Creep Tumor (1694), anchor within 3.5 tiles of the Queen's own position
              ;; toward (tx, ty) so placement is on the Hatchery's existing creep radius!
              (define-values (anchor-x anchor-y)
                (if (and (= ab-id 1694) caster-u)
                    (let* ([qp (sc2-unit-pos caster-u)]
                           [qx (sc2-point3d-x qp)]
                           [qy (sc2-point3d-y qp)]
                           [dx (- tx qx)]
                           [dy (- ty qy)]
                           [d (max 1.0 (sqrt (+ (sqr dx) (sqr dy))))]
                           [step-d (min d 3.5)])
                      (values (+ qx (* step-d (/ dx d)))
                              (+ qy (* step-d (/ dy d)))))
                    (values tx ty)))
              (define tumor-pt
                (find-verified-building-placement ws-conn ab-id anchor-x anchor-y units
                                                  #:min-spacing 1.5
                                                  #:max-radius 7.5
                                                  #:step 1.5
                                                  #:extra-reserved-points step-reserved-build-pts))
              (reserve-step-build-pt! tumor-pt ab-id)
              (emit! (sc2-raw-unit-command ab-id tumor-pt 0 (list caster-id) #f)))]

           ;; Case C: Orbital Command Calldown MULE (171) -> resolve to real mineral field tag
           [(= ab-id 171)
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
              (emit! (sc2-raw-unit-command ab-id #f resolved-min-tag (list caster-id) #f)))]

           ;; Case D: Point-target ability (Blink, Force Field, Psi Storm, Corrosive Bile, EMP, Scanner Sweep, Phase Shift)
           [(or (set-member? SC2-POINT-TARGET-ABILITY-IDS ab-id)
                (>= (length rest) 2))
            (define-values (tx ty)
              (cond
                [(>= (length rest) 2)
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
            (emit! (sc2-raw-unit-command ab-id (sc2-point2d tx ty) 0 (list caster-id) #f))]

           ;; Case E: Unit-target ability (Inject Larva, Chrono Boost, Transfusion, Feedback, Snipe, Yamato, Abduct, etc.)
           [else
            (unless (and (= ab-id 251) (unit-has-protected-queen-order? caster-id))
              (define target-id (if (pair? rest) (first rest) 0))
              (if (and (exact-integer? target-id) (> target-id 0))
                  (emit! (sc2-raw-unit-command ab-id #f target-id (list caster-id) #f))
                  (emit! (sc2-raw-unit-command ab-id #f 0 (list caster-id) #f))))]))]

      ;; 9. Anti-cheese & Pro-mechanics
      [(list 'pull-workers-attack worker-ids raw-x raw-y)
       (define tx (scale-bot-coord-to-world raw-x home-x))
       (define ty (scale-bot-coord-to-world raw-y home-y))
       (define wlist (if (list? worker-ids) worker-ids (list worker-ids)))
       (when (not (null? wlist))
         (for ([wt (in-list wlist)] #:when (exact-integer? wt))
           (record-worker-used! wt))
         (emit! (sc2-raw-unit-command 23 (sc2-point2d tx ty) 0 wlist #f)))]

      [(list 'resume-halted-building scv-id bldg-id)
       (record-worker-used! scv-id)
       (emit! (sc2-raw-unit-command 1 #f bldg-id (list scv-id) #f))]

      [(list 'clear-gas-steal enemy-gas-id raw-x raw-y)
       (define ctags (map sc2-unit-tag combat-units))
       (when (not (null? ctags))
         (if (and (exact-integer? enemy-gas-id) (> enemy-gas-id 0))
             (emit! (sc2-raw-unit-command 23 #f enemy-gas-id ctags #f))
             (emit! (sc2-raw-unit-command 23
                                          (sc2-point2d (scale-bot-coord-to-world raw-x home-x)
                                                       (scale-bot-coord-to-world raw-y home-y))
                                          0 ctags #f))))]

      [(list 'snipe-enemy-changeling changeling-id _ ...)
       (define ctags (map sc2-unit-tag (if (not (null? combat-units)) combat-units workers)))
       (when (and (not (null? ctags)) (exact-integer? changeling-id))
         (emit! (sc2-raw-unit-command 23 #f changeling-id (list (first ctags)) #f)))]

      ;; 10. Spatial maneuvers: `(execute-spatial-maneuver <name> <x> <y>)` or `(mirror-spatial-maneuver ...)`
      ;;     Bug #11 fix: never overwrite units that already received individual micro orders in this step,
      ;;     exclude Queens and units currently engaged in local combat within 16 tiles of an enemy,
      ;;     and prevent 1-by-1 reinforcement streaming ("conga line of death") by requiring units near
      ;;     home (`<= 48` tiles) to gather into a wave of `>= SC2-ATTACK-WAVE-MIN-COMBAT-UNITS` before
      ;;     marching across the map.
      [(list (or 'execute-spatial-maneuver 'mirror-spatial-maneuver) _ raw-x raw-y)
       (define tx (scale-bot-coord-to-world raw-x home-x))
       (define ty (scale-bot-coord-to-world raw-y home-y))
       (define target-pt (sc2-point2d tx ty))
       (define home-staged-count
         (count (lambda (u)
                  (define up (sc2-unit-pos u))
                  (<= (pt-dist home-x home-y (sc2-point3d-x up) (sc2-point3d-y up)) 48.0))
                combat-units))
       (define uncommanded-combat
         (filter (lambda (u)
                   (define up (sc2-unit-pos u))
                   (define near-home?
                     (<= (pt-dist home-x home-y (sc2-point3d-x up) (sc2-point3d-y up)) 48.0))
                   (and (not (set-member? commanded-combat-tags (sc2-unit-tag u)))
                        (not (eq? (sc2-id->unit-symbol (sc2-unit-unit-type u)) 'queen))
                        (or (not near-home?)
                            (>= home-staged-count SC2-ATTACK-WAVE-MIN-COMBAT-UNITS)
                            (null? townhalls))
                        (not (ormap (lambda (e)
                                      (define ep (sc2-unit-pos e))
                                      (<= (pt-dist (sc2-point3d-x up) (sc2-point3d-y up)
                                                   (sc2-point3d-x ep) (sc2-point3d-y ep))
                                          16.0))
                                    enemy-units))))
                 combat-units))
       (when (and (not (null? uncommanded-combat))
                  (or (>= (length combat-units) 14)
                      (null? townhalls)))
         (define ctags
           (claim-combat-tags-for-order! (map sc2-unit-tag uncommanded-combat) 23 target-pt 0))
         (when (not (null? ctags))
           (emit! (sc2-raw-unit-command 23 target-pt 0 ctags #f))))]

      ;; 11. Control Groups (`ActionUI.control_group`) & Camera Hotkeys / Saccades (`ActionRawCameraMove`)
      [(list 'control-group-set grp-idx _ ...)
       #:when (exact-integer? grp-idx)
       (emit! (sc2-ui-control-group SC2-CONTROL-GROUP-ACTION-SET grp-idx))]
      [(list 'control-group-append grp-idx _ ...)
       #:when (exact-integer? grp-idx)
       (emit! (sc2-ui-control-group SC2-CONTROL-GROUP-ACTION-APPEND grp-idx))]
      [(list 'control-group-steal grp-idx _ ...)
       #:when (exact-integer? grp-idx)
       (emit! (sc2-ui-control-group SC2-CONTROL-GROUP-ACTION-SET-AND-STEAL grp-idx))]
      [(list 'control-group-append-steal grp-idx _ ...)
       #:when (exact-integer? grp-idx)
       (emit! (sc2-ui-control-group SC2-CONTROL-GROUP-ACTION-APPEND-AND-STEAL grp-idx))]
      [(list 'control-group-recall grp-idx _ ...)
       #:when (exact-integer? grp-idx)
       (emit! (sc2-ui-control-group SC2-CONTROL-GROUP-ACTION-RECALL grp-idx))]

      [(list 'camera-focus _ raw-x raw-y)
       (emit-camera-move! raw-x raw-y)]
      [(list 'camera-focus raw-x raw-y)
       (emit-camera-move! raw-x raw-y)]
      [(list 'move-camera raw-x raw-y)
       (emit-camera-move! raw-x raw-y)]
      [(list 'camera-bookmark-jump _ raw-x raw-y)
       (emit-camera-move! raw-x raw-y)]

      [_ (void)]))

  ;; 12. Automatic Terran Supply Depot Lower / Raise & Base Defense Rally / Army Wave Attack-Move
  (for ([u (in-list self-units)]
        #:when (and (>= (sc2-unit-build-progress u) SC2-BUILD-COMPLETE-PROGRESS)
                    (null? (sc2-unit-orders u))))
    (define utype (sc2-unit-unit-type u))
    (when (or (= utype 19) (= utype 47)) ;; 19 = SupplyDepot (raised), 47 = SupplyDepotLowered
      (define dp (sc2-unit-pos u))
      (define enemy-ground-near?
        (ormap (lambda (e)
                 (and (not (sc2-unit-is-flying e))
                      (let ([ep (sc2-unit-pos e)])
                        (<= (pt-dist (sc2-point3d-x dp) (sc2-point3d-y dp)
                                     (sc2-point3d-x ep) (sc2-point3d-y ep))
                            SC2-DEPOT-RAISE-ENEMY-RADIUS))))
               enemy-units))
      (cond
        [(and (= utype 19) (not enemy-ground-near?))
         (emit! (sc2-raw-unit-command 556 #f 0 (list (sc2-unit-tag u)) #f))] ;; MORPH_SUPPLYDEPOT_LOWER
        [(and (= utype 47) enemy-ground-near?)
         (emit! (sc2-raw-unit-command 558 #f 0 (list (sc2-unit-tag u)) #f))]))) ;; MORPH_SUPPLYDEPOT_RAISE

  (define targetable-enemy-units
    (filter (lambda (e)
              (sc2-enemy-unit-targetable? (sc2-id->unit-symbol (sc2-unit-unit-type e))))
            enemy-units))
  (define idle-combat-units
    (filter (lambda (u)
              (and (null? (sc2-unit-orders u))
                   (not (set-member? commanded-combat-tags (sc2-unit-tag u)))
                   (not (eq? (sc2-id->unit-symbol (sc2-unit-unit-type u)) 'queen))))
            combat-units))
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
        [(and (list? enemy-base) (>= (length enemy-base) 2))
         (values (exact->inexact (first enemy-base))
                 (exact->inexact (second enemy-base)))]
        [else
         (values (- SC2-DEFAULT-MAP-WIDTH home-x)
                 (- SC2-DEFAULT-MAP-HEIGHT home-y))]))
    (define-values (stage-x stage-y)
      (let* ([dx (- att-x home-x)]
             [dy (- att-y home-y)]
             [d (max 1.0 (sqrt (+ (sqr dx) (sqr dy))))]
             [step-d (min 18.0 (* 0.25 d))])
        (values (+ home-x (* step-d (/ dx d)))
                (+ home-y (* step-d (/ dy d))))))
    (define home-staged-combat
      (filter (lambda (u)
                (define up (sc2-unit-pos u))
                (<= (pt-dist home-x home-y (sc2-point3d-x up) (sc2-point3d-y up)) 48.0))
              combat-units))
    (cond
      [base-threat
       (define ep (sc2-unit-pos base-threat))
       (emit! (sc2-raw-unit-command 23
                                    (sc2-point2d (sc2-point3d-x ep) (sc2-point3d-y ep))
                                    0 idle-tags #f))]
      [(and (>= (length combat-units) 14)
            (>= (length home-staged-combat) SC2-ATTACK-WAVE-MIN-COMBAT-UNITS))
       (emit! (sc2-raw-unit-command 23
                                    (sc2-point2d att-x att-y)
                                    0 idle-tags #f))]
      [(>= (length combat-units) 14)
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
       ;; Army < 14: rally idle units that spawned at main base (> 8 tiles from front stage) to our natural choke
       (define unplaced-home-tags
         (for/list ([u (in-list idle-combat-units)]
                    #:when (let ([up (sc2-unit-pos u)])
                             (and (<= (pt-dist home-x home-y (sc2-point3d-x up) (sc2-point3d-y up)) 48.0)
                                  (> (pt-dist stage-x stage-y (sc2-point3d-x up) (sc2-point3d-y up)) 8.0))))
           (sc2-unit-tag u)))
       (when (and (not (null? unplaced-home-tags)) (not (null? townhalls)))
         (emit! (sc2-raw-unit-command 23 (sc2-point2d stage-x stage-y) 0 unplaced-home-tags #f)))]))

  (reverse raw-cmds))
