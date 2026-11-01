#!/usr/bin/env python3
"""End-to-end verifier for the unified `#lang lakefillq` reader and `lakefillqc` driver.

Exercises the complete intrinsic compiler pipeline (`LakefillQ -> lambda_LFQ_kern ->
RevIR -> MachineISA -> OpenQASM 3.0 & Stim`) across:
  1. Direct `#lang lakefillq` execution (`racket examples/<name>.lfq`) on all 5 examples.
  2. Unified CLI compilation (`compiler/lakefillqc.rkt`) emitting JSON, dynamic
     OpenQASM 3.0 (`h q[a]; m[k] = measure q[a]; if (m[k] == 1) { cz q[c1], q[c2]; } reset q[a];`),
     and Stim stabilizer circuits.
  3. Gate-faithful dynamic OpenQASM 3.0 simulation on Qiskit `AerSimulator`
     (`Fidelity = 1.000000`), `qiskit.qasm3.loads` cross-checking, exhaustive basis
     sweeps (`BP34` `256/256`, `mod13` `169/169`, `BCH(7,4,3)` Early-MBU DQI,
     `Select-SWAP` Berry-Gidney `U4`, `Kawamura RNS-CRT` `15/15` `U2`), and Stim
     `TableauSimulator` + `DetectorErrorModel` verification.
  4. All 7 ill-typed `#lang lakefillq` programs (`U1`, `U2`, `U3`, `U4`, `Phi1`,
     `Phi2`, `Phi3`) rejected with concrete counterexample witnesses, plus
     counterexample-guided `--repair` restoration of `Phi1`, `Phi2`, and `Phi3`.
  5. Mechanized Lean `4.35.0` proof compilation and strict proof-hygiene audit.
"""

from __future__ import annotations

import json
import math
import os
import pathlib
import random
import re
import subprocess
from typing import Any

import numpy as np
import qiskit.qasm3
import stim
from qiskit import ClassicalRegister, QuantumCircuit, QuantumRegister
from qiskit.quantum_info import DensityMatrix, Statevector, state_fidelity
from qiskit_aer import AerSimulator

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
PERSISTENT_TMP = pathlib.Path("/home/antigravity/toolchains/tmp")
WORKDIR = PERSISTENT_TMP / "lakefillq_verify_work"

RACKET_BIN = "/home/antigravity/toolchains/racket-p36t2/racket/bin/racket"
LEAN_BIN = "/home/antigravity/toolchains/lean4-p36t4/lean-4.35.0-linux/bin/lean"

DRIVER_RKT = REPO_ROOT / "compiler" / "lakefillqc.rkt"
EXAMPLES_DIR = REPO_ROOT / "examples"
LEAN_PROOF = REPO_ROOT / "proofs" / "lakefillq_unified_compiler_elaboration_and_qasm3_proofs.lean"
REPORT_PATH = REPO_ROOT / "reproducers" / "artifacts" / "lakefillq_unified_compiler_report.json"

FIPS197_AES_SBOX = [
    0x63, 0x7C, 0x77, 0x7B, 0xF2, 0x6B, 0x6F, 0xC5, 0x30, 0x01, 0x67, 0x2B, 0xFE, 0xD7, 0xAB, 0x76,
    0xCA, 0x82, 0xC9, 0x7D, 0xFA, 0x59, 0x47, 0xF0, 0xAD, 0xD4, 0xA2, 0xAF, 0x9C, 0xA4, 0x72, 0xC0,
    0xB7, 0xFD, 0x93, 0x26, 0x36, 0x3F, 0xF7, 0xCC, 0x34, 0xA5, 0xE5, 0xF1, 0x71, 0xD8, 0x31, 0x15,
    0x04, 0xC7, 0x23, 0xC3, 0x18, 0x96, 0x05, 0x9A, 0x07, 0x12, 0x80, 0xE2, 0xEB, 0x27, 0xB2, 0x75,
    0x09, 0x83, 0x2C, 0x1A, 0x1B, 0x6E, 0x5A, 0xA0, 0x52, 0x3B, 0xD6, 0xB3, 0x29, 0xE3, 0x2F, 0x84,
    0x53, 0xD1, 0x00, 0xED, 0x20, 0xFC, 0xB1, 0x5B, 0x6A, 0xCB, 0xBE, 0x39, 0x4A, 0x4C, 0x58, 0xCF,
    0xD0, 0xEF, 0xAA, 0xFB, 0x43, 0x4D, 0x33, 0x85, 0x45, 0xF9, 0x02, 0x7F, 0x50, 0x3C, 0x9F, 0xA8,
    0x51, 0xA3, 0x40, 0x8F, 0x92, 0x9D, 0x38, 0xF5, 0xBC, 0xB6, 0xDA, 0x21, 0x10, 0xFF, 0xF3, 0xD2,
    0xCD, 0x0C, 0x13, 0xEC, 0x5F, 0x97, 0x44, 0x17, 0xC4, 0xA7, 0x7E, 0x3D, 0x64, 0x5D, 0x19, 0x73,
    0x60, 0x81, 0x4F, 0xDC, 0x22, 0x2A, 0x90, 0x88, 0x46, 0xEE, 0xB8, 0x14, 0xDE, 0x5E, 0x0B, 0xDB,
    0xE0, 0x32, 0x3A, 0x0A, 0x49, 0x06, 0x24, 0x5C, 0xC2, 0xD3, 0xAC, 0x62, 0x91, 0x95, 0xE4, 0x79,
    0xE7, 0xC8, 0x37, 0x6D, 0x8D, 0xD5, 0x4E, 0xA9, 0x6C, 0x56, 0xF4, 0xEA, 0x65, 0x7A, 0xAE, 0x08,
    0xBA, 0x78, 0x25, 0x2E, 0x1C, 0xA6, 0xB4, 0xC6, 0xE8, 0xDD, 0x74, 0x1F, 0x4B, 0xBD, 0x8B, 0x8A,
    0x70, 0x3E, 0xB5, 0x66, 0x48, 0x03, 0xF6, 0x0E, 0x61, 0x35, 0x57, 0xB9, 0x86, 0xC1, 0x1D, 0x9E,
    0xE1, 0xF8, 0x98, 0x11, 0x69, 0xD9, 0x8E, 0x94, 0x9B, 0x1E, 0x87, 0xE9, 0xCE, 0x55, 0x28, 0xDF,
    0x8C, 0xA1, 0x89, 0x0D, 0xBF, 0xE6, 0x42, 0x68, 0x41, 0x99, 0x2D, 0x0F, 0xB0, 0x54, 0xBB, 0x16,
]


