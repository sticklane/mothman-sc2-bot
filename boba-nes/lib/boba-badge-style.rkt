#lang racket/base

;; ============================================================================
;; lib/boba-badge-style.rkt
;; Optional Art-Style Library: 3x5 Beveled 16x8 Pill-Badge Word Tiles
;;
;; Separates Boba Is You's procedural 4-letter pill-badge aesthetic from the
;; core #lang boba-nes hardware compiler and standard 8x8 tile typography.
;; ============================================================================

(require "../compiler/mos6502-assembler.rkt"
         "../compiler/boba-rom-builder.rkt")

(provide
 FONT-3X5
 make-word-tile-pair
 emit-boba-badge-chr-ram-upload-6502)

;; Emit 6502 instructions to dynamically synthesize and upload 16x8 (2-tile) word badges
;; into writable 8 KB CHR-RAM ($0000-$1FFF) during ForcedBlank level load
(define (emit-boba-badge-chr-ram-upload-6502 word-alist)
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
