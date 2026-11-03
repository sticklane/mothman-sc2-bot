#lang racket/base

;; ============================================================================
;; compiler/original-dsl-games.rkt
;; Thin Backward-Compatible Re-Export Module for the 3 Original #lang boba-nes Games
;;
;; All CHR graphics, palettes, Zero-Page maps, state machines, metasprites,
;; and 6502 programs for the 3 original games live 100% inside:
;;   - examples/star_courier.bnes
;;   - examples/crypt_sweep.bnes
;;   - examples/neon_strider.bnes
;; ============================================================================

(require "boba-dsl-compiler.rkt"
         "../examples/star_courier.bnes"
         "../examples/crypt_sweep.bnes"
         "../examples/neon_strider.bnes")

(provide
 ;; Surface Phase Block Forms (from compiler/boba-dsl-compiler.rkt)
 vblank-block
 active-frame-block

 ;; Shared Original Games Zero-Page Address Constants ($0010-$0029)
 ORIG-ZP-BUTTONS
 ORIG-ZP-PREV-BTN
 ORIG-ZP-NEW-BTN
 ORIG-ZP-FRAME-CNT
 ORIG-ZP-X
 ORIG-ZP-Y
 ORIG-ZP-VY
 ORIG-ZP-SPECIAL
 ORIG-ZP-FUEL
 ORIG-ZP-FREEZE-TIMER
 ORIG-ZP-POLARITY
 ORIG-ZP-BOMB-X
 ORIG-ZP-BOMB-Y
 ORIG-ZP-BOMB-TIMER
 ORIG-ZP-ENEMY-X
 ORIG-ZP-ENEMY-ALIVE
 ORIG-ZP-ENEMY-Y
 ORIG-ZP-SCORE
 ORIG-ZP-PODS
 ORIG-ZP-RELICS
 ORIG-ZP-NODES
 ORIG-ZP-WALL-INTACT
 ORIG-ZP-WON
 ORIG-ZP-LIVES
 ORIG-ZP-DEAD
 ORIG-ZP-STAGE-DIRTY
 ORIG-ZP-STAGE-ID
 ORIG-ZP-GAME-COMPLETED

 ;; Re-Exported from examples/star_courier.bnes, examples/crypt_sweep.bnes, examples/neon_strider.bnes
 build-star-courier-chr-rom
 build-crypt-sweep-chr-rom
 build-neon-strider-chr-rom
 emit-star-courier-6502-program
 emit-crypt-sweep-6502-program
 emit-neon-strider-6502-program
 compile-star-courier-rom!
 compile-crypt-sweep-rom!
 compile-neon-strider-rom!

 star-courier-chr
 star-courier-zp-map
 star-courier-fsm
 kestral-lander-metasprite
 plasma-drone-metasprite
 energy-pod-metasprite
 landing-beacon-metasprite
 thruster-plume-vertical-metasprite
 star-courier-game
 star-courier-rom-bytes
 star-courier-asm-result
 star-courier-type-result
 star-courier-module-desc
 star-courier-repairs

 crypt-sweep-chr
 crypt-sweep-zp-map
 crypt-sweep-fsm
 chronomancer-metasprite
 crypt-wraith-metasprite
 arcane-bomb-metasprite
 chrono-relic-metasprite
 hourglass-pillar-vertical-metasprite
 crypt-sweep-game
 crypt-sweep-rom-bytes
 crypt-sweep-asm-result
 crypt-sweep-type-result
 crypt-sweep-module-desc
 crypt-sweep-repairs

 neon-strider-chr
 neon-strider-zp-map
 neon-strider-fsm
 neon-strider-metasprite
 laser-sentry-metasprite
 cyber-node-metasprite
 mainframe-core-metasprite
 laser-beam-vertical-metasprite
 neon-strider-game
 neon-strider-rom-bytes
 neon-strider-asm-result
 neon-strider-type-result
 neon-strider-module-desc
 neon-strider-repairs)

(define ORIG-ZP-BUTTONS        #x10)
(define ORIG-ZP-PREV-BTN       #x11)
(define ORIG-ZP-NEW-BTN        #x12)
(define ORIG-ZP-FRAME-CNT      #x13)
(define ORIG-ZP-X              #x14)
(define ORIG-ZP-Y              #x15)
(define ORIG-ZP-VY             #x16)
(define ORIG-ZP-SPECIAL        #x17)
(define ORIG-ZP-FUEL           #x17)
(define ORIG-ZP-FREEZE-TIMER   #x17)
(define ORIG-ZP-POLARITY       #x17)
(define ORIG-ZP-BOMB-X         #x18)
(define ORIG-ZP-BOMB-Y         #x19)
(define ORIG-ZP-BOMB-TIMER     #x1A)
(define ORIG-ZP-ENEMY-X        #x1B)
(define ORIG-ZP-ENEMY-ALIVE    #x1C)
(define ORIG-ZP-ENEMY-Y        #x1D)
(define ORIG-ZP-SCORE          #x1E)
(define ORIG-ZP-PODS           #x1F)
(define ORIG-ZP-RELICS         #x1F)
(define ORIG-ZP-NODES          #x1F)
(define ORIG-ZP-WALL-INTACT    #x20)
(define ORIG-ZP-WON            #x24)
(define ORIG-ZP-LIVES          #x25)
(define ORIG-ZP-DEAD           #x26)
(define ORIG-ZP-STAGE-DIRTY    #x27)
(define ORIG-ZP-STAGE-ID       #x28)
(define ORIG-ZP-GAME-COMPLETED #x29)