def clean_env() -> dict[str, str]:
    env = dict(os.environ)
    env["TMPDIR"] = str(PERSISTENT_TMP)
    return env


def run_cmd(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=str(REPO_ROOT),
        env=clean_env(),
        capture_output=True,
        text=True,
        check=False,
    )


# =============================================================================
# 1. Gate-Faithful Dynamic OpenQASM 3.0 Parser (`QuantumCircuit` + AST Stream)
# =============================================================================


def parse_openqasm3_ast(qasm_text: str) -> tuple[int, int, list[tuple[Any, ...]]]:
    """Parses emitted dynamic OpenQASM 3.0 text into `(n_qubits, n_clbits, ops)`."""
    raw_lines = [ln.strip() for ln in qasm_text.splitlines() if ln.strip() and not ln.strip().startswith("//")]
    assert raw_lines[0] == "OPENQASM 3.0;", f"Unexpected header: {raw_lines[0]}"
    assert raw_lines[1] == 'include "stdgates.inc";', f"Unexpected include: {raw_lines[1]}"

    n_qubits = 0
    n_clbits = 0
    ops: list[tuple[Any, ...]] = []
    idx = 2
    while idx < len(raw_lines):
        ln = raw_lines[idx]
        m_q = re.fullmatch(r"qubit\[(\d+)\]\s+q;", ln)
        if m_q:
            n_qubits = int(m_q.group(1))
            idx += 1
            continue
        m_c = re.fullmatch(r"bit\[(\d+)\]\s+m;", ln)
        if m_c:
            n_clbits = int(m_c.group(1))
            idx += 1
            continue
        m_1q = re.fullmatch(r"(x|z|s|h|reset)\s+q\[(\d+)\];", ln)
        if m_1q:
            ops.append((m_1q.group(1), int(m_1q.group(2))))
            idx += 1
            continue
        m_rot = re.fullmatch(r"(ry|rz)\(([-+0-9.eE]+)\)\s+q\[(\d+)\];", ln)
        if m_rot:
            ops.append((m_rot.group(1), float(m_rot.group(2)), int(m_rot.group(3))))
            idx += 1
            continue
        m_2q = re.fullmatch(r"(cx|cz|swap)\s+q\[(\d+)\],\s*q\[(\d+)\];", ln)
        if m_2q:
            ops.append((m_2q.group(1), int(m_2q.group(2)), int(m_2q.group(3))))
            idx += 1
            continue
        m_3q = re.fullmatch(r"ccx\s+q\[(\d+)\],\s*q\[(\d+)\],\s*q\[(\d+)\];", ln)
        if m_3q:
            ops.append(("ccx", int(m_3q.group(1)), int(m_3q.group(2)), int(m_3q.group(3))))
            idx += 1
            continue
        m_meas = re.fullmatch(r"m\[(\d+)\]\s*=\s*measure\s+q\[(\d+)\];", ln)
        if m_meas:
            ops.append(("measure", int(m_meas.group(2)), int(m_meas.group(1))))
            idx += 1
            continue
        m_if_inline_cz = re.fullmatch(
            r"if\s*\(m\[(\d+)\]\s*==\s*1\)\s*\{\s*cz\s+q\[(\d+)\],\s*q\[(\d+)\];\s*\}", ln
        )
        if m_if_inline_cz:
            ops.append(
                (
                    "if_cz",
                    int(m_if_inline_cz.group(1)),
                    int(m_if_inline_cz.group(2)),
                    int(m_if_inline_cz.group(3)),
                )
            )
            idx += 1
            continue
        m_if_inline_z = re.fullmatch(
            r"if\s*\(m\[(\d+)\]\s*==\s*1\)\s*\{\s*z\s+q\[(\d+)\];\s*\}", ln
        )
        if m_if_inline_z:
            ops.append(("if_z", int(m_if_inline_z.group(1)), int(m_if_inline_z.group(2))))
            idx += 1
            continue
        m_if_open = re.fullmatch(r"if\s*\(m\[(\d+)\]\s*==\s*1\)\s*\{", ln)
        if m_if_open:
            cl_k = int(m_if_open.group(1))
            body_ln = raw_lines[idx + 1]
            close_ln = raw_lines[idx + 2]
            assert close_ln == "}", f"Expected closing brace after {body_ln}, got {close_ln}"
            m_if_cz = re.fullmatch(r"cz\s+q\[(\d+)\],\s*q\[(\d+)\];", body_ln)
            m_if_z = re.fullmatch(r"z\s+q\[(\d+)\];", body_ln)
            if m_if_cz:
                ops.append(("if_cz", cl_k, int(m_if_cz.group(1)), int(m_if_cz.group(2))))
            elif m_if_z:
                ops.append(("if_z", cl_k, int(m_if_z.group(1))))
            else:
                raise ValueError(f"Unsupported conditional body in OpenQASM 3.0: {body_ln}")
            idx += 3
            continue
        raise ValueError(f"Unrecognized OpenQASM 3.0 line: {ln}")

    return n_qubits, n_clbits, ops


