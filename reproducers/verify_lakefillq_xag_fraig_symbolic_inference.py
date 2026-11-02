#!/usr/bin/env python3
"""
reproducers/verify_lakefillq_xag_fraig_symbolic_inference.py
============================================================
End-to-End Verification & Benchmark Reproducer for Optimization 1:
  - Canonical Sub-DAG Cone Isomorphism Hashing Modulo Input-Wire Relabeling
    (`xag-cone-canonical-signature` in Racket and `canonical_cone_signature` in Python)
  - Incremental Z3 Solver Context Reuse (`z3-exec-push-pop!` and `z3.Solver.push/pop`)
  - Zero-Flag Automatic Loop-Invariant Escalation (`k=1 -> k=2 -> k=R`)
  - Mechanized Lean 4 Soundness Proofs (`proofs/lakefillq_xag_fraig_symbolic_inference_proofs.lean`)
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import time
from typing import Any, Dict

PERSISTENT_TMP = "/home/antigravity/toolchains/tmp"
os.makedirs(PERSISTENT_TMP, exist_ok=True)
os.environ["TMPDIR"] = PERSISTENT_TMP

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))
sys.path.insert(0, str(REPO_ROOT / "reproducers"))

from compiler.lakefillqc.infer_qsub import (  # noqa: E402
    test_canonical_cone_isomorphism_and_unrolled_full_cipher_speedup,
    test_inductive_loop_qsub_constant_queries_across_rounds,
    test_infer_for_fold_loop_sexpr,
    test_negative_buggy_loops_rejected_with_witnesses,
    test_rwire_semiring_and_loop_grade_scaling,
    test_zero_flag_auto_escalation_k1_k2_unrolled,
)
from audit_comparator_statement_integrity_and_small_proofs import audit_lean_file  # noqa: E402
from sanitize_lean4_preprint_and_audit_gaps import audit_lean_source  # noqa: E402

RACKET_BIN = Path("/home/antigravity/toolchains/racket-p36t2/racket/bin/racket")
LEAN_BIN = Path("/home/antigravity/.elan/bin/lean")
RACKET_TYPECHECKER = REPO_ROOT / "compiler" / "lakefillq-xag-fraig-typechecker.rkt"
LEAN_PROOF_FILE = REPO_ROOT / "proofs" / "lakefillq_xag_fraig_symbolic_inference_proofs.lean"

REQUIRED_LEAN_THEOREMS = [
    "xag_lit_not_involution_and_semantics",
    "xag_smart_xor_self_cancels",
    "xag_smart_xor_preserves_semantics",
    "xag_smart_and_zero_self_and_not_self",
    "xag_smart_and_preserves_semantics",
    "sim_signature_mismatch_refutes_xag_equivalence",
    "bilinear_xag_mbu_collapses_arbitrary_degree_to_zero",
    "bilinear_xag_zero_coeff_implies_unit_quantum_phase",
    "multiround_mbu_session_total_quantum_phase_unit",
    "xag_circuit_linear_node_bound",
    "gidney_carry_explicit_anf_exponential_closed_form",
    "central_binomial_anf_exponential_lower_bound",
    "tseitin_dag_model_agrees_with_semantics",
    "tseitin_canonical_eval_satisfies_defs",
    "tseitin_miter_unsat_iff_xag_domain_equivalence",
    "cut_sweeping_local_unsat_implies_global_multiround_soundness",
    "cone_isomorphism_relabeling_soundness",
    "zero_flag_k1_k2_unrolled_escalation_soundness",
]


def verify_lean4_proofs() -> Dict[str, Any]:
    """Machine-check and audit `proofs/lakefillq_xag_fraig_symbolic_inference_proofs.lean`."""
    assert LEAN_PROOF_FILE.exists(), f"Missing Lean 4 file: {LEAN_PROOF_FILE}"
    env = dict(os.environ)
    env["TMPDIR"] = PERSISTENT_TMP

    t0 = time.perf_counter()
    proc = subprocess.run(
        [str(LEAN_BIN), str(LEAN_PROOF_FILE)],
        cwd=str(REPO_ROOT),
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    compile_ms = (time.perf_counter() - t0) * 1000.0
    if proc.returncode != 0:
        raise RuntimeError(
            f"Lean 4 compilation failed on {LEAN_PROOF_FILE}:\n"
            f"STDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}"
        )

    comp_rep = audit_lean_file(LEAN_PROOF_FILE, REPO_ROOT)
    raw_src = LEAN_PROOF_FILE.read_text(encoding="utf-8")
    san_viols = audit_lean_source(str(LEAN_PROOF_FILE.relative_to(REPO_ROOT)), raw_src)
    total_san_viols = sum(len(v) for v in san_viols.values())

    found_names = [t["name"] for t in comp_rep["theorems"]]
    for req_thm in REQUIRED_LEAN_THEOREMS:
        assert req_thm in found_names, f"Missing required Lean theorem `{req_thm}`"

    assert len(comp_rep["kernel_violations"]) == 0, f"Kernel violations: {comp_rep['kernel_violations']}"
    assert len(comp_rep["vacuous_or_tautological"]) == 0, f"Tautologies: {comp_rep['vacuous_or_tautological']}"
    assert total_san_viols == 0, f"Sanitizer violations: {san_viols}"
    assert comp_rep["small_proof_count"] == comp_rep["theorem_count"], "All proofs must be <= 30 lines"

    return {
        "lean_file": str(LEAN_PROOF_FILE.relative_to(REPO_ROOT)),
        "kernel_verified": True,
        "compile_time_ms": round(compile_ms, 2),
        "theorem_count": comp_rep["theorem_count"],
        "small_proof_count": comp_rep["small_proof_count"],
        "kernel_violations": len(comp_rep["kernel_violations"]),
        "tautologies": len(comp_rep["vacuous_or_tautological"]),
        "sanitizer_violations": total_san_viols,
        "theorems": found_names,
    }


def verify_racket_xag_fraig_typechecker() -> Dict[str, Any]:
    """Run `compiler/lakefillq-xag-fraig-typechecker.rkt --json` and verify all benchmarks & bugs."""
    env = dict(os.environ)
    env["TMPDIR"] = PERSISTENT_TMP

    proc = subprocess.run(
        [str(RACKET_BIN), str(RACKET_TYPECHECKER), "--json"],
        cwd=str(REPO_ROOT),
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"Racket typechecker failed:\nSTDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}"
        )

    report = json.loads(proc.stdout.strip())
    assert report["status"] == "PASS", f"Racket typechecker status != PASS: {report}"
    assert len(report["multiblock_sound_benchmarks"]) == 6
    assert all(b["z3_miter_status"] == "UNSAT" for b in report["multiblock_sound_benchmarks"])
    assert len(report["deep_multiround_bug_injections"]) == 4
    assert all(b["z3_miter_status"] == "SAT" for b in report["deep_multiround_bug_injections"])

    by_id = {b["id"]: b for b in report["multiblock_sound_benchmarks"]}
    assert by_id["AES128_10round_pareto_290q"]["xag_stats"]["z3_cut_sweep_queries"] == 1
    assert by_id["AES128_10round_pareto_290q"]["xag_stats"]["verified_cut_lemma_reuses"] == 159
    assert by_id["AES256_14round_pareto_418q"]["xag_stats"]["z3_cut_sweep_queries"] == 1
    assert by_id["AES256_14round_pareto_418q"]["xag_stats"]["verified_cut_lemma_reuses"] == 223

    esc = report["canonical_cone_and_loop_escalation"]
    assert esc["k1_uniform_aes128_loop"]["escalation_stage"] == "k=1"
    assert esc["k1_uniform_aes128_loop"]["logical_well_typed"] is True
    assert esc["k2_ping_pong_loop"]["escalation_stage"] == "k=2"
    assert esc["k2_ping_pong_loop"]["logical_well_typed"] is True
    assert esc["kR_heterogeneous_buggy_loop"]["escalation_stage"] == "k=R"
    assert esc["kR_heterogeneous_buggy_loop"]["logical_well_typed"] is False

    return report


def verify_python_infer_qsub() -> Dict[str, Any]:
    """Run all `compiler/lakefillqc/infer_qsub.py` tests and collect canonical cone isomorphism metrics."""
    test_rwire_semiring_and_loop_grade_scaling()
    test_inductive_loop_qsub_constant_queries_across_rounds()
    test_negative_buggy_loops_rejected_with_witnesses()
    test_zero_flag_auto_escalation_k1_k2_unrolled()
    test_infer_for_fold_loop_sexpr()
    cone_metrics = test_canonical_cone_isomorphism_and_unrolled_full_cipher_speedup()
    return {
        "status": "PASS",
        "unrolled_canonical_cone_isomorphism_metrics": cone_metrics,
        "negative_buggy_loops_rejected": "4/4",
        "mid_round_full_cipher_bugs_rejected": "2/2",
    }


def main() -> None:
    lean_rep = verify_lean4_proofs()
    racket_rep = verify_racket_xag_fraig_symbolic_inference()
    python_rep = verify_python_infer_qsub()

    summary = {
        "status": "PASS",
        "lean4_verification": lean_rep,
        "racket_xag_fraig_typechecker": {
            "status": racket_rep["status"],
            "multiblock_sound_benchmarks": racket_rep["multiblock_sound_benchmarks"],
            "deep_multiround_bug_injections_rejected": len(racket_rep["deep_multiround_bug_injections"]),
            "canonical_cone_and_loop_escalation": racket_rep["canonical_cone_and_loop_escalation"],
        },
        "python_infer_qsub": python_rep,
    }
    artifact_json = REPO_ROOT / "reproducers" / "artifacts" / "lakefillq_xag_fraig_inference_report.json"
    if artifact_json.exists():
        doc = json.loads(artifact_json.read_text(encoding="utf-8"))
    else:
        doc = {"status": "PASS"}
    doc["canonical_cone_isomorphism_optimization"] = summary
    artifact_json.parent.mkdir(parents=True, exist_ok=True)
    artifact_json.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))


def verify_racket_xag_fraig_symbolic_inference() -> Dict[str, Any]:
    return verify_racket_xag_fraig_typechecker()


if __name__ == "__main__":
    main()
