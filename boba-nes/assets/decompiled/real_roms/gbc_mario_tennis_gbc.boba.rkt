#lang boba-nes
;; ============================================================================
;; Decompiled from Real Commercial GBC ROM: gbc/mario_tennis_gbc.gbc (2097152 bytes)
;; Game Title : Mario Tennis (GBC, 2000) (Header: "CGBTENNIS BM8E")
;; Emulator   : danShumway/serverboy.js (Grant Galitz GameBoyCore SM83 + PPU)
;; Captured   : Frame 705 | Non-Zero 2bpp Tiles: 291/384 | Active OAM Sprites: 20/40
;; Registers  : LCDC=$e7 SCX=0 SCY=0 WX=7 WY=144 BGP=$fc
;; ============================================================================

(def-cartridge
  (target gbc)
  (title "CGBTENNIS BM8E")
  (rom-source "gbc/mario_tennis_gbc.gbc")
  (origin-frame 705)
  (lcdc #xe7)
  (scroll (scx 0) (scy 0) (wx 7) (wy 144))
  (dmg-palettes (bgp #xfc)
                (obp0 #x00)
                (obp1 #x00))
  (gbc-bg-cgram "d65a5f010000ff7fff7fec2f471b892204004a0100112433ff7f14670632007f9f3eff6b0a5000009452ff7f4a2900009f5aff6b1f000000cc3aff6b4a7d0000")
  (gbc-obj-cgram "ef3ddf000000ff7f00008f011f031f030000000000000000dc1aff6b401e00005f22ff6b5c5000001f33ff6bdf0100009f5aff6b1f000000cc3aff6b4a7d0000")
  (vram-bank0-sha-prefix "000000000979067f007f007f097f0676007000700070007000700000000000000000000004e708ef00ef00ee00ee00ee00ef00ef00ef00ee00ee000000000000")
  (oam-table "10350001103d020110450401104d060110550801105d0a0110650c01106d0e0110751001107d12013e0410083e0c12083e1414083e1c16083e2418083e2c1a083e341c083e3c1e08361c7208362474080000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
  (sample-2bpp-tiles
    (tile 0 "000000000979067f007f007f097f0676")
    (tile 1 "00700070007000700070000000000000")
    (tile 2 "0000000004e708ef00ef00ee00ee00ee")
    (tile 3 "00ef00ef00ef00ee00ee000000000000")
    (tile 4 "0000000010f308fb00fb003b003b003b")
    (tile 5 "00fb00fb00fb003b003b000000000000")
    (tile 6 "0000000010b008b804bc02be01bf00bf")
    (tile 7 "04bf02bb01b900b800b8000000000000")
    (tile 8 "0000000000e100e100e100e100e100e1")
    (tile 9 "00e100e100e180e14061000000000000")
    (tile 10 "0000000024e718ff00ff00ff24ff18db")
    (tile 11 "00c300c300c300c300c3000000000000")
    (tile 12 "0000000000bf00bf00bf00b800bf00bf")
    (tile 13 "00bf00b800bf00bf00bf000000000000")
    (tile 14 "0000000004ec02ee01ef000f00cf00cf")
    (tile 15 "01cf000e00ee00ee00ee000000000000")))
