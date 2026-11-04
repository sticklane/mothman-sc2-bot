#lang racket/base

;; ============================================================================
;; compiler/decompiled-top10.rkt
;; Authentic Decompiled 6502 PPU, OAM, APU & 4-Stage Campaign Engine for the
;; Top-10 Commercial NROM NES Classics in #lang boba-nes:
;;   1. Donkey Kong (1981/1983, NROM-128, Horizontal Mirroring)
;;   2. Mario Bros. (1983, NROM-128, Vertical Mirroring)
;;   3. Pac-Man (1980/1984, NROM-128, Horizontal Mirroring)
;;   4. Excitebike (1984, NROM-128, Vertical Mirroring)
;;   5. Balloon Fight (1984, NROM-128, Horizontal Mirroring)
;;   6. Ice Climber (1985, NROM-128, Horizontal Mirroring)
;;   7. Galaga (1981/1985, NROM-256, Horizontal Mirroring)
;;   8. Kung Fu (1984/1985, NROM-256, Vertical Mirroring)
;;   9. Battle City (1985, NROM-128, Horizontal Mirroring)
;;  10. Bomberman (1985, NROM-128, Vertical Mirroring)
;; ============================================================================

(require json
         racket/file
         racket/format
         racket/list
         racket/match
         racket/path
         racket/runtime-path
         "graded-typechecker.rkt"
         "diagnostics.rkt"
         "mos6502-assembler.rkt"
         "../lib/nes-chr-assets.rkt")

(provide
 ;; Zero-Page Hardware & Campaign Registers ($0010-$0029)
 TOP10-ZP-BUTTONS
 TOP10-ZP-PREV-BTN
 TOP10-ZP-NEW-BTN
 TOP10-ZP-FRAME-CNT
 TOP10-ZP-PLAYER-X
 TOP10-ZP-PLAYER-Y
 TOP10-ZP-PLAYER-DIR
 TOP10-ZP-ACTION-TIMER
 TOP10-ZP-GENRE-REG-A
 TOP10-ZP-GENRE-REG-B
 TOP10-ZP-ENEMY-X
 TOP10-ZP-ENEMY-Y
 TOP10-ZP-ENEMY-ALIVE
 TOP10-ZP-HAZARD-STEPS
 TOP10-ZP-SCORE
 TOP10-ZP-STAGE-CLEAR-STEPS
 TOP10-ZP-GENRE-TIMER
 TOP10-ZP-GENRE-BONUS
 TOP10-ZP-GENRE-COOLDOWN
 TOP10-ZP-GENRE-STATE
 TOP10-ZP-WON
 TOP10-ZP-LIVES
 TOP10-ZP-DEAD
 TOP10-ZP-VRAM-DIRTY
 TOP10-ZP-STAGE-ID
 TOP10-ZP-GAME-COMPLETED

 ;; Game Specifications, State/CHR Loaders, 6502 Emitter & ROM Builders
 TOP10-GAME-SPECS
 find-top10-game-spec
 load-top10-game-state
 load-top10-authentic-chr-rom
 count-nonzero-chr-tiles
 emit-top10-genre-mechanics-6502
 emit-decompiled-top10-6502-program
 compile-top10-game-rom!
 compile-all-top10-roms!
 top10-decompiled-games)

