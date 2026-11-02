"""
compiler/lakefillqc/typecheck.py
================================
Unified Typechecker & Symbolic `QSub` (`Laws U1-U4`) / `QPhysGrade` (`Phi1-Phi3`)
Inference Driver for `#lang lakefillq`.

Integrates:
  1. Surface `#lang lakefillq -> lambda_LFQ_kern -> RevIR -> MachineISA` compilation
     and multipass provenance diagnostics (`compiler/lakefillqc.rkt`).
  2. $O(1)$-Query Symbolic $k$-Inductive Loop-Invariant `QSub` Inference
     (`infer_for_fold_loop_sexpr` / `infer_inductive_loop_qsub` from
     `compiler/lakefillqc/infer_qsub.py`) for `(for/fold ...)` loops and
     round-iterated cryptographic sponges.
  3. Higher-Genus Algebraic-Geometry (Deligne-Lusztig Suzuki `S(8)/GF(8)`,
     Hermitian `H_2/GF(4)`, Lifted Bivariate `GF(4)^2`) Early-MBU DQI verification.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
from typing import Any, Dict, Optional

from compiler.lakefillqc.infer_qsub import (
    LoopRoundSpec,
    infer_for_fold_loop_sexpr,
    infer_inductive_loop_qsub,
    infer_loop_qsub_auto_escalate,
)
from compiler.lakefillqc.parser import (
    LFQParsedModule,
    parse_lfq_file,
    parse_lfq_source,
)

PERSISTENT_TMP = Path("/home/antigravity/toolchains/tmp")
REPO_ROOT = Path(__file__).resolve().parent.parent.parent
RACKET_DRIVER = REPO_ROOT / "compiler" / "lakefillqc.rkt"
RACKET_TOOLCHAIN_BIN = Path("/home/antigravity/toolchains/racket-p36t2/racket/bin/racket")
RACKET_BIN = str(RACKET_TOOLCHAIN_BIN) if RACKET_TOOLCHAIN_BIN.exists() else "racket"


def _build_env() -> Dict[str, str]:
    PERSISTENT_TMP.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env["TMPDIR"] = str(PERSISTENT_TMP)
    if RACKET_TOOLCHAIN_BIN.exists():
        env["PATH"] = f"{RACKET_TOOLCHAIN_BIN.parent}:{env.get('PATH', '')}"
    return env


def typecheck_lfq_module(
    input_path: str | Path,
    target_override: Optional[str] = None,
    emit_json_path: Optional[str | Path] = None,
    emit_qasm3_path: Optional[str | Path] = None,
    emit_stim_path: Optional[str | Path] = None,
    diagnostics_human: bool = False,
    repair: bool = False,
    emit_repaired_lfq_path: Optional[str | Path] = None,
) -> Dict[str, Any]:
    """
    Typecheck and compile a `#lang lakefillq` (`.lfq`) module, automatically
    running zero-flag $k$-inductive loop-invariant `QSub` inference ($k=1 \\to
    k=2 \\to k=R$ unrolled XAG/FRAIG escalation) on `(for/fold ...)` loops and
    attaching the verified summary fields (`k_induction_depth`, `escalation_stage`,
    `z3_queries`, `round_invariant_status`, `single_round_mbu_deg_le_2`) to the
    returned typecheck report.
    """
    in_path = Path(input_path).resolve()
    parsed: LFQParsedModule = parse_lfq_file(in_path)

    PERSISTENT_TMP.mkdir(parents=True, exist_ok=True)
    cmd = [
        RACKET_BIN,
        str(RACKET_DRIVER),
        "--input",
        str(in_path),
        "--emit-json",
    ]
    if target_override:
        cmd.extend(["--target", target_override])
    if emit_qasm3_path is not None:
        cmd.extend(["--emit-qasm3", str(Path(emit_qasm3_path).resolve())])
    if emit_stim_path is not None:
        cmd.extend(["--emit-stim", str(Path(emit_stim_path).resolve())])
    if diagnostics_human:
        cmd.append("--diagnostics-human")
    if repair:
        cmd.append("--repair")
    if emit_repaired_lfq_path is not None:
        cmd.extend(["--emit-repaired-lfq", str(Path(emit_repaired_lfq_path).resolve())])

    proc = subprocess.run(
        cmd,
        cwd=str(REPO_ROOT),
        env=_build_env(),
        capture_output=True,
        text=True,
        check=False,
    )

    stdout_txt = (proc.stdout or "").strip()
    report: Dict[str, Any]
    try:
        json_line = next(
            (ln for ln in reversed(stdout_txt.splitlines()) if ln.strip().startswith("{")),
            stdout_txt,
        )
        report = json.loads(json_line)
    except Exception:
        report = {
            "source_id": str(in_path),
            "target_profile": target_override or parsed.target_profile,
            "well_typed": False,
            "returncode": proc.returncode,
            "stdout": proc.stdout,
            "stderr": proc.stderr,
        }

    report["compiler_returncode"] = proc.returncode
    if proc.stderr:
        report["diagnostics_stderr"] = proc.stderr

    # Zero-flag automatic loop-invariant QSub inference (k=1 -> k=2 -> k=R escalation)
    if parsed.has_inductive_loop:
        loop_summary = infer_for_fold_loop_sexpr(parsed.raw_source)
        report["k_induction_depth"] = loop_summary["k_induction_depth"]
        report["escalation_stage"] = loop_summary.get("escalation_stage", "k=1")
        report["z3_queries"] = loop_summary["z3_queries"]
        report["round_invariant_status"] = loop_summary["round_invariant_status"]
        report["single_round_mbu_deg_le_2"] = loop_summary["single_round_mbu_deg_le_2"]
        report["inductive_loop_qsub"] = loop_summary
        report["well_typed"] = bool(report.get("well_typed", False)) and bool(
            loop_summary["well_typed"]
        )

    # Attach higher-genus / Suzuki S(8) / AG DQI curve metadata if present
    if parsed.ag_dqi_metadata is not None:
        report["ag_dqi_curve_summary"] = parsed.ag_dqi_metadata

    if emit_json_path is not None:
        Path(emit_json_path).resolve().write_text(
            json.dumps(report, indent=2),
            encoding="utf-8",
        )

    return report


def typecheck_for_fold_spec(
    spec_or_sexpr: LoopRoundSpec | str,
    num_rounds: Optional[int] = None,
    k_induction_depth: Optional[int] = None,
) -> Dict[str, Any]:
    """
    Directly run symbolic $k$-inductive `QSub` inference (defaulting to zero-flag
    $k=1 \\to k=2 \\to k=R$ automatic escalation when `k_induction_depth is None`)
    on a `LoopRoundSpec` or `#lang lakefillq` `(for/fold ...)` S-expression.
    """
    if isinstance(spec_or_sexpr, LoopRoundSpec):
        r_cnt = num_rounds if num_rounds is not None else 10
        if k_induction_depth is None:
            res = infer_loop_qsub_auto_escalate(spec_or_sexpr, num_rounds=r_cnt)
        else:
            res = infer_inductive_loop_qsub(
                spec_or_sexpr,
                num_rounds=r_cnt,
                k_depth=k_induction_depth,
            )
        deg_le_2 = (
            res.u1_scratch_clean_ok
            and res.u4_zero_taint_escape_ok
            and res.capability_invariant_ok
        )
        return {
            "well_typed": res.well_typed,
            "k_induction_depth": res.k_depth,
            "escalation_stage": res.escalation_stage,
            "z3_queries": res.z3_solver_calls,
            "round_invariant_status": (
                "VERIFIED_INDUCTIVE_INVARIANT"
                if res.well_typed
                else "VIOLATED_INDUCTIVE_INVARIANT"
            ),
            "single_round_mbu_deg_le_2": deg_le_2,
            "num_rounds": res.num_rounds,
            "result": res,
        }
    return infer_for_fold_loop_sexpr(
        spec_or_sexpr,
        num_rounds=num_rounds,
        k_depth=k_induction_depth,
    )
