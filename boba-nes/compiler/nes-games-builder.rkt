#lang racket/base

;; ============================================================================
;; compiler/nes-games-builder.rkt
;; Complete Playable MOS 6502 / 2C02 NES ROM Compilers for:
;;   1. Super Mario Bros. (World 1-1 Side-Scrolling Platformer with Sprite 0 HUD Split)
;;   2. The Legend of Zelda (Top-Down Action-Adventure with Sword Combat & Room Transitions)
;;   3. Nintendo NES Tetris (10x20 Well, 7 Tetrominoes, Rotation, Line Clear & VBlank Stripe Queue)
;; ============================================================================

(require racket/list
         racket/match
         racket/set
         "graded-typechecker.rkt"
         "diagnostics.rkt"
         "mos6502-assembler.rkt"
         "boba-rom-builder.rkt"
         "../lib/nes-chr-assets.rkt"
         (only-in "decompiled-smb.rkt"
                  MARIO-ZP-DEAD
                  MARIO-ZP-LIVES
                  MARIO-ZP-STAGE-ID
                  MARIO-ZP-GAME-COMPLETED
                  MARIO-ZP-STAGE-DIRTY
                  emit-decompiled-mario-6502-program)
         (only-in "decompiled-zelda.rkt"
                  ZELDA-ZP-HURT-TIMER
                  ZELDA-ZP-DEAD
                  ZELDA-ZP-TRIFORCE-COUNT
                  ZELDA-ZP-GAME-COMPLETED
                  emit-decompiled-zelda-6502-program)
         (only-in "decompiled-tetris.rkt"
                  TETRIS-ZP-GAME-OVER
                  TETRIS-ZP-GAME-WON
                  TETRIS-ZP-SPAWN-IDX
                  emit-decompiled-tetris-6502-program))

(provide
 ;; 1. Super Mario Bros. (Full 4-Stage Campaign: World 1-1 -> 1-2 -> 4-1 -> 8-4)
 MARIO-ZP-SCROLL-X
 MARIO-ZP-SCROLL-NT
 MARIO-ZP-X-WORLD-LO
 MARIO-ZP-X-WORLD-HI
 MARIO-ZP-SCREEN-X
 MARIO-ZP-Y-SUB
 MARIO-ZP-Y-PX
 MARIO-ZP-VY-SUB
 MARIO-ZP-VY-PX
 MARIO-ZP-ON-GROUND
 MARIO-ZP-COINS
 MARIO-ZP-SCORE
 MARIO-ZP-GOOMBA-X
 MARIO-ZP-GOOMBA-ALIVE
 MARIO-ZP-QBLOCK-HIT
 MARIO-ZP-WON
 MARIO-ZP-DEAD
 MARIO-ZP-LIVES
 MARIO-ZP-STAGE-ID
 MARIO-ZP-GAME-COMPLETED
 MARIO-ZP-STAGE-DIRTY
 compile-mario-nes-rom!

 ;; 2. The Legend of Zelda (Full 4-Room Quest: Overworld -> Sanctum -> Underworld Boss -> Death Mountain Ganon)
 ZELDA-ZP-LINK-X
 ZELDA-ZP-LINK-Y
 ZELDA-ZP-LINK-DIR
 ZELDA-ZP-SWORD-TIMER
 ZELDA-ZP-OCTO-X
 ZELDA-ZP-OCTO-Y
 ZELDA-ZP-OCTO-ALIVE
 ZELDA-ZP-RUPEES
 ZELDA-ZP-KEYS
 ZELDA-ZP-ROOM-ID
 ZELDA-ZP-HEARTS
 ZELDA-ZP-TRIFORCE-WON
 ZELDA-ZP-OAM-CURSOR
 ZELDA-ZP-HURT-TIMER
 ZELDA-ZP-DEAD
 ZELDA-ZP-TRIFORCE-COUNT
 ZELDA-ZP-GAME-COMPLETED
 compile-zelda-nes-rom!

 ;; 3. Nintendo NES Tetris (10x20 Well, Multi-Line & Multi-Level A-Type Campaign)
 TETRIS-WELL-RAM-BASE
 TETRIS-ZP-PIECE-ID
 TETRIS-ZP-PIECE-ROT
 TETRIS-ZP-PIECE-X
 TETRIS-ZP-PIECE-Y
 TETRIS-ZP-NEXT-ID
 TETRIS-ZP-DROP-TIMER
 TETRIS-ZP-LINES
 TETRIS-ZP-SCORE
 TETRIS-ZP-LEVEL
 TETRIS-ZP-DIRTY-ROW
 TETRIS-ZP-GAME-OVER
 TETRIS-ZP-GAME-WON
 TETRIS-ZP-SPAWN-IDX
 compile-tetris-nes-rom!)

