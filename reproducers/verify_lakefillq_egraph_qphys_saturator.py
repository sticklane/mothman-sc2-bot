#!/usr/bin/env python3
"""
End-to-End Multi-Simulator & Lean 4 Verifier for LakefillQ ZX E-Graph Saturation
and Optimization 3: RM(3, n) Symmetric 3-Tensor TODD Phase-Polynomial Decomposition
+ AutoCCZ Factory Packing (`compiler/lakefillq-egraph-saturator.rkt`).

Verifies:
  1. Machine-checked Lean 4 soundness & QPhysGrade monotonicity proofs in
     `proofs/lakefillq_egraph_qphys_saturation_proofs.lean` (`0 sorry`, `0 axiom`,
     passing structural proof-hygiene audit, including Theorem 9
     `f2_cubic_todd_rank_reduction_and_autocc_pair_fusion_soundness` and Theorem 10
     `todd_autocc_phase_poly_qphys_grade_monotonicity`).
  2. Full baseline regression check on the Racket e-graph saturator
     (`compiler/lakefillq-egraph-saturator.rkt --json`) across all 6 existing
     benchmarks and external 4K cryo-CMOS / 300K coax / software MWPM pacing profiles.
  3. Exact unitary matrix simulation (`||U_pre - U_post||_max < 1e-12`), PyZX
     tensor/diagram equivalence (`zx.compare_tensors(..., preserve_scalar=True)`),
     and Stim stabilizer frame verification across all 3 Phase-Clean (`U2`/`U4`-certified)
     `focus-zipper` cones:
       - `bp-aes-sbox-phase-cone` (Boyar-Peralta AES S-box GF(2^4) nonlinear cone, 7q)
       - `keccak-f200-chi-row-cone` (Keccak-f[200] chi-row 5-bit S-box slice, 8q)
       - `suzuki-hermitian-dqi-syndrome-cone` (Suzuki/Hermitian AG DQI syndrome block, 8q)
     confirming 18-28% active T-count reduction and 25-50% T-depth reduction at
     0 additional peak logical qubits.
"""

from __future__ import annotations

import json
import math
import os
from pathlib import Path
import subprocess
import sys
from typing import Any, Dict, List

PERSISTENT_TMP = "/home/antigravity/toolchains/tmp"
os.makedirs(PERSISTENT_TMP, exist_ok=True)
os.environ["TMPDIR"] = PERSISTENT_TMP

import numpy as np
import pyzx as zx
from qiskit import QuantumCircuit
from qiskit.quantum_info import Operator
import stim

REPO_ROOT = Path(__file__).resolve().parent.parent
RACKET_BIN = Path("/home/antigravity/toolchains/racket-p36t2/racket/bin/racket")
LEAN_BIN = Path("/home/antigravity/.elan/bin/lean")
SATURATOR_RKT = REPO_ROOT / "compiler" / "lakefillq-egraph-saturator.rkt"
PROOF_LEAN = REPO_ROOT / "proofs" / "lakefillq_egraph_qphys_saturation_proofs.lean"
REPORT_JSON = (
    REPO_ROOT
    / "benchmarks"
    / "results"
    / "lakefillq_egraph_todd_autocc_verification.json"
)

sys.path.insert(0, str(REPO_ROOT / "reproducers"))
from audit_comparator_statement_integrity_and_small_proofs import (  # noqa: E402
    audit_lean_file,
)
from sanitize_lean4_preprint_and_audit_gaps import audit_lean_source  # noqa: E402


