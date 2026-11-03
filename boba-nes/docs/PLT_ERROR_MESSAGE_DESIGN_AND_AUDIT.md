# PLT Error Message Literature Audit, `syntax/parse` Macro Fortification & Resugaring/Blame Engine Architecture for `#lang boba-nes`

## 1. Executive Summary & Architectural Thesis

Domain-Specific Languages (DSLs) targeting bare-metal retro and embedded hardware (`#lang boba-nes` across 8-bit 6502 NES, Sharp SM83 Game Boy/Game Boy Color, 16-bit WDC 65C816 SNES, 32-bit ARM7TDMI Game Boy Advance, 64-bit MIPS VR4300 + RCP Nintendo 64, PICO-8 Fantasy Console, and Dual Cortex-M0+ + PIO RP2040) fail their users when syntax, type, capability, or hardware-budget errors leak the compiler's internal representation (`Boba-Core IR`, `cap-mem-access`, `ir-dma-transfer`, `rot4`, `eval-gba-expr`, `mode-state-m`, or raw `match: no matching clause` exceptions).

This document audits the `#lang boba-nes` compiler and multi-target graded typechecker against four foundational pillars of Programming Languages Theory (PLT) error-message research and specifies the design of [`compiler/plt-error-diagnostics.rkt`](../compiler/plt-error-diagnostics.rkt):

1. **Fortifying Macros (`syntax/parse`)** — *Culpepper & Felleisen (ICFP 2010, JFP 2012)*: Replacing fragile `define-syntax-rule` and unguarded `match` clauses with declarative syntax classes (`define-syntax-class`, `#:description`, `#:fail-when`, `#:fail-unless`) that validate target-dependent domain invariants at macro expansion / surface validation time and pinpoint the exact offending sub-datum (`at: <sub-term>`) within its enclosing surface declaration (`in: <surface-form>`).
2. **Vocabulary Consistency, Highlighting Specificity & Non-Presumptuous Multi-Site Repairs** — *Marceau, Fisler, & Krishnamurthi (SIGCSE 2011, Onward! 2011)*: Eliminating internal compiler vocabulary from all diagnostics, enforcing strict sub-term span specificity ($\text{span}(\text{at}) < \text{span}(\text{in})$), and presenting all conflicting witnesses and symmetric repair options without guessing which site represents the programmer's true intent.
3. **Provenance-Preserving Resugaring of Core IR & Type Judgments** — *Pombrio, Krishnamurthi, & Wand (PLDI 2014, ICFP 2015, ICFP 2017, PLDI 2018)*: Enforcing the Pombrio-Krishnamurthi Resugaring Invariant (*"Type rules and diagnostics for surface constructs must never mention core constructs"*) by unexpanding lowered `Boba-Core IR` terms (`ir-palette`, `ir-tileset`, `ir-metasprite`, `ir-dma-transfer`, `ir-mode-transition`, `ir-coproc-session`, `ir-campaign`) back to `#lang boba-nes` surface syntax (`defpalette`, `deftiles`, `defmetasprite`, `defvblank-dma`, `defcpu-mode`, `defcoproc-audio`, `defcampaign`).
4. **Higher-Order Contract Blame & Multi-Site Value-Flow / Pareto Witness Slices** — *Findler & Felleisen (ICFP 2002)*, *Flanagan, Flatt, Krishnamurthi, Weirich, & Felleisen (PLDI 1996, MrSpidey)*, and *Zhang & Myers (POPL 2014, SHErrLoc)*: Assigning formal Positive vs. Negative blame across hardware co-processor and bank boundaries (`65C816 <-> SPC700`, `VR4300 <-> RSP <-> RDP`, `RP2040 Core 0 <-> Core 1 / PIO`, `MMC1 switchable <-> fixed PRG bank`), reconstructing backward register def-use slices for illegal GBA 8-bit `STRB` video writes, extracting two-path control-flow witnesses for 65C816 `REP`/`SEP` mode conflicts, and computing Pareto-ranked minimal cut sets for resource semiring (`TargetGrade`) budget overflows.

---

## 2. Theoretical Foundations from the PLT Literature

### 2.1 Culpepper & Felleisen (ICFP 2010, JFP 2012) — *Fortifying Macros* (`syntax/parse`)

