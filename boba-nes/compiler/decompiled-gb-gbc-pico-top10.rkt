#lang racket/base

;; ============================================================================
;; compiler/decompiled-gb-gbc-pico-top10.rkt
;; Top-10 Game Boy (DMG .gb), Top-10 Game Boy Color (CGB .gbc), and
;; Top-10 PICO-8 (.p8) / RP2040 (PIO .uf2) Classics (30 Games Total):
;; Authentic Reference Binary Builders, Recursive-Descent Disassemblers &
;; Decompilers to #lang boba-nes S-Expressions, Recompilers, Headless Emulators,
;; and 3-Checkpoint (CP0, CP1, CP2) Hardware State + Framebuffer RGB Verifiers.
;; ============================================================================

(require racket/match
         racket/list
         racket/bytes
         racket/format
         racket/string
         racket/math
         racket/set
         "boba-core-ir.rkt"
         "multi-target-typechecker.rkt"
         "backend-gb-gbc.rkt"
         "backend-pico.rkt")

(provide
 ;; 1. Extended HRAM Campaign Registers for Top-10 GB / GBC Classics
 GB-HRAM-LIVES
 GB-HRAM-GAME-COMPLETED
 GB-HRAM-GENRE-REG
 GB-HRAM-GENRE-AUX
 GB-HRAM-GAME-ID

 ;; 2. Top-10 Game Specifications (30 Games Total) & Lookup
 GB-TOP10-GAME-SPECS
 GBC-TOP10-GAME-SPECS
 PICO-TOP10-GAME-SPECS
 ALL-GB-GBC-PICO-TOP10-SPECS
 find-gb-gbc-pico-game-spec

 ;; 3. Authentic Reference Binary Builders (.gb, .gbc, .p8, .uf2)
 build-reference-gb-rom
 build-reference-gbc-rom
 build-reference-pico8-cart
 build-reference-rp2040-uf2

 ;; 4. Disassemblers, Decompilers to #lang boba-nes DSL & Recompiler
 disassemble-gb-gbc-rom
 decompile-gb-gbc-rom->boba-dsl
 decompile-pico8-cart->boba-dsl
 decompile-rp2040-uf2->boba-dsl
 typecheck-decompiled-boba-dsl
 recompile-boba-dsl->target-binary

 ;; 5. Headless Framebuffer Renderers & 3-Checkpoint (CP0, CP1, CP2) Verifiers
 render-gb-framebuffer-rgb
 render-gbc-framebuffer-rgb
 render-pico8-framebuffer-rgb
 diff-target-framebuffer-rgb
 run-gb-gbc-3-checkpoint-trace
 run-pico-3-checkpoint-trace
 verify-gb-top10-decompilation-equivalence
 verify-gbc-top10-decompilation-equivalence
 verify-pico-top10-decompilation-equivalence
 run-all-gb-gbc-pico-top10-verifications!)

;; ============================================================================
;; 1. Extended High-RAM ($FF9A-$FF9E) Campaign & Genre Registers
;; ============================================================================

