#lang racket/base

;; ============================================================================
;; #lang boba-nes : Surface Language Expander & Graded Hardware DSL Forms
;; ============================================================================

(require (for-syntax racket/base
                     racket/syntax)
         racket/match
         racket/list
         racket/format
         "../compiler/graded-typechecker.rkt"
         "../compiler/diagnostics.rkt"
         "../compiler/mos6502-assembler.rkt"
         "../compiler/boba-rom-builder.rkt"
         "../compiler/nes-games-builder.rkt")

(provide
 (all-from-out racket/base)
 (all-from-out "../compiler/graded-typechecker.rkt")
 (all-from-out "../compiler/diagnostics.rkt")
 (all-from-out "../compiler/mos6502-assembler.rkt")
 (all-from-out "../compiler/boba-rom-builder.rkt")
 (all-from-out "../compiler/nes-games-builder.rkt")

 ;; Declarative #lang boba-nes Surface DSL Forms
 defnes-module
 defcartridge
 defprg-bank
 far-call
 with-turn-coroutine
 with-vram-delta-queue
 emit-chr-ram-word-upload-6502
 defmetasprite
 emit-oam-metasprite-6502
 emit-oam-coprime-flicker-6502
 emit-fixed-point-8.8-step-6502
 emit-sprite0-hud-split-6502
 defzp-var
 with-zp-scratch
 defchr-tile
 defboba-stage
 verify-nes-grades!)

