# `#lang boba-nes`: Developer Reference & Decompiler Toolchain Guide

`#lang boba-nes` is a Racket domain-specific language, coeffect–effect graded typechecker, MOS 6502 two-pass macro assembler, and bidirectional iNES 1.0 (`.nes`) decompiler targeting the **Nintendo Entertainment System (Ricoh 2A03 CPU/APU + Ricoh 2C02 PPU)**. Every module written in `#lang boba-nes`—or lifted from a commercial `.nes` binary via `tools/nes-rom-decompiler.rkt`—is statically verified against four logical safety families ($L_1\text{–}L_4$) and five physical hardware budgets ($\Phi_1\text{–}\Phi_5$) before emitting a cycle-accurate, bootable iNES 1.0 cartridge image.

---

## 1. Quickstart & Toolchain Architecture

### 1.1 End-to-End Compiler & Decompiler Pipeline

```
+-----------------------------------------------------------------------------------+
|                        #lang boba-nes Toolchain Architecture                      |
+-----------------------------------------------------------------------------------+
|                                                                                   |
|  [Declarative .bnes Source]                   [Commercial .nes ROM Binary]        |
|   examples/boba_is_you.bnes                    assets/roms/super_mario_bros.nes   |
|   examples/star_courier.bnes                   assets/roms/legend_of_zelda.nes    |
|   examples/crypt_sweep.bnes                    assets/roms/tetris.nes             |
|   examples/neon_strider.bnes                   assets/roms/donkey_kong.nes ...    |
|              |                                                |                   |
|              v  (boba-nes/lang/reader.rkt)                    v                   |
|  +---------------------------------------+    +-------------------------------+   |
|  | Tier 1: High-Level Surface AST        |<---| tools/nes-rom-decompiler.rkt  |   |
|  |  - defnes-module, defcartridge        |    |  - disassemble-ines-rom       |   |
|  |  - defchr-layout, defchar-map         |    |  - decompile-ines-rom-to-...  |   |
|  |  - defmetasprite, defstate-machine    |    |  - detect-6502-jump-engine    |   |
|  |  - defzp-map, with-zp-scratch         |    |  - infer-zp-roles-from-trace  |   |
|  +---------------------------------------+    +-------------------------------+   |
|              |                                                                    |
|              v  (compiler/graded-typechecker.rkt & compiler/diagnostics.rkt)      |
|  +----------------------------------------------------------------------------+   |
|  | Tier 2: Coeffect-Effect Typechecker, Auto-Repair & Chordal ZP Allocator    |   |
|  |  - CapMem Semiring: ConstMeta < RomBorrow < PpuTaint < RamLinear < ZpScratch|   |
|  |  - Logical Families: L1 (ZP/Stack), L2 (Banks), L3 (Phases), L4 (Latch/DMC)|   |
|  |  - Physical Budgets: Phi1 (WCET), Phi2 (OAM), Phi3 (RAM), Phi4 (VRAM), Phi5|   |
|  |  - Grade-Driven Repair: repair-nes-module & allocate-zero-page-chordal     |   |
|  +----------------------------------------------------------------------------+   |
|              |                                                                    |
|              v  (compiler/mos6502-assembler.rkt)                                  |
|  +----------------------------------------------------------------------------+   |
|  | Tier 3: MOS 6502 Optimizer, Branch Relaxer, WCET Analyzer & iNES Linker    |   |
|  |  - optimize-6502-peephole (Tail-Call JSR+RTS -> JMP, Redundant STA/LDA)    |   |
|  |  - relax-6502-branches (Fixed-Point [-128,+127] & Page-Crossing Relaxation)|   |
|  |  - analyze-6502-wcet (Instruction-Level Cycle & $4014 OAMDMA Accounting)   |   |
|  |  - build-ines-rom / build-banked-ines-rom -> build/*.nes + build/*.s       |   |
|  +----------------------------------------------------------------------------+   |
|              |                                                                    |
|              +--------------------------------+-----------------------------------+
|              v                                v                                   |
|  +-----------------------------------+  +-------------------------------------+   |
|  | Racket 6502 + 2C02 VM             |  | Node.js jsnes Differential Harness  |   |
|  |  - make-nes-emulator-from-rom     |  |  - emulator-harness/run-jsnes.mjs   |   |
|  |  - nes-step-frame! (Cycle-Exact)  |  |  - side-by-side-differ.mjs          |   |
|  |  - tests/boba-nes-tests.rkt       |  |  - diff-top10-roms.mjs              |   |
|  +-----------------------------------+  +-------------------------------------+   |
+-----------------------------------------------------------------------------------+
```

### 1.2 Essential CLI Commands

Run all commands from the repository root (`boba-nes/`):

```bash
# 1. Compile core #lang boba-nes cartridges to bootable iNES 1.0 (.nes) ROMs
racket examples/boba_is_you.bnes
racket examples/boba_200_levels_cartridge.bnes
racket examples/mario_platformer.bnes
racket examples/zelda_adventure.bnes
racket examples/tetris_nes.bnes

# 2. Compile the 3 original #lang boba-nes games (Star Courier, Crypt Sweep, Neon Strider)
racket examples/star_courier.bnes
racket examples/crypt_sweep.bnes
racket examples/neon_strider.bnes

# 3. Run the complete Racket verification suite (CapMem, L1-L4, Phi1-Phi5, WCET, 6502 VM, Decompiler)
racket tests/boba-nes-tests.rkt

# 4. Run the Node.js jsnes frame-by-frame side-by-side PPU/OAM/RAM differential harnesses
node emulator-harness/run-jsnes.mjs
node emulator-harness/run-games-jsnes.mjs
node emulator-harness/side-by-side-differ.mjs
node emulator-harness/diff-top10-roms.mjs
```

