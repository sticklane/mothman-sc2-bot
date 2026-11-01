#!/usr/bin/env python3
"""
Verification Harness for `ae/lakefillq_lint.py`
(`Gamma_in |- t : Q_e(A) -| Gamma_out`: `T-DomImg` .. `T-ParGuard` + `M* <= 256` Sizer)

Verifies:
  1. 16 buggy circuits across all 7 projected `LakefillQ` static rules in both
     `OpenQASM 3.0` and `Qiskit QuantumCircuit` formats (`100%` true-positive rate,
     every diagnostic carrying an explicit counterexample witness).
  2. 14 clean / repaired circuits across all 7 rules in both `OpenQASM 3.0` and
     `Qiskit QuantumCircuit` formats (`0%` false-positive rate).
  3. Compact `AerSimulator(method="statevector")` (`<= 9` qubits) physical statevector
     verification across 7 buggy-vs-repaired circuit pairs.
  4. `M_max = 256` Convex `M*` Cluster Sizer cross-checks across all 12 workload
     presets, interconnect topologies, U-curve knee pruning, and sequential-depth
     `M* = 1` fallback.
  5. Subprocess CLI verification (`--self-test --json`, positional `.qasm --json`,
     `--spec-json --json`, `--workload --json`) using scratch files exclusively under
     `~/toolchains/tmp/linter_verify`.
"""

from __future__ import annotations

import json
import math
import os
import resource
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Tuple

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRATCH_DIR = Path.home() / "toolchains" / "tmp" / "linter_verify"
SCRATCH_DIR.mkdir(parents=True, exist_ok=True)
os.environ["TMPDIR"] = str(Path.home() / "toolchains" / "tmp")

if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

import numpy as np
from qiskit import QuantumCircuit, QuantumRegister, ClassicalRegister
from qiskit_aer import AerSimulator

from ae.lakefillq_lint import (
    ALL_SEVEN_RULES,
    SOTA_CLUSTER_WORKLOAD_PRESETS,
    LintSpec,
    lint_qasm_str,
    lint_qiskit_circuit,
    size_convex_m_star_cluster,
)


def run_aer_statevector(qc: QuantumCircuit) -> np.ndarray:
    assert qc.num_qubits <= 14, f"Keep AerSimulator compact (<= 14 qubits), got {qc.num_qubits}"
    qc_sv = qc.copy()
    qc_sv.save_statevector()
    sim = AerSimulator(method="statevector")
    res = sim.run(qc_sv, shots=1).result()
    return np.asarray(res.get_statevector(qc_sv), dtype=np.complex128)


def state_fidelity(psi_a: np.ndarray, psi_b: np.ndarray) -> float:
    na = float(np.linalg.norm(psi_a))
    nb = float(np.linalg.norm(psi_b))
    if na < 1e-15 or nb < 1e-15:
        return 0.0
    ov = complex(np.vdot(psi_a / na, psi_b / nb))
    return float((ov.real * ov.real) + (ov.imag * ov.imag))


def build_gf2_3_clean_qc() -> QuantumCircuit:
    """
    Out-of-place GF(2^3) multiplier modulo x^3 + x + 1:
      a = q[0..2], b = q[3..5], p = q[6..8] (initially |000>).
      p0 = a0*b0 ^ a1*b2 ^ a2*b1
      p1 = a0*b1 ^ a1*b0 ^ a1*b2 ^ a2*b1 ^ a2*b2
      p2 = a0*b2 ^ a1*b1 ^ a2*b0 ^ a2*b2
    """
    qc = QuantumCircuit(9, name="gf2_3_clean_qiskit")
    terms = [
        (0, 3, 6), (1, 5, 6), (2, 4, 6),
        (0, 4, 7), (1, 3, 7), (1, 5, 7), (2, 4, 7), (2, 5, 7),
        (0, 5, 8), (1, 4, 8), (2, 3, 8), (2, 5, 8),
    ]
    for ia, ib, ip in terms:
        qc.ccx(ia, ib, ip)
    return qc


def build_gf2_3_aliased_buggy_qc() -> QuantumCircuit:
    """
    Buggy in-place GF(2^3) multiplier aliasing output wire p0 onto input wire a0 (q[0]),
    corrupting subsequent partial products a0*b1 and a0*b2.
    """
    qc = QuantumCircuit(8, name="gf2_3_aliased_buggy_qiskit")
    # Aliased output wires: [0, 6, 7] where wire 0 is also a0!
    qc.ccx(1, 5, 0)
    qc.ccx(2, 4, 0)
    qc.ccx(0, 4, 6)  # reads already-mutated q[0]!
    qc.ccx(1, 3, 6)
    qc.ccx(0, 5, 7)  # reads already-mutated q[0]!
    qc.ccx(2, 3, 7)
    return qc


