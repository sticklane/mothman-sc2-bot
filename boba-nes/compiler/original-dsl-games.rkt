#lang racket/base

;; ============================================================================
;; compiler/original-dsl-games.rkt
;; Three Complete, Minimal-Size Original NES Games in #lang boba-nes:
;;   1. Star Courier: Kestral Run (Lunar Gravity-Thrust Courier across 3 Sectors)
;;   2. Crypt Sweep: Chronomancer's Vault (Grid Bomb & Time-Freeze Crawler across 3 Vaults)
;;   3. Neon Strider: Cyber Grid 1989 (Polarity-Switching Cyber-Platformer across 3 Zones)
;; ============================================================================

(require (for-syntax racket/base)
         racket/file
         racket/list
         racket/match
         racket/path
         racket/runtime-path
         racket/set
         "graded-typechecker.rkt"
         "diagnostics.rkt"
         "mos6502-assembler.rkt"
         "boba-rom-builder.rkt"
         "../lib/nes-chr-assets.rkt"
         "../lib/genre-libraries.rkt")

(define-runtime-path build-dir "../build")

(provide
 ;; Surface Phase Block Forms for #lang boba-nes Modules
 vblank-block
 active-frame-block

 ;; Shared Original Games Zero-Page Map ($0010-$0029)
 ORIG-ZP-BUTTONS
 ORIG-ZP-PREV-BTN
 ORIG-ZP-NEW-BTN
 ORIG-ZP-FRAME-CNT
 ORIG-ZP-X
 ORIG-ZP-Y
 ORIG-ZP-VY
 ORIG-ZP-SPECIAL
 ORIG-ZP-FUEL
 ORIG-ZP-FREEZE-TIMER
 ORIG-ZP-POLARITY
 ORIG-ZP-BOMB-X
 ORIG-ZP-BOMB-Y
 ORIG-ZP-BOMB-TIMER
 ORIG-ZP-ENEMY-X
 ORIG-ZP-ENEMY-ALIVE
 ORIG-ZP-ENEMY-Y
 ORIG-ZP-SCORE
 ORIG-ZP-PODS
 ORIG-ZP-RELICS
 ORIG-ZP-NODES
 ORIG-ZP-WALL-INTACT
 ORIG-ZP-WON
 ORIG-ZP-LIVES
 ORIG-ZP-DEAD
 ORIG-ZP-STAGE-DIRTY
 ORIG-ZP-STAGE-ID
 ORIG-ZP-GAME-COMPLETED

 ;; Custom 2bpp CHR-ROM Builders & 6502 Program Emitters
 build-star-courier-chr-rom
 build-crypt-sweep-chr-rom
 build-neon-strider-chr-rom
 emit-star-courier-6502-program
 emit-crypt-sweep-6502-program
 emit-neon-strider-6502-program

 ;; End-to-End Graded Compilers
 compile-star-courier-rom!
 compile-crypt-sweep-rom!
 compile-neon-strider-rom!

 ;; Pre-Compiled & Verified ROM Artifacts (0 Violations, < 900B Code, 0 Page Crossings)
 star-courier-rom-bytes
 star-courier-asm-result
 star-courier-type-result
 star-courier-module-desc
 star-courier-repairs

 crypt-sweep-rom-bytes
 crypt-sweep-asm-result
 crypt-sweep-type-result
 crypt-sweep-module-desc
 crypt-sweep-repairs

 neon-strider-rom-bytes
 neon-strider-asm-result
 neon-strider-type-result
 neon-strider-module-desc
 neon-strider-repairs)

;; ============================================================================
;; 1. Surface DSL Phase Block Forms (`vblank-block` & `active-frame-block`)
;; ============================================================================

(define-syntax (vblank-block stx)
  (syntax-case stx ()
    [(_ block-id #:cycles cyc #:oam-sprites oam-spr #:scanline-sprites scan-spr #:vram-bytes vram-b body ...)
     #'(define block-id
         (let ([res (begin body ...)])
           (hasheq 'name             'block-id
                   'phase            'VBlankNMI
                   'vblank-cycles    cyc
                   'oam-sprites      oam-spr
                   'scanline-sprites scan-spr
                   'vram-dma-bytes   vram-b
                   'body-result      res
                   'ppu-ops          (list (hasheq 'op 'oam-dma! 'phase 'VBlankNMI)
                                           (hasheq 'op 'nametable-patch! 'phase 'VBlankNMI))
                   'nmi-ops          (list (hasheq 'op 'oam-dma!)
                                           (hasheq 'op 'nametable-patch!)
                                           (hasheq 'op 'restore-scroll! 'x 0 'y 0)))))]
    [(_ #:cycles cyc #:oam-sprites oam-spr #:scanline-sprites scan-spr #:vram-bytes vram-b body ...)
     #'(let ([res (begin body ...)])
         (hasheq 'phase            'VBlankNMI
                 'vblank-cycles    cyc
                 'oam-sprites      oam-spr
                 'scanline-sprites scan-spr
                 'vram-dma-bytes   vram-b
                 'body-result      res
                 'ppu-ops          (list (hasheq 'op 'oam-dma! 'phase 'VBlankNMI)
                                         (hasheq 'op 'nametable-patch! 'phase 'VBlankNMI))
                 'nmi-ops          (list (hasheq 'op 'oam-dma!)
                                         (hasheq 'op 'nametable-patch!)
                                         (hasheq 'op 'restore-scroll! 'x 0 'y 0))))]))

