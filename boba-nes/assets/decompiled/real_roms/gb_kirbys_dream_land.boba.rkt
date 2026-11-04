#lang boba-nes
;; ============================================================================
;; Decompiled from Real Commercial GB ROM: gb/kirbys_dream_land.gb (262144 bytes)
;; Game Title : Kirby's Dream Land (1992) (Header: "KIRBY DREAM LAN")
;; Emulator   : danShumway/serverboy.js (Grant Galitz GameBoyCore SM83 + PPU)
;; Captured   : Frame 480 | Non-Zero 2bpp Tiles: 368/384 | Active OAM Sprites: 2/40
;; Registers  : LCDC=$e7 SCX=0 SCY=0 WX=7 WY=128 BGP=$e4
;; ============================================================================

(def-cartridge
  (target gb)
  (title "KIRBY DREAM LAN")
  (rom-source "gb/kirbys_dream_land.gb")
  (origin-frame 480)
  (lcdc #xe7)
  (scroll (scx 0) (scy 0) (wx 7) (wy 128))
  (dmg-palettes (bgp #xe4)
                (obp0 #xd0)
                (obp1 #xe4))
  (gbc-bg-cgram "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
  (gbc-obj-cgram "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
  (vram-bank0-sha-prefix "010136374b7cbfc0bfc0bfc05f607f602f302f36293f111f101f101f090f070703030d0e17182f303f207f40bfc0ff80f788b7c85b6c3b3c1c1f233f417f3e3e")
  (oam-table "3e2800003e301001006e3e0000662e00006e3c0000662c01005a740000526401005ea2010045a201000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
  (sample-2bpp-tiles
    (tile 0 "010136374b7cbfc0bfc0bfc05f607f60")
    (tile 1 "2f302f36293f111f101f101f090f0707")
    (tile 2 "03030d0e17182f303f207f40bfc0ff80")
    (tile 3 "f788b7c85b6c3b3c1c1f233f417f3e3e")
    (tile 4 "07071b1c2f303f205f607f407b467f41")
    (tile 5 "5f616f72fffc97f88bfc8fff70700000")
    (tile 6 "000007071b1c2f305f607f40ff80ff80")
    (tile 7 "f788bfc85f683b3c1d1e131f080f0707")
    (tile 8 "07071b1c2f307f70b7c8ff80ff80bfc0")
    (tile 9 "6f703f206f7057784d7e233f111f0e0e")
    (tile 10 "e0e0d838f40cfe12fd0bff09ff03ff15")
    (tile 11 "ff09fd0bfe02fa06ec1cf0f008f8f8f8")
    (tile 12 "1c1cbaa6fe62de32ee1afe0afc04fc54")
    (tile 13 "fa56fe52fe02fe82f64afe7afa46fc84")
    (tile 14 "1e1e3f215f607f407f405f603f202f30")
    (tile 15 "17181f102f303f203f203f203f202f30")))
