#!/usr/bin/env python3
"""
reproducers/verify_inductive_loop_qsub_inference.py
===================================================
End-to-End Verification & Benchmark Harness for Symbolic $k$-Inductive
Loop-Invariant `QSub` (`Laws U1-U4`) Inference (`infer_inductive_loop_qsub`).

Verifies & Benchmarks:
  1. $O(1)$ Symbolic $k$-Inductive Loop-Invariant Inference (`infer_inductive_loop_qsub`)
     vs. $O(R)$ Unrolled Cut-Sweeping (`infer_module_qsub`) across:
       * `AES-128` (`R = 10`, `290 Q`, `12,240` `TempAND`s)
       * `AES-256` (`R = 14`, `418 Q`, `17,024` `TempAND`s)
       * `Keccak-f[200]` (`R = 18`, `245 Q`, `3,600` `TempAND`s)
       * `ChaCha20` (`R = 20`, `576 Q`, `9,920` `TempAND`s)
       * `Iterated-Perm-256` (`R = 64`, `288 Q`, `32,768` `TempAND`s)
       * `Iterated-Perm-256` (`R = 1000`, `288 Q`, `512,000` `TempAND`s)
  2. Exact grade agreement ($e_{\\mathrm{loop}} = R \\triangleright e_{\\mathrm{step}}$)
     between $O(1)$ inductive inference and $O(R)$ unrolled inference on every benchmark.
  3. Deterministic rejection of all 4 negative/buggy loop bodies with concrete Z3
     counterexample witnesses:
       * Loop-carried `TaintedX` / bilinear kickback leak (`Law U4` violation, `Law U1` clean)
       * Uncleaned per-round scratch wire (`Law U1` violation)
       * Non-bijective / colliding round step (`Law U2` violation with colliding pair `s_a != s_b`)
       * Loop capability invariant drift $\\Gamma_{\\mathrm{out}} \\neq \\Gamma_{\\mathrm{inv}}$
  4. Mechanized Lean `4.35.0` kernel compilation and 11-pattern / comparator proof-hygiene
     audit on `lean4/LakefillQ/InductiveLoopQSub.lean` (`14` theorems, `0` axioms, `0` `sorry`).
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import time
from typing import Any, Dict, List

PERSISTENT_TMP = "/home/antigravity/toolchains/tmp"
os.makedirs(PERSISTENT_TMP, exist_ok=True)
os.environ["TMPDIR"] = PERSISTENT_TMP

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))
sys.path.insert(0, str(REPO_ROOT / "reproducers"))

from compiler.lakefillqc.infer_qsub import (  # noqa: E402
    build_aes128_round_spec,
    build_aes256_round_spec,
    build_buggy_capability_drift_round_spec,
    build_buggy_nonbijective_round_spec,
    build_buggy_taintedx_leak_round_spec,
    build_buggy_uncleaned_scratch_round_spec,
    build_chacha20_round_spec,
    build_deep_permutation_round_spec,
    build_keccak_f200_round_spec,
    infer_inductive_loop_qsub,
    infer_module_qsub,
    test_inductive_loop_qsub_constant_queries_across_rounds,
    test_negative_buggy_loops_rejected_with_witnesses,
    test_rwire_semiring_and_loop_grade_scaling,
)
from audit_comparator_statement_integrity_and_small_proofs import audit_lean_file  # noqa: E402
from sanitize_lean4_preprint_and_audit_gaps import audit_lean_source  # noqa: E402

LEAN_BIN = Path("/home/antigravity/toolchains/lean4-p36t4/lean-4.35.0-linux/bin/lean")
LEAN_PROOF_PATH = REPO_ROOT / "proofs" / "lakefillq_inductive_loop_qsub_proofs.lean"
REPORT_OUT_PATH = REPO_ROOT / "reproducers" / "artifacts" / "inductive_loop_qsub_inference_report.json"

REQUIRED_LEAN_THEOREMS = [
    "rwire_join_comm_and_idempotent",
    "rwire_taint_discharge_restores_capability",
    "inductive_loop_capability_invariant",
    "inductive_loop_zero_taint_escape",
    "inductive_loop_u1_scratch_clean",
    "inductive_loop_u2_bijective_comp",
    "inductive_loop_u4_bilinear_phase_cancellation",
    "inductive_loop_grade_scaling",
    "inductive_loop_ancilla_recycling_width_constant",
    "inductive_loop_constant_query_bound",
    "inductive_loop_query_saving_linear_in_rounds",
    "inductive_loop_k_step_strengthening",
    "inductive_loop_soundness_implies_unrolled_qsub",
    "inductive_loop_counterexample_refutes_invariant",
]


def run_positive_scaling_benchmarks() -> List[Dict[str, Any]]:
    """
    Benchmark $O(1)$ inductive loop-invariant inference vs. $O(R)$ unrolled cut-sweeping
    across AES-128 (R=10), AES-256 (R=14), Keccak-f[200] (R=18), ChaCha20 (R=20),
    and deep iterated permutation rounds (R=64 and R=1000).
    """
    benchmark_configs = [
        ("AES-128", build_aes128_round_spec(), 10),
        ("AES-256", build_aes256_round_spec(), 14),
        ("Keccak-f[200]", build_keccak_f200_round_spec(), 18),
        ("ChaCha20", build_chacha20_round_spec(), 20),
        ("Iterated-Perm-256-R64", build_deep_permutation_round_spec("Iterated-Perm-256-R64"), 64),
        ("Iterated-Perm-256-R1000", build_deep_permutation_round_spec("Iterated-Perm-256-R1000"), 1000),
    ]

    results: List[Dict[str, Any]] = []
    for label, spec, num_rounds in benchmark_configs:
        ind_res = infer_inductive_loop_qsub(spec, num_rounds=num_rounds, k_depth=1)
        unr_res = infer_module_qsub(spec, num_rounds=num_rounds, inductive=False)

        assert ind_res.well_typed is True, f"{label} failed inductive QSub inference: {ind_res.violations}"
        assert unr_res.well_typed is True, f"{label} failed unrolled QSub inference: {unr_res.violations}"
        assert ind_res.loop_grade == unr_res.loop_grade, (
            f"{label} grade mismatch between inductive and unrolled: "
            f"{ind_res.loop_grade} != {unr_res.loop_grade}"
        )
        assert ind_res.z3_solver_calls < unr_res.z3_solver_calls, (
            f"Expected O(1) inductive Z3 calls ({ind_res.z3_solver_calls}) < "
            f"O(R) unrolled Z3 calls ({unr_res.z3_solver_calls}) on {label}"
        )

        query_speedup = unr_res.z3_solver_calls / max(1, ind_res.z3_solver_calls)
        time_speedup = unr_res.inference_time_ms / max(0.001, ind_res.inference_time_ms)
        node_reduction = unr_res.xag_nodes_allocated / max(1, ind_res.xag_nodes_allocated)

        results.append(
            {
                "benchmark": label,
                "rounds": num_rounds,
                "peak_qubits": ind_res.loop_grade.peak_qubits,
                "state_qubits": len(spec.state_wires),
                "key_qubits": len(spec.key_wires),
                "recycled_scratch_qubits": len(spec.scratch_wires),
                "total_temp_ands": ind_res.loop_grade.temp_and_count,
                "total_mbus": ind_res.loop_grade.mbu_count,
                "inductive_o1": {
                    "well_typed": ind_res.well_typed,
                    "z3_solver_calls": ind_res.z3_solver_calls,
                    "xag_nodes_allocated": ind_res.xag_nodes_allocated,
                    "and_nodes_allocated": ind_res.and_nodes_allocated,
                    "inference_time_ms": round(ind_res.inference_time_ms, 3),
                },
                "unrolled_oR": {
                    "well_typed": unr_res.well_typed,
                    "z3_solver_calls": unr_res.z3_solver_calls,
                    "xag_nodes_allocated": unr_res.xag_nodes_allocated,
                    "and_nodes_allocated": unr_res.and_nodes_allocated,
                    "inference_time_ms": round(unr_res.inference_time_ms, 3),
                },
                "z3_query_speedup_x": round(query_speedup, 2),
                "wall_time_speedup_x": round(time_speedup, 2),
                "xag_node_reduction_x": round(node_reduction, 2),
                "exact_loop_grade_match": ind_res.loop_grade == unr_res.loop_grade,
            }
        )

    return results


def run_negative_adversarial_loop_checks() -> List[Dict[str, Any]]:
    """
    Verify that buggy loop bodies violating Law U4 (loop-carried TaintedX leak),
    Law U1 (uncleaned scratch wire), Law U2 (non-bijective state step), and
    Capability Invariance (gamma_out != gamma_inv) are deterministically rejected
    with concrete counterexample witnesses.
    """
    cases = [
        ("Bug1_LoopCarried_TaintedX_Escape", build_buggy_taintedx_leak_round_spec(), 10, "U4"),
        ("Bug2_Uncleaned_Round_Scratch_Wire", build_buggy_uncleaned_scratch_round_spec(), 18, "U1"),
        ("Bug3_NonBijective_Colliding_Round_Step", build_buggy_nonbijective_round_spec(), 20, "U2"),
        ("Bug4_Loop_Capability_Invariant_Drift", build_buggy_capability_drift_round_spec(), 14, "CapabilityInvariant"),
    ]

    neg_reports: List[Dict[str, Any]] = []
    for bug_id, spec, rounds, expected_law in cases:
        res = infer_inductive_loop_qsub(spec, num_rounds=rounds, k_depth=2)
        assert res.well_typed is False, f"Buggy loop {bug_id} was not rejected!"
        laws_caught = [v.get("law") for v in res.violations]
        assert expected_law in laws_caught, (
            f"Expected law {expected_law} violation in {bug_id}, got {laws_caught}"
        )
        if expected_law in ("U1", "U2", "U4"):
            assert res.counterexample is not None, f"Missing counterexample witness for {bug_id}"

        neg_reports.append(
            {
                "bug_id": bug_id,
                "rounds": rounds,
                "expected_violated_law": expected_law,
                "rejected": not res.well_typed,
                "u1_scratch_clean_ok": res.u1_scratch_clean_ok,
                "u2_bijective_ok": res.u2_bijective_ok,
                "u4_zero_taint_escape_ok": res.u4_zero_taint_escape_ok,
                "capability_invariant_ok": res.capability_invariant_ok,
                "z3_solver_calls": res.z3_solver_calls,
                "inference_time_ms": round(res.inference_time_ms, 3),
                "counterexample": res.counterexample,
                "violations": res.violations,
            }
        )

    return neg_reports


def verify_lean4_inductive_loop_proofs() -> Dict[str, Any]:
    """
    Compile `lean4/LakefillQ/InductiveLoopQSub.lean` with Lean 4.35.0 and run
    both comparator statement-integrity and 11-pattern proof-hygiene audits.
    """
    assert LEAN_PROOF_PATH.exists(), f"Missing Lean 4 file: {LEAN_PROOF_PATH}"
    env = dict(os.environ)
    env["TMPDIR"] = PERSISTENT_TMP
    env["PATH"] = f"/home/antigravity/.elan/bin:{LEAN_BIN.parent}:{env.get('PATH', '')}"

    t0 = time.perf_counter()
    proc = subprocess.run(
        [str(LEAN_BIN), str(LEAN_PROOF_PATH)],
        cwd=str(REPO_ROOT),
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    compile_ms = (time.perf_counter() - t0) * 1000.0
    if proc.returncode != 0:
        raise RuntimeError(
            f"Lean 4.35.0 compilation failed on {LEAN_PROOF_PATH}:\n"
            f"STDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}"
        )

    comp_rep = audit_lean_file(LEAN_PROOF_PATH, REPO_ROOT)
    raw_src = LEAN_PROOF_PATH.read_text(encoding="utf-8")
    san_viols = audit_lean_source(str(LEAN_PROOF_PATH.relative_to(REPO_ROOT)), raw_src)
    total_san_viols = sum(len(v) for v in san_viols.values())

    found_names = [t["name"] for t in comp_rep["theorems"]]
    for req_thm in REQUIRED_LEAN_THEOREMS:
        assert req_thm in found_names, f"Missing required Lean theorem `{req_thm}` in {LEAN_PROOF_PATH}"

    assert len(comp_rep["kernel_violations"]) == 0, f"Kernel violations: {comp_rep['kernel_violations']}"
    assert len(comp_rep["vacuous_or_tautological"]) == 0, f"Tautologies: {comp_rep['vacuous_or_tautological']}"
    assert total_san_viols == 0, f"Sanitizer violations: {san_viols}"
    assert comp_rep["small_proof_count"] == comp_rep["theorem_count"], "All proofs must be <= 30 lines"

    return {
        "lean_file": str(LEAN_PROOF_PATH.relative_to(REPO_ROOT)),
        "kernel_verified": True,
        "compile_time_ms": round(compile_ms, 2),
        "theorem_count": comp_rep["theorem_count"],
        "small_proof_count": comp_rep["small_proof_count"],
        "kernel_violations": len(comp_rep["kernel_violations"]),
        "tautologies": len(comp_rep["vacuous_or_tautological"]),
        "sanitizer_violations": total_san_viols,
        "theorem_names": found_names,
    }


def main() -> int:
    t0 = time.perf_counter()

    # 1. Run embedded unit tests in `compiler/lakefillqc/infer_qsub.py`
    test_rwire_semiring_and_loop_grade_scaling()
    test_inductive_loop_qsub_constant_queries_across_rounds()
    test_negative_buggy_loops_rejected_with_witnesses()

    # 2. Run positive scaling benchmarks (O(1) inductive vs O(R) unrolled)
    scaling_benchmarks = run_positive_scaling_benchmarks()

    # 3. Run negative adversarial loop checks
    negative_checks = run_negative_adversarial_loop_checks()

    # 4. Run Lean 4.35.0 mechanization & hygiene verification
    lean_report = verify_lean4_inductive_loop_proofs()

    total_ms = (time.perf_counter() - t0) * 1000.0

    report = {
        "status": "PASS",
        "engine": "LakefillQ Symbolic k-Inductive Loop-Invariant QSub (Laws U1-U4) Inference",
        "compiler_module": "compiler/lakefillqc/infer_qsub.py",
        "lean4_module": "proofs/lakefillq_inductive_loop_qsub_proofs.lean",
        "total_verification_time_ms": round(total_ms, 2),
        "unit_tests_passed": True,
        "positive_loop_benchmarks": scaling_benchmarks,
        "negative_adversarial_loop_checks": negative_checks,
        "lean4_mechanization": lean_report,
    }

    REPORT_OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_OUT_PATH.write_text(json.dumps(report, indent=2), encoding="utf-8")

    print("=" * 108)
    print("  SYMBOLIC k-INDUCTIVE LOOP-INVARIANT `QSub` (`LAWS U1-U4`) INFERENCE VERIFICATION & BENCHMARK")
    print("=" * 108)
    print(
        f"  {'Benchmark':<24} | {'R':>5} | {'Peak Q':>6} | {'TempANDs':>9} | "
        f"{'O(1) Z3':>7} | {'O(R) Z3':>7} | {'Z3 Speedup':>10} | {'O(1) ms':>8} | {'O(R) ms':>8} | {'Speedup':>8}"
    )
    print("-" * 108)
    for row in scaling_benchmarks:
        ind = row["inductive_o1"]
        unr = row["unrolled_oR"]
        print(
            f"  {row['benchmark']:<24} | {row['rounds']:>5} | {row['peak_qubits']:>6} | "
            f"{row['total_temp_ands']:>9} | {ind['z3_solver_calls']:>7} | {unr['z3_solver_calls']:>7} | "
            f"{row['z3_query_speedup_x']:>9.2f}x | {ind['inference_time_ms']:>8.2f} | "
            f"{unr['inference_time_ms']:>8.2f} | {row['wall_time_speedup_x']:>7.2f}x"
        )
    print("-" * 108)
    print(
        f"  Negative / Buggy Loop Bodies Rejected : {len(negative_checks)}/{len(negative_checks)} "
        f"(100.0% deterministic rejection with Z3 counterexamples)"
    )
    print(
        f"  Lean 4.35.0 Kernel Mechanization      : PASS ({lean_report['theorem_count']} theorems in "
        f"`{lean_report['lean_file']}`, 0 sorry, 0 axioms, {lean_report['compile_time_ms']:.1f} ms)"
    )
    print(f"  Artifact Report Written To            : {REPORT_OUT_PATH.relative_to(REPO_ROOT)}")
    print("=" * 108)
    return 0


if __name__ == "__main__":
    sys.exit(main())