def build_buggy_test_cases() -> List[Dict[str, Any]]:
    cases: List[Dict[str, Any]] = []

    # 1. T-DomImg (OpenQASM 3.0): Read-only input wire mutated by reversed CNOT
    cases.append({
        "id": "BUG-01-DOMIMG-QASM-READONLY-MUTATION",
        "expected_rule": "T-DomImg",
        "expected_code": "E-DOMIMG-READONLY-ALIASED-MUTATION",
        "kind": "openqasm3",
        "qasm": (
            'OPENQASM 3.0;\ninclude "stdgates.inc";\n'
            "qubit[3] q;\ncx q[0], q[2];\ncx q[2], q[0];\n"
        ),
        "spec": {"readonly_input_wires": [0, 1], "output_wires": [2]},
    })

    # 2. T-DomImg (Qiskit): Aliased GF(2^3) polynomial multiplier corrupting input a[0]
    cases.append({
        "id": "BUG-02-DOMIMG-QISKIT-GF2K-ALIAS",
        "expected_rule": "T-DomImg",
        "expected_code": "E-DOMIMG-GF2K-ALIAS-CORRUPTION",
        "kind": "qiskit",
        "qc": build_gf2_3_aliased_buggy_qc(),
        "spec": {
            "gf2k_mul_spec": {
                "a_wires": [0, 1, 2],
                "b_wires": [3, 4, 5],
                "out_wires": [0, 6, 7],
                "modulus_poly": [1, 1, 0, 1],
            }
        },
    })

    # 3. T-DomImg (OpenQASM 3.0): Roundtrip uncomputation mismatch (subtract without carry restore)
    cases.append({
        "id": "BUG-03-DOMIMG-QASM-UNCOMPUTE-ROUNDTRIP",
        "expected_rule": "T-DomImg",
        "expected_code": "E-DOMIMG-ROUNDTRIP-RESIDUAL",
        "kind": "openqasm3",
        "qasm": (
            'OPENQASM 3.0;\ninclude "stdgates.inc";\n'
            "qubit[3] q;\nccx q[0], q[1], q[2];\ncx q[0], q[1];\n"
        ),
        "spec": {
            "input_wires": [0, 1],
            "ancilla_wires": [2],
            "uncompute_qasm": (
                'OPENQASM 3.0;\ninclude "stdgates.inc";\n'
                "qubit[3] q;\ncx q[0], q[1];\n"
            ),
        },
    })

    # 4. T-BorrowZ (OpenQASM 3.0): Borrowed ConstZ control wire polluted by Hadamard gate
    cases.append({
        "id": "BUG-04-BORROWZ-QASM-HADAMARD-POLLUTION",
        "expected_rule": "T-BorrowZ",
        "expected_code": "E-BORROWZ-BASIS-POLLUTION",
        "kind": "openqasm3",
        "qasm": (
            'OPENQASM 3.0;\ninclude "stdgates.inc";\n'
            "qubit[2] q;\nh q[0];\ncx q[0], q[1];\nh q[0];\n"
        ),
        "spec": {"borrowed_z_wires": [0]},
    })

    # 5. T-BorrowZ (Qiskit): Borrowed ConstZ wire toggled via X without restoration
    qc_bz_mut = QuantumCircuit(2, name="borrowz_unrestored_x")
    qc_bz_mut.x(0)
    qc_bz_mut.cx(0, 1)
    cases.append({
        "id": "BUG-05-BORROWZ-QISKIT-UNRESTORED-CONTROL",
        "expected_rule": "T-BorrowZ",
        "expected_code": "E-BORROWZ-UNRESTORED-MUTATION",
        "kind": "qiskit",
        "qc": qc_bz_mut,
        "spec": {"borrowed_z_wires": [0]},
    })

    # 6. T-BorrowZ (OpenQASM 3.0): Unguarded oracle phase flip ignoring validity witness wire
    cases.append({
        "id": "BUG-06-BORROWZ-QASM-UNGUARDED-PHASE",
        "expected_rule": "T-BorrowZ",
        "expected_code": "E-BORROWZ-UNGUARDED-PHASE-FLIP",
        "kind": "openqasm3",
        "qasm": (
            'OPENQASM 3.0;\ninclude "stdgates.inc";\n'
            "qubit[3] q;\ncx q[0], q[2];\nz q[1];\ncx q[0], q[2];\n"
        ),
        "spec": {"validity_witness_wire": 2, "witness_ready_after_gate": 0},
    })

    # 7. T-PhaseClean (OpenQASM 3.0): Dirty CCX ancilla missing Bennet reverse sweep
    cases.append({
        "id": "BUG-07-PHASECLEAN-QASM-DIRTY-ANCILLA",
        "expected_rule": "T-PhaseClean",
        "expected_code": "E-PHASECLEAN-DIRTY-ANCILLA",
        "kind": "openqasm3",
        "qasm": (
            'OPENQASM 3.0;\ninclude "stdgates.inc";\n'
            "qubit[4] q;\nccx q[0], q[1], q[2];\ncx q[2], q[3];\n"
        ),
        "spec": {"input_wires": [0, 1], "output_wires": [3], "ancilla_wires": [2]},
    })

    # 8. T-PhaseClean (Qiskit): Clean computational basis wires but residual S-phase kickback
    qc_phase_bug = QuantumCircuit(2, name="phaseclean_residual_s_phase")
    qc_phase_bug.cx(0, 1)
    qc_phase_bug.s(1)
    qc_phase_bug.cx(0, 1)
    cases.append({
        "id": "BUG-08-PHASECLEAN-QISKIT-RESIDUAL-PHASE",
        "expected_rule": "T-PhaseClean",
        "expected_code": "E-PHASECLEAN-RESIDUAL-PHASE",
        "kind": "qiskit",
        "qc": qc_phase_bug,
        "spec": {"input_wires": [0], "ancilla_wires": [1], "expect_phase_clean": True},
    })

    # 9. T-CounitU4 (OpenQASM 3.0): Mid-circuit M_X TempAND erasure missing `if (c==1) cz` fixup
    cases.append({
        "id": "BUG-09-COUNITU4-QASM-MISSING-CZ-FIXUP",
        "expected_rule": "T-CounitU4",
        "expected_code": "E-COUNITU4-TAINTED-PHASE",
        "kind": "openqasm3",
        "qasm": (
            'OPENQASM 3.0;\ninclude "stdgates.inc";\n'
            "qubit[3] q;\nbit[1] c;\n"
            "ccx q[0], q[1], q[2];\nh q[2];\nc[0] = measure q[2];\nreset q[2];\n"
        ),
        "spec": {},
    })

    # 10. T-CounitU4 (Qiskit): Cross-QPU redundant unitary cat-disentangler instead of Law U4 M_X
    qc_remote_bug = QuantumCircuit(3, name="counitu4_redundant_remote_cx")
    qc_remote_bug.cx(0, 1)   # QPU 0 -> QPU 1 remote fanout
    qc_remote_bug.cx(1, 2)   # local target use on QPU 1
    qc_remote_bug.cx(0, 1)   # redundant QPU 0 -> QPU 1 unitary uncompute!
    cases.append({
        "id": "BUG-10-COUNITU4-QISKIT-REDUNDANT-REMOTE-UNCOMPUTE",
        "expected_rule": "T-CounitU4",
        "expected_code": "E-COUNITU4-REDUNDANT-REMOTE-DISENTANGLER",
        "kind": "qiskit",
        "qc": qc_remote_bug,
        "spec": {"qpu_partition": [0, 1, 1], "ancilla_wires": [1]},
    })

    # 11. T-SubNorm (Qiskit): QSVT block-encoding alpha_declared < ||A||_2 overflow
    qc_subnorm_alpha = QuantumCircuit(2, name="subnorm_alpha_overflow")
    qc_subnorm_alpha.h(0)
    qc_subnorm_alpha.cx(0, 1)
    qc_subnorm_alpha.h(0)
    cases.append({
        "id": "BUG-11-SUBNORM-QISKIT-ALPHA-OVERFLOW",
        "expected_rule": "T-SubNorm",
        "expected_code": "E-SUBNORM-ALPHA-OVERFLOW",
        "kind": "qiskit",
        "qc": qc_subnorm_alpha,
        "spec": {
            "block_encoding_spec": {
                "alpha_declared": 0.75,
                "lcu_coeffs": [0.6, 0.6],
            }
        },
    })

    # 12. T-SubNorm (OpenQASM 3.0): Block-encoding top-left `<0|U|0>` spectral error + Chebyshev amplification
    cases.append({
        "id": "BUG-12-SUBNORM-QASM-BLOCK-ERR-AND-CHEBYSHEV",
        "expected_rule": "T-SubNorm",
        "expected_code": "E-SUBNORM-BLOCK-ENCODING-ERROR",
        "kind": "openqasm3",
        "qasm": (
            'OPENQASM 3.0;\ninclude "stdgates.inc";\n'
            "qubit[2] q;\nry(0.9) q[1];\ncx q[1], q[0];\n"
        ),
        "spec": {
            "block_encoding_spec": {
                "alpha_declared": 1.0,
                "system_wires": [0],
                "target_matrix": [[1.0, 0.0], [0.0, 1.0]],
                "eps_0": 0.01,
                "degree": 20,
                "eps_target": 0.5,
            }
        },
    })

    # 13. T-QubitCap (OpenQASM 3.0): Single-QPU capacity overflow without multi-QPU partition
    cases.append({
        "id": "BUG-13-QUBITCAP-QASM-SINGLE-QPU-OVERFLOW",
        "expected_rule": "T-QubitCap",
        "expected_code": "E-QUBITCAP-EXCEEDS-SINGLE-QPU",
        "kind": "openqasm3",
        "qasm": (
            'OPENQASM 3.0;\ninclude "stdgates.inc";\n'
            "qubit[8] q;\nccx q[0], q[1], q[2];\nccx q[2], q[3], q[7];\n"
        ),
        "spec": {"q_cap": 6, "input_wires": [0, 1, 3], "ancilla_wires": [2, 4, 5, 6], "output_wires": [7]},
    })

    # 14. T-QubitCap (Qiskit): Detached Toffoli cost claim mismatch against compiled AST
    qc_detached = QuantumCircuit(4, name="qubitcap_detached_cost")
    qc_detached.ccx(0, 1, 2)
    qc_detached.cx(2, 3)
    qc_detached.ccx(0, 1, 2)
    cases.append({
        "id": "BUG-14-QUBITCAP-QISKIT-DETACHED-COST",
        "expected_rule": "T-QubitCap",
        "expected_code": "E-QUBITCAP-DETACHED-COST-MISMATCH",
        "kind": "qiskit",
        "qc": qc_detached,
        "spec": {"input_wires": [0, 1], "output_wires": [3], "ancilla_wires": [2], "claimed_temp_ands": 1},
    })

    # 15. T-ParGuard (OpenQASM 3.0): Requesting M = 16 on ECC-256 where M* = 4 is optimal
    cases.append({
        "id": "BUG-15-PARGUARD-QASM-SUBOPTIMAL-ECC256-M16",
        "expected_rule": "T-ParGuard",
        "expected_code": "E-PARGUARD-SUBOPTIMAL-M",
        "kind": "openqasm3",
        "qasm": (
            'OPENQASM 3.0;\ninclude "stdgates.inc";\n'
            "qubit[3] q;\nccx q[0], q[1], q[2];\nccx q[0], q[1], q[2];\n"
        ),
        "spec": {"cluster_spec": {"workload": "ECC-256", "requested_machines": 16}},
    })

    # 16. T-ParGuard (Qiskit): Requesting M = 8 on Grover AES-128 where Zalka guard enforces M* = 1
    qc_grover_par = QuantumCircuit(3, name="parguard_grover_aes128_m8")
    qc_grover_par.ccx(0, 1, 2)
    qc_grover_par.z(2)
    qc_grover_par.ccx(0, 1, 2)
    cases.append({
        "id": "BUG-16-PARGUARD-QISKIT-ZALKA-GROVER-M8",
        "expected_rule": "T-ParGuard",
        "expected_code": "E-PARGUARD-ZALKA-GROVER-SUBLINEAR",
        "kind": "qiskit",
        "qc": qc_grover_par,
        "spec": {
            "cluster_spec": {
                "workload": "AES-128",
                "strict_parallel": True,
                "requested_machines": 8,
            }
        },
    })

    return cases


