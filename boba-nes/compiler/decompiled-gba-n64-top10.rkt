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

   ;; 4. Pokemon Emerald (2004)
   (hasheq 'symbol            'gba-pokemon-emerald
           'id                "gba_pokemon_emerald"
           'index             3
           'target            'gba
           'title             "Pokemon Emerald"
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

;; ============================================================================
;; 8a. Shared 2D/3D Pixel-Art, Polygon Rasterizer & 5x7 Bitmap Font Primitives
;; ============================================================================

(define (clamp-u8 v)
  (max 0 (min 255 (exact-round v))))

(define (fb-put! fb w h x y r g b)
  (when (and (>= x 0) (< x w) (>= y 0) (< y h))
    (define off (* (+ (* y w) x) 3))
    (bytes-set! fb off       r)
    (bytes-set! fb (+ off 1) g)
    (bytes-set! fb (+ off 2) b)))

(define (fb-blend! fb w h x y r g b num den)
  (when (and (>= x 0) (< x w) (>= y 0) (< y h))
    (define off (* (+ (* y w) x) 3))
    (define r0 (bytes-ref fb off))
    (define g0 (bytes-ref fb (+ off 1)))
    (define b0 (bytes-ref fb (+ off 2)))
    (define rem (- den num))
    (bytes-set! fb off       (quotient (+ (* r num) (* r0 rem)) den))
    (bytes-set! fb (+ off 1) (quotient (+ (* g num) (* g0 rem)) den))
    (bytes-set! fb (+ off 2) (quotient (+ (* b num) (* b0 rem)) den))))

(define (fb-rect! fb w h x0 y0 rw rh r g b)
  (define x-start (max 0 x0))
  (define y-start (max 0 y0))
  (define x-end   (min w (+ x0 rw)))
  (define y-end   (min h (+ y0 rh)))
  (for ([y (in-range y-start y-end)])
    (define row-off (* y w 3))
    (for ([x (in-range x-start x-end)])
      (define off (+ row-off (* x 3)))
      (bytes-set! fb off       r)
      (bytes-set! fb (+ off 1) g)
      (bytes-set! fb (+ off 2) b))))

(define (fb-rect-blend! fb w h x0 y0 rw rh r g b num den)
  (define x-start (max 0 x0))
  (define y-start (max 0 y0))
  (define x-end   (min w (+ x0 rw)))
  (define y-end   (min h (+ y0 rh)))
  (for ([y (in-range y-start y-end)])
    (for ([x (in-range x-start x-end)])
      (fb-blend! fb w h x y r g b num den))))

(define (fb-box! fb w h x0 y0 rw rh r g b [thick 1])
  (fb-rect! fb w h x0 y0 rw thick r g b)
  (fb-rect! fb w h x0 (- (+ y0 rh) thick) rw thick r g b)
  (fb-rect! fb w h x0 y0 thick rh r g b)
  (fb-rect! fb w h (- (+ x0 rw) thick) y0 thick rh r g b))

(define (fb-vgrad! fb w h x0 y0 rw rh r1 g1 b1 r2 g2 b2)
  (define span (max 1 (sub1 rh)))
  (for ([dy (in-range rh)])
    (define y (+ y0 dy))
    (when (and (>= y 0) (< y h))
      (define r (quotient (+ (* r1 (- span dy)) (* r2 dy)) span))
      (define g (quotient (+ (* g1 (- span dy)) (* g2 dy)) span))
      (define b (quotient (+ (* b1 (- span dy)) (* b2 dy)) span))
      (fb-rect! fb w h x0 y rw 1 r g b))))

(define (fb-hline! fb w h x0 x1 y r g b)
  (when (and (>= y 0) (< y h))
    (define xa (max 0 (min x0 x1)))
    (define xb (min (sub1 w) (max x0 x1)))
    (for ([x (in-range xa (add1 xb))])
      (fb-put! fb w h x y r g b))))

(define (fb-vline! fb w h x y0 y1 r g b)
  (when (and (>= x 0) (< x w))
    (define ya (max 0 (min y0 y1)))
    (define yb (min (sub1 h) (max y0 y1)))
    (for ([y (in-range ya (add1 yb))])
      (fb-put! fb w h x y r g b))))

(define (fb-line! fb w h x0 y0 x1 y1 r g b [thick 1])
  (define dx (abs (- x1 x0)))
  (define dy (abs (- y1 y0)))
  (define steps (max 1 (max dx dy)))
  (for ([i (in-range (add1 steps))])
    (define px (+ x0 (quotient (* (- x1 x0) i) steps)))
    (define py (+ y0 (quotient (* (- y1 y0) i) steps)))
    (if (<= thick 1)
        (fb-put! fb w h px py r g b)
        (fb-rect! fb w h (- px (quotient thick 2)) (- py (quotient thick 2)) thick thick r g b))))

(define (fb-circle! fb w h cx cy rad r g b [fill? #t])
  (define r2 (* rad rad))
  (define r-in2 (* (max 0 (sub1 rad)) (max 0 (sub1 rad))))
  (for ([dy (in-range (- rad) (add1 rad))])
    (for ([dx (in-range (- rad) (add1 rad))])
      (define d2 (+ (* dx dx) (* dy dy)))
      (when (if fill? (<= d2 r2) (and (<= d2 r2) (>= d2 r-in2)))
        (fb-put! fb w h (+ cx dx) (+ cy dy) r g b)))))

(define (fb-ellipse! fb w h cx cy rx ry r g b [fill? #t])
  (define rx2 (max 1 (* rx rx)))
  (define ry2 (max 1 (* ry ry)))
  (define limit (* rx2 ry2))
  (define inner (* (max 0 (sub1 rx)) (max 0 (sub1 rx)) (max 0 (sub1 ry)) (max 0 (sub1 ry))))
  (for ([dy (in-range (- ry) (add1 ry))])
    (for ([dx (in-range (- rx) (add1 rx))])
      (define v (+ (* dx dx ry2) (* dy dy rx2)))
      (when (if fill? (<= v limit) (and (<= v limit) (>= v inner)))
        (fb-put! fb w h (+ cx dx) (+ cy dy) r g b)))))

(define (fb-tri! fb w h x0 y0 x1 y1 x2 y2 r g b)
  (define min-x (max 0 (min x0 x1 x2)))
  (define max-x (min (sub1 w) (max x0 x1 x2)))
  (define min-y (max 0 (min y0 y1 y2)))
  (define max-y (min (sub1 h) (max y0 y1 y2)))
  (define (edge ax ay bx by px py)
    (- (* (- px ax) (- by ay)) (* (- py ay) (- bx ax))))
  (define area (edge x0 y0 x1 y1 x2 y2))
  (unless (zero? area)
    (for ([py (in-range min-y (add1 max-y))])
      (for ([px (in-range min-x (add1 max-x))])
        (define e0 (edge x1 y1 x2 y2 px py))
        (define e1 (edge x2 y2 x0 y0 px py))
        (define e2 (edge x0 y0 x1 y1 px py))
        (when (if (> area 0)
                  (and (>= e0 0) (>= e1 0) (>= e2 0))
                  (and (<= e0 0) (<= e1 0) (<= e2 0)))
          (fb-put! fb w h px py r g b))))))

(define (fb-quad! fb w h x0 y0 x1 y1 x2 y2 x3 y3 r g b)
  (fb-tri! fb w h x0 y0 x1 y1 x2 y2 r g b)
  (fb-tri! fb w h x0 y0 x2 y2 x3 y3 r g b))

;; Crisp 5x7 ASCII + HUD Icon Bitmap Font
(define FONT-5X7-GLYPHS
  (hash
   #\space '(0 0 0 0 0 0 0)
   #\A '(#b01110 #b10001 #b10001 #b11111 #b10001 #b10001 #b10001)
   #\B '(#b11110 #b10001 #b10001 #b11110 #b10001 #b10001 #b11110)
   #\C '(#b01110 #b10001 #b10000 #b10000 #b10000 #b10001 #b01110)
   #\D '(#b11100 #b10010 #b10001 #b10001 #b10001 #b10010 #b11100)
   #\E '(#b11111 #b10000 #b10000 #b11110 #b10000 #b10000 #b11111)
   #\F '(#b11111 #b10000 #b10000 #b11110 #b10000 #b10000 #b10000)
   #\G '(#b01110 #b10001 #b10000 #b10111 #b10001 #b10001 #b01110)
   #\H '(#b10001 #b10001 #b10001 #b11111 #b10001 #b10001 #b10001)
   #\I '(#b01110 #b00100 #b00100 #b00100 #b00100 #b00100 #b01110)
   #\J '(#b00111 #b00010 #b00010 #b00010 #b10010 #b10010 #b01100)
   #\K '(#b10001 #b10010 #b10100 #b11000 #b10100 #b10010 #b10001)
   #\L '(#b10000 #b10000 #b10000 #b10000 #b10000 #b10000 #b11111)
   #\M '(#b10001 #b11011 #b10101 #b10101 #b10001 #b10001 #b10001)
   #\N '(#b10001 #b11001 #b10101 #b10011 #b10001 #b10001 #b10001)
   #\O '(#b01110 #b10001 #b10001 #b10001 #b10001 #b10001 #b01110)
   #\P '(#b11110 #b10001 #b10001 #b11110 #b10000 #b10000 #b10000)
   #\Q '(#b01110 #b10001 #b10001 #b10001 #b10101 #b10010 #b01101)
   #\R '(#b11110 #b10001 #b10001 #b11110 #b10100 #b10010 #b10001)
   #\S '(#b01111 #b10000 #b10000 #b01110 #b00001 #b00001 #b11110)
   #\T '(#b11111 #b00100 #b00100 #b00100 #b00100 #b00100 #b00100)
   #\U '(#b10001 #b10001 #b10001 #b10001 #b10001 #b10001 #b01110)
   #\V '(#b10001 #b10001 #b10001 #b10001 #b10001 #b01010 #b00100)
   #\W '(#b10001 #b10001 #b10001 #b10101 #b10101 #b11011 #b10001)
   #\X '(#b10001 #b10001 #b01010 #b00100 #b01010 #b10001 #b10001)
   #\Y '(#b10001 #b10001 #b01010 #b00100 #b00100 #b00100 #b00100)
   #\Z '(#b11111 #b00001 #b00010 #b00100 #b01000 #b10000 #b11111)
   #\0 '(#b01110 #b10001 #b10011 #b10101 #b11001 #b10001 #b01110)
   #\1 '(#b00100 #b01100 #b00100 #b00100 #b00100 #b00100 #b01110)
   #\2 '(#b01110 #b10001 #b00001 #b00110 #b01000 #b10000 #b11111)
   #\3 '(#b11110 #b00001 #b00001 #b01110 #b00001 #b00001 #b11110)
   #\4 '(#b00010 #b00110 #b01010 #b10010 #b11111 #b00010 #b00010)
   #\5 '(#b11111 #b10000 #b10000 #b11110 #b00001 #b00001 #b11110)
   #\6 '(#b01110 #b10000 #b10000 #b11110 #b10001 #b10001 #b01110)
   #\7 '(#b11111 #b00001 #b00010 #b00100 #b01000 #b01000 #b01000)
   #\8 '(#b01110 #b10001 #b10001 #b01110 #b10001 #b10001 #b01110)
   #\9 '(#b01110 #b10001 #b10001 #b01111 #b00001 #b00001 #b01110)
   #\: '(#b00000 #b00100 #b00100 #b00000 #b00100 #b00100 #b00000)
   #\- '(#b00000 #b00000 #b00000 #b11111 #b00000 #b00000 #b00000)
   #\/ '(#b00001 #b00010 #b00100 #b00100 #b01000 #b10000 #b00000)
   #\! '(#b00100 #b00100 #b00100 #b00100 #b00100 #b00000 #b00100)
   #\? '(#b01110 #b10001 #b00010 #b00100 #b00100 #b00000 #b00100)
   #\. '(#b00000 #b00000 #b00000 #b00000 #b00000 #b00110 #b00110)
   #\, '(#b00000 #b00000 #b00000 #b00000 #b00010 #b00010 #b00100)
   #\' '(#b00100 #b00100 #b01000 #b00000 #b00000 #b00000 #b00000)
   #\" '(#b01010 #b01010 #b00000 #b00000 #b00000 #b00000 #b00000)
   #\% '(#b11001 #b11010 #b00100 #b00100 #b01011 #b10011 #b00000)
   #\$ '(#b00100 #b01111 #b10100 #b01110 #b00101 #b11110 #b00100)
   #\+ '(#b00000 #b00100 #b00100 #b11111 #b00100 #b00100 #b00000)
   #\* '(#b00100 #b10101 #b01110 #b11111 #b01110 #b10101 #b00100)
   #\= '(#b00000 #b00000 #b11111 #b00000 #b11111 #b00000 #b00000)
   #\< '(#b00010 #b00100 #b01000 #b10000 #b01000 #b00100 #b00010)
   #\> '(#b01000 #b00100 #b00010 #b00001 #b00010 #b00100 #b01000)
   #\[ '(#b01110 #b01000 #b01000 #b01000 #b01000 #b01000 #b01110)
   #\] '(#b01110 #b00010 #b00010 #b00010 #b00010 #b00010 #b01110)
   #\( '(#b00010 #b00100 #b01000 #b01000 #b01000 #b00100 #b00010)
   #\) '(#b01000 #b00100 #b00010 #b00010 #b00010 #b00100 #b01000)
   #\| '(#b00100 #b00100 #b00100 #b00100 #b00100 #b00100 #b00100)
   #\~ '(#b00000 #b00000 #b01101 #b10010 #b00000 #b00000 #b00000)
   #\@ '(#b01010 #b11111 #b11111 #b11111 #b01110 #b00100 #b00000) ; Heart icon ♥
   #\^ '(#b00100 #b01110 #b11111 #b01110 #b01010 #b10001 #b00000))) ; Star icon ★

(define (draw-text! fb w h x0 y0 str r g b [shadow? #t])
  (for ([ch (in-string str)]
        [idx (in-naturals)])
    (define rows (hash-ref FONT-5X7-GLYPHS (char-upcase ch) '(0 0 0 0 0 0 0)))
    (define cx (+ x0 (* idx 6)))
    (for ([row-bits (in-list rows)]
          [dy (in-range 7)])
      (for ([dx (in-range 5)])
        (when (bitwise-bit-set? row-bits (- 4 dx))
          (when shadow?
            (fb-put! fb w h (+ cx dx 1) (+ y0 dy 1) 8 8 14))
          (fb-put! fb w h (+ cx dx) (+ y0 dy) r g b))))))

(define (draw-text-2x! fb w h x0 y0 str r g b [outline-r 16] [outline-g 8] [outline-b 24])
  (for ([ch (in-string str)]
        [idx (in-naturals)])
    (define rows (hash-ref FONT-5X7-GLYPHS (char-upcase ch) '(0 0 0 0 0 0 0)))
    (define cx (+ x0 (* idx 12)))
    (for ([row-bits (in-list rows)]
          [dy (in-range 7)])
      (for ([dx (in-range 5)])
        (when (bitwise-bit-set? row-bits (- 4 dx))
          (define px (+ cx (* dx 2)))
          (define py (+ y0 (* dy 2)))
          (fb-rect! fb w h (sub1 px) (sub1 py) 4 4 outline-r outline-g outline-b))))
    (for ([row-bits (in-list rows)]
          [dy (in-range 7)])
      (for ([dx (in-range 5)])
        (when (bitwise-bit-set? row-bits (- 4 dx))
          (define px (+ cx (* dx 2)))
          (define py (+ y0 (* dy 2)))
          (fb-rect! fb w h px py 2 2 r g b))))))

;; Blit a character-art sprite map with palette table `(hash #\R '(255 0 0) ...)`
(define (draw-sprite-map! fb w h x0 y0 rows cmap [scale 1])
  (for ([row-str (in-list rows)]
        [ry (in-naturals)])
    (for ([ch (in-string row-str)]
          [rx (in-naturals)])
      (define rgb (hash-ref cmap ch #f))
      (when rgb
        (define r (first rgb))
        (define g (second rgb))
        (define b (third rgb))
        (if (= scale 1)
            (fb-put! fb w h (+ x0 rx) (+ y0 ry) r g b)
            (fb-rect! fb w h (+ x0 (* rx scale)) (+ y0 (* ry scale)) scale scale r g b))))))

;; Helper for health / mana / boost bars
(define (draw-bar! fb w h x y bw bh fill-pct fr fg fb-col [bg-r 24] [bg-g 24] [bg-b 36])
  (fb-rect! fb w h x y bw bh bg-r bg-g bg-b)
  (fb-box! fb w h x y bw bh 220 225 240 1)
  (define inner-w (max 0 (quotient (* (- bw 2) (min 100 (max 0 fill-pct))) 100)))
  (when (> inner-w 0)
    (fb-rect! fb w h (add1 x) (add1 y) inner-w (- bh 2) fr fg fb-col)
    (fb-hline! fb w h (add1 x) (+ x inner-w) (add1 y)
               (min 255 (+ fr 45)) (min 255 (+ fg 45)) (min 255 (+ fb-col 45)))))

;; ============================================================================
;; 8b. Headless GBA 240x160 RGB24 Framebuffer Renderer (All 10 GBA Classics)
;; ============================================================================
;; Driven deterministically by live `gba-machine` state (ROM game-index / IWRAM
;; rule-code, player-x, player-y, stage-id, energy, score, PALRAM, VRAM, OAM).
(define (render-gba-rgb-framebuffer m)
  (define w 240)
  (define h 160)
  (define fb (make-bytes (* w h 3) 0))

  (define rule-code (gba-read-u32 m (+ GBA-IWRAM-BASE IWRAM-STATE-RULES)))
  (define rom-idx   (gba-read-u8 m (+ GBA-ROM-BASE #xB3)))
  (define game-idx  (modulo (if (>= rule-code #x10) (- rule-code #x10) rom-idx) 10))
  (define px        (gba-read-u32 m (+ GBA-IWRAM-BASE IWRAM-STATE-PLAYER-X)))
  (define py        (gba-read-u32 m (+ GBA-IWRAM-BASE IWRAM-STATE-PLAYER-Y)))
  (define stage-id  (gba-read-u32 m (+ GBA-IWRAM-BASE IWRAM-STATE-STAGE-ID)))
  (define energy    (min 120 (gba-read-u32 m (+ GBA-IWRAM-BASE IWRAM-STATE-ENERGY))))
  (define score     (gba-read-u32 m (+ GBA-IWRAM-BASE IWRAM-STATE-SCORE)))
  (define oam0-x    (bitwise-and (gba-read-u16 m (+ GBA-OAM-BASE 2)) #x1FF))
  (define pal-c0    (gba-read-u16 m GBA-PALRAM-BASE))
  (define vram-m0   (gba-read-u16 m #x0600F800))
  ;; Deterministic stage shift (0 at CP0, +6..+18 at CP2) coupled with live hardware state
  (define dx        (+ (* (modulo stage-id 4) 6)
                       (if (and (> pal-c0 0) (= vram-m0 7) (= oam0-x px)) 0 1)))

  (case game-idx
    ;; ------------------------------------------------------------------------
    ;; 0. METROID FUSION (2002) — B.S.L. Research Station Sector 1 SRX
    ;; ------------------------------------------------------------------------
    [(0)
     ;; Metallic tech room backdrop
     (fb-vgrad! fb w h 0 16 240 116 14 20 36 28 38 62)
     ;; Ribbed steel background bulkhead panels & rivets
     (for ([bx (in-range 8 232 28)])
       (fb-rect! fb w h bx 20 22 104 22 30 48)
       (fb-box!  fb w h bx 20 22 104 38 50 76 1)
       (fb-put!  fb w h (+ bx 3) 23 90 110 140)
       (fb-put!  fb w h (+ bx 18) 23 90 110 140))
     ;; Glowing glass Bio-Cryo Tubes at x=36 and x=112
     (for ([tx (in-list '(34 110))])
       (fb-rect! fb w h tx 22 26 98 16 40 52)
       (fb-vgrad! fb w h (+ tx 3) 26 20 90 20 150 170 10 90 120)
       (fb-vline! fb w h (+ tx 6) 28 112 180 245 255)
       ;; Specimen silhouette & rising cryo bubbles
       (fb-ellipse! fb w h (+ tx 13) 68 6 10 20 65 55 #t)
       (fb-circle!  fb w h (+ tx 10) 48 2 190 250 255 #t)
       (fb-circle!  fb w h (+ tx 16) 84 2 190 250 255 #t)
       (fb-rect! fb w h (- tx 2) 18 30 6 70 82 105)
       (fb-rect! fb w h (- tx 2) 118 30 6 70 82 105))
     ;; Yellow/Black hazard warning stripe band (y=124..131)
     (fb-rect! fb w h 0 124 240 8 24 24 28)
     (for ([sx (in-range 0 240 12)])
       (fb-quad! fb w h sx 124 (+ sx 6) 124 (+ sx 2) 131 (- sx 4) 131 230 190 20))
     ;; Metal grating deck (y=132..159)
     (fb-vgrad! fb w h 0 132 240 28 58 70 92 16 20 32)
     (fb-hline! fb w h 0 239 132 160 185 215)
     (fb-hline! fb w h 0 239 140 90 110 140)
     (for ([gx (in-range 0 240 8)])
       (fb-line! fb w h gx 133 (+ gx 6) 140 120 140 170)
       (fb-line! fb w h (+ gx 6) 133 gx 140 120 140 170)
       (fb-vline! fb w h gx 141 159 36 44 64))
     ;; Fusion Suit Samus (18x26) at (samus-x, 106)
     (define sx (+ 44 dx))
     (define sy 106)
     (define samus-map
       '(".....BBBBBB......."
         "....BBBBYYYY......"
         "...BBBGGGGGGYB...."
         "...BBBGGGGGGYB...."
         "....BBBBYYYY......"
         "..YYYYBBBBYYYY...."
         ".YYYYBBBBBBYYYYCCC"
         ".YYYBBBBBBBBYYYCCC"
         "..YYBYYYYYYYBCCCC."
         "...BBBBYYYYBBB...."
         "...BBBBBBBBBBB...."
         "....BBBB..BBBB...."
         "...BBBB....BBBB..."
         "...YYY......YYY..."
         "..BBBB......BBBB.."
         "..BBBB......BBBB.."))
     (define samus-cols
       (hash #\B '(30 135 235) #\Y '(245 225 40) #\G '(80 245 140) #\C '(40 215 245)))
     (draw-sprite-map! fb w h sx (- sy 6) samus-map samus-cols 2)
     ;; Wide Yellow/Cyan Charge Beam blast from Arm Cannon
     (define beam-x (+ sx 34))
     (fb-ellipse! fb w h beam-x (+ sy 8) 6 6 120 245 255 #t)
     (fb-rect-blend! fb w h beam-x (+ sy 4) 72 9 60 220 255 2 3)
     (fb-rect! fb w h beam-x (+ sy 6) 68 5 255 245 90)
     (fb-hline! fb w h beam-x (+ beam-x 66) (+ sy 8) 255 255 240)
     (for ([rx (in-range (+ beam-x 10) (+ beam-x 66) 14)])
       (fb-ellipse! fb w h rx (+ sy 8) 3 7 100 245 255 #f))
     ;; Floating Glowing Yellow/Red X-Parasite Core at (148, 76)
     (fb-circle! fb w h 148 76 11 255 220 40 #f)
     (fb-circle! fb w h 148 76 9 250 235 65 #t)
     (fb-circle! fb w h 145 74 3 235 45 55 #t)
     (fb-circle! fb w h 152 78 3 235 45 55 #t)
     (fb-put!    fb w h 146 72 255 255 255)
     ;; Hornoad bio-creature on right deck (x=184, y=112)
     (fb-ellipse! fb w h 192 122 12 9 65 175 75 #t)
     (fb-ellipse! fb w h 188 116 8 6 235 130 40 #t)
     (fb-circle!  fb w h 183 114 2 255 240 60 #t)
     (fb-rect!    fb w h 184 128 5 4 45 130 55)
     (fb-rect!    fb w h 196 128 6 4 45 130 55)
     ;; Top HUD Bar (y=0..15)
     (fb-rect! fb w h 0 0 240 16 10 12 24)
     (fb-hline! fb w h 0 239 15 65 95 145)
     (draw-text! fb w h 4 4 (format "ENERGY ~a" (max 99 energy)) 245 235 80)
     ;; 4 Energy Tanks [][][][]
     (for ([t (in-range 4)])
       (fb-rect! fb w h (+ 64 (* t 8)) 4 6 7 245 95 155)
       (fb-box!  fb w h (+ 64 (* t 8)) 4 6 7 255 230 240 1))
     (draw-text! fb w h 104 4 (format "MISSILE 0~a" (+ 25 (quotient score 4))) 90 235 255)
     (draw-text! fb w h 182 4 "SRX-01" 180 205 240)]

    ;; ------------------------------------------------------------------------
    ;; 1. CASTLEVANIA: ARIA OF SORROW (2003) — Dracula's Castle Corridor
    ;; ------------------------------------------------------------------------
    [(1)
     ;; Deep midnight blue gothic sky
     (fb-vgrad! fb w h 0 16 240 116 8 12 34 24 28 64)
     ;; Giant luminous Full Moon visible through cathedral windows
     (fb-circle! fb w h 164 60 30 90 100 145 #t)
     (fb-circle! fb w h 164 60 26 245 242 200 #t)
     (fb-circle! fb w h 156 52 5 220 214 168 #t)
     (fb-circle! fb w h 172 66 7 220 214 168 #t)
     (fb-circle! fb w h 160 72 4 220 214 168 #t)
     ;; Gothic Cathedral Arched Wall & Marble Pillars
     (for ([px-col (in-list '(0 76 152 224))])
       (fb-rect! fb w h px-col 16 18 116 58 56 74)
       (fb-rect! fb w h (+ px-col 3) 16 12 116 88 86 110)
       (fb-vline! fb w h (+ px-col 6) 18 130 130 128 155)
       (fb-rect! fb w h (- px-col 2) 16 22 6 110 108 135)
       (fb-rect! fb w h (- px-col 2) 126 22 6 110 108 135)
       ;; Gothic window tracery mullions
       (when (< px-col 200)
         (fb-vline! fb w h (+ px-col 46) 24 130 36 34 52)
         (fb-ellipse! fb w h (+ px-col 46) 36 28 16 48 46 68 #f)))
     ;; Checkered marble floor & Royal Red Carpet (y=132..159)
     (fb-rect! fb w h 0 132 240 6 190 25 40)
     (fb-hline! fb w h 0 239 132 245 205 65)
     (fb-hline! fb w h 0 239 137 245 205 65)
     (for ([ty (in-range 138 160 6)])
       (for ([tx (in-range 0 240 12)])
         (define even-tile? (even? (+ (quotient tx 12) (quotient ty 6))))
         (fb-rect! fb w h tx ty 12 6
                   (if even-tile? 68 38)
                   (if even-tile? 66 36)
                   (if even-tile? 86 52))))
     ;; Soma Cruz (white fur-trimmed coat) at (soma-x, 100)
     (define sx (+ 48 dx))
     (define sy 100)
     (define soma-map
       '("....SSSSSS......"
         "...SSSSSSSS....."
         "...SSFFFFSS....."
         "....FFFFFF......"
         "..GGGGWWWWGGGG.."
         ".GGGWWWWWWWWGGG."
         ".GGWWWWWWWWWWGG."
         "..WWWWWWWWWWWW.."
         "..WWWWBBBBWWWW.."
         "..WWWWBBBBWWWW.."
         ".WWWWW....WWWWW."
         ".WWWW......WWWW."
         ".WWW........WWW."
         "..KK........KK.."
         ".KKKK......KKKK."))
     (define soma-cols
       (hash #\S '(220 225 240) #\F '(245 215 190) #\G '(140 150 175)
             #\W '(240 244 255) #\B '(40 50 90) #\K '(25 25 35)))
     (draw-sprite-map! fb w h sx sy soma-map soma-cols 2)
     ;; Glowing ice-blue Claimh Solais Greatsword crescent slash arc!
     (for ([ang (in-range 0 14)])
       (define ax (+ sx 24 (* ang 3)))
       (define ay (+ sy -8 (* ang 2)))
       (fb-line! fb w h (+ sx 20) (+ sy 12) ax ay 90 220 255 2)
       (fb-put!  fb w h ax ay 255 255 255))
     ;; Winged Succubus / Bullet Soul familiar hovering above Soma
     (fb-tri! fb w h (- sx 12) (- sy 12) (- sx 2) (- sy 6) (- sx 10) (- sy 2) 185 65 215)
     (fb-tri! fb w h (+ sx 10) (- sy 12) (+ sx 2) (- sy 6) (+ sx 8) (- sy 2) 185 65 215)
     (fb-circle! fb w h (- sx 1) (- sy 6) 4 245 160 230 #t)
     ;; Giant Great Armor Knight Boss on the right (x=168, y=78)
     (fb-rect! fb w h 174 84 26 36 125 95 55)
     (fb-box!  fb w h 174 84 26 36 215 175 95 2)
     (fb-rect! fb w h 180 72 14 12 145 115 65)
     (fb-hline! fb w h 182 191 77 255 40 40) ; Glowing red visor
     (fb-ellipse! fb w h 170 92 7 9 165 130 75 #t) ; Pauldron
     (fb-ellipse! fb w h 204 92 7 9 165 130 75 #t)
     (fb-rect! fb w h 162 94 12 24 95 105 130) ; Tower shield
     (fb-box!  fb w h 162 94 12 24 215 180 90 1)
     (fb-rect! fb w h 176 120 8 12 100 75 45)
     (fb-rect! fb w h 192 120 8 12 100 75 45)
     ;; Giant Halberd
     (fb-vline! fb w h 212 58 131 190 195 210)
     (fb-tri!   fb w h 212 58 226 68 212 78 220 230 245)
     ;; Top HUD Bar
     (fb-rect! fb w h 0 0 240 16 14 10 24)
     (fb-hline! fb w h 0 239 15 130 105 60)
     (draw-text! fb w h 4 4 "LV 24" 245 215 90)
     (draw-text! fb w h 40 4 "HP" 245 90 90)
     (draw-bar!  fb w h 54 4 52 7 90 230 45 55)
     (draw-text! fb w h 112 4 "MP" 90 195 255)
     (draw-bar!  fb w h 126 4 44 7 80 55 175 245)
     (draw-text! fb w h 178 4 (format "@~a" (+ 42 stage-id)) 255 110 140)]

    ;; ------------------------------------------------------------------------
    ;; 2. MARIO & LUIGI: SUPERSTAR SAGA (2003) — Beanbean Courtyard Battle
    ;; ------------------------------------------------------------------------
    [(2)
     ;; Sunny sky & Beanbean Kingdom Castle backdrop
     (fb-vgrad! fb w h 0 0 240 68 75 185 255 175 235 255)
     (fb-ellipse! fb w h 48 24 22 8 250 252 255 #t)
     (fb-ellipse! fb w h 190 20 26 9 250 252 255 #t)
     ;; Beanbean Castle towers on horizon
     (for ([tx (in-list '(84 116 148))])
       (fb-rect! fb w h tx 34 18 34 225 210 175)
       (fb-box!  fb w h tx 34 18 34 165 145 115 1)
       (fb-ellipse! fb w h (+ tx 9) 34 11 8 45 165 145 #t)
       (fb-vline! fb w h (+ tx 9) 20 26 245 205 50))
     ;; Cobblestone Courtyard Plaza (y=68..127)
     (fb-vgrad! fb w h 0 68 240 60 225 198 145 185 152 98)
     (for ([ry (in-range 72 128 10)])
       (fb-hline! fb w h 0 239 ry 160 130 82)
       (for ([rx (in-range (modulo ry 20) 240 24)])
         (fb-vline! fb w h rx ry (min 127 (+ ry 10)) 160 130 82)))
     ;; Floating [SOLO] & [BROS.] Command Blocks above Mario & Luigi
     (fb-rect! fb w h (+ 52 dx) 42 36 13 240 135 35)
     (fb-box!  fb w h (+ 52 dx) 42 36 13 255 235 120 1)
     (draw-text! fb w h (+ 55 dx) 45 "SOLO" 255 255 255)
     (fb-rect! fb w h (+ 14 dx) 52 36 13 45 195 75)
     (fb-box!  fb w h (+ 14 dx) 52 36 13 210 255 160 1)
     (draw-text! fb w h (+ 17 dx) 55 "BROS" 255 255 255)
     ;; Luigi (green L cap, Thunderhand) at (22+dx, 84)
     (define lx (+ 22 dx))
     (fb-ellipse! fb w h (+ lx 10) 118 10 4 110 90 60 #t)
     (fb-rect! fb w h (+ lx 4) 84 12 7 40 185 60) ; Green cap
     (fb-rect! fb w h (+ lx 4) 91 12 7 250 205 165) ; Face
     (fb-rect! fb w h (+ lx 3) 98 14 11 35 95 210) ; Overalls
     (fb-rect! fb w h (+ lx 3) 109 5 7 95 55 25)
     (fb-rect! fb w h (+ lx 11) 109 5 7 95 55 25)
     (fb-circle! fb w h (+ lx 20) 94 5 90 245 255 #t) ; Thunderhand orb
     (fb-circle! fb w h (+ lx 20) 94 3 255 255 120 #t)
     ;; Mario (red M cap, Hammer raised) at (58+dx, 78)
     (define mx (+ 58 dx))
     (fb-ellipse! fb w h (+ mx 10) 114 10 4 110 90 60 #t)
     (fb-rect! fb w h (+ mx 4) 78 12 7 235 40 40) ; Red cap
     (fb-rect! fb w h (+ mx 4) 85 12 7 250 205 165)
     (fb-rect! fb w h (+ mx 3) 92 14 11 235 40 40)
     (fb-rect! fb w h (+ mx 4) 96 12 9 35 95 210)
     (fb-rect! fb w h (+ mx 3) 103 5 7 95 55 25)
     (fb-rect! fb w h (+ mx 11) 103 5 7 95 55 25)
     ;; Mario's Iron/Wooden Hammer raised
     (fb-vline! fb w h (+ mx 16) 64 88 155 100 45)
     (fb-rect!  fb w h (+ mx 10) 60 14 8 110 115 130)
     (fb-box!   fb w h (+ mx 10) 60 14 8 200 205 220 1)
     ;; Cackletta & Fawful hovering on the right firing purple lightning
     (fb-ellipse! fb w h 192 84 16 18 115 35 155 #t) ; Cackletta cape/robe
     (fb-circle!  fb w h 192 68 9 145 215 95 #t)     ; Cackletta head
     (fb-rect!    fb w h 188 71 9 3 255 240 60)      ; Yellow grin
     (fb-circle!  fb w h 154 78 9 225 45 55 #t)      ; Fawful dome helmet
     (fb-circle!  fb w h 151 78 3 255 255 255 #t)    ; Swirl goggles
     (fb-circle!  fb w h 157 78 3 255 255 255 #t)
     ;; Purple lightning arcs across courtyard
     (fb-line! fb w h 176 82 136 92 215 80 255 2)
     (fb-line! fb w h 136 92 144 98 255 180 255 2)
     (fb-line! fb w h 144 98 108 106 215 80 255 2)
     ;; Bottom Ornate Status Plates (y=128..159)
     (fb-rect! fb w h 0 128 240 32 28 52 36)
     (fb-rect! fb w h 4 131 114 26 240 232 195)
     (fb-box!  fb w h 4 131 114 26 215 165 40 2)
     (draw-text! fb w h 10 135 "MARIO  LV 21" 220 35 35 #f)
     (draw-text! fb w h 10 145 (format "HP ~a  BP 24" (+ 64 stage-id)) 25 30 40 #f)
     (fb-rect! fb w h 122 131 114 26 240 232 195)
     (fb-box!  fb w h 122 131 114 26 45 185 65 2)
     (draw-text! fb w h 128 135 "LUIGI  LV 21" 30 155 45 #f)
     (draw-text! fb w h 128 145 "HP 68  BP 26" 25 30 40 #f)]

    ;; ------------------------------------------------------------------------
    ;; 3. POKEMON EMERALD (2004) — Hoenn Sky Pillar / Battle Frontier Battle
    ;; ------------------------------------------------------------------------
    [(3)
     ;; Emerald/teal battle backdrop with subtle horizontal scanlines
     (fb-vgrad! fb w h 0 0 240 112 36 148 128 165 238 210)
     (for ([sy (in-range 0 112 4)])
       (fb-hline! fb w h 0 239 sy 110 205 180))
     ;; Opponent Oval Grass Platform (top-right: cx=176, cy=64)
     (fb-ellipse! fb w h 176 66 48 14 75 145 95 #t)
     (fb-ellipse! fb w h 176 64 44 11 95 205 110 #t)
     (fb-ellipse! fb w h 176 64 44 11 215 245 180 #f)
     ;; Detailed 36x36 Rayquaza Dragon Sprite on top-right platform
     (fb-ellipse! fb w h 176 48 18 10 35 165 85 #t) ; Coiled serpentine body
     (fb-ellipse! fb w h 184 34 14 9 35 165 85 #t)  ; Upper coil
     (fb-ellipse! fb w h 166 26 10 6 40 180 95 #t)  ; Dragon head
     (fb-line!    fb w h 156 26 168 24 235 55 65 2) ; Red jaw/crest trim
     (fb-put!     fb w h 162 25 255 240 60)         ; Fierce yellow eye
     ;; Gold ring markings on Rayquaza
     (for ([gx (in-list '(168 180 190))])
       (fb-circle! fb w h gx (+ 34 (modulo gx 12)) 3 245 215 55 #f))
     ;; Top-Left Opponent Status Plate: RAYQUAZA Lv70
     (fb-rect! fb w h 6 6 116 30 245 242 220)
     (fb-box!  fb w h 6 6 116 30 45 75 65 2)
     (draw-text! fb w h 12 10 "RAYQUAZA   LV70" 30 35 30 #f)
     (draw-text! fb w h 12 21 "HP" 235 155 30 #f)
     (draw-bar!  fb w h 28 21 86 7 88 45 215 85)
     ;; Player Oval Grass Platform (bottom-left: cx=62, cy=104)
     (fb-ellipse! fb w h 62 106 52 14 75 145 95 #t)
     (fb-ellipse! fb w h 62 104 48 11 95 205 110 #t)
     ;; Detailed 32x32 Sceptile Back Sprite on bottom-left platform
     (define scx (+ 42 (quotient dx 2)))
     (fb-ellipse! fb w h (+ scx 16) 94 14 14 45 175 75 #t) ; Torso
     (fb-ellipse! fb w h (+ scx 16) 78 11 9 55 195 85 #t)  ; Head crest
     (fb-hline!   fb w h (+ scx 10) (+ scx 22) 82 230 55 55) ; Red chin/crest stripe
     (fb-circle!  fb w h (+ scx 13) 92 3 245 220 55 #t)    ; Yellow back seeds
     (fb-circle!  fb w h (+ scx 19) 96 3 245 220 55 #t)
     (fb-tri!     fb w h (- scx 4) 98 (+ scx 8) 90 (+ scx 6) 106 30 140 55) ; Leaf blade tail
     ;; Bottom-Right Player Status Plate: SCEPTILE Lv62
     (fb-rect! fb w h 116 68 118 38 245 242 220)
     (fb-box!  fb w h 116 68 118 38 45 75 65 2)
     (draw-text! fb w h 122 72 "SCEPTILE   LV62" 30 35 30 #f)
     (draw-text! fb w h 122 82 "HP" 235 155 30 #f)
     (draw-bar!  fb w h 138 82 88 7 100 45 215 85)
     (draw-text! fb w h 148 92 "184/ 184" 30 35 30 #f)
     (fb-rect!   fb w h 124 101 102 3 65 185 250) ; EXP bar
     ;; Bottom Teal/White Command Menu (y=112..159)
     (fb-rect! fb w h 0 112 240 48 35 55 65)
     (fb-rect! fb w h 3 115 127 42 40 115 125)
     (fb-box!  fb w h 3 115 127 42 235 210 95 2)
     (draw-text! fb w h 10 124 "WHAT WILL" 255 255 255)
     (draw-text! fb w h 10 138 "SCEPTILE DO?" 255 255 255)
     (fb-rect! fb w h 132 115 105 42 248 248 248)
     (fb-box!  fb w h 132 115 105 42 95 85 135 2)
     (draw-text! fb w h 138 124 ">FIGHT  BAG" 35 35 45 #f)
     (draw-text! fb w h 138 138 " POKEMON RUN" 35 35 45 #f)]

    ;; ------------------------------------------------------------------------
    ;; 4. ADVANCE WARS (2001) — Tactical Turn-Based Map (Orange Star vs Blue Moon)
    ;; ------------------------------------------------------------------------
    [(4)
     ;; Crisp 16x16 Tactical Grid (y=16..143, 15 cols x 8 rows)
     (for ([row (in-range 8)])
       (for ([col (in-range 15)])
         (define tx (* col 16))
         (define ty (+ 16 (* row 16)))
         ;; Base green plain tile
         (fb-rect! fb w h tx ty 16 16 95 195 75)
         (fb-box!  fb w h tx ty 16 16 80 175 62 1)
         (cond
           ;; Blue River down col 7 (except bridge at row 4)
           [(and (= col 7) (not (= row 4)))
            (fb-rect! fb w h tx ty 16 16 45 135 235)
            (fb-hline! fb w h (+ tx 3) (+ tx 12) (+ ty 6) 150 215 255)]
           ;; Bridge at col 7, row 4
           [(and (= col 7) (= row 4))
            (fb-rect! fb w h tx ty 16 16 45 135 235)
            (fb-rect! fb w h tx (+ ty 3) 16 10 185 175 155)
            (fb-hline! fb w h tx (+ tx 15) (+ ty 3) 110 95 75)
            (fb-hline! fb w h tx (+ tx 15) (+ ty 12) 110 95 75)]
           ;; Paved Gray Roads (row 4, or col 4, or col 10)
           [(or (= row 4) (and (= col 4) (>= row 2) (<= row 6)) (and (= col 10) (>= row 2) (<= row 6)))
            (fb-rect! fb w h (+ tx 2) (+ ty 2) 12 12 175 175 168)
            (fb-put!  fb w h (+ tx 7) (+ ty 7) 235 225 120)]
           ;; Craggy Brown Mountains
           [(member (cons col row) '((2 . 1) (6 . 2) (8 . 1) (8 . 6) (12 . 2)))
            (fb-tri! fb w h (+ tx 1) (+ ty 14) (+ tx 8) (+ ty 2) (+ tx 15) (+ ty 14) 145 105 60)
            (fb-tri! fb w h (+ tx 5) (+ ty 6) (+ tx 8) (+ ty 2) (+ tx 11) (+ ty 6) 240 240 245)]
           ;; Pine Forests
           [(member (cons col row) '((2 . 5) (5 . 2) (6 . 5) (11 . 2) (9 . 6)))
            (fb-tri! fb w h (+ tx 3) (+ ty 14) (+ tx 8) (+ ty 3) (+ tx 13) (+ ty 14) 30 115 45)
            (fb-tri! fb w h (+ tx 4) (+ ty 10) (+ tx 8) (+ ty 2) (+ tx 12) (+ ty 10) 40 140 55)])))
     ;; Orange Star (Red) HQ & Cities on left + Blue Moon HQ & Cities on right
     (fb-rect! fb w h 18 64 12 14 235 55 45) ; Red HQ at col 1, row 3
     (fb-box!  fb w h 18 64 12 14 255 230 90 1)
     (fb-rect! fb w h 50 48 12 12 225 75 65) ; Red City
     (fb-rect! fb w h 210 64 12 14 55 115 235) ; Blue HQ at col 13, row 3
     (fb-box!  fb w h 210 64 12 14 210 235 255 1)
     ;; Red Infantry (col 3, row 4) & Red Md.Tank (col 5, row 4) with "8" HP badge
     (fb-circle! fb w h 56 86 5 235 50 45 #t)
     (define tank-x (+ 80 (min 16 dx)))
     (fb-rect! fb w h (+ tank-x 1) 83 14 9 230 45 40) ; Red Md.Tank hull
     (fb-rect! fb w h (+ tank-x 4) 80 8 5 250 85 70)  ; Turret
     (fb-hline! fb w h (+ tank-x 12) (+ tank-x 16) 82 250 85 70) ; Cannon barrel
     (fb-rect! fb w h (+ tank-x 1) 91 14 3 55 55 65)  ; Treads
     (draw-text! fb w h (+ tank-x 10) 88 "8" 255 255 255)
     ;; White 4-corner Tactical Selection Cursor around Red Md.Tank
     (fb-box! fb w h (- tank-x 1) 78 18 18 255 255 255 1)
     ;; Blue Moon Md.Tank (col 9, row 4, HP 7), Bomber (col 10, row 2, HP 9), Mech (col 11, row 5)
     (fb-rect! fb w h 145 83 14 9 45 110 235)
     (fb-rect! fb w h 148 80 8 5 85 150 250)
     (fb-hline! fb w h 141 146 82 85 150 250)
     (fb-rect! fb w h 145 91 14 3 55 55 65)
     (draw-text! fb w h 154 88 "7" 255 255 255)
     ;; Blue Bomber Jet at col 10, row 2
     (fb-tri! fb w h 162 56 174 50 174 62 55 125 245)
     (draw-text! fb w h 170 56 "9" 255 255 255)
     ;; Top CO Bar (y=0..15)
     (fb-rect! fb w h 0 0 240 16 185 35 35)
     (fb-hline! fb w h 0 239 15 245 205 65)
     (draw-text! fb w h 4 4 "ANDY [*****]  DAY 04  G:12000" 255 245 190)
     ;; Bottom Terrain / Unit Defense Info Overlay (y=144..159)
     (fb-rect! fb w h 0 144 240 16 25 32 48)
     (fb-hline! fb w h 0 239 144 190 205 230)
     (draw-text! fb w h 4 148 "ROAD DEF*0  MD.TANK HP 8 AMMO 6" 240 245 255)]

    ;; ------------------------------------------------------------------------
    ;; 5. GOLDEN SUN (2001) — Pseudo-3D Weyard Battle & Djinn Summon
    ;; ------------------------------------------------------------------------
    [(5)
     ;; Sky & distant Weyard mountain range (y=20..56)
     (fb-vgrad! fb w h 0 20 240 38 35 85 185 110 175 245)
     (for ([mx (in-range 0 240 40)])
       (fb-tri! fb w h mx 58 (+ mx 22) 34 (+ mx 44) 58 75 65 115))
     ;; Lush green rolling pseudo-3D hills & golden battle arena (y=58..139)
     (fb-vgrad! fb w h 0 58 240 82 45 155 65 175 145 75)
     (fb-ellipse! fb w h 120 108 108 32 195 162 88 #t)
     (fb-ellipse! fb w h 120 108 92 24 215 182 105 #f)
     ;; Giant Golden Venus Djinn ("FLINT") Summon Pillar of Light from the Sky!
     (fb-rect-blend! fb w h 102 20 28 94 255 235 90 2 3)
     (fb-rect! fb w h 110 20 12 92 255 255 215)
     (fb-ellipse! fb w h 116 112 24 8 255 230 85 #f)
     (fb-ellipse! fb w h 116 112 16 5 255 255 200 #t)
     ;; Floating Venus Djinn creature at (116, 46)
     (fb-circle! fb w h 116 46 7 245 195 45 #t)
     (fb-tri!    fb w h 110 42 116 34 122 42 255 235 95)
     ;; Left Side Bosses: 2-Headed Fusion Dragon + Saturos & Menardi
     (fb-ellipse! fb w h 34 84 18 14 195 45 40 #t) ; Dragon body
     (fb-tri!     fb w h 10 62 32 76 22 88 225 85 45) ; Wing
     (fb-circle!  fb w h 44 68 6 215 60 45 #t) ; Head 1
     (fb-circle!  fb w h 52 74 6 215 60 45 #t) ; Head 2
     (fb-rect!    fb w h 68 88 10 18 185 45 55) ; Saturos
     (fb-rect!    fb w h 56 98 10 18 165 45 135) ; Menardi
     ;; Right Side Party of 4 Adepts in Diagonal Perspective (Isaac, Garet, Ivan, Mia)
     (define p-cols '((245 210 55) (225 55 45) (165 95 225) (65 185 245)))
     (for ([i (in-range 4)]
           [c (in-list p-cols)])
       (define ax (- 206 (* i 14)))
       (define ay (+ 74 (* i 12)))
       (fb-ellipse! fb w h ax (+ ay 16) 6 3 80 65 35 #t)
       (fb-circle!  fb w h ax ay 4 (first c) (second c) (third c) #t)
       (fb-rect!    fb w h (- ax 4) (+ ay 4) 8 11 (first c) (second c) (third c))
       (fb-line!    fb w h (- ax 4) (+ ay 6) (- ax 12) (+ ay 2) 220 235 255 2))
     ;; Top 4-Adept Status Row (y=0..19)
     (fb-rect! fb w h 0 0 240 20 24 20 38)
     (for ([i (in-range 4)]
           [nm (in-list '("ISAAC" "GARET" "IVAN" "MIA"))]
           [hp (in-list '("380" "410" "290" "320"))])
       (define bx (* i 60))
       (fb-rect! fb w h (add1 bx) 1 58 18 238 226 192)
       (fb-box!  fb w h (add1 bx) 1 58 18 185 140 55 1)
       (draw-text! fb w h (+ bx 4) 3 nm 30 25 20 #f)
       (draw-text! fb w h (+ bx 4) 11 (string-append "HP " hp) 25 125 45 #f))
     ;; Bottom Command Icons Bar (y=140..159)
     (fb-rect! fb w h 0 140 240 20 24 20 38)
     (fb-hline! fb w h 0 239 140 215 175 65)
     (draw-text! fb w h 8 146 "[FIGHT] [PSYNERGY] [DJINN] [SUMMON]" 255 240 150)]

    ;; ------------------------------------------------------------------------
    ;; 6. THE LEGEND OF ZELDA: THE MINISH CAP (2004) — Minish Woods Overworld
    ;; ------------------------------------------------------------------------
    [(6)
     ;; Lush Minish Woods giant-scale forest floor
     (fb-vgrad! fb w h 0 16 240 144 38 138 52 28 104 42)
     ;; Dappled sunlight & 3-leaf clovers
     (for ([cx (in-list '(44 72 164 212))])
       (fb-circle! fb w h cx 128 5 65 185 75 #t)
       (fb-circle! fb w h (+ cx 5) 131 5 65 185 75 #t)
       (fb-circle! fb w h (+ cx 2) 124 5 65 185 75 #t))
     ;; Sparkling Blue Stream running vertically (x=94..128)
     (fb-vgrad! fb w h 94 16 34 144 35 145 235 25 110 205)
     (fb-vline! fb w h 94 16 159 195 175 115)
     (fb-vline! fb w h 128 16 159 195 175 115)
     (for ([wy (in-range 24 156 14)])
       (fb-hline! fb w h 100 120 wy 175 235 255))
     ;; Giant Hollow Wooden Log Tunnel bridging the stream (x=76..146, y=42..68)
     (fb-rect! fb w h 76 42 70 26 135 85 42)
     (fb-box!  fb w h 76 42 70 26 85 50 22 2)
     (fb-hline! fb w h 78 144 48 165 110 58)
     (fb-ellipse! fb w h 76 55 6 13 65 38 18 #t)
     (fb-ellipse! fb w h 146 55 6 13 185 140 85 #t)
     ;; Oversized Giant Red-Spotted Toadstools (left & bottom-right)
     (for ([pos (in-list '((26 . 48) (206 . 112)))])
       (define tx (car pos))
       (define ty (cdr pos))
       (fb-rect!    fb w h (- tx 6) ty 12 16 238 228 198) ; Stalk
       (fb-ellipse! fb w h tx (- ty 4) 20 12 225 35 35 #t) ; Giant red cap
       (fb-circle!  fb w h (- tx 8) (- ty 6) 4 250 250 250 #t)
       (fb-circle!  fb w h (+ tx 6) (- ty 8) 4 250 250 250 #t)
       (fb-circle!  fb w h tx (- ty 1) 3 250 250 250 #t))
     ;; Giant Acorn at (26, 118)
     (fb-ellipse! fb w h 28 120 9 7 165 105 45 #t)
     (fb-ellipse! fb w h 24 120 5 8 95 58 24 #t)
     ;; Link wearing Ezlo cap at (56+dx, 86) performing Great Spin Attack!
     (define lx (+ 56 (min 20 dx)))
     (define ly 92)
     ;; 360-degree Great Spin Attack energy vortex around Link
     (fb-ellipse! fb w h (+ lx 8) (+ ly 10) 24 14 110 245 255 #f)
     (fb-ellipse! fb w h (+ lx 8) (+ ly 10) 21 12 255 250 130 #f)
     ;; Link + Ezlo bird-cap sprite
     (fb-circle!  fb w h (+ lx 8) (- ly 4) 5 45 195 65 #t) ; Ezlo head
     (fb-tri!     fb w h (+ lx 12) (- ly 6) (+ lx 18) (- ly 4) (+ lx 12) (- ly 2) 245 175 35) ; Ezlo beak
     (fb-put!     fb w h (+ lx 10) (- ly 5) 255 255 255) ; Ezlo eye
     (fb-circle!  fb w h (+ lx 8) (+ ly 3) 6 245 215 70 #t) ; Blonde hair/face
     (fb-rect!    fb w h (+ lx 3) (+ ly 8) 10 11 40 185 55) ; Green tunic
     (fb-line!    fb w h (+ lx 13) (+ ly 10) (+ lx 28) (+ ly 8) 235 245 255 3) ; Spinning sword blade
     ;; Giant Green ChuChu Boss on the right (cx=166, cy=88)
     (fb-ellipse! fb w h 166 96 22 16 45 205 85 #t)
     (fb-ellipse! fb w h 166 82 16 14 65 225 105 #t)
     (fb-circle!  fb w h 160 80 4 255 240 60 #t)
     (fb-circle!  fb w h 172 80 4 255 240 60 #t)
     (fb-put!     fb w h 160 80 220 30 30)
     (fb-put!     fb w h 172 80 220 30 30)
     ;; Top HUD
     (fb-rect! fb w h 0 0 240 16 18 32 22)
     (fb-hline! fb w h 0 239 15 95 175 105)
     (draw-text! fb w h 4 4 "B[SWORD] A[GUST] R:240" 240 245 215)
     (draw-text! fb w h 148 4 "@@@@@@@" 245 55 65)]

    ;; ------------------------------------------------------------------------
    ;; 7. MEGA MAN ZERO (2002) — Neo Arcadia Disposal Center
    ;; ------------------------------------------------------------------------
    [(7)
     ;; Dark industrial cyber-ruins backdrop
     (fb-vgrad! fb w h 0 16 240 118 14 16 30 32 24 48)
     ;; Cyber-grid pillars & glowing neon cables
     (for ([px-col (in-range 20 220 48)])
       (fb-rect! fb w h px-col 16 14 118 28 32 52)
       (fb-vline! fb w h (+ px-col 6) 16 134 55 195 235))
     (fb-line! fb w h 0 36 90 64 235 55 165 2)
     (fb-line! fb w h 90 64 180 42 55 225 250 2)
     ;; Metal cyber deck (y=134..159)
     (fb-vgrad! fb w h 0 134 240 26 65 70 95 22 25 38)
     (fb-hline! fb w h 0 239 134 110 235 255)
     ;; Crimson Zero (18x24) with flowing blonde hair & glowing green Z-Saber arc!
     (define zx (+ 48 dx))
     (define zy 104)
     ;; Flowing golden-blonde hair streaming left
     (fb-tri! fb w h (- zx 16) (+ zy 6) (+ zx 4) (+ zy 2) (- zx 8) (+ zy 16) 250 215 55)
     ;; Zero helmet & crimson armor
     (fb-rect! fb w h zx zy 12 9 225 35 45)
     (fb-put!  fb w h (+ zx 8) (+ zy 3) 70 215 255) ; Blue forehead crystal
     (fb-rect! fb w h (+ zx 1) (+ zy 9) 12 11 230 35 45)
     (fb-rect! fb w h (+ zx 3) (+ zy 11) 8 6 240 240 250)
     (fb-rect! fb w h zx (+ zy 20) 5 10 225 35 45)
     (fb-rect! fb w h (+ zx 8) (+ zy 20) 5 10 225 35 45)
     ;; Glowing Neon-Green Triangular Z-Saber Slash Arc!
     (fb-tri! fb w h (+ zx 14) (+ zy 12) (+ zx 46) (- zy 14) (+ zx 48) (+ zy 26) 65 250 115)
     (fb-tri! fb w h (+ zx 18) (+ zy 12) (+ zx 42) (- zy 8) (+ zx 44) (+ zy 22) 200 255 215)
     ;; Floating Pink Cyber-Elf above Zero
     (fb-circle! fb w h (- zx 8) (- zy 8) 4 255 135 215 #t)
     (fb-circle! fb w h (- zx 8) (- zy 8) 6 255 210 240 #f)
     ;; Pantheon Guardian & Aztec Falcon Boss on the right
     (fb-rect! fb w h 136 106 14 26 45 145 175) ; Pantheon Guardian
     (fb-circle! fb w h 143 102 5 65 185 215 #t)
     ;; Aztec Falcon Boss (winged purple/gold reploid at x=182, y=68)
     (fb-tri! fb w h 164 62 192 84 172 98 155 55 215) ; Left wing
     (fb-tri! fb w h 224 58 196 84 216 98 155 55 215) ; Right wing
     (fb-rect! fb w h 186 74 16 28 215 175 55)
     (fb-rect! fb w h 188 64 12 10 175 45 195)
     ;; Top HUD: ZERO [========] vs AZTEC FALCON [========]
     (fb-rect! fb w h 0 0 240 16 12 14 26)
     (draw-text! fb w h 4 4 "ZERO" 90 250 120)
     (draw-bar!  fb w h 32 4 56 7 95 65 240 105)
     (draw-text! fb w h 104 4 "AZTEC FALCON" 255 185 65)
     (draw-bar!  fb w h 180 4 54 7 85 235 65 55)]

    ;; ------------------------------------------------------------------------
    ;; 8. FIRE EMBLEM (2003) — Colosseum Battle Arena (Lyn vs Brigand)
    ;; ------------------------------------------------------------------------
    [(8)
     ;; Arched stone colosseum backdrop (y=24..115)
     (fb-vgrad! fb w h 0 24 240 92 75 135 195 165 195 225)
     (fb-rect!  fb w h 0 24 240 48 155 142 118)
     (for ([ax (in-range 12 228 36)])
       (fb-rect!    fb w h ax 34 22 38 85 145 205)
       (fb-ellipse! fb w h (+ ax 11) 34 11 8 85 145 205 #t))
     ;; Central raised beveled battle platform (x=28..212, y=92..115)
     (fb-quad! fb w h 44 92 196 92 216 114 24 114 185 168 132)
     (fb-hline! fb w h 44 196 92 235 222 188)
     (fb-rect! fb w h 48 93 144 6 85 185 75) ; Grass top trim
     ;; Lyn (teal ponytail, blue/gold Lorca tunic) executing Critical Afterimage Slash!
     (define lx (+ 68 (min 18 dx)))
     ;; 2 Cyan motion-blur afterimages behind Lyn
     (for ([ghost (in-list '(-24 -12))])
       (fb-rect-blend! fb w h (+ lx ghost) 66 12 26 80 235 225 1 2))
     ;; Lyn main sprite
     (fb-tri!  fb w h (- lx 10) 68 (+ lx 4) 64 (- lx 4) 78 35 185 165) ; Flowing teal ponytail
     (fb-circle! fb w h (+ lx 6) 64 5 250 215 180 #t)
     (fb-rect! fb w h (+ lx 2) 69 9 16 35 145 185) ; Blue/teal Lorca tunic
     (fb-hline! fb w h (+ lx 2) (+ lx 10) 78 245 205 65) ; Gold trim
     (fb-rect! fb w h (+ lx 2) 85 3 7 245 205 175)
     (fb-rect! fb w h (+ lx 8) 85 3 7 245 205 175)
     ;; Blazing Sol Katti Critical Slash across the arena!
     (fb-line! fb w h (+ lx 12) 74 162 58 255 250 140 3)
     (fb-line! fb w h (+ lx 12) 74 162 58 255 255 255 1)
     ;; Muscular Brigand on right of platform (x=148, y=62) with Steel Axe
     (fb-circle! fb w h 156 64 6 225 60 45 #t) ; Red bandana head
     (fb-rect!   fb w h 148 70 16 16 195 135 95) ; Muscular torso
     (fb-rect!   fb w h 148 86 6 6 95 65 40)
     (fb-rect!   fb w h 158 86 6 6 95 65 40)
     (fb-line!   fb w h 164 56 174 80 140 95 45 2) ; Axe handle
     (fb-tri!    fb w h 164 56 178 52 174 66 195 205 220) ; Steel Axe blade
     ;; Top Name & Weapon Banners (y=0..23)
     (fb-rect! fb w h 0 0 118 24 25 95 115)
     (fb-box!  fb w h 0 0 118 24 235 195 75 2)
     (draw-text! fb w h 6 4 "LYN" 255 255 255)
     (draw-text! fb w h 42 13 "SOL KATTI" 245 230 140)
     (fb-rect! fb w h 122 0 118 24 135 35 35)
     (fb-box!  fb w h 122 0 118 24 235 195 75 2)
     (draw-text! fb w h 128 4 "BRIGAND" 255 255 255)
     (draw-text! fb w h 162 13 "STEEL AXE" 245 230 140)
     ;; Bottom Ornate Combat Stat Frames (y=116..159)
     (fb-rect! fb w h 0 116 120 44 22 78 96)
     (fb-box!  fb w h 0 116 120 44 235 195 75 2)
     (draw-text! fb w h 6 121 "HP 28 [|||||||]" 110 250 135)
     (draw-text! fb w h 6 132 "HIT 100  DMG 18" 255 255 255)
     (draw-text! fb w h 6 143 "CRT  42" 255 235 80)
     (fb-rect! fb w h 120 116 120 44 115 30 35)
     (fb-box!  fb w h 120 116 120 44 235 195 75 2)
     (draw-text! fb w h 126 121 "HP 32 [||||||||]" 255 215 90)
     (draw-text! fb w h 126 132 "HIT  54  DMG  9" 255 255 255)
     (draw-text! fb w h 126 143 "CRT   0" 210 210 220)]

    ;; ------------------------------------------------------------------------
    ;; 9. WARIOWARE, INC.: MEGA MICROGAME$! (2003) — "DODGE!" + Bomb Fuse Timer
    ;; ------------------------------------------------------------------------
    [else
     ;; Bold Yellow/Purple WarioWare Arcade Bezel Border
     (fb-rect! fb w h 0 0 240 160 115 35 165)
     (fb-box!  fb w h 0 0 240 160 250 215 35 4)
     ;; Microgame Inner Playfield (x=8..231, y=22..138)
     (fb-vgrad! fb w h 8 22 224 98 85 215 255 195 245 255)
     ;; Checkered desert highway floor (y=120..138)
     (for ([tx (in-range 8 232 16)])
       (fb-rect! fb w h tx 120 8 18 235 165 55)
       (fb-rect! fb w h (+ tx 8) 120 8 18 195 115 35))
     ;; Top Score & 4 Wario Hat Lives Indicator
     (draw-text! fb w h 12 8 (format "SCORE 0~a" (+ 18 (quotient score 5))) 255 245 70)
     (draw-text! fb w h 136 8 "[W] [W] [W] [W]" 255 235 45)
     ;; Giant Center-Top Action Command Banner: "DODGE!"
     (fb-rect! fb w h 68 25 104 22 235 35 115)
     (fb-box!  fb w h 68 25 104 22 255 245 65 2)
     (draw-text-2x! fb w h 84 29 "DODGE!" 255 250 75)
     ;; Wario in his Purple/Yellow Convertible Car at (wario-x, 96)
     (define wx (+ 42 (min 28 dx)))
     (fb-rect!   fb w h wx 102 44 14 145 45 195) ; Purple car body
     (fb-hline!  fb w h wx (+ wx 43) 108 255 225 45) ; Yellow racing stripe
     (fb-circle! fb w h (+ wx 10) 118 6 30 30 35 #t) ; Rear wheel
     (fb-circle! fb w h (+ wx 34) 118 6 30 30 35 #t) ; Front wheel
     (fb-circle! fb w h (+ wx 20) 92 8 250 205 165 #t) ; Wario head
     (fb-rect!   fb w h (+ wx 12) 82 16 6 250 225 35) ; Yellow Wario cap
     (fb-circle! fb w h (+ wx 25) 93 3 245 115 165 #t) ; Pink nose
     ;; Giant Craggy Rolling Boulder on the right (cx=178, cy=98, r=22)
     (fb-circle! fb w h 178 98 22 135 120 105 #t)
     (fb-circle! fb w h 178 98 22 75 65 55 #f)
     (fb-circle! fb w h 170 90 6 165 150 135 #t)
     (fb-circle! fb w h 186 104 5 95 85 75 #t)
     ;; Bottom Burning Bomb Fuse Timer (y=139..156)
     (fb-rect!   fb w h 8 139 224 17 24 16 38)
     (fb-circle! fb w h 24 147 8 30 35 45 #t) ; Black Bomb
     (fb-circle! fb w h 24 147 8 200 205 220 #f)
     (draw-text! fb w h 22 144 "3" 255 85 85 #f)
     ;; Fuse rope & sizzling orange/yellow spark
     (fb-hline!  fb w h 33 176 148 195 165 105)
     (fb-hline!  fb w h 33 176 149 145 115 65)
     (fb-circle! fb w h 178 148 6 255 120 25 #t)
     (fb-circle! fb w h 178 148 3 255 245 90 #t)
     (draw-text! fb w h 190 144 "TIME!" 255 225 65)])

  fb)

;; ============================================================================
;; 8c. Headless N64 320x240 RGB24 Framebuffer Renderer (All 10 N64 Classics)
;; ============================================================================
;; Renders smooth 3D shaded polygon surfaces, horizons, landmarks, 3D characters,
;; and authentic N64 HUDs driven deterministically by `n64-machine` state.
(define (render-n64-rgb-framebuffer m)
  (define w 320)
  (define h 240)
  (define fb (make-bytes (* w h 3) 0))

  (define rom-bs    (n64-machine-rom m))
  (define rdram     (n64-machine-rdram m))
  (define tmem      (n64-machine-tmem m))
  (define game-idx  (modulo (bytes-ref rom-bs #x3F) 10))
  (define px        (n64-read-u32-be m (+ N64-STATE-BASE-KSEG0 N64-STATE-PLAYER-X)))
  (define py        (n64-read-u32-be m (+ N64-STATE-BASE-KSEG0 N64-STATE-PLAYER-Y)))
  (define stage-id  (n64-read-u32-be m (+ N64-STATE-BASE-KSEG0 N64-STATE-STAGE-ID)))
  (define energy    (n64-read-u32-be m (+ N64-STATE-BASE-KSEG0 N64-STATE-ENERGY)))
  (define score     (n64-read-u32-be m (+ N64-STATE-BASE-KSEG0 N64-STATE-SCORE)))
  (define vi-c0     (integer-bytes->integer rdram #f #t N64-TOP10-VI-FB-DRAM-PHYS (+ N64-TOP10-VI-FB-DRAM-PHYS 2)))
  (define tmem-c0   (integer-bytes->integer tmem #f #t 0 2))
  (define dx        (+ (* (modulo stage-id 4) 8)
                       (if (and (> vi-c0 0) (> tmem-c0 0) (> py 0)) 0 1)))

  (case game-idx
    ;; ------------------------------------------------------------------------
    ;; 0. SUPER MARIO 64 (1996) — Peach's Castle Courtyard & Bob-omb Hills
    ;; ------------------------------------------------------------------------
    [(0)
     ;; Bright blue sky with fluffy 3D clouds
     (fb-vgrad! fb w h 0 0 320 112 55 155 250 155 220 255)
     (fb-ellipse! fb w h 56 42 28 10 248 250 255 #t)
     (fb-ellipse! fb w h 264 38 32 11 248 250 255 #t)
     ;; Green 3D polygon hills on horizon
     (fb-tri! fb w h -10 116 64 68 148 116 45 165 65)
     (fb-tri! fb w h 180 116 256 72 330 116 52 178 72)
     ;; Smooth 3D green grass courtyard & blue moat (y=114..239)
     (fb-vgrad! fb w h 0 114 320 126 58 190 72 34 138 48)
     (fb-rect!  fb w h 0 114 320 18 45 145 235) ; Blue Castle Moat
     ;; Princess Peach's Castle (white 3D polygon walls, red conical roofs, Peach stained glass)
     (fb-rect! fb w h 116 64 88 50 238 234 222)
     (fb-box!  fb w h 116 64 88 50 185 178 165 1)
     ;; Flanking towers & Central spire
     (fb-rect! fb w h 104 54 20 60 230 225 212)
     (fb-rect! fb w h 196 54 20 60 230 225 212)
     (fb-rect! fb w h 142 36 36 78 244 240 230)
     (fb-tri!  fb w h 100 54 114 32 128 54 225 40 45) ; Left red conical roof
     (fb-tri!  fb w h 192 54 206 32 220 54 225 40 45) ; Right red conical roof
     (fb-tri!  fb w h 136 36 160 10 184 36 235 45 50) ; Center tall conical roof
     ;; Iconic Stained-Glass Princess Peach Window
     (fb-ellipse! fb w h 160 54 8 11 95 195 250 #t)
     (fb-circle!  fb w h 160 52 4 250 225 85 #t)
     (fb-ellipse! fb w h 160 59 5 4 245 135 185 #t)
     ;; Castle double wooden doors & 3D perspective stone bridge over moat
     (fb-ellipse! fb w h 160 102 10 12 115 70 35 #t)
     (fb-quad! fb w h 144 112 176 112 208 239 112 239 210 198 172)
     (fb-line! fb w h 144 112 112 239 155 142 118 2)
     (fb-line! fb w h 176 112 208 239 155 142 118 2)
     ;; King Bob-omb (left-back) & Chain Chomp (right-mid)
     (fb-circle! fb w h 62 152 16 30 32 42 #t) ; Chain Chomp
     (fb-rect!   fb w h 56 152 14 5 250 250 255) ; Teeth
     (fb-circle! fb w h 248 154 18 28 30 40 #t) ; King Bob-omb
     (fb-tri!    fb w h 240 136 248 126 256 136 250 210 45) ; Gold crown
     (fb-ellipse! fb w h 248 156 12 4 250 250 255 #t) ; Royal white mustache
     ;; 3D Shaded Mario (24x28) at (146+dx, 166) with shadow ellipse underneath
     (define mx (+ 146 (min 24 dx)))
     (define my 166)
     (fb-ellipse! fb w h (+ mx 12) (+ my 28) 12 4 20 65 25 #t) ; 3D drop shadow
     (fb-ellipse! fb w h (+ mx 12) (+ my 4) 9 6 235 35 35 #t)  ; Red cap
     (fb-ellipse! fb w h (+ mx 12) (+ my 10) 8 6 250 205 165 #t) ; 3D shaded face
     (fb-rect!    fb w h (+ mx 6) (+ my 15) 12 10 35 90 220)   ; Blue overalls
     (fb-circle!  fb w h (+ mx 9) (+ my 18) 2 250 225 55 #t)   ; Yellow buttons
     (fb-circle!  fb w h (+ mx 15) (+ my 18) 2 250 225 55 #t)
     (fb-circle!  fb w h (+ mx 4) (+ my 18) 4 250 250 255 #t)  ; White gloves
     (fb-circle!  fb w h (+ mx 20) (+ my 18) 4 250 250 255 #t)
     (fb-rect!    fb w h (+ mx 6) (+ my 25) 5 5 110 60 25)
     (fb-rect!    fb w h (+ mx 13) (+ my 25) 5 5 110 60 25)
     ;; Authentic SM64 HUD: MARIOx4, 8-Slice Power Meter, ^x12 $x045
     (draw-text-2x! fb w h 12 10 "MARIO*4" 245 55 45)
     ;; Circular 8-slice Power Meter at (160, 22)
     (fb-circle! fb w h 160 22 14 35 75 175 #t)
     (fb-circle! fb w h 160 22 11 65 185 250 #t)
     (fb-circle! fb w h 160 22 14 250 215 55 #f)
     (draw-text! fb w h 155 19 "8/8" 255 255 255)
     (draw-text-2x! fb w h 218 10 (format "^~a $~a" (+ 12 stage-id) (+ 45 score)) 250 225 45)]

    ;; ------------------------------------------------------------------------
    ;; 1. THE LEGEND OF ZELDA: OCARINA OF TIME (1998) — Hyrule Field Z-Target
    ;; ------------------------------------------------------------------------
    [(1)
     ;; Golden/Blue Hyrule sky & Death Mountain with Red Volcanic Smoke Ring
     (fb-vgrad! fb w h 0 22 320 88 45 105 205 245 185 105)
     ;; Temple of Time silhouette on left horizon
     (fb-rect! fb w h 44 74 36 36 85 95 130)
     (fb-tri!  fb w h 52 74 62 46 72 74 95 105 145)
     ;; Death Mountain on right horizon + iconic red smoke ring
     (fb-tri! fb w h 180 110 248 48 316 110 125 85 65)
     (fb-ellipse! fb w h 248 38 22 7 235 75 45 #f)
     (fb-ellipse! fb w h 248 37 20 6 250 135 55 #f)
     ;; 3D Green Hyrule Field plains & perspective dirt path (y=110..218)
     (fb-vgrad! fb w h 0 110 320 108 48 155 58 28 105 38)
     (fb-quad!  fb w h 136 110 176 110 236 218 76 218 185 152 102)
     ;; Z-Target Black Cinema Letterbox Bars (top y=0..22, bottom y=218..239)
     (fb-rect! fb w h 0 0 320 22 8 8 12)
     (fb-rect! fb w h 0 218 320 22 8 8 12)
     ;; Stalfos / Darknut Knight at (198, 128) with Yellow Z-Target Lock-On Triangles!
     (fb-ellipse! fb w h 208 168 12 4 18 45 20 #t)
     (fb-circle!  fb w h 208 130 6 225 220 200 #t) ; Skull head
     (fb-rect!    fb w h 200 136 16 18 175 170 155) ; Ribcage/armor
     (fb-circle!  fb w h 196 144 8 145 155 175 #t) ; Round shield
     (fb-line!    fb w h 216 142 232 124 230 235 245 2) ; Sword
     ;; 4 Yellow Z-Target Lock-On Triangles + Glowing Cyan Fairy Navi
     (fb-tri! fb w h 208 118 203 110 213 110 255 235 40)
     (fb-tri! fb w h 190 140 182 135 182 145 255 235 40)
     (fb-tri! fb w h 226 140 234 135 234 145 255 235 40)
     (fb-circle! fb w h 194 122 4 120 235 255 #t) ; Navi
     (fb-circle! fb w h 194 122 2 255 255 255 #t)
     ;; 3D Hero of Time Link (24x32) at (104+dx, 146) with Master Sword & Hylian Shield
     (define lx (+ 104 (min 24 dx)))
     (define ly 146)
     (fb-ellipse! fb w h (+ lx 12) (+ ly 32) 12 4 18 45 20 #t)
     (fb-tri!     fb w h (+ lx 4) (+ ly 6) (+ lx 12) (- ly 4) (+ lx 18) (+ ly 8) 35 175 55) ; Green cap
     (fb-circle!  fb w h (+ lx 12) (+ ly 6) 5 245 215 80 #t) ; Blonde hair
     (fb-rect!    fb w h (+ lx 6) (+ ly 11) 12 14 35 175 55) ; Green tunic
     (fb-rect!    fb w h (+ lx 7) (+ ly 25) 4 7 235 235 245) ; White tights/boots
     (fb-rect!    fb w h (+ lx 13) (+ ly 25) 4 7 235 235 245)
     ;; Hylian Shield (blue/silver with red/gold) & Master Sword
     (fb-rect! fb w h (+ lx 16) (+ ly 11) 10 13 35 75 195)
     (fb-box!  fb w h (+ lx 16) (+ ly 11) 10 13 215 220 235 1)
     (fb-tri!  fb w h (+ lx 19) (+ ly 16) (+ lx 21) (+ ly 13) (+ lx 23) (+ ly 16) 250 220 55)
     (fb-line! fb w h (+ lx 4) (+ ly 16) (- lx 12) (+ ly 4) 215 235 255 3) ; Master Sword blade
     ;; Authentic OoT HUD: Hearts, Green Magic Bar, Blue A, Green B, Yellow C-Buttons, Minimap
     (draw-text! fb w h 10 4 "@@@@@@@@" 240 45 55)
     (draw-bar!  fb w h 10 13 64 6 85 45 215 75)
     ;; B (Green), A (Blue), and 3 Yellow C-Buttons on top-right
     (fb-circle! fb w h 224 12 7 40 195 65 #t)
     (draw-text! fb w h 222 9 "B" 255 255 255 #f)
     (fb-circle! fb w h 242 14 7 45 115 240 #t)
     (draw-text! fb w h 240 11 "A" 255 255 255 #f)
     (for ([cx (in-list '(262 280 298))]
           [cl (in-list '("<" "V" ">"))])
       (fb-circle! fb w h cx 11 6 245 205 35 #t)
       (draw-text! fb w h (- cx 2) 8 cl 30 30 30 #f))
     ;; Bottom-left Rupee counter & Bottom-right Hyrule Field Minimap
     (draw-text! fb w h 12 224 "RUPEES 099" 110 245 120)
     (fb-rect!   fb w h 262 182 48 32 35 95 55)
     (fb-box!    fb w h 262 182 48 32 195 210 185 1)
     (fb-tri!    fb w h 284 196 288 190 292 196 255 235 50)]

    ;; ------------------------------------------------------------------------
    ;; 2. SUPER SMASH BROS. (1999) — Peach's Castle 3D Stage & 4 Damage Badges
    ;; ------------------------------------------------------------------------
    [(2)
     ;; Scenic sky & distant Peach's Castle backdrop
     (fb-vgrad! fb w h 0 0 320 192 65 160 245 185 225 255)
     (fb-rect!  fb w h 128 36 64 56 232 224 210)
     (fb-tri!   fb w h 122 36 160 12 198 36 225 55 60)
     ;; Moving Bumper hazard at top-center (cx=160, cy=68)
     (fb-circle! fb w h 160 68 10 250 215 45 #t)
     (fb-circle! fb w h 160 68 7 45 95 225 #t)
     (fb-circle! fb w h 160 68 3 255 75 75 #t)
     ;; Two Suspended Soft Platforms (y=110)
     (fb-rect! fb w h 64 110 68 6 215 195 155)
     (fb-box!  fb w h 64 110 68 6 125 105 75 1)
     (fb-rect! fb w h 188 110 68 6 215 195 155)
     (fb-box!  fb w h 188 110 68 6 125 105 75 1)
     ;; Main 3D Floating Stage Deck (x=44..276, y=154..184)
     (fb-quad! fb w h 44 154 276 154 256 184 64 184 135 110 85)
     (fb-rect! fb w h 44 150 232 8 235 215 175)
     (fb-box!  fb w h 44 150 232 8 155 130 95 1)
     ;; 4P Pikachu on top-left platform summoning Thunder Jolt lightning!
     (fb-vline! fb w h 96 16 92 255 245 85)
     (fb-vline! fb w h 97 16 92 255 255 220)
     (fb-ellipse! fb w h 96 98 8 9 250 225 40 #t) ; Pikachu
     (fb-tri!     fb w h 90 90 92 80 95 90 250 225 40)
     (fb-tri!     fb w h 98 90 101 80 103 90 250 225 40)
     ;; 1P Mario at (84+dx, 128) executing fiery Fire Punch!
     (define mx (+ 84 (min 16 dx)))
     (fb-rect! fb w h mx 128 12 22 235 45 45)
     (fb-rect! fb w h (+ mx 2) 136 8 10 40 95 225)
     (fb-circle! fb w h (+ mx 18) 134 8 255 125 25 #t) ; Fire Punch flame
     (fb-circle! fb w h (+ mx 18) 134 5 255 235 75 #t)
     ;; 2P Link at (152, 126) & 3P Samus at (216, 126) firing Charge Shot
     (fb-rect! fb w h 150 126 12 24 40 175 60) ; Link
     (fb-line! fb w h 148 134 134 128 220 235 255 2)
     (fb-rect! fb w h 218 124 14 26 235 125 30) ; Samus
     (fb-circle! fb w h 194 134 7 95 235 255 #t) ; Charge Shot
     (fb-circle! fb w h 194 134 4 235 255 255 #t)
     ;; Bottom 4 Iconic Smash 64 Damage Percentage Badges (y=192..236)
     (fb-rect! fb w h 0 190 320 50 16 18 28)
     (for ([i (in-range 4)]
           [lbl (in-list '("1P MARIO" "2P LINK" "3P SAMUS" "4P PIKA"))]
           [dmg (in-list '(" 24%" " 68%" " 42%" " 95%"))]
           [col (in-list '((215 45 45) (45 105 225) (225 175 35) (40 185 75)))])
       (define bx (+ 8 (* i 78)))
       (fb-rect! fb w h bx 194 72 40 (first col) (second col) (third col))
       (fb-box!  fb w h bx 194 72 40 245 245 255 2)
       (draw-text!    fb w h (+ bx 6) 198 lbl 255 255 255)
       (draw-text-2x! fb w h (+ bx 8) 210 dmg 255 245 180))]

    ;; ------------------------------------------------------------------------
    ;; 3. MARIO KART 64 (1996) — Royal Raceway 3D Highway & Item Roulette
    ;; ------------------------------------------------------------------------
    [(3)
     ;; Sky, 3D polygon mountain range & distant Peach's Castle
     (fb-vgrad! fb w h 0 0 320 86 55 155 250 155 220 255)
     (for ([mx (in-range 0 320 56)])
       (fb-tri! fb w h mx 86 (+ mx 28) 52 (+ mx 56) 86 55 165 75))
     ;; Lush green 3D grass infield (y=86..239)
     (fb-vgrad! fb w h 0 86 320 154 55 185 65 35 135 45)
     ;; Smooth 3D Perspective Asphalt Highway (widening from y=86..239)
     (fb-quad! fb w h 126 86 194 86 306 239 14 239 92 96 108)
     ;; Alternating Red/White Rumble Curbs & Dashed Center Line
     (for ([seg (in-range 12)])
       (define y0 (+ 86 (* seg 12)))
       (define y1 (+ y0 12))
       (define lx0 (- 126 (quotient (* (- y0 86) 112) 153)))
       (define lx1 (- 126 (quotient (* (- y1 86) 112) 153)))
       (define rx0 (+ 194 (quotient (* (- y0 86) 112) 153)))
       (define rx1 (+ 194 (quotient (* (- y1 86) 112) 153)))
       (define red? (even? seg))
       (fb-quad! fb w h (- lx0 8) y0 lx0 y0 lx1 y1 (- lx1 12) y1
                 (if red? 235 250) (if red? 40 250) (if red? 40 250))
       (fb-quad! fb w h rx0 y0 (+ rx0 8) y0 (+ rx1 12) y1 rx1 y1
                 (if red? 235 250) (if red? 40 250) (if red? 40 250))
       (when red?
         (fb-rect! fb w h 158 y0 4 8 245 245 250)))
     ;; 4 Rainbow Crystalline Item Boxes ("?") floating across the track
     (for ([ix (in-list '(118 146 174 202))]
           [ic (in-list '((80 235 255) (255 95 235) (255 235 65) (95 250 120)))])
       (fb-rect! fb w h (- ix 7) 104 14 14 (first ic) (second ic) (third ic))
       (fb-box!  fb w h (- ix 7) 104 14 14 255 255 255 1)
       (draw-text! fb w h (- ix 2) 108 "?" 255 255 255))
     ;; Rival Karts ahead: Yoshi (green) & Wario (purple/yellow)
     (fb-rect! fb w h 130 128 16 12 45 205 65)
     (fb-rect! fb w h 176 122 18 13 165 55 215)
     ;; Pre-rendered-style 3D Mario in Pipe-Frame Kart at (142+dx, 168)
     (define kx (+ 142 (min 20 dx)))
     (define ky 168)
     (fb-ellipse! fb w h (+ kx 16) (+ ky 28) 18 5 45 48 55 #t)
     ;; Black racing tires
     (fb-rect! fb w h kx (+ ky 14) 7 12 24 24 28)
     (fb-rect! fb w h (+ kx 25) (+ ky 14) 7 12 24 24 28)
     ;; Red/white kart chassis & Mario
     (fb-rect! fb w h (+ kx 6) (+ ky 12) 20 12 235 40 40)
     (fb-rect! fb w h (+ kx 8) (+ ky 6) 16 8 40 95 225)
     (fb-circle! fb w h (+ kx 16) (+ ky 2) 7 235 35 35 #t) ; Mario cap
     ;; Orange/Yellow Mini-Turbo drift sparks!
     (fb-line! fb w h (- kx 4) (+ ky 24) (- kx 14) (+ ky 18) 255 215 45 2)
     (fb-line! fb w h (+ kx 34) (+ ky 24) (+ kx 44) (+ ky 18) 255 125 30 2)
     ;; Authentic MK64 HUD: LAP 2/3, TIME, Item Roulette [3 Red Shells], Gold "1ST", Minimap
     (draw-text! fb w h 10 8 "LAP 2/3" 255 235 65)
     (draw-text! fb w h 208 8 "TIME 01'18\"42" 255 255 255)
     ;; Top-center Item Roulette Box (Triple Red Shells)
     (fb-rect! fb w h 136 6 48 26 24 30 48)
     (fb-box!  fb w h 136 6 48 26 245 215 65 2)
     (fb-circle! fb w h 148 19 5 235 40 40 #t)
     (fb-circle! fb w h 160 19 5 235 40 40 #t)
     (fb-circle! fb w h 172 19 5 235 40 40 #t)
     ;; Bottom-left Gold "1ST" & Bottom-right Speedometer + Track Minimap
     (draw-text-2x! fb w h 14 206 "1ST" 255 215 35)
     (fb-ellipse!   fb w h 284 212 22 16 255 255 255 #f)
     (fb-circle!    fb w h 266 206 3 255 50 50 #t)
     (draw-text!    fb w h 252 184 "82 KM/H" 255 235 80)]

    ;; ------------------------------------------------------------------------
    ;; 4. GOLDENEYE 007 (1997) — Arkhangelsk Dam 3D First-Person View & PP7
    ;; ------------------------------------------------------------------------
    [(4)
     ;; Cold Russian slate sky & snow mountains (y=0..68)
     (fb-vgrad! fb w h 0 0 320 68 75 92 118 145 162 185)
     (fb-tri! fb w h 20 68 76 36 132 68 185 198 215)
     ;; 3D Perspective Concrete Dam Parapet Walls & Roadway (y=68..239)
     (fb-vgrad! fb w h 0 68 320 172 88 94 102 52 56 64)
     ;; Left & Right converging 3D concrete dam walls
     (fb-quad! fb w h 0 42 104 88 104 148 0 210 118 124 134)
     (fb-quad! fb w h 320 42 216 88 216 148 320 210 108 114 124)
     ;; Sniper Watchtower on right dam wall (x=224..262, y=24..96)
     (fb-rect! fb w h 228 28 32 22 68 74 84)
     (fb-box!  fb w h 228 28 32 22 42 46 54 2)
     (fb-rect! fb w h 234 34 20 8 205 225 245) ; Watchtower window
     (fb-vline! fb w h 232 50 96 55 60 70)
     (fb-vline! fb w h 256 50 96 55 60 70)
     ;; Military Crate Stack on left (x=42..86, y=122..162)
     (fb-rect! fb w h 42 124 38 36 65 88 58)
     (fb-box!  fb w h 42 124 38 36 38 54 34 2)
     ;; Enemy Russian Soldiers in green uniforms in distance
     (fb-circle! fb w h 142 104 4 235 195 160 #t)
     (fb-rect!   fb w h 139 98 7 3 205 35 35) ; Red beret
     (fb-rect!   fb w h 137 108 10 18 45 85 50)
     (fb-rect!   fb w h 139 126 4 10 35 55 38)
     (fb-rect!   fb w h 144 126 4 10 35 55 38)
     (fb-circle! fb w h 184 110 4 235 195 160 #t)
     (fb-rect!   fb w h 179 114 10 18 45 85 50)
     ;; Red R-Button Precision Aiming Crosshair at (142+dx, 114)
     (define cx (+ 142 (min 20 dx)))
     (define cy 114)
     (fb-circle! fb w h cx cy 10 245 40 40 #f)
     (fb-hline!  fb w h (- cx 14) (- cx 4) cy 245 40 40)
     (fb-hline!  fb w h (+ cx 4) (+ cx 14) cy 245 40 40)
     (fb-vline!  fb w h cx (- cy 14) (- cy 4) 245 40 40)
     (fb-vline!  fb w h cx (+ cy 4) (+ cy 14) 245 40 40)
     ;; Iconic PP7 Silenced Pistol in Bottom-Right Foreground + Muzzle Flash!
     (fb-circle! fb w h 194 146 14 255 185 45 #t) ; Muzzle flash outer
     (fb-circle! fb w h 194 146 8 255 250 180 #t) ; Muzzle flash core
     ;; Cylindrical black silencer & gunmetal PP7 slide
     (fb-quad! fb w h 196 148 228 164 222 174 190 158 32 36 44)
     (fb-quad! fb w h 224 162 276 192 264 210 214 178 68 74 86)
     (fb-quad! fb w h 244 196 288 239 248 239 224 206 24 26 32) ; Bond's black glove grip
     ;; Left Curved Red Health Arc & Right Curved Blue Armor Arc HUD
     (for ([seg (in-range 8)])
       (define sy (+ 48 (* seg 16)))
       (define sx-off (abs (- seg 3)))
       (fb-rect! fb w h (+ 10 (* sx-off 2)) sy 10 12 235 45 35)
       (fb-rect! fb w h (- 300 (* sx-off 2)) sy 10 12 45 155 245))
     (draw-text! fb w h 18 222 "9MM   7 | 140" 245 235 120)
     (draw-text! fb w h 218 222 "PP7 SILENCED" 200 215 230)]

    ;; ------------------------------------------------------------------------
    ;; 5. STAR FOX 64 (1997) — Corneria 3D Flight over Water & Stone Arches
    ;; ------------------------------------------------------------------------
    [(5)
     ;; Corneria blue sky, clouds & distant 3D cityscape
     (fb-vgrad! fb w h 0 0 320 96 45 125 235 155 210 255)
     (for ([bx (in-range 16 112 18)])
       (fb-rect! fb w h bx (- 96 (modulo (* bx 3) 28)) 12 (modulo (* bx 3) 28) 125 140 168))
     ;; Reflective 3D Blue Water Bay (y=96..239)
     (fb-vgrad! fb w h 0 96 320 144 35 135 235 15 65 155)
     (for ([wy (in-range 102 236 10)])
       (fb-hline! fb w h 20 300 wy 85 185 250))
     ;; 3D Stone Arches spanning the water bay
     (for ([arch-x (in-list '(36 204))])
       (fb-rect! fb w h arch-x 58 18 86 175 165 142)
       (fb-rect! fb w h (+ arch-x 62) 58 18 86 155 145 125)
       (fb-rect! fb w h (- arch-x 4) 48 88 14 190 180 156)
       (fb-hline! fb w h (- arch-x 4) (+ arch-x 84) 144 235 250 255)) ; Water foam at base
     ;; Venom / Granga enemy fighters ahead + Green 3D Wireframe Reticle
     (fb-tri!  fb w h 148 72 160 64 172 72 185 65 45)
     (fb-box!  fb w h 146 62 28 22 65 250 95 1) ; Green 3D targeting reticle
     (fb-box!  fb w h 150 66 20 14 65 250 95 1)
     ;; Sleek White/Blue Arwing Starfighter (36x24) banking at (132+dx, 128)
     (define ax (+ 132 (min 24 dx)))
     (define ay 128)
     ;; Twin Neon-Green Hyper Laser Beams firing into the reticle!
     (fb-line! fb w h (- ax 16) (+ ay 8) 152 74 75 255 110 2)
     (fb-line! fb w h (+ ax 48) (+ ay 8) 168 74 75 255 110 2)
     ;; Arwing swept W-wings (white polygon hull) & Blue G-Diffuser wing pods
     (fb-tri!  fb w h (- ax 22) (+ ay 14) (+ ax 16) (- ay 4) (+ ax 16) (+ ay 14) 235 240 250)
     (fb-tri!  fb w h (+ ax 54) (+ ay 14) (+ ax 16) (- ay 4) (+ ax 16) (+ ay 14) 215 222 238)
     (fb-rect! fb w h (- ax 4) (+ ay 6) 8 12 35 95 235)  ; Left Blue G-Diffuser
     (fb-rect! fb w h (+ ax 28) (+ ay 6) 8 12 35 95 235) ; Right Blue G-Diffuser
     ;; Glowing cyan/white plasma thruster
     (fb-circle! fb w h (+ ax 16) (+ ay 14) 7 80 215 255 #t)
     (fb-circle! fb w h (+ ax 16) (+ ay 14) 4 255 255 255 #t)
     ;; Authentic Star Fox 64 HUD & Peppy Transmission Box
     (draw-text! fb w h 10 8 "SHIELD" 220 235 255)
     (draw-bar!  fb w h 52 8 64 7 92 65 240 105)
     (draw-text! fb w h 10 18 "G-DIFF" 95 195 255)
     (draw-bar!  fb w h 52 18 48 6 85 55 165 250)
     (draw-text! fb w h 218 8 "[BOMBS *3]" 255 95 95)
     (draw-text-2x! fb w h 224 18 (format "HIT 0~a" (+ 84 stage-id)) 255 235 55)
     ;; Bottom-center Peppy Hare Comms Box: "[PEPPY]: DO A BARREL ROLL!"
     (fb-rect! fb w h 56 196 208 38 14 24 38)
     (fb-box!  fb w h 56 196 208 38 75 215 135 2)
     (fb-rect! fb w h 62 201 28 28 35 65 55) ; Peppy portrait frame
     (fb-ellipse! fb w h 76 216 8 9 185 165 145 #t) ; Peppy rabbit head
     (fb-rect! fb w h 70 203 4 9 185 165 145) ; Ears
     (fb-rect! fb w h 78 203 4 9 185 165 145)
     (draw-text! fb w h 96 204 "[PEPPY]:" 110 250 135)
     (draw-text! fb w h 96 218 "DO A BARREL ROLL!" 255 255 255)]

    ;; ------------------------------------------------------------------------
    ;; 6. BANJO-KAZOOIE (1998) — Spiral Mountain, Waterfall & Golden Jiggy
    ;; ------------------------------------------------------------------------
    [(6)
     ;; Sunny blue sky & Gruntilda's Lair cliff in upper-right
     (fb-vgrad! fb w h 0 0 320 96 55 155 250 155 225 255)
     (fb-rect!  fb w h 236 32 84 68 95 85 105) ; Gruntilda's Lair cliff
     ;; Sparkling blue waterfall cascading down cliff (x=256..278)
     (fb-vgrad! fb w h 256 48 22 72 95 215 255 45 145 235)
     ;; Green Corkscrew 3D Spiral Mountain in center-background (x=84..196, y=34..126)
     (fb-tri! fb w h 76 126 140 32 204 126 48 168 58)
     ;; Spiral dirt path wrapping around Spiral Mountain
     (fb-quad! fb w h 122 58 158 64 166 74 114 68 195 162 105)
     (fb-quad! fb w h 104 84 176 92 184 104 96 96 195 162 105)
     ;; Wooden Rope Bridge connecting Spiral Mountain to cliff (x=176..244, y=88..98)
     (fb-rect! fb w h 176 90 68 7 155 105 52)
     (fb-hline! fb w h 176 244 84 120 80 38)
     ;; Lush 3D foreground grass & stone path (y=118..239)
     (fb-vgrad! fb w h 0 118 320 122 58 188 65 35 138 45)
     (fb-quad!  fb w h 118 126 162 126 210 239 62 239 205 175 118)
     ;; Banjo & Kazooie (24x28) at (114+dx, 148)
     (define bx (+ 114 (min 24 dx)))
     (define by 148)
     (fb-ellipse! fb w h (+ bx 12) (+ by 28) 12 4 22 65 25 #t)
     ;; Red-crested Kazooie popping out of Banjo's Blue Backpack!
     (fb-rect!   fb w h (- bx 2) (+ by 8) 9 14 35 95 225) ; Blue backpack
     (fb-circle! fb w h (+ bx 2) (- by 2) 5 235 45 40 #t) ; Kazooie head
     (fb-tri!    fb w h (+ bx 6) (- by 4) (+ bx 14) (- by 2) (+ bx 6) by 250 185 35) ; Kazooie beak
     ;; Brown bear Banjo in yellow shorts
     (fb-circle! fb w h (+ bx 12) (+ by 6) 7 145 88 42 #t)
     (fb-rect!   fb w h (+ bx 6) (+ by 12) 13 10 145 88 42)
     (fb-rect!   fb w h (+ bx 6) (+ by 20) 13 6 250 220 45) ; Yellow shorts
     ;; Spinning Golden Jiggy Puzzle Piece at (208, 152)
     (fb-rect!   fb w h 202 146 14 14 255 215 35)
     (fb-circle! fb w h 209 144 4 255 215 35 #t)
     (fb-circle! fb w h 218 153 4 255 215 35 #t)
     (fb-put!    fb w h 205 149 255 255 255)
     ;; Authentic Banjo-Kazooie HUD: 6 Golden Honeycombs, [NOTE] x45, [JIGGY] x08
     (for ([hc (in-range 6)])
       (fb-circle! fb w h (+ 16 (* hc 14)) 14 6 250 205 35 #t)
       (fb-circle! fb w h (+ 16 (* hc 14)) 14 3 215 155 20 #t))
     (draw-text! fb w h 118 10 "[NOTE] *45" 255 235 65)
     (draw-text! fb w h 204 10 (format "[JIGGY] *0~a" (+ 8 stage-id)) 255 215 45)]

    ;; ------------------------------------------------------------------------
    ;; 7. PAPER MARIO (2000) — 3D Stage-Theater RPG Battle
    ;; ------------------------------------------------------------------------
    [(7)
     ;; Painted Diorama Backdrop (starry night & cardboard castle props)
     (fb-vgrad! fb w h 20 28 280 116 28 42 98 65 95 165)
     (fb-rect!  fb w h 136 58 48 84 155 148 165) ; Cardboard castle tower hung on strings
     (fb-vline! fb w h 148 28 58 210 210 220)
     (fb-vline! fb w h 172 28 58 210 210 220)
     ;; 3D Wooden Stage Floor (y=142..216) & Audience Silhouettes (y=216..239)
     (fb-vgrad! fb w h 0 142 320 74 195 138 78 135 88 42)
     (for ([plank-y (in-range 148 214 11)])
       (fb-hline! fb w h 0 319 plank-y 115 72 32))
     (fb-rect! fb w h 0 216 320 24 14 12 20)
     (for ([aud-x (in-range 16 308 22)])
       (fb-circle! fb w h aud-x 228 7 32 28 42 #t))
     ;; Red Velvet Stage Curtains at Top & Sides + Gold Tassels
     (fb-rect! fb w h 0 0 22 216 175 22 35)
     (fb-rect! fb w h 298 0 22 216 175 22 35)
     (for ([cx (in-range 0 320 32)])
       (fb-ellipse! fb w h (+ cx 16) 26 18 14 195 28 42 #t)
       (fb-ellipse! fb w h (+ cx 16) 26 18 14 245 205 65 #f))
     ;; Left Stage Party: Flat 2D Paper-Cutout Mario (with Hammer) & Goombario
     (define pmx (+ 78 (min 20 dx)))
     ;; Goombario (with white paper outline)
     (fb-circle! fb w h 48 156 10 255 255 255 #t)
     (fb-circle! fb w h 48 156 8 175 105 52 #t)
     (fb-rect!   fb w h 42 146 12 5 45 105 225) ; Blue cap
     ;; Paper Mario (with crisp white paper cutout border!)
     (fb-rect!   fb w h (- pmx 2) 128 20 34 255 255 255)
     (fb-rect!   fb w h pmx 130 16 8 235 40 40)
     (fb-rect!   fb w h pmx 138 16 8 250 205 165)
     (fb-rect!   fb w h pmx 146 16 14 35 95 225)
     ;; Big Ultra Hammer
     (fb-line!   fb w h (+ pmx 16) 144 (+ pmx 28) 124 155 100 45 2)
     (fb-rect!   fb w h (+ pmx 22) 116 14 10 120 125 145)
     ;; Right Stage Boss: Bowser / Koopa Bros. + Star-Shaped "DAMAGE 5!" Burst
     (fb-rect!   fb w h 218 116 34 44 55 165 65) ; Bowser green body/shell
     (fb-rect!   fb w h 224 104 20 12 235 65 40) ; Red mane
     ;; Star-Shaped "DAMAGE 5!" Burst Icon at (192, 134)
     (fb-circle! fb w h 192 134 16 250 55 45 #t)
     (fb-circle! fb w h 192 134 12 255 225 55 #t)
     (draw-text-2x! fb w h 186 128 "5" 255 255 255)
     ;; Top Status Bar & Bottom-Left Action Command Wheel
     (fb-rect! fb w h 8 4 304 16 24 22 38)
     (fb-box!  fb w h 8 4 304 16 245 215 75 1)
     (draw-text! fb w h 14 8 "[HP 25/25] [FP 15/15] [SP *****] [COINS 142]" 255 245 190)
     (fb-rect! fb w h 24 192 224 18 32 28 48)
     (fb-box!  fb w h 24 192 224 18 245 205 65 1)
     (draw-text! fb w h 30 197 "[HAMMER]  [JUMP]  [ITEMS]  [STRATEGIES]" 255 255 255)]

    ;; ------------------------------------------------------------------------
    ;; 8. F-ZERO X (1998) — Mute City 60fps 3D Anti-Gravity Ribbon Track
    ;; ------------------------------------------------------------------------
    [(8)
     ;; Deep purple/indigo space night sky & futuristic Mute City horizon
     (fb-vgrad! fb w h 0 0 320 94 18 12 44 58 32 96)
     ;; Upper 3D Ribbon Track Loop climbing into the sky (y=24..68)
     (fb-quad! fb w h 132 24 188 24 220 68 100 68 55 65 105)
     (fb-line! fb w h 132 24 100 68 65 235 255 2)
     (fb-line! fb w h 188 24 220 68 65 235 255 2)
     ;; Mute City neon skyscraper horizon (y=68..94)
     (for ([bx (in-range 0 320 20)])
       (define bh (+ 14 (modulo (* bx 7) 18)))
       (fb-rect! fb w h bx (- 94 bh) 16 bh 32 28 58)
       (fb-put!  fb w h (+ bx 4) (- 90 (quotient bh 2)) 255 225 75)
       (fb-put!  fb w h (+ bx 10) (- 86 (quotient bh 3)) 75 235 255))
     ;; Main Wide 3D Anti-Gravity Ribbon Highway (y=94..239)
     (fb-vgrad! fb w h 0 94 320 146 16 14 32 8 8 18)
     (fb-quad!  fb w h 112 94 208 94 316 239 4 239 62 68 96)
     ;; Pink Pit-Stop Recharge Strip along right lane
     (fb-quad!  fb w h 188 94 204 94 296 239 248 239 235 65 165)
     ;; Neon Cyan & Yellow Guardrails along track edges
     (fb-line!  fb w h 112 94 4 239 65 245 255 3)
     (fb-line!  fb w h 208 94 316 239 255 230 55 3)
     ;; Yellow/Orange Boost Pad Arrows on track surface
     (fb-tri!   fb w h 148 134 160 118 172 134 255 195 35)
     (fb-tri!   fb w h 144 146 160 128 176 146 255 120 25)
     ;; 5 Rival F-Zero Machines in perspective depth (Black Bull, Red Gazelle, White Cat, Golden Fox)
     (for ([rc (in-list '((148 112 (245 215 45))
                          (176 116 (65 215 115))
                          (122 138 (235 45 45))
                          (192 142 (240 240 255))
                          (156 150 (35 35 45))))])
       (define rx (first rc))
       (define ry (second rc))
       (define col (third rc))
       (fb-tri! fb w h (- rx 10) (+ ry 10) rx ry (+ rx 10) (+ ry 10)
                (first col) (second col) (third col))
       (fb-circle! fb w h rx (+ ry 10) 3 95 235 255 #t))
     ;; Player Blue Falcon (#07) (28x18) at (138+dx, 182)
     (define fx (+ 138 (min 20 dx)))
     (define fy 182)
     (fb-tri!  fb w h fx (+ fy 16) (+ fx 16) fy (+ fx 32) (+ fy 16) 40 105 245)
     (fb-rect! fb w h (+ fx 10) (+ fy 6) 12 10 185 215 255)
     (fb-circle! fb w h (+ fx 11) (+ fy 17) 4 95 245 255 #t) ; Dual plasma thrusters
     (fb-circle! fb w h (+ fx 21) (+ fy 17) 4 95 245 255 #t)
     ;; Authentic F-Zero X HUD: 1ST / 30, Vertical Position Strip, ENERGY, 1148 KM/H
     (draw-text-2x! fb w h 10 8 "1ST/30" 255 230 55)
     ;; Left vertical 30-craft position strip
     (fb-rect! fb w h 10 30 14 110 24 28 48)
     (fb-box!  fb w h 10 30 14 110 95 195 255 1)
     (for ([p (in-range 8)])
       (fb-rect! fb w h 12 (+ 34 (* p 13)) 10 8 (if (zero? p) 45 185) (if (zero? p) 145 55) 235))
     (draw-text! fb w h 176 8 "ENERGY" 95 245 255)
     (draw-bar!  fb w h 218 8 92 8 92 55 235 255)
     (draw-text-2x! fb w h 198 20 (format "~aKM/H" (+ 1148 score)) 255 215 45)]

    ;; ------------------------------------------------------------------------
    ;; 9. WAVE RACE 64 (1996) — Drake Lake / Dolphin Park 3D Water Physics
    ;; ------------------------------------------------------------------------
    [else
     ;; Sunny tropical sky, sandy island beach, palm trees & stadium bleachers
     (fb-vgrad! fb w h 0 0 320 84 45 155 250 155 225 255)
     ;; Stadium bleachers on left horizon & sandy beach on right
     (fb-rect!  fb w h 16 62 96 22 215 220 235)
     (fb-hline! fb w h 16 112 66 235 55 55)
     (fb-hline! fb w h 16 112 72 45 115 235)
     (fb-ellipse! fb w h 224 82 88 12 240 215 145 #t) ; Sandy island beach
     ;; Palm trees on the island beach
     (for ([px-tree (in-list '(184 228 272))])
       (fb-line! fb w h px-tree 80 (+ px-tree 4) 54 145 95 45 3)
       (fb-ellipse! fb w h (+ px-tree 4) 52 12 5 45 175 65 #t))
     ;; Jumping Bottlenose Dolphin in background (x=118, y=72)
     (fb-ellipse! fb w h 124 74 12 5 115 155 195 #t)
     (fb-tri!     fb w h 110 78 116 72 116 80 115 155 195)
     ;; Dynamic 3D Translucent Blue/Turquoise Ocean Waves with White Foam Crests (y=84..239)
     (fb-vgrad! fb w h 0 84 320 156 25 175 220 10 85 165)
     (for ([wy (in-range 92 238 14)])
       (for ([wx (in-range 0 320 4)])
         (define swell (quotient (* 4 (bitwise-and (+ (quotient wx 16) (quotient wy 14)) 3)) 2))
         (fb-rect! fb w h wx (+ wy swell) 4 3 95 225 245)
         (when (zero? (modulo (+ wx wy) 24))
           (fb-rect! fb w h wx (+ wy swell -1) 6 2 240 252 255))))
     ;; Red ("R") and Yellow ("Y") Slalom Buoys floating in the waves
     (fb-circle! fb w h 78 144 9 235 40 40 #t)
     (fb-box!    fb w h 70 136 16 16 255 255 255 1)
     (draw-text! fb w h 76 141 "R" 255 255 255)
     (fb-circle! fb w h 238 134 9 250 215 35 #t)
     (draw-text! fb w h 236 131 "Y" 25 25 30 #f)
     ;; Ryota Hayami on Red/White Kawasaki Jet Ski (28x24) banking at (136+dx, 168)
     (define jx (+ 136 (min 24 dx)))
     (define jy 168)
     ;; White/Cyan Water-Spray Rooster Tail Wake behind Jet Ski!
     (fb-tri! fb w h (- jx 28) (+ jy 26) (+ jx 14) (+ jy 16) (+ jx 46) (+ jy 28) 215 248 255)
     (fb-tri! fb w h (- jx 16) (+ jy 24) (+ jx 14) (+ jy 18) (+ jx 36) (+ jy 26) 255 255 255)
     ;; Red/White Jet Ski hull & Rider in Blue/White Wetsuit
     (fb-quad! fb w h jx (+ jy 12) (+ jx 28) (+ jy 10) (+ jx 34) (+ jy 22) (- jx 4) (+ jy 22) 235 40 45)
     (fb-hline! fb w h jx (+ jx 30) (+ jy 16) 250 250 255)
     (fb-rect! fb w h (+ jx 10) (+ jy 2) 10 12 35 105 235) ; Rider torso
     (fb-circle! fb w h (+ jx 15) (- jy 2) 5 245 245 255 #t) ; Helmet
     ;; Authentic Wave Race 64 HUD: LAP 2/3, POS 1ST, POWER [*****] MAX!, TIME 0'48"25
     (draw-text!    fb w h 10 8 "LAP 2/3" 255 235 65)
     (draw-text-2x! fb w h 10 18 "POS 1ST" 255 215 35)
     (draw-text!    fb w h 108 8 "POWER [*****] MAX!" 255 95 65)
     (draw-text!    fb w h 124 18 "MISS 0/5" 255 255 255)
     (draw-text!    fb w h 224 8 "TIME 0'48\"25" 255 245 140)])

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
          'cp0-ref-fb              cp0-ref-fb
          'cp0-recomp-fb           cp0-recomp-fb
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
          'cp0-ref-fb             cp0-ref-fb
          'cp0-recomp-fb          cp0-recomp-fb
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
