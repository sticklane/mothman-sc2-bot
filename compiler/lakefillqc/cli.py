#!/usr/bin/env python3
"""
compiler/lakefillqc/cli.py
==========================
Command-Line Interface (`lakefillqc`) for `#lang lakefillq` with Zero-Flag
Automatic $k$-Inductive Loop-Invariant `QSub` Inference ($k=1 \to k=2 \to k=R$
unrolled XAG/FRAIG escalation) and Higher-Genus Algebraic-Geometry /
Deligne-Lusztig Suzuki `S(8)` Early-MBU DQI Lowering to Dynamic OpenQASM 3.0
(`--emit-qasm3`) and Stim (`--emit-stim`).
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys
from typing import List, Optional

PERSISTENT_TMP = "/home/antigravity/toolchains/tmp"
os.makedirs(PERSISTENT_TMP, exist_ok=True)
os.environ["TMPDIR"] = PERSISTENT_TMP

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from compiler.lakefillqc.codegen import compile_and_emit  # noqa: E402
from compiler.lakefillqc.typecheck import typecheck_lfq_module  # noqa: E402


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="lakefillqc",
        description=(
            "LakefillQ Unified Compiler CLI (`#lang lakefillq -> RevIR -> MachineISA -> "
            "OpenQASM 3.0 / Stim`) with zero-flag automatic k-inductive loop-invariant QSub inference."
        ),
    )
    parser.add_argument(
        "--input",
        "-i",
        type=str,
        default=None,
        help="Path to input `#lang lakefillq` (`.lfq`) source file.",
    )
    parser.add_argument(
        "positional_input",
         nargs="?",
        default=None,
        help="Optional positional path to input `.lfq` source file.",
    )
    parser.add_argument(
        "--target",
        "-t",
        type=str,
        default=None,
        help="Hardware target profile override (`heron-r2`, `bluvstein-aod`, `bb-qldpc`, `ideal`).",
    )
    parser.add_argument(
        "--emit-json",
        type=str,
        default=None,
        help="Write JSON compilation & QSub/QPhysGrade typecheck report to path.",
    )
    parser.add_argument(
        "--emit-qasm3",
        type=str,
        default=None,
        help="Write dynamic OpenQASM 3.0 output to path.",
    )
    parser.add_argument(
        "--emit-stim",
        type=str,
        default=None,
        help="Write Stim stabilizer circuit output to path.",
    )
    parser.add_argument(
        "--diagnostics-human",
        action="store_true",
        help="Print human-readable multipass diagnostics and provenance trace.",
    )
    parser.add_argument(
        "--repair",
        action="store_true",
        help="Enable counterexample-guided physical repair pass.",
    )
    parser.add_argument(
        "--emit-repaired-lfq",
        type=str,
        default=None,
        help="Write repaired `#lang lakefillq` surface source to path.",
    )
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_arg_parser()
    args = parser.parse_args(argv)

    input_file = args.input or args.positional_input
    if not input_file:
        parser.error("Must specify an input `.lfq` file via `--input <path>` or positional argument.")

    if args.emit_qasm3 is not None or args.emit_stim is not None:
        report, _qasm_txt, _stim_txt = compile_and_emit(
            input_path=input_file,
            target_override=args.target,
            emit_json_path=args.emit_json,
            emit_qasm3_path=args.emit_qasm3,
            emit_stim_path=args.emit_stim,
            diagnostics_human=args.diagnostics_human,
            repair=args.repair,
            emit_repaired_lfq_path=args.emit_repaired_lfq,
        )
    else:
        report = typecheck_lfq_module(
            input_path=input_file,
            target_override=args.target,
            emit_json_path=args.emit_json,
            diagnostics_human=args.diagnostics_human,
            repair=args.repair,
            emit_repaired_lfq_path=args.emit_repaired_lfq,
        )

    if args.diagnostics_human and report.get("diagnostics_stdout"):
        print(report["diagnostics_stdout"], end="")
    elif args.emit_json is None and args.emit_qasm3 is None and args.emit_stim is None:
        print(json.dumps(report, indent=2))

    return 0 if report.get("well_typed", False) else 1


if __name__ == "__main__":
    sys.exit(main())
