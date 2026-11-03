#lang racket/base

;; ============================================================================
;; compiler/backend-gb-gbc.rkt
;; Sharp SM83 (LR35902) Two-Pass Assembler, Peephole Optimizer,
;; Game Boy (.gb DMG) & Game Boy Color (.gbc CGB) Cartridge Linker,
;; and Headless SM83 + PPU / HRAM OAM DMA / STAT Mode Verifier
;; ============================================================================

(require racket/match
         racket/list
         racket/bytes
         racket/format
         racket/string
         racket/math
         racket/path
         racket/file)

(provide
 ;; 1. SM83 Assembler & Peephole Optimizer
 (struct-out sm83-asm-result)
 sm83-asm-result-bytes*
 assemble-sm83
 assemble-sm83-detailed
 optimize-sm83-peephole
 optimize-sm83-peephole-stats
 emit-hram-oam-dma-trampoline
 HRAM-OAM-DMA-TRAMPOLINE-BYTES

 ;; 2. Game Boy / Game Boy Color Header, Logo, Tiles, Palettes & Checksums
 NINTENDO-GB-LOGO-BYTES
 compute-gb-header-checksum
 compute-gb-global-checksum
 compile-gb-2bpp-tile
 encode-gbc-bgr555
 build-gb-rom-image
 compile-boba-gb-rom!

 ;; 3. Headless SM83 + DMG/CGB PPU Step Simulator & Campaign Verifier
 (struct-out gb-emulator)
 make-gb-emulator-from-rom
 gb-step!
 gb-step-frame!
 verify-gb-rom-execution

 ;; 4. Hardware Constants & Joypad Bitmasks
 GB-BTN-RIGHT
 GB-BTN-LEFT
 GB-BTN-UP
 GB-BTN-DOWN
 GB-BTN-A
 GB-BTN-B
 GB-BTN-SELECT
 GB-BTN-START
 GB-HRAM-JOYPAD
 GB-HRAM-STAGE-ID
 GB-HRAM-PLAYER-X
 GB-HRAM-PLAYER-Y
 GB-HRAM-FAILED
 GB-HRAM-RECOVERED
 GB-HRAM-WON
 GB-HRAM-SCORE
 GB-HRAM-FRAME-CNT
 GB-HRAM-DMA-COUNT)

;; ============================================================================
;; 1. Hardware Constants, Joypad Masks & HRAM Layout
;; ============================================================================

