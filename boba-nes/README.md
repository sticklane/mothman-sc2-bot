# `#lang boba-nes`: Coeffect–Effect Type-Graded Racket DSL & Compiler for the NES

`#lang boba-nes` is a Racket domain-specific language and MOS 6502 / Ricoh 2C02 compiler for the **Nintendo Entertainment System (NES / Famicom)** that encodes hardware resource invariants directly into a **coeffect–effect graded type system**.

Its flagship target is a complete, bootable, 5-stage NES cartridge ROM of **"Boba Is You"** ([`examples/boba_is_you.bnes`](examples/boba_is_you.bnes) $\to$ [`build/boba_is_you.nes`](build/boba_is_you.nes), `40,976` bytes iNES 1.0 NROM-256).

---

## 1. Architecture & Graded Type System Overview

Every `#lang boba-nes` module is checked against the single cohesive coeffect–effect judgment:

$$\Gamma_{\text{in}} \mathbin{@} (\pi, b) \vdash t : \mathcal{C}_{g}(A) \dashv \Gamma_{\text{out}} \mathbin{@} (\pi', b')$$

### 1.1 Five-Element Memory & Hardware Capability Semiring ($\mathsf{CapMem}$)

$$\mathsf{ConstMeta} < \mathsf{RomBorrow} < \mathsf{PpuTaint} < \mathsf{RamLinear} < \mathsf{DmaUnique}$$

| Capability Grade | NES Hardware Interpretation | Parallel Rule ($q_1 \oplus q_2$) | Runtime Footprint |
| :--- | :--- | :--- | :--- |
| `ConstMeta` ($0$) | Erased compile-time tile IDs, rule bitmasks, SoA offsets | Identity (`0 + q = q`) | `0` ZP / `0` RAM bytes |
| `RomBorrow` | Read-only PRG-ROM lookup tables (`$8000–$FFFF`) | Idempotent (`RomBorrow`) | `0` RAM bytes |
| `PpuTaint` | `$2006`/`$2007` write tainting shared 2C02 `t`/`v`/`w` scroll latch | Requires `(restore-scroll! x y)` before `RTI` | PPU internal latch |
| `RamLinear` | Mutable Zero-Page (`$00–$FF`) or Work RAM (`$0300–$07FF`) state | Linear (`RamLinear + RamLinear = CapConflict`) | $n$ bytes ZP/RAM |
| `DmaUnique` | Exclusive `$0200–$02FF` OAM DMA shadow page or recyclable ZP scratch | Unique (`DmaUnique + RamLinear = CapConflict`) | $256\text{ B}$ OAM / $k\text{ B}$ scratch |

### 1.2 Four Logical Hardware Safety Families ($\mathsf{L1}\text{–}\mathsf{L4}$)

- **`L1` (Zero-Page Conservation & 6502 Stack Balance)**: Forbids linear Zero-Page aliasing, detects leaked `(with-zp-scratch ...)` pointers, and proves every subroutine balances `PHA`/`PHP` with `PLA`/`PLP` before `RTS`/`RTI`.
- **`L2` (Cartridge Bank-Residency, Trampoline, Bus-Conflict & WRAM Safety)**: Tracks active vs. fixed PRG-ROM banks (`$8000–$BFFF` vs. `$C000–$FFFF`) across `NROM`, `UNROM` (Mapper 2), `MMC1` (Mapper 1 `SXROM`), and `MMC3` (Mapper 4 `TXROM`). Detects direct cross-bank `JSR` without a fixed-bank trampoline, `UNROM` CPU/ROM bus conflicts missing a ROM identity table, `MMC1` 5-write serial shift-register NMI re-entrancy hazards, and unmapped/disabled `$6000–$7FFF` Cartridge `WRAM` accesses.
- **`L3` (2C02 PPU Temporal Phase Discipline & Total Dispatch)**: Forbids `$2006`/`$2007` VRAM writes and `$4014` `OAMDMA` during `ActiveFrame` rendering, and verifies exhaustiveness of noun/verb rule dispatch tables.
- **`L4` (`$2006`/`$2007` Scroll-Latch Taint & 2A03 DMC Joypad Glitch Safety)**: Rejects any `VBlankNMI` handler that writes `$2006`/`$2007` without discharging `PpuTaint` via `(restore-scroll! x y)` (`BIT $2002` + `STA $2000` + `STA $2005` $\times 2$), and prevents 2A03 DPCM DMA cycle-stealing bit deletion on `$4016` joypad reads.

