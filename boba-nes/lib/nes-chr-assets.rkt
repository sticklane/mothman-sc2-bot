#lang racket/base

;; ============================================================================
;; lib/nes-chr-assets.rkt
;; Resource, Typography & CHR Asset Library for #lang boba-nes
;;
;; Separates Art Style, Character Typography, Sprite/Metasprite Conventions,
;; and Commercial iNES ROM Asset Extraction from the Core Hardware Language.
;; ============================================================================

(require (for-syntax racket/base
                     racket/path)
         racket/file
         racket/list
         racket/match
         racket/path
         racket/string
         "../compiler/mos6502-assembler.rkt"
         "../compiler/boba-rom-builder.rkt")

(provide
 ;; 1. iNES 1.0 ROM Header & Binary Slice Extraction
 parse-ines-header
 extract-ines-chr-rom
 extract-ines-prg-slice
 copy-chr-tiles!
 extract-chr-tile-rows

 ;; 2. Authentic Commercial NES ROM CHR Builders (Mario, Zelda, Tetris)
 DEFAULT-SMB-ROM-PATH
 DEFAULT-ZELDA-ROM-PATH
 DEFAULT-TETRIS-ROM-PATH
 load-authentic-smb-chr-rom
 load-authentic-zelda-chr-rom
 load-authentic-tetris-chr-rom

 ;; 3. Character Maps & HUD Typography (Separated from Boba 3x5 Pill Badges)
 make-char-map
 NINTENDO-STD-CHAR-MAP
 TETRIS-CHAR-MAP
 char-map-lookup
 encode-char-map-string
 emit-nametable-string-6502

 ;; 4. Hardware-Parameterized Metasprite Constructors (Row-Major vs Col-Major vs Symmetric-Vertical)
 OAM-FLIP-H
 OAM-FLIP-V
 make-metasprite-desc
 emit-metasprite-oam-6502

 ;; 5. Compiler Optimization Pass: 2bpp CHR Tile Deduplication & Flip-Folding
 reverse-tile-row-bits
 flip-chr-tile-horizontal
 deduplicate-chr-tiles)

;; ============================================================================
;; 1. iNES 1.0 ROM Header & Binary Slice Extraction
;; ============================================================================

