#lang boba-nes
;; ============================================================================
;; Decompiled from Real Commercial GBC ROM: gbc/mega_man_xtreme_2.gbc (1048576 bytes)
;; Game Title : Mega Man Xtreme 2 (2001) (Header: "MEGAMANX2SEB2XE")
;; Emulator   : danShumway/serverboy.js (Grant Galitz GameBoyCore SM83 + PPU)
;; Captured   : Frame 510 | Non-Zero 2bpp Tiles: 140/384 | Active OAM Sprites: 17/40
;; Registers  : LCDC=$e7 SCX=0 SCY=0 WX=7 WY=112 BGP=$fc
;; ============================================================================

(def-cartridge
  (target gbc)
  (title "MEGAMANX2SEB2XE")
  (rom-source "gbc/mega_man_xtreme_2.gbc")
  (origin-frame 510)
  (lcdc #xe7)
  (scroll (scx 0) (scy 0) (wx 7) (wy 112))
  (dmg-palettes (bgp #xfc)
                (obp0 #x00)
                (obp1 #x00))
  (gbc-bg-cgram "f7623a739d7fdf7ff762f7663a73df7ff762f7669d7fdf7ff762f86a196fdf7ff762f86a196f7c7bf762196f7c7bdf7ff75ef75ef75ef75ef75ef75ef75ef75e")
  (gbc-obj-cgram "f7623a739d7fdf7ff762f7663a73df7ff762f7669d7fdf7ff762f86a196fdf7ff762f86a196f7c7bf762196f7c7bdf7fff7fff7fff7fff7fff7fff7fff7fff7f")
  (vram-bank0-sha-prefix "00000000000000000000000000000000000000000000030006010d031d031e010000000000000000000000000000100018303c709b63e5037f81bec1a0c06886")
  (oam-table "10880004109002041098040418100a0118180c0120400e012048100160401204208806042090080420982004308814043090160440881a0440901c0440981e0430981804ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000")
  (sample-2bpp-tiles
    (tile 0 "00000000000000000000000000000000")
    (tile 1 "000000000000030006010d031d031e01")
    (tile 2 "00000000000000000000000000001000")
    (tile 3 "18303c709b63e5037f81bec1a0c06886")
    (tile 4 "00000000000000000000000000000000")
    (tile 5 "000000000080c0e0e0f0e8f0f3fb74f9")
    (tile 6 "3f00393c7c6654666c4e797d327a4435")
    (tile 7 "780b790b390b390d1d0505051009ac1c")
    (tile 8 "dc0fcd1ec31ce608f0e01f0073f0d8bc")
    (tile 9 "eaddf5ebfff3ffffdfbff7ccbff34dfe")
    (tile 10 "a478e678e27ca27c52bce29cb4c919e3")
    (tile 11 "1fe3ad5bf31dfe4fbe6f7b0726010300")
    (tile 12 "1be00df30df37d835a2d6fbc6dbe46fe")
    (tile 13 "fffefffe1dfecffcea1c7c98e8f0f400")
    (tile 14 "a31c17084e80a540d021c3f307e1071f")
    (tile 15 "bf4f5f2f170e0040136753270b304000")))