def build_clean_test_cases() -> List[Dict[str, Any]]:
    cases: List[Dict[str, Any]] = []

    # 1. Clean T-DomImg (OpenQASM 3.0): Read-only input preserved
    cases.append({
        "id": "CLEAN-01-DOMIMG-QASM-READONLY",
        "kind": "openqasm3",
        "qasm": (
            'OPENQASM 3.0;\ninclude "stdgates.inc";\n'
            "qubit[3] q;\ncx q[0], q[2];\ncx q[1], q[2];\n"
        ),
        "spec": {"readonly_input_wires": [0, 1], "output_wires": [2]},
    })

    # 2. Clean T-DomImg (Qiskit): 9-qubit out-of-place GF(2^3) multiplier
    cases.append({
        "id": "CLEAN-02-DOMIMG-QISKIT-GF2K-EXACT",
        "kind": "qiskit",
        "qc": build_gf2_3_clean_qc(),
        "spec": {
            "gf2k_mul_spec": {
                "a_wires": [0, 1, 2],
                "b_wires": [3, 4, 5],
                "out_wires": [6, 7, 8],
                "modulus_poly": [1, 1, 0, 1],
            }
        },
    })

    # 3. Clean T-DomImg (OpenQASM 3.0): Exact reversible ripple step + exact inverse
    cases.append({
        "id": "CLEAN-03-DOMIMG-QASM-EXACT-INVERSE",
        "kind": "openqasm3",
        "qasm": (
            'OPENQASM 3.0;\ninclude "stdgates.inc";\n'
            "qubit[3] q;\nccx q[0], q[1], q[2];\ncx q[0], q[1];\n"
        ),
        "spec": {
            "input_wires": [0, 1],
            "ancilla_wires": [2],
            "uncompute_qasm": (
                'OPENQASM 3.0;\ninclude "stdgates.inc";\n'
                "qubit[3] q;\ncx q[0], q[1];\nccx q[0], q[1], q[2];\n"
            ),
        },
    })

    # 4. Clean T-BorrowZ (OpenQASM 3.0): Borrowed ConstZ wire used with OpenQASM 3 `negctrl @ x`
    cases.append({
        "id": "CLEAN-04-BORROWZ-QASM-NEGCTRL",
        "kind": "openqasm3",
        "qasm": (
            'OPENQASM 3.0;\ninclude "stdgates.inc";\n'
            "qubit[2] q;\nnegctrl @ x q[0], q[1];\n"
        ),
        "spec": {"borrowed_z_wires": [0]},
    })

    # 5. Clean T-BorrowZ (Qiskit): Validity-guarded phase oracle
    qc_valid_ok = QuantumCircuit(3, name="borrowz_guarded_oracle_ok")
    qc_valid_ok.cx(0, 2)
    qc_valid_ok.cz(2, 1)
    qc_valid_ok.cx(0, 2)
    cases.append({
        "id": "CLEAN-05-BORROWZ-QISKIT-GUARDED-ORACLE",
        "kind": "qiskit",
        "qc": qc_valid_ok,
        "spec": {
            "input_wires": [0, 1],
            "ancilla_wires": [2],
            "validity_witness_wire": 2,
            "witness_ready_after_gate": 0,
        },
    })

    # 6. Clean T-PhaseClean (OpenQASM 3.0): Symmetric Bennet compute-copy-uncompute
    cases.append({
        "id": "CLEAN-06-PHASECLEAN-QASM-BENNET",
        "kind": "openqasm3",
        "qasm": (
            'OPENQASM 3.0;\ninclude "stdgates.inc";\n'
            "qubit[4] q;\nccx q[0], q[1], q[2];\ncx q[2], q[3];\nccx q[0], q[1], q[2];\n"
        ),
        "spec": {
            "input_wires": [0, 1],
            "output_wires": [3],
            "ancilla_wires": [2],
            "expect_phase_clean": True,
        },
    })

    # 7. Clean T-PhaseClean (Qiskit): Relative S-phase cancelled by Sdg before uncomputation
    qc_phase_ok = QuantumCircuit(2, name="phaseclean_cancelled_s_sdg")
    qc_phase_ok.cx(0, 1)
    qc_phase_ok.s(1)
    qc_phase_ok.sdg(1)
    qc_phase_ok.cx(0, 1)
    cases.append({
        "id": "CLEAN-07-PHASECLEAN-QISKIT-PHASE-CANCELLED",
        "kind": "qiskit",
        "qc": qc_phase_ok,
        "spec": {"input_wires": [0], "ancilla_wires": [1], "expect_phase_clean": True},
    })

    # 8. Clean T-CounitU4 (OpenQASM 3.0): Gidney M_X TempAND erasure WITH `if (c[0] == 1) { cz q[0], q[1]; }`
    cases.append({
        "id": "CLEAN-08-COUNITU4-QASM-GIDNEY-MX-CZ",
        "kind": "openqasm3",
        "qasm": (
            'OPENQASM 3.0;\ninclude "stdgates.inc";\n'
            "qubit[3] q;\nbit[1] c;\n"
            "ccx q[0], q[1], q[2];\nh q[2];\nc[0] = measure q[2];\n"
            "if (c[0] == 1) { cz q[0], q[1]; }\nreset q[2];\n"
        ),
        "spec": {},
    })

    # 9. Clean T-CounitU4 (OpenQASM 3.0): Multi-QPU cat-disentanglement via local M_X + classical CZ
    cases.append({
        "id": "CLEAN-09-COUNITU4-QASM-REMOTE-MX-DISENTANGLE",
        "kind": "openqasm3",
        "qasm": (
            'OPENQASM 3.0;\ninclude "stdgates.inc";\n'
            "qubit[3] q;\nbit[1] c;\n"
            "cx q[0], q[1];\ncx q[1], q[2];\n"
            "h q[1];\nc[0] = measure q[1];\n"
            "if (c[0] == 1) { z q[0]; }\nreset q[1];\n"
        ),
        "spec": {"qpu_partition": [0, 1, 1]},
    })

    # 10. Clean T-SubNorm (Qiskit): Properly normalized LCU block encoding of 0.5*(I + Z) = |0><0|
    qc_subnorm_ok = QuantumCircuit(2, name="subnorm_exact_proj0")
    qc_subnorm_ok.h(1)
    qc_subnorm_ok.cz(1, 0)
    qc_subnorm_ok.h(1)
    cases.append({
        "id": "CLEAN-10-SUBNORM-QISKIT-EXACT-LCU",
        "kind": "qiskit",
        "qc": qc_subnorm_ok,
        "spec": {
            "block_encoding_spec": {
                "alpha_declared": 1.0,
                "lcu_coeffs": [0.5, 0.5],
                "system_wires": [0],
                "target_matrix": [[1.0, 0.0], [0.0, 0.0]],
                "eps_0": 1e-6,
                "degree": 10,
                "eps_target": 1e-3,
            }
        },
    })

    # 11. Clean T-QubitCap (OpenQASM 3.0): Fits single-QPU Q_cap via chordal reset reuse (4 qubits <= 4)
    cases.append({
        "id": "CLEAN-11-QUBITCAP-QASM-RESET-REUSE",
        "kind": "openqasm3",
        "qasm": (
            'OPENQASM 3.0;\ninclude "stdgates.inc";\n'
            "qubit[4] q;\n"
            "ccx q[0], q[1], q[2];\ncx q[2], q[3];\nccx q[0], q[1], q[2];\nreset q[2];\n"
            "ccx q[0], q[3], q[2];\nccx q[0], q[3], q[2];\n"
        ),
        "spec": {
            "q_cap": 4,
            "input_wires": [0, 1],
            "output_wires": [3],
            "ancilla_wires": [2],
            "claimed_ccx": 4,
        },
    })

    # 12. Clean T-QubitCap (Qiskit): Exact matrix-elimination full slice + Grover margin
    qc_mat_ok = QuantumCircuit(3, name="qubitcap_full_slice_ok")
    qc_mat_ok.ccx(0, 1, 2)
    qc_mat_ok.ccx(0, 1, 2)
    cases.append({
        "id": "CLEAN-12-QUBITCAP-QISKIT-SLICE-AND-MARGIN",
        "kind": "qiskit",
        "qc": qc_mat_ok,
        "spec": {
            "input_wires": [0, 1],
            "ancilla_wires": [2],
            "matrix_elim_slice": {"rows": 8, "total_cols": 16, "col_lo": 0, "col_hi": 16, "pivots": 8},
            "grover_oracle_spec": {"key_bits": 128, "m_check": 192, "s_margin": 32},
        },
    })

    # 13. Clean T-ParGuard (OpenQASM 3.0): ECC-256 provisioned at exact M* = 4
    cases.append({
        "id": "CLEAN-13-PARGUARD-QASM-ECC256-M4",
        "kind": "openqasm3",
        "qasm": (
            'OPENQASM 3.0;\ninclude "stdgates.inc";\n'
            "qubit[3] q;\nccx q[0], q[1], q[2];\nccx q[0], q[1], q[2];\n"
        ),
        "spec": {"cluster_spec": {"workload": "ECC-256", "requested_machines": 4}},
    })

    # 14. Clean T-ParGuard (Qiskit): Sequential-dominated circuit provisioned at exact M* = 1
    qc_seq_ok = QuantumCircuit(4, name="parguard_seq_dominated_m1")
    qc_seq_ok.ccx(0, 1, 2)
    qc_seq_ok.cx(2, 3)
    qc_seq_ok.ccx(0, 1, 2)
    cases.append({
        "id": "CLEAN-14-PARGUARD-QISKIT-SEQ-DOMINATED-M1",
        "kind": "qiskit",
        "qc": qc_seq_ok,
        "spec": {
            "input_wires": [0, 1],
            "output_wires": [3],
            "ancilla_wires": [2],
            "cluster_spec": {
                "paradigm": "algebraic-limb",
                "q_single": 120,
                "q_cap_per_machine": 400,
                "local_toffolis": 50000,
                "sequential_toffolis": 49500,
                "requested_machines": 1,
            },
        },
    })

    return cases


