#lang racket/base

;; ============================================================================
;; tools/sm83-disassembler.rkt
;; Complete Sharp SM83 (LR35902) 256-Base + 256-CB-Prefix Disassembler,
;; Call-Graph Tracer, Symbolic DMG/CGB MMIO Annotator & Direct Instruction
;; Assembler for Commercial Game Boy (.gb) & Game Boy Color (.gbc) ROMs
;; ============================================================================

(require racket/bytes
         racket/format
         racket/list
         racket/match
         racket/set
         racket/string
         "cfg-structurer.rkt")

(provide
 (all-from-out "cfg-structurer.rkt")
 SM83-BASE-OPCODE-VEC
 SM83-CB-OPCODE-VEC
 SM83-MMIO-SYM-HASH
 sm83-addr->mmio-symbol
 disassemble-sm83-inst-at
 disassemble-sm83-linear-block
 lift-sm83-interrupt-vectors
 lift-sm83-bank-subroutines
 analyze-sm83-bank-deep
 assemble-sm83-inst-bytes
 assemble-sm83-subroutine-into!)

;; ============================================================================
;; 1. Canonical DMG & CGB Symbolic Hardware Register Table ($FF00-$FFFF)
;; ============================================================================

(define SM83-MMIO-SYM-HASH
  (hasheq
   ;; Joypad & Serial
   #xFF00 'JOYP
   #xFF01 'SB
   #xFF02 'SC
   ;; Timer & Divider
   #xFF04 'DIV
   #xFF05 'TIMA
   #xFF06 'TMA
   #xFF07 'TAC
   ;; Interrupt Flags
   #xFF0F 'IF
   ;; APU Channel 1 (Pulse + Sweep)
   #xFF10 'NR10
   #xFF11 'NR11
   #xFF12 'NR12
   #xFF13 'NR13
   #xFF14 'NR14
   ;; APU Channel 2 (Pulse)
   #xFF16 'NR21
   #xFF17 'NR22
   #xFF18 'NR23
   #xFF19 'NR24
   ;; APU Channel 3 (Wave)
   #xFF1A 'NR30
   #xFF1B 'NR31
   #xFF1C 'NR32
   #xFF1D 'NR33
   #xFF1E 'NR34
   ;; APU Channel 4 (Noise)
   #xFF20 'NR41
   #xFF21 'NR42
   #xFF22 'NR43
   #xFF23 'NR44
   ;; APU Master Control
   #xFF24 'NR50
   #xFF25 'NR51
   #xFF26 'NR52
   ;; Wave Pattern RAM ($FF30-$FF3F)
   #xFF30 'WAVE_RAM_0
   #xFF31 'WAVE_RAM_1
   #xFF32 'WAVE_RAM_2
   #xFF33 'WAVE_RAM_3
   #xFF34 'WAVE_RAM_4
   #xFF35 'WAVE_RAM_5
   #xFF36 'WAVE_RAM_6
   #xFF37 'WAVE_RAM_7
   #xFF38 'WAVE_RAM_8
   #xFF39 'WAVE_RAM_9
   #xFF3A 'WAVE_RAM_A
   #xFF3B 'WAVE_RAM_B
   #xFF3C 'WAVE_RAM_C
   #xFF3D 'WAVE_RAM_D
   #xFF3E 'WAVE_RAM_E
   #xFF3F 'WAVE_RAM_F
   ;; LCD / PPU Control, Status, Scroll & Palettes
   #xFF40 'LCDC
   #xFF41 'STAT
   #xFF42 'SCY
   #xFF43 'SCX
   #xFF44 'LY
   #xFF45 'LYC
   #xFF46 'DMA
   #xFF47 'BGP
   #xFF48 'OBP0
   #xFF49 'OBP1
   #xFF4A 'WY
   #xFF4B 'WX
   ;; CGB (Game Boy Color) Hardware Extensions
   #xFF4D 'KEY1
   #xFF4F 'VBK
   #xFF51 'HDMA1
   #xFF52 'HDMA2
   #xFF53 'HDMA3
   #xFF54 'HDMA4
   #xFF55 'HDMA5
   #xFF56 'RP
   #xFF68 'BCPS
   #xFF69 'BCPD
   #xFF6A 'OCPS
   #xFF6B 'OCPD
   #xFF70 'SVBK
   ;; Master Interrupt Enable
   #xFFFF 'IE))

(define (sm83-addr->mmio-symbol addr [is-write? #f])
  (cond
    [(hash-ref SM83-MMIO-SYM-HASH addr #f) => values]
    [(and (>= addr #xFF80) (<= addr #xFFFE))
     (string->symbol (format "HRAM_~a" (string-upcase (~r addr #:base 16 #:min-width 4 #:pad-string "0"))))]
    [(and is-write? (<= #x0000 addr #x1FFF)) 'MBC_RAM_EN]
    [(and is-write? (<= #x2000 addr #x3FFF)) 'MBC_ROM_BANK]
    [(and is-write? (<= #x4000 addr #x5FFF)) 'MBC_RAM_BANK]
    [(and is-write? (<= #x6000 addr #x7FFF)) 'MBC_BANK_MODE]
    [else #f]))

;; ============================================================================
;; 2. Complete 256-Opcode Base + 256-CB-Prefix Sharp SM83 Decode Tables
;; ============================================================================

;; Each entry in SM83-BASE-OPCODE-VEC is either `#f` (unmapped opcode) or:
;;   `(list mnemonic mode length flow-kind)`
;; where:
;;   - `mode` in '(imp d8 d16 a16 rel io8 cb)
;;   - `flow-kind` in '(normal call call-cond jp jp-cond jp-hl jr jr-cond ret ret-cond reti rst halt stop prefix-cb)
(define SM83-BASE-OPCODE-VEC (make-vector 256 #f))
(define SM83-CB-OPCODE-VEC   (make-vector 256 #f))

(define SM83-REG8-VEC '#(B C D E H L HL-IND A))
(define SM83-ALU-VEC  '#(ADD ADC SUB SBC AND XOR OR CP))
(define SM83-CB-SHIFT-VEC '#(RLC RRC RL RR SLA SRA SWAP SRL))

;; Populate 0x40..0x7F (LD r, r' and HALT at 0x76)
(for* ([dst (in-range 8)]
       [src (in-range 8)])
  (define op (+ #x40 (* dst 8) src))
  (if (= op #x76)
      (vector-set! SM83-BASE-OPCODE-VEC op (list 'HALT 'imp 1 'halt))
      (let ([mnem (string->symbol (format "LD_~a_~a"
                                          (vector-ref SM83-REG8-VEC dst)
                                          (vector-ref SM83-REG8-VEC src)))])
        (vector-set! SM83-BASE-OPCODE-VEC op (list mnem 'imp 1 'normal)))))

;; Populate 0x80..0xBF (8-bit ALU register ops)
(for* ([alu (in-range 8)]
       [src (in-range 8)])
  (define op (+ #x80 (* alu 8) src))
  (define mnem (string->symbol (format "~a_A_~a"
                                       (vector-ref SM83-ALU-VEC alu)
                                       (vector-ref SM83-REG8-VEC src))))
  (vector-set! SM83-BASE-OPCODE-VEC op (list mnem 'imp 1 'normal)))

;; Populate remaining base opcodes (0x00..0x3F and 0xC0..0xFF)
(for ([entry
       (in-list
        '((#x00 NOP imp 1 normal)
          (#x01 LD_BC d16 3 normal)
          (#x02 LD_BC_IND_A imp 1 normal)
          (#x03 INC_BC imp 1 normal)
          (#x04 INC_B imp 1 normal)
          (#x05 DEC_B imp 1 normal)
          (#x06 LD_B d8 2 normal)
          (#x07 RLCA imp 1 normal)
          (#x08 LD_A16_SP a16 3 normal)
          (#x09 ADD_HL_BC imp 1 normal)
          (#x0A LD_A_BC_IND imp 1 normal)
          (#x0B DEC_BC imp 1 normal)
          (#x0C INC_C imp 1 normal)
          (#x0D DEC_C imp 1 normal)
          (#x0E LD_C d8 2 normal)
          (#x0F RRCA imp 1 normal)

          (#x10 STOP d8 2 stop)
          (#x11 LD_DE d16 3 normal)
          (#x12 LD_DE_IND_A imp 1 normal)
          (#x13 INC_DE imp 1 normal)
          (#x14 INC_D imp 1 normal)
          (#x15 DEC_D imp 1 normal)
          (#x16 LD_D d8 2 normal)
          (#x17 RLA imp 1 normal)
          (#x18 JR rel 2 jr)
          (#x19 ADD_HL_DE imp 1 normal)
          (#x1A LD_A_DE_IND imp 1 normal)
          (#x1B DEC_DE imp 1 normal)
          (#x1C INC_E imp 1 normal)
          (#x1D DEC_E imp 1 normal)
          (#x1E LD_E d8 2 normal)
          (#x1F RRA imp 1 normal)

          (#x20 JR_NZ rel 2 jr-cond)
          (#x21 LD_HL d16 3 normal)
          (#x22 LD_HLI_A imp 1 normal)
          (#x23 INC_HL imp 1 normal)
          (#x24 INC_H imp 1 normal)
          (#x25 DEC_H imp 1 normal)
          (#x26 LD_H d8 2 normal)
          (#x27 DAA imp 1 normal)
          (#x28 JR_Z rel 2 jr-cond)
          (#x29 ADD_HL_HL imp 1 normal)
          (#x2A LD_A_HLI imp 1 normal)
          (#x2B DEC_HL imp 1 normal)
          (#x2C INC_L imp 1 normal)
          (#x2D DEC_L imp 1 normal)
          (#x2E LD_L d8 2 normal)
          (#x2F CPL imp 1 normal)

          (#x30 JR_NC rel 2 jr-cond)
          (#x31 LD_SP d16 3 normal)
          (#x32 LD_HLD_A imp 1 normal)
          (#x33 INC_SP imp 1 normal)
          (#x34 INC_HL_IND imp 1 normal)
          (#x35 DEC_HL_IND imp 1 normal)
          (#x36 LD_HL_IND d8 2 normal)
          (#x37 SCF imp 1 normal)
          (#x38 JR_C rel 2 jr-cond)
          (#x39 ADD_HL_SP imp 1 normal)
          (#x3A LD_A_HLD imp 1 normal)
          (#x3B DEC_SP imp 1 normal)
          (#x3C INC_A imp 1 normal)
          (#x3D DEC_A imp 1 normal)
          (#x3E LD_A d8 2 normal)
          (#x3F CCF imp 1 normal)

          ;; 0xC0..0xFF
          (#xC0 RET_NZ imp 1 ret-cond)
          (#xC1 POP_BC imp 1 normal)
          (#xC2 JP_NZ a16 3 jp-cond)
          (#xC3 JP a16 3 jp)
          (#xC4 CALL_NZ a16 3 call-cond)
          (#xC5 PUSH_BC imp 1 normal)
          (#xC6 ADD_A d8 2 normal)
          (#xC7 RST_00 imp 1 rst)
          (#xC8 RET_Z imp 1 ret-cond)
          (#xC9 RET imp 1 ret)
          (#xCA JP_Z a16 3 jp-cond)
          (#xCB PREFIX_CB cb 2 prefix-cb)
          (#xCC CALL_Z a16 3 call-cond)
          (#xCD CALL a16 3 call)
          (#xCE ADC_A d8 2 normal)
          (#xCF RST_08 imp 1 rst)

          (#xD0 RET_NC imp 1 ret-cond)
          (#xD1 POP_DE imp 1 normal)
          (#xD2 JP_NC a16 3 jp-cond)
          (#xD4 CALL_NC a16 3 call-cond)
          (#xD5 PUSH_DE imp 1 normal)
          (#xD6 SUB_A d8 2 normal)
          (#xD7 RST_10 imp 1 rst)
          (#xD8 RET_C imp 1 ret-cond)
          (#xD9 RETI imp 1 reti)
          (#xDA JP_C a16 3 jp-cond)
          (#xDC CALL_C a16 3 call-cond)
          (#xDE SBC_A d8 2 normal)
          (#xDF RST_18 imp 1 rst)

          (#xE0 LDH_OUT io8 2 normal)
          (#xE1 POP_HL imp 1 normal)
          (#xE2 LDH_C_OUT imp 1 normal)
          (#xE5 PUSH_HL imp 1 normal)
          (#xE6 AND_A d8 2 normal)
          (#xE7 RST_20 imp 1 rst)
          (#xE8 ADD_SP d8 2 normal)
          (#xE9 JP_HL imp 1 jp-hl)
          (#xEA LD_A16_A a16 3 normal)
          (#xEE XOR_A d8 2 normal)
          (#xEF RST_28 imp 1 rst)

          (#xF0 LDH_IN io8 2 normal)
          (#xF1 POP_AF imp 1 normal)
          (#xF2 LDH_C_IN imp 1 normal)
          (#xF3 DI imp 1 normal)
          (#xF5 PUSH_AF imp 1 normal)
          (#xF6 OR_A d8 2 normal)
          (#xF7 RST_30 imp 1 rst)
          (#xF8 LD_HL_SP_OFFSET d8 2 normal)
          (#xF9 LD_SP_HL imp 1 normal)
          (#xFA LD_A_A16 a16 3 normal)
          (#xFB EI imp 1 normal)
          (#xFE CP_A d8 2 normal)
          (#xFF RST_38 imp 1 rst)))])
  (vector-set! SM83-BASE-OPCODE-VEC (first entry) (rest entry)))

;; Populate all 256 CB-prefix opcodes (0x00..0xFF)
(for ([cb-op (in-range 256)])
  (define reg-sym (vector-ref SM83-REG8-VEC (bitwise-and cb-op 7)))
  (define sub-idx (bitwise-and (arithmetic-shift cb-op -3) 7))
  (define top-two (arithmetic-shift cb-op -6))
  (define mnem
    (case top-two
      [(0) (string->symbol (format "~a_~a" (vector-ref SM83-CB-SHIFT-VEC sub-idx) reg-sym))]
      [(1) (string->symbol (format "BIT_~a_~a" sub-idx reg-sym))]
      [(2) (string->symbol (format "RES_~a_~a" sub-idx reg-sym))]
      [(3) (string->symbol (format "SET_~a_~a" sub-idx reg-sym))]))
  (vector-set! SM83-CB-OPCODE-VEC cb-op (list mnem cb-op)))

;; Reverse lookup tables for direct SM83 instruction assembly
(define SM83-MNEM->OPCODE-HASH (make-hasheq))
(for ([op (in-range 256)])
  (define info (vector-ref SM83-BASE-OPCODE-VEC op))
  (when info
    (hash-set! SM83-MNEM->OPCODE-HASH (first info) (cons op info))))

(define SM83-CB-MNEM->OPCODE-HASH (make-hasheq))
(for ([cb-op (in-range 256)])
  (define info (vector-ref SM83-CB-OPCODE-VEC cb-op))
  (when info
    (hash-set! SM83-CB-MNEM->OPCODE-HASH (first info) cb-op)))

;; ============================================================================
;; 3. Single-Instruction Disassembler & Symbolic Annotator
;; ============================================================================

;; Disassemble one SM83 instruction at `rom-offset` (with logical CPU address `pc`).
;; Returns `#f` if out-of-bounds or invalid opcode, or a hash:
;;   'sexp       -> `(<mnem> <mode-kw> <operand> #:pc <pc> #:sym <sym>)`
;;   'len        -> 1, 2, or 3
;;   'flow       -> flow-kind
;;   'target     -> target address (for call/jp/jr/rst) or #f
;;   'mmio-reg   -> `(cons addr sym)` or #f
;;   'hram-addr  -> addr in $FF80..$FFFE or #f
;;   'mbc-write  -> addr in $0000..$7FFF or #f
(define (disassemble-sm83-inst-at rom-bytes rom-offset bank-end pc)
  (and (< rom-offset bank-end)
       (let* ([op (bytes-ref rom-bytes rom-offset)]
              [info (vector-ref SM83-BASE-OPCODE-VEC op)])
         (and info
              (match-let ([(list mnem mode len flow) info])
                (and (<= (+ rom-offset len) bank-end)
                     (let* ([b1 (if (>= len 2) (bytes-ref rom-bytes (+ rom-offset 1)) 0)]
                            [b2 (if (= len 3)  (bytes-ref rom-bytes (+ rom-offset 2)) 0)]
                            [u16 (bitwise-ior b1 (arithmetic-shift b2 8))])
                     (case mode
                       [(imp)
                        (define rst-target
                          (case mnem
                            [(RST_00) #x0000] [(RST_08) #x0008] [(RST_10) #x0010] [(RST_18) #x0018]
                            [(RST_20) #x0020] [(RST_28) #x0028] [(RST_30) #x0030] [(RST_38) #x0038]
                            [else #f]))
                        (hasheq 'sexp (if rst-target
                                          `(,mnem #:imp 0 #:pc ,pc #:sym ,(string->symbol (format "rst_~a" (~r rst-target #:base 16 #:min-width 2 #:pad-string "0"))))
                                          `(,mnem #:imp 0 #:pc ,pc))
                                'len 1
                                'flow flow
                                'target rst-target
                                'mmio-reg #f
                                'hram-addr #f
                                'mbc-write #f)]
                       [(cb)
                        (define cb-info (vector-ref SM83-CB-OPCODE-VEC b1))
                        (define cb-mnem (first cb-info))
                        (hasheq 'sexp `(,cb-mnem #:cb ,b1 #:pc ,pc)
                                'len 2
                                'flow 'normal
                                'target #f
                                'mmio-reg #f
                                'hram-addr #f
                                'mbc-write #f)]
                       [(d8)
                        (hasheq 'sexp `(,mnem #:d8 ,b1 #:pc ,pc)
                                'len 2
                                'flow flow
                                'target #f
                                'mmio-reg #f
                                'hram-addr #f
                                'mbc-write #f)]
                       [(io8)
                        (define io-addr (+ #xFF00 b1))
                        (define is-write? (eq? mnem 'LDH_OUT))
                        (define sym (sm83-addr->mmio-symbol io-addr is-write?))
                        (define is-hram? (and (>= io-addr #xFF80) (<= io-addr #xFFFE)))
                        (hasheq 'sexp (if sym
                                          `(,mnem #:io8 ,b1 #:pc ,pc #:sym ,sym)
                                          `(,mnem #:io8 ,b1 #:pc ,pc))
                                'len 2
                                'flow 'normal
                                'target #f
                                'mmio-reg (and (not is-hram?) sym (cons io-addr sym))
                                'hram-addr (and is-hram? io-addr)
                                'mbc-write #f)]
                       [(rel)
                        (define signed (if (>= b1 128) (- b1 256) b1))
                        (define target (bitwise-and #xFFFF (+ pc 2 signed)))
                        (define lbl (string->symbol (format "loc_~a" (string-upcase (~r target #:base 16 #:min-width 4 #:pad-string "0")))))
                        (hasheq 'sexp `(,mnem #:rel ,target #:pc ,pc #:sym ,lbl)
                                'len 2
                                'flow flow
                                'target target
                                'mmio-reg #f
                                'hram-addr #f
                                'mbc-write #f)]
                       [(d16)
                        (define sym (sm83-addr->mmio-symbol u16 #f))
                        (hasheq 'sexp (if sym
                                          `(,mnem #:d16 ,u16 #:pc ,pc #:sym ,sym)
                                          `(,mnem #:d16 ,u16 #:pc ,pc))
                                'len 3
                                'flow 'normal
                                'target #f
                                'mmio-reg (and sym (>= u16 #xFF00) (not (<= #xFF80 u16 #xFFFE)) (cons u16 sym))
                                'hram-addr (and (<= #xFF80 u16 #xFFFE) u16)
                                'mbc-write #f)]
                       [(a16)
                        (define is-write? (or (eq? mnem 'LD_A16_A) (eq? mnem 'LD_A16_SP)))
                        (define is-call?  (memq flow '(call call-cond)))
                        (define is-jp?    (memq flow '(jp jp-cond)))
                        (define mmio-sym  (and (not is-call?) (not is-jp?) (sm83-addr->mmio-symbol u16 is-write?)))
                        (define target-sym
                          (cond
                            [is-call? (string->symbol (format "sub_~a" (string-upcase (~r u16 #:base 16 #:min-width 4 #:pad-string "0"))))]
                            [is-jp?   (string->symbol (format "loc_~a" (string-upcase (~r u16 #:base 16 #:min-width 4 #:pad-string "0"))))]
                            [else     mmio-sym]))
                        (define is-hram? (and (not is-call?) (not is-jp?) (<= #xFF80 u16 #xFFFE)))
                        (define is-mbc?  (and is-write? (<= #x0000 u16 #x7FFF)))
                        (hasheq 'sexp (if target-sym
                                          `(,mnem #:a16 ,u16 #:pc ,pc #:sym ,target-sym)
                                          `(,mnem #:a16 ,u16 #:pc ,pc))
                                'len 3
                                'flow flow
                                'target (and (or is-call? is-jp?) u16)
                                'mmio-reg (and mmio-sym (not is-hram?) (not is-mbc?) (cons u16 mmio-sym))
                                'hram-addr (and is-hram? u16)
                                'mbc-write (and is-mbc? u16))]))))))))

;; ============================================================================
;; 4. Linear-Block / Subroutine Disassembler & Interrupt Vector Lifter
;; ============================================================================

(define (disassemble-sm83-linear-block rom-bytes bank-start bank-end bank-origin start-offset
                                       #:max-insts [max-insts 36]
                                       #:stop-offset [stop-offset bank-end])
  (define limit-end (min bank-end stop-offset))
  (define max-local-off (- limit-end bank-start))
  (let loop ([off start-offset]
             [cnt 0]
             [max-fwd-off start-offset]
             [insts '()]
             [calls '()]
             [mmio '()]
             [hram '()]
             [mbc '()])
    (if (or (>= (+ bank-start off) limit-end) (>= cnt max-insts))
        (hasheq 'size-bytes (- off start-offset)
                'insts      (reverse insts)
                'calls      (remove-duplicates (reverse calls))
                'mmio       (remove-duplicates (reverse mmio))
                'hram       (sort (remove-duplicates hram) <)
                'mbc-writes (sort (remove-duplicates mbc) <))
        (let* ([abs-off (+ bank-start off)]
               [pc      (+ bank-origin off)]
               [dec     (disassemble-sm83-inst-at rom-bytes abs-off limit-end pc)])
          (if (not dec)
              (hasheq 'size-bytes (- off start-offset)
                      'insts      (reverse insts)
                      'calls      (remove-duplicates (reverse calls))
                      'mmio       (remove-duplicates (reverse mmio))
                      'hram       (sort (remove-duplicates hram) <)
                      'mbc-writes (sort (remove-duplicates mbc) <))
              (let* ([len      (hash-ref dec 'len)]
                     [flow     (hash-ref dec 'flow)]
                     [target   (hash-ref dec 'target)]
                     [mmio-reg (hash-ref dec 'mmio-reg)]
                     [hram-a   (hash-ref dec 'hram-addr)]
                     [mbc-a    (hash-ref dec 'mbc-write)]
                     [insts1   (cons (hash-ref dec 'sexp) insts)]
                     [calls1   (if (and target (memq flow '(call call-cond jp rst)))
                                   (cons target calls)
                                   calls)]
                     [mmio1    (if mmio-reg (cons (cdr mmio-reg) mmio) mmio)]
                     [hram1    (if hram-a (cons hram-a hram) hram)]
                     [mbc1     (if mbc-a (cons mbc-a mbc) mbc)]
                     [next-off (+ off len)]
                     [new-fwd-off
                      (if (and target (memq flow '(jr-cond jp-cond jr)))
                          (let ([toff (- target bank-origin)])
                            (if (and (> toff next-off)
                                     (<= toff (min max-local-off (+ off 24))))
                                (max max-fwd-off toff)
                                max-fwd-off))
                          max-fwd-off)])
                (if (or (memq flow '(jp-hl halt stop rst))
                        (and (memq flow '(ret reti jp))
                             (>= next-off new-fwd-off)))
                    (hasheq 'size-bytes (- next-off start-offset)
                            'insts      (reverse insts1)
                            'calls      (remove-duplicates (reverse calls1))
                            'mmio       (remove-duplicates (reverse mmio1))
                            'hram       (sort (remove-duplicates hram1) <)
                            'mbc-writes (sort (remove-duplicates mbc1) <))
                    (loop next-off (add1 cnt) new-fwd-off insts1 calls1 mmio1 hram1 mbc1))))))))

;; Disassemble all 8 RST vectors ($0000..$0038), 5 hardware ISRs ($0040..$0060),
;; and the $0100 cartridge entry point from Bank 0!
(define SM83-VECTOR-SPECS
  '((rst_00       #x0000 #x0008)
    (rst_08       #x0008 #x0010)
    (rst_10       #x0010 #x0018)
    (rst_18       #x0018 #x0020)
    (rst_20       #x0020 #x0028)
    (rst_28       #x0028 #x0030)
    (rst_30       #x0030 #x0038)
    (rst_38       #x0038 #x0040)
    (vblank_isr   #x0040 #x0048)
    (lcd_stat_isr #x0048 #x0050)
    (timer_isr    #x0050 #x0058)
    (serial_isr   #x0058 #x0060)
    (joypad_isr   #x0060 #x0080)
    (cart_entry   #x0100 #x0104)))

(define (infer-sm83-semantic-sub-name bank-idx sub-addr blk)
  (cond
    [(and (= bank-idx 0) (= sub-addr #x0150))
     'main_entry_0150]
    [else
     (define insts (hash-ref blk 'insts '()))
     (define mmio  (hash-ref blk 'mmio '()))
     (define mbc-w (hash-ref blk 'mbc-writes '()))
     (define mnems (map car insts))
     (define hex-a (string-upcase (~r sub-addr #:base 16 #:min-width 4 #:pad-string "0")))
     (define prefix
       (cond
         [(memq 'DAA mnems)
          "bcd_score_math"]
         [(or (memq 'DMA mmio)
              (for/or ([m (in-list mmio)])
                (memq m '(HDMA1 HDMA2 HDMA3 HDMA4 HDMA5))))
          "dma_oam_vram_transfer"]
         [(memq 'JOYP mmio)
          "poll_joypad_matrix"]
         [(for/or ([m (in-list mmio)])
            (memq m '(LCDC STAT LY LYC SCX SCY BGP OBP0 OBP1 WY WX BCPS BCPD OCPS OCPD VBK)))
          "lcd_ppu_control"]
         [(or (memq 'SB mmio) (memq 'SC mmio))
          "serial_link_io"]
         [(for/or ([m (in-list mmio)])
            (or (memq m '(NR10 NR11 NR12 NR13 NR14 NR21 NR22 NR23 NR24
                          NR30 NR31 NR32 NR33 NR34 NR41 NR42 NR43 NR44 NR50 NR51 NR52))
                (regexp-match? #px"^WAVE_RAM_" (symbol->string m))))
          "apu_sound_channel"]
         [(or (pair? mbc-w)
              (for/or ([m (in-list mmio)])
                (memq m '(MBC_ROM_BANK MBC_RAM_EN MBC_RAM_BANK MBC_BANK_MODE))))
          "mbc_rom_bank_switch"]
         [(for/or ([mn (in-list mnems)])
            (memq mn '(LD_HLI_A LD_A_HLI LD_HLD_A LD_A_HLD)))
          "vram_wram_block_xfer"]
         [(for/or ([mn (in-list mnems)])
            (memq mn '(RST_28 JP_HL)))
          "state_table_dispatch"]
         [(for/or ([ins (in-list insts)])
            (and (pair? ins) (pair? (cdr ins)) (eq? (cadr ins) '#:cb)))
          "bitfield_flag_update"]
         [else
          "game_logic_step"]))
     (string->symbol (format "~a_b~a_~a" prefix bank-idx hex-a))]))

(define (rewrite-sm83-call-syms forms bank-idx sub-name-map)
  (for/list ([f (in-list forms)])
    (cond
      [(not (pair? f)) f]
      [(memq (car f) '(when-branch if-else then-branch else-branch
                       counted-loop spin-wait-mmio-loop do-while-loop guard-return))
       (let loop ([rem (cdr f)]
                  [hdr (list (car f))])
         (match rem
           [(list* (? keyword? k) v rest)
            (loop rest (cons v (cons k hdr)))]
           [_
            (append (reverse hdr) (rewrite-sm83-call-syms rem bank-idx sub-name-map))]))]
      [else
       (match f
         [`(,mnem #:a16 ,u16 #:pc ,pc #:sym ,old-sym)
          #:when (memq mnem '(CALL CALL_NZ CALL_Z CALL_NC CALL_C))
          (define t-bank (if (< u16 #x4000) 0 bank-idx))
          (define new-sym
            (or (hash-ref sub-name-map (cons t-bank u16) #f)
                (hash-ref sub-name-map u16 #f)
                old-sym))
          `(,mnem #:a16 ,u16 #:pc ,pc #:sym ,new-sym)]
         [_ f])])))

(define (lift-sm83-interrupt-vectors rom-bytes)
  (define b0-end (min (bytes-length rom-bytes) 16384))
  (for/list ([vspec (in-list SM83-VECTOR-SPECS)]
             #:when (< (second vspec) b0-end))
    (match-define (list vname vaddr vlimit) vspec)
    (define blk
      (disassemble-sm83-linear-block rom-bytes 0 b0-end #x0000 vaddr
                                     #:max-insts 16
                                     #:stop-offset (min b0-end vlimit)))
    (define-values (structured-body _stats)
      (structure-subroutine-cfg (hash-ref blk 'insts) #:arch 'sm83))
    (define pseudo-code
      (synthesize-subroutine-pseudo-code structured-body #:arch 'sm83))
    `(def-sm83-isr ,vname
       #:vector ,vaddr
       #:size-bytes ,(hash-ref blk 'size-bytes)
       #:calls ,(hash-ref blk 'calls)
       #:mmio ,(hash-ref blk 'mmio)
       ,pseudo-code
       ,@structured-body)))

;; ============================================================================
;; 5. Deep Bank Analyzer & Call-Graph Subroutine Lifter
;; ============================================================================

(define (analyze-sm83-bank-deep rom-bytes bank-idx bank-start bank-end
                                #:seed-entries [seed-entries '()]
                                #:max-subroutines [max-subroutines 24]
                                #:max-insts-per-sub [max-insts-per-sub 28])
  (define bank-origin (if (= bank-idx 0) #x0000 #x4000))
  (define bank-size   (- bank-end bank-start))
  (define start-off   (if (= bank-idx 0) #x0150 0))

  (define call-targets (mutable-set))
  (define hram-offsets (mutable-set))
  (define io-regs      (mutable-set))
  (define mbc-writes   (mutable-set))
  (define mmio-counts  (make-hasheq))
  (define inst-cnt     0)
  (define cb-bit-ops   0)
  (define sub-entry-Candidates '())

  ;; Seed entry points that fall within this bank's address range
  (for ([addr (in-list seed-entries)])
    (when (and (exact-integer? addr)
               (>= addr (+ bank-origin start-off))
               (< addr (+ bank-origin bank-size)))
      (set! sub-entry-Candidates (cons addr sub-entry-Candidates))))
  (when (and (= bank-idx 0) (< #x0150 bank-size))
    (set! sub-entry-Candidates (cons #x0150 sub-entry-Candidates)))
  (when (and (> bank-idx 0) (>= bank-size 16))
    (set! sub-entry-Candidates (cons #x4000 sub-entry-Candidates)))

  ;; Full bank instruction + call-graph + MMIO + HRAM + MBC linear scan
  (let loop ([off start-off]
             [after-ret? #t])
    (when (< (+ bank-start off) bank-end)
      (define pc (+ bank-origin off))
      (define op (bytes-ref rom-bytes (+ bank-start off)))
      (define info (vector-ref SM83-BASE-OPCODE-VEC op))
      (cond
        [(not info)
         (loop (add1 off) #f)]
        [else
         (match-define (list mnem mode len flow) info)
         (if (> (+ bank-start off len) bank-end)
             (loop (add1 off) #f)
             (let* ([b1 (if (>= len 2) (bytes-ref rom-bytes (+ bank-start off 1)) 0)]
                    [b2 (if (= len 3)  (bytes-ref rom-bytes (+ bank-start off 2)) 0)]
                    [u16 (bitwise-ior b1 (arithmetic-shift b2 8))])
               (set! inst-cnt (add1 inst-cnt))
               ;; If right after a RET/RETI and this looks like a valid subroutine prologue (PUSH, LD, LDH, XOR A, DI)
               (when (and after-ret?
                          (not (= op #x00))
                          (not (= op #xFF))
                          (< (length sub-entry-Candidates) (* max-subroutines 2)))
                 (set! sub-entry-Candidates (cons pc sub-entry-Candidates)))
               (cond
                 [(= op #xCB)
                  (set! cb-bit-ops (add1 cb-bit-ops))]
                 [(eq? mode 'io8)
                  (define io-addr (+ #xFF00 b1))
                  (if (>= b1 #x80)
                      (set-add! hram-offsets io-addr)
                      (let ([sym (sm83-addr->mmio-symbol io-addr (eq? mnem 'LDH_OUT))])
                        (set-add! io-regs io-addr)
                        (when sym
                          (hash-set! mmio-counts sym (add1 (hash-ref mmio-counts sym 0))))))]
                 [(memq flow '(call call-cond))
                  (set-add! call-targets u16)
                  (when (and (>= u16 (+ bank-origin start-off))
                             (< u16 (+ bank-origin bank-size)))
                    (set! sub-entry-Candidates (cons u16 sub-entry-Candidates)))]
                 [(eq? mode 'a16)
                  (define is-write? (or (eq? mnem 'LD_A16_A) (eq? mnem 'LD_A16_SP)))
                  (cond
                    [(<= #xFF00 u16 #xFF7F)
                     (set-add! io-regs u16)
                     (define sym (sm83-addr->mmio-symbol u16 is-write?))
                     (when sym
                       (hash-set! mmio-counts sym (add1 (hash-ref mmio-counts sym 0))))]
                    [(<= #xFF80 u16 #xFFFE)
                     (set-add! hram-offsets u16)]
                    [(and is-write? (<= #x2000 u16 #x3FFF))
                     (set-add! mbc-writes u16)
                     (hash-set! mmio-counts 'MBC_ROM_BANK (add1 (hash-ref mmio-counts 'MBC_ROM_BANK 0)))])])
               (loop (+ off len) (memq flow '(ret reti)))))])))

  ;; Deduplicate and sort discovered subroutine entry addresses in this bank
  (define unique-sub-addrs
    (take (sort (remove-duplicates sub-entry-Candidates) <)
          (min max-subroutines (length (remove-duplicates sub-entry-Candidates)))))

  (define bank-loops 0)
  (define bank-spin-waits 0)
  (define bank-conditionals 0)
  (define bank-guard-returns 0)
  (define sub-name-map (make-hash))

  ;; Pass 1: Disassemble blocks & assign semantic subroutine names
  (define raw-sub-entries
    (if (= max-subroutines 0)
        '()
        (for/list ([sub-addr (in-list unique-sub-addrs)]
                   [s-idx (in-naturals)])
          (define next-sub-addr
            (if (< (add1 s-idx) (length unique-sub-addrs))
                (list-ref unique-sub-addrs (add1 s-idx))
                (+ bank-origin bank-size)))
          (define sub-off (- sub-addr bank-origin))
          (define stop-off (+ bank-start (- next-sub-addr bank-origin)))
          (define blk
            (disassemble-sm83-linear-block rom-bytes bank-start bank-end bank-origin sub-off
                                           #:max-insts max-insts-per-sub
                                           #:stop-offset stop-off))
          (define sub-name (infer-sm83-semantic-sub-name bank-idx sub-addr blk))
          (hash-set! sub-name-map (cons bank-idx sub-addr) sub-name)
          (hash-set! sub-name-map sub-addr sub-name)
          (list sub-addr sub-off blk sub-name))))

  ;; Pass 2: Structure CFG, rewrite call targets to semantic names, & synthesize pseudo-code
  (define lifted-subs
    (for/list ([entry (in-list raw-sub-entries)])
      (match-define (list sub-addr sub-off blk sub-name) entry)
      (define-values (structured-body cfg-stats)
        (structure-subroutine-cfg (hash-ref blk 'insts) #:arch 'sm83))
      (set! bank-loops         (+ bank-loops         (hash-ref cfg-stats 'loops 0)))
      (set! bank-spin-waits    (+ bank-spin-waits    (hash-ref cfg-stats 'spin-waits 0)))
      (set! bank-conditionals  (+ bank-conditionals  (hash-ref cfg-stats 'conditionals 0)))
      (set! bank-guard-returns (+ bank-guard-returns (hash-ref cfg-stats 'guard-returns 0)))
      (define rewritten-body
        (rewrite-sm83-call-syms structured-body bank-idx sub-name-map))
      (define pseudo-code
        (synthesize-subroutine-pseudo-code rewritten-body #:arch 'sm83))
      (define sem-calls
        (for/list ([c (in-list (hash-ref blk 'calls))])
          (define t-bank (if (< c #x4000) 0 bank-idx))
          (or (hash-ref sub-name-map (cons t-bank c) #f)
              (hash-ref sub-name-map c #f)
              (string->symbol (format "sub_b~a_~a"
                                      t-bank
                                      (string-upcase (~r c #:base 16 #:min-width 4 #:pad-string "0")))))))
      `(defsub-sm83 ,sub-name
         #:bank ,bank-idx
         #:addr ,sub-addr
         #:offset ,sub-off
         #:size-bytes ,(hash-ref blk 'size-bytes)
         #:calls ,sem-calls
         #:mmio ,(hash-ref blk 'mmio)
         #:hram ,(hash-ref blk 'hram)
         #:mbc-writes ,(hash-ref blk 'mbc-writes)
         ,pseudo-code
         ,@rewritten-body)))

  (hasheq 'instruction-count        inst-cnt
          'cb-bit-ops               cb-bit-ops
          'call-targets             (sort (set->list call-targets) <)
          'hram-offsets             (sort (set->list hram-offsets) <)
          'io-regs                  (sort (set->list io-regs) <)
          'mbc-writes               (sort (set->list mbc-writes) <)
          'mmio-counts              mmio-counts
          'subroutines              lifted-subs
          'sub-name-map             sub-name-map
          'structured-loops         bank-loops
          'structured-spin-waits    bank-spin-waits
          'structured-conditionals  bank-conditionals
          'structured-guard-returns bank-guard-returns))

(define (lift-sm83-bank-subroutines rom-bytes bank-idx bank-start bank-end
                                    #:seed-entries [seed-entries '()]
                                    #:max-subroutines [max-subroutines 24])
  (hash-ref (analyze-sm83-bank-deep rom-bytes bank-idx bank-start bank-end
                                    #:seed-entries seed-entries
                                    #:max-subroutines max-subroutines)
            'subroutines))

;; ============================================================================
;; 6. Direct SM83 Instruction & Subroutine Assembler (S-exp -> Exact ROM Bytes)
;; ============================================================================

;; Assemble a single lifted SM83 instruction S-expression back into its 1, 2, or 3 bytes
(define (assemble-sm83-inst-bytes inst-sexp)
  (match inst-sexp
    [(list mnem mode-kw operand '#:pc pc _ ...)
     (case mode-kw
       [(#:cb)
        (bytes #xCB (bitwise-and #xFF operand))]
       [(#:imp)
        (define entry (hash-ref SM83-MNEM->OPCODE-HASH mnem #f))
        (unless entry (error 'assemble-sm83-inst-bytes "unknown SM83 imp mnemonic ~v" mnem))
        (bytes (car entry))]
       [(#:d8 #:io8)
        (define entry (hash-ref SM83-MNEM->OPCODE-HASH mnem #f))
        (unless entry (error 'assemble-sm83-inst-bytes "unknown SM83 d8/io8 mnemonic ~v" mnem))
        (bytes (car entry) (bitwise-and #xFF operand))]
       [(#:rel)
        (define entry (hash-ref SM83-MNEM->OPCODE-HASH mnem #f))
        (unless entry (error 'assemble-sm83-inst-bytes "unknown SM83 rel mnemonic ~v" mnem))
        (define rel-off (bitwise-and #xFF (- operand (+ pc 2))))
        (bytes (car entry) rel-off)]
       [(#:d16 #:a16)
        (define entry (hash-ref SM83-MNEM->OPCODE-HASH mnem #f))
        (unless entry (error 'assemble-sm83-inst-bytes "unknown SM83 d16/a16 mnemonic ~v" mnem))
        (bytes (car entry)
               (bitwise-and #xFF operand)
               (bitwise-and #xFF (arithmetic-shift operand -8)))]
       [else
        (error 'assemble-sm83-inst-bytes "unknown SM83 mode ~v in ~v" mode-kw inst-sexp)])]
    [_ #f]))

;; Assemble all instructions in a `(def-sm83-isr ...)` or `(defsub-sm83 ...)` form
;; (including nested structured control-flow forms) directly into `dst-bytes` at the bank's ROM offset!
(define (assemble-sm83-subroutine-into! sub-sexp dst-bytes)
  (define kind (and (pair? sub-sexp) (car sub-sexp)))
  (when (memq kind '(def-sm83-isr defsub-sm83))
    ;; Extract keyword headers vs body/instruction forms
    (define bank-idx 0)
    (define sub-off  0)
    (define body-forms '())
    (let loop ([rem (cddr sub-sexp)])
      (match rem
        [(list* '#:bank b rest)   (set! bank-idx b) (loop rest)]
        [(list* '#:vector v rest) (set! sub-off v)  (loop rest)]
        [(list* '#:offset o rest) (set! sub-off o)  (loop rest)]
        [(list* (? keyword?) _ rest) (loop rest)]
        [(cons form rest)
         (when (pair? form)
           (set! body-forms (cons form body-forms)))
         (loop rest)]
        ['() (void)]))
    (define flat-insts (flatten-structured-insts (reverse body-forms)))
    (define base-rom-off (+ (* bank-idx 16384) sub-off))
    (let iloop ([insts flat-insts]
                [cur-off base-rom-off])
      (when (pair? insts)
        (define ibytes (assemble-sm83-inst-bytes (car insts)))
        (when (and ibytes (<= (+ cur-off (bytes-length ibytes)) (bytes-length dst-bytes)))
          (bytes-copy! dst-bytes cur-off ibytes)
          (iloop (cdr insts) (+ cur-off (bytes-length ibytes))))))))
