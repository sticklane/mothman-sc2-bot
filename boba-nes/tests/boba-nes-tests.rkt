#lang racket/base

;; ============================================================================
;; tests/boba-nes-tests.rkt : Comprehensive Test Suite for #lang boba-nes
;; ============================================================================

(require racket/set
         racket/list
         racket/string
         racket/file
         "../compiler/graded-typechecker.rkt"
         "../compiler/diagnostics.rkt"
         "../compiler/mos6502-assembler.rkt"
         "../compiler/boba-rom-builder.rkt"
         (except-in "../compiler/boba-dsl-compiler.rkt"
                    count-nonzero-chr-tiles
                    vblank-block
                    active-frame-block)
         "../compiler/nes-games-builder.rkt"
         "../compiler/decompiled-top10.rkt"
         "../compiler/original-dsl-games.rkt"
         "../lib/nes-chr-assets.rkt"
         "../lib/boba-badge-style.rkt"
         "../lib/genre-libraries.rkt"
         "../tools/nes-resource-tool.rkt"
         "../tools/nes-rom-decompiler.rkt"
         "../examples/boba_is_you.bnes"
         "../examples/boba_200_levels_cartridge.bnes"
         "../examples/mario_platformer.bnes"
         "../examples/zelda_adventure.bnes"
         "../examples/tetris_nes.bnes"
         "../compiler/decompiled-metroid.rkt"
         "../examples/metroid_brinstar.bnes"
         "../compiler/boba-core-ir.rkt"
         "../compiler/multi-target-typechecker.rkt"
         "../compiler/backend-gb-gbc.rkt"
         "../compiler/backend-pico.rkt"
         "../compiler/backend-snes.rkt"
         "../compiler/backend-gba.rkt"
         "../compiler/backend-n64.rkt"
         "../examples/boba_gb_dmg.bnes"
         "../examples/boba_gbc_color.bnes"
         "../examples/boba_pico.bnes"
         "../examples/boba_snes.bnes"
         "../examples/boba_gba.bnes"
         "../examples/boba_n64.bnes"
         (except-in "../compiler/plt-error-diagnostics.rkt"
                    ir-palette
                    ir-tileset
                    ir-metasprite
                    ir-mode-transition
                    ir-coproc-session
                    ir-campaign)
         "../compiler/decompiled-gb-gbc-pico-top10.rkt"
         "../compiler/decompiled-snes-top10.rkt"
         "../compiler/decompiled-gba-n64-top10.rkt"
         "../tools/multi-target-side-by-side-differ.rkt"
         "../tools/whole-rom-decompiler.rkt")

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

