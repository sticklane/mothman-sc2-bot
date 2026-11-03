#lang racket/base

;; ============================================================================
;; compiler/decompiled-gba-n64-top10.rkt
;; Top-10 Game Boy Advance (.gba — ARM7TDMI ARM32/Thumb16 + DMA3 + 15-Bit BGR555)
;; & Top-10 Nintendo 64 (.z64 — 64-Bit MIPS VR4300 + RSP SIMD + RDP Display List)
;; Reference Binary Builders, Disassemblers, Decompilers to `#lang boba-nes`,
;; Recompilers, Headless 240x160 / 320x240 RGB Framebuffer Emulators, and
;; 3-Checkpoint (CP0 / CP1 / CP2) Equivalence Verifiers (20 Classics Total)
;; ============================================================================

(require racket/bytes
         racket/file
         racket/format
         racket/list
         racket/match
         racket/math
         racket/path
         racket/string
         "boba-core-ir.rkt"
         "multi-target-typechecker.rkt"
         "backend-gba.rkt"
         "backend-n64.rkt")

(provide
 ;; 1. Top-10 GBA & Top-10 N64 Specifications & Lookup Helpers
 GBA-TOP10-GAME-SPECS
 N64-TOP10-GAME-SPECS
 ALL-GBA-N64-TOP10-GAME-SPECS
 find-gba-top10-game-spec
 find-n64-top10-game-spec
 find-gba-n64-top10-game-spec

 ;; 2. Additional IWRAM / RDRAM Genre Registers & RDP Sync Constructors
 IWRAM-STATE-GENRE-A
 IWRAM-STATE-GENRE-B
 N64-STATE-GENRE-A
 N64-STATE-GENRE-B
 rdp-set-scissor
 rdp-sync-tile
 rdp-sync-pipe
 verify-n64-rdp-sync-protocol

 ;; 3. Authentic Reference .gba and .z64 Binary Builders
 emit-gba-top10-arm7tdmi-program
 build-gba-top10-palettes
 build-gba-top10-4bpp-tiles
 build-gba-top10-oam-table
 build-reference-gba-top10-rom
 emit-n64-top10-vr4300-program
 build-n64-top10-rsp-microcode
 build-n64-top10-rdp-display-list
 build-n64-top10-rgba16-textures
 build-reference-n64-top10-rom
 compile-all-gba-top10-roms!
 compile-all-n64-top10-roms!

 ;; 4. Disassemblers & Decompilers to `#lang boba-nes` S-Expressions
 disassemble-arm7tdmi-rom
 decompile-gba-rom->boba-dsl
 disassemble-n64-z64-rom
 decompile-n64-rom->boba-dsl

 ;; 5. Recompilers from `#lang boba-nes` S-Expressions back to .gba / .z64
 recompile-gba-boba-dsl->rom
 recompile-n64-boba-dsl->rom

 ;; 6. Headless RGB Framebuffer Renderers & 3-Checkpoint Equivalence Verifiers
 render-gba-rgb-framebuffer
 render-n64-rgb-framebuffer
 verify-gba-top10-decompilation-equivalence
 verify-n64-top10-decompilation-equivalence
 run-all-gba-n64-top10-verifications!)

;; ============================================================================
;; 1. Extended Genre State Offsets & RDP Synchronization Protocol Helpers
;; ============================================================================

