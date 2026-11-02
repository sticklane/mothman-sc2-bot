#!/usr/bin/env python3
"""
reproducers/verify_lakefillq_compiler_and_diagnostics.py
========================================================
End-to-End Verification Harness for the `lakefillqc` Compiler Package
(`compiler/lakefillqc/{cli,typecheck,codegen,parser,infer_qsub}.py`),
Multipass Provenance Diagnostics, and all 14 `#lang lakefillq` (`.lfq`)
Example Modules (including `examples/inductive_loop_aes_keccak.lfq` and
`examples/early_mbu_dqi_suzuki_s8_f8.lfq`).
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import time
from typing import Any, Dict, List

PERSISTENT_TMP = Path("/home/antigravity/toolchains/tmp")
PERSISTENT_TMP.mkdir(parents=True, exist_ok=True)
os.environ["TMPDIR"] = str(PERSISTENT_TMP)

REPO_ROOT = Path(__file__).resolve().parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from compiler.lakefillqc.cli import main as cli_main  # noqa: E402
from compiler.lakefillqc.codegen import compile_and_emit  # noqa: E402
from compiler.lakefillqc.infer_qsub import (  # noqa: E402
    infer_for_fold_loop_sexpr,
    test_inductive_loop_qsub_constant_queries_across_rounds,
    test_infer_for_fold_loop_sexpr,
    test_negative_buggy_loops_rejected_with_witnesses,
    test_rwire_semiring_and_loop_grade_scaling,
    test_zero_flag_auto_escalation_k1_k2_unrolled,
)
from compiler.lakefillqc.parser import parse_lfq_file  # noqa: E402
from compiler.lakefillqc.typecheck import typecheck_lfq_module  # noqa: E402


def verify_all_14_lfq_parsers() -> List[Dict[str, Any]]:
    examples_dir = REPO_ROOT / "examples"
    lfq_files = sorted(examples_dir.glob("*.lfq"))
    assert len(lfq_files) == 14, (
        f"Expected 14 .lfq modules in examples/, found {len(lfq_files)}: "
        f"{[p.name for p in lfq_files]}"
    )

    parsed_summaries: List[Dict[str, Any]] = []
    for fpath in lfq_files:
        parsed = parse_lfq_file(fpath)
        assert parsed.has_lang_header is True, f"Missing `#lang lakefillq` in {fpath.name}"
        assert len(parsed.circuit_names) >= 1, f"No `defq`/`defqfree` found in {fpath.name}"
        parsed_summaries.append(
            {
                "file": fpath.name,
                "target_profile": parsed.target_profile,
                "circuits": parsed.circuit_names,
                "has_inductive_loop": parsed.has_inductive_loop,
                "has_ag_dqi_metadata": parsed.ag_dqi_metadata is not None,
            }
        )
    return parsed_summaries


def verify_inductive_loop_and_suzuki_cli() -> Dict[str, Any]:
    work = PERSISTENT_TMP / f"verify_lfqc_cli_{os.getpid()}"
    work.mkdir(parents=True, exist_ok=True)

    # 1. Verify `examples/inductive_loop_aes_keccak.lfq` via `cli.py` (zero QSub CLI flags)
    aes_keccak_lfq = REPO_ROOT / "examples" / "inductive_loop_aes_keccak.lfq"
    aes_json = work / "inductive_loop_aes_keccak.json"
    aes_qasm = work / "inductive_loop_aes_keccak.qasm"
    aes_stim = work / "inductive_loop_aes_keccak.stim"

    rc_aes = cli_main(
        [
            "--input",
            str(aes_keccak_lfq),
            "--emit-json",
            str(aes_json),
            "--emit-qasm3",
            str(aes_qasm),
            "--emit-stim",
            str(aes_stim),
        ]
    )
    assert rc_aes == 0, f"CLI exited {rc_aes} on {aes_keccak_lfq}"
    rep_aes = json.loads(aes_json.read_text(encoding="utf-8"))
    qasm_aes = aes_qasm.read_text(encoding="utf-8")
    stim_aes = aes_stim.read_text(encoding="utf-8")

    assert rep_aes["well_typed"] is True
    assert rep_aes["residual_surface_forms"] == 0
    assert rep_aes["uncompute_ccx_count"] == 0
    assert rep_aes["k_induction_depth"] == 1
    assert rep_aes["escalation_stage"] == "k1_inductive"
    assert rep_aes["z3_queries"] == 5
    assert rep_aes["round_invariant_status"] == "VERIFIED_INDUCTIVE_INVARIANT"
    assert rep_aes["single_round_mbu_deg_le_2"] is True
    assert qasm_aes.startswith("OPENQASM 3.0;")
    assert "VERIFIED_INDUCTIVE_INVARIANT" in qasm_aes
    assert len(stim_aes.strip()) > 0

    # 2. Verify `examples/early_mbu_dqi_suzuki_s8_f8.lfq` via `cli.py`
    suzuki_lfq = REPO_ROOT / "examples" / "early_mbu_dqi_suzuki_s8_f8.lfq"
    suzuki_json = work / "early_mbu_dqi_suzuki_s8_f8.json"
    suzuki_qasm = work / "early_mbu_dqi_suzuki_s8_f8.qasm"
    suzuki_stim = work / "early_mbu_dqi_suzuki_s8_f8.stim"

    rc_suz = cli_main(
        [
            "--input",
            str(suzuki_lfq),
            "--emit-json",
            str(suzuki_json),
            "--emit-qasm3",
            str(suzuki_qasm),
            "--emit-stim",
            str(suzuki_stim),
        ]
    )
    assert rc_suz == 0, f"CLI exited {rc_suz} on {suzuki_lfq}"
    rep_suz = json.loads(suzuki_json.read_text(encoding="utf-8"))
    qasm_suz = suzuki_qasm.read_text(encoding="utf-8")
    stim_suz = suzuki_stim.read_text(encoding="utf-8")

    assert rep_suz["well_typed"] is True
    assert rep_suz["residual_surface_forms"] == 0
    assert rep_suz["uncompute_ccx_count"] == 0
    assert rep_suz["physical_qubits"] == 36
    ag_meta = rep_suz["ag_dqi_curve_summary"]
    assert ag_meta["genus_g"] == 14
    assert ag_meta["rational_points_N"] == 64
    assert ag_meta["reed_solomon_mds_ceiling"] == 9
    assert ag_meta["code_parameters"] == "[64, 52, 6]_{GF(8)}"
    assert ag_meta["uncompressed_unitary_peak_qubits"] == 228
    assert ag_meta["early_mbu_peak_qubits"] == 36
    assert ag_meta["width_reduction_ratio"] == 6.33
    assert ag_meta["t_gate_reduction_ratio"] == 3.33
    assert qasm_suz.startswith("OPENQASM 3.0;")
    assert "[64, 52, 6]_{GF(8)}" in qasm_suz
    assert len(stim_suz.strip()) > 0

    return {
        "inductive_loop_aes_keccak": {
            "well_typed": rep_aes["well_typed"],
            "physical_qubits": rep_aes["physical_qubits"],
            "forward_temp_and_count": rep_aes["forward_temp_and_count"],
            "mbu_erasure_count": rep_aes["mbu_erasure_count"],
            "uncompute_ccx_count": rep_aes["uncompute_ccx_count"],
            "k_induction_depth": rep_aes["k_induction_depth"],
            "escalation_stage": rep_aes["escalation_stage"],
            "z3_queries": rep_aes["z3_queries"],
            "round_invariant_status": rep_aes["round_invariant_status"],
            "single_round_mbu_deg_le_2": rep_aes["single_round_mbu_deg_le_2"],
        },
        "early_mbu_dqi_suzuki_s8_f8": {
            "well_typed": rep_suz["well_typed"],
            "physical_qubits": rep_suz["physical_qubits"],
            "forward_temp_and_count": rep_suz["forward_temp_and_count"],
            "mbu_erasure_count": rep_suz["mbu_erasure_count"],
            "uncompute_ccx_count": rep_suz["uncompute_ccx_count"],
            "ag_dqi_curve_summary": ag_meta,
        },
    }


def verify_multipass_diagnostics_subprocess() -> Dict[str, Any]:
    env = dict(os.environ)
    env["TMPDIR"] = str(PERSISTENT_TMP)
    diag_script = REPO_ROOT / "reproducers" / "verify_lakefillq_multipass_diagnostics.py"
    t0 = time.perf_counter()
    proc = subprocess.run(
        [sys.executable, str(diag_script)],
        cwd=str(REPO_ROOT),
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    elapsed_sec = time.perf_counter() - t0
    if proc.returncode != 0:
        raise RuntimeError(
            f"Multipass diagnostics verifier failed (exit {proc.returncode}):\n"
            f"{proc.stdout}\n{proc.stderr}"
        )
    return {
        "script": "reproducers/verify_lakefillq_multipass_diagnostics.py",
        "status": "PASS",
        "elapsed_sec": round(elapsed_sec, 2),
    }


def main() -> int:
    t0 = time.perf_counter()

    # 1. Run embedded unit tests in `compiler/lakefillqc/infer_qsub.py`
    test_rwire_semiring_and_loop_grade_scaling()
    test_inductive_loop_qsub_constant_queries_across_rounds()
    test_zero_flag_auto_escalation_k1_k2_unrolled()
    test_negative_buggy_loops_rejected_with_witnesses()
    test_infer_for_fold_loop_sexpr()

    # 2. Parse all 14 `#lang lakefillq` modules in `examples/`
    parsed_14 = verify_all_14_lfq_parsers()

    # 3. Compile & verify `inductive_loop_aes_keccak.lfq` and `early_mbu_dqi_suzuki_s8_f8.lfq` via `cli.py`
    cli_res = verify_inductive_loop_and_suzuki_cli()

    # 4. Run multipass provenance diagnostics verifier
    diag_res = verify_multipass_diagnostics_subprocess()

    total_sec = time.perf_counter() - t0
    ind = cli_res["inductive_loop_aes_keccak"]
    suz = cli_res["early_mbu_dqi_suzuki_s8_f8"]
    ag = suz["ag_dqi_curve_summary"]

    print("=" * 104)
    print("  LAKEFILLQ COMPILER CLI, SYMBOLIC k-INDUCTIVE `QSub`, SUZUKI DQI & DIAGNOSTICS VERIFICATION")
    print("=" * 104)
    print(f"  [PASS] Parsed all {len(parsed_14)}/14 `#lang lakefillq` modules in `examples/`")
    print(
        f"  [PASS] examples/inductive_loop_aes_keccak.lfq   : well_typed={ind['well_typed']} "
        f"phys_q={ind['physical_qubits']} temp_and={ind['forward_temp_and_count']} mbu={ind['mbu_erasure_count']} "
        f"k={ind['k_induction_depth']} z3_queries={ind['z3_queries']} "
        f"status={ind['round_invariant_status']} deg_le_2={ind['single_round_mbu_deg_le_2']}"
    )
    print(
        f"  [PASS] examples/early_mbu_dqi_suzuki_s8_f8.lfq  : well_typed={suz['well_typed']} "
        f"phys_q={suz['physical_qubits']} temp_and={suz['forward_temp_and_count']} mbu={suz['mbu_erasure_count']} "
        f"code={ag['code_parameters']} g={ag['genus_g']} N={ag['rational_points_N']} "
        f"width={ag['uncompressed_unitary_peak_qubits']}Q->{ag['early_mbu_peak_qubits']}Q ({ag['width_reduction_ratio']}x)"
    )
    print(
        f"  [PASS] Multipass Provenance & Resugaring Audit  : {diag_res['status']} ({diag_res['elapsed_sec']:.2f}s)"
    )
    print("-" * 104)
    print(f"  OVERALL COMPILER & DIAGNOSTICS STATUS : PASS (completed in {total_sec:.2f}s)")
    print("=" * 104)
    return 0


if __name__ == "__main__":
    sys.exit(main())
