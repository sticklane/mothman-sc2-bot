# `LakefillQ` Artifact Evaluation Guide (`ACM` Functional, Reusable & Reproduced)

This document provides step-by-step instructions for evaluating the standalone open-source artifact bundle accompanying **`LakefillQ`: Purely Functional Data Structures, Substructural Typing, and Graded Physical Compilation for Low-Width Fault-Tolerant Quantum Circuits** ([`../paper/lakefillq_paper.pdf`](../paper/lakefillq_paper.pdf), [`../paper/lakefillq_paper.tex`](../paper/lakefillq_paper.tex), [`../PAPER_OKASAKI_QUANTUM_DATA_STRUCTURES.md`](../PAPER_OKASAKI_QUANTUM_DATA_STRUCTURES.md), and [`../README.md`](../README.md)).

---

## 1. ACM Artifact Badge Summary

| ACM Artifact Badge | Artifact Support & Verification Evidence |
| :--- | :--- |
| **`Artifacts Evaluated — Functional`** | One-command smoke check (`make quick`, `< 35s`) links `#lang lakefillq`, compiles `.lfq` source programs through `LakefillQ -> lambda_LFQ_kern -> RevIR -> MachineISA` to runnable dynamic `OpenQASM 3.0` and `Stim`, runs the standalone Python `OpenQASM 3.0` / `Qiskit` bug-linter ([`lakefillq_lint.py`](lakefillq_lint.py)), runs `XAG`/`FRAIG + Z3` symbolic `QSub` inference, executes congruence-closed `RevIR` `e-graph` equality saturation across 4 hardware targets, certifies `0-DSP` SystemVerilog/DSLX hardware hygiene, kernel-checks `Lean 4.35.0` formal proofs, and runs all proof/link/GFM sanitizers. |
| **`Artifacts Evaluated — Reusable`** | Modular Racket `#lang lakefillq` surface reader ([`../lakefillq/main.rkt`](../lakefillq/main.rkt)), standalone CLI compiler ([`../compiler/lakefillqc.rkt`](../compiler/lakefillqc.rkt) supporting `--emit-qasm3`, `--emit-stim`, `--emit-cluster-dir`, and `--diagnostics-human`), drop-in Python `OpenQASM 3.0` / `Qiskit` bug-linter & convex $M^* \le 256$ cluster sizer ([`lakefillq_lint.py`](lakefillq_lint.py)), symbolic `XAG`/`FRAIG + Z3` typechecker ([`../compiler/lakefillq-xag-fraig-typechecker.rkt`](../compiler/lakefillq-xag-fraig-typechecker.rkt)), `QPhysGrade` `e-graph` extractor ([`../compiler/lakefillq-egraph-saturator.rkt`](../compiler/lakefillq-egraph-saturator.rkt)), synthesizable SystemVerilog & Google XLS DSLX `0-DSP` syndrome decoder ([`../hardware/lakefillq_0dsp_braun_uf_decoder.sv`](../hardware/lakefillq_0dsp_braun_uf_decoder.sv), [`../hardware/lakefillq_0dsp_braun_uf_decoder.x`](../hardware/lakefillq_0dsp_braun_uf_decoder.x)), interactive explorer ([`lakefillq_explorer.py`](lakefillq_explorer.py)), and self-contained [`../Dockerfile`](../Dockerfile). |
| **`Results Reproduced`** | Complete reproduction (`make full` and `make paper`) re-verifies all `125` quantitative claims in [`../reproducers/artifacts/lakefillq_paper_claim_manifest.json`](../reproducers/artifacts/lakefillq_paper_claim_manifest.json), all `AerSimulator` / `Stim` / `PyMatching` / `PyZX` simulator checks (including non-Clifford ZX phase-polynomial saturation, $[8,5,3]_{\mathbb{F}_4}$ Hermitian AG Early-`MBU` `DQI`, `2.11M`-shot noisy optical-link distillation, and `640` `PLT Redex` `#lang lakefillq` surface/diagnostic modules), all `Z3` `QF_BV` hardware miters and `80,000`-cycle `Stim` co-simulations, and `100%` of the `2,305` mechanized `Lean 4.35.0` theorems (`0 sorry`, `0 axiom`) across `82` modules. |

