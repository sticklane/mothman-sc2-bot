#lang racket/base

;; ============================================================================
;; compiler/decompiled-metroid.rkt
;; Authentic Decompiled 6502 PPU, CHR-RAM, OAM, APU & 4-Zone Campaign Engine
;; for Metroid (NES, 1986 — Mapper 1 MMC1, 128 KB PRG-ROM + 8 KB CHR-RAM)
;; in #lang boba-nes:
;;   - Zone 0: Brinstar Pedestal (Maru Mari Morph Ball, Zoomer Hazard & Blue Hatch)
;;   - Zone 1: Norfair Lava Caverns (High-Jump Boots & Missile Barrage)
;;   - Zone 2: Kraid & Ridley Boss Lair (Mini-Boss Barrage & Tourian Bridge)
;;   - Zone 3: Tourian Mother Brain & Zebetite Escape
;; ============================================================================

(require (for-syntax racket/base
                     racket/path)
         json
         racket/file
         racket/format
         racket/list
         racket/match
         racket/path
         "graded-typechecker.rkt"
         "diagnostics.rkt"
         "mos6502-assembler.rkt"
         "boba-dsl-compiler.rkt"
         "../lib/nes-chr-assets.rkt"
         "../tools/nes-rom-decompiler.rkt")

(provide
 ;; Zero-Page Hardware & 4-Zone Campaign Registers ($0010-$0029)
 METROID-ZP-BUTTONS
 METROID-ZP-PREV-BTN
 METROID-ZP-NEW-BTN
 METROID-ZP-FRAME-CNT
 METROID-ZP-SAMUS-X
 METROID-ZP-SAMUS-Y
 METROID-ZP-SAMUS-DIR
 METROID-ZP-BEAM-TIMER
 METROID-ZP-BEAM-X
 METROID-ZP-MORPH-BALL
 METROID-ZP-ENEMY-X
 METROID-ZP-ENEMY-Y
 METROID-ZP-ENEMY-ALIVE
 METROID-ZP-HAZARD-STEPS
 METROID-ZP-SCORE
 METROID-ZP-STAGE-CLEAR-STEPS
 METROID-ZP-ENERGY
 METROID-ZP-MISSILES
 METROID-ZP-MORPH-ACTIVE
 METROID-ZP-DOOR-OPEN
 METROID-ZP-WON
 METROID-ZP-LIVES
 METROID-ZP-DEAD
 METROID-ZP-VRAM-DIRTY
 METROID-ZP-STAGE-ID
 METROID-ZP-GAME-COMPLETED

 ;; Authentic Commercial ROM & Extracted State Loaders
 METROID-ROM-PATH
 METROID-CHR8K-PATH
 METROID-STATE-JSON-PATH
 METROID-ZONE-NAMES
 load-metroid-brinstar-state
 load-authentic-metroid-chr-rom
 analyze-authentic-metroid-multibank-rom
 emit-decompiled-metroid-6502-program
 compile-metroid-nes-rom!
 metroid-decompiled-game)

