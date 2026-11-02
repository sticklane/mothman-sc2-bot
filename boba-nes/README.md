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
- **`L2` (Cartridge Bank-Residency & Trampoline Safety)**: Tracks active vs. fixed PRG-ROM banks (`$8000–$BFFF` vs. `$C000–$FFFF`) across mapper bank switches.
- **`L3` (2C02 PPU Temporal Phase Discipline & Total Dispatch)**: Forbids `$2006`/`$2007` VRAM writes and `$4014` `OAMDMA` during `ActiveFrame` rendering, and verifies exhaustiveness of noun/verb rule dispatch tables.
- **`L4` (`$2006`/`$2007` Scroll-Latch Taint & 2A03 DMC Joypad Glitch Safety)**: Rejects any `VBlankNMI` handler that writes `$2006`/`$2007` without discharging `PpuTaint` via `(restore-scroll! x y)` (`BIT $2002` + `STA $2000` + `STA $2005` $\times 2$), and prevents 2A03 DPCM DMA cycle-stealing bit deletion on `$4016` joypad reads.

### 1.3 Five Orthogonal Physical Resource Grades ($\Phi_1\text{–}\Phi_5$)

| Grade Component | NTSC NES Hardware Limit | "Boba Is You" Verified Grade |
| :--- | :--- | :--- |
| **$\Phi_1$ VBlank NMI Cycles** | $\le 2,273\text{ cycles}$ (`OAMDMA` = $514\text{ cyc}$) | **$612\text{ cycles}$** ($26.9\%$ of budget) |
| **$\Phi_1$ ActiveFrame Cycles** | $\le 29,780\text{ cycles}$ ($60\text{ fps}$) | **$3,420\text{ cycles}$** ($11.5\%$ of budget) |
| **$\Phi_1$ Page-Crossing Hazards** | $0$ unaligned branch/table crossings | **$0\text{ page crossings}$** |
| **$\Phi_2$ Total OAM Sprites** | $\le 64\text{ sprites}$ ($256\text{ B}$ at `$0200–$02FF`) | **$32\text{ sprites}$** ($128\text{ B}$) |
| **$\Phi_2$ Scanline Sprites** | $\le 8\text{ sprites/scanline}$ | **$6\text{ sprites/scanline}$** |
| **$\Phi_3$ Zero-Page Live / Peak** | $\le 224\text{ B}$ (`$0010–$00EF`) | **$21\text{ B live} / 27\text{ B peak}$** ($4\times 6\text{ B}$ scratch recycled!) |
| **$\Phi_3$ BSS Work RAM** | $\le 1,280\text{ B}$ (`$0300–$07FF`) | **$448\text{ B}$** (`$0300–$04DF` dual-layer $16\times 14$ board) |
| **$\Phi_3$ PRG-ROM Code + Tables** | $\le 32,768\text{ B}$ (`$8000–$FFFF` NROM-256) | **$1,478\text{ B}$** |
| **$\Phi_3$ CHR-ROM 2bpp Tiles** | $\le 512\text{ tiles}$ ($8,192\text{ B}$) | **$19\text{ custom tiles}$** |
| **$\Phi_4$ VBlank VRAM Transfer** | $\le 128\text{ B/frame}$ via `$2007` | **$8\text{ B/frame}$** (HUD status stripe at `$2022`) |
| **$\Phi_4$ $16\times 16$ Attr Clashes** | $0$ quadrant palette clashes | **$0\text{ clashes}$** ($2\times 2$-tile metatile alignment) |
| **$\Phi_5$ 2A03 APU Channels** | Disjoint subset of `{pulse1, pulse2, triangle, noise, dmc}` | **`{pulse1, triangle, noise}`** |

---

## 2. Repository Layout

- [`PRIOR_ART_AND_DESIGN.md`](PRIOR_ART_AND_DESIGN.md): Survey of retro console compilers (`CO2`, `Asi64`, `NESFab`, `Millfork`, `Wiz`, `KickC`, `llvm-mos`, `GB Studio`, `agb`) and graded type systems (`Granule`, Ghica–Smith hardware semirings, QTT, Marshall–Vollmer–Orchard, `RAML`).
- [`compiler/graded-typechecker.rkt`](compiler/graded-typechecker.rkt): `CapMem` semiring, `nes-grade` algebra with high-watermark Zero-Page scratch reuse, `L1–L4` and `Phi1–Phi5` checkers, and automated grade-driven repair pass (`repair-nes-module`).
- [`compiler/diagnostics.rkt`](compiler/diagnostics.rkt): 3-span provenance tracking (`surface-span`, `macro-span`, `lowered-6502`) and chordal SSA Zero-Page interval coloring (`allocate-zero-page-chordal`).
- [`compiler/mos6502-assembler.rkt`](compiler/mos6502-assembler.rkt): Two-pass MOS 6502 machine-code assembler, `ca65` `.s` emitter, `2bpp` CHR tile compiler, iNES 1.0 `.nes` ROM linker, and cycle-accurate 6502 + 2C02 PPU/OAM/Joypad verification emulator.
- [`compiler/boba-rom-builder.rkt`](compiler/boba-rom-builder.rkt): Complete 5-stage **"Boba Is You"** 6502 game engine (dynamic horizontal/vertical `[NOUN] [IS] [VERB/NOUN]` rule scanner, `WALL IS BOBA` world-event noun transformation, multi-block push chain solver, `UNDER_RAM` passable tile preservation, dust/sparkle sprites, and APU sound effects).
- [`boba-nes/main.rkt`](boba-nes/main.rkt) & [`boba-nes/lang/reader.rkt`](boba-nes/lang/reader.rkt): `#lang boba-nes` Racket reader and surface macros.
- [`examples/boba_is_you.bnes`](examples/boba_is_you.bnes): Flagship `#lang boba-nes` program that compiles [`build/boba_is_you.nes`](build/boba_is_you.nes) and [`build/boba_is_you.s`](build/boba_is_you.s).
- [`tests/boba-nes-tests.rkt`](tests/boba-nes-tests.rkt): 157-assertion verification suite including full 6502 gameplay execution across all 5 stages of *Boba Is You*.

---

## 3. Building & Running

```bash
# 1. Compile examples/boba_is_you.bnes -> build/boba_is_you.nes & print hardware grade report
/home/antigravity/toolchains/racket/bin/racket examples/boba_is_you.bnes

# 2. Run the 157-assertion typechecker, repair, and 5-stage 6502 ROM gameplay test suite
/home/antigravity/toolchains/racket/bin/racket tests/boba-nes-tests.rkt
```