### 1.3 Interactive Cycle-Accurate 6502/2C02 Emulation in Racket

Every compiled `.nes` image can be booted and stepped instruction-by-instruction or frame-by-frame inside the built-in Racket 6502/2C02 verification virtual machine ([`compiler/mos6502-assembler.rkt`](../compiler/mos6502-assembler.rkt)):

```racket
#lang racket/base
(require "compiler/mos6502-assembler.rkt"
         "examples/boba_is_you.bnes")

;; 1. Instantiate the cycle-accurate 6502 + 2C02 emulator from raw iNES bytes
(define emu    (make-nes-emulator-from-rom boba-rom-bytes))
(define labels (asm-result-labels boba-asm-result))
(define boot   (hash-ref labels 'boot_init))
(define step   (hash-ref labels 'game_frame_step))

;; 2. Execute boot initialization until RTS
(nes-run-until-rts! emu boot)

;; 3. Step a full 60 Hz frame (ActiveFrame + VBlank NMI) with RIGHT pressed on Joypad 1
(define-values (active-cycles vblank-cycles)
  (nes-step-frame! emu step BTN-RIGHT))

(printf "ActiveFrame: ~a cyc (<= 29780), VBlank NMI: ~a cyc (<= 2273)\n"
        active-cycles vblank-cycles)
```

---

## 2. Complete `#lang boba-nes` Language Reference

Every source file begins with `#lang boba-nes`, which configures the custom reader ([`boba-nes/lang/reader.rkt`](../boba-nes/lang/reader.rkt)) and exports all declarative hardware forms, graded typechecker primitives, 6502 assembler macros, and genre libraries from [`boba-nes/main.rkt`](../boba-nes/main.rkt).

### 2.1 Module & Hardware Configuration

#### `(defnes-module mod-id budget-expr spec-hash-expr)`
Declares a hardware-verified NES module, runs `compile-and-verify-nes-module` (invoking both `typecheck-nes-module` and the automated grade-driven repair pass `repair-nes-module`), and aborts compilation with a 3-span resugared diagnostic if any unrepairable $L_1\text{–}L_4$ or $\Phi_1\text{–}\Phi_5$ violation remains.

#### `(defcartridge spec-id budget-id #:mapper m #:prg-banks p #:chr-banks c #:chr-mode cm #:wram-bytes w #:battery? b #:mirroring mir)`
Declares an iNES cartridge hardware specification (`nes-cartridge-spec`) and binds `budget-id` to its derived `nes-budget`:

| Mapper Symbol | iNES Mapper ID | PRG-ROM Windowing | CHR Capability | Cartridge WRAM (`$6000–$7FFF`) | Predefined Budget Constant |
| :--- | :---: | :--- | :--- | :--- | :--- |
| `'NROM` | `0` | Fixed $16\text{ KB}$ (`NROM-128`) or $32\text{ KB}$ (`NROM-256`) at `$8000–$FFFF` | $8\text{ KB}$ CHR-ROM (`512` tiles) | None (`0 B`) | `NTSC-NROM-BUDGET` |
| `'MMC1` | `1` | Switchable $16\text{ KB}$ at `$8000–$BFFF` + Fixed $16\text{ KB}$ at `$C000–$FFFF` (up to $256\text{ KB}$ `SXROM`) | $8\text{ KB}$ CHR-RAM or $16\text{ KB}$ banked CHR-ROM | $8\text{ KB}$ (`8,192 B`, battery optional) | `NTSC-MMC1-BUDGET`, `NTSC-MMC1-SXROM-BUDGET` |
| `'UNROM` | `2` | Switchable $16\text{ KB}$ at `$8000–$BFFF` + Fixed $16\text{ KB}$ at `$C000–$FFFF` ($128\text{ KB}$) | $8\text{ KB}$ writable CHR-RAM (`0` CHR banks) | None (`0 B`) | `NTSC-UNROM-128-BUDGET` |
| `'MMC3` | `4` | Switchable $8\text{ KB}$ banks + `A12` scanline IRQ counter (up to $512\text{ KB}$ `TXROM`) | Up to $64\text{ KB}$ fine-banked CHR-ROM (`4,096` tiles) | $8\text{ KB}$ (`8,192 B`, battery optional) | `NTSC-MMC3-TXROM-BUDGET` |

**Example — Declaring a 256 KB MMC1 SXROM Cartridge with 8 KB Battery WRAM & CHR-RAM**:
```racket
#lang boba-nes

(defcartridge sxrom-cartridge sxrom-budget
  #:mapper     MMC1
  #:prg-banks  16        ; 16 x 16 KB = 256 KB PRG-ROM
  #:chr-banks  0         ; 0 CHR-ROM banks => 8 KB writable CHR-RAM ($0000-$1FFF)
  #:chr-mode   chr-ram
  #:wram-bytes 8192      ; 8 KB PRG-RAM at $6000-$7FFF
  #:battery?   #t
  #:mirroring  vertical) ; $2000 != $2400 for seamless horizontal scrolling
```

