#lang racket/base

;; ============================================================================
;; compiler/boba-dsl-compiler.rkt
;; Declarative Resource Compiler, Static 6502 AST Grade Analyzer &
;; End-to-End `defnes-game` Pipeline for #lang boba-nes
;; ============================================================================

(require (for-syntax racket/base
                     racket/path)
         racket/file
         racket/list
         racket/match
         racket/path
         racket/set
         racket/string
         "graded-typechecker.rkt"
         "diagnostics.rkt"
         "mos6502-assembler.rkt"
         "boba-rom-builder.rkt"
         "../lib/nes-chr-assets.rkt"
         "../lib/genre-libraries.rkt")

(provide
 ;; 1. Static 6502 AST & Resource Grade Analyzer
 count-nonzero-chr-tiles
 split-6502-forms-by-top-labels
 estimate-6502-ast-prg-bytes
 analyze-6502-ast-grades

 ;; 2. Declarative CHR / Palette / Nametable / OAM Resource Forms
 glyph-3x5->8x8-rows
 BASE-FONT-TILES
 build-custom-dual-pt-chr-rom
 build-chr-resource-bytes
 defchr-resource
 defpalette-resource
 defnametable-resource
 defoam-resource

 ;; 3. Phase Block & End-to-End `defnes-game` Compiler Forms
 vblank-block
 active-frame-block
 compile-boba-nes-game!
 compile-boba-dsl-game!
 defnes-game)

(define-syntax (get-repo-root-dir stx)
  (datum->syntax stx (path->string (simplify-path (build-path (syntax-source stx) 'up 'up)))))

(define REPO-ROOT-DIR (string->path (get-repo-root-dir)))

;; Resolve a relative ROM output path against REPO-ROOT-DIR so running `.bnes`
;; from either the repository root or `examples/` or `tests/` writes to the right place.
(define (resolve-rom-path p)
  (define path-obj (if (path? p) p (string->path p)))
  (cond
    [(complete-path? path-obj) path-obj]
    [else
     (define s (path->string path-obj))
     (if (string-prefix? s "../")
         (simplify-path (build-path REPO-ROOT-DIR "examples" path-obj))
         (simplify-path (build-path REPO-ROOT-DIR path-obj)))]))

;; ============================================================================
;; 1. Zero-Offset 3x5 Base Font & Declarative Resource Builders
;; ============================================================================