---

## 2. System Requirements & Persistent Scratch Architecture

- **Hardware**: Standard `x86_64` or `ARM64` Linux / macOS machine with `4+` CPU cores and `8 GB` RAM (`16 GB` recommended for `make full`). No GPU or physical quantum hardware access is required.
- **Automatic Toolchain Discovery**: Both [`../Makefile`](../Makefile) and [`run_artifact_evaluation.py`](run_artifact_evaluation.py) automatically discover `python3` (checking `z3`, `stim`, `qiskit`, `qiskit-aer`, `pymatching`, `pyzx`), `racket`, `raco`, and `lean` (`Lean 4.35.0`) across `PATH`, workspace/parent `.venv/bin`, and persistent toolchain directories without hardcoded user paths.
- **Persistent Scratch Policy**: Every target routes `TMPDIR` to a persistent directory (removing workspace-local `.lakefillq_tmp` cleanly upon target completion so `git status` remains clean) and sets `PYTHONDONTWRITEBYTECODE=1`.

---

## 3. Getting Started (`< 35s` Smoke Check & Drop-In Linter)

### Option A: Native One-Command Evaluation (From Repository Root)

```bash
# Display available Make targets and resolved toolchain paths
make help

# Run the fast (< 35s) 10-gate end-to-end smoke check
make quick

# Run the drop-in OpenQASM 3.0 / Qiskit static bug-linter & M* <= 256 cluster sizer self-test
python3 ae/lakefillq_lint.py --self-test

# Inspect Single-Machine, Parallel-Machine, & Serial-Multishot results, RTL, and proofs
make explore
```

### Option B: Self-Contained Reproducible Docker Container

[`../Dockerfile`](../Dockerfile) builds a clean single-image `debian:bookworm-slim` container pre-configured with `Python 3`, `Racket` (`#lang lakefillq` linked), `Lean 4.35.0`, `GHC`, `OCaml`, `TeX Live`, `z3-solver`, `qiskit`, `qiskit-aer`, `stim`, `pymatching`, and `pyzx`:

```bash
# Build the self-contained container image from the repository root
docker build -t lakefillq-ae .

# Run the default < 35s smoke check (make quick)
docker run --rm lakefillq-ae

# Launch the terminal explorer summary inside the container
docker run --rm lakefillq-ae make explore

# Run full end-to-end reproduction inside the container
docker run --rm lakefillq-ae make full
```

---

## 4. `Makefile` Targets & Execution Budget

All targets in [`../Makefile`](../Makefile) exit with code `0` if and only if every underlying check succeeds:

| Command | Typical Wall-Clock | Underlying Components Verified |
| :--- | :---: | :--- |
| `make help` | `< 1s` | Prints target descriptions and resolved `PYTHON`, `RACKET`, `RACO`, `LEAN`, and `TMPDIR` paths. |
| `make quick` | `~15s` (`< 35s`) | Runs [`run_artifact_evaluation.py`](run_artifact_evaluation.py) `--mode quick`: links `#lang lakefillq`, compiles [`../examples/aes_sbox_bp34.lfq`](../examples/aes_sbox_bp34.lfq) to dynamic `OpenQASM 3.0` & `Stim`, runs [`lakefillq_lint.py`](lakefillq_lint.py) `--self-test`, typechecks `191-Q` `Add64` (`UNSAT`) + bit-47 premature-`MBU` fault (`SAT`) via `XAG`/`FRAIG + Z3`, runs `RevIR` `e-graph` saturation, audits `0-DSP` RTL, compiles a standalone `Lean 4.35.0` proof module, and runs all 3 repository/proof linters. |
| `make examples` | `~10s` | Compiles every `.lfq` program in [`../examples/`](../examples/) via [`../compiler/lakefillqc.rkt`](../compiler/lakefillqc.rkt) to JSON, dynamic `OpenQASM 3.0`, and `Stim`. |
| `make explore` | `< 1s` | Runs [`lakefillq_explorer.py`](lakefillq_explorer.py) `--summary` over on-disk JSON reports. |
| `make paper` | `~45s` | Runs [`../reproducers/verify_lakefillq_paper_claims_and_latex_manifest.py`](../reproducers/verify_lakefillq_paper_claims_and_latex_manifest.py) cross-checking `125` quantitative claims, `21` formal paper labels, `29` `Lean 4.35.0` kernel modules, and `acmart` LaTeX / `120` BibTeX entries. |
| `make rtl` | `~95s` | Runs [`../reproducers/verify_lakefillq_0dsp_rtl_z3_and_stim_cosim.py`](../reproducers/verify_lakefillq_0dsp_rtl_z3_and_stim_cosim.py) (`500 MHz` `0-DSP` netlist synthesis, `3/3` `Z3` `QF_BV` `UNSAT` miters across all `4,096` $d=5$ syndromes, and `80,000`-cycle `Stim` co-simulation). |
| `make proofs` | `~2–4 min` | Runs the `Lean 4.35.0` kernel across all standalone `proofs/lakefillq_*_proofs.lean` and `proofs/sota_*_proofs.lean` modules plus [`../proofs/quantum_type_theory_and_intrinsic_qds_proofs.lean`](../proofs/quantum_type_theory_and_intrinsic_qds_proofs.lean). |
| `make full` | `~8–14 min` | Runs [`run_artifact_evaluation.py`](run_artifact_evaluation.py) `--mode full` executing every compiler, multi-QPU cluster codegen, linter, optical-link `Stim`, 3-span diagnostic, `640`-module `PLT Redex` `#lang lakefillq` surface/diagnostic fuzzer, holistic cohesion & 22-program error-clarity probe, multi-block `XAG`/`FRAIG`, ZX `e-graph` & Hermitian AG `DQI` simulator, `0-DSP` RTL, LaTeX claim manifest, `Lean 4.35.0` kernel, and Haskell/OCaml quantum type-theory verifier. |
| `make clean` | `< 1s` | Cleans workspace-local scratch directories and Python bytecode caches. |

---

## 5. Interactive & Flag-Driven Explorer (`ae/lakefillq_explorer.py`)

[`lakefillq_explorer.py`](lakefillq_explorer.py) queries live JSON evaluation reports in `reproducers/artifacts/` and `reproducers/` and compiles `.lfq` modules across hardware targets:

```bash
# 1. Executive dashboard: artifact inventory, 3-mode SOTA overview, .lfq grades, RTL, & proofs
python3 ae/lakefillq_explorer.py --summary

# 2. Dedicated resource tables by execution regime (Single-QPU vs Parallel-QPU vs Serial-Multishot)
python3 ae/lakefillq_explorer.py --mode single
python3 ae/lakefillq_explorer.py --mode parallel
python3 ae/lakefillq_explorer.py --mode multishot

# 3. Drill down into a specific algorithm family (with Lean 4.35.0 theorem mappings)
python3 ae/lakefillq_explorer.py --algorithm ecc
python3 ae/lakefillq_explorer.py --algorithm rsa
python3 ae/lakefillq_explorer.py --algorithm aes
python3 ae/lakefillq_explorer.py --algorithm dqi

# 4. Live-compile any #lang lakefillq program to OpenQASM 3.0 & Stim for a chosen target
python3 ae/lakefillq_explorer.py --compile examples/aes_sbox_bp34.lfq --target heron-r2
python3 ae/lakefillq_explorer.py --compile examples/early_mbu_dqi_bch7.lfq --target bluvstein-aod
python3 ae/lakefillq_explorer.py --compile examples/early_mbu_dqi_hermitian_ag_f4.lfq --target bb-qldpc

# 5. Inspect external 500 MHz 0-DSP SystemVerilog/DSLX subblocks, Z3 miters, and 80k-cycle Stim co-sim
python3 ae/lakefillq_explorer.py --inspect-rtl

# 6. Inspect all 125 quantitative paper claims and formal paper-to-Lean 4.35.0 mappings
python3 ae/lakefillq_explorer.py --check-claims

# 7. Emit machine-readable JSON for any view or launch the interactive terminal menu
python3 ae/lakefillq_explorer.py --summary --json
python3 ae/lakefillq_explorer.py --interactive
```