#### Mirroring & Mid-Frame `Sprite 0 Hit` HUD Splits
When `'scroll-mode` is set to `'horizontal`, rule $\Phi_4$ (`check-Phi4-vram-and-attributes`) enforces `'vertical` mirroring so Nametable 0 (`$2000`) and Nametable 1 (`$2400`) form a contiguous $512\times 240$-pixel horizontal playfield. If `'sprite0-split?` is `#t`, rule $L_3$ (`check-L3-phase-and-totality`) verifies `'sprite0-opaque-overlap?` to guarantee that OAM Slot 0 (`$0200–$0203`) overlaps a non-transparent background tile before polling `BIT $2002 / BVC`, preventing a mid-frame CPU deadlock.

---

### 2.2 Memory & Capability Grades (`CapMem`, `defzp-var`, `with-zp-scratch`, `defzp-map`)

`#lang boba-nes` tracks every memory binding using the 5-element capability semiring $\mathsf{CapMem}$:

$$\mathsf{ConstMeta} < \mathsf{RomBorrow} < \mathsf{PpuTaint} < \mathsf{RamLinear} < \mathsf{DmaUnique}\;(\text{Scoped }\mathsf{ZpScratch})$$

| Grade | Rank | Parallel Composition ($q_1 \oplus q_2$) | Hardware Semantics |
| :--- | :---: | :--- | :--- |
| `ConstMeta` | `0` | Identity (`ConstMeta + q = q`) | Erased compile-time constant (`0` ZP / `0` RAM bytes at runtime). |
| `RomBorrow` | `1` | Idempotent (`RomBorrow + RomBorrow = RomBorrow`) | Immutable PRG-ROM lookup table (`$8000–$FFFF`). |
| `PpuTaint` | `2` | Tainting (`PpuTaint + RomBorrow = PpuTaint`) | Side-effecting write to `$2006`/`$2007` tainting internal PPU `t`/`v`/`w` latch; must be discharged by `(restore-scroll! x y)` before `RTI`. |
| `RamLinear` | `3` | Linear (`RamLinear + RamLinear = CapConflict`) | Mutable Zero-Page (`$0010–$00EF`) or Work RAM (`$0300–$07FF`) state; forbids concurrent mutable aliasing. |
| `DmaUnique` (`ZpScratch`) | `4` | Unique (`DmaUnique + q = CapConflict` for $q > \mathsf{RomBorrow}$) | Exclusive `$0200–$02FF` OAM DMA shadow page or scoped `(with-zp-scratch ...)` block recycled via high-watermark algebra. |

#### `(defzp-var id #:bytes n #:cap cap-sym)` & `(with-zp-scratch ([id bytes] ...) body ...)`
Permanent Zero-Page variables declared via `defzp-var` remain live across the entire frame, whereas temporary Zero-Page pointers inside `(with-zp-scratch ...)` are recycled across sequential phases via the high-watermark law:

$$m_{\text{zp-live}}(t_1 \fatsemi t_2) = m_{\text{zp-live}}(t_1) + m_{\text{zp-live}}(t_2), \qquad m_{\text{zp-peak}}(t_1 \fatsemi t_2) = \max\!\big(m_{\text{zp-peak}}(t_1),\; m_{\text{zp-live}}(t_1) + m_{\text{zp-peak}}(t_2)\big)$$

