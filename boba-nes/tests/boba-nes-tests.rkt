#lang racket/base

;; ============================================================================
;; tests/boba-nes-tests.rkt : Comprehensive Test Suite for #lang boba-nes
;; ============================================================================

(require racket/set
         racket/list
         racket/string
         "../compiler/graded-typechecker.rkt"
         "../compiler/diagnostics.rkt"
         "../compiler/mos6502-assembler.rkt"
         "../compiler/boba-rom-builder.rkt"
         "../examples/boba_is_you.bnes"
         "../examples/boba_200_levels_cartridge.bnes")

(define total-checks 0)

(define-syntax-rule (test-case name body ...)
  (begin
    (printf "  [TEST] ~a ... " name)
    (let ()
      body ...
      (void))
    (printf "OK\n")))

(define (check-equal? actual expected [msg ""])
  (set! total-checks (add1 total-checks))
  (unless (equal? actual expected)
    (error 'check-equal? "~aExpected ~v, got ~v"
           (if (equal? msg "") "" (format "~a: " msg))
           expected actual)))

(define (check-true val [msg ""])
  (check-equal? (and val #t) #t msg))

(define (check-false val [msg ""])
  (check-equal? val #f msg))

(define (check-not-false val [msg ""])
  (check-true (not (eq? val #f)) msg))

(printf "Running #lang boba-nes Graded Typechecker & 6502 ROM Verification Suite...\n\n")

;; ============================================================================
;; 1. 5-Element Capability Semiring (CapMem) Algebraic Laws
;; ============================================================================
(test-case "CapMem 5-element semiring ordering, idempotence, and conflict detection"
  (check-true (cap<=? 'ConstMeta 'RomBorrow))
  (check-true (cap<=? 'RomBorrow 'PpuTaint))
  (check-true (cap<=? 'PpuTaint  'RamLinear))
  (check-true (cap<=? 'RamLinear 'DmaUnique))
  (check-false (cap<=? 'RamLinear 'RomBorrow))

  ;; ConstMeta is additive identity
  (check-equal? (cap-par 'ConstMeta 'RamLinear) 'RamLinear)
  (check-equal? (cap-par 'DmaUnique 'ConstMeta) 'DmaUnique)

  ;; RomBorrow is idempotent under parallel composition
  (check-equal? (cap-par 'RomBorrow 'RomBorrow) 'RomBorrow)

  ;; Linear RAM and Unique DMA forbid concurrent mutable aliasing
  (check-equal? (cap-par 'RamLinear 'RamLinear) 'CapConflict)
  (check-equal? (cap-par 'DmaUnique 'RamLinear) 'CapConflict)
  (check-equal? (cap-par 'DmaUnique 'DmaUnique) 'CapConflict)

  ;; Scaling laws
  (check-equal? (cap-scale 0 'DmaUnique) 'ConstMeta)
  (check-equal? (cap-scale 4 'RomBorrow) 'RomBorrow)
  (check-equal? (cap-scale 2 'RamLinear) 'CapConflict))

;; ============================================================================
;; 2. High-Watermark Zero-Page Scratch Reuse & Chordal SSA Coloring
;; ============================================================================
(test-case "High-watermark Zero-Page scratch reuse and chordal interval coloring"
  (define g-perm (nes-grade 100 0 0 0 20 20 0 0 0 0 0 (set)))
  (define g-scr1 (nes-grade 200 0 0 0 0  12 0 0 0 0 0 (set)))
  (define g-scr2 (nes-grade 250 0 0 0 0  12 0 0 0 0 0 (set)))
  (define g-scr3 (nes-grade 300 0 0 0 0  12 0 0 0 0 0 (set)))

  ;; Sequential composition reuses the 12-byte scratch pool across all 3 phases:
  ;; live = 20 B, peak = 20 + max(12, 12, 12) = 32 B (instead of 20 + 36 = 56 B!)
  (define g-seq (nes-grade-seq (nes-grade-seq (nes-grade-seq g-perm g-scr1) g-scr2) g-scr3))
  (check-equal? (nes-grade-cycles g-seq) 850)
  (check-equal? (nes-grade-zp-bytes-live g-seq) 20)
  (check-equal? (nes-grade-zp-bytes-peak g-seq) 32)

  ;; Parallel composition of co-live scratch blocks sums their peaks:
  (define g-par (nes-grade-par g-scr1 g-scr2))
  (check-equal? (nes-grade-zp-bytes-peak g-par) 24)

  ;; Chordal SSA Zero-Page interval coloring:
  (define intervals
    (list
     ;; Erased compile-time constant -> 0 ZP bytes
     (zp-interval 'tile_consts 16 'ConstMeta 0 10 #f)
     ;; Permanent Zero-Page state live across [0, 10] -> $10..$23 (20 bytes)
     (zp-interval 'zp_permanent 20 'RamLinear 0 10 #f)
     ;; 3 disjoint sequential scratch scopes [1,2], [3,4], [5,6] -> all colored to $24!
     (zp-interval 'scratch_joypad 8 'DmaUnique 1 2 #f)
     (zp-interval 'scratch_rules  8 'DmaUnique 3 4 #f)
     (zp-interval 'scratch_push   8 'DmaUnique 5 6 #f)))

  (define alloc (allocate-zero-page-chordal intervals #:base-addr #x10 #:max-bytes 224))
  (check-true (zp-allocation-success? alloc))
  (check-equal? (zp-allocation-peak-bytes alloc) 28) ; 20 + 8 = 28 bytes!

  (define addr-map (zp-allocation-address-map alloc))
  (define (addr-of sym)
    (hash-ref (findf (lambda (h) (eq? (hash-ref h 'name) sym)) addr-map) 'addr))
  (check-false (addr-of 'tile_consts))
  (check-equal? (addr-of 'zp_permanent) #x10)
  (check-equal? (addr-of 'scratch_joypad) #x24)
  (check-equal? (addr-of 'scratch_rules)  #x24)
  (check-equal? (addr-of 'scratch_push)   #x24))

(test-case "Chordal Zero-Page overflow extracts minimal interference core"
  (define bad-intervals
    (list
     (zp-interval 'zp_table_a 120 'RamLinear 0 10 #f)
     (zp-interval 'zp_table_b 120 'RamLinear 2 8  #f)))
  (define alloc (allocate-zero-page-chordal bad-intervals #:base-addr #x10 #:max-bytes 224))
  (check-false (zp-allocation-success? alloc))
  (check-equal? (zp-allocation-peak-bytes alloc) 240)
  (check-equal? (length (zp-allocation-interference-core alloc)) 2))

;; ============================================================================
;; 3. Logical (L1..L4) & Physical (Phi1..Phi5) Violation Detection & Repair
;; ============================================================================
(test-case "Detects and repairs L1..L4 and Phi1..Phi5 hardware violations"
  (define broken-mod
    (hasheq
     'name 'broken-nes-demo
     'mapper 'MMC1
     'fixed-prg-bank 1
     'initial-prg-bank 0
     'zp-vars
     (list (hasheq 'name 'zp_player 'bytes 4 'cap 'RamLinear)
           (hasheq 'name 'zp_player 'bytes 4 'cap 'RamLinear)) ; L1 aliasing!
     'zp-scratch-blocks
     (list (hasheq 'id 'leaked_ptr 'bytes 8 'leaked? #t))      ; L1 leaked scratch!
     'subroutines
     (list (hasheq 'name 'bad_sub 'pha-count 2 'pla-count 1))  ; L1 unbalanced stack!
     'bank-calls
     (list (hasheq 'target 'music_tick 'caller-bank 0 'target-bank 2 'trampoline? #f)) ; L2!
     'ppu-ops
     (list (hasheq 'op 'vram-put! 'phase 'ActiveFrame))        ; L3 VRAM write in ActiveFrame!
     'dispatches
     (list (hasheq 'name 'entity-step 'domain '(boba rock flag) 'handled '(boba rock))) ; L3!
     'nmi-ops
     (list (hasheq 'op 'nametable-patch! 'bytes 32))           ; L4 missing restore-scroll!
     'apu-channels '(pulse1 dmc)
     'joypad-poll-mode 'single-read-unsafe                     ; L4 DMC joypad glitch!
     'vblank-cycles 2650                                       ; Phi1 > 2273 cycles!
     'active-cycles 12000
     'page-crossings 3                                         ; Phi1 page crossings!
     'oam-sprites 72                                           ; Phi2 > 64 sprites!
     'scanline-sprites 11                                      ; Phi2 > 8 scanline sprites!
     'oam-mux? #f
     'zp-extra-bytes 230                                       ; Phi3 > 224 ZP bytes!
     'ram-bytes 512
     'prg-rom-bytes 4096
     'chr-tiles 64
     'vram-dma-bytes 192                                       ; Phi4 > 128 B VRAM DMA!
     'nametable-cells
     (list (hasheq 'tile-x 0 'tile-y 0 'palette 0)
           (hasheq 'tile-x 1 'tile-y 1 'palette 2))            ; Phi4 16x16 attr clash!
     'concurrent-apu-writes
     (list (hasheq 'channel 'pulse1 'writer 'sfx_move)
           (hasheq 'channel 'pulse1 'writer 'sfx_win))))       ; Phi5 APU contention!

  (define bad-res (typecheck-nes-module broken-mod NTSC-NROM-BUDGET))
  (check-false (nes-type-result-well-typed? bad-res))

  (define cats (map nes-violation-category (nes-type-result-violations bad-res)))
  (check-not-false (memq 'zero-page-linear-aliasing cats))
  (check-not-false (memq 'unreleased-zp-scratch cats))
  (check-not-false (memq 'unbalanced-6502-stack cats))
  (check-not-false (memq 'cross-bank-call-hazard cats))
  (check-not-false (memq 'vram-write-during-active-render cats))
  (check-not-false (memq 'non-exhaustive-dispatch cats))
  (check-not-false (memq 'unrestored-ppu-scroll-latch cats))
  (check-not-false (memq 'dmc-joypad-clock-glitch cats))
  (check-not-false (memq 'vblank-cycle-budget-exceeded cats))
  (check-not-false (memq 'unaligned-page-crossing-hazard cats))
  (check-not-false (memq 'oam-total-sprites-exceeded cats))
  (check-not-false (memq 'scanline-8-sprite-overflow cats))
  (check-not-false (memq 'zero-page-overflow cats))
  (check-not-false (memq 'vram-transfer-bandwidth-exceeded cats))
  (check-not-false (memq 'attribute-table-16x16-clash cats))
  (check-not-false (memq 'apu-channel-contention cats))

  ;; Check 3-span provenance diagnostic formatting
  (define prov
    (provenance-chain
     (source-span "boba_is_you.bnes" 42 4 "defnmi")
     (source-span "boba-nes/main.rkt" 88 2 "expand-nmi-vblank")
     "STA $2007 without trailing BIT $2002 / STA $2005"))
  (define diag-str
    (format-resugared-diagnostic (first (nes-type-result-violations bad-res)) prov))
  (check-true (string-contains? diag-str "boba_is_you.bnes:42:4"))

  ;; Verify automated grade-driven repair pass on repairable physical/latch violations
  (define repairable-mod
    (hasheq
     'name 'repairable-demo
     'nmi-ops (list (hasheq 'op 'nametable-patch! 'bytes 160))
     'apu-channels '(pulse1 dmc)
     'joypad-poll-mode 'single-read-unsafe
     'vblank-cycles 2500
     'active-cycles 5000
     'page-crossings 4
     'oam-sprites 68
     'scanline-sprites 10
     'oam-mux? #f
     'zp-extra-bytes 240
     'ram-bytes 448
     'prg-rom-bytes 1024
     'chr-tiles 19
     'vram-dma-bytes 160
     'attr-clashes 2))
  (define-values (fixed-mod repairs fixed-res)
    (repair-nes-module repairable-mod NTSC-NROM-BUDGET))
  (check-true (nes-type-result-well-typed? fixed-res))
  (check-true (>= (length repairs) 6)))

;; ============================================================================
;; 4. End-to-End "Boba Is You" iNES (.nes) ROM Verification & 6502 Gameplay
;; ============================================================================
(test-case "Boba Is You compiles to valid 40,976-byte iNES 1.0 ROM and passes all grades"
  (check-true (nes-type-result-well-typed? boba-type-result))
  (check-equal? (bytes-length boba-rom-bytes) (+ 16 32768 8192))
  ;; Check "NES\x1A" magic bytes
  (check-equal? (subbytes boba-rom-bytes 0 4) #"NES\x1A")
  ;; 2 x 16KB PRG banks, 1 x 8KB CHR bank
  (check-equal? (bytes-ref boba-rom-bytes 4) 2)
  (check-equal? (bytes-ref boba-rom-bytes 5) 1))

(test-case "Stage 1 (gaia1) 6502 Execution: Break WALL IS STOP, walk through WALL, form FLAG IS WIN, and touch FLAG to win!"
  (define emu (make-nes-emulator-from-rom boba-rom-bytes))
  (define labels (asm-result-labels boba-asm-result))
  (define boot-addr  (hash-ref labels 'boot_init))
  (define frame-addr (hash-ref labels 'game_frame_step))

  ;; 1. Run boot_init subroutine
  (nes-run-until-rts! emu boot-addr)

  ;; Verify initial active rules on Stage 1:
  ;;   BOBA IS YOU  -> ZP-RULE-BOBA = #x01 (RULE-YOU)
  ;;   WALL IS STOP -> ZP-RULE-WALL = #x04 (RULE-STOP)
  ;;   FLAG IS [gap] WIN -> ZP-RULE-FLAG = #x00
  (check-equal? (nes-zp-ref emu ZP-CUR-STAGE) 0)
  (check-equal? (nes-zp-ref emu ZP-RULE-BOBA) RULE-YOU)
  (check-equal? (nes-zp-ref emu ZP-RULE-WALL) RULE-STOP)
  (check-equal? (nes-zp-ref emu ZP-RULE-FLAG) 0)
  (check-equal? (nes-zp-ref emu ZP-LEVEL-WON) 0)

  ;; Helper to press and release a button across 2 frames (because input is edge-triggered!)
  (define (tap-button! btn)
    (define-values (act1 vb1) (nes-step-frame! emu frame-addr btn))
    (define-values (act2 vb2) (nes-step-frame! emu frame-addr 0))
    ;; Verify every frame stays strictly inside the NTSC 2273-cycle VBlank budget
    ;; and leaves the 2C02 PPU scroll latch untainted!
    (check-true (<= vb1 2273))
    (check-true (<= vb2 2273))
    (check-false (nes-emulator-ppu-tainted? emu)))

  ;; 2. Boba starts at (7, 8). Try moving UP twice to (7, 6) where WALL sits:
  ;;    First UP moves Boba from (7, 8) to (7, 7); second UP hits WALL at (7, 6)
  ;;    and is BLOCKED because WALL IS STOP!
  (tap-button! BTN-UP) ; Boba -> (7, 7)
  (check-equal? (nes-ram-ref emu (+ BOARD-RAM-BASE (+ (* 7 16) 7))) OBJ-BOBA)
  (tap-button! BTN-UP) ; Blocked by WALL at (7, 6)!
  (check-equal? (nes-ram-ref emu (+ BOARD-RAM-BASE (+ (* 7 16) 7))) OBJ-BOBA)
  (check-equal? (nes-ram-ref emu (+ BOARD-RAM-BASE (+ (* 6 16) 7))) OBJ-WALL)

  ;; 3. Now move Boba to (4, 9) and push TXT-STOP at (4, 8) UP to (4, 7) to break WALL IS STOP!
  (tap-button! BTN-DOWN) ; (7, 8)
  (tap-button! BTN-DOWN) ; (7, 9)
  (tap-button! BTN-LEFT) ; (6, 9)
  (tap-button! BTN-LEFT) ; (5, 9)
  (tap-button! BTN-LEFT) ; (4, 9)
  (tap-button! BTN-UP)   ; Boba -> (4, 8), pushes TXT-STOP to (4, 7)!

  ;; Verify WALL IS STOP is now broken (ZP-RULE-WALL == 0)!
  (check-equal? (nes-zp-ref emu ZP-RULE-WALL) 0)

  ;; 4. Walk RIGHT to (7, 8) and UP right through the WALL at (7, 6) into the top room!
  (tap-button! BTN-RIGHT) ; (5, 8)
  (tap-button! BTN-RIGHT) ; (6, 8)
  (tap-button! BTN-RIGHT) ; (7, 8)
  (tap-button! BTN-UP)    ; (7, 7)
  (tap-button! BTN-UP)    ; (7, 6) -> Boba stands on top of the non-STOP WALL!
  (check-equal? (nes-ram-ref emu (+ BOARD-RAM-BASE (+ (* 6 16) 7))) OBJ-BOBA)
  (check-equal? (nes-ram-ref emu (+ UNDER-RAM-BASE (+ (* 6 16) 7))) OBJ-WALL)
  (tap-button! BTN-UP)    ; (7, 5) -> Wall at (7, 6) is restored from UNDER_RAM!
  (check-equal? (nes-ram-ref emu (+ BOARD-RAM-BASE (+ (* 6 16) 7))) OBJ-WALL)

  ;; 5. Navigate to (9, 3) to push TXT-WIN at (8, 3) LEFT into (7, 3), forming FLAG IS WIN!
  (tap-button! BTN-RIGHT) ; (8, 5)
  (tap-button! BTN-RIGHT) ; (9, 5)
  (tap-button! BTN-UP)    ; (9, 4)
  (tap-button! BTN-UP)    ; (9, 3)
  (tap-button! BTN-LEFT)  ; Boba -> (8, 3), pushes TXT-WIN to (7, 3) -> FLAG IS WIN!

  ;; Verify FLAG IS WIN is now active (ZP-RULE-FLAG == RULE-WIN)!
  (check-equal? (nes-zp-ref emu ZP-RULE-FLAG) RULE-WIN)
  (check-equal? (nes-zp-ref emu ZP-LEVEL-WON) 0)

  ;; 6. Walk RIGHT from (8, 3) -> (9, 3) -> (10, 3) to touch the FLAG at (10, 3) and WIN!
  (tap-button! BTN-RIGHT) ; (9, 3)
  (tap-button! BTN-RIGHT) ;Touches FLAG at (10, 3) -> WIN!
  (check-equal? (nes-zp-ref emu ZP-LEVEL-WON) 1))

(test-case "Stage 2 (gaia2) 6502 Execution: Control WALL (WALL IS YOU), break FLAG IS STOP, form FLAG IS WIN, and win!"
  (define emu (make-nes-emulator-from-rom boba-rom-bytes))
  (define labels (asm-result-labels boba-asm-result))
  (define boot-addr  (hash-ref labels 'boot_init))
  (define frame-addr (hash-ref labels 'game_frame_step))

  (nes-run-until-rts! emu boot-addr)
  (define (tap-button! btn)
    (nes-step-frame! emu frame-addr btn)
    (nes-step-frame! emu frame-addr 0))

  ;; Advance to Stage 2 (index 1)
  (tap-button! BTN-START)
  (check-equal? (nes-zp-ref emu ZP-CUR-STAGE) 1)
  (check-equal? (nes-zp-ref emu ZP-RULE-WALL) RULE-YOU)
  (check-equal? (nes-zp-ref emu ZP-RULE-FLAG) RULE-STOP)

  ;; Player WALL starts at (7, 8). Move to (4, 9) and push TXT-STOP at (4, 8) UP to break FLAG IS STOP:
  (tap-button! BTN-DOWN) ; (7, 9)
  (tap-button! BTN-LEFT) ; (6, 9)
  (tap-button! BTN-LEFT) ; (5, 9)
  (tap-button! BTN-LEFT) ; (4, 9)
  (tap-button! BTN-UP)   ; (4, 8) -> pushes TXT-STOP to (4, 7), breaking FLAG IS STOP!
  (check-equal? (nes-zp-ref emu ZP-RULE-FLAG) 0)

  ;; Walk through FLAG border at (7, 6) up to (9, 3) and push TXT-WIN left to (7, 3) -> FLAG IS WIN!
  (tap-button! BTN-RIGHT) ; (5, 8)
  (tap-button! BTN-RIGHT) ; (6, 8)
  (tap-button! BTN-RIGHT) ; (7, 8)
  (tap-button! BTN-UP)    ; (7, 7)
  (tap-button! BTN-UP)    ; (7, 6)
  (tap-button! BTN-UP)    ; (7, 5)
  (tap-button! BTN-RIGHT) ; (8, 5)
  (tap-button! BTN-RIGHT) ; (9, 5)
  (tap-button! BTN-UP)    ; (9, 4)
  (tap-button! BTN-UP)    ; (9, 3)
  (tap-button! BTN-LEFT)  ; (8, 3) -> pushes TXT-WIN to (7, 3) -> FLAG IS WIN!
  (check-equal? (nes-zp-ref emu ZP-RULE-FLAG) RULE-WIN)

  ;; Step down to (8, 6) to touch OBJ-FLAG and win Stage 2!
  (tap-button! BTN-DOWN) ; (8, 4)
  (tap-button! BTN-DOWN) ; (8, 5)
  (tap-button! BTN-DOWN) ; (8, 6) -> touches OBJ-FLAG -> WIN!
  (check-equal? (nes-zp-ref emu ZP-LEVEL-WON) 1))

(test-case "Stage 3 (gaia3) 6502 Execution: 2-Rock Push Chain, SKULL IS DEFEAT hazard, SELECT restart, and victory!"
  (define emu (make-nes-emulator-from-rom boba-rom-bytes))
  (define labels (asm-result-labels boba-asm-result))
  (define boot-addr  (hash-ref labels 'boot_init))
  (define frame-addr (hash-ref labels 'game_frame_step))

  (nes-run-until-rts! emu boot-addr)
  (define (tap-button! btn)
    (nes-step-frame! emu frame-addr btn)
    (nes-step-frame! emu frame-addr 0))

  ;; Advance to Stage 3 (index 2)
  (tap-button! BTN-START)
  (tap-button! BTN-START)
  (check-equal? (nes-zp-ref emu ZP-CUR-STAGE) 2)
  (check-equal? (nes-zp-ref emu ZP-RULE-ROCK) RULE-PUSH)
  (check-equal? (nes-zp-ref emu ZP-RULE-SKULL) RULE-DEFEAT)

  ;; Boba is at (6, 9) with two ROCKs stacked at (6, 8) and (6, 7).
  ;; Pressing UP pushes BOTH rocks simultaneously: (6,7)->(6,6), (6,8)->(6,7), Boba->(6,8)!
  (tap-button! BTN-UP)
  (check-equal? (nes-ram-ref emu (+ BOARD-RAM-BASE (+ (* 8 16) 6))) OBJ-BOBA)
  (check-equal? (nes-ram-ref emu (+ BOARD-RAM-BASE (+ (* 7 16) 6))) OBJ-ROCK)
  (check-equal? (nes-ram-ref emu (+ BOARD-RAM-BASE (+ (* 6 16) 6))) OBJ-ROCK)

  ;; Step LEFT onto SKULL at (5, 8) -> SKULL IS DEFEAT destroys Boba!
  (tap-button! BTN-LEFT)
  (check-equal? (nes-ram-ref emu (+ BOARD-RAM-BASE (+ (* 8 16) 6))) TILE-EMPTY)

  ;; Press SELECT to restart Stage 3 cleanly!
  (tap-button! BTN-SELECT)
  (check-equal? (nes-ram-ref emu (+ BOARD-RAM-BASE (+ (* 9 16) 6))) OBJ-BOBA)

  ;; Now push the two ROCKs up 4 times and walk RIGHT to FLAG at (10, 5) to win Stage 3!
  (tap-button! BTN-UP)    ; Boba (6, 8)
  (tap-button! BTN-UP)    ; Boba (6, 7)
  (tap-button! BTN-UP)    ; Boba (6, 6)
  (tap-button! BTN-UP)    ; Boba (6, 5)
  (tap-button! BTN-RIGHT) ; (7, 5)
  (tap-button! BTN-RIGHT) ; (8, 5)
  (tap-button! BTN-RIGHT) ; (9, 5)
  (tap-button! BTN-RIGHT) ; (10, 5) -> touches FLAG -> WIN!
  (check-equal? (nes-zp-ref emu ZP-LEVEL-WON) 1))

(test-case "Stage 4 (gaia4 Single-IS Crossword) & Stage 5 (gaia5 World Event: WALL IS BOBA) 6502 Execution"
  (define emu (make-nes-emulator-from-rom boba-rom-bytes))
  (define labels (asm-result-labels boba-asm-result))
  (define boot-addr  (hash-ref labels 'boot_init))
  (define frame-addr (hash-ref labels 'game_frame_step))

  (nes-run-until-rts! emu boot-addr)
  (define (tap-button! btn)
    (nes-step-frame! emu frame-addr btn)
    (nes-step-frame! emu frame-addr 0))

  ;; Advance to Stage 4 (index 3)
  (tap-button! BTN-START)
  (tap-button! BTN-START)
  (tap-button! BTN-START)
  (check-equal? (nes-zp-ref emu ZP-CUR-STAGE) 3)
  (check-equal? (nes-zp-ref emu ZP-RULE-BOBA) RULE-YOU)
  (check-equal? (nes-zp-ref emu ZP-RULE-FLAG) 0)

  ;; Boba at (6, 8) steps UP to (6, 7), pushing TXT-WIN to (6, 6) so the single
  ;; TXT-IS at (6, 5) simultaneously forms horizontal BOBA IS YOU and vertical FLAG IS WIN!
  (tap-button! BTN-UP)
  (check-equal? (nes-zp-ref emu ZP-RULE-BOBA) RULE-YOU)
  (check-equal? (nes-zp-ref emu ZP-RULE-FLAG) RULE-WIN)

  ;; Walk RIGHT to (11, 7) and UP to (11, 5) to touch FLAG and win Stage 4!
  (tap-button! BTN-RIGHT) ; (7, 7)
  (tap-button! BTN-RIGHT) ; (8, 7)
  (tap-button! BTN-RIGHT) ; (9, 7)
  (tap-button! BTN-RIGHT) ; (10, 7)
  (tap-button! BTN-RIGHT) ; (11, 7)
  (tap-button! BTN-UP)    ; (11, 6)
  (tap-button! BTN-UP)    ; (11, 5) -> touches FLAG -> WIN!
  (check-equal? (nes-zp-ref emu ZP-LEVEL-WON) 1)

  ;; Advance to Stage 5 (index 4: World Event WALL IS BOBA)
  (tap-button! BTN-START)
  (check-equal? (nes-zp-ref emu ZP-CUR-STAGE) 4)
  (check-equal? (nes-ram-ref emu (+ BOARD-RAM-BASE (+ (* 8 16) 8))) OBJ-WALL)

  ;; Boba at (9, 5) steps LEFT to (8, 5), pushing TXT-BOBA into (7, 5) to form WALL IS BOBA!
  (tap-button! BTN-LEFT)

  ;; World Event check: OBJ-WALL at (8, 8) has transformed into OBJ-BOBA (#x01)!
  (check-equal? (nes-ram-ref emu (+ BOARD-RAM-BASE (+ (* 8 16) 8))) OBJ-BOBA)

  ;; Verify hardware OAM DMA ($4014) populated valid sprites and Nametable HUD at $2022 updated!
  (define spr0 (nes-oam-sprite-ref emu 0))
  (check-true (< (hash-ref spr0 'y) #xF0))
  (check-equal? (nes-vram-ref emu #x2022) 4))

;; ============================================================================
;; 5. Multi-Bank Cartridges (UNROM / MMC1 / MMC3), WRAM, CHR-RAM & Turn Coroutines
;; ============================================================================
(test-case "Detects and repairs UNROM bus conflicts, MMC1 serial reentrancy, WRAM hazards, and 231-level overflows"
  (check-equal? (nes-budget-prg-rom-bytes-max NTSC-UNROM-128-BUDGET) 131072)
  (check-equal? (nes-budget-prg-rom-bytes-max NTSC-MMC1-SXROM-BUDGET) 262144)
  (check-equal? (nes-budget-ram-bytes-max NTSC-MMC1-SXROM-BUDGET) (+ 1280 8192))
  (check-equal? (nes-budget-prg-rom-bytes-max NTSC-MMC3-TXROM-BUDGET) 524288)

  ;; Module with UNROM bus conflict, unmapped WRAM access on UNROM, single-bank overflow,
  ;; active-frame lag (> 29780 cyc), and > 512 CHR tiles in CHR-ROM mode:
  (define broken-unrom-mod
    (hasheq
     'name 'broken-unrom-231
     'mapper 'UNROM
     'fixed-prg-bank 7
     'initial-prg-bank 0
     'bank-calls
     (list (hasheq 'target 'unpack_lvl 'caller-bank 7 'target-bank 2
                   'trampoline? #t 'bus-conflict-table? #f))
     'wram-bytes 4096          ; Hazard: UNROM has no $6000-$7FFF WRAM by default!
     'wram-enabled? #f
     'vblank-cycles 1400
     'active-cycles 44000      ; Hazard: exceeds 29,780-cycle single-frame budget!
     'turn-slices 1
     'ram-bytes 768
     'prg-rom-bytes 53248
     'prg-banks (list (hasheq 'bank 0 'bytes 18500 'limit 16384)) ; Single-bank > 16 KB!
     'chr-mode 'chr-rom
     'chr-tiles 580            ; Hazard: > 512 tiles in fixed 8 KB CHR-ROM!
     'active-chr-tiles 580))

  (define bad-unrom-res (typecheck-nes-module broken-unrom-mod NTSC-UNROM-128-BUDGET))
  (check-false (nes-type-result-well-typed? bad-unrom-res))
  (define unrom-cats (map nes-violation-category (nes-type-result-violations bad-unrom-res)))
  (check-not-false (memq 'unrom-bus-conflict-hazard unrom-cats))
  (check-not-false (memq 'unmapped-wram-access unrom-cats))
  (check-not-false (memq 'active-frame-cycle-lag unrom-cats))
  (check-not-false (memq 'prg-single-bank-overflow unrom-cats))
  (check-not-false (memq 'chr-rom-tile-overflow unrom-cats))

  ;; Also verify MMC1 serial shift register reentrancy hazard detection:
  (define broken-mmc1-mod
    (hasheq
     'name 'broken-mmc1
     'mapper 'MMC1
     'fixed-prg-bank 15
     'mmc1-atomic-guard? #f
     'wram-bytes 4096
     'wram-enabled? #f
     'bank-calls (list (hasheq 'target 'unpack_lvl 'caller-bank 15 'target-bank 1 'trampoline? #t))))
  (define bad-mmc1-res (typecheck-nes-module broken-mmc1-mod NTSC-MMC1-SXROM-BUDGET))
  (define mmc1-cats (map nes-violation-category (nes-type-result-violations bad-mmc1-res)))
  (check-not-false (memq 'mmc1-serial-reentrancy-hazard mmc1-cats))
  (check-not-false (memq 'wram-chip-select-disabled mmc1-cats))

  ;; Run automated repair on broken-unrom-mod under MMC1 SXROM budget (which supports 8 KB WRAM):
  (define-values (repaired-cartridge-mod cart-repairs repaired-cart-res)
    (repair-nes-module broken-unrom-mod NTSC-MMC1-SXROM-BUDGET))
  (check-true (nes-type-result-well-typed? repaired-cart-res))
  (check-equal? (hash-ref repaired-cartridge-mod 'chr-mode) 'chr-ram)
  (check-true (> (hash-ref repaired-cartridge-mod 'turn-slices) 1)))

;; ============================================================================
;; 6. Static 6502 Instruction-Level WCET Cycle Analyzer
;; ============================================================================
(test-case "Static 6502 WCET analyzer computes exact loop bounds and OAMDMA stall cycles"
  (define wcet-prog
    `((label test_loop)
      (LDX #:imm 16)                ; 2 cyc
      (loop-bound 16                ; 16 iterations of (4 + 2 + 3 = 9 cyc) = 144 cyc
        (LDA #:absx #x8000)         ; 4 cyc
        (DEX)                       ; 2 cyc
        (BNE test_loop))            ; 3 cyc (taken branch WCET)
      (LDA #:imm #x02)              ; 2 cyc
      (STA #:abs #x4014)            ; 4 + 514 OAMDMA stall = 518 cyc
      (RTS)))                       ; 6 cyc
  (define report (analyze-6502-wcet wcet-prog #:origin #xC000))
  (check-equal? (hash-ref report 'wcet-cycles) (+ 2 144 2 518 6))
  (check-equal? (hash-ref report 'page-crossings) 0))

;; ============================================================================
;; 7. 231-Level Banked Cartridge 6502 Execution: Far-Calls, WRAM & Dynamic CHR-RAM
;; ============================================================================
(test-case "231-Level Banked ROM executes cross-bank far-calls, $6000-$7FFF WRAM, and dynamic CHR-RAM synthesis"
  (check-true (nes-type-result-well-typed? res-231))
  ;; 16-byte iNES header + 2 switchable 16KB banks + 1 fixed 16KB bank = 49,168 bytes
  (check-equal? (bytes-length banked-rom-bytes) (+ 16 (* 3 16384)))
  ;; Byte 5 == 0 signals 8 KB writable CHR-RAM on the cartridge
  (check-equal? (bytes-ref banked-rom-bytes 5) 0)

  (define banked-emu (make-nes-emulator-from-rom banked-rom-bytes))
  (define fixed-labels (asm-result-labels fixed-engine-asm))
  (define reset-addr (hash-ref fixed-labels 'reset_handler))

  ;; Execute reset_handler in Fixed Bank ($C000-$FFFF):
  ;;   1. Synthesizes "KEKE" (tiles $16-$17 -> CHR-RAM $0160-$017F) and
  ;;      "MELT" (tiles $26-$27 -> CHR-RAM $0260-$027F) into writable CHR-RAM via $2006/$2007
  ;;   2. Far-calls Switchable Bank 0 ($8000: bank0_unpack_world1) -> writes $6000, $6300, $6301
  ;;   3. Far-calls Switchable Bank 1 ($8000: bank1_unpack_meta_world) -> writes $6001, $6F00, $7F17
  ;;   4. Restores caller PRG bank (0) before RTS
  (nes-run-until-rts! banked-emu reset-addr)

  ;; Verify caller PRG bank 0 was restored by far_call_trampoline!
  (check-equal? (nes-zp-ref banked-emu #x0E) 0)
  (check-equal? (nes-emulator-active-prg-bank banked-emu) 0)

  ;; Verify Switchable Bank 0 wrote Level 17 header (#x11) and stacked entities into $6000-$7FFF WRAM!
  (check-equal? (nes-wram-ref banked-emu #x6000) #x11)
  (check-equal? (nes-wram-ref banked-emu #x6300) OBJ-BOBA)
  (check-equal? (nes-wram-ref banked-emu #x6301) OBJ-FLAG)

  ;; Verify Switchable Bank 1 wrote Level 184 header (#xB8), UNDO delta (#x5A), and battery save (#x01)!
  (check-equal? (nes-wram-ref banked-emu #x6001) #xB8)
  (check-equal? (nes-wram-ref banked-emu #x6F00) #x5A)
  (check-equal? (nes-wram-ref banked-emu #x7F17) #x01)

  ;; Verify dynamic 3x5 word tiles ("KEKE" at $0160 and "MELT" at $0260) were uploaded into CHR-RAM!
  (define keke-left (compile-chr-tile (cdr (first (make-word-tile-pair #x16 "KEKE")))))
  (define melt-left (compile-chr-tile (cdr (first (make-word-tile-pair #x26 "MELT")))))
  (for ([i (in-range 16)])
    (check-equal? (nes-chr-ref banked-emu (+ #x0160 i))
                  (bytes-ref keke-left i))
    (check-equal? (nes-chr-ref banked-emu (+ #x0260 i))
                  (bytes-ref melt-left i))))

(printf "\nAll #lang boba-nes graded typechecker, repair, banked cartridge, and 6502 ROM tests PASSED (~a assertions)!\n"
        total-checks)

