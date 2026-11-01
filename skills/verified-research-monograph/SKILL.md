---
name: verified-research-monograph
description: Write rigorous, self-contained, executable-synchronized research papers and technical monographs across any domain of computer science, mathematics, systems, hardware architecture, cryptography, machine learning, programming languages, or formal methods. Enforces the 10-Pillar Verified Research Monograph Methodology—pairing every theoretical claim, theorem, and table entry with mechanized proofs, multi-language differential implementations, grammar-guided fuzzing narratives, multi-regime evaluation matrices, Pareto frontiers, and cycle-accurate hardware/system accounting.
---

# Verified Research Monograph Methodology (`verified-research-monograph`)

Use this skill whenever drafting, expanding, auditing, or refactoring a research paper, technical monograph, system design specification, or formal methods report in **any** area of computer science, mathematics, systems, hardware architecture, cryptography, machine learning, programming languages, or formal verification.

---

## Core Philosophy

A research monograph must never be a collection of disconnected prose claims, hand-waved asymptotic sketches, or cherry-picked single-point benchmarks. Every section of the document must operate as a **synchronized projection of an executable, mechanically verified artifact**:

1. **Zero Handwaving**: Every definition, theorem, lemma, algorithm, and numerical table cell maps 1-to-1 to a mechanized proof, an executable operational semantics model, or a deterministic benchmark script.
2. **Radical Honesty on Scope**: Every speedup, compression ratio, or complexity reduction is paired with an explicit boundary statement clarifying which fundamental lower bounds remain unchanged and separating asymptotic/ideal models from today-executable hardware/system constraints.
3. **Architecture-Schedule Separation**: High-level domain invariants are cleanly decoupled from mid-level canonical normal forms and low-level target/hardware schedule lowering.
4. **Empirical & Adversarial Grounding**: Type systems, invariants, and algebraic rewrite rules are justified by concrete bug classes discovered via grammar-guided and mutation fuzzing, accompanied by algebraic simplification ledgers that shrink the core calculus.

---

## The 10-Pillar Methodology

### Pillar 1: Zero-Handwaving Executable-Synchronized Writing ("Every Claim Has a Theorem, Fuzzer Category, or Reproducer")

Never write prose claims in isolation. Every definition, theorem, algorithm, and table entry in the paper must map 1-to-1 to an executable artifact:

- **Mechanized Proofs (`Lean 4` / `Coq` / `Isabelle` / `Agda`)**:
  - Zero unfinished proofs (`0 sorry`, `0 Admitted`) and zero unverified user axioms (`0 axiom`) across all theorem files.
  - Every formal theorem in the paper states its exact mechanized identifier, file path, and line or symbol reference.
- **Executable Operational Semantics (`PLT Redex` / `K Framework` / `TLA+` / `Alloy`)**:
  - All typing judgments, small-step/big-step reduction rules, and state-machine transitions are executable and tested via automated property/fuzzer suites (`redex-check`, model checking, or symbolic execution).
- **Multi-Language Reference Implementations (`Haskell`, `OCaml`, `Rust`, `C++`, `Python`, `SystemVerilog`)**:
  - Provide idiomatic, independent implementations across multiple host paradigms (e.g., pure functional, systems/ownership, hardware/RTL, and scripting/reference) that compute identical canonical outputs on all test vectors.
- **Mandatory Artifact Cross-Reference Ledger**:
  - Maintain an explicit cross-reference table in the monograph mapping every paper element to its verification artifacts:

