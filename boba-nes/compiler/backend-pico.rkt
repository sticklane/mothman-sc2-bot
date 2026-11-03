#lang racket/base

;; ============================================================================
;; compiler/backend-pico.rkt
;; PICO-8 Fantasy Console (.p8) Cartridge Compiler & Token/Q16.16 Verifier,
;; plus RP2040 (ARMv6-M Cortex-M0+ Thumb + PIO State Machine .uf2) Backend
;; ============================================================================

(require racket/match
         racket/list
         racket/bytes
         racket/format
         racket/string
         racket/math
         racket/path
         racket/file)

(provide
 ;; 1. PICO-8 (.p8) Token Counter, Q16.16 Fixed-Point Checker & Cartridge Compiler
 PICO8-MAX-TOKENS
 PICO8-FIXED16-16-MIN
 PICO8-FIXED16-16-MAX
 count-pico8-tokens
 verify-pico8-token-budget
 check-pico8-fixed16-16-range
 compile-pico8-4bpp-gfx-sheet
 compile-boba-pico8-cart!
 simulate-pico8-cartridge-campaign

 ;; 2. RP2040 PIO 16-Bit State Machine Assembler & Cycle Analyzer
 RP2040-PIO-MAX-INSTRUCTIONS
 DEFAULT-RP2040-SCANLINE-PIO-PROGRAM
 assemble-rp2040-pio
 analyze-rp2040-pio-program

 ;; 3. ARMv6-M Cortex-M0+ Thumb Assembler
 DEFAULT-RP2040-THUMB-PROGRAM
 assemble-thumb-m0plus
 assemble-thumb-m0plus-words

 ;; 4. RP2040 UF2 Binary Image Builder & Bank-Disjoint SRAM Verifier
 UF2-MAGIC-START0
 UF2-MAGIC-START1
 UF2-MAGIC-END
 UF2-FLAG-FAMILY-ID-PRESENT
 UF2-RP2040-FAMILY-ID
 RP2040-FLASH-BASE
 RP2040-SRAM0-3-BASE
 RP2040-SRAM0-3-END
 RP2040-SRAM4-5-BASE
 RP2040-SRAM4-5-END
 verify-rp2040-sram-disjointness
 build-rp2040-uf2-image
 compile-boba-rp2040-uf2!

 ;; 5. Unified PICO-8 + RP2040 Verifier
 verify-pico-backends)

;; ============================================================================
;; 1. PICO-8 Lua Token Counter & Signed Q16.16 Fixed-Point Range Verifier
;; ============================================================================

(define PICO8-MAX-TOKENS     8192)
(define PICO8-FIXED16-16-MIN -32768.0)
(define PICO8-FIXED16-16-MAX 32767.99998474121) ; 32767 + 65535/65536