def build_dynamic_qiskit_circuit(n_qubits: int, n_clbits: int, ops: list[tuple[Any, ...]]) -> QuantumCircuit:
    """Builds a Qiskit `QuantumCircuit` with real `if_test` dynamic feedforward."""
    qreg = QuantumRegister(n_qubits, "q")
    creg = ClassicalRegister(max(1, n_clbits), "m")
    qc = QuantumCircuit(qreg, creg)
    for op in ops:
        tag = op[0]
        if tag == "x":
            qc.x(qreg[op[1]])
        elif tag == "z":
            qc.z(qreg[op[1]])
        elif tag == "s":
            qc.s(qreg[op[1]])
        elif tag == "h":
            qc.h(qreg[op[1]])
        elif tag == "reset":
            qc.reset(qreg[op[1]])
        elif tag == "ry":
            qc.ry(op[1], qreg[op[2]])
        elif tag == "rz":
            qc.rz(op[1], qreg[op[2]])
        elif tag == "cx":
            qc.cx(qreg[op[1]], qreg[op[2]])
        elif tag == "cz":
            qc.cz(qreg[op[1]], qreg[op[2]])
        elif tag == "swap":
            qc.swap(qreg[op[1]], qreg[op[2]])
        elif tag == "ccx":
            qc.ccx(qreg[op[1]], qreg[op[2]], qreg[op[3]])
        elif tag == "measure":
            qc.measure(qreg[op[1]], creg[op[2]])
        elif tag == "if_cz":
            with qc.if_test((creg[op[1]], 1)):
                qc.cz(qreg[op[2]], qreg[op[3]])
        elif tag == "if_z":
            with qc.if_test((creg[op[1]], 1)):
                qc.z(qreg[op[2]])
        else:
            raise ValueError(f"Unhandled op tag: {op}")
    return qc


def eval_qfree_qasm3_on_basis(
    n_qubits: int,
    n_clbits: int,
    ops: list[tuple[Any, ...]],
    init_bits: dict[int, int],
    rng: random.Random,
) -> tuple[list[int], int]:
    """Executes basis-preserving + Hadamard-dual `M_X` QASM3 stream with exact quantum phase tracking.

    Every `h q[a]; m[k] = measure q[a];` where `q[a]` holds basis bit `b_a` samples outcome
    `mk in {0, 1}`, kicks back quantum phase sign `(-1)^(mk & b_a)`, and collapses `q[a] = mk`
    until `reset q[a];` returns `q[a] = 0`. Returns `(final_qubit_bits, phase_sign_bit)`.
    """
    q = [0] * n_qubits
    for w, val in init_bits.items():
        q[w] = val & 1
    m = [0] * max(1, n_clbits)
    sign_bit = 0
    idx = 0
    while idx < len(ops):
        op = ops[idx]
        tag = op[0]
        if tag == "x":
            q[op[1]] ^= 1
            idx += 1
        elif tag == "z":
            sign_bit ^= q[op[1]]
            idx += 1
        elif tag == "cx":
            q[op[2]] ^= q[op[1]]
            idx += 1
        elif tag == "cz":
            sign_bit ^= q[op[1]] & q[op[2]]
            idx += 1
        elif tag == "swap":
            q[op[1]], q[op[2]] = q[op[2]], q[op[1]]
            idx += 1
        elif tag == "ccx":
            q[op[3]] ^= q[op[1]] & q[op[2]]
            idx += 1
        elif tag == "reset":
            q[op[1]] = 0
            idx += 1
        elif (
            tag == "h"
            and idx + 1 < len(ops)
            and ops[idx + 1][0] == "measure"
            and ops[idx + 1][1] == op[1]
        ):
            anc = op[1]
            cl_k = ops[idx + 1][2]
            mk = rng.randint(0, 1)
            sign_bit ^= mk & q[anc]
            q[anc] = mk
            m[cl_k] = mk
            idx += 2
        elif tag == "if_cz":
            if m[op[1]] == 1:
                sign_bit ^= q[op[2]] & q[op[3]]
            idx += 1
        elif tag == "if_z":
            if m[op[1]] == 1:
                sign_bit ^= q[op[2]]
            idx += 1
        else:
            raise ValueError(f"Non-qfree op encountered in basis evaluator at {idx}: {op}")
    return q, sign_bit


# =============================================================================
# 2. Five Positive `#lang lakefillq` Examples: Compilation, Aer, & Stim
# =============================================================================


