#lang boba-nes
;; ============================================================================
;; Decompiled from Real Commercial GBC ROM: gbc/shantae.gbc (4194304 bytes)
;; Game Title : Shantae (2002) (Header: "SHANTAEB3AE")
;; Emulator   : danShumway/serverboy.js (Grant Galitz GameBoyCore SM83 + PPU)
;; Captured   : Frame 315 | Non-Zero 2bpp Tiles: 304/384 | Active OAM Sprites: 9/40
;; Registers  : LCDC=$e7 SCX=0 SCY=0 WX=7 WY=144 BGP=$fc
;; ============================================================================

(def-cartridge
  (target gbc)
  (title "SHANTAEB3AE")
  (rom-source "gbc/shantae.gbc")
  (origin-frame 315)
  (lcdc #xe7)
  (scroll (scx 0) (scy 0) (wx 7) (wy 144))
  (dmg-palettes (bgp #xfc)
                (obp0 #x00)
                (obp1 #x00))
  (gbc-bg-cgram "de7b7e038b2d0464de7bc56b007900001378083c0000de7b1e000e000000de7b000029259452de7b000029259452de7b000029259452de7b000029259452de7b")
  (gbc-obj-cgram "0000df030d5800000000ef7f3f26000000001f003f2600000000be03f20000000000587a0c540000000000036001800000009c738c3500000000be031e000000")
  (vram-bank0-sha-prefix "00000000000000000000000000000000fcfc03ff01ff06fe8afefefe10109090000000000000000000008080c040c040e0a0ff1fe03fc07f84ff87ff88f8f3f3")
  (oam-table "4a2b01004a2303005e1805004e1b0700582c090158240b01602d0d0260250f02601d11020011130200001500000017000000190000001b0000001d0000001f00000021000000230000002500000027000000290000002b0000002d0000002f00000031000000330000003500000037000000390000003b0000003d0000003f00000041000000430000004500000047000000490000004b0000004d0000004f00")
  (sample-2bpp-tiles
    (tile 0 "00000000000000000000000000000000")
    (tile 1 "fcfc03ff01ff06fe8afefefe10109090")
    (tile 2 "000000000000000000008080c040c040")
    (tile 3 "e0a0ff1fe03fc07f84ff87ff88f8f3f3")
    (tile 4 "121e243c243c48785070a0e0c0c00000")
    (tile 5 "00000000010102020606050505050505")
    (tile 6 "1e1e213f437e477c4f784f79477e417f")
    (tile 7 "417f427e427e427e447c447c88f888f8")
    (tile 8 "20e020e0b0f090f010f020e040c08080")
    (tile 9 "00008080808000008080808000000000")
    (tile 10 "101fe7ff2ffc87fc407fe2bdd05f8f8f")
    (tile 11 "131ff0ff16fe73ffa8bf2c3f17171212")
    (tile 12 "00000000000000000000000000000000")
    (tile 13 "00008080c040c040c0408080c040f0f0")
    (tile 14 "263ee1ff2ffde6fed17fd97ffe2efc24")
    (tile 15 "ff43ff40bfa09f901f100f0907060101")))