In *"Fortifying Macros"* (ICFP 2010; JFP 2012), Culpepper and Felleisen show that naive macro definitions written with `syntax-rules` or ad-hoc procedural destructuring suffer from two systemic failure modes:
- **Abstraction Leakage**: Syntax errors inside a macro body are reported in terms of the macro's *expansion* (e.g., `bitwise-and: contract violation` or `match: no matching clause for '(defpalette ...)`), exposing private implementation helpers.
- **Imprecise Blame Assignment**: Without structured syntax classes, macros fail to distinguish between a malformed outer clause shape and an out-of-range domain literal inside a sub-clause.

`syntax/parse` solves both problems through:
1. **Declarative Syntax Classes (`define-syntax-class`) with `#:description`**: Every grammar non-terminal carries a human-readable domain description (e.g., `"6-bit NES PPU palette color index (#x00..#x3F)"` or `"8-pixel 2bpp CHR tile row string ('0'..'3')"`).
2. **Side-Condition Guards (`#:fail-when`, `#:fail-unless`)**: Semantic domain invariants (such as signed `Q8.8` fixed-point bounds $[-128.0, +127.99609375]$ or campaign stage graph reachability) are checked directly on syntax objects, attaching failure blame to the specific offending sub-syntax `#'bad-token` while retaining the enclosing form `stx`.
3. **Progress-Ordered Failure Selection**: When multiple syntax patterns fail, `syntax/parse` orders failures by longest parse progress so the user receives a diagnostic about the deepest specific sub-term rather than a generic top-level syntax rejection.

### 2.2 Marceau, Fisler, & Krishnamurthi (SIGCSE 2011, Onward! 2011) — *Mind Your Language*

In *"Mind Your Language: On Novices' Interactions with Error Messages"* (Onward! 2011) and *"Measuring the Effectiveness of Error Messages Designed for Novice Programmers"* (SIGCSE 2011), Marceau, Fisler, and Krishnamurthi establish empirical criteria for effective error reporting:
1. **Vocabulary Consistency**: An error message must *only* use vocabulary from the surface language specification that the programmer wrote. If a `#lang boba-nes` user writes `(defvblank-dma ...)` or `(defpalette ...)`, the diagnostic must never mention internal compiler identifiers such as `ir-dma-transfer`, `cap-mem-access`, `cap-rank`, `mode-state-m`, `rot4`, or `eval-gba-expr`.
2. **Highlighting Specificity (`at:` vs. `in:`)**: Highlighting an entire 40-line `(defnes-game ...)` module or a synthetic `"surface-dsl:1:1"` location forces the programmer to linearly scan the entire program. Every diagnostic must separate the exact offending sub-datum (`at: #x7F`) from the enclosing surface form (`in: (defpalette hero-pal #x0F #x7F #x20 #x30)`), satisfying $\text{length}(\text{at}) < \text{length}(\text{in})$.
3. **Non-Presumptuous Multi-Site Repair Guidance**: When two program points conflict—such as Path 1 setting 65C816 `M=8` via `(SEP #$20)` at line 12 and Path 2 setting `M=16` via `(REP #$20)` at line 27 before joining at `loop:`—the compiler **cannot know** whether the programmer intended `loop:` to run in 8-bit or 16-bit accumulator mode. Guessing one side as "the bug" misleads users half the time. Instead, the compiler must present both witness paths symmetrically and offer dual repairs:
   - *Option A (if `loop` expects 8-bit `M=8`)*: insert `(SEP #$20)` on Path 2 before `BRA loop`.
   - *Option B (if `loop` expects 16-bit `M=16`)*: insert `(REP #$20)` on Path 1 before falling through to `loop`.

### 2.3 Pombrio, Krishnamurthi, & Wand (PLDI 2014, ICFP 2015, ICFP 2017, PLDI 2018) — *Resugaring*

In *"Resugaring: Lifting Evaluation Sequences through Syntactic Sugar"* (PLDI 2014), *"Hygienic Resugaring of Compositional Desugaring"* (ICFP 2015), and *"Inferring Type Rules for Syntactic Sugar"* (PLDI 2018), Pombrio, Krishnamurthi, and Wand formalize the relationship between a surface DSL ($\mathcal{L}_{\text{surface}}$) and a core intermediate language ($\mathcal{L}_{\text{core}}$):
- **Goal 1 (Provenance Tagging)**: Every core AST node produced during lowering/desugaring carries provenance metadata linking it back to the surface syntax constructor and source span that generated it.
- **Goal 2 (Surface-Level Type & Capability Judgments)**: *"Type rules for surface constructs should not mention core constructs."* When the multi-target graded typechecker (`compiler/multi-target-typechecker.rkt`) rejects a lowered `Boba-Core IR` node `(mem-write s-ppu-vram dma 256 active cache-flushed 512)`, the resugaring engine lifts that core term back to `(defvblank-dma s-ppu-vram #:bytes 512 #:align 256 #:phase 'active)` before formatting the diagnostic.