| Paper Section / Theorem / Table | Formal Proof (`Lean 4` / `Coq`) | Operational Model (`Redex` / `TLA+`) | Reference Implementations (`Rust` / `Haskell` / `C++` / `Python`) | Verification Test / Fuzz Category |
| :--- | :--- | :--- | :--- | :--- |
| `§3, Thm 3.2 (Soundness)` | `Proofs/Soundness.lean : thm_soundness` | `model/semantics.rkt : judgement-sound` | `src/core.rs : verify_invariant` | `Cat 1: Well-Typed Preservation (10,000 cases)` |
| `§5, Alg 2 (Canonical Pass)` | `Proofs/NormalForm.lean : alg2_norm_eq` | `model/opt.rkt : normalize-term` | `src/pass.hs : normalize`, `src/pass.cpp : normalize` | `Cat 4: Idempotence & Cost Non-Increase` |
| `§7, Table 4 (Throughput)` | `Proofs/CostBound.lean : bound_tight` | `model/cost.rkt : exact-cost` | `bench/eval_matrix.py : run_regime_matrix` | `Cat 8: Table Numerical Sync Check` |

---

### Pillar 2: Honest Scope Boundaries & "What Does Not Change" Columns

Whenever presenting speedups, compressions, or complexity gains, include an explicit **"Honest Asymptotic / Physical Scope Boundary"** column in summary tables and a dedicated subsection in the text.

1. **State What Fundamental Lower Bounds Do Not Change**:
   - Explicitly identify information-theoretic lower bounds (e.g., Shannon capacity, Yao minimax, communication complexity), computational hardness barriers (`NP`-hardness, `PSPACE`-completeness, query complexity $\Omega(\cdot)$), or physical/thermodynamic limits (speed-of-light propagation, Landauer limit, DRAM row-cycle $t_{\text{RC}}$, wire fanout delay) that the technique **does not** and **cannot** bypass.
   - Clarify whether each improvement is:
     - An **asymptotic reduction in an auxiliary/structural dimension** (e.g., $O(N) \to O(\log N)$ metadata/bookkeeping/routing overhead while core problem lower bound $\Omega(f(N))$ remains invariant),
     - A **sparsity- or structure-exploiting improvement** (exact parameter regime where $k \ll N$ holds vs. worst-case dense inputs where $k = \Theta(N)$), or
     - A **constant-factor / microarchitectural improvement** (e.g., eliminating pointer chasing, zero-DSP LUT synthesis, cache-line alignment, or zero-copy region cleanup).
2. **Separate Ideal / Asymptotic Theory Models from Today-Available Real-World Hardware / System Constraints**:
   - Maintain a strict separation between **Ideal / Asymptotic Theory Projections** (e.g., unbounded word RAM, ideal network fabric, asymptotic $N \to \infty$ scaling) and **Today-Available Real-World System / Hardware Constraints** (e.g., PCIe Gen5 / CXL tail latency, L1/L2 cache capacity, FPGA BRAM/URAM port limits, clock-domain crossing jitter, calibration drift, I/O serialization bottlenecks).
   - Provide both an **Asymptotic Scaling Table** and a **Today-Executable Hardware/System Table** runnable on current commodity or laboratory hardware.

#### Template: Scope Boundary Table

| Contribution / Subsystem | Exact Metric Improved (`Baseline -> Ours`) | Where the Gain Comes From | What Fundamental Lower Bound Does NOT Change | Today-Available Hardware / System Bottleneck |
| :--- | :--- | :--- | :--- | :--- |
| `[Subsystem A]` | `$O(N) \to O(\log N)$` (`14.2x` at $N=10^4$) | Persistent tree path-copying & region fusion | Lower bound $\Omega(Q)$ on total irreducible state updates | L2 cache miss penalty ($>12\text{ ns}$) when working set exceeds $1\text{ MB}$ |
| `[Subsystem B]` | `3.8x` throughput, `0` DSPs | Algebraic shift-add decomposition in Tier 2 IR | Information-theoretic entropy bound $H(X)$ bits/symbol | PCIe DMA ingress ring buffer saturation at $>100\text{ Gbps}$ |

---

### Pillar 3: Multi-Regime / Multi-Architecture Evaluation Matrices (No Single-Point Strawmen)

Never evaluate a system on a single synthetic operating point or against a weak strawman baseline. Evaluate every benchmark across **multiple distinct deployment regimes** against the **strongest published state-of-the-art baselines**.