### 1.3 Five Orthogonal Physical Resource Grades ($\Phi_1\text{–}\Phi_5$) across NROM & Banked Cartridges

| Grade Component | NROM-256 Limit (`boba_is_you.bnes`) | Banked SXROM Limit (`boba_200_levels_cartridge.bnes`) |
| :--- | :--- | :--- |
| **$\Phi_1$ VBlank NMI Cycles** | **$612 / 2,273\text{ cyc}$** (`OAMDMA` = $514\text{ cyc}$) | **$1,420 / 2,273\text{ cyc}$** |
| **$\Phi_1$ ActiveFrame / Coroutine** | **$3,680 / 29,780\text{ cyc}$** (single-frame turn) | **$21,042 / 29,780\text{ cyc/frame}$** ($42,000\text{ cyc}$ across $k=2$ coroutine slices) |
| **$\Phi_1$ Page-Crossing Hazards** | **$0\text{ crossings}$** | **$0\text{ crossings}$** (static 6502 `WCET` verified) |
| **$\Phi_2$ Total OAM Sprites** | **$38 / 64\text{ sprites}$** ($152\text{ B}$) | **$32 / 64\text{ sprites}$** ($128\text{ B}$) |
| **$\Phi_2$ Scanline Sprites** | **$8 / 8\text{ sprites/scanline}$** | **$8 / 8\text{ sprites/scanline}$** |
| **$\Phi_3$ Zero-Page Live / Peak** | **$21\text{ B live} / 27\text{ B peak}$** ($\le 224\text{ B}$) | **$59\text{ B live} / 71\text{ B peak}$** ($\le 224\text{ B}$) |
| **$\Phi_3$ BSS + Cartridge WRAM** | **$448 / 1,280\text{ B}$** (internal `$0300–$04DF`) | **$8,896 / 9,472\text{ B}$** ($768\text{ B}$ BSS + $8,128\text{ B}$ `$6000–$7FFF` WRAM) |
| **$\Phi_3$ PRG-ROM Capacity** | **$1,977 / 32,768\text{ B}$** ($2\times 16\text{ KB}$) | **$53,248 / 262,144\text{ B}$** ($16\times 16\text{ KB}$ banked PRG-ROM) |
| **$\Phi_3$ CHR-ROM / Dynamic CHR-RAM** | **$36 / 512\text{ tiles}$** ($8\text{ KB}$ CHR-ROM) | **$56 / 512\text{ active tiles}$** in $8\text{ KB}$ `CHR-RAM` (from $580$ PRG tiles) |
| **$\Phi_4$ VBlank VRAM Transfer** | **$8 / 128\text{ B/frame}$** | **$60 / 128\text{ B/frame}$** ($180\text{ B}$ drained across $m=3$ VBlank slices) |
| **$\Phi_4$ $16\times 16$ Attr Clashes** | **$0\text{ clashes}$** | **$0\text{ clashes}$** |
| **$\Phi_5$ 2A03 APU Channels** | **`{pulse1, triangle, noise}`** | **`{pulse1, pulse2, triangle, noise}`** |

---

## 2. Scaling to 200+ Levels (`defcartridge`, `defprg-bank`, `far-call`, `with-turn-coroutine`)

