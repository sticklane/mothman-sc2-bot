#lang racket/base

;; ============================================================================
;; #lang boba-nes : Super Nintendo (SNES) Hardware Backend
;;   - Flow-Sensitive WDC 65C816 Mode-Indexed Two-Pass Assembler & Verifier
;;   - Automatic Control-Flow Join Mode Reconciler (REP/SEP Insertion)
;;   - Sony SPC700 Audio Co-Processor Assembler & IPL ROM ($2140-$2143) Uploader
;;   - S-PPU 4bpp Planar Tile Packer, 15-bit BGR555 CGRAM, DMA0 & HDMA1 Builders
;;   - 32 KB FastROM LoROM (.sfc) Cartridge Linker with Checksum/Complement
;;   - Headless SNES 65C816 + S-PPU + S-CPU DMA/HDMA + SPC700 Execution Verifier
;; ============================================================================

(require racket/match
         racket/list
         racket/format
         racket/string
         racket/bytes
         racket/math
         racket/file
         racket/path)

(provide
 ;; 1. Flow-Sensitive WDC 65C816 Mode-Indexed Assembler & Mode-Safety Verifier
 (struct-out cpu-mode-65816)
 (struct-out mode-conflict-65816)
 (struct-out mode-safety-result)
 (struct-out asm-65816-result)
 make-initial-65816-mode
 step-65816-mode
 verify-65816-mode-safety
 reconcile-65816-branch-modes
 assemble-65816

 ;; 2. Sony SPC700 Audio Co-Processor Assembler & 5A22 IPL Handshake Uploader
 (struct-out spc700-asm-result)
 assemble-spc700
 build-boba-spc700-driver
 emit-spc700-ipl-upload

 ;; 3. S-PPU 4bpp CHR, CGRAM 15-bit BGR555, General DMA ($4300) & HBlank HDMA ($4310)
 bgr555-color
 pack-snes-cgram-palette
 pack-snes-4bpp-tile
 unpack-snes-4bpp-tile
 build-boba-snes-4bpp-tileset
 build-boba-snes-cgram-palette
 build-snes-hdma-gradient-table
 emit-snes-dma-transfer
 emit-snes-hdma-gradient

 ;; 4. SNES LoROM (.sfc) Cartridge Linker & Full Boba SNES ROM Builder
 compute-snes-lorom-checksum
 build-snes-lorom-image
 build-boba-snes-65816-program
 compile-boba-snes-rom!

 ;; 5. Headless SNES 65C816 + S-PPU + SPC700 VM & Campaign Verifier
 (struct-out snes-vm)
 (struct-out snes-verification-report)
 make-snes-vm-from-rom
 snes-reset!
 snes-set-joypad1!
 snes-step-instruction!
 snes-run-until-wai-or-rti!
 snes-step-frame!
 verify-snes-rom-execution

 ;; 6. SNES Controller 1 Button Bitmasks ($4218/$4219) & Direct Page Constants
 SNES-BTN-B
 SNES-BTN-Y
 SNES-BTN-SELECT
 SNES-BTN-START
 SNES-BTN-UP
 SNES-BTN-DOWN
 SNES-BTN-LEFT
 SNES-BTN-RIGHT
 SNES-BTN-A
 SNES-BTN-X
 SNES-BTN-L
 SNES-BTN-R
 DP-JOY-LO
 DP-JOY-HI
 DP-CUR-STAGE
 DP-STAGE-STATUS
 DP-PLAYER-X
 DP-PLAYER-Y
 DP-MOVE-COUNT
 DP-RECOVERIES
 DP-FRAME-COUNT
 DP-SPC-CMD
 DP-RULE-MASK
 DP-CAMPAIGN-WON
 DP-STAGE-CLEARS)

;; ============================================================================
;; 0. SNES Hardware Constants, Joypad Masks & Direct Page Layout
;; ============================================================================

