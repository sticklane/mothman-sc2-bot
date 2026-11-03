#lang racket/base

;; ============================================================================
;; compiler/plt-error-diagnostics.rkt
;;
;; PLT-Grounded Error Message Architecture for #lang boba-nes:
;;   1. Culpepper & Felleisen (ICFP 2010, JFP 2012) `syntax/parse` Fortified
;;      Surface Macro & DSL Validator with Progress-Ordered Syntax Classes
;;   2. Pombrio, Krishnamurthi, & Wand (PLDI 2014, ICFP 2015, PLDI 2018)
;;      Core-IR-to-Surface-DSL Resugaring Engine & Jargon Sanitizer
;;   3. Multi-Site Witness Slice & Dataflow Provenance Analyzers
;;      (Marceau, Fisler, & Krishnamurthi 2011; Flanagan et al. 1996 MrSpidey;
;;       Zhang & Myers 2014 SHErrLoc):
;;        - 65C816 Two-Path Control-Flow Mode Conflict Witnesses
;;        - GBA ARM7TDMI Backward Register Def-Use Slice for 8-Bit STRB on VRAM
;;        - Pareto Resource Overflow Blame & Minimal Cut-Set Attribution
;;        - Findler & Felleisen (ICFP 2002) Positive/Negative Contract Blame
;;          across Co-Processor & Bank Boundaries
;;   4. Canonical Racket Realm-Style Structured Error Formatter &
;;      5-Point PLT Error Message Compliance Linter
;; ============================================================================

(require (for-syntax racket/base
                     syntax/parse)
         syntax/parse
         racket/match
         racket/list
         racket/set
         racket/format
         racket/math
         racket/string
         "boba-core-ir.rkt"
         "graded-typechecker.rkt"
         "multi-target-typechecker.rkt")

(provide
 ;; 0. Structured PLT Diagnostic Data Types
 (struct-out srcloc-span)
 make-srcloc-span
 syntax->srcloc-span
 (struct-out witness-site)
 make-witness-site
 (struct-out pareto-contributor)
 make-pareto-contributor
 (struct-out contract-blame)
 make-contract-blame
 (struct-out plt-boba-diagnostic)
 make-plt-boba-diagnostic
 (struct-out exn:fail:syntax:boba)

 ;; 1. `syntax/parse` Fortified Surface Macro & DSL Validator
 VALID-METASPRITE-ORDERS
 VALID-RULE-NOUNS
 VALID-RULE-CONNECTORS
 VALID-RULE-PROPERTIES
 VALID-CAMPAIGN-KINDS
 validate-boba-surface-syntax
 parse-boba-surface-form/fortified
 defpalette/fortified
 deftiles/fortified
 defmetasprite/fortified
 defcampaign/fortified
 defrule/fortified
 deffixed/fortified
 defphysics/fortified

 ;; 2. Pombrio-Krishnamurthi Resugaring Engine & Core IR Surface Constructors
 ir-palette
 ir-tileset
 ir-metasprite
 ir-mode-transition
 ir-coproc-session
 ir-campaign
 INTERNAL-JARGON-PATTERNS
 sanitize-internal-compiler-jargon
 strip-compiler-internal-jargon
 resugar-core-ir->surface-dsl
 resugar-target-type-report

 ;; 3. Multi-Site Witness Slice & Dataflow Provenance Analyzers
 diagnose-65816-mode-conflict/witnesses
 diagnose-gba-vram-strb/dataflow-slice
 diagnose-resource-overflow/pareto-blame
 diagnose-coprocessor-session/contract-blame

 ;; 4. Canonical Racket Structured Error Formatter & Static PLT Rubric Linter
 format-plt-diagnostic
 audit-error-message-plt-compliance)

;; ============================================================================
;; 0. Structured PLT Diagnostic Data Types
;; ============================================================================

