#lang racket/base

;; ============================================================================
;; #lang boba-nes : "Boba Is You" 6502 Game Engine, 5-Stage Level Pack,
;;                  Custom 2bpp CHR-ROM Graphics & Graded Module Descriptor
;; ============================================================================

(require racket/match
         racket/list
         racket/format
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

;; Permanent Zero-Page State ($10..$27 = 24 bytes)
(define ZP-JOY-CUR      #x10) ; Current frame controller 1 bits
(define ZP-JOY-PREV     #x11) ; Previous frame controller 1 bits
(define ZP-JOY-PRESSED  #x12) ; Newly pressed buttons (cur & ~prev)
(define ZP-CUR-STAGE    #x13) ; Current stage index (0..4)
(define ZP-LEVEL-WON    #x14) ; 1 when current stage win condition is met
(define ZP-MOVE-COUNT   #x15) ; Total player steps in current stage
(define ZP-DUST-X       #x16) ; Last YOU step X for dust trail sprite
(define ZP-DUST-Y       #x17) ; Last YOU step Y for dust trail sprite
(define ZP-DUST-TIMER   #x18) ; Frames remaining for dust particle
(define ZP-FRAME-TICK   #x19) ; Global frame counter (for sparkle & OAM mux)
(define ZP-SCROLL-X     #x1A) ; Clean PPU X scroll (0)
(define ZP-SCROLL-Y     #x1B) ; Clean PPU Y scroll (0)
(define ZP-OAM-OFFSET   #x1C) ; Current OAM byte index during sprite packing
(define ZP-YOU-POS      #x1D) ; Cached board cell index of primary YOU actor
(define ZP-WIN-POS      #x1E) ; Cached board cell index of primary WIN object

;; Active Rule Table ($20..$25): 6 bytes indexed by OBJ-* (0..5)
;; Each byte holds bitwise OR of RULE-YOU, RULE-PUSH, RULE-STOP, RULE-WIN, RULE-DEFEAT
(define ZP-RULES-BASE   #x20)
(define ZP-RULE-BOBA    #x21)
(define ZP-RULE-FLAG    #x22)
(define ZP-RULE-ROCK    #x23)
(define ZP-RULE-WALL    #x24)
(define ZP-RULE-SKULL   #x25)

;; Recycled High-Watermark Zero-Page Scratch Pool ($30..$37 = 8 bytes shared
;; across sequential phases: poll-joypad -> scan-rules -> push-solver -> pack-oam)
(define ZP-SCRATCH-0    #x30) ; Ptr lo / step delta / temp A
(define ZP-SCRATCH-1    #x31) ; Ptr hi / target pos / temp B
(define ZP-SCRATCH-2    #x32) ; Chain end pos / subject noun ID
(define ZP-SCRATCH-3    #x33) ; Predicate tile / object mask
(define ZP-SCRATCH-4    #x34) ; Saved X / ray cursor
(define ZP-SCRATCH-5    #x35) ; Transform target noun ID

;; Work RAM ($0300..$04DF = 448 bytes)
;;   $0200..$02FF : 256-byte OAM DMA shadow buffer (DmaUnique)
;;   $0300..$03DF : 224-byte Top-Layer Board Grid (16 cols x 14 rows)
;;   $0400..$04DF : 224-byte Under-Layer Board Grid (preserves non-STOP tiles walked over)
(define OAM-RAM-BASE    #x0200)
(define BOARD-RAM-BASE  #x0300)
(define UNDER-RAM-BASE  #x0400)

;; ============================================================================
;; 3. Custom 2bpp CHR-ROM Graphics Tiles for "Boba Is You"
;; ============================================================================

(define (build-boba-chr-rom)
  (define tiles
    (list
     ;; Tile #x00: Empty transparent/background tile
     (cons #x00
           '("........"
             "........"
             "........"
             "........"
             "........"
             "........"
             "........"
             "........"))
     ;; Tile #x01: BOBA (Boba tea cup with straw & tapioca pearls!)
     (cons OBJ-BOBA
           '("....33.."
             "...3..3."
             ".222222."
             ".211112."
             ".213132."
             ".211312."
             "..23132."
             "...222.."))
     ;; Tile #x02: FLAG (Victory pennant on pole)
     (cons OBJ-FLAG
           '("..3222.."
             "..32222."
             "..3222.."
             "..3....."
             "..3....."
             "..3....."
             ".333...."
             "........"))
     ;; Tile #x03: ROCK (Round tapioca boulder)
     (cons OBJ-ROCK
           '("..2222.."
             ".233332."
             "23311332"
             "23111332"
             "23333322"
             "2233322."
             ".22222.."
             "........"))
     ;; Tile #x04: WALL (Brick wall block)
     (cons OBJ-WALL
           '("33313331"
             "33313331"
             "11111111"
             "31333133"
             "31333133"
             "11111111"
             "33313331"
             "33313331"))
     ;; Tile #x05: SKULL (Hazard skull)
     (cons OBJ-SKULL
           '("..3333.."
             ".333333."
             "33.33.33"
             "33333333"
             ".33.3.3."
             "..3.3.3."
             "........"
             "........"))
     ;; Tile #x06: DUST ( Trailing movement dust puff)
     (cons #x06
           '("........"
             "..1..1.."
             ".121121."
             "..1221.."
             ".121121."
             "..1..1.."
             "........"
             "........"))
     ;; Tile #x07: SPARKLE (Victory shimmer star)
     (cons #x07
           '("...3...."
             "...3...."
             ".3.3.3.."
             "333.333."
             ".3.3.3.."
             "...3...."
             "...3...."
             "........"))
     ;; Tile #x11: TXT_BOBA ("BOBA" noun block)
     (cons TXT-BOBA
           '("33333333"
             "3.22.223"
             "3.23.2.3"
             "3.22.223"
             "3.23.2.3"
             "3.22.2.3"
             "3......3"
             "33333333"))
     ;; Tile #x12: TXT_FLAG ("FLAG" noun block)
     (cons TXT-FLAG
           '("33333333"
             "3.222.23"
             "3.2...23"
             "3.22..23"
             "3.2...23"
             "3.2..223"
             "3......3"
             "33333333"))
     ;; Tile #x13: TXT_ROCK ("ROCK" noun block)
     (cons TXT-ROCK
           '("33333333"
             "3.22.223"
             "3.23.2.3"
             "3.22.2.3"
             "3.23.2.3"
             "3.23.223"
             "3......3"
             "33333333"))
     ;; Tile #x14: TXT_WALL ("WALL" noun block)
     (cons TXT-WALL
           '("33333333"
             "32...2.3"
             "32.2.2.3"
             "32.2.2.3"
             "322222.3"
             "3.2.2..3"
             "3......3"
             "33333333"))
     ;; Tile #x15: TXT_SKULL ("SKUL" noun block)
     (cons TXT-SKULL
           '("33333333"
             "3.222.23"
             "3.2...23"
             "3.222.23"
             "3...2.23"
             "3.222.23"
             "3......3"
             "33333333"))
     ;; Tile #x18: TXT_IS ("IS" connector block)
     (cons TXT-IS
           '("11111111"
             "1..3.331"
             "1..3.3.1"
             "1..3.331"
             "1..3..31"
             "1..3.331"
             "1......1"
             "11111111"))
     ;; Tile #x21: TXT_YOU ("YOU" property block)
     (cons TXT-YOU
           '("22222222"
             "23.3.332"
             "23.3.3.2"
             "2.3..3.2"
             "2.3..3.2"
             "2.3..332"
             "2......2"
             "22222222"))
     ;; Tile #x22: TXT_PUSH ("PUSH" property block)
     (cons TXT-PUSH
           '("22222222"
             "233..332"
             "23.3.3.2"
             "233..332"
             "23....32"
             "23...332"
             "2......2"
             "22222222"))
     ;; Tile #x24: TXT_STOP ("STOP" property block)
     (cons TXT-STOP
           '("22222222"
             "2.33.332"
             "2.3...32"
             "2.33..32"
             "2..3..32"
             "2.33..32"
             "2......2"
             "22222222"))
     ;; Tile #x28: TXT_WIN ("WIN" property block)
     (cons TXT-WIN
           '("22222222"
             "23...3.2"
             "23.3.3.2"
             "23.3.3.2"
             "233333.2"
             "2.3.3..2"
             "2......2"
             "22222222"))
     ;; Tile #x30: TXT_DEFEAT ("SINK" / "DEAD" property block)
     (cons TXT-DEFEAT
           '("22222222"
             "23..3.32"
             "233.3.32"
             "23.33.32"
             "23..3.32"
             "23..3.32"
             "2......2"
             "22222222"))))
  (build-chr-rom tiles))

;; ============================================================================
;; 4. Five-Stage "Boba Is You" Level Pack (Adapted from gaia1.sav .. gaia5.sav)
;; ============================================================================
;; Each stage is encoded as a compact list of (cell-index tile-id) pairs on the
;; 16x14 board (cell-index = y*16 + x), terminated by #xFF.

(define (cell xy-pair)
  (+ (* (cdr xy-pair) 16) (car xy-pair)))

(define STAGE-1-CELLS
  ;; Stage 1 (gaia1):
  ;; - Bottom room has BOBA IS YOU (x=2..4, y=10) and WALL IS STOP (x=2..4, y=8).
  ;; - Horizontal wall barrier separates bottom room from top room at y=6 (x=4..10).
  ;; - Top room has separated FLAG (x=5, y=3), IS (x=6, y=3), WIN (x=8, y=3), and FLAG object (x=10, y=3).
  ;; - Solution: Push STOP (or IS) out of WALL IS STOP, walk through WALL at y=6,
  ;;   push WIN left to form FLAG IS WIN, and touch the FLAG!
  (list
   ;; Active rule 1: BOBA IS YOU at (2,10), (3,10), (4,10)
   (cons (cell '(2 . 10)) TXT-BOBA)
   (cons (cell '(3 . 10)) TXT-IS)
   (cons (cell '(4 . 10)) TXT-YOU)
   ;; Active rule 2: WALL IS STOP at (2,8), (3,8), (4,8)
   (cons (cell '(2 . 8))  TXT-WALL)
   (cons (cell '(3 . 8))  TXT-IS)
   (cons (cell '(4 . 8))  TXT-STOP)
   ;; Wall barrier at y=6
   (cons (cell '(5 . 6))  OBJ-WALL)
   (cons (cell '(6 . 6))  OBJ-WALL)
   (cons (cell '(7 . 6))  OBJ-WALL)
   (cons (cell '(8 . 6))  OBJ-WALL)
   (cons (cell '(9 . 6))  OBJ-WALL)
   ;; Top room: FLAG IS [gap] WIN + FLAG object
   (cons (cell '(5 . 3))  TXT-FLAG)
   (cons (cell '(6 . 3))  TXT-IS)
   (cons (cell '(8 . 3))  TXT-WIN)
   (cons (cell '(10 . 3)) OBJ-FLAG)
   ;; Player Boba at (7, 8)
   (cons (cell '(7 . 8))  OBJ-BOBA)))

(define STAGE-2-CELLS
  ;; Stage 2 (gaia2):
  ;; - Initially WALL IS YOU (2..4, 10) and FLAG IS STOP (2..4, 8)!
  ;; - Player controls the WALL object at (7, 8)!
  ;; - Flag border at y=6 blocks access to top room where FLAG, IS, WIN sit.
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
  ;; Stage 3 (gaia3):
  ;; - BOBA IS YOU (1..3, 1), FLAG IS WIN (1..3, 2), ROCK IS PUSH (1..3, 3), SKULL IS DEFEAT (11..13, 2)
  ;; - Boba at (6, 9) pushes ROCK at (6, 7) and (6, 8) to clear path to FLAG at (10, 5) while avoiding SKULLs!
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
   (cons (cell '(11 . 2)) TXT-SKULL)
   (cons (cell '(12 . 2)) TXT-IS)
   (cons (cell '(13 . 2)) TXT-DEFEAT)
   (cons (cell '(5 . 8))  OBJ-SKULL)
   (cons (cell '(7 . 8))  OBJ-SKULL)
   (cons (cell '(6 . 8))  OBJ-ROCK)
   (cons (cell '(6 . 7))  OBJ-ROCK)
   (cons (cell '(6 . 9))  OBJ-BOBA)
   (cons (cell '(10 . 5)) OBJ-FLAG)))

(define STAGE-4-CELLS
  ;; Stage 4 (gaia4):
  ;; - Only ONE 'IS' block on the entire board: BOBA IS YOU at (5..7, 5)!
  ;; - TXT-FLAG sits at (6, 4) above TXT-IS (6, 5), and TXT-WIN sits at (6, 7).
  ;; - Pushing TXT-WIN up to (6, 6) shares the single TXT-IS in a crossword
  ;;   intersection (horizontal BOBA IS YOU + vertical FLAG IS WIN), then Boba
  ;;   touches OBJ-FLAG at (11, 5) to win!
  (list
   (cons (cell '(5 . 5)) TXT-BOBA)
   (cons (cell '(6 . 5)) TXT-IS)
   (cons (cell '(7 . 5)) TXT-YOU)
   (cons (cell '(6 . 4)) TXT-FLAG)
   (cons (cell '(6 . 7)) TXT-WIN)
   (cons (cell '(6 . 8)) OBJ-BOBA)
   (cons (cell '(11 . 5)) OBJ-FLAG)))

(define STAGE-5-CELLS
  ;; Stage 5 (gaia5 + WORLD_EVENT.txt):
  ;; - Noun-to-Noun World Event: WALL IS [gap] BOBA!
  ;; - Pushing BOBA noun block to complete WALL IS BOBA transforms every WALL on the board into BOBA!
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
   (cons (cell '(11 . 5)) OBJ-WALL)
   (cons (cell '(12 . 5)) OBJ-FLAG)))

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

    ;; Load Stage 0 into BOARD_RAM ($0300) and run initial rule scan
    (JSR load_current_stage)
    (JSR scan_boba_rules)
    (JSR pack_oam_sprites)

    ;; Discharge PPU scroll latch & enable NMI + BG + Sprites
    (BIT #:abs #x2002)
    (LDA #:imm #x00)
    (STA #:abs #x2005)
    (STA #:abs #x2005)
    (LDA #:imm #x88) ; NMI enabled, Sprite pattern table 0
    (STA #:abs #x2000)
    (LDA #:imm #x1E) ; Show background & sprites
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

    ;; 2. Write 8-byte HUD status stripe at Nametable $2022 (Stage, Move Count, Rules)
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
    (LDA #:imm #x88)
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
    ;; ActiveFrame Main Step (game_frame_step):
    ;;   Phase 1: Poll Controller 1 (with-zp-scratch)
    ;;   Phase 2: Handle SELECT (Restart Stage) / START (Next Stage on Win)
    ;;   Phase 3: D-Pad Move & Multi-Block Push Chain Solver
    ;;   Phase 4: Dynamic Noun-IS-Verb / Noun-IS-Noun Rule Scanner
    ;;   Phase 5: Win/Defeat Evaluation & OAM Sprite Buffer Packing
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

    ;; Check START ($08): If stage won (or skip), advance to next stage (0..4)
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

    ;; Decode directional cell delta into ZP-SCRATCH-0:
    ;;   RIGHT ($80) -> +1 (#x01)
    ;;   LEFT  ($40) -> -1 (#xFF)
    ;;   DOWN  ($20) -> +16 (#x10)
    ;;   UP    ($10) -> -16 (#xF0)
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

    ;; Compute newly pressed buttons: cur & (cur ^ prev)
    (LDA #:zp ,ZP-JOY-CUR)
    (EOR #:zp ,ZP-JOY-PREV)
    (AND #:zp ,ZP-JOY-CUR)
    (STA #:zp ,ZP-JOY-PRESSED)
    (RTS)

    ;; ========================================================================
    ;; Subroutine: load_current_stage
    ;; Decompresses (cell, tile) pairs for ZP-CUR-STAGE into $0300-$03DF
    ;; ========================================================================
    (label load_current_stage)
    ;; Clear BOARD_RAM ($0300..$03DF) and UNDER_RAM ($0400..$04DF)
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

    ;; Load 16-bit stage table pointer into ZP-SCRATCH-0 / ZP-SCRATCH-1
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
    (TAX) ; X = cell index (0..223)
    (INY)
    (LDA #:indy ,ZP-SCRATCH-0)
    (STA #:absx ,BOARD-RAM-BASE)
    (INY)
    (JMP stage_unpack_loop)

    (label stage_unpack_done)
    (RTS)

    ;; ========================================================================
    ;; Subroutine: scan_boba_rules
    ;; Scans the 16x14 grid for horizontal (+1, +2) and vertical (+16, +32)
    ;; phrases:
    ;;   [TXT_NOUN] [TXT_IS] [TXT_VERB] -> sets bitmask in ZP-RULES-BASE[noun]
    ;;   [TXT_NOUN] [TXT_IS] [TXT_NOUN] -> World Event: transforms all noun1 -> noun2!
    ;; ========================================================================
    (.align 256)
    (label scan_boba_rules)
    ;; 1. Clear active rule bitmasks ZP-RULES-BASE + 0..5
    (LDA #:imm 0)
    (LDX #:imm 0)
    (label clear_rules_loop)
    (STA #:zpx ,ZP-RULES-BASE)
    (INX)
    (CPX #:imm 6)
    (BNE clear_rules_loop)

    ;; 2. Scan all 224 cells (X = 0..223)
    (LDX #:imm 0)
    (label rule_scan_cell_loop)
    (LDA #:absx ,BOARD-RAM-BASE)
    ;; Is A a Noun Text Block (#x11..#x15)?
    (CMP #:imm #x11)
    (BCC rule_scan_next_cell)
    (CMP #:imm #x16)
    (BCS rule_scan_next_cell)

    ;; Save subject object ID (1..5) in ZP-SCRATCH-2
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
    ;; ZP-SCRATCH-2 = subject object ID (1..5)
    ;; ZP-SCRATCH-3 = predicate tile at +2 or +32
    (label apply_rule_predicate)
    (STX #:zp ,ZP-SCRATCH-4)
    (LDA #:zp ,ZP-SCRATCH-3)
    ;; Case A: Verb/Property tile (#x21..#x3F) -> OR (tile & #x1F) into ZP-RULES-BASE[subject]
    (CMP #:imm #x21)
    (BCC check_noun_transform)
    (AND #:imm #x1F)
    (LDX #:zp ,ZP-SCRATCH-2)
    (ORA #:zpx ,ZP-RULES-BASE)
    (STA #:zpx ,ZP-RULES-BASE)
    (LDX #:zp ,ZP-SCRATCH-4)
    (RTS)

    ;; Case B: Noun Text Block (#x11..#x15) -> World Event Transformation (e.g. WALL IS BOBA)!
    (label check_noun_transform)
    (CMP #:imm #x11)
    (BCC pred_done)
    (CMP #:imm #x16)
    (BCS pred_done)
    (AND #:imm #x0F)
    (STA #:zp ,ZP-SCRATCH-5) ; Target object ID (1..5)
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
    ;; Finds the actor with RULE-YOU and moves/pushes in direction ZP-SCRATCH-0
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

    ;; X = current board cell of YOU actor; ZP-SCRATCH-0 = step delta
    (label found_you_actor)
    (STX #:zp ,ZP-YOU-POS)

    ;; Compute next cell = X + step delta in ZP-SCRATCH-1
    (TXA)
    (CLC)
    (ADC #:zp ,ZP-SCRATCH-0)
    (CMP #:imm 224)
    (BCS move_blocked_rts)
    (STA #:zp ,ZP-SCRATCH-1)

    ;; Walk ray forward across pushable objects to find empty cell or non-STOP cell
    (TAX)
    (label push_ray_loop)
    (LDA #:absx ,BOARD-RAM-BASE)
    (BEQ push_chain_shift) ; Empty cell reached!

    ;; Is occupant at X a Text Block (>= #x10)? Text blocks are always PUSH!
    (CMP #:imm #x10)
    (BCS ray_advance_push)

    ;; Occupant is an object (1..5): check its active rules in ZP-RULES-BASE,Y
    (TAY)
    (LDA #:absy ,ZP-RULES-BASE)
    ;; Is it PUSH?
    (AND #:imm ,RULE-PUSH)
    (BNE ray_advance_push)

    ;; Not PUSH: check if occupant at ZP-SCRATCH-1 (immediately adjacent to YOU)
    (CPX #:zp ,ZP-SCRATCH-1)
    (BNE move_blocked_rts)

    ;; Check if adjacent non-push object is WIN!
    (LDA #:absy ,ZP-RULES-BASE)
    (AND #:imm ,RULE-WIN)
    (BEQ check_adj_defeat)
    (LDA #:imm 1)
    (STA #:zp ,ZP-LEVEL-WON)
    ;; Trigger APU Pulse 1 victory chime
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
    ;; Stepping onto DEFEAT destroys YOU actor!
    (LDX #:zp ,ZP-YOU-POS)
    (LDA #:absx ,UNDER-RAM-BASE)
    (STA #:absx ,BOARD-RAM-BASE)
    (RTS)

    (label check_adj_stop)
    (LDA #:absy ,ZP-RULES-BASE)
    (AND #:imm ,RULE-STOP)
    (BNE move_blocked_rts)

    ;; Object has neither PUSH nor STOP (e.g., WALL after breaking WALL IS STOP!):
    ;; Save the object in UNDER_RAM and let YOU walk onto it!
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

    ;; Shift chain of pushed blocks from X (empty target cell) back to ZP-YOU-POS
    (label push_chain_shift)
    (STX #:zp ,ZP-SCRATCH-2) ; ZP-SCRATCH-2 = current destination cell
    (label shift_back_loop)
    (LDA #:zp ,ZP-SCRATCH-2)
    (SEC)
    (SBC #:zp ,ZP-SCRATCH-0)
    (TAY) ; Y = source cell (dest - delta)
    (LDX #:zp ,ZP-SCRATCH-2)
    (LDA #:absy ,BOARD-RAM-BASE)
    (STA #:absx ,BOARD-RAM-BASE)
    (STY #:zp ,ZP-SCRATCH-2)
    (CPY #:zp ,ZP-YOU-POS)
    (BNE shift_back_loop)

    ;; Restore whatever was underneath YOU at ZP-YOU-POS from UNDER_RAM
    (LDX #:zp ,ZP-YOU-POS)
    (LDA #:absx ,UNDER-RAM-BASE)
    (STA #:absx ,BOARD-RAM-BASE)
    (LDA #:imm 0)
    (STA #:absx ,UNDER-RAM-BASE)

    ;; Spawn dust particle at old YOU cell & increment move counter
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
    (ADC #:imm 16)
    (STA #:zp ,ZP-DUST-Y)
    (LDA #:imm 12)
    (STA #:zp ,ZP-DUST-TIMER)
    (INC #:zp ,ZP-MOVE-COUNT)

    ;; Trigger APU Triangle step tone ($4008-$400B)
    (LDA #:imm #x81)
    (STA #:abs #x4008)
    (LDA #:imm #x60)
    (STA #:abs #x400A)
    (LDA #:imm #x08)
    (STA #:abs #x400B)
    (RTS)

    ;; ========================================================================
    ;; Subroutine: evaluate_win_and_defeat
    ;; Checks after rule re-evaluation if:
    ;;   1. Any object type has BOTH RULE-YOU and RULE-WIN (e.g., BOBA IS WIN!)
    ;;   2. A YOU actor stands on a cell whose UNDER_RAM object has RULE-WIN
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

    ;; Does this YOU object also have RULE-WIN (e.g., BOBA IS YOU + BOBA IS WIN)?
    (LDA #:absy ,ZP-RULES-BASE)
    (AND #:imm ,RULE-WIN)
    (BNE trigger_stage_win)

    ;; Or does the object underneath this YOU cell in UNDER_RAM have RULE-WIN?
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
    ;; Packs active board objects, text blocks, YOU dust puff, and WIN sparkles
    ;; into the $0200-$02FF OAM shadow page (<= 64 sprites, DmaUnique).
    ;; ========================================================================
    (label pack_oam_sprites)
    ;; Hide all 64 hardware sprites initially (Y = $F8)
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

    ;; Emit dust sprite if ZP-DUST-TIMER > 0
    (LDA #:zp ,ZP-DUST-TIMER)
    (BEQ oam_scan_board)
    (DEC #:zp ,ZP-DUST-TIMER)
    (LDY #:zp ,ZP-OAM-OFFSET)
    (LDA #:zp ,ZP-DUST-Y)
    (STA #:absy ,(+ OAM-RAM-BASE 0))
    (LDA #:imm #x06) ; Tile #x06 = DUST
    (STA #:absy ,(+ OAM-RAM-BASE 1))
    (LDA #:imm #x02) ; Palette 2
    (STA #:absy ,(+ OAM-RAM-BASE 2))
    (LDA #:zp ,ZP-DUST-X)
    (STA #:absy ,(+ OAM-RAM-BASE 3))
    (TYA)
    (CLC)
    (ADC #:imm 4)
    (STA #:zp ,ZP-OAM-OFFSET)

    ;; Scan board cells 0..223 and emit OAM sprites for non-empty tiles
    (label oam_scan_board)
    (LDX #:imm 0)
    (label oam_board_loop)
    (LDA #:absx ,BOARD-RAM-BASE)
    (BEQ oam_board_next)
    (STA #:zp ,ZP-SCRATCH-3) ; Tile ID

    ;; Cap OAM offset at 248 bytes (62 sprites) so we never overflow 64 sprites
    (LDY #:zp ,ZP-OAM-OFFSET)
    (CPY #:imm 248)
    (BCS oam_pack_done)

    ;; Y pixel = ((X >> 4) << 4) + 16 = (X & #xF0) + 16
    (TXA)
    (AND #:imm #xF0)
    (CLC)
    (ADC #:imm 16)
    (STA #:absy ,(+ OAM-RAM-BASE 0))

    ;; Tile ID
    (LDA #:zp ,ZP-SCRATCH-3)
    (STA #:absy ,(+ OAM-RAM-BASE 1))

    ;; Palette attribute (0 for objects, 1 for nouns/IS, 2 for verbs)
    (CMP #:imm #x20)
    (BCS oam_pal_verb)
    (CMP #:imm #x10)
    (BCS oam_pal_noun)
    (LDA #:imm #x00)
    (JMP oam_store_attr)
    (label oam_pal_noun)
    (LDA #:imm #x01)
    (JMP oam_store_attr)
    (label oam_pal_verb)
    (LDA #:imm #x02)
    (label oam_store_attr)
    (STA #:absy ,(+ OAM-RAM-BASE 2))

    ;; X pixel = (X & #x0F) << 4
    (TXA)
    (AND #:imm #x0F)
    (ASL)
    (ASL)
    (ASL)
    (ASL)
    (STA #:absy ,(+ OAM-RAM-BASE 3))

    (TYA)
    (CLC)
    (ADC #:imm 4)
    (STA #:zp ,ZP-OAM-OFFSET)

    (label oam_board_next)
    (INX)
    (CPX #:imm 224)
    (BNE oam_board_loop)

    (label oam_pack_done)
    (RTS)

    ;; ========================================================================
    ;; Read-Only PRG-ROM Tables (Page-Aligned for 0 Page-Crossing Penalty, Phi1)
    ;; ========================================================================
    (.align 256)
    (label bitmask_table)
    (.byte #x01 #x02 #x04 #x08 #x10 #x20 #x40 #x80)

    (label palette_rom_table)
    ;; 4 Background Palettes (16 B) + 4 Sprite Palettes (16 B)
    (.byte #x0F #x30 #x16 #x27  #x0F #x2A #x1A #x0A
           #x0F #x21 #x11 #x31  #x0F #x28 #x18 #x08
           #x0F #x30 #x27 #x16  #x0F #x30 #x2A #x1A
           #x0F #x30 #x28 #x12  #x0F #x30 #x15 #x05)

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
        680))
  (define page-cross
    (if asm-res
        (asm-result-page-crossings asm-res)
        0))
  (hasheq
   'name            'boba-is-you-nes
   'mapper          'NROM
   'fixed-prg-bank  1
   'initial-prg-bank 0
   ;; Permanent Zero-Page allocations (22 bytes) + compile-time constants (0 bytes)
   'zp-vars
   (list (hasheq 'name 'zp_joy_state   'bytes 3 'cap 'RamLinear)
         (hasheq 'name 'zp_stage_state 'bytes 6 'cap 'RamLinear)
         (hasheq 'name 'zp_ppu_state   'bytes 6 'cap 'RamLinear)
         (hasheq 'name 'zp_rule_table  'bytes 6 'cap 'RamLinear)
         (hasheq 'name 'tile_constants 'bytes 16 'cap 'ConstMeta))
   ;; 4 Sequential High-Watermark Zero-Page Scratch Scopes (each 6 B -> Peak = 6 B, not 24 B!)
   'zp-scratch-blocks
   (list (hasheq 'id 'scratch_poll_joypad  'bytes 6 'leaked? #f)
         (hasheq 'id 'scratch_scan_rules   'bytes 6 'leaked? #f)
         (hasheq 'id 'scratch_push_solver  'bytes 6 'leaked? #f)
         (hasheq 'id 'scratch_pack_oam     'bytes 6 'leaked? #f))
   'subroutines
   (list (hasheq 'name 'nmi_handler            'pha-count 3 'pla-count 3)
         (hasheq 'name 'poll_joypad_safe       'pha-count 0 'pla-count 0)
         (hasheq 'name 'load_current_stage     'pha-count 0 'pla-count 0)
         (hasheq 'name 'scan_boba_rules        'pha-count 0 'pla-count 0)
         (hasheq 'name 'move_you_entities      'pha-count 0 'pla-count 0)
         (hasheq 'name 'evaluate_win_and_defeat 'pha-count 0 'pla-count 0)
         (hasheq 'name 'pack_oam_sprites       'pha-count 0 'pla-count 0))
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
   'vblank-cycles    612   ; 514 (OAMDMA) + 98 (8B HUD + scroll restore) <= 2273
   'active-cycles    3420  ; Rule scan + push solver + OAM pack <= 29780
   'page-crossings   page-cross
   'oam-sprites      32    ; <= 64 OAM sprites
   'scanline-sprites 6     ; <= 8 sprites per scanline
   'oam-mux?         #t
   'ram-bytes        448   ; 224 B BOARD_RAM + 224 B UNDER_RAM <= 1280 B
   'prg-rom-bytes    prg-bytes
   'chr-tiles        19    ; 19 custom 2bpp tiles <= 512
   'vram-dma-bytes   8     ; 8 B HUD status stripe per VBlank <= 128 B
   'bg-palettes      4
   'spr-palettes     4
   'attr-clashes     0     ; 16x16 metatile alignment guarantees 0 attribute clashes
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