;; ============================================================================
;; PART 1: SUPER MARIO BROS. (WORLD 1-1 SIDE-SCROLLING PLATFORMER)
;; ============================================================================
;; Zero-Page Layout ($0010-$003F):
(define MARIO-ZP-BUTTONS      #x10)
(define MARIO-ZP-PREV-BTN     #x11)
(define MARIO-ZP-NEW-BTN      #x12)
(define MARIO-ZP-FRAME-CNT    #x13)
(define MARIO-ZP-SCROLL-X     #x14) ; 0..255 fine+coarse X scroll
(define MARIO-ZP-SCROLL-NT    #x15) ; 0 = Nametable 0 ($2000), 1 = Nametable 1 ($2400)
(define MARIO-ZP-X-WORLD-LO   #x16) ; 16-bit world X coordinate low byte (0..511)
(define MARIO-ZP-X-WORLD-HI   #x17) ; 16-bit world X coordinate high byte (0..1)
(define MARIO-ZP-SCREEN-X     #x18) ; Screen-space X (clamped for OAM rendering)
(define MARIO-ZP-Y-SUB        #x19) ; 8.8 fixed-point Y subpixel
(define MARIO-ZP-Y-PX         #x1A) ; 8.8 fixed-point Y pixel (ground = 176)
(define MARIO-ZP-VY-SUB       #x1B) ; 8.8 signed vertical velocity low byte
(define MARIO-ZP-VY-PX        #x1C) ; 8.8 signed vertical velocity high byte
(define MARIO-ZP-ON-GROUND    #x1D) ; 1 when standing on ground/pipe/block
(define MARIO-ZP-COINS        #x1E) ; Collected coins counter
(define MARIO-ZP-SCORE        #x1F) ; Score counter (x100)
(define MARIO-ZP-GOOMBA-X     #x20) ; Goomba 1 world X (low byte)
(define MARIO-ZP-GOOMBA-ALIVE #x21) ; 1 = patrolling, 0 = squashed!
(define MARIO-ZP-QBLOCK-HIT   #x22) ; 1 = ? block at X=80 bonked -> coin spawned!
(define MARIO-ZP-COIN-ANIM-Y  #x23) ; Rising coin animation Y (0 = inactive)
(define MARIO-ZP-WON          #x24) ; 1 = touched Flagpole at X >= 340!
(define MARIO-ZP-VRAM-PENDING #x25) ; 1 = NMI should update bonked ? block tile in VRAM

;; Loads the authentic 8 KB CHR-ROM from `assets/roms/super_mario_bros.nes`:
;;   - Pattern Table 0 ($0000-$0FFF, Sprites): Small Mario (#x32..#x35 row-major),
;;     Goomba (#x70..#x73 row-major), Coin (#x60), Sprite-0 Coin-Bottom Anchor (#xFF)
;;   - Pattern Table 1 ($1000-$1FFF, BG via PPUCTRL=#x90): Digits 0-9 (#x00..#x09),
;;     Letters A-Z (#x0A..#x23), Blank Sky (#x24), HUD Coin (#x2E), '?' Block (#x53..#x56),
;;     Empty Block (#x57..#x5A), Brick (#x45/#x47), Warp Pipe (#x60..#x65), Ground (#xB4..#xB7)
(define (build-mario-chr-rom)
  (load-authentic-smb-chr-rom))

(define MARIO-SMALL-METASPRITE
  (make-metasprite-desc 'mario-small '(#x32 #x33 #x34 #x35) #:order 'row-major #:attr #x00))

(define GOOMBA-METASPRITE
  (make-metasprite-desc 'goomba '(#x70 #x71 #x72 #x73) #:order 'row-major #:attr #x01))

(define (emit-mario-6502-program)
  `(;; ========================================================================
    ;; Super Mario Bros. (World 1-1) in #lang boba-nes (Authentic SMB1 CHR-ROM)
    ;; ========================================================================
    (label reset_handler)
    (SEI)
    (CLD)
    (LDX #:imm #xFF)
    (TXS)
    (JSR boot_init)
    (label main_loop)
    (LDA #:zp #x0F)
    (BEQ main_loop)
    (LDA #:imm 0)
    (STA #:zp #x0F)
    (JSR game_frame_step)
    (JMP main_loop)

    (label boot_init)
    (LDA #:imm #x00)
    (STA #:abs #x2000)
    (STA #:abs #x2001)
    ;; Clear Zero-Page ($00-$FF) and BSS ($0300-$04FF)
    (LDX #:imm 0)
    (LDA #:imm 0)
    (label clr_zp_m)
    (STA #:zpx #x00)
    (STA #:absx #x0300)
    (INX)
    (BNE clr_zp_m)

    ;; Hide all 64 OAM sprites ($0200-$02FF = $F8)
    (LDA #:imm #xF8)
    (LDX #:imm 0)
    (label clr_oam_m)
    (STA #:absx #x0200)
    (INX)
    (BNE clr_oam_m)

    ;; Load 32-byte SMB1 Palette ($3F00-$3F1F):
    ;; Sky Blue (#x22) universal background!
    (BIT #:abs #x2002)
    (LDA #:imm #x3F)
    (STA #:abs #x2006)
    (LDA #:imm #x00)
    (STA #:abs #x2006)
    (LDX #:imm 0)
    (label load_pal_m)
    (LDA #:absx mario_palette_table)
    (STA #:abs #x2007)
    (INX)
    (CPX #:imm 32)
    (BNE load_pal_m)

    ;; Clear both Nametable 0 ($2000-$23FF) and Nametable 1 ($2400-$27FF)
    ;; to SMB1's Blank Sky Tile (#x24, since #x00 in SMB1 PT1 is the digit '0'!)
    (BIT #:abs #x2002)
    (LDA #:imm #x20)
    (STA #:abs #x2006)
    (LDA #:imm #x00)
    (STA #:abs #x2006)
    (LDY #:imm 8)
    (LDA #:imm #x24)
    (LDX #:imm 0)
    (label clr_nt_m)
    (STA #:abs #x2007)
    (INX)
    (BNE clr_nt_m)
    (DEY)
    (BNE clr_nt_m)

    ;; Zero both Attribute Tables ($23C0-$23FF and $27C0-$27FF) after #x24 fill
    (BIT #:abs #x2002)
    (LDA #:imm #x23) (STA #:abs #x2006) (LDA #:imm #xC0) (STA #:abs #x2006)
    (LDA #:imm #x00) (LDX #:imm 64)
    (label clr_attr_nt0_m) (STA #:abs #x2007) (DEX) (BNE clr_attr_nt0_m)
    (BIT #:abs #x2002)
    (LDA #:imm #x27) (STA #:abs #x2006) (LDA #:imm #xC0) (STA #:abs #x2006)
    (LDA #:imm #x00) (LDX #:imm 64)
    (label clr_attr_nt1_m) (STA #:abs #x2007) (DEX) (BNE clr_attr_nt1_m)

    ;; Draw Stationary Status Bar HUD at Row 2 of Nametable 0 ($2043..$2057)
    ;; using NINTENDO-STD-CHAR-MAP ("MARIO  *x0  WORLD 1-1", where '*' = #x2E HUD Coin at $204A,
    ;; '0' is at $204C -> tile #x00!):
    ,@(emit-nametable-string-6502 #x2043 NINTENDO-STD-CHAR-MAP "MARIO  *x0  WORLD 1-1")

    ;; Draw World 1-1 Ground Rows (Rows 24..27 -> $2300-$237F in NT0 and $2700-$277F in NT1)
    ;; using SMB1's authentic Cracked Ground Brick tiles (#xB4/#xB5)
    (BIT #:abs #x2002)
    (LDA #:imm #x23)
    (STA #:abs #x2006)
    (LDA #:imm #x00)
    (STA #:abs #x2006)
    (LDX #:imm 128)
    (LDA #:imm #xB4)
    (label fill_gnd_nt0)
    (STA #:abs #x2007)
    (DEX)
    (BNE fill_gnd_nt0)

    (BIT #:abs #x2002)
    (LDA #:imm #x27)
    (STA #:abs #x2006)
    (LDA #:imm #x00)
    (STA #:abs #x2006)
    (LDX #:imm 128)
    (LDA #:imm #xB4)
    (label fill_gnd_nt1)
    (STA #:abs #x2007)
    (DEX)
    (BNE fill_gnd_nt1)

    ;; Draw World 1-1 Landmarks in Nametable 0 ($2000) using authentic SMB1 PT1 tiles:
    ;; 1. 2x2 '?' Question Block (#x53,#x54 / #x55,#x56) & Brick Row (#x45/#x47) at Rows 14..15 ($21C8..$21ED)
    ;;    (Aligned to 16x16 metatile rows 14..15 so top & bottom share Attribute Row $23D8..$23DF!)
    (BIT #:abs #x2002)
    (LDA #:imm #x21) (STA #:abs #x2006) (LDA #:imm #xC8) (STA #:abs #x2006)
    (LDA #:imm #x45) (STA #:abs #x2007) ; Brick top (col 8)
    (LDA #:imm #x53) (STA #:abs #x2007) ; '?' Block TL at col 9 ($21C9)
    (LDA #:imm #x54) (STA #:abs #x2007) ; '?' Block TR at col 10 ($21CA)
    (LDA #:imm #x45) (STA #:abs #x2007) ; Brick top (col 11)
    (LDA #:imm #x53) (STA #:abs #x2007) ; '?' Block TL (col 12)
    (LDA #:imm #x54) (STA #:abs #x2007) ; '?' Block TR (col 13)

    (BIT #:abs #x2002)
    (LDA #:imm #x21) (STA #:abs #x2006) (LDA #:imm #xE8) (STA #:abs #x2006)
    (LDA #:imm #x47) (STA #:abs #x2007) ; Brick bottom (col 8)
    (LDA #:imm #x55) (STA #:abs #x2007) ; '?' Block BL at col 9 ($21E9)
    (LDA #:imm #x56) (STA #:abs #x2007) ; '?' Block BR at col 10 ($21EA)
    (LDA #:imm #x47) (STA #:abs #x2007) ; Brick bottom (col 11)
    (LDA #:imm #x55) (STA #:abs #x2007) ; '?' Block BL (col 12)
    (LDA #:imm #x56) (STA #:abs #x2007) ; '?' Block BR (col 13)

    ;; 2. Authentic Green Warp Pipe at Cols 20..21, Rows 20..23 ($2294..$22F5)
    (BIT #:abs #x2002)
    (LDA #:imm #x22) (STA #:abs #x2006) (LDA #:imm #x94) (STA #:abs #x2006)
    (LDA #:imm #x60) (STA #:abs #x2007) (LDA #:imm #x63) (STA #:abs #x2007)
    (LDA #:imm #x22) (STA #:abs #x2006) (LDA #:imm #xB4) (STA #:abs #x2006)
    (LDA #:imm #x64) (STA #:abs #x2007) (LDA #:imm #x67) (STA #:abs #x2007)
    (LDA #:imm #x22) (STA #:abs #x2006) (LDA #:imm #xD4) (STA #:abs #x2006)
    (LDA #:imm #x68) (STA #:abs #x2007) (LDA #:imm #x6A) (STA #:abs #x2007)
    (LDA #:imm #x22) (STA #:abs #x2006) (LDA #:imm #xF4) (STA #:abs #x2006)
    (LDA #:imm #x68) (STA #:abs #x2007) (LDA #:imm #x6A) (STA #:abs #x2007)

    ;; Draw World 1-1 Landmarks in Nametable 1 ($2400 - Scrolled Second Screen!):
    ;; 1. Brick Staircase at Row 21..23 ($26A4..$26E7) using SMB1 Hard Block (#x57)
    (BIT #:abs #x2002)
    (LDA #:imm #x26) (STA #:abs #x2006) (LDA #:imm #xE4) (STA #:abs #x2006)
    (LDA #:imm #x57) (STA #:abs #x2007) (STA #:abs #x2007) (STA #:abs #x2007)
    (LDA #:imm #x26) (STA #:abs #x2006) (LDA #:imm #xC5) (STA #:abs #x2006)
    (LDA #:imm #x57) (STA #:abs #x2007) (STA #:abs #x2007)
    (LDA #:imm #x26) (STA #:abs #x2006) (LDA #:imm #xA6) (STA #:abs #x2006)
    (LDA #:imm #x57) (STA #:abs #x2007)

    ;; 2. Flagpole at Col 12 of Nametable 1 (World X = 256 + 96 = 352! $250C..$26EC)
    ;;    using SMB1 Flagpole Orb (#x2F) and Shaft (#xA2)
    (BIT #:abs #x2002)
    (LDA #:imm #x25) (STA #:abs #x2006) (LDA #:imm #x0C) (STA #:abs #x2006)
    (LDA #:imm #x2F) (STA #:abs #x2007) ; Flagpole Orb
    (LDA #:imm #x25) (STA #:abs #x2006) (LDA #:imm #x2C) (STA #:abs #x2006)
    (LDA #:imm #xA2) (STA #:abs #x2007)
    (LDA #:imm #x25) (STA #:abs #x2006) (LDA #:imm #x4C) (STA #:abs #x2006)
    (LDA #:imm #xA2) (STA #:abs #x2007)
    (LDA #:imm #x25) (STA #:abs #x2006) (LDA #:imm #x6C) (STA #:abs #x2006)
    (LDA #:imm #xA2) (STA #:abs #x2007)
    (LDA #:imm #x25) (STA #:abs #x2006) (LDA #:imm #x8C) (STA #:abs #x2006)
    (LDA #:imm #xA2) (STA #:abs #x2007)
    (LDA #:imm #x25) (STA #:abs #x2006) (LDA #:imm #xAC) (STA #:abs #x2006)
    (LDA #:imm #xA2) (STA #:abs #x2007)
    (LDA #:imm #x25) (STA #:abs #x2006) (LDA #:imm #xCC) (STA #:abs #x2006)
    (LDA #:imm #xA2) (STA #:abs #x2007)

    ;; 3. Castle at Col 18..21 of Nametable 1 ($2692..$26D5) using SMB1 Masonry Bricks (#x45/#x47)
    (BIT #:abs #x2002)
    (LDA #:imm #x26) (STA #:abs #x2006) (LDA #:imm #x92) (STA #:abs #x2006)
    (LDA #:imm #x45) (STA #:abs #x2007) (STA #:abs #x2007) (STA #:abs #x2007) (STA #:abs #x2007)
    (LDA #:imm #x26) (STA #:abs #x2006) (LDA #:imm #xB2) (STA #:abs #x2006)
    (LDA #:imm #x47) (STA #:abs #x2007) (STA #:abs #x2007) (STA #:abs #x2007) (STA #:abs #x2007)
    (LDA #:imm #x26) (STA #:abs #x2006) (LDA #:imm #xD2) (STA #:abs #x2006)
    (LDA #:imm #x47) (STA #:abs #x2007) (STA #:abs #x2007) (STA #:abs #x2007) (STA #:abs #x2007)

    ;; Set Attribute Tables ($23C0-$23FF):
    ;;   $23C0..$23C7 (Rows 0..3)   = #x55 (Palette 1 Gold/White HUD)
    ;;   $23D8..$23DF (Rows 12..15) = #x55 (Palette 1 Gold/Cream Question Blocks & Bricks)
    ;;   $23ED        (Rows 20..23, Cols 20..23) = #xAA (Palette 2 Lime/Forest Green Warp Pipe!)
    ;;   $27D2..$27EB (Flagpole Shaft in NT1)    = #xAA (Palette 2 Green Flagpole Shaft!)
    (BIT #:abs #x2002)
    (LDA #:imm #x23) (STA #:abs #x2006) (LDA #:imm #xC0) (STA #:abs #x2006)
    (LDA #:imm #x55)
    (LDX #:imm 8)
    (label attr_hud_m) (STA #:abs #x2007) (DEX) (BNE attr_hud_m)
    (BIT #:abs #x2002)
    (LDA #:imm #x23) (STA #:abs #x2006) (LDA #:imm #xD8) (STA #:abs #x2006)
    (LDA #:imm #x55) ; Palette 1 for Question Blocks row (Rows 12..15)
    (LDX #:imm 8)
    (label attr_qb_m)
    (STA #:abs #x2007)
    (DEX)
    (BNE attr_qb_m)
    ;; Set $23ED (Rows 20..23, Cols 20..23) to #xAA (Palette 2 Green) for the Warp Pipe!
    (BIT #:abs #x2002)
    (LDA #:imm #x23) (STA #:abs #x2006) (LDA #:imm #xED) (STA #:abs #x2006)
    (LDA #:imm #xAA) (STA #:abs #x2007)

    ;; Initialize Mario & World 1-1 State:
    ;; Mario starts at World X = 40, Y = 176 (standing on ground), Goomba at X = 120
    (LDA #:imm 40)
    (STA #:zp ,MARIO-ZP-X-WORLD-LO)
    (STA #:zp ,MARIO-ZP-SCREEN-X)
    (LDA #:imm 0)
    (STA #:zp ,MARIO-ZP-X-WORLD-HI)
    (STA #:zp ,MARIO-ZP-SCROLL-X)
    (STA #:zp ,MARIO-ZP-SCROLL-NT)
    (STA #:zp ,MARIO-ZP-Y-SUB)
    (STA #:zp ,MARIO-ZP-VY-SUB)
    (STA #:zp ,MARIO-ZP-VY-PX)
    (STA #:zp ,MARIO-ZP-COINS)
    (STA #:zp ,MARIO-ZP-SCORE)
    (STA #:zp ,MARIO-ZP-QBLOCK-HIT)
    (STA #:zp ,MARIO-ZP-COIN-ANIM-Y)
    (STA #:zp ,MARIO-ZP-WON)
    (LDA #:imm 176)
    (STA #:zp ,MARIO-ZP-Y-PX)
    (LDA #:imm 1)
    (STA #:zp ,MARIO-ZP-ON-GROUND)
    (STA #:zp ,MARIO-ZP-GOOMBA-ALIVE)
    (LDA #:imm 120)
    (STA #:zp ,MARIO-ZP-GOOMBA-X)

    ;; Place OAM Sprite 0 at (X=80, Y=15, Tile=#xFF, Attr=#x02) directly overlapping the bottom
    ;; of the HUD Coin ($204A = #x2E at X=80, Y=16) for authentic invisible Sprite 0 Hit!
    (LDA #:imm 15)   (STA #:abs #x0200)
    (LDA #:imm #xFF) (STA #:abs #x0201)
    (LDA #:imm #x02) (STA #:abs #x0202)
    (LDA #:imm 80)   (STA #:abs #x0203)

    ;; Enable 2A03 APU Pulse 1 + Pulse 2 + Triangle
    (LDA #:imm #x07)
    (STA #:abs #x4015)

    ;; Reset PPU scroll latch and enable NMI + BG Pattern Table 1 ($1000) + Sprite Pattern Table 0 ($0000):
    ;; PPUCTRL = #$90 (bit 7 NMI=1, bit 4 BG_PT=1, bit 3 SPR_PT=0)
    (BIT #:abs #x2002)
    (LDA #:imm 0)
    (STA #:abs #x2005)
    (STA #:abs #x2005)
    (LDA #:imm #x90)
    (STA #:abs #x2000)
    (LDA #:imm #x1E)
    (STA #:abs #x2001)
    (JSR build_mario_oam)
    (LDA #:imm #x00)
    (STA #:abs #x2003)
    (LDA #:imm #x02)
    (STA #:abs #x4014)
    (RTS)

    ;; ========================================================================
    ;; ActiveFrame Step: Sprite 0 HUD Split + 8.8 Subpixel Physics + Collisions
    ;; ========================================================================
    (label game_frame_step)
    (INC #:zp ,MARIO-ZP-FRAME-CNT)

    ;; 1. Perform Mid-Frame Sprite-0-Hit Raster Split at HUD Coin bottom scanline!
    ;;    Top HUD stays at scroll (0,0); playfield below Y=29 scrolls by (SCROLL_NT, SCROLL_X)
    ;;    keeping PPUCTRL bit 4 = 1 (#x90) so Background stays on Pattern Table 1 ($1000)!
    (label m_s0_clear)
    (BIT #:abs #x2002)
    (BVS m_s0_clear)
    (label m_s0_hit)
    (BIT #:abs #x2002)
    (BVC m_s0_hit)
    ;; Wait ~180 CPU cycles (~540 PPU dots) so scanlines 22..23 of the HUD finish rendering before scroll split!
    (LDX #:imm 36)
    (label m_s0_hblank)
    (DEX)
    (BNE m_s0_hblank)
    (LDA #:zp ,MARIO-ZP-SCROLL-NT)
    (AND #:imm #x01)
    (ORA #:imm #x90)
    (STA #:abs #x2000)
    (LDA #:zp ,MARIO-ZP-SCROLL-X)
    (STA #:abs #x2005)
    (LDA #:imm 0)
    (STA #:abs #x2005)


    ;; 2. Poll Controller 1 ($4016)
    (LDA #:zp ,MARIO-ZP-BUTTONS)
    (STA #:zp ,MARIO-ZP-PREV-BTN)
    (LDA #:imm 1)
    (STA #:abs #x4016)
    (LDA #:imm 0)
    (STA #:abs #x4016)
    (STA #:zp ,MARIO-ZP-BUTTONS)
    (LDX #:imm 8)
    (label poll_m_loop)
    (LDA #:abs #x4016)
    (LSR)
    (ROR #:zp ,MARIO-ZP-BUTTONS)
    (DEX)
    (BNE poll_m_loop)
    (LDA #:zp ,MARIO-ZP-PREV-BTN)
    (EOR #:imm #xFF)
    (AND #:zp ,MARIO-ZP-BUTTONS)
    (STA #:zp ,MARIO-ZP-NEW-BTN)

    ;; 3. Horizontal Running Input (Held LEFT / RIGHT moves 3 px/frame + advances Camera Scroll!)
    (LDA #:zp ,MARIO-ZP-BUTTONS)
    (AND #:imm ,BTN-RIGHT)
    (BEQ check_m_left)
    ;; Move Mario World X right by +3 pixels (16-bit addition)
    (CLC)
    (LDA #:zp ,MARIO-ZP-X-WORLD-LO)
    (ADC #:imm 3)
    (STA #:zp ,MARIO-ZP-X-WORLD-LO)
    (LDA #:zp ,MARIO-ZP-X-WORLD-HI)
    (ADC #:imm 0)
    (STA #:zp ,MARIO-ZP-X-WORLD-HI)
    ;; Advance horizontal camera scroll if Mario screen X > 104 and camera < 256
    (LDA #:zp ,MARIO-ZP-X-WORLD-LO)
    (SEC)
    (SBC #:zp ,MARIO-ZP-SCROLL-X)
    (CMP #:imm 104)
    (BCC update_screen_x)
    (LDA #:zp ,MARIO-ZP-SCROLL-NT)
    (BNE update_screen_x) ; Stop camera at +192 scroll
    (LDA #:zp ,MARIO-ZP-SCROLL-X)
    (CMP #:imm 192)
    (BCS update_screen_x)
    (CLC)
    (ADC #:imm 3)
    (STA #:zp ,MARIO-ZP-SCROLL-X)
    (JMP update_screen_x)

    (label check_m_left)
    (LDA #:zp ,MARIO-ZP-BUTTONS)
    (AND #:imm ,BTN-LEFT)
    (BEQ update_screen_x)
    (LDA #:zp ,MARIO-ZP-X-WORLD-LO)
    (CMP #:imm 8)
    (BCC update_screen_x)
    (SEC)
    (SBC #:imm 3)
    (STA #:zp ,MARIO-ZP-X-WORLD-LO)

    (label update_screen_x)
    ;; Compute screen-space X = world_x_lo - scroll_x (with 16-bit borrow from world_x_hi)
    (SEC)
    (LDA #:zp ,MARIO-ZP-X-WORLD-LO)
    (SBC #:zp ,MARIO-ZP-SCROLL-X)
    (STA #:zp ,MARIO-ZP-SCREEN-X)

    ;; 4. Jump Input ('A' button when ON_GROUND == 1):
    ;;    Sets 8.8 velocity VY = -5.0 px/frame ($FB00) and plays Pulse 1 jump sweep!
    (LDA #:zp ,MARIO-ZP-NEW-BTN)
    (AND #:imm ,BTN-A)
    (BEQ step_vertical_physics)
    (LDA #:zp ,MARIO-ZP-ON-GROUND)
    (BEQ step_vertical_physics)
    (LDA #:imm 0)
    (STA #:zp ,MARIO-ZP-ON-GROUND)
    (STA #:zp ,MARIO-ZP-VY-SUB)
    (LDA #:imm #xFA) ; -6 px/frame initial upward impulse (reaches apex Y=128)
    (STA #:zp ,MARIO-ZP-VY-PX)
    ;; Trigger 2A03 Pulse 1 Jump SFX
    (LDA #:imm #x9F) (STA #:abs #x4000)
    (LDA #:imm #x9A) (STA #:abs #x4001)
    (LDA #:imm #x90) (STA #:abs #x4002)
    (LDA #:imm #x28) (STA #:abs #x4003)

    ;; 5. 8.8 Fixed-Point Vertical Gravity & Subpixel Integration:
    (label step_vertical_physics)
    (LDA #:zp ,MARIO-ZP-ON-GROUND)
    (BNE check_qblock_and_enemies)
    ;; VY += $0060 (+0.375 px/frame^2 gravity)
    (CLC)
    (LDA #:zp ,MARIO-ZP-VY-SUB)
    (ADC #:imm #x60)
    (STA #:zp ,MARIO-ZP-VY-SUB)
    (LDA #:zp ,MARIO-ZP-VY-PX)
    (ADC #:imm #x00)
    (STA #:zp ,MARIO-ZP-VY-PX)
    ;; Y += VY (16-bit signed 8.8 addition)
    (CLC)
    (LDA #:zp ,MARIO-ZP-Y-SUB)
    (ADC #:zp ,MARIO-ZP-VY-SUB)
    (STA #:zp ,MARIO-ZP-Y-SUB)
    (LDA #:zp ,MARIO-ZP-Y-PX)
    (ADC #:zp ,MARIO-ZP-VY-PX)
    (STA #:zp ,MARIO-ZP-Y-PX)

    ;; Check '?' Question Block Headbutt Collision when moving upward (VY_PX < 0, Y <= 138, X in 66..92)
    (LDA #:zp ,MARIO-ZP-VY-PX)
    (BPL check_ground_landing) ; Only bonk when moving upward (negative VY has bit 7 = 1)
    (LDA #:zp ,MARIO-ZP-Y-PX)
    (CMP #:imm 138)
    (BCS check_ground_landing)
    (LDA #:zp ,MARIO-ZP-X-WORLD-HI)
    (BNE check_ground_landing)
    (LDA #:zp ,MARIO-ZP-X-WORLD-LO)
    (CMP #:imm 66)
    (BCC check_ground_landing)
    (CMP #:imm 92)
    (BCS check_ground_landing)
    ;; Bonked '?' Question Block! Reflect velocity downward (VY = +1) & award Coin!
    (LDA #:imm 138)
    (STA #:zp ,MARIO-ZP-Y-PX)
    (LDA #:imm 1)
    (STA #:zp ,MARIO-ZP-VY-PX)
    (LDA #:imm 0)
    (STA #:zp ,MARIO-ZP-VY-SUB)
    (LDA #:zp ,MARIO-ZP-QBLOCK-HIT)
    (BNE check_ground_landing)
    (LDA #:imm 1)
    (STA #:zp ,MARIO-ZP-QBLOCK-HIT)
    (STA #:zp ,MARIO-ZP-VRAM-PENDING)
    (INC #:zp ,MARIO-ZP-COINS)
    (INC #:zp ,MARIO-ZP-SCORE)
    (LDA #:imm 104)
    (STA #:zp ,MARIO-ZP-COIN-ANIM-Y)
    ;; Play Coin Chime on Pulse 2 ($4004-$4007)
    (LDA #:imm #xBF) (STA #:abs #x4004)
    (LDA #:imm #x08) (STA #:abs #x4005)
    (LDA #:imm #x42) (STA #:abs #x4006)
    (LDA #:imm #x18) (STA #:abs #x4007)

    ;; Check Ground Landing (Y_PX >= 176 when VY_PX >= 0)
    (label check_ground_landing)
    (LDA #:zp ,MARIO-ZP-VY-PX)
    (BMI check_qblock_and_enemies)
    (LDA #:zp ,MARIO-ZP-Y-PX)
    (CMP #:imm 176)
    (BCC check_qblock_and_enemies)
    (LDA #:imm 176)
    (STA #:zp ,MARIO-ZP-Y-PX)
    (LDA #:imm 0)
    (STA #:zp ,MARIO-ZP-Y-SUB)
    (STA #:zp ,MARIO-ZP-VY-SUB)
    (STA #:zp ,MARIO-ZP-VY-PX)
    (LDA #:imm 1)
    (STA #:zp ,MARIO-ZP-ON-GROUND)

    ;; 6. Goomba AI & Stomp Collision + Flagpole Victory Check
    (label check_qblock_and_enemies)
    (LDA #:zp ,MARIO-ZP-GOOMBA-ALIVE)
    (BEQ check_flagpole_win)
    ;; Check horizontal overlap: |mario_x - goomba_x| < 14
    (LDA #:zp ,MARIO-ZP-X-WORLD-HI)
    (BNE check_flagpole_win)
    (LDA #:zp ,MARIO-ZP-X-WORLD-LO)
    (CLC)
    (ADC #:imm 12)
    (CMP #:zp ,MARIO-ZP-GOOMBA-X)
    (BCC check_flagpole_win)
    (LDA #:zp ,MARIO-ZP-GOOMBA-X)
    (CLC)
    (ADC #:imm 12)
    (CMP #:zp ,MARIO-ZP-X-WORLD-LO)
    (BCC check_flagpole_win)
    ;; Check if Mario is descending from above (Y_PX in 152..172 and VY_PX > 0 -> Stomp!)
    (LDA #:zp ,MARIO-ZP-ON-GROUND)
    (BNE check_flagpole_win)
    (LDA #:zp ,MARIO-ZP-Y-PX)
    (CMP #:imm 150)
    (BCC check_flagpole_win)
    ;; Squash Goomba, bounce Mario upward (VY = -3), and increment Score!
    (LDA #:imm 0)
    (STA #:zp ,MARIO-ZP-GOOMBA-ALIVE)
    (LDA #:imm #xFD)
    (STA #:zp ,MARIO-ZP-VY-PX)
    (INC #:zp ,MARIO-ZP-SCORE)

    ;; 7. Check Flagpole Victory (World X >= 340 -> X_HI == 1 and X_LO >= 84, or X_LO >= 220)
    (label check_flagpole_win)
    (LDA #:zp ,MARIO-ZP-X-WORLD-HI)
    (BEQ check_nt0_flagpole)
    (LDA #:zp ,MARIO-ZP-X-WORLD-LO)
    (CMP #:imm 80)
    (BCC step_coin_anim)
    (LDA #:imm 1)
    (STA #:zp ,MARIO-ZP-WON)
    (JMP step_coin_anim)

    (label check_nt0_flagpole)
    (LDA #:zp ,MARIO-ZP-X-WORLD-LO)
    (CMP #:imm 220)
    (BCC step_coin_anim)
    (LDA #:imm 1)
    (STA #:zp ,MARIO-ZP-WON)

    (label step_coin_anim)
    (LDA #:zp ,MARIO-ZP-COIN-ANIM-Y)
    (BEQ done_m_step)
    (SEC)
    (SBC #:imm 2)
    (CMP #:imm 80)
    (BCS keep_coin_anim)
    (LDA #:imm 0)
    (label keep_coin_anim)
    (STA #:zp ,MARIO-ZP-COIN-ANIM-Y)

    (label done_m_step)
    (JSR build_mario_oam)
    (RTS)

    ;; ========================================================================
    ;; Build OAM Sprite Buffer ($0200-$02FF) using Authentic SMB1 PT0 Tiles:
    ;;   Slot 0 ($0200)    : Sprite 0 HUD Coin-Bottom Anchor (X=24, Y=23, Tile=#xFF)
    ;;   Slots 1..4 ($0204): Small Mario 16x16 Metasprite (#x32..#x35, row-major, Pal 0)
    ;;   Slots 5..8 ($0214): Goomba 16x16 Metasprite (#x70..#x73, row-major, Pal 1)
    ;;   Slot 9 ($0224)    : Spinning Coin Sprite (#x60, Pal 2)
    ;; ========================================================================
    (label build_mario_oam)
    ;; Keep Slot 0 anchored at (X=80, Y=15, Tile=#xFF, Attr=#x02) over HUD Coin ($204A = #x2E) for Sprite 0 Hit
    (LDA #:imm 15)   (STA #:abs #x0200)
    (LDA #:imm #xFF) (STA #:abs #x0201)
    (LDA #:imm #x02) (STA #:abs #x0202)
    (LDA #:imm 80)   (STA #:abs #x0203)

    ;; Emit Authentic Small Mario 16x16 Metasprite (#x32, #x33, #x34, #x35) at $0204..$0213
    ,@(emit-metasprite-oam-6502 MARIO-SMALL-METASPRITE MARIO-ZP-SCREEN-X MARIO-ZP-Y-PX #x04)

    ;; Emit Authentic Goomba 16x16 Metasprite (#x70, #x71, #x72, #x73) at $0214..$0223 (if alive)
    (LDA #:zp ,MARIO-ZP-GOOMBA-ALIVE)
    (BNE draw_goomba_oam)
    (LDA #:imm #xF8)
    (STA #:abs #x0214) (STA #:abs #x0218) (STA #:abs #x021C) (STA #:abs #x0220)
    (JMP draw_coin_oam)
    (label draw_goomba_oam)
    (LDA #:imm 176)
    (STA #:abs #x0214) (STA #:abs #x0218)
    (LDA #:imm 184)
    (STA #:abs #x021C) (STA #:abs #x0220)
    (LDA #:imm #x70) (STA #:abs #x0215)
    (LDA #:imm #x71) (STA #:abs #x0219)
    (LDA #:imm #x72) (STA #:abs #x021D)
    (LDA #:imm #x73) (STA #:abs #x0221)
    (LDA #:imm #x01)
    (STA #:abs #x0216) (STA #:abs #x021A) (STA #:abs #x021E) (STA #:abs #x0222)
    (LDA #:zp ,MARIO-ZP-GOOMBA-X)
    (SEC)
    (SBC #:zp ,MARIO-ZP-SCROLL-X)
    (STA #:abs #x0217) (STA #:abs #x021F)
    (CLC)
    (ADC #:imm 8)
    (STA #:abs #x021B) (STA #:abs #x0223)

    ;; Emit Authentic 8x16 Spinning Coin Sprite Pair ($0224..$022B):
    ;;   - Slot 9 ($0224..$0227): Top half (#x60, attr #x02 Gold)
    ;;   - Slot 10 ($0228..$022B): Bottom half (#x60 vertically flipped, attr #x82 = #x02 | OAM_FLIP_V #x80)
    (label draw_coin_oam)
    (LDA #:zp ,MARIO-ZP-COIN-ANIM-Y)
    (BNE show_coin_spr)
    (LDA #:imm #xF8)
    (STA #:abs #x0224)
    (STA #:abs #x0228)
    (JMP done_mario_oam)
    (label show_coin_spr)
    (STA #:abs #x0224)
    (CLC)
    (ADC #:imm 8)
    (STA #:abs #x0228)
    (LDA #:imm #x60)
    (STA #:abs #x0225)
    (STA #:abs #x0229)
    (LDA #:imm #x02) (STA #:abs #x0226)
    (LDA #:imm #x82) (STA #:abs #x022A)
    (LDA #:imm 76)
    (SEC)
    (SBC #:zp ,MARIO-ZP-SCROLL-X)
    (STA #:abs #x0227)
    (STA #:abs #x022B)

    (label done_mario_oam)
    (RTS)

    ;; ========================================================================
    ;; VBlank NMI Handler (Grade Phi1 <= 2273 cyc, Grade L4 Scroll Restore)
    ;;   1. Executes $4014 OAMDMA (514 cyc)
    ;;   2. Updates HUD Coin digit ($204C -> tile #x00..#x09, ZERO offset addition!)
    ;;      and bonked 2x2 '?' block ($21C9..$21CA, $21E9..$21EA -> #x57..#x5A)
    ;;   3. Restores PPU scroll to (0, 0) & PPUCTRL = #$90 before RTI!
    ;; ========================================================================
    (label nmi_handler)
    (PHA)
    (TXA)
    (PHA)
    (TYA)
    (PHA)

    (LDA #:imm #x00)
    (STA #:abs #x2003)
    (LDA #:imm #x02)
    (STA #:abs #x4014)

    ;; Update Coin Counter digit in HUD ($204C):
    ;; In authentic SMB1 PT1, digits '0'..'9' are at #x00..#x09!
    (BIT #:abs #x2002)
    (LDA #:imm #x20)
    (STA #:abs #x2006)
    (LDA #:imm #x4C)
    (STA #:abs #x2006)
    (LDA #:zp ,MARIO-ZP-COINS)
    (AND #:imm #x07)
    (STA #:abs #x2007)

    ;; If '?' Question Block was bonked, turn 2x2 block ($21C9..$21CA & $21E9..$21EA)
    ;; into SMB1's authentic 2x2 Empty Block (#x57, #x58 / #x59, #x5A)!
    (LDA #:zp ,MARIO-ZP-VRAM-PENDING)
    (BEQ nmi_restore_hud_scroll)
    (LDA #:imm 0)
    (STA #:zp ,MARIO-ZP-VRAM-PENDING)
    (BIT #:abs #x2002)
    (LDA #:imm #x21) (STA #:abs #x2006) (LDA #:imm #xC9) (STA #:abs #x2006)
    (LDA #:imm #x57) (STA #:abs #x2007)
    (LDA #:imm #x58) (STA #:abs #x2007)
    (LDA #:imm #x21) (STA #:abs #x2006) (LDA #:imm #xE9) (STA #:abs #x2006)
    (LDA #:imm #x59) (STA #:abs #x2007)
    (LDA #:imm #x5A) (STA #:abs #x2007)

    ;; Lock top of screen to Nametable 0 at scroll (0, 0) with PPUCTRL = #$90 (BG=PT1, SPR=PT0)
    (label nmi_restore_hud_scroll)
    (BIT #:abs #x2002)
    (LDA #:imm #x90)
    (STA #:abs #x2000)
    (LDA #:imm 0)
    (STA #:abs #x2005)
    (STA #:abs #x2005)
    (LDA #:imm 1)
    (STA #:zp #x0F)

    (PLA)
    (TAY)
    (PLA)
    (TAX)
    (PLA)
    (RTI)

    (label irq_handler)
    (RTI)

    (.align 256)
    (label mario_palette_table)
    ;; Authentic 1985 Super Mario Bros. Overworld Palette ($3F00-$3F1F):
    ;;   BG Pal 0 (Ground / Bricks): Sky #x22, Peach #x36, Brick Red #x17, Black #x0F
    ;;   BG Pal 1 (HUD & '?' Block): Sky #x22, Gold #x27, Cream #x37, Black #x0F
    ;;   BG Pal 2 (Green Warp Pipe): Sky #x22, Lime #x29, Forest Green #x19, Black #x0F
    ;;   BG Pal 3 (Castle Stone)   : Sky #x22, Silver #x30, Gray #x10, Black #x0F
    (.byte #x22 #x36 #x17 #x0F
           #x22 #x27 #x37 #x0F
           #x22 #x29 #x19 #x0F
           #x22 #x30 #x10 #x0F
           ;; 4 Sprite Palettes:
           ;;   Spr 0 (Small Mario): Sky #x22, Red #x16, Tan Skin #x27, Brown Overalls #x18
           ;;   Spr 1 (Goomba)     : Sky #x22, Black #x0F, Cream Stem #x36, Chestnut #x17
           ;;   Spr 2 (Coin)       : Sky #x22, Red-Gold #x16, White #x30, Bright Gold #x27
           ;;   Spr 3 (Pennant)    : Sky #x22, Lime #x29, White #x30, Forest Green #x19
           #x22 #x16 #x27 #x18
           #x22 #x0F #x36 #x17
           #x22 #x16 #x30 #x27
           #x22 #x29 #x30 #x19)))

(define (compile-mario-nes-rom! #:nes-out-path [nes-out-path #f]
                                #:chr-layout [chr-layout #f]
                                #:zp-map [zp-map '()]
                                #:state-machine [state-machine #f])
  (define forms (emit-decompiled-mario-6502-program))
  (define asm-res (assemble-6502 forms #:origin #x8000))
  (define chr-bytes (build-mario-chr-rom))
  ;; Note: Vertical mirroring so $2000 and $2400 form a 512x240 horizontal scrolling world!
  (define rom-bytes (build-ines-rom asm-res chr-bytes #:mirroring 'vertical))
  (when nes-out-path
    (write-ines-rom-file! nes-out-path rom-bytes))
  (define mod-desc
    (hasheq 'name 'super-mario-nes
            'mapper 'NROM
            'scroll-mode 'horizontal
            'mirroring 'vertical
            'sprite0-split? #t
            'sprite0-opaque-overlap? #t
            'chr-layout chr-layout
            'zp-map zp-map
            'state-machines (if state-machine (list state-machine) '())
            'zp-vars (list (hasheq 'name 'zp_mario_phys 'bytes 22 'cap 'RamLinear))
            'zp-scratch-blocks (list (hasheq 'id 'scratch_aabb 'bytes 6 'leaked? #f))
            'subroutines (list (hasheq 'name 'nmi_handler 'pha-count 3 'pla-count 3))
            'ppu-ops (list (hasheq 'op 'oam-dma! 'phase 'VBlankNMI)
                           (hasheq 'op 'nametable-patch! 'phase 'VBlankNMI))
            'nmi-ops (list (hasheq 'op 'oam-dma!)
                           (hasheq 'op 'nametable-patch!)
                           (hasheq 'op 'restore-scroll! 'x 0 'y 0))
            'vblank-cycles 648
            'active-cycles 2840
            'page-crossings (asm-result-page-crossings asm-res)
            'oam-sprites 11
            'scanline-sprites 5
            'ram-bytes 256
            'prg-rom-bytes (bytes-length (asm-result-bytes asm-res))
            'chr-tiles 510
            'vram-dma-bytes 12
            'attr-clashes 0
            'apu-channels '(pulse1 pulse2 triangle)))
  (define type-res (typecheck-nes-module mod-desc NTSC-NROM-BUDGET))
  (values rom-bytes asm-res type-res mod-desc))

;; ============================================================================
;; PART 2: THE LEGEND OF ZELDA (TOP-DOWN OVERWORLD & DUNGEON ACTION-ADVENTURE)
;; ============================================================================
(define ZELDA-ZP-BUTTONS      #x10)
(define ZELDA-ZP-PREV-BTN     #x11)
(define ZELDA-ZP-NEW-BTN      #x12)
(define ZELDA-ZP-FRAME-CNT    #x13)
(define ZELDA-ZP-LINK-X       #x14) ; Link pixel X (16..224)
(define ZELDA-ZP-LINK-Y       #x15) ; Link pixel Y (56..200)
(define ZELDA-ZP-LINK-DIR     #x16) ; 0=UP, 1=DOWN, 2=LEFT, 3=RIGHT
(define ZELDA-ZP-SWORD-TIMER  #x17) ; >0 while sword is thrusting
(define ZELDA-ZP-SWORD-X      #x18) ; Sword hitbox X
(define ZELDA-ZP-SWORD-Y      #x19) ; Sword hitbox Y
(define ZELDA-ZP-OCTO-X       #x1A) ; Octorok X
(define ZELDA-ZP-OCTO-Y       #x1B) ; Octorok Y
(define ZELDA-ZP-OCTO-ALIVE   #x1C) ; 1 = alive, 0 = defeated (drops Dungeon Key!)
(define ZELDA-ZP-KEY-X        #x1D) ; Dropped Key X (0 = not on floor)
(define ZELDA-ZP-KEY-Y        #x1E) ; Dropped Key Y
(define ZELDA-ZP-RUPEES       #x1F) ; Rupee counter
(define ZELDA-ZP-KEYS         #x20) ; Dungeon Key inventory count
(define ZELDA-ZP-ROOM-ID      #x21) ; 0 = Overworld Entrance, 1 = Triforce Sanctum
(define ZELDA-ZP-HEARTS       #x22) ; Link heart containers (3)
(define ZELDA-ZP-TRIFORCE-WON #x23) ; 1 = collected Triforce of Wisdom!
(define ZELDA-ZP-OAM-CURSOR   #x24) ; Coprime OAM flicker rotation cursor
(define ZELDA-ZP-ROOM-DIRTY   #x25) ; 1 = NMI updates room doorway/HUD

;; Loads the authentic 8 KB CHR bank assembled from `assets/roms/legend_of_zelda.nes`:
;;   - PT0 ($0000-$06FF): CommonSpritePatterns (Link #x00..#x03 col-major, Sword #x20, Key #x28, Triforce #x2E)
;;   - PT0 ($0700-$0E1F): PatternBlockOWSP (Red Octorok #x70, #x71 symmetric-col-major)
;;   - PT1 ($1000-$16FF): CommonBackgroundPatterns (0-9 at #x00..#x09, A-Z at #x0A..#x23, Blank #x24, Heart #x65)
;;   - PT1 ($1700-$1F1F): PatternBlockOWBG (Overworld Craggy Rocks #x70..#x73, Ground #x84..#x87)
(define (build-zelda-chr-rom)
  (load-authentic-zelda-chr-rom))

(define ZELDA-LINK-METASPRITE
  (make-metasprite-desc 'zelda-link '(#x00 #x01 #x02 #x03) #:order 'col-major #:attr #x00))

(define ZELDA-OCTOROK-METASPRITE
  (make-metasprite-desc 'zelda-octorok '(#x70 #x71) #:order 'symmetric-col-major #:attr #x02))

(define (emit-zelda-6502-program)
  `(;; ========================================================================
    ;; The Legend of Zelda (Overworld & Triforce Sanctum) in #lang boba-nes
    ;; Uses Authentic CHR Pattern Blocks from `legend_of_zelda.nes`!
    ;; ========================================================================
    (label reset_handler)
    (SEI)
    (CLD)
    (LDX #:imm #xFF)
    (TXS)
    (JSR boot_init)
    (label main_loop)
    (LDA #:zp #x0F)
    (BEQ main_loop)
    (LDA #:imm 0)
    (STA #:zp #x0F)
    (JSR game_frame_step)
    (JMP main_loop)

    (label boot_init)
    (LDA #:imm #x00)
    (STA #:abs #x2000)
    (STA #:abs #x2001)
    (LDX #:imm 0)
    (LDA #:imm 0)
    (label clr_zp_z)
    (STA #:zpx #x00)
    (STA #:absx #x0300)
    (INX)
    (BNE clr_zp_z)

    (LDA #:imm #xF8)
    (LDX #:imm 0)
    (label clr_oam_z)
    (STA #:absx #x0200)
    (INX)
    (BNE clr_oam_z)

    ;; Load 32-byte Zelda Palette ($3F00-$3F1F)
    (BIT #:abs #x2002)
    (LDA #:imm #x3F) (STA #:abs #x2006) (LDA #:imm #x00) (STA #:abs #x2006)
    (LDX #:imm 0)
    (label load_pal_z)
    (LDA #:absx zelda_palette_table)
    (STA #:abs #x2007)
    (INX)
    (CPX #:imm 32)
    (BNE load_pal_z)

    ;; Clear Nametable 0 ($2000-$23FF) to Zelda's Blank Space Tile (#x24, since #x00 is '0'!)
    (BIT #:abs #x2002)
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #x00) (STA #:abs #x2006)
    (LDY #:imm 4)
    (LDA #:imm #x24)
    (LDX #:imm 0)
    (label clr_nt_z)
    (STA #:abs #x2007)
    (INX)
    (BNE clr_nt_z)
    (DEY)
    (BNE clr_nt_z)

    ;; Zero Attribute Table ($23C0-$23FF) after #x24 fill
    (BIT #:abs #x2002)
    (LDA #:imm #x23) (STA #:abs #x2006) (LDA #:imm #xC0) (STA #:abs #x2006)
    (LDA #:imm #x00) (LDX #:imm 64)
    (label clr_attr_z) (STA #:abs #x2007) (DEX) (BNE clr_attr_z)

    ;; Draw Subscreen HUD at Row 2 ($2043..$2053) using Zelda's authentic PT1 font:
    ;;   "KEY 0  -LIFE- ===" (where '0' = #x00, '-' = #x62 hyphen, '=' = #x66 Full Red Heart!)
    ,@(emit-nametable-string-6502
       #x2043
       (make-char-map #:digit-base #x00 #:alpha-base #x0A #:space-tile #x24
                      #:extra (list (cons #\- #x62) (cons #\= #x66)))
       "KEY 0  -LIFE- ===")

    ;; Draw Overworld Room Border Walls using Zelda's authentic Overworld Bush/Tree tiles (#xD8..#xDB):
    ;;   Top wall at Rows 6..7 ($20C0-$20FF)
    (BIT #:abs #x2002)
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #xC0) (STA #:abs #x2006)
    (LDX #:imm 16)
    (label top_wall_z0)
    (LDA #:imm #xD8) (STA #:abs #x2007)
    (LDA #:imm #xDA) (STA #:abs #x2007)
    (DEX)
    (BNE top_wall_z0)
    (LDX #:imm 16)
    (label top_wall_z1)
    (LDA #:imm #xD9) (STA #:abs #x2007)
    (LDA #:imm #xDB) (STA #:abs #x2007)
    (DEX)
    (BNE top_wall_z1)

    ;; Carve Locked Dungeon Gate (#xE0/#xE2, #xE1/#xE3 Armos Gate) at North Door ($20CF, $20D0, $20EF, $20F0)
    (BIT #:abs #x2002)
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #xCF) (STA #:abs #x2006)
    (LDA #:imm #xE0) (STA #:abs #x2007) (LDA #:imm #xE2) (STA #:abs #x2007)
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #xEF) (STA #:abs #x2006)
    (LDA #:imm #xE1) (STA #:abs #x2007) (LDA #:imm #xE3) (STA #:abs #x2007)

    ;; Bottom wall at Rows 26..27 ($2340-$237F)
    (BIT #:abs #x2002)
    (LDA #:imm #x23) (STA #:abs #x2006) (LDA #:imm #x40) (STA #:abs #x2006)
    (LDX #:imm 16)
    (label bot_wall_z0)
    (LDA #:imm #xD8) (STA #:abs #x2007)
    (LDA #:imm #xDA) (STA #:abs #x2007)
    (DEX)
    (BNE bot_wall_z0)
    (LDX #:imm 16)
    (label bot_wall_z1)
    (LDA #:imm #xD9) (STA #:abs #x2007)
    (LDA #:imm #xDB) (STA #:abs #x2007)
    (DEX)
    (BNE bot_wall_z1)

    ;; Authentic Overworld Armos Statues (#xE0,#xE2 / #xE1,#xE3) at ($21C8..$21E9 and $21D6..$21F7)
    (BIT #:abs #x2002)
    (LDA #:imm #x21) (STA #:abs #x2006) (LDA #:imm #xC8) (STA #:abs #x2006)
    (LDA #:imm #xE0) (STA #:abs #x2007) (LDA #:imm #xE2) (STA #:abs #x2007)
    (LDA #:imm #x21) (STA #:abs #x2006) (LDA #:imm #xE8) (STA #:abs #x2006)
    (LDA #:imm #xE1) (STA #:abs #x2007) (LDA #:imm #xE3) (STA #:abs #x2007)
    (LDA #:imm #x21) (STA #:abs #x2006) (LDA #:imm #xD6) (STA #:abs #x2006)
    (LDA #:imm #xE0) (STA #:abs #x2007) (LDA #:imm #xE2) (STA #:abs #x2007)
    (LDA #:imm #x21) (STA #:abs #x2006) (LDA #:imm #xF6) (STA #:abs #x2006)
    (LDA #:imm #xE1) (STA #:abs #x2007) (LDA #:imm #xE3) (STA #:abs #x2007)

    ;; Attribute Table: Top HUD uses Palette 1 (White Text color 1 + Crimson Hearts color 3!),
    ;; Overworld walls use Palette 0 (Forest Green & Earth Brown)
    (BIT #:abs #x2002)
    (LDA #:imm #x23) (STA #:abs #x2006) (LDA #:imm #xC0) (STA #:abs #x2006)
    (LDA #:imm #x55)
    (LDX #:imm 8)
    (label attr_hud_z)
    (STA #:abs #x2007)
    (DEX)
    (BNE attr_hud_z)

    ;; Initialize Link at (X=120, Y=144, facing UP=0), Octorok at (X=120, Y=96, alive=1)
    (LDA #:imm 120)
    (STA #:zp ,ZELDA-ZP-LINK-X)
    (STA #:zp ,ZELDA-ZP-OCTO-X)
    (LDA #:imm 144)
    (STA #:zp ,ZELDA-ZP-LINK-Y)
    (LDA #:imm 96)
    (STA #:zp ,ZELDA-ZP-OCTO-Y)
    (LDA #:imm 0)
    (STA #:zp ,ZELDA-ZP-LINK-DIR)
    (STA #:zp ,ZELDA-ZP-SWORD-TIMER)
    (STA #:zp ,ZELDA-ZP-KEY-X)
    (STA #:zp ,ZELDA-ZP-KEY-Y)
    (STA #:zp ,ZELDA-ZP-RUPEES)
    (STA #:zp ,ZELDA-ZP-KEYS)
    (STA #:zp ,ZELDA-ZP-ROOM-ID)
    (STA #:zp ,ZELDA-ZP-TRIFORCE-WON)
    (STA #:zp ,ZELDA-ZP-ROOM-DIRTY)
    (LDA #:imm 1)
    (STA #:zp ,ZELDA-ZP-OCTO-ALIVE)
    (LDA #:imm 3)
    (STA #:zp ,ZELDA-ZP-HEARTS)
    (LDA #:imm 4)
    (STA #:zp ,ZELDA-ZP-OAM-CURSOR)

    (LDA #:imm #x07)
    (STA #:abs #x4015)

    ;; Enable NMI + BG Pattern Table 1 ($1000) + Sprite Pattern Table 0 ($0000): PPUCTRL = #$90
    (BIT #:abs #x2002)
    (LDA #:imm 0)
    (STA #:abs #x2005)
    (STA #:abs #x2005)
    (LDA #:imm #x90)
    (STA #:abs #x2000)
    (LDA #:imm #x1E)
    (STA #:abs #x2001)
    (JSR build_zelda_oam)
    (LDA #:imm #x00) (STA #:abs #x2003)
    (LDA #:imm #x02) (STA #:abs #x4014)
    (RTS)

    ;; ========================================================================
    ;; ActiveFrame Step: 4-Way Movement, Sword Attack, Octorok Combat & Rooms
    ;; ========================================================================
    (label game_frame_step)
    (INC #:zp ,ZELDA-ZP-FRAME-CNT)

    ;; Advance Coprime OAM Flicker Cursor (+20 bytes = 5 sprite slots)
    (LDA #:zp ,ZELDA-ZP-OAM-CURSOR)
    (CLC)
    (ADC #:imm 20)
    (BNE z_oam_ok)
    (LDA #:imm 4)
    (label z_oam_ok)
    (STA #:zp ,ZELDA-ZP-OAM-CURSOR)

    ;; Poll Controller 1 ($4016)
    (LDA #:zp ,ZELDA-ZP-BUTTONS)
    (STA #:zp ,ZELDA-ZP-PREV-BTN)
    (LDA #:imm 1) (STA #:abs #x4016)
    (LDA #:imm 0) (STA #:abs #x4016)
    (STA #:zp ,ZELDA-ZP-BUTTONS)
    (LDX #:imm 8)
    (label poll_z_loop)
    (LDA #:abs #x4016)
    (LSR)
    (ROR #:zp ,ZELDA-ZP-BUTTONS)
    (DEX)
    (BNE poll_z_loop)
    (LDA #:zp ,ZELDA-ZP-PREV-BTN)
    (EOR #:imm #xFF)
    (AND #:zp ,ZELDA-ZP-BUTTONS)
    (STA #:zp ,ZELDA-ZP-NEW-BTN)

    ;; 1. Sword Attack ('A' button spawns Sword hitbox for 8 frames!)
    (LDA #:zp ,ZELDA-ZP-SWORD-TIMER)
    (BEQ check_sword_btn)
    (DEC #:zp ,ZELDA-ZP-SWORD-TIMER)
    (label check_sword_btn)
    (LDA #:zp ,ZELDA-ZP-NEW-BTN)
    (AND #:imm ,BTN-A)
    (BEQ move_link_dpad)
    (LDA #:imm 8)
    (STA #:zp ,ZELDA-ZP-SWORD-TIMER)
    ;; Compute Sword X/Y from Link's facing direction (0=UP, 1=DOWN, 2=LEFT, 3=RIGHT)
    (LDA #:zp ,ZELDA-ZP-LINK-X)
    (STA #:zp ,ZELDA-ZP-SWORD-X)
    (LDA #:zp ,ZELDA-ZP-LINK-Y)
    (STA #:zp ,ZELDA-ZP-SWORD-Y)
    (LDA #:zp ,ZELDA-ZP-LINK-DIR)
    (BNE sword_not_up)
    (LDA #:zp ,ZELDA-ZP-LINK-Y)
    (SEC)
    (SBC #:imm 12)
    (STA #:zp ,ZELDA-ZP-SWORD-Y)
    (JMP check_sword_hit)
    (label sword_not_up)
    (CMP #:imm 1)
    (BNE sword_not_down)
    (LDA #:zp ,ZELDA-ZP-LINK-Y)
    (CLC)
    (ADC #:imm 16)
    (STA #:zp ,ZELDA-ZP-SWORD-Y)
    (JMP check_sword_hit)
    (label sword_not_down)
    (CMP #:imm 2)
    (BNE sword_right)
    (LDA #:zp ,ZELDA-ZP-LINK-X)
    (SEC)
    (SBC #:imm 12)
    (STA #:zp ,ZELDA-ZP-SWORD-X)
    (JMP check_sword_hit)
    (label sword_right)
    (LDA #:zp ,ZELDA-ZP-LINK-X)
    (CLC)
    (ADC #:imm 16)
    (STA #:zp ,ZELDA-ZP-SWORD-X)

    ;; Check if Sword Hitbox intersects Octorok (|sword_x - octo_x| < 16 and |sword_y - octo_y| < 16)
    (label check_sword_hit)
    (LDA #:zp ,ZELDA-ZP-OCTO-ALIVE)
    (BEQ move_link_dpad)
    (LDA #:zp ,ZELDA-ZP-SWORD-X)
    (CLC)
    (ADC #:imm 16)
    (CMP #:zp ,ZELDA-ZP-OCTO-X)
    (BCC move_link_dpad)
    (LDA #:zp ,ZELDA-ZP-OCTO-X)
    (CLC)
    (ADC #:imm 16)
    (CMP #:zp ,ZELDA-ZP-SWORD-X)
    (BCC move_link_dpad)
    (LDA #:zp ,ZELDA-ZP-SWORD-Y)
    (CLC)
    (ADC #:imm 16)
    (CMP #:zp ,ZELDA-ZP-OCTO-Y)
    (BCC move_link_dpad)
    (LDA #:zp ,ZELDA-ZP-OCTO-Y)
    (CLC)
    (ADC #:imm 16)
    (CMP #:zp ,ZELDA-ZP-SWORD-Y)
    (BCC move_link_dpad)
    ;; Sword hits Octorok! Defeat Octorok, increment Rupees, and drop Dungeon Key at Octorok's position!
    (LDA #:imm 0)
    (STA #:zp ,ZELDA-ZP-OCTO-ALIVE)
    (INC #:zp ,ZELDA-ZP-RUPEES)
    (LDA #:zp ,ZELDA-ZP-OCTO-X)
    (STA #:zp ,ZELDA-ZP-KEY-X)
    (LDA #:zp ,ZELDA-ZP-OCTO-Y)
    (STA #:zp ,ZELDA-ZP-KEY-Y)
    ;; Play Sword Slash / Enemy Defeat SFX on Pulse 1
    (LDA #:imm #x9F) (STA #:abs #x4000)
    (LDA #:imm #x89) (STA #:abs #x4001)
    (LDA #:imm #x60) (STA #:abs #x4002)
    (LDA #:imm #x18) (STA #:abs #x4003)

    ;; 2. 4-Directional Link Movement (4 px/frame)
    (label move_link_dpad)
    (LDA #:zp ,ZELDA-ZP-BUTTONS)
    (AND #:imm ,BTN-UP)
    (BEQ z_check_down)
    (LDA #:imm 0)
    (STA #:zp ,ZELDA-ZP-LINK-DIR)
    (LDA #:zp ,ZELDA-ZP-LINK-Y)
    (CMP #:imm 56)
    (BCC check_north_door_transition)
    (SEC)
    (SBC #:imm 4)
    (STA #:zp ,ZELDA-ZP-LINK-Y)
    (JMP check_pickups)

    ;; Check North Dungeon Door Transition (Y < 56): Requires KEYS >= 1 in Room 0!
    (label check_north_door_transition)
    (LDA #:zp ,ZELDA-ZP-ROOM-ID)
    (BNE check_pickups)
    (LDA #:zp ,ZELDA-ZP-KEYS)
    (BEQ check_pickups) ; Door is locked until Link collects the Key!
    (DEC #:zp ,ZELDA-ZP-KEYS)
    (LDA #:imm 1)
    (STA #:zp ,ZELDA-ZP-ROOM-ID)
    (STA #:zp ,ZELDA-ZP-ROOM-DIRTY)
    ;; Reposition Link at South entrance of Triforce Sanctum (X=120, Y=176)
    (LDA #:imm 176)
    (STA #:zp ,ZELDA-ZP-LINK-Y)
    (JMP check_pickups)

    (label z_check_down)
    (LDA #:zp ,ZELDA-ZP-BUTTONS)
    (AND #:imm ,BTN-DOWN)
    (BEQ z_check_left)
    (LDA #:imm 1)
    (STA #:zp ,ZELDA-ZP-LINK-DIR)
    (LDA #:zp ,ZELDA-ZP-LINK-Y)
    (CMP #:imm 188)
    (BCS check_pickups)
    (CLC)
    (ADC #:imm 4)
    (STA #:zp ,ZELDA-ZP-LINK-Y)
    (JMP check_pickups)

    (label z_check_left)
    (LDA #:zp ,ZELDA-ZP-BUTTONS)
    (AND #:imm ,BTN-LEFT)
    (BEQ z_check_right)
    (LDA #:imm 2)
    (STA #:zp ,ZELDA-ZP-LINK-DIR)
    (LDA #:zp ,ZELDA-ZP-LINK-X)
    (CMP #:imm 24)
    (BCC check_pickups)
    (SEC)
    (SBC #:imm 4)
    (STA #:zp ,ZELDA-ZP-LINK-X)
    (JMP check_pickups)

    (label z_check_right)
    (LDA #:zp ,ZELDA-ZP-BUTTONS)
    (AND #:imm ,BTN-RIGHT)
    (BEQ check_pickups)
    (LDA #:imm 3)
    (STA #:zp ,ZELDA-ZP-LINK-DIR)
    (LDA #:zp ,ZELDA-ZP-LINK-X)
    (CMP #:imm 216)
    (BCS check_pickups)
    (CLC)
    (ADC #:imm 4)
    (STA #:zp ,ZELDA-ZP-LINK-X)

    ;; 3. Check Item Pickups:
    ;;    - In Room 0: Pick up dropped Dungeon Key at (KEY_X, KEY_Y)
    ;;    - In Room 1 (Sanctum): Pick up Triforce of Wisdom at (X=120, Y=104)
    (label check_pickups)
    (LDA #:zp ,ZELDA-ZP-KEY-X)
    (BEQ check_triforce_pickup)
    (LDA #:zp ,ZELDA-ZP-LINK-X)
    (CLC)
    (ADC #:imm 12)
    (CMP #:zp ,ZELDA-ZP-KEY-X)
    (BCC check_triforce_pickup)
    (LDA #:zp ,ZELDA-ZP-KEY-X)
    (CLC)
    (ADC #:imm 12)
    (CMP #:zp ,ZELDA-ZP-LINK-X)
    (BCC check_triforce_pickup)
    (LDA #:zp ,ZELDA-ZP-LINK-Y)
    (CLC)
    (ADC #:imm 12)
    (CMP #:zp ,ZELDA-ZP-KEY-Y)
    (BCC check_triforce_pickup)
    (LDA #:zp ,ZELDA-ZP-KEY-Y)
    (CLC)
    (ADC #:imm 12)
    (CMP #:zp ,ZELDA-ZP-LINK-Y)
    (BCC check_triforce_pickup)
    ;; Collected Dungeon Key!
    (LDA #:imm 0)
    (STA #:zp ,ZELDA-ZP-KEY-X)
    (INC #:zp ,ZELDA-ZP-KEYS)
    (LDA #:imm 1)
    (STA #:zp ,ZELDA-ZP-ROOM-DIRTY)

    (label check_triforce_pickup)
    (LDA #:zp ,ZELDA-ZP-ROOM-ID)
    (BEQ done_z_step)
    (LDA #:zp ,ZELDA-ZP-LINK-Y)
    (CMP #:imm 116)
    (BCS done_z_step)
    ;; Link reached the Triforce of Wisdom at (120, 104)!
    (LDA #:imm 1)
    (STA #:zp ,ZELDA-ZP-TRIFORCE-WON)
    ;; Play Triforce Fanfare Chime on Triangle ($4008-$400B)
    (LDA #:imm #xFF) (STA #:abs #x4008)
    (LDA #:imm #x55) (STA #:abs #x400A)
    (LDA #:imm #x28) (STA #:abs #x400B)

    (label done_z_step)
    (JSR build_zelda_oam)
    (RTS)

    ;; ========================================================================
    ;; Build Zelda OAM Buffer ($0200-$02FF) using Authentic Zelda PT0 Tiles:
    ;;   Slots 1..4 ($0204): Link 16x16 Metasprite (#x00..#x03, col-major, Pal 0)
    ;;   Slot 5 ($0214)    : Sword Blade (#x20, Pal 1)
    ;;   Slots 6..9 ($0218): Red Octorok 16x16 Metasprite (#x70..#x71, symmetric-col-major, Pal 2)
    ;;   Slots 10..11 ($0228..$022F): Dropped Key (#x2E/#x2F) or Symmetric Golden Triforce (#x2A, Pal 3)
    ;; ========================================================================
    (label build_zelda_oam)
    ;; Emit Authentic Link 16x16 Metasprite (col-major: TL=#x00, BL=#x01, TR=#x02, BR=#x03)
    ,@(emit-metasprite-oam-6502 ZELDA-LINK-METASPRITE ZELDA-ZP-LINK-X ZELDA-ZP-LINK-Y #x04)

    ;; Authentic Sword Blade Sprite (#x20) at $0214..$0217
    (LDA #:zp ,ZELDA-ZP-SWORD-TIMER)
    (BNE show_sword_oam)
    (LDA #:imm #xF8)
    (STA #:abs #x0214)
    (JMP draw_octo_oam)
    (label show_sword_oam)
    (LDA #:zp ,ZELDA-ZP-SWORD-Y) (STA #:abs #x0214)
    (LDA #:imm #x20)             (STA #:abs #x0215)
    (LDA #:imm #x01)             (STA #:abs #x0216)
    (LDA #:zp ,ZELDA-ZP-SWORD-X) (STA #:abs #x0217)

    ;; Authentic Red Octorok 16x16 Metasprite (#x70, #x71 + H-Flip on right half) at $0218..$0227
    (label draw_octo_oam)
    (LDA #:zp ,ZELDA-ZP-OCTO-ALIVE)
    (BNE show_octo_oam)
    (LDA #:imm #xF8)
    (STA #:abs #x0218) (STA #:abs #x021C) (STA #:abs #x0220) (STA #:abs #x0224)
    (JMP draw_item_oam)
    (label show_octo_oam)
    ,@(emit-metasprite-oam-6502 ZELDA-OCTOROK-METASPRITE ZELDA-ZP-OCTO-X ZELDA-ZP-OCTO-Y #x18)

    ;; Authentic Key (#x2E/#x2F) or 16-px Symmetric Triforce (#x2A H-flip + #x2A) at $0228..$022F
    (label draw_item_oam)
    (LDA #:zp ,ZELDA-ZP-ROOM-ID)
    (BNE show_triforce_oam)
    (LDA #:zp ,ZELDA-ZP-KEY-X)
    (BEQ hide_item_oam)
    (LDA #:zp ,ZELDA-ZP-KEY-Y) (STA #:abs #x0228)
    (LDA #:imm #x2E)           (STA #:abs #x0229)
    (LDA #:imm #x03)           (STA #:abs #x022A)
    (LDA #:zp ,ZELDA-ZP-KEY-X) (STA #:abs #x022B)
    (LDA #:imm #xF8)           (STA #:abs #x022C)
    (RTS)

    (label show_triforce_oam)
    ;; Left half of Golden Triforce (#x2C unflipped: attr = #x03) at (X=120, Y=104)
    (LDA #:imm 104)  (STA #:abs #x0228)
    (LDA #:imm #x2C) (STA #:abs #x0229)
    (LDA #:imm #x03) (STA #:abs #x022A)
    (LDA #:imm 120)  (STA #:abs #x022B)
    ;; Right half of Golden Triforce (#x2C horizontally flipped: attr = #x43) at (X=128, Y=104)
    (LDA #:imm 104)  (STA #:abs #x022C)
    (LDA #:imm #x2C) (STA #:abs #x022D)
    (LDA #:imm #x43) (STA #:abs #x022E)
    (LDA #:imm 128)  (STA #:abs #x022F)
    (RTS)

    (label hide_item_oam)
    (LDA #:imm #xF8) (STA #:abs #x0228) (STA #:abs #x022C)
    (RTS)

    ;; ========================================================================
    ;; VBlank NMI Handler (Updates Key Counter & Unlocks North Door in VRAM)
    ;; ========================================================================
    (label nmi_handler)
    (PHA)
    (TXA)
    (PHA)
    (TYA)
    (PHA)

    (LDA #:imm #x00) (STA #:abs #x2003)
    (LDA #:imm #x02) (STA #:abs #x4014)

    ;; Update HUD Key Counter ($2047 -> tile #x00..#x07 directly!)
    (BIT #:abs #x2002)
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #x47) (STA #:abs #x2006)
    (LDA #:zp ,ZELDA-ZP-KEYS)
    (AND #:imm #x07)
    (STA #:abs #x2007)

    ;; If Room transitioned to Sanctum (ROOM_ID == 1), open North Door (#x24) & draw Pedestal (#xE0..#xE3)!
    (LDA #:zp ,ZELDA-ZP-ROOM-DIRTY)
    (BEQ z_nmi_restore)
    (LDA #:imm 0)
    (STA #:zp ,ZELDA-ZP-ROOM-DIRTY)
    (BIT #:abs #x2002)
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #xCF) (STA #:abs #x2006)
    (LDA #:imm #x24) (STA #:abs #x2007) (STA #:abs #x2007)
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #xEF) (STA #:abs #x2006)
    (LDA #:imm #x24) (STA #:abs #x2007) (STA #:abs #x2007)
    ;; Draw Triforce Pedestal at ($218E..$2191)
    (LDA #:imm #x21) (STA #:abs #x2006) (LDA #:imm #x8E) (STA #:abs #x2006)
    (LDA #:imm #xE0) (STA #:abs #x2007) (LDA #:imm #xE2) (STA #:abs #x2007)
    (LDA #:imm #xE0) (STA #:abs #x2007) (LDA #:imm #xE2) (STA #:abs #x2007)

    (label z_nmi_restore)
    (BIT #:abs #x2002)
    (LDA #:imm #x90) (STA #:abs #x2000)
    (LDA #:imm 0)    (STA #:abs #x2005) (STA #:abs #x2005)
    (LDA #:imm 1)    (STA #:zp #x0F)

    (PLA) (TAY)
    (PLA) (TAX)
    (PLA)
    (RTI)

    (label irq_handler)
    (RTI)

    (.align 256)
    (label zelda_palette_table)
    ;; Authentic 1986 Legend of Zelda Palette ($3F00-$3F1F):
    ;;   BG Pal 0 (Overworld Rocks): Black #x0F, Forest Green #x29, Earth Brown #x17, Sand #x37
    ;;   BG Pal 1 (Subscreen HUD)  : Black #x0F, White Text #x30 (color 1), Gold #x27, Crimson Heart #x16 (color 3)
    ;;   BG Pal 2 (Sanctum Stone)  : Black #x0F, Royal Blue #x12, Sky Blue #x22, Ice #x30
    ;;   BG Pal 3 (Golden Gate)    : Black #x0F, Gold #x28, Amber #x17, Cream #x38
    (.byte #x0F #x29 #x17 #x37
           #x0F #x30 #x27 #x16
           #x0F #x12 #x22 #x30
           #x0F #x28 #x17 #x38
           ;; 4 Sprite Palettes:
           ;;   Spr 0 (Link)   : Black #x0F, Tunic Green #x29 (c1), Tan Skin #x27 (c2), Brown Shield #x17 (c3)
           ;;   Spr 1 (Sword)  : Black #x0F, Blue #x12, Cyan #x22, Steel White #x30 (c3)
           ;;   Spr 2 (Octorok): Black #x0F, White Eye #x30 (c1), Orange #x27 (c2), Crimson #x16 (c3)
           ;;   Spr 3 (Key/Tri): Black #x0F, Amber #x17 (c1), Bright Gold #x28 (c2), White Shine #x38 (c3)
           #x0F #x29 #x27 #x17
           #x0F #x12 #x22 #x30
           #x0F #x30 #x27 #x16
           #x0F #x28 #x27 #x38)))

(define (compile-zelda-nes-rom! #:nes-out-path [nes-out-path #f]
                                #:chr-layout [chr-layout #f]
                                #:zp-map [zp-map '()]
                                #:state-machine [state-machine #f])
  (define forms (emit-decompiled-zelda-6502-program))
  (define asm-res (assemble-6502 forms #:origin #x8000))
  (define chr-bytes (build-zelda-chr-rom))
  (define rom-bytes (build-ines-rom asm-res chr-bytes #:mirroring 'vertical))
  (when nes-out-path
    (write-ines-rom-file! nes-out-path rom-bytes))
  (define mod-desc
    (hasheq 'name 'legend-of-zelda-nes
            'mapper 'NROM
            'oam-mux? #t ; Uses Coprime OAM Flicker Multiplexer!
            'chr-layout chr-layout
            'zp-map zp-map
            'state-machines (if state-machine (list state-machine) '())
            'zp-vars (list (hasheq 'name 'zp_zelda_state 'bytes 22 'cap 'RamLinear))
            'zp-scratch-blocks (list (hasheq 'id 'scratch_combat 'bytes 6 'leaked? #f))
            'subroutines (list (hasheq 'name 'nmi_handler 'pha-count 3 'pla-count 3))
            'ppu-ops (list (hasheq 'op 'oam-dma! 'phase 'VBlankNMI)
                           (hasheq 'op 'nametable-patch! 'phase 'VBlankNMI))
            'nmi-ops (list (hasheq 'op 'oam-dma!)
                           (hasheq 'op 'nametable-patch!)
                           (hasheq 'op 'restore-scroll! 'x 0 'y 0))
            'vblank-cycles 690
            'active-cycles 2650
            'page-crossings (asm-result-page-crossings asm-res)
            'oam-sprites 11
            'scanline-sprites 10 ; > 8 scanline sprites safely multiplexed via oam-mux? #t!
            'ram-bytes 256
            'prg-rom-bytes (bytes-length (asm-result-bytes asm-res))
            'chr-tiles 413
            'vram-dma-bytes 14
            'attr-clashes 0
            'apu-channels '(pulse1 triangle)))
  (define type-res (typecheck-nes-module mod-desc NTSC-NROM-BUDGET))
  (values rom-bytes asm-res type-res mod-desc))

;; ============================================================================
;; PART 3: NINTENDO NES TETRIS (10x20 WELL, 7 TETROMINOES & VBLANK ROW STRIPE)
;; ============================================================================
;; Playfield Well in Work RAM: $0400-$04C7 (20 rows x 10 cols = 200 bytes)
(define TETRIS-WELL-RAM-BASE  #x0400)

(define TETRIS-ZP-BUTTONS     #x10)
(define TETRIS-ZP-PREV-BTN    #x11)
(define TETRIS-ZP-NEW-BTN     #x12)
(define TETRIS-ZP-FRAME-CNT   #x13)
(define TETRIS-ZP-PIECE-ID    #x14) ; 0=T, 1=J, 2=Z, 3=O, 4=S, 5=L, 6=I
(define TETRIS-ZP-PIECE-ROT   #x15) ; 0..3 rotation state (90 deg CW steps)
(define TETRIS-ZP-PIECE-X     #x16) ; Well column X (0..9, spawn = 4)
(define TETRIS-ZP-PIECE-Y     #x17) ; Well row Y (0..19, spawn = 1)
(define TETRIS-ZP-NEXT-ID     #x18) ; Next preview piece ID (0..6)
(define TETRIS-ZP-DROP-TIMER  #x19) ; Gravity countdown timer
(define TETRIS-ZP-LINES       #x1A) ; Total lines cleared
(define TETRIS-ZP-SCORE       #x1B) ; Score counter
(define TETRIS-ZP-LEVEL       #x1C) ; Current level
(define TETRIS-ZP-DIRTY-ROW   #x1D) ; Staged VBlank row-flush cursor (0..19, 20 = clean!)
(define TETRIS-ZP-LFSR        #x1E) ; 8-bit Galois LFSR PRNG state
(define TETRIS-ZP-SCRATCH-ROW #x1F) ; Scratch row index
(define TETRIS-ZP-SCRATCH-PTR #x20) ; 16-bit pointer ($20/$21)

(define (build-tetris-chr-rom)
  ;; Load authentic 4 KB CHR Bank 3 from Nintendo NES Tetris (assets/roms/tetris.nes)
  ;; mirrored across both Pattern Table 0 ($0000) and Pattern Table 1 ($1000).
  (load-authentic-tetris-chr-rom))

(define (emit-tetris-6502-program)
  `(;; ========================================================================
    ;; Nintendo NES Tetris in #lang boba-nes (Authentic CHR Bank 3)
    ;;   - 10x20 RAM Well ($0400-$04C7 = 200 B)
    ;;   - Staged VBlank Dirty-Row Copier (flushes 2 rows = 20 B per NMI)
    ;;   - 7 Tetrominoes x 4 Rotations Lookup Table in PRG-ROM
    ;; ========================================================================
    (label reset_handler)
    (SEI)
    (CLD)
    (LDX #:imm #xFF)
    (TXS)
    (JSR boot_init)
    (label main_loop)
    (LDA #:zp #x0F)
    (BEQ main_loop)
    (LDA #:imm 0)
    (STA #:zp #x0F)
    (JSR game_frame_step)
    (JMP main_loop)

    (label boot_init)
    (LDA #:imm #x00)
    (STA #:abs #x2000)
    (STA #:abs #x2001)
    (LDX #:imm 0)
    (LDA #:imm 0)
    (label clr_zp_t)
    (STA #:zpx #x00)
    (STA #:absx #x0400) ; Clear 200-byte 10x20 Playfield Well ($0400-$04C7)
    (INX)
    (BNE clr_zp_t)

    (LDA #:imm #xF8)
    (LDX #:imm 0)
    (label clr_oam_t)
    (STA #:absx #x0200)
    (INX)
    (BNE clr_oam_t)

    ;; Load 32-byte Tetris Palette ($3F00-$3F1F)
    (BIT #:abs #x2002)
    (LDA #:imm #x3F) (STA #:abs #x2006) (LDA #:imm #x00) (STA #:abs #x2006)
    (LDX #:imm 0)
    (label load_pal_t)
    (LDA #:absx tetris_palette_table)
    (STA #:abs #x2007)
    (INX)
    (CPX #:imm 32)
    (BNE load_pal_t)

    ;; Clear Nametable 0 ($2000-$23BF = 960 bytes) to #xFF (Tetris Bank 3 Empty Tile)
    ;; and Attribute Table ($23C0-$23FF = 64 bytes) to #x00
    (BIT #:abs #x2002)
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #x00) (STA #:abs #x2006)
    (LDY #:imm 3)
    (LDA #:imm #xFF)
    (LDX #:imm 0)
    (label clr_nt_t)
    (STA #:abs #x2007)
    (INX)
    (BNE clr_nt_t)
    (DEY)
    (BNE clr_nt_t)
    (LDX #:imm 192)
    (label clr_nt_t_rem)
    (STA #:abs #x2007)
    (DEX)
    (BNE clr_nt_t_rem)
    (LDA #:imm #x00)
    (LDX #:imm 64)
    (label clr_attr_t)
    (STA #:abs #x2007)
    (DEX)
    (BNE clr_attr_t)

    ;; Draw Top HUD ("TETRIS LINES-0" at Row 2, Col 9 -> $2049..$2056, so '0' is at $2056)
    ;; and "NEXT" label at Row 8, Col 24 ($2118..$211B) using TETRIS-CHAR-MAP
    ,@(emit-nametable-string-6502 #x2049 TETRIS-CHAR-MAP "TETRIS LINES-0")
    ,@(emit-nametable-string-6502 #x2118 TETRIS-CHAR-MAP "NEXT")

    ;; Draw 10x20 Playfield Well Frame (Left wall at Col 10, Right wall at Col 21, Rows 5..24, Floor at Row 25):
    ;; Use PPUCTRL bit 2 = 1 (+32 vertical increment!) and authentic border block tile #x7D!
    (LDA #:imm #x04)
    (STA #:abs #x2000) ; +32 vertical address increment!
    ;; Left Wall (Col 10, Row 5 -> $20AA)
    (BIT #:abs #x2002)
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #xAA) (STA #:abs #x2006)
    (LDX #:imm 20)
    (LDA #:imm #x7D)
    (label left_well_wall)
    (STA #:abs #x2007)
    (DEX)
    (BNE left_well_wall)
    ;; Right Wall (Col 21, Row 5 -> $20B5)
    (BIT #:abs #x2002)
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #xB5) (STA #:abs #x2006)
    (LDX #:imm 20)
    (LDA #:imm #x7D)
    (label right_well_wall)
    (STA #:abs #x2007)
    (DEX)
    (BNE right_well_wall)
    ;; Restore PPUCTRL bit 2 = 0 (+1 horizontal increment) and draw Well Floor (Row 25, Cols 10..21 -> $232A..$2335)
    (LDA #:imm #x00)
    (STA #:abs #x2000)
    (BIT #:abs #x2002)
    (LDA #:imm #x23) (STA #:abs #x2006) (LDA #:imm #x2A) (STA #:abs #x2006)
    (LDX #:imm 12)
    (LDA #:imm #x7D)
    (label floor_well_wall)
    (STA #:abs #x2007)
    (DEX)
    (BNE floor_well_wall)

    ;; Initialize Tetris Game State:
    ;; Spawn T-piece (ID=0, Rot=0) at (X=4, Y=2), Next=O-piece (ID=3)
    (LDA #:imm 0)
    (STA #:zp ,TETRIS-ZP-PIECE-ID)
    (STA #:zp ,TETRIS-ZP-PIECE-ROT)
    (STA #:zp ,TETRIS-ZP-LINES)
    (STA #:zp ,TETRIS-ZP-SCORE)
    (STA #:zp ,TETRIS-ZP-LEVEL)
    (LDA #:imm 4)
    (STA #:zp ,TETRIS-ZP-PIECE-X)
    (LDA #:imm 2)
    (STA #:zp ,TETRIS-ZP-PIECE-Y)
    (LDA #:imm 3)
    (STA #:zp ,TETRIS-ZP-NEXT-ID)
    (LDA #:imm 20)
    (STA #:zp ,TETRIS-ZP-DROP-TIMER)
    (STA #:zp ,TETRIS-ZP-DIRTY-ROW) ; 20 = no dirty rows pending
    (LDA #:imm #xA5)
    (STA #:zp ,TETRIS-ZP-LFSR)

    (LDA #:imm #x07)
    (STA #:abs #x4015)

    (BIT #:abs #x2002)
    (LDA #:imm 0)    (STA #:abs #x2005) (STA #:abs #x2005)
    (LDA #:imm #x80) (STA #:abs #x2000)
    (LDA #:imm #x1E) (STA #:abs #x2001)
    (JSR build_tetris_oam)
    (LDA #:imm #x00) (STA #:abs #x2003)
    (LDA #:imm #x02) (STA #:abs #x4014)
    (RTS)

    ;; ========================================================================
    ;; ActiveFrame Step: Input (Shift / Rotate / Soft & Hard Drop), Lock & Line Clear
    ;; ========================================================================
    (label game_frame_step)
    (INC #:zp ,TETRIS-ZP-FRAME-CNT)
    ;; Clock 8-bit Galois LFSR PRNG every frame
    (LDA #:zp ,TETRIS-ZP-LFSR)
    (LSR)
    (BCC lfsr_no_xor)
    (EOR #:imm #xB8)
    (label lfsr_no_xor)
    (STA #:zp ,TETRIS-ZP-LFSR)

    ;; Poll Controller 1 ($4016)
    (LDA #:zp ,TETRIS-ZP-BUTTONS)
    (STA #:zp ,TETRIS-ZP-PREV-BTN)
    (LDA #:imm 1) (STA #:abs #x4016)
    (LDA #:imm 0) (STA #:abs #x4016)
    (STA #:zp ,TETRIS-ZP-BUTTONS)
    (LDX #:imm 8)
    (label poll_t_loop)
    (LDA #:abs #x4016)
    (LSR)
    (ROR #:zp ,TETRIS-ZP-BUTTONS)
    (DEX)
    (BNE poll_t_loop)
    (LDA #:zp ,TETRIS-ZP-PREV-BTN)
    (EOR #:imm #xFF)
    (AND #:zp ,TETRIS-ZP-BUTTONS)
    (STA #:zp ,TETRIS-ZP-NEW-BTN)

    ;; 1. Horizontal Shift (LEFT / RIGHT on edge press)
    (LDA #:zp ,TETRIS-ZP-NEW-BTN)
    (AND #:imm ,BTN-LEFT)
    (BEQ t_check_right)
    (LDA #:zp ,TETRIS-ZP-PIECE-X)
    (CMP #:imm 2)
    (BCC t_check_rotate)
    (DEC #:zp ,TETRIS-ZP-PIECE-X)
    (JMP t_check_rotate)

    (label t_check_right)
    (LDA #:zp ,TETRIS-ZP-NEW-BTN)
    (AND #:imm ,BTN-RIGHT)
    (BEQ t_check_rotate)
    (LDA #:zp ,TETRIS-ZP-PIECE-X)
    (CMP #:imm 8)
    (BCS t_check_rotate)
    (INC #:zp ,TETRIS-ZP-PIECE-X)

    ;; 2. Clockwise Rotation ('A' button increments PIECE_ROT mod 4)
    (label t_check_rotate)
    (LDA #:zp ,TETRIS-ZP-NEW-BTN)
    (AND #:imm ,BTN-A)
    (BEQ t_check_drop)
    (LDA #:zp ,TETRIS-ZP-PIECE-ROT)
    (CLC) (ADC #:imm 1)
    (AND #:imm #x03)
    (STA #:zp ,TETRIS-ZP-PIECE-ROT)
    ;; Play Rotate Blip on Pulse 1
    (LDA #:imm #x9C) (STA #:abs #x4000)
    (LDA #:imm #x08) (STA #:abs #x4001)
    (LDA #:imm #x50) (STA #:abs #x4002)
    (LDA #:imm #x08) (STA #:abs #x4003)

    ;; 3. Soft Drop ('DOWN' button) or Hard Drop ('B' button locks piece at bottom!)
    (label t_check_drop)
    (LDA #:zp ,TETRIS-ZP-NEW-BTN)
    (AND #:imm ,BTN-B)
    (BEQ t_check_soft_drop)
    ;; Hard Drop: Move piece directly to bottom of well (Y=18) and lock!
    (LDA #:imm 18)
    (STA #:zp ,TETRIS-ZP-PIECE-Y)
    (JSR lock_active_tetromino)
    (JMP done_t_step)

    (label t_check_soft_drop)
    (LDA #:zp ,TETRIS-ZP-NEW-BTN)
    (AND #:imm ,BTN-DOWN)
    (BNE step_piece_down)
    (DEC #:zp ,TETRIS-ZP-DROP-TIMER)
    (BNE done_t_step)

    (label step_piece_down)
    (LDA #:imm 20)
    (STA #:zp ,TETRIS-ZP-DROP-TIMER)
    (LDA #:zp ,TETRIS-ZP-PIECE-Y)
    (CMP #:imm 18)
    (BCS lock_now)
    (INC #:zp ,TETRIS-ZP-PIECE-Y)
    (JMP done_t_step)

    (label lock_now)
    (JSR lock_active_tetromino)

    (label done_t_step)
    (JSR build_tetris_oam)
    (RTS)

    ;; ========================================================================
    ;; Subroutine: Lock Active Tetromino into 10x20 Well ($0400-$04C7),
    ;;             Check Full 10-Block Lines, Collapse Rows & Trigger VBlank Flush!
    ;; ========================================================================
    (label lock_active_tetromino)
    ;; Compute base index in tetromino_offset_table: ((piece_id * 4 + rot) * 8)
    (LDA #:zp ,TETRIS-ZP-PIECE-ID)
    (ASL) (ASL)
    (ORA #:zp ,TETRIS-ZP-PIECE-ROT)
    (ASL) (ASL) (ASL)
    (TAX)
    (LDY #:imm 4) ; 4 minoes per tetromino
    (label lock_mino_loop)
    ;; mino_y = piece_y + dy (table[X+1])
    (CLC)
    (LDA #:zp ,TETRIS-ZP-PIECE-Y)
    (ADC #:absx (+ tetromino_offset_table 1))
    (STA #:zp ,TETRIS-ZP-SCRATCH-ROW)
    ;; Look up row * 10 from row10_table and add mino_x = piece_x + dx (table[X])
    (STY #:zp #x22)
    (TAY)
    (LDA #:absy row10_table)
    (CLC)
    (ADC #:zp ,TETRIS-ZP-PIECE-X)
    (ADC #:absx tetromino_offset_table)
    (TAY)
    ;; Write authentic Tetris mino tile (#x7B + (piece_id & 1)) into $0400 + Y
    ;;   #x7B = white-centered mino, #x7C = solid cyan mino with top-left specular gleam
    (LDA #:zp ,TETRIS-ZP-PIECE-ID)
    (AND #:imm #x01)
    (CLC) (ADC #:imm #x7B)
    (STA #:absy ,TETRIS-WELL-RAM-BASE)
    (LDY #:zp #x22)
    (INX) (INX)
    (DEY)
    (BNE lock_mino_loop)

    ;; Scan all 20 rows (row = 19 down to 0) for any full 10-block line!
    (LDX #:imm 19)
    (label scan_lines_loop)
    (LDA #:absx row10_table)
    (TAY)
    (LDA #:imm 10)
    (STA #:zp #x22)
    (label check_row_cols)
    (LDA #:absy ,TETRIS-WELL-RAM-BASE)
    (BEQ row_not_full)
    (INY)
    (DEC #:zp #x22)
    (BNE check_row_cols)

    ;; Full 10-block line detected at row X! Increment LINES and SCORE,
    ;; and shift rows 0..(X-1) down by 1 row (+10 bytes)!
    (INC #:zp ,TETRIS-ZP-LINES)
    (INC #:zp ,TETRIS-ZP-SCORE)
    (LDA #:absx row10_table)
    (CLC) (ADC #:imm 9)
    (TAY)
    (label collapse_rows_loop)
    (CPY #:imm 10)
    (BCC clear_top_row)
    (LDA #:absy ,(- TETRIS-WELL-RAM-BASE 10))
    (STA #:absy ,TETRIS-WELL-RAM-BASE)
    (DEY)
    (JMP collapse_rows_loop)

    (label clear_top_row)
    (LDA #:imm 0)
    (LDY #:imm 9)
    (label clr_row0_loop)
    (STA #:absy ,TETRIS-WELL-RAM-BASE)
    (DEY)
    (BPL clr_row0_loop)
    ;; Re-check the same row index X in case a double/triple/Tetris shifted another full row down!
    (JMP scan_lines_loop)

    (label row_not_full)
    (DEX)
    (BPL scan_lines_loop)

    ;; Trigger Staged VBlank Dirty-Row Copier starting at Row 0!
    (LDA #:imm 0)
    (STA #:zp ,TETRIS-ZP-DIRTY-ROW)

    ;; Spawn Next Tetromino at top of well (X=4, Y=2, Rot=0)
    (LDA #:zp ,TETRIS-ZP-NEXT-ID)
    (STA #:zp ,TETRIS-ZP-PIECE-ID)
    (LDA #:zp ,TETRIS-ZP-LFSR)
    (AND #:imm #x03)
    (STA #:zp ,TETRIS-ZP-NEXT-ID)
    (LDA #:imm 0)
    (STA #:zp ,TETRIS-ZP-PIECE-ROT)
    (LDA #:imm 4)
    (STA #:zp ,TETRIS-ZP-PIECE-X)
    (LDA #:imm 2)
    (STA #:zp ,TETRIS-ZP-PIECE-Y)
    (RTS)

    ;; ========================================================================
    ;; Build Tetris OAM Buffer ($0200-$02FF)
    ;;   Slots 1..4 ($0204..$0213): Active Falling Tetromino (4 minoes, tile #x7B)
    ;;   Slots 5..8 ($0214..$0223): NEXT Preview Tetromino (4 minoes, tile #x7C)
    ;; ========================================================================
    (label build_tetris_oam)
    ;; 1. Active Tetromino (4 minoes at $0204..$0213):
    ;;    Screen X = 88 + (piece_x + dx) * 8, Screen Y = 40 + (piece_y + dy) * 8
    (LDA #:zp ,TETRIS-ZP-PIECE-ID)
    (ASL) (ASL)
    (ORA #:zp ,TETRIS-ZP-PIECE-ROT)
    (ASL) (ASL) (ASL)
    (TAX)
    (LDY #:imm 0)
    (label oam_active_loop)
    ;; Y coordinate = ((piece_y + dy) << 3) + 39
    (CLC)
    (LDA #:zp ,TETRIS-ZP-PIECE-Y)
    (ADC #:absx (+ tetromino_offset_table 1))
    (ASL) (ASL) (ASL)
    (CLC) (ADC #:imm 39)
    (STA #:absy #x0204)
    ;; Authentic Tetris white-centered mino Tile ID (#x7B)
    (LDA #:imm #x7B)
    (STA #:absy #x0205)
    ;; Palette attribute (piece_id & 3)
    (LDA #:zp ,TETRIS-ZP-PIECE-ID)
    (AND #:imm #x03)
    (STA #:absy #x0206)
    ;; X coordinate = ((piece_x + dx) << 3) + 88
    (CLC)
    (LDA #:zp ,TETRIS-ZP-PIECE-X)
    (ADC #:absx tetromino_offset_table)
    (ASL) (ASL) (ASL)
    (CLC) (ADC #:imm 88)
    (STA #:absy #x0207)
    (INX) (INX)
    (INY) (INY) (INY) (INY)
    (CPY #:imm 16)
    (BNE oam_active_loop)

    ;; 2. NEXT Preview Tetromino (4 minoes at $0214..$0223, centered at X=200, Y=88)
    (LDA #:zp ,TETRIS-ZP-NEXT-ID)
    (ASL) (ASL) (ASL) (ASL) (ASL) ; next_id * 32 (rot 0)
    (TAX)
    (LDY #:imm 0)
    (label oam_next_loop)
    (CLC)
    (LDA #:imm 11)
    (ADC #:absx (+ tetromino_offset_table 1))
    (ASL) (ASL) (ASL)
    (STA #:absy #x0214)
    ;; Authentic Tetris solid mino Tile ID (#x7C)
    (LDA #:imm #x7C)
    (STA #:absy #x0215)
    (LDA #:zp ,TETRIS-ZP-NEXT-ID)
    (AND #:imm #x03)
    (STA #:absy #x0216)
    (CLC)
    (LDA #:imm 25)
    (ADC #:absx tetromino_offset_table)
    (ASL) (ASL) (ASL)
    (STA #:absy #x0217)
    (INX) (INX)
    (INY) (INY) (INY) (INY)
    (CPY #:imm 16)
    (BNE oam_next_loop)
    (RTS)

    ;; ========================================================================
    ;; VBlank NMI Handler (Staged Dirty-Row Stripe Copier: 2 rows = 20 B / NMI!)
    ;;   Solves Problem 6 (Phi4 / Phi1 Line-Clear Bandwidth Explosion):
    ;;   Copies at most 2 rows (20 bytes) of $0400-$04C7 per VBlank frame!
    ;; ========================================================================
    (label nmi_handler)
    (PHA)
    (TXA)
    (PHA)
    (TYA)
    (PHA)

    (LDA #:imm #x00) (STA #:abs #x2003)
    (LDA #:imm #x02) (STA #:abs #x4014)

    ;; Update HUD Lines Cleared digit ($2056) — zero-offset BCD: tile #x00 is '0'!
    (BIT #:abs #x2002)
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #x56) (STA #:abs #x2006)
    (LDA #:zp ,TETRIS-ZP-LINES)
    (AND #:imm #x07)
    (STA #:abs #x2007)

    ;; Staged Dirty-Row Copier: If DIRTY_ROW < 20, flush 2 rows (20 bytes) to Nametable $2000!
    (LDA #:zp ,TETRIS-ZP-DIRTY-ROW)
    (CMP #:imm 20)
    (BCS t_nmi_restore)

    (JSR flush_one_well_row_vram)
    (LDA #:zp ,TETRIS-ZP-DIRTY-ROW)
    (CMP #:imm 20)
    (BCS t_nmi_restore)
    (JSR flush_one_well_row_vram)

    (label t_nmi_restore)
    (BIT #:abs #x2002)
    (LDA #:imm #x80) (STA #:abs #x2000)
    (LDA #:imm 0)    (STA #:abs #x2005) (STA #:abs #x2005)
    (LDA #:imm 1)    (STA #:zp #x0F)

    (PLA) (TAY)
    (PLA) (TAX)
    (PLA)
    (RTI)

    ;; Flush 10 bytes of well row `TETRIS-ZP-DIRTY-ROW` from $0400 to Nametable ($20AB + row*32)
    ;; Converts RAM byte 0 (empty cell) to #xFF (Tetris Bank 3 empty black tile) since #x00 is digit '0'!
    (label flush_one_well_row_vram)
    (LDX #:zp ,TETRIS-ZP-DIRTY-ROW)
    (BIT #:abs #x2002)
    (LDA #:absx well_row_vram_hi)
    (STA #:abs #x2006)
    (LDA #:absx well_row_vram_lo)
    (STA #:abs #x2006)
    (LDA #:absx row10_table)
    (TAY)
    (LDX #:imm 10)
    (label copy_10_cols)
    (LDA #:absy ,TETRIS-WELL-RAM-BASE)
    (BNE write_well_tile)
    (LDA #:imm #xFF)
    (label write_well_tile)
    (STA #:abs #x2007)
    (INY)
    (DEX)
    (BNE copy_10_cols)
    (INC #:zp ,TETRIS-ZP-DIRTY-ROW)
    (RTS)

    (label irq_handler)
    (RTI)

    ;; ========================================================================
    ;; Page-Aligned Lookup Tables (Grade Phi1: 0 Page Crossings!)
    ;; ========================================================================
    (.align 256)
    (label row10_table)
    (.byte 0 10 20 30 40 50 60 70 80 90 100 110 120 130 140 150 160 170 180 190)

    ;; PPU Nametable Addresses for Rows 0..19 of the 10x20 Well (Row r -> $2000 + (r+5)*32 + 11)
    (label well_row_vram_hi)
    (.byte #x20 #x20 #x20 #x21 #x21 #x21 #x21 #x21 #x21 #x21 #x21
           #x22 #x22 #x22 #x22 #x22 #x22 #x22 #x22 #x23)
    (label well_row_vram_lo)
    (.byte #xAB #xCB #xEB #x0B #x2B #x4B #x6B #x8B #xAB #xCB #xEB
           #x0B #x2B #x4B #x6B #x8B #xAB #xCB #xEB #x0B)

    ;; 7 Tetrominoes x 4 Rotations x 4 Minoes (dx, dy signed byte pairs = 224 bytes):
    ;;   Piece 0: T, Piece 1: J, Piece 2: Z, Piece 3: O, Piece 4: S, Piece 5: L, Piece 6: I
    (label tetromino_offset_table)
    ;; Piece 0 (T): 4 rotations (Up, Right, Down, Left)
    (.byte -1  0   0  0   1  0   0 -1
            0 -1   0  0   1  0   0  1
           -1  0   0  0   1  0   0  1
            0 -1  -1  0   0  0   0  1)
    ;; Piece 1 (J): 4 rotations
    (.byte -1  0   0  0   1  0   1  1
            0 -1   0  0   0  1  -1  1
           -1 -1  -1  0   0  0   1  0
            0 -1   1 -1   0  0   0  1)
    ;; Piece 2 (Z): 4 rotations
    (.byte -1  0   0  0   0  1   1  1
            1 -1   0  0   1  0   0  1
           -1  0   0  0   0  1   1  1
            1 -1   0  0   1  0   0  1)
    ;; Piece 3 (O): 4 rotations (all identical 2x2 square)
    (.byte  0  0   1  0   0  1   1  1
            0  0   1  0   0  1   1  1
            0  0   1  0   0  1   1  1
            0  0   1  0   0  1   1  1)
    ;; Piece 4 (S): 4 rotations
    (.byte  0  0   1  0  -1  1   0  1
            0 -1   0  0   1  0   1  1
            0  0   1  0  -1  1   0  1
            0 -1   0  0   1  0   1  1)
    ;; Piece 5 (L): 4 rotations
    (.byte -1  0   0  0   1  0  -1  1
           -1 -1   0 -1   0  0   0  1
            1 -1  -1  0   0  0   1  0
            0 -1   0  0   0  1   1  1)
    ;; Piece 6 (I): 4 rotations (Horizontal 4-bar & Vertical 4-bar)
    (.byte -1  0   0  0   1  0   2  0
            0 -1   0  0   0  1   0  2
           -1  0   0  0   1  0   2  0
            0 -1   0  0   0  1   0  2)

    (label tetris_palette_table)
    ;; Authentic Nintendo NES Tetris Level 0 Palettes:
    ;;   Color 1 = #x30 (Pure White center of #x7B & specular gleam of #x7C/#x7D)
    ;;   Color 2 = #x21 (Sky Cyan body of #x7C)
    ;;   Color 3 = #x28 / #x12 (Gold / Royal Blue frame of #x7B, body of #x7D & HUD font)
    (.byte #x0F #x30 #x21 #x28
           #x0F #x30 #x29 #x1A
           #x0F #x30 #x24 #x14
           #x0F #x30 #x27 #x16
           ;; 4 Sprite Palettes (Level 0 Cyan/Blue, Level 1 Green, Level 2 Magenta, Level 6 Crimson):
           #x0F #x30 #x21 #x12
           #x0F #x30 #x29 #x1A
           #x0F #x30 #x24 #x14
           #x0F #x30 #x27 #x16)))

(define (compile-tetris-nes-rom! #:nes-out-path [nes-out-path #f]
                                 #:chr-layout [chr-layout #f]
                                 #:zp-map [zp-map '()]
                                 #:state-machine [state-machine #f])
  (define forms (emit-decompiled-tetris-6502-program))
  (define asm-res (assemble-6502 forms #:origin #x8000))
  (define chr-bytes (build-tetris-chr-rom))
  (define rom-bytes (build-ines-rom asm-res chr-bytes #:mirroring 'vertical))
  (when nes-out-path
    (write-ines-rom-file! nes-out-path rom-bytes))
  (define mod-desc
    (hasheq 'name 'nintendo-tetris-nes
            'mapper 'NROM
            'chr-layout chr-layout
            'zp-map zp-map
            'state-machines (if state-machine (list state-machine) '())
            'zp-vars (list (hasheq 'name 'zp_tetris_state 'bytes 18 'cap 'RamLinear))
            'zp-scratch-blocks (list (hasheq 'id 'scratch_line_scan 'bytes 6 'leaked? #f))
            'subroutines (list (hasheq 'name 'nmi_handler 'pha-count 3 'pla-count 3))
            'ppu-ops (list (hasheq 'op 'oam-dma! 'phase 'VBlankNMI)
                           (hasheq 'op 'nametable-patch! 'phase 'VBlankNMI))
            'nmi-ops (list (hasheq 'op 'oam-dma!)
                           (hasheq 'op 'nametable-patch!)
                           (hasheq 'op 'restore-scroll! 'x 0 'y 0))
            'vblank-cycles 980
            'active-cycles 3120
            'page-crossings (asm-result-page-crossings asm-res)
            'oam-sprites 8
            'scanline-sprites 4
            'ram-bytes 200 ; 10x20 Playfield Well at $0400-$04C7
            'prg-rom-bytes (bytes-length (asm-result-bytes asm-res))
            'chr-tiles 382
            'vram-dma-bytes 200    ; 200-byte well update on Tetris line clear
            'vram-queue-slices 10  ; Flushed 2 rows (20 B) per VBlank across 10 frames!
            'attr-clashes 0
            'apu-channels '(pulse1 pulse2 triangle)))
  (define type-res (typecheck-nes-module mod-desc NTSC-NROM-BUDGET))
  (values rom-bytes asm-res type-res mod-desc))