---

## 6. Paper-to-Artifact Claim & Module Directory

| Paper Component | Primary Implementation & Formal Proof Files | JSON Artifact & Verification Script |
| :--- | :--- | :--- |
| **`#lang lakefillq` Surface Calculus, 6-Primitive Kernel & Dynamic `OpenQASM 3.0` / `Stim` Codegen** | [`../lakefillq/main.rkt`](../lakefillq/main.rkt), [`../compiler/lakefillqc.rkt`](../compiler/lakefillqc.rkt), [`../examples/mod13_adder_mbu.lfq`](../examples/mod13_adder_mbu.lfq), [`../examples/kawamura_rns_crt_u2.lfq`](../examples/kawamura_rns_crt_u2.lfq), [`../examples/modular_compositional_cipher.lfq`](../examples/modular_compositional_cipher.lfq), [`../proofs/lakefillq_unified_compiler_elaboration_and_qasm3_proofs.lean`](../proofs/lakefillq_unified_compiler_elaboration_and_qasm3_proofs.lean) | [`../reproducers/artifacts/lakefillq_unified_compiler_report.json`](../reproducers/artifacts/lakefillq_unified_compiler_report.json), [`../reproducers/verify_lakefillq_unified_compiler_and_openqasm3.py`](../reproducers/verify_lakefillq_unified_compiler_and_openqasm3.py) |
| **Unified Graded Coeffect-Effect Bimodule & Ordered Partial Duoidal Judgment $\Gamma_{\text{in}} \vdash t : \mathcal{Q}_e(A) \dashv \Gamma_{\text{out}}$** | [`../compiler/lakefillq-graded-coeffect-effect-bimodule.rkt`](../compiler/lakefillq-graded-coeffect-effect-bimodule.rkt), [`../proofs/lakefillq_graded_coeffect_uniqueness_place_effect_proofs.lean`](../proofs/lakefillq_graded_coeffect_uniqueness_place_effect_proofs.lean), [`../proofs/lakefillq_holistic_modular_duoidal_cohesion_proofs.lean`](../proofs/lakefillq_holistic_modular_duoidal_cohesion_proofs.lean) | [`../reproducers/artifacts/lakefillq_graded_type_theory_synthesis_report.json`](../reproducers/artifacts/lakefillq_graded_type_theory_synthesis_report.json), [`../reproducers/verify_lakefillq_graded_coeffect_effect_calculus.py`](../reproducers/verify_lakefillq_graded_coeffect_effect_calculus.py) |
| **Three-Span Multipass Diagnostic Provenance, Chordal Resugaring, `640`-Module `PLT Redex` Surface Fuzzer & 22 Real Error Probes** | [`../compiler/lakefillq-multipass-diagnostics.rkt`](../compiler/lakefillq-multipass-diagnostics.rkt), [`../compiler/lakefillq-redex-surface-diagnostic-fuzzer.rkt`](../compiler/lakefillq-redex-surface-diagnostic-fuzzer.rkt), [`../lakefillq/main.rkt`](../lakefillq/main.rkt), [`../proofs/lakefillq_multipass_diagnostic_provenance_proofs.lean`](../proofs/lakefillq_multipass_diagnostic_provenance_proofs.lean), [`../proofs/lakefillq_redex_surface_diagnostic_fuzzer_proofs.lean`](../proofs/lakefillq_redex_surface_diagnostic_fuzzer_proofs.lean), [`../proofs/lakefillq_holistic_modular_duoidal_cohesion_proofs.lean`](../proofs/lakefillq_holistic_modular_duoidal_cohesion_proofs.lean) | [`../reproducers/artifacts/lakefillq_multipass_diagnostics_report.json`](../reproducers/artifacts/lakefillq_multipass_diagnostics_report.json), [`../reproducers/artifacts/lakefillq_redex_surface_diagnostic_fuzzer_report.json`](../reproducers/artifacts/lakefillq_redex_surface_diagnostic_fuzzer_report.json), [`../reproducers/artifacts/lakefillq_holistic_language_cohesion_report.json`](../reproducers/artifacts/lakefillq_holistic_language_cohesion_report.json), [`../reproducers/verify_lakefillq_multipass_diagnostics.py`](../reproducers/verify_lakefillq_multipass_diagnostics.py), [`../reproducers/verify_lakefillq_redex_surface_diagnostic_fuzzer.py`](../reproducers/verify_lakefillq_redex_surface_diagnostic_fuzzer.py), [`../reproducers/verify_lakefillq_holistic_language_cohesion.py`](../reproducers/verify_lakefillq_holistic_language_cohesion.py) |
| **Multi-QPU Cluster `OpenQASM 3.0` Partition Codegen (`--emit-cluster-dir`) & `ebit_schedule.json`** | [`../compiler/lakefillq-cluster-qasm3-codegen.rkt`](../compiler/lakefillq-cluster-qasm3-codegen.rkt), [`../examples/distributed_qrns_shor_u4.lfq`](../examples/distributed_qrns_shor_u4.lfq), [`../examples/aes_sbox_dlog5_13q.lfq`](../examples/aes_sbox_dlog5_13q.lfq), [`../proofs/lakefillq_cluster_qasm3_partition_proofs.lean`](../proofs/lakefillq_cluster_qasm3_partition_proofs.lean) | [`../reproducers/artifacts/lakefillq_cluster_qasm3_codegen_report.json`](../reproducers/artifacts/lakefillq_cluster_qasm3_codegen_report.json), [`../reproducers/verify_lakefillq_cluster_qasm3_partition_codegen.py`](../reproducers/verify_lakefillq_cluster_qasm3_partition_codegen.py) |
| **Drop-In Python `OpenQASM 3.0` / `Qiskit` Static Bug-Linter & Convex $M^* \le 256$ Sizer** | [`lakefillq_lint.py`](lakefillq_lint.py), [`../proofs/lakefillq_qasm_python_linter_lifting_proofs.lean`](../proofs/lakefillq_qasm_python_linter_lifting_proofs.lean) | [`../reproducers/artifacts/lakefillq_python_qasm_linter_report.json`](../reproducers/artifacts/lakefillq_python_qasm_linter_report.json), [`../reproducers/verify_lakefillq_python_qasm_linter.py`](../reproducers/verify_lakefillq_python_qasm_linter.py) |
| **`2.11M`-Shot Noisy Optical-Link `Stim` + `PyMatching` Distillation & `Law U4` Simulation** | [`../compiler/lakefillq-optical-distillation-stim.rkt`](../compiler/lakefillq-optical-distillation-stim.rkt), [`../proofs/lakefillq_noisy_optical_link_distillation_proofs.lean`](../proofs/lakefillq_noisy_optical_link_distillation_proofs.lean) | [`../reproducers/artifacts/lakefillq_noisy_optical_link_stim_report.json`](../reproducers/artifacts/lakefillq_noisy_optical_link_stim_report.json), [`../reproducers/verify_lakefillq_noisy_optical_link_stim.py`](../reproducers/verify_lakefillq_noisy_optical_link_stim.py) |
| **Annotation-Free `QSub` (`Laws U1–U4`) & `XAG`/`FRAIG + Z3` Cut-Sweeping Inference (`AES-128/256`, `Keccak-f[200]`, `Add64`)** | [`../compiler/lakefillq-xag-fraig-typechecker.rkt`](../compiler/lakefillq-xag-fraig-typechecker.rkt), [`../proofs/lakefillq_xag_fraig_symbolic_inference_proofs.lean`](../proofs/lakefillq_xag_fraig_symbolic_inference_proofs.lean) | [`../reproducers/artifacts/lakefillq_xag_fraig_inference_report.json`](../reproducers/artifacts/lakefillq_xag_fraig_inference_report.json), [`../reproducers/verify_lakefillq_xag_fraig_z3_multiblock_inference.py`](../reproducers/verify_lakefillq_xag_fraig_z3_multiblock_inference.py) |
| **Non-Clifford ZX `RevIR` `e-Graph` Saturation, Bellman–Knuth `QPhysGrade` Extraction & Hermitian AG Early-`MBU` `DQI`** | [`../compiler/lakefillq-egraph-saturator.rkt`](../compiler/lakefillq-egraph-saturator.rkt), [`../examples/early_mbu_dqi_hermitian_ag_f4.lfq`](../examples/early_mbu_dqi_hermitian_ag_f4.lfq), [`../proofs/lakefillq_egraph_qphys_saturation_proofs.lean`](../proofs/lakefillq_egraph_qphys_saturation_proofs.lean), [`../proofs/lakefillq_zx_phase_poly_and_ag_dqi_proofs.lean`](../proofs/lakefillq_zx_phase_poly_and_ag_dqi_proofs.lean) | [`../reproducers/artifacts/lakefillq_egraph_qphys_extraction_report.json`](../reproducers/artifacts/lakefillq_egraph_qphys_extraction_report.json), [`../reproducers/artifacts/lakefillq_zx_egraph_and_ag_dqi_report.json`](../reproducers/artifacts/lakefillq_zx_egraph_and_ag_dqi_report.json), [`../reproducers/verify_lakefillq_egraph_qphys_extraction_on_simulators.py`](../reproducers/verify_lakefillq_egraph_qphys_extraction_on_simulators.py), [`../reproducers/verify_lakefillq_zx_egraph_and_ag_dqi.py`](../reproducers/verify_lakefillq_zx_egraph_and_ag_dqi.py) |
| **External `500 MHz` `0-DSP` `BraunTree` + Shiloach–Vishkin Union-Find Decoder Feasibility ($H_Z c = s$, `0.0 ns` Backlog)** | [`../hardware/lakefillq_0dsp_braun_uf_decoder.sv`](../hardware/lakefillq_0dsp_braun_uf_decoder.sv), [`../hardware/lakefillq_0dsp_braun_uf_decoder.x`](../hardware/lakefillq_0dsp_braun_uf_decoder.x), [`../proofs/lakefillq_0dsp_rtl_decoder_and_cosim_proofs.lean`](../proofs/lakefillq_0dsp_rtl_decoder_and_cosim_proofs.lean) | [`../reproducers/artifacts/lakefillq_0dsp_rtl_stim_cosim_report.json`](../reproducers/artifacts/lakefillq_0dsp_rtl_stim_cosim_report.json), [`../reproducers/verify_lakefillq_0dsp_rtl_z3_and_stim_cosim.py`](../reproducers/verify_lakefillq_0dsp_rtl_z3_and_stim_cosim.py) |
| **Purely Functional Quantum Data Structures & Intrinsic `Haskell` / `OCaml` / `Lean 4` GADTs** | [`../lean4/OkasakiQuantumDataStructures.lean`](../lean4/OkasakiQuantumDataStructures.lean), [`../haskell/OkasakiQuantumDataStructures.hs`](../haskell/OkasakiQuantumDataStructures.hs), [`../ocaml/okasaki_quantum_data_structures.ml`](../ocaml/okasaki_quantum_data_structures.ml), [`../proofs/quantum_type_theory_and_intrinsic_qds_proofs.lean`](../proofs/quantum_type_theory_and_intrinsic_qds_proofs.lean) | [`../reproducers/verify_haskell_ocaml_quantum_type_theory_and_simulators.py`](../reproducers/verify_haskell_ocaml_quantum_type_theory_and_simulators.py) |
| **Camera-Ready `acmart` PDF & Manuscript, `120` BibTeX Citations & Proof Hygiene Gates** | [`../paper/lakefillq_paper.pdf`](../paper/lakefillq_paper.pdf), [`../paper/lakefillq_paper.tex`](../paper/lakefillq_paper.tex), [`../paper/references.bib`](../paper/references.bib) | [`../reproducers/artifacts/lakefillq_paper_claim_manifest.json`](../reproducers/artifacts/lakefillq_paper_claim_manifest.json), [`../reproducers/verify_lakefillq_paper_claims_and_latex_manifest.py`](../reproducers/verify_lakefillq_paper_claims_and_latex_manifest.py), [`../reproducers/sanitize_lean4_preprint_and_audit_gaps.py`](../reproducers/sanitize_lean4_preprint_and_audit_gaps.py), [`../reproducers/audit_comparator_statement_integrity_and_small_proofs.py`](../reproducers/audit_comparator_statement_integrity_and_small_proofs.py), [`../reproducers/lint_proofs_benchmarks_and_gfm.py`](../reproducers/lint_proofs_benchmarks_and_gfm.py) |

