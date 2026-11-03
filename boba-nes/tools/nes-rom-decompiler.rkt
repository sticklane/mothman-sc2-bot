#lang racket/base

;; ============================================================================
;; tools/nes-rom-decompiler.rkt
;; 6502 Recursive-Descent Disassembler, #lang boba-nes S-Expression Decompiler
;; & Commercial-vs-Compiled iNES ROM Binary Comparator
;; ============================================================================

(require racket/file
         racket/format
         racket/list
         racket/match
         racket/path
         racket/set
         racket/string
         "../lib/nes-chr-assets.rkt"
         "nes-resource-tool.rkt")

(provide
 disassemble-ines-rom
 decompile-ines-rom-to-boba-dsl
 compare-rom-binaries
 detect-6502-jump-engine-idioms
 infer-zp-roles-from-frame-trace
 detect-multi-stage-progression-from-trace
 decompile-multibank-ines-rom
 decode-smb-area-objects
 detect-zp-timer-array-idioms
 detect-nmi-sync-semaphore-idioms
 parse-fm2-tas-inputs
 serialize-fm2-tas-inputs)

;; ============================================================================
;; 1. Official MOS 6502 Opcode Decode Table (Opcode -> Mnemonic, Mode, Length)
;; ============================================================================

(define DISASM-OPCODE-VEC (make-vector 256 #f))

(for ([entry
       (in-list
        '(;; Load / Store
          (#xA9 LDA imm 2)  (#xA5 LDA zp 2)   (#xB5 LDA zpx 2)
          (#xAD LDA abs 3)  (#xBD LDA absx 3) (#xB9 LDA absy 3)
          (#xA1 LDA indx 2) (#xB1 LDA indy 2)
          (#xA2 LDX imm 2)  (#xA6 LDX zp 2)   (#xB6 LDX zpy 2)
          (#xAE LDX abs 3)  (#xBE LDX absy 3)
          (#xA0 LDY imm 2)  (#xA4 LDY zp 2)   (#xB4 LDY zpx 2)
          (#xAC LDY abs 3)  (#xBC LDY absx 3)
          (#x85 STA zp 2)   (#x95 STA zpx 2)
          (#x8D STA abs 3)  (#x9D STA absx 3) (#x99 STA absy 3)
          (#x81 STA indx 2) (#x91 STA indy 2)
          (#x86 STX zp 2)   (#x96 STX zpy 2)  (#x8E STX abs 3)
          (#x84 STY zp 2)   (#x94 STY zpx 2)  (#x8C STY abs 3)

          ;; Register Transfers & Stack
          (#xAA TAX imp 1)  (#xA8 TAY imp 1)  (#x8A TXA imp 1)  (#x98 TYA imp 1)
          (#xBA TSX imp 1)  (#x9A TXS imp 1)
          (#x48 PHA imp 1)  (#x08 PHP imp 1)  (#x68 PLA imp 1)  (#x28 PLP imp 1)

          ;; Logical & Bitwise
          (#x29 AND imm 2)  (#x25 AND zp 2)   (#x35 AND zpx 2)
          (#x2D AND abs 3)  (#x3D AND absx 3) (#x39 AND absy 3)
          (#x21 AND indx 2) (#x31 AND indy 2)
          (#x49 EOR imm 2)  (#x45 EOR zp 2)   (#x55 EOR zpx 2)
          (#x4D EOR abs 3)  (#x5D EOR absx 3) (#x59 EOR absy 3)
          (#x41 EOR indx 2) (#x51 EOR indy 2)
          (#x09 ORA imm 2)  (#x05 ORA zp 2)   (#x15 ORA zpx 2)
          (#x0D ORA abs 3)  (#x1D ORA absx 3) (#x19 ORA absy 3)
          (#x01 ORA indx 2) (#x11 ORA indy 2)
          (#x24 BIT zp 2)   (#x2C BIT abs 3)

          ;; Arithmetic & Compare
          (#x69 ADC imm 2)  (#x65 ADC zp 2)   (#x75 ADC zpx 2)
          (#x6D ADC abs 3)  (#x7D ADC absx 3) (#x79 ADC absy 3)
          (#x61 ADC indx 2) (#x71 ADC indy 2)
          (#xE9 SBC imm 2)  (#xE5 SBC zp 2)   (#xF5 SBC zpx 2)
          (#xED SBC abs 3)  (#xFD SBC absx 3) (#xF9 SBC absy 3)
          (#xE1 SBC indx 2) (#xF1 SBC indy 2)
          (#xC9 CMP imm 2)  (#xC5 CMP zp 2)   (#xD5 CMP zpx 2)
          (#xCD CMP abs 3)  (#xDD CMP absx 3) (#xD9 CMP absy 3)
          (#xC1 CMP indx 2) (#xD1 CMP indy 2)
          (#xE0 CPX imm 2)  (#xE4 CPX zp 2)   (#xEC CPX abs 3)
          (#xC0 CPY imm 2)  (#xC4 CPY zp 2)   (#xCC CPY abs 3)

          ;; Increment / Decrement
          (#xE6 INC zp 2)   (#xF6 INC zpx 2)  (#xEE INC abs 3)  (#xFE INC absx 3)
          (#xE8 INX imp 1)  (#xC8 INY imp 1)
          (#xC6 DEC zp 2)   (#xD6 DEC zpx 2)  (#xCE DEC abs 3)  (#xDE DEC absx 3)
          (#xCA DEX imp 1)  (#x88 DEY imp 1)

          ;; Shifts & Rotates
          (#x0A ASL acc 1)  (#x06 ASL zp 2)   (#x16 ASL zpx 2)  (#x0E ASL abs 3)  (#x1E ASL absx 3)
          (#x4A LSR acc 1)  (#x46 LSR zp 2)   (#x56 LSR zpx 2)  (#x4E LSR abs 3)  (#x5E LSR absx 3)
          (#x2A ROL acc 1)  (#x26 ROL zp 2)   (#x36 ROL zpx 2)  (#x2E ROL abs 3)  (#x3E ROL absx 3)
          (#x6A ROR acc 1)  (#x66 ROR zp 2)   (#x76 ROR zpx 2)  (#x6E ROR abs 3)  (#x7E ROR absx 3)

          ;; Jumps, Calls & Returns
          (#x4C JMP abs 3)  (#x6C JMP ind 3)
          (#x20 JSR abs 3)  (#x60 RTS imp 1)  (#x40 RTI imp 1)

          ;; Conditional Branches
          (#x90 BCC rel 2)  (#xB0 BCS rel 2)  (#xF0 BEQ rel 2)  (#x30 BMI rel 2)
          (#xD0 BNE rel 2)  (#x10 BPL rel 2)  (#x50 BVC rel 2)  (#x70 BVS rel 2)

          ;; Flags & System
          (#x18 CLC imp 1)  (#xD8 CLD imp 1)  (#x58 CLI imp 1)  (#xB8 CLV imp 1)
          (#x38 SEC imp 1)  (#xF8 SED imp 1)  (#x78 SEI imp 1)
          (#x00 BRK imp 1)  (#xEA NOP imp 1)))])
  (vector-set! DISASM-OPCODE-VEC (first entry) (rest entry)))

(define WRITE-MNEMONICS '(STA STX STY INC DEC ASL LSR ROL ROR))
(define READ-MNEMONICS  '(LDA LDX LDY BIT CMP CPX CPY AND ORA EOR ADC SBC))

(define (mapper-id->symbol mapper-id)
  (case mapper-id
    [(0) 'NROM]
    [(1) 'MMC1]
    [(2) 'UNROM]
    [(3) 'CNROM]
    [(4) 'MMC3]
    [else (string->symbol (format "MAPPER-~a" mapper-id))]))

(define (rom-src->bytes rom-path-or-bytes)
  (cond
    [(bytes? rom-path-or-bytes) rom-path-or-bytes]
    [(or (path? rom-path-or-bytes) (string? rom-path-or-bytes))
     (file->bytes rom-path-or-bytes)]
    [else
     (error 'rom-src->bytes "expected bytes? or path-string?, got ~v" rom-path-or-bytes)]))

;; ============================================================================
;; 2. Recursive-Descent 6502 Disassembler (`disassemble-ines-rom`)
;; ============================================================================

(define (disassemble-ines-rom rom-path-or-bytes)
  (define rom (rom-src->bytes rom-path-or-bytes))
  (define hdr (parse-ines-header rom))
  (define prg-off   (hash-ref hdr 'prg-offset))
  (define prg-bytes (hash-ref hdr 'prg-bytes))
  (define chr-bytes (hash-ref hdr 'chr-bytes))
  (define prg-banks (hash-ref hdr 'prg-banks))
  (define chr-banks (hash-ref hdr 'chr-banks))
  (define mapper-id (hash-ref hdr 'mapper))
  (define mirroring (hash-ref hdr 'mirroring))
  (define battery?  (hash-ref hdr 'battery?))
  (define prg       (subbytes rom prg-off (+ prg-off prg-bytes)))

  ;; Map CPU address $8000-$FFFF:
  ;;   $8000-$BFFF -> Bank 0 (first 16 KB)
  ;;   $C000-$FFFF -> Fixed last 16 KB bank
  (define (cpu-u8 addr)
    (define a (bitwise-and #xFFFF addr))
    (cond
      [(< a #xC000)
       (bytes-ref prg (- a #x8000))]
      [else
       (bytes-ref prg (+ (- prg-bytes 16384) (- a #xC000)))]))

  (define (cpu-u16 addr)
    (bitwise-ior (cpu-u8 addr)
                 (arithmetic-shift (cpu-u8 (add1 addr)) 8)))

  ;; Read 6502 Interrupt Vector Table from last 6 bytes of PRG-ROM ($FFFA-$FFFF)
  (define nmi-vec   (cpu-u16 #xFFFA))
  (define reset-vec (cpu-u16 #xFFFC))
  (define irq-vec   (cpu-u16 #xFFFE))
  (define vectors
    (hasheq 'nmi   nmi-vec
            'reset reset-vec
            'irq   irq-vec))

  ;; Recursive-descent control-flow walk from RESET, NMI, and IRQ vectors
  (define visited      (mutable-set))
  (define ppu-writes   (mutable-set))
  (define ppu-reads    (mutable-set))
  (define apu-writes   (mutable-set))
  (define joypad-reads (mutable-set))
  (define zp-addrs     (mutable-set))
  (define subroutines  (mutable-set))
  (define mapper-write-count 0)
  (define decoded-insts (make-hash)) ; pc -> sexp form

  (define worklist (list reset-vec nmi-vec irq-vec))

  (let loop ()
    (unless (null? worklist)
      (define pc (car worklist))
      (set! worklist (cdr worklist))
      (when (and (>= pc #x8000) (<= pc #xFFF9) (not (set-member? visited pc)))
        (set-add! visited pc)
        (define op (cpu-u8 pc))
        (define info (vector-ref DISASM-OPCODE-VEC op))
        (when info
          (match-define (list mnem mode len) info)
          (define arg8  (if (>= len 2) (cpu-u8 (+ pc 1)) 0))
          (define arg16 (if (= len 3)  (cpu-u16 (+ pc 1)) 0))

          ;; Record decoded S-expression instruction
          (define inst-sexp
            (case mode
              [(imp acc) (list mnem)]
              [(rel)
               (define signed (if (>= arg8 128) (- arg8 256) arg8))
               (list mnem (bitwise-and #xFFFF (+ pc 2 signed)))]
              [else
               (define kw (string->keyword (symbol->string mode)))
               (list mnem kw (if (= len 2) arg8 arg16))]))
          (hash-set! decoded-insts pc inst-sexp)

          ;; Zero-Page address tracking ($00-$FF)
          (when (memq mode '(zp zpx zpy indx indy))
            (set-add! zp-addrs arg8))
          (when (and (memq mode '(abs absx absy)) (< arg16 #x0100))
            (set-add! zp-addrs arg16))

          ;; Memory-mapped hardware register tracking ($2000-$FFFF)
          (when (memq mode '(abs absx absy))
            (define is-write? (and (memq mnem WRITE-MNEMONICS) #t))
            (define is-read?  (and (memq mnem READ-MNEMONICS) #t))
            (when (and is-write? (or (<= #x2000 arg16 #x2007) (= arg16 #x4014)))
              (set-add! ppu-writes arg16))
            (when (and is-read? (<= #x2000 arg16 #x2007))
              (set-add! ppu-reads arg16))
            (when (and is-write? (<= #x4000 arg16 #x4015) (not (= arg16 #x4014)))
              (set-add! apu-writes arg16))
            (when (and is-read? (or (= arg16 #x4016) (= arg16 #x4017)))
              (set-add! joypad-reads arg16))
            (when (and is-write? (>= arg16 #x8000))
              (set! mapper-write-count (add1 mapper-write-count))))

          ;; Advance control-flow worklist
          (cond
            [(eq? mnem 'JSR)
             (when (and (>= arg16 #x8000) (<= arg16 #xFFF9))
               (set-add! subroutines arg16)
               (set! worklist (cons arg16 worklist)))
             (set! worklist (cons (+ pc 3) worklist))]
            [(eq? mnem 'JMP)
             (when (and (eq? mode 'abs) (>= arg16 #x8000) (<= arg16 #xFFF9))
               (set! worklist (cons arg16 worklist)))]
            [(memq mnem '(RTS RTI BRK))
             (void)]
            [(eq? mode 'rel)
             (define signed (if (>= arg8 128) (- arg8 256) arg8))
             (define target (bitwise-and #xFFFF (+ pc 2 signed)))
             (set! worklist (list* target (+ pc 2) worklist))]
            [else
             (set! worklist (cons (+ pc len) worklist))])))
      (loop)))

  (define sorted-pcs (sort (hash-keys decoded-insts) <))
  (define ordered-insts
    (for/list ([pc (in-list sorted-pcs)])
      (hash-ref decoded-insts pc)))

  (define nonblank-chr
    (cond
      [(> chr-bytes 0)
       (count-nonblank-chr-tiles (extract-ines-chr-rom rom))]
      [(>= prg-bytes 65536)
       ;; CHR-RAM cartridge (e.g., Zelda): count tiles in extracted 8 KB CHR image
       (count-nonblank-chr-tiles (load-authentic-zelda-chr-rom rom))]
      [else 0]))

  (define sorted-zp   (sort (set->list zp-addrs) <))
  (define sorted-subs (sort (set->list subroutines) <))
  (define sorted-ppu  (sort (set->list ppu-writes) <))
  (define sorted-apu  (sort (set->list apu-writes) <))
  (define sorted-joy  (sort (set->list joypad-reads) <))

  (hasheq 'header             hdr
          'mapper             mapper-id
          'mapper-name        (mapper-id->symbol mapper-id)
          'prg-banks          prg-banks
          'chr-banks          chr-banks
          'prg-bytes          prg-bytes
          'chr-bytes          chr-bytes
          'mirroring          mirroring
          'battery-wram?      battery?
          'battery?           battery?
          'chr-ram?           (zero? chr-banks)
          'nonblank-chr-tiles nonblank-chr
          'vectors            vectors
          'ppu-writes         sorted-ppu
          'ppu-reads          (sort (set->list ppu-reads) <)
          'apu-writes         sorted-apu
          'joypad-reads       sorted-joy
          'mapper-writes      mapper-write-count
          'zp-addresses       sorted-zp
          'zp-count           (length sorted-zp)
          'subroutines        sorted-subs
          'subroutine-count   (length sorted-subs)
          'instructions       ordered-insts
          'instruction-count  (length ordered-insts)))

;; ============================================================================
;; 3. Decompile iNES ROM to #lang boba-nes S-Expression Module
;; ============================================================================

(define (decompile-ines-rom-to-boba-dsl rom-path-or-bytes #:game-name [game-name 'decompiled-rom])
  (define dis  (disassemble-ines-rom rom-path-or-bytes))
  (define vecs (hash-ref dis 'vectors))
  `(boba-nes-decompiled-module
    (game-name ,game-name)
    (cartridge
     (mapper ,(hash-ref dis 'mapper-name))
     (mapper-id ,(hash-ref dis 'mapper))
     (mirroring ,(hash-ref dis 'mirroring))
     (prg-banks ,(hash-ref dis 'prg-banks))
     (chr-banks ,(hash-ref dis 'chr-banks))
     (battery-wram? ,(hash-ref dis 'battery-wram?))
     (nonblank-chr-tiles ,(hash-ref dis 'nonblank-chr-tiles)))
    (vectors
     (nmi ,(hash-ref vecs 'nmi))
     (reset ,(hash-ref vecs 'reset))
     (irq ,(hash-ref vecs 'irq)))
    (hardware-capabilities
     (ppu-writes ,(hash-ref dis 'ppu-writes))
     (apu-writes ,(hash-ref dis 'apu-writes))
     (joypad-reads ,(hash-ref dis 'joypad-reads))
     (mapper-writes ,(hash-ref dis 'mapper-writes)))
    (zero-page-working-set
     (count ,(hash-ref dis 'zp-count))
     (addresses ,(hash-ref dis 'zp-addresses)))
    (subroutines
     (count ,(hash-ref dis 'subroutine-count))
     (entry-points ,(hash-ref dis 'subroutines)))))

;; ============================================================================
;; 4. Commercial-vs-Compiled ROM Binary Comparator (`compare-rom-binaries`)
;; ============================================================================

;; Extract canonical 8 KB CHR image from a ROM (supporting NROM 8KB, MMC1 16KB, and Zelda CHR-RAM)
(define (extract-canonical-8k-chr rom-bytes hdr)
  (define chr-bytes (hash-ref hdr 'chr-bytes))
  (define prg-bytes (hash-ref hdr 'prg-bytes))
  (cond
    [(= chr-bytes 8192)
     (extract-ines-chr-rom rom-bytes #:bank-8k 0)]
    [(> chr-bytes 8192)
     ;; Multi-bank CHR-ROM (e.g. Tetris 16 KB CHR-ROM where Bank 3 is the playfield bank)
     (load-authentic-tetris-chr-rom rom-bytes)]
    [(>= prg-bytes 65536)
     ;; CHR-RAM cartridge with pattern blocks in PRG-ROM (e.g. Legend of Zelda)
     (load-authentic-zelda-chr-rom rom-bytes)]
    [else
     (make-bytes 8192 0)]))

(define (compare-rom-binaries orig-rom-src compiled-rom-src)
  (define orig-bytes (rom-src->bytes orig-rom-src))
  (define comp-bytes (rom-src->bytes compiled-rom-src))
  (define orig-dis   (disassemble-ines-rom orig-bytes))
  (define comp-dis   (disassemble-ines-rom comp-bytes))

  (define orig-chr (extract-canonical-8k-chr orig-bytes (hash-ref orig-dis 'header)))
  (define comp-chr (extract-canonical-8k-chr comp-bytes (hash-ref comp-dis 'header)))

  (define total-chr-bytes (min (bytes-length orig-chr) (bytes-length comp-chr)))
  (define exact-match-bytes
    (for/sum ([i (in-range total-chr-bytes)])
      (if (= (bytes-ref orig-chr i) (bytes-ref comp-chr i)) 1 0)))

  (define matching-tiles
    (for/sum ([tid (in-range (quotient total-chr-bytes 16))])
      (define base (* tid 16))
      (if (equal? (subbytes orig-chr base (+ base 16))
                  (subbytes comp-chr base (+ base 16)))
          1
          0)))

  (define match-ratio
    (if (> total-chr-bytes 0)
        (exact->inexact (/ exact-match-bytes total-chr-bytes))
        1.0))

  (define orig-ppu (list->set (hash-ref orig-dis 'ppu-writes)))
  (define comp-ppu (list->set (hash-ref comp-dis 'ppu-writes)))
  (define shared-ppu (sort (set->list (set-intersect orig-ppu comp-ppu)) <))

  (define orig-apu (list->set (hash-ref orig-dis 'apu-writes)))
  (define comp-apu (list->set (hash-ref comp-dis 'apu-writes)))
  (define shared-apu (sort (set->list (set-intersect orig-apu comp-apu)) <))

  (define orig-joy (list->set (hash-ref orig-dis 'joypad-reads)))
  (define comp-joy (list->set (hash-ref comp-dis 'joypad-reads)))
  (define shared-joy (sort (set->list (set-intersect orig-joy comp-joy)) <))

  (define (valid-vecs? vhash)
    (and (<= #x8000 (hash-ref vhash 'nmi 0)   #xFFFF)
         (<= #x8000 (hash-ref vhash 'reset 0) #xFFFF)
         (<= #x8000 (hash-ref vhash 'irq 0)   #xFFFF)))

  (hasheq 'chr-exact-match-bytes   exact-match-bytes
          'chr-total-bytes         total-chr-bytes
          'chr-match-ratio         match-ratio
          'chr-matching-tiles      matching-tiles
          'orig-prg-bytes          (hash-ref orig-dis 'prg-bytes)
          'compiled-prg-bytes      (hash-ref comp-dis 'prg-bytes)
          'orig-chr-bytes          (hash-ref orig-dis 'chr-bytes)
          'compiled-chr-bytes      (hash-ref comp-dis 'chr-bytes)
          'shared-ppu-writes       shared-ppu
          'ppu-capability-overlap  (length shared-ppu)
          'shared-apu-writes       shared-apu
          'apu-capability-overlap  (length shared-apu)
          'shared-joypad-reads     shared-joy
          'orig-zp-count           (hash-ref orig-dis 'zp-count)
          'compiled-zp-count       (hash-ref comp-dis 'zp-count)
          'orig-subroutine-count   (hash-ref orig-dis 'subroutine-count)
          'compiled-subroutine-count (hash-ref comp-dis 'subroutine-count)
          'vectors-valid?          (and (valid-vecs? (hash-ref orig-dis 'vectors))
                                        (valid-vecs? (hash-ref comp-dis 'vectors)))))

;; ============================================================================
;; 5. Decompiler Spin-Offs: 6502 Jump-Engine Idiom Detector &
;;    Frame-by-Frame Zero-Page Semantic Role Classifier
;; ============================================================================

;; Scan disassembled 6502 instructions (or an iNES ROM) for indirect jump tables
;; (`JMP ($xxxx)`) and stack-synthesized `PHA ... PHA; RTS` dispatch engines
;; (used in SMB `JumpEngine`, Zelda `GameMode` dispatch, and Tetris `switch_s_plus_2a`).
(define (detect-6502-jump-engine-idioms dis-or-rom)
  (define dis
    (if (hash? dis-or-rom)
        dis-or-rom
        (disassemble-ines-rom dis-or-rom)))
  (define insts (hash-ref dis 'instructions '()))
  (define indirect-targets '())
  (define rts-dispatch-pcs '())

  (define (inst-mnem inst)
    (cond
      [(hash? inst) (hash-ref inst 'mnemonic #f)]
      [(and (pair? inst) (symbol? (car inst))) (car inst)]
      [else #f]))

  (for ([inst (in-list insts)])
    (cond
      [(and (hash? inst)
            (eq? (hash-ref inst 'mnemonic #f) 'JMP)
            (eq? (hash-ref inst 'mode #f) 'ind))
       (set! indirect-targets (cons (hash-ref inst 'operand 0) indirect-targets))]
      [(match inst [`(JMP #:ind ,addr) addr] [_ #f])
       => (lambda (addr) (set! indirect-targets (cons addr indirect-targets)))]))

  (let loop ([rem insts] [idx 0])
    (match rem
      [(list* i1 i2 i3 i4 i5 _)
       (define m1 (inst-mnem i1))
       (define window (list (inst-mnem i2) (inst-mnem i3) (inst-mnem i4) (inst-mnem i5)))
       (when (and (eq? m1 'PHA)
                  (memq 'PHA window)
                  (memq 'RTS window))
         (define pc-or-idx (if (hash? i1) (hash-ref i1 'pc idx) idx))
         (set! rts-dispatch-pcs (cons pc-or-idx rts-dispatch-pcs)))
       (loop (cdr rem) (add1 idx))]
      [else (void)]))

  (hasheq 'indirect-jmp-count   (length indirect-targets)
          'indirect-targets     (reverse indirect-targets)
          'rts-dispatch-count   (length rts-dispatch-pcs)
          'rts-dispatch-pcs     (reverse rts-dispatch-pcs)))

;; Given a chronological list of 256-byte Zero-Page snapshots `(list zp-bytes-0 zp-bytes-1 ...)`
;; captured across every frame of a precanned input sequence, automatically classify each
;; active Zero-Page address ($00-$FF) into its hardware/gameplay semantic role:
;;   - 'monotonic-frame-counter : increments by +1 mod 256 on every frame
;;   - 'prng-lfsr               : evolves via 8-bit Galois LFSR step (`(v >> 1) ^ ((v & 1) ? poly : 0)`)
;;   - 'player-or-actor-coord   : bounded per-frame velocity delta in [-8..+8] within screen/world range
;;   - 'hud-bcd-counter         : monotonically non-decreasing small counter (coins, score, rupees, lines)
;;   - 'game-phase-or-flag      : discrete state/boolean flag in {0, 1, 2, 3}
(define (infer-zp-roles-from-frame-trace zp-frames #:lfsr-poly [poly #xB8])
  (define num-frames (length zp-frames))
  (when (< num-frames 3)
    (error 'infer-zp-roles-from-frame-trace "expected at least 3 frame snapshots, got ~a" num-frames))

  (define (zp-at frame-snap addr)
    (cond
      [(bytes? frame-snap) (bytes-ref frame-snap addr)]
      [(vector? frame-snap) (bitwise-and #xFF (vector-ref frame-snap addr))]
      [else (error 'zp-at "expected bytes? or vector? snapshot")]))

  (define (lfsr-next v)
    (define shifted (arithmetic-shift v -1))
    (if (odd? v)
        (bitwise-xor shifted poly)
        shifted))

  (for/fold ([acc '()])
            ([addr (in-range 256)])
    (define series (for/list ([snap (in-list zp-frames)]) (zp-at snap addr)))
    (define v0 (first series))
    (define vN (last series))
    (define changed? (for/or ([v (in-list (cdr series))]) (not (= v v0))))
    (if (not changed?)
        acc
        (let* ([pairs (for/list ([a (in-list series)]
                                 [b (in-list (cdr series))])
                        (cons a b))]
               [mod-deltas (for/list ([p (in-list pairs)])
                             (modulo (- (cdr p) (car p)) 256))]
               [signed-deltas (for/list ([d (in-list mod-deltas)])
                                (if (> d 127) (- d 256) d))]
               [all-plus-one? (for/and ([d (in-list mod-deltas)]) (= d 1))]
               [all-lfsr? (for/and ([p (in-list pairs)])
                            (= (cdr p) (lfsr-next (car p))))]
               [all-flag-domain? (for/and ([v (in-list series)]) (<= 0 v 3))]
               [non-dec-small? (and (not all-flag-domain?)
                                    (for/and ([d (in-list signed-deltas)]) (<= 0 d 2))
                                    (for/and ([v (in-list series)]) (<= 0 v 99)))]
               [coord-like? (and (for/and ([d (in-list signed-deltas)]) (<= -16 d 16))
                                 (for/or ([v (in-list series)]) (>= v 4)))]
               [role (cond
                       [all-plus-one?    'monotonic-frame-counter]
                       [all-lfsr?        'prng-lfsr]
                       [non-dec-small?   'hud-bcd-counter]
                       [all-flag-domain? 'game-phase-or-flag]
                       [coord-like?      'player-or-actor-coord]
                       [else             'dynamic-working-state])])
          (cons (hasheq 'addr addr
                        'role role
                        'initial v0
                        'final vN)
                acc)))))

;; Analyze a multi-stage Zero-Page trace `(list zp-bytes-0 zp-bytes-1 ...)` to identify:
;;   - `stage-registers`   : Zero-Page addresses that step monotonically `0 -> 1 -> 2 ...` across multiple stages/levels
;;   - `recovery-registers`: Zero-Page flags that transition `0 -> 1 -> 0` (failure/death followed by START recovery)
;;   - `completion-flags`  : Zero-Page flags that start at `0` and terminate at `1` at the end of the campaign
(define (detect-multi-stage-progression-from-trace zp-frames)
  (define (zp-at frame-snap addr)
    (cond
      [(bytes? frame-snap) (bytes-ref frame-snap addr)]
      [(vector? frame-snap) (bitwise-and #xFF (vector-ref frame-snap addr))]
      [else (error 'zp-at "expected bytes? or vector? snapshot")]))

  (define stage-regs '())
  (define recovery-regs '())
  (define completion-flags '())

  (for ([addr (in-range 256)])
    (define series (for/list ([snap (in-list zp-frames)]) (zp-at snap addr)))
    (define v0 (first series))
    (define vN (last series))
    (define distinct (remove-duplicates series))
    (define pairs (for/list ([a (in-list series)] [b (in-list (cdr series))]) (cons a b)))
    (define non-dec? (for/and ([p (in-list pairs)]) (<= (car p) (cdr p))))
    (define unit-steps? (for/and ([p (in-list pairs)]) (<= (- (cdr p) (car p)) 1)))
    ;; 1. Multi-stage register: starts at 0, non-decreasing by +1 steps, reaches >= 2 distinct stages (e.g. 0->1->2->3)
    (when (and (= v0 0) (>= vN 2) (<= vN 16) non-dec? unit-steps?)
      (set! stage-regs (cons (hasheq 'addr addr 'max-stage vN 'stages-visited distinct) stage-regs)))
    ;; 2. Failure-then-recovery register: starts at 0, visits 1, returns to 0
    (when (and (= v0 0)
               (equal? (sort distinct <) '(0 1))
               (for/or ([p (in-list pairs)]) (and (= (car p) 1) (= (cdr p) 0))))
      (set! recovery-regs (cons addr recovery-regs)))
    ;; 3. Final campaign completion flag: starts at 0, only ever transitions 0 -> 1 once, ends at 1
    (when (and (= v0 0) (= vN 1) non-dec? (equal? distinct '(0 1)))
      (set! completion-flags (cons addr completion-flags))))

  (hasheq 'stage-registers    (reverse stage-regs)
          'recovery-registers (reverse recovery-regs)
          'completion-flags   (reverse completion-flags)))

;; ============================================================================
;; 6. Multi-Bank MMC1/UNROM Decompilation, SMB Area Object Decoder,
;;    Community Disassembly Idioms & FCEUX .fm2 TAS Movie Parser
;; ============================================================================

;; Inspect all K 16 KB PRG-ROM banks (0..K-1) of an NROM/MMC1/UNROM/CNROM/MMC3 ROM,
;; disassemble each switchable bank at $8000 and the fixed bank at $C000,
;; and emit `#lang boba-nes` `defbanked-table` S-expressions with per-bank statistics.
(define (decompile-multibank-ines-rom rom-path-or-bytes)
  (define rom (rom-src->bytes rom-path-or-bytes))
  (define hdr (parse-ines-header rom))
  (define prg-off   (hash-ref hdr 'prg-offset))
  (define prg-bytes (hash-ref hdr 'prg-bytes))
  (define prg-banks (hash-ref hdr 'prg-banks))
  (define chr-banks (hash-ref hdr 'chr-banks))
  (define mapper-id (hash-ref hdr 'mapper))
  (define prg       (subbytes rom prg-off (+ prg-off prg-bytes)))

  (define bank-reports
    (for/list ([b (in-range prg-banks)])
      (define bank-start (* b 16384))
      (define bank-slice (subbytes prg bank-start (+ bank-start 16384)))
      (define is-fixed?  (= b (sub1 prg-banks)))
      (define base-addr  (if is-fixed? #xC000 #x8000))

      ;; Scan 16 KB bank for valid 6502 instruction sequences and data table bytes
      (define inst-cnt 0)
      (define sub-cnt 0)
      (define code-bytes 0)
      (let loop ([off 0])
        (when (< off 16380)
          (define op (bytes-ref bank-slice off))
          (define info (vector-ref DISASM-OPCODE-VEC op))
          (cond
            [info
             (match-define (list mnem _mode len) info)
             (when (<= (+ off len) 16384)
               (set! inst-cnt (add1 inst-cnt))
               (set! code-bytes (+ code-bytes len))
               (when (eq? mnem 'JSR)
                 (set! sub-cnt (add1 sub-cnt))))
             (loop (+ off len))]
            [else
             (loop (add1 off))])))

      (define non-empty-bytes
        (for/sum ([i (in-range 16384)])
          (define v (bytes-ref bank-slice i))
          (if (or (= v #x00) (= v #xFF)) 0 1)))
      (define table-byte-cnt (max 0 (- 16384 code-bytes)))
      (define sample-bytes
        (for/list ([i (in-range (min 16 (bytes-length bank-slice)))])
          (bytes-ref bank-slice i)))
      (define tbl-sym (string->symbol (format "prg_bank_~a_table" b)))
      (define defbanked-sexp
        `(defbanked-table ,tbl-sym
           #:bank ,b
           #:origin ,base-addr
           (.byte ,@sample-bytes)))

      (hasheq 'bank              b
              'role              (if is-fixed? 'fixed 'switchable)
              'origin            base-addr
              'base-addr         base-addr
              'size-bytes        16384
              'instruction-count inst-cnt
              'subroutine-count  sub-cnt
              'table-bytes       table-byte-cnt
              'table-byte-count  table-byte-cnt
              'non-empty-bytes   non-empty-bytes
              'defbanked-table   defbanked-sexp)))

  (define defbanked-tables
    (map (lambda (h) (hash-ref h 'defbanked-table)) bank-reports))
  (define total-insts
    (for/sum ([h (in-list bank-reports)]) (hash-ref h 'instruction-count)))

  (hasheq 'mapper             mapper-id
          'mapper-name        (mapper-id->symbol mapper-id)
          'prg-banks          prg-banks
          'bank-count         prg-banks
          'chr-banks          chr-banks
          'fixed-bank         (sub1 prg-banks)
          'switchable-banks   (max 0 (sub1 prg-banks))
          'banks              bank-reports
          'defbanked-tables   defbanked-tables
          'total-instructions total-insts))

;; Decode SMB-style 2-byte compressed area objects `(coord-byte, type-len-byte)`
;; into structured column descriptors:
;;   - `coord-byte`: upper nibble = `col-x` (0..15), lower nibble = `row-y` (0..15)
;;   - `type-len-byte`: bit 7 = `page-flag` (0 or 1), bits 6..4 = `obj-type` (0..7),
;;                      bits 3..0 = `length` (1..16, i.e., low-nibble + 1)
(define (decode-smb-area-objects byte-seq)
  (define raw-list
    (cond
      [(bytes? byte-seq) (bytes->list byte-seq)]
      [(list? byte-seq)  byte-seq]
      [else (error 'decode-smb-area-objects "expected list? or bytes?, got ~v" byte-seq)]))
  (let loop ([rem raw-list]
             [acc '()])
    (match rem
      [(list* #xFD _)
       (reverse acc)]
      [(list* coord-byte type-len-byte rest-bytes)
       (define col-x     (bitwise-and (arithmetic-shift coord-byte -4) #x0F))
       (define row-y     (bitwise-and coord-byte #x0F))
       (define page-flag (if (bitwise-bit-set? type-len-byte 7) 1 0))
       (define obj-type  (bitwise-and (arithmetic-shift type-len-byte -4) #x07))
       (define raw-len   (bitwise-and type-len-byte #x0F))
       (define obj-desc
         (hasheq 'page-flag page-flag
                 'col-x     col-x
                 'row-y     row-y
                 'obj-type  obj-type
                 'length    (add1 raw-len)
                 'raw-len   raw-len))
       (loop rest-bytes (cons obj-desc acc))]
      [_
       (reverse acc)])))

(define (extract-inst-stream src)
  (cond
    [(list? src) src]
    [(and (hash? src) (hash-has-key? src 'instructions))
     (hash-ref src 'instructions)]
    [else
     (hash-ref (disassemble-ines-rom src) 'instructions '())]))

;; Detect indexed Zero-Page / work-RAM countdown timer loops
;; (`DEC zp,X` or `DEC abs,X` followed by `DEX`/`DEY` and `BPL`/`BNE`,
;; as used in Donkey Kong $34-$45 and Super Mario Bros. $0780-$07A3).
(define (detect-zp-timer-array-idioms inst-src)
  (define insts
    (filter (lambda (f) (not (and (pair? f) (eq? (car f) 'label))))
            (extract-inst-stream inst-src)))
  (define matches '())

  (let loop ([rem insts]
             [idx 0])
    (match rem
      [(cons head tail)
       (define dec-info
         (match head
           [`(DEC #:zpx ,base)  (list 'zpx base)]
           [`(DEC #:absx ,base) (list 'absx base)]
           [_ #f]))
       (when dec-info
         (match-define (list mode base-addr) dec-info)
         (define window (take tail (min 4 (length tail))))
         (define has-dex?
           (for/or ([w (in-list window)])
             (match w
               [`(DEX) #t]
               [`(DEY) #t]
               [_ #f])))
         (define branch-mnem
           (for/or ([w (in-list window)])
             (match w
               [`(BPL ,_) 'BPL]
               [`(BNE ,_) 'BNE]
               [_ #f])))
         (when (and has-dex? branch-mnem)
           (set! matches
                 (cons (hasheq 'base-addr base-addr
                               'mode      mode
                               'branch    branch-mnem
                               'index     idx)
                       matches))))
       (loop tail (add1 idx))]
      [_ (void)]))

  (define rev-matches (reverse matches))
  (hasheq 'count            (length rev-matches)
          'timer-loop-count (length rev-matches)
          'base-addresses   (remove-duplicates (map (lambda (m) (hash-ref m 'base-addr)) rev-matches))
          'matches          rev-matches))

;; Detect main-thread NMI frame-wait spinloops (`LDA zp; BEQ *-2` or `BNE *-2`,
;; as used in Balloon Fight $0002, Pac-Man, and Super Mario Bros.).
(define (detect-nmi-sync-semaphore-idioms inst-src)
  (define raw-insts (extract-inst-stream inst-src))
  (define insts
    (filter (lambda (f) (not (and (pair? f) (eq? (car f) 'label))))
            raw-insts))
  (define matches '())

  (let loop ([rem insts]
             [idx 0])
    (match rem
      [(list* i1 i2 tail)
       (define zp-addr
         (match i1
           [`(LDA #:zp ,a) a]
           [`(BIT #:zp ,a) a]
           [`(LDA #:abs ,a) #:when (< a #x0800) a]
           [_ #f]))
       (define branch-info
         (match i2
           [`(BEQ ,t) (list 'BEQ t)]
           [`(BNE ,t) (list 'BNE t)]
           [_ #f]))
       (when (and zp-addr branch-info)
         (match-define (list b-mnem target) branch-info)
         (set! matches
               (cons (hasheq 'zp-addr zp-addr
                             'branch  b-mnem
                             'target  target
                             'index   idx)
                     matches)))
       (loop (cons i2 tail) (add1 idx))]
      [_ (void)]))

  (define rev-matches (reverse matches))
  (hasheq 'count           (length rev-matches)
          'semaphore-count (length rev-matches)
          'semaphore-addrs (remove-duplicates (map (lambda (m) (hash-ref m 'zp-addr)) rev-matches))
          'matches         rev-matches))

;; Parse standard FCEUX `.fm2` TAS movie input lines (`|0|RLDUTSBA|...|`)
;; into a list of frame-by-frame 8-bit NES joypad bitmasks
;; (`BTN-A=#x01`, `BTN-B=#x02`, `BTN-SELECT=#x04`, `BTN-START=#x08`,
;;  `BTN-UP=#x10`, `BTN-DOWN=#x20`, `BTN-LEFT=#x40`, `BTN-RIGHT=#x80`).
(define (parse-fm2-tas-inputs fm2-text)
  (define lines (string-split fm2-text "\n"))
  (reverse
   (for/fold ([acc '()])
             ([raw-line (in-list lines)])
     (define line (string-trim raw-line))
     (if (and (>= (string-length line) 11)
              (char=? (string-ref line 0) #\|))
         (let* ([parts (string-split line "|" #:trim? #f)]
                ;; parts: '("" "0" "RLDUTSBA" ...)
                [port0 (if (>= (length parts) 3) (list-ref parts 2) "")])
           (if (>= (string-length port0) 8)
               (let ([mask
                      (for/fold ([m 0])
                                ([i (in-range 8)])
                        (define ch (string-ref port0 i))
                        (if (memv ch '(#\. #\space #\0))
                            m
                            (bitwise-ior m (arithmetic-shift 1 (- 7 i)))))])
                 (cons mask acc))
               acc))
         acc))))

;; Serialize a list of 8-bit NES joypad button masks into standard FCEUX `.fm2`
;; frame lines (`|0|RLDUTSBA|||`).
(define (serialize-fm2-tas-inputs button-mask-list)
  (define btn-chars "RLDUTSBA")
  (string-join
   (for/list ([mask (in-list button-mask-list)])
     (define p0-str
       (list->string
        (for/list ([i (in-range 8)])
          (if (bitwise-bit-set? mask (- 7 i))
              (string-ref btn-chars i)
              #\.))))
     (format "|0|~a|||" p0-str))
   "\n"))