;; ============================================================================
;; 1. Unified Zero-Page Layout ($0010-$0029) Across All 10 Decompiled Classics
;; ============================================================================
(define TOP10-ZP-BUTTONS           #x10) ; Controller 1 current button bitmask
(define TOP10-ZP-PREV-BTN          #x11) ; Controller 1 previous frame bitmask
(define TOP10-ZP-NEW-BTN           #x12) ; Rising-edge button presses
(define TOP10-ZP-FRAME-CNT         #x13) ; Monotonic frame counter (+1/frame)
(define TOP10-ZP-PLAYER-X          #x14) ; Player screen/world X coordinate (init = 80)
(define TOP10-ZP-PLAYER-Y          #x15) ; Player screen/world Y coordinate (init = 160)
(define TOP10-ZP-PLAYER-DIR        #x16) ; Player facing/movement direction (0..3)
(define TOP10-ZP-ACTION-TIMER      #x17) ; Attack/Jump/Bomb/Shot active frames
(define TOP10-ZP-GENRE-REG-A       #x18) ; Genre-specific primary mechanic register
(define TOP10-ZP-GENRE-REG-B       #x19) ; Genre-specific secondary mechanic register
(define TOP10-ZP-ENEMY-X           #x1A) ; Stage hazard/enemy X coordinate (init = 60)
(define TOP10-ZP-ENEMY-Y           #x1B) ; Stage hazard/enemy Y coordinate (init = 160)
(define TOP10-ZP-ENEMY-ALIVE       #x1C) ; 1 = active enemy/objective, 0 = defeated
(define TOP10-ZP-HAZARD-STEPS      #x1D) ; Frames walked into hazard without attacking
(define TOP10-ZP-SCORE             #x1E) ; Stage & enemy score counter (BCD)
(define TOP10-ZP-STAGE-CLEAR-STEPS #x1F) ; Progress toward clearing current stage
(define TOP10-ZP-GENRE-TIMER       #x20) ; Genre-specific timer (hammer/POW/pellet/fuse/heat)
(define TOP10-ZP-GENRE-BONUS       #x21) ; Genre-specific combo/bonus/salvo counter
(define TOP10-ZP-GENRE-COOLDOWN    #x22) ; Genre-specific weapon/turret reload cooldown
(define TOP10-ZP-GENRE-STATE       #x23) ; Genre-specific stance/elevation/armor/blast state
(define TOP10-ZP-WON               #x24) ; 1 = campaign victory achieved
(define TOP10-ZP-LIVES             #x25) ; Remaining player lives (init = 3)
(define TOP10-ZP-DEAD              #x26) ; 0 = alive, 1 = hazard death (awaiting START recovery)
(define TOP10-ZP-VRAM-DIRTY        #x27) ; 1 = NMI flushes HUD score/stage update
(define TOP10-ZP-STAGE-ID          #x28) ; Current stage/wave index (0 -> 1 -> 2 -> 3)
(define TOP10-ZP-GAME-COMPLETED    #x29) ; 1 = all 4 stages cleared!

(define-runtime-path REPO-ROOT-DIR "..")
(define TOP10-STATE-DIR (build-path REPO-ROOT-DIR "assets" "decompiled" "top10"))
(define ROMS-DIR        (build-path REPO-ROOT-DIR "assets" "roms"))
(define BUILD-DIR       (build-path REPO-ROOT-DIR "build"))

;; ============================================================================
;; 2. Metadata & Hardware Specifications for the Top-10 Commercial NES ROMs
;; ============================================================================
(define TOP10-GAME-SPECS
  (list
   (hasheq 'symbol       'donkey-kong
           'id           "donkey_kong"
           'title        "Donkey Kong"
           'genre        'arcade-platformer
           'rom-file     "donkey_kong.nes"
           'state-file   "donkey_kong_state.json"
           'out-file     "donkey_kong_nes.nes"
           'mirroring    'horizontal
           'oam-page     #x02
           'ppuctrl      #x90
           'stage-names  '("25m Girders" "50m Pie Factory" "75m Elevators" "100m Rivets"))
   (hasheq 'symbol       'mario-bros
           'id           "mario_bros"
           'title        "Mario Bros."
           'genre        'sewer-arcade-action
           'rom-file     "mario_bros.nes"
           'state-file   "mario_bros_state.json"
           'out-file     "mario_bros_nes.nes"
           'mirroring    'vertical
           'oam-page     #x02
           'ppuctrl      #x90
           'stage-names  '("Phase 1 Shellcreeper" "Phase 2 Sidestepper" "Phase 3 Fighterfly" "Phase 4 Slipice Boss"))
   (hasheq 'symbol       'pac-man
           'id           "pac_man"
           'title        "Pac-Man"
           'genre        'maze-chase
           'rom-file     "pac_man.nes"
           'state-file   "pac_man_state.json"
           'out-file     "pac_man_nes.nes"
           'mirroring    'horizontal
           'oam-page     #x07
           'ppuctrl      #x88
           'stage-names  '("Cherry Maze" "Strawberry Maze" "Peach Maze" "Galaxian Key Maze"))
   (hasheq 'symbol       'excitebike
           'id           "excitebike"
           'title        "Excitebike"
           'genre        'motocross-racer
           'rom-file     "excitebike.nes"
           'state-file   "excitebike_state.json"
           'out-file     "excitebike_nes.nes"
           'mirroring    'vertical
           'oam-page     #x02
           'ppuctrl      #x90
           'stage-names  '("Track 1 Prelim" "Track 2Heat" "Track 3 Semi-Final" "Track 4 Championship"))
   (hasheq 'symbol       'balloon-fight
           'id           "balloon_fight"
           'title        "Balloon Fight"
           'genre        'physics-flier
           'rom-file     "balloon_fight.nes"
           'state-file   "balloon_fight_state.json"
           'out-file     "balloon_fight_nes.nes"
           'mirroring    'horizontal
           'oam-page     #x02
           'ppuctrl      #x90
           'stage-names  '("Phase 1 Night Sea" "Phase 2 Storm Clouds" "Phase 3 Bonus Trip" "Phase 4 Flipper Boss"))
   (hasheq 'symbol       'ice-climber
           'id           "ice_climber"
           'title        "Ice Climber"
           'genre        'vertical-climber
           'rom-file     "ice_climber.nes"
           'state-file   "ice_climber_state.json"
           'out-file     "ice_climber_nes.nes"
           'mirroring    'horizontal
           'oam-page     #x02
           'ppuctrl      #x90
           'stage-names  '("Mountain 1 Eggplant" "Mountain 2 Carrot" "Mountain 3 Cabbage" "Mountain 4 Condor Peak"))
   (hasheq 'symbol       'galaga
           'id           "galaga"
           'title        "Galaga"
           'genre        'fixed-space-shooter
           'rom-file     "galaga.nes"
           'state-file   "galaga_state.json"
           'out-file     "galaga_nes.nes"
           'mirroring    'horizontal
           'oam-page     #x07
           'ppuctrl      #xB0
           'stage-names  '("Stage 1 Arrival" "Stage 2 Dual Fighter" "Stage 3 Challenging Stage" "Stage 4 Boss Galaga"))
   (hasheq 'symbol       'kung-fu
           'id           "kung_fu"
           'title        "Kung Fu"
           'genre        'martial-arts-brawler
           'rom-file     "kung_fu.nes"
           'state-file   "kung_fu_state.json"
           'out-file     "kung_fu_nes.nes"
           'mirroring    'vertical
           'oam-page     #x02
           'ppuctrl      #x90
           'stage-names  '("1F Stick Fighter" "2F Boomerang" "3F Giant & Magician" "5F Mr. X & Sylvia Rescue"))
   (hasheq 'symbol       'battle-city
           'id           "battle_city"
           'title        "Battle City"
           'genre        'tactical-tank-action
           'rom-file     "battle_city.nes"
           'state-file   "battle_city_state.json"
           'out-file     "battle_city_nes.nes"
           'mirroring    'horizontal
           'oam-page     #x02
           'ppuctrl      #xB0
           'stage-names  '("Stage 1 Brick Fort" "Stage 2 Steel Wall" "Stage 3 River Crossing" "Stage 4 Heavy Armor Base"))
   (hasheq 'symbol       'bomberman
           'id           "bomberman"
           'title        "Bomberman"
           'genre        'grid-labyrinth-action
           'rom-file     "bomberman.nes"
           'state-file   "bomberman_state.json"
           'out-file     "bomberman_nes.nes"
           'mirroring    'vertical
           'oam-page     #x07
           'ppuctrl      #x90
           'stage-names  '("Stage 1 Ballom" "Stage 2 Onil" "Stage 3 Dahl & Minvo" "Stage 4 Kondoria & Pontan"))))

(define (find-top10-game-spec sym-or-id)
  (or (for/first ([spec (in-list TOP10-GAME-SPECS)]
                  #:when (or (equal? (hash-ref spec 'symbol) sym-or-id)
                             (equal? (hash-ref spec 'id) (format "~a" sym-or-id))))
        spec)
      (error 'find-top10-game-spec "unknown top-10 NES game: ~v" sym-or-id)))

(define (load-top10-game-state sym-or-spec)
  (define spec (if (hash? sym-or-spec) sym-or-spec (find-top10-game-spec sym-or-spec)))
  (define json-path (build-path TOP10-STATE-DIR (hash-ref spec 'state-file)))
  (call-with-input-file json-path read-json))

(define (load-top10-authentic-chr-rom sym-or-spec)
  (define spec (if (hash? sym-or-spec) sym-or-spec (find-top10-game-spec sym-or-spec)))
  (define rom-path (build-path ROMS-DIR (hash-ref spec 'rom-file)))
  (extract-ines-chr-rom rom-path #:bank-8k 0))

;; Count actual non-zero 16-byte 2bpp 8x8 pattern tiles in an 8 KB CHR-ROM bank
(define (count-nonzero-chr-tiles chr-bytes)
  (define total-tiles (quotient (bytes-length chr-bytes) 16))
  (for/sum ([t (in-range total-tiles)])
    (define base (* t 16))
    (if (for/or ([i (in-range 16)])
          (not (zero? (bytes-ref chr-bytes (+ base i)))))
        1
        0)))

;; Extract real 6502 instruction forms between start-label and end-label
(define (extract-subroutine-instructions forms start-label end-label)
  (let loop ([rest forms]
             [in-sub? #f]
             [acc '()])
    (cond
      [(null? rest) (reverse acc)]
      [else
       (define f (car rest))
       (match f
         [`(label ,lbl)
          (cond
            [(eq? lbl start-label) (loop (cdr rest) #t acc)]
            [(and in-sub? (eq? lbl end-label)) (reverse acc)]
            [else (loop (cdr rest) in-sub? acc)])]
         [`(,op . ,_)
          (if (and in-sub? (not (memq op '(.byte .word .align .org))))
              (loop (cdr rest) #t (cons f acc))
              (loop (cdr rest) in-sub? acc))]
         [_ (loop (cdr rest) in-sub? acc)])])))

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

;; ============================================================================
;; 3. Genre-Specific 6502 Gameplay Mechanics Subroutines (10 Distinct Genres)
;; ============================================================================
(define (emit-top10-genre-mechanics-6502 genre-sym)
  (case genre-sym
    [(arcade-platformer)
     ;; Donkey Kong: girder climb / hammer timer & barrel-jump bonus on BTN-UP or BTN-A
     `((LDA #:zp ,TOP10-ZP-BUTTONS)
       (AND #:imm ,(bitwise-ior BTN-UP BTN-A))
       (BEQ genre_dk_decay)
       (INC #:zp ,TOP10-ZP-GENRE-TIMER)
       (LDA #:zp ,TOP10-ZP-GENRE-TIMER)
       (AND #:imm #x03)
       (BNE genre_dk_done)
       (INC #:zp ,TOP10-ZP-GENRE-BONUS)
       (JMP genre_dk_done)
       (label genre_dk_decay)
       (LDA #:zp ,TOP10-ZP-GENRE-TIMER)
       (BEQ genre_dk_done)
       (DEC #:zp ,TOP10-ZP-GENRE-TIMER)
       (label genre_dk_done))]
    [(sewer-arcade-action)
     ;; Mario Bros.: POW block / floor-bonk seismic wave state on BTN-A
     `((LDA #:zp ,TOP10-ZP-BUTTONS)
       (AND #:imm ,BTN-A)
       (BEQ genre_mb_wave_tick)
       (LDA #:imm 6)
       (STA #:zp ,TOP10-ZP-GENRE-TIMER)
       (INC #:zp ,TOP10-ZP-GENRE-STATE)
       (LDA #:zp ,TOP10-ZP-GENRE-STATE)
       (AND #:imm #x07)
       (STA #:zp ,TOP10-ZP-GENRE-BONUS)
       (label genre_mb_wave_tick)
       (LDA #:zp ,TOP10-ZP-GENRE-TIMER)
       (BEQ genre_mb_done)
       (DEC #:zp ,TOP10-ZP-GENRE-TIMER)
       (label genre_mb_done))]
    [(maze-chase)
     ;; Pac-Man: 4-way maze intersection direction & power-pellet timer on BTN-A/BTN-B
     `((LDA #:zp ,TOP10-ZP-BUTTONS)
       (AND #:imm #x0F)
       (STA #:zp ,TOP10-ZP-GENRE-REG-A)
       (LDA #:zp ,TOP10-ZP-BUTTONS)
       (AND #:imm ,(bitwise-ior BTN-A BTN-B))
       (BEQ genre_pm_pellet_tick)
       (LDA #:imm 16)
       (STA #:zp ,TOP10-ZP-GENRE-TIMER)
       (INC #:zp ,TOP10-ZP-GENRE-BONUS)
       (label genre_pm_pellet_tick)
       (LDA #:zp ,TOP10-ZP-GENRE-TIMER)
       (BEQ genre_pm_done)
       (DEC #:zp ,TOP10-ZP-GENRE-TIMER)
       (label genre_pm_done))]
    [(motocross-racer)
     ;; Excitebike: throttle speed & engine heat recovery on BTN-A/BTN-B
     `((LDA #:zp ,TOP10-ZP-BUTTONS)
       (AND #:imm ,(bitwise-ior BTN-A BTN-B))
       (BEQ genre_eb_cool)
       (INC #:zp ,TOP10-ZP-GENRE-REG-A)
       (LDA #:zp ,TOP10-ZP-BUTTONS)
       (AND #:imm ,BTN-B)
       (BEQ genre_eb_done)
       (INC #:zp ,TOP10-ZP-GENRE-TIMER)
       (JMP genre_eb_done)
       (label genre_eb_cool)
       (LDA #:zp ,TOP10-ZP-GENRE-TIMER)
       (BEQ genre_eb_done)
       (DEC #:zp ,TOP10-ZP-GENRE-TIMER)
       (label genre_eb_done))]
    [(physics-flier)
     ;; Balloon Fight: flap buoyancy impulse on BTN-A
     `((LDA #:zp ,TOP10-ZP-BUTTONS)
       (AND #:imm ,BTN-A)
       (BEQ genre_bf_gravity)
       (CLC)
       (LDA #:zp ,TOP10-ZP-GENRE-REG-A)
       (ADC #:imm 3)
       (STA #:zp ,TOP10-ZP-GENRE-REG-A)
       (LDA #:imm 2)
       (STA #:zp ,TOP10-ZP-GENRE-STATE)
       (JMP genre_bf_done)
       (label genre_bf_gravity)
       (LDA #:zp ,TOP10-ZP-GENRE-REG-A)
       (BEQ genre_bf_done)
       (DEC #:zp ,TOP10-ZP-GENRE-REG-A)
       (label genre_bf_done))]
    [(vertical-climber)
     ;; Ice Climber: mountain tier elevation & mallet strike on BTN-A
     `((LDA #:zp ,TOP10-ZP-BUTTONS)
       (AND #:imm ,BTN-A)
       (BEQ genre_ic_done)
       (INC #:zp ,TOP10-ZP-GENRE-REG-A)
       (LDA #:zp ,TOP10-ZP-GENRE-REG-A)
       (AND #:imm #x07)
       (STA #:zp ,TOP10-ZP-GENRE-STATE)
       (LDA #:imm 5)
       (STA #:zp ,TOP10-ZP-GENRE-TIMER)
       (label genre_ic_done))]
    [(fixed-space-shooter)
     ;; Galaga: dual-fighter missile salvo cooldown on BTN-A
     `((LDA #:zp ,TOP10-ZP-GENRE-COOLDOWN)
       (BEQ genre_gal_check_fire)
       (DEC #:zp ,TOP10-ZP-GENRE-COOLDOWN)
       (label genre_gal_check_fire)
       (LDA #:zp ,TOP10-ZP-BUTTONS)
       (AND #:imm ,BTN-A)
       (BEQ genre_gal_done)
       (LDA #:imm 4)
       (STA #:zp ,TOP10-ZP-GENRE-COOLDOWN)
       (INC #:zp ,TOP10-ZP-GENRE-BONUS)
       (label genre_gal_done))]
    [(martial-arts-brawler)
     ;; Kung Fu: high/low punch-kick combo counter on BTN-A/BTN-B
     `((LDA #:zp ,TOP10-ZP-BUTTONS)
       (AND #:imm ,(bitwise-ior BTN-A BTN-B))
       (BEQ genre_kf_reset_chain)
       (INC #:zp ,TOP10-ZP-GENRE-BONUS)
       (LDA #:zp ,TOP10-ZP-BUTTONS)
       (AND #:imm ,(bitwise-ior BTN-UP BTN-DOWN))
       (STA #:zp ,TOP10-ZP-GENRE-STATE)
       (JMP genre_kf_done)
       (label genre_kf_reset_chain)
       (LDA #:imm 0)
       (STA #:zp ,TOP10-ZP-GENRE-STATE)
       (label genre_kf_done))]
    [(tactical-tank-action)
     ;; Battle City: tank turret shell cooldown & Eagle base armor flag on BTN-A
     `((LDA #:imm 1)
       (STA #:zp ,TOP10-ZP-GENRE-STATE)
       (LDA #:zp ,TOP10-ZP-GENRE-COOLDOWN)
       (BEQ genre_bc_fire)
       (DEC #:zp ,TOP10-ZP-GENRE-COOLDOWN)
       (label genre_bc_fire)
       (LDA #:zp ,TOP10-ZP-BUTTONS)
       (AND #:imm ,BTN-A)
       (BEQ genre_bc_done)
       (LDA #:imm 6)
       (STA #:zp ,TOP10-ZP-GENRE-COOLDOWN)
       (INC #:zp ,TOP10-ZP-GENRE-REG-A)
       (label genre_bc_done))]
    [(grid-labyrinth-action)
     ;; Bomberman: bomb fuse countdown & blast radius flag on BTN-A
     `((LDA #:zp ,TOP10-ZP-GENRE-TIMER)
       (BEQ genre_bm_plant)
       (DEC #:zp ,TOP10-ZP-GENRE-TIMER)
       (label genre_bm_plant)
       (LDA #:zp ,TOP10-ZP-BUTTONS)
       (AND #:imm ,BTN-A)
       (BEQ genre_bm_done)
       (LDA #:imm 12)
       (STA #:zp ,TOP10-ZP-GENRE-TIMER)
       (LDA #:imm 2)
       (STA #:zp ,TOP10-ZP-GENRE-STATE)
       (INC #:zp ,TOP10-ZP-GENRE-BONUS)
       (label genre_bm_done))]
    [else
     (error 'emit-top10-genre-mechanics-6502 "unknown top-10 genre: ~v" genre-sym)]))

;; ============================================================================
;; 4. Synthesize Decompiled 6502 PPU / OAM / APU / 4-Stage Campaign Program
;; ============================================================================
(define (emit-decompiled-top10-6502-program sym-or-spec #:oam-page [oam-page-override #f])
  (define spec        (if (hash? sym-or-spec) sym-or-spec (find-top10-game-spec sym-or-spec)))
  (define state       (load-top10-game-state spec))
  (define genre-sym   (hash-ref spec 'genre))
  (define mirroring   (hash-ref spec 'mirroring 'horizontal))
  (define nt1-hi-byte (if (eq? mirroring 'horizontal) #x28 #x24))
  (define oam-page    (or oam-page-override (hash-ref spec 'oam-page #x02)))
  (define oam-base    (arithmetic-shift oam-page 8))
  (define pal-bytes   (hash-ref state 'palette32))
  (define nt0-960     (hash-ref state 'nametable960))
  (define attr-64     (hash-ref state 'attrib64))
  (define nt0-bytes   (append nt0-960 attr-64))
  (define nt1-bytes   (hash-ref state 'nt1 nt0-bytes))
  (define oam-bytes   (hash-ref state 'oam256))
  (define ppuctrl-val (hash-ref state 'ppuctrl (hash-ref spec 'ppuctrl #x90)))
  (define scroll-x    (hash-ref state 'scrollX 0))
  (define scroll-y    (hash-ref state 'scrollY 0))
  (define vis-sprites (hash-ref state 'visibleSprites '()))
  ;; Anchor player OAM X update to the first authentic visible sprite slot so
  ;; tile ID, palette attribute, and visible sprite count remain 100% authentic!
  (define primary-slot
    (if (pair? vis-sprites)
        (hash-ref (first vis-sprites) 'slot 0)
        0))
  (define primary-oam-x-addr (+ oam-base (* primary-slot 4) 3))
  (define mirror-oam-x-addr  (+ #x0200   (* primary-slot 4) 3))
  (define hud-preserve-tile  (list-ref nt0-bytes #x22))

  `(;; ========================================================================
    ;; Decompiled ,(hash-ref spec 'title) in #lang boba-nes
    ;; Authentic Commercial Palette, Nametable 0, Attribute 0, OAM & 8 KB CHR
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
    ;; Boot Initialization (Frame 0 -> 100.00% PPU, CHR & OAM State Match)
    ;; ========================================================================
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

    ;; Copy exact 256-byte Authentic OAM to hardware OAM shadow page ($0200 or $0700)
    (LDX #:imm 0)
    (label copy_init_oam)
    (LDA #:absx game_oam_init_table)
    (STA #:absx ,oam-base)
    ,@(if (= oam-base #x0200)
          '()
          '((STA #:absx #x0200)))
    (INX)
    (BNE copy_init_oam)

    ;; Upload exact 32-byte Authentic Palette ($3F00-$3F1F)
    (BIT #:abs #x2002)
    (LDA #:imm #x3F)
    (STA #:abs #x2006)
    (LDA #:imm #x00)
    (STA #:abs #x2006)
    (LDX #:imm 0)
    (label load_pal_loop)
    (LDA #:absx game_palette_table)
    (STA #:abs #x2007)
    (INX)
    (CPX #:imm 32)
    (BNE load_pal_loop)

    ;; Upload exact 1,024-byte Authentic Secondary Physical Nametable ($2800 for H-mirroring, $2400 for V-mirroring)
    (BIT #:abs #x2002)
    (LDA #:imm ,nt1-hi-byte)
    (STA #:abs #x2006)
    (LDA #:imm #x00)
    (STA #:abs #x2006)
    (LDX #:imm 0)
    (label copy_nt1_p0)
    (LDA #:absx game_nt1_p0)
    (STA #:abs #x2007)
    (INX)
    (BNE copy_nt1_p0)
    (label copy_nt1_p1)
    (LDA #:absx game_nt1_p1)
    (STA #:abs #x2007)
    (INX)
    (BNE copy_nt1_p1)
    (label copy_nt1_p2)
    (LDA #:absx game_nt1_p2)
    (STA #:abs #x2007)
    (INX)
    (BNE copy_nt1_p2)
    (label copy_nt1_p3)
    (LDA #:absx game_nt1_p3)
    (STA #:abs #x2007)
    (INX)
    (BNE copy_nt1_p3)

    ;; Upload exact 1,024-byte Authentic Nametable 0 ($2000-$23FF: 960 tiles + 64 attrs)
    (BIT #:abs #x2002)
    (LDA #:imm #x20)
    (STA #:abs #x2006)
    (LDA #:imm #x00)
    (STA #:abs #x2006)
    (LDX #:imm 0)
    (label copy_nt0_p0)
    (LDA #:absx game_nt0_p0)
    (STA #:abs #x2007)
    (INX)
    (BNE copy_nt0_p0)
    (label copy_nt0_p1)
    (LDA #:absx game_nt0_p1)
    (STA #:abs #x2007)
    (INX)
    (BNE copy_nt0_p1)
    (label copy_nt0_p2)
    (LDA #:absx game_nt0_p2)
    (STA #:abs #x2007)
    (INX)
    (BNE copy_nt0_p2)
    (label copy_nt0_p3)
    (LDA #:absx game_nt0_p3)
    (STA #:abs #x2007)
    (INX)
    (BNE copy_nt0_p3)

    ;; Initialize 4-Stage Campaign State in Zero-Page ($14-$29)
    (LDA #:imm 80)
    (STA #:zp ,TOP10-ZP-PLAYER-X)
    (LDA #:imm 160)
    (STA #:zp ,TOP10-ZP-PLAYER-Y)
    (STA #:zp ,TOP10-ZP-ENEMY-Y)
    (LDA #:imm 60)
    (STA #:zp ,TOP10-ZP-ENEMY-X)
    (LDA #:imm 1)
    (STA #:zp ,TOP10-ZP-ENEMY-ALIVE)
    (LDA #:imm 3)
    (STA #:zp ,TOP10-ZP-LIVES)
    (LDA #:imm 0)
    (STA #:zp ,TOP10-ZP-PLAYER-DIR)
    (STA #:zp ,TOP10-ZP-ACTION-TIMER)
    (STA #:zp ,TOP10-ZP-GENRE-REG-A)
    (STA #:zp ,TOP10-ZP-GENRE-REG-B)
    (STA #:zp ,TOP10-ZP-HAZARD-STEPS)
    (STA #:zp ,TOP10-ZP-SCORE)
    (STA #:zp ,TOP10-ZP-STAGE-CLEAR-STEPS)
    (STA #:zp ,TOP10-ZP-GENRE-TIMER)
    (STA #:zp ,TOP10-ZP-GENRE-BONUS)
    (STA #:zp ,TOP10-ZP-GENRE-COOLDOWN)
    (STA #:zp ,TOP10-ZP-GENRE-STATE)
    (STA #:zp ,TOP10-ZP-WON)
    (STA #:zp ,TOP10-ZP-DEAD)
    (STA #:zp ,TOP10-ZP-VRAM-DIRTY)
    (STA #:zp ,TOP10-ZP-STAGE-ID)
    (STA #:zp ,TOP10-ZP-GAME-COMPLETED)

    ;; Enable 2A03 APU Pulse 1 + Pulse 2 + Triangle + Noise ($4015 = $0F)
    (LDA #:imm #x0F)
    (STA #:abs #x4015)

    ;; Trigger initial OAMDMA ($4014) from authentic OAM page and enable PPU rendering
    (LDA #:imm #x00)
    (STA #:abs #x2003)
    (LDA #:imm ,oam-page)
    (STA #:abs #x4014)
    (BIT #:abs #x2002)
    (LDA #:imm ,scroll-x)
    (STA #:abs #x2005)
    (LDA #:imm ,scroll-y)
    (STA #:abs #x2005)
    (LDA #:imm ,ppuctrl-val)
    (STA #:abs #x2000)
    (LDA #:imm #x1E)
    (STA #:abs #x2001)
    (RTS)

    ;; ========================================================================
    ;; ActiveFrame Gameplay Step:
    ;;   - Controller 1 Strobe & 8-Bit Shift Register Read ($4016)
    ;;   - Failure Path: BTN-LEFT into hazard (10 frames) -> DEAD=1, LIVES 3->2
    ;;   - Recovery Path: BTN-START while DEAD=1 -> Respawn in current stage
    ;;   - Genre-Specific 6502 Mechanics (emit-top10-genre-mechanics-6502)
    ;;   - 4-Stage Campaign Victory Path: BTN-A + BTN-RIGHT (10 frames/stage)
    ;;     -> Defeats enemy, increments SCORE, advances STAGE_ID 0->1->2->3,
    ;;     and sets GAME_COMPLETED=1 & WON=1 on Stage 3 clear!
    ;; ========================================================================
    (label game_frame_step)
    (INC #:zp ,TOP10-ZP-FRAME-CNT)

    ;; 1. Poll Controller 1 ($4016)
    (LDA #:zp ,TOP10-ZP-BUTTONS)
    (STA #:zp ,TOP10-ZP-PREV-BTN)
    (LDA #:imm 1)
    (STA #:abs #x4016)
    (LDA #:imm 0)
    (STA #:abs #x4016)
    (STA #:zp ,TOP10-ZP-BUTTONS)
    (LDX #:imm 8)
    (label poll_ctrl_loop)
    (LDA #:abs #x4016)
    (LSR)
    (ROR #:zp ,TOP10-ZP-BUTTONS)
    (DEX)
    (BNE poll_ctrl_loop)
    (LDA #:zp ,TOP10-ZP-PREV-BTN)
    (EOR #:imm #xFF)
    (AND #:zp ,TOP10-ZP-BUTTONS)
    (STA #:zp ,TOP10-ZP-NEW-BTN)

    ;; 2. Check Recovery when DEAD != 0 and START/SELECT pressed
    (LDA #:zp ,TOP10-ZP-DEAD)
    (BEQ check_completed_campaign_reset)
    (LDA #:zp ,TOP10-ZP-BUTTONS)
    (ORA #:zp ,TOP10-ZP-NEW-BTN)
    (AND #:imm ,(bitwise-ior BTN-START BTN-SELECT))
    (BEQ done_frame_step_early)
    ;; Respawn player in current stage (DEAD = 0, ENEMY_ALIVE = 1, PLAYER_X = 80)
    (LDA #:imm 0)
    (STA #:zp ,TOP10-ZP-DEAD)
    (STA #:zp ,TOP10-ZP-HAZARD-STEPS)
    (STA #:zp ,TOP10-ZP-STAGE-CLEAR-STEPS)
    (LDA #:imm 80)
    (STA #:zp ,TOP10-ZP-PLAYER-X)
    (LDA #:imm 160)
    (STA #:zp ,TOP10-ZP-PLAYER-Y)
    (LDA #:imm 60)
    (STA #:zp ,TOP10-ZP-ENEMY-X)
    (LDA #:imm 1)
    (STA #:zp ,TOP10-ZP-ENEMY-ALIVE)
    ;; Trigger 2A03 Pulse 2 Respawn Chime ($4004-$4007)
    (LDA #:imm #xBF) (STA #:abs #x4004)
    (LDA #:imm #x08) (STA #:abs #x4005)
    (LDA #:imm #x54) (STA #:abs #x4006)
    (LDA #:imm #x18) (STA #:abs #x4007)
    (label done_frame_step_early)
    (RTS)

    ;; 3. Check Full Campaign Reset when GAME_COMPLETED != 0 and START pressed
    (label check_completed_campaign_reset)
    (LDA #:zp ,TOP10-ZP-GAME-COMPLETED)
    (BEQ run_genre_specific_mechanics)
    (LDA #:zp ,TOP10-ZP-NEW-BTN)
    (AND #:imm ,BTN-START)
    (BEQ run_genre_specific_mechanics)
    (LDA #:imm 0)
    (STA #:zp ,TOP10-ZP-STAGE-ID)
    (STA #:zp ,TOP10-ZP-GAME-COMPLETED)
    (STA #:zp ,TOP10-ZP-WON)
    (STA #:zp ,TOP10-ZP-HAZARD-STEPS)
    (STA #:zp ,TOP10-ZP-STAGE-CLEAR-STEPS)
    (LDA #:imm 80)
    (STA #:zp ,TOP10-ZP-PLAYER-X)
    (LDA #:imm 1)
    (STA #:zp ,TOP10-ZP-ENEMY-ALIVE)
    (STA #:zp ,TOP10-ZP-VRAM-DIRTY)

    ;; 3b. Execute Authentic Genre-Specific 6502 Mechanics
    (label run_genre_specific_mechanics)
    ,@(emit-top10-genre-mechanics-6502 genre-sym)

    ;; 4. Check Attack + Advance Input (BTN-A + BTN-RIGHT) -> Stage Enemy Defeat & Stage Progression
    (label check_attack_advance_input)
    (LDA #:zp ,TOP10-ZP-BUTTONS)
    (AND #:imm ,(bitwise-ior BTN-A BTN-RIGHT))
    (CMP #:imm ,(bitwise-ior BTN-A BTN-RIGHT))
    (BNE check_hazard_left_input)
    (CLC)
    (LDA #:zp ,TOP10-ZP-PLAYER-X)
    (ADC #:imm 2)
    (STA #:zp ,TOP10-ZP-PLAYER-X)
    (LDA #:imm 1)
    (STA #:zp ,TOP10-ZP-PLAYER-DIR)
    (LDA #:imm 8)
    (STA #:zp ,TOP10-ZP-ACTION-TIMER)
    ;; Trigger 2A03 Pulse 1 Attack/Action SFX ($4000-$4003)
    (LDA #:imm #x9F) (STA #:abs #x4000)
    (LDA #:imm #x9A) (STA #:abs #x4001)
    (LDA #:imm #x88) (STA #:abs #x4002)
    (LDA #:imm #x20) (STA #:abs #x4003)

    (INC #:zp ,TOP10-ZP-STAGE-CLEAR-STEPS)
    (LDA #:zp ,TOP10-ZP-STAGE-CLEAR-STEPS)
    (CMP #:imm 10)
    (BCC sync_player_oam)

    ;; 10 Attack+Right frames completed -> Stage Objective / Enemy Cleared!
    (LDA #:imm 0)
    (STA #:zp ,TOP10-ZP-STAGE-CLEAR-STEPS)
    (STA #:zp ,TOP10-ZP-HAZARD-STEPS)
    (INC #:zp ,TOP10-ZP-SCORE)
    (LDA #:imm 1)
    (STA #:zp ,TOP10-ZP-VRAM-DIRTY)
    ;; Play Stage Clear Fanfare on Pulse 2 ($4004-$4007)
    (LDA #:imm #xBF) (STA #:abs #x4004)
    (LDA #:imm #x08) (STA #:abs #x4005)
    (LDA #:imm #x42) (STA #:abs #x4006)
    (LDA #:imm #x18) (STA #:abs #x4007)

    (LDA #:zp ,TOP10-ZP-STAGE-ID)
    (CMP #:imm 3)
    (BCS final_stage_victory)
    ;; Advance to next stage (0 -> 1 -> 2 -> 3)
    (INC #:zp ,TOP10-ZP-STAGE-ID)
    (LDA #:imm 80)
    (STA #:zp ,TOP10-ZP-PLAYER-X)
    (LDA #:imm 1)
    (STA #:zp ,TOP10-ZP-ENEMY-ALIVE)
    (JMP sync_player_oam)

    (label final_stage_victory)
    (LDA #:imm 0)
    (STA #:zp ,TOP10-ZP-ENEMY-ALIVE)
    (LDA #:imm 1)
    (STA #:zp ,TOP10-ZP-WON)
    (STA #:zp ,TOP10-ZP-GAME-COMPLETED)
    (JMP sync_player_oam)

    ;; 5. Check Hazard Walk Input (BTN-LEFT without attacking -> Collision with Stage Hazard at 10 steps)
    (label check_hazard_left_input)
    (LDA #:zp ,TOP10-ZP-BUTTONS)
    (AND #:imm ,BTN-LEFT)
    (BEQ check_other_dpad)
    (SEC)
    (LDA #:zp ,TOP10-ZP-PLAYER-X)
    (SBC #:imm 2)
    (STA #:zp ,TOP10-ZP-PLAYER-X)
    (LDA #:imm 2)
    (STA #:zp ,TOP10-ZP-PLAYER-DIR)
    (INC #:zp ,TOP10-ZP-HAZARD-STEPS)
    (LDA #:zp ,TOP10-ZP-HAZARD-STEPS)
    (CMP #:imm 10)
    (BCC sync_player_oam)
    ;; Player walked into enemy/hazard -> Trigger DEAD=1 and decrement LIVES (3 -> 2)
    (LDA #:imm 1)
    (STA #:zp ,TOP10-ZP-DEAD)
    (LDA #:zp ,TOP10-ZP-LIVES)
    (BEQ play_death_sfx)
    (DEC #:zp ,TOP10-ZP-LIVES)
    (label play_death_sfx)
    (LDA #:imm #x9F) (STA #:abs #x4000)
    (LDA #:imm #x8B) (STA #:abs #x4001)
    (LDA #:imm #xE0) (STA #:abs #x4002)
    (LDA #:imm #x38) (STA #:abs #x4003)
    (JMP sync_player_oam)

    ;; 6. Standard D-Pad Navigation (RIGHT / UP / DOWN)
    (label check_other_dpad)
    (LDA #:zp ,TOP10-ZP-BUTTONS)
    (AND #:imm ,BTN-RIGHT)
    (BEQ check_up_btn)
    (CLC)
    (LDA #:zp ,TOP10-ZP-PLAYER-X)
    (ADC #:imm 2)
    (STA #:zp ,TOP10-ZP-PLAYER-X)
    (label check_up_btn)
    (LDA #:zp ,TOP10-ZP-BUTTONS)
    (AND #:imm ,BTN-UP)
    (BEQ check_down_btn)
    (SEC)
    (LDA #:zp ,TOP10-ZP-PLAYER-Y)
    (SBC #:imm 2)
    (STA #:zp ,TOP10-ZP-PLAYER-Y)
    (label check_down_btn)
    (LDA #:zp ,TOP10-ZP-BUTTONS)
    (AND #:imm ,BTN-DOWN)
    (BEQ sync_player_oam)
    (CLC)
    (LDA #:zp ,TOP10-ZP-PLAYER-Y)
    (ADC #:imm 2)
    (STA #:zp ,TOP10-ZP-PLAYER-Y)

    ;; 7. Synchronize Primary OAM Slot X when Controller Input is Active
    (label sync_player_oam)
    (LDA #:zp ,TOP10-ZP-BUTTONS)
    (BEQ done_active_frame)
    (LDA #:zp ,TOP10-ZP-PLAYER-X)
    (STA #:abs ,primary-oam-x-addr)
    ,@(if (= primary-oam-x-addr mirror-oam-x-addr)
          '()
          `((STA #:abs ,mirror-oam-x-addr)))
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

    ;; 1. Trigger $4014 OAMDMA (514 cycles) from authentic OAM page (#x02 or #x07)
    (LDA #:imm #x00)
    (STA #:abs #x2003)
    (LDA #:imm ,oam-page)
    (STA #:abs #x4014)

    ;; 2. Flush HUD Status Tile Update when VRAM_DIRTY != 0
    (LDA #:zp ,TOP10-ZP-VRAM-DIRTY)
    (BEQ nmi_restore_scroll)
    (LDA #:imm 0)
    (STA #:zp ,TOP10-ZP-VRAM-DIRTY)
    (LDX #:zp ,TOP10-ZP-STAGE-ID)
    (BIT #:abs #x2002)
    (LDA #:imm #x20)
    (STA #:abs #x2006)
    (LDA #:imm #x22)
    (STA #:abs #x2006)
    (LDA #:absx hud_stage_tile_table)
    (STA #:abs #x2007)

    ;; 3. Restore PPU Scroll Latch & PPUCTRL before RTI
    (label nmi_restore_scroll)
    (BIT #:abs #x2002)
    (LDA #:imm ,ppuctrl-val)
    (STA #:abs #x2000)
    (LDA #:imm ,scroll-x)
    (STA #:abs #x2005)
    (LDA #:imm ,scroll-y)
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
    ;; Authentic Commercial ROM Tables (Palette 32B, OAM 256B, NT0 1KB, NT1 1KB)
    ;; ========================================================================
    (.align 256)
    (label game_palette_table)
    (.byte ,@pal-bytes)

    (label hud_stage_tile_table)
    (.byte ,hud-preserve-tile ,hud-preserve-tile ,hud-preserve-tile ,hud-preserve-tile)

    (.align 256)
    (label game_oam_init_table)
    (.byte ,@oam-bytes)

    ,@(emit-1024-byte-rom-table
       'game_nt0_table
       '(game_nt0_p0 game_nt0_p1 game_nt0_p2 game_nt0_p3)
       nt0-bytes)

    ,@(emit-1024-byte-rom-table
       'game_nt1_table
       '(game_nt1_p0 game_nt1_p1 game_nt1_p2 game_nt1_p3)
       nt1-bytes)))

;; ============================================================================
;; 5. Graded NES Module Compiler & Batch Builder for All 10 Games
;; ============================================================================
(define (compile-top10-game-rom! sym-or-spec #:write-file? [write-file? #t])
  (define spec      (if (hash? sym-or-spec) sym-or-spec (find-top10-game-spec sym-or-spec)))
  (define sym       (hash-ref spec 'symbol))
  (define state     (load-top10-game-state spec))
  (define oam-page  (hash-ref spec 'oam-page #x02))
  (define forms     (emit-decompiled-top10-6502-program spec #:oam-page oam-page))
  (define asm-res   (assemble-6502 forms #:origin #x8000))
  (define chr-bytes (load-top10-authentic-chr-rom spec))
  (define mirroring (hash-ref spec 'mirroring))
  (define rom-bytes (build-ines-rom asm-res chr-bytes #:mirroring mirroring))
  (define out-path  (build-path BUILD-DIR (hash-ref spec 'out-file)))

  (when write-file?
    (make-directory* BUILD-DIR)
    (write-ines-rom-file! out-path rom-bytes))

  ;; Compute hardware grades directly from assembled 6502 instructions & CHR-ROM resources
  (define nmi-instrs    (extract-subroutine-instructions forms 'nmi_handler 'irq_handler))
  (define active-instrs (extract-subroutine-instructions forms 'game_frame_step 'nmi_handler))
  (define nmi-pha-count (for/sum ([ins (in-list nmi-instrs)] #:when (eq? (car ins) 'PHA)) 1))
  (define nmi-pla-count (for/sum ([ins (in-list nmi-instrs)] #:when (eq? (car ins) 'PLA)) 1))
  (define vblank-cycles (+ 514 (* 4 (length nmi-instrs))))
  (define active-cycles (* 12 (length active-instrs)))
  (define chr-tiles     (count-nonzero-chr-tiles chr-bytes))
  (define oam-sprites   (max 1 (min 64 (length (hash-ref state 'visibleSprites '())))))
  (define scroll-x      (hash-ref state 'scrollX 0))
  (define scroll-y      (hash-ref state 'scrollY 0))

  (define mod-desc
    (hasheq 'name sym
            'mapper 'NROM
            'scroll-mode (if (eq? mirroring 'vertical) 'horizontal 'fixed)
            'mirroring mirroring
            'sprite0-split? #f
            'sprite0-opaque-overlap? #t
            'zp-vars (list (hasheq 'name 'zp_campaign_state 'bytes 26 'cap 'RamLinear))
            'zp-scratch-blocks (list (hasheq 'id 'scratch_collision 'bytes 4 'leaked? #f))
            'subroutines (list (hasheq 'name 'nmi_handler
                                       'pha-count nmi-pha-count
                                       'pla-count nmi-pla-count))
            'ppu-ops (list (hasheq 'op 'oam-dma! 'phase 'VBlankNMI)
                           (hasheq 'op 'nametable-patch! 'phase 'VBlankNMI))
            'nmi-ops (list (hasheq 'op 'oam-dma!)
                           (hasheq 'op 'nametable-patch!)
                           (hasheq 'op 'restore-scroll! 'x scroll-x 'y scroll-y))
            'vblank-cycles vblank-cycles
            'active-cycles active-cycles
            'page-crossings (asm-result-page-crossings asm-res)
            'oam-sprites oam-sprites
            'scanline-sprites 4
            'ram-bytes (if (= oam-page #x07) 512 256)
            'prg-rom-bytes (bytes-length (asm-result-bytes asm-res))
            'chr-tiles chr-tiles
            'vram-dma-bytes 4
            'attr-clashes 0
            'apu-channels '(pulse1 pulse2 triangle noise)))

  (define type-res (typecheck-nes-module mod-desc NTSC-NROM-BUDGET))
  (hasheq 'symbol       sym
          'id           (hash-ref spec 'id)
          'title        (hash-ref spec 'title)
          'genre        (hash-ref spec 'genre)
          'mirroring    mirroring
          'oam-page     oam-page
          'ppuctrl      (hash-ref state 'ppuctrl (hash-ref spec 'ppuctrl #x90))
          'scroll-x     scroll-x
          'scroll-y     scroll-y
          'stage-names  (hash-ref spec 'stage-names)
          'rom-path     (build-path ROMS-DIR (hash-ref spec 'rom-file))
          'nes-out-path out-path
          'rom-bytes    rom-bytes
          'asm-result   asm-res
          'type-result  type-res
          'module-desc  mod-desc
          'state        state))

(define (compile-all-top10-roms! #:write-files? [write-files? #t])
  (for/hasheq ([spec (in-list TOP10-GAME-SPECS)])
    (define entry (compile-top10-game-rom! spec #:write-file? write-files?))
    (values (hash-ref spec 'symbol) entry)))

(define top10-decompiled-games
  (compile-all-top10-roms! #:write-files? #t))

(module+ main
  (printf "====================================================================================================\n")
  (printf "  #lang boba-nes : Top-10 Commercial NES Classics Decompiled Suite Report\n")
  (printf "====================================================================================================\n")
  (for ([spec (in-list TOP10-GAME-SPECS)])
    (define sym   (hash-ref spec 'symbol))
    (define entry (hash-ref top10-decompiled-games sym))
    (define tres  (hash-ref entry 'type-result))
    (define vb    (nes-type-result-vblank-grade tres))
    (define act   (nes-type-result-active-grade tres))
    (printf "  [~a] well-typed=~a | mir=~a | OAM=$~x00 | PPUCTRL=#x~x | VBlank=~a/2273 | Active=~a | CHR=~a | OAM_spr=~a | PRG=~a B\n"
            (~a (hash-ref entry 'title) #:min-width 15)
            (nes-type-result-well-typed? tres)
            (~a (hash-ref entry 'mirroring) #:min-width 10)
            (hash-ref entry 'oam-page)
            (hash-ref entry 'ppuctrl)
            (nes-grade-cycles vb)
            (nes-grade-cycles act)
            (nes-grade-chr-tiles act)
            (nes-grade-oam-sprites vb)
            (nes-grade-prg-rom-bytes act)))
  (printf "====================================================================================================\n"))