1. **Five Standard Deployment Regimes** (adapt names to the target domain):
   - **Regime I — Ideal Monolithic / Uniform RAM / Flat Shared-Memory**: Baseline uniform-cost model with zero tiering or communication penalty, isolating pure algorithmic operation counts.
   - **Regime II — Hierarchical / Tiered Memory (Hot-Cache + Cold-Storage)**: Realistic memory hierarchy (e.g., SRAM/L1 + DRAM + NVMe, or Fast Scratchpad + Banked Bulk Store) where active working sets are small and cold accesses incur explicit tier-transfer latency/energy.
   - **Regime III — High-Rate / Compressed / Packed Block Encoding**: Bandwidth- or space-optimized block representations where multiple logical elements share a packed container, requiring amortised or surgical extraction/insertion to avoid full-block unpacking penalties.
   - **Regime IV — Physically Distributed / Networked / Multi-Die / Shuttled**: Multi-node, multi-chiplet, or multi-core message-passing architectures with explicit interconnect topology, serialization latency, and cross-partition synchronization costs.
   - **Regime V — Near-Term / Today-Executable Down-Scaled Hardware Instances**: Small-scale, cycle-accurate or resource-constrained instances that execute end-to-end today on real FPGAs, CPUs/GPUs, embedded MCUs, or testbeds without extrapolation.
2. **Mandatory Reporting Format**:
   - Report **exact absolute metrics** alongside **relative ratios** (`Baseline -> Ours`, `% Reduction`, `Speedup x`) across all primary dimensions (Space/Memory, Total Operations, Critical-Path Depth, Wall-Clock Latency).

---

### Pillar 4: Multi-Tier Intermediate Representation (`HL -> ML -> LL`) & Algorithm-vs-Schedule Separation

Structure system, compiler, hardware, and algorithmic monographs around a **3-Tier Intermediate Representation (IR) Architecture** that cleanly separates *what* is computed from *how* it is scheduled on a target:

```
+-------------------------------------------------------------------------+
| Tier 1: High-Level Domain / Modal IR (HL-IR)                            |
|   - 100% Target-Independent                                             |
|   - Structural types, resource/linearity modalities, algebraic laws     |
|   - Proven sound via mechanized type checker & small-step semantics     |
+-------------------------------------------------------------------------+
                                    |
                                    |  CanonicalElaborate : HL-IR -> ML-IR
                                    v
+-------------------------------------------------------------------------+
| Tier 2: Mid-Level Canonical / Region IR (ML-IR)                         |
|   - 100% Shared Across All Target Backends                              |
|   - Explicit Setup-Action-Cleanup (with_region) scopes                  |
|   - Normalization-by-Evaluation (NbE) & algebraic rewrite normal forms  |
|   - O(1) Bitboard / Symbolic equivalence & commutation decision engine  |
+-------------------------------------------------------------------------+
                                    |
                                    |  TargetLower[Arch] : ML-IR -> LL-IR
                                    v
+-------------------------------------------------------------------------+
| Tier 3: Low-Level Machine / Schedule ISA (LL-IR)                        |
|   - Target-Specific Cost Models, Resource Budgets & Pipeline Schedules  |
|   - Isolates all hardware latencies, bank conflicts, routing & placement|
|   - Selects Pareto-optimal schedule (Space-Min, Balanced, Depth-Min)    |
+-------------------------------------------------------------------------+
```

- **Key Architectural Invariant**: Adding a new hardware backend, storage tier, or execution regime requires **zero modifications** to Tier 1 or Tier 2 proofs and optimizations; it only instantiates a new cost functor and schedule lowering pass in `Tier 2 -> Tier 3`.

---

### Pillar 5: Bug-Driven Formal Refinement Narrative (`Issues F1..Fn` -> `Type/Invariant Refinements`)

Document the **actual failure modes discovered by grammar-guided and mutation fuzzing** (`Issues F1..Fn`). Present the formal type system or invariant checker not as an arbitrary set of rules, but as the minimal, necessary defense against concrete, reproducible failure traces:

For every bug class `Fi` (`F1..Fn`), document four mandatory components:
1. **Minimal Counterexample Trace**: The exact minimal program or state transition sequence (3–8 lines) where a naive or unrefined system fails.
2. **Why Naive Designs Fail Silently**: Explain why standard compilers, linters, or runtime checks miss the bug (e.g., silent aliasing corruption, residual dirty state in recycled buffers, non-commuting concurrent updates, catastrophic cancellation, or off-by-one boundary overflow).
3. **Exact Static Type / Invariant Refinement**: Give the formal inference rule or static side-condition added to Tier 1/Tier 2 that statically rules out `Fi`.
4. **Negative Mutation Fuzzing Verification**: Cite the automated negative fuzzer category (`N` mutated invalid programs per category) proving **100% static rejection** with zero false negatives.

#### Template: Bug-Driven Refinement Ledger

| Issue ID | Bug Class & Failure Mechanism | Minimal Counterexample / Trigger | Static Type / Invariant Refinement | Negative Fuzz Suite & Rejection Rate |
| :--- | :--- | :--- | :--- | :--- |
| **`F1`** | **Silent Aliasing / Overlapping Mutable Borrow** | `swap_update(buf[i], buf[j])` when runtime index $i = j$ | Disjointness judgment $\Gamma \vdash r_1 \perp r_2$ in HL-IR | `fuzz_neg_F1_aliasing`: `2,000 / 2,000` rejected (`100%`) |
| **`F2`** | **Incomplete Cleanup / Residual Scratchpad State** | Early exit inside `with_scratch` before inverse uncompute | Linear region modality $\text{Clean}[R]$ requiring balanced inverse | `fuzz_neg_F2_unclean`: `2,000 / 2,000` rejected (`100%`) |
| **`F3`** | **Non-Commuting Reordering Across Shared Dependency** | Hoisting read of `x` across conditional write to `x` | Bitboard dependency footprint intersection check $(R_1 \cap W_2 = \emptyset)$ | `fuzz_neg_F3_commute`: `2,000 / 2,000` rejected (`100%`) |

---

### Pillar 6: Algebraic & Architectural Simplification Ledger (`Simplifications S1..Sm`)

Never grow a system's complexity unchecked. Pair every new capability or feature with explicit **simplification rules (`S1..Sm`)** that *shrink* the core calculus, collapse redundant cases, and simplify the implementation and proofs:

- **Examples of Structural & Algebraic Simplifications**:
  - **`S1` (Universal Container Polymorphism)**: Replace $K$ bespoke data-structure implementations (e.g., stacks, queues, deques, priority queues, finite maps) with a single parameterized algebraic spine or finger-tree functor instantiated with a monoidal measure.
  - **`S2` (Single-Pass Normalization-by-Evaluation / NbE)**: Replace $M$ iterative fixed-point peephole passes (which suffer from phase-ordering problems) with a single-pass algebraic evaluation into canonical normal form followed by reification.
  - **`S3` (Bitboard / Symbolic Footprint Decision Procedure)**: Replace recursive AST traversal for dependency/commutation checking ($O(|e|^2)$) with $O(1)$ bitwise word operations (`u64`/`u128` footprint bitboards).
  - **`S4` (Scoped Region Fusion)**: Fuse adjacent `Setup-Action-Cleanup` scopes sharing the same auxiliary state (`with_region R S A1; with_region R S A2 ==> with_region R S (A1; A2)`), eliminating $2(k-1)$ redundant setup/cleanup passes across $k$ consecutive operations.
- **Mechanized Monotonicity Guarantee**: Every simplification rule $S_j$ must carry a mechanized proof of semantic preservation ($\llbracket \text{simplify}(e) \rrbracket = \llbracket e \rrbracket$) and strict cost non-increase ($\text{Cost}(\text{simplify}(e)) \le \text{Cost}(e)$).

---

### Pillar 7: Multi-Objective Pareto Frontier Analysis (Instead of Arbitrary Scalar Weights)

When a design trades off competing resources (e.g., **Space / Memory Footprint** vs. **Total Compute Operations** vs. **Critical-Path Depth / Latency** vs. **Communication / Energy**), never hide the tradeoff behind a single arbitrary scalar objective like $\alpha \cdot \text{Space} + \beta \cdot \text{Time}$.