To support all 231 levels of the full base game, `#lang boba-nes` provides hardware-graded abstractions for larger mappers (`UNROM`, `MMC1 SXROM`, `MMC3 TXROM`):
- **`(defcartridge name budget-id #:mapper ... #:prg-banks ... #:chr-mode ... #:wram-bytes ...)`**: Declares a cartridge specification and derives its `nes-budget` (`NTSC-UNROM-128-BUDGET`, `NTSC-MMC1-SXROM-BUDGET`, `NTSC-MMC3-TXROM-BUDGET`).
- **`(defprg-bank id #:bank n forms)` & `(far-call bank target)`**: Assembles switchable 16 KB `$8000–$BFFF` PRG-ROM banks and invokes cross-bank targets through a synthesized fixed-bank (`$C000–$FFFF`) `far_call_trampoline` that saves/restores the caller's bank on the 6502 hardware stack and indexes `bank_identity_table` for bus-conflict-free switching.
- **`(emit-chr-ram-word-upload-6502 alist)`**: Synthesizes $16\times 8$ (`2-tile`) word badges dynamically at level load from the 130-byte 26-letter $3\times 5$ bitmap font (`FONT-3X5`) into writable 8 KB `CHR-RAM` (`$0000–$1FFF`), overcoming the 512-tile `CHR-ROM` ceiling.
- **`(with-turn-coroutine #:slices k #:turn-cycles c ...)` & `(with-vram-delta-queue #:slices m #:vram-bytes b ...)`**: Cooperatively slices heavy multi-rule puzzle turns (e.g., `EMPTY IS PUSH`) and mass World Event (`WALL IS BOBA`) Nametable updates across multiple VBlank frames while keeping 60 Hz sprite animation and APU audio uninterrupted.
- **`(analyze-6502-wcet forms #:origin addr)`**: Static instruction-level 6502 Worst-Case Execution Time (`WCET`) analyzer supporting nested `(loop-bound k body ...)` annotations, $+1$ taken-branch cycles, and $+514$ `$4014` `OAMDMA` stall cycles.

---

## 3. Multi-Genre NES Game Suite (*Super Mario Bros.*, *The Legend of Zelda*, *Tetris*) & Compiler Discoveries

To stress-test `#lang boba-nes` beyond turn-based grid puzzles across the full NES genre space, we implemented three additional complete playable NES games ([`compiler/nes-games-builder.rkt`](compiler/nes-games-builder.rkt)):
1. **Super Mario Bros. (World 1-1)** ([`examples/mario_platformer.bnes`](examples/mario_platformer.bnes) $\to$ [`build/mario_nes.nes`](build/mario_nes.nes)): Continuous `8.8` fixed-point subpixel gravity/jump physics (`emit-fixed-point-8.8-step-6502`), mid-frame **Sprite 0 Hit (`$2002` bit 6)** stationary top HUD + horizontal camera scrolling across Nametable 0 (`$2000`) & Nametable 1 (`$2400`, Vertical Mirroring), `?` Question Block headbutt coin spawning, Goomba stomp, and Flagpole victory.
2. **The Legend of Zelda (Overworld & Triforce Sanctum)** ([`examples/zelda_adventure.bnes`](examples/zelda_adventure.bnes) $\to$ [`build/zelda_nes.nes`](build/zelda_nes.nes)): Top-down action-adventure with $16\times 16$ Link & Red Octorok metasprites (`defmetasprite`, `emit-oam-metasprite-6502`), Coprime $+5$-sprite stride OAM flicker rotation (`emit-oam-coprime-flicker-6502`), directional `A`-button Sword thrust combat, Dungeon Key drop, locked North Door VRAM transition, and Triforce of Wisdom victory.
3. **Nintendo NES Tetris** ([`examples/tetris_nes.bnes`](examples/tetris_nes.bnes) $\to$ [`build/tetris_nes.nes`](build/tetris_nes.nes)): Real-time falling-tetromino puzzle with a $10\times 20$ (`200 B`) RAM well (`$0400–$04C7`), 7 tetrominoes $\times$ 4 rotations signed offset table, multiply-free `row10_table` indexing, full-row line clear + gravity collapse, and a staged VBlank dirty-row stripe copier (`2 rows = 20 B / NMI` across 10 frames).