(define GB-BTN-RIGHT  #x01)
(define GB-BTN-LEFT   #x02)
(define GB-BTN-UP     #x04)
(define GB-BTN-DOWN   #x08)
(define GB-BTN-A      #x10)
(define GB-BTN-B      #x20)
(define GB-BTN-SELECT #x40)
(define GB-BTN-START  #x80)

;; Pinned High-RAM ($FF80-$FFFE) layout:
;;   $FF80-$FF89 : 10-byte OAM DMA routine
;;   $FF90-$FF9F : Game state variables accessible during single-cycle LDH
(define GB-HRAM-JOYPAD    #x90) ; $FF90
(define GB-HRAM-STAGE-ID  #x91) ; $FF91
(define GB-HRAM-PLAYER-X  #x92) ; $FF92
(define GB-HRAM-PLAYER-Y  #x93) ; $FF93
(define GB-HRAM-FAILED    #x94) ; $FF94
(define GB-HRAM-RECOVERED #x95) ; $FF95
(define GB-HRAM-WON       #x96) ; $FF96
(define GB-HRAM-SCORE     #x97) ; $FF97
(define GB-HRAM-FRAME-CNT #x98) ; $FF98
(define GB-HRAM-DMA-COUNT #x99) ; $FF99

;; Official 48-byte Nintendo Boot Logo ($0104-$0133) verified by DMG/CGB boot ROM
(define NINTENDO-GB-LOGO-BYTES
  (bytes
   #xCE #xED #x66 #x66 #xCC #x0D #x00 #x0B #x03 #x73 #x00 #x83 #x00 #x0C #x00 #x0D
   #x00 #x08 #x11 #x1F #x88 #x89 #x00 #x0E #xDC #xCC #x6E #xE6 #xDD #xDD #xD9 #x99
   #xBB #xBB #x67 #x63 #x6E #x0E #xEC #xCC #xDD #xDC #x99 #x9F #xBB #xB9 #x33 #x3E))

;; ============================================================================
;; 2. Sharp SM83 (LR35902) Peephole Optimizer & Two-Pass Assembler
;; ============================================================================

(struct sm83-asm-result
  (bytes
   origin
   labels
   m-cycles
   t-states
   instruction-count)
  #:transparent)

(define (sm83-asm-result-bytes* v)
  (if (bytes? v) v (sm83-asm-result-bytes v)))

;; Encode $CB-prefixed register operand index:
;;   B=0, C=1, D=2, E=3, H=4, L=5, (HL)=6, A=7
(define (sm83-cb-reg-code reg)
  (match reg
    [(or 'b 'B 0) 0]
    [(or 'c 'C 1) 1]
    [(or 'd 'D 2) 2]
    [(or 'e 'E 3) 3]
    [(or 'h 'H 4) 4]
    [(or 'l 'L 5) 5]
    [(or '(hl) '(HL) 'hl-ind 'hl 'HL 6) 6]
    [(or 'a 'A 7) 7]
    [else (error 'sm83-cb-reg-code "Invalid SM83 $CB register operand: ~v" reg)]))

;; Evaluate an SM83 operand expression given label table
(define (eval-sm83-expr expr labels [allow-unresolved? #f])
  (match expr
    [(? exact-integer? n) n]
    [(? symbol? sym)
     (cond
       [(hash-has-key? labels sym) (hash-ref labels sym)]
       [allow-unresolved? #x0150]
       [else (error 'eval-sm83-expr "Undefined SM83 label: ~a" sym)])]
    [`(lo ,e)
     (bitwise-and #xFF (eval-sm83-expr e labels allow-unresolved?))]
    [`(hi ,e)
     (bitwise-and #xFF (arithmetic-shift (eval-sm83-expr e labels allow-unresolved?) -8))]
    [`(+ ,a ,b)
     (+ (eval-sm83-expr a labels allow-unresolved?)
        (eval-sm83-expr b labels allow-unresolved?))]
    [`(- ,a ,b)
     (- (eval-sm83-expr a labels allow-unresolved?)
        (eval-sm83-expr b labels allow-unresolved?))]
    [else
     (error 'eval-sm83-expr "Unsupported SM83 operand expression: ~v" expr)]))

;; SM83 Peephole Optimizer:
;;   1. `LD A, #0` -> `XOR A` (saves 1 B, 1 M-cycle)
;;   2. Redundant `LDH ($FF00+n), A; LDH A, ($FF00+n)` -> `LDH ($FF00+n), A` (saves 2 B, 3 M-cycles)
;;   3. Tail-call `CALL lbl; RET` -> `JP lbl` (saves 1 B, 6 M-cycles)
(define (optimize-sm83-peephole-internal forms)
  (define zero-loads-folded 0)
  (define redundant-ldh-eliminated 0)
  (define tail-calls-folded 0)
  (define bytes-saved 0)
  (define m-cycles-saved 0)

  (let loop ([rem forms]
             [acc '()])
    (match rem
      ['()
       (values (reverse acc)
               (hasheq 'zero-loads-folded zero-loads-folded
                       'redundant-ldh-eliminated redundant-ldh-eliminated
                       'tail-calls-folded tail-calls-folded
                       'bytes-saved bytes-saved
                       'm-cycles-saved m-cycles-saved))]
      ;; 1. Tail-call folding: (call lbl) (ret) -> (jp lbl)
      [(list* `(call ,target) `(ret) rest)
       (set! tail-calls-folded (add1 tail-calls-folded))
       (set! bytes-saved (+ bytes-saved 1))
       (set! m-cycles-saved (+ m-cycles-saved 6))
       (loop rest (cons `(jp ,target) acc))]
      ;; 2. Redundant HRAM/IO store-then-reload: (ldh-ind-a n1) (ldh-a-ind n2)
      [(list* `(ldh-ind-a ,n1) `(ldh-a-ind ,n2) rest)
       #:when (and (exact-integer? n1)
                   (exact-integer? n2)
                   (= (bitwise-and #xFF n1) (bitwise-and #xFF n2)))
       (set! redundant-ldh-eliminated (add1 redundant-ldh-eliminated))
       (set! bytes-saved (+ bytes-saved 2))
       (set! m-cycles-saved (+ m-cycles-saved 3))
       (loop rest (cons `(ldh-ind-a ,n1) acc))]
      ;; 3. Zero load folding: (ld-a-imm 0) -> (xor-a-a)
      [(list* `(ld-a-imm 0) rest)
       (set! zero-loads-folded (add1 zero-loads-folded))
       (set! bytes-saved (+ bytes-saved 1))
       (set! m-cycles-saved (+ m-cycles-saved 1))
       (loop rest (cons '(xor-a-a) acc))]
      [(cons head tail)
       (loop tail (cons head acc))])))

(define (optimize-sm83-peephole forms)
  (define-values (opt-forms _stats) (optimize-sm83-peephole-internal forms))
  opt-forms)

(define (optimize-sm83-peephole-stats forms)
  (define-values (_opt-forms stats) (optimize-sm83-peephole-internal forms))
  stats)

;; Return (values byte-length m-cycles) for an SM83 form
(define (sm83-form-metrics form)
  (match form
    [(? symbol? _) (values 0 0)]
    [`(label ,_)   (values 0 0)]
    [`(.equ ,_ ,_) (values 0 0)]
    [`(db . ,bs)   (values (length bs) 0)]
    [`(dw . ,ws)   (values (* 2 (length ws)) 0)]
    [`(nop)        (values 1 1)]
    [`(di)         (values 1 1)]
    [`(ei)         (values 1 1)]
    [`(halt)       (values 1 1)]
    [`(stop)       (values 2 1)]
    [`(ret)        (values 1 4)]
    [`(reti)       (values 1 4)]
    [`(ret-nz)     (values 1 5)]
    [`(ret-z)      (values 1 5)]
    [`(ret-nc)     (values 1 5)]
    [`(ret-c)      (values 1 5)]
    [`(ld-a-imm ,_) (values 2 2)]
    [`(ld-b-imm ,_) (values 2 2)]
    [`(ld-c-imm ,_) (values 2 2)]
    [`(ld-d-imm ,_) (values 2 2)]
    [`(ld-e-imm ,_) (values 2 2)]
    [`(ld-h-imm ,_) (values 2 2)]
    [`(ld-l-imm ,_) (values 2 2)]
    [`(ld-bc-imm ,_) (values 3 3)]
    [`(ld-de-imm ,_) (values 3 3)]
    [`(ld-hl-imm ,_) (values 3 3)]
    [`(ld-sp-imm ,_) (values 3 3)]
    [`(ld-hl-ind-a) (values 1 2)]
    [`(ld-a-hl-ind) (values 1 2)]
    [`(ldi-hl-a)    (values 1 2)]
    [`(ldd-hl-a)    (values 1 2)]
    [`(ldi-a-hl)    (values 1 2)]
    [`(ldd-a-hl)    (values 1 2)]
    [`(ld-bc-ind-a) (values 1 2)]
    [`(ld-a-bc-ind) (values 1 2)]
    [`(ld-de-ind-a) (values 1 2)]
    [`(ld-a-de-ind) (values 1 2)]
    [`(ld-a-b)      (values 1 1)]
    [`(ld-a-c)      (values 1 1)]
    [`(ld-a-d)      (values 1 1)]
    [`(ld-a-e)      (values 1 1)]
    [`(ld-a-h)      (values 1 1)]
    [`(ld-a-l)      (values 1 1)]
    [`(ld-b-a)      (values 1 1)]
    [`(ld-c-a)      (values 1 1)]
    [`(ld-d-a)      (values 1 1)]
    [`(ld-e-a)      (values 1 1)]
    [`(ld-h-a)      (values 1 1)]
    [`(ld-l-a)      (values 1 1)]
    [`(ldh-ind-a ,_) (values 2 3)]
    [`(ldh-a-ind ,_) (values 2 3)]
    [`(ldh-c-ind-a)  (values 1 2)]
    [`(ldh-a-c-ind)  (values 1 2)]
    [`(ld-abs-a ,_)  (values 3 4)]
    [`(ld-a-abs ,_)  (values 3 4)]
    [`(inc-a)  (values 1 1)]
    [`(dec-a)  (values 1 1)]
    [`(inc-b)  (values 1 1)]
    [`(dec-b)  (values 1 1)]
    [`(inc-c)  (values 1 1)]
    [`(dec-c)  (values 1 1)]
    [`(inc-d)  (values 1 1)]
    [`(dec-d)  (values 1 1)]
    [`(inc-e)  (values 1 1)]
    [`(dec-e)  (values 1 1)]
    [`(inc-h)  (values 1 1)]
    [`(dec-h)  (values 1 1)]
    [`(inc-l)  (values 1 1)]
    [`(dec-l)  (values 1 1)]
    [`(inc-hl-ind) (values 1 3)]
    [`(dec-hl-ind) (values 1 3)]
    [`(inc-bc) (values 1 2)]
    [`(dec-bc) (values 1 2)]
    [`(inc-de) (values 1 2)]
    [`(dec-de) (values 1 2)]
    [`(inc-hl) (values 1 2)]
    [`(dec-hl) (values 1 2)]
    [`(inc-sp) (values 1 2)]
    [`(dec-sp) (values 1 2)]
    [`(add-a-imm ,_) (values 2 2)]
    [`(sub-a-imm ,_) (values 2 2)]
    [`(and-a-imm ,_) (values 2 2)]
    [`(or-a-imm ,_)  (values 2 2)]
    [`(xor-a-imm ,_) (values 2 2)]
    [`(xor-a-a)      (values 1 1)]
    [`(xor-a)        (values 1 1)]
    [`(cp-a-imm ,_)  (values 2 2)]
    [`(add-a-b)      (values 1 1)]
    [`(add-a-c)      (values 1 1)]
    [`(or-a-b)       (values 1 1)]
    [`(or-a-c)       (values 1 1)]
    [`(and-a-b)      (values 1 1)]
    [`(and-a-c)      (values 1 1)]
    [`(cpl)          (values 1 1)]
    [`(scf)          (values 1 1)]
    [`(ccf)          (values 1 1)]
    [`(bit ,_ ,reg)  (values 2 (if (= (sm83-cb-reg-code reg) 6) 3 2))]
    [`(res ,_ ,reg)  (values 2 (if (= (sm83-cb-reg-code reg) 6) 4 2))]
    [`(set ,_ ,reg)  (values 2 (if (= (sm83-cb-reg-code reg) 6) 4 2))]
    [`(swap-a)       (values 2 2)]
    [`(jp ,_)        (values 3 4)]
    [`(jp-nz ,_)     (values 3 4)]
    [`(jp-z ,_)      (values 3 4)]
    [`(jp-nc ,_)     (values 3 4)]
    [`(jp-c ,_)      (values 3 4)]
    [`(jp-hl)        (values 1 1)]
    [`(jr ,_)        (values 2 3)]
    [`(jr-nz ,_)     (values 2 3)]
    [`(jr-z ,_)      (values 2 3)]
    [`(jr-nc ,_)     (values 2 3)]
    [`(jr-c ,_)      (values 2 3)]
    [`(call ,_)      (values 3 6)]
    [`(call-nz ,_)   (values 3 6)]
    [`(call-z ,_)    (values 3 6)]
    [`(push-af)      (values 1 4)]
    [`(pop-af)       (values 1 3)]
    [`(push-bc)      (values 1 4)]
    [`(pop-bc)       (values 1 3)]
    [`(push-de)      (values 1 4)]
    [`(pop-de)       (values 1 3)]
    [`(push-hl)      (values 1 4)]
    [`(pop-hl)       (values 1 3)]
    [else (error 'sm83-form-metrics "Unrecognized SM83 instruction form: ~v" form)]))

;; Two-Pass SM83 Assembler
(define (assemble-sm83-detailed forms #:origin [origin #x0150])
  (define labels (make-hash))
  (define pc origin)

  ;; Pass 1: Record label addresses
  (for ([form (in-list forms)])
    (match form
      [(? symbol? sym)
       (hash-set! labels sym pc)]
      [`(label ,sym)
       (hash-set! labels sym pc)]
      [`(.equ ,sym ,val)
       (hash-set! labels sym (eval-sm83-expr val labels #t))]
      [else
       (define-values (len _m) (sm83-form-metrics form))
       (set! pc (+ pc len))]))

  ;; Pass 2: Encode machine bytes
  (define out-bytes '())
  (define cur-pc origin)
  (define total-m-cycles 0)
  (define inst-count 0)

  (define (emit-u8! b)
    (set! out-bytes (cons (bitwise-and #xFF b) out-bytes))
    (set! cur-pc (add1 cur-pc)))

  (define (emit-u16! w)
    (define val (eval-sm83-expr w labels #f))
    (emit-u8! (bitwise-and #xFF val))
    (emit-u8! (bitwise-and #xFF (arithmetic-shift val -8))))

  (define (emit-rel8! target-or-offset mnem)
    (define next-pc (+ cur-pc 1)) ; cur-pc was already incremented once by opcode emit
    (define rel
      (cond
        [(and (exact-integer? target-or-offset)
              (>= target-or-offset -128)
              (<= target-or-offset 127))
         target-or-offset]
        [else
         (define target-addr (eval-sm83-expr target-or-offset labels #f))
         (- target-addr next-pc)]))
    (when (or (< rel -128) (> rel 127))
      (error 'assemble-sm83
             "SM83 relative jump (~a ~v) out of range [-128, 127]: offset ~a at PC $~x"
             mnem target-or-offset rel (sub1 cur-pc)))
    (emit-u8! (bitwise-and #xFF rel)))

  (for ([form (in-list forms)])
    (define-values (len m) (sm83-form-metrics form))
    (set! total-m-cycles (+ total-m-cycles m))
    (when (> m 0)
      (set! inst-count (add1 inst-count)))
    (match form
      [(? symbol? _) (void)]
      [`(label ,_)   (void)]
      [`(.equ ,_ ,_) (void)]
      [`(db . ,bs)
       (for ([b (in-list bs)])
         (emit-u8! (eval-sm83-expr b labels #f)))]
      [`(dw . ,ws)
       (for ([w (in-list ws)])
         (emit-u16! w))]
      [`(nop)    (emit-u8! #x00)]
      [`(di)     (emit-u8! #xF3)]
      [`(ei)     (emit-u8! #xFB)]
      [`(halt)   (emit-u8! #x76)]
      [`(stop)   (emit-u8! #x10) (emit-u8! #x00)]
      [`(ret)    (emit-u8! #xC9)]
      [`(reti)   (emit-u8! #xD9)]
      [`(ret-nz) (emit-u8! #xC0)]
      [`(ret-z)  (emit-u8! #xC8)]
      [`(ret-nc) (emit-u8! #xD0)]
      [`(ret-c)  (emit-u8! #xD8)]

      [`(ld-a-imm ,v) (emit-u8! #x3E) (emit-u8! (eval-sm83-expr v labels #f))]
      [`(ld-b-imm ,v) (emit-u8! #x06) (emit-u8! (eval-sm83-expr v labels #f))]
      [`(ld-c-imm ,v) (emit-u8! #x0E) (emit-u8! (eval-sm83-expr v labels #f))]
      [`(ld-d-imm ,v) (emit-u8! #x16) (emit-u8! (eval-sm83-expr v labels #f))]
      [`(ld-e-imm ,v) (emit-u8! #x1E) (emit-u8! (eval-sm83-expr v labels #f))]
      [`(ld-h-imm ,v) (emit-u8! #x26) (emit-u8! (eval-sm83-expr v labels #f))]
      [`(ld-l-imm ,v) (emit-u8! #x2E) (emit-u8! (eval-sm83-expr v labels #f))]

      [`(ld-bc-imm ,v) (emit-u8! #x01) (emit-u16! v)]
      [`(ld-de-imm ,v) (emit-u8! #x11) (emit-u16! v)]
      [`(ld-hl-imm ,v) (emit-u8! #x21) (emit-u16! v)]
      [`(ld-sp-imm ,v) (emit-u8! #x31) (emit-u16! v)]

      [`(ld-hl-ind-a) (emit-u8! #x77)]
      [`(ld-a-hl-ind) (emit-u8! #x7E)]
      [`(ldi-hl-a)    (emit-u8! #x22)]
      [`(ldd-hl-a)    (emit-u8! #x32)]
      [`(ldi-a-hl)    (emit-u8! #x2A)]
      [`(ldd-a-hl)    (emit-u8! #x3A)]
      [`(ld-bc-ind-a) (emit-u8! #x02)]
      [`(ld-a-bc-ind) (emit-u8! #x0A)]
      [`(ld-de-ind-a) (emit-u8! #x12)]
      [`(ld-a-de-ind) (emit-u8! #x1A)]

      [`(ld-a-b) (emit-u8! #x78)]
      [`(ld-a-c) (emit-u8! #x79)]
      [`(ld-a-d) (emit-u8! #x7A)]
      [`(ld-a-e) (emit-u8! #x7B)]
      [`(ld-a-h) (emit-u8! #x7C)]
      [`(ld-a-l) (emit-u8! #x7D)]
      [`(ld-b-a) (emit-u8! #x47)]
      [`(ld-c-a) (emit-u8! #x4F)]
      [`(ld-d-a) (emit-u8! #x57)]
      [`(ld-e-a) (emit-u8! #x5F)]
      [`(ld-h-a) (emit-u8! #x67)]
      [`(ld-l-a) (emit-u8! #x6F)]

      [`(ldh-ind-a ,v) (emit-u8! #xE0) (emit-u8! (eval-sm83-expr v labels #f))]
      [`(ldh-a-ind ,v) (emit-u8! #xF0) (emit-u8! (eval-sm83-expr v labels #f))]
      [`(ldh-c-ind-a)  (emit-u8! #xE2)]
      [`(ldh-a-c-ind)  (emit-u8! #xF2)]

      [`(ld-abs-a ,v)  (emit-u8! #xEA) (emit-u16! v)]
      [`(ld-a-abs ,v)  (emit-u8! #xFA) (emit-u16! v)]

      [`(inc-a)  (emit-u8! #x3C)]
      [`(dec-a)  (emit-u8! #x3D)]
      [`(inc-b)  (emit-u8! #x04)]
      [`(dec-b)  (emit-u8! #x05)]
      [`(inc-c)  (emit-u8! #x0C)]
      [`(dec-c)  (emit-u8! #x0D)]
      [`(inc-d)  (emit-u8! #x14)]
      [`(dec-d)  (emit-u8! #x15)]
      [`(inc-e)  (emit-u8! #x1C)]
      [`(dec-e)  (emit-u8! #x1D)]
      [`(inc-h)  (emit-u8! #x24)]
      [`(dec-h)  (emit-u8! #x25)]
      [`(inc-l)  (emit-u8! #x2C)]
      [`(dec-l)  (emit-u8! #x2D)]
      [`(inc-hl-ind) (emit-u8! #x34)]
      [`(dec-hl-ind) (emit-u8! #x35)]
      [`(inc-bc) (emit-u8! #x03)]
      [`(dec-bc) (emit-u8! #x0B)]
      [`(inc-de) (emit-u8! #x13)]
      [`(dec-de) (emit-u8! #x1B)]
      [`(inc-hl) (emit-u8! #x23)]
      [`(dec-hl) (emit-u8! #x2B)]
      [`(inc-sp) (emit-u8! #x33)]
      [`(dec-sp) (emit-u8! #x3B)]

      [`(add-a-imm ,v) (emit-u8! #xC6) (emit-u8! (eval-sm83-expr v labels #f))]
      [`(sub-a-imm ,v) (emit-u8! #xD6) (emit-u8! (eval-sm83-expr v labels #f))]
      [`(and-a-imm ,v) (emit-u8! #xE6) (emit-u8! (eval-sm83-expr v labels #f))]
      [`(or-a-imm ,v)  (emit-u8! #xF6) (emit-u8! (eval-sm83-expr v labels #f))]
      [`(xor-a-imm ,v) (emit-u8! #xEE) (emit-u8! (eval-sm83-expr v labels #f))]
      [(or `(xor-a-a) `(xor-a)) (emit-u8! #xAF)]
      [`(cp-a-imm ,v)  (emit-u8! #xFE) (emit-u8! (eval-sm83-expr v labels #f))]
      [`(add-a-b)      (emit-u8! #x80)]
      [`(add-a-c)      (emit-u8! #x81)]
      [`(or-a-b)       (emit-u8! #xB0)]
      [`(or-a-c)       (emit-u8! #xB1)]
      [`(and-a-b)      (emit-u8! #xA0)]
      [`(and-a-c)      (emit-u8! #xA1)]
      [`(cpl)          (emit-u8! #x2F)]
      [`(scf)          (emit-u8! #x37)]
      [`(ccf)          (emit-u8! #x3F)]

      [`(bit ,u3 ,reg)
       (emit-u8! #xCB)
       (emit-u8! (+ #x40
                    (arithmetic-shift (bitwise-and u3 7) 3)
                    (sm83-cb-reg-code reg)))]
      [`(res ,u3 ,reg)
       (emit-u8! #xCB)
       (emit-u8! (+ #x80
                    (arithmetic-shift (bitwise-and u3 7) 3)
                    (sm83-cb-reg-code reg)))]
      [`(set ,u3 ,reg)
       (emit-u8! #xCB)
       (emit-u8! (+ #xC0
                    (arithmetic-shift (bitwise-and u3 7) 3)
                    (sm83-cb-reg-code reg)))]
      [`(swap-a)
       (emit-u8! #xCB)
       (emit-u8! #x37)]

      [`(jp ,target)    (emit-u8! #xC3) (emit-u16! target)]
      [`(jp-nz ,target) (emit-u8! #xC2) (emit-u16! target)]
      [`(jp-z ,target)  (emit-u8! #xCA) (emit-u16! target)]
      [`(jp-nc ,target) (emit-u8! #xD2) (emit-u16! target)]
      [`(jp-c ,target)  (emit-u8! #xDA) (emit-u16! target)]
      [`(jp-hl)         (emit-u8! #xE9)]

      [`(jr ,target)    (emit-u8! #x18) (emit-rel8! target 'jr)]
      [`(jr-nz ,target) (emit-u8! #x20) (emit-rel8! target 'jr-nz)]
      [`(jr-z ,target)  (emit-u8! #x28) (emit-rel8! target 'jr-z)]
      [`(jr-nc ,target) (emit-u8! #x30) (emit-rel8! target 'jr-nc)]
      [`(jr-c ,target)  (emit-u8! #x38) (emit-rel8! target 'jr-c)]

      [`(call ,target)    (emit-u8! #xCD) (emit-u16! target)]
      [`(call-nz ,target) (emit-u8! #xC4) (emit-u16! target)]
      [`(call-z ,target)  (emit-u8! #xCC) (emit-u16! target)]

      [`(push-af) (emit-u8! #xF5)]
      [`(pop-af)  (emit-u8! #xF1)]
      [`(push-bc) (emit-u8! #xC5)]
      [`(pop-bc)  (emit-u8! #xC1)]
      [`(push-de) (emit-u8! #xD5)]
      [`(pop-de)  (emit-u8! #xD1)]
      [`(push-hl) (emit-u8! #xE5)]
      [`(pop-hl)  (emit-u8! #xE1)]))

  (sm83-asm-result
   (list->bytes (reverse out-bytes))
   origin
   labels
   total-m-cycles
   (* 4 total-m-cycles)
   inst-count))

(define (assemble-sm83 forms #:origin [origin #x0150] #:detailed? [detailed? #f])
  (define res (assemble-sm83-detailed forms #:origin origin))
  (if detailed? res (sm83-asm-result-bytes res)))

;; ============================================================================
;; 3. HRAM OAM DMA Trampoline, Checksums, 2bpp Tiles & GBC BGR555 Palettes
;; ============================================================================

;; 10-byte HRAM OAM DMA routine installed at $FF80-$FF89:
;;   LD A, #$C0       ; #x3E #xC0 (2B) - Shadow OAM page $C000
;;   LDH ($46), A     ; #xE0 #x46 (2B) - Trigger 160 M-cycle OAM DMA
;;   LD A, #40        ; #x3E #x28 (2B) - 40 * 4 M-cycles = 160 M-cycles
;; .loop:
;;   DEC A            ; #x3D      (1B)
;;   JR NZ, .loop     ; #x20 #xFD (2B)
;;   RET              ; #xC9      (1B)
(define (emit-hram-oam-dma-trampoline #:source-page [source-page #xC0]
                                      #:bytes? [as-bytes? #f])
  (define forms
    `((ld-a-imm ,source-page)
      (ldh-ind-a #x46)
      (ld-a-imm 40)
      (label hram_dma_wait_loop)
      (dec-a)
      (jr-nz hram_dma_wait_loop)
      (ret)))
  (if as-bytes?
      (assemble-sm83 forms #:origin #xFF80)
      forms))

(define HRAM-OAM-DMA-TRAMPOLINE-BYTES
  (emit-hram-oam-dma-trampoline #:bytes? #t))

;; Header checksum over $0134..$014C (25 bytes):
;;   x = 0; for b in $0134..$014C: x = (x - b - 1) & #xFF
(define (compute-gb-header-checksum rom-or-slice)
  (define slice
    (cond
      [(= (bytes-length rom-or-slice) 25) rom-or-slice]
      [(>= (bytes-length rom-or-slice) #x014D)
       (subbytes rom-or-slice #x0134 #x014D)]
      [else
       (error 'compute-gb-header-checksum
              "Expected full ROM (>= 333 B) or 25-byte $0134..$014C slice, got ~a B"
              (bytes-length rom-or-slice))]))
  (for/fold ([x 0])
            ([b (in-bytes slice)])
    (bitwise-and #xFF (- x b 1))))

;; Global 16-bit checksum: sum of all ROM bytes except $014E and $014F
(define (compute-gb-global-checksum rom)
  (for/fold ([sum 0])
            ([b (in-bytes rom)]
             [idx (in-naturals)])
    (if (or (= idx #x014E) (= idx #x014F))
        sum
        (bitwise-and #xFFFF (+ sum b)))))

;; Compile an 8x8 2bpp Game Boy tile (16 bytes, row-interleaved lo/hi planes)
(define (compile-gb-2bpp-tile rows)
  (unless (= (length rows) 8)
    (error 'compile-gb-2bpp-tile "Expected 8 rows for 8x8 2bpp tile, got ~a" (length rows)))
  (define out (make-bytes 16 0))
  (for ([row-str (in-list rows)]
        [r (in-range 8)])
    (unless (= (string-length row-str) 8)
      (error 'compile-gb-2bpp-tile "Row ~a must have 8 pixels, got ~v" r row-str))
    (define lo 0)
    (define hi 0)
    (for ([ch (in-string row-str)]
          [c (in-range 8)])
      (define pix
        (case ch
          [(#\. #\0 #\space) 0]
          [(#\1) 1]
          [(#\2) 2]
          [(#\3) 3]
          [else (error 'compile-gb-2bpp-tile "Invalid pixel char ~v" ch)]))
      (define bit-pos (- 7 c))
      (when (bitwise-bit-set? pix 0)
        (set! lo (bitwise-ior lo (arithmetic-shift 1 bit-pos))))
      (when (bitwise-bit-set? pix 1)
        (set! hi (bitwise-ior hi (arithmetic-shift 1 bit-pos)))))
    (bytes-set! out (* 2 r) lo)
    (bytes-set! out (add1 (* 2 r)) hi))
  out)

;; Encode a 15-bit GBC BGR555 color word (bit 15 = 0, B[14:10] G[9:5] R[4:0])
(define (encode-gbc-bgr555 r5 g5 b5)
  (when (or (< r5 0) (> r5 31) (< g5 0) (> g5 31) (< b5 0) (> b5 31))
    (error 'encode-gbc-bgr555 "BGR555 channel out of [0..31] range: (~a, ~a, ~a)" r5 g5 b5))
  (bitwise-ior (bitwise-and r5 #x1F)
               (arithmetic-shift (bitwise-and g5 #x1F) 5)
               (arithmetic-shift (bitwise-and b5 #x1F) 10)))

;; Default 8x8 2bpp tiles for Boba DMG / GBC
(define DEFAULT-GB-TILES
  (list
   ;; Tile 0: Blank background
   (compile-gb-2bpp-tile
    '("........" "........" "........" "........"
      "........" "........" "........" "........"))
   ;; Tile 1: Boba Hero Cup (Stage 0)
   (compile-gb-2bpp-tile
    '("...33..." "..3223.." ".333333." ".312213."
      ".322223." ".323323." "..3333.." "...22..."))
   ;; Tile 2: Boba Hero Cup (Stage 1)
   (compile-gb-2bpp-tile
    '("...33..." "..3223.." ".333333." ".313313."
      ".322223." ".332233." "..3333.." "...22..."))
   ;; Tile 3: Boba Hero Cup (Stage 2)
   (compile-gb-2bpp-tile
    '("..3..3.." "..3223.." ".333333." ".312213."
      ".323323." ".322223." "..3333.." "...33..."))
   ;; Tile 4: Boba Crown Cup (Stage 3 Victory)
   (compile-gb-2bpp-tile
    '(".3.33.3." ".332233." ".333333." ".312213."
      ".323323." ".323323." "..3333.." "..3333.."))
   ;; Tile 5: Tapioca Pearl Goal
   (compile-gb-2bpp-tile
    '("..3333.." ".322223." "32112223" "32122223"
      "32222323" "32223323" ".322223." "..3333.."))
   ;; Tile 6: Hazard Spike Block
   (compile-gb-2bpp-tile
    '("...33..." "..3113.." "..3113.." ".313313."
      ".313313." "31133113" "31111113" "33333333"))
   ;; Tile 7: IS / YOU Rule Block
   (compile-gb-2bpp-tile
    '("33333333" "31111113" "31333313" "31322313"
      "31322313" "31333313" "31111113" "33333333"))))

;; Default GBC 15-bit BGR555 Palettes (4 colors each)
(define DEFAULT-GBC-BG-PALETTE
  (list (encode-gbc-bgr555 31 30 27) ; Warm Milk Tea Cream
        (encode-gbc-bgr555 26 18 11) ; Caramel Brown
        (encode-gbc-bgr555 15  8  5) ; Roasted Oolong
        (encode-gbc-bgr555  4  2  3))) ; Deep Tapioca Ink

(define DEFAULT-GBC-OBJ-PALETTE
  (list (encode-gbc-bgr555 31 31 31) ; Transparent / Highlight
        (encode-gbc-bgr555 31 23  8) ; Golden Honey
        (encode-gbc-bgr555 29  9 14) ; Berry Hibiscus
        (encode-gbc-bgr555  5  2  6))) ; Dark Pearl Outline

;; ============================================================================
;; 4. Complete SM83 Program Generator & 32 KB (.gb / .gbc) Cartridge Linker
;; ============================================================================

(define (make-boba-sm83-program #:gbc? [gbc? #f]
                                #:tile-count [tile-count 8]
                                #:bg-palette [bg-pal DEFAULT-GBC-BG-PALETTE]
                                #:obj-palette [obj-pal DEFAULT-GBC-OBJ-PALETTE]
                                #:optimize? [optimize? #t])
  (define tile-bytes-len (* 16 tile-count))
  (define raw-forms
    (append
     `(;; ====================================================================
       ;; Boot Entry at $0150
       ;; ====================================================================
       (label boot_start)
       (di)
       (ld-sp-imm #xFFFE)

       ;; Wait for VBlank (LY >= 144) before disabling LCDC ($FF40)
       (label wait_vblank_boot)
       (ldh-a-ind #x44)
       (cp-a-imm 144)
       (jr-c wait_vblank_boot)

       ;; Disable LCD (LCDC = 0) so VRAM ($8000-$9FFF) and OAM are unlocked
       (ld-a-imm 0)
       (ldh-ind-a #x40))

     ;; Optional GBC Double-Speed Mode switch ($FF4D KEY1 + STOP)
     (if gbc?
         `((ldh-a-ind #x4D)
           (bit 7 a)
           (jr-nz gbc_speed_ready)
           (ld-a-imm #x01)
           (ldh-ind-a #x4D)
           (ld-a-imm 0)
           (ldh-ind-a #xFF)
           (ld-a-imm #x30)
           (ldh-ind-a #x00)
           (stop)
           (label gbc_speed_ready))
         '())

     `(;; ====================================================================
       ;; Install 10-byte HRAM OAM DMA Trampoline at $FF80-$FF89
       ;; ====================================================================
       (ld-hl-imm hram_dma_template)
       (ld-c-imm #x80)
       (ld-b-imm 10)
       (label install_hram_loop)
       (ldi-a-hl)
       (ldh-c-ind-a)
       (inc-c)
       (dec-b)
       (jr-nz install_hram_loop)

       ;; ====================================================================
       ;; Bulk 2bpp Tile Upload to VRAM $8000 (while LCDC bit 7 == 0)
       ;; ====================================================================
       (ld-de-imm rom_tile_bank)
       (ld-hl-imm #x8000)
       (ld-b-imm ,tile-bytes-len)
       (label upload_tiles_loop)
       (ld-a-de-ind)
       (ldi-hl-a)
       (inc-de)
       (dec-b)
       (jr-nz upload_tiles_loop)

       ;; ====================================================================
       ;; Initialize 32-byte Top Row of $9800 BG Tilemap
       ;; ====================================================================
       (ld-hl-imm #x9800)
       (ld-b-imm 32)
       (ld-a-imm 7)
       (label init_bg_map_loop)
       (ldi-hl-a)
       (dec-b)
       (jr-nz init_bg_map_loop)

       ;; Configure DMG Monochrome Palettes (BGP=$FF47, OBP0=$FF48, OBP1=$FF49)
       (ld-a-imm #xE4)
       (ldh-ind-a #x47)
       (ldh-ind-a #x48)
       (ld-a-imm #xD2)
       (ldh-ind-a #x49))

     ;; GBC 15-bit BGR555 Palette Upload ($FF68/$FF69 BCPS/BCPD, $FF6A/$FF6B OCPS/OCPD)
     ;; and HBlank HDMA Setup ($FF51-$FF55)
     (if gbc?
         (append
          `((ld-a-imm #x80)
            (ldh-ind-a #x68))
          (apply append
                 (for/list ([col (in-list bg-pal)])
                   `((ld-a-imm ,(bitwise-and col #xFF))
                     (ldh-ind-a #x69)
                     (ld-a-imm ,(bitwise-and (arithmetic-shift col -8) #x7F))
                     (ldh-ind-a #x69))))
          `((ld-a-imm #x80)
            (ldh-ind-a #x6A))
          (apply append
                 (for/list ([col (in-list obj-pal)])
                   `((ld-a-imm ,(bitwise-and col #xFF))
                     (ldh-ind-a #x6B)
                     (ld-a-imm ,(bitwise-and (arithmetic-shift col -8) #x7F))
                     (ldh-ind-a #x6B))))
          ;; Configure HDMA registers ($FF51-$FF55): copy 16 bytes (1 block) from rom_tile_bank to $8100
          `((ld-a-imm (hi rom_tile_bank))
            (ldh-ind-a #x51)
            (ld-a-imm (lo rom_tile_bank))
            (ldh-ind-a #x52)
            (ld-a-imm #x01)
            (ldh-ind-a #x53)
            (ld-a-imm #x00)
            (ldh-ind-a #x54)
            (ld-a-imm #x00)
            (ldh-ind-a #x55)))
         '())

     `(;; ====================================================================
       ;; Initialize Shadow OAM ($C000-$C09F) & HRAM Campaign State ($FF90-$FF99)
       ;; ====================================================================
       (ld-a-imm 0)
       (ldh-ind-a ,GB-HRAM-JOYPAD)
       (ldh-a-ind ,GB-HRAM-JOYPAD)
       (ldh-ind-a ,GB-HRAM-STAGE-ID)
       (ldh-ind-a ,GB-HRAM-FAILED)
       (ldh-ind-a ,GB-HRAM-RECOVERED)
       (ldh-ind-a ,GB-HRAM-WON)
       (ldh-ind-a ,GB-HRAM-SCORE)
       (ldh-ind-a ,GB-HRAM-FRAME-CNT)
       (ldh-ind-a ,GB-HRAM-DMA-COUNT)

       (ld-a-imm #x20)
       (ldh-ind-a ,GB-HRAM-PLAYER-X)
       (ld-a-imm #x40)
       (ldh-ind-a ,GB-HRAM-PLAYER-Y)

       ;; Populate Hero, Goal Pearl, and Hazard Spike sprites in Shadow OAM ($C000-$C00B)
       (ld-hl-imm #xC000)
       (ld-a-imm #x40)
       (ldi-hl-a) ; Hero Y
       (ld-a-imm #x20)
       (ldi-hl-a) ; Hero X
       (ld-a-imm 1)
       (ldi-hl-a) ; Hero Tile
       (ld-a-imm 0)
       (ldi-hl-a) ; Hero Attr

       (ld-a-imm #x40)
       (ldi-hl-a) ; Goal Y
       (ld-a-imm #x68)
       (ldi-hl-a) ; Goal X
       (ld-a-imm 5)
       (ldi-hl-a) ; Goal Tile
       (ld-a-imm 0)
       (ldi-hl-a) ; Goal Attr

       (ld-a-imm #x40)
       (ldi-hl-a) ; Hazard Y
       (ld-a-imm #x48)
       (ldi-hl-a) ; Hazard X
       (ld-a-imm 6)
       (ldi-hl-a) ; Hazard Tile
       (ld-a-imm 0)
       (ldi-hl-a) ; Hazard Attr

       ;; Turn LCD ON (LCDC = #x91: LCD on, $8000 tile data, $9800 map, OBJ on, BG on)
       (ld-a-imm #x91)
       (ldh-ind-a #x40)

       ;; Initial OAM DMA via HRAM Trampoline at $FF80
       (call #xFF80)
       (ld-a-imm 1)
       (ldh-ind-a ,GB-HRAM-DMA-COUNT)

       ;; ====================================================================
       ;; Main Campaign Loop
       ;; ====================================================================
       (label main_loop)
       (call frame_step)
       (jr main_loop)

       ;; ====================================================================
       ;; Per-Frame Campaign State Machine Step Subroutine (`frame_step`)
       ;; ====================================================================
       (label frame_step)
       (ldh-a-ind ,GB-HRAM-FRAME-CNT)
       (inc-a)
       (ldh-ind-a ,GB-HRAM-FRAME-CNT)

       ;; Check if currently in Hazard/Failure state
       (ldh-a-ind ,GB-HRAM-FAILED)
       (cp-a-imm 0)
       (jr-z state_alive)

       ;; In Failure State: check START button (bit 7 of HRAM_JOYPAD) for Recovery
       (ldh-a-ind ,GB-HRAM-JOYPAD)
       (bit 7 a)
       (jr-z sync_oam_and_dma)

       ;; START pressed -> Recover!
       (ld-a-imm 0)
       (ldh-ind-a ,GB-HRAM-FAILED)
       (ld-a-imm 1)
       (ldh-ind-a ,GB-HRAM-RECOVERED)
       (ld-a-imm #x20)
       (ldh-ind-a ,GB-HRAM-PLAYER-X)
       (jr sync_oam_and_dma)

       (label state_alive)
       ;; Check if already won
       (ldh-a-ind ,GB-HRAM-WON)
       (cp-a-imm 0)
       (jr-nz sync_oam_and_dma)

       ;; Check Hazard trigger (B button = bit 5)
       (ldh-a-ind ,GB-HRAM-JOYPAD)
       (bit 5 a)
       (jr-z check_move_right)
       (ld-a-imm 1)
       (ldh-ind-a ,GB-HRAM-FAILED)
       (jr sync_oam_and_dma)

       (label check_move_right)
       (ldh-a-ind ,GB-HRAM-JOYPAD)
       (bit 0 a)
       (jr-z check_stage_advance)
       (ldh-a-ind ,GB-HRAM-PLAYER-X)
       (add-a-imm 8)
       (ldh-ind-a ,GB-HRAM-PLAYER-X)

       (label check_stage_advance)
       ;; A button (bit 4) clears current stage rule objective
       (ldh-a-ind ,GB-HRAM-JOYPAD)
       (bit 4 a)
       (jr-z sync_oam_and_dma)

       ;; Increment score
       (ldh-a-ind ,GB-HRAM-SCORE)
       (inc-a)
       (ldh-ind-a ,GB-HRAM-SCORE)

       ;; Reset player X to $20 for next stage
       (ld-a-imm #x20)
       (ldh-ind-a ,GB-HRAM-PLAYER-X)

       ;; Advance stage: 0 -> 1 -> 2 -> 3 (and if already at Stage 3, mark Victory!)
       (ldh-a-ind ,GB-HRAM-STAGE-ID)
       (cp-a-imm 3)
       (jr-z mark_campaign_victory)
       (inc-a)
       (ldh-ind-a ,GB-HRAM-STAGE-ID)
       (cp-a-imm 3)
       (jr-nz sync_oam_and_dma)

       (label mark_campaign_victory)
       (ld-a-imm 1)
       (ldh-ind-a ,GB-HRAM-WON)

       (label sync_oam_and_dma)
       ;; Update Shadow OAM Hero Sprite ($C000-$C003)
       (ldh-a-ind ,GB-HRAM-PLAYER-Y)
       (ld-abs-a #xC000)
       (ldh-a-ind ,GB-HRAM-PLAYER-X)
       (ld-abs-a #xC001)
       (ldh-a-ind ,GB-HRAM-STAGE-ID)
       (inc-a)
       (ld-abs-a #xC002)
       (ldh-a-ind ,GB-HRAM-FAILED)
       (ld-abs-a #xC003)

       ;; Increment DMA count and tail-call HRAM OAM DMA routine ($FF80)
       (ldh-a-ind ,GB-HRAM-DMA-COUNT)
       (inc-a)
       (ldh-ind-a ,GB-HRAM-DMA-COUNT)
       (call #xFF80)
       (ret)

       ;; ====================================================================
       ;; Embedded 10-byte HRAM OAM DMA Trampoline Template
       ;; ====================================================================
       (label hram_dma_template))
     (emit-hram-oam-dma-trampoline)
     `((label rom_tile_bank))))

  (if optimize?
      (optimize-sm83-peephole raw-forms)
      raw-forms))

;; Build a complete 32,768-byte .gb (DMG) or .gbc (CGB) ROM image
(define (build-gb-rom-image #:title [title "BOBA DMG"]
                            #:gbc? [gbc? #f]
                            #:tiles [tiles DEFAULT-GB-TILES]
                            #:bg-palette [bg-palette DEFAULT-GBC-BG-PALETTE]
                            #:obj-palette [obj-palette DEFAULT-GBC-OBJ-PALETTE]
                            #:custom-forms [custom-forms #f])
  (define rom (make-bytes 32768 #x00))

  ;; 1. Hardware Interrupt Vectors ($0040 VBlank, $0048 STAT, $0050 Timer, $0058 Serial, $0060 Joypad)
  (for ([vec (in-list '(#x0040 #x0048 #x0050 #x0058 #x0060))])
    (bytes-set! rom vec #xD9)) ; RETI

  ;; 2. Cartridge Entry Point at $0100-$0103: NOP; JP $0150
  (bytes-set! rom #x0100 #x00)
  (bytes-set! rom #x0101 #xC3)
  (bytes-set! rom #x0102 #x50)
  (bytes-set! rom #x0103 #x01)

  ;; 3. Official 48-byte Nintendo Boot Logo at $0104-$0133
  (bytes-copy! rom #x0104 NINTENDO-GB-LOGO-BYTES)

  ;; 4. Cartridge Title at $0134-$0142 (up to 15 ASCII bytes)
  (define title-bytes (string->bytes/utf-8 (string-upcase title)))
  (define copy-len (min 15 (bytes-length title-bytes)))
  (bytes-copy! rom #x0134 title-bytes 0 copy-len)

  ;; 5. CGB Flag at $0143 (#x80 for GBC dual-mode/CGB, #x00 for DMG)
  (bytes-set! rom #x0143 (if gbc? #x80 #x00))

  ;; 6. SGB Flag ($0146 = 0), Cartridge Type ($0147 = 0 ROM ONLY), ROM Size ($0148 = 0 32KB), RAM ($0149 = 0)
  (bytes-set! rom #x0146 #x00)
  (bytes-set! rom #x0147 #x00)
  (bytes-set! rom #x0148 #x00)
  (bytes-set! rom #x0149 #x00)
  (bytes-set! rom #x014A #x01) ; Non-Japanese destination code
  (bytes-set! rom #x014B #x33) ; New licensee code indicator
  (bytes-set! rom #x014C #x00) ; Mask ROM version 0

  ;; 7. Assemble SM83 Program at $0150 and append 2bpp Tile Bank
  (define forms
    (or custom-forms
        (make-boba-sm83-program #:gbc? gbc?
                                #:tile-count (length tiles)
                                #:bg-palette bg-palette
                                #:obj-palette obj-palette)))
  (define asm-res (assemble-sm83-detailed forms #:origin #x0150))
  (define code-bytes (sm83-asm-result-bytes asm-res))
  (bytes-copy! rom #x0150 code-bytes)

  (define tile-offset (+ #x0150 (bytes-length code-bytes)))
  (define tile-blob (apply bytes-append tiles))
  (bytes-copy! rom tile-offset tile-blob)

  ;; 8. Compute and write Header Checksum ($014D) and Global Checksum ($014E-$014F big-endian)
  (define hdr-chk (compute-gb-header-checksum rom))
  (bytes-set! rom #x014D hdr-chk)

  (define glob-chk (compute-gb-global-checksum rom))
  (bytes-set! rom #x014E (bitwise-and #xFF (arithmetic-shift glob-chk -8)))
  (bytes-set! rom #x014F (bitwise-and #xFF glob-chk))

  rom)

(define (compile-boba-gb-rom! #:out-path [out-path #f]
                              #:title [title "BOBA DMG"]
                              #:gbc? [gbc? #f]
                              #:tiles [tiles DEFAULT-GB-TILES]
                              #:bg-palette [bg-palette DEFAULT-GBC-BG-PALETTE]
                              #:obj-palette [obj-palette DEFAULT-GBC-OBJ-PALETTE])
  (define unopt-forms
    (make-boba-sm83-program #:gbc? gbc?
                            #:tile-count (length tiles)
                            #:bg-palette bg-palette
                            #:obj-palette obj-palette
                            #:optimize? #f))
  (define peephole-stats (optimize-sm83-peephole-stats unopt-forms))
  (define opt-forms (optimize-sm83-peephole unopt-forms))
  (define asm-res (assemble-sm83-detailed opt-forms #:origin #x0150))
  (define rom-bytes
    (build-gb-rom-image #:title title
                        #:gbc? gbc?
                        #:tiles tiles
                        #:bg-palette bg-palette
                        #:obj-palette obj-palette
                        #:custom-forms opt-forms))
  (when out-path
    (make-directory* (or (path-only out-path) (current-directory)))
    (display-to-file rom-bytes out-path #:exists 'replace #:mode 'binary))
  (define verification (verify-gb-rom-execution rom-bytes))
  (values rom-bytes asm-res peephole-stats verification))

;; ============================================================================
;; 5. Headless SM83 CPU + DMG/CGB PPU Step Simulator & Campaign Verifier
;; ============================================================================

(struct gb-emulator
  (rom
   vram                 ; 8 KB ($8000-$9FFF)
   wram                 ; 8 KB ($C000-$DFFF)
   oam                  ; 160 B ($FE00-$FE9F)
   io                   ; 128 B ($FF00-$FF7F)
   hram                 ; 127 B ($FF80-$FFFE)
   [ie #:mutable]       ; $FFFF
   ;; CPU Registers
   [a #:mutable]
   [f #:mutable]        ; Z=#x80 N=#x40 H=#x20 C=#x10
   [b #:mutable]
   [c #:mutable]
   [d #:mutable]
   [e #:mutable]
   [h #:mutable]
   [l #:mutable]
   [sp #:mutable]
   [pc #:mutable]
   [ime #:mutable]
   [halted? #:mutable]
   ;; Timing & Hardware Audit Counters
   [m-cycles #:mutable]
   [double-speed? #:mutable]
   [stat-mode-safe? #:mutable]
   [hram-dma-ok? #:mutable]
   [oam-dma-count #:mutable]
   [vram-writes #:mutable]
   [bg-map-writes #:mutable]
   [gbc-bg-pal-writes #:mutable]
   [gbc-obj-pal-writes #:mutable]
   [hdma-transfers #:mutable]
   gbc-bg-cram          ; 64 B CGB BG Palette RAM
   gbc-obj-cram)        ; 64 B CGB OBJ Palette RAM
  #:transparent)

(define (make-gb-emulator-from-rom rom-bytes)
  (define io (make-bytes #x80 0))
  ;; Start LY ($FF44) at 144 (VBlank, STAT mode 1) for deterministic boot
  (bytes-set! io #x40 #x91) ; LCDC
  (bytes-set! io #x41 #x01) ; STAT Mode 1 (VBlank)
  (bytes-set! io #x44 144)  ; LY = 144
  (gb-emulator
   rom-bytes
   (make-bytes #x2000 0)
   (make-bytes #x2000 0)
   (make-bytes #xA0 0)
   io
   (make-bytes #x7F 0)
   0
   ;; Post-boot DMG/CGB register state
   #x01 #xB0 #x00 #x13 #x00 #xD8 #x01 #x4D
   #xFFFE #x0100 #f #f
   0 #f #t #f 0 0 0 0 0 0
   (make-bytes 64 0)
   (make-bytes 64 0)))

(define (gb-flag-z? emu) (bitwise-bit-set? (gb-emulator-f emu) 7))
(define (gb-flag-c? emu) (bitwise-bit-set? (gb-emulator-f emu) 4))

(define (gb-set-flags! emu z? n? h? c?)
  (set-gb-emulator-f!
   emu
   (bitwise-ior (if z? #x80 0)
                (if n? #x40 0)
                (if h? #x20 0)
                (if c? #x10 0))))

(define (gb-bc emu) (bitwise-ior (arithmetic-shift (gb-emulator-b emu) 8) (gb-emulator-c emu)))
(define (gb-de emu) (bitwise-ior (arithmetic-shift (gb-emulator-d emu) 8) (gb-emulator-e emu)))
(define (gb-hl emu) (bitwise-ior (arithmetic-shift (gb-emulator-h emu) 8) (gb-emulator-l emu)))

(define (gb-set-bc! emu v)
  (set-gb-emulator-b! emu (bitwise-and #xFF (arithmetic-shift v -8)))
  (set-gb-emulator-c! emu (bitwise-and #xFF v)))

(define (gb-set-de! emu v)
  (set-gb-emulator-d! emu (bitwise-and #xFF (arithmetic-shift v -8)))
  (set-gb-emulator-e! emu (bitwise-and #xFF v)))

(define (gb-set-hl! emu v)
  (set-gb-emulator-h! emu (bitwise-and #xFF (arithmetic-shift v -8)))
  (set-gb-emulator-l! emu (bitwise-and #xFF v)))

(define (gb-read8 emu addr)
  (define a (bitwise-and #xFFFF addr))
  (cond
    [(< a #x8000)
     (bytes-ref (gb-emulator-rom emu) a)]
    [(< a #xA000)
     (bytes-ref (gb-emulator-vram emu) (- a #x8000))]
    [(and (>= a #xC000) (< a #xE000))
     (bytes-ref (gb-emulator-wram emu) (- a #xC000))]
    [(and (>= a #xFE00) (< a #xFEA0))
     (bytes-ref (gb-emulator-oam emu) (- a #xFE00))]
    [(and (>= a #xFF00) (< a #xFF80))
     (bytes-ref (gb-emulator-io emu) (- a #xFF00))]
    [(and (>= a #xFF80) (< a #xFFFF))
     (bytes-ref (gb-emulator-hram emu) (- a #xFF80))]
    [(= a #xFFFF)
     (gb-emulator-ie emu)]
    [else #xFF]))

(define (gb-write8! emu addr val)
  (define a (bitwise-and #xFFFF addr))
  (define b (bitwise-and #xFF val))
  (cond
    [(< a #x8000) (void)]
    [(< a #xA000)
     ;; Verify STAT mode safety: VRAM writes allowed when LCDC bit 7 == 0 or STAT mode != 3
     (define lcdc (bytes-ref (gb-emulator-io emu) #x40))
     (define stat-mode (bitwise-and #x03 (bytes-ref (gb-emulator-io emu) #x41)))
     (when (and (bitwise-bit-set? lcdc 7) (= stat-mode 3))
       (set-gb-emulator-stat-mode-safe?! emu #f))
     (bytes-set! (gb-emulator-vram emu) (- a #x8000) b)
     (if (< a #x9800)
         (set-gb-emulator-vram-writes! emu (add1 (gb-emulator-vram-writes emu)))
         (set-gb-emulator-bg-map-writes! emu (add1 (gb-emulator-bg-map-writes emu))))]
    [(and (>= a #xC000) (< a #xE000))
     (bytes-set! (gb-emulator-wram emu) (- a #xC000) b)]
    [(and (>= a #xFE00) (< a #xFEA0))
     (bytes-set! (gb-emulator-oam emu) (- a #xFE00) b)]
    [(and (>= a #xFF00) (< a #xFF80))
     (define reg (- a #xFF00))
     (bytes-set! (gb-emulator-io emu) reg b)
     (case reg
       ;; $FF46: OAM DMA Transfer
       [(#x46)
        (define src-base (arithmetic-shift b 8))
        (for ([i (in-range 160)])
          (bytes-set! (gb-emulator-oam emu) i (gb-read8 emu (+ src-base i))))
        (set-gb-emulator-oam-dma-count! emu (add1 (gb-emulator-oam-dma-count emu)))
        ;; Verify CPU PC is currently inside HRAM ($FF80-$FFFE) when OAM DMA triggers!
        (when (and (>= (gb-emulator-pc emu) #xFF80)
                   (< (gb-emulator-pc emu) #xFFFF))
          (set-gb-emulator-hram-dma-ok?! emu #t))]
       ;; $FF69: GBC BCPD (BG Palette Data)
       [(#x69)
        (define bcps (bytes-ref (gb-emulator-io emu) #x68))
        (define idx (bitwise-and bcps #x3F))
        (bytes-set! (gb-emulator-gbc-bg-cram emu) idx b)
        (set-gb-emulator-gbc-bg-pal-writes! emu (add1 (gb-emulator-gbc-bg-pal-writes emu)))
        (when (bitwise-bit-set? bcps 7)
          (bytes-set! (gb-emulator-io emu) #x68 (bitwise-ior #x80 (bitwise-and (add1 idx) #x3F))))]
       ;; $FF6B: GBC OCPD (OBJ Palette Data)
       [(#x6B)
        (define ocps (bytes-ref (gb-emulator-io emu) #x6A))
        (define idx (bitwise-and ocps #x3F))
        (bytes-set! (gb-emulator-gbc-obj-cram emu) idx b)
        (set-gb-emulator-gbc-obj-pal-writes! emu (add1 (gb-emulator-gbc-obj-pal-writes emu)))
        (when (bitwise-bit-set? ocps 7)
          (bytes-set! (gb-emulator-io emu) #x6A (bitwise-ior #x80 (bitwise-and (add1 idx) #x3F))))]
       ;; $FF55: GBC HDMA5 Transfer
       [(#x55)
        (define src
          (bitwise-ior (arithmetic-shift (bytes-ref (gb-emulator-io emu) #x51) 8)
                       (bitwise-and #xF0 (bytes-ref (gb-emulator-io emu) #x52))))
        (define dst
          (+ #x8000
             (bitwise-ior (arithmetic-shift (bitwise-and #x1F (bytes-ref (gb-emulator-io emu) #x53)) 8)
                          (bitwise-and #xF0 (bytes-ref (gb-emulator-io emu) #x54)))))
        (define blocks (add1 (bitwise-and #x7F b)))
        (for ([i (in-range (* 16 blocks))])
          (gb-write8! emu (+ dst i) (gb-read8 emu (+ src i))))
        (set-gb-emulator-hdma-transfers! emu (add1 (gb-emulator-hdma-transfers emu)))
        (bytes-set! (gb-emulator-io emu) #x55 #xFF)])]
    [(and (>= a #xFF80) (< a #xFFFF))
     (bytes-set! (gb-emulator-hram emu) (- a #xFF80) b)]
    [(= a #xFFFF)
     (set-gb-emulator-ie! emu b)]))

(define (gb-fetch8! emu)
  (define pc (gb-emulator-pc emu))
  (define b (gb-read8 emu pc))
  (set-gb-emulator-pc! emu (bitwise-and #xFFFF (add1 pc)))
  b)

(define (gb-fetch16! emu)
  (define lo (gb-fetch8! emu))
  (define hi (gb-fetch8! emu))
  (bitwise-ior (arithmetic-shift hi 8) lo))

(define (gb-push16! emu w)
  (define sp (gb-emulator-sp emu))
  (gb-write8! emu (sub1 sp) (bitwise-and #xFF (arithmetic-shift w -8)))
  (gb-write8! emu (- sp 2) (bitwise-and #xFF w))
  (set-gb-emulator-sp! emu (bitwise-and #xFFFF (- sp 2))))

(define (gb-pop16! emu)
  (define sp (gb-emulator-sp emu))
  (define lo (gb-read8 emu sp))
  (define hi (gb-read8 emu (add1 sp)))
  (set-gb-emulator-sp! emu (bitwise-and #xFFFF (+ sp 2)))
  (bitwise-ior (arithmetic-shift hi 8) lo))

;; Step a single SM83 instruction
(define (gb-step! emu)
  (define op (gb-fetch8! emu))
  (define m 1)
  (case op
    [(#x00) (set! m 1)] ; NOP
    [(#xF3) (set-gb-emulator-ime! emu #f) (set! m 1)] ; DI
    [(#xFB) (set-gb-emulator-ime! emu #t) (set! m 1)] ; EI
    [(#x76) (set-gb-emulator-halted?! emu #t) (set! m 1)] ; HALT
    [(#x10) ; STOP
     (void (gb-fetch8! emu))
     (define key1 (bytes-ref (gb-emulator-io emu) #x4D))
     (when (bitwise-bit-set? key1 0)
       (set-gb-emulator-double-speed?! emu #t)
       (bytes-set! (gb-emulator-io emu) #x4D #x80))
     (set! m 1)]
    [(#xC9) ; RET
     (set-gb-emulator-pc! emu (gb-pop16! emu))
     (set! m 4)]
    [(#xD9) ; RETI
     (set-gb-emulator-pc! emu (gb-pop16! emu))
     (set-gb-emulator-ime! emu #t)
     (set! m 4)]
    ;; 8-bit Immediate Loads
    [(#x3E) (set-gb-emulator-a! emu (gb-fetch8! emu)) (set! m 2)]
    [(#x06) (set-gb-emulator-b! emu (gb-fetch8! emu)) (set! m 2)]
    [(#x0E) (set-gb-emulator-c! emu (gb-fetch8! emu)) (set! m 2)]
    [(#x16) (set-gb-emulator-d! emu (gb-fetch8! emu)) (set! m 2)]
    [(#x1E) (set-gb-emulator-e! emu (gb-fetch8! emu)) (set! m 2)]
    [(#x26) (set-gb-emulator-h! emu (gb-fetch8! emu)) (set! m 2)]
    [(#x2E) (set-gb-emulator-l! emu (gb-fetch8! emu)) (set! m 2)]
    ;; 16-bit Immediate Loads
    [(#x01) (gb-set-bc! emu (gb-fetch16! emu)) (set! m 3)]
    [(#x11) (gb-set-de! emu (gb-fetch16! emu)) (set! m 3)]
    [(#x21) (gb-set-hl! emu (gb-fetch16! emu)) (set! m 3)]
    [(#x31) (set-gb-emulator-sp! emu (gb-fetch16! emu)) (set! m 3)]
    ;; Indirect Loads
    [(#x77) (gb-write8! emu (gb-hl emu) (gb-emulator-a emu)) (set! m 2)]
    [(#x7E) (set-gb-emulator-a! emu (gb-read8 emu (gb-hl emu))) (set! m 2)]
    [(#x22) ; LDI (HL),A
     (define hl (gb-hl emu))
     (gb-write8! emu hl (gb-emulator-a emu))
     (gb-set-hl! emu (bitwise-and #xFFFF (add1 hl)))
     (set! m 2)]
    [(#x32) ; LDD (HL),A
     (define hl (gb-hl emu))
     (gb-write8! emu hl (gb-emulator-a emu))
     (gb-set-hl! emu (bitwise-and #xFFFF (sub1 hl)))
     (set! m 2)]
    [(#x2A) ; LDI A,(HL)
     (define hl (gb-hl emu))
     (set-gb-emulator-a! emu (gb-read8 emu hl))
     (gb-set-hl! emu (bitwise-and #xFFFF (add1 hl)))
     (set! m 2)]
    [(#x1A) ; LD A,(DE)
     (set-gb-emulator-a! emu (gb-read8 emu (gb-de emu)))
     (set! m 2)]
    [(#x12) ; LD (DE),A
     (gb-write8! emu (gb-de emu) (gb-emulator-a emu))
     (set! m 2)]
    ;; LDH ($FF00+u8) / ($FF00+C)
    [(#xE0)
     (define u8 (gb-fetch8! emu))
     (gb-write8! emu (+ #xFF00 u8) (gb-emulator-a emu))
     (set! m 3)]
    [(#xF0)
     (define u8 (gb-fetch8! emu))
     (set-gb-emulator-a! emu (gb-read8 emu (+ #xFF00 u8)))
     (set! m 3)]
    [(#xE2)
     (gb-write8! emu (+ #xFF00 (gb-emulator-c emu)) (gb-emulator-a emu))
     (set! m 2)]
    [(#xF2)
     (set-gb-emulator-a! emu (gb-read8 emu (+ #xFF00 (gb-emulator-c emu))))
     (set! m 2)]
    ;; Absolute 16-bit Loads
    [(#xEA)
     (define addr (gb-fetch16! emu))
     (gb-write8! emu addr (gb-emulator-a emu))
     (set! m 4)]
    [(#xFA)
     (define addr (gb-fetch16! emu))
     (set-gb-emulator-a! emu (gb-read8 emu addr))
     (set! m 4)]
    ;; INC / DEC 8-bit
    [(#x3C)
     (define v (bitwise-and #xFF (add1 (gb-emulator-a emu))))
     (set-gb-emulator-a! emu v)
     (gb-set-flags! emu (zero? v) #f (zero? (bitwise-and v #x0F)) (gb-flag-c? emu))
     (set! m 1)]
    [(#x3D)
     (define v (bitwise-and #xFF (sub1 (gb-emulator-a emu))))
     (set-gb-emulator-a! emu v)
     (gb-set-flags! emu (zero? v) #t (= (bitwise-and v #x0F) #x0F) (gb-flag-c? emu))
     (set! m 1)]
    [(#x04)
     (define v (bitwise-and #xFF (add1 (gb-emulator-b emu))))
     (set-gb-emulator-b! emu v)
     (gb-set-flags! emu (zero? v) #f (zero? (bitwise-and v #x0F)) (gb-flag-c? emu))
     (set! m 1)]
    [(#x05)
     (define v (bitwise-and #xFF (sub1 (gb-emulator-b emu))))
     (set-gb-emulator-b! emu v)
     (gb-set-flags! emu (zero? v) #t (= (bitwise-and v #x0F) #x0F) (gb-flag-c? emu))
     (set! m 1)]
    [(#x0C)
     (define v (bitwise-and #xFF (add1 (gb-emulator-c emu))))
     (set-gb-emulator-c! emu v)
     (gb-set-flags! emu (zero? v) #f (zero? (bitwise-and v #x0F)) (gb-flag-c? emu))
     (set! m 1)]
    [(#x0D)
     (define v (bitwise-and #xFF (sub1 (gb-emulator-c emu))))
     (set-gb-emulator-c! emu v)
     (gb-set-flags! emu (zero? v) #t (= (bitwise-and v #x0F) #x0F) (gb-flag-c? emu))
     (set! m 1)]
    ;; INC / DEC 16-bit
    [(#x23) (gb-set-hl! emu (bitwise-and #xFFFF (add1 (gb-hl emu)))) (set! m 2)]
    [(#x13) (gb-set-de! emu (bitwise-and #xFFFF (add1 (gb-de emu)))) (set! m 2)]
    [(#x0B) (gb-set-bc! emu (bitwise-and #xFFFF (sub1 (gb-bc emu)))) (set! m 2)]
    ;; 8-bit ALU Immediate & XOR A
    [(#xC6)
     (define imm (gb-fetch8! emu))
     (define a (gb-emulator-a emu))
     (define res (+ a imm))
     (define v (bitwise-and #xFF res))
     (set-gb-emulator-a! emu v)
     (gb-set-flags! emu (zero? v) #f (> (+ (bitwise-and a #x0F) (bitwise-and imm #x0F)) #x0F) (> res #xFF))
     (set! m 2)]
    [(#xD6)
     (define imm (gb-fetch8! emu))
     (define a (gb-emulator-a emu))
     (define res (- a imm))
     (define v (bitwise-and #xFF res))
     (set-gb-emulator-a! emu v)
     (gb-set-flags! emu (zero? v) #t (< (bitwise-and a #x0F) (bitwise-and imm #x0F)) (< res 0))
     (set! m 2)]
    [(#xE6)
     (define imm (gb-fetch8! emu))
     (define v (bitwise-and (gb-emulator-a emu) imm))
     (set-gb-emulator-a! emu v)
     (gb-set-flags! emu (zero? v) #f #t #f)
     (set! m 2)]
    [(#xF6)
     (define imm (gb-fetch8! emu))
     (define v (bitwise-ior (gb-emulator-a emu) imm))
     (set-gb-emulator-a! emu v)
     (gb-set-flags! emu (zero? v) #f #f #f)
     (set! m 2)]
    [(#xAF)
     (set-gb-emulator-a! emu 0)
     (gb-set-flags! emu #t #f #f #f)
     (set! m 1)]
    [(#xFE)
     (define imm (gb-fetch8! emu))
     (define a (gb-emulator-a emu))
     (define res (- a imm))
     (gb-set-flags! emu (= a imm) #t (< (bitwise-and a #x0F) (bitwise-and imm #x0F)) (< res 0))
     (set! m 2)]
    ;; $CB Prefix: BIT / RES / SET
    [(#xCB)
     (define cb (gb-fetch8! emu))
     (define kind (arithmetic-shift cb -6))
     (define bit-idx (bitwise-and (arithmetic-shift cb -3) 7))
     (define reg-code (bitwise-and cb 7))
     (define (read-reg rc)
       (case rc
         [(0) (gb-emulator-b emu)]
         [(1) (gb-emulator-c emu)]
         [(2) (gb-emulator-d emu)]
         [(3) (gb-emulator-e emu)]
         [(4) (gb-emulator-h emu)]
         [(5) (gb-emulator-l emu)]
         [(6) (gb-read8 emu (gb-hl emu))]
         [(7) (gb-emulator-a emu)]))
     (define (write-reg! rc val)
       (case rc
         [(0) (set-gb-emulator-b! emu val)]
         [(1) (set-gb-emulator-c! emu val)]
         [(2) (set-gb-emulator-d! emu val)]
         [(3) (set-gb-emulator-e! emu val)]
         [(4) (set-gb-emulator-h! emu val)]
         [(5) (set-gb-emulator-l! emu val)]
         [(6) (gb-write8! emu (gb-hl emu) val)]
         [(7) (set-gb-emulator-a! emu val)]))
     (define cur (read-reg reg-code))
     (case kind
       [(1) ; BIT u3, reg
        (gb-set-flags! emu (not (bitwise-bit-set? cur bit-idx)) #f #t (gb-flag-c? emu))
        (set! m (if (= reg-code 6) 3 2))]
       [(2) ; RES u3, reg
        (write-reg! reg-code (bitwise-and cur (bitwise-not (arithmetic-shift 1 bit-idx))))
        (set! m (if (= reg-code 6) 4 2))]
       [(3) ; SET u3, reg
        (write-reg! reg-code (bitwise-ior cur (arithmetic-shift 1 bit-idx)))
        (set! m (if (= reg-code 6) 4 2))]
       [else (set! m 2)])]
    ;; Jumps, Relative Branches & Calls
    [(#xC3) ; JP u16
     (set-gb-emulator-pc! emu (gb-fetch16! emu))
     (set! m 4)]
    [(#x18) ; JR rel8
     (define raw (gb-fetch8! emu))
     (define rel (if (>= raw 128) (- raw 256) raw))
     (set-gb-emulator-pc! emu (bitwise-and #xFFFF (+ (gb-emulator-pc emu) rel)))
     (set! m 3)]
    [(#x20) ; JR NZ, rel8
     (define raw (gb-fetch8! emu))
     (define rel (if (>= raw 128) (- raw 256) raw))
     (if (not (gb-flag-z? emu))
         (begin (set-gb-emulator-pc! emu (bitwise-and #xFFFF (+ (gb-emulator-pc emu) rel)))
                (set! m 3))
         (set! m 2))]
    [(#x28) ; JR Z, rel8
     (define raw (gb-fetch8! emu))
     (define rel (if (>= raw 128) (- raw 256) raw))
     (if (gb-flag-z? emu)
         (begin (set-gb-emulator-pc! emu (bitwise-and #xFFFF (+ (gb-emulator-pc emu) rel)))
                (set! m 3))
         (set! m 2))]
    [(#x30) ; JR NC, rel8
     (define raw (gb-fetch8! emu))
     (define rel (if (>= raw 128) (- raw 256) raw))
     (if (not (gb-flag-c? emu))
         (begin (set-gb-emulator-pc! emu (bitwise-and #xFFFF (+ (gb-emulator-pc emu) rel)))
                (set! m 3))
         (set! m 2))]
    [(#x38) ; JR C, rel8
     (define raw (gb-fetch8! emu))
     (define rel (if (>= raw 128) (- raw 256) raw))
     (if (gb-flag-c? emu)
         (begin (set-gb-emulator-pc! emu (bitwise-and #xFFFF (+ (gb-emulator-pc emu) rel)))
                (set! m 3))
         (set! m 2))]
    [(#xCD) ; CALL u16
     (define target (gb-fetch16! emu))
     (gb-push16! emu (gb-emulator-pc emu))
     (set-gb-emulator-pc! emu target)
     (set! m 6)]
    ;; Stack PUSH / POP
    [(#xF5) ; PUSH AF
     (gb-push16! emu (bitwise-ior (arithmetic-shift (gb-emulator-a emu) 8)
                                  (bitwise-and #xF0 (gb-emulator-f emu))))
     (set! m 4)]
    [(#xF1) ; POP AF
     (define af (gb-pop16! emu))
     (set-gb-emulator-a! emu (bitwise-and #xFF (arithmetic-shift af -8)))
     (set-gb-emulator-f! emu (bitwise-and #xF0 af))
     (set! m 3)]
    [(#xC5) (gb-push16! emu (gb-bc emu)) (set! m 4)]
    [(#xC1) (gb-set-bc! emu (gb-pop16! emu)) (set! m 3)]
    [(#xD5) (gb-push16! emu (gb-de emu)) (set! m 4)]
    [(#xD1) (gb-set-de! emu (gb-pop16! emu)) (set! m 3)]
    [(#xE5) (gb-push16! emu (gb-hl emu)) (set! m 4)]
    [(#xE1) (gb-set-hl! emu (gb-pop16! emu)) (set! m 3)]
    [else
     (error 'gb-step! "Unhandled SM83 opcode #x~a at PC $~a"
            (~r op #:base 16 #:min-width 2 #:pad-string "0")
            (~r (sub1 (gb-emulator-pc emu)) #:base 16 #:min-width 4 #:pad-string "0"))])
  (set-gb-emulator-m-cycles! emu (+ (gb-emulator-m-cycles emu) m))
  m)

;; Step one frame in the main loop (injecting `joypad-mask` into $FF90 and stepping until OAM DMA completes)
(define (gb-step-frame! emu [joypad-mask 0] #:max-steps [max-steps 4096])
  (gb-write8! emu (+ #xFF00 GB-HRAM-JOYPAD) joypad-mask)
  (define start-dma (gb-emulator-oam-dma-count emu))
  (let loop ([steps 0])
    (when (< steps max-steps)
      (gb-step! emu)
      ;; Stop after the frame's OAM DMA completes and returns from $FF80
      (unless (and (> (gb-emulator-oam-dma-count emu) start-dma)
                   (< (gb-emulator-pc emu) #xFF80))
        (loop (add1 steps))))))

;; Headless SM83 + PPU Verifier:
;;   1. Validates $0104-$0133 Nintendo logo, header checksum ($014D), and global checksum ($014E-$014F)
;;   2. Steps through boot (LCDC disable, HRAM OAM DMA trampoline install at $FF80, 2bpp tile upload
;;      to $8000, BG map to $9800, GBC 15-bit palette & HDMA upload, initial OAM DMA via CALL $FF80)
;;   3. Simulates a 4-stage campaign playthrough:
;;      Stage 0 -> Stage 1 -> Hazard/Failure -> START Recovery -> Stage 2 -> Stage 3 Victory
(define (verify-gb-rom-execution rom-bytes)
  (unless (= (bytes-length rom-bytes) 32768)
    (error 'verify-gb-rom-execution "Expected 32,768 B .gb/.gbc ROM, got ~a B" (bytes-length rom-bytes)))

  ;; 1. Verify Nintendo Logo ($0104-$0133) and Checksums
  (define logo-slice (subbytes rom-bytes #x0104 #x0134))
  (define valid-header?
    (and (equal? logo-slice NINTENDO-GB-LOGO-BYTES)
         (= (bytes-ref rom-bytes #x0100) #x00)
         (= (bytes-ref rom-bytes #x0101) #xC3)))

  (define expected-hdr-chk (compute-gb-header-checksum rom-bytes))
  (define actual-hdr-chk   (bytes-ref rom-bytes #x014D))
  (define expected-glob-chk (compute-gb-global-checksum rom-bytes))
  (define actual-glob-chk
    (bitwise-ior (arithmetic-shift (bytes-ref rom-bytes #x014E) 8)
                 (bytes-ref rom-bytes #x014F)))
  (define checksum-ok?
    (and (= expected-hdr-chk actual-hdr-chk)
         (= expected-glob-chk actual-glob-chk)))

  (define gbc-mode? (= (bytes-ref rom-bytes #x0143) #x80))

  ;; 2. Initialize Emulator and Step Through Boot until Initial OAM DMA Completes
  (define emu (make-gb-emulator-from-rom rom-bytes))
  (let boot-loop ([steps 0])
    (when (< steps 8192)
      (gb-step! emu)
      (unless (and (>= (gb-emulator-oam-dma-count emu) 1)
                   (< (gb-emulator-pc emu) #xFF80)
                   (= (gb-read8 emu (+ #xFF00 GB-HRAM-DMA-COUNT)) 1))
        (boot-loop (add1 steps)))))

  ;; Verify 10-byte HRAM OAM DMA trampoline installed at $FF80-$FF89
  (define installed-trampoline (subbytes (gb-emulator-hram emu) 0 10))
  (define hram-trampoline-match?
    (equal? installed-trampoline HRAM-OAM-DMA-TRAMPOLINE-BYTES))

  ;; 3. Simulate 4-Stage Playthrough:
  ;;    Stage 0 -> Stage 1 -> Hazard/Failure -> START Recovery -> Stage 2 -> Stage 3 Victory
  (define stage0 (gb-read8 emu (+ #xFF00 GB-HRAM-STAGE-ID)))

  ;; Advance Stage 0 -> Stage 1
  (gb-step-frame! emu GB-BTN-RIGHT)
  (gb-step-frame! emu GB-BTN-A)
  (define stage1 (gb-read8 emu (+ #xFF00 GB-HRAM-STAGE-ID)))

  ;; Trigger Hazard/Failure in Stage 1 (B button)
  (gb-step-frame! emu GB-BTN-B)
  (define fail-flag (gb-read8 emu (+ #xFF00 GB-HRAM-FAILED)))
  (define fail-ok? (= fail-flag 1))

  ;; Recover via START button
  (gb-step-frame! emu GB-BTN-START)
  (define rec-fail-flag (gb-read8 emu (+ #xFF00 GB-HRAM-FAILED)))
  (define rec-flag      (gb-read8 emu (+ #xFF00 GB-HRAM-RECOVERED)))
  (define rec-ok? (and (= rec-fail-flag 0) (= rec-flag 1)))

  ;; Advance Stage 1 -> Stage 2
  (gb-step-frame! emu GB-BTN-RIGHT)
  (gb-step-frame! emu GB-BTN-A)
  (define stage2 (gb-read8 emu (+ #xFF00 GB-HRAM-STAGE-ID)))

  ;; Advance Stage 2 -> Stage 3 Victory
  (gb-step-frame! emu GB-BTN-RIGHT)
  (gb-step-frame! emu GB-BTN-A)
  (define stage3  (gb-read8 emu (+ #xFF00 GB-HRAM-STAGE-ID)))
  (define won-flag (gb-read8 emu (+ #xFF00 GB-HRAM-WON)))
  (define full-win-ok?
    (and (= stage0 0) (= stage1 1) (= stage2 2) (= stage3 3) (= won-flag 1)))

  (define campaign-result
    (string-append
     (if fail-ok? "FAIL_OK" "FAIL_ERR")
     " -> "
     (if rec-ok? "REC_OK" "REC_ERR")
     " -> "
     (if full-win-ok? "FULL_WIN_OK" "WIN_ERR")))

  (hasheq 'valid-header?           valid-header?
          'checksum-ok?            checksum-ok?
          'header-checksum         actual-hdr-chk
          'global-checksum         actual-glob-chk
          'hram-dma-ok?            (and (gb-emulator-hram-dma-ok? emu) hram-trampoline-match?)
          'stat-mode-safe?         (gb-emulator-stat-mode-safe? emu)
          'gbc-mode?               gbc-mode?
          'gbc-double-speed?       (gb-emulator-double-speed? emu)
          'gbc-bgr555-palettes-ok? (if gbc-mode?
                                       (and (>= (gb-emulator-gbc-bg-pal-writes emu) 8)
                                            (>= (gb-emulator-gbc-obj-pal-writes emu) 8))
                                       #t)
          'hdma-transfers          (gb-emulator-hdma-transfers emu)
          'vram-tiles-uploaded     (quotient (gb-emulator-vram-writes emu) 16)
          'bg-map-writes           (gb-emulator-bg-map-writes emu)
          'oam-dma-transfers       (gb-emulator-oam-dma-count emu)
          'm-cycles-executed       (gb-emulator-m-cycles emu)
          'stages-visited          (list stage0 stage1 stage2 stage3)
          'failure-triggered?      fail-ok?
          'recovery-ok?            rec-ok?
          'victory-reached?        full-win-ok?
          'campaign-result         campaign-result))
