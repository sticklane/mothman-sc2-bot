#!/usr/bin/env python3
"""
verify_lakefillq_multipass_diagnostics.py
=========================================
End-to-end verification of Multipass Type-Error Clarity, Chordal SSA Wire-Recycling
Inverse Resugaring, Macro Gensym Hygiene, Surface Basis Counterexample Witnesses,
and 3-Span Unified Judgment Provenance (`Gamma_in |- t : Q_e(A) -| Gamma_out`)
across `compiler/lakefillqc.rkt` and `ae/lakefillq_lint.py`.

Writes structured JSON verification artifact to:
  `reproducers/artifacts/lakefillq_multipass_diagnostics_report.json`
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
from typing import Any, Dict, List, Tuple


REPO_ROOT = Path(__file__).resolve().parent.parent
PERSISTENT_TMP = Path("/home/antigravity/toolchains/tmp")
if not PERSISTENT_TMP.parent.exists():
    PERSISTENT_TMP = REPO_ROOT / ".lakefillq_tmp"
PERSISTENT_TMP.mkdir(parents=True, exist_ok=True)
os.environ["TMPDIR"] = str(PERSISTENT_TMP)

RACKET_BIN = Path("/home/antigravity/toolchains/racket-p36t2/racket/bin/racket")
RACO_BIN = Path("/home/antigravity/toolchains/racket-p36t2/racket/bin/raco")
LEAN_BIN = Path("/home/antigravity/toolchains/lean4-p36t4/lean-4.35.0-linux/bin/lean")
LAKEFILLQC = REPO_ROOT / "compiler" / "lakefillqc.rkt"
ARTIFACT_PATH = REPO_ROOT / "reproducers" / "artifacts" / "lakefillq_multipass_diagnostics_report.json"

sys.path.insert(0, str(REPO_ROOT / "ae"))
import lakefillq_lint  # noqa: E402


def run_lakefillqc(
    lfq_file: Path,
    target: str = "ideal",
    extra_args: List[str] | None = None,
) -> Tuple[int, Dict[str, Any], str]:
    cmd = [
        str(RACKET_BIN),
        str(LAKEFILLQC),
        "--input",
        str(lfq_file),
        "--target",
        target,
        "--emit-json",
        "--diagnostics-human",
    ]
    if extra_args:
        cmd.extend(extra_args)
    proc = subprocess.run(
        cmd,
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
        check=False,
    )
    payload = json.loads(proc.stdout.strip()) if proc.stdout.strip() else {}
    return proc.returncode, payload, proc.stderr


def main() -> int:
    work_dir = PERSISTENT_TMP / "multipass_diagnostics_verify"
    work_dir.mkdir(parents=True, exist_ok=True)

    results: List[Dict[str, Any]] = []

    # -------------------------------------------------------------------------
    # Case 1: Chordal SSA Wire-Recycling Leak Attribution (`U1-EraseBy`)
    # -------------------------------------------------------------------------
    # Line numbers (1-indexed):
    #   1: #lang lakefillq
    #   2: (target-profile ideal)
    #   3: (defqfree (chordal-recycle-demo
    #   4:            #:wires ([a (range 0 2)])
    #   5:            #:scratch ([s1 '(2)] [s2 '(3)]))
    #   6:   (cx (first a) (first s1))
    #   7:   (cx (first a) (first s1))
    #   8:   (ccx (first a) (second a) (first s2)))
    case1_src = "\n".join([
        "#lang lakefillq",
        "(target-profile ideal)",
        "(defqfree (chordal-recycle-demo",
        "           #:wires ([a (range 0 2)])",
        "           #:scratch ([s1 '(2)] [s2 '(3)]))",
        "  (cx (first a) (first s1))",
        "  (cx (first a) (first s1))",
        "  (ccx (first a) (second a) (first s2)))",
        "",
    ])
    case1_path = work_dir / "case1_chordal_recycle_leak.lfq"
    case1_path.write_text(case1_src, encoding="utf-8")
    rc1, js1, stderr1 = run_lakefillqc(case1_path, target="ideal")
    v1 = (js1.get("violations") or [{}])[0]
    prov1 = v1.get("provenance_spans", {})
    c1_ok = (
        rc1 == 1
        and js1.get("well_typed") is False
        and js1.get("chordal_recycled_wires") == 1
        and v1.get("code") == "U1-EraseBy"
        and v1.get("surface_wire") == "s2[0]"
        and v1.get("chordal_recycled_from") == ["s1[0]"]
        and v1.get("resugared_anf") == "a[0]*a[1]"
        and (v1.get("resugared_witness") or {}).get("basis_ket") == "|a[0]=1, a[1]=1>"
        and prov1.get("origin_span", {}).get("line") == 3
        and prov1.get("mutating_span", {}).get("line") == 8
        and "s2[0]" in stderr1
        and "shared earlier with s1[0]" in stderr1
        and "(ccx (first a) (second a) (first s2))" in stderr1
    )
    results.append({
        "case": "U1_chordal_recycle_inverse_resugaring",
        "passed": c1_ok,
        "surface_wire": v1.get("surface_wire"),
        "chordal_recycled_from": v1.get("chordal_recycled_from"),
        "resugared_witness": v1.get("resugared_witness"),
        "origin_line": prov1.get("origin_span", {}).get("line"),
        "mutating_line": prov1.get("mutating_span", {}).get("line"),
    })
    assert c1_ok, f"Case 1 failed: {json.dumps(js1, indent=2)}\nSTDERR:\n{stderr1}"

    # -------------------------------------------------------------------------
    # Case 2: Macro Hygiene & Zero Compiler-Gensym Leakage (`U4-QTainted`)
    # -------------------------------------------------------------------------
    # `(mid-meas-x-cond-z (first anc) (first idle))` synthesizes `__u4_mx_0` via
    # `fresh-u4-meas-sym!`, applying `cond-z` to clean `idle[0]` instead of `ctl[0]`,
    # leaving uncancelled `__u4_mx_0` phase taint on `ctl[0]` across `(h (first ctl))`!
    case2_src = "\n".join([
        "#lang lakefillq",
        "(target-profile ideal)",
        "(defq (gensym-hygiene-u4",
        "       #:wires ([ctl '(0)] [idle '(1)])",
        "       #:scratch ([anc '(2)]))",
        "  (h (first ctl))",
        "  (cx (first ctl) (first anc))",
        "  (mid-meas-x-cond-z (first anc) (first idle))",
        "  (h (first ctl)))",
        "",
    ])
    case2_path = work_dir / "case2_gensym_hygiene_u4.lfq"
    case2_path.write_text(case2_src, encoding="utf-8")
    rc2, js2, stderr2 = run_lakefillqc(case2_path, target="ideal")
    v2 = (js2.get("violations") or [{}])[0]
    prov2 = v2.get("provenance_spans", {})
    res_msg2 = v2.get("resugared_message", "")
    c2_ok = (
        rc2 == 1
        and v2.get("code") == "U4-QTainted"
        and "__u4_mx_" not in res_msg2
        and "__u4_mx_" not in stderr2
        and "mid-meas-x on anc[0]" in res_msg2
        and "ctl[0]" in res_msg2
        and prov2.get("origin_span", {}).get("line") == 8
        and prov2.get("failure_span", {}).get("line") == 9
    )
    results.append({
        "case": "U4_gensym_hygiene_and_interference_spans",
        "passed": c2_ok,
        "resugared_message": res_msg2,
        "origin_line": prov2.get("origin_span", {}).get("line"),
        "failure_line": prov2.get("failure_span", {}).get("line"),
    })
    assert c2_ok, f"Case 2 failed: {json.dumps(js2, indent=2)}\nSTDERR:\n{stderr2}"

    # -------------------------------------------------------------------------
    # Case 3: Quotient Canonicalization 3-Span Provenance (`U2-Canonical`)
    # -------------------------------------------------------------------------
    case3_src = "\n".join([
        "#lang lakefillq",
        "(target-profile ideal)",
        "(defq (quotient-leak-demo",
        "       #:wires ([x '(0)] [qcarry '(1)])",
        "       #:scratch ()",
        "       #:domain `(quotient-vars ,qcarry))",
        "  (cx (first x) (first qcarry))",
        "  (h (first x)))",
        "",
    ])
    case3_path = work_dir / "case3_quotient_u2.lfq"
    case3_path.write_text(case3_src, encoding="utf-8")
    rc3, js3, stderr3 = run_lakefillqc(case3_path, target="ideal")
    v3 = (js3.get("violations") or [{}])[0]
    prov3 = v3.get("provenance_spans", {})
    c3_ok = (
        rc3 == 1
        and v3.get("code") == "U2-Canonical"
        and v3.get("surface_wire") == "qcarry[0]"
        and prov3.get("origin_span", {}).get("line") == 3
        and prov3.get("mutating_span", {}).get("line") == 7
        and prov3.get("failure_span", {}).get("line") == 8
    )
    results.append({
        "case": "U2_quotient_canonical_3span",
        "passed": c3_ok,
        "surface_wire": v3.get("surface_wire"),
        "origin_line": prov3.get("origin_span", {}).get("line"),
        "mutating_line": prov3.get("mutating_span", {}).get("line"),
        "failure_line": prov3.get("failure_span", {}).get("line"),
    })
    assert c3_ok, f"Case 3 failed: {json.dumps(js3, indent=2)}\nSTDERR:\n{stderr3}"

    # -------------------------------------------------------------------------
    # Case 4: Guarded Orthogonal Partition Drift (`U3-TotalOn`)
    # -------------------------------------------------------------------------
    case4_src = "\n".join([
        "#lang lakefillq",
        "(target-profile ideal)",
        "(defq (qmatch-drift-demo",
        "       #:wires ([flag '(0)] [acc '(1)])",
        "       #:scratch ())",
        "  (qmatch",
        "   ([(g-zero (first flag))",
        "     (x (first flag))",
        "     (x (first acc))]",
        "    [`(wire ,(first flag))",
        "     (x (first acc))])))",
        "",
    ])
    case4_path = work_dir / "case4_qmatch_drift_u3.lfq"
    case4_path.write_text(case4_src, encoding="utf-8")
    rc4, js4, stderr4 = run_lakefillqc(case4_path, target="ideal")
    v4 = (js4.get("violations") or [{}])[0]
    prov4 = v4.get("provenance_spans", {})
    c4_ok = (
        rc4 == 1
        and v4.get("code") == "U3-TotalOn"
        and prov4.get("origin_span", {}).get("line") == 6
        and prov4.get("mutating_span", {}).get("line") in (6, 8, 9)
        and prov4.get("failure_span", {}).get("line") == 6
    )
    results.append({
        "case": "U3_qmatch_guard_mutation_span",
        "passed": c4_ok,
        "origin_line": prov4.get("origin_span", {}).get("line"),
        "mutating_line": prov4.get("mutating_span", {}).get("line"),
    })
    assert c4_ok, f"Case 4 failed: {json.dumps(js4, indent=2)}\nSTDERR:\n{stderr4}"

    # -------------------------------------------------------------------------
    # Case 5: Physical Grade (`Phi3-FaultExponent`) Span + `--repair` Healing
    # -------------------------------------------------------------------------
    case5_src = "\n".join([
        "#lang lakefillq",
        "(target-profile bb-qldpc)",
        "(defq (dyadic-trunc-demo",
        "       #:wires ([data '(0)])",
        "       #:scratch ())",
        "  (rz-dyadic (first data) 60 #:precision 'float64 #:distance 7))",
        "",
    ])
    case5_path = work_dir / "case5_phi3_dyadic.lfq"
    case5_path.write_text(case5_src, encoding="utf-8")
    rc5, js5, stderr5 = run_lakefillqc(case5_path, target="bb-qldpc")
    rc5_rep, js5_rep, _ = run_lakefillqc(case5_path, target="bb-qldpc", extra_args=["--repair"])
    v5 = (js5.get("violations") or [{}])[0]
    prov5 = v5.get("provenance_spans", {})
    c5_ok = (
        rc5 == 1
        and v5.get("code") == "Phi3-FaultExponent"
        and v5.get("surface_wire") == "data[0]"
        and prov5.get("mutating_span", {}).get("line") == 6
        and rc5_rep == 0
        and js5_rep.get("well_typed") is True
    )
    results.append({
        "case": "Phi3_dyadic_span_and_repair",
        "passed": c5_ok,
        "surface_wire": v5.get("surface_wire"),
        "mutating_line": prov5.get("mutating_span", {}).get("line"),
        "repaired_well_typed": js5_rep.get("well_typed"),
    })
    assert c5_ok, f"Case 5 failed: {json.dumps(js5, indent=2)}\nSTDERR:\n{stderr5}"

    # -------------------------------------------------------------------------
    # Case 6: Surface Static Guard (`T-ParGuard`) Provenance Localization
    # -------------------------------------------------------------------------
    case6_src = "\n".join([
        "#lang lakefillq",
        "(target-profile ideal)",
        "(defq (parguard-strict-demo",
        "       #:wires ([w '(0)])",
        "       #:scratch ())",
        "  (guard-par-partition",
        "   (par-cluster-opt-spec #:workload 'Grover-Strict",
        "                         #:paradigm 'grover-amplify",
        "                         #:max-machines 256",
        "                         #:q-cap-per-machine 400",
        "                         #:q-single 3",
        "                         #:local-toffolis 8",
        "                         #:strict-parallel? #t)",
        "   (x (first w))))",
        "",
    ])
    case6_path = work_dir / "case6_surface_parguard.lfq"
    case6_path.write_text(case6_src, encoding="utf-8")
    rc6, js6, stderr6 = run_lakefillqc(case6_path, target="ideal")
    v6 = (js6.get("violations") or [{}])[0]
    prov6 = v6.get("provenance_spans", {})
    c6_ok = (
        rc6 == 1
        and v6.get("rule") == "T-ParGuard"
        and "QParGrade" in v6.get("unified_judgment_obligation", "")
        and prov6.get("origin_span", {}).get("line") == 3
        and prov6.get("mutating_span", {}).get("line") == 6
    )
    results.append({
        "case": "SurfaceGuard_TParGuard_provenance",
        "passed": c6_ok,
        "rule": v6.get("rule"),
        "origin_line": prov6.get("origin_span", {}).get("line"),
        "mutating_line": prov6.get("mutating_span", {}).get("line"),
    })
    assert c6_ok, f"Case 6 failed: {json.dumps(js6, indent=2)}\nSTDERR:\n{stderr6}"

    # -------------------------------------------------------------------------
    # Case 7: Python `OpenQASM 3.0` Linter (`ae/lakefillq_lint.py`) 3-Span Provenance
    # -------------------------------------------------------------------------
    qasm_leak = "\n".join([
        "OPENQASM 3.0;",
        'include "stdgates.inc";',
        "qubit[3] q;",
        "ccx q[0], q[1], q[2];",
        "",
    ])
    lint_rep = lakefillq_lint.lint_qasm_str(
        qasm_leak,
        spec={"input_wires": [0, 1], "ancilla_wires": [2]},
        name="qasm_phaseclean_demo.qasm",
    )
    d7 = lint_rep.diagnostics[0]
    prov7 = d7.details.get("provenance_spans", {})
    human7 = lint_rep.format_human_readable()
    c7_ok = (
        not lint_rep.well_typed
        and d7.rule == "T-PhaseClean"
        and "Gamma_out[ancilla = |0>, phase = 0]" in d7.details.get("unified_judgment_obligation", "")
        and prov7.get("mutating_span", {}).get("line") == 4
        and "ccx q[0], q[1], q[2];" in prov7.get("mutating_span", {}).get("surface_form", "")
        and "Unified Judgment:" in human7
        and "Provenance:" in human7
    )
    results.append({
        "case": "Python_OpenQASM3_Linter_3span_provenance",
        "passed": c7_ok,
        "rule": d7.rule,
        "mutating_line": prov7.get("mutating_span", {}).get("line"),
        "mutating_form": prov7.get("mutating_span", {}).get("surface_form"),
    })
    assert c7_ok, f"Case 7 failed: {lint_rep.to_json()}"

    # -------------------------------------------------------------------------
    # Case 8: Racket Unit Tests & Lean 4.35.0 Mechanization Gate
    # -------------------------------------------------------------------------
    raco_proc = subprocess.run(
        [str(RACO_BIN), "test", "compiler/lakefillq-multipass-diagnostics.rkt"],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
        check=False,
    )
    lean_proc = subprocess.run(
        [str(LEAN_BIN), "proofs/lakefillq_multipass_diagnostic_provenance_proofs.lean"],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
        check=False,
    )
    c8_ok = raco_proc.returncode == 0 and lean_proc.returncode == 0
    results.append({
        "case": "Raco_and_Lean4_mechanization_gate",
        "passed": c8_ok,
        "raco_exit": raco_proc.returncode,
        "lean_exit": lean_proc.returncode,
    })
    assert c8_ok, f"Case 8 failed: raco={raco_proc.stderr} lean={lean_proc.stderr}"

    report = {
        "status": "PASS",
        "overall_pass": all(r["passed"] for r in results),
        "unified_judgment": "Gamma_in |- t : Q_e(A) -| Gamma_out",
        "cases_verified": len(results),
        "zero_gensym_leakage": True,
        "chordal_ssa_inverse_resugaring_verified": True,
        "three_span_provenance_verified": True,
        "cases": results,
    }
    ARTIFACT_PATH.parent.mkdir(parents=True, exist_ok=True)
    ARTIFACT_PATH.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"[PASS] Multipass diagnostic provenance & resugaring verified ({len(results)}/{len(results)} cases).")
    print(f"       Artifact written to {ARTIFACT_PATH.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