(define (rom-source->bytes src)
  (cond
    [(bytes? src) src]
    [(or (path? src) (string? src)) (file->bytes src)]
    [else (error 'rom-source->bytes "expected bytes? or path-string?, got ~v" src)]))

(define (parse-ines-header src)
  (define rom (rom-source->bytes src))
  (when (< (bytes-length rom) 16)
    (error 'parse-ines-header "file too small (< 16 bytes)"))
  (unless (and (= (bytes-ref rom 0) #x4E) ; 'N'
               (= (bytes-ref rom 1) #x45) ; 'E'
               (= (bytes-ref rom 2) #x53) ; 'S'
               (= (bytes-ref rom 3) #x1A))
    (error 'parse-ines-header "invalid iNES magic header (expected \"NES\\x1A\")"))
  (define prg-banks (bytes-ref rom 4))
  (define chr-banks (bytes-ref rom 5))
  (define flags6    (bytes-ref rom 6))
  (define flags7    (bytes-ref rom 7))
  (define mapper    (bitwise-ior (arithmetic-shift (bitwise-and flags6 #xF0) -4)
                                 (bitwise-and flags7 #xF0)))
  (define mirroring (if (bitwise-bit-set? flags6 0) 'vertical 'horizontal))
  (define battery?  (bitwise-bit-set? flags6 1))
  (define trainer?  (bitwise-bit-set? flags6 2))
  (define prg-offset (+ 16 (if trainer? 512 0)))
  (define prg-bytes  (* prg-banks 16384))
  (define chr-offset (+ prg-offset prg-bytes))
  (define chr-bytes  (* chr-banks 8192))
  (hasheq 'prg-banks  prg-banks
          'chr-banks  chr-banks
          'mapper     mapper
          'mirroring  mirroring
          'battery?   battery?
          'chr-ram?   (zero? chr-banks)
          'prg-offset prg-offset
          'prg-bytes  prg-bytes
          'chr-offset chr-offset
          'chr-bytes  chr-bytes
          'total-size (bytes-length rom)))

(define (extract-ines-chr-rom src #:bank-4k [bank-4k #f] #:bank-8k [bank-8k #f])
  (define rom (rom-source->bytes src))
  (define hdr (parse-ines-header rom))
  (define chr-off (hash-ref hdr 'chr-offset))
  (define chr-len (hash-ref hdr 'chr-bytes))
  (when (zero? chr-len)
    (error 'extract-ines-chr-rom "ROM uses CHR-RAM (0 CHR-ROM banks); use extract-ines-prg-slice"))
  (cond
    [bank-4k
     (define off (+ chr-off (* bank-4k 4096)))
     (subbytes rom off (+ off 4096))]
    [bank-8k
     (define off (+ chr-off (* bank-8k 8192)))
     (subbytes rom off (+ off 8192))]
    [else
     (subbytes rom chr-off (+ chr-off chr-len))]))

(define (extract-ines-prg-slice src prg-offset byte-len)
  (define rom (rom-source->bytes src))
  (define hdr (parse-ines-header rom))
  (define start (+ (hash-ref hdr 'prg-offset) prg-offset))
  (subbytes rom start (+ start byte-len)))

(define (copy-chr-tiles! dest-chr dest-tile-id src-bytes [src-byte-offset 0] [num-tiles #f]
                         #:pattern-table [pt 0])
  (define count (or num-tiles (quotient (- (bytes-length src-bytes) src-byte-offset) 16)))
  (define dest-start (+ (* pt 4096) (* dest-tile-id 16)))
  (bytes-copy! dest-chr dest-start src-bytes src-byte-offset (+ src-byte-offset (* count 16))))

;; Decode a 16-byte 2bpp planar NES tile back into 8 ASCII rows of '.', '1', '2', '3'
(define (extract-chr-tile-rows chr-bytes tile-id #:pattern-table [pt 0])
  (define base (+ (* pt 4096) (* tile-id 16)))
  (for/list ([r (in-range 8)])
    (define p0 (bytes-ref chr-bytes (+ base r)))
    (define p1 (bytes-ref chr-bytes (+ base r 8)))
    (list->string
     (for/list ([c (in-range 7 -1 -1)])
       (define v (+ (bitwise-bit-field p0 c (+ c 1))
                    (* 2 (bitwise-bit-field p1 c (+ c 1)))))
       (case v
         [(0) #\.]
         [(1) #\1]
         [(2) #\2]
         [(3) #\3])))))

;; ============================================================================
;; 2. Authentic Commercial NES ROM CHR Builders (Mario, Zelda, Tetris)
;; ============================================================================

(define-syntax (get-repo-root stx)
  (datum->syntax stx (path->string (simplify-path (build-path (syntax-source stx) 'up 'up)))))

(define HERE-DIR (string->path (get-repo-root)))

(define DEFAULT-SMB-ROM-PATH    (build-path HERE-DIR "assets" "roms" "super_mario_bros.nes"))
(define DEFAULT-ZELDA-ROM-PATH  (build-path HERE-DIR "assets" "roms" "legend_of_zelda.nes"))
(define DEFAULT-TETRIS-ROM-PATH (build-path HERE-DIR "assets" "roms" "tetris.nes"))

;; 2.1 Super Mario Bros. (1985):
;; Directly extracts the 8 KB CHR-ROM bank (offset 32784, 8192 B):
;;   - Pattern Table 0 ($0000-$0FFF): Sprites (Small Mario #x32..#x35, Goomba #x70..#x73,
;;     Coin #x60, Sprite-0 HUD Coin Bottom Anchor #xFF)
;;   - Pattern Table 1 ($1000-$1FFF): Backgrounds (0-9 at #x00..#x09, A-Z at #x0A..#x23,
;;     Blank Sky #x24, HUD Coin #x2E, '?' Block #x53..#x56, Empty Block #x57..#x5A,
;;     Warp Pipe #x60..#x67, Cracked Ground Brick #xB4..#xB7)
(define (load-authentic-smb-chr-rom [rom-path DEFAULT-SMB-ROM-PATH])
  (extract-ines-chr-rom rom-path #:bank-8k 0))

;; 2.2 The Legend of Zelda (1986):
;; Extracts the 4 CHR-RAM pattern blocks embedded inside Zelda's PRG-ROM
;; (per aldonunez/zelda1-disassembly bins.xml) and composites an 8 KB CHR image:
;;   - PT0 ($0000-$06FF): CommonSpritePatterns (PRG offset 32895, 1792 B)
;;                        Link (#x00..#x03 col-major), Sword (#x20/#x22), Key (#x28), Triforce (#x2E)
;;   - PT0 ($0700-$0E1F): PatternBlockOWSP (PRG offset 53595, 1824 B)
;;                        Red Octorok (#x70, #x71 + H-Flip)
;;   - PT1 ($1000-$16FF): CommonBackgroundPatterns (PRG offset 34687, 1792 B)
;;                        0-9 (#x00..#x09), A-Z (#x0A..#x23), Blank (#x24), Heart (#x65/#x66)
;;   - PT1 ($1700-$1F1F): PatternBlockOWBG (PRG offset 51515, 2080 B)
;;                        Overworld Craggy Rocks (#x70..#x73), Ground (#x84..#x87)
(define DEFAULT-ZELDA-DECOMPILED-CHR-PATH
  (build-path HERE-DIR "assets" "decompiled" "zelda_overworld_chr8k.bin"))

(define (load-authentic-zelda-chr-rom [rom-path DEFAULT-ZELDA-ROM-PATH])
  (if (file-exists? DEFAULT-ZELDA-DECOMPILED-CHR-PATH)
      (bytes-copy (file->bytes DEFAULT-ZELDA-DECOMPILED-CHR-PATH))
      (let ([rom (rom-source->bytes rom-path)]
            [chr8k (make-bytes 8192 0)])
        (define common-sp (extract-ines-prg-slice rom 32895 1792))
        (define ow-sp     (extract-ines-prg-slice rom 53595 1824))
        (define common-bg (extract-ines-prg-slice rom 34687 1792))
        (define ow-bg     (extract-ines-prg-slice rom 51515 2080))
        (copy-chr-tiles! chr8k #x00 common-sp 0 #:pattern-table 0)
        (copy-chr-tiles! chr8k #x70 ow-sp     0 #:pattern-table 0)
        (copy-chr-tiles! chr8k #x00 common-bg 0 #:pattern-table 1)
        (copy-chr-tiles! chr8k #x70 ow-bg     0 #:pattern-table 1)
        chr8k)))

;; 2.3 Nintendo NES Tetris (1989):
;; Extracts 4 KB CHR Bank 3 (the in-game playfield & Tetromino bank at file offset 45072)
;; and maps it into both Pattern Table 0 ($0000-$0FFF, Sprites) and Pattern Table 1 ($1000-$1FFF, BG):
;;   - 0-9 (#x00..#x09), A-Z (#x0A..#x23), '-' (#x24)
;;   - White-Centered Mino (#x7B), Primary Solid Mino (#x7C), Secondary Solid Mino (#x7D)
;;   - Empty Black Tile (#xEF / #xFF)
(define (load-authentic-tetris-chr-rom [rom-path DEFAULT-TETRIS-ROM-PATH])
  (define bank3 (extract-ines-chr-rom rom-path #:bank-4k 3))
  (define chr8k (make-bytes 8192 0))
  (bytes-copy! chr8k 0    bank3 0 4096)
  (bytes-copy! chr8k 4096 bank3 0 4096)
  chr8k)

;; ============================================================================
;; 3. Character Maps & HUD Typography
;; ============================================================================
;; Notice the hardware-software co-design discovery from real Nintendo ROMs:
;; All three Nintendo games (SMB1, Zelda, Tetris) place '0'..'9' at tile IDs #x00..#x09
;; and 'A'..'Z' at tile IDs #x0A..#x23 so that writing a BCD digit 0..9 in NMI requires
;; ZERO `ADC #offset` instructions (`LDA zp_digit; STA $2007`)!

(define (make-char-map #:digit-base [digit-base #x00]
                       #:alpha-base [alpha-base #x0A]
                       #:space-tile [space-tile #x24]
                       #:extra      [extra-alist '()])
  (define ht (make-hasheq))
  (for ([d (in-range 10)])
    (hash-set! ht (integer->char (+ (char->integer #\0) d)) (+ digit-base d)))
  (for ([c (in-range 26)])
    (define upper (integer->char (+ (char->integer #\A) c)))
    (define lower (integer->char (+ (char->integer #\a) c)))
    (hash-set! ht upper (+ alpha-base c))
    (hash-set! ht lower (+ alpha-base c)))
  (hash-set! ht #\space space-tile)
  (for ([pair (in-list extra-alist)])
    (hash-set! ht (car pair) (cdr pair)))
  ht)

;; Standard Nintendo CHR Typography (Super Mario Bros. & The Legend of Zelda):
(define NINTENDO-STD-CHAR-MAP
  (make-char-map #:digit-base #x00
                 #:alpha-base #x0A
                 #:space-tile #x24
                 #:extra (list (cons #\- #x28)
                               (cons #\x #x29)
                               (cons #\* #x2E) ; Coin icon in SMB1
                               (cons #\= #x65)))) ; Heart icon in Zelda

;; Nintendo NES Tetris CHR Bank 3 Typography (Empty space is #xEF or #xFF; #x24 is '-'):
(define TETRIS-CHAR-MAP
  (make-char-map #:digit-base #x00
                 #:alpha-base #x0A
                 #:space-tile #xFF
                 #:extra (list (cons #\- #x24)
                               (cons #\: #x25))))

(define (char-map-lookup cmap ch)
  (hash-ref cmap ch (lambda () (hash-ref cmap #\space #x24))))

(define (encode-char-map-string cmap str)
  (for/list ([ch (in-string str)])
    (char-map-lookup cmap ch)))

(define (emit-nametable-string-6502 vram-addr cmap str)
  (define hi (bitwise-and #xFF (arithmetic-shift vram-addr -8)))
  (define lo (bitwise-and #xFF vram-addr))
  (define tile-ids (encode-char-map-string cmap str))
  (append
   `((BIT #:abs #x2002)
     (LDA #:imm ,hi)
     (STA #:abs #x2006)
     (LDA #:imm ,lo)
     (STA #:abs #x2006))
   (apply append
          (for/list ([tid (in-list tile-ids)])
            `((LDA #:imm ,tid)
              (STA #:abs #x2007))))))

;; ============================================================================
;; 4. Hardware-Parameterized Metasprite Constructors (Row-Major vs Col-Major)
;; ============================================================================
;; Real NES games use distinct metasprite tile orderings in CHR-ROM:
;;   1. 'row-major (Super Mario Bros.): [t0=TL, t1=TR, t2=BL, t3=BR] (16x16, 4 sprites)
;;   2. 'col-major (Legend of Zelda)  : [t0=TL, t1=BL, t2=TR, t3=BR] (16x16, 4 sprites)
;;   3. 'symmetric-col-major (Zelda Octorok / Link Down):
;;      Uses only 2 CHR tiles [t0=TL, t1=BL] and sets OAM Horizontal Flip (#x40) on TR and BR!
;;   4. 'symmetric-vertical:
;;      8x16 vertical 2-sprite metasprite where tile 0 is drawn at (X, Y) with `attr`
;;      and tile 1 is drawn at (X, Y+8) with `(bitwise-ior attr OAM-FLIP-V)` (#x80 vertical flip),
;;      or 2 explicit tiles `(list top-tile bottom-tile)`.

(define OAM-FLIP-H #x40)
(define OAM-FLIP-V #x80)

(define (make-metasprite-desc name tiles [pos-attr #f]
                              #:order [order 'row-major]
                              #:attr [kw-attr #f]
                              #:tr-attr [tr-attr #f]
                              #:br-attr [br-attr #f]
                              #:bl-attr [bl-attr #f])
  (define attr (or pos-attr kw-attr 0))
  (define tile-list (if (list? tiles) tiles (list tiles)))
  (cond
    [(eq? order 'symmetric-vertical)
     (when (null? tile-list)
       (error 'make-metasprite-desc "symmetric-vertical requires 1 or 2 tiles, got ~v" tiles))
     (define top-tile (first tile-list))
     (define bot-tile (if (>= (length tile-list) 2) (second tile-list) top-tile))
     (define vflip-attr (or bl-attr (bitwise-ior attr OAM-FLIP-V)))
     (hasheq 'name       name
             'order      order
             'tl         top-tile
             'bl         bot-tile
             'top        top-tile
             'bottom     bot-tile
             'attr       attr
             'bl-attr    vflip-attr
             'bottom-attr vflip-attr
             'oam-sprites 2
             'scanline-sprites 1)]
    [else
     (match-define (list tl tr bl br)
       (case order
         [(row-major)
          (unless (= (length tile-list) 4)
            (error 'make-metasprite-desc "row-major requires 4 tiles (TL TR BL BR), got ~v" tiles))
          tile-list]
         [(col-major)
          (unless (= (length tile-list) 4)
            (error 'make-metasprite-desc "col-major requires 4 tiles (TL BL TR BR), got ~v" tiles))
          (list (first tile-list) (third tile-list) (second tile-list) (fourth tile-list))]
         [(symmetric-col-major)
          (unless (>= (length tile-list) 2)
            (error 'make-metasprite-desc "symmetric-col-major requires 2 left-half tiles (TL BL), got ~v" tiles))
          (list (first tile-list) (first tile-list) (second tile-list) (second tile-list))]
         [else
          (error 'make-metasprite-desc "unknown metasprite order ~v" order)]))
     (define right-flip-attr (bitwise-ior attr OAM-FLIP-H))
     (hasheq 'name    name
             'order   order
             'tl      tl
             'tr      tr
             'bl      bl
             'br      br
             'attr    attr
             'bl-attr (or bl-attr attr)
             'tr-attr (or tr-attr (if (eq? order 'symmetric-col-major) right-flip-attr attr))
             'br-attr (or br-attr (if (eq? order 'symmetric-col-major) right-flip-attr attr))
             'oam-sprites 4
             'scanline-sprites 2)]))

(define (emit-metasprite-oam-6502 ms-desc zp-x zp-y oam-base)
  (define order (hash-ref ms-desc 'order 'row-major))
  (cond
    [(eq? order 'symmetric-vertical)
     (define top-tile (hash-ref ms-desc 'tl))
     (define bot-tile (hash-ref ms-desc 'bl top-tile))
     (define attr     (hash-ref ms-desc 'attr 0))
     (define bot-attr (hash-ref ms-desc 'bl-attr (bitwise-ior attr OAM-FLIP-V)))
     `((LDA #:zp ,zp-y)
       (STA #:abs ,(+ #x0200 oam-base 0))
       (CLC)
       (ADC #:imm 8)
       (STA #:abs ,(+ #x0200 oam-base 4))
       (LDA #:imm ,top-tile)
       (STA #:abs ,(+ #x0200 oam-base 1))
       (LDA #:imm ,bot-tile)
       (STA #:abs ,(+ #x0200 oam-base 5))
       (LDA #:imm ,attr)
       (STA #:abs ,(+ #x0200 oam-base 2))
       (LDA #:imm ,bot-attr)
       (STA #:abs ,(+ #x0200 oam-base 6))
       (LDA #:zp ,zp-x)
       (STA #:abs ,(+ #x0200 oam-base 3))
       (STA #:abs ,(+ #x0200 oam-base 7)))]
    [else
     (define tl      (hash-ref ms-desc 'tl))
     (define tr      (hash-ref ms-desc 'tr))
     (define bl      (hash-ref ms-desc 'bl))
     (define br      (hash-ref ms-desc 'br))
     (define attr    (hash-ref ms-desc 'attr 0))
     (define tr-attr (hash-ref ms-desc 'tr-attr attr))
     (define br-attr (hash-ref ms-desc 'br-attr attr))
     (append
      `((LDA #:zp ,zp-y)
        (STA #:abs ,(+ #x0200 oam-base 0))
        (STA #:abs ,(+ #x0200 oam-base 4))
        (CLC)
        (ADC #:imm 8)
        (STA #:abs ,(+ #x0200 oam-base 8))
        (STA #:abs ,(+ #x0200 oam-base 12))
        (LDA #:imm ,tl)
        (STA #:abs ,(+ #x0200 oam-base 1))
        (LDA #:imm ,tr)
        (STA #:abs ,(+ #x0200 oam-base 5))
        (LDA #:imm ,bl)
        (STA #:abs ,(+ #x0200 oam-base 9))
        (LDA #:imm ,br)
        (STA #:abs ,(+ #x0200 oam-base 13))
        (LDA #:imm ,attr)
        (STA #:abs ,(+ #x0200 oam-base 2))
        (STA #:abs ,(+ #x0200 oam-base 10)))
      (if (and (= tr-attr attr) (= br-attr attr))
          `((STA #:abs ,(+ #x0200 oam-base 6))
            (STA #:abs ,(+ #x0200 oam-base 14)))
          `((LDA #:imm ,tr-attr)
            (STA #:abs ,(+ #x0200 oam-base 6))
            (LDA #:imm ,br-attr)
            (STA #:abs ,(+ #x0200 oam-base 14))))
      `((LDA #:zp ,zp-x)
        (STA #:abs ,(+ #x0200 oam-base 3))
        (STA #:abs ,(+ #x0200 oam-base 11))
        (CLC)
        (ADC #:imm 8)
        (STA #:abs ,(+ #x0200 oam-base 7))
        (STA #:abs ,(+ #x0200 oam-base 15))))]))

;; ============================================================================
;; 5. Compiler Optimization Pass: 2bpp CHR Tile Deduplication & Flip-Folding
;; ============================================================================
;; Given a list of (cons tile-id 16-byte-tile-bytes), identifies duplicate 8x8 tiles
;; AND horizontally mirrored 8x8 tiles (which can share a single CHR tile via OAM bit 6!),
;; reducing the module's Phi3 CHR tile grade automatically.

(define (reverse-tile-row-bits b)
  (for/fold ([acc 0]) ([i (in-range 8)])
    (bitwise-ior (arithmetic-shift acc 1)
                 (bitwise-bit-field b i (+ i 1)))))

(define (flip-chr-tile-horizontal tile16)
  (bytes->immutable-bytes
   (list->bytes
    (for/list ([b (in-bytes tile16)])
      (reverse-tile-row-bits b)))))

(define (deduplicate-chr-tiles tile-byte-alist #:fold-hflip? [fold-hflip? #t])
  (define seen-exact (make-hash)) ; immutable-bytes -> canonical-tile-id
  (define unique-alist '())
  (define remap-table (make-hasheq)) ; old-tile-id -> (hasheq 'tile-id canon-id 'hflip? bool)
  (define exact-dups 0)
  (define hflip-dups 0)

  (for ([entry (in-list tile-byte-alist)])
    (define tid (car entry))
    (define raw (cdr entry))
    (define tbytes
      (bytes->immutable-bytes
       (if (bytes? raw) raw (compile-chr-tile raw))))
    (define flipped (flip-chr-tile-horizontal tbytes))
    (cond
      [(hash-has-key? seen-exact tbytes)
       (set! exact-dups (add1 exact-dups))
       (hash-set! remap-table tid
                  (hasheq 'tile-id (hash-ref seen-exact tbytes)
                          'hflip? #f))]
      [(and fold-hflip? (hash-has-key? seen-exact flipped))
       (set! hflip-dups (add1 hflip-dups))
       (hash-set! remap-table tid
                  (hasheq 'tile-id (hash-ref seen-exact flipped)
                          'hflip? #t))]
      [else
       (hash-set! seen-exact tbytes tid)
       (set! unique-alist (cons (cons tid tbytes) unique-alist))
       (hash-set! remap-table tid
                  (hasheq 'tile-id tid
                          'hflip? #f))]))

  (hasheq 'unique-tiles      (reverse unique-alist)
          'remap-table       remap-table
          'original-count    (length tile-byte-alist)
          'deduped-count     (length unique-alist)
          'exact-saved       exact-dups
          'hflip-saved       hflip-dups
          'total-tiles-saved (+ exact-dups hflip-dups)))
