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
         "../compiler/boba-core-ir.rkt"
         "../compiler/multi-target-typechecker.rkt"
         "../compiler/diagnostics.rkt"
         "../compiler/mos6502-assembler.rkt"
         "../compiler/boba-rom-builder.rkt"
         "../compiler/nes-games-builder.rkt"
         "../compiler/boba-dsl-compiler.rkt"
         "../lib/nes-chr-assets.rkt"
         "../lib/boba-badge-style.rkt"
         "../lib/genre-libraries.rkt"
         "../tools/nes-resource-tool.rkt")

(provide
 (all-from-out racket/base)
 (all-from-out "../compiler/graded-typechecker.rkt")
 (all-from-out "../compiler/boba-core-ir.rkt")
 (all-from-out "../compiler/multi-target-typechecker.rkt")
 (all-from-out "../compiler/diagnostics.rkt")
 (all-from-out "../compiler/mos6502-assembler.rkt")
 (all-from-out "../compiler/boba-rom-builder.rkt")
 (all-from-out "../compiler/nes-games-builder.rkt")
 (all-from-out "../compiler/boba-dsl-compiler.rkt")
 (all-from-out "../lib/nes-chr-assets.rkt")
 (all-from-out "../lib/boba-badge-style.rkt")
 (all-from-out "../lib/genre-libraries.rkt")
 (all-from-out "../tools/nes-resource-tool.rkt")

 ;; Declarative #lang boba-nes Surface DSL Forms
 defnes-module
 defcartridge
 defprg-bank
 far-call
 with-turn-coroutine
 with-vram-delta-queue
 emit-chr-ram-word-upload-6502
 defchr-layout
 defchar-map
 defsprite-tile
 defmetasprite
 emit-oam-metasprite-6502
 defstate-machine
 defzp-map
 defzp-var
 with-zp-scratch
 defchr-tile
 defboba-stage
 define-boba-whole-rom
 def-whole-rom-cartridge
 defsub
 defdata
 def-sm83-isr
 defsub-sm83
 def-pico-function
 def-prg-bank
 def-chr-bank
 def-rom-bank
 def-state-machine
 def-sm83-state-machine
 def-pico-state-machine
 when-branch
 if-else
 then-branch
 else-branch
 counted-loop
 spin-wait-mmio-loop
 do-while-loop
 guard-return
 decompiled-pseudo-code
 high-level-idioms
 pico8-state-machines
 defsub-65c816
 defsub-arm32
 defsub-thumb16
 subroutine
 define-snes-rom-header
 define-snes-interrupt-vectors
 define-snes-coeffect-effect-grade
 define-snes-mmio-profile
 define-snes-call-graph
 define-snes-state-machines
 define-snes-high-level-idioms
 define-snes-spc700-audio-driver
 define-snes-lifted-subroutines
 define-snes-rom-banks
 define-snes-rom-bank-manifest
 define-gba-rom-header
 define-gba-coeffect-effect-grade
 define-gba-mmio-profile
 define-gba-bios-swi-catalog
 define-gba-call-graph
 define-gba-state-machines
 define-gba-high-level-idioms
 define-gba-lifted-lz77-assets
 define-gba-lifted-subroutines
 define-gba-rom-banks
 define-gba-rom-bank-manifest
 define-n64-rom-header
 define-n64-coeffect-effect-grade
 define-n64-mmio-cross-references
 define-n64-resolved-pointers
 define-n64-libultra-call-graph
 define-n64-state-machines
 define-n64-high-level-idioms
 define-n64-lifted-subroutines
 define-n64-rsp-rdp-display-list
 define-n64-rom-segments
 define-n64-rom-segment-manifest
 def-memory-layout
 def-struct-layout
 def-subroutine-contract
 define-snes-struct-layouts
 define-gba-struct-layouts
 define-n64-struct-layouts
 extract-whole-rom-contracts
 verify-whole-rom-module-contracts
 verify-nes-grades!)

