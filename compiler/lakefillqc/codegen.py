"""
compiler/lakefillqc/codegen.py
==============================
Dynamic OpenQASM 3.0 and Stim Stabilizer Code Generation Backend for `lakefillqc`.

Lowers verified `#lang lakefillq` (`.lfq`) modules (including multi-round
`(for/fold ...)` cryptographic round uncomputation loops and higher-genus
Deligne-Lusztig Suzuki `S(8)/GF(8)` Early-MBU DQI circuits) to hardware-ready
OpenQASM 3.0 (`--emit-qasm3`) and Stim (`--emit-stim`).
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

from compiler.lakefillqc.typecheck import PERSISTENT_TMP, typecheck_lfq_module


def _annotate_qasm3_with_metadata(qasm_text: str, report: Dict[str, Any]) -> str:
    """
    Inject verified $k$-inductive `QSub` or Algebraic-Geometry DQI metadata comments
    immediately after the `OPENQASM 3.0;` header while preserving exact QASM 3.0 syntax.
    """
    extra_comments = []
    if "inductive_loop_qsub" in report:
        ind = report["inductive_loop_qsub"]
        extra_comments.append(
            f"// LakefillQ Symbolic k-Inductive QSub: status={ind['round_invariant_status']} "
            f"k={ind['k_induction_depth']} stage={ind.get('escalation_stage', 'k=1')} "
            f"z3_queries={ind['z3_queries']} "
            f"single_round_mbu_deg_le_2={ind['single_round_mbu_deg_le_2']}"
        )
    if "ag_dqi_curve_summary" in report:
        ag = report["ag_dqi_curve_summary"]
        extra_comments.append(
            f"// LakefillQ AG-DQI Curve: {ag['curve_family']} code={ag['code_parameters']} "
            f"genus={ag['genus_g']} N={ag['rational_points_N']} "
            f"width={ag['uncompressed_unitary_peak_qubits']}Q->{ag['early_mbu_peak_qubits']}Q "
            f"({ag['width_reduction_ratio']}x) T_reduction={ag['t_gate_reduction_ratio']}x"
        )
    if not extra_comments:
        return qasm_text

    lines = qasm_text.splitlines()
    if lines and lines[0].startswith("OPENQASM 3.0;"):
        return "\n".join([lines[0], *extra_comments, *lines[1:]]) + "\n"
    return "\n".join([*extra_comments, qasm_text])


def _annotate_stim_with_metadata(stim_text: str, report: Dict[str, Any]) -> str:
    """
    Inject verified $k$-inductive `QSub` or Algebraic-Geometry DQI `#` header comments
    into the emitted Stim circuit.
    """
    extra_comments = []
    if "inductive_loop_qsub" in report:
        ind = report["inductive_loop_qsub"]
        extra_comments.append(
            f"# LakefillQ Symbolic k-Inductive QSub: status={ind['round_invariant_status']} "
            f"k={ind['k_induction_depth']} stage={ind.get('escalation_stage', 'k=1')} "
            f"z3_queries={ind['z3_queries']} "
            f"single_round_mbu_deg_le_2={ind['single_round_mbu_deg_le_2']}"
        )
    if "ag_dqi_curve_summary" in report:
        ag = report["ag_dqi_curve_summary"]
        extra_comments.append(
            f"# LakefillQ AG-DQI Curve: {ag['curve_family']} code={ag['code_parameters']} "
            f"genus={ag['genus_g']} N={ag['rational_points_N']} "
            f"width={ag['uncompressed_unitary_peak_qubits']}Q->{ag['early_mbu_peak_qubits']}Q "
            f"({ag['width_reduction_ratio']}x) T_reduction={ag['t_gate_reduction_ratio']}x"
        )
    if not extra_comments:
        return stim_text
    return "\n".join([*extra_comments, stim_text])


def compile_and_emit(
    input_path: str | Path,
    target_override: Optional[str] = None,
    emit_json_path: Optional[str | Path] = None,
    emit_qasm3_path: Optional[str | Path] = None,
    emit_stim_path: Optional[str | Path] = None,
    diagnostics_human: bool = False,
    repair: bool = False,
    emit_repaired_lfq_path: Optional[str | Path] = None,
) -> Tuple[Dict[str, Any], str, str]:
    """
    Typecheck a `#lang lakefillq` module and lower it to OpenQASM 3.0 and Stim.
    Returns `(report, qasm3_text, stim_text)`.
    """
    PERSISTENT_TMP.mkdir(parents=True, exist_ok=True)
    in_path = Path(input_path).resolve()
    stem = in_path.stem
    pid = os.getpid()

    qasm_out = (
        Path(emit_qasm3_path).resolve()
        if emit_qasm3_path is not None
        else (PERSISTENT_TMP / f"lfqc_{stem}_{pid}.qasm")
    )
    stim_out = (
        Path(emit_stim_path).resolve()
        if emit_stim_path is not None
        else (PERSISTENT_TMP / f"lfqc_{stem}_{pid}.stim")
    )

    report = typecheck_lfq_module(
        input_path=in_path,
        target_override=target_override,
        emit_json_path=emit_json_path,
        emit_qasm3_path=qasm_out,
        emit_stim_path=stim_out,
        diagnostics_human=diagnostics_human,
        repair=repair,
        emit_repaired_lfq_path=emit_repaired_lfq_path,
    )

    qasm_text = qasm_out.read_text(encoding="utf-8") if qasm_out.exists() else ""
    stim_text = stim_out.read_text(encoding="utf-8") if stim_out.exists() else ""

    if qasm_text:
        qasm_text = _annotate_qasm3_with_metadata(qasm_text, report)
        if emit_qasm3_path is not None:
            qasm_out.write_text(qasm_text, encoding="utf-8")
    if stim_text:
        stim_text = _annotate_stim_with_metadata(stim_text, report)
        if emit_stim_path is not None:
            stim_out.write_text(stim_text, encoding="utf-8")

    if emit_qasm3_path is None:
        qasm_out.unlink(missing_ok=True)
    if emit_stim_path is None:
        stim_out.unlink(missing_ok=True)

    return report, qasm_text, stim_text