def build_qiskit_circuit_from_isa(
    num_qubits: int, isa_ops: List[List[Any]]
) -> QuantumCircuit:
    """Builds an exact Qiskit QuantumCircuit from LakefillQ MachineISA instructions."""
    qc = QuantumCircuit(num_qubits)
    for ins in isa_ops:
        op = ins[0]
        if op == "x":
            qc.x(int(ins[1]))
        elif op == "z":
            qc.z(int(ins[1]))
        elif op == "h":
            qc.h(int(ins[1]))
        elif op == "s":
            qc.s(int(ins[1]))
        elif op == "sdg":
            qc.sdg(int(ins[1]))
        elif op == "t":
            qc.t(int(ins[1]))
        elif op == "tdg":
            qc.tdg(int(ins[1]))
        elif op == "ry_pi4":
            qc.ry(math.pi / 4.0, int(ins[1]))
        elif op == "ry_mpi4":
            qc.ry(-math.pi / 4.0, int(ins[1]))
        elif op == "cx":
            qc.cx(int(ins[1]), int(ins[2]))
        elif op == "cz":
            qc.cz(int(ins[1]), int(ins[2]))
        elif op in (
            "aod_move",
            "spectator_wait",
            "plaquette_order_tag",
            "tree_schedule_tag",
            "layer_barrier",
            "qroam_meta",
        ):
            continue
        else:
            raise ValueError(f"Unsupported unitary ISA instruction: {ins}")
    return qc


def build_pyzx_circuit_from_isa(
    num_qubits: int, isa_ops: List[List[Any]]
) -> zx.Circuit:
    """Builds a PyZX Circuit from Clifford+T MachineISA instructions."""
    c = zx.Circuit(num_qubits)
    for ins in isa_ops:
        op = ins[0]
        if op == "x":
            c.add_gate("NOT", int(ins[1]))
        elif op == "z":
            c.add_gate("Z", int(ins[1]))
        elif op == "h":
            c.add_gate("HAD", int(ins[1]))
        elif op == "s":
            c.add_gate("S", int(ins[1]))
        elif op == "sdg":
            c.add_gate("S", int(ins[1]), adjoint=True)
        elif op == "t":
            c.add_gate("T", int(ins[1]))
        elif op == "tdg":
            c.add_gate("T", int(ins[1]), adjoint=True)
        elif op == "cx":
            c.add_gate("CNOT", int(ins[1]), int(ins[2]))
        elif op == "cz":
            c.add_gate("CZ", int(ins[1]), int(ins[2]))
        else:
            raise ValueError(f"Unsupported PyZX ISA instruction: {ins}")
    return c


def verify_stim_cnot_frame_equivalence(
    num_qubits: int, pre_isa: List[List[Any]], post_isa: List[List[Any]]
) -> Dict[str, Any]:
    """Verifies via Stim Tableau simulation that the CNOT linear frame of pre_isa and post_isa match."""
    sim_pre = stim.TableauSimulator()
    sim_post = stim.TableauSimulator()
    # Apply all CNOT gates in pre_isa vs post_isa to verify the linear GF(2) frame
    # on computational basis states |e_i> (since diagonal Z-phase gates commute with Z-basis bitstrings).
    c_pre = stim.Circuit()
    c_post = stim.Circuit()
    for ins in pre_isa:
        if ins[0] == "cx":
            c_pre.append("CX", [int(ins[1]), int(ins[2])])
    for ins in post_isa:
        if ins[0] == "cx":
            c_post.append("CX", [int(ins[1]), int(ins[2])])
    sim_pre.do_circuit(c_pre)
    sim_post.do_circuit(c_post)
    tab_pre = sim_pre.current_inverse_tableau() ** -1
    tab_post = sim_post.current_inverse_tableau() ** -1

    # Check computational basis action on all 2^n bitstrings via Z-observables
    basis_matches = 0
    for x in range(1 << num_qubits):
        s_pre = stim.TableauSimulator()
        s_post = stim.TableauSimulator()
        for q in range(num_qubits):
            if (x >> q) & 1:
                s_pre.x(q)
                s_post.x(q)
        s_pre.do_circuit(c_pre)
        s_post.do_circuit(c_post)
        out_pre = [bool(s_pre.measure(q)) for q in range(num_qubits)]
        out_post = [bool(s_post.measure(q)) for q in range(num_qubits)]
        if out_pre != out_post:
            raise AssertionError(
                f"Stim GF(2) frame mismatch on input {x}: pre={out_pre}, post={out_post}"
            )
        basis_matches += 1

    return {
        "stim_tableau_z_outputs_equal": bool(
            all(
                tab_pre.z_output(q) == tab_post.z_output(q)
                for q in range(num_qubits)
            )
        ),
        "basis_states_verified": basis_matches,
    }


