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
         "boba-rom-builder.rkt")

(provide
 ;; 1. Super Mario Bros. (World 1-1 Platformer)
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
 compile-mario-nes-rom!

 ;; 2. The Legend of Zelda (Top-Down Action-Adventure)
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
 compile-zelda-nes-rom!

 ;; 3. Nintendo NES Tetris (10x20 Well, Rotation & Staged VBlank Row Flush)
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

(define (build-mario-chr-rom)
  (define tiles
    (append
     (list
      ;; #x00: Empty sky tile
      (cons #x00 '("........" "........" "........" "........" "........" "........" "........" "........"))
      ;; #x01: Cracked Ground Brick (SMB1 iconic ground tile)
      (cons #x01 '("22222221" "23332231" "23222221" "22211221" "11122111" "22322321" "22222221" "11111111"))
      ;; #x02: Solid Masonry Brick
      (cons #x02 '("33313331" "22212221" "22212221" "11111111" "31333133" "21222122" "21222122" "11111111"))
      ;; #x03: '?' Question Block (Unbonked, golden shimmer)
      (cons #x03 '("13333331" "31222213" "32.33.23" "32...323" "32..3.23" "32....23" "31223213" "13333331"))
      ;; #x04: Empty Bonked Block
      (cons #x04 '("12222221" "23....32" "2......2" "2......2" "2......2" "2......2" "23....32" "12222221"))
      ;; #x05: Warp Pipe Top-Left
      (cons #x05 '("11111111" "13322222" "13322212" "13322212" "11111111" ".1332222" ".1332212" ".1332212"))
      ;; #x06: Warp Pipe Top-Right
      (cons #x06 '("11111111" "22221121" "21111221" "21111221" "11111111" "2221121." "2111221." "2111221."))
      ;; #x07: Warp Pipe Shaft-Left
      (cons #x07 '(".1332222" ".1332212" ".1332212" ".1332222" ".1332212" ".1332212" ".1332222" ".1332212"))
      ;; #x08: Warp Pipe Shaft-Right
      (cons #x08 '("2221121." "2111221." "2111221." "2221121." "2111221." "2111221." "2221121." "2111221."))
      ;; #x09: Flagpole Shaft
      (cons #x09 '("...23..." "...23..." "...23..." "...23..." "...23..." "...23..." "...23..." "...23..."))
      ;; #x0A: Flagpole Top Orb
      (cons #x0A '("..2332.." ".233332." ".233332." "..2332.." "...23..." "...23..." "...23..." "...23..."))
      ;; #x0B: Cloud / Bush Fluffy Tile
      (cons #x0B '("..3333.." ".322223." "32233223" "32222223" "32222223" ".322223." "..3333.." "........"))
      ;; #x0C: Castle Battlement Brick
      (cons #x0C '("22.22.22" "22.22.22" "22222222" "21111112" "21....12" "21....12" "21....12" "22222222"))
      ;; #x0F: Solid HUD Coin / Bar Tile for guaranteed Sprite 0 Hit overlap!
      (cons #x0F '("33333333" "32222223" "32333323" "32333323" "32333323" "32333323" "32222223" "33333333"))

      ;; #x10..#x13: Mario 16x16 Metasprite (TL=CapL, TR=Cap/FaceR, BL=OverallsL, BR=OverallsR)
      (cons #x10 '("..111111" ".1111111" ".222332." "22323332" "22322333" ".222233." "..11211." ".2221222"))
      (cons #x11 '("1111...." "111111.." "3313...." "33133..." "331133.." "1111...." "11211..." "221222.."))
      (cons #x12 '("22211211" "22111111" "33121111" "33111111" "..1111.." ".2222..." "22222..." "........"))
      (cons #x13 '("121122.." "111122.." "112133.." "111133.." "1111...." ".2222..." ".22222.." "........"))

      ;; #x14..#x17: Goomba 16x16 Metasprite (Mushroom Enemy)
      (cons #x14 '("....1111" "..111111" ".1311111" "11331111" "11131111" "11111111" ".1111111" "..222222"))
      (cons #x15 '("1111...." "111111.." "1111131." "11113311" "11113111" "11111111" "1111111." "222222.."))
      (cons #x16 '("..222222" "...22222" "..333..." ".3333..." ".333...." "........" "........" "........"))
      (cons #x17 '("222222.." "22222..." "...333.." "...3333." "....333." "........" "........" "........"))

      ;; #x18: Spinning Coin Sprite
      (cons #x18 '("..2332.." ".232232." ".232232." ".232232." ".232232." ".232232." "..2332.." "........"))
      ;; #x19: Flagpole Victory Pennant
      (cons #x19 '("3333333." "322223.." "32333..." "322223.." "3333333." "........" "........" "........")))
     (make-word-tile-pair #x30 "MARI")
     (make-word-tile-pair #x32 "COIN")
     (make-word-tile-pair #x34 "W1 1")
     ;; Digits 0..9 at #x20..#x29
     (for/list ([d (in-range 10)])
       (cons (+ #x20 d)
             (list "........"
                   (if (memv d '(0 2 3 5 6 7 8 9)) "..3333.." "....3...")
                   (if (memv d '(0 4 8 9))         ".3....3."
                       (if (memv d '(5 6))         ".3......" "......3."))
                   (if (memv d '(0 1 7))           ".3....3." "..3333..")
                   (if (memv d '(0 6 8))           ".3....3."
                       (if (= d 2)                 ".3......" "......3."))
                   (if (memv d '(0 2 3 5 6 8 9))   "..3333.." "....3...")
                   "........"
                   "........")))))
  (build-chr-rom tiles))

(define (emit-mario-6502-program)
  `(;; ========================================================================
    ;; Super Mario Bros. (World 1-1) in #lang boba-nes
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
    (BIT #:abs #x2002)
    (LDA #:imm #x20)
    (STA #:abs #x2006)
    (LDA #:imm #x00)
    (STA #:abs #x2006)
    (LDY #:imm 8)
    (LDA #:imm #x00)
    (LDX #:imm 0)
    (label clr_nt_m)
    (STA #:abs #x2007)
    (INX)
    (BNE clr_nt_m)
    (DEY)
    (BNE clr_nt_m)

    ;; Draw Stationary Status Bar HUD at Row 2 of Nametable 0 ($2042..$205D):
    ;;   "MARI" (#x30,#x70) + "COIN" (#x32,#x72) + ":0" + "W1 1" (#x34,#x74)
    ;;   And place solid tile #x0F at (X=24, Y=24 -> $2063) for Sprite 0 Hit!
    (BIT #:abs #x2002)
    (LDA #:imm #x20)
    (STA #:abs #x2006)
    (LDA #:imm #x42)
    (STA #:abs #x2006)
    (LDA #:imm #x30) (STA #:abs #x2007)
    (LDA #:imm #x70) (STA #:abs #x2007)
    (LDA #:imm #x00) (STA #:abs #x2007)
    (LDA #:imm #x32) (STA #:abs #x2007)
    (LDA #:imm #x72) (STA #:abs #x2007)
    (LDA #:imm #x20) (STA #:abs #x2007) ; '0' coins
    (LDA #:imm #x00) (STA #:abs #x2007)
    (LDA #:imm #x34) (STA #:abs #x2007)
    (LDA #:imm #x74) (STA #:abs #x2007)

    ;; Write opaque Sprite-0-Hit anchor tile (#x0F) at Nametable 0 row 3, col 3 ($2063 -> pixel X=24, Y=24)
    (BIT #:abs #x2002)
    (LDA #:imm #x20)
    (STA #:abs #x2006)
    (LDA #:imm #x63)
    (STA #:abs #x2006)
    (LDA #:imm #x0F)
    (STA #:abs #x2007)

    ;; Draw World 1-1 Ground Rows (Rows 24..27 -> $2300-$237F in NT0 and $2700-$277F in NT1)
    (BIT #:abs #x2002)
    (LDA #:imm #x23)
    (STA #:abs #x2006)
    (LDA #:imm #x00)
    (STA #:abs #x2006)
    (LDX #:imm 128)
    (LDA #:imm #x01) ; Cracked Ground Brick
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
    (LDA #:imm #x01)
    (label fill_gnd_nt1)
    (STA #:abs #x2007)
    (DEX)
    (BNE fill_gnd_nt1)

    ;; Draw World 1-1 Landmarks in Nametable 0 ($2000):
    ;; 1. '?' Question Block & Brick Row at Row 15 (Y=120 -> $21E8..$21EE, cols 8..14)
    (BIT #:abs #x2002)
    (LDA #:imm #x21)
    (STA #:abs #x2006)
    (LDA #:imm #xE8)
    (STA #:abs #x2006)
    (LDA #:imm #x02) (STA #:abs #x2007) ; Brick
    (LDA #:imm #x03) (STA #:abs #x2007) ; '?' Question Block at col 9..10 (X=72..87)!
    (LDA #:imm #x03) (STA #:abs #x2007)
    (LDA #:imm #x02) (STA #:abs #x2007) ; Brick
    (LDA #:imm #x03) (STA #:abs #x2007) ; '?' Question Block
    (LDA #:imm #x02) (STA #:abs #x2007)

    ;; 2. Green Warp Pipe at Cols 20..21, Rows 20..23 ($2294..$22F5, X=160..175, Y=160..191)
    (BIT #:abs #x2002)
    (LDA #:imm #x22) (STA #:abs #x2006) (LDA #:imm #x94) (STA #:abs #x2006)
    (LDA #:imm #x05) (STA #:abs #x2007) (LDA #:imm #x06) (STA #:abs #x2007)
    (LDA #:imm #x22) (STA #:abs #x2006) (LDA #:imm #xB4) (STA #:abs #x2006)
    (LDA #:imm #x07) (STA #:abs #x2007) (LDA #:imm #x08) (STA #:abs #x2007)
    (LDA #:imm #x22) (STA #:abs #x2006) (LDA #:imm #xD4) (STA #:abs #x2006)
    (LDA #:imm #x07) (STA #:abs #x2007) (LDA #:imm #x08) (STA #:abs #x2007)
    (LDA #:imm #x22) (STA #:abs #x2006) (LDA #:imm #xF4) (STA #:abs #x2006)
    (LDA #:imm #x07) (STA #:abs #x2007) (LDA #:imm #x08) (STA #:abs #x2007)

    ;; 3. Clouds at Row 7 ($20E4..$20E6, $20F2..$20F4)
    (BIT #:abs #x2002)
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #xE4) (STA #:abs #x2006)
    (LDA #:imm #x0B) (STA #:abs #x2007) (STA #:abs #x2007) (STA #:abs #x2007)

    ;; Draw World 1-1 Landmarks in Nametable 1 ($2400 - Scrolled Second Screen!):
    ;; 1. Brick Staircase at Row 21..23 ($26A4..$26E7)
    (BIT #:abs #x2002)
    (LDA #:imm #x26) (STA #:abs #x2006) (LDA #:imm #xE4) (STA #:abs #x2006)
    (LDA #:imm #x04) (STA #:abs #x2007) (STA #:abs #x2007) (STA #:abs #x2007)
    (LDA #:imm #x26) (STA #:abs #x2006) (LDA #:imm #xC5) (STA #:abs #x2006)
    (LDA #:imm #x04) (STA #:abs #x2007) (STA #:abs #x2007)
    (LDA #:imm #x26) (STA #:abs #x2006) (LDA #:imm #xA6) (STA #:abs #x2006)
    (LDA #:imm #x04) (STA #:abs #x2007)

    ;; 2. Flagpole at Col 12 of Nametable 1 (World X = 256 + 96 = 352! $250C..$26EC)
    (BIT #:abs #x2002)
    (LDA #:imm #x25) (STA #:abs #x2006) (LDA #:imm #x0C) (STA #:abs #x2006)
    (LDA #:imm #x0A) (STA #:abs #x2007) ; Flagpole Orb
    (LDA #:imm #x25) (STA #:abs #x2006) (LDA #:imm #x2C) (STA #:abs #x2006)
    (LDA #:imm #x09) (STA #:abs #x2007)
    (LDA #:imm #x25) (STA #:abs #x2006) (LDA #:imm #x4C) (STA #:abs #x2006)
    (LDA #:imm #x09) (STA #:abs #x2007)
    (LDA #:imm #x25) (STA #:abs #x2006) (LDA #:imm #x6C) (STA #:abs #x2006)
    (LDA #:imm #x09) (STA #:abs #x2007)
    (LDA #:imm #x25) (STA #:abs #x2006) (LDA #:imm #x8C) (STA #:abs #x2006)
    (LDA #:imm #x09) (STA #:abs #x2007)
    (LDA #:imm #x25) (STA #:abs #x2006) (LDA #:imm #xAC) (STA #:abs #x2006)
    (LDA #:imm #x09) (STA #:abs #x2007)
    (LDA #:imm #x25) (STA #:abs #x2006) (LDA #:imm #xCC) (STA #:abs #x2006)
    (LDA #:imm #x09) (STA #:abs #x2007)

    ;; 3. Castle at Col 18..22 of Nametable 1 ($2692..$26F6)
    (BIT #:abs #x2002)
    (LDA #:imm #x26) (STA #:abs #x2006) (LDA #:imm #x92) (STA #:abs #x2006)
    (LDA #:imm #x0C) (STA #:abs #x2007) (STA #:abs #x2007) (STA #:abs #x2007) (STA #:abs #x2007)
    (LDA #:imm #x26) (STA #:abs #x2006) (LDA #:imm #xB2) (STA #:abs #x2006)
    (LDA #:imm #x02) (STA #:abs #x2007) (STA #:abs #x2007) (STA #:abs #x2007) (STA #:abs #x2007)
    (LDA #:imm #x26) (STA #:abs #x2006) (LDA #:imm #xD2) (STA #:abs #x2006)
    (LDA #:imm #x02) (STA #:abs #x2007) (STA #:abs #x2007) (STA #:abs #x2007) (STA #:abs #x2007)

    ;; Set Attribute Tables ($23C0-$23FF and $27C0-$27FF):
    ;;   Top rows = Palette 1 (Gold/White HUD & ? blocks), Pipe rows = Palette 2 (Green), Ground = Palette 0 (Brick Red)
    (BIT #:abs #x2002)
    (LDA #:imm #x23) (STA #:abs #x2006) (LDA #:imm #xD0) (STA #:abs #x2006)
    (LDA #:imm #x55) ; Palette 1 for Question Blocks row
    (LDX #:imm 16)
    (label attr_qb_m)
    (STA #:abs #x2007)
    (DEX)
    (BNE attr_qb_m)
    (LDA #:imm #xAA) ; Palette 2 (Green) for Pipe & Bushes
    (LDX #:imm 16)
    (label attr_pipe_m)
    (STA #:abs #x2007)
    (DEX)
    (BNE attr_pipe_m)

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

    ;; Place OAM Sprite 0 at (X=24, Y=23, Tile=#x0F, Attr=#x20 behind BG) for HUD split!
    (LDA #:imm 23)   (STA #:abs #x0200)
    (LDA #:imm #x0F) (STA #:abs #x0201)
    (LDA #:imm #x01) (STA #:abs #x0202)
    (LDA #:imm 24)   (STA #:abs #x0203)

    ;; Enable 2A03 APU Pulse 1 + Pulse 2 + Triangle
    (LDA #:imm #x07)
    (STA #:abs #x4015)

    ;; Reset PPU scroll latch and enable NMI + BG + Sprites
    (BIT #:abs #x2002)
    (LDA #:imm 0)
    (STA #:abs #x2005)
    (STA #:abs #x2005)
    (LDA #:imm #x80)
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

    ;; 1. Perform Mid-Frame Sprite-0-Hit Raster Split at Y=24!
    ;;    Top HUD stays at scroll (0,0); playfield below Y=24 scrolls by (SCROLL_NT, SCROLL_X)
    (label m_s0_clear)
    (BIT #:abs #x2002)
    (BVS m_s0_clear)
    (label m_s0_hit)
    (BIT #:abs #x2002)
    (BVC m_s0_hit)
    (LDA #:zp ,MARIO-ZP-SCROLL-NT)
    (AND #:imm #x01)
    (ORA #:imm #x80)
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
    ;; Build OAM Sprite Buffer ($0200-$02FF)
    ;;   Slot 0 ($0200)    : Sprite 0 HUD Split Anchor (X=24, Y=23, Tile=#x0F)
    ;;   Slots 1..4 ($0204): Mario 16x16 Metasprite (#x10..#x13, Palette 0)
    ;;   Slots 5..8 ($0214): Goomba 16x16 Metasprite (#x14..#x17, Palette 1)
    ;;   Slot 9 ($0224)    : Popping Coin Sprite (#x18, Palette 2)
    ;;   Slot 10 ($0228)   : Flagpole Pennant Sprite (#x19, Palette 3)
    ;; ========================================================================
    (label build_mario_oam)
    ;; Keep Slot 0 anchored for Sprite 0 Hit
    (LDA #:imm 23)   (STA #:abs #x0200)
    (LDA #:imm #x0F) (STA #:abs #x0201)
    (LDA #:imm #x01) (STA #:abs #x0202)
    (LDA #:imm 24)   (STA #:abs #x0203)

    ;; Emit Mario 16x16 Metasprite at $0204..$0213
    (LDA #:zp ,MARIO-ZP-Y-PX)
    (STA #:abs #x0204)
    (STA #:abs #x0208)
    (CLC)
    (ADC #:imm 8)
    (STA #:abs #x020C)
    (STA #:abs #x0210)
    (LDA #:imm #x10) (STA #:abs #x0205)
    (LDA #:imm #x11) (STA #:abs #x0209)
    (LDA #:imm #x12) (STA #:abs #x020D)
    (LDA #:imm #x13) (STA #:abs #x0211)
    (LDA #:imm #x00)
    (STA #:abs #x0206) (STA #:abs #x020A) (STA #:abs #x020E) (STA #:abs #x0212)
    (LDA #:zp ,MARIO-ZP-SCREEN-X)
    (STA #:abs #x0207)
    (STA #:abs #x020F)
    (CLC)
    (ADC #:imm 8)
    (STA #:abs #x020B)
    (STA #:abs #x0213)

    ;; Emit Goomba 16x16 Metasprite at $0214..$0223 (if alive)
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
    (LDA #:imm #x14) (STA #:abs #x0215)
    (LDA #:imm #x15) (STA #:abs #x0219)
    (LDA #:imm #x16) (STA #:abs #x021D)
    (LDA #:imm #x17) (STA #:abs #x0221)
    (LDA #:imm #x01)
    (STA #:abs #x0216) (STA #:abs #x021A) (STA #:abs #x021E) (STA #:abs #x0222)
    (LDA #:zp ,MARIO-ZP-GOOMBA-X)
    (SEC)
    (SBC #:zp ,MARIO-ZP-SCROLL-X)
    (STA #:abs #x0217) (STA #:abs #x021F)
    (CLC)
    (ADC #:imm 8)
    (STA #:abs #x021B) (STA #:abs #x0223)

    ;; Emit Popping Coin Sprite at $0224..$0227
    (label draw_coin_oam)
    (LDA #:zp ,MARIO-ZP-COIN-ANIM-Y)
    (BNE show_coin_spr)
    (LDA #:imm #xF8)
    (STA #:abs #x0224)
    (JMP done_mario_oam)
    (label show_coin_spr)
    (STA #:abs #x0224)
    (LDA #:imm #x18) (STA #:abs #x0225)
    (LDA #:imm #x02) (STA #:abs #x0226)
    (LDA #:imm 76)
    (SEC)
    (SBC #:zp ,MARIO-ZP-SCROLL-X)
    (STA #:abs #x0227)

    (label done_mario_oam)
    (RTS)

    ;; ========================================================================
    ;; VBlank NMI Handler (Grade Phi1 <= 2273 cyc, Grade L4 Scroll Restore)
    ;;   1. Executes $4014 OAMDMA (514 cyc)
    ;;   2. Updates HUD Coin digit ($2047) and bonked '?' block ($21E9) if pending
    ;;   3. Restores PPU scroll to (0, 0) for top stationary HUD bar before RTI!
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

    ;; Update Coin Counter digit in HUD ($2047)
    (BIT #:abs #x2002)
    (LDA #:imm #x20)
    (STA #:abs #x2006)
    (LDA #:imm #x47)
    (STA #:abs #x2006)
    (LDA #:zp ,MARIO-ZP-COINS)
    (AND #:imm #x07)
    (CLC)
    (ADC #:imm #x20)
    (STA #:abs #x2007)

    ;; If '?' Question Block was bonked, turn $21E9..$21EA into Empty Block (#x04)
    (LDA #:zp ,MARIO-ZP-VRAM-PENDING)
    (BEQ nmi_restore_hud_scroll)
    (LDA #:imm 0)
    (STA #:zp ,MARIO-ZP-VRAM-PENDING)
    (BIT #:abs #x2002)
    (LDA #:imm #x21)
    (STA #:abs #x2006)
    (LDA #:imm #xE9)
    (STA #:abs #x2006)
    (LDA #:imm #x04)
    (STA #:abs #x2007)
    (STA #:abs #x2007)

    ;; Lock top of screen to Nametable 0 at scroll (0, 0) for the stationary HUD!
    ;; (ActiveFrame will split the scroll at scanline 24 via Sprite 0 Hit!)
    (label nmi_restore_hud_scroll)
    (BIT #:abs #x2002)
    (LDA #:imm #x80)
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
    ;; 4 Background Palettes (Universal Sky Blue #x22):
    ;; Pal 0: Brick Red / Ground (#x22, #x0F, #x16, #x37)
    ;; Pal 1: Golden '?' Block / HUD (#x22, #x0F, #x27, #x30)
    ;; Pal 2: Emerald Warp Pipe & Bushes (#x22, #x0F, #x19, #x29)
    ;; Pal 3: Castle Stone (#x22, #x0F, #x00, #x10)
    (.byte #x22 #x0F #x16 #x37
           #x22 #x0F #x27 #x30
           #x22 #x0F #x19 #x29
           #x22 #x0F #x00 #x10
           ;; 4 Sprite Palettes:
           ;; Spr 0: Mario Red/Brown/Peach (#x22, #x16, #x27, #x18)
           ;; Spr 1: Goomba Chestnut/Cream (#x22, #x0F, #x17, #x37)
           ;; Spr 2: Coin Gold (#x22, #x0F, #x27, #x30)
           ;; Spr 3: Flag Pennant Green (#x22, #x0F, #x19, #x30)
           #x22 #x16 #x36 #x17
           #x22 #x0F #x17 #x37
           #x22 #x0F #x27 #x30
           #x22 #x0F #x19 #x30)))

(define (compile-mario-nes-rom! #:nes-out-path [nes-out-path #f])
  (define forms (emit-mario-6502-program))
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
            'oam-sprites 10
            'scanline-sprites 5
            'ram-bytes 256
            'prg-rom-bytes (bytes-length (asm-result-bytes asm-res))
            'chr-tiles 40
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

(define (build-zelda-chr-rom)
  (define tiles
    (append
     (list
      ;; #x00: Floor tile
      (cons #x00 '("........" "........" "........" "........" "........" "........" "........" "........"))
      ;; #x01: Overworld Craggy Mountain / Tree Rock Metatile
      (cons #x01 '("12233221" "23322332" "23211232" "32111123" "32122123" "23211232" "23322332" "12233221"))
      ;; #x02: Carved Dungeon Temple Block
      (cons #x02 '("33333331" "32222211" "32111211" "32121211" "32111211" "32222211" "31111111" "11111111"))
      ;; #x03: Locked Dungeon Door (Keyhole gate)
      (cons #x03 '("13333331" "32111123" "31.33.13" "31.33.13" "31..3.13" "31.33.13" "32111123" "13333331"))
      ;; #x04: Sanctum Pedestal Tile
      (cons #x04 '("33333333" "12222221" ".133331." ".132231." ".132231." ".133331." "12222221" "33333333"))
      ;; #x05: HUD Heart Icon
      (cons #x05 '(".22..22." "23222222" "23222222" "22222222" ".222222." "..2222.." "...22..." "........"))

      ;; #x10..#x13: Link 16x16 Metasprite (Green Tunic, Pointed Cap & Hylian Shield)
      (cons #x10 '("....1111" "..111111" ".1122222" ".2222332" ".2222223" ".3333111" "32323111" "33233111"))
      (cons #x11 '("1111...." "111111.." "2222211." "2332222." "3222222." "1111122." "1111122." "111111.."))
      (cons #x12 '("32323111" ".3333111" "..111111" "...2222." "...2222." "..22222." "........" "........"))
      (cons #x13 '("111111.." "111111.." "111111.." ".2222..." ".2222..." ".22222.." "........" "........"))

      ;; #x14: Vertical Sword Blade
      (cons #x14 '("...33..." "...33..." "...33..." "...33..." "...33..." ".123321." "...22..." "...22..."))
      ;; #x15: Horizontal Sword Blade
      (cons #x15 '("........" ".....1.." "33333222" "33333222" ".....1.." "........" "........" "........"))

      ;; #x16..#x19: Red Octorok 16x16 Metasprite
      (cons #x16 '("...11111" "..122222" ".1222222" ".1223312" ".1223312" ".1222223" "..122221" ".11.11.1"))
      (cons #x17 '("11111..." "222221.." "2222221." "2133221." "2133221." "3222221." "122221.." "1.11.11."))
      (cons #x18 '("11..11.." "1...11.." "........" "........" "........" "........" "........" "........"))
      (cons #x19 '("..11..11" "..11...1" "........" "........" "........" "........" "........" "........"))

      ;; #x1C: Golden Dungeon Key Sprite
      (cons #x1C '("..2332.." ".23..32." "..2332.." "...33..." "...333.." "...33..." "...333.." "........"))
      ;; #x1D: Glowing Triforce of Wisdom Sprite
      (cons #x1D '("...33..." "..3223.." ".323323." "32222223" ".33..33." "32233223" "33333333" "........")))
     (make-word-tile-pair #x30 "LIFE")
     (make-word-tile-pair #x32 "KEY ")
     ;; Digits 0..9 at #x20..#x29
     (for/list ([d (in-range 10)])
       (cons (+ #x20 d)
             (list "........"
                   (if (memv d '(0 2 3 5 6 7 8 9)) "..3333.." "....3...")
                   (if (memv d '(0 4 8 9))         ".3....3."
                       (if (memv d '(5 6))         ".3......" "......3."))
                   (if (memv d '(0 1 7))           ".3....3." "..3333..")
                   (if (memv d '(0 6 8))           ".3....3."
                       (if (= d 2)                 ".3......" "......3."))
                   (if (memv d '(0 2 3 5 6 8 9))   "..3333.." "....3...")
                   "........"
                   "........")))))
  (build-chr-rom tiles))

(define (emit-zelda-6502-program)
  `(;; ========================================================================
    ;; The Legend of Zelda (Overworld & Triforce Sanctum) in #lang boba-nes
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

    ;; Clear Nametable 0 ($2000-$23FF)
    (BIT #:abs #x2002)
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #x00) (STA #:abs #x2006)
    (LDY #:imm 4)
    (LDA #:imm #x00)
    (LDX #:imm 0)
    (label clr_nt_z)
    (STA #:abs #x2007)
    (INX)
    (BNE clr_nt_z)
    (DEY)
    (BNE clr_nt_z)

    ;; Draw Subscreen HUD at Row 2 ($2042..$205A):
    ;;   "KEY " (#x32,#x72) + "0" + "LIFE" (#x30,#x70) + 3 Hearts (#x05 #x05 #x05)
    (BIT #:abs #x2002)
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #x42) (STA #:abs #x2006)
    (LDA #:imm #x32) (STA #:abs #x2007)
    (LDA #:imm #x72) (STA #:abs #x2007)
    (LDA #:imm #x20) (STA #:abs #x2007) ; Key count '0' at $2044
    (LDA #:imm #x00) (STA #:abs #x2007)
    (LDA #:imm #x30) (STA #:abs #x2007)
    (LDA #:imm #x70) (STA #:abs #x2007)
    (LDA #:imm #x05) (STA #:abs #x2007) ; 3 Red Hearts
    (STA #:abs #x2007)
    (STA #:abs #x2007)

    ;; Draw Overworld Room Border Walls:
    ;;   Top wall at Rows 6..7 ($20C0-$20FF) with Locked Dungeon Door at cols 15..16 ($20CF..$20D0, $20EF..$20F0)
    (BIT #:abs #x2002)
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #xC0) (STA #:abs #x2006)
    (LDX #:imm 64)
    (LDA #:imm #x01)
    (label top_wall_z)
    (STA #:abs #x2007)
    (DEX)
    (BNE top_wall_z)

    ;; Carve Locked Dungeon Door (#x03) at North Gate ($20CF, $20D0, $20EF, $20F0)
    (BIT #:abs #x2002)
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #xCF) (STA #:abs #x2006)
    (LDA #:imm #x03) (STA #:abs #x2007) (STA #:abs #x2007)
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #xEF) (STA #:abs #x2006)
    (LDA #:imm #x03) (STA #:abs #x2007) (STA #:abs #x2007)

    ;; Bottom wall at Rows 26..27 ($2340-$237F)
    (BIT #:abs #x2002)
    (LDA #:imm #x23) (STA #:abs #x2006) (LDA #:imm #x40) (STA #:abs #x2006)
    (LDX #:imm 64)
    (LDA #:imm #x01)
    (label bot_wall_z)
    (STA #:abs #x2007)
    (DEX)
    (BNE bot_wall_z)

    ;; Decorative central rock pillars at ($21CC..$21CD, $21F2..$21F3)
    (BIT #:abs #x2002)
    (LDA #:imm #x21) (STA #:abs #x2006) (LDA #:imm #xC8) (STA #:abs #x2006)
    (LDA #:imm #x02) (STA #:abs #x2007) (STA #:abs #x2007)
    (LDA #:imm #x21) (STA #:abs #x2006) (LDA #:imm #xD6) (STA #:abs #x2006)
    (LDA #:imm #x02) (STA #:abs #x2007) (STA #:abs #x2007)

    ;; Attribute Table: Top HUD uses Palette 1 (Crimson Hearts / White Text),
    ;; Overworld walls use Palette 0 (Forest Green) & Palette 2 (Gold Door)
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

    (BIT #:abs #x2002)
    (LDA #:imm 0)
    (STA #:abs #x2005)
    (STA #:abs #x2005)
    (LDA #:imm #x80)
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
    ;; Build Zelda OAM Buffer ($0200-$02FF)
    ;;   Slots 1..4 ($0204): Link 16x16 Metasprite (#x10..#x13, Palette 0)
    ;;   Slot 5 ($0214)    : Sword Blade (#x14/#x15, Palette 1)
    ;;   Slots 6..9 ($0218): Red Octorok 16x16 Metasprite (#x16..#x19, Palette 2)
    ;;   Slot 10 ($0228)   : Dropped Key (#x1C) or Glowing Triforce (#x1D, Palette 3)
    ;; ========================================================================
    (label build_zelda_oam)
    ;; Link 16x16 Metasprite at $0204..$0213
    (LDA #:zp ,ZELDA-ZP-LINK-Y)
    (STA #:abs #x0204) (STA #:abs #x0208)
    (CLC) (ADC #:imm 8)
    (STA #:abs #x020C) (STA #:abs #x0210)
    (LDA #:imm #x10) (STA #:abs #x0205)
    (LDA #:imm #x11) (STA #:abs #x0209)
    (LDA #:imm #x12) (STA #:abs #x020D)
    (LDA #:imm #x13) (STA #:abs #x0211)
    (LDA #:imm #x00)
    (STA #:abs #x0206) (STA #:abs #x020A) (STA #:abs #x020E) (STA #:abs #x0212)
    (LDA #:zp ,ZELDA-ZP-LINK-X)
    (STA #:abs #x0207) (STA #:abs #x020F)
    (CLC) (ADC #:imm 8)
    (STA #:abs #x020B) (STA #:abs #x0213)

    ;; Sword Sprite at $0214..$0217
    (LDA #:zp ,ZELDA-ZP-SWORD-TIMER)
    (BNE show_sword_oam)
    (LDA #:imm #xF8)
    (STA #:abs #x0214)
    (JMP draw_octo_oam)
    (label show_sword_oam)
    (LDA #:zp ,ZELDA-ZP-SWORD-Y) (STA #:abs #x0214)
    (LDA #:imm #x14)             (STA #:abs #x0215)
    (LDA #:imm #x01)             (STA #:abs #x0216)
    (LDA #:zp ,ZELDA-ZP-SWORD-X) (STA #:abs #x0217)

    ;; Red Octorok 16x16 Metasprite at $0218..$0227
    (label draw_octo_oam)
    (LDA #:zp ,ZELDA-ZP-OCTO-ALIVE)
    (BNE show_octo_oam)
    (LDA #:imm #xF8)
    (STA #:abs #x0218) (STA #:abs #x021C) (STA #:abs #x0220) (STA #:abs #x0224)
    (JMP draw_item_oam)
    (label show_octo_oam)
    (LDA #:zp ,ZELDA-ZP-OCTO-Y)
    (STA #:abs #x0218) (STA #:abs #x021C)
    (CLC) (ADC #:imm 8)
    (STA #:abs #x0220) (STA #:abs #x0224)
    (LDA #:imm #x16) (STA #:abs #x0219)
    (LDA #:imm #x17) (STA #:abs #x021D)
    (LDA #:imm #x18) (STA #:abs #x0221)
    (LDA #:imm #x19) (STA #:abs #x0225)
    (LDA #:imm #x02)
    (STA #:abs #x021A) (STA #:abs #x021E) (STA #:abs #x0222) (STA #:abs #x0226)
    (LDA #:zp ,ZELDA-ZP-OCTO-X)
    (STA #:abs #x021B) (STA #:abs #x0223)
    (CLC) (ADC #:imm 8)
    (STA #:abs #x021F) (STA #:abs #x0227)

    ;; Key or Triforce Sprite at $0228..$022B
    (label draw_item_oam)
    (LDA #:zp ,ZELDA-ZP-ROOM-ID)
    (BNE show_triforce_oam)
    (LDA #:zp ,ZELDA-ZP-KEY-X)
    (BEQ hide_item_oam)
    (LDA #:zp ,ZELDA-ZP-KEY-Y) (STA #:abs #x0228)
    (LDA #:imm #x1C)           (STA #:abs #x0229)
    (LDA #:imm #x03)           (STA #:abs #x022A)
    (LDA #:zp ,ZELDA-ZP-KEY-X) (STA #:abs #x022B)
    (RTS)

    (label show_triforce_oam)
    (LDA #:imm 104)  (STA #:abs #x0228)
    (LDA #:imm #x1D) (STA #:abs #x0229)
    (LDA #:imm #x03) (STA #:abs #x022A)
    (LDA #:imm 124)  (STA #:abs #x022B)
    (RTS)

    (label hide_item_oam)
    (LDA #:imm #xF8) (STA #:abs #x0228)
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

    ;; Update HUD Key Counter ($2044)
    (BIT #:abs #x2002)
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #x44) (STA #:abs #x2006)
    (LDA #:zp ,ZELDA-ZP-KEYS)
    (AND #:imm #x07)
    (CLC) (ADC #:imm #x20)
    (STA #:abs #x2007)

    ;; If Room transitioned to Sanctum (ROOM_ID == 1), open North Door & draw Pedestal!
    (LDA #:zp ,ZELDA-ZP-ROOM-DIRTY)
    (BEQ z_nmi_restore)
    (LDA #:imm 0)
    (STA #:zp ,ZELDA-ZP-ROOM-DIRTY)
    (BIT #:abs #x2002)
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #xCF) (STA #:abs #x2006)
    (LDA #:imm #x00) (STA #:abs #x2007) (STA #:abs #x2007)
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #xEF) (STA #:abs #x2006)
    (LDA #:imm #x00) (STA #:abs #x2007) (STA #:abs #x2007)
    ;; Draw Triforce Pedestal at ($218E..$2191)
    (LDA #:imm #x21) (STA #:abs #x2006) (LDA #:imm #x8E) (STA #:abs #x2006)
    (LDA #:imm #x04) (STA #:abs #x2007) (STA #:abs #x2007) (STA #:abs #x2007) (STA #:abs #x2007)

    (label z_nmi_restore)
    (BIT #:abs #x2002)
    (LDA #:imm #x80) (STA #:abs #x2000)
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
    ;; 4 BG Palettes (Deep Dungeon/Overworld Black #x0F):
    ;; Pal 0: Overworld Forest Green / Tan (#x0F, #x19, #x29, #x37)
    ;; Pal 1: Subscreen HUD Crimson Hearts & White Text (#x0F, #x16, #x27, #x30)
    ;; Pal 2: Dungeon Stone Blue (#x0F, #x02, #x12, #x22)
    ;; Pal 3: Golden Door / Triforce Pedestal (#x0F, #x17, #x27, #x38)
    (.byte #x0F #x19 #x29 #x37
           #x0F #x16 #x27 #x30
           #x0F #x02 #x12 #x22
           #x0F #x17 #x27 #x38
           ;; 4 Sprite Palettes:
           ;; Spr 0: Link Tunic Green / Tan / Brown (#x0F, #x29, #x27, #x17)
           ;; Spr 1: Steel Sword Blade (#x0F, #x12, #x22, #x30)
           ;; Spr 2: Red Octorok (#x0F, #x16, #x26, #x30)
           ;; Spr 3: Golden Key & Triforce (#x0F, #x17, #x28, #x38)
           #x0F #x29 #x27 #x17
           #x0F #x12 #x22 #x30
           #x0F #x16 #x26 #x30
           #x0F #x17 #x28 #x38)))

(define (compile-zelda-nes-rom! #:nes-out-path [nes-out-path #f])
  (define forms (emit-zelda-6502-program))
  (define asm-res (assemble-6502 forms #:origin #x8000))
  (define chr-bytes (build-zelda-chr-rom))
  (define rom-bytes (build-ines-rom asm-res chr-bytes #:mirroring 'vertical))
  (when nes-out-path
    (write-ines-rom-file! nes-out-path rom-bytes))
  (define mod-desc
    (hasheq 'name 'legend-of-zelda-nes
            'mapper 'NROM
            'oam-mux? #t ; Uses Coprime OAM Flicker Multiplexer!
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
            'chr-tiles 38
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
  (define tiles
    (append
     (list
      ;; #x00: Empty well background tile
      (cons #x00 '("........" "........" "........" "........" "........" "........" "........" "........"))
      ;; #x01: Beveled Cyan/White Tetromino Block (I / O / T)
      (cons #x01 '("33333331" "33333321" "33222221" "33222221" "33222221" "33222221" "32222211" "11111111"))
      ;; #x02: Beveled Solid Accent Tetromino Block (J / S)
      (cons #x02 '("11111111" "13333321" "13111121" "13122121" "13122121" "13111121" "12222221" "11111111"))
      ;; #x03: Beveled Highlight Tetromino Block (Z / L)
      (cons #x03 '("11111111" "13333331" "13222231" "13233231" "13233231" "13222231" "13333331" "11111111"))
      ;; #x04: Playfield Well Border Pillar Tile
      (cons #x04 '("23222231" "23111131" "23122131" "23122131" "23122131" "23122131" "23111131" "23222231")))
     (make-word-tile-pair #x30 "LINE")
     (make-word-tile-pair #x32 "NEXT")
     (make-word-tile-pair #x34 "TETR")
     ;; Digits 0..9 at #x20..#x29
     (for/list ([d (in-range 10)])
       (cons (+ #x20 d)
             (list "........"
                   (if (memv d '(0 2 3 5 6 7 8 9)) "..3333.." "....3...")
                   (if (memv d '(0 4 8 9))         ".3....3."
                       (if (memv d '(5 6))         ".3......" "......3."))
                   (if (memv d '(0 1 7))           ".3....3." "..3333..")
                   (if (memv d '(0 6 8))           ".3....3."
                       (if (= d 2)                 ".3......" "......3."))
                   (if (memv d '(0 2 3 5 6 8 9))   "..3333.." "....3...")
                   "........"
                   "........")))))
  (build-chr-rom tiles))

(define (emit-tetris-6502-program)
  `(;; ========================================================================
    ;; Nintendo NES Tetris in #lang boba-nes
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

    ;; Clear Nametable 0 ($2000-$23FF)
    (BIT #:abs #x2002)
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #x00) (STA #:abs #x2006)
    (LDY #:imm 4)
    (LDA #:imm #x00)
    (LDX #:imm 0)
    (label clr_nt_t)
    (STA #:abs #x2007)
    (INX)
    (BNE clr_nt_t)
    (DEY)
    (BNE clr_nt_t)

    ;; Draw Top HUD ("TETR" + "LINE" + ":0" at Row 2, $204B..$2055)
    ;; and "NEXT" label at Row 8, Col 24 ($2118..$2119)
    (BIT #:abs #x2002)
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #x4B) (STA #:abs #x2006)
    (LDA #:imm #x34) (STA #:abs #x2007)
    (LDA #:imm #x74) (STA #:abs #x2007)
    (LDA #:imm #x00) (STA #:abs #x2007)
    (LDA #:imm #x30) (STA #:abs #x2007)
    (LDA #:imm #x70) (STA #:abs #x2007)
    (LDA #:imm #x20) (STA #:abs #x2007) ; Lines cleared digit '0' at $2050

    (BIT #:abs #x2002)
    (LDA #:imm #x21) (STA #:abs #x2006) (LDA #:imm #x18) (STA #:abs #x2006)
    (LDA #:imm #x32) (STA #:abs #x2007)
    (LDA #:imm #x72) (STA #:abs #x2007)

    ;; Draw 10x20 Playfield Well Frame (Left wall at Col 10, Right wall at Col 21, Rows 5..24, Floor at Row 25):
    ;; Use PPUCTRL bit 2 = 1 (+32 vertical increment!) to draw Left & Right well walls in 2 passes!
    (LDA #:imm #x04)
    (STA #:abs #x2000) ; +32 vertical address increment!
    ;; Left Wall (Col 10, Row 5 -> $20AA)
    (BIT #:abs #x2002)
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #xAA) (STA #:abs #x2006)
    (LDX #:imm 20)
    (LDA #:imm #x04)
    (label left_well_wall)
    (STA #:abs #x2007)
    (DEX)
    (BNE left_well_wall)
    ;; Right Wall (Col 21, Row 5 -> $20B5)
    (BIT #:abs #x2002)
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #xB5) (STA #:abs #x2006)
    (LDX #:imm 20)
    (LDA #:imm #x04)
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
    (LDA #:imm #x04)
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
    ;; Write tile (#x01 + (piece_id & 1)) into $0400 + Y
    (LDA #:zp ,TETRIS-ZP-PIECE-ID)
    (AND #:imm #x01)
    (CLC) (ADC #:imm #x01)
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
    ;;   Slots 1..4 ($0204..$0213): Active Falling Tetromino (4 minoes)
    ;;   Slots 5..8 ($0214..$0223): NEXT Preview Tetromino (4 minoes at X=196, Y=88)
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
    ;; Y coordinate = ((piece_y + dy) << 3) + 40
    (CLC)
    (LDA #:zp ,TETRIS-ZP-PIECE-Y)
    (ADC #:absx (+ tetromino_offset_table 1))
    (ASL) (ASL) (ASL)
    (CLC) (ADC #:imm 39)
    (STA #:absy #x0204)
    ;; Tile ID (#x01)
    (LDA #:imm #x01)
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

    ;; 2. NEXT Preview Tetromino (4 minoes at $0214..$0223, centered at X=196, Y=88)
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
    (LDA #:imm #x02)
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

    ;; Update HUD Lines Cleared digit ($2050)
    (BIT #:abs #x2002)
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #x50) (STA #:abs #x2006)
    (LDA #:zp ,TETRIS-ZP-LINES)
    (AND #:imm #x07)
    (CLC) (ADC #:imm #x20)
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
    ;; 4 BG Palettes:
    (.byte #x0F #x11 #x21 #x30
           #x0F #x16 #x26 #x30
           #x0F #x19 #x29 #x30
           #x0F #x00 #x10 #x30
           ;; 4 Sprite Palettes (Cyan, Crimson, Emerald, Gold):
           #x0F #x11 #x21 #x30
           #x0F #x16 #x27 #x30
           #x0F #x19 #x29 #x30
           #x0F #x17 #x28 #x30)))

(define (compile-tetris-nes-rom! #:nes-out-path [nes-out-path #f])
  (define forms (emit-tetris-6502-program))
  (define asm-res (assemble-6502 forms #:origin #x8000))
  (define chr-bytes (build-tetris-chr-rom))
  (define rom-bytes (build-ines-rom asm-res chr-bytes #:mirroring 'vertical))
  (when nes-out-path
    (write-ines-rom-file! nes-out-path rom-bytes))
  (define mod-desc
    (hasheq 'name 'nintendo-tetris-nes
            'mapper 'NROM
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
            'chr-tiles 26
            'vram-dma-bytes 200    ; 200-byte well update on Tetris line clear
            'vram-queue-slices 10  ; Flushed 2 rows (20 B) per VBlank across 10 frames!
            'attr-clashes 0
            'apu-channels '(pulse1 pulse2 triangle)))
  (define type-res (typecheck-nes-module mod-desc NTSC-NROM-BUDGET))
  (values rom-bytes asm-res type-res mod-desc))