```
  Surface DSL (#lang boba-nes)                  Boba-Core IR (Lowered)
 ┌──────────────────────────────┐   Desugar    ┌─────────────────────────────────────┐
 │ (defvblank-dma oam-dma       │ ───────────► │ (mem-write oam dma 256 vblank       │
 │   #:bytes 256 #:phase vblank)│              │            cache-flushed 256)       │
 └──────────────────────────────┘              └──────────────────┬──────────────────┘
                ▲                                                 │
                │           Resugar (Pombrio-Krishnamurthi)       ▼
 ┌──────────────┴───────────────┐              ┌─────────────────────────────────────┐
 │ plt-boba-diagnostic          │ ◄─────────── │ Graded Type / Capability Judgment   │
 │   in: (defvblank-dma ...)    │              │   cap-mem / TargetGrade / ModeState │
 └──────────────────────────────┘              └─────────────────────────────────────┘
```

### 2.4 Findler & Felleisen (ICFP 2002), Flanagan et al. (PLDI 1996, *MrSpidey*), & Zhang & Myers (POPL 2014, *SHErrLoc*)

1. **Higher-Order Contract Blame (`'positive` vs. `'negative`) — Findler & Felleisen (ICFP 2002)**:
   Across hardware co-processor and memory-bank boundaries, every session channel or far-call trampoline defines a two-party behavioral contract $\mathcal{C}(\text{Caller}, \text{Callee})$:
   - **Positive Blame (`'positive`)** falls on the **initiating module / host CPU caller** when it violates a boundary precondition:
     - Executing `(recv apu0 'boot-ack)` on an empty channel without a preceding `(send ...)` (deadlock precondition failure).
     - Sending a payload larger than the co-processor's hardware FIFO/ARAM/IMEM limit (e.g., $> 4,096\text{ B}$ to N64 RSP IMEM or $> 32$ instructions to RP2040 PIO).
     - Initiating an N64 RDRAM $\to$ RSP/RDP DMA transfer when the VR4300 data cache is `'cache-dirty` (missing `osWritebackDCache`).
     - Issuing a direct `JSR` between two switchable NES MMC1 `$8000-$BFFF` banks without routing through the fixed `$C000-$FFFF` bank trampoline.
     - Accessing RP2040 `SRAM4` simultaneously from both Cortex-M0+ Core 0 and Core 1 (violating bank-disjoint ownership).
   - **Negative Blame (`'negative`)** falls on the **responder / co-processor / target environment** when the caller satisfied all preconditions (`handshake-boot-ack`, valid payload size, cache flushed) but the co-processor or target boundary violated its postcondition:
     - Returning a mismatched handshake tag (`'ack-corrupt` instead of `'ipl-boot`) on SNES SPC700 `$2140-$2143`.
     - Failing to acknowledge a sent command before session termination (`unacknowledged-coprocessor-handshake`).
2. **Value-Flow & Multi-Site Witness Graphs — Flanagan et al. (PLDI 1996, *MrSpidey*) & Zhang & Myers (POPL 2014, *SHErrLoc*)**:
   When a hardware bus error depends on earlier state definitions—such as an 8-bit `STRB R2, [R1, #4]` on GBA where `R1` was computed from `R0 = #x06000000` (`VRAM`) three instructions earlier—reporting only the `STRB` line leaves the programmer asking *"Why does the compiler think `R1` points to VRAM?"*. Following *MrSpidey*'s value-flow arrows and *SHErrLoc*'s maximum-likelihood witness paths, `compiler/plt-error-diagnostics.rkt` records the full register def-use slice (`base-register-def` $\to$ `base-register-refine` $\to$ `stored-byte-source` $\to$ `illegal-8bit-strb-use`) and ranks resource-overflow contributors by Pareto dominance with an exact **minimal cut set**.

---

## 3. Audit of the 7 Error-Reporting Flaws in Existing `#lang boba-nes` Modules (Before vs. After)

Our audit of `boba-nes/main.rkt`, `compiler/boba-dsl-compiler.rkt`, `compiler/boba-core-ir.rkt`, `compiler/diagnostics.rkt`, `compiler/graded-typechecker.rkt`, `compiler/multi-target-typechecker.rkt`, `compiler/backend-snes.rkt`, and `compiler/backend-gba.rkt` uncovered **7 concrete PLT error-reporting flaws**. Below we document each flaw with exact source citations, a before/after diagnostic comparison, and the fix implemented in [`compiler/plt-error-diagnostics.rkt`](../compiler/plt-error-diagnostics.rkt).

---

### Issue 1: Unfortified Surface Macros & Silent Bit-Masking / Coercion (`boba-nes/main.rkt`, `compiler/boba-core-ir.rkt`)