Under the hood, [`allocate-zero-page-chordal`](../compiler/diagnostics.rkt) colors interval graphs in left-edge (perfect elimination) order, mapping sequential scratch scopes to the exact same physical Zero-Page addresses (`$0010 + m_{\text{zp-live}}$).

```racket
;; Permanent Zero-Page state (21 B live) + Erased compile-time constants (0 B live)
(defzp-var zp_joy_state   #:bytes 3  #:cap RamLinear)
(defzp-var zp_stage_state #:bytes 6  #:cap RamLinear)
(defzp-var zp_ppu_state   #:bytes 6  #:cap RamLinear)
(defzp-var zp_rule_table  #:bytes 6  #:cap RamLinear)
(defzp-var tile_constants #:bytes 16 #:cap ConstMeta) ; Erased at compile time!

;; Sequential scratch scopes share physical Zero-Page addresses $25..$2A (peak = 21 + 6 = 27 B, not 45 B!)
(with-zp-scratch ([joy_tmp 6])  'poll-joypad-phase)
(with-zp-scratch ([rule_tmp 6]) 'scan-rules-phase)
(with-zp-scratch ([push_tmp 6]) 'resolve-push-chain-phase)
(with-zp-scratch ([oam_tmp 6])  'pack-oam-sprites-phase)
```

#### `(defzp-map map-id ([var-sym zp-addr role-sym] ...))`
Declares a pinned hardware Zero-Page memory map (`$00–$FF`) and annotates each register with its semantic role (`'monotonic-frame-counter`, `'prng-lfsr`, `'player-or-actor-coord`, `'hud-bcd-counter`, `'game-phase-or-flag`, or `'zp-timer-array`). Checked by `check-pinned-zp-map` ($L_1$) for out-of-range addresses and colliding Zero-Page assignments:

```racket
(defzp-map smb-zp-layout
  ([scroll-x       #x14 player-or-actor-coord]
   [x-world-lo     #x16 player-or-actor-coord]
   [y-px           #x1A player-or-actor-coord]
   [coins          #x1E hud-bcd-counter]
   [score          #x1F hud-bcd-counter]
   [won            #x24 game-phase-or-flag]
   [dead           #x26 game-phase-or-flag]
   [lives          #x27 hud-bcd-counter]
   [stage-id       #x28 game-phase-or-flag]
   [game-completed #x29 game-phase-or-flag]))
```

---

### 2.3 Scanline Phase Typing (`vblank-block`, `active-frame-block`, $\Phi_1\text{–}\Phi_5$ & $L_1\text{–}L_4$)

Every PPU and CPU operation is checked against the active execution phase $\pi \in \{\mathsf{Boot}, \mathsf{ForcedBlank}, \mathsf{ActiveFrame}, \mathsf{VBlankNMI}, \mathsf{ScanlineHBlank}\}$:
- **`(vblank-block body ...)` (`VBlankNMI` Phase)**: Grants temporary capability to execute `$4014` `oam-dma!`, `$2006`/`$2007` `ppu-write!`, `vram-put!`, `palette-write!`, and `nametable-patch!` within the $2,273$-cycle NTSC VBlank budget ($\Phi_1$) and $128$-byte per-NMI transfer cap ($\Phi_4$). Any `$2006`/`$2007` write taints the context with `PpuTaint` ($L_4$), requiring `(restore-scroll! scroll-x scroll-y)` before `RTI`.
- **`(active-frame-block body ...)` (`ActiveFrame` Phase)**: Enforces the $29,780$-cycle active scanline budget ($\Phi_1$) while statically rejecting any direct `$2006`/`$2007` VRAM write or `$4014` `OAMDMA` transfer ($L_3$: `vram-write-during-active-render` / `oam-dma-outside-vblank`), because the 2C02 PPU owns the VRAM address bus during visible scanlines `0..239`.
- **Cooperative Coroutine & VBlank Slicing ($\Phi_1, \Phi_4$)**:
  - `(with-turn-coroutine #:slices k #:turn-cycles cyc body ...)` slices heavy puzzle or AI evaluations across $k$ consecutive frames, reducing per-frame active cycles to $\lceil \text{cyc} / k \rceil + 42 \le 29,780$.
  - `(with-vram-delta-queue #:slices m #:vram-bytes b body ...)` drains large Nametable updates across $m$ VBlank interrupts, keeping per-NMI `$2007` transfers $\lceil b / m \rceil \le 128\text{ B}$ and VBlank cycles $\le 2,273$.

```racket
;; Phase-typed VBlank NMI vs. ActiveFrame separation:
;; 1. VBlank NMI block: OAM DMA (514 cyc) + BCD HUD update (20 cyc) + Scroll Restore (18 cyc)
(define nmi-vblank-ops
  (list (hasheq 'op 'oam-dma!        'phase 'VBlankNMI)
        (hasheq 'op 'nametable-patch! 'phase 'VBlankNMI)
        (hasheq 'op 'restore-scroll!  'phase 'VBlankNMI 'x 0 'y 0)))

;; 2. ActiveFrame block: Mid-frame Sprite 0 HUD split + 8.8 physics + OAM shadow packing ($0200-$02FF)
;;    (Attempting 'nametable-patch! in 'ActiveFrame is statically rejected by check-L3-phase-and-totality!)
```

| Rule ID | Invariant Family | Enforced Hardware Bound | Auto-Repair Pass (`repair-nes-module`) |
| :--- | :--- | :--- | :--- |
| **`L1`** | Zero-Page & 6502 Stack Conservation | `CapConflict`-free ZP, `0` leaked scratch refs, `PHA == PLA` before `RTS`, collision-free `defzp-map` | `relocate-colliding-pinned-zp-address` |
| **`L2`** | Bank-Residency, Bus-Conflict & WRAM | Cross-bank `JSR` via `$C000` trampoline, `UNROM` identity table, `MMC1` atomic shift guard, WRAM enable | `synthesize-fixed-bank-far-call-trampoline`, `synthesize-unrom-bus-conflict-identity-table`, `insert-mmc1-serial-nmi-guard` |
| **`L3`** | 2C02 Phase Discipline & Totality | No `$2006`/`$2007`/`$4014` in `ActiveFrame`, exhaustive dispatch, Sprite 0 opaque overlap, FSM totality | `place-sprite0-on-opaque-hud-tile`, `inject-failure-state-respawn-transition`, `connect-disconnected-victory-state` |
| **`L4`** | `$2006`/`$2007` Scroll Latch & DMC Joypad | `(restore-scroll! x y)` before `RTI`, double-read `$4016` polling when 2A03 `dmc` channel is active | `insert-restore-scroll-latch`, `upgrade-joypad-dmc-double-read` |
| **$\Phi_1$** | CPU Cycle & Page-Crossing Budget | $\text{WCET}_{\text{VBlank}} \le 2,273\text{ cyc}$, $\text{WCET}_{\text{Active}} \le 29,780\text{ cyc}$, `0` unaligned page crossings | `stripe-vram-dma-ring-buffer`, `slice-turn-across-vblank-coroutines`, `align-256-rom-tables` |
| **$\Phi_2$** | OAM Total & Scanline Sprite Evaluation | $\le 64$ total OAM sprites ($256\text{ B}$), $\le 8$ sprites/scanline (or coprime OAM flicker mux enabled) | `move-static-tiles-to-nametable`, `enable-coprime-oam-flicker-mux` |
| **$\Phi_3$** | Memory Hierarchy Capacity | ZP peak $\le 224\text{ B}$, BSS $\le 1,280\text{ B}$ ($+ 8,192\text{ B}$ WRAM), PRG bank $\le 16\text{ KB}$, active CHR $\le 512$ tiles | `recycle-zp-scratch-high-watermark`, `rebalance-prg-rom-banks`, `convert-chr-rom-to-dynamic-chr-ram` |
| **$\Phi_4$** | VBlank Bandwidth, Clashes & Mirroring | $\le 128\text{ B}$ `$2007`/NMI, `0` $16\times 16$ attribute clashes, scroll axis aligned with nametable mirroring | `align-16x16-metatile-quadrants`, `align-nametable-mirroring-to-scroll-axis` |
| **$\Phi_5$** | 2A03 5-Channel APU Disjointness | Valid channels $\subseteq \{\texttt{pulse1}, \texttt{pulse2}, \texttt{triangle}, \texttt{noise}, \texttt{dmc}\}$, `0` unarbitrated concurrent writes | Priority-arbitrated APU channel envelopes |

---

### 2.4 Graphics, CHR Pattern Tables & Typography

#### `(defchr-layout id #:sprite-pt s #:bg-pt b #:blank-tile blank)`
Declares the 2C02 Pattern Table assignment (`0` = `$0000–$0FFF`, `1` = `$1000–$1FFF`) and computes the exact `PPUCTRL` (`$2000`) byte (`#x80 | (bg-pt << 4) | (sprite-pt << 3)`):
```racket
;; Sprites in PT0 ($0000), Backgrounds in PT1 ($1000), Blank Sky tile at #x24 => PPUCTRL = #x90
(defchr-layout smb-chr-layout
  #:sprite-pt  0
  #:bg-pt      1
  #:blank-tile #x24)
```

#### `(defchar-map id #:digit-base d #:alpha-base a #:space-tile sp #:extra alist)`
Maps ASCII strings to nametable tile indices. Placing digits `'0'..'9'` at tile IDs `#x00..#x09` enables **zero-offset BCD HUD rendering**: writing a single-digit counter in VBlank requires only `LDA zp_counter; STA $2007` with zero `ADC #offset` instructions.

```racket
(defchar-map smb-hud-font
  #:digit-base #x00
  #:alpha-base #x0A
  #:space-tile #x24
  #:extra      (list (cons #\- #x28) (cons #\x #x29) (cons #\! #x2B) (cons #\* #x2E)))
```

#### `(defsprite-tile id #:tile tid #:attr attr)` & `(defmetasprite id #:tiles list #:order ord #:attr attr)`
Declares hardware sprites (`1` OAM slot) and $16\times 16$-pixel ($2\times 2$-tile, `4` OAM slots, `2` scanline sprites) composite metasprites. `defmetasprite` supports all three commercial NES CHR tile conventions ([`lib/nes-chr-assets.rkt`](../lib/nes-chr-assets.rkt)):
1. **`'row-major`** (*Super Mario Bros.*): `#:tiles (list TL TR BL BR)` — 4 distinct tiles ordered left-to-right, top-to-bottom.
2. **`'col-major`** (*The Legend of Zelda* Link): `#:tiles (list TL BL TR BR)` — 4 distinct tiles ordered in vertical $8\times 16$ columns.
3. **`'symmetric-col-major`** (*The Legend of Zelda* Octorok): `#:tiles (list TL BL)` — requires only **2 CHR tiles** for the left half and automatically sets OAM Horizontal Flip (`bit 6 = #x40`) on `TR` and `BR`, cutting CHR-ROM consumption by $50\%$.

```racket
;; 1. Row-major 4-tile metasprite (Small Mario: #x32=TL, #x33=TR, #x34=BL, #x35=BR)
(defmetasprite mario-metasprite
  #:tiles (list #x32 #x33 #x34 #x35)
  #:order 'row-major
  #:attr  #x00)

;; 2. Column-major 4-tile metasprite (Zelda Link: #x00=TL, #x01=BL, #x02=TR, #x03=BR)
(defmetasprite link-metasprite
  #:tiles (list #x00 #x01 #x02 #x03)
  #:order 'col-major
  #:attr  #x00)

;; 3. Symmetric column-major 2-tile metasprite (Red Octorok: #x70=TL, #x71=BL; TR/BR auto-H-flipped!)
(defmetasprite octorok-metasprite
  #:tiles (list #x70 #x71)
  #:order 'symmetric-col-major
  #:attr  #x02)

;; Emit 6502 instructions to write the 4 OAM slots at $0200 + offset:
(emit-oam-metasprite-6502 mario-metasprite MARIO-ZP-SCREEN-X MARIO-ZP-Y-PX #x04)
```

---

### 2.5 Full-Campaign State Machines (`defstate-machine`)

`(defstate-machine sm-id #:initial init-sym ([state-sym #:kind kind-sym #:transitions (target-sym ...)] ...))` declares a game's phase/world transition graph. During `check-L3-phase-and-totality`, `check-state-machine-totality` statically enforces three properties:
1. **Target Closure**: Every transition target `target-sym` must be a declared state in `sm-id` (no dangling phase IDs).
2. **Non-Terminal Failure Recovery (`unrecoverable-failure-softlock`)**: Every state whose `#:kind` is in `'(failure dying dead defeat game-over top-out)` must possess at least one outgoing recovery transition (e.g., `START` respawn back to the active stage), preventing permanent player soft-locks on death.
3. **BFS Campaign Victory Reachability (`unreachable-victory-state`)**: Every state whose `#:kind` is in `'(victory completed win)` must be reachable via breadth-first search from `#:initial`.

```racket
(defstate-machine smb-campaign-fsm
  #:initial world-1-1
  ([world-1-1        #:kind normal  #:transitions (world-1-2 dying)]
   [world-1-2        #:kind normal  #:transitions (world-4-1 dying)]
   [world-4-1        #:kind normal  #:transitions (world-8-4 dying)]
   [world-8-4        #:kind normal  #:transitions (princess-rescued dying)]
   [dying            #:kind failure #:transitions (world-1-1 world-1-2 world-4-1 world-8-4)]
   [princess-rescued #:kind victory #:transitions (world-1-1)]))
```

---

### 2.6 Multi-Bank Cartridges (`defprg-bank`, `defbanked-table`, `far-call`)

For games exceeding $32\text{ KB}$ of PRG-ROM (`UNROM`, `MMC1`, `MMC3`), `#lang boba-nes` partitions code and data into switchable $16\text{ KB}$ banks (`$8000–$BFFF`) and a fixed $16\text{ KB}$ engine bank (`$C000–$FFFF`):
- **`(defprg-bank bank-id #:bank n forms-expr)` & `(defbanked-table table-id #:bank n bytes-or-forms)`**: Assembles switchable $16\text{ KB}$ PRG-ROM code or read-only level/asset tables (`RomBorrow` capability) at origin `$8000`, statically verifying that each bank's footprint fits within the $16,384$-byte `$8000–$BFFF` window ($\Phi_3$: `prg-single-bank-overflow`).
- **`(far-call target-bank target-label #:caller-bank cb #:trampoline? #t)`**: Emits a cross-bank call sequence that stores `target-label` in Zero Page (`$0C/$0D`), loads `target-bank` into `Y`, and calls `far_call_trampoline` in the fixed bank (`$C000–$FFFF`).
- **`(emit-bank-trampoline-6502 #:mapper m #:bank-count k)`**: Synthesizes the page-aligned `bank_identity_table` (eliminating `UNROM` CPU/ROM bus conflicts via `STA bank_identity_table,Y`) or the 5-write `MMC1` serial shift sequence, saves the caller's bank on the 6502 stack (`PHA`), switches banks, executes `JMP ($000C)`, and restores the caller's bank (`PLA; TAY; JSR switch_prg_bank_y; RTS`).

```racket
;; Switchable Bank 0 ($8000-$BFFF): Compressed World 1..4 Level Table & Unpacker
(defprg-bank prg-bank-0 #:bank 0
  `((label bank0_unpack_world1)
    (LDA #:imm #x11)
    (STA #:abs #x6000)
    (RTS)))

;; Cross-bank invocation from Fixed Bank 15 ($C000-$FFFF) -> Bank 0 ($8000)
(far-call 0 'bank0_unpack_world1 #:caller-bank 15 #:trampoline? #t)
```

---

### 2.7 Genre & 2A03 APU Libraries (`lib/`)

| Library File | Exported Emitters & Utilities | Purpose |
| :--- | :--- | :--- |
| [`lib/genre-libraries.rkt`](../lib/genre-libraries.rkt) | `emit-fixed-point-8.8-step-6502`, `emit-sprite0-hud-split-6502`, `emit-camera-scroll-follow-6502` | **Platformer Library**: 16-bit signed `8.8` subpixel gravity/velocity integration, Sprite-0 HUD split, and horizontal camera tracking. |
| [`lib/genre-libraries.rkt`](../lib/genre-libraries.rkt) | `emit-oam-coprime-flicker-6502`, `emit-directional-offset-6502`, `emit-invincibility-damage-handler-6502` | **Top-Down Adventure Library**: Coprime $+20\text{ B}$ ($5$-sprite, $\gcd(5,64)=1$) OAM slot rotation, 4-way melee hitbox offsets, and i-frame health/death handling. |
| [`lib/genre-libraries.rkt`](../lib/genre-libraries.rkt) | `emit-galois-lfsr-step-6502`, `emit-staged-vblank-row-copier-6502`, `emit-topout-and-reset-guard-6502` | **Falling-Block Puzzle Library**: $x^8+x^6+x^5+x^4+1$ (`#xB8`) Galois LFSR PRNG, 2-row/NMI (`20 B`) dirty-row VRAM stripe copier, and well top-out guard. |
| [`lib/genre-libraries.rkt`](../lib/genre-libraries.rkt) | `emit-vblank-hud-bcd-delta-6502`, `emit-stage-progression-handler-6502` | **Cross-Genre Campaign Library**: 20-cycle single-digit BCD HUD updater and multi-stage progression / campaign completion state handler. |
| `lib/apu-sequencer.rkt` | `emit-apu-init-6502`, `emit-apu-sfx-pulse1-6502`, `emit-apu-sfx-pulse2-6502`, `emit-apu-triangle-bass-6502`, `emit-apu-noise-percussion-6502` | **2A03 5-Channel APU Sequencer & SFX Library**: Disjoint channel envelope triggers (`$4000–$4015`) verified by $\Phi_5$ (`check-Phi5-apu-channels`) for zero unarbitrated channel contention. |
| [`lib/nes-chr-assets.rkt`](../lib/nes-chr-assets.rkt) | `parse-ines-header`, `extract-ines-chr-rom`, `extract-ines-prg-slice`, `deduplicate-chr-tiles`, `flip-chr-tile-horizontal` | **CHR & Asset Library**: iNES header/slice extraction, ASCII 2bpp tile decoding, and automatic exact + H-flip CHR tile deduplication. |
| [`lib/boba-badge-style.rkt`](../lib/boba-badge-style.rkt) | `FONT-3X5`, `make-word-tile-pair`, `emit-boba-badge-chr-ram-upload-6502` | **Dynamic CHR-RAM Word Badge Synthesizer**: Compiles 4-letter strings into $16\times 8$ beveled pill-badge tile pairs uploaded to writable CHR-RAM during `ForcedBlank`. |

---

## 3. Step-by-Step Guide to Decompiling Commercial `.nes` ROMs

The decompiler and static/dynamic analysis toolkit in [`tools/nes-rom-decompiler.rkt`](../tools/nes-rom-decompiler.rkt) and [`tools/nes-resource-tool.rkt`](../tools/nes-resource-tool.rkt) lifts raw commercial `.nes` binaries into structured `#lang boba-nes` S-expression modules and verifies them against authentic execution traces.

### 3.1 Static Recursive-Descent Disassembly, Multi-Bank Lifting & 6502 Idiom Detection

```racket
#lang racket/base
(require "tools/nes-rom-decompiler.rkt"
         "tools/nes-resource-tool.rkt")

;; 1. Disassemble an iNES 1.0 ROM starting from RESET ($FFFC), NMI ($FFFA), and IRQ ($FFFE) vectors
(define smb-dis (disassemble-ines-rom "assets/roms/super_mario_bros.nes"))
(printf "Mapper: ~a, PRG: ~a B, CHR tiles: ~a, ZP addrs: ~a, Subroutines: ~a, Insts: ~a\n"
        (hash-ref smb-dis 'mapper-name)
        (hash-ref smb-dis 'prg-bytes)
        (hash-ref smb-dis 'nonblank-chr-tiles)
        (hash-ref smb-dis 'zp-count)
        (hash-ref smb-dis 'subroutine-count)
        (hash-ref smb-dis 'instruction-count))

;; 2. Lift a single-bank (NROM) or multi-bank (MMC1/UNROM) ROM into a #lang boba-nes S-expression module
(define smb-dsl   (decompile-ines-rom-to-boba-dsl "assets/roms/super_mario_bros.nes"
                                                  #:game-name 'super-mario-bros))
;; For multi-bank cartridges (e.g., The Legend of Zelda, 8 x 16 KB MMC1 PRG-ROM banks),
;; decompile-multibank-ines-rom disassembles every switchable $8000-$BFFF bank alongside Fixed Bank 7 ($C000-$FFFF):
;; (define zelda-banks (decompile-multibank-ines-rom "assets/roms/legend_of_zelda.nes"))

;; 3. Detect 6502 Jump-Engine idioms: JMP ($xxxx) indirect tables and PHA+PHA+RTS stack dispatchers
;;    (e.g., Super Mario Bros. OperMode_Task / JumpEngine, Excitebike & Bomberman PHA+RTS dispatchers)
(define jump-idioms (detect-6502-jump-engine-idioms smb-dis))
(printf "Indirect JMPs: ~a, Stack RTS Dispatchers: ~a\n"
        (hash-ref jump-idioms 'indirect-jmp-count)
        (hash-ref jump-idioms 'rts-dispatch-count))

;; 4. Additional Static Idiom & Data-Format Detectors:
;;    - (detect-zp-timer-array-idioms dis)     : Finds `DEC zp,X / BPL` frame countdown timer arrays
;;    - (detect-nmi-sync-semaphore-idioms dis) : Finds `LDA zp / BEQ loop` main-thread NMI wait semaphores
;;    - (decode-smb-area-objects bytes)        : Decodes 2-byte SMB1 `(coords, object-type)` level area streams
;;    - (parse-fm2-tas-inputs fm2-path)        : Parses FCEUX `.fm2` TAS movie frame logs into 8-bit button masks

;; 5. Compare an authentic commercial ROM against a compiled #lang boba-nes ROM binary
(define cmp (compare-rom-binaries "assets/roms/super_mario_bros.nes" "build/mario_nes.nes"))
(printf "CHR Exact Match: ~a / ~a bytes (~a matching 8x8 tiles)\n"
        (hash-ref cmp 'chr-exact-match-bytes)
        (hash-ref cmp 'chr-total-bytes)
        (hash-ref cmp 'chr-matching-tiles))
```

### 3.2 Dynamic Trace Role Classification & Multi-Stage Progression Inference

Static disassembly alone cannot always distinguish whether Zero-Page address `$001E` holds a player coordinate, an LFSR PRNG seed, or a BCD HUD counter. `infer-zp-roles-from-frame-trace` and `detect-multi-stage-progression-from-trace` analyze chronological 256-byte Zero-Page snapshots captured across gameplay frames:

```racket
;; Classify every active Zero-Page address ($00-$FF) from a sequence of 256-byte frame snapshots:
;;   - 'monotonic-frame-counter : Δv == +1 (mod 256) every frame
;;   - 'prng-lfsr               : evolves via Galois LFSR step (v >> 1) ^ ((v & 1) ? #xB8 : 0)
;;   - 'hud-bcd-counter         : monotonically non-decreasing small integer in [0..99]
;;   - 'game-phase-or-flag      : discrete state flag in {0, 1, 2, 3}
;;   - 'player-or-actor-coord   : bounded per-frame velocity delta in [-16..+16]
(define zp-roles (infer-zp-roles-from-frame-trace zp-frame-snapshots))

;; Automatically discover multi-stage campaign registers (0 -> 1 -> 2 -> 3),
;; failure-then-recovery flags (0 -> 1 -> 0 on START respawn), and campaign completion flags (0 -> 1):
(define campaign-info (detect-multi-stage-progression-from-trace zp-frame-snapshots))
```

### 3.3 Running the Frame-by-Frame Side-by-Side Memory Differ

The Node.js differential harness boots both the authentic commercial `.nes` ROM and the compiled `#lang boba-nes` ROM simultaneously in two lockstep `jsnes` instances, feeding deterministic controller trajectories (covering both **Trajectory A: Hazard Failure $\to$ `START` Recovery** and **Trajectory B: Multi-Stage Campaign Victory**) and comparing PPU Palette RAM (`$3F00–$3F1F`, `32 B`), Nametable 0 (`$2000–$23BF`, `960 B`), Attribute Table 0 (`$23C0–$23FF`, `64 B`), CHR Pattern Tables (`$0000–$1FFF`, `8,192 B`), OAM sprites (`$0200–$02FF`), and Work RAM on every single frame:

```bash
# Run the 3-game full-campaign frame-by-frame differ (SMB 798 frames, Zelda 150 frames, Tetris 141 frames)
# Outputs: assets/decompiled/diff_report.json and screenshots/diff_{smb,zelda,tetris}_side_by_side.png
node emulator-harness/side-by-side-differ.mjs

# Extract gameplay PPU/OAM states and run the 10-game NROM/MMC1 classic arcade differ
node emulator-harness/inspect-top10-roms.mjs
node emulator-harness/diff-top10-roms.mjs
```

---

## 4. Case Study: Building 3 Original NES Games Purely in `#lang boba-nes`

To demonstrate that `#lang boba-nes` is a general-purpose, multi-genre NES systems language—not merely a decompilation target—the repository includes three complete, original games written from scratch in `#lang boba-nes` using procedural 2bpp CHR graphics, custom palettes, and full state machines:

### 4.1 *Star Courier: Kestral Run* (`examples/star_courier.bnes`) — Horizontal Space Shoot-'Em-Up

- **Genre & Mechanics**: 60 fps horizontal scrolling space shooter across 3 sectors (`Sector 1: Asteroid Belt` $\to$ `Sector 2: Pirate Blockade` $\to$ `Sector 3: Dreadnought Core`). Features `8.8` fixed-point ship thrust/inertia (`emit-fixed-point-8.8-step-6502`), dual laser projectiles, wave-oscillating interceptor drones, shield/hull damage with invincibility frames (`emit-invincibility-damage-handler-6502`), and a mid-frame **Sprite 0 Hit** stationary top telemetry HUD (`emit-sprite0-hud-split-6502`).
- **Graded Hardware Profile**:
  - **Mapper & Mirroring**: `NROM-256` (`32 KB` PRG, `8 KB` CHR-ROM, `'vertical` mirroring for horizontal starfield scrolling).
  - **OAM Multiplexing ($\Phi_2$)**: Uses `emit-oam-coprime-flicker-6502` (`+20 B` stride) so player ship + 2 lasers + 4 interceptors + explosions (`12` scanline sprites peak) never permanently drop on a single scanline.
  - **Campaign FSM ($L_3$)**: `sector-1 -> sector-2 -> sector-3 -> kestral-victory`, with `hull-breach` (`#:kind failure`) recovering to the current sector via `START`.

### 4.2 *Crypt Sweep: Chronomancer's Vault* (`examples/crypt_sweep.bnes`) — Top-Down Grid Relic Tactics

- **Genre & Mechanics**: Turn-based / real-time hybrid dungeon crawler across 4 vaults (`Vault 1: Sun Dial` $\to$ `Vault 2: Mirror Hall` $\to$ `Vault 3: Hourglass Abyss` $\to$ `Vault 4: Chronos Sanctum`). The player navigates $16\times 16$-pixel metatile chambers, collects Chrono-Shards, triggers time-freeze switches that pause patrolling Wraiths via a Zero-Page countdown timer array, and unlocks the sanctum gate.
- **Graded Hardware Profile**:
  - **Attribute-Clash-Free Metatiles ($\Phi_4$)**: Every dungeon floor, wall, switch, and gate is aligned to a $2\times 2$-tile ($16\times 16$-pixel) quadrant (`a_clash = 0`).
  - **Symmetric Metasprites ($\Phi_3$)**: Uses `#:order 'symmetric-col-major` for the Chronomancer and Wraith actors, halving sprite CHR tile consumption via hardware OAM horizontal flip (`#x40`).
  - **High-Watermark Zero-Page Reuse ($\Phi_3$)**: Recycles a 10-byte Zero-Page scratch pool across `input-step`, `wraith-ai-step`, `relic-collision-step`, and `oam-pack-step`.

### 4.3 *Neon Strider: Cyber Grid 1989* (`examples/neon_strider.bnes`) — Gravity-Flip Cyber Action Platformer

- **Genre & Mechanics**: High-speed cyberpunk action platformer where pressing `B` inverts vertical gravity (`+0.375 px/frame²` $\leftrightarrow$ `-0.375 px/frame²`), allowing the runner to sprint along both the lower highway deck and upper neon ceiling rails to bypass laser barriers, collect Data Cores, and reach the Mainframe Uplink across 3 grid zones.
- **Graded Hardware Profile**:
  - **Signed 8.8 Gravity Inversion ($\Phi_1$)**: Combines `emit-fixed-point-8.8-step-6502` with a dynamic sign-flipped acceleration register and OAM Vertical Flip (`bit 7 = #x80`) when running inverted on the ceiling.
  - **VBlank Delta Stripe Queue ($\Phi_1, \Phi_4$)**: Streams animated neon grid barriers and HUD Data Core counters in `644 / 2,273` VBlank cycles (`1,629` cycles of positive NTSC VBlank slack) with `0` page crossings.