1. **Present the Non-Dominated 3D/Multi-Objective Pareto Frontier**:
   - Explicitly characterize the non-dominated operating points across the resource space:
     - **Architecture / Schedule A (`Min-Space Extreme`)**: Minimizes peak memory, register, or scratchpad footprint via eager recomputation/cleanup at the expense of higher operation count and critical-path depth.
     - **Architecture / Schedule B (`Balanced Knee Point`)**: Maximizes joint space-time efficiency (e.g., square-root decomposition, $B$-way branching, or bounded region pooling) to capture the bulk of the space savings with minimal latency overhead.
     - **Architecture / Schedule C (`Min-Depth / Min-Latency Extreme`)**: Minimizes critical-path latency via speculative parallel fanout or pre-allocated shadow buffers at the cost of higher peak memory/hardware area.
2. **State Dominated vs. Non-Dominated Regimes Explicitly**:
   - Identify under what hardware budget (e.g., memory-starved edge/FPGA vs. latency-critical HFT/control loop) each Pareto point is optimal, and prove which naive schedules are strictly dominated across all metrics.

---

### Pillar 8: Real-Time Physical & Microarchitectural Accounting (Cycle-Accurate Latency & Resource Breakdown)

Anchor every nanosecond, microsecond, byte, LUT, or gate estimate in **explicit stage-by-stage hardware pipeline tables**. Never state a latency or hardware cost without accounting for every clock cycle and physical resource:

1. **Stage-by-Stage Pipeline Accounting**:
   - Specify the target clock frequency $f_{\text{clk}}$ (e.g., $250\text{ MHz} \implies 4.0\text{ ns/cycle}$ on FPGA, or $3.5\text{ GHz}$ on CPU), exact cycle count per pipeline stage, initiation interval ($\text{II}$), ingress/egress serialization cycles, and total end-to-end latency in both cycles and nanoseconds.
2. **Hard Real-Time Slack Verification**:
   - Compare total worst-case execution time ($\text{WCET}$) against the physical deadline $T_{\text{deadline}}$ and report the explicit **positive timing slack** ($\Delta t_{\text{slack}} = T_{\text{deadline}} - \text{WCET} > 0$) and percentage budget utilization.
3. **Physical Resource Breakdown**:
   - Tabulate exact LUTs, Flip-Flops (FFs), BRAM/URAM blocks, DSP slices (highlighting `0 DSP` multiplierless designs where applicable), SRAM bytes, or cache lines consumed per module.

#### Template: Cycle-Accurate Microarchitectural Pipeline Table

| Pipeline Stage | Microarchitectural Operation | Clock Cycles (`@ f_clk`) | Latency (`ns`) | LUTs / Logic | Flip-Flops | Memory (`BRAM` / `Bytes`) | DSP Slices |
| :--- | :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| `Stage 1: Ingress` | AXI4-Stream / DMA frame unpack & syndrome align | `2` | `8.0 ns` | `142` | `128` | `0` | `0` |
| `Stage 2: Core` | Bitboard canonical lookup & tree spine traversal | `6` | `24.0 ns` | `618` | `384` | `1 BRAM` | `0` |
| `Stage 3: Update` | Balanced region commit & parity writeback | `3` | `12.0 ns` | `210` | `192` | `0` | `0` |
| `Stage 4: Egress` | Output serialization & valid handshake | `1` | `4.0 ns` | `64` | `64` | `0` | `0` |
| **Total Pipeline** | **End-to-End Deterministic Datapath (`II = 1`)** | **`12 cycles`** | **`48.0 ns`** | **`1,034`** | **`768`** | **`1 BRAM`** | **`0 DSP`** |
| **Deadline Slack** | **Hard Deadline $T_{\text{deadline}} = 200.0\text{ ns}$** | **`+38 cycles` slack** | **`+152.0 ns` (`24.0%` budget)** | — | — | — | — |

---