- **Existing Code Citations**:
  - `boba-nes/main.rkt:62-214`: Surface macros (`defchr-tile`, `defpalette-resource`, `defmetasprite`, `defstate-machine`, `defrule`) use bare `define-syntax-rule` or `syntax-case` without `syntax/parse` syntax classes (`#:description`, `#:fail-when`, `#:fail-unless`).
  - `compiler/boba-core-ir.rkt:386-396`: `char->2bpp-pixel` and `char->4bpp-pixel` silently coerce any invalid pixel character (such as `'Z'` or `'9'` in a 2bpp NES tile) to pixel value `0` via `[else 0]` instead of reporting a syntax/domain error!
  - `compiler/boba-core-ir.rkt:500`: `pack-bgr555` silently masks out-of-range 5-bit RGB channels via `(bitwise-and r5 #x1F)` instead of rejecting channel values $> 31$.

- **Before (`boba-nes/main.rkt` / `compiler/boba-core-ir.rkt`)**:
  ```
  ;; Passing #x7F to an NES 6-bit palette or "0011223Z" to a 2bpp CHR tile:
  ;; Either silently truncates bits in ROM output or crashes inside a helper:
  match: no matching clause for '(defmetasprite hero-spr #:order diagonal-zigzag (0 0 1 0))
    context...:
     compiler/boba-dsl-compiler.rkt:182:0
  ```

- **After (`compiler/plt-error-diagnostics.rkt` — `validate-boba-surface-syntax`)**:
  ```
  defpalette: out-of-range NES 6-bit PPU palette color #x7f (127) in palette 'hero-pal' at entry 1
    at: 127
    in: (defpalette hero-pal 15 127 32 48)
    target: nes (Nintendo Entertainment System (Ricoh 2A03 / 2C02 PPU))
    expected: 6-bit NES PPU palette index in #x00..#x3F (0..63)
    given: #x7f (127) at color index 1
    witness chain:
      [1] enclosing-surface-form: boba-surface.bnes:1:0 -- Target 'nes' uses 6-bit PPU hardware palette indices (#x00..#x3F) [in (defpalette hero-pal 15 127 32 48)]
      [2] offending-sub-datum: boba-surface.bnes:1:28 -- Color entry 1 is #x7f (127), which exceeds #x3F (63) [at 127]
    resugared surface form: (defpalette hero-pal 15 127 32 48)
    suggested repairs:
      (1) Clamp color #x7f to a valid 6-bit NES PPU index in #x00..#x3F (e.g., #x3f)
      (2) Avoid forbidden PPU sync gray #x0D; use #x0F for canonical NES black
      (3) If 15-bit BGR555 (#x0000..#x7FFF) was intended, set #:target 'snes, 'gbc, or 'gba
  ```

---

### Issue 2: Leaking Internal Compiler & Lowered IR Jargon (`compiler/multi-target-typechecker.rkt`, `compiler/backend-gba.rkt`)

- **Existing Code Citations**:
  - `compiler/multi-target-typechecker.rkt:594-772`: `check-single-cap-mem-op` formats error messages containing raw internal struct/symbol names (`cap-rank`, `s-ppu-vram`, `cap-mem-safe?`, `mode-state-safe?`).
  - `compiler/backend-gba.rkt:319, 344`: `encode-arm-imm12` and `eval-gba-expr` raise raw `(error 'encode-arm-imm12 ...)` and `(error 'eval-gba-expr ...)` mentioning internal parameter `rot4`.

- **Before (`compiler/multi-target-typechecker.rkt` / `compiler/backend-gba.rkt`)**:
  ```
  encode-arm-imm12: rot4 out of range in eval-gba-expr for ir-dma-transfer / cap-mem-access (cap-rank < 2 on s-ppu-vram)
  ```

- **After (`compiler/plt-error-diagnostics.rkt` — `resugar-core-ir->surface-dsl` & `sanitize-internal-compiler-jargon`)**:
  - Every `Boba-Core IR` struct (`ir-palette`, `ir-tileset`, `ir-metasprite`, `ir-dma-transfer`, `ir-mode-transition`, `ir-coproc-session`, `ir-campaign`) is unexpanded back to its documented `#lang boba-nes` surface form (`defpalette`, `deftiles`, `defmetasprite`, `defvblank-dma`, `defcpu-mode`, `defcoproc-audio`, `defcampaign`).
  - `sanitize-internal-compiler-jargon` (`strip-compiler-internal-jargon`) scrubs all 19 internal compiler symbols (`ir-dma-transfer`, `cap-mem-access`, `mode-state-m`, `rot4`, `eval-gba-expr`, `encode-arm-imm12`, `cap-rank`, etc.) and `audit-error-message-plt-compliance` statically verifies `no-internal-jargon?`.

---

### Issue 3: Single-Site 65C816 Mode Conflict Reporting & Premature Single-Fix Guessing (`compiler/backend-snes.rkt`, `compiler/multi-target-typechecker.rkt`)