def verify_aer_buggy_vs_repaired_pairs() -> List[Dict[str, Any]]:
    """
    Compact (`<= 9` qubits) `AerSimulator(method='statevector')` verification proving
    physical state corruption in buggy circuits vs. fidelity 1.0 in repaired circuits.
    """
    aer_records: List[Dict[str, Any]] = []

    # Pair 1 (T-DomImg): GF(2^3) multiplier on a = x^2 (|001> -> q2=1), b = x + 1 (q0=1,q1=1 -> q3=1,q4=1)
    # Wait: a = 1 + x^2 (bits [1,0,1] = 5) * b = x + x^2 (bits [0,1,1] = 6) mod (x^3 + x + 1):
    # (1 + x^2)(x + x^2) = x + x^2 + x^3 + x^4 = x + x^2 + (x + 1) + (x^2 + x) = 1 + x (bits [1,1,0] = 3).
    # Notice a0 = 1, a1 = 0, a2 = 1, b0 = 0, b1 = 1, b2 = 1:
    # In buggy aliased circuit, ccx(2, 4, 0) flips q[0] from 1 -> 0 BEFORE ccx(0, 4, 6) and ccx(0, 5, 7)!
    qc_gf_bug = QuantumCircuit(8)
    qc_gf_bug.x(0)
    qc_gf_bug.x(2)
    qc_gf_bug.x(4)
    qc_gf_bug.x(5)
    qc_gf_bug.compose(build_gf2_3_aliased_buggy_qc(), inplace=True)
    sv_gf_bug = run_aer_statevector(qc_gf_bug)
    bug_idx = int(np.argmax(np.abs(sv_gf_bug)))
    # Expected product bits: p0=1, p1=1, p2=0; inputs preserved a=5 (0b101), b=6 (0b110)
    qc_gf_rep = QuantumCircuit(9)
    qc_gf_rep.x(0)
    qc_gf_rep.x(2)
    qc_gf_rep.x(4)
    qc_gf_rep.x(5)
    qc_gf_rep.compose(build_gf2_3_clean_qc(), inplace=True)
    sv_gf_rep = run_aer_statevector(qc_gf_rep)
    expected_gf_idx = (1 << 0) | (1 << 2) | (1 << 4) | (1 << 5) | (1 << 6) | (1 << 7)
    sv_gf_ideal = np.zeros(1 << 9, dtype=np.complex128)
    sv_gf_ideal[expected_gf_idx] = 1.0
    fid_gf_rep = state_fidelity(sv_gf_rep, sv_gf_ideal)
    # In buggy 8-qubit circuit, check if output bits [q0, q6, q7] equal [1, 1, 0]:
    bug_out_bits = [(bug_idx >> 0) & 1, (bug_idx >> 6) & 1, (bug_idx >> 7) & 1]
    aer_records.append({
        "pair_id": "AER-01-DOMIMG-GF2K-MULTIPLIER",
        "rule": "T-DomImg",
        "qubits_repaired": 9,
        "buggy_output_bits": bug_out_bits,
        "expected_output_bits": [1, 1, 0],
        "buggy_fidelity": 1.0 if bug_out_bits == [1, 1, 0] else 0.0,
        "repaired_fidelity": round(fid_gf_rep, 12),
        "verified": (bug_out_bits != [1, 1, 0]) and abs(fid_gf_rep - 1.0) < 1e-12,
    })

    # Pair 2 (T-BorrowZ): Borrowed ConstZ control wire initialized to |1>, target |0>
    # Buggy uses H-wrap (`h q[0]; cx q[0], q[1]; h q[0]`) instead of `negctrl @ x` (`x q[0]; cx q[0], q[1]; x q[0]`)
    qc_bz_bug = QuantumCircuit(2)
    qc_bz_bug.x(0)
    qc_bz_bug.h(0)
    qc_bz_bug.cx(0, 1)
    qc_bz_bug.h(0)
    sv_bz_bug = run_aer_statevector(qc_bz_bug)

    qc_bz_rep = QuantumCircuit(2)
    qc_bz_rep.x(0)
    qc_bz_rep.x(0)
    qc_bz_rep.cx(0, 1)
    qc_bz_rep.x(0)
    sv_bz_rep = run_aer_statevector(qc_bz_rep)

    sv_bz_ideal = np.zeros(4, dtype=np.complex128)
    sv_bz_ideal[0b01] = 1.0  # q[0]=1 preserved, q[1]=0 untouched since negctrl triggers on q[0]=0
    fid_bz_bug = state_fidelity(sv_bz_bug, sv_bz_ideal)
    fid_bz_rep = state_fidelity(sv_bz_rep, sv_bz_ideal)
    aer_records.append({
        "pair_id": "AER-02-BORROWZ-CONTROL-PURITY",
        "rule": "T-BorrowZ",
        "qubits_repaired": 2,
        "buggy_fidelity": round(fid_bz_bug, 12),
        "repaired_fidelity": round(fid_bz_rep, 12),
        "verified": (fid_bz_bug < 0.6) and abs(fid_bz_rep - 1.0) < 1e-12,
    })

    # Pair 3 (T-PhaseClean): Bennet ancilla uncomputation on superposition (H x H)|00>|0_anc>|0_out>
    qc_pc_bug = QuantumCircuit(4)
    qc_pc_bug.h(0)
    qc_pc_bug.h(1)
    qc_pc_bug.ccx(0, 1, 2)
    qc_pc_bug.cx(2, 3)
    sv_pc_bug = run_aer_statevector(qc_pc_bug)

    qc_pc_rep = QuantumCircuit(4)
    qc_pc_rep.h(0)
    qc_pc_rep.h(1)
    qc_pc_rep.ccx(0, 1, 2)
    qc_pc_rep.cx(2, 3)
    qc_pc_rep.ccx(0, 1, 2)
    sv_pc_rep = run_aer_statevector(qc_pc_rep)

    sv_pc_ideal = np.zeros(16, dtype=np.complex128)
    for x0 in (0, 1):
        for x1 in (0, 1):
            out3 = x0 & x1
            idx = x0 | (x1 << 1) | (0 << 2) | (out3 << 3)
            sv_pc_ideal[idx] = 0.5
    fid_pc_bug = state_fidelity(sv_pc_bug, sv_pc_ideal)
    fid_pc_rep = state_fidelity(sv_pc_rep, sv_pc_ideal)
    aer_records.append({
        "pair_id": "AER-03-PHASECLEAN-BENNET-ANCILLA",
        "rule": "T-PhaseClean",
        "qubits_repaired": 4,
        "buggy_fidelity": round(fid_pc_bug, 12),
        "repaired_fidelity": round(fid_pc_rep, 12),
        "verified": (fid_pc_bug < 0.8) and abs(fid_pc_rep - 1.0) < 1e-12,
    })

    # Pair 4 (T-PhaseClean): Residual relative S-phase kickback on |+>|0>
    qc_ph_bug = QuantumCircuit(2)
    qc_ph_bug.h(0)
    qc_ph_bug.cx(0, 1)
    qc_ph_bug.s(1)
    qc_ph_bug.cx(0, 1)
    sv_ph_bug = run_aer_statevector(qc_ph_bug)

    qc_ph_rep = QuantumCircuit(2)
    qc_ph_rep.h(0)
    qc_ph_rep.cx(0, 1)
    qc_ph_rep.s(1)
    qc_ph_rep.sdg(1)
    qc_ph_rep.cx(0, 1)
    sv_ph_rep = run_aer_statevector(qc_ph_rep)

    sv_ph_ideal = np.array([1.0 / math.sqrt(2.0), 1.0 / math.sqrt(2.0), 0.0, 0.0], dtype=np.complex128)
    fid_ph_bug = state_fidelity(sv_ph_bug, sv_ph_ideal)
    fid_ph_rep = state_fidelity(sv_ph_rep, sv_ph_ideal)
    aer_records.append({
        "pair_id": "AER-04-PHASECLEAN-RELATIVE-PHASE",
        "rule": "T-PhaseClean",
        "qubits_repaired": 2,
        "buggy_fidelity": round(fid_ph_bug, 12),
        "repaired_fidelity": round(fid_ph_rep, 12),
        "verified": (fid_ph_bug < 0.6) and abs(fid_ph_rep - 1.0) < 1e-12,
    })

    # Pair 5 (T-CounitU4): Law U4 M_X TempAND erasure on |++>|0> in the c = 1 measurement outcome branch
    # Projecting q[2] onto |-> (i.e. H q[2] followed by |1><1| collapse and reset to |0>):
    qc_u4_pre = QuantumCircuit(3)
    qc_u4_pre.h(0)
    qc_u4_pre.h(1)
    qc_u4_pre.ccx(0, 1, 2)
    qc_u4_pre.h(2)
    sv_u4_pre = run_aer_statevector(qc_u4_pre)
    # Extract collapsed branch where q[2] == 1 (indices 4..7), reset q[2] -> 0:
    branch_m1_bug = sv_u4_pre[4:8].copy()
    branch_m1_bug /= np.linalg.norm(branch_m1_bug)
    # Repaired applies CZ(0, 1) when m == 1:
    branch_m1_rep = branch_m1_bug.copy()
    branch_m1_rep[0b11] *= -1.0
    sv_u4_ideal = np.array([0.5, 0.5, 0.5, 0.5], dtype=np.complex128)
    fid_u4_bug = state_fidelity(branch_m1_bug, sv_u4_ideal)
    fid_u4_rep = state_fidelity(branch_m1_rep, sv_u4_ideal)
    aer_records.append({
        "pair_id": "AER-05-COUNITU4-MX-MINUS-BRANCH",
        "rule": "T-CounitU4",
        "qubits_repaired": 3,
        "buggy_fidelity": round(fid_u4_bug, 12),
        "repaired_fidelity": round(fid_u4_rep, 12),
        "verified": (fid_u4_bug < 0.3) and abs(fid_u4_rep - 1.0) < 1e-12,
    })

    # Pair 6 (T-SubNorm): Block encoding of P_0 = |0><0| on q[0] with ancilla q[1] on input |1>_sys |0>_anc
    # Ideal <0_anc| U |0_anc> |1>_sys = 0; buggy RY(0.9) leaves non-zero amplitude on |0_anc>|1_sys>
    qc_sn_bug = QuantumCircuit(2)
    qc_sn_bug.x(0)
    qc_sn_bug.ry(0.9, 1)
    qc_sn_bug.cx(1, 0)
    sv_sn_bug = run_aer_statevector(qc_sn_bug)
    # Top-left ancilla=0 block acting on |1>_sys is amplitudes at q[1]==0 (indices 0, 1):
    block_vec_bug = sv_sn_bug[0:2]
    err_sn_bug = float(np.linalg.norm(block_vec_bug))

    qc_sn_rep = QuantumCircuit(2)
    qc_sn_rep.x(0)
    qc_sn_rep.h(1)
    qc_sn_rep.cz(1, 0)
    qc_sn_rep.h(1)
    sv_sn_rep = run_aer_statevector(qc_sn_rep)
    block_vec_rep = sv_sn_rep[0:2]
    err_sn_rep = float(np.linalg.norm(block_vec_rep))
    aer_records.append({
        "pair_id": "AER-06-SUBNORM-BLOCK-PROJECTION",
        "rule": "T-SubNorm",
        "qubits_repaired": 2,
        "buggy_subblock_error": round(err_sn_bug, 12),
        "repaired_subblock_error": round(err_sn_rep, 12),
        "verified": (err_sn_bug > 0.8) and (err_sn_rep < 1e-12),
    })

    # Pair 7 (T-QubitCap): Unfolded 5-qubit two-step circuit vs 4-qubit chordal `reset`-reused circuit
    qc_cap_5q = QuantumCircuit(5)
    qc_cap_5q.x(0)
    qc_cap_5q.x(1)
    qc_cap_5q.ccx(0, 1, 2)
    qc_cap_5q.cx(2, 4)
    qc_cap_5q.ccx(0, 1, 2)
    qc_cap_5q.ccx(0, 4, 3)
    qc_cap_5q.ccx(0, 4, 3)
    sv_cap_5q = run_aer_statevector(qc_cap_5q)

    qc_cap_4q = QuantumCircuit(4)
    qc_cap_4q.x(0)
    qc_cap_4q.x(1)
    qc_cap_4q.ccx(0, 1, 2)
    qc_cap_4q.cx(2, 3)
    qc_cap_4q.ccx(0, 1, 2)
    qc_cap_4q.reset(2)
    qc_cap_4q.ccx(0, 3, 2)
    qc_cap_4q.ccx(0, 3, 2)
    sv_cap_4q = run_aer_statevector(qc_cap_4q)
    # Verify data wires (q0=1, q1=1, out=1) match identically while saving 1 physical ancilla qubit:
    prob_5q_target = float(abs(sv_cap_5q[(1 << 0) | (1 << 1) | (1 << 4)]) ** 2)
    prob_4q_target = float(abs(sv_cap_4q[(1 << 0) | (1 << 1) | (1 << 3)]) ** 2)
    aer_records.append({
        "pair_id": "AER-07-QUBITCAP-CHORDAL-RESET-REUSE",
        "rule": "T-QubitCap",
        "qubits_unfolded": 5,
        "qubits_repaired": 4,
        "unfolded_target_prob": round(prob_5q_target, 12),
        "repaired_target_prob": round(prob_4q_target, 12),
        "verified": abs(prob_5q_target - 1.0) < 1e-12 and abs(prob_4q_target - 1.0) < 1e-12,
    })

    return aer_records


