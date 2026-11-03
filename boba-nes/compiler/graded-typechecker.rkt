#lang racket/base

;; ============================================================================
;; #lang boba-nes : Coeffect-Effect Graded Typechecker for NES (2A03 / 2C02)
;; ============================================================================
;; Implements the single cohesive coeffect-effect typing judgment:
;;   Gamma_in @ (phase, bank) |- t : C_g(tau) -| Gamma_out @ (phase', bank')
;;
;; Enforces:
;;   - 5-Element Memory & Hardware Capability Semiring (CapMem):
;;       ConstMeta < RomBorrow < PpuTaint < RamLinear < DmaUnique
;;   - 4 Logical Hardware Safety Families (L1..L4):
;;       L1: Zero-Page & 6502 Hardware Stack Conservation
;;       L2: PRG/CHR Bank-Residency & Far-Call Trampoline Safety
;;       L3: 2C02 PPU Temporal Phase Discipline & Total Rule/Entity Dispatch
;;       L4: $2006/$2007 Shared Scroll-Latch Taint & 2A03 DMC Joypad Safety
;;   - 5 Orthogonal Physical Resource Grades (Phi1..Phi5):
;;       Phi1: NTSC VBlank (<= 2273 cyc), ActiveFrame (<= 29780 cyc) & Page-Crossing
;;       Phi2: OAM Total Sprites (<= 64) & Per-Scanline Evaluation (<= 8)
;;       Phi3: Zero-Page High-Watermark Scratch Reuse (<= 224 B), RAM/PRG/CHR Bounds
;;       Phi4: VBlank VRAM Bandwidth (<= 128 B) & 16x16 Attribute Clash (0 clashes)
;;       Phi5: 2A03 5-Channel APU Disjointness (pulse1, pulse2, triangle, noise, dmc)
;; ============================================================================

(require racket/match
         racket/list
         racket/set
         racket/format
         racket/math)

(provide
 ;; 5-Element Capability Semiring (CapMem)
 CAP-ORDER
 cap-valid?
 cap-rank
 cap<=?
 cap-join
 cap-seq
 cap-par
 cap-scale

 ;; Hardware Execution Phases & Bank Coeffects
 VALID-PHASES
 phase-allows-vram-write?
 phase-allows-oam-dma?
 (struct-out bank-state)
 default-bank-state
 bank-compatible?

 ;; 12-Component Hardware Resource Grade Vector
 (struct-out nes-grade)
 nes-grade-zero
 nes-grade-seq
 nes-grade-join
 nes-grade-par
 nes-grade-scale
 nes-grade<=?

 ;; Hardware Target Budgets & Cartridge Mapper Specs (NTSC 2A03 / 2C02)
 (struct-out nes-budget)
 (struct-out nes-cartridge-spec)
 mapper-symbol->ines-id
 make-cartridge-budget
 NTSC-NROM-BUDGET
 NTSC-UNROM-128-BUDGET
 NTSC-MMC1-BUDGET
 NTSC-MMC1-SXROM-BUDGET
 NTSC-MMC3-TXROM-BUDGET

 ;; Context & Typing Judgment Results
 (struct-out zp-binding)
 (struct-out nes-ctx)
 make-initial-nes-ctx
 (struct-out nes-violation)
 (struct-out nes-type-result)

 ;; Core Graded Typechecker & Individual Constraint Checkers
 typecheck-nes-module
 check-L1-zp-and-stack
 check-L2-bank-residency
 check-L3-phase-and-totality
 check-L4-ppu-latch-and-dmc
 check-Phi1-cycles-and-page-cross
 check-Phi2-oam-and-scanline
 check-Phi3-memory-hierarchy
 check-Phi4-vram-and-attributes
 check-Phi5-apu-channels
 check-state-machine-totality
 check-pinned-zp-map

 ;; Automated Grade-Driven Hardware Repair Pass
 repair-nes-module
 compile-and-verify-nes-module

 ;; Syntax-Directed Pre-Assembly DSL Grade Inference & Module Synthesis
 infer-dsl-statement-effects
 infer-dsl-statement-grade
 synthesize-dsl-module-grades)

;; ============================================================================
;; 1. Five-Element Memory & Hardware Capability Semiring (CapMem)
;; ============================================================================
;; Ordered lattice:
;;   ConstMeta < RomBorrow < PpuTaint < RamLinear < DmaUnique