;; Surface DSL macro for declaring a game phase state machine with verified failure recovery & victory reachability
(define-syntax-rule (defstate-machine sm-id #:initial init-sym ([state-sym #:kind kind-sym #:transitions (target-sym ...)] ...))
  (define sm-id
    (hasheq 'name 'sm-id
            'initial 'init-sym
            'states (list (hasheq 'id 'state-sym
                                  'kind 'kind-sym
                                  'transitions '(target-sym ...))
                          ...))))

;; Surface DSL macro for declaring a pinned hardware Zero-Page semantic layout map ($00-$FF)
(define-syntax-rule (defzp-map map-id ([var-sym zp-addr role-sym] ...))
  (define map-id
    (list (hasheq 'id 'var-sym 'addr zp-addr 'role 'role-sym) ...)))

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

;; Backward-compatible alias delegating to lib/boba-badge-style.rkt
(define emit-chr-ram-word-upload-6502 emit-boba-badge-chr-ram-upload-6502)

;; Surface DSL macro for declaring a PPU Pattern Table layout ($0000 vs $1000)
;; Computes PPUCTRL ($2000) value:
;;   - bit 7 (#x80): NMI enable
;;   - bit 4 (#x10): Background pattern table ($0000 = 0, $1000 = 1)
;;   - bit 3 (#x08): Sprite pattern table ($0000 = 0, $1000 = 1)
(define-syntax-rule (defchr-layout layout-id
                      #:sprite-pt sprite-pt-num
                      #:bg-pt bg-pt-num
                      #:blank-tile blank-tile-id)
  (define layout-id
    (hasheq 'name       'layout-id
            'sprite-pt  sprite-pt-num
            'bg-pt      bg-pt-num
            'blank-tile blank-tile-id
            'ppuctrl    (bitwise-ior #x80
                                     (if (zero? bg-pt-num) 0 #x10)
                                     (if (zero? sprite-pt-num) 0 #x08)))))

;; Surface DSL macro for declaring a character-to-tile typography map (0..9, A..Z, punctuation)
(define-syntax-rule (defchar-map cmap-id
                      #:digit-base digit-base-num
                      #:alpha-base alpha-base-num
                      #:space-tile space-tile-num
                      #:extra extra-alist-expr)
  (define cmap-id
    (make-char-map #:digit-base digit-base-num
                   #:alpha-base alpha-base-num
                   #:space-tile space-tile-num
                   #:extra extra-alist-expr)))

;; Surface DSL macro for binding a single 8x8 hardware sprite tile & OAM attribute byte
(define-syntax-rule (defsprite-tile spr-id #:tile tile-id #:attr attr-byte)
  (define spr-id
    (hasheq 'name 'spr-id
            'tile tile-id
            'attr attr-byte
            'oam-sprites 1
            'scanline-sprites 1)))

;; Surface DSL macro for declaring a 16x16 (2x2 hardware 8x8 tile) or 8x16 ('symmetric-vertical) composite metasprite.
;; Supports:
;;   1. Explicit quadrant form: (defmetasprite id #:tl t0 #:tr t1 #:bl t2 #:br t3 #:attr a)
;;   2. Order-aware form      : (defmetasprite id #:tiles (list ...) #:order 'row-major/'col-major/'symmetric-col-major/'symmetric-vertical #:attr a)
;;   3. Single-tile vertical  : (defmetasprite id #:tile t0 #:order 'symmetric-vertical #:attr a)
(define-syntax (defmetasprite stx)
  (syntax-case stx ()
    [(_ ms-id #:tl tl-tile #:tr tr-tile #:bl bl-tile #:br br-tile #:attr attr-byte)
     #'(define ms-id
         (make-metasprite-desc 'ms-id (list tl-tile tr-tile bl-tile br-tile)
                               #:order 'row-major
                               #:attr attr-byte))]
    [(_ ms-id #:tiles tile-list-expr #:order order-expr #:attr attr-byte)
     #'(define ms-id
         (make-metasprite-desc 'ms-id tile-list-expr
                               #:order order-expr
                               #:attr attr-byte))]
    [(_ ms-id #:tile single-tile-expr #:order order-expr #:attr attr-byte)
     #'(define ms-id
         (make-metasprite-desc 'ms-id (list single-tile-expr)
                               #:order order-expr
                               #:attr attr-byte))]))

;; Emit 6502 instructions to write a 16x16 (4-sprite) metasprite into OAM page $0200
(define emit-oam-metasprite-6502 emit-metasprite-oam-6502)

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

;; Surface DSL macro for a whole-ROM decompiled/recompiled cartridge module (.nes / .gb / .gbc / .p8)
(define-syntax (define-boba-whole-rom stx)
  (syntax-case stx ()
    [(define-boba-whole-rom rom-id rest ...)
     #'(begin
         (provide rom-id whole-rom-sexp)
         (define whole-rom-sexp '(define-boba-whole-rom rom-id rest ...))
         (define rom-id whole-rom-sexp))]))

(define-syntax (def-whole-rom-cartridge stx)
  (syntax-case stx ()
    [(def-whole-rom-cartridge body ...)
     #'(begin
         (provide whole-rom-sexp)
         (define whole-rom-sexp '(def-whole-rom-cartridge body ...)))]))

(define-syntax-rule (defsub sub-id body ...)
  (define sub-id '(defsub sub-id body ...)))

(define-syntax-rule (defdata data-id body ...)
  (define data-id '(defdata data-id body ...)))

(define-syntax-rule (def-sm83-isr isr-id body ...)
  (define isr-id '(def-sm83-isr isr-id body ...)))

(define-syntax-rule (defsub-sm83 sub-id body ...)
  (define sub-id '(defsub-sm83 sub-id body ...)))

(define-syntax-rule (def-pico-function body ...)
  '(def-pico-function body ...))

(define-syntax-rule (def-prg-bank body ...)
  '(def-prg-bank body ...))

(define-syntax-rule (def-chr-bank body ...)
  '(def-chr-bank body ...))

(define-syntax-rule (def-rom-bank body ...)
  '(def-rom-bank body ...))

(define-syntax-rule (def-state-machine sm-id body ...)
  '(def-state-machine sm-id body ...))

(define-syntax-rule (def-sm83-state-machine sm-id body ...)
  '(def-sm83-state-machine sm-id body ...))

(define-syntax-rule (def-pico-state-machine sm-id body ...)
  '(def-pico-state-machine sm-id body ...))

(define-syntax-rule (when-branch body ...)
  '(when-branch body ...))

(define-syntax-rule (if-else body ...)
  '(if-else body ...))

(define-syntax-rule (then-branch body ...)
  '(then-branch body ...))

(define-syntax-rule (else-branch body ...)
  '(else-branch body ...))

(define-syntax-rule (counted-loop body ...)
  '(counted-loop body ...))

(define-syntax-rule (spin-wait-mmio-loop body ...)
  '(spin-wait-mmio-loop body ...))

(define-syntax-rule (do-while-loop body ...)
  '(do-while-loop body ...))

(define-syntax-rule (guard-return body ...)
  '(guard-return body ...))

(define-syntax-rule (decompiled-pseudo-code body ...)
  '(decompiled-pseudo-code body ...))

(define-syntax-rule (high-level-idioms body ...)
  '(high-level-idioms body ...))

(define-syntax-rule (pico8-state-machines body ...)
  '(pico8-state-machines body ...))

(define-syntax-rule (defsub-65c816 sub-id body ...)
  (define sub-id '(defsub-65c816 sub-id body ...)))

(define-syntax-rule (defsub-arm32 sub-id body ...)
  (define sub-id '(defsub-arm32 sub-id body ...)))

(define-syntax-rule (defsub-thumb16 sub-id body ...)
  (define sub-id '(defsub-thumb16 sub-id body ...)))

(define-syntax-rule (subroutine sub-id body ...)
  (define sub-id '(subroutine sub-id body ...)))

(define-syntax-rule (define-snes-rom-header body ...) '(define-snes-rom-header body ...))
(define-syntax-rule (define-snes-interrupt-vectors body ...) '(define-snes-interrupt-vectors body ...))
(define-syntax-rule (define-snes-coeffect-effect-grade body ...) '(define-snes-coeffect-effect-grade body ...))
(define-syntax-rule (define-snes-mmio-profile body ...) '(define-snes-mmio-profile body ...))
(define-syntax-rule (define-snes-call-graph body ...) '(define-snes-call-graph body ...))
(define-syntax-rule (define-snes-state-machines body ...) '(define-snes-state-machines body ...))
(define-syntax-rule (define-snes-high-level-idioms body ...) '(define-snes-high-level-idioms body ...))
(define-syntax-rule (define-snes-spc700-audio-driver body ...) '(define-snes-spc700-audio-driver body ...))
(define-syntax-rule (define-snes-lifted-subroutines body ...) '(define-snes-lifted-subroutines body ...))
(define-syntax-rule (define-snes-rom-banks body ...) '(define-snes-rom-banks body ...))
(define-syntax-rule (define-snes-rom-bank-manifest body ...) '(define-snes-rom-bank-manifest body ...))

(define-syntax-rule (define-gba-rom-header body ...) '(define-gba-rom-header body ...))
(define-syntax-rule (define-gba-coeffect-effect-grade body ...) '(define-gba-coeffect-effect-grade body ...))
(define-syntax-rule (define-gba-mmio-profile body ...) '(define-gba-mmio-profile body ...))
(define-syntax-rule (define-gba-bios-swi-catalog body ...) '(define-gba-bios-swi-catalog body ...))
(define-syntax-rule (define-gba-call-graph body ...) '(define-gba-call-graph body ...))
(define-syntax-rule (define-gba-state-machines body ...) '(define-gba-state-machines body ...))
(define-syntax-rule (define-gba-high-level-idioms body ...) '(define-gba-high-level-idioms body ...))
(define-syntax-rule (define-gba-lifted-lz77-assets body ...) '(define-gba-lifted-lz77-assets body ...))
(define-syntax-rule (define-gba-lifted-subroutines body ...) '(define-gba-lifted-subroutines body ...))
(define-syntax-rule (define-gba-rom-banks body ...) '(define-gba-rom-banks body ...))
(define-syntax-rule (define-gba-rom-bank-manifest body ...) '(define-gba-rom-bank-manifest body ...))

(define-syntax-rule (define-n64-rom-header body ...) '(define-n64-rom-header body ...))
(define-syntax-rule (define-n64-coeffect-effect-grade body ...) '(define-n64-coeffect-effect-grade body ...))
(define-syntax-rule (define-n64-mmio-cross-references body ...) '(define-n64-mmio-cross-references body ...))
(define-syntax-rule (define-n64-resolved-pointers body ...) '(define-n64-resolved-pointers body ...))
(define-syntax-rule (define-n64-libultra-call-graph body ...) '(define-n64-libultra-call-graph body ...))
(define-syntax-rule (define-n64-state-machines body ...) '(define-n64-state-machines body ...))
(define-syntax-rule (define-n64-high-level-idioms body ...) '(define-n64-high-level-idioms body ...))
(define-syntax-rule (define-n64-lifted-subroutines body ...) '(define-n64-lifted-subroutines body ...))
(define-syntax-rule (define-n64-rsp-rdp-display-list body ...) '(define-n64-rsp-rdp-display-list body ...))
(define-syntax-rule (define-n64-rom-segments body ...) '(define-n64-rom-segments body ...))
(define-syntax-rule (define-n64-rom-segment-manifest body ...) '(define-n64-rom-segment-manifest body ...))

(define-syntax-rule (def-memory-layout body ...) '(def-memory-layout body ...))
(define-syntax-rule (def-struct-layout body ...) '(def-struct-layout body ...))
(define-syntax-rule (def-subroutine-contract body ...) '(def-subroutine-contract body ...))
(define-syntax-rule (define-snes-struct-layouts body ...) '(define-snes-struct-layouts body ...))
(define-syntax-rule (define-gba-struct-layouts body ...) '(define-gba-struct-layouts body ...))
(define-syntax-rule (define-n64-struct-layouts body ...) '(define-n64-struct-layouts body ...))