def compute_isa_t_count_py(isa_ops: List[List[Any]]) -> int:
    return sum(
        1 for ins in isa_ops if ins[0] in ("t", "tdg", "ry_pi4", "ry_mpi4")
    )


def compute_isa_t_depth_py(num_qubits: int, isa_ops: List[List[Any]]) -> int:
    wire_td = [0] * num_qubits
    for ins in isa_ops:
        op = ins[0]
        if op in ("t", "tdg", "ry_pi4", "ry_mpi4"):
            w = int(ins[1])
            wire_td[w] += 1
        elif op in ("cx", "cz"):
            w1, w2 = int(ins[1]), int(ins[2])
            d = max(wire_td[w1], wire_td[w2])
            wire_td[w1] = d
            wire_td[w2] = d
    return max(wire_td) if wire_td else 0


def verify_lean_proofs() -> Dict[str, Any]:
    """Runs Lean 4 kernel checker and structural proof-hygiene linter on saturation proofs."""
    proc = subprocess.run(
        [str(LEAN_BIN), str(PROOF_LEAN)],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"Lean 4 verification failed on {PROOF_LEAN}:\n{proc.stdout}\n{proc.stderr}"
        )
    stdout_clean = proc.stdout.strip()
    if stdout_clean != "true":
        raise AssertionError(
            f"Expected Lean #eval to output 'true', got: {stdout_clean!r}"
        )

    src_text = PROOF_LEAN.read_text(encoding="utf-8")
    lean_audit = audit_lean_file(PROOF_LEAN, REPO_ROOT)
    lean_gap_audit = audit_lean_source(PROOF_LEAN.name, src_text)
    max_proof_lines = max(t["proof_lines"] for t in lean_audit["theorems"])
    if lean_audit["kernel_violations"]:
        raise AssertionError(
            f"Lean kernel violations: {lean_audit['kernel_violations']}"
        )
    if lean_audit["vacuous_or_tautological"]:
        raise AssertionError(
            f"Vacuous/tautological theorems: {lean_audit['vacuous_or_tautological']}"
        )
    if max_proof_lines > 25:
        raise AssertionError(f"Proof exceeded 25 lines: {max_proof_lines}")
    if not all(not v for v in lean_gap_audit.values()):
        raise AssertionError(f"Preprint audit flags: {lean_gap_audit}")

    required_theorems = [
        "f2_cubic_todd_rank_reduction_and_autocc_pair_fusion_soundness",
        "todd_autocc_phase_poly_qphys_grade_monotonicity",
    ]
    for thm in required_theorems:
        if f"theorem {thm}" not in src_text:
            raise AssertionError(f"Missing required theorem {thm} in {PROOF_LEAN}")

    return {
        "lean_file": str(PROOF_LEAN.relative_to(REPO_ROOT)),
        "kernel_exit_code": proc.returncode,
        "eval_master_check": stdout_clean == "true",
        "theorems_total": lean_audit["theorem_count"],
        "theorems_small_25lines": lean_audit["theorem_count"],
        "max_proof_lines": max_proof_lines,
        "hygiene_violations": 0,
        "verified_todd_autocc_theorems": required_theorems,
    }


def run_racket_saturator_json() -> Dict[str, Any]:
    """Executes `compiler/lakefillq-egraph-saturator.rkt --json` and parses the JSON bundle."""
    proc = subprocess.run(
        [str(RACKET_BIN), str(SATURATOR_RKT), "--json"],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"Racket e-graph saturator failed:\n{proc.stdout}\n{proc.stderr}"
        )
    return json.loads(proc.stdout)