- **Existing Code Citations**:
  - `compiler/backend-snes.rkt:138, 256-266`: `(struct mode-conflict-65816 (label expected-state actual-state origin) #:transparent)` stores only a *single* `origin` string (the second incoming edge), discarding the line and instruction where Path 1 established `expected-state`.
  - `compiler/multi-target-typechecker.rkt:366-386`: `step-processor-mode-ast` unilaterally assumes `else-state` is the "correct" mode after an `(if ...)` join (`(values else-state (append ...))`), violating Marceau et al. (2011) by guessing one branch over the other.

- **Before (`compiler/backend-snes.rkt`)**:
  ```
  mode-conflict-65816 at label 'loop': expected (mode-65816 8 8 'native #f 'fallthrough), got (mode-65816 16 8 'native #f 'branch) from BRA
  ```

- **After (`compiler/plt-error-diagnostics.rkt` — `diagnose-65816-mode-conflict/witnesses`)**:
  ```
  defcpu-mode: ambiguous WDC 65C816 accumulator (M) register width at control-flow join label 'loop'
    at: (label loop)
    in: (defcpu-mode loop #:target 'snes #:path-1 (defcpu-mode #:m 8) #:path-2 (defcpu-mode #:m 16))
    target: snes (Super Nintendo Entertainment System (Ricoh 5A22 / WDC 65C816 + S-PPU + Sony SPC700))
    expected: all incoming control-flow paths to label 'loop' must agree on 65C816 (M, X, E) processor mode
    given: Path 1 arrives with M=8-bit, X=8-bit (native) [from (SEP 32) at line 1], whereas Path 2 arrives with M=16-bit, X=8-bit (native) [from (REP 32) at line 5]
    witness chain:
      [1] witness-path-1: snes-mode-kernel.bnes:1:2 -- Path 1 executes (SEP 32) at line 1 -> sets M=8-bit, X=8-bit (native), then reaches 'loop' via branch (line 3) [at (SEP 32)]
      [2] witness-path-2: snes-mode-kernel.bnes:5:2 -- Path 2 executes (REP 32) at line 5 -> sets M=16-bit, X=8-bit (native), then reaches 'loop' via (fallthrough -> loop) (line 6) [at (REP 32)]
      [3] control-flow-join-site: snes-mode-kernel.bnes:7:0 -- Join label 'loop' at line 7 receives incompatible 65C816 register widths: Path 1 (M=8-bit, X=8-bit (native)) vs. Path 2 (M=16-bit, X=8-bit (native)) [at (label loop)]
    resugared surface form: (defcpu-mode loop #:target 'snes #:path-1 (defcpu-mode #:m 8) #:path-2 (defcpu-mode #:m 16))
    suggested repairs:
      (1) Option A (if label 'loop' expects M=8-bit, X=8-bit (native)): insert (sep 32) on Path 2 before (fallthrough -> loop) at line 6
      (2) Option B (if label 'loop' expects M=16-bit, X=8-bit (native)): insert (rep 32) on Path 1 before entering '(label loop)' at line 7
      (3) Or annotate '(entry-label loop #:m 8 #:x 8)' and run (reconcile-65816-branch-modes ...) to synthesize transitions automatically
  ```

---

### Issue 4: Memoryless GBA 8-Bit `STRB` Bus-Width Check Without Backward Def-Use Slice (`compiler/backend-gba.rkt`)

- **Existing Code Citations**:
  - `compiler/backend-gba.rkt:650-706`: `verify-gba-vram-bus-widths` tracks register values in a flat numeric vector `(define reg-vals (make-vector 16 0))`. When `STRB` writes to `$06000124` via base register `R1`, the violation hash records only the `STRB` instruction and the hex number `#x06000124`, losing the backward dataflow slice where `R0` was loaded with `#x06000000` (`MOV R0, #x06000000`) and refined into `R1` (`ADD R1, R0, #x120`).

- **Before (`compiler/backend-gba.rkt`)**:
  ```
  #hasheq((addr . 100663588) (form . (arm-strb-imm 2 1 4)) (message . "Illegal 8-bit STRB write to GBA VRAM...") (region . VRAM))
  ```

