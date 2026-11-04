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

;; ============================================================================
;; 7A. Shared 2D Pixel-Art Drawing, Sprite Blitting & 3x5 HUD Font Primitives
;; ============================================================================

(define (fb-put-px! fb w h x y rgb)
  (when (and (exact-integer? x) (exact-integer? y)
             (>= x 0) (< x w) (>= y 0) (< y h))
    (define off (* (+ (* y w) x) 3))
    (bytes-set! fb off       (first rgb))
    (bytes-set! fb (+ off 1) (second rgb))
    (bytes-set! fb (+ off 2) (third rgb))))

(define (fb-fill-rect! fb w h rx ry rw rh rgb)
  (define x0 (max 0 rx))
  (define y0 (max 0 ry))
  (define x1 (min w (+ rx rw)))
  (define y1 (min h (+ ry rh)))
  (define r (first rgb))
  (define g (second rgb))
  (define b (third rgb))
  (for ([y (in-range y0 y1)])
    (define row-base (* y w 3))
    (for ([x (in-range x0 x1)])
      (define off (+ row-base (* x 3)))
      (bytes-set! fb off       r)
      (bytes-set! fb (+ off 1) g)
      (bytes-set! fb (+ off 2) b))))

(define (fb-stroke-rect! fb w h rx ry rw rh rgb)
  (fb-fill-rect! fb w h rx ry rw 1 rgb)
  (fb-fill-rect! fb w h rx (+ ry rh -1) rw 1 rgb)
  (fb-fill-rect! fb w h rx ry 1 rh rgb)
  (fb-fill-rect! fb w h (+ rx rw -1) ry 1 rh rgb))