def compile_and_check_common(example_filename: str) -> tuple[dict[str, Any], str, str, QuantumCircuit]:
    lfq_path = EXAMPLES_DIR / example_filename

    # 1. Direct `#lang lakefillq` execution (`racket examples/<name>.lfq`):
    direct_proc = run_cmd([RACKET_BIN, str(lfq_path)])
    assert direct_proc.returncode == 0, (
        f"Direct `#lang lakefillq` run failed on {example_filename}: "
        f"{direct_proc.stdout}\n{direct_proc.stderr}"
    )
    direct_json = json.loads(direct_proc.stdout)
    assert direct_json["well_typed"] is True
    assert direct_json["residual_surface_forms"] == 0
    assert direct_json["annotation_free_flags"] == 0

    # 2. CLI `compiler/lakefillqc.rkt` execution emitting `.qasm`, `.stim`, and JSON:
    qasm_out = WORKDIR / f"{example_filename}.qasm"
    stim_out = WORKDIR / f"{example_filename}.stim"
    cli_proc = run_cmd(
        [
            RACKET_BIN,
            str(DRIVER_RKT),
            "--input",
            str(lfq_path),
            "--emit-qasm3",
            str(qasm_out),
            "--emit-stim",
            str(stim_out),
            "--emit-json",
        ]
    )
    assert cli_proc.returncode == 0, (
        f"CLI `lakefillqc` failed on {example_filename}: {cli_proc.stdout}\n{cli_proc.stderr}"
    )
    meta = json.loads(cli_proc.stdout)
    assert meta == direct_json, f"Direct vs CLI metadata mismatch on {example_filename}"

    qasm_text = qasm_out.read_text()
    stim_text = stim_out.read_text()

    # Cross-check Qiskit OpenQASM 3.0 standard parser (`if (m[k] == true)` boolean coercion):
    qc_via_qasm3_loads = qiskit.qasm3.loads(qasm_text.replace("== 1)", "== true)"))
    assert qc_via_qasm3_loads.num_qubits == meta["physical_qubits"]

    # Build gate-faithful dynamic Qiskit circuit directly from `if (m[k] == 1)` OpenQASM 3.0 text:
    nq, nc, ops = parse_openqasm3_ast(qasm_text)
    assert nq == meta["physical_qubits"]
    assert nc == meta["classical_meas_bits"]
    dyn_qc = build_dynamic_qiskit_circuit(nq, nc, ops)

    # Verify Stim stabilizer execution (`TableauSimulator` + `DetectorErrorModel`):
    sc = stim.Circuit(stim_text)
    tab_sim = stim.TableauSimulator()
    tab_sim.do(sc)
    dem = sc.detector_error_model(decompose_errors=True)
    meta["stim_verification"] = {
        "parsed_ok": True,
        "num_qubits": sc.num_qubits,
        "num_detectors": sc.num_detectors,
        "dem_error_mechanisms": len(dem),
    }
    return meta, qasm_text, stim_text, dyn_qc


def verify_aes_sbox_bp34() -> dict[str, Any]:
    meta, qasm_text, _, dyn_qc = compile_and_check_common("aes_sbox_bp34.lfq")
    assert meta["forward_temp_and_count"] == 34
    assert meta["uncompute_ccx_count"] == 0
    assert meta["mbu_erasure_count"] == 34
    assert meta["virtual_wires"] == 50
    assert meta["physical_qubits"] == 41
    assert meta["chordal_recycled_wires"] == 9
    assert "if (m[0] == 1) { cz " in qasm_text

    nq, nc, ops = parse_openqasm3_ast(qasm_text)
    rng = random.Random(20261029)

    # 1. Exhaustive `256/256` FIPS-197 S-box sweep with random mid-circuit `M_X` trajectories:
    exact_matches = 0
    for byte_val in range(256):
        init_bits = {b: (byte_val >> b) & 1 for b in range(8)}
        final_q, sign_bit = eval_qfree_qasm3_on_basis(nq, nc, ops, init_bits, rng)
        in_after = sum(final_q[b] << b for b in range(8))
        out_byte = sum(final_q[8 + b] << b for b in range(8))
        scratch_clean = all(final_q[w] == 0 for w in range(16, nq))
        if in_after == byte_val and out_byte == FIPS197_AES_SBOX[byte_val] and scratch_clean and sign_bit == 0:
            exact_matches += 1
    assert exact_matches == 256, f"Expected 256/256 AES S-box matches, got {exact_matches}"

    # 2. Genuine quantum superposition execution on Qiskit `AerSimulator(method='matrix_product_state')`:
    #    Prepare `(1/2)(|0x00> + |0x01> + |0x02> + |0x03>)` on `q[0..1]`, execute the full
    #    41-qubit dynamic OpenQASM 3.0 circuit (`34` mid-circuit `M_X` + `if_test` `cz` + `reset`),
    #    coherently uncompute `S(x)` from `q[8..15]`, and measure reduced density-matrix fidelity
    #    on `q[0..1]` against `|++><++|` (`1.000000` iff all amplitudes, scratch resets, and all
    #    34 dynamic quantum phase kickbacks cancel identically!).
    sup_qc = QuantumCircuit(dyn_qc.qregs[0], dyn_qc.cregs[0])
    sup_qc.h(0)
    sup_qc.h(1)
    sup_qc.compose(dyn_qc, inplace=True)
    for x_val in range(4):
        s_val = FIPS197_AES_SBOX[x_val]
        if (x_val & 1) == 0:
            sup_qc.x(0)
        if ((x_val >> 1) & 1) == 0:
            sup_qc.x(1)
        for bit_idx in range(8):
            if (s_val >> bit_idx) & 1:
                sup_qc.ccx(0, 1, 8 + bit_idx)
        if ((x_val >> 1) & 1) == 0:
            sup_qc.x(1)
        if (x_val & 1) == 0:
            sup_qc.x(0)
    sup_qc.save_density_matrix(qubits=[0, 1])

    aer_mps = AerSimulator(method="matrix_product_state")
    aer_res = aer_mps.run(sup_qc, shots=1).result()
    rho_01 = DensityMatrix(aer_res.data(0)["density_matrix"])
    target_plus_plus = Statevector.from_label("++")
    fid = float(state_fidelity(rho_01, target_plus_plus))
    assert abs(fid - 1.0) < 1e-9, f"AES S-box Aer superposition fidelity {fid} != 1.0"

    # Also verify classic FIPS-197 vector `S(0x53) = 0xED` directly on `AerSimulator`:
    vec_qc = QuantumCircuit(dyn_qc.qregs[0], dyn_qc.cregs[0])
    for b in range(8):
        if (0x53 >> b) & 1:
            vec_qc.x(b)
    vec_qc.compose(dyn_qc, inplace=True)
    out_creg = ClassicalRegister(8, "sbox_out")
    vec_qc.add_register(out_creg)
    for b in range(8):
        vec_qc.measure(8 + b, out_creg[b])
    counts = aer_mps.run(vec_qc, shots=8).result().get_counts()
    for bitstr in counts:
        out_bits = bitstr.split()[0]
        assert int(out_bits, 2) == 0xED, f"Expected S(0x53)=0xED on Aer, got {hex(int(out_bits, 2))}"

    meta["verification"] = {
        "classical_vectors_verified": "256/256",
        "fips197_0x53_to_0xed_aer": True,
        "aer_superposition_fidelity": round(fid, 6),
    }
    return meta