### Pillar 9: Self-Contained Monograph Structure (ASCII/Mermaid Diagrams, Concrete Worked Examples, & Step-by-Step Algorithms)

Write the monograph so a reader can understand, implement, and verify the entire system from the document alone without chasing external folklore:

1. **Concrete Small-Scale Worked Traces**:
   - Immediately after introducing any abstract formalism, typing judgment, or optimization pass, walk through a **concrete small-scale instance** (e.g., $N=4$ or $N=8$ elements, explicit bitvectors, exact pointer/spine transitions, and step-by-step state evolution) calculated both by hand in the text and verified by a unit test.
2. **Clean Visual Architecture (ASCII & Mermaid Diagrams)**:
   - Include high-signal architectural block diagrams, data-layout memory maps, tree-spine transformation diagrams, and pipeline timing charts using clean ASCII art (for universal portability in plain-text/LaTeX/Markdown) or Mermaid flowcharts.
3. **Self-Contained Pseudocode (`Algorithm 1..K`)**:
   - Present every core algorithm as a self-contained numbered block with explicit **Input**, **Output**, **Preconditions / Invariants**, **Step-by-Step Operations**, **Time/Space Complexity**, and **Resource Footprint** annotations.

---

### Pillar 10: Automated Cross-Language Differential Verification Pipeline

Conclude every research monograph project with an automated, single-command verification harness (`verify_monograph.py` or `verify_all.py`) that audits the entire paper-to-code correspondence:

1. **Zero-Sorry / Zero-Axiom Proof Gate**:
   - Invokes the formal proof assistant (`lake build`, `coqc`, etc.) and scans all proof sources to verify `0 sorry`, `0 Admitted`, and `0 axiom`.
2. **Operational Semantics & Negative Mutation Fuzz Gate**:
   - Runs the executable semantics model (`raco test`, `redex-check`, etc.) across thousands of grammar-generated positive terms and verifies `100%` rejection across all negative mutation categories (`F1..Fn`).
3. **Cross-Language Differential Equivalence Gate**:
   - Executes all reference implementations (`Haskell`, `OCaml`, `Rust`, `C++`, `Python`, `SystemVerilog/Verilator`) on shared test vectors and verifies bit-exact agreement on outputs, normal forms, and resource metrics across all three IR tiers (`HL -> ML -> LL`).
4. **Paper Table & Numerical Claim Synchronization Gate**:
   - Recomputes every benchmark table, Pareto frontier coordinate, and cycle-accurate hardware metric from the executable scripts and asserts that every number appearing in the monograph's prose and tables matches the live computed output (`0` drift).

---

### Pillar 11: Peer-Reviewed Academic Prose, Thematic Organization & Anti-AI-Trope Discipline (PLDI / POPL / OOPSLA / *Quantum* Style)

Even when a monograph is backed by mechanized proofs and differential tests, **iterative AI editing easily degrades the prose into an unreadable changelog**. Every manuscript must adhere to the prose, heading, and formatting conventions of top-tier peer-reviewed venues (*PLDI*, *POPL*, *OOPSLA*, *CGO*, *Quantum*, *PRX Quantum*, *EUROCRYPT*) and eliminate AI writing tropes:

1. **Crisp, Self-Contained Abstract (`150–300` Words, Zero Internal Ticket/Table Dumps)**:
   - Model abstracts after peer-reviewed papers (e.g., *Cobble* PLDI '26, *Spire* PLDI '24, *Compiling Qunity* OOPSLA '25, *Guppy* '25, *Silq* PLDI '20): 1–2 tight paragraphs (`150–300` words total) stating **(i)** the core technical problem, **(ii)** the key conceptual and architectural contribution, and **(iii)** headline quantitative results and verification scope.
   - **Never** write an 800-word single-sentence abstract, **never** cite internal table/section numbers (`Table 6F`, `Subsection 7.10.8`) or ticket lists (`S17–S28`, `Passes M1–M10`, `Issues F1–F48`) in the abstract, **never** paste raw code expressions (`effective_correctable_faults(7, 1) == 3`), and **always** keep summary counts unified across the Abstract, Introduction, and Conclusion.
2. **Thematic Organization — Never Chronological `"Phase N"` Worklogs**:
   - When extending a paper across multiple iterations, **integrate new material thematically into the appropriate conceptual section** and update global summary counts in place.
   - **Never** append chronological worklog subsections titled `Phase 12: ...`, `Phase 13: ...`, `Phase 14: ...` or write self-referential transition prose (`"While Phase 13 closed GAP-1..4, a natural question arises in Phase 14..."`). A published paper describes a unified system, not the chronological history of agent prompts.
3. **Concise Conceptual Headings ($\le 12$ Words, $\le 120$ Characters)**:
   - Section and subsection headings must be short, conceptual noun phrases (`3.1 Ownership and Borrowing`, `7.8 Three-Tier Intermediate Representation`, `7.10.12 The CoreQDS Calculus and Three-Loop Execution Model`).
   - **Never** stuff headings or table captions with parenthetical laundry lists of internal identifiers (`### 7.10 Executing on Quantum Machines (S21–S24, Phase-12 QDS-14..16, Phase-13 GAP-1..4, ...)`).
4. **Natural Mathematical & Systems Prose — Never Raw Unit-Test Assertion Dumps**:
   - State invariants, failure modes, and quantitative results in clean English and LaTeX math (e.g., *"reordering Pauli-frame propagation before uncomputation selection leaves a residual $Z$-frame error on the Margolus ancilla"* or *"reduces zone-shuttling heating from $2{,}016$ to $18$ motional quanta ($112\times$)"*).
   - **Never** paste raw camelCase unit-test assertions with boolean flags and inequality operators (`(pde1PassOrderCommutativityDiff(false, 42, 1) == 1 != 0)`) into narrative prose paragraphs. Reserve function identifiers for code listings and artifact cross-reference tables.
5. **Restrained Typography & Anti-Cliché Discipline**:
   - Avoid bolding and backticking every third word (`**Pass M15 (TopologicalPassScheduleDagEnforcer, Simplification S35, Fix F55, Suite 51, Theorem 30A)**`) or wrapping plain English numbers in backticks (write `16 physical qubits`, not `` `16` `` physical qubits).
   - Eliminate repetitive formulaic section templates (`"1. Three New Data Structures... 2. Four New Open Problems... 3. Six Falsified Assumptions..."`) and rhetorical throat-clearing (`"resolves two foundational questions at the boundary of..."`, `"crucial hazard"`, `"exact 100% precision"`).
6. **Strict Citation & arXiv ID Verification**:
   - Every cited paper must use its exact published/preprint authors, venue, year, and verified `arXiv` identifier (never guess or hallucinate arXiv numbers).

---

## Standard Monograph Blueprint (Recommended Section Structure)

When authoring a full paper or monograph using this skill, organize the document along the following 10-section spine:

1. **§1. Executive Summary & Honest Scope Ledger**:
   - Problem statement, core insight, summary of contributions, and the **Honest Asymptotic & Physical Scope Boundary Table** (Pillar 2).
2. **§2. Motivating Failure Modes & Bug-Driven Design (`Issues F1..Fn`)**:
   - Concrete counterexample traces showing why existing/naive approaches fail, motivating each static invariant and architectural mechanism (Pillar 5).
3. **§3. Tier 1 High-Level Domain / Modal Calculus (`HL-IR`)**:
   - Syntax, structural/modal type system, operational semantics, concrete worked example, and mechanized soundness theorems (Pillars 1, 4, 9).
4. **§4. Tier 2 Canonical Region IR & Algebraic Simplification Ledger (`ML-IR` & `S1..Sm`)**:
   - Scoped `Setup-Action-Cleanup` regions, Normalization-by-Evaluation (NbE), $O(1)$ bitboard decision procedures, and proved cost-non-increasing simplification rules (Pillars 4, 6, 9).
5. **§5. Tier 3 Target Schedule Lowering & Multi-Objective Pareto Frontier (`LL-IR`)**:
   - Target cost functors, schedule selection (`Min-Space`, `Balanced Knee`, `Min-Depth`), and non-dominated Pareto analysis (Pillars 4, 7).
6. **§6. Real-Time Microarchitectural & Physical Pipeline Accounting**:
   - Cycle-accurate datapath stages, clock frequency, LUT/FF/BRAM/DSP resource breakdown, and hard real-time deadline slack (Pillar 8).
7. **§7. Multi-Regime Evaluation Matrix (`Regimes I–V`)**:
   - Comprehensive evaluation across all 5 deployment regimes against state-of-the-art baselines with exact absolute metrics and relative speedups/reductions (Pillar 3).
8. **§8. Cross-Language Reference Implementations & Differential Testing**:
   - Architecture of the multi-language implementations (`Haskell`, `OCaml`, `Rust`, `C++`, `Python`, `RTL`) and grammar-guided fuzzing results (Pillars 1, 5, 10).
9. **§9. Related Work & Quantitative Comparison**:
   - Detailed feature-by-feature and asymptotic comparison table against prior literature.
10. **§10. Artifact Cross-Reference Ledger & Single-Command Verification**:
    - Complete mapping from every theorem, figure, and table to source files and the automated `verify_*.py` pipeline output (Pillars 1, 10).

---

## Pre-Submission Audit Checklist

Before declaring any research paper or monograph complete, verify every item below:

- [ ] **Pillar 1 (Executable Sync)**: Does every theorem, lemma, algorithm, and numerical claim map to a concrete proof symbol or test in the Artifact Cross-Reference Ledger? Are there `0 sorry` and `0 axiom`?
- [ ] **Pillar 2 (Honest Scope)**: Does every speedup or complexity table include a "What Fundamental Lower Bound Does Not Change" column and separate asymptotic projections from today-executable hardware numbers?
- [ ] **Pillar 3 (Multi-Regime Matrix)**: Are benchmarks evaluated across multiple distinct architectural regimes (Monolithic, Tiered/Hierarchical, Packed/High-Rate, Distributed, Today-Executable) against strong SOTA baselines?
- [ ] **Pillar 4 (`HL -> ML -> LL` Separation)**: Is target-independent semantics (`Tier 1`) cleanly separated from canonical region/algebraic normalization (`Tier 2`) and hardware schedule lowering (`Tier 3`)?
- [ ] **Pillar 5 (Bug-Driven Narrative)**: Are static typing rules and invariants motivated by concrete fuzzer-discovered failure traces (`F1..Fn`) with `100%` negative mutation rejection tests?
- [ ] **Pillar 6 (Simplification Ledger)**: Are new features paired with explicit algebraic/architectural simplifications (`S1..Sm`) proven not to increase cost?
- [ ] **Pillar 7 (Pareto Frontier)**: Are multi-objective resource tradeoffs presented as non-dominated Pareto frontiers (`Min-Space`, `Balanced Knee`, `Min-Depth`) rather than arbitrary scalar weights?
- [ ] **Pillar 8 (Cycle-Accurate Hardware Accounting)**: Are all latency and hardware claims backed by stage-by-stage cycle counts, clock frequencies, LUT/FF/BRAM/DSP tables, and explicit deadline slack?
- [ ] **Pillar 9 (Self-Contained Exposition)**: Does every major section include a concrete small-scale worked trace, an ASCII/Mermaid diagram, and numbered pseudocode (`Algorithm 1..K`)?
- [ ] **Pillar 10 (Automated Differential Verification)**: Does the single-command verification script pass `100%` of proofs, positive/negative fuzz suites, cross-language differential checks, and table numerical synchronization assertions?
- [ ] **Pillar 11 (Peer-Reviewed Prose & Anti-AI-Trope Gate)**: Is the Abstract `150–300` words with unified final numbers? Are all headings thematic and $\le 120$ characters with zero `"Phase N"` worklog labels? Is narrative prose free of raw `foo(false) == 1 != 0` assertion dumps, bold-backtick soup, and hallucinated citation IDs?

