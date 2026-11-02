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
         "../compiler/boba-rom-builder.rkt")

(provide
 (all-from-out racket/base)
 (all-from-out "../compiler/graded-typechecker.rkt")
 (all-from-out "../compiler/diagnostics.rkt")
 (all-from-out "../compiler/mos6502-assembler.rkt")
 (all-from-out "../compiler/boba-rom-builder.rkt")

 ;; Declarative #lang boba-nes Surface DSL Forms
 defnes-module
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