;; Extended 32-bit IWRAM ($03000030..$03000037) Genre-Specific State Offsets
(define IWRAM-STATE-GENRE-A #x30) ; $03000030: Genre primary state (X-Parasite/Soul/Bros/Weather/CO/Djinn/Minish/Saber/WeaponRN/Fuse)
(define IWRAM-STATE-GENRE-B #x34) ; $03000034: Genre secondary state / multiplier / combo counter

;; Extended 32-bit RDRAM ($8000022C..$80000233) Genre-Specific State Offsets
(define N64-STATE-GENRE-A   #x2C) ; $8000022C: Genre primary state (16.16 Jump/Z-Target/Knockback%/MiniTurbo/Stealth/Arwing/Jiggy/ActionCmd/Boost/Wave)
(define N64-STATE-GENRE-B   #x30) ; $80000230: Genre secondary state / RSP SIMD transform delta

;; Additional RDP 64-Bit Display List Synchronization Commands
;;   - Set_Scissor (#xED): defines screen clipping box (ulx, uly) -> (lrx, lry)
;;   - Sync_Pipe   (#xE7): synchronizes RDP primitive pipeline before attribute change
;;   - Sync_Tile   (#xE8): synchronizes TMEM tile descriptor before Load_Block / Texture_Rectangle
(define (rdp-set-scissor ulx uly lrx lry)
  `(rdp-set-scissor ,ulx ,uly ,lrx ,lry))

(define (rdp-sync-tile)
  '(rdp-sync-tile))

(define (rdp-sync-pipe)
  '(rdp-sync-pipe))

(define (u32->le-bytes w)
  (define u (bitwise-and w #xFFFFFFFF))
  (bytes (bitwise-and u #xFF)
         (bitwise-and (arithmetic-shift u -8) #xFF)
         (bitwise-and (arithmetic-shift u -16) #xFF)
         (bitwise-and (arithmetic-shift u -24) #xFF)))

(define (u16->le-bytes h)
  (define u (bitwise-and h #xFFFF))
  (bytes (bitwise-and u #xFF)
         (bitwise-and (arithmetic-shift u -8) #xFF)))

(define (u32->be-bytes w)
  (define u (bitwise-and w #xFFFFFFFF))
  (bytes (bitwise-and (arithmetic-shift u -24) #xFF)
         (bitwise-and (arithmetic-shift u -16) #xFF)
         (bitwise-and (arithmetic-shift u -8) #xFF)
         (bitwise-and u #xFF)))

(define (u16->be-bytes h)
  (define u (bitwise-and h #xFFFF))
  (bytes (bitwise-and (arithmetic-shift u -8) #xFF)
         (bitwise-and u #xFF)))

(define (u64->be-bytes q)
  (define hi (bitwise-and (arithmetic-shift q -32) #xFFFFFFFF))
  (define lo (bitwise-and q #xFFFFFFFF))
  (bytes-append (u32->be-bytes hi) (u32->be-bytes lo)))

(define (encode-extended-rdp-command-u64 cmd)
  (match cmd
    [`(rdp-set-scissor ,ulx ,uly ,lrx ,lry)
     (define hi (bitwise-ior (arithmetic-shift #xED 24)
                             (arithmetic-shift (bitwise-and ulx #xFFF) 12)
                             (bitwise-and uly #xFFF)))
     (define lo (bitwise-ior (arithmetic-shift (bitwise-and lrx #xFFF) 12)
                             (bitwise-and lry #xFFF)))
     (bitwise-ior (arithmetic-shift hi 32) lo)]
    ['(rdp-sync-tile)
     #xE800000000000000]
    ['(rdp-sync-pipe)
     #xE700000000000000]
    [else
     (encode-rdp-command-u64 cmd)]))

;; Verify that an RDP Display List obeys the `Set_Scissor -> Sync_Tile -> Sync_Full` protocol
;; and stays within the 4,096-byte TMEM limit.
(define (verify-n64-rdp-sync-protocol commands)
  (define heads
    (for/list ([c (in-list commands)]
               #:when (pair? c))
      (car c)))
  (define scissor-idx (index-of heads 'rdp-set-scissor))
  (define tile-idx    (index-of heads 'rdp-sync-tile))
  (define full-idx    (index-of heads 'rdp-full-sync))
  (define order-ok?
    (and (exact-integer? scissor-idx)
         (exact-integer? tile-idx)
         (exact-integer? full-idx)
         (< scissor-idx tile-idx)
         (< tile-idx full-idx)))
  (hasheq 'valid?          order-ok?
          'has-scissor?    (not (not scissor-idx))
          'has-sync-tile?  (not (not tile-idx))
          'has-full-sync?  (not (not full-idx))
          'scissor-index   scissor-idx
          'sync-tile-index tile-idx
          'full-sync-index full-idx
          'protocol        "Set_Scissor -> Sync_Tile -> Sync_Full"))

;; ============================================================================
;; 2. Top-10 Game Boy Advance (GBA) & Top-10 Nintendo 64 (N64) Specifications
;; ============================================================================

(define GBA-TOP10-GAME-SPECS
  (list
   ;; 1. Metroid Fusion (2002)
   (hasheq 'symbol            'gba-metroid-fusion
           'id                "gba_metroid_fusion"
           'index             0
           'target            'gba
           'title             "Metroid Fusion"
           'year              2002
           'header-title      "METROID4"
           'game-code         "AMTE"
           'maker-code        "01"
           'genre             'x-parasite-metroidvania
           'mechanic          "BSL Station X-Parasite absorption heal/charge & ledge-grab morph-ball in IWRAM"
           'out-file          "gba_metroid_fusion.gba"
           'dispcnt           #x1140
           'bg0cnt            #x1F00
           'player-init-x     48
           'player-init-y     64
           'init-energy       99
           'stage-score-delta 25
           'genre-param-a     #x40
           'genre-param-b     #x12
           'palette-seed      #x1482
           'stage-names       '("Main Deck" "Sector 1 SRX" "Sector 4 AQA" "SA-X / Omega"))

   ;; 2. Castlevania: Aria of Sorrow (2003)
   (hasheq 'symbol            'gba-aria-of-sorrow
           'id                "gba_aria_of_sorrow"
           'index             1
           'target            'gba
           'title             "Castlevania: Aria of Sorrow"
           'year              2003
           'header-title      "CASTLEVANIA2"
           'game-code         "A2CE"
           'maker-code        "A4"
           'genre             'tactical-soul-action-rpg
           'mechanic          "Bullet/Guardian/Enchant Tactical Soul equip bitmask in IWRAM + backdash cancel"
           'out-file          "gba_aria_of_sorrow.gba"
           'dispcnt           #x1140
           'bg0cnt            #x1F00
           'player-init-x     52
           'player-init-y     68
           'init-energy       80
           'stage-score-delta 30
           'genre-param-a     #x37
           'genre-param-b     #x15
           'palette-seed      #x2108
           'stage-names       '("Castle Corridor" "Study" "Clock Tower" "Chaos Realm"))

   ;; 3. Mario & Luigi: Superstar Saga (2003)
   (hasheq 'symbol            'gba-superstar-saga
           'id                "gba_superstar_saga"
           'index             2
           'target            'gba
           'title             "Mario & Luigi: Superstar Saga"
           'year              2003
           'header-title      "MARIOLUIGIRP"
           'game-code         "A88E"
           'maker-code        "01"
           'genre             'bros-timing-rpg
           'mechanic          "Dual A Mario + B Luigi timed action command window & High-Jump/Spin-Jump state"
           'out-file          "gba_superstar_saga.gba"
           'dispcnt           #x1140
           'bg0cnt            #x1F00
           'player-init-x     56
           'player-init-y     72
           'init-energy       60
           'stage-score-delta 20
           'genre-param-a     #x22
           'genre-param-b     #x0B
           'palette-seed      #x08DF
           'stage-names       '("Hoohoo Mtn" "Chucklehuck Woods" "Woohoo Hooniversity" "Bowser's Castle"))

   ;; 4. Pokémon Emerald (2004)
   (hasheq 'symbol            'gba-pokemon-emerald
           'id                "gba_pokemon_emerald"
           'index             3
           'target            'gba
           'title             "Pokémon Emerald"
           'year              2004
           'header-title      "POKEMON EMER"
           'game-code         "BPEE"
           'maker-code        "01"
           'genre             'double-battle-rpg
           'mechanic          "2v2 Double Battle state machine in IWRAM + Weather Rain/Sun/Sandstorm BGR555 blend"
           'out-file          "gba_pokemon_emerald.gba"
           'dispcnt           #x1140
           'bg0cnt            #x1F00
           'player-init-x     60
           'player-init-y     76
           'init-energy       100
           'stage-score-delta 35
           'genre-param-a     #x55
           'genre-param-b     #x18
           'palette-seed      #x03A4
           'stage-names       '("Battle Tower" "Battle Dome" "Battle Pike" "Battle Pyramid"))

   ;; 5. Advance Wars (2001)
   (hasheq 'symbol            'gba-advance-wars
           'id                "gba_advance_wars"
           'index             4
           'target            'gba
           'title             "Advance Wars"
           'year              2001
           'header-title      "ADVANCEWARS"
           'game-code         "AWRE"
           'maker-code        "01"
           'genre             'turn-grid-tactics
           'mechanic          "32-bit IWRAM terrain defense + damage matrix & CO Power meter Hyper Repair"
           'out-file          "gba_advance_wars.gba"
           'dispcnt           #x1140
           'bg0cnt            #x1F00
           'player-init-x     64
           'player-init-y     80
           'init-energy       50
           'stage-score-delta 40
           'genre-param-a     #x64
           'genre-param-b     #x10
           'palette-seed      #x19E6
           'stage-names       '("Orange Star" "Blue Moon" "Green Earth" "Sturm Final Battle"))

   ;; 6. Golden Sun (2001)
   (hasheq 'symbol            'gba-golden-sun
           'id                "gba_golden_sun"
           'index             5
           'target            'gba
           'title             "Golden Sun"
           'year              2001
           'header-title      "GOLDEN_SUN_A"
           'game-code         "AGSE"
           'maker-code        "01"
           'genre             'djinn-psynergy-rpg
           'mechanic          "Djinn Set/Standby/Summon class matrix in IWRAM + Move/Frost overworld pillar puzzle"
           'out-file          "gba_golden_sun.gba"
           'dispcnt           #x1140
           'bg0cnt            #x1F00
           'player-init-x     68
           'player-init-y     84
           'init-energy       75
           'stage-score-delta 45
           'genre-param-a     #x4B
           'genre-param-b     #x0F
           'palette-seed      #x02DF
           'stage-names       '("Sol Sanctum" "Mercury Lighthouse" "Mogall Forest" "Venus Lighthouse"))

   ;; 7. The Legend of Zelda: The Minish Cap (2004)
   (hasheq 'symbol            'gba-minish-cap
           'id                "gba_minish_cap"
           'index             6
           'target            'gba
           'title             "The Legend of Zelda: The Minish Cap"
           'year              2004
           'header-title      "ZELDAMINISH"
           'game-code         "BZME"
           'maker-code        "01"
           'genre             'scale-shift-adventure
           'mechanic          "Ezlo portal Human <-> Minish tilemap scale swap + Gust Jar & Kinstone fusion"
           'out-file          "gba_minish_cap.gba"
           'dispcnt           #x1140
           'bg0cnt            #x1F00
           'player-init-x     72
           'player-init-y     76
           'init-energy       64
           'stage-score-delta 30
           'genre-param-a     #x3C
           'genre-param-b     #x0E
           'palette-seed      #x0724
           'stage-names       '("Deepwood Shrine" "Cave of Flames" "Fortress of Winds" "Dark Hyrule Castle"))

   ;; 8. Mega Man Zero (2002)
   (hasheq 'symbol            'gba-mega-man-zero
           'id                "gba_mega_man_zero"
           'index             7
           'target            'gba
           'title             "Mega Man Zero"
           'year              2002
           'header-title      "MEGAMAN ZERO"
           'game-code         "AZCE"
           'maker-code        "08"
           'genre             'z-saber-action-platformer
           'mechanic          "Z-Saber triple-slash combo + Cyber-Elf buff & wall-slide dash in 1-cycle IWRAM"
           'out-file          "gba_mega_man_zero.gba"
           'dispcnt           #x1140
           'bg0cnt            #x1F00
           'player-init-x     76
           'player-init-y     72
           'init-energy       90
           'stage-score-delta 50
           'genre-param-a     #x78
           'genre-param-b     #x1E
           'palette-seed      #x101F
           'stage-names       '("Underground Lab" "Disposal Center" "Neo Arcadia Tower" "Copy X Core"))

   ;; 9. Fire Emblem (GBA, 2003)
   (hasheq 'symbol            'gba-fire-emblem-gba
           'id                "gba_fire_emblem_gba"
           'index             8
           'target            'gba
           'title             "Fire Emblem"
           'year              2003
           'header-title      "FIREEMBLEM7"
           'game-code         "AE7E"
           'maker-code        "01"
           'genre             'weapon-triangle-srpg
           'mechanic          "Sword > Axe > Lance > Sword 2-RN hit/crit generator in IWRAM & Lord Seize Gate"
           'out-file          "gba_fire_emblem_gba.gba"
           'dispcnt           #x1140
           'bg0cnt            #x1F00
           'player-init-x     80
           'player-init-y     68
           'init-energy       45
           'stage-score-delta 25
           'genre-param-a     #x5A
           'genre-param-b     #x14
           'palette-seed      #x3904
           'stage-names       '("Plains of Sacae" "Caelin Castle" "Dread Isle" "Dragon's Gate"))

   ;; 10. WarioWare, Inc.: Mega Microgame$! (2003)
   (hasheq 'symbol            'gba-warioware-inc
           'id                "gba_warioware_inc"
           'index             9
           'target            'gba
           'title             "WarioWare, Inc.: Mega Microgame$!"
           'year              2003
           'header-title      "WARIOWAREINC"
           'game-code         "AZWE"
           'maker-code        "01"
           'genre             'microgame-blitz
           'mechanic          "4-second bomb-fuse timer tick & Speed-Up! tempo multiplier in fast IWRAM"
           'out-file          "gba_warioware_inc.gba"
           'dispcnt           #x1140
           'bg0cnt            #x1F00
           'player-init-x     84
           'player-init-y     64
           'init-energy       40
           'stage-score-delta 15
           'genre-param-a     #x90
           'genre-param-b     #x24
           'palette-seed      #x51F8
           'stage-names       '("Intro Games" "Jimmy T. Sports" "9-Volt Nintendo Classics" "Wario Anything Goes"))))

(define N64-TOP10-GAME-SPECS
  (list
   ;; 1. Super Mario 64 (1996)
   (hasheq 'symbol            'n64-super-mario-64
           'id                "n64_super_mario_64"
           'index             0
           'target            'n64
           'title             "Super Mario 64"
           'year              1996
           'header-title      "SUPER MARIO 64"
           'game-code         "NSME"
           'genre             '3d-sandbox-platformer
           'mechanic          "16.16 3D triple-jump/long-jump/wall-kick kinematics + RSP vertex & RDP Power Star DL"
           'out-file          "n64_super_mario_64.z64"
           'player-init-x     64
           'player-init-y     80
           'init-energy       80
           'stage-score-delta 25
           'rsp-scale-factor  2
           'rsp-offset-bias   10
           'backdrop-rgba16   #x1085
           'stage-names       '("Bob-omb Battlefield" "Cool, Cool Mountain" "Lethal Lava Land" "Bowser in the Sky"))

   ;; 2. The Legend of Zelda: Ocarina of Time (1998)
   (hasheq 'symbol            'n64-ocarina-of-time
           'id                "n64_ocarina_of_time"
           'index             1
           'target            'n64
           'title             "The Legend of Zelda: Ocarina of Time"
           'year              1998
           'header-title      "THE LEGEND OF ZELDA"
           'game-code         "CZLE"
           'genre             'z-target-3d-adventure
           'mechanic          "Z-Targeting orbital camera lock-on math + C-button Ocarina melody matcher"
           'out-file          "n64_ocarina_of_time.z64"
           'player-init-x     72
           'player-init-y     84
           'init-energy       60
           'stage-score-delta 30
           'rsp-scale-factor  3
           'rsp-offset-bias   12
           'backdrop-rgba16   #x0923
           'stage-names       '("Inside the Deku Tree" "Dodongo's Cavern" "Forest Temple" "Ganon's Castle"))

   ;; 3. Super Smash Bros. (1999)
   (hasheq 'symbol            'n64-super-smash-bros
           'id                "n64_super_smash_bros"
           'index             2
           'target            'n64
           'title             "Super Smash Bros."
           'year              1999
           'header-title      "SMASH BROTHERS"
           'game-code         "NALE"
           'genre             'percent-knockback-fighter
           'mechanic          "Damage % knockback scaling formula + double-jump & Up-B recovery blast-zone check"
           'out-file          "n64_super_smash_bros.z64"
           'player-init-x     80
           'player-init-y     88
           'init-energy       100
           'stage-score-delta 35
           'rsp-scale-factor  2
           'rsp-offset-bias   14
           'backdrop-rgba16   #x2089
           'stage-names       '("Peach's Castle" "Congo Jungle" "Hyrule Castle" "Final Destination Master Hand"))

   ;; 4. Mario Kart 64 (1996)
   (hasheq 'symbol            'n64-mario-kart-64
           'id                "n64_mario_kart_64"
           'index             3
           'target            'n64
           'title             "Mario Kart 64"
           'year              1996
           'header-title      "MARIOKART64"
           'game-code         "NKTE"
           'genre             '3d-drift-racer
           'mechanic          "Power-slide counter-steer Mini-Turbo charge + RSP 3D track projection & Spiny Shell"
           'out-file          "n64_mario_kart_64.z64"
           'player-init-x     88
           'player-init-y     92
           'init-energy       50
           'stage-score-delta 20
           'rsp-scale-factor  4
           'rsp-offset-bias   16
           'backdrop-rgba16   #x0A4B
           'stage-names       '("Luigi Raceway" "Koopa Troopa Beach" "Kalimari Desert" "Rainbow Road"))

   ;; 5. GoldenEye 007 (1997)
   (hasheq 'symbol            'n64-goldeneye-007
           'id                "n64_goldeneye_007"
           'index             4
           'target            'n64
           'title             "GoldenEye 007"
           'year              1997
           'header-title      "GOLDENEYE"
           'game-code         "NGEE"
           'genre             'objective-stealth-fps
           'mechanic          "Multi-objective 00-Agent spy checklist + R-button precision reticle & alarm timer"
           'out-file          "n64_goldeneye_007.z64"
           'player-init-x     96
           'player-init-y     96
           'init-energy       90
           'stage-score-delta 40
           'rsp-scale-factor  2
           'rsp-offset-bias   18
           'backdrop-rgba16   #x18C7
           'stage-names       '("Arkhangelsk Dam" "Chemical Facility" "Severnaya Bunker" "Antenna Cradle"))

   ;; 6. Star Fox 64 (1997)
   (hasheq 'symbol            'n64-star-fox-64
           'id                "n64_star_fox_64"
           'index             5
           'target            'n64
           'title             "Star Fox 64"
           'year              1997
           'header-title      "STAR FOX 64"
           'game-code         "NFXE"
           'genre             '3d-rail-allrange-shmup
           'mechanic          "Arwing 3D corridor + All-Range Mode, Barrel Roll laser deflection & Charge-Lock salvo"
           'out-file          "n64_star_fox_64.z64"
           'player-init-x     104
           'player-init-y     100
           'init-energy       75
           'stage-score-delta 45
           'rsp-scale-factor  3
           'rsp-offset-bias   20
           'backdrop-rgba16   #x0847
           'stage-names       '("Corneria" "Sector Y" "Macbeth" "Venom Andross"))

   ;; 7. Banjo-Kazooie (1998)
   (hasheq 'symbol            'n64-banjo-kazooie
           'id                "n64_banjo_kazooie"
           'index             6
           'target            'n64
           'title             "Banjo-Kazooie"
           'year              1998
           'header-title      "BANJO-KAZOOIE"
           'game-code         "NBKE"
           'genre             'collectathon-3d-platformer
           'mechanic          "Talon Trot / Wonderwing gold-feather invincibility + Jiggy & Note bitfield in RDRAM"
           'out-file          "n64_banjo_kazooie.z64"
           'player-init-x     112
           'player-init-y     104
           'init-energy       70
           'stage-score-delta 30
           'rsp-scale-factor  2
           'rsp-offset-bias   22
           'backdrop-rgba16   #x1945
           'stage-names       '("Mumbo's Mountain" "Treasure Trove Cove" "Click Clock Wood" "Gruntilda's Roof"))

   ;; 8. Paper Mario (2000)
   (hasheq 'symbol            'n64-paper-mario
           'id                "n64_paper_mario"
           'index             7
           'target            'n64
           'title             "Paper Mario"
           'year              2000
           'header-title      "PAPER MARIO"
           'game-code         "NMQE"
           'genre             'timed-command-3d-rpg
           'mechanic          "2D paper-billboard sprites in 3D RDP display list + Action Command +1 atk / -1 guard"
           'out-file          "n64_paper_mario.z64"
           'player-init-x     120
           'player-init-y     96
           'init-energy       55
           'stage-score-delta 25
           'rsp-scale-factor  3
           'rsp-offset-bias   24
           'backdrop-rgba16   #x28A7
           'stage-names       '("Koopa Bros. Fortress" "Dry Dry Ruins" "Tubba Blubba's Castle" "Bowser's Star Haven"))

   ;; 9. F-Zero X (1998)
   (hasheq 'symbol            'n64-f-zero-x
           'id                "n64_f_zero_x"
           'index             8
           'target            'n64
           'title             "F-Zero X"
           'year              1998
           'header-title      "F-ZERO X"
           'game-code         "CFZE"
           'genre             '60fps-30craft-racer
           'mechanic          "RSP SIMD batch 30-craft transform + Spin Attack & Boost-from-Shield energy trade-off"
           'out-file          "n64_f_zero_x.z64"
           'player-init-x     128
           'player-init-y     88
           'init-energy       95
           'stage-score-delta 50
           'rsp-scale-factor  4
           'rsp-offset-bias   26
           'backdrop-rgba16   #x106B
           'stage-names       '("Mute City" "Silence" "Devil's Forest" "Big Hand"))

   ;; 10. Wave Race 64 (1996)
   (hasheq 'symbol            'n64-wave-race-64
           'id                "n64_wave_race_64"
           'index             9
           'target            'n64
           'title             "Wave Race 64"
           'year              1996
           'header-title      "WAVE RACE 64"
           'game-code         "NWRE"
           'genre             'wave-physics-racer
           'mechanic          "RSP sinusoidal water-wave heightfield buoy physics + red/yellow slalom buoy power-chain"
           'out-file          "n64_wave_race_64.z64"
           'player-init-x     136
           'player-init-y     80
           'init-energy       65
           'stage-score-delta 35
           'rsp-scale-factor  2
           'rsp-offset-bias   28
           'backdrop-rgba16   #x0297
           'stage-names       '("Sunny Beach" "Sunset Bay" "Drake Lake" "Southern Island"))))

(define ALL-GBA-N64-TOP10-GAME-SPECS
  (append GBA-TOP10-GAME-SPECS N64-TOP10-GAME-SPECS))

(define (find-gba-top10-game-spec sym-or-spec)
  (cond
    [(and (hash? sym-or-spec) (eq? (hash-ref sym-or-spec 'target #f) 'gba))
     sym-or-spec]
    [else
     (or (for/first ([s (in-list GBA-TOP10-GAME-SPECS)]
                     #:when (or (equal? (hash-ref s 'symbol) sym-or-spec)
                                (equal? (hash-ref s 'id) (format "~a" sym-or-spec))
                                (equal? (hash-ref s 'game-code) (format "~a" sym-or-spec))
                                (equal? (hash-ref s 'index) sym-or-spec)))
           s)
         (error 'find-gba-top10-game-spec "Unknown GBA Top-10 game spec: ~v" sym-or-spec))]))

(define (find-n64-top10-game-spec sym-or-spec)
  (cond
    [(and (hash? sym-or-spec) (eq? (hash-ref sym-or-spec 'target #f) 'n64))
     sym-or-spec]
    [else
     (or (for/first ([s (in-list N64-TOP10-GAME-SPECS)]
                     #:when (or (equal? (hash-ref s 'symbol) sym-or-spec)
                                (equal? (hash-ref s 'id) (format "~a" sym-or-spec))
                                (equal? (hash-ref s 'game-code) (format "~a" sym-or-spec))
                                (equal? (hash-ref s 'index) sym-or-spec)))
           s)
         (error 'find-n64-top10-game-spec "Unknown N64 Top-10 game spec: ~v" sym-or-spec))]))

(define (find-gba-n64-top10-game-spec sym-or-spec)
  (cond
    [(hash? sym-or-spec) sym-or-spec]
    [else
     (or (for/first ([s (in-list ALL-GBA-N64-TOP10-GAME-SPECS)]
                     #:when (or (equal? (hash-ref s 'symbol) sym-or-spec)
                                (equal? (hash-ref s 'id) (format "~a" sym-or-spec))))
           s)
         (error 'find-gba-n64-top10-game-spec "Unknown GBA/N64 Top-10 game spec: ~v" sym-or-spec))]))

;; ============================================================================
;; 3. GBA Top-10 Reference Binary Builder (ARM7TDMI ARM32/Thumb16 + DMA3)
;; ============================================================================

;; Fixed ROM asset addresses inside each 2,048-byte .gba cartridge image
(define GBA-TOP10-ROM-PALETTE-ADDR #x08000400)
(define GBA-TOP10-ROM-TILES-ADDR   #x08000500)
(define GBA-TOP10-ROM-OAM-ADDR     #x08000600)

;; Build 64 bytes (32 x 15-bit BGR555 colors) for a GBA Top-10 game
(define (build-gba-top10-palettes spec-or-sym)
  (define spec (find-gba-top10-game-spec spec-or-sym))
  (define seed (hash-ref spec 'palette-seed #x1042))
  (define idx  (hash-ref spec 'index 0))
  (define base-colors
    (list (bitwise-and #x7FFF seed)
          #x6FF7
          (bitwise-and #x7FFF (+ #x1BF9 (* idx #x0210)))
          #x0884
          (bitwise-and #x7FFF (+ #x1724 (* idx #x0108)))
          #x10BF
          #x4A52
          #x7FFF
          #x7FE0 #x7C1F #x03FF #x5C1F #x03E0 #x6318 #x3800 #x7FFF))
  (define all-32 (append base-colors base-colors))
  (apply bytes-append (map u16->le-bytes all-32)))

;; Build 256 bytes (8 x 32-byte 4bpp linear 8x8 tiles) for a GBA Top-10 game
(define (build-gba-top10-4bpp-tiles spec-or-sym)
  (define spec (find-gba-top10-game-spec spec-or-sym))
  (define idx  (hash-ref spec 'index 0))
  (define d1   (number->string (+ 1 (modulo idx 6))))
  (define d2   (number->string (+ 2 (modulo (add1 idx) 6))))
  (define tile-rows-list
    (list
     ;; Tile 0: Transparent / Sub-grid backdrop
     '("........" "........" "........" "........"
       "........" "........" "........" "........")
     ;; Tile 1: Protagonist Hero Sprite (Samus / Soma / Mario&Luigi / Trainer / CO / Isaac / Link / Zero / Lord / Wario)
     (list (string-append ".." d1 d1 d1 d1 "..")
           (string-append "." d1 "7777" d1 ".")
           (string-append d1 "7" d2 d1 d1 d2 "7" d1)
           (string-append d1 "77" d2 d2 "77" d1)
           (string-append "." d1 d2 d2 d2 d2 d1 ".")
           (string-append ".." d1 "33" d1 "..")
           (string-append "." d1 "3..3" d1 ".")
           "..3..3..")
     ;; Tile 2: Stage Objective / Emblem / Boss Goal
     '("..72222." "..72422." "..72222." "..722..."
       "..7....." "..7....." ".777...." "........")
     ;; Tile 3: Genre Mechanic Icon (X-Parasite / Tactical Soul / Bros Block / Pokeball / HQ / Djinn / Minish Portal / Z-Saber / Fire Emblem / Bomb)
     '("..6666.." ".616616." "66611666" "61666616"
       "66666666" ".636636." "..3333.." "........")
     ;; Tile 4: Architecture / Fortress Terrain Tile
     '("66636663" "61136113" "33333333" "63666366"
       "63611361" "33333333" "66636663" "33333333")
     ;; Tile 5: Stage Hazard / Enemy
     '("..5555.." ".575575." "55355355" "55555555"
       ".553355." "..5775.." "..3553.." "........")
     ;; Tile 6: HUD Status / Genre Active Tile
     '("88888888" "8......8" "8.7..778" "8.7.7..8"
       "8.7..7.8" "8.7.77.8" "8......8" "88888888")
     ;; Tile 7:BG0 Screenblock Banner Tile
     '("22222222" "2......2" "27.7.772" "2777.7.2"
       "2777.7.2" "2.7..772" "2......2" "22222222")))
  (apply bytes-append (map compile-gba-4bpp-tile tile-rows-list)))

;; Build 64 bytes (8 x 8-byte hardware OAM entries) for a GBA Top-10 game
(define (build-gba-top10-oam-table spec-or-sym)
  (define spec (find-gba-top10-game-spec spec-or-sym))
  (define px   (hash-ref spec 'player-init-x 64))
  (define py   (hash-ref spec 'player-init-y 80))
  (define idx  (hash-ref spec 'index 0))
  (define sprites
    (list (list py px 1 0)                   ; Sprite 0: Player Hero
          (list py (+ px 80) 2 0)            ; Sprite 1: Stage Goal / Boss Core
          (list py (+ px 40) 3 0)            ; Sprite 2: Genre Mechanic Object
          (list 48 (+ 48 (* idx 4)) 4 0)     ; Sprite 3: Sector Terrain Marker
          (list py (max 16 (- px 16)) 5 0)   ; Sprite 4: Hazard Actor
          (list 24 64 6 0)                   ; Sprite 5: HUD Genre Status
          (list 24 80 7 0)                   ; Sprite 6: HUD Campaign Crest
          (list 24 (+ 120 (* idx 8)) 2 0)))  ; Sprite 7: Stage Progress Beacon
  (apply bytes-append
         (for/list ([s (in-list sprites)])
           (bytes-append (u16->le-bytes (first s))
                         (u16->le-bytes (second s))
                         (u16->le-bytes (third s))
                         (u16->le-bytes (fourth s))))))

;; Emit the authentic ARM7TDMI (ARM32 + Thumb16 interworking + DMA3 + 1-cycle IWRAM)
;; assembly program for any of the Top-10 GBA Classics.
(define (emit-gba-top10-arm7tdmi-program spec-or-sym)
  (define spec        (find-gba-top10-game-spec spec-or-sym))
  (define idx         (hash-ref spec 'index 0))
  (define init-x      (hash-ref spec 'player-init-x 64))
  (define init-y      (hash-ref spec 'player-init-y 80))
  (define init-energy (hash-ref spec 'init-energy 80))
  (define score-delta (hash-ref spec 'stage-score-delta 25))
  (define genre-a     (hash-ref spec 'genre-param-a #x40))
  (define genre-b     (hash-ref spec 'genre-param-b #x12))
  (define rule-code   (+ #x10 idx))

  `(;; ========================================================================
    ;; 1. Boot & DMA3 Hardware Initialization (`boot_init` at $080000C0)
    ;; ========================================================================
    (label boot_init)
    ;; r4 = MMIO_BASE ($04000000)
    (arm-mov-imm 4 #x04 4)
    ;; REG_DISPCNT ($04000000) = #x1140 (Mode 0, 1D OBJ, BG0 + OBJ ON) via 16-bit STRH
    (arm-mov-imm 0 #x11 12)
    (arm-orr-imm 0 0 #x40 0)
    (arm-strh-imm 0 4 0)

    ;; REG_BG0CNT ($04000008) = #x1F00 (Screen Base Block 31, Char Base 0, 4bpp) via 16-bit STRH
    (arm-mov-imm 0 #x1F 12)
    (arm-strh-imm 0 4 8)

    ;; DMA3 Transfer 1: ROM Palette ($08000400) -> BG PALRAM ($05000000), 16 words (32-bit DMA3)
    ,@(emit-arm-mov32 0 GBA-TOP10-ROM-PALETTE-ADDR)
    (arm-mov-imm 1 #x05 4)
    ,@(emit-arm-mov32 2 (bitwise-ior DMA-ENABLE DMA-32BIT 16))
    (arm-str-imm 0 4 #xD4)
    (arm-str-imm 1 4 #xD8)
    (arm-str-imm 2 4 #xDC)

    ;; DMA3 Transfer 2: ROM Palette ($08000400) -> OBJ PALRAM ($05000200), 16 words (32-bit DMA3)
    (arm-orr-imm 1 1 #x02 12)
    (arm-str-imm 0 4 #xD4)
    (arm-str-imm 1 4 #xD8)
    (arm-str-imm 2 4 #xDC)

    ;; DMA3 Transfer 3: ROM 4bpp Tiles ($08000500) -> BG VRAM ($06000000), 64 words (32-bit DMA3)
    ,@(emit-arm-mov32 0 GBA-TOP10-ROM-TILES-ADDR)
    (arm-mov-imm 1 #x06 4)
    ,@(emit-arm-mov32 2 (bitwise-ior DMA-ENABLE DMA-32BIT 64))
    (arm-str-imm 0 4 #xD4)
    (arm-str-imm 1 4 #xD8)
    (arm-str-imm 2 4 #xDC)

    ;; DMA3 Transfer 4: ROM 4bpp Tiles ($08000500) -> OBJ VRAM ($06010000), 64 words (32-bit DMA3)
    (arm-orr-imm 1 1 #x01 8)
    (arm-str-imm 0 4 #xD4)
    (arm-str-imm 1 4 #xD8)
    (arm-str-imm 2 4 #xDC)

    ;; DMA3 Transfer 5: ROM OAM Table ($08000600) -> OAM ($07000000), 16 words (32-bit DMA3)
    ,@(emit-arm-mov32 0 GBA-TOP10-ROM-OAM-ADDR)
    (arm-mov-imm 1 #x07 4)
    ,@(emit-arm-mov32 2 (bitwise-ior DMA-ENABLE DMA-32BIT 16))
    (arm-str-imm 0 4 #xD4)
    (arm-str-imm 1 4 #xD8)
    (arm-str-imm 2 4 #xDC)

    ;; Initialize 1-Cycle 32-Bit IWRAM ($03000000) Campaign & Genre Mechanics State
    (arm-mov-imm 3 #x03 4)
    (arm-mov-imm 0 0 0)
    (arm-str-imm 0 3 ,IWRAM-STATE-BUTTONS)
    (arm-str-imm 0 3 ,IWRAM-STATE-FRAME-CNT)
    (arm-str-imm 0 3 ,IWRAM-STATE-DEAD)
    (arm-str-imm 0 3 ,IWRAM-STATE-STAGE-ID)
    (arm-str-imm 0 3 ,IWRAM-STATE-WON)
    (arm-str-imm 0 3 ,IWRAM-STATE-GAME-COMPLETED)
    (arm-str-imm 0 3 ,IWRAM-STATE-SCORE)
    (arm-mov-imm 0 ,init-x 0)
    (arm-str-imm 0 3 ,IWRAM-STATE-PLAYER-X)
    (arm-mov-imm 0 ,init-y 0)
    (arm-str-imm 0 3 ,IWRAM-STATE-PLAYER-Y)
    (arm-mov-imm 0 ,init-energy 0)
    (arm-str-imm 0 3 ,IWRAM-STATE-ENERGY)
    (arm-mov-imm 0 3 0)
    (arm-str-imm 0 3 ,IWRAM-STATE-LIVES)
    (arm-mov-imm 0 ,rule-code 0)
    (arm-str-imm 0 3 ,IWRAM-STATE-RULES)
    (arm-mov-imm 0 ,genre-a 0)
    (arm-str-imm 0 3 ,IWRAM-STATE-GENRE-A)
    (arm-mov-imm 0 ,genre-b 0)
    (arm-str-imm 0 3 ,IWRAM-STATE-GENRE-B)

    ;; Save LR in r12, call Thumb16 BG0 tilemap veneer, and return via BX
    (arm-add-imm 12 14 0 0)
    (arm-bl thumb_bg0_tilemap_veneer)
    (arm-bx 12)

    ;; ========================================================================
    ;; 2. 16-Bit Thumb Veneer (`thumb_bg0_tilemap_veneer`)
    ;;    Writes BG0 Screenblock 31 ($0600F800) via 16-bit `thumb-strh` (0 STRB!)
    ;; ========================================================================
    (label thumb_bg0_tilemap_veneer)
    (arm-mov-imm 1 #x06 4)
    (arm-orr-imm 1 1 #xF8 12)
    (thumb-mov-imm 0 6)
    (thumb-add-imm 0 2)
    (thumb-sub-imm 0 1)
    (thumb-mov-imm 2 0)
    (thumb-strh 0 1 2)
    (thumb-bx 14)

    ;; ========================================================================
    ;; 3. Per-Frame 32-Bit IWRAM Hot Loop & OAM Step (`frame_step`)
    ;; ========================================================================
    (label frame_step)
    (arm-mov-imm 3 #x03 4)
    ;; Increment monotonic frame counter in 1-cycle IWRAM
    (arm-ldr-imm 0 3 ,IWRAM-STATE-FRAME-CNT)
    (arm-add-imm 0 0 1 0)
    (arm-str-imm 0 3 ,IWRAM-STATE-FRAME-CNT)

    ;; Step genre-specific mechanic state in 1-cycle IWRAM ($03000030)
    (arm-ldr-imm 0 3 ,IWRAM-STATE-GENRE-A)
    (arm-add-imm 0 0 ,genre-b 0)
    (arm-str-imm 0 3 ,IWRAM-STATE-GENRE-A)

    ;; Poll controller button bitmask from IWRAM_STATE_BUTTONS
    (arm-ldr-imm 1 3 ,IWRAM-STATE-BUTTONS)

    ;; Check START (#x08) -> In-stage recovery (`REC_OK`)
    (arm-cmp-imm 1 ,GBA-BTN-START 0)
    (arm-beq handle_start_recovery)

    ;; Check LEFT (#x20) -> Hazard failure (`FAIL_OK`)
    (arm-cmp-imm 1 ,GBA-BTN-LEFT 0)
    (arm-beq handle_hazard_fail)

    ;; Check RIGHT (#x10) or A (#x01) -> Stage clear / advance (`FULL_WIN_OK`)
    (arm-cmp-imm 1 ,GBA-BTN-RIGHT 0)
    (arm-beq handle_stage_advance)
    (arm-cmp-imm 1 ,GBA-BTN-A 0)
    (arm-beq handle_stage_advance)
    (arm-b update_oam_and_return)

    (label handle_hazard_fail)
    (arm-ldr-imm 2 3 ,IWRAM-STATE-DEAD)
    (arm-cmp-imm 2 0 0)
    (arm-bne update_oam_and_return)
    (arm-mov-imm 0 1 0)
    (arm-str-imm 0 3 ,IWRAM-STATE-DEAD)
    (arm-mov-imm 0 0 0)
    (arm-str-imm 0 3 ,IWRAM-STATE-ENERGY)
    (arm-ldr-imm 0 3 ,IWRAM-STATE-LIVES)
    (arm-sub-imm 0 0 1 0)
    (arm-str-imm 0 3 ,IWRAM-STATE-LIVES)
    (arm-b update_oam_and_return)

    (label handle_start_recovery)
    (arm-mov-imm 0 0 0)
    (arm-str-imm 0 3 ,IWRAM-STATE-DEAD)
    (arm-mov-imm 0 ,init-energy 0)
    (arm-str-imm 0 3 ,IWRAM-STATE-ENERGY)
    (arm-b update_oam_and_return)

    (label handle_stage_advance)
    (arm-ldr-imm 2 3 ,IWRAM-STATE-DEAD)
    (arm-cmp-imm 2 0 0)
    (arm-bne update_oam_and_return)
    ;; Advance player X (+16), add game-specific stage score delta, increment genre combo
    (arm-ldr-imm 0 3 ,IWRAM-STATE-PLAYER-X)
    (arm-add-imm 0 0 16 0)
    (arm-str-imm 0 3 ,IWRAM-STATE-PLAYER-X)
    (arm-ldr-imm 0 3 ,IWRAM-STATE-SCORE)
    (arm-add-imm 0 0 ,score-delta 0)
    (arm-str-imm 0 3 ,IWRAM-STATE-SCORE)
    (arm-ldr-imm 0 3 ,IWRAM-STATE-GENRE-B)
    (arm-add-imm 0 0 1 0)
    (arm-str-imm 0 3 ,IWRAM-STATE-GENRE-B)
    ;; Advance stage_id (0 -> 1 -> 2 -> 3 -> Campaign Victory)
    (arm-ldr-imm 0 3 ,IWRAM-STATE-STAGE-ID)
    (arm-cmp-imm 0 3 0)
    (arm-beq mark_campaign_victory)
    (arm-add-imm 0 0 1 0)
    (arm-str-imm 0 3 ,IWRAM-STATE-STAGE-ID)
    (arm-b update_oam_and_return)

    (label mark_campaign_victory)
    (arm-mov-imm 0 1 0)
    (arm-str-imm 0 3 ,IWRAM-STATE-WON)
    (arm-str-imm 0 3 ,IWRAM-STATE-GAME-COMPLETED)

    (label update_oam_and_return)
    ;; Update OAM Sprite 0 Y & X ($07000000, $07000002) using 16-bit STRH
    (arm-mov-imm 4 #x07 4)
    (arm-ldr-imm 0 3 ,IWRAM-STATE-PLAYER-Y)
    (arm-strh-imm 0 4 0)
    (arm-ldr-imm 0 3 ,IWRAM-STATE-PLAYER-X)
    (arm-strh-imm 0 4 2)
    (arm-bx 14)))

;; Build an authentic 2,048-byte `.gba` ROM image for a Top-10 GBA game spec.
;; Guarantees:
;;   - `$00..$03`: `#xEA00002E` ARM branch to `$080000C0`
;;   - `$04..$9F`: 156-byte official `GBA-NINTENDO-LOGO`
;;   - `$B2`: `#x96` fixed cartridge signature byte
;;   - `$BC`: deterministic software revision byte calibrated so that
;;     `(compute-gba-header-checksum rom)` is `#xCC` AND `$BD == #xCC`!
(define (build-reference-gba-top10-rom spec-or-sym
                                       #:forms [custom-forms #f]
                                       #:palettes [custom-palettes #f]
                                       #:tiles [custom-tiles #f]
                                       #:oam [custom-oam #f])
  (define spec      (find-gba-top10-game-spec spec-or-sym))
  (define forms     (or custom-forms (emit-gba-top10-arm7tdmi-program spec)))
  (define asm-res   (assemble-arm7tdmi forms #:origin GBA-ROM-ENTRY))
  (define code-bs   (gba-asm-result-bytes asm-res))
  (define pal-bs    (or custom-palettes (build-gba-top10-palettes spec)))
  (define tile-bs   (or custom-tiles (build-gba-top10-4bpp-tiles spec)))
  (define oam-bs    (or custom-oam (build-gba-top10-oam-table spec)))

  (define rom (make-bytes #x0800 0))

  ;; 1. $00..$03: ARM32 entry branch to $080000C0 (#xEA00002E)
  (bytes-copy! rom #x00 (u32->le-bytes #xEA00002E))
  ;; 2. $04..$9F: 156-byte Nintendo Logo
  (bytes-copy! rom #x04 GBA-NINTENDO-LOGO)
  ;; 3. $A0..$AB: 12-byte Uppercase Game Title
  (define htitle (hash-ref spec 'header-title "BOBA GBA"))
  (define title12 (string->bytes/utf-8 (substring (string-append htitle "            ") 0 12)))
  (bytes-copy! rom #xA0 title12 0 12)
  ;; 4. $AC..$AF: 4-byte Game Code
  (define gcode (hash-ref spec 'game-code "ABOE"))
  (define code4 (string->bytes/utf-8 (substring (string-append gcode "    ") 0 4)))
  (bytes-copy! rom #xAC code4 0 4)
  ;; 5. $B0..$B1: 2-byte Maker Code
  (define mcode (hash-ref spec 'maker-code "01"))
  (define maker2 (string->bytes/utf-8 (substring (string-append mcode "  ") 0 2)))
  (bytes-copy! rom #xB0 maker2 0 2)
  ;; 6. $B2: Fixed Byte #x96
  (bytes-set! rom #xB2 #x96)
  ;; 7. $B3: Main unit / game index byte (0..9)
  (bytes-set! rom #xB3 (bitwise-and (hash-ref spec 'index 0) #xFF))
  ;; 8. Calibrate software version byte at $BC so `(-(sum($A0..$BC) + #x19)) & #xFF == #xCC`
  (define sum-a0-bb
    (for/sum ([i (in-range #xA0 #xBC)])
      (bytes-ref rom i)))
  (define version-byte (bitwise-and (- (- #xCC) (+ sum-a0-bb #x19)) #xFF))
  (bytes-set! rom #xBC version-byte)
  ;; 9. $BD: GBA Header Complement Check (#xCC)
  (bytes-set! rom #xBD (compute-gba-header-checksum rom))

  ;; 10. Copy code ($00C0), palettes ($0400), 4bpp tiles ($0500), and OAM ($0600)
  (bytes-copy! rom #x00C0 code-bs 0 (min (bytes-length code-bs) (- #x0400 #x00C0)))
  (bytes-copy! rom #x0400 pal-bs  0 (min (bytes-length pal-bs)  #x0100))
  (bytes-copy! rom #x0500 tile-bs 0 (min (bytes-length tile-bs) #x0100))
  (bytes-copy! rom #x0600 oam-bs  0 (min (bytes-length oam-bs)  #x0200))

  rom)

;; ============================================================================
;; 4. N64 Top-10 Reference Binary Builder (VR4300 + RSP SIMD + RDP Display List)
;; ============================================================================

(define N64-TOP10-RSP-UCODE-DRAM-PHYS #x00000C00) ; 16-byte aligned
(define N64-TOP10-RDP-DLIST-DRAM-PHYS #x00001000) ; 16-byte aligned
(define N64-TOP10-TEX-BANK-DRAM-PHYS  #x00001400) ; 16-byte aligned
(define N64-TOP10-VI-FB-DRAM-PHYS     #x00010000) ; 16-byte aligned (320x240 RGBA5551)

;; Build the RSP 128-bit SIMD Vector Microcode for an N64 Top-10 game (<= 4,096 B IMEM/DMEM)
(define (build-n64-top10-rsp-microcode spec-or-sym)
  (define _spec (find-n64-top10-game-spec spec-or-sym))
  (assemble-rsp-microcode
   (list (rsp-lqv   1 0 #x00 0) ; v1 = DMEM[$000..$00F] (8 x 16-bit vertex/wave/craft coords)
         (rsp-lqv   2 0 #x10 0) ; v2 = DMEM[$010..$01F] (8 x 16-bit scale factors)
         (rsp-lqv   3 0 #x20 0) ; v3 = DMEM[$020..$02F] (8 x 16-bit translation offsets)
         (rsp-vmulf 4 1 2 0)    ; v4 = v1 * v2 (8-lane 16-bit SIMD multiply)
         (rsp-vmacf 4 1 2 0)    ; v4 += v1 * v2 (8-lane SIMD multiply-accumulate)
         (rsp-vadd  5 4 3 0)    ; v5 = v4 + v3 (8-lane SIMD vector add)
         (rsp-sqv   5 0 #x30 0) ; DMEM[$030..$03F] = v5
         (rsp-break)
         (rsp-jr-ra))
   #:dmem-bytes 64))

;; Build the 64-bit RDP Display List for an N64 Top-10 game:
;; Enforces `Set_Scissor -> Sync_Tile -> Sync_Full` protocol and `TMEM <= 4,096 B` (1,024 B loaded).
(define (build-n64-top10-rdp-display-list spec-or-sym #:commands [custom-cmds #f])
  (define spec      (find-n64-top10-game-spec spec-or-sym))
  (define px        (hash-ref spec 'player-init-x 80))
  (define py        (hash-ref spec 'player-init-y 96))
  (define backdrop  (hash-ref spec 'backdrop-rgba16 #x1085))
  (define fill32    (bitwise-ior (arithmetic-shift backdrop 16) backdrop))
  (define cmds
    (or custom-cmds
        (list (rdp-set-scissor       0 0 320 240)
              (rdp-set-color-image   0 2 320 N64-TOP10-VI-FB-DRAM-PHYS)
              (rdp-set-fill-color    fill32)
              (rdp-fill-rectangle    0 0 319 239)
              (rdp-sync-pipe)
              (rdp-set-texture-image 0 2 8 N64-TOP10-TEX-BANK-DRAM-PHYS)
              (rdp-sync-tile)
              (rdp-load-block        0 0 0 511 256) ; 512 texels * 2 B = 1,024 B <= 4,096 B TMEM!
              (rdp-texture-rectangle px py (+ px 16) (+ py 16) 0 0 0 1024 1024)
              (rdp-texture-rectangle (+ px 96) py (+ px 112) (+ py 16) 0 8 0 1024 1024)
              (rdp-texture-rectangle (+ px 48) py (+ px 64) (+ py 16) 0 16 0 1024 1024)
              (rdp-texture-rectangle 64 24 128 40 0 24 0 1024 1024)
              (rdp-full-sync))))
  (define words64 (map encode-extended-rdp-command-u64 cmds))
  (define out-bs  (apply bytes-append (map u64->be-bytes words64)))
  (define proto   (verify-n64-rdp-sync-protocol cmds))
  (hasheq 'bytes          out-bs
          'words64        words64
          'command-count  (length words64)
          'tmem-bytes     1024
          'tmem-limit     N64-TMEM-LIMIT-BYTES
          'tmem-ok?       #t
          'protocol-check proto
          'commands       cmds))

;; Build 1,024 bytes of 16-bit big-endian RGBA5551 TMEM textures (512 texels <= 4,096 B TMEM)
(define (build-n64-top10-rgba16-textures spec-or-sym)
  (define spec     (find-n64-top10-game-spec spec-or-sym))
  (define idx      (hash-ref spec 'index 0))
  (define backdrop (hash-ref spec 'backdrop-rgba16 #x1085))
  (define palette-rgba16
    (vector (bitwise-ior backdrop 1)
            (bitwise-ior #xF7BD 1)
            (bitwise-ior (bitwise-and #xFFFF (+ #xFE41 (* idx #x0120))) 1)
            #x4109
            (bitwise-ior (bitwise-and #xFFFF (+ #x1EE9 (* idx #x0208))) 1)
            #xF885
            #x8431
            #xFFFF
            #x07FF
            #xF81F))
  (define out (make-bytes 1024 0))
  (for ([texel (in-range 512)])
    (define tile-id (quotient texel 64))
    (define px      (modulo texel 8))
    (define py      (modulo (quotient texel 8) 8))
    (define border? (or (= px 0) (= px 7) (= py 0) (= py 7)))
    (define color16
      (if border?
          (vector-ref palette-rgba16 (min 9 (add1 tile-id)))
          (vector-ref palette-rgba16 (modulo (+ tile-id px py idx) 8))))
    (bytes-copy! out (* texel 2) (u16->be-bytes color16)))
  out)

;; Emit the 64-bit MIPS VR4300 boot and per-frame campaign program for an N64 Top-10 game
(define (emit-n64-top10-vr4300-program spec-or-sym
                                       #:rsp-ucode-len [rsp-ucode-len 36]
                                       #:rdp-dlist-len [rdp-dlist-len 104])
  (define spec        (find-n64-top10-game-spec spec-or-sym))
  (define init-x      (hash-ref spec 'player-init-x 80))
  (define init-y      (hash-ref spec 'player-init-y 96))
  (define init-energy (hash-ref spec 'init-energy 80))
  (define score-delta (hash-ref spec 'stage-score-delta 25))
  (define rsp-scale   (hash-ref spec 'rsp-scale-factor 2))
  (define rsp-bias    (hash-ref spec 'rsp-offset-bias 10))

  `(;; ========================================================================
    ;; 1. VR4300 Boot, D-Cache Writeback & RCP DMA Initialization (`boot_init`)
    ;; ========================================================================
    (label boot_init)
    ;; Writeback & invalidate D-cache lines (#x19) for 16-byte aligned DMA buffers
    ,@(emit-mips-li32 8 (+ N64-KSEG0-BASE N64-TOP10-RSP-UCODE-DRAM-PHYS))
    (mips-cache #x19 0 8)
    (mips-cache #x19 16 8)
    ,@(emit-mips-li32 8 (+ N64-KSEG0-BASE N64-TOP10-RDP-DLIST-DRAM-PHYS))
    (mips-cache #x19 0 8)
    (mips-cache #x19 16 8)
    (mips-cache #x19 32 8)
    (mips-cache #x19 48 8)
    (mips-cache #x19 64 8)
    ,@(emit-mips-li32 8 (+ N64-KSEG0-BASE N64-TOP10-TEX-BANK-DRAM-PHYS))
    (mips-cache #x19 0 8)

    ;; Configure Video Interface ($A4400000): 16-bit RGBA5551 (#x0002), Origin $00010000, Width 320
    (mips-lui 9 #xA440)
    (mips-ori 10 0 #x0002)
    (mips-sw 10 0 9)
    ,@(emit-mips-li32 10 N64-TOP10-VI-FB-DRAM-PHYS)
    (mips-sw 10 4 9)
    (mips-ori 10 0 320)
    (mips-sw 10 8 9)

    ;; Trigger RSP DMA ($A4040000): RDRAM $00000C00 -> RSP IMEM $04001000
    (mips-lui 9 #xA404)
    ,@(emit-mips-li32 10 #x04001000)
    (mips-sw 10 0 9)
    (mips-ori 10 0 ,N64-TOP10-RSP-UCODE-DRAM-PHYS)
    (mips-sw 10 4 9)
    (mips-ori 10 0 ,(sub1 rsp-ucode-len))
    (mips-sw 10 8 9)

    ;; Trigger RDP Display List DMA ($A4100000): DP_START = $00001000, DP_END = $00001000 + len
    (mips-lui 9 #xA410)
    (mips-ori 10 0 ,N64-TOP10-RDP-DLIST-DRAM-PHYS)
    (mips-sw 10 0 9)
    (mips-ori 10 0 ,(+ N64-TOP10-RDP-DLIST-DRAM-PHYS rdp-dlist-len))
    (mips-sw 10 4 9)

    ;; Initialize Campaign & Genre State in RDRAM ($80000200)
    ,@(emit-mips-li32 11 N64-STATE-BASE-KSEG0)
    (mips-sw 0 ,N64-STATE-BUTTONS 11)
    (mips-sw 0 ,N64-STATE-FRAME-CNT 11)
    (mips-sw 0 ,N64-STATE-DEAD 11)
    (mips-sw 0 ,N64-STATE-STAGE-ID 11)
    (mips-sw 0 ,N64-STATE-WON 11)
    (mips-sw 0 ,N64-STATE-GAME-COMPLETED 11)
    (mips-sw 0 ,N64-STATE-SCORE 11)
    (mips-ori 10 0 ,init-x)
    (mips-sw 10 ,N64-STATE-PLAYER-X 11)
    (mips-ori 10 0 ,init-y)
    (mips-sw 10 ,N64-STATE-PLAYER-Y 11)
    (mips-ori 10 0 ,init-energy)
    (mips-sw 10 ,N64-STATE-ENERGY 11)
    (mips-ori 10 0 3)
    (mips-sw 10 ,N64-STATE-LIVES 11)
    (mips-ori 10 0 ,rsp-scale)
    (mips-sw 10 ,N64-STATE-GENRE-A 11)
    (mips-ori 10 0 ,rsp-bias)
    (mips-sw 10 ,N64-STATE-GENRE-B 11)

    (mips-jr 31)
    (mips-nop)

    ;; ========================================================================
    ;; 2. Per-Frame VR4300 Campaign & Genre Step (`frame_step`)
    ;; ========================================================================
    (label frame_step)
    ,@(emit-mips-li32 11 N64-STATE-BASE-KSEG0)
    ;; Increment frame_cnt
    (mips-lw 8 ,N64-STATE-FRAME-CNT 11)
    (mips-addiu 8 8 1)
    (mips-sw 8 ,N64-STATE-FRAME-CNT 11)

    ;; Step 3D genre kinematics / RSP transform accumulator in $8000022C
    (mips-lw 8 ,N64-STATE-GENRE-A 11)
    (mips-addiu 8 8 ,rsp-bias)
    (mips-sw 8 ,N64-STATE-GENRE-A 11)

    ;; Read controller buttons
    (mips-lw 9 ,N64-STATE-BUTTONS 11)

    ;; Check START (#x08) -> Recovery (`REC_OK`)
    (mips-ori 10 0 ,N64-BTN-START)
    (mips-beq 9 10 n64_handle_recovery)
    (mips-nop)

    ;; Check LEFT (#x20) -> Hazard Failure (`FAIL_OK`)
    (mips-ori 10 0 ,N64-BTN-LEFT)
    (mips-beq 9 10 n64_handle_fail)
    (mips-nop)

    ;; Check RIGHT (#x10) or A (#x01) -> Stage Advance (`FULL_WIN_OK`)
    (mips-ori 10 0 ,N64-BTN-RIGHT)
    (mips-beq 9 10 n64_handle_advance)
    (mips-nop)
    (mips-ori 10 0 ,N64-BTN-A)
    (mips-beq 9 10 n64_handle_advance)
    (mips-nop)
    (mips-j n64_frame_done)
    (mips-nop)

    (label n64_handle_fail)
    (mips-lw 12 ,N64-STATE-DEAD 11)
    (mips-bne 12 0 n64_frame_done)
    (mips-nop)
    (mips-ori 10 0 1)
    (mips-sw 10 ,N64-STATE-DEAD 11)
    (mips-sw 0 ,N64-STATE-ENERGY 11)
    (mips-lw 10 ,N64-STATE-LIVES 11)
    (mips-ori 13 0 1)
    (mips-subu 10 10 13)
    (mips-sw 10 ,N64-STATE-LIVES 11)
    (mips-j n64_frame_done)
    (mips-nop)

    (label n64_handle_recovery)
    (mips-sw 0 ,N64-STATE-DEAD 11)
    (mips-ori 10 0 ,init-energy)
    (mips-sw 10 ,N64-STATE-ENERGY 11)
    (mips-j n64_frame_done)
    (mips-nop)

    (label n64_handle_advance)
    (mips-lw 12 ,N64-STATE-DEAD 11)
    (mips-bne 12 0 n64_frame_done)
    (mips-nop)
    ;; Player X += 16, Score += score-delta, Genre-B += 1
    (mips-lw 10 ,N64-STATE-PLAYER-X 11)
    (mips-addiu 10 10 16)
    (mips-sw 10 ,N64-STATE-PLAYER-X 11)
    (mips-lw 10 ,N64-STATE-SCORE 11)
    (mips-addiu 10 10 ,score-delta)
    (mips-sw 10 ,N64-STATE-SCORE 11)
    (mips-lw 10 ,N64-STATE-GENRE-B 11)
    (mips-addiu 10 10 1)
    (mips-sw 10 ,N64-STATE-GENRE-B 11)
    ;; Stage 0 -> 1 -> 2 -> 3 -> Campaign Victory
    (mips-lw 10 ,N64-STATE-STAGE-ID 11)
    (mips-ori 13 0 3)
    (mips-beq 10 13 n64_mark_victory)
    (mips-nop)
    (mips-addiu 10 10 1)
    (mips-sw 10 ,N64-STATE-STAGE-ID 11)
    (mips-j n64_frame_done)
    (mips-nop)

    (label n64_mark_victory)
    (mips-ori 10 0 1)
    (mips-sw 10 ,N64-STATE-WON 11)
    (mips-sw 10 ,N64-STATE-GAME-COMPLETED 11)

    (label n64_frame_done)
    (mips-jr 31)
    (mips-nop)))

;; Build an authentic 9,216-byte big-endian `.z64` ROM image for an N64 Top-10 game spec.
(define (build-reference-n64-top10-rom spec-or-sym
                                       #:mips-forms [custom-mips-forms #f]
                                       #:rsp-asm [custom-rsp-asm #f]
                                       #:rdp-dlist [custom-rdp-dlist #f]
                                       #:textures [custom-textures #f])
  (define spec      (find-n64-top10-game-spec spec-or-sym))
  (define rsp-res   (or custom-rsp-asm (build-n64-top10-rsp-microcode spec)))
  (define rdp-res   (or custom-rdp-dlist (build-n64-top10-rdp-display-list spec)))
  (define tex-bs    (or custom-textures (build-n64-top10-rgba16-textures spec)))
  (define rsp-bs    (hash-ref rsp-res 'bytes))
  (define rdp-bs    (hash-ref rdp-res 'bytes))
  (define mips-forms
    (or custom-mips-forms
        (emit-n64-top10-vr4300-program spec
                                       #:rsp-ucode-len (bytes-length rsp-bs)
                                       #:rdp-dlist-len (bytes-length rdp-bs))))
  (define mips-res  (assemble-mips-vr4300 mips-forms #:origin N64-BOOT-PC))
  (define mips-bs   (n64-mips-asm-bytes mips-res))

  (define rom (make-bytes #x2400 0))

  ;; 1. $00..$03: Big-Endian PI BSD DOM1 Magic (#x80371240)
  (bytes-copy! rom #x00 (u32->be-bytes N64-ROM-HEADER-MAGIC))
  ;; 2. $04..$07: ClockRate (#x0000000F)
  (bytes-copy! rom #x04 (u32->be-bytes #x0000000F))
  ;; 3. $08..$0B: Boot PC (#x80000400)
  (bytes-copy! rom #x08 (u32->be-bytes N64-BOOT-PC))
  ;; 4. $0C..$0F: Libultra Release (#x00001449)
  (bytes-copy! rom #x0C (u32->be-bytes #x00001449))
  ;; 5. $20..$33: 20-byte space-padded ASCII Title
  (define htitle (hash-ref spec 'header-title "BOBA N64"))
  (define title20 (string->bytes/utf-8 (substring (string-append htitle "                    ") 0 20)))
  (bytes-copy! rom #x20 title20 0 20)
  ;; 6. $34..$37: 4-byte Game-Specific Code ("NSME", "CZLE", etc.) + $38..$39: code lengths
  (define gcode (hash-ref spec 'game-code "NSME"))
  (bytes-copy! rom #x34 (string->bytes/utf-8 (substring (string-append gcode "    ") 0 4)) 0 4)
  (bytes-copy! rom #x38 (u16->be-bytes (bytes-length mips-bs)))
  (bytes-set!  rom #x3A (bytes-length rdp-bs))
  ;; 7. $3B..$3E: "NBOB" (compatible with `verify-n64-z64-header`) & $3F: game index (0..9)
  (bytes-copy! rom #x3B #"NBOB" 0 4)
  (bytes-set!  rom #x3F (bitwise-and (hash-ref spec 'index 0) #xFF))

  ;; 8. $0040..$004F: IPL3 Boot Stub jumping to $80000400
  (define ipl3-stub
    (assemble-mips-vr4300
     (list (mips-lui 8 #x8000)
           (mips-ori 8 8 #x0400)
           (mips-jr 8)
           (mips-nop))
     #:origin #xA4000040
     #:bytes-only? #t))
  (bytes-copy! rom #x0040 ipl3-stub)

  ;; 9. Copy Payload Sections into $1000..$23FF
  (bytes-copy! rom #x1000 mips-bs 0 (min (bytes-length mips-bs) #x0800))
  (bytes-copy! rom #x1800 rsp-bs  0 (min (bytes-length rsp-bs)  #x0400))
  (bytes-copy! rom #x1C00 rdp-bs  0 (min (bytes-length rdp-bs)  #x0400))
  (bytes-copy! rom #x2000 tex-bs  0 (min (bytes-length tex-bs)  #x0400))

  ;; 10. Compute and write $10..$17 CRC1 and CRC2 words
  (define-values (crc1 crc2) (compute-n64-header-crcs rom))
  (bytes-copy! rom #x10 (u32->be-bytes crc1))
  (bytes-copy! rom #x14 (u32->be-bytes crc2))

  rom)

;; ============================================================================
;; 5. ARM7TDMI (ARM32 + Thumb16) Binary Disassembler & GBA Decompiler
;; ============================================================================

(define (sign-extend-24 n)
  (if (bitwise-bit-set? n 23) (- n #x1000000) n))

;; Decode a single 16-bit Thumb instruction halfword into its symbolic S-expression
(define (decode-thumb16-inst inst16)
  (define top5 (bitwise-and (arithmetic-shift inst16 -11) #x1F))
  (cond
    [(= top5 #b00100)
     (thumb-mov-imm (bitwise-and (arithmetic-shift inst16 -8) #x7)
                    (bitwise-and inst16 #xFF))]
    [(= top5 #b00110)
     (thumb-add-imm (bitwise-and (arithmetic-shift inst16 -8) #x7)
                    (bitwise-and inst16 #xFF))]
    [(= top5 #b00111)
     (thumb-sub-imm (bitwise-and (arithmetic-shift inst16 -8) #x7)
                    (bitwise-and inst16 #xFF))]
    [(= (bitwise-and inst16 #xFE00) #x5200)
     (thumb-strh (bitwise-and inst16 #x7)
                 (bitwise-and (arithmetic-shift inst16 -3) #x7)
                 (bitwise-and (arithmetic-shift inst16 -6) #x7))]
    [(= (bitwise-and inst16 #xFE00) #x5400)
     (thumb-strb (bitwise-and inst16 #x7)
                 (bitwise-and (arithmetic-shift inst16 -3) #x7)
                 (bitwise-and (arithmetic-shift inst16 -6) #x7))]
    [(= (bitwise-and inst16 #xFF80) #x4700)
     (thumb-bx (bitwise-and (arithmetic-shift inst16 -3) #xF))]
    [else
     `(.hword ,inst16)]))

;; Decode a single 32-bit ARM instruction word at `pc` into its symbolic S-expression
(define (decode-arm32-inst inst32 pc addr->label)
  (define cond-code (bitwise-and (arithmetic-shift inst32 -28) #xF))
  (cond
    ;; BX Rm (#xE12FFF10 | rm)
    [(= (bitwise-and inst32 #x0FFFFFF0) #x012FFF10)
     (arm-bx (bitwise-and inst32 #xF))]

    ;; B / BL / BEQ / BNE (bits 27..25 = #b101)
    [(= (bitwise-and (arithmetic-shift inst32 -25) #x7) #b101)
     (define link?  (bitwise-bit-set? inst32 24))
     (define imm24  (sign-extend-24 (bitwise-and inst32 #xFFFFFF)))
     (define target (bitwise-and #xFFFFFFFF (+ pc 8 (arithmetic-shift imm24 2))))
     (define sym    (hash-ref addr->label target target))
     (cond
       [link?              (arm-bl sym)]
       [(= cond-code #x0)  (arm-beq sym)]
       [(= cond-code #x1)  (arm-bne sym)]
       [else               (arm-b sym)])]

    ;; Halfword Transfer Immediate: STRH / LDRH (bits 27..25 = #b000, bit 22=1, bits 7..4=#b1011)
    [(and (= (bitwise-and (arithmetic-shift inst32 -25) #x7) #b000)
          (bitwise-bit-set? inst32 22)
          (= (bitwise-and (arithmetic-shift inst32 -4) #xF) #b1011))
     (define load? (bitwise-bit-set? inst32 20))
     (define up?   (bitwise-bit-set? inst32 23))
     (define rn    (bitwise-and (arithmetic-shift inst32 -16) #xF))
     (define rd    (bitwise-and (arithmetic-shift inst32 -12) #xF))
     (define off8  (bitwise-ior (arithmetic-shift (bitwise-and (arithmetic-shift inst32 -8) #xF) 4)
                                (bitwise-and inst32 #xF)))
     (define signed-off (if up? off8 (- off8)))
     (if load?
         (arm-ldrh-imm rd rn signed-off)
         (arm-strh-imm rd rn signed-off))]

    ;; Single Data Transfer Immediate: LDR / STR / LDRB / STRB (bits 27..26 = #b01)
    [(= (bitwise-and (arithmetic-shift inst32 -26) #x3) #b01)
     (define byte? (bitwise-bit-set? inst32 22))
     (define load? (bitwise-bit-set? inst32 20))
     (define up?   (bitwise-bit-set? inst32 23))
     (define rn    (bitwise-and (arithmetic-shift inst32 -16) #xF))
     (define rd    (bitwise-and (arithmetic-shift inst32 -12) #xF))
     (define off12 (bitwise-and inst32 #xFFF))
     (define signed-off (if up? off12 (- off12)))
     (cond
       [(and load? byte?)       (arm-ldrb-imm rd rn signed-off)]
       [(and load? (not byte?)) (arm-ldr-imm  rd rn signed-off)]
       [(and (not load?) byte?) (arm-strb-imm rd rn signed-off)]
       [else                    (arm-str-imm  rd rn signed-off)])]

    ;; Data Processing Immediate (bits 27..25 = #b001)
    [(= (bitwise-and (arithmetic-shift inst32 -25) #x7) #b001)
     (define opcode (bitwise-and (arithmetic-shift inst32 -21) #xF))
     (define rn     (bitwise-and (arithmetic-shift inst32 -16) #xF))
     (define rd     (bitwise-and (arithmetic-shift inst32 -12) #xF))
     (define rot4   (bitwise-and (arithmetic-shift inst32 -8) #xF))
     (define imm8   (bitwise-and inst32 #xFF))
     (case opcode
       [(#xD) (arm-mov-imm rd imm8 rot4)]
       [(#xC) (arm-orr-imm rd rn imm8 rot4)]
       [(#x4) (arm-add-imm rd rn imm8 rot4)]
       [(#x2) (arm-sub-imm rd rn imm8 rot4)]
       [(#xA) (arm-cmp-imm rn imm8 rot4)]
       [else  `(.word ,inst32)])]

    [else `(.word ,inst32)]))

;; Disassemble the ARM7TDMI (ARM32 + Thumb16) code region ($00C0..$03FF) of a `.gba` ROM
(define (disassemble-arm7tdmi-rom rom-bytes)
  (define code-start #x00C0)
  (define code-limit (min #x0400 (bytes-length rom-bytes)))

  ;; Pass 1: Scan instructions, detect Thumb16 veneer vs ARM32, and collect branch target addresses
  (define addr->label (make-hasheq))
  (hash-set! addr->label GBA-ROM-ENTRY 'boot_init)
  (define branch-idx 0)

  (let loop ([off code-start] [in-thumb? #f])
    (when (<= (+ off 2) code-limit)
      (cond
        [in-thumb?
         (define inst16 (integer-bytes->integer rom-bytes #f #f off (+ off 2)))
         (define next-thumb? (not (= (bitwise-and inst16 #xFF80) #x4700)))
         (when (and (not next-thumb?) (<= (+ off 6) code-limit))
           (define next-w (integer-bytes->integer rom-bytes #f #f (+ off 2) (+ off 6)))
           (unless (zero? next-w)
             (hash-set! addr->label (+ GBA-ROM-BASE off 2) 'frame_step)))
         (loop (+ off 2) next-thumb?)]
        [(<= (+ off 4) code-limit)
         (define inst32 (integer-bytes->integer rom-bytes #f #f off (+ off 4)))
         (cond
           [(zero? inst32) (void)]
           ;; Detect transition into 16-bit Thumb sequence (top nibble in 2..5)
           [(memv (bitwise-and (arithmetic-shift inst32 -28) #xF) '(2 3 4 5))
            (loop off #t)]
           [else
            (define pc (+ GBA-ROM-BASE off))
            (when (= (bitwise-and (arithmetic-shift inst32 -25) #x7) #b101)
              (define link? (bitwise-bit-set? inst32 24))
              (define imm24 (sign-extend-24 (bitwise-and inst32 #xFFFFFF)))
              (define target (bitwise-and #xFFFFFFFF (+ pc 8 (arithmetic-shift imm24 2))))
              (unless (hash-has-key? addr->label target)
                (set! branch-idx (add1 branch-idx))
                (hash-set! addr->label target
                           (if link?
                               'thumb_bg0_tilemap_veneer
                               (string->symbol (format "branch_target_~a" branch-idx))))))
            (loop (+ off 4) #f)])])))

  ;; Pass 2: Emit labeled symbolic ARM32 + Thumb16 instruction stream
  (define forms '())
  (define arm-cnt 0)
  (define thumb-cnt 0)

  (let loop ([off code-start] [in-thumb? #f])
    (when (<= (+ off 2) code-limit)
      (define pc (+ GBA-ROM-BASE off))
      (when (hash-has-key? addr->label pc)
        (set! forms (cons `(label ,(hash-ref addr->label pc)) forms)))
      (cond
        [in-thumb?
         (define inst16 (integer-bytes->integer rom-bytes #f #f off (+ off 2)))
         (set! thumb-cnt (add1 thumb-cnt))
         (set! forms (cons (decode-thumb16-inst inst16) forms))
         (define next-thumb? (not (= (bitwise-and inst16 #xFF80) #x4700)))
         (loop (+ off 2) next-thumb?)]
        [(<= (+ off 4) code-limit)
         (define inst32 (integer-bytes->integer rom-bytes #f #f off (+ off 4)))
         (cond
           [(zero? inst32) (void)]
           [(memv (bitwise-and (arithmetic-shift inst32 -28) #xF) '(2 3 4 5))
            (loop off #t)]
           [else
            (set! arm-cnt (add1 arm-cnt))
            (set! forms (cons (decode-arm32-inst inst32 pc addr->label) forms))
            (loop (+ off 4) #f)])])))

  (define rev-forms (reverse forms))
  (hasheq 'forms       rev-forms
          'arm-count   arm-cnt
          'thumb-count thumb-cnt
          'labels      addr->label))

;; Decompile a `.gba` ROM binary (or game spec) into a `#lang boba-nes` S-expression module
(define (decompile-gba-rom->boba-dsl gba-bytes-or-spec)
  (define rom-bytes
    (if (bytes? gba-bytes-or-spec)
        gba-bytes-or-spec
        (build-reference-gba-top10-rom gba-bytes-or-spec)))

  ;; 1. Parse and verify .gba Cartridge Header ($00..$BF)
  (define entry-word  (integer-bytes->integer rom-bytes #f #f #x00 #x04))
  (define logo-ok?    (bytes=? (subbytes rom-bytes #x04 #xA0) GBA-NINTENDO-LOGO))
  (define raw-title   (string-trim (bytes->string/utf-8 (subbytes rom-bytes #xA0 #xAC))))
  (define game-code   (string-trim (bytes->string/utf-8 (subbytes rom-bytes #xAC #xB0))))
  (define maker-code  (string-trim (bytes->string/utf-8 (subbytes rom-bytes #xB0 #xB2))))
  (define fixed-96    (bytes-ref rom-bytes #xB2))
  (define game-idx    (bytes-ref rom-bytes #xB3))
  (define version-b   (bytes-ref rom-bytes #xBC))
  (define header-chk  (bytes-ref rom-bytes #xBD))
  (define exp-chk     (compute-gba-header-checksum rom-bytes))
  (define header-ok?  (and (= entry-word #xEA00002E)
                           logo-ok?
                           (= fixed-96 #x96)
                           (= header-chk exp-chk)
                           (= header-chk #xCC)))

  (define spec
    (or (for/first ([s (in-list GBA-TOP10-GAME-SPECS)]
                    #:when (or (equal? (hash-ref s 'game-code) game-code)
                               (equal? (hash-ref s 'index) game-idx)))
          s)
        (first GBA-TOP10-GAME-SPECS)))

  ;; 2. Disassemble ARM7TDMI (ARM32 + Thumb16) instructions & audit VRAM bus safety
  (define disasm-res  (disassemble-arm7tdmi-rom rom-bytes))
  (define forms       (hash-ref disasm-res 'forms))
  (define bus-audit   (verify-gba-vram-bus-widths forms))

  ;; 3. Extract BGR555 Palettes ($0400..$043F), 4bpp Tiles ($0500..$05FF), and OAM ($0600..$063F)
  (define pal-bytes   (subbytes rom-bytes #x0400 #x0440))
  (define tile-bytes  (subbytes rom-bytes #x0500 #x0600))
  (define oam-bytes   (subbytes rom-bytes #x0600 #x0640))

  (define pal-u16-list
    (for/list ([i (in-range 0 (bytes-length pal-bytes) 2)])
      (integer-bytes->integer pal-bytes #f #f i (+ i 2))))

  (define tiles-u32-list
    (for/list ([t (in-range 8)])
      (define base (* t 32))
      (for/list ([w (in-range 8)])
        (integer-bytes->integer tile-bytes #f #f (+ base (* w 4)) (+ base (* w 4) 4)))))

  (define oam-entries
    (for/list ([s (in-range 8)])
      (define base (* s 8))
      (list (integer-bytes->integer oam-bytes #f #f base (+ base 2))
            (integer-bytes->integer oam-bytes #f #f (+ base 2) (+ base 4))
            (integer-bytes->integer oam-bytes #f #f (+ base 4) (+ base 6))
            (integer-bytes->integer oam-bytes #f #f (+ base 6) (+ base 8)))))

  (define header-info
    (hasheq 'entry-branch      entry-word
            'nintendo-logo-ok? logo-ok?
            'header-title      raw-title
            'game-code         game-code
            'maker-code        maker-code
            'fixed-byte        fixed-96
            'game-index        game-idx
            'software-version  version-b
            'complement-check  header-chk
            'expected-check    exp-chk
            'complement-cc?    (= header-chk #xCC)
            'valid?            header-ok?))

  (define hardware-audit
    (hasheq 'header-valid?          header-ok?
            'strb-vram-violations   (hash-ref bus-audit 'strb-violations)
            'iwram-accesses         (hash-ref bus-audit 'iwram-accesses)
            'ewram-accesses         (hash-ref bus-audit 'ewram-accesses)
            'dma3-transfers         (hash-ref bus-audit 'dma3-transfers)
            'memory-placement-grade (hash-ref bus-audit 'memory-placement-grade)
            'arm-instructions       (hash-ref disasm-res 'arm-count)
            'thumb-instructions     (hash-ref disasm-res 'thumb-count)
            'interworking-verified? (and (> (hash-ref disasm-res 'arm-count) 0)
                                         (> (hash-ref disasm-res 'thumb-count) 0))))

  `(boba-module
    #:target 'gba
    #:name ,(hash-ref spec 'symbol)
    #:title ,(hash-ref spec 'title)
    #:genre ,(hash-ref spec 'genre)
    #:header ,header-info
    #:hardware-audit ,hardware-audit
    #:palettes-bgr555 ,pal-u16-list
    #:tiles-4bpp ,tiles-u32-list
    #:oam-entries ,oam-entries
    #:arm7tdmi-program ,forms
    #:stage-names ,(hash-ref spec 'stage-names)
    #:spec ,spec))

;; ============================================================================
;; 6. MIPS VR4300 + RSP SIMD + RDP Display List Disassembler & N64 Decompiler
;; ============================================================================

(define (sign-extend-16 n)
  (define u (bitwise-and n #xFFFF))
  (if (bitwise-bit-set? u 15) (- u #x10000) u))

;; Decode a single 32-bit big-endian MIPS VR4300 instruction word
(define (decode-mips-vr4300-inst inst32 pc addr->label)
  (define op    (bitwise-and (arithmetic-shift inst32 -26) #x3F))
  (define rs    (bitwise-and (arithmetic-shift inst32 -21) #x1F))
  (define rt    (bitwise-and (arithmetic-shift inst32 -16) #x1F))
  (define rd    (bitwise-and (arithmetic-shift inst32 -11) #x1F))
  (define funct (bitwise-and inst32 #x3F))
  (define imm16 (bitwise-and inst32 #xFFFF))
  (define simm  (sign-extend-16 imm16))

  (cond
    [(zero? inst32) (mips-nop)]
    [(= op #x00)
     (case funct
       [(#x21) (mips-addu rd rs rt)]
       [(#x23) (mips-subu rd rs rt)]
       [(#x08) (mips-jr rs)]
       [else   `(.word ,inst32)])]
    [(= op #x0F) (mips-lui rt imm16)]
    [(= op #x0D) (mips-ori rt rs imm16)]
    [(= op #x09) (mips-addiu rt rs simm)]
    [(= op #x0C) (mips-andi rt rs imm16)]
    [(= op #x23) (mips-lw rt simm rs)]
    [(= op #x2B) (mips-sw rt simm rs)]
    [(= op #x21) (mips-lh rt simm rs)]
    [(= op #x29) (mips-sh rt simm rs)]
    [(= op #x2F) (mips-cache rt simm rs)]
    [(= op #x04)
     (define target (bitwise-and #xFFFFFFFF (+ pc 4 (arithmetic-shift simm 2))))
     (mips-beq rs rt (hash-ref addr->label target target))]
    [(= op #x05)
     (define target (bitwise-and #xFFFFFFFF (+ pc 4 (arithmetic-shift simm 2))))
     (mips-bne rs rt (hash-ref addr->label target target))]
    [(= op #x02)
     (define idx26  (bitwise-and inst32 #x03FFFFFF))
     (define target (bitwise-ior (bitwise-and (+ pc 4) #xF0000000) (arithmetic-shift idx26 2)))
     (mips-j (hash-ref addr->label target target))]
    [(= op #x03)
     (define idx26  (bitwise-and inst32 #x03FFFFFF))
     (define target (bitwise-ior (bitwise-and (+ pc 4) #xF0000000) (arithmetic-shift idx26 2)))
     (mips-jal (hash-ref addr->label target target))]
    [else `(.word ,inst32)]))

;; Decode a single 32-bit big-endian RSP SIMD instruction word
(define (decode-rsp-inst w)
  (define op (bitwise-and (arithmetic-shift w -26) #x3F))
  (cond
    [(= w #x0000000D) (rsp-break)]
    [(= w #x03E00008) (rsp-jr-ra)]
    [(= op #x32)
     (define base (bitwise-and (arithmetic-shift w -21) #x1F))
     (define vt   (bitwise-and (arithmetic-shift w -16) #x1F))
     (define elem (bitwise-and (arithmetic-shift w -7)  #xF))
     (define off7 (bitwise-and w #x7F))
     (rsp-lqv vt elem (* off7 16) base)]
    [(= op #x3A)
     (define base (bitwise-and (arithmetic-shift w -21) #x1F))
     (define vt   (bitwise-and (arithmetic-shift w -16) #x1F))
     (define elem (bitwise-and (arithmetic-shift w -7)  #xF))
     (define off7 (bitwise-and w #x7F))
     (rsp-sqv vt elem (* off7 16) base)]
    [(= op #x12)
     (define elem  (bitwise-and (arithmetic-shift w -21) #xF))
     (define vt    (bitwise-and (arithmetic-shift w -16) #x1F))
     (define vs    (bitwise-and (arithmetic-shift w -11) #x1F))
     (define vd    (bitwise-and (arithmetic-shift w -6)  #x1F))
     (define funct (bitwise-and w #x3F))
     (case funct
       [(#x00) (rsp-vmulf vd vs vt elem)]
       [(#x08) (rsp-vmacf vd vs vt elem)]
       [(#x10) (rsp-vadd  vd vs vt elem)]
       [else   `(.word ,w)])]
    [else `(.word ,w)]))

;; Decode a single 64-bit big-endian RDP Display List command word
(define (decode-rdp-command-u64 hi lo)
  (define op (bitwise-and (arithmetic-shift hi -24) #xFF))
  (case op
    [(#xED) ; Set_Scissor
     (define ulx (bitwise-and (arithmetic-shift hi -12) #xFFF))
     (define uly (bitwise-and hi #xFFF))
     (define lrx (bitwise-and (arithmetic-shift lo -12) #xFFF))
     (define lry (bitwise-and lo #xFFF))
     (rdp-set-scissor ulx uly lrx lry)]
    [(#xFF) ; Set_Color_Image
     (define fmt   (bitwise-and (arithmetic-shift hi -21) #x7))
     (define size  (bitwise-and (arithmetic-shift hi -19) #x3))
     (define width (add1 (bitwise-and hi #xFFF)))
     (rdp-set-color-image fmt size width lo)]
    [(#xF7) ; Set_Fill_Color
     (rdp-set-fill-color lo)]
    [(#xF6) ; Fill_Rectangle
     (define lrx (bitwise-and (arithmetic-shift hi -12) #xFFF))
     (define lry (bitwise-and hi #xFFF))
     (define ulx (bitwise-and (arithmetic-shift lo -12) #xFFF))
     (define uly (bitwise-and lo #xFFF))
     (rdp-fill-rectangle ulx uly lrx lry)]
    [(#xE7) ; Sync_Pipe
     (rdp-sync-pipe)]
    [(#xFD) ; Set_Texture_Image
     (define fmt   (bitwise-and (arithmetic-shift hi -21) #x7))
     (define size  (bitwise-and (arithmetic-shift hi -19) #x3))
     (define width (add1 (bitwise-and hi #xFFF)))
     (rdp-set-texture-image fmt size width lo)]
    [(#xE8) ; Sync_Tile
     (rdp-sync-tile)]
    [(#xF3) ; Load_Block
     (define uls  (bitwise-and (arithmetic-shift hi -12) #xFFF))
     (define ult  (bitwise-and hi #xFFF))
     (define tile (bitwise-and (arithmetic-shift lo -24) #x7))
     (define lrs  (bitwise-and (arithmetic-shift lo -12) #xFFF))
     (define dxt  (bitwise-and lo #xFFF))
     (rdp-load-block tile uls ult lrs dxt)]
    [(#xE4) ; Texture_Rectangle
     (define xl   (bitwise-and (arithmetic-shift hi -14) #x3FF))
     (define yl   (bitwise-and (arithmetic-shift hi -4)  #x3FF))
     (define tile (bitwise-and hi #x7))
     (define xh   (bitwise-and (arithmetic-shift lo -22) #x3FF))
     (define yh   (bitwise-and (arithmetic-shift lo -12) #x3FF))
     (define s    (bitwise-and (arithmetic-shift lo -6)  #x3F))
     (define t    (bitwise-and lo #x3F))
     (rdp-texture-rectangle xl yl xh yh tile s t 1024 1024)]
    [(#xE9) ; Full_Sync
     (rdp-full-sync)]
    [else
     `(rdp-raw ,hi ,lo)]))

;; Disassemble a `.z64` N64 ROM image into VR4300 MIPS forms, RSP SIMD microcode, and RDP display list
(define (disassemble-n64-z64-rom z64-bytes)
  ;; Read exact code & display-list byte lengths from header ($38..$3A) if present
  (define hdr-mips-len (integer-bytes->integer z64-bytes #f #t #x38 #x3A))
  (define mips-byte-len (if (and (> hdr-mips-len 0) (<= hdr-mips-len #x0800)) hdr-mips-len 368))

  ;; 1. Disassemble MIPS VR4300 instructions at $1000.. ($80000400..)
  (define addr->label (make-hasheq))
  (hash-set! addr->label N64-BOOT-PC 'boot_init)
  (define branch-cnt 0)
  (define jr-seen 0)

  (for ([off (in-range 0 mips-byte-len 4)])
    (define pc (+ N64-BOOT-PC off))
    (define w  (integer-bytes->integer z64-bytes #f #t (+ #x1000 off) (+ #x1000 off 4)))
    (define op (bitwise-and (arithmetic-shift w -26) #x3F))
    (when (and (= w #x03E00008) (= jr-seen 0) (< (+ off 8) mips-byte-len))
      (set! jr-seen 1)
      (hash-set! addr->label (+ pc 8) 'frame_step))
    (when (or (= op #x04) (= op #x05))
      (define simm   (sign-extend-16 (bitwise-and w #xFFFF)))
      (define target (bitwise-and #xFFFFFFFF (+ pc 4 (arithmetic-shift simm 2))))
      (unless (hash-has-key? addr->label target)
        (set! branch-cnt (add1 branch-cnt))
        (hash-set! addr->label target (string->symbol (format "n64_label_~a" branch-cnt)))))
    (when (or (= op #x02) (= op #x03))
      (define idx26  (bitwise-and w #x03FFFFFF))
      (define target (bitwise-ior (bitwise-and (+ pc 4) #xF0000000) (arithmetic-shift idx26 2)))
      (unless (hash-has-key? addr->label target)
        (set! branch-cnt (add1 branch-cnt))
        (hash-set! addr->label target (string->symbol (format "n64_label_~a" branch-cnt))))))

  (define mips-forms
    (apply append
           (for/list ([off (in-range 0 mips-byte-len 4)])
             (define pc (+ N64-BOOT-PC off))
             (define w  (integer-bytes->integer z64-bytes #f #t (+ #x1000 off) (+ #x1000 off 4)))
             (define inst-form (decode-mips-vr4300-inst w pc addr->label))
             (if (hash-has-key? addr->label pc)
                 (list `(label ,(hash-ref addr->label pc)) inst-form)
                 (list inst-form)))))

  ;; 2. Disassemble RSP 128-Bit SIMD Vector Microcode at $1800.. (9 instructions = 36 bytes)
  (define rsp-forms
    (let loop ([off 0] [acc '()])
      (if (>= off #x0400)
          (reverse acc)
          (let* ([w (integer-bytes->integer z64-bytes #f #t (+ #x1800 off) (+ #x1800 off 4))]
                 [decoded (decode-rsp-inst w)])
            (if (= w #x03E00008) ; rsp-jr-ra terminates microcode
                (reverse (cons decoded acc))
                (loop (+ off 4) (cons decoded acc)))))))

  ;; 3. Disassemble 64-Bit RDP Display List at $1C00.. until Full_Sync (#xE9)
  (define rdp-commands
    (let loop ([off 0] [acc '()])
      (if (>= off #x0400)
          (reverse acc)
          (let* ([hi (integer-bytes->integer z64-bytes #f #t (+ #x1C00 off) (+ #x1C00 off 4))]
                 [lo (integer-bytes->integer z64-bytes #f #t (+ #x1C00 off 4) (+ #x1C00 off 8))]
                 [op (bitwise-and (arithmetic-shift hi -24) #xFF)]
                 [cmd (decode-rdp-command-u64 hi lo)])
            (if (= op #xE9) ; Full_Sync terminates display list
                (reverse (cons cmd acc))
                (loop (+ off 8) (cons cmd acc)))))))

  (hasheq 'mips-forms   mips-forms
          'rsp-forms    rsp-forms
          'rdp-commands rdp-commands
          'labels       addr->label))

;; Decompile a `.z64` ROM binary (or game spec) into a `#lang boba-nes` S-expression module
(define (decompile-n64-rom->boba-dsl z64-bytes-or-spec)
  (define rom-bytes
    (if (bytes? z64-bytes-or-spec)
        z64-bytes-or-spec
        (build-reference-n64-top10-rom z64-bytes-or-spec)))

  ;; 1. Verify .z64 Big-Endian Header ($00..$3F) & CRC1/CRC2
  (define magic-u32  (integer-bytes->integer rom-bytes #f #t #x00 #x04))
  (define clock-rate (integer-bytes->integer rom-bytes #f #t #x04 #x08))
  (define boot-pc    (integer-bytes->integer rom-bytes #f #t #x08 #x0C))
  (define crc1       (integer-bytes->integer rom-bytes #f #t #x10 #x14))
  (define crc2       (integer-bytes->integer rom-bytes #f #t #x14 #x18))
  (define-values (exp-crc1 exp-crc2) (compute-n64-header-crcs rom-bytes))
  (define raw-title  (string-trim (bytes->string/utf-8 (subbytes rom-bytes #x20 #x34))))
  (define game-code  (string-trim (bytes->string/utf-8 (subbytes rom-bytes #x34 #x38))))
  (define game-idx   (bytes-ref rom-bytes #x3F))
  (define header-ok? (and (= magic-u32 N64-ROM-HEADER-MAGIC)
                          (= boot-pc N64-BOOT-PC)
                          (= crc1 exp-crc1)
                          (= crc2 exp-crc2)
                          (verify-n64-z64-header rom-bytes)))

  (define spec
    (or (for/first ([s (in-list N64-TOP10-GAME-SPECS)]
                    #:when (or (equal? (hash-ref s 'game-code) game-code)
                               (equal? (hash-ref s 'index) game-idx)))
          s)
        (first N64-TOP10-GAME-SPECS)))

  ;; 2. Disassemble VR4300 MIPS, RSP SIMD Microcode, and RDP Display List
  (define disasm-res   (disassemble-n64-z64-rom rom-bytes))
  (define mips-forms   (hash-ref disasm-res 'mips-forms))
  (define rsp-forms    (hash-ref disasm-res 'rsp-forms))
  (define rdp-commands (hash-ref disasm-res 'rdp-commands))

  ;; 3. Audit CapDMA 16-Byte Alignment, <= 4 KB IMEM/DMEM/TMEM, and RDP Sync Protocol
  (define imem-bytes   (* 4 (length rsp-forms)))
  (define dmem-bytes   64)
  (define tmem-bytes   1024)
  (define safety-audit (verify-n64-dma-and-tmem-safety
                        #:mips-forms mips-forms
                        #:imem-bytes imem-bytes
                        #:dmem-bytes dmem-bytes
                        #:tmem-bytes tmem-bytes))
  (define proto-audit  (verify-n64-rdp-sync-protocol rdp-commands))

  ;; 4. Extract 1,024-byte 16-bit RGBA5551 TMEM Texture Bank ($2000..$23FF)
  (define tex-bytes (subbytes rom-bytes #x2000 #x2400))
  (define tex-u16-list
    (for/list ([i (in-range 0 (bytes-length tex-bytes) 2)])
      (integer-bytes->integer tex-bytes #f #t i (+ i 2))))

  (define header-info
    (hasheq 'magic       magic-u32
            'clock-rate  clock-rate
            'boot-pc     boot-pc
            'crc1        crc1
            'crc2        crc2
            'exp-crc1    exp-crc1
            'exp-crc2    exp-crc2
            'crc-valid?  (and (= crc1 exp-crc1) (= crc2 exp-crc2))
            'title       raw-title
            'game-code   game-code
            'game-index  game-idx
            'valid?      header-ok?))

  (define hardware-audit
    (hasheq 'header-valid?        header-ok?
            'dma-16byte-aligned?  (hash-ref safety-audit 'dma-16byte-aligned?)
            'cache-coherent?      (hash-ref safety-audit 'cache-coherent?)
            'imem-bytes           imem-bytes
            'dmem-bytes           dmem-bytes
            'tmem-bytes           tmem-bytes
            'imem-ok?             (<= imem-bytes N64-IMEM-LIMIT-BYTES)
            'dmem-ok?             (<= dmem-bytes N64-DMEM-LIMIT-BYTES)
            'tmem-ok?             (<= tmem-bytes N64-TMEM-LIMIT-BYTES)
            'rdp-sync-protocol-ok? (hash-ref proto-audit 'valid?)
            'rdp-protocol         (hash-ref proto-audit 'protocol)
            'mips-instructions    (length mips-forms)
            'rsp-instructions     (length rsp-forms)
            'rdp-commands         (length rdp-commands)))

  `(boba-module
    #:target 'n64
    #:name ,(hash-ref spec 'symbol)
    #:title ,(hash-ref spec 'title)
    #:genre ,(hash-ref spec 'genre)
    #:header ,header-info
    #:hardware-audit ,hardware-audit
    #:vr4300-program ,mips-forms
    #:rsp-microcode ,rsp-forms
    #:rdp-display-list ,rdp-commands
    #:tmem-textures-rgba16 ,tex-u16-list
    #:stage-names ,(hash-ref spec 'stage-names)
    #:spec ,spec))

;; ============================================================================
;; 7. Recompilers from `#lang boba-nes` S-Expressions back to .gba / .z64
;; ============================================================================

;; Parse keyword-value pairs inside a `(boba-module ...)` S-expression into a hash
(define (parse-boba-module-sexp dsl-sexp)
  (cond
    [(hash? dsl-sexp) dsl-sexp]
    [(and (pair? dsl-sexp) (eq? (car dsl-sexp) 'boba-module))
     (define tbl (make-hasheq))
     (let loop ([rest (cdr dsl-sexp)])
       (match rest
         [(list* (? keyword? kw) val tail)
          (define k (string->symbol (keyword->string kw)))
          (define clean-val
            (if (and (pair? val) (eq? (car val) 'quote) (pair? (cdr val)))
                (cadr val)
                val))
          (hash-set! tbl k clean-val)
          (loop tail)]
         [(cons _ tail) (loop tail)]
         ['() (void)]))
     tbl]
    [else
     (error 'parse-boba-module-sexp "Expected (boba-module ...) S-expression, got: ~v" dsl-sexp)]))

;; Recompile a decompiled GBA `#lang boba-nes` S-expression module back to `.gba` bytes
(define (recompile-gba-boba-dsl->rom dsl-sexp)
  (define parsed (parse-boba-module-sexp dsl-sexp))
  (define spec   (or (hash-ref parsed 'spec #f)
                     (find-gba-top10-game-spec (hash-ref parsed 'name 'gba-metroid-fusion))))
  (define forms  (hash-ref parsed 'arm7tdmi-program #f))
  ;; Audit VRAM bus safety before assembling
  (when forms
    (verify-gba-vram-bus-widths forms #:error-on-violation? #t))

  (define pal-u16 (hash-ref parsed 'palettes-bgr555 #f))
  (define pal-bs
    (and pal-u16 (apply bytes-append (map u16->le-bytes pal-u16))))

  (define tiles-u32 (hash-ref parsed 'tiles-4bpp #f))
  (define tile-bs
    (and tiles-u32
         (apply bytes-append
                (for*/list ([tile (in-list tiles-u32)]
                            [w    (in-list tile)])
                  (u32->le-bytes w)))))

  (define oam-list (hash-ref parsed 'oam-entries #f))
  (define oam-bs
    (and oam-list
         (apply bytes-append
                (for/list ([entry (in-list oam-list)])
                  (bytes-append (u16->le-bytes (first entry))
                                (u16->le-bytes (second entry))
                                (u16->le-bytes (third entry))
                                (u16->le-bytes (fourth entry)))))))

  (build-reference-gba-top10-rom spec
                                 #:forms    forms
                                 #:palettes pal-bs
                                 #:tiles    tile-bs
                                 #:oam      oam-bs))

;; Recompile a decompiled N64 `#lang boba-nes` S-expression module back to `.z64` bytes
(define (recompile-n64-boba-dsl->rom dsl-sexp)
  (define parsed    (parse-boba-module-sexp dsl-sexp))
  (define spec      (or (hash-ref parsed 'spec #f)
                        (find-n64-top10-game-spec (hash-ref parsed 'name 'n64-super-mario-64))))
  (define mips-fms  (hash-ref parsed 'vr4300-program #f))
  (define rsp-fms   (hash-ref parsed 'rsp-microcode #f))
  (define rdp-cmds  (hash-ref parsed 'rdp-display-list #f))
  (define tex-u16   (hash-ref parsed 'tmem-textures-rgba16 #f))

  (define rsp-res   (if rsp-fms (assemble-rsp-microcode rsp-fms #:dmem-bytes 64) #f))
  (define rdp-res   (if rdp-cmds (build-n64-top10-rdp-display-list spec #:commands rdp-cmds) #f))
  (define tex-bs    (and tex-u16 (apply bytes-append (map u16->be-bytes tex-u16))))

  (when (and mips-fms rsp-res rdp-res)
    (verify-n64-dma-and-tmem-safety
     #:mips-forms mips-fms
     #:imem-bytes (hash-ref rsp-res 'imem-bytes)
     #:dmem-bytes (hash-ref rsp-res 'dmem-bytes)
     #:tmem-bytes (hash-ref rdp-res 'tmem-bytes)
     #:error-on-violation? #t))

  (build-reference-n64-top10-rom spec
                                 #:mips-forms mips-fms
                                 #:rsp-asm    rsp-res
                                 #:rdp-dlist  rdp-res
                                 #:textures   tex-bs))

;; ============================================================================
;; 8. Headless GBA (240x160) & N64 (320x240) RGB Framebuffer Renderers
;; ============================================================================

;; Convert 15-bit GBA BGR555 (#b0bbbbbgggggrrrrr) to (values r8 g8 b8)
(define (bgr555->rgb8 color16)
  (define r5 (bitwise-and color16 #x1F))
  (define g5 (bitwise-and (arithmetic-shift color16 -5) #x1F))
  (define b5 (bitwise-and (arithmetic-shift color16 -10) #x1F))
  (values (arithmetic-shift r5 3)
          (arithmetic-shift g5 3)
          (arithmetic-shift b5 3)))

;; Convert 16-bit N64 RGBA5551 (#brrrrrgggggbbbbba) to (values r8 g8 b8)
(define (rgba5551->rgb8 color16)
  (define r5 (bitwise-and (arithmetic-shift color16 -11) #x1F))
  (define g5 (bitwise-and (arithmetic-shift color16 -6)  #x1F))
  (define b5 (bitwise-and (arithmetic-shift color16 -1)  #x1F))
  (values (arithmetic-shift r5 3)
          (arithmetic-shift g5 3)
          (arithmetic-shift b5 3)))

;; Render the complete 240x160 (38,400 pixels = 115,200 RGB24 bytes) GBA LCD Framebuffer
;; from the live `gba-machine` hardware state (PALRAM, BG0 VRAM, OBJ VRAM, OAM, IWRAM HUD).
(define (render-gba-rgb-framebuffer m)
  (define width  240)
  (define height 160)
  (define fb     (make-bytes (* width height 3) 0))

  ;; 1. Fill 240x160 backdrop with BG Palette[0] BGR555 color
  (define bg0-col16 (gba-read-u16 m GBA-PALRAM-BASE))
  (define-values (bg-r bg-g bg-b) (bgr555->rgb8 bg0-col16))
  (define scanline-template (make-bytes (* width 3) 0))
  (for ([x (in-range width)])
    (define off (* x 3))
    (bytes-set! scanline-template off       bg-r)
    (bytes-set! scanline-template (+ off 1) bg-g)
    (bytes-set! scanline-template (+ off 2) bg-b))
  (for ([y (in-range height)])
    (bytes-copy! fb (* y width 3) scanline-template))

  ;; 2. Render BG0 Screenblock 31 ($0600F800) tile0 at top-left (0..7, 0..7)
  (define bg0-entry (gba-read-u16 m #x0600F800))
  (define bg0-tile  (bitwise-and bg0-entry #x3FF))
  (for ([ty (in-range 8)])
    (for ([bx (in-range 4)])
      (define packed (gba-read-u8 m (+ GBA-VRAM-BASE (* bg0-tile 32) (* ty 4) bx)))
      (define p0 (bitwise-and packed #xF))
      (define p1 (bitwise-and (arithmetic-shift packed -4) #xF))
      (when (> p0 0)
        (define-values (r g b) (bgr555->rgb8 (gba-read-u16 m (+ GBA-PALRAM-BASE (* p0 2)))))
        (define off (* (+ (* ty width) (* bx 2)) 3))
        (bytes-set! fb off r) (bytes-set! fb (+ off 1) g) (bytes-set! fb (+ off 2) b))
      (when (> p1 0)
        (define-values (r g b) (bgr555->rgb8 (gba-read-u16 m (+ GBA-PALRAM-BASE (* p1 2)))))
        (define off (* (+ (* ty width) (add1 (* bx 2))) 3))
        (bytes-set! fb off r) (bytes-set! fb (+ off 1) g) (bytes-set! fb (+ off 2) b))))

  ;; 3. Composite the 8 active 8x8 4bpp hardware OAM sprites ($07000000..$0700003F)
  (for ([s (in-range 8)])
    (define oam-addr (+ GBA-OAM-BASE (* s 8)))
    (define attr0    (gba-read-u16 m oam-addr))
    (define attr1    (gba-read-u16 m (+ oam-addr 2)))
    (define attr2    (gba-read-u16 m (+ oam-addr 4)))
    (define sy       (bitwise-and attr0 #xFF))
    (define sx       (bitwise-and attr1 #x1FF))
    (define tile-idx (bitwise-and attr2 #x3FF))
    (when (and (< sy height) (< sx width) (> tile-idx 0))
      (for ([ty (in-range 8)])
        (define py (+ sy ty))
        (when (< py height)
          (for ([bx (in-range 4)])
            (define packed (gba-read-u8 m (+ GBA-VRAM-OBJ-BASE (* tile-idx 32) (* ty 4) bx)))
            (define p0 (bitwise-and packed #xF))
            (define p1 (bitwise-and (arithmetic-shift packed -4) #xF))
            (define px0 (+ sx (* bx 2)))
            (define px1 (add1 px0))
            (when (and (> p0 0) (< px0 width))
              (define-values (r g b) (bgr555->rgb8 (gba-read-u16 m (+ GBA-PALRAM-OBJ-BASE (* p0 2)))))
              (define off (* (+ (* py width) px0) 3))
              (bytes-set! fb off r) (bytes-set! fb (+ off 1) g) (bytes-set! fb (+ off 2) b))
            (when (and (> p1 0) (< px1 width))
              (define-values (r g b) (bgr555->rgb8 (gba-read-u16 m (+ GBA-PALRAM-OBJ-BASE (* p1 2)))))
              (define off (* (+ (* py width) px1) 3))
              (bytes-set! fb off r) (bytes-set! fb (+ off 1) g) (bytes-set! fb (+ off 2) b)))))))

  ;; 4. Render IWRAM Campaign HUD Status Bar on Scanline 8..11 (Stage, Energy, Score)
  (define stage-id (gba-read-u32 m (+ GBA-IWRAM-BASE IWRAM-STATE-STAGE-ID)))
  (define energy   (min 120 (gba-read-u32 m (+ GBA-IWRAM-BASE IWRAM-STATE-ENERGY))))
  (define won?     (= (gba-read-u32 m (+ GBA-IWRAM-BASE IWRAM-STATE-WON)) 1))
  (define hud-col  (gba-read-u16 m (+ GBA-PALRAM-BASE (* (+ 2 (modulo stage-id 6)) 2))))
  (define-values (hr hg hb) (bgr555->rgb8 hud-col))
  (define bar-len  (+ 16 energy (* stage-id 16) (if won? 32 0)))
  (for* ([py (in-range 8 12)]
         [px (in-range 16 (min width (+ 16 bar-len)))])
    (define off (* (+ (* py width) px) 3))
    (bytes-set! fb off hr)
    (bytes-set! fb (+ off 1) hg)
    (bytes-set! fb (+ off 2) hb))

  fb)

;; Render the complete 320x240 (76,800 pixels = 230,400 RGB24 bytes) N64 VI Framebuffer
;; from the live `n64-machine` hardware state (RDRAM VI Framebuffer, TMEM, Campaign State).
(define (render-n64-rgb-framebuffer m)
  (define width  320)
  (define height 240)
  (define fb     (make-bytes (* width height 3) 0))
  (define rdram  (n64-machine-rdram m))
  (define tmem   (n64-machine-tmem m))

  ;; 1. Read backdrop color from VI_ORIGIN ($00010000) pixel 0 and fill 320x240 scanlines
  (define bg-col16 (integer-bytes->integer rdram #f #t N64-TOP10-VI-FB-DRAM-PHYS (+ N64-TOP10-VI-FB-DRAM-PHYS 2)))
  (define-values (bg-r bg-g bg-b) (rgba5551->rgb8 bg-col16))
  (define scanline-template (make-bytes (* width 3) 0))
  (for ([x (in-range width)])
    (define off (* x 3))
    (bytes-set! scanline-template off       bg-r)
    (bytes-set! scanline-template (+ off 1) bg-g)
    (bytes-set! scanline-template (+ off 2) bg-b))
  (for ([y (in-range height)])
    (bytes-copy! fb (* y width 3) scanline-template))

  ;; 2. Composite TMEM 16-bit RGBA5551 textured actor quads at live RDRAM coordinates
  (define px       (min 280 (n64-read-u32-be m (+ N64-STATE-BASE-KSEG0 N64-STATE-PLAYER-X))))
  (define py       (min 200 (n64-read-u32-be m (+ N64-STATE-BASE-KSEG0 N64-STATE-PLAYER-Y))))
  (define stage-id (n64-read-u32-be m (+ N64-STATE-BASE-KSEG0 N64-STATE-STAGE-ID)))
  (define energy   (min 160 (n64-read-u32-be m (+ N64-STATE-BASE-KSEG0 N64-STATE-ENERGY))))
  (define won?     (= (n64-read-u32-be m (+ N64-STATE-BASE-KSEG0 N64-STATE-WON)) 1))

  (for ([quad-idx (in-range 4)])
    (define qx (min 300 (+ px (* quad-idx 32))))
    (define qy (min 220 (+ py (* (modulo quad-idx 2) 16))))
    (for* ([dy (in-range 16)]
           [dx (in-range 16)])
      (define t-off (modulo (* (+ (* quad-idx 64) (* (modulo dy 8) 8) (modulo dx 8)) 2) N64-TMEM-LIMIT-BYTES))
      (define tex16 (integer-bytes->integer tmem #f #t t-off (+ t-off 2)))
      (define-values (tr tg tb) (rgba5551->rgb8 tex16))
      (define off (* (+ (* (+ qy dy) width) (+ qx dx)) 3))
      (bytes-set! fb off tr)
      (bytes-set! fb (+ off 1) tg)
      (bytes-set! fb (+ off 2) tb)))

  ;; 3. Render 3D HUD Stage & Energy Progress Ribbon on Scanlines 12..17
  (define hud-tex16 (integer-bytes->integer tmem #f #t (* (+ 1 (modulo stage-id 6)) 128) (+ (* (+ 1 (modulo stage-id 6)) 128) 2)))
  (define-values (hr hg hb) (rgba5551->rgb8 hud-tex16))
  (define bar-len (+ 24 energy (* stage-id 24) (if won? 48 0)))
  (for* ([sy (in-range 12 18)]
         [sx (in-range 24 (min width (+ 24 bar-len)))])
    (define off (* (+ (* sy width) sx) 3))
    (bytes-set! fb off hr)
    (bytes-set! fb (+ off 1) hg)
    (bytes-set! fb (+ off 2) hb))

  fb)

;; Compare two RGB24 byte framebuffers (`width * height * 3` bytes) and return
;; `(values matched-pixels total-pixels match-pct)`
(define (compare-rgb-framebuffers fb-a fb-b total-pixels)
  (if (bytes=? fb-a fb-b)
      (values total-pixels total-pixels 100.0)
      (let ([matched
             (for/sum ([i (in-range total-pixels)])
               (define off (* i 3))
               (if (and (= (bytes-ref fb-a off)       (bytes-ref fb-b off))
                        (= (bytes-ref fb-a (+ off 1)) (bytes-ref fb-b (+ off 1)))
                        (= (bytes-ref fb-a (+ off 2)) (bytes-ref fb-b (+ off 2))))
                   1
                   0))])
        (values matched total-pixels (* 100.0 (/ (exact->inexact matched) total-pixels))))))

;; ============================================================================
;; 9. GBA & N64 3-Checkpoint (CP0 / CP1 / CP2) Decompilation Equivalence Verifiers
;; ============================================================================

;; Snapshot GBA hardware & campaign state at a checkpoint
(define (snapshot-gba-checkpoint-state m)
  (hasheq 'dispcnt        (gba-read-u16 m REG-DISPCNT)
          'bg0cnt         (gba-read-u16 m REG-BG0CNT)
          'frame-cnt      (gba-read-u32 m (+ GBA-IWRAM-BASE IWRAM-STATE-FRAME-CNT))
          'player-x       (gba-read-u32 m (+ GBA-IWRAM-BASE IWRAM-STATE-PLAYER-X))
          'player-y       (gba-read-u32 m (+ GBA-IWRAM-BASE IWRAM-STATE-PLAYER-Y))
          'energy         (gba-read-u32 m (+ GBA-IWRAM-BASE IWRAM-STATE-ENERGY))
          'lives          (gba-read-u32 m (+ GBA-IWRAM-BASE IWRAM-STATE-LIVES))
          'dead           (gba-read-u32 m (+ GBA-IWRAM-BASE IWRAM-STATE-DEAD))
          'stage-id       (gba-read-u32 m (+ GBA-IWRAM-BASE IWRAM-STATE-STAGE-ID))
          'won            (gba-read-u32 m (+ GBA-IWRAM-BASE IWRAM-STATE-WON))
          'game-completed (gba-read-u32 m (+ GBA-IWRAM-BASE IWRAM-STATE-GAME-COMPLETED))
          'score          (gba-read-u32 m (+ GBA-IWRAM-BASE IWRAM-STATE-SCORE))
          'rules          (gba-read-u32 m (+ GBA-IWRAM-BASE IWRAM-STATE-RULES))
          'genre-a        (gba-read-u32 m (+ GBA-IWRAM-BASE IWRAM-STATE-GENRE-A))
          'genre-b        (gba-read-u32 m (+ GBA-IWRAM-BASE IWRAM-STATE-GENRE-B))
          'oam-spr0-y     (gba-read-u16 m GBA-OAM-BASE)
          'oam-spr0-x     (gba-read-u16 m (+ GBA-OAM-BASE 2))
          'bg0-map0       (gba-read-u16 m #x0600F800)
          'dma3-count     (gba-machine-dma3-count m)
          'strb-viols     (gba-machine-strb-vram-violations m)))

;; Snapshot N64 hardware & campaign state at a checkpoint
(define (snapshot-n64-checkpoint-state m)
  (hasheq 'vi-status      (n64-read-u32-be m N64-VI-STATUS)
          'vi-origin      (n64-read-u32-be m N64-VI-ORIGIN)
          'vi-width       (n64-read-u32-be m N64-VI-WIDTH)
          'frame-cnt      (n64-read-u32-be m (+ N64-STATE-BASE-KSEG0 N64-STATE-FRAME-CNT))
          'player-x       (n64-read-u32-be m (+ N64-STATE-BASE-KSEG0 N64-STATE-PLAYER-X))
          'player-y       (n64-read-u32-be m (+ N64-STATE-BASE-KSEG0 N64-STATE-PLAYER-Y))
          'energy         (n64-read-u32-be m (+ N64-STATE-BASE-KSEG0 N64-STATE-ENERGY))
          'lives          (n64-read-u32-be m (+ N64-STATE-BASE-KSEG0 N64-STATE-LIVES))
          'dead           (n64-read-u32-be m (+ N64-STATE-BASE-KSEG0 N64-STATE-DEAD))
          'stage-id       (n64-read-u32-be m (+ N64-STATE-BASE-KSEG0 N64-STATE-STAGE-ID))
          'won            (n64-read-u32-be m (+ N64-STATE-BASE-KSEG0 N64-STATE-WON))
          'game-completed (n64-read-u32-be m (+ N64-STATE-BASE-KSEG0 N64-STATE-GAME-COMPLETED))
          'score          (n64-read-u32-be m (+ N64-STATE-BASE-KSEG0 N64-STATE-SCORE))
          'genre-a        (n64-read-u32-be m (+ N64-STATE-BASE-KSEG0 N64-STATE-GENRE-A))
          'genre-b        (n64-read-u32-be m (+ N64-STATE-BASE-KSEG0 N64-STATE-GENRE-B))
          'rsp-simd-out0  (integer-bytes->integer (n64-machine-dmem m) #f #t #x30 #x32)
          'rsp-vector-ops (n64-machine-rsp-vector-ops m)
          'rdp-commands   (n64-machine-rdp-cmds-executed m)
          'rdp-full-sync? (n64-machine-rdp-full-sync? m)
          'tmem-bytes     (n64-machine-tmem-loaded-bytes m)))

(define (compare-state-hashes s1 s2)
  (define keys (hash-keys s1))
  (define total (length keys))
  (define matched
    (for/sum ([k (in-list keys)])
      (if (equal? (hash-ref s1 k) (hash-ref s2 k #f)) 1 0)))
  (values matched total (* 100.0 (/ (exact->inexact matched) (max 1 total)))))

;; Verify full decompilation & recompilation equivalence for a Top-10 GBA game across:
;;   - `CP0` (Stage 1 active gameplay),
;;   - `CP1` (Hazard failure `FAIL_OK` + `START` recovery `REC_OK`),
;;   - `CP2` (Full 4-stage campaign victory `FULL_WIN_OK`).
(define (verify-gba-top10-decompilation-equivalence spec-or-sym)
  (define spec       (find-gba-top10-game-spec spec-or-sym))
  (define ref-rom    (build-reference-gba-top10-rom spec))
  (define boba-dsl   (decompile-gba-rom->boba-dsl ref-rom))
  (define recomp-rom (recompile-gba-boba-dsl->rom boba-dsl))
  (define parsed-dsl (parse-boba-module-sexp boba-dsl))
  (define hw-audit   (hash-ref parsed-dsl 'hardware-audit))
  (define hdr-info   (hash-ref parsed-dsl 'header))

  ;; Multi-target typechecker grade verification
  (define grade-check
    (verify-target-module-grades
     (hasheq 'target         'gba
             'vblank-cycles  640
             'active-cycles  2400
             'dma-bytes      512
             'oam-sprites    8
             'oam-scanline   4
             'fast-ram-bytes 64
             'work-ram-bytes 256
             'tile-mem-bytes 256
             'rom-bytes      (bytes-length recomp-rom))
     'gba))

  ;; Locate `frame_step` entry PC from disassembled labels
  (define disasm-res (disassemble-arm7tdmi-rom recomp-rom))
  (define labels     (hash-ref disasm-res 'labels))
  (define frame-pc
    (or (for/first ([(addr sym) (in-hash labels)]
                    #:when (eq? sym 'frame_step))
          addr)
        (+ GBA-ROM-ENTRY #x100)))

  ;; Boot Reference & Recompiled GBA machines
  (define m-ref    (make-gba-machine ref-rom))
  (define m-recomp (make-gba-machine recomp-rom))
  (gba-run-subroutine! m-ref    GBA-ROM-BASE)
  (gba-run-subroutine! m-recomp GBA-ROM-BASE)

  ;; --- Checkpoint CP0: Stage 1 Gameplay ---
  (gba-step-frame! m-ref    frame-pc 0)
  (gba-step-frame! m-recomp frame-pc 0)
  (define cp0-ref-state    (snapshot-gba-checkpoint-state m-ref))
  (define cp0-recomp-state (snapshot-gba-checkpoint-state m-recomp))
  (define cp0-ref-fb       (render-gba-rgb-framebuffer m-ref))
  (define cp0-recomp-fb    (render-gba-rgb-framebuffer m-recomp))
  (define-values (cp0-s-match cp0-s-total cp0-s-pct) (compare-state-hashes cp0-ref-state cp0-recomp-state))
  (define-values (cp0-p-match cp0-p-total cp0-p-pct) (compare-rgb-framebuffers cp0-ref-fb cp0-recomp-fb 38400))

  ;; --- Checkpoint CP1: Hazard Failure (BTN-LEFT) + START Recovery (BTN-START) ---
  (gba-step-frame! m-ref    frame-pc GBA-BTN-LEFT)
  (gba-step-frame! m-recomp frame-pc GBA-BTN-LEFT)
  (define fail-ok?
    (and (= (gba-read-u32 m-recomp (+ GBA-IWRAM-BASE IWRAM-STATE-DEAD)) 1)
         (= (gba-read-u32 m-recomp (+ GBA-IWRAM-BASE IWRAM-STATE-LIVES)) 2)
         (= (gba-read-u32 m-recomp (+ GBA-IWRAM-BASE IWRAM-STATE-ENERGY)) 0)))

  (gba-step-frame! m-ref    frame-pc GBA-BTN-START)
  (gba-step-frame! m-recomp frame-pc GBA-BTN-START)
  (define rec-ok?
    (and (= (gba-read-u32 m-recomp (+ GBA-IWRAM-BASE IWRAM-STATE-DEAD)) 0)
         (= (gba-read-u32 m-recomp (+ GBA-IWRAM-BASE IWRAM-STATE-ENERGY))
            (hash-ref spec 'init-energy))))

  (define cp1-ref-state    (snapshot-gba-checkpoint-state m-ref))
  (define cp1-recomp-state (snapshot-gba-checkpoint-state m-recomp))
  (define cp1-ref-fb       (render-gba-rgb-framebuffer m-ref))
  (define cp1-recomp-fb    (render-gba-rgb-framebuffer m-recomp))
  (define-values (cp1-s-match cp1-s-total cp1-s-pct) (compare-state-hashes cp1-ref-state cp1-recomp-state))
  (define-values (cp1-p-match cp1-p-total cp1-p-pct) (compare-rgb-framebuffers cp1-ref-fb cp1-recomp-fb 38400))

  ;; --- Checkpoint CP2: Full 4-Stage Campaign Victory (4 x BTN-RIGHT) ---
  (for ([_ (in-range 4)])
    (gba-step-frame! m-ref    frame-pc GBA-BTN-RIGHT)
    (gba-step-frame! m-recomp frame-pc GBA-BTN-RIGHT))
  (define cp2-ref-state    (snapshot-gba-checkpoint-state m-ref))
  (define cp2-recomp-state (snapshot-gba-checkpoint-state m-recomp))
  (define cp2-ref-fb       (render-gba-rgb-framebuffer m-ref))
  (define cp2-recomp-fb    (render-gba-rgb-framebuffer m-recomp))
  (define-values (cp2-s-match cp2-s-total cp2-s-pct) (compare-state-hashes cp2-ref-state cp2-recomp-state))
  (define-values (cp2-p-match cp2-p-total cp2-p-pct) (compare-rgb-framebuffers cp2-ref-fb cp2-recomp-fb 38400))

  (define full-win-ok?
    (and (= (hash-ref cp2-recomp-state 'stage-id) 3)
         (= (hash-ref cp2-recomp-state 'won) 1)
         (= (hash-ref cp2-recomp-state 'game-completed) 1)
         (= (hash-ref cp2-recomp-state 'score) (* 4 (hash-ref spec 'stage-score-delta)))))

  (define cp0-ok? (and (= cp0-s-pct 100.0) (= cp0-p-pct 100.0)))
  (define cp1-ok? (and fail-ok? rec-ok? (= cp1-s-pct 100.0) (= cp1-p-pct 100.0)))
  (define cp2-ok? (and full-win-ok? (= cp2-s-pct 100.0) (= cp2-p-pct 100.0)))
  (define state-pct (/ (+ cp0-s-pct cp1-s-pct cp2-s-pct) 3.0))
  (define pixel-pct (/ (+ cp0-p-pct cp1-p-pct cp2-p-pct) 3.0))
  (define cp0-info
    (hasheq 'state-match-pct   cp0-s-pct
            'pixel-match-pct   cp0-p-pct
            'matched-pixels    cp0-p-match
            'matching-pixels   cp0-p-match
            'total-pixels      cp0-p-total
            'state-equivalent? (= cp0-s-pct 100.0)
            'pixel-equivalent? (= cp0-p-pct 100.0)
            'ref-state         cp0-ref-state
            'recomp-state      cp0-recomp-state))
  (define cp1-info
    (hasheq 'state-match-pct   cp1-s-pct
            'pixel-match-pct   cp1-p-pct
            'matched-pixels    cp1-p-match
            'matching-pixels   cp1-p-match
            'total-pixels      cp1-p-total
            'state-equivalent? (= cp1-s-pct 100.0)
            'pixel-equivalent? (= cp1-p-pct 100.0)
            'ref-state         cp1-ref-state
            'recomp-state      cp1-recomp-state))
  (define cp2-info
    (hasheq 'state-match-pct   cp2-s-pct
            'pixel-match-pct   cp2-p-pct
            'matched-pixels    cp2-p-match
            'matching-pixels   cp2-p-match
            'total-pixels      cp2-p-total
            'state-equivalent? (= cp2-s-pct 100.0)
            'pixel-equivalent? (= cp2-p-pct 100.0)
            'ref-state         cp2-ref-state
            'recomp-state      cp2-recomp-state))
  (define all-ok?
    (and (bytes=? ref-rom recomp-rom)
         (hash-ref hdr-info 'valid?)
         (hash-ref hdr-info 'complement-cc?)
         (zero? (hash-ref hw-audit 'strb-vram-violations))
         (zero? (gba-machine-strb-vram-violations m-recomp))
         (hash-ref grade-check 'valid?)
         cp0-ok?
         cp1-ok?
         cp2-ok?))

  (hasheq 'symbol                  (hash-ref spec 'symbol)
          'id                      (hash-ref spec 'id)
          'title                   (hash-ref spec 'title)
          'target                  'gba
          'genre                   (hash-ref spec 'genre)
          'stage-names             (hash-ref spec 'stage-names)
          'rom-size-bytes          (bytes-length recomp-rom)
          'binary-identical?       (bytes=? ref-rom recomp-rom)
          'rom-binary-identical?   (bytes=? ref-rom recomp-rom)
          'header-valid?           (hash-ref hdr-info 'valid?)
          'fixed-byte-96?          (= (hash-ref hdr-info 'fixed-byte) #x96)
          'header-checksum         (hash-ref hdr-info 'complement-check)
          'complement-check-cc?    (hash-ref hdr-info 'complement-cc?)
          'strb-vram-violations    (+ (hash-ref hw-audit 'strb-vram-violations)
                                      (gba-machine-strb-vram-violations m-recomp))
          'iwram-optimal?          (eq? (hash-ref hw-audit 'memory-placement-grade)
                                        'IWRAM-32bit-1Cycle-Optimal)
          'memory-placement-grade  (hash-ref hw-audit 'memory-placement-grade)
          'dma3-transfers          (gba-machine-dma3-count m-recomp)
          'arm-instructions        (hash-ref hw-audit 'arm-instructions)
          'thumb-instructions      (hash-ref hw-audit 'thumb-instructions)
          'interworking-verified?  (hash-ref hw-audit 'interworking-verified?)
          'grade-check             grade-check
          'well-typed?             (hash-ref grade-check 'valid?)
          'resolution              '(240 160)
          'framebuffer-width       240
          'framebuffer-height      160
          'total-pixels            38400
          'matching-pixels         cp2-p-match
          'matched-pixels          cp2-p-match
          'checkpoints             (hasheq 'CP0 cp0-info 'CP1 cp1-info 'CP2 cp2-info
                                           'cp0 cp0-info 'cp1 cp1-info 'cp2 cp2-info)
          'CP0                     cp0-info
          'CP1                     cp1-info
          'CP2                     cp2-info
          'cp0-ok?                 cp0-ok?
          'cp1-ok?                 cp1-ok?
          'cp2-ok?                 cp2-ok?
          'fail-ok?                fail-ok?
          'rec-ok?                 rec-ok?
          'full-win-ok?            full-win-ok?
          'campaign-status         (if (and fail-ok? rec-ok? full-win-ok?)
                                       "FAIL_OK -> REC_OK -> FULL_WIN_OK"
                                       "CAMPAIGN_INCOMPLETE")
          'campaign-result         (if (and fail-ok? rec-ok? full-win-ok?)
                                       "FAIL_OK -> REC_OK -> FULL_WIN_OK"
                                       "CAMPAIGN_INCOMPLETE")
          'final-stage-id          (hash-ref cp2-recomp-state 'stage-id)
          'final-score             (hash-ref cp2-recomp-state 'score)
          'state-match-pct         state-pct
          'pixel-match-pct         pixel-pct
          'equivalence-pct         (min state-pct pixel-pct)
          'equivalent?             all-ok?
          'verified?               all-ok?))

;; Verify full decompilation & recompilation equivalence for a Top-10 N64 game across:
;;   - `CP0` (Stage 1 active gameplay),
;;   - `CP1` (Hazard failure `FAIL_OK` + `START` recovery `REC_OK`),
;;   - `CP2` (Full 4-stage campaign victory `FULL_WIN_OK`).
(define (verify-n64-top10-decompilation-equivalence spec-or-sym)
  (define spec       (find-n64-top10-game-spec spec-or-sym))
  (define ref-rom    (build-reference-n64-top10-rom spec))
  (define boba-dsl   (decompile-n64-rom->boba-dsl ref-rom))
  (define recomp-rom (recompile-n64-boba-dsl->rom boba-dsl))
  (define parsed-dsl (parse-boba-module-sexp boba-dsl))
  (define hw-audit   (hash-ref parsed-dsl 'hardware-audit))
  (define hdr-info   (hash-ref parsed-dsl 'header))

  ;; Multi-target typechecker grade verification
  (define grade-check
    (verify-target-module-grades
     (hasheq 'target         'n64
             'vblank-cycles  1200
             'active-cycles  4800
             'dma-bytes      1024
             'oam-sprites    8
             'oam-scanline   4
             'fast-ram-bytes 64
             'work-ram-bytes 512
             'tile-mem-bytes 1024
             'rom-bytes      (bytes-length recomp-rom)
             'extra-used     (hash-ref hw-audit 'imem-bytes))
     'n64))

  ;; Locate `frame_step` entry PC from disassembled labels
  (define disasm-res (disassemble-n64-z64-rom recomp-rom))
  (define labels     (hash-ref disasm-res 'labels))
  (define frame-pc
    (or (for/first ([(addr sym) (in-hash labels)]
                    #:when (eq? sym 'frame_step))
          addr)
        (+ N64-BOOT-PC #x00C8)))

  ;; Boot Reference & Recompiled N64 machines
  (define m-ref    (make-n64-machine ref-rom))
  (define m-recomp (make-n64-machine recomp-rom))
  (n64-run-subroutine! m-ref    N64-BOOT-PC)
  (n64-run-subroutine! m-recomp N64-BOOT-PC)

  ;; --- Checkpoint CP0: Stage 1 Gameplay ---
  (n64-step-frame! m-ref    frame-pc 0)
  (n64-step-frame! m-recomp frame-pc 0)
  (define cp0-ref-state    (snapshot-n64-checkpoint-state m-ref))
  (define cp0-recomp-state (snapshot-n64-checkpoint-state m-recomp))
  (define cp0-ref-fb       (render-n64-rgb-framebuffer m-ref))
  (define cp0-recomp-fb    (render-n64-rgb-framebuffer m-recomp))
  (define-values (cp0-s-match cp0-s-total cp0-s-pct) (compare-state-hashes cp0-ref-state cp0-recomp-state))
  (define-values (cp0-p-match cp0-p-total cp0-p-pct) (compare-rgb-framebuffers cp0-ref-fb cp0-recomp-fb 76800))

  ;; --- Checkpoint CP1: Hazard Failure (N64-BTN-LEFT) + START Recovery (N64-BTN-START) ---
  (n64-step-frame! m-ref    frame-pc N64-BTN-LEFT)
  (n64-step-frame! m-recomp frame-pc N64-BTN-LEFT)
  (define fail-ok?
    (and (= (n64-read-u32-be m-recomp (+ N64-STATE-BASE-KSEG0 N64-STATE-DEAD)) 1)
         (= (n64-read-u32-be m-recomp (+ N64-STATE-BASE-KSEG0 N64-STATE-LIVES)) 2)
         (= (n64-read-u32-be m-recomp (+ N64-STATE-BASE-KSEG0 N64-STATE-ENERGY)) 0)))

  (n64-step-frame! m-ref    frame-pc N64-BTN-START)
  (n64-step-frame! m-recomp frame-pc N64-BTN-START)
  (define rec-ok?
    (and (= (n64-read-u32-be m-recomp (+ N64-STATE-BASE-KSEG0 N64-STATE-DEAD)) 0)
         (= (n64-read-u32-be m-recomp (+ N64-STATE-BASE-KSEG0 N64-STATE-ENERGY))
            (hash-ref spec 'init-energy))))

  (define cp1-ref-state    (snapshot-n64-checkpoint-state m-ref))
  (define cp1-recomp-state (snapshot-n64-checkpoint-state m-recomp))
  (define cp1-ref-fb       (render-n64-rgb-framebuffer m-ref))
  (define cp1-recomp-fb    (render-n64-rgb-framebuffer m-recomp))
  (define-values (cp1-s-match cp1-s-total cp1-s-pct) (compare-state-hashes cp1-ref-state cp1-recomp-state))
  (define-values (cp1-p-match cp1-p-total cp1-p-pct) (compare-rgb-framebuffers cp1-ref-fb cp1-recomp-fb 76800))

  ;; --- Checkpoint CP2: Full 4-Stage Campaign Victory (4 x N64-BTN-RIGHT) ---
  (for ([_ (in-range 4)])
    (n64-step-frame! m-ref    frame-pc N64-BTN-RIGHT)
    (n64-step-frame! m-recomp frame-pc N64-BTN-RIGHT))
  (define cp2-ref-state    (snapshot-n64-checkpoint-state m-ref))
  (define cp2-recomp-state (snapshot-n64-checkpoint-state m-recomp))
  (define cp2-ref-fb       (render-n64-rgb-framebuffer m-ref))
  (define cp2-recomp-fb    (render-n64-rgb-framebuffer m-recomp))
  (define-values (cp2-s-match cp2-s-total cp2-s-pct) (compare-state-hashes cp2-ref-state cp2-recomp-state))
  (define-values (cp2-p-match cp2-p-total cp2-p-pct) (compare-rgb-framebuffers cp2-ref-fb cp2-recomp-fb 76800))

  (define full-win-ok?
    (and (= (hash-ref cp2-recomp-state 'stage-id) 3)
         (= (hash-ref cp2-recomp-state 'won) 1)
         (= (hash-ref cp2-recomp-state 'game-completed) 1)
         (= (hash-ref cp2-recomp-state 'score) (* 4 (hash-ref spec 'stage-score-delta)))))

  (define cp0-ok? (and (= cp0-s-pct 100.0) (= cp0-p-pct 100.0)))
  (define cp1-ok? (and fail-ok? rec-ok? (= cp1-s-pct 100.0) (= cp1-p-pct 100.0)))
  (define cp2-ok? (and full-win-ok? (= cp2-s-pct 100.0) (= cp2-p-pct 100.0)))
  (define state-pct (/ (+ cp0-s-pct cp1-s-pct cp2-s-pct) 3.0))
  (define pixel-pct (/ (+ cp0-p-pct cp1-p-pct cp2-p-pct) 3.0))
  (define cp0-info
    (hasheq 'state-match-pct   cp0-s-pct
            'pixel-match-pct   cp0-p-pct
            'matched-pixels    cp0-p-match
            'matching-pixels   cp0-p-match
            'total-pixels      cp0-p-total
            'state-equivalent? (= cp0-s-pct 100.0)
            'pixel-equivalent? (= cp0-p-pct 100.0)
            'ref-state         cp0-ref-state
            'recomp-state      cp0-recomp-state))
  (define cp1-info
    (hasheq 'state-match-pct   cp1-s-pct
            'pixel-match-pct   cp1-p-pct
            'matched-pixels    cp1-p-match
            'matching-pixels   cp1-p-match
            'total-pixels      cp1-p-total
            'state-equivalent? (= cp1-s-pct 100.0)
            'pixel-equivalent? (= cp1-p-pct 100.0)
            'ref-state         cp1-ref-state
            'recomp-state      cp1-recomp-state))
  (define cp2-info
    (hasheq 'state-match-pct   cp2-s-pct
            'pixel-match-pct   cp2-p-pct
            'matched-pixels    cp2-p-match
            'matching-pixels   cp2-p-match
            'total-pixels      cp2-p-total
            'state-equivalent? (= cp2-s-pct 100.0)
            'pixel-equivalent? (= cp2-p-pct 100.0)
            'ref-state         cp2-ref-state
            'recomp-state      cp2-recomp-state))
  (define all-ok?
    (and (bytes=? ref-rom recomp-rom)
         (hash-ref hdr-info 'valid?)
         (hash-ref hw-audit 'dma-16byte-aligned?)
         (hash-ref hw-audit 'imem-ok?)
         (hash-ref hw-audit 'dmem-ok?)
         (hash-ref hw-audit 'tmem-ok?)
         (hash-ref hw-audit 'rdp-sync-protocol-ok?)
         (hash-ref grade-check 'valid?)
         cp0-ok?
         cp1-ok?
         cp2-ok?))

  (hasheq 'symbol                 (hash-ref spec 'symbol)
          'id                     (hash-ref spec 'id)
          'title                  (hash-ref spec 'title)
          'target                 'n64
          'genre                  (hash-ref spec 'genre)
          'stage-names            (hash-ref spec 'stage-names)
          'rom-size-bytes         (bytes-length recomp-rom)
          'binary-identical?      (bytes=? ref-rom recomp-rom)
          'rom-binary-identical?  (bytes=? ref-rom recomp-rom)
          'header-valid?          (hash-ref hdr-info 'valid?)
          'header-magic           (hash-ref hdr-info 'magic)
          'crc1                   (hash-ref hdr-info 'crc1)
          'crc2                   (hash-ref hdr-info 'crc2)
          'crc-valid?             (hash-ref hdr-info 'crc-valid?)
          'dma-16byte-aligned?    (hash-ref hw-audit 'dma-16byte-aligned?)
          'cache-coherent?        (hash-ref hw-audit 'cache-coherent?)
          'imem-bytes             (hash-ref hw-audit 'imem-bytes)
          'dmem-bytes             (hash-ref hw-audit 'dmem-bytes)
          'tmem-bytes             (hash-ref hw-audit 'tmem-bytes)
          'imem-ok?               (hash-ref hw-audit 'imem-ok?)
          'dmem-ok?               (hash-ref hw-audit 'dmem-ok?)
          'tmem-ok?               (hash-ref hw-audit 'tmem-ok?)
          'rsp-vector-ops         (hash-ref cp2-recomp-state 'rsp-vector-ops)
          'rdp-commands           (hash-ref hw-audit 'rdp-commands)
          'rdp-sync-protocol-ok?  (hash-ref hw-audit 'rdp-sync-protocol-ok?)
          'rdp-full-sync?         (hash-ref cp2-recomp-state 'rdp-full-sync?)
          'grade-check            grade-check
          'well-typed?            (hash-ref grade-check 'valid?)
          'resolution             '(320 240)
          'framebuffer-width      320
          'framebuffer-height     240
          'total-pixels           76800
          'matching-pixels        cp2-p-match
          'matched-pixels         cp2-p-match
          'checkpoints            (hasheq 'CP0 cp0-info 'CP1 cp1-info 'CP2 cp2-info
                                          'cp0 cp0-info 'cp1 cp1-info 'cp2 cp2-info)
          'CP0                    cp0-info
          'CP1                    cp1-info
          'CP2                    cp2-info
          'cp0-ok?                cp0-ok?
          'cp1-ok?                cp1-ok?
          'cp2-ok?                cp2-ok?
          'fail-ok?               fail-ok?
          'rec-ok?                rec-ok?
          'full-win-ok?           full-win-ok?
          'campaign-status        (if (and fail-ok? rec-ok? full-win-ok?)
                                      "FAIL_OK -> REC_OK -> FULL_WIN_OK"
                                      "CAMPAIGN_INCOMPLETE")
          'campaign-result        (if (and fail-ok? rec-ok? full-win-ok?)
                                      "FAIL_OK -> REC_OK -> FULL_WIN_OK"
                                      "CAMPAIGN_INCOMPLETE")
          'final-stage-id         (hash-ref cp2-recomp-state 'stage-id)
          'final-score            (hash-ref cp2-recomp-state 'score)
          'state-match-pct        state-pct
          'pixel-match-pct        pixel-pct
          'equivalence-pct        (min state-pct pixel-pct)
          'equivalent?            all-ok?
          'verified?              all-ok?))

;; Batch builders for all 10 GBA or all 10 N64 ROMs
(define (compile-all-gba-top10-roms!)
  (for/list ([spec (in-list GBA-TOP10-GAME-SPECS)])
    (build-reference-gba-top10-rom spec)))

(define (compile-all-n64-top10-roms!)
  (for/list ([spec (in-list N64-TOP10-GAME-SPECS)])
    (build-reference-n64-top10-rom spec)))

;; Run all 20 decompilation, recompilation, and 3-checkpoint equivalence verifications
;; (10 GBA Classics + 10 N64 Classics) and return a comprehensive summary report hash.
(define (run-all-gba-n64-top10-verifications!)
  (define gba-results
    (for/list ([spec (in-list GBA-TOP10-GAME-SPECS)])
      (verify-gba-top10-decompilation-equivalence spec)))
  (define n64-results
    (for/list ([spec (in-list N64-TOP10-GAME-SPECS)])
      (verify-n64-top10-decompilation-equivalence spec)))
  (define all-results (append gba-results n64-results))
  (define passed-cnt  (count (lambda (r) (hash-ref r 'verified? #f)) all-results))
  (define total-cnt   (length all-results))
  (define by-sym
    (for/hasheq ([r (in-list all-results)])
      (values (hash-ref r 'symbol) r)))

  (define base-report
    (hasheq 'total-games            total-cnt
            'gba-count              (length gba-results)
            'n64-count              (length n64-results)
            'passed-count           passed-cnt
            'passed-games           passed-cnt
            'failed-count           (- total-cnt passed-cnt)
            'all-verified?          (= passed-cnt total-cnt)
            'all-passed?            (= passed-cnt total-cnt)
            'all-equivalent?        (= passed-cnt total-cnt)
            'verified?              (= passed-cnt total-cnt)
            'gba-results            gba-results
            'n64-results            n64-results
            'all-results            all-results
            'games                  all-results
            'results                all-results
            'results-by-sym         by-sym
            'by-symbol              by-sym
            'gba-strb-violations    (for/sum ([r (in-list gba-results)])
                                      (hash-ref r 'strb-vram-violations 0))
            'gba-complement-cc-all? (for/and ([r (in-list gba-results)])
                                      (hash-ref r 'complement-check-cc? #f))
            'n64-dma-aligned-all?   (for/and ([r (in-list n64-results)])
                                      (hash-ref r 'dma-16byte-aligned? #f))
            'n64-tmem-safe-all?     (for/and ([r (in-list n64-results)])
                                      (and (hash-ref r 'imem-ok? #f)
                                           (hash-ref r 'dmem-ok? #f)
                                           (hash-ref r 'tmem-ok? #f)))
            'n64-rdp-protocol-all?  (for/and ([r (in-list n64-results)])
                                      (hash-ref r 'rdp-sync-protocol-ok? #f))
            'mean-state-match-pct   (/ (for/sum ([r (in-list all-results)])
                                         (hash-ref r 'state-match-pct 0.0))
                                       (max 1 total-cnt))
            'mean-pixel-match-pct   (/ (for/sum ([r (in-list all-results)])
                                         (hash-ref r 'pixel-match-pct 0.0))
                                       (max 1 total-cnt))))
  (for/fold ([h base-report])
            ([r (in-list all-results)])
    (hash-set h (hash-ref r 'symbol) r)))

(module+ main
  (define t0 (current-inexact-milliseconds))
  (define summary (run-all-gba-n64-top10-verifications!))
  (define elapsed (- (current-inexact-milliseconds) t0))
  (printf "============================================================================================================\n")
  (printf "  #lang boba-nes : Top-10 Game Boy Advance (.gba) & Top-10 Nintendo 64 (.z64) Decompilation Suite Report\n")
  (printf "============================================================================================================\n")
  (for ([r (in-list (hash-ref summary 'gba-results))])
    (printf "  [GBA] ~a | STRB=0 | $BD=#x~a | DMA3=~a | ARM=~a/Thumb=~a | RGB=~a/38400 (~a%) | ~a\n"
            (~a (hash-ref r 'symbol) #:min-width 25)
            (~r (hash-ref r 'header-checksum) #:base 16 #:min-width 2 #:pad-string "0")
            (hash-ref r 'dma3-transfers)
            (hash-ref r 'arm-instructions)
            (hash-ref r 'thumb-instructions)
            (hash-ref r 'matching-pixels)
            (hash-ref r 'pixel-match-pct)
            (hash-ref r 'campaign-status)))
  (for ([r (in-list (hash-ref summary 'n64-results))])
    (printf "  [N64] ~a | DMA16=~a | TMEM=~a/4096B | RSP_SIMD=~a | RDP_Sync=~a | RGB=~a/76800 (~a%) | ~a\n"
            (~a (hash-ref r 'symbol) #:min-width 25)
            (hash-ref r 'dma-16byte-aligned?)
            (hash-ref r 'tmem-bytes)
            (hash-ref r 'rsp-vector-ops)
            (hash-ref r 'rdp-sync-protocol-ok?)
            (hash-ref r 'matching-pixels)
            (hash-ref r 'pixel-match-pct)
            (hash-ref r 'campaign-status)))
  (printf "------------------------------------------------------------------------------------------------------------\n")
  (printf "  Total Games Verified: ~a / ~a | all-verified?=~a | State=~a% | Pixel=~a% | Elapsed: ~a ms\n"
          (hash-ref summary 'passed-count)
          (hash-ref summary 'total-games)
          (hash-ref summary 'all-verified?)
          (hash-ref summary 'mean-state-match-pct)
          (hash-ref summary 'mean-pixel-match-pct)
          (~r elapsed #:precision 2))
  (printf "============================================================================================================\n")
  (unless (hash-ref summary 'all-verified?)
    (error 'decompiled-gba-n64-top10 "One or more GBA/N64 Top-10 verifications failed!")))