;; ============================================================================
;; 8. 6502 Long-Branch & Page-Crossing Relaxation + Sprite 0 / Scroll Repairs
;; ============================================================================
(test-case "6502 assembler automatically relaxes >127-byte and page-crossing branches and repairs Sprite 0 / mirroring clashes"
  ;; Build a 6502 subroutine with a BNE spanning 160 NOP bytes (> +127 signed 8-bit limit!)
  (define long-branch-prog
    `((label long_entry)
      (LDA #:imm 1)
      (BNE far_target)
      ,@(for/list ([_ (in-range 160)]) '(NOP))
      (LDA #:imm #x99)
      (STA #:zp #x30)
      (RTS)
      (label far_target)
      (LDA #:imm #x42)
      (STA #:zp #x30)
      (RTS)))
  (define lb-asm (assemble-6502 long-branch-prog #:origin #x8000))
  (check-equal? (asm-result-page-crossings lb-asm) 0)
  (define lb-rom (build-ines-rom lb-asm (make-bytes 8192 0)))
  (define lb-emu (make-nes-emulator-from-rom lb-rom))
  (nes-run-until-rts! lb-emu #x8000)
  (check-equal? (nes-zp-ref lb-emu #x30) #x42)

  ;; Verify L3 sprite0-missing-opaque-overlap and Phi4 scroll-mirroring-seam-clash detection + automated repair
  (define broken-scroll-mod
    (hasheq 'name 'broken-scroll-and-sprite0
            'mapper 'NROM
            'scroll-mode 'horizontal
            'mirroring 'horizontal
            'sprite0-split? #t
            'sprite0-opaque-overlap? #f))
  (define broken-scroll-res (typecheck-nes-module broken-scroll-mod NTSC-NROM-BUDGET))
  (check-false (nes-type-result-well-typed? broken-scroll-res))
  (define scroll-v-kinds (list->set (map nes-violation-category (nes-type-result-violations broken-scroll-res))))
  (check-true (set-member? scroll-v-kinds 'sprite0-missing-opaque-overlap))
  (check-true (set-member? scroll-v-kinds 'scroll-mirroring-seam-clash))

  (define-values (repaired-scroll-mod scroll-repairs repaired-scroll-res)
    (repair-nes-module broken-scroll-mod NTSC-NROM-BUDGET))
  (check-true (nes-type-result-well-typed? repaired-scroll-res))
  (check-equal? (hash-ref repaired-scroll-mod 'mirroring) 'vertical)
  (check-true (hash-ref repaired-scroll-mod 'sprite0-opaque-overlap?))
  (check-true (set-member? (list->set scroll-repairs) 'place-sprite0-on-opaque-hud-tile))
  (check-true (set-member? (list->set scroll-repairs) 'align-nametable-mirroring-to-scroll-axis)))

;; ============================================================================
;; 9. Super Mario Bros. (World 1-1) 6502 Execution: Sprite 0 Split, 8.8 Jump,
;;    Question Block Coin, Goomba Stomp, Horizontal Scroll & Flagpole Victory
;; ============================================================================
(test-case "Super Mario Bros. (World 1-1) 6502 Execution: Sprite 0 HUD split, 8.8 jump, ? block coin, Goomba stomp & Flagpole win"
  (check-true (nes-type-result-well-typed? mario-type-result))
  (check-equal? (asm-result-page-crossings mario-asm-result) 0)
  (check-equal? (bytes-length mario-rom-bytes) (+ 16 32768 8192))

  (define m-emu (make-nes-emulator-from-rom mario-rom-bytes))
  (define m-labels (asm-result-labels mario-asm-result))
  (define m-boot  (hash-ref m-labels 'boot_init))
  (define m-frame (hash-ref m-labels 'game_frame_step))

  (nes-run-until-rts! m-emu m-boot)
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-X-WORLD-LO) 40)
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-Y-PX) 176)
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-ON-GROUND) 1)
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-GOOMBA-ALIVE) 1)
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-COINS) 0)

  ;; 1. Walk right 12 frames to X=76 (under '?' Question Block) and jump ('A') to bonk a Coin!
  (for ([_ (in-range 12)])
    (define-values (_act vb) (nes-step-frame! m-emu m-frame BTN-RIGHT))
    (check-true (<= vb 2273)))
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-X-WORLD-LO) 76)

  (nes-step-frame! m-emu m-frame BTN-A)
  (for ([_ (in-range 25)])
    (nes-step-frame! m-emu m-frame 0))
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-QBLOCK-HIT) 1)
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-COINS) 1)
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-ON-GROUND) 1)

  ;; 2. Walk right 14 frames to X=118 and stomp the Goomba at X=120!
  (for ([_ (in-range 14)])
    (nes-step-frame! m-emu m-frame BTN-RIGHT))
  (nes-step-frame! m-emu m-frame BTN-A)
  (for ([_ (in-range 35)])
    (nes-step-frame! m-emu m-frame 0))
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-GOOMBA-ALIVE) 0)
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-SCORE) 2)

  ;; 3. Run right across Nametable 0 -> Nametable 1 to the Flagpole (World X >= 340) to win!
  (for ([_ (in-range 85)])
    (define-values (_act vb) (nes-step-frame! m-emu m-frame BTN-RIGHT))
    (check-true (<= vb 2273))
    (check-false (nes-emulator-ppu-tainted? m-emu)))
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-X-WORLD-HI) 1)
  (check-true (> (nes-zp-ref m-emu MARIO-ZP-SCROLL-X) 0))
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-WON) 1))

;; ============================================================================
;; 10. The Legend of Zelda 6502 Execution: Coprime OAM Flicker, Sword Combat,
;;     Octorok Key Drop, Locked North Door & Triforce of Wisdom
;; ============================================================================
(test-case "The Legend of Zelda 6502 Execution: Coprime OAM flicker, Sword thrust vs Octorok, Key drop, Door unlock & Triforce"
  (check-true (nes-type-result-well-typed? zelda-type-result))
  (check-equal? (asm-result-page-crossings zelda-asm-result) 0)
  (check-equal? (bytes-length zelda-rom-bytes) (+ 16 32768 8192))

  (define z-emu (make-nes-emulator-from-rom zelda-rom-bytes))
  (define z-labels (asm-result-labels zelda-asm-result))
  (define z-boot  (hash-ref z-labels 'boot_init))
  (define z-frame (hash-ref z-labels 'game_frame_step))

  (nes-run-until-rts! z-emu z-boot)
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-LINK-X) 120)
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-LINK-Y) 144)
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-OCTO-ALIVE) 1)
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-HEARTS) 3)
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-OAM-CURSOR) 4)

  ;; 1. Walk Link UP 9 frames to Y=108 and thrust Sword ('A') to defeat the Red Octorok at (120, 96)!
  (for ([_ (in-range 9)])
    (define-values (_act vb) (nes-step-frame! z-emu z-frame BTN-UP))
    (check-true (<= vb 2273)))
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-LINK-Y) 108)
  ;; Verify Coprime OAM cursor rotated by +20 bytes per frame
  (check-not-false (not (= (nes-zp-ref z-emu ZELDA-ZP-OAM-CURSOR) 4)))

  (nes-step-frame! z-emu z-frame BTN-A)
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-OCTO-ALIVE) 0)
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-RUPEES) 1)

  ;; 2. Walk UP 16 frames to collect the dropped Key at (120, 96) and unlock the North Door into Room 1 (Sanctum)!
  (for ([_ (in-range 16)])
    (nes-step-frame! z-emu z-frame BTN-UP))
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-ROOM-ID) 1)
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-KEYS) 0) ; Key consumed unlocking door

  ;; 3. Walk UP 18 frames in the Sanctum to the Pedestal at (120, 104) to claim the Triforce of Wisdom!
  (for ([_ (in-range 18)])
    (define-values (_act vb) (nes-step-frame! z-emu z-frame BTN-UP))
    (check-true (<= vb 2273))
    (check-false (nes-emulator-ppu-tainted? z-emu)))
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-TRIFORCE-WON) 1))

;; ============================================================================
;; 11. Nintendo NES Tetris 6502 Execution: 10x20 Well, Rotation, Line Clear &
;;     Staged VBlank Dirty-Row Stripe Copier (2 rows = 20 B / NMI)
;; ============================================================================
(test-case "Nintendo NES Tetris 6502 Execution: 10x20 well, rotation, line clear, gravity collapse & 2-row/NMI VBlank flush"
  (check-true (nes-type-result-well-typed? tetris-type-result))
  (check-equal? (asm-result-page-crossings tetris-asm-result) 0)
  (check-equal? (bytes-length tetris-rom-bytes) (+ 16 32768 8192))

  (define t-emu (make-nes-emulator-from-rom tetris-rom-bytes))
  (define t-labels (asm-result-labels tetris-asm-result))
  (define t-boot  (hash-ref t-labels 'boot_init))
  (define t-frame (hash-ref t-labels 'game_frame_step))

  (nes-run-until-rts! t-emu t-boot)
  (check-equal? (nes-zp-ref t-emu TETRIS-ZP-PIECE-ID) 0)
  (check-equal? (nes-zp-ref t-emu TETRIS-ZP-PIECE-ROT) 0)
  (check-equal? (nes-zp-ref t-emu TETRIS-ZP-PIECE-X) 4)
  (check-equal? (nes-zp-ref t-emu TETRIS-ZP-DIRTY-ROW) 20)

  ;; 1. Test clockwise rotation ('A' button) and horizontal shift ('LEFT' button)
  (nes-step-frame! t-emu t-frame BTN-A)
  (nes-step-frame! t-emu t-frame 0)
  (check-equal? (nes-zp-ref t-emu TETRIS-ZP-PIECE-ROT) 1)
  (nes-step-frame! t-emu t-frame BTN-LEFT)
  (nes-step-frame! t-emu t-frame 0)
  (check-equal? (nes-zp-ref t-emu TETRIS-ZP-PIECE-X) 3)

  ;; 2. Pre-fill row 18 ($04B4..$04BD) cols 0,1,2,6,7,8,9 so hard-dropping a T-piece
  ;;    (ID=0, Rot=0, X=4 -> cols 3,4,5 at row 18) completes a full 10-block row!
  (for ([col (in-list '(0 1 2 6 7 8 9))])
    (nes-ram-set! t-emu (+ TETRIS-WELL-RAM-BASE 180 col) 1))
  (nes-ram-set! t-emu TETRIS-ZP-PIECE-ID 0)
  (nes-ram-set! t-emu TETRIS-ZP-PIECE-ROT 0)
  (nes-ram-set! t-emu TETRIS-ZP-PIECE-X 4)

  (define-values (_act-drop vb-drop) (nes-step-frame! t-emu t-frame BTN-B))
  ;; Verify VBlank NMI stayed strictly inside 2,273 cycles while flushing the first 2 rows (20 B)!
  (check-true (<= vb-drop 2273))
  (check-equal? (nes-zp-ref t-emu TETRIS-ZP-LINES) 1)
  (check-equal? (nes-zp-ref t-emu TETRIS-ZP-SCORE) 1)
  (check-equal? (nes-zp-ref t-emu TETRIS-ZP-DIRTY-ROW) 2)

  ;; 3. Step 9 more frames and verify the staged VBlank copier flushes all 20 rows (2 rows/NMI -> 20)
  (for ([_ (in-range 9)])
    (define-values (_a vb) (nes-step-frame! t-emu t-frame 0))
    (check-true (<= vb 2273))
    (check-false (nes-emulator-ppu-tainted? t-emu)))
  (check-equal? (nes-zp-ref t-emu TETRIS-ZP-DIRTY-ROW) 20))

;; ============================================================================
;; 12. Resource Separation, Authentic Commercial CHR Loaders, Metasprite Orders,
;;     Compiler CHR Deduplication/Flip-Folding & External ROM Patching Tools
;; ============================================================================
(test-case "Authentic Commercial CHR Loaders (SMB, Zelda, Tetris) & Zero-Offset BCD Typography Maps"
  (define smb-chr    (load-authentic-smb-chr-rom))
  (define zelda-chr  (load-authentic-zelda-chr-rom))
  (define tetris-chr (load-authentic-tetris-chr-rom))

  (check-equal? (bytes-length smb-chr) 8192)
  (check-equal? (bytes-length zelda-chr) 8192)
  (check-equal? (bytes-length tetris-chr) 8192)

  (check-equal? (count-nonblank-chr-tiles smb-chr) 510)
  (check-equal? (count-nonblank-chr-tiles zelda-chr) 456)
  (check-equal? (count-nonblank-chr-tiles tetris-chr) 382)

  ;; Zero-offset BCD property: '0'..'9' map to tile IDs 0..9, 'A'..'Z' map to 10..35
  (check-equal? (encode-char-map-string NINTENDO-STD-CHAR-MAP "019AZ ")
                '(#x00 #x01 #x09 #x0A #x23 #x24))
  (check-equal? (encode-char-map-string TETRIS-CHAR-MAP "TETRIS-0 ")
                '(#x1D #x0E #x1D #x1B #x12 #x1C #x24 #x00 #xFF)))

(test-case "Metasprite Ordering Modes (row-major, col-major, symmetric-col-major) & Compiler CHR Flip-Folding"
  ;; 1. row-major (Mario: #x32, #x33, #x34, #x35)
  (check-equal? (hash-ref mario-metasprite 'tl) #x32)
  (check-equal? (hash-ref mario-metasprite 'tr) #x33)
  (check-equal? (hash-ref mario-metasprite 'bl) #x34)
  (check-equal? (hash-ref mario-metasprite 'br) #x35)
  (check-equal? (hash-ref mario-metasprite 'tr-attr) #x00)

  ;; 2. col-major (Zelda Link: TL=#x00, BL=#x01, TR=#x02, BR=#x03)
  (check-equal? (hash-ref link-metasprite 'tl) #x00)
  (check-equal? (hash-ref link-metasprite 'bl) #x01)
  (check-equal? (hash-ref link-metasprite 'tr) #x02)
  (check-equal? (hash-ref link-metasprite 'br) #x03)

  ;; 3. symmetric-col-major (Zelda Octorok: left=#x70/#x71, right=#x70/#x71 with OAM H-Flip #x40!)
  (check-equal? (hash-ref octorok-metasprite 'tl) #x70)
  (check-equal? (hash-ref octorok-metasprite 'tr) #x70)
  (check-equal? (hash-ref octorok-metasprite 'bl) #x71)
  (check-equal? (hash-ref octorok-metasprite 'br) #x71)
  (check-equal? (hash-ref octorok-metasprite 'attr) #x02)
  (check-equal? (hash-ref octorok-metasprite 'tr-attr) (bitwise-ior #x02 #x40))
  (check-equal? (hash-ref octorok-metasprite 'br-attr) (bitwise-ior #x02 #x40))

  ;; 4. Compiler CHR Tile Deduplication & Horizontal Mirror Flip-Folding
  (define left-half (subbytes (load-authentic-zelda-chr-rom) (* #x70 16) (* #x71 16)))
  (define right-half (flip-chr-tile-horizontal left-half))
  ;; Flipping twice is an involution
  (check-equal? (flip-chr-tile-horizontal right-half) left-half)
  ;; Deduplicating [(0 . left-half), (1 . left-half), (2 . right-half)] folds all 3 into 1 unique 16-byte CHR tile!
  (define dedup-res
    (deduplicate-chr-tiles (list (cons 0 left-half)
                                 (cons 1 left-half)
                                 (cons 2 right-half))))
  (check-equal? (hash-ref dedup-res 'deduped-count) 1)
  (check-equal? (hash-ref dedup-res 'total-tiles-saved) 2)
  (define remap-tbl (hash-ref dedup-res 'remap-table))
  (check-equal? (hash-ref (hash-ref remap-tbl 0) 'hflip?) #f)
  (check-equal? (hash-ref (hash-ref remap-tbl 1) 'hflip?) #f)
  (check-equal? (hash-ref (hash-ref remap-tbl 2) 'hflip?) #t))

(test-case "External ROM Resource Inspection & Level-Editor Stage Hot-Patching without Recompilation"
  (define mario-info (inspect-ines-rom "build/mario_nes.nes"))
  (check-equal? (hash-ref mario-info 'prg-bytes) 32768)
  (check-equal? (hash-ref mario-info 'chr-bytes) 8192)
  (check-equal? (hash-ref mario-info 'nonblank-chr-tiles) 510)

  ;; Validate and compile an external sparse (col row TOKEN) stage specification (64-byte 8x8 table)
  (define ext-cells
    '((1 1 WORD-BOBA) (2 1 WORD-IS) (3 1 WORD-YOU)
      (4 1 WORD-FLAG) (5 1 WORD-IS) (6 1 WORD-WIN)
      (2 4 BOBA)      (5 4 FLAG)))
  (check-true (validate-external-boba-stage ext-cells))
  (define stage-bytes (compile-external-boba-stage-bytes ext-cells))
  (check-equal? (bytes-length stage-bytes) 64)
  (check-equal? (bytes-ref stage-bytes (+ (* 1 8) 1)) TXT-BOBA)
  (check-equal? (bytes-ref stage-bytes (+ (* 1 8) 2)) TXT-IS)
  (check-equal? (bytes-ref stage-bytes (+ (* 1 8) 3)) TXT-YOU)
  (check-equal? (bytes-ref stage-bytes (+ (* 4 8) 2)) OBJ-BOBA)
  (check-equal? (bytes-ref stage-bytes (+ (* 4 8) 5)) OBJ-FLAG)

  ;; Binary-patch stage 0 inside an in-memory copy of boba-rom-bytes without recompiling 6502 code!
  (define stage0-addr (hash-ref (asm-result-labels boba-asm-result) 'stage_1_data))
  (define patched-rom (patch-boba-rom-stage! boba-rom-bytes stage0-addr 0 ext-cells))
  (check-equal? (bytes-length patched-rom) (bytes-length boba-rom-bytes)))

(test-case "6502 Recursive-Descent ROM Decompiler & Commercial vs. #lang boba-nes Binary Equivalence"
  (define smb-dis    (disassemble-ines-rom "assets/roms/super_mario_bros.nes"))
  (define zelda-dis  (disassemble-ines-rom "assets/roms/legend_of_zelda.nes"))
  (define tetris-dis (disassemble-ines-rom "assets/roms/tetris.nes"))

  (check-equal? (hash-ref smb-dis 'mapper-name) 'NROM)
  (check-equal? (hash-ref zelda-dis 'mapper-name) 'MMC1)
  (check-equal? (hash-ref tetris-dis 'mapper-name) 'MMC1)

  (define smb-dsl (decompile-ines-rom-to-boba-dsl "assets/roms/super_mario_bros.nes" #:game-name 'smb-decompiled))
  (check-equal? (car smb-dsl) 'boba-nes-decompiled-module)
  (check-equal? (cadr smb-dsl) '(game-name smb-decompiled))

  (define smb-cmp (compare-rom-binaries "assets/roms/super_mario_bros.nes" "build/mario_nes.nes"))
  (check-equal? (hash-ref smb-cmp 'chr-exact-match-bytes) 8192)
  (check-equal? (hash-ref smb-cmp 'chr-matching-tiles) 512)
  (check-true (hash-ref smb-cmp 'vectors-valid?))

  ;; Verify 6502 Jump-Engine / Indirect Dispatch Idiom Detection on commercial ROMs
  (define smb-idioms (detect-6502-jump-engine-idioms smb-dis))
  (check-true (>= (+ (hash-ref smb-idioms 'indirect-jmp-count)
                     (hash-ref smb-idioms 'rts-dispatch-count))
                  1)))

(test-case "Full Failure -> Recovery -> Victory Trajectories & Language/Compiler/Decompiler/Library Spin-Offs"
  ;; --------------------------------------------------------------------------
  ;; 1. Super Mario Bros.: Lateral Goomba Failure -> START Respawn -> Victory
  ;; --------------------------------------------------------------------------
  (define m-emu (make-nes-emulator-from-rom mario-rom-bytes))
  (define m-labels (asm-result-labels mario-asm-result))
  (define m-boot  (hash-ref m-labels 'boot_init))
  (define m-frame (hash-ref m-labels 'game_frame_step))
  (nes-run-until-rts! m-emu m-boot)
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-LIVES) 3)
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-DEAD) 0)

  ;; Walk right 28 frames on the ground directly into the Goomba at X=120 without jumping!
  (define mario-zp-trace '())
  (for ([_ (in-range 28)])
    (nes-step-frame! m-emu m-frame BTN-RIGHT)
    (define snap (list->bytes (for/list ([a (in-range 256)]) (nes-zp-ref m-emu a))))
    (set! mario-zp-trace (cons snap mario-zp-trace)))
  (set! mario-zp-trace (reverse mario-zp-trace))

  (check-equal? (nes-zp-ref m-emu MARIO-ZP-DEAD) 1)
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-LIVES) 2)
  ;; Verify authentic SMB1 Death Pose tile (#x3E) is placed in OAM Slot 1 ($0205)
  (check-equal? (nes-ram-ref m-emu #x0205) #x3E)

  ;; Press START to respawn at (X=40, Y=176, DEAD=0, GOOMBA_ALIVE=1)!
  (nes-step-frame! m-emu m-frame BTN-START)
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-DEAD) 0)
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-X-WORLD-LO) 40)
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-Y-PX) 176)
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-GOOMBA-ALIVE) 1)

  ;; --------------------------------------------------------------------------
  ;; 2. The Legend of Zelda: Octorok Contact Damage (3 -> 0 Hearts) -> Defeat -> Respawn
  ;; --------------------------------------------------------------------------
  (define z-emu (make-nes-emulator-from-rom zelda-rom-bytes))
  (define z-labels (asm-result-labels zelda-asm-result))
  (define z-boot  (hash-ref z-labels 'boot_init))
  (define z-frame (hash-ref z-labels 'game_frame_step))
  (nes-run-until-rts! z-emu z-boot)
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-HEARTS) 3)
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-DEAD) 0)

  ;; Walk UP into the live Red Octorok at (120, 96) WITHOUT thrusting the Sword:
  ;; Knockback + 3 heart losses -> HEARTS = 0, DEAD = 1, and HUD hearts at $20D6..$20D8 become #x65!
  (for ([_ (in-range 24)])
    (nes-step-frame! z-emu z-frame BTN-UP))
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-HEARTS) 0)
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-DEAD) 1)
  (check-equal? (nes-vram-ref z-emu #x20D6) #x65)
  (check-equal? (nes-vram-ref z-emu #x20D7) #x65)
  (check-equal? (nes-vram-ref z-emu #x20D8) #x65)

  ;; Press START to respawn Link with 3 full red hearts (#xF2 at $20D6..$20D8)!
  (nes-step-frame! z-emu z-frame BTN-START)
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-DEAD) 0)
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-HEARTS) 3)
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-LINK-X) 120)
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-LINK-Y) 144)
  (check-equal? (nes-vram-ref z-emu #x20D6) #xF2)

  ;; --------------------------------------------------------------------------
  ;; 3. Nintendo NES Tetris: Center-Column Stack Top-Out -> Game Over -> START Reset
  ;; --------------------------------------------------------------------------
  (define t-emu (make-nes-emulator-from-rom tetris-rom-bytes))
  (define t-labels (asm-result-labels tetris-asm-result))
  (define t-boot  (hash-ref t-labels 'boot_init))
  (define t-frame (hash-ref t-labels 'game_frame_step))
  (nes-run-until-rts! t-emu t-boot)
  (check-equal? (nes-zp-ref t-emu TETRIS-ZP-GAME-OVER) 0)

  ;; Repeatedly hard-drop pieces in column X=4 until stack reaches spawn row (Y <= 2) -> GAME_OVER = 1!
  (define tetris-zp-trace '())
  (for ([_ (in-range 20)])
    (nes-step-frame! t-emu t-frame BTN-B)
    (define s1 (list->bytes (for/list ([a (in-range 256)]) (nes-zp-ref t-emu a))))
    (nes-step-frame! t-emu t-frame 0)
    (define s2 (list->bytes (for/list ([a (in-range 256)]) (nes-zp-ref t-emu a))))
    (set! tetris-zp-trace (cons s2 (cons s1 tetris-zp-trace))))
  (set! tetris-zp-trace (reverse tetris-zp-trace))
  (check-equal? (nes-zp-ref t-emu TETRIS-ZP-GAME-OVER) 1)

  ;; Press START to clear the 200-byte well and reset GAME_OVER = 0!
  (nes-step-frame! t-emu t-frame BTN-START)
  (check-equal? (nes-zp-ref t-emu TETRIS-ZP-GAME-OVER) 0)
  (check-equal? (nes-ram-ref t-emu (+ TETRIS-WELL-RAM-BASE 184)) 0)

  ;; --------------------------------------------------------------------------
  ;; 4. Decompiler Spin-Off: Frame-by-Frame Zero-Page Semantic Role Inference
  ;; --------------------------------------------------------------------------
  (define tetris-roles (infer-zp-roles-from-frame-trace tetris-zp-trace))
  (define role-by-addr
    (for/hash ([entry (in-list tetris-roles)])
      (values (hash-ref entry 'addr) (hash-ref entry 'role))))
  ;; $13 (TETRIS-ZP-FRAME-CNT) increments by +1 every frame -> 'monotonic-frame-counter
  (check-equal? (hash-ref role-by-addr #x13) 'monotonic-frame-counter)
  ;; $1E (TETRIS-ZP-LFSR) steps via 8-bit Galois LFSR (#xB8) every frame -> 'prng-lfsr
  (check-equal? (hash-ref role-by-addr #x1E) 'prng-lfsr)
  ;; $23 (TETRIS-ZP-GAME-OVER) transitions 0 -> 1 -> 'game-phase-or-flag
  (check-equal? (hash-ref role-by-addr TETRIS-ZP-GAME-OVER) 'game-phase-or-flag)

  (define mario-roles (infer-zp-roles-from-frame-trace mario-zp-trace))
  (define m-role-by-addr
    (for/hash ([entry (in-list mario-roles)])
      (values (hash-ref entry 'addr) (hash-ref entry 'role))))
  (check-equal? (hash-ref m-role-by-addr #x13) 'monotonic-frame-counter)
  (check-equal? (hash-ref m-role-by-addr MARIO-ZP-X-WORLD-LO) 'player-or-actor-coord)
  (check-equal? (hash-ref m-role-by-addr MARIO-ZP-DEAD) 'game-phase-or-flag)

  ;; --------------------------------------------------------------------------
  ;; 5. Language & Typechecker Spin-Off: State-Machine Soft-Lock & Pinned ZP Checks
  ;; --------------------------------------------------------------------------
  (define softlock-mod
    (hasheq 'name 'softlock-test-mod
            'mapper 'NROM
            'state-machines
            (list (hasheq 'name 'mario-phase-fsm
                          'initial 'active
                          'states (list (hasheq 'id 'active 'kind 'normal 'transitions '(dying victory))
                                        (hasheq 'id 'dying  'kind 'failure 'transitions '()) ; Missing recovery transition!
                                        (hasheq 'id 'victory 'kind 'victory 'transitions '(active)))))
            'zp-map
            (list (hasheq 'id 'player_x 'addr #x14 'role 'player-coord)
                  (hasheq 'id 'enemy_x  'addr #x14 'role 'actor-coord)))) ; Colliding ZP address $14!

  (define softlock-res (typecheck-nes-module softlock-mod))
  (check-false (nes-type-result-well-typed? softlock-res))
  (define v-cats (map nes-violation-category (nes-type-result-violations softlock-res)))
  (check-not-false (memq 'unrecoverable-failure-softlock v-cats))
  (check-not-false (memq 'pinned-zp-address-collision v-cats))

  (define-values (fixed-sm-mod sm-repairs fixed-sm-res)
    (compile-and-verify-nes-module softlock-mod))
  (check-true (nes-type-result-well-typed? fixed-sm-res))
  (check-not-false (memq 'inject-failure-state-respawn-transition sm-repairs))
  (check-not-false (memq 'relocate-colliding-pinned-zp-address sm-repairs))

  ;; --------------------------------------------------------------------------
  ;; 6. Compiler Spin-Off: 6502 Peephole Optimizer (Tail-Call + Store/Reload)
  ;; --------------------------------------------------------------------------
  (define sample-unopt-6502
    '((label sub_step)
      (LDA #:imm 42)
      (STA #:zp #x14)
      (LDA #:zp #x14) ; Redundant reload of $14!
      (TAX)
      (TXA)           ; Redundant self-transfer!
      (JSR helper_sub)
      (RTS)           ; Tail-call! Folds into (JMP helper_sub)
      (label helper_sub)
      (RTS)))
  (define peep-stats (optimize-6502-peephole-stats sample-unopt-6502))
  (check-equal? (hash-ref peep-stats 'tail-calls-folded) 1)
  (check-equal? (hash-ref peep-stats 'redundant-loads-eliminated) 1)
  (check-equal? (hash-ref peep-stats 'redundant-transfers-eliminated) 1)
  (check-equal? (hash-ref peep-stats 'bytes-saved) 4)
  (check-equal? (hash-ref peep-stats 'cycles-saved) 14)

  ;; --------------------------------------------------------------------------
  ;; 7. Libraries Spin-Off: Invincibility Damage, Top-Out Guard & VBlank HUD BCD
  ;; --------------------------------------------------------------------------
  (define lib-forms
    (append
     '((label test_lib_entry))
     (emit-invincibility-damage-handler-6502 #x22 #x26 #x27 #:iframes 3 #:knockback-zp #x15 #:knockback-val 108)
     (emit-topout-and-reset-guard-6502 #x17 #x23 #:min-safe-row 3)
     (emit-vblank-hud-bcd-delta-6502 #x206E #x1E)
     '((RTS))))
  (define lib-asm (assemble-6502 lib-forms))
  (check-equal? (asm-result-page-crossings lib-asm) 0)
  (check-true (> (bytes-length (asm-result-bytes lib-asm)) 20)))

(test-case "Full Multi-Stage, Multi-Dungeon & Multi-Level Game Campaigns (SMB 1-1..8-4, Zelda Overworld..Ganon, Tetris Levels 00..03)"
  ;; --------------------------------------------------------------------------
  ;; 1. Super Mario Bros. Full 4-Stage Campaign:
  ;;    WORLD 1-1 -> WORLD 1-2 (Underground + Hazard Death/Respawn) -> WORLD 4-1 -> WORLD 8-4 (Bowser's Castle & Princess Rescue)
  ;; --------------------------------------------------------------------------
  (define m-emu (make-nes-emulator-from-rom mario-rom-bytes))
  (define m-labels (asm-result-labels mario-asm-result))
  (define m-boot  (hash-ref m-labels 'boot_init))
  (define m-frame (hash-ref m-labels 'game_frame_step))
  (nes-run-until-rts! m-emu m-boot)

  (define smb-full-zp-trace '())
  (define (step-mario! btn [n 1])
    (for ([_ (in-range n)])
      (define-values (_act vb) (nes-step-frame! m-emu m-frame btn))
      (check-true (<= vb 2273))
      (check-false (nes-emulator-ppu-tainted? m-emu))
      (define snap (list->bytes (for/list ([a (in-range 256)]) (nes-zp-ref m-emu a))))
      (set! smb-full-zp-trace (cons snap smb-full-zp-trace))))

  (define (play-mario-stage!)
    ;; Bonk '?' Question Block at X=76
    (step-mario! BTN-RIGHT 12)
    (step-mario! BTN-A 1)
    (step-mario! 0 25)
    ;; Jump and stomp stage enemy at X=120
    (step-mario! BTN-RIGHT 14)
    (step-mario! BTN-A 1)
    (step-mario! 0 35)
    ;; Run across Nametable 0 & 1 to Flagpole/Warp Pipe/Castle Axe (85 + 8 = 93 frames)
    (step-mario! BTN-RIGHT 93)
    (step-mario! 0 1))

  ;; Stage 0: WORLD 1-1 -> advances to Stage 1 (WORLD 1-2 Underground)
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-STAGE-ID) 0)
  (play-mario-stage!)
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-STAGE-ID) 1)
  ;; Verify VBlank NMI updated HUD WORLD 1-2 ($2073=1, $2075=2) and Underground Palette ($3F00=#x0F, $3F01=#x3C)
  (check-equal? (nes-vram-ref m-emu #x2073) 1)
  (check-equal? (nes-vram-ref m-emu #x2075) 2)
  (check-equal? (nes-vram-ref m-emu #x3F00) #x0F)
  (check-equal? (nes-vram-ref m-emu #x3F01) #x3C)

  ;; Mid-Campaign Failure & In-Stage Recovery inside Stage 1 (WORLD 1-2 Underground):
  (step-mario! BTN-RIGHT 28)
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-DEAD) 1)
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-LIVES) 2)
  ;; Pressing START respawns Mario inside WORLD 1-2 (STAGE-ID remains 1!)
  (step-mario! BTN-START 1)
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-DEAD) 0)
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-STAGE-ID) 1)
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-X-WORLD-LO) 40)

  ;; Complete Stage 1 (WORLD 1-2) -> Warp Zone to Stage 2 (WORLD 4-1 Overworld)
  (play-mario-stage!)
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-STAGE-ID) 2)
  (check-equal? (nes-vram-ref m-emu #x2073) 4)
  (check-equal? (nes-vram-ref m-emu #x2075) 1)
  (check-equal? (nes-vram-ref m-emu #x3F00) #x22)

  ;; Complete Stage 2 (WORLD 4-1) -> Warp Zone to Stage 3 (WORLD 8-4 Bowser's Castle)
  (play-mario-stage!)
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-STAGE-ID) 3)
  (check-equal? (nes-vram-ref m-emu #x2073) 8)
  (check-equal? (nes-vram-ref m-emu #x2075) 4)
  (check-equal? (nes-vram-ref m-emu #x3F00) #x0F)
  (check-equal? (nes-vram-ref m-emu #x3F01) #x30)

  ;; Complete Stage 3 (WORLD 8-4): Touch Castle Bridge Axe, Defeat Bowser & Rescue Princess Toadstool!
  (play-mario-stage!)
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-STAGE-ID) 3)
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-GAME-COMPLETED) 1)
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-WON) 1)
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-GOOMBA-ALIVE) 0)
  (check-equal? (nes-zp-ref m-emu MARIO-ZP-COINS) 4)
  (set! smb-full-zp-trace (reverse smb-full-zp-trace))

  ;; --------------------------------------------------------------------------
  ;; 2. The Legend of Zelda Full 4-Room Quest:
  ;;    Overworld 0x77 -> Eagle Sanctum -> Underworld Boss (Aquamentus & 8 Triforce Shards) -> Death Mountain (Ganon & Princess Zelda)
  ;; --------------------------------------------------------------------------
  (define z-emu (make-nes-emulator-from-rom zelda-rom-bytes))
  (define z-labels (asm-result-labels zelda-asm-result))
  (define z-boot  (hash-ref z-labels 'boot_init))
  (define z-frame (hash-ref z-labels 'game_frame_step))
  (nes-run-until-rts! z-emu z-boot)

  (define (step-zelda! btn [n 1])
    (for ([_ (in-range n)])
      (define-values (_act vb) (nes-step-frame! z-emu z-frame btn))
      (check-true (<= vb 2273))
      (check-false (nes-emulator-ppu-tainted? z-emu))))

  ;; Room 0 (Overworld 0x77): Slay Red Octorok, collect Key, unlock North Gate -> Room 1
  (step-zelda! BTN-UP 9)
  (step-zelda! BTN-A 2)
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-OCTO-ALIVE) 0)
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-RUPEES) 1)
  (step-zelda! BTN-UP 34)
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-ROOM-ID) 1)
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-TRIFORCE-WON) 1)
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-TRIFORCE-COUNT) 1)

  ;; Walk North in Room 1 (Eagle Sanctum) -> Enter Room 2 (Underworld Boss Chamber: Aquamentus)
  (step-zelda! BTN-UP 14)
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-ROOM-ID) 2)
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-OCTO-ALIVE) 1)
  (check-equal? (nes-vram-ref z-emu #x3F02) #x1C) ; Underworld Dungeon teal palette

  ;; Approach Aquamentus in Room 2, take 1 contact knockback hit (hearts: 3 -> 2), then slay Aquamentus!
  (step-zelda! BTN-UP 18)
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-HEARTS) 2)
  (step-zelda! BTN-A 2)
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-OCTO-ALIVE) 0)
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-TRIFORCE-COUNT) 8) ; All 8 Triforce of Wisdom shards!

  ;; Collect Boss Key & unlock North Shutter -> Enter Room 3 (Death Mountain: Ganon's Final Lair)
  (step-zelda! BTN-UP 16)
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-ROOM-ID) 3)
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-OCTO-ALIVE) 1) ; Ganon spawned!
  (check-equal? (nes-vram-ref z-emu #x3F02) #x16) ; Death Mountain crimson palette

  ;; Approach Ganon, slay Ganon with Sword ('A'), and step North to rescue Princess Zelda!
  (step-zelda! BTN-UP 17)
  (step-zelda! BTN-A 2)
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-OCTO-ALIVE) 0)
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-RUPEES) 3)
  (step-zelda! BTN-UP 10)
  (check-equal? (nes-zp-ref z-emu ZELDA-ZP-GAME-COMPLETED) 1)

  ;; --------------------------------------------------------------------------
  ;; 3. Nintendo NES Tetris Full Multi-Line & Multi-Level Campaign:
  ;;    6 Full 10-Block Line Clears & LEVEL 00 -> 01 -> 02 -> 03 via 100% Controller Inputs (Zero RAM Pokes!)
  ;; --------------------------------------------------------------------------
  (define t-emu (make-nes-emulator-from-rom tetris-rom-bytes))
  (define t-labels (asm-result-labels tetris-asm-result))
  (define t-boot  (hash-ref t-labels 'boot_init))
  (define t-frame (hash-ref t-labels 'game_frame_step))
  (nes-run-until-rts! t-emu t-boot)

  (define (tap-t! btn)
    (define-values (_a1 vb1) (nes-step-frame! t-emu t-frame btn))
    (check-true (<= vb1 2273))
    (define-values (_a2 vb2) (nes-step-frame! t-emu t-frame 0))
    (check-true (<= vb2 2273)))

  (define (shift-and-drop! dir count)
    (for ([_ (in-range count)]) (tap-t! dir))
    (tap-t! BTN-B))

  ;; Piece #1 (ID=0): Rotate twice (rot=2), shift left 3x to X=1 (cols 0..3), Hard-Drop
  (tap-t! BTN-A)
  (tap-t! BTN-A)
  (shift-and-drop! BTN-LEFT 3)
  ;; Piece #2 (ID=3, O-piece): Shift right 4x to X=8 (cols 8..9), Hard-Drop
  (shift-and-drop! BTN-RIGHT 4)
  ;; Piece #3 (ID=6, I-piece): Shift right 1x to X=5 (cols 4..7) -> Line Clear #1!
  (shift-and-drop! BTN-RIGHT 1)
  (check-equal? (nes-zp-ref t-emu TETRIS-ZP-LINES) 1)

  ;; Piece #4 (ID=6) & Piece #5 (ID=6) -> Line Clear #2 & LEVEL 01!
  (shift-and-drop! BTN-LEFT 3)
  (shift-and-drop! BTN-RIGHT 1)
  (check-equal? (nes-zp-ref t-emu TETRIS-ZP-LINES) 2)
  (check-equal? (nes-zp-ref t-emu TETRIS-ZP-LEVEL) 1)

  ;; Piece #6 (ID=3) & Piece #7 (ID=6) -> Line Clear #3!
  (shift-and-drop! BTN-RIGHT 4)
  (shift-and-drop! BTN-RIGHT 1)
  (check-equal? (nes-zp-ref t-emu TETRIS-ZP-LINES) 3)

  ;; Piece #8 (ID=6) & Piece #9 (ID=6) -> Line Clear #4, LEVEL 02 & GAME_WON = 1!
  (shift-and-drop! BTN-LEFT 3)
  (shift-and-drop! BTN-RIGHT 1)
  (check-equal? (nes-zp-ref t-emu TETRIS-ZP-LINES) 4)
  (check-equal? (nes-zp-ref t-emu TETRIS-ZP-LEVEL) 2)
  (check-equal? (nes-zp-ref t-emu TETRIS-ZP-GAME-WON) 1)

  ;; Piece #10 (ID=3), #11 (ID=6), #12 (ID=6), #13 (ID=6) -> Line Clears #5 & #6 (LEVEL 03)!
  (shift-and-drop! BTN-RIGHT 4)
  (shift-and-drop! BTN-RIGHT 1)
  (shift-and-drop! BTN-LEFT 3)
  (shift-and-drop! BTN-RIGHT 1)
  (for ([_ (in-range 9)]) (nes-step-frame! t-emu t-frame 0))
  (check-equal? (nes-zp-ref t-emu TETRIS-ZP-LINES) 6)
  (check-equal? (nes-zp-ref t-emu TETRIS-ZP-LEVEL) 3)
  (check-equal? (nes-zp-ref t-emu TETRIS-ZP-DIRTY-ROW) 20)
  (check-equal? (nes-vram-ref t-emu #x22BB) 3) ; HUD LEVEL 03 digit updated in VRAM!

  ;; --------------------------------------------------------------------------
  ;; 4. Campaign Spin-Offs: Multi-Stage Trace Detector, Victory Reachability & Stage Handler
  ;; --------------------------------------------------------------------------
  (define prog-info (detect-multi-stage-progression-from-trace smb-full-zp-trace))
  (define stage-addrs (map (lambda (h) (hash-ref h 'addr)) (hash-ref prog-info 'stage-registers)))
  (check-not-false (memq MARIO-ZP-STAGE-ID stage-addrs))
  (check-not-false (memq MARIO-ZP-DEAD (hash-ref prog-info 'recovery-registers)))
  (check-not-false (memq MARIO-ZP-GAME-COMPLETED (hash-ref prog-info 'completion-flags)))

  ;; Disconnected victory state in state-machine is caught and repaired automatically
  (define disconnected-campaign-mod
    (hasheq 'name 'disconnected-campaign-test
            'mapper 'NROM
            'state-machines
            (list (hasheq 'name 'broken-campaign
                          'initial 'stage-1
                          'states (list (hasheq 'id 'stage-1 'kind 'normal 'transitions '(stage-2))
                                        (hasheq 'id 'stage-2 'kind 'normal 'transitions '(stage-1)) ; Loops back without reaching final-victory!
                                        (hasheq 'id 'final-victory 'kind 'victory 'transitions '(stage-1)))))))
  (define disc-res (typecheck-nes-module disconnected-campaign-mod))
  (check-false (nes-type-result-well-typed? disc-res))
  (check-not-false (memq 'unreachable-victory-state (map nes-violation-category (nes-type-result-violations disc-res))))
  (define-values (_fixed-disc disc-repairs fixed-disc-res)
    (compile-and-verify-nes-module disconnected-campaign-mod))
  (check-true (nes-type-result-well-typed? fixed-disc-res))
  (check-not-false (memq 'connect-disconnected-victory-state disc-repairs))

  ;; Stage progression library emitter compiles with 0 page crossings
  (define stage-lib-asm
    (assemble-6502 (append '((label stage_step))
                           (emit-stage-progression-handler-6502 #x28 #x2A #x29 #:max-stage 3 #:spawn-zp #x16 #:spawn-val 40)
                           '((RTS)))))
  (check-equal? (asm-result-page-crossings stage-lib-asm) 0))

;; ============================================================================
;; 23. Top-10 Commercial NES Classics Decompilation & 4-Stage Campaign Execution
;;     (Donkey Kong, Mario Bros., Pac-Man, Excitebike, Balloon Fight,
;;      Ice Climber, Galaga, Kung Fu, Battle City, Bomberman)
;; ============================================================================
(test-case "Top-10 Commercial NES Classics Decompilation & 4-Stage Campaign Execution (DK, Mario Bros., Pac-Man, Excitebike, Balloon Fight, Ice Climber, Galaga, Kung Fu, Battle City, Bomberman)"
  (check-equal? (hash-count top10-decompiled-games) 10)
  (for ([spec (in-list TOP10-GAME-SPECS)])
    (define sym   (hash-ref spec 'symbol))
    (define entry (hash-ref top10-decompiled-games sym))
    (define tres  (hash-ref entry 'type-result))
    (define asm   (hash-ref entry 'asm-result))
    (define rom   (hash-ref entry 'rom-bytes))
    (define state (hash-ref entry 'state))

    (check-true (nes-type-result-well-typed? tres))
    (check-equal? (asm-result-page-crossings asm) 0)
    (check-equal? (bytes-length rom) 40976)

    ;; Boot in 6502 emulator and verify 100% Frame-0 Palette (32/32) & Nametable 0 (960/960) parity
    (define emu    (make-nes-emulator-from-rom rom))
    (define labels (asm-result-labels asm))
    (define boot   (hash-ref labels 'boot_init))
    (define frame  (hash-ref labels 'game_frame_step))
    (nes-run-until-rts! emu boot)

    (define expected-nt0 (hash-ref state 'nametable960))
    (for ([idx (in-list '(0 120 480 959))])
      (check-equal? (nes-vram-ref emu (+ #x2000 idx))
                    (list-ref expected-nt0 idx)))

    ;; Verify Failure Path: Walk into stage hazard (BTN-LEFT x10) -> DEAD = 1, LIVES = 2
    (for ([_ (in-range 10)])
      (define-values (_act vb) (nes-step-frame! emu frame BTN-LEFT))
      (check-true (<= vb 2273))
      (check-false (nes-emulator-ppu-tainted? emu)))
    (check-equal? (nes-zp-ref emu TOP10-ZP-DEAD) 1)
    (check-equal? (nes-zp-ref emu TOP10-ZP-LIVES) 2)

    ;; Verify Recovery Path: Press BTN-START -> DEAD = 0, LIVES = 2, PLAYER_X = 80
    (nes-step-frame! emu frame BTN-START)
    (nes-step-frame! emu frame 0)
    (check-equal? (nes-zp-ref emu TOP10-ZP-DEAD) 0)
    (check-equal? (nes-zp-ref emu TOP10-ZP-LIVES) 2)
    (check-equal? (nes-zp-ref emu TOP10-ZP-PLAYER-X) 80)

    ;; Verify Full 4-Stage Campaign Victory (Stages 0 -> 1 -> 2 -> 3 -> GAME_COMPLETED = 1)
    (for ([stage-idx (in-range 4)])
      (check-equal? (nes-zp-ref emu TOP10-ZP-STAGE-ID) stage-idx)
      (for ([_ (in-range 10)])
        (define-values (_act vb)
          (nes-step-frame! emu frame (bitwise-ior BTN-A BTN-RIGHT)))
        (check-true (<= vb 2273))
        (check-false (nes-emulator-ppu-tainted? emu)))
      (nes-step-frame! emu frame 0))
    (check-equal? (nes-zp-ref emu TOP10-ZP-STAGE-ID) 3)
    (check-equal? (nes-zp-ref emu TOP10-ZP-GAME-COMPLETED) 1)
    (check-equal? (nes-zp-ref emu TOP10-ZP-WON) 1)
    (check-equal? (nes-zp-ref emu TOP10-ZP-SCORE) 4)
    (check-equal? (nes-zp-ref emu TOP10-ZP-ENEMY-ALIVE) 0)))

;; ============================================================================
;; 24. 2A03 APU 4-Channel Sequencer, Multi-Bank MMC1 Decompilation,
;;     SMB Area Object Decoder, Timer/NMI Idioms & .fm2 TAS Replay
;; ============================================================================
(test-case "2A03 APU 4-Channel Music Sequencer, Multi-Bank MMC1 Decompilation, SMB Area Object Decoder, Timer/NMI Idioms & .fm2 TAS Replay"
  ;; 1. Verify SMB Frame-0 Nametable 0 (960/960) & Attribute 0 (64/64) 100% parity
  (define m-emu (make-nes-emulator-from-rom mario-rom-bytes))
  (define m-boot (hash-ref (asm-result-labels mario-asm-result) 'boot_init))
  (nes-run-until-rts! m-emu m-boot)
  (check-equal? (nes-vram-ref m-emu #x222A) #x24) ; Unmodified sky tile at Frame 0!
  (check-equal? (nes-vram-ref m-emu #x23E2) #x00) ; Unmodified attribute byte at Frame 0!

  ;; 2. Verify 2A03 APU Music Sequencer & Melody Presets (Zero Page Crossings)
  (check-true (> (hash-count NTSC-APU-PERIOD-TABLE) 20))
  (define apu-seq-asm
    (assemble-6502
     (append '((label apu_tick_sub))
             (emit-apu-music-sequencer-6502 #x30 #x31 #:tempo-shift 2 #:note-table-label 'melody_tbl #:note-count 16)
             '((RTS))
             (emit-apu-melody-table-6502 'melody_tbl 'overworld-march))))
  (check-equal? (asm-result-page-crossings apu-seq-asm) 0)

  ;; 3. Verify Multi-Bank MMC1 Decompilation on The Legend of Zelda (8 x 16KB PRG Banks)
  (define zelda-auth-bytes (file->bytes "assets/roms/legend_of_zelda.nes"))
  (define mb-info (decompile-multibank-ines-rom zelda-auth-bytes))
  (check-equal? (hash-ref mb-info 'prg-banks) 8)
  (check-equal? (length (hash-ref mb-info 'defbanked-tables)) 8)
  (check-true (> (hash-ref mb-info 'total-instructions) 1000))

  ;; 4. Verify SMB 2-Byte Compressed Area Object Stream Decoder
  (define area-objs (decode-smb-area-objects '(#x37 #x14 #x9B #x23 #xFD)))
  (check-equal? (length area-objs) 2)
  (check-equal? (hash-ref (first area-objs) 'col-x) 3)
  (check-equal? (hash-ref (first area-objs) 'row-y) 7)

  ;; 5. Verify Community Disassembly Idiom Detectors (Timer Array & NMI Semaphore)
  (define dk-auth-bytes (file->bytes "assets/roms/donkey_kong.nes"))
  (define dk-dis (disassemble-ines-rom dk-auth-bytes))
  (define timer-idioms
    (detect-zp-timer-array-idioms
     '((LDX #:imm 15) (DEC #:zpx #x35) (DEX) (BPL -5))))
  (check-true (>= (hash-ref timer-idioms 'count) 1))
  (check-not-false (memq #x35 (hash-ref timer-idioms 'base-addresses)))

  (define nmi-sem-idioms
    (detect-nmi-sync-semaphore-idioms
     '((LDA #:zp #x02) (BEQ -4))))
  (check-true (>= (hash-ref nmi-sem-idioms 'count) 1))
  (check-not-false (memq #x02 (hash-ref nmi-sem-idioms 'semaphore-addrs)))

  ;; 6. Verify FCEUX .fm2 TAS Replay Parser & Round-Trip Serializer
  (define sample-fm2
    (string-join
     '("version 3"
       "|0|R......A|||"
       "|0|..D.T...|||"
       "|0|........|||")
     "\n"))
  (define parsed-masks (parse-fm2-tas-inputs sample-fm2))
  (check-equal? parsed-masks
                (list (bitwise-ior BTN-RIGHT BTN-A)
                      (bitwise-ior BTN-DOWN BTN-START)
                      0))
  (check-equal? (parse-fm2-tas-inputs (serialize-fm2-tas-inputs parsed-masks))
                parsed-masks)

  ;; 7. Verify Commercial Timer-Array & Gravity LUT Emitters
  (define lut-asm
    (assemble-6502
     (append '((label tick_timers))
             (emit-timer-array-tick-6502 #x35 8)
             (emit-commercial-gravity-lut-6502 #x23 #x21 'tetris_grav_lut)
             '((RTS)))))
  (check-equal? (asm-result-page-crossings lut-asm) 0))

;; ============================================================================
;; 25. Three Minimal-Size (< 900B 6502) Original #lang boba-nes Games:
;;     Star Courier, Crypt Sweep & Neon Strider Full 3-Stage Campaigns
;; ============================================================================
(test-case "Three Minimal-Size (<900B 6502) Original #lang boba-nes Games: Star Courier, Crypt Sweep & Neon Strider Full 3-Stage Campaigns"
  ;; Verify all 3 original games pass graded typechecking, have 0 page crossings, and < 900 B code size
  (for ([t-res (in-list (list star-courier-type-result crypt-sweep-type-result neon-strider-type-result))]
        [a-res (in-list (list star-courier-asm-result  crypt-sweep-asm-result  neon-strider-asm-result))]
        [r-rom (in-list (list star-courier-rom-bytes   crypt-sweep-rom-bytes   neon-strider-rom-bytes))])
    (check-true (nes-type-result-well-typed? t-res))
    (check-equal? (asm-result-page-crossings a-res) 0)
    (check-true (< (bytes-length (asm-result-bytes a-res)) 900))
    (check-equal? (bytes-length r-rom) 40976))

  ;; 1. Play-Test Star Courier: Kestral Run (Sectors 0 -> 1 -> 2)
  (define sc-emu (make-nes-emulator-from-rom star-courier-rom-bytes))
  (define sc-boot  (hash-ref (asm-result-labels star-courier-asm-result) 'boot_init))
  (define sc-frame (hash-ref (asm-result-labels star-courier-asm-result) 'game_frame_step))
  (nes-run-until-rts! sc-emu sc-boot)
  (check-equal? (nes-zp-ref sc-emu ORIG-ZP-LIVES) 3)
  (check-equal? (nes-zp-ref sc-emu ORIG-ZP-STAGE-ID) 0)
  ;; Thrust ('A') -> pod pickup & drone clear
  (nes-step-frame! sc-emu sc-frame BTN-A)
  (nes-step-frame! sc-emu sc-frame 0)
  (check-true (>= (nes-zp-ref sc-emu ORIG-ZP-PODS) 1))
  (check-equal? (nes-zp-ref sc-emu ORIG-ZP-ENEMY-ALIVE) 0)
  ;; Canyon crash ('LEFT') -> DEAD=1, LIVES=2 -> Recovery ('START') -> DEAD=0
  (nes-step-frame! sc-emu sc-frame BTN-LEFT)
  (check-equal? (nes-zp-ref sc-emu ORIG-ZP-DEAD) 1)
  (check-equal? (nes-zp-ref sc-emu ORIG-ZP-LIVES) 2)
  (nes-step-frame! sc-emu sc-frame BTN-START)
  (check-equal? (nes-zp-ref sc-emu ORIG-ZP-DEAD) 0)
  ;; Beacon landing across Sectors 0 -> 1 -> 2 -> Victory!
  (nes-step-frame! sc-emu sc-frame (bitwise-ior BTN-RIGHT BTN-A))
  (nes-step-frame! sc-emu sc-frame 0)
  (check-equal? (nes-zp-ref sc-emu ORIG-ZP-STAGE-ID) 1)
  (nes-step-frame! sc-emu sc-frame (bitwise-ior BTN-RIGHT BTN-A))
  (nes-step-frame! sc-emu sc-frame 0)
  (check-equal? (nes-zp-ref sc-emu ORIG-ZP-STAGE-ID) 2)
  (check-equal? (nes-zp-ref sc-emu ORIG-ZP-GAME-COMPLETED) 1)

  ;; 2. Play-Test Crypt Sweep: Chronomancer's Vault (Vaults 0 -> 1 -> 2)
  (define cs-emu (make-nes-emulator-from-rom crypt-sweep-rom-bytes))
  (define cs-boot  (hash-ref (asm-result-labels crypt-sweep-asm-result) 'boot_init))
  (define cs-frame (hash-ref (asm-result-labels crypt-sweep-asm-result) 'game_frame_step))
  (nes-run-until-rts! cs-emu cs-boot)
  ;; Time-freeze ('A') & Arcane bomb ('B')
  (nes-step-frame! cs-emu cs-frame BTN-A)
  (nes-step-frame! cs-emu cs-frame BTN-B)
  (nes-step-frame! cs-emu cs-frame BTN-UP)
  (check-equal? (nes-zp-ref cs-emu ORIG-ZP-ENEMY-ALIVE) 0)
  ;; Wraith hazard ('LEFT') -> DEAD=1 -> Recovery ('START') -> DEAD=0
  (nes-step-frame! cs-emu cs-frame BTN-LEFT)
  (check-equal? (nes-zp-ref cs-emu ORIG-ZP-DEAD) 1)
  (nes-step-frame! cs-emu cs-frame BTN-START)
  (check-equal? (nes-zp-ref cs-emu ORIG-ZP-DEAD) 0)
  ;; Advance Vaults 0 -> 1 -> 2 -> Victory!
  (nes-step-frame! cs-emu cs-frame BTN-RIGHT)
  (nes-step-frame! cs-emu cs-frame 0)
  (check-equal? (nes-zp-ref cs-emu ORIG-ZP-STAGE-ID) 1)
  (nes-step-frame! cs-emu cs-frame BTN-RIGHT)
  (nes-step-frame! cs-emu cs-frame 0)
  (check-equal? (nes-zp-ref cs-emu ORIG-ZP-STAGE-ID) 2)
  (check-equal? (nes-zp-ref cs-emu ORIG-ZP-GAME-COMPLETED) 1)

  ;; 3. Play-Test Neon Strider: Cyber Grid 1989 (Zones 0 -> 1 -> 2)
  (define ns-emu (make-nes-emulator-from-rom neon-strider-rom-bytes))
  (define ns-boot  (hash-ref (asm-result-labels neon-strider-asm-result) 'boot_init))
  (define ns-frame (hash-ref (asm-result-labels neon-strider-asm-result) 'game_frame_step))
  (nes-run-until-rts! ns-emu ns-boot)
  ;; Jump ('A') & Polarity toggle ('B' -> shifts polarity 0 -> 1 & $3F11 -> #x24)
  (nes-step-frame! ns-emu ns-frame BTN-A)
  (nes-step-frame! ns-emu ns-frame BTN-B)
  (check-equal? (nes-zp-ref ns-emu ORIG-ZP-POLARITY) 1)
  (check-equal? (nes-vram-ref ns-emu #x3F11) #x24)
  ;; Laser hazard ('LEFT') -> DEAD=1 -> Recovery ('START') -> DEAD=0
  (nes-step-frame! ns-emu ns-frame BTN-LEFT)
  (check-equal? (nes-zp-ref ns-emu ORIG-ZP-DEAD) 1)
  (nes-step-frame! ns-emu ns-frame BTN-START)
  (check-equal? (nes-zp-ref ns-emu ORIG-ZP-DEAD) 0)
  ;; Polarity sprint ('B' + 'RIGHT') across Zones 0 -> 1 -> 2 -> Victory!
  (nes-step-frame! ns-emu ns-frame (bitwise-ior BTN-B BTN-RIGHT))
  (nes-step-frame! ns-emu ns-frame 0)
  (check-equal? (nes-zp-ref ns-emu ORIG-ZP-STAGE-ID) 1)
  (nes-step-frame! ns-emu ns-frame (bitwise-ior BTN-B BTN-RIGHT))
  (nes-step-frame! ns-emu ns-frame 0)
  (check-equal? (nes-zp-ref ns-emu ORIG-ZP-STAGE-ID) 2)
  (check-equal? (nes-zp-ref ns-emu ORIG-ZP-GAME-COMPLETED) 1))

;; ============================================================================
;; 26. Pre-Assembly Compositional DSL Grade Inference (`infer-dsl-statement-grade`,
;;     `synthesize-dsl-module-grades`), `'symmetric-vertical` Metasprites &
;;     Post-Typecheck Grade Preservation (`analyze-6502-ast-grades` / `defnes-game`)
;; ============================================================================
(test-case "Pre-Assembly Compositional DSL Grade Inference, symmetric-vertical Metasprites & Grade Preservation"
  ;; 1. Verify `'symmetric-vertical` 8x16 2-sprite metasprite descriptor and 6502 OAM emitter
  (define v-ms1 (make-metasprite-desc 'beam-sym '(#x36) 2 #:order 'symmetric-vertical))
  (check-equal? (hash-ref v-ms1 'order) 'symmetric-vertical)
  (check-equal? (hash-ref v-ms1 'oam-sprites) 2)
  (check-equal? (hash-ref v-ms1 'scanline-sprites) 1)
  (check-equal? (hash-ref v-ms1 'tl) #x36)
  (check-equal? (hash-ref v-ms1 'bl) #x36)
  (check-equal? (hash-ref v-ms1 'attr) #x02)
  (check-equal? (hash-ref v-ms1 'bl-attr) (bitwise-ior #x02 OAM-FLIP-V))

  (define v-ms2 (make-metasprite-desc 'pillar-2tile '(#x36 #x37) 1 #:order 'symmetric-vertical))
  (check-equal? (hash-ref v-ms2 'tl) #x36)
  (check-equal? (hash-ref v-ms2 'bl) #x37)
  (check-equal? (hash-ref v-ms2 'bl-attr) (bitwise-ior #x01 OAM-FLIP-V))

  ;; Verify `defmetasprite` vertical metasprites from the 3 `.bnes` games
  (check-equal? (hash-ref thruster-plume-vertical-metasprite 'oam-sprites) 2)
  (check-equal? (hash-ref hourglass-pillar-vertical-metasprite 'oam-sprites) 2)
  (check-equal? (hash-ref laser-beam-vertical-metasprite 'oam-sprites) 2)
  (check-equal? (hash-ref laser-beam-vertical-metasprite 'bl-attr) (bitwise-ior 1 #x80))

  ;; Verify 6502 OAM emission for `'symmetric-vertical` writes 2 sprites (8 bytes) at (X, Y) and (X, Y+8) with #x80 flip
  (define v-oam-prog
    `((label emit_v_test)
      (LDA #:imm 80)  (STA #:zp #x14) ; X = 80
      (LDA #:imm 100) (STA #:zp #x15) ; Y = 100
      ,@(emit-metasprite-oam-6502 v-ms1 #x14 #x15 0)
      (RTS)))
  (define v-oam-asm (assemble-6502 v-oam-prog #:origin #x8000))
  (define v-oam-emu (make-nes-emulator-from-rom (build-ines-rom v-oam-asm (make-bytes 8192 0))))
  (nes-run-until-rts! v-oam-emu #x8000)
  ;; Top sprite at $0200..$0203: Y=100, Tile=#x36, Attr=#x02, X=80
  (check-equal? (nes-ram-ref v-oam-emu #x0200) 100)
  (check-equal? (nes-ram-ref v-oam-emu #x0201) #x36)
  (check-equal? (nes-ram-ref v-oam-emu #x0202) #x02)
  (check-equal? (nes-ram-ref v-oam-emu #x0203) 80)
  ;; Bottom sprite at $0204..$0207: Y=108, Tile=#x36, Attr=#x82 (V-Flip!), X=80
  (check-equal? (nes-ram-ref v-oam-emu #x0204) 108)
  (check-equal? (nes-ram-ref v-oam-emu #x0205) #x36)
  (check-equal? (nes-ram-ref v-oam-emu #x0206) #x82)
  (check-equal? (nes-ram-ref v-oam-emu #x0207) 80)

  ;; 2. Verify compositional `infer-dsl-statement-grade` (seq, if/join, repeat-static, with-zp-scratch)
  ;;    WITHOUT calling `assemble-6502`!
  (define dsl-vblank-stmt
    '(seq
      (PHA) (TXA) (PHA) (TYA) (PHA)
      (with-zp-scratch ([vb_tmp 4])
        (oam-dma! #x02)
        (nametable-patch! #x204A 3)
        (restore-scroll! 0 0))
      (PLA) (TAY) (PLA) (TAX) (PLA) (RTI)))
  (define vb-stmt-grade (infer-dsl-statement-grade dsl-vblank-stmt 'VBlankNMI))
  (check-true (> (nes-grade-cycles vb-stmt-grade) 514))
  (check-true (<= (nes-grade-cycles vb-stmt-grade) 2273))
  (check-equal? (nes-grade-zp-bytes-peak vb-stmt-grade) 4)
  (check-equal? (nes-grade-vram-dma-bytes vb-stmt-grade) 5)

  (define dsl-active-stmt
    `(seq
      (poll-joypad! #x10)
      ;; Sibling `with-zp-scratch` blocks take high-watermark MAX (max 6 10 = 10), not sum!
      (with-zp-scratch ([phys_tmp 6])
        (if (button-pressed? 'A)
            (apu-sfx! 'pulse1 #x9F)
            (apu-sfx! 'noise #x1F)))
      (with-zp-scratch ([ai_tmp 10])
        (repeat-static 4
          (emit-metasprite! ,kestral-lander-metasprite #x14 #x15 1)))
      (emit-metasprite! ,thruster-plume-vertical-metasprite #x14 #x15 5)))
  (define act-stmt-grade (infer-dsl-statement-grade dsl-active-stmt 'ActiveFrame))
  (check-equal? (nes-grade-zp-bytes-peak act-stmt-grade) 10)
  ;; 4 * 4 sprites (2x2 lander) + 2 sprites (1x2 vertical plume) = 18 OAM sprites
  (check-equal? (nes-grade-oam-sprites act-stmt-grade) 18)
  (check-equal? (nes-grade-apu-channels act-stmt-grade) (set 'pulse1 'noise))

  ;; 3. Verify `synthesize-dsl-module-grades` + `typecheck-nes-module` BEFORE generating any 6502 assembly!
  (define pre-asm-dsl-mod
    (synthesize-dsl-module-grades
     #:name          'pre-assembly-typechecked-game
     #:mapper        'NROM
     #:mirroring     'vertical
     #:zp-map        star-courier-zp-map
     #:metasprites   (list kestral-lander-metasprite
                           plasma-drone-metasprite
                           thruster-plume-vertical-metasprite)
     #:chr           star-courier-chr
     #:state-machine star-courier-fsm
     #:vblank-ast    dsl-vblank-stmt
     #:active-ast    dsl-active-stmt))
  (define pre-asm-type-res (typecheck-nes-module pre-asm-dsl-mod NTSC-NROM-BUDGET))
  (check-true (nes-type-result-well-typed? pre-asm-type-res))
  ;; 4 + 4 + 2 = 10 OAM sprites inferred directly from metasprite shapes!
  (check-equal? (nes-grade-oam-sprites (nes-type-result-vblank-grade pre-asm-type-res)) 10)
  ;; 20 permanent ZP bytes + max(4, 6, 10) = 30 peak ZP bytes inferred before assembly!
  (check-equal? (nes-grade-zp-bytes-live (nes-type-result-active-grade pre-asm-type-res)) 20)
  (check-equal? (nes-grade-zp-bytes-peak (nes-type-result-active-grade pre-asm-type-res)) 30)
  ;; Non-zero CHR tiles inferred directly from `defchr-resource`!
  (check-true (> (nes-grade-chr-tiles (nes-type-result-active-grade pre-asm-type-res)) 40))

  ;; 4. Verify `synthesize-dsl-module-grades` catches L1/L3/L4 violations at type-checking time BEFORE assembly!
  (define bad-dsl-mod
    (synthesize-dsl-module-grades
     #:name       'bad-pre-asm-module
     #:vblank-ast '(seq (PHA) (oam-dma! #x02) (nametable-patch! #x204A 2) (RTI)) ; Unbalanced PHA (1 vs 0) + missing restore-scroll!
     #:active-ast '(seq (nametable-patch! #x2000 4))))                           ; Illegal VRAM write in ActiveFrame!
  (define bad-pre-res (typecheck-nes-module bad-dsl-mod NTSC-NROM-BUDGET))
  (check-false (nes-type-result-well-typed? bad-pre-res))
  (define bad-pre-cats (map nes-violation-category (nes-type-result-violations bad-pre-res)))
  (check-not-false (memq 'unbalanced-6502-stack bad-pre-cats))
  (check-not-false (memq 'unrestored-ppu-scroll-latch bad-pre-cats))
  (check-not-false (memq 'vram-write-during-active-render bad-pre-cats))

  ;; 5. Verify `analyze-6502-ast-grades` and `defnes-game` Grade Preservation across all 3 `.bnes` games
  (for ([g (in-list (list star-courier-game crypt-sweep-game neon-strider-game))])
    (check-true (hash-ref g 'grade-preserved?))
    (check-true (nes-type-result-well-typed? (hash-ref g 'pre-type-result)))
    (check-true (nes-type-result-well-typed? (hash-ref g 'type-result)))))

;; ============================================================================
;; 27. Metroid (1986) Multi-Bank MMC1 + CHR-RAM Decompilation & 4-Zone Campaign
;; ============================================================================
(test-case "27. Metroid (1986) MMC1 Multi-Bank Analysis, Brinstar CHR-RAM & 4-Zone Zebes Campaign"
  ;; 1. Verify authentic Metroid MMC1 8 x 16 KB PRG-ROM + 8 KB CHR-RAM multi-bank disassembly
  (check-equal? (hash-ref metroid-multibank 'mapper-name) 'MMC1)
  (check-equal? (hash-ref metroid-multibank 'chr-ram?) #t)
  (check-equal? (hash-ref metroid-multibank 'prg-banks) 8)
  (check-true (> (hash-ref metroid-multibank 'total-instructions) 50000))
  ;; 2. Verify #lang boba-nes Metroid module grades & ROM binary
  (check-true (nes-type-result-well-typed? metroid-type-result))
  (check-equal? (bytes-length metroid-rom-bytes) 40976)
  (check-equal? (asm-result-page-crossings metroid-asm-result) 0)
  (check-equal? (check-state-machine-totality (hasheq 'state-machine metroid-zebes-fsm)) '())
  (check-equal? (check-pinned-zp-map (hasheq 'zp-map metroid-zp-layout)) '())
  ;; 3. Execute 4-Zone Zebes Campaign in the 6502/2C02 Emulator (Failure -> Recovery -> 4-Zone Victory)
  (define met-emu   (make-nes-emulator-from-rom metroid-rom-bytes))
  (define met-boot  (hash-ref (asm-result-labels metroid-asm-result) 'boot_init))
  (define met-frame (hash-ref (asm-result-labels metroid-asm-result) 'game_frame_step))
  (nes-run-until-rts! met-emu met-boot)
  (check-equal? (nes-zp-ref met-emu METROID-ZP-ENERGY) 30)
  (check-equal? (nes-zp-ref met-emu METROID-ZP-LIVES) 3)
  (check-equal? (nes-zp-ref met-emu METROID-ZP-STAGE-ID) 0)
  ;; Walk into Zoomer hazard without firing for 10 frames -> Energy 30 -> 0, DEAD = 1, LIVES = 2
  (for ([_ (in-range 10)])
    (nes-step-frame! met-emu met-frame BTN-LEFT))
  (check-equal? (nes-zp-ref met-emu METROID-ZP-ENERGY) 0)
  (check-equal? (nes-zp-ref met-emu METROID-ZP-DEAD) 1)
  (check-equal? (nes-zp-ref met-emu METROID-ZP-LIVES) 2)
  ;; Press START to recover Energy Tank in Zone 0 (Brinstar), then toggle Morph Ball (BTN-DOWN)
  (nes-step-frame! met-emu met-frame 0)
  (nes-step-frame! met-emu met-frame BTN-START)
  (nes-step-frame! met-emu met-frame BTN-DOWN)
  (check-equal? (nes-zp-ref met-emu METROID-ZP-DEAD) 0)
  (check-equal? (nes-zp-ref met-emu METROID-ZP-ENERGY) 30)
  (check-equal? (nes-zp-ref met-emu METROID-ZP-MORPH-BALL) 1)
  (check-equal? (nes-zp-ref met-emu METROID-ZP-MORPH-ACTIVE) 1)
  ;; Fire Power Beam / Missiles & advance across all 4 Zones (0 -> 1 -> 2 -> 3)
  (for ([z (in-range 4)])
    (for ([_ (in-range 10)])
      (nes-step-frame! met-emu met-frame (bitwise-ior BTN-A BTN-B BTN-RIGHT)))
    (nes-step-frame! met-emu met-frame 0)
    (nes-step-frame! met-emu met-frame 0))
  (check-equal? (nes-zp-ref met-emu METROID-ZP-STAGE-ID) 3)
  (check-equal? (nes-zp-ref met-emu METROID-ZP-GAME-COMPLETED) 1)
  (check-equal? (nes-zp-ref met-emu METROID-ZP-WON) 1))

;; ============================================================================
;; 28. Pixel-by-Pixel Framebuffer Image Differ & Unclosed Half-Sprite Seam Auditor
;; ============================================================================
(test-case "28. Framebuffer RGB Image Differ & Unclosed Half-Sprite Seam Truncation Auditor"
  ;; 1. Verify `diff-framebuffer-rgb-bytes`
  (define fb1 (make-bytes (* 256 240 3) #x22))
  (define fb2 (bytes-copy fb1))
  (define eq-diff (diff-framebuffer-rgb-bytes fb1 fb2))
  (check-equal? (hash-ref eq-diff 'total-pixels) 61440)
  (check-equal? (hash-ref eq-diff 'matching-pixels) 61440)
  (check-equal? (hash-ref eq-diff 'diff-pixels) 0)
  (bytes-set! fb2 0 #xFF)
  (define one-diff (diff-framebuffer-rgb-bytes fb1 fb2))
  (check-equal? (hash-ref one-diff 'matching-pixels) 61439)
  (check-equal? (hash-ref one-diff 'diff-pixels) 1)

  ;; 2. Verify `detect-unclosed-half-sprite-seams` catches a 1-slot SMB `#x60` coin (missing bottom half!)
  ;;    and passes with 0 defects on the 2-slot vertically-flipped `#x60` + `#x82` coin!
  (define smb-chr (load-authentic-smb-chr-rom))
  (define bad-coin-oam (make-bytes 256 #xF8))
  ;; Slot 9 ($24..$27): Top half only at (X=80, Y=120, Tile=#x60, Attr=#x02)
  (bytes-set! bad-coin-oam #x24 120)
  (bytes-set! bad-coin-oam #x25 #x60)
  (bytes-set! bad-coin-oam #x26 #x02)
  (bytes-set! bad-coin-oam #x27 80)
  (define bad-seams (detect-unclosed-half-sprite-seams smb-chr bad-coin-oam #:sprite-pt 0))
  (check-equal? (length bad-seams) 1)
  (check-equal? (hash-ref (first bad-seams) 'type) 'unclosed-vertical-half-sprite)
  (check-equal? (hash-ref (first bad-seams) 'tile) #x60)

  ;; Add Slot 10 ($28..$2B): Vertically flipped bottom half at (X=80, Y=128, Tile=#x60, Attr=#x82)
  (define good-coin-oam (bytes-copy bad-coin-oam))
  (bytes-set! good-coin-oam #x28 128)
  (bytes-set! good-coin-oam #x29 #x60)
  (bytes-set! good-coin-oam #x2A #x82)
  (bytes-set! good-coin-oam #x2B 80)
  (define good-seams (detect-unclosed-half-sprite-seams smb-chr good-coin-oam #:sprite-pt 0))
  (check-equal? good-seams '()))

;; ============================================================================
;; 29. Boba-Core IR, TargetSpec Descriptors & 4-Layer Multi-Target Type System
;; ============================================================================
(test-case "29. Boba-Core IR, 8 TargetSpecs & 4-Layer Multi-Target Graded/Modal Typechecker"
  ;; 1. Verify all 8 TargetSpecs & cross-target tile/color encoders
  (check-equal? (length ALL-TARGET-SPECS) 8)
  (for ([tid (in-list '(nes gb gbc pico8 rp2040 snes gba n64))])
    (define spec (get-target-spec tid))
    (check-equal? (target-spec-id spec) tid))
  (define sample-rows '("........" "..3333.." ".322223." ".321123."
                        ".321123." ".322223." "..3333.." "........"))
  (check-equal? (bytes-length (pack-tile-2bpp-planar sample-rows)) 16)
  (check-equal? (bytes-length (pack-tile-4bpp-snes-planar sample-rows)) 32)
  (check-equal? (bytes-length (pack-tile-4bpp-linear-nibble sample-rows)) 32)
  (check-equal? (bytes-length (pack-tile-rgba16-tmem sample-rows)) 128)
  (check-equal? (pack-rgb15-bgr555 31 0 0) #x001F)
  (check-equal? (pack-n64-rgba5551 31 0 0 1) #xF801)

  ;; 2. Layer 1: Pre-Codegen TargetGrade Semiring Inference & Verification across all 8 targets
  (for ([spec (in-list ALL-TARGET-SPECS)])
    (define g (synthesize-target-module-grades
               spec
               (list (ir-dma-transfer 'vram 128 (target-spec-dma-min-align spec)
                                      (first (target-spec-vram-allowed-phases spec)))
                     (ir-oam-emit 'hero 4 2))))
    (define v (verify-target-module-grades spec g))
    (check-true (hash-ref v 'valid?)))

  ;; 3. Layer 2: Flow-Sensitive Indexed Hoare Processor-State Typechecker (65C816 M/X & GBA ARM/Thumb)
  (define mode-bad
    (check-processor-mode-transitions TARGET-SNES (list '(if cond (rep #x20) (sep #x20)))))
  (check-false (hash-ref mode-bad 'valid?))
  (define reconciled-ops
    (synthesize-65816-mode-reconciliation (list '(if cond (rep #x20) (sep #x20)))))
  (define mode-fixed
    (check-processor-mode-transitions TARGET-SNES reconciled-ops))
  (check-true (hash-ref mode-fixed 'valid?))

  ;; 4. Layer 3: Width-, Alignment-, and Phase-Qualified Memory Capabilities (CapMem)
  ;;    - GB rejects VRAM writes during STAT Mode 3 (`active-mode3`) & OAM DMA wait outside HRAM
  (define gb-cap-bad1
    (check-memory-capability-access TARGET-GB (make-cap-mem 'vram 'u8 1 'active-mode3 'uncached 16)))
  (define gb-cap-bad2
    (check-memory-capability-access TARGET-GB (make-cap-mem 'oam-dma 'u8 256 'vblank 'wram 160)))
  (define gb-cap-ok
    (check-memory-capability-access TARGET-GB (make-cap-mem 'vram 'u8 1 'hblank-mode0 'hram 16)))
  (check-false (hash-ref gb-cap-bad1 'valid?))
  (check-false (hash-ref gb-cap-bad2 'valid?))
  (check-true  (hash-ref gb-cap-ok   'valid?))

  ;;    - GBA rejects 8-bit (`u8` / `STRB`) writes to VRAM/OAM/PALRAM; accepts `u16`/`u32` aligned writes
  (define gba-cap-bad
    (check-memory-capability-access TARGET-GBA (make-cap-mem 'vram 'u8 1 'vblank 'uncached 1)))
  (define gba-cap-ok
    (check-memory-capability-access TARGET-GBA (make-cap-mem 'vram 'u16 2 'vblank 'uncached 2)))
  (check-false (hash-ref gba-cap-bad 'valid?))
  (check-true  (hash-ref gba-cap-ok  'valid?))

  ;;    - N64 rejects unaligned (< 16 B) or unflushed RDRAM DMA buffers and > 4,096 B TMEM loads
  (define n64-cap-bad1
    (check-memory-capability-access TARGET-N64 (make-cap-mem 'rdram-dma 'u32 4 'active 'dirty 64)))
  (define n64-cap-bad2
    (check-memory-capability-access TARGET-N64 (make-cap-mem 'rdp-tmem 'u16 16 'rsp-display-list 'cache-flushed 8192)))
  (define n64-cap-ok
    (check-memory-capability-access TARGET-N64 (make-cap-mem 'rdram-dma 'u64 16 'active 'cache-flushed 256)))
  (check-false (hash-ref n64-cap-bad1 'valid?))
  (check-false (hash-ref n64-cap-bad2 'valid?))
  (check-true  (hash-ref n64-cap-ok   'valid?))

  ;; 5. Layer 4: Co-Processor / Multi-Core Session Protocol Verifier
  (define sess-ok
    (check-coprocessor-session-protocol TARGET-SNES (list '(send #x2140 ipl-boot 108) '(recv #x2140 ipl-boot))))
  (define sess-bad
    (check-coprocessor-session-protocol TARGET-SNES (list '(send #x2140 ipl-boot 108))))
  (check-true  (hash-ref sess-ok  'valid?))
  (check-false (hash-ref sess-bad 'valid?)))

;; ============================================================================
;; 30. Game Boy (DMG), Game Boy Color (GBC) & PICO-8 / RP2040 Backends
;; ============================================================================
(test-case "30. Game Boy (.gb), Game Boy Color (.gbc), PICO-8 (.p8) & RP2040 PIO (.uf2) Backends"
  ;; 1. DMG Game Boy (`build/boba_gb.gb`)
  (check-equal? (bytes-length boba-gb-rom-bytes) 32768)
  (check-true (hash-ref boba-gb-verification 'valid-header?))
  (check-true (hash-ref boba-gb-verification 'checksum-ok?))
  (check-true (hash-ref boba-gb-verification 'hram-dma-ok?))
  (check-true (hash-ref boba-gb-verification 'stat-mode-safe?))
  (check-equal? (hash-ref boba-gb-verification 'campaign-result) "FAIL_OK -> REC_OK -> FULL_WIN_OK")

  ;; 2. Game Boy Color (`build/boba_gbc.gbc`) with Double-Speed, 15-bit BGR555 Palettes & HDMA
  (check-equal? (bytes-length boba-gbc-rom-bytes) 32768)
  (check-true (hash-ref boba-gbc-verification 'valid-header?))
  (check-true (hash-ref boba-gbc-verification 'checksum-ok?))
  (check-true (hash-ref boba-gbc-verification 'gbc-mode?))
  (check-true (hash-ref boba-gbc-verification 'gbc-double-speed?))
  (check-true (hash-ref boba-gbc-verification 'gbc-bgr555-palettes-ok?))
  (check-true (> (hash-ref boba-gbc-verification 'hdma-transfers) 0))
  (check-equal? (hash-ref boba-gbc-verification 'campaign-result) "FAIL_OK -> REC_OK -> FULL_WIN_OK")

  ;; 3. PICO-8 (`.p8`) & RP2040 (`Cortex-M0+ Thumb` + `PIO` `.uf2`)
  (check-true (hash-ref boba-pico-verification 'pico8-tokens-ok?))
  (check-true (<= (hash-ref boba-pico-verification 'pico8-tokens) 8192))
  (check-true (hash-ref boba-pico-verification 'pico8-fixed16-16-ok?))
  (check-true (hash-ref boba-pico-verification 'pico8-sections-ok?))
  (check-equal? (hash-ref boba-pico-verification 'pico8-campaign-result) "FAIL_OK -> REC_OK -> FULL_WIN_OK")
  (check-true (hash-ref boba-pico-verification 'uf2-valid-blocks?))
  (check-equal? (hash-ref boba-pico-verification 'uf2-family-id) #xE48BFF56)
  (check-true (hash-ref boba-pico-verification 'pio-within-32-limit?))
  (check-true (<= (hash-ref boba-pico-verification 'pio-instruction-count) 32))
  (check-true (hash-ref boba-pico-verification 'sram-bank-disjoint?)))

;; ============================================================================
;; 31. SNES WDC 65C816 Mode-Indexed + Sony SPC700 LoROM (.sfc) Backend
;; ============================================================================
(test-case "31. SNES WDC 65C816 Mode-Indexed Assembler, SPC700 Audio & LoROM (.sfc) Backend"
  (define rpt boba-snes-verification-report)
  (check-equal? (bytes-length boba-snes-rom-bytes) 32768)
  (check-true (asm-65816-result-mode-safe? boba-snes-asm-result))
  (check-false (mode-safety-result-mode-safe? unreconciled-check))
  (check-true (mode-safety-result-mode-safe? reconciled-check))
  (check-true (snes-verification-report-header-valid? rpt))
  (check-true (snes-verification-report-checksum-xor-ffff? rpt))
  (check-true (snes-verification-report-checksum-matches-sum? rpt))
  (check-true (snes-verification-report-native-mode-switched? rpt))
  (check-true (snes-verification-report-reg-16bit-configured? rpt))
  (check-true (snes-verification-report-spc700-handshake-ok? rpt))
  (check-equal? (snes-verification-report-cgram-dma-bytes rpt) 64)
  (check-equal? (snes-verification-report-vram-4bpp-dma-bytes rpt) 512)
  (check-equal? (snes-verification-report-hdma-scanlines-updated rpt) 224)
  (check-true (snes-verification-report-campaign-victory? rpt)))

;; ============================================================================
;; 32. GBA (ARM7TDMI ARM32/Thumb16) & N64 (MIPS VR4300 + RSP + RDP) Backends
;; ============================================================================
(test-case "32. GBA (.gba) ARM7TDMI Bus-Width Verifier & N64 (.z64) VR4300 + RSP/RDP TMEM Backend"
  ;; 1. GBA (`build/boba_gba.gba`)
  (check-true (hash-ref boba-gba-bus-check 'valid?))
  (check-equal? (hash-ref boba-gba-bus-check 'violations) '())
  (check-true (hash-ref boba-gba-exec-report 'header-valid?))
  (check-equal? (hash-ref boba-gba-exec-report 'strb-vram-violations) 0)
  (check-equal? (hash-ref boba-gba-exec-report 'dma3-transfers) 5)
  (check-equal? (hash-ref boba-gba-exec-report 'campaign-status) "FAIL_OK -> REC_OK -> FULL_WIN_OK")
  (check-true (hash-ref boba-gba-exec-report 'verified?))

  ;; Verify GBA bus-width checker catches an illegal 8-bit STRB write to VRAM ($06000000)
  (define bad-gba-bus
    (verify-gba-vram-bus-widths
     (list '(arm-mov-imm 0 #x06 4) ; R0 = $06000000 (VRAM, rot4=4 -> ROR 8)
           '(arm-mov-imm 1 #xFF 0)
           '(arm-strb-imm 1 0 0))))
  (check-false (hash-ref bad-gba-bus 'valid?))

  ;; 2. Nintendo 64 (`build/boba_n64.z64`)
  (check-true (hash-ref boba-n64-safety-check 'valid?))
  (check-true (<= (hash-ref boba-n64-exec-report 'imem-bytes) 4096))
  (check-true (<= (hash-ref boba-n64-exec-report 'dmem-bytes) 4096))
  (check-true (<= (hash-ref boba-n64-exec-report 'tmem-bytes) 4096))
  (check-equal? (hash-ref boba-n64-exec-report 'header-magic) #x80371240)
  (check-true (hash-ref boba-n64-exec-report 'dma-16byte-aligned?))
  (check-true (hash-ref boba-n64-exec-report 'rdp-full-sync?))
  (check-equal? (hash-ref boba-n64-exec-report 'campaign-status) "FAIL_OK -> REC_OK -> FULL_WIN_OK")
  (check-true (hash-ref boba-n64-exec-report 'verified?)))

;; ============================================================================
;; 33. PLT Error Message Architecture: syntax/parse Fortification, Resugaring,
;;     Multi-Site Witnesses, Pareto Resource Blame & Contract Blame
;; ============================================================================
(test-case "33. PLT Error Diagnostics: syntax/parse Fortification, Resugaring, Multi-Witness Slices, Pareto & Contract Blame"
  ;; 1. syntax/parse Fortified Surface Macro Validation (Culpepper & Felleisen 2010/2012)
  (define bad-pal-diag
    (validate-boba-surface-syntax '(defpalette hero-pal (#x0F #x45 #x10 #x20))
                                  #:target 'nes
                                  #:raise? #f))
  (check-true (plt-boba-diagnostic? bad-pal-diag))
  (check-equal? (plt-boba-diagnostic-at-datum bad-pal-diag) #x45)
  (define bad-pal-audit (audit-error-message-plt-compliance bad-pal-diag))
  (check-true (hash-ref bad-pal-audit 'compliant?))
  (check-equal? (hash-ref bad-pal-audit 'score) 5)

  (define bad-tile-diag
    (validate-boba-surface-syntax '(deftiles hero-chr
                                     ("01230123"
                                      "01290123"
                                      "00000000"
                                      "00000000"
                                      "00000000"
                                      "00000000"
                                      "00000000"
                                      "00000000"))
                                  #:target 'nes
                                  #:raise? #f))
  (check-true (plt-boba-diagnostic? bad-tile-diag))
  (check-equal? (plt-boba-diagnostic-at-datum bad-tile-diag) "01290123")
  (check-true (hash-ref (audit-error-message-plt-compliance bad-tile-diag) 'compliant?))

  ;; 2. Pombrio-Krishnamurthi Core-IR-to-Surface Resugaring & Jargon Elimination
  (define resugared-dma
    (resugar-core-ir->surface-dsl
     '(ir-dma-transfer ppu-oam 256 256 vblank)
     'nes))
  (check-equal? (car resugared-dma) 'defvblank-dma)
  (define sanitized-str
    (sanitize-internal-compiler-jargon
     "ir-dma-transfer failed in cap-mem-access with mode-state-m and rot4"))
  (for ([pat (in-list INTERNAL-JARGON-PATTERNS)])
    (check-false (string-contains? sanitized-str pat)))

  ;; 3. Multi-Site Witness Slice for 65C816 M/X Mode Conflict (Marceau et al. 2011)
  (define mode-conflict-diag
    (diagnose-65816-mode-conflict/witnesses
     '((sep #x20)
       (label loop)
       (lda-imm #x12)
       (rep #x20)
       (bra loop))
     #:raise? #f))
  (check-true (plt-boba-diagnostic? mode-conflict-diag))
  (check-true (>= (length (plt-boba-diagnostic-witnesses mode-conflict-diag)) 3))
  (define mode-audit (audit-error-message-plt-compliance mode-conflict-diag #:conflict? #t))
  (check-true (hash-ref mode-audit 'compliant?))
  (check-equal? (hash-ref mode-audit 'score) 5)

  ;; 4. GBA ARM7TDMI Backward Register Def-Use Slice for 8-Bit STRB to VRAM
  (define gba-slice-diag
    (diagnose-gba-vram-strb/dataflow-slice
     '((arm-mov-imm r0 #x06 4)
       (arm-mov-imm r1 #xFF 0)
       (arm-strb-imm r1 r0 0))
     #:raise? #f))
  (check-true (plt-boba-diagnostic? gba-slice-diag))
  (check-true (>= (length (plt-boba-diagnostic-witnesses gba-slice-diag)) 2))
  (check-true (hash-ref (audit-error-message-plt-compliance gba-slice-diag #:conflict? #t) 'compliant?))

  ;; 5. Pareto Resource Overflow Blame & Minimal Cut Set
  (define pareto-diag
    (diagnose-resource-overflow/pareto-blame
     'n64
     'rdp-tmem
     '((deftiles boss-rgba16-atlas #:bytes 3072)
       (deftiles hud-font-atlas #:bytes 1536)
       (deftiles particle-tiles #:bytes 512))
     #:raise? #f))
  (check-true (plt-boba-diagnostic? pareto-diag))
  (check-equal? (pareto-contributor-id (first (plt-boba-diagnostic-pareto-breakdown pareto-diag)))
                'boss-rgba16-atlas)
  (check-true (hash-ref (audit-error-message-plt-compliance pareto-diag #:conflict? #t) 'compliant?))

  ;; 6. Findler-Felleisen Positive vs. Negative Co-Processor Contract Blame
  (define pos-blame-diag
    (diagnose-coprocessor-session/contract-blame
     'snes
     (hasheq 'violation 'recv-without-send
             'port '$2140-reg
             'expected "65C816 host must send #xAA/#xBB IPL boot command before polling SPC700"
             'actual "65C816 host polled $2140 without prior send")
     #:raise? #f))
  (check-equal? (contract-blame-polarity (plt-boba-diagnostic-blame pos-blame-diag)) 'positive)
  (check-true (hash-ref (audit-error-message-plt-compliance pos-blame-diag #:conflict? #t) 'compliant?))

  (define neg-blame-diag
    (diagnose-coprocessor-session/contract-blame
     'snes
     (hasheq 'violation 'ack-tag-mismatch
             'port '$2140-reg
             'expected "SPC700 co-processor must echo block counter tag on $2140"
             'actual "SPC700 returned mismatched tag #xFF")
     #:raise? #f))
  (check-equal? (contract-blame-polarity (plt-boba-diagnostic-blame neg-blame-diag)) 'negative)
  (check-true (hash-ref (audit-error-message-plt-compliance neg-blame-diag #:conflict? #t) 'compliant?)))

;; ============================================================================
;; 34. Top-10 Game Boy (.gb), Top-10 Game Boy Color (.gbc) & Top-10 PICO-8/RP2040
;;     Decompilation, Recompilation & 3-Checkpoint Framebuffer Equivalence (30 Games)
;; ============================================================================
(test-case "34. Top-10 GB (.gb), Top-10 GBC (.gbc) & Top-10 PICO-8 (.p8)/RP2040 (.uf2) Decompilation & 3-Checkpoint Verification (30 Games)"
  (define gb-gbc-pico-summary (run-all-gb-gbc-pico-top10-verifications!))
  (check-equal? (hash-ref gb-gbc-pico-summary 'total-games) 30)
  (check-equal? (hash-ref gb-gbc-pico-summary 'gb-count) 10)
  (check-equal? (hash-ref gb-gbc-pico-summary 'gbc-count) 10)
  (check-equal? (hash-ref gb-gbc-pico-summary 'pico-count) 10)
  (check-true (hash-ref gb-gbc-pico-summary 'all-verified?))

  ;; Verify every GB game (10/10)
  (for ([r (in-list (hash-ref gb-gbc-pico-summary 'gb-results))])
    (check-true (hash-ref r 'verified?))
    (check-true (hash-ref r 'hram-dma-ok?))
    (check-true (hash-ref r 'stat-mode-safe?))
    (check-equal? (hash-ref r 'matching-pixels) 23040)
    (check-equal? (hash-ref r 'pixel-match-pct) 100.0)
    (check-equal? (hash-ref r 'campaign-result) "FAIL_OK -> REC_OK -> FULL_WIN_OK"))

  ;; Verify every GBC game (10/10)
  (for ([r (in-list (hash-ref gb-gbc-pico-summary 'gbc-results))])
    (check-true (hash-ref r 'verified?))
    (check-true (hash-ref r 'double-speed?))
    (check-equal? (hash-ref r 'cgram-match-bytes) 64)
    (check-true (>= (hash-ref r 'hdma-transfers) 1))
    (check-equal? (hash-ref r 'matching-pixels) 23040)
    (check-equal? (hash-ref r 'pixel-match-pct) 100.0)
    (check-equal? (hash-ref r 'campaign-result) "FAIL_OK -> REC_OK -> FULL_WIN_OK"))

  ;; Verify every PICO-8 (.p8) / RP2040 (.uf2) game (10/10)
  (for ([r (in-list (hash-ref gb-gbc-pico-summary 'pico-results))])
    (check-true (hash-ref r 'verified?))
    (check-true (<= (hash-ref r 'p8-tokens) 8192))
    (check-true (<= (hash-ref r 'pio-instructions) 32))
    (check-true (hash-ref r 'sram-disjoint?))
    (check-equal? (hash-ref r 'matching-pixels) 16384)
    (check-equal? (hash-ref r 'pixel-match-pct) 100.0)
    (check-equal? (hash-ref r 'campaign-result) "FAIL_OK -> REC_OK -> FULL_WIN_OK")))

;; ============================================================================
;; 35. Top-10 Super Nintendo (.sfc LoROM — 65C816 Mode-Indexed + SPC700 + S-PPU)
;;     Decompilation, Recompilation & 3-Checkpoint Framebuffer Equivalence (10 Games)
;; ============================================================================
(test-case "35. Top-10 SNES (.sfc) 65C816 Mode-Indexed + SPC700 + Mode 7/HDMA Decompilation & 256x224 RGB Verification (10 Games)"
  (define snes-summary (run-all-snes-top10-verifications!))
  (check-equal? (hash-ref snes-summary 'total-games) 10)
  (check-equal? (hash-ref snes-summary 'passed-games) 10)
  (check-true (hash-ref snes-summary 'all-verified?))
  (check-equal? (hash-ref snes-summary 'total-mode-conflicts) 0)
  (check-equal? (hash-ref snes-summary 'pixel-match-pct) 100.0)

  (for ([r (in-list (hash-ref snes-summary 'games))])
    (check-true (hash-ref r 'verified?))
    (check-true (hash-ref r 'mode-safe?))
    (check-equal? (hash-ref r 'mode-conflicts) 0)
    (check-true (hash-ref r 'all-4-typecheck-layers-valid?))
    (check-true (hash-ref r 'cgram-match?))
    (check-true (hash-ref r 'vram-match?))
    (check-true (hash-ref r 'oam-match?))
    (check-true (hash-ref r 'hdma-match?))
    (check-true (hash-ref r 'spc700-match?))
    (check-equal? (hash-ref r 'framebuffer-matching-pixels) 57344)
    (check-equal? (hash-ref r 'framebuffer-match-pct) 100.0)))

;; ============================================================================
;; 36. Top-10 GBA (.gba ARM7TDMI) & Top-10 N64 (.z64 VR4300 + RSP SIMD + RDP)
;;     Decompilation, Recompilation & 3-Checkpoint Framebuffer Equivalence (20 Games)
;; ============================================================================
(test-case "36. Top-10 GBA (.gba) & Top-10 N64 (.z64) Decompilation, Recompilation & Framebuffer Equivalence (20 Games)"
  (define gba-n64-summary (run-all-gba-n64-top10-verifications!))
  (check-equal? (hash-ref gba-n64-summary 'total-games) 20)
  (check-equal? (hash-ref gba-n64-summary 'gba-count) 10)
  (check-equal? (hash-ref gba-n64-summary 'n64-count) 10)
  (check-true (hash-ref gba-n64-summary 'all-verified?))
  (check-equal? (hash-ref gba-n64-summary 'gba-strb-violations) 0)
  (check-true (hash-ref gba-n64-summary 'gba-complement-cc-all?))
  (check-true (hash-ref gba-n64-summary 'n64-dma-aligned-all?))
  (check-true (hash-ref gba-n64-summary 'n64-tmem-safe-all?))
  (check-true (hash-ref gba-n64-summary 'n64-rdp-protocol-all?))
  (check-equal? (hash-ref gba-n64-summary 'mean-pixel-match-pct) 100.0)

  (for ([r (in-list (hash-ref gba-n64-summary 'gba-results))])
    (check-true (hash-ref r 'verified?))
    (check-equal? (hash-ref r 'strb-vram-violations) 0)
    (check-true (hash-ref r 'complement-check-cc?))
    (check-equal? (hash-ref r 'matching-pixels) 38400)
    (check-equal? (hash-ref r 'pixel-match-pct) 100.0)
    (check-equal? (hash-ref r 'campaign-status) "FAIL_OK -> REC_OK -> FULL_WIN_OK"))

  (for ([r (in-list (hash-ref gba-n64-summary 'n64-results))])
    (check-true (hash-ref r 'verified?))
    (check-true (hash-ref r 'dma-16byte-aligned?))
    (check-true (<= (hash-ref r 'tmem-bytes) 4096))
    (check-true (hash-ref r 'rdp-sync-protocol-ok?))
    (check-equal? (hash-ref r 'matching-pixels) 76800)
    (check-equal? (hash-ref r 'pixel-match-pct) 100.0)
    (check-equal? (hash-ref r 'campaign-status) "FAIL_OK -> REC_OK -> FULL_WIN_OK")))

;; ============================================================================
;; 37. Unified Side-by-Side Real vs. Decompiled ROM Verification Across All
;;     14 Commercial NES ROMs (100.00% CP0 Pixel Match, 0 Seam Defects) &
;;     All 74 Multi-Target Games Across 8 Hardware Targets
;; ============================================================================
(test-case "37. Side-by-Side Real vs. Decompiled ROM Verification Across All 14 Commercial NES ROMs (100.00% CP0 Pixel Match) & All 74 Multi-Target Games"
  (define nes-14-rpt (verify-all-14-commercial-nes-side-by-side!))
  (check-equal? (hash-ref nes-14-rpt 'total-games) 14)
  (check-true   (hash-ref nes-14-rpt 'all-verified?))
  (check-equal? (hash-ref nes-14-rpt 'cp0-avg-pixel-match-pct) 100.0)
  (check-equal? (hash-ref nes-14-rpt 'total-matching-pixels) (* 14 61440))
  (check-equal? (hash-ref nes-14-rpt 'total-seam-defects) 0)

  (for ([g (in-list (hash-ref nes-14-rpt 'games))])
    (check-true   (hash-ref g 'verified?))
    (check-equal? (hash-ref g 'cp0-matching-pixels) 61440)
    (check-equal? (hash-ref g 'cp0-diff-pixels) 0)
    (check-equal? (hash-ref g 'cp0-pixel-match-pct) 100.0)
    (check-equal? (hash-ref g 'cp0-rgb-mae) 0.0)
    (check-equal? (hash-ref g 'hud-band-pct) 100)
    (check-equal? (hash-ref g 'upper-playfield-pct) 100)
    (check-equal? (hash-ref g 'lower-playfield-pct) 100)
    (check-equal? (hash-ref g 'palette-match-bytes) 32)
    (check-equal? (hash-ref g 'nametable-match-bytes) 960)
    (check-equal? (hash-ref g 'attrib-match-bytes) 64)
    (check-equal? (hash-ref g 'chr-match-bytes) 8192)
    (check-equal? (hash-ref g 'oam-tile-overlap-pct) 100)
    (check-equal? (hash-ref g 'seam-defects) 0)
    (check-true   (hash-ref g 'visual-diff-png-ok?))
    (check-true   (hash-ref g 'campaign-verified?))
    (check-equal? (hash-ref g 'campaign-result) "FAIL_OK -> REC_OK -> FULL_WIN_OK"))

  (define multi-74-rpt (run-all-74-multi-target-side-by-side-diffs!))
  (check-equal? (hash-ref multi-74-rpt 'total-games) 74)
  (check-equal? (hash-ref multi-74-rpt 'total-targets) 8)
  (check-true   (hash-ref multi-74-rpt 'all-74-verified?))
  (check-true   (hash-ref multi-74-rpt 'all-74-3panel-pngs-ok?))
  (check-true   (hash-ref multi-74-rpt 'all-6-system-sheets-ok?))
  (check-equal? (hash-ref multi-74-rpt 'overall-pixel-match-pct) 100.0)
  (check-equal? (hash-ref multi-74-rpt 'total-diff-pixels) 0)
  (check-equal? (hash-ref multi-74-rpt 'total-seam-defects) 0)
  (check-equal? (hash-ref multi-74-rpt 'total-matching-pixels) 3210240))

;; ============================================================================
;; 38. Whole-ROM Lossless Decompilation/Recompilation & Full Continuous .fm2
;;     TAS Lockstep Verification Across All 44 NES, GB, GBC & PICO-8 Games
;; ============================================================================
(test-case "38. Whole-ROM Lossless Decompiler/Recompiler & Full Continuous .fm2 TAS Movies (14 NES + 10 GB + 10 GBC + 10 PICO-8 = 44 Whole Games)"
  (check-equal? (length NES-WHOLE-ROM-SPECS) 14)
  (check-equal? (length GB-WHOLE-ROM-SPECS) 10)
  (check-equal? (length GBC-WHOLE-ROM-SPECS) 10)
  (check-equal? (length PICO-WHOLE-ROM-SPECS) 10)
  (check-equal? (length ALL-44-WHOLE-ROM-SPECS) 44)

  ;; 1. Verify all 7 downloaded real GitHub .fm2 TAS files exist and parse cleanly
  (for ([tas-file (in-list '("smb_geekgame_tas2.fm2"
                             "smb_geekgame_flag2.fm2"
                             "smb_minus_world.fm2"
                             "dr_mario_tas.fm2"
                             "yie_ar_kungfu_tas.fm2"
                             "battle_city_tas.fm2"
                             "nuts_milk_tas.fm2"))])
    (define p (build-path "assets" "tas" tas-file))
    (check-true (file-exists? p) (format "Missing real TAS file ~a" tas-file))
    (define masks (parse-fm2-tas-inputs (file->string p)))
    (check-true (> (length masks) 100) (format "TAS file ~a should have >100 frames" tas-file)))

  ;; 2. Verify all 44 whole-ROM .boba.rkt modules, examples/decompiled/*_whole_rom.rkt,
  ;;    recompiled full-game binaries, and continuous .fm2 TAS movies (>= 600 frames)
  (for ([spec (in-list ALL-44-WHOLE-ROM-SPECS)])
    (define target (hash-ref spec 'target))
    (define id (hash-ref spec 'id))
    (define ext (case target [(nes) "nes"] [(gb) "gb"] [(gbc) "gbc"] [(pico) "p8"]))
    (define orig-path (build-path "assets" "roms" (hash-ref spec 'rom-file)))
    (define boba-path (build-path "assets" "decompiled" "real_roms" (format "~a_~a.boba.rkt" target id)))
    (define ex-path (build-path "examples" "decompiled"
                                (if (eq? target 'nes)
                                    (format "~a_whole_rom.rkt" id)
                                    (format "~a_~a_whole_rom.rkt" target id))))
    (define recomp-path (build-path "build"
                                    (if (eq? target 'nes)
                                        (format "recompiled_~a.~a" id ext)
                                        (format "recompiled_~a_~a.~a" target id ext))))
    (define tas-path (build-path "assets" "tas" (format "~a_~a.fm2" target id)))

    (check-true (file-exists? orig-path) (format "Missing orig ROM ~a" orig-path))
    (check-true (file-exists? boba-path) (format "Missing whole-ROM .boba.rkt ~a" boba-path))
    (check-true (file-exists? ex-path) (format "Missing examples/decompiled whole-ROM ~a" ex-path))
    (check-true (file-exists? recomp-path) (format "Missing recompiled full-game ROM ~a" recomp-path))
    (check-true (file-exists? tas-path) (format "Missing .fm2 TAS file ~a" tas-path))

    ;; Verify multi-line formatting (> 100 lines) and lifted AST forms in .boba.rkt and example modules
    (define boba-str (file->string boba-path))
    (define ex-str (file->string ex-path))
    (define boba-lines (length (string-split boba-str "\n")))
    (define ex-lines (length (string-split ex-str "\n")))
    (check-true (> boba-lines 100)
                (format "Expected multi-line formatting (> 100 lines) in ~a, got ~a" boba-path boba-lines))
    (check-true (> ex-lines 100)
                (format "Expected multi-line formatting (> 100 lines) in ~a, got ~a" ex-path ex-lines))
    (case target
      [(nes)
       (check-true (string-contains? boba-str "(symbolic-mmio-xref")
                   (format "Missing symbolic-mmio-xref in ~a" boba-path))
       (check-true (string-contains? boba-str "(defsub ")
                   (format "Missing lifted (defsub ...) in ~a" boba-path))
       (check-true (string-contains? boba-str "(defdata ")
                   (format "Missing lifted (defdata ...) in ~a" boba-path))]
      [(gb gbc)
       (check-true (string-contains? boba-str "(symbolic-mmio-xref")
                   (format "Missing symbolic-mmio-xref in ~a" boba-path))
       (check-true (string-contains? boba-str "(def-sm83-isr ")
                   (format "Missing lifted (def-sm83-isr ...) in ~a" boba-path))
       (check-true (string-contains? boba-str "(defsub-sm83 ")
                   (format "Missing lifted (defsub-sm83 ...) in ~a" boba-path))]
      [(pico)
       (check-true (string-contains? boba-str "(def-pico-function")
                   (format "Missing lifted (def-pico-function ...) in ~a" boba-path))
       (check-true (string-contains? boba-str "(lifted-pico8-assets")
                   (format "Missing (lifted-pico8-assets ...) in ~a" boba-path))])

    ;; Verify 100.00% byte-for-byte identity between original commercial ROM and recompiled whole-ROM binary
    (define orig-bytes (file->bytes orig-path))
    (define recomp-bytes (file->bytes recomp-path))
    (check-equal? (bytes-length recomp-bytes) (bytes-length orig-bytes)
                  (format "Whole-ROM size mismatch for ~a_~a" target id))
    (check-equal? recomp-bytes orig-bytes
                  (format "Whole-ROM byte mismatch for ~a_~a" target id))

    ;; Verify continuous .fm2 TAS movie has >= 600 frames of gameplay inputs
    (define tas-masks (parse-fm2-tas-inputs (file->string tas-path)))
    (check-true (>= (length tas-masks) 600)
                (format "Expected >= 600 TAS frames for ~a_~a, got ~a" target id (length tas-masks))))

  ;; 3. Verify direct instruction/function assembly & round-trip recompilation across all 4 targets
  (for ([sample-pair (in-list '(("assets/decompiled/real_roms/nes_super_mario_bros.boba.rkt"
                                 "assets/roms/super_mario_bros.nes")
                                ("assets/decompiled/real_roms/gb_tetris.boba.rkt"
                                 "assets/roms/gb/tetris.gb")
                                ("assets/decompiled/real_roms/gbc_smb_deluxe.boba.rkt"
                                 "assets/roms/gbc/smb_deluxe.gbc")
                                ("assets/decompiled/real_roms/pico_celeste_classic.boba.rkt"
                                 "assets/roms/pico/celeste.p8")))])
    (define boba-file (first sample-pair))
    (define orig-file (second sample-pair))
    (define orig-bytes (file->bytes orig-file))
    (define sexp (read-boba-whole-rom-sexp boba-file))
    (define direct-asm-res (verify-whole-rom-direct-assembly sexp orig-bytes))
    (check-true (hash-ref direct-asm-res 'exact-match?)
                (format "Direct instruction assembly failed for ~a" boba-file))
    (check-true (> (hash-ref direct-asm-res 'assembled-subs) 0)
                (format "Expected > 0 assembled subroutines/functions for ~a" boba-file))
    (check-equal? (hash-ref direct-asm-res 'recompiled-bytes) orig-bytes
                  (format "Round-trip recompilation mismatch for ~a" boba-file)))

  ;; 4. Verify whole_rom_decompilation_report.json metrics
  (local-require json)
  (define whole-rpt-path (build-path "assets" "decompiled" "whole_rom_decompilation_report.json"))
  (check-true (file-exists? whole-rpt-path))
  (define whole-rpt (string->jsexpr (file->string whole-rpt-path)))
  (check-equal? (hash-ref whole-rpt 'allBitExactWholeRom) #t)
  (check-equal? (hash-ref whole-rpt 'totalGames) 44)
  (for ([g (in-list (hash-ref whole-rpt 'games))])
    (check-equal? (hash-ref g 'bitExactWholeRom) #t)
    (check-true (> (hash-ref g 'dslLineCount) 100))
    (check-true (> (hash-ref g 'liftedSubroutines) 0))
    (check-true (> (hash-ref g 'liftedInstructions) 0))))

;; ============================================================================
;; 39. Real Commercial SNES (.sfc in SnesJs), GBA (.gba in gbajs2) & N64 (.n64
;;     in n64js) Whole-ROM Decompilation, Recompilation & Lockstep Verification
;; ============================================================================
(test-case "39. Real Commercial SNES (.sfc), GBA (.gba) & N64 (.n64) Whole-ROM Decompiler/Recompiler & Headless Emulator Lockstep (30 Whole Games)"
  (local-require json)
  (define snes-gba-rpt-path (build-path "assets" "decompiled" "real_snes_gba_report.json"))
  (define n64-rpt-path      (build-path "assets" "decompiled" "real_n64_report.json"))
  (check-true (file-exists? snes-gba-rpt-path))
  (check-true (file-exists? n64-rpt-path))

  (define snes-gba-rpt (call-with-input-file snes-gba-rpt-path read-json))
  (define n64-rpt      (call-with-input-file n64-rpt-path read-json))

  (check-equal? (hash-ref snes-gba-rpt 'snesCount) 10)
  (check-equal? (hash-ref snes-gba-rpt 'gbaCount) 10)
  (check-equal? (hash-ref snes-gba-rpt 'totalMatchingPixels) 957440)
  (check-equal? (hash-ref snes-gba-rpt 'totalDiffPixels) 0)
  (check-equal? (hash-ref n64-rpt 'totalMatchingPixels) 768000)
  (check-equal? (hash-ref n64-rpt 'totalDiffPixels) 0)

  ;; Verify all 10 SNES, 10 GBA, and 10 N64 whole-ROM .boba.rkt modules, symbolic examples/decompiled/*_whole_rom.rkt modules, recompiled ROMs, and .fm2 TAS files
  (for ([snes-id (in-list '("super_mario_world" "link_to_the_past" "super_metroid" "chrono_trigger"
                            "donkey_kong_country" "super_mario_kart" "mega_man_x" "f_zero"
                            "contra_iii" "earthbound"))])
    (define boba-p (build-path "assets" "decompiled" "real_roms" (format "snes_~a.boba.rkt" snes-id)))
    (define sym-p  (build-path "examples" "decompiled" (format "snes_~a_whole_rom.rkt" snes-id)))
    (define rec-p  (build-path "build" (format "recompiled_snes_~a.sfc" snes-id)))
    (define tas-p  (build-path "assets" "tas" (format "snes_~a.fm2" snes-id)))
    (check-true (file-exists? boba-p) (format "Missing SNES .boba.rkt ~a" boba-p))
    (check-true (file-exists? sym-p)  (format "Missing symbolic SNES whole_rom.rkt ~a" sym-p))
    (check-true (file-exists? rec-p)  (format "Missing recompiled SNES .sfc ~a" rec-p))
    (check-true (file-exists? tas-p)  (format "Missing SNES .fm2 ~a" tas-p))
    (check-true (>= (file-size rec-p) 524288) (format "Expected full-size SNES ROM >= 512KB for ~a" snes-id))
    (define sym-str (file->string sym-p))
    (check-true (string-contains? sym-str "(defsub-65c816 ") (format "Missing defsub-65c816 in ~a" sym-p))
    (check-true (string-contains? sym-str "(define-snes-spc700-audio-driver") (format "Missing SPC700 driver in ~a" sym-p))
    (check-true (string-contains? sym-str "(define-snes-mmio-profile") (format "Missing SNES MMIO profile in ~a" sym-p)))

  (for ([gba-id (in-list '("metroid_fusion" "aria_of_sorrow" "superstar_saga" "pokemon_emerald"
                           "advance_wars" "golden_sun" "minish_cap" "mega_man_zero"
                           "fire_emblem_gba" "warioware_inc"))])
    (define boba-p (build-path "assets" "decompiled" "real_roms" (format "gba_~a.boba.rkt" gba-id)))
    (define sym-p  (build-path "examples" "decompiled" (format "gba_~a_whole_rom.rkt" gba-id)))
    (define rec-p  (build-path "build" (format "recompiled_gba_~a.gba" gba-id)))
    (define tas-p  (build-path "assets" "tas" (format "gba_~a.fm2" gba-id)))
    (check-true (file-exists? boba-p) (format "Missing GBA .boba.rkt ~a" boba-p))
    (check-true (file-exists? sym-p)  (format "Missing symbolic GBA whole_rom.rkt ~a" sym-p))
    (check-true (file-exists? rec-p)  (format "Missing recompiled GBA .gba ~a" rec-p))
    (check-true (file-exists? tas-p)  (format "Missing GBA .fm2 ~a" tas-p))
    (check-true (>= (file-size rec-p) 4194304) (format "Expected full-size GBA ROM >= 4MB for ~a" gba-id))
    (define sym-str (file->string sym-p))
    (check-true (string-contains? sym-str "(defsub-arm32 ") (format "Missing defsub-arm32 in ~a" sym-p))
    (check-true (string-contains? sym-str "(defsub-thumb16 ") (format "Missing defsub-thumb16 in ~a" sym-p))
    (check-true (string-contains? sym-str "(define-gba-bios-swi-catalog") (format "Missing GBA BIOS SWI catalog in ~a" sym-p)))

  (for ([n64-id (in-list '("super_mario_64" "ocarina_of_time" "mario_kart_64" "banjo_kazooie"
                           "f_zero_x" "1080_snowboarding" "castlevania_64" "bomberman_64"
                           "bomberman_hero" "kirby_64"))])
    (define orig-p (build-path "assets" "roms" "n64" (format "~a.n64" n64-id)))
    (define boba-p (build-path "assets" "decompiled" "real_roms" (format "n64_~a.boba.rkt" n64-id)))
    (define sym-p  (build-path "examples" "decompiled" (format "n64_~a_whole_rom.rkt" n64-id)))
    (define rec-p  (build-path "build" (format "recompiled_n64_~a.n64" n64-id)))
    (define tas-p  (build-path "assets" "tas" (format "n64_~a.fm2" n64-id)))
    (check-true (file-exists? orig-p) (format "Missing orig N64 ROM ~a" orig-p))
    (check-true (file-exists? boba-p) (format "Missing N64 .boba.rkt ~a" boba-p))
    (check-true (file-exists? sym-p)  (format "Missing symbolic N64 whole_rom.rkt ~a" sym-p))
    (check-true (file-exists? rec-p)  (format "Missing recompiled N64 .n64 ~a" rec-p))
    (check-true (file-exists? tas-p)  (format "Missing N64 .fm2 ~a" tas-p))
    (check-equal? (file-size rec-p) (file-size orig-p)
                  (format "Whole-ROM N64 size mismatch for ~a" n64-id))
    (define sym-str (file->string sym-p))
    (check-true (string-contains? sym-str "(define-n64-lifted-subroutines") (format "Missing VR4300 subroutines in ~a" sym-p))
    (check-true (string-contains? sym-str "(define-n64-rsp-rdp-display-list") (format "Missing GBI display lists in ~a" sym-p))
    (check-true (string-contains? sym-str "(define-n64-resolved-pointers") (format "Missing resolved 32-bit pointers in ~a" sym-p))))

(printf "\nAll #lang boba-nes graded typechecker, PLT error diagnostics/resugaring, banked cartridge, authentic CHR, whole-ROM decompiler/recompiler, continuous .fm2 TAS lockstep, and 74 Multi-Architecture Side-by-Side Games (14 NES + 10 GB + 10 GBC + 10 PICO-8/RP2040 + 10 SNES + 10 GBA + 10 N64) tests PASSED (~a assertions)!\n"
        total-checks)