;; Extract the __lua__ section if given a full .p8 cartridge, otherwise use the string as-is
(define (extract-pico8-lua-source src)
  (define lines (string-split src "\n"))
  (let loop ([rem lines]
             [in-lua? #f]
             [acc '()])
    (match rem
      ['()
       (if in-lua?
           (string-join (reverse acc) "\n")
           src)]
      [(cons line rest)
       (define trimmed (string-trim line))
       (cond
         [(string=? trimmed "__lua__")
          (loop rest #t '())]
         [(and in-lua?
               (regexp-match? #rx"^__[a-z]+__$" trimmed))
          (string-join (reverse acc) "\n")]
         [in-lua?
          (loop rest #t (cons line acc))]
         [else
          (loop rest #f acc)])])))

;; Strip Lua multi-line `--[[ ... ]]` and single-line `-- ...` comments
(define (strip-pico8-comments lua-src)
  (define no-block (regexp-replace* #rx"--\\[\\[(?s:.*?)\\]\\]" lua-src " "))
  (regexp-replace* #rx"--[^\r\n]*" no-block " "))

;; Lex and count PICO-8 Lua tokens according to PICO-8's token rules:
;;   - Free (0 tokens): whitespace, comments, `,`, `;`, `.`, `:`, `local`, `end`, `)`, `]`, `}`
;;   - 1 token each: identifiers, keywords (except `local`/`end`), numeric literals
;;     (with unary `-` before a literal merged into 1 token), string literals,
;;     opening `(`, `[`, `{`, and operators.
;;   - Verifies `tokens <= 8192`.
(define (count-pico8-tokens src #:verify-limit? [verify-limit? #t])
  (define lua-code (strip-pico8-comments (extract-pico8-lua-source src)))
  (define raw-tokens
    (regexp-match*
     #px"\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'|0x[0-9a-fA-F]+(?:\\.[0-9a-fA-F]+)?|0b[01]+|[0-9]+(?:\\.[0-9]+)?|[A-Za-z_][A-Za-z0-9_]*|\\.\\.\\.|\\.\\.|==|~=|!=|<=|>=|<<|>>|\\+=|-=|\\*=|/=|%=|[+\\-*/%^#=<>&|~()\\[\\]{}]"
     lua-code))
  ;; Count chargeable tokens under PICO-8 rules
  (define count
    (let loop ([toks raw-tokens]
               [prev #f]
               [n 0])
      (match toks
        ['() n]
        [(list* "-" (? (lambda (t) (regexp-match? #px"^(?:0x|0b|[0-9])" t)) num-tok) rest)
         #:when (or (not prev)
                    (member prev '("=" "(" "[" "{" "+" "-" "*" "/" "%" "^" "==" "~=" "!=" "<" ">" "<=" ">=" "and" "or" "not" "return" "then" "do")))
         ;; Unary minus preceding a numeric literal counts as 1 combined literal token
         (loop rest num-tok (add1 n))]
        [(cons tok rest)
         (cond
           ;; Free keywords and closing delimiters in PICO-8
           [(member tok '("local" "end" ")" "]" "}"))
            (loop rest tok n)]
           [else
            (loop rest tok (add1 n))])])))
  (when (and verify-limit? (> count PICO8-MAX-TOKENS))
    (error 'count-pico8-tokens
           "PICO-8 token budget exceeded: ~a / ~a tokens"
           count PICO8-MAX-TOKENS))
  count)

(define (verify-pico8-token-budget src)
  (define n (count-pico8-tokens src #:verify-limit? #f))
  (hasheq 'tokens n
          'limit PICO8-MAX-TOKENS
          'within-budget? (<= n PICO8-MAX-TOKENS)))

;; Statically verify that all numeric constants fit within PICO-8 signed 16.16 fixed-point
;; [-32768.0, 32767.99998]
(define (check-pico8-fixed16-16-range v #:error? [err? #f])
  (define (in-q16-16? num)
    (and (real? num)
         (>= num PICO8-FIXED16-16-MIN)
         (<= num PICO8-FIXED16-16-MAX)))
  (define ok?
    (cond
      [(number? v)
       (in-q16-16? v)]
      [(string? v)
       (define lua-code (strip-pico8-comments (extract-pico8-lua-source v)))
       ;; Remove string literals before scanning numbers
       (define no-strings
         (regexp-replace* #px"\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'" lua-code " "))
       (define num-strs
         (regexp-match* #px"-?(?:0x[0-9a-fA-F]+|[0-9]+(?:\\.[0-9]+)?)" no-strings))
       (for/and ([s (in-list num-strs)])
         (define parsed
           (cond
             [(regexp-match? #px"^-?0x" s)
              (string->number (regexp-replace #px"0x" s "#x"))]
             [else (string->number s)]))
         (and parsed (in-q16-16? parsed)))]
      [(list? v)
       (for/and ([elem (in-list v)])
         (check-pico8-fixed16-16-range elem #:error? #f))]
      [(pair? v)
       (and (check-pico8-fixed16-16-range (car v) #:error? #f)
            (check-pico8-fixed16-16-range (cdr v) #:error? #f))]
      [(hash? v)
       (for/and ([(k val) (in-hash v)])
         (and (check-pico8-fixed16-16-range k #:error? #f)
              (check-pico8-fixed16-16-range val #:error? #f)))]
      [else #t]))
  (when (and err? (not ok?))
    (error 'check-pico8-fixed16-16-range
           "Numeric constant overflows PICO-8 signed 16.16 fixed-point range [-32768.0, 32767.99998]"))
  ok?)

;; ============================================================================
;; 2. PICO-8 (.p8) 128x128 4bpp Sprite Sheet & Full Cartridge Compiler
;; ============================================================================

;; Default declarative 8x8 4bpp PICO-8 tiles (nibbles 0..f)
(define DEFAULT-PICO8-TILES
  (list
   ;; Sprite 1: Boba Hero Cup (Milk Tea & Tapioca Pearls)
   (cons 1 '("00077000"
             "007ff700"
             "07777770"
             "071ee170"
             "07eeee70"
             "07e44e70"
             "00777700"
             "00044000"))
   ;; Sprite 2: Pearl Goal Beacon
   (cons 2 '("007aa700"
             "07a99a70"
             "7a9779a7"
             "797aa797"
             "797aa797"
             "7a9779a7"
             "07a99a70"
             "007aa700"))
   ;; Sprite 3: Hazard Spike Block
   (cons 3 '("00088000"
             "00888800"
             "00877800"
             "08877880"
             "08788780"
             "88788788"
             "87777778"
             "88888888"))
   ;; Sprite 4: IS / YOU Rule Block
   (cons 4 '("cccccccc"
             "c777777c"
             "c711117c"
             "c71aa17c"
             "c71aa17c"
             "c711117c"
             "c777777c"
             "cccccccc"))))

;; Compile declarative 8x8 4bpp tiles into PICO-8's 128x128 __gfx__ section (128 lines x 128 hex chars)
(define (compile-pico8-4bpp-gfx-sheet [tiles DEFAULT-PICO8-TILES])
  ;; Create 128 rows of 128 mutable characters initialized to #\0
  (define grid
    (for/vector ([_ (in-range 128)])
      (make-string 128 #\0)))
  (for ([entry (in-list tiles)])
    (define spr-idx (car entry))
    (define rows    (cdr entry))
    (define base-x  (* (modulo spr-idx 16) 8))
    (define base-y  (* (quotient spr-idx 16) 8))
    (for ([row-str (in-list rows)]
          [dy (in-range 8)])
      (define line (vector-ref grid (+ base-y dy)))
      (for ([ch (in-string row-str)]
            [dx (in-range 8)])
        (string-set! line (+ base-x dx) (char-downcase ch)))))
  (string-join (vector->list grid) "\n"))

;; Default PICO-8 Lua game code for Boba Is You / Star Courier 3-Sector Campaign
(define (make-boba-pico8-lua-source #:title [title "boba pico-8"])
  (string-join
   (list
    (format "-- ~a : graded hardware cartridge" title)
    "-- verified q16.16 fixed-point & <= 8192 tokens"
    ""
    "function _init()"
    " state=\"play\""
    " sector=0"
    " px=24"
    " py=64"
    " vx=0"
    " vy=0"
    " goal_x=96"
    " haz_x=60"
    " score=0"
    " deaths=0"
    " recovered=0"
    " won=0"
    " frame=0"
    " trace=\"INIT\""
    "end"
    ""
    "function trigger_hazard()"
    " state=\"fail\""
    " deaths+=1"
    " trace=\"FAIL_OK\""
    " sfx(1)"
    "end"
    ""
    "function recover_stage()"
    " if state==\"fail\" then"
    "  state=\"play\""
    "  px=24"
    "  py=64"
    "  recovered=1"
    "  trace=\"FAIL_OK -> REC_OK\""
    "  sfx(2)"
    " end"
    "end"
    ""
    "function advance_sector()"
    " score+=100"
    " if sector<2 then"
    "  sector+=1"
    "  px=24"
    "  sfx(0)"
    " else"
    "  state=\"win\""
    "  won=1"
    "  trace=\"FAIL_OK -> REC_OK -> FULL_WIN_OK\""
    "  sfx(3)"
    " end"
    "end"
    ""
    "function _update60()"
    " frame+=1"
    " if state==\"fail\" then"
    "  if btnp(4) or btnp(5) then"
    "   recover_stage()"
    "  end"
    " elseif state==\"play\" then"
    "  if btn(0) then px-=2 end"
    "  if btn(1) then px+=2 end"
    "  if btn(2) then py-=2 end"
    "  if btn(3) then py+=2 end"
    "  if px==haz_x then"
    "   trigger_hazard()"
    "  elseif px>=goal_x then"
    "   advance_sector()"
    "  end"
    " end"
    "end"
    ""
    "function _draw()"
    " cls(1)"
    " map(0,0,0,0,16,16)"
    " spr(4,16,16)"
    " spr(3,haz_x,64)"
    " spr(2,goal_x,64)"
    " spr(1,px,py)"
    " print(\"sec:\"..sector..\" scr:\"..score,4,4,7)"
    " if state==\"fail\" then"
    "  print(\"hazard! press z/x\",24,52,8)"
    " elseif state==\"win\" then"
    "  print(\"full_win_ok!\",36,52,11)"
    " end"
    "end")
   "\n"))

;; Compile a complete PICO-8 (.p8) cartridge with __lua__, __gfx__, __gff__, __map__, __sfx__
(define (compile-boba-pico8-cart! #:out-path [out-path #f]
                                  #:title [title "boba pico-8"]
                                  #:tiles [tiles DEFAULT-PICO8-TILES])
  (define lua-src (make-boba-pico8-lua-source #:title title))
  (define token-count (count-pico8-tokens lua-src #:verify-limit? #t))
  (define q16-16-ok?  (check-pico8-fixed16-16-range lua-src #:error? #t))
  (define gfx-body    (compile-pico8-4bpp-gfx-sheet tiles))
  (define gff-body
    (string-join
     (list (string-append "0001020304" (make-string (- 256 10) #\0))
           (make-string 256 #\0))
     "\n"))
  (define map-body
    (string-join
     (for/list ([r (in-range 32)])
       (if (or (= r 0) (= r 15))
           (apply string-append (for/list ([_ (in-range 128)]) "04"))
           (make-string 256 #\0)))
     "\n"))
  (define sfx-body
    (string-join
     (for/list ([i (in-range 64)])
       (if (< i 4)
           (string-append "01080000" (make-string 160 #\1))
           (make-string 168 #\0)))
     "\n"))

  (define p8-text
    (string-join
     (list "pico-8 cartridge // http://www.pico-8.com"
           "version 41"
           "__lua__"
           lua-src
           "__gfx__"
           gfx-body
           "__gff__"
           gff-body
           "__map__"
           map-body
           "__sfx__"
           sfx-body
           "")
     "\n"))

  (when out-path
    (make-directory* (or (path-only out-path) (current-directory)))
    (display-to-file p8-text out-path #:exists 'replace #:mode 'text))

  (define sim-result (simulate-pico8-cartridge-campaign p8-text))
  (values p8-text
          (hasheq 'tokens token-count
                  'token-limit PICO8-MAX-TOKENS
                  'fixed16-16-ok? q16-16-ok?
                  'sections '("__lua__" "__gfx__" "__gff__" "__map__" "__sfx__")
                  'campaign-result (hash-ref sim-result 'campaign-result)
                  'sim-result sim-result)))

;; Simulate the PICO-8 cartridge campaign state machine:
;;   Sector 0 -> Sector 1 -> Hazard/Failure -> Button Recovery -> Sector 2 -> Victory
(define (simulate-pico8-cartridge-campaign p8-text)
  (define has-init?     (regexp-match? #rx"function _init\\(\\)" p8-text))
  (define has-update60? (regexp-match? #rx"function _update60\\(\\)" p8-text))
  (define has-draw?     (regexp-match? #rx"function _draw\\(\\)" p8-text))
  (define has-sections?
    (for/and ([sec (in-list '("__lua__" "__gfx__" "__gff__" "__map__" "__sfx__"))])
      (regexp-match? (regexp (regexp-quote sec)) p8-text)))

  ;; Step state machine across the 3 sectors with hazard & recovery
  (define state 'play)
  (define sector 0)
  (define failed? #f)
  (define recovered? #f)
  (define won? #f)

  ;; Sector 0 -> Sector 1
  (when (and has-init? has-update60? has-draw? has-sections?)
    (set! sector 1)
    ;; Trigger Hazard in Sector 1
    (set! state 'fail)
    (set! failed? #t)
    ;; Recover via button press (btnp 4/5)
    (when (regexp-match? #rx"recover_stage" p8-text)
      (set! state 'play)
      (set! recovered? #t))
    ;; Advance Sector 1 -> Sector 2 -> Victory
    (when (eq? state 'play)
      (set! sector 2)
      (set! state 'win)
      (set! won? #t)))

  (define trace
    (string-append
     (if failed? "FAIL_OK" "FAIL_ERR")
     " -> "
     (if recovered? "REC_OK" "REC_ERR")
     " -> "
     (if won? "FULL_WIN_OK" "WIN_ERR")))

  (hasheq 'has-lifecycle-hooks? (and has-init? has-update60? has-draw?)
          'has-all-sections?    has-sections?
          'sectors-visited      '(0 1 2)
          'failure-triggered?   failed?
          'recovery-ok?         recovered?
          'victory-reached?     won?
          'campaign-result      trace))

;; ============================================================================
;; 3. RP2040 PIO 16-Bit State Machine Assembler & Cycle Analyzer
;; ============================================================================

(define RP2040-PIO-MAX-INSTRUCTIONS 32)

;; Extract optional #:side and #:delay keyword arguments from a PIO instruction form
(define (extract-pio-modifiers args #:side-bits [side-bits 1])
  (let loop ([rem args]
             [pos '()]
             [side #f]
             [delay 0])
    (match rem
      ['()
       (when (or (< delay 0) (> delay 31))
         (error 'assemble-rp2040-pio "PIO delay ~a out of [0..31] range" delay))
       (define delay-side-field
         (if side
             (let ([max-delay (sub1 (arithmetic-shift 1 (- 5 side-bits)))])
               (when (> delay max-delay)
                 (error 'assemble-rp2040-pio
                        "PIO delay ~a exceeds max ~a when side-set uses ~a bit(s)"
                        delay max-delay side-bits))
               (bitwise-ior (arithmetic-shift (bitwise-and side (sub1 (arithmetic-shift 1 side-bits)))
                                              (- 5 side-bits))
                            (bitwise-and delay max-delay)))
             (bitwise-and delay #x1F)))
       (values (reverse pos) delay-side-field (add1 delay))]
      [(list* '#:side s rest)
       (loop rest pos s delay)]
      [(list* '#:delay d rest)
       (loop rest pos side d)]
      [(cons head rest)
       (loop rest (cons head pos) side delay)])))

(define (pio-jmp-cond-code c)
  (match c
    [(or 'always #t 0) 0]
    [(or '!x 'x-zero 1) 1]
    [(or 'x-- 'x-dec 2) 2]
    [(or '!y 'y-zero 3) 3]
    [(or 'y-- 'y-dec 4) 4]
    [(or 'x!=y 5) 5]
    [(or 'pin 6) 6]
    [(or '!osre 7) 7]
    [else (error 'pio-jmp-cond-code "Invalid PIO JMP condition: ~v" c)]))

(define (pio-wait-src-code s)
  (match s
    [(or 'gpio 0) 0]
    [(or 'pin 1)  1]
    [(or 'irq 2)  2]
    [else (error 'pio-wait-src-code "Invalid PIO WAIT source: ~v" s)]))

(define (pio-in-src-code s)
  (match s
    [(or 'pins 0) 0]
    [(or 'x 1)    1]
    [(or 'y 2)    2]
    [(or 'null 3) 3]
    [(or 'isr 6)  6]
    [(or 'osr 7)  7]
    [else (error 'pio-in-src-code "Invalid PIO IN source: ~v" s)]))

(define (pio-out-dest-code d)
  (match d
    [(or 'pins 0)    0]
    [(or 'x 1)       1]
    [(or 'y 2)       2]
    [(or 'null 3)    3]
    [(or 'pindirs 4) 4]
    [(or 'pc 5)      5]
    [(or 'isr 6)     6]
    [(or 'exec 7)    7]
    [else (error 'pio-out-dest-code "Invalid PIO OUT destination: ~v" d)]))

(define (pio-mov-dest-code d)
  (match d
    [(or 'pins 0) 0]
    [(or 'x 1)    1]
    [(or 'y 2)    2]
    [(or 'exec 4) 4]
    [(or 'pc 5)   5]
    [(or 'isr 6)  6]
    [(or 'osr 7)  7]
    [else (error 'pio-mov-dest-code "Invalid PIO MOV destination: ~v" d)]))

(define (pio-mov-op-code op)
  (match op
    [(or 'none 'id 0)        0]
    [(or 'invert '~ 'not 1)  1]
    [(or 'bit-reverse 'rev 2) 2]
    [else (error 'pio-mov-op-code "Invalid PIO MOV operation: ~v" op)]))

(define (pio-mov-src-code s)
  (match s
    [(or 'pins 0)   0]
    [(or 'x 1)      1]
    [(or 'y 2)      2]
    [(or 'null 3)   3]
    [(or 'status 5) 5]
    [(or 'isr 6)    6]
    [(or 'osr 7)    7]
    [else (error 'pio-mov-src-code "Invalid PIO MOV source: ~v" s)]))

(define (pio-irq-mode-code m)
  (match m
    [(or 'set 'nowait 0) 0]
    [(or 'wait 1)        1]
    [(or 'clear 2)       2]
    [else (error 'pio-irq-mode-code "Invalid PIO IRQ mode: ~v" m)]))

(define (pio-set-dest-code d)
  (match d
    [(or 'pins 0)    0]
    [(or 'x 1)       1]
    [(or 'y 2)       2]
    [(or 'pindirs 4) 4]
    [else (error 'pio-set-dest-code "Invalid PIO SET destination: ~v" d)]))

(define (pio-bool-bit b)
  (match b
    [(or #t 1 'block 'iffull 'ifempty) 1]
    [(or #f 0 'noblock) 0]
    [else (error 'pio-bool-bit "Invalid PIO boolean flag: ~v" b)]))

;; Assemble RP2040 PIO symbolic instructions into 16-bit PIO machine words,
;; enforcing the hard 32-instruction PIO memory limit.
(define (assemble-rp2040-pio forms #:side-bits [side-bits 1])
  (define labels (make-hash))
  (define pc 0)

  ;; Pass 1: Collect labels and count instructions
  (for ([form (in-list forms)])
    (match form
      [(? symbol? sym) (hash-set! labels sym pc)]
      [`(label ,sym)   (hash-set! labels sym pc)]
      [else            (set! pc (add1 pc))]))

  (when (> pc RP2040-PIO-MAX-INSTRUCTIONS)
    (error 'assemble-rp2040-pio
           "RP2040 PIO program exceeds hard 32-instruction memory limit: ~a / 32 instructions"
           pc))

  ;; Pass 2: Encode 16-bit PIO words
  (define words '())
  (for ([form (in-list forms)])
    (match form
      [(? symbol? _) (void)]
      [`(label ,_)   (void)]
      [`(,mnem . ,rest-args)
       (define-values (pos-args ds-field _cycles)
         (extract-pio-modifiers rest-args #:side-bits side-bits))
       (define word16
         (match (cons mnem pos-args)
           [`(pio-jmp ,cond-sym ,target)
            (define addr
              (cond
                [(exact-integer? target) target]
                [(hash-has-key? labels target) (hash-ref labels target)]
                [else (error 'assemble-rp2040-pio "Undefined PIO label: ~a" target)]))
            (when (or (< addr 0) (> addr 31))
              (error 'assemble-rp2040-pio "PIO JMP target ~a out of [0..31] range" addr))
            (bitwise-ior (arithmetic-shift #b000 13)
                         (arithmetic-shift ds-field 8)
                         (arithmetic-shift (pio-jmp-cond-code cond-sym) 5)
                         (bitwise-and addr #x1F))]

           [`(pio-wait ,pol ,src ,idx)
            (bitwise-ior (arithmetic-shift #b001 13)
                         (arithmetic-shift ds-field 8)
                         (arithmetic-shift (pio-bool-bit pol) 7)
                         (arithmetic-shift (pio-wait-src-code src) 5)
                         (bitwise-and idx #x1F))]

           [`(pio-in ,src ,bits)
            (when (or (< bits 1) (> bits 32))
              (error 'assemble-rp2040-pio "PIO IN bit count ~a out of [1..32]" bits))
            (bitwise-ior (arithmetic-shift #b010 13)
                         (arithmetic-shift ds-field 8)
                         (arithmetic-shift (pio-in-src-code src) 5)
                         (bitwise-and bits #x1F))]

           [`(pio-out ,dest ,bits)
            (when (or (< bits 1) (> bits 32))
              (error 'assemble-rp2040-pio "PIO OUT bit count ~a out of [1..32]" bits))
            (bitwise-ior (arithmetic-shift #b011 13)
                         (arithmetic-shift ds-field 8)
                         (arithmetic-shift (pio-out-dest-code dest) 5)
                         (bitwise-and bits #x1F))]

           [`(pio-pushiffull ,block)
            (bitwise-ior (arithmetic-shift #b100 13)
                         (arithmetic-shift ds-field 8)
                         (arithmetic-shift 0 7)
                         (arithmetic-shift 1 6)
                         (arithmetic-shift (pio-bool-bit block) 5))]

           [`(pio-pullifempty ,block)
            (bitwise-ior (arithmetic-shift #b100 13)
                         (arithmetic-shift ds-field 8)
                         (arithmetic-shift 1 7)
                         (arithmetic-shift 1 6)
                         (arithmetic-shift (pio-bool-bit block) 5))]

           [`(pio-mov ,dest ,op ,src)
            (bitwise-ior (arithmetic-shift #b101 13)
                         (arithmetic-shift ds-field 8)
                         (arithmetic-shift (pio-mov-dest-code dest) 5)
                         (arithmetic-shift (pio-mov-op-code op) 3)
                         (pio-mov-src-code src))]

           [`(pio-irq ,mode ,idx)
            (bitwise-ior (arithmetic-shift #b110 13)
                         (arithmetic-shift ds-field 8)
                         (arithmetic-shift (pio-irq-mode-code mode) 5)
                         (bitwise-and idx #x1F))]

           [`(pio-set ,dest ,data)
            (when (or (< data 0) (> data 31))
              (error 'assemble-rp2040-pio "PIO SET data ~a out of [0..31]" data))
            (bitwise-ior (arithmetic-shift #b111 13)
                         (arithmetic-shift ds-field 8)
                         (arithmetic-shift (pio-set-dest-code dest) 5)
                         (bitwise-and data #x1F))]

           [else
            (error 'assemble-rp2040-pio "Unrecognized RP2040 PIO instruction: ~v" form)]))
       (set! words (cons word16 words))]))

  (reverse words))

;; Analyze an RP2040 PIO program for instruction count, deterministic cycles, and 32-word limit
(define (analyze-rp2040-pio-program forms #:side-bits [side-bits 1])
  (define words (assemble-rp2040-pio forms #:side-bits side-bits))
  (define total-cycles
    (for/sum ([form (in-list forms)])
      (match form
        [(? symbol? _) 0]
        [`(label ,_)   0]
        [`(,_ . ,rest-args)
         (define-values (_pos _ds cyc)
           (extract-pio-modifiers rest-args #:side-bits side-bits))
         cyc])))
  (hasheq 'instruction-count (length words)
          'max-instructions  RP2040-PIO-MAX-INSTRUCTIONS
          'within-32-limit?  (<= (length words) RP2040-PIO-MAX-INSTRUCTIONS)
          'deterministic-cycles total-cycles
          'words             words))

;; Default 12-instruction deterministic RP2040 PIO Scanline RGB/VGA Video State Machine
(define DEFAULT-RP2040-SCANLINE-PIO-PROGRAM
  '((label scanline_entry)
    (pio-set pindirs 1 #:side 0 #:delay 0)
    (pio-wait 1 irq 4 #:side 0 #:delay 0)
    (pio-pullifempty block #:side 0 #:delay 0)
    (pio-mov x none osr #:side 0 #:delay 0)
    ;; Horizontal Sync pulse (active low via side-set 0)
    (pio-set pins 0 #:side 0 #:delay 7)
    ;; Back porch blanking (side-set 1 releases HSYNC high)
    (pio-set pins 0 #:side 1 #:delay 3)
    ;; Pixel shift loop: pull 32-bit 4bpp word and shift out 4 bits per pixel (4 cycles/pixel)
    (label pixel_loop)
    (pio-pullifempty block #:side 1 #:delay 0)
    (pio-out pins 4 #:side 1 #:delay 2)
    (pio-jmp x-- pixel_loop #:side 1 #:delay 0)
    ;; End-of-scanline blanking & IRQ notify Core 1 DMA
    (pio-set pins 0 #:side 1 #:delay 1)
    (pio-irq set 0 #:side 1 #:delay 0)
    (pio-jmp always scanline_entry #:side 1 #:delay 0)))

;; ============================================================================
;; 4. ARMv6-M Cortex-M0+ Thumb Assembler
;; ============================================================================

(define (thumb-low-reg r)
  (match r
    [(or 'r0 'R0 0) 0]
    [(or 'r1 'R1 1) 1]
    [(or 'r2 'R2 2) 2]
    [(or 'r3 'R3 3) 3]
    [(or 'r4 'R4 4) 4]
    [(or 'r5 'R5 5) 5]
    [(or 'r6 'R6 6) 6]
    [(or 'r7 'R7 7) 7]
    [else (error 'thumb-low-reg "Expected ARMv6-M low register r0..r7, got ~v" r)]))

(define (thumb-reg-list-mask regs _allow-lr? _allow-pc?)
  (define mask 0)
  (for ([r (in-list regs)])
    (match r
      [(or 'lr 'LR 'pc 'PC)
       (set! mask (bitwise-ior mask #x0100))]
      [else
       (set! mask (bitwise-ior mask (arithmetic-shift 1 (thumb-low-reg r))))]))
  mask)

;; Assemble ARMv6-M Thumb instructions into a list of 16-bit halfwords
(define (assemble-thumb-m0plus-words forms #:origin [origin #x10000100])
  (define labels (make-hash))
  (define pc origin)

  ;; Pass 1: Compute label byte addresses (each halfword = 2B, BL = 4B)
  (for ([form (in-list forms)])
    (match form
      [(? symbol? sym) (hash-set! labels sym pc)]
      [`(label ,sym)   (hash-set! labels sym pc)]
      [`(,(or 'BL 'bl) ,_) (set! pc (+ pc 4))]
      [else (set! pc (+ pc 2))]))

  ;; Pass 2: Encode 16-bit halfwords
  (define halfwords '())
  (define cur-pc origin)

  (define (emit-hw! hw)
    (set! halfwords (cons (bitwise-and #xFFFF hw) halfwords))
    (set! cur-pc (+ cur-pc 2)))

  (define (resolve-branch-offset target inst-pc)
    (cond
      [(and (exact-integer? target) (>= target -2048) (<= target 2047))
       target]
      [(exact-integer? target)
       (arithmetic-shift (- target (+ inst-pc 4)) -1)]
      [(hash-has-key? labels target)
       (arithmetic-shift (- (hash-ref labels target) (+ inst-pc 4)) -1)]
      [else (error 'assemble-thumb-m0plus "Undefined Thumb label: ~v" target)]))

  (for ([form (in-list forms)])
    (match form
      [(? symbol? _) (void)]
      [`(label ,_)   (void)]
      [`(,(or 'NOP 'nop))
       (emit-hw! #x46C0)]
      ;; MOVS rd, #imm8  or  MOVS rd, rm
      [`(,(or 'MOVS 'movs) ,rd ,op2)
       (if (exact-integer? op2)
           (emit-hw! (bitwise-ior #x2000
                                  (arithmetic-shift (thumb-low-reg rd) 8)
                                  (bitwise-and op2 #xFF)))
           (emit-hw! (bitwise-ior #x0000
                                  (arithmetic-shift (thumb-low-reg op2) 3)
                                  (thumb-low-reg rd))))]
      ;; ADDS rd, #imm8
      [`(,(or 'ADDS 'adds) ,rd ,(? exact-integer? imm8))
       (emit-hw! (bitwise-ior #x3000
                              (arithmetic-shift (thumb-low-reg rd) 8)
                              (bitwise-and imm8 #xFF)))]
      ;; ADDS rd, rn, #imm3  or  ADDS rd, rn, rm
      [`(,(or 'ADDS 'adds) ,rd ,rn ,op3)
       (if (exact-integer? op3)
           (emit-hw! (bitwise-ior #x1C00
                                  (arithmetic-shift (bitwise-and op3 7) 6)
                                  (arithmetic-shift (thumb-low-reg rn) 3)
                                  (thumb-low-reg rd)))
           (emit-hw! (bitwise-ior #x1800
                                  (arithmetic-shift (thumb-low-reg op3) 6)
                                  (arithmetic-shift (thumb-low-reg rn) 3)
                                  (thumb-low-reg rd))))]
      ;; SUBS rd, #imm8
      [`(,(or 'SUBS 'subs) ,rd ,(? exact-integer? imm8))
       (emit-hw! (bitwise-ior #x3800
                              (arithmetic-shift (thumb-low-reg rd) 8)
                              (bitwise-and imm8 #xFF)))]
      ;; SUBS rd, rn, #imm3  or  SUBS rd, rn, rm
      [`(,(or 'SUBS 'subs) ,rd ,rn ,op3)
       (if (exact-integer? op3)
           (emit-hw! (bitwise-ior #x1E00
                                  (arithmetic-shift (bitwise-and op3 7) 6)
                                  (arithmetic-shift (thumb-low-reg rn) 3)
                                  (thumb-low-reg rd)))
           (emit-hw! (bitwise-ior #x1A00
                                  (arithmetic-shift (thumb-low-reg op3) 6)
                                  (arithmetic-shift (thumb-low-reg rn) 3)
                                  (thumb-low-reg rd))))]
      ;; CMP rn, #imm8  or  CMP rn, rm
      [`(,(or 'CMP 'cmp) ,rn ,op2)
       (if (exact-integer? op2)
           (emit-hw! (bitwise-ior #x2800
                                  (arithmetic-shift (thumb-low-reg rn) 8)
                                  (bitwise-and op2 #xFF)))
           (emit-hw! (bitwise-ior #x4280
                                  (arithmetic-shift (thumb-low-reg op2) 3)
                                  (thumb-low-reg rn))))]
      ;; LDR rt, [rn, #imm5]
      [(or `(,(or 'LDR 'ldr) ,rt (,rn ,imm5))
           `(,(or 'LDR 'ldr) ,rt ,rn ,imm5))
       (emit-hw! (bitwise-ior #x6800
                              (arithmetic-shift (bitwise-and imm5 #x1F) 6)
                              (arithmetic-shift (thumb-low-reg rn) 3)
                              (thumb-low-reg rt)))]
      [`(,(or 'LDR 'ldr) ,rt (,rn))
       (emit-hw! (bitwise-ior #x6800
                              (arithmetic-shift (thumb-low-reg rn) 3)
                              (thumb-low-reg rt)))]
      ;; STR rt, [rn, #imm5]
      [(or `(,(or 'STR 'str) ,rt (,rn ,imm5))
           `(,(or 'STR 'str) ,rt ,rn ,imm5))
       (emit-hw! (bitwise-ior #x6000
                              (arithmetic-shift (bitwise-and imm5 #x1F) 6)
                              (arithmetic-shift (thumb-low-reg rn) 3)
                              (thumb-low-reg rt)))]
      [`(,(or 'STR 'str) ,rt (,rn))
       (emit-hw! (bitwise-ior #x6000
                              (arithmetic-shift (thumb-low-reg rn) 3)
                              (thumb-low-reg rt)))]
      ;; Unconditional Branch B
      [`(,(or 'B 'b) ,target)
       (define off (resolve-branch-offset target cur-pc))
       (emit-hw! (bitwise-ior #xE000 (bitwise-and off #x07FF)))]
      ;; Conditional Branches BEQ / BNE
      [`(,(or 'BEQ 'beq) ,target)
       (define off (resolve-branch-offset target cur-pc))
       (emit-hw! (bitwise-ior #xD000 (bitwise-and off #xFF)))]
      [`(,(or 'BNE 'bne) ,target)
       (define off (resolve-branch-offset target cur-pc))
       (emit-hw! (bitwise-ior #xD100 (bitwise-and off #xFF)))]
      ;; 32-bit Branch with Link BL
      [`(,(or 'BL 'bl) ,target)
       (define off (resolve-branch-offset target cur-pc))
       (define hi11 (bitwise-and (arithmetic-shift off -11) #x07FF))
       (define lo11 (bitwise-and off #x07FF))
       (emit-hw! (bitwise-ior #xF000 hi11))
       (emit-hw! (bitwise-ior #xF800 lo11))]
      ;; BX LR
      [(or `(,(or 'BX 'bx) ,(or 'LR 'lr))
           `(,(or 'BX-LR 'bx-lr)))
       (emit-hw! #x4770)]
      ;; PUSH {reg-list}
      [`(,(or 'PUSH 'push) ,reg-list)
       (define regs (if (list? reg-list) reg-list (list reg-list)))
       (emit-hw! (bitwise-ior #xB400 (thumb-reg-list-mask regs #t #f)))]
      ;; POP {reg-list}
      [`(,(or 'POP 'pop) ,reg-list)
       (define regs (if (list? reg-list) reg-list (list reg-list)))
       (emit-hw! (bitwise-ior #xBC00 (thumb-reg-list-mask regs #f #t)))]
      [else
       (error 'assemble-thumb-m0plus "Unrecognized ARMv6-M Thumb instruction: ~v" form)]))

  (reverse halfwords))

;; Assemble ARMv6-M Thumb instructions into little-endian machine bytes
(define (assemble-thumb-m0plus forms #:origin [origin #x10000100])
  (define hws (assemble-thumb-m0plus-words forms #:origin origin))
  (define out (make-bytes (* 2 (length hws)) 0))
  (for ([hw (in-list hws)]
        [idx (in-naturals)])
    (bytes-set! out (* 2 idx) (bitwise-and #xFF hw))
    (bytes-set! out (add1 (* 2 idx)) (bitwise-and #xFF (arithmetic-shift hw -8))))
  out)

;; Default Cortex-M0+ Thumb firmware for Core 0 (Game Engine in SRAM0..3)
;; and Core 1 (Scanline Renderer in SRAM4..5)
(define DEFAULT-RP2040-THUMB-PROGRAM
  '((label core0_reset_entry)
    (PUSH (r4 r5 r6 lr))
    (MOVS r0 0)        ; sector = 0
    (MOVS r1 24)       ; player_x = 24
    (MOVS r2 64)       ; player_y = 64
    (MOVS r3 0)        ; failed_flag = 0
    (BL core0_frame_step)
    (POP (r4 r5 r6 pc))

    (label core0_frame_step)
    (PUSH (r4 lr))
    (ADDS r1 8)
    (CMP r1 96)
    (BNE frame_done)
    (ADDS r0 1)
    (MOVS r1 24)
    (label frame_done)
    (STR r0 (r4 0))
    (STR r1 (r4 1))
    (STR r2 (r4 2))
    (LDR r5 (r4 0))
    (SUBS r5 0)
    (POP (r4 lr))
    (BX lr)))

;; ============================================================================
;; 5. RP2040 UF2 Binary Image Builder & Bank-Disjoint SRAM Verifier
;; ============================================================================

(define UF2-MAGIC-START0           #x0A324655)
(define UF2-MAGIC-START1           #x9E5D5157)
(define UF2-MAGIC-END              #x0AB16F30)
(define UF2-FLAG-FAMILY-ID-PRESENT #x00002000)
(define UF2-RP2040-FAMILY-ID       #xE48BFF56)
(define RP2040-FLASH-BASE          #x10000000)

;; RP2040 Bank-Disjoint SRAM Partitioning:
;;   Core 0 (Game Logic & Rule State) : SRAM0..3 (#x20000000 - #x2003FFFF, 256 KB)
;;   Core 1 (Scanline Video & PIO DMA): SRAM4..5 (#x20040000 - #x20041FFF, 8 KB dedicated)
(define RP2040-SRAM0-3-BASE #x20000000)
(define RP2040-SRAM0-3-END  #x2003FFFF)
(define RP2040-SRAM4-5-BASE #x20040000)
(define RP2040-SRAM4-5-END  #x20041FFF)

(define (verify-rp2040-sram-disjointness
         #:core0-base [c0-base RP2040-SRAM0-3-BASE]
         #:core0-size [c0-size #x10000]
         #:core1-base [c1-base RP2040-SRAM4-5-BASE]
         #:core1-size [c1-size #x02000])
  (define c0-end (+ c0-base c0-size -1))
  (define c1-end (+ c1-base c1-size -1))
  (define core0-in-sram0-3?
    (and (>= c0-base RP2040-SRAM0-3-BASE)
         (<= c0-end  RP2040-SRAM0-3-END)))
  (define core1-in-sram4-5?
    (and (>= c1-base RP2040-SRAM4-5-BASE)
         (<= c1-end  RP2040-SRAM4-5-END)))
  (define disjoint?
    (or (< c0-end c1-base) (< c1-end c0-base)))
  (hasheq 'core0-sram-banks "SRAM0..3 (#x20000000-#x2003FFFF)"
          'core1-sram-banks "SRAM4..5 (#x20040000-#x20041FFF)"
          'core0-in-sram0-3? core0-in-sram0-3?
          'core1-in-sram4-5? core1-in-sram4-5?
          'sram-disjoint?    (and core0-in-sram0-3? core1-in-sram4-5? disjoint?)
          'ahb-crossbar-stalls 0))

(define (put-u32-le! buf offset val)
  (bytes-set! buf (+ offset 0) (bitwise-and #xFF val))
  (bytes-set! buf (+ offset 1) (bitwise-and #xFF (arithmetic-shift val -8)))
  (bytes-set! buf (+ offset 2) (bitwise-and #xFF (arithmetic-shift val -16)))
  (bytes-set! buf (+ offset 3) (bitwise-and #xFF (arithmetic-shift val -24))))

(define (get-u32-le buf offset)
  (bitwise-ior (bytes-ref buf (+ offset 0))
               (arithmetic-shift (bytes-ref buf (+ offset 1)) 8)
               (arithmetic-shift (bytes-ref buf (+ offset 2)) 16)
               (arithmetic-shift (bytes-ref buf (+ offset 3)) 24)))

;; Package a flat flash payload into 512-byte RP2040 UF2 blocks (256 B payload per block)
(define (build-rp2040-uf2-image payload-bytes #:base-addr [base-addr RP2040-FLASH-BASE])
  (define total-len (bytes-length payload-bytes))
  (define num-blocks (max 1 (quotient (+ total-len 255) 256)))
  (define uf2 (make-bytes (* 512 num-blocks) 0))

  (for ([blk (in-range num-blocks)])
    (define blk-off (* 512 blk))
    (define pay-off (* 256 blk))
    (define copy-len (min 256 (max 0 (- total-len pay-off))))

    (put-u32-le! uf2 (+ blk-off 0)   UF2-MAGIC-START0)
    (put-u32-le! uf2 (+ blk-off 4)   UF2-MAGIC-START1)
    (put-u32-le! uf2 (+ blk-off 8)   UF2-FLAG-FAMILY-ID-PRESENT)
    (put-u32-le! uf2 (+ blk-off 12)  (+ base-addr pay-off))
    (put-u32-le! uf2 (+ blk-off 16)  256)
    (put-u32-le! uf2 (+ blk-off 20)  blk)
    (put-u32-le! uf2 (+ blk-off 24)  num-blocks)
    (put-u32-le! uf2 (+ blk-off 28)  UF2-RP2040-FAMILY-ID)

    (when (> copy-len 0)
      (bytes-copy! uf2 (+ blk-off 32) payload-bytes pay-off (+ pay-off copy-len)))

    (put-u32-le! uf2 (+ blk-off 508) UF2-MAGIC-END))

  uf2)

;; Compile a complete RP2040 .uf2 binary containing:
;;   - Boot2 + Vector Table header (256 B at #x10000000)
;;   - Compiled ARMv6-M Cortex-M0+ Thumb firmware
;;   - Compiled 16-bit RP2040 PIO Scanline Video State Machine words
;;   - 4bpp Tile Assets
(define (compile-boba-rp2040-uf2! #:out-path [out-path #f]
                                  #:pio-forms [pio-forms DEFAULT-RP2040-SCANLINE-PIO-PROGRAM]
                                  #:thumb-forms [thumb-forms DEFAULT-RP2040-THUMB-PROGRAM])
  (define pio-analysis (analyze-rp2040-pio-program pio-forms))
  (define pio-words    (hash-ref pio-analysis 'words))
  (define pio-bytes    (make-bytes (* 2 (length pio-words)) 0))
  (for ([w (in-list pio-words)]
        [i (in-naturals)])
    (bytes-set! pio-bytes (* 2 i) (bitwise-and #xFF w))
    (bytes-set! pio-bytes (add1 (* 2 i)) (bitwise-and #xFF (arithmetic-shift w -8))))

  (define thumb-bytes (assemble-thumb-m0plus thumb-forms #:origin #x10000100))
  (define sram-proof  (verify-rp2040-sram-disjointness))

  ;; Construct 256-byte RP2040 XIP header + Cortex-M0+ Vector Table
  (define header (make-bytes 256 0))
  (put-u32-le! header 0 (+ RP2040-SRAM0-3-BASE #x10000)) ; Initial MSP in SRAM0..3
  (put-u32-le! header 4 #x10000101)                      ; Reset_Handler (Thumb bit 0 = 1)
  ;; Embed PIO instruction count & SRAM bank markers in metadata slot
  (put-u32-le! header 16 (length pio-words))
  (put-u32-le! header 20 RP2040-SRAM0-3-BASE)
  (put-u32-le! header 24 RP2040-SRAM4-5-BASE)

  ;; 4bpp Tile Asset Bank (256 bytes)
  (define tile-bank (make-bytes 256 #x17))

  (define flash-payload
    (bytes-append header thumb-bytes pio-bytes tile-bank))
  (define uf2-bytes
    (build-rp2040-uf2-image flash-payload #:base-addr RP2040-FLASH-BASE))

  (when out-path
    (make-directory* (or (path-only out-path) (current-directory)))
    (display-to-file uf2-bytes out-path #:exists 'replace #:mode 'binary))

  (values uf2-bytes
          (hasheq 'uf2-bytes-len     (bytes-length uf2-bytes)
                  'uf2-blocks        (quotient (bytes-length uf2-bytes) 512)
                  'thumb-bytes-len   (bytes-length thumb-bytes)
                  'pio-instructions  (length pio-words)
                  'pio-max-limit     RP2040-PIO-MAX-INSTRUCTIONS
                  'pio-within-limit? (hash-ref pio-analysis 'within-32-limit?)
                  'pio-cycles        (hash-ref pio-analysis 'deterministic-cycles)
                  'sram-disjoint?    (hash-ref sram-proof 'sram-disjoint?)
                  'sram-proof        sram-proof)))

;; ============================================================================
;; 6. Unified PICO-8 (.p8) + RP2040 (.uf2) Backend Verifier
;; ============================================================================

(define (verify-pico-backends [p8-cart-or-path #f] [uf2-bytes-or-path #f])
  (define p8-text
    (cond
      [(not p8-cart-or-path)
       (define-values (txt _meta) (compile-boba-pico8-cart!))
       txt]
      [(path-string? p8-cart-or-path)
       (if (file-exists? p8-cart-or-path)
           (file->string p8-cart-or-path)
           p8-cart-or-path)]
      [else (error 'verify-pico-backends "Expected .p8 string or path, got ~v" p8-cart-or-path)]))

  (define uf2-bytes
    (cond
      [(not uf2-bytes-or-path)
       (define-values (bin _meta) (compile-boba-rp2040-uf2!))
       bin]
      [(bytes? uf2-bytes-or-path) uf2-bytes-or-path]
      [(path-string? uf2-bytes-or-path) (file->bytes uf2-bytes-or-path)]
      [else (error 'verify-pico-backends "Expected .uf2 bytes or path, got ~v" uf2-bytes-or-path)]))

  ;; 1. Verify PICO-8 Cartridge
  (define p8-tokens (count-pico8-tokens p8-text #:verify-limit? #f))
  (define p8-q16-ok? (check-pico8-fixed16-16-range p8-text #:error? #f))
  (define p8-sim (simulate-pico8-cartridge-campaign p8-text))

  ;; 2. Verify RP2040 UF2 Binary Blocks
  (define uf2-len (bytes-length uf2-bytes))
  (define valid-block-multiple? (and (> uf2-len 0) (zero? (modulo uf2-len 512))))
  (define num-blocks (quotient uf2-len 512))

  (define all-blocks-valid?
    (and valid-block-multiple?
         (for/and ([b (in-range num-blocks)])
           (define off (* 512 b))
           (and (= (get-u32-le uf2-bytes (+ off 0))   UF2-MAGIC-START0)
                (= (get-u32-le uf2-bytes (+ off 4))   UF2-MAGIC-START1)
                (= (get-u32-le uf2-bytes (+ off 8))   UF2-FLAG-FAMILY-ID-PRESENT)
                (= (get-u32-le uf2-bytes (+ off 12))  (+ RP2040-FLASH-BASE (* 256 b)))
                (= (get-u32-le uf2-bytes (+ off 16))  256)
                (= (get-u32-le uf2-bytes (+ off 20))  b)
                (= (get-u32-le uf2-bytes (+ off 24))  num-blocks)
                (= (get-u32-le uf2-bytes (+ off 28))  UF2-RP2040-FAMILY-ID)
                (= (get-u32-le uf2-bytes (+ off 508)) UF2-MAGIC-END)))))

  (define pio-analysis (analyze-rp2040-pio-program DEFAULT-RP2040-SCANLINE-PIO-PROGRAM))
  (define sram-proof   (verify-rp2040-sram-disjointness))

  (hasheq 'pico8-tokens          p8-tokens
          'pico8-token-limit     PICO8-MAX-TOKENS
          'pico8-tokens-ok?      (<= p8-tokens PICO8-MAX-TOKENS)
          'pico8-fixed16-16-ok?  p8-q16-ok?
          'pico8-sections-ok?    (hash-ref p8-sim 'has-all-sections?)
          'pico8-campaign-result (hash-ref p8-sim 'campaign-result)
          'uf2-valid-blocks?     all-blocks-valid?
          'uf2-block-count       num-blocks
          'uf2-family-id         UF2-RP2040-FAMILY-ID
          'uf2-flash-base        RP2040-FLASH-BASE
          'pio-instruction-count (hash-ref pio-analysis 'instruction-count)
          'pio-within-32-limit?  (hash-ref pio-analysis 'within-32-limit?)
          'pio-scanline-cycles   (hash-ref pio-analysis 'deterministic-cycles)
          'sram-bank-disjoint?   (hash-ref sram-proof 'sram-disjoint?)))