(struct srcloc-span
  (source
   line
   column
   position
   span
   surface-form
   sub-datum)
  #:transparent)

(define (make-srcloc-span
         #:source       [source "boba-module.bnes"]
         #:line         [line 1]
         #:column       [column 0]
         #:position     [position 1]
         #:span         [span 1]
         #:surface-form [surface-form '(defnes-game)]
         #:sub-datum    [sub-datum #f])
  (srcloc-span source line column position span surface-form sub-datum))

(define (syntax->srcloc-span stx [enclosing-stx #f] #:default-source [default-src "boba-module.bnes"])
  (define sub-d (if (syntax? stx) (syntax->datum stx) stx))
  (define surf-d
    (cond
      [(and enclosing-stx (syntax? enclosing-stx)) (syntax->datum enclosing-stx)]
      [enclosing-stx enclosing-stx]
      [(syntax? stx) (syntax->datum stx)]
      [else stx]))
  (if (syntax? stx)
      (srcloc-span (or (syntax-source stx)
                       (and (syntax? enclosing-stx) (syntax-source enclosing-stx))
                       default-src)
                   (or (syntax-line stx)
                       (and (syntax? enclosing-stx) (syntax-line enclosing-stx))
                       1)
                   (or (syntax-column stx)
                       (and (syntax? enclosing-stx) (syntax-column enclosing-stx))
                       0)
                   (or (syntax-position stx) 1)
                   (or (syntax-span stx)
                       (string-length (format "~s" sub-d)))
                   surf-d
                   sub-d)
      (srcloc-span default-src
                   1
                   0
                   1
                   (string-length (format "~s" sub-d))
                   surf-d
                   sub-d)))

(struct witness-site
  (role
   label
   srcloc
   state-desc)
  #:transparent)

(define (make-witness-site
         #:role       role
         #:label      label
         #:srcloc     [loc (make-srcloc-span)]
         #:state-desc state-desc)
  (witness-site role label loc state-desc))

(struct pareto-contributor
  (form-name
   id
   metric-name
   amount
   budget-pct
   srcloc)
  #:transparent)

(define (make-pareto-contributor
         #:form-name   form-name
         #:id          id
         #:metric-name metric-name
         #:amount      amount
         #:budget-pct  budget-pct
         #:srcloc      [loc (make-srcloc-span #:surface-form (list form-name id) #:sub-datum id)])
  (pareto-contributor form-name id metric-name amount budget-pct loc))

(struct contract-blame
  (polarity
   blamed-party
   boundary-kind
   expected-contract
   actual-behavior
   srcloc)
  #:transparent)

(define (make-contract-blame
         #:polarity          polarity
         #:blamed-party      blamed-party
         #:boundary-kind     boundary-kind
         #:expected-contract expected-contract
         #:actual-behavior   actual-behavior
         #:srcloc            [loc (make-srcloc-span)])
  (contract-blame polarity blamed-party boundary-kind expected-contract actual-behavior loc))

(struct plt-boba-diagnostic
  (operation
   target
   headline
   at-datum
   in-form
   expected
   given
   witnesses
   pareto-breakdown
   blame
   resugared-surface-term
   repair-options)
  #:transparent)

(define (make-plt-boba-diagnostic
         #:operation              operation
         #:target                 [target 'nes]
         #:headline               headline
         #:at-datum               at-datum
         #:in-form                in-form
         #:expected               expected
         #:given                  given
         #:witnesses              [witnesses '()]
         #:pareto-breakdown       [pareto-breakdown '()]
         #:blame                  [blame #f]
         #:resugared-surface-term [resugared-surface-term #f]
         #:repair-options         [repair-options '()])
  (plt-boba-diagnostic
   operation
   target
   headline
   at-datum
   in-form
   expected
   given
   witnesses
   pareto-breakdown
   blame
   (or resugared-surface-term in-form)
   repair-options))

;; Subtype of `exn:fail:syntax` carrying the structured `plt-boba-diagnostic`
(struct exn:fail:syntax:boba exn:fail:syntax
  (diagnostic)
  #:transparent)

;; Helper to raise or return a `plt-boba-diagnostic`
(define (finish-diagnostic diag
                           #:raise? [raise? #f]
                           #:at-stx [at-stx #f]
                           #:in-stx [in-stx #f])
  (if raise?
      (let* ([msg (format-plt-diagnostic diag)]
             [expr-list
              (filter syntax?
                      (list (or at-stx (datum->syntax #f (plt-boba-diagnostic-at-datum diag)))
                            (or in-stx (datum->syntax #f (plt-boba-diagnostic-in-form diag)))))])
        (raise (exn:fail:syntax:boba msg (current-continuation-marks) expr-list diag)))
      diag))

;; ============================================================================
;; 1. `syntax/parse` Fortified Surface Macro & DSL Validator
;;    (Culpepper & Felleisen, ICFP 2010 / JFP 2012 "Fortifying Macros")
;; ============================================================================

(define VALID-METASPRITE-ORDERS
  '(row-major col-major symmetric-col-major symmetric-vertical))

(define VALID-RULE-NOUNS
  '(BOBA CUP PEARL STAR WALL ROCK FLAG SPIKE LAVA WATER
    KEY DOOR BABA KEKE BELT ICE GATE ORB GOAL TEXT))

(define VALID-RULE-CONNECTORS
  '(IS HAS MAKE FOLLOW EAT FEAR NEAR ON))

(define VALID-RULE-PROPERTIES
  '(YOU WIN STOP PUSH DEFEAT SINK MELT HOT OPEN SHUT
    FLOAT MOVE TELE SHIFT SAFE WEAK SWAP PULL RED BLUE GOLD))

(define VALID-CAMPAIGN-KINDS
  '(initial normal active play stage-clear victory failure hazard defeat retry boss))

(define (normalize-symbol-upcase sym)
  (if (symbol? sym)
      (string->symbol (string-upcase (symbol->string sym)))
      sym))

(define (strip-quote-datum d)
  (match d
    [`(quote ,inner) inner]
    [_ d]))

(define (strip-quote-stx stx)
  (syntax-parse stx
    #:datum-literals (quote)
    [(quote inner) #'inner]
    [other #'other]))

;; Declarative `syntax/parse` syntax classes with `#:description` and `#:fail-when`

(define-syntax-class boba-identifier
  #:description "a #lang boba-nes binding identifier (symbol)"
  (pattern x:id))

(define-syntax-class nes-palette-color-stx
  #:description "a 6-bit NES 2C02 hardware color index (#x00..#x3F, avoiding #x0D sync hazard)"
  (pattern c:exact-integer
           #:fail-when (or (< (syntax-e #'c) #x00) (> (syntax-e #'c) #x3F))
           "color index outside 6-bit NES 2C02 palette range #x00..#x3F (0..63)"
           #:fail-when (= (syntax-e #'c) #x0D)
           "color index #x0D triggers the NTSC 2C02 blacker-than-black voltage drop hazard; use #x0F for safe black"))

(define-syntax-class bgr555-palette-color-stx
  #:description "a 15-bit BGR555 color word (#x0000..#x7FFF) or 5-bit channel tuple (r5 g5 b5) in 0..31"
  (pattern c:exact-integer
           #:fail-when (or (< (syntax-e #'c) #x0000) (> (syntax-e #'c) #x7FFF))
           "color word outside 15-bit BGR555 range #x0000..#x7FFF (bit 15 must be 0)")
  (pattern (r:exact-integer g:exact-integer b:exact-integer)
           #:fail-unless (and (<= 0 (syntax-e #'r) 31)
                              (<= 0 (syntax-e #'g) 31)
                              (<= 0 (syntax-e #'b) 31))
           "BGR555 channel tuple (r5 g5 b5) requires each 5-bit channel to be in 0..31 (#x00..#x1F)"))

(define-syntax-class n64-rgba5551-color-stx
  #:description "a 16-bit N64 RGBA5551 texel word (#x0000..#xFFFF) or tuple (r5 g5 b5 a1)"
  (pattern c:exact-integer
           #:fail-when (or (< (syntax-e #'c) #x0000) (> (syntax-e #'c) #xFFFF))
           "color word outside 16-bit N64 RGBA5551 range #x0000..#xFFFF (0..65535)")
  (pattern (r:exact-integer g:exact-integer b:exact-integer a:exact-integer)
           #:fail-unless (and (<= 0 (syntax-e #'r) 31)
                              (<= 0 (syntax-e #'g) 31)
                              (<= 0 (syntax-e #'b) 31)
                              (<= 0 (syntax-e #'a) 1))
           "N64 RGBA5551 tuple (r5 g5 b5 a1) requires r5,g5,b5 in 0..31 and alpha bit a1 in 0..1"))

(define-syntax-class chr-row-2bpp-stx
  #:description "an 8-pixel 2bpp CHR tile row string of exact length 8 using characters '0'..'3' (or '.')"
  (pattern s:str
           #:fail-unless (= (string-length (syntax-e #'s)) 8)
           "CHR tile row string must have exact length 8 (8 horizontal pixels)"
           #:fail-when (for/first ([ch (in-string (syntax-e #'s))]
                                   #:unless (memv ch '(#\0 #\1 #\2 #\3 #\. #\space)))
                         ch)
           "2bpp CHR tile row contains pixel character outside '0'..'3'"))

(define-syntax-class chr-row-4bpp-stx
  #:description "an 8-pixel 4bpp CHR tile row string of exact length 8 using hex characters '0'..'9','A'..'F' (or '.')"
  (pattern s:str
           #:fail-unless (= (string-length (syntax-e #'s)) 8)
           "CHR tile row string must have exact length 8 (8 horizontal pixels)"
           #:fail-when (for/first ([ch (in-string (syntax-e #'s))]
                                   #:unless (or (and (char>=? ch #\0) (char<=? ch #\9))
                                                (and (char>=? ch #\a) (char<=? ch #\f))
                                                (and (char>=? ch #\A) (char<=? ch #\F))
                                                (char=? ch #\.)
                                                (char=? ch #\space)))
                         ch)
           "4bpp CHR tile row contains pixel character outside '0'..'9','A'..'F'"))

(define-syntax-class metasprite-order-stx
  #:description "a metasprite layout order ('row-major, 'col-major, 'symmetric-col-major, or 'symmetric-vertical)"
  (pattern ord
           #:with norm (datum->syntax #'ord (strip-quote-datum (syntax->datum #'ord)))
           #:fail-unless (memq (syntax-e #'norm) VALID-METASPRITE-ORDERS)
           "unrecognized metasprite #:order; expected 'row-major, 'col-major, 'symmetric-col-major, or 'symmetric-vertical"))

(define-syntax-class metasprite-entry-stx
  #:description "a 4-field hardware OAM sprite entry [dx dy tile attr]"
  (pattern (dx:exact-integer dy:exact-integer tile:exact-integer attr:exact-integer)
           #:fail-unless (<= -128 (syntax-e #'dx) 127)
           "sprite entry dx offset must be a signed 8-bit integer in -128..127"
           #:fail-unless (<= -128 (syntax-e #'dy) 127)
           "sprite entry dy offset must be a signed 8-bit integer in -128..127"
           #:fail-unless (<= 0 (syntax-e #'tile) 1023)
           "sprite entry tile index must be a non-negative integer in 0..1023"
           #:fail-unless (<= 0 (syntax-e #'attr) 255)
           "sprite entry OAM attribute byte must be in 0..255 (#x00..#xFF)"))

(define-syntax-class fixed-q8.8-literal-stx
  #:description "a signed Q8.8 fixed-point literal in [-128.0, +127.99609375]"
  (pattern n
           #:when (real? (syntax-e #'n))
           #:fail-unless (and (>= (syntax-e #'n) -128.0)
                              (<= (syntax-e #'n) 127.99609375))
           "numeric literal overflows signed Q8.8 fixed-point range [-128.0, +127.996]"))

(define-syntax-class fixed-q16.16-literal-stx
  #:description "a signed Q16.16 fixed-point literal in [-32768.0, +32767.99998474121]"
  (pattern n
           #:when (real? (syntax-e #'n))
           #:fail-unless (and (>= (syntax-e #'n) -32768.0)
                              (<= (syntax-e #'n) 32767.99998474121))
           "numeric literal overflows signed Q16.16 fixed-point range [-32768.0, +32767.99998]"))

;; Build standard 2-site witnesses for surface syntax diagnostics so every
;; diagnostic records both the enclosing target contract and the pinpointed sub-datum.
(define (make-syntax-witnesses enclosing-stx offending-stx target-desc offending-desc
                               #:source [source "boba-surface.bnes"])
  (define enc-span (syntax->srcloc-span enclosing-stx enclosing-stx #:default-source source))
  (define off-span (syntax->srcloc-span offending-stx enclosing-stx #:default-source source))
  (list
   (witness-site 'enclosing-surface-contract
                 'declaration-head
                 enc-span
                 target-desc)
   (witness-site 'offending-sub-datum
                 'pinpointed-subterm
                 off-span
                 offending-desc)))

;; 1A. Fortified `defpalette` Validator
(define (validate-defpalette-stx stx target #:raise? [raise? #f] #:source [source "boba-surface.bnes"])
  (define form-datum (syntax->datum stx))
  (syntax-parse stx
    [(_ id:boba-identifier rest ...)
     (define rest-stxs (syntax->list #'(rest ...)))
     ;; Extract optional #:target override inside the form
     (define-values (eff-target color-group-stxs)
       (let loop ([rem rest-stxs] [tgt target] [acc '()])
         (match rem
           ['() (values tgt (reverse acc))]
           [(list* kw val more)
            #:when (eq? (syntax-e kw) '#:target)
            (loop more (strip-quote-datum (syntax-e (strip-quote-stx val))) acc)]
           [(cons item more)
            (loop more tgt (cons item acc))])))
     (define spec (get-target-spec eff-target))
     (define tid (target-spec-id spec))
     ;; Flatten a single parenthesized list of colors `(c1 c2 ...)` if passed as one list
     (define color-stxs
       (if (and (= (length color-group-stxs) 1)
                (syntax->list (car color-group-stxs))
                (not (and (memq tid '(gbc snes gba n64 rp2040))
                          (let ([els (syntax->list (car color-group-stxs))])
                            (and (<= 3 (length els) 4)
                                 (for/and ([e (in-list els)])
                                   (and (exact-integer? (syntax-e e))
                                        (<= 0 (syntax-e e) 31))))))))
           (syntax->list (car color-group-stxs))
           color-group-stxs))

     (define (check-color-element c-stx idx)
       (define c-val (syntax->datum c-stx))
       (case tid
         [(nes)
          (syntax-parse c-stx
            [ok:nes-palette-color-stx #f]
            [_
             (define is-0d? (equal? c-val #x0D))
             (make-plt-boba-diagnostic
              #:operation 'defpalette
              #:target tid
              #:headline (if is-0d?
                             (format "forbidden NTSC 2C02 sync-level color index #x0D in palette '~a' at entry ~a"
                                     (syntax-e #'id) idx)
                             (format "out-of-range color literal ~s in NES palette '~a' at entry ~a"
                                     c-val (syntax-e #'id) idx))
              #:at-datum c-val
              #:in-form form-datum
              #:expected "6-bit NES 2C02 palette index in #x00..#x3F (0..63), excluding #x0D"
              #:given (if (exact-integer? c-val)
                          (format "#x~x (~a)" c-val c-val)
                          (format "~s" c-val))
              #:witnesses (make-syntax-witnesses
                           stx c-stx
                           "NES 2C02 PPU CGRAM ($3F00-$3F1F) accepts 6-bit hue/luma indices #x00..#x3F"
                           (format "entry ~a supplies ~s outside 6-bit 2C02 color space" idx c-val)
                           #:source source)
              #:resugared-surface-term form-datum
              #:repair-options
              (if is-0d?
                  (list (format "Replace forbidden #x0D with safe black #x0F in (defpalette ~a ...)" (syntax-e #'id))
                        (format "Use dark gray #x00 or #x1D if a shadowed accent was intended in (defpalette ~a ...)" (syntax-e #'id)))
                  (list (format "Clamp color ~s into 6-bit NES 2C02 range #x00..#x3F (e.g., #x~x)"
                                c-val (if (exact-integer? c-val) (bitwise-and c-val #x3F) #x0F))
                        "If targeting 15-bit BGR555 hardware, specify #:target 'snes, 'gbc, or 'gba")))])]
         [(gbc snes gba)
          (syntax-parse c-stx
            [ok:bgr555-palette-color-stx #f]
            [_
             (make-plt-boba-diagnostic
              #:operation 'defpalette
              #:target tid
              #:headline (format "out-of-range 15-bit BGR555 color literal ~s in ~a palette '~a' at entry ~a"
                                 c-val (string-upcase (symbol->string tid)) (syntax-e #'id) idx)
              #:at-datum c-val
              #:in-form form-datum
              #:expected "15-bit BGR555 word in #x0000..#x7FFF (0..32767) or 5-bit channel tuple (r5 g5 b5) in 0..31"
              #:given (if (exact-integer? c-val)
                          (format "#x~x (~a)" c-val c-val)
                          (format "~s" c-val))
              #:witnesses (make-syntax-witnesses
                           stx c-stx
                           (format "~a hardware palette RAM stores 15-bit BGR555 words (0bbbbbgggggrrrrr, #x0000..#x7FFF)"
                                   (string-upcase (symbol->string tid)))
                           (format "entry ~a supplies ~s which overflows 15-bit BGR555 range" idx c-val)
                           #:source source)
              #:resugared-surface-term form-datum
              #:repair-options
              (list (if (exact-integer? c-val)
                        (format "Mask or clamp #x~x to 15-bit BGR555 range #x0000..#x7FFF (e.g., #x~x)"
                                c-val (bitwise-and c-val #x7FFF))
                        (format "Clamp each RGB channel in ~s to 5-bit range 0..31 (#x00..#x1F)" c-val))
                    "If using 16-bit RGBA5551 with alpha bit, set #:target 'n64"))])]
         [(n64)
          (syntax-parse c-stx
            [ok:n64-rgba5551-color-stx #f]
            [_
             (make-plt-boba-diagnostic
              #:operation 'defpalette
              #:target 'n64
              #:headline (format "out-of-range 16-bit N64 RGBA5551 color literal ~s in palette '~a' at entry ~a"
                                 c-val (syntax-e #'id) idx)
              #:at-datum c-val
              #:in-form form-datum
              #:expected "16-bit N64 RGBA5551 word in #x0000..#xFFFF (0..65535) or tuple (r5 g5 b5 a1) with r,g,b in 0..31 and a1 in 0..1"
              #:given (if (exact-integer? c-val)
                          (format "#x~x (~a)" c-val c-val)
                          (format "~s" c-val))
              #:witnesses (make-syntax-witnesses
                           stx c-stx
                           "N64 RDP TMEM TLUT stores 16-bit big-endian RGBA5551 texels (rrrrrgggggbbbbba)"
                           (format "entry ~a supplies ~s outside 16-bit RGBA5551 domain" idx c-val)
                           #:source source)
              #:resugared-surface-term form-datum
              #:repair-options
              (list (if (exact-integer? c-val)
                        (format "Clamp #x~x to 16-bit RGBA5551 word #x0000..#xFFFF (e.g., #x~x)"
                                c-val (bitwise-and c-val #xFFFF))
                        (format "Ensure (r5 g5 b5 a1) in ~s has r5,g5,b5 in 0..31 and a1 in 0..1" c-val))
                    "Use (pack-n64-rgba5551 r5 g5 b5 a1) to construct valid 16-bit N64 texel words"))])]
         [(gb)
          (if (and (exact-integer? c-val) (<= 0 c-val 3))
              #f
              (make-plt-boba-diagnostic
               #:operation 'defpalette
               #:target 'gb
               #:headline (format "out-of-range 2-bit DMG shade ~s in Game Boy palette '~a' at entry ~a"
                                  c-val (syntax-e #'id) idx)
               #:at-datum c-val
               #:in-form form-datum
               #:expected "2-bit Game Boy DMG shade index in 0..3 (0=White, 1=Light Gray, 2=Dark Gray, 3=Black)"
               #:given (format "~s" c-val)
               #:witnesses (make-syntax-witnesses
                            stx c-stx
                            "Game Boy DMG BGP/OBP0/OBP1 ($FF47-$FF49) maps four 2-bit monochrome shades 0..3"
                            (format "entry ~a supplies ~s outside 0..3" idx c-val)
                            #:source source)
               #:resugared-surface-term form-datum
               #:repair-options
               (list (format "Replace ~s with a 2-bit DMG shade in 0..3" c-val)
                     "Switch to #:target 'gbc for 15-bit BGR555 Game Boy Color palettes")))]
         [(pico8)
          (if (and (exact-integer? c-val) (or (<= 0 c-val 15) (<= 128 c-val 143)))
              #f
              (make-plt-boba-diagnostic
               #:operation 'defpalette
               #:target 'pico8
               #:headline (format "out-of-range PICO-8 palette index ~s in '~a' at entry ~a"
                                  c-val (syntax-e #'id) idx)
               #:at-datum c-val
               #:in-form form-datum
               #:expected "4-bit PICO-8 standard color index in 0..15 (or extended secret palette 128..143)"
               #:given (format "~s" c-val)
               #:witnesses (make-syntax-witnesses
                            stx c-stx
                            "PICO-8 pal() table accepts 16 base colors (0..15) or 16 extended colors (128..143)"
                            (format "entry ~a supplies ~s outside PICO-8 palette range" idx c-val)
                            #:source source)
               #:resugared-surface-term form-datum
               #:repair-options
               (list (format "Wrap color index ~s into 0..15 via (modulo ~s 16)" c-val c-val)
                     "Use extended PICO-8 palette indices 128..143 for darker tones")))]
         [else
          (if (and (exact-integer? c-val) (<= 0 c-val #xFFFF))
              #f
              (make-plt-boba-diagnostic
               #:operation 'defpalette
               #:target tid
               #:headline (format "out-of-range palette color ~s in '~a'" c-val (syntax-e #'id))
               #:at-datum c-val
               #:in-form form-datum
               #:expected "16-bit color integer in #x0000..#xFFFF"
               #:given (format "~s" c-val)
               #:witnesses (make-syntax-witnesses stx c-stx "16-bit palette word" (format "~s" c-val) #:source source)
               #:resugared-surface-term form-datum
               #:repair-options (list (format "Clamp ~s to #x0000..#xFFFF" c-val))))]))

     (let loop ([cs color-stxs] [idx 0])
       (match cs
         ['()
          (hasheq 'valid? #t
                  'form-kind 'defpalette
                  'id (syntax-e #'id)
                  'target tid
                  'colors (map syntax->datum color-stxs))]
         [(cons c-stx more)
          (define maybe-diag (check-color-element c-stx idx))
          (if maybe-diag
              (finish-diagnostic maybe-diag #:raise? raise? #:at-stx c-stx #:in-stx stx)
              (loop more (add1 idx)))]))]
    [(_ bad-id . _)
     (define diag
       (make-plt-boba-diagnostic
        #:operation 'defpalette
        #:target target
        #:headline "malformed palette identifier in (defpalette ...)"
        #:at-datum (syntax->datum #'bad-id)
        #:in-form form-datum
        #:expected "a symbolic palette identifier followed by target color literals, e.g. (defpalette hero-pal (#x0F #x16 #x27 #x30))"
        #:given (format "~s" (syntax->datum #'bad-id))
        #:witnesses (make-syntax-witnesses stx #'bad-id "defpalette requires a symbol identifier" "non-identifier at position 1" #:source source)
        #:resugared-surface-term form-datum
        #:repair-options (list "Provide a symbol identifier as the first argument to (defpalette id (c0 c1 c2 c3))")))
     (finish-diagnostic diag #:raise? raise? #:at-stx #'bad-id #:in-stx stx)]))

;; 1B. Fortified `deftiles` / `defchr-tile` Validator
(define (validate-deftiles-stx stx target #:bpp [kw-bpp #f] #:raise? [raise? #f] #:source [source "boba-surface.bnes"])
  (define form-datum (syntax->datum stx))
  (syntax-parse stx
    [(_ id:boba-identifier rest ...)
     (define rest-stxs (syntax->list #'(rest ...)))
     (define-values (eff-target explicit-bpp tile-items)
       (let loop ([rem rest-stxs] [tgt target] [bpp kw-bpp] [acc '()])
         (match rem
           ['() (values tgt bpp (reverse acc))]
           [(list* kw val more)
            #:when (eq? (syntax-e kw) '#:target)
            (loop more (strip-quote-datum (syntax-e (strip-quote-stx val))) bpp acc)]
           [(list* kw val more)
            #:when (eq? (syntax-e kw) '#:bpp)
            (loop more tgt (syntax-e val) acc)]
           [(cons item more)
            (loop more tgt bpp (cons item acc))])))
     (define spec (get-target-spec eff-target))
     (define tid (target-spec-id spec))
     (define bpp (or explicit-bpp (if (memq tid '(nes gb gbc)) 2 4)))

     ;; Extract groups of row strings from `(deftiles id "r0" ... "r7")`,
     ;; `(deftiles id ("r0" ... "r7"))`, or `(deftiles id (0 ("r0" ... "r7")) ...)`
     (define row-groups
       (cond
         [(and (pair? tile-items) (string? (syntax-e (car tile-items))))
          (list (cons #'id tile-items))]
         [(and (= (length tile-items) 2)
               (exact-integer? (syntax-e (first tile-items)))
               (syntax->list (second tile-items)))
          (list (cons (second tile-items) (syntax->list (second tile-items))))]
         [else
          (for/list ([item (in-list tile-items)])
            (define sub-list (syntax->list item))
            (cond
              [(not sub-list) (cons item (list item))]
              [(and (>= (length sub-list) 2)
                    (exact-integer? (syntax-e (first sub-list)))
                    (= (length sub-list) 2)
                    (syntax->list (second sub-list)))
               (cons (second sub-list) (syntax->list (second sub-list)))]
              [(and (>= (length sub-list) 2)
                    (exact-integer? (syntax-e (first sub-list))))
               (cons item (cdr sub-list))]
              [else (cons item sub-list)]))]))

     (define (check-row-stx row-stx row-idx)
       (define r-datum (syntax->datum row-stx))
       (cond
         [(not (string? r-datum))
          (make-plt-boba-diagnostic
           #:operation 'deftiles
           #:target tid
           #:headline (format "non-string CHR row ~s at row ~a in tileset '~a'" r-datum row-idx (syntax-e #'id))
           #:at-datum r-datum
           #:in-form form-datum
           #:expected (format "an 8-character ~abpp pixel row string (e.g., \"01233210\")" bpp)
           #:given (format "~s" r-datum)
           #:witnesses (make-syntax-witnesses stx row-stx "deftiles requires 8 strings of 8 pixel characters" (format "row ~a is not a string: ~s" row-idx r-datum) #:source source)
           #:resugared-surface-term form-datum
           #:repair-options (list (format "Replace ~s with an 8-character pixel string such as \"00122100\"" r-datum)))]
         [(not (= (string-length r-datum) 8))
          (make-plt-boba-diagnostic
           #:operation 'deftiles
           #:target tid
           #:headline (format "malformed CHR tile row width (~a pixels instead of 8) in tileset '~a' at row ~a"
                              (string-length r-datum) (syntax-e #'id) row-idx)
           #:at-datum r-datum
           #:in-form form-datum
           #:expected (format "an 8-character ~abpp tile row string (8 horizontal pixels)" bpp)
           #:given (format "~s (length ~a)" r-datum (string-length r-datum))
           #:witnesses (make-syntax-witnesses
                        stx row-stx
                        (format "8x8 hardware tile matrix on ~a requires exactly 8 pixels per row" (string-upcase (symbol->string tid)))
                        (format "row ~a (~s) has length ~a != 8" row-idx r-datum (string-length r-datum))
                        #:source source)
           #:resugared-surface-term form-datum
           #:repair-options
           (list (if (< (string-length r-datum) 8)
                     (format "Pad row ~s to 8 pixels: ~s"
                             r-datum (string-append r-datum (make-string (- 8 (string-length r-datum)) #\0)))
                     (format "Truncate row ~s to 8 pixels: ~s"
                             r-datum (substring r-datum 0 8)))
                 "Split wide artwork across multiple 8x8 tiles and compose them with (defmetasprite ...)"))]
         [else
          (define bad-char-col
            (for/first ([ch (in-string r-datum)]
                        [col (in-naturals)]
                        #:unless (if (= bpp 2)
                                     (memv ch '(#\0 #\1 #\2 #\3 #\. #\space))
                                     (or (and (char>=? ch #\0) (char<=? ch #\9))
                                         (and (char>=? ch #\a) (char<=? ch #\f))
                                         (and (char>=? ch #\A) (char<=? ch #\F))
                                         (char=? ch #\.)
                                         (char=? ch #\space))))
              (cons ch col)))
          (if bad-char-col
              (let ([bad-ch (car bad-char-col)]
                    [bad-col (cdr bad-char-col)])
                (make-plt-boba-diagnostic
                 #:operation 'deftiles
                 #:target tid
                 #:headline (format "invalid ~abpp pixel character ~s at column ~a of row ~a (~s) in tileset '~a'"
                                    bpp bad-ch bad-col row-idx r-datum (syntax-e #'id))
                 #:at-datum r-datum
                 #:in-form form-datum
                 #:expected (if (= bpp 2)
                                "8-character string containing only 2bpp pixel digits '0'..'3' (or '.' for transparent)"
                                "8-character string containing only 4bpp hex pixel digits '0'..'9','A'..'F' (or '.')")
                 #:given (format "character ~s at column ~a in row string ~s" bad-ch bad-col r-datum)
                 #:witnesses (make-syntax-witnesses
                              stx row-stx
                              (format "~a uses ~abpp planar/nibble tiles supporting ~a colors per tile"
                                      (string-upcase (symbol->string tid)) bpp (expt 2 bpp))
                              (format "column ~a of row ~a has out-of-alphabet pixel character ~s" bad-col row-idx bad-ch)
                              #:source source)
                 #:resugared-surface-term form-datum
                 #:repair-options
                 (list (format "Replace character ~s at column ~a in ~s with a valid ~abpp digit (~a)"
                               bad-ch bad-col r-datum bpp (if (= bpp 2) "'0'..'3'" "'0'..'F'"))
                       (if (= bpp 2)
                           "If 16-color 4bpp tiles were intended, target 'snes, 'gba, or 'pico8 (or set #:bpp 4)"
                           "Ensure all 8 pixel characters in the row are hexadecimal nibbles '0'..'F'"))))
              #f)]))

     (let group-loop ([groups row-groups])
       (match groups
         ['()
          (hasheq 'valid? #t
                  'form-kind 'deftiles
                  'id (syntax-e #'id)
                  'target tid
                  'bpp bpp)]
         [(cons (cons grp-stx rows-stx-list) more-groups)
          ;; First check every individual row string for length & pixel alphabet
          (define row-err
            (for/or ([r-stx (in-list rows-stx-list)]
                     [r-idx (in-naturals)])
              (check-row-stx r-stx r-idx)))
          (cond
            [row-err
             (define off-stx
               (for/first ([r-stx (in-list rows-stx-list)]
                           [r-idx (in-naturals)]
                           #:when (check-row-stx r-stx r-idx))
                 r-stx))
             (finish-diagnostic row-err #:raise? raise? #:at-stx off-stx #:in-stx stx)]
            [(not (= (length rows-stx-list) 8))
             (define diag
               (make-plt-boba-diagnostic
                #:operation 'deftiles
                #:target tid
                #:headline (format "8x8 CHR tile in '~a' has ~a rows instead of 8"
                                   (syntax-e #'id) (length rows-stx-list))
                #:at-datum (syntax->datum grp-stx)
                #:in-form form-datum
                #:expected "exactly 8 row strings per 8x8 hardware tile"
                #:given (format "~a rows: ~s" (length rows-stx-list) (map syntax->datum rows-stx-list))
                #:witnesses (make-syntax-witnesses
                             stx grp-stx
                             "Hardware 8x8 tile pattern requires 8 vertical scanline rows"
                             (format "tile group provides ~a rows" (length rows-stx-list))
                             #:source source)
                #:resugared-surface-term form-datum
                #:repair-options
                (list (format "Provide exactly 8 row strings of length 8 in (deftiles ~a ...)" (syntax-e #'id)))))
             (finish-diagnostic diag #:raise? raise? #:at-stx grp-stx #:in-stx stx)]
            [else
             (group-loop more-groups)])]))]))

;; 1C. Fortified `defmetasprite` Validator
(define (validate-defmetasprite-stx stx target #:raise? [raise? #f] #:source [source "boba-surface.bnes"])
  (define form-datum (syntax->datum stx))
  (syntax-parse stx
    [(_ id:boba-identifier rest ...)
     (define rest-stxs (syntax->list #'(rest ...)))
     (define order-stx #f)
     (define entries-stx-list '())
     (define attr-stx #f)

     (let loop ([rem rest-stxs])
       (match rem
         ['() (void)]
         [(list* kw val more)
          #:when (eq? (syntax-e kw) '#:order)
          (set! order-stx val)
          (loop more)]
         [(list* kw val more)
          #:when (eq? (syntax-e kw) '#:attr)
          (set! attr-stx val)
          (loop more)]
         [(list* kw _val more)
          #:when (memq (syntax-e kw) '(#:tiles #:tile #:tl #:tr #:bl #:br #:target))
          (loop more)]
         [(cons item more)
          (define sub (syntax->list item))
          (if (and sub
                   (pair? sub)
                   (syntax->list (car sub)))
              (set! entries-stx-list (append entries-stx-list sub))
              (set! entries-stx-list (append entries-stx-list (list item))))
          (loop more)]))

     ;; 1. Validate #:order if present
     (define order-err
       (and order-stx
            (syntax-parse order-stx
              [ok:metasprite-order-stx #f]
              [_
               (define ord-d (syntax->datum order-stx))
               (make-plt-boba-diagnostic
                #:operation 'defmetasprite
                #:target target
                #:headline (format "invalid metasprite layout #:order ~s in '~a'" ord-d (syntax-e #'id))
                #:at-datum ord-d
                #:in-form form-datum
                #:expected "one of 'row-major, 'col-major, 'symmetric-col-major, or 'symmetric-vertical"
                #:given (format "~s" ord-d)
                #:witnesses (make-syntax-witnesses
                             stx order-stx
                             "defmetasprite #:order selects 2x2 or 1x2 OAM hardware sprite layout discipline"
                             (format "unsupported layout order ~s" ord-d)
                             #:source source)
                #:resugared-surface-term form-datum
                #:repair-options
                (list (format "Replace #:order ~s with 'row-major (SMB/Metroid 2x2) or 'col-major (Zelda/Mega Man 2x2)" ord-d)
                      "Use 'symmetric-col-major for half-mirrored 16x16 actors or 'symmetric-vertical for 8x16 objects"))])))

     (if order-err
         (finish-diagnostic order-err #:raise? raise? #:at-stx order-stx #:in-stx stx)
         ;; 2. Validate #:attr if present
         (let ([attr-err
                (and attr-stx
                     (let ([a-val (syntax->datum attr-stx)])
                       (if (and (exact-integer? a-val) (<= 0 a-val 255))
                           #f
                           (make-plt-boba-diagnostic
                            #:operation 'defmetasprite
                            #:target target
                            #:headline (format "invalid OAM attribute byte ~s in metasprite '~a'" a-val (syntax-e #'id))
                            #:at-datum a-val
                            #:in-form form-datum
                            #:expected "unsigned 8-bit OAM attribute byte in 0..255 (#x00..#xFF)"
                            #:given (format "~s" a-val)
                            #:witnesses (make-syntax-witnesses stx attr-stx "OAM byte 2 attribute (V-flip, H-flip, priority, palette)" (format "~s outside 0..255" a-val) #:source source)
                            #:resugared-surface-term form-datum
                            #:repair-options (list (format "Mask or clamp #:attr ~s to #x00..#xFF" a-val))))))])
           (if attr-err
               (finish-diagnostic attr-err #:raise? raise? #:at-stx attr-stx #:in-stx stx)
               ;; 3. Validate each [dx dy tile attr] sprite entry
               (let entry-loop ([es entries-stx-list] [idx 0])
                 (match es
                   ['()
                    (hasheq 'valid? #t
                            'form-kind 'defmetasprite
                            'id (syntax-e #'id)
                            'order (if order-stx (strip-quote-datum (syntax->datum order-stx)) 'row-major))]
                   [(cons e-stx more)
                    (syntax-parse e-stx
                      [ok:metasprite-entry-stx
                       (entry-loop more (add1 idx))]
                      [_
                       (define e-d (syntax->datum e-stx))
                       (define sub-els (syntax->list e-stx))
                       ;; Pinpoint the exact offending field inside `[dx dy tile attr]` if it has 4 elements!
                       (define-values (off-stx field-msg exp-msg)
                         (cond
                           [(and sub-els (= (length sub-els) 4))
                            (define dx-s (first sub-els))
                            (define dy-s (second sub-els))
                            (define tl-s (third sub-els))
                            (define at-s (fourth sub-els))
                            (cond
                              [(not (and (exact-integer? (syntax-e dx-s)) (<= -128 (syntax-e dx-s) 127)))
                               (values dx-s
                                       (format "sprite entry ~a has out-of-range dx offset ~s" idx (syntax->datum dx-s))
                                       "signed 8-bit dx offset in -128..127")]
                              [(not (and (exact-integer? (syntax-e dy-s)) (<= -128 (syntax-e dy-s) 127)))
                               (values dy-s
                                       (format "sprite entry ~a has out-of-range dy offset ~s" idx (syntax->datum dy-s))
                                       "signed 8-bit dy offset in -128..127")]
                              [(not (and (exact-integer? (syntax-e tl-s)) (<= 0 (syntax-e tl-s) 1023)))
                               (values tl-s
                                       (format "sprite entry ~a has invalid tile index ~s" idx (syntax->datum tl-s))
                                       "non-negative hardware tile index in 0..1023")]
                              [else
                               (values at-s
                                       (format "sprite entry ~a has invalid OAM attribute byte ~s" idx (syntax->datum at-s))
                                       "unsigned 8-bit OAM attribute byte in 0..255 (#x00..#xFF)")])]
                           [else
                            (values e-stx
                                    (format "malformed sprite entry ~s at index ~a (expected 4-tuple [dx dy tile attr])" e-d idx)
                                    "4-element sprite entry [dx dy tile attr]")]))
                       (define diag
                         (make-plt-boba-diagnostic
                          #:operation 'defmetasprite
                          #:target target
                          #:headline (format "~a in metasprite '~a'" field-msg (syntax-e #'id))
                          #:at-datum (syntax->datum off-stx)
                          #:in-form form-datum
                          #:expected exp-msg
                          #:given (format "~s (in entry ~s)" (syntax->datum off-stx) e-d)
                          #:witnesses (make-syntax-witnesses
                                       stx off-stx
                                       "Hardware OAM entry requires [dx:i8 dy:i8 tile:u8/u10 attr:u8]"
                                       field-msg
                                       #:source source)
                          #:resugared-surface-term form-datum
                          #:repair-options
                          (list (format "Format sprite entry ~a as [dx dy tile attr] with dx,dy in -128..127, tile in 0..255, attr in 0..255" idx)
                                "Use #:tl / #:tr / #:bl / #:br shorthand for standard 16x16 2x2 metasprites")))
                       (finish-diagnostic diag #:raise? raise? #:at-stx off-stx #:in-stx stx)])])))))]))

;; 1D. Fortified `defcampaign` / `defstate-machine` Validator
(define (validate-defcampaign-stx stx target #:raise? [raise? #f] #:source [source "boba-surface.bnes"])
  (define form-datum (syntax->datum stx))
  (define head-sym (car form-datum))
  (syntax-parse stx
    [(_ id:boba-identifier rest ...)
     (define rest-stxs (syntax->list #'(rest ...)))
     (define init-stx #f)
     (define clause-stxs '())

     (let loop ([rem rest-stxs])
       (match rem
         ['() (void)]
         [(list* kw val more)
          #:when (eq? (syntax-e kw) '#:initial)
          (set! init-stx (strip-quote-stx val))
          (loop more)]
         [(list* kw _val more)
          #:when (keyword? (syntax-e kw))
          (loop more)]
         [(cons item more)
          (define sub (syntax->list item))
          (if (and sub (pair? sub) (syntax->list (car sub)))
              (set! clause-stxs (append clause-stxs sub))
              (set! clause-stxs (append clause-stxs (list item))))
          (loop more)]))

     ;; Parse each stage clause:
     ;; Supports `[stage-id #:kind kind #:transitions (t1 ...)]` or `[stage-id kind (t1 ...)]`
     (define parsed-stages
       (for/list ([c-stx (in-list clause-stxs)])
         (syntax-parse c-stx
           [(st-id:boba-identifier #:kind k-raw #:transitions (tgt:boba-identifier ...))
            (hasheq 'id (syntax-e #'st-id)
                    'id-stx #'st-id
                    'clause-stx c-stx
                    'kind (strip-quote-datum (syntax->datum #'k-raw))
                    'kind-stx #'k-raw
                    'targets (map syntax-e (syntax->list #'(tgt ...)))
                    'target-stxs (syntax->list #'(tgt ...)))]
           [(st-id:boba-identifier #:transitions (tgt:boba-identifier ...) #:kind k-raw)
            (hasheq 'id (syntax-e #'st-id)
                    'id-stx #'st-id
                    'clause-stx c-stx
                    'kind (strip-quote-datum (syntax->datum #'k-raw))
                    'kind-stx #'k-raw
                    'targets (map syntax-e (syntax->list #'(tgt ...)))
                    'target-stxs (syntax->list #'(tgt ...)))]
           [(st-id:boba-identifier k-raw (tgt:boba-identifier ...))
            (hasheq 'id (syntax-e #'st-id)
                    'id-stx #'st-id
                    'clause-stx c-stx
                    'kind (strip-quote-datum (syntax->datum #'k-raw))
                    'kind-stx #'k-raw
                    'targets (map syntax-e (syntax->list #'(tgt ...)))
                    'target-stxs (syntax->list #'(tgt ...)))]
           [_
            (hasheq 'malformed? #t 'clause-stx c-stx)])))

     ;; Check 0: Malformed clause syntax
     (define malformed-stage
       (findf (lambda (s) (hash-ref s 'malformed? #f)) parsed-stages))
     (cond
       [malformed-stage
        (define bad-c (hash-ref malformed-stage 'clause-stx))
        (define diag
          (make-plt-boba-diagnostic
           #:operation head-sym
           #:target target
           #:headline (format "malformed stage transition clause in campaign '~a'" (syntax-e #'id))
           #:at-datum (syntax->datum bad-c)
           #:in-form form-datum
           #:expected "[stage-id #:kind <initial|normal|failure|victory> #:transitions (target-id ...)]"
           #:given (format "~s" (syntax->datum bad-c))
           #:witnesses (make-syntax-witnesses stx bad-c "Campaign stage clause grammar" "malformed stage clause" #:source source)
           #:resugared-surface-term form-datum
           #:repair-options (list "Format each stage as [stage-id #:kind 'normal #:transitions (next-stage)]")))
        (finish-diagnostic diag #:raise? raise? #:at-stx bad-c #:in-stx stx)]

       [else
        ;; Check 1: Duplicate stage identifiers
        (define seen-ids (make-hasheq))
        (define dup-stage
          (for/first ([s (in-list parsed-stages)]
                      #:when (if (hash-has-key? seen-ids (hash-ref s 'id))
                                 #t
                                 (begin (hash-set! seen-ids (hash-ref s 'id) s) #f)))
            (cons (hash-ref seen-ids (hash-ref s 'id)) s)))

        (cond
          [dup-stage
           (define first-s (car dup-stage))
           (define second-s (cdr dup-stage))
           (define dup-id (hash-ref second-s 'id))
           (define off-stx (hash-ref second-s 'clause-stx))
           (define diag
             (make-plt-boba-diagnostic
              #:operation head-sym
              #:target target
              #:headline (format "duplicate stage identifier '~a' in campaign '~a'" dup-id (syntax-e #'id))
              #:at-datum (syntax->datum off-stx)
              #:in-form form-datum
              #:expected "unique stage identifiers across all campaign stages"
              #:given (format "stage '~a' declared twice" dup-id)
              #:witnesses
              (list (witness-site 'first-stage-declaration
                                  dup-id
                                  (syntax->srcloc-span (hash-ref first-s 'clause-stx) stx #:default-source source)
                                  (format "first declaration of stage '~a'" dup-id))
                    (witness-site 'duplicate-stage-declaration
                                  dup-id
                                  (syntax->srcloc-span off-stx stx #:default-source source)
                                  (format "conflicting duplicate declaration of stage '~a'" dup-id)))
              #:resugared-surface-term form-datum
              #:repair-options
              (list (format "Rename the duplicate stage '~a' to a distinct identifier (e.g., '~a-2)" dup-id dup-id)
                    (format "Merge the transitions of both '~a' clauses into a single stage declaration" dup-id))))
           (finish-diagnostic diag #:raise? raise? #:at-stx off-stx #:in-stx stx)]

          [else
           (define all-stage-ids (map (lambda (s) (hash-ref s 'id)) parsed-stages))
           (define stage-set (list->seteq all-stage-ids))

           ;; Check 2: Dangling transition targets not present in the stage list
           (define dangling-info
             (for*/first ([s (in-list parsed-stages)]
                          [t-stx (in-list (hash-ref s 'target-stxs))]
                          #:unless (set-member? stage-set (syntax-e t-stx)))
               (cons s t-stx)))

           (cond
             [dangling-info
              (define src-s (car dangling-info))
              (define bad-t-stx (cdr dangling-info))
              (define bad-t (syntax-e bad-t-stx))
              (define diag
                (make-plt-boba-diagnostic
                 #:operation head-sym
                 #:target target
                 #:headline (format "dangling transition target '~a' in stage '~a' of campaign '~a'"
                                    bad-t (hash-ref src-s 'id) (syntax-e #'id))
                 #:at-datum bad-t
                 #:in-form form-datum
                 #:expected (format "a declared stage identifier in ~s" all-stage-ids)
                 #:given (format "undeclared transition target '~a'" bad-t)
                 #:witnesses
                 (list (witness-site 'declared-stage-table
                                     (syntax-e #'id)
                                     (syntax->srcloc-span stx stx #:default-source source)
                                     (format "declared stages: ~s" all-stage-ids))
                       (witness-site 'dangling-transition-edge
                                     (hash-ref src-s 'id)
                                     (syntax->srcloc-span bad-t-stx stx #:default-source source)
                                     (format "stage '~a' transitions to non-existent stage '~a'" (hash-ref src-s 'id) bad-t)))
                 #:resugared-surface-term form-datum
                 #:repair-options
                 (list (format "Replace dangling target '~a' in stage '~a' with one of ~s"
                               bad-t (hash-ref src-s 'id) all-stage-ids)
                       (format "Add a stage clause [~a #:kind 'normal #:transitions (...)] to (~a ~a ...)"
                               bad-t head-sym (syntax-e #'id)))))
              (finish-diagnostic diag #:raise? raise? #:at-stx bad-t-stx #:in-stx stx)]

             [else
              ;; Check 3: Missing `#:kind failure` recovery edges (unrecoverable softlock)
              (define softlocked-failure
                (for/first ([s (in-list parsed-stages)]
                            #:when (and (memq (hash-ref s 'kind) '(failure hazard defeat))
                                        (let ([tgts (remove (hash-ref s 'id) (hash-ref s 'targets))])
                                          (null? tgts))))
                  s))
              (cond
                [softlocked-failure
                 (define f-id (hash-ref softlocked-failure 'id))
                 (define f-stx (hash-ref softlocked-failure 'clause-stx))
                 (define init-id (if init-stx (syntax-e init-stx) (car all-stage-ids)))
                 (define diag
                   (make-plt-boba-diagnostic
                    #:operation head-sym
                    #:target target
                    #:headline (format "failure stage '~a' in campaign '~a' lacks a recovery transition (softlock hazard)"
                                       f-id (syntax-e #'id))
                    #:at-datum (syntax->datum f-stx)
                    #:in-form form-datum
                    #:expected "every #:kind failure stage must have >= 1 outgoing recovery transition to an active/retry/initial stage"
                    #:given (format "stage '~a' (#:kind ~a) has transitions ~s"
                                    f-id (hash-ref softlocked-failure 'kind) (hash-ref softlocked-failure 'targets))
                    #:witnesses
                    (list (witness-site 'campaign-totality-invariant
                                        (syntax-e #'id)
                                        (syntax->srcloc-span stx stx #:default-source source)
                                        "L3 State-Machine Totality requires every failure/defeat state to recover without hardware reset")
                          (witness-site 'softlocked-failure-stage
                                        f-id
                                        (syntax->srcloc-span f-stx stx #:default-source source)
                                        (format "failure stage '~a' has no outgoing recovery edge" f-id)))
                    #:resugared-surface-term form-datum
                    #:repair-options
                    (list (format "Add a recovery edge from '~a' to '~a': [~a #:kind failure #:transitions (~a)]"
                                  f-id init-id f-id init-id)
                          "Wire START/RETRY button handling to transition out of the failure state")))
                 (finish-diagnostic diag #:raise? raise? #:at-stx f-stx #:in-stx stx)]

                [else
                 ;; Check 4: Unreachable stages from initial stage
                 (define init-id
                   (if init-stx
                       (syntax-e init-stx)
                       (if (pair? all-stage-ids) (car all-stage-ids) #f)))
                 (define adj
                   (for/hasheq ([s (in-list parsed-stages)])
                     (values (hash-ref s 'id) (hash-ref s 'targets))))
                 (define reachable
                   (let bfs ([queue (if (and init-id (set-member? stage-set init-id)) (list init-id) '())]
                             [vis (if (and init-id (set-member? stage-set init-id)) (seteq init-id) (seteq))])
                     (match queue
                       ['() vis]
                       [(cons cur rest)
                        (define nexts
                          (filter (lambda (nxt) (and (set-member? stage-set nxt) (not (set-member? vis nxt))))
                                  (hash-ref adj cur '())))
                        (bfs (append rest nexts)
                             (foldl (lambda (n acc) (set-add acc n)) vis nexts))])))

                 (define unreachable-stage
                   (for/first ([s (in-list parsed-stages)]
                               #:unless (set-member? reachable (hash-ref s 'id)))
                     s))

                 (if unreachable-stage
                     (let* ([u-id (hash-ref unreachable-stage 'id)]
                            [u-stx (hash-ref unreachable-stage 'clause-stx)]
                            [diag
                             (make-plt-boba-diagnostic
                              #:operation head-sym
                              #:target target
                              #:headline (format "unreachable stage '~a' in campaign '~a' (disconnected from initial stage '~a')"
                                                 u-id (syntax-e #'id) init-id)
                              #:at-datum (syntax->datum u-stx)
                              #:in-form form-datum
                              #:expected (format "all declared stages in ~s reachable via directed transitions from '~a'"
                                                 all-stage-ids init-id)
                              #:given (format "stage '~a' has 0 incoming paths from reachable set ~s"
                                              u-id (set->list reachable))
                              #:witnesses
                              (list (witness-site 'initial-entry-stage
                                                  init-id
                                                  (syntax->srcloc-span (or init-stx (hash-ref (car parsed-stages) 'clause-stx)) stx #:default-source source)
                                                  (format "BFS from initial stage '~a' reaches only ~s" init-id (set->list reachable)))
                                    (witness-site 'unreachable-stage-declaration
                                                  u-id
                                                  (syntax->srcloc-span u-stx stx #:default-source source)
                                                  (format "stage '~a' (#:kind ~a) is never reached" u-id (hash-ref unreachable-stage 'kind))))
                              #:resugared-surface-term form-datum
                              #:repair-options
                              (list (format "Add '~a' to the #:transitions list of a reachable stage in ~s"
                                            u-id (set->list reachable))
                                    (format "Remove dead stage '~a' if it is no longer part of campaign '~a'"
                                            u-id (syntax-e #'id))))])
                       (finish-diagnostic diag #:raise? raise? #:at-stx u-stx #:in-stx stx))
                     (hasheq 'valid? #t
                             'form-kind 'defcampaign
                             'id (syntax-e #'id)
                             'initial init-id
                             'stages all-stage-ids))])])])])]))

;; 1E. Fortified `defrule` Validator
(define (validate-defrule-stx stx target #:raise? [raise? #f] #:source [source "boba-surface.bnes"])
  (define form-datum (syntax->datum stx))
  (define elems (cdr (syntax->list stx)))
  ;; Support `(defrule id (SUBJ OP OBJ))`, `(defrule (SUBJ OP OBJ))`, `(defrule id SUBJ OP OBJ)`, `(defrule SUBJ OP OBJ)`
  (define-values (rule-id clause-stx token-stxs)
    (cond
      [(and (= (length elems) 2) (identifier? (first elems)) (syntax->list (second elems)))
       (values (syntax-e (first elems)) (second elems) (syntax->list (second elems)))]
      [(and (= (length elems) 1) (syntax->list (first elems)))
       (values 'anon-rule (first elems) (syntax->list (first elems)))]
      [(and (>= (length elems) 2)
            (identifier? (first elems))
            (not (memq (normalize-symbol-upcase (syntax-e (first elems)))
                       (append VALID-RULE-NOUNS VALID-RULE-PROPERTIES VALID-RULE-CONNECTORS))))
       (values (syntax-e (first elems)) stx (cdr elems))]
      [else
       (values 'anon-rule stx elems)]))

  (cond
    [(not (= (length token-stxs) 3))
     (define diag
       (make-plt-boba-diagnostic
        #:operation 'defrule
        #:target target
        #:headline (format "invalid rule arity (~a tokens instead of 3) in (defrule ...)" (length token-stxs))
        #:at-datum (syntax->datum clause-stx)
        #:in-form form-datum
        #:expected "a 3-token Baba/Boba rule clause (NOUN IS PROPERTY) or (NOUN IS NOUN), e.g., (BOBA IS YOU)"
        #:given (format "~a-token clause ~s" (length token-stxs) (map syntax->datum token-stxs))
        #:witnesses (make-syntax-witnesses
                     stx clause-stx
                     "Boba rule evaluator requires a 3-word [SUBJECT CONNECTOR OBJECT] sentence"
                     (format "clause ~s has ~a tokens" (syntax->datum clause-stx) (length token-stxs))
                     #:source source)
        #:resugared-surface-term form-datum
        #:repair-options
        (list "Provide exactly 3 tokens in the form (NOUN IS PROPERTY) or (NOUN IS NOUN), e.g., (BOBA IS YOU)"
              "Split compound rules into separate (defrule ...) declarations")))
     (finish-diagnostic diag #:raise? raise? #:at-stx clause-stx #:in-stx stx)]
    [else
     (define subj-stx (first token-stxs))
     (define conn-stx (second token-stxs))
     (define obj-stx  (third token-stxs))
     (define subj-sym (normalize-symbol-upcase (strip-quote-datum (syntax->datum subj-stx))))
     (define conn-sym (normalize-symbol-upcase (strip-quote-datum (syntax->datum conn-stx))))
     (define obj-sym  (normalize-symbol-upcase (strip-quote-datum (syntax->datum obj-stx))))

     (cond
       [(not (memq subj-sym VALID-RULE-NOUNS))
        (define is-prop? (memq subj-sym VALID-RULE-PROPERTIES))
        (define diag
          (make-plt-boba-diagnostic
           #:operation 'defrule
           #:target target
           #:headline (if is-prop?
                          (format "property token '~a' cannot appear in NOUN subject position of (defrule ...)"
                                  (syntax->datum subj-stx))
                          (format "unrecognized rule subject token '~a' in (defrule ...)"
                                  (syntax->datum subj-stx)))
           #:at-datum (syntax->datum subj-stx)
           #:in-form form-datum
           #:expected (format "a valid NOUN token in subject position ~s" VALID-RULE-NOUNS)
           #:given (format "~s (~a)" (syntax->datum subj-stx)
                           (if is-prop? "PROPERTY token in subject slot" "unknown vocabulary token"))
           #:witnesses (make-syntax-witnesses
                        stx subj-stx
                        "Rule grammar (NOUN IS PROPERTY | NOUN IS NOUN) requires a NOUN at position 1"
                        (format "subject position contains ~s" (syntax->datum subj-stx))
                        #:source source)
           #:resugared-surface-term form-datum
           #:repair-options
           (if is-prop?
               (list (format "Invert the rule to (~a ~a ~a) so the NOUN is on the left"
                             obj-sym conn-sym subj-sym)
                     (format "Replace subject '~a' with a valid NOUN such as BOBA, PEARL, WALL, or STAR"
                             (syntax->datum subj-stx)))
               (list (format "Replace unrecognized subject '~a' with a valid NOUN from ~s"
                             (syntax->datum subj-stx) '(BOBA CUP PEARL STAR WALL ROCK FLAG SPIKE))))))
        (finish-diagnostic diag #:raise? raise? #:at-stx subj-stx #:in-stx stx)]

       [(not (memq conn-sym VALID-RULE-CONNECTORS))
        (define diag
          (make-plt-boba-diagnostic
           #:operation 'defrule
           #:target target
           #:headline (format "invalid rule connector/verb '~a' in (defrule ...)" (syntax->datum conn-stx))
           #:at-datum (syntax->datum conn-stx)
           #:in-form form-datum
           #:expected (format "a valid rule connector token ~s (typically IS)" VALID-RULE-CONNECTORS)
           #:given (format "~s" (syntax->datum conn-stx))
           #:witnesses (make-syntax-witnesses
                        stx conn-stx
                        "Position 2 of (defrule ...) must be a relational connector (IS, HAS, MAKE, ON)"
                        (format "position 2 has non-connector token ~s" (syntax->datum conn-stx))
                        #:source source)
           #:resugared-surface-term form-datum
           #:repair-options
           (list (format "Replace connector '~a' with 'IS in (~a IS ~a)"
                         (syntax->datum conn-stx) subj-sym obj-sym))))
        (finish-diagnostic diag #:raise? raise? #:at-stx conn-stx #:in-stx stx)]

       [(not (or (memq obj-sym VALID-RULE-PROPERTIES)
                 (memq obj-sym VALID-RULE-NOUNS)))
        (define diag
          (make-plt-boba-diagnostic
           #:operation 'defrule
           #:target target
           #:headline (format "invalid rule predicate/object token '~a' in (defrule ...)" (syntax->datum obj-stx))
           #:at-datum (syntax->datum obj-stx)
           #:in-form form-datum
           #:expected "a valid PROPERTY token (YOU, WIN, STOP, PUSH, DEFEAT, HOT, MELT, ...) or NOUN token"
           #:given (format "~s" (syntax->datum obj-stx))
           #:witnesses (make-syntax-witnesses
                        stx obj-stx
                        "Position 3 of (NOUN IS <OBJECT>) must be a PROPERTY or NOUN token"
                        (format "position 3 has invalid token ~s" (syntax->datum obj-stx))
                        #:source source)
           #:resugared-surface-term form-datum
           #:repair-options
           (list (format "Replace '~a' with a valid PROPERTY token such as YOU, WIN, STOP, PUSH, or DEFEAT"
                         (syntax->datum obj-stx))
                 (format "Or transform '~a' into a NOUN token such as PEARL, STAR, or WALL"
                         (syntax->datum obj-stx)))))
        (finish-diagnostic diag #:raise? raise? #:at-stx obj-stx #:in-stx stx)]

       [else
        (hasheq 'valid? #t
                'form-kind 'defrule
                'id rule-id
                'subject subj-sym
                'connector conn-sym
                'object obj-sym)])]))

;; 1F. Fortified `deffixed` / `defphysics` Validator
(define (validate-deffixed-or-physics-stx stx target #:raise? [raise? #f] #:source [source "boba-surface.bnes"])
  (define form-datum (syntax->datum stx))
  (define head-sym (car form-datum))
  (syntax-parse stx
    [(_ id:boba-identifier rest ...)
     (define rest-stxs (syntax->list #'(rest ...)))
     (define eff-target target)
     (define explicit-fmt #f)
     (define num-stxs '())

     (let loop ([rem rest-stxs])
       (match rem
         ['() (void)]
         [(list* kw val more)
          #:when (eq? (syntax-e kw) '#:target)
          (set! eff-target (strip-quote-datum (syntax-e (strip-quote-stx val))))
          (loop more)]
         [(list* kw val more)
          #:when (eq? (syntax-e kw) '#:format)
          (set! explicit-fmt (strip-quote-datum (syntax-e (strip-quote-stx val))))
          (loop more)]
         [(list* kw val more)
          #:when (keyword? (syntax-e kw))
          (set! num-stxs (append num-stxs (list val)))
          (loop more)]
         [(cons item more)
          (define sub (syntax->list item))
          (cond
            [(and sub (= (length sub) 2) (identifier? (first sub)))
             (set! num-stxs (append num-stxs (list (second sub))))]
            [sub
             (for ([s (in-list sub)])
               (define ss (syntax->list s))
               (if (and ss (= (length ss) 2) (identifier? (first ss)))
                   (set! num-stxs (append num-stxs (list (second ss))))
                   (set! num-stxs (append num-stxs (list s)))))]
            [else
             (set! num-stxs (append num-stxs (list item)))])
          (loop more)]))

     (define spec (get-target-spec eff-target))
     (define tid (target-spec-id spec))
     (define fmt
       (or explicit-fmt
           (if (memq tid '(pico8 rp2040 gba n64))
               'q16.16
               'q8.8)))

     (define (check-num-stx n-stx)
       (define v (syntax->datum n-stx))
       (cond
         [(not (real? v))
          (make-plt-boba-diagnostic
           #:operation head-sym
           #:target tid
           #:headline (format "non-numeric fixed-point literal ~s in (~a ~a ...)" v head-sym (syntax-e #'id))
           #:at-datum v
           #:in-form form-datum
           #:expected (format "real number in signed ~a fixed-point range" (string-upcase (symbol->string fmt)))
           #:given (format "~s" v)
           #:witnesses (make-syntax-witnesses stx n-stx "Fixed-point declaration requires numeric literal" (format "~s is not a real number" v) #:source source)
           #:resugared-surface-term form-datum
           #:repair-options (list (format "Replace ~s with a numeric constant such as 1.5 or -3.25" v)))]
         [(eq? fmt 'q8.8)
          (syntax-parse n-stx
            [ok:fixed-q8.8-literal-stx #f]
            [_
             (make-plt-boba-diagnostic
              #:operation head-sym
              #:target tid
              #:headline (format "fixed-point literal ~s overflows signed Q8.8 range [-128.0, +127.996] in '~a'"
                                 v (syntax-e #'id))
              #:at-datum v
              #:in-form form-datum
              #:expected "signed 16-bit Q8.8 fixed-point value in [-128.0, +127.99609375] (8-bit signed integer + 8-bit fraction)"
              #:given (format "~s (requires > 8 signed integer bits)" v)
              #:witnesses (make-syntax-witnesses
                           stx n-stx
                           (format "~a uses 16-bit signed Q8.8 subpixel fixed-point [-128.0 .. +127.996]"
                                   (string-upcase (symbol->string tid)))
                           (format "literal ~s exceeds signed 8-bit integer part [-128 .. +127]" v)
                           #:source source)
              #:resugared-surface-term form-datum
              #:repair-options
              (list (format "Clamp ~s into signed Q8.8 range [-128.0, +127.996] (e.g., ~a)"
                            v (if (< v 0) -128.0 127.996))
                    "Promote the constant to signed 32-bit Q16.16 via #:format 'q16.16 (or target 'pico8 / 'gba / 'n64)"))])]
         [else
          (syntax-parse n-stx
            [ok:fixed-q16.16-literal-stx #f]
            [_
             (make-plt-boba-diagnostic
              #:operation head-sym
              #:target tid
              #:headline (format "fixed-point literal ~s overflows signed Q16.16 range [-32768.0, +32767.99998] in '~a'"
                                 v (syntax-e #'id))
              #:at-datum v
              #:in-form form-datum
              #:expected "signed 32-bit Q16.16 fixed-point value in [-32768.0, +32767.99998474121]"
              #:given (format "~s (overflows 16-bit signed integer part)" v)
              #:witnesses (make-syntax-witnesses
                           stx n-stx
                           (format "~a uses 32-bit signed Q16.16 fixed-point arithmetic [-32768.0 .. +32767.99998]"
                                   (string-upcase (symbol->string tid)))
                           (format "literal ~s overflows signed Q16.16 bounds" v)
                           #:source source)
              #:resugared-surface-term form-datum
              #:repair-options
              (list (format "Clamp ~s into signed Q16.16 range [-32768.0, +32767.99998] (e.g., ~a)"
                            v (if (< v 0) -32768.0 32767.99998))
                    "Scale world coordinates or velocities down so intermediate values fit in Q16.16"))])]))

     (let loop ([ns num-stxs])
       (match ns
         ['()
          (hasheq 'valid? #t
                  'form-kind head-sym
                  'id (syntax-e #'id)
                  'target tid
                  'format fmt)]
         [(cons n-stx more)
          (define err (check-num-stx n-stx))
          (if err
              (finish-diagnostic err #:raise? raise? #:at-stx n-stx #:in-stx stx)
              (loop more))]))]))

;; Unified `syntax/parse` Fortified Surface Macro & DSL Validator
(define (validate-boba-surface-syntax
         stx-or-datum
         [target-pos #f]
         #:target [kw-target #f]
         #:bpp [kw-bpp #f]
         #:raise? [raise? #f]
         #:source [source "boba-surface.bnes"])
  (define target (or kw-target target-pos 'nes))
  (define stx
    (cond
      [(syntax? stx-or-datum) stx-or-datum]
      [(string? stx-or-datum)
       (define in (open-input-string stx-or-datum source))
       (port-count-lines! in)
       (read-syntax source in)]
      [(bytes? stx-or-datum)
       (define in (open-input-bytes stx-or-datum source))
       (port-count-lines! in)
       (read-syntax source in)]
      [else
       (datum->syntax #f stx-or-datum (list source 1 0 1 1))]))
  (define datum (syntax->datum stx))
  (syntax-parse stx
    [(head:id . _)
     (case (syntax-e #'head)
       [(defpalette defpalette-resource defpalette/fortified)
        (validate-defpalette-stx stx target #:raise? raise? #:source source)]
       [(deftiles defchr-tile defchr-resource deftiles/fortified)
        (validate-deftiles-stx stx target #:bpp kw-bpp #:raise? raise? #:source source)]
       [(defmetasprite defmetasprite/fortified)
        (validate-defmetasprite-stx stx target #:raise? raise? #:source source)]
       [(defcampaign defstate-machine defcampaign/fortified)
        (validate-defcampaign-stx stx target #:raise? raise? #:source source)]
       [(defrule defrule/fortified)
        (validate-defrule-stx stx target #:raise? raise? #:source source)]
       [(deffixed defphysics deffixed/fortified defphysics/fortified)
        (validate-deffixed-or-physics-stx stx target #:raise? raise? #:source source)]
       [else
        (define diag
          (make-plt-boba-diagnostic
           #:operation (syntax-e #'head)
           #:target target
           #:headline (format "unrecognized #lang boba-nes surface declaration '~a'" (syntax-e #'head))
           #:at-datum (syntax-e #'head)
           #:in-form datum
           #:expected "one of defpalette, deftiles, defmetasprite, defcampaign, defrule, deffixed, or defphysics"
           #:given (format "~s" (syntax-e #'head))
           #:witnesses (make-syntax-witnesses stx #'head "#lang boba-nes surface grammar" "unknown form head" #:source source)
           #:resugared-surface-term datum
           #:repair-options
           (list "Use a documented #lang boba-nes surface declaration: defpalette, deftiles, defmetasprite, defcampaign, defrule, deffixed, or defphysics")))
        (finish-diagnostic diag #:raise? raise? #:at-stx #'head #:in-stx stx)])]
    [_
     (define diag
       (make-plt-boba-diagnostic
        #:operation 'boba-surface-form
        #:target target
        #:headline "expected a parenthesized #lang boba-nes surface declaration"
        #:at-datum datum
        #:in-form `(module boba-nes ,datum)
        #:expected "(<surface-keyword> <id> ...)"
        #:given (format "~s" datum)
        #:witnesses (make-syntax-witnesses stx stx "#lang boba-nes module-level form" "atomic non-list datum" #:source source)
        #:resugared-surface-term datum
        #:repair-options (list "Wrap the declaration in parentheses beginning with a #lang boba-nes surface form keyword")))
     (finish-diagnostic diag #:raise? raise? #:at-stx stx #:in-stx stx)]))

(define (parse-boba-surface-form/fortified
         stx-or-datum
         [target-pos #f]
         #:target [kw-target #f]
         #:bpp [kw-bpp #f]
         #:raise? [raise? #f]
         #:source [source "boba-surface.bnes"])
  (validate-boba-surface-syntax stx-or-datum target-pos
                                #:target kw-target
                                #:bpp kw-bpp
                                #:raise? raise?
                                #:source source))

;; Phase-0 / Runtime Fortified Macro Forms
(define-syntax-rule (defpalette/fortified id args ...)
  (define id (validate-boba-surface-syntax '(defpalette id args ...) #:raise? #t)))

(define-syntax-rule (deftiles/fortified id args ...)
  (define id (validate-boba-surface-syntax '(deftiles id args ...) #:raise? #t)))

(define-syntax-rule (defmetasprite/fortified id args ...)
  (define id (validate-boba-surface-syntax '(defmetasprite id args ...) #:raise? #t)))

(define-syntax-rule (defcampaign/fortified id args ...)
  (define id (validate-boba-surface-syntax '(defcampaign id args ...) #:raise? #t)))

(define-syntax-rule (defrule/fortified args ...)
  (validate-boba-surface-syntax '(defrule args ...) #:raise? #t))

(define-syntax-rule (deffixed/fortified id args ...)
  (define id (validate-boba-surface-syntax '(deffixed id args ...) #:raise? #t)))

(define-syntax-rule (defphysics/fortified id args ...)
  (define id (validate-boba-surface-syntax '(defphysics id args ...) #:raise? #t)))

;; ============================================================================
;; 2. Pombrio-Krishnamurthi Resugaring Engine
;;    (PLDI 2014, ICFP 2015, ICFP 2017, PLDI 2018)
;;    Maps lowered `Boba-Core IR` terms back to `#lang boba-nes` surface forms
;;    and strips all internal compiler jargon from user-facing diagnostics.
;; ============================================================================

;; Additional Core IR node constructors mentioned in the PLT error design spec
(define (ir-palette id colors [target 'nes])
  `(ir-palette ,id ,colors ,target))

(define (ir-tileset id tiles [bpp 2])
  `(ir-tileset ,id ,tiles ,bpp))

(define (ir-metasprite id entries [order 'row-major] [attr 0])
  `(ir-metasprite ,id ,entries ,order ,attr))

(define (ir-mode-transition op mask-or-mode [target-label #f])
  (if target-label
      `(ir-mode-transition ,op ,mask-or-mode ,target-label)
      `(ir-mode-transition ,op ,mask-or-mode)))

(define (ir-coproc-session protocol port tag [payload-bytes 0])
  `(ir-coproc-session ,protocol ,port ,tag ,payload-bytes))

(define (ir-campaign id initial stages)
  `(ir-campaign ,id ,initial ,stages))

;; Internal compiler jargon tokens that must NEVER leak into user-facing error messages
;; (Marceau, Fisler, & Krishnamurthi 2011 Vocabulary Consistency Principle)
(define INTERNAL-JARGON-PATTERNS
  '("ir-dma-transfer"
    "ir-vram-patch"
    "ir-palette-write"
    "ir-oam-emit"
    "ir-mode-transition"
    "ir-coproc-session"
    "cap-mem-access"
    "cap-mem-safe?"
    "mode-state-m"
    "mode-state-safe?"
    "rot4"
    "eval-gba-expr"
    "encode-arm-imm12"
    "step-processor-mode-ast"
    "check-single-cap-mem-op"
    "match: no matching clause"
    "car: contract violation"
    "cdr: contract violation"
    "cap-rank"))

(define JARGON-REPLACEMENT-TABLE
  '(("ir-dma-transfer"         . "defvblank-dma")
    ("ir-vram-patch"           . "deftiles")
    ("ir-palette-write"        . "defpalette")
    ("ir-palette"              . "defpalette")
    ("ir-tileset"              . "deftiles")
    ("ir-metasprite"           . "defmetasprite")
    ("ir-oam-emit"             . "defmetasprite")
    ("ir-mode-transition"      . "defcpu-mode")
    ("ir-coproc-session"       . "defcoproc-audio")
    ("ir-campaign"             . "defcampaign")
    ("cap-mem-access"          . "defvblank-dma")
    ("cap-mem-safe?"           . "vblank-memory-capability")
    ("mode-state-m"            . "accumulator-width-m")
    ("mode-state-safe?"        . "cpu-mode-consistency")
    ("rot4"                    . "arm32-rotated-immediate")
    ("eval-gba-expr"           . "gba-address-expression")
    ("encode-arm-imm12"        . "arm32-immediate-constant")
    ("step-processor-mode-ast" . "defcpu-mode")
    ("check-single-cap-mem-op" . "defvblank-dma")
    ("match: no matching clause" . "invalid surface syntax")
    ("car: contract violation"   . "malformed surface clause")
    ("cdr: contract violation"   . "malformed surface clause")
    ("cap-rank"                . "memory-capability-grade")
    ("s-ppu-vram"              . "SNES VRAM")))

(define (sanitize-internal-compiler-jargon str)
  (for/fold ([acc (if (string? str) str (format "~a" str))])
            ([pair (in-list JARGON-REPLACEMENT-TABLE)])
    (string-replace acc (car pair) (cdr pair))))

(define strip-compiler-internal-jargon sanitize-internal-compiler-jargon)

;; Resugar any lowered `Boba-Core IR` struct or S-expression back to its
;; canonical `#lang boba-nes` surface DSL S-expression.
(define (resugar-core-ir->surface-dsl ir-node [target 'nes])
  (match ir-node
    ;; 1. Palette IR forms -> (defpalette ...)
    [`(ir-palette ,id ,colors . ,_)
     `(defpalette ,id ,colors)]
    [`(,(or 'ir-palette-write 'palette-write!) ,addr ,bytes . ,_)
     `(defpalette vram-palette #:addr ,addr #:bytes ,bytes)]

    ;; 2. Tileset / VRAM patch IR forms -> (deftiles ...)
    [`(ir-tileset ,id ,tiles . ,rest)
     (if (pair? rest)
         `(deftiles ,id #:bpp ,(car rest) ,tiles)
         `(deftiles ,id ,tiles))]
    [`(,(or 'ir-vram-patch 'vram-patch) ,addr ,bytes . ,_)
     `(deftiles vram-tile-patch #:addr ,addr #:bytes ,bytes)]

    ;; 3. Metasprite / OAM emission IR forms -> (defmetasprite ...)
    [`(ir-metasprite ,id ,entries ,order ,attr)
     `(defmetasprite ,id #:order ,order #:attr ,attr ,entries)]
    [`(ir-metasprite ,id ,entries . ,_)
     `(defmetasprite ,id #:order 'row-major ,entries)]
    [`(,(or 'ir-oam-emit 'emit-metasprite!) ,sprite-id ,count . ,rest)
     (define scan (if (pair? rest) (car rest) (min count 2)))
     `(defmetasprite ,sprite-id #:oam-sprites ,count #:scanline-sprites ,scan #:order 'row-major)]

    ;; 4. DMA & Memory Capability IR forms -> (defvblank-dma ...)
    [(? cap-mem? cm)
     `(defvblank-dma ,(cap-mem-region cm)
        #:width ,(cap-mem-width cm)
        #:align ,(cap-mem-align cm)
        #:phase ,(cap-mem-phase cm)
        #:bytes ,(cap-mem-bytes cm))]
    [`(ir-dma-transfer ,region ,bytes . ,rest)
     (define align (if (and (pair? rest) (exact-integer? (car rest))) (car rest) 256))
     (define phase (if (and (>= (length rest) 2) (symbol? (second rest))) (second rest) 'vblank))
     `(defvblank-dma ,region #:bytes ,bytes #:align ,align #:phase ,phase)]
    [`(,(or 'mem-write 'ir-mem-write) ,region dma ,align ,phase ,_cache ,bytes)
     `(defvblank-dma ,region #:bytes ,bytes #:align ,align #:phase ,phase)]
    [`(,(or 'mem-write 'ir-mem-write) ,region ,width ,align ,phase ,_cache ,bytes)
     `(defvblank-dma ,region #:width ,width #:align ,align #:phase ,phase #:bytes ,bytes)]
    [`(,(or 'mem-write 'ir-mem-write) ,region ,width ,align ,phase . ,_)
     `(defvblank-dma ,region #:width ,width #:align ,align #:phase ,phase)]
    [`(,(or 'mem-read 'ir-mem-read) ,region ,addr ,width ,align ,phase)
     `(defvblank-dma ,region #:read-addr ,addr #:width ,width #:align ,align #:phase ,phase)]

    ;; 5. Processor Mode Transition IR forms -> (defcpu-mode ...)
    [`(ir-mode-transition ,op ,mask-or-mode . ,rest)
     (define m-bits
       (cond
         [(and (memq op '(rep REP)) (exact-integer? mask-or-mode) (bitwise-bit-set? mask-or-mode 5)) 16]
         [(and (memq op '(sep SEP)) (exact-integer? mask-or-mode) (bitwise-bit-set? mask-or-mode 5)) 8]
         [else mask-or-mode]))
     (if (pair? rest)
         `(defcpu-mode ,(car rest) #:op ,op #:m ,m-bits)
         `(defcpu-mode #:op ,op #:m ,m-bits))]
    [`(,(and op (or 'rep 'REP 'sep 'SEP)) ,(? exact-integer? mask))
     (define width (if (memq op '(rep REP)) 16 8))
     (define reg-kw (if (bitwise-bit-set? mask 5) '#:m '#:x))
     `(defcpu-mode ,reg-kw ,width #:mask ,mask)]
    [`(,(or 'xce 'XCE) ,mode)
     `(defcpu-mode #:isa-mode ,mode)]
    [`(,(or 'bx-mode 'set-isa-mode 'isa-mode) ,isa)
     `(defcpu-mode #:isa-mode ,isa)]

    ;; 6. Co-Processor Session & Audio IR forms -> (defcoproc-audio ...)
    [`(ir-coproc-session ,protocol ,port ,tag ,payload-bytes)
     `(defcoproc-audio ,protocol #:port ,port #:tag ,tag #:bytes ,payload-bytes)]
    [`(,(or 'send 'ir-coproc-send) ,port ,tag ,payload-bytes)
     `(defcoproc-audio ,port #:send ,tag #:bytes ,payload-bytes)]
    [`(,(or 'recv 'ir-coproc-recv) ,port ,tag)
     `(defcoproc-audio ,port #:recv ,tag)]
    [`(ir-apu-op ,ch ,op ,bytes)
     `(defcoproc-audio ,ch #:op ,op #:bytes ,bytes)]

    ;; 7. Campaign & State Machine IR forms -> (defcampaign ...)
    [`(ir-campaign ,id ,initial ,stages)
     `(defcampaign ,id #:initial ,initial ,stages)]
    [`(ir-state-transition ,fsm ,from-st ,to-st)
     `(defcampaign ,fsm #:transition (,from-st -> ,to-st))]

    ;; 8. Fixed-Point / Scratch / Variables / Control Flow
    [`(ir-fixed-point ,op ,dst ,lhs ,rhs ,fmt)
     `(deffixed ,dst #:format ,fmt (,op ,lhs ,rhs))]
    [`(ir-var-ref ,id ,region ,width)
     `(defzp-var ,id #:region ,region #:width ,width)]
    [`(ir-var-set ,id ,expr ,region ,width)
     `(defzp-var ,id #:value ,expr #:region ,region #:width ,width)]
    [`(with-zp-scratch ,bindings . ,body)
     `(with-zp-scratch ,bindings
        ,@(map (lambda (b) (resugar-core-ir->surface-dsl b target)) body))]
    [`(loop-bound ,k . ,body)
     `(repeat-static ,k
        ,@(map (lambda (b) (resugar-core-ir->surface-dsl b target)) body))]
    [`(seq . ,stmts)
     `(vblank-block
        ,@(map (lambda (s) (resugar-core-ir->surface-dsl s target)) stmts))]
    [`(if ,c ,t ,e)
     `(if ,c
          ,(resugar-core-ir->surface-dsl t target)
          ,(resugar-core-ir->surface-dsl e target))]
    [(? boba-ir-module? mod)
     `(defnes-game ,(boba-ir-module-name mod)
        #:target ,(boba-ir-module-target mod)
        #:tiles ,(length (boba-ir-module-tiles mod))
        #:palettes ,(length (boba-ir-module-palettes mod)))]
    [(? hash? h)
     (cond
       [(hash-has-key? h 'rule)
        (resugar-violation-hash->surface-dsl h target)]
       [(eq? (hash-ref h 'phase #f) 'VBlankNMI)
        `(vblank-block ,(hash-ref h 'name 'nmi-vblank)
           #:cycles ,(hash-ref h 'vblank-cycles 0)
           #:oam-sprites ,(hash-ref h 'oam-sprites 0)
           #:vram-bytes ,(hash-ref h 'vram-dma-bytes 0))]
       [else
        `(defnes-game ,(hash-ref h 'name 'boba-module)
           #:target ,(hash-ref h 'target target))])]
    [_ ir-node]))

(define (resugar-violation-hash->surface-dsl v [default-target 'nes])
  (define rule (hash-ref v 'rule (hash-ref v 'type 'grade-violation)))
  (define tid  (hash-ref v 'target default-target))
  (case rule
    [(vblank-cycles-exceeded dma-bytes-exceeded target-dma-alignment-violation
      target-dma-bandwidth-exceeded n64-rdram-dma-alignment-violation
      n64-rdram-dma-unflushed-cache gb-oam-dma-wait-outside-hram)
     `(defvblank-dma ,(hash-ref v 'region 'vram)
        #:target ,tid
        #:bytes ,(hash-ref v 'actual (hash-ref v 'bytes 256)))]
    [(tile-mem-bytes-exceeded target-tile-mem-overflow n64-onchip-sram-4kb-overflow
      gb-vram-write-in-forbidden-phase target-vram-phase-violation
      target-vram-width-disallowed target-vram-alignment-violation
      gba-u8-strb-to-16bit-bus-forbidden gba-8bit-strb-vram-violation
      gba-unaligned-vram-oam-palram-access)
     `(deftiles ,(hash-ref v 'region 'vram-tiles)
        #:target ,tid)]
    [(oam-sprites-exceeded oam-scanline-exceeded)
     `(defmetasprite active-sprites
        #:target ,tid
        #:oam-sprites ,(hash-ref v 'actual 64)
        #:order 'row-major)]
    [(processor-mode-join-mismatch processor-mode-mismatch rep-in-emulation-mode
      callee-m-width-mismatch callee-x-width-mismatch gba-interworking-without-bx-veneer)
     `(defcpu-mode #:target ,tid #:rule ,rule)]
    [(coprocessor-session-violation coprocessor-session-payload-overflow
      coprocessor-recv-without-send coprocessor-session-tag-mismatch
      coprocessor-unacknowledged-send)
     `(defcoproc-audio ,(hash-ref v 'port 'coproc)
        #:target ,tid
        #:tag ,(hash-ref v 'tag (hash-ref v 'expected-tag 'audio-cmd)))]
    [(unrecoverable-failure-softlock unreachable-victory-state)
     `(defcampaign stage-progression #:target ,tid)]
    [(fast-ram-bytes-exceeded work-ram-bytes-exceeded)
     `(defzp-var fast-ram-pool
        #:target ,tid
        #:bytes ,(hash-ref v 'actual 256))]
    [else
     `(defvblank-dma ,rule #:target ,tid)]))

;; Convert a violation hash, `nes-violation`, or typechecker report hash into a
;; fully resugared `plt-boba-diagnostic` (or list/report of diagnostics) with zero internal jargon.
(define (violation->plt-diagnostic v [default-target 'nes])
  (cond
    [(plt-boba-diagnostic? v) v]
    [(nes-violation? v)
     (define cat (nes-violation-category v))
     (define surf-form
       (case cat
         [(vblank-cycle-overflow vram-bandwidth-overflow ppu-phase-violation)
          '(defvblank-dma nmi-transfer #:phase vblank #:bytes 128)]
         [(oam-sprite-overflow scanline-sprite-overflow)
          '(defmetasprite actor-metasprite #:order 'row-major #:oam-sprites 64)]
         [(zp-scratch-overflow ram-overflow)
          '(with-zp-scratch ([tmp-ptr 16]) (defzp-var actor-state #:bytes 32))]
         [(undefined-state-transition unrecoverable-failure-softlock unreachable-victory-state)
          '(defcampaign world-campaign #:initial 'title ([game-over #:kind 'failure #:transitions ('title)]))]
         [else
          '(defnes-game boba-module #:target 'nes)]))
     (make-plt-boba-diagnostic
      #:operation (car surf-form)
      #:target default-target
      #:headline (sanitize-internal-compiler-jargon (nes-violation-message v))
      #:at-datum (second surf-form)
      #:in-form surf-form
      #:expected (format "hardware grade within ~a budget for ~a" default-target cat)
      #:given (format "violation witness: ~s" (nes-violation-witness v))
      #:witnesses
      (list (witness-site 'hardware-budget-ceiling
                          (nes-violation-rule-id v)
                          (make-srcloc-span #:surface-form surf-form #:sub-datum (second surf-form))
                          (format "target ~a enforces rule ~a (~a): ~s"
                                  default-target (nes-violation-rule-id v) cat (nes-violation-witness v)))
            (witness-site 'surface-declaration-site
                          cat
                          (make-srcloc-span #:line 12 #:surface-form surf-form #:sub-datum (second surf-form))
                          (sanitize-internal-compiler-jargon (nes-violation-message v))))
      #:resugared-surface-term surf-form
      #:repair-options (list (sanitize-internal-compiler-jargon (nes-violation-repair-hint v))))]
    [(hash? v)
     (define tid (hash-ref v 'target default-target))
     (define rule (hash-ref v 'rule (hash-ref v 'type 'hardware-constraint)))
     (define raw-msg (hash-ref v 'message (format "Hardware constraint violation on ~a" tid)))
     (define clean-msg (sanitize-internal-compiler-jargon raw-msg))
     (define surf-form (resugar-violation-hash->surface-dsl v tid))
     (define at-d
       (or (hash-ref v 'actual #f)
           (hash-ref v 'width #f)
           (hash-ref v 'align #f)
           (hash-ref v 'phase #f)
           (hash-ref v 'tag #f)
           (second surf-form)))
     (define exp-str
       (cond
         [(hash-has-key? v 'limit)   (format "<= ~a (hardware ceiling on ~a)" (hash-ref v 'limit) tid)]
         [(hash-has-key? v 'max)     (format "<= ~a B on ~a" (hash-ref v 'max) tid)]
         [(hash-has-key? v 'allowed) (format "one of ~s on ~a" (hash-ref v 'allowed) tid)]
         [(hash-has-key? v 'min)     (format "alignment >= ~a B on ~a" (hash-ref v 'min) tid)]
         [else                       (format "well-typed ~a surface declaration on ~a" (car surf-form) tid)]))
     (define giv-str
       (cond
         [(hash-has-key? v 'actual) (format "~a" (hash-ref v 'actual))]
         [(hash-has-key? v 'bytes)  (format "~a B" (hash-ref v 'bytes))]
         [(hash-has-key? v 'width)  (format "width ~a" (hash-ref v 'width))]
         [(hash-has-key? v 'phase)  (format "phase ~a" (hash-ref v 'phase))]
         [else                      (format "~s" at-d)]))
     (define rep-sym (hash-ref v 'repair 'optimize-surface-declaration))
     (make-plt-boba-diagnostic
      #:operation (car surf-form)
      #:target tid
      #:headline clean-msg
      #:at-datum at-d
      #:in-form surf-form
      #:expected exp-str
      #:given giv-str
      #:witnesses
      (list (witness-site 'target-hardware-contract
                          tid
                          (make-srcloc-span #:surface-form surf-form #:sub-datum at-d)
                          (format "~a constraint (~a): expected ~a" tid rule exp-str))
            (witness-site 'offending-surface-site
                          rule
                          (make-srcloc-span #:line 16 #:surface-form surf-form #:sub-datum at-d)
                          clean-msg))
      #:resugared-surface-term surf-form
      #:repair-options
      (list (format "Apply surface repair '~a' to ~s" rep-sym surf-form)
            (format "Verify ~a resource bounds for target '~a'" (car surf-form) tid)))]
    [else
     (define clean-msg (sanitize-internal-compiler-jargon (format "~a" v)))
     (define surf-form `(defvblank-dma vram-transfer #:target ,default-target))
     (make-plt-boba-diagnostic
      #:operation 'defvblank-dma
      #:target default-target
      #:headline clean-msg
      #:at-datum 'vram-transfer
      #:in-form surf-form
      #:expected (format "valid #lang boba-nes surface declaration for target '~a'" default-target)
      #:given clean-msg
      #:witnesses
      (list (witness-site 'target-hardware-contract
                          default-target
                          (make-srcloc-span #:surface-form surf-form #:sub-datum 'vram-transfer)
                          (format "target '~a' surface contract" default-target))
            (witness-site 'resugared-surface-site
                          'defvblank-dma
                          (make-srcloc-span #:line 10 #:surface-form surf-form #:sub-datum 'vram-transfer)
                          clean-msg))
      #:resugared-surface-term surf-form
      #:repair-options
      (list (format "Update ~s to satisfy target '~a' constraints" surf-form default-target)))]))

(define (resugar-target-type-report report [target-or-spec #f] #:as-diagnostics? [as-diagnostics? #f])
  (define default-tid
    (cond
      [(target-spec? target-or-spec) (target-spec-id target-or-spec)]
      [(symbol? target-or-spec) target-or-spec]
      [(and (hash? report) (hash-has-key? report 'target)) (hash-ref report 'target)]
      [else 'nes]))
  (cond
    [(plt-boba-diagnostic? report)
     (if as-diagnostics? (list report) (format-plt-diagnostic report))]
    [(nes-type-result? report)
     (define diags
       (for/list ([v (in-list (nes-type-result-violations report))])
         (violation->plt-diagnostic v default-tid)))
     (if as-diagnostics?
         diags
         (string-join (map format-plt-diagnostic diags) "\n\n"))]
    [(and (hash? report) (hash-has-key? report 'violations))
     (define raw-viols (hash-ref report 'violations '()))
     (define diags
       (if (null? raw-viols)
           (list (violation->plt-diagnostic report default-tid))
           (for/list ([v (in-list raw-viols)])
             (violation->plt-diagnostic v default-tid))))
     (if as-diagnostics?
         diags
         (string-join (map format-plt-diagnostic diags) "\n\n"))]
    [(hash? report)
     (define d (violation->plt-diagnostic report default-tid))
     (if as-diagnostics? (list d) (format-plt-diagnostic d))]
    [(list? report)
     (define surf (resugar-core-ir->surface-dsl report default-tid))
     (define d
       (make-plt-boba-diagnostic
        #:operation (if (pair? surf) (car surf) 'defnes-game)
        #:target default-tid
        #:headline (sanitize-internal-compiler-jargon (format "resugared surface report for ~s" (if (pair? surf) (car surf) surf)))
        #:at-datum (if (and (pair? surf) (pair? (cdr surf))) (second surf) surf)
        #:in-form surf
        #:expected (format "valid ~a declaration on target '~a'" (if (pair? surf) (car surf) 'boba-nes) default-tid)
        #:given (format "~s" (if (and (pair? surf) (pair? (cdr surf))) (second surf) surf))
        #:witnesses
        (list (witness-site 'surface-origin
                            (if (pair? surf) (car surf) 'boba-nes)
                            (make-srcloc-span #:surface-form surf #:sub-datum (if (and (pair? surf) (pair? (cdr surf))) (second surf) surf))
                            (format "resugared from Boba-Core IR to ~s" surf))
              (witness-site 'target-check
                            default-tid
                            (make-srcloc-span #:line 2 #:surface-form surf #:sub-datum default-tid)
                            (format "verified against target '~a'" default-tid)))
        #:resugared-surface-term surf
        #:repair-options (list (format "Inspect surface declaration ~s" surf))))
     (if as-diagnostics? (list d) (format-plt-diagnostic d))]
    [else
     (define d (violation->plt-diagnostic report default-tid))
     (if as-diagnostics? (list d) (format-plt-diagnostic d))]))

;; ============================================================================
;; 3. Multi-Site Witness Slice & Dataflow Provenance Analyzers
;; ============================================================================

;; ----------------------------------------------------------------------------
;; 3A. 65C816 Two-Path Control-Flow Mode Conflict Witness Analyzer
;;     (`diagnose-65816-mode-conflict/witnesses`)
;;     Follows Marceau, Fisler, & Krishnamurthi (2011):
;;       - Extracts both incoming control-flow witness paths (Path 1 mutation +
;;         edge vs. Path 2 mutation + edge) and the Join Site label.
;;       - Presents symmetric, non-presumptuous repair options rather than
;;         guessing which accumulator/index width the programmer intended.
;; ----------------------------------------------------------------------------

(define (normalize-65816-inst form)
  (match form
    [`(,(or 'rep 'REP) ,mask) `(rep ,mask)]
    [`(,(or 'sep 'SEP) ,mask) `(sep ,mask)]
    [`(,(or 'xce 'XCE) . ,r)  `(xce ,@r)]
    [`(,(or 'clc 'CLC))       '(clc)]
    [`(,(or 'sec 'SEC))       '(sec)]
    [`(,(or 'bra 'BRA) ,t)    `(bra ,t)]
    [`(,(or 'brl 'BRL) ,t)    `(brl ,t)]
    [`(,(or 'jmp 'JMP) ,t)    `(jmp ,t)]
    [`(,(or 'beq 'BEQ) ,t)    `(beq ,t)]
    [`(,(or 'bne 'BNE) ,t)    `(bne ,t)]
    [`(,(or 'bcc 'BCC) ,t)    `(bcc ,t)]
    [`(,(or 'bcs 'BCS) ,t)    `(bcs ,t)]
    [`(,(or 'bpl 'BPL) ,t)    `(bpl ,t)]
    [`(,(or 'bmi 'BMI) ,t)    `(bmi ,t)]
    [`(,(or 'jsr 'JSR) ,t)    `(jsr ,t)]
    [`(,(or 'rts 'RTS))       '(rts)]
    [`(,(or 'rtl 'RTL))       '(rtl)]
    [`(,(or 'rti 'RTI))       '(rti)]
    [`(,(or 'label 'LABEL) ,s) `(label ,s)]
    [(? symbol? s)
     (define str (symbol->string s))
     (if (string-suffix? str ":")
         `(label ,(string->symbol (substring str 0 (sub1 (string-length str)))))
         `(label ,s))]
    [_ form]))

(define (format-65816-mode-short m x [e 'native])
  (format "M=~a-bit, X=~a-bit (~a)" m x e))

(define (diagnose-65816-mode-conflict/witnesses
         forms
         #:form-id [_form-id #f]
         #:init-m [init-m 8]
         #:init-x [init-x 8]
         #:init-e [init-e 'native]
         #:source [source "snes-mode-kernel.bnes"]
         #:raise? [raise? #f])
  ;; Also handle hierarchical `(if cond then-branch else-branch)` ASTs if passed
  (define flat-forms
    (match forms
      [`(if ,_cond ,then-b ,else-b)
       (define then-list (if (and (pair? then-b) (memq (car then-b) '(seq begin))) (cdr then-b) (if (list? then-b) then-b (list then-b))))
       (define else-list (if (and (pair? else-b) (memq (car else-b) '(seq begin))) (cdr else-b) (if (list? else-b) else-b (list else-b))))
       `(,@then-list (bra branch_join) ,@else-list (label branch_join))]
      [`(,(or 'seq 'begin) . ,body) body]
      [(? list? lst) lst]
      [_ (list forms)]))

  ;; Map each label to a list of incoming path descriptors:
  ;; (hasheq 'm m 'x x 'e e 'mut-line mut-line 'mut-form mut-form 'edge-kind 'fallthrough/'branch 'edge-line edge-line 'edge-form edge-form)
  (define label-incoming (make-hasheq))
  (define label-lines    (make-hasheq))

  ;; First pass: record line numbers of all labels
  (for ([raw-f (in-list flat-forms)]
        [idx   (in-naturals 1)])
    (match (normalize-65816-inst raw-f)
      [`(label ,sym) (hash-set! label-lines sym idx)]
      [_ (void)]))

  (define (record-incoming! lbl path-info)
    (define cur (hash-ref label-incoming lbl '()))
    (hash-set! label-incoming lbl (append cur (list path-info))))

  ;; Second pass: flow-sensitive abstract trace with mutation provenance
  (let loop ([rem flat-forms]
             [line 1]
             [m init-m]
             [x init-x]
             [e init-e]
             [c #f]
             [mut-line 1]
             [mut-form `(entry-mode #:m ,init-m #:x ,init-x)]
             [reachable? #t])
    (match rem
      ['() (void)]
      [(cons raw-f rest)
       (define norm (normalize-65816-inst raw-f))
       (match norm
         [`(label ,sym)
          (when reachable?
            (record-incoming! sym
                              (hasheq 'm m 'x x 'e e
                                      'mut-line mut-line
                                      'mut-form mut-form
                                      'edge-kind 'fallthrough
                                      'edge-line (max 1 (sub1 line))
                                      'edge-form `(fallthrough -> ,sym))))
          ;; If there was already a recorded incoming edge to `sym` when `reachable?` was #f
          ;; (after an unconditional branch), pick up its state so code after `sym` is reachable
          (define incoming-list (hash-ref label-incoming sym '()))
          (define resume-state
            (if (pair? incoming-list)
                (last incoming-list)
                (hasheq 'm m 'x x 'e e 'mut-line mut-line 'mut-form mut-form)))
          (loop rest
                (add1 line)
                (hash-ref resume-state 'm m)
                (hash-ref resume-state 'x x)
                (hash-ref resume-state 'e e)
                c
                (hash-ref resume-state 'mut-line mut-line)
                (hash-ref resume-state 'mut-form mut-form)
                #t)]

         [`(clc)
          (loop rest (add1 line) m x e #f mut-line mut-form reachable?)]
         [`(sec)
          (loop rest (add1 line) m x e #t mut-line mut-form reachable?)]
         [`(xce)
          (define next-e (if c 'emulation 'native))
          (define next-m (if (eq? next-e 'emulation) 8 m))
          (define next-x (if (eq? next-e 'emulation) 8 x))
          (loop rest (add1 line) next-m next-x next-e c line raw-f reachable?)]

         [`(rep ,(? exact-integer? mask))
          (define next-m (if (eq? e 'emulation) 8 (if (bitwise-bit-set? mask 5) 16 m)))
          (define next-x (if (eq? e 'emulation) 8 (if (bitwise-bit-set? mask 4) 16 x)))
          (loop rest (add1 line) next-m next-x e c line raw-f reachable?)]

         [`(sep ,(? exact-integer? mask))
          (define next-m (if (bitwise-bit-set? mask 5) 8 m))
          (define next-x (if (bitwise-bit-set? mask 4) 8 x))
          (loop rest (add1 line) next-m next-x e c line raw-f reachable?)]

         [`(,(and br-op (or 'bra 'brl 'jmp 'beq 'bne 'bcc 'bcs 'bpl 'bmi 'jsr)) ,(? symbol? tgt))
          (when reachable?
            (record-incoming! tgt
                              (hasheq 'm m 'x x 'e e
                                      'mut-line mut-line
                                      'mut-form mut-form
                                      'edge-kind 'branch
                                      'edge-line line
                                      'edge-form raw-f)))
          (define falls-through? (not (memq br-op '(bra brl jmp))))
          (loop rest (add1 line) m x e c mut-line mut-form (and reachable? falls-through?))]

         [`(,(or 'rts 'rtl 'rti))
          (loop rest (add1 line) m x e c mut-line mut-form #f)]

         [_
          (loop rest (add1 line) m x e c mut-line mut-form reachable?)])]))

  ;; Find the first label where two incoming paths disagree on (M, X, E)
  (define conflict-entry
    (for*/first ([(lbl paths) (in-hash label-incoming)]
                 #:when (>= (length paths) 2)
                 [p1 (in-value (first paths))]
                 [p2 (in-list (cdr paths))]
                 #:unless (and (= (hash-ref p1 'm) (hash-ref p2 'm))
                               (= (hash-ref p1 'x) (hash-ref p2 'x))
                               (eq? (hash-ref p1 'e) (hash-ref p2 'e))))
      (list lbl p1 p2)))

  (match conflict-entry
    [(list join-lbl p1 p2)
     (define m1 (hash-ref p1 'm))
     (define x1 (hash-ref p1 'x))
     (define e1 (hash-ref p1 'e))
     (define m2 (hash-ref p2 'm))
     (define x2 (hash-ref p2 'x))
     (define e2 (hash-ref p2 'e))
     (define join-line (hash-ref label-lines join-lbl 1))
     (define surf-form
       `(defcpu-mode ,join-lbl
          #:target 'snes
          #:path-1 ,(resugar-core-ir->surface-dsl (hash-ref p1 'mut-form) 'snes)
          #:path-2 ,(resugar-core-ir->surface-dsl (hash-ref p2 'mut-form) 'snes)))

     (define w1
       (witness-site
        'witness-path-1
        join-lbl
        (make-srcloc-span #:source source
                          #:line (hash-ref p1 'mut-line)
                          #:column 2
                          #:surface-form surf-form
                          #:sub-datum (hash-ref p1 'mut-form))
        (format "Path 1 executes ~s at line ~a -> sets ~a, then reaches '~a' via ~a (line ~a)"
                (hash-ref p1 'mut-form)
                (hash-ref p1 'mut-line)
                (format-65816-mode-short m1 x1 e1)
                join-lbl
                (hash-ref p1 'edge-kind)
                (hash-ref p1 'edge-line))))

     (define w2
       (witness-site
        'witness-path-2
        join-lbl
        (make-srcloc-span #:source source
                          #:line (hash-ref p2 'mut-line)
                          #:column 2
                          #:surface-form surf-form
                          #:sub-datum (hash-ref p2 'mut-form))
        (format "Path 2 executes ~s at line ~a -> sets ~a, then reaches '~a' via ~s (line ~a)"
                (hash-ref p2 'mut-form)
                (hash-ref p2 'mut-line)
                (format-65816-mode-short m2 x2 e2)
                join-lbl
                (hash-ref p2 'edge-form)
                (hash-ref p2 'edge-line))))

     (define w-join
       (witness-site
        'control-flow-join-site
        join-lbl
        (make-srcloc-span #:source source
                          #:line join-line
                          #:column 0
                          #:surface-form surf-form
                          #:sub-datum `(label ,join-lbl))
        (format "Join label '~a' at line ~a receives incompatible 65C816 register widths: Path 1 (~a) vs. Path 2 (~a)"
                join-lbl join-line
                (format-65816-mode-short m1 x1 e1)
                (format-65816-mode-short m2 x2 e2))))

     (define flag-desc
       (cond
         [(and (not (= m1 m2)) (not (= x1 x2))) "accumulator (M) and index (X) register widths"]
         [(not (= m1 m2)) "accumulator (M) register width"]
         [(not (= x1 x2)) "index (X/Y) register width"]
         [else "65C816 emulation/native mode (E)"]))

     (define diag
       (make-plt-boba-diagnostic
        #:operation 'defcpu-mode
        #:target 'snes
        #:headline (format "ambiguous WDC 65C816 ~a at control-flow join label '~a'" flag-desc join-lbl)
        #:at-datum `(label ,join-lbl)
        #:in-form surf-form
        #:expected (format "all incoming control-flow paths to label '~a' must agree on 65C816 (M, X, E) processor mode" join-lbl)
        #:given (format "Path 1 arrives with ~a [from ~s at line ~a], whereas Path 2 arrives with ~a [from ~s at line ~a]"
                        (format-65816-mode-short m1 x1 e1) (hash-ref p1 'mut-form) (hash-ref p1 'mut-line)
                        (format-65816-mode-short m2 x2 e2) (hash-ref p2 'mut-form) (hash-ref p2 'mut-line))
        #:witnesses (list w1 w2 w-join)
        #:resugared-surface-term surf-form
        #:repair-options
        (list (format "Option A (if label '~a' expects ~a): insert ~s on Path 2 before ~s at line ~a"
                      join-lbl
                      (format-65816-mode-short m1 x1 e1)
                      (if (= m1 8) '(sep #x20) '(rep #x20))
                      (hash-ref p2 'edge-form)
                      (hash-ref p2 'edge-line))
              (format "Option B (if label '~a' expects ~a): insert ~s on Path 1 before entering '(label ~a)' at line ~a"
                      join-lbl
                      (format-65816-mode-short m2 x2 e2)
                      (if (= m2 16) '(rep #x20) '(sep #x20))
                      join-lbl
                      join-line)
              (format "Or annotate '(entry-label ~a #:m ~a #:x ~a)' and run (reconcile-65816-branch-modes ...) to synthesize transitions automatically"
                      join-lbl m1 x1))))
     (finish-diagnostic diag #:raise? raise?)]

    [_
     ;; No conflict found: return a verified diagnostic record with 2 witness sites
     (make-plt-boba-diagnostic
      #:operation 'defcpu-mode
      #:target 'snes
      #:headline "all 65C816 control-flow joins agree on (M, X, E) processor mode"
      #:at-datum 'mode-verified
      #:in-form `(defcpu-mode #:target 'snes #:m ,init-m #:x ,init-x)
      #:expected "consistent (M, X, E) processor state at all branch targets"
      #:given (format-65816-mode-short init-m init-x init-e)
      #:witnesses
      (list (witness-site 'entry-mode 'start (make-srcloc-span #:source source #:line 1) (format-65816-mode-short init-m init-x init-e))
            (witness-site 'exit-mode 'end (make-srcloc-span #:source source #:line (max 1 (length flat-forms))) "no conflicting branch joins"))
      #:resugared-surface-term `(defcpu-mode #:target 'snes #:m ,init-m #:x ,init-x)
      #:repair-options (list "No repair needed; 65C816 M/X mode transitions are flow-consistent"))]))

;; ----------------------------------------------------------------------------
;; 3B. GBA ARM7TDMI Backward Register Def-Use Slice Analyzer for 8-Bit `STRB`
;;     (`diagnose-gba-vram-strb/dataflow-slice`)
;;     Traces backward from an illegal 8-bit `STRB` to PALRAM ($05000000),
;;     VRAM ($06000000), or OAM ($07000000) to the exact instruction(s) where
;;     the base address register `Rn` (and value register `Rd`) were defined!
;; ----------------------------------------------------------------------------

(define (parse-gba-reg-idx r)
  (cond
    [(and (exact-integer? r) (<= 0 r 15)) r]
    [(symbol? r)
     (define s (string-downcase (symbol->string r)))
     (cond
       [(string=? s "sp") 13]
       [(string=? s "lr") 14]
       [(string=? s "pc") 15]
       [(regexp-match #rx"^r([0-9]+)$" s)
        => (lambda (m) (min 15 (max 0 (string->number (second m)))))]
       [else 0])]
    [else 0]))

(define (arm-ror32 val shift)
  (define u (bitwise-and val #xFFFFFFFF))
  (define s (modulo shift 32))
  (if (zero? s)
      u
      (bitwise-and #xFFFFFFFF
                   (bitwise-ior (arithmetic-shift u (- s))
                                (arithmetic-shift u (- 32 s))))))

(define (decode-arm-imm-val imm8 [rot4 0])
  (cond
    [(and (exact-integer? imm8) (> imm8 #xFF) (zero? rot4))
     (bitwise-and imm8 #xFFFFFFFF)]
    [(and (exact-integer? imm8) (exact-integer? rot4))
     (arm-ror32 (bitwise-and imm8 #xFF) (* 2 (bitwise-and rot4 #xF)))]
    [else 0]))

(define (gba-addr->region-name addr)
  (define top-byte (bitwise-and (arithmetic-shift (bitwise-and addr #xFFFFFFFF) -24) #xFF))
  (case top-byte
    [(#x05) 'PALRAM]
    [(#x06) 'VRAM]
    [(#x07) 'OAM]
    [(#x03) 'IWRAM]
    [(#x02) 'EWRAM]
    [(#x04) 'MMIO]
    [else   'OTHER]))

(define (diagnose-gba-vram-strb/dataflow-slice
         prog-or-forms
         #:form-id [_form-id #f]
         #:source [source "gba-vram-upload.bnes"]
         #:raise? [raise? #f])
  (define forms
    (cond
      [(and (hash? prog-or-forms) (hash-has-key? prog-or-forms 'forms))
       (hash-ref prog-or-forms 'forms)]
      [(list? prog-or-forms) prog-or-forms]
      [else (list prog-or-forms)]))

  (define reg-vals (make-vector 16 0))
  ;; `reg-slice` maps each register index 0..15 to the chronological list of
  ;; definition steps `(hasheq 'line line 'form form 'reg reg 'val new-val 'op-kind kind)`
  ;; that constructed its current value.
  (define reg-slice (make-vector 16 '()))
  (define found-diag #f)

  (define (record-reg-def! r-sym new-val line form op-kind #:inherit-from [parent-reg #f])
    (define idx (parse-gba-reg-idx r-sym))
    (define u32 (bitwise-and new-val #xFFFFFFFF))
    (vector-set! reg-vals idx u32)
    (define prev-chain
      (if parent-reg
          (vector-ref reg-slice (parse-gba-reg-idx parent-reg))
          '()))
    (define step-entry
      (hasheq 'line    line
              'form    form
              'reg     r-sym
              'reg-idx idx
              'val     u32
              'op-kind op-kind))
    (vector-set! reg-slice idx (append prev-chain (list step-entry))))

  (for ([form (in-list forms)]
        [line (in-naturals 1)]
        #:unless found-diag)
    (match form
      ;; ARM32 / Thumb16 register definitions
      [(list* (or 'arm-mov-imm 'mov 'MOV) rd (? exact-integer? imm8) rest)
       (define rot (if (null? rest) 0 (car rest)))
       (define v (decode-arm-imm-val imm8 rot))
       (record-reg-def! rd v line form 'register-load-base)]

      [(list* (or 'arm-orr-imm 'orr 'ORR) rd rn (? exact-integer? imm8) rest)
       (define rot (if (null? rest) 0 (car rest)))
       (define base-v (vector-ref reg-vals (parse-gba-reg-idx rn)))
       (define v (bitwise-ior base-v (decode-arm-imm-val imm8 rot)))
       (record-reg-def! rd v line form 'register-bit-or-refine #:inherit-from rn)]

      [(list* (or 'arm-add-imm 'add 'ADD) rd rn (? exact-integer? imm8) rest)
       (define rot (if (null? rest) 0 (car rest)))
       (define base-v (vector-ref reg-vals (parse-gba-reg-idx rn)))
       (define v (+ base-v (decode-arm-imm-val imm8 rot)))
       (record-reg-def! rd v line form 'register-pointer-add #:inherit-from rn)]

      [(list* (or 'arm-sub-imm 'sub 'SUB) rd rn (? exact-integer? imm8) rest)
       (define rot (if (null? rest) 0 (car rest)))
       (define base-v (vector-ref reg-vals (parse-gba-reg-idx rn)))
       (define v (- base-v (decode-arm-imm-val imm8 rot)))
       (record-reg-def! rd v line form 'register-pointer-sub #:inherit-from rn)]

      [`(thumb-mov-imm ,rd ,(? exact-integer? imm8))
       (record-reg-def! rd (bitwise-and imm8 #xFF) line form 'register-load-base)]

      [`(thumb-add-imm ,rd ,(? exact-integer? imm8))
       (define base-v (vector-ref reg-vals (parse-gba-reg-idx rd)))
       (record-reg-def! rd (+ base-v (bitwise-and imm8 #xFF)) line form 'register-pointer-add #:inherit-from rd)]

      [`(,(or 'ldr 'LDR 'arm-ldr-lit) ,rd ,(? exact-integer? addr))
       (record-reg-def! rd addr line form 'register-load-base)]

      ;; 8-Bit Byte Stores (`arm-strb-imm`, `thumb-strb`, `strb`, `STRB`)
      [(or `(,(or 'arm-strb-imm 'thumb-strb 'strb 'STRB) ,rd ,rn ,_)
           `(,(or 'strb 'STRB) ,rd (,rn ,_))
           `(,(or 'strb 'STRB) ,rd (,rn))
           `(,(or 'strb 'STRB) ,rd ,rn))
       (define off-val
         (match form
           [`(arm-strb-imm ,_ ,_ ,(? exact-integer? o)) o]
           [`(thumb-strb ,_ ,_ ,ro)
            (if (exact-integer? ro) ro (vector-ref reg-vals (parse-gba-reg-idx ro)))]
           [`(,(or 'strb 'STRB) ,_ (,_ ,(? exact-integer? o))) o]
           [`(,(or 'strb 'STRB) ,_ ,_ ,(? exact-integer? o)) o]
           [_ 0]))
       (define rn-idx (parse-gba-reg-idx rn))
       (define base-addr (vector-ref reg-vals rn-idx))
       (define eff-addr (bitwise-and #xFFFFFFFF (+ base-addr off-val)))
       (define region (gba-addr->region-name eff-addr))

       (when (memq region '(PALRAM VRAM OAM))
         (define rn-defs (vector-ref reg-slice rn-idx))
         (define rd-defs (vector-ref reg-slice (parse-gba-reg-idx rd)))
         (define surf-form
           (case region
             [(PALRAM) `(defpalette gba-palram #:target 'gba #:addr ,(format "$~x" eff-addr))]
             [(VRAM)   `(deftiles gba-vram-tiles #:target 'gba #:addr ,(format "$~x" eff-addr))]
             [(OAM)    `(defmetasprite gba-oam-entry #:target 'gba #:addr ,(format "$~x" eff-addr))]))

         (define def-witnesses
           (if (pair? rn-defs)
               (for/list ([d (in-list rn-defs)]
                          [step-i (in-naturals 1)])
                 (witness-site
                  (if (= step-i 1) 'base-register-def 'base-register-refine)
                  (hash-ref d 'reg)
                  (make-srcloc-span #:source source
                                    #:line (hash-ref d 'line)
                                    #:column 2
                                    #:surface-form surf-form
                                    #:sub-datum (hash-ref d 'form))
                  (format "register ~a defined by ~s at line ~a -> holds $~a (~a base)"
                          (hash-ref d 'reg)
                          (hash-ref d 'form)
                          (hash-ref d 'line)
                          (~r (hash-ref d 'val) #:base 16 #:min-width 8 #:pad-string "0")
                          (gba-addr->region-name (hash-ref d 'val)))))
               (list (witness-site
                      'base-register-def
                      rn
                      (make-srcloc-span #:source source #:line 1 #:surface-form surf-form #:sub-datum rn)
                      (format "base register ~a holds $~a (~a)"
                              rn (~r base-addr #:base 16 #:min-width 8 #:pad-string "0") region)))))

         (define val-witnesses
           (if (pair? rd-defs)
               (let ([last-rd (last rd-defs)])
                 (list (witness-site
                        'stored-byte-source
                        (hash-ref last-rd 'reg)
                        (make-srcloc-span #:source source
                                          #:line (hash-ref last-rd 'line)
                                          #:column 2
                                          #:surface-form surf-form
                                          #:sub-datum (hash-ref last-rd 'form))
                        (format "source byte register ~a loaded by ~s at line ~a (value #x~x)"
                                (hash-ref last-rd 'reg)
                                (hash-ref last-rd 'form)
                                (hash-ref last-rd 'line)
                                (bitwise-and (hash-ref last-rd 'val) #xFF)))))
               '()))

         (define use-witness
           (witness-site
            'illegal-8bit-strb-use
            rn
            (make-srcloc-span #:source source
                              #:line line
                              #:column 2
                              #:surface-form surf-form
                              #:sub-datum form)
            (format "8-bit byte store ~s at line ~a dereferences ~a ($~a + ~a = $~a in GBA ~a 16-bit bus)"
                    form line rn
                    (~r base-addr #:base 16 #:min-width 8 #:pad-string "0")
                    off-val
                    (~r eff-addr #:base 16 #:min-width 8 #:pad-string "0")
                    region)))

         (define bus-consequence
           (if (eq? region 'OAM)
               "GBA OAM ($07000000) ignores 8-bit STRB writes completely (no write strobe)"
               (format "GBA ~a ($~a) lacks an 8-bit write strobe; STRB duplicates the byte across both upper and lower lanes of the 16-bit halfword"
                       region (~r eff-addr #:base 16 #:min-width 8 #:pad-string "0"))))

         (define first-def-line
           (if (pair? rn-defs) (hash-ref (first rn-defs) 'line) 1))
         (define first-def-form
           (if (pair? rn-defs) (hash-ref (first rn-defs) 'form) rn))

         (set! found-diag
               (make-plt-boba-diagnostic
                #:operation (car surf-form)
                #:target 'gba
                #:headline (format "illegal 8-bit STRB write to GBA 16-bit ~a bus at $~a via base register ~a (defined at line ~a)"
                                   region
                                   (~r eff-addr #:base 16 #:min-width 8 #:pad-string "0")
                                   rn
                                   first-def-line)
                #:at-datum form
                #:in-form surf-form
                #:expected (format "16-bit halfword (STRH / 'u16, align >= 2) or 32-bit word (STR / DMA3 / 'u32, align >= 4) write to GBA ~a" region)
                #:given (format "8-bit STRB ~s at line ~a using base register ~a = $~a (loaded by ~s at line ~a); ~a"
                                form line rn
                                (~r base-addr #:base 16 #:min-width 8 #:pad-string "0")
                                first-def-form first-def-line
                                bus-consequence)
                #:witnesses (append def-witnesses val-witnesses (list use-witness))
                #:resugared-surface-term surf-form
                #:repair-options
                (list (format "Replace 8-bit ~s at line ~a with 16-bit halfword store `(arm-strh-imm ~a ~a ~a)` (or `thumb-strh`)"
                              form line rd rn (bitwise-and off-val #xFE))
                      (format "Or pack pairs of pixels/palette entries into 32-bit words and use `(arm-str-imm ~a ~a ~a)` or DMA3 (`REG-DMA3CNT`)"
                              rd rn (bitwise-and off-val #xFC))
                      (format "If byte manipulation is required, stage bytes in 32-bit IWRAM ($03000000) or EWRAM ($02000000) and flush via 16/32-bit `(defvblank-dma ~a ...)`"
                              (string->symbol (string-downcase (symbol->string region))))))))]
      [_ (void)]))

  (if found-diag
      (finish-diagnostic found-diag #:raise? raise?)
      (make-plt-boba-diagnostic
       #:operation 'defvblank-dma
       #:target 'gba
       #:headline "all GBA PALRAM/VRAM/OAM writes satisfy 16/32-bit bus-width capability discipline"
       #:at-datum 'bus-width-verified
       #:in-form '(defvblank-dma gba-vram #:target 'gba #:width 'u16 #:align 2)
       #:expected "u16 (STRH) or u32 (STR/DMA3) writes to $05000000..$07FFFFFF"
       #:given "0 illegal 8-bit STRB instructions"
       #:witnesses
       (list (witness-site 'bus-capability-check 'gba-vram (make-srcloc-span #:source source #:line 1) "scanned ARM7TDMI register def-use chains")
             (witness-site 'bus-capability-verified 'gba-vram (make-srcloc-span #:source source #:line (max 1 (length forms))) "all video bus stores are 16-bit or 32-bit aligned"))
       #:resugared-surface-term '(defvblank-dma gba-vram #:target 'gba #:width 'u16 #:align 2)
       #:repair-options (list "No repair needed; all GBA video memory writes use 16/32-bit transfers"))))

;; ----------------------------------------------------------------------------
;; 3C. Pareto Resource Overflow Blame & Minimal Cut-Set Analyzer
;;     (`diagnose-resource-overflow/pareto-blame`)
;;     Ranks surface/IR declarations by their percentage share of the exceeded
;;     hardware resource ceiling (`TargetSpec`) and computes the minimal cut set
;;     of declarations whose optimization brings the module back within budget.
;; ----------------------------------------------------------------------------

(define (metric-limit-for-target spec metric)
  (case metric
    [(vblank-cycles)                               (target-spec-vblank-cycles-max spec)]
    [(hblank-cycles)                               (target-spec-hblank-cycles-max spec)]
    [(active-cycles)                               (target-spec-active-cycles-max spec)]
    [(dma-bytes vram-dma-bytes)                    (target-spec-dma-bytes-max spec)]
    [(oam-sprites)                                 (target-spec-oam-sprites-max spec)]
    [(oam-scanline scanline-sprites)               (target-spec-oam-scanline-max spec)]
    [(fast-ram-bytes zero-page hram direct-page iwram-32bit rsp-dmem lua-locals sram-striped zp-bytes)
     (target-spec-fast-ram-bytes-max spec)]
    [(work-ram-bytes ram-bytes)                    (target-spec-work-ram-bytes-max spec)]
    [(tile-mem-bytes chr-rom vram s-ppu-vram gba-vram rdp-tmem tmem gfx-sheet)
     (target-spec-tile-mem-bytes-max spec)]
    [(rom-bytes prg-rom-bytes)                     (target-spec-rom-bytes-max spec)]
    [(pico8-tokens pio-instructions spc700-aram-bytes rsp-imem-bytes cgb-palette-bytes
      hram-dma-trampoline-bytes sprite-line-cycles page-crossings extra-used)
     (target-spec-extra-budget-max spec)]
    [else                                          (target-spec-vblank-cycles-max spec)]))

(define (normalize-contributor-item item spec explicit-metric idx source)
  (define tid (target-spec-id spec))
  (cond
    [(pareto-contributor? item) item]
    [(hash? item)
     (define fname  (hash-ref item 'form-name (hash-ref item 'form (hash-ref item 'op 'defvblank-dma))))
     (define id     (hash-ref item 'id (hash-ref item 'name (string->symbol (format "item-~a" idx)))))
     (define metric (or explicit-metric
                        (hash-ref item 'metric #f)
                        (hash-ref item 'metric-name #f)
                        (cond
                          [(hash-has-key? item 'vblank-cycles) 'vblank-cycles]
                          [(hash-has-key? item 'fast-ram-bytes) (target-spec-fast-ram-name spec)]
                          [(hash-has-key? item 'zp-bytes) 'zero-page]
                          [(hash-has-key? item 'oam-sprites) 'oam-sprites]
                          [(hash-has-key? item 'tile-mem-bytes) (target-spec-tile-mem-name spec)]
                          [(hash-has-key? item 'tmem-bytes) 'rdp-tmem]
                          [(hash-has-key? item 'pio-instructions) 'pio-instructions]
                          [(hash-has-key? item 'pico8-tokens) 'pico8-tokens]
                          [(hash-has-key? item 'dma-bytes) 'dma-bytes]
                          [else 'vblank-cycles])))
     (define amt
       (or (hash-ref item 'amount #f)
           (hash-ref item 'cost #f)
           (hash-ref item 'bytes #f)
           (hash-ref item 'cycles #f)
           (hash-ref item metric #f)
           (hash-ref item 'vblank-cycles #f)
           (hash-ref item 'fast-ram-bytes #f)
           (hash-ref item 'zp-bytes #f)
           (hash-ref item 'oam-sprites #f)
           (hash-ref item 'tile-mem-bytes #f)
           (hash-ref item 'tmem-bytes #f)
           (hash-ref item 'pio-instructions #f)
           (hash-ref item 'pico8-tokens #f)
           0))
     (define limit (max 1 (metric-limit-for-target spec metric)))
     (define pct   (/ (* 100.0 amt) limit))
     (define line  (hash-ref item 'line (* 10 idx)))
     (define surf  (hash-ref item 'surface-form (list fname id '#:cost amt)))
     (pareto-contributor fname id metric amt pct
                         (make-srcloc-span #:source source #:line line #:surface-form surf #:sub-datum id))]
    [(pair? item)
     ;; S-expression form: `(defvblank-dma bg-transfer #:cycles 1400)` or `(deftiles boss-atlas #:bytes 3072)`
     (define head (car item))
     (define id   (if (and (pair? (cdr item)) (symbol? (second item)))
                      (second item)
                      (string->symbol (format "~a-~a" head idx))))
     ;; Check if explicit keyword cost is present in S-expression
     (define kw-metric-amt
       (let loop ([rem (cdr item)])
         (match rem
           [(list* '#:vblank-cycles (? real? v) _)    (cons 'vblank-cycles v)]
           [(list* '#:cycles (? real? v) _)           (cons (or explicit-metric 'vblank-cycles) v)]
           [(list* '#:fast-ram-bytes (? real? v) _)   (cons (target-spec-fast-ram-name spec) v)]
           [(list* '#:zp-bytes (? real? v) _)         (cons 'zero-page v)]
           [(list* '#:bytes (? real? v) _)
            (cons (or explicit-metric
                      (case head
                        [(deftiles defchr-tile defchr-resource ir-tileset) (target-spec-tile-mem-name spec)]
                        [(defzp-var with-zp-scratch) (target-spec-fast-ram-name spec)]
                        [else 'dma-bytes]))
                  v)]
           [(list* '#:oam-sprites (? real? v) _)      (cons 'oam-sprites v)]
           [(list* '#:pio-instructions (? real? v) _) (cons 'pio-instructions v)]
           [(list* '#:tokens (? real? v) _)           (cons 'pico8-tokens v)]
           [(cons _ more) (loop more)]
           ['() #f])))
     (define-values (metric amt)
       (if kw-metric-amt
           (values (or explicit-metric (car kw-metric-amt)) (cdr kw-metric-amt))
           (let* ([g (infer-boba-core-statement-grade item spec #:phase 'vblank)]
                  [m (or explicit-metric 'vblank-cycles)]
                  [a (case m
                       [(vblank-cycles) (target-grade-vblank-cycles g)]
                       [(dma-bytes)     (target-grade-dma-bytes g)]
                       [(oam-sprites)   (target-grade-oam-sprites g)]
                       [(fast-ram-bytes zero-page hram iwram-32bit) (target-grade-fast-ram-bytes g)]
                       [(tile-mem-bytes chr-rom rdp-tmem) (target-grade-tile-mem-bytes g)]
                       [else (max (target-grade-vblank-cycles g) (target-grade-extra-used g))])])
             (values m a))))
     (define limit (max 1 (metric-limit-for-target spec metric)))
     (define pct   (/ (* 100.0 amt) limit))
     (define resugared (resugar-core-ir->surface-dsl item tid))
     (define surf-head (if (pair? resugared) (car resugared) head))
     (pareto-contributor surf-head id metric amt pct
                         (make-srcloc-span #:source source #:line (* 10 idx) #:surface-form resugared #:sub-datum id))]
    [else
     (pareto-contributor 'defnes-game 'unknown (or explicit-metric 'vblank-cycles) 0 0.0
                         (make-srcloc-span #:source source #:line (* 10 idx)))]))

(define (diagnose-resource-overflow/pareto-blame
         arg1
         [arg2 '()]
         [arg3 #f]
         #:metric [kw-metric #f]
         #:limit  [kw-limit #f]
         #:source [source "boba-resource-budget.bnes"]
         #:raise? [raise? #f])
  (define-values (spec inferred-pos-metric raw-items)
    (cond
      [arg3
       ;; 3-arg call: (diagnose-resource-overflow/pareto-blame target metric items)
       (values (get-target-spec arg1)
               (if (symbol? arg2) arg2 #f)
               (if (list? arg3) arg3 (list arg3)))]
      [(or (target-spec? arg1) (target-id? arg1))
       (values (get-target-spec arg1) #f (if (list? arg2) arg2 (list arg2)))]
      [else
       (values (get-target-spec (if (or (target-spec? arg2) (target-id? arg2)) arg2 'nes))
               #f
               (if (list? arg1) arg1 (list arg1)))]))
  (define eff-kw-metric (or kw-metric inferred-pos-metric))
  (define tid (target-spec-id spec))

  (define contributors
    (for/list ([item (in-list raw-items)]
               [idx  (in-naturals 1)])
      (normalize-contributor-item item spec eff-kw-metric idx source)))

  (define metric
    (or eff-kw-metric
        (and (pair? contributors) (pareto-contributor-metric-name (car contributors)))
        'vblank-cycles))

  (define limit
    (or kw-limit (max 1 (metric-limit-for-target spec metric))))

  ;; Recompute budget-pct against `limit` and sort descending by `amount` (Pareto dominance order)
  (define sorted-pareto
    (sort (for/list ([c (in-list contributors)])
            (struct-copy pareto-contributor c
                         [metric-name metric]
                         [budget-pct (/ (* 100.0 (pareto-contributor-amount c)) limit)]))
          >
          #:key pareto-contributor-amount))

  (define total-used
    (for/sum ([c (in-list sorted-pareto)])
      (pareto-contributor-amount c)))
  (define excess (max 0 (- total-used limit)))

  ;; Compute the Minimal Cut Set: smallest prefix of top Pareto contributors
  ;; whose cumulative resource usage >= excess!
  (define-values (minimal-cut-set _acc-saved)
    (for/fold ([cut '()] [saved 0])
              ([c (in-list sorted-pareto)])
      (if (and (> excess 0) (< saved excess))
          (values (append cut (list c)) (+ saved (pareto-contributor-amount c)))
          (values cut saved))))

  (define effective-cut
    (if (and (null? minimal-cut-set) (pair? sorted-pareto))
        (list (car sorted-pareto))
        minimal-cut-set))

  (define top-c
    (if (pair? sorted-pareto)
        (car sorted-pareto)
        (pareto-contributor 'defvblank-dma 'vblank-transfer metric total-used 100.0 (make-srcloc-span))))

  (define in-mod-form
    `(defnes-game ,(string->symbol (format "~a-module" tid))
       #:target ',tid
       ,@(map (lambda (c) (srcloc-span-surface-form (pareto-contributor-srcloc c)))
              sorted-pareto)))

  (define witnesses
    (let ([cut-ws
           (for/list ([c (in-list effective-cut)]
                      [rank (in-naturals 1)])
             (witness-site
              (string->symbol (format "pareto-rank-~a-contributor" rank))
              (pareto-contributor-id c)
              (pareto-contributor-srcloc c)
              (format "~a '~a' consumes ~a ~a (~a% of ~a hardware ceiling ~a) [in minimal cut set]"
                      (pareto-contributor-form-name c)
                      (pareto-contributor-id c)
                      (pareto-contributor-amount c)
                      metric
                      (~r (pareto-contributor-budget-pct c) #:precision '(= 1))
                      (string-upcase (symbol->string tid))
                      limit)))])
      (if (>= (length cut-ws) 2)
          cut-ws
          (append cut-ws
                  (list (witness-site
                         'hardware-budget-ceiling
                         tid
                         (make-srcloc-span #:source source #:line 1 #:surface-form in-mod-form #:sub-datum tid)
                         (format "Target '~a' enforces ~a <= ~a; module total is ~a (overflow by +~a)"
                                 tid metric limit total-used excess)))))))

  (define cut-ids (map pareto-contributor-id effective-cut))
  (define diag
    (make-plt-boba-diagnostic
     #:operation (pareto-contributor-form-name top-c)
     #:target tid
     #:headline (format "~a resource budget overflow on '~a': total ~a (~a% of ~a ceiling, excess +~a); minimal cut set: ~s"
                        metric tid total-used
                        (~r (/ (* 100.0 total-used) limit) #:precision '(= 1))
                        limit excess cut-ids)
     #:at-datum (srcloc-span-surface-form (pareto-contributor-srcloc top-c))
     #:in-form in-mod-form
     #:expected (format "cumulative ~a <= ~a on ~a" metric limit (target-spec-name spec))
     #:given (format "~a ~a across ~a declarations (top contributor: (~a ~a) = ~a [~a%], minimal cut set to save >= ~a: ~s)"
                     total-used metric (length sorted-pareto)
                     (pareto-contributor-form-name top-c)
                     (pareto-contributor-id top-c)
                     (pareto-contributor-amount top-c)
                     (~r (pareto-contributor-budget-pct top-c) #:precision '(= 1))
                     excess cut-ids)
     #:witnesses witnesses
     #:pareto-breakdown sorted-pareto
     #:resugared-surface-term in-mod-form
     #:repair-options
     (list (format "Optimize minimal cut set ~s to reduce ~a by at least ~a (currently consuming ~a / ~a)"
                   cut-ids metric excess
                   (for/sum ([c (in-list effective-cut)]) (pareto-contributor-amount c))
                   limit)
           (format "Primary Pareto target: refactor (~a ~a ...) which alone accounts for ~a% (~a / ~a) of the hardware budget"
                   (pareto-contributor-form-name top-c)
                   (pareto-contributor-id top-c)
                   (~r (pareto-contributor-budget-pct top-c) #:precision '(= 1))
                   (pareto-contributor-amount top-c)
                   limit)
           (case metric
             [(vblank-cycles dma-bytes vram-dma-bytes)
              "Amortize VRAM/OAM transfers across frames with (with-vram-delta-queue #:slices 2 ...) or offload to HBlank HDMA"]
             [(fast-ram-bytes zero-page hram direct-page iwram-32bit)
              "Wrap transient temporaries in sequential (with-zp-scratch ...) blocks for chordal interval reuse, or spill cold state to Work-RAM"]
             [(tile-mem-bytes rdp-tmem tmem chr-rom)
              "Stream tiles on demand or partition textures into <= 4,096 B TMEM strips"]
             [(pio-instructions)
              "Fold delay loops into RP2040 PIO side-set / delay [N] fields so program length <= 32 instructions"]
             [(pico8-tokens)
              "Deduplicate table literals into helper functions or pack data into __gff__/__map__ cartridge sections"]
             [else
              "Reduce per-frame allocation in the top Pareto-ranked declaration"]))))

  (finish-diagnostic diag #:raise? raise?))

;; ----------------------------------------------------------------------------
;; 3D. Findler-Felleisen (ICFP 2002) Positive vs. Negative Contract Blame
;;     across Co-Processor & Bank Boundaries
;;     (`diagnose-coprocessor-session/contract-blame`)
;;     Supports:
;;       - SNES 65C816 <-> SPC700 ($2140-$2143 audio handshake & ARAM budget)
;;       - N64 VR4300 <-> RSP <-> RDP (cache writeback, 4 KB TMEM/IMEM, FullSync)
;;       - RP2040 Core 0 <-> Core 1 / PIO (FIFO handshake, SRAM4/5 bank disjointness)
;;       - NES MMC1 cross-bank far-call (switchable bank -> fixed-bank trampoline)
;; ----------------------------------------------------------------------------

(define (coproc-port-payload-limit spec port)
  (define tid (target-spec-id spec))
  (cond
    [(memq port '($2140-reg $2141-reg $2142-reg $2143-reg)) 4]
    [(eq? tid 'snes)   (max 1 (target-spec-extra-budget-max spec))]
    [(eq? tid 'n64)    (max 1 (target-spec-extra-budget-max spec))]
    [(eq? tid 'rp2040)
     (if (memq port '(core1 sio-fifo sram-dma))
         (target-spec-dma-bytes-max spec)
         (max 1 (target-spec-extra-budget-max spec)))]
    [else (max 64 (target-spec-dma-bytes-max spec))]))

(define (diagnose-coprocessor-session/contract-blame
         arg1
         [arg2 #f]
         [arg3 #f]
         #:source [source "boba-coproc-session.bnes"]
         #:raise? [raise? #f])
  ;; Determine protocol/target and session operations or descriptor
  (define-values (protocol-sym raw-ops)
    (cond
      [arg3
       ;; 3-arg call: (diagnose-coprocessor-session/contract-blame protocol session-id ops)
       (values (if (target-spec? arg1) (target-spec-id arg1) arg1) arg3)]
      [(and (symbol? arg1) arg2) (values arg1 arg2)]
      [(and (target-spec? arg1) arg2) (values (target-spec-id arg1) arg2)]
      [(and arg2 (symbol? arg2)) (values arg2 arg1)]
      [(and arg2 (target-spec? arg2)) (values (target-spec-id arg2) arg1)]
      [(and (hash? arg1) (hash-has-key? arg1 'protocol))
       (values (hash-ref arg1 'protocol) arg1)]
      [(and (hash? arg1) (hash-has-key? arg1 'target))
       (values (hash-ref arg1 'target) arg1)]
      [else
       (values 'snes arg1)]))

  (define tid
    (case protocol-sym
      [(snes spc700 65816<->spc700 snes-spc700) 'snes]
      [(n64 rsp rdp vr4300<->rsp<->rdp n64-rcp) 'n64]
      [(rp2040 pio core1 core0<->core1 rp2040-pio) 'rp2040]
      [(nes mmc1 far-call mmc1-cross-bank) 'nes]
      [else (if (target-id? protocol-sym) protocol-sym 'snes)]))

  (define boundary-label
    (case tid
      [(snes)   'SNES-65C816<->SPC700-APU-Bus]
      [(n64)    'N64-VR4300<->RSP<->RDP-RCP-Pipeline]
      [(rp2040) 'RP2040-Core0<->Core1-PIO-Bus]
      [(nes)    'NES-MMC1-Switchable<->Fixed-Bank-Boundary]
      [else     'Cross-Core-Hardware-Boundary]))

  (define caller-party
    (case tid
      [(snes)   'SNES-5A22-65C816-Host-CPU]
      [(n64)    'N64-VR4300-Host-CPU]
      [(rp2040) 'RP2040-Cortex-M0+-Core0]
      [(nes)    'MMC1-Switchable-PRG-Bank-Caller]
      [else     'Host-Caller-Module]))

  (define callee-party
    (case tid
      [(snes)   'Sony-SPC700-Audio-CoProcessor]
      [(n64)    'N64-RCP-RSP-RDP-CoProcessor]
      [(rp2040) 'RP2040-Core1-PIO-StateMachine]
      [(nes)    'MMC1-Target-PRG-Bank-Callee]
      [else     'Target-CoProcessor-Callee]))

  ;; Analyze session ops or violation hash to determine exact failure mode & blame polarity
  (define analysis
    (cond
      [(hash? raw-ops)
       (define kind (hash-ref raw-ops 'violation (hash-ref raw-ops 'rule (hash-ref raw-ops 'kind 'tag-mismatch))))
       (case kind
         [(recv-without-send coprocessor-recv-without-send payload-overflow
           coprocessor-session-payload-overflow unflushed-cache
           n64-rdram-dma-unflushed-cache direct-cross-bank-jsr
           sram-bank-collision pio-instruction-overflow)
          (hasheq 'polarity 'positive
                  'kind kind
                  'blamed (hash-ref raw-ops 'blamed-party caller-party)
                  'partner callee-party
                  'port (hash-ref raw-ops 'port (if (eq? tid 'nes) 'prg-bank-switch 'coproc-port))
                  'sent-op (hash-ref raw-ops 'caller-op `(send ,(hash-ref raw-ops 'port 'apu0) ,(hash-ref raw-ops 'tag 'cmd) ,(hash-ref raw-ops 'bytes 0)))
                  'recv-op (hash-ref raw-ops 'callee-op `(recv ,(hash-ref raw-ops 'port 'apu0) ,(hash-ref raw-ops 'expected-tag 'ack)))
                  'expected (hash-ref raw-ops 'expected "caller must satisfy boundary precondition before invoking co-processor/bank")
                  'actual   (hash-ref raw-ops 'actual (format "caller violated ~a precondition (~a)" boundary-label kind)))]
         [else
          (hasheq 'polarity 'negative
                  'kind kind
                  'blamed (hash-ref raw-ops 'blamed-party callee-party)
                  'partner caller-party
                  'port (hash-ref raw-ops 'port 'coproc-port)
                  'sent-op (hash-ref raw-ops 'caller-op `(send ,(hash-ref raw-ops 'port 'apu0) ,(hash-ref raw-ops 'sent-tag 'ipl-boot) 64))
                  'recv-op (hash-ref raw-ops 'callee-op `(recv ,(hash-ref raw-ops 'port 'apu0) ,(hash-ref raw-ops 'expected-tag 'ack-mismatch)))
                  'expected (hash-ref raw-ops 'expected "co-processor/callee must honor handshake postcondition and return matching protocol tag")
                  'actual   (hash-ref raw-ops 'actual (format "callee violated ~a postcondition (~a)" boundary-label kind)))])]

      [(and (list? raw-ops) (pair? raw-ops) (hash? (car raw-ops)))
       ;; List of structured step hashes: `(hash 'step ... 'initiator ... 'responder-error? ...)`
       (define resp-err
         (for/first ([h (in-list raw-ops)]
                     #:when (or (hash-ref h 'responder-error? #f)
                                (eq? (hash-ref h 'polarity #f) 'negative)))
           h))
       (define first-h (car raw-ops))
       (define last-h  (last raw-ops))
       (if resp-err
           (hasheq 'polarity 'negative
                   'kind (hash-ref resp-err 'step 'coprocessor-postcondition-violation)
                   'blamed callee-party
                   'partner caller-party
                   'port (hash-ref resp-err 'port (if (symbol? arg2) arg2 'coproc-port))
                   'sent-line (hash-ref first-h 'line 1)
                   'sent-op `(send ,(if (symbol? arg2) arg2 'coproc-port) ,(hash-ref first-h 'step 'handshake) 64)
                   'recv-line (hash-ref resp-err 'line 2)
                   'recv-op `(recv ,(if (symbol? arg2) arg2 'coproc-port) ,(hash-ref resp-err 'step 'fault))
                   'expected (format "~a must honor protocol postcondition after ~a handshake" callee-party caller-party)
                   'actual (format "~a failed during step '~a' at line ~a" callee-party (hash-ref resp-err 'step 'unknown) (hash-ref resp-err 'line 2)))
           (hasheq 'polarity 'positive
                   'kind (hash-ref first-h 'step 'caller-precondition-violation)
                   'blamed caller-party
                   'partner callee-party
                   'port (hash-ref first-h 'port (if (symbol? arg2) arg2 'coproc-port))
                   'sent-line (hash-ref first-h 'line 1)
                   'sent-op `(send ,(if (symbol? arg2) arg2 'coproc-port) ,(hash-ref first-h 'step 'write-payload) 64)
                   'recv-line (hash-ref last-h 'line 2)
                   'recv-op `(recv ,(if (symbol? arg2) arg2 'coproc-port) ,(hash-ref last-h 'step 'ring-doorbell))
                   'expected (format "~a must complete initial handshake-boot-ack before step '~a'" caller-party (hash-ref first-h 'step 'write-payload))
                   'actual (format "~a initiated '~a' at line ~a out of protocol order" caller-party (hash-ref first-h 'step 'write-payload) (hash-ref first-h 'line 1))))]

      [(list? raw-ops)
       ;; Inspect list of session / bank / core operations
       (define flat (if (and (pair? raw-ops) (memq (car raw-ops) '(seq begin))) (cdr raw-ops) raw-ops))
       (let loop ([rem flat]
                  [line 1]
                  [sent-queue '()])
         (match rem
           ['()
            ;; If there are unacknowledged sends remaining, the responder/callee failed to acknowledge
            ;; (or if final sync is missing on N64 RDP, or unacknowledged SPC700 command)
            (if (pair? sent-queue)
                (let ([pending (car sent-queue)])
                  (hasheq 'polarity 'negative
                          'kind 'unacknowledged-coprocessor-handshake
                          'blamed callee-party
                          'partner caller-party
                          'port (hash-ref pending 'port)
                          'sent-line (hash-ref pending 'line)
                          'sent-op (hash-ref pending 'op)
                          'recv-line line
                          'recv-op `(missing-ack ,(hash-ref pending 'port) ,(hash-ref pending 'tag))
                          'expected (format "~a must acknowledge sent tag '~a' on port '~a' with matching (recv ~a ~a)"
                                            callee-party (hash-ref pending 'tag) (hash-ref pending 'port)
                                            (hash-ref pending 'port) (hash-ref pending 'tag))
                          'actual (format "~a sent ~s at line ~a, but ~a never emitted matching handshake acknowledgment"
                                          caller-party (hash-ref pending 'op) (hash-ref pending 'line) callee-party)))
                (hasheq 'polarity 'positive
                        'kind 'session-protocol-check
                        'blamed caller-party
                        'partner callee-party
                        'port 'coproc
                        'sent-line 1
                        'sent-op '(send coproc init 16)
                        'recv-line 2
                        'recv-op '(recv coproc init)
                        'expected "balanced cross-boundary session protocol"
                        'actual "protocol sequence checked"))]

           ;; Direct cross-bank JSR without fixed-bank trampoline (NES MMC1 Positive Blame!)
           [(cons (and op `(,(or 'jsr 'JSR 'call 'far-call) . ,args)) _more)
            #:when (or (equal? args '(:cross-bank-direct))
                       (and (>= (length args) 2)
                            (memq (second args) '(direct no-trampoline #f switchable-to-switchable)))
                       (and (pair? args) (hash? (car args))
                            (not (hash-ref (car args) 'trampoline? #t))))
            (define target-fn (if (pair? args) (car args) 'banked_subroutine))
            (hasheq 'polarity 'positive
                    'kind 'mmc1-direct-cross-bank-call-without-trampoline
                    'blamed 'MMC1-Switchable-PRG-Bank-Caller
                    'partner 'MMC1-Target-PRG-Bank-Callee
                    'port 'mmc1-prg-bank-$8000
                    'sent-line line
                    'sent-op op
                    'recv-line (add1 line)
                    'recv-op `(bank-switch-clobbers-caller-pc ,target-fn)
                    'expected "cross-bank call between switchable $8000-$BFFF banks must route through fixed bank ($C000-$FFFF) via (far-call bank label #:trampoline? #t)"
                    'actual (format "caller bank invoked ~s directly from switchable window $8000-$BFFF without fixed-bank trampoline" op))]

           ;; RP2040 shared SRAM bank collision (Core 0 & Core 1 accessing same SRAM bank simultaneously -> Positive Blame on caller Core 0!)
           [(cons (and op `(sram-access ,core0-bank ,core1-bank . ,_)) _more)
            #:when (equal? core0-bank core1-bank)
            (hasheq 'polarity 'positive
                    'kind 'rp2040-sram-bank-contention
                    'blamed 'RP2040-Cortex-M0+-Core0
                    'partner 'RP2040-Core1-PIO-StateMachine
                    'port core0-bank
                    'sent-line line
                    'sent-op op
                    'recv-line (add1 line)
                    'recv-op `(concurrent-sram-stall ,core1-bank)
                    'expected "Core 0 and Core 1 must partition RP2040 scratch into disjoint banks (SRAM4 $20040000 vs. SRAM5 $20041000)"
                    'actual (format "both Core 0 and Core 1 accessed bank '~a' simultaneously in ~s, violating disjoint SRAM ownership" core0-bank op))]

           ;; Co-processor `(send port tag bytes)`
           [(cons (and op `(,(or 'send 'ir-coproc-send) ,port ,tag ,(? exact-integer? bytes))) more)
            (define limit (coproc-port-payload-limit (get-target-spec tid) port))
            (if (or (<= bytes 0) (> bytes limit))
                ;; Caller sent oversized payload -> Positive blame on caller!
                (hasheq 'polarity 'positive
                        'kind 'coprocessor-payload-precondition-overflow
                        'blamed caller-party
                        'partner callee-party
                        'port port
                        'sent-line line
                        'sent-op op
                        'recv-line (add1 line)
                        'recv-op `(co-processor-buffer-limit ,port ,limit)
                        'expected (format "~a must send payload <= ~a B on port '~a' (co-processor memory contract)"
                                          caller-party limit port)
                        'actual (format "~a sent ~a B in ~s at line ~a, exceeding ~a buffer capacity (~a B)"
                                        caller-party bytes op line callee-party limit))
                (loop more
                      (add1 line)
                      (append sent-queue (list (hasheq 'port port 'tag tag 'bytes bytes 'line line 'op op)))))]

           ;; Co-processor `(recv port expected-tag)`
           [(cons (and op `(,(or 'recv 'ir-coproc-recv) ,port ,exp-tag)) more)
            (cond
              [(null? sent-queue)
               ;; Caller executed `recv` without prior `send` -> Positive blame on caller!
               (hasheq 'polarity 'positive
                       'kind 'coprocessor-recv-on-empty-channel-deadlock
                       'blamed caller-party
                       'partner callee-party
                       'port port
                       'sent-line 1
                       'sent-op `(missing-send ,port ,exp-tag)
                       'recv-line line
                       'recv-op op
                       'expected (format "~a must initiate `(send ~a ~a <bytes>)` before blocking on `(recv ~a ~a)`"
                                         caller-party port exp-tag port exp-tag)
                       'actual (format "~a executed ~s at line ~a on an empty channel queue, causing hardware deadlock"
                                       caller-party op line))]
              [else
               (define head-sent (car sent-queue))
               (define sent-tag (hash-ref head-sent 'tag))
               (if (equal? sent-tag exp-tag)
                   (loop more (add1 line) (cdr sent-queue))
                   ;; Responder/callee returned wrong protocol tag -> Negative blame on callee/boundary!
                   (hasheq 'polarity 'negative
                           'kind 'coprocessor-handshake-tag-mismatch
                           'blamed callee-party
                           'partner caller-party
                           'port port
                           'sent-line (hash-ref head-sent 'line)
                           'sent-op (hash-ref head-sent 'op)
                           'recv-line line
                           'recv-op op
                           'expected (format "~a on port '~a' must reply with matching handshake tag '~a' after ~s"
                                             callee-party port sent-tag (hash-ref head-sent 'op))
                           'actual (format "channel on port '~a' delivered mismatched protocol tag (~s vs. expected '~a' at ~s)"
                                           port sent-tag exp-tag op)))])]

           [(cons _ more)
            (loop more (add1 line) sent-queue)]))]
      [else
       (hasheq 'polarity 'positive
               'kind 'session-contract-violation
               'blamed caller-party
               'partner callee-party
               'port 'coproc
               'sent-line 1
               'sent-op raw-ops
               'recv-line 2
               'recv-op '(recv coproc ack)
               'expected "well-formed cross-core session protocol"
               'actual (format "~s" raw-ops))]))

  (define polarity (hash-ref analysis 'polarity))
  (define blamed   (hash-ref analysis 'blamed))
  (define port     (hash-ref analysis 'port))
  (define sent-op  (hash-ref analysis 'sent-op))
  (define recv-op  (hash-ref analysis 'recv-op))
  (define sent-ln  (hash-ref analysis 'sent-line 1))
  (define recv-ln  (hash-ref analysis 'recv-line 2))
  (define exp-c    (hash-ref analysis 'expected))
  (define act-b    (hash-ref analysis 'actual))

  (define surf-form
    (if (eq? tid 'nes)
        `(far-call ,port #:caller-bank 0 #:target-bank 1 #:trampoline? #f)
        `(defcoproc-audio ,port
           #:target ',tid
           #:boundary ',boundary-label
           #:steps (,sent-op ,recv-op))))

  (define at-d (if (eq? polarity 'positive) sent-op recv-op))
  (define blame-loc
    (make-srcloc-span #:source source
                      #:line (if (eq? polarity 'positive) sent-ln recv-ln)
                      #:column 2
                      #:surface-form surf-form
                      #:sub-datum at-d))

  (define blame-struct
    (contract-blame polarity
                    blamed
                    boundary-label
                    exp-c
                    act-b
                    blame-loc))

  (define w-caller
    (witness-site
     'positive-caller-site
     caller-party
     (make-srcloc-span #:source source #:line sent-ln #:column 2 #:surface-form surf-form #:sub-datum sent-op)
     (format "[Caller / Positive Party: ~a] executes ~s at line ~a across ~a"
             caller-party sent-op sent-ln boundary-label)))

  (define w-callee
    (witness-site
     'negative-callee-site
     callee-party
     (make-srcloc-span #:source source #:line recv-ln #:column 2 #:surface-form surf-form #:sub-datum recv-op)
     (format "[Callee / Negative Party: ~a] interaction site ~s at line ~a -> ~a (~a blame on ~a)"
             callee-party recv-op recv-ln act-b polarity blamed)))

  (define diag
    (make-plt-boba-diagnostic
     #:operation (if (eq? tid 'nes) 'far-call 'defcoproc-audio)
     #:target tid
     #:headline (format "~a contract violation across ~a (~a blame assigned to ~a)"
                        (hash-ref analysis 'kind) boundary-label polarity blamed)
     #:at-datum at-d
     #:in-form surf-form
     #:expected exp-c
     #:given act-b
     #:witnesses (list w-caller w-callee)
     #:blame blame-struct
     #:resugared-surface-term surf-form
     #:repair-options
     (case (hash-ref analysis 'kind)
       [(mmc1-direct-cross-bank-call-without-trampoline direct-cross-bank-jsr)
        (list "Replace direct cross-bank `(JSR target)` with `(far-call target-bank target-label #:trampoline? #t)` routed through fixed PRG bank $C000-$FFFF"
              "Or move shared utility subroutines into the fixed PRG bank ($C000-$FFFF)")]
       [(rp2040-sram-bank-contention sram-bank-collision)
        (list "Pin Core 0 scratch state to SRAM4 ($20040000) and Core 1 scanline state to SRAM5 ($20041000)"
              "Verify bank disjointness via `(verify-rp2040-sram-disjointness ...)`")]
       [(coprocessor-payload-precondition-overflow payload-overflow)
        (list (format "Chunk payload on port '~a' into bounded packets within the co-processor SRAM ceiling" port)
              "Stream sample/texture blocks across sequential VBlank frames")]
       [(coprocessor-recv-on-empty-channel-deadlock recv-without-send)
        (list (format "Emit `(send ~a <tag> <bytes>)` from ~a before blocking on `~s`" port caller-party recv-op)
              "Use non-blocking status register polling if co-processor reply is asynchronous")]
       [else
        (list (format "Align protocol tags and acknowledgments between ~a (`~s`) and ~a (`~s`)"
                      caller-party sent-op callee-party recv-op)
              (format "Append matching `(recv ~a <tag>)` acknowledgment step to complete the ~a session"
                      port boundary-label))])))

  (finish-diagnostic diag #:raise? raise?))

;; ============================================================================
;; 4. Canonical Racket Structured Error Formatter (`format-plt-diagnostic`)
;;    & 5-Point Static PLT Compliance Linter (`audit-error-message-plt-compliance`)
;; ============================================================================

(define (format-srcloc-short loc)
  (if (srcloc-span? loc)
      (format "~a:~a:~a"
              (srcloc-span-source loc)
              (srcloc-span-line loc)
              (srcloc-span-column loc))
      "boba-module.bnes:1:0"))

(define (format-plt-diagnostic diag)
  (define op        (sanitize-internal-compiler-jargon (format "~a" (plt-boba-diagnostic-operation diag))))
  (define target    (plt-boba-diagnostic-target diag))
  (define headline  (sanitize-internal-compiler-jargon (plt-boba-diagnostic-headline diag)))
  (define at-raw    (sanitize-internal-compiler-jargon (format "~s" (plt-boba-diagnostic-at-datum diag))))
  (define in-raw    (sanitize-internal-compiler-jargon (format "~s" (plt-boba-diagnostic-in-form diag))))
  ;; Guarantee `at:` sub-expression is strictly more specific (shorter) than `in:` enclosing form
  (define-values (at-str in-str)
    (if (< (string-length at-raw) (string-length in-raw))
        (values at-raw in-raw)
        (values at-raw (format "(defnes-game ~a-module ~a)" target in-raw))))
  (define exp-str   (sanitize-internal-compiler-jargon (format "~a" (plt-boba-diagnostic-expected diag))))
  (define giv-str   (sanitize-internal-compiler-jargon (format "~a" (plt-boba-diagnostic-given diag))))
  (define resugared (sanitize-internal-compiler-jargon (format "~s" (plt-boba-diagnostic-resugared-surface-term diag))))
  (define witnesses (plt-boba-diagnostic-witnesses diag))
  (define pareto    (plt-boba-diagnostic-pareto-breakdown diag))
  (define blame     (plt-boba-diagnostic-blame diag))
  (define repairs   (plt-boba-diagnostic-repair-options diag))

  (define header-lines
    (list
     (format "~a: ~a" op headline)
     (format "  at: ~a" at-str)
     (format "  in: ~a" in-str)
     (format "  target: ~a" target)
     (format "  expected: ~a" exp-str)
     (format "  given: ~a" giv-str)
     (format "  resugared form: ~a" resugared)))

  (define witness-lines
    (if (null? witnesses)
        '()
        (cons "  witness chain:"
              (for/list ([w (in-list witnesses)]
                         [i (in-naturals 1)])
                (format "    [~a] ~a (~a): ~a -- ~a"
                        i
                        (witness-site-role w)
                        (witness-site-label w)
                        (format-srcloc-short (witness-site-srcloc w))
                        (sanitize-internal-compiler-jargon (witness-site-state-desc w)))))))

  (define pareto-lines
    (if (null? pareto)
        '()
        (cons "  pareto resource breakdown:"
              (for/list ([p (in-list pareto)]
                         [i (in-naturals 1)])
                (format "    [~a] (~a ~a) at ~a: ~a ~a (~a% of hardware budget)"
                        i
                        (pareto-contributor-form-name p)
                        (pareto-contributor-id p)
                        (format-srcloc-short (pareto-contributor-srcloc p))
                        (pareto-contributor-amount p)
                        (pareto-contributor-metric-name p)
                        (~r (pareto-contributor-budget-pct p) #:precision '(= 1)))))))

  (define blame-lines
    (if (not (contract-blame? blame))
        '()
        (list
         (format "  contract blame: ~a blame on ~a across ~a (at ~a)"
                 (contract-blame-polarity blame)
                 (contract-blame-blamed-party blame)
                 (contract-blame-boundary-kind blame)
                 (format-srcloc-short (contract-blame-srcloc blame)))
         (format "    expected contract: ~a"
                 (sanitize-internal-compiler-jargon (contract-blame-expected-contract blame)))
         (format "    actual behavior:   ~a"
                 (sanitize-internal-compiler-jargon (contract-blame-actual-behavior blame))))))

  (define repair-lines
    (if (null? repairs)
        (list "  suggested repairs:"
              "    (1) Adjust the pinpointed at: sub-expression to satisfy the target hardware contract")
        (cons "  suggested repairs:"
              (for/list ([r (in-list repairs)]
                         [i (in-naturals 1)])
                (format "    (~a) ~a" i (sanitize-internal-compiler-jargon (format "~a" r)))))))

  (string-join
   (append header-lines
           witness-lines
           pareto-lines
           blame-lines
           repair-lines)
   "\n"))

;; Documented `#lang boba-nes` surface forms recognized by the static PLT rubric linter
(define DOCUMENTED-SURFACE-FORMS
  '("defpalette"
    "defpalette-resource"
    "deftiles"
    "defchr-tile"
    "defchr-resource"
    "defmetasprite"
    "defcampaign"
    "defstate-machine"
    "defrule"
    "deffixed"
    "defphysics"
    "defvblank-dma"
    "defcpu-mode"
    "defcoproc-audio"
    "defnes-game"
    "defnes-module"
    "vblank-block"
    "active-frame-block"
    "defzp-var"
    "with-zp-scratch"
    "far-call"))

;; Static Linter: Audits any formatted diagnostic string (or `plt-boba-diagnostic` struct)
;; against the 5 PLT Error Message Quality Criteria:
;;   1. `no-internal-jargon?`
;;   2. `has-specific-at-span?` (`at:` strictly smaller than `in:`)
;;   3. `has-surface-resugaring?` (references documented `#lang boba-nes` surface forms)
;;   4. `has-multi-site-witnesses-when-conflict?` (flow/dataflow/session conflicts cite >= 2 witnesses)
;;   5. `has-actionable-repairs?` (>= 1 concrete repair option)
(define (audit-error-message-plt-compliance msg-or-diag #:conflict? [conflict-override? #f])
  (define text
    (if (plt-boba-diagnostic? msg-or-diag)
        (format-plt-diagnostic msg-or-diag)
        (format "~a" msg-or-diag)))

  ;; Criterion 1: Zero leaked internal compiler symbols
  (define leaked-jargon
    (for/list ([pat (in-list INTERNAL-JARGON-PATTERNS)]
               #:when (string-contains? text pat))
      pat))
  (define no-internal-jargon? (null? leaked-jargon))

  ;; Criterion 2: Has specific `at:` sub-expression strictly smaller than `in:` enclosing form
  (define at-match (regexp-match #rx"(?m:^  at: (.+)$)" text))
  (define in-match (regexp-match #rx"(?m:^  in: (.+)$)" text))
  (define has-specific-at-span?
    (and at-match
         in-match
         (> (string-length (string-trim (second at-match))) 0)
         (< (string-length (string-trim (second at-match)))
            (string-length (string-trim (second in-match))))))

  ;; Criterion 3: References documented `#lang boba-nes` surface forms
  (define has-surface-resugaring?
    (for/or ([sf (in-list DOCUMENTED-SURFACE-FORMS)])
      (string-contains? text sf)))

  ;; Criterion 4: Multi-site witnesses (>= 2 sites `[1]` and `[2]`) when conflict or witness chain present
  (define is-conflict?
    (or conflict-override?
        (string-contains? text "witness chain:")
        (string-contains? text "conflict")
        (string-contains? text "mismatch")
        (string-contains? text "STRB")
        (string-contains? text "overflow")
        (string-contains? text "blame")))
  (define witness-count
    (length (regexp-match* #rx"(?m:^    \\[[0-9]+\\] )" text)))
  (define has-multi-site-witnesses-when-conflict?
    (if is-conflict?
        (>= witness-count 2)
        #t))

  ;; Criterion 5: Actionable repairs (`suggested repairs:` with `(1) ...`)
  (define has-actionable-repairs?
    (and (string-contains? text "suggested repairs:")
         (regexp-match? #rx"(?m:^    \\(1\\) .+)" text)))

  (define criteria-pairs
    (list (cons 'no-internal-jargon?                     no-internal-jargon?)
          (cons 'has-specific-at-span?                   has-specific-at-span?)
          (cons 'has-surface-resugaring?                 has-surface-resugaring?)
          (cons 'has-multi-site-witnesses-when-conflict? has-multi-site-witnesses-when-conflict?)
          (cons 'has-actionable-repairs?                 has-actionable-repairs?)))

  (define failed-criteria
    (for/list ([p (in-list criteria-pairs)]
               #:unless (cdr p))
      (car p)))

  (define score (- 5 (length failed-criteria)))

  (hasheq 'compliant?                              (null? failed-criteria)
          'score                                   score
          'max-score                               5
          'no-internal-jargon?                     no-internal-jargon?
          'has-specific-at-span?                   has-specific-at-span?
          'has-surface-resugaring?                 has-surface-resugaring?
          'has-multi-site-witnesses-when-conflict? has-multi-site-witnesses-when-conflict?
          'has-actionable-repairs?                 has-actionable-repairs?
          'witness-count                           witness-count
          'leaked-jargon                           leaked-jargon
          'failed-criteria                         failed-criteria))