---

## 7. Reusability: Writing & Compiling Custom `#lang lakefillq` Programs or Linting External `OpenQASM 3.0` / `Qiskit` Circuits

1. **Create a `.lfq` Source Module**: Start any file with `#lang lakefillq`, declare `(target heron-r2)` (or `bluvstein-aod`, `bb-qldpc`, `ideal`), and write classical-reversible `defqfree` or quantum `defq` circuits using `(with-and-session ...)`, `(within-apply-mbu compute action)`, `(erase-by fwd bwd)`, `match-wires`, and functional combinators (see [`../examples/aes_sbox_bp34.lfq`](../examples/aes_sbox_bp34.lfq), [`../examples/distributed_qrns_shor_u4.lfq`](../examples/distributed_qrns_shor_u4.lfq), and [`../examples/early_mbu_dqi_bch7.lfq`](../examples/early_mbu_dqi_bch7.lfq)).
2. **Compile, Partition Across Multi-QPU Clusters & Render 3-Span Diagnostics**: Invoke `racket compiler/lakefillqc.rkt --input path/to/module.lfq --target heron-r2 --emit-json --emit-qasm3 out.qasm --emit-stim out.stim` (add `--emit-cluster-dir out_dir --q-cap 400 --r-bell 100000` for per-QPU `OpenQASM 3.0` + `ebit_schedule.json`, `--diagnostics-human` for Elm/Rust-style 3-span provenance cards, or `--repair` for counterexample-guided `XY4` / chromatic / `N-Z-S-W` repair).
3. **Lint Existing `OpenQASM 3.0` / `Qiskit` Circuits Without Rewriting in `#lang lakefillq`**: Run `python3 ae/lakefillq_lint.py path/to/circuit.qasm --json --q-cap 400 --r-bell 100000 --topology switched-optical-tree --max-machines 256` to check all 7 projected rules (`T-DomImg`, `T-BorrowZ`, `T-PhaseClean`, `T-CounitU4`, `T-SubNorm`, `T-QubitCap`, `T-ParGuard`) with 3-span provenance and `Z3` witnesses.

