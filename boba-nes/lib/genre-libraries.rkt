#lang racket/base

;; ============================================================================
;; lib/genre-libraries.rkt
;; Reusable Genre Mechanics Libraries Built on Top of #lang boba-nes
;;
;;   1. Platformer Library (8.8 Subpixel Physics, Sprite-0 HUD Split, Camera Scroll)
;;   2. Top-Down Adventure Library (Coprime OAM Flicker Multiplexer, Directional Hitbox)
;;   3. Falling-Block Puzzle Library (Galois LFSR PRNG, Staged VBlank Dirty-Row Copier)
;; ============================================================================

(require racket/list
         racket/format)

(provide
 ;; 1. Platformer Library
 emit-fixed-point-8.8-step-6502
 emit-sprite0-hud-split-6502
 emit-camera-scroll-follow-6502

 ;; 2. Top-Down Adventure Library
 emit-oam-coprime-flicker-6502
 emit-directional-offset-6502

 ;; 3. Falling-Block Puzzle Library
 emit-galois-lfsr-step-6502
 emit-staged-vblank-row-copier-6502)

;; ============================================================================
;; 1. Platformer Mechanics Library
;; ============================================================================

;; 16-bit signed 8.8 fixed-point velocity + gravity integration:
;;   vel += accel (16-bit signed), pos += vel (16-bit signed)
(define (emit-fixed-point-8.8-step-6502 zp-pos-lo zp-pos-hi zp-vel-lo zp-vel-hi
                                        #:accel-lo [accel-lo 0]
                                        #:accel-hi [accel-hi 0])
  (append
   (if (and (zero? accel-lo) (zero? accel-hi))
       '()
       `((CLC)
         (LDA #:zp ,zp-vel-lo)
         (ADC #:imm ,(bitwise-and #xFF accel-lo))
         (STA #:zp ,zp-vel-lo)
         (LDA #:zp ,zp-vel-hi)
         (ADC #:imm ,(bitwise-and #xFF accel-hi))
         (STA #:zp ,zp-vel-hi)))
   `((CLC)
     (LDA #:zp ,zp-pos-lo)
     (ADC #:zp ,zp-vel-lo)
     (STA #:zp ,zp-pos-lo)
     (LDA #:zp ,zp-pos-hi)
     (ADC #:zp ,zp-vel-hi)
     (STA #:zp ,zp-pos-hi))))

;; Mid-frame Sprite-0-Hit HUD raster split:
;;   1. Waits for previous frame's Sprite 0 Hit flag ($2002 bit 6) to clear
;;   2. Waits for current frame's Sprite 0 Hit flag ($2002 bit 6) to set at HUD bottom scanline
;;   3. Updates $2000 (base nametable bit 0 + pattern table bits) and $2005 (scroll_x)
(define (emit-sprite0-hud-split-6502 zp-scroll-x zp-scroll-nt
                                     #:base-ppuctrl [base-ppuctrl #x90]
                                     #:label-prefix [prefix 'hud_split])
  (define lbl-clear (string->symbol (format "~a_wait_clear" prefix)))
  (define lbl-hit   (string->symbol (format "~a_wait_hit" prefix)))
  `((label ,lbl-clear)
    (BIT #:abs #x2002)
    (BVS ,lbl-clear)
    (label ,lbl-hit)
    (BIT #:abs #x2002)
    (BVC ,lbl-hit)
    (LDA #:zp ,zp-scroll-nt)
    (AND #:imm #x01)
    (ORA #:imm ,base-ppuctrl)
    (STA #:abs #x2000)
    (LDA #:zp ,zp-scroll-x)
    (STA #:abs #x2005)
    (LDA #:imm 0)
    (STA #:abs #x2005)))

;; Camera follow helper for horizontal platformers
(define (emit-camera-scroll-follow-6502 zp-world-x-lo zp-scroll-x
                                        #:lead-threshold [lead 104]
                                        #:max-scroll [max-scroll 192]
                                        #:step [step 3]
                                        #:done-label [done-lbl 'cam_done])
  `((LDA #:zp ,zp-world-x-lo)
    (SEC)
    (SBC #:zp ,zp-scroll-x)
    (CMP #:imm ,lead)
    (BCC ,done-lbl)
    (LDA #:zp ,zp-scroll-x)
    (CMP #:imm ,max-scroll)
    (BCS ,done-lbl)
    (CLC)
    (ADC #:imm ,step)
    (STA #:zp ,zp-scroll-x)
    (label ,done-lbl)))

;; ============================================================================
;; 2. Top-Down Adventure Mechanics Library
;; ============================================================================

;; Advance a Zero-Page OAM slot index by a coprime stride
;; (+20 bytes = 5 sprite slots, gcd(5, 64) = 1, keeping Slot 0 reserved)
(define (emit-oam-coprime-flicker-6502 zp-oam-cursor #:stride-sprites [stride 5])
  (define byte-stride (* 4 stride))
  `((LDA #:zp ,zp-oam-cursor)
    (CLC)
    (ADC #:imm ,byte-stride)
    (BNE __oam_mux_ok)
    (LDA #:imm 4)
    (label __oam_mux_ok)
    (STA #:zp ,zp-oam-cursor)))

;; Compute a directional melee/projectile hitbox offset from an actor's (X, Y, DIR)
(define (emit-directional-offset-6502 zp-x zp-y zp-dir zp-out-x zp-out-y
                                      #:up-dy [up-dy 12]
                                      #:down-dy [down-dy 16]
                                      #:left-dx [left-dx 12]
                                      #:right-dx [right-dx 16]
                                      #:done-label [done-lbl 'dir_offset_done])
  `((LDA #:zp ,zp-x) (STA #:zp ,zp-out-x)
    (LDA #:zp ,zp-y) (STA #:zp ,zp-out-y)
    (LDA #:zp ,zp-dir)
    (BNE __dir_not_up)
    (LDA #:zp ,zp-y) (SEC) (SBC #:imm ,up-dy) (STA #:zp ,zp-out-y)
    (JMP ,done-lbl)
    (label __dir_not_up)
    (CMP #:imm 1)
    (BNE __dir_not_down)
    (LDA #:zp ,zp-y) (CLC) (ADC #:imm ,down-dy) (STA #:zp ,zp-out-y)
    (JMP ,done-lbl)
    (label __dir_not_down)
    (CMP #:imm 2)
    (BNE __dir_right)
    (LDA #:zp ,zp-x) (SEC) (SBC #:imm ,left-dx) (STA #:zp ,zp-out-x)
    (JMP ,done-lbl)
    (label __dir_right)
    (LDA #:zp ,zp-x) (CLC) (ADC #:imm ,right-dx) (STA #:zp ,zp-out-x)
    (label ,done-lbl)))

;; ============================================================================
;; 3. Falling-Block Puzzle Mechanics Library
;; ============================================================================

;; 8-bit Galois LFSR PRNG step (polynomial x^8 + x^6 + x^5 + x^4 + 1 -> #xB8)
(define (emit-galois-lfsr-step-6502 zp-lfsr #:poly [poly #xB8] #:label [lbl '__lfsr_no_xor])
  `((LDA #:zp ,zp-lfsr)
    (LSR)
    (BCC ,lbl)
    (EOR #:imm ,poly)
    (label ,lbl)
    (STA #:zp ,zp-lfsr)))

;; Staged VBlank dirty-row copier subroutine call wrapper
(define (emit-staged-vblank-row-copier-6502 zp-dirty-row
                                            #:total-rows [total-rows 20]
                                            #:rows-per-nmi [rows-per-nmi 2]
                                            #:row-subroutine [row-sub 'flush_one_well_row_vram]
                                            #:done-label [done-lbl '__vblank_rows_done])
  (apply append
         (for/list ([i (in-range rows-per-nmi)])
           `((LDA #:zp ,zp-dirty-row)
             (CMP #:imm ,total-rows)
             (BCS ,done-lbl)
             (JSR ,row-sub)))))
