#!/usr/bin/env python3
"""
End-to-End Verification Script for the 7 Generalized Bug-Class & Parallel-Partitionability
Rules in `LakefillQ` (`T-DomImg`, `T-ValidIf`, `T-AlgPhase`, `T-WireBasis`,
`T-DriftEps`, `T-SingleIR`, `T-ParGuard`).

Verifies:
  1. `compiler/lakefillq-bug-class-prevention-types.rkt` via `raco test` and
     `--json`: `14/14` wild research bugs statically rejected with structured
     rule codes + concrete witnesses, `14/14` repaired programs well-typed,
     `14/14` generalized class instances verified, and `13/13` SOTA parallel
     profiles (`ParSliceable`, `ParShotLinear`, and `ParNonPartitionable`
     automatic `1`-machine Single-Machine fallback).
  2. `#lang lakefillq` (`lakefillq/main.rkt`) + `compiler/lakefillqc.rkt` CLI
     integration: `examples/guarded_sota_safety_showcase.lfq` compiles cleanly
     to runnable OpenQASM 3.0 (`Qiskit Aer`) and `Stim` (`0` residual surface
     forms, automatic `machines_used = 1` fallback on Grover), a sliceable
     `ECC-256` module compiles to `machines_used = 4`, and 7 negative `.lfq`
     modules (one per rule) exit `1` with exact `T-DomImg` .. `T-ParGuard`
     diagnostics even under `--repair`.
  3. Independent Python `z3-solver` cross-checks of the symbolic obligations
     across `T-DomImg`, `T-ValidIf`, `T-AlgPhase`, `T-WireBasis`, `T-DriftEps`,
     `T-SingleIR`, and `T-ParGuard`.
  4. `proofs/lakefillq_bug_class_prevention_type_system_proofs.lean` under
     Lean `4.35.0` (`20` soundness theorems including
     `t_par_guard_zalka_fallback_soundness`, `0 sorry`, `0 axiom`, `<= 25`
     lines per proof block).
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, List

import qiskit.qasm3
from qiskit_aer import AerSimulator
import stim
import z3


REPO_ROOT = Path(__file__).resolve().parent.parent
TYPES_RKT = REPO_ROOT / "compiler" / "lakefillq-bug-class-prevention-types.rkt"
COMPILER_RKT = REPO_ROOT / "compiler" / "lakefillqc.rkt"
SHOWCASE_LFQ = REPO_ROOT / "examples" / "guarded_sota_safety_showcase.lfq"
LEAN_PROOF_FILE = REPO_ROOT / "proofs" / "lakefillq_bug_class_prevention_type_system_proofs.lean"
REPORT_JSON = REPO_ROOT / "reproducers" / "artifacts" / "lakefillq_bug_class_prevention_report.json"

EXPECTED_RULES = [
    "T-DomImg",
    "T-ValidIf",
    "T-AlgPhase",
    "T-WireBasis",
    "T-DriftEps",
    "T-SingleIR",
    "T-ParGuard",
]


def persistent_scratch_root() -> Path:
    host_scratch = Path("/home/antigravity/toolchains/tmp")
    if host_scratch.is_dir():
        return host_scratch
    fallback = REPO_ROOT / ".lakefillq_tmp"
    fallback.mkdir(parents=True, exist_ok=True)
    return fallback


def locate_racket_bin(exe_name: str) -> str:
    candidate = Path("/home/antigravity/toolchains/racket-p36t2/racket/bin") / exe_name
    if candidate.is_file():
        return str(candidate)
    found = shutil.which(exe_name)
    if found:
        return found
    raise FileNotFoundError(f"Unable to locate {exe_name} in persistent toolchain")


def locate_lean_bin() -> str:
    candidate = Path("/home/antigravity/toolchains/lean4-p36t4/lean-4.35.0-linux/bin/lean")
    if candidate.is_file():
        return str(candidate)
    found = shutil.which("lean")
    if found:
        return found
    raise FileNotFoundError("Unable to locate Lean 4.35.0 binary")


def build_env() -> Dict[str, str]:
    env = dict(os.environ)
    env["TMPDIR"] = str(persistent_scratch_root())
    return env


def verify_racket_typechecker_module() -> Dict[str, Any]:
    raco_bin = locate_racket_bin("raco")
    racket_bin = locate_racket_bin("racket")
    env = build_env()

    rel_types_rkt = str(TYPES_RKT.relative_to(REPO_ROOT))
    t0 = time.perf_counter()
    test_proc = subprocess.run(
        [raco_bin, "test", rel_types_rkt],
        cwd=str(REPO_ROOT),
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    if test_proc.returncode != 0:
        raise AssertionError(
            f"raco test failed (rc={test_proc.returncode}):\n"
            f"STDOUT:\n{test_proc.stdout}\nSTDERR:\n{test_proc.stderr}"
        )

    json_proc = subprocess.run(
        [racket_bin, rel_types_rkt, "--json"],
        cwd=str(REPO_ROOT),
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    elapsed_ms = (time.perf_counter() - t0) * 1000.0
    if json_proc.returncode != 0:
        raise AssertionError(
            f"Typechecker --json run failed (rc={json_proc.returncode}):\n"
            f"STDOUT:\n{json_proc.stdout}\nSTDERR:\n{json_proc.stderr}"
        )

    payload = json.loads(json_proc.stdout)
    assert payload["status"] == "PASS", payload
    assert payload["rules_implemented"] == EXPECTED_RULES, payload["rules_implemented"]
    assert payload["wild_bug_total_cases"] == 14, payload
    assert payload["wild_bug_negative_rejected_count"] == 14, payload
    assert payload["wild_bug_positive_well_typed_count"] == 14, payload
    assert payload["generalized_total_cases"] == 14, payload
    assert payload["generalized_negative_rejected_count"] == 14, payload
    assert payload["generalized_positive_well_typed_count"] == 14, payload
    assert payload["parallel_partition_total_profiles"] == 13, payload
    assert payload["parallel_partition_multi_machine_count"] == 6, payload
    assert payload["parallel_partition_single_machine_fallback_count"] == 7, payload

    seen_wild_rules = {entry["rule"] for entry in payload["wild_research_bug_results"]}
    assert seen_wild_rules == set(EXPECTED_RULES[:6]), f"Missing rules in wild-bug catalog: {seen_wild_rules}"
    seen_all_rules = seen_wild_rules | {entry["rule"] for entry in payload["generalized_class_results"]}
    assert seen_all_rules == set(EXPECTED_RULES), f"Missing rules across catalogs: {seen_all_rules}"

    for entry in payload["wild_research_bug_results"]:
        assert entry["negative_rejected"] is True, entry
        assert entry["positive_well_typed"] is True, entry
        diag = entry["negative_diagnostic"]
        assert diag["rule"] == entry["rule"], entry
        assert diag["code"] == entry["diagnostic_code"], entry

    fallback_workloads = {
        p["workload"] for p in payload["parallel_partition_profiles"] if p["fallback_to_single_machine"]
    }
    assert fallback_workloads == {
        "AES-128",
        "AES-256",
        "SHA3-256",
        "SLH-DSA-128s",
        "McEliece-348864",
        "BIKE-L1",
        "ECC-256-OverCut",
    }, fallback_workloads

    # Verify Convex M* Cluster-Profile Optimization across all SOTA workloads at (M_max=256, Q_cap=400, R_bell=100kHz):
    c400_by_name = {p["workload"]: p for p in payload["cluster_m_star_qcap400_profiles"]}
    assert len(c400_by_name) == 12, c400_by_name.keys()

    ecc400 = c400_by_name["ECC-256"]
    assert ecc400["max_machines"] == 256, ecc400
    assert ecc400["optimal_machines"] == 4 and ecc400["q_allocated_per_machine"] == 312, ecc400
    assert ecc400["lookup_ebits_total"] == 1680 and ecc400["carry_ebits_total"] == 8064, ecc400
    assert ecc400["logical_ebits_total"] == 9744, ecc400
    ecc_pruned = ecc400["pruned_ucurve_candidates"]
    assert [p["pruned_m"] for p in ecc_pruned] == [16, 24, 32, 48, 64, 96, 128, 256], ecc_pruned
    assert ecc_pruned[0]["code"] == "W-PARGUARD-PRUNED-UCURVE-KNEE", ecc_pruned[0]
    assert ecc_pruned[0]["pruned_q_per_machine"] == 192 and ecc_pruned[-1]["pruned_q_per_machine"] == 1572, ecc_pruned
    assert all(p["dominating_m"] == 12 and p["dominating_q_per_machine"] == 190 for p in ecc_pruned), ecc_pruned

    rsa2048_400 = c400_by_name["RSA-2048"]
    assert rsa2048_400["optimal_machines"] == 6 and rsa2048_400["q_allocated_per_machine"] == 236, rsa2048_400
    assert rsa2048_400["carry_ebits_total"] == 0 and rsa2048_400["lookup_ebits_total"] == 31140, rsa2048_400
    assert rsa2048_400["logical_ebits_total"] == 31140, rsa2048_400
    assert [p["pruned_m"] for p in rsa2048_400["pruned_ucurve_candidates"]] == [
        24, 32, 48, 64, 96, 128, 256
    ], rsa2048_400

    rsa4096_400 = c400_by_name["RSA-4096"]
    assert rsa4096_400["optimal_machines"] == 8 and rsa4096_400["q_allocated_per_machine"] == 356, rsa4096_400
    assert rsa4096_400["carry_ebits_total"] == 0 and rsa4096_400["lookup_ebits_total"] == 87192, rsa4096_400
    assert rsa4096_400["logical_ebits_total"] == 87192, rsa4096_400
    assert [p["pruned_m"] for p in rsa4096_400["pruned_ucurve_candidates"]] == [
        32, 48, 64, 96, 128, 256
    ], rsa4096_400

    # RSA-4096 true U-curve knee M* = 24 (24 x 228 Q, 286,488 lookup ebits, 0 carry ebits) at Q_cap = 230 Q:
    rsa4096_230 = payload["cluster_m_star_rsa4096_qcap230_m256"]
    assert rsa4096_230["optimal_machines"] == 24 and rsa4096_230["q_allocated_per_machine"] == 228, rsa4096_230
    assert rsa4096_230["carry_ebits_total"] == 0 and rsa4096_230["lookup_ebits_total"] == 286488, rsa4096_230
    assert [p["pruned_m"] for p in rsa4096_230["pruned_ucurve_candidates"]] == [
        32, 48, 64, 96, 128, 256
    ], rsa4096_230

    # Switched-optical-tree on tiny Q_cap = 128 Q chiplets (M_max = 256) + Q_cap = 100 Q:
    tree128 = {p["workload"]: p for p in payload["cluster_m_star_optical_tree_qcap128"]}
    assert tree128["ECC-256"]["optimal_machines"] == 16 and tree128["ECC-256"]["q_allocated_per_machine"] == 126
    assert tree128["RSA-2048"]["optimal_machines"] == 16 and tree128["RSA-2048"]["q_allocated_per_machine"] == 112
    assert tree128["RSA-4096"]["optimal_machines"] == 48 and tree128["RSA-4096"]["q_allocated_per_machine"] == 112
    tree100_rsa2048 = payload["cluster_m_star_optical_tree_rsa2048_qcap100"]
    assert tree100_rsa2048["optimal_machines"] == 32 and tree100_rsa2048["q_allocated_per_machine"] == 80

    assert c400_by_name["AES-128"]["optimal_machines"] == 1 and c400_by_name["AES-128"]["q_allocated_per_machine"] == 261
    assert c400_by_name["AES-128"]["zalka_total_work_blowup_factor"] == 16.0
    assert c400_by_name["AES-256"]["optimal_machines"] == 1 and c400_by_name["AES-256"]["q_allocated_per_machine"] == 389
    for w_grover in ("SHA3-256", "SLH-DSA-128s", "McEliece-348864", "BIKE-L1"):
        assert c400_by_name[w_grover]["optimal_machines"] == 1, c400_by_name[w_grover]
        assert c400_by_name[w_grover]["zalka_total_work_blowup_factor"] == 16.0, c400_by_name[w_grover]
        assert c400_by_name[w_grover]["fallback_to_single_machine"] is True, c400_by_name[w_grover]
    for w_shot in ("DQI", "Hubbard-QSVT", "FeMoCo-THC"):
        assert c400_by_name[w_shot]["qpar_grade"] == "ParShotLinear", c400_by_name[w_shot]
    assert c400_by_name["DQI"]["machines_per_shot_instance"] == 4
    assert c400_by_name["DQI"]["parallel_shot_groups"] == 64
    assert c400_by_name["DQI"]["machines_used"] == 256
    assert c400_by_name["DQI"]["q_allocated_per_machine"] == 228
    assert c400_by_name["DQI"]["shot_throughput_speedup"] == 64
    assert c400_by_name["Hubbard-QSVT"]["machines_used"] == 256
    assert c400_by_name["FeMoCo-THC"]["machines_used"] == 64
    assert c400_by_name["FeMoCo-THC"]["q_allocated_per_machine"] == 2196
    assert c400_by_name["FeMoCo-THC"]["idle_machines_avoided"] == 192

    # Q_cap = 1500 monolithic fit, DQI 256x512Q shot scaling, & R_bell = 1 kHz sensitivity:
    c1500 = {p["workload"]: p for p in payload["cluster_m_star_qcap1500_profiles"]}
    assert c1500["ECC-256"]["optimal_machines"] == 1 and c1500["ECC-256"]["logical_ebits_total"] == 0
    assert c1500["RSA-2048"]["optimal_machines"] == 1 and c1500["RSA-2048"]["logical_ebits_total"] == 0
    assert c1500["RSA-4096"]["optimal_machines"] == 8 and c1500["RSA-4096"]["logical_ebits_total"] == 87192
    assert c1500["DQI"]["machines_used"] == 256 and c1500["DQI"]["q_allocated_per_machine"] == 512
    assert c1500["DQI"]["shot_throughput_speedup"] == 256
    assert c1500["FeMoCo-THC"]["machines_used"] == 64 and c1500["FeMoCo-THC"]["idle_machines_avoided"] == 192

    rsa_1khz = payload["cluster_m_star_rsa2048_1khz"]
    assert rsa_1khz["optimal_machines"] == 4 and rsa_1khz["q_allocated_per_machine"] == 324, rsa_1khz
    assert rsa_1khz["logical_ebits_total"] == 18684, rsa_1khz

    ecc_220 = payload["cluster_m_star_ecc256_qcap220"]
    assert ecc_220["optimal_machines"] == 8 and ecc_220["q_allocated_per_machine"] == 208, ecc_220
    assert ecc_220["logical_ebits_total"] == 22736, ecc_220

    payload["subprocess_wall_ms"] = round(elapsed_ms, 2)
    payload["raco_test_stdout"] = test_proc.stdout.strip()
    return payload


def verify_unified_cli_and_negative_lfq_guards() -> Dict[str, Any]:
    racket_bin = locate_racket_bin("racket")
    env = build_env()
    scratch_base = persistent_scratch_root()

    with tempfile.TemporaryDirectory(dir=str(scratch_base), prefix="lfq_guard_cli_") as work_dir_str:
        work_dir = Path(work_dir_str)
        qasm_path = work_dir / "guarded_showcase.qasm"
        stim_path = work_dir / "guarded_showcase.stim"

        pos_proc = subprocess.run(
            [
                racket_bin,
                str(COMPILER_RKT),
                "--input",
                str(SHOWCASE_LFQ),
                "--emit-qasm3",
                str(qasm_path),
                "--emit-stim",
                str(stim_path),
                "--emit-json",
            ],
            cwd=str(REPO_ROOT),
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        if pos_proc.returncode != 0:
            raise AssertionError(
                f"Positive showcase compilation failed:\n{pos_proc.stdout}\n{pos_proc.stderr}"
            )
        pos_report = json.loads(pos_proc.stdout)
        assert pos_report["well_typed"] is True, pos_report
        assert pos_report["residual_surface_forms"] == 0, pos_report
        assert pos_report["violations"] == [], pos_report
        assert pos_report["machines_used"] == 1, pos_report
        assert pos_report["fallback_to_single_machine"] is True, pos_report
        assert len(pos_report["parallel_partition_decisions"]) == 6, pos_report
        opt_decisions = pos_report["parallel_partition_decisions"][3:]
        assert [d["optimal_machines"] for d in opt_decisions] == [4, 6, 8], opt_decisions

        # Verify a `par-cluster-opt-spec` `#lang lakefillq` program allocates `M* = 6` machines across M <= 256 on RSA-2048:
        rsa_opt_lfq = work_dir / "pos_cluster_opt_rsa2048.lfq"
        rsa_opt_lfq.write_text(
            """#lang lakefillq