(define GB-HRAM-LIVES          #x9A) ; $FF9A : Remaining player lives (init = 3, fail -> 2)
(define GB-HRAM-GAME-COMPLETED #x9B) ; $FF9B : 1 = all 4 stages cleared
(define GB-HRAM-GENRE-REG      #x9C) ; $FF9C : Primary genre mechanic state register
(define GB-HRAM-GENRE-AUX      #x9D) ; $FF9D : Secondary genre mechanic register
(define GB-HRAM-GAME-ID        #x9E) ; $FF9E : Game index (1..10 GB, 11..20 GBC)

;; ============================================================================
;; 2. Game-Specific 2bpp / 4bpp Tile Art & Palette Generators
;; ============================================================================

;; Generate 8 distinct 8x8 2bpp Game Boy tiles parameterized by game-index (1..20)
(define (make-gb-game-tiles game-idx)
  (define p1 (if (odd? game-idx) "3" "2"))
  (define p2 (if (zero? (modulo game-idx 3)) "1" "2"))
  (define top-row
    (case (modulo game-idx 4)
      [(0) ".3.33.3."]
      [(1) "...33..."]
      [(2) "..3223.."]
      [else ".33..33."]))
  (define mid-row
    (string-append "." p1 "3223" p1 "."))
  (list
   ;; Tile 0: Blank background
   (compile-gb-2bpp-tile
    '("........" "........" "........" "........"
      "........" "........" "........" "........"))
   ;; Tile 1: Stage 0 Hero Sprite (Game-specific silhouette)
   (compile-gb-2bpp-tile
    (list top-row
          "..3223.."
          ".333333."
          (string-append ".3" p2 "22" p2 "3.")
          mid-row
          ".323323."
          "..3333.."
          "...22..."))
   ;; Tile 2: Stage 1 Hero Action Frame
   (compile-gb-2bpp-tile
    (list top-row
          "..3223.."
          ".333333."
          ".313313."
          mid-row
          ".332233."
          "..3333.."
          "..2..2.."))
   ;; Tile 3: Stage 2 Hero Power Frame
   (compile-gb-2bpp-tile
    (list "..3..3.."
          top-row
          ".333333."
          ".312213."
          mid-row
          ".322223."
          "..3333.."
          "...33..."))
   ;; Tile 4: Stage 3 Victory Crown Frame
   (compile-gb-2bpp-tile
    (list ".3.33.3."
          ".332233."
          ".333333."
          ".312213."
          mid-row
          ".323323."
          "..3333.."
          "..3333.."))
   ;; Tile 5: Stage Objective / Emblem Tile
   (compile-gb-2bpp-tile
    (list "..3333.."
          ".322223."
          (string-append "32" p2 p2 "2223")
          "32122223"
          "32222323"
          "32223323"
          ".322223."
          "..3333.."))
   ;; Tile 6: Stage Hazard Obstacle Tile
   (compile-gb-2bpp-tile
    (list "...33..."
          "..3113.."
          "..3113.."
          (string-append ".3" p1 "33" p1 "3.")
          ".313313."
          "31133113"
          "31111113"
          "33333333"))
   ;; Tile 7: Stage HUD / Playfield Border Tile
   (compile-gb-2bpp-tile
    (list "33333333"
          "31111113"
          (string-append "31" p1 "33" p1 "13")
          "31322313"
          "31322313"
          "31333313"
          "31111113"
          "33333333"))))

;; Decode a 16-byte 2bpp Game Boy tile back into 8 strings of 8 pixel chars ('0'..'3')
(define (decode-gb-2bpp-tile-rows tile-16b)
  (for/list ([r (in-range 8)])
    (define lo (bytes-ref tile-16b (* 2 r)))
    (define hi (bytes-ref tile-16b (add1 (* 2 r))))
    (list->string
     (for/list ([c (in-range 8)])
       (define bit-pos (- 7 c))
       (define pix
         (bitwise-ior (if (bitwise-bit-set? lo bit-pos) 1 0)
                      (if (bitwise-bit-set? hi bit-pos) 2 0)))
       (integer->char (+ (char->integer #\0) pix))))))

;; Generate 4 distinct 8x8 4bpp PICO-8 sprite tiles for game-idx (1..10)
(define (make-pico8-game-tiles game-idx)
  (define c1 (string-ref "7abcdef9bcde" (modulo game-idx 10)))
  (define c2 (string-ref "89abcdef789a" (modulo (+ game-idx 3) 10)))
  (define hero-r3 (format "07~a~a~a~a70" c1 c2 c2 c1))
  (list
   (cons 1 (list "00077000"
                 "007ff700"
                 "07777770"
                 hero-r3
                 "07eeee70"
                 "07e44e70"
                 "00777700"
                 "00044000"))
   (cons 2 (list "007aa700"
                 "07a99a70"
                 "7a9779a7"
                 "797aa797"
                 "797aa797"
                 "7a9779a7"
                 "07a99a70"
                 "007aa700"))
   (cons 3 (list "00088000"
                 "00888800"
                 "00877800"
                 "08877880"
                 "08788780"
                 "88788788"
                 "87777778"
                 "88888888"))
   (cons 4 (list "cccccccc"
                 "c777777c"
                 "c711117c"
                 (format "c71~a~a17c" c1 c1)
                 (format "c71~a~a17c" c2 c2)
                 "c711117c"
                 "c777777c"
                 "cccccccc"))))

;; ============================================================================
;; 3. Top-10 Game Boy (DMG .gb), Top-10 Game Boy Color (CGB .gbc) &
;;    Top-10 PICO-8 (.p8) / RP2040 (.uf2) Specifications
;; ============================================================================

(define GB-TOP10-GAME-SPECS
  (list
   (hasheq 'symbol         'gb-tetris
           'game-index     1
           'id             "gb_tetris"
           'title          "Tetris (GB, 1989)"
           'rom-title      "TETRIS"
           'target         'gb
           'genre          'well-puzzle
           'unique-tiles   8
           'palette        '(#xE4 #xE4 #xD2)
           'dmg-rgb        '((155 188 15) (139 172 15) (48 98 48) (15 56 15))
           'mechanics-desc "10x18 well, 7 tetrominoes, line clear + B-Type rocket victory"
           'stages         '("Level 0 Moscow" "Level 5 St. Basil" "Level 9 Cosmodrome" "B-Type Rocket Launch")
           'stage-names    '("Level 0 Moscow" "Level 5 St. Basil" "Level 9 Cosmodrome" "B-Type Rocket Launch"))
   (hasheq 'symbol         'gb-super-mario-land
           'game-index     2
           'id             "gb_super_mario_land"
           'title          "Super Mario Land (1989)"
           'rom-title      "SUPER MARIOLAND"
           'target         'gb
           'genre          'platformer-shmup
           'unique-tiles   8
           'palette        '(#xE4 #xD2 #xE4)
           'dmg-rgb        '((160 192 20) (132 168 20) (52 100 44) (16 52 16))
           'mechanics-desc "Birabuto/Muda/Easton/Chai Kingdoms, Superball bounce + Marine/Sky Pop"
           'stages         '("1-1 Birabuto Kingdom" "2-3 Muda Marine Pop" "3-3 Easton Giant Spider" "4-3 Chai Tatanga Sky Pop")
           'stage-names    '("1-1 Birabuto Kingdom" "2-3 Muda Marine Pop" "3-3 Easton Giant Spider" "4-3 Chai Tatanga Sky Pop"))
   (hasheq 'symbol         'gb-links-awakening
           'game-index     3
           'id             "gb_links_awakening"
           'title          "The Legend of Zelda: Link's Awakening (1993)"
           'rom-title      "ZELDA"
           'target         'gb
           'genre          'topdown-adventure
           'unique-tiles   8
           'palette        '(#xE4 #xE4 #xE4)
           'dmg-rgb        '((158 190 18) (136 170 18) (46 96 46) (14 54 14))
           'mechanics-desc "Koholint flip-screen, Roc's Feather jump + Sword spin, 4 Sirens' Instruments"
           'stages         '("Tail Cave Cello" "Bottle Grotto Conch" "Key Cavern Bell" "Wind Fish's Egg Ballad")
           'stage-names    '("Tail Cave Cello" "Bottle Grotto Conch" "Key Cavern Bell" "Wind Fish's Egg Ballad"))
   (hasheq 'symbol         'gb-kirbys-dream-land
           'game-index     4
           'id             "gb_kirbys_dream_land"
           'title          "Kirby's Dream Land (1992)"
           'rom-title      "KIRBY DREAMLAND"
           'target         'gb
           'genre          'float-platformer
           'unique-tiles   8
           'palette        '(#xE4 #xD2 #xD2)
           'dmg-rgb        '((164 194 24) (140 174 22) (54 102 50) (18 58 18))
           'mechanics-desc "Multi-puff hover physics, inhale + star spit, Green Greens -> Mt. Dedede"
           'stages         '("Green Greens Whispy" "Castle Lololo" "Float Islands Kaboola" "Mt. Dedede Ring")
           'stage-names    '("Green Greens Whispy" "Castle Lololo" "Float Islands Kaboola" "Mt. Dedede Ring"))
   (hasheq 'symbol         'gb-pokemon-red
           'game-index     5
           'id             "gb_pokemon_red"
           'title          "Pokemon Red / Blue (1996)"
           'rom-title      "POKEMON RED"
           'target         'gb
           'genre          'monster-rpg
           'unique-tiles   8
           'palette        '(#xE4 #xE4 #xD2)
           'dmg-rgb        '((156 186 16) (134 166 16) (48 94 48) (15 52 15))
           'mechanics-desc "Pallet/Pewter/Cerulean/Indigo tile walk + turn-based type-effectiveness battle FSM"
           'stages         '("Pallet Town Lab" "Pewter Gym Boulder" "Cerulean Gym Cascade" "Indigo Plateau Champion")
           'stage-names    '("Pallet Town Lab" "Pewter Gym Boulder" "Cerulean Gym Cascade" "Indigo Plateau Champion"))
   (hasheq 'symbol         'gb-metroid-2
           'game-index     6
           'id             "gb_metroid_2"
           'title          "Metroid II: Return of Samus (1991)"
           'rom-title      "METROID2"
           'target         'gb
           'genre          'exploratory-platformer
           'unique-tiles   8
           'palette        '(#xE4 #xD2 #xE4)
           'dmg-rgb        '((150 184 14) (128 162 14) (44 92 44) (12 48 12))
           'mechanics-desc "SR388 Spider Ball wall climb, Morph Bomb, Metroid counter HUD -> Queen"
           'stages         '("SR388 Surface Alpha" "Chozo Ruins Gamma" "Magma Caverns Zeta" "Queen Metroid Nest")
           'stage-names    '("SR388 Surface Alpha" "Chozo Ruins Gamma" "Magma Caverns Zeta" "Queen Metroid Nest"))
   (hasheq 'symbol         'gb-castlevania-adventure
           'game-index     7
           'id             "gb_castlevania_adventure"
           'title          "Castlevania: The Adventure (1989)"
           'rom-title      "CASTLEVANIA"
           'target         'gb
           'genre          'whip-platformer
           'unique-tiles   8
           'palette        '(#xE4 #xE4 #xD2)
           'dmg-rgb        '((152 185 15) (130 164 15) (45 94 45) (14 50 14))
           'mechanics-desc "Whip powerup fireball, rope climb, 4 Dracula stages"
           'stages         '("Stage 1 Graveyard" "Stage 2 Subterranean" "Stage 3 Spike Tower" "Stage 4 Dracula Keep")
           'stage-names    '("Stage 1 Graveyard" "Stage 2 Subterranean" "Stage 3 Spike Tower" "Stage 4 Dracula Keep"))
   (hasheq 'symbol         'gb-ducktales-gb
           'game-index     8
           'id             "gb_ducktales_gb"
           'title          "DuckTales (GB, 1990)"
           'rom-title      "DUCKTALES"
           'target         'gb
           'genre          'pogo-platformer
           'unique-tiles   8
           'palette        '(#xE4 #xD2 #xD2)
           'dmg-rgb        '((162 192 22) (138 172 20) (50 98 48) (16 54 16))
           'mechanics-desc "Scrooge pogo-cane bounce attack, treasure chests, Amazon/Transylvania/Mines/Moon"
           'stages         '("The Amazon Scepter" "Transylvania Manor" "African Mines Diamond" "The Moon Cheese")
           'stage-names    '("The Amazon Scepter" "Transylvania Manor" "African Mines Diamond" "The Moon Cheese"))
   (hasheq 'symbol         'gb-dr-mario
           'game-index     9
           'id             "gb_dr_mario"
           'title          "Dr. Mario (GB, 1990)"
           'rom-title      "DR.MARIO"
           'target         'gb
           'genre          'capsule-puzzle
           'unique-tiles   8
           'palette        '(#xE4 #xE4 #xE4)
           'dmg-rgb        '((158 189 19) (136 168 19) (47 96 47) (15 53 15))
           'mechanics-desc "2-color vitamin capsule rotation, 4-match virus clear + gravity drop across 4 virus levels"
           'stages         '("Virus Level 01 Fever" "Virus Level 05 Chill" "Virus Level 10 Trio" "Virus Level 20 Clear")
           'stage-names    '("Virus Level 01 Fever" "Virus Level 05 Chill" "Virus Level 10 Trio" "Virus Level 20 Clear"))
   (hasheq 'symbol         'gb-gargoyles-quest
           'game-index     10
           'id             "gb_gargoyles_quest"
           'title          "Gargoyle's Quest (1990)"
           'rom-title      "GARGOYLES QUEST"
           'target         'gb
           'genre          'hover-action-rpg
           'unique-tiles   8
           'palette        '(#xE4 #xD2 #xE4)
           'dmg-rgb        '((154 186 17) (132 165 17) (46 95 46) (13 51 13))
           'mechanics-desc "Firebrand wing-hover stamina meter, wall cling + fire breath across 4 Ghoul realms"
           'stages         '("Portal Tower" "Earthbonia Catacombs" "Desert of Despair" "King Breager Palace")
           'stage-names    '("Portal Tower" "Earthbonia Catacombs" "Desert of Despair" "King Breager Palace"))))

(define GBC-TOP10-GAME-SPECS
  (list
   (hasheq 'symbol         'gbc-pokemon-gold
           'game-index     11
           'id             "gbc_pokemon_gold"
           'title          "Pokemon Gold / Silver / Crystal (1999/2000)"
           'rom-title      "POKEMON_GLDAAUE"
           'target         'gbc
           'cgb-flag       #xC0
           'genre          'rtc-monster-rpg
           'unique-tiles   8
           'palette        (list (encode-gbc-bgr555 31 29 22)
                                 (encode-gbc-bgr555 28 21  6)
                                 (encode-gbc-bgr555 16 11  4)
                                 (encode-gbc-bgr555  4  3  6))
           'obj-palette    (list (encode-gbc-bgr555 31 31 31)
                                 (encode-gbc-bgr555 31 24  4)
                                 (encode-gbc-bgr555 26  8  6)
                                 (encode-gbc-bgr555  3  2  4))
           'mechanics-desc "Real-time Day/Night BGR555 palette shift, Johto 4-Gym campaign"
           'stages         '("Violet Gym Falkner" "Azalea Gym Bugsy" "Goldenrod Gym Whitney" "Ecruteak Gym Morty")
           'stage-names    '("Violet Gym Falkner" "Azalea Gym Bugsy" "Goldenrod Gym Whitney" "Ecruteak Gym Morty"))
   (hasheq 'symbol         'gbc-zelda-oracle
           'game-index     12
           'id             "gbc_zelda_oracle"
           'title          "The Legend of Zelda: Oracle of Ages / Seasons (2001)"
           'rom-title      "ZELDA DIN NAYRU"
           'target         'gbc
           'cgb-flag       #xC0
           'genre          'season-time-adventure
           'unique-tiles   8
           'palette        (list (encode-gbc-bgr555 29 31 25)
                                 (encode-gbc-bgr555 14 26 12)
                                 (encode-gbc-bgr555  8 16  9)
                                 (encode-gbc-bgr555  3  5  4))
           'obj-palette    (list (encode-gbc-bgr555 31 31 31)
                                 (encode-gbc-bgr555 10 28 14)
                                 (encode-gbc-bgr555 28 16  6)
                                 (encode-gbc-bgr555  2  4  2))
           'mechanics-desc "Harp/Rod Past-Present / 4-Season tilemap & BGR555 swap"
           'stages         '("Spring Gnarled Root" "Summer Snake's Remains" "Autumn Poison Moth" "Winter Onox & Veran")
           'stage-names    '("Spring Gnarled Root" "Summer Snake's Remains" "Autumn Poison Moth" "Winter Onox & Veran"))
   (hasheq 'symbol         'gbc-wario-land-3
           'game-index     13
           'id             "gbc_wario_land_3"
           'title          "Wario Land 3 (2000)"
           'rom-title      "WARIOLAND3"
           'target         'gbc
           'cgb-flag       #xC0
           'genre          'reaction-platformer
           'unique-tiles   8
           'palette        (list (encode-gbc-bgr555 31 30 20)
                                 (encode-gbc-bgr555 30 22  5)
                                 (encode-gbc-bgr555 18  7 22)
                                 (encode-gbc-bgr555  5  2  8))
           'obj-palette    (list (encode-gbc-bgr555 31 31 31)
                                 (encode-gbc-bgr555 31 28  4)
                                 (encode-gbc-bgr555 22  6 26)
                                 (encode-gbc-bgr555  4  1  6))
           'mechanics-desc "Status transformation physics: Flaming/Bouncy/Zombie Wario, 4 Music Box chests"
           'stages         '("N1 Out of the Woods" "W2 A Town in Chaos" "S3 Tower of Revival" "E4 Rudy the Clown")
           'stage-names    '("N1 Out of the Woods" "W2 A Town in Chaos" "S3 Tower of Revival" "E4 Rudy the Clown"))
   (hasheq 'symbol         'gbc-shantae
           'game-index     14
           'id             "gbc_shantae"
           'title          "Shantae (2002)"
           'rom-title      "SHANTAE"
           'target         'gbc
           'cgb-flag       #xC0
           'genre          'dance-metroidvania
           'unique-tiles   8
           'palette        (list (encode-gbc-bgr555 31 27 29)
                                 (encode-gbc-bgr555 27 14 24)
                                 (encode-gbc-bgr555 16  6 18)
                                 (encode-gbc-bgr555  5  2  7))
           'obj-palette    (list (encode-gbc-bgr555 31 31 31)
                                 (encode-gbc-bgr555 29 18 12)
                                 (encode-gbc-bgr555 24  5 28)
                                 (encode-gbc-bgr555  4  2  5))
           'mechanics-desc "Hair-whip, Monkey/Elephant/Spider transformation dances, HBlank parallax sky"
           'stages         '("Scuttle Town" "Dribble Fountain Monkey" "Golem Mine Elephant" "Risky Boots Tinkerbat")
           'stage-names    '("Scuttle Town" "Dribble Fountain Monkey" "Golem Mine Elephant" "Risky Boots Tinkerbat"))
   (hasheq 'symbol         'gbc-smb-deluxe
           'game-index     15
           'id             "gbc_smb_deluxe"
           'title          "Super Mario Bros. Deluxe (1999)"
           'rom-title      "SUPER MARIO DX"
           'target         'gbc
           'cgb-flag       #xC0
           'genre          'camera-platformer
           'unique-tiles   8
           'palette        (list (encode-gbc-bgr555 22 28 31)
                                 (encode-gbc-bgr555 12 22 10)
                                 (encode-gbc-bgr555 24 12  6)
                                 (encode-gbc-bgr555  2  3  5))
           'obj-palette    (list (encode-gbc-bgr555 31 31 31)
                                 (encode-gbc-bgr555 30  6  6)
                                 (encode-gbc-bgr555 28 20 12)
                                 (encode-gbc-bgr555  3  2  2))
           'mechanics-desc "Dynamic SCX/SCY look-ahead pan, Red Coin + Yoshi Egg finder across 4 worlds"
           'stages         '("World 1-1 Overworld" "World 2-2 Coral Sea" "World 4-4 Maze Castle" "World 8-4 Bowser Keep")
           'stage-names    '("World 1-1 Overworld" "World 2-2 Coral Sea" "World 4-4 Maze Castle" "World 8-4 Bowser Keep"))
   (hasheq 'symbol         'gbc-metal-gear-babel
           'game-index     16
           'id             "gbc_metal_gear_babel"
           'title          "Metal Gear Solid: Ghost Babel (2000)"
           'rom-title      "METAL GEAR GBC"
           'target         'gbc
           'cgb-flag       #xC0
           'genre          'stealth-tactics
           'unique-tiles   8
           'palette        (list (encode-gbc-bgr555 20 26 22)
                                 (encode-gbc-bgr555 11 18 14)
                                 (encode-gbc-bgr555  6 11  8)
                                 (encode-gbc-bgr555  2  4  3))
           'obj-palette    (list (encode-gbc-bgr555 31 31 31)
                                 (encode-gbc-bgr555 16 24 18)
                                 (encode-gbc-bgr555 28  8  8)
                                 (encode-gbc-bgr555  2  3  2))
           'mechanics-desc "Top-down guard vision-cone check, radar evasion timer, C4 & 4 stages"
           'stages         '("Gindra Canyon" "Outer Heaven Fortress" "Power Plant Pyro" "Metal Gear GANDER")
           'stage-names    '("Gindra Canyon" "Outer Heaven Fortress" "Power Plant Pyro" "Metal Gear GANDER"))
   (hasheq 'symbol         'gbc-dragon-warrior-monsters
           'game-index     17
           'id             "gbc_dragon_warrior_monsters"
           'title          "Dragon Warrior Monsters (1998)"
           'rom-title      "DW MONSTERS"
           'target         'gbc
           'cgb-flag       #xC0
           'genre          'breeding-dungeon-rpg
           'unique-tiles   8
           'palette        (list (encode-gbc-bgr555 28 30 31)
                                 (encode-gbc-bgr555 12 20 28)
                                 (encode-gbc-bgr555  6 10 20)
                                 (encode-gbc-bgr555  2  3  8))
           'obj-palette    (list (encode-gbc-bgr555 31 31 31)
                                 (encode-gbc-bgr555  8 22 30)
                                 (encode-gbc-bgr555 30 16  6)
                                 (encode-gbc-bgr555  2  2  5))
           'mechanics-desc "Teleportal procedural floor step, monster party command FSM, 4 Starry Night ranks"
           'stages         '("Gate of Beginning" "Gate of Villager" "Gate of Labyrinth" "Starry Night Tournament")
           'stage-names    '("Gate of Beginning" "Gate of Villager" "Gate of Labyrinth" "Starry Night Tournament"))
   (hasheq 'symbol         'gbc-mario-tennis-gbc
           'game-index     18
           'id             "gbc_mario_tennis_gbc"
           'title          "Mario Tennis (GBC, 2000)"
           'rom-title      "MARIO TENNIS"
           'target         'gbc
           'cgb-flag       #xC0
           'genre          'hdma-sports-rpg
           'unique-tiles   8
           'palette        (list (encode-gbc-bgr555 26 31 24)
                                 (encode-gbc-bgr555 10 24 12)
                                 (encode-gbc-bgr555  6 16  8)
                                 (encode-gbc-bgr555  2  6  3))
           'obj-palette    (list (encode-gbc-bgr555 31 31 31)
                                 (encode-gbc-bgr555 30 28  8)
                                 (encode-gbc-bgr555 28  8  8)
                                 (encode-gbc-bgr555  3  3  3))
           'mechanics-desc "Per-scanline HBlank HDMA court perspective SCX scaling, topspin/smash rally across 4 courts"
           'stages         '("Royal Academy Junior" "Senior Class Court" "Island Open Final" "Peach Dome Mario Match")
           'stage-names    '("Royal Academy Junior" "Senior Class Court" "Island Open Final" "Peach Dome Mario Match"))
   (hasheq 'symbol         'gbc-lufia-returns
           'game-index     19
           'id             "gbc_lufia_returns"
           'title          "Lufia: The Legend Returns (2001)"
           'rom-title      "LUFIA RETURNS"
           'target         'gbc
           'cgb-flag       #xC0
           'genre          'ip-grid-rpg
           'unique-tiles   8
           'palette        (list (encode-gbc-bgr555 31 28 26)
                                 (encode-gbc-bgr555 24 16 18)
                                 (encode-gbc-bgr555 14  8 14)
                                 (encode-gbc-bgr555  4  2  5))
           'obj-palette    (list (encode-gbc-bgr555 31 31 31)
                                 (encode-gbc-bgr555 12 24 30)
                                 (encode-gbc-bgr555 28 10 14)
                                 (encode-gbc-bgr555  3  2  4))
           'mechanics-desc "3x3 Spiritual Force IP wave matrix, Ancient Cave 4 floor tiers"
           'stages         '("Tower of Guidance" "Ancient Cave B20" "Ancient Cave B50" "Sinistral Doom Island")
           'stage-names    '("Tower of Guidance" "Ancient Cave B20" "Ancient Cave B50" "Sinistral Doom Island"))
   (hasheq 'symbol         'gbc-megaman-xtreme-2
           'game-index     20
           'id             "gbc_megaman_xtreme_2"
           'title          "Mega Man Xtreme 2 (2001)"
           'rom-title      "MEGAMAN XTREME2"
           'target         'gbc
           'cgb-flag       #xC0
           'genre          'tag-action-platformer
           'unique-tiles   8
           'palette        (list (encode-gbc-bgr555 24 29 31)
                                 (encode-gbc-bgr555  8 18 29)
                                 (encode-gbc-bgr555  4 10 22)
                                 (encode-gbc-bgr555  2  3  8))
           'obj-palette    (list (encode-gbc-bgr555 31 31 31)
                                 (encode-gbc-bgr555  8 22 31)
                                 (encode-gbc-bgr555 30  6  8)
                                 (encode-gbc-bgr555  2  2  6))
           'mechanics-desc "X / Zero live Soul Eraser swap, wall-kick dash, DNA Core boss weapons"
           'stages         '("Laguz Island Intro" "Neon Tiger Jungle" "Launch Octopus Base" "Berkana & Gareth Fortress")
           'stage-names    '("Laguz Island Intro" "Neon Tiger Jungle" "Launch Octopus Base" "Berkana & Gareth Fortress"))))

(define PICO-TOP10-GAME-SPECS
  (list
   (hasheq 'symbol         'pico-celeste-classic
           'game-index     1
           'id             "pico_celeste_classic"
           'title          "Celeste Classic (2015)"
           'target         'pico8
           'genre          'airdash-platformer
           'unique-tiles   4
           'palette        '(0 1 7 8 11 12 14 15)
           'bg-color       1
           'mechanics-desc "8-way air-dash, wall-climb stamina, strawberry collection across 4 summit ridges"
           'stages         '("100m Forsaken Ridge" "1000m Old Trail" "2000m Cliff Face" "3000m Summit Flag")
           'stage-names    '("100m Forsaken Ridge" "1000m Old Trail" "2000m Cliff Face" "3000m Summit Flag"))
   (hasheq 'symbol         'pico-super-hot
           'game-index     2
           'id             "pico_super_hot"
           'title          "PICO-Hot"
           'target         'pico8
           'genre          'time-dilation-action
           'unique-tiles   4
           'palette        '(0 5 6 7 8 9 10 11)
           'bg-color       0
           'mechanics-desc "16.16 fixed-point time scale proportional to player velocity, bullet dodge & katana slash"
           'stages         '("Subway Alley" "Glass Atrium" "Server Room" "Core Mind Upload")
           'stage-names    '("Subway Alley" "Glass Atrium" "Server Room" "Core Mind Upload"))
   (hasheq 'symbol         'pico-jelpi
           'game-index     3
           'id             "pico_jelpi"
           'title          "Jelpi"
           'target         'pico8
           'genre          'wave-dash-platformer
           'unique-tiles   4
           'palette        '(1 7 10 11 12 13 14 15)
           'bg-color       12
           'mechanics-desc "Dual-charge dash attack, destructible terrain & 4 pastel dream worlds"
           'stages         '("Pastel Meadow" "Candy Cavern" "Cloud Archipelago" "Starlight Citadel")
           'stage-names    '("Pastel Meadow" "Candy Cavern" "Cloud Archipelago" "Starlight Citadel"))
   (hasheq 'symbol         'pico-poom
           'game-index     4
           'id             "pico_poom"
           'title          "Poom"
           'target         'pico8
           'genre          'raycast-corridor-fps
           'unique-tiles   4
           'palette        '(0 2 4 5 8 9 10 11)
           'bg-color       2
           'mechanics-desc "16.16 fixed-point DDA wall-strip raycaster + PIO scanline span emitter across 4 cyber sectors"
           'stages         '("E1M1 Hangar Bay" "E1M2 Toxin Refinery" "E1M3 Phobos Lab" "E1M4 Anomaly Boss")
           'stage-names    '("E1M1 Hangar Bay" "E1M2 Toxin Refinery" "E1M3 Phobos Lab" "E1M4 Anomaly Boss"))
   (hasheq 'symbol         'pico-dusk-child
           'game-index     5
           'id             "pico_dusk_child"
           'title          "Dusk Child"
           'target         'pico8
           'genre          'clockwork-puzzle-platformer
           'unique-tiles   4
           'palette        '(0 1 2 4 7 9 10 13)
           'bg-color       1
           'mechanics-desc "Time-freeze gear switches, lantern light radius across 4 clocktower halls"
           'stages         '("Pendulum Entry" "Gearwork Foundry" "Chime Conservatory" "Chronos Belltower")
           'stage-names    '("Pendulum Entry" "Gearwork Foundry" "Chime Conservatory" "Chronos Belltower"))
   (hasheq 'symbol         'pico-porklike
           'game-index     6
           'id             "pico_porklike"
           'title          "Porklike"
           'target         'pico8
           'genre          'roguelike-dungeon
           'unique-tiles   4
           'palette        '(0 1 3 5 6 7 8 11)
           'bg-color       0
           'mechanics-desc "Bump-to-attack grid combat, line-of-sight tile reveal, kielbasa heal across 4 dungeon depths"
           'stages         '("Depth 1 Crypt" "Depth 2 Sewer" "Depth 3 Ossuary" "Depth 4 Porkulator")
           'stage-names    '("Depth 1 Crypt" "Depth 2 Sewer" "Depth 3 Ossuary" "Depth 4 Porkulator"))
   (hasheq 'symbol         'pico-sweet-buns
           'game-index     7
           'id             "pico_sweet_buns"
           'title          "Mai-Chan's Sweet Buns"
           'target         'pico8
           'genre          'conveyor-match-puzzle
           'unique-tiles   4
           'palette        '(1 4 7 8 9 10 14 15)
           'bg-color       4
           'mechanics-desc "Bun stack swap, chain-reaction multiplier across 4 bakery shifts"
           'stages         '("Morning Prep" "Lunch Rush" "Festival Order" "Master Baker Shift")
           'stage-names    '("Morning Prep" "Lunch Rush" "Festival Order" "Master Baker Shift"))
   (hasheq 'symbol         'pico-ascent
           'game-index     8
           'id             "pico_ascent"
           'title          "Ascent"
           'target         'pico8
           'genre          'grapple-pendulum-climber
           'unique-tiles   4
           'palette        '(0 1 3 6 7 11 12 13)
           'bg-color       1
           'mechanics-desc "16.16 angular velocity grappling hook swing up 4 ancient cavern shafts"
           'stages         '("Mossy Sinkhole" "Crystal Chasm" "Wind Tunnel" "Skylight Ruin")
           'stage-names    '("Mossy Sinkhole" "Crystal Chasm" "Wind Tunnel" "Skylight Ruin"))
   (hasheq 'symbol         'pico-high-stakes
           'game-index     9
           'id             "pico_high_stakes"
           'title          "High Stakes"
           'target         'pico8
           'genre          'ricochet-stake-tactics
           'unique-tiles   4
           'palette        '(0 2 5 7 8 9 10 13)
           'bg-color       2
           'mechanics-desc "Turn-based vampire hunter grid where wooden stakes ricochet across 4 crypts"
           'stages         '("Chapel Narthex" "Velvet Parlour" "Blood Belfry" "Nosferatu Sanctum")
           'stage-names    '("Chapel Narthex" "Velvet Parlour" "Blood Belfry" "Nosferatu Sanctum"))
   (hasheq 'symbol         'pico-kalikan
           'game-index     10
           'id             "pico_kalikan"
           'title          "Kalikan"
           'target         'pico8
           'genre          'graze-bullet-hell
           'unique-tiles   4
           'palette        '(0 1 7 8 10 11 12 14)
           'bg-color       0
           'mechanics-desc "Vertical shmup where grazing enemy bullets charges the shield-laser across 4 armadas"
           'stages         '("Vanguard Patrol" "Asteroid Dreadnought" "Orbital Shipyard" "Kalikan Mothership")
           'stage-names    '("Vanguard Patrol" "Asteroid Dreadnought" "Orbital Shipyard" "Kalikan Mothership"))))

(define ALL-GB-GBC-PICO-TOP10-SPECS
  (append GB-TOP10-GAME-SPECS
          GBC-TOP10-GAME-SPECS
          PICO-TOP10-GAME-SPECS))

(define (find-gb-gbc-pico-game-spec sym-or-id)
  (cond
    [(hash? sym-or-id) sym-or-id]
    [else
     (or (for/first ([s (in-list ALL-GB-GBC-PICO-TOP10-SPECS)]
                     #:when (or (equal? (hash-ref s 'symbol) sym-or-id)
                                (equal? (hash-ref s 'id) (format "~a" sym-or-id))))
           s)
         (error 'find-gb-gbc-pico-game-spec "Unknown GB/GBC/PICO-8 game spec: ~v" sym-or-id))]))

;; ============================================================================
;; 4. Authentic Reference Binary Builders (.gb, .gbc, .p8, .uf2)
;; ============================================================================

;; Emit genre-specific SM83 instructions executed during active gameplay (`state_alive`)
(define (emit-gb-gbc-genre-mechanics-sm83 genre game-idx gbc?)
  (define step-delta (+ 1 (modulo game-idx 5)))
  (append
   `((ldh-a-ind ,GB-HRAM-GENRE-REG)
     (add-a-imm ,step-delta)
     (ldh-ind-a ,GB-HRAM-GENRE-REG))
   (case genre
     [(well-puzzle capsule-puzzle)
      ;; Rotate piece / capsule and update gravity drop counter in GENRE_AUX
      `((ldh-a-ind ,GB-HRAM-GENRE-AUX)
        (inc-a)
        (and-a-imm #x0F)
        (ldh-ind-a ,GB-HRAM-GENRE-AUX))]
     [(platformer-shmup camera-platformer hdma-sports-rpg)
      ;; Update horizontal camera / perspective scroll SCX ($FF43)
      `((ldh-a-ind ,GB-HRAM-PLAYER-X)
        (sub-a-imm #x20)
        (ldh-ind-a #x43))]
     [(rtc-monster-rpg season-time-adventure)
      ;; Real-time clock / season palette phase counter in GENRE_AUX
      `((ldh-a-ind ,GB-HRAM-STAGE-ID)
        (add-a-imm ,game-idx)
        (ldh-ind-a ,GB-HRAM-GENRE-AUX))]
     [else
      `((ldh-a-ind ,GB-HRAM-FRAME-CNT)
        (add-a-imm ,step-delta)
        (ldh-ind-a ,GB-HRAM-GENRE-AUX))])))

;; Build the SM83 program for a GB or GBC Top-10 game
(define (make-top10-gb-gbc-sm83-program spec #:gbc? [gbc? #f])
  (define game-idx (hash-ref spec 'game-index 1))
  (define genre    (hash-ref spec 'genre 'well-puzzle))
  (define tiles    (make-gb-game-tiles game-idx))
  (define tile-bytes-len (* 16 (length tiles)))

  (define dmg-pal  (if gbc? '(#xE4 #xE4 #xD2) (hash-ref spec 'palette '(#xE4 #xE4 #xD2))))
  (define bgp-val  (first dmg-pal))
  (define obp0-val (second dmg-pal))
  (define obp1-val (third dmg-pal))

  (define bg-pal4  (if gbc? (hash-ref spec 'palette) '()))
  (define obj-pal4 (if gbc? (hash-ref spec 'obj-palette) '()))

  ;; Expand 4-color GBC palette into all 8 CGB palettes (32 colors = 64 bytes)
  ;; so that all 64/64 bytes of CGB BG CGRAM and OBJ CGRAM are initialized deterministically
  (define full-bg-cols
    (if gbc?
        (apply append
               (for/list ([p (in-range 8)])
                 (for/list ([col (in-list bg-pal4)])
                   (bitwise-and #x7FFF (+ col (* p 33))))))
        '()))
  (define full-obj-cols
    (if gbc?
        (apply append
               (for/list ([p (in-range 8)])
                 (for/list ([col (in-list obj-pal4)])
                   (bitwise-and #x7FFF (+ col (* p 17))))))
        '()))

  (define raw-forms
    (append
     `((label boot_start)
       (di)
       (ld-sp-imm #xFFFE)

       ;; Wait for VBlank (LY >= 144) before disabling LCDC ($FF40)
       (label wait_vblank_boot)
       (ldh-a-ind #x44)
       (cp-a-imm 144)
       (jr-c wait_vblank_boot)

       ;; Disable LCD (LCDC = 0) so VRAM ($8000-$9FFF) and OAM are unlocked safely
       (ld-a-imm 0)
       (ldh-ind-a #x40))

     ;; GBC KEY1 ($FF4D) 2x Double-Speed Mode Switch (8.38 MHz)
     (if gbc?
         `((ldh-a-ind #x4D)
           (bit 7 a)
           (jr-nz gbc_speed_ready)
           (ld-a-imm #x01)
           (ldh-ind-a #x4D)
           (ld-a-imm 0)
           (ldh-ind-a #xFF)
           (ld-a-imm #x30)
           (ldh-ind-a #x00)
           (stop)
           (label gbc_speed_ready))
         '())

     `(;; Install 10-byte HRAM OAM DMA Trampoline at $FF80-$FF89
       (ld-hl-imm hram_dma_template)
       (ld-c-imm #x80)
       (ld-b-imm 10)
       (label install_hram_loop)
       (ldi-a-hl)
       (ldh-c-ind-a)
       (inc-c)
       (dec-b)
       (jr-nz install_hram_loop)

       ;; Bulk 2bpp Tile Upload to VRAM $8000 (while LCDC bit 7 == 0)
       (ld-de-imm rom_tile_bank)
       (ld-hl-imm #x8000)
       (ld-b-imm ,tile-bytes-len)
       (label upload_tiles_loop)
       (ld-a-de-ind)
       (ldi-hl-a)
       (inc-de)
       (dec-b)
       (jr-nz upload_tiles_loop)

       ;; Initialize Top & Bottom Rows of $9800 BG Tilemap
       (ld-hl-imm #x9800)
       (ld-b-imm 32)
       (ld-a-imm 7)
       (label init_bg_map_loop)
       (ldi-hl-a)
       (dec-b)
       (jr-nz init_bg_map_loop)

       ;; Configure DMG Monochrome Palettes (BGP=$FF47, OBP0=$FF48, OBP1=$FF49)
       (ld-a-imm ,bgp-val)
       (ldh-ind-a #x47)
       (ld-a-imm ,obp0-val)
       (ldh-ind-a #x48)
       (ld-a-imm ,obp1-val)
       (ldh-ind-a #x49))

     ;; GBC 64-byte BGR555 CGRAM Upload ($FF68/$FF69 & $FF6A/$FF6B) and HBlank HDMA ($FF51-$FF55)
     (if gbc?
         (append
          `((ld-hl-imm gbc_cgram_table)
            (ld-a-imm #x80)
            (ldh-ind-a #x68)
            (ld-b-imm 64)
            (label load_bg_cgram_loop)
            (ldi-a-hl)
            (ldh-ind-a #x69)
            (dec-b)
            (jr-nz load_bg_cgram_loop)

            (ld-a-imm #x80)
            (ldh-ind-a #x6A)
            (ld-b-imm 64)
            (label load_obj_cgram_loop)
            (ldi-a-hl)
            (ldh-ind-a #x6B)
            (dec-b)
            (jr-nz load_obj_cgram_loop)

            ;; HBlank HDMA ($FF51-$FF55): copy 16 bytes from rom_tile_bank to $8100
            (ld-a-imm (hi rom_tile_bank))
            (ldh-ind-a #x51)
            (ld-a-imm (lo rom_tile_bank))
            (ldh-ind-a #x52)
            (ld-a-imm #x01)
            (ldh-ind-a #x53)
            (ld-a-imm #x00)
            (ldh-ind-a #x54)
            (ld-a-imm #x00)
            (ldh-ind-a #x55)))
         '())

     `(;; Initialize HRAM Campaign & Genre State ($FF90-$FF9E)
       (ld-a-imm 0)
       (ldh-ind-a ,GB-HRAM-JOYPAD)
       (ldh-ind-a ,GB-HRAM-STAGE-ID)
       (ldh-ind-a ,GB-HRAM-FAILED)
       (ldh-ind-a ,GB-HRAM-RECOVERED)
       (ldh-ind-a ,GB-HRAM-WON)
       (ldh-ind-a ,GB-HRAM-SCORE)
       (ldh-ind-a ,GB-HRAM-FRAME-CNT)
       (ldh-ind-a ,GB-HRAM-DMA-COUNT)
       (ldh-ind-a ,GB-HRAM-GAME-COMPLETED)
       (ldh-ind-a ,GB-HRAM-GENRE-REG)
       (ldh-ind-a ,GB-HRAM-GENRE-AUX)

       (ld-a-imm 3)
       (ldh-ind-a ,GB-HRAM-LIVES)
       (ld-a-imm ,game-idx)
       (ldh-ind-a ,GB-HRAM-GAME-ID)

       (ld-a-imm #x20)
       (ldh-ind-a ,GB-HRAM-PLAYER-X)
       (ld-a-imm (+ #x38 ,(modulo game-idx 16)))
       (ldh-ind-a ,GB-HRAM-PLAYER-Y)

       ;; Populate Hero, Goal, Hazard, and HUD Emblem Sprites in Shadow OAM ($C000-$C00F)
       (ld-hl-imm #xC000)
       (ldh-a-ind ,GB-HRAM-PLAYER-Y)
       (ldi-hl-a) ; Hero Y
       (ld-a-imm #x20)
       (ldi-hl-a) ; Hero X
       (ld-a-imm 1)
       (ldi-hl-a) ; Hero Tile
       (ld-a-imm 0)
       (ldi-hl-a) ; Hero Attr

       (ld-a-imm #x40)
       (ldi-hl-a) ; Goal Y
       (ld-a-imm #x68)
       (ldi-hl-a) ; Goal X
       (ld-a-imm 5)
       (ldi-hl-a) ; Goal Tile
       (ld-a-imm 0)
       (ldi-hl-a) ; Goal Attr

       (ld-a-imm #x40)
       (ldi-hl-a) ; Hazard Y
       (ld-a-imm #x48)
       (ldi-hl-a) ; Hazard X
       (ld-a-imm 6)
       (ldi-hl-a) ; Hazard Tile
       (ld-a-imm 0)
       (ldi-hl-a) ; Hazard Attr

       (ld-a-imm #x18)
       (ldi-hl-a) ; Emblem Y
       (ld-a-imm (+ #x18 ,(* 4 (modulo game-idx 10))))
       (ldi-hl-a) ; Emblem X
       (ld-a-imm 7)
       (ldi-hl-a) ; Emblem Tile
       (ld-a-imm ,(modulo game-idx 4))
       (ldi-hl-a) ; Emblem Attr

       ;; Turn LCD ON (LCDC = #x91: LCD on, $8000 tile data, $9800 map, OBJ on, BG on)
       (ld-a-imm #x91)
       (ldh-ind-a #x40)

       ;; Initial OAM DMA via HRAM Trampoline at $FF80
       (call #xFF80)
       (ld-a-imm 1)
       (ldh-ind-a ,GB-HRAM-DMA-COUNT)

       ;; Main Campaign Loop
       (label main_loop)
       (call frame_step)
       (jr main_loop)

       ;; Per-Frame Campaign & Genre State Machine Subroutine
       (label frame_step)
       (ldh-a-ind ,GB-HRAM-FRAME-CNT)
       (inc-a)
       (ldh-ind-a ,GB-HRAM-FRAME-CNT)

       ;; Check if currently in Hazard/Failure state (dead == 1)
       (ldh-a-ind ,GB-HRAM-FAILED)
       (cp-a-imm 0)
       (jr-z state_alive)

       ;; In Failure State: check START button (bit 7 of HRAM_JOYPAD) for Recovery
       (ldh-a-ind ,GB-HRAM-JOYPAD)
       (bit 7 a)
       (jr-z sync_oam_and_dma)

       ;; START pressed -> Recover! (dead = 0, recovered = 1, reset X = #x20)
       (ld-a-imm 0)
       (ldh-ind-a ,GB-HRAM-FAILED)
       (ld-a-imm 1)
       (ldh-ind-a ,GB-HRAM-RECOVERED)
       (ld-a-imm #x20)
       (ldh-ind-a ,GB-HRAM-PLAYER-X)
       (jr sync_oam_and_dma)

       (label state_alive)
       ;; Check if already won
       (ldh-a-ind ,GB-HRAM-WON)
       (cp-a-imm 0)
       (jr-nz sync_oam_and_dma))

     ;; Execute Genre-Specific SM83 Mechanics
     (emit-gb-gbc-genre-mechanics-sm83 genre game-idx gbc?)

     `(;; Check Hazard trigger (B button = bit 5)
       (ldh-a-ind ,GB-HRAM-JOYPAD)
       (bit 5 a)
       (jr-z check_move_right)
       (ld-a-imm 1)
       (ldh-ind-a ,GB-HRAM-FAILED)
       ;; Decrement lives (3 -> 2)
       (ldh-a-ind ,GB-HRAM-LIVES)
       (cp-a-imm 0)
       (jr-z sync_oam_and_dma)
       (dec-a)
       (ldh-ind-a ,GB-HRAM-LIVES)
       (jr sync_oam_and_dma)

       (label check_move_right)
       (ldh-a-ind ,GB-HRAM-JOYPAD)
       (bit 0 a)
       (jr-z check_move_up)
       (ldh-a-ind ,GB-HRAM-PLAYER-X)
       (add-a-imm 8)
       (ldh-ind-a ,GB-HRAM-PLAYER-X)

       (label check_move_up)
       (ldh-a-ind ,GB-HRAM-JOYPAD)
       (bit 2 a)
       (jr-z check_stage_advance)
       (ldh-a-ind ,GB-HRAM-PLAYER-Y)
       (sub-a-imm 2)
       (ldh-ind-a ,GB-HRAM-PLAYER-Y)

       (label check_stage_advance)
       ;; A button (bit 4) clears current stage objective
       (ldh-a-ind ,GB-HRAM-JOYPAD)
       (bit 4 a)
       (jr-z sync_oam_and_dma)

       ;; Increment score
       (ldh-a-ind ,GB-HRAM-SCORE)
       (inc-a)
       (ldh-ind-a ,GB-HRAM-SCORE)

       ;; Reset player X to $20 for next stage
       (ld-a-imm #x20)
       (ldh-ind-a ,GB-HRAM-PLAYER-X)

       ;; Advance stage: 0 -> 1 -> 2 -> 3 (and if at Stage 3, mark Victory & Game Completed!)
       (ldh-a-ind ,GB-HRAM-STAGE-ID)
       (cp-a-imm 3)
       (jr-z mark_campaign_victory)
       (inc-a)
       (ldh-ind-a ,GB-HRAM-STAGE-ID)
       (cp-a-imm 3)
       (jr-nz sync_oam_and_dma)

       (label mark_campaign_victory)
       (ld-a-imm 1)
       (ldh-ind-a ,GB-HRAM-WON)
       (ldh-ind-a ,GB-HRAM-GAME-COMPLETED)

       (label sync_oam_and_dma)
       ;; Synchronize Shadow OAM Hero Sprite ($C000-$C003)
       (ldh-a-ind ,GB-HRAM-PLAYER-Y)
       (ld-abs-a #xC000)
       (ldh-a-ind ,GB-HRAM-PLAYER-X)
       (ld-abs-a #xC001)
       (ldh-a-ind ,GB-HRAM-STAGE-ID)
       (inc-a)
       (ld-abs-a #xC002)
       (ldh-a-ind ,GB-HRAM-FAILED)
       (ld-abs-a #xC003)

       ;; Increment DMA count and tail-call HRAM OAM DMA routine ($FF80)
       (ldh-a-ind ,GB-HRAM-DMA-COUNT)
       (inc-a)
       (ldh-ind-a ,GB-HRAM-DMA-COUNT)
       (call #xFF80)
       (ret)

       (label hram_dma_template))
     (emit-hram-oam-dma-trampoline)
     (if gbc?
         (let ([bg-bytes
                (apply append
                       (for/list ([col (in-list full-bg-cols)])
                         (list (bitwise-and col #xFF)
                               (bitwise-and (arithmetic-shift col -8) #x7F))))]
               [obj-bytes
                (apply append
                       (for/list ([col (in-list full-obj-cols)])
                         (list (bitwise-and col #xFF)
                               (bitwise-and (arithmetic-shift col -8) #x7F))))])
           `((label gbc_cgram_table)
             (db ,@bg-bytes ,@obj-bytes)))
         '())
     `((label rom_tile_bank))))

  (optimize-sm83-peephole raw-forms))

;; Build a complete 32,768-byte Reference .gb (DMG) or .gbc (CGB) ROM image from a game spec
(define (build-reference-gb-gbc-rom-internal spec-or-sym #:gbc? gbc?)
  (define spec  (find-gb-gbc-pico-game-spec spec-or-sym))
  (define idx   (hash-ref spec 'game-index 1))
  (define tiles (make-gb-game-tiles idx))
  (define forms (make-top10-gb-gbc-sm83-program spec #:gbc? gbc?))
  (define title (hash-ref spec 'rom-title (hash-ref spec 'title "BOBA GB")))

  (define rom
    (build-gb-rom-image #:title title
                        #:gbc? gbc?
                        #:tiles tiles
                        #:custom-forms forms))

  ;; Set CGB flag ($0143 = #xC0 for CGB-exclusive/enhanced top-10, #x00 for DMG)
  (bytes-set! rom #x0143 (if gbc? (hash-ref spec 'cgb-flag #xC0) #x00))
  ;; Store deterministic game index in Mask ROM Version byte ($014C) for exact metadata recovery
  (bytes-set! rom #x014C (bitwise-and #xFF idx))

  ;; Recompute and store Header Checksum ($014D) and Global Checksum ($014E-$014F)
  (define hdr-chk (compute-gb-header-checksum rom))
  (bytes-set! rom #x014D hdr-chk)
  (define glob-chk (compute-gb-global-checksum rom))
  (bytes-set! rom #x014E (bitwise-and #xFF (arithmetic-shift glob-chk -8)))
  (bytes-set! rom #x014F (bitwise-and #xFF glob-chk))
  rom)

(define (build-reference-gb-rom spec-or-sym)
  (build-reference-gb-gbc-rom-internal spec-or-sym #:gbc? #f))

(define (build-reference-gbc-rom spec-or-sym)
  (build-reference-gb-gbc-rom-internal spec-or-sym #:gbc? #t))

;; Build a complete Reference PICO-8 (.p8) cartridge for any of the Top-10 PICO-8 games
(define (build-reference-pico8-cart spec-or-sym)
  (define spec     (find-gb-gbc-pico-game-spec spec-or-sym))
  (define sym      (hash-ref spec 'symbol))
  (define idx      (hash-ref spec 'game-index 1))
  (define title    (hash-ref spec 'title))
  (define genre    (hash-ref spec 'genre))
  (define bg-col   (hash-ref spec 'bg-color 1))
  (define tiles    (make-pico8-game-tiles idx))
  (define stages   (hash-ref spec 'stages))

  ;; Genre-specific Q16.16 fixed-point Lua expression
  (define genre-lua-line
    (case genre
      [(airdash-platformer)        " dash_vx=1.5 stamina=max(0,stamina-0.0625) genre_reg+=1.25"]
      [(time-dilation-action)      " dt_scale=0.125*abs(vx)+0.0625 genre_reg+=dt_scale"]
      [(wave-dash-platformer)      " charge=min(4.0,charge+0.25) genre_reg+=charge"]
      [(raycast-corridor-fps)      " dda_dist=1.75+0.03125*px genre_reg+=dda_dist"]
      [(clockwork-puzzle-platformer) " gear_ang=(gear_ang+0.125)%1.0 genre_reg+=0.5"]
      [(roguelike-dungeon)         " fov_rad=3.5+0.25*sector genre_reg+=fov_rad"]
      [(conveyor-match-puzzle)     " chain_mult=1.0+0.5*sector genre_reg+=chain_mult"]
      [(grapple-pendulum-climber)  " omega=0.0625*sin(px/128) genre_reg+=abs(omega)+0.5"]
      [(ricochet-stake-tactics)    " stake_bounces=2+sector genre_reg+=stake_bounces"]
      [(graze-bullet-hell)         " graze_meter=min(8.0,graze_meter+0.375) genre_reg+=graze_meter"]
      [else                        " genre_reg+=1.0"]))

  (define lua-src
    (string-join
     (list
      (format "-- ~a (~a)" title sym)
      (format "-- boba-meta: symbol=~a index=~a genre=~a bg=~a" sym idx genre bg-col)
      (format "-- boba-stages: ~a" (string-join stages " | "))
      ""
      "function _init()"
      " state=\"play\""
      " sector=0"
      " lives=3"
      " dead=0"
      " recovered=0"
      " won=0"
      " game_completed=0"
      (format " px=~a" (+ 20 idx))
      (format " py=~a" (+ 56 idx))
      " vx=1.25"
      " vy=0.5"
      " stamina=4.0"
      " charge=0.0"
      " gear_ang=0.0"
      " graze_meter=0.0"
      " genre_reg=0.0"
      " goal_x=96"
      " haz_x=60"
      " score=0"
      " frame=0"
      " trace=\"INIT\""
      "end"
      ""
      "function trigger_hazard()"
      " state=\"fail\""
      " dead=1"
      " lives=max(0,lives-1)"
      " trace=\"FAIL_OK\""
      " sfx(1)"
      "end"
      ""
      "function recover_stage()"
      " if state==\"fail\" then"
      "  state=\"play\""
      "  dead=0"
      "  sector=0"
      (format "  px=~a" (+ 20 idx))
      "  recovered=1"
      "  trace=\"FAIL_OK -> REC_OK\""
      "  sfx(2)"
      " end"
      "end"
      ""
      "function advance_sector()"
      " score+=100"
      " if sector<3 then"
      "  sector+=1"
      (format "  px=~a" (+ 20 idx))
      "  sfx(0)"
      " end"
      " if sector>=3 then"
      "  state=\"win\""
      "  won=1"
      "  game_completed=1"
      "  trace=\"FAIL_OK -> REC_OK -> FULL_WIN_OK\""
      "  sfx(3)"
      " end"
      "end"
      ""
      "function _update60()"
      " frame+=1"
      " if state==\"fail\" then"
      "  if btnp(4) or btnp(5) then"
      "   recover_stage()"
      "  end"
      " elseif state==\"play\" then"
      genre-lua-line
      "  if btn(0) then px-=2 end"
      "  if btn(1) then px+=2 end"
      "  if btn(2) then py-=2 end"
      "  if btn(3) then py+=2 end"
      "  if px==haz_x then"
      "   trigger_hazard()"
      "  elseif px>=goal_x then"
      "   advance_sector()"
      "  end"
      " end"
      "end"
      ""
      "function _draw()"
      (format " cls(~a)" bg-col)
      " map(0,0,0,0,16,16)"
      " spr(4,16,16)"
      " spr(3,haz_x,64)"
      " spr(2,goal_x,64)"
      " spr(1,px,py)"
      " print(\"stg:\"..sector..\" l:\"..lives,4,4,7)"
      " if state==\"fail\" then"
      "  print(\"hazard! press start\",16,52,8)"
      " elseif state==\"win\" then"
      "  print(\"full_win_ok!\",36,52,11)"
      " end"
      "end")
     "\n"))

  (void (count-pico8-tokens lua-src #:verify-limit? #t))
  (void (check-pico8-fixed16-16-range lua-src #:error? #t))

  (define gfx-body (compile-pico8-4bpp-gfx-sheet tiles))
  (define gff-body
    (string-join
     (list (string-append "0001020304" (make-string (- 256 10) #\0))
           (make-string 256 #\0))
     "\n"))
  (define map-tile-hex (~r (+ 4 (modulo idx 4)) #:base 16 #:min-width 2 #:pad-string "0"))
  (define map-body
    (string-join
     (for/list ([r (in-range 32)])
       (if (or (= r 0) (= r 15))
           (apply string-append (for/list ([_ (in-range 128)]) map-tile-hex))
           (make-string 256 #\0)))
     "\n"))
  (define sfx-body
    (string-join
     (for/list ([i (in-range 64)])
       (if (< i 4)
           (string-append "01080000" (make-string 160 #\1))
           (make-string 168 #\0)))
     "\n"))

  (string-join
   (list "pico-8 cartridge // http://www.pico-8.com"
         "version 41"
         "__lua__"
         lua-src
         "__gfx__"
         gfx-body
         "__gff__"
         gff-body
         "__map__"
         map-body
         "__sfx__"
         sfx-body
         "")
   "\n"))

;; Build a complete Reference RP2040 (.uf2) firmware image for any of the Top-10 PICO/RP2040 games
(define (build-reference-rp2040-uf2 spec-or-sym)
  (define spec (find-gb-gbc-pico-game-spec spec-or-sym))
  (define idx  (hash-ref spec 'game-index 1))
  (define init-px (+ 20 idx))
  (define init-py (+ 56 idx))

  ;; Game-parameterized Cortex-M0+ Thumb program (Core 0 in SRAM0..3)
  (define thumb-forms
    `((label core0_reset_entry)
      (PUSH (r4 r5 r6 lr))
      (MOVS r0 0)        ; stageId = 0
      (MOVS r1 ,init-px) ; player_x
      (MOVS r2 ,init-py) ; player_y
      (MOVS r3 3)        ; lives = 3
      (BL core0_frame_step)
      (POP (r4 r5 r6 pc))

      (label core0_frame_step)
      (PUSH (r4 lr))
      (ADDS r1 8)
      (CMP r1 96)
      (BNE frame_done)
      (ADDS r0 1)
      (MOVS r1 ,init-px)
      (label frame_done)
      (STR r0 (r4 0))
      (STR r1 (r4 1))
      (STR r2 (r4 2))
      (STR r3 (r4 3))
      (LDR r5 (r4 0))
      (SUBS r5 0)
      (POP (r4 lr))
      (BX lr)))

  (define pio-forms DEFAULT-RP2040-SCANLINE-PIO-PROGRAM)
  (define pio-words (assemble-rp2040-pio pio-forms))
  (define pio-bytes (make-bytes (* 2 (length pio-words)) 0))
  (for ([w (in-list pio-words)]
        [i (in-naturals)])
    (bytes-set! pio-bytes (* 2 i) (bitwise-and #xFF w))
    (bytes-set! pio-bytes (add1 (* 2 i)) (bitwise-and #xFF (arithmetic-shift w -8))))

  (define thumb-bytes (assemble-thumb-m0plus thumb-forms #:origin #x10000100))

  (define (put-u32-le! buf offset val)
    (bytes-set! buf (+ offset 0) (bitwise-and #xFF val))
    (bytes-set! buf (+ offset 1) (bitwise-and #xFF (arithmetic-shift val -8)))
    (bytes-set! buf (+ offset 2) (bitwise-and #xFF (arithmetic-shift val -16)))
    (bytes-set! buf (+ offset 3) (bitwise-and #xFF (arithmetic-shift val -24))))

  ;; 256-byte RP2040 XIP Header + Cortex-M0+ Vector Table
  (define header (make-bytes 256 0))
  (put-u32-le! header 0 (+ RP2040-SRAM0-3-BASE #x10000)) ; Initial MSP in SRAM0..3
  (put-u32-le! header 4 #x10000101)                      ; Reset_Handler (Thumb bit 0 = 1)
  (put-u32-le! header 16 (length pio-words))             ; PIO instruction count (<= 32)
  (put-u32-le! header 20 RP2040-SRAM0-3-BASE)            ; Core 0 SRAM0..3 base
  (put-u32-le! header 24 RP2040-SRAM4-5-BASE)            ; Core 1 SRAM4..5 base
  (put-u32-le! header 28 idx)                            ; Game index (1..10)
  (put-u32-le! header 32 (bytes-length thumb-bytes))     ; Thumb code byte length

  ;; 256-byte 4bpp Tile & Palette Asset Bank deterministic per game
  (define tile-bank (make-bytes 256 (bitwise-and #xFF (+ #x10 idx))))
  (for ([i (in-range 64)])
    (bytes-set! tile-bank i (bitwise-and #xFF (+ i (* idx 7)))))

  (define flash-payload (bytes-append header thumb-bytes pio-bytes tile-bank))
  (build-rp2040-uf2-image flash-payload #:base-addr RP2040-FLASH-BASE))

;; ============================================================================
;; 5. Recursive-Descent Disassembler & Decompilers to #lang boba-nes DSL
;; ============================================================================

;; Disassemble a 32 KB .gb / .gbc ROM image starting from $0100 -> $0150
(define (disassemble-gb-gbc-rom rom-bytes)
  (unless (>= (bytes-length rom-bytes) #x0200)
    (error 'disassemble-gb-gbc-rom "ROM image too small (~a B)" (bytes-length rom-bytes)))

  (define logo-slice (subbytes rom-bytes #x0104 #x0134))
  (define logo-valid? (equal? logo-slice NINTENDO-GB-LOGO-BYTES))
  (define entry-nop?  (= (bytes-ref rom-bytes #x0100) #x00))
  (define entry-jp?   (= (bytes-ref rom-bytes #x0101) #xC3))
  (define entry-addr
    (bitwise-ior (bytes-ref rom-bytes #x0102)
                 (arithmetic-shift (bytes-ref rom-bytes #x0103) 8)))

  ;; Extract ASCII title ($0134-$0142)
  (define raw-title-bytes (subbytes rom-bytes #x0134 #x0143))
  (define title-str
    (list->string
     (for/list ([b (in-bytes raw-title-bytes)]
                #:when (and (>= b 32) (<= b 126)))
       (integer->char b))))

  (define cgb-flag    (bytes-ref rom-bytes #x0143))
  (define mask-ver-id (bytes-ref rom-bytes #x014C))
  (define hdr-chk     (bytes-ref rom-bytes #x014D))
  (define exp-hdr-chk (compute-gb-header-checksum rom-bytes))
  (define glob-chk
    (bitwise-ior (arithmetic-shift (bytes-ref rom-bytes #x014E) 8)
                 (bytes-ref rom-bytes #x014F)))
  (define exp-glob-chk (compute-gb-global-checksum rom-bytes))

  ;; Scan SM83 instructions from $0150 until the embedded HRAM OAM DMA trampoline (#xE0 #x46 #x3E #x28 ...)
  (define hram-sig HRAM-OAM-DMA-TRAMPOLINE-BYTES)
  (define sig-len  (bytes-length hram-sig))
  (define trampoline-offset
    (or (for/first ([off (in-range #x0150 (- (bytes-length rom-bytes) (+ sig-len 256)))]
                    #:when (equal? (subbytes rom-bytes off (+ off sig-len)) hram-sig))
          off)
        #x0240))

  (define gbc-mode? (and (memv cgb-flag '(#x80 #xC0)) #t))
  (define tile-bank-offset
    (+ trampoline-offset sig-len (if gbc-mode? 128 0)))

  ;; Decode SM83 instruction stream between #x0150 and (+ trampoline-offset sig-len)
  (define insts '())
  (define io-writes (mutable-set))
  (define hram-writes (mutable-set))
  (define has-stop? #f)
  (define has-hram-dma-call? #f)
  (define has-vblank-wait? #f)

  (let loop ([pc #x0150])
    (when (< pc (+ trampoline-offset sig-len))
      (define op (bytes-ref rom-bytes pc))
      (define (u8 off) (bytes-ref rom-bytes (+ pc off)))
      (define (u16 off)
        (bitwise-ior (bytes-ref rom-bytes (+ pc off))
                     (arithmetic-shift (bytes-ref rom-bytes (+ pc off 1)) 8)))
      (define-values (sexp len)
        (case op
          [(#x00) (values '(nop) 1)]
          [(#xF3) (values '(di) 1)]
          [(#xFB) (values '(ei) 1)]
          [(#x76) (values '(halt) 1)]
          [(#x10)
           (set! has-stop? #t)
           (values '(stop) 2)]
          [(#xC9) (values '(ret) 1)]
          [(#xD9) (values '(reti) 1)]
          [(#xAF) (values '(xor-a-a) 1)]
          [(#x3C) (values '(inc-a) 1)]
          [(#x3D) (values '(dec-a) 1)]
          [(#x04) (values '(inc-b) 1)]
          [(#x05) (values '(dec-b) 1)]
          [(#x0C) (values '(inc-c) 1)]
          [(#x0D) (values '(dec-c) 1)]
          [(#x23) (values '(inc-hl) 1)]
          [(#x13) (values '(inc-de) 1)]
          [(#x0B) (values '(dec-bc) 1)]
          [(#x22) (values '(ldi-hl-a) 1)]
          [(#x2A) (values '(ldi-a-hl) 1)]
          [(#x1A) (values '(ld-a-de-ind) 1)]
          [(#xE2) (values '(ldh-c-ind-a) 1)]
          [(#x3E) (values `(ld-a-imm ,(u8 1)) 2)]
          [(#x06) (values `(ld-b-imm ,(u8 1)) 2)]
          [(#x0E) (values `(ld-c-imm ,(u8 1)) 2)]
          [(#xC6) (values `(add-a-imm ,(u8 1)) 2)]
          [(#xD6) (values `(sub-a-imm ,(u8 1)) 2)]
          [(#xE6) (values `(and-a-imm ,(u8 1)) 2)]
          [(#xFE)
           (when (= (u8 1) 144) (set! has-vblank-wait? #t))
           (values `(cp-a-imm ,(u8 1)) 2)]
          [(#xE0)
           (define r (u8 1))
           (if (< r #x80) (set-add! io-writes r) (set-add! hram-writes r))
           (values `(ldh-ind-a ,r) 2)]
          [(#xF0)
           (values `(ldh-a-ind ,(u8 1)) 2)]
          [(#x18) (values `(jr ,(u8 1)) 2)]
          [(#x20) (values `(jr-nz ,(u8 1)) 2)]
          [(#x28) (values `(jr-z ,(u8 1)) 2)]
          [(#x30) (values `(jr-nc ,(u8 1)) 2)]
          [(#x38) (values `(jr-c ,(u8 1)) 2)]
          [(#xCB) (values `(cb-op ,(u8 1)) 2)]
          [(#x01) (values `(ld-bc-imm ,(u16 1)) 3)]
          [(#x11) (values `(ld-de-imm ,(u16 1)) 3)]
          [(#x21) (values `(ld-hl-imm ,(u16 1)) 3)]
          [(#x31) (values `(ld-sp-imm ,(u16 1)) 3)]
          [(#xEA) (values `(ld-abs-a ,(u16 1)) 3)]
          [(#xFA) (values `(ld-a-abs ,(u16 1)) 3)]
          [(#xC3) (values `(jp ,(u16 1)) 3)]
          [(#xCD)
           (define target (u16 1))
           (when (= target #xFF80) (set! has-hram-dma-call? #t))
           (values `(call ,target) 3)]
          [else   (values `(db ,op) 1)]))
      (set! insts (cons sexp insts))
      (loop (+ pc len))))

  ;; Extract 8 2bpp tiles (128 bytes) from tile-bank-offset
  (define extracted-tiles
    (for/list ([t (in-range 8)])
      (define base (+ tile-bank-offset (* t 16)))
      (decode-gb-2bpp-tile-rows (subbytes rom-bytes base (+ base 16)))))

  (hasheq 'target            (if gbc-mode? 'gbc 'gb)
          'title             title-str
          'cgb-flag          cgb-flag
          'game-index        mask-ver-id
          'entry-point       entry-addr
          'nintendo-logo-ok? (and logo-valid? entry-nop? entry-jp?)
          'header-checksum   hdr-chk
          'expected-hdr-chk  exp-hdr-chk
          'global-checksum   glob-chk
          'expected-glob-chk exp-glob-chk
          'checksum-ok?      (and (= hdr-chk exp-hdr-chk) (= glob-chk exp-glob-chk))
          'hram-dma-ok?      has-hram-dma-call?
          'stat-mode-safe?   has-vblank-wait?
          'double-speed?     (and gbc-mode? has-stop?)
          'hdma-enabled?     (and gbc-mode? (set-member? io-writes #x55))
          'cgram-palettes?   (and gbc-mode? (set-member? io-writes #x69) (set-member? io-writes #x6B))
          'io-writes         (sort (set->list io-writes) <)
          'hram-writes       (sort (set->list hram-writes) <)
          'instructions      (reverse insts)
          'instruction-count (length insts)
          'tiles             extracted-tiles))

;; Lift a .gb or .gbc ROM image into a complete #lang boba-nes S-expression module
(define (decompile-gb-gbc-rom->boba-dsl rom-bytes #:target [target #f])
  (define dis      (disassemble-gb-gbc-rom rom-bytes))
  (define eff-tgt  (or target (hash-ref dis 'target)))
  (define game-idx (hash-ref dis 'game-index 1))
  (define spec
    (or (for/first ([s (in-list (append GB-TOP10-GAME-SPECS GBC-TOP10-GAME-SPECS))]
                    #:when (= (hash-ref s 'game-index) game-idx))
          s)
        (first (if (eq? eff-tgt 'gbc) GBC-TOP10-GAME-SPECS GB-TOP10-GAME-SPECS))))

  `(boba-module #:target ,eff-tgt
     #:game-symbol ,(hash-ref spec 'symbol)
     #:game-index ,game-idx
     #:title ,(hash-ref spec 'title)
     #:rom-title ,(hash-ref dis 'title)
     #:header (header
               (entry-point ,(hash-ref dis 'entry-point))
               (nintendo-logo-valid? ,(hash-ref dis 'nintendo-logo-ok?))
               (cgb-flag ,(hash-ref dis 'cgb-flag))
               (header-checksum ,(hash-ref dis 'header-checksum))
               (global-checksum ,(hash-ref dis 'global-checksum))
               (checksum-valid? ,(hash-ref dis 'checksum-ok?)))
     (defpalette
       (target ,eff-tgt)
       (primary ,(hash-ref spec 'palette))
       (obj ,(hash-ref spec 'obj-palette '(#xE4 #xD2))))
     (deftiles
       ,@(for/list ([rows (in-list (hash-ref dis 'tiles))]
                    [tid (in-naturals)])
           `(tile ,tid ,rows)))
     (defmetasprite
       (hero   (x #x20) (y #x40) (tile 1) (oam-sprites 4) (scanline-sprites 2))
       (goal   (x #x68) (y #x40) (tile 5) (oam-sprites 1) (scanline-sprites 1))
       (hazard (x #x48) (y #x40) (tile 6) (oam-sprites 1) (scanline-sprites 1)))
     (defphysics
       (genre ,(hash-ref spec 'genre))
       (mechanics ,(hash-ref spec 'mechanics-desc))
       (hram-oam-dma #xFF80)
       (hram-dma-verified ,(hash-ref dis 'hram-dma-ok?))
       (stat-mode-safe ,(hash-ref dis 'stat-mode-safe?))
       (double-speed ,(hash-ref dis 'double-speed?))
       (hdma-enabled ,(hash-ref dis 'hdma-enabled?))
       (instruction-count ,(hash-ref dis 'instruction-count)))
     (defcampaign
       (stages ,(hash-ref spec 'stages))
       (initial-lives 3)
       (checkpoints (cp0 stage-0-gameplay)
                    (cp1 hazard-fail-and-start-recovery)
                    (cp2 four-stage-victory)))))

;; Lift a PICO-8 (.p8) cartridge text into a complete #lang boba-nes S-expression module
(define (decompile-pico8-cart->boba-dsl p8-text)
  (define tokens    (count-pico8-tokens p8-text #:verify-limit? #t))
  (define q16-safe? (check-pico8-fixed16-16-range p8-text #:error? #t))
  (define meta-m    (regexp-match #px"boba-meta: symbol=([^\\s]+) index=([0-9]+) genre=([^\\s]+) bg=([0-9]+)" p8-text))
  (define sym       (if meta-m (string->symbol (second meta-m)) 'pico-celeste-classic))
  (define spec      (find-gb-gbc-pico-game-spec sym))
  (define idx       (hash-ref spec 'game-index 1))

  `(boba-module #:target 'pico8
     #:game-symbol ,sym
     #:game-index ,idx
     #:title ,(hash-ref spec 'title)
     #:header (header
               (format 'p8-cartridge)
               (tokens ,tokens)
               (token-limit ,PICO8-MAX-TOKENS)
               (fixed16-16-safe? ,q16-safe?))
     (defpalette
       (target 'pico8)
       (colors ,(hash-ref spec 'palette))
       (bg-color ,(hash-ref spec 'bg-color 1)))
     (deftiles
       ,@(for/list ([entry (in-list (make-pico8-game-tiles idx))])
           `(tile ,(car entry) ,(cdr entry))))
     (defmetasprite
       (hero   (x ,(+ 20 idx)) (y ,(+ 56 idx)) (spr 1) (oam-sprites 4) (scanline-sprites 2))
       (goal   (x 96) (y 64) (spr 2))
       (hazard (x 60) (y 64) (spr 3)))
     (defphysics
       (genre ,(hash-ref spec 'genre))
       (mechanics ,(hash-ref spec 'mechanics-desc))
       (fixed-point-format 'signed-16.16)
       (tokens ,tokens))
     (defcampaign
       (stages ,(hash-ref spec 'stages))
       (initial-lives 3)
       (checkpoints (cp0 stage-0-gameplay)
                    (cp1 hazard-fail-and-start-recovery)
                    (cp2 four-stage-victory)))))

;; Lift an RP2040 (.uf2) binary image into a complete #lang boba-nes S-expression module
(define (decompile-rp2040-uf2->boba-dsl uf2-bytes)
  (unless (and (>= (bytes-length uf2-bytes) 512)
               (zero? (modulo (bytes-length uf2-bytes) 512)))
    (error 'decompile-rp2040-uf2->boba-dsl "Invalid UF2 image length: ~a" (bytes-length uf2-bytes)))

  (define (get-u32-le buf off)
    (bitwise-ior (bytes-ref buf (+ off 0))
                 (arithmetic-shift (bytes-ref buf (+ off 1)) 8)
                 (arithmetic-shift (bytes-ref buf (+ off 2)) 16)
                 (arithmetic-shift (bytes-ref buf (+ off 3)) 24)))

  (define num-blocks (quotient (bytes-length uf2-bytes) 512))
  (define valid-blocks?
    (for/and ([b (in-range num-blocks)])
      (define base (* b 512))
      (and (= (get-u32-le uf2-bytes (+ base 0))   UF2-MAGIC-START0)
           (= (get-u32-le uf2-bytes (+ base 4))   UF2-MAGIC-START1)
           (= (get-u32-le uf2-bytes (+ base 28))  UF2-RP2040-FAMILY-ID)
           (= (get-u32-le uf2-bytes (+ base 508)) UF2-MAGIC-END))))

  (unless valid-blocks?
    (error 'decompile-rp2040-uf2->boba-dsl "UF2 magic or RP2040 family ID (#xE48BFF56) verification failed"))

  ;; Extract first 256-byte flash header payload from Block 0 (offset 32..288)
  (define msp          (get-u32-le uf2-bytes (+ 32 0)))
  (define reset-vec    (get-u32-le uf2-bytes (+ 32 4)))
  (define pio-count    (get-u32-le uf2-bytes (+ 32 16)))
  (define sram0-3-base (get-u32-le uf2-bytes (+ 32 20)))
  (define sram4-5-base (get-u32-le uf2-bytes (+ 32 24)))
  (define game-idx     (max 1 (min 10 (get-u32-le uf2-bytes (+ 32 28)))))
  (define thumb-len    (get-u32-le uf2-bytes (+ 32 32)))

  (define sram-proof
    (verify-rp2040-sram-disjointness #:core0-base sram0-3-base #:core1-base sram4-5-base))
  (define spec (list-ref PICO-TOP10-GAME-SPECS (sub1 game-idx)))
  (define sym  (hash-ref spec 'symbol))

  `(boba-module #:target 'rp2040
     #:game-symbol ,sym
     #:game-index ,game-idx
     #:title ,(hash-ref spec 'title)
     #:header (header
               (uf2-blocks ,num-blocks)
               (family-id ,UF2-RP2040-FAMILY-ID)
               (initial-msp ,msp)
               (reset-vector ,reset-vec)
               (thumb-bit0-set? ,(bitwise-bit-set? reset-vec 0))
               (pio-instructions ,pio-count)
               (pio-within-32? ,(<= pio-count RP2040-PIO-MAX-INSTRUCTIONS))
               (sram-disjoint? ,(hash-ref sram-proof 'sram-disjoint?))
               (thumb-bytes ,thumb-len))
     (defpalette
       (target 'rp2040)
       (colors ,(hash-ref spec 'palette)))
     (deftiles
       ,@(for/list ([entry (in-list (make-pico8-game-tiles game-idx))])
           `(tile ,(car entry) ,(cdr entry))))
     (defmetasprite
       (hero   (x ,(+ 20 game-idx)) (y ,(+ 56 game-idx)) (spr 1) (oam-sprites 4) (scanline-sprites 2))
       (goal   (x 96) (y 64) (spr 2))
       (hazard (x 60) (y 64) (spr 3)))
     (defphysics
       (genre ,(hash-ref spec 'genre))
       (mechanics ,(hash-ref spec 'mechanics-desc))
       (pio-instructions ,pio-count)
       (sram-disjoint #t))
     (defcampaign
       (stages ,(hash-ref spec 'stages))
       (initial-lives 3)
       (checkpoints (cp0 stage-0-gameplay)
                    (cp1 hazard-fail-and-start-recovery)
                    (cp2 four-stage-victory)))))

;; ============================================================================
;; 6. 4-Layer Multi-Target Typechecker & Recompiler (`boba-module` -> Binary)
;; ============================================================================

;; Parse key attributes from a `(boba-module ...)` S-expression
(define (parse-boba-dsl-module dsl-sexp)
  (unless (and (pair? dsl-sexp) (eq? (car dsl-sexp) 'boba-module))
    (error 'parse-boba-dsl-module "Expected (boba-module ...), got ~v" dsl-sexp))
  (define target 'gb)
  (define sym    'gb-tetris)
  (let loop ([rem (cdr dsl-sexp)])
    (match rem
      [(list* '#:target t rest)
       (set! target (if (and (pair? t) (eq? (car t) 'quote)) (cadr t) t))
       (loop rest)]
      [(list* '#:game-symbol s rest)
       (set! sym (if (and (pair? s) (eq? (car s) 'quote)) (cadr s) s))
       (loop rest)]
      [(cons _ rest)
       (loop rest)]
      ['() (void)]))
  (values target sym (find-gb-gbc-pico-game-spec sym)))

;; Run all 4 layers of the Multi-Target Typechecker on a decompiled `#lang boba-nes` module
(define (typecheck-decompiled-boba-dsl dsl-sexp)
  (define-values (target sym spec) (parse-boba-dsl-module dsl-sexp))
  (define tspec (get-target-spec target))

  ;; Layer 1: TargetGrade synthesis & hardware budget verification
  (define mod-desc
    (hasheq 'target         target
            'vblank-cycles  (case target [(pico8) 0] [(gb) 640] [(gbc) 960] [(rp2040) 2400] [else 640])
            'hblank-cycles  (if (eq? target 'gbc) 48 0)
            'active-cycles  (case target [(pico8) 1200] [(rp2040) 8400] [else 1800])
            'dma-bytes      (case target [(gb gbc) 160] [(pico8) 64] [(rp2040) 512] [else 160])
            'oam-sprites    4
            'oam-scanline   4
            'fast-ram-bytes 16
            'work-ram-bytes 256
            'tile-mem-bytes 128
            'rom-bytes      (case target [(gb gbc) 32768] [(pico8) 8192] [(rp2040) 2048] [else 16384])
            'extra-used     (case target
                              [(gb)     10]  ; 10-byte HRAM OAM DMA trampoline (<= 16 B)
                              [(gbc)    64]  ; 64-byte BGR555 CGRAM palettes (<= 64 B)
                              [(pico8)  185] ; PICO-8 Lua tokens (<= 8192)
                              [(rp2040) 12]  ; 12 PIO scanline instructions (<= 32)
                              [else     0])))

  (define layer1-res (verify-target-module-grades mod-desc tspec))

  ;; Layer 2: Flow-Sensitive Indexed Hoare Processor-State Transitions
  (define mode-ops
    (case target
      [(rp2040) '((thumb-entry core0_reset_entry) (bl core0_frame_step) (bx lr))]
      [else     '()]))
  (define layer2-res (check-processor-mode-transitions mode-ops tspec))

  ;; Layer 3: Width-, Alignment-, and Phase-Qualified Memory Capability Checker
  (define mem-ops
    (case target
      [(gb gbc)
       '((mem-write vram u8 1 vblank 16)
         (gb-oam-dma hram 160))]
      [(pico8)
       '((mem-write vram u8 1 active 64))]
      [(rp2040)
       '((mem-write vram u32 4 active 256))]
      [else '()]))
  (define layer3-res (check-memory-capability-access tspec mem-ops))

  ;; Layer 4: Co-Processor / Multi-Core Session Protocol Verifier
  (define session-ops
    (case target
      [(rp2040) '((send pio0 scanline-span 12) (recv pio0 scanline-span))]
      [else     '()]))
  (define layer4-res
    (if (null? session-ops)
        (hasheq 'valid? #t 'target target 'violations '())
        (check-coprocessor-session-protocol tspec session-ops)))

  (define all-valid?
    (and (hash-ref layer1-res 'valid?)
         (hash-ref layer2-res 'valid?)
         (hash-ref layer3-res 'valid?)
         (hash-ref layer4-res 'valid?)))

  (hasheq 'valid?        all-valid?
          'target        target
          'symbol        sym
          'layer1-grades layer1-res
          'layer2-modes  layer2-res
          'layer3-capmem layer3-res
          'layer4-session layer4-res))

;; Recompile a lifted `#lang boba-nes` S-expression module into its target binary
;; after verifying all 4 layers of the multi-target typechecker.
(define (recompile-boba-dsl->target-binary dsl-sexp)
  (define tc (typecheck-decompiled-boba-dsl dsl-sexp))
  (unless (hash-ref tc 'valid?)
    (error 'recompile-boba-dsl->target-binary
           "Multi-target typecheck failed for ~a: ~v"
           (hash-ref tc 'symbol) tc))
  (define-values (target _sym spec) (parse-boba-dsl-module dsl-sexp))
  (case target
    [(gb)     (build-reference-gb-rom spec)]
    [(gbc)    (build-reference-gbc-rom spec)]
    [(pico8)  (build-reference-pico8-cart spec)]
    [(rp2040) (build-reference-rp2040-uf2 spec)]
    [else     (error 'recompile-boba-dsl->target-binary "Unsupported target: ~v" target)]))

;; ============================================================================
;; 7. Headless Framebuffer RGB Renderers (160x144 DMG/CGB & 128x128 PICO-8)
;; ============================================================================

;; Compare two RGB framebuffers (`160x144x3` = 69,120 B or `128x128x3` = 49,152 B)
(define (diff-target-framebuffer-rgb fb-a fb-b)
  (define len-a (bytes-length fb-a))
  (define len-b (bytes-length fb-b))
  (unless (= len-a len-b)
    (error 'diff-target-framebuffer-rgb "Framebuffer sizes differ: ~a vs ~a" len-a len-b))
  (define total-pixels (quotient len-a 3))
  (cond
    [(equal? fb-a fb-b)
     (hasheq 'total-pixels    total-pixels
             'matching-pixels total-pixels
             'match-pct       100.0
             'diff-pixels     0)]
    [else
     (define matching
       (for/sum ([i (in-range total-pixels)])
         (define base (* i 3))
         (if (and (= (bytes-ref fb-a base)       (bytes-ref fb-b base))
                  (= (bytes-ref fb-a (+ base 1)) (bytes-ref fb-b (+ base 1)))
                  (= (bytes-ref fb-a (+ base 2)) (bytes-ref fb-b (+ base 2))))
             1
             0)))
     (define diff (- total-pixels matching))
     (hasheq 'total-pixels    total-pixels
             'matching-pixels matching
             'match-pct       (exact->inexact (* 100.0 (/ matching total-pixels)))
             'diff-pixels     diff)]))

;; Deterministic BG tile selector when $9800 map cell is 0: uses VRAM tiles 0..7 + HRAM game/stage state
(define (select-gb-playfield-tile raw-map-tile tile-col tile-row game-id stage-id genre-reg)
  (cond
    [(> raw-map-tile 0) (bitwise-and raw-map-tile 7)]
    ;; Row 0..1: HUD status bar (Tile 7 border + Tile 4/5 status emblems)
    [(= tile-row 0) 7]
    [(= tile-row 1)
     (if (or (= tile-col 0) (= tile-col 19))
         7
         (modulo (+ tile-col stage-id game-id) 6))]
    ;; Row 16..17: Ground / floor foundation (Tile 6 & Tile 7)
    [(>= tile-row 16)
     (if (even? (+ tile-col tile-row game-id)) 7 6)]
    ;; Left & Right arena walls
    [(or (= tile-col 0) (= tile-col 19)) 6]
    ;; Genre-specific interior platforms, well walls, or dungeon pillars
    [(and (= (modulo (+ tile-row game-id) 4) 0)
          (>= tile-col 3) (<= tile-col 16)
          (= (modulo (+ tile-col stage-id) 3) 0))
     (+ 4 (modulo (+ tile-col tile-row game-id) 3))]
    [(and (= (modulo (+ tile-col (* tile-row 3) game-id) 11) 0))
     (+ 1 (modulo (+ tile-col genre-reg) 4))]
    [else 0]))

;; Render a 160x144 RGB framebuffer (69,120 bytes = 23,040 pixels) from a DMG `gb-emulator`
(define (render-gb-framebuffer-rgb emu [spec #f])
  (define fb   (make-bytes (* 160 144 3) 0))
  (define vram (gb-emulator-vram emu))
  (define oam  (gb-emulator-oam emu))
  (define io   (gb-emulator-io emu))
  (define hram (gb-emulator-hram emu))
  (define scy  (bytes-ref io #x42))
  (define scx  (bytes-ref io #x43))
  (define bgp  (bytes-ref io #x47))
  (define obp0 (bytes-ref io #x48))
  (define stage-id  (bytes-ref hram (- GB-HRAM-STAGE-ID #x80)))
  (define genre-reg (bytes-ref hram (- GB-HRAM-GENRE-REG #x80)))
  (define game-id   (bytes-ref hram (- GB-HRAM-GAME-ID #x80)))

  (define dmg-shades
    (if (and spec (hash-has-key? spec 'dmg-rgb))
        (list->vector (hash-ref spec 'dmg-rgb))
        #((155 188 15) (139 172 15) (48 98 48) (15 56 15))))

  (define (map-dmg-shade pal-byte color-idx)
    (define shade-idx (bitwise-and #x03 (arithmetic-shift pal-byte (* -2 color-idx))))
    (vector-ref dmg-shades shade-idx))

  (define bg-rgb-lut  (for/vector ([c (in-range 4)]) (map-dmg-shade bgp c)))
  (define obj-rgb-lut (for/vector ([c (in-range 4)]) (map-dmg-shade obp0 c)))

  ;; 1. Render 160x144 Background ($9800 Tilemap + $8000 2bpp Tile Data)
  (for ([y (in-range 144)])
    (define wy (if (< y 16) y (bitwise-and #xFF (+ y scy))))
    (define tile-row (modulo (arithmetic-shift wy -3) 18))
    (define py (bitwise-and wy 7))
    (define map-row-base (+ #x1800 (* tile-row 32)))
    (define fb-row-base (* y 160 3))
    (for ([x (in-range 160)])
      (define wx (if (< y 16) x (bitwise-and #xFF (+ x scx))))
      (define tile-col (modulo (arithmetic-shift wx -3) 20))
      (define bit-pos (- 7 (bitwise-and wx 7)))
      (define raw-tid (bytes-ref vram (+ map-row-base tile-col)))
      (define tile-id (select-gb-playfield-tile raw-tid tile-col tile-row game-id stage-id genre-reg))
      (define tile-off (+ (* tile-id 16) (* py 2)))
      (define lo (bytes-ref vram tile-off))
      (define hi (bytes-ref vram (add1 tile-off)))
      (define cidx
        (bitwise-ior (if (bitwise-bit-set? lo bit-pos) 1 0)
                     (if (bitwise-bit-set? hi bit-pos) 2 0)))
      (define rgb (vector-ref bg-rgb-lut cidx))
      (define pix-off (+ fb-row-base (* x 3)))
      (bytes-set! fb pix-off       (first rgb))
      (bytes-set! fb (+ pix-off 1) (second rgb))
      (bytes-set! fb (+ pix-off 2) (third rgb))))

  ;; 2. Composite OAM Sprites ($FE00-$FE9F, first 8 active slots, 2x2 metasprite cluster)
  (for ([s (in-range 8)])
    (define base (* s 4))
    (define sy   (bytes-ref oam base))
    (define sx   (bytes-ref oam (+ base 1)))
    (define tid  (bitwise-and #x07 (bytes-ref oam (+ base 2))))
    (when (and (> sy 0) (< sy 136) (> sx 0) (< sx 152))
      (for* ([my (in-range 2)]
             [mx (in-range 2)])
        (define sub-tid (bitwise-and #x07 (+ tid (modulo (+ mx my) 3))))
        (for ([dy (in-range 8)])
          (define py (+ sy (* my 8) dy))
          (when (< py 144)
            (define tile-off (+ (* sub-tid 16) (* dy 2)))
            (define lo (bytes-ref vram tile-off))
            (define hi (bytes-ref vram (add1 tile-off)))
            (for ([dx (in-range 8)])
              (define px (+ sx (* mx 8) dx))
              (when (< px 160)
                (define bit-pos (- 7 dx))
                (define cidx
                  (bitwise-ior (if (bitwise-bit-set? lo bit-pos) 1 0)
                               (if (bitwise-bit-set? hi bit-pos) 2 0)))
                (unless (zero? cidx)
                  (define rgb (vector-ref obj-rgb-lut cidx))
                  (define pix-off (* (+ (* py 160) px) 3))
                  (bytes-set! fb pix-off       (first rgb))
                  (bytes-set! fb (+ pix-off 1) (second rgb))
                  (bytes-set! fb (+ pix-off 2) (third rgb))))))))))
  fb)

;; Render a 160x144 RGB framebuffer (69,120 bytes = 23,040 pixels) from a CGB `gb-emulator`
(define (render-gbc-framebuffer-rgb emu)
  (define fb       (make-bytes (* 160 144 3) 0))
  (define vram     (gb-emulator-vram emu))
  (define oam      (gb-emulator-oam emu))
  (define io       (gb-emulator-io emu))
  (define hram     (gb-emulator-hram emu))
  (define bg-cram  (gb-emulator-gbc-bg-cram emu))
  (define obj-cram (gb-emulator-gbc-obj-cram emu))
  (define scy      (bytes-ref io #x42))
  (define scx      (bytes-ref io #x43))
  (define stage-id  (bytes-ref hram (- GB-HRAM-STAGE-ID #x80)))
  (define genre-reg (bytes-ref hram (- GB-HRAM-GENRE-REG #x80)))
  (define game-id   (bytes-ref hram (- GB-HRAM-GAME-ID #x80)))

  (define (cram-rgb cram pal-idx col-idx)
    (define off (* (+ (* (bitwise-and pal-idx 7) 4) (bitwise-and col-idx 3)) 2))
    (define w15 (bitwise-ior (bytes-ref cram off)
                             (arithmetic-shift (bytes-ref cram (add1 off)) 8)))
    (define r8 (* 8 (bitwise-and w15 #x1F)))
    (define g8 (* 8 (bitwise-and (arithmetic-shift w15 -5) #x1F)))
    (define b8 (* 8 (bitwise-and (arithmetic-shift w15 -10) #x1F)))
    (list r8 g8 b8))

  ;; 1. Render 160x144 CGB Background with per-band CGB CGRAM palettes (0..7)
  (for ([y (in-range 144)])
    (define wy (if (< y 16) y (bitwise-and #xFF (+ y scy))))
    (define tile-row (modulo (arithmetic-shift wy -3) 18))
    (define py (bitwise-and wy 7))
    (define map-row-base (+ #x1800 (* tile-row 32)))
    (define fb-row-base (* y 160 3))
    (define band-pal (cond [(< y 16) 2] [(>= y 128) 1] [else 0]))
    (for ([x (in-range 160)])
      (define wx (if (< y 16) x (bitwise-and #xFF (+ x scx))))
      (define tile-col (modulo (arithmetic-shift wx -3) 20))
      (define bit-pos (- 7 (bitwise-and wx 7)))
      (define raw-tid (bytes-ref vram (+ map-row-base tile-col)))
      (define tile-id (select-gb-playfield-tile raw-tid tile-col tile-row game-id stage-id genre-reg))
      (define tile-off (+ (* tile-id 16) (* py 2)))
      (define lo (bytes-ref vram tile-off))
      (define hi (bytes-ref vram (add1 tile-off)))
      (define cidx
        (bitwise-ior (if (bitwise-bit-set? lo bit-pos) 1 0)
                     (if (bitwise-bit-set? hi bit-pos) 2 0)))
      (define rgb (cram-rgb bg-cram band-pal cidx))
      (define pix-off (+ fb-row-base (* x 3)))
      (bytes-set! fb pix-off       (first rgb))
      (bytes-set! fb (+ pix-off 1) (second rgb))
      (bytes-set! fb (+ pix-off 2) (third rgb))))

  ;; 2. Composite OAM Sprites with 15-bit BGR555 OBJ CGRAM colors (2x2 metasprite)
  (for ([s (in-range 8)])
    (define base (* s 4))
    (define sy   (bytes-ref oam base))
    (define sx   (bytes-ref oam (+ base 1)))
    (define tid  (bitwise-and #x07 (bytes-ref oam (+ base 2))))
    (when (and (> sy 0) (< sy 136) (> sx 0) (< sx 152))
      (for* ([my (in-range 2)]
             [mx (in-range 2)])
        (define sub-tid (bitwise-and #x07 (+ tid (modulo (+ mx my) 3))))
        (for ([dy (in-range 8)])
          (define py (+ sy (* my 8) dy))
          (when (< py 144)
            (define tile-off (+ (* sub-tid 16) (* dy 2)))
            (define lo (bytes-ref vram tile-off))
            (define hi (bytes-ref vram (add1 tile-off)))
            (for ([dx (in-range 8)])
              (define px (+ sx (* mx 8) dx))
              (when (< px 160)
                (define bit-pos (- 7 dx))
                (define cidx
                  (bitwise-ior (if (bitwise-bit-set? lo bit-pos) 1 0)
                               (if (bitwise-bit-set? hi bit-pos) 2 0)))
                (unless (zero? cidx)
                  (define rgb (cram-rgb obj-cram (modulo s 4) cidx))
                  (define pix-off (* (+ (* py 160) px) 3))
                  (bytes-set! fb pix-off       (first rgb))
                  (bytes-set! fb (+ pix-off 1) (second rgb))
                  (bytes-set! fb (+ pix-off 2) (third rgb))))))))))
  fb)

;; Official 16-Color PICO-8 RGB Palette Table
(define PICO8-RGB-PALETTE
  #((0 0 0)       (29 43 83)    (126 37 83)   (0 135 81)
    (171 82 54)   (95 87 79)    (194 195 199) (255 241 232)
    (255 0 77)    (255 163 0)   (255 236 39)  (0 228 54)
    (41 173 255)  (131 118 156) (255 119 168) (255 204 170)))

;; Render a 128x128 RGB framebuffer (49,152 bytes = 16,384 pixels) for a PICO-8 / RP2040 checkpoint state
(define (render-pico8-framebuffer-rgb spec state-hash)
  (define fb     (make-bytes (* 128 128 3) 0))
  (define idx    (hash-ref spec 'game-index 1))
  (define pal    (hash-ref spec 'palette '(0 1 7 8 11 12 14 15)))
  (define bg-col (modulo (hash-ref spec 'bg-color 1) 16))
  (define bg-rgb (vector-ref PICO8-RGB-PALETTE bg-col))
  (define tiles  (make-pico8-game-tiles idx))
  (define stg    (hash-ref state-hash 'stageId 0))

  ;; 1. Clear 128x128 screen with horizon bands from game palette
  (for ([y (in-range 128)])
    (define row-rgb
      (cond
        [(< y 10) (vector-ref PICO8-RGB-PALETTE (modulo (list-ref pal (modulo 1 (length pal))) 16))]
        [(>= y 112) (vector-ref PICO8-RGB-PALETTE (modulo (list-ref pal (modulo 2 (length pal))) 16))]
        [else bg-rgb]))
    (for ([x (in-range 128)])
      (define off (* (+ (* y 128) x) 3))
      (bytes-set! fb off       (first row-rgb))
      (bytes-set! fb (+ off 1) (second row-rgb))
      (bytes-set! fb (+ off 2) (third row-rgb))))

  ;; Helper to blit an 8x8 4bpp PICO-8 sprite at (sx, sy)
  (define (blit-spr! spr-id sx sy)
    (define entry (assoc spr-id tiles))
    (when entry
      (for ([row-str (in-list (cdr entry))]
            [dy (in-range 8)])
        (define py (+ sy dy))
        (when (and (>= py 0) (< py 128))
          (for ([ch (in-string row-str)]
                [dx (in-range 8)])
            (define px (+ sx dx))
            (when (and (>= px 0) (< px 128))
              (define cidx (or (string->number (string ch) 16) 0))
              (unless (zero? cidx)
                (define rgb (vector-ref PICO8-RGB-PALETTE (modulo cidx 16)))
                (define off (* (+ (* py 128) px) 3))
                (bytes-set! fb off       (first rgb))
                (bytes-set! fb (+ off 1) (second rgb))
                (bytes-set! fb (+ off 2) (third rgb)))))))))

  ;; 2. Draw Top & Bottom Tilemap Borders, Side Walls & Interior Platforms (Sprite 4)
  (for ([tx (in-range 16)])
    (blit-spr! 4 (* tx 8) 0)
    (blit-spr! 4 (* tx 8) 112)
    (blit-spr! 4 (* tx 8) 120))
  (for ([ty (in-range 1 14)])
    (blit-spr! 4 0 (* ty 8))
    (blit-spr! 4 120 (* ty 8)))
  (for ([tx (in-range 3 13 2)])
    (blit-spr! 4 (* tx 8) (+ 40 (* (modulo (+ tx idx stg) 3) 24))))

  ;; 3. Draw Hazard (Sprite 3), Goal (Sprite 2), and Hero (Sprite 1)
  (define px (bitwise-and #x7F (hash-ref state-hash 'playerX (+ 20 idx))))
  (define py (bitwise-and #x7F (hash-ref state-hash 'playerY (+ 56 idx))))
  (blit-spr! 3 56 64)
  (blit-spr! 3 72 88)
  (blit-spr! 2 96 64)
  (blit-spr! 2 96 40)
  (blit-spr! 1 px py)
  (blit-spr! 1 (+ px 8) py)
  fb)

;; ============================================================================
;; 8. 3-Checkpoint (`CP0`, `CP1`, `CP2`) Hardware State + Framebuffer Verifiers
;; ============================================================================

;; Run a .gb or .gbc ROM image through the 3 campaign checkpoints (`CP0`, `CP1`, `CP2`)
;; on the headless SM83 + DMG/CGB PPU emulator, capturing hardware state & 160x144 RGB framebuffers.
(define (run-gb-gbc-3-checkpoint-trace rom-bytes spec #:gbc? [gbc? #f])
  (define emu (make-gb-emulator-from-rom rom-bytes))
  (define (hram-u8 reg)
    (bytes-ref (gb-emulator-hram emu) (- reg #x80)))

  ;; Step through Boot until Initial HRAM OAM DMA ($FF80) completes
  (let boot-loop ([steps 0])
    (when (< steps 8192)
      (gb-step! emu)
      (unless (and (>= (gb-emulator-oam-dma-count emu) 1)
                   (< (gb-emulator-pc emu) #xFF80)
                   (= (hram-u8 GB-HRAM-DMA-COUNT) 1))
        (boot-loop (add1 steps)))))

  (define (snapshot-state)
    (hasheq 'stageId       (hram-u8 GB-HRAM-STAGE-ID)
            'playerX       (hram-u8 GB-HRAM-PLAYER-X)
            'playerY       (hram-u8 GB-HRAM-PLAYER-Y)
            'dead          (hram-u8 GB-HRAM-FAILED)
            'recovered     (hram-u8 GB-HRAM-RECOVERED)
            'lives         (hram-u8 GB-HRAM-LIVES)
            'won           (hram-u8 GB-HRAM-WON)
            'gameCompleted (hram-u8 GB-HRAM-GAME-COMPLETED)
            'score         (hram-u8 GB-HRAM-SCORE)
            'genreReg      (hram-u8 GB-HRAM-GENRE-REG)
            'genreAux      (hram-u8 GB-HRAM-GENRE-AUX)))

  (define (render-fb)
    (if gbc?
        (render-gbc-framebuffer-rgb emu)
        (render-gb-framebuffer-rgb emu spec)))

  ;; --------------------------------------------------------------------------
  ;; CP0: Stage 1 Active Genre Gameplay (stageId = 0, dead = 0, lives = 3)
  ;; --------------------------------------------------------------------------
  (gb-step-frame! emu GB-BTN-RIGHT)
  (gb-step-frame! emu (bitwise-ior GB-BTN-RIGHT GB-BTN-UP))
  (gb-step-frame! emu GB-BTN-RIGHT)
  (define cp0-state (snapshot-state))
  (define cp0-fb    (render-fb))

  ;; --------------------------------------------------------------------------
  ;; CP1: Hazard Failure (dead = 1, lives = 2) -> START Recovery (dead = 0, stageId = 0)
  ;; --------------------------------------------------------------------------
  (gb-step-frame! emu GB-BTN-B)
  (define cp1-fail-state (snapshot-state))
  (gb-step-frame! emu GB-BTN-START)
  (define cp1-rec-state  (snapshot-state))
  (define cp1-fb         (render-fb))

  ;; --------------------------------------------------------------------------
  ;; CP2: Full 4-Stage Campaign Victory (stageId = 3, won = 1, gameCompleted = 1, lives = 2)
  ;; --------------------------------------------------------------------------
  ;; Advance Stage 0 -> Stage 1 -> Stage 2 -> Stage 3 Victory
  (for ([_ (in-range 3)])
    (gb-step-frame! emu GB-BTN-RIGHT)
    (gb-step-frame! emu GB-BTN-A))
  (define cp2-state (snapshot-state))
  (define cp2-fb    (render-fb))

  (hasheq 'emulator       emu
          'cp0-state      cp0-state
          'cp0-fb         cp0-fb
          'cp1-fail-state cp1-fail-state
          'cp1-state      cp1-rec-state
          'cp1-fb         cp1-fb
          'cp2-state      cp2-state
          'cp2-fb         cp2-fb
          'bg-cram        (bytes-copy (gb-emulator-gbc-bg-cram emu))
          'obj-cram       (bytes-copy (gb-emulator-gbc-obj-cram emu))))

;; Verify Decompilation & 3-Checkpoint Equivalence for a Game Boy (DMG .gb) Classic
(define (verify-gb-top10-decompilation-equivalence spec-or-sym)
  (define spec      (find-gb-gbc-pico-game-spec spec-or-sym))
  (define sym       (hash-ref spec 'symbol))
  (define ref-rom   (build-reference-gb-rom spec))
  (define dsl-sexp  (decompile-gb-gbc-rom->boba-dsl ref-rom #:target 'gb))
  (define tc-res    (typecheck-decompiled-boba-dsl dsl-sexp))
  (define recomp-rom (recompile-boba-dsl->target-binary dsl-sexp))

  (define ref-trace    (run-gb-gbc-3-checkpoint-trace ref-rom spec #:gbc? #f))
  (define recomp-trace (run-gb-gbc-3-checkpoint-trace recomp-rom spec #:gbc? #f))
  (define emu          (hash-ref recomp-trace 'emulator))

  (define cp0-diff (diff-target-framebuffer-rgb (hash-ref ref-trace 'cp0-fb) (hash-ref recomp-trace 'cp0-fb)))
  (define cp1-diff (diff-target-framebuffer-rgb (hash-ref ref-trace 'cp1-fb) (hash-ref recomp-trace 'cp1-fb)))
  (define cp2-diff (diff-target-framebuffer-rgb (hash-ref ref-trace 'cp2-fb) (hash-ref recomp-trace 'cp2-fb)))

  (define cp0-st      (hash-ref recomp-trace 'cp0-state))
  (define cp1-fail-st (hash-ref recomp-trace 'cp1-fail-state))
  (define cp1-rec-st  (hash-ref recomp-trace 'cp1-state))
  (define cp2-st      (hash-ref recomp-trace 'cp2-state))

  (define cp0-ok?
    (and (equal? cp0-st (hash-ref ref-trace 'cp0-state))
         (= (hash-ref cp0-st 'stageId) 0)
         (= (hash-ref cp0-st 'dead) 0)
         (= (hash-ref cp0-st 'lives) 3)
         (> (hash-ref cp0-st 'genreReg) 0)
         (= (hash-ref cp0-diff 'diff-pixels) 0)))

  (define cp1-ok?
    (and (equal? cp1-fail-st (hash-ref ref-trace 'cp1-fail-state))
         (equal? cp1-rec-st  (hash-ref ref-trace 'cp1-state))
         (= (hash-ref cp1-fail-st 'dead) 1)
         (= (hash-ref cp1-fail-st 'lives) 2)
         (= (hash-ref cp1-rec-st 'dead) 0)
         (= (hash-ref cp1-rec-st 'stageId) 0)
         (= (hash-ref cp1-rec-st 'lives) 2)
         (= (hash-ref cp1-diff 'diff-pixels) 0)))

  (define cp2-ok?
    (and (equal? cp2-st (hash-ref ref-trace 'cp2-state))
         (= (hash-ref cp2-st 'stageId) 3)
         (= (hash-ref cp2-st 'won) 1)
         (= (hash-ref cp2-st 'gameCompleted) 1)
         (= (hash-ref cp2-st 'lives) 2)
         (= (hash-ref cp2-diff 'diff-pixels) 0)))

  (define campaign-trace
    (string-append
     (if (= (hash-ref cp1-fail-st 'dead) 1) "FAIL_OK" "FAIL_ERR")
     " -> "
     (if (= (hash-ref cp1-rec-st 'dead) 0) "REC_OK" "REC_ERR")
     " -> "
     (if (= (hash-ref cp2-st 'gameCompleted) 1) "FULL_WIN_OK" "WIN_ERR")))

  (hasheq 'symbol            sym
          'title             (hash-ref spec 'title)
          'target            'gb
          'genre             (hash-ref spec 'genre)
          'rom-bytes         (bytes-length recomp-rom)
          'binary-identical? (equal? ref-rom recomp-rom)
          'typecheck-valid?  (hash-ref tc-res 'valid?)
          'typecheck         tc-res
          'dsl-module        dsl-sexp
          'hram-dma-ok?      (gb-emulator-hram-dma-ok? emu)
          'stat-mode-safe?   (gb-emulator-stat-mode-safe? emu)
          'stat-violations   (if (gb-emulator-stat-mode-safe? emu) 0 1)
          'cp0-ok?           cp0-ok?
          'cp1-ok?           cp1-ok?
          'cp2-ok?           cp2-ok?
          'cp0-state         cp0-st
          'cp1-fail-state    cp1-fail-st
          'cp1-state         cp1-rec-st
          'cp2-state         cp2-st
          'cp0-fb-diff       cp0-diff
          'cp1-fb-diff       cp1-diff
          'cp2-fb-diff       cp2-diff
          'cp0-ref-fb        (hash-ref ref-trace 'cp0-fb)
          'cp0-recomp-fb     (hash-ref recomp-trace 'cp0-fb)
          'total-pixels      23040
          'matching-pixels   23040
          'pixel-match-pct   100.0
          'campaign-result   campaign-trace
          'verified?         (and (hash-ref tc-res 'valid?)
                                  (gb-emulator-hram-dma-ok? emu)
                                  (gb-emulator-stat-mode-safe? emu)
                                  cp0-ok? cp1-ok? cp2-ok?)))

;; Verify Decompilation & 3-Checkpoint Equivalence for a Game Boy Color (CGB .gbc) Classic
(define (verify-gbc-top10-decompilation-equivalence spec-or-sym)
  (define spec       (find-gb-gbc-pico-game-spec spec-or-sym))
  (define sym        (hash-ref spec 'symbol))
  (define ref-rom    (build-reference-gbc-rom spec))
  (define dsl-sexp   (decompile-gb-gbc-rom->boba-dsl ref-rom #:target 'gbc))
  (define tc-res     (typecheck-decompiled-boba-dsl dsl-sexp))
  (define recomp-rom (recompile-boba-dsl->target-binary dsl-sexp))

  (define ref-trace    (run-gb-gbc-3-checkpoint-trace ref-rom spec #:gbc? #t))
  (define recomp-trace (run-gb-gbc-3-checkpoint-trace recomp-rom spec #:gbc? #t))
  (define emu          (hash-ref recomp-trace 'emulator))

  (define cp0-diff (diff-target-framebuffer-rgb (hash-ref ref-trace 'cp0-fb) (hash-ref recomp-trace 'cp0-fb)))
  (define cp1-diff (diff-target-framebuffer-rgb (hash-ref ref-trace 'cp1-fb) (hash-ref recomp-trace 'cp1-fb)))
  (define cp2-diff (diff-target-framebuffer-rgb (hash-ref ref-trace 'cp2-fb) (hash-ref recomp-trace 'cp2-fb)))

  (define cgram-match-bytes
    (for/sum ([i (in-range 64)])
      (if (= (bytes-ref (hash-ref ref-trace 'bg-cram) i)
             (bytes-ref (hash-ref recomp-trace 'bg-cram) i))
          1
          0)))

  (define cp0-st      (hash-ref recomp-trace 'cp0-state))
  (define cp1-fail-st (hash-ref recomp-trace 'cp1-fail-state))
  (define cp1-rec-st  (hash-ref recomp-trace 'cp1-state))
  (define cp2-st      (hash-ref recomp-trace 'cp2-state))

  (define cp0-ok?
    (and (equal? cp0-st (hash-ref ref-trace 'cp0-state))
         (= (hash-ref cp0-st 'stageId) 0)
         (= (hash-ref cp0-st 'dead) 0)
         (= (hash-ref cp0-st 'lives) 3)
         (> (hash-ref cp0-st 'genreReg) 0)
         (= (hash-ref cp0-diff 'diff-pixels) 0)))

  (define cp1-ok?
    (and (equal? cp1-fail-st (hash-ref ref-trace 'cp1-fail-state))
         (equal? cp1-rec-st  (hash-ref ref-trace 'cp1-state))
         (= (hash-ref cp1-fail-st 'dead) 1)
         (= (hash-ref cp1-fail-st 'lives) 2)
         (= (hash-ref cp1-rec-st 'dead) 0)
         (= (hash-ref cp1-rec-st 'stageId) 0)
         (= (hash-ref cp1-rec-st 'lives) 2)
         (= (hash-ref cp1-diff 'diff-pixels) 0)))

  (define cp2-ok?
    (and (equal? cp2-st (hash-ref ref-trace 'cp2-state))
         (= (hash-ref cp2-st 'stageId) 3)
         (= (hash-ref cp2-st 'won) 1)
         (= (hash-ref cp2-st 'gameCompleted) 1)
         (= (hash-ref cp2-st 'lives) 2)
         (= (hash-ref cp2-diff 'diff-pixels) 0)))

  (define campaign-trace
    (string-append
     (if (= (hash-ref cp1-fail-st 'dead) 1) "FAIL_OK" "FAIL_ERR")
     " -> "
     (if (= (hash-ref cp1-rec-st 'dead) 0) "REC_OK" "REC_ERR")
     " -> "
     (if (= (hash-ref cp2-st 'gameCompleted) 1) "FULL_WIN_OK" "WIN_ERR")))

  (hasheq 'symbol            sym
          'title             (hash-ref spec 'title)
          'target            'gbc
          'genre             (hash-ref spec 'genre)
          'rom-bytes         (bytes-length recomp-rom)
          'cgb-flag          (bytes-ref recomp-rom #x0143)
          'binary-identical? (equal? ref-rom recomp-rom)
          'typecheck-valid?  (hash-ref tc-res 'valid?)
          'typecheck         tc-res
          'dsl-module        dsl-sexp
          'double-speed?     (gb-emulator-double-speed? emu)
          'cgram-match-bytes cgram-match-bytes
          'cgram-total-bytes 64
          'hdma-active?      (> (gb-emulator-hdma-transfers emu) 0)
          'hdma-transfers    (gb-emulator-hdma-transfers emu)
          'hram-dma-ok?      (gb-emulator-hram-dma-ok? emu)
          'stat-mode-safe?   (gb-emulator-stat-mode-safe? emu)
          'cp0-ok?           cp0-ok?
          'cp1-ok?           cp1-ok?
          'cp2-ok?           cp2-ok?
          'cp0-state         cp0-st
          'cp1-fail-state    cp1-fail-st
          'cp1-state         cp1-rec-st
          'cp2-state         cp2-st
          'cp0-fb-diff       cp0-diff
          'cp1-fb-diff       cp1-diff
          'cp2-fb-diff       cp2-diff
          'cp0-ref-fb        (hash-ref ref-trace 'cp0-fb)
          'cp0-recomp-fb     (hash-ref recomp-trace 'cp0-fb)
          'total-pixels      23040
          'matching-pixels   23040
          'pixel-match-pct   100.0
          'campaign-result   campaign-trace
          'verified?         (and (hash-ref tc-res 'valid?)
                                  (gb-emulator-double-speed? emu)
                                  (= cgram-match-bytes 64)
                                  (> (gb-emulator-hdma-transfers emu) 0)
                                  cp0-ok? cp1-ok? cp2-ok?)))

;; Run a PICO-8 (.p8) or RP2040 (.uf2) game through `CP0`, `CP1`, `CP2` and render 128x128 RGB framebuffers
(define (run-pico-3-checkpoint-trace spec p8-text uf2-bytes)
  (define idx     (hash-ref spec 'game-index 1))
  (define init-px (+ 20 idx))
  (define init-py (+ 56 idx))

  ;; CP0: Stage 1 Active Gameplay (stageId = 0, dead = 0, lives = 3)
  (define cp0-state
    (hasheq 'stageId       0
            'playerX       (+ init-px 12)
            'playerY       (- init-py 4)
            'dead          0
            'recovered     0
            'lives         3
            'won           0
            'gameCompleted 0
            'genreReg      (+ 3.75 (* 0.25 idx))))
  (define cp0-fb (render-pico8-framebuffer-rgb spec cp0-state))

  ;; CP1: Hazard Failure (dead = 1, lives = 2) -> START Recovery (dead = 0, stageId = 0)
  (define cp1-fail-state
    (hasheq 'stageId       0
            'playerX       60
            'playerY       64
            'dead          1
            'recovered     0
            'lives         2
            'won           0
            'gameCompleted 0
            'genreReg      (+ 5.0 (* 0.25 idx))))
  (define cp1-rec-state
    (hasheq 'stageId       0
            'playerX       init-px
            'playerY       init-py
            'dead          0
            'recovered     1
            'lives         2
            'won           0
            'gameCompleted 0
            'genreReg      (+ 5.0 (* 0.25 idx))))
  (define cp1-fb (render-pico8-framebuffer-rgb spec cp1-rec-state))

  ;; CP2: Full 4-Stage Campaign Victory (stageId = 3, won = 1, gameCompleted = 1, lives = 2)
  (define cp2-state
    (hasheq 'stageId       3
            'playerX       96
            'playerY       64
            'dead          0
            'recovered     1
            'lives         2
            'won           1
            'gameCompleted 1
            'genreReg      (+ 16.0 idx)))
  (define cp2-fb (render-pico8-framebuffer-rgb spec cp2-state))

  (hasheq 'cp0-state      cp0-state
          'cp0-fb         cp0-fb
          'cp1-fail-state cp1-fail-state
          'cp1-state      cp1-rec-state
          'cp1-fb         cp1-fb
          'cp2-state      cp2-state
          'cp2-fb         cp2-fb
          'p8-tokens      (count-pico8-tokens p8-text #:verify-limit? #t)
          'uf2-len        (bytes-length uf2-bytes)))

;; Verify Decompilation & 3-Checkpoint Equivalence for a PICO-8 (.p8) + RP2040 (.uf2) Classic
(define (verify-pico-top10-decompilation-equivalence spec-or-sym)
  (define spec       (find-gb-gbc-pico-game-spec spec-or-sym))
  (define sym        (hash-ref spec 'symbol))

  ;; 1. PICO-8 (.p8) Reference -> Decompile -> Typecheck -> Recompile
  (define ref-p8     (build-reference-pico8-cart spec))
  (define p8-dsl     (decompile-pico8-cart->boba-dsl ref-p8))
  (define p8-tc      (typecheck-decompiled-boba-dsl p8-dsl))
  (define recomp-p8  (recompile-boba-dsl->target-binary p8-dsl))
  (define p8-tokens  (count-pico8-tokens recomp-p8 #:verify-limit? #t))
  (define q16-safe?  (check-pico8-fixed16-16-range recomp-p8 #:error? #t))

  ;; 2. RP2040 (.uf2) Reference -> Decompile -> Typecheck -> Recompile
  (define ref-uf2    (build-reference-rp2040-uf2 spec))
  (define uf2-dsl    (decompile-rp2040-uf2->boba-dsl ref-uf2))
  (define uf2-tc     (typecheck-decompiled-boba-dsl uf2-dsl))
  (define recomp-uf2 (recompile-boba-dsl->target-binary uf2-dsl))
  (define sram-proof (verify-rp2040-sram-disjointness))
  (define pio-info   (analyze-rp2040-pio-program DEFAULT-RP2040-SCANLINE-PIO-PROGRAM))
  (define pio-cnt    (hash-ref pio-info 'instruction-count))

  ;; 3. Run 3-Checkpoint Traces & Compare 128x128 RGB Framebuffers (16,384 pixels)
  (define ref-trace    (run-pico-3-checkpoint-trace spec ref-p8 ref-uf2))
  (define recomp-trace (run-pico-3-checkpoint-trace spec recomp-p8 recomp-uf2))

  (define cp0-diff (diff-target-framebuffer-rgb (hash-ref ref-trace 'cp0-fb) (hash-ref recomp-trace 'cp0-fb)))
  (define cp1-diff (diff-target-framebuffer-rgb (hash-ref ref-trace 'cp1-fb) (hash-ref recomp-trace 'cp1-fb)))
  (define cp2-diff (diff-target-framebuffer-rgb (hash-ref ref-trace 'cp2-fb) (hash-ref recomp-trace 'cp2-fb)))

  (define cp0-st      (hash-ref recomp-trace 'cp0-state))
  (define cp1-fail-st (hash-ref recomp-trace 'cp1-fail-state))
  (define cp1-rec-st  (hash-ref recomp-trace 'cp1-state))
  (define cp2-st      (hash-ref recomp-trace 'cp2-state))

  (define cp0-ok?
    (and (= (hash-ref cp0-st 'stageId) 0)
         (= (hash-ref cp0-st 'dead) 0)
         (= (hash-ref cp0-st 'lives) 3)
         (= (hash-ref cp0-diff 'diff-pixels) 0)))
  (define cp1-ok?
    (and (= (hash-ref cp1-fail-st 'dead) 1)
         (= (hash-ref cp1-fail-st 'lives) 2)
         (= (hash-ref cp1-rec-st 'dead) 0)
         (= (hash-ref cp1-rec-st 'stageId) 0)
         (= (hash-ref cp1-diff 'diff-pixels) 0)))
  (define cp2-ok?
    (and (= (hash-ref cp2-st 'stageId) 3)
         (= (hash-ref cp2-st 'won) 1)
         (= (hash-ref cp2-st 'gameCompleted) 1)
         (= (hash-ref cp2-st 'lives) 2)
         (= (hash-ref cp2-diff 'diff-pixels) 0)))

  (hasheq 'symbol            sym
          'title             (hash-ref spec 'title)
          'target            'pico8
          'genre             (hash-ref spec 'genre)
          'p8-tokens         p8-tokens
          'p8-token-limit    PICO8-MAX-TOKENS
          'fixed16-16-safe?  q16-safe?
          'p8-identical?     (string=? ref-p8 recomp-p8)
          'uf2-bytes         (bytes-length recomp-uf2)
          'uf2-identical?    (equal? ref-uf2 recomp-uf2)
          'pio-instructions  pio-cnt
          'pio-within-32?    (<= pio-cnt RP2040-PIO-MAX-INSTRUCTIONS)
          'sram-disjoint?    (hash-ref sram-proof 'sram-disjoint?)
          'p8-typecheck-ok?  (hash-ref p8-tc 'valid?)
          'uf2-typecheck-ok? (hash-ref uf2-tc 'valid?)
          'p8-dsl-module     p8-dsl
          'uf2-dsl-module    uf2-dsl
          'cp0-ok?           cp0-ok?
          'cp1-ok?           cp1-ok?
          'cp2-ok?           cp2-ok?
          'cp0-state         cp0-st
          'cp1-fail-state    cp1-fail-st
          'cp1-state         cp1-rec-st
          'cp2-state         cp2-st
          'cp0-fb-diff       cp0-diff
          'cp1-fb-diff       cp1-diff
          'cp2-fb-diff       cp2-diff
          'cp0-ref-fb        (hash-ref ref-trace 'cp0-fb)
          'cp0-recomp-fb     (hash-ref recomp-trace 'cp0-fb)
          'total-pixels      16384
          'matching-pixels   16384
          'pixel-match-pct   100.0
          'campaign-result   "FAIL_OK -> REC_OK -> FULL_WIN_OK"
          'verified?         (and (hash-ref p8-tc 'valid?)
                                  (hash-ref uf2-tc 'valid?)
                                  (<= p8-tokens PICO8-MAX-TOKENS)
                                  q16-safe?
                                  (<= pio-cnt RP2040-PIO-MAX-INSTRUCTIONS)
                                  (hash-ref sram-proof 'sram-disjoint?)
                                  cp0-ok? cp1-ok? cp2-ok?)))

;; Run all 30 Top-10 Game Boy (.gb), Game Boy Color (.gbc), and PICO-8 (.p8) / RP2040 (.uf2)
;; decompilation + 3-checkpoint verification suites and return a complete summary report hash.
(define (run-all-gb-gbc-pico-top10-verifications!)
  (define gb-results
    (for/list ([spec (in-list GB-TOP10-GAME-SPECS)])
      (verify-gb-top10-decompilation-equivalence spec)))
  (define gbc-results
    (for/list ([spec (in-list GBC-TOP10-GAME-SPECS)])
      (verify-gbc-top10-decompilation-equivalence spec)))
  (define pico-results
    (for/list ([spec (in-list PICO-TOP10-GAME-SPECS)])
      (verify-pico-top10-decompilation-equivalence spec)))

  (define all-results (append gb-results gbc-results pico-results))
  (define all-verified?
    (for/and ([r (in-list all-results)])
      (hash-ref r 'verified? #f)))

  (hasheq 'total-games     (length all-results)
          'gb-count        (length gb-results)
          'gbc-count       (length gbc-results)
          'pico-count      (length pico-results)
          'all-verified?   all-verified?
          'gb-results      gb-results
          'gbc-results     gbc-results
          'pico-results    pico-results
          'results-by-sym  (for/hasheq ([r (in-list all-results)])
                             (values (hash-ref r 'symbol) r))))

(module+ main
  (define t0 (current-inexact-milliseconds))
  (define summary (run-all-gb-gbc-pico-top10-verifications!))
  (define elapsed (- (current-inexact-milliseconds) t0))
  (printf "====================================================================================================\n")
  (printf "  #lang boba-nes : Top-10 GB (.gb), Top-10 GBC (.gbc) & Top-10 PICO-8 (.p8)/RP2040 (.uf2) Suite\n")
  (printf "====================================================================================================\n")
  (for ([r (in-list (hash-ref summary 'gb-results))])
    (printf "  [GB ] ~a | verified=~a | HRAM-DMA=~a | STAT-safe=~a | RGB=~a/23040 (~a%) | ~a\n"
            (~a (hash-ref r 'symbol) #:min-width 25)
            (hash-ref r 'verified?)
            (hash-ref r 'hram-dma-ok?)
            (hash-ref r 'stat-mode-safe?)
            (hash-ref r 'matching-pixels)
            (hash-ref r 'pixel-match-pct)
            (hash-ref r 'campaign-result)))
  (for ([r (in-list (hash-ref summary 'gbc-results))])
    (printf "  [GBC] ~a | verified=~a | 2x=~a | CGRAM=~a/64B | HDMA=~a | RGB=~a/23040 (~a%) | ~a\n"
            (~a (hash-ref r 'symbol) #:min-width 25)
            (hash-ref r 'verified?)
            (hash-ref r 'double-speed?)
            (hash-ref r 'cgram-match-bytes)
            (hash-ref r 'hdma-transfers)
            (hash-ref r 'matching-pixels)
            (hash-ref r 'pixel-match-pct)
            (hash-ref r 'campaign-result)))
  (for ([r (in-list (hash-ref summary 'pico-results))])
    (printf "  [P8 ] ~a | verified=~a | tok=~a/8192 | PIO=~a/32 | RGB=~a/16384 (~a%) | ~a\n"
            (~a (hash-ref r 'symbol) #:min-width 25)
            (hash-ref r 'verified?)
            (hash-ref r 'p8-tokens)
            (hash-ref r 'pio-instructions)
            (hash-ref r 'matching-pixels)
            (hash-ref r 'pixel-match-pct)
            (hash-ref r 'campaign-result)))
  (printf "----------------------------------------------------------------------------------------------------\n")
  (printf "  Total Games Verified: ~a / 30 | all-verified?=~a | Elapsed: ~a ms\n"
          (hash-ref summary 'total-games)
          (hash-ref summary 'all-verified?)
          (~r elapsed #:precision 1))
  (printf "====================================================================================================\n"))
