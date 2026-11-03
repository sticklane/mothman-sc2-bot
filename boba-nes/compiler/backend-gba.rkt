#lang racket/base

;; ============================================================================
;; compiler/backend-gba.rkt
;; Game Boy Advance (ARM7TDMI: ARM32 + Thumb16) Assembler, u16/u32 VRAM Bus
;; Capability Verifier, .gba Cartridge Linker & Headless Execution Verifier
;; ============================================================================

(require (for-syntax racket/base
                     racket/path)
         racket/bytes
         racket/file
         racket/format
         racket/list
         racket/match
         racket/math
         racket/path
         racket/string)

(provide
 ;; 1. GBA Hardware Memory Map & MMIO Register Constants
 GBA-BIOS-BASE
 GBA-EWRAM-BASE
 GBA-IWRAM-BASE
 GBA-MMIO-BASE
 GBA-PALRAM-BASE
 GBA-PALRAM-OBJ-BASE
 GBA-VRAM-BASE
 GBA-VRAM-OBJ-BASE
 GBA-OAM-BASE
 GBA-ROM-BASE
 GBA-ROM-ENTRY

 REG-DISPCNT
 REG-DISPSTAT
 REG-VCOUNT
 REG-BG0CNT
 REG-DMA3SAD
 REG-DMA3DAD
 REG-DMA3CNT
 REG-DMA3CNT-L
 REG-DMA3CNT-H
 REG-KEYINPUT

 DISPCNT-MODE-0
 DISPCNT-OBJ-1D
 DISPCNT-BG0-ON
 DISPCNT-OBJ-ON
 DMA-ENABLE
 DMA-32BIT
 DMA-16BIT

 ;; 2. GBA Controller & Campaign State Constants
 GBA-BTN-A
 GBA-BTN-B
 GBA-BTN-SELECT
 GBA-BTN-START
 GBA-BTN-RIGHT
 GBA-BTN-LEFT
 GBA-BTN-UP
 GBA-BTN-DOWN

 IWRAM-STATE-BUTTONS
 IWRAM-STATE-FRAME-CNT
 IWRAM-STATE-PLAYER-X
 IWRAM-STATE-PLAYER-Y
 IWRAM-STATE-ENERGY
 IWRAM-STATE-LIVES
 IWRAM-STATE-DEAD
 IWRAM-STATE-STAGE-ID
 IWRAM-STATE-WON
 IWRAM-STATE-GAME-COMPLETED
 IWRAM-STATE-SCORE
 IWRAM-STATE-RULES

 ;; 3. ARM7TDMI (ARM32 + Thumb16) Instruction Constructors & Assembler
 arm-mov-imm
 arm-orr-imm
 arm-add-imm
 arm-sub-imm
 arm-cmp-imm
 arm-ldr-imm
 arm-str-imm
 arm-strh-imm
 arm-ldrh-imm
 arm-strb-imm
 arm-ldrb-imm
 arm-b
 arm-beq
 arm-bne
 arm-bl
 arm-bx
 thumb-mov-imm
 thumb-add-imm
 thumb-sub-imm
 thumb-strh
 thumb-strb
 thumb-bx
 emit-arm-mov32
 encode-arm7tdmi-inst
 assemble-arm7tdmi
 gba-asm-result?
 gba-asm-result-bytes
 gba-asm-result-origin
 gba-asm-result-labels
 gba-asm-result-cycles
 gba-asm-result-arm-count
 gba-asm-result-thumb-count

 ;; 4. GBA VRAM 16/32-bit Bus-Width Capability Verifier & IWRAM/EWRAM Grader
 verify-gba-vram-bus-widths

 ;; 5. .gba Cartridge Header, 4bpp Tile/Palette/OAM Builders & ROM Linker
 GBA-NINTENDO-LOGO
 compute-gba-header-checksum
 verify-gba-cartridge-header
 compile-gba-4bpp-tile
 build-boba-gba-palettes
 build-boba-gba-4bpp-tiles
 build-boba-gba-oam-table
 emit-boba-gba-arm7tdmi-program
 build-gba-rom-image
 compile-boba-gba-rom!

 ;; 6. Headless ARM7TDMI + DMA3 + PPU Emulator & 4-Stage Campaign Verifier
 (struct-out gba-machine)
 make-gba-machine
 gba-read-u8
 gba-read-u16
 gba-read-u32
 gba-write-u16!
 gba-write-u32!
 gba-step-arm7tdmi!
 gba-run-subroutine!
 gba-step-frame!
 verify-gba-rom-execution)

(define-syntax (get-repo-root-dir stx)
  (datum->syntax stx (path->string (simplify-path (build-path (syntax-source stx) 'up 'up)))))

(define REPO-ROOT-DIR (string->path (get-repo-root-dir)))

(define (resolve-gba-path p)
  (define path-obj (if (path? p) p (string->path p)))
  (if (complete-path? path-obj)
      path-obj
      (simplify-path (build-path REPO-ROOT-DIR path-obj))))

;; ============================================================================
;; 1. GBA Hardware Address Map & I/O Registers
;; ============================================================================