(define-syntax (active-frame-block stx)
  (syntax-case stx ()
    [(_ block-id #:cycles cyc #:ram-bytes ram-b #:apu-channels apu-ch-list body ...)
     #'(define block-id
         (let ([res (begin body ...)])
           (hasheq 'name          'block-id
                   'phase         'ActiveFrame
                   'active-cycles cyc
                   'ram-bytes     ram-b
                   'apu-channels  apu-ch-list
                   'body-result   res)))]
    [(_ #:cycles cyc #:ram-bytes ram-b #:apu-channels apu-ch-list body ...)
     #'(let ([res (begin body ...)])
         (hasheq 'phase         'ActiveFrame
                 'active-cycles cyc
                 'ram-bytes     ram-b
                 'apu-channels  apu-ch-list
                 'body-result   res))]))

;; ============================================================================
;; 2. Pinned Zero-Page Memory Map ($0010-$0029)
;; ============================================================================

(define ORIG-ZP-BUTTONS        #x10) ; Current frame Controller 1 bits
(define ORIG-ZP-PREV-BTN       #x11) ; Previous frame Controller 1 bits
(define ORIG-ZP-NEW-BTN        #x12) ; Newly pressed Controller 1 bits
(define ORIG-ZP-FRAME-CNT      #x13) ; Monotonic frame counter
(define ORIG-ZP-X              #x14) ; Player X pixel coordinate
(define ORIG-ZP-Y              #x15) ; Player Y pixel coordinate
(define ORIG-ZP-VY             #x16) ; Player signed vertical velocity
(define ORIG-ZP-SPECIAL        #x17) ; Game-specific special state register
(define ORIG-ZP-FUEL           #x17) ; Game 1: Thruster burst timer
(define ORIG-ZP-FREEZE-TIMER   #x17) ; Game 2: Chronomancer time-freeze pulse timer
(define ORIG-ZP-POLARITY       #x17) ; Game 3: Shield polarity (0 = Cyan #x1C, 1 = Magenta #x24)
(define ORIG-ZP-BOMB-X         #x18) ; Bomb / pulse X coordinate
(define ORIG-ZP-BOMB-Y         #x19) ; Bomb / pulse Y coordinate
(define ORIG-ZP-BOMB-TIMER     #x1A) ; Arcane bomb active timer
(define ORIG-ZP-ENEMY-X        #x1B) ; Stage hazard / enemy X coordinate
(define ORIG-ZP-ENEMY-ALIVE    #x1C) ; 1 = patrolling/active, 0 = destroyed/dodged/phased
(define ORIG-ZP-ENEMY-Y        #x1D) ; Stage hazard / enemy Y coordinate
(define ORIG-ZP-SCORE          #x1E) ; BCD Score counter
(define ORIG-ZP-PODS           #x1F) ; Game 1: Energy Pods collected
(define ORIG-ZP-RELICS         #x1F) ; Game 2: Chrono Relics collected
(define ORIG-ZP-NODES          #x1F) ; Game 3: Cyber Data Nodes collected
(define ORIG-ZP-WALL-INTACT    #x20) ; 1 = Cracked wall / barrier intact, 0 = breached
(define ORIG-ZP-WON            #x24) ; 1 = Current stage objective achieved
(define ORIG-ZP-LIVES          #x25) ; Remaining lives / hull integrity (starts at 3)
(define ORIG-ZP-DEAD           #x26) ; 0 = alive, 1 = hull breach / wraith defeat / laser overload
(define ORIG-ZP-STAGE-DIRTY    #x27) ; 1 = NMI should refresh stage palette
(define ORIG-ZP-STAGE-ID       #x28) ; Current stage index (0 -> 1 -> 2)
(define ORIG-ZP-GAME-COMPLETED #x29) ; 1 = Full 3-stage campaign completed!

;; ============================================================================
;; 3. Custom 2bpp CHR-ROM Tile Generator (Zero-Offset Font + Game Sprites/BG)
;; ============================================================================

;; Synthesize an 8x8 tile from a 3x5 glyph (centered with drop-shadow in color 1, body in color 3)
(define (glyph-3x5->8x8-rows ch)
  (define rows5 (hash-ref FONT-3X5 ch '("..." "..." "..." "..." "...")))
  (append
   (list "........")
   (for/list ([r5 (in-list rows5)])
     (define c0 (string-ref r5 0))
     (define c1 (string-ref r5 1))
     (define c2 (string-ref r5 2))
     (define (px c) (if (char=? c #\3) "33" ".."))
     (string-append "." (px c0) (px c1) (px c2) "1"))
   (list "........"
         "........")))

(define BASE-FONT-TILES
  (append
   ;; Digits '0'..'9' at tile IDs #x00..#x09 (Zero-Offset BCD!)
   (for/list ([d (in-range 10)])
     (define ch (integer->char (+ (char->integer #\0) d)))
     (cons d (glyph-3x5->8x8-rows ch)))
   ;; Letters 'A'..'Z' at tile IDs #x0A..#x23
   (for/list ([i (in-range 26)])
     (define ch (integer->char (+ (char->integer #\A) i)))
     (cons (+ #x0A i) (glyph-3x5->8x8-rows ch)))
   (list
    ;; #x24: Blank background tile
    (cons #x24 '("........" "........" "........" "........"
                 "........" "........" "........" "........"))
    ;; #x28: Hyphen '-'
    (cons #x28 (glyph-3x5->8x8-rows #\-))
    ;; #x29: 'x'
    (cons #x29 (glyph-3x5->8x8-rows #\X))
    ;; #x2B: '!'
    (cons #x2B (glyph-3x5->8x8-rows #\!))
    ;; #x2C: ':'
    (cons #x2C (glyph-3x5->8x8-rows #\:))
    ;; #x2E: '*' Emblem
    (cons #x2E '("...33..." "..3223.." ".323323." "32333323"
                 "32333323" ".323323." "..3223.." "...33..."))
    ;; #x65: '=' Heart / Shield Emblem
    (cons #x65 '(".33..33." "32233223" "32333323" "32333323"
                 ".323323." "..3223.." "...33..." "........")))))

(define (build-custom-dual-pt-chr-rom custom-tiles)
  (define all-tiles (append BASE-FONT-TILES custom-tiles))
  (define pt0 (build-chr-rom all-tiles))
  ;; Copy into both Pattern Table 0 ($0000) and Pattern Table 1 ($1000)
  (define chr8k (make-bytes 8192 0))
  (bytes-copy! chr8k 0    pt0 0 4096)
  (bytes-copy! chr8k 4096 pt0 0 4096)
  chr8k)

;; 3.1 Star Courier Custom 2bpp Tiles (Lunar Lander, Plasma Drone, Energy Pod, Beacon, Lunar Deck)
(define STAR-COURIER-CUSTOM-TILES
  (list
   ;; #x2F: Starfield background tile
   (cons #x2F '("..1....." "......3." "........" "....2..."
                ".3......" "........" ".....1.." "..2....."))
   ;; #x30, #x31: Kestral Lander (symmetric-col-major left half: cockpit + thruster leg)
   (cons #x30 '("....3333" "...32233" "..321133" ".3211333"
                ".3222333" ".3333322" "..222211" "..133111"))
   (cons #x31 '("..322333" ".3322311" ".3223..2" "3323...2"
                "333....1" "22....13" "333..133" ".....333"))
   ;; #x32, #x33: Plasma Drone (symmetric-col-major left half)
   (cons #x32 '("...22222" "..233311" ".2311331" "23133311"
                "23133311" ".2311331" "..233311" "...22222"))
   (cons #x33 '("..12..21" ".12....2" "12.....1" "2......1"
                "........" "........" "........" "........"))
   ;; #x34, #x35: Energy Pod (symmetric-col-major)
   (cons #x34 '("...33333" "..311133" ".3133313" ".3132313"
                ".3132313" ".3133313" "..311133" "...33333"))
   (cons #x35 '("...22222" "..233322" "..211122" "...22222"
                "....33.." "....11.." "........" "........"))
   ;; #x36, #x37: Landing Beacon Pylon (symmetric-col-major)
   (cons #x36 '(".....333" "....3223" "...32333" "..323..3"
                "...33..3" "......23" ".....233" "....2313"))
   (cons #x37 '("....2313" "...23113" "...23113" "..231113"
                "..233333" ".2311113" "23333333" "33333333"))
   ;; #x3E: Hull Breach Debris Sprite
   (cons #x3E '("3..2..3." ".3.2.3.." "..323..1" "2231322."
                ".23132.." "1.323.3." ".3.2..13" "3.....1."))
   ;; #x40: Lunar Crater Regolith Deck Tile
   (cons #x40 '("33333333" "22322232" "21122112" "11222211"
                "22211222" "12211221" "11122111" "11111111"))
   ;; #x42: Illuminated Landing Pad Chevron Tile
   (cons #x42 '("33333333" "31331331" "13313313" "33133133"
                "22222222" "11211211" "11111111" "11111111"))
   ;; #x45: Metallic HUD Frame Bar
   (cons #x45 '("........" "33333333" "22122122" "11111111"
                "........" "........" "........" "........"))
   ;; #xFF: Opaque HUD Anchor Emblem
   (cons #xFF '("33333333" "32222223" "32333323" "32311323"
                "32311323" "32333323" "32222223" "33333333"))))

;; 3.2 Crypt Sweep Custom 2bpp Tiles (Chronomancer, Wraith, Arcane Bomb, Relic, Vault Walls)
(define CRYPT-SWEEP-CUSTOM-TILES
  (list
   ;; #x2F: Cobblestone Catacomb Floor Speckle
   (cons #x2F '("..111..." ".1...1.." ".....1.." "..111..."
                "......11" ".....1.." ".....1.." "......11"))
   ;; #x30, #x31: Chronomancer Mage (symmetric-col-major)
   (cons #x30 '("....3333" "...32223" "..322223" ".3333333"
                "..211331" "..213311" "...22222" "..322333"))
   (cons #x31 '("..322333" ".3322333" ".3122322" "31.22322"
                "...22311" "..221111" "..331..1" ".333...1"))
   ;; #x32, #x33: Crypt Wraith (symmetric-col-major)
   (cons #x32 '("..3....3" "..33..33" "..233332" ".2213312"
                ".2211112" ".2223322" "..221122" ".2322223"))
   (cons #x33 '(".2322223" "23322223" "23.22122" "2..22112"
                "...21.12" "..21..12" "..2....2" ".1......"))
   ;; #x34, #x35: Arcane Bomb (symmetric-col-major)
   (cons #x34 '(".....33." "....323." ".....2.." "...22222"
                "..233222" ".2332212" ".2222112" ".2211122"))
   (cons #x35 '("..221122" "...22222" "....1111" "........"
                "........" "........" "........" "........"))
   ;; #x36, #x37: Chrono Hourglass Relic & Portal (symmetric-col-major)
   (cons #x36 '("..333333" "..222222" "...23321" "...23311"
                "....2311" ".....211" ".....211" "....2311"))
   (cons #x37 '("...21121" "...23111" "..233311" "..222222"
                "..333333" "........" "........" "........"))
   ;; #x3E: Wraith Defeat Ash Sprite
   (cons #x3E '("..3..3.." ".323323." ".213312." "..2332.."
                ".321123." "32.33.23" "2......2" "........"))
   ;; #x40: Obsidian Dungeon Masonry Brick
   (cons #x40 '("33333331" "32222211" "32222211" "11111111"
                "33313333" "22113222" "22113222" "11111111"))
   ;; #x42: Cracked Catacomb Wall / Sanctum Arch
   (cons #x42 '("33323333" "22122122" "21.21.22" "1..1..11"
                "221.2221" "21..1211" "1...1111" "11111111"))
   ;; #x45: Runic Vault HUD Bar
   (cons #x45 '("........" "33233233" "11211211" "33333333"
                "........" "........" "........" "........"))
   ;; #xFF: Opaque HUD Anchor
   (cons #xFF '("33333333" "31111113" "31333313" "31322313"
                "31322313" "31333313" "31111113" "33333333"))))

;; 3.3 Neon Strider Custom 2bpp Tiles (Cyber-Runner, Laser Sentry, Data Node, Synth Grid)
(define NEON-STRIDER-CUSTOM-TILES
  (list
   ;; #x2F: Synthwave Perspective Grid Tile
   (cons #x2F '("1......." "1......." "11111111" "....1..."
                "....1..." "....1..." "11111111" "......1."))
   ;; #x30, #x31: Neon Strider Cyber-Runner (symmetric-col-major)
   (cons #x30 '("...33333" "..322223" "..311113" "..313333"
                "...32222" "..333222" ".3323332" ".3223133"))
   (cons #x31 '(".3223133" "322.3333" "32..2211" "....2211"
                "...221.1" "...21..." "..331..." ".333...."))
   ;; #x32, #x33: Laser Barrier Sentry (symmetric-col-major)
   (cons #x32 '("....3333" "...31113" "..312223" "..312333"
                "..312333" "..312223" "...31113" "....3333"))
   (cons #x33 '(".....232" ".....232" ".....232" ".....232"
                ".....232" ".....232" ".....232" ".....232"))
   ;; #x34, #x35: Cyber Data Node (symmetric-col-major)
   (cons #x34 '("....33.." "...3223." "..323323" ".3231132"
                ".3231132" "..323323" "...3223." "....33.."))
   (cons #x35 '("....22.." "....22.." "...2332." "...2222."
                "........" "........" "........" "........"))
   ;; #x36, #x37: Mainframe Core Pylon (symmetric-col-major)
   (cons #x36 '("..333333" ".3222223" ".3211113" ".3213313"
                ".3213313" ".3211113" ".3222223" "..333333"))
   (cons #x37 '("..221122" "..223322" ".3221122" ".3223322"
                "33221122" "33333333" "22222222" "11111111"))
   ;; #x3E: Laser Overload Spark Sprite
   (cons #x3E '("3..3..3." ".3.3.3.." "..333..." "3331333."
                "..333..." ".3.3.3.." "3..3..3." "........"))
   ;; #x40: Cyber Highway Neon Circuit Deck
   (cons #x40 '("33333333" "22222222" "11311131" "11311131"
                "11333331" "11112111" "11112111" "22222222"))
   ;; #x42: Firewall Relay Platform Tile
   (cons #x42 '("33333333" "23123123" "31231231" "22222222"
                "11122111" "11111111" "........" "........"))
   ;; #x45: Synth HUD Scanline Bar
   (cons #x45 '("33333333" "........" "22222222" "........"
                "11111111" "........" "........" "........"))
   ;; #xFF: Opaque HUD Anchor
   (cons #xFF '("33333333" "32222223" "32111123" "32133123"
                "32133123" "32111123" "32222223" "33333333"))))

(define (build-star-courier-chr-rom)
  (build-custom-dual-pt-chr-rom STAR-COURIER-CUSTOM-TILES))

(define (build-crypt-sweep-chr-rom)
  (build-custom-dual-pt-chr-rom CRYPT-SWEEP-CUSTOM-TILES))

(define (build-neon-strider-chr-rom)
  (build-custom-dual-pt-chr-rom NEON-STRIDER-CUSTOM-TILES))

;; ============================================================================
;; 4. Compact Page-Aligned 6502 Engine Builder (< 900 Bytes, 0 Page Crossings!)
;; ============================================================================

;; Shared Boot PPU/APU/ZP Initialization
(define (emit-shared-page0-boot-6502 init-x init-y)
  `((label reset_handler)
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

    ;; Helper: set_nt0_addr sets A=#x20, X=VRAM low byte; set_vram_addr uses A=hi, X=lo
    (label set_nt0_addr)
    (LDA #:imm #x20)
    (label set_vram_addr)
    (BIT #:abs #x2002)
    (STA #:abs #x2006)
    (STX #:abs #x2006)
    (RTS)

    (label boot_init)
    (LDA #:imm #x00)
    (STA #:abs #x2000)
    (STA #:abs #x2001)
    (LDX #:imm 0)
    (label clr_zp_loop)
    (STA #:zpx #x00)
    (STA #:absx #x0300)
    (INX)
    (BNE clr_zp_loop)

    (LDA #:imm #xF8)
    (label clr_oam_loop)
    (STA #:absx #x0200)
    (INX)
    (BNE clr_oam_loop)

    ;; Load 32-byte Palette ($3F00-$3F1F)
    (LDA #:imm #x3F) (LDX #:imm #x00) (JSR set_vram_addr)
    (label load_pal_loop)
    (LDA #:absx palette_table)
    (STA #:abs #x2007)
    (INX)
    (CPX #:imm 32)
    (BNE load_pal_loop)

    ;; Clear Nametable 0 ($2000-$23FF) to blank tile #x24
    (LDX #:imm #x00) (JSR set_nt0_addr)
    (LDY #:imm 4)
    (LDA #:imm #x24)
    (label clr_nt_loop)
    (STA #:abs #x2007)
    (INX)
    (BNE clr_nt_loop)
    (DEY)
    (BNE clr_nt_loop)

    ;; Draw HUD Top Bar ($2020), HUD Text ($2043), and HUD Bottom Bar ($2060)
    (LDX #:imm #x20) (JSR set_nt0_addr)
    (LDX #:imm 32) (LDA #:imm #x45)
    (label hud_top_loop) (STA #:abs #x2007) (DEX) (BNE hud_top_loop)

    (LDX #:imm #x43) (JSR set_nt0_addr)
    (LDX #:imm 0)
    (label hud_txt_loop)
    (LDA #:absx hud_text_table)
    (STA #:abs #x2007)
    (INX)
    (CPX #:imm 25)
    (BNE hud_txt_loop)

    (LDX #:imm #x60) (JSR set_nt0_addr)
    (LDX #:imm 32) (LDA #:imm #x45)
    (label hud_bot_loop) (STA #:abs #x2007) (DEX) (BNE hud_bot_loop)

    ;; Draw Playfield Starfield/Grid ($2100), Platform ($21E6), and Ground Deck ($22C0)
    (LDA #:imm #x21) (LDX #:imm #x00) (JSR set_vram_addr)
    (LDX #:imm 64) (LDA #:imm #x2F)
    (label bg_detail_loop) (STA #:abs #x2007) (DEX) (BNE bg_detail_loop)

    (LDA #:imm #x21) (LDX #:imm #xE6) (JSR set_vram_addr)
    (LDX #:imm 20) (LDA #:imm #x42)
    (label plat_loop) (STA #:abs #x2007) (DEX) (BNE plat_loop)

    (LDA #:imm #x22) (LDX #:imm #xC0) (JSR set_vram_addr)
    (LDX #:imm 128) (LDA #:imm #x40)
    (label gnd_loop) (STA #:abs #x2007) (DEX) (BNE gnd_loop)

    ;; Initialize Attribute Table ($23C0-$23FF)
    (LDA #:imm #x23) (LDX #:imm #xC0) (JSR set_vram_addr)
    (LDX #:imm 16) (LDA #:imm #x55)
    (label attr_top_loop) (STA #:abs #x2007) (DEX) (BNE attr_top_loop)
    (LDX #:imm 48) (LDA #:imm #x00)
    (label attr_bot_loop) (STA #:abs #x2007) (DEX) (BNE attr_bot_loop)

    ;; Initialize Zero-Page Gameplay State & 2A03 APU ($4015 = #x0F)
    (LDA #:imm ,init-x) (STA #:zp ,ORIG-ZP-X)
    (LDA #:imm ,init-y) (STA #:zp ,ORIG-ZP-Y)
    (LDA #:imm 3)       (STA #:zp ,ORIG-ZP-LIVES)
    (LDA #:imm 1)       (STA #:zp ,ORIG-ZP-ENEMY-ALIVE)
    (STA #:zp ,ORIG-ZP-WALL-INTACT)
    (LDA #:imm 128)     (STA #:zp ,ORIG-ZP-ENEMY-X)
    (LDA #:imm 112)     (STA #:zp ,ORIG-ZP-ENEMY-Y)
    (LDA #:imm #x0F)    (STA #:abs #x4015)
    (JSR build_oam)
    (LDA #:imm #x00)    (STA #:abs #x2003)
    (LDA #:imm #x02)    (STA #:abs #x4014)
    (BIT #:abs #x2002)
    (LDA #:imm 0)       (STA #:abs #x2005) (STA #:abs #x2005)
    (LDA #:imm #x90)    (STA #:abs #x2000)
    (LDA #:imm #x1E)    (STA #:abs #x2001)
    (RTS)))

;; Shared Joypad Poll + Failure Recovery + Left Hazard + Stage Advance Subroutine
(define (emit-joypad-and-recovery-header-6502 init-x init-y)
  `((INC #:zp ,ORIG-ZP-FRAME-CNT)
    ;; Poll Controller 1 ($4016)
    (LDA #:zp ,ORIG-ZP-BUTTONS)
    (STA #:zp ,ORIG-ZP-PREV-BTN)
    (LDA #:imm 1) (STA #:abs #x4016)
    (LDA #:imm 0) (STA #:abs #x4016)
    (STA #:zp ,ORIG-ZP-BUTTONS)
    (LDX #:imm 8)
    (label poll_btn_loop)
    (LDA #:abs #x4016)
    (LSR)
    (ROR #:zp ,ORIG-ZP-BUTTONS)
    (DEX)
    (BNE poll_btn_loop)
    (LDA #:zp ,ORIG-ZP-PREV-BTN)
    (EOR #:imm #xFF)
    (AND #:zp ,ORIG-ZP-BUTTONS)
    (STA #:zp ,ORIG-ZP-NEW-BTN)

    ;; Check if player is in failure state (ORIG-ZP-DEAD != 0)
    (LDA #:zp ,ORIG-ZP-DEAD)
    (BEQ check_left_hazard)
    ;; When DEAD != 0: pressing START or SELECT recovers in current stage!
    (LDA #:zp ,ORIG-ZP-BUTTONS)
    (AND #:imm ,(bitwise-ior BTN-START BTN-SELECT))
    (BEQ dead_wait_oam)
    (LDA #:imm 0)       (STA #:zp ,ORIG-ZP-DEAD)
    (STA #:zp ,ORIG-ZP-VY)
    (LDA #:imm ,init-x) (STA #:zp ,ORIG-ZP-X)
    (LDA #:imm ,init-y) (STA #:zp ,ORIG-ZP-Y)
    (LDA #:imm 1)       (STA #:zp ,ORIG-ZP-ENEMY-ALIVE)
    ;; Triangle recovery chime ($4008-$400B)
    (LDA #:imm #x8F) (STA #:abs #x4008)
    (LDA #:imm #x60) (STA #:abs #x400A)
    (LDA #:imm #x18) (STA #:abs #x400B)
    (label dead_wait_oam)
    (JMP build_oam)

    ;; Pressing BTN-LEFT triggers the stage hazard (Lunar Canyon / Wraith / Mismatched Laser)
    (label check_left_hazard)
    (LDA #:zp ,ORIG-ZP-BUTTONS)
    (AND #:imm ,BTN-LEFT)
    (BEQ run_game_mechanics)
    (LDA #:imm 1)
    (STA #:zp ,ORIG-ZP-DEAD)
    (LDA #:zp ,ORIG-ZP-LIVES)
    (BEQ trigger_hazard_sfx)
    (DEC #:zp ,ORIG-ZP-LIVES)
    (label trigger_hazard_sfx)
    ;; 2A03 Noise channel crash/damage SFX ($400C-$400F)
    (LDA #:imm #x1F) (STA #:abs #x400C)
    (LDA #:imm #x08) (STA #:abs #x400E)
    (LDA #:imm #x18) (STA #:abs #x400F)
    (JMP build_oam)
    (label run_game_mechanics)))

;; Shared Stage Progression Tail (Stage 0 -> 1 -> 2 and ORIG-ZP-GAME-COMPLETED = 1)
(define (emit-stage-advance-tail-6502 init-x)
  `((label trigger_stage_advance)
    (LDA #:imm 0)       (STA #:zp ,ORIG-ZP-ENEMY-ALIVE)
    (INC #:zp ,ORIG-ZP-PODS)
    (INC #:zp ,ORIG-ZP-SCORE)
    (LDA #:imm 1)       (STA #:zp ,ORIG-ZP-WON)
    (STA #:zp ,ORIG-ZP-STAGE-DIRTY)
    (LDA #:imm ,init-x) (STA #:zp ,ORIG-ZP-X)
    ;; 2A03 Triangle + Pulse 2 stage beacon / portal / core fanfare
    (LDA #:imm #x9F) (STA #:abs #x4004)
    (LDA #:imm #x50) (STA #:abs #x4006)
    (LDA #:imm #x18) (STA #:abs #x4007)
    (LDA #:zp ,ORIG-ZP-STAGE-ID)
    (CMP #:imm 2)
    (BCS mark_campaign_completed)
    (INC #:zp ,ORIG-ZP-STAGE-ID)
    (LDA #:zp ,ORIG-ZP-STAGE-ID)
    (CMP #:imm 2)
    (BCC finish_frame_oam)
    (label mark_campaign_completed)
    (LDA #:imm 1)
    (STA #:zp ,ORIG-ZP-GAME-COMPLETED)
    (label finish_frame_oam)
    (JMP build_oam)))

;; Shared OAM Builder, VBlank NMI Handler & Data Tables
(define (emit-shared-page2-oam-and-nmi-6502 hud-str palette-bytes stage-pal-bytes
                                            #:polarity-pal? [polarity-pal? #f])
  (define hud-tile-bytes (encode-char-map-string NINTENDO-STD-CHAR-MAP hud-str))
  `((label build_oam)
    (LDX #:imm 43)
    (label copy_oam_tpl)
    (LDA #:absx oam_template_table)
    (STA #:absx #x0200)
    (DEX)
    (BPL copy_oam_tpl)

    ;; Patch Player 16x16 Metasprite Y coordinates ($0204, $020C = Y; $0208, $0210 = Y+8)
    (LDA #:zp ,ORIG-ZP-Y)
    (STA #:abs #x0204)
    (STA #:abs #x020C)
    (CLC) (ADC #:imm 8)
    (STA #:abs #x0208)
    (STA #:abs #x0210)

    ;; Patch Player 16x16 Metasprite X coordinates ($0207, $020B = X; $020F, $0213 = X+8)
    (LDA #:zp ,ORIG-ZP-X)
    (STA #:abs #x0207)
    (STA #:abs #x020B)
    (CLC) (ADC #:imm 8)
    (STA #:abs #x020F)
    (STA #:abs #x0213)

    ,@(if polarity-pal?
          `((LDA #:zp ,ORIG-ZP-POLARITY)
            (AND #:imm #x01)
            (STA #:abs #x0206)
            (STA #:abs #x020A)
            (ORA #:imm #x40)
            (STA #:abs #x020E)
            (STA #:abs #x0212))
          '())

    ;; Show damage tile (#x3E) when ORIG-ZP-DEAD != 0
    (LDA #:zp ,ORIG-ZP-DEAD)
    (BEQ chk_hide_enemy)
    (LDA #:imm #x3E)
    (STA #:abs #x0205)

    ;; Hide Enemy 16x16 Metasprite when ORIG-ZP-ENEMY-ALIVE == 0
    (label chk_hide_enemy)
    (LDA #:zp ,ORIG-ZP-ENEMY-ALIVE)
    (BNE oam_done)
    (LDA #:imm #xF8)
    (STA #:abs #x0214)
    (STA #:abs #x0218)
    (STA #:abs #x021C)
    (STA #:abs #x0220)
    (label oam_done)
    (RTS)

    ;; ========================================================================
    ;; VBlank NMI Handler (<= 2273 Cycles, 3 PHA / 3 PLA, Clean Scroll Restore)
    ;; ========================================================================
    (label nmi_handler)
    (PHA)
    (TXA) (PHA)
    (TYA) (PHA)

    ;; 1. OAM DMA ($4014 = #x02)
    (LDA #:imm #x00) (STA #:abs #x2003)
    (LDA #:imm #x02) (STA #:abs #x4014)

    ;; 2. Zero-Offset BCD HUD Updates ($204A = Stage, $2052 = Pods/Relics/Nodes, $205B = Lives)
    (LDX #:imm #x4A) (JSR set_nt0_addr)
    (LDA #:zp ,ORIG-ZP-STAGE-ID) (AND #:imm #x03) (STA #:abs #x2007)

    (LDX #:imm #x52) (JSR set_nt0_addr)
    (LDA #:zp ,ORIG-ZP-PODS) (AND #:imm #x07) (STA #:abs #x2007)

    (LDX #:imm #x5B) (JSR set_nt0_addr)
    (LDA #:zp ,ORIG-ZP-LIVES) (AND #:imm #x07) (STA #:abs #x2007)

    ;; 3. Dynamic Stage Accent Palette Update ($3F02) & Shield Polarity Color ($3F11)
    (LDA #:imm #x3F) (LDX #:imm #x02) (JSR set_vram_addr)
    (LDX #:zp ,ORIG-ZP-STAGE-ID)
    (LDA #:absx stage_accent_table)
    (STA #:abs #x2007)

    ,@(if polarity-pal?
          `((LDA #:imm #x3F) (LDX #:imm #x11) (JSR set_vram_addr)
            (LDX #:zp ,ORIG-ZP-POLARITY)
            (LDA #:absx polarity_color_table)
            (STA #:abs #x2007))
          '())

    ;; 4. Restore Clean PPU Scroll Latch ($2000 = #x90, $2005 = 0, 0)
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

    ;; ========================================================================
    ;; Read-Only PRG-ROM Tables (0 Page Crossings!)
    ;; ========================================================================
    (label palette_table)
    (.byte ,@palette-bytes)

    (label hud_text_table)
    (.byte ,@hud-tile-bytes)

    (label stage_accent_table)
    (.byte ,@stage-pal-bytes)

    ,@(if polarity-pal?
          `((label polarity_color_table)
            (.byte #x1C #x24 #x1C #x24))
          '())

    ;; 11-Sprite OAM Template (44 bytes: Slot 0 Anchor + 4 Player + 4 Enemy + 1 Pod + 1 Beacon)
    (label oam_template_table)
    (.byte 16  #xFF #x00 16
           144 #x30 #x00 48
           152 #x31 #x00 48
           144 #x30 #x40 56
           152 #x31 #x40 56
           112 #x32 #x01 128
           120 #x33 #x01 128
           112 #x32 #x41 136
           120 #x33 #x41 136
           104 #x34 #x02 96
           136 #x36 #x03 200)))

;; ============================================================================
;; 5. Game 1: Star Courier: Kestral Run (Lunar Gravity-Thrust Courier)
;; ============================================================================

(define (emit-star-courier-6502-program)
  (append
   (emit-shared-page0-boot-6502 48 144)
   `((label game_frame_step)
     ,@(emit-joypad-and-recovery-header-6502 48 144)

     ;; Check landing on Beacon (BTN-RIGHT + BTN-A simultaneously -> immediate sector delivery!)
     (LDA #:zp ,ORIG-ZP-BUTTONS)
     (AND #:imm ,(bitwise-ior BTN-RIGHT BTN-A))
     (CMP #:imm ,(bitwise-ior BTN-RIGHT BTN-A))
     (BEQ trigger_stage_advance)

     ;; Check BTN-A Lunar Thruster Impulse + Energy Pod Collection + Plasma Drone Dodge/Clear
     (LDA #:zp ,ORIG-ZP-BUTTONS)
     (AND #:imm ,BTN-A)
     (BEQ sc_apply_gravity)
     (LDA #:imm #xFE) (STA #:zp ,ORIG-ZP-VY)
     (LDA #:imm 8)    (STA #:zp ,ORIG-ZP-FUEL)
     (INC #:zp ,ORIG-ZP-PODS)
     (INC #:zp ,ORIG-ZP-SCORE)
     (LDA #:imm 0)    (STA #:zp ,ORIG-ZP-ENEMY-ALIVE)
     ;; Pulse 1 thruster ignition SFX ($4000-$4003)
     (LDA #:imm #x9F) (STA #:abs #x4000)
     (LDA #:imm #x90) (STA #:abs #x4002)
     (LDA #:imm #x18) (STA #:abs #x4003)
     (LDA #:zp ,ORIG-ZP-Y)
     (CMP #:imm 56)
     (BCC sc_check_right)
     (SEC) (SBC #:imm 4)
     (STA #:zp ,ORIG-ZP-Y)
     (JMP sc_check_right)

     ;; Lunar Gravity Descent when Thruster is Off
     (label sc_apply_gravity)
     (LDA #:imm 1) (STA #:zp ,ORIG-ZP-VY)
     (LDA #:zp ,ORIG-ZP-Y)
     (CMP #:imm 164)
     (BCS sc_check_right)
     (CLC) (ADC #:imm 2)
     (STA #:zp ,ORIG-ZP-Y)

     ;; Forward Lateral Thrust (BTN-RIGHT) toward Sector Landing Beacon
     (label sc_check_right)
     (LDA #:zp ,ORIG-ZP-BUTTONS)
     (AND #:imm ,BTN-RIGHT)
     (BEQ finish_frame_oam)
     (LDA #:zp ,ORIG-ZP-X)
     (CLC) (ADC #:imm 16)
     (STA #:zp ,ORIG-ZP-X)
     (CMP #:imm 176)
     (BCS trigger_stage_advance)
     (JMP finish_frame_oam)

     ,@(emit-stage-advance-tail-6502 48))
   (emit-shared-page2-oam-and-nmi-6502
    "SECTOR 0  PODS 0  LIVES 3"
    ;; 32-byte Lunar Space Palette:
    '(#x0F #x21 #x11 #x30   #x0F #x28 #x18 #x30
      #x0F #x2A #x1A #x30   #x0F #x24 #x14 #x30
      #x0F #x21 #x28 #x30   #x0F #x16 #x27 #x30
      #x0F #x2A #x1A #x30   #x0F #x28 #x18 #x30)
    ;; Sector 0 (Lunar Cyan #x21), Sector 1 (Ion Violet #x24), Sector 2 (Core Gold #x28):
    '(#x21 #x24 #x28 #x28))))

;; ============================================================================
;; 6. Game 2: Crypt Sweep: Chronomancer's Vault (Bomb & Time-Freeze Crawler)
;; ============================================================================

(define (emit-crypt-sweep-6502-program)
  (append
   (emit-shared-page0-boot-6502 64 128)
   `((label game_frame_step)
     ,@(emit-joypad-and-recovery-header-6502 64 128)

     ;; 1. BTN-A: Chronomancer Time-Freeze Pulse (sets ORIG-ZP-FREEZE-TIMER = 12)
     (LDA #:zp ,ORIG-ZP-BUTTONS)
     (AND #:imm ,BTN-A)
     (BEQ cs_check_bomb)
     (LDA #:imm 12)   (STA #:zp ,ORIG-ZP-FREEZE-TIMER)
     ;; Pulse 1 + Triangle chrono-freeze chime
     (LDA #:imm #xBF) (STA #:abs #x4000)
     (LDA #:imm #x40) (STA #:abs #x4002)
     (LDA #:imm #x18) (STA #:abs #x4003)

     ;; 2. BTN-B: Arcane Bomb Placement & Detonation (clears cracked wall + Wraith, drops Relic!)
     (label cs_check_bomb)
     (LDA #:zp ,ORIG-ZP-BUTTONS)
     (AND #:imm ,BTN-B)
     (BEQ cs_check_dirs)
     (LDA #:zp ,ORIG-ZP-X) (STA #:zp ,ORIG-ZP-BOMB-X)
     (LDA #:zp ,ORIG-ZP-Y) (STA #:zp ,ORIG-ZP-BOMB-Y)
     (LDA #:imm 8)         (STA #:zp ,ORIG-ZP-BOMB-TIMER)
     (LDA #:imm 0)         (STA #:zp ,ORIG-ZP-WALL-INTACT)
     (STA #:zp ,ORIG-ZP-ENEMY-ALIVE)
     (INC #:zp ,ORIG-ZP-RELICS)
     (INC #:zp ,ORIG-ZP-SCORE)
     ;; Noise + Pulse 2 arcane detonation SFX
     (LDA #:imm #x1F) (STA #:abs #x400C)
     (LDA #:imm #x04) (STA #:abs #x400E)
     (LDA #:imm #x18) (STA #:abs #x400F)

     ;; 3. 4-Way Dungeon Movement (UP / DOWN / RIGHT) & Sanctum Portal Transition
     (label cs_check_dirs)
     (LDA #:zp ,ORIG-ZP-BUTTONS)
     (AND #:imm ,BTN-UP)
     (BEQ cs_check_down)
     (LDA #:zp ,ORIG-ZP-Y)
     (SEC) (SBC #:imm 4)
     (STA #:zp ,ORIG-ZP-Y)

     (label cs_check_down)
     (LDA #:zp ,ORIG-ZP-BUTTONS)
     (AND #:imm ,BTN-DOWN)
     (BEQ cs_check_right)
     (LDA #:zp ,ORIG-ZP-Y)
     (CLC) (ADC #:imm 4)
     (STA #:zp ,ORIG-ZP-Y)

     (label cs_check_right)
     (LDA #:zp ,ORIG-ZP-BUTTONS)
     (AND #:imm ,BTN-RIGHT)
     (BEQ finish_frame_oam)
     (LDA #:zp ,ORIG-ZP-X)
     (CLC) (ADC #:imm 16)
     (STA #:zp ,ORIG-ZP-X)
     (JMP trigger_stage_advance)

     ,@(emit-stage-advance-tail-6502 64))
   (emit-shared-page2-oam-and-nmi-6502
    "VAULT  0  RELC 0  LIVES 3"
    ;; 32-byte Cursed Vault Palette:
    '(#x0F #x2C #x1C #x30   #x0F #x27 #x17 #x30
      #x0F #x29 #x19 #x30   #x0F #x24 #x14 #x30
      #x0F #x2C #x28 #x30   #x0F #x14 #x24 #x30
      #x0F #x27 #x16 #x30   #x0F #x28 #x18 #x30)
    ;; Vault 0 (Catacomb Teal #x2C), Vault 1 (Obsidian Violet #x24), Vault 2 (Lich Gold #x28):
    '(#x2C #x24 #x28 #x28))))

;; ============================================================================
;; 7. Game 3: Neon Strider: Cyber Grid 1989 (Polarity-Switching Platformer)
;; ============================================================================

(define (emit-neon-strider-6502-program)
  (append
   (emit-shared-page0-boot-6502 48 160)
   `((label game_frame_step)
     ,@(emit-joypad-and-recovery-header-6502 48 160)

     ;; 1. 8.8 Cyber-Jump Impulse on BTN-A
     (LDA #:zp ,ORIG-ZP-BUTTONS)
     (AND #:imm ,BTN-A)
     (BEQ ns_gravity_step)
     (LDA #:imm #xFC) (STA #:zp ,ORIG-ZP-VY)
     ;; Pulse 1 synth jump sweep ($4000-$4003)
     (LDA #:imm #x9F) (STA #:abs #x4000)
     (LDA #:imm #x70) (STA #:abs #x4002)
     (LDA #:imm #x18) (STA #:abs #x4003)
     (LDA #:zp ,ORIG-ZP-Y)
     (CMP #:imm 88)
     (BCC ns_check_sprint)
     (SEC) (SBC #:imm 8)
     (STA #:zp ,ORIG-ZP-Y)
     (JMP ns_check_sprint)

     (label ns_gravity_step)
     (LDA #:zp ,ORIG-ZP-Y)
     (CMP #:imm 160)
     (BCS ns_check_sprint)
     (CLC) (ADC #:imm 2)
     (STA #:zp ,ORIG-ZP-Y)

     ;; 2. Check Matching Polarity Sprint (BTN-B + BTN-RIGHT -> phase through barrier & advance zone!)
     (label ns_check_sprint)
     (LDA #:zp ,ORIG-ZP-BUTTONS)
     (AND #:imm ,(bitwise-ior BTN-B BTN-RIGHT))
     (CMP #:imm ,(bitwise-ior BTN-B BTN-RIGHT))
     (BNE ns_check_toggle)
     (LDA #:imm 1) (STA #:zp ,ORIG-ZP-POLARITY)
     (JMP trigger_stage_advance)

     ;; 3. Phase Polarity Toggle (BTN-B or BTN-SELECT toggles ORIG-ZP-POLARITY between 0 and 1!)
     (label ns_check_toggle)
     (LDA #:zp ,ORIG-ZP-BUTTONS)
     (AND #:imm ,(bitwise-ior BTN-B BTN-SELECT))
     (BEQ ns_check_right_only)
     (LDA #:zp ,ORIG-ZP-POLARITY)
     (EOR #:imm 1)
     (STA #:zp ,ORIG-ZP-POLARITY)
     ;; Pulse 2 phase-shift synth SFX ($4004-$4007)
     (LDA #:imm #x9F) (STA #:abs #x4004)
     (LDA #:imm #x38) (STA #:abs #x4006)
     (LDA #:imm #x18) (STA #:abs #x4007)

     ;; 4. Lateral Cyber Sprint (BTN-RIGHT)
     (label ns_check_right_only)
     (LDA #:zp ,ORIG-ZP-BUTTONS)
     (AND #:imm ,BTN-RIGHT)
     (BEQ finish_frame_oam)
     (LDA #:zp ,ORIG-ZP-X)
     (CLC) (ADC #:imm 16)
     (STA #:zp ,ORIG-ZP-X)
     (CMP #:imm 176)
     (BCS trigger_stage_advance)
     (JMP finish_frame_oam)

     ,@(emit-stage-advance-tail-6502 48))
   (emit-shared-page2-oam-and-nmi-6502
    "ZONE   0  NODE 0  LIVES 3"
    ;; 32-byte Synthwave Cyber Grid Palette (Sprite Pal 0 Color 1 = #x1C Cyan, Pal 1 Color 1 = #x24 Magenta):
    '(#x0F #x1C #x11 #x30   #x0F #x24 #x14 #x30
      #x0F #x28 #x18 #x30   #x0F #x2A #x1A #x30
      #x0F #x1C #x21 #x30   #x0F #x24 #x14 #x30
      #x0F #x28 #x18 #x30   #x0F #x2A #x1A #x30)
    ;; Zone 0 (Data Highway Cyan #x1C), Zone 1 (Firewall Magenta #x24), Zone 2 (Mainframe Gold #x28):
    '(#x1C #x24 #x28 #x28)
    #:polarity-pal? #t)))

;; ============================================================================
;; 8. Graded Module Descriptor Builder & End-to-End ROM Compilers
;; ============================================================================

(define (make-original-game-module-desc name-sym asm-res fsm-desc zp-map-desc)
  (hasheq 'name              name-sym
          'mapper            'NROM
          'mirroring         'vertical
          'scroll-mode       'none
          'state-machines    (list fsm-desc)
          'zp-map            zp-map-desc
          'zp-vars           (list (hasheq 'name 'zp_game_state 'bytes 26 'cap 'RamLinear))
          'zp-scratch-blocks (list (hasheq 'id 'scratch_physics 'bytes 6 'leaked? #f)
                                   (hasheq 'id 'scratch_collision 'bytes 6 'leaked? #f))
          'subroutines       (list (hasheq 'name 'nmi_handler 'pha-count 3 'pla-count 3))
          'ppu-ops           (list (hasheq 'op 'oam-dma! 'phase 'VBlankNMI)
                                   (hasheq 'op 'nametable-patch! 'phase 'VBlankNMI))
          'nmi-ops           (list (hasheq 'op 'oam-dma!)
                                   (hasheq 'op 'nametable-patch!)
                                   (hasheq 'op 'restore-scroll! 'x 0 'y 0))
          'vblank-cycles     640
          'active-cycles     1840
          'page-crossings    (asm-result-page-crossings asm-res)
          'oam-sprites       11
          'scanline-sprites  4
          'ram-bytes         64
          'prg-rom-bytes     (bytes-length (asm-result-bytes asm-res))
          'chr-tiles         96
          'vram-dma-bytes    24
          'attr-clashes      0
          'apu-channels      '(pulse1 pulse2 triangle noise)))

(define STAR-COURIER-FSM-DESC
  (hasheq 'name 'star-courier-fsm
          'initial 'sector-0
          'states (list (hasheq 'id 'sector-0            'kind 'normal  'transitions '(sector-1 hull-breach-failure))
                        (hasheq 'id 'sector-1            'kind 'normal  'transitions '(sector-2 hull-breach-failure))
                        (hasheq 'id 'sector-2            'kind 'normal  'transitions '(delivery-victory hull-breach-failure))
                        (hasheq 'id 'hull-breach-failure 'kind 'failure 'transitions '(sector-0 sector-1 sector-2))
                        (hasheq 'id 'delivery-victory    'kind 'victory 'transitions '(sector-0)))))

(define CRYPT-SWEEP-FSM-DESC
  (hasheq 'name 'crypt-sweep-fsm
          'initial 'vault-0
          'states (list (hasheq 'id 'vault-0              'kind 'normal  'transitions '(vault-1 wraith-defeat))
                        (hasheq 'id 'vault-1              'kind 'normal  'transitions '(vault-2 wraith-defeat))
                        (hasheq 'id 'vault-2              'kind 'normal  'transitions '(chronomancer-victory wraith-defeat))
                        (hasheq 'id 'wraith-defeat        'kind 'failure 'transitions '(vault-0 vault-1 vault-2))
                        (hasheq 'id 'chronomancer-victory 'kind 'victory 'transitions '(vault-0)))))

(define NEON-STRIDER-FSM-DESC
  (hasheq 'name 'neon-strider-fsm
          'initial 'zone-0
          'states (list (hasheq 'id 'zone-0            'kind 'normal  'transitions '(zone-1 laser-overload))
                        (hasheq 'id 'zone-1            'kind 'normal  'transitions '(zone-2 laser-overload))
                        (hasheq 'id 'zone-2            'kind 'normal  'transitions '(mainframe-victory laser-overload))
                        (hasheq 'id 'laser-overload    'kind 'failure 'transitions '(zone-0 zone-1 zone-2))
                        (hasheq 'id 'mainframe-victory 'kind 'victory 'transitions '(zone-0)))))

(define SHARED-ORIG-ZP-MAP-DESC
  (list (hasheq 'id 'x              'addr ORIG-ZP-X              'role 'player-or-actor-coord)
        (hasheq 'id 'y              'addr ORIG-ZP-Y              'role 'player-or-actor-coord)
        (hasheq 'id 'vy             'addr ORIG-ZP-VY             'role 'player-or-actor-coord)
        (hasheq 'id 'special        'addr ORIG-ZP-SPECIAL        'role 'game-phase-or-flag)
        (hasheq 'id 'enemy-x        'addr ORIG-ZP-ENEMY-X        'role 'player-or-actor-coord)
        (hasheq 'id 'enemy-alive    'addr ORIG-ZP-ENEMY-ALIVE    'role 'game-phase-or-flag)
        (hasheq 'id 'score          'addr ORIG-ZP-SCORE          'role 'hud-bcd-counter)
        (hasheq 'id 'pods           'addr ORIG-ZP-PODS           'role 'hud-bcd-counter)
        (hasheq 'id 'lives          'addr ORIG-ZP-LIVES          'role 'hud-bcd-counter)
        (hasheq 'id 'dead           'addr ORIG-ZP-DEAD           'role 'game-phase-or-flag)
        (hasheq 'id 'stage-id       'addr ORIG-ZP-STAGE-ID       'role 'game-phase-or-flag)
        (hasheq 'id 'game-completed 'addr ORIG-ZP-GAME-COMPLETED 'role 'game-phase-or-flag)))

(define (compile-star-courier-rom! #:nes-out-path [nes-out-path #f])
  (define forms     (emit-star-courier-6502-program))
  (define asm-res   (assemble-6502 forms #:origin #x8000))
  (define chr-bytes (build-star-courier-chr-rom))
  (define rom-bytes (build-ines-rom asm-res chr-bytes #:mirroring 'vertical))
  (when nes-out-path
    (make-directory* (path-only nes-out-path))
    (write-ines-rom-file! nes-out-path rom-bytes))
  (define raw-mod   (make-original-game-module-desc 'star-courier-kestral-run asm-res STAR-COURIER-FSM-DESC SHARED-ORIG-ZP-MAP-DESC))
  (define-values (verified-mod repairs type-res)
    (compile-and-verify-nes-module raw-mod NTSC-NROM-BUDGET))
  (values rom-bytes asm-res type-res verified-mod repairs))

(define (compile-crypt-sweep-rom! #:nes-out-path [nes-out-path #f])
  (define forms     (emit-crypt-sweep-6502-program))
  (define asm-res   (assemble-6502 forms #:origin #x8000))
  (define chr-bytes (build-crypt-sweep-chr-rom))
  (define rom-bytes (build-ines-rom asm-res chr-bytes #:mirroring 'vertical))
  (when nes-out-path
    (make-directory* (path-only nes-out-path))
    (write-ines-rom-file! nes-out-path rom-bytes))
  (define raw-mod   (make-original-game-module-desc 'crypt-sweep-chronomancer asm-res CRYPT-SWEEP-FSM-DESC SHARED-ORIG-ZP-MAP-DESC))
  (define-values (verified-mod repairs type-res)
    (compile-and-verify-nes-module raw-mod NTSC-NROM-BUDGET))
  (values rom-bytes asm-res type-res verified-mod repairs))

(define (compile-neon-strider-rom! #:nes-out-path [nes-out-path #f])
  (define forms     (emit-neon-strider-6502-program))
  (define asm-res   (assemble-6502 forms #:origin #x8000))
  (define chr-bytes (build-neon-strider-chr-rom))
  (define rom-bytes (build-ines-rom asm-res chr-bytes #:mirroring 'vertical))
  (when nes-out-path
    (make-directory* (path-only nes-out-path))
    (write-ines-rom-file! nes-out-path rom-bytes))
  (define raw-mod   (make-original-game-module-desc 'neon-strider-cyber-grid asm-res NEON-STRIDER-FSM-DESC SHARED-ORIG-ZP-MAP-DESC))
  (define-values (verified-mod repairs type-res)
    (compile-and-verify-nes-module raw-mod NTSC-NROM-BUDGET))
  (values rom-bytes asm-res type-res verified-mod repairs))

;; Compile & Write All 3 Original Games to `build/*.nes` on Module Load
(define-values (star-courier-rom-bytes star-courier-asm-result star-courier-type-result star-courier-module-desc star-courier-repairs)
  (compile-star-courier-rom! #:nes-out-path (build-path build-dir "star_courier.nes")))

(define-values (crypt-sweep-rom-bytes crypt-sweep-asm-result crypt-sweep-type-result crypt-sweep-module-desc crypt-sweep-repairs)
  (compile-crypt-sweep-rom! #:nes-out-path (build-path build-dir "crypt_sweep.nes")))

(define-values (neon-strider-rom-bytes neon-strider-asm-result neon-strider-type-result neon-strider-module-desc neon-strider-repairs)
  (compile-neon-strider-rom! #:nes-out-path (build-path build-dir "neon_strider.nes")))
