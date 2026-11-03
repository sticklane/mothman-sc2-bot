#lang racket/base

;; ============================================================================
;; compiler/boba-core-ir.rkt
;; Layer 1 (Boba-Core IR) & Layer 2 (Hardware Subsystem Dialect)
;; Multi-Target Hardware Specifications, Asset/Tile Bitplane Encoders,
;; and Surface `#lang boba-nes` to Boba-Core IR Lowering Pass
;; ============================================================================

(require racket/match
         racket/list
         racket/set
         racket/format
         racket/math
         racket/string)

(provide
 ;; 1. Hardware Target Specification (`TargetSpec`)
 (struct-out target-spec)
 TargetSpec
 make-target-spec
 TARGET-NES
 TARGET-GB
 TARGET-GBC
 TARGET-PICO8
 TARGET-RP2040
 TARGET-SNES
 TARGET-GBA
 TARGET-N64
 ALL-TARGET-SPECS
 TARGET-SPECS-TABLE
 get-target-spec
 target-id?
 target-tile-byte-size

 ;; 2. Layer 2 Multi-Target Asset, Tile & Palette Encoders
 char->tile-pixel
 normalize-tile-rows
 pack-tile-2bpp-planar
 pack-tile-4bpp-snes-planar
 pack-tile-4bpp-linear-nibble
 pack-tile-rgba16-tmem
 pack-tile-for-target
 pack-rgb15-bgr555
 pack-n64-rgba5551
 pack-rgb15-bgr555-bytes
 pack-n64-rgba5551-bytes
 DEFAULT-RGBA5551-PALETTE

 ;; 3. Layer 1 (`Boba-Core IR`) Node Structs & Constructors
 (struct-out boba-ir-module)
 make-boba-ir-module
 boba-core-ir-module?
 ir-const
 ir-var-ref
 ir-var-set
 ir-alu
 ir-fixed-point
 ir-mem-read
 ir-mem-write
 ir-dma-transfer
 ir-oam-emit
 ir-vram-patch
 ir-palette-write
 ir-scroll-set
 ir-joypad-poll
 ir-apu-op
 ir-coproc-send
 ir-coproc-recv
 ir-mode-switch
 ir-seq
 ir-if
 ir-loop-bounded
 ir-with-scratch
 ir-call
 ir-state-transition

 ;; 4. Surface `#lang boba-nes` -> `Boba-Core IR` Lowering
 lower-dsl-statement-to-boba-ir
 lower-dsl-to-boba-core-ir)

;; ============================================================================
;; 1. Hardware Target Specification (`TargetSpec`)
;; ============================================================================