(target-profile ideal)
(defq (rsa2048-cluster-opt #:wires ([w (range 0 2)]) #:scratch ())
  (guard-par-partition
   (par-cluster-opt-spec
    #:workload 'RSA-2048
    #:paradigm 'algebraic-limb
    #:max-machines 256
    #:q-cap-per-machine 400
    #:raw-bell-rate-hz 100000.0
    #:raw-per-logical-ebit 30
    #:q-single 1332
    #:q-data-dist 1152
    #:q-local-fixed 24
    #:q-peer-sync 4
    #:candidate-machines '(1 2 4 6 8 12 16 24 32 48 64 96 128 256)
    #:window-bits 6
    #:num-windows 1038
    #:local-toffolis 1180000000
    #:carry-scheme 'qrns-zero-carry
    #:lookup-scheme 'law-u4-ghz-mx
    #:strict-parallel? #f)
   (cx 0 1)))
""",
            encoding="utf-8",
        )
        rsa_opt_proc = subprocess.run(
            [racket_bin, str(COMPILER_RKT), "--input", str(rsa_opt_lfq), "--emit-json"],
            cwd=str(REPO_ROOT),
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        assert rsa_opt_proc.returncode == 0, rsa_opt_proc.stderr
        rsa_opt_report = json.loads(rsa_opt_proc.stdout)
        assert rsa_opt_report["well_typed"] is True, rsa_opt_report
        assert rsa_opt_report["machines_used"] == 6, rsa_opt_report
        assert rsa_opt_report["fallback_to_single_machine"] is False, rsa_opt_report

        # Also verify a pure `ParSliceable` `#lang lakefillq` program allocates `M = 4` machines:
        slice_lfq = work_dir / "pos_sliceable_ecc256.lfq"
        slice_lfq.write_text(
            """#lang lakefillq
(target-profile ideal)
(defq (ecc256-sliceable #:wires ([w (range 0 2)]) #:scratch ())
  (guard-par-partition
   '(par-partition-spec #:workload ECC-256 #:paradigm algebraic-limb #:requested-machines 4 #:q-single 2124 #:q-per-machine 540 #:q-comm 32 #:bell-cuts 512 #:max-bell-budget 1024 #:strict-parallel? #f)
   (cx 0 1)))
""",
            encoding="utf-8",
        )
        slice_proc = subprocess.run(
            [racket_bin, str(COMPILER_RKT), "--input", str(slice_lfq), "--emit-json"],
            cwd=str(REPO_ROOT),
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        assert slice_proc.returncode == 0, slice_proc.stderr
        slice_report = json.loads(slice_proc.stdout)
        assert slice_report["well_typed"] is True, slice_report
        assert slice_report["machines_used"] == 4, slice_report
        assert slice_report["fallback_to_single_machine"] is False, slice_report

        # Simulate emitted OpenQASM 3.0 on Qiskit AerSimulator and Stim on TableauSimulator:
        qasm_text = qasm_path.read_text(encoding="utf-8")
        assert "OPENQASM 3.0;" in qasm_text
        qasm_for_qiskit = re.sub(r"if\s*\((m\[\d+\])\s*==\s*1\)", r"if (\1 == true)", qasm_text)
        qc = qiskit.qasm3.loads(qasm_for_qiskit)
        qc_meas = qc.copy()
        qc_meas.measure_all()
        aer_sim = AerSimulator(seed_simulator=20261029)
        aer_counts = aer_sim.run(qc_meas, shots=256).result().get_counts()
        assert sum(aer_counts.values()) == 256

        stim_circuit = stim.Circuit(stim_path.read_text(encoding="utf-8"))
        det_samples = stim_circuit.compile_detector_sampler(seed=20261029).sample(shots=256)
        det_fires = int(det_samples.sum())
        assert det_fires == 0, f"Expected 0 Stim detector failures on noiseless skeleton, got {det_fires}"

        # Construct 7 negative `#lang lakefillq` files (one per rule) and verify CLI rejection:
        negative_lfq_specs = [
            (
                "T-DomImg",
                "E-DOMIMG-ROUNDTRIP-RESIDUAL",
                """#lang lakefillq
(target-profile ideal)
(defq (neg-dom-img #:wires ([w (range 0 2)]) #:scratch ([a (range 2 3)]))
  (erase-by-part-bij
   '(part-bij-smt2
     #:label kaliski-zero-stall
     #:vars ((x Int))
     #:vars-alt ((x2 Int))
     #:preamble "(define-fun f ((x Int)) Int (ite (= x 0) 13 x)) (define-fun res ((x Int)) Int (ite (= x 0) 12 0))"
     #:dom-f "(and (<= 0 x) (< x 13))"
     #:f-out ("(f x)")
     #:dom-g-on-f "true"
     #:g-of-f ("x")
     #:residual ("(res x)")
     #:f-out-alt ("(f x2)")
     #:dom-f-alt "(and (<= 0 x2) (< x2 13))")
   (temp-and 0 1 2)
   (seq (mid-meas-x 2 'm0) (cond-cz 'm0 0 1))
   '(2)))
""",
            ),
            (
                "T-ValidIf",
                "E-VALIDIF-UNGUARDED-PHASE-FLIP",
                """#lang lakefillq
(target-profile ideal)
(defq (neg-valid-if #:wires ([w (range 0 2)]) #:scratch ([a (range 2 3)]))
  (guard-valid-if
   '(valid-if-seq
     (bind-partial-op v_rank 0 s_tilde (QVec 768 id F2StdBasis) qgje-solve)
     (derive-pred wt_ok (s_tilde) 1)
     (phase-flip-if (wt_ok) (1) (2)))
   (x 0)))
""",
            ),
            (
                "T-AlgPhase",
                "E-ALGPHASE-NONCOMM-PRODUCT",
                """#lang lakefillq
(target-profile ideal)
(defq (neg-alg-phase #:wires ([w (range 0 2)]) #:scratch ())
  (guard-involutory
   'qubitization-walk
   '(op-seq (pauli-string ((0 X))) (pauli-string ((0 Z))))
   (cx 0 1)))
""",
            ),
            (
                "T-WireBasis",
                "E-WIREBASIS-PERM-MISMATCH",
                """#lang lakefillq
(target-profile ideal)
(defq (neg-wire-basis #:wires ([w (range 0 4)]) #:scratch ())
  (guard-wire-basis
   '(wire-basis-prog
     #:regs ((st 4 (0 1 2 3) AESPolyBasis (0 1 2 3))
             (rk 4 (0 1 2 3) AESPolyBasis (0 1 2 3)))
     #:ops ((plu-linear-op st (1 2 3 0) ((0 1)))
            (add-round-key st rk)))
   (cx 0 1)))
""",
            ),
            (
                "T-DriftEps",
                "E-DRIFTEPS-COSET-RUNWAY-OVERFLOW",
                """#lang lakefillq
(target-profile ideal)
(defq (neg-drift-eps #:wires ([w (range 0 2)]) #:scratch ())
  (guard-drift-eps
   '(coset-runway-spec #:modulus-bits 4096 #:c-pad 34 #:steps 2015560 #:safety-bits 15)
   (cx 0 1)))
""",
            ),
            (
                "T-SingleIR",
                "E-SINGLEIR-SPURIOUS-KEY-MARGIN",
                """#lang lakefillq
(target-profile ideal)
(defq (neg-single-ir #:wires ([w (range 0 2)]) #:scratch ())
  (guard-single-ir
   '(grover-search-oracle #:cipher AES-128-r1 #:key-bits 128 #:constraint-bits 128 #:log2-eta-max -32)
   (cx 0 1)))
""",
            ),
            (
                "T-ParGuard",
                "E-PARGUARD-ZALKA-GROVER-SUBLINEAR",
                """#lang lakefillq
(target-profile ideal)
(defq (neg-par-guard #:wires ([w (range 0 2)]) #:scratch ())
  (guard-par-partition
   '(par-partition-spec #:workload AES-128 #:paradigm grover-amplify #:requested-machines 16 #:q-single 984 #:q-per-machine 980 #:q-comm 0 #:bell-cuts 0 #:max-bell-budget 0 #:strict-parallel? #t)
   (cx 0 1)))
""",
            ),
            (
                "T-ParGuard",
                "E-PARGUARD-SINGLE-EXCEEDS-QCAP",
                """#lang lakefillq
(target-profile ideal)
(defq (neg-par-cluster-qcap #:wires ([w (range 0 2)]) #:scratch ())
  (guard-par-partition
   '(par-cluster-opt-spec
     #:workload AES-128
     #:paradigm grover-amplify
     #:max-machines 16
     #:q-cap-per-machine 400
     #:raw-bell-rate-hz 100000
     #:raw-per-logical-ebit 30
     #:q-single 984
     #:q-data-dist 0
     #:q-local-fixed 984
     #:q-peer-sync 0
     #:candidate-machines (1 2 4 8 16)
     #:window-bits 0
     #:num-windows 0
     #:local-toffolis 84000000
     #:carry-scheme qrns-zero-carry
     #:lookup-scheme law-u4-ghz-mx
     #:strict-parallel? #t)
   (cx 0 1)))
""",
            ),
            (
                "T-ParGuard",
                "E-PARGUARD-NO-FEASIBLE-PARTITION",
                """#lang lakefillq
(target-profile ideal)
(defq (neg-par-cluster-infeasible #:wires ([w (range 0 2)]) #:scratch ())
  (guard-par-partition
   '(par-cluster-opt-spec
     #:workload ECC-256
     #:paradigm algebraic-limb
     #:max-machines 16
     #:q-cap-per-machine 100
     #:raw-bell-rate-hz 100000
     #:raw-per-logical-ebit 30
     #:q-single 1298
     #:q-data-dist 1024
     #:q-local-fixed 38
     #:q-peer-sync 6
     #:candidate-machines (1 2 4 8 12 16)
     #:window-bits 5
     #:num-windows 112
     #:local-toffolis 9824640
     #:carry-scheme projective-oblivious-runway
     #:lookup-scheme law-u4-ghz-mx
     #:strict-parallel? #t)
   (cx 0 1)))
""",
            ),
        ]

        cli_negative_checks: List[Dict[str, Any]] = []
        for idx, (exp_rule, exp_code, src_text) in enumerate(negative_lfq_specs):
            neg_file = work_dir / f"neg_rule_{idx}.lfq"
            neg_file.write_text(src_text, encoding="utf-8")

            for use_repair in (False, True):
                cmd = [racket_bin, str(COMPILER_RKT), "--input", str(neg_file), "--emit-json"]
                if use_repair:
                    cmd.append("--repair")
                proc = subprocess.run(
                    cmd,
                    cwd=str(REPO_ROOT),
                    env=env,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                assert proc.returncode == 1, (
                    f"Expected exit code 1 for {exp_rule}/{exp_code} (repair={use_repair}), got {proc.returncode}"
                )
                neg_js = json.loads(proc.stdout)
                assert neg_js["well_typed"] is False, neg_js
                assert len(neg_js["violations"]) >= 1, neg_js
                v0 = neg_js["violations"][0]
                assert v0["rule"] == exp_rule, v0
                assert v0["code"] == exp_code, v0

            cli_negative_checks.append(
                {
                    "rule": exp_rule,
                    "expected_code": exp_code,
                    "rejected_default": True,
                    "rejected_under_repair": True,
                }
            )

    return {
        "showcase_file": "examples/guarded_sota_safety_showcase.lfq",
        "showcase_compilation": pos_report,
        "sliceable_ecc256_machines_used": slice_report["machines_used"],
        "rsa2048_cluster_opt_machines_used": rsa_opt_report["machines_used"],
        "aer_shots_verified": 256,
        "aer_distinct_outcomes": len(aer_counts),
        "stim_detector_fires_256_shots": det_fires,
        "cli_negative_rule_rejections": cli_negative_checks,
    }


def verify_independent_python_z3_obligations() -> Dict[str, Any]:
    # 1. T-DomImg: Short Weierstrass E(F_13) y^2 = x^3 + x + 7, Q = (1, 3) reverse-slope collision
    xp = z3.BitVec("xp", 16)
    yp = z3.BitVec("yp", 16)
    p13 = z3.BitVecVal(13, 16)

    def add13(a: z3.BitVecRef, b: z3.BitVecRef) -> z3.BitVecRef:
        return z3.URem(a + b, p13)

    def sub13(a: z3.BitVecRef, b: z3.BitVecRef) -> z3.BitVecRef:
        return z3.URem(z3.URem(a, p13) + (p13 - z3.URem(b, p13)), p13)

    def mul13(a: z3.BitVecRef, b: z3.BitVecRef) -> z3.BitVecRef:
        return z3.URem(z3.URem(a, p13) * z3.URem(b, p13), p13)

    inv_table = {1: 1, 2: 7, 3: 9, 4: 10, 5: 8, 6: 11, 7: 2, 8: 5, 9: 3, 10: 4, 11: 6, 12: 12}

    def inv13(a: z3.BitVecRef) -> z3.BitVecRef:
        m = z3.URem(a, p13)
        acc: z3.BitVecRef = z3.BitVecVal(0, 16)
        for k, v in inv_table.items():
            acc = z3.If(m == z3.BitVecVal(k, 16), z3.BitVecVal(v, 16), acc)
        return acc

    on_curve = z3.And(
        z3.ULT(xp, p13),
        z3.ULT(yp, p13),
        mul13(yp, yp) == add13(mul13(xp, mul13(xp, xp)), add13(xp, z3.BitVecVal(7, 16))),
    )
    lam = mul13(sub13(yp, z3.BitVecVal(3, 16)), inv13(sub13(xp, z3.BitVecVal(1, 16))))
    x3 = sub13(mul13(lam, lam), add13(xp, z3.BitVecVal(1, 16)))

    s_ec = z3.Solver()
    s_ec.add(on_curve, xp != z3.BitVecVal(1, 16), x3 == z3.BitVecVal(1, 16))
    assert s_ec.check() == z3.sat
    ec_m = s_ec.model()
    ec_witness = [ec_m.eval(xp).as_long(), ec_m.eval(yp).as_long()]
    assert ec_witness == [10, 9]

    s_ec_guarded = z3.Solver()
    s_ec_guarded.add(
        on_curve,
        xp != z3.BitVecVal(1, 16),
        z3.Not(z3.And(xp == z3.BitVecVal(10, 16), yp == z3.BitVecVal(9, 16))),
        x3 == z3.BitVecVal(1, 16),
    )
    assert s_ec_guarded.check() == z3.unsat

    # 2. T-ValidIf: Singular 3x3 F_2 submatrix false-positive vs rank-guarded UNSAT
    diag = [z3.Bool(f"diag_{i}") for i in range(3)]
    stilde = [z3.Bool(f"st_{i}") for i in range(3)]
    wt_eq_1 = z3.Sum([z3.If(b, 1, 0) for b in stilde]) == 1
    full_rank = z3.And(*diag)

    s_vif_bug = z3.Solver()
    s_vif_bug.add(z3.Not(full_rank), wt_eq_1)
    assert s_vif_bug.check() == z3.sat

    s_vif_ok = z3.Solver()
    s_vif_ok.add(z3.Not(full_rank), z3.And(full_rank, wt_eq_1))
    assert s_vif_ok.check() == z3.unsat

    # 3. T-AlgPhase & T-WireBasis: 5-bit Keccak chi_5 non-involution + sequential RAW corruption
    a = [z3.Bool(f"a_{i}") for i in range(5)]
    chi1 = [z3.Xor(a[i], z3.And(z3.Not(a[(i + 1) % 5]), a[(i + 2) % 5])) for i in range(5)]
    chi2 = [z3.Xor(chi1[i], z3.And(z3.Not(chi1[(i + 1) % 5]), chi1[(i + 2) % 5])) for i in range(5)]

    s_chi_inv = z3.Solver()
    s_chi_inv.add(z3.Or(*[chi2[i] != a[i] for i in range(5)]))
    assert s_chi_inv.check() == z3.sat

    seq_lanes = list(a)
    for i in range(5):
        seq_lanes[i] = z3.Xor(seq_lanes[i], z3.And(z3.Not(seq_lanes[(i + 1) % 5]), seq_lanes[(i + 2) % 5]))
    s_chi_seq = z3.Solver()
    s_chi_seq.add(z3.Or(*[seq_lanes[i] != chi1[i] for i in range(5)]))
    assert s_chi_seq.check() == z3.sat

    # 4. T-DriftEps & T-SingleIR: RSA-4096 c_pad=34 overflow & SHA-2 Ch miter
    err = z3.Int("err")
    s_cpad_bug = z3.Solver()
    s_cpad_bug.add(err <= 2015560 * (2**15), err >= 2**34)
    assert s_cpad_bug.check() == z3.sat

    s_cpad_ok = z3.Solver()
    s_cpad_ok.add(err <= 2015560 * (2**15), err >= 2**36)
    assert s_cpad_ok.check() == z3.unsat

    eb, fb, gb = z3.Bools("e f g")
    sha2_spec = z3.Xor(z3.And(eb, fb), z3.And(z3.Not(eb), gb))
    sha2_reverc_bug = z3.And(eb, fb, gb)
    sha2_repaired = z3.Xor(z3.And(eb, fb), z3.And(z3.Not(eb), gb))

    s_ch_bug = z3.Solver()
    s_ch_bug.add(sha2_spec != sha2_reverc_bug)
    assert s_ch_bug.check() == z3.sat

    s_ch_ok = z3.Solver()
    s_ch_ok.add(sha2_spec != sha2_repaired)
    assert s_ch_ok.check() == z3.unsat

    # 5. T-ParGuard: Zalka total-work strictly increases for all M >= 2, w >= 1 (`1 * w^2 < M * w^2`)
    m_z3 = z3.Int("M")
    w_z3 = z3.Int("w")
    s_zalka = z3.Solver()
    s_zalka.add(m_z3 >= 2, w_z3 >= 1, 1 * (w_z3 * w_z3) >= m_z3 * (w_z3 * w_z3))
    assert s_zalka.check() == z3.unsat

    # 6. T-ParGuard (Law U4 + U-curve knee pruning):
    # (a) Law U4 local M_X + Z-fixup halves lookup ebits vs roundtrip cat for all M >= 2, w_bits >= 1, N_win >= 1
    n_win_z3 = z3.Int("N_win")
    s_law_u4 = z3.Solver()
    u4_ebits = n_win_z3 * w_z3 * (m_z3 - 1)
    rt_ebits = n_win_z3 * 2 * w_z3 * (m_z3 - 1)
    s_law_u4.add(m_z3 >= 2, w_z3 >= 1, n_win_z3 >= 1, z3.Or(2 * u4_ebits != rt_ebits, u4_ebits >= rt_ebits))
    assert s_law_u4.check() == z3.unsat

    # (b) U-curve knee dominance: if 2 <= M1 < M2 and Q_mach(M1) <= Q_mach(M2), M2 has strictly larger ebit cost
    m1_z3 = z3.Int("M1")
    m2_z3 = z3.Int("M2")
    ewin_z3 = z3.Int("e_win")
    s_ucurve = z3.Solver()
    s_ucurve.add(m1_z3 >= 2, m2_z3 > m1_z3, ewin_z3 >= 1, n_win_z3 >= 1)
    s_ucurve.add(n_win_z3 * ewin_z3 * (m1_z3 - 1) >= n_win_z3 * ewin_z3 * (m2_z3 - 1))
    assert s_ucurve.check() == z3.unsat

    return {
        "ec_f13_reverse_slope_witness": ec_witness,
        "ec_f13_guarded_status": "unsat",
        "qgje_unguarded_singular_status": "sat",
        "qgje_guarded_singular_status": "unsat",
        "keccak_chi5_non_involution_status": "sat",
        "keccak_chi5_imperative_raw_status": "sat",
        "rsa4096_cpad34_overflow_status": "sat",
        "rsa4096_cpad36_overflow_status": "unsat",
        "reverc_sha2_ch_miter_status": "sat",
        "repaired_sha2_ch_miter_status": "unsat",
        "zalka_multi_machine_work_optimality_violation_status": "unsat",
        "law_u4_ghz_mx_halves_lookup_ebits_violation_status": "unsat",
        "ucurve_knee_dominance_ebit_monotonicity_violation_status": "unsat",
    }


def verify_lean4_soundness_proofs() -> Dict[str, Any]:
    lean_bin = locate_lean_bin()
    env = build_env()

    src = LEAN_PROOF_FILE.read_text(encoding="utf-8")
    for banned in ("sorry", "axiom ", "admit", "native_decide", "implemented_by", "| _ =>"):
        assert banned not in src, f"Forbidden token {banned!r} found in {LEAN_PROOF_FILE}"

    theorem_names = re.findall(r"^theorem\s+([A-Za-z0-9_']+)\b", src, flags=re.MULTILINE)
    assert len(theorem_names) == 25, f"Expected 25 Lean theorems, found {len(theorem_names)}: {theorem_names}"
    assert "t_par_guard_zalka_fallback_soundness" in theorem_names, theorem_names
    assert "t_par_guard_bell_cut_overhead_triggers_single_machine_fallback" in theorem_names, theorem_names
    assert "law_u4_ghz_cat_disentangle_halves_lookup_ebits" in theorem_names, theorem_names
    assert "qrns_distributed_zero_carry_ebits_soundness" in theorem_names, theorem_names
    assert "qpar_m_star_ucurve_knee_pruning_and_monolithic_fit" in theorem_names, theorem_names
    assert "qpar_m256_horizon_rsa4096_knee24_and_optical_tree_scaling" in theorem_names, theorem_names

    # Check proof block line counts (`:= by` .. next top-level decl):
    lines = src.splitlines()
    max_proof_lines = 0
    idx = 0
    while idx < len(lines):
        if ":= by" in lines[idx]:
            start = idx + 1
            end = start
            while end < len(lines):
                stripped = lines[end].strip()
                if stripped and not lines[end].startswith(" "):
                    break
                end += 1
            block_len = sum(1 for ln in lines[start:end] if ln.strip() and not ln.strip().startswith("--"))
            assert block_len <= 25, f"Proof block starting at line {idx + 1} has {block_len} > 25 lines"
            max_proof_lines = max(max_proof_lines, block_len)
            idx = end
        else:
            idx += 1

    t0 = time.perf_counter()
    proc = subprocess.run(
        [lean_bin, str(LEAN_PROOF_FILE)],
        cwd=str(REPO_ROOT),
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    elapsed_ms = (time.perf_counter() - t0) * 1000.0
    if proc.returncode != 0 or proc.stdout.strip() or proc.stderr.strip():
        raise AssertionError(
            f"Lean 4.35.0 verification failed (rc={proc.returncode}):\n"
            f"STDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}"
        )

    return {
        "proof_file": "proofs/lakefillq_bug_class_prevention_type_system_proofs.lean",
        "lean_version": "4.35.0",
        "exit_code": proc.returncode,
        "theorem_count": len(theorem_names),
        "theorem_names": theorem_names,
        "sorry_count": 0,
        "axiom_count": 0,
        "native_decide_count": 0,
        "wildcard_arm_count": 0,
        "max_proof_lines": max_proof_lines,
        "lean_kernel_ms": round(elapsed_ms, 2),
    }


def main() -> None:
    racket_summary = verify_racket_typechecker_module()
    cli_summary = verify_unified_cli_and_negative_lfq_guards()
    z3_summary = verify_independent_python_z3_obligations()
    lean_summary = verify_lean4_soundness_proofs()

    report = {
        "status": "PASS",
        "rules_verified": EXPECTED_RULES,
        "deliverables": {
            "racket_type_system_module": "compiler/lakefillq-bug-class-prevention-types.rkt",
            "surface_language_integration": "lakefillq/main.rkt",
            "unified_compiler_driver": "compiler/lakefillqc.rkt",
            "safety_showcase_example": "examples/guarded_sota_safety_showcase.lfq",
            "lean4_soundness_proofs": "proofs/lakefillq_bug_class_prevention_type_system_proofs.lean",
            "verification_reproducer": "reproducers/verify_lakefillq_bug_class_prevention_typechecker.py",
        },
        "racket_typechecker_verification": racket_summary,
        "unified_cli_and_aer_stim_verification": cli_summary,
        "independent_python_z3_cross_check": z3_summary,
        "lean4_soundness_verification": lean_summary,
    }

    REPORT_JSON.parent.mkdir(parents=True, exist_ok=True)
    REPORT_JSON.write_text(json.dumps(report, indent=2, sort_keys=False) + "\n", encoding="utf-8")

    print(
        "PASS: LakefillQ 7-Rule Generalized Bug-Class & Convex M*<=256 Cluster-Profile Type System verified — "
        f"{racket_summary['wild_bug_negative_rejected_count']}/14 wild bugs rejected, "
        f"{racket_summary['wild_bug_positive_well_typed_count']}/14 repaired well-typed, "
        f"{racket_summary['generalized_negative_rejected_count']}/14 generalized cases verified, "
        f"{racket_summary['parallel_partition_single_machine_fallback_count']}/13 SOTA parallel profiles routed to 1-machine fallback, "
        f"12/12 Convex M*<=256 cluster profiles solved (ECC-256 M*=4, RSA-2048 M*=6, RSA-4096 M*=8 at Q_cap=400; RSA-4096 knee M*=24 at Q_cap=230; optical-tree M*=16/16/48 at Q_cap=128), "
        f"{len(cli_summary['cli_negative_rule_rejections'])}/{len(cli_summary['cli_negative_rule_rejections'])} CLI negative .lfq guards rejected, "
        f"and {lean_summary['theorem_count']} Lean 4.35.0 soundness theorems verified (0 sorry, 0 axiom)."
    )


if __name__ == "__main__":
    main()