def verify_convex_m_star_cluster_sizer() -> Dict[str, Any]:
    expected_m_star = {
        "ECC-256": 4,
        "RSA-2048": 6,
        "RSA-4096": 8,
        "AES-128": 1,
        "AES-256": 1,
        "SHA3-256": 1,
        "SLH-DSA-128s": 1,
        "McEliece-348864": 1,
        "BIKE-L1": 1,
        "DQI": 256,
        "Hubbard-QSVT": 256,
        "FeMoCo-THC": 64,
    }
    preset_results: List[Dict[str, Any]] = []
    all_presets_match = True
    for wname, exp_m in expected_m_star.items():
        info_peer, _ = size_convex_m_star_cluster(
            {"workload": wname, "max_machines": 256, "interconnect_topology": "all-to-all-peers"}
        )
        info_tree, _ = size_convex_m_star_cluster(
            {"workload": wname, "max_machines": 256, "interconnect_topology": "switched-optical-tree"}
        )
        ok = int(info_peer["optimal_machines"]) == exp_m
        if not ok:
            all_presets_match = False
        preset_results.append({
            "workload": wname,
            "paradigm": info_peer["paradigm"],
            "qpar_grade": info_peer["qpar_grade"],
            "expected_m_star_peers": exp_m,
            "actual_m_star_peers": info_peer["optimal_machines"],
            "q_per_machine_peers": info_peer["q_allocated_per_machine"],
            "logical_ebits_peers": info_peer["logical_ebits_total"],
            "m_star_optical_tree": info_tree["optimal_machines"],
            "q_per_machine_optical_tree": info_tree["q_allocated_per_machine"],
            "pruned_ucurve_count_peers": len(info_peer.get("pruned_ucurve_candidates", [])),
            "verified": ok,
        })

    # Sequential-dominated fallback check (`M* = 1` optimal across M in 1..256):
    seq_info, seq_diags = size_convex_m_star_cluster({
        "workload": "sequential_chain",
        "paradigm": "algebraic-limb",
        "q_single": 180,
        "q_cap_per_machine": 400,
        "max_machines": 256,
        "local_toffolis": 100000,
        "sequential_toffolis": 99500,
    })
    seq_ok = (
        seq_info["optimal_machines"] == 1
        and seq_info.get("sequential_depth_dominates") is True
        and seq_info.get("fallback_to_single_machine") is True
        and len(seq_diags) == 0
    )

    # U-curve knee pruning check on ECC-256 (`all-to-all-peers` prunes large M >= 16 where sync qubits dominate):
    ecc_info, _ = size_convex_m_star_cluster({"workload": "ECC-256", "max_machines": 256})
    ucurve_pruned_ok = len(ecc_info.get("pruned_ucurve_candidates", [])) >= 4

    return {
        "m_max_tested": 256,
        "presets_verified": sum(1 for r in preset_results if r["verified"]),
        "presets_total": len(preset_results),
        "all_presets_match": all_presets_match,
        "sequential_m1_fallback_verified": seq_ok,
        "ucurve_knee_pruning_verified": ucurve_pruned_ok,
        "preset_results": preset_results,
    }