def verify_todd_autocc_cones(bundle: Dict[str, Any]) -> Dict[str, Any]:
    """Verifies exact unitary equivalence, PyZX tensor identity, Stim frame, and T-metrics."""
    # 1. Confirm all existing baseline flags pass
    for flag in (
        "congruence_closure_unit_test_passed",
        "all_target_separation_assertions_passed",
        "zx_phase_polynomial_extension_passed",
        "external_decoder_pacing_passed",
        "todd_autocc_phase_poly_optimization_passed",
    ):
        if not bundle.get(flag, False):
            raise AssertionError(f"Saturator self-test flag {flag} is False!")

    if len(bundle.get("benchmarks", [])) != 5:
        raise AssertionError("Expected 5 core benchmarks in bundle['benchmarks']!")
    if (
        bundle.get("zx_phase_poly_benchmark", {}).get("benchmark_name")
        != "zx-phase-poly-parity-cascade"
    ):
        raise AssertionError("Missing zx-phase-poly-parity-cascade benchmark!")

    todd_sec = bundle.get("todd_autocc_phase_poly_optimization")
    if not todd_sec:
        raise AssertionError(
            "Missing 'todd_autocc_phase_poly_optimization' section in JSON bundle!"
        )

    cones = todd_sec.get("cones", [])
    if len(cones) != 3:
        raise AssertionError(f"Expected 3 TODD/AutoCCZ cones, got {len(cones)}")

    expected_cone_names = [
        "bp-aes-sbox-phase-cone",
        "keccak-f200-chi-row-cone",
        "suzuki-hermitian-dqi-syndrome-cone",
    ]
    cone_results: List[Dict[str, Any]] = []

    for cone, expected_name in zip(cones, expected_cone_names):
        name = cone["benchmark_name"]
        if name != expected_name:
            raise AssertionError(f"Expected cone {expected_name}, got {name}")

        nw = int(cone["num_qubits"])
        pre_isa = cone["pre_machine_isa"]
        post_isa = cone["post_machine_isa"]

        # Verify peak logical qubits and 0 additional qubits
        pre_q = int(cone["peak_logical_qubits_pre"])
        post_q = int(cone["peak_logical_qubits_post"])
        addl_q = int(cone["additional_peak_logical_qubits"])
        if pre_q != nw or post_q != nw or addl_q != 0:
            raise AssertionError(
                f"{name}: expected 0 additional qubits ({nw} -> {nw}), got {pre_q} -> {post_q} (+{addl_q})"
            )

        # Verify T-count and T-depth independently from MachineISA
        pre_tc = compute_isa_t_count_py(pre_isa)
        post_tc = compute_isa_t_count_py(post_isa)
        pre_td = compute_isa_t_depth_py(nw, pre_isa)
        post_td = compute_isa_t_depth_py(nw, post_isa)

        if pre_tc != int(cone["pre_t_count"]) or post_tc != int(
            cone["post_t_count"]
        ):
            raise AssertionError(
                f"{name}: T-count mismatch between Python ({pre_tc}->{post_tc}) and Racket ({cone['pre_t_count']}->{cone['post_t_count']})"
            )
        if pre_td != int(cone["pre_t_depth"]) or post_td != int(
            cone["post_t_depth"]
        ):
            raise AssertionError(
                f"{name}: T-depth mismatch between Python ({pre_td}->{post_td}) and Racket ({cone['pre_t_depth']}->{cone['post_t_depth']})"
            )

        tc_red_pct = 100.0 * (pre_tc - post_tc) / pre_tc
        td_red_pct = 100.0 * (pre_td - post_td) / pre_td

        if not (18.0 <= tc_red_pct <= 28.0):
            raise AssertionError(
                f"{name}: T-count reduction {tc_red_pct:.2f}% outside [18%, 28%]!"
            )
        if not (25.0 <= td_red_pct <= 50.0):
            raise AssertionError(
                f"{name}: T-depth reduction {td_red_pct:.2f}% outside [25%, 50%]!"
            )

        # 1. Qiskit Operator / NumPy exact unitary simulation
        qc_pre = build_qiskit_circuit_from_isa(nw, pre_isa)
        qc_post = build_qiskit_circuit_from_isa(nw, post_isa)
        u_pre = Operator(qc_pre).data
        u_post = Operator(qc_post).data

        max_abs_diff = float(np.max(np.abs(u_pre - u_post)))
        frob_diff = float(np.linalg.norm(u_pre - u_post, ord="fro"))
        hs_inner = abs(np.trace(u_pre.conj().T @ u_post)) / (1 << nw)
        phase_infidelity = float(abs(1.0 - hs_inner))

        if max_abs_diff >= 1e-12:
            raise AssertionError(
                f"{name}: ||U_pre - U_post||_max = {max_abs_diff:.3e} >= 1e-12!"
            )

        # Also check all 2^n diagonal phases on computational basis states
        diag_pre = np.diag(u_pre)
        diag_post = np.diag(u_post)
        max_diag_diff = float(np.max(np.abs(diag_pre - diag_post)))
        if max_diag_diff >= 1e-12:
            raise AssertionError(
                f"{name}: diagonal basis statevector diff {max_diag_diff:.3e} >= 1e-12!"
            )

        # 2. PyZX tensor & ZX-diagram equivalence check
        zx_pre = build_pyzx_circuit_from_isa(nw, pre_isa)
        zx_post = build_pyzx_circuit_from_isa(nw, post_isa)
        pyzx_exact_scalar_eq = bool(
            zx.compare_tensors(zx_pre, zx_post, preserve_scalar=True)
        )
        if not pyzx_exact_scalar_eq:
            raise AssertionError(
                f"{name}: PyZX compare_tensors(..., preserve_scalar=True) returned False!"
            )

        # Verify PyZX full_reduce on `zx_pre.adjoint() + zx_post` reduces to identity
        zx_combined = zx_pre.adjoint() + zx_post
        g_comb = zx_combined.to_graph()
        zx.simplify.full_reduce(g_comb)
        pyzx_adjoint_identity = bool(
            zx.compare_tensors(g_comb, zx.Circuit(nw), preserve_scalar=False)
        )
        if not pyzx_adjoint_identity:
            raise AssertionError(
                f"{name}: PyZX full_reduce(U_pre^dag U_post) did not reduce to identity!"
            )

        # 3. Stim stabilizer / GF(2) CNOT frame verification
        stim_res = verify_stim_cnot_frame_equivalence(nw, pre_isa, post_isa)
        if not stim_res["stim_tableau_z_outputs_equal"]:
            raise AssertionError(f"{name}: Stim tableau Z-outputs differed!")

        # 4. Verify hardware extractions in e-graph match post_machine_isa
        hw_exts = cone["hardware_extractions"]
        for hw_name, expected_op in (
            ("NISQ-HighSPAM-Transmon", "todd-rm3-reduced-cone"),
            ("IBM-Heron-r2-Dynamic", "todd-autocc-packed-cone"),
            ("QuEra-Bluvstein-Zoned-AOD", "todd-autocc-packed-cone"),
            ("FTQC-BB-qLDPC-Cultivation", "todd-autocc-packed-cone"),
        ):
            hw_entry = hw_exts[hw_name]
            op_hist = hw_entry["operator_histogram"]
            if op_hist.get(expected_op, 0) < 1:
                raise AssertionError(
                    f"{name} on {hw_name}: expected {expected_op} in {op_hist}"
                )
            hw_isa = hw_entry["machine_isa"]
            if hw_isa != post_isa:
                raise AssertionError(
                    f"{name} on {hw_name}: extracted machine_isa does not match post_machine_isa!"
                )

        cone_results.append(
            {
                "benchmark_name": name,
                "num_qubits": nw,
                "additional_peak_logical_qubits": addl_q,
                "pre_t_count": pre_tc,
                "post_t_count": post_tc,
                "t_count_saved": pre_tc - post_tc,
                "t_count_reduction_pct": round(tc_red_pct, 2),
                "pre_t_depth": pre_td,
                "post_t_depth": post_td,
                "t_depth_saved": pre_td - post_td,
                "t_depth_reduction_pct": round(td_red_pct, 2),
                "pre_twoq_count": int(cone["pre_twoq_count"]),
                "post_twoq_count": int(cone["post_twoq_count"]),
                "max_unitary_diff_norm": max_abs_diff,
                "frobenius_unitary_diff_norm": frob_diff,
                "global_phase_infidelity": phase_infidelity,
                "pyzx_preserve_scalar_tensor_eq": pyzx_exact_scalar_eq,
                "pyzx_full_reduce_identity_eq": pyzx_adjoint_identity,
                "stim_gf2_frame_verified": stim_res["stim_tableau_z_outputs_equal"],
                "stim_basis_states_checked": stim_res["basis_states_verified"],
                "egraph_stats": cone["egraph_stats"],
            }
        )

    agg = todd_sec["aggregate_summary"]
    return {
        "pass_name": todd_sec["pass_name"],
        "certification_scope": todd_sec["certification_scope"],
        "cones": cone_results,
        "aggregate_summary": agg,
    }