def verify_mod13_adder_mbu() -> dict[str, Any]:
    meta, qasm_text, _, dyn_qc = compile_and_check_common("mod13_adder_mbu.lfq")
    assert meta["forward_temp_and_count"] == 9
    assert meta["uncompute_ccx_count"] == 0
    assert meta["mbu_erasure_count"] == 9
    assert meta["physical_qubits"] == 21

    nq, nc, ops = parse_openqasm3_ast(qasm_text)
    rng = random.Random(131313)

    # 1. Exhaustive `169/169` `(a, b) in [0..12]^2` modular addition sweep:
    exact_pairs = 0
    for a in range(13):
        for b in range(13):
            init_bits = {i: (a >> i) & 1 for i in range(4)}
            init_bits.update({4 + i: (b >> i) & 1 for i in range(4)})
            final_q, sign_bit = eval_qfree_qasm3_on_basis(nq, nc, ops, init_bits, rng)
            a_after = sum(final_q[i] << i for i in range(4))
            b_after = sum(final_q[4 + i] << i for i in range(4))
            out_val = sum(final_q[8 + i] << i for i in range(4))
            scratch_clean = all(final_q[w] == 0 for w in range(12, nq))
            if a_after == a and b_after == b and out_val == (a + b) % 13 and scratch_clean and sign_bit == 0:
                exact_pairs += 1
    assert exact_pairs == 169, f"Expected 169/169 mod-13 pairs, got {exact_pairs}"

    # 2. Quantum superposition across modular wraparound `(a, b) in {(4, 8), (5, 8), (4, 9), (5, 9)}`
    #    (`12, 0, 0, 1 mod 13`!): `a = 4 + q0` (`a2=1, a0=q0`), `b = 8 + q1` (`b3=1, b0=q1`).
    sup_qc = QuantumCircuit(dyn_qc.qregs[0], dyn_qc.cregs[0])
    sup_qc.x(2)  # a += 4
    sup_qc.x(7)  # b += 8
    sup_qc.h(0)  # a0 in |+> -> a in {4, 5}
    sup_qc.h(4)  # b0 in |+> -> b in {8, 9}
    sup_qc.compose(dyn_qc, inplace=True)
    for a0_bit in (0, 1):
        for b0_bit in (0, 1):
            expected_sum = ((4 + a0_bit) + (8 + b0_bit)) % 13
            if a0_bit == 0:
                sup_qc.x(0)
            if b0_bit == 0:
                sup_qc.x(4)
            for r in range(4):
                if (expected_sum >> r) & 1:
                    sup_qc.ccx(0, 4, 8 + r)
            if b0_bit == 0:
                sup_qc.x(4)
            if a0_bit == 0:
                sup_qc.x(0)
    sup_qc.save_density_matrix(qubits=[0, 4])

    aer_mps = AerSimulator(method="matrix_product_state")
    rho = DensityMatrix(aer_mps.run(sup_qc, shots=1).result().data(0)["density_matrix"])
    fid = float(state_fidelity(rho, Statevector.from_label("++")))
    assert abs(fid - 1.0) < 1e-9, f"mod13 Aer superposition fidelity {fid} != 1.0"

    meta["verification"] = {
        "classical_pairs_verified": "169/169",
        "aer_superposition_fidelity": round(fid, 6),
    }
    return meta


def verify_early_mbu_dqi_bch7() -> dict[str, Any]:
    meta, _, _, dyn_qc = compile_and_check_common("early_mbu_dqi_bch7.lfq")
    assert meta["virtual_wires"] == 24
    assert meta["physical_qubits"] == 10
    assert meta["chordal_recycled_wires"] == 14
    assert meta["uncompute_ccx_count"] == 0

    # Exact full-channel `AerSimulator(method='density_matrix')` simulation on all 10 qubits
    # (integrating analytically over all `2^21` mid-circuit `M_X` + `if_test` outcomes!):
    qc_dm = dyn_qc.copy()
    qc_dm.save_density_matrix(qubits=[7, 8, 9])
    sim_dm = AerSimulator(method="density_matrix")
    rho_syn = DensityMatrix(sim_dm.run(qc_dm, shots=1).result().data(0)["density_matrix"])

    # Analytical DQI output statevector on `syn3 = (q7, q8, q9)` (`w0 = sqrt(7/32)`,
    # `w1 = sqrt(25/32)`, `b_mask = 44`, syndrome columns `1..7` -> Walsh-Hadamard):
    w0 = math.sqrt(7.0 / 32.0)
    w1 = math.sqrt(25.0 / 32.0)
    b_mask = 44
    syn_amps = np.zeros(8, dtype=complex)
    syn_amps[0] = w0
    for j in range(7):
        col = j + 1
        sign = -1.0 if ((b_mask >> j) & 1) else 1.0
        syn_amps[col] = sign * (w1 / math.sqrt(7.0))
    # Apply 3-qubit Walsh-Hadamard `H^{\otimes 3}`:
    target_amps = np.zeros(8, dtype=complex)
    for x_idx in range(8):
        acc = 0.0 + 0.0j
        for s_idx in range(8):
            dot = bin(x_idx & s_idx).count("1") & 1
            acc += ((-1.0) ** dot) * syn_amps[s_idx]
        target_amps[x_idx] = acc / math.sqrt(8.0)
    target_sv = Statevector(target_amps)

    fid = float(state_fidelity(rho_syn, target_sv))
    purity = float(np.real(rho_syn.purity()))
    probs = rho_syn.probabilities_dict()
    p_xstar_5 = float(probs.get("101", 0.0))  # x* = 5 = 0b101 on (q9, q8, q7)

    assert abs(fid - 1.0) < 1e-9, f"Early-MBU DQI fidelity {fid} != 1.0"
    assert abs(purity - 1.0) < 1e-9, f"Early-MBU DQI purity {purity} != 1.0"
    assert abs(p_xstar_5 - (4.0 / 7.0)) < 1e-9, f"Expected P(x*=5)=4/7, got {p_xstar_5}"

    meta["verification"] = {
        "aer_density_matrix_fidelity": round(fid, 6),
        "output_purity": round(purity, 6),
        "prob_optimal_xstar_5": round(p_xstar_5, 6),
        "analytical_4_over_7": round(4.0 / 7.0, 6),
    }
    return meta