- **After (`compiler/plt-error-diagnostics.rkt` — `diagnose-gba-vram-strb/dataflow-slice`)**:
  ```
  deftiles: illegal 8-bit STRB write to GBA 16-bit VRAM bus at $06000124 via base register R1 (defined at line 1)
    at: (STRB R2 (R1 4))
    in: (deftiles gba-vram-tiles #:target 'gba #:addr "$6000124")
    target: gba (Game Boy Advance (ARM7TDMI 32-bit RISC @ 16.78 MHz))
    expected: 16-bit halfword (STRH / 'u16, align >= 2) or 32-bit word (STR / DMA3 / 'u32, align >= 4) write to GBA VRAM
    given: 8-bit STRB (STRB R2 (R1 4)) at line 4 using base register R1 = $06000120 (loaded by (MOV R0 100663296) at line 1); GBA VRAM ($06000124) lacks an 8-bit write strobe; STRB duplicates the byte across both upper and lower lanes of the 16-bit halfword
    witness chain:
      [1] base-register-def: gba-vram-upload.bnes:1:2 -- register R0 defined by (MOV R0 100663296) at line 1 -> holds $06000000 (VRAM base) [at (MOV R0 100663296)]
      [2] base-register-refine: gba-vram-upload.bnes:2:2 -- register R1 defined by (ADD R1 R0 288) at line 2 -> holds $06000120 (VRAM base) [at (ADD R1 R0 288)]
      [3] stored-byte-source: gba-vram-upload.bnes:3:2 -- source byte register R2 loaded by (MOV R2 66) at line 3 (value #x42) [at (MOV R2 66)]
      [4] illegal-8bit-strb-use: gba-vram-upload.bnes:4:2 -- 8-bit byte store (STRB R2 (R1 4)) at line 4 dereferences R1 ($06000120 + 4 = $06000124 in GBA VRAM 16-bit bus) [at (STRB R2 (R1 4))]
    resugared surface form: (deftiles gba-vram-tiles #:target 'gba #:addr "$6000124")
    suggested repairs:
      (1) Replace 8-bit (STRB R2 (R1 4)) at line 4 with 16-bit halfword store `(arm-strh-imm R2 R1 4)` (or `thumb-strh`)
      (2) Or pack pairs of pixels/palette entries into 32-bit words and use `(arm-str-imm R2 R1 4)` or DMA3 (`REG-DMA3CNT`)
      (3) If byte manipulation is required, stage bytes in 32-bit IWRAM ($03000000) or EWRAM ($02000000) and flush via 16/32-bit `(defvblank-dma vram ...)`
  ```

---

### Issue 5: Monolithic Resource Grade Overflows Without Pareto Attribution or Minimal Cut Set (`compiler/multi-target-typechecker.rkt`, `compiler/diagnostics.rkt`)

- **Existing Code Citations**:
  - `compiler/multi-target-typechecker.rkt:1441-1551`: `collect-target-grade-violations` sums all statement grades into a single scalar (e.g., `2493 > 2273` VBlank cycles) and emits a single aggregate violation without identifying which declarations contributed what percentage of the budget.
  - `compiler/diagnostics.rkt:174`: Defaults missing source locations to `"surface-dsl:1:1"`.

- **Before (`compiler/multi-target-typechecker.rkt` / `compiler/diagnostics.rkt`)**:
  ```
  [BOBA-NES HARDWARE/TYPE ERROR] VBLANK-CYCLE-OVERFLOW at surface-dsl:1:1
  VBlank cycle grade 2493 exceeds NES hardware budget of 2273 cycles
  ```

- **After (`compiler/plt-error-diagnostics.rkt` — `diagnose-resource-overflow/pareto-blame`)**:
  ```
  defvblank-dma: vblank-cycles resource budget overflow on 'nes': total 2493 (109.7% of 2273 ceiling, excess +220); minimal cut set: (full-nametable-upload)
    at: (defvblank-dma full-nametable-upload #:cost 1600)
    in: (defnes-game nes-module #:target 'nes (defvblank-dma full-nametable-upload #:cost 1600) (defvblank-dma oam-dma-sync #:cost 513) (defpalette hud-pal-swap #:cost 320) (defrule status-bar-scroll #:cost 60))
    target: nes (Nintendo Entertainment System (Ricoh 2A03 / 2C02 PPU))
    expected: cumulative vblank-cycles <= 2273 on Nintendo Entertainment System (Ricoh 2A03 / 2C02 PPU)
    given: 2493 vblank-cycles across 4 declarations (top contributor: (defvblank-dma full-nametable-upload) = 1600 [70.4%], minimal cut set to save >= 220: (full-nametable-upload))
    witness chain:
      [1] pareto-rank-1-contributor: boba-resource-budget.bnes:42:0 -- defvblank-dma 'full-nametable-upload' consumes 1600 vblank-cycles (70.4% of NES hardware ceiling 2273) [in minimal cut set] [at full-nametable-upload]
      [2] hardware-budget-ceiling: boba-resource-budget.bnes:1:0 -- Target 'nes' enforces vblank-cycles <= 2273; module total is 2493 (overflow by +220) [at nes]
    pareto resource breakdown:
      #1 (defvblank-dma full-nametable-upload): 1600 vblank-cycles (70.4% of budget) at boba-resource-budget.bnes:42:0
      #2 (defvblank-dma oam-dma-sync): 513 vblank-cycles (22.6% of budget) at boba-resource-budget.bnes:18:0
      #3 (defpalette hud-pal-swap): 320 vblank-cycles (14.1% of budget) at boba-resource-budget.bnes:29:0
      #4 (defrule status-bar-scroll): 60 vblank-cycles (2.6% of budget) at boba-resource-budget.bnes:55:0
    resugared surface form: (defnes-game nes-module #:target 'nes ...)
    suggested repairs:
      (1) Optimize minimal cut set (full-nametable-upload) to reduce vblank-cycles by at least 220 (currently consuming 1600 / 2273)
      (2) Primary Pareto target: refactor (defvblank-dma full-nametable-upload ...) which alone accounts for 70.4% (1600 / 2273) of the hardware budget
      (3) Amortize VRAM/OAM transfers across frames with (with-vram-delta-queue #:slices 2 ...) or offload to HBlank HDMA
  ```