def main() -> None:
    print(
        "======================================================================"
    )
    print(
        "LakefillQ ZX E-Graph & RM(3,n) TODD + AutoCCZ Phase-Poly Verifier"
    )
    print(
        "======================================================================"
    )

    lean_report = verify_lean_proofs()
    print(
        f"[1/3] Lean 4 Proof Verification PASSED: {lean_report['lean_file']} "
        f"({lean_report['theorems_small_25lines']}/{lean_report['theorems_total']} "
        f"theorems <= 25 lines, 0 hygiene violations)"
    )

    bundle = run_racket_saturator_json()
    print(
        "[2/3] Racket E-Graph Saturator JSON Self-Tests PASSED "
        "(5 core benchmarks + ZX cascade + cryo-CMOS pacing + 3 TODD/AutoCCZ cones)"
    )

    todd_report = verify_todd_autocc_cones(bundle)
    agg = todd_report["aggregate_summary"]
    print(
        f"[3/3] Exact Unitary (Qiskit/NumPy), PyZX, & Stim Verification PASSED:\n"
        f"      Aggregate T-count: {agg['total_pre_t_count']} -> {agg['total_post_t_count']} "
        f"(-{agg['aggregate_t_count_reduction_pct']}%)\n"
        f"      Aggregate T-depth: {agg['total_pre_t_depth']} -> {agg['total_post_t_depth']} "
        f"(-{agg['aggregate_t_depth_reduction_pct']}%)\n"
        f"      Max additional peak logical qubits: {agg['max_additional_peak_logical_qubits']}"
    )
    for c in todd_report["cones"]:
        print(
            f"      * {c['benchmark_name']} ({c['num_qubits']}q, +{c['additional_peak_logical_qubits']}q): "
            f"T-count {c['pre_t_count']} -> {c['post_t_count']} (-{c['t_count_reduction_pct']:.2f}%), "
            f"T-depth {c['pre_t_depth']} -> {c['post_t_depth']} (-{c['t_depth_reduction_pct']:.2f}%), "
            f"||U_pre - U_post||_max = {c['max_unitary_diff_norm']:.3e}, "
            f"PyZX={c['pyzx_preserve_scalar_tensor_eq']}, Stim={c['stim_gf2_frame_verified']}"
        )

    full_report = {
        "verifier": "reproducers/verify_lakefillq_egraph_qphys_saturator.py",
        "all_checks_passed": True,
        "lean4_verification": lean_report,
        "todd_autocc_phase_poly_verification": todd_report,
    }
    primary_artifact = (
        REPO_ROOT
        / "reproducers"
        / "artifacts"
        / "lakefillq_egraph_qphys_extraction_report.json"
    )
    if primary_artifact.exists():
        ext_doc = json.loads(primary_artifact.read_text(encoding="utf-8"))
        ext_doc["todd_autocc_phase_poly_verification"] = todd_report
        if "lean4_mechanization_audit" in ext_doc:
            ext_doc["lean4_mechanization_audit"]["theorem_count"] = lean_report["theorems_total"]
        primary_artifact.write_text(json.dumps(ext_doc, indent=2) + "\n", encoding="utf-8")
    if "--save-json" in sys.argv:
        REPORT_JSON.parent.mkdir(parents=True, exist_ok=True)
        REPORT_JSON.write_text(
            json.dumps(full_report, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        print(
            f"Saved verification report to {REPORT_JSON.relative_to(REPO_ROOT)}"
        )
    if "--json" in sys.argv:
        print(json.dumps(full_report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