def verify_select_swap_qroam_u4() -> dict[str, Any]:
    meta, _, _, dyn_qc = compile_and_check_common("select_swap_qroam_u4.lfq")
    assert meta["virtual_wires"] == 25
    assert meta["physical_qubits"] == 19
    assert meta["chordal_recycled_wires"] == 6

    # Execute dynamic 19-qubit `Select-SWAP` + Berry-Gidney `5-TempAND` phase uncompute
    # on `AerSimulator(method='matrix_product_state')` across multiple independent runs,
    # verifying `addr` (`q[0..3]`) returns deterministically to `|0000>` with fidelity `1.000000`!
    aer_mps = AerSimulator(method="matrix_product_state")
    fids: list[float] = []
    target_zero4 = Statevector.from_label("0000")
    for seed_offset in range(8):
        qc_run = dyn_qc.copy()
        qc_run.save_density_matrix(qubits=[0, 1, 2, 3])
        res = aer_mps.run(qc_run, shots=1, seed_simulator=7000 + seed_offset).result()
        rho_addr = DensityMatrix(res.data(0)["density_matrix"])
        fids.append(float(state_fidelity(rho_addr, target_zero4)))

    min_fid = min(fids)
    assert abs(min_fid - 1.0) < 1e-9, f"Select-SWAP Berry-Gidney U4 fidelity {min_fid} != 1.0"

    meta["verification"] = {
        "berry_gidney_uncompute_temp_ands": 5,
        "sawtooth_baseline_temp_ands": 14,
        "aer_interference_fidelity": round(min_fid, 6),
    }
    return meta


def verify_kawamura_rns_crt_u2() -> dict[str, Any]:
    meta, qasm_text, _, dyn_qc = compile_and_check_common("kawamura_rns_crt_u2.lfq")
    assert meta["chordal_recycled_wires"] == 3
    assert meta["quantum_phase_residuals"] == 0

    nq, nc, ops = parse_openqasm3_ast(qasm_text)
    aer_mps = AerSimulator(method="matrix_product_state")

    # 1. Verify all `15/15` valid `RNS(3, 5)` residues `(r3, r5) in Z_3 x Z_5` erase
    #    `q_crt = (q[3], q[4]) -> |00>` (`Law U2` `Canonical`) and return `ctrl = q[0] -> |0>`
    #    with fidelity `1.000000` on `AerSimulator`:
    canonical_count = 0
    for r3 in range(3):
        for r5 in range(5):
            qc_r = QuantumCircuit(dyn_qc.qregs[0], dyn_qc.cregs[0])
            if r3 & 1:
                qc_r.x(1)
            if (r3 >> 1) & 1:
                qc_r.x(2)
            for b in range(3):
                if (r5 >> b) & 1:
                    qc_r.x(5 + b)
            qc_r.compose(dyn_qc, inplace=True)
            qc_r.save_density_matrix(qubits=[0, 3, 4])
            rho = DensityMatrix(aer_mps.run(qc_r, shots=1).result().data(0)["density_matrix"])
            fid_r = float(state_fidelity(rho, Statevector.from_label("000")))
            if abs(fid_r - 1.0) < 1e-9:
                canonical_count += 1
    assert canonical_count == 15, f"Expected 15/15 RNS residues canonicalized, got {canonical_count}"

    # 2. Coherent superposition across 4 RNS residues `(r3, r5) in {(0, 0), (1, 0), (0, 3), (1, 3)}`
    #    spanning distinct CRT overflow quotients (`q_crt = 0` vs `q_crt = 1`!):
    #    `r3 = q1` (`q1 in |+>`, `q2 = 0`), `r5 = 3 * q5` (`q5 in |+>`, `CX q5 -> q6`).
    sup_qc = QuantumCircuit(dyn_qc.qregs[0], dyn_qc.cregs[0])
    sup_qc.h(1)
    sup_qc.h(5)
    sup_qc.cx(5, 6)
    sup_qc.compose(dyn_qc, inplace=True)
    sup_qc.cx(5, 6)
    sup_qc.save_density_matrix(qubits=[0, 1, 3, 4, 5])
    rho_sup = DensityMatrix(aer_mps.run(sup_qc, shots=1).result().data(0)["density_matrix"])
    # Qubit order `[q0, q1, q3, q4, q5]` -> state_label bitstring is `q5 q4 q3 q1 q0` = `"+00+0"`!
    target_sup = Statevector.from_label("+00+0")
    fid_sup = float(state_fidelity(rho_sup, target_sup))
    assert abs(fid_sup - 1.0) < 1e-9, f"Kawamura RNS-CRT superposition fidelity {fid_sup} != 1.0"

    meta["verification"] = {
        "rns_residues_canonicalized": "15/15",
        "aer_superposition_fidelity": round(fid_sup, 6),
    }
    return meta


