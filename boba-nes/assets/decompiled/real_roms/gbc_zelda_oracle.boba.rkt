#lang boba-nes
;; ============================================================================
;; Decompiled from Real Commercial GBC ROM: gbc/zelda_oracle.gbc (1048576 bytes)
;; Game Title : Zelda: Oracle of Ages (2001) (Header: "ZELDA NAYRUAZ8E")
;; Emulator   : danShumway/serverboy.js (Grant Galitz GameBoyCore SM83 + PPU)
;; Captured   : Frame 660 | Non-Zero 2bpp Tiles: 365/384 | Active OAM Sprites: 28/40
;; Registers  : LCDC=$c7 SCX=0 SCY=0 WX=199 WY=199 BGP=$e4
;; ============================================================================

(def-cartridge
  (target gbc)
  (title "ZELDA NAYRUAZ8E")
  (rom-source "gbc/zelda_oracle.gbc")
  (origin-frame 660)
  (lcdc #xc7)
  (scroll (scx 0) (scy 0) (wx 199) (wy 199))
  (dmg-palettes (bgp #xe4)
                (obp0 #xe4)
                (obp1 #x6c))
  (gbc-bg-cgram "8e11dc7f0c730b443f439f261f0ebe018e119f030c73c0018e11fd7f0c730b44ce49fd7f0c730b448e11be010c730b44735efd7f0c730b448e11fd7f0c73be01")
  (gbc-obj-cgram "4c7ec028034a0a734c7e1f001f001f004c7e4c7e1f0e9f264c7efd02fa01cc004c7e73030d02e7004c7e1f001f001f004c7e112fe915e7004c7e112fe9155301")
  (vram-bank0-sha-prefix "000000000000000000000000000000000000000002000600070107030400060003004503eb47b76f9b6f5b2f370b3d136a35433e5b27592fc9b7e09f27182b17")
  (oam-table "48906206428e6806517a560450827404587a6a0758826c07588a6e07548a540354825203547a5003647a700364827203648a702340866606407f64064170600655765a0644685e2674004602802c380080343a00803c3c0080443e00804c3e00805c3e0080644000806c420080743a00807c4000e0000000e0000000e0000000e0000000e0000000e0000000e0000000e0000000e0000000e0000000e0000000")
  (sample-2bpp-tiles
    (tile 0 "00000000000000000000000000000000")
    (tile 1 "00000000020006000701070304000600")
    (tile 2 "03004503eb47b76f9b6f5b2f370b3d13")
    (tile 3 "6a35433e5b27592fc9b7e09f27182b17")
    (tile 4 "03000300010000000100030103010301")
    (tile 5 "03010301050305030503070307030703")
    (tile 6 "7c0f7718e937f32ff6894ab5ce339779")
    (tile 7 "9d7e9f7f9f7f9f7f8f7f867fc13e639c")
    (tile 8 "00000000000001000100000000000000")
    (tile 9 "00000100010003000300020002000200")
    (tile 10 "00000300c503ebc76fc7956f572d3619")
    (tile 11 "633ed927d9afc9b7c0bfe39c2f133c0f")
    (tile 12 "03000300010000000100030103010301")
    (tile 13 "03010301050305030503070307030703")
    (tile 14 "77187b27f629d629ea9555bbdb3c9e7f")
    (tile 15 "9f7f9f7f9f7f9f7f9e7fcc3fc03fe19e")))