### 7 Language & Compiler Problems Discovered and Solved

1. **6502 Relative Branch Range (`[-128, +127]` B) & Page-Crossing Jitter (`Phi1`)**: Complex game loops in Mario, Zelda, and Tetris exceeded 127 bytes and crossed 256-byte page boundaries (`+1` cycle penalty caught by `check-Phi1-cycles-and-page-cross`). Solved via iterative fixed-point branch relaxation (`relax-6502-branches` in [`compiler/mos6502-assembler.rkt`](compiler/mos6502-assembler.rkt)), rewriting out-of-range or page-crossing `Bxx target` into page-aligned `(inv-Bxx skip) (JMP target) (label skip)`.
2. **Mid-Frame `Sprite 0 Hit` (`$2002` Bit 6) Deadlock Hazard (`L3`)**: Polling `BIT $2002 / BVC` hangs the 6502 forever if Sprite 0 does not overlap an opaque background pixel. Added `sprite0-missing-opaque-overlap` to `check-L3-phase-and-totality`, automated repair `place-sprite0-on-opaque-hud-tile`, `emit-sprite0-hud-split-6502`, and `$2002` bit 6 simulation in `nes-emulator`.
3. **Nametable Mirroring vs. Scroll Axis Seam Clash (`Phi4`)**: Horizontal scrolling across `$2000`/`$2400` requires `vertical` mirroring (`$2000 \neq $2400`). Added `scroll-mirroring-seam-clash` to `check-Phi4-vram-and-attributes` and automated repair `align-nametable-mirroring-to-scroll-axis`.
4. **$16\times 16$ Metasprite Scanline Overflow (`Phi2`)**: Multi-tile actors (`4` OAM sprites/actor) in Mario & Zelda quickly exceed 8 sprites/scanline. Added `defmetasprite`, `emit-oam-metasprite-6502`, and Coprime OAM Flicker Multiplexing (`emit-oam-coprime-flicker-6502`).
5. **Subpixel Physics Expressiveness on an 8-Bit ALU**: Added `emit-fixed-point-8.8-step-6502` (`CLC/ADC` low subpixel byte + `ADC` high pixel byte) for smooth `8.8` fixed-point acceleration and velocity integration.
6. **Tetris Line-Clear VBlank Bandwidth Explosion (`Phi1` & `Phi4`)**: Shifting a 200-byte ($10\times 20$) well on a 4-line Tetris clear in a single NMI exceeds both the 128-byte `Phi4` cap and 2,273-cycle `Phi1` VBlank limit. Solved via a staged VBlank dirty-row stripe copier (`TETRIS-ZP-DIRTY-ROW`) flushing 2 rows (`20 B`) per NMI across 10 frames (`980 / 2273` VBlank cycles).
7. **Alphanumeric & Punctuation HUD Typography (`FONT-3X5`)**: Extended `FONT-3X5` in [`compiler/boba-rom-builder.rkt`](compiler/boba-rom-builder.rkt) with digits `0–9` and punctuation (`-`, `:`, `?`, `!`) for score, coin, world (`"W1 1"`), key, and line counters.

---

## 4. Repository Layout