# =============================================================================
# 3. Seven Negative Ill-Typed `#lang lakefillq` Programs (`U1-U4`, `Phi1-Phi3`)
# =============================================================================

NEGATIVE_LFQ_PROGRAMS: list[tuple[str, str, bool, str]] = [
    (
        "neg_u1_erase_by.lfq",
        "U1-EraseBy",
        False,
        """#lang lakefillq
(target-profile ideal)
(defqfree (bad-u1 #:wires ([a '(0 1)] [out '(2)]) #:scratch ([sc '(3)]))
  ;; Violates Law U1: forward TempAND allocates `sc[0] = q[3]` and forgets to erase it!
  (erase-by
   (seq (temp-and 0 1 3) (cx 3 2))
   skip
   '(3)))
""",
    ),
    (
        "neg_u2_canonical.lfq",
        "U2-Canonical",
        False,
        """#lang lakefillq
(target-profile ideal)
(defq (bad-u2
       #:wires ([ctrl '(0)] [r '(1)] [q-crt '(2)])
       #:scratch ()
       #:domain (domain-guard (g-all-zero '(0 2))))
  ;; Violates Law U2: `q_crt = q[2]` retains history-dependent overflow `q[0] & q[1]`!
  (h 0)
  (ccx 0 1 2)
  (canonicalize-quotient '(2) skip)
  (h 0))
""",
    ),
    (
        "neg_u3_total_on.lfq",
        "U3-TotalOn",
        False,
        """#lang lakefillq
(target-profile ideal)
(defqfree (bad-u3
           #:wires ([r3 '(0 1)] [out '(2)])
           #:scratch ()
           #:domain (domain-guard (g-not (g-and (g-wire 0) (g-wire 1)))))
  ;; Violates Law U3: omits valid residue `r3 = 2` (`(0, 1)`) from `qmatch`!
  (qmatch
   ([(g-eq-bits '(0 1) '(0 0)) skip]
    [(g-eq-bits '(0 1) '(1 0)) (x 2)])))
""",
    ),
    (
        "neg_u4_qtainted.lfq",
        "U4-QTainted",
        False,
        """#lang lakefillq
(target-profile ideal)
(defq (bad-u4 #:wires ([c '(0 1)] [out '(2)]) #:scratch ([anc '(3)]))
  ;; Violates Law U4: omits `cond-cz` after `mid-meas-x`, leaving `(-1)^(m * q0 * q1)` phase taint
  ;; before Hadamard interference on `q[0]`!
  (h 0)
  (h 1)
  (erase-by
   (seq (temp-and 0 1 3) (cx 3 2))
   (mid-meas-x 3 'm_leak)
   '(3))
  (h 0))
""",
    ),
    (
        "neg_phi1_decoherence.lfq",
        "Phi1-DecoherenceAction",
        True,
        """#lang lakefillq
(target-profile bluvstein-aod)
(defq (bad-phi1 #:wires ([c '(0 1)] [out '(2)]) #:scratch ([anc '(3)]))
  ;; Violates Grade Phi1 on `bluvstein-aod` (`5000 ns > 1500 ns` budget): unshielded `mid-meas-x`!
  (erase-by
   (seq (temp-and 0 1 3) (cx 3 2))
   (seq (mid-meas-x-unshielded 3 'm_unshielded)
        (cond-cz 'm_unshielded 0 1))
   '(3)))
""",
    ),
    (
        "neg_phi2_exclusion.lfq",
        "Phi2-ExclusionGraph",
        True,
        """#lang lakefillq
(target-profile bluvstein-aod)
(defq (bad-phi2 #:wires ([w '(0 1 2 3)]) #:scratch ())
  ;; Violates Grade Phi2: adjacent parallel CZ gates (`|1 - 2| * 5 um = 5 um < 8 um` Rydberg blockade)!
  (par-wires
   (cz 0 1)
   (cz 2 3)))
""",
    ),
    (
        "neg_phi3_fault_exponent.lfq",
        "Phi3-FaultExponent",
        True,
        """#lang lakefillq
(target-profile bb-qldpc)
(defq (bad-phi3 #:wires ([p '(0 1 2 3 4)]) #:scratch ())
  ;; Violates Grade Phi3: hook-aligned stabilizer schedule halves `d_eff = 3 < 5` AND float64 `k = 60 >= 53`!
  (syndrome-plaquette '(0 1 2 3 4) 5 #:schedule 'aligned)
  (rz-dyadic 0 60 #:precision 'float64 #:distance 5))
""",
    ),
]


def verify_negative_and_repair_cases() -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    for fname, expected_code, is_phys_repairable, src in NEGATIVE_LFQ_PROGRAMS:
        fpath = WORKDIR / fname
        fpath.write_text(src)

        proc = run_cmd([RACKET_BIN, str(DRIVER_RKT), "--input", str(fpath), "--emit-json"])
        assert proc.returncode == 1, f"Expected {fname} to be rejected (rc=1), got rc={proc.returncode}"
        js = json.loads(proc.stdout)
        assert js["well_typed"] is False
        codes = [v["code"] for v in js["violations"]]
        assert expected_code in codes, f"Expected {expected_code} in {codes} for {fname}"
        matched_v = next(v for v in js["violations"] if v["code"] == expected_code)
        assert isinstance(matched_v["witness"], dict) and len(matched_v["witness"]) > 0

        entry: dict[str, Any] = {
            "program": fname,
            "expected_violation": expected_code,
            "rejected": True,
            "detected_codes": codes,
            "counterexample_witness": matched_v["witness"],
        }

        # Verify `--repair` restores all 3 `QPhysGrade` (`Phi1`, `Phi2`, `Phi3`) programs
        # to `well_typed == True`, while NEVER masking logical `QSub` (`U1-U4`) bugs!
        rep_proc = run_cmd(
            [RACKET_BIN, str(DRIVER_RKT), "--input", str(fpath), "--repair", "--emit-json"]
        )
        rep_js = json.loads(rep_proc.stdout)
        if is_phys_repairable:
            assert rep_proc.returncode == 0, f"Expected --repair to fix {fname}: {rep_proc.stdout}"
            assert rep_js["well_typed"] is True
            assert len(rep_js["repairs_applied"]) >= 1
            entry["repaired_well_typed"] = True
            entry["repairs_applied"] = rep_js["repairs_applied"]
        else:
            assert rep_proc.returncode == 1, f"Logical bug {fname} must stay rejected under --repair"
            assert rep_js["well_typed"] is False
            entry["repaired_well_typed"] = False

        results.append(entry)
    return results


