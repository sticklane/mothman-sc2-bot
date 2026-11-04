#lang boba-nes
;; ============================================================================
;; Decompiled from Real Commercial GBC ROM: gbc/lufia_the_legend_returns.gbc (2097152 bytes)
;; Game Title : Lufia: The Legend Returns (2001) (Header: "LUFIA RETURBLCE")
;; Emulator   : danShumway/serverboy.js (Grant Galitz GameBoyCore SM83 + PPU)
;; Captured   : Frame 645 | Non-Zero 2bpp Tiles: 94/384 | Active OAM Sprites: 0/40
;; Registers  : LCDC=$c7 SCX=0 SCY=0 WX=7 WY=144 BGP=$e4
;; ============================================================================

(def-cartridge
  (target gbc)
  (title "LUFIA RETURBLCE")
  (rom-source "gbc/lufia_the_legend_returns.gbc")
  (origin-frame 645)
  (lcdc #xc7)
  (scroll (scx 0) (scy 0) (wx 7) (wy 144))
  (dmg-palettes (bgp #xe4)
                (obp0 #x00)
                (obp1 #x00))
  (gbc-bg-cgram "ff7fbf5f3f5ff75eff7f9c773f5ff75eff7fbf6f3f5ff75eff7fff5ef77ef75eff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7f")
  (gbc-obj-cgram "ff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7fff7ff75eff5f9e67")
  (vram-bank0-sha-prefix "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
  (oam-table "a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000a0000000")
  (sample-2bpp-tiles
    (tile 0 "00000000000000000000000000000000")
    (tile 1 "00000000000000000000000000000000")
    (tile 2 "00000000000000000000000000000000")
    (tile 3 "00000000000000000000000000000000")
    (tile 4 "00000000000000000000000000000000")
    (tile 5 "00000000000000000000000000000000")
    (tile 6 "00000000000000000000000000000000")
    (tile 7 "00000000000000000000000000000000")
    (tile 8 "00000000000000000000000000000000")
    (tile 9 "00000000000000000000000000000000")
    (tile 10 "00000000000000000000000000000000")
    (tile 11 "00000000000000000000000000000000")
    (tile 12 "00000000000000000000000000000000")
    (tile 13 "00000000000000000000000000000000")
    (tile 14 "00000000000000000000000000000000")
    (tile 15 "00000000000000000000000000000000")))