---

### Issue 6: Blameless Cross-Core / Bank Session Failures (`compiler/multi-target-typechecker.rkt`)

- **Existing Code Citations**:
  - `compiler/multi-target-typechecker.rkt:852-951`: `check-coprocessor-session-protocol` returns flat violation hashes (`'coprocessor-recv-without-send`, `'coprocessor-session-tag-mismatch`, `'coprocessor-session-payload-overflow`) without distinguishing whether the **host caller** broke a precondition (**Positive Blame**, `'positive`) or the **co-processor/responder** broke a postcondition (**Negative Blame**, `'negative`) in the sense of Findler & Felleisen (ICFP 2002).

- **Before (`compiler/multi-target-typechecker.rkt`)**:
  ```
  #hasheq((expected-tag . ack) (port . apu0) (rule . coprocessor-session-tag-mismatch) (sent-tag . boot))
  ```

- **After (`compiler/plt-error-diagnostics.rkt` — `diagnose-coprocessor-session/contract-blame`)**:
  - Assigns `(contract-blame 'positive 'SNES-5A22-65C816-Host-CPU 'SNES-65C816<->SPC700-APU-Bus ...)` when the 65C816 host writes payload bytes before completing `handshake-boot-ack` or exceeds SPC700 ARAM / N64 RSP IMEM / RP2040 PIO capacity.
  - Assigns `(contract-blame 'negative 'Sony-SPC700-Audio-CoProcessor 'SNES-65C816<->SPC700-APU-Bus ...)` when the 65C816 caller satisfies all preconditions but the SPC700 responder returns a corrupted handshake tag or fails to acknowledge a sent command.

---

### Issue 7: Ad-Hoc Error Banner Without Canonical Racket Realm Fields or Static PLT Rubric Enforcement (`compiler/diagnostics.rkt`)

- **Existing Code Citations**:
  - `compiler/diagnostics.rkt:189-199`: `format-boba-diagnostic` prints an ASCII banner (`[BOBA-NES HARDWARE/TYPE ERROR] ...`) that omits standard Racket structured diagnostic fields (`at:`, `in:`, `target:`, `expected:`, `given:`, `witness chain:`, `pareto resource breakdown:`, `contract blame:`, `suggested repairs:`) and provides no automated compliance verifier.

- **After (`compiler/plt-error-diagnostics.rkt` — `format-plt-diagnostic` & `audit-error-message-plt-compliance`)**:
  - `format-plt-diagnostic` produces canonical Racket multi-line structured diagnostics.
  - `audit-error-message-plt-compliance` statically checks every formatted diagnostic against all 5 PLT rubric criteria:
    1. `no-internal-jargon?`
    2. `has-specific-at-span?` ($\text{length}(\text{at}) < \text{length}(\text{in})$)
    3. `has-surface-resugaring?`
    4. `has-multi-site-witnesses-when-conflict?` ($\ge 2$ witness sites)
    5. `has-actionable-repairs?` ($\ge 1$ concrete repair option)

---

## 4. Architecture of `compiler/plt-error-diagnostics.rkt`

### 4.1 Structured PLT Diagnostic Data Types