def verify_cli_entrypoints() -> Dict[str, Any]:
    linter_script = REPO_ROOT / "ae" / "lakefillq_lint.py"
    env = dict(os.environ)
    env["TMPDIR"] = str(Path.home() / "toolchains" / "tmp")

    # 1. `--self-test --json`
    proc_self = subprocess.run(
        [sys.executable, str(linter_script), "--self-test", "--json"],
        cwd=str(REPO_ROOT),
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    self_payload = json.loads(proc_self.stdout)

    # 2. Positional buggy `.qasm --json` in SCRATCH_DIR
    bug_qasm_path = SCRATCH_DIR / "cli_buggy_counitu4.qasm"
    bug_qasm_path.write_text(
        'OPENQASM 3.0;\ninclude "stdgates.inc";\n'
        "qubit[3] q;\nbit[1] c;\n"
        "ccx q[0], q[1], q[2];\nh q[2];\nc[0] = measure q[2];\nreset q[2];\n",
        encoding="utf-8",
    )
    proc_bug = subprocess.run(
        [sys.executable, str(linter_script), str(bug_qasm_path), "--json"],
        cwd=str(REPO_ROOT),
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    bug_payload = json.loads(proc_bug.stdout)

    # 3. Clean `.qasm --spec-json ... --json` in SCRATCH_DIR
    clean_qasm_path = SCRATCH_DIR / "cli_clean_bennet.qasm"
    clean_spec_path = SCRATCH_DIR / "cli_clean_bennet_spec.json"
    clean_qasm_path.write_text(
        'OPENQASM 3.0;\ninclude "stdgates.inc";\n'
        "qubit[4] q;\nccx q[0], q[1], q[2];\ncx q[2], q[3];\nccx q[0], q[1], q[2];\n",
        encoding="utf-8",
    )
    clean_spec_path.write_text(
        json.dumps({"input_wires": [0, 1], "output_wires": [3], "ancilla_wires": [2], "q_cap": 4}),
        encoding="utf-8",
    )
    proc_clean = subprocess.run(
        [
            sys.executable,
            str(linter_script),
            "--qasm",
            str(clean_qasm_path),
            "--spec-json",
            str(clean_spec_path),
            "--json",
        ],
        cwd=str(REPO_ROOT),
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    clean_payload = json.loads(proc_clean.stdout)

    # 4. `--workload RSA-4096 --max-machines 256 --json`
    proc_sizer = subprocess.run(
        [sys.executable, str(linter_script), "--workload", "RSA-4096", "--max-machines", "256", "--json"],
        cwd=str(REPO_ROOT),
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    sizer_payload = json.loads(proc_sizer.stdout)

    cli_ok = (
        proc_self.returncode == 0
        and self_payload.get("self_test_passed") is True
        and proc_bug.returncode == 1
        and bug_payload.get("well_typed") is False
        and proc_clean.returncode == 0
        and clean_payload.get("well_typed") is True
        and proc_sizer.returncode == 0
        and (sizer_payload.get("cluster_sizing") or {}).get("optimal_machines") == 8
    )
    return {
        "cli_verified": cli_ok,
        "self_test_exit_code": proc_self.returncode,
        "buggy_qasm_exit_code": proc_bug.returncode,
        "clean_qasm_exit_code": proc_clean.returncode,
        "rsa4096_sizer_exit_code": proc_sizer.returncode,
        "rsa4096_optimal_machines": (sizer_payload.get("cluster_sizing") or {}).get("optimal_machines"),
        "scratch_dir_used": "~/toolchains/tmp/linter_verify",
    }


def main() -> int:
    t_start = time.perf_counter()

    buggy_cases = build_buggy_test_cases()
    clean_cases = build_clean_test_cases()

    buggy_results: List[Dict[str, Any]] = []
    rules_covered_buggy: set[str] = set()
    sources_covered_buggy: set[str] = set()

    for tc in buggy_cases:
        if tc["kind"] == "openqasm3":
            rep = lint_qasm_str(tc["qasm"], spec=tc["spec"], name=tc["id"])
        else:
            rep = lint_qiskit_circuit(tc["qc"], spec=tc["spec"])

        err_diags = [d for d in rep.diagnostics if d.severity == "ERROR"]
        matched_diag = next(
            (d for d in err_diags if d.rule == tc["expected_rule"] and d.code == tc["expected_code"]),
            None,
        )
        has_witness = matched_diag is not None and matched_diag.counterexample is not None
        ok = (not rep.well_typed) and (matched_diag is not None) and has_witness
        if matched_diag is not None:
            rules_covered_buggy.add(matched_diag.rule)
        sources_covered_buggy.add(rep.source_kind)
        buggy_results.append({
            "id": tc["id"],
            "source_kind": rep.source_kind,
            "expected_rule": tc["expected_rule"],
            "expected_code": tc["expected_code"],
            "well_typed": rep.well_typed,
            "error_count": rep.error_count,
            "matched_rule_and_code": matched_diag is not None,
            "has_concrete_witness": has_witness,
            "counterexample": matched_diag.counterexample if matched_diag else None,
            "elapsed_ms": round(rep.elapsed_ms, 3),
            "verified": ok,
        })

    clean_results: List[Dict[str, Any]] = []
    sources_covered_clean: set[str] = set()
    for tc in clean_cases:
        if tc["kind"] == "openqasm3":
            rep = lint_qasm_str(tc["qasm"], spec=tc["spec"], name=tc["id"])
        else:
            rep = lint_qiskit_circuit(tc["qc"], spec=tc["spec"])
        ok = rep.well_typed and rep.error_count == 0
        sources_covered_clean.add(rep.source_kind)
        clean_results.append({
            "id": tc["id"],
            "source_kind": rep.source_kind,
            "well_typed": rep.well_typed,
            "error_count": rep.error_count,
            "warning_count": rep.warning_count,
            "elapsed_ms": round(rep.elapsed_ms, 3),
            "verified": ok,
        })

    tp_count = sum(1 for r in buggy_results if r["verified"])
    fp_count = sum(1 for r in clean_results if not r["verified"])
    tpr = tp_count / len(buggy_results)
    fpr = fp_count / len(clean_results)

    aer_results = verify_aer_buggy_vs_repaired_pairs()
    aer_all_ok = all(r["verified"] for r in aer_results)

    cluster_summary = verify_convex_m_star_cluster_sizer()
    cli_summary = verify_cli_entrypoints()

    elapsed_sec = time.perf_counter() - t_start
    peak_rss_mb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024.0

    overall_pass = (
        tp_count == len(buggy_results)
        and fp_count == 0
        and set(ALL_SEVEN_RULES).issubset(rules_covered_buggy)
        and {"openqasm3", "qiskit"}.issubset(sources_covered_buggy)
        and {"openqasm3", "qiskit"}.issubset(sources_covered_clean)
        and aer_all_ok
        and cluster_summary["all_presets_match"]
        and cluster_summary["sequential_m1_fallback_verified"]
        and cluster_summary["ucurve_knee_pruning_verified"]
        and cli_summary["cli_verified"]
    )

    report_payload: Dict[str, Any] = {
        "overall_pass": overall_pass,
        "unified_judgment": "Gamma_in |- t : Q_e(A) -| Gamma_out",
        "projected_rules": list(ALL_SEVEN_RULES),
        "summary_metrics": {
            "buggy_circuits_tested": len(buggy_results),
            "buggy_true_positives": tp_count,
            "true_positive_rate": round(tpr, 6),
            "clean_circuits_tested": len(clean_results),
            "clean_false_positives": fp_count,
            "false_positive_rate": round(fpr, 6),
            "rules_covered_by_buggy_witnesses": sorted(rules_covered_buggy),
            "input_formats_verified": sorted(sources_covered_buggy | sources_covered_clean),
            "aer_statevector_pairs_verified": sum(1 for r in aer_results if r["verified"]),
            "aer_statevector_pairs_total": len(aer_results),
            "cluster_presets_verified": cluster_summary["presets_verified"],
            "cluster_presets_total": cluster_summary["presets_total"],
            "cli_checks_passed": cli_summary["cli_verified"],
            "wall_clock_sec": round(elapsed_sec, 4),
            "peak_rss_mb": round(peak_rss_mb, 2),
        },
        "buggy_circuit_results": buggy_results,
        "clean_circuit_results": clean_results,
        "aer_statevector_verification": aer_results,
        "convex_m_star_cluster_sizing": cluster_summary,
        "cli_verification": cli_summary,
    }

    artifact_path = REPO_ROOT / "reproducers" / "artifacts" / "lakefillq_python_qasm_linter_report.json"
    artifact_path.parent.mkdir(parents=True, exist_ok=True)
    artifact_path.write_text(json.dumps(report_payload, indent=2) + "\n", encoding="utf-8")

    print(
        f"[LakefillQ Python/QASM/Qiskit Linter Verification] overall_pass={overall_pass} | "
        f"TP={tp_count}/{len(buggy_results)} (TPR={tpr:.1%}) | "
        f"FP={fp_count}/{len(clean_results)} (FPR={fpr:.1%}) | "
        f"Aer={sum(1 for r in aer_results if r['verified'])}/{len(aer_results)} | "
        f"Cluster={cluster_summary['presets_verified']}/{cluster_summary['presets_total']} | "
        f"CLI={cli_summary['cli_verified']} | "
        f"time={elapsed_sec:.2f}s | peak_rss={peak_rss_mb:.1f} MB"
    )
    if not overall_pass:
        for r in buggy_results:
            if not r["verified"]:
                print("  FAILED BUGGY CASE:", r)
        for r in clean_results:
            if not r["verified"]:
                print("  FAILED CLEAN CASE:", r)
        for r in aer_results:
            if not r["verified"]:
                print("  FAILED AER PAIR:", r)
        if not cluster_summary["all_presets_match"]:
            print("  FAILED CLUSTER PRESET:", cluster_summary)
        if not cli_summary["cli_verified"]:
            print("  FAILED CLI:", cli_summary)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
