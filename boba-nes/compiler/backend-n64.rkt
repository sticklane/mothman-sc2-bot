#lang racket/base

;; ============================================================================
;; compiler/backend-n64.rkt
;; Nintendo 64 (64-Bit MIPS VR4300 + RSP Vector Microcode + RDP Display List)
;; Assembler, 16-Byte Cache-Aligned CapDMA & 4 KB TMEM/IMEM/DMEM Verifier,
;; Big-Endian .z64 Cartridge Linker & Headless Execution Verifier
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
 ;; 1. N64 Memory Map, KSEG0/KSEG1 Segments & RCP Hardware Registers
 N64-RDRAM-PHYS-BASE
 N64-KSEG0-BASE
 N64-KSEG1-BASE
 N64-BOOT-PC
 N64-ROM-HEADER-MAGIC

 N64-SP-DMEM-BASE
 N64-SP-IMEM-BASE
 N64-SP-REG-BASE
 N64-SP-MEM-ADDR
 N64-SP-DRAM-ADDR
 N64-SP-RD-LEN
 N64-SP-WR-LEN
 N64-SP-STATUS

 N64-DP-REG-BASE
 N64-DP-START
 N64-DP-END
 N64-DP-CURRENT
 N64-DP-STATUS

 N64-VI-REG-BASE
 N64-VI-STATUS
 N64-VI-ORIGIN
 N64-VI-WIDTH
 N64-VI-V-CURRENT

 N64-PI-REG-BASE
 N64-PI-DRAM-ADDR
 N64-PI-CART-ADDR
 N64-PI-RD-LEN
 N64-PI-WR-LEN
 N64-PI-STATUS

 N64-IMEM-LIMIT-BYTES
 N64-DMEM-LIMIT-BYTES
 N64-TMEM-LIMIT-BYTES
 N64-DMA-ALIGN-BYTES

 ;; 2. N64 Campaign State & Controller Constants
 N64-BTN-A
 N64-BTN-B
 N64-BTN-START
 N64-BTN-UP
 N64-BTN-DOWN
 N64-BTN-LEFT
 N64-BTN-RIGHT

 N64-STATE-BASE-KSEG0
 N64-STATE-BASE-KSEG1
 N64-STATE-BASE-PHYS
 N64-STATE-BUTTONS
 N64-STATE-FRAME-CNT
 N64-STATE-PLAYER-X
 N64-STATE-PLAYER-Y
 N64-STATE-ENERGY
 N64-STATE-LIVES
 N64-STATE-DEAD
 N64-STATE-STAGE-ID
 N64-STATE-WON
 N64-STATE-GAME-COMPLETED
 N64-STATE-SCORE

 ;; 3. MIPS VR4300 Instruction Constructors & Assembler
 mips-lui
 mips-ori
 mips-addiu
 mips-addu
 mips-subu
 mips-andi
 mips-lw
 mips-sw
 mips-lh
 mips-sh
 mips-cache
 mips-beq
 mips-bne
 mips-j
 mips-jal
 mips-jr
 mips-nop
 emit-mips-li32
 encode-mips-vr4300-inst
 assemble-mips-vr4300
 n64-mips-asm-bytes
 n64-mips-asm-labels

 ;; 4. RSP 128-Bit Vector Unit (COP2) Microcode Constructors & Assembler
 rsp-lqv
 rsp-sqv
 rsp-vmulf
 rsp-vmacf
 rsp-vadd
 rsp-jr-ra
 rsp-break
 encode-rsp-inst
 assemble-rsp-microcode

 ;; 5. RDP 64-Bit Display-List Constructors & Compiler (<= 4 KB TMEM Verified)
 rdp-set-color-image
 rdp-set-fill-color
 rdp-fill-rectangle
 rdp-set-texture-image
 rdp-load-block
 rdp-texture-rectangle
 rdp-full-sync
 encode-rdp-command-u64
 compile-rdp-display-list

 ;; 6. 16-Byte Cache-Aligned CapDMA & 4 KB TMEM/IMEM/DMEM Static Verifier
 verify-n64-dma-and-tmem-safety

 ;; 7. Big-Endian .z64 ROM Image Builder & Boba N64 Compiler
 compute-n64-header-crcs
 verify-n64-z64-header
 build-boba-n64-rsp-microcode
 build-boba-n64-rdp-display-list
 build-boba-n64-rgba16-textures
 emit-boba-n64-vr4300-program
 build-n64-z64-rom-image
 compile-boba-n64-rom!

 ;; 8. Headless VR4300 + RSP + RDP + VI Emulator & 4-Stage Campaign Verifier
 (struct-out n64-machine)
 make-n64-machine
 n64-read-u16-be
 n64-read-u32-be
 n64-write-u16-be!
 n64-write-u32-be!
 n64-step-vr4300!
 n64-run-subroutine!
 n64-step-frame!
 verify-n64-rom-execution)

(define-syntax (get-repo-root-dir stx)
  (datum->syntax stx (path->string (simplify-path (build-path (syntax-source stx) 'up 'up)))))

(define REPO-ROOT-DIR (string->path (get-repo-root-dir)))

(define (resolve-n64-path p)
  (define path-obj (if (path? p) p (string->path p)))
  (if (complete-path? path-obj)
      path-obj
      (simplify-path (build-path REPO-ROOT-DIR path-obj))))

;; ============================================================================
;; 1. N64 Memory Map, KSEG0/KSEG1 Segments & RCP Registers
;; ============================================================================