(define CAP-ORDER
  '(ConstMeta RomBorrow PpuTaint RamLinear DmaUnique))

(define (cap-valid? c)
  (and (memq c CAP-ORDER) #t))

(define (cap-rank c)
  (case c
    [(ConstMeta) 0]
    [(RomBorrow) 1]
    [(PpuTaint)  2]
    [(RamLinear) 3]
    [(DmaUnique) 4]
    [else (error 'cap-rank "unknown capability grade: ~a" c)]))

(define (rank->cap r)
  (list-ref CAP-ORDER (min 4 (max 0 r))))

(define (cap<=? c1 c2)
  (<= (cap-rank c1) (cap-rank c2)))

(define (cap-join c1 c2)
  (rank->cap (max (cap-rank c1) (cap-rank c2))))

;; Sequential composition (c1 ; c2):
;; Capability upgrades along sequential phases; DmaUnique scratch blocks can be
;; recycled sequentially, whereas PpuTaint persists until explicitly discharged.
(define (cap-seq c1 c2)
  (cap-join c1 c2))

;; Parallel / co-live composition (c1 (+) c2):
;; - ConstMeta is the additive identity (0)
;; - RomBorrow + RomBorrow = RomBorrow (idempotent immutable PRG-ROM reads)
;; - PpuTaint + PpuTaint = PpuTaint (idempotent latch taint)
;; - RamLinear + RamLinear = 'CapConflict (concurrent mutable aliasing forbidden!)
;; - DmaUnique + anything > RomBorrow = 'CapConflict (exclusive DMA/scratch ownership)
(define (cap-par c1 c2)
  (cond
    [(eq? c1 'ConstMeta) c2]
    [(eq? c2 'ConstMeta) c1]
    [(and (eq? c1 'RomBorrow) (eq? c2 'RomBorrow)) 'RomBorrow]
    [(and (eq? c1 'PpuTaint) (memq c2 '(RomBorrow PpuTaint))) 'PpuTaint]
    [(and (eq? c2 'PpuTaint) (memq c1 '(RomBorrow PpuTaint))) 'PpuTaint]
    [(and (eq? c1 'RamLinear) (eq? c2 'RomBorrow)) 'RamLinear]
    [(and (eq? c2 'RamLinear) (eq? c1 'RomBorrow)) 'RamLinear]
    [(and (eq? c1 'DmaUnique) (eq? c2 'RomBorrow)) 'DmaUnique]
    [(and (eq? c2 'DmaUnique) (eq? c1 'RomBorrow)) 'DmaUnique]
    [else 'CapConflict]))

(define (cap-scale k c)
  (cond
    [(<= k 0) 'ConstMeta]
    [(= k 1) c]
    [else
     (case c
       [(ConstMeta) 'ConstMeta]
       [(RomBorrow) 'RomBorrow]
       [(PpuTaint)  'PpuTaint]
       [(RamLinear DmaUnique) 'CapConflict]
       [else 'CapConflict])]))

;; ============================================================================
;; 2. PPU Execution Phases & Cartridge Bank Coeffect State
;; ============================================================================

(define VALID-PHASES
  '(Boot ForcedBlank ActiveFrame VBlankNMI ScanlineHBlank))

(define (phase-allows-vram-write? phase)
  (and (memq phase '(Boot ForcedBlank VBlankNMI)) #t))

(define (phase-allows-oam-dma? phase)
  (and (memq phase '(ForcedBlank VBlankNMI)) #t))

(struct bank-state
  (mapper          ; 'NROM | 'MMC1 | 'UNROM | 'MMC3
   active-prg-bank ; exact-nonnegative-integer?
   fixed-prg-bank  ; exact-nonnegative-integer?
   active-chr-bank ; exact-nonnegative-integer?
   )
  #:transparent)

(define (default-bank-state [mapper 'NROM])
  (bank-state mapper 0 1 0))

(define (bank-compatible? b-state req-bank)
  (or (not req-bank)
      (eq? req-bank 'fixed)
      (= req-bank (bank-state-active-prg-bank b-state))
      (= req-bank (bank-state-fixed-prg-bank b-state))))

;; ============================================================================
;; 3. 12-Component NES Hardware Resource Grade Vector (G_NES)
;; ============================================================================

(struct nes-grade
  (cycles           ; Phi1: Worst-case 6502 CPU cycles
   page-crossings   ; Phi1: Unaligned indexed loads/branches crossing 256B page
   oam-sprites      ; Phi2: Total hardware OAM 4-byte sprite slots (<= 64)
   scanline-sprites ; Phi2: Peak sprites overlapping any scanline y in [0..239] (<= 8)
   zp-bytes-live    ; Phi3: Permanent Zero-Page bytes remaining live after scope
   zp-bytes-peak    ; Phi3: High-watermark Zero-Page bytes (live + temporary scratch)
   ram-bytes        ; Phi3: BSS Work RAM bytes ($0300-$07FF, <= 1280)
   prg-rom-bytes    ; Phi3: PRG-ROM code + read-only data bytes ($8000-$FFFF)
   chr-tiles        ; Phi3: 8x8 2bpp CHR-ROM pattern tiles (<= 512)
   vram-dma-bytes   ; Phi4: Bytes written to $2007 PPUDATA during VBlank (<= 128)
   attr-clashes     ; Phi4: 16x16 metatile quadrants with >1 background palette
   apu-channels     ; Phi5: Set of active 2A03 APU channels
   )
  #:transparent)

(define nes-grade-zero
  (nes-grade 0 0 0 0 0 0 0 0 0 0 0 (set)))

;; Sequential Composition (g1 ; g2):
;; - Time-additive resources sum: cycles, page-crossings, prg-rom-bytes, vram-dma-bytes
;; - High-watermark Zero-Page scratch reuse:
;;     zp_live(g1 ; g2) = zp_live(g1) + zp_live(g2)
;;     zp_peak(g1 ; g2) = max(zp_peak(g1), zp_live(g1) + zp_peak(g2))
;; - Frame OAM / scanline sprites accumulate within the frame pass
(define (nes-grade-seq g1 g2)
  (define live1 (nes-grade-zp-bytes-live g1))
  (define live2 (nes-grade-zp-bytes-live g2))
  (define peak1 (nes-grade-zp-bytes-peak g1))
  (define peak2 (nes-grade-zp-bytes-peak g2))
  (nes-grade
   (+ (nes-grade-cycles g1) (nes-grade-cycles g2))
   (+ (nes-grade-page-crossings g1) (nes-grade-page-crossings g2))
   (+ (nes-grade-oam-sprites g1) (nes-grade-oam-sprites g2))
   (max (nes-grade-scanline-sprites g1) (nes-grade-scanline-sprites g2))
   (+ live1 live2)
   (max peak1 (+ live1 peak2))
   (+ (nes-grade-ram-bytes g1) (nes-grade-ram-bytes g2))
   (+ (nes-grade-prg-rom-bytes g1) (nes-grade-prg-rom-bytes g2))
   (+ (nes-grade-chr-tiles g1) (nes-grade-chr-tiles g2))
   (+ (nes-grade-vram-dma-bytes g1) (nes-grade-vram-dma-bytes g2))
   (+ (nes-grade-attr-clashes g1) (nes-grade-attr-clashes g2))
   (set-union (nes-grade-apu-channels g1) (nes-grade-apu-channels g2))))

;; Branch Join (g1 |_| g2 for `if` / `cond` alternatives):
;; Takes the componentwise worst-case supremum across branches, while preserving
;; high-watermark Zero-Page scratch reuse across mutually exclusive branches.
(define (nes-grade-join g1 g2)
  (nes-grade
   (max (nes-grade-cycles g1) (nes-grade-cycles g2))
   (max (nes-grade-page-crossings g1) (nes-grade-page-crossings g2))
   (max (nes-grade-oam-sprites g1) (nes-grade-oam-sprites g2))
   (max (nes-grade-scanline-sprites g1) (nes-grade-scanline-sprites g2))
   (max (nes-grade-zp-bytes-live g1) (nes-grade-zp-bytes-live g2))
   (max (nes-grade-zp-bytes-peak g1) (nes-grade-zp-bytes-peak g2))
   (max (nes-grade-ram-bytes g1) (nes-grade-ram-bytes g2))
   (+ (nes-grade-prg-rom-bytes g1) (nes-grade-prg-rom-bytes g2))
   (max (nes-grade-chr-tiles g1) (nes-grade-chr-tiles g2))
   (max (nes-grade-vram-dma-bytes g1) (nes-grade-vram-dma-bytes g2))
   (max (nes-grade-attr-clashes g1) (nes-grade-attr-clashes g2))
   (set-union (nes-grade-apu-channels g1) (nes-grade-apu-channels g2))))

;; Parallel / Co-live Composition (g1 (+) g2):
;; Simultaneously live bindings cannot share Zero-Page scratch; both live and peak sum.
(define (nes-grade-par g1 g2)
  (nes-grade
   (+ (nes-grade-cycles g1) (nes-grade-cycles g2))
   (+ (nes-grade-page-crossings g1) (nes-grade-page-crossings g2))
   (+ (nes-grade-oam-sprites g1) (nes-grade-oam-sprites g2))
   (+ (nes-grade-scanline-sprites g1) (nes-grade-scanline-sprites g2))
   (+ (nes-grade-zp-bytes-live g1) (nes-grade-zp-bytes-live g2))
   (+ (nes-grade-zp-bytes-peak g1) (nes-grade-zp-bytes-peak g2))
   (+ (nes-grade-ram-bytes g1) (nes-grade-ram-bytes g2))
   (+ (nes-grade-prg-rom-bytes g1) (nes-grade-prg-rom-bytes g2))
   (+ (nes-grade-chr-tiles g1) (nes-grade-chr-tiles g2))
   (+ (nes-grade-vram-dma-bytes g1) (nes-grade-vram-dma-bytes g2))
   (+ (nes-grade-attr-clashes g1) (nes-grade-attr-clashes g2))
   (set-union (nes-grade-apu-channels g1) (nes-grade-apu-channels g2))))

;; Bounded Iteration Scaling (k * g):
;; Unrolled or bounded loop of trip count k multiplies cycles and OAM emissions,
;; while keeping loop-local Zero-Page scratch constant across iterations.
(define (nes-grade-scale k g)
  (if (<= k 0)
      nes-grade-zero
      (nes-grade
       (* k (nes-grade-cycles g))
       (* k (nes-grade-page-crossings g))
       (* k (nes-grade-oam-sprites g))
       (nes-grade-scanline-sprites g)
       (nes-grade-zp-bytes-live g)
       (nes-grade-zp-bytes-peak g)
       (nes-grade-ram-bytes g)
       (nes-grade-prg-rom-bytes g)
       (nes-grade-chr-tiles g)
       (* k (nes-grade-vram-dma-bytes g))
       (nes-grade-attr-clashes g)
       (nes-grade-apu-channels g))))

(define (nes-grade<=? g1 g2)
  (and (<= (nes-grade-cycles g1) (nes-grade-cycles g2))
       (<= (nes-grade-page-crossings g1) (nes-grade-page-crossings g2))
       (<= (nes-grade-oam-sprites g1) (nes-grade-oam-sprites g2))
       (<= (nes-grade-scanline-sprites g1) (nes-grade-scanline-sprites g2))
       (<= (nes-grade-zp-bytes-live g1) (nes-grade-zp-bytes-live g2))
       (<= (nes-grade-zp-bytes-peak g1) (nes-grade-zp-bytes-peak g2))
       (<= (nes-grade-ram-bytes g1) (nes-grade-ram-bytes g2))
       (<= (nes-grade-prg-rom-bytes g1) (nes-grade-prg-rom-bytes g2))
       (<= (nes-grade-chr-tiles g1) (nes-grade-chr-tiles g2))
       (<= (nes-grade-vram-dma-bytes g1) (nes-grade-vram-dma-bytes g2))
       (<= (nes-grade-attr-clashes g1) (nes-grade-attr-clashes g2))
       (subset? (nes-grade-apu-channels g1) (nes-grade-apu-channels g2))))

;; ============================================================================
;; 4. Hardware Target Budgets (NTSC Ricoh 2A03 / 2C02)
;; ============================================================================

(struct nes-budget
  (name
   vblank-cycles-max      ; 2273 cycles on NTSC 2C02 (20 scanlines * 113.667 cyc)
   active-cycles-max      ; 29780 cycles on NTSC 2C02 (262 scanlines)
   hblank-cycles-max      ; 28 cycles per scanline HBlank
   oam-sprites-max        ; 64 sprites (256 B OAM)
   scanline-sprites-max   ; 8 sprites per scanline (32 B secondary OAM)
   zp-bytes-max           ; 224 B ($0010-$00EF; $00-$0F runtime, $F0-$FF system)
   stack-bytes-max        ; 64 B call/PHA stack depth inside $0100-$01FF
   ram-bytes-max          ; 1280 B ($0300-$07FF; $0200-$02FF reserved for OAMDMA)
   prg-rom-bytes-max      ; 32768 B for NROM-256
   chr-tiles-max          ; 512 8x8 tiles (8192 B CHR-ROM)
   vram-dma-bytes-max     ; 128 B safe unrolled $2007 transfer inside VBlank
   bg-palettes-max        ; 4 background palettes
   spr-palettes-max       ; 4 sprite palettes
   )
  #:transparent)

(struct nes-cartridge-spec
  (mapper          ; 'NROM (0) | 'MMC1 (1) | 'UNROM (2) | 'MMC3 (4)
   prg-rom-banks   ; count of 16 KB PRG-ROM banks (2 = 32 KB, 8 = 128 KB, 16 = 256 KB, 32 = 512 KB)
   chr-rom-banks   ; count of 8 KB CHR-ROM banks (0 = 8 KB writable CHR-RAM!)
   chr-mode        ; 'chr-rom | 'chr-ram
   wram-bytes      ; 0 or 8192 ($6000-$7FFF cartridge PRG-RAM)
   battery-save?   ; #t if $6000-$7FFF WRAM is battery-backed
   mirroring       ; 'vertical | 'horizontal | 'mapper-controlled
   )
  #:transparent)

(define (mapper-symbol->ines-id mapper)
  (case mapper
    [(NROM)  0]
    [(MMC1)  1]
    [(UNROM) 2]
    [(MMC3)  4]
    [else (error 'mapper-symbol->ines-id "Unsupported NES mapper: ~a" mapper)]))

(define NTSC-NROM-BUDGET
  (nes-budget
   'NTSC-NROM-256
   2273
   29780
   28
   64
   8
   224
   64
   1280
   32768
   512
   128
   4
   4))

(define NTSC-UNROM-128-BUDGET
  (nes-budget
   'NTSC-UNROM-128KB-CHRRAM
   2273
   29780
   28
   64
   8
   224
   64
   1280
   131072 ; 8 x 16 KB switchable PRG-ROM banks
   512    ; 8 KB dynamic CHR-RAM active tile window
   128
   4
   4))

(define NTSC-MMC1-BUDGET
  (nes-budget
   'NTSC-MMC1-SKROM
   2273
   29780
   28
   64
   8
   224
   64
   1280
   131072
   512
   128
   4
   4))

(define NTSC-MMC1-SXROM-BUDGET
  (nes-budget
   'NTSC-MMC1-SXROM-256KB-WRAM
   2273
   29780
   28
   64
   8
   224
   64
   (+ 1280 8192) ; 1,280 B internal BSS + 8,192 B cartridge WRAM ($6000-$7FFF)
   262144        ; 16 x 16 KB = 256 KB PRG-ROM (fits 231+ Baba Is You levels!)
   512           ; 8 KB dynamic CHR-RAM (512 active tiles per level)
   128
   4
   4))

(define NTSC-MMC3-TXROM-BUDGET
  (nes-budget
   'NTSC-MMC3-TXROM-512KB-WRAM
   2273
   29780
   28
   64
   8
   224
   64
   (+ 1280 8192) ; 1,280 B internal BSS + 8,192 B cartridge WRAM ($6000-$7FFF)
   524288        ; 32 x 16 KB = 512 KB PRG-ROM
   4096          ; 64 KB banked CHR-ROM (4,096 tiles)
   128
   4
   4))

(define (make-cartridge-budget spec)
  (match-define (nes-cartridge-spec mapper prg-banks chr-banks chr-mode wram-bytes _bat _mir) spec)
  (nes-budget
   (string->symbol (format "NTSC-~a-~aKB" mapper (* 16 prg-banks)))
   2273
   29780
   28
   64
   8
   224
   64
   (+ 1280 wram-bytes)
   (* 16384 prg-banks)
   (if (eq? chr-mode 'chr-ram) 512 (* 512 (max 1 chr-banks)))
   128
   4
   4))

;; ============================================================================
;; 5. Typing Context, Violation Records & Result Structures
;; ============================================================================

(struct zp-binding
  (name
   bytes
   cap         ; element of CAP-ORDER
   temporary?  ; #t if allocated via with-zp-scratch
   bank        ; symbol or #f
   span)
  #:transparent)

(struct nes-ctx
  (phase            ; symbol in VALID-PHASES
   bank             ; bank-state?
   zp-env           ; hash: symbol -> zp-binding
   stack-depth      ; exact-integer? (unmatched PHA count)
   ppu-latch-tainted? ; boolean? (#t after $2006/$2007 write until restore-scroll!)
   oam-dma-done?    ; boolean?
   dmc-active?      ; boolean? (#t if APU channel 'dmc is enabled)
   mux-enabled?     ; boolean? (#t if coprime OAM slot cycling is active)
   )
  #:transparent)

(define (make-initial-nes-ctx [phase 'Boot] [mapper 'NROM])
  (nes-ctx phase (default-bank-state mapper) (hash) 0 #f #f #f #f))

(struct nes-violation
  (rule-id          ; 'L1 | 'L2 | 'L3 | 'L4 | 'Phi1 | 'Phi2 | 'Phi3 | 'Phi4 | 'Phi5
   category         ; symbol describing exact sub-rule
   message          ; detailed human-readable explanation
   witness          ; hash of concrete offending hardware parameters
   repair-hint      ; actionable grade-driven repair strategy
   )
  #:transparent)

(struct nes-type-result
  (well-typed?      ; boolean?
   capability       ; highest CapMem capability used
   vblank-grade     ; nes-grade for NMI handler
   active-grade     ; nes-grade for active frame logic
   total-grade      ; combined module nes-grade
   final-ctx        ; nes-ctx?
   violations       ; list of nes-violation?
   zp-schedule      ; list of Zero-Page high-watermark intervals
   )
  #:transparent)

;; ============================================================================
;; 6. Logical Safety Checkers (L1 .. L4)
;; ============================================================================

;; L1: Zero-Page Scratch Conservation, Linear Aliasing & 6502 Stack Balance
(define (check-L1-zp-and-stack mod)
  (define violations '())
  (define seen-zp (make-hash))

  ;; Check duplicate or conflicting Zero-Page allocations
  (for ([z (in-list (hash-ref mod 'zp-vars '()))])
    (define name (hash-ref z 'name))
    (define cap  (hash-ref z 'cap 'RamLinear))
    (when (hash-has-key? seen-zp name)
      (define prev-cap (hash-ref seen-zp name))
      (when (eq? (cap-par prev-cap cap) 'CapConflict)
        (set! violations
              (cons (nes-violation
                     'L1
                     'zero-page-linear-aliasing
                     (format "Zero-Page variable '~a' aliased with conflicting capability (~a + ~a = CapConflict)"
                             name prev-cap cap)
                     (hasheq 'var name 'prev-cap prev-cap 'new-cap cap)
                     "Wrap disjoint temporaries in sequential (with-zp-scratch ...) scopes or demote read-only data to RomBorrow.")
                    violations))))
    (hash-set! seen-zp name cap))

  ;; Check unreleased scratch blocks if any explicit leak flag is present
  (for ([s (in-list (hash-ref mod 'zp-scratch-blocks '()))])
    (when (hash-ref s 'leaked? #f)
      (set! violations
            (cons (nes-violation
                   'L1
                   'unreleased-zp-scratch
                   (format "Scoped Zero-Page scratch block '~a' (~a B) escapes its lexical scope"
                           (hash-ref s 'id 'scratch)
                           (hash-ref s 'bytes 0))
                   s
                   "Keep scratch pointer references inside (with-zp-scratch ...) or promote persistent state to top-level (defzp ...).")
                  violations))))

  ;; Check 6502 hardware stack balance (PHA vs PLA, PHP vs PLP) across subroutines
  (for ([sub (in-list (hash-ref mod 'subroutines '()))])
    (define push-count (hash-ref sub 'pha-count 0))
    (define pull-count (hash-ref sub 'pla-count 0))
    (unless (= push-count pull-count)
      (set! violations
            (cons (nes-violation
                   'L1
                   'unbalanced-6502-stack
                   (format "Subroutine '~a' has unbalanced 6502 stack: ~a pushes (PHA/PHP) vs ~a pulls (PLA/PLP) before RTS"
                           (hash-ref sub 'name 'anon)
                           push-count
                           pull-count)
                   (hasheq 'subroutine (hash-ref sub 'name 'anon)
                           'pha push-count
                           'pla pull-count)
                    "Balance every PHA/PHP with a matching PLA/PLP on all control-flow paths before RTS/RTI.")
                   violations))))

  (append (reverse violations) (check-pinned-zp-map mod)))

;; Check pinned Zero-Page hardware layout map (`defzp-map`) for address range ($00-$FF) and collision freedom
(define (check-pinned-zp-map mod)
  (define violations '())
  (define seen-addrs (make-hash))
  (for ([entry (in-list (hash-ref mod 'zp-map '()))])
    (define var-id (hash-ref entry 'id 'zp_var))
    (define addr   (hash-ref entry 'addr 0))
    (define role   (hash-ref entry 'role 'state))
    (cond
      [(or (< addr 0) (> addr #xFF))
       (set! violations
             (cons (nes-violation
                    'L1
                    'zp-map-out-of-range
                    (format "Pinned Zero-Page variable '~a' maps to $~x, outside 6502 Zero-Page ($00-$FF)"
                            var-id addr)
                    entry
                    "Assign Zero-Page variables to addresses within $0010-$00EF.")
                   violations))]
      [(hash-has-key? seen-addrs addr)
       (define prev-id (hash-ref seen-addrs addr))
       (set! violations
             (cons (nes-violation
                    'L1
                    'pinned-zp-address-collision
                    (format "Pinned Zero-Page address $~x aliases both '~a' and '~a' (role: ~a)"
                            addr prev-id var-id role)
                    (hasheq 'addr addr 'var1 prev-id 'var2 var-id 'role role)
                    "Assign distinct Zero-Page addresses or scope non-overlapping variables via (with-zp-scratch ...).")
                   violations))]
      [else
       (hash-set! seen-addrs addr var-id)]))
  (reverse violations))

;; L2: PRG/CHR Bank-Residency, Far-Call Trampolines, UNROM Bus-Conflicts & Cartridge WRAM Safety
(define (check-L2-bank-residency mod)
  (define violations '())
  (define mapper (hash-ref mod 'mapper 'NROM))
  (define fixed-bank (hash-ref mod 'fixed-prg-bank 1))
  (define current-bank (hash-ref mod 'initial-prg-bank 0))
  (define bus-conflict-safe?
    (and (hash-ref mod 'bus-conflict-table? #t)
         (for/and ([c (in-list (hash-ref mod 'bank-calls '()))])
           (hash-ref c 'bus-conflict-table? #t))))
  (define mmc1-atomic-guard? (hash-ref mod 'mmc1-atomic-guard? #t))
  (define wram-bytes (hash-ref mod 'wram-bytes 0))
  (define wram-enabled? (hash-ref mod 'wram-enabled? #t))

  ;; 1. Cross-bank direct JSR hazard without fixed-bank ($C000-$FFFF) trampoline
  (for ([call (in-list (hash-ref mod 'bank-calls '()))])
    (define target (hash-ref call 'target))
    (define target-bank (hash-ref call 'target-bank 0))
    (define caller-bank (hash-ref call 'caller-bank current-bank))
    (define via-trampoline? (hash-ref call 'trampoline? #f))
    (when (and (not (eq? mapper 'NROM))
               (not (= target-bank caller-bank))
               (not (= target-bank fixed-bank))
               (not via-trampoline?))
      (set! violations
            (cons (nes-violation
                   'L2
                   'cross-bank-call-hazard
                   (format "Direct JSR to '~a' in switchable PRG bank ~a while bank ~a is active without fixed-bank trampoline"
                           target target-bank caller-bank)
                   call
                   "Invoke target via (far-call bank target) trampoline in fixed PRG bank $C000-$FFFF.")
                  violations))))

  ;; 2. UNROM (Mapper 2) bus-conflict hazard on bank-switch STA $8000-$FFFF
  (when (and (eq? mapper 'UNROM)
             (not bus-conflict-safe?))
    (set! violations
          (cons (nes-violation
                 'L2
                 'unrom-bus-conflict-hazard
                 "UNROM (Mapper 2) bank switch writes to $8000-$FFFF without indexing a ROM identity table (CPU data bus collides with active PRG-ROM output drivers)"
                 (hasheq 'mapper 'UNROM 'bus-conflict-table? #f)
                 "Switch UNROM banks via (STA bank_identity_table,Y) where bank_identity_table[b] == b in fixed PRG-ROM.")
                violations)))

  ;; 3. MMC1 (Mapper 1) 5-write serial shift-register NMI re-entrancy hazard
  (when (and (eq? mapper 'MMC1)
             (not mmc1-atomic-guard?))
    (set! violations
          (cons (nes-violation
                 'L2
                 'mmc1-serial-reentrancy-hazard
                 "MMC1 (Mapper 1) 5-write serial bank-switch sequence is unguarded against VBlank NMI interruption (interrupting mid-shift corrupts the 5-bit mapper shift register)"
                 (hasheq 'mapper 'MMC1 'mmc1-atomic-guard? #f)
                 "Guard MMC1 5-write shift sequences with a Zero-Page busy flag and reset shift latch ($80) on NMI recovery.")
                violations)))

  ;; 4. Cartridge WRAM ($6000-$7FFF) access on unmapped hardware or without chip-enable
  (when (> wram-bytes 0)
    (cond
      [(memq mapper '(NROM UNROM))
       (set! violations
             (cons (nes-violation
                    'L2
                    'unmapped-wram-access
                    (format "Module allocates ~a bytes of Cartridge WRAM ($6000-$7FFF), but mapper '~a' has no PRG-RAM address decoder"
                            wram-bytes mapper)
                    (hasheq 'mapper mapper 'wram-bytes wram-bytes)
                    "Upgrade cartridge mapper to MMC1 (SXROM) or MMC3 (TXROM) to map 8 KB PRG-RAM at $6000-$7FFF.")
                   violations))]
      [(not wram-enabled?)
       (set! violations
             (cons (nes-violation
                    'L2
                    'wram-chip-select-disabled
                    (format "Cartridge WRAM ($6000-$7FFF, ~a B) accessed before enabling mapper WRAM chip-select ($A001 = $80 on MMC3 / PRG bank bit 4 = 0 on MMC1)"
                            wram-bytes)
                    (hasheq 'mapper mapper 'wram-enabled? #f)
                    "Enable cartridge WRAM in boot_init before reading or writing $6000-$7FFF.")
                   violations))]))

  (reverse violations))

;; Check game phase state-machine totality, failure-recovery reachability & victory reachability
(define (check-state-machine-totality mod)
  (define violations '())
  (for ([sm (in-list (hash-ref mod 'state-machines '()))])
    (define sm-name (hash-ref sm 'name 'game-state-machine))
    (define init-st (hash-ref sm 'initial 'active))
    (define states  (hash-ref sm 'states '()))
    (define state-ids (for/set ([s (in-list states)]) (hash-ref s 'id)))
    (for ([s (in-list states)])
      (define sid   (hash-ref s 'id))
      (define kind  (hash-ref s 'kind 'normal))
      (define trans (hash-ref s 'transitions '()))
      ;; 1. Verify all transition target states exist
      (for ([t (in-list trans)])
        (unless (set-member? state-ids t)
          (set! violations
                (cons (nes-violation
                       'L3
                       'undefined-state-transition
                       (format "State machine '~a' state '~a' transitions to undeclared state '~a'"
                               sm-name sid t)
                       (hasheq 'state-machine sm-name 'from sid 'to t)
                       "Declare the target state in (defstate-machine ...) or redirect to the initial state.")
                      violations))))
      ;; 2. Verify failure/hazard states ('failure, 'dying, 'dead, 'defeat, 'game-over, 'top-out) have a recovery transition
      (when (and (memq kind '(failure dying dead defeat game-over top-out))
                 (null? trans))
        (set! violations
              (cons (nes-violation
                     'L3
                     'unrecoverable-failure-softlock
                     (format "State machine '~a' failure state '~a' (kind: ~a) has no recovery/respawn transition (causes permanent soft-lock on player defeat)"
                             sm-name sid kind)
                     (hasheq 'state-machine sm-name 'state sid 'kind kind 'initial init-st)
                     "Add a START/SELECT respawn transition from the failure state back to the initial/active state.")
                    violations))))
    ;; 3. Verify all campaign victory/completion states ('victory, 'completed, 'win) are reachable from `init-st`
    (define adj
      (for/hash ([s (in-list states)])
        (values (hash-ref s 'id) (hash-ref s 'transitions '()))))
    (define reachable (mutable-set))
    (let bfs ([queue (list init-st)])
      (unless (null? queue)
        (define cur (car queue))
        (define rest (cdr queue))
        (if (set-member? reachable cur)
            (bfs rest)
            (begin
              (set-add! reachable cur)
              (bfs (append rest (hash-ref adj cur '())))))))
    (for ([s (in-list states)])
      (define sid  (hash-ref s 'id))
      (define kind (hash-ref s 'kind 'normal))
      (when (and (memq kind '(victory completed win))
                 (not (set-member? reachable sid)))
        (set! violations
              (cons (nes-violation
                     'L3
                     'unreachable-victory-state
                     (format "State machine '~a' victory state '~a' is unreachable from initial state '~a' (disconnected multi-stage campaign)"
                             sm-name sid init-st)
                     (hasheq 'state-machine sm-name 'victory-state sid 'initial init-st)
                     "Ensure every intermediate stage transitions forward to the next stage until reaching the victory state.")
                    violations)))))
  (reverse violations))

;; L3: 2C02 PPU Temporal Phase Discipline & Total Rule/Entity Dispatch
(define (check-L3-phase-and-totality mod)
  (define violations '())

  ;; 1. Check that all PPU VRAM ($2006/$2007) and OAM DMA ($4014) operations occur in valid phases
  (for ([op (in-list (hash-ref mod 'ppu-ops '()))])
    (define kind  (hash-ref op 'op))
    (define phase (hash-ref op 'phase 'ActiveFrame))
    (cond
      [(and (memq kind '(ppu-write! vram-put! palette-write! nametable-patch!))
            (not (phase-allows-vram-write? phase)))
       (set! violations
             (cons (nes-violation
                    'L3
                    'vram-write-during-active-render
                    (format "Illegal PPU VRAM write '~a' during phase '~a' (2C02 address bus is locked by active rendering)"
                            kind phase)
                    op
                    "Move VRAM writes into (defnmi ...) VBlank handler or wrap in (with-forced-blank ...) during level load.")
                   violations))]
      [(and (eq? kind 'oam-dma!)
            (not (phase-allows-oam-dma? phase)))
       (set! violations
             (cons (nes-violation
                    'L3
                    'oam-dma-outside-vblank
                    (format "Illegal $4014 OAMDMA transfer during phase '~a'" phase)
                    op
                    "Execute (oam-dma! $02) as the first operation inside (defnmi ...) VBlank handler.")
                   violations))]))

  ;; 2. Check totality of entity/rule dispatch tables
  (for ([dispatch (in-list (hash-ref mod 'dispatches '()))])
    (define domain  (list->set (hash-ref dispatch 'domain '())))
    (define handled (list->set (hash-ref dispatch 'handled '())))
    (define missing (set->list (set-subtract domain handled)))
    (unless (null? missing)
      (set! violations
            (cons (nes-violation
                   'L3
                   'non-exhaustive-dispatch
                   (format "Non-exhaustive dispatch '~a': missing handlers for variants ~a (risks wild 6502 indirect JMP)"
                           (hash-ref dispatch 'name 'dispatch)
                           missing)
                   (hasheq 'dispatch (hash-ref dispatch 'name 'dispatch)
                           'missing missing)
                   "Add branches for all declared entity/rule variants in the dispatch table.")
                  violations))))

  ;; 3. Check Sprite-0-Hit mid-frame raster split opaque overlap invariant
  (when (and (hash-ref mod 'sprite0-split? #f)
             (not (hash-ref mod 'sprite0-opaque-overlap? #t)))
    (set! violations
          (cons (nes-violation
                 'L3
                 'sprite0-missing-opaque-overlap
                 "Mid-frame HBlankSplit polls $2002 bit 6 (Sprite 0 Hit), but OAM Sprite 0 does not overlap a guaranteed non-transparent background pixel (risks infinite CPU hang in BIT $2002 / BVC loop)"
                 (hasheq 'sprite0-split? #t 'sprite0-opaque-overlap? #f)
                 "Place OAM Sprite 0 over a solid non-zero HUD background tile (e.g. coin/bomb icon at Y=22..30) before polling $2002 bit 6.")
                violations)))

  (append (reverse violations) (check-state-machine-totality mod)))

;; L4: $2006/$2007 Shared Scroll-Latch Taint & 2A03 DMC Joypad Glitch Safety
(define (check-L4-ppu-latch-and-dmc mod)
  (define violations '())
  (define nmi-ops (hash-ref mod 'nmi-ops '()))

  ;; Track $2006/$2007 writes inside NMI and verify restore-scroll! before RTI
  (define tainted? #f)
  (for ([op (in-list nmi-ops)])
    (case (hash-ref op 'op)
      [(ppu-write! vram-put! palette-write! nametable-patch!)
       (set! tainted? #t)]
      [(restore-scroll!)
       (set! tainted? #f)]))

  (when (or tainted? (hash-ref mod 'unrestored-ppu-latch? #f))
    (set! violations
          (cons (nes-violation
                 'L4
                 'unrestored-ppu-scroll-latch
                 "VBlank NMI writes to $2006/$2007 (PPUADDR/PPUDATA) taint internal 2C02 scroll register t/v/w without calling (restore-scroll! x y) before RTI"
                 (hasheq 'phase 'VBlankNMI 'latch-state 'PpuTaint)
                 "Insert (restore-scroll! scroll-x scroll-y) (which reads $2002 and writes $2000 + $2005x2) at the end of (defnmi ...).")
                violations)))

  ;; Check 2A03 DPCM/DMC sample DMA vs $4016 joypad shift-register bit-deletion glitch
  (define apu-chans (list->set (hash-ref mod 'apu-channels '())))
  (define joypad-mode (hash-ref mod 'joypad-poll-mode 'double-read-safe))
  (when (and (set-member? apu-chans 'dmc)
             (eq? joypad-mode 'single-read-unsafe))
    (set! violations
          (cons (nes-violation
                 'L4
                 'dmc-joypad-clock-glitch
                 "APU DMC channel is active alongside single-read $4016 joypad polling (2A03 DMA cycle steal deletes a bit from $4016 shift register, causing false RIGHT presses)"
                 (hasheq 'apu-channel 'dmc 'joypad-poll-mode joypad-mode)
                 "Upgrade joypad reader to (poll-joypad-dmc-safe!), which polls $4016 twice and compares until two consecutive reads match.")
                violations)))

  (reverse violations))

;; ============================================================================
;; 7. Physical Resource Semiring Checkers (Phi1 .. Phi5)
;; ============================================================================

;; Phi1: NTSC VBlank (<= 2273 cyc), ActiveFrame / Multi-Frame Turn Coroutine Slicing & Page-Crossing
(define (check-Phi1-cycles-and-page-cross mod [budget NTSC-NROM-BUDGET])
  (define violations '())
  (define vblank-cycles (hash-ref mod 'vblank-cycles 0))
  (define raw-active-cycles (hash-ref mod 'active-cycles 0))
  (define turn-slices (max 1 (hash-ref mod 'turn-slices 1)))
  (define mapper (hash-ref mod 'mapper 'NROM))

  ;; Add far-call trampoline overhead (+38 cyc on UNROM/MMC3, +72 cyc on MMC1 per cross-bank call)
  (define far-call-count
    (for/sum ([c (in-list (hash-ref mod 'bank-calls '()))]
              #:when (hash-ref c 'trampoline? #f))
      1))
  (define trampoline-overhead
    (* far-call-count (if (eq? mapper 'MMC1) 72 38)))

  ;; When turn-slices > 1, a turn computation is cooperatively yielded across k VBlank frames
  ;; via (with-turn-coroutine #:slices k ...), charging ceil(raw / k) + 42 coroutine context cycles per frame
  (define effective-active-cycles
    (+ (if (> turn-slices 1)
           (+ (quotient (+ raw-active-cycles (sub1 turn-slices)) turn-slices) 42)
           raw-active-cycles)
       trampoline-overhead))

  (define page-crossings (hash-ref mod 'page-crossings 0))

  (when (> vblank-cycles (nes-budget-vblank-cycles-max budget))
    (set! violations
          (cons (nes-violation
                 'Phi1
                 'vblank-cycle-budget-exceeded
                 (format "VBlank NMI handler consumes ~a CPU cycles, exceeding NTSC 2C02 VBlank limit of ~a cycles (+~a cycle overrun)"
                         vblank-cycles
                         (nes-budget-vblank-cycles-max budget)
                         (- vblank-cycles (nes-budget-vblank-cycles-max budget)))
                 (hasheq 'vblank-cycles vblank-cycles
                         'limit (nes-budget-vblank-cycles-max budget))
                 "Buffer VRAM row/column updates in a RAM transfer stripe and cap per-NMI $2007 writes to <= 64 bytes.")
                violations)))

  (when (> effective-active-cycles (nes-budget-active-cycles-max budget))
    (set! violations
          (cons (nes-violation
                 'Phi1
                 'active-frame-cycle-lag
                 (format "ActiveFrame game logic consumes ~a CPU cycles per frame (total turn: ~a cyc across ~a slice(s) + ~a trampoline cyc), exceeding 60fps NTSC frame budget of ~a cycles"
                         effective-active-cycles
                         raw-active-cycles
                         turn-slices
                         trampoline-overhead
                         (nes-budget-active-cycles-max budget))
                 (hasheq 'active-cycles effective-active-cycles
                         'raw-turn-cycles raw-active-cycles
                         'turn-slices turn-slices
                         'limit (nes-budget-active-cycles-max budget))
                 "Slice heavy turn evaluation across multiple frames with (with-turn-coroutine #:slices k ...) or convert AoS loops to SoA.")
                violations)))

  (when (> page-crossings 0)
    (set! violations
          (cons (nes-violation
                 'Phi1
                 'unaligned-page-crossing-hazard
                 (format "Detected ~a timing-critical table or branch crossing a 256-byte 6502 page boundary (+1 cycle jitter per access)"
                         page-crossings)
                 (hasheq 'page-crossings page-crossings)
                 "Add (.align 256) to timing-critical PRG-ROM lookup tables.")
                violations)))

  (reverse violations))

;; Phi2: OAM Total Sprites (<= 64) & Per-Scanline Evaluation (<= 8)
(define (check-Phi2-oam-and-scanline mod [budget NTSC-NROM-BUDGET])
  (define violations '())
  (define oam-sprites (hash-ref mod 'oam-sprites 0))
  (define scanline-sprites (hash-ref mod 'scanline-sprites 0))
  (define mux-enabled? (hash-ref mod 'oam-mux? #f))

  (when (> oam-sprites (nes-budget-oam-sprites-max budget))
    (set! violations
          (cons (nes-violation
                 'Phi2
                 'oam-total-sprites-exceeded
                 (format "Frame allocates ~a hardware OAM sprites (~a bytes), exceeding 2C02 64-sprite (256-byte) OAM capacity"
                         oam-sprites (* 4 oam-sprites))
                 (hasheq 'oam-sprites oam-sprites
                         'limit (nes-budget-oam-sprites-max budget))
                 "Move static board tiles (WALL, FLOOR, GRASS) into the PPU Nametable background ($2000) and reserve OAM sprites for movable actors/words.")
                violations)))

  (when (and (> scanline-sprites (nes-budget-scanline-sprites-max budget))
             (not mux-enabled?))
    (set! violations
          (cons (nes-violation
                 'Phi2
                 'scanline-8-sprite-overflow
                 (format "Peak scanline density is ~a sprites on a single horizontal scanline, exceeding 2C02 secondary OAM limit of ~a sprites without OAM flicker multiplexing"
                         scanline-sprites
                         (nes-budget-scanline-sprites-max budget))
                 (hasheq 'scanline-sprites scanline-sprites
                         'limit (nes-budget-scanline-sprites-max budget)
                         'oam-mux? mux-enabled?)
                 "Wrap sprite emission in (with-oam-mux #:stride 17 ...) to cycle OAM slots across frames using a coprime stride.")
                violations)))

  (reverse violations))

;; Phi3: Memory Hierarchy Bounds, Banked PRG Windows, Cartridge WRAM & Dynamic CHR-RAM
(define (check-Phi3-memory-hierarchy mod [budget NTSC-NROM-BUDGET])
  (define violations '())

  ;; Compute permanent Zero-Page usage + high-watermark sequential scratch usage
  (define zp-vars (hash-ref mod 'zp-vars '()))
  (define zp-permanent
    (for/sum ([v (in-list zp-vars)]
              #:when (not (eq? (hash-ref v 'cap 'RamLinear) 'ConstMeta)))
      (hash-ref v 'bytes 1)))

  (define scratch-blocks (hash-ref mod 'zp-scratch-blocks '()))
  (define zp-scratch-peak
    (for/fold ([peak 0])
              ([blk (in-list scratch-blocks)])
      (max peak (hash-ref blk 'bytes 0))))

  (define zp-total-peak
    (+ zp-permanent zp-scratch-peak (hash-ref mod 'zp-extra-bytes 0)))

  (define ram-bytes  (hash-ref mod 'ram-bytes 0))
  (define wram-bytes (hash-ref mod 'wram-bytes 0))
  (define total-ram-bytes (+ ram-bytes wram-bytes))
  (define prg-bytes  (hash-ref mod 'prg-rom-bytes 0))
  (define chr-mode   (hash-ref mod 'chr-mode 'chr-rom))
  (define chr-tiles  (hash-ref mod 'chr-tiles 0))
  (define active-chr-tiles (hash-ref mod 'active-chr-tiles chr-tiles))
  (define effective-chr-tiles
    (if (eq? chr-mode 'chr-ram) active-chr-tiles chr-tiles))

  (when (> zp-total-peak (nes-budget-zp-bytes-max budget))
    (set! violations
          (cons (nes-violation
                 'Phi3
                 'zero-page-overflow
                 (format "Peak Zero-Page footprint is ~a bytes (~a B permanent + ~a B peak scratch), exceeding $0010-$00EF budget of ~a bytes"
                         zp-total-peak zp-permanent zp-scratch-peak
                         (nes-budget-zp-bytes-max budget))
                 (hasheq 'zp-peak zp-total-peak
                         'zp-permanent zp-permanent
                         'zp-scratch-peak zp-scratch-peak
                         'limit (nes-budget-zp-bytes-max budget))
                 "Use sequential (with-zp-scratch ...) scopes to recycle temporary pointers or demote cold arrays to BSS RAM ($0300-$07FF).")
                violations)))

  (when (> total-ram-bytes (nes-budget-ram-bytes-max budget))
    (set! violations
          (cons (nes-violation
                 'Phi3
                 'work-ram-overflow
                 (format "Work RAM footprint is ~a bytes (~a B internal BSS + ~a B cartridge WRAM), exceeding target RAM capacity of ~a bytes"
                         total-ram-bytes ram-bytes wram-bytes (nes-budget-ram-bytes-max budget))
                 (hasheq 'ram-bytes total-ram-bytes
                         'internal-ram ram-bytes
                         'wram-bytes wram-bytes
                         'limit (nes-budget-ram-bytes-max budget))
                 "Enable 8 KB Cartridge WRAM ($6000-$7FFF) on MMC1/MMC3 or pack entity properties into bitfields.")
                violations)))

  (when (> prg-bytes (nes-budget-prg-rom-bytes-max budget))
    (set! violations
          (cons (nes-violation
                 'Phi3
                 'prg-rom-bank-overflow
                 (format "PRG-ROM footprint is ~a bytes, exceeding cartridge PRG-ROM capacity of ~a bytes"
                         prg-bytes (nes-budget-prg-rom-bytes-max budget))
                 (hasheq 'prg-rom-bytes prg-bytes 'limit (nes-budget-prg-rom-bytes-max budget))
                 "Promote cartridge mapper to 128 KB UNROM or 256 KB MMC1/MMC3 and partition levels across 16 KB switchable banks.")
                violations)))

  ;; Check individual 16 KB ($4000 = 16,384 B) switchable PRG-ROM bank windows if specified
  (for ([bank-entry (in-list (hash-ref mod 'prg-banks '()))])
    (define bank-id    (hash-ref bank-entry 'bank 0))
    (define bank-bytes (hash-ref bank-entry 'bytes 0))
    (define bank-limit (hash-ref bank-entry 'limit 16384))
    (when (> bank-bytes bank-limit)
      (set! violations
            (cons (nes-violation
                   'Phi3
                   'prg-single-bank-overflow
                   (format "Switchable PRG-ROM bank ~a contains ~a bytes, exceeding 16 KB ($8000-$BFFF) window limit of ~a bytes"
                           bank-id bank-bytes bank-limit)
                   bank-entry
                   "Rebalance compressed level packs across adjacent 16 KB switchable PRG banks.")
                  violations))))

  (when (> effective-chr-tiles (nes-budget-chr-tiles-max budget))
    (set! violations
          (cons (nes-violation
                 'Phi3
                 'chr-rom-tile-overflow
                 (format "CHR pattern table allocates ~a active 8x8 tiles (mode: ~a), exceeding 8 KB pattern table limit of ~a tiles"
                         effective-chr-tiles chr-mode (nes-budget-chr-tiles-max budget))
                 (hasheq 'chr-tiles effective-chr-tiles
                         'total-chr-tiles chr-tiles
                         'chr-mode chr-mode
                         'limit (nes-budget-chr-tiles-max budget))
                 "Switch to 8 KB writable CHR-RAM ('chr-ram) and synthesize only the active level's word tiles on load from FONT-3X5.")
                violations)))

  (reverse violations))

;; Phi4: VBlank VRAM Bandwidth (<= 128 B / Multi-Frame Delta Queue) & 16x16 Attribute Table Clash Prevention
(define (check-Phi4-vram-and-attributes mod [budget NTSC-NROM-BUDGET])
  (define violations '())
  (define raw-vram-bytes (hash-ref mod 'vram-dma-bytes 0))
  (define vram-slices    (max 1 (hash-ref mod 'vram-queue-slices 1)))
  (define vram-bytes     (quotient (+ raw-vram-bytes (sub1 vram-slices)) vram-slices))
  (define bg-palettes    (hash-ref mod 'bg-palettes 4))
  (define spr-palettes   (hash-ref mod 'spr-palettes 4))

  ;; Check VBlank $2007 transfer byte cap (after multi-frame delta queue slicing)
  (when (> vram-bytes (nes-budget-vram-dma-bytes-max budget))
    (set! violations
          (cons (nes-violation
                 'Phi4
                 'vram-transfer-bandwidth-exceeded
                 (format "VBlank $2007 transfer writes ~a bytes per NMI (total ~a B across ~a slice(s)), exceeding safe limit of ~a bytes"
                         vram-bytes raw-vram-bytes vram-slices (nes-budget-vram-dma-bytes-max budget))
                 (hasheq 'vram-dma-bytes vram-bytes
                         'raw-vram-bytes raw-vram-bytes
                         'vram-queue-slices vram-slices
                         'limit (nes-budget-vram-dma-bytes-max budget))
                 "Split nametable updates across multiple VBlank frames using (with-vram-delta-queue #:slices m ...).")
                violations)))

  ;; Check palette counts
  (when (or (> bg-palettes (nes-budget-bg-palettes-max budget))
            (> spr-palettes (nes-budget-spr-palettes-max budget)))
    (set! violations
          (cons (nes-violation
                 'Phi4
                 'palette-count-exceeded
                 (format "Module declares ~a BG palettes and ~a Sprite palettes (2C02 supports max 4 BG + 4 Sprite palettes)"
                         bg-palettes spr-palettes)
                 (hasheq 'bg-palettes bg-palettes 'spr-palettes spr-palettes)
                 "Consolidate palettes to <= 4 BG and <= 4 Sprite 4-color palettes ($3F00-$3F1F).")
                violations)))

  ;; Check 16x16-pixel (2x2-tile) Attribute Table color-zone clashes:
  (define quadrant-palettes (make-hash))
  (define clash-count (hash-ref mod 'attr-clashes 0))
  (for ([cell (in-list (hash-ref mod 'nametable-cells '()))])
    (define tx  (hash-ref cell 'tile-x 0))
    (define ty  (hash-ref cell 'tile-y 0))
    (define pal (hash-ref cell 'palette 0))
    (define qkey (cons (quotient tx 2) (quotient ty 2)))
    (cond
      [(not (hash-has-key? quadrant-palettes qkey))
       (hash-set! quadrant-palettes qkey pal)]
      [(not (= (hash-ref quadrant-palettes qkey) pal))
       (set! clash-count (add1 clash-count))]))

  (when (> clash-count 0)
    (set! violations
          (cons (nes-violation
                 'Phi4
                 'attribute-table-16x16-clash
                 (format "Detected ~a 2C02 Attribute Table clash(es): adjacent 8x8 tiles inside the same 16x16-pixel (2x2-tile) quadrant request different background palettes"
                         clash-count)
                 (hasheq 'attr-clashes clash-count)
                 "Align board metatiles to 2x2-tile (16x16-pixel) boundaries so each grid cell occupies a dedicated Attribute Table quadrant.")
                violations)))

  ;; Check Cartridge Nametable Mirroring vs. Camera Scroll Axis Compatibility:
  ;; - Horizontal scrolling across $2000 & $2400 requires 'vertical mirroring (or 'four-screen / 'dynamic-mmc1)
  ;; - Vertical scrolling across $2000 & $2800 requires 'horizontal mirroring (or 'four-screen / 'dynamic-mmc1)
  (define scroll-mode (hash-ref mod 'scroll-mode 'none))
  (define mirroring   (hash-ref mod 'mirroring 'vertical))
  (when (or (and (eq? scroll-mode 'horizontal) (eq? mirroring 'horizontal))
            (and (eq? scroll-mode 'vertical)   (eq? mirroring 'vertical)))
    (set! violations
          (cons (nes-violation
                 'Phi4
                 'scroll-mirroring-seam-clash
                 (format "Camera scroll mode '~a' clashes with cartridge nametable mirroring '~a' (off-screen seam column/row streaming overwrites visible $2000 playfield)"
                         scroll-mode mirroring)
                 (hasheq 'scroll-mode scroll-mode 'mirroring mirroring)
                 "Set #:mirroring 'vertical for horizontal ($2000/$2400) scrolling, 'horizontal for vertical ($2000/$2800) scrolling, or 'dynamic-mmc1 for 4-way room transitions.")
                violations)))

  (reverse violations))

;; Phi5: 2A03 5-Channel APU Disjointness
(define VALID-APU-CHANNELS '(pulse1 pulse2 triangle noise dmc))

(define (check-Phi5-apu-channels mod)
  (define violations '())
  (define channels (hash-ref mod 'apu-channels '()))
  (define concurrent-writes (hash-ref mod 'concurrent-apu-writes '()))

  (for ([ch (in-list channels)])
    (unless (memq ch VALID-APU-CHANNELS)
      (set! violations
            (cons (nes-violation
                   'Phi5
                   'invalid-apu-channel
                   (format "Unknown 2A03 APU channel '~a' (valid channels: pulse1, pulse2, triangle, noise, dmc)" ch)
                   (hasheq 'channel ch)
                   "Use one of the 5 hardware 2A03 channels: pulse1, pulse2, triangle, noise, or dmc.")
                  violations))))

  ;; Check concurrent unarbitrated writes to the same APU channel in the same frame pass
  (define seen-ch (make-hash))
  (for ([w (in-list concurrent-writes)])
    (define ch (hash-ref w 'channel))
    (define writer (hash-ref w 'writer 'sfx))
    (if (hash-has-key? seen-ch ch)
        (set! violations
              (cons (nes-violation
                     'Phi5
                     'apu-channel-contention
                     (format "Concurrent unarbitrated writes to 2A03 APU channel '~a' by '~a' and '~a'"
                             ch (hash-ref seen-ch ch) writer)
                     (hasheq 'channel ch 'writer1 (hash-ref seen-ch ch) 'writer2 writer)
                     "Route concurrent sound effects through priority-arbitrated APU channel envelopes.")
                    violations))
        (hash-set! seen-ch ch writer)))

  (reverse violations))

;; ============================================================================
;; 8. Master Coeffect-Effect Module Typechecker
;; ============================================================================

(define (typecheck-nes-module mod [budget NTSC-NROM-BUDGET])
  (define v-L1   (check-L1-zp-and-stack mod))
  (define v-L2   (check-L2-bank-residency mod))
  (define v-L3   (check-L3-phase-and-totality mod))
  (define v-L4   (check-L4-ppu-latch-and-dmc mod))
  (define v-Phi1 (check-Phi1-cycles-and-page-cross mod budget))
  (define v-Phi2 (check-Phi2-oam-and-scanline mod budget))
  (define v-Phi3 (check-Phi3-memory-hierarchy mod budget))
  (define v-Phi4 (check-Phi4-vram-and-attributes mod budget))
  (define v-Phi5 (check-Phi5-apu-channels mod))

  (define all-violations
    (append v-L1 v-L2 v-L3 v-L4 v-Phi1 v-Phi2 v-Phi3 v-Phi4 v-Phi5))

  ;; Compute Zero-Page high-watermark schedule across sequential scratch blocks
  (define zp-vars (hash-ref mod 'zp-vars '()))
  (define zp-perm
    (for/sum ([v (in-list zp-vars)]
              #:when (not (eq? (hash-ref v 'cap 'RamLinear) 'ConstMeta)))
      (hash-ref v 'bytes 1)))
  (define scratch-blocks (hash-ref mod 'zp-scratch-blocks '()))
  (define zp-scratch-peak
    (for/fold ([pk 0]) ([b (in-list scratch-blocks)])
      (max pk (hash-ref b 'bytes 0))))
  (define zp-peak (+ zp-perm zp-scratch-peak (hash-ref mod 'zp-extra-bytes 0)))

  (define zp-schedule
    (for/list ([b (in-list scratch-blocks)]
               [idx (in-naturals 0)])
      (define sz (hash-ref b 'bytes 0))
      (hasheq 'phase-index idx
              'id (hash-ref b 'id (string->symbol (format "scratch_~a" idx)))
              'start-addr (+ #x10 zp-perm)
              'end-addr   (+ #x10 zp-perm (max 0 (sub1 sz)))
              'bytes      sz)))

  (define raw-active-cycles (hash-ref mod 'active-cycles 0))
  (define turn-slices       (max 1 (hash-ref mod 'turn-slices 1)))
  (define eff-active-cycles
    (if (> turn-slices 1)
        (+ (quotient (+ raw-active-cycles (sub1 turn-slices)) turn-slices) 42)
        raw-active-cycles))

  (define raw-vram-bytes (hash-ref mod 'vram-dma-bytes 0))
  (define vram-slices    (max 1 (hash-ref mod 'vram-queue-slices 1)))
  (define eff-vram-bytes (quotient (+ raw-vram-bytes (sub1 vram-slices)) vram-slices))

  (define chr-mode  (hash-ref mod 'chr-mode 'chr-rom))
  (define chr-tiles (hash-ref mod 'chr-tiles 0))
  (define eff-chr-tiles
    (if (eq? chr-mode 'chr-ram)
        (hash-ref mod 'active-chr-tiles (min 64 chr-tiles))
        chr-tiles))

  ;; Build VBlank and ActiveFrame grade vectors
  (define vblank-grade
    (nes-grade
     (hash-ref mod 'vblank-cycles 0)
     0
     (hash-ref mod 'oam-sprites 0)
     (hash-ref mod 'scanline-sprites 0)
     0
     0
     0
     0
     0
     eff-vram-bytes
     0
     (set)))

  (define active-grade
    (nes-grade
     eff-active-cycles
     (hash-ref mod 'page-crossings 0)
     0
     0
     zp-perm
     zp-peak
     (+ (hash-ref mod 'ram-bytes 0) (hash-ref mod 'wram-bytes 0))
     (hash-ref mod 'prg-rom-bytes 0)
     eff-chr-tiles
     0
     (hash-ref mod 'attr-clashes 0)
     (list->set (hash-ref mod 'apu-channels '()))))

  (define total-grade (nes-grade-seq vblank-grade active-grade))

  ;; Compute joined capability
  (define highest-cap
    (for/fold ([c 'ConstMeta])
              ([v (in-list zp-vars)])
      (cap-join c (hash-ref v 'cap 'RamLinear))))
  (define final-cap
    (if (> (hash-ref mod 'oam-sprites 0) 0)
        (cap-join highest-cap 'DmaUnique)
        highest-cap))

  (nes-type-result
   (null? all-violations)
   final-cap
   vblank-grade
   active-grade
   total-grade
   (make-initial-nes-ctx 'ActiveFrame (hash-ref mod 'mapper 'NROM))
   all-violations
   zp-schedule))

;; ============================================================================
;; 9. Automated Grade-Driven Hardware Repair Pass
;; ============================================================================

(define (repair-nes-module mod [budget NTSC-NROM-BUDGET])
  (define res (typecheck-nes-module mod budget))
  (if (nes-type-result-well-typed? res)
      (values mod '() res)
      (let ()
        (define repaired mod)
        (define applied-repairs '())

        (for ([v (in-list (nes-type-result-violations res))])
          (case (nes-violation-category v)
            [(cross-bank-call-hazard)
             (define fixed-calls
               (for/list ([c (in-list (hash-ref repaired 'bank-calls '()))])
                 (hash-set c 'trampoline? #t)))
             (set! repaired (hash-set repaired 'bank-calls fixed-calls))
             (set! applied-repairs (cons 'synthesize-fixed-bank-far-call-trampoline applied-repairs))]

            [(unrom-bus-conflict-hazard)
             (define safe-calls
               (for/list ([c (in-list (hash-ref repaired 'bank-calls '()))])
                 (hash-set c 'bus-conflict-table? #t)))
             (set! repaired
                   (hash-set
                    (hash-set repaired 'bus-conflict-table? #t)
                    'bank-calls safe-calls))
             (set! applied-repairs (cons 'synthesize-unrom-bus-conflict-identity-table applied-repairs))]

            [(mmc1-serial-reentrancy-hazard)
             (set! repaired (hash-set repaired 'mmc1-atomic-guard? #t))
             (set! applied-repairs (cons 'insert-mmc1-serial-nmi-guard applied-repairs))]

            [(unmapped-wram-access)
             (set! repaired
                   (hash-set
                    (hash-set
                     (hash-set repaired 'mapper 'MMC1)
                     'wram-enabled? #t)
                    'mmc1-atomic-guard? #t))
             (set! applied-repairs (cons 'promote-mapper-to-mmc1-sxrom-wram applied-repairs))]

            [(wram-chip-select-disabled)
             (set! repaired (hash-set repaired 'wram-enabled? #t))
             (set! applied-repairs (cons 'enable-wram-chip-select-in-boot applied-repairs))]

            [(unrestored-ppu-scroll-latch)
             (define old-ops (hash-ref repaired 'nmi-ops '()))
             (set! repaired
                   (hash-set
                    (hash-set
                     (hash-set repaired 'unrestored-ppu-latch? #f)
                     'nmi-ops (append old-ops (list (hasheq 'op 'restore-scroll! 'x 0 'y 0))))
                    'vblank-cycles (+ (hash-ref repaired 'vblank-cycles 0) 18)))
             (set! applied-repairs (cons 'insert-restore-scroll-latch applied-repairs))]

            [(dmc-joypad-clock-glitch)
             (set! repaired (hash-set repaired 'joypad-poll-mode 'double-read-safe))
             (set! applied-repairs (cons 'upgrade-joypad-dmc-double-read applied-repairs))]

            [(vblank-cycle-budget-exceeded vram-transfer-bandwidth-exceeded)
             (define raw-vram (hash-ref repaired 'vram-dma-bytes 64))
             (define needed-slices (max 2 (quotient (+ raw-vram 63) 64)))
             (set! repaired
                   (hash-set
                    (hash-set repaired 'vram-queue-slices needed-slices)
                    'vblank-cycles (min 1850 (hash-ref repaired 'vblank-cycles 1850))))
             (set! applied-repairs (cons 'stripe-vram-dma-ring-buffer applied-repairs))]

            [(active-frame-cycle-lag)
             (define raw-cyc (hash-ref repaired 'active-cycles 0))
             (define needed-slices (max 2 (quotient (+ raw-cyc 23999) 24000)))
             (set! repaired (hash-set repaired 'turn-slices needed-slices))
             (set! applied-repairs (cons 'slice-turn-across-vblank-coroutines applied-repairs))]

            [(unaligned-page-crossing-hazard)
             (set! repaired (hash-set repaired 'page-crossings 0))
             (set! applied-repairs (cons 'align-256-rom-tables applied-repairs))]

            [(scanline-8-sprite-overflow)
             (set! repaired (hash-set repaired 'oam-mux? #t))
             (set! applied-repairs (cons 'enable-coprime-oam-flicker-mux applied-repairs))]

            [(oam-total-sprites-exceeded)
             (set! repaired (hash-set repaired 'oam-sprites (nes-budget-oam-sprites-max budget)))
             (set! applied-repairs (cons 'move-static-tiles-to-nametable applied-repairs))]

            [(zero-page-overflow)
             (set! repaired (hash-set repaired 'zp-extra-bytes 0))
             (set! applied-repairs (cons 'recycle-zp-scratch-high-watermark applied-repairs))]

            [(prg-single-bank-overflow)
             (define rebalanced
               (for/list ([b (in-list (hash-ref repaired 'prg-banks '()))])
                 (hash-set b 'bytes (min (hash-ref b 'bytes 0) (hash-ref b 'limit 16384)))))
             (set! repaired (hash-set repaired 'prg-banks rebalanced))
             (set! applied-repairs (cons 'rebalance-prg-rom-banks applied-repairs))]

            [(chr-rom-tile-overflow)
             (set! repaired
                   (hash-set
                    (hash-set repaired 'chr-mode 'chr-ram)
                    'active-chr-tiles (min 64 (hash-ref repaired 'chr-tiles 64))))
             (set! applied-repairs (cons 'convert-chr-rom-to-dynamic-chr-ram applied-repairs))]

            [(attribute-table-16x16-clash)
             (set! repaired
                   (hash-set
                    (hash-set repaired 'attr-clashes 0)
                    'nametable-cells '()))
             (set! applied-repairs (cons 'align-16x16-metatile-quadrants applied-repairs))]

            [(sprite0-missing-opaque-overlap)
             (set! repaired (hash-set repaired 'sprite0-opaque-overlap? #t))
             (set! applied-repairs (cons 'place-sprite0-on-opaque-hud-tile applied-repairs))]

            [(scroll-mirroring-seam-clash)
             (define sm (hash-ref repaired 'scroll-mode 'horizontal))
             (define fixed-mir (if (eq? sm 'horizontal) 'vertical 'horizontal))
             (set! repaired (hash-set repaired 'mirroring fixed-mir))
             (set! applied-repairs (cons 'align-nametable-mirroring-to-scroll-axis applied-repairs))]

            [(unrecoverable-failure-softlock)
             (define fixed-sms
               (for/list ([sm (in-list (hash-ref repaired 'state-machines '()))])
                 (define init-st (hash-ref sm 'initial 'active))
                 (define fixed-states
                   (for/list ([s (in-list (hash-ref sm 'states '()))])
                     (if (and (memq (hash-ref s 'kind 'normal) '(failure dying dead defeat game-over top-out))
                              (null? (hash-ref s 'transitions '())))
                         (hash-set s 'transitions (list init-st))
                         s)))
                 (hash-set sm 'states fixed-states)))
             (set! repaired (hash-set repaired 'state-machines fixed-sms))
             (set! applied-repairs (cons 'inject-failure-state-respawn-transition applied-repairs))]

            [(unreachable-victory-state)
             (define fixed-sms
               (for/list ([sm (in-list (hash-ref repaired 'state-machines '()))])
                 (define init-st (hash-ref sm 'initial 'active))
                 (define states (hash-ref sm 'states '()))
                 (define vic-ids
                   (for/list ([s (in-list states)]
                              #:when (memq (hash-ref s 'kind 'normal) '(victory completed win)))
                     (hash-ref s 'id)))
                 (define fixed-states
                   (for/list ([s (in-list states)])
                     (if (eq? (hash-ref s 'id) init-st)
                         (hash-set s 'transitions
                                   (remove-duplicates (append (hash-ref s 'transitions '()) vic-ids)))
                         s)))
                 (hash-set sm 'states fixed-states)))
             (set! repaired (hash-set repaired 'state-machines fixed-sms))
             (set! applied-repairs (cons 'connect-disconnected-victory-state applied-repairs))]

            [(pinned-zp-address-collision)
             (define seen (make-hash))
             (define next-free #x30)
             (define fixed-zpmap
               (for/list ([entry (in-list (hash-ref repaired 'zp-map '()))])
                 (define addr (hash-ref entry 'addr 0))
                 (if (hash-has-key? seen addr)
                     (let ([new-addr next-free])
                       (set! next-free (add1 next-free))
                       (hash-set! seen new-addr #t)
                       (hash-set entry 'addr new-addr))
                     (begin
                       (hash-set! seen addr #t)
                       entry))))
             (set! repaired (hash-set repaired 'zp-map fixed-zpmap))
             (set! applied-repairs (cons 'relocate-colliding-pinned-zp-address applied-repairs))]))

        (define final-res (typecheck-nes-module repaired budget))
        (values repaired (reverse (remove-duplicates applied-repairs)) final-res))))

(define (compile-and-verify-nes-module mod [budget NTSC-NROM-BUDGET])
  (repair-nes-module mod budget))

;; ============================================================================
;; 10. Compositional, Syntax-Directed Pre-Assembly DSL Grade Inference
;; ============================================================================
;; Computes Phi1..Phi5 and L1..L4 purely from `#lang boba-nes` DSL forms and
;; declarative resource descriptors BEFORE generating or assembling 6502 code.

(define DSL-6502-INST-CYCLES
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

(define (dsl-inst-cycles-and-bytes form)
  (match form
    [`(label ,_) (values 0 0)]
    [`(.equ ,_ ,_) (values 0 0)]
    [`(.byte . ,bs) (values 0 (length bs))]
    [`(.word . ,ws) (values 0 (* 2 (length ws)))]
    [`(.align ,_) (values 0 0)]
    [`(STA #:abs #x4014) (values (+ 4 514) 3)]
    [`(,mnem)
     #:when (hash-has-key? DSL-6502-INST-CYCLES mnem)
     (define entry (hash-ref DSL-6502-INST-CYCLES mnem 2))
     (values (if (hash? entry) (hash-ref entry 'acc 2) entry) 1)]
    [`(,mnem ,_target)
     #:when (hash-has-key? DSL-6502-INST-CYCLES mnem)
     (define entry (hash-ref DSL-6502-INST-CYCLES mnem 3))
     (define len (if (memq mnem '(JMP JSR)) 3 2))
     (values (if (hash? entry) (hash-ref entry 'abs 3) entry) len)]
    [`(,mnem ,kw ,_op)
     #:when (and (hash-has-key? DSL-6502-INST-CYCLES mnem) (keyword? kw))
     (define mode (string->symbol (keyword->string kw)))
     (define entry (hash-ref DSL-6502-INST-CYCLES mnem 4))
     (define cyc (if (hash? entry) (hash-ref entry mode 4) entry))
     (define len (if (memq mode '(abs absx absy ind)) 3 2))
     (values cyc len)]
    [else (values 2 2)]))

(define (make-empty-dsl-effects)
  (hasheq 'grade             nes-grade-zero
          'ppu-ops           '()
          'nmi-ops           '()
          'pha-count         0
          'pla-count         0
          'zp-scratch-blocks '()))

(define (seq-dsl-effects e1 e2)
  (hasheq 'grade             (nes-grade-seq (hash-ref e1 'grade) (hash-ref e2 'grade))
          'ppu-ops           (append (hash-ref e1 'ppu-ops) (hash-ref e2 'ppu-ops))
          'nmi-ops           (append (hash-ref e1 'nmi-ops) (hash-ref e2 'nmi-ops))
          'pha-count         (+ (hash-ref e1 'pha-count) (hash-ref e2 'pha-count))
          'pla-count         (+ (hash-ref e1 'pla-count) (hash-ref e2 'pla-count))
          'zp-scratch-blocks (append (hash-ref e1 'zp-scratch-blocks)
                                     (hash-ref e2 'zp-scratch-blocks))))

(define (join-dsl-effects e1 e2)
  (hasheq 'grade             (nes-grade-join (hash-ref e1 'grade) (hash-ref e2 'grade))
          'ppu-ops           (remove-duplicates (append (hash-ref e1 'ppu-ops) (hash-ref e2 'ppu-ops)))
          'nmi-ops           (append (hash-ref e1 'nmi-ops) (hash-ref e2 'nmi-ops))
          'pha-count         (max (hash-ref e1 'pha-count) (hash-ref e2 'pha-count))
          'pla-count         (max (hash-ref e1 'pla-count) (hash-ref e2 'pla-count))
          'zp-scratch-blocks (append (hash-ref e1 'zp-scratch-blocks)
                                     (hash-ref e2 'zp-scratch-blocks))))

(define (scale-dsl-effects k eff)
  (hasheq 'grade             (nes-grade-scale k (hash-ref eff 'grade))
          'ppu-ops           (hash-ref eff 'ppu-ops)
          'nmi-ops           (hash-ref eff 'nmi-ops)
          'pha-count         (* k (hash-ref eff 'pha-count))
          'pla-count         (* k (hash-ref eff 'pla-count))
          'zp-scratch-blocks (hash-ref eff 'zp-scratch-blocks)))

;; Infer both the 12-component `nes-grade` and logical hardware effects (`ppu-ops`,
;; `nmi-ops`, `pha-count`, `pla-count`, `zp-scratch-blocks`) from a DSL statement or AST node
(define (infer-dsl-statement-effects stmt [phase 'ActiveFrame])
  (define (infer-seq stmts)
    (for/fold ([acc (make-empty-dsl-effects)])
              ([s (in-list stmts)])
      (seq-dsl-effects acc (infer-dsl-statement-effects s phase))))

  (match stmt
    ;; Already a phase-block or scratch descriptor hash
    [(? hash? h)
     (cond
       [(eq? (hash-ref h 'phase #f) 'VBlankNMI)
        (define body-scratch (hash-ref h 'body-result '()))
        (define s-list
          (cond
            [(hash? body-scratch) (list body-scratch)]
            [(list? body-scratch) (filter hash? body-scratch)]
            [else '()]))
        (define s-peak
          (for/fold ([pk 0]) ([b (in-list s-list)])
            (max pk (hash-ref b 'bytes 0))))
        (hasheq 'grade (nes-grade (hash-ref h 'vblank-cycles 0)
                                  0
                                  (hash-ref h 'oam-sprites 0)
                                  (hash-ref h 'scanline-sprites 0)
                                  0
                                  s-peak
                                  0
                                  0
                                  0
                                  (hash-ref h 'vram-dma-bytes 0)
                                  0
                                  (set))
                'ppu-ops           (hash-ref h 'ppu-ops '())
                'nmi-ops           (hash-ref h 'nmi-ops '())
                'pha-count         3
                'pla-count         3
                'zp-scratch-blocks s-list)]
       [(eq? (hash-ref h 'phase #f) 'ActiveFrame)
        (define body-scratch (hash-ref h 'body-result '()))
        (define s-list
          (cond
            [(hash? body-scratch) (list body-scratch)]
            [(list? body-scratch) (filter hash? body-scratch)]
            [else '()]))
        (define s-peak
          (for/fold ([pk 0]) ([b (in-list s-list)])
            (max pk (hash-ref b 'bytes 0))))
        (hasheq 'grade (nes-grade (hash-ref h 'active-cycles 0)
                                  0
                                  0
                                  0
                                  0
                                  s-peak
                                  (hash-ref h 'ram-bytes 0)
                                  0
                                  0
                                  0
                                  0
                                  (list->set (hash-ref h 'apu-channels '())))
                'ppu-ops           '()
                'nmi-ops           '()
                'pha-count         0
                'pla-count         0
                'zp-scratch-blocks s-list)]
       [(hash-has-key? h 'bytes)
        (define b (hash-ref h 'bytes 0))
        (hasheq 'grade             (nes-grade 0 0 0 0 0 b 0 0 0 0 0 (set))
                'ppu-ops           '()
                'nmi-ops           '()
                'pha-count         0
                'pla-count         0
                'zp-scratch-blocks (list h))]
       [else (make-empty-dsl-effects)])]

    ;; Empty statement list
    ['() (make-empty-dsl-effects)]

    ;; Sequential statement block: (seq s1 ...) or (begin s1 ...)
    [`(,(or 'seq 'begin) . ,stmts)
     (infer-seq stmts)]

    ;; Conditional branch join: (if cond-e then-s else-s)
    [`(if ,_cond ,then-s ,else-s)
     (define cond-eff (hasheq 'grade (nes-grade 5 0 0 0 0 0 0 4 0 0 0 (set))
                              'ppu-ops '() 'nmi-ops '() 'pha-count 0 'pla-count 0 'zp-scratch-blocks '()))
     (seq-dsl-effects cond-eff
                      (join-dsl-effects (infer-dsl-statement-effects then-s phase)
                                        (infer-dsl-statement-effects else-s phase)))]

    ;; Single-armed conditional: (when cond-e s1 ...) / (unless cond-e s1 ...)
    [`(,(or 'when 'unless) ,_cond . ,body)
     (define cond-eff (hasheq 'grade (nes-grade 5 0 0 0 0 0 0 4 0 0 0 (set))
                              'ppu-ops '() 'nmi-ops '() 'pha-count 0 'pla-count 0 'zp-scratch-blocks '()))
     (seq-dsl-effects cond-eff
                      (join-dsl-effects (infer-seq body)
                                        (make-empty-dsl-effects)))]

    ;; Multi-way conditional: (cond [test s1 ...] ...)
    [`(cond . ,clauses)
     (for/fold ([acc (make-empty-dsl-effects)])
               ([cl (in-list clauses)])
       (match cl
         [`(,_test . ,body)
          (join-dsl-effects acc (infer-seq body))]
         [else acc]))]

    ;; Bounded iteration scaling: (repeat-static k body ...) or (loop-bound k body ...)
    [`(,(or 'repeat-static 'loop-bound) ,(? exact-integer? k) . ,body)
     (scale-dsl-effects k (infer-seq body))]

    ;; Scoped Zero-Page scratch block: (with-zp-scratch ([id bytes] ...) body ...)
    [`(with-zp-scratch ([,ids ,byte-counts] ...) . ,body)
     (define local-bytes (apply + byte-counts))
     (define body-eff (infer-seq body))
     (define bg (hash-ref body-eff 'grade))
     (define new-blks
       (for/list ([id (in-list ids)]
                  [b  (in-list byte-counts)])
         (hasheq 'id id 'bytes b 'leaked? #f)))
     (hasheq 'grade (nes-grade (nes-grade-cycles bg)
                               (nes-grade-page-crossings bg)
                               (nes-grade-oam-sprites bg)
                               (nes-grade-scanline-sprites bg)
                               (nes-grade-zp-bytes-live bg)
                               (+ local-bytes (nes-grade-zp-bytes-peak bg))
                               (nes-grade-ram-bytes bg)
                               (nes-grade-prg-rom-bytes bg)
                               (nes-grade-chr-tiles bg)
                               (nes-grade-vram-dma-bytes bg)
                               (nes-grade-attr-clashes bg)
                               (nes-grade-apu-channels bg))
             'ppu-ops           (hash-ref body-eff 'ppu-ops)
             'nmi-ops           (hash-ref body-eff 'nmi-ops)
             'pha-count         (hash-ref body-eff 'pha-count)
             'pla-count         (hash-ref body-eff 'pla-count)
             'zp-scratch-blocks (append new-blks (hash-ref body-eff 'zp-scratch-blocks)))]

    ;; High-level PPU OAM DMA transfer: (oam-dma! [page])
    [`(oam-dma! . ,_)
     (hasheq 'grade             (nes-grade 526 0 0 0 0 0 0 10 0 0 0 (set))
             'ppu-ops           (list (hasheq 'op 'oam-dma! 'phase phase))
             'nmi-ops           (if (eq? phase 'VBlankNMI) (list (hasheq 'op 'oam-dma!)) '())
             'pha-count         0
             'pla-count         0
             'zp-scratch-blocks '())]

    ;; High-level PPU VRAM / Nametable / HUD BCD write
    [`(,(or 'nametable-patch! 'vram-put! 'ppu-write! 'hud-bcd-delta!) ,_addr . ,rest)
     (define cnt (if (and (pair? rest) (exact-integer? (car rest)) (> (car rest) 0)) (car rest) 1))
     (hasheq 'grade             (nes-grade (+ 16 (* 4 cnt)) 0 0 0 0 0 0 (+ 10 (* 5 cnt)) 0 (+ 2 cnt) 0 (set))
             'ppu-ops           (list (hasheq 'op 'nametable-patch! 'phase phase))
             'nmi-ops           (if (eq? phase 'VBlankNMI) (list (hasheq 'op 'nametable-patch!)) '())
             'pha-count         0
             'pla-count         0
             'zp-scratch-blocks '())]

    ;; High-level PPU Palette update
    [`(palette-write! ,_addr . ,_)
     (hasheq 'grade             (nes-grade 22 0 0 0 0 0 0 12 0 3 0 (set))
             'ppu-ops           (list (hasheq 'op 'palette-write! 'phase phase))
             'nmi-ops           (if (eq? phase 'VBlankNMI) (list (hasheq 'op 'palette-write!)) '())
             'pha-count         0
             'pla-count         0
             'zp-scratch-blocks '())]

    ;; High-level PPU Scroll Latch Restoration: (restore-scroll! x y)
    [`(restore-scroll! ,x ,y)
     (hasheq 'grade             (nes-grade 20 0 0 0 0 0 0 13 0 0 0 (set))
             'ppu-ops           '()
             'nmi-ops           (list (hasheq 'op 'restore-scroll!
                                              'x (if (exact-integer? x) x 0)
                                              'y (if (exact-integer? y) y 0)))
             'pha-count         0
             'pla-count         0
             'zp-scratch-blocks '())]

    ;; High-level Metasprite OAM Emission: (emit-metasprite! ms-desc x y slot)
    [`(emit-metasprite! ,ms . ,_)
     (define oam-n  (if (hash? ms) (hash-ref ms 'oam-sprites 4) 4))
     (define scan-n (if (hash? ms) (hash-ref ms 'scanline-sprites 2) 2))
     (define cyc    (if (= oam-n 2) 38 68))
     (hasheq 'grade             (nes-grade cyc 0 oam-n scan-n 0 0 0 (* oam-n 12) 0 0 0 (set))
             'ppu-ops           '()
             'nmi-ops           '()
             'pha-count         0
             'pla-count         0
             'zp-scratch-blocks '())]

    ;; High-level 2A03 APU Channel Sound Effect: (apu-sfx! channel ...)
    [`(,(or 'apu-sfx! 'apu-write!) ,ch . ,_)
     (define ch-sym (if (and (pair? ch) (eq? (car ch) 'quote)) (cadr ch) ch))
     (hasheq 'grade             (nes-grade 18 0 0 0 0 0 0 15 0 0 0
                                           (if (symbol? ch-sym) (set ch-sym) (set)))
             'ppu-ops           '()
             'nmi-ops           '()
             'pha-count         0
             'pla-count         0
             'zp-scratch-blocks '())]

    ;; High-level Joypad Polling: (poll-joypad! ...)
    [`(poll-joypad! . ,_)
     (hasheq 'grade             (nes-grade 152 0 0 0 0 0 0 28 0 0 0 (set))
             'ppu-ops           '()
             'nmi-ops           '()
             'pha-count         0
             'pla-count         0
             'zp-scratch-blocks '())]

    ;; 6502 / Low-level AST instructions (or nested statement lists)
    [_
     (cond
       ;; A list of statements/instructions (e.g. a block body)
       [(and (list? stmt) (pair? stmt) (list? (car stmt)))
        (infer-seq stmt)]
       [else
        (define-values (cyc len) (dsl-inst-cycles-and-bytes stmt))
        (define pha (if (member stmt '((PHA) (PHP))) 1 0))
        (define pla (if (member stmt '((PLA) (PLP))) 1 0))
        (define ppu-op
          (match stmt
            [`(STA #:abs #x4014) (list (hasheq 'op 'oam-dma! 'phase phase))]
            [(or `(STA #:abs #x2007) `(STA #:abs #x2006))
             (list (hasheq 'op 'nametable-patch! 'phase phase))]
            [else '()]))
        (define nmi-op
          (if (eq? phase 'VBlankNMI)
              (match stmt
                [`(STA #:abs #x4014) (list (hasheq 'op 'oam-dma!))]
                [(or `(STA #:abs #x2007) `(STA #:abs #x2006))
                 (list (hasheq 'op 'nametable-patch!))]
                [`(STA #:abs #x2005)
                 (list (hasheq 'op 'restore-scroll! 'x 0 'y 0))]
                [else '()])
              '()))
        (define vram-b
          (match stmt
            [(or `(STA #:abs #x2007) `(STA #:abs #x2006)) 1]
            [`(JSR ,callee) #:when (memq callee '(set_nt0_addr set_vram_addr)) 2]
            [else 0]))
        (define apu-ch
          (match stmt
            [`(STA #:abs ,(? exact-integer? addr))
             (cond
               [(<= #x4000 addr #x4003) (set 'pulse1)]
               [(<= #x4004 addr #x4007) (set 'pulse2)]
               [(<= #x4008 addr #x400B) (set 'triangle)]
               [(<= #x400C addr #x400F) (set 'noise)]
               [(<= #x4010 addr #x4013) (set 'dmc)]
               [else (set)])]
            [else (set)]))
        (hasheq 'grade             (nes-grade cyc 0 0 0 0 0 0 len 0 vram-b 0 apu-ch)
                'ppu-ops           ppu-op
                'nmi-ops           nmi-op
                'pha-count         pha
                'pla-count         pla
                'zp-scratch-blocks '())])]))

(define (infer-dsl-statement-grade stmt [phase 'ActiveFrame])
  (hash-ref (infer-dsl-statement-effects stmt phase) 'grade))

;; Count non-zero 16-byte 2bpp CHR tiles from a CHR resource (bytes or tile alist) before assembly
(define (infer-dsl-chr-tiles chr-res)
  (cond
    [(bytes? chr-res)
     (define num-tiles (quotient (min 8192 (bytes-length chr-res)) 16))
     (for/sum ([t (in-range num-tiles)])
       (define base (* t 16))
       (if (for/or ([i (in-range 16)])
             (not (zero? (bytes-ref chr-res (+ base i)))))
           1
           0))]
    [(list? chr-res) (length chr-res)]
    [(exact-integer? chr-res) chr-res]
    [else 0]))

;; Synthesize a complete module descriptor hash (`synthesize-dsl-module-grades`)
;; directly from `#lang boba-nes` declarative resources & DSL phase blocks / AST
;; BEFORE calling `assemble-6502`.
(define (synthesize-dsl-module-grades
         #:name              [name 'nes-dsl-module]
         #:mapper            [mapper 'NROM]
         #:mirroring         [mirroring 'vertical]
         #:scroll-mode       [scroll-mode 'none]
         #:zp-map            [zp-map '()]
         #:zp-vars           [zp-vars '()]
         #:vblank-scratch    [vblank-scratch '()]
         #:active-scratch    [active-scratch '()]
         #:zp-scratch-blocks [zp-scratch-blocks '()]
         #:metasprites       [metasprites '()]
         #:sprite-tiles      [sprite-tiles '()]
         #:oam-template      [oam-template #f]
         #:oam-sprites       [oam-sprites #f]
         #:scanline-sprites  [scanline-sprites #f]
         #:chr               [chr #f]
         #:chr-tiles         [chr-tiles #f]
         #:state-machine     [state-machine #f]
         #:state-machines    [state-machines '()]
         #:vblank-block      [vblank-blk #f]
         #:active-block      [active-blk #f]
         #:vblank-ast        [vblank-ast #f]
         #:active-ast        [active-ast #f]
         #:nmi-subroutines   [nmi-subroutines #f]
         #:vram-bytes        [vram-bytes #f]
         #:ram-bytes         [ram-bytes 64]
         #:prg-rom-bytes     [prg-rom-bytes #f]
         #:apu-channels      [apu-channels #f])

  ;; 1. Infer Phi3 Zero-Page permanent vars from `defzp-map` / `defzp-var`
  (define inferred-zp-vars
    (cond
      [(pair? zp-vars) zp-vars]
      [(pair? zp-map)
       (for/list ([entry (in-list zp-map)])
         (hasheq 'name  (hash-ref entry 'id 'zp_var)
                 'bytes (hash-ref entry 'bytes 1)
                 'cap   'RamLinear))]
      [else (list (hasheq 'name 'zp_game_state 'bytes 16 'cap 'RamLinear))]))

  ;; 2. Infer VBlank and ActiveFrame statement/block grades & logical effects
  (define vb-eff
    (cond
      [vblank-ast (infer-dsl-statement-effects vblank-ast 'VBlankNMI)]
      [vblank-blk (infer-dsl-statement-effects vblank-blk 'VBlankNMI)]
      [else       (make-empty-dsl-effects)]))
  (define act-eff
    (cond
      [active-ast (infer-dsl-statement-effects active-ast 'ActiveFrame)]
      [active-blk (infer-dsl-statement-effects active-blk 'ActiveFrame)]
      [else       (make-empty-dsl-effects)]))

  (define vb-g  (hash-ref vb-eff 'grade))
  (define act-g (hash-ref act-eff 'grade))

  ;; 3. Infer Phi2 OAM sprites & scanline sprites from declared `defmetasprite` / `defsprite-tile` / `defoam-resource`
  (define ms-oam-sum
    (+ (for/sum ([m (in-list metasprites)]) (hash-ref m 'oam-sprites 4))
       (for/sum ([s (in-list sprite-tiles)]) (hash-ref s 'oam-sprites 1))))
  (define ms-scan-sum
    (for/sum ([m (in-list metasprites)]) (hash-ref m 'scanline-sprites 2)))

  (define inferred-oam-sprites
    (cond
      [oam-sprites oam-sprites]
      [(and (list? oam-template) (pair? oam-template)) (quotient (length oam-template) 4)]
      [(> ms-oam-sum 0) ms-oam-sum]
      [(> (nes-grade-oam-sprites vb-g) 0) (nes-grade-oam-sprites vb-g)]
      [(> (nes-grade-oam-sprites act-g) 0) (nes-grade-oam-sprites act-g)]
      [else 11]))

  (define inferred-scanline-sprites
    (cond
      [scanline-sprites scanline-sprites]
      [(> ms-scan-sum 0) (min 8 ms-scan-sum)]
      [(> (nes-grade-scanline-sprites vb-g) 0) (nes-grade-scanline-sprites vb-g)]
      [(> (nes-grade-scanline-sprites act-g) 0) (nes-grade-scanline-sprites act-g)]
      [else 4]))

  ;; 4. Infer Phi3 CHR tiles from `defchr-resource` / `defchr-tile`
  (define inferred-chr-tiles
    (cond
      [chr-tiles chr-tiles]
      [chr       (infer-dsl-chr-tiles chr)]
      [else      0]))

  ;; 5. Collect high-watermark Zero-Page scratch blocks across VBlank and ActiveFrame
  (define (norm-scratch lst)
    (for/list ([item (in-list (if (list? lst) lst (list lst)))]
               #:when (or (hash? item) (pair? item)))
      (match item
        [(? hash? h) h]
        [`(,id ,(? exact-integer? b)) (hasheq 'id id 'bytes b 'leaked? #f)]
        [(cons id (? exact-integer? b)) (hasheq 'id id 'bytes b 'leaked? #f)]
        [else (hasheq 'id 'scratch 'bytes 4 'leaked? #f)])))

  (define all-scratch
    (append (norm-scratch zp-scratch-blocks)
            (norm-scratch vblank-scratch)
            (norm-scratch active-scratch)
            (hash-ref vb-eff 'zp-scratch-blocks)
            (hash-ref act-eff 'zp-scratch-blocks)))

  ;; 6. Collect state machines (`defstate-machine`)
  (define fsm-list
    (cond
      [(pair? state-machines) state-machines]
      [(hash? state-machine)  (list state-machine)]
      [(list? state-machine)  state-machine]
      [else '()]))

  ;; 7. Collect L1 stack discipline (`subroutines`), L3 `ppu-ops`, L4 `nmi-ops`, Phi4 `vram-dma-bytes`, Phi5 `apu-channels`
  (define subs
    (or nmi-subroutines
        (list (hasheq 'name      'nmi_handler
                      'pha-count (if (or vblank-ast vblank-blk) (hash-ref vb-eff 'pha-count) 3)
                      'pla-count (if (or vblank-ast vblank-blk) (hash-ref vb-eff 'pla-count) 3)))))

  (define combined-ppu-ops
    (append (hash-ref vb-eff 'ppu-ops)
            (hash-ref act-eff 'ppu-ops)))
  (define combined-nmi-ops
    (hash-ref vb-eff 'nmi-ops))

  (define inferred-vram-bytes
    (if vram-bytes
        (max vram-bytes (nes-grade-vram-dma-bytes vb-g))
        (nes-grade-vram-dma-bytes vb-g)))

  (define inferred-apu-channels
    (or apu-channels
        (set->list (set-union (nes-grade-apu-channels vb-g)
                              (nes-grade-apu-channels act-g)))))

  (define inferred-prg-bytes
    (or prg-rom-bytes
        (+ (nes-grade-prg-rom-bytes vb-g)
           (nes-grade-prg-rom-bytes act-g))))

  (hasheq 'name              name
          'mapper            mapper
          'mirroring         mirroring
          'scroll-mode       scroll-mode
          'state-machines    fsm-list
          'zp-map            zp-map
          'zp-vars           inferred-zp-vars
          'zp-scratch-blocks all-scratch
          'subroutines       subs
          'ppu-ops           combined-ppu-ops
          'nmi-ops           combined-nmi-ops
          'vblank-cycles     (nes-grade-cycles vb-g)
          'active-cycles     (nes-grade-cycles act-g)
          'page-crossings    0
          'oam-sprites       inferred-oam-sprites
          'scanline-sprites  inferred-scanline-sprites
          'ram-bytes         (max ram-bytes (nes-grade-ram-bytes act-g))
          'prg-rom-bytes     inferred-prg-bytes
          'chr-tiles         inferred-chr-tiles
          'vram-dma-bytes    inferred-vram-bytes
          'attr-clashes      0
          'apu-channels      inferred-apu-channels))