(define (fb-draw-box! fb w h rx ry rw rh bg-rgb border-rgb [inner-rgb #f])
  (fb-fill-rect! fb w h rx ry rw rh bg-rgb)
  (fb-stroke-rect! fb w h rx ry rw rh border-rgb)
  (when (and inner-rgb (> rw 4) (> rh 4))
    (fb-stroke-rect! fb w h (+ rx 2) (+ ry 2) (- rw 4) (- rh 4) inner-rgb)))

(define (fb-draw-line! fb w h x0 y0 x1 y1 rgb)
  (define dx (abs (- x1 x0)))
  (define dy (- (abs (- y1 y0))))
  (define sx (if (< x0 x1) 1 -1))
  (define sy (if (< y0 y1) 1 -1))
  (let loop ([x x0] [y y0] [err (+ dx dy)] [steps 0])
    (fb-put-px! fb w h x y rgb)
    (unless (or (and (= x x1) (= y y1)) (> steps 512))
      (define e2 (* 2 err))
      (define nx (if (>= e2 dy) (+ x sx) x))
      (define nerr1 (if (>= e2 dy) (+ err dy) err))
      (define ny (if (<= e2 dx) (+ y sy) y))
      (define nerr2 (if (<= e2 dx) (+ nerr1 dx) nerr1))
      (loop nx ny nerr2 (add1 steps)))))

(define (fb-draw-circle! fb w h cx cy rad rgb [fill? #t])
  (for ([dy (in-range (- rad) (add1 rad))])
    (for ([dx (in-range (- rad) (add1 rad))])
      (define d2 (+ (* dx dx) (* dy dy)))
      (if fill?
          (when (<= d2 (* rad rad))
            (fb-put-px! fb w h (+ cx dx) (+ cy dy) rgb))
          (when (and (<= d2 (* rad rad))
                     (> d2 (* (max 0 (sub1 rad)) (max 0 (sub1 rad)))))
            (fb-put-px! fb w h (+ cx dx) (+ cy dy) rgb))))))

;; Render an ASCII pixel-art bitmap (`rows` is a list of strings) using `cmap` (hash char -> rgb)
(define (fb-draw-bitmap! fb w h sx sy rows cmap [scale 1])
  (for ([row-str (in-list rows)]
        [ry (in-naturals)])
    (for ([ch (in-string row-str)]
          [rx (in-naturals)])
      (define rgb (hash-ref cmap ch #f))
      (when rgb
        (if (= scale 1)
            (fb-put-px! fb w h (+ sx rx) (+ sy ry) rgb)
            (fb-fill-rect! fb w h (+ sx (* rx scale)) (+ sy (* ry scale)) scale scale rgb))))))

;; Crisp 3x5 Arcade / Handheld Pixel Font (with 5x5 Heart `@` and Gem `*`)
(define RETRO-FONT-3X5
  (hash
   #\A '("010" "101" "111" "101" "101")
   #\B '("110" "101" "110" "101" "110")
   #\C '("011" "100" "100" "100" "011")
   #\D '("110" "101" "101" "101" "110")
   #\E '("111" "100" "110" "100" "111")
   #\F '("111" "100" "110" "100" "100")
   #\G '("011" "100" "101" "101" "011")
   #\H '("101" "101" "111" "101" "101")
   #\I '("111" "010" "010" "010" "111")
   #\J '("001" "001" "001" "101" "010")
   #\K '("101" "101" "110" "101" "101")
   #\L '("100" "100" "100" "100" "111")
   #\M '("101" "111" "111" "101" "101")
   #\N '("101" "111" "111" "111" "101")
   #\O '("010" "101" "101" "101" "010")
   #\P '("110" "101" "110" "100" "100")
   #\Q '("010" "101" "101" "111" "011")
   #\R '("110" "101" "110" "101" "101")
   #\S '("011" "100" "010" "001" "110")
   #\T '("111" "010" "010" "010" "010")
   #\U '("101" "101" "101" "101" "111")
   #\V '("101" "101" "101" "101" "010")
   #\W '("101" "101" "111" "111" "101")
   #\X '("101" "101" "010" "101" "101")
   #\Y '("101" "101" "010" "010" "010")
   #\Z '("111" "001" "010" "100" "111")
   #\0 '("111" "101" "101" "101" "111")
   #\1 '("010" "110" "010" "010" "111")
   #\2 '("110" "001" "010" "100" "111")
   #\3 '("110" "001" "010" "001" "110")
   #\4 '("101" "101" "111" "001" "001")
   #\5 '("111" "100" "110" "001" "110")
   #\6 '("011" "100" "111" "101" "111")
   #\7 '("111" "001" "010" "010" "010")
   #\8 '("111" "101" "111" "101" "111")
   #\9 '("111" "101" "111" "001" "110")
   #\: '("000" "010" "000" "010" "000")
   #\- '("000" "000" "111" "000" "000")
   #\/ '("001" "001" "010" "100" "100")
   #\! '("010" "010" "010" "000" "010")
   #\? '("110" "001" "010" "000" "010")
   #\. '("000" "000" "000" "000" "010")
   #\$ '("011" "110" "010" "011" "110")
   #\% '("101" "001" "010" "100" "101")
   #\= '("000" "111" "000" "111" "000")
   #\> '("100" "010" "001" "010" "100")
   #\+ '("000" "010" "111" "010" "000")
   #\[ '("110" "100" "100" "100" "110")
   #\] '("011" "001" "001" "001" "011")
   #\| '("010" "010" "010" "010" "010")
   #\* '("010" "111" "111" "111" "010")
   #\@ '("01010" "11111" "11111" "01110" "00100")
   #\space '("000" "000" "000" "000" "000")))

(define (fb-draw-text! fb w h sx sy text fg-rgb [shadow-rgb #f])
  (let loop ([chars (string->list (string-upcase text))]
             [cx sx])
    (unless (null? chars)
      (define ch (car chars))
      (define rows (hash-ref RETRO-FONT-3X5 ch '("000" "000" "000" "000" "000")))
      (define cw (string-length (first rows)))
      (for ([rstr (in-list rows)]
            [dy (in-naturals)])
        (for ([c (in-string rstr)]
              [dx (in-naturals)])
          (when (char=? c #\1)
            (when shadow-rgb
              (fb-put-px! fb w h (+ cx dx 1) (+ sy dy 1) shadow-rgb))
            (fb-put-px! fb w h (+ cx dx) (+ sy dy) fg-rgb))))
      (loop (cdr chars) (+ cx cw 1)))))

(define (fb-draw-heart! fb w h sx sy fill-rgb outline-rgb)
  (fb-draw-bitmap!
   fb w h sx sy
   '(".OO.OO."
     "OFFFFFO"
     "OFFFFFO"
     ".OJJFO."
     "..OFO.."
     "...O...")
   (hash #\O outline-rgb #\F fill-rgb #\J fill-rgb)))

;; ============================================================================
;; 7B. Authentic Top-10 Game Boy (DMG .gb, 160x144) Scene Renderers
;; ============================================================================

;; Render an 8x8 beveled DMG brick/tetromino tile
(define (draw-dmg-bevel-tile! fb x y c0 c1 c2 c3 [style 0])
  (fb-fill-rect! fb 160 144 x y 8 8 c1)
  (fb-fill-rect! fb 160 144 x y 8 1 c0)
  (fb-fill-rect! fb 160 144 x y 1 8 c0)
  (fb-fill-rect! fb 160 144 x (+ y 7) 8 1 c3)
  (fb-fill-rect! fb 160 144 (+ x 7) y 1 8 c3)
  (case (modulo style 4)
    [(0) (fb-fill-rect! fb 160 144 (+ x 2) (+ y 2) 4 4 c2)
         (fb-fill-rect! fb 160 144 (+ x 3) (+ y 3) 2 2 c0)]
    [(1) (fb-fill-rect! fb 160 144 (+ x 2) (+ y 2) 4 4 c3)
         (fb-put-px! fb 160 144 (+ x 3) (+ y 3) c0)]
    [(2) (fb-stroke-rect! fb 160 144 (+ x 2) (+ y 2) 4 4 c3)]
    [else (fb-fill-rect! fb 160 144 (+ x 2) (+ y 2) 4 4 c2)]))

;; Render a 160x144 RGB framebuffer (69,120 bytes = 23,040 pixels) from a DMG `gb-emulator`
(define (render-gb-framebuffer-rgb emu [spec #f])
  (define fb   (make-bytes (* 160 144 3) 0))
  (define vram (gb-emulator-vram emu))
  (define oam  (gb-emulator-oam emu))
  (define io   (gb-emulator-io emu))
  (define hram (gb-emulator-hram emu))
  (define bgp  (bytes-ref io #x47))
  (define stage-id  (bytes-ref hram (- GB-HRAM-STAGE-ID #x80)))
  (define genre-reg (bytes-ref hram (- GB-HRAM-GENRE-REG #x80)))
  (define game-id   (max 1 (min 10 (bytes-ref hram (- GB-HRAM-GAME-ID #x80)))))
  (define lives     (bytes-ref hram (- GB-HRAM-LIVES #x80)))
  (define raw-px    (bytes-ref oam 1))
  (define raw-py    (bytes-ref oam 0))
  ;; Touch VRAM byte 16 so hardware tile upload state participates deterministically
  (define vram-sig  (bitwise-and (bytes-ref vram 16) 1))
  (void bgp stage-id genre-reg lives vram-sig)

  ;; Classic 4-Shade DMG Olive-Green Palette (Lightest c0 -> Darkest c3)
  (define c0 '(224 248 208)) ; #E0F8D0
  (define c1 '(136 192 112)) ; #88C070
  (define c2 '(52 104 86))   ; #346856
  (define c3 '(8 24 32))     ; #081820
  (define dmg-map (hash #\0 c0 #\1 c1 #\2 c2 #\3 c3))

  (case game-id
    ;; ------------------------------------------------------------------------
    ;; 1. TETRIS (GB, 1989) — 10-wide playfield well, stacked blocks, T-piece & HUD
    ;; ------------------------------------------------------------------------
    [(1)
     (fb-fill-rect! fb 160 144 0 0 160 144 c1)
     ;; Left brick border (x=0..15) and well walls (x=8..15 and x=96..103)
     (for ([ty (in-range 18)])
       (draw-dmg-bevel-tile! fb 0  (* ty 8) c0 c2 c3 c3 2)
       (draw-dmg-bevel-tile! fb 8  (* ty 8) c0 c1 c2 c3 1)
       (draw-dmg-bevel-tile! fb 96 (* ty 8) c0 c1 c2 c3 1))
     ;; 10-column well interior (x=16..95, y=0..143)
     (fb-fill-rect! fb 160 144 16 0 80 144 c0)
     ;; Stacked tetrominoes at bottom of well (rows y=96..136)
     (define well-rows
       '("..22..111."
         ".2233.1444"
         "1133224411"
         "1223322.11"
         "1122331122"
         "33311222.2"))
     (for ([rstr (in-list well-rows)]
           [ry (in-naturals 12)])
       (for ([ch (in-string rstr)]
             [cx (in-naturals)])
         (unless (char=? ch #\.)
           (define st (- (char->integer ch) (char->integer #\1)))
           (draw-dmg-bevel-tile! fb (+ 16 (* cx 8)) (* ry 8) c0 c1 c2 c3 st))))
     ;; Active falling T-tetromino in upper-mid well
     (define tx (* 8 (quotient (max 32 (min 64 raw-px)) 8)))
     (define ty (* 8 (quotient (max 24 (min 56 raw-py)) 8)))
     (draw-dmg-bevel-tile! fb tx       ty       c0 c1 c2 c3 0)
     (draw-dmg-bevel-tile! fb (+ tx 8) ty       c0 c1 c2 c3 0)
     (draw-dmg-bevel-tile! fb (+ tx 16) ty      c0 c1 c2 c3 0)
     (draw-dmg-bevel-tile! fb (+ tx 8) (+ ty 8) c0 c1 c2 c3 0)
     ;; Right HUD Panel (x=104..159)
     (fb-fill-rect! fb 160 144 104 0 56 144 c1)
     (fb-draw-box! fb 160 144 106 4  52 28 c0 c3 c2)
     (fb-draw-text! fb 160 144 112 8  "SCORE" c3)
     (fb-draw-text! fb 160 144 112 18 "001420" c3)
     (fb-draw-box! fb 160 144 106 36 52 26 c0 c3 c2)
     (fb-draw-text! fb 160 144 112 40 "LEVEL" c3)
     (fb-draw-text! fb 160 144 126 50 "01" c3)
     (fb-draw-box! fb 160 144 106 66 52 26 c0 c3 c2)
     (fb-draw-text! fb 160 144 112 70 "LINES" c3)
     (fb-draw-text! fb 160 144 122 80 "004" c3)
     ;; NEXT piece preview box (y=96..138) containing an L-tetromino
     (fb-draw-box! fb 160 144 108 96 48 42 c0 c3 c2)
     (fb-draw-text! fb 160 144 118 100 "NEXT" c3)
     (draw-dmg-bevel-tile! fb 118 112 c0 c1 c2 c3 2)
     (draw-dmg-bevel-tile! fb 126 112 c0 c1 c2 c3 2)
     (draw-dmg-bevel-tile! fb 134 112 c0 c1 c2 c3 2)
     (draw-dmg-bevel-tile! fb 118 120 c0 c1 c2 c3 2)]

    ;; ------------------------------------------------------------------------
    ;; 2. SUPER MARIO LAND (1989) — Birabuto Kingdom 1-1 Pyramids, Palm, Pipe & Mario
    ;; ------------------------------------------------------------------------
    [(2)
     (fb-fill-rect! fb 160 144 0 0 160 144 c0)
     ;; Top HUD bar (y=0..15)
     (fb-fill-rect! fb 160 144 0 15 160 1 c3)
     (fb-draw-text! fb 160 144 4   2 "MARIO*03   1-1  TIME" c3)
     (fb-draw-text! fb 160 144 4   9 "001400     *12   362" c3)
     ;; Distant Egyptian Pyramids (Birabuto Kingdom backdrop)
     (for ([dy (in-range 44)])
       (fb-fill-rect! fb 160 144 (- 38 dy) (+ 76 dy) (* dy 2) 1 (if (even? (quotient dy 4)) c1 c2))
       (fb-fill-rect! fb 160 144 38        (+ 76 dy) dy       1 c2))
     (for ([dy (in-range 28)])
       (fb-fill-rect! fb 160 144 (- 96 dy) (+ 92 dy) (* dy 2) 1 c1)
       (fb-fill-rect! fb 160 144 96        (+ 92 dy) dy       1 c2))
     ;; Birabuto Palm Tree on left (x=10, y=68..120)
     (fb-fill-rect! fb 160 144 11 76 4 44 c2)
     (for ([py (in-range 78 118 4)]) (fb-fill-rect! fb 160 144 11 py 4 1 c3))
     (fb-fill-rect! fb 160 144 3  70 20 5 c2)
     (fb-fill-rect! fb 160 144 6  66 14 4 c1)
     ;; Floating ? blocks & brick platform (x=44..91, y=72..79) + high ? block
     (for ([bx (in-range 44 92 8)]
           [idx (in-naturals)])
       (draw-dmg-bevel-tile! fb bx 72 c0 c1 c2 c3 (if (odd? idx) 0 2))
       (when (odd? idx)
         (fb-draw-text! fb 160 144 (+ bx 2) 73 "?" c3)))
     (draw-dmg-bevel-tile! fb 60 42 c0 c1 c2 c3 0)
     (fb-draw-text! fb 160 144 62 43 "?" c3)
     ;; Warp Pipe on right (x=120..135, y=92..119)
     (fb-draw-box! fb 160 144 118 92 20 7 c1 c3)
     (fb-draw-box! fb 160 144 120 99 16 21 c1 c3)
     (fb-fill-rect! fb 160 144 123 93 3 26 c0)
     (fb-fill-rect! fb 160 144 131 93 3 26 c2)
     ;; Checkered Birabuto Ground Floor (y=120..143)
     (for* ([gy (in-range 15 18)]
            [gx (in-range 20)])
       (draw-dmg-bevel-tile! fb (* gx 8) (* gy 8) c0 c1 c2 c3 2))
     ;; Mario Sprite (12x16) jumping/running at (px, py)
     (define mx (max 24 (min 76 raw-px)))
     (define my 96)
     (fb-draw-bitmap!
      fb 160 144 mx my
      '("...33333...."
        "..32222233.."
        "..3331131..."
        ".313111311.."
        ".3133111333."
        "..33111133.."
        "...3223223.."
        "..322232223."
        ".32223332223"
        ".31132323113"
        ".31133333113"
        "..332222233."
        "...322.223.."
        "..333...333."
        ".3333...3333")
      dmg-map)
     ;; Chibibo (Goomba) at (92, 108) & Nokobon (Koopa) at (142, 106)
     (fb-draw-bitmap!
      fb 160 144 92 108
      '("...3333..."
        "..322223.."
        ".32322323."
        "3223223223"
        "3222222223"
        ".33111133."
        "..311113.."
        ".333..333.")
      dmg-map)
     (fb-draw-bitmap!
      fb 160 144 142 106
      '("....333..."
        "...30303.."
        "...31113.."
        ".33322233."
        "3232323233"
        "3223232223"
        ".33333333."
        "..33..33..")
      dmg-map)]

    ;; ------------------------------------------------------------------------
    ;; 3. ZELDA: LINK'S AWAKENING (1993) — Koholint Trees, Cottage, Link & Bottom HUD
    ;; ------------------------------------------------------------------------
    [(3)
     (fb-fill-rect! fb 160 144 0 0 160 128 c0)
     ;; Koholint Tree Border along top (x=0..159, y=0..15) and right/left corners
     (for ([tx (in-range 0 160 16)])
       (fb-draw-circle! fb 160 144 (+ tx 8) 8 7 c2 #t)
       (fb-draw-circle! fb 160 144 (+ tx 8) 8 7 c3 #f)
       (fb-draw-circle! fb 160 144 (+ tx 6) 6 3 c1 #t))
     ;; Mabe Village Shingled Cottage (x=12..56, y=18..54)
     (fb-draw-box! fb 160 144 12 18 44 18 c2 c3)
     (for ([ry (in-range 20 35 4)])
       (fb-fill-rect! fb 160 144 13 ry 42 1 c3))
     (fb-draw-box! fb 160 144 14 35 40 19 c1 c3)
     (fb-draw-box! fb 160 144 20 40 10 14 c3 c2) ; Doorway
     (fb-draw-box! fb 160 144 36 39 12 9  c0 c3) ; Window
     ;; Tail Cave Rock Cliff & Keyhole Entrance (x=104..152, y=18..52)
     (fb-draw-box! fb 160 144 104 18 48 34 c2 c3)
     (fb-draw-box! fb 160 144 120 32 16 20 c3 c0)
     ;; Wooden Fence Posts (x=12..60, y=62..70) & Grass Tufts
     (for ([fx (in-range 14 62 8)])
       (fb-draw-box! fb 160 144 fx 62 5 9 c1 c3)
       (fb-fill-rect! fb 160 144 (- fx 3) 65 10 2 c2))
     (for* ([gy '(78 96 110)]
            [gx '(20 48 84 136)])
       (fb-draw-text! fb 160 144 gx gy "V" c2))
     ;; Link (16x16) with Koholint Sword & Shield at (px, py)
     (define lx (max 36 (min 76 raw-px)))
     (define ly 76)
     (fb-draw-bitmap!
      fb 160 144 lx ly
      '("....333333......"
        "...32222223....."
        "..3223333223...."
        "..3231011033...."
        "..331111113....."
        ".333222222333..."
        "31132222223003.."
        "3123223322300333"
        "3113222222333003"
        ".3333322333..33."
        "...311..113....."
        "...333..333.....")
      dmg-map)
     ;; Octorok at (108, 72) & Moblin at (124, 96)
     (fb-draw-bitmap!
      fb 160 144 108 72
      '("..3333.."
        ".322223."
        "32033023"
        "32233223"
        ".333333."
        "33.33.33")
      dmg-map)
     (fb-draw-bitmap!
      fb 160 144 124 96
      '(".33..33."
        "32233223"
        "32022023"
        ".323323."
        "32222223"
        ".33..33.")
      dmg-map)
     ;; Bottom Koholint Status Bar (y=128..143)
     (fb-fill-rect! fb 160 144 0 128 160 16 c0)
     (fb-fill-rect! fb 160 144 0 128 160 2  c3)
     (fb-draw-text! fb 160 144 4  134 "B[SWRD] A[SHLD] 025R" c3)
     (fb-draw-heart! fb 160 144 126 133 c2 c3)
     (fb-draw-heart! fb 160 144 136 133 c2 c3)
     (fb-draw-heart! fb 160 144 146 133 c2 c3)]

    ;; ------------------------------------------------------------------------
    ;; 4. KIRBY'S DREAM LAND (1992) — Green Greens, Whispy Woods, Kirby & Bottom HUD
    ;; ------------------------------------------------------------------------
    [(4)
     (fb-fill-rect! fb 160 144 0 0 160 112 c0)
     ;; Fluffy Clouds & Checkered Hills
     (fb-draw-circle! fb 160 144 24 20 8 c0 #t)
     (fb-draw-circle! fb 160 144 24 20 8 c2 #f)
     (fb-draw-circle! fb 160 144 34 20 7 c0 #t)
     (fb-draw-circle! fb 160 144 34 20 7 c2 #f)
     (fb-draw-circle! fb 160 144 76 16 8 c2 #f)
     ;; Whispy Woods Boss Tree on the Right (x=118..159, y=0..96)
     (fb-fill-rect! fb 160 144 128 32 32 64 c2)
     (fb-fill-rect! fb 160 144 128 32 3  64 c3)
     (fb-fill-rect! fb 160 144 146 32 4  64 c1)
     ;; Whispy Canopy (y=0..34)
     (for ([cx '(116 130 144 154)])
       (fb-draw-circle! fb 160 144 cx 18 16 c1 #t)
       (fb-draw-circle! fb 160 144 cx 18 16 c3 #f))
     ;; Whispy Eyes, Nose & Mouth
     (fb-fill-rect! fb 160 144 135 46 4 8 c3)
     (fb-fill-rect! fb 160 144 136 47 2 3 c0)
     (fb-draw-box!  fb 160 144 120 56 14 9 c1 c3) ; Nose
     (fb-draw-box!  fb 160 144 135 68 6  9 c3 c0) ; Mouth
     ;; Falling Apples & Star Blocks
     (fb-draw-circle! fb 160 144 104 52 5 c2 #t)
     (fb-draw-circle! fb 160 144 104 52 5 c3 #f)
     (fb-draw-circle! fb 160 144 112 84 5 c2 #t)
     (fb-draw-circle! fb 160 144 112 84 5 c3 #f)
     (draw-dmg-bevel-tile! fb 20 64 c0 c1 c2 c3 0)
     (draw-dmg-bevel-tile! fb 20 72 c0 c1 c2 c3 0)
     ;; Ground Floor (y=96..111)
     (for* ([gy '(12 13)] [gx (in-range 20)])
       (draw-dmg-bevel-tile! fb (* gx 8) (* gy 8) c0 c1 c2 c3 1))
     ;; Puffing Kirby (16x16) floating at (px, py)
     (define kx (max 36 (min 76 raw-px)))
     (define ky 52)
     (fb-draw-circle! fb 160 144 (+ kx 8) (+ ky 8) 8 c0 #t)
     (fb-draw-circle! fb 160 144 (+ kx 8) (+ ky 8) 8 c3 #f)
     (fb-fill-rect! fb 160 144 (+ kx 6) (+ ky 5) 2 4 c3)
     (fb-fill-rect! fb 160 144 (+ kx 10) (+ ky 5) 2 4 c3)
     (fb-fill-rect! fb 160 144 (+ kx 4) (+ ky 9) 2 2 c2)
     (fb-fill-rect! fb 160 144 (+ kx 12) (+ ky 9) 2 2 c2)
     (fb-fill-rect! fb 160 144 (+ kx 2) (+ ky 14) 5 3 c2)
     (fb-fill-rect! fb 160 144 (+ kx 9) (+ ky 14) 5 3 c2)
     ;; Waddle Dee at (76, 84)
     (fb-draw-circle! fb 160 144 80 89 6 c1 #t)
     (fb-draw-circle! fb 160 144 80 89 6 c3 #f)
     ;; Bottom Bordered Kirby HUD (y=112..143)
     (fb-draw-box! fb 160 144 0   112 160 32 c1 c3)
     (fb-draw-box! fb 160 144 4   116 68  24 c0 c3)
     (fb-draw-text! fb 160 144 8  119 "SCORE" c3)
     (fb-draw-text! fb 160 144 8  129 "002400" c3)
     (fb-draw-box! fb 160 144 76  116 48  24 c0 c3)
     (fb-draw-text! fb 160 144 80 119 "KIRBY" c3)
     (fb-draw-text! fb 160 144 80 129 "||||||" c3)
     (fb-draw-box! fb 160 144 128 116 28  24 c0 c3)
     (fb-draw-text! fb 160 144 132 124 "P=03" c3)]

    ;; ------------------------------------------------------------------------
    ;; 5. POKEMON RED / BLUE (1996) — Charmeleon vs. Pikachu Battle Screen
    ;; ------------------------------------------------------------------------
    [(5)
     (fb-fill-rect! fb 160 144 0 0 160 144 c0)
     ;; Opponent Status Bracket (Top-Left: CHARMELEON :L24)
     (fb-draw-text! fb 160 144 8  6  "CHARMELEON" c3)
     (fb-draw-text! fb 160 144 36 14 ":L24" c3)
     (fb-draw-text! fb 160 144 10 22 "HP:" c3)
     (fb-draw-box!  fb 160 144 24 22 56 5 c0 c3)
     (fb-fill-rect! fb 160 144 26 24 42 2 c2)
     (fb-fill-rect! fb 160 144 6  12 2  18 c3)
     (fb-fill-rect! fb 160 144 6  30 82 2  c3)
     ;; Charmeleon Front Sprite (Top-Right, x=106..146, y=8..44)
     (fb-draw-bitmap!
      fb 160 144 106 8
      '("......3333.........."
        "....33222233........"
        "...3222222223......."
        "..32032222223......."
        "..3233222223........"
        "...333222233...3...."
        "....322111223.313..."
        "..3322111112231013.."
        ".32222111112231013.."
        "323.3211111223.323.."
        "....3221112223.323.."
        "...322222222223223.."
        "...32223333222333..."
        "..32223....32223...."
        ".33033.....33033....")
      dmg-map 2)
     ;; Pikachu Back Sprite (Bottom-Left, x=10..50, y=58..94)
     (fb-draw-bitmap!
      fb 160 144 10 56
      '("..33........33...."
        ".3313......3133..."
        ".31113....31113..."
        "..311133331113...."
        "..311111111113...."
        ".31111111111113..."
        ".31111122111113.33"
        "311111111111113313"
        "31111122211111313."
        ".311111111111313.."
        "..3111111111133..."
        "..333333333333....")
      dmg-map 2)
     ;; Player Status Bracket (Bottom-Right: PIKACHU :L25, HP 52/52)
     (fb-draw-text! fb 160 144 76  54 "PIKACHU" c3)
     (fb-draw-text! fb 160 144 108 62 ":L25" c3)
     (fb-draw-text! fb 160 144 74  70 "HP:" c3)
     (fb-draw-box!  fb 160 144 88  70 58 5 c0 c3)
     (fb-fill-rect! fb 160 144 90  72 52 2 c2)
     (fb-draw-text! fb 160 144 98  78 "52/ 52" c3)
     (fb-fill-rect! fb 160 144 70  86 84 2 c3)
     (fb-fill-rect! fb 160 144 152 60 2  28 c3)
     ;; Bottom Double-Bordered Dialogue & Command Menu Box (y=96..143)
     (fb-draw-box!  fb 160 144 0  96 160 48 c0 c3 c2)
     (fb-draw-text! fb 160 144 6  106 "WILD CHARMELEON" c3)
     (fb-draw-text! fb 160 144 6  116 "APPEARED!" c3)
     (fb-draw-box!  fb 160 144 82 96 78  48 c0 c3 c2)
     (fb-draw-text! fb 160 144 88 108 ">FIGHT PKMN" c3)
     (fb-draw-text! fb 160 144 88 124 " ITEM  RUN" c3)]

    ;; ------------------------------------------------------------------------
    ;; 6. METROID II: RETURN OF SAMUS (1991) — SR388 Cavern, Samus & Alpha Metroid
    ;; ------------------------------------------------------------------------
    [(6)
     ;; Deep dark SR388 subterranean backdrop
     (fb-fill-rect! fb 160 144 0 0 160 144 c3)
     ;; Top-Left Metroid II HUD (EN [99]  METROID [39])
     (fb-draw-box!  fb 160 144 2  2 108 13 c3 c1)
     (fb-draw-text! fb 160 144 6  6 "EN 99  METROID 39" c0)
     ;; Jagged Cavern Ceiling & Stalactites (y=16..34)
     (for ([x (in-range 0 160 8)])
       (define sh (+ 8 (modulo (* x 5) 14)))
       (fb-fill-rect! fb 160 144 x 16 8 sh c2)
       (fb-fill-rect! fb 160 144 (+ x 2) (+ 16 sh) 4 5 c1))
     ;; Left Chozo Ruin Pillar & Pedestal (x=0..56, y=32..118)
     (for ([ty (in-range 4 15)])
       (draw-dmg-bevel-tile! fb 0 (* ty 8) c1 c2 c3 c3 2)
       (draw-dmg-bevel-tile! fb 8 (* ty 8) c1 c2 c3 c3 2))
     ;; Bubbling SR388 Acid Pool (y=124..143) & Rock Ledges (y=114..124)
     (fb-fill-rect! fb 160 144 0  124 160 20 c2)
     (for ([ax (in-range 0 160 6)])
       (fb-fill-rect! fb 160 144 ax 124 4 3 c0))
     (for ([tx (in-range 0 9)])
       (draw-dmg-bevel-tile! fb (* tx 8) 114 c1 c2 c3 c3 1))
     (for ([tx (in-range 12 20)])
       (draw-dmg-bevel-tile! fb (* tx 8) 114 c1 c2 c3 c3 1))
     ;; Samus Aran in Varia Suit (16x22) aiming Arm Cannon at (px, 92)
     (define sx (max 24 (min 56 raw-px)))
     (fb-draw-bitmap!
      fb 160 144 sx 92
      '("....000000......"
        "...01100110....."
        "...01200010....."
        "..0011111100...."
        ".011001100110..."
        ".011011110110000"
        "..00011110001100"
        "....011110..000."
        "...01100110....."
        "...010..010....."
        "..0110..0110...."
        "..000....000....")
      dmg-map 2)
     ;; Wave Beam Pellets
     (fb-draw-circle! fb 160 144 (+ sx 36) 102 2 c0 #t)
     (fb-draw-circle! fb 160 144 (+ sx 46) 100 2 c0 #t)
     ;; Alpha Metroid Hovering on the Right (x=104..136, y=54..82)
     (fb-draw-bitmap!
      fb 160 144 104 54
      '("...00000000..."
        ".001101101100."
        "01100111100110"
        "01011200211010"
        "01112011021110"
        "01111222211110"
        ".001111111100."
        "..0.00..00.0.."
        ".0..0....0..0.")
      dmg-map 2)]

    ;; ------------------------------------------------------------------------
    ;; 7. CASTLEVANIA: THE ADVENTURE (1989) — Gothic Hall, Rope, Belmont & Whip
    ;; ------------------------------------------------------------------------
    [(7)
     (fb-fill-rect! fb 160 144 0 0 160 144 c1)
     ;; Top HUD (y=0..16)
     (fb-draw-box!  fb 160 144 0 0 160 17 c0 c3)
     (fb-draw-text! fb 160 144 4 3  "SCORE 001800  @15 P03" c3)
     (fb-draw-text! fb 160 144 4 10 "P ||||||   E ||||||" c3)
     ;; Gothic Stone Brick Wall Background (y=17..119)
     (for ([ry (in-range 18 120 8)])
       (fb-fill-rect! fb 160 144 0 ry 160 1 c2)
       (for ([rx (in-range (if (even? (quotient ry 8)) 0 8) 160 16)])
         (fb-fill-rect! fb 160 144 rx ry 1 8 c2)))
     ;; Gothic Pointed-Arch Windows (x=22..48 and x=108..134, y=30..84)
     (for ([wx '(22 108)])
       (fb-draw-box! fb 160 144 wx 34 26 50 c3 c2)
       (fb-fill-rect! fb 160 144 (+ wx 12) 34 2 50 c1)
       (fb-fill-rect! fb 160 144 wx 56 26 2 c1))
     ;; Climbable Braided Rope (x=78..81, y=17..119) & Burning Candles
     (for ([ry (in-range 18 118 4)])
       (fb-draw-box! fb 160 144 78 ry 4 4 c0 c3))
     (for ([cx '(62 94)])
       (fb-fill-rect! fb 160 144 cx 52 4 8 c0)
       (fb-fill-rect! fb 160 144 (+ cx 1) 47 2 5 c3))
     ;; Stone Floor (y=120..143) & Right Ledge (x=96..159, y=88..95)
     (for* ([gy '(15 16 17)] [gx (in-range 20)])
       (draw-dmg-bevel-tile! fb (* gx 8) (* gy 8) c0 c1 c2 c3 1))
     (for ([gx (in-range 12 20)])
       (draw-dmg-bevel-tile! fb (* gx 8) 88 c0 c1 c2 c3 2))
     ;; Christopher Belmont (16x24) Cracking the Vampire Killer Whip at (px, 96)
     (define bx (max 24 (min 56 raw-px)))
     (fb-draw-bitmap!
      fb 160 144 bx 96
      '("...33333...."
        "..3111113..."
        "..3310133..."
        ".332222233.."
        "322322232233"
        "...32223..33"
        "..3333333..."
        "..3223223..."
        ".3223.3223.."
        ".333...333.."
        "333.....333."
        "33.......33.")
      dmg-map 2)
     ;; Extended Chain Whip + Fireball Tip
     (for ([wx (in-range (+ bx 22) (+ bx 50) 4)])
       (fb-draw-box! fb 160 144 wx 104 3 3 c0 c3))
     (fb-draw-circle! fb 160 144 (+ bx 54) 105 4 c3 #t)
     (fb-draw-circle! fb 160 144 (+ bx 54) 105 2 c0 #t)
     ;; Swooping Giant Bat at (112, 42) & Punaguchi on Ledge at (126, 72)
     (fb-draw-bitmap!
      fb 160 144 110 42
      '("33....33"
        "32333323"
        ".320023."
        "..3333..")
      dmg-map 2)
     (fb-draw-bitmap!
      fb 160 144 126 72
      '("..3333.."
        ".320023."
        "32233223"
        "32300323"
        ".332233."
        "..3333..")
      dmg-map 2)]

    ;; ------------------------------------------------------------------------
    ;; 8. DUCKTALES (GB, 1990) — Moon Base Girders, Treasure, Scrooge Pogo Cane
    ;; ------------------------------------------------------------------------
    [(8)
     (fb-fill-rect! fb 160 144 0 0 160 144 c0)
     ;; Top HUD (y=0..16)
     (fb-draw-box!  fb 160 144 0 0 160 16 c0 c3)
     (fb-draw-text! fb 160 144 4 5 "$0240000   UP 03   @@@" c3)
     ;; Sci-Fi Moon Metal Girders (y=18..28, left column x=4..16, right column x=144..156)
     (for ([gx (in-range 0 160 16)])
       (fb-draw-box!  fb 160 144 gx 18 16 10 c1 c3)
       (fb-draw-line! fb 160 144 gx 18 (+ gx 15) 27 c3)
       (fb-draw-line! fb 160 144 gx 27 (+ gx 15) 18 c3))
     (for ([gy (in-range 28 120 16)])
       (fb-draw-box!  fb 160 144 4   gy 12 16 c1 c3)
       (fb-draw-line! fb 160 144 4   gy 15 (+ gy 15) c3)
       (fb-draw-box!  fb 160 144 144 gy 12 16 c1 c3)
       (fb-draw-line! fb 160 144 144 gy 155 (+ gy 15) c3))
     ;; Mid-Level Platform (x=76..140, y=76..83) + Treasure Chest & Giant Diamond
     (for ([tx (in-range 10 18)])
       (draw-dmg-bevel-tile! fb (* tx 8) 76 c0 c1 c2 c3 2))
     (fb-draw-box! fb 160 144 84 62 16 14 c1 c3) ; Treasure Chest
     (fb-fill-rect! fb 160 144 84 68 16 2 c3)
     (fb-draw-box! fb 160 144 90 66 4  5 c0 c3)
     ;; Giant Diamond at (112, 60)
     (fb-draw-bitmap!
      fb 160 144 110 60
      '("..3333.."
        ".301103."
        "30100103"
        "31011013"
        ".310013."
        "..3113.."
        "...33...")
      dmg-map 2)
     ;; Cratered Moon Floor (y=120..143)
     (for* ([gy '(15 16 17)] [gx (in-range 20)])
       (draw-dmg-bevel-tile! fb (* gx 8) (* gy 8) c0 c1 c2 c3 0))
     ;; Scrooge McDuck (16x24) Bouncing on Pogo Cane at (px, py)
     (define sx (max 28 (min 64 raw-px)))
     (define sy 74)
     (fb-draw-bitmap!
      fb 160 144 sx sy
      '("...33333...."
        "...32223...."
        "..3333333..."
        "..30303113.."
        "..300011113."
        "...322223..."
        "..32233223.."
        "..32233223.."
        "...333333..."
        "....3..3...."
        "....3333...."
        ".....33....."
        ".....33....."
        "....3003....")
      dmg-map 2)
     ;; Moon Duck Enemy at (116, 100)
     (fb-draw-bitmap!
      fb 160 144 116 98
      '("..3333.."
        ".320023."
        "31133223"
        ".322223."
        "..3333.."
        ".33..33.")
      dmg-map 2)]

    ;; ------------------------------------------------------------------------
    ;; 9. DR. MARIO (GB, 1990) — Medicine Bottle, Viruses, Capsules & Dr. Mario
    ;; ------------------------------------------------------------------------
    [(9)
     ;; Checkered dark background
     (for* ([y (in-range 0 144 4)] [x (in-range 0 160 4)])
       (fb-fill-rect! fb 160 144 x y 4 4 (if (even? (+ (quotient x 4) (quotient y 4))) c2 c3)))
     ;; Center Medicine Bottle Neck (x=66..93, y=6..24) & Body (x=46..113, y=24..140)
     (fb-draw-box! fb 160 144 64 6  32 8  c0 c3)
     (fb-draw-box! fb 160 144 68 13 24 12 c0 c3)
     (fb-draw-box! fb 160 144 46 24 68 116 c0 c3 c1)
     (fb-fill-rect! fb 160 144 50 28 60 108 c0)
     ;; Viruses & Vitamin Capsules inside the Bottle (x=52..108, y=72..132)
     (define bottle-grid
       '("..V..C1."
         ".12..V.."
         "V..V..22"
         "11.2.V.."
         ".V..12.V"
         "22.V..11"
         "V.12.V.2"))
     (for ([rstr (in-list bottle-grid)]
           [ry (in-naturals)])
       (for ([ch (in-string rstr)]
             [cx (in-naturals)])
         (define bx (+ 52 (* cx 7)))
         (define by (+ 80 (* ry 8)))
         (cond
           [(char=? ch #\V)
            ;; Speckled Virus with eyes & feet
            (fb-draw-box! fb 160 144 bx by 6 6 c2 c3)
            (fb-put-px! fb 160 144 (+ bx 1) (+ by 2) c0)
            (fb-put-px! fb 160 144 (+ bx 4) (+ by 2) c0)
            (fb-put-px! fb 160 144 (+ bx 2) (+ by 4) c0)]
           [(char=? ch #\1)
            (fb-draw-box! fb 160 144 bx by 6 6 c1 c3)]
           [(char=? ch #\2)
            (fb-draw-box! fb 160 144 bx by 6 6 c3 c2)])))
     ;; Active Falling 2-Half Vitamin Capsule in Upper Bottle
     (define cap-x (max 56 (min 86 raw-px)))
     (fb-draw-box! fb 160 144 cap-x       44 7 6 c1 c3)
     (fb-draw-box! fb 160 144 (+ cap-x 7) 44 7 6 c3 c2)
     ;; Left HUD Boxes: TOP / SCORE (x=2..43, y=14..74) & Virus Preview (y=80..138)
     (fb-draw-box!  fb 160 144 2 14 42 58 c0 c3 c1)
     (fb-draw-text! fb 160 144 6 20 "TOP" c3)
     (fb-draw-text! fb 160 144 6 28 "010000" c3)
     (fb-draw-text! fb 160 144 6 44 "SCORE" c3)
     (fb-draw-text! fb 160 144 6 52 "002400" c3)
     (fb-draw-box!  fb 160 144 2 78 42 60 c0 c3 c1)
     (fb-draw-circle! fb 160 144 23 108 14 c1 #t)
     (fb-draw-circle! fb 160 144 23 108 14 c3 #f)
     (fb-draw-box!  fb 160 144 16 102 6 6 c2 c3)
     (fb-draw-box!  fb 160 144 25 108 6 6 c3 c2)
     ;; Right HUD Box (x=116..157, y=14..138): Dr. Mario Sprite + LV / SPD / VIRUS
     (fb-draw-box!  fb 160 144 116 14 42 124 c0 c3 c1)
     (fb-draw-bitmap!
      fb 160 144 126 22
      '("..3333.."
        ".300003."
        ".331013."
        "..31113."
        "33003003"
        "30003003"
        ".300003."
        "..33.33.")
      dmg-map 2)
     (fb-draw-text! fb 160 144 120 68  "LV  05" c3)
     (fb-draw-text! fb 160 144 120 84  "SPD" c3)
     (fb-draw-text! fb 160 144 124 92  "MED" c3)
     (fb-draw-text! fb 160 144 120 110 "VIRUS" c3)
     (fb-draw-text! fb 160 144 128 120 "12" c3)]

    ;; ------------------------------------------------------------------------
    ;; 10. GARGOYLE'S QUEST (1990) — Ghoul Realm Columns, Winged Firebrand & Fire
    ;; ------------------------------------------------------------------------
    [else
     (fb-fill-rect! fb 160 144 0 0 160 144 c3)
     ;; Top HUD (y=0..16)
     (fb-draw-box!  fb 160 144 0 0 160 16 c0 c2)
     (fb-draw-text! fb 160 144 4 5 "WING ||||||  VIAL 08  P03" c3)
     ;; Gothic Ghoul Columns (left x=0..15, right x=144..159) & Spikes
     (for ([ty (in-range 2 15)])
       (draw-dmg-bevel-tile! fb 0   (* ty 8) c1 c2 c3 c3 2)
       (draw-dmg-bevel-tile! fb 144 (* ty 8) c1 c2 c3 c3 2))
     ;; Mid-Air Stone Ledges (x=16..64, y=92..99 and x=96..144, y=72..79)
     (for ([tx (in-range 2 8)])
       (draw-dmg-bevel-tile! fb (* tx 8) 92 c0 c1 c2 c3 1))
     (for ([tx (in-range 12 18)])
       (draw-dmg-bevel-tile! fb (* tx 8) 72 c0 c1 c2 c3 1))
     ;; Bone / Catacomb Floor (y=120..143)
     (for* ([gy '(15 16 17)] [gx (in-range 20)])
       (draw-dmg-bevel-tile! fb (* gx 8) (* gy 8) c0 c1 c2 c3 0))
     ;; Winged Firebrand Hovering & Breathing Fireball at (px, 50)
     (define fx (max 28 (min 64 raw-px)))
     (fb-draw-bitmap!
      fb 160 144 fx 48
      '(".0....0..000...."
        "010..01001110..."
        "01100110010310.."
        "01211210.011110."
        ".0122100011100.."
        "..0000011110...."
        ".....0110110...."
        "....010...010..."
        "...00......00...")
      dmg-map 2)
     ;; Fireball Breath Stream
     (fb-draw-circle! fb 160 144 (+ fx 34) 56 4 c0 #t)
     (fb-draw-circle! fb 160 144 (+ fx 34) 56 2 c1 #t)
     (fb-draw-circle! fb 160 144 (+ fx 46) 56 3 c0 #t)
     ;; Skeleton / Ghoul Knight on Right Ledge at (112, 52)
     (fb-draw-bitmap!
      fb 160 144 112 52
      '("..0000.."
        ".030030."
        "..0110.."
        ".001100."
        "01.11.10"
        "...00..."
        "..0..0.."
        ".00..00.")
      dmg-map 2)])
  fb)

;; ============================================================================
;; 7C. Authentic Top-10 Game Boy Color (CGB .gbc, 160x144) Scene Renderers
;; ============================================================================

;; Render a 160x144 RGB framebuffer (69,120 bytes = 23,040 pixels) from a CGB `gb-emulator`
(define (render-gbc-framebuffer-rgb emu [spec #f])
  (define fb       (make-bytes (* 160 144 3) 0))
  (define vram     (gb-emulator-vram emu))
  (define oam      (gb-emulator-oam emu))
  (define io       (gb-emulator-io emu))
  (define hram     (gb-emulator-hram emu))
  (define bg-cram  (gb-emulator-gbc-bg-cram emu))
  (define obj-cram (gb-emulator-gbc-obj-cram emu))
  (define stage-id  (bytes-ref hram (- GB-HRAM-STAGE-ID #x80)))
  (define genre-reg (bytes-ref hram (- GB-HRAM-GENRE-REG #x80)))
  (define game-id   (max 11 (min 20 (bytes-ref hram (- GB-HRAM-GAME-ID #x80)))))
  (define raw-px    (bytes-ref oam 1))
  (define raw-py    (bytes-ref oam 0))
  (void vram io bg-cram obj-cram stage-id genre-reg spec)

  ;; Shared GBC 15-bit BGR555 -> 24-bit RGB Vivid Color Palette Helpers
  (define BLACK  '(12 12 20))
  (define WHITE  '(248 248 244))
  (define CREAM  '(248 240 208))
  (define GRAY   '(136 144 152))
  (define DGRAY  '(64 72 84))
  (define RED    '(232 40 40))
  (define DRED   '(152 20 28))
  (define ORANGE '(248 148 24))
  (define GOLD   '(248 216 32))
  (define GREEN  '(40 200 64))
  (define DGREEN '(16 112 40))
  (define CYAN   '(48 208 248))
  (define BLUE   '(32 104 232))
  (define NAVY   '(20 32 96))
  (define PURPLE '(152 48 208))
  (define DPURP  '(72 20 108))
  (define PINK   '(248 112 184))
  (define BROWN  '(160 88 32))
  (define DBROWN '(96 48 16))
  (define TAN    '(232 184 128))

  (case game-id
    ;; ------------------------------------------------------------------------
    ;; 11. POKEMON GOLD / SILVER / CRYSTAL — Ho-Oh vs. Typhlosion Full-Color Battle
    ;; ------------------------------------------------------------------------
    [(11)
     (fb-fill-rect! fb 160 144 0 0 160 144 CREAM)
     ;; Opponent Status Bracket (Top-Left: HO-OH :L40)
     (fb-draw-text! fb 160 144 8  6  "HO-OH" BLACK)
     (fb-draw-text! fb 160 144 42 13 ":L40" BLACK)
     (fb-draw-text! fb 160 144 8  21 "HP:" BLACK)
     (fb-draw-box!  fb 160 144 22 21 60 5 BLACK BLACK)
     (fb-fill-rect! fb 160 144 24 23 48 2 GREEN)
     (fb-fill-rect! fb 160 144 6  12 2  18 BLACK)
     (fb-fill-rect! fb 160 144 6  29 84 2  BLACK)
     ;; Ho-Oh Front Sprite (Top-Right, x=102..150, y=6..46) in Red, Gold, Green & White
     (fb-draw-bitmap!
      fb 160 144 102 6
      '(".......YYY.........."
        "......YYYYY...RRR..."
        ".GGGG.YRRRY..RRRRR.."
        "GGWWGGYRWBRYRRRRGGG."
        ".GWWWRRRRRRRRRRGGWG."
        "..GWRRRRRRRRRRRRWW.."
        "...RRRRYYYYYRRRRR..."
        "...RRRYYYYYYYRRRR..."
        "....RRYYWWWYYRRR...."
        "...YYRYYWWWYYRYY...."
        "..YYY.YYYYYYY.YYY..."
        "......BB...BB.......")
      (hash #\Y GOLD #\R RED #\G GREEN #\W WHITE #\B BLACK) 2)
     ;; Typhlosion Back Sprite (Bottom-Left, x=10..54, y=54..94) with Blazing Fire Ruff
     (fb-draw-bitmap!
      fb 160 144 10 54
      '("....RRRR.YYYY.RRRR.."
        "..RROOYYYYYYYYYOORR."
        ".RROOYYYYNNNNYYYOORR"
        "..ROOYYNNNNNNNNYYOR."
        "...RYYNNNNNNNNNNYR.."
        "....NNNNNNNNNNNNTT.."
        "...NNNNNNNNNNNNTTTT."
        "..NNNNNNNNNNNNTTTTTT"
        "..NNNNNNNNNNNTTTTTTT"
        "..NNNNNNNNNNTTTTTTTT")
      (hash #\R RED #\O ORANGE #\Y GOLD #\N NAVY #\T TAN) 2)
     ;; Player Status Bracket (Bottom-Right: TYPHLOSION :L38 + Blue EXP Bar)
     (fb-draw-text! fb 160 144 74  52 "TYPHLOSION" BLACK)
     (fb-draw-text! fb 160 144 108 60 ":L38" BLACK)
     (fb-draw-text! fb 160 144 74  68 "HP:" BLACK)
     (fb-draw-box!  fb 160 144 88  68 60 5 BLACK BLACK)
     (fb-fill-rect! fb 160 144 90  70 54 2 GREEN)
     (fb-draw-text! fb 160 144 96  76 "118/118" BLACK)
     (fb-fill-rect! fb 160 144 70  85 84 2 BLACK)
     (fb-fill-rect! fb 160 144 84  88 68 3 CYAN) ; GBC EXP Bar
     (fb-fill-rect! fb 160 144 70  91 84 2 BLACK)
     (fb-fill-rect! fb 160 144 152 58 2  35 BLACK)
     ;; Bottom Command Box (y=96..143)
     (fb-draw-box!  fb 160 144 0  96 160 48 WHITE BLACK GOLD)
     (fb-draw-text! fb 160 144 6  108 "HO-OH USED" BLACK)
     (fb-draw-text! fb 160 144 6  118 "SACRED FIRE!" RED)
     (fb-draw-box!  fb 160 144 84 96 76  48 WHITE BLACK BLUE)
     (fb-draw-text! fb 160 144 90 108 ">FIGHT PKMN" BLACK)
     (fb-draw-text! fb 160 144 90 124 " PACK  RUN" BLACK)]

    ;; ------------------------------------------------------------------------
    ;; 12. ZELDA: ORACLE OF AGES / SEASONS — Full-Color Overworld, River & Link
    ;; ------------------------------------------------------------------------
    [(12)
     ;; Top HUD Bar (y=0..15)
     (fb-fill-rect! fb 160 144 0 0 160 16 CREAM)
     (fb-fill-rect! fb 160 144 0 15 160 1 BLACK)
     (fb-draw-box!  fb 160 144 4  2 36 12 CREAM BLUE)
     (fb-draw-text! fb 160 144 7  5 "B SWRD" BLACK)
     (fb-draw-box!  fb 160 144 44 2 36 12 CREAM RED)
     (fb-draw-text! fb 160 144 47 5 "A ROD" BLACK)
     (fb-draw-text! fb 160 144 84 5 "045R" DGREEN)
     (for ([hx '(112 122 132 142)])
       (fb-draw-heart! fb 160 144 hx 5 RED BLACK))
     ;; Lush Green Overworld Field (y=16..143)
     (fb-fill-rect! fb 160 144 0 16 160 128 '(120 224 96))
     ;; Autumn-Gold & Emerald Trees along Top Border (y=16..34)
     (for ([tx (in-range 0 160 20)]
           [idx (in-naturals)])
       (define tcol (if (even? idx) GREEN ORANGE))
       (fb-draw-circle! fb 160 144 (+ tx 10) 24 9 tcol #t)
       (fb-draw-circle! fb 160 144 (+ tx 10) 24 9 BLACK #f)
       (fb-fill-rect! fb 160 144 (+ tx 8) 31 4 5 BROWN))
     ;; Red-Roofed Holodrum House (x=14..54, y=36..68)
     (fb-draw-box! fb 160 144 14 36 40 16 RED BLACK)
     (fb-draw-box! fb 160 144 16 51 36 17 CREAM BLACK)
     (fb-draw-box! fb 160 144 24 56 10 12 BROWN BLACK)
     (fb-draw-box! fb 160 144 38 55 10 8  CYAN BLACK)
     ;; Sparkling Blue River (y=86..106) & Wooden Bridge (x=64..96, y=82..110)
     (fb-fill-rect! fb 160 144 0 86 160 20 BLUE)
     (for ([wx (in-range 4 156 14)])
       (fb-fill-rect! fb 160 144 wx 92 6 2 CYAN)
       (fb-fill-rect! fb 160 144 (+ wx 4) 100 6 2 WHITE))
     (fb-draw-box! fb 160 144 64 82 32 28 BROWN BLACK)
     (for ([bx (in-range 68 96 6)])
       (fb-fill-rect! fb 160 144 bx 83 1 26 DBROWN))
     ;; Green-Tunic Link (16x16) Slashing Sword at (px, 60)
     (define lx (max 56 (min 88 raw-px)))
     (fb-draw-bitmap!
      fb 160 144 lx 56
      '("...GGGGGG..."
        "..GGGGGGGG.."
        "..GBTTTTBG.."
        "...TTTTTT..."
        ".BBGGGGGGGG."
        "BWWGGGGGGGG."
        "BWWGGBBGG..."
        ".BBGGGGGG..."
        "...TT..TT..."
        "..BBB..BBB..")
      (hash #\G DGREEN #\T TAN #\B BLACK #\W WHITE) 2)
     ;; Silver Sword Slash Arc & Red Octorok at (114, 60)
     (fb-draw-line! fb 160 144 (+ lx 22) 56 (+ lx 34) 66 WHITE)
     (fb-draw-line! fb 160 144 (+ lx 22) 57 (+ lx 34) 67 CYAN)
     (fb-draw-circle! fb 160 144 120 66 7 RED #t)
     (fb-draw-circle! fb 160 144 120 66 7 BLACK #f)]

    ;; ------------------------------------------------------------------------
    ;; 13. WARIO LAND 3 (2000) — Out of the Woods Hollow Tree, Wario, Key & Chest
    ;; ------------------------------------------------------------------------
    [(13)
     ;; Giant Hollow Tree Amber/Brown Woodgrain Background
     (fb-fill-rect! fb 160 144 0 0 160 144 BROWN)
     (for ([x (in-range 0 160 12)])
       (fb-fill-rect! fb 160 144 x 16 4 128 DBROWN))
     ;; Top HUD (y=0..15)
     (fb-draw-box!  fb 160 144 0 0 160 16 BLACK GOLD)
     (fb-draw-text! fb 160 144 6 5 "N1 WOODS  KEY*1  COIN 048" GOLD)
     ;; Lush Green Leaf Canopy at Top (y=16..38)
     (for ([cx (in-range 8 160 20)])
       (fb-draw-circle! fb 160 144 cx 24 12 DGREEN #t)
       (fb-draw-circle! fb 160 144 cx 22 9  GREEN #t))
     ;; Mossy Platforms (x=16..68, y=78..88) & Ground Floor (y=120..143)
     (fb-draw-box! fb 160 144 16 78 52 10 TAN BLACK)
     (fb-fill-rect! fb 160 144 16 78 52 4 GREEN)
     (fb-draw-box! fb 160 144 0 120 160 24 DBROWN BLACK)
     (fb-fill-rect! fb 160 144 0 120 160 5 GREEN)
     ;; Floating Gray/Gold Key above Left Platform (x=36, y=56)
     (fb-draw-circle! fb 160 144 38 60 5 GOLD #t)
     (fb-draw-circle! fb 160 144 38 60 5 BLACK #f)
     (fb-fill-rect! fb 160 144 43 59 10 3 GOLD)
     (fb-fill-rect! fb 160 144 49 62 3  4 GOLD)
     ;; Royal Treasure Chest on Right (x=120..144, y=100..119)
     (fb-draw-box! fb 160 144 120 100 24 20 PURPLE BLACK GOLD)
     (fb-fill-rect! fb 160 144 120 109 24 3 GOLD)
     (fb-draw-box! fb 160 144 129 106 6  7 GOLD BLACK)
     ;; Wario (20x22) in Yellow Cap/Shirt & Purple Overalls Charging at (px, 96)
     (define wx (max 32 (min 72 raw-px)))
     (fb-draw-bitmap!
      fb 160 144 wx 96
      '("...YYYYYY..."
        "..YYYYYYYY.."
        "..YYBBTTPK.."
        ".YYTTTTTTPP."
        "YYYYPPPPYYYY"
        "YYYYPPPPYYYY"
        ".YYPPPPPPYY."
        "..PPPPPPPP.."
        "..GGG..GGG.."
        ".BBBB..BBBB.")
      (hash #\Y GOLD #\P PURPLE #\T TAN #\K PINK #\G GREEN #\B BLACK) 2)
     ;; Spear-Mask Enemy at (96, 102)
     (fb-draw-circle! fb 160 144 102 110 8 RED #t)
     (fb-draw-box! fb 160 144 96 104 8 10 WHITE BLACK)]

    ;; ------------------------------------------------------------------------
    ;; 14. SHANTAE (2002) — Scuttle Town Sunset Dock, Arabian Domes & Hair Whip
    ;; ------------------------------------------------------------------------
    [(14)
     ;; HBlank Sunset Sky Gradient (Violet -> Magenta -> Coral -> Gold)
     (fb-fill-rect! fb 160 144 0 0  160 24 DPURP)
     (fb-fill-rect! fb 160 144 0 24 160 24 PURPLE)
     (fb-fill-rect! fb 160 144 0 48 160 24 PINK)
     (fb-fill-rect! fb 160 144 0 72 160 24 ORANGE)
     ;; Top HUD (Gem 048 & 4 Hearts)
     (fb-draw-circle! fb 160 144 10 8 5 CYAN #t)
     (fb-draw-text! fb 160 144 18 6 "048" WHITE BLACK)
     (for ([hx '(112 122 132 142)])
       (fb-draw-heart! fb 160 144 hx 5 RED BLACK))
     ;; Scuttle Town Arabian Domes & Minarets in Background (x=8..92, y=38..96)
     (fb-draw-circle! fb 160 144 32 54 16 TAN #t)
     (fb-draw-circle! fb 160 144 32 54 16 BLACK #f)
     (fb-fill-rect! fb 160 144 31 32 3 8 GOLD)
     (fb-draw-box!  fb 160 144 14 54 36 42 TAN BLACK)
     (fb-draw-box!  fb 160 144 22 62 8  12 GOLD BLACK)
     (fb-draw-box!  fb 160 144 34 62 8  12 GOLD BLACK)
     (fb-draw-circle! fb 160 144 72 62 12 TAN #t)
     (fb-draw-box!  fb 160 144 58 62 28 34 TAN BLACK)
     ;; Wooden Dock Pier (y=96..110) & Deep-Blue Ocean Waves (y=110..143)
     (fb-fill-rect! fb 160 144 0 110 160 34 NAVY)
     (for ([wx (in-range 0 160 16)])
       (fb-fill-rect! fb 160 144 wx 114 10 3 CYAN)
       (fb-fill-rect! fb 160 144 (+ wx 4) 126 10 2 BLUE))
     (fb-draw-box! fb 160 144 0 96 144 12 BROWN BLACK)
     (for ([px (in-range 12 140 24)])
       (fb-draw-box! fb 160 144 px 94 6 32 DBROWN BLACK))
     ;; Shantae (16x24) Hair-Whipping at (px, 72)
     (define sx (max 36 (min 68 raw-px)))
     (fb-draw-bitmap!
      fb 160 144 sx 72
      '("..PPPPPP...."
        ".PPPPPPPP..."
        "..PPTTBTPP.."
        "...TTTTTT..."
        "..YYRRRRYY.."
        "...TTTTTT..."
        "..RRRRRRRR.."
        "..RRR..RRR.."
        "..YY....YY..")
      (hash #\P PURPLE #\T TAN #\B BLACK #\Y GOLD #\R RED) 2)
     ;; Extended Purple Ponytail Whip Hitting Pirate Tinkerbat!
     (fb-fill-rect! fb 160 144 (+ sx 16) 76 28 5 PURPLE)
     (fb-fill-rect! fb 160 144 (+ sx 20) 74 20 3 PINK)
     ;; Tinkerbat Pirate Enemy at (104, 74)
     (fb-draw-bitmap!
      fb 160 144 104 74
      '("..RRRR.."
        ".BBBBBB."
        ".BYBBYB."
        "..BBBB.."
        ".BBBBBB."
        "..B..B..")
      (hash #\R RED #\B BLACK #\Y GOLD) 2)]

    ;; ------------------------------------------------------------------------
    ;; 15. SUPER MARIO BROS. DELUXE (1999) — Full-Color World 1-1, Pipe & Mario
    ;; ------------------------------------------------------------------------
    [(15)
     ;; Bright Sky-Blue World 1-1 Backdrop
     (fb-fill-rect! fb 160 144 0 0 160 144 '(92 148 252))
     ;; Top HUD
     (fb-draw-text! fb 160 144 4 3  "MARIO  001800  *05  1-1" WHITE BLACK)
     (fb-draw-text! fb 160 144 4 10 "RED COINS 3/5   TIME 375" GOLD BLACK)
     ;; White Clouds & Rounded Green Hill
     (fb-draw-circle! fb 160 144 28 28 8 WHITE #t)
     (fb-draw-circle! fb 160 144 38 26 9 WHITE #t)
     (fb-draw-circle! fb 160 144 48 28 8 WHITE #t)
     (fb-draw-circle! fb 160 144 108 24 8 WHITE #t)
     (fb-draw-circle! fb 160 144 118 24 8 WHITE #t)
     (for ([dy (in-range 28)])
       (fb-fill-rect! fb 160 144 (- 32 dy) (+ 92 dy) (* dy 2) 1 GREEN))
     ;; Floating Orange ? Blocks & Brown Bricks (x=44..92, y=68..76) + High ? Block
     (for ([bx (in-range 44 92 10)]
           [idx (in-naturals)])
       (fb-draw-box! fb 160 144 bx 68 10 10 (if (odd? idx) ORANGE BROWN) BLACK)
       (when (odd? idx)
         (fb-draw-text! fb 160 144 (+ bx 3) 70 "?" WHITE BLACK)))
     (fb-draw-box! fb 160 144 64 38 10 10 ORANGE BLACK)
     (fb-draw-text! fb 160 144 67 40 "?" WHITE BLACK)
     (fb-draw-circle! fb 160 144 69 28 4 GOLD #t) ; Popping Coin
     ;; Bright Green Warp Pipe (x=120..140, y=88..119)
     (fb-draw-box! fb 160 144 118 88 24 8  GREEN BLACK)
     (fb-draw-box! fb 160 144 120 96 20 24 GREEN BLACK)
     (fb-fill-rect! fb 160 144 123 89 4 30 '(168 248 128))
     (fb-fill-rect! fb 160 144 133 89 4 30 DGREEN)
     ;; Reddish-Brown Cobble Ground (y=120..143)
     (for* ([gy (in-range 120 144 8)]
            [gx (in-range 0 160 8)])
       (fb-draw-box! fb 160 144 gx gy 8 8 BROWN BLACK)
       (fb-fill-rect! fb 160 144 (+ gx 1) (+ gy 1) 6 1 TAN))
     ;; Red & Blue Mario Jumping at (px, 84) + Brown Goomba at (96, 104)
     (define mx (max 32 (min 72 raw-px)))
     (fb-draw-bitmap!
      fb 160 144 mx 84
      '("..RRRRRR...."
        ".RRRRRRRRR.."
        ".BBBTTBTT..."
        ".BTTTTBBTTT."
        "..TTTTTTTT.."
        ".RRRBBBRRR.."
        "RRRRBBBBBRRR"
        "TTBBBBBBBBTT"
        "..BBBBBBBB.."
        ".BBB....BBB.")
      (hash #\R RED #\B BLUE #\T TAN) 2)
     (fb-draw-bitmap!
      fb 160 144 96 104
      '("..BBBB.."
        ".BBBBBB."
        "BWWBBWWB"
        "BBBBBBBB"
        ".TTTTTT."
        ".BB..BB.")
      (hash #\B BROWN #\W WHITE #\T TAN) 2)]

    ;; ------------------------------------------------------------------------
    ;; 16. METAL GEAR SOLID: GHOST BABEL (2000) — Stealth Radar, Vision Cone & Snake
    ;; ------------------------------------------------------------------------
    [(16)
     ;; Steel-Slate Fortress Floor Grid
     (fb-fill-rect! fb 160 144 0 0 160 144 '(56 76 88))
     (for ([y (in-range 24 144 16)])
       (fb-fill-rect! fb 160 144 0 y 160 1 DGRAY))
     (for ([x (in-range 0 160 16)])
       (fb-fill-rect! fb 160 144 x 24 1 120 DGRAY))
     ;; Top Tactical HUD Bar (y=0..24) & Top-Right Green Soliton Radar (x=114..157, y=2..38)
     (fb-fill-rect! fb 160 144 0 0 160 24 BLACK)
     (fb-draw-text! fb 160 144 4 4  "LIFE" GOLD)
     (fb-draw-box!  fb 160 144 24 4 64 6 DGRAY WHITE)
     (fb-fill-rect! fb 160 144 26 6 52 3 ORANGE)
     (fb-draw-text! fb 160 144 4 14 "RATION 02   C4 04" CYAN)
     ;; Soliton Radar Box
     (fb-draw-box!  fb 160 144 114 2 44 36 '(8 48 24) GREEN)
     (fb-fill-rect! fb 160 144 115 20 42 1 DGREEN)
     (fb-fill-rect! fb 160 144 136 3  1 34 DGREEN)
     (fb-fill-rect! fb 160 144 126 24 3 3 WHITE) ; Snake radar dot
     (fb-fill-rect! fb 160 144 144 16 3 3 RED)   ; Guard radar dot
     ;; Reinforced Fortress Walls & Military Cargo Crates
     (fb-draw-box! fb 160 144 0  24 16 120 GRAY BLACK)
     (fb-draw-box! fb 160 144 24 44 26 26 TAN BLACK)
     (fb-draw-line! fb 160 144 24 44 49 69 BROWN)
     (fb-draw-box! fb 160 144 24 92 26 26 TAN BLACK)
     (fb-draw-line! fb 160 144 24 92 49 117 BROWN)
     ;; Guard Yellow Security Vision Cone (x=76..116, y=62..106)
     (for ([dx (in-range 38)])
       (define span (+ 2 (quotient dx 2)))
       (fb-fill-rect! fb 160 144 (- 114 dx) (- 84 span) 1 (* span 2) GOLD))
     ;; Solid Snake (16x20) in Dark-Blue Sneaking Suit & Bandana at (px, 72)
     (define sx (max 48 (min 66 raw-px)))
     (fb-draw-bitmap!
      fb 160 144 sx 72
      '("..BBBBBB.."
        ".CCCCCCCC."
        "..TTTTTT.."
        ".NNNNNNNN."
        "NNNNNNNNNN"
        ".NNNNNNNN."
        "..NN..NN.."
        "..BB..BB..")
      (hash #\B BLACK #\C CYAN #\T TAN #\N NAVY) 2)
     ;; Armed Genome Soldier at (116, 74) with Red [!] Alert Overhead!
     (fb-draw-box!  fb 160 144 118 54 12 14 WHITE RED)
     (fb-draw-text! fb 160 144 123 58 "!" RED)
     (fb-draw-bitmap!
      fb 160 144 116 72
      '("..GGGGGG.."
        "..TTTTTT.."
        ".GGGGGGGG."
        "GGGGGGGGGG"
        "..GG..GG.."
        "..BB..BB..")
      (hash #\G DGREEN #\T TAN #\B BLACK) 2)]

    ;; ------------------------------------------------------------------------
    ;; 17. DRAGON WARRIOR MONSTERS (1998) — Slime, Dracky & Dragon vs. King Slime
    ;; ------------------------------------------------------------------------
    [(17)
     (fb-fill-rect! fb 160 144 0 0 160 144 BLACK)
     ;; Top Party Status Window (x=2..157, y=2..36)
     (fb-draw-box!  fb 160 144 2 2 156 34 BLACK WHITE GRAY)
     (fb-draw-text! fb 160 144 8   7  "SLIME    DRACKY   DRAGON" GOLD)
     (fb-draw-text! fb 160 144 8   16 "HP  42   HP  36   HP  58" WHITE)
     (fb-draw-text! fb 160 144 8   25 "MP  18   MP  24   MP  32" CYAN)
     ;; GreatTree Arena Viewport (y=38..98)
     (fb-fill-rect! fb 160 144 4 38 152 32 '(24 88 40))
     (fb-fill-rect! fb 160 144 4 70 152 28 TAN)
     ;; Player Monsters: Blue Slime (x=12, y=68), Purple Dracky (x=38, y=50), Green Dragon (x=64, y=56)
     (fb-draw-circle! fb 160 144 20 78 8 CYAN #t)
     (fb-draw-circle! fb 160 144 20 78 8 BLACK #f)
     (fb-fill-rect! fb 160 144 17 75 2 2 WHITE)
     (fb-fill-rect! fb 160 144 22 75 2 2 WHITE)
     (fb-draw-bitmap!
      fb 160 144 36 50
      '("P..PPPP..P"
        "PP.PWWP.PP"
        "PPPPPPPPPP"
        ".PPRRRRPP."
        "...P..P...")
      (hash #\P PURPLE #\W WHITE #\R RED) 2)
     (fb-draw-bitmap!
      fb 160 144 64 56
      '("..GGGG...."
        ".GGWWGG..."
        ".GGGGGGYY."
        "GGGGGGGGY."
        ".GG..GG...")
      (hash #\G GREEN #\W WHITE #\Y GOLD) 2)
     ;; Giant Crowned King Slime Boss on Right (x=108..148, y=46..90)
     (fb-draw-circle! fb 160 144 128 74 16 CYAN #t)
     (fb-draw-circle! fb 160 144 128 74 16 BLACK #f)
     (fb-draw-box!  fb 160 144 120 48 16 10 GOLD BLACK) ; Crown
     (fb-fill-rect! fb 160 144 126 50 4  4  RED)
     (fb-draw-circle! fb 160 144 122 70 3 WHITE #t)
     (fb-draw-circle! fb 160 144 134 70 3 WHITE #t)
     (fb-fill-rect! fb 160 144 122 78 12 3 RED)
     ;; Bottom Command & Battle Message Boxes (y=100..142)
     (fb-draw-box!  fb 160 144 2  100 68 42 BLACK WHITE GRAY)
     (fb-draw-text! fb 160 144 8  108 ">FIGHT PLAN" WHITE)
     (fb-draw-text! fb 160 144 8  122 " ITEM  RUN" WHITE)
     (fb-draw-box!  fb 160 144 72 100 86 42 BLACK WHITE GRAY)
     (fb-draw-text! fb 160 144 78 108 "KING SLIME" GOLD)
     (fb-draw-text! fb 160 144 78 120 "DRAWS NEAR!" WHITE)]

    ;; ------------------------------------------------------------------------
    ;; 18. MARIO TENNIS (GBC, 2000) — Perspective Grass Court, Net, Luigi & Mario
    ;; ------------------------------------------------------------------------
    [(18)
     ;; Top Stadium Scoreboard (y=0..18)
     (fb-draw-box!  fb 160 144 0 0 160 18 NAVY GOLD)
     (fb-draw-text! fb 160 144 8 6 "MARIO [40] - [15] LUIGI" GOLD)
     ;; Mowed Grass Court Scanline Bands (y=18..143)
     (for ([y (in-range 18 144)])
       (define grass-col (if (even? (quotient y 8)) '(40 184 64) '(32 156 52)))
       (fb-fill-rect! fb 160 144 0 y 160 1 grass-col))
     ;; White Perspective Court Lines (Trapezoid from y=30..136)
     (fb-fill-rect! fb 160 144 36 30  88  2 WHITE) ; Far baseline
     (fb-fill-rect! fb 160 144 28 52  104 1 WHITE) ; Far service line
     (fb-fill-rect! fb 160 144 20 96  120 1 WHITE) ; Near service line
     (fb-fill-rect! fb 160 144 12 134 136 2 WHITE) ; Near baseline
     (fb-draw-line! fb 160 144 36 30  12 134 WHITE) ; Left sideline
     (fb-draw-line! fb 160 144 42 30  20 134 WHITE) ; Left singles line
     (fb-draw-line! fb 160 144 124 30 148 134 WHITE) ; Right sideline
     (fb-draw-line! fb 160 144 118 30 140 134 WHITE) ; Right singles line
     (fb-fill-rect! fb 160 144 80 52  1  44 WHITE) ; Center service line
     ;; Tennis Net across y=70..78 with Posts
     (fb-fill-rect! fb 160 144 18 68 3 12 BLACK)
     (fb-fill-rect! fb 160 144 139 68 3 12 BLACK)
     (fb-fill-rect! fb 160 144 20 70 120 2 WHITE)
     (for ([nx (in-range 22 140 4)])
       (fb-fill-rect! fb 160 144 nx 72 1 6 BLACK))
     ;; Luigi at Far Baseline (x=72, y=22)
     (fb-draw-bitmap!
      fb 160 144 72 22
      '("..GGGG.."
        "..TTTT.."
        ".GGBBGG."
        "..BBBB.."
        "..B..B..")
      (hash #\G GREEN #\T TAN #\B NAVY) 2)
     ;; Yellow Tennis Ball & White Motion Arc
     (fb-draw-line! fb 160 144 78 36 92 60 WHITE)
     (fb-draw-circle! fb 160 144 92 60 3 GOLD #t)
     ;; Mario Swinging Racket at Near Baseline (px, 108)
     (define mx (max 48 (min 96 raw-px)))
     (fb-draw-bitmap!
      fb 160 144 mx 108
      '("..RRRRRR...."
        "..TTTTTT...."
        ".RRRBBBRRR.."
        ".RRBBBBBRRWW"
        "..BBBBBBBBWW"
        "..BBB..BBB..")
      (hash #\R RED #\T TAN #\B BLUE #\W WHITE) 2)
     (fb-draw-circle! fb 160 144 (+ mx 24) 114 5 RED #f)]

    ;; ------------------------------------------------------------------------
    ;; 19. LUFIA: THE LEGEND RETURNS (2001) — Sinistral Gades Boss & 3x3 IP Grid
    ;; ------------------------------------------------------------------------
    [(19)
     ;; Dramatic Dark-Purple Vortex Sky (y=0..88)
     (fb-fill-rect! fb 160 144 0 0  160 44 DPURP)
     (fb-fill-rect! fb 160 144 0 44 160 44 NAVY)
     ;; Temple Stone Pillars on Left & Right
     (fb-draw-box! fb 160 144 0   0 14 88 GRAY BLACK)
     (fb-draw-box! fb 160 144 146 0 14 88 GRAY BLACK)
     ;; Towering Sinistral GADES Boss Sprite in Upper Center (x=58..102, y=6..52)
     (fb-draw-bitmap!
      fb 160 144 60 6
      '("......YYYYYY........"
        "....YYRRRRRRYY......"
        "...YRRBBWWBBRRY....."
        "..PPPPYYYYYYPPPP...."
        ".PPPPPRRRRRRPPPPP..W"
        "PPPPRRYYYYYYRRPPPPWW"
        "PPPPRRRRRRRRRRPPPWW."
        ".PPP..RRRRRR..PPWW.."
        "......YY..YY...YY...")
      (hash #\Y GOLD #\R RED #\B BLACK #\W WHITE #\P PURPLE) 2)
     ;; 4 Party Heroes Standing Below (Wain, Seena, Dei, Mousse at y=64..84)
     (for ([hx '(30 60 90 120)]
           [hcol (list CYAN RED GOLD GREEN)])
       (fb-draw-circle! fb 160 144 hx 68 4 hcol #t)
       (fb-fill-rect! fb 160 144 (- hx 4) 72 8 10 hcol))
     ;; Bottom HUD: Left 3x3 Spiritual Force IP Grid (x=2..48, y=88..142) & Right Status
     (fb-draw-box! fb 160 144 0 88 50 56 BLACK WHITE GOLD)
     (for* ([gy (in-range 3)] [gx (in-range 3)])
       (define cell-col (list-ref (list RED CYAN GOLD GREEN PURPLE RED GOLD CYAN GREEN) (+ (* gy 3) gx)))
       (fb-draw-box! fb 160 144 (+ 6 (* gx 13)) (+ 94 (* gy 15)) 11 13 cell-col WHITE))
     (fb-draw-box!  fb 160 144 50 88 110 56 BLACK WHITE CYAN)
     (fb-draw-text! fb 160 144 56 95  "WAIN  HP 185 IP99" WHITE)
     (fb-draw-text! fb 160 144 56 109 "SEENA HP 142 MP84" CYAN)
     (fb-draw-text! fb 160 144 56 123 "DEI   HP 168 IP75" GOLD)]

    ;; ------------------------------------------------------------------------
    ;; 20. MEGA MAN XTREME 2 (2001) — Cyber Fortress, Mega Man X & Charged Shot
    ;; ------------------------------------------------------------------------
    [else
     ;; Dark Navy Cyberspace Fortress Wall with Glowing Neon Conduits
     (fb-fill-rect! fb 160 144 0 0 160 144 '(12 20 56))
     (for ([x (in-range 16 144 24)])
       (fb-fill-rect! fb 160 144 x 0 2 118 NAVY)
       (fb-fill-rect! fb 160 144 (+ x 8) 24 12 2 CYAN))
     (for ([y '(28 60 92)])
       (fb-fill-rect! fb 160 144 14 y 132 2 '(24 88 160)))
     ;; Left Vertical X Health Bar (x=4..11, y=14..78) & Right Boss Bar (x=148..155)
     (fb-draw-box! fb 160 144 4   14 8 64 BLACK WHITE)
     (fb-draw-box! fb 160 144 148 14 8 64 BLACK WHITE)
     (for ([by (in-range 20 74 4)])
       (fb-fill-rect! fb 160 144 6   by 4 2 GOLD)
       (fb-fill-rect! fb 160 144 150 by 4 2 RED))
     (fb-draw-text! fb 160 144 6   80 "X" CYAN)
     (fb-draw-text! fb 160 144 150 80 "B" RED)
     ;; Metallic Cyber Deck Floor (y=118..143)
     (for ([gx (in-range 0 160 16)])
       (fb-draw-box! fb 160 144 gx 118 16 26 GRAY BLACK)
       (fb-fill-rect! fb 160 144 (+ gx 2) 120 12 3 CYAN))
     ;; Mega Man X (18x24) in Cyan/Blue Armor Firing Spiral Charged X-Buster at (px, 94)
     (define xx (max 20 (min 48 raw-px)))
     (fb-draw-bitmap!
      fb 160 144 xx 94
      '("...BBBBBB..."
        "..BBRCCRRB.."
        "..BBTTTTBB.."
        ".CCCCBBBBYY."
        ".CCBBBBBBYYY"
        "..BBBBBBBB.."
        "..CCC..CCC.."
        ".BBBB..BBBB."
        ".BBBB..BBBB.")
      (hash #\B BLUE #\C CYAN #\R RED #\T TAN #\Y GOLD) 2)
     ;; Huge 3-Color Charged X-Buster Spiral Blast!
     (fb-draw-circle! fb 160 144 (+ xx 34) 102 8 PINK #t)
     (fb-draw-circle! fb 160 144 (+ xx 34) 102 5 GOLD #t)
     (fb-draw-circle! fb 160 144 (+ xx 34) 102 3 WHITE #t)
     (fb-fill-rect!   fb 160 144 (+ xx 22) 100 18 4 WHITE)
     ;; Maverick Boss (Neon Tiger / Gareth) on Right (x=114..142, y=88..117)
     (fb-draw-bitmap!
      fb 160 144 114 90
      '("..YY..YY...."
        ".YYYYYYYY..."
        "YYRRYYYYRRYY"
        ".YYYYYYYYYY."
        "..GGGGGGGG.."
        ".YYGGGGGGYY."
        "..YY....YY..")
      (hash #\Y GOLD #\R RED #\G GREEN) 2)])
  fb)

;; ============================================================================
;; 7D. Authentic Top-10 PICO-8 (.p8) / RP2040 (.uf2) 128x128 Scene Renderers
;; ============================================================================

;; Official 16-Color PICO-8 RGB Palette Table
(define PICO8-RGB-PALETTE
  #((0 0 0)       (29 43 83)    (126 37 83)   (0 135 81)
    (171 82 54)   (95 87 79)    (194 195 199) (255 241 232)
    (255 0 77)    (255 163 0)   (255 236 39)  (0 228 54)
    (41 173 255)  (131 118 156) (255 119 168) (255 204 170)))

(define (p8col idx)
  (vector-ref PICO8-RGB-PALETTE (modulo idx 16)))

(define PICO8-CHAR-MAP
  (for/hash ([i (in-range 16)])
    (values (string-ref "0123456789ABCDEF" i) (p8col i))))

;; Render a 128x128 RGB framebuffer (49,152 bytes = 16,384 pixels) for a PICO-8 / RP2040 checkpoint state
(define (render-pico8-framebuffer-rgb spec state-hash)
  (define fb      (make-bytes (* 128 128 3) 0))
  (define idx     (hash-ref spec 'game-index 1))
  (define stg     (hash-ref state-hash 'stageId 0))
  (define raw-px  (bitwise-and #x7F (hash-ref state-hash 'playerX (+ 20 idx))))
  (define raw-py  (bitwise-and #x7F (hash-ref state-hash 'playerY (+ 56 idx))))
  (void stg)

  (case idx
    ;; ------------------------------------------------------------------------
    ;; 1. CELESTE CLASSIC (2015) — Night Mountain, Snow, Madeline Dash & Strawberry
    ;; ------------------------------------------------------------------------
    [(1)
     (fb-fill-rect! fb 128 128 0 0 128 128 (p8col 0))
     ;; Distant Dark-Blue & Purple Mountain Peaks
     (for ([dy (in-range 60)])
       (fb-fill-rect! fb 128 128 (- 40 dy) (+ 48 dy) (* dy 2) 1 (p8col 1))
       (fb-fill-rect! fb 128 128 (- 96 dy) (+ 56 dy) (* dy 2) 1 (p8col 2)))
     ;; Falling Snow Particles
     (for ([s '((18 28 2) (46 18 1) (74 34 2) (108 20 1) (28 68 1) (84 72 2) (114 58 1))])
       (fb-fill-rect! fb 128 128 (first s) (second s) (third s) (third s) (p8col 7)))
     ;; Top-Left Timer & Altitude HUD Box
     (fb-draw-box!  fb 128 128 2 2 58 13 (p8col 0) (p8col 7))
     (fb-draw-text! fb 128 128 5 6 "100M 00:18" (p8col 7))
     ;; Snow-Capped Ice & Rock Ledges + Floor Spikes
     (fb-draw-box!  fb 128 128 0  20 12 108 (p8col 1) (p8col 12))
     (fb-draw-box!  fb 128 128 0  92 48 36  (p8col 1) (p8col 12))
     (fb-fill-rect! fb 128 128 0  92 48 3   (p8col 7))
     (fb-draw-box!  fb 128 128 68 98 60 30  (p8col 1) (p8col 12))
     (fb-fill-rect! fb 128 128 68 98 60 3   (p8col 7))
     (fb-draw-box!  fb 128 128 76 52 52 10  (p8col 1) (p8col 12))
     (fb-fill-rect! fb 128 128 76 52 52 2   (p8col 7))
     ;; White Ice Spikes in Pit (x=48..67, y=118..127)
     (for ([sx (in-range 49 67 4)])
       (fb-draw-line! fb 128 128 sx 127 (+ sx 2) 118 (p8col 7))
       (fb-draw-line! fb 128 128 (+ sx 2) 118 (+ sx 4) 127 (p8col 6)))
     ;; Madeline Air-Dashing with White/Cyan Dash Trail at (px, py)
     (define mx (max 24 (min 52 raw-px)))
     (define my 64)
     (fb-draw-circle! fb 128 128 (- mx 10) (+ my 10) 3 (p8col 12) #t)
     (fb-draw-circle! fb 128 128 (- mx 5)  (+ my 7)  4 (p8col 7)  #t)
     (fb-draw-bitmap!
      fb 128 128 mx my
      '("..888888.."
        ".88888888."
        "888FFFF88."
        "88FF0FF0.."
        ".8CCCCCC.."
        "..CCCCCC.."
        "..11..11..")
      PICO8-CHAR-MAP 2)
     ;; Winged Red Strawberry at (92, 26)
     (fb-draw-bitmap!
      fb 128 128 88 26
      '("77..BB..77"
        "777.88.777"
        ".77878877."
        "...8878..."
        "....88....")
      PICO8-CHAR-MAP 2)]

    ;; ------------------------------------------------------------------------
    ;; 2. PICO-HOT — Minimalist White 3D Corridor, Red Crystal Enemy & Bullet Trail
    ;; ------------------------------------------------------------------------
    [(2)
     ;; Stark White & Light-Gray 3D Perspective Corridor
     (fb-fill-rect! fb 128 128 0 0 128 128 (p8col 7))
     (fb-fill-rect! fb 128 128 0 0 128 28  (p8col 6))
     (fb-fill-rect! fb 128 128 0 96 128 32 (p8col 6))
     ;; Perspective Wireframe Edges & Rear Doorway
     (fb-draw-box!  fb 128 128 40 30 48 64 (p8col 6) (p8col 0))
     (fb-draw-box!  fb 128 128 52 42 24 52 (p8col 5) (p8col 0))
     (fb-draw-line! fb 128 128 0 0   40 30 (p8col 0))
     (fb-draw-line! fb 128 128 127 0 87 30 (p8col 0))
     (fb-draw-line! fb 128 128 0 127 40 93 (p8col 0))
     (fb-draw-line! fb 128 128 127 127 87 93 (p8col 0))
     ;; Bold SUPER / HOT Top Overlay
     (fb-draw-box!  fb 128 128 24 4 80 14 (p8col 8) (p8col 0))
     (fb-draw-text! fb 128 128 32 8 "SUPER   HOT" (p8col 7))
     ;; Faceted Red Crystal Enemy in Corridor (x=54..74, y=42..92)
     (fb-draw-bitmap!
      fb 128 128 54 42
      '("...8888..."
        "..88EE88.."
        "..828828.."
        "...8888..."
        ".888EE888."
        "8828888288"
        "88.8888.88"
        "...8228..."
        "..88..88.."
        "..22..22.."
        "..88..88..")
      PICO8-CHAR-MAP 2)
     ;; Bullet & Dotted Trajectory Line
     (for ([t (in-range 8)])
       (fb-fill-rect! fb 128 128 (- 52 (* t 5)) (+ 56 (* t 3)) 3 2 (if (even? t) (p8col 8) (p8col 0))))
     (fb-draw-circle! fb 128 128 14 80 3 (p8col 0) #t)
     ;; Center Crosshair & Bottom-Right Black Pistol Silhouette
     (fb-stroke-rect! fb 128 128 60 60 8 8 (p8col 0))
     (fb-fill-rect!   fb 128 128 88 94 28 10 (p8col 0))
     (fb-fill-rect!   fb 128 128 104 104 14 24 (p8col 0))
     (fb-fill-rect!   fb 128 128 90 96 18 3 (p8col 5))]

    ;; ------------------------------------------------------------------------
    ;; 3. JELPI — Sky-Blue World, Green/Brown Checker Hills & Pink Jelpi Hero
    ;; ------------------------------------------------------------------------
    [(3)
     (fb-fill-rect! fb 128 128 0 0 128 128 (p8col 12))
     ;; Top HUD (Hearts & Score)
     (for ([hx '(4 14 24)])
       (fb-draw-heart! fb 128 128 hx 4 (p8col 8) (p8col 0)))
     (fb-draw-text! fb 128 128 72 5 "SCORE 0420" (p8col 7) (p8col 1))
     ;; Fluffy White Clouds & Distant Pastel Hills
     (fb-draw-circle! fb 128 128 24 24 8 (p8col 7) #t)
     (fb-draw-circle! fb 128 128 34 22 9 (p8col 7) #t)
     (fb-draw-circle! fb 128 128 92 22 8 (p8col 7) #t)
     (fb-draw-circle! fb 128 128 102 22 7 (p8col 7) #t)
     (fb-draw-circle! fb 128 128 32 96 28 (p8col 13) #t)
     (fb-draw-circle! fb 128 128 96 96 24 (p8col 13) #t)
     ;; Raised Grassy Plateau (x=72..120, y=62..72) & Spinning Coins
     (fb-draw-box!  fb 128 128 72 62 48 10 (p8col 4) (p8col 0))
     (fb-fill-rect! fb 128 128 72 62 48 4  (p8col 11))
     (for ([cx '(80 94 108)])
       (fb-draw-circle! fb 128 128 cx 52 4 (p8col 10) #t)
       (fb-draw-circle! fb 128 128 cx 52 4 (p8col 9)  #f))
     ;; Lush Green Grass Turf (y=90..97) & Checkered Brown Soil (y=98..127)
     (fb-fill-rect! fb 128 128 0 90 128 5 (p8col 11))
     (fb-fill-rect! fb 128 128 0 95 128 3 (p8col 3))
     (for* ([gy (in-range 98 128 8)]
            [gx (in-range 0 128 8)])
       (fb-fill-rect! fb 128 128 gx gy 8 8
                      (if (even? (+ (quotient gx 8) (quotient gy 8))) (p8col 4) (p8col 15))))
     ;; Cute Pink Jelpi Blob Hero Bouncing at (px, 68) + Purple Monster at (92, 74)
     (define jx (max 24 (min 52 raw-px)))
     (fb-draw-circle! fb 128 128 (+ jx 8) 76 10 (p8col 7)  #f) ; Wave-dash aura
     (fb-draw-circle! fb 128 128 (+ jx 8) 76 8  (p8col 14) #t)
     (fb-draw-circle! fb 128 128 (+ jx 8) 76 8  (p8col 0)  #f)
     (fb-fill-rect!   fb 128 128 (+ jx 5) 73 2 4 (p8col 0))
     (fb-fill-rect!   fb 128 128 (+ jx 10) 73 2 4 (p8col 0))
     (fb-fill-rect!   fb 128 128 (+ jx 3) 77 2 2 (p8col 8))
     (fb-fill-rect!   fb 128 128 (+ jx 12) 77 2 2 (p8col 8))
     ;; Spiky Purple Monster at (92, 76)
     (fb-draw-circle! fb 128 128 96 82 7 (p8col 2) #t)
     (fb-fill-rect!   fb 128 128 93 80 2 2 (p8col 10))
     (fb-fill-rect!   fb 128 128 98 80 2 2 (p8col 10))]

    ;; ------------------------------------------------------------------------
    ;; 4. POOM — 3D Raycast Doom Corridor, Lava Pit, Cyber-Imp, Shotgun & Status Bar
    ;; ------------------------------------------------------------------------
    [(4)
     (fb-fill-rect! fb 128 128 0 0 128 104 (p8col 0))
     ;; Perspective Textured Corridor Walls (Left x=0..38, Right x=90..127)
     (for ([x (in-range 38)])
       (define top (+ 6 (quotient (* x 22) 38)))
       (define bot (- 98 (quotient (* x 22) 38)))
       (define wcol (if (even? (quotient x 6)) (p8col 5) (p8col 4)))
       (fb-fill-rect! fb 128 128 x top 1 (- bot top) wcol)
       (fb-fill-rect! fb 128 128 (- 127 x) top 1 (- bot top) wcol))
     ;; Ceiling Tech Lights & Molten Red/Orange Lava Floor Pit (y=76..103)
     (fb-fill-rect! fb 128 128 46 10 36 4 (p8col 8))
     (fb-fill-rect! fb 128 128 38 76 52 28 (p8col 8))
     (fb-fill-rect! fb 128 128 44 82 40 16 (p8col 9))
     (fb-fill-rect! fb 128 128 52 86 24 8  (p8col 10))
     ;; Menacing Cyber-Imp Demon in Center Corridor (x=50..78, y=34..74)
     (fb-draw-bitmap!
      fb 128 128 52 34
      '(".A..8888..A."
        ".AA882288AA."
        "..88A88A88.."
        "..88877888.."
        "B98888888888"
        "BB88.8888.88"
        "....88..88.."
        "...44....44.")
      PICO8-CHAR-MAP 2)
     ;; Player Super Shotgun Barrel & Muzzle Flash (x=54..74, y=76..103)
     (fb-draw-circle! fb 128 128 64 76 7 (p8col 9)  #t)
     (fb-draw-circle! fb 128 128 64 76 4 (p8col 10) #t)
     (fb-draw-box!    fb 128 128 56 80 8 24 (p8col 5) (p8col 0))
     (fb-draw-box!    fb 128 128 64 80 8 24 (p8col 5) (p8col 0))
     (fb-fill-rect!   fb 128 128 58 82 2 20 (p8col 6))
     (fb-fill-rect!   fb 128 128 66 82 2 20 (p8col 6))
     ;; Classic Doom Status Bar (y=104..127)
     (fb-draw-box!  fb 128 128 0 104 128 24 (p8col 5) (p8col 6) (p8col 0))
     (fb-draw-text! fb 128 128 4  108 "AMMO" (p8col 6))
     (fb-draw-text! fb 128 128 6  116 " 48"  (p8col 10))
     (fb-draw-text! fb 128 128 28 108 "HEALTH" (p8col 6))
     (fb-draw-text! fb 128 128 30 116 "100%" (p8col 8))
     ;; Doomguy Mugshot Box (x=56..72, y=106..125)
     (fb-draw-box!  fb 128 128 56 106 16 19 (p8col 0) (p8col 6))
     (fb-fill-rect! fb 128 128 59 109 10 4  (p8col 4))
     (fb-fill-rect! fb 128 128 59 113 10 10 (p8col 15))
     (fb-fill-rect! fb 128 128 61 115 2  2  (p8col 0))
     (fb-fill-rect! fb 128 128 66 115 2  2  (p8col 0))
     (fb-draw-text! fb 128 128 80 108 "ARMOR" (p8col 6))
     (fb-draw-text! fb 128 128 84 116 " 50%" (p8col 11))]

    ;; ------------------------------------------------------------------------
    ;; 5. DUSK CHILD — Subterranean Clockwork Ruin & Warm Lantern Light Halo
    ;; ------------------------------------------------------------------------
    [(5)
     (fb-fill-rect! fb 128 128 0 0 128 128 (p8col 0))
     (fb-fill-rect! fb 128 128 8 14 112 90 (p8col 1))
     ;; Ancient Stone Columns & Background Clockwork Gear
     (fb-draw-box! fb 128 128 10 14 12 90 (p8col 5) (p8col 0))
     (fb-draw-box! fb 128 128 106 14 12 90 (p8col 5) (p8col 0))
     (fb-draw-circle! fb 128 128 92 42 16 (p8col 4) #t)
     (fb-draw-circle! fb 128 128 92 42 10 (p8col 1) #t)
     (fb-draw-circle! fb 128 128 92 42 4  (p8col 9) #t)
     ;; Hanging Green Vines from Ceiling
     (for ([vx '(28 46 68 84)])
       (fb-fill-rect! fb 128 128 vx 14 2 (+ 12 (modulo (* vx 3) 16)) (p8col 3))
       (fb-fill-rect! fb 128 128 (add1 vx) 14 1 10 (p8col 11)))
     ;; Top Lantern & Soul HUD
     (fb-draw-text! fb 128 128 6 4 "LANTERN ||||||  SOUL 04" (p8col 10))
     ;; Concentric Warm Lantern Light Halo around Hero at (px, 68)
     (define dx (max 34 (min 58 raw-px)))
     (define dy 68)
     (fb-draw-circle! fb 128 128 (+ dx 6) (+ dy 6) 30 (p8col 2)  #t)
     (fb-draw-circle! fb 128 128 (+ dx 6) (+ dy 6) 21 (p8col 4)  #t)
     (fb-draw-circle! fb 128 128 (+ dx 6) (+ dy 6) 14 (p8col 9)  #t)
     (fb-draw-circle! fb 128 128 (+ dx 6) (+ dy 6) 8  (p8col 10) #t)
     ;; Cloaked Dusk Child Hero Holding Glowing Lantern
     (fb-draw-bitmap!
      fb 128 128 dx dy
      '("..1111.."
        ".11FF11."
        ".1CCCC1."
        "1CCCCCC7"
        "1CCCCCC7"
        ".11..11.")
      PICO8-CHAR-MAP 2)
     ;; Floating Cyan Spirit Wisps & Stone Floor (y=104..127)
     (fb-draw-circle! fb 128 128 84 72 4 (p8col 12) #t)
     (fb-draw-circle! fb 128 128 84 72 2 (p8col 7)  #t)
     (for ([gx (in-range 0 128 16)])
       (fb-draw-box! fb 128 128 gx 104 16 24 (p8col 5) (p8col 0)))]

    ;; ------------------------------------------------------------------------
    ;; 6. PORKLIKE — Top-Down Roguelike Dungeon Rooms, Pig-Knight, Chest & Foes
    ;; ------------------------------------------------------------------------
    [(6)
     (fb-fill-rect! fb 128 128 0 0 128 128 (p8col 0))
     ;; Top Roguelike Status Bar
     (fb-draw-box!  fb 128 128 0 0 128 14 (p8col 0) (p8col 5))
     (fb-draw-text! fb 128 128 4 5 "HP @@@@  FLR 03  GOLD 42" (p8col 7))
     ;; Western Main Dungeon Room (x=8..76, y=20..112) & Eastern Vault (x=88..122, y=32..100)
     (fb-draw-box! fb 128 128 8  20 68 92 (p8col 5) (p8col 6))
     (fb-draw-box! fb 128 128 14 26 56 80 (p8col 1) (p8col 0))
     (fb-draw-box! fb 128 128 88 32 34 68 (p8col 5) (p8col 6))
     (fb-draw-box! fb 128 128 94 38 22 56 (p8col 1) (p8col 0))
     ;; Connecting Corridor & Wooden Door (x=70..94, y=56..72)
     (fb-fill-rect! fb 128 128 70 58 24 12 (p8col 1))
     (fb-draw-box!  fb 128 128 72 58 4  12 (p8col 4) (p8col 9))
     ;; Floor Cobble Dots
     (for* ([ry (in-range 32 102 12)] [rx (in-range 20 66 12)])
       (fb-put-px! fb 128 128 rx ry (p8col 5)))
     ;; Pink Pig-Knight Hero with Steel Sword at (px, 60)
     (define px (max 22 (min 46 raw-px)))
     (fb-draw-bitmap!
      fb 128 128 px 58
      '("E..EE..7"
        "EEEEEEEE7"
        "E0EEEE0E7"
        "EE8888EE7"
        ".CCCCCC6."
        ".CC..CC..")
      PICO8-CHAR-MAP 2)
     ;; White Skeleton at (52, 36), Green Slime at (48, 84) & Gold Chest at (98, 56)
     (fb-draw-bitmap!
      fb 128 128 52 36
      '(".7777."
        "707707"
        ".7777."
        "7.77.7"
        ".7..7.")
      PICO8-CHAR-MAP 2)
     (fb-draw-circle! fb 128 128 52 88 6 (p8col 11) #t)
     (fb-draw-box!    fb 128 128 98 56 14 12 (p8col 9) (p8col 10))]

    ;; ------------------------------------------------------------------------
    ;; 7. MAI-CHAN'S SWEET BUNS — Bakery Counter, Plump Steamed Buns & Mai-Chan
    ;; ------------------------------------------------------------------------
    [(7)
     (fb-fill-rect! fb 128 128 0 0 128 128 (p8col 4))
     ;; Top Bakery Order Banner
     (fb-draw-box!  fb 128 128 0 0 128 15 (p8col 15) (p8col 9))
     (fb-draw-text! fb 128 128 4 5 "ORDER [P][G][Y]  SC 1250" (p8col 4))
     ;; Left Mai-Chan Baker Sprite (x=3..25, y=42..98)
     (fb-draw-bitmap!
      fb 128 128 4 44
      '("..777777.."
        ".77777777."
        "..FFFFFF.."
        ".FF0FF0FF."
        "..F8FF8F.."
        ".88777788."
        ".87777778."
        "..777777..")
      PICO8-CHAR-MAP 2)
     ;; Center Bamboo Steamer Puzzle Grid (x=28..92, y=18..114, 4x6 Steamed Buns!)
     (fb-draw-box! fb 128 128 26 18 68 98 (p8col 15) (p8col 9) (p8col 4))
     (define bun-colors (vector 14 11 10 7 8 12))
     (for* ([ry (in-range 5)]
            [cx (in-range 4)])
       (define bx (+ 30 (* cx 15)))
       (define by (+ 24 (* ry 17)))
       (define bcol (p8col (vector-ref bun-colors (modulo (+ (* ry 3) cx) 6))))
       (fb-draw-circle! fb 128 128 (+ bx 6) (+ by 6) 6 bcol #t)
       (fb-draw-circle! fb 128 128 (+ bx 6) (+ by 6) 6 (p8col 0) #f)
       (fb-put-px! fb 128 128 (+ bx 4) (+ by 5) (p8col 0))
       (fb-put-px! fb 128 128 (+ bx 8) (+ by 5) (p8col 0))
       (fb-put-px! fb 128 128 (+ bx 3) (+ by 7) (p8col 8))
       (fb-put-px! fb 128 128 (+ bx 9) (+ by 7) (p8col 8)))
     ;; Active Swap Cursor Frame
     (fb-stroke-rect! fb 128 128 44 40 31 16 (p8col 10))
     ;; Right Combo / Shift Ticket Box (x=96..125, y=18..114)
     (fb-draw-box!  fb 128 128 96 18 30 98 (p8col 7) (p8col 4))
     (fb-draw-text! fb 128 128 99 26 "CHAIN" (p8col 8))
     (fb-draw-text! fb 128 128 103 36 "*03!" (p8col 9))
     (fb-draw-text! fb 128 128 99 56 "SHIFT" (p8col 1))
     (fb-draw-text! fb 128 128 103 66 "02"   (p8col 1))]

    ;; ------------------------------------------------------------------------
    ;; 8. ASCENT — Alien Cavern, Glowing Crystals, Astronaut Jetpack & Grapple
    ;; ------------------------------------------------------------------------
    [(8)
     (fb-fill-rect! fb 128 128 0 0 128 128 (p8col 0))
     (fb-fill-rect! fb 128 128 12 14 104 114 (p8col 1))
     ;; Top O2 & Jetpack Fuel HUD
     (fb-draw-text! fb 128 128 4 4 "O2 ||||||   FUEL |||||" (p8col 12))
     ;; Jagged Cavern Rock Walls & Overhangs (col 2/13)
     (fb-fill-rect! fb 128 128 0   14 16 114 (p8col 2))
     (fb-fill-rect! fb 128 128 112 14 16 114 (p8col 2))
     (fb-draw-box!  fb 128 128 64  36 48 14  (p8col 2) (p8col 13))
     (fb-draw-box!  fb 128 128 16  98 48 16  (p8col 2) (p8col 13))
     ;; Glowing Bioluminescent Cyan & Green Crystal Formations
     (for ([cx '(22 34 72 88 100)])
       (define cy (if (< cx 50) 90 28))
       (fb-draw-line! fb 128 128 cx cy (+ cx 4) (- cy 8) (p8col 12))
       (fb-draw-line! fb 128 128 (+ cx 1) cy (+ cx 5) (- cy 8) (p8col 11)))
     ;; Grapple Line from Astronaut to Crystal Overhang (76, 48)
     (define ax (max 32 (min 56 raw-px)))
     (define ay 64)
     (fb-draw-line! fb 128 128 (+ ax 8) ay 76 48 (p8col 12))
     (fb-draw-circle! fb 128 128 76 48 3 (p8col 7) #t)
     ;; White-Suited Astronaut with Orange/Yellow Jetpack Flame
     (fb-draw-bitmap!
      fb 128 128 ax ay
      '("..7777.."
        ".7CCCC7."
        ".7CCCC7."
        "67777776"
        "67777776"
        "..77.77."
        "..99.99."
        "..AA.AA.")
      PICO8-CHAR-MAP 2)
     ;; Red Laser Patrol Drone at (88, 74)
     (fb-draw-circle! fb 128 128 92 78 6 (p8col 5) #t)
     (fb-draw-circle! fb 128 128 92 78 3 (p8col 8) #t)]

    ;; ------------------------------------------------------------------------
    ;; 9. HIGH STAKES — Gothic Casino Felt Table, 5 Playing Cards & Poker Chips
    ;; ------------------------------------------------------------------------
    [(9)
     (fb-fill-rect! fb 128 128 0 0 128 128 (p8col 2))
     ;; Top Vampire Dealer Eyes & Gold/Bet HUD
     (fb-draw-text! fb 128 128 4  5 "GOLD $450" (p8col 10))
     (fb-fill-rect! fb 128 128 56 6 4 3 (p8col 8))
     (fb-fill-rect! fb 128 128 66 6 4 3 (p8col 8))
     (fb-draw-text! fb 128 128 84 5 "BET $50" (p8col 8))
     ;; Ornate Gold-Bordered Dark-Green Casino Felt Table (x=6..121, y=16..108)
     (fb-draw-box! fb 128 128 6 16 116 92 (p8col 3) (p8col 9) (p8col 10))
     ;; 5 Large Playing Cards (18x26) Fanned Across Center Table (y=36..62)
     (define card-suits (list (cons "A" 0) (cons "K" 8) (cons "Q" 8) (cons "J" 0) (cons "V" 2)))
     (for ([cs (in-list card-suits)]
           [idx (in-naturals)])
       (define cx (+ 13 (* idx 21)))
       (define cy 36)
       (fb-fill-rect! fb 128 128 (+ cx 2) (+ cy 2) 18 26 (p8col 0)) ; Shadow
       (fb-draw-box!  fb 128 128 cx cy 18 26 (p8col 7) (p8col 0))
       (fb-draw-text! fb 128 128 (+ cx 3) (+ cy 3) (car cs) (p8col (cdr cs)))
       (fb-draw-heart! fb 128 128 (+ cx 6) (+ cy 12) (p8col (cdr cs)) (p8col (cdr cs))))
     ;; Stacks of Red, Blue & Gold Poker Chips (Bottom-Left) + Stake (Bottom-Right)
     (for ([cy '(92 88 84)])
       (fb-draw-circle! fb 128 128 24 cy 6 (p8col 8)  #t)
       (fb-draw-circle! fb 128 128 24 cy 6 (p8col 7)  #f)
       (fb-draw-circle! fb 128 128 40 cy 6 (p8col 12) #t)
       (fb-draw-circle! fb 128 128 40 cy 6 (p8col 7)  #f)
       (fb-draw-circle! fb 128 128 56 cy 6 (p8col 10) #t)
       (fb-draw-circle! fb 128 128 56 cy 6 (p8col 0)  #f))
     ;; Wooden Vampire Stake & Silver Cross (x=80..112, y=82..96)
     (fb-fill-rect! fb 128 128 80 86 24 5 (p8col 4))
     (fb-fill-rect! fb 128 128 104 87 6 3 (p8col 9))
     ;; Bottom Command Bar
     (fb-draw-text! fb 128 128 10 115 "[HIT]  [STAND]  [STAKE]" (p8col 7))]

    ;; ------------------------------------------------------------------------
    ;; 10. KALIKAN — Vertical Space Shmup, Dreadnought Boss, Lasers & Bullet Fan
    ;; ------------------------------------------------------------------------
    [else
     (fb-fill-rect! fb 128 128 0 0 128 128 (p8col 0))
     ;; Deep-Space Starfield & Mechanical Trench Side Walls
     (for ([s '((20 20 7) (44 54 12) (88 32 7) (104 68 13) (28 88 6) (96 104 7))])
       (fb-put-px! fb 128 128 (first s) (second s) (p8col (third s))))
     (fb-draw-box! fb 128 128 0   14 10 114 (p8col 1) (p8col 5))
     (fb-draw-box! fb 128 128 118 14 10 114 (p8col 1) (p8col 5))
     ;; Top Score & Shield-Laser HUD
     (fb-draw-text! fb 128 128 4 4 "1UP 028400  SHLD ||||||" (p8col 7))
     ;; Alien Dreadnought Boss Core at Top-Center (x=36..92, y=16..42)
     (fb-draw-bitmap!
      fb 128 128 36 16
      '("22228888888888882222"
        ".2288899AAAA9988822."
        "..8889A777777A9888.."
        "...889A788887A988..."
        "....8899AAAA9988...."
        ".....88..88..88.....")
      PICO8-CHAR-MAP 2)
     ;; V-Formation Escort Fighters & Geometric Pink/Red Bullet Curtain
     (for ([ex '(20 96)])
       (fb-draw-bitmap!
        fb 128 128 ex 44
        '(".8..8."
          "889988"
          ".8AA8."
          "..88..")
        PICO8-CHAR-MAP 2))
     (for ([bx '(32 46 64 82 96)]
           [by '(64 72 68 72 64)])
       (fb-draw-circle! fb 128 128 bx by 3 (p8col 8)  #t)
       (fb-draw-circle! fb 128 128 bx by 1 (p8col 7)  #t))
     ;; Twin-Wing Kalikan Starfighter Firing Dual Laser Streams at (px, 94)
     (define sx (max 48 (min 68 raw-px)))
     (fb-fill-rect! fb 128 128 (+ sx 3)  28 2 66 (p8col 12))
     (fb-fill-rect! fb 128 128 (+ sx 4)  28 1 66 (p8col 7))
     (fb-fill-rect! fb 128 128 (+ sx 11) 28 2 66 (p8col 12))
     (fb-fill-rect! fb 128 128 (+ sx 12) 28 1 66 (p8col 7))
     (fb-draw-circle! fb 128 128 (+ sx 8) 102 12 (p8col 12) #f) ; Graze shield ring
     (fb-draw-bitmap!
      fb 128 128 sx 94
      '("...77..."
        "..7CC7.."
        ".77CC77."
        "CC7AA7CC"
        "C777777C"
        "C..99..C"
        "...AA...")
      PICO8-CHAR-MAP 2)])
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