# =============================================================================
# 4. Mechanized Lean 4.35.0 Compilation & Strict Proof-Hygiene Audit
# =============================================================================


def verify_lean_proofs() -> dict[str, Any]:
    lean_src = LEAN_PROOF.read_text()
    proc = run_cmd([LEAN_BIN, str(LEAN_PROOF)])
    assert proc.returncode == 0, f"Lean 4.35.0 failed:\n{proc.stdout}\n{proc.stderr}"
    assert proc.stdout.strip() == "" and proc.stderr.strip() == "", (
        f"Lean emitted unexpected warnings:\n{proc.stdout}\n{proc.stderr}"
    )

    code_lines = []
    in_block_comment = False
    for raw_ln in lean_src.splitlines():
        s = raw_ln
        if "/-" in s and "-/" in s:
            s = re.sub(r"/-.*?-/", "", s)
        elif "/-" in s:
            in_block_comment = True
            continue
        elif "-/" in s:
            in_block_comment = False
            continue
        if in_block_comment:
            continue
        s = s.split("--")[0]
        code_lines.append(s)
    stripped_code = "\n".join(code_lines)

    sorry_count = len(re.findall(r"\bsorry\b", stripped_code))
    axiom_count = len(re.findall(r"\baxiom\b", stripped_code))
    native_decide_count = len(re.findall(r"\bnative_decide\b", stripped_code))
    wildcard_count = len(re.findall(r"\|\s*_\s*=>", stripped_code))

    assert sorry_count == 0
    assert axiom_count == 0
    assert native_decide_count == 0
    assert wildcard_count == 0

    # Measure `:= by` proof block lengths:
    lines = lean_src.splitlines()
    theorems: list[str] = []
    max_proof_lines = 0
    idx = 0
    while idx < len(lines):
        m_thm = re.match(r"^\s*theorem\s+([A-Za-z0-9_']+)", lines[idx])
        if m_thm:
            theorems.append(m_thm.group(1))
        if ":= by" in lines[idx]:
            start = idx + 1
            end = start
            while end < len(lines) and lines[end].strip() != "" and not re.match(
                r"^\s*(theorem|def|inductive|structure|end|--|/-)\b", lines[end]
            ):
                end += 1
            plen = end - start
            max_proof_lines = max(max_proof_lines, plen)
            assert plen <= 25, f"Proof starting at line {idx + 1} has {plen} > 25 lines"
            idx = end
        else:
            idx += 1

    return {
        "lean_file": str(LEAN_PROOF.relative_to(REPO_ROOT)),
        "lean_compiler": "4.35.0",
        "exit_code": proc.returncode,
        "theorems_proved": theorems,
        "theorem_count": len(theorems),
        "sorry_count": sorry_count,
        "axiom_count": axiom_count,
        "native_decide_count": native_decide_count,
        "wildcard_arm_count": wildcard_count,
        "max_proof_lines": max_proof_lines,
    }


def main() -> None:
    WORKDIR.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)

    positive_results = {
        "aes_sbox_bp34": verify_aes_sbox_bp34(),
        "mod13_adder_mbu": verify_mod13_adder_mbu(),
        "early_mbu_dqi_bch7": verify_early_mbu_dqi_bch7(),
        "select_swap_qroam_u4": verify_select_swap_qroam_u4(),
        "kawamura_rns_crt_u2": verify_kawamura_rns_crt_u2(),
    }
    negative_results = verify_negative_and_repair_cases()
    lean_summary = verify_lean_proofs()

    report = {
        "compiler_driver": "compiler/lakefillqc.rkt",
        "surface_reader": "#lang lakefillq",
        "intrinsic_dialects": ["LakefillQ", "lambda_LFQ_kern", "RevIR", "MachineISA"],
        "logical_laws_qsub": ["U1-EraseBy", "U2-Canonical", "U3-TotalOn", "U4-QTainted"],
        "physical_grades_qphys": [
            "Phi1-DecoherenceAction",
            "Phi2-ExclusionGraph",
            "Phi3-FaultExponent",
        ],
        "positive_programs_verified": len(positive_results),
        "negative_programs_rejected": len(negative_results),
        "all_residual_surface_forms_zero": all(
            m["residual_surface_forms"] == 0 for m in positive_results.values()
        ),
        "all_annotation_free_flags_zero": all(
            m["annotation_free_flags"] == 0 for m in positive_results.values()
        ),
        "positive_benchmarks": positive_results,
        "negative_and_repair_checks": negative_results,
        "mechanized_lean_proofs": lean_summary,
    }

    REPORT_PATH.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(
        json.dumps(
            {
                "status": "ALL_CHECKS_PASSED",
                "positive_programs_verified": len(positive_results),
                "negative_programs_rejected": len(negative_results),
                "lean_theorems_proved": lean_summary["theorem_count"],
                "report_path": str(REPORT_PATH),
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