;; Synthesize an 8x8 tile from a 3x5 glyph (centered with drop-shadow in color 1, body in color 3)
(define (glyph-3x5->8x8-rows ch)
  (define rows5 (hash-ref FONT-3X5 ch '("..." "..." "..." "..." "...")))
  (append
   (list "........")
   (for/list ([r5 (in-list rows5)])
     (define c0 (string-ref r5 0))
     (define c1 (string-ref r5 1))
     (define c2 (string-ref r5 2))
     (define (px c) (if (char=? c #\3) "33" ".."))
     (string-append "." (px c0) (px c1) (px c2) "1"))
   (list "........"
         "........")))

(define BASE-FONT-TILES
  (append
   ;; Digits '0'..'9' at tile IDs #x00..#x09 (Zero-Offset BCD!)
   (for/list ([d (in-range 10)])
     (define ch (integer->char (+ (char->integer #\0) d)))
     (cons d (glyph-3x5->8x8-rows ch)))
   ;; Letters 'A'..'Z' at tile IDs #x0A..#x23
   (for/list ([i (in-range 26)])
     (define ch (integer->char (+ (char->integer #\A) i)))
     (cons (+ #x0A i) (glyph-3x5->8x8-rows ch)))
   (list
    ;; #x24: Blank background tile
    (cons #x24 '("........" "........" "........" "........"
                 "........" "........" "........" "........"))
    ;; #x28: Hyphen '-'
    (cons #x28 (glyph-3x5->8x8-rows #\-))
    ;; #x29: 'x'
    (cons #x29 (glyph-3x5->8x8-rows #\X))
    ;; #x2B: '!'
    (cons #x2B (glyph-3x5->8x8-rows #\!))
    ;; #x2C: ':'
    (cons #x2C (glyph-3x5->8x8-rows #\:))
    ;; #x2E: '*' Emblem
    (cons #x2E '("...33..." "..3223.." ".323323." "32333323"
                 "32333323" ".323323." "..3223.." "...33..."))
    ;; #x65: '=' Heart / Shield Emblem
    (cons #x65 '(".33..33." "32233223" "32333323" "32333323"
                 ".323323." "..3223.." "...33..." "........")))))

(define (build-custom-dual-pt-chr-rom custom-tiles #:base-font? [base-font? #t])
  (define all-tiles
    (if base-font?
        (append BASE-FONT-TILES custom-tiles)
        custom-tiles))
  (define pt0 (build-chr-rom all-tiles))
  ;; Copy into both Pattern Table 0 ($0000) and Pattern Table 1 ($1000)
  (define chr8k (make-bytes 8192 0))
  (bytes-copy! chr8k 0    pt0 0 4096)
  (bytes-copy! chr8k 4096 pt0 0 4096)
  chr8k)

(define (build-chr-resource-bytes #:base-font? [base-font? #t]
                                  #:tiles [tiles #f]
                                  #:from-ines [from-ines #f]
                                  #:bank-8k [bank-8k 0]
                                  #:bank-4k [bank-4k #f])
  (cond
    [from-ines
     (define resolved (resolve-rom-path from-ines))
     (if bank-4k
         (let ([b4 (extract-ines-chr-rom resolved #:bank-4k bank-4k)]
               [chr8 (make-bytes 8192 0)])
           (bytes-copy! chr8 0    b4 0 4096)
           (bytes-copy! chr8 4096 b4 0 4096)
           chr8)
         (extract-ines-chr-rom resolved #:bank-8k bank-8k))]
    [tiles
     (build-custom-dual-pt-chr-rom tiles #:base-font? base-font?)]
    [else
     (error 'defchr-resource "Must specify either #:tiles or #:from-ines")]))

(define-syntax (defchr-resource stx)
  (syntax-case stx ()
    [(_ id #:base-font? bf #:tiles tile-alist-expr)
     #'(define id (build-chr-resource-bytes #:base-font? bf #:tiles tile-alist-expr))]
    [(_ id #:tiles tile-alist-expr #:base-font? bf)
     #'(define id (build-chr-resource-bytes #:base-font? bf #:tiles tile-alist-expr))]
    [(_ id #:tiles tile-alist-expr)
     #'(define id (build-chr-resource-bytes #:base-font? #t #:tiles tile-alist-expr))]
    [(_ id #:from-ines rom-path-expr #:bank-8k bank-num)
     #'(define id (build-chr-resource-bytes #:from-ines rom-path-expr #:bank-8k bank-num))]
    [(_ id #:from-ines rom-path-expr #:bank-4k bank-num)
     #'(define id (build-chr-resource-bytes #:from-ines rom-path-expr #:bank-4k bank-num))]
    [(_ id #:from-ines rom-path-expr)
     #'(define id (build-chr-resource-bytes #:from-ines rom-path-expr #:bank-8k 0))]))

(define-syntax-rule (defpalette-resource id byte-list-expr)
  (define id
    (let ([bs byte-list-expr])
      (unless (and (list? bs) (for/and ([b (in-list bs)]) (and (exact-integer? b) (<= 0 b #xFF))))
        (error 'defpalette-resource "Expected list of byte integers (0..255) for ~a" 'id))
      bs)))

(define-syntax-rule (defnametable-resource id byte-list-expr)
  (define id
    (let ([bs byte-list-expr])
      (cond
        [(bytes? bs) (bytes->list bs)]
        [(list? bs)  bs]
        [else (error 'defnametable-resource "Expected byte list or bytes for ~a" 'id)]))))

(define-syntax-rule (defoam-resource id byte-list-expr)
  (define id
    (let ([bs byte-list-expr])
      (unless (and (list? bs) (zero? (modulo (length bs) 4)))
        (error 'defoam-resource "OAM resource ~a must be a list of 4-byte sprite entries" 'id))
      bs)))

;; ============================================================================
;; 2. Phase Block Surface Forms (`vblank-block` & `active-frame-block`)
;; ============================================================================

(define-syntax (vblank-block stx)
  (syntax-case stx ()
    [(_ block-id #:cycles cyc #:oam-sprites oam-spr #:scanline-sprites scan-spr #:vram-bytes vram-b body ...)
     #'(define block-id
         (let ([res (begin body ...)])
           (hasheq 'name             'block-id
                   'phase            'VBlankNMI
                   'vblank-cycles    cyc
                   'oam-sprites      oam-spr
                   'scanline-sprites scan-spr
                   'vram-dma-bytes   vram-b
                   'body-result      res
                   'ppu-ops          (list (hasheq 'op 'oam-dma! 'phase 'VBlankNMI)
                                           (hasheq 'op 'nametable-patch! 'phase 'VBlankNMI))
                   'nmi-ops          (list (hasheq 'op 'oam-dma!)
                                           (hasheq 'op 'nametable-patch!)
                                           (hasheq 'op 'restore-scroll! 'x 0 'y 0)))))]
    [(_ #:cycles cyc #:oam-sprites oam-spr #:scanline-sprites scan-spr #:vram-bytes vram-b body ...)
     #'(let ([res (begin body ...)])
         (hasheq 'phase            'VBlankNMI
                 'vblank-cycles    cyc
                 'oam-sprites      oam-spr
                 'scanline-sprites scan-spr
                 'vram-dma-bytes   vram-b
                 'body-result      res
                 'ppu-ops          (list (hasheq 'op 'oam-dma! 'phase 'VBlankNMI)
                                         (hasheq 'op 'nametable-patch! 'phase 'VBlankNMI))
                 'nmi-ops          (list (hasheq 'op 'oam-dma!)
                                         (hasheq 'op 'nametable-patch!)
                                         (hasheq 'op 'restore-scroll! 'x 0 'y 0))))]))

(define-syntax (active-frame-block stx)
  (syntax-case stx ()
    [(_ block-id #:cycles cyc #:ram-bytes ram-b #:apu-channels apu-ch-list body ...)
     #'(define block-id
         (let ([res (begin body ...)])
           (hasheq 'name          'block-id
                   'phase         'ActiveFrame
                   'active-cycles cyc
                   'ram-bytes     ram-b
                   'apu-channels  apu-ch-list
                   'body-result   res)))]
    [(_ #:cycles cyc #:ram-bytes ram-b #:apu-channels apu-ch-list body ...)
     #'(let ([res (begin body ...)])
         (hasheq 'phase         'ActiveFrame
                 'active-cycles cyc
                 'ram-bytes     ram-b
                 'apu-channels  apu-ch-list
                 'body-result   res))]))

;; ============================================================================
;; 3. Static 6502 AST & Resource Grade Analyzer (`analyze-6502-ast-grades`)
;; ============================================================================

;; Count non-zero 16-byte 2bpp tiles inside an 8 KB CHR-ROM image
(define (count-nonzero-chr-tiles chr-bytes)
  (if (and (bytes? chr-bytes) (>= (bytes-length chr-bytes) 16))
      (let ([num-tiles (quotient (min 8192 (bytes-length chr-bytes)) 16)])
        (for/sum ([t (in-range num-tiles)])
          (define base (* t 16))
          (if (for/or ([i (in-range 16)])
                (not (zero? (bytes-ref chr-bytes (+ base i)))))
              1
              0)))
      0))

;; Instruction base cycle table for static 6502 AST analysis
(define INST-CYCLE-TABLE
  (hash
   'LDA (hash 'imm 2 'zp 3 'zpx 4 'abs 4 'absx 4 'absy 4 'indx 6 'indy 5)
   'LDX (hash 'imm 2 'zp 3 'zpy 4 'abs 4 'absy 4)
   'LDY (hash 'imm 2 'zp 3 'zpx 4 'abs 4 'absx 4)
   'STA (hash 'zp 3 'zpx 4 'abs 4 'absx 5 'absy 5 'indx 6 'indy 6)
   'STX (hash 'zp 3 'zpy 4 'abs 4)
   'STY (hash 'zp 3 'zpx 4 'abs 4)
   'TAX 2 'TAY 2 'TXA 2 'TYA 2 'TSX 2 'TXS 2
   'PHA 3 'PHP 3 'PLA 4 'PLP 4
   'AND (hash 'imm 2 'zp 3 'zpx 4 'abs 4 'absx 4 'absy 4 'indx 6 'indy 5)
   'EOR (hash 'imm 2 'zp 3 'zpx 4 'abs 4 'absx 4 'absy 4 'indx 6 'indy 5)
   'ORA (hash 'imm 2 'zp 3 'zpx 4 'abs 4 'absx 4 'absy 4 'indx 6 'indy 5)
   'BIT (hash 'zp 3 'abs 4)
   'ADC (hash 'imm 2 'zp 3 'zpx 4 'abs 4 'absx 4 'absy 4 'indx 6 'indy 5)
   'SBC (hash 'imm 2 'zp 3 'zpx 4 'abs 4 'absx 4 'absy 4 'indx 6 'indy 5)
   'CMP (hash 'imm 2 'zp 3 'zpx 4 'abs 4 'absx 4 'absy 4 'indx 6 'indy 5)
   'CPX (hash 'imm 2 'zp 3 'abs 4)
   'CPY (hash 'imm 2 'zp 3 'abs 4)
   'INC (hash 'zp 5 'zpx 6 'abs 6 'absx 7)
   'DEC (hash 'zp 5 'zpx 6 'abs 6 'absx 7)
   'INX 2 'INY 2 'DEX 2 'DEY 2
   'ASL (hash 'acc 2 'zp 5 'zpx 6 'abs 6 'absx 7)
   'LSR (hash 'acc 2 'zp 5 'zpx 6 'abs 6 'absx 7)
   'ROL (hash 'acc 2 'zp 5 'zpx 6 'abs 6 'absx 7)
   'ROR (hash 'acc 2 'zp 5 'zpx 6 'abs 6 'absx 7)
   'JMP (hash 'abs 3 'ind 5)
   'JSR 6 'RTS 6 'RTI 6
   'BCC 3 'BCS 3 'BEQ 3 'BMI 3 'BNE 3 'BPL 3 'BVC 3 'BVS 3
   'CLC 2 'CLD 2 'CLI 2 'CLV 2 'SEC 2 'SED 2 'SEI 2 'BRK 7 'NOP 2))

(define (inst-form-cycles form)
  (match form
    [`(label ,_) 0]
    [`(.equ ,_ ,_) 0]
    [`(.byte . ,_) 0]
    [`(.word . ,_) 0]
    [`(.align ,_) 0]
    [`(STA #:abs #x4014) (+ 4 514)] ; 4 cyc STA + 514 cyc 2C02 OAMDMA burst
    [`(,mnem)
     (define entry (hash-ref INST-CYCLE-TABLE mnem 2))
     (if (hash? entry) (hash-ref entry 'acc 2) entry)]
    [`(,mnem ,_target)
     (define entry (hash-ref INST-CYCLE-TABLE mnem 3))
     (if (hash? entry) (hash-ref entry 'abs 3) entry)]
    [`(,mnem ,kw ,_op)
     #:when (keyword? kw)
     (define mode (string->symbol (keyword->string kw)))
     (define entry (hash-ref INST-CYCLE-TABLE mnem 4))
     (if (hash? entry) (hash-ref entry mode 4) entry)]
    [else 2]))

;; Estimate PRG-ROM byte footprint directly from 6502 AST forms (without assembling)
(define (estimate-6502-ast-prg-bytes forms)
  (for/sum ([f (in-list forms)])
    (match f
      [`(label ,_) 0]
      [`(.equ ,_ ,_) 0]
      [`(.align ,_) 0]
      [`(.byte . ,bs) (length bs)]
      [`(.word . ,ws) (* 2 (length ws))]
      [`(,_mnem) 1]
      [`(,mnem ,_target) (if (memq mnem '(JMP JSR)) 3 2)]
      [`(,_mnem ,kw ,_op)
       #:when (keyword? kw)
       (define mode (string->symbol (keyword->string kw)))
       (if (memq mode '(abs absx absy ind)) 3 2)]
      [else 2])))

;; Split a 6502 AST form list into top-level routine/table sections keyed by label symbol:
;; Top-level section boundaries occur at:
;;   - Canonical entry labels: reset_handler, set_nt0_addr, boot_init,
;;     game_frame_step, build_oam, nmi_handler, irq_handler
;;   - Any label following an RTS or RTI instruction
(define TOP-ENTRY-LABELS
  '(reset_handler set_nt0_addr boot_init game_frame_step build_oam nmi_handler irq_handler))

(define (split-6502-forms-by-top-labels forms)
  (define sections (make-hasheq))
  (define cur-label 'preamble)
  (define cur-acc '())
  (define prev-was-return? #f)

  (define (flush-section!)
    (when (pair? cur-acc)
      (hash-set! sections cur-label
                 (append (hash-ref sections cur-label '())
                         (reverse cur-acc)))
      (set! cur-acc '())))

  (for ([f (in-list forms)])
    (match f
      [`(label ,sym)
       (if (or (memq sym TOP-ENTRY-LABELS) prev-was-return?)
           (begin
             (flush-section!)
             (set! cur-label sym)
             (set! cur-acc (list f))
             (set! prev-was-return? #f))
           (begin
             (set! cur-acc (cons f cur-acc))
             (set! prev-was-return? #f)))]
      [(or '(RTS) '(RTI))
       (set! cur-acc (cons f cur-acc))
       (set! prev-was-return? #t)]
      [`(.byte . ,_)
       (set! cur-acc (cons f cur-acc))]
      [`(.word . ,_)
       (set! cur-acc (cons f cur-acc))]
      [else
       (set! cur-acc (cons f cur-acc))
       (set! prev-was-return? #f)]))
  (flush-section!)
  sections)

;; Compute static cycles of a section, scaling backward counted loops (LDX/LDY #imm ... BNE/BPL)
;; and charging subroutine calls via `sub-cycles-hash`
(define (compute-section-cycles section-forms [sub-cycles-hash (hasheq)] #:scale-loops? [scale-loops? #t])
  (define label-pos (make-hasheq))
  (define label-trip (make-hasheq))
  (define inst-vec (list->vector section-forms))
  (define n (vector-length inst-vec))

  ;; Pass 1: Record label positions and preceding LDX/LDY immediate loop counters
  (define last-imm-count #f)
  (for ([i (in-range n)])
    (define f (vector-ref inst-vec i))
    (match f
      [`(LDX #:imm ,(? exact-integer? k)) (set! last-imm-count k)]
      [`(LDY #:imm ,(? exact-integer? k)) (set! last-imm-count k)]
      [`(label ,sym)
       (hash-set! label-pos sym i)
       (when last-imm-count
         (hash-set! label-trip sym last-imm-count))]
      [else (void)]))

  ;; Pass 2: Sum base cycles + JSR callee cycles + backward loop multipliers
  (define total 0)
  (for ([i (in-range n)])
    (define f (vector-ref inst-vec i))
    (define base
      (match f
        [`(JSR ,target)
         (+ 6 (hash-ref sub-cycles-hash target 0))]
        [`(JSR #:abs ,target)
         (+ 6 (hash-ref sub-cycles-hash target 0))]
        [else (inst-form-cycles f)]))
    (set! total (+ total base))

    ;; If this is a backward conditional branch to a label in the same section, scale loop body
    (when scale-loops?
      (match f
        [`(,b-mnem ,target)
         #:when (and (memq b-mnem '(BNE BPL BCC BCS))
                     (hash-has-key? label-pos target)
                     (< (hash-ref label-pos target) i))
         (define start-idx (hash-ref label-pos target))
         (define raw-trip  (hash-ref label-trip target 8))
         (define trip
           (cond
             [(<= raw-trip 0) 8]
             [(eq? b-mnem 'BPL) (min 64 (add1 raw-trip))]
             [else (min 64 raw-trip)]))
         (define body-cyc
           (for/sum ([j (in-range start-idx (add1 i))])
             (inst-form-cycles (vector-ref inst-vec j))))
         (set! total (+ total (* (max 0 (sub1 trip)) body-cyc)))]
        [else (void)])))
  total)

;; Normalize a scratch block list from either `with-zp-scratch` hashes or `(id bytes)` pairs
(define (normalize-scratch-list lst)
  (cond
    [(null? lst) '()]
    [(hash? lst) (list lst)]
    [(list? lst)
     (for/list ([item (in-list lst)])
       (match item
         [(? hash? h) h]
         [`(,id ,(? exact-integer? b))
          (hasheq 'id id 'bytes b 'leaked? #f)]
         [(cons id (? exact-integer? b))
          (hasheq 'id id 'bytes b 'leaked? #f)]
         [else (hasheq 'id 'scratch 'bytes 4 'leaked? #f)]))]
    [else '()]))

;; Real static analyzer that walks the 6502 AST (`forms`) and optional `asm-result`
;; to compute hardware grades directly from the code & resources.
;; When `asm-res` is `#f` (pre-assembly typechecking), `prg-rom-bytes` is estimated
;; directly from `forms` without invoking `assemble-6502`.
(define (analyze-6502-ast-grades forms [asm-res #f]
                                 #:chr-bytes         [chr-bytes #f]
                                 #:zp-map            [zp-map '()]
                                 #:state-machines    [state-machines '()]
                                 #:name              [name 'nes-game-module]
                                 #:mapper            [mapper 'NROM]
                                 #:mirroring         [mirroring 'vertical]
                                 #:scroll-mode       [scroll-mode 'none]
                                 #:oam-sprites       [oam-sprites 11]
                                 #:scanline-sprites  [scanline-sprites 4]
                                 #:vram-bytes        [vram-bytes #f]
                                 #:ram-bytes         [ram-bytes 64]
                                 #:zp-scratch-blocks [zp-scratch-blocks '()])
  (define sections (split-6502-forms-by-top-labels forms))

  ;; 1. Helper subroutine cycles (e.g., set_nt0_addr / set_vram_addr)
  (define helper-forms (hash-ref sections 'set_nt0_addr '()))
  (define helper-cyc   (if (null? helper-forms) 20 (compute-section-cycles helper-forms #:scale-loops? #f)))
  (define sub-cyc-map
    (hasheq 'set_nt0_addr  helper-cyc
            'set_vram_addr (max 0 (- helper-cyc 2))))

  ;; 2. Analyze `nmi_handler`: VBlank cycles, PHA/PLA balance, PPU/NMI ops, VRAM write count
  (define nmi-forms (hash-ref sections 'nmi_handler '()))
  (define vblank-cycles (compute-section-cycles nmi-forms sub-cyc-map #:scale-loops? #t))

  (define nmi-pha-count
    (for/sum ([f (in-list nmi-forms)])
      (match f
        [(or '(PHA) '(PHP)) 1]
        [else 0])))
  (define nmi-pla-count
    (for/sum ([f (in-list nmi-forms)])
      (match f
        [(or '(PLA) '(PLP)) 1]
        [else 0])))

  ;; Scan nmi_handler in instruction order for $4014 (oam-dma!), $2007 (nametable-patch!), and $2000/$2005 (restore-scroll!)
  (define nmi-ops-rev '())
  (define ppu-ops-rev '())
  (define nmi-vram-writes 0)
  (define seen-nmi-dma? #f)
  (define seen-nmi-patch? #f)
  (define seen-nmi-scroll-2000? #f)
  (define seen-nmi-scroll-2005-count 0)

  (for ([f (in-list nmi-forms)])
    (match f
      [`(STA #:abs #x4014)
       (unless seen-nmi-dma?
         (set! seen-nmi-dma? #t)
         (set! ppu-ops-rev (cons (hasheq 'op 'oam-dma! 'phase 'VBlankNMI) ppu-ops-rev)))
       (set! nmi-ops-rev (cons (hasheq 'op 'oam-dma!) nmi-ops-rev))]
      [(or `(STA #:abs #x2007) `(STA #:abs #x2006))
       (set! nmi-vram-writes (add1 nmi-vram-writes))
       (unless seen-nmi-patch?
         (set! seen-nmi-patch? #t)
         (set! ppu-ops-rev (cons (hasheq 'op 'nametable-patch! 'phase 'VBlankNMI) ppu-ops-rev)))
       (set! nmi-ops-rev (cons (hasheq 'op 'nametable-patch!) nmi-ops-rev))]
      [`(JSR ,callee)
       #:when (memq callee '(set_nt0_addr set_vram_addr))
       (set! nmi-vram-writes (+ nmi-vram-writes 2))]
      [`(STA #:abs #x2000)
       (set! seen-nmi-scroll-2000? #t)]
      [`(STA #:abs #x2005)
       (set! seen-nmi-scroll-2005-count (add1 seen-nmi-scroll-2005-count))
       (when (and seen-nmi-scroll-2000? (>= seen-nmi-scroll-2005-count 2))
         (set! nmi-ops-rev (cons (hasheq 'op 'restore-scroll! 'x 0 'y 0) nmi-ops-rev)))]
      [else (void)]))

  ;; 3. Analyze `game_frame_step` and `build_oam` (ActiveFrame): cycles & illegal PPU/DMA access check
  (define active-forms
    (append (hash-ref sections 'game_frame_step '())
            (hash-ref sections 'build_oam '())))
  (define active-cycles
    (compute-section-cycles active-forms sub-cyc-map #:scale-loops? #t))

  (for ([f (in-list active-forms)])
    (match f
      [`(STA #:abs #x4014)
       (set! ppu-ops-rev (cons (hasheq 'op 'oam-dma! 'phase 'ActiveFrame) ppu-ops-rev))]
      [(or `(STA #:abs #x2007) `(STA #:abs #x2006))
       (set! ppu-ops-rev (cons (hasheq 'op 'nametable-patch! 'phase 'ActiveFrame) ppu-ops-rev))]
      [else (void)]))

  ;; 4. Scan all forms for 2A03 APU channel writes ($4000-$4013)
  (define apu-set (mutable-seteq))
  (for ([f (in-list forms)])
    (match f
      [`(STA #:abs ,(? exact-integer? addr))
       (cond
         [(<= #x4000 addr #x4003) (set-add! apu-set 'pulse1)]
         [(<= #x4004 addr #x4007) (set-add! apu-set 'pulse2)]
         [(<= #x4008 addr #x400B) (set-add! apu-set 'triangle)]
         [(<= #x400C addr #x400F) (set-add! apu-set 'noise)]
         [(<= #x4010 addr #x4013) (set-add! apu-set 'dmc)])]
      [else (void)]))
  (define detected-apu-channels
    (for/list ([ch (in-list '(pulse1 pulse2 triangle noise dmc))]
               #:when (set-member? apu-set ch))
      ch))

  ;; 5. Count non-zero 16-byte CHR tiles in the 8 KB CHR-ROM
  (define chr-tiles-count
    (if chr-bytes
        (count-nonzero-chr-tiles chr-bytes)
        0))

  ;; 6. Compute Zero-Page live variables from `defzp-map` declaration
  (define zp-vars-list
    (if (pair? zp-map)
        (for/list ([entry (in-list zp-map)])
          (hasheq 'name  (hash-ref entry 'id 'zp_var)
                  'bytes (hash-ref entry 'bytes 1)
                  'cap   'RamLinear))
        (list (hasheq 'name 'zp_game_state 'bytes 16 'cap 'RamLinear))))

  (define effective-vram-bytes
    (if vram-bytes
        (max vram-bytes nmi-vram-writes)
        nmi-vram-writes))

  (define fsm-list
    (cond
      [(null? state-machines) '()]
      [(hash? state-machines) (list state-machines)]
      [(list? state-machines) state-machines]
      [else '()]))

  (define page-cross-count
    (if asm-res
        (asm-result-page-crossings asm-res)
        0))

  (define prg-byte-count
    (if asm-res
        (bytes-length (asm-result-bytes asm-res))
        (estimate-6502-ast-prg-bytes forms)))

  (hasheq 'name              name
          'mapper            mapper
          'mirroring         mirroring
          'scroll-mode       scroll-mode
          'state-machines    fsm-list
          'zp-map            zp-map
          'zp-vars           zp-vars-list
          'zp-scratch-blocks (normalize-scratch-list zp-scratch-blocks)
          'subroutines       (list (hasheq 'name      'nmi_handler
                                           'pha-count nmi-pha-count
                                           'pla-count nmi-pla-count))
          'ppu-ops           (reverse ppu-ops-rev)
          'nmi-ops           (reverse nmi-ops-rev)
          'vblank-cycles     vblank-cycles
          'active-cycles     active-cycles
          'page-crossings    page-cross-count
          'oam-sprites       oam-sprites
          'scanline-sprites  scanline-sprites
          'ram-bytes         ram-bytes
          'prg-rom-bytes     prg-byte-count
          'chr-tiles         chr-tiles-count
          'vram-dma-bytes    effective-vram-bytes
          'attr-clashes      0
          'apu-channels      detected-apu-channels))

;; ============================================================================
;; 4. End-to-End `defnes-game` Compiler Pipeline
;;    Step 1 (Pre-Assembly): Infer & verify grades from DSL AST & resources
;;    Step 2 (Post-Typecheck): Emit & assemble 6502 code, verify Grade Preservation
;; ============================================================================

(define (compile-boba-nes-game! #:id               [game-id 'nes-game]
                                #:name             [name-sym game-id]
                                #:mapper           [mapper-sym 'NROM]
                                #:mirroring        [mir-sym 'vertical]
                                #:chr              chr-bytes
                                #:zp-map           [zp-map '()]
                                #:state-machine    [fsm #f]
                                #:metasprites      [metasprites '()]
                                #:sprite-tiles     [sprite-tiles '()]
                                #:oam-template     [oam-template #f]
                                #:oam-sprites      [oam-n #f]
                                #:scanline-sprites [scan-n #f]
                                #:vram-bytes       [vram-b #f]
                                #:ram-bytes        [ram-b 64]
                                #:vblank-scratch   [vb-scratch '()]
                                #:active-scratch   [act-scratch '()]
                                #:vblank-block     [vblank-blk #f]
                                #:active-block     [active-blk #f]
                                #:vblank-ast       [vblank-ast #f]
                                #:active-ast       [active-ast #f]
                                #:program          raw-forms
                                #:out-rom          [out-rom-path #f]
                                #:budget           [budget NTSC-NROM-BUDGET])
  (define all-scratch
    (append (normalize-scratch-list vb-scratch)
            (normalize-scratch-list act-scratch)))

  ;; --------------------------------------------------------------------------
  ;; STEP 1: Type-Checking Time (Pre-Assembly DSL & Resource Grade Inference)
  ;; Infer Phi1..Phi5 and L1..L4 purely from the DSL declarations, resources,
  ;; and AST BEFORE invoking `optimize-6502-peephole` or `assemble-6502`!
  ;; --------------------------------------------------------------------------
  (define pre-ast-mod
    (analyze-6502-ast-grades raw-forms #f
                             #:chr-bytes         chr-bytes
                             #:zp-map            zp-map
                             #:state-machines    (if fsm (list fsm) '())
                             #:name              name-sym
                             #:mapper            mapper-sym
                             #:mirroring         mir-sym
                             #:oam-sprites       (or oam-n 11)
                             #:scanline-sprites  (or scan-n 4)
                             #:vram-bytes        vram-b
                             #:ram-bytes         ram-b
                             #:zp-scratch-blocks all-scratch))

  (define dsl-pre-mod
    (synthesize-dsl-module-grades
     #:name              name-sym
     #:mapper            mapper-sym
     #:mirroring         mir-sym
     #:zp-map            zp-map
     #:vblank-scratch    vb-scratch
     #:active-scratch    act-scratch
     #:metasprites       metasprites
     #:sprite-tiles      sprite-tiles
     #:oam-template      oam-template
     #:oam-sprites       oam-n
     #:scanline-sprites  scan-n
     #:chr               chr-bytes
     #:state-machine     fsm
     #:vblank-block      vblank-blk
     #:active-block      active-blk
     #:vblank-ast        vblank-ast
     #:active-ast        active-ast
     #:nmi-subroutines   (hash-ref pre-ast-mod 'subroutines)
     #:vram-bytes        (hash-ref pre-ast-mod 'vram-dma-bytes)
     #:ram-bytes         ram-b
     #:prg-rom-bytes     (hash-ref pre-ast-mod 'prg-rom-bytes)
     #:apu-channels      (hash-ref pre-ast-mod 'apu-channels)))

  ;; Merge AST-inferred cycles/ops when explicit `vblank-blk`/`active-blk` were not passed
  (define pre-typecheck-mod
    (hash-set
     (hash-set
      (hash-set
       (hash-set dsl-pre-mod
                 'vblank-cycles (max (hash-ref dsl-pre-mod 'vblank-cycles 0)
                                     (hash-ref pre-ast-mod 'vblank-cycles 0)))
       'active-cycles (max (hash-ref dsl-pre-mod 'active-cycles 0)
                           (hash-ref pre-ast-mod 'active-cycles 0)))
      'ppu-ops (if (pair? (hash-ref dsl-pre-mod 'ppu-ops '()))
                   (hash-ref dsl-pre-mod 'ppu-ops)
                   (hash-ref pre-ast-mod 'ppu-ops)))
     'nmi-ops (if (pair? (hash-ref dsl-pre-mod 'nmi-ops '()))
                  (hash-ref dsl-pre-mod 'nmi-ops)
                  (hash-ref pre-ast-mod 'nmi-ops))))

  (define-values (pre-verified-mod pre-repairs pre-type-res)
    (compile-and-verify-nes-module pre-typecheck-mod budget))
  (unless (nes-type-result-well-typed? pre-type-res)
    (error 'defnes-game
           "Pre-assembly DSL hardware grade verification failed for ~a:\n~a"
           name-sym
           (resugar-module-diagnostics pre-type-res)))

  ;; --------------------------------------------------------------------------
  ;; STEP 2: Codegen & Soundness / Grade-Preservation Check (Post-Typecheck)
  ;; Only after DSL type-checking succeeds, optimize & assemble 6502 machine
  ;; code and verify Grade Preservation (0 page crossings, exact binary size).
  ;; --------------------------------------------------------------------------
  (define opt-forms (optimize-6502-peephole raw-forms))
  (define peep-stats (optimize-6502-peephole-stats raw-forms))
  (define asm-res (assemble-6502 opt-forms #:origin #x8000))

  (define post-mod
    (analyze-6502-ast-grades opt-forms asm-res
                             #:chr-bytes         chr-bytes
                             #:zp-map            (hash-ref pre-verified-mod 'zp-map zp-map)
                             #:state-machines    (hash-ref pre-verified-mod 'state-machines '())
                             #:name              name-sym
                             #:mapper            mapper-sym
                             #:mirroring         (hash-ref pre-verified-mod 'mirroring mir-sym)
                             #:oam-sprites       (hash-ref pre-verified-mod 'oam-sprites 11)
                             #:scanline-sprites  (hash-ref pre-verified-mod 'scanline-sprites 4)
                             #:vram-bytes        (hash-ref pre-verified-mod 'vram-dma-bytes vram-b)
                             #:ram-bytes         ram-b
                             #:zp-scratch-blocks all-scratch))

  (define-values (verified-mod post-repairs type-res)
    (compile-and-verify-nes-module post-mod budget))
  (define repairs (remove-duplicates (append pre-repairs post-repairs)))
  (define grade-preserved?
    (and (nes-type-result-well-typed? type-res)
         (zero? (asm-result-page-crossings asm-res))
         (<= (nes-grade-cycles (nes-type-result-vblank-grade type-res))
             (nes-grade-cycles (nes-type-result-vblank-grade pre-type-res)))
         (<= (nes-grade-cycles (nes-type-result-active-grade type-res))
             (nes-grade-cycles (nes-type-result-active-grade pre-type-res)))))

  (unless (and (nes-type-result-well-typed? type-res) grade-preserved?)
    (error 'defnes-game
           "Post-assembly 6502 grade preservation check failed for ~a:\n~a"
           name-sym
           (resugar-module-diagnostics type-res)))

  ;; Link iNES 1.0 (.nes) binary ROM image and write to disk if #:out-rom is specified
  (define rom-bytes
    (build-ines-rom asm-res chr-bytes #:mirroring mir-sym))
  (when out-rom-path
    (define resolved-out (resolve-rom-path out-rom-path))
    (make-directory* (path-only resolved-out))
    (write-ines-rom-file! resolved-out rom-bytes))

  (hasheq 'id               game-id
          'name             name-sym
          'rom-bytes        rom-bytes
          'asm-result       asm-res
          'pre-type-result  pre-type-res
          'type-result      type-res
          'grade-preserved? grade-preserved?
          'module-desc      verified-mod
          'repairs          repairs
          'peephole-stats   peep-stats))

(define compile-boba-dsl-game! compile-boba-nes-game!)

(define-syntax-rule (defnes-game game-id kw-arg ...)
  (define game-id
    (compile-boba-nes-game! #:id 'game-id kw-arg ...)))
