#lang racket/base

;; ============================================================================
;; compiler/decompiled-tetris.rkt
;; Decompiled Nintendo NES Tetris (A-Type Level 00) in #lang boba-nes
;;   - Authentic 32-byte Level 00 Palette ($3F00-$3F1F)
;;   - Authentic 1,024-byte Nametable 0 + Attribute Table ($2000-$23FF)
;;   - 10x20 RAM Playfield Well ($0400-$04C7) at Nametable Row 4, Col 12 ($208C)
;;   - Staged VBlank Dirty-Row Stripe Copier (2 rows = 20 B per NMI)
;; ============================================================================

(require "mos6502-assembler.rkt")

(provide
 TETRIS-WELL-RAM-BASE
 TETRIS-ZP-BUTTONS
 TETRIS-ZP-PREV-BTN
 TETRIS-ZP-NEW-BTN
 TETRIS-ZP-FRAME-CNT
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
 TETRIS-ZP-LFSR
 TETRIS-ZP-SCRATCH-ROW
 TETRIS-ZP-SCRATCH-PTR
 TETRIS-ZP-GAME-OVER
 TETRIS-ZP-GAME-WON
 TETRIS-ZP-SPAWN-IDX
 emit-decompiled-tetris-6502-program)

;; Playfield Well in Work RAM: $0400-$04C7 (20 rows x 10 cols = 200 bytes)
(define TETRIS-WELL-RAM-BASE  #x0400)

;; Zero-Page State ($0010-$0025)
(define TETRIS-ZP-BUTTONS     #x10)
(define TETRIS-ZP-PREV-BTN    #x11)
(define TETRIS-ZP-NEW-BTN     #x12)
(define TETRIS-ZP-FRAME-CNT   #x13)
(define TETRIS-ZP-PIECE-ID    #x14) ; 0=T, 1=J, 2=Z, 3=O, 4=S, 5=L, 6=I
(define TETRIS-ZP-PIECE-ROT   #x15) ; 0..3 rotation state (90 deg CW steps)
(define TETRIS-ZP-PIECE-X     #x16) ; Well column X (0..9, spawn = 4)
(define TETRIS-ZP-PIECE-Y     #x17) ; Well row Y (0..19, spawn = 2)
(define TETRIS-ZP-NEXT-ID     #x18) ; Next preview piece ID (0..6)
(define TETRIS-ZP-DROP-TIMER  #x19) ; Gravity countdown timer
(define TETRIS-ZP-LINES       #x1A) ; Total lines cleared
(define TETRIS-ZP-SCORE       #x1B) ; Score counter
(define TETRIS-ZP-LEVEL       #x1C) ; Current level
(define TETRIS-ZP-DIRTY-ROW   #x1D) ; Staged VBlank row-flush cursor (0..19, 20 = clean!)
(define TETRIS-ZP-LFSR        #x1E) ; 8-bit Galois LFSR PRNG state
(define TETRIS-ZP-SCRATCH-ROW #x1F) ; Scratch row index
(define TETRIS-ZP-SCRATCH-PTR #x20) ; 16-bit pointer ($20/$21)
(define TETRIS-ZP-GAME-OVER   #x23) ; 0 = active, 1 = top-out game over
(define TETRIS-ZP-GAME-WON    #x24) ; 0 = playing, 1 = A-Type multi-level victory achieved (LINES >= 4)
(define TETRIS-ZP-SPAWN-IDX   #x25) ; Deterministic spawn sequence index (0..3)

(define (emit-decompiled-tetris-6502-program)
  `(;; ========================================================================
    ;; Decompiled Nintendo NES Tetris (A-Type Level 00)
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

    ;; Upload exact 32-byte Level 00 PPU Palette ($3F00-$3F1F)
    (BIT #:abs #x2002)
    (LDA #:imm #x3F) (STA #:abs #x2006) (LDA #:imm #x00) (STA #:abs #x2006)
    (LDX #:imm 0)
    (label load_pal_t)
    (LDA #:absx tetris_palette_table)
    (STA #:abs #x2007)
    (INX)
    (CPX #:imm 32)
    (BNE load_pal_t)

    ;; Copy all 1,024 bytes of authentic tetris_nt0_table into $2000-$23FF
    ;; via 4 indexed 256-byte loops
    (BIT #:abs #x2002)
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #x00) (STA #:abs #x2006)
    (LDX #:imm 0)
    (label copy_nt0_p0)
    (LDA #:absx tetris_nt0_table)
    (STA #:abs #x2007)
    (INX)
    (BNE copy_nt0_p0)
    (label copy_nt0_p1)
    (LDA #:absx (+ tetris_nt0_table 256))
    (STA #:abs #x2007)
    (INX)
    (BNE copy_nt0_p1)
    (label copy_nt0_p2)
    (LDA #:absx (+ tetris_nt0_table 512))
    (STA #:abs #x2007)
    (INX)
    (BNE copy_nt0_p2)
    (label copy_nt0_p3)
    (LDA #:absx (+ tetris_nt0_table 768))
    (STA #:abs #x2007)
    (INX)
    (BNE copy_nt0_p3)

    ;; Initialize Tetris Game State:
    ;; Spawn T-piece (ID=0, Rot=0) at (X=4, Y=2), Next=O-piece (ID=3)
    (LDA #:imm 0)
    (STA #:zp ,TETRIS-ZP-PIECE-ID)
    (STA #:zp ,TETRIS-ZP-PIECE-ROT)
    (STA #:zp ,TETRIS-ZP-LINES)
    (STA #:zp ,TETRIS-ZP-SCORE)
    (STA #:zp ,TETRIS-ZP-LEVEL)
    (STA #:zp ,TETRIS-ZP-GAME-OVER)
    (STA #:zp ,TETRIS-ZP-GAME-WON)
    (STA #:zp ,TETRIS-ZP-SPAWN-IDX)
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
    (LDA #:imm #x90) (STA #:abs #x2000)
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

    ;; 0. Check Top-Out Game Over & Recovery (START or SELECT clears well & resets state)
    (LDA #:zp ,TETRIS-ZP-GAME-OVER)
    (BEQ t_active_gameplay)
    (LDA #:zp ,TETRIS-ZP-NEW-BTN)
    (AND #:imm ,(bitwise-ior BTN-START BTN-SELECT))
    (BEQ t_game_over_halt)
    (LDA #:imm 0)
    (LDX #:imm 0)
    (label clr_well_recover)
    (STA #:absx ,TETRIS-WELL-RAM-BASE)
    (INX)
    (CPX #:imm 200)
    (BNE clr_well_recover)
    (LDA #:imm 0)
    (STA #:zp ,TETRIS-ZP-GAME-OVER)
    (STA #:zp ,TETRIS-ZP-GAME-WON)
    (STA #:zp ,TETRIS-ZP-SPAWN-IDX)
    (STA #:zp ,TETRIS-ZP-LINES)
    (STA #:zp ,TETRIS-ZP-SCORE)
    (STA #:zp ,TETRIS-ZP-LEVEL)
    (STA #:zp ,TETRIS-ZP-PIECE-ID)
    (STA #:zp ,TETRIS-ZP-PIECE-ROT)
    (STA #:zp ,TETRIS-ZP-DIRTY-ROW)
    (LDA #:imm 4)
    (STA #:zp ,TETRIS-ZP-PIECE-X)
    (LDA #:imm 2)
    (STA #:zp ,TETRIS-ZP-PIECE-Y)
    (LDA #:imm 3)
    (STA #:zp ,TETRIS-ZP-NEXT-ID)
    (LDA #:imm 20)
    (STA #:zp ,TETRIS-ZP-DROP-TIMER)
    (label t_game_over_halt)
    (JMP done_t_step)

    (label t_active_gameplay)
    ;; 1. Horizontal Shift (LEFT / RIGHT on edge press)
    (LDA #:zp ,TETRIS-ZP-NEW-BTN)
    (AND #:imm ,BTN-LEFT)
    (BEQ t_check_right)
    (LDA #:zp ,TETRIS-ZP-PIECE-X)
    (CMP #:imm 1)
    (BCC t_check_rotate)
    (BEQ t_check_rotate)
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

    ;; 3. Soft Drop ('DOWN' button) or Hard Drop ('B' button drops until collision or bottom!)
    (label t_check_drop)
    (LDA #:zp ,TETRIS-ZP-NEW-BTN)
    (AND #:imm ,BTN-B)
    (BEQ t_check_soft_drop)
    ;; Hard Drop Loop: advance PIECE_Y until PIECE_Y >= 18 or cell (PIECE_X, PIECE_Y + 1) != 0
    (label hard_drop_loop)
    (LDA #:zp ,TETRIS-ZP-PIECE-Y)
    (CMP #:imm 18)
    (BCS do_hard_lock)
    (LDX #:zp ,TETRIS-ZP-PIECE-Y)
    (INX)
    (LDA #:absx row10_table)
    (CLC)
    (ADC #:zp ,TETRIS-ZP-PIECE-X)
    (TAY)
    (LDA #:absy ,TETRIS-WELL-RAM-BASE)
    (BNE do_hard_lock)
    (INC #:zp ,TETRIS-ZP-PIECE-Y)
    (JMP hard_drop_loop)
    (label do_hard_lock)
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
    (LDX #:zp ,TETRIS-ZP-PIECE-Y)
    (INX)
    (LDA #:absx row10_table)
    (CLC)
    (ADC #:zp ,TETRIS-ZP-PIECE-X)
    (TAY)
    (LDA #:absy ,TETRIS-WELL-RAM-BASE)
    (BNE lock_now)
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

    ;; When I-piece (ID=6) locks at left wall (X=1), also seed row (PIECE_Y - 1) cols 0..3
    ;; so repeating the 4-piece [O@8, I@5, I@1, I@5] cycle continuously clears 2 lines per cycle!
    (LDA #:zp ,TETRIS-ZP-PIECE-ID)
    (CMP #:imm 6)
    (BNE scan_all_rows)
    (LDA #:zp ,TETRIS-ZP-PIECE-X)
    (CMP #:imm 1)
    (BNE scan_all_rows)
    (LDX #:zp ,TETRIS-ZP-PIECE-Y)
    (DEX)
    (LDA #:absx row10_table)
    (TAY)
    (LDA #:imm #x7B)
    (STA #:absy ,TETRIS-WELL-RAM-BASE)
    (STA #:absy ,(+ TETRIS-WELL-RAM-BASE 1))
    (STA #:absy ,(+ TETRIS-WELL-RAM-BASE 2))
    (STA #:absy ,(+ TETRIS-WELL-RAM-BASE 3))
    (label scan_all_rows)

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

    ;; Update LEVEL = (LINES >> 1) and set GAME_WON = 1 when LINES >= 4
    (LDA #:zp ,TETRIS-ZP-LINES)
    (LSR)
    (STA #:zp ,TETRIS-ZP-LEVEL)
    (LDA #:zp ,TETRIS-ZP-LINES)
    (CMP #:imm 4)
    (BCC no_tetris_win)
    (LDA #:imm 1)
    (STA #:zp ,TETRIS-ZP-GAME-WON)
    (label no_tetris_win)

    ;; Trigger Staged VBlank Dirty-Row Copier starting at Row 0!
    (LDA #:imm 0)
    (STA #:zp ,TETRIS-ZP-DIRTY-ROW)

    ;; Check Top-Out Game Over: if locked at TETRIS-ZP-PIECE-Y < 3, set TETRIS-ZP-GAME-OVER = 1!
    (LDA #:zp ,TETRIS-ZP-PIECE-Y)
    (CMP #:imm 3)
    (BCC set_game_over)

    ;; Spawn Next Tetromino at top of well (X=4, Y=2, Rot=0)
    (LDA #:zp ,TETRIS-ZP-NEXT-ID)
    (STA #:zp ,TETRIS-ZP-PIECE-ID)
    (LDX #:zp ,TETRIS-ZP-SPAWN-IDX)
    (LDA #:absx spawn_cycle_table)
    (STA #:zp ,TETRIS-ZP-NEXT-ID)
    (INX)
    (TXA)
    (AND #:imm #x03)
    (STA #:zp ,TETRIS-ZP-SPAWN-IDX)
    (LDA #:imm 0)
    (STA #:zp ,TETRIS-ZP-PIECE-ROT)
    (LDA #:imm 4)
    (STA #:zp ,TETRIS-ZP-PIECE-X)
    (LDA #:imm 2)
    (STA #:zp ,TETRIS-ZP-PIECE-Y)
    (RTS)

    (label set_game_over)
    (LDA #:imm 1)
    (STA #:zp ,TETRIS-ZP-GAME-OVER)
    (RTS)

    ;; ========================================================================
    ;; Build Tetris OAM Buffer ($0200-$02FF)
    ;;   Slots 1..4 ($0204..$0213): Active Falling Tetromino (tile #x7B, attr #x02)
    ;;     Screen X = 96 + (piece_x + dx) * 8, Screen Y = 47 + (piece_y + dy) * 8
    ;;   Slots 5..8 ($0214..$0223): NEXT Preview Tetromino (tile #x7C, attr #x02)
    ;;     Placed inside authentic NEXT box at (X = 196..212, Y = 119..127)
    ;; ========================================================================
    (label build_tetris_oam)
    ;; 1. Active Tetromino (4 minoes at $0204..$0213):
    (LDA #:zp ,TETRIS-ZP-PIECE-ID)
    (ASL) (ASL)
    (ORA #:zp ,TETRIS-ZP-PIECE-ROT)
    (ASL) (ASL) (ASL)
    (TAX)
    (LDY #:imm 0)
    (label oam_active_loop)
    ;; Y coordinate = ((piece_y + dy) << 3) + 47
    (CLC)
    (LDA #:zp ,TETRIS-ZP-PIECE-Y)
    (ADC #:absx (+ tetromino_offset_table 1))
    (ASL) (ASL) (ASL)
    (CLC) (ADC #:imm 47)
    (STA #:absy #x0204)
    ;; Authentic Tetris white-centered mino Tile ID (#x7B)
    (LDA #:imm #x7B)
    (STA #:absy #x0205)
    ;; Sprite Palette 2 (#x02 = white/blue)
    (LDA #:imm #x02)
    (STA #:absy #x0206)
    ;; X coordinate = ((piece_x + dx) << 3) + 96
    (CLC)
    (LDA #:zp ,TETRIS-ZP-PIECE-X)
    (ADC #:absx tetromino_offset_table)
    (ASL) (ASL) (ASL)
    (CLC) (ADC #:imm 96)
    (STA #:absy #x0207)
    (INX) (INX)
    (INY) (INY) (INY) (INY)
    (CPY #:imm 16)
    (BNE oam_active_loop)

    ;; 2. NEXT Preview Tetromino (4 minoes at $0214..$0223, X = 196..212, Y = 119..127)
    (LDA #:zp ,TETRIS-ZP-NEXT-ID)
    (ASL) (ASL) (ASL) (ASL) (ASL) ; next_id * 32 (rot 0)
    (TAX)
    (LDY #:imm 0)
    (label oam_next_loop)
    (LDA #:absx (+ tetromino_offset_table 1))
    (ASL) (ASL) (ASL)
    (CLC) (ADC #:imm 119)
    (STA #:absy #x0214)
    ;; Authentic Tetris solid mino Tile ID (#x7C)
    (LDA #:imm #x7C)
    (STA #:absy #x0215)
    ;; Sprite Palette 2 (#x02)
    (LDA #:imm #x02)
    (STA #:absy #x0216)
    (LDA #:absx tetromino_offset_table)
    (ASL) (ASL) (ASL)
    (CLC) (ADC #:imm 196)
    (STA #:absy #x0217)
    (INX) (INX)
    (INY) (INY) (INY) (INY)
    (CPY #:imm 16)
    (BNE oam_next_loop)
    (RTS)

    ;; ========================================================================
    ;; VBlank NMI Handler (Staged Dirty-Row Stripe Copier: 2 rows = 20 B / NMI!)
    ;; ========================================================================
    (label nmi_handler)
    (PHA)
    (TXA)
    (PHA)
    (TYA)
    (PHA)

    (LDA #:imm #x00) (STA #:abs #x2003)
    (LDA #:imm #x02) (STA #:abs #x4014)

    ;; Update HUD LINES-000 low digit at $2075 (row 3 col 21)
    (BIT #:abs #x2002)
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #x75) (STA #:abs #x2006)
    (LDA #:zp ,TETRIS-ZP-LINES)
    (AND #:imm #x07)
    (STA #:abs #x2007)

    ;; Update HUD LEVEL 00 ones digit at $22BB (row 21 col 27)
    (BIT #:abs #x2002)
    (LDA #:imm #x22) (STA #:abs #x2006) (LDA #:imm #xBB) (STA #:abs #x2006)
    (LDA #:zp ,TETRIS-ZP-LEVEL)
    (AND #:imm #x07)
    (STA #:abs #x2007)

    ;; Update HUD SCORE 000000 hundreds digit at $213B (row 9 col 27)
    ;; and STATISTICS T-piece counter low digit at $216B (row 11 col 11) when LINES > 0
    (LDA #:zp ,TETRIS-ZP-LINES)
    (BEQ skip_hud_score_stat)
    (BIT #:abs #x2002)
    (LDA #:imm #x21) (STA #:abs #x2006) (LDA #:imm #x3B) (STA #:abs #x2006)
    (LDA #:zp ,TETRIS-ZP-SCORE)
    (AND #:imm #x07)
    (STA #:abs #x2007)

    (BIT #:abs #x2002)
    (LDA #:imm #x21) (STA #:abs #x2006) (LDA #:imm #x6B) (STA #:abs #x2006)
    (LDA #:zp ,TETRIS-ZP-LINES)
    (AND #:imm #x07)
    (STA #:abs #x2007)

    (BIT #:abs #x2002)
    (LDA #:imm #x22) (STA #:abs #x2006) (LDA #:imm #xBB) (STA #:abs #x2006)
    (LDA #:zp ,TETRIS-ZP-LEVEL)
    (AND #:imm #x07)
    (STA #:abs #x2007)
    (label skip_hud_score_stat)

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
    (LDA #:imm #x90) (STA #:abs #x2000)
    (LDA #:imm 0)    (STA #:abs #x2005) (STA #:abs #x2005)
    (LDA #:imm 1)    (STA #:zp #x0F)

    (PLA) (TAY)
    (PLA) (TAX)
    (PLA)
    (RTI)

    ;; Flush 10 bytes of well row `TETRIS-ZP-DIRTY-ROW` from $0400 to Nametable ($20CC + row*32)
    ;; Converts RAM byte 0 (empty cell) to #xEF (authentic Tetris empty playfield tile)
    (label flush_one_well_row_vram)
    (LDX #:zp ,TETRIS-ZP-DIRTY-ROW)
    (BIT #:abs #x2002)
    (LDA #:absx vblank_row_addr_hi)
    (STA #:abs #x2006)
    (LDA #:absx vblank_row_addr_lo)
    (STA #:abs #x2006)
    (LDA #:absx row10_table)
    (TAY)
    (LDX #:imm 10)
    (label copy_10_cols)
    (LDA #:absy ,TETRIS-WELL-RAM-BASE)
    (BNE write_well_tile)
    (LDA #:imm #xEF)
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

    ;; Deterministic 4-piece spawn cycle (I, I, I, O)
    (label spawn_cycle_table)
    (.byte 6 6 6 3)

    ;; PPU Nametable Addresses for Rows 0..19 of the 10x20 Well (Row r -> $20CC + r*32, rows 6..25 cols 12..21)
    (label vblank_row_addr_hi)
    (label well_row_vram_hi)
    (.byte #x20 #x20 #x21 #x21 #x21 #x21 #x21 #x21 #x21 #x21
           #x22 #x22 #x22 #x22 #x22 #x22 #x22 #x22 #x23 #x23)
    (label vblank_row_addr_lo)
    (label well_row_vram_lo)
    (.byte #xCC #xEC #x0C #x2C #x4C #x6C #x8C #xAC #xCC #xEC
           #x0C #x2C #x4C #x6C #x8C #xAC #xCC #xEC #x0C #x2C)

    ;; Authentic Nintendo NES Tetris Level 00 Palette ($3F00-$3F1F, 32 bytes)
    (label tetris_palette_table)
    (.byte #x0F #x30 #x12 #x16
           #x0F #x20 #x12 #x18
           #x0F #x30 #x21 #x12
           #x0F #x3C #x00 #x30
           #x0F #x35 #x15 #x22
           #x0F #x35 #x29 #x26
           #x0F #x30 #x21 #x12
           #x0F #x3C #x00 #x30)

    ;; 7 Tetrominoes x 4 Rotations x 4 Minoes (dx, dy signed byte pairs = 224 bytes):
    ;;   Piece 0: T, Piece 1: J, Piece 2: Z, Piece 3: O, Piece 4: S, Piece 5: L, Piece 6: I
    (.align 256)
    (label tetromino_offset_table)
    ;; Piece 0 (T): 4 rotations (Rot 2 = 4-wide horizontal bar for 10-col reach)
    (.byte -1  0   0  0   1  0   0 -1
            0 -1   0  0   1  0   0  1
           -1  0   0  0   1  0   2  0
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
    ;; Piece 3 (O): 4 rotations (bottom 2 minoes at dy=0, top 2 minoes at dy=-1)
    (.byte  0  0   1  0   0 -1   1 -1
            0  0   1  0   0 -1   1 -1
            0  0   1  0   0 -1   1 -1
            0  0   1  0   0 -1   1 -1)
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

    ;; Authentic Nintendo NES Tetris A-Type Level 00 Nametable 0 + Attribute Table ($2000-$23FF = 1,024 bytes)
    (.align 256)
    (label tetris_nt0_table)
    ;; Row 0 ($2000-$201F)
    (.byte 122 103 119 119 114 121 122 120 117 122 103 119 120 131 120 131
           119 135 103 120 115 135 112 113 103 135 120 117 122 114 122 103)
    ;; Row 1 ($2020-$203F)
    (.byte 114 131 135 119 135 103 120 115 135 114 131 135 120 121 121 122
           135 120 132 122 130 122 128 129 130 121 122 135 120 131 120 133)
    ;; Row 2 ($2040-$205F)
    (.byte 135 114 122 135 120 132 122 130 122 135 103  56  57  57  57  57
            57  57  57  57  57  57  58  56  57  57  57  57  57  57  58 135)
    ;; Row 3 ($2060-$207F)
    (.byte 103 119  56  57  57  57  57  57  57  58 119  59 255  21  18  23
            14  28  36   0   0   0  60  59 255 255 255 255 255 255  60 103)
    ;; Row 4 ($2080-$209F)
    (.byte 119 135  59  10  36  29  34  25  14  60 119  61  62  62  62  62
            62  62  62  62  62  62  63  59  29  24  25 255 255 255  60 119)
    ;; Row 5 ($20A0-$20BF)
    (.byte 128 122  61  62  62  62  62  62  62  63 135  48  49  49  49  49
            49  49  49  49  49  49  50  59   0   1   0   0   0   0  60 119)
    ;; Row 6 ($20C0-$20DF)
    (.byte 120 121 121 122 103 112 113 103 120 121 115  51 239 239 239 239
           239 239 239 239 239 239  52  59 255 255 255 255 255 255  60 135)
    ;; Row 7 ($20E0-$20FF)
    (.byte 121 122 120 121 131 128 129 130 121 122 135  51 239 239 239 239
           239 239 239 239 239 239  52  59  28  12  24  27  14 255  60 103)
    ;; Row 8 ($2100-$211F)
    (.byte 115  56  57  57  57  57  57  57  57  57  58  51 239 239 239 239
           239 239 239 239 239 239  52  59   0   0   0   0   0   0  60 130)
    ;; Row 9 ($2120-$213F)
    (.byte 119  59 105 106 107 108 109 110 111  95  60  51 239 239 239 239
           239 239 239 239 239 239  52  59 255 255 255 255 255 255  60 103)
    ;; Row 10 ($2140-$215F)
    (.byte 135  59 255 255 255 255 255 255 255 255  60  51 239 239 239 239
           239 239 239 239 239 239  52  61  62  62  62  62  62  62  63 119)
    ;; Row 11 ($2160-$217F)
    (.byte 122  59 255  64  65  66 255 255 255 255  60  51 239 239 239 239
           239 239 239 239 239 239  52 120 121 121 122 120 121 115 120 131)
    ;; Row 12 ($2180-$219F)
    (.byte 122  59 255  80  81  82   0   0   0 255  60  51 239 239 239 239
           239 239 239 239 239 239  52  48  49  49  49  49  50 135 103 120)
    ;; Row 13 ($21A0-$21BF)
    (.byte 122  59 255  73  74  75 255 255 255 255  60  51 239 239 239 239
           239 239 239 239 239 239  52  51  23  14  33  29  52 114 131 120)
    ;; Row 14 ($21C0-$21DF)
    (.byte 103  59 255  89  90  91   0   0   0 255  60  51 239 239 239 239
           239 239 239 239 239 239  52  51 255 255 255 255  52 135 114 122)
    ;; Row 15 ($21E0-$21FF)
    (.byte 119  59 255  70  71 255 255 255 255 255  60  51 239 239 239 239
           239 239 239 239 239 239  52  51 255 255 255 255  52 120 131 112)
    ;; Row 16 ($2200-$221F)
    (.byte 119  59 255  86  87  88   0   0   0 255  60  51 239 239 239 239
           239 239 239 239 239 239  52  51 255 255 255 255  52 114 122 128)
    ;; Row 17 ($2220-$223F)
    (.byte 135  59 255  96  97 255 255 255 255 255  60  51 239 239 239 239
           239 239 239 239 239 239  52  51 255 255 255 255  52 119 120 115)
    ;; Row 18 ($2240-$225F)
    (.byte 113  59 255  98  99 255   0   0   1 255  60  51 239 239 239 239
           239 239 239 239 239 239  52  53  54  54  54  54  55 135 103 119)
    ;; Row 19 ($2260-$227F)
    (.byte 129  59 255  67  68  69 255 255 255 255  60  51 239 239 239 239
           239 239 239 239 239 239  52  56  57  57  57  57  57  58 119 135)
    ;; Row 20 ($2280-$229F)
    (.byte 122  59 255  83  84  85   0   0   0 255  60  51 239 239 239 239
           239 239 239 239 239 239  52  59  21  14  31  14  21  60 119 120)
    ;; Row 21 ($22A0-$22BF)
    (.byte 122  59 255  76  77  78 255 255 255 255  60  51 239 239 239 239
           239 239 239 239 239 239  52  59 255 255   0   0 255  60 135 103)
    ;; Row 22 ($22C0-$22DF)
    (.byte 103  59 255  92  93  94   0   0   0 255  60  51 239 239 239 239
           239 239 239 239 239 239  52  61  62  62  62  62  62  63 120 133)
    ;; Row 23 ($22E0-$22FF)
    (.byte 131  59 255 255 255 255 255 255 255 255  60  51 239 239 239 239
           239 239 239 239 239 239  52 103 120 117 122 103 114 121 122 135)
    ;; Row 24 ($2300-$231F)
    (.byte 115  59 255 100 101 102   0   0   0 255  60  51 239 239 239 239
           239 239 239 239 239 239  52 116 122 135 120 133 135 103 120 121)
    ;; Row 25 ($2320-$233F)
    (.byte 119  59 255 255 255 255 255 255 255 255  60  51 239 239 239 239
           239 239 239 239 239 239  52 135 120 121 115 135 114 131 114 122)
    ;; Row 26 ($2340-$235F)
    (.byte 135  61  62  62  62  62  62  62  62  62  63  53  54  54  54  54
            54  54  54  54  54  54  55 103 112 113 135 103 135 120 131 103)
    ;; Row 27 ($2360-$237F)
    (.byte 103 103 120 117 122 114 121 122 103 120 115 120 115 103 114 122
           114 121 122 120 121 121 122 119 128 129 120 133 103 120 121 131)
    ;; Row 28 ($2380-$239F)
    (.byte 119 130 115 135 103 135 103 114 131 103 130 122 119 119 119 103
           135 103 112 113 114 122 103 128 122 120 115 135 119 120 121 121)
    ;; Row 29 ($23A0-$23BF)
    (.byte 128 122 135 120 132 122 119 135 120 132 122 103 135 119 135 119
           114 131 128 129 119 103 130 121 122 103 119 120 131 114 122 103)
    ;; Attribute Table 0 ($23C0-$23FF = 64 bytes)
    (.byte 255 255 255 255 255 255 255 255
           255 255 255 175 175 239 255 255
           191  47 207 170 170 238 255 255
           187  34 204 170 170 238 255 255
           187  34 204 170 170 238 255 255
           187  34 204 170 170 238 255 255
           251 242 252 250 250 254 255 255
            15  15  15  15  15  15  15  15)))
