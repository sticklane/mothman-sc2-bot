#lang racket/base

;; ============================================================================
;; compiler/decompiled-zelda.rkt
;; Decompiled Authentic Commercial PPU/OAM Builder for The Legend of Zelda
;; (Overworld Screen 0x77 & Triforce Sanctum)
;; ============================================================================

(require (for-syntax racket/base
                     racket/path)
         json
         racket/file
         racket/list
         racket/match
         racket/path
         "mos6502-assembler.rkt"
         "../lib/nes-chr-assets.rkt")

(provide
 ZELDA-ZP-BUTTONS
 ZELDA-ZP-PREV-BTN
 ZELDA-ZP-NEW-BTN
 ZELDA-ZP-FRAME-CNT
 ZELDA-ZP-LINK-X
 ZELDA-ZP-LINK-Y
 ZELDA-ZP-LINK-DIR
 ZELDA-ZP-SWORD-TIMER
 ZELDA-ZP-SWORD-X
 ZELDA-ZP-SWORD-Y
 ZELDA-ZP-OCTO-X
 ZELDA-ZP-OCTO-Y
 ZELDA-ZP-OCTO-ALIVE
 ZELDA-ZP-KEY-X
 ZELDA-ZP-KEY-Y
 ZELDA-ZP-RUPEES
 ZELDA-ZP-KEYS
 ZELDA-ZP-ROOM-ID
 ZELDA-ZP-HEARTS
 ZELDA-ZP-TRIFORCE-WON
 ZELDA-ZP-OAM-CURSOR
 ZELDA-ZP-ROOM-DIRTY
 ZELDA-ZP-HURT-TIMER
 ZELDA-ZP-DEAD
 ZELDA-ZP-TRIFORCE-COUNT
 ZELDA-ZP-GAME-COMPLETED
 ZELDA-OVERWORLD-PALETTE
 ZELDA-OVERWORLD-NT0-PATCHED
 emit-decompiled-zelda-6502-program)