(define N64-RDRAM-PHYS-BASE  #x00000000) ; 4 MB RDRAM Physical Base
(define N64-KSEG0-BASE       #x80000000) ; Cached Virtual Segment -> Physical $00000000
(define N64-KSEG1-BASE       #xA0000000) ; Uncached Virtual Segment -> Physical $00000000
(define N64-BOOT-PC          #x80000400) ; Standard IPL3 Boot Entry Point in RDRAM
(define N64-ROM-HEADER-MAGIC #x80371240) ; Big-Endian .z64 PI BSD DOM1 Header Magic

;; Reality Signal Processor (RSP: 4 KB DMEM + 4 KB IMEM + DMA Registers)
(define N64-SP-DMEM-BASE     #xA4000000) ; 4,096 B Data Memory ($04000000..$04000FFF)
(define N64-SP-IMEM-BASE     #xA4001000) ; 4,096 B Instruction Memory ($04001000..$04001FFF)
(define N64-SP-REG-BASE      #xA4040000)
(define N64-SP-MEM-ADDR      #xA4040000)
(define N64-SP-DRAM-ADDR     #xA4040004)
(define N64-SP-RD-LEN        #xA4040008) ; RDRAM -> RSP DMEM/IMEM DMA length
(define N64-SP-WR-LEN        #xA404000C) ; RSP DMEM/IMEM -> RDRAM DMA length
(define N64-SP-STATUS        #xA4040010)

;; Reality Display Processor (RDP: 64-Bit Command Processor + 4 KB On-Chip TMEM)
(define N64-DP-REG-BASE      #xA4100000)
(define N64-DP-START         #xA4100000)
(define N64-DP-END           #xA4100004)
(define N64-DP-CURRENT       #xA4100008)
(define N64-DP-STATUS        #xA410000C)

;; Video Interface (VI: Framebuffer Scanout Controller)
(define N64-VI-REG-BASE      #xA4400000)
(define N64-VI-STATUS        #xA4400000)
(define N64-VI-ORIGIN        #xA4400004)
(define N64-VI-WIDTH         #xA4400008)
(define N64-VI-V-CURRENT     #xA4400010)

;; Peripheral Interface (PI: Cartridge ROM <-> RDRAM DMA)
(define N64-PI-REG-BASE      #xA4600000)
(define N64-PI-DRAM-ADDR     #xA4600000)
(define N64-PI-CART-ADDR     #xA4600004)
(define N64-PI-RD-LEN        #xA4600008)
(define N64-PI-WR-LEN        #xA460000C)
(define N64-PI-STATUS        #xA4600010)

;; Strict Hardware Memory & Alignment Limits
(define N64-IMEM-LIMIT-BYTES 4096)
(define N64-DMEM-LIMIT-BYTES 4096)
(define N64-TMEM-LIMIT-BYTES 4096)
(define N64-DMA-ALIGN-BYTES  16)

;; 16-Byte Cache-Aligned RDRAM Buffer Addresses Used by Boba N64
(define N64-RSP-UCODE-DRAM-PHYS #x00000C00) ; 16-byte aligned ($00000C00 % 16 == 0)
(define N64-RDP-DLIST-DRAM-PHYS #x00001000) ; 16-byte aligned ($00001000 % 16 == 0)
(define N64-TEX-BANK-DRAM-PHYS  #x00001400) ; 16-byte aligned ($00001400 % 16 == 0)
(define N64-VI-FB-DRAM-PHYS     #x00010000) ; 16-byte aligned ($00010000 % 16 == 0, 320x240 RGBA16)

;; Controller & Campaign State Constants (16-byte aligned at physical $00000200)
(define N64-BTN-A               #x0001)
(define N64-BTN-B               #x0002)
(define N64-BTN-START           #x0008)
(define N64-BTN-RIGHT           #x0010)
(define N64-BTN-LEFT            #x0020)
(define N64-BTN-UP              #x0040)
(define N64-BTN-DOWN            #x0080)

(define N64-STATE-BASE-PHYS     #x00000200)
(define N64-STATE-BASE-KSEG0    #x80000200)
(define N64-STATE-BASE-KSEG1    #xA0000200)

(define N64-STATE-BUTTONS        #x00) ; $80000200
(define N64-STATE-FRAME-CNT      #x04) ; $80000204
(define N64-STATE-PLAYER-X       #x08) ; $80000208
(define N64-STATE-PLAYER-Y       #x0C) ; $8000020C
(define N64-STATE-ENERGY         #x10) ; $80000210
(define N64-STATE-LIVES          #x14) ; $80000214
(define N64-STATE-DEAD           #x18) ; $80000218
(define N64-STATE-STAGE-ID       #x1C) ; $8000021C
(define N64-STATE-WON            #x20) ; $80000220
(define N64-STATE-GAME-COMPLETED #x24) ; $80000224
(define N64-STATE-SCORE          #x28) ; $80000228

;; ============================================================================
;; 2. Big-Endian Byte Packing Helpers & MIPS Register Resolver
;; ============================================================================

(define (u32->be-bytes w)
  (define u (bitwise-and w #xFFFFFFFF))
  (bytes (bitwise-and (arithmetic-shift u -24) #xFF)
         (bitwise-and (arithmetic-shift u -16) #xFF)
         (bitwise-and (arithmetic-shift u -8)  #xFF)
         (bitwise-and u #xFF)))

(define (u16->be-bytes h)
  (define u (bitwise-and h #xFFFF))
  (bytes (bitwise-and (arithmetic-shift u -8) #xFF)
         (bitwise-and u #xFF)))

(define (u64->be-bytes q)
  (define hi (bitwise-and (arithmetic-shift q -32) #xFFFFFFFF))
  (define lo (bitwise-and q #xFFFFFFFF))
  (bytes-append (u32->be-bytes hi) (u32->be-bytes lo)))

(define (mips-reg-index r)
  (cond
    [(exact-integer? r)
     (unless (and (>= r 0) (<= r 31))
       (error 'mips-reg-index "MIPS register index out of range 0..31: ~v" r))
     r]
    [(symbol? r)
     (case r
       [(r0 $0 zero $zero) 0]
       [(r1 $1 at $at)     1]
       [(r2 $2 v0 $v0)     2]
       [(r3 $3 v1 $v1)     3]
       [(r4 $4 a0 $a0)     4]
       [(r5 $5 a1 $a1)     5]
       [(r6 $6 a2 $a2)     6]
       [(r7 $7 a3 $a3)     7]
       [(r8 $8 t0 $t0)     8]
       [(r9 $9 t1 $t1)     9]
       [(r10 $10 t2 $t2)   10]
       [(r11 $11 t3 $t3)   11]
       [(r12 $12 t4 $t4)   12]
       [(r13 $13 t5 $t5)   13]
       [(r14 $14 t6 $t6)   14]
       [(r15 $15 t7 $t7)   15]
       [(r16 $16 s0 $s0)   16]
       [(r17 $17 s1 $s1)   17]
       [(r18 $18 s2 $s2)   18]
       [(r19 $19 s3 $s3)   19]
       [(r20 $20 s4 $s4)   20]
       [(r21 $21 s5 $s5)   21]
       [(r22 $22 s6 $s6)   22]
       [(r23 $23 s7 $s7)   23]
       [(r24 $24 t8 $t8)   24]
       [(r25 $25 t9 $t9)   25]
       [(r26 $26 k0 $k0)   26]
       [(r27 $27 k1 $k1)   27]
       [(r28 $28 gp $gp)   28]
       [(r29 $29 sp $sp)   29]
       [(r30 $30 fp $fp s8 $s8) 30]
       [(r31 $31 ra $ra)   31]
       ;; RSP Vector registers v0..v31
       [else
        (define s (symbol->string r))
        (if (and (> (string-length s) 1)
                 (or (char=? (string-ref s 0) #\v)
                     (char=? (string-ref s 0) #\V)))
            (let ([n (string->number (substring s 1))])
              (if (and (exact-integer? n) (<= 0 n 31))
                  n
                  (error 'mips-reg-index "Unknown MIPS/RSP register symbol: ~v" r)))
            (error 'mips-reg-index "Unknown MIPS/RSP register symbol: ~v" r))])]
    [else (error 'mips-reg-index "Invalid MIPS register specifier: ~v" r)]))

;; ============================================================================
;; 3. MIPS VR4300 Instruction Constructors & Big-Endian Assembler
;; ============================================================================

(define (mips-lui rt imm16)          `(mips-lui ,rt ,imm16))
(define (mips-ori rt rs imm16)       `(mips-ori ,rt ,rs ,imm16))
(define (mips-addiu rt rs imm16)     `(mips-addiu ,rt ,rs ,imm16))
(define (mips-addu rd rs rt)         `(mips-addu ,rd ,rs ,rt))
(define (mips-subu rd rs rt)         `(mips-subu ,rd ,rs ,rt))
(define (mips-andi rt rs imm16)      `(mips-andi ,rt ,rs ,imm16))
(define (mips-lw rt offset16 rs)     `(mips-lw ,rt ,offset16 ,rs))
(define (mips-sw rt offset16 rs)     `(mips-sw ,rt ,offset16 ,rs))
(define (mips-lh rt offset16 rs)     `(mips-lh ,rt ,offset16 ,rs))
(define (mips-sh rt offset16 rs)     `(mips-sh ,rt ,offset16 ,rs))
(define (mips-cache op offset16 rs)  `(mips-cache ,op ,offset16 ,rs))
(define (mips-beq rs rt label)       `(mips-beq ,rs ,rt ,label))
(define (mips-bne rs rt label)       `(mips-bne ,rs ,rt ,label))
(define (mips-j label)               `(mips-j ,label))
(define (mips-jal label)             `(mips-jal ,label))
(define (mips-jr rs)                 `(mips-jr ,rs))
(define (mips-nop)                   '(mips-nop))

(define (emit-mips-li32 rt val32)
  (define u32 (bitwise-and val32 #xFFFFFFFF))
  (define hi16 (bitwise-and (arithmetic-shift u32 -16) #xFFFF))
  (define lo16 (bitwise-and u32 #xFFFF))
  (cond
    [(zero? hi16)
     (list (mips-ori rt 0 lo16))]
    [(zero? lo16)
     (list (mips-lui rt hi16))]
    [else
     (list (mips-lui rt hi16)
           (mips-ori rt rt lo16))]))

(define (eval-n64-expr expr labels [default-val 0])
  (match expr
    [(? exact-integer? n) n]
    [(? symbol? sym)
     (hash-ref labels sym
               (lambda ()
                 (if default-val
                     default-val
                     (error 'eval-n64-expr "Undefined MIPS VR4300 label: ~a" sym))))]
    [`(hi16 ,e)
     (bitwise-and (arithmetic-shift (eval-n64-expr e labels default-val) -16) #xFFFF)]
    [`(lo16 ,e)
     (bitwise-and (eval-n64-expr e labels default-val) #xFFFF)]
    [`(+ ,a ,b)
     (+ (eval-n64-expr a labels default-val)
        (eval-n64-expr b labels default-val))]
    [`(- ,a ,b)
     (- (eval-n64-expr a labels default-val)
        (eval-n64-expr b labels default-val))]
    [else
     (error 'eval-n64-expr "Unsupported MIPS assembler expression: ~v" expr)]))

(define (encode-mips-vr4300-inst form [pc N64-BOOT-PC] [labels (hasheq)])
  (define (resolve-branch-imm16 target)
    (cond
      [(and (exact-integer? target) (< (abs target) #x10000))
       (bitwise-and target #xFFFF)]
      [else
       (define target-addr (eval-n64-expr target labels #f))
       (bitwise-and (arithmetic-shift (- target-addr (+ pc 4)) -2) #xFFFF)]))

  (define (resolve-jump-idx26 target)
    (define target-addr (eval-n64-expr target labels #f))
    (bitwise-and (arithmetic-shift (bitwise-and target-addr #x0FFFFFFF) -2) #x03FFFFFF))

  (match form
    [`(mips-lui ,rt ,imm16)
     (u32->be-bytes (bitwise-ior #x3C000000
                                 (arithmetic-shift (mips-reg-index rt) 16)
                                 (bitwise-and (eval-n64-expr imm16 labels #f) #xFFFF)))]
    [`(mips-ori ,rt ,rs ,imm16)
     (u32->be-bytes (bitwise-ior #x34000000
                                 (arithmetic-shift (mips-reg-index rs) 21)
                                 (arithmetic-shift (mips-reg-index rt) 16)
                                 (bitwise-and (eval-n64-expr imm16 labels #f) #xFFFF)))]
    [`(mips-addiu ,rt ,rs ,imm16)
     (u32->be-bytes (bitwise-ior #x24000000
                                 (arithmetic-shift (mips-reg-index rs) 21)
                                 (arithmetic-shift (mips-reg-index rt) 16)
                                 (bitwise-and (eval-n64-expr imm16 labels #f) #xFFFF)))]
    [`(mips-addu ,rd ,rs ,rt)
     (u32->be-bytes (bitwise-ior (arithmetic-shift (mips-reg-index rs) 21)
                                 (arithmetic-shift (mips-reg-index rt) 16)
                                 (arithmetic-shift (mips-reg-index rd) 11)
                                 #x21))]
    [`(mips-subu ,rd ,rs ,rt)
     (u32->be-bytes (bitwise-ior (arithmetic-shift (mips-reg-index rs) 21)
                                 (arithmetic-shift (mips-reg-index rt) 16)
                                 (arithmetic-shift (mips-reg-index rd) 11)
                                 #x23))]
    [`(mips-andi ,rt ,rs ,imm16)
     (u32->be-bytes (bitwise-ior #x30000000
                                 (arithmetic-shift (mips-reg-index rs) 21)
                                 (arithmetic-shift (mips-reg-index rt) 16)
                                 (bitwise-and (eval-n64-expr imm16 labels #f) #xFFFF)))]
    [`(mips-lw ,rt ,offset16 ,rs)
     (u32->be-bytes (bitwise-ior #x8C000000
                                 (arithmetic-shift (mips-reg-index rs) 21)
                                 (arithmetic-shift (mips-reg-index rt) 16)
                                 (bitwise-and (eval-n64-expr offset16 labels #f) #xFFFF)))]
    [`(mips-sw ,rt ,offset16 ,rs)
     (u32->be-bytes (bitwise-ior #xAC000000
                                 (arithmetic-shift (mips-reg-index rs) 21)
                                 (arithmetic-shift (mips-reg-index rt) 16)
                                 (bitwise-and (eval-n64-expr offset16 labels #f) #xFFFF)))]
    [`(mips-lh ,rt ,offset16 ,rs)
     (u32->be-bytes (bitwise-ior #x84000000
                                 (arithmetic-shift (mips-reg-index rs) 21)
                                 (arithmetic-shift (mips-reg-index rt) 16)
                                 (bitwise-and (eval-n64-expr offset16 labels #f) #xFFFF)))]
    [`(mips-sh ,rt ,offset16 ,rs)
     (u32->be-bytes (bitwise-ior #xA4000000
                                 (arithmetic-shift (mips-reg-index rs) 21)
                                 (arithmetic-shift (mips-reg-index rt) 16)
                                 (bitwise-and (eval-n64-expr offset16 labels #f) #xFFFF)))]
    [`(mips-cache ,op ,offset16 ,rs)
     (u32->be-bytes (bitwise-ior #xBC000000
                                 (arithmetic-shift (mips-reg-index rs) 21)
                                 (arithmetic-shift (bitwise-and op #x1F) 16)
                                 (bitwise-and (eval-n64-expr offset16 labels #f) #xFFFF)))]
    [`(mips-beq ,rs ,rt ,label)
     (u32->be-bytes (bitwise-ior #x10000000
                                 (arithmetic-shift (mips-reg-index rs) 21)
                                 (arithmetic-shift (mips-reg-index rt) 16)
                                 (resolve-branch-imm16 label)))]
    [`(mips-bne ,rs ,rt ,label)
     (u32->be-bytes (bitwise-ior #x14000000
                                 (arithmetic-shift (mips-reg-index rs) 21)
                                 (arithmetic-shift (mips-reg-index rt) 16)
                                 (resolve-branch-imm16 label)))]
    [`(mips-j ,label)
     (u32->be-bytes (bitwise-ior #x08000000 (resolve-jump-idx26 label)))]
    [`(mips-jal ,label)
     (u32->be-bytes (bitwise-ior #x0C000000 (resolve-jump-idx26 label)))]
    [`(mips-jr ,rs)
     (u32->be-bytes (bitwise-ior (arithmetic-shift (mips-reg-index rs) 21) #x08))]
    ['(mips-nop)
     (u32->be-bytes #x00000000)]
    [else
     (error 'encode-mips-vr4300-inst "Unrecognized MIPS VR4300 instruction form: ~v" form)]))

(define (assemble-mips-vr4300 forms
                              #:origin [origin N64-BOOT-PC]
                              #:bytes-only? [bytes-only? #f])
  (define labels (make-hash))
  (define pc origin)

  ;; Pass 1: Compute label addresses
  (for ([form (in-list forms)])
    (match form
      [`(label ,sym)
       (hash-set! labels sym pc)]
      [`(.equ ,sym ,val)
       (hash-set! labels sym (eval-n64-expr val labels 0))]
      [`(.align ,boundary)
       (define rem (modulo pc boundary))
       (unless (zero? rem)
         (set! pc (+ pc (- boundary rem))))]
      [`(.word . ,vals)
       (set! pc (+ pc (* 4 (length vals))))]
      [else
       (set! pc (+ pc 4))]))

  ;; Pass 2: Emit 32-bit big-endian machine words
  (define chunks '())
  (define cur-pc origin)
  (define inst-cnt 0)
  (define cache-op-cnt 0)

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
      [`(.word . ,vals)
       (for ([v (in-list vals)])
         (set! chunks (cons (u32->be-bytes (eval-n64-expr v labels #f)) chunks))
         (set! cur-pc (+ cur-pc 4)))]
      [else
       (when (and (pair? form) (eq? (car form) 'mips-cache))
         (set! cache-op-cnt (add1 cache-op-cnt)))
       (set! inst-cnt (add1 inst-cnt))
       (set! chunks (cons (encode-mips-vr4300-inst form cur-pc labels) chunks))
       (set! cur-pc (+ cur-pc 4))]))

  (define out-bytes (apply bytes-append (reverse chunks)))
  (define imm-labels
    (for/hasheq ([(k v) (in-hash labels)])
      (values k v)))

  (if bytes-only?
      out-bytes
      (hasheq 'bytes             out-bytes
              'origin            origin
              'labels            imm-labels
              'instruction-count inst-cnt
              'cache-ops         cache-op-cnt
              'forms             forms)))

(define (n64-mips-asm-bytes x)
  (if (bytes? x) x (hash-ref x 'bytes)))

(define (n64-mips-asm-labels x)
  (if (bytes? x) (hasheq) (hash-ref x 'labels (hasheq))))

;; ============================================================================
;; 4. RSP 128-Bit Vector Unit (`COP2`) Microcode Assembler (<= 4 KB IMEM/DMEM)
;; ============================================================================

(define (rsp-lqv vt elem offset base) `(rsp-lqv ,vt ,elem ,offset ,base))
(define (rsp-sqv vt elem offset base) `(rsp-sqv ,vt ,elem ,offset ,base))
(define (rsp-vmulf vd vs vt elem)     `(rsp-vmulf ,vd ,vs ,vt ,elem))
(define (rsp-vmacf vd vs vt elem)     `(rsp-vmacf ,vd ,vs ,vt ,elem))
(define (rsp-vadd vd vs vt elem)      `(rsp-vadd ,vd ,vs ,vt ,elem))
(define (rsp-jr-ra)                   '(rsp-jr-ra))
(define (rsp-break)                   '(rsp-break))

(define (encode-rsp-inst form)
  (match form
    [`(rsp-lqv ,vt ,elem ,offset ,base)
     (define b (mips-reg-index base))
     (define t (mips-reg-index vt))
     (define e (bitwise-and elem #xF))
     ;; LQV offset is in 16-byte quadwords when >= 16 or raw signed 7-bit field
     (define off7 (bitwise-and (if (>= (abs offset) 16) (arithmetic-shift offset -4) offset) #x7F))
     (u32->be-bytes (bitwise-ior #xC8000000
                                 (arithmetic-shift b 21)
                                 (arithmetic-shift t 16)
                                 (arithmetic-shift #x02 11)
                                 (arithmetic-shift e 7)
                                 off7))]
    [`(rsp-sqv ,vt ,elem ,offset ,base)
     (define b (mips-reg-index base))
     (define t (mips-reg-index vt))
     (define e (bitwise-and elem #xF))
     (define off7 (bitwise-and (if (>= (abs offset) 16) (arithmetic-shift offset -4) offset) #x7F))
     (u32->be-bytes (bitwise-ior #xE8000000
                                 (arithmetic-shift b 21)
                                 (arithmetic-shift t 16)
                                 (arithmetic-shift #x02 11)
                                 (arithmetic-shift e 7)
                                 off7))]
    [`(rsp-vmulf ,vd ,vs ,vt ,elem)
     (u32->be-bytes (bitwise-ior #x4A000000
                                 (arithmetic-shift (bitwise-and elem #xF) 21)
                                 (arithmetic-shift (mips-reg-index vt) 16)
                                 (arithmetic-shift (mips-reg-index vs) 11)
                                 (arithmetic-shift (mips-reg-index vd) 6)
                                 #x00))]
    [`(rsp-vmacf ,vd ,vs ,vt ,elem)
     (u32->be-bytes (bitwise-ior #x4A000000
                                 (arithmetic-shift (bitwise-and elem #xF) 21)
                                 (arithmetic-shift (mips-reg-index vt) 16)
                                 (arithmetic-shift (mips-reg-index vs) 11)
                                 (arithmetic-shift (mips-reg-index vd) 6)
                                 #x08))]
    [`(rsp-vadd ,vd ,vs ,vt ,elem)
     (u32->be-bytes (bitwise-ior #x4A000000
                                 (arithmetic-shift (bitwise-and elem #xF) 21)
                                 (arithmetic-shift (mips-reg-index vt) 16)
                                 (arithmetic-shift (mips-reg-index vs) 11)
                                 (arithmetic-shift (mips-reg-index vd) 6)
                                 #x10))]
    ['(rsp-jr-ra)
     (u32->be-bytes #x03E00008)]
    ['(rsp-break)
     (u32->be-bytes #x0000000D)]
    [else
     (encode-mips-vr4300-inst form #x04001000 (hasheq))]))

(define (assemble-rsp-microcode forms
                                #:dmem-bytes [dmem-bytes 64]
                                #:error-on-overflow? [error-on-overflow? #t])
  (define encoded-chunks
    (for/list ([f (in-list forms)]
               #:unless (and (pair? f) (eq? (car f) 'label)))
      (encode-rsp-inst f)))
  (define ucode-bytes (apply bytes-append encoded-chunks))
  (define imem-size   (bytes-length ucode-bytes))
  (define imem-ok?    (<= imem-size N64-IMEM-LIMIT-BYTES))
  (define dmem-ok?    (<= dmem-bytes N64-DMEM-LIMIT-BYTES))

  (when (and error-on-overflow? (not (and imem-ok? dmem-ok?)))
    (error 'assemble-rsp-microcode
           "RSP microcode exceeded 4 KB hardware limit: IMEM=~a/4096 B, DMEM=~a/4096 B"
           imem-size dmem-bytes))

  (hasheq 'bytes             ucode-bytes
          'imem-bytes        imem-size
          'imem-limit        N64-IMEM-LIMIT-BYTES
          'imem-ok?          imem-ok?
          'dmem-bytes        dmem-bytes
          'dmem-limit        N64-DMEM-LIMIT-BYTES
          'dmem-ok?          dmem-ok?
          'instruction-count (length encoded-chunks)
          'forms             forms))

;; ============================================================================
;; 5. RDP 64-Bit Display-List Compiler (<= 4,096 B On-Chip TMEM Verifier)
;; ============================================================================

(define (rdp-set-color-image fmt size width dram-addr)
  `(rdp-set-color-image ,fmt ,size ,width ,dram-addr))

(define (rdp-set-fill-color rgba32)
  `(rdp-set-fill-color ,rgba32))

(define (rdp-fill-rectangle ulx uly lrx lry)
  `(rdp-fill-rectangle ,ulx ,uly ,lrx ,lry))

(define (rdp-set-texture-image fmt size width dram-addr)
  `(rdp-set-texture-image ,fmt ,size ,width ,dram-addr))

(define (rdp-load-block tile uls ult lrs dxt)
  `(rdp-load-block ,tile ,uls ,ult ,lrs ,dxt))

(define (rdp-texture-rectangle xl yl xh yh tile s t dsdx dtdy)
  `(rdp-texture-rectangle ,xl ,yl ,xh ,yh ,tile ,s ,t ,dsdx ,dtdy))

(define (rdp-full-sync)
  '(rdp-full-sync))

(define (encode-rdp-command-u64 cmd)
  (match cmd
    [`(rdp-set-color-image ,fmt ,size ,width ,dram-addr)
     (define hi (bitwise-ior (arithmetic-shift #xFF 24)
                             (arithmetic-shift (bitwise-and fmt #x7) 21)
                             (arithmetic-shift (bitwise-and size #x3) 19)
                             (bitwise-and (max 0 (sub1 width)) #xFFF)))
     (define lo (bitwise-and dram-addr #xFFFFFFFF))
     (bitwise-ior (arithmetic-shift hi 32) lo)]

    [`(rdp-set-fill-color ,rgba32)
     (define hi (arithmetic-shift #xF7 24))
     (define lo (bitwise-and rgba32 #xFFFFFFFF))
     (bitwise-ior (arithmetic-shift hi 32) lo)]

    [`(rdp-fill-rectangle ,ulx ,uly ,lrx ,lry)
     (define hi (bitwise-ior (arithmetic-shift #xF6 24)
                             (arithmetic-shift (bitwise-and lrx #xFFF) 12)
                             (bitwise-and lry #xFFF)))
     (define lo (bitwise-ior (arithmetic-shift (bitwise-and ulx #xFFF) 12)
                             (bitwise-and uly #xFFF)))
     (bitwise-ior (arithmetic-shift hi 32) lo)]

    [`(rdp-set-texture-image ,fmt ,size ,width ,dram-addr)
     (define hi (bitwise-ior (arithmetic-shift #xFD 24)
                             (arithmetic-shift (bitwise-and fmt #x7) 21)
                             (arithmetic-shift (bitwise-and size #x3) 19)
                             (bitwise-and (max 0 (sub1 width)) #xFFF)))
     (define lo (bitwise-and dram-addr #xFFFFFFFF))
     (bitwise-ior (arithmetic-shift hi 32) lo)]

    [`(rdp-load-block ,tile ,uls ,ult ,lrs ,dxt)
     (define hi (bitwise-ior (arithmetic-shift #xF3 24)
                             (arithmetic-shift (bitwise-and uls #xFFF) 12)
                             (bitwise-and ult #xFFF)))
     (define lo (bitwise-ior (arithmetic-shift (bitwise-and tile #x7) 24)
                             (arithmetic-shift (bitwise-and lrs #xFFF) 12)
                             (bitwise-and dxt #xFFF)))
     (bitwise-ior (arithmetic-shift hi 32) lo)]

    [`(rdp-texture-rectangle ,xl ,yl ,xh ,yh ,tile ,s ,t ,_dsdx ,_dtdy)
     (define hi (bitwise-ior (arithmetic-shift #xE4 24)
                             (arithmetic-shift (bitwise-and xl #x3FF) 14)
                             (arithmetic-shift (bitwise-and yl #x3FF) 4)
                             (bitwise-and tile #x7)))
     (define lo (bitwise-ior (arithmetic-shift (bitwise-and xh #x3FF) 22)
                             (arithmetic-shift (bitwise-and yh #x3FF) 12)
                             (arithmetic-shift (bitwise-and s #x3F) 6)
                             (bitwise-and t #x3F)))
     (bitwise-ior (arithmetic-shift hi 32) lo)]

    ['(rdp-full-sync)
     #xE900000000000000]

    [else
     (error 'encode-rdp-command-u64 "Unrecognized RDP command form: ~v" cmd)]))

(define (compile-rdp-display-list commands
                                  #:error-on-tmem-overflow? [error-on-tmem-overflow? #t])
  (define cur-texel-size-code 2) ; Default size=2 -> 16-bit RGBA16 (2 bytes/texel)
  (define peak-tmem-bytes 0)
  (define tmem-violations '())
  (define words64 '())

  (define (texel-bytes-for-count count size-code)
    (case size-code
      [(0) (quotient (add1 count) 2)] ; 4-bit CI4
      [(1) count]                     ; 8-bit CI8/IA8
      [(2) (* count 2)]               ; 16-bit RGBA16
      [(3) (* count 4)]               ; 32-bit RGBA32
      [else (* count 2)]))

  (for ([cmd (in-list commands)])
    (match cmd
      [`(rdp-set-texture-image ,_fmt ,size ,_width ,_dram-addr)
       (set! cur-texel-size-code size)]
      [`(rdp-load-block ,tile ,_uls ,_ult ,lrs ,_dxt)
       (define loaded-bytes (texel-bytes-for-count (add1 lrs) cur-texel-size-code))
       (when (> loaded-bytes peak-tmem-bytes)
         (set! peak-tmem-bytes loaded-bytes))
       (when (> loaded-bytes N64-TMEM-LIMIT-BYTES)
         (set! tmem-violations
               (cons (hasheq 'type         'rdp-tmem-4kb-overflow
                             'tile         tile
                             'loaded-bytes loaded-bytes
                             'limit-bytes  N64-TMEM-LIMIT-BYTES
                             'command      cmd)
                     tmem-violations)))]
      [else (void)])
    (set! words64 (cons (encode-rdp-command-u64 cmd) words64)))

  (define rev-words (reverse words64))
  (define out-bytes (apply bytes-append (map u64->be-bytes rev-words)))
  (define rev-viols (reverse tmem-violations))

  (when (and error-on-tmem-overflow? (not (null? rev-viols)))
    (error 'compile-rdp-display-list
           "RDP Load_Block exceeded 4,096-byte on-chip TMEM limit: ~v"
           rev-viols))

  (hasheq 'bytes          out-bytes
          'words64        rev-words
          'command-count  (length rev-words)
          'tmem-bytes     peak-tmem-bytes
          'tmem-limit     N64-TMEM-LIMIT-BYTES
          'tmem-ok?       (null? rev-viols)
          'violations     rev-viols
          'commands       commands))

;; ============================================================================
;; 6. Static 16-Byte Cache-Aligned `CapDMA` & 4 KB TMEM/IMEM/DMEM Verifier
;; ============================================================================

(define (verify-n64-dma-and-tmem-safety [desc-or-forms (hasheq)]
                                        #:dma-buffers [dma-buffers #f]
                                        #:mips-forms [mips-forms #f]
                                        #:imem-bytes [imem-bytes #f]
                                        #:dmem-bytes [dmem-bytes #f]
                                        #:tmem-bytes [tmem-bytes #f]
                                        #:error-on-violation? [error-on-violation? #f])
  (define h (if (hash? desc-or-forms) desc-or-forms (hasheq)))
  (define buffers
    (or dma-buffers
        (hash-ref h 'dma-buffers #f)
        (list (hasheq 'name 'rsp-ucode-buffer  'addr N64-RSP-UCODE-DRAM-PHYS 'bytes 32   'cache-synced? #t)
              (hasheq 'name 'rdp-dlist-buffer  'addr N64-RDP-DLIST-DRAM-PHYS 'bytes 80   'cache-synced? #t)
              (hasheq 'name 'rgba16-tex-buffer 'addr N64-TEX-BANK-DRAM-PHYS  'bytes 1024 'cache-synced? #t)
              (hasheq 'name 'vi-frame-buffer   'addr N64-VI-FB-DRAM-PHYS     'bytes (* 320 240 2) 'uncached-kseg1? #t))))
  (define forms
    (or mips-forms
        (hash-ref h 'mips-forms #f)
        (if (list? desc-or-forms) desc-or-forms '())))
  (define imem (or imem-bytes (hash-ref h 'imem-bytes 28)))
  (define dmem (or dmem-bytes (hash-ref h 'dmem-bytes 64)))
  (define tmem (or tmem-bytes (hash-ref h 'tmem-bytes 1024)))

  (define has-mips-cache-inst?
    (or (null? forms)
        (for/or ([f (in-list forms)])
          (and (pair? f) (eq? (car f) 'mips-cache)))))

  (define violations '())

  ;; 1. Check 16-byte cache-line alignment and cache coherency on all DMA buffers
  (for ([buf (in-list buffers)])
    (define addr (if (exact-integer? buf) buf (hash-ref buf 'addr 0)))
    (define name (if (hash? buf) (hash-ref buf 'name 'dma-buf) 'dma-buf))
    (define synced?
      (if (hash? buf)
          (or (hash-ref buf 'cache-synced? #f)
              (hash-ref buf 'uncached-kseg1? #f)
              (>= (bitwise-and addr #xFFFFFFFF) N64-KSEG1-BASE)
              has-mips-cache-inst?)
          has-mips-cache-inst?))
    (unless (zero? (modulo addr N64-DMA-ALIGN-BYTES))
      (set! violations
            (cons (hasheq 'type    'unaligned-n64-dma-buffer
                          'name    name
                          'address addr
                          'align   N64-DMA-ALIGN-BYTES
                          'message (format "N64 DMA buffer ~a at $#x~x is not 16-byte cache-line aligned (addr % 16 = ~a)"
                                           name addr (modulo addr 16)))
                  violations)))
    (unless synced?
      (set! violations
            (cons (hasheq 'type    'missing-dcache-writeback-before-dma
                          'name    name
                          'address addr
                          'message (format "N64 DMA buffer ~a at $#x~x lacks preceding (mips-cache ...) writeback/invalidate or uncached KSEG1 addressing"
                                           name addr))
                  violations))))

  ;; 2. Check 4,096 B limits on IMEM, DMEM, and TMEM
  (when (> imem N64-IMEM-LIMIT-BYTES)
    (set! violations
          (cons (hasheq 'type 'rsp-imem-4kb-overflow 'bytes imem 'limit N64-IMEM-LIMIT-BYTES)
                violations)))
  (when (> dmem N64-DMEM-LIMIT-BYTES)
    (set! violations
          (cons (hasheq 'type 'rsp-dmem-4kb-overflow 'bytes dmem 'limit N64-DMEM-LIMIT-BYTES)
                violations)))
  (when (> tmem N64-TMEM-LIMIT-BYTES)
    (set! violations
          (cons (hasheq 'type 'rdp-tmem-4kb-overflow 'bytes tmem 'limit N64-TMEM-LIMIT-BYTES)
                violations)))

  (define rev-violations (reverse violations))
  (when (and error-on-violation? (not (null? rev-violations)))
    (error 'verify-n64-dma-and-tmem-safety
           "N64 CapDMA / TMEM verification failed with ~a violation(s): ~v"
           (length rev-violations)
           rev-violations))

  (hasheq 'valid?              (null? rev-violations)
          'well-typed?         (null? rev-violations)
          'dma-16byte-aligned? (for/and ([b (in-list buffers)])
                                 (zero? (modulo (if (exact-integer? b) b (hash-ref b 'addr 0)) 16)))
          'cache-coherent?     has-mips-cache-inst?
          'imem-bytes          imem
          'imem-limit          N64-IMEM-LIMIT-BYTES
          'dmem-bytes          dmem
          'dmem-limit          N64-DMEM-LIMIT-BYTES
          'tmem-bytes          tmem
          'tmem-limit          N64-TMEM-LIMIT-BYTES
          'violations          rev-violations))

;; ============================================================================
;; 7. Boba N64 RSP Microcode, RDP Display List, RGBA16 Textures & .z64 Builder
;; ============================================================================

;; Build the RSP 128-bit Vector Unit microcode for Boba N64:
;;   Loads 8 x 16-bit vertex/sprite transform coefficients from DMEM ($000, $010) via `rsp-lqv`,
;;   executes SIMD `rsp-vmulf`, `rsp-vmacf`, and `rsp-vadd`, stores transformed quadvector to DMEM ($020)
;;   via `rsp-sqv`, and signals completion with `rsp-break` + `rsp-jr-ra`.
(define (build-boba-n64-rsp-microcode)
  (assemble-rsp-microcode
   (list (rsp-lqv   1 0 #x00 0) ; v1 = DMEM[$000..$00F] (8 x 16-bit sprite coords)
         (rsp-lqv   2 0 #x10 0) ; v2 = DMEM[$010..$01F] (8 x 16-bit scale factors)
         (rsp-lqv   3 0 #x20 0) ; v3 = DMEM[$020..$02F] (8 x 16-bit translation offsets)
         (rsp-vmulf 4 1 2 0)    ; v4 = v1 * v2 (8-lane 16-bit fractional multiply)
         (rsp-vmacf 4 1 2 0)    ; v4 += v1 * v2 (8-lane multiply-accumulate)
         (rsp-vadd  5 4 3 0)    ; v5 = v4 + v3 (8-lane vector add)
         (rsp-sqv   5 0 #x30 0) ; DMEM[$030..$03F] = v5
         (rsp-break)
         (rsp-jr-ra))
   #:dmem-bytes 64))

;; Build the 64-bit RDP Display List for Boba N64:
;;   1. `rdp-set-color-image`   (#xFF): 320x240 16-bit RGBA5551 framebuffer at $00010000
;;   2. `rdp-set-fill-color`    (#xF7): Deep Space Indigo backdrop (#x10851085)
;;   3. `rdp-fill-rectangle`    (#xF6): Clear 320x240 screen
;;   4. `rdp-set-texture-image` (#xFD): 16-bit RGBA5551 texture bank at $00001400
;;   5. `rdp-load-block`        (#xF3): Load 512 RGBA16 texels (1,024 B <= 4,096 B TMEM!) into Tile 0
;;   6. `rdp-texture-rectangle` (#xE4): Draw Boba Player sprite (80, 96) -> (96, 112)
;;   7. `rdp-texture-rectangle` (#xE4): Draw Flag Goal sprite (176, 96) -> (192, 112)
;;   8. `rdp-texture-rectangle` (#xE4): Draw Rock Push Block (128, 96) -> (144, 112)
;;   9. `rdp-texture-rectangle` (#xE4): Draw "BOBA IS YOU" Banner (64, 32) -> (128, 48)
;;  10. `rdp-full-sync`         (#xE900000000000000)
(define (build-boba-n64-rdp-display-list)
  (compile-rdp-display-list
   (list (rdp-set-color-image   0 2 320 N64-VI-FB-DRAM-PHYS)
         (rdp-set-fill-color    #x10851085)
         (rdp-fill-rectangle    0 0 319 239)
         (rdp-set-texture-image 0 2 8 N64-TEX-BANK-DRAM-PHYS)
         (rdp-load-block        0 0 0 511 256) ; 512 texels * 2 B = 1,024 B <= 4,096 B TMEM!
         (rdp-texture-rectangle 80  96  96  112 0 0  0 1024 1024)
         (rdp-texture-rectangle 176 96  192 112 0 8  0 1024 1024)
         (rdp-texture-rectangle 128 96  144 112 0 16 0 1024 1024)
         (rdp-texture-rectangle 64  32  128 48  0 24 0 1024 1024)
         (rdp-full-sync))))

;; Build 1,024 bytes of 16-bit big-endian RGBA5551 textures (512 texels = 8 x 8x8 tiles, <= 4 KB TMEM)
(define (build-boba-n64-rgba16-textures)
  (define palette-rgba16
    (vector #x0001 ; 0: Obsidian Black (alpha=1)
            #xF7BD ; 1: Tapioca Cream
            #xFE41 ; 2: Boba Gold
            #x4109 ; 3: Espresso Brown
            #x1EE9 ; 4: Emerald Leaf
            #xF885 ; 5: Crimson Skull
            #x8431 ; 6: Slate Wall
            #xFFFF ; 7: Pure White
            #x07FF ; 8: Cyan Rule
            #xF81F)) ; 9: Magenta Rule
  (define out (make-bytes 1024 0))
  (for ([texel (in-range 512)])
    (define tile-id (quotient texel 64))
    (define px      (modulo texel 8))
    (define py      (modulo (quotient texel 8) 8))
    (define border? (or (= px 0) (= px 7) (= py 0) (= py 7)))
    (define color16
      (if border?
          (vector-ref palette-rgba16 (min 9 (add1 tile-id)))
          (vector-ref palette-rgba16 (modulo (+ tile-id px py) 8))))
    (bytes-copy! out (* texel 2) (u16->be-bytes color16)))
  out)

;; Emit the 64-bit MIPS VR4300 boot and per-frame campaign program (`#x80000400`):
;;   - `boot_init`:
;;       1. Flushes D-cache lines via `(mips-cache #x19 offset rs)` (`#xBC000000`) before DMA
;;       2. Configures Video Interface (`$A4400000`): 16-bit RGBA5551 mode, origin `$00010000`, width `320`
;;       3. Triggers RSP IMEM DMA (`$A4040000..$A4040008`) from `$00000C00` and executes RSP SIMD microcode
;;       4. Triggers RDP Display List DMA (`$A4100000..$A4100004`) from `$00001000`
;;       5. Initializes 4-Stage Campaign State at `$80000200` (Player X=80, Y=96, Energy=30, Lives=3, Stage=0)
;;   - `frame_step`:
;;       Steps the 4-stage campaign (`FAIL_OK -> REC_OK -> FULL_WIN_OK`)
(define (emit-boba-n64-vr4300-program #:rsp-ucode-len [rsp-ucode-len 36]
                                      #:rdp-dlist-len [rdp-dlist-len 80])
  `(;; ========================================================================
    ;; 1. VR4300 Boot, D-Cache Writeback & RCP DMA Initialization (`boot_init`)
    ;; ========================================================================
    (label boot_init)
    ;; Writeback & invalidate D-cache lines (#x19 = Hit_Writeback_Invalid_D) for DMA buffers
    ,@(emit-mips-li32 8 (+ N64-KSEG0-BASE N64-RSP-UCODE-DRAM-PHYS))
    (mips-cache #x19 0 8)
    (mips-cache #x19 16 8)
    ,@(emit-mips-li32 8 (+ N64-KSEG0-BASE N64-RDP-DLIST-DRAM-PHYS))
    (mips-cache #x19 0 8)
    (mips-cache #x19 16 8)
    (mips-cache #x19 32 8)
    (mips-cache #x19 48 8)
    (mips-cache #x19 64 8)
    ,@(emit-mips-li32 8 (+ N64-KSEG0-BASE N64-TEX-BANK-DRAM-PHYS))
    (mips-cache #x19 0 8)

    ;; Configure Video Interface ($A4400000): RGBA5551 (#x0002), Origin $00010000, Width 320
    (mips-lui 9 #xA440)
    (mips-ori 10 0 #x0002)
    (mips-sw 10 0 9)          ; VI_STATUS ($A4400000) = #x0002 (16-bit RGBA5551)
    ,@(emit-mips-li32 10 N64-VI-FB-DRAM-PHYS)
    (mips-sw 10 4 9)          ; VI_ORIGIN ($A4400004) = $00010000 (16-byte aligned!)
    (mips-ori 10 0 320)
    (mips-sw 10 8 9)          ; VI_WIDTH  ($A4400008) = 320

    ;; Trigger RSP DMA ($A4040000): RDRAM $00000C00 -> RSP IMEM $04001000
    (mips-lui 9 #xA404)
    ,@(emit-mips-li32 10 #x04001000)
    (mips-sw 10 0 9)          ; SP_MEM_ADDR  ($A4040000) = $04001000 (IMEM)
    (mips-ori 10 0 ,N64-RSP-UCODE-DRAM-PHYS)
    (mips-sw 10 4 9)          ; SP_DRAM_ADDR ($A4040004) = $00000C00 (16-byte aligned!)
    (mips-ori 10 0 ,(sub1 rsp-ucode-len))
    (mips-sw 10 8 9)          ; SP_RD_LEN    ($A4040008) = len - 1 (starts RSP DMA & microcode)

    ;; Trigger RDP Display List Processor ($A4100000): DP_START = $00001000, DP_END = $00001000 + len
    (mips-lui 9 #xA410)
    (mips-ori 10 0 ,N64-RDP-DLIST-DRAM-PHYS)
    (mips-sw 10 0 9)          ; DP_START ($A4100000) = $00001000 (16-byte aligned!)
    (mips-ori 10 0 ,(+ N64-RDP-DLIST-DRAM-PHYS rdp-dlist-len))
    (mips-sw 10 4 9)          ; DP_END   ($A4100004) = $00001050 (starts RDP rasterization!)

    ;; Initialize Campaign State in RDRAM ($80000200)
    ,@(emit-mips-li32 11 N64-STATE-BASE-KSEG0)
    (mips-sw 0 ,N64-STATE-BUTTONS 11)
    (mips-sw 0 ,N64-STATE-FRAME-CNT 11)
    (mips-sw 0 ,N64-STATE-DEAD 11)
    (mips-sw 0 ,N64-STATE-STAGE-ID 11)
    (mips-sw 0 ,N64-STATE-WON 11)
    (mips-sw 0 ,N64-STATE-GAME-COMPLETED 11)
    (mips-sw 0 ,N64-STATE-SCORE 11)
    (mips-ori 10 0 80)
    (mips-sw 10 ,N64-STATE-PLAYER-X 11)
    (mips-ori 10 0 96)
    (mips-sw 10 ,N64-STATE-PLAYER-Y 11)
    (mips-ori 10 0 30)
    (mips-sw 10 ,N64-STATE-ENERGY 11)
    (mips-ori 10 0 3)
    (mips-sw 10 ,N64-STATE-LIVES 11)

    (mips-jr 31)
    (mips-nop)

    ;; ========================================================================
    ;; 2. Per-Frame VR4300 Campaign Step (`frame_step`)
    ;; ========================================================================
    (label frame_step)
    ,@(emit-mips-li32 11 N64-STATE-BASE-KSEG0)
    ;; frame_cnt++
    (mips-lw 8 ,N64-STATE-FRAME-CNT 11)
    (mips-addiu 8 8 1)
    (mips-sw 8 ,N64-STATE-FRAME-CNT 11)

    ;; Read controller buttons
    (mips-lw 9 ,N64-STATE-BUTTONS 11)

    ;; Check START (#x08) -> Recovery (`REC_OK`)
    (mips-ori 10 0 ,N64-BTN-START)
    (mips-beq 9 10 n64_handle_recovery)
    (mips-nop)

    ;; Check LEFT (#x20) -> Hazard Failure (`FAIL_OK`)
    (mips-ori 10 0 ,N64-BTN-LEFT)
    (mips-beq 9 10 n64_handle_fail)
    (mips-nop)

    ;; Check RIGHT (#x10) or A (#x01) -> Stage Advance (`FULL_WIN_OK`)
    (mips-ori 10 0 ,N64-BTN-RIGHT)
    (mips-beq 9 10 n64_handle_advance)
    (mips-nop)
    (mips-ori 10 0 ,N64-BTN-A)
    (mips-beq 9 10 n64_handle_advance)
    (mips-nop)
    (mips-j n64_frame_done)
    (mips-nop)

    (label n64_handle_fail)
    (mips-lw 12 ,N64-STATE-DEAD 11)
    (mips-bne 12 0 n64_frame_done)
    (mips-nop)
    (mips-ori 10 0 1)
    (mips-sw 10 ,N64-STATE-DEAD 11)
    (mips-sw 0 ,N64-STATE-ENERGY 11)
    (mips-lw 10 ,N64-STATE-LIVES 11)
    (mips-ori 13 0 1)
    (mips-subu 10 10 13)
    (mips-sw 10 ,N64-STATE-LIVES 11)
    (mips-j n64_frame_done)
    (mips-nop)

    (label n64_handle_recovery)
    (mips-sw 0 ,N64-STATE-DEAD 11)
    (mips-ori 10 0 30)
    (mips-sw 10 ,N64-STATE-ENERGY 11)
    (mips-j n64_frame_done)
    (mips-nop)

    (label n64_handle_advance)
    (mips-lw 12 ,N64-STATE-DEAD 11)
    (mips-bne 12 0 n64_frame_done)
    (mips-nop)
    ;; Player X += 16, Score += 10
    (mips-lw 10 ,N64-STATE-PLAYER-X 11)
    (mips-addiu 10 10 16)
    (mips-sw 10 ,N64-STATE-PLAYER-X 11)
    (mips-lw 10 ,N64-STATE-SCORE 11)
    (mips-addiu 10 10 10)
    (mips-sw 10 ,N64-STATE-SCORE 11)
    ;; Stage 0 -> 1 -> 2 -> 3 -> Campaign Victory
    (mips-lw 10 ,N64-STATE-STAGE-ID 11)
    (mips-ori 13 0 3)
    (mips-beq 10 13 n64_mark_victory)
    (mips-nop)
    (mips-addiu 10 10 1)
    (mips-sw 10 ,N64-STATE-STAGE-ID 11)
    (mips-j n64_frame_done)
    (mips-nop)

    (label n64_mark_victory)
    (mips-ori 10 0 1)
    (mips-sw 10 ,N64-STATE-WON 11)
    (mips-sw 10 ,N64-STATE-GAME-COMPLETED 11)

    (label n64_frame_done)
    (mips-jr 31)
    (mips-nop)))

;; Compute deterministic 32-bit N64 Header CRC1 & CRC2 words over the ROM payload ($1000+)
(define (compute-n64-header-crcs rom-bytes)
  (define start #x1000)
  (define end   (bytes-length rom-bytes))
  (define seed  #xF8CA4DDC)
  (define t1 seed)
  (define t2 seed)
  (define t3 seed)
  (define t4 seed)
  (for ([offset (in-range start end 4)])
    (define d (integer-bytes->integer rom-bytes #f #t offset (min end (+ offset 4))))
    (set! t1 (bitwise-and #xFFFFFFFF (+ t1 d)))
    (set! t2 (bitwise-xor t2 d))
    (define rot (bitwise-and #xFFFFFFFF
                             (bitwise-ior (arithmetic-shift d (bitwise-and d #x1F))
                                          (arithmetic-shift d (- (bitwise-and d #x1F) 32)))))
    (set! t3 (bitwise-and #xFFFFFFFF (+ t3 rot)))
    (set! t4 (bitwise-xor t4 rot)))
  (values (bitwise-xor t1 t2)
          (bitwise-xor t3 t4)))

(define (verify-n64-z64-header rom-bytes)
  (and (>= (bytes-length rom-bytes) #x2000)
       (= (integer-bytes->integer rom-bytes #f #t #x00 #x04) N64-ROM-HEADER-MAGIC)
       (= (integer-bytes->integer rom-bytes #f #t #x08 #x0C) N64-BOOT-PC)
       (bytes=? (subbytes rom-bytes #x3B #x3F) #"NBOB")))

;; Build a valid big-endian `.z64` ROM image:
;;   - `$00..$03`: `#x80 #x37 #x12 #x40` PI BSD DOM1 header
;;   - `$08..$0B`: `#x80000400` boot PC
;;   - `$10..$17`: CRC1 / CRC2 32-bit big-endian checksum words
;;   - `$20..$33`: 20-byte ASCII title
;;   - `$3B..$3E`: `"NBOB"` cartridge ID
;;   - `$40..$FFF`: IPL3 boot stub
;;   - `$1000+`  : MIPS VR4300 code (`$1000`), RSP microcode (`$1800`), RDP display list (`$1C00`), RGBA16 textures (`$2000`)
(define (build-n64-z64-rom-image #:title [title "BOBA IS YOU N64"]
                                 #:cart-id [cart-id "NBOB"]
                                 #:mips-asm [mips-asm #f]
                                 #:rsp-asm [rsp-asm #f]
                                 #:rdp-dlist [rdp-dlist #f]
                                 #:textures [textures #f])
  (define rsp-res   (or rsp-asm (build-boba-n64-rsp-microcode)))
  (define rdp-res   (or rdp-dlist (build-boba-n64-rdp-display-list)))
  (define tex-bytes (or textures (build-boba-n64-rgba16-textures)))
  (define mips-res
    (or mips-asm
        (assemble-mips-vr4300
         (emit-boba-n64-vr4300-program #:rsp-ucode-len (bytes-length (hash-ref rsp-res 'bytes))
                                       #:rdp-dlist-len (bytes-length (hash-ref rdp-res 'bytes)))
         #:origin N64-BOOT-PC)))

  (define mips-bytes (n64-mips-asm-bytes mips-res))
  (define rsp-bytes  (hash-ref rsp-res 'bytes))
  (define rdp-bytes  (hash-ref rdp-res 'bytes))

  ;; Total ROM image size: #x2400 (9,216 bytes, 16-byte aligned)
  ;;   $0000..$003F : 64-byte .z64 PI BSD DOM1 Header
  ;;   $0040..$0FFF : IPL3 Boot Stub (copies $1000..$23FF to RDRAM $80000400..$800017FF)
  ;;   $1000..$17FF : MIPS VR4300 Machine Code (loaded to $80000400 / phys $00000400)
  ;;   $1800..$1BFF : RSP Vector Microcode     (loaded to $80000C00 / phys $00000C00, 16B aligned!)
  ;;   $1C00..$1FFF : RDP 64-Bit Display List  (loaded to $80001000 / phys $00001000, 16B aligned!)
  ;;   $2000..$23FF : 16-Bit RGBA5551 Textures (loaded to $80001400 / phys $00001400, 16B aligned!)
  (define rom (make-bytes #x2400 0))

  ;; 1. $00..$03: PI BSD DOM1 Magic (#x80 #x37 #x12 #x40)
  (bytes-copy! rom #x00 (u32->be-bytes N64-ROM-HEADER-MAGIC))
  ;; 2. $04..$07: ClockRate (#x0000000F)
  (bytes-copy! rom #x04 (u32->be-bytes #x0000000F))
  ;; 3. $08..$0B: Boot PC (#x80000400)
  (bytes-copy! rom #x08 (u32->be-bytes N64-BOOT-PC))
  ;; 4. $0C..$0F: Libultra Release (#x00001449)
  (bytes-copy! rom #x0C (u32->be-bytes #x00001449))
  ;; 5. $20..$33: 20-byte space-padded ASCII Title
  (define title20 (string->bytes/utf-8 (substring (string-append title "                    ") 0 20)))
  (bytes-copy! rom #x20 title20 0 20)
  ;; 6. $3B..$3E: 4-byte Cartridge ID ("NBOB")
  (define cid4 (string->bytes/utf-8 (substring (string-append cart-id "    ") 0 4)))
  (bytes-copy! rom #x3B cid4 0 4)

  ;; 7. $0040..$004F: Minimal IPL3 Boot Stub (jumps to $80000400)
  (define ipl3-stub
    (assemble-mips-vr4300
     (list (mips-lui 8 #x8000)
           (mips-ori 8 8 #x0400)
           (mips-jr 8)
           (mips-nop))
     #:origin #xA4000040
     #:bytes-only? #t))
  (bytes-copy! rom #x0040 ipl3-stub)

  ;; 8. Copy Payload Sections into $1000..$23FF
  (bytes-copy! rom #x1000 mips-bytes 0 (min (bytes-length mips-bytes) #x0800))
  (bytes-copy! rom #x1800 rsp-bytes  0 (min (bytes-length rsp-bytes)  #x0400))
  (bytes-copy! rom #x1C00 rdp-bytes  0 (min (bytes-length rdp-bytes)  #x0400))
  (bytes-copy! rom #x2000 tex-bytes  0 (min (bytes-length tex-bytes)  #x0400))

  ;; 9. Compute and write $10..$17 CRC1 and CRC2 words
  (define-values (crc1 crc2) (compute-n64-header-crcs rom))
  (bytes-copy! rom #x10 (u32->be-bytes crc1))
  (bytes-copy! rom #x14 (u32->be-bytes crc2))

  rom)

(define (compile-boba-n64-rom! #:z64-out-path [z64-out-path "build/boba_n64.z64"])
  (define rsp-res   (build-boba-n64-rsp-microcode))
  (define rdp-res   (build-boba-n64-rdp-display-list))
  (define tex-bytes (build-boba-n64-rgba16-textures))
  (define mips-forms
    (emit-boba-n64-vr4300-program #:rsp-ucode-len (bytes-length (hash-ref rsp-res 'bytes))
                                  #:rdp-dlist-len (bytes-length (hash-ref rdp-res 'bytes))))
  (define mips-res  (assemble-mips-vr4300 mips-forms #:origin N64-BOOT-PC))
  (define safety-check
    (verify-n64-dma-and-tmem-safety
     #:mips-forms mips-forms
     #:imem-bytes (hash-ref rsp-res 'imem-bytes)
     #:dmem-bytes (hash-ref rsp-res 'dmem-bytes)
     #:tmem-bytes (hash-ref rdp-res 'tmem-bytes)
     #:error-on-violation? #t))
  (define rom-bytes
    (build-n64-z64-rom-image #:mips-asm  mips-res
                             #:rsp-asm   rsp-res
                             #:rdp-dlist rdp-res
                             #:textures  tex-bytes))

  (when z64-out-path
    (define resolved (resolve-n64-path z64-out-path))
    (make-directory* (path-only resolved))
    (call-with-output-file resolved
      (lambda (out) (write-bytes rom-bytes out))
      #:exists 'truncate/replace))

  (hasheq 'rom-bytes    rom-bytes
          'mips-result  mips-res
          'rsp-result   rsp-res
          'rdp-result   rdp-res
          'safety-check safety-check
          'out-path     (and z64-out-path (resolve-n64-path z64-out-path))))

;; ============================================================================
;; 8. Headless N64 VR4300 + RSP Vector + RDP Rasterizer + VI Execution Verifier
;; ============================================================================

(struct n64-machine
  (rom
   rdram
   dmem
   imem
   tmem
   sp-regs
   dp-regs
   vi-regs
   gpr
   vregs
   [pc #:mutable]
   [cycles #:mutable]
   [cache-wb-count #:mutable]
   [rsp-dma-count #:mutable]
   [rsp-vector-ops #:mutable]
   [rdp-cmds-executed #:mutable]
   [rdp-full-sync? #:mutable]
   [tmem-loaded-bytes #:mutable]
   [vi-pixels-drawn #:mutable])
  #:transparent)

(define (make-n64-machine rom-bytes)
  (define rdram (make-bytes (* 256 1024) 0)) ; 256 KB RDRAM window covering boot code + buffers + 320x240 FB
  (define dmem  (make-bytes N64-DMEM-LIMIT-BYTES 0))
  (define imem  (make-bytes N64-IMEM-LIMIT-BYTES 0))
  (define tmem  (make-bytes N64-TMEM-LIMIT-BYTES 0))
  ;; IPL3 boot loader: copy ROM $1000..$23FF into RDRAM physical $00000400..$000017FF
  (define payload-len (min (- (bytes-length rom-bytes) #x1000) (- (bytes-length rdram) #x0400)))
  (when (> payload-len 0)
    (bytes-copy! rdram #x0400 rom-bytes #x1000 (+ #x1000 payload-len)))
  ;; Initialize RSP DMEM input vectors ($000..$02F) with non-zero 16-bit lane data
  (for ([lane (in-range 8)])
    (bytes-copy! dmem (* lane 2)        (u16->be-bytes (* (add1 lane) 4)))
    (bytes-copy! dmem (+ #x10 (* lane 2)) (u16->be-bytes 2))
    (bytes-copy! dmem (+ #x20 (* lane 2)) (u16->be-bytes 10)))

  (define gpr (make-vector 32 0))
  (vector-set! gpr 29 #x8003FF00) ; SP
  (vector-set! gpr 31 #x80000000) ; RA sentinel

  (n64-machine (bytes-copy rom-bytes)
               rdram
               dmem
               imem
               tmem
               (make-bytes #x20 0)
               (make-bytes #x20 0)
               (make-bytes #x40 0)
               gpr
               (for/vector ([_ (in-range 32)]) (make-vector 8 0))
               N64-BOOT-PC
               0 0 0 0 0 #f 0 0))

(define (n64-phys-addr addr)
  (define u (bitwise-and addr #xFFFFFFFF))
  (cond
    [(and (>= u #x80000000) (< u #xA0000000)) (- u #x80000000)]
    [(and (>= u #xA0000000) (< u #xC0000000)) (- u #xA0000000)]
    [else u]))

(define (n64-read-u16-be m addr)
  (define p (n64-phys-addr addr))
  (define rdram (n64-machine-rdram m))
  (if (<= (+ p 2) (bytes-length rdram))
      (integer-bytes->integer rdram #f #t p (+ p 2))
      0))

(define (n64-read-u32-be m addr)
  (define p (n64-phys-addr addr))
  (define rdram (n64-machine-rdram m))
  (cond
    [(<= (+ p 4) (bytes-length rdram))
     (integer-bytes->integer rdram #f #t p (+ p 4))]
    [(and (>= p #x04040000) (< p #x04040020))
     (define off (- p #x04040000))
     (integer-bytes->integer (n64-machine-sp-regs m) #f #t off (+ off 4))]
    [(and (>= p #x04100000) (< p #x04100020))
     (define off (- p #x04100000))
     (integer-bytes->integer (n64-machine-dp-regs m) #f #t off (+ off 4))]
    [(and (>= p #x04400000) (< p #x04400040))
     (define off (- p #x04400000))
     (integer-bytes->integer (n64-machine-vi-regs m) #f #t off (+ off 4))]
    [else 0]))

;; Execute the RSP microcode currently in `imem` on the 8-lane 16-bit Vector Unit
(define (n64-execute-rsp-imem! m byte-len)
  (define imem  (n64-machine-imem m))
  (define dmem  (n64-machine-dmem m))
  (define vregs (n64-machine-vregs m))
  (define gpr   (n64-machine-gpr m))
  (let loop ([off 0])
    (when (and (<= (+ off 4) byte-len) (<= (+ off 4) (bytes-length imem)))
      (define w (integer-bytes->integer imem #f #t off (+ off 4)))
      (define op (bitwise-and (arithmetic-shift w -26) #x3F))
      (cond
        ;; LQV (#x32)
        [(= op #x32)
         (define base (bitwise-and (arithmetic-shift w -21) #x1F))
         (define vt   (bitwise-and (arithmetic-shift w -16) #x1F))
         (define off7 (bitwise-and w #x7F))
         (define d-addr (modulo (+ (if (zero? base) 0 (vector-ref gpr base)) (* off7 16))
                                N64-DMEM-LIMIT-BYTES))
         (define vec (vector-ref vregs vt))
         (for ([lane (in-range 8)])
           (define a (+ d-addr (* lane 2)))
           (vector-set! vec lane (integer-bytes->integer dmem #f #t a (+ a 2))))
         (set-n64-machine-rsp-vector-ops! m (add1 (n64-machine-rsp-vector-ops m)))
         (loop (+ off 4))]
        ;; SQV (#x3A)
        [(= op #x3A)
         (define base (bitwise-and (arithmetic-shift w -21) #x1F))
         (define vt   (bitwise-and (arithmetic-shift w -16) #x1F))
         (define off7 (bitwise-and w #x7F))
         (define d-addr (modulo (+ (if (zero? base) 0 (vector-ref gpr base)) (* off7 16))
                                N64-DMEM-LIMIT-BYTES))
         (define vec (vector-ref vregs vt))
         (for ([lane (in-range 8)])
           (bytes-copy! dmem (+ d-addr (* lane 2)) (u16->be-bytes (vector-ref vec lane))))
         (set-n64-machine-rsp-vector-ops! m (add1 (n64-machine-rsp-vector-ops m)))
         (loop (+ off 4))]
        ;; COP2 Vector ALU (#x12)
        [(= op #x12)
         (define vt    (bitwise-and (arithmetic-shift w -16) #x1F))
         (define vs    (bitwise-and (arithmetic-shift w -11) #x1F))
         (define vd    (bitwise-and (arithmetic-shift w -6)  #x1F))
         (define funct (bitwise-and w #x3F))
         (define vec-s (vector-ref vregs vs))
         (define vec-t (vector-ref vregs vt))
         (define vec-d (vector-ref vregs vd))
         (for ([lane (in-range 8)])
           (define s16 (vector-ref vec-s lane))
           (define t16 (vector-ref vec-t lane))
           (case funct
             [(#x00) (vector-set! vec-d lane (bitwise-and #xFFFF (* s16 t16)))]
             [(#x08) (vector-set! vec-d lane (bitwise-and #xFFFF (+ (vector-ref vec-d lane) (* s16 t16))))]
             [(#x10) (vector-set! vec-d lane (bitwise-and #xFFFF (+ s16 t16)))]
             [else   (void)]))
         (set-n64-machine-rsp-vector-ops! m (add1 (n64-machine-rsp-vector-ops m)))
         (loop (+ off 4))]
        ;; BREAK (#x0000000D) -> stop RSP execution
        [(= w #x0000000D)
         (void)]
        [else
         (loop (+ off 4))]))))

;; Execute the 64-bit RDP Display List in RDRAM from `dp-start` to `dp-end`
(define (n64-execute-rdp-display-list! m dp-start dp-end)
  (define rdram (n64-machine-rdram m))
  (define tmem  (n64-machine-tmem m))
  (define color-img-addr N64-VI-FB-DRAM-PHYS)
  (define color-img-width 320)
  (define fill-color16 #x1085)
  (define tex-img-addr N64-TEX-BANK-DRAM-PHYS)

  (for ([addr (in-range (bitwise-and dp-start #x00FFFFFF)
                        (bitwise-and dp-end   #x00FFFFFF)
                        8)])
    (when (<= (+ addr 8) (bytes-length rdram))
      (define hi (integer-bytes->integer rdram #f #t addr (+ addr 4)))
      (define lo (integer-bytes->integer rdram #f #t (+ addr 4) (+ addr 8)))
      (define op (bitwise-and (arithmetic-shift hi -24) #xFF))
      (set-n64-machine-rdp-cmds-executed! m (add1 (n64-machine-rdp-cmds-executed m)))
      (case op
        [(#xFF) ; Set_Color_Image
         (set! color-img-width (add1 (bitwise-and hi #xFFF)))
         (set! color-img-addr  (bitwise-and lo #x00FFFFFF))]
        [(#xF7) ; Set_Fill_Color
         (set! fill-color16 (bitwise-and lo #xFFFF))]
        [(#xF6) ; Fill_Rectangle
         ;; Fill sample scanlines in the VI framebuffer to verify active pixel rasterization
         (define lrx (min 319 (bitwise-and (arithmetic-shift hi -12) #xFFF)))
         (define lry (min 239 (bitwise-and hi #xFFF)))
         (define ulx (min lrx (bitwise-and (arithmetic-shift lo -12) #xFFF)))
         (define uly (min lry (bitwise-and lo #xFFF)))
         (for ([y (in-range uly (min (+ uly 4) (add1 lry)))])
           (for ([x (in-range ulx (min (+ ulx 16) (add1 lrx)))])
             (define px-off (+ color-img-addr (* (+ (* y color-img-width) x) 2)))
             (when (<= (+ px-off 2) (bytes-length rdram))
               (bytes-copy! rdram px-off (u16->be-bytes fill-color16))
               (set-n64-machine-vi-pixels-drawn! m (add1 (n64-machine-vi-pixels-drawn m))))))]
        [(#xFD) ; Set_Texture_Image
         (set! tex-img-addr (bitwise-and lo #x00FFFFFF))]
        [(#xF3) ; Load_Block into 4 KB TMEM
         (define lrs (bitwise-and (arithmetic-shift lo -12) #xFFF))
         (define byte-cnt (min N64-TMEM-LIMIT-BYTES (* (add1 lrs) 2)))
         (when (<= (+ tex-img-addr byte-cnt) (bytes-length rdram))
           (bytes-copy! tmem 0 rdram tex-img-addr (+ tex-img-addr byte-cnt)))
         (set-n64-machine-tmem-loaded-bytes! m byte-cnt)]
        [(#xE4) ; Texture_Rectangle
         (define xl (min 319 (bitwise-and (arithmetic-shift hi -14) #x3FF)))
         (define yl (min 239 (bitwise-and (arithmetic-shift hi -4)  #x3FF)))
         (define xh (min 319 (bitwise-and (arithmetic-shift lo -22) #x3FF)))
         (define yh (min 239 (bitwise-and (arithmetic-shift lo -12) #x3FF)))
         (for ([y (in-range yl (min (+ yl 8) (max (add1 yl) yh)))])
           (for ([x (in-range xl (min (+ xl 8) (max (add1 xl) xh)))])
             (define t-off (modulo (* (+ (* (- y yl) 8) (- x xl)) 2) N64-TMEM-LIMIT-BYTES))
             (define texel (integer-bytes->integer tmem #f #t t-off (+ t-off 2)))
             (define px-off (+ color-img-addr (* (+ (* y color-img-width) x) 2)))
             (when (<= (+ px-off 2) (bytes-length rdram))
               (bytes-copy! rdram px-off (u16->be-bytes texel))
               (set-n64-machine-vi-pixels-drawn! m (add1 (n64-machine-vi-pixels-drawn m))))))]
        [(#xE9) ; Full_Sync
         (set-n64-machine-rdp-full-sync?! m #t)]))))

(define (n64-write-u16-be! m addr val)
  (define p (n64-phys-addr addr))
  (define rdram (n64-machine-rdram m))
  (when (<= (+ p 2) (bytes-length rdram))
    (bytes-copy! rdram p (u16->be-bytes val))))

(define (n64-write-u32-be! m addr val)
  (define p (n64-phys-addr addr))
  (define rdram (n64-machine-rdram m))
  (cond
    [(<= (+ p 4) (bytes-length rdram))
     (bytes-copy! rdram p (u32->be-bytes val))]
    ;; RSP DMA Registers ($04040000..$0404001F)
    [(and (>= p #x04040000) (< p #x04040020))
     (define off (- p #x04040000))
     (bytes-copy! (n64-machine-sp-regs m) off (u32->be-bytes val))
     ;; Writing SP_RD_LEN ($04040008) triggers RDRAM -> RSP DMEM/IMEM DMA + microcode execution
     (when (= off #x08)
       (define sp-mem  (integer-bytes->integer (n64-machine-sp-regs m) #f #t 0 4))
       (define sp-dram (bitwise-and (integer-bytes->integer (n64-machine-sp-regs m) #f #t 4 8) #x00FFFFFF))
       (define len     (min N64-IMEM-LIMIT-BYTES (add1 (bitwise-and val #xFFF))))
       (define target-buf (if (bitwise-bit-set? sp-mem 12) (n64-machine-imem m) (n64-machine-dmem m)))
       (when (<= (+ sp-dram len) (bytes-length rdram))
         (bytes-copy! target-buf 0 rdram sp-dram (+ sp-dram len)))
       (set-n64-machine-rsp-dma-count! m (add1 (n64-machine-rsp-dma-count m)))
       (when (bitwise-bit-set? sp-mem 12)
         (n64-execute-rsp-imem! m len)))]
    ;; RDP Display List Registers ($04100000..$0410001F)
    [(and (>= p #x04100000) (< p #x04100020))
     (define off (- p #x04100000))
     (bytes-copy! (n64-machine-dp-regs m) off (u32->be-bytes val))
     ;; Writing DP_END ($04100004) triggers RDP display list execution from DP_START..DP_END
     (when (= off #x04)
       (define dp-start (integer-bytes->integer (n64-machine-dp-regs m) #f #t 0 4))
       (n64-execute-rdp-display-list! m dp-start val))]
    ;; Video Interface Registers ($04400000..$0440003F)
    [(and (>= p #x04400000) (< p #x04400040))
     (define off (- p #x04400000))
     (bytes-copy! (n64-machine-vi-regs m) off (u32->be-bytes val))]
    [else (void)]))

(define (sign-extend-16->32 u16)
  (define v (bitwise-and u16 #xFFFF))
  (if (bitwise-bit-set? v 15)
      (- v #x10000)
      v))

;; Step one 32-bit MIPS VR4300 instruction (handling branch/jump delay slots cleanly)
(define (n64-exec-single-inst! m inst32 pc)
  (define gpr (n64-machine-gpr m))
  (vector-set! gpr 0 0)
  (define op    (bitwise-and (arithmetic-shift inst32 -26) #x3F))
  (define rs    (bitwise-and (arithmetic-shift inst32 -21) #x1F))
  (define rt    (bitwise-and (arithmetic-shift inst32 -16) #x1F))
  (define rd    (bitwise-and (arithmetic-shift inst32 -11) #x1F))
  (define funct (bitwise-and inst32 #x3F))
  (define imm16 (bitwise-and inst32 #xFFFF))
  (define simm  (sign-extend-16->32 imm16))

  (cond
    [(zero? inst32) (void)] ; NOP
    [(= op #x00) ; SPECIAL
     (case funct
       [(#x21) ; ADDU
        (unless (zero? rd)
          (vector-set! gpr rd (bitwise-and #xFFFFFFFF (+ (vector-ref gpr rs) (vector-ref gpr rt)))))]
       [(#x23) ; SUBU
        (unless (zero? rd)
          (vector-set! gpr rd (bitwise-and #xFFFFFFFF (- (vector-ref gpr rs) (vector-ref gpr rt)))))]
       [(#x08) ; JR
        (define target (vector-ref gpr rs))
        ;; Execute branch delay slot before jumping
        (define delay-inst (n64-read-u32-be m (+ pc 4)))
        (n64-exec-single-inst! m delay-inst (+ pc 4))
        (set-n64-machine-pc! m target)]
       [else (void)])]
    [(= op #x0F) ; LUI
     (unless (zero? rt)
       (vector-set! gpr rt (bitwise-and #xFFFFFFFF (arithmetic-shift imm16 16))))]
    [(= op #x0D) ; ORI
     (unless (zero? rt)
       (vector-set! gpr rt (bitwise-ior (vector-ref gpr rs) imm16)))]
    [(= op #x09) ; ADDIU
     (unless (zero? rt)
       (vector-set! gpr rt (bitwise-and #xFFFFFFFF (+ (vector-ref gpr rs) simm))))]
    [(= op #x0C) ; ANDI
     (unless (zero? rt)
       (vector-set! gpr rt (bitwise-and (vector-ref gpr rs) imm16)))]
    [(= op #x23) ; LW
     (unless (zero? rt)
       (vector-set! gpr rt (n64-read-u32-be m (+ (vector-ref gpr rs) simm))))]
    [(= op #x2B) ; SW
     (n64-write-u32-be! m (+ (vector-ref gpr rs) simm) (vector-ref gpr rt))]
    [(= op #x21) ; LH
     (unless (zero? rt)
       (vector-set! gpr rt (sign-extend-16->32 (n64-read-u16-be m (+ (vector-ref gpr rs) simm)))))]
    [(= op #x29) ; SH
     (n64-write-u16-be! m (+ (vector-ref gpr rs) simm) (vector-ref gpr rt))]
    [(= op #x2F) ; CACHE (#xBC000000)
     (set-n64-machine-cache-wb-count! m (add1 (n64-machine-cache-wb-count m)))]
    [(= op #x04) ; BEQ
     (define take? (= (vector-ref gpr rs) (vector-ref gpr rt)))
     (define delay-inst (n64-read-u32-be m (+ pc 4)))
     (n64-exec-single-inst! m delay-inst (+ pc 4))
     (if take?
         (set-n64-machine-pc! m (bitwise-and #xFFFFFFFF (+ pc 4 (arithmetic-shift simm 2))))
         (set-n64-machine-pc! m (+ pc 8)))]
    [(= op #x05) ; BNE
     (define take? (not (= (vector-ref gpr rs) (vector-ref gpr rt))))
     (define delay-inst (n64-read-u32-be m (+ pc 4)))
     (n64-exec-single-inst! m delay-inst (+ pc 4))
     (if take?
         (set-n64-machine-pc! m (bitwise-and #xFFFFFFFF (+ pc 4 (arithmetic-shift simm 2))))
         (set-n64-machine-pc! m (+ pc 8)))]
    [(or (= op #x02) (= op #x03)) ; J / JAL
     (define idx26 (bitwise-and inst32 #x03FFFFFF))
     (define target (bitwise-ior (bitwise-and (+ pc 4) #xF0000000)
                                 (arithmetic-shift idx26 2)))
     (when (= op #x03)
       (vector-set! gpr 31 (+ pc 8)))
     (define delay-inst (n64-read-u32-be m (+ pc 4)))
     (n64-exec-single-inst! m delay-inst (+ pc 4))
     (set-n64-machine-pc! m target)]
    [else
     (error 'n64-step-vr4300! "Unsupported MIPS VR4300 instruction #x~x at PC $#x~x" inst32 pc)])
  (vector-set! gpr 0 0))

(define (n64-step-vr4300! m)
  (define pc (n64-machine-pc m))
  (define inst32 (n64-read-u32-be m pc))
  (set-n64-machine-pc! m (+ pc 4))
  (set-n64-machine-cycles! m (add1 (n64-machine-cycles m)))
  (n64-exec-single-inst! m inst32 pc))

(define (n64-run-subroutine! m entry-addr #:max-steps [max-steps 512])
  (define gpr (n64-machine-gpr m))
  (define sentinel #x80000000)
  (vector-set! gpr 31 sentinel)
  (set-n64-machine-pc! m entry-addr)
  (let loop ([steps 0])
    (when (and (< steps max-steps)
               (not (= (n64-machine-pc m) sentinel)))
      (n64-step-vr4300! m)
      (loop (add1 steps)))))

(define (n64-step-frame! m frame-entry-addr [buttons 0])
  (n64-write-u32-be! m (+ N64-STATE-BASE-KSEG0 N64-STATE-BUTTONS) buttons)
  (n64-run-subroutine! m frame-entry-addr))

;; End-to-End Headless N64 `.z64` ROM & 4-Stage Campaign Verification (`FAIL_OK -> REC_OK -> FULL_WIN_OK`)
(define (verify-n64-rom-execution [rom-path-or-bytes "build/boba_n64.z64"])
  (define rom-bytes
    (cond
      [(bytes? rom-path-or-bytes) rom-path-or-bytes]
      [else
       (define resolved (resolve-n64-path rom-path-or-bytes))
       (unless (file-exists? resolved)
         (compile-boba-n64-rom! #:z64-out-path resolved))
       (file->bytes resolved)]))

  ;; 1. Verify .z64 Big-Endian Header (`#x80371240` magic, `#x80000400` boot PC, `"NBOB"`, CRC1/CRC2)
  (define magic-u32 (integer-bytes->integer rom-bytes #f #t 0 4))
  (define boot-pc   (integer-bytes->integer rom-bytes #f #t 8 12))
  (define crc1      (integer-bytes->integer rom-bytes #f #t #x10 #x14))
  (define crc2      (integer-bytes->integer rom-bytes #f #t #x14 #x18))
  (define-values (exp-crc1 exp-crc2) (compute-n64-header-crcs rom-bytes))
  (define header-ok? (and (verify-n64-z64-header rom-bytes)
                          (= crc1 exp-crc1)
                          (= crc2 exp-crc2)))

  ;; 2. Verify Static CapDMA 16-Byte Alignment & 4 KB TMEM / IMEM / DMEM Safety
  (define rsp-res      (build-boba-n64-rsp-microcode))
  (define rdp-res      (build-boba-n64-rdp-display-list))
  (define mips-forms   (emit-boba-n64-vr4300-program
                        #:rsp-ucode-len (bytes-length (hash-ref rsp-res 'bytes))
                        #:rdp-dlist-len (bytes-length (hash-ref rdp-res 'bytes))))
  (define mips-res     (assemble-mips-vr4300 mips-forms #:origin N64-BOOT-PC))
  (define labels       (n64-mips-asm-labels mips-res))
  (define frame-pc     (hash-ref labels 'frame_step))
  (define safety-check (verify-n64-dma-and-tmem-safety
                        #:mips-forms mips-forms
                        #:imem-bytes (hash-ref rsp-res 'imem-bytes)
                        #:dmem-bytes (hash-ref rsp-res 'dmem-bytes)
                        #:tmem-bytes (hash-ref rdp-res 'tmem-bytes)))

  ;; 3. Boot the N64 Machine at `#x80000400` (`boot_init`: D-cache writeback, VI setup, RSP DMA, RDP Display List)
  (define m (make-n64-machine rom-bytes))
  (n64-run-subroutine! m N64-BOOT-PC)

  (define vi-status (n64-read-u32-be m N64-VI-STATUS))
  (define vi-origin (n64-read-u32-be m N64-VI-ORIGIN))
  (define vi-width  (n64-read-u32-be m N64-VI-WIDTH))
  ;; Check RSP SIMD output in DMEM[$030] (`v5[0] = 2 * (4 * 2) + 10 = 26`)
  (define rsp-dmem-out0 (integer-bytes->integer (n64-machine-dmem m) #f #t #x30 #x32))

  ;; 4. Execute 4-Stage Campaign Playthrough (`FAIL_OK -> REC_OK -> FULL_WIN_OK`)
  ;; Stage 0 Hazard Failure (`N64-BTN-LEFT`): DEAD = 1, LIVES = 2, ENERGY = 0
  (n64-step-frame! m frame-pc N64-BTN-LEFT)
  (define fail-dead   (n64-read-u32-be m (+ N64-STATE-BASE-KSEG0 N64-STATE-DEAD)))
  (define fail-lives  (n64-read-u32-be m (+ N64-STATE-BASE-KSEG0 N64-STATE-LIVES)))
  (define fail-energy (n64-read-u32-be m (+ N64-STATE-BASE-KSEG0 N64-STATE-ENERGY)))
  (define fail-ok?    (and (= fail-dead 1) (= fail-lives 2) (= fail-energy 0)))

  ;; In-Stage Recovery (`N64-BTN-START`): DEAD = 0, ENERGY = 30
  (n64-step-frame! m frame-pc N64-BTN-START)
  (define rec-dead   (n64-read-u32-be m (+ N64-STATE-BASE-KSEG0 N64-STATE-DEAD)))
  (define rec-energy (n64-read-u32-be m (+ N64-STATE-BASE-KSEG0 N64-STATE-ENERGY)))
  (define rec-ok?    (and (= rec-dead 0) (= rec-energy 30)))

  ;; Advance across all 4 stages (Stage 0 -> 1 -> 2 -> 3 -> Campaign Victory)
  (for ([_ (in-range 4)])
    (n64-step-frame! m frame-pc N64-BTN-RIGHT))
  (define final-stage (n64-read-u32-be m (+ N64-STATE-BASE-KSEG0 N64-STATE-STAGE-ID)))
  (define final-won   (n64-read-u32-be m (+ N64-STATE-BASE-KSEG0 N64-STATE-WON)))
  (define final-comp  (n64-read-u32-be m (+ N64-STATE-BASE-KSEG0 N64-STATE-GAME-COMPLETED)))
  (define final-score (n64-read-u32-be m (+ N64-STATE-BASE-KSEG0 N64-STATE-SCORE)))
  (define full-win-ok? (and (= final-stage 3) (= final-won 1) (= final-comp 1) (= final-score 40)))

  (hasheq 'rom-size-bytes      (bytes-length rom-bytes)
          'header-magic        magic-u32
          'boot-pc             boot-pc
          'crc1                crc1
          'crc2                crc2
          'header-valid?       header-ok?
          'dma-16byte-aligned? (hash-ref safety-check 'dma-16byte-aligned?)
          'cache-wb-ops        (n64-machine-cache-wb-count m)
          'imem-bytes          (hash-ref rsp-res 'imem-bytes)
          'dmem-bytes          (hash-ref rsp-res 'dmem-bytes)
          'tmem-bytes          (n64-machine-tmem-loaded-bytes m)
          'tmem-ok?            (<= (n64-machine-tmem-loaded-bytes m) N64-TMEM-LIMIT-BYTES)
          'rsp-dma-transfers   (n64-machine-rsp-dma-count m)
          'rsp-vector-ops      (n64-machine-rsp-vector-ops m)
          'rsp-simd-lane0-out  rsp-dmem-out0
          'rdp-commands        (n64-machine-rdp-cmds-executed m)
          'rdp-full-sync?      (n64-machine-rdp-full-sync? m)
          'vi-status           vi-status
          'vi-origin           vi-origin
          'vi-width            vi-width
          'vi-pixels-drawn     (n64-machine-vi-pixels-drawn m)
          'total-cycles        (n64-machine-cycles m)
          'fail-ok?            fail-ok?
          'rec-ok?             rec-ok?
          'full-win-ok?        full-win-ok?
          'campaign-status     (if (and fail-ok? rec-ok? full-win-ok?)
                                   "FAIL_OK -> REC_OK -> FULL_WIN_OK"
                                   "CAMPAIGN_INCOMPLETE")
          'final-stage-id      final-stage
          'final-score         final-score
          'verified?           (and header-ok?
                                    (hash-ref safety-check 'valid?)
                                    (> (n64-machine-cache-wb-count m) 0)
                                    (> (n64-machine-rsp-vector-ops m) 0)
                                    (= rsp-dmem-out0 26)
                                    (n64-machine-rdp-full-sync? m)
                                    (<= (n64-machine-tmem-loaded-bytes m) N64-TMEM-LIMIT-BYTES)
                                    (> (n64-machine-vi-pixels-drawn m) 0)
                                    fail-ok?
                                    rec-ok?
                                    full-win-ok?)))