;; Surface DSL macro for declaring a graded Zero-Page binding
(define-syntax-rule (defzp-var id #:bytes n #:cap cap)
  (define id (hasheq 'name 'id 'bytes n 'cap 'cap)))

;; Surface DSL macro for scoped high-watermark Zero-Page scratch reuse
(define-syntax-rule (with-zp-scratch ([id bytes] ...) body ...)
  (let ([id (hasheq 'id 'id 'bytes bytes 'leaked? #f)] ...)
    body ...))

;; Surface DSL macro for declaring an 8x8 2bpp CHR-ROM tile
(define-syntax-rule (defchr-tile id tile-index row-list)
  (define id (cons tile-index (compile-chr-tile row-list))))

;; Surface DSL macro for declaring a Boba Is You stage layout
(define-syntax-rule (defboba-stage id stage-index cell-alist)
  (define id
    (hasheq 'name 'id
            'stage-index stage-index
            'cells cell-alist)))

;; Surface DSL macro for declaring a banked NES cartridge specification and its derived hardware budget
(define-syntax-rule (defcartridge spec-id budget-id
                      #:mapper mapper-sym
                      #:prg-banks prg-n
                      #:chr-banks chr-n
                      #:chr-mode chr-mode-sym
                      #:wram-bytes wram-b
                      #:battery? bat?
                      #:mirroring mir-sym)
  (begin
    (define spec-id
      (nes-cartridge-spec 'mapper-sym prg-n chr-n 'chr-mode-sym wram-b bat? 'mir-sym))
    (define budget-id
      (make-cartridge-budget spec-id))))

;; Surface DSL macro for declaring a 16 KB ($8000-$BFFF) switchable PRG-ROM bank
(define-syntax-rule (defprg-bank bank-id #:bank bank-num forms-expr)
  (define bank-id
    (let ([asm (assemble-6502 forms-expr #:origin #x8000)])
      (hasheq 'name 'bank-id
              'bank bank-num
              'asm  asm
              'bytes (bytes-length (asm-result-bytes asm))
              'limit 16384))))

;; Surface DSL form for invoking a subroutine in another switchable PRG bank via fixed-bank trampoline
(define (far-call target-bank target-label
                  #:caller-bank [caller-bank 0]
                  #:trampoline? [trampoline? #t]
                  #:zp-far-ptr-lo [zp-far-ptr-lo #x0C]
                  #:zp-far-ptr-hi [zp-far-ptr-hi #x0D])
  (hasheq 'target       target-label
          'target-bank  target-bank
          'caller-bank  caller-bank
          'trampoline?  trampoline?
          'asm-forms
          `((LDA #:imm (lo ,target-label))
            (STA #:zp ,zp-far-ptr-lo)
            (LDA #:imm (hi ,target-label))
            (STA #:zp ,zp-far-ptr-hi)
            (LDY #:imm ,target-bank)
            (JSR far_call_trampoline))))

;; Surface DSL macro for slicing a heavy puzzle turn evaluation across k cooperative VBlank frames
(define-syntax-rule (with-turn-coroutine #:slices k #:turn-cycles cyc body ...)
  (let ([turn-coroutine-grade (hasheq 'turn-slices k 'active-cycles cyc)])
    body ...
    turn-coroutine-grade))

;; Surface DSL macro for draining a large Nametable/CHR-RAM update across m VBlank frames
(define-syntax-rule (with-vram-delta-queue #:slices m #:vram-bytes b body ...)
  (let ([vram-queue-grade (hasheq 'vram-queue-slices m 'vram-dma-bytes b)])
    body ...
    vram-queue-grade))

;; Emit 6502 instructions to dynamically synthesize and upload 16x8 (2-tile) word badges
;; into writable 8 KB CHR-RAM ($0000-$1FFF) during ForcedBlank level load
(define (emit-chr-ram-word-upload-6502 word-alist)
  (define tile-pairs
    (apply append
           (for/list ([entry (in-list word-alist)])
             (make-word-tile-pair (car entry) (cdr entry)))))
  (apply append
         (for/list ([tp (in-list tile-pairs)])
           (define tile-id (car tp))
           (define tbytes  (compile-chr-tile (cdr tp)))
           (define vram-addr (* tile-id 16))
           (append
            `((BIT #:abs #x2002)
              (LDA #:imm ,(bitwise-and #xFF (arithmetic-shift vram-addr -8)))
              (STA #:abs #x2006)
              (LDA #:imm ,(bitwise-and #xFF vram-addr))
              (STA #:abs #x2006))
            (apply append
                   (for/list ([b (in-bytes tbytes)])
                     `((LDA #:imm ,b)
                       (STA #:abs #x2007))))))))

;; Surface DSL macro for declaring a 16x16 (2x2 hardware 8x8 tile) composite metasprite
(define-syntax-rule (defmetasprite ms-id
                      #:tl tl-tile #:tr tr-tile
                      #:bl bl-tile #:br br-tile
                      #:attr attr-byte)
  (define ms-id
    (hasheq 'name 'ms-id
            'tl tl-tile 'tr tr-tile
            'bl bl-tile 'br br-tile
            'attr attr-byte
            'oam-sprites 4
            'scanline-sprites 2)))

;; Emit 6502 instructions to write a 16x16 (4-sprite) metasprite into OAM page $0200
;; starting at static OAM byte offset `oam-base` from Zero-Page coordinates `zp-x` and `zp-y`.
(define (emit-oam-metasprite-6502 ms-desc zp-x zp-y oam-base)
  (define tl   (hash-ref ms-desc 'tl))
  (define tr   (hash-ref ms-desc 'tr))
  (define bl   (hash-ref ms-desc 'bl))
  (define br   (hash-ref ms-desc 'br))
  (define attr (hash-ref ms-desc 'attr 0))
  `((LDA #:zp ,zp-y)
    (STA #:abs ,(+ #x0200 oam-base 0))
    (STA #:abs ,(+ #x0200 oam-base 4))
    (CLC)
    (ADC #:imm 8)
    (STA #:abs ,(+ #x0200 oam-base 8))
    (STA #:abs ,(+ #x0200 oam-base 12))
    (LDA #:imm ,tl)
    (STA #:abs ,(+ #x0200 oam-base 1))
    (LDA #:imm ,tr)
    (STA #:abs ,(+ #x0200 oam-base 5))
    (LDA #:imm ,bl)
    (STA #:abs ,(+ #x0200 oam-base 9))
    (LDA #:imm ,br)
    (STA #:abs ,(+ #x0200 oam-base 13))
    (LDA #:imm ,attr)
    (STA #:abs ,(+ #x0200 oam-base 2))
    (STA #:abs ,(+ #x0200 oam-base 6))
    (STA #:abs ,(+ #x0200 oam-base 10))
    (STA #:abs ,(+ #x0200 oam-base 14))
    (LDA #:zp ,zp-x)
    (STA #:abs ,(+ #x0200 oam-base 3))
    (STA #:abs ,(+ #x0200 oam-base 11))
    (CLC)
    (ADC #:imm 8)
    (STA #:abs ,(+ #x0200 oam-base 7))
    (STA #:abs ,(+ #x0200 oam-base 15))))

;; Emit 6502 instructions to advance a Zero-Page OAM slot index by a coprime stride
;; (+20 bytes = 5 sprite slots, gcd(5, 64) = 1, keeping Slot 0 reserved for Sprite 0 Hit)
(define (emit-oam-coprime-flicker-6502 zp-oam-cursor #:stride-sprites [stride 5])
  (define byte-stride (* 4 stride))
  `((LDA #:zp ,zp-oam-cursor)
    (CLC)
    (ADC #:imm ,byte-stride)
    ;; Keep Slot 0 ($00..$03) reserved when wrapping to 0
    (BNE __oam_mux_ok)
    (LDA #:imm 4)
    (label __oam_mux_ok)
    (STA #:zp ,zp-oam-cursor)))

;; Emit 6502 instructions for 16-bit signed 8.8 fixed-point velocity + gravity integration:
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

;; Emit 6502 instructions for a mid-frame Sprite-0-Hit HUD raster split:
;;   1. Waits for previous frame's Sprite 0 Hit flag ($2002 bit 6) to clear
;;   2. Waits for current frame's Sprite 0 Hit flag ($2002 bit 6) to set at HUD bottom scanline
;;   3. Updates $2000 (base nametable bit 0) and $2005 (horizontal camera scroll_x) during HBlankSplit
(define (emit-sprite0-hud-split-6502 zp-scroll-x zp-scroll-nt
                                     #:base-ppuctrl [base-ppuctrl #x88]
                                     #:label-prefix [prefix 'hud_split])
  (define lbl-clear (string->symbol (format "~a_wait_clear" prefix)))
  (define lbl-hit   (string->symbol (format "~a_wait_hit" prefix)))
  `((label ,lbl-clear)
    (BIT #:abs #x2002)
    (BVS ,lbl-clear)
    (label ,lbl-hit)
    (BIT #:abs #x2002)
    (BVC ,lbl-hit)
    ;; Apply horizontal camera scroll_x and nametable bit below the HUD!
    (LDA #:zp ,zp-scroll-nt)
    (AND #:imm #x01)
    (ORA #:imm ,base-ppuctrl)
    (STA #:abs #x2000)
    (LDA #:zp ,zp-scroll-x)
    (STA #:abs #x2005)
    (LDA #:imm 0)
    (STA #:abs #x2005)))

;; Surface DSL macro for declaring and typechecking a graded NES module
(define-syntax-rule (defnes-module mod-id budget-expr spec-hash-expr)
  (begin
    (define mod-id spec-hash-expr)
    (define-values (repaired-mod applied-repairs mod-type-result)
      (compile-and-verify-nes-module mod-id budget-expr))
    (unless (nes-type-result-well-typed? mod-type-result)
      (error 'defnes-module
             "NES hardware grade verification failed for ~a:\n~a"
             'mod-id
             (resugar-module-diagnostics mod-type-result)))))

(define (verify-nes-grades! mod [budget NTSC-NROM-BUDGET])
  (typecheck-nes-module mod budget))

