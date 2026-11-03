#lang racket/base

;; ============================================================================
;; compiler/decompiled-smb.rkt
;; Authentic Decompiled Super Mario Bros. (World 1-1) 6502 PPU & Gameplay Engine
;;
;; Uses the exact commercial World 1-1 PPU state from
;; `assets/decompiled/smb_w1_1_ppu_state.json`:
;;   - 32-byte World 1-1 Palette (`#x22 #x29 #x1A #x0F ...`)
;;   - 1,024-byte Nametable 0 (`$2000-$23FF`: HUD `MARIO 000000 *00 WORLD 1-1 TIME 397`,
;;     clouds, hill, bushes, `?` Question Block at `$222A-$222B`/`$224A-$224B`,
;;     cracked ground `#xB4..#xB7`, and attribute table)
;;   - 1,024-byte Nametable 1 (`$2400-$27FF`: `?` blocks, bricks, Warp Pipes,
;;     Flagpole at col 11 (`#x2F` ball at row 9, `#x25` shaft at rows 10..20),
;;     ground, and attribute table)
;; ============================================================================

(require (for-syntax racket/base
                     racket/path)
         json
         racket/file
         racket/list
         racket/match
         racket/path
         "mos6502-assembler.rkt")

(provide
 MARIO-ZP-BUTTONS
 MARIO-ZP-PREV-BTN
 MARIO-ZP-NEW-BTN
 MARIO-ZP-FRAME-CNT
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
 MARIO-ZP-COIN-ANIM-Y
 MARIO-ZP-WON
 MARIO-ZP-VRAM-PENDING
 load-decompiled-smb-ppu-state
 emit-decompiled-mario-6502-program)

