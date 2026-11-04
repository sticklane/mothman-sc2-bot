#lang boba-nes
;; ============================================================================
;; Decompiled from Real Commercial GBC ROM: gbc/smb_deluxe.gbc (1048576 bytes)
;; Game Title : Super Mario Bros. Deluxe (1999) (Header: "MARIO DELUXAHYE")
;; Emulator   : danShumway/serverboy.js (Grant Galitz GameBoyCore SM83 + PPU)
;; Captured   : Frame 570 | Non-Zero 2bpp Tiles: 371/384 | Active OAM Sprites: 18/40
;; Registers  : LCDC=$87 SCX=0 SCY=112 WX=0 WY=0 BGP=$e4
;; ============================================================================

(def-cartridge
  (target gbc)
  (title "MARIO DELUXAHYE")
  (rom-source "gbc/smb_deluxe.gbc")
  (origin-frame 570)
  (lcdc #x87)
  (scroll (scx 0) (scy 112) (wx 0) (wy 0))
  (dmg-palettes (bgp #xe4)
                (obp0 #xd8)
                (obp1 #xd8))
  (gbc-bg-cgram "c6206c7eb356fd7fc620f863b24bfd7fc620ff63df4afd7fc6205f635f4afd7fc620fd7ff27efd7fc620ff63ff4bfd7f65696c7e737ffd7f6c7ebf0355020b09")
  (gbc-obj-cgram "0000bf0355020b090000bf03ff7f00008f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f999a9b9c9d9e9fa08f8f8f8f8f8f8f8f8f8f")
  (vram-bank0-sha-prefix "007c00c600aa009200aa00c6007c0000007c00c600aa009200aa00c6007c0000007c00c600aa009200aa00c6007c0000007c00c600aa009200aa00c6007c0000")
  (oam-table "f4000000f40000004f5810004f6012004f6814004f7016004f7918004f811a004f931c005f581e005f6020005f6822005f7024005f7826005f8028005f882a005f902c005f982e005fa030005f884000f4000000f4000000f4000000f4000000f4000000f4000000f4000000f4000000f4000000f4000000f4000000f4000000f4000000f4000000f4000000f4000000f4000000f4000000f4000000f4000000")
  (sample-2bpp-tiles
    (tile 0 "007c00c600aa009200aa00c6007c0000")
    (tile 1 "007c00c600aa009200aa00c6007c0000")
    (tile 2 "007c00c600aa009200aa00c6007c0000")
    (tile 3 "007c00c600aa009200aa00c6007c0000")
    (tile 4 "007c00c600aa009200aa00c6007c0000")
    (tile 5 "007c00c600aa009200aa00c6007c0000")
    (tile 6 "007c00c600aa009200aa00c6007c0000")
    (tile 7 "007c00c600aa009200aa00c6007c0000")
    (tile 8 "007c00c600aa009200aa00c6007c0000")
    (tile 9 "007c00c600aa009200aa00c6007c0000")
    (tile 10 "007c00c600aa009200aa00c6007c0000")
    (tile 11 "007c00c600aa009200aa00c6007c0000")
    (tile 12 "007c00c600aa009200aa00c6007c0000")
    (tile 13 "007c00c600aa009200aa00c6007c0000")
    (tile 14 "007c00c600aa009200aa00c6007c0000")
    (tile 15 "007c00c600aa009200aa00c6007c0000")))