(struct target-spec
  (id
   name
   cpu-arch
   word-bits
   endianness
   vblank-cycles-max
   hblank-cycles-max
   active-cycles-max
   dma-bytes-max
   oam-sprites-max
   oam-scanline-max
   fast-ram-name
   fast-ram-bytes-max
   work-ram-bytes-max
   tile-mem-name
   tile-mem-bytes-max
   rom-bytes-max
   tile-bpp
   vram-allowed-widths
   vram-min-align
   vram-allowed-phases
   dma-min-align
   coprocessor-name
   extra-budget-name
   extra-budget-max)
  #:transparent)

(define TargetSpec target-spec)
(define make-target-spec target-spec)

;; 1. NES (Ricoh 2A03 / 2C02)
(define TARGET-NES
  (target-spec
   'nes
   "Nintendo Entertainment System (Ricoh 2A03 / 2C02)"
   'mos6502
   8
   'little
   2273
   85
   29780
   256
   64
   8
   'zero-page
   256
   2048
   'chr-rom
   8192
   32768
   2
   '(u8)
   1
   '(vblank forced-blank)
   256
   'none
   'page-crossings
   0))

;; 2. Game Boy (Sharp SM83 / DMG)
(define TARGET-GB
  (target-spec
   'gb
   "Nintendo Game Boy (Sharp SM83 / DMG)"
   'sm83
   8
   'little
   4560
   85
   65664
   160
   40
   10
   'hram
   127
   8192
   'vram
   8192
   32768
   2
   '(u8)
   1
   '(vblank hblank-mode0 lcd-disabled)
   256
   'none
   'hram-dma-trampoline-bytes
   16))

;; 3. Game Boy Color (Sharp SM83 Double-Speed / CGB)
(define TARGET-GBC
  (target-spec
   'gbc
   "Nintendo Game Boy Color (Sharp SM83 Double-Speed / CGB)"
   'sm83-2x
   8
   'little
   9120
   170
   131328
   2240
   40
   10
   'hram
   127
   32768
   'vram-banked
   16384
   65536
   2
   '(u8)
   1
   '(vblank hblank-mode0 lcd-disabled)
   16
   'hdma
   'cgb-palette-bytes
   64))

;; 4. PICO-8 Fantasy Console VM
(define TARGET-PICO8
  (target-spec
   'pico8
   "PICO-8 Fantasy Console VM"
   'pico8-vm
   32
   'little
   0
   0
   65536
   8192
   128
   128
   'lua-locals
   200
   2097152
   'gfx-sheet
   8192
   65536
   4
   '(u8 u16 u32)
   1
   '(vblank hblank-mode0 active forced-blank)
   1
   'none
   'pico8-tokens
   8192))

;; 5. Raspberry Pi RP2040 (Dual Cortex-M0+ + PIO)
(define TARGET-RP2040
  (target-spec
   'rp2040
   "Raspberry Pi RP2040 (Dual Cortex-M0+ + PIO)"
   'cortex-m0plus-thumb
   32
   'little
   266000
   4200
   2200000
   65536
   128
   32
   'sram-striped
   264192
   264192
   'framebuf-sram
   76800
   2097152
   4
   '(u8 u16 u32)
   1
   '(vblank hblank-mode0 active forced-blank)
   4
   'pio-sm
   'pio-instructions
   32))

;; 6. Super Nintendo Entertainment System (Ricoh 5A22 / WDC 65C816)
(define TARGET-SNES
  (target-spec
   'snes
   "Super Nintendo Entertainment System (Ricoh 5A22 / WDC 65C816)"
   'wdc65816
   16
   'little
   6144
   168
   53600
   6144
   128
   32
   'direct-page
   256
   131072
   's-ppu-vram
   65536
   262144
   4
   '(u8 u16)
   1
   '(vblank hblank-hdma forced-blank)
   1
   'spc700
   'spc700-aram-bytes
   65536))

;; 7. Game Boy Advance (ARM7TDMI 16.78 MHz)
(define TARGET-GBA
  (target-spec
   'gba
   "Nintendo Game Boy Advance (ARM7TDMI 16.78 MHz)"
   'arm7tdmi
   32
   'little
   83776
   272
   197120
   32768
   128
   32
   'iwram-32bit
   32768
   262144
   'gba-vram
   98304
   33554432
   4
   '(u16 u32)
   2
   '(vblank hblank-mode0 active forced-blank)
   4
   'dma3
   'sprite-line-cycles
   1210))

;; 8. Nintendo 64 (MIPS VR4300 + RCP RSP/RDP)
(define TARGET-N64
  (target-spec
   'n64
   "Nintendo 64 (MIPS VR4300 + RCP RSP/RDP)"
   'mips-vr4300
   64
   'big
   262500
   3000
   1562500
   65536
   256
   64
   'rsp-dmem
   4096
   4194304
   'rdp-tmem
   4096
   67108864
   16
   '(u16 u32 u64)
   2
   '(vblank active rsp-display-list)
   16
   'rsp-rdp
   'rsp-imem-bytes
   4096))

(define ALL-TARGET-SPECS
  (list TARGET-NES
        TARGET-GB
        TARGET-GBC
        TARGET-PICO8
        TARGET-RP2040
        TARGET-SNES
        TARGET-GBA
        TARGET-N64))

(define TARGET-SPECS-TABLE
  (for/hasheq ([spec (in-list ALL-TARGET-SPECS)])
    (values (target-spec-id spec) spec)))

(define (target-id? x)
  (and (symbol? x) (hash-has-key? TARGET-SPECS-TABLE x)))

(define (get-target-spec sym-or-spec)
  (cond
    [(target-spec? sym-or-spec) sym-or-spec]
    [(and (symbol? sym-or-spec) (hash-has-key? TARGET-SPECS-TABLE sym-or-spec))
     (hash-ref TARGET-SPECS-TABLE sym-or-spec)]
    [(string? sym-or-spec)
     (get-target-spec (string->symbol (string-downcase sym-or-spec)))]
    [else
     (error 'get-target-spec "Unknown hardware target specification: ~v" sym-or-spec)]))

(define (target-tile-byte-size sym-or-spec)
  (define spec (get-target-spec sym-or-spec))
  (* 8 (target-spec-tile-bpp spec)))

;; ============================================================================
;; 2. Layer 2 Multi-Target Asset, Tile & Palette Encoders
;; ============================================================================

;; Map an ASCII character in a tile row string ("0123..." or ".123...") to a
;; 4-bit pixel index 0..15.
(define (char->tile-pixel ch)
  (cond
    [(or (char=? ch #\.) (char=? ch #\space) (char=? ch #\0)) 0]
    [(and (char>=? ch #\1) (char<=? ch #\9))
     (- (char->integer ch) (char->integer #\0))]
    [(and (char>=? ch #\a) (char<=? ch #\f))
     (+ 10 (- (char->integer ch) (char->integer #\a)))]
    [(and (char>=? ch #\A) (char<=? ch #\F))
     (+ 10 (- (char->integer ch) (char->integer #\A)))]
    [(char=? ch #\#) 3]
    [else 0]))

;; Normalize an 8x8 tile row specification into a list of 8 lists of 8 exact integers in 0..15.
(define (normalize-tile-rows rows)
  (define raw-rows
    (cond
      [(and (pair? rows) (number? (car rows)) (list? (cdr rows)))
       ;; Handle (cons tile-id row-list)
       (cdr rows)]
      [(list? rows) rows]
      [else '()]))
  (for/list ([y (in-range 8)])
    (define row (if (< y (length raw-rows)) (list-ref raw-rows y) "........"))
    (define px-list
      (cond
        [(string? row) (map char->tile-pixel (string->list row))]
        [(list? row)   (map (lambda (v) (if (char? v) (char->tile-pixel v) (bitwise-and v #x0F))) row)]
        [(bytes? row)  (bytes->list row)]
        [else '()]))
    (for/list ([x (in-range 8)])
      (if (< x (length px-list))
          (bitwise-and (list-ref px-list x) #x0F)
          0))))

;; Pack an 8x8 tile into 16-byte 2bpp planar format (NES / GB / GBC / SNES 2bpp).
;; By default (`#:interleaved? #f`), bytes 0..7 are Plane 0 and bytes 8..15 are Plane 1 (NES 2C02).
;; When `#:interleaved? #t`, row bytes are interleaved [Plane0_y, Plane1_y] (GB / GBC / SNES 2bpp).
(define (pack-tile-2bpp-planar rows #:interleaved? [interleaved? #f])
  (define norm (normalize-tile-rows rows))
  (define out (make-bytes 16 0))
  (for ([px-row (in-list norm)]
        [y      (in-range 8)])
    (define b0 0)
    (define b1 0)
    (for ([px (in-list px-row)]
          [x  (in-range 8)])
      (define shift (- 7 x))
      (define c2 (bitwise-and px #x03))
      (set! b0 (bitwise-ior b0 (arithmetic-shift (bitwise-and c2 1) shift)))
      (set! b1 (bitwise-ior b1 (arithmetic-shift (bitwise-and (arithmetic-shift c2 -1) 1) shift))))
    (if interleaved?
        (begin
          (bytes-set! out (* 2 y) b0)
          (bytes-set! out (add1 (* 2 y)) b1))
        (begin
          (bytes-set! out y b0)
          (bytes-set! out (+ 8 y) b1))))
  out)

;; Pack an 8x8 tile into 32-byte 4bpp SNES S-PPU composite planar format:
;;   - Bytes 0..15  : Planes 0 and 1 interleaved row-by-row ([p0_row0, p1_row0, ..., p0_row7, p1_row7])
;;   - Bytes 16..31 : Planes 2 and 3 interleaved row-by-row ([p2_row0, p3_row0, ..., p2_row7, p3_row7])
(define (pack-tile-4bpp-snes-planar rows)
  (define norm (normalize-tile-rows rows))
  (define out (make-bytes 32 0))
  (for ([px-row (in-list norm)]
        [y      (in-range 8)])
    (define b0 0)
    (define b1 0)
    (define b2 0)
    (define b3 0)
    (for ([px (in-list px-row)]
          [x  (in-range 8)])
      (define shift (- 7 x))
      (define c4 (bitwise-and px #x0F))
      (set! b0 (bitwise-ior b0 (arithmetic-shift (bitwise-and c4 1) shift)))
      (set! b1 (bitwise-ior b1 (arithmetic-shift (bitwise-and (arithmetic-shift c4 -1) 1) shift)))
      (set! b2 (bitwise-ior b2 (arithmetic-shift (bitwise-and (arithmetic-shift c4 -2) 1) shift)))
      (set! b3 (bitwise-ior b3 (arithmetic-shift (bitwise-and (arithmetic-shift c4 -3) 1) shift))))
    (bytes-set! out (* 2 y) b0)
    (bytes-set! out (add1 (* 2 y)) b1)
    (bytes-set! out (+ 16 (* 2 y)) b2)
    (bytes-set! out (+ 17 (* 2 y)) b3))
  out)

;; Pack an 8x8 tile into 32-byte 4bpp linear little-endian nibble pairs (GBA 4bpp & PICO-8):
;; Each row is 4 bytes; byte i holds pixel (2*i) in the low nibble and pixel (2*i + 1) in the high nibble.
(define (pack-tile-4bpp-linear-nibble rows)
  (define norm (normalize-tile-rows rows))
  (define out (make-bytes 32 0))
  (for ([px-row (in-list norm)]
        [y      (in-range 8)])
    (for ([pair-idx (in-range 4)])
      (define p-even (bitwise-and (list-ref px-row (* 2 pair-idx)) #x0F))
      (define p-odd  (bitwise-and (list-ref px-row (add1 (* 2 pair-idx))) #x0F))
      (define packed-byte (bitwise-ior p-even (arithmetic-shift p-odd 4)))
      (bytes-set! out (+ (* y 4) pair-idx) packed-byte)))
  out)

;; Convert (r5 g5 b5) into a 16-bit little-endian `0bbbbbgggggrrrrr` word for GBC / SNES / GBA.
;; Supports both `(pack-rgb15-bgr555 r5 g5 b5)` and `(pack-rgb15-bgr555 '(r5 g5 b5))`.
(define (pack-rgb15-bgr555 a [g-opt #f] [b-opt #f] #:as-bytes? [as-bytes? #f])
  (define-values (r5 g5 b5)
    (cond
      [(and (list? a) (= (length a) 3))
       (values (first a) (second a) (third a))]
      [(and (vector? a) (= (vector-length a) 3))
       (values (vector-ref a 0) (vector-ref a 1) (vector-ref a 2))]
      [(and (exact-integer? a) (exact-integer? g-opt) (exact-integer? b-opt))
       (values a g-opt b-opt)]
      [else
       (error 'pack-rgb15-bgr555 "Expected (r5 g5 b5) as 3 integers or a 3-element list, got ~v ~v ~v"
              a g-opt b-opt)]))
  (define word
    (bitwise-ior (bitwise-and r5 #x1F)
                 (arithmetic-shift (bitwise-and g5 #x1F) 5)
                 (arithmetic-shift (bitwise-and b5 #x1F) 10)))
  (if as-bytes?
      (bytes (bitwise-and word #xFF)
             (bitwise-and (arithmetic-shift word -8) #x7F))
      word))

(define (pack-rgb15-bgr555-bytes a [g-opt #f] [b-opt #f])
  (pack-rgb15-bgr555 a g-opt b-opt #:as-bytes? #t))

;; Convert (r5 g5 b5 a1) into a 16-bit big-endian `rrrrrgggggbbbbba` word for N64.
;; Supports both `(pack-n64-rgba5551 r5 g5 b5 a1)` and `(pack-n64-rgba5551 '(r5 g5 b5 a1))`.
(define (pack-n64-rgba5551 a [g-opt #f] [b-opt #f] [a-opt 1] #:as-bytes? [as-bytes? #f])
  (define-values (r5 g5 b5 a1)
    (cond
      [(and (list? a) (= (length a) 4))
       (values (first a) (second a) (third a) (fourth a))]
      [(and (list? a) (= (length a) 3))
       (values (first a) (second a) (third a) 1)]
      [(and (vector? a) (= (vector-length a) 4))
       (values (vector-ref a 0) (vector-ref a 1) (vector-ref a 2) (vector-ref a 3))]
      [(and (exact-integer? a) (exact-integer? g-opt) (exact-integer? b-opt))
       (values a g-opt b-opt (if (exact-integer? a-opt) a-opt 1))]
      [else
       (error 'pack-n64-rgba5551 "Expected (r5 g5 b5 a1) as 4 integers or a 4-element list, got ~v ~v ~v ~v"
              a g-opt b-opt a-opt)]))
  (define word
    (bitwise-ior (arithmetic-shift (bitwise-and r5 #x1F) 11)
                 (arithmetic-shift (bitwise-and g5 #x1F) 6)
                 (arithmetic-shift (bitwise-and b5 #x1F) 1)
                 (bitwise-and a1 #x01)))
  (if as-bytes?
      (bytes (bitwise-and (arithmetic-shift word -8) #xFF)
             (bitwise-and word #xFF))
      word))

(define (pack-n64-rgba5551-bytes a [g-opt #f] [b-opt #f] [a-opt 1])
  (pack-n64-rgba5551 a g-opt b-opt a-opt #:as-bytes? #t))

;; Default 16-entry RGBA5551 palette for 8x8 tile -> N64 RDP TMEM encoding
;; Index 0 is transparent (0,0,0,0 -> #x0000); indices 1..15 are opaque (a1 = 1).
(define DEFAULT-RGBA5551-PALETTE
  (vector
   (pack-n64-rgba5551 0  0  0  0) ; 0: Transparent
   (pack-n64-rgba5551 6  6  10 1) ; 1: Deep outline / shadow
   (pack-n64-rgba5551 28 16 8  1) ; 2: Warm accent / midtone
   (pack-n64-rgba5551 31 30 24 1) ; 3: Bright highlight / cream
   (pack-n64-rgba5551 31 6  6  1) ; 4: Red
   (pack-n64-rgba5551 6  26 8  1) ; 5: Green
   (pack-n64-rgba5551 6  14 31 1) ; 6: Blue
   (pack-n64-rgba5551 31 28 4  1) ; 7: Gold
   (pack-n64-rgba5551 22 8  28 1) ; 8: Purple
   (pack-n64-rgba5551 6  28 28 1) ; 9: Cyan
   (pack-n64-rgba5551 31 14 22 1) ; 10: Pink
   (pack-n64-rgba5551 18 12 6  1) ; 11: Brown
   (pack-n64-rgba5551 14 14 14 1) ; 12: Dark Gray
   (pack-n64-rgba5551 22 22 22 1) ; 13: Light Gray
   (pack-n64-rgba5551 16 31 12 1) ; 14: Lime
   (pack-n64-rgba5551 31 31 31 1) ; 15: Pure White
   ))

;; Pack an 8x8 tile into 128-byte big-endian 5551 RGBA16 texels for N64 RDP TMEM.
(define (pack-tile-rgba16-tmem rows #:palette [palette DEFAULT-RGBA5551-PALETTE])
  (define norm (normalize-tile-rows rows))
  (define out (make-bytes 128 0))
  (define (lookup-rgba5551 idx)
    (define c (bitwise-and idx #x0F))
    (cond
      [(vector? palette)
       (define entry (vector-ref palette (min c (sub1 (vector-length palette)))))
       (if (list? entry) (pack-n64-rgba5551 entry) entry)]
      [(list? palette)
       (define entry (list-ref palette (min c (sub1 (length palette)))))
       (if (list? entry) (pack-n64-rgba5551 entry) entry)]
      [(hash? palette)
       (define entry (hash-ref palette c (if (zero? c) 0 (pack-n64-rgba5551 31 31 31 1))))
       (if (list? entry) (pack-n64-rgba5551 entry) entry)]
      [else (vector-ref DEFAULT-RGBA5551-PALETTE c)]))
  (for ([px-row (in-list norm)]
        [y      (in-range 8)])
    (for ([px (in-list px-row)]
          [x  (in-range 8)])
      (define word16 (lookup-rgba5551 px))
      (define byte-off (* 2 (+ (* y 8) x)))
      ;; Big-endian 16-bit texel write for N64 RDP TMEM
      (bytes-set! out byte-off        (bitwise-and (arithmetic-shift word16 -8) #xFF))
      (bytes-set! out (add1 byte-off) (bitwise-and word16 #xFF))))
  out)

;; Dispatch tile packing on TargetSpec (or target symbol).
;; Supports both `(pack-tile-for-target target rows)` and `(pack-tile-for-target rows target)`.
(define (pack-tile-for-target arg1 arg2)
  (define-values (spec rows)
    (if (or (target-spec? arg1) (target-id? arg1))
        (values (get-target-spec arg1) arg2)
        (values (get-target-spec arg2) arg1)))
  (case (target-spec-id spec)
    [(nes)    (pack-tile-2bpp-planar rows #:interleaved? #f)]
    [(gb gbc) (pack-tile-2bpp-planar rows #:interleaved? #t)]
    [(snes)   (pack-tile-4bpp-snes-planar rows)]
    [(gba pico8 rp2040) (pack-tile-4bpp-linear-nibble rows)]
    [(n64)    (pack-tile-rgba16-tmem rows)]
    [else
     (case (target-spec-tile-bpp spec)
       [(2)  (pack-tile-2bpp-planar rows)]
       [(4)  (pack-tile-4bpp-linear-nibble rows)]
       [(16) (pack-tile-rgba16-tmem rows)]
       [else (pack-tile-2bpp-planar rows)])]))

;; ============================================================================
;; 3. Layer 1 (`Boba-Core IR`) Node Structs & Constructors
;; ============================================================================

(struct boba-ir-module
  (name
   target
   target-spec
   fast-ram-vars
   work-ram-vars
   tiles
   packed-tiles
   palettes
   metasprites
   state-machines
   vblank-ops
   hblank-ops
   active-ops
   mem-ops
   mode-ops
   session-ops
   metadata)
  #:transparent)

(define (boba-core-ir-module? x)
  (or (boba-ir-module? x)
      (and (hash? x) (eq? (hash-ref x 'kind #f) 'boba-core-ir-module))))

(define (make-boba-ir-module
         #:name           [name 'boba-core-module]
         #:target         [target 'nes]
         #:fast-ram-vars  [fast-ram-vars '()]
         #:work-ram-vars  [work-ram-vars '()]
         #:tiles          [tiles '()]
         #:packed-tiles   [packed-tiles #f]
         #:palettes       [palettes '()]
         #:metasprites    [metasprites '()]
         #:state-machines [state-machines '()]
         #:vblank-ops     [vblank-ops '()]
         #:hblank-ops     [hblank-ops '()]
         #:active-ops     [active-ops '()]
         #:mem-ops        [mem-ops '()]
         #:mode-ops       [mode-ops '()]
         #:session-ops    [session-ops '()]
         #:metadata       [metadata (hasheq)])
  (define spec (get-target-spec target))
  (define encoded-tiles
    (or packed-tiles
        (for/list ([t (in-list tiles)]
                   #:when (or (pair? t) (list? t)))
          (if (and (pair? t) (exact-integer? (car t)))
              (cons (car t) (pack-tile-for-target spec (cdr t)))
              (pack-tile-for-target spec t)))))
  (boba-ir-module
   name
   (target-spec-id spec)
   spec
   fast-ram-vars
   work-ram-vars
   tiles
   encoded-tiles
   palettes
   metasprites
   state-machines
   vblank-ops
   hblank-ops
   active-ops
   mem-ops
   mode-ops
   session-ops
   metadata))

;; Canonical S-expression node constructors for Layer 1 Boba-Core IR
(define (ir-const val [width 'u8])
  `(ir-const ,val ,width))

(define (ir-var-ref id [region 'fast-ram] [width 'u8])
  `(ir-var-ref ,id ,region ,width))

(define (ir-var-set id expr [region 'fast-ram] [width 'u8])
  `(ir-var-set ,id ,expr ,region ,width))

(define (ir-alu op dst lhs rhs [width 'u8])
  `(ir-alu ,op ,dst ,lhs ,rhs ,width))

(define (ir-fixed-point op dst lhs rhs [fmt 'q8.8])
  `(ir-fixed-point ,op ,dst ,lhs ,rhs ,fmt))

(define (ir-mem-read region addr [width 'u8] [align 1] [phase 'active])
  `(mem-read ,region ,addr ,width ,align ,phase))

(define (ir-mem-write region width align phase [cache-state 'cache-flushed] [bytes 1])
  `(mem-write ,region ,width ,align ,phase ,cache-state ,bytes))

(define (ir-dma-transfer region bytes [align-or-phase 256] [phase 'vblank] [cache-state 'cache-flushed])
  (define actual-align (if (exact-integer? align-or-phase) align-or-phase 256))
  (define actual-phase (if (symbol? align-or-phase) align-or-phase phase))
  `(mem-write ,region dma ,actual-align ,actual-phase ,cache-state ,bytes))

(define (ir-oam-emit sprite-id [count 4] [scanline-count 2])
  `(ir-oam-emit ,sprite-id ,count ,scanline-count))

(define (ir-vram-patch addr bytes [width 'u8] [align 1] [phase 'vblank])
  `(ir-vram-patch ,addr ,bytes ,width ,align ,phase))

(define (ir-palette-write addr bytes [phase 'vblank])
  `(ir-palette-write ,addr ,bytes ,phase))

(define (ir-scroll-set x y [phase 'vblank])
  `(ir-scroll-set ,x ,y ,phase))

(define (ir-joypad-poll [port 0])
  `(ir-joypad-poll ,port))

(define (ir-apu-op channel [op 'sfx] [payload-bytes 4])
  `(ir-apu-op ,channel ,op ,payload-bytes))

(define (ir-coproc-send port tag payload-bytes)
  `(send ,port ,tag ,payload-bytes))

(define (ir-coproc-recv port tag)
  `(recv ,port ,tag))

(define (ir-mode-switch op imm)
  `(,op ,imm))

(define (ir-seq . stmts)
  (if (and (= (length stmts) 1) (list? (car stmts)))
      `(seq ,@(car stmts))
      `(seq ,@stmts)))

(define (ir-if cond-expr then-branch else-branch)
  `(if ,cond-expr ,then-branch ,else-branch))

(define (ir-loop-bounded trip-count . body)
  `(loop-bound ,trip-count ,@body))

(define (ir-with-scratch bindings . body)
  `(with-zp-scratch ,bindings ,@body))

(define (ir-call callee [args '()] #:interworking? [interworking? #f] #:bank [bank #f])
  `(call ,callee ,args ,interworking? ,bank))

(define (ir-state-transition fsm-name from-state to-state)
  `(ir-state-transition ,fsm-name ,from-state ,to-state))

;; ============================================================================
;; 4. Surface `#lang boba-nes` -> `Boba-Core IR` Lowering Pass
;; ============================================================================

(define (normalize-phase-for-target phase spec)
  (define tid (target-spec-id spec))
  (case phase
    [(VBlankNMI vblank) 'vblank]
    [(ForcedBlank forced-blank lcd-disabled)
     (if (memq tid '(gb gbc)) 'lcd-disabled 'forced-blank)]
    [(ScanlineHBlank hblank hblank-mode0 hblank-hdma)
     (if (eq? tid 'snes) 'hblank-hdma 'hblank-mode0)]
    [(ActiveFrame active) 'active]
    [else phase]))

;; Lower a single surface `#lang boba-nes` statement or block into Layer 1 Boba-Core IR
(define (lower-dsl-statement-to-boba-ir stmt [target-or-spec 'nes] #:phase [phase 'active])
  (define spec (get-target-spec target-or-spec))
  (define norm-phase (normalize-phase-for-target phase spec))
  (define default-vram-width (first (target-spec-vram-allowed-widths spec)))
  (define default-vram-align (target-spec-vram-min-align spec))
  (define default-dma-align  (target-spec-dma-min-align spec))

  (match stmt
    ['() '(seq)]
    [(? hash? h)
     (cond
       [(eq? (hash-ref h 'phase #f) 'VBlankNMI)
        (ir-seq
         (ir-dma-transfer 'oam-dma (min 256 (target-spec-dma-bytes-max spec)) default-dma-align 'vblank)
         (ir-vram-patch #x2000 (hash-ref h 'vram-dma-bytes 16) default-vram-width default-vram-align 'vblank)
         (ir-oam-emit 'vblank-oam (hash-ref h 'oam-sprites 4) (hash-ref h 'scanline-sprites 2))
         (ir-scroll-set 0 0 'vblank))]
       [(eq? (hash-ref h 'phase #f) 'ActiveFrame)
        (ir-seq
         (ir-joypad-poll 0)
         (ir-alu 'add 'frame_counter 'frame_counter 1))]
       [else h])]
    [`(,(or 'seq 'begin) . ,stmts)
     `(seq ,@(for/list ([s (in-list stmts)])
               (lower-dsl-statement-to-boba-ir s spec #:phase norm-phase)))]
    [`(if ,c ,t ,e)
     (ir-if c
            (lower-dsl-statement-to-boba-ir t spec #:phase norm-phase)
            (lower-dsl-statement-to-boba-ir e spec #:phase norm-phase))]
    [`(,(or 'when 'unless) ,c . ,body)
     (ir-if c
            `(seq ,@(for/list ([s (in-list body)])
                      (lower-dsl-statement-to-boba-ir s spec #:phase norm-phase)))
            '(seq))]
    [`(,(or 'repeat-static 'loop-bound) ,(? exact-integer? k) . ,body)
     `(loop-bound ,k
                  ,@(for/list ([s (in-list body)])
                      (lower-dsl-statement-to-boba-ir s spec #:phase norm-phase)))]
    [`(with-zp-scratch ,bindings . ,body)
     `(with-zp-scratch ,bindings
                       ,@(for/list ([s (in-list body)])
                           (lower-dsl-statement-to-boba-ir s spec #:phase norm-phase)))]
    [`(oam-dma! . ,_)
     (ir-dma-transfer 'oam-dma (min 256 (target-spec-dma-bytes-max spec)) default-dma-align norm-phase)]
    [`(,(or 'nametable-patch! 'vram-put! 'ppu-write! 'hud-bcd-delta!) ,addr . ,rest)
     (define cnt (if (and (pair? rest) (exact-integer? (car rest)) (> (car rest) 0)) (car rest) 4))
     (ir-vram-patch addr cnt default-vram-width default-vram-align norm-phase)]
    [`(palette-write! ,addr . ,_)
     (ir-palette-write addr 4 norm-phase)]
    [`(restore-scroll! ,x ,y)
     (ir-scroll-set x y norm-phase)]
    [`(emit-metasprite! ,ms . ,_)
     (define oam-n  (if (hash? ms) (hash-ref ms 'oam-sprites 4) 4))
     (define scan-n (if (hash? ms) (hash-ref ms 'scanline-sprites 2) 2))
     (ir-oam-emit 'metasprite oam-n scan-n)]
    [`(poll-joypad! . ,_)
     (ir-joypad-poll 0)]
    [`(,(or 'apu-sfx! 'apu-write!) ,ch . ,_)
     (ir-apu-op ch 'sfx 4)]
    [_ stmt]))

;; Lower surface `#lang boba-nes` module declarations (hash, S-expression list, or keyword args)
;; into a target-parameterized `boba-ir-module` structure.
(define (lower-dsl-to-boba-core-ir
         [dsl-input #hasheq()]
         [pos-target #f]
         #:target         [kw-target #f]
         #:name           [kw-name #f]
         #:tiles          [kw-tiles #f]
         #:palettes       [kw-palettes #f]
         #:metasprites    [kw-metasprites #f]
         #:state-machines [kw-state-machines #f]
         #:vblank-block   [kw-vblank #f]
         #:hblank-block   [kw-hblank #f]
         #:active-block   [kw-active #f]
         #:mem-ops        [kw-mem-ops #f]
         #:mode-ops       [kw-mode-ops #f]
         #:session-ops    [kw-session-ops #f])
  (cond
    [(boba-ir-module? dsl-input)
     (if (or pos-target kw-target)
         (let ([spec (get-target-spec (or kw-target pos-target))])
           (make-boba-ir-module
            #:name           (boba-ir-module-name dsl-input)
            #:target         spec
            #:fast-ram-vars  (boba-ir-module-fast-ram-vars dsl-input)
            #:work-ram-vars  (boba-ir-module-work-ram-vars dsl-input)
            #:tiles          (boba-ir-module-tiles dsl-input)
            #:palettes       (boba-ir-module-palettes dsl-input)
            #:metasprites    (boba-ir-module-metasprites dsl-input)
            #:state-machines (boba-ir-module-state-machines dsl-input)
            #:vblank-ops     (boba-ir-module-vblank-ops dsl-input)
            #:hblank-ops     (boba-ir-module-hblank-ops dsl-input)
            #:active-ops     (boba-ir-module-active-ops dsl-input)
            #:mem-ops        (boba-ir-module-mem-ops dsl-input)
            #:mode-ops       (boba-ir-module-mode-ops dsl-input)
            #:session-ops    (boba-ir-module-session-ops dsl-input)
            #:metadata       (boba-ir-module-metadata dsl-input)))
         dsl-input)]
    [(hash? dsl-input)
     (define eff-target
       (or kw-target
           pos-target
           (hash-ref dsl-input 'target #f)
           (hash-ref dsl-input 'target-id #f)
           'nes))
     (define spec (get-target-spec eff-target))
     (define default-vram-width (first (target-spec-vram-allowed-widths spec)))
     (define default-vram-align (target-spec-vram-min-align spec))
     (define default-dma-align  (target-spec-dma-min-align spec))

     (define fast-vars
       (or (hash-ref dsl-input 'fast-ram-vars #f)
           (hash-ref dsl-input 'zp-vars #f)
           (hash-ref dsl-input 'zp-map '())))
     (define work-vars
       (hash-ref dsl-input 'work-ram-vars '()))
     (define tiles
       (or kw-tiles
           (hash-ref dsl-input 'tiles #f)
           (let ([n (hash-ref dsl-input 'chr-tiles 0)])
             (if (and (exact-integer? n) (> n 0))
                 (for/list ([i (in-range n)])
                   (cons i '("11111111" "12222221" "12333321" "12333321"
                             "12333321" "12333321" "12222221" "11111111")))
                 '()))))
     (define vb-raw (or kw-vblank (hash-ref dsl-input 'vblank-ops #f) (hash-ref dsl-input 'vblank-block #f) '()))
     (define hb-raw (or kw-hblank (hash-ref dsl-input 'hblank-ops #f) (hash-ref dsl-input 'hblank-block #f) '()))
     (define ac-raw (or kw-active (hash-ref dsl-input 'active-ops #f) (hash-ref dsl-input 'active-block #f) '()))

     (define vb-ops
       (cond
         [(list? vb-raw)
          (for/list ([s (in-list vb-raw)])
            (lower-dsl-statement-to-boba-ir s spec #:phase 'vblank))]
         [vb-raw (list (lower-dsl-statement-to-boba-ir vb-raw spec #:phase 'vblank))]
         [else '()]))
     (define hb-ops
       (cond
         [(list? hb-raw)
          (for/list ([s (in-list hb-raw)])
            (lower-dsl-statement-to-boba-ir s spec #:phase 'hblank))]
         [hb-raw (list (lower-dsl-statement-to-boba-ir hb-raw spec #:phase 'hblank))]
         [else '()]))
     (define ac-ops
       (cond
         [(list? ac-raw)
          (for/list ([s (in-list ac-raw)])
            (lower-dsl-statement-to-boba-ir s spec #:phase 'active))]
         [ac-raw (list (lower-dsl-statement-to-boba-ir ac-raw spec #:phase 'active))]
         [else '()]))

     (define mem-ops
       (or kw-mem-ops
           (hash-ref dsl-input 'mem-ops #f)
           (let ([vram-b (hash-ref dsl-input 'vram-dma-bytes 16)])
             (if (> vram-b 0)
                 (list (ir-mem-write (target-spec-tile-mem-name spec)
                                     default-vram-width
                                     default-vram-align
                                     'vblank
                                     'cache-flushed
                                     (min vram-b (target-spec-tile-mem-bytes-max spec)))
                       (ir-dma-transfer 'dma
                                        (min 160 (target-spec-dma-bytes-max spec))
                                        default-dma-align
                                        'vblank
                                        'cache-flushed))
                 '()))))
     (define mode-ops
       (or kw-mode-ops (hash-ref dsl-input 'mode-ops '())))
     (define session-ops
       (or kw-session-ops (hash-ref dsl-input 'session-ops '())))

     (make-boba-ir-module
      #:name           (or kw-name (hash-ref dsl-input 'name 'boba-core-module))
      #:target         spec
      #:fast-ram-vars  fast-vars
      #:work-ram-vars  work-vars
      #:tiles          tiles
      #:palettes       (or kw-palettes (hash-ref dsl-input 'palettes '()))
      #:metasprites    (or kw-metasprites (hash-ref dsl-input 'metasprites '()))
      #:state-machines (or kw-state-machines (hash-ref dsl-input 'state-machines '()))
      #:vblank-ops     vb-ops
      #:hblank-ops     hb-ops
      #:active-ops     ac-ops
      #:mem-ops        mem-ops
      #:mode-ops       mode-ops
      #:session-ops    session-ops
      #:metadata       dsl-input)]
    [(list? dsl-input)
     ;; Lower a list of surface `#lang boba-nes` forms
     (define eff-target (or kw-target pos-target 'nes))
     (define spec (get-target-spec eff-target))
     (define lowered-stmts
       (for/list ([form (in-list dsl-input)])
         (lower-dsl-statement-to-boba-ir form spec #:phase 'active)))
     (make-boba-ir-module
      #:name           (or kw-name 'boba-dsl-lowered)
      #:target         spec
      #:tiles          (or kw-tiles '())
      #:palettes       (or kw-palettes '())
      #:metasprites    (or kw-metasprites '())
      #:state-machines (or kw-state-machines '())
      #:vblank-ops     '()
      #:hblank-ops     '()
      #:active-ops     lowered-stmts
      #:mem-ops        (or kw-mem-ops '())
      #:mode-ops       (or kw-mode-ops '())
      #:session-ops    (or kw-session-ops '()))]
    [else
     (error 'lower-dsl-to-boba-core-ir "Unsupported DSL input for Boba-Core IR lowering: ~v" dsl-input)]))