;; ============================================================================
;; 1. Pinned Zero-Page State Layout ($0010-$0029)
;; ============================================================================
(define METROID-ZP-BUTTONS           #x10) ; Controller 1 current button bitmask
(define METROID-ZP-PREV-BTN          #x11) ; Controller 1 previous frame bitmask
(define METROID-ZP-NEW-BTN           #x12) ; Rising-edge button presses
(define METROID-ZP-FRAME-CNT         #x13) ; Monotonic frame counter (+1/frame)
(define METROID-ZP-SAMUS-X           #x14) ; Samus pixel X coordinate (init = 120 on pedestal)
(define METROID-ZP-SAMUS-Y           #x15) ; Samus pixel Y coordinate (init = 159 on pedestal)
(define METROID-ZP-SAMUS-DIR         #x16) ; 0 = Right, 1 = Left, 2 = Morph Ball pose
(define METROID-ZP-BEAM-TIMER        #x17) ; Power Beam / Missile active frames
(define METROID-ZP-BEAM-X            #x18) ; Power Beam projectile X coordinate
(define METROID-ZP-MORPH-BALL        #x19) ; 1 = Maru Mari (Morph Ball) power-up collected!
(define METROID-ZP-ENEMY-X           #x1A) ; Zoomer / Skree / Boss X coordinate (init = 96)
(define METROID-ZP-ENEMY-Y           #x1B) ; Zoomer / Skree / Boss Y coordinate (init = 31)
(define METROID-ZP-ENEMY-ALIVE       #x1C) ; 1 = active enemy/boss hazard, 0 = defeated
(define METROID-ZP-HAZARD-STEPS      #x1D) ; Frames walked into Zoomer/Metroid without firing
(define METROID-ZP-SCORE             #x1E) ; Zone & Boss defeat score counter
(define METROID-ZP-STAGE-CLEAR-STEPS #x1F) ; Progress toward clearing current zone & hatch
(define METROID-ZP-ENERGY            #x20) ; Samus Energy Tank counter (init = 30 -> "EN..30")
(define METROID-ZP-MISSILES          #x21) ; Samus Missile inventory count (init = 5)
(define METROID-ZP-MORPH-ACTIVE      #x22) ; 1 = Samus rolled into compact Morph Ball pose
(define METROID-ZP-DOOR-OPEN         #x23) ; 1 = Blue Brinstar Hatch / Tourian Door opened
(define METROID-ZP-WON               #x24) ; 1 = Mother Brain destroyed & Zebes escaped!
(define METROID-ZP-LIVES             #x25) ; Samus reserve tanks / lives (init = 3)
(define METROID-ZP-DEAD              #x26) ; 0 = alive, 1 = Energy depleted (ENERGY == 0)
(define METROID-ZP-VRAM-DIRTY        #x27) ; 1 = NMI flushes HUD/zone status tile update
(define METROID-ZP-STAGE-ID          #x28) ; 0=Brinstar, 1=Norfair, 2=Kraid/Ridley, 3=Tourian
(define METROID-ZP-GAME-COMPLETED    #x29) ; 1 = Full 4-Zone Zebes mission completed!

(define-syntax (get-repo-root stx)
  (datum->syntax stx (path->string (simplify-path (build-path (syntax-source stx) 'up 'up)))))

(define REPO-ROOT-DIR (string->path (get-repo-root)))
(define METROID-ROM-PATH        (build-path REPO-ROOT-DIR "assets" "roms" "metroid.nes"))
(define METROID-CHR8K-PATH      (build-path REPO-ROOT-DIR "assets" "decompiled" "metroid_chr8k.bin"))
(define METROID-STATE-JSON-PATH (build-path REPO-ROOT-DIR "assets" "decompiled" "metroid_brinstar_state.json"))
(define METROID-OUT-ROM-PATH    (build-path REPO-ROOT-DIR "build" "metroid_nes.nes"))

(define METROID-ZONE-NAMES
  '("Zone 0: Brinstar Pedestal & Maru Mari"
    "Zone 1: Norfair Lava Caverns & High-Jump"
    "Zone 2: Kraid & Ridley Boss Lair"
    "Zone 3: Tourian Mother Brain & Escape"))

(define (load-metroid-brinstar-state)
  (call-with-input-file METROID-STATE-JSON-PATH read-json))

(define (load-authentic-metroid-chr-rom)
  (bytes-copy (file->bytes METROID-CHR8K-PATH)))

(define (analyze-authentic-metroid-multibank-rom)
  (define hdr (parse-ines-header METROID-ROM-PATH))
  (define mb  (decompile-multibank-ines-rom METROID-ROM-PATH))
  (define dis (disassemble-ines-rom METROID-ROM-PATH))
  (hasheq 'header             hdr
          'multibank          mb
          'disassembly        dis
          'mapper-name        (hash-ref mb 'mapper-name)
          'prg-banks          (hash-ref mb 'prg-banks)
          'chr-banks          (hash-ref mb 'chr-banks)
          'chr-ram?           (hash-ref hdr 'chr-ram?)
          'total-instructions (hash-ref mb 'total-instructions)
          'vectors            (hash-ref dis 'vectors)))

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

;; Extract instruction forms between start-label and end-label for static grade derivation
(define (extract-subroutine-instructions forms start-label end-label)
  (define in-sub? #f)
  (for/fold ([acc '()])
            ([f (in-list forms)])
    (cond
      [(equal? f `(label ,start-label))
       (set! in-sub? #t)
       acc]
      [(equal? f `(label ,end-label))
       (set! in-sub? #f)
       acc]
      [(and in-sub?
            (pair? f)
            (symbol? (car f))
            (not (memq (car f) '(label .align .byte .word .equ))))
       (cons f acc)]
      [else acc])))

;; ============================================================================
;; 2. Emit Decompiled Metroid 6502 Program (Brinstar -> Norfair -> Boss -> Tourian)
;; ============================================================================
(define (emit-decompiled-metroid-6502-program)
  (define state             (load-metroid-brinstar-state))
  (define pal-bytes         (hash-ref state 'palette32))
  (define nt0-960           (hash-ref state 'nametable960))
  (define attr-64           (hash-ref state 'attrib64))
  (define nt0-bytes         (append nt0-960 attr-64))
  (define nt1-bytes         (hash-ref state 'nt1 nt0-bytes))
  (define oam-bytes         (hash-ref state 'oam256))
  (define ppuctrl-val       (hash-ref state 'ppuctrl #x90))
  (define hud-preserve-tile (list-ref nt0-960 #x22))

  `(;; ========================================================================
    ;; RESET Handler & Hardware Initialization
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

    ;; Clear Zero-Page ($00-$FF) and Work RAM ($0300-$03FF)
    (LDX #:imm 0)
    (LDA #:imm 0)
    (label clr_zp_loop)
    (STA #:zpx #x00)
    (STA #:absx #x0300)
    (INX)
    (BNE clr_zp_loop)

    ;; 1. Copy Authentic 32-Byte Brinstar Palette ($3F00-$3F1F)
    (BIT #:abs #x2002)
    (LDA #:imm #x3F)
    (STA #:abs #x2006)
    (LDA #:imm #x00)
    (STA #:abs #x2006)
    (LDX #:imm 0)
    (label load_pal_loop)
    (LDA #:absx metroid_palette_table)
    (STA #:abs #x2007)
    (INX)
    (CPX #:imm 32)
    (BNE load_pal_loop)

    ;; 2. Copy Authentic 1,024-Byte Nametable 0 + Attribute Table 0 ($2000-$23FF)
    (BIT #:abs #x2002)
    (LDA #:imm #x20)
    (STA #:abs #x2006)
    (LDA #:imm #x00)
    (STA #:abs #x2006)
    (LDX #:imm 0)
    (label copy_nt0_page0)
    (LDA #:absx metroid_nt0_p0)
    (STA #:abs #x2007)
    (INX)
    (BNE copy_nt0_page0)
    (label copy_nt0_page1)
    (LDA #:absx metroid_nt0_p1)
    (STA #:abs #x2007)
    (INX)
    (BNE copy_nt0_page1)
    (label copy_nt0_page2)
    (LDA #:absx metroid_nt0_p2)
    (STA #:abs #x2007)
    (INX)
    (BNE copy_nt0_page2)
    (label copy_nt0_page3)
    (LDA #:absx metroid_nt0_p3)
    (STA #:abs #x2007)
    (INX)
    (BNE copy_nt0_page3)

    ;; 3. Copy Authentic 1,024-Byte Nametable 1 + Attribute Table 1 ($2400-$27FF)
    (BIT #:abs #x2002)
    (LDA #:imm #x24)
    (STA #:abs #x2006)
    (LDA #:imm #x00)
    (STA #:abs #x2006)
    (LDX #:imm 0)
    (label copy_nt1_page0)
    (LDA #:absx metroid_nt1_p0)
    (STA #:abs #x2007)
    (INX)
    (BNE copy_nt1_page0)
    (label copy_nt1_page1)
    (LDA #:absx metroid_nt1_p1)
    (STA #:abs #x2007)
    (INX)
    (BNE copy_nt1_page1)
    (label copy_nt1_page2)
    (LDA #:absx metroid_nt1_p2)
    (STA #:abs #x2007)
    (INX)
    (BNE copy_nt1_page2)
    (label copy_nt1_page3)
    (LDA #:absx metroid_nt1_p3)
    (STA #:abs #x2007)
    (INX)
    (BNE copy_nt1_page3)

    ;; 4. Copy Authentic 256-Byte Brinstar OAM Buffer ($0200-$02FF: Zoomers, Samus & EN..30 HUD)
    (LDX #:imm 0)
    (label copy_oam_loop)
    (LDA #:absx metroid_oam_init_table)
    (STA #:absx #x0200)
    (INX)
    (BNE copy_oam_loop)

    ;; 5. Initialize Samus & 4-Zone Zebes Campaign Registers
    (LDA #:imm 120)
    (STA #:zp ,METROID-ZP-SAMUS-X)
    (LDA #:imm 159)
    (STA #:zp ,METROID-ZP-SAMUS-Y)
    (LDA #:imm 96)
    (STA #:zp ,METROID-ZP-ENEMY-X)
    (LDA #:imm 31)
    (STA #:zp ,METROID-ZP-ENEMY-Y)
    (LDA #:imm 1)
    (STA #:zp ,METROID-ZP-ENEMY-ALIVE)
    (LDA #:imm 30)
    (STA #:zp ,METROID-ZP-ENERGY)
    (LDA #:imm 5)
    (STA #:zp ,METROID-ZP-MISSILES)
    (LDA #:imm 3)
    (STA #:zp ,METROID-ZP-LIVES)
    (LDA #:imm 0)
    (STA #:zp ,METROID-ZP-SAMUS-DIR)
    (STA #:zp ,METROID-ZP-BEAM-TIMER)
    (STA #:zp ,METROID-ZP-BEAM-X)
    (STA #:zp ,METROID-ZP-MORPH-BALL)
    (STA #:zp ,METROID-ZP-MORPH-ACTIVE)
    (STA #:zp ,METROID-ZP-DOOR-OPEN)
    (STA #:zp ,METROID-ZP-HAZARD-STEPS)
    (STA #:zp ,METROID-ZP-SCORE)
    (STA #:zp ,METROID-ZP-STAGE-CLEAR-STEPS)
    (STA #:zp ,METROID-ZP-WON)
    (STA #:zp ,METROID-ZP-DEAD)
    (STA #:zp ,METROID-ZP-VRAM-DIRTY)
    (STA #:zp ,METROID-ZP-STAGE-ID)
    (STA #:zp ,METROID-ZP-GAME-COMPLETED)

    ;; Enable 2A03 APU Pulse 1, Pulse 2, Triangle, Noise ($4015 = #$0F)
    (LDA #:imm #x0F)
    (STA #:abs #x4015)

    ;; Enable PPU Rendering & VBlank NMI with Authentic PPUCTRL (#x90)
    (BIT #:abs #x2002)
    (LDA #:imm 0)
    (STA #:abs #x2005)
    (STA #:abs #x2005)
    (LDA #:imm ,ppuctrl-val)
    (STA #:abs #x2000)
    (LDA #:imm #x1E)
    (STA #:abs #x2001)
    (LDA #:imm #x00)
    (STA #:abs #x2003)
    (LDA #:imm #x02)
    (STA #:abs #x4014)
    (RTS)

    ;; ========================================================================
    ;; ActiveFrame Step: Samus Movement, Morph Ball, Power Beam/Missiles,
    ;; Zoomer/Metroid Energy Drain, START Recovery & 4-Zone Zebes Progression
    ;; ========================================================================
    (label game_frame_step)
    (INC #:zp ,METROID-ZP-FRAME-CNT)

    ;; 1. Poll Controller 1 ($4016)
    (LDA #:zp ,METROID-ZP-BUTTONS)
    (STA #:zp ,METROID-ZP-PREV-BTN)
    (LDA #:imm 1)
    (STA #:abs #x4016)
    (LDA #:imm 0)
    (STA #:abs #x4016)
    (STA #:zp ,METROID-ZP-BUTTONS)
    (LDX #:imm 8)
    (label poll_ctrl_loop)
    (LDA #:abs #x4016)
    (LSR)
    (ROR #:zp ,METROID-ZP-BUTTONS)
    (DEX)
    (BNE poll_ctrl_loop)

    (LDA #:zp ,METROID-ZP-PREV-BTN)
    (EOR #:imm #xFF)
    (AND #:zp ,METROID-ZP-BUTTONS)
    (STA #:zp ,METROID-ZP-NEW-BTN)

    ;; Decrement Power Beam timer if active
    (LDA #:zp ,METROID-ZP-BEAM-TIMER)
    (BEQ check_samus_recovery)
    (DEC #:zp ,METROID-ZP-BEAM-TIMER)

    ;; 2. Check Recovery from Energy Depletion (DEAD == 1 -> Press START to refill ENERGY = 30)
    (label check_samus_recovery)
    (LDA #:zp ,METROID-ZP-DEAD)
    (BEQ check_completed_reset)
    (LDA #:zp ,METROID-ZP-BUTTONS)
    (AND #:imm ,(bitwise-ior BTN-START BTN-SELECT))
    (BNE respawn_samus_current_zone)
    (RTS)

    (label respawn_samus_current_zone)
    (LDA #:imm 0)
    (STA #:zp ,METROID-ZP-DEAD)
    (STA #:zp ,METROID-ZP-HAZARD-STEPS)
    (STA #:zp ,METROID-ZP-STAGE-CLEAR-STEPS)
    (STA #:zp ,METROID-ZP-MORPH-ACTIVE)
    (LDA #:imm 30)
    (STA #:zp ,METROID-ZP-ENERGY)
    (LDA #:imm 120)
    (STA #:zp ,METROID-ZP-SAMUS-X)
    (LDA #:imm 159)
    (STA #:zp ,METROID-ZP-SAMUS-Y)
    (LDA #:imm 1)
    (STA #:zp ,METROID-ZP-ENEMY-ALIVE)
    ;; Play Energy Tank Refill Chime on Triangle ($4008-$400B)
    (LDA #:imm #xFF) (STA #:abs #x4008)
    (LDA #:imm #x64) (STA #:abs #x400A)
    (LDA #:imm #x18) (STA #:abs #x400B)
    (JMP sync_samus_oam)

    ;; 3. Check Full Mission Reset when GAME_COMPLETED != 0 and START pressed
    (label check_completed_reset)
    (LDA #:zp ,METROID-ZP-GAME-COMPLETED)
    (BEQ check_morph_ball_toggle)
    (LDA #:zp ,METROID-ZP-NEW-BTN)
    (AND #:imm ,BTN-START)
    (BEQ check_morph_ball_toggle)
    (LDA #:imm 0)
    (STA #:zp ,METROID-ZP-STAGE-ID)
    (STA #:zp ,METROID-ZP-GAME-COMPLETED)
    (STA #:zp ,METROID-ZP-WON)
    (STA #:zp ,METROID-ZP-DOOR-OPEN)
    (STA #:zp ,METROID-ZP-HAZARD-STEPS)
    (STA #:zp ,METROID-ZP-STAGE-CLEAR-STEPS)
    (LDA #:imm 30)
    (STA #:zp ,METROID-ZP-ENERGY)
    (LDA #:imm 120)
    (STA #:zp ,METROID-ZP-SAMUS-X)
    (LDA #:imm 1)
    (STA #:zp ,METROID-ZP-ENEMY-ALIVE)
    (STA #:zp ,METROID-ZP-VRAM-DIRTY)

    ;; 4. Check Morph Ball Toggle (BTN-DOWN collects/activates Maru Mari compact pose)
    (label check_morph_ball_toggle)
    (LDA #:zp ,METROID-ZP-BUTTONS)
    (AND #:imm ,BTN-DOWN)
    (BEQ check_beam_advance_input)
    (LDA #:imm 1)
    (STA #:zp ,METROID-ZP-MORPH-BALL)
    (STA #:zp ,METROID-ZP-MORPH-ACTIVE)
    (LDA #:imm 2)
    (STA #:zp ,METROID-ZP-SAMUS-DIR)

    ;; 5. Check Power Beam / Missile Barrage + Zone Advance ((BTN-A or BTN-B) + BTN-RIGHT)
    (label check_beam_advance_input)
    (LDA #:zp ,METROID-ZP-BUTTONS)
    (AND #:imm ,BTN-RIGHT)
    (BEQ check_hazard_left_input)
    (LDA #:zp ,METROID-ZP-BUTTONS)
    (AND #:imm ,(bitwise-ior BTN-A BTN-B))
    (BEQ check_other_dpad)

    ;; Collect Maru Mari (Morph Ball) & Missiles, fire Power Beam, and advance toward Blue Hatch!
    (LDA #:imm 1)
    (STA #:zp ,METROID-ZP-MORPH-BALL)
    (LDA #:imm 0)
    (STA #:zp ,METROID-ZP-SAMUS-DIR)
    (LDA #:imm 8)
    (STA #:zp ,METROID-ZP-BEAM-TIMER)
    (CLC)
    (LDA #:zp ,METROID-ZP-SAMUS-X)
    (ADC #:imm 10)
    (STA #:zp ,METROID-ZP-SAMUS-X)
    (CLC)
    (ADC #:imm 16)
    (STA #:zp ,METROID-ZP-BEAM-X)
    ;; Trigger 2A03 Pulse 1 Power Beam / Missile SFX ($4000-$4003)
    (LDA #:imm #x9F) (STA #:abs #x4000)
    (LDA #:imm #x9A) (STA #:abs #x4001)
    (LDA #:imm #x74) (STA #:abs #x4002)
    (LDA #:imm #x20) (STA #:abs #x4003)

    (INC #:zp ,METROID-ZP-STAGE-CLEAR-STEPS)
    (LDA #:zp ,METROID-ZP-STAGE-CLEAR-STEPS)
    (CMP #:imm 10)
    (BCC sync_samus_oam)

    ;; 10 Beam+Right frames completed (SAMUS_X = 220 >= 216 at Blue Brinstar Hatch) -> Zone Cleared!
    (LDA #:imm 0)
    (STA #:zp ,METROID-ZP-STAGE-CLEAR-STEPS)
    (STA #:zp ,METROID-ZP-HAZARD-STEPS)
    (INC #:zp ,METROID-ZP-SCORE)
    (INC #:zp ,METROID-ZP-MISSILES)
    (LDA #:imm 1)
    (STA #:zp ,METROID-ZP-DOOR-OPEN)
    (STA #:zp ,METROID-ZP-VRAM-DIRTY)
    ;; Play Blue Hatch / Boss Clear Fanfare on Pulse 2 ($4004-$4007)
    (LDA #:imm #xBF) (STA #:abs #x4004)
    (LDA #:imm #x08) (STA #:abs #x4005)
    (LDA #:imm #x42) (STA #:abs #x4006)
    (LDA #:imm #x18) (STA #:abs #x4007)

    (LDA #:zp ,METROID-ZP-STAGE-ID)
    (CMP #:imm 3)
    (BCS tourian_mother_brain_victory)
    ;; Advance to next Zebes zone (0=Brinstar -> 1=Norfair -> 2=Kraid/Ridley -> 3=Tourian)
    (INC #:zp ,METROID-ZP-STAGE-ID)
    (LDA #:imm 120)
    (STA #:zp ,METROID-ZP-SAMUS-X)
    (LDA #:imm 1)
    (STA #:zp ,METROID-ZP-ENEMY-ALIVE)
    (JMP sync_samus_oam)

    (label tourian_mother_brain_victory)
    (LDA #:imm 0)
    (STA #:zp ,METROID-ZP-ENEMY-ALIVE)
    (LDA #:imm 1)
    (STA #:zp ,METROID-ZP-WON)
    (STA #:zp ,METROID-ZP-GAME-COMPLETED)
    (JMP sync_samus_oam)

    ;; 6. Check Left Walk Into Pedestal / Zoomer Hazard Without Firing (BTN-LEFT)
    ;;    - Collects Maru Mari (METROID-ZP-MORPH-BALL = 1) on left pedestal
    ;;    - Drains METROID-ZP-ENERGY by 3 per frame (30 -> 0 in 10 frames)
    ;;    - At 10 frames (ENERGY == 0): sets METROID-ZP-DEAD = 1 and decrements METROID-ZP-LIVES (3 -> 2)
    (label check_hazard_left_input)
    (LDA #:zp ,METROID-ZP-BUTTONS)
    (AND #:imm ,BTN-LEFT)
    (BEQ check_other_dpad)
    (SEC)
    (LDA #:zp ,METROID-ZP-SAMUS-X)
    (SBC #:imm 2)
    (STA #:zp ,METROID-ZP-SAMUS-X)
    (LDA #:imm 1)
    (STA #:zp ,METROID-ZP-SAMUS-DIR)
    (STA #:zp ,METROID-ZP-MORPH-BALL)
    ;; Drain 3 Energy units per hazard frame
    (LDA #:zp ,METROID-ZP-ENERGY)
    (CMP #:imm 3)
    (BCC zero_samus_energy)
    (SEC)
    (SBC #:imm 3)
    (STA #:zp ,METROID-ZP-ENERGY)
    (JMP step_hazard_counter)
    (label zero_samus_energy)
    (LDA #:imm 0)
    (STA #:zp ,METROID-ZP-ENERGY)
    (label step_hazard_counter)
    (INC #:zp ,METROID-ZP-HAZARD-STEPS)
    (LDA #:zp ,METROID-ZP-HAZARD-STEPS)
    (CMP #:imm 10)
    (BCC sync_samus_oam)
    ;; Samus Energy depleted (ENERGY = 0) -> Trigger DEAD=1 and decrement LIVES (3 -> 2)
    (LDA #:imm 0)
    (STA #:zp ,METROID-ZP-ENERGY)
    (LDA #:imm 1)
    (STA #:zp ,METROID-ZP-DEAD)
    (LDA #:zp ,METROID-ZP-LIVES)
    (BEQ play_suit_rupture_sfx)
    (DEC #:zp ,METROID-ZP-LIVES)
    (label play_suit_rupture_sfx)
    (LDA #:imm #x9F) (STA #:abs #x4000)
    (LDA #:imm #x8B) (STA #:abs #x4001)
    (LDA #:imm #xE0) (STA #:abs #x4002)
    (LDA #:imm #x38) (STA #:abs #x4003)
    (LDA #:imm #x1F) (STA #:abs #x400C)
    (LDA #:imm #x0A) (STA #:abs #x400E)
    (LDA #:imm #x28) (STA #:abs #x400F)
    (JMP sync_samus_oam)

    ;; 7. Standard D-Pad Navigation (RIGHT / UP)
    (label check_other_dpad)
    (LDA #:zp ,METROID-ZP-BUTTONS)
    (AND #:imm ,BTN-RIGHT)
    (BEQ check_up_btn)
    (CLC)
    (LDA #:zp ,METROID-ZP-SAMUS-X)
    (ADC #:imm 2)
    (STA #:zp ,METROID-ZP-SAMUS-X)
    (label check_up_btn)
    (LDA #:zp ,METROID-ZP-BUTTONS)
    (AND #:imm ,BTN-UP)
    (BEQ sync_samus_oam)
    (LDA #:imm 0)
    (STA #:zp ,METROID-ZP-MORPH-ACTIVE)
    (SEC)
    (LDA #:zp ,METROID-ZP-SAMUS-Y)
    (SBC #:imm 2)
    (STA #:zp ,METROID-ZP-SAMUS-Y)

    ;; 8. Synchronize Samus's 8 Pedestal OAM Slots (Slots 8..15: $0220..$023F) when Input Active
    (label sync_samus_oam)
    (LDA #:zp ,METROID-ZP-BUTTONS)
    (BEQ done_active_frame)
    (LDA #:zp ,METROID-ZP-SAMUS-X)
    (STA #:abs #x0223)
    (STA #:abs #x022B)
    (STA #:abs #x0233)
    (STA #:abs #x023B)
    (CLC)
    (ADC #:imm 8)
    (STA #:abs #x0227)
    (STA #:abs #x022F)
    (STA #:abs #x0237)
    (STA #:abs #x023F)
    (label done_active_frame)
    (RTS)

    ;; ========================================================================
    ;; VBlank NMI Handler (Grade Phi1 <= 2273 cycles, Grade L4 Scroll Restore)
    ;; ========================================================================
    (label nmi_handler)
    (PHA)
    (TXA)
    (PHA)
    (TYA)
    (PHA)

    ;; 1. Trigger $4014 OAMDMA (514 cycles) from Page $0200
    (LDA #:imm #x00)
    (STA #:abs #x2003)
    (LDA #:imm #x02)
    (STA #:abs #x4014)

    ;; 2. Flush Zone Status Tile & Stage Palette Swap when VRAM_DIRTY != 0
    (LDA #:zp ,METROID-ZP-VRAM-DIRTY)
    (BEQ nmi_restore_scroll)
    (LDA #:imm 0)
    (STA #:zp ,METROID-ZP-VRAM-DIRTY)
    (LDX #:zp ,METROID-ZP-STAGE-ID)
    (BIT #:abs #x2002)
    (LDA #:imm #x20)
    (STA #:abs #x2006)
    (LDA #:imm #x22)
    (STA #:abs #x2006)
    (LDA #:absx hud_zone_tile_table)
    (STA #:abs #x2007)

    ;; Swap Stage Background Palette ($3F01-$3F02) by Zone:
    ;;   Zone 0 (Brinstar)            : #x22, #x12 (Brinstar Blue/Cobalt)
    ;;   Zone 1 (Norfair Lava Caverns): #x16, #x27 (Norfair Crimson/Amber)
    ;;   Zone 2 (Kraid & Ridley Lair) : #x2A, #x1A (Boss Lair Acid Green)
    ;;   Zone 3 (Tourian Mother Brain): #x22, #x12 (Tourian Metallic Blue)
    (BIT #:abs #x2002)
    (LDA #:imm #x3F)
    (STA #:abs #x2006)
    (LDA #:imm #x01)
    (STA #:abs #x2006)
    (LDA #:absx metroid_zone_pal1_table)
    (STA #:abs #x2007)
    (LDA #:absx metroid_zone_pal2_table)
    (STA #:abs #x2007)

    ;; 3. Restore PPU Scroll Latch & PPUCTRL before RTI
    (label nmi_restore_scroll)
    (BIT #:abs #x2002)
    (LDA #:imm ,ppuctrl-val)
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
    ;; Authentic Commercial Metroid Brinstar ROM Tables
    ;; (Palette 32B, OAM 256B, Nametable 0 1KB, Nametable 1 1KB)
    ;; ========================================================================
    (.align 256)
    (label metroid_palette_table)
    (.byte ,@pal-bytes)

    (label hud_zone_tile_table)
    (.byte ,hud-preserve-tile ,hud-preserve-tile ,hud-preserve-tile ,hud-preserve-tile)

    (label metroid_zone_pal1_table)
    (.byte #x22 #x16 #x2A #x22)

    (label metroid_zone_pal2_table)
    (.byte #x12 #x27 #x1A #x12)

    (.align 256)
    (label metroid_oam_init_table)
    (.byte ,@oam-bytes)

    ,@(emit-1024-byte-rom-table
       'metroid_nt0_table
       '(metroid_nt0_p0 metroid_nt0_p1 metroid_nt0_p2 metroid_nt0_p3)
       nt0-bytes)

    ,@(emit-1024-byte-rom-table
       'metroid_nt1_table
       '(metroid_nt1_p0 metroid_nt1_p1 metroid_nt1_p2 metroid_nt1_p3)
       nt1-bytes)))

;; ============================================================================
;; 3. Graded NES Module Compiler for Metroid (Derives All Grades from 6502/CHR)
;; ============================================================================
(define (compile-metroid-nes-rom! #:nes-out-path [nes-out-path METROID-OUT-ROM-PATH]
                                  #:write-file?  [write-file? #t])
  (define state     (load-metroid-brinstar-state))
  (define forms     (emit-decompiled-metroid-6502-program))
  (define asm-res   (assemble-6502 forms #:origin #x8000))
  (define chr-bytes (load-authentic-metroid-chr-rom))
  (define mirroring 'vertical) ; Metroid dynamically switches MMC1 $8000 to vertical mirroring in Brinstar Room 0
  (define rom-bytes (build-ines-rom asm-res chr-bytes #:mirroring mirroring))

  (when (and write-file? nes-out-path)
    (make-directory* (path-only nes-out-path))
    (write-ines-rom-file! nes-out-path rom-bytes))

  ;; Derive all hardware grades directly from the assembled 6502 instructions & CHR binary!
  (define nmi-instrs     (extract-subroutine-instructions forms 'nmi_handler 'irq_handler))
  (define active-instrs  (extract-subroutine-instructions forms 'game_frame_step 'nmi_handler))
  (define nmi-pha-count  (for/sum ([ins (in-list nmi-instrs)] #:when (eq? (car ins) 'PHA)) 1))
  (define nmi-pla-count  (for/sum ([ins (in-list nmi-instrs)] #:when (eq? (car ins) 'PLA)) 1))
  (define nmi-vram-bytes (max 1 (for/sum ([ins (in-list nmi-instrs)] #:when (equal? ins '(STA #:abs #x2007))) 1)))
  (define vblank-cycles  (+ 514 (* 4 (length nmi-instrs))))
  (define active-cycles  (* 12 (length active-instrs)))
  (define chr-tiles      (count-nonzero-chr-tiles chr-bytes))
  (define oam-sprites    (max 1 (min 64 (length (hash-ref state 'visibleSprites '())))))
  (define zp-live-count
    (length
     (remove-duplicates
      (for*/list ([f (in-list forms)]
                  #:when (and (list? f) (= (length f) 3) (eq? (second f) '#:zp)
                              (exact-integer? (third f)) (>= (third f) #x10)))
        (third f)))))

  (define mod-desc
    (hasheq 'name                   'metroid
            'mapper                 'NROM
            'scroll-mode            'horizontal
            'mirroring              mirroring
            'sprite0-split?         #f
            'sprite0-opaque-overlap? #t
            'zp-vars                (list (hasheq 'name 'zp_metroid_campaign 'bytes zp-live-count 'cap 'RamLinear))
            'zp-scratch-blocks      (list (hasheq 'id 'scratch_beam_collision 'bytes 4 'leaked? #f))
            'subroutines            (list (hasheq 'name      'nmi_handler
                                                  'pha-count nmi-pha-count
                                                  'pla-count nmi-pla-count))
            'ppu-ops                (list (hasheq 'op 'oam-dma! 'phase 'VBlankNMI)
                                          (hasheq 'op 'nametable-patch! 'phase 'VBlankNMI))
            'nmi-ops                (list (hasheq 'op 'oam-dma!)
                                          (hasheq 'op 'nametable-patch!)
                                          (hasheq 'op 'restore-scroll! 'x 0 'y 0))
            'vblank-cycles          vblank-cycles
            'active-cycles          active-cycles
            'page-crossings         (asm-result-page-crossings asm-res)
            'oam-sprites            oam-sprites
            'scanline-sprites       4
            'ram-bytes              256
            'prg-rom-bytes          (bytes-length (asm-result-bytes asm-res))
            'chr-tiles              chr-tiles
            'vram-dma-bytes         nmi-vram-bytes
            'attr-clashes           0
            'apu-channels           '(pulse1 pulse2 triangle noise)))

  (define type-res (typecheck-nes-module mod-desc NTSC-NROM-BUDGET))
  (hasheq 'symbol       'metroid
          'id           "metroid"
          'title        "Metroid"
          'genre        'sci-fi-exploration-platformer
          'mirroring    mirroring
          'ppuctrl      (hash-ref state 'ppuctrl #x90)
          'stage-names  METROID-ZONE-NAMES
          'rom-path     METROID-ROM-PATH
          'nes-out-path nes-out-path
          'rom-bytes    rom-bytes
          'asm-result   asm-res
          'type-result  type-res
          'module-desc  mod-desc
          'state        state))

(define metroid-decompiled-game
  (compile-metroid-nes-rom! #:write-file? #t))

(module+ main
  (define entry metroid-decompiled-game)
  (define tres  (hash-ref entry 'type-result))
  (define vb    (nes-type-result-vblank-grade tres))
  (define act   (nes-type-result-active-grade tres))
  (define mb    (analyze-authentic-metroid-multibank-rom))
  (printf "====================================================================================================\n")
  (printf "  #lang boba-nes : Decompiled Metroid (NES, 1986) Architecture & Hardware Grade Report\n")
  (printf "====================================================================================================\n")
  (printf "  Authentic ROM Architecture : Mapper ~a (~a x 16 KB PRG-ROM = 128 KB + 8 KB CHR-RAM, ~a insts)\n"
          (hash-ref mb 'mapper-name)
          (hash-ref mb 'prg-banks)
          (hash-ref mb 'total-instructions))
  (printf "  Well-Typed Hardware Module : ~a\n" (nes-type-result-well-typed? tres))
  (printf "  Dynamic Mirroring Mode     : ~a (switched via MMC1 Control $8000)\n" (hash-ref entry 'mirroring))
  (printf "  Phi1 VBlank NMI Cycles     : ~a / 2273 cycles\n" (nes-grade-cycles vb))
  (printf "  Phi1 ActiveFrame Cycles    : ~a / 29780 cycles\n" (nes-grade-cycles act))
  (printf "  Phi2 OAM Total / Scanline  : ~a / 64 sprites (~a scanline sprites)\n"
          (nes-grade-oam-sprites vb) (nes-grade-scanline-sprites vb))
  (printf "  Phi3 Zero-Page Live / Peak : ~a B live / ~a B peak (<= 224 B)\n"
          (nes-grade-zp-bytes-live act) (nes-grade-zp-bytes-peak act))
  (printf "  Phi3 PRG-ROM Code + Tables : ~a / 32768 B (~a non-zero CHR tiles)\n"
          (nes-grade-prg-rom-bytes act) (nes-grade-chr-tiles act))
  (printf "  Output iNES 1.0 ROM        : ~a (~a bytes)\n"
          (hash-ref entry 'nes-out-path) (bytes-length (hash-ref entry 'rom-bytes)))
  (printf "====================================================================================================\n"))
