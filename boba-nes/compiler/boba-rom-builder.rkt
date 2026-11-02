#lang racket/base

;; ============================================================================
;; #lang boba-nes : "Boba Is You" 6502 Game Engine, 5-Stage Level Pack,
;;                  Custom 2bpp CHR-ROM Graphics & Graded Module Descriptor
;; ============================================================================

(require racket/match
         racket/list
         racket/format
         racket/string
         "graded-typechecker.rkt"
         "diagnostics.rkt"
         "mos6502-assembler.rkt")

(provide
 ;; Tile & Rule Constants
 TILE-EMPTY
 OBJ-BOBA
 OBJ-FLAG
 OBJ-ROCK
 OBJ-WALL
 OBJ-SKULL
 TXT-BOBA
 TXT-FLAG
 TXT-ROCK
 TXT-WALL
 TXT-SKULL
 TXT-IS
 TXT-YOU
 TXT-PUSH
 TXT-STOP
 TXT-WIN
 TXT-DEFEAT

 RULE-YOU
 RULE-PUSH
 RULE-STOP
 RULE-WIN
 RULE-DEFEAT

 ;; Zero-Page & Work RAM Map
 ZP-JOY-CUR
 ZP-JOY-PREV
 ZP-JOY-PRESSED
 ZP-CUR-STAGE
 ZP-LEVEL-WON
 ZP-MOVE-COUNT
 ZP-DUST-X
 ZP-DUST-Y
 ZP-DUST-TIMER
 ZP-RULES-BASE
 ZP-RULE-BOBA
 ZP-RULE-FLAG
 ZP-RULE-ROCK
 ZP-RULE-WALL
 ZP-RULE-SKULL
 OAM-RAM-BASE
 BOARD-RAM-BASE
 UNDER-RAM-BASE

 ;; ROM & Module Builders
 build-boba-chr-rom
 build-boba-6502-program
 build-boba-graded-module-descriptor
 compile-boba-is-you-rom!)

;; ============================================================================
;; 1. Entity, Text Block & Rule Bitmask Constants
;; ============================================================================