- [`PRIOR_ART_AND_DESIGN.md`](PRIOR_ART_AND_DESIGN.md): Survey of retro console compilers (`CO2`, `Asi64`, `NESFab`, `Millfork`, `Wiz`, `KickC`, `llvm-mos`, `GB Studio`, `agb`), graded type systems, and real NES game architectures (*Super Mario Bros.*, *The Legend of Zelda*, *Nintendo NES Tetris*, *Mega Man 2*, *Super Mario Bros. 3*, *Battletoads*).
- [`compiler/graded-typechecker.rkt`](compiler/graded-typechecker.rkt): `CapMem` semiring, `nes-grade` algebra, multi-bank cartridge specs (`UNROM`/`MMC1`/`MMC3`), `L1–L4` and `Phi1–Phi5` checkers, and automated grade-driven repair pass (`repair-nes-module`).
- [`compiler/diagnostics.rkt`](compiler/diagnostics.rkt): 3-span provenance tracking (`surface-span`, `macro-span`, `lowered-6502`) and chordal SSA Zero-Page interval coloring (`allocate-zero-page-chordal`).
- [`compiler/mos6502-assembler.rkt`](compiler/mos6502-assembler.rkt): Two-pass MOS 6502 machine-code assembler with automatic branch & page-crossing relaxation (`relax-6502-branches`), static `WCET` cycle analyzer (`analyze-6502-wcet`), fixed-bank trampoline synthesizer (`emit-bank-trampoline-6502`), single/multi-bank iNES 1.0 `.nes` ROM linker (`build-ines-rom`, `build-banked-ines-rom`), and cycle-accurate 6502 + 2C02 PPU/OAM/Sprite-0/WRAM/CHR-RAM/Mapper verification emulator.
- [`compiler/boba-rom-builder.rkt`](compiler/boba-rom-builder.rkt): Complete 5-stage **"Boba Is You"** 6502 game engine and full `A–Z` + `0–9` $3\times 5$ bitmap font (`FONT-3X5`).
- [`compiler/nes-games-builder.rkt`](compiler/nes-games-builder.rkt): Complete 6502 + 2C02 compilers for **Super Mario Bros. (World 1-1)**, **The Legend of Zelda**, and **Nintendo NES Tetris**.
- [`boba-nes/main.rkt`](boba-nes/main.rkt) & [`boba-nes/lang/reader.rkt`](boba-nes/lang/reader.rkt): `#lang boba-nes` Racket reader and surface macros.
- [`examples/boba_is_you.bnes`](examples/boba_is_you.bnes), [`examples/boba_200_levels_cartridge.bnes`](examples/boba_200_levels_cartridge.bnes), [`examples/mario_platformer.bnes`](examples/mario_platformer.bnes), [`examples/zelda_adventure.bnes`](examples/zelda_adventure.bnes), [`examples/tetris_nes.bnes`](examples/tetris_nes.bnes): Complete compilable `#lang boba-nes` game cartridges.
- [`tests/boba-nes-tests.rkt`](tests/boba-nes-tests.rkt): **518-assertion** verification suite covering `CapMem`, chordal Zero-Page coloring, `L1–L4` / `Phi1–Phi5` detection & repair, `WCET` analysis, branch relaxation, and end-to-end 6502 gameplay execution of *Boba Is You* (NROM & 231-level banked), *Super Mario Bros.*, *The Legend of Zelda*, and *Tetris*.

---

## 5. Building & Running

```bash
# 1. Compile all 5 NES ROM cartridges (.bnes -> build/*.nes)
/home/antigravity/toolchains/racket/bin/racket examples/boba_is_you.bnes
/home/antigravity/toolchains/racket/bin/racket examples/boba_200_levels_cartridge.bnes
/home/antigravity/toolchains/racket/bin/racket examples/mario_platformer.bnes
/home/antigravity/toolchains/racket/bin/racket examples/zelda_adventure.bnes
/home/antigravity/toolchains/racket/bin/racket examples/tetris_nes.bnes

# 2. Run the 518-assertion typechecker, repair, WCET, banked cartridge, and 6502 ROM test suite
/home/antigravity/toolchains/racket/bin/racket tests/boba-nes-tests.rkt

# 3. Boot all ROMs in the third-party jsnes emulator and capture PNG screenshots
node emulator-harness/run-jsnes.mjs
node emulator-harness/run-games-jsnes.mjs
```