;; 16-bit SNES Joypad 1 register ($4218 = low byte, $4219 = high byte)
(define SNES-BTN-B      #x8000)
(define SNES-BTN-Y      #x4000)
(define SNES-BTN-SELECT #x2000)
(define SNES-BTN-START  #x1000)
(define SNES-BTN-UP     #x0800)
(define SNES-BTN-DOWN   #x0400)
(define SNES-BTN-LEFT   #x0200)
(define SNES-BTN-RIGHT  #x0100)
(define SNES-BTN-A      #x0080)
(define SNES-BTN-X      #x0040)
(define SNES-BTN-L      #x0020)
(define SNES-BTN-R      #x0010)

;; Direct Page ($0000-$00FF) Game Engine State Addresses
(define DP-JOY-LO       #x10) ; $4218 low joypad byte (A, X, L, R)
(define DP-JOY-HI       #x11) ; $4219 high joypad byte (B, Y, SELECT, START, U, D, L, R)
(define DP-CUR-STAGE    #x12) ; Current stage index (0..3)
(define DP-STAGE-STATUS #x13) ; 0 = playing, 1 = failed (defeat), 2 = victory
(define DP-PLAYER-X     #x14) ; Boba X coordinate on 16x14 board
(define DP-PLAYER-Y     #x15) ; Boba Y coordinate on 16x14 board
(define DP-MOVE-COUNT   #x16) ; Total player actions in campaign
(define DP-RECOVERIES   #x17) ; Total START recoveries from failure state
(define DP-FRAME-COUNT  #x18) ; 16-bit VBlank frame counter ($18..$19)
(define DP-SPC-CMD      #x1A) ; Last audio command byte sent to SPC700 ($2140)
(define DP-RULE-MASK    #x1B) ; Active rule bitmask (#x1F = YOU|PUSH|STOP|WIN|DEFEAT)
(define DP-CAMPAIGN-WON #x1C) ; 1 when Stage 3 Victory is achieved
(define DP-STAGE-CLEARS #x1D) ; Bitmask of cleared stages (#x0F = all 4 stages cleared)

;; ============================================================================
;; 1. Flow-Sensitive WDC 65C816 Mode-Indexed Assembler & Mode-Safety Verifier
;; ============================================================================
;; Tracks processor status flags (M, X, E, C):
;;   - m : 8 or 16 (Accumulator & memory immediate width)
;;   - x : 8 or 16 (Index X/Y immediate width)
;;   - e : 'emulation or 'native (6502 emulation vs 65C816 native mode)
;;   - c : #t, #f, or 'unknown (Carry flag for CLC/SEC -> XCE transitions)

(struct cpu-mode-65816 (m x e c) #:transparent)
(struct mode-conflict-65816 (label expected-mode actual-mode origin) #:transparent)
(struct mode-safety-result (mode-safe? label-modes instruction-modes conflicts) #:transparent)
(struct asm-65816-result (bytes labels cycles instruction-count mode-safe? label-modes conflicts) #:transparent)

(define (make-initial-65816-mode #:m [m 8] #:x [x 8] #:e [e 'emulation] #:c [c 'unknown])
  (cpu-mode-65816 m x e c))

(define (modes-compatible-65816? m1 m2)
  (and (= (cpu-mode-65816-m m1) (cpu-mode-65816-m m2))
       (= (cpu-mode-65816-x m1) (cpu-mode-65816-x m2))
       (eq? (cpu-mode-65816-e m1) (cpu-mode-65816-e m2))))

(define (label-form? form)
  (or (symbol? form)
      (match form
        [`(label ,(? symbol? _)) #t]
        [`(entry-label ,(? symbol? _) . ,_) #t]
        [_ #f])))

(define (extract-label-name form)
  (cond
    [(symbol? form) form]
    [else
     (match form
       [`(label ,sym) sym]
       [`(entry-label ,sym . ,_) sym]
       [_ #f])]))

(define (extract-entry-label-mode form)
  (match form
    [`(entry-label ,_ #:m ,m #:x ,x #:e ,e)
     (cpu-mode-65816 m x e 'unknown)]
    [`(entry-label ,_ #:m ,m #:x ,x)
     (cpu-mode-65816 m x 'native 'unknown)]
    [_ #f]))

;; Update (M, X, E, C) state after executing a single 65C816 instruction
(define (step-65816-mode inst mode)
  (define m (cpu-mode-65816-m mode))
  (define x (cpu-mode-65816-x mode))
  (define e (cpu-mode-65816-e mode))
  (define c (cpu-mode-65816-c mode))
  (match inst
    [`(clc) (cpu-mode-65816 m x e #f)]
    [`(sec) (cpu-mode-65816 m x e #t)]
    [`(xce)
     (cond
       [(eq? c #f)
        (cpu-mode-65816 m x 'native (eq? e 'emulation))]
       [(eq? c #t)
        (cpu-mode-65816 8 8 'emulation (eq? e 'emulation))]
       [else
        (cpu-mode-65816 m x 'native 'unknown)])]
    [`(rep ,mask)
     (if (eq? e 'emulation)
         (cpu-mode-65816 8 8 'emulation
                         (if (bitwise-bit-set? mask 0) #f c))
         (cpu-mode-65816 (if (bitwise-bit-set? mask 5) 16 m)
                         (if (bitwise-bit-set? mask 4) 16 x)
                         e
                         (if (bitwise-bit-set? mask 0) #f c)))]
    [`(sep ,mask)
     (cpu-mode-65816 (if (bitwise-bit-set? mask 5) 8 m)
                     (if (bitwise-bit-set? mask 4) 8 x)
                     e
                     (if (bitwise-bit-set? mask 0) #t c))]
    [`(assume-mode #:m ,nm #:x ,nx #:e ,ne)
     (cpu-mode-65816 nm nx ne 'unknown)]
    [`(assume-mode #:m ,nm #:x ,nx)
     (cpu-mode-65816 nm nx e 'unknown)]
    [_ mode]))

;; Determine control-flow targets and whether an instruction falls through
(define (instruction-control-flow-65816 inst)
  (match inst
    [`(bra ,(? symbol? tgt)) (values (list tgt) #f)]
    [`(brl ,(? symbol? tgt)) (values (list tgt) #f)]
    [`(jmp ,(? symbol? tgt)) (values (list tgt) #f)]
    [`(jmp ,_)               (values '() #f)]
    [`(jml ,_)               (values '() #f)]
    [`(rts)                  (values '() #f)]
    [`(rtl)                  (values '() #f)]
    [`(rti)                  (values '() #f)]
    [`(stp)                  (values '() #f)]
    [`(jsr ,(? symbol? tgt)) (values (list tgt) #t)]
    [`(beq ,(? symbol? tgt)) (values (list tgt) #t)]
    [`(bne ,(? symbol? tgt)) (values (list tgt) #t)]
    [`(bpl ,(? symbol? tgt)) (values (list tgt) #t)]
    [`(bmi ,(? symbol? tgt)) (values (list tgt) #t)]
    [`(bcc ,(? symbol? tgt)) (values (list tgt) #t)]
    [`(bcs ,(? symbol? tgt)) (values (list tgt) #t)]
    [`(bvc ,(? symbol? tgt)) (values (list tgt) #t)]
    [`(bvs ,(? symbol? tgt)) (values (list tgt) #t)]
    [_                       (values '() #t)]))

;; Flow-sensitive static verification of (M, X, E) across all instructions and labels
(define (verify-65816-mode-safety forms
                                  #:init-m [init-m 8]
                                  #:init-x [init-x 8]
                                  #:init-e [init-e 'emulation]
                                  #:vector-modes [vector-modes
                                                  (hasheq 'nmi_vector (cpu-mode-65816 8 16 'native 'unknown)
                                                          'irq_vector (cpu-mode-65816 8 16 'native 'unknown))])
  (define label-modes (make-hasheq))
  (define label-origins (make-hasheq))
  (define conflicts '())
  (define inst-modes '())

  ;; Pre-seed any explicit entry-label or known hardware interrupt vector modes
  (for ([f (in-list forms)])
    (when (label-form? f)
      (define sym (extract-label-name f))
      (define explicit-mode (or (extract-entry-label-mode f)
                                (hash-ref vector-modes sym #f)))
      (when explicit-mode
        (hash-set! label-modes sym explicit-mode)
        (hash-set! label-origins sym 'entry-vector))))

  (define (record-label-edge! sym incoming-mode origin)
    (cond
      [(hash-has-key? label-modes sym)
       (define existing (hash-ref label-modes sym))
       (unless (modes-compatible-65816? existing incoming-mode)
         (set! conflicts
               (append conflicts
                       (list (mode-conflict-65816 sym existing incoming-mode origin)))))]
      [else
       (hash-set! label-modes sym incoming-mode)
       (hash-set! label-origins sym origin)]))

  (let loop ([rem forms]
             [idx 0]
             [cur-mode (make-initial-65816-mode #:m init-m #:x init-x #:e init-e)]
             [reachable? #t])
    (match rem
      ['()
       (mode-safety-result (null? conflicts)
                           (hash-copy label-modes)
                           (reverse inst-modes)
                           conflicts)]
      [(cons form rest)
       (cond
         [(label-form? form)
          (define sym (extract-label-name form))
          (when reachable?
            (record-label-edge! sym cur-mode `(fallthrough ,idx)))
          (define joined-mode
            (hash-ref label-modes sym cur-mode))
          (set! inst-modes (cons (cons form joined-mode) inst-modes))
          (loop rest (add1 idx) joined-mode #t)]
         [else
          (define active-mode cur-mode)
          (define next-mode (step-65816-mode form active-mode))
          (set! inst-modes (cons (cons form active-mode) inst-modes))
          (define-values (targets falls-through?)
            (instruction-control-flow-65816 form))
          (when reachable?
            (for ([tgt (in-list targets)])
              (record-label-edge! tgt next-mode `(branch ,idx ,form))))
          (loop rest (add1 idx) next-mode (and reachable? falls-through?))])])))

;; Emit minimal REP/SEP instructions to transition from `from-mode` to `to-mode`
(define (emit-mode-transition-65816 from-mode to-mode)
  (define rep-mask
    (bitwise-ior (if (and (= (cpu-mode-65816-m from-mode) 8)
                          (= (cpu-mode-65816-m to-mode) 16))
                     #x20 0)
                 (if (and (= (cpu-mode-65816-x from-mode) 8)
                          (= (cpu-mode-65816-x to-mode) 16))
                     #x10 0)))
  (define sep-mask
    (bitwise-ior (if (and (= (cpu-mode-65816-m from-mode) 16)
                          (= (cpu-mode-65816-m to-mode) 8))
                     #x20 0)
                 (if (and (= (cpu-mode-65816-x from-mode) 16)
                          (= (cpu-mode-65816-x to-mode) 8))
                     #x10 0)))
  (append (if (> rep-mask 0) `((rep ,rep-mask)) '())
          (if (> sep-mask 0) `((sep ,sep-mask)) '())))

;; Automatically insert REP/SEP before control-flow joins where incoming (M, X) states disagree
(define (reconcile-65816-branch-modes forms
                                      #:init-m [init-m 8]
                                      #:init-x [init-x 8]
                                      #:init-e [init-e 'emulation])
  (define initial-check
    (verify-65816-mode-safety forms #:init-m init-m #:init-x init-x #:init-e init-e))
  (if (mode-safety-result-mode-safe? initial-check)
      forms
      (let ([target-modes (mode-safety-result-label-modes initial-check)])
        (let loop ([rem forms]
                   [cur-mode (make-initial-65816-mode #:m init-m #:x init-x #:e init-e)]
                   [reachable? #t]
                   [acc '()])
          (match rem
            ['() (reverse acc)]
            [(cons form rest)
             (cond
               [(label-form? form)
                (define sym (extract-label-name form))
                (define canonical (hash-ref target-modes sym cur-mode))
                (define fixups
                  (if (and reachable? (not (modes-compatible-65816? cur-mode canonical)))
                      (emit-mode-transition-65816 cur-mode canonical)
                      '()))
                (loop rest
                      canonical
                      #t
                      (cons form (append (reverse fixups) acc)))]
               [else
                (define next-mode (step-65816-mode form cur-mode))
                (define-values (targets falls-through?)
                  (instruction-control-flow-65816 form))
                (define branch-fixups
                  (if (and reachable? (pair? targets))
                      (let ([tgt (car targets)])
                        (define canonical (hash-ref target-modes tgt next-mode))
                        (if (not (modes-compatible-65816? next-mode canonical))
                            (emit-mode-transition-65816 next-mode canonical)
                            '()))
                      '()))
                (define updated-mode
                  (for/fold ([m next-mode]) ([fx (in-list branch-fixups)])
                    (step-65816-mode fx m)))
                (loop rest
                      updated-mode
                      (and reachable? falls-through?)
                      (cons form (append (reverse branch-fixups) acc)))])])))))

;; Compute exact byte length and cycle count of a 65C816 instruction under `mode`
(define (instruction-size-and-cycles-65816 inst mode)
  (define m-bytes (if (= (cpu-mode-65816-m mode) 16) 2 1))
  (define x-bytes (if (= (cpu-mode-65816-x mode) 16) 2 1))
  (define m-extra (if (= (cpu-mode-65816-m mode) 16) 1 0))
  (define x-extra (if (= (cpu-mode-65816-x mode) 16) 1 0))
  (cond
    [(label-form? inst) (values 0 0)]
    [else
     (match inst
       [`(assume-mode . ,_) (values 0 0)]
       [`(byte ,bs ...)     (values (length bs) 0)]
       [`(word ,ws ...)     (values (* 2 (length ws)) 0)]
       [`(bytes ,(? bytes? b)) (values (bytes-length b) 0)]

       ;; Processor status & mode switching
       [`(clc) (values 1 2)]
       [`(sec) (values 1 2)]
       [`(sei) (values 1 2)]
       [`(cli) (values 1 2)]
       [`(xce) (values 1 2)]
       [`(rep ,_) (values 2 3)]
       [`(sep ,_) (values 2 3)]
       [`(nop) (values 1 2)]
       [`(wai) (values 1 3)]
       [`(stp) (values 1 3)]

       ;; Mode-width-sensitive immediate loads & ALU
       [`(lda-imm ,_) (values (+ 1 m-bytes) (+ 2 m-extra))]
       [`(adc-imm ,_) (values (+ 1 m-bytes) (+ 2 m-extra))]
       [`(sbc-imm ,_) (values (+ 1 m-bytes) (+ 2 m-extra))]
       [`(and-imm ,_) (values (+ 1 m-bytes) (+ 2 m-extra))]
       [`(ora-imm ,_) (values (+ 1 m-bytes) (+ 2 m-extra))]
       [`(eor-imm ,_) (values (+ 1 m-bytes) (+ 2 m-extra))]
       [`(cmp-imm ,_) (values (+ 1 m-bytes) (+ 2 m-extra))]
       [`(bit-imm ,_) (values (+ 1 m-bytes) (+ 2 m-extra))]

       [`(ldx-imm ,_) (values (+ 1 x-bytes) (+ 2 x-extra))]
       [`(ldy-imm ,_) (values (+ 1 x-bytes) (+ 2 x-extra))]
       [`(cpx-imm ,_) (values (+ 1 x-bytes) (+ 2 x-extra))]
       [`(cpy-imm ,_) (values (+ 1 x-bytes) (+ 2 x-extra))]

       ;; Direct Page (2 bytes)
       [`(lda-dp ,_)   (values 2 (+ 3 m-extra))]
       [`(sta-dp ,_)   (values 2 (+ 3 m-extra))]
       [`(ldx-dp ,_)   (values 2 (+ 3 x-extra))]
       [`(stx-dp ,_)   (values 2 (+ 3 x-extra))]
       [`(ldy-dp ,_)   (values 2 (+ 3 x-extra))]
       [`(sty-dp ,_)   (values 2 (+ 3 x-extra))]
       [`(stz-dp ,_)   (values 2 (+ 3 m-extra))]
       [`(lda-dp-x ,_) (values 2 (+ 4 m-extra))]
       [`(sta-dp-x ,_) (values 2 (+ 4 m-extra))]
       [`(stz-dp-x ,_) (values 2 (+ 4 m-extra))]
       [`(inc-dp ,_)   (values 2 (+ 5 m-extra))]
       [`(dec-dp ,_)   (values 2 (+ 5 m-extra))]
       [`(adc-dp ,_)   (values 2 (+ 3 m-extra))]
       [`(sbc-dp ,_)   (values 2 (+ 3 m-extra))]
       [`(and-dp ,_)   (values 2 (+ 3 m-extra))]
       [`(ora-dp ,_)   (values 2 (+ 3 m-extra))]
       [`(eor-dp ,_)   (values 2 (+ 3 m-extra))]
       [`(cmp-dp ,_)   (values 2 (+ 3 m-extra))]

       ;; Absolute 16-bit (3 bytes)
       [`(lda-abs ,_)   (values 3 (+ 4 m-extra))]
       [`(sta-abs ,_)   (values 3 (+ 4 m-extra))]
       [`(ldx-abs ,_)   (values 3 (+ 4 x-extra))]
       [`(stx-abs ,_)   (values 3 (+ 4 x-extra))]
       [`(ldy-abs ,_)   (values 3 (+ 4 x-extra))]
       [`(sty-abs ,_)   (values 3 (+ 4 x-extra))]
       [`(stz-abs ,_)   (values 3 (+ 4 m-extra))]
       [`(lda-abs-x ,_) (values 3 (+ 4 m-extra))]
       [`(sta-abs-x ,_) (values 3 (+ 5 m-extra))]
       [`(stz-abs-x ,_) (values 3 (+ 5 m-extra))]
       [`(lda-abs-y ,_) (values 3 (+ 4 m-extra))]
       [`(sta-abs-y ,_) (values 3 (+ 5 m-extra))]
       [`(inc-abs ,_)   (values 3 (+ 6 m-extra))]
       [`(dec-abs ,_)   (values 3 (+ 6 m-extra))]
       [`(adc-abs ,_)   (values 3 (+ 4 m-extra))]
       [`(sbc-abs ,_)   (values 3 (+ 4 m-extra))]
       [`(and-abs ,_)   (values 3 (+ 4 m-extra))]
       [`(ora-abs ,_)   (values 3 (+ 4 m-extra))]
       [`(eor-abs ,_)   (values 3 (+ 4 m-extra))]
       [`(cmp-abs ,_)   (values 3 (+ 4 m-extra))]
       [`(bit-abs ,_)   (values 3 (+ 4 m-extra))]

       ;; Long 24-bit addressing (4 bytes)
       [`(sta-long ,_)   (values 4 (+ 5 m-extra))]
       [`(lda-long ,_)   (values 4 (+ 5 m-extra))]
       [`(lda-long-x ,_) (values 4 (+ 5 m-extra))]
       [`(sta-long-x ,_) (values 4 (+ 5 m-extra))]

       ;; Implied register increments, shifts & transfers (1 byte)
       [`(inx)   (values 1 2)]
       [`(dex)   (values 1 2)]
       [`(iny)   (values 1 2)]
       [`(dey)   (values 1 2)]
       [`(inc-a) (values 1 2)]
       [`(dec-a) (values 1 2)]
       [`(asl-a) (values 1 2)]
       [`(lsr-a) (values 1 2)]
       [`(rol-a) (values 1 2)]
       [`(ror-a) (values 1 2)]
       [`(tax)   (values 1 2)]
       [`(txa)   (values 1 2)]
       [`(tay)   (values 1 2)]
       [`(tya)   (values 1 2)]
       [`(tsx)   (values 1 2)]
       [`(txs)   (values 1 2)]
       [`(txy)   (values 1 2)]
       [`(tyx)   (values 1 2)]
       [`(tcd)   (values 1 2)]
       [`(tdc)   (values 1 2)]
       [`(tcs)   (values 1 2)]
       [`(tsc)   (values 1 2)]
       [`(xba)   (values 1 3)]

       ;; Stack operations (1 byte)
       [`(pha) (values 1 (+ 3 m-extra))]
       [`(pla) (values 1 (+ 4 m-extra))]
       [`(phx) (values 1 (+ 3 x-extra))]
       [`(plx) (values 1 (+ 4 x-extra))]
       [`(phy) (values 1 (+ 3 x-extra))]
       [`(ply) (values 1 (+ 4 x-extra))]
       [`(php) (values 1 3)]
       [`(plp) (values 1 4)]
       [`(phb) (values 1 3)]
       [`(plb) (values 1 4)]
       [`(phd) (values 1 4)]
       [`(pld) (values 1 5)]
       [`(phk) (values 1 3)]

       ;; Jumps, calls, returns & branches
       [`(jmp ,_) (values 3 3)]
       [`(jml ,_) (values 4 4)]
       [`(jsr ,_) (values 3 6)]
       [`(jsl ,_) (values 4 8)]
       [`(rts)    (values 1 6)]
       [`(rtl)    (values 1 6)]
       [`(rti)    (values 1 6)]
       [`(bra ,_) (values 2 3)]
       [`(brl ,_) (values 3 4)]
       [`(beq ,_) (values 2 2)]
       [`(bne ,_) (values 2 2)]
       [`(bpl ,_) (values 2 2)]
       [`(bmi ,_) (values 2 2)]
       [`(bcc ,_) (values 2 2)]
       [`(bcs ,_) (values 2 2)]
       [`(bvc ,_) (values 2 2)]
       [`(bvs ,_) (values 2 2)]

       ;; 65C816 Hardware Block Move (MVN/MVP: 3 bytes)
       [`(mvn ,_ ,_) (values 3 7)]
       [`(mvp ,_ ,_) (values 3 7)]

       [_ (error 'assemble-65816 "Unknown 65C816 instruction form: ~s" inst)])]))

;; Evaluate numeric or symbolic operand expression against label table
(define (resolve-65816-expr expr labels)
  (match expr
    [(? integer? n) n]
    [(? symbol? s)
     (hash-ref labels s
               (lambda ()
                 (error 'assemble-65816 "Undefined 65C816 label: ~a" s)))]
    [`(lo ,sub)
     (bitwise-and (resolve-65816-expr sub labels) #xFF)]
    [`(hi ,sub)
     (bitwise-and (arithmetic-shift (resolve-65816-expr sub labels) -8) #xFF)]
    [`(bank ,sub)
     (bitwise-and (arithmetic-shift (resolve-65816-expr sub labels) -16) #xFF)]
    [`(+ ,a ,b)
     (+ (resolve-65816-expr a labels) (resolve-65816-expr b labels))]
    [`(- ,a ,b)
     (- (resolve-65816-expr a labels) (resolve-65816-expr b labels))]
    [_ (error 'assemble-65816 "Invalid operand expression: ~s" expr)]))

(define (u8-byte v)
  (bitwise-and v #xFF))

(define (u16-lo-hi v)
  (list (bitwise-and v #xFF)
        (bitwise-and (arithmetic-shift v -8) #xFF)))

(define (u24-lo-hi-bank v)
  (list (bitwise-and v #xFF)
        (bitwise-and (arithmetic-shift v -8) #xFF)
        (bitwise-and (arithmetic-shift v -16) #xFF)))

(define (emit-imm-bytes opcode val width-bits labels)
  (define v (resolve-65816-expr val labels))
  (if (= width-bits 16)
      (cons opcode (u16-lo-hi v))
      (list opcode (u8-byte v))))

(define (emit-rel8-branch opcode target pc labels)
  (define tgt-addr
    (if (symbol? target)
        (resolve-65816-expr target labels)
        (+ pc 2 target)))
  (define disp (- tgt-addr (+ pc 2)))
  (when (or (< disp -128) (> disp 127))
    (error 'assemble-65816
           "Relative branch target ~a out of 8-bit range at PC=$~x (disp=~a)"
           target pc disp))
  (list opcode (bitwise-and disp #xFF)))

;; Encode a single 65C816 instruction into a list of bytes
(define (encode-instruction-65816 inst mode pc labels)
  (define m-bits (cpu-mode-65816-m mode))
  (define x-bits (cpu-mode-65816-x mode))
  (cond
    [(label-form? inst) '()]
    [else
     (match inst
       [`(assume-mode . ,_) '()]
       [`(byte ,bs ...)
        (map (lambda (b) (u8-byte (resolve-65816-expr b labels))) bs)]
       [`(word ,ws ...)
        (append-map (lambda (w) (u16-lo-hi (resolve-65816-expr w labels))) ws)]
       [`(bytes ,(? bytes? b))
        (bytes->list b)]

       ;; Status & mode control
       [`(clc) (list #x18)]
       [`(sec) (list #x38)]
       [`(sei) (list #x78)]
       [`(cli) (list #x58)]
       [`(xce) (list #xFB)]
       [`(rep ,mask) (list #xC2 (u8-byte (resolve-65816-expr mask labels)))]
       [`(sep ,mask) (list #xE2 (u8-byte (resolve-65816-expr mask labels)))]
       [`(nop) (list #xEA)]
       [`(wai) (list #xCB)]
       [`(stp) (list #xDB)]

       ;; Mode-indexed Immediate instructions (2B when 8-bit, 3B when 16-bit!)
       [`(lda-imm ,v) (emit-imm-bytes #xA9 v m-bits labels)]
       [`(adc-imm ,v) (emit-imm-bytes #x69 v m-bits labels)]
       [`(sbc-imm ,v) (emit-imm-bytes #xE9 v m-bits labels)]
       [`(and-imm ,v) (emit-imm-bytes #x29 v m-bits labels)]
       [`(ora-imm ,v) (emit-imm-bytes #x09 v m-bits labels)]
       [`(eor-imm ,v) (emit-imm-bytes #x49 v m-bits labels)]
       [`(cmp-imm ,v) (emit-imm-bytes #xC9 v m-bits labels)]
       [`(bit-imm ,v) (emit-imm-bytes #x89 v m-bits labels)]

       [`(ldx-imm ,v) (emit-imm-bytes #xA2 v x-bits labels)]
       [`(ldy-imm ,v) (emit-imm-bytes #xA0 v x-bits labels)]
       [`(cpx-imm ,v) (emit-imm-bytes #xE0 v x-bits labels)]
       [`(cpy-imm ,v) (emit-imm-bytes #xC0 v x-bits labels)]

       ;; Direct Page (2B)
       [`(lda-dp ,zp)   (list #xA5 (u8-byte (resolve-65816-expr zp labels)))]
       [`(sta-dp ,zp)   (list #x85 (u8-byte (resolve-65816-expr zp labels)))]
       [`(ldx-dp ,zp)   (list #xA6 (u8-byte (resolve-65816-expr zp labels)))]
       [`(stx-dp ,zp)   (list #x86 (u8-byte (resolve-65816-expr zp labels)))]
       [`(ldy-dp ,zp)   (list #xA4 (u8-byte (resolve-65816-expr zp labels)))]
       [`(sty-dp ,zp)   (list #x84 (u8-byte (resolve-65816-expr zp labels)))]
       [`(stz-dp ,zp)   (list #x64 (u8-byte (resolve-65816-expr zp labels)))]
       [`(lda-dp-x ,zp) (list #xB5 (u8-byte (resolve-65816-expr zp labels)))]
       [`(sta-dp-x ,zp) (list #x95 (u8-byte (resolve-65816-expr zp labels)))]
       [`(stz-dp-x ,zp) (list #x74 (u8-byte (resolve-65816-expr zp labels)))]
       [`(inc-dp ,zp)   (list #xE6 (u8-byte (resolve-65816-expr zp labels)))]
       [`(dec-dp ,zp)   (list #xC6 (u8-byte (resolve-65816-expr zp labels)))]
       [`(adc-dp ,zp)   (list #x65 (u8-byte (resolve-65816-expr zp labels)))]
       [`(sbc-dp ,zp)   (list #xE5 (u8-byte (resolve-65816-expr zp labels)))]
       [`(and-dp ,zp)   (list #x25 (u8-byte (resolve-65816-expr zp labels)))]
       [`(ora-dp ,zp)   (list #x05 (u8-byte (resolve-65816-expr zp labels)))]
       [`(eor-dp ,zp)   (list #x45 (u8-byte (resolve-65816-expr zp labels)))]
       [`(cmp-dp ,zp)   (list #xC5 (u8-byte (resolve-65816-expr zp labels)))]

       ;; Absolute 16-bit (3B)
       [`(lda-abs ,a)   (cons #xAD (u16-lo-hi (resolve-65816-expr a labels)))]
       [`(sta-abs ,a)   (cons #x8D (u16-lo-hi (resolve-65816-expr a labels)))]
       [`(ldx-abs ,a)   (cons #xAE (u16-lo-hi (resolve-65816-expr a labels)))]
       [`(stx-abs ,a)   (cons #x8E (u16-lo-hi (resolve-65816-expr a labels)))]
       [`(ldy-abs ,a)   (cons #xAC (u16-lo-hi (resolve-65816-expr a labels)))]
       [`(sty-abs ,a)   (cons #x8C (u16-lo-hi (resolve-65816-expr a labels)))]
       [`(stz-abs ,a)   (cons #x9C (u16-lo-hi (resolve-65816-expr a labels)))]
       [`(lda-abs-x ,a) (cons #xBD (u16-lo-hi (resolve-65816-expr a labels)))]
       [`(sta-abs-x ,a) (cons #x9D (u16-lo-hi (resolve-65816-expr a labels)))]
       [`(stz-abs-x ,a) (cons #x9E (u16-lo-hi (resolve-65816-expr a labels)))]
       [`(lda-abs-y ,a) (cons #xB9 (u16-lo-hi (resolve-65816-expr a labels)))]
       [`(sta-abs-y ,a) (cons #x99 (u16-lo-hi (resolve-65816-expr a labels)))]
       [`(inc-abs ,a)   (cons #xEE (u16-lo-hi (resolve-65816-expr a labels)))]
       [`(dec-abs ,a)   (cons #xCE (u16-lo-hi (resolve-65816-expr a labels)))]
       [`(adc-abs ,a)   (cons #x6D (u16-lo-hi (resolve-65816-expr a labels)))]
       [`(sbc-abs ,a)   (cons #xED (u16-lo-hi (resolve-65816-expr a labels)))]
       [`(and-abs ,a)   (cons #x2D (u16-lo-hi (resolve-65816-expr a labels)))]
       [`(ora-abs ,a)   (cons #x0D (u16-lo-hi (resolve-65816-expr a labels)))]
       [`(eor-abs ,a)   (cons #x4D (u16-lo-hi (resolve-65816-expr a labels)))]
       [`(cmp-abs ,a)   (cons #xCD (u16-lo-hi (resolve-65816-expr a labels)))]
       [`(bit-abs ,a)   (cons #x2C (u16-lo-hi (resolve-65816-expr a labels)))]

       ;; Long 24-bit (4B)
       [`(sta-long ,u24)   (cons #x8F (u24-lo-hi-bank (resolve-65816-expr u24 labels)))]
       [`(lda-long ,u24)   (cons #xAF (u24-lo-hi-bank (resolve-65816-expr u24 labels)))]
       [`(lda-long-x ,u24) (cons #xBF (u24-lo-hi-bank (resolve-65816-expr u24 labels)))]
       [`(sta-long-x ,u24) (cons #x9F (u24-lo-hi-bank (resolve-65816-expr u24 labels)))]

       ;; Implied operations
       [`(inx)   (list #xE8)]
       [`(dex)   (list #xCA)]
       [`(iny)   (list #xC8)]
       [`(dey)   (list #x88)]
       [`(inc-a) (list #x1A)]
       [`(dec-a) (list #x3A)]
       [`(asl-a) (list #x0A)]
       [`(lsr-a) (list #x4A)]
       [`(rol-a) (list #x2A)]
       [`(ror-a) (list #x6A)]
       [`(tax)   (list #xAA)]
       [`(txa)   (list #x8A)]
       [`(tay)   (list #xA8)]
       [`(tya)   (list #x98)]
       [`(tsx)   (list #xBA)]
       [`(txs)   (list #x9A)]
       [`(txy)   (list #x9B)]
       [`(tyx)   (list #xBB)]
       [`(tcd)   (list #x5B)]
       [`(tdc)   (list #x7B)]
       [`(tcs)   (list #x1B)]
       [`(tsc)   (list #x3B)]
       [`(xba)   (list #xEB)]

       ;; Stack
       [`(pha) (list #x48)]
       [`(pla) (list #x68)]
       [`(phx) (list #xDA)]
       [`(plx) (list #xFA)]
       [`(phy) (list #x5A)]
       [`(ply) (list #x7A)]
       [`(php) (list #x08)]
       [`(plp) (list #x28)]
       [`(phb) (list #x8B)]
       [`(plb) (list #xAB)]
       [`(phd) (list #x0B)]
       [`(pld) (list #x2B)]
       [`(phk) (list #x4B)]

       ;; Control flow
       [`(jmp ,t) (cons #x4C (u16-lo-hi (resolve-65816-expr t labels)))]
       [`(jml ,t) (cons #x5C (u24-lo-hi-bank (resolve-65816-expr t labels)))]
       [`(jsr ,t) (cons #x20 (u16-lo-hi (resolve-65816-expr t labels)))]
       [`(jsl ,t) (cons #x22 (u24-lo-hi-bank (resolve-65816-expr t labels)))]
       [`(rts)    (list #x60)]
       [`(rtl)    (list #x6B)]
       [`(rti)    (list #x40)]
       [`(bra ,t) (emit-rel8-branch #x80 t pc labels)]
       [`(beq ,t) (emit-rel8-branch #xF0 t pc labels)]
       [`(bne ,t) (emit-rel8-branch #xD0 t pc labels)]
       [`(bpl ,t) (emit-rel8-branch #x10 t pc labels)]
       [`(bmi ,t) (emit-rel8-branch #x30 t pc labels)]
       [`(bcc ,t) (emit-rel8-branch #x90 t pc labels)]
       [`(bcs ,t) (emit-rel8-branch #xB0 t pc labels)]
       [`(bvc ,t) (emit-rel8-branch #x50 t pc labels)]
       [`(bvs ,t) (emit-rel8-branch #x70 t pc labels)]
       [`(brl ,t)
        (define tgt-addr (resolve-65816-expr t labels))
        (define disp (- tgt-addr (+ pc 3)))
        (cons #x82 (u16-lo-hi disp))]

       ;; 65C816 Block Move: (mvn src-bank dst-bank) -> #x54 dst-bank src-bank
       [`(mvn ,src-bank ,dst-bank)
        (list #x54
              (u8-byte (resolve-65816-expr dst-bank labels))
              (u8-byte (resolve-65816-expr src-bank labels)))]
       [`(mvp ,src-bank ,dst-bank)
        (list #x44
              (u8-byte (resolve-65816-expr dst-bank labels))
              (u8-byte (resolve-65816-expr src-bank labels)))]

       [_ (error 'encode-instruction-65816 "Unhandled instruction: ~s" inst)])]))

;; Two-Pass Mode-Indexed 65C816 Assembler
(define (assemble-65816 forms
                        #:origin [origin #x8000]
                        #:init-m [init-m 8]
                        #:init-x [init-x 8]
                        #:init-e [init-e 'emulation]
                        #:auto-reconcile? [auto-reconcile? #f]
                        #:enforce-mode-safety? [enforce-mode-safety? #t])
  (define checked-forms
    (if auto-reconcile?
        (reconcile-65816-branch-modes forms #:init-m init-m #:init-x init-x #:init-e init-e)
        forms))
  (define safety
    (verify-65816-mode-safety checked-forms #:init-m init-m #:init-x init-x #:init-e init-e))
  (when (and enforce-mode-safety? (not (mode-safety-result-mode-safe? safety)))
    (error 'assemble-65816
           "65C816 M/X mode-safety verification failed with ~a conflict(s): ~s"
           (length (mode-safety-result-conflicts safety))
           (mode-safety-result-conflicts safety)))

  (define labels (make-hasheq))
  (define inst-modes (mode-safety-result-instruction-modes safety))

  ;; Pass 1: Compute exact label addresses using flow-sensitive (M, X) instruction widths
  (define total-cycles 0)
  (define inst-count 0)
  (let pass1 ([items inst-modes]
              [pc origin])
    (match items
      ['() (void)]
      [(cons (cons form mode) rest)
       (when (label-form? form)
         (define sym (extract-label-name form))
         (hash-set! labels sym pc))
       (define-values (sz cyc)
         (instruction-size-and-cycles-65816 form mode))
       (set! total-cycles (+ total-cycles cyc))
       (unless (or (label-form? form)
                   (match form [`(assume-mode . ,_) #t] [`(byte . ,_) #t] [`(word . ,_) #t] [`(bytes . ,_) #t] [_ #f]))
         (set! inst-count (add1 inst-count)))
       (pass1 rest (+ pc sz))]))

  ;; Pass 2: Emit machine code bytes
  (define out-bytes
    (let pass2 ([items inst-modes]
                [pc origin]
                [acc '()])
      (match items
        ['() (list->bytes (reverse acc))]
        [(cons (cons form mode) rest)
         (define-values (sz _) (instruction-size-and-cycles-65816 form mode))
         (define bs (encode-instruction-65816 form mode pc labels))
         (pass2 rest (+ pc sz) (append (reverse bs) acc))])))

  (asm-65816-result out-bytes
                    (hash-copy labels)
                    total-cycles
                    inst-count
                    (mode-safety-result-mode-safe? safety)
                    (mode-safety-result-label-modes safety)
                    (mode-safety-result-conflicts safety)))

;; ============================================================================
;; 2. Sony SPC700 Audio Co-Processor Assembler & IPL ROM ($2140-$2143) Uploader
;; ============================================================================

(struct spc700-asm-result (bytes labels aram-origin instruction-count) #:transparent)

(define (spc-instruction-size inst)
  (cond
    [(label-form? inst) 0]
    [else
     (match inst
       [`(spc-mov-a-imm ,_)      2] ; #xE8 imm
       [`(spc-mov-x-imm ,_)      2] ; #xCD imm
       [`(spc-mov-y-imm ,_)      2] ; #x8D imm
       [`(spc-mov-dp-a ,_)       2] ; #xC4 dp
       [`(spc-mov-a-dp ,_)       2] ; #xE4 dp
       [`(spc-mov-dp-imm ,_ ,_)  3] ; #x8F imm dp
       [`(spc-dsp-write ,_ ,_)   6] ; MOV $F2, #reg (3B) + MOV $F3, #val (3B)
       [`(spc-cmp-a-imm ,_)      2] ; #x68 imm
       [`(spc-cmp-a-dp ,_)       2] ; #x64 dp
       [`(spc-inc-a)             1] ; #xBC
       [`(spc-dec-a)             1] ; #x9C
       [`(spc-bra ,_)            2] ; #x2F rel8
       [`(spc-beq ,_)            2] ; #xF0 rel8
       [`(spc-bne ,_)            2] ; #xD0 rel8
       [`(spc-ret)               1] ; #x6F
       [`(spc-nop)               1] ; #x00
       [`(byte ,bs ...)          (length bs)]
       [_ (error 'assemble-spc700 "Unknown SPC700 instruction: ~s" inst)])]))

(define (resolve-spc-branch opcode target pc labels)
  (define disp
    (cond
      [(integer? target) target]
      [(symbol? target)
       (define addr
         (hash-ref labels target
                   (lambda ()
                     (error 'assemble-spc700 "Undefined SPC700 label: ~a" target))))
       (- addr (+ pc 2))]
      [else (error 'assemble-spc700 "Invalid SPC700 branch target: ~s" target)]))
  (when (or (< disp -128) (> disp 127))
    (error 'assemble-spc700 "SPC700 branch displacement out of range: ~a" disp))
  (list opcode (bitwise-and disp #xFF)))

(define (encode-spc700-instruction inst pc labels)
  (cond
    [(label-form? inst) '()]
    [else
     (match inst
       [`(spc-mov-a-imm ,u8)      (list #xE8 (u8-byte u8))]
       [`(spc-mov-x-imm ,u8)      (list #xCD (u8-byte u8))]
       [`(spc-mov-y-imm ,u8)      (list #x8D (u8-byte u8))]
       [`(spc-mov-dp-a ,dp)       (list #xC4 (u8-byte dp))]
       [`(spc-mov-a-dp ,dp)       (list #xE4 (u8-byte dp))]
       [`(spc-mov-dp-imm ,dp ,u8) (list #x8F (u8-byte u8) (u8-byte dp))]
       [`(spc-dsp-write ,reg ,val)
        (list #x8F (u8-byte reg) #xF2
              #x8F (u8-byte val) #xF3)]
       [`(spc-cmp-a-imm ,u8)      (list #x68 (u8-byte u8))]
       [`(spc-cmp-a-dp ,dp)       (list #x64 (u8-byte dp))]
       [`(spc-inc-a)              (list #xBC)]
       [`(spc-dec-a)              (list #x9C)]
       [`(spc-bra ,offset)        (resolve-spc-branch #x2F offset pc labels)]
       [`(spc-beq ,offset)        (resolve-spc-branch #xF0 offset pc labels)]
       [`(spc-bne ,offset)        (resolve-spc-branch #xD0 offset pc labels)]
       [`(spc-ret)                (list #x6F)]
       [`(spc-nop)                (list #x00)]
       [`(byte ,bs ...)           (map u8-byte bs)]
       [_ (error 'encode-spc700-instruction "Unhandled SPC700 instruction: ~s" inst)])]))

;; Two-pass Sony SPC700 Assembler
(define (assemble-spc700 forms #:origin [origin #x0200])
  (define labels (make-hasheq))
  (define inst-count 0)
  (let pass1 ([rem forms] [pc origin])
    (match rem
      ['() (void)]
      [(cons f rest)
       (when (label-form? f)
         (hash-set! labels (extract-label-name f) pc))
       (define sz (spc-instruction-size f))
       (unless (or (label-form? f) (match f [`(byte . ,_) #t] [_ #f]))
         (set! inst-count (add1 inst-count)))
       (pass1 rest (+ pc sz))]))
  (define out-bytes
    (let pass2 ([rem forms] [pc origin] [acc '()])
      (match rem
        ['() (list->bytes (reverse acc))]
        [(cons f rest)
         (define sz (spc-instruction-size f))
         (define bs (encode-spc700-instruction f pc labels))
         (pass2 rest (+ pc sz) (append (reverse bs) acc))])))
  (spc700-asm-result out-bytes (hash-copy labels) origin inst-count))

;; Build the "Boba Is You" SPC700 S-DSP Chime Driver loaded at ARAM $0200
(define (build-boba-spc700-driver #:origin [origin #x0200])
  (define forms
    `(;; Initialize S-DSP master volume, echo, sample directory & Voice 0 chime
      (label spc_driver_entry)
      (spc-dsp-write #x6C #x20) ; FLG: clear mute/reset, disable echo writes
      (spc-dsp-write #x0C #x7F) ; MVOL_L = 127
      (spc-dsp-write #x1C #x7F) ; MVOL_R = 127
      (spc-dsp-write #x2C #x00) ; EVOL_L = 0
      (spc-dsp-write #x3C #x00) ; EVOL_R = 0
      (spc-dsp-write #x5D #x03) ; DIR = $0300 BRR sample directory
      (spc-dsp-write #x00 #x7F) ; V0 VOL_L = 127
      (spc-dsp-write #x01 #x7F) ; V0 VOL_R = 127
      (spc-dsp-write #x02 #x80) ; V0 PITCH_L = #x80
      (spc-dsp-write #x03 #x12) ; V0 PITCH_H = #x12 (Boba pentatonic chime)
      (spc-dsp-write #x04 #x00) ; V0 SRCN = 0
      (spc-dsp-write #x05 #xFF) ; V0 ADSR1 = #xFF
      (spc-dsp-write #x06 #xE0) ; V0 ADSR2 = #xE0
      (spc-dsp-write #x07 #x7F) ; V0 GAIN = #x7F
      (spc-dsp-write #x4C #x01) ; KON = #x01 (Key-On Voice 0!)
      (spc-mov-dp-imm #x10 #x5A) ; Mark ARAM $0010 = #x5A ("SPC driver alive")
      ;; Poll APUIO0 ($F4) for 5A22 sound effect commands and acknowledge on $F4
      (label spc_cmd_poll)
      (spc-mov-a-dp #xF4)
      (spc-beq spc_cmd_done)
      (spc-mov-dp-a #x11)        ; Record last command ID in ARAM $0011
      (spc-mov-dp-a #xF4)        ; Echo command back on APUIO0 ($F4)
      (spc-dsp-write #x4C #x01)  ; Re-trigger Voice 0 chime on command
      (label spc_cmd_done)
      (spc-ret)))
  (assemble-spc700 forms #:origin origin))

;; Emit 5A22-side 65C816 instructions to upload an SPC700 driver block to ARAM $0200
;; via the Sony IPL ROM ($2140-$2143) #xAA/#xBB handshake protocol.
;; Expects M=8, X=16 at entry and preserves M=8, X=16 at exit.
(define (emit-spc700-ipl-upload #:blob-label [blob-label 'spc_driver_blob]
                                #:blob-length [blob-length 64]
                                #:aram-dest [aram-dest #x0200])
  (define dest-lo (bitwise-and aram-dest #xFF))
  (define dest-hi (bitwise-and (arithmetic-shift aram-dest -8) #xFF))
  `((label spc700_ipl_upload)
    ;; 1. Wait for SPC700 IPL ROM ready signature: $2140 == #xAA and $2141 == #xBB
    (label spc_wait_ready)
    (lda-abs #x2140)
    (cmp-imm #xAA)
    (bne spc_wait_ready)
    (lda-abs #x2141)
    (cmp-imm #xBB)
    (bne spc_wait_ready)

    ;; 2. Write target ARAM destination address ($0200) to $2142/$2143
    (lda-imm ,dest-lo)
    (sta-abs #x2142)
    (lda-imm ,dest-hi)
    (sta-abs #x2143)

    ;; 3. Write non-zero command #x01 to $2141 and kick byte #xCC to $2140
    (lda-imm #x01)
    (sta-abs #x2141)
    (lda-imm #xCC)
    (sta-abs #x2140)
    (label spc_wait_kick)
    (lda-abs #x2140)
    (cmp-imm #xCC)
    (bne spc_wait_kick)

    ;; 4. Stream `blob-length` bytes to ARAM via $2141 (data) and $2140 (index)
    (ldx-imm #x0000)
    (label spc_upload_loop)
    (lda-abs-x ,blob-label)
    (sta-abs #x2141)
    (txa)
    (sta-abs #x2140)
    (label spc_wait_byte)
    (cmp-abs #x2140)
    (bne spc_wait_byte)
    (inx)
    (cpx-imm ,blob-length)
    (bne spc_upload_loop)

    ;; 5. Set execution entry address ($0200) in $2142/$2143, $2141 = #x00,
    ;;    and write (index + 2) to $2140 to launch the SPC700 driver!
    (lda-imm ,dest-lo)
    (sta-abs #x2142)
    (lda-imm ,dest-hi)
    (sta-abs #x2143)
    (stz-abs #x2141)
    (txa)
    (clc)
    (adc-imm #x02)
    (sta-abs #x2140)
    (rts)))

;; ============================================================================
;; 3. S-PPU 4bpp CHR, CGRAM 15-bit BGR555 Palette, General DMA ($4300) & HDMA ($4310)
;; ============================================================================

;; Pack 5-bit (0..31) R, G, B components into a 15-bit SNES BGR555 word
(define (bgr555-color r g b)
  (bitwise-ior (bitwise-and r #x1F)
               (arithmetic-shift (bitwise-and g #x1F) 5)
               (arithmetic-shift (bitwise-and b #x1F) 10)))

;; Pack a list of 15-bit BGR555 color words into little-endian CGRAM bytes
(define (pack-snes-cgram-palette colors)
  (list->bytes
   (append-map (lambda (c)
                 (list (bitwise-and c #xFF)
                       (bitwise-and (arithmetic-shift c -8) #x7F)))
               colors)))

;; Normalize an 8x8 tile input (either 8 rows of 8 4-bit integers or 64-element flat list)
(define (normalize-8x8-tile-rows tile)
  (cond
    [(and (list? tile) (= (length tile) 8) (andmap list? tile))
     tile]
    [(and (list? tile) (= (length tile) 64))
     (for/list ([r (in-range 8)])
       (take (drop tile (* r 8)) 8))]
    [else
     (error 'pack-snes-4bpp-tile
            "Expected 8 rows of 8 pixels (0..15) or 64-element list, got: ~s"
            tile)]))

;; Pack an 8x8 tile of 4-bit pixel indices (0..15) into a 32-byte S-PPU 4bpp planar tile:
;;   - Bytes  0..15: Bitplane 0 and Bitplane 1 interleaved by row (row 0..7)
;;   - Bytes 16..31: Bitplane 2 and Bitplane 3 interleaved by row (row 0..7)
(define (pack-snes-4bpp-tile tile)
  (define rows (normalize-8x8-tile-rows tile))
  (define out (make-bytes 32 0))
  (for ([row (in-list rows)]
        [y (in-range 8)])
    (define bp0 0)
    (define bp1 0)
    (define bp2 0)
    (define bp3 0)
    (for ([px (in-list row)]
          [x (in-range 8)])
      (define shift (- 7 x))
      (when (bitwise-bit-set? px 0) (set! bp0 (bitwise-ior bp0 (arithmetic-shift 1 shift))))
      (when (bitwise-bit-set? px 1) (set! bp1 (bitwise-ior bp1 (arithmetic-shift 1 shift))))
      (when (bitwise-bit-set? px 2) (set! bp2 (bitwise-ior bp2 (arithmetic-shift 1 shift))))
      (when (bitwise-bit-set? px 3) (set! bp3 (bitwise-ior bp3 (arithmetic-shift 1 shift)))))
    (bytes-set! out (* 2 y) bp0)
    (bytes-set! out (+ (* 2 y) 1) bp1)
    (bytes-set! out (+ 16 (* 2 y)) bp2)
    (bytes-set! out (+ 16 (* 2 y) 1) bp3))
  out)

;; Unpack a 32-byte S-PPU 4bpp planar tile back into 8 rows of 8 4-bit pixel indices (0..15)
(define (unpack-snes-4bpp-tile tile-bytes)
  (unless (and (bytes? tile-bytes) (= (bytes-length tile-bytes) 32))
    (error 'unpack-snes-4bpp-tile "Expected 32-byte 4bpp tile, got: ~s" tile-bytes))
  (for/list ([y (in-range 8)])
    (define bp0 (bytes-ref tile-bytes (* 2 y)))
    (define bp1 (bytes-ref tile-bytes (+ (* 2 y) 1)))
    (define bp2 (bytes-ref tile-bytes (+ 16 (* 2 y))))
    (define bp3 (bytes-ref tile-bytes (+ 16 (* 2 y) 1)))
    (for/list ([x (in-range 8)])
      (define shift (- 7 x))
      (bitwise-ior (if (bitwise-bit-set? bp0 shift) 1 0)
                   (if (bitwise-bit-set? bp1 shift) 2 0)
                   (if (bitwise-bit-set? bp2 shift) 4 0)
                   (if (bitwise-bit-set? bp3 shift) 8 0)))))

;; Build 16 custom 4bpp (16-color) tiles (512 bytes total) for "Boba Is You" SNES
(define (build-boba-snes-4bpp-tileset)
  (define tile-empty
    (make-list 8 (make-list 8 0)))
  (define tile-boba ; Rich 4bpp Boba Milk Tea cup with pearls (colors 1..9)
    '((0 0 0 6 6 0 0 0)
      (0 1 1 6 6 1 1 0)
      (0 1 2 3 3 2 1 0)
      (0 1 2 2 3 2 1 0)
      (0 1 4 2 4 2 1 0)
      (0 1 2 4 2 4 1 0)
      (0 0 1 4 4 1 0 0)
      (0 0 0 1 1 0 0 0)))
  (define tile-flag ; Golden victory flag (colors 1, 5, 6, 7)
    '((0 0 1 6 6 6 0 0)
      (0 0 1 6 7 6 6 0)
      (0 0 1 6 6 6 0 0)
      (0 0 1 5 0 0 0 0)
      (0 0 1 5 0 0 0 0)
      (0 0 1 5 0 0 0 0)
      (0 1 1 1 1 0 0 0)
      (0 0 0 0 0 0 0 0)))
  (define tile-rock ; Faceted boulder (colors 1, 8, 9, 10)
    '((0 0 1 1 1 1 0 0)
      (0 1 8 9 9 8 1 0)
      (1 8 9 10 9 8 8 1)
      (1 8 9 9 8 8 10 1)
      (1 8 8 8 8 10 8 1)
      (0 1 8 8 10 8 1 0)
      (0 0 1 1 1 1 0 0)
      (0 0 0 0 0 0 0 0)))
  (define tile-wall ; Brick wall (colors 1, 11, 12)
    '((1 1 1 1 1 1 1 1)
      (11 11 11 1 12 12 12 1)
      (11 11 11 1 12 12 12 1)
      (1 1 1 1 1 1 1 1)
      (12 1 11 11 11 1 12 12)
      (12 1 11 11 11 1 12 12)
      (1 1 1 1 1 1 1 1)
      (11 11 11 1 12 12 12 1)))
  (define tile-skull ; Hazard skull (colors 1, 13, 14)
    '((0 0 1 1 1 1 0 0)
      (0 1 13 13 13 13 1 0)
      (1 13 1 13 13 1 13 1)
      (1 13 13 14 14 13 13 1)
      (0 1 13 13 13 13 1 0)
      (0 0 1 13 1 13 0 0)
      (0 0 0 1 1 0 0 0)
      (0 0 0 0 0 0 0 0)))
  ;; Procedural 4bpp glyph generator for rule blocks (tiles 6..15)
  (define (make-rule-glyph accent-color seed)
    (for/list ([y (in-range 8)])
      (for/list ([x (in-range 8)])
        (cond
          [(or (= y 0) (= y 7) (= x 0) (= x 7)) 1]
          [(bitwise-bit-set? (+ (* y 3) x seed) 1) accent-color]
          [else 2]))))
  (define all-tiles
    (append (list tile-empty tile-boba tile-flag tile-rock tile-wall tile-skull)
            (for/list ([i (in-range 10)])
              (make-rule-glyph (+ 3 (modulo i 12)) (+ i 1)))))
  (apply bytes-append (map pack-snes-4bpp-tile all-tiles)))

;; Build 32-color (64-byte) 15-bit BGR555 CGRAM palette for BG1 and OBJ
(define (build-boba-snes-cgram-palette)
  (define bg-colors
    (list (bgr555-color  3  2  8) ;  0: Deep twilight sky backdrop
          (bgr555-color  2  2  4) ;  1: Outline ink
          (bgr555-color 28 24 18) ;  2: Creamy milk tea
          (bgr555-color 31 29 24) ;  3: Foam highlight
          (bgr555-color  8  4  3) ;  4: Tapioca boba pearl
          (bgr555-color 20 14  6) ;  5: Flagpole wood
          (bgr555-color 31 27  4) ;  6: Golden flag / straw
          (bgr555-color 31 31 18) ;  7: Bright gold shine
          (bgr555-color 14 15 18) ;  8: Slate rock base
          (bgr555-color 21 22 25) ;  9: Slate rock highlight
          (bgr555-color  9 10 12) ; 10: Slate rock shadow
          (bgr555-color 18  8  9) ; 11: Brick wall crimson
          (bgr555-color 24 13 14) ; 12: Brick wall highlight
          (bgr555-color 30  6  8) ; 13: Skull hazard red
          (bgr555-color 31 18 10) ; 14: Skull eye glow
          (bgr555-color 12 28 20))) ; 15: Victory emerald
  ;; Mirror palette to second 16-color bank (OBJ palette 0 at CGRAM $10..$1F)
  (pack-snes-cgram-palette (append bg-colors bg-colors)))

;; Build HBlank HDMA table for Channel 1 targeting $2122 (CGRAM backdrop color)
;; Format for 1-register write twice (mode #x02): [scanline-count lo-byte hi-byte] ... #x00
(define (build-snes-hdma-gradient-table)
  (define bands
    (list (cons 32 (bgr555-color  2  1  6)) ; Top night sky
          (cons 32 (bgr555-color  4  2 10)) ; Upper indigo
          (cons 32 (bgr555-color  7  4 14)) ; Royal twilight
          (cons 32 (bgr555-color 12  6 16)) ; Violet horizon
          (cons 32 (bgr555-color 18  9 15)) ; Bobaberry dusk
          (cons 32 (bgr555-color 24 13 12)) ; Sunset amber
          (cons 32 (bgr555-color 29 19 10)))) ; Golden glow (7 * 32 = 224 scanlines!)
  (list->bytes
   (append
    (append-map (lambda (band)
                  (define cnt (car band))
                  (define col (cdr band))
                  (list cnt
                        (bitwise-and col #xFF)
                        (bitwise-and (arithmetic-shift col -8) #x7F)))
                bands)
    (list #x00))))

;; Emit 65C816 instructions configuring General DMA Channel `ch` ($4300..$4306)
;; and triggering `$420B = (1 << ch)` during VBlank / ForcedBlank.
;; Expects M=8, X=16 at entry and preserves M=8, X=16 at exit.
(define (emit-snes-dma-transfer #:channel [ch 0]
                                #:dest [dest 'vram]
                                #:src-label [src-label 'chr_4bpp_tileset]
                                #:src-bank [src-bank #x00]
                                #:byte-count [byte-count 512]
                                #:dest-addr [dest-addr #x0000])
  (define ch-base (+ #x4300 (* ch #x10)))
  (define mdma-mask (arithmetic-shift 1 ch))
  (match dest
    ['cgram
     `(;; Configure CGRAM target address ($2121)
       (lda-imm ,(u8-byte dest-addr))
       (sta-abs #x2121)
       ;; DMA Channel 0: Mode #x00 (1-register write once) -> B-bus $2122 (CGDATA)
       (stz-abs ,ch-base)
       (lda-imm #x22)
       (sta-abs ,(+ ch-base 1))
       (ldx-imm ,src-label)
       (stx-abs ,(+ ch-base 2))
       (lda-imm ,src-bank)
       (sta-abs ,(+ ch-base 4))
       (ldx-imm ,byte-count)
       (stx-abs ,(+ ch-base 5))
       (lda-imm ,mdma-mask)
       (sta-abs #x420B))]
    ['vram
     `(;; Configure VRAM word address ($2115 = #x80 increment on high byte, $2116/$2117)
       (lda-imm #x80)
       (sta-abs #x2115)
       (ldx-imm ,dest-addr)
       (stx-abs #x2116)
       ;; DMA Channel 0: Mode #x01 (2-register write low/high) -> B-bus $2118/$2119 (VMDATAL/H)
       (lda-imm #x01)
       (sta-abs ,ch-base)
       (lda-imm #x18)
       (sta-abs ,(+ ch-base 1))
       (ldx-imm ,src-label)
       (stx-abs ,(+ ch-base 2))
       (lda-imm ,src-bank)
       (sta-abs ,(+ ch-base 4))
       (ldx-imm ,byte-count)
       (stx-abs ,(+ ch-base 5))
       (lda-imm ,mdma-mask)
       (sta-abs #x420B))]
    ['oam
     `(;; Configure OAM word address ($2102/$2103)
       (ldx-imm ,dest-addr)
       (stx-abs #x2102)
       ;; DMA Channel 0: Mode #x00 (1-register write once) -> B-bus $2104 (OAMDATA)
       (stz-abs ,ch-base)
       (lda-imm #x04)
       (sta-abs ,(+ ch-base 1))
       (ldx-imm ,src-label)
       (stx-abs ,(+ ch-base 2))
       (lda-imm ,src-bank)
       (sta-abs ,(+ ch-base 4))
       (ldx-imm ,byte-count)
       (stx-abs ,(+ ch-base 5))
       (lda-imm ,mdma-mask)
       (sta-abs #x420B))]
    [_ (error 'emit-snes-dma-transfer "Unknown DMA destination: ~s" dest)]))

;; Emit 65C816 instructions configuring HBlank HDMA Channel 1 ($4310..$4314)
;; targeting $2122 (CGRAM backdrop sky gradient) and enabling $420C = #x02.
;; Expects M=8, X=16 at entry and preserves M=8, X=16 at exit.
(define (emit-snes-hdma-gradient #:channel [ch 1]
                                 #:table-label [table-label 'hdma_sky_gradient_table]
                                 #:table-bank [table-bank #x00])
  (define ch-base (+ #x4300 (* ch #x10)))
  (define hdma-mask (arithmetic-shift 1 ch))
  `(;; Reset CGRAM address to 0 ($2121) for backdrop color
    (stz-abs #x2121)
    ;; HDMA Channel 1: Mode #x02 (write twice to single B-bus register $2122 CGDATA)
    (lda-imm #x02)
    (sta-abs ,ch-base)
    (lda-imm #x22)
    (sta-abs ,(+ ch-base 1))
    (ldx-imm ,table-label)
    (stx-abs ,(+ ch-base 2))
    (lda-imm ,table-bank)
    (sta-abs ,(+ ch-base 4))
    ;; Enable HDMA Channel 1 via $420C = #x02
    (lda-imm ,hdma-mask)
    (sta-abs #x420C)))

;; ============================================================================
;; 4. SNES LoROM (.sfc) Cartridge Linker & Full Boba SNES ROM Builder
;; ============================================================================

;; Compute 16-bit SNES LoROM Checksum and Complement Check (where checksum ^ complement = #xFFFF)
(define (compute-snes-lorom-checksum rom-bytes)
  (unless (= (bytes-length rom-bytes) 32768)
    (error 'compute-snes-lorom-checksum "Expected 32,768-byte LoROM image, got ~a bytes"
           (bytes-length rom-bytes)))
  ;; Sum all 32,768 bytes assuming $7FDC-$7FDD = #xFFFF (complement) and $7FDE-$7FDF = #x0000 (checksum)
  (define total-sum
    (for/fold ([acc 0]) ([i (in-range 32768)])
      (+ acc
         (cond
           [(or (= i #x7FDC) (= i #x7FDD)) #xFF]
           [(or (= i #x7FDE) (= i #x7FDF)) #x00]
           [else (bytes-ref rom-bytes i)]))))
  (define checksum (bitwise-and total-sum #xFFFF))
  (define complement (bitwise-xor checksum #xFFFF))
  (values checksum complement))

;; Link a 32,768-byte ($8000-$FFFF Bank $00) .sfc LoROM image with valid SNES header at $7FC0-$7FFF
(define (build-snes-lorom-image code-bytes
                                #:title [title "BOBA IS YOU SNES"]
                                #:reset-vector [reset-vec #x8000]
                                #:nmi-vector [nmi-vec #x8000]
                                #:irq-vector [irq-vec #x8000])
  (when (> (bytes-length code-bytes) #x7FC0)
    (error 'build-snes-lorom-image "Code size (~a B) exceeds LoROM Bank $00 header offset ($7FC0)"
           (bytes-length code-bytes)))
  (define rom (make-bytes 32768 0))
  (bytes-copy! rom 0 code-bytes 0 (bytes-length code-bytes))

  ;; 1. 21-byte space-padded ASCII Cartridge Title at $7FC0-$7FD4
  (define padded-title
    (let ([s (string-append title (make-string 21 #\space))])
      (substring s 0 21)))
  (for ([ch (in-string padded-title)]
        [i (in-range 21)])
    (bytes-set! rom (+ #x7FC0 i) (char->integer ch)))

  ;; 2. Map Mode ($7FD5 = #x30 FastROM LoROM), Cartridge Type ($7FD6 = #x00),
  ;;    ROM Size ($7FD7 = #x08 -> 32 KB), SRAM Size ($7FD8 = #x00),
  ;;    Region ($7FD9 = #x01 NTSC), Developer ID ($7FDA = #x33), Version ($7FDB = #x00)
  (bytes-set! rom #x7FD5 #x30)
  (bytes-set! rom #x7FD6 #x00)
  (bytes-set! rom #x7FD7 #x08)
  (bytes-set! rom #x7FD8 #x00)
  (bytes-set! rom #x7FD9 #x01)
  (bytes-set! rom #x7FDA #x33)
  (bytes-set! rom #x7FDB #x00)

  ;; Helper to write 16-bit little-endian word into ROM
  (define (set-u16! offset val)
    (bytes-set! rom offset (bitwise-and val #xFF))
    (bytes-set! rom (+ offset 1) (bitwise-and (arithmetic-shift val -8) #xFF)))

  ;; 3. 65C816 Native Mode Vectors ($7FE4-$7FEF)
  (set-u16! #x7FE4 irq-vec) ; Native COP
  (set-u16! #x7FE6 irq-vec) ; Native BRK
  (set-u16! #x7FE8 irq-vec) ; Native ABORT
  (set-u16! #x7FEA nmi-vec) ; Native NMI
  (set-u16! #x7FEC #x0000)  ; Reserved
  (set-u16! #x7FEE irq-vec) ; Native IRQ

  ;; 4. 6502 Emulation Mode Vectors ($7FF4-$7FFF)
  (set-u16! #x7FF4 irq-vec)   ; Emulation COP
  (set-u16! #x7FF6 #x0000)    ; Reserved
  (set-u16! #x7FF8 irq-vec)   ; Emulation ABORT
  (set-u16! #x7FFA nmi-vec)   ; Emulation NMI
  (set-u16! #x7FFC reset-vec) ; Emulation RESET
  (set-u16! #x7FFE irq-vec)   ; Emulation IRQ/BRK

  ;; 5. Compute and store Complement ($7FDC-$7FDD) and Checksum ($7FDE-$7FDF)
  (define-values (checksum complement)
    (compute-snes-lorom-checksum rom))
  (set-u16! #x7FDC complement)
  (set-u16! #x7FDE checksum)
  rom)

;; Build the complete 65C816 program for "Boba Is You" SNES 4-Stage Campaign
(define (build-boba-snes-65816-program #:spc-driver-bytes [spc-bytes (spc700-asm-result-bytes (build-boba-spc700-driver))]
                                       #:cgram-bytes [cgram-bytes (build-boba-snes-cgram-palette)]
                                       #:chr-4bpp-bytes [chr-bytes (build-boba-snes-4bpp-tileset)]
                                       #:hdma-bytes [hdma-bytes (build-snes-hdma-gradient-table)])
  ;; 64-word (128-byte) initial BG1 tilemap placing BOBA IS YOU, FLAG IS WIN, SKULL IS DEFEAT
  (define bg1-tilemap-bytes
    (list->bytes
     (append
      ;; Row 0..1: Rule banner tiles (6=TXT-BOBA, 7=TXT-IS, 8=TXT-YOU, 9=TXT-WIN, 4=WALL)
      (list 4 0 6 0 7 0 8 0  4 0 13 0 7 0 9 0
            1 0 0 0 2 0 3 0  5 0 10 0 11 0 12 0)
      (make-list 96 0))))
  ;; 32-byte initial stage board layout copied to WRAM $0400 via 65C816 MVN block move
  (define initial-board-bytes
    (bytes 4 4 4 4 4 4 4 4
           4 1 0 3 0 2 5 4
           4 6 7 8 0 13 7 9
           4 4 4 4 4 4 4 4))

  `((label reset_vector)
    (sei)
    ;; Switch 65C816 from 6502 Emulation Mode (E=1) to Native Mode (E=0)
    (clc)
    (xce)
    ;; Switch both Accumulator (M=16) and Index (X=16) to 16-bit width
    (rep #x30)
    (lda-imm #x1FFF)
    (tcs)
    (lda-imm #x0000)
    (tcd)

    ;; Hardware block move: copy 32-byte initial board from ROM to WRAM $0400 using MVN
    (lda-imm 31)
    (ldx-imm initial_board_rom)
    (ldy-imm #x0400)
    (mvn #x00 #x00)

    ;; Switch Accumulator to 8-bit (M=8) while keeping Index 16-bit (X=16)
    (sep #x20)
    (phk)
    (plb)

    ;; Enter S-PPU Forced Blank ($2100 = #x80) and disable NMI/DMA during setup
    (lda-imm #x80)
    (sta-abs #x2100)
    (stz-abs #x4200)
    (stz-abs #x420B)
    (stz-abs #x420C)

    ;; Configure S-PPU Mode 1 (BG1/BG2 4bpp), BG1 tilemap at VRAM $1000, CHR at VRAM $0000
    (lda-imm #x01)
    (sta-abs #x2105) ; BGMODE = Mode 1
    (sta-abs #x2101) ; OBSEL
    (lda-imm #x10)
    (sta-abs #x2107) ; BG1SC = $1000
    (stz-abs #x210B) ; BG12NBA = $0000
    (stz-abs #x210D) ; BG1HOFS = 0
    (stz-abs #x210D)
    (stz-abs #x210E) ; BG1VOFS = 0
    (stz-abs #x210E)
    (lda-imm #x11)
    (sta-abs #x212C) ; TM = BG1 + OBJ enabled on main screen

    ;; Upload SPC700 audio driver to ARAM $0200 over $2140-$2143 IPL handshake
    (jsr spc700_ipl_upload)

    ;; Upload 15-bit BGR555 CGRAM palette via DMA Channel 0
    ,@(emit-snes-dma-transfer #:channel 0
                              #:dest 'cgram
                              #:src-label 'cgram_palette_data
                              #:byte-count (bytes-length cgram-bytes)
                              #:dest-addr #x00)

    ;; Upload 4bpp CHR tileset to S-PPU VRAM $0000 via DMA Channel 0
    ,@(emit-snes-dma-transfer #:channel 0
                              #:dest 'vram
                              #:src-label 'chr_4bpp_tileset
                              #:byte-count (bytes-length chr-bytes)
                              #:dest-addr #x0000)

    ;; Upload BG1 tilemap to S-PPU VRAM $1000 via DMA Channel 0
    ,@(emit-snes-dma-transfer #:channel 0
                              #:dest 'vram
                              #:src-label 'bg1_tilemap_data
                              #:byte-count (bytes-length bg1-tilemap-bytes)
                              #:dest-addr #x1000)

    ;; Configure HBlank HDMA Channel 1 ($4310..$4314) sky gradient on $2122 and enable $420C = #x02
    ,@(emit-snes-hdma-gradient #:channel 1
                               #:table-label 'hdma_sky_gradient_table
                               #:table-bank #x00)

    ;; Initialize Direct Page campaign state ($10..$1D)
    (stz-dp ,DP-JOY-LO)
    (stz-dp ,DP-JOY-HI)
    (stz-dp ,DP-CUR-STAGE)    ; Stage 0
    (stz-dp ,DP-STAGE-STATUS) ; Status 0 = playing
    (lda-imm 2)
    (sta-dp ,DP-PLAYER-X)
    (lda-imm 4)
    (sta-dp ,DP-PLAYER-Y)
    (stz-dp ,DP-MOVE-COUNT)
    (stz-dp ,DP-RECOVERIES)
    (stz-dp ,DP-FRAME-COUNT)
    (stz-dp ,(+ DP-FRAME-COUNT 1))
    (stz-dp ,DP-SPC-CMD)
    (lda-imm #x1F)
    (sta-dp ,DP-RULE-MASK)
    (stz-dp ,DP-CAMPAIGN-WON)
    (stz-dp ,DP-STAGE-CLEARS)

    ;; Seed WRAM OAM shadow buffer ($0200..$020F) for Boba, Flag, Rock, Skull sprites
    (lda-imm 32)
    (sta-abs #x0200) ; Sprite 0 X (Boba)
    (lda-imm 64)
    (sta-abs #x0201) ; Sprite 0 Y (Boba)
    (lda-imm 1)
    (sta-abs #x0202) ; Sprite 0 Tile = OBJ-BOBA
    (stz-abs #x0203) ; Sprite 0 Attr
    (lda-imm 128)
    (sta-abs #x0204) ; Sprite 1 X (Flag)
    (lda-imm 64)
    (sta-abs #x0205) ; Sprite 1 Y (Flag)
    (lda-imm 2)
    (sta-abs #x0206) ; Sprite 1 Tile = OBJ-FLAG
    (stz-abs #x0207)

    ;; Upload initial OAM buffer ($0200, 16 bytes) via DMA Channel 0
    ,@(emit-snes-dma-transfer #:channel 0
                              #:dest 'oam
                              #:src-label #x0200
                              #:byte-count 16
                              #:dest-addr #x0000)

    ;; Exit Forced Blank ($2100 = #x0F full brightness) & enable NMI + Auto-Joypad ($4200 = #x81)
    (lda-imm #x0F)
    (sta-abs #x2100)
    (lda-imm #x81)
    (sta-abs #x4200)

    ;; Main idle loop synchronized to VBlank NMI via WAI
    (label main_loop)
    (wai)
    (bra main_loop)

    ;; ========================================================================
    ;; Subroutine: SPC700 IPL ROM Upload ($2140-$2143)
    ;; ========================================================================
    ,@(emit-spc700-ipl-upload #:blob-label 'spc_driver_blob
                              #:blob-length (bytes-length spc-bytes)
                              #:aram-dest #x0200)

    ;; ========================================================================
    ;; Native NMI Vector: VBlank DMA/HDMA Refresh & 4-Stage Campaign Engine
    ;; ========================================================================
    (entry-label nmi_vector #:m 8 #:x 16 #:e native)
    (sep #x20)
    (rep #x10)
    ;; Acknowledge NMI ($4210) and increment frame counter
    (lda-abs #x4210)
    (inc-dp ,DP-FRAME-COUNT)

    ;; Re-enable HDMA Channel 1 sky gradient ($420C = #x02)
    (lda-imm #x02)
    (sta-abs #x420C)

    ;; Read SNES Joypad 1 ($4218/$4219) into Direct Page
    (lda-abs #x4218)
    (sta-dp ,DP-JOY-LO)
    (lda-abs #x4219)
    (sta-dp ,DP-JOY-HI)

    ;; Check if campaign is already won (DP-STAGE-STATUS == 2)
    (lda-dp ,DP-STAGE-STATUS)
    (cmp-imm 2)
    (bne nmi_check_failed)
    (jmp nmi_update_oam)

    ;; Check if currently in Failure state (DP-STAGE-STATUS == 1)
    (label nmi_check_failed)
    (cmp-imm 1)
    (bne nmi_playing)

    ;; In Failure state: check for START button (#x10 in DP-JOY-HI) recovery!
    (lda-dp ,DP-JOY-HI)
    (and-imm #x10)
    (bne nmi_do_recover)
    (jmp nmi_update_oam)
    ;; START pressed -> recover Stage 1 cleanly!
    (label nmi_do_recover)
    (stz-dp ,DP-STAGE-STATUS)
    (inc-dp ,DP-RECOVERIES)
    (lda-imm 2)
    (sta-dp ,DP-PLAYER-X)
    (lda-imm 4)
    (sta-dp ,DP-PLAYER-Y)
    (lda-imm #x03)
    (sta-dp ,DP-SPC-CMD)
    (sta-abs #x2140)
    (jmp nmi_update_oam)

    ;; Active playing state (DP-STAGE-STATUS == 0)
    (label nmi_playing)
    ;; Check for hazard move (DOWN #x04 or B #x80 in DP-JOY-HI)
    (lda-dp ,DP-JOY-HI)
    (and-imm #x84)
    (beq nmi_check_advance)
    ;; Trigger Skull Defeat hazard in current stage!
    (inc-dp ,DP-MOVE-COUNT)
    (inc-dp ,DP-PLAYER-Y)
    (lda-imm 1)
    (sta-dp ,DP-STAGE-STATUS) ; 1 = failed
    (lda-imm #x02)
    (sta-dp ,DP-SPC-CMD)
    (sta-abs #x2140)
    (bra nmi_update_oam)

    ;; Check for stage-clearing move (RIGHT #x01 in DP-JOY-HI or A #x80 in DP-JOY-LO)
    (label nmi_check_advance)
    (lda-dp ,DP-JOY-HI)
    (and-imm #x01)
    (bne nmi_do_advance)
    (lda-dp ,DP-JOY-LO)
    (and-imm #x80)
    (beq nmi_update_oam)

    (label nmi_do_advance)
    (inc-dp ,DP-MOVE-COUNT)
    (inc-dp ,DP-PLAYER-X)
    (lda-dp ,DP-CUR-STAGE)
    (cmp-imm 0)
    (beq nmi_advance_from_0)
    (cmp-imm 1)
    (beq nmi_advance_from_1)
    (cmp-imm 2)
    (beq nmi_advance_from_2)

    ;; Stage 3 cleared -> Stage 3 Victory!
    (lda-imm 2)
    (sta-dp ,DP-STAGE-STATUS) ; 2 = victory
    (lda-imm 1)
    (sta-dp ,DP-CAMPAIGN-WON)
    (lda-imm #x0F)
    (sta-dp ,DP-STAGE-CLEARS)
    (lda-imm #x07)
    (sta-dp ,DP-SPC-CMD)
    (sta-abs #x2140)
    (bra nmi_update_oam)

    (label nmi_advance_from_0)
    (lda-imm 1)
    (sta-dp ,DP-CUR-STAGE)
    (lda-imm #x01)
    (sta-dp ,DP-STAGE-CLEARS)
    (lda-imm #x01)
    (sta-dp ,DP-SPC-CMD)
    (sta-abs #x2140)
    (bra nmi_update_oam)

    (label nmi_advance_from_1)
    (lda-imm 2)
    (sta-dp ,DP-CUR-STAGE)
    (lda-imm #x03)
    (sta-dp ,DP-STAGE-CLEARS)
    (lda-imm #x04)
    (sta-dp ,DP-SPC-CMD)
    (sta-abs #x2140)
    (bra nmi_update_oam)

    (label nmi_advance_from_2)
    (lda-imm 3)
    (sta-dp ,DP-CUR-STAGE)
    (lda-imm #x07)
    (sta-dp ,DP-STAGE-CLEARS)
    (lda-imm #x05)
    (sta-dp ,DP-SPC-CMD)
    (sta-abs #x2140)

    ;; Update OAM Sprite 0 (Boba player X/Y) and DMA0 transfer to S-PPU OAM ($2104)
    (label nmi_update_oam)
    (lda-dp ,DP-PLAYER-X)
    (asl-a)
    (asl-a)
    (asl-a)
    (sta-abs #x0200)
    (lda-dp ,DP-PLAYER-Y)
    (asl-a)
    (asl-a)
    (asl-a)
    (sta-abs #x0201)
    ,@(emit-snes-dma-transfer #:channel 0
                              #:dest 'oam
                              #:src-label #x0200
                              #:byte-count 16
                              #:dest-addr #x0000)
    (rti)

    ;; ========================================================================
    ;; Native/Emulation IRQ Vector
    ;; ========================================================================
    (entry-label irq_vector #:m 8 #:x 16 #:e native)
    (rti)

    ;; ========================================================================
    ;; Embedded ROM Data Tables (SPC700 Driver, CGRAM, 4bpp CHR, Tilemap, HDMA)
    ;; ========================================================================
    (label spc_driver_blob)
    (bytes ,spc-bytes)
    (label cgram_palette_data)
    (bytes ,cgram-bytes)
    (label chr_4bpp_tileset)
    (bytes ,chr-bytes)
    (label bg1_tilemap_data)
    (bytes ,bg1-tilemap-bytes)
    (label hdma_sky_gradient_table)
    (bytes ,hdma-bytes)
    (label initial_board_rom)
    (bytes ,initial-board-bytes)))

;; ============================================================================
;; 5. Headless SNES 65C816 + S-PPU + SPC700 VM & Campaign Verifier
;; ============================================================================

(struct snes-vm
  ([rom #:mutable]
   [wram #:mutable]          ; 128 KB WRAM ($7E0000-$7FFFFF, low 8 KB at $00:0000-$1FFF)
   [vram #:mutable]          ; 64 KB S-PPU VRAM
   [cgram #:mutable]         ; 512 B S-PPU CGRAM (256 x 15-bit BGR555 colors)
   [oam #:mutable]           ; 544 B S-PPU OAM
   [aram #:mutable]          ; 64 KB Sony SPC700 Audio RAM
   [dsp-regs #:mutable]      ; 128 B Sony S-DSP register file
   ;; 65C816 CPU registers
   [a #:mutable]             ; 16-bit Accumulator C (B:A)
   [x #:mutable]             ; 16-bit Index X
   [y #:mutable]             ; 16-bit Index Y
   [s #:mutable]             ; 16-bit Stack Pointer S
   [d #:mutable]             ; 16-bit Direct Page D
   [dbr #:mutable]           ; 8-bit Data Bank Register
   [pbr #:mutable]           ; 8-bit Program Bank Register
   [pc #:mutable]            ; 16-bit Program Counter
   [m-width #:mutable]       ; 8 or 16
   [x-width #:mutable]       ; 8 or 16
   [emulation? #:mutable]    ; #t (6502 emulation) or #f (65C816 native)
   [flag-c #:mutable]
   [flag-z #:mutable]
   [flag-n #:mutable]
   [flag-v #:mutable]
   [flag-i #:mutable]
   [waiting? #:mutable]
   [cycles #:mutable]
   ;; S-PPU & S-CPU DMA/HDMA state
   [inidisp #:mutable]       ; $2100
   [bgmode #:mutable]        ; $2105
   [tm #:mutable]            ; $212C
   [vmain #:mutable]         ; $2115
   [vmadd #:mutable]         ; $2116/$2117 (16-bit word address)
   [cgadd #:mutable]         ; $2121 (byte index 0..511 into cgram)
   [cg-flip #:mutable]       ; low/high byte toggle for $2122
   [oamadd #:mutable]        ; $2102/$2103
   [nmitimen #:mutable]      ; $4200
   [hdmaen #:mutable]        ; $420C
   [joypad1 #:mutable]       ; 16-bit controller 1 ($4218/$4219)
   [dma-regs #:mutable]      ; 128 bytes covering $4300..$437F
   [dma-transfers #:mutable] ; count of General DMA transfers executed
   [hdma-scanlines #:mutable] ; count of scanlines updated by HBlank HDMA
   [hdma-backdrop-log #:mutable] ; list of (scanline . bgr555) written by HDMA1
   ;; Sony SPC700 IPL & Co-Processor state
   [apu-ports-in #:mutable]  ; 4 bytes written by 5A22 to $2140..$2143
   [apu-ports-out #:mutable] ; 4 bytes visible to 5A22 on $2140..$2143
   [spc-ipl-state #:mutable] ; 'ready, 'transfer, or 'running
   [spc-aram-ptr #:mutable]  ; current ARAM write pointer during IPL upload
   [spc-uploaded-bytes #:mutable]
   [spc-pc #:mutable]
   [spc-a #:mutable]
   [spc-x #:mutable]
   [spc-y #:mutable]
   [spc-z #:mutable])
  #:transparent)

(struct snes-verification-report
  (header-valid?
   title
   map-mode
   rom-size-bytes
   checksum
   complement
   checksum-xor-ffff?
   checksum-matches-sum?
   native-mode-switched?
   reg-16bit-configured?
   spc700-handshake-ok?
   spc700-uploaded-bytes
   spc700-dsp-kon
   cgram-dma-bytes
   vram-4bpp-dma-bytes
   hdma-enabled-mask
   hdma-scanlines-updated
   oam-dma-transfers
   campaign-trace
   campaign-victory?)
  #:transparent)

(define (make-snes-vm-from-rom rom-bytes)
  (define vm
    (snes-vm (bytes-copy rom-bytes)
             (make-bytes (* 128 1024) 0)
             (make-bytes (* 64 1024) 0)
             (make-bytes 512 0)
             (make-bytes 544 0)
             (make-bytes (* 64 1024) 0)
             (make-bytes 128 0)
             0 0 0 #x01FF 0 0 0 #x8000
             8 8 #t #f #f #f #f #t #f 0
             #x80 0 0 #x80 0 0 #f 0 0 0 0
             (make-bytes 128 0)
             0 0 '()
             (bytes 0 0 0 0)
             (bytes #xAA #xBB 0 0) ; SPC700 IPL boot signature #xAA / #xBB!
             'ready #x0200 0 #xFFC0 0 0 0 #f))
  (snes-reset! vm)
  vm)

(define (snes-reset! vm)
  (define rom (snes-vm-rom vm))
  (define reset-lo (bytes-ref rom #x7FFC))
  (define reset-hi (bytes-ref rom #x7FFD))
  (set-snes-vm-pc! vm (bitwise-ior reset-lo (arithmetic-shift reset-hi 8)))
  (set-snes-vm-m-width! vm 8)
  (set-snes-vm-x-width! vm 8)
  (set-snes-vm-emulation?! vm #t)
  (set-snes-vm-s! vm #x01FF)
  (set-snes-vm-d! vm #x0000)
  (set-snes-vm-waiting?! vm #f)
  (bytes-set! (snes-vm-apu-ports-out vm) 0 #xAA)
  (bytes-set! (snes-vm-apu-ports-out vm) 1 #xBB)
  (set-snes-vm-spc-ipl-state! vm 'ready)
  (set-snes-vm-spc-uploaded-bytes! vm 0)
  vm)

(define (snes-set-joypad1! vm mask)
  (set-snes-vm-joypad1! vm (bitwise-and mask #xFFFF)))

;; Execute SPC700 machine code at `spc-pc` in ARAM until `RET` (#x6F)
(define (run-spc700-driver! vm [max-steps 64])
  (define aram (snes-vm-aram vm))
  (define dsp (snes-vm-dsp-regs vm))
  (let loop ([steps 0])
    (when (< steps max-steps)
      (define pc (snes-vm-spc-pc vm))
      (define op (bytes-ref aram (bitwise-and pc #xFFFF)))
      (match op
        [#xE8 ; MOV A, #imm
         (define v (bytes-ref aram (bitwise-and (+ pc 1) #xFFFF)))
         (set-snes-vm-spc-a! vm v)
         (set-snes-vm-spc-z! vm (zero? v))
         (set-snes-vm-spc-pc! vm (+ pc 2))
         (loop (add1 steps))]
        [#xCD ; MOV X, #imm
         (define v (bytes-ref aram (bitwise-and (+ pc 1) #xFFFF)))
         (set-snes-vm-spc-x! vm v)
         (set-snes-vm-spc-z! vm (zero? v))
         (set-snes-vm-spc-pc! vm (+ pc 2))
         (loop (add1 steps))]
        [#x8D ; MOV Y, #imm
         (define v (bytes-ref aram (bitwise-and (+ pc 1) #xFFFF)))
         (set-snes-vm-spc-y! vm v)
         (set-snes-vm-spc-z! vm (zero? v))
         (set-snes-vm-spc-pc! vm (+ pc 2))
         (loop (add1 steps))]
        [#x8F ; MOV dp, #imm (encoding: #x8F imm dp)
         (define imm (bytes-ref aram (bitwise-and (+ pc 1) #xFFFF)))
         (define dp  (bytes-ref aram (bitwise-and (+ pc 2) #xFFFF)))
         (bytes-set! aram dp imm)
         (when (= dp #xF3)
           (define reg-idx (bitwise-and (bytes-ref aram #xF2) #x7F))
           (bytes-set! dsp reg-idx imm))
         (when (and (>= dp #xF4) (<= dp #xF7))
           (bytes-set! (snes-vm-apu-ports-out vm) (- dp #xF4) imm))
         (set-snes-vm-spc-pc! vm (+ pc 3))
         (loop (add1 steps))]
        [#xC4 ; MOV dp, A
         (define dp (bytes-ref aram (bitwise-and (+ pc 1) #xFFFF)))
         (define a  (snes-vm-spc-a vm))
         (bytes-set! aram dp a)
         (when (= dp #xF3)
           (define reg-idx (bitwise-and (bytes-ref aram #xF2) #x7F))
           (bytes-set! dsp reg-idx a))
         (when (and (>= dp #xF4) (<= dp #xF7))
           (bytes-set! (snes-vm-apu-ports-out vm) (- dp #xF4) a))
         (set-snes-vm-spc-pc! vm (+ pc 2))
         (loop (add1 steps))]
        [#xE4 ; MOV A, dp
         (define dp (bytes-ref aram (bitwise-and (+ pc 1) #xFFFF)))
         (define v
           (if (and (>= dp #xF4) (<= dp #xF7))
               (bytes-ref (snes-vm-apu-ports-in vm) (- dp #xF4))
               (bytes-ref aram dp)))
         (set-snes-vm-spc-a! vm v)
         (set-snes-vm-spc-z! vm (zero? v))
         (set-snes-vm-spc-pc! vm (+ pc 2))
         (loop (add1 steps))]
        [#x68 ; CMP A, #imm
         (define imm (bytes-ref aram (bitwise-and (+ pc 1) #xFFFF)))
         (set-snes-vm-spc-z! vm (= (snes-vm-spc-a vm) imm))
         (set-snes-vm-spc-pc! vm (+ pc 2))
         (loop (add1 steps))]
        [#xBC ; INC A
         (define v (bitwise-and (add1 (snes-vm-spc-a vm)) #xFF))
         (set-snes-vm-spc-a! vm v)
         (set-snes-vm-spc-z! vm (zero? v))
         (set-snes-vm-spc-pc! vm (+ pc 1))
         (loop (add1 steps))]
        [#x9C ; DEC A
         (define v (bitwise-and (sub1 (snes-vm-spc-a vm)) #xFF))
         (set-snes-vm-spc-a! vm v)
         (set-snes-vm-spc-z! vm (zero? v))
         (set-snes-vm-spc-pc! vm (+ pc 1))
         (loop (add1 steps))]
        [#x2F ; BRA rel8
         (define rel (bytes-ref aram (bitwise-and (+ pc 1) #xFFFF)))
         (define disp (if (>= rel 128) (- rel 256) rel))
         (set-snes-vm-spc-pc! vm (+ pc 2 disp))
         (loop (add1 steps))]
        [#xF0 ; BEQ rel8
         (define rel (bytes-ref aram (bitwise-and (+ pc 1) #xFFFF)))
         (define disp (if (>= rel 128) (- rel 256) rel))
         (set-snes-vm-spc-pc! vm (if (snes-vm-spc-z vm) (+ pc 2 disp) (+ pc 2)))
         (loop (add1 steps))]
        [#xD0 ; BNE rel8
         (define rel (bytes-ref aram (bitwise-and (+ pc 1) #xFFFF)))
         (define disp (if (>= rel 128) (- rel 256) rel))
         (set-snes-vm-spc-pc! vm (if (not (snes-vm-spc-z vm)) (+ pc 2 disp) (+ pc 2)))
         (loop (add1 steps))]
        [#x00 ; NOP
         (set-snes-vm-spc-pc! vm (+ pc 1))
         (loop (add1 steps))]
        [#x6F ; RET
         (void)]
        [_ (void)]))))

;; Handle 5A22 writes to $2140..$2143 (Sony SPC700 IPL ROM & running driver)
(define (snes-apu-write! vm port val)
  (define in-ports (snes-vm-apu-ports-in vm))
  (define out-ports (snes-vm-apu-ports-out vm))
  (bytes-set! in-ports port (bitwise-and val #xFF))
  (when (= port 0)
    (match (snes-vm-spc-ipl-state vm)
      ['ready
       (when (= val #xCC)
         (define dest (bitwise-ior (bytes-ref in-ports 2)
                                   (arithmetic-shift (bytes-ref in-ports 3) 8)))
         (set-snes-vm-spc-aram-ptr! vm dest)
         (set-snes-vm-spc-ipl-state! vm 'transfer)
         (bytes-set! out-ports 0 #xCC))]
      ['transfer
       (define data-byte (bytes-ref in-ports 1))
       (define expected-idx (bitwise-and (snes-vm-spc-uploaded-bytes vm) #xFF))
       (cond
         [(= (bitwise-and val #xFF) expected-idx)
          ;; Store data byte from $2141 into ARAM and echo index on $2140
          (define ptr (snes-vm-spc-aram-ptr vm))
          (bytes-set! (snes-vm-aram vm) (bitwise-and ptr #xFFFF) data-byte)
          (set-snes-vm-spc-aram-ptr! vm (add1 ptr))
          (set-snes-vm-spc-uploaded-bytes! vm (add1 (snes-vm-spc-uploaded-bytes vm)))
          (bytes-set! out-ports 0 (bitwise-and val #xFF))]
         [else
          ;; Non-sequential index kick with $2141 == 0 -> execute at $2142/$2143!
          (define entry (bitwise-ior (bytes-ref in-ports 2)
                                     (arithmetic-shift (bytes-ref in-ports 3) 8)))
          (bytes-set! out-ports 0 (bitwise-and val #xFF))
          (set-snes-vm-spc-ipl-state! vm 'running)
          (set-snes-vm-spc-pc! vm entry)
          (bytes-set! in-ports 0 0)
          (run-spc700-driver! vm)])]
      ['running
       ;; Re-run SPC700 driver entry at $0200 to process new command byte in $F4
       (set-snes-vm-spc-pc! vm #x0200)
       (run-spc700-driver! vm)])))

;; Read 1 byte from 24-bit SNES bus address
(define (snes-bus-read8 vm bank addr16)
  (define b (bitwise-and bank #xFF))
  (define a (bitwise-and addr16 #xFFFF))
  (cond
    [(or (= b #x7E) (= b #x7F))
     (define wram-idx (+ (if (= b #x7F) 65536 0) a))
     (bytes-ref (snes-vm-wram vm) wram-idx)]
    [(< a #x2000)
     (bytes-ref (snes-vm-wram vm) a)]
    [(>= a #x8000)
     (bytes-ref (snes-vm-rom vm) (- a #x8000))]
    [(and (>= a #x2140) (<= a #x2143))
     (bytes-ref (snes-vm-apu-ports-out vm) (- a #x2140))]
    [(= a #x4210) #x82] ; RDNMI
    [(= a #x4212) #x00] ; HVBJOY
    [(= a #x4218) (bitwise-and (snes-vm-joypad1 vm) #xFF)]
    [(= a #x4219) (bitwise-and (arithmetic-shift (snes-vm-joypad1 vm) -8) #xFF)]
    [(and (>= a #x4300) (<= a #x437F))
     (bytes-ref (snes-vm-dma-regs vm) (- a #x4300))]
    [else 0]))

;; Write 1 byte to S-PPU B-bus register ($2100..$213F)
(define (snes-ppu-write8! vm reg val)
  (define v (bitwise-and val #xFF))
  (match reg
    [#x2100 (set-snes-vm-inidisp! vm v)]
    [#x2102 (set-snes-vm-oamadd! vm (bitwise-ior (bitwise-and (snes-vm-oamadd vm) #xFF00) v))]
    [#x2103 (set-snes-vm-oamadd! vm (bitwise-ior (bitwise-and (snes-vm-oamadd vm) #x00FF)
                                                 (arithmetic-shift v 8)))]
    [#x2104
     (define idx (modulo (snes-vm-oamadd vm) 544))
     (bytes-set! (snes-vm-oam vm) idx v)
     (set-snes-vm-oamadd! vm (add1 idx))]
    [#x2105 (set-snes-vm-bgmode! vm v)]
    [#x2115 (set-snes-vm-vmain! vm v)]
    [#x2116 (set-snes-vm-vmadd! vm (bitwise-ior (bitwise-and (snes-vm-vmadd vm) #xFF00) v))]
    [#x2117 (set-snes-vm-vmadd! vm (bitwise-ior (bitwise-and (snes-vm-vmadd vm) #x00FF)
                                                (arithmetic-shift v 8)))]
    [#x2118
     (define byte-addr (bitwise-and (* 2 (snes-vm-vmadd vm)) #xFFFE))
     (bytes-set! (snes-vm-vram vm) byte-addr v)
     (when (zero? (bitwise-and (snes-vm-vmain vm) #x80))
       (set-snes-vm-vmadd! vm (bitwise-and (add1 (snes-vm-vmadd vm)) #x7FFF)))]
    [#x2119
     (define byte-addr (bitwise-and (+ (* 2 (snes-vm-vmadd vm)) 1) #xFFFF))
     (bytes-set! (snes-vm-vram vm) byte-addr v)
     (unless (zero? (bitwise-and (snes-vm-vmain vm) #x80))
       (set-snes-vm-vmadd! vm (bitwise-and (add1 (snes-vm-vmadd vm)) #x7FFF)))]
    [#x2121
     (set-snes-vm-cgadd! vm (* 2 v))
     (set-snes-vm-cg-flip! vm #f)]
    [#x2122
     (define idx (modulo (snes-vm-cgadd vm) 512))
     (bytes-set! (snes-vm-cgram vm) idx v)
     (set-snes-vm-cgadd! vm (add1 idx))]
    [#x212C (set-snes-vm-tm! vm v)]
    [_ (void)]))

;; Execute General DMA channels enabled by write to $420B (MDMAEN)
(define (snes-execute-mdma! vm mask)
  (define dma (snes-vm-dma-regs vm))
  (for ([ch (in-range 8)])
    (when (bitwise-bit-set? mask ch)
      (define base (* ch #x10))
      (define dmap (bytes-ref dma (+ base 0)))
      (define bbad (+ #x2100 (bytes-ref dma (+ base 1))))
      (define src-addr (bitwise-ior (bytes-ref dma (+ base 2))
                                    (arithmetic-shift (bytes-ref dma (+ base 3)) 8)))
      (define src-bank (bytes-ref dma (+ base 4)))
      (define raw-cnt  (bitwise-ior (bytes-ref dma (+ base 5))
                                    (arithmetic-shift (bytes-ref dma (+ base 6)) 8)))
      (define cnt (if (zero? raw-cnt) 65536 raw-cnt))
      (define mode (bitwise-and dmap #x07))
      (for ([i (in-range cnt)])
        (define b (snes-bus-read8 vm src-bank (+ src-addr i)))
        (match mode
          [0 (snes-ppu-write8! vm bbad b)]
          [1 (snes-ppu-write8! vm (+ bbad (bitwise-and i 1)) b)]
          [2 (snes-ppu-write8! vm bbad b)]
          [_ (snes-ppu-write8! vm bbad b)]))
      (set-snes-vm-dma-transfers! vm (add1 (snes-vm-dma-transfers vm))))))

;; Simulate 224 visible scanlines of HBlank HDMA transfers for active $420C channels
(define (snes-execute-frame-hdma! vm)
  (define mask (snes-vm-hdmaen vm))
  (define dma (snes-vm-dma-regs vm))
  (for ([ch (in-range 8)])
    (when (bitwise-bit-set? mask ch)
      (define base (* ch #x10))
      (define bbad (+ #x2100 (bytes-ref dma (+ base 1))))
      (define tbl-addr (bitwise-ior (bytes-ref dma (+ base 2))
                                    (arithmetic-shift (bytes-ref dma (+ base 3)) 8)))
      (define tbl-bank (bytes-ref dma (+ base 4)))
      (let loop ([ptr tbl-addr] [scanline 0])
        (when (< scanline 224)
          (define hdr (snes-bus-read8 vm tbl-bank ptr))
          (unless (zero? hdr)
            (define lines (bitwise-and hdr #x7F))
            (define lo (snes-bus-read8 vm tbl-bank (+ ptr 1)))
            (define hi (snes-bus-read8 vm tbl-bank (+ ptr 2)))
            (define col (bitwise-ior lo (arithmetic-shift hi 8)))
            (when (= bbad #x2122)
              (snes-ppu-write8! vm #x2121 0))
            (snes-ppu-write8! vm bbad lo)
            (snes-ppu-write8! vm bbad hi)
            (set-snes-vm-hdma-scanlines! vm (+ (snes-vm-hdma-scanlines vm) lines))
            (set-snes-vm-hdma-backdrop-log!
             vm
             (append (snes-vm-hdma-backdrop-log vm)
                     (list (cons scanline col))))
            (loop (+ ptr 3) (+ scanline lines))))))))

;; Write 1 byte to 24-bit SNES bus address
(define (snes-bus-write8! vm bank addr16 val)
  (define b (bitwise-and bank #xFF))
  (define a (bitwise-and addr16 #xFFFF))
  (define v (bitwise-and val #xFF))
  (cond
    [(or (= b #x7E) (= b #x7F))
     (define wram-idx (+ (if (= b #x7F) 65536 0) a))
     (bytes-set! (snes-vm-wram vm) wram-idx v)]
    [(< a #x2000)
     (bytes-set! (snes-vm-wram vm) a v)]
    [(and (>= a #x2100) (<= a #x213F))
     (snes-ppu-write8! vm a v)]
    [(and (>= a #x2140) (<= a #x2143))
     (snes-apu-write! vm (- a #x2140) v)]
    [(= a #x4200) (set-snes-vm-nmitimen! vm v)]
    [(= a #x420B) (snes-execute-mdma! vm v)]
    [(= a #x420C)
     (set-snes-vm-hdmaen! vm v)
     (when (and (> v 0) (null? (snes-vm-hdma-backdrop-log vm)))
       (snes-execute-frame-hdma! vm))]
    [(and (>= a #x4300) (<= a #x437F))
     (bytes-ref (snes-vm-dma-regs vm) (- a #x4300))
     (bytes-set! (snes-vm-dma-regs vm) (- a #x4300) v)]
    [else (void)]))

(define (snes-bus-read16 vm bank addr16)
  (bitwise-ior (snes-bus-read8 vm bank addr16)
               (arithmetic-shift (snes-bus-read8 vm bank (+ addr16 1)) 8)))

(define (snes-bus-write16! vm bank addr16 val16)
  (snes-bus-write8! vm bank addr16 (bitwise-and val16 #xFF))
  (snes-bus-write8! vm bank (+ addr16 1) (bitwise-and (arithmetic-shift val16 -8) #xFF)))

(define (update-nz-flags! vm val width-bits)
  (define mask (if (= width-bits 16) #xFFFF #xFF))
  (define msb  (if (= width-bits 16) 15 7))
  (define v    (bitwise-and val mask))
  (set-snes-vm-flag-z! vm (zero? v))
  (set-snes-vm-flag-n! vm (bitwise-bit-set? v msb)))

(define (set-accum! vm val)
  (if (= (snes-vm-m-width vm) 16)
      (let ([v (bitwise-and val #xFFFF)])
        (set-snes-vm-a! vm v)
        (update-nz-flags! vm v 16))
      (let ([lo (bitwise-and val #xFF)]
            [hi (bitwise-and (snes-vm-a vm) #xFF00)])
        (set-snes-vm-a! vm (bitwise-ior hi lo))
        (update-nz-flags! vm lo 8))))

(define (get-accum vm)
  (if (= (snes-vm-m-width vm) 16)
      (bitwise-and (snes-vm-a vm) #xFFFF)
      (bitwise-and (snes-vm-a vm) #xFF)))

(define (set-index-x! vm val)
  (define w (snes-vm-x-width vm))
  (define v (bitwise-and val (if (= w 16) #xFFFF #xFF)))
  (set-snes-vm-x! vm v)
  (update-nz-flags! vm v w))

(define (set-index-y! vm val)
  (define w (snes-vm-x-width vm))
  (define v (bitwise-and val (if (= w 16) #xFFFF #xFF)))
  (set-snes-vm-y! vm v)
  (update-nz-flags! vm v w))

(define (push8! vm val)
  (define s (snes-vm-s vm))
  (snes-bus-write8! vm 0 s val)
  (set-snes-vm-s! vm (bitwise-and (sub1 s) #xFFFF)))

(define (pull8! vm)
  (define s (bitwise-and (add1 (snes-vm-s vm)) #xFFFF))
  (set-snes-vm-s! vm s)
  (snes-bus-read8 vm 0 s))

(define (push16! vm val16)
  (push8! vm (bitwise-and (arithmetic-shift val16 -8) #xFF))
  (push8! vm (bitwise-and val16 #xFF)))

(define (pull16! vm)
  (define lo (pull8! vm))
  (define hi (pull8! vm))
  (bitwise-ior lo (arithmetic-shift hi 8)))

;; Step a single WDC 65C816 instruction on `vm`
(define (snes-step-instruction! vm)
  (define pbr (snes-vm-pbr vm))
  (define dbr (snes-vm-dbr vm))
  (define pc  (snes-vm-pc vm))
  (define dp  (snes-vm-d vm))
  (define m-w (snes-vm-m-width vm))
  (define x-w (snes-vm-x-width vm))
  (define op  (snes-bus-read8 vm pbr pc))

  (define (fetch-imm w)
    (if (= w 16)
        (let ([v (snes-bus-read16 vm pbr (+ pc 1))])
          (set-snes-vm-pc! vm (+ pc 3))
          v)
        (let ([v (snes-bus-read8 vm pbr (+ pc 1))])
          (set-snes-vm-pc! vm (+ pc 2))
          v)))

  (define (branch-if! cond?)
    (define rel (snes-bus-read8 vm pbr (+ pc 1)))
    (define disp (if (>= rel 128) (- rel 256) rel))
    (set-snes-vm-pc! vm (if cond? (+ pc 2 disp) (+ pc 2))))

  (set-snes-vm-cycles! vm (+ (snes-vm-cycles vm) 2))
  (match op
    [#x78 (set-snes-vm-flag-i! vm #t) (set-snes-vm-pc! vm (+ pc 1))] ; SEI
    [#x58 (set-snes-vm-flag-i! vm #f) (set-snes-vm-pc! vm (+ pc 1))] ; CLI
    [#x18 (set-snes-vm-flag-c! vm #f) (set-snes-vm-pc! vm (+ pc 1))] ; CLC
    [#x38 (set-snes-vm-flag-c! vm #t) (set-snes-vm-pc! vm (+ pc 1))] ; SEC
    [#xFB ; XCE (Exchange Carry and Emulation bit)
     (define old-c (snes-vm-flag-c vm))
     (define old-e (snes-vm-emulation? vm))
     (set-snes-vm-flag-c! vm old-e)
     (set-snes-vm-emulation?! vm old-c)
     (when old-c
       (set-snes-vm-m-width! vm 8)
       (set-snes-vm-x-width! vm 8))
     (set-snes-vm-pc! vm (+ pc 1))]
    [#xC2 ; REP #mask
     (define mask (snes-bus-read8 vm pbr (+ pc 1)))
     (unless (snes-vm-emulation? vm)
       (when (bitwise-bit-set? mask 5) (set-snes-vm-m-width! vm 16))
       (when (bitwise-bit-set? mask 4) (set-snes-vm-x-width! vm 16)))
     (when (bitwise-bit-set? mask 0) (set-snes-vm-flag-c! vm #f))
     (when (bitwise-bit-set? mask 1) (set-snes-vm-flag-z! vm #f))
     (set-snes-vm-pc! vm (+ pc 2))]
    [#xE2 ; SEP #mask
     (define mask (snes-bus-read8 vm pbr (+ pc 1)))
     (when (bitwise-bit-set? mask 5) (set-snes-vm-m-width! vm 8))
     (when (bitwise-bit-set? mask 4)
       (set-snes-vm-x-width! vm 8)
       (set-snes-vm-x! vm (bitwise-and (snes-vm-x vm) #xFF))
       (set-snes-vm-y! vm (bitwise-and (snes-vm-y vm) #xFF)))
     (when (bitwise-bit-set? mask 0) (set-snes-vm-flag-c! vm #t))
     (when (bitwise-bit-set? mask 1) (set-snes-vm-flag-z! vm #t))
     (set-snes-vm-pc! vm (+ pc 2))]

    ;; Transfers
    [#x1B ; TCS
     (set-snes-vm-s! vm (bitwise-and (snes-vm-a vm) #xFFFF))
     (set-snes-vm-pc! vm (+ pc 1))]
    [#x3B ; TSC
     (set-snes-vm-a! vm (snes-vm-s vm))
     (update-nz-flags! vm (snes-vm-s vm) 16)
     (set-snes-vm-pc! vm (+ pc 1))]
    [#x5B ; TCD
     (set-snes-vm-d! vm (bitwise-and (snes-vm-a vm) #xFFFF))
     (update-nz-flags! vm (snes-vm-d vm) 16)
     (set-snes-vm-pc! vm (+ pc 1))]
    [#x7B ; TDC
     (set-snes-vm-a! vm (snes-vm-d vm))
     (update-nz-flags! vm (snes-vm-d vm) 16)
     (set-snes-vm-pc! vm (+ pc 1))]
    [#xAA (set-index-x! vm (snes-vm-a vm)) (set-snes-vm-pc! vm (+ pc 1))] ; TAX
    [#x8A (set-accum! vm (snes-vm-x vm))   (set-snes-vm-pc! vm (+ pc 1))] ; TXA
    [#xA8 (set-index-y! vm (snes-vm-a vm)) (set-snes-vm-pc! vm (+ pc 1))] ; TAY
    [#x98 (set-accum! vm (snes-vm-y vm))   (set-snes-vm-pc! vm (+ pc 1))] ; TYA
    [#x9B (set-index-y! vm (snes-vm-x vm)) (set-snes-vm-pc! vm (+ pc 1))] ; TXY
    [#xBB (set-index-x! vm (snes-vm-y vm)) (set-snes-vm-pc! vm (+ pc 1))] ; TYX
    [#xEB ; XBA
     (define a16 (snes-vm-a vm))
     (define swapped (bitwise-ior (arithmetic-shift (bitwise-and a16 #xFF) 8)
                                  (bitwise-and (arithmetic-shift a16 -8) #xFF)))
     (set-snes-vm-a! vm swapped)
     (update-nz-flags! vm (bitwise-and swapped #xFF) 8)
     (set-snes-vm-pc! vm (+ pc 1))]

    ;; Stack
    [#x4B (push8! vm pbr) (set-snes-vm-pc! vm (+ pc 1))] ; PHK
    [#x8B (push8! vm dbr) (set-snes-vm-pc! vm (+ pc 1))] ; PHB
    [#xAB ; PLB
     (define b (pull8! vm))
     (set-snes-vm-dbr! vm b)
     (update-nz-flags! vm b 8)
     (set-snes-vm-pc! vm (+ pc 1))]
    [#x48 ; PHA
     (if (= m-w 16) (push16! vm (snes-vm-a vm)) (push8! vm (get-accum vm)))
     (set-snes-vm-pc! vm (+ pc 1))]
    [#x68 ; PLA
     (set-accum! vm (if (= m-w 16) (pull16! vm) (pull8! vm)))
     (set-snes-vm-pc! vm (+ pc 1))]

    ;; Immediate loads
    [#xA9 (set-accum! vm (fetch-imm m-w))]   ; LDA #imm
    [#xA2 (set-index-x! vm (fetch-imm x-w))] ; LDX #imm
    [#xA0 (set-index-y! vm (fetch-imm x-w))] ; LDY #imm

    ;; Direct Page loads/stores
    [#xA5 ; LDA dp
     (define off (snes-bus-read8 vm pbr (+ pc 1)))
     (define v (if (= m-w 16)
                   (snes-bus-read16 vm 0 (+ dp off))
                   (snes-bus-read8 vm 0 (+ dp off))))
     (set-accum! vm v)
     (set-snes-vm-pc! vm (+ pc 2))]
    [#x85 ; STA dp
     (define off (snes-bus-read8 vm pbr (+ pc 1)))
     (if (= m-w 16)
         (snes-bus-write16! vm 0 (+ dp off) (get-accum vm))
         (snes-bus-write8! vm 0 (+ dp off) (get-accum vm)))
     (set-snes-vm-pc! vm (+ pc 2))]
    [#x64 ; STZ dp
     (define off (snes-bus-read8 vm pbr (+ pc 1)))
     (if (= m-w 16)
         (snes-bus-write16! vm 0 (+ dp off) 0)
         (snes-bus-write8! vm 0 (+ dp off) 0))
     (set-snes-vm-pc! vm (+ pc 2))]
    [#xE6 ; INC dp
     (define off (snes-bus-read8 vm pbr (+ pc 1)))
     (define v (add1 (snes-bus-read8 vm 0 (+ dp off))))
     (snes-bus-write8! vm 0 (+ dp off) v)
     (update-nz-flags! vm v 8)
     (set-snes-vm-pc! vm (+ pc 2))]
    [#xC6 ; DEC dp
     (define off (snes-bus-read8 vm pbr (+ pc 1)))
     (define v (sub1 (snes-bus-read8 vm 0 (+ dp off))))
     (snes-bus-write8! vm 0 (+ dp off) v)
     (update-nz-flags! vm v 8)
     (set-snes-vm-pc! vm (+ pc 2))]

    ;; Absolute 16-bit loads/stores
    [#xAD ; LDA abs
     (define addr (snes-bus-read16 vm pbr (+ pc 1)))
     (set-accum! vm (if (= m-w 16)
                        (snes-bus-read16 vm dbr addr)
                        (snes-bus-read8 vm dbr addr)))
     (set-snes-vm-pc! vm (+ pc 3))]
    [#xBD ; LDA abs,X
     (define addr (+ (snes-bus-read16 vm pbr (+ pc 1)) (snes-vm-x vm)))
     (set-accum! vm (if (= m-w 16)
                        (snes-bus-read16 vm dbr addr)
                        (snes-bus-read8 vm dbr addr)))
     (set-snes-vm-pc! vm (+ pc 3))]
    [#x8D ; STA abs
     (define addr (snes-bus-read16 vm pbr (+ pc 1)))
     (if (= m-w 16)
         (snes-bus-write16! vm dbr addr (get-accum vm))
         (snes-bus-write8! vm dbr addr (get-accum vm)))
     (set-snes-vm-pc! vm (+ pc 3))]
    [#x9D ; STA abs,X
     (define addr (+ (snes-bus-read16 vm pbr (+ pc 1)) (snes-vm-x vm)))
     (if (= m-w 16)
         (snes-bus-write16! vm dbr addr (get-accum vm))
         (snes-bus-write8! vm dbr addr (get-accum vm)))
     (set-snes-vm-pc! vm (+ pc 3))]
    [#x8E ; STX abs
     (define addr (snes-bus-read16 vm pbr (+ pc 1)))
     (if (= x-w 16)
         (snes-bus-write16! vm dbr addr (snes-vm-x vm))
         (snes-bus-write8! vm dbr addr (snes-vm-x vm)))
     (set-snes-vm-pc! vm (+ pc 3))]
    [#x8C ; STY abs
     (define addr (snes-bus-read16 vm pbr (+ pc 1)))
     (if (= x-w 16)
         (snes-bus-write16! vm dbr addr (snes-vm-y vm))
         (snes-bus-write8! vm dbr addr (snes-vm-y vm)))
     (set-snes-vm-pc! vm (+ pc 3))]
    [#x9C ; STZ abs
     (define addr (snes-bus-read16 vm pbr (+ pc 1)))
     (if (= m-w 16)
         (snes-bus-write16! vm dbr addr 0)
         (snes-bus-write8! vm dbr addr 0))
     (set-snes-vm-pc! vm (+ pc 3))]

    ;; Long 24-bit loads/stores
    [#xAF ; LDA long
     (define addr (snes-bus-read16 vm pbr (+ pc 1)))
     (define bnk  (snes-bus-read8 vm pbr (+ pc 3)))
     (set-accum! vm (if (= m-w 16)
                        (snes-bus-read16 vm bnk addr)
                        (snes-bus-read8 vm bnk addr)))
     (set-snes-vm-pc! vm (+ pc 4))]
    [#x8F ; STA long
     (define addr (snes-bus-read16 vm pbr (+ pc 1)))
     (define bnk  (snes-bus-read8 vm pbr (+ pc 3)))
     (if (= m-w 16)
         (snes-bus-write16! vm bnk addr (get-accum vm))
         (snes-bus-write8! vm bnk addr (get-accum vm)))
     (set-snes-vm-pc! vm (+ pc 4))]

    ;; Implied increments & shifts
    [#xE8 (set-index-x! vm (add1 (snes-vm-x vm))) (set-snes-vm-pc! vm (+ pc 1))] ; INX
    [#xCA (set-index-x! vm (sub1 (snes-vm-x vm))) (set-snes-vm-pc! vm (+ pc 1))] ; DEX
    [#xC8 (set-index-y! vm (add1 (snes-vm-y vm))) (set-snes-vm-pc! vm (+ pc 1))] ; INY
    [#x88 (set-index-y! vm (sub1 (snes-vm-y vm))) (set-snes-vm-pc! vm (+ pc 1))] ; DEY
    [#x1A (set-accum! vm (add1 (get-accum vm)))   (set-snes-vm-pc! vm (+ pc 1))] ; INC A
    [#x3A (set-accum! vm (sub1 (get-accum vm)))   (set-snes-vm-pc! vm (+ pc 1))] ; DEC A
    [#x0A ; ASL A
     (define v (arithmetic-shift (get-accum vm) 1))
     (set-accum! vm v)
     (set-snes-vm-pc! vm (+ pc 1))]
    [#x4A ; LSR A
     (define v (arithmetic-shift (get-accum vm) -1))
     (set-accum! vm v)
     (set-snes-vm-pc! vm (+ pc 1))]

    ;; ALU Immediate & Absolute
    [#x69 ; ADC #imm
     (define imm (fetch-imm m-w))
     (define sum (+ (get-accum vm) imm (if (snes-vm-flag-c vm) 1 0)))
     (define maxv (if (= m-w 16) #xFFFF #xFF))
     (set-snes-vm-flag-c! vm (> sum maxv))
     (set-accum! vm sum)]
    [#xE9 ; SBC #imm
     (define imm (fetch-imm m-w))
     (define diff (- (get-accum vm) imm (if (snes-vm-flag-c vm) 0 1)))
     (set-snes-vm-flag-c! vm (>= diff 0))
     (set-accum! vm diff)]
    [#x29 (set-accum! vm (bitwise-and (get-accum vm) (fetch-imm m-w)))] ; AND #imm
    [#x09 (set-accum! vm (bitwise-ior (get-accum vm) (fetch-imm m-w)))] ; ORA #imm
    [#x49 (set-accum! vm (bitwise-xor (get-accum vm) (fetch-imm m-w)))] ; EOR #imm
    [#xC9 ; CMP #imm
     (define imm (fetch-imm m-w))
     (define diff (- (get-accum vm) imm))
     (set-snes-vm-flag-c! vm (>= diff 0))
     (update-nz-flags! vm diff m-w)]
    [#xCD ; CMP abs
     (define addr (snes-bus-read16 vm pbr (+ pc 1)))
     (define rhs  (if (= m-w 16) (snes-bus-read16 vm dbr addr) (snes-bus-read8 vm dbr addr)))
     (define diff (- (get-accum vm) rhs))
     (set-snes-vm-flag-c! vm (>= diff 0))
     (update-nz-flags! vm diff m-w)
     (set-snes-vm-pc! vm (+ pc 3))]
    [#xE0 ; CPX #imm
     (define imm (fetch-imm x-w))
     (define diff (- (snes-vm-x vm) imm))
     (set-snes-vm-flag-c! vm (>= diff 0))
     (update-nz-flags! vm diff x-w)]
    [#xC0 ; CPY #imm
     (define imm (fetch-imm x-w))
     (define diff (- (snes-vm-y vm) imm))
     (set-snes-vm-flag-c! vm (>= diff 0))
     (update-nz-flags! vm diff x-w)]

    ;; Hardware Block Move MVN (#x54 dst-bank src-bank)
    [#x54
     (define dst-b (snes-bus-read8 vm pbr (+ pc 1)))
     (define src-b (snes-bus-read8 vm pbr (+ pc 2)))
     (define count (add1 (bitwise-and (snes-vm-a vm) #xFFFF)))
     (define src-x (snes-vm-x vm))
     (define dst-y (snes-vm-y vm))
     (for ([i (in-range count)])
       (define byte-val (snes-bus-read8 vm src-b (+ src-x i)))
       (snes-bus-write8! vm dst-b (+ dst-y i) byte-val))
     (set-snes-vm-a! vm #xFFFF)
     (set-snes-vm-x! vm (bitwise-and (+ src-x count) #xFFFF))
     (set-snes-vm-y! vm (bitwise-and (+ dst-y count) #xFFFF))
     (set-snes-vm-dbr! vm dst-b)
     (set-snes-vm-pc! vm (+ pc 3))]

    ;; Branches & Jumps
    [#x80 (branch-if! #t)]                       ; BRA
    [#xF0 (branch-if! (snes-vm-flag-z vm))]      ; BEQ
    [#xD0 (branch-if! (not (snes-vm-flag-z vm)))] ; BNE
    [#x10 (branch-if! (not (snes-vm-flag-n vm)))] ; BPL
    [#x30 (branch-if! (snes-vm-flag-n vm))]      ; BMI
    [#x90 (branch-if! (not (snes-vm-flag-c vm)))] ; BCC
    [#xB0 (branch-if! (snes-vm-flag-c vm))]      ; BCS
    [#x4C ; JMP abs
     (set-snes-vm-pc! vm (snes-bus-read16 vm pbr (+ pc 1)))]
    [#x5C ; JML long
     (define tgt (snes-bus-read16 vm pbr (+ pc 1)))
     (define bnk (snes-bus-read8 vm pbr (+ pc 3)))
     (set-snes-vm-pbr! vm bnk)
     (set-snes-vm-pc! vm tgt)]
    [#x20 ; JSR abs
     (define tgt (snes-bus-read16 vm pbr (+ pc 1)))
     (push16! vm (+ pc 2))
     (set-snes-vm-pc! vm tgt)]
    [#x22 ; JSL long
     (define tgt (snes-bus-read16 vm pbr (+ pc 1)))
     (define bnk (snes-bus-read8 vm pbr (+ pc 3)))
     (push8! vm pbr)
     (push16! vm (+ pc 3))
     (set-snes-vm-pbr! vm bnk)
     (set-snes-vm-pc! vm tgt)]
    [#x60 ; RTS
     (set-snes-vm-pc! vm (add1 (pull16! vm)))]
    [#x6B ; RTL
     (define ret-pc (add1 (pull16! vm)))
     (define ret-b  (pull8! vm))
     (set-snes-vm-pbr! vm ret-b)
     (set-snes-vm-pc! vm ret-pc)]
    [#x40 ; RTI
     (set-snes-vm-waiting?! vm #t)]
    [#xCB ; WAI
     (set-snes-vm-waiting?! vm #t)
     (set-snes-vm-pc! vm (+ pc 1))]
    [#xEA (set-snes-vm-pc! vm (+ pc 1))] ; NOP
    [_ (error 'snes-step-instruction! "Unhandled 65C816 opcode #x~x at PC=$~x" op pc)]))

;; Run 65C816 instructions until WAI (#xCB) or RTI (#x40)
(define (snes-run-until-wai-or-rti! vm [max-steps 50000])
  (set-snes-vm-waiting?! vm #f)
  (let loop ([steps 0])
    (when (and (< steps max-steps) (not (snes-vm-waiting? vm)))
      (snes-step-instruction! vm)
      (loop (add1 steps)))))

;; Step one full 60Hz SNES frame (triggers Native NMI vector + HBlank HDMA)
(define (snes-step-frame! vm [joypad-mask 0])
  (snes-set-joypad1! vm joypad-mask)
  (define rom (snes-vm-rom vm))
  (define nmi-lo (bytes-ref rom #x7FEA))
  (define nmi-hi (bytes-ref rom #x7FEB))
  (define nmi-pc (bitwise-ior nmi-lo (arithmetic-shift nmi-hi 8)))
  (set-snes-vm-pc! vm nmi-pc)
  (snes-run-until-wai-or-rti! vm))

;; Read a Direct Page byte from `vm`
(define (snes-dp-ref vm dp-addr)
  (snes-bus-read8 vm 0 (+ (snes-vm-d vm) dp-addr)))

;; Headless SNES 65C816 + S-PPU + SPC700 Execution & 4-Stage Campaign Verifier
(define (verify-snes-rom-execution rom-source)
  (define rom-bytes
    (cond
      [(bytes? rom-source) rom-source]
      [(or (path? rom-source) (string? rom-source))
       (file->bytes rom-source)]
      [else (error 'verify-snes-rom-execution "Invalid ROM source: ~s" rom-source)]))

  ;; 1. Verify LoROM Header ($7FC0-$7FFF) & Checksum/Complement
  (define size-ok? (= (bytes-length rom-bytes) 32768))
  (define title-str
    (bytes->string/latin-1 (subbytes rom-bytes #x7FC0 #x7FD5)))
  (define map-mode (bytes-ref rom-bytes #x7FD5))
  (define rom-size-code (bytes-ref rom-bytes #x7FD7))
  (define sram-code (bytes-ref rom-bytes #x7FD8))
  (define stored-comp
    (bitwise-ior (bytes-ref rom-bytes #x7FDC)
                 (arithmetic-shift (bytes-ref rom-bytes #x7FDD) 8)))
  (define stored-chk
    (bitwise-ior (bytes-ref rom-bytes #x7FDE)
                 (arithmetic-shift (bytes-ref rom-bytes #x7FDF) 8)))
  (define-values (computed-chk computed-comp)
    (compute-snes-lorom-checksum rom-bytes))
  (define xor-ok? (= (bitwise-xor stored-chk stored-comp) #xFFFF))
  (define sum-ok? (and (= stored-chk computed-chk) (= stored-comp computed-comp)))
  (define header-ok?
    (and size-ok? (= map-mode #x30) (= rom-size-code #x08) (= sram-code #x00) xor-ok? sum-ok?))

  ;; 2. Boot from RESET vector and run through initialization until WAI
  (define vm (make-snes-vm-from-rom rom-bytes))
  (snes-run-until-wai-or-rti! vm)

  (define native-switched? (not (snes-vm-emulation? vm)))
  (define reg-16bit-ok? (= (snes-vm-x-width vm) 16))
  (define spc-ok? (and (eq? (snes-vm-spc-ipl-state vm) 'running)
                       (= (bytes-ref (snes-vm-aram vm) #x0010) #x5A)))
  (define spc-uploaded (snes-vm-spc-uploaded-bytes vm))
  (define spc-kon (bytes-ref (snes-vm-dsp-regs vm) #x4C))

  ;; Snapshot state helper
  (define (snapshot label)
    (hasheq 'step          label
            'stage         (snes-dp-ref vm DP-CUR-STAGE)
            'status        (case (snes-dp-ref vm DP-STAGE-STATUS)
                             [(0) 'playing]
                             [(1) 'failed]
                             [(2) 'victory]
                             [else 'unknown])
            'player-x      (snes-dp-ref vm DP-PLAYER-X)
            'player-y      (snes-dp-ref vm DP-PLAYER-Y)
            'moves         (snes-dp-ref vm DP-MOVE-COUNT)
            'recoveries    (snes-dp-ref vm DP-RECOVERIES)
            'stage-clears  (snes-dp-ref vm DP-STAGE-CLEARS)
            'campaign-won  (snes-dp-ref vm DP-CAMPAIGN-WON)
            'spc-last-cmd  (snes-dp-ref vm DP-SPC-CMD)))

  ;; 3. Execute 4-Stage Campaign:
  ;;    Stage 0 -> Stage 1 -> Failure -> START Recovery -> Stage 2 -> Stage 3 Victory
  (define trace0 (snapshot 'boot-stage-0))
  (snes-step-frame! vm SNES-BTN-RIGHT) ; Clear Stage 0 -> Stage 1
  (define trace1 (snapshot 'stage-1-reached))
  (snes-step-frame! vm SNES-BTN-DOWN)  ; Step into Skull hazard -> Failure
  (define trace2 (snapshot 'stage-1-failure))
  (snes-step-frame! vm SNES-BTN-START) ; Press START -> START Recovery
  (define trace3 (snapshot 'stage-1-recovered))
  (snes-step-frame! vm SNES-BTN-RIGHT) ; Clear Stage 1 -> Stage 2
  (define trace4 (snapshot 'stage-2-reached))
  (snes-step-frame! vm SNES-BTN-RIGHT) ; Clear Stage 2 -> Stage 3
  (define trace5 (snapshot 'stage-3-reached))
  (snes-step-frame! vm SNES-BTN-RIGHT) ; Clear Stage 3 -> Stage 3 Victory!
  (define trace6 (snapshot 'stage-3-victory))

  (define campaign-trace
    (list trace0 trace1 trace2 trace3 trace4 trace5 trace6))

  (define campaign-ok?
    (and (= (hash-ref trace0 'stage) 0) (eq? (hash-ref trace0 'status) 'playing)
         (= (hash-ref trace1 'stage) 1) (eq? (hash-ref trace1 'status) 'playing)
         (= (hash-ref trace2 'stage) 1) (eq? (hash-ref trace2 'status) 'failed)
         (= (hash-ref trace3 'stage) 1) (eq? (hash-ref trace3 'status) 'playing)
         (= (hash-ref trace3 'recoveries) 1)
         (= (hash-ref trace4 'stage) 2) (eq? (hash-ref trace4 'status) 'playing)
         (= (hash-ref trace5 'stage) 3) (eq? (hash-ref trace5 'status) 'playing)
         (= (hash-ref trace6 'stage) 3) (eq? (hash-ref trace6 'status) 'victory)
         (= (hash-ref trace6 'campaign-won) 1)
         (= (hash-ref trace6 'stage-clears) #x0F)))

  (snes-verification-report
   header-ok?
   (string-trim title-str)
   map-mode
   (bytes-length rom-bytes)
   stored-chk
   stored-comp
   xor-ok?
   sum-ok?
   native-switched?
   reg-16bit-ok?
   spc-ok?
   spc-uploaded
   spc-kon
   64   ; CGRAM DMA bytes uploaded
   512  ; 4bpp CHR VRAM DMA bytes uploaded (16 tiles * 32 B)
   (snes-vm-hdmaen vm)
   (snes-vm-hdma-scanlines vm)
   (snes-vm-dma-transfers vm)
   campaign-trace
   campaign-ok?))

;; Compile, link, write, and verify the complete "Boba Is You" SNES LoROM (.sfc)
(define (compile-boba-snes-rom! #:sfc-out-path [sfc-out-path #f]
                                #:title [title "BOBA IS YOU SNES"])
  (define spc-asm   (build-boba-spc700-driver #:origin #x0200))
  (define cgram-pal (build-boba-snes-cgram-palette))
  (define chr-4bpp  (build-boba-snes-4bpp-tileset))
  (define hdma-tbl  (build-snes-hdma-gradient-table))

  (define prog-forms
    (build-boba-snes-65816-program #:spc-driver-bytes (spc700-asm-result-bytes spc-asm)
                                   #:cgram-bytes cgram-pal
                                   #:chr-4bpp-bytes chr-4bpp
                                   #:hdma-bytes hdma-tbl))
  (define asm-res
    (assemble-65816 prog-forms
                    #:origin #x8000
                    #:init-m 8
                    #:init-x 8
                    #:init-e 'emulation
                    #:enforce-mode-safety? #t))
  (define labels (asm-65816-result-labels asm-res))
  (define sfc-bytes
    (build-snes-lorom-image (asm-65816-result-bytes asm-res)
                            #:title title
                            #:reset-vector (hash-ref labels 'reset_vector)
                            #:nmi-vector   (hash-ref labels 'nmi_vector)
                            #:irq-vector   (hash-ref labels 'irq_vector)))
  (when sfc-out-path
    (make-directory* (path-only sfc-out-path))
    (display-to-file sfc-bytes sfc-out-path #:exists 'replace))
  (define report
    (verify-snes-rom-execution (or sfc-out-path sfc-bytes)))
  (values sfc-bytes asm-res spc-asm report))