| Struct / Constructor | Fields | Purpose |
| :--- | :--- | :--- |
| `srcloc-span` | `(source line column position span surface-form sub-datum)` | Pinpoints both the exact offending sub-syntax (`sub-datum`) and its enclosing `#lang boba-nes` form (`surface-form`). |
| `witness-site` | `(role label srcloc state-desc)` | Represents one node in a multi-path 65C816 mode conflict, GBA backward register def-use slice, or co-processor protocol trace. |
| `pareto-contributor` | `(form-name id metric-name amount budget-pct srcloc)` | Quantifies an individual surface declaration's share of a hardware resource ceiling (`TargetSpec`). |
| `contract-blame` | `(polarity blamed-party boundary-kind expected-contract actual-behavior srcloc)` | Encodes Findler-Felleisen `'positive` vs. `'negative` blame across hardware/bank boundaries. |
| `plt-boba-diagnostic` | `(operation target headline at-datum in-form expected given witnesses pareto-breakdown blame resugared-surface-term repair-options)` | Unified PLT diagnostic record consumed by `format-plt-diagnostic` and `audit-error-message-plt-compliance`. |
| `exn:fail:syntax:boba` | `(message continuation-marks exprs diagnostic)` | Subtype of `exn:fail:syntax` raised when `#:raise? #t` is passed to fortified validators. |

### 4.2 Summary of Verification Results

All 12 standalone verification suites pass against `compiler/plt-error-diagnostics.rkt`, confirming:
- Fortified `syntax/parse` validation for `defpalette`, `deftiles`, `defmetasprite`, `defcampaign`, `defrule`, and `deffixed` / `defphysics` (both returning `plt-boba-diagnostic` when `#:raise? #f` and raising `exn:fail:syntax:boba` when `#:raise? #t`).
- Pombrio-Krishnamurthi resugaring (`resugar-core-ir->surface-dsl`, `resugar-target-type-report`, `sanitize-internal-compiler-jargon` / `strip-compiler-internal-jargon`) across all lowered `Boba-Core IR` nodes.
- Multi-site witness extraction (`diagnose-65816-mode-conflict/witnesses`, `diagnose-gba-vram-strb/dataflow-slice`, `diagnose-resource-overflow/pareto-blame`, `diagnose-coprocessor-session/contract-blame`).
- 100% compliance on `audit-error-message-plt-compliance` across all generated diagnostics.

---

## 5. References

1. **Ryan Culpepper & Matthias Felleisen** (2010). *"Fortifying Macros."* In *Proceedings of the 15th ACM SIGPLAN International Conference on Functional Programming (ICFP '10)*, pp. 235–246. Extended version in *Journal of Functional Programming (JFP)*, 22(4–5), 2012, pp. 439–476.
2. **Guillaume Marceau, Kathi Fisler, & Shriram Krishnamurthi** (2011). *"Mind Your Language: On Novices' Interactions with Error Messages."* In *Proceedings of the 10th SIGPLAN Symposium on New Ideas, New Paradigms, and Reflections on Programming and Software (Onward! '11)*, pp. 3–18.
3. **Guillaume Marceau, Kathi Fisler, & Shriram Krishnamurthi** (2011). *"Measuring the Effectiveness of Error Messages Designed for Novice Programmers."* In *Proceedings of the 42nd ACM Technical Symposium on Computer Science Education (SIGCSE '11)*, pp. 499–504.
4. **Justin Pombrio & Shriram Krishnamurthi** (2014). *"Resugaring: Lifting Evaluation Sequences through Syntactic Sugar."* In *Proceedings of the 35th ACM SIGPLAN Conference on Programming Language Design and Implementation (PLDI '14)*, pp. 361–371.
5. **Justin Pombrio & Shriram Krishnamurthi** (2015). *"Hygienic Resugaring of Compositional Desugaring."* In *Proceedings of the 20th ACM SIGPLAN International Conference on Functional Programming (ICFP '15)*, pp. 75–87.
6. **Justin Pombrio, Shriram Krishnamurthi, & Mitchell Wand** (2017). *"Inferring Type Rules for Syntactic Sugar."* In *Proceedings of the 38th ACM SIGPLAN Conference on Programming Language Design and Implementation (PLDI '17 / ICFP '17)*.
7. **Robert Bruce Findler & Matthias Felleisen** (2002). *"Contracts for Higher-Order Functions."* In *Proceedings of the 7th ACM SIGPLAN International Conference on Functional Programming (ICFP '02)*, pp. 48–59.
8. **Cormac Flanagan, Matthew Flatt, Shriram Krishnamurthi, Stephanie Weirich, & Matthias Felleisen** (1996). *"Catching Bugs in the Web of Program Invariants (MrSpidey)."* In *Proceedings of the ACM SIGPLAN 1996 Conference on Programming Language Design and Implementation (PLDI '96)*, pp. 23–32.
9. **Dan Zhang & Andrew C. Myers** (2014). *"Toward General Diagnosis of Static Errors (SHErrLoc)."* In *Proceedings of the 41st ACM SIGPLAN-SIGACT Symposium on Principles of Programming Languages (POPL '14)*, pp. 569–581.