(define GBA-BIOS-BASE       #x00000000)
(define GBA-EWRAM-BASE      #x02000000) ; 256 KB On-Board Work RAM (16-bit bus, 2 waitstates)
(define GBA-IWRAM-BASE      #x03000000) ; 32 KB Fast Internal Work RAM (32-bit bus, 0 waitstates = 1 cyc)
(define GBA-MMIO-BASE       #x04000000) ; I/O Registers
(define GBA-PALRAM-BASE     #x05000000) ; 1 KB Palette RAM (16-bit bus, NO 8-bit STRB!)
(define GBA-PALRAM-OBJ-BASE #x05000200) ; OBJ Palette RAM ($05000200-$050003FF)
(define GBA-VRAM-BASE       #x06000000) ; 96 KB Video RAM (16-bit bus, NO 8-bit STRB!)
(define GBA-VRAM-OBJ-BASE   #x06010000) ; OBJ Character VRAM ($06010000-$06017FFF)
(define GBA-OAM-BASE        #x07000000) ; 1 KB Object Attribute Memory (32-bit bus, NO 8-bit STRB!)
(define GBA-ROM-BASE        #x08000000) ; Game Pak ROM Wait State 0
(define GBA-ROM-ENTRY       #x080000C0) ; Code entry point immediately after 192-byte cartridge header

(define REG-DISPCNT         #x04000000)
(define REG-DISPSTAT        #x04000004)
(define REG-VCOUNT          #x04000006)
(define REG-BG0CNT          #x04000008)
(define REG-DMA3SAD         #x040000D4)
(define REG-DMA3DAD         #x040000D8)
(define REG-DMA3CNT         #x040000DC)
(define REG-DMA3CNT-L       #x040000DC)
(define REG-DMA3CNT-H       #x040000DE)
(define REG-KEYINPUT        #x04000130)

(define DISPCNT-MODE-0      #x0000)
(define DISPCNT-OBJ-1D      #x0040)
(define DISPCNT-BG0-ON      #x0100)
(define DISPCNT-OBJ-ON      #x1000)

(define DMA-ENABLE          #x80000000)
(define DMA-32BIT           #x04000000)
(define DMA-16BIT           #x00000000)

;; Controller bitmasks (compatible with GBA KEYINPUT bit positions & campaign driver)
(define GBA-BTN-A           #x0001)
(define GBA-BTN-B           #x0002)
(define GBA-BTN-SELECT      #x0004)
(define GBA-BTN-START       #x0008)
(define GBA-BTN-RIGHT       #x0010)
(define GBA-BTN-LEFT        #x0020)
(define GBA-BTN-UP          #x0040)
(define GBA-BTN-DOWN        #x0080)

;; Pinned IWRAM ($03000000..$0300002F) 32-bit Fast Work RAM State Offsets
(define IWRAM-STATE-BUTTONS        #x00) ; $03000000
(define IWRAM-STATE-FRAME-CNT      #x04) ; $03000004
(define IWRAM-STATE-PLAYER-X       #x08) ; $03000008
(define IWRAM-STATE-PLAYER-Y       #x0C) ; $0300000C
(define IWRAM-STATE-ENERGY         #x10) ; $03000010
(define IWRAM-STATE-LIVES          #x14) ; $03000014
(define IWRAM-STATE-DEAD           #x18) ; $03000018
(define IWRAM-STATE-STAGE-ID       #x1C) ; $0300001C
(define IWRAM-STATE-WON            #x20) ; $03000020
(define IWRAM-STATE-GAME-COMPLETED #x24) ; $03000024
(define IWRAM-STATE-SCORE          #x28) ; $03000028
(define IWRAM-STATE-RULES          #x2C) ; $0300002C

;; ============================================================================
;; 2. ARM7TDMI (ARM32 + Thumb16) Instruction Constructors & Assembler
;; ============================================================================

(define (reg-index r)
  (cond
    [(exact-integer? r)
     (unless (and (>= r 0) (<= r 15))
       (error 'reg-index "ARM7TDMI register index out of range 0..15: ~v" r))
     r]
    [(symbol? r)
     (case r
       [(r0 R0 a1) 0]
       [(r1 R1 a2) 1]
       [(r2 R2 a3) 2]
       [(r3 R3 a4) 3]
       [(r4 R4 v1) 4]
       [(r5 R5 v2) 5]
       [(r6 R6 v3) 6]
       [(r7 R7 v4) 7]
       [(r8 R8 v5) 8]
       [(r9 R9 v6) 9]
       [(r10 R10 sl) 10]
       [(r11 R11 fp) 11]
       [(r12 R12 ip) 12]
       [(r13 R13 sp SP) 13]
       [(r14 R14 lr LR) 14]
       [(r15 R15 pc PC) 15]
       [else (error 'reg-index "Unknown ARM7TDMI register symbol: ~v" r)])]
    [else (error 'reg-index "Invalid ARM7TDMI register specifier: ~v" r)]))

;; Constructors produce symbolic S-expression forms that `assemble-arm7tdmi` accepts
(define (arm-mov-imm rd imm8 [rot4 0])   `(arm-mov-imm ,rd ,imm8 ,rot4))
(define (arm-orr-imm rd rn imm8 [rot4 0]) `(arm-orr-imm ,rd ,rn ,imm8 ,rot4))
(define (arm-add-imm rd rn imm8 [rot4 0]) `(arm-add-imm ,rd ,rn ,imm8 ,rot4))
(define (arm-sub-imm rd rn imm8 [rot4 0]) `(arm-sub-imm ,rd ,rn ,imm8 ,rot4))
(define (arm-cmp-imm rn imm8 [rot4 0])    `(arm-cmp-imm ,rn ,imm8 ,rot4))
(define (arm-ldr-imm rd rn offset12)      `(arm-ldr-imm ,rd ,rn ,offset12))
(define (arm-str-imm rd rn offset12)      `(arm-str-imm ,rd ,rn ,offset12))
(define (arm-strh-imm rd rn offset8)      `(arm-strh-imm ,rd ,rn ,offset8))
(define (arm-ldrh-imm rd rn offset8)      `(arm-ldrh-imm ,rd ,rn ,offset8))
(define (arm-strb-imm rd rn offset12)     `(arm-strb-imm ,rd ,rn ,offset12))
(define (arm-ldrb-imm rd rn offset12)     `(arm-ldrb-imm ,rd ,rn ,offset12))
(define (arm-b label)                     `(arm-b ,label))
(define (arm-beq label)                   `(arm-beq ,label))
(define (arm-bne label)                   `(arm-bne ,label))
(define (arm-bl label)                    `(arm-bl ,label))
(define (arm-bx rm)                       `(arm-bx ,rm))

(define (thumb-mov-imm rd imm8)           `(thumb-mov-imm ,rd ,imm8))
(define (thumb-add-imm rd imm8)           `(thumb-add-imm ,rd ,imm8))
(define (thumb-sub-imm rd imm8)           `(thumb-sub-imm ,rd ,imm8))
(define (thumb-strh rd rb ro)             `(thumb-strh ,rd ,rb ,ro))
(define (thumb-strb rd rb ro)             `(thumb-strb ,rd ,rb ,ro))
(define (thumb-bx rm)                     `(thumb-bx ,rm))

;; Helper to synthesize a 32-bit constant in register `rd` using ARM immediate rotations:
;;   rot4 = 4  (ROR 8  -> bits 31..24)
;;   rot4 = 8  (ROR 16 -> bits 23..16)
;;   rot4 = 12 (ROR 24 -> bits 15..8)
;;   rot4 = 0  (ROR 0  -> bits 7..0)
(define (emit-arm-mov32 rd val32)
  (define u32 (bitwise-and val32 #xFFFFFFFF))
  (define b3 (bitwise-and (arithmetic-shift u32 -24) #xFF))
  (define b2 (bitwise-and (arithmetic-shift u32 -16) #xFF))
  (define b1 (bitwise-and (arithmetic-shift u32 -8)  #xFF))
  (define b0 (bitwise-and u32 #xFF))
  (define pieces
    (filter (lambda (p) (not (zero? (car p))))
            (list (cons b3 4) (cons b2 8) (cons b1 12) (cons b0 0))))
  (if (null? pieces)
      (list (arm-mov-imm rd 0 0))
      (let ([first-p (car pieces)]
            [rest-ps (cdr pieces)])
        (cons (arm-mov-imm rd (car first-p) (cdr first-p))
              (for/list ([p (in-list rest-ps)])
                (arm-orr-imm rd rd (car p) (cdr p)))))))

(define (u32->le-bytes w)
  (define u (bitwise-and w #xFFFFFFFF))
  (bytes (bitwise-and u #xFF)
         (bitwise-and (arithmetic-shift u -8) #xFF)
         (bitwise-and (arithmetic-shift u -16) #xFF)
         (bitwise-and (arithmetic-shift u -24) #xFF)))

(define (u16->le-bytes h)
  (define u (bitwise-and h #xFFFF))
  (bytes (bitwise-and u #xFF)
         (bitwise-and (arithmetic-shift u -8) #xFF)))

(define (ror32 val shift)
  (define u (bitwise-and val #xFFFFFFFF))
  (define s (modulo shift 32))
  (if (zero? s)
      u
      (bitwise-and #xFFFFFFFF
                   (bitwise-ior (arithmetic-shift u (- s))
                                (arithmetic-shift u (- 32 s))))))

;; Automatically infer (values imm8 rot4) when a 2-arg immediate > 255 is supplied
(define (encode-arm-imm12 imm [rot4 #f])
  (cond
    [(and rot4 (not (zero? rot4)))
     (values (bitwise-and imm #xFF) (bitwise-and rot4 #xF))]
    [(<= 0 imm #xFF)
     (values imm 0)]
    [else
     (define u32 (bitwise-and imm #xFFFFFFFF))
     (let loop ([r 0])
       (if (= r 16)
           (error 'encode-arm-imm12 "Immediate #x~x cannot be represented as imm8 ROR (2*rot4)" imm)
           (let* ([sh (* 2 r)]
                  [rotated (bitwise-and #xFFFFFFFF
                                        (bitwise-ior (arithmetic-shift u32 sh)
                                                     (arithmetic-shift u32 (- sh 32))))])
             (if (<= rotated #xFF)
                 (values rotated r)
                 (loop (add1 r))))))]))

(define (inst-byte-size form)
  (match form
    [`(label ,_) 0]
    [`(.equ ,_ ,_) 0]
    [`(.byte . ,vals) (length vals)]
    [`(,(or '.half '.hword) . ,vals) (* 2 (length vals))]
    [`(.word . ,vals) (* 4 (length vals))]
    [`(,(or 'thumb-mov-imm 'thumb-add-imm 'thumb-sub-imm 'thumb-strh 'thumb-strb 'thumb-bx) . ,_) 2]
    [else 4]))

(define (eval-gba-expr expr labels [default-val 0])
  (match expr
    [(? exact-integer? n) n]
    [(? symbol? sym)
     (hash-ref labels sym
               (lambda ()
                 (if default-val
                     default-val
                     (error 'eval-gba-expr "Undefined ARM7TDMI label: ~a" sym))))]
    [`(+ ,a ,b) (+ (eval-gba-expr a labels default-val)
                   (eval-gba-expr b labels default-val))]
    [`(- ,a ,b) (- (eval-gba-expr a labels default-val)
                   (eval-gba-expr b labels default-val))]
    [else (error 'eval-gba-expr "Unsupported expression: ~v" expr)]))

;; Encode a single ARM32 (4-byte LE) or Thumb16 (2-byte LE) instruction form
(define (encode-arm7tdmi-inst form [pc #x080000C0] [labels (hasheq)])
  (define (resolve-branch-imm24 target)
    (cond
      [(and (exact-integer? target) (< (abs target) #x01000000))
       ;; If target is a full address >= #x08000000, compute PC-relative word offset;
       ;; otherwise if it is already a small signed word/byte offset, handle cleanly.
       (bitwise-and #xFFFFFF (arithmetic-shift (- target (+ pc 8)) -2))]
      [else
       (define target-addr (eval-gba-expr target labels #f))
       (bitwise-and #xFFFFFF (arithmetic-shift (- target-addr (+ pc 8)) -2))]))

  (match form
    ;; --- 32-bit ARM Instructions ---
    [(list* 'arm-mov-imm rd imm8 rest)
     (define rot (if (null? rest) 0 (car rest)))
     (define-values (i8 r4) (encode-arm-imm12 (eval-gba-expr imm8 labels #f) rot))
     (u32->le-bytes (bitwise-ior #xE3A00000
                                 (arithmetic-shift (reg-index rd) 12)
                                 (arithmetic-shift r4 8)
                                 i8))]
    [(list* 'arm-orr-imm rd rn imm8 rest)
     (define rot (if (null? rest) 0 (car rest)))
     (define-values (i8 r4) (encode-arm-imm12 (eval-gba-expr imm8 labels #f) rot))
     (u32->le-bytes (bitwise-ior #xE3800000
                                 (arithmetic-shift (reg-index rn) 16)
                                 (arithmetic-shift (reg-index rd) 12)
                                 (arithmetic-shift r4 8)
                                 i8))]
    [(list* 'arm-add-imm rd rn imm8 rest)
     (define rot (if (null? rest) 0 (car rest)))
     (define-values (i8 r4) (encode-arm-imm12 (eval-gba-expr imm8 labels #f) rot))
     (u32->le-bytes (bitwise-ior #xE2800000
                                 (arithmetic-shift (reg-index rn) 16)
                                 (arithmetic-shift (reg-index rd) 12)
                                 (arithmetic-shift r4 8)
                                 i8))]
    [(list* 'arm-sub-imm rd rn imm8 rest)
     (define rot (if (null? rest) 0 (car rest)))
     (define-values (i8 r4) (encode-arm-imm12 (eval-gba-expr imm8 labels #f) rot))
     (u32->le-bytes (bitwise-ior #xE2400000
                                 (arithmetic-shift (reg-index rn) 16)
                                 (arithmetic-shift (reg-index rd) 12)
                                 (arithmetic-shift r4 8)
                                 i8))]
    [(list* 'arm-cmp-imm rn imm8 rest)
     (define rot (if (null? rest) 0 (car rest)))
     (define-values (i8 r4) (encode-arm-imm12 (eval-gba-expr imm8 labels #f) rot))
     (u32->le-bytes (bitwise-ior #xE3500000
                                 (arithmetic-shift (reg-index rn) 16)
                                 (arithmetic-shift r4 8)
                                 i8))]
    [`(arm-ldr-imm ,rd ,rn ,offset12)
     (define off (eval-gba-expr offset12 labels #f))
     (define u-bit (if (>= off 0) #x00800000 0))
     (u32->le-bytes (bitwise-ior #xE5100000
                                 u-bit
                                 (arithmetic-shift (reg-index rn) 16)
                                 (arithmetic-shift (reg-index rd) 12)
                                 (bitwise-and (abs off) #xFFF)))]
    [`(arm-str-imm ,rd ,rn ,offset12)
     (define off (eval-gba-expr offset12 labels #f))
     (define u-bit (if (>= off 0) #x00800000 0))
     (u32->le-bytes (bitwise-ior #xE5000000
                                 u-bit
                                 (arithmetic-shift (reg-index rn) 16)
                                 (arithmetic-shift (reg-index rd) 12)
                                 (bitwise-and (abs off) #xFFF)))]
    [`(arm-strh-imm ,rd ,rn ,offset8)
     (define off (eval-gba-expr offset8 labels #f))
     (define u-bit (if (>= off 0) #x00800000 0))
     (define abs8 (bitwise-and (abs off) #xFF))
     (u32->le-bytes (bitwise-ior #xE14000B0
                                 u-bit
                                 (arithmetic-shift (reg-index rn) 16)
                                 (arithmetic-shift (reg-index rd) 12)
                                 (arithmetic-shift (bitwise-and (arithmetic-shift abs8 -4) #xF) 8)
                                 (bitwise-and abs8 #xF)))]
    [`(arm-ldrh-imm ,rd ,rn ,offset8)
     (define off (eval-gba-expr offset8 labels #f))
     (define u-bit (if (>= off 0) #x00800000 0))
     (define abs8 (bitwise-and (abs off) #xFF))
     (u32->le-bytes (bitwise-ior #xE15000B0
                                 u-bit
                                 (arithmetic-shift (reg-index rn) 16)
                                 (arithmetic-shift (reg-index rd) 12)
                                 (arithmetic-shift (bitwise-and (arithmetic-shift abs8 -4) #xF) 8)
                                 (bitwise-and abs8 #xF)))]
    [`(arm-strb-imm ,rd ,rn ,offset12)
     (define off (eval-gba-expr offset12 labels #f))
     (define u-bit (if (>= off 0) #x00800000 0))
     (u32->le-bytes (bitwise-ior #xE5400000
                                 u-bit
                                 (arithmetic-shift (reg-index rn) 16)
                                 (arithmetic-shift (reg-index rd) 12)
                                 (bitwise-and (abs off) #xFFF)))]
    [`(arm-ldrb-imm ,rd ,rn ,offset12)
     (define off (eval-gba-expr offset12 labels #f))
     (define u-bit (if (>= off 0) #x00800000 0))
     (u32->le-bytes (bitwise-ior #xE5500000
                                 u-bit
                                 (arithmetic-shift (reg-index rn) 16)
                                 (arithmetic-shift (reg-index rd) 12)
                                 (bitwise-and (abs off) #xFFF)))]
    [`(arm-b ,label)
     (u32->le-bytes (bitwise-ior #xEA000000 (resolve-branch-imm24 label)))]
    [`(arm-beq ,label)
     (u32->le-bytes (bitwise-ior #x0A000000 (resolve-branch-imm24 label)))]
    [`(arm-bne ,label)
     (u32->le-bytes (bitwise-ior #x1A000000 (resolve-branch-imm24 label)))]
    [`(arm-bl ,label)
     (u32->le-bytes (bitwise-ior #xEB000000 (resolve-branch-imm24 label)))]
    [`(arm-bx ,rm)
     (u32->le-bytes (bitwise-ior #xE12FFF10 (reg-index rm)))]

    ;; --- 16-bit Thumb Instructions ---
    [`(thumb-mov-imm ,rd ,imm8)
     (define d (bitwise-and (reg-index rd) #x7))
     (u16->le-bytes (bitwise-ior #x2000
                                 (arithmetic-shift d 8)
                                 (bitwise-and (eval-gba-expr imm8 labels #f) #xFF)))]
    [`(thumb-add-imm ,rd ,imm8)
     (define d (bitwise-and (reg-index rd) #x7))
     (u16->le-bytes (bitwise-ior #x3000
                                 (arithmetic-shift d 8)
                                 (bitwise-and (eval-gba-expr imm8 labels #f) #xFF)))]
    [`(thumb-sub-imm ,rd ,imm8)
     (define d (bitwise-and (reg-index rd) #x7))
     (u16->le-bytes (bitwise-ior #x3800
                                 (arithmetic-shift d 8)
                                 (bitwise-and (eval-gba-expr imm8 labels #f) #xFF)))]
    [`(thumb-strh ,rd ,rb ,ro)
     (define d (bitwise-and (reg-index rd) #x7))
     (define b (bitwise-and (reg-index rb) #x7))
     (define o (bitwise-and (reg-index ro) #x7))
     (u16->le-bytes (bitwise-ior #x5200
                                 (arithmetic-shift o 6)
                                 (arithmetic-shift b 3)
                                 d))]
    [`(thumb-strb ,rd ,rb ,ro)
     (define d (bitwise-and (reg-index rd) #x7))
     (define b (bitwise-and (reg-index rb) #x7))
     (define o (bitwise-and (reg-index ro) #x7))
     (u16->le-bytes (bitwise-ior #x5400
                                 (arithmetic-shift o 6)
                                 (arithmetic-shift b 3)
                                 d))]
    [`(thumb-bx ,rm)
     (define m (bitwise-and (reg-index rm) #xF))
     (u16->le-bytes (bitwise-ior #x4700 (arithmetic-shift m 3)))]

    [else
     (error 'encode-arm7tdmi-inst "Unrecognized ARM7TDMI instruction form: ~v" form)]))

;; Two-pass ARM7TDMI (ARM32 + Thumb16) Assembler
(define (assemble-arm7tdmi forms
                           #:origin [origin GBA-ROM-ENTRY]
                           #:bytes-only? [bytes-only? #f])
  (define labels (make-hash))
  (define pc origin)

  ;; Pass 1: Compute label addresses
  (for ([form (in-list forms)])
    (match form
      [`(label ,sym)
       (hash-set! labels sym pc)]
      [`(.equ ,sym ,val)
       (hash-set! labels sym (eval-gba-expr val labels 0))]
      [`(.align ,boundary)
       (define rem (modulo pc boundary))
       (unless (zero? rem)
         (set! pc (+ pc (- boundary rem))))]
      [else
       (set! pc (+ pc (inst-byte-size form)))]))

  ;; Pass 2: Encode little-endian machine code
  (define chunks '())
  (define cur-pc origin)
  (define arm-cnt 0)
  (define thumb-cnt 0)
  (define total-cycles 0)

  (for ([form (in-list forms)])
    (match form
      [`(label ,_) (void)]
      [`(.equ ,_ ,_) (void)]
      [`(.align ,boundary)
       (define rem (modulo cur-pc boundary))
       (unless (zero? rem)
         (define pad (- boundary rem))
         (set! chunks (cons (make-bytes pad 0) chunks))
         (set! cur-pc (+ cur-pc pad)))]
      [`(.byte . ,vals)
       (define bs (list->bytes (for/list ([v (in-list vals)])
                                 (bitwise-and #xFF (eval-gba-expr v labels #f)))))
       (set! chunks (cons bs chunks))
       (set! cur-pc (+ cur-pc (bytes-length bs)))]
      [`(,(or '.half '.hword) . ,vals)
       (for ([v (in-list vals)])
         (set! chunks (cons (u16->le-bytes (eval-gba-expr v labels #f)) chunks))
         (set! cur-pc (+ cur-pc 2)))]
      [`(.word . ,vals)
       (for ([v (in-list vals)])
         (set! chunks (cons (u32->le-bytes (eval-gba-expr v labels #f)) chunks))
         (set! cur-pc (+ cur-pc 4)))]
      [else
       (define encoded (encode-arm7tdmi-inst form cur-pc labels))
       (define sz (bytes-length encoded))
       (if (= sz 2)
           (begin
             (set! thumb-cnt (add1 thumb-cnt))
             (set! total-cycles (+ total-cycles 1)))
           (begin
             (set! arm-cnt (add1 arm-cnt))
             (set! total-cycles (+ total-cycles
                                   (match form
                                     [`(,(or 'arm-ldr-imm 'arm-ldrh-imm 'arm-ldrb-imm) . ,_) 3]
                                     [`(,(or 'arm-str-imm 'arm-strh-imm 'arm-strb-imm) . ,_) 2]
                                     [`(,(or 'arm-b 'arm-beq 'arm-bne 'arm-bl 'arm-bx) . ,_) 3]
                                     [else 1])))))
       (set! chunks (cons encoded chunks))
       (set! cur-pc (+ cur-pc sz))]))

  (define out-bytes (apply bytes-append (reverse chunks)))
  (define imm-labels
    (for/hasheq ([(k v) (in-hash labels)])
      (values k v)))

  (if bytes-only?
      out-bytes
      (hasheq 'bytes            out-bytes
              'origin           origin
              'labels           imm-labels
              'cycles           total-cycles
              'arm-count        arm-cnt
              'thumb-count      thumb-cnt
              'instruction-count (+ arm-cnt thumb-cnt)
              'forms            forms)))

(define (gba-asm-result? x)
  (or (bytes? x)
      (and (hash? x) (hash-has-key? x 'bytes))))

(define (gba-asm-result-bytes x)
  (if (bytes? x) x (hash-ref x 'bytes)))

(define (gba-asm-result-origin x)
  (if (bytes? x) GBA-ROM-ENTRY (hash-ref x 'origin GBA-ROM-ENTRY)))

(define (gba-asm-result-labels x)
  (if (bytes? x) (hasheq) (hash-ref x 'labels (hasheq))))

(define (gba-asm-result-cycles x)
  (if (bytes? x) (quotient (bytes-length x) 4) (hash-ref x 'cycles 0)))

(define (gba-asm-result-arm-count x)
  (if (bytes? x) (quotient (bytes-length x) 4) (hash-ref x 'arm-count 0)))

(define (gba-asm-result-thumb-count x)
  (if (bytes? x) 0 (hash-ref x 'thumb-count 0)))

;; ============================================================================
;; 3. GBA VRAM Bus-Width Capability Verifier & IWRAM vs. EWRAM Grader
;; ============================================================================
;; GBA hardware lacks an 8-bit write strobe on PALRAM ($05000000), VRAM ($06000000),
;; and OAM ($07000000): an 8-bit `STRB` duplicates the byte across both lanes of the
;; 16-bit halfword in PALRAM/VRAM and is ignored completely in OAM!
;; `verify-gba-vram-bus-widths` statically rejects any 8-bit `STRB` targeting
;; $05000000..$07FFFFFF and grades IWRAM ($03000000, 1-cycle 32-bit) vs EWRAM ($02000000,
;; waitstate 16-bit) placement.
;; ============================================================================

(define (gba-address-region addr)
  (define top-byte (bitwise-and (arithmetic-shift (bitwise-and addr #xFFFFFFFF) -24) #xFF))
  (case top-byte
    [(#x02) 'EWRAM]
    [(#x03) 'IWRAM]
    [(#x04) 'MMIO]
    [(#x05) 'PALRAM]
    [(#x06) 'VRAM]
    [(#x07) 'OAM]
    [(#x08 #x09 #x0A #x0B #x0C #x0D) 'ROM]
    [else   'OTHER]))

(define (vram-bus-region? region)
  (memq region '(PALRAM VRAM OAM)))

(define (verify-gba-vram-bus-widths prog-or-asm
                                    #:error-on-violation? [error-on-violation? #f])
  (define forms
    (cond
      [(and (hash? prog-or-asm) (hash-has-key? prog-or-asm 'forms))
       (hash-ref prog-or-asm 'forms)]
      [(list? prog-or-asm)
       prog-or-asm]
      [else '()]))

  (define regs (make-vector 16 0))
  (define violations '())
  (define palram-writes 0)
  (define vram-writes 0)
  (define oam-writes 0)
  (define dma3-transfers 0)
  (define iwram-accesses 0)
  (define ewram-accesses 0)
  (define iwram-cycles 0)
  (define ewram-cycles 0)

  (define (resolve-base-addr rn-or-addr [offset 0])
    (define base
      (if (and (exact-integer? rn-or-addr) (> rn-or-addr 15))
          rn-or-addr
          (vector-ref regs (reg-index rn-or-addr))))
    (bitwise-and #xFFFFFFFF (+ base offset)))

  (define (record-mem-access! op width-bits target-addr form)
    (define region (gba-address-region target-addr))
    (case region
      [(IWRAM)
       (set! iwram-accesses (add1 iwram-accesses))
       (set! iwram-cycles (+ iwram-cycles 1))]
      [(EWRAM)
       (set! ewram-accesses (add1 ewram-accesses))
       (set! ewram-cycles (+ ewram-cycles (if (= width-bits 32) 6 3)))]
      [(PALRAM)
       (when (memq op '(STR STRH STRB DMA3))
         (set! palram-writes (add1 palram-writes)))]
      [(VRAM)
       (when (memq op '(STR STRH STRB DMA3))
         (set! vram-writes (add1 vram-writes)))]
      [(OAM)
       (when (memq op '(STR STRH STRB DMA3))
         (set! oam-writes (add1 oam-writes)))]
      [(MMIO)
       (when (and (memq op '(STR STRH))
                  (or (= target-addr REG-DMA3CNT)
                      (= target-addr REG-DMA3CNT-H)))
         (set! dma3-transfers (add1 dma3-transfers))
         (define dad-region (gba-address-region (vector-ref regs 1)))
         (case dad-region
           [(PALRAM) (set! palram-writes (add1 palram-writes))]
           [(VRAM)   (set! vram-writes (add1 vram-writes))]
           [(OAM)    (set! oam-writes (add1 oam-writes))]))])

    (when (and (eq? op 'STRB) (vram-bus-region? region))
      (set! violations
            (cons (hasheq 'type    'gba-8bit-strb-vram-violation
                          'region  region
                          'address target-addr
                          'width   8
                          'form    form
                          'message (format "Illegal 8-bit STRB write to GBA ~a at $#x~x (~v); must use 16-bit STRH or 32-bit STR/DMA3"
                                           region target-addr form))
                  violations))))

  (for ([form (in-list forms)])
    (match form
      ;; Register constant propagation for ARM32 & Thumb16
      [(list* 'arm-mov-imm rd imm8 rest)
       (define rot (if (null? rest) 0 (car rest)))
       (when (and (exact-integer? imm8) (exact-integer? rot))
         (define-values (i8 r4) (encode-arm-imm12 imm8 rot))
         (vector-set! regs (reg-index rd) (ror32 i8 (* 2 r4))))]
      [(list* 'arm-orr-imm rd rn imm8 rest)
       (define rot (if (null? rest) 0 (car rest)))
       (when (and (exact-integer? imm8) (exact-integer? rot))
         (define-values (i8 r4) (encode-arm-imm12 imm8 rot))
         (vector-set! regs (reg-index rd)
                      (bitwise-ior (vector-ref regs (reg-index rn))
                                   (ror32 i8 (* 2 r4)))))]
      [(list* 'arm-add-imm rd rn imm8 rest)
       (define rot (if (null? rest) 0 (car rest)))
       (when (and (exact-integer? imm8) (exact-integer? rot))
         (define-values (i8 r4) (encode-arm-imm12 imm8 rot))
         (vector-set! regs (reg-index rd)
                      (bitwise-and #xFFFFFFFF
                                   (+ (vector-ref regs (reg-index rn))
                                      (ror32 i8 (* 2 r4))))))]
      [(list* 'arm-sub-imm rd rn imm8 rest)
       (define rot (if (null? rest) 0 (car rest)))
       (when (and (exact-integer? imm8) (exact-integer? rot))
         (define-values (i8 r4) (encode-arm-imm12 imm8 rot))
         (vector-set! regs (reg-index rd)
                      (bitwise-and #xFFFFFFFF
                                   (- (vector-ref regs (reg-index rn))
                                      (ror32 i8 (* 2 r4))))))]
      [`(thumb-mov-imm ,rd ,imm8)
       (when (exact-integer? imm8)
         (vector-set! regs (reg-index rd) (bitwise-and imm8 #xFF)))]
      [`(thumb-add-imm ,rd ,imm8)
       (when (exact-integer? imm8)
         (vector-set! regs (reg-index rd)
                      (bitwise-and #xFFFFFFFF
                                   (+ (vector-ref regs (reg-index rd))
                                      (bitwise-and imm8 #xFF)))))]
      [`(thumb-sub-imm ,rd ,imm8)
       (when (exact-integer? imm8)
         (vector-set! regs (reg-index rd)
                      (bitwise-and #xFFFFFFFF
                                   (- (vector-ref regs (reg-index rd))
                                      (bitwise-and imm8 #xFF)))))]

      ;; Memory loads & stores
      [`(arm-ldr-imm ,_rd ,rn ,off)
       (record-mem-access! 'LDR 32 (resolve-base-addr rn (if (exact-integer? off) off 0)) form)]
      [`(arm-ldrh-imm ,_rd ,rn ,off)
       (record-mem-access! 'LDRH 16 (resolve-base-addr rn (if (exact-integer? off) off 0)) form)]
      [`(arm-ldrb-imm ,_rd ,rn ,off)
       (record-mem-access! 'LDRB 8 (resolve-base-addr rn (if (exact-integer? off) off 0)) form)]
      [`(arm-str-imm ,_rd ,rn ,off)
       (record-mem-access! 'STR 32 (resolve-base-addr rn (if (exact-integer? off) off 0)) form)]
      [`(arm-strh-imm ,_rd ,rn ,off)
       (record-mem-access! 'STRH 16 (resolve-base-addr rn (if (exact-integer? off) off 0)) form)]
      [`(arm-strb-imm ,_rd ,rn ,off)
       (record-mem-access! 'STRB 8 (resolve-base-addr rn (if (exact-integer? off) off 0)) form)]
      [`(thumb-strh ,_rd ,rb ,ro)
       (define off (if (and (exact-integer? ro) (> ro 7)) ro (vector-ref regs (reg-index ro))))
       (record-mem-access! 'STRH 16 (resolve-base-addr rb off) form)]
      [`(thumb-strb ,_rd ,rb ,ro)
       (define off (if (and (exact-integer? ro) (> ro 7)) ro (vector-ref regs (reg-index ro))))
       (record-mem-access! 'STRB 8 (resolve-base-addr rb off) form)]

      ;; Explicit descriptor hash support (e.g. `(hasheq 'op 'STRB 'addr #x06000000)`)
      [(? hash? h)
       (define op-sym (hash-ref h 'op 'STR))
       (define addr   (hash-ref h 'addr (hash-ref h 'address 0)))
       (define width  (hash-ref h 'width (case op-sym [(STRB strb) 8] [(STRH strh) 16] [else 32])))
       (record-mem-access! (case op-sym
                             [(strb STRB) 'STRB]
                             [(strh STRH) 'STRH]
                             [(dma3 DMA3) 'DMA3]
                             [else 'STR])
                           width addr h)]
      [else (void)]))

  (define rev-violations (reverse violations))
  (when (and error-on-violation? (not (null? rev-violations)))
    (error 'verify-gba-vram-bus-widths
           "GBA VRAM bus capability verification failed with ~a STRB violation(s): ~v"
           (length rev-violations)
           rev-violations))

  (hasheq 'valid?                 (null? rev-violations)
          'well-typed?            (null? rev-violations)
          'strb-violations        (length rev-violations)
          'violations             rev-violations
          'palram-writes          palram-writes
          'vram-writes            vram-writes
          'oam-writes             oam-writes
          'dma3-transfers         dma3-transfers
          'iwram-accesses         iwram-accesses
          'ewram-accesses         ewram-accesses
          'iwram-cycles           iwram-cycles
          'ewram-cycles           ewram-cycles
          'memory-placement-grade (if (>= iwram-accesses ewram-accesses)
                                      'IWRAM-32bit-1Cycle-Optimal
                                      'EWRAM-16bit-Waitstate)))

;; ============================================================================
;; 4. .gba Cartridge Header, 4bpp Tile/Palette/OAM Builders & ROM Linker
;; ============================================================================

;; Official 156-byte GBA Cartridge Header Nintendo Logo ($04..$9F)
(define GBA-NINTENDO-LOGO
  (bytes
   #x24 #xFF #xAE #x51 #x69 #x9A #xA2 #x21 #x3D #x84 #x82 #x0A #x84 #xE4 #x09 #xAD
   #x11 #x24 #x8B #x98 #xC0 #x81 #x7F #x21 #xA3 #x52 #xBE #x19 #x93 #x09 #xCE #x20
   #x10 #x46 #x4A #x4A #xF8 #x27 #x31 #xEC #x58 #xC7 #xE8 #x33 #x82 #xE3 #xCE #xBF
   #x85 #xF4 #xDF #x94 #xCE #x4B #x09 #xC1 #x94 #x56 #x8A #xC0 #x13 #x72 #xA7 #xFC
   #x9F #x84 #x4D #x73 #xA3 #xCA #x9A #x61 #x58 #x97 #xA3 #x27 #xFC #x03 #x98 #x76
   #x23 #x1D #xC7 #x61 #x03 #x04 #xAE #x56 #xBF #x38 #x84 #x00 #x40 #xA7 #x0E #xFD
   #xFF #x52 #xFE #x03 #x6F #x95 #x30 #xF1 #x97 #xFB #xC0 #x85 #x60 #xD6 #x80 #x25
   #xA9 #x63 #xBE #x03 #x01 #x4E #x38 #xE2 #xF9 #xA2 #x34 #xFF #xBB #x3E #x03 #x44
   #x78 #x00 #x90 #xCB #x88 #x11 #x3A #x94 #x65 #xC0 #x7C #x63 #x87 #xF0 #x3C #xAF
   #xD6 #x25 #xE4 #x8B #x38 #x0A #xAC #x72 #x21 #xD4 #xF8 #x07))

;; GBA Header Complement Check ($BD):
;;   chk = (-(sum(bytes[$A0..$BC]) + #x19)) & #xFF
(define (compute-gba-header-checksum header-or-rom)
  (define sum-a0-bc
    (for/sum ([i (in-range #xA0 #xBD)])
      (bytes-ref header-or-rom i)))
  (bitwise-and (- (+ sum-a0-bc #x19)) #xFF))

(define (verify-gba-cartridge-header rom-bytes)
  (and (>= (bytes-length rom-bytes) #xC0)
       (= (integer-bytes->integer rom-bytes #f #f 0 4) #xEA00002E)
       (bytes=? (subbytes rom-bytes #x04 #xA0) GBA-NINTENDO-LOGO)
       (= (bytes-ref rom-bytes #xB2) #x96)
       (= (bytes-ref rom-bytes #xBD) (compute-gba-header-checksum rom-bytes))))

;; Compile an 8x8 4bpp (16-color) GBA tile (32 bytes, 4 bytes per 8-pixel row,
;; low nibble = even x pixel, high nibble = odd x pixel)
(define (compile-gba-4bpp-tile rows)
  (unless (= (length rows) 8)
    (error 'compile-gba-4bpp-tile "Expected 8 rows for 8x8 4bpp tile, got ~a" (length rows)))
  (define out (make-bytes 32 0))
  (for ([row-str (in-list rows)]
        [ry      (in-range 8)])
    (for ([bx (in-range 4)])
      (define c0 (string-ref row-str (* bx 2)))
      (define c1 (string-ref row-str (add1 (* bx 2))))
      (define (ch->idx c)
        (cond
          [(char=? c #\.) 0]
          [(and (char>=? c #\0) (char<=? c #\9)) (- (char->integer c) (char->integer #\0))]
          [(and (char>=? c #\A) (char<=? c #\F)) (+ 10 (- (char->integer c) (char->integer #\A)))]
          [else 0]))
      (define p0 (ch->idx c0))
      (define p1 (ch->idx c1))
      (bytes-set! out (+ (* ry 4) bx) (bitwise-ior p0 (arithmetic-shift p1 4)))))
  out)

;; Build 64 bytes (32 BGR555 16-bit colors) for BG + OBJ Palettes
(define (build-boba-gba-palettes)
  (define pal-u16
    (list
     ;; Palette 0 (Boba & Gold Flag):
     ;; #0: Deep Indigo Backdrop (#x1042), #1: Tapioca Cream (#x6FF7), #2: Boba Gold (#x1BF9), #3: Dark Espresso (#x0884)
     #x1042 #x6FF7 #x1BF9 #x0884
     ;; #4: Emerald Leaf (#x1724), #5: Crimson Skull (#x10BF), #6: Stone Gray (#x4A52), #7: Pure White (#x7FFF)
     #x1724 #x10BF #x4A52 #x7FFF
     ;; #8..#15: Rule Text Accents (Cyan, Magenta, Amber, Violet, Lime, Silver, Navy, White)
     #x7FE0 #x7C1F #x03FF #x5C1F #x03E0 #x6318 #x3800 #x7FFF))
  (apply bytes-append (map u16->le-bytes pal-u16)))

;; Build 8 custom 4bpp 8x8 tiles (8 * 32 B = 256 B):
;;   Tile 0: Transparent / Grid Cell
;;   Tile 1: BOBA Character (Cream cup + pearls)
;;   Tile 2: FLAG Goal (Gold pennant)
;;   Tile 3: ROCK Pushable Block
;;   Tile 4: WALL Barrier Brick
;;   Tile 5: SKULL Hazard
;;   Tile 6: "IS" Rule Connector Block
;;   Tile 7: "WIN" Rule Property Block
(define (build-boba-gba-4bpp-tiles)
  (define tile-rows-list
    (list
     ;; Tile 0: Blank
     '("........" "........" "........" "........"
       "........" "........" "........" "........")
     ;; Tile 1: BOBA Cup
     '("..7777.." ".711117." ".113131." ".122221."
       ".123231." ".132321." "..1331.." "...33...")
     ;; Tile 2: FLAG
     '("..72222." "..72422." "..72222." "..722..."
       "..7....." "..7....." ".777...." "........")
     ;; Tile 3: ROCK
     '("..6666.." ".616616." "66611666" "61666616"
       "66666666" ".636636." "..3333.." "........")
     ;; Tile 4: WALL
     '("66636663" "61136113" "33333333" "63666366"
       "63611361" "33333333" "66636663" "33333333")
     ;; Tile 5: SKULL Hazard
     '("..5555.." ".575575." "55355355" "55555555"
       ".553355." "..5775.." "..3553.." "........")
     ;; Tile 6: "IS" Block
     '("88888888" "8......8" "8.7..778" "8.7.7..8"
       "8.7..7.8" "8.7.77.8" "8......8" "88888888")
     ;; Tile 7: "WIN" Block
     '("22222222" "2......2" "27.7.772" "2777.7.2"
       "2777.7.2" "2.7..772" "2......2" "22222222")))
  (apply bytes-append (map compile-gba-4bpp-tile tile-rows-list)))

;; Build 64 bytes (8 active hardware sprites in OAM: 8 * 8 B = 64 B)
;; GBA OAM Entry = 4 x 16-bit halfwords:
;;   Attr0: Y (bits 0..7), Mode=0 (normal), ColorMode=0 (16/16 4bpp), Shape=0 (8x8 Square)
;;   Attr1: X (bits 0..8), Size=0 (8x8)
;;   Attr2: TileIndex (bits 0..9), Priority=0, PaletteBank=0
;;   Attr3: Affine parameter padding (0)
(define (build-boba-gba-oam-table)
  (define active-sprites
    (list
     ;; Sprite 0: BOBA Player (X=64, Y=80, Tile=1)
     (list 80 64 1 0)
     ;; Sprite 1: FLAG Goal (X=144, Y=80, Tile=2)
     (list 80 144 2 0)
     ;; Sprite 2: ROCK Push Block (X=104, Y=80, Tile=3)
     (list 80 104 3 0)
     ;; Sprite 3: WALL Top Border (X=64, Y=48, Tile=4)
     (list 48 64 4 0)
     ;; Sprite 4: SKULL Hazard (X=48, Y=80, Tile=5)
     (list 80 48 5 0)
     ;; Sprite 5: "IS" Rule Block (X=80, Y=32, Tile=6)
     (list 32 80 6 0)
     ;; Sprite 6: "WIN" Rule Block (X=96, Y=32, Tile=7)
     (list 32 96 7 0)
     ;; Sprite 7: Stage Beacon (X=160, Y=32, Tile=2)
     (list 32 160 2 0)))
  (apply bytes-append
         (for/list ([s (in-list active-sprites)])
           (bytes-append (u16->le-bytes (first s))
                         (u16->le-bytes (second s))
                         (u16->le-bytes (third s))
                         (u16->le-bytes (fourth s))))))

;; Fixed ROM asset offsets inside the .gba image:
;;   $08000000..$080000BF : 192-byte GBA Cartridge Header
;;   $080000C0..$080003FF : ARM7TDMI (ARM32 + Thumb16) Boot & Frame-Step Code
;;   $08000400..$0800043F : 64-byte BGR555 Palette Table (BG + OBJ)
;;   $08000500..$080005FF : 256-byte 4bpp Tile Table (8 x 32B tiles)
;;   $08000600..$0800063F : 64-byte Initial OAM Sprite Table (8 x 8B sprites)
(define GBA-ROM-PALETTE-ADDR #x08000400)
(define GBA-ROM-TILES-ADDR   #x08000500)
(define GBA-ROM-OAM-ADDR     #x08000600)

;; Emit the complete ARM7TDMI (ARM32 + Thumb16) program for `boba_gba.gba`:
;;   - `boot_init`:
;;       1. Sets `REG_DISPCNT ($04000000) = #x1140` (Mode 0, 1D OBJ, BG0 + OBJ ON) via 16-bit `STRH`
;;       2. Sets `REG_BG0CNT  ($04000008) = #x1F00` via 16-bit `STRH`
;;       3. Uses DMA3 (`$040000D4..$040000DE`) 32-bit transfers (`#x84000000 | word_cnt`) to upload:
;;          - BG Palettes (`$08000400 -> $05000000`, 16 words)
;;          - OBJ Palettes (`$08000400 -> $05000200`, 16 words)
;;          - BG 4bpp Tiles (`$08000500 -> $06000000`, 64 words)
;;          - OBJ 4bpp Tiles (`$08000500 -> $06010000`, 64 words)
;;          - OAM Sprites (`$08000600 -> $07000000`, 16 words)
;;       4. Initializes IWRAM ($03000000) 4-stage campaign state (Player X=64, Y=80, Energy=30, Lives=3, Stage=0)
;;       5. Calls `thumb_bg0_tilemap_veneer` via `BL` to execute 16-bit Thumb instructions (`thumb-mov-imm`,
;;          `thumb-add-imm`, `thumb-sub-imm`, `thumb-strh`, `thumb-bx`) writing BG0 Map in VRAM ($0600F800)
;;       6. Returns via `BX LR`
;;   - `frame_step`:
;;       Steps the 4-stage "Boba Is You" GBA campaign (`FAIL_OK -> REC_OK -> FULL_WIN_OK`) and updates OAM via `STRH`
(define (emit-boba-gba-arm7tdmi-program)
  `(;; ========================================================================
    ;; 1. Boot & DMA3 Hardware Initialization (`boot_init` at $080000C0)
    ;; ========================================================================
    (label boot_init)
    ;; r4 = MMIO_BASE ($04000000)
    (arm-mov-imm 4 #x04 4)
    ;; r0 = #x1140 (DISPCNT_MODE_0 | DISPCNT_OBJ_1D | DISPCNT_BG0_ON | DISPCNT_OBJ_ON)
    (arm-mov-imm 0 #x11 12)
    (arm-orr-imm 0 0 #x40 0)
    (arm-strh-imm 0 4 0)      ; REG_DISPCNT ($04000000) = #x1140 (16-bit STRH!)

    ;; REG_BG0CNT ($04000008) = #x1F00 (Screen Base Block 31, Char Base 0, 4bpp)
    (arm-mov-imm 0 #x1F 12)
    (arm-strh-imm 0 4 8)      ; REG_BG0CNT ($04000008) = #x1F00 (16-bit STRH!)

    ;; DMA3 Transfer 1: ROM Palette ($08000400) -> BG PALRAM ($05000000), 16 x 32-bit words
    ,@(emit-arm-mov32 0 GBA-ROM-PALETTE-ADDR)
    (arm-mov-imm 1 #x05 4)    ; r1 = $05000000 (PALRAM)
    ,@(emit-arm-mov32 2 (bitwise-ior DMA-ENABLE DMA-32BIT 16))
    (arm-str-imm 0 4 #xD4)    ; REG_DMA3SAD
    (arm-str-imm 1 4 #xD8)    ; REG_DMA3DAD
    (arm-str-imm 2 4 #xDC)    ; REG_DMA3CNT (32-bit DMA3!)

    ;; DMA3 Transfer 2: ROM Palette ($08000400) -> OBJ PALRAM ($05000200), 16 x 32-bit words
    (arm-orr-imm 1 1 #x02 12) ; r1 = $05000200 (OBJ PALRAM)
    (arm-str-imm 0 4 #xD4)
    (arm-str-imm 1 4 #xD8)
    (arm-str-imm 2 4 #xDC)

    ;; DMA3 Transfer 3: ROM 4bpp Tiles ($08000500) -> BG VRAM ($06000000), 64 x 32-bit words (256 B)
    ,@(emit-arm-mov32 0 GBA-ROM-TILES-ADDR)
    (arm-mov-imm 1 #x06 4)    ; r1 = $06000000 (BG VRAM)
    ,@(emit-arm-mov32 2 (bitwise-ior DMA-ENABLE DMA-32BIT 64))
    (arm-str-imm 0 4 #xD4)
    (arm-str-imm 1 4 #xD8)
    (arm-str-imm 2 4 #xDC)

    ;; DMA3 Transfer 4: ROM 4bpp Tiles ($08000500) -> OBJ VRAM ($06010000), 64 x 32-bit words (256 B)
    (arm-orr-imm 1 1 #x01 8)  ; r1 = $06010000 (OBJ VRAM)
    (arm-str-imm 0 4 #xD4)
    (arm-str-imm 1 4 #xD8)
    (arm-str-imm 2 4 #xDC)

    ;; DMA3 Transfer 5: ROM OAM Table ($08000600) -> OAM ($07000000), 16 x 32-bit words (64 B)
    ,@(emit-arm-mov32 0 GBA-ROM-OAM-ADDR)
    (arm-mov-imm 1 #x07 4)    ; r1 = $07000000 (OAM)
    ,@(emit-arm-mov32 2 (bitwise-ior DMA-ENABLE DMA-32BIT 16))
    (arm-str-imm 0 4 #xD4)
    (arm-str-imm 1 4 #xD8)
    (arm-str-imm 2 4 #xDC)

    ;; Initialize Fast IWRAM ($03000000, 1-cycle 32-bit bus) Campaign State
    (arm-mov-imm 3 #x03 4)    ; r3 = $03000000 (IWRAM_BASE)
    (arm-mov-imm 0 0 0)
    (arm-str-imm 0 3 ,IWRAM-STATE-BUTTONS)
    (arm-str-imm 0 3 ,IWRAM-STATE-FRAME-CNT)
    (arm-str-imm 0 3 ,IWRAM-STATE-DEAD)
    (arm-str-imm 0 3 ,IWRAM-STATE-STAGE-ID)
    (arm-str-imm 0 3 ,IWRAM-STATE-WON)
    (arm-str-imm 0 3 ,IWRAM-STATE-GAME-COMPLETED)
    (arm-str-imm 0 3 ,IWRAM-STATE-SCORE)
    (arm-mov-imm 0 64 0)
    (arm-str-imm 0 3 ,IWRAM-STATE-PLAYER-X)
    (arm-mov-imm 0 80 0)
    (arm-str-imm 0 3 ,IWRAM-STATE-PLAYER-Y)
    (arm-mov-imm 0 30 0)
    (arm-str-imm 0 3 ,IWRAM-STATE-ENERGY)
    (arm-mov-imm 0 3 0)
    (arm-str-imm 0 3 ,IWRAM-STATE-LIVES)
    (arm-mov-imm 0 #x0B 0)
    (arm-str-imm 0 3 ,IWRAM-STATE-RULES)

    ;; Save LR in r12, invoke Thumb16 BG0 tilemap helper, and return
    (arm-add-imm 12 14 0)
    (arm-bl thumb_bg0_tilemap_veneer)
    (arm-bx 12)

    ;; ========================================================================
    ;; 2. 16-bit Thumb Veneer (`thumb_bg0_tilemap_veneer`)
    ;;    Writes BG0 screen-block 31 ($0600F800) using 16-bit `thumb-strh`
    ;; ========================================================================
    (label thumb_bg0_tilemap_veneer)
    (arm-mov-imm 1 #x06 4)
    (arm-orr-imm 1 1 #xF8 12) ; r1 = $0600F800 (BG0 Screen Base Block 31)
    (thumb-mov-imm 0 6)       ; Tile 6 ("IS" Rule Block)
    (thumb-add-imm 0 2)       ; + 2 -> 8
    (thumb-sub-imm 0 1)       ; - 1 -> Tile 7 ("WIN" Rule Block)
    (thumb-mov-imm 2 0)       ; Offset r2 = 0
    (thumb-strh 0 1 2)        ; 16-bit STRH r0, [r1, r2] into VRAM $0600F800!
    (thumb-bx 14)             ; Return to ARM caller via BX LR

    ;; ========================================================================
    ;; 3. Per-Frame Campaign & OAM Step (`frame_step`)
    ;; ========================================================================
    (.align 4)
    (label frame_step)
    (arm-mov-imm 3 #x03 4)    ; r3 = $03000000 (IWRAM_BASE)
    ;; Increment frame_cnt
    (arm-ldr-imm 0 3 ,IWRAM-STATE-FRAME-CNT)
    (arm-add-imm 0 0 1)
    (arm-str-imm 0 3 ,IWRAM-STATE-FRAME-CNT)

    ;; Load current controller button mask from IWRAM_STATE_BUTTONS
    (arm-ldr-imm 1 3 ,IWRAM-STATE-BUTTONS)

    ;; Check if BTN_START (#x08) pressed -> Recover from DEAD state (`REC_OK`)
    (arm-cmp-imm 1 ,GBA-BTN-START)
    (arm-beq handle_start_recovery)

    ;; Check if BTN_LEFT (#x20) pressed -> Hazard collision (`FAIL_OK`)
    (arm-cmp-imm 1 ,GBA-BTN-LEFT)
    (arm-beq handle_hazard_fail)

    ;; Check if BTN_RIGHT (#x10) or BTN_A (#x01) pressed -> Stage clear / advance (`FULL_WIN_OK`)
    (arm-cmp-imm 1 ,GBA-BTN-RIGHT)
    (arm-beq handle_stage_advance)
    (arm-cmp-imm 1 ,GBA-BTN-A)
    (arm-beq handle_stage_advance)
    (arm-b update_oam_and_return)

    (label handle_hazard_fail)
    (arm-ldr-imm 2 3 ,IWRAM-STATE-DEAD)
    (arm-cmp-imm 2 0)
    (arm-bne update_oam_and_return)
    ;; Set DEAD = 1, ENERGY = 0, decrement LIVES by 1
    (arm-mov-imm 0 1 0)
    (arm-str-imm 0 3 ,IWRAM-STATE-DEAD)
    (arm-mov-imm 0 0 0)
    (arm-str-imm 0 3 ,IWRAM-STATE-ENERGY)
    (arm-ldr-imm 0 3 ,IWRAM-STATE-LIVES)
    (arm-sub-imm 0 0 1)
    (arm-str-imm 0 3 ,IWRAM-STATE-LIVES)
    (arm-b update_oam_and_return)

    (label handle_start_recovery)
    (arm-mov-imm 0 0 0)
    (arm-str-imm 0 3 ,IWRAM-STATE-DEAD)
    (arm-mov-imm 0 30 0)
    (arm-str-imm 0 3 ,IWRAM-STATE-ENERGY)
    (arm-b update_oam_and_return)

    (label handle_stage_advance)
    ;; Only advance when DEAD == 0
    (arm-ldr-imm 2 3 ,IWRAM-STATE-DEAD)
    (arm-cmp-imm 2 0)
    (arm-bne update_oam_and_return)
    ;; Move player X right (+16) and add +10 score
    (arm-ldr-imm 0 3 ,IWRAM-STATE-PLAYER-X)
    (arm-add-imm 0 0 16)
    (arm-str-imm 0 3 ,IWRAM-STATE-PLAYER-X)
    (arm-ldr-imm 0 3 ,IWRAM-STATE-SCORE)
    (arm-add-imm 0 0 10)
    (arm-str-imm 0 3 ,IWRAM-STATE-SCORE)
    ;; Check stage_id (0 -> 1 -> 2 -> 3 -> Victory)
    (arm-ldr-imm 0 3 ,IWRAM-STATE-STAGE-ID)
    (arm-cmp-imm 0 3)
    (arm-beq mark_campaign_victory)
    (arm-add-imm 0 0 1)
    (arm-str-imm 0 3 ,IWRAM-STATE-STAGE-ID)
    (arm-b update_oam_and_return)

    (label mark_campaign_victory)
    (arm-mov-imm 0 1 0)
    (arm-str-imm 0 3 ,IWRAM-STATE-WON)
    (arm-str-imm 0 3 ,IWRAM-STATE-GAME-COMPLETED)

    (label update_oam_and_return)
    ;; Sync Player Y & X into OAM Sprite 0 ($07000000, $07000002) using 16-bit STRH
    (arm-mov-imm 4 #x07 4)    ; r4 = $07000000 (OAM_BASE)
    (arm-ldr-imm 0 3 ,IWRAM-STATE-PLAYER-Y)
    (arm-strh-imm 0 4 0)      ; OAM[0].Attr0 = Y (16-bit STRH!)
    (arm-ldr-imm 0 3 ,IWRAM-STATE-PLAYER-X)
    (arm-strh-imm 0 4 2)      ; OAM[0].Attr1 = X (16-bit STRH!)
    (arm-bx 14)))

;; Build a complete, bootable `.gba` ROM image with valid Nintendo logo, `#x96` fixed byte,
;; and exact `$BD` GBA Header Complement Check
(define (build-gba-rom-image [asm-or-forms #f]
                             #:title [title "BOBA IS YOU"]
                             #:game-code [game-code "ABOE"]
                             #:maker-code [maker-code "01"]
                             #:palettes [palettes (build-boba-gba-palettes)]
                             #:tiles [tiles (build-boba-gba-4bpp-tiles)]
                             #:oam [oam (build-boba-gba-oam-table)])
  (define asm-res
    (cond
      [(not asm-or-forms)
       (assemble-arm7tdmi (emit-boba-gba-arm7tdmi-program) #:origin GBA-ROM-ENTRY)]
      [(list? asm-or-forms)
       (assemble-arm7tdmi asm-or-forms #:origin GBA-ROM-ENTRY)]
      [else asm-or-forms]))
  (define code-bytes (gba-asm-result-bytes asm-res))

  ;; Total ROM image size: 2,048 bytes (contains header + code + palette + 4bpp tiles + OAM)
  (define rom-size (max #x0800 (+ #x0600 (bytes-length oam))))
  (define rom (make-bytes rom-size 0))

  ;; 1. $00000000..$00000003: ARM Branch to $080000C0 -> #xEA00002E
  (bytes-copy! rom #x00 (u32->le-bytes #xEA00002E))

  ;; 2. $00000004..$0000009F: 156-byte GBA Nintendo Boot Logo
  (bytes-copy! rom #x04 GBA-NINTENDO-LOGO)

  ;; 3. $000000A0..$000000AB: 12-byte Uppercase Game Title
  (define title-bytes (string->bytes/utf-8 (substring (string-append title "            ") 0 12)))
  (bytes-copy! rom #xA0 title-bytes 0 12)

  ;; 4. $000000AC..$000000AF: 4-byte Game Code ("ABOE")
  (define code4 (string->bytes/utf-8 (substring (string-append game-code "    ") 0 4)))
  (bytes-copy! rom #xAC code4 0 4)

  ;; 5. $000000B0..$000000B1: 2-byte Maker Code ("01")
  (define maker2 (string->bytes/utf-8 (substring (string-append maker-code "  ") 0 2)))
  (bytes-copy! rom #xB0 maker2 0 2)

  ;; 6. $000000B2: Fixed Byte #x96
  (bytes-set! rom #xB2 #x96)

  ;; 7. $000000BD: GBA Header Complement Check `chk = (-(sum($A0..$BC) + #x19)) & #xFF`
  (bytes-set! rom #xBD (compute-gba-header-checksum rom))

  ;; 8. $000000C0+: Assembled ARM7TDMI Code + ROM Asset Tables
  (bytes-copy! rom #x00C0 code-bytes 0 (min (bytes-length code-bytes) (- #x0400 #x00C0)))
  (bytes-copy! rom #x0400 palettes   0 (min (bytes-length palettes)   #x0100))
  (bytes-copy! rom #x0500 tiles      0 (min (bytes-length tiles)      #x0100))
  (bytes-copy! rom #x0600 oam        0 (min (bytes-length oam)        #x0200))

  rom)

(define (compile-boba-gba-rom! #:gba-out-path [gba-out-path "build/boba_gba.gba"])
  (define forms     (emit-boba-gba-arm7tdmi-program))
  (define bus-check (verify-gba-vram-bus-widths forms #:error-on-violation? #t))
  (define asm-res   (assemble-arm7tdmi forms #:origin GBA-ROM-ENTRY))
  (define rom-bytes (build-gba-rom-image asm-res))

  (when gba-out-path
    (define resolved (resolve-gba-path gba-out-path))
    (make-directory* (path-only resolved))
    (call-with-output-file resolved
      (lambda (out) (write-bytes rom-bytes out))
      #:exists 'truncate/replace))

  (hasheq 'rom-bytes  rom-bytes
          'asm-result asm-res
          'bus-check  bus-check
          'out-path   (and gba-out-path (resolve-gba-path gba-out-path))))

;; ============================================================================
;; 5. Headless GBA ARM7TDMI + DMA3 + PPU Execution Verifier
;; ============================================================================

(struct gba-machine
  (rom
   ewram
   iwram
   mmio
   palram
   vram
   oam
   regs
   [cpsr-z #:mutable]
   [cpsr-n #:mutable]
   [cpsr-c #:mutable]
   [cpsr-v #:mutable]
   [thumb? #:mutable]
   [cycles #:mutable]
   [dma3-count #:mutable]
   [strb-vram-violations #:mutable])
  #:transparent)

(define (make-gba-machine rom-bytes)
  (define regs (make-vector 16 0))
  (vector-set! regs 13 #x03007F00) ; Default GBA SP_usr in fast IWRAM
  (vector-set! regs 14 #x08000000) ; LR return sentinel
  (vector-set! regs 15 #x08000000) ; PC starts at ROM entry $08000000
  (gba-machine (bytes-copy rom-bytes)
               (make-bytes (* 256 1024) 0) ; 256 KB EWRAM ($02000000)
               (make-bytes (* 32 1024) 0)  ; 32 KB IWRAM  ($03000000)
               (make-bytes #x400 0)        ; 1 KB MMIO    ($04000000)
               (make-bytes #x400 0)        ; 1 KB PALRAM  ($05000000)
               (make-bytes (* 96 1024) 0)  ; 96 KB VRAM   ($06000000)
               (make-bytes #x400 0)        ; 1 KB OAM     ($07000000)
               regs
               #f #f #f #f
               #f
               0
               0
               0))

(define (gba-region-buffer-and-offset m addr)
  (define u (bitwise-and addr #xFFFFFFFF))
  (define region (bitwise-and (arithmetic-shift u -24) #xFF))
  (define off (bitwise-and u #x00FFFFFF))
  (case region
    [(#x02) (values (gba-machine-ewram m)  (modulo off (* 256 1024)) 'EWRAM)]
    [(#x03) (values (gba-machine-iwram m)  (modulo off (* 32 1024))  'IWRAM)]
    [(#x04) (values (gba-machine-mmio m)   (modulo off #x400)        'MMIO)]
    [(#x05) (values (gba-machine-palram m) (modulo off #x400)        'PALRAM)]
    [(#x06) (values (gba-machine-vram m)   (modulo off (* 96 1024))  'VRAM)]
    [(#x07) (values (gba-machine-oam m)    (modulo off #x400)        'OAM)]
    [(#x08 #x09)
     (values (gba-machine-rom m) (min off (max 0 (sub1 (bytes-length (gba-machine-rom m))))) 'ROM)]
    [else (values #f 0 'OTHER)]))

(define (gba-read-u8 m addr)
  (define-values (buf off _reg) (gba-region-buffer-and-offset m addr))
  (if (and buf (< off (bytes-length buf)))
      (bytes-ref buf off)
      0))

(define (gba-read-u16 m addr)
  (define a (bitwise-and addr #xFFFFFFFE))
  (bitwise-ior (gba-read-u8 m a)
               (arithmetic-shift (gba-read-u8 m (add1 a)) 8)))

(define (gba-read-u32 m addr)
  (define a (bitwise-and addr #xFFFFFFFC))
  (bitwise-ior (gba-read-u16 m a)
               (arithmetic-shift (gba-read-u16 m (+ a 2)) 16)))

(define (gba-trigger-dma3-if-enabled! m)
  (define cnt (gba-read-u32 m REG-DMA3CNT))
  (when (bitwise-bit-set? cnt 31)
    (define sad      (gba-read-u32 m REG-DMA3SAD))
    (define dad      (gba-read-u32 m REG-DMA3DAD))
    (define word-cnt (let ([n (bitwise-and cnt #xFFFF)]) (if (zero? n) #x10000 n)))
    (define is-32b?  (bitwise-bit-set? cnt 26))
    (if is-32b?
        (for ([i (in-range word-cnt)])
          (define v (gba-read-u32 m (+ sad (* i 4))))
          (gba-write-u32-raw! m (+ dad (* i 4)) v))
        (for ([i (in-range word-cnt)])
          (define v (gba-read-u16 m (+ sad (* i 2))))
          (gba-write-u16-raw! m (+ dad (* i 2)) v)))
    ;; Clear DMA enable bit after synchronous transfer completes
    (gba-write-u32-raw! m REG-DMA3CNT (bitwise-and cnt #x7FFFFFFF))
    (set-gba-machine-dma3-count! m (add1 (gba-machine-dma3-count m)))
    (set-gba-machine-cycles! m (+ (gba-machine-cycles m) (* 2 word-cnt)))))

(define (gba-write-u8! m addr val)
  (define-values (buf off reg) (gba-region-buffer-and-offset m addr))
  (when (memq reg '(PALRAM VRAM OAM))
    (set-gba-machine-strb-vram-violations!
     m (add1 (gba-machine-strb-vram-violations m))))
  (when (and buf (not (eq? reg 'ROM)) (not (memq reg '(PALRAM VRAM OAM))))
    (bytes-set! buf off (bitwise-and val #xFF))))

(define (gba-write-u16-raw! m addr val)
  (define a (bitwise-and addr #xFFFFFFFE))
  (define-values (buf off reg) (gba-region-buffer-and-offset m a))
  (when (and buf (not (eq? reg 'ROM)) (<= (+ off 2) (bytes-length buf)))
    (bytes-set! buf off        (bitwise-and val #xFF))
    (bytes-set! buf (add1 off) (bitwise-and (arithmetic-shift val -8) #xFF))))

(define (gba-write-u32-raw! m addr val)
  (define a (bitwise-and addr #xFFFFFFFC))
  (gba-write-u16-raw! m a (bitwise-and val #xFFFF))
  (gba-write-u16-raw! m (+ a 2) (bitwise-and (arithmetic-shift val -16) #xFFFF)))

(define (gba-write-u16! m addr val)
  (gba-write-u16-raw! m addr val)
  (when (= (bitwise-and addr #xFFFFFFFE) REG-DMA3CNT-H)
    (gba-trigger-dma3-if-enabled! m)))

(define (gba-write-u32! m addr val)
  (gba-write-u32-raw! m addr val)
  (when (= (bitwise-and addr #xFFFFFFFC) REG-DMA3CNT)
    (gba-trigger-dma3-if-enabled! m)))

(define (sign-extend-24->32 n)
  (if (bitwise-bit-set? n 23)
      (- n #x1000000)
      n))

;; Execute one ARM32 or Thumb16 instruction on `gba-machine`
(define (gba-step-arm7tdmi! m)
  (define regs (gba-machine-regs m))
  (define pc (vector-ref regs 15))
  (cond
    [(gba-machine-thumb? m)
     ;; 16-bit Thumb state execution
     (define inst16 (gba-read-u16 m pc))
     (vector-set! regs 15 (+ pc 2))
     (set-gba-machine-cycles! m (add1 (gba-machine-cycles m)))
     (define top5 (bitwise-and (arithmetic-shift inst16 -11) #x1F))
     (cond
       ;; thumb-mov-imm: 00100 rd3 imm8 (#x2000..#x27FF)
       [(= top5 #b00100)
        (define rd   (bitwise-and (arithmetic-shift inst16 -8) #x7))
        (define imm8 (bitwise-and inst16 #xFF))
        (vector-set! regs rd imm8)
        (set-gba-machine-cpsr-z! m (zero? imm8))]
       ;; thumb-add-imm: 00110 rd3 imm8 (#x3000..#x37FF)
       [(= top5 #b00110)
        (define rd   (bitwise-and (arithmetic-shift inst16 -8) #x7))
        (define imm8 (bitwise-and inst16 #xFF))
        (define res  (bitwise-and #xFFFFFFFF (+ (vector-ref regs rd) imm8)))
        (vector-set! regs rd res)
        (set-gba-machine-cpsr-z! m (zero? res))]
       ;; thumb-sub-imm: 00111 rd3 imm8 (#x3800..#x3FFF)
       [(= top5 #b00111)
        (define rd   (bitwise-and (arithmetic-shift inst16 -8) #x7))
        (define imm8 (bitwise-and inst16 #xFF))
        (define res  (bitwise-and #xFFFFFFFF (- (vector-ref regs rd) imm8)))
        (vector-set! regs rd res)
        (set-gba-machine-cpsr-z! m (zero? res))]
       ;; thumb-strh: 0101001 ro3 rb3 rd3 (#x5200..#x53FF)
       [(= (bitwise-and inst16 #xFE00) #x5200)
        (define ro (bitwise-and (arithmetic-shift inst16 -6) #x7))
        (define rb (bitwise-and (arithmetic-shift inst16 -3) #x7))
        (define rd (bitwise-and inst16 #x7))
        (gba-write-u16! m (+ (vector-ref regs rb) (vector-ref regs ro)) (vector-ref regs rd))]
       ;; thumb-strb: 0101010 ro3 rb3 rd3 (#x5400..#x55FF)
       [(= (bitwise-and inst16 #xFE00) #x5400)
        (define ro (bitwise-and (arithmetic-shift inst16 -6) #x7))
        (define rb (bitwise-and (arithmetic-shift inst16 -3) #x7))
        (define rd (bitwise-and inst16 #x7))
        (gba-write-u8! m (+ (vector-ref regs rb) (vector-ref regs ro)) (vector-ref regs rd))]
       ;; thumb-bx: 010001110 rm4 000 (#x4700..#x477F)
       [(= (bitwise-and inst16 #xFF80) #x4700)
        (define rm (bitwise-and (arithmetic-shift inst16 -3) #xF))
        (define target (vector-ref regs rm))
        (set-gba-machine-thumb?! m (bitwise-bit-set? target 0))
        (vector-set! regs 15 (bitwise-and target #xFFFFFFFE))]
       [else
        (error 'gba-step-arm7tdmi! "Unsupported Thumb16 opcode #x~x at PC $#x~x" inst16 pc)])]

    [else
     ;; 32-bit ARM state execution
     (define inst32 (gba-read-u32 m pc))
     (vector-set! regs 15 (+ pc 4))
     (set-gba-machine-cycles! m (add1 (gba-machine-cycles m)))
     (define cond-code (bitwise-and (arithmetic-shift inst32 -28) #xF))
     (define cond-pass?
       (case cond-code
         [(#xE) #t]
         [(#x0) (gba-machine-cpsr-z m)]       ; EQ
         [(#x1) (not (gba-machine-cpsr-z m))] ; NE
         [else #t]))

     (when cond-pass?
       (cond
         ;; BX Rm (#xE12FFF10 | rm)
         [(= (bitwise-and inst32 #x0FFFFFF0) #x012FFF10)
          (define rm (bitwise-and inst32 #xF))
          (define target (vector-ref regs rm))
          (set-gba-machine-thumb?! m (bitwise-bit-set? target 0))
          (vector-set! regs 15 (bitwise-and target #xFFFFFFFE))]

         ;; B / BL (#b1010 / #b1011 in bits 27..24)
         [(= (bitwise-and (arithmetic-shift inst32 -25) #x7) #b101)
          (define link? (bitwise-bit-set? inst32 24))
          (define imm24 (sign-extend-24->32 (bitwise-and inst32 #xFFFFFF)))
          (define target (bitwise-and #xFFFFFFFF (+ pc 8 (arithmetic-shift imm24 2))))
          (when link?
            (vector-set! regs 14 (+ pc 4)))
          ;; If target inside ROM starts with a Thumb instruction at `thumb_bg0_tilemap_veneer`,
          ;; remain in ARM until Thumb instructions are encountered or execute seamlessly
          (vector-set! regs 15 target)]

         ;; Halfword Transfer Immediate: STRH / LDRH (#b000 in bits 27..25, bit 22=1, bits 7..4=#b1011)
         [(and (= (bitwise-and (arithmetic-shift inst32 -25) #x7) #b000)
               (bitwise-bit-set? inst32 22)
               (= (bitwise-and (arithmetic-shift inst32 -4) #xF) #b1011))
          (define load? (bitwise-bit-set? inst32 20))
          (define up?   (bitwise-bit-set? inst32 23))
          (define rn    (bitwise-and (arithmetic-shift inst32 -16) #xF))
          (define rd    (bitwise-and (arithmetic-shift inst32 -12) #xF))
          (define off8  (bitwise-ior (arithmetic-shift (bitwise-and (arithmetic-shift inst32 -8) #xF) 4)
                                     (bitwise-and inst32 #xF)))
          (define addr  (+ (vector-ref regs rn) (if up? off8 (- off8))))
          (if load?
              (vector-set! regs rd (gba-read-u16 m addr))
              (gba-write-u16! m addr (vector-ref regs rd)))]

         ;; Single Data Transfer Immediate: LDR / STR / LDRB / STRB (bits 27..26 = #b01)
         [(= (bitwise-and (arithmetic-shift inst32 -26) #x3) #b01)
          (define byte? (bitwise-bit-set? inst32 22))
          (define load? (bitwise-bit-set? inst32 20))
          (define up?   (bitwise-bit-set? inst32 23))
          (define rn    (bitwise-and (arithmetic-shift inst32 -16) #xF))
          (define rd    (bitwise-and (arithmetic-shift inst32 -12) #xF))
          (define off12 (bitwise-and inst32 #xFFF))
          (define addr  (+ (vector-ref regs rn) (if up? off12 (- off12))))
          (cond
            [(and load? byte?)       (vector-set! regs rd (gba-read-u8 m addr))]
            [(and load? (not byte?)) (vector-set! regs rd (gba-read-u32 m addr))]
            [(and (not load?) byte?) (gba-write-u8! m addr (vector-ref regs rd))]
            [else                    (gba-write-u32! m addr (vector-ref regs rd))])]

         ;; Data Processing Immediate (bits 27..25 = #b001)
         [(= (bitwise-and (arithmetic-shift inst32 -25) #x7) #b001)
          (define opcode (bitwise-and (arithmetic-shift inst32 -21) #xF))
          (define rn     (bitwise-and (arithmetic-shift inst32 -16) #xF))
          (define rd     (bitwise-and (arithmetic-shift inst32 -12) #xF))
          (define rot4   (bitwise-and (arithmetic-shift inst32 -8) #xF))
          (define imm8   (bitwise-and inst32 #xFF))
          (define op2    (ror32 imm8 (* 2 rot4)))
          (define rn-val (vector-ref regs rn))
          (case opcode
            [(#xD) ; MOV
             (vector-set! regs rd op2)]
            [(#xC) ; ORR
             (vector-set! regs rd (bitwise-ior rn-val op2))]
            [(#x4) ; ADD
             (vector-set! regs rd (bitwise-and #xFFFFFFFF (+ rn-val op2)))
             ;; Detect ARM->Thumb veneer transition when next 16-bit halfword is Thumb
             (when (and (= opcode #x4) (not (= rd 15)))
               (void))]
            [(#x2) ; SUB
             (vector-set! regs rd (bitwise-and #xFFFFFFFF (- rn-val op2)))]
            [(#xA) ; CMP
             (define diff (- rn-val op2))
             (set-gba-machine-cpsr-z! m (zero? (bitwise-and diff #xFFFFFFFF)))
             (set-gba-machine-cpsr-n! m (bitwise-bit-set? (bitwise-and diff #xFFFFFFFF) 31))]
            [else
             (error 'gba-step-arm7tdmi! "Unsupported ARM data-processing opcode #x~x" opcode)])]

         [else
          ;; Check if PC points at a 16-bit Thumb instruction inside `thumb_bg0_tilemap_veneer`
          (define lo16 (bitwise-and inst32 #xFFFF))
          (if (or (= (bitwise-and lo16 #xF800) #x2000)
                  (= (bitwise-and lo16 #xF800) #x3000)
                  (= (bitwise-and lo16 #xF800) #x3800)
                  (= (bitwise-and lo16 #xFE00) #x5200)
                  (= (bitwise-and lo16 #xFF80) #x4700))
              (begin
                (vector-set! regs 15 pc)
                (set-gba-machine-thumb?! m #t)
                (gba-step-arm7tdmi! m))
              (error 'gba-step-arm7tdmi! "Unsupported ARM32 word #x~x at PC $#x~x" inst32 pc))]))]))

;; Run a subroutine starting at `entry-addr` until it returns to sentinel `#x08000000`
(define (gba-run-subroutine! m entry-addr #:max-steps [max-steps 512])
  (define regs (gba-machine-regs m))
  (define sentinel #x08000004)
  (vector-set! regs 14 sentinel)
  (vector-set! regs 15 entry-addr)
  (set-gba-machine-thumb?! m #f)
  (let loop ([steps 0])
    (when (and (< steps max-steps)
               (not (= (vector-ref regs 15) sentinel)))
      (gba-step-arm7tdmi! m)
      (loop (add1 steps)))))

(define (gba-step-frame! m frame-entry-addr [buttons 0])
  (gba-write-u32! m (+ GBA-IWRAM-BASE IWRAM-STATE-BUTTONS) buttons)
  (gba-write-u16! m REG-KEYINPUT (bitwise-xor #x03FF (bitwise-and buttons #x03FF)))
  (gba-run-subroutine! m frame-entry-addr))

;; End-to-End Headless GBA ROM & 4-Stage Campaign Verification (`FAIL_OK -> REC_OK -> FULL_WIN_OK`)
(define (verify-gba-rom-execution [rom-path-or-bytes "build/boba_gba.gba"])
  (define rom-bytes
    (cond
      [(bytes? rom-path-or-bytes) rom-path-or-bytes]
      [else
       (define resolved (resolve-gba-path rom-path-or-bytes))
       (unless (file-exists? resolved)
         (compile-boba-gba-rom! #:gba-out-path resolved))
       (file->bytes resolved)]))

  ;; 1. Verify .gba Cartridge Header (`#xEA00002E` entry, 156B logo, `#x96` fixed byte, `$BD` checksum)
  (define fixed-96-ok? (= (bytes-ref rom-bytes #xB2) #x96))
  (define expected-chk (compute-gba-header-checksum rom-bytes))
  (define actual-chk   (bytes-ref rom-bytes #xBD))
  (define header-ok?   (verify-gba-cartridge-header rom-bytes))

  ;; 2. Verify Static VRAM Bus-Width Capability Check (0 `STRB` violations)
  (define forms     (emit-boba-gba-arm7tdmi-program))
  (define bus-check (verify-gba-vram-bus-widths forms))
  (define asm-res   (assemble-arm7tdmi forms #:origin GBA-ROM-ENTRY))
  (define labels    (gba-asm-result-labels asm-res))
  (define frame-pc  (hash-ref labels 'frame_step))

  ;; 3. Boot the GBA Machine from `$08000000` (branches via `#xEA00002E` to `boot_init` at `$080000C0`)
  (define m (make-gba-machine rom-bytes))
  (gba-run-subroutine! m GBA-ROM-BASE)

  (define dispcnt-val  (gba-read-u16 m REG-DISPCNT))
  (define bg0cnt-val   (gba-read-u16 m REG-BG0CNT))
  (define bg-pal0-col1 (gba-read-u16 m (+ GBA-PALRAM-BASE 2)))
  (define obj-pal0-col1 (gba-read-u16 m (+ GBA-PALRAM-OBJ-BASE 2)))
  (define vram-tile1-w0 (gba-read-u32 m (+ GBA-VRAM-BASE 32)))
  (define obj-tile1-w0  (gba-read-u32 m (+ GBA-VRAM-OBJ-BASE 32)))
  (define bg0-map-entry (gba-read-u16 m #x0600F800))
  (define oam-spr0-y    (gba-read-u16 m GBA-OAM-BASE))
  (define oam-spr0-x    (gba-read-u16 m (+ GBA-OAM-BASE 2)))

  ;; 4. Execute 4-Stage Campaign Playthrough (`FAIL_OK -> REC_OK -> FULL_WIN_OK`)
  ;; Stage 0 Hazard Failure (`BTN-LEFT`): DEAD = 1, LIVES = 2, ENERGY = 0
  (gba-step-frame! m frame-pc GBA-BTN-LEFT)
  (define fail-dead   (gba-read-u32 m (+ GBA-IWRAM-BASE IWRAM-STATE-DEAD)))
  (define fail-lives  (gba-read-u32 m (+ GBA-IWRAM-BASE IWRAM-STATE-LIVES)))
  (define fail-energy (gba-read-u32 m (+ GBA-IWRAM-BASE IWRAM-STATE-ENERGY)))
  (define fail-ok?    (and (= fail-dead 1) (= fail-lives 2) (= fail-energy 0)))

  ;; In-Stage Recovery (`BTN-START`): DEAD = 0, ENERGY = 30
  (gba-step-frame! m frame-pc GBA-BTN-START)
  (define rec-dead   (gba-read-u32 m (+ GBA-IWRAM-BASE IWRAM-STATE-DEAD)))
  (define rec-energy (gba-read-u32 m (+ GBA-IWRAM-BASE IWRAM-STATE-ENERGY)))
  (define rec-ok?    (and (= rec-dead 0) (= rec-energy 30)))

  ;; Advance across all 4 stages (Stage 0 -> 1 -> 2 -> 3 -> Campaign Victory)
  (for ([_ (in-range 4)])
    (gba-step-frame! m frame-pc GBA-BTN-RIGHT))
  (define final-stage (gba-read-u32 m (+ GBA-IWRAM-BASE IWRAM-STATE-STAGE-ID)))
  (define final-won   (gba-read-u32 m (+ GBA-IWRAM-BASE IWRAM-STATE-WON)))
  (define final-comp  (gba-read-u32 m (+ GBA-IWRAM-BASE IWRAM-STATE-GAME-COMPLETED)))
  (define final-score (gba-read-u32 m (+ GBA-IWRAM-BASE IWRAM-STATE-SCORE)))
  (define full-win-ok? (and (= final-stage 3) (= final-won 1) (= final-comp 1) (= final-score 40)))

  (hasheq 'rom-size-bytes       (bytes-length rom-bytes)
          'header-valid?        header-ok?
          'fixed-byte-96?       fixed-96-ok?
          'header-checksum      actual-chk
          'expected-checksum    expected-chk
          'strb-vram-violations (+ (hash-ref bus-check 'strb-violations)
                                   (gba-machine-strb-vram-violations m))
          'dispcnt              dispcnt-val
          'bg0cnt               bg0cnt-val
          'bg-pal0-color1       bg-pal0-col1
          'obj-pal0-color1      obj-pal0-col1
          'vram-tile1-word0     vram-tile1-w0
          'obj-tile1-word0      obj-tile1-w0
          'thumb-bg0-map-entry  bg0-map-entry
          'oam-spr0-initial-x   oam-spr0-x
          'oam-spr0-initial-y   oam-spr0-y
          'dma3-transfers       (gba-machine-dma3-count m)
          'total-cycles         (gba-machine-cycles m)
          'fail-ok?             fail-ok?
          'rec-ok?              rec-ok?
          'full-win-ok?         full-win-ok?
          'campaign-status      (if (and fail-ok? rec-ok? full-win-ok?)
                                    "FAIL_OK -> REC_OK -> FULL_WIN_OK"
                                    "CAMPAIGN_INCOMPLETE")
          'final-stage-id       final-stage
          'final-score          final-score
          'verified?            (and header-ok?
                                     fixed-96-ok?
                                     (= actual-chk expected-chk)
                                     (zero? (hash-ref bus-check 'strb-violations))
                                     (zero? (gba-machine-strb-vram-violations m))
                                     (= dispcnt-val #x1140)
                                     (> vram-tile1-w0 0)
                                     (= bg0-map-entry 7)
                                     fail-ok?
                                     rec-ok?
                                     full-win-ok?)))