;; Zero-Page Layout ($0010-$0025) matching `compiler/nes-games-builder.rkt`:
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
(define MARIO-ZP-Y-PX         #x1A) ; 8.8 fixed-point Y pixel (ground = 176, visual Y = 192)
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

(define-syntax (get-smb-ppu-json-path stx)
  (datum->syntax
   stx
   (path->string
    (simplify-path
     (build-path (syntax-source stx) 'up 'up "assets" "decompiled" "smb_w1_1_ppu_state.json")))))

(define DEFAULT-SMB-PPU-JSON-PATH (string->path (get-smb-ppu-json-path)))

;; Load and patch the authentic commercial World 1-1 PPU state from JSON:
;;   - `palette`: 32 bytes (`$3F00-$3F1F`)
;;   - `nt0`: 1,024 bytes (`$2000-$23FF`) with `?` Question Block patched at
;;     row 17 cols 10..11 (`$222A-$222B` = `#x53 #x54`) and
;;     row 18 cols 10..11 (`$224A-$224B` = `#x55 #x56`) + attribute palette 3 at `$23E2`
;;   - `nt1`: 1,024 bytes (`$2400-$27FF`) with Flagpole patched at col 11
;;     (`#x2F` ball at row 9, `#x25` shaft at rows 10..20)
(define (load-decompiled-smb-ppu-state [json-path DEFAULT-SMB-PPU-JSON-PATH])
  (define raw (call-with-input-file json-path read-json))
  (define palette (hash-ref raw 'palette))
  (define nt0-vec (list->vector (hash-ref raw 'nt0)))
  (define nt1-vec (list->vector (hash-ref raw 'nt1)))

  ;; Patch 2x2 '?' Question Block into Nametable 0 at rows 17..18, cols 10..11:
  ;;   Row 17, col 10..11 -> $222A, $222B (offsets 554, 555) = #x53, #x54
  ;;   Row 18, col 10..11 -> $224A, $224B (offsets 586, 587) = #x55, #x56
  (vector-set! nt0-vec (+ (* 17 32) 10) #x53)
  (vector-set! nt0-vec (+ (* 17 32) 11) #x54)
  (vector-set! nt0-vec (+ (* 18 32) 10) #x55)
  (vector-set! nt0-vec (+ (* 18 32) 11) #x56)
  ;; Set 16x16 attribute table quadrants for rows 16..19, cols 10..11 ($23E2 = offset 994)
  ;; to Palette 3 (Gold/Brown Question Block: bits 2..3 = #x0C and bits 6..7 = #xC0 -> #xCC)
  (define attr-idx-qblock (+ 960 (* 4 8) 2))
  (vector-set! nt0-vec attr-idx-qblock
               (bitwise-ior (vector-ref nt0-vec attr-idx-qblock) #xCC))

  ;; Patch Flagpole into Nametable 1 at cols 12..13 (after clearing conflicting blocks in cols 8..17):
  ;;   - Clear rows 9..23, cols 8..17 to #x24 (blank sky) so bricks/? blocks do not overlap the pole
  ;;   - Row 9, cols 12..13  ($252C-$252D) = #x2F, #x3D (Flagpole Orb/Ball left & right halves)
  ;;   - Rows 10..23, cols 12..13          = #xA2, #xA3 (Flagpole Shaft left & right halves)
  ;;   - Rows 24..25, cols 12..13          = #x57, #x58 / #x59, #x5A (16x16 Hard Base Block on ground)
  (for* ([r (in-range 9 24)]
         [c (in-range 8 18)])
    (vector-set! nt1-vec (+ (* r 32) c) #x24))
  (vector-set! nt1-vec (+ (* 9 32) 12) #x2F)
  (vector-set! nt1-vec (+ (* 9 32) 13) #x3D)
  (for ([r (in-range 10 24)])
    (vector-set! nt1-vec (+ (* r 32) 12) #xA2)
    (vector-set! nt1-vec (+ (* r 32) 13) #xA3))
  (vector-set! nt1-vec (+ (* 24 32) 12) #x57)
  (vector-set! nt1-vec (+ (* 24 32) 13) #x58)
  (vector-set! nt1-vec (+ (* 25 32) 12) #x59)
  (vector-set! nt1-vec (+ (* 25 32) 13) #x5A)
  ;; Set NT1 attribute bytes for cols 8..15, rows 8..23 (attr rows 2..5, attr cols 2..3) to #x00 (Palette 0 Green)
  (for* ([ar (in-range 2 6)]
         [ac (in-list '(2 3))])
    (vector-set! nt1-vec (+ 960 (* ar 8) ac) #x00))
  ;; Set NT1 attribute byte for cols 12..15, rows 24..27 (attr row 6, attr col 3) to #x53
  ;; (top-left 16x16 base block = Palette 3 Gold/Brown, bottom rows 26..27 ground = Palette 1 Brown)
  (vector-set! nt1-vec (+ 960 (* 6 8) 3) #x53)

  (hasheq 'palette palette
          'nt0     (vector->list nt0-vec)
          'nt1     (vector->list nt1-vec)))

;; Split a 1,024-byte nametable list into 4 labeled 256-byte ROM pages
(define (emit-1024-byte-rom-table base-label page-labels byte-list)
  (unless (= (length byte-list) 1024)
    (error 'emit-1024-byte-rom-table "expected 1024 bytes for ~a, got ~a"
           base-label (length byte-list)))
  (define p0 (take byte-list 256))
  (define p1 (take (drop byte-list 256) 256))
  (define p2 (take (drop byte-list 512) 256))
  (define p3 (drop byte-list 768))
  `((.align 256)
    (label ,base-label)
    (label ,(first page-labels))
    (.byte ,@p0)
    (label ,(second page-labels))
    (.byte ,@p1)
    (label ,(third page-labels))
    (.byte ,@p2)
    (label ,(fourth page-labels))
    (.byte ,@p3)))

(define (emit-decompiled-mario-6502-program)
  (define ppu-state (load-decompiled-smb-ppu-state))
  (define pal-bytes (hash-ref ppu-state 'palette))
  (define nt0-bytes (hash-ref ppu-state 'nt0))
  (define nt1-bytes (hash-ref ppu-state 'nt1))

  `(;; ========================================================================
    ;; Decompiled Super Mario Bros. (World 1-1) in #lang boba-nes
    ;; Authentic Commercial World 1-1 Nametables, Palette, HUD & Standing Pose
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

    ;; ========================================================================
    ;; Boot Initialization: Upload Authentic World 1-1 Palette, NT0 & NT1
    ;; ========================================================================
    (label boot_init)
    (LDA #:imm #x00)
    (STA #:abs #x2000)
    (STA #:abs #x2001)

    ;; Clear Zero-Page ($00-$FF) and BSS ($0300-$03FF)
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

    ;; Upload exact 32-byte World 1-1 Palette ($3F00-$3F1F)
    (BIT #:abs #x2002)
    (LDA #:imm #x3F)
    (STA #:abs #x2006)
    (LDA #:imm #x00)
    (STA #:abs #x2006)
    (LDX #:imm 0)
    (label load_pal_m)
    (LDA #:absx smb_palette_table)
    (STA #:abs #x2007)
    (INX)
    (CPX #:imm 32)
    (BNE load_pal_m)

    ;; Copy 1,024-byte Authentic World 1-1 Nametable 0 (`smb_nt0_table`) to $2000-$23FF
    (BIT #:abs #x2002)
    (LDA #:imm #x20)
    (STA #:abs #x2006)
    (LDA #:imm #x00)
    (STA #:abs #x2006)
    (LDX #:imm 0)
    (label copy_nt0_p0)
    (LDA #:absx smb_nt0_p0)
    (STA #:abs #x2007)
    (INX)
    (BNE copy_nt0_p0)
    (label copy_nt0_p1)
    (LDA #:absx smb_nt0_p1)
    (STA #:abs #x2007)
    (INX)
    (BNE copy_nt0_p1)
    (label copy_nt0_p2)
    (LDA #:absx smb_nt0_p2)
    (STA #:abs #x2007)
    (INX)
    (BNE copy_nt0_p2)
    (label copy_nt0_p3)
    (LDA #:absx smb_nt0_p3)
    (STA #:abs #x2007)
    (INX)
    (BNE copy_nt0_p3)

    ;; Copy 1,024-byte Authentic World 1-1 Nametable 1 (`smb_nt1_table`) to $2400-$27FF
    (BIT #:abs #x2002)
    (LDA #:imm #x24)
    (STA #:abs #x2006)
    (LDA #:imm #x00)
    (STA #:abs #x2006)
    (LDX #:imm 0)
    (label copy_nt1_p0)
    (LDA #:absx smb_nt1_p0)
    (STA #:abs #x2007)
    (INX)
    (BNE copy_nt1_p0)
    (label copy_nt1_p1)
    (LDA #:absx smb_nt1_p1)
    (STA #:abs #x2007)
    (INX)
    (BNE copy_nt1_p1)
    (label copy_nt1_p2)
    (LDA #:absx smb_nt1_p2)
    (STA #:abs #x2007)
    (INX)
    (BNE copy_nt1_p2)
    (label copy_nt1_p3)
    (LDA #:absx smb_nt1_p3)
    (STA #:abs #x2007)
    (INX)
    (BNE copy_nt1_p3)

    ;; Initialize Mario & World 1-1 State:
    ;; Mario starts at World X = 40, logical Y = 176 (visual Y = 192 on row 26 ground), Goomba at X = 120
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
    (STA #:zp ,MARIO-ZP-VRAM-PENDING)
    (LDA #:imm 176)
    (STA #:zp ,MARIO-ZP-Y-PX)
    (LDA #:imm 1)
    (STA #:zp ,MARIO-ZP-ON-GROUND)
    (STA #:zp ,MARIO-ZP-GOOMBA-ALIVE)
    (LDA #:imm 120)
    (STA #:zp ,MARIO-ZP-GOOMBA-X)

    ;; Place OAM Sprite 0 at (X=88, Y=23, Tile=#xFF, Attr=#x23) overlapping the HUD Coin
    ;; at row 3 col 11 ($206B = #x2E) in `nt0` (`MARIO 000000 *00 WORLD 1-1 TIME 397`)
    (LDA #:imm 23)   (STA #:abs #x0200)
    (LDA #:imm #xFF) (STA #:abs #x0201)
    (LDA #:imm #x23) (STA #:abs #x0202)
    (LDA #:imm 88)   (STA #:abs #x0203)

    ;; Enable 2A03 APU Pulse 1 + Pulse 2 + Triangle
    (LDA #:imm #x07)
    (STA #:abs #x4015)

    ;; Reset PPU scroll latch and enable NMI + BG Pattern Table 1 ($1000) + Sprite Pattern Table 0 ($0000)
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

    ;; 1. Mid-Frame Sprite-0-Hit Raster Split at HUD Coin bottom scanline
    (label m_s0_clear)
    (BIT #:abs #x2002)
    (BVS m_s0_clear)
    (label m_s0_hit)
    (BIT #:abs #x2002)
    (BVC m_s0_hit)
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
    (CLC)
    (LDA #:zp ,MARIO-ZP-X-WORLD-LO)
    (ADC #:imm 3)
    (STA #:zp ,MARIO-ZP-X-WORLD-LO)
    (LDA #:zp ,MARIO-ZP-X-WORLD-HI)
    (ADC #:imm 0)
    (STA #:zp ,MARIO-ZP-X-WORLD-HI)
    (LDA #:zp ,MARIO-ZP-X-WORLD-LO)
    (SEC)
    (SBC #:zp ,MARIO-ZP-SCROLL-X)
    (CMP #:imm 104)
    (BCC update_screen_x)
    (LDA #:zp ,MARIO-ZP-SCROLL-NT)
    (BNE update_screen_x)
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
    (SEC)
    (LDA #:zp ,MARIO-ZP-X-WORLD-LO)
    (SBC #:zp ,MARIO-ZP-SCROLL-X)
    (STA #:zp ,MARIO-ZP-SCREEN-X)

    ;; 4. Jump Input ('A' button when ON_GROUND == 1)
    (LDA #:zp ,MARIO-ZP-NEW-BTN)
    (AND #:imm ,BTN-A)
    (BEQ step_vertical_physics)
    (LDA #:zp ,MARIO-ZP-ON-GROUND)
    (BEQ step_vertical_physics)
    (LDA #:imm 0)
    (STA #:zp ,MARIO-ZP-ON-GROUND)
    (STA #:zp ,MARIO-ZP-VY-SUB)
    (LDA #:imm #xFA)
    (STA #:zp ,MARIO-ZP-VY-PX)
    ;; Trigger 2A03 Pulse 1 Jump SFX
    (LDA #:imm #x9F) (STA #:abs #x4000)
    (LDA #:imm #x9A) (STA #:abs #x4001)
    (LDA #:imm #x90) (STA #:abs #x4002)
    (LDA #:imm #x28) (STA #:abs #x4003)

    ;; 5. 8.8 Fixed-Point Vertical Gravity & Subpixel Integration
    (label step_vertical_physics)
    (LDA #:zp ,MARIO-ZP-ON-GROUND)
    (BNE check_qblock_and_enemies)
    (CLC)
    (LDA #:zp ,MARIO-ZP-VY-SUB)
    (ADC #:imm #x60)
    (STA #:zp ,MARIO-ZP-VY-SUB)
    (LDA #:zp ,MARIO-ZP-VY-PX)
    (ADC #:imm #x00)
    (STA #:zp ,MARIO-ZP-VY-PX)
    (CLC)
    (LDA #:zp ,MARIO-ZP-Y-SUB)
    (ADC #:zp ,MARIO-ZP-VY-SUB)
    (STA #:zp ,MARIO-ZP-Y-SUB)
    (LDA #:zp ,MARIO-ZP-Y-PX)
    (ADC #:zp ,MARIO-ZP-VY-PX)
    (STA #:zp ,MARIO-ZP-Y-PX)

    ;; Check '?' Question Block Headbutt Collision when moving upward (VY_PX < 0, Y <= 138, X in 66..92)
    (LDA #:zp ,MARIO-ZP-VY-PX)
    (BPL check_ground_landing)
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
    (LDA #:zp ,MARIO-ZP-ON-GROUND)
    (BNE check_flagpole_win)
    (LDA #:zp ,MARIO-ZP-Y-PX)
    (CMP #:imm 150)
    (BCC check_flagpole_win)
    (LDA #:imm 0)
    (STA #:zp ,MARIO-ZP-GOOMBA-ALIVE)
    (LDA #:imm #xFD)
    (STA #:zp ,MARIO-ZP-VY-PX)
    (INC #:zp ,MARIO-ZP-SCORE)

    ;; 7. Check Flagpole Victory (World X >= 340 -> X_HI == 1 and X_LO >= 80, or X_LO >= 220)
    (label check_flagpole_win)
    (LDA #:zp ,MARIO-ZP-X-WORLD-HI)
    (BEQ check_nt0_flagpole)
    (LDA #:zp ,MARIO-ZP-X-WORLD-LO)
    (CMP #:imm 80)
    (BCC step_coin_anim)
    (JMP award_flagpole_win)

    (label check_nt0_flagpole)
    (LDA #:zp ,MARIO-ZP-X-WORLD-LO)
    (CMP #:imm 220)
    (BCC step_coin_anim)

    (label award_flagpole_win)
    (LDA #:zp ,MARIO-ZP-WON)
    (BNE step_coin_anim)
    (LDA #:imm 1)
    (STA #:zp ,MARIO-ZP-WON)
    (INC #:zp ,MARIO-ZP-SCORE)

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
    ;;   Slot 0 ($0200)    : Sprite 0 HUD Coin Anchor (X=88, Y=23, Tile=#xFF, Attr=#x23)
    ;;   Slots 1..4 ($0204): Small Mario 16x16 Metasprite at visual Y = MARIO-ZP-Y-PX + 16
    ;;                       Standing pose: TL=#x3A, TR=#x37, BL=#x4F, BR=#x4F (BR attr=#x40)
    ;;                       Walking/Jumping pose: #x32, #x33, #x34, #x35 (attr=#x00)
    ;;   Slots 5..8 ($0214): Goomba 16x16 Metasprite at visual Y = 192 (#x70..#x73, Pal 1)
    ;;   Slot 9 ($0224)    : Spinning Coin Sprite at visual Y = COIN_ANIM_Y + 16 (#x60, Pal 2)
    ;; ========================================================================
    (label build_mario_oam)
    ;; Keep Slot 0 anchored at (X=88, Y=23, Tile=#xFF, Attr=#x23) over HUD Coin ($206B = #x2E)
    (LDA #:imm 23)   (STA #:abs #x0200)
    (LDA #:imm #xFF) (STA #:abs #x0201)
    (LDA #:imm #x23) (STA #:abs #x0202)
    (LDA #:imm 88)   (STA #:abs #x0203)

    ;; Compute Mario visual Y = MARIO-ZP-Y-PX + 16 (176 + 16 = 192, resting on row 26 ground at Y=208)
    (LDA #:zp ,MARIO-ZP-Y-PX)
    (CLC)
    (ADC #:imm 16)
    (STA #:abs #x0204)
    (STA #:abs #x0208)
    (CLC)
    (ADC #:imm 8)
    (STA #:abs #x020C)
    (STA #:abs #x0210)

    ;; Choose Standing Pose vs Walking/Jumping Pose:
    ;; Standing when MARIO-ZP-ON-GROUND == 1 and no BTN-LEFT/BTN-RIGHT in MARIO-ZP-NEW-BTN / MARIO-ZP-BUTTONS
    (LDA #:zp ,MARIO-ZP-ON-GROUND)
    (BEQ mario_action_pose)
    (LDA #:zp ,MARIO-ZP-NEW-BTN)
    (ORA #:zp ,MARIO-ZP-BUTTONS)
    (AND #:imm ,(bitwise-ior BTN-LEFT BTN-RIGHT))
    (BNE mario_action_pose)

    ;; Authentic SMB1 Small Mario Standing Tiles: TL=#x3A, TR=#x37, BL=#x4F, BR=#x4F (H-Flip #x40)
    (LDA #:imm #x3A) (STA #:abs #x0205)
    (LDA #:imm #x37) (STA #:abs #x0209)
    (LDA #:imm #x4F) (STA #:abs #x020D)
    (STA #:abs #x0211)
    (LDA #:imm #x00)
    (STA #:abs #x0206)
    (STA #:abs #x020A)
    (STA #:abs #x020E)
    (LDA #:imm #x40)
    (STA #:abs #x0212)
    (JMP set_mario_oam_x)

    (label mario_action_pose)
    ;; Walking / Jumping Small Mario Tiles: #x32, #x33, #x34, #x35
    (LDA #:imm #x32) (STA #:abs #x0205)
    (LDA #:imm #x33) (STA #:abs #x0209)
    (LDA #:imm #x34) (STA #:abs #x020D)
    (LDA #:imm #x35) (STA #:abs #x0211)
    (LDA #:imm #x00)
    (STA #:abs #x0206)
    (STA #:abs #x020A)
    (STA #:abs #x020E)
    (STA #:abs #x0212)

    (label set_mario_oam_x)
    (LDA #:zp ,MARIO-ZP-SCREEN-X)
    (STA #:abs #x0207)
    (STA #:abs #x020F)
    (CLC)
    (ADC #:imm 8)
    (STA #:abs #x020B)
    (STA #:abs #x0213)

    ;; Emit Authentic Goomba 16x16 Metasprite (#x70, #x71, #x72, #x73) at visual Y = 192 ($0214..$0223)
    (LDA #:zp ,MARIO-ZP-GOOMBA-ALIVE)
    (BNE draw_goomba_oam)
    (LDA #:imm #xF8)
    (STA #:abs #x0214) (STA #:abs #x0218) (STA #:abs #x021C) (STA #:abs #x0220)
    (JMP draw_coin_oam)
    (label draw_goomba_oam)
    (LDA #:imm 192)
    (STA #:abs #x0214) (STA #:abs #x0218)
    (LDA #:imm 200)
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

    ;; Emit Authentic Spinning Coin Sprite (#x60) at visual Y = COIN_ANIM_Y + 16 ($0224..$0227)
    (label draw_coin_oam)
    (LDA #:zp ,MARIO-ZP-COIN-ANIM-Y)
    (BNE show_coin_spr)
    (LDA #:imm #xF8)
    (STA #:abs #x0224)
    (JMP done_mario_oam)
    (label show_coin_spr)
    (CLC)
    (ADC #:imm 16)
    (STA #:abs #x0224)
    (LDA #:imm #x60) (STA #:abs #x0225)
    (LDA #:imm #x02) (STA #:abs #x0226)
    (LDA #:imm 80)
    (SEC)
    (SBC #:zp ,MARIO-ZP-SCROLL-X)
    (STA #:abs #x0227)

    (label done_mario_oam)
    (RTS)

    ;; ========================================================================
    ;; VBlank NMI Handler (Grade Phi1 <= 2273 cyc, Grade L4 Scroll Restore)
    ;;   1. Executes $4014 OAMDMA (514 cyc)
    ;;   2. Updates HUD Score hundreds-digit at $2066 (row 3 col 6 in `nt0`) and
    ;;      HUD Coin ones-digit at $206E (row 3 col 14 in `nt0`)
    ;;   3. Updates bonked 2x2 '?' block at $222A..$222B & $224A..$224B -> #x57..#x5A
    ;;   4. Restores PPU scroll to (0, 0) & PPUCTRL = #$90 before RTI!
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

    ;; Update HUD Score hundreds-digit ($2066, row 3 col 6 of `000000`)
    (BIT #:abs #x2002)
    (LDA #:imm #x20)
    (STA #:abs #x2006)
    (LDA #:imm #x66)
    (STA #:abs #x2006)
    (LDA #:zp ,MARIO-ZP-SCORE)
    (AND #:imm #x07)
    (STA #:abs #x2007)

    ;; Update HUD Coin ones-digit ($206E, row 3 col 14 of `*x00`)
    (LDA #:imm #x20)
    (STA #:abs #x2006)
    (LDA #:imm #x6E)
    (STA #:abs #x2006)
    (LDA #:zp ,MARIO-ZP-COINS)
    (AND #:imm #x07)
    (STA #:abs #x2007)

    ;; If '?' Question Block was bonked, turn 2x2 block ($222A..$222B & $224A..$224B)
    ;; into SMB1's authentic 2x2 Empty Block (#x57, #x58 / #x59, #x5A)!
    (LDA #:zp ,MARIO-ZP-VRAM-PENDING)
    (BEQ nmi_restore_hud_scroll)
    (LDA #:imm 0)
    (STA #:zp ,MARIO-ZP-VRAM-PENDING)
    (BIT #:abs #x2002)
    (LDA #:imm #x22) (STA #:abs #x2006) (LDA #:imm #x2A) (STA #:abs #x2006)
    (LDA #:imm #x57) (STA #:abs #x2007)
    (LDA #:imm #x58) (STA #:abs #x2007)
    (LDA #:imm #x22) (STA #:abs #x2006) (LDA #:imm #x4A) (STA #:abs #x2006)
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

    ;; ========================================================================
    ;; Decompiled World 1-1 ROM Tables (Palette + 1,024B NT0 + 1,024B NT1)
    ;; ========================================================================
    (.align 256)
    (label smb_palette_table)
    (label mario_palette_table)
    (.byte ,@pal-bytes)

    ,@(emit-1024-byte-rom-table
       'smb_nt0_table
       '(smb_nt0_p0 smb_nt0_p1 smb_nt0_p2 smb_nt0_p3)
       nt0-bytes)

    ,@(emit-1024-byte-rom-table
       'smb_nt1_table
       '(smb_nt1_p0 smb_nt1_p1 smb_nt1_p2 smb_nt1_p3)
       nt1-bytes)))
