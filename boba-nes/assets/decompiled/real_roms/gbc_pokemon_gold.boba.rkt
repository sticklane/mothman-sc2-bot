#lang boba-nes
;; ============================================================================
;; Decompiled from Real Commercial GBC ROM: gbc/pokemon_gold.gbc (2097152 bytes)
;; Game Title : Pokemon Gold Version (1999) (Header: "POKEMON_GLDAAUE")
;; Emulator   : danShumway/serverboy.js (Grant Galitz GameBoyCore SM83 + PPU)
;; Captured   : Frame 480 | Non-Zero 2bpp Tiles: 250/384 | Active OAM Sprites: 19/40
;; Registers  : LCDC=$e7 SCX=0 SCY=0 WX=7 WY=144 BGP=$e4
;; ============================================================================

(def-cartridge
  (target gbc)
  (title "POKEMON_GLDAAUE")
  (rom-source "gbc/pokemon_gold.gbc")
  (origin-frame 480)
  (lcdc #xe7)
  (scroll (scx 0) (scy 0) (wx 7) (wy 144))
  (dmg-palettes (bgp #xe4)
                (obp0 #xe4)
                (obp1 #x24))
  (gbc-bg-cgram "ff7ff27e8f7e0000bf02cc318f7e0044ff7f1f008f7e0000ff7f3d038f7e5105ff7f577ff27e0000ffffffff00000000ffffffff00000000ffffffff00000000")
  (gbc-obj-cgram "ff7fc70cc70cc70cff7fff03da020000ff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7f")
  (vram-bank0-sha-prefix "000000000000030304047d7dffc7ffef989f0607010100000000000000000000000018183c243e263f293f293f337e567c6c7c6c98f8d0f0f0f0f8f884fc02fe")
  (oam-table "6d7cf811596cf811655cf8115938000051400200614004005948260069480a004950280059502a006950100059582c00695816005960300069601c0059681e00696820005170220061702400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
  (sample-2bpp-tiles
    (tile 0 "000000000000030304047d7dffc7ffef")
    (tile 1 "989f0607010100000000000000000000")
    (tile 2 "000018183c243e263f293f293f337e56")
    (tile 3 "7c6c7c6c98f8d0f0f0f0f8f884fc02fe")
    (tile 4 "01ff00ffe0ff181f0607010100000000")
    (tile 5 "00000000000000000000000000000000")
    (tile 6 "00000000000000000606070537343f2c")
    (tile 7 "3f243f241f141f141f141f141f141f10")
    (tile 8 "101f080f080f04070407020302030203")
    (tile 9 "828362e31eff00ff00ff80ff407f203f")
    (tile 10 "101f080f080f04070203010100000000")
    (tile 11 "00000000000000000000000000000000")
    (tile 12 "8080c0c0e0a0f090f898fc94ff93ff91")
    (tile 13 "ff91ff92ff92ffa2ff24ff29ff49ff12")
    (tile 14 "3fc40ff90ff107fe03fd07fe03fc01ff")
    (tile 15 "07fe01fe01ff07f807ffc7f83ff807ff")))