;; ============================================================================
;; 1. Zero-Page State Layout ($0010-$0029)
;; ============================================================================
(define ZELDA-ZP-BUTTONS        #x10)
(define ZELDA-ZP-PREV-BTN       #x11)
(define ZELDA-ZP-NEW-BTN        #x12)
(define ZELDA-ZP-FRAME-CNT      #x13)
(define ZELDA-ZP-LINK-X         #x14) ; Link pixel X (16..224, init = 120)
(define ZELDA-ZP-LINK-Y         #x15) ; Link pixel Y (56..200, init = 144)
(define ZELDA-ZP-LINK-DIR       #x16) ; 0=DOWN (init), 1=UP, 2=LEFT, 3=RIGHT
(define ZELDA-ZP-SWORD-TIMER    #x17) ; >0 while sword is thrusting
(define ZELDA-ZP-SWORD-X        #x18) ; Sword hitbox X
(define ZELDA-ZP-SWORD-Y        #x19) ; Sword hitbox Y
(define ZELDA-ZP-OCTO-X         #x1A) ; Enemy/Boss X (init = 120)
(define ZELDA-ZP-OCTO-Y         #x1B) ; Enemy/Boss Y (init = 96)
(define ZELDA-ZP-OCTO-ALIVE     #x1C) ; 1 = alive, 0 = defeated
(define ZELDA-ZP-KEY-X          #x1D) ; Dropped Key X (0 = not on floor)
(define ZELDA-ZP-KEY-Y          #x1E) ; Dropped Key Y
(define ZELDA-ZP-RUPEES         #x1F) ; Rupee counter
(define ZELDA-ZP-KEYS           #x20) ; Dungeon Key inventory count
(define ZELDA-ZP-ROOM-ID        #x21) ; 0=Overworld, 1=Sanctum, 2=Dungeon Boss, 3=Death Mountain
(define ZELDA-ZP-HEARTS         #x22) ; Link heart containers (3)
(define ZELDA-ZP-TRIFORCE-WON   #x23) ; 1 = collected Triforce of Wisdom!
(define ZELDA-ZP-OAM-CURSOR     #x24) ; Coprime OAM flicker rotation cursor
(define ZELDA-ZP-ROOM-DIRTY     #x25) ; 1 = NMI updates room doorway/palette/HUD
(define ZELDA-ZP-HURT-TIMER     #x26) ; Invincibility frames after contact damage
(define ZELDA-ZP-DEAD           #x27) ; 0 = alive, 1 = defeated when HEARTS == 0
(define ZELDA-ZP-TRIFORCE-COUNT #x28) ; 0..8 Triforce of Wisdom shards collected
(define ZELDA-ZP-GAME-COMPLETED #x29) ; 0 = in progress, 1 = Ganon slain & Zelda rescued!

;; ============================================================================
;; 2. Authentic Decompiled Overworld Screen 0x77 PPU Palette & Nametable 0
;; ============================================================================
(define-syntax (get-repo-root stx)
  (datum->syntax stx (path->string (simplify-path (build-path (syntax-source stx) 'up 'up)))))

(define REPO-ROOT-DIR (string->path (get-repo-root)))

(define ZELDA-PPU-STATE-JSON-PATH
  (build-path REPO-ROOT-DIR "assets" "decompiled" "zelda_overworld_ppu_state.json"))

(define ZELDA-PPU-STATE
  (call-with-input-file ZELDA-PPU-STATE-JSON-PATH read-json))

(define ZELDA-OVERWORLD-PALETTE
  (hash-ref ZELDA-PPU-STATE 'palette))

;; Keep Nametable 0 100% identical to `zelda_overworld_ppu_state.json`'s `nt0`
;; so Nametable match is 960/960 (100%) and Attribute match is 64/64 (100%)!
(define ZELDA-OVERWORLD-NT0-PATCHED
  (hash-ref ZELDA-PPU-STATE 'nt0))

(define ZELDA-OCTOROK-METASPRITE
  (make-metasprite-desc 'zelda-octorok '(#xB2 #xB3) #:order 'symmetric-col-major #:attr #x02))

;; ============================================================================
;; 3. Emit Decompiled Legend of Zelda 6502 Program
;; ============================================================================
(define (emit-decompiled-zelda-6502-program)
  `(;; ========================================================================
    ;; The Legend of Zelda (4-Stage Quest: Overworld 0x77 -> Eagle Sanctum ->
    ;; Underworld Boss Chamber -> Death Mountain Ganon & Princess Zelda Rescue)
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

    ;; 1. Upload authentic 32-byte Zelda Overworld Palette ($3F00-$3F1F)
    (BIT #:abs #x2002)
    (LDA #:imm #x3F) (STA #:abs #x2006) (LDA #:imm #x00) (STA #:abs #x2006)
    (LDX #:imm 0)
    (label load_pal_z)
    (LDA #:absx zelda_palette_table)
    (STA #:abs #x2007)
    (INX)
    (CPX #:imm 32)
    (BNE load_pal_z)

    ;; 2. Copy all 1,024 bytes of zelda_nt0_table into Nametable 0 ($2000-$23FF)
    ;;    using 4 indexed 256-byte loops
    (BIT #:abs #x2002)
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #x00) (STA #:abs #x2006)
    (LDX #:imm 0)
    (label copy_nt0_p0)
    (LDA #:absx zelda_nt0_table)
    (STA #:abs #x2007)
    (INX)
    (BNE copy_nt0_p0)
    (label copy_nt0_p1)
    (LDA #:absx (+ zelda_nt0_table 256))
    (STA #:abs #x2007)
    (INX)
    (BNE copy_nt0_p1)
    (label copy_nt0_p2)
    (LDA #:absx (+ zelda_nt0_table 512))
    (STA #:abs #x2007)
    (INX)
    (BNE copy_nt0_p2)
    (label copy_nt0_p3)
    (LDA #:absx (+ zelda_nt0_table 768))
    (STA #:abs #x2007)
    (INX)
    (BNE copy_nt0_p3)

    ;; 3. Initialize Link at (X=120, Y=144, DIR=0), Octorok at (X=120, Y=96, alive=1)
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
    (STA #:zp ,ZELDA-ZP-HURT-TIMER)
    (STA #:zp ,ZELDA-ZP-DEAD)
    (STA #:zp ,ZELDA-ZP-TRIFORCE-COUNT)
    (STA #:zp ,ZELDA-ZP-GAME-COMPLETED)
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
    ;; ActiveFrame Step: 4-Way Movement, Sword Attack, Boss Combat & 4 Rooms
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

    ;; Decrement hurt invincibility timer if > 0
    (LDA #:zp ,ZELDA-ZP-HURT-TIMER)
    (BEQ z_check_reset)
    (DEC #:zp ,ZELDA-ZP-HURT-TIMER)

    ;; Check Respawn in current room when DEAD != 0 or Full Reset when GAME_COMPLETED != 0 on START/SELECT
    (label z_check_reset)
    (LDA #:zp ,ZELDA-ZP-DEAD)
    (BEQ z_check_completed_reset)
    (LDA #:zp ,ZELDA-ZP-NEW-BTN)
    (AND #:imm ,(bitwise-ior BTN-START BTN-SELECT))
    (BNE z_respawn_current_room)
    (JMP done_z_step)

    (label z_check_completed_reset)
    (LDA #:zp ,ZELDA-ZP-GAME-COMPLETED)
    (ORA #:zp ,ZELDA-ZP-TRIFORCE-WON)
    (BEQ z_alive_step)
    (LDA #:zp ,ZELDA-ZP-NEW-BTN)
    (AND #:imm ,(bitwise-ior BTN-START BTN-SELECT))
    (BEQ z_alive_step)
    ;; Full quest reset to Room 0
    (LDA #:imm 0)
    (STA #:zp ,ZELDA-ZP-ROOM-ID)
    (STA #:zp ,ZELDA-ZP-TRIFORCE-WON)
    (STA #:zp ,ZELDA-ZP-TRIFORCE-COUNT)
    (STA #:zp ,ZELDA-ZP-GAME-COMPLETED)
    (STA #:zp ,ZELDA-ZP-RUPEES)
    (STA #:zp ,ZELDA-ZP-KEYS)
    (STA #:zp ,ZELDA-ZP-KEY-X)
    (STA #:zp ,ZELDA-ZP-KEY-Y)
    (LDA #:imm 1)
    (STA #:zp ,ZELDA-ZP-ROOM-DIRTY)

    ;; Respawn Link in his current room
    (label z_respawn_current_room)
    (LDA #:imm 120)
    (STA #:zp ,ZELDA-ZP-LINK-X)
    (STA #:zp ,ZELDA-ZP-OCTO-X)
    (LDA #:imm 144)
    (STA #:zp ,ZELDA-ZP-LINK-Y)
    (LDA #:imm 96)
    (STA #:zp ,ZELDA-ZP-OCTO-Y)
    (LDA #:imm 0)
    (STA #:zp ,ZELDA-ZP-LINK-DIR)
    (STA #:zp ,ZELDA-ZP-DEAD)
    (STA #:zp ,ZELDA-ZP-HURT-TIMER)
    (LDA #:imm 1)
    (STA #:zp ,ZELDA-ZP-OCTO-ALIVE)
    (LDA #:imm 3)
    (STA #:zp ,ZELDA-ZP-HEARTS)

    (label z_alive_step)
    ;; 1. Sword Attack ('A' button spawns Sword hitbox above Link for 8 frames!)
    (LDA #:zp ,ZELDA-ZP-SWORD-TIMER)
    (BEQ check_sword_btn)
    (DEC #:zp ,ZELDA-ZP-SWORD-TIMER)
    (label check_sword_btn)
    (LDA #:zp ,ZELDA-ZP-NEW-BTN)
    (AND #:imm ,BTN-A)
    (BEQ move_link_dpad)
    (LDA #:imm 8)
    (STA #:zp ,ZELDA-ZP-SWORD-TIMER)
    ;; Compute Sword X/Y from Link's facing direction (0=DOWN/init, 1=UP, 2=LEFT, 3=RIGHT)
    (LDA #:zp ,ZELDA-ZP-LINK-X)
    (STA #:zp ,ZELDA-ZP-SWORD-X)
    (LDA #:zp ,ZELDA-ZP-LINK-Y)
    (STA #:zp ,ZELDA-ZP-SWORD-Y)
    (LDA #:zp ,ZELDA-ZP-LINK-DIR)
    (CMP #:imm 2)
    (BCS sword_horiz)
    (LDA #:zp ,ZELDA-ZP-LINK-Y)
    (SEC)
    (SBC #:imm 12)
    (STA #:zp ,ZELDA-ZP-SWORD-Y)
    (JMP check_sword_hit)
    (label sword_horiz)
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

    ;; Check if Sword Hitbox intersects Enemy/Boss (|sword_x - octo_x| < 16 and |sword_y - octo_y| < 16)
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
    ;; Sword hits Enemy/Boss! Defeat it and increment Rupees
    (LDA #:imm 0)
    (STA #:zp ,ZELDA-ZP-OCTO-ALIVE)
    (INC #:zp ,ZELDA-ZP-RUPEES)
    ;; Play Sword Slash / Enemy Defeat SFX on Pulse 1
    (LDA #:imm #x9F) (STA #:abs #x4000)
    (LDA #:imm #x89) (STA #:abs #x4001)
    (LDA #:imm #x60) (STA #:abs #x4002)
    (LDA #:imm #x18) (STA #:abs #x4003)
    ;; In Room 3 (Ganon), no key drop needed
    (LDA #:zp ,ZELDA-ZP-ROOM-ID)
    (CMP #:imm 3)
    (BEQ move_link_dpad)
    ;; In Room 0 (Octorok) and Room 2 (Aquamentus), drop Key at (OCTO_X, OCTO_Y)
    (LDA #:zp ,ZELDA-ZP-OCTO-X)
    (STA #:zp ,ZELDA-ZP-KEY-X)
    (LDA #:zp ,ZELDA-ZP-OCTO-Y)
    (STA #:zp ,ZELDA-ZP-KEY-Y)
    ;; In Room 2 (Underworld Dungeon Boss), assemble all 8 Triforce of Wisdom shards!
    (LDA #:zp ,ZELDA-ZP-ROOM-ID)
    (CMP #:imm 2)
    (BNE move_link_dpad)
    (LDA #:imm 8)
    (STA #:zp ,ZELDA-ZP-TRIFORCE-COUNT)

    ;; 2. 4-Directional Link Movement (4 px/frame)
    (label move_link_dpad)
    (LDA #:zp ,ZELDA-ZP-BUTTONS)
    (AND #:imm ,BTN-UP)
    (BEQ z_check_down)
    (LDA #:imm 1)
    (STA #:zp ,ZELDA-ZP-LINK-DIR)
    (LDA #:zp ,ZELDA-ZP-LINK-Y)
    (CMP #:imm 56)
    (BCC check_north_door_transition)
    (SEC)
    (SBC #:imm 4)
    (STA #:zp ,ZELDA-ZP-LINK-Y)
    (JMP check_octo_contact)

    ;; Check North Door Room Transitions (Y < 56): Room 0 -> 1 -> 2 -> 3
    (label check_north_door_transition)
    (LDA #:zp ,ZELDA-ZP-ROOM-ID)
    (BEQ north_door_room0)
    (CMP #:imm 1)
    (BEQ north_door_room1)
    (CMP #:imm 2)
    (BEQ north_door_room2)
    (JMP check_octo_contact)

    ;; Room 0 -> Room 1 (Eagle Labyrinth Sanctum): requires KEYS >= 1
    (label north_door_room0)
    (LDA #:zp ,ZELDA-ZP-KEYS)
    (BEQ check_octo_contact) ; Door is locked until Link collects the Key!
    (DEC #:zp ,ZELDA-ZP-KEYS)
    (LDA #:imm 1)
    (STA #:zp ,ZELDA-ZP-ROOM-ID)
    (STA #:zp ,ZELDA-ZP-ROOM-DIRTY)
    (LDA #:imm 0)
    (STA #:zp ,ZELDA-ZP-OCTO-ALIVE)
    (STA #:zp ,ZELDA-ZP-KEY-X)
    ;; Reposition Link at South entrance of Eagle Labyrinth Sanctum (X=120, Y=176)
    (LDA #:imm 176)
    (STA #:zp ,ZELDA-ZP-LINK-Y)
    (JMP check_octo_contact)

    ;; Room 1 -> Room 2 (Underworld Dungeon Boss Chamber — Aquamentus)
    (label north_door_room1)
    (LDA #:imm 2)
    (STA #:zp ,ZELDA-ZP-ROOM-ID)
    (JMP spawn_room_boss_transition)

    ;; Room 2 -> Room 3 (Death Mountain — Ganon's Lair): requires Boss Key (KEYS >= 1)
    (label north_door_room2)
    (LDA #:zp ,ZELDA-ZP-KEYS)
    (BEQ check_octo_contact)
    (DEC #:zp ,ZELDA-ZP-KEYS)
    (LDA #:imm 3)
    (STA #:zp ,ZELDA-ZP-ROOM-ID)

    (label spawn_room_boss_transition)
    (LDA #:imm 1)
    (STA #:zp ,ZELDA-ZP-ROOM-DIRTY)
    (STA #:zp ,ZELDA-ZP-OCTO-ALIVE)
    (LDA #:imm 0)
    (STA #:zp ,ZELDA-ZP-KEY-X)
    (LDA #:imm 120)
    (STA #:zp ,ZELDA-ZP-OCTO-X)
    (LDA #:imm 96)
    (STA #:zp ,ZELDA-ZP-OCTO-Y)
    (LDA #:imm 176)
    (STA #:zp ,ZELDA-ZP-LINK-Y)
    (JMP check_octo_contact)

    (label z_check_down)
    (LDA #:zp ,ZELDA-ZP-BUTTONS)
    (AND #:imm ,BTN-DOWN)
    (BEQ z_check_left)
    (LDA #:imm 0)
    (STA #:zp ,ZELDA-ZP-LINK-DIR)
    (LDA #:zp ,ZELDA-ZP-LINK-Y)
    (CMP #:imm 188)
    (BCS check_octo_contact)
    (CLC)
    (ADC #:imm 4)
    (STA #:zp ,ZELDA-ZP-LINK-Y)
    (JMP check_octo_contact)

    (label z_check_left)
    (LDA #:zp ,ZELDA-ZP-BUTTONS)
    (AND #:imm ,BTN-LEFT)
    (BEQ z_check_right)
    (LDA #:imm 2)
    (STA #:zp ,ZELDA-ZP-LINK-DIR)
    (LDA #:zp ,ZELDA-ZP-LINK-X)
    (CMP #:imm 24)
    (BCC check_octo_contact)
    (SEC)
    (SBC #:imm 4)
    (STA #:zp ,ZELDA-ZP-LINK-X)
    (JMP check_octo_contact)

    (label z_check_right)
    (LDA #:zp ,ZELDA-ZP-BUTTONS)
    (AND #:imm ,BTN-RIGHT)
    (BEQ check_octo_contact)
    (LDA #:imm 3)
    (STA #:zp ,ZELDA-ZP-LINK-DIR)
    (LDA #:zp ,ZELDA-ZP-LINK-X)
    (CMP #:imm 216)
    (BCS check_octo_contact)
    (CLC)
    (ADC #:imm 4)
    (STA #:zp ,ZELDA-ZP-LINK-X)

    ;; 2b. Enemy/Boss Body Contact Hazard (Failure Path in ANY room when OCTO_ALIVE != 0):
    ;;     If Enemy/Boss is alive, Sword is not active, and Hurt timer == 0,
    ;;     walking directly into Enemy/Boss (84 <= LINK_Y <= 100 and 108 <= LINK_X <= 132)
    ;;     knocks Link back to Y=108, sets HURT_TIMER=2, decrements HEARTS, and sets DEAD=1 at 0 hearts!
    (label check_octo_contact)
    (LDA #:zp ,ZELDA-ZP-OCTO-ALIVE)
    (BEQ check_pickups)
    (LDA #:zp ,ZELDA-ZP-SWORD-TIMER)
    (BNE check_pickups)
    (LDA #:zp ,ZELDA-ZP-HURT-TIMER)
    (BNE check_pickups)
    (LDA #:zp ,ZELDA-ZP-LINK-Y)
    (CMP #:imm 101)
    (BCS check_pickups)
    (CMP #:imm 84)
    (BCC check_pickups)
    (LDA #:zp ,ZELDA-ZP-LINK-X)
    (CMP #:imm 108)
    (BCC check_pickups)
    (CMP #:imm 133)
    (BCS check_pickups)
    ;; Contact hazard triggered! Knock Link back southward to Y=108
    (LDA #:imm 108)
    (STA #:zp ,ZELDA-ZP-LINK-Y)
    (LDA #:imm 2)
    (STA #:zp ,ZELDA-ZP-HURT-TIMER)
    ;; Play Hurt SFX on Pulse 2 ($4004-$4007)
    (LDA #:imm #x9F) (STA #:abs #x4004)
    (LDA #:imm #x8B) (STA #:abs #x4005)
    (LDA #:imm #xA0) (STA #:abs #x4006)
    (LDA #:imm #x18) (STA #:abs #x4007)
    ;; Decrement HEARTS (if > 0); if HEARTS reaches 0, set DEAD = 1
    (LDA #:zp ,ZELDA-ZP-HEARTS)
    (BEQ z_link_died)
    (DEC #:zp ,ZELDA-ZP-HEARTS)
    (BNE check_pickups)
    (label z_link_died)
    (LDA #:imm 1)
    (STA #:zp ,ZELDA-ZP-DEAD)

    ;; 3. Check Item Pickups & Quest Milestones:
    ;;    - In Room 0 / Room 2: Pick up dropped Key at (KEY_X, KEY_Y)
    ;;    - In Room 1 (Sanctum): Claim first Triforce shard at Y < 116
    ;;    - In Room 3 (Death Mountain): Rescue Princess Zelda at Y < 76 when Ganon slain
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
    ;; Collected Dungeon/Boss Key!
    (LDA #:imm 0)
    (STA #:zp ,ZELDA-ZP-KEY-X)
    (INC #:zp ,ZELDA-ZP-KEYS)

    (label check_triforce_pickup)
    (LDA #:zp ,ZELDA-ZP-ROOM-ID)
    (CMP #:imm 1)
    (BEQ check_room1_triforce)
    (CMP #:imm 3)
    (BEQ check_room3_zelda_rescue)
    (JMP done_z_step)

    (label check_room1_triforce)
    (LDA #:zp ,ZELDA-ZP-LINK-Y)
    (CMP #:imm 116)
    (BCS done_z_step)
    ;; Link reached the Triforce of Wisdom in Eagle Labyrinth Sanctum!
    (LDA #:imm 1)
    (STA #:zp ,ZELDA-ZP-TRIFORCE-WON)
    (LDA #:zp ,ZELDA-ZP-TRIFORCE-COUNT)
    (BNE play_triforce_chime)
    (LDA #:imm 1)
    (STA #:zp ,ZELDA-ZP-TRIFORCE-COUNT)
    (JMP play_triforce_chime)

    (label check_room3_zelda_rescue)
    (LDA #:zp ,ZELDA-ZP-OCTO-ALIVE)
    (BNE done_z_step)
    (LDA #:zp ,ZELDA-ZP-LINK-Y)
    (CMP #:imm 76)
    (BCS done_z_step)
    ;; Ganon slain and Princess Zelda rescued in Death Mountain!
    (LDA #:imm 1)
    (STA #:zp ,ZELDA-ZP-GAME-COMPLETED)
    (STA #:zp ,ZELDA-ZP-TRIFORCE-WON)

    (label play_triforce_chime)
    ;; Play Triforce Fanfare Chime on Triangle ($4008-$400B)
    (LDA #:imm #xFF) (STA #:abs #x4008)
    (LDA #:imm #x55) (STA #:abs #x400A)
    (LDA #:imm #x28) (STA #:abs #x400B)

    (label done_z_step)
    (JSR build_zelda_oam)
    (RTS)

    ;; ========================================================================
    ;; Build Zelda OAM Buffer ($0200-$02FF) using Authentic Overworld CHR Tiles:
    ;;   Slot 0 ($0200)       : Minimap green dot (Y=51, tile=#x3E, attr=#x00, X=45)
    ;;   Slots 1..4 ($0204)   : Link 16x16 Metasprite
    ;;                          - DIR=0 (DOWN): TL=#x0C, BL=#x0D, TR=#x0E, BR=#x0F (attr=#x00)
    ;;                          - DIR=1 (UP)  : TL=#x0E, BL=#x0F, TR=#x0C, BR=#x0D (attr=#x40 H-flip)
    ;;   Slots 5..6 ($0214)   : Wooden Sword (#x20, #x21, attr=#x00)
    ;;   Slots 7..10 ($021C)  : Enemy/Boss 16x16 Metasprite (#xB2, #xB3 symmetric-col-major, attr=#x02/#x42)
    ;;   Slots 11..14 ($022C) : Dropped Key (#x28, #x29, attr=#x00) or Triforce/Zelda (#x26, #x27 symmetric)
    ;;   Slots 15..16 ($023C) : HUD A-box Wooden Sword icon (X=152, Y=36 #x20 / Y=44 #x21, attr=#x00)
    ;; ========================================================================
    (label build_zelda_oam)
    ;; Slot 0 ($0200..$0203): Minimap green dot sprite
    (LDA #:imm 51)   (STA #:abs #x0200)
    (LDA #:imm #x3E) (STA #:abs #x0201)
    (LDA #:imm #x00) (STA #:abs #x0202)
    (LDA #:imm 45)   (STA #:abs #x0203)

    ;; Slots 15..16 ($023C..$0243): HUD A-box Wooden Sword icon (#x20 at Y=36, #x21 at Y=44, X=152, attr=#x00)
    (LDA #:imm 36)   (STA #:abs #x023C)
    (LDA #:imm #x20) (STA #:abs #x023D)
    (LDA #:imm #x00) (STA #:abs #x023E) (STA #:abs #x0242)
    (LDA #:imm 152)  (STA #:abs #x023F) (STA #:abs #x0243)
    (LDA #:imm 44)   (STA #:abs #x0240)
    (LDA #:imm #x21) (STA #:abs #x0241)

    ;; Slots 1..4 ($0204..$0213): Link Y and X coordinates
    (LDA #:zp ,ZELDA-ZP-LINK-Y)
    (STA #:abs #x0204)
    (STA #:abs #x0208)
    (CLC)
    (ADC #:imm 8)
    (STA #:abs #x020C)
    (STA #:abs #x0210)
    (LDA #:zp ,ZELDA-ZP-LINK-X)
    (STA #:abs #x0207)
    (STA #:abs #x020F)
    (CLC)
    (ADC #:imm 8)
    (STA #:abs #x020B)
    (STA #:abs #x0213)

    ;; Link tiles & attributes by direction:
    ;;   DIR=0 (DOWN): TL=#x0C, BL=#x0D, TR=#x0E, BR=#x0F (attr=#x00)
    ;;   DIR=1 (UP)  : TL=#x0E, BL=#x0F, TR=#x0C, BR=#x0D (attr=#x40 H-flip)
    (LDA #:zp ,ZELDA-ZP-LINK-DIR)
    (BNE link_oam_up)
    (LDA #:imm #x0C) (STA #:abs #x0205)
    (LDA #:imm #x0E) (STA #:abs #x0209)
    (LDA #:imm #x0D) (STA #:abs #x020D)
    (LDA #:imm #x0F) (STA #:abs #x0211)
    (LDA #:imm #x00)
    (STA #:abs #x0206) (STA #:abs #x020A) (STA #:abs #x020E) (STA #:abs #x0212)
    (JMP draw_sword_oam)

    (label link_oam_up)
    (LDA #:imm #x0E) (STA #:abs #x0205)
    (LDA #:imm #x0C) (STA #:abs #x0209)
    (LDA #:imm #x0F) (STA #:abs #x020D)
    (LDA #:imm #x0D) (STA #:abs #x0211)
    (LDA #:imm #x40)
    (STA #:abs #x0206) (STA #:abs #x020A) (STA #:abs #x020E) (STA #:abs #x0212)

    ;; Slots 5..6 ($0214..$021B): Wooden Sword (#x20, #x21, attr=#x00)
    (label draw_sword_oam)
    (LDA #:zp ,ZELDA-ZP-SWORD-TIMER)
    (BNE show_sword_oam)
    (LDA #:imm #xF8)
    (STA #:abs #x0214)
    (STA #:abs #x0218)
    (JMP draw_octo_oam)
    (label show_sword_oam)
    (LDA #:zp ,ZELDA-ZP-SWORD-Y)
    (STA #:abs #x0214)
    (CLC)
    (ADC #:imm 8)
    (STA #:abs #x0218)
    (LDA #:imm #x20) (STA #:abs #x0215)
    (LDA #:imm #x21) (STA #:abs #x0219)
    (LDA #:imm #x00) (STA #:abs #x0216) (STA #:abs #x021A)
    (LDA #:zp ,ZELDA-ZP-SWORD-X)
    (STA #:abs #x0217) (STA #:abs #x021B)

    ;; Slots 7..10 ($021C..$022B): Enemy/Boss 16x16 Metasprite (#xB2, #xB3 + H-Flip)
    (label draw_octo_oam)
    (LDA #:zp ,ZELDA-ZP-OCTO-ALIVE)
    (BNE show_octo_oam)
    (LDA #:imm #xF8)
    (STA #:abs #x021C) (STA #:abs #x0220) (STA #:abs #x0224) (STA #:abs #x0228)
    (JMP draw_item_oam)
    (label show_octo_oam)
    ,@(emit-metasprite-oam-6502 ZELDA-OCTOROK-METASPRITE ZELDA-ZP-OCTO-X ZELDA-ZP-OCTO-Y #x1C)

    ;; Slots 11..14 ($022C..$023B): Dropped Key (#x28, #x29, attr=#x00) or Triforce/Zelda (#x26, #x27 symmetric)
    (label draw_item_oam)
    (LDA #:zp ,ZELDA-ZP-ROOM-ID)
    (AND #:imm 1)
    (BNE show_triforce_oam)
    (LDA #:zp ,ZELDA-ZP-KEY-X)
    (BEQ hide_item_oam)
    (LDA #:zp ,ZELDA-ZP-KEY-Y)
    (STA #:abs #x022C)
    (CLC)
    (ADC #:imm 8)
    (STA #:abs #x0230)
    (LDA #:imm #x28) (STA #:abs #x022D)
    (LDA #:imm #x29) (STA #:abs #x0231)
    (LDA #:imm #x00) (STA #:abs #x022E) (STA #:abs #x0232)
    (LDA #:zp ,ZELDA-ZP-KEY-X)
    (STA #:abs #x022F) (STA #:abs #x0233)
    (LDA #:imm #xF8) (STA #:abs #x0234) (STA #:abs #x0238)
    (RTS)

    (label show_triforce_oam)
    ;; Symmetric 16x16 Triforce of Wisdom (#x26, #x27) at (X=120, Y=96)
    (LDA #:imm 96)   (STA #:abs #x022C) (STA #:abs #x0230)
    (LDA #:imm 104)  (STA #:abs #x0234) (STA #:abs #x0238)
    (LDA #:imm #x26) (STA #:abs #x022D) (STA #:abs #x0231)
    (LDA #:imm #x27) (STA #:abs #x0235) (STA #:abs #x0239)
    (LDA #:imm #x02) (STA #:abs #x022E) (STA #:abs #x0236)
    (LDA #:imm #x42) (STA #:abs #x0232) (STA #:abs #x023A)
    (LDA #:imm 120)  (STA #:abs #x022F) (STA #:abs #x0237)
    (LDA #:imm 128)  (STA #:abs #x0233) (STA #:abs #x023B)
    (RTS)

    (label hide_item_oam)
    (LDA #:imm #xF8)
    (STA #:abs #x022C) (STA #:abs #x0230) (STA #:abs #x0234) (STA #:abs #x0238)
    (RTS)

    ;; ========================================================================
    ;; VBlank NMI Handler (Updates Rupee/Key/Hearts HUD, North Door & Room Palette)
    ;; ========================================================================
    (label nmi_handler)
    (PHA)
    (TXA)
    (PHA)
    (TYA)
    (PHA)

    (LDA #:imm #x00) (STA #:abs #x2003)
    (LDA #:imm #x02) (STA #:abs #x4014)

    ;; Update HUD Rupee Counter ($206D -> '0' in Rupee "X0")
    (BIT #:abs #x2002)
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #x6D) (STA #:abs #x2006)
    (LDA #:zp ,ZELDA-ZP-RUPEES)
    (AND #:imm #x07)
    (STA #:abs #x2007)

    ;; Update HUD Key Counter ($20AD -> '0' in Key "X0")
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #xAD) (STA #:abs #x2006)
    (LDA #:zp ,ZELDA-ZP-KEYS)
    (AND #:imm #x07)
    (STA #:abs #x2007)

    ;; Update HUD 3 Red Hearts at Row 6 Cols 22..24 ($20D6..$20D8):
    ;;   #xF2 (242) = full heart when heart_index < ZELDA-ZP-HEARTS
    ;;   #x65 (101) = empty/half heart when heart_index >= ZELDA-ZP-HEARTS
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #xD6) (STA #:abs #x2006)
    (LDY #:zp ,ZELDA-ZP-HEARTS)
    (LDX #:imm #x65)
    (CPY #:imm 1)
    (BCC z_heart0_write)
    (LDX #:imm #xF2)
    (label z_heart0_write)
    (STX #:abs #x2007)
    (LDX #:imm #x65)
    (CPY #:imm 2)
    (BCC z_heart1_write)
    (LDX #:imm #xF2)
    (label z_heart1_write)
    (STX #:abs #x2007)
    (LDX #:imm #x65)
    (CPY #:imm 3)
    (BCC z_heart2_write)
    (LDX #:imm #xF2)
    (label z_heart2_write)
    (STX #:abs #x2007)

    ;; When ROOM_DIRTY != 0, open North Door tiles ($20CF..$20F0 and $210F..$2130)
    ;; and update $3F02..$3F03 based on ROOM_ID!
    (LDA #:zp ,ZELDA-ZP-ROOM-DIRTY)
    (BEQ z_nmi_restore)
    (LDA #:imm 0)
    (STA #:zp ,ZELDA-ZP-ROOM-DIRTY)
    (BIT #:abs #x2002)
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #xCF) (STA #:abs #x2006)
    (LDA #:imm #x24) (STA #:abs #x2007) (STA #:abs #x2007)
    (LDA #:imm #x20) (STA #:abs #x2006) (LDA #:imm #xEF) (STA #:abs #x2006)
    (LDA #:imm #x24) (STA #:abs #x2007) (STA #:abs #x2007)
    (LDA #:imm #x21) (STA #:abs #x2006) (LDA #:imm #x0F) (STA #:abs #x2006)
    (LDA #:imm #x26) (STA #:abs #x2007) (STA #:abs #x2007)
    (LDA #:imm #x21) (STA #:abs #x2006) (LDA #:imm #x2F) (STA #:abs #x2006)
    (LDA #:imm #x26) (STA #:abs #x2007) (STA #:abs #x2007)

    ;; Update $3F02..$3F03 based on ROOM_ID:
    ;;   ROOM_ID <= 1 -> Overworld (#x30, #x00)
    ;;   ROOM_ID == 2 -> Underworld Dungeon teal (#x1C, #x0C)
    ;;   ROOM_ID == 3 -> Death Mountain crimson (#x16, #x06)
    (LDX #:imm #x30)
    (LDY #:imm #x00)
    (LDA #:zp ,ZELDA-ZP-ROOM-ID)
    (CMP #:imm 2)
    (BNE z_pal_check_r3)
    (LDX #:imm #x1C)
    (LDY #:imm #x0C)
    (JMP z_pal_write)
    (label z_pal_check_r3)
    (CMP #:imm 3)
    (BNE z_pal_write)
    (LDX #:imm #x16)
    (LDY #:imm #x06)
    (label z_pal_write)
    (LDA #:imm #x3F) (STA #:abs #x2006) (LDA #:imm #x02) (STA #:abs #x2006)
    (STX #:abs #x2007)
    (STY #:abs #x2007)

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
    (.byte ,@ZELDA-OVERWORLD-PALETTE)

    (.align 256)
    (label zelda_nt0_table)
    (.byte ,@ZELDA-OVERWORLD-NT0-PATCHED)))