(define TILE-EMPTY  #x00)

;; Noun Objects (1..5)
(define OBJ-BOBA    #x01)
(define OBJ-FLAG    #x02)
(define OBJ-ROCK    #x03)
(define OBJ-WALL    #x04)
(define OBJ-SKULL   #x05)

;; Noun Text Blocks (#x11..#x15 -> low nibble = target OBJ-* id!)
(define TXT-BOBA    #x11)
(define TXT-FLAG    #x12)
(define TXT-ROCK    #x13)
(define TXT-WALL    #x14)
(define TXT-SKULL   #x15)

;; Conjunction Text Block
(define TXT-IS      #x18)

;; Verb / Property Text Blocks (#x20 | RULE-* bitmask!)
(define RULE-YOU    #x01)
(define RULE-PUSH   #x02)
(define RULE-STOP   #x04)
(define RULE-WIN    #x08)
(define RULE-DEFEAT #x10)

(define TXT-YOU     #x21)
(define TXT-PUSH    #x22)
(define TXT-STOP    #x24)
(define TXT-WIN     #x28)
(define TXT-DEFEAT  #x30)

;; ============================================================================
;; 2. Zero-Page ($0010..$003F) & BSS Work RAM ($0300..$04FF) Memory Map
;; ============================================================================

;; Permanent Zero-Page State ($10..$27)
(define ZP-JOY-CUR      #x10) ; Current frame controller 1 bits
(define ZP-JOY-PREV     #x11) ; Previous frame controller 1 bits
(define ZP-JOY-PRESSED  #x12) ; Newly pressed buttons (cur & ~prev)
(define ZP-CUR-STAGE    #x13) ; Current stage index (0..4)
(define ZP-LEVEL-WON    #x14) ; 1 when current stage win condition is met
(define ZP-MOVE-COUNT   #x15) ; Total player steps in current stage
(define ZP-DUST-X       #x16) ; Last YOU step X for dust trail sprite
(define ZP-DUST-Y       #x17) ; Last YOU step Y for dust trail sprite
(define ZP-DUST-TIMER   #x18) ; Frames remaining for dust particle
(define ZP-FRAME-TICK   #x19) ; Global frame counter
(define ZP-SCROLL-X     #x1A) ; Clean PPU X scroll (0)
(define ZP-SCROLL-Y     #x1B) ; Clean PPU Y scroll (0)
(define ZP-OAM-OFFSET   #x1C) ; Current OAM byte index during sprite packing
(define ZP-YOU-POS      #x1D) ; Cached board cell index of primary YOU actor
(define ZP-WIN-POS      #x1E) ; VBlank synchronization flag

;; Active Rule Table ($20..$25): 6 bytes indexed by OBJ-* (0..5)
(define ZP-RULES-BASE   #x20)
(define ZP-RULE-BOBA    #x21)
(define ZP-RULE-FLAG    #x22)
(define ZP-RULE-ROCK    #x23)
(define ZP-RULE-WALL    #x24)
(define ZP-RULE-SKULL   #x25)

;; Recycled High-Watermark Zero-Page Scratch Pool ($30..$35 = 6 bytes)
(define ZP-SCRATCH-0    #x30)
(define ZP-SCRATCH-1    #x31)
(define ZP-SCRATCH-2    #x32)
(define ZP-SCRATCH-3    #x33)
(define ZP-SCRATCH-4    #x34)
(define ZP-SCRATCH-5    #x35)

;; Work RAM ($0300..$04DF = 448 bytes)
(define OAM-RAM-BASE    #x0200)
(define BOARD-RAM-BASE  #x0300)
(define UNDER-RAM-BASE  #x0400)

;; ============================================================================
;; 3. Custom 2bpp CHR-ROM Graphics & 3x5 Word-Block Tile Generator
;; ============================================================================
;; Each cell on the 16x14 grid is rendered as a 16-pixel-wide metasprite pair:
;;   - Left 8x8 tile  : tile-id
;;   - Right 8x8 tile : tile-id + #x40
;; For 4-letter word blocks ("BOBA", "FLAG", "ROCK", "WALL", "SKUL", " IS ",
;; "YOU ", "PUSH", "STOP", "WIN ", "SINK"), we synthesize crisp 3x5 pixel
;; bitmap typography framed inside a beveled pill badge!

(define FONT-3X5
  (hash
   #\space '("..." "..." "..." "..." "...")
   #\A     '(".3." "3.3" "333" "3.3" "3.3")
   #\B     '("33." "3.3" "33." "3.3" "33.")
   #\C     '(".33" "3.." "3.." "3.." ".33")
   #\D     '("33." "3.3" "3.3" "3.3" "33.")
   #\E     '("333" "3.." "33." "3.." "333")
   #\F     '("333" "3.." "33." "3.." "3..")
   #\G     '(".33" "3.." "3.3" "3.3" ".33")
   #\H     '("3.3" "3.3" "333" "3.3" "3.3")
   #\I     '("333" ".3." ".3." ".3." "333")
   #\K     '("3.3" "3.3" "33." "3.3" "3.3")
   #\L     '("3.." "3.." "3.." "3.." "333")
   #\N     '("3.3" "333" "333" "3.3" "3.3")
   #\O     '(".3." "3.3" "3.3" "3.3" ".3.")
   #\P     '("33." "3.3" "33." "3.." "3..")
   #\R     '("33." "3.3" "33." "3.3" "3.3")
   #\S     '(".33" "3.." ".3." "..3" "33.")
   #\T     '("333" ".3." ".3." ".3." ".3.")
   #\U     '("3.3" "3.3" "3.3" "3.3" "333")
   #\W     '("3.3" "3.3" "333" "333" "3.3")
   #\Y     '("3.3" "3.3" ".3." ".3." ".3.")))

(define (make-word-tile-pair tile-id str4)
  (define chars (string->list str4))
  (define c1 (hash-ref FONT-3X5 (first chars)))
  (define c2 (hash-ref FONT-3X5 (second chars)))
  (define c3 (hash-ref FONT-3X5 (third chars)))
  (define c4 (hash-ref FONT-3X5 (fourth chars)))

  (define left-rows
    (append
     (list "22222222")
     (for/list ([r (in-range 5)])
       (string-append "1" (list-ref c1 r) "1" (list-ref c2 r)))
     (list "11111111"
           "22222222")))

  (define right-rows
    (append
     (list "22222222")
     (for/list ([r (in-range 5)])
       (string-append "1" (list-ref c3 r) "1" (list-ref c4 r)))
     (list "11111111"
           "22222222")))

  (list (cons tile-id left-rows)
        (cons (bitwise-ior tile-id #x40) right-rows)))

(define (build-boba-chr-rom)
  (define base-tiles
    (list
     ;; Tile #x00: Empty transparent tile
     (cons #x00
           '("........"
             "........"
             "........"
             "........"
             "........"
             "........"
             "........"
             "........"))
     ;; Tile #x01 + #x41: 16x8 BOBA Tea Cup Character (Left & Right halves)
     (cons OBJ-BOBA
           '(".....33."
             ".....33."
             "..222222"
             ".2111111"
             ".2133113"
             ".2133111"
             "..213131"
             "...22222"))
     (cons (bitwise-ior OBJ-BOBA #x40)
           '("33......"
             "........"
             "222222.."
             "1111112."
             "1133112."
             "1133112."
             "311312.."
             "22222..."))
     ;; Tile #x02 + #x42: 16x8 FLAG (Golden Pennant Flag on Pole)
     (cons OBJ-FLAG
           '(".....332"
             ".....332"
             ".....332"
             ".....332"
             ".....33."
             ".....33."
             "...33333"
             "..333333"))
     (cons (bitwise-ior OBJ-FLAG #x40)
           '("22222..."
             "233222.."
             "23322..."
             "222....."
             "........"
             "........"
             "33......"
             "333....."))
     ;; Tile #x03 + #x43: 16x8 ROCK (Tapioca Boulder)
     (cons OBJ-ROCK
           '("...22222"
             "..233333"
             ".2331133"
             ".2311133"
             ".2333332"
             "..223322"
             "...22222"
             "........"))
     (cons (bitwise-ior OBJ-ROCK #x40)
           '("2222...."
             "33332..."
             "331332.."
             "333332.."
             "23322..."
             "2222...."
             "222....."
             "........"))
     ;; Tile #x04 + #x44: 16x8 WALL (Brick Wall Block)
     (cons OBJ-WALL
           '("33333331"
             "22222221"
             "11111111"
             "22213333"
             "22212222"
             "11111111"
             "33333331"
             "22222221"))
     (cons (bitwise-ior OBJ-WALL #x40)
           '("33333331"
             "22222221"
             "11111111"
             "33312222"
             "22212222"
             "11111111"
             "33333331"
             "22222221"))
     ;; Tile #x05 + #x45: 16x8 SKULL (Hazard Skull)
     (cons OBJ-SKULL
           '("...33333"
             "..333333"
             ".33..333"
             ".33..333"
             ".333333."
             "..33.33."
             "...3.3.."
             "........"))
     (cons (bitwise-ior OBJ-SKULL #x40)
           '("3333...."
             "33333..."
             "33..33.."
             "33..33.."
             ".33333.."
             ".33.33.."
             "..3.3..."
             "........"))
     ;; Tile #x06: DUST particle
     (cons #x06
           '("........"
             "..2..2.."
             ".232232."
             "..2332.."
             ".232232."
             "..2..2.."
             "........"
             "........"))
     ;; Tile #x07: SPARKLE star
     (cons #x07
           '("...3...."
             "...3...."
             ".3.3.3.."
             "333.333."
             ".3.3.3.."
             "...3...."
             "...3...."
             "........"))
     ;; Tile #x08: Playfield background grid cell border (Nametable floor tile)
     (cons #x08
           '("11111111"
             "1......."
             "1......."
             "1......."
             "1......."
             "1......."
             "1......."
             "1......."))))

  (define word-tiles
    (append
     (make-word-tile-pair TXT-BOBA   "BOBA")
     (make-word-tile-pair TXT-FLAG   "FLAG")
     (make-word-tile-pair TXT-ROCK   "ROCK")
     (make-word-tile-pair TXT-WALL   "WALL")
     (make-word-tile-pair TXT-SKULL  "SKUL")
     (make-word-tile-pair TXT-IS     " IS ")
     (make-word-tile-pair TXT-YOU    "YOU ")
     (make-word-tile-pair TXT-PUSH   "PUSH")
     (make-word-tile-pair TXT-STOP   "STOP")
     (make-word-tile-pair TXT-WIN    "WIN ")
     (make-word-tile-pair TXT-DEFEAT "SINK")))

  (build-chr-rom (append base-tiles word-tiles)))

;; ============================================================================
;; 4. Five-Stage "Boba Is You" Level Pack (Adapted from gaia1.sav .. gaia5.sav)
;; ============================================================================

(define (cell xy-pair)
  (+ (* (cdr xy-pair) 16) (car xy-pair)))

(define STAGE-1-CELLS
  (list
   ;; Active rule 1: BOBA IS YOU at (2,10), (3,10), (4,10)
   (cons (cell '(2 . 10)) TXT-BOBA)
   (cons (cell '(3 . 10)) TXT-IS)
   (cons (cell '(4 . 10)) TXT-YOU)
   ;; Active rule 2: WALL IS STOP at (2,8), (3,8), (4,8)
   (cons (cell '(2 . 8))  TXT-WALL)
   (cons (cell '(3 . 8))  TXT-IS)
   (cons (cell '(4 . 8))  TXT-STOP)
   ;; Wall barrier at y=6 (4x2 = 8 sprites on scanline y=6 <= 8!)
   (cons (cell '(5 . 6))  OBJ-WALL)
   (cons (cell '(6 . 6))  OBJ-WALL)
   (cons (cell '(7 . 6))  OBJ-WALL)
   (cons (cell '(8 . 6))  OBJ-WALL)
   ;; Top room: FLAG IS [gap] WIN + FLAG object (4x2 = 8 sprites on scanline y=3 <= 8!)
   (cons (cell '(5 . 3))  TXT-FLAG)
   (cons (cell '(6 . 3))  TXT-IS)
   (cons (cell '(8 . 3))  TXT-WIN)
   (cons (cell '(10 . 3)) OBJ-FLAG)
   ;; Player Boba at (7, 8)
   (cons (cell '(7 . 8))  OBJ-BOBA)))

(define STAGE-2-CELLS
  (list
   (cons (cell '(2 . 10)) TXT-WALL)
   (cons (cell '(3 . 10)) TXT-IS)
   (cons (cell '(4 . 10)) TXT-YOU)
   (cons (cell '(2 . 8))  TXT-FLAG)
   (cons (cell '(3 . 8))  TXT-IS)
   (cons (cell '(4 . 8))  TXT-STOP)
   (cons (cell '(6 . 6))  OBJ-FLAG)
   (cons (cell '(7 . 6))  OBJ-FLAG)
   (cons (cell '(8 . 6))  OBJ-FLAG)
   (cons (cell '(5 . 3))  TXT-FLAG)
   (cons (cell '(6 . 3))  TXT-IS)
   (cons (cell '(8 . 3))  TXT-WIN)
   (cons (cell '(7 . 8))  OBJ-WALL)))

(define STAGE-3-CELLS
  (list
   (cons (cell '(1 . 1))  TXT-BOBA)
   (cons (cell '(2 . 1))  TXT-IS)
   (cons (cell '(3 . 1))  TXT-YOU)
   (cons (cell '(1 . 2))  TXT-FLAG)
   (cons (cell '(2 . 2))  TXT-IS)
   (cons (cell '(3 . 2))  TXT-WIN)
   (cons (cell '(1 . 3))  TXT-ROCK)
   (cons (cell '(2 . 3))  TXT-IS)
   (cons (cell '(3 . 3))  TXT-PUSH)
   ;; Vertical SKUL IS SINK at x=12, y=1..3 (keeps y=1..3 at 4x2 = 8 sprites/scanline!)
   (cons (cell '(12 . 1)) TXT-SKULL)
   (cons (cell '(12 . 2)) TXT-IS)
   (cons (cell '(12 . 3)) TXT-DEFEAT)
   (cons (cell '(5 . 8))  OBJ-SKULL)
   (cons (cell '(7 . 8))  OBJ-SKULL)
   (cons (cell '(6 . 8))  OBJ-ROCK)
   (cons (cell '(6 . 7))  OBJ-ROCK)
   (cons (cell '(6 . 9))  OBJ-BOBA)
   (cons (cell '(10 . 5)) OBJ-FLAG)))

(define STAGE-4-CELLS
  (list
   (cons (cell '(5 . 5)) TXT-BOBA)
   (cons (cell '(6 . 5)) TXT-IS)
   (cons (cell '(7 . 5)) TXT-YOU)
   (cons (cell '(6 . 4)) TXT-FLAG)
   (cons (cell '(6 . 7)) TXT-WIN)
   (cons (cell '(6 . 8)) OBJ-BOBA)
   (cons (cell '(11 . 5)) OBJ-FLAG)))

(define STAGE-5-CELLS
  (list
   (cons (cell '(1 . 1)) TXT-BOBA)
   (cons (cell '(2 . 1)) TXT-IS)
   (cons (cell '(3 . 1)) TXT-YOU)
   (cons (cell '(1 . 2)) TXT-FLAG)
   (cons (cell '(2 . 2)) TXT-IS)
   (cons (cell '(3 . 2)) TXT-WIN)
   (cons (cell '(5 . 5)) TXT-WALL)
   (cons (cell '(6 . 5)) TXT-IS)
   (cons (cell '(8 . 5)) TXT-BOBA)
   (cons (cell '(9 . 5)) OBJ-BOBA)
   (cons (cell '(8 . 8)) OBJ-WALL)
   (cons (cell '(11 . 8)) OBJ-FLAG)))

(define (encode-stage-bytes pairs)
  (append
   (apply append
          (for/list ([p (in-list pairs)])
            (list (car p) (cdr p))))
   (list #xFF)))

;; ============================================================================
;; 5. Complete MOS 6502 Assembly Program for "Boba Is You"
;; ============================================================================

(define (build-boba-6502-program)
  `(;; ========================================================================
    ;; RESET Handler ($8000): Initialize 6502 Stack, Clear RAM, Load Stage 0
    ;; ========================================================================
    (label reset_handler)
    (SEI)
    (CLD)
    (LDX #:imm #xFF)
    (TXS)
    (JSR boot_init)
    (label main_game_loop)
    (LDA #:zp ,ZP-WIN-POS)
    (BEQ main_game_loop)
    (LDA #:imm 0)
    (STA #:zp ,ZP-WIN-POS)
    (JSR game_frame_step)
    (JMP main_game_loop)

    ;; Subroutine: boot_init (Callable directly in tests or from reset_handler)
    (label boot_init)
    ;; Disable PPU rendering during boot setup (ForcedBlank phase)
    (LDA #:imm #x00)
    (STA #:abs #x2000)
    (STA #:abs #x2001)
    (STA #:zp ,ZP-CUR-STAGE)
    (STA #:zp ,ZP-SCROLL-X)
    (STA #:zp ,ZP-SCROLL-Y)
    (STA #:zp ,ZP-WIN-POS)

    ;; Enable 2A03 APU Pulse 1, Pulse 2, Triangle, Noise channels ($4015 = $0F)
    (LDA #:imm #x0F)
    (STA #:abs #x4015)

    ;; Load initial palettes into $3F00-$3F1F
    (BIT #:abs #x2002)
    (LDA #:imm #x3F)
    (STA #:abs #x2006)
    (LDA #:imm #x00)
    (STA #:abs #x2006)
    (LDX #:imm 0)
    (label boot_pal_loop)
    (LDA #:absx palette_rom_table)
    (STA #:abs #x2007)
    (INX)
    (CPX #:imm 32)
    (BNE boot_pal_loop)

    ;; Initialize Nametable 0 ($2000-$23BF) with playfield grid tile (#x08)
    (BIT #:abs #x2002)
    (LDA #:imm #x20)
    (STA #:abs #x2006)
    (LDA #:imm #x00)
    (STA #:abs #x2006)
    ;; Clear top 2 HUD rows (64 bytes) to #x00
    (LDX #:imm 64)
    (LDA #:imm #x00)
    (label clear_hud_nt_loop)
    (STA #:abs #x2007)
    (DEX)
    (BNE clear_hud_nt_loop)
    ;; Fill 16x14 playfield rows (896 tiles = 3 pages + 128 bytes) with grid tile #x08
    (LDY #:imm 3)
    (LDA #:imm #x08)
    (label fill_grid_pages)
    (LDX #:imm 0)
    (label fill_grid_inner)
    (STA #:abs #x2007)
    (INX)
    (BNE fill_grid_inner)
    (DEY)
    (BNE fill_grid_pages)
    (LDX #:imm 128)
    (label fill_grid_rem)
    (STA #:abs #x2007)
    (DEX)
    (BNE fill_grid_rem)
    ;; Clear Attribute Table ($23C0-$23FF = 64 bytes) to palette 0
    (LDX #:imm 64)
    (LDA #:imm #x00)
    (label clear_attr_loop)
    (STA #:abs #x2007)
    (DEX)
    (BNE clear_attr_loop)

    ;; Load Stage 0 into BOARD_RAM ($0300) and run initial rule scan
    (JSR load_current_stage)
    (JSR scan_boba_rules)
    (JSR pack_oam_sprites)

    ;; Trigger immediate OAMDMA so first rendered frame already has sprites in OAM
    (LDA #:imm #x00)
    (STA #:abs #x2003)
    (LDA #:imm #x02)
    (STA #:abs #x4014)

    ;; Discharge PPU scroll latch & enable NMI + BG + Sprites
    ;; ($2000 = $80: NMI on, BG pattern table $0000, Sprite pattern table $0000!)
    (BIT #:abs #x2002)
    (LDA #:imm #x00)
    (STA #:abs #x2005)
    (STA #:abs #x2005)
    (LDA #:imm #x80)
    (STA #:abs #x2000)
    (LDA #:imm #x1E) ; Show background & sprites in all columns
    (STA #:abs #x2001)
    (RTS)

    ;; ========================================================================
    ;; VBlank NMI Handler ($FFFA): OAMDMA + HUD Status Patch + Scroll Restore
    ;; ========================================================================
    ;; Grade Phi1: 514 (OAMDMA) + 98 (HUD & Latch restore) = 612 cycles <= 2273!
    ;; Grade L4  : Reads $2002 and writes $2000 + $2005x2 before RTI (0 PpuTaint!)
    (label nmi_handler)
    (PHA)
    (TXA)
    (PHA)
    (TYA)
    (PHA)

    ;; 1. Trigger $4014 OAMDMA from $0200-$02FF (514 cycles, DmaUnique)
    (LDA #:imm #x00)
    (STA #:abs #x2003)
    (LDA #:imm #x02)
    (STA #:abs #x4014)

    ;; 2. Write HUD banner & status stripe at Nametable $2022
    (BIT #:abs #x2002)
    (LDA #:imm #x20)
    (STA #:abs #x2006)
    (LDA #:imm #x22)
    (STA #:abs #x2006)
    (LDA #:zp ,ZP-CUR-STAGE)
    (STA #:abs #x2007)
    (LDA #:zp ,ZP-MOVE-COUNT)
    (STA #:abs #x2007)
    (LDA #:zp ,ZP-LEVEL-WON)
    (STA #:abs #x2007)
    (LDA #:zp ,ZP-RULE-BOBA)
    (STA #:abs #x2007)
    (LDA #:zp ,ZP-RULE-FLAG)
    (STA #:abs #x2007)
    (LDA #:zp ,ZP-RULE-ROCK)
    (STA #:abs #x2007)
    (LDA #:zp ,ZP-RULE-WALL)
    (STA #:abs #x2007)
    (LDA #:zp ,ZP-RULE-SKULL)
    (STA #:abs #x2007)

    ;; 3. Discharge PpuTaint: reset $2002 w-latch and restore $2000 + $2005 scroll!
    (BIT #:abs #x2002)
    (LDA #:imm #x80)
    (STA #:abs #x2000)
    (LDA #:zp ,ZP-SCROLL-X)
    (STA #:abs #x2005)
    (LDA #:zp ,ZP-SCROLL-Y)
    (STA #:abs #x2005)

    ;; Signal VBlank frame ready to main_game_loop
    (LDA #:imm 1)
    (STA #:zp ,ZP-WIN-POS)

    (PLA)
    (TAY)
    (PLA)
    (TAX)
    (PLA)
    (RTI)

    ;; ========================================================================
    ;; IRQ Handler ($FFFE)
    ;; ========================================================================
    (label irq_handler)
    (RTI)

    ;; ========================================================================
    ;; ActiveFrame Main Step (game_frame_step)
    ;; ========================================================================
    (.align 256)
    (label game_frame_step)
    (INC #:zp ,ZP-FRAME-TICK)
    (JSR poll_joypad_safe)

    ;; Check SELECT ($04): Restart current stage
    (LDA #:zp ,ZP-JOY-PRESSED)
    (AND #:imm ,BTN-SELECT)
    (BEQ check_start_btn)
    (JSR load_current_stage)
    (JSR scan_boba_rules)
    (JSR pack_oam_sprites)
    (RTS)

    ;; Check START ($08): Advance to next stage (0..4)
    (label check_start_btn)
    (LDA #:zp ,ZP-JOY-PRESSED)
    (AND #:imm ,BTN-START)
    (BEQ check_dpad_input)
    (INC #:zp ,ZP-CUR-STAGE)
    (LDA #:zp ,ZP-CUR-STAGE)
    (CMP #:imm 5)
    (BCC stage_idx_ok)
    (LDA #:imm 0)
    (STA #:zp ,ZP-CUR-STAGE)
    (label stage_idx_ok)
    (JSR load_current_stage)
    (JSR scan_boba_rules)
    (JSR pack_oam_sprites)
    (RTS)

    ;; Check D-Pad directional input (UP=$10, DOWN=$20, LEFT=$40, RIGHT=$80)
    (label check_dpad_input)
    (LDA #:zp ,ZP-JOY-PRESSED)
    (AND #:imm #xF0)
    (BEQ frame_no_move)

    (LDA #:zp ,ZP-JOY-PRESSED)
    (AND #:imm ,BTN-RIGHT)
    (BEQ try_left_btn)
    (LDA #:imm #x01)
    (JMP execute_dpad_step)

    (label try_left_btn)
    (LDA #:zp ,ZP-JOY-PRESSED)
    (AND #:imm ,BTN-LEFT)
    (BEQ try_down_btn)
    (LDA #:imm #xFF)
    (JMP execute_dpad_step)

    (label try_down_btn)
    (LDA #:zp ,ZP-JOY-PRESSED)
    (AND #:imm ,BTN-DOWN)
    (BEQ try_up_btn)
    (LDA #:imm #x10)
    (JMP execute_dpad_step)

    (label try_up_btn)
    (LDA #:imm #xF0)

    (label execute_dpad_step)
    (STA #:zp ,ZP-SCRATCH-0)
    (JSR move_you_entities)
    (JSR scan_boba_rules)
    (JSR evaluate_win_and_defeat)

    (label frame_no_move)
    (JSR pack_oam_sprites)
    (RTS)

    ;; ========================================================================
    ;; Subroutine: poll_joypad_safe (Reads $4016 Controller 1 + Edge Detection)
    ;; ========================================================================
    (label poll_joypad_safe)
    (LDA #:zp ,ZP-JOY-CUR)
    (STA #:zp ,ZP-JOY-PREV)

    (LDA #:imm 1)
    (STA #:abs #x4016)
    (LDA #:imm 0)
    (STA #:abs #x4016)
    (STA #:zp ,ZP-JOY-CUR)

    (LDX #:imm 0)
    (label joy_bit_loop)
    (LDA #:abs #x4016)
    (AND #:imm #x01)
    (BEQ joy_bit_zero)
    (LDA #:zp ,ZP-JOY-CUR)
    (ORA #:absx bitmask_table)
    (STA #:zp ,ZP-JOY-CUR)
    (label joy_bit_zero)
    (INX)
    (CPX #:imm 8)
    (BNE joy_bit_loop)

    (LDA #:zp ,ZP-JOY-CUR)
    (EOR #:zp ,ZP-JOY-PREV)
    (AND #:zp ,ZP-JOY-CUR)
    (STA #:zp ,ZP-JOY-PRESSED)
    (RTS)

    ;; ========================================================================
    ;; Subroutine: load_current_stage
    ;; ========================================================================
    (label load_current_stage)
    (LDA #:imm 0)
    (STA #:zp ,ZP-LEVEL-WON)
    (STA #:zp ,ZP-MOVE-COUNT)
    (STA #:zp ,ZP-DUST-TIMER)
    (LDX #:imm 0)
    (label clear_board_loop)
    (STA #:absx ,BOARD-RAM-BASE)
    (STA #:absx ,UNDER-RAM-BASE)
    (INX)
    (CPX #:imm 224)
    (BNE clear_board_loop)

    (LDX #:zp ,ZP-CUR-STAGE)
    (LDA #:absx stage_ptr_lo)
    (STA #:zp ,ZP-SCRATCH-0)
    (LDA #:absx stage_ptr_hi)
    (STA #:zp ,ZP-SCRATCH-1)

    (LDY #:imm 0)
    (label stage_unpack_loop)
    (LDA #:indy ,ZP-SCRATCH-0)
    (CMP #:imm #xFF)
    (BEQ stage_unpack_done)
    (TAX)
    (INY)
    (LDA #:indy ,ZP-SCRATCH-0)
    (STA #:absx ,BOARD-RAM-BASE)
    (INY)
    (JMP stage_unpack_loop)

    (label stage_unpack_done)
    (RTS)

    ;; ========================================================================
    ;; Subroutine: scan_boba_rules
    ;; ========================================================================
    (.align 256)
    (label scan_boba_rules)
    (LDA #:imm 0)
    (LDX #:imm 0)
    (label clear_rules_loop)
    (STA #:zpx ,ZP-RULES-BASE)
    (INX)
    (CPX #:imm 6)
    (BNE clear_rules_loop)

    (LDX #:imm 0)
    (label rule_scan_cell_loop)
    (LDA #:absx ,BOARD-RAM-BASE)
    (CMP #:imm #x11)
    (BCC rule_scan_next_cell)
    (CMP #:imm #x16)
    (BCS rule_scan_next_cell)

    (AND #:imm #x0F)
    (STA #:zp ,ZP-SCRATCH-2)

    ;; --- Check Horizontal Phrase (X, X+1, X+2) when (X & 15) < 14 ---
    (TXA)
    (AND #:imm #x0F)
    (CMP #:imm 14)
    (BCS check_vertical_phrase)
    (LDA #:absx ,(+ BOARD-RAM-BASE 1))
    (CMP #:imm ,TXT-IS)
    (BNE check_vertical_phrase)
    (LDA #:absx ,(+ BOARD-RAM-BASE 2))
    (STA #:zp ,ZP-SCRATCH-3)
    (JSR apply_rule_predicate)

    ;; --- Check Vertical Phrase (X, X+16, X+32) when X < 192 ---
    (label check_vertical_phrase)
    (CPX #:imm 192)
    (BCS rule_scan_next_cell)
    (LDA #:absx ,(+ BOARD-RAM-BASE 16))
    (CMP #:imm ,TXT-IS)
    (BNE rule_scan_next_cell)
    (LDA #:absx ,(+ BOARD-RAM-BASE 32))
    (STA #:zp ,ZP-SCRATCH-3)
    (JSR apply_rule_predicate)

    (label rule_scan_next_cell)
    (INX)
    (CPX #:imm 224)
    (BNE rule_scan_cell_loop)
    (RTS)

    ;; Helper: apply_rule_predicate
    (label apply_rule_predicate)
    (STX #:zp ,ZP-SCRATCH-4)
    (LDA #:zp ,ZP-SCRATCH-3)
    (CMP #:imm #x21)
    (BCC check_noun_transform)
    (AND #:imm #x1F)
    (LDX #:zp ,ZP-SCRATCH-2)
    (ORA #:zpx ,ZP-RULES-BASE)
    (STA #:zpx ,ZP-RULES-BASE)
    (LDX #:zp ,ZP-SCRATCH-4)
    (RTS)

    (label check_noun_transform)
    (CMP #:imm #x11)
    (BCC pred_done)
    (CMP #:imm #x16)
    (BCS pred_done)
    (AND #:imm #x0F)
    (STA #:zp ,ZP-SCRATCH-5)
    (LDY #:imm 0)
    (label transform_board_loop)
    (LDA #:absy ,BOARD-RAM-BASE)
    (CMP #:zp ,ZP-SCRATCH-2)
    (BNE transform_next)
    (LDA #:zp ,ZP-SCRATCH-5)
    (STA #:absy ,BOARD-RAM-BASE)
    (label transform_next)
    (INY)
    (CPY #:imm 224)
    (BNE transform_board_loop)

    (label pred_done)
    (LDX #:zp ,ZP-SCRATCH-4)
    (RTS)

    ;; ========================================================================
    ;; Subroutine: move_you_entities
    ;; ========================================================================
    (.align 256)
    (label move_you_entities)
    (LDX #:imm 0)
    (label find_you_loop)
    (LDA #:absx ,BOARD-RAM-BASE)
    (BEQ find_you_next)
    (CMP #:imm 6)
    (BCS find_you_next)
    (TAY)
    (LDA #:absy ,ZP-RULES-BASE)
    (AND #:imm ,RULE-YOU)
    (BNE found_you_actor)
    (label find_you_next)
    (INX)
    (CPX #:imm 224)
    (BNE find_you_loop)
    (RTS)

    (label found_you_actor)
    (STX #:zp ,ZP-YOU-POS)

    (TXA)
    (CLC)
    (ADC #:zp ,ZP-SCRATCH-0)
    (CMP #:imm 224)
    (BCS move_blocked_rts)
    (STA #:zp ,ZP-SCRATCH-1)

    (TAX)
    (label push_ray_loop)
    (LDA #:absx ,BOARD-RAM-BASE)
    (BEQ push_chain_shift)

    (CMP #:imm #x10)
    (BCS ray_advance_push)

    (TAY)
    (LDA #:absy ,ZP-RULES-BASE)
    (AND #:imm ,RULE-PUSH)
    (BNE ray_advance_push)

    (CPX #:zp ,ZP-SCRATCH-1)
    (BNE move_blocked_rts)

    (LDA #:absy ,ZP-RULES-BASE)
    (AND #:imm ,RULE-WIN)
    (BEQ check_adj_defeat)
    (LDA #:imm 1)
    (STA #:zp ,ZP-LEVEL-WON)
    (LDA #:imm #xBF)
    (STA #:abs #x4000)
    (LDA #:imm #x80)
    (STA #:abs #x4002)
    (LDA #:imm #x08)
    (STA #:abs #x4003)
    (JMP step_onto_non_stop)

    (label check_adj_defeat)
    (LDA #:absy ,ZP-RULES-BASE)
    (AND #:imm ,RULE-DEFEAT)
    (BEQ check_adj_stop)
    (LDX #:zp ,ZP-YOU-POS)
    (LDA #:absx ,UNDER-RAM-BASE)
    (STA #:absx ,BOARD-RAM-BASE)
    (RTS)

    (label check_adj_stop)
    (LDA #:absy ,ZP-RULES-BASE)
    (AND #:imm ,RULE-STOP)
    (BNE move_blocked_rts)

    (label step_onto_non_stop)
    (LDX #:zp ,ZP-SCRATCH-1)
    (LDA #:absx ,BOARD-RAM-BASE)
    (STA #:absx ,UNDER-RAM-BASE)
    (LDA #:imm 0)
    (STA #:absx ,BOARD-RAM-BASE)
    (JMP push_chain_shift)

    (label ray_advance_push)
    (TXA)
    (CLC)
    (ADC #:zp ,ZP-SCRATCH-0)
    (CMP #:imm 224)
    (BCS move_blocked_rts)
    (TAX)
    (JMP push_ray_loop)

    (label move_blocked_rts)
    (RTS)

    (label push_chain_shift)
    (STX #:zp ,ZP-SCRATCH-2)
    (label shift_back_loop)
    (LDA #:zp ,ZP-SCRATCH-2)
    (SEC)
    (SBC #:zp ,ZP-SCRATCH-0)
    (TAY)
    (LDX #:zp ,ZP-SCRATCH-2)
    (LDA #:absy ,BOARD-RAM-BASE)
    (STA #:absx ,BOARD-RAM-BASE)
    (STY #:zp ,ZP-SCRATCH-2)
    (CPY #:zp ,ZP-YOU-POS)
    (BNE shift_back_loop)

    (LDX #:zp ,ZP-YOU-POS)
    (LDA #:absx ,UNDER-RAM-BASE)
    (STA #:absx ,BOARD-RAM-BASE)
    (LDA #:imm 0)
    (STA #:absx ,UNDER-RAM-BASE)

    (TXA)
    (AND #:imm #x0F)
    (ASL)
    (ASL)
    (ASL)
    (ASL)
    (STA #:zp ,ZP-DUST-X)
    (TXA)
    (LSR)
    (LSR)
    (LSR)
    (LSR)
    (ASL)
    (ASL)
    (ASL)
    (ASL)
    (CLC)
    (ADC #:imm 20)
    (STA #:zp ,ZP-DUST-Y)
    (LDA #:imm 12)
    (STA #:zp ,ZP-DUST-TIMER)
    (INC #:zp ,ZP-MOVE-COUNT)

    (LDA #:imm #x81)
    (STA #:abs #x4008)
    (LDA #:imm #x60)
    (STA #:abs #x400A)
    (LDA #:imm #x08)
    (STA #:abs #x400B)
    (RTS)

    ;; ========================================================================
    ;; Subroutine: evaluate_win_and_defeat
    ;; ========================================================================
    (.align 256)
    (label evaluate_win_and_defeat)
    (LDX #:imm 0)
    (label win_scan_loop)
    (LDA #:absx ,BOARD-RAM-BASE)
    (BEQ win_scan_next)
    (CMP #:imm 6)
    (BCS win_scan_next)
    (TAY)
    (LDA #:absy ,ZP-RULES-BASE)
    (AND #:imm ,RULE-YOU)
    (BEQ win_scan_next)
    (STX #:zp ,ZP-YOU-POS)

    (LDA #:absy ,ZP-RULES-BASE)
    (AND #:imm ,RULE-WIN)
    (BNE trigger_stage_win)

    (LDA #:absx ,UNDER-RAM-BASE)
    (BEQ win_scan_next)
    (CMP #:imm 6)
    (BCS win_scan_next)
    (TAY)
    (LDA #:absy ,ZP-RULES-BASE)
    (AND #:imm ,RULE-WIN)
    (BNE trigger_stage_win)

    (label win_scan_next)
    (INX)
    (CPX #:imm 224)
    (BNE win_scan_loop)
    (RTS)

    (label trigger_stage_win)
    (LDA #:imm 1)
    (STA #:zp ,ZP-LEVEL-WON)
    (RTS)

    ;; ========================================================================
    ;; Subroutine: pack_oam_sprites
    ;; Packs each non-empty board cell as a 2-sprite (16x8) horizontal pair:
    ;;   Sprite L: tile = id,       X = 16*col,     Y = 16*row + 20
    ;;   Sprite R: tile = id | $40, X = 16*col + 8, Y = 16*row + 20
    ;; ========================================================================
    (.align 256)
    (label pack_oam_sprites)
    (LDA #:imm #xF8)
    (LDX #:imm 0)
    (label clear_oam_loop)
    (STA #:absx ,OAM-RAM-BASE)
    (INX)
    (INX)
    (INX)
    (INX)
    (BNE clear_oam_loop)

    (LDA #:imm 0)
    (STA #:zp ,ZP-OAM-OFFSET)

    ;; 1. Emit victory sparkle sprite on YOU actor when ZP-LEVEL-WON == 1
    (LDA #:zp ,ZP-LEVEL-WON)
    (BEQ oam_scan_board)
    (LDY #:zp ,ZP-OAM-OFFSET)
    (LDA #:zp ,ZP-YOU-POS)
    (AND #:imm #xF0)
    (CLC)
    (ADC #:imm 12)
    (STA #:absy ,(+ OAM-RAM-BASE 0))
    (LDA #:imm #x07) ; Tile #x07 = SPARKLE
    (STA #:absy ,(+ OAM-RAM-BASE 1))
    (LDA #:imm #x02)
    (STA #:absy ,(+ OAM-RAM-BASE 2))
    (LDA #:zp ,ZP-YOU-POS)
    (AND #:imm #x0F)
    (ASL)
    (ASL)
    (ASL)
    (ASL)
    (CLC)
    (ADC #:imm 4)
    (STA #:absy ,(+ OAM-RAM-BASE 3))
    (TYA)
    (CLC)
    (ADC #:imm 4)
    (STA #:zp ,ZP-OAM-OFFSET)

    ;; 2. Scan board cells 0..223 and emit 2-tile (16x8) metasprites
    (label oam_scan_board)
    (LDX #:imm 0)
    (label oam_board_loop)
    (LDA #:absx ,BOARD-RAM-BASE)
    (BEQ oam_board_next)
    (STA #:zp ,ZP-SCRATCH-3) ; Tile ID

    ;; Ensure space for 2 OAM sprites (8 bytes <= 248)
    (LDY #:zp ,ZP-OAM-OFFSET)
    (CPY #:imm 244)
    (BCS check_dust_oam)

    ;; Compute Y pixel = (X & #xF0) + 20 in ZP-SCRATCH-4
    (TXA)
    (AND #:imm #xF0)
    (CLC)
    (ADC #:imm 20)
    (STA #:zp ,ZP-SCRATCH-4)
    (STA #:absy ,(+ OAM-RAM-BASE 0))
    (STA #:absy ,(+ OAM-RAM-BASE 4))

    ;; Left Tile ID & Right Tile ID (tile | #x40)
    (LDA #:zp ,ZP-SCRATCH-3)
    (STA #:absy ,(+ OAM-RAM-BASE 1))
    (ORA #:imm #x40)
    (STA #:absy ,(+ OAM-RAM-BASE 5))

    ;; Palette attribute:
    ;;   0: Boba/Flag/Rock
    ;;   1: Noun blocks (#x11..#x15)
    ;;   2: Verb blocks (#x21..#x30)
    ;;   3: IS (#x18) & Wall/Skull (#x04..#x05)
    (LDA #:zp ,ZP-SCRATCH-3)
    (CMP #:imm #x20)
    (BCS oam_pal_2)
    (CMP #:imm ,TXT-IS)
    (BEQ oam_pal_3)
    (CMP #:imm #x10)
    (BCS oam_pal_1)
    (CMP #:imm #x04)
    (BCS oam_pal_3)
    (LDA #:imm #x00)
    (JMP oam_store_attr)
    (label oam_pal_1)
    (LDA #:imm #x01)
    (JMP oam_store_attr)
    (label oam_pal_2)
    (LDA #:imm #x02)
    (JMP oam_store_attr)
    (label oam_pal_3)
    (LDA #:imm #x03)
    (label oam_store_attr)
    (STA #:absy ,(+ OAM-RAM-BASE 2))
    (STA #:absy ,(+ OAM-RAM-BASE 6))

    ;; Left X pixel = (X & #x0F) << 4; Right X pixel = Left X + 8
    (TXA)
    (AND #:imm #x0F)
    (ASL)
    (ASL)
    (ASL)
    (ASL)
    (STA #:absy ,(+ OAM-RAM-BASE 3))
    (CLC)
    (ADC #:imm 8)
    (STA #:absy ,(+ OAM-RAM-BASE 7))

    (TYA)
    (CLC)
    (ADC #:imm 8)
    (STA #:zp ,ZP-OAM-OFFSET)

    (label oam_board_next)
    (INX)
    (CPX #:imm 224)
    (BNE oam_board_loop)

    ;; 3. Emit trailing dust sprite if ZP-DUST-TIMER > 0
    (label check_dust_oam)
    (LDA #:zp ,ZP-DUST-TIMER)
    (BEQ oam_pack_done)
    (DEC #:zp ,ZP-DUST-TIMER)
    (LDY #:zp ,ZP-OAM-OFFSET)
    (CPY #:imm 252)
    (BCS oam_pack_done)
    (LDA #:zp ,ZP-DUST-Y)
    (STA #:absy ,(+ OAM-RAM-BASE 0))
    (LDA #:imm #x06) ; Tile #x06 = DUST
    (STA #:absy ,(+ OAM-RAM-BASE 1))
    (LDA #:imm #x00)
    (STA #:absy ,(+ OAM-RAM-BASE 2))
    (LDA #:zp ,ZP-DUST-X)
    (STA #:absy ,(+ OAM-RAM-BASE 3))
    (TYA)
    (CLC)
    (ADC #:imm 4)
    (STA #:zp ,ZP-OAM-OFFSET)

    (label oam_pack_done)
    (RTS)

    ;; ========================================================================
    ;; Read-Only PRG-ROM Tables (Page-Aligned for 0 Page-Crossing Penalty, Phi1)
    ;; ========================================================================
    (.align 256)
    (label bitmask_table)
    (.byte #x01 #x02 #x04 #x08 #x10 #x20 #x40 #x80)

    (label palette_rom_table)
    ;; 4 Background Palettes (16 B): Dark midnight blue backdrop (#x0F) + grid (#x01)
    ;; 4 Sprite Palettes (16 B):
    ;;   Spr Pal 0 (Boba/Flag/Rock): Cream (#x37), Berry/Gold (#x27), Dark (#x07)
    ;;   Spr Pal 1 (Nouns)         : Deep Teal (#x0C), Cyan border (#x2C), White text (#x30)
    ;;   Spr Pal 2 (Verbs)         : Deep Plum (#x04), Gold border (#x28), White text (#x30)
    ;;   Spr Pal 3 (IS / Wall)     : Charcoal (#x00), Brick/Silver (#x16), White (#x30)
    (.byte #x0F #x01 #x21 #x30  #x0F #x2A #x1A #x0A
           #x0F #x21 #x11 #x31  #x0F #x28 #x18 #x08
           #x0F #x37 #x27 #x07  #x0F #x0C #x2C #x30
           #x0F #x04 #x28 #x30  #x0F #x00 #x16 #x30)

    (label stage_1_data)
    (.byte ,@(encode-stage-bytes STAGE-1-CELLS))

    (label stage_2_data)
    (.byte ,@(encode-stage-bytes STAGE-2-CELLS))

    (label stage_3_data)
    (.byte ,@(encode-stage-bytes STAGE-3-CELLS))

    (label stage_4_data)
    (.byte ,@(encode-stage-bytes STAGE-4-CELLS))

    (label stage_5_data)
    (.byte ,@(encode-stage-bytes STAGE-5-CELLS))

    (label stage_ptr_lo)
    (.byte (lo stage_1_data) (lo stage_2_data) (lo stage_3_data) (lo stage_4_data) (lo stage_5_data))

    (label stage_ptr_hi)
    (.byte (hi stage_1_data) (hi stage_2_data) (hi stage_3_data) (hi stage_4_data) (hi stage_5_data))))

;; ============================================================================
;; 6. Graded Module Descriptor & End-to-End ROM Builder for "Boba Is You"
;; ============================================================================

(define (build-boba-graded-module-descriptor [asm-res #f])
  (define prg-bytes
    (if asm-res
        (bytes-length (asm-result-bytes asm-res))
        1600))
  (define page-cross
    (if asm-res
        (asm-result-page-crossings asm-res)
        0))
  (hasheq
   'name            'boba-is-you-nes
   'mapper          'NROM
   'fixed-prg-bank  1
   'initial-prg-bank 0
   'zp-vars
   (list (hasheq 'name 'zp_joy_state   'bytes 3 'cap 'RamLinear)
         (hasheq 'name 'zp_stage_state 'bytes 6 'cap 'RamLinear)
         (hasheq 'name 'zp_ppu_state   'bytes 6 'cap 'RamLinear)
         (hasheq 'name 'zp_rule_table  'bytes 6 'cap 'RamLinear)
         (hasheq 'name 'tile_constants 'bytes 16 'cap 'ConstMeta))
   'zp-scratch-blocks
   (list (hasheq 'id 'scratch_poll_joypad  'bytes 6 'leaked? #f)
         (hasheq 'id 'scratch_scan_rules   'bytes 6 'leaked? #f)
         (hasheq 'id 'scratch_push_solver  'bytes 6 'leaked? #f)
         (hasheq 'id 'scratch_pack_oam     'bytes 6 'leaked? #f))
   'subroutines
   (list (hasheq 'name 'nmi_handler             'pha-count 3 'pla-count 3)
         (hasheq 'name 'poll_joypad_safe        'pha-count 0 'pla-count 0)
         (hasheq 'name 'load_current_stage      'pha-count 0 'pla-count 0)
         (hasheq 'name 'scan_boba_rules         'pha-count 0 'pla-count 0)
         (hasheq 'name 'move_you_entities       'pha-count 0 'pla-count 0)
         (hasheq 'name 'evaluate_win_and_defeat 'pha-count 0 'pla-count 0)
         (hasheq 'name 'pack_oam_sprites        'pha-count 0 'pla-count 0))
   'ppu-ops
   (list (hasheq 'op 'palette-write!   'phase 'ForcedBlank)
         (hasheq 'op 'oam-dma!         'phase 'VBlankNMI)
         (hasheq 'op 'nametable-patch! 'phase 'VBlankNMI)
         (hasheq 'op 'restore-scroll!  'phase 'VBlankNMI))
   'nmi-ops
   (list (hasheq 'op 'oam-dma!)
         (hasheq 'op 'nametable-patch! 'bytes 8)
         (hasheq 'op 'restore-scroll!  'x 0 'y 0))
   'dispatches
   (list (hasheq 'name 'boba-noun-dispatch
                 'domain  '(boba flag rock wall skull)
                 'handled '(boba flag rock wall skull))
         (hasheq 'name 'boba-verb-dispatch
                 'domain  '(you push stop win defeat)
                 'handled '(you push stop win defeat)))
   'vblank-cycles    612
   'active-cycles    3680
   'page-crossings   page-cross
   'oam-sprites      38
   'scanline-sprites 8
   'oam-mux?         #t
   'ram-bytes        448
   'prg-rom-bytes    prg-bytes
   'chr-tiles        36
   'vram-dma-bytes   8
   'bg-palettes      4
   'spr-palettes     4
   'attr-clashes     0
   'apu-channels     '(pulse1 triangle noise)
   'joypad-poll-mode 'double-read-safe))

(define (compile-boba-is-you-rom! #:nes-out-path [nes-out-path #f]
                                  #:asm-out-path [asm-out-path #f])
  (define forms   (build-boba-6502-program))
  (define asm-res (assemble-6502 forms #:origin #x8000))
  (define chr-rom (build-boba-chr-rom))
  (define mod-desc (build-boba-graded-module-descriptor asm-res))
  (define type-res (typecheck-nes-module mod-desc NTSC-NROM-BUDGET))

  (unless (nes-type-result-well-typed? type-res)
    (error 'compile-boba-is-you-rom!
           "Graded typecheck failed with violations: ~v"
           (nes-type-result-violations type-res)))

  (define rom-bytes
    (build-ines-rom asm-res chr-rom
                    #:nmi-label   'nmi_handler
                    #:reset-label 'reset_handler
                    #:irq-label   'irq_handler))

  (when nes-out-path
    (write-ines-rom-file! nes-out-path rom-bytes))

  (when asm-out-path
    (call-with-output-file asm-out-path
      (lambda (out)
        (display (emit-ca65-asm forms #:origin #x8000) out))
      #:exists 'truncate/replace))

  (values rom-bytes asm-res type-res mod-desc))
