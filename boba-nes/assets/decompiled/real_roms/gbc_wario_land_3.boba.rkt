#lang boba-nes
;; ============================================================================
;; Decompiled from Real Commercial GBC ROM: gbc/wario_land_3.gbc (2097152 bytes)
;; Game Title : Wario Land 3 (2000) (Header: "WARIOLAND3AW8A")
;; Emulator   : danShumway/serverboy.js (Grant Galitz GameBoyCore SM83 + PPU)
;; Captured   : Frame 750 | Non-Zero 2bpp Tiles: 335/384 | Active OAM Sprites: 16/40
;; Registers  : LCDC=$87 SCX=247 SCY=4 WX=0 WY=0 BGP=$fc
;; ============================================================================

(def-cartridge
  (target gbc)
  (title "WARIOLAND3AW8A")
  (rom-source "gbc/wario_land_3.gbc")
  (origin-frame 750)
  (lcdc #x87)
  (scroll (scx 247) (scy 4) (wx 0) (wy 0))
  (dmg-palettes (bgp #xfc)
                (obp0 #x00)
                (obp1 #x00))
  (gbc-bg-cgram "d07fd07fd07fd07fd07fd07fd07fd07fd07fd07fd07fd07fd07fd07fd07fd07fd07fd07fd07fd07fd07f687ec55d687eff7f687e000180008000ea010001ee02")
  (gbc-obj-cgram "d57f000000000000d57f000000000000d57f000000000000d57f7f0b1b080734d57ffe4e9f2c0734d57fff7fd57f4d7ad57fff7fff290734d57fff7fdf02ed28")
  (vram-bank0-sha-prefix "00000000000044cd24ed24ed54fd54fd44dd44dd44cd44cd000000000000000000000000000014fc848c858f858f25ef858f858f828712f70000000000000000")
  (oam-table "4d5a120e4d62140e4d47000b4d4f020b4d57040b4d67080b5d470a0b5d4f0c0b5d570e0b5d67100b545f060b4d3f160e5d3f184e1c10560d1c18580d1c205a0d14ac5c0d14b45e0d00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
  (sample-2bpp-tiles
    (tile 0 "00000000000044cd24ed24ed54fd54fd")
    (tile 1 "44dd44dd44cd44cd0000000000000000")
    (tile 2 "00000000000014fc848c858f858f25ef")
    (tile 3 "858f858f828712f70000000000000000")
    (tile 4 "00000000000040c141c341c341c341c3")
    (tile 5 "41c341c3818380810000000000000000")
    (tile 6 "00000000000021e312371237020714fc")
    (tile 7 "143c103f143c24ec0000000000000000")
    (tile 8 "000000000000113389bf81bf95bf51f3")
    (tile 9 "51f351f351f351f30000000000000000")
    (tile 10 "000000000000047c2060206020600878")
    (tile 11 "206020602060047c0000000000000000")
    (tile 12 "0000000000000000000000000000043c")
    (tile 13 "2267226720612061206122672267043c")
    (tile 14 "000000000000000000000000000012f6")
    (tile 15 "899f899f8a9f8a9f8a9e8a9e8a9e12f6")))
