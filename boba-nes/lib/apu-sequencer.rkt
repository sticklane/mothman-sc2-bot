#lang racket/base

;; ============================================================================
;; lib/apu-sequencer.rkt
;; Ricoh 2A03 NTSC APU Multi-Channel Music & Envelope Sequencer Library
;;
;;   - 11-bit NTSC 2A03 Timer Period Lookup Table (`C3..B5` at 1.789773 MHz)
;;   - Zero-Page-Crossing 6502 Frame Music Sequencer (`Pulse 1` + `Triangle`)
;;   - Preset 16-Step Chiptune Melody Tables (`'overworld-march`, `'underground-bass`,
;;     `'korobeiniki-theme`, `'cyber-arcade`)
;; ============================================================================

(require racket/format
         racket/list)

(provide
 NTSC-APU-PERIOD-TABLE
 APU-MELODY-PRESETS
 apu-note-period
 emit-apu-music-sequencer-6502
 emit-apu-melody-table-6502)

;; 11-bit timer period lookup table for standard musical notes (`C3..B5`) on the
;; 1.789773 MHz NTSC 2A03 APU clock: T = round(1789773 / (16 * f_Hz) - 1)
(define NTSC-APU-PERIOD-TABLE
  (hasheq
   'REST 0
   ;; Octave 3 (C3 = 130.81 Hz .. B3 = 246.94 Hz)
   'C3   854   'CS3  806   'C#3  806
   'D3   761   'DS3  718   'D#3  718
   'E3   678
   'F3   640   'FS3  604   'F#3  604
   'G3   570   'GS3  538   'G#3  538
   'A3   507   'AS3  479   'A#3  479
   'B3   452
   ;; Octave 4 (C4 = 261.63 Hz .. B4 = 493.88 Hz, A4 = 440.00 Hz -> 253)
   'C4   427   'CS4  403   'C#4  403
   'D4   380   'DS4  359   'D#4  359
   'E4   338
   'F4   319   'FS4  301   'F#4  301
   'G4   284   'GS4  268   'G#4  268
   'A4   253   'AS4  239   'A#4  239
   'B4   225
   ;; Octave 5 (C5 = 523.25 Hz .. B5 = 987.77 Hz)
   'C5   213   'CS5  201   'C#5  201
   'D5   189   'DS5  179   'D#5  179
   'E5   169
   'F5   159   'FS5  150   'F#5  150
   'G5   142   'GS5  134   'G#5  134
   'A5   126   'AS5  119   'A#5  119
   'B5   112))

(define (apu-note-period note-sym)
  (cond
    [(exact-integer? note-sym) (bitwise-and #x07FF note-sym)]
    [(hash-has-key? NTSC-APU-PERIOD-TABLE note-sym)
     (hash-ref NTSC-APU-PERIOD-TABLE note-sym)]
    [else
     (error 'apu-note-period "unknown NTSC 2A03 note symbol: ~v" note-sym)]))

;; Canonical 16-step melody presets encoded as note symbol sequences
(define APU-MELODY-PRESETS
  (hasheq
   'overworld-march
   '(E5 E5 REST E5 REST C5 E5 REST G5 REST REST REST G4 REST REST REST)
   'underground-bass
   '(C4 C5 A3 A4 AS3 AS4 REST REST C4 C5 A3 A4 AS3 AS4 REST REST)
   'korobeiniki-theme
   '(E5 B4 C5 D5 C5 B4 A4 A4 C5 E5 D5 C5 B4 C5 D5 E5)
   'cyber-arcade
   '(A4 C5 E5 A5 G5 E5 C5 A4 F4 A4 C5 F5 E5 C5 B4 E5)))

;; Emit a zero-page-crossing 6502 routine that:
;;   1. Increments `zp-music-tick` every frame
;;   2. Steps `zp-music-idx` mod `note-count` every 2^tempo-shift frames
;;   3. Indexes `note-table-label` and drives Pulse 1 ($4000-$4003) & Triangle ($4008-$400B)
;;      within Grade L4 (no DMC DMA contention, zero page crossings)
(define (emit-apu-music-sequencer-6502 zp-music-tick zp-music-idx
                                       #:tempo-shift [tempo-shift 3]
                                       #:note-table-label [note-table-label 'apu_melody_table]
                                       #:note-count [note-count 16]
                                       #:label-prefix [prefix '__apu_seq])
  (define frame-mask (bitwise-and #xFF (sub1 (arithmetic-shift 1 tempo-shift))))
  (define lbl-rest (string->symbol (format "~a_rest" prefix)))
  (define lbl-adv  (string->symbol (format "~a_advance" prefix)))
  (define lbl-ok   (string->symbol (format "~a_idx_ok" prefix)))
  (define lbl-done (string->symbol (format "~a_done" prefix)))
  `((INC #:zp ,zp-music-tick)
    (LDA #:zp ,zp-music-tick)
    (AND #:imm ,frame-mask)
    (BNE ,lbl-done)
    (LDX #:zp ,zp-music-idx)
    (LDA #:absx ,note-table-label)
    (BEQ ,lbl-rest)
    ;; Drive 2A03 Pulse 1 ($4000-$4003) lead voice & Triangle ($4008-$400B) bass voice
    (STA #:abs #x4002)
    (STA #:abs #x400A)
    (LDA #:imm #x9C)
    (STA #:abs #x4000)
    (LDA #:imm #x08)
    (STA #:abs #x4001)
    (LDA #:imm #x18)
    (STA #:abs #x4003)
    (LDA #:imm #x81)
    (STA #:abs #x4008)
    (LDA #:imm #x18)
    (STA #:abs #x400B)
    (JMP ,lbl-adv)
    (label ,lbl-rest)
    (LDA #:imm #x90)
    (STA #:abs #x4000)
    (LDA #:imm #x00)
    (STA #:abs #x4008)
    (label ,lbl-adv)
    (INX)
    (CPX #:imm ,note-count)
    (BCC ,lbl-ok)
    (LDX #:imm 0)
    (label ,lbl-ok)
    (STX #:zp ,zp-music-idx)
    (label ,lbl-done)))

;; Emit a page-aligned 6502 melody period table for one of the presets
;; ('overworld-march, 'underground-bass, 'korobeiniki-theme, 'cyber-arcade)
;; or a custom list of note symbols.
(define (emit-apu-melody-table-6502 label-sym preset-name)
  (define notes
    (cond
      [(list? preset-name) preset-name]
      [(hash-has-key? APU-MELODY-PRESETS preset-name)
       (hash-ref APU-MELODY-PRESETS preset-name)]
      [else
       (hash-ref APU-MELODY-PRESETS 'overworld-march)]))
  (define period-bytes
    (for/list ([n (in-list notes)])
      (bitwise-and #xFF (apu-note-period n))))
  `((.align 256)
    (label ,label-sym)
    (.byte ,@period-bytes)))
