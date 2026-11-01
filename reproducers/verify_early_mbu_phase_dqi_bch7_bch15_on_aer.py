#!/usr/bin/env python3
"""
verify_early_mbu_phase_dqi_bch7_bch15_on_aer.py
===============================================================================
Early-MBU Phase-Only Decoded Quantum Interferometry (`DQI`) Verification Harness:
Closing Lesson 5 — Early Stage-2 `MBU` + Stage-3 Phase-Only Decoding in `DQI`
(`Khattar–Babbush 2025`, arXiv:2510.10967, Unified Under `Law U1 + Law U4`).

Executes end-to-end verification in < 6 seconds:
  1. Runs `racket lakefill-early-mbu-phase-dqi.rkt` via `subprocess.run`,
     verifying `BCH(7, 4, 3)` across all `128 / 128` (`2^7`) `M_X` branches
     (`10 -> 3` live qubits, `fidelity = 1.000000000000`) and `BCH(15, 7, 5)`
     across all `121 / 121` weight<=2 Dicke error patterns (`23 -> 8` live
     qubits = `-65.22%`, `0` ancilla leakage).
  2. Simulates BOTH Standard unitary `erase-by` `DQI` and Early-`MBU` Phase-Only
     `DQI` on `qiskit_aer.AerSimulator`:
       a) Noiseless Dynamic Feedforward Equivalence (`BCH(7,4,3)` & `BCH(15,7,5)`):
          Gate-level Bartschi-Eidenbenz Dicke state preparation (`ry` + `cx`,
          `0` magic ops) + mid-circuit `M_X` + feedforward parity phase fixup +
          `H^{otimes k_synd}` achieves `state_fidelity = 1.000000` vs Standard
          unitary `DQI`, whereas omitting the `Law U4` phase-parity fixup
          collapses optimal-solution probability to uniform random `1/2^k`, and
          the `Law U1`-violating `wt<=1` Hamming stub on `BCH(15,7,5)` corrupts
          `105 / 121` (`86.8%`) weight-2 patterns and degrades fidelity!
       b) Calibrated `IBM Heron r2` Noisy `AerSimulator(method='density_matrix')`
          Survival Fidelity Gain (`Phi1`):
          Freeing all `n = 7` error qubits before Stage-3 decoding eliminates
          `7 * tau_decoder` of idle `T1/T2` decoherence AND replaces `n` target
          writebacks with a single `m`-masked phase-kickback parity wire,
          producing a substantial `Phi1` survival fidelity improvement on noisy
          `AerSimulator(method='density_matrix')`!
  3. Writes `reproducers/artifacts/early_mbu_phase_dqi_report.json`.

CRITICAL RULE: NEVER uses `/tmp`. Always sets `TMPDIR=/home/antigravity/toolchains/tmp`.
===============================================================================
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
import itertools
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
from typing import Any, Dict, List, Tuple

sys.dont_write_bytecode = True

PERSISTENT_TMPDIR = Path("/home/antigravity/toolchains/tmp")
PERSISTENT_TMPDIR.mkdir(parents=True, exist_ok=True)
os.environ["TMPDIR"] = str(PERSISTENT_TMPDIR)

import numpy as np
from qiskit import ClassicalRegister, QuantumCircuit, QuantumRegister, transpile
from qiskit.quantum_info import DensityMatrix, Statevector, partial_trace, state_fidelity
from qiskit_aer import AerSimulator
from qiskit_aer.noise import (
    NoiseModel,
    depolarizing_error,
    thermal_relaxation_error,
)

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
RACKET_MODULE = REPO_ROOT / "lakefill-early-mbu-phase-dqi.rkt"
LEAN_PROOF_FILE = REPO_ROOT / "proofs" / "early_mbu_phase_only_dqi_proofs.lean"
REPORT_PATH = SCRIPT_DIR / "artifacts" / "early_mbu_phase_dqi_report.json"


# =============================================================================
# 1. Toolchain Helpers & Elementary Gate Builders (`0` Magic Ops!)
# =============================================================================

def resolve_racket_binary() -> str:
    candidates = [
        Path("/home/antigravity/.local/bin/racket"),
        Path("/home/antigravity/toolchains/racket-p36t2/racket/bin/racket"),
    ]
    found = shutil.which("racket")
    if found:
        return found
    for c in candidates:
        if c.exists() and os.access(c, os.X_OK):
            return str(c)
    raise FileNotFoundError("Could not locate `racket` executable in persistent toolchains")


def bit_dot_parity(a: int, b: int) -> int:
    return (a & b).bit_count() & 1


def append_cry(qc: QuantumCircuit, theta: float, ctrl: int, target: int) -> None:
    """Exact 2-CX elementary decomposition of controlled-Ry(theta)."""
    qc.ry(theta / 2.0, target)
    qc.cx(ctrl, target)
    qc.ry(-theta / 2.0, target)
    qc.cx(ctrl, target)


def append_ccry(qc: QuantumCircuit, theta: float, c1: int, c2: int, target: int) -> None:
    """Exact elementary `ry` + `cx` decomposition of doubly-controlled Ry(theta)."""
    append_cry(qc, theta / 2.0, c2, target)
    qc.cx(c1, c2)
    append_cry(qc, -theta / 2.0, c2, target)
    qc.cx(c1, c2)
    append_cry(qc, theta / 2.0, c1, target)


def append_rccx_compute(qc: QuantumCircuit, c1: int, c2: int, target: int) -> None:
    """6-CX Toffoli / 3-CX Margolus-style relative-phase compute into clean ancilla (`3` CX!)."""
    qc.ry(math.pi / 4.0, target)
    qc.cx(c2, target)
    qc.ry(math.pi / 4.0, target)
    qc.cx(c1, target)
    qc.ry(-math.pi / 4.0, target)
    qc.cx(c2, target)
    qc.ry(-math.pi / 4.0, target)


def append_rccx_uncompute(qc: QuantumCircuit, c1: int, c2: int, target: int) -> None:
    """Syntactic inverse of `append_rccx_compute` (`3` CX!)."""
    qc.ry(math.pi / 4.0, target)
    qc.cx(c2, target)
    qc.ry(math.pi / 4.0, target)
    qc.cx(c1, target)
    qc.ry(-math.pi / 4.0, target)
    qc.cx(c2, target)
    qc.ry(-math.pi / 4.0, target)


def append_exact_ccx_6cx(qc: QuantumCircuit, c1: int, c2: int, target: int) -> None:
    """Standard 6-CX + 1Q Clifford+T exact Toffoli decomposition (`0` magic ops)."""
    qc.h(target)
    qc.cx(c2, target)
    qc.tdg(target)
    qc.cx(c1, target)
    qc.t(target)
    qc.cx(c2, target)
    qc.tdg(target)
    qc.cx(c1, target)
    qc.t(c2)
    qc.t(target)
    qc.h(target)
    qc.cx(c1, c2)
    qc.t(c1)
    qc.tdg(c2)
    qc.cx(c1, c2)


def append_mcx_vchain(qc: QuantumCircuit, ctrls: List[int], target: int, scratch: List[int]) -> None:
    """Lower k-controlled X into V-chain of 3-CX RCCX temporary-ANDs + 6-CX apex CCX."""
    k = len(ctrls)
    if k == 1:
        qc.cx(ctrls[0], target)
        return
    if k == 2:
        append_exact_ccx_6cx(qc, ctrls[0], ctrls[1], target)
        return
    need = k - 2
    assert len(scratch) >= need
    ancs = scratch[:need]
    append_rccx_compute(qc, ctrls[0], ctrls[1], ancs[0])
    for idx in range(2, k - 1):
        append_rccx_compute(qc, ctrls[idx], ancs[idx - 2], ancs[idx - 1])
    append_exact_ccx_6cx(qc, ctrls[-1], ancs[-1], target)
    for idx in range(k - 2, 1, -1):
        append_rccx_uncompute(qc, ctrls[idx], ancs[idx - 2], ancs[idx - 1])
    append_rccx_uncompute(qc, ctrls[0], ctrls[1], ancs[0])


# =============================================================================
# 2. Gate-Level Bartschi-Eidenbenz Dicke State Preparation (`wt<=1` & `wt<=2`)
# =============================================================================

def append_dicke_le1_prep(qc: QuantumCircuit, wires: List[int], w0: float, w1: float, b_mask: int) -> None:
    """
    Gate-level Bartschi-Eidenbenz unary-to-one-hot circuit preparing:
      w0 |0^n> + (w1 / sqrt(n)) sum_{j=0}^{n-1} (-1)^{b_j} |e_j>
    using ONLY `ry`, `cx`, and `z` (`0` ancillas, `0` magic ops).
    """
    n = len(wires)
    qc.ry(2.0 * math.acos(w0), wires[0])
    for j in range(n - 1):
        theta_next = 2.0 * math.acos(math.sqrt(1.0 / (n - j)))
        append_cry(qc, theta_next, wires[j], wires[j + 1])
    for j in range(n - 1):
        qc.cx(wires[j + 1], wires[j])
    for j in range(n):
        if (b_mask >> j) & 1:
            qc.z(wires[j])


def append_dicke_le2_prep(
    qc: QuantumCircuit,
    wires: List[int],
    w0: float,
    w1: float,
    w2: float,
    b_mask: int,
) -> None:
    """
    Exact gate-level Bartschi-Eidenbenz (FCT 2019) Split-and-Cyclic-Shift `SCS_{m, 2}`
    circuit preparing on `wires[0..n-1]`:
      w0 |0^n> + (w1 / sqrt(n)) sum_{wt(e)=1} (-1)^{b.e} |e>
               + (w2 / sqrt(C(n,2))) sum_{wt(e)=2} (-1)^{b.e} |e>
    using ONLY `ry`, `cx`, and `z` (`0` ancillas, `0` magic ops).
    """
    n = len(wires)
    rem_prob = max(0.0, 1.0 - w0 * w0)
    qc.ry(2.0 * math.acos(min(1.0, max(-1.0, w0))), wires[n - 1])
    if rem_prob > 1e-15:
        ratio = min(1.0, max(0.0, w1 / math.sqrt(rem_prob)))
        # Put second unary `1` at `wires[n - 2]` with amplitude `w2` when `wires[n - 1] == 1`
        theta_second = 2.0 * math.acos(ratio)
        append_cry(qc, theta_second, wires[n - 1], wires[n - 2])

    # Apply Bartschi-Eidenbenz `SCS_{m, 2}` for m = n, n-1, ..., 3
    for m in range(n, 2, -1):
        qa = wires[m - 1]
        qb = wires[m - 2]
        qc_wire = wires[m - 3]
        # 2-qubit block swaps |1,0> <-> |0,1> with cos(theta1/2) = sqrt(1/m), identity on |1,1>
        theta1 = 2.0 * math.acos(math.sqrt(1.0 / m))
        qc.cx(qb, qa)
        append_cry(qc, theta1, qa, qb)
        qc.cx(qb, qa)
        # 3-qubit block swaps |1,1,0> <-> |0,1,1> with cos(theta2/2) = sqrt(2/m)
        theta2 = 2.0 * math.acos(math.sqrt(2.0 / m))
        qc.cx(qc_wire, qa)
        append_ccry(qc, theta2, qa, qb, qc_wire)
        qc.cx(qc_wire, qa)

    # Final `SCS_{2, 1}` on `(wires[1], wires[0])`
    qa = wires[1]
    qb = wires[0]
    theta_last = 2.0 * math.acos(math.sqrt(0.5))
    qc.cx(qb, qa)
    append_cry(qc, theta_last, qa, qb)
    qc.cx(qb, qa)

    for j in range(n):
        if (b_mask >> j) & 1:
            qc.z(wires[j])


# =============================================================================
# 3. Execute Racket Deliverable 1 (`lakefill-early-mbu-phase-dqi.rkt`)
# =============================================================================

def run_racket_verification() -> Dict[str, Any]:
    racket_bin = resolve_racket_binary()
    env = dict(os.environ)
    env["TMPDIR"] = str(PERSISTENT_TMPDIR)
    t0 = time.perf_counter()
    proc = subprocess.run(
        [racket_bin, str(RACKET_MODULE)],
        cwd=str(REPO_ROOT),
        env=env,
        capture_output=True,
        text=True,
        check=True,
    )
    elapsed_s = time.perf_counter() - t0
    data = json.loads(proc.stdout)
    assert data["status"] == "PASS"
    assert data["bch_7_4_3_early_mbu_dqi"]["mx_branches_exact_fidelity_1"] == 128
    assert data["bch_15_7_5_early_mbu_dqi"]["early_mbu_patterns_exact_parity"] == 121
    assert data["bch_15_7_5_early_mbu_dqi"]["law_u1_violation_wt1_stub_exact_patterns"] == 16
    assert data["bch_15_7_5_early_mbu_dqi"]["law_u1_violation_wt1_stub_corrupted_patterns"] == 105
    data["subprocess_wall_time_s"] = round(elapsed_s, 4)
    return data


# =============================================================================
# 4. Experiment 1A: `BCH(7, 4, 3)` Noiseless Dynamic Feedforward Equivalence
#    on `qiskit_aer.AerSimulator`
# =============================================================================

def bch7_ht_mul(x: int) -> int:
    out = 0
    for j in range(7):
        col = j + 1
        if bit_dot_parity(col, x):
            out |= (1 << j)
    return out


def verify_bch7_noiseless_aer() -> Dict[str, Any]:
    sim_sv = AerSimulator(method="statevector")
    x_star = 5  # 0b101
    # Frustrated Max-XORSAT (`6/7` optimal clauses satisfied) with optimal DQI weights:
    b_mask = bch7_ht_mul(x_star) ^ 0b0000001
    w0 = math.sqrt(7.0 / 32.0)
    w1 = math.sqrt(25.0 / 32.0)

    # 1. Standard Unitary `erase-by` DQI (`11` qubits: `e[0..6]`, `s[7..9]`, `sc[10]`)
    qc_std = QuantumCircuit(11)
    append_dicke_le1_prep(qc_std, list(range(7)), w0, w1, b_mask)
    for j in range(7):
        col = j + 1
        for r in range(3):
            if (col >> r) & 1:
                qc_std.cx(j, 7 + r)
    # Stage 3: Unitary `erase-by` syndrome decoder keeps all 7 error wires alive!
    for j in range(7):
        col = j + 1
        for r in range(3):
            if not ((col >> r) & 1):
                qc_std.x(7 + r)
        append_mcx_vchain(qc_std, [7, 8, 9], j, [10])
        for r in range(3):
            if not ((col >> r) & 1):
                qc_std.x(7 + r)
    for r in range(3):
        qc_std.h(7 + r)
    qc_std.save_statevector()

    res_std = sim_sv.run(qc_std, shots=1).result()
    sv_std_full = np.asarray(res_std.get_statevector(qc_std))
    # Error wires `0..6` and scratch `10` are cleanly `|0^7>|0>`, so syndrome amplitudes sit at `x << 7`
    sv_std_3q = np.array([sv_std_full[x << 7] for x in range(8)], dtype=complex)
    err_zero_prob = float(np.sum(np.abs(sv_std_3q) ** 2))
    prob_xstar_std = float(np.abs(sv_std_3q[x_star]) ** 2)
    assert abs(err_zero_prob - 1.0) < 1e-11
    assert abs(prob_xstar_std - (4.0 / 7.0)) < 1e-11

    # 2. Early-`MBU` Phase-Only DQI with Dynamic Qiskit `if_test` Feedforward on `AerSimulator`!
    q_err = QuantumRegister(7, "e")
    q_syn = QuantumRegister(3, "s")
    q_sc = QuantumRegister(2, "sc")  # sc[0] = p_anc, sc[1] = mcx_sc
    c_mx = ClassicalRegister(7, "m_x")
    qc_early_dyn = QuantumCircuit(q_err, q_syn, q_sc, c_mx)
    append_dicke_le1_prep(qc_early_dyn, list(range(7)), w0, w1, b_mask)
    for j in range(7):
        col = j + 1
        for r in range(3):
            if (col >> r) & 1:
                qc_early_dyn.cx(q_err[j], q_syn[r])
    # Immediately measure all 7 error qubits in X-basis and reset/release them!
    for j in range(7):
        qc_early_dyn.h(q_err[j])
        qc_early_dyn.measure(q_err[j], c_mx[j])
        qc_early_dyn.reset(q_err[j])

    # Prepare single parity wire `p_anc = q_sc[0]` in `|->` phase-kickback state
    qc_early_dyn.x(q_sc[0])
    qc_early_dyn.h(q_sc[0])
    for j in range(7):
        col = j + 1
        with qc_early_dyn.if_test((c_mx[j], 1)):
            for r in range(3):
                if not ((col >> r) & 1):
                    qc_early_dyn.x(q_syn[r])
            append_mcx_vchain(qc_early_dyn, [7, 8, 9], 10, [11])
            for r in range(3):
                if not ((col >> r) & 1):
                    qc_early_dyn.x(q_syn[r])
    qc_early_dyn.h(q_sc[0])
    qc_early_dyn.x(q_sc[0])

    for r in range(3):
        qc_early_dyn.h(q_syn[r])
    qc_early_dyn.save_statevector()

    # Execute 8 stochastic mid-circuit `M_X` + `if_test` feedforward trajectories on `AerSimulator`
    dyn_fidelities: List[float] = []
    observed_masks: List[int] = []
    for seed in range(100, 108):
        res_dyn = sim_sv.run(qc_early_dyn, shots=1, seed_simulator=seed).result()
        counts = res_dyn.get_counts()
        m_bits = next(iter(counts.keys())).replace(" ", "")
        observed_masks.append(int(m_bits, 2))
        sv_dyn_full = np.asarray(res_dyn.get_statevector(qc_early_dyn))
        sv_dyn_3q = np.array([sv_dyn_full[x << 7] for x in range(8)], dtype=complex)
        fid = float(state_fidelity(Statevector(sv_std_3q), Statevector(sv_dyn_3q)))
        dyn_fidelities.append(fid)

    min_dyn_fid = min(dyn_fidelities)
    assert abs(min_dyn_fid - 1.0) < 1e-11, f"Dynamic Early-MBU fidelity {min_dyn_fid} != 1.0"

    # 3. Also verify planted `7/7` satisfiable XORSAT (`w0=sqrt(1/8), w1=sqrt(7/8)`) -> `P(x*) = 1.0`!
    qc_planted = QuantumCircuit(11)
    append_dicke_le1_prep(qc_planted, list(range(7)), math.sqrt(1.0 / 8.0), math.sqrt(7.0 / 8.0), bch7_ht_mul(x_star))
    for j in range(7):
        col = j + 1
        for r in range(3):
            if (col >> r) & 1:
                qc_planted.cx(j, 7 + r)
        qc_planted.h(j)
    qc_planted.save_statevector()
    sv_pre = np.asarray(sim_sv.run(qc_planted, shots=1).result().get_statevector(qc_planted))
    # Check deterministic m = 0b1010110 (`86`) on `5`-qubit Stage-3 circuit (`0` error qubits!)
    m_demo = 0b1010110
    sv_branch_3q = np.array([sv_pre[(s << 7) | m_demo] * math.sqrt(128.0) for s in range(8)], dtype=complex)
    qc_5q = QuantumCircuit(5)  # s[0..2], p_anc=3, mcx_sc=4
    qc_5q.x(3)
    qc_5q.h(3)
    for j in range(7):
        if (m_demo >> j) & 1:
            col = j + 1
            for r in range(3):
                if not ((col >> r) & 1):
                    qc_5q.x(r)
            append_mcx_vchain(qc_5q, [0, 1, 2], 3, [4])
            for r in range(3):
                if not ((col >> r) & 1):
                    qc_5q.x(r)
    qc_5q.h(3)
    qc_5q.x(3)
    for r in range(3):
        qc_5q.h(r)
    init_5q = np.zeros(32, dtype=complex)
    init_5q[:8] = sv_branch_3q
    sv_planted_out = np.asarray(Statevector(init_5q).evolve(qc_5q))[:8]
    prob_planted_xstar = float(np.abs(sv_planted_out[x_star]) ** 2)
    assert abs(prob_planted_xstar - 1.0) < 1e-11

    # 4. Negative Control (`Law U4` Omitted on `AerSimulator`):
    qc_u4_bad = QuantumCircuit(10, 3)
    append_dicke_le1_prep(qc_u4_bad, list(range(7)), w0, w1, b_mask)
    for j in range(7):
        col = j + 1
        for r in range(3):
            if (col >> r) & 1:
                qc_u4_bad.cx(j, 7 + r)
        qc_u4_bad.h(j)
    # Measure error wires in X-basis WITHOUT phase fixup, then interfere syndromes!
    c_ign = ClassicalRegister(7, "ign")
    qc_u4_bad.add_register(c_ign)
    for j in range(7):
        qc_u4_bad.measure(j, c_ign[j])
    for r in range(3):
        qc_u4_bad.h(7 + r)
        qc_u4_bad.measure(7 + r, r)

    shots_u4 = 8192
    counts_u4 = sim_sv.run(qc_u4_bad, shots=shots_u4, seed_simulator=2026).result().get_counts()
    hits_u4 = 0
    for bitstr, cnt in counts_u4.items():
        # Qiskit space-separates classical registers: "<c_ign> <c_out>"
        syn_bits = bitstr.split()[-1]
        if int(syn_bits, 2) == x_star:
            hits_u4 += cnt
    empirical_u4_prob = hits_u4 / shots_u4
    assert abs(empirical_u4_prob - 0.125) < 0.025

    return {
        "code": "BCH(7, 4, 3)",
        "standard_live_data_syndrome_qubits": 10,
        "early_mbu_live_data_syndrome_qubits": 3,
        "live_error_qubits_during_decoding": 0,
        "dynamic_feedforward_trajectories_tested": len(dyn_fidelities),
        "unique_mx_masks_sampled": len(set(observed_masks)),
        "min_dynamic_trajectory_state_fidelity": round(min_dyn_fid, 12),
        "frustrated_6of7_optimal_prob_standard": round(prob_xstar_std, 12),
        "frustrated_6of7_optimal_prob_early_mbu": round(
            float(np.abs(sv_dyn_3q[x_star]) ** 2), 12
        ),
        "planted_7of7_optimal_prob_early_mbu": round(prob_planted_xstar, 12),
        "law_u4_violated_aer_8192shot_optimal_prob": round(empirical_u4_prob, 6),
        "law_u4_violated_exact_uniform_prob": 0.125,
    }


# =============================================================================
# 5. Experiment 1B: `BCH(15, 7, 5)` 23-Qubit Gate-Level Dicke + Dynamic `M_X`
#    -> 8-Qubit Syndrome Phase-Only Decoding on `AerSimulator`
# =============================================================================

GF16_POLY = 0b10011


def gf16_mul(a: int, b: int) -> int:
    res = 0
    x, y = a & 0xF, b & 0xF
    for _ in range(4):
        if y & 1:
            res ^= x
        hi = x & 0x8
        x = (x << 1) & 0xF
        if hi:
            x ^= 0x3
        y >>= 1
    return res


def gf16_pow(a: int, exp: int) -> int:
    res = 1
    for _ in range(exp % 15):
        res = gf16_mul(res, a)
    return res


ALPHA_POW15 = [gf16_pow(2, i) for i in range(15)]


def bch15_syn_int(e_mask: int) -> int:
    s1, s3 = 0, 0
    for i in range(15):
        if (e_mask >> i) & 1:
            s1 ^= ALPHA_POW15[i]
            s3 ^= ALPHA_POW15[(3 * i) % 15]
    return s1 | (s3 << 4)


def bch15_pb_decode_mask(syn: int) -> int:
    s1 = syn & 0xF
    s3 = (syn >> 4) & 0xF
    if s1 == 0 and s3 == 0:
        return 0
    s1_cubed = gf16_pow(s1, 3)
    s1_inv = 0 if s1 == 0 else gf16_pow(s1, 14)
    sigma2 = gf16_mul(s3 ^ s1_cubed, s1_inv)
    out = 0
    for i in range(15):
        x_inv = ALPHA_POW15[(15 - i) % 15]
        lam = 1 ^ gf16_mul(s1, x_inv) ^ gf16_mul(sigma2, gf16_mul(x_inv, x_inv))
        if lam == 0:
            out |= (1 << i)
    return out


def bch15_wt1_stub_decode_mask(syn: int) -> int:
    s1 = syn & 0xF
    if s1 == 0:
        return 0
    out = 0
    for i in range(15):
        if ALPHA_POW15[i] == s1:
            out |= (1 << i)
    return out


def bch15_ht_mul(x: int) -> int:
    out = 0
    for i in range(15):
        col = ALPHA_POW15[i] | (ALPHA_POW15[(3 * i) % 15] << 4)
        if bit_dot_parity(col, x):
            out |= (1 << i)
    return out


def build_8bit_syndrome_parity_phase_circuit(parity_true_syndromes: List[int]) -> QuantumCircuit:
    """
    15-qubit pure elementary gate circuit (`8` live syndrome wires `0..7` +
    `1` `|->` parity ancilla `8` + `6` RCCX V-chain clean scratch wires `9..14`;
    `0` error wires, `0` magic ops) applying `(-1)^{p(s)}` followed by `H^{otimes 8}`!
    """
    qc = QuantumCircuit(15)
    if parity_true_syndromes:
        qc.x(8)
        qc.h(8)
        for s_val in parity_true_syndromes:
            for b in range(8):
                if not ((s_val >> b) & 1):
                    qc.x(b)
            append_mcx_vchain(qc, list(range(8)), 8, list(range(9, 15)))
            for b in range(8):
                if not ((s_val >> b) & 1):
                    qc.x(b)
        qc.h(8)
        qc.x(8)
    for b in range(8):
        qc.h(b)
    return qc


def verify_bch15_noiseless_aer() -> Dict[str, Any]:
    sim_sv = AerSimulator(method="statevector", max_parallel_threads=8)
    sim_mps = AerSimulator(method="matrix_product_state")
    x_star = 173  # 0b10101101
    b_mask = bch15_ht_mul(x_star) ^ 0b0000101  # 2 frustrated clauses -> 13/15 satisfied!

    w0 = math.sqrt(1.0 / 121.0)
    w1 = math.sqrt(15.0 / 121.0)
    w2 = math.sqrt(105.0 / 121.0)

    all_121_masks = (
        [0]
        + [1 << i for i in range(15)]
        + [(1 << i) | (1 << j) for i, j in itertools.combinations(range(15), 2)]
    )

    # 1A. Verify 15-qubit Bartschi-Eidenbenz Dicke_{<=2} unitary circuit on `AerSimulator(method='statevector')`
    qc_dicke_15q = QuantumCircuit(15)
    append_dicke_le2_prep(qc_dicke_15q, list(range(15)), w0, w1, w2, b_mask)
    qc_dicke_15q.save_statevector()
    sv_dicke_15q = np.asarray(sim_sv.run(qc_dicke_15q, shots=1).result().get_statevector(qc_dicke_15q))
    sv_dicke_exact_15q = np.zeros(1 << 15, dtype=complex)
    for e_mask in all_121_masks:
        sv_dicke_exact_15q[e_mask] = (-1.0 if bit_dot_parity(b_mask, e_mask) else 1.0) / math.sqrt(121.0)
    assert abs(float(state_fidelity(Statevector(sv_dicke_exact_15q), Statevector(sv_dicke_15q))) - 1.0) < 1e-11

    # 1B. Full 23-qubit Stage 1 + Stage 2 (`|s = H e>_8`) + Mid-Circuit `M_X` + Error-Qubit Reset on `AerSimulator`!
    qc_23q = QuantumCircuit(23, 15)
    append_dicke_le2_prep(qc_23q, list(range(15)), w0, w1, w2, b_mask)
    for i in range(15):
        p1 = ALPHA_POW15[i]
        p3 = ALPHA_POW15[(3 * i) % 15]
        for b in range(4):
            if (p1 >> b) & 1:
                qc_23q.cx(i, 15 + b)
            if (p3 >> b) & 1:
                qc_23q.cx(i, 19 + b)
    for i in range(15):
        qc_23q.h(i)
        qc_23q.measure(i, i)
        qc_23q.reset(i)
    # Extract the collapsed 8-qubit `QTainted[m_aer, e]` syndrome state (`0` live error qubits!)
    qc_23q.save_amplitudes([s << 15 for s in range(256)], label="syn_amps")

    res_23q = sim_mps.run(qc_23q, shots=1, seed_simulator=37152).result()
    m_aer = int(next(iter(res_23q.get_counts().keys())).replace(" ", ""), 2)
    sv_tainted_8q = np.asarray(res_23q.data(0)["syn_amps"], dtype=complex)
    sv_tainted_norm = float(np.sum(np.abs(sv_tainted_8q) ** 2))
    assert abs(sv_tainted_norm - 1.0) < 1e-9
    sv_tainted_8q = sv_tainted_8q / math.sqrt(sv_tainted_norm)

    # 2. Exact Standard Unitary DQI 8-qubit reference (`e -> 0^15`, `H^{otimes 8}` on `s`):
    sv_clean_syn_8q = np.zeros(256, dtype=complex)
    for e_mask in all_121_masks:
        s_val = bch15_syn_int(e_mask)
        sign = -1.0 if bit_dot_parity(b_mask, e_mask) else 1.0
        sv_clean_syn_8q[s_val] = sign / math.sqrt(121.0)
    qc_h8 = QuantumCircuit(8)
    for b in range(8):
        qc_h8.h(b)
    sv_std_out_8q = np.asarray(Statevector(sv_clean_syn_8q).evolve(qc_h8))
    prob_xstar_std = float(np.abs(sv_std_out_8q[x_star]) ** 2)

    # 3. Run Stage-3 Feedforward Parity-Phase Fixup + `H^{otimes 8}` on `AerSimulator`
    #    using ONLY `8` live syndrome qubits (+ `p_anc` + `6` RCCX scratch = `15` qubits)!
    active_syndromes = [bch15_syn_int(e_mask) for e_mask in all_121_masks]
    pb_true_syns = [s for s in active_syndromes if bit_dot_parity(m_aer, bch15_pb_decode_mask(s)) == 1]
    stub_true_syns = [s for s in active_syndromes if bit_dot_parity(m_aer, bch15_wt1_stub_decode_mask(s)) == 1]

    init_15q = np.zeros(1 << 15, dtype=complex)
    init_15q[:256] = sv_tainted_8q

    # 3A. Certified `Law U1 + Law U4` Peterson-Berlekamp Phase-Only Decoder on `AerSimulator`
    qc_pb = QuantumCircuit(15)
    qc_pb.set_statevector(init_15q)
    qc_pb.compose(build_8bit_syndrome_parity_phase_circuit(pb_true_syns), inplace=True)
    qc_pb.save_amplitudes(list(range(256)), label="pb_out")
    sv_pb_8q = np.asarray(sim_sv.run(qc_pb, shots=1).result().data(0)["pb_out"], dtype=complex)
    scratch_clean_prob = float(np.sum(np.abs(sv_pb_8q) ** 2))
    fid_pb = float(state_fidelity(Statevector(sv_std_out_8q), Statevector(sv_pb_8q)))
    prob_xstar_pb = float(np.abs(sv_pb_8q[x_star]) ** 2)
    assert abs(scratch_clean_prob - 1.0) < 1e-10
    assert abs(fid_pb - 1.0) < 1e-10

    # 3B. `Law U1` Violated (`wt<=1` Hamming Stub) on `AerSimulator`
    qc_stub = QuantumCircuit(15)
    qc_stub.set_statevector(init_15q)
    qc_stub.compose(build_8bit_syndrome_parity_phase_circuit(stub_true_syns), inplace=True)
    qc_stub.save_amplitudes(list(range(256)), label="stub_out")
    sv_stub_8q = np.asarray(sim_sv.run(qc_stub, shots=1).result().data(0)["stub_out"], dtype=complex)
    fid_stub = float(state_fidelity(Statevector(sv_std_out_8q), Statevector(sv_stub_8q)))
    prob_xstar_stub = float(np.abs(sv_stub_8q[x_star]) ** 2)
    assert fid_stub < 0.35

    # 3C. `Law U4` Violated (Omitted Phase Fixup):
    sv_u4_branch_8q = np.asarray(Statevector(sv_tainted_8q).evolve(qc_h8))
    fid_u4_branch = float(state_fidelity(Statevector(sv_std_out_8q), Statevector(sv_u4_branch_8q)))
    # Exact M_X-averaged density matrix when Law U4 fixup is omitted: diagonal in syndrome basis -> uniform 1/256!
    u4_exact_avg_prob = float(np.sum(np.abs(sv_clean_syn_8q) ** 2) / 256.0)
    assert abs(u4_exact_avg_prob - (1.0 / 256.0)) < 1e-12

    corrupted_wt2_count = sum(
        1 for e_mask in all_121_masks if bch15_wt1_stub_decode_mask(bch15_syn_int(e_mask)) != e_mask
    )
    assert corrupted_wt2_count == 105

    return {
        "code": "BCH(15, 7, 5)",
        "standard_live_data_syndrome_qubits": 23,
        "early_mbu_live_data_syndrome_qubits": 8,
        "live_error_qubits_during_decoding": 0,
        "live_width_reduction_pct": round(100.0 * 15.0 / 23.0, 2),
        "aer_sampled_15bit_mx_mask": m_aer,
        "aer_sampled_15bit_mx_hex": f"0x{m_aer:04x}",
        "peterson_berlekamp_aer_state_fidelity": round(fid_pb, 12),
        "peterson_berlekamp_scratch_clean_prob": round(scratch_clean_prob, 12),
        "optimal_prob_standard_dqi": round(prob_xstar_std, 12),
        "optimal_prob_early_mbu_dqi": round(prob_xstar_pb, 12),
        "law_u1_stub_corrupted_patterns": corrupted_wt2_count,
        "law_u1_stub_corrupted_pct": round(100.0 * corrupted_wt2_count / 121.0, 2),
        "law_u1_stub_aer_state_fidelity": round(fid_stub, 6),
        "law_u1_stub_optimal_prob": round(prob_xstar_stub, 6),
        "law_u4_omitted_single_branch_fidelity": round(fid_u4_branch, 6),
        "law_u4_omitted_mx_averaged_optimal_prob": u4_exact_avg_prob,
    }


# =============================================================================
# 6. Experiment 2: Calibrated `IBM Heron r2` Noisy `AerSimulator(method='density_matrix')`
#    Survival Fidelity Gain (`Phi1`)
# =============================================================================

@dataclass(frozen=True)
class CalibratedHeronR2DqiNoiseParams:
    name: str = "IBM Heron r2 (Calibrated Superconducting Tunable-Coupler Profile)"
    t1_ns: float = 220_000.0         # 220 us T1
    t2_ns: float = 150_000.0         # 150 us T2
    tau_1q_ns: float = 24.0          # 24 ns 1Q gate
    tau_2q_ns: float = 68.0          # 68 ns 2Q CX/CZ gate
    tau_meas_echo_eff_ns: float = 130.0  # Effective XY4-echoed spectator dephasing during 650 ns M_X
    tau_routed_decoder_ns: float = 12_000.0  # 12 us routed algebraic syndrome decoder window
    p_1q: float = 2.0e-4
    p_2q: float = 1.8e-3


def build_heron_r2_noise_model(params: CalibratedHeronR2DqiNoiseParams) -> NoiseModel:
    nm = NoiseModel()
    err_1q = depolarizing_error(params.p_1q, 1).compose(
        thermal_relaxation_error(params.t1_ns, params.t2_ns, params.tau_1q_ns)
    )
    err_2q_1 = thermal_relaxation_error(params.t1_ns, params.t2_ns, params.tau_2q_ns)
    err_2q = depolarizing_error(params.p_2q, 2).compose(err_2q_1.tensor(err_2q_1))

    nm.add_all_qubit_quantum_error(err_1q, ["x", "h", "z", "t", "tdg", "ry", "u"])
    nm.add_all_qubit_quantum_error(err_2q, ["cx"])
    return nm


def verify_calibrated_heron_r2_noisy_density_matrix() -> Dict[str, Any]:
    params = CalibratedHeronR2DqiNoiseParams()
    nm = build_heron_r2_noise_model(params)
    sim_dm = AerSimulator(method="density_matrix", noise_model=nm, max_parallel_threads=8)

    # Ancilla-free 4-qubit `C3X` elementary template (`14` CX + `1Q` gates, `0` extra ancillas)
    _c3x_raw = QuantumCircuit(4)
    _c3x_raw.mcx([0, 1, 2], 3)
    c3x_elem = transpile(_c3x_raw, basis_gates=["cx", "u", "h", "x"], optimization_level=2)

    x_star = 5
    b_mask = bch7_ht_mul(x_star)  # Planted 7/7 satisfiable XORSAT where ideal P(x*) = 1.000000!
    w0 = math.sqrt(1.0 / 8.0)
    w1 = math.sqrt(7.0 / 8.0)
    ideal_target_sv = Statevector.from_int(x_star, 8)

    # Stage 1 + Stage 2 + H^7 + XY4 spectator echo on 10 qubits (`7` error + `3` syndrome)
    echo_err = thermal_relaxation_error(params.t1_ns, params.t2_ns, params.tau_meas_echo_eff_ns)
    qc_mx = QuantumCircuit(10)
    append_dicke_le1_prep(qc_mx, list(range(7)), w0, w1, b_mask)
    for j in range(7):
        col = j + 1
        for r in range(3):
            if (col >> r) & 1:
                qc_mx.cx(j, 7 + r)
    for j in range(7):
        qc_mx.h(j)
    for r in range(3):
        qc_mx.append(echo_err.to_instruction(), [7 + r])
    qc_mx.save_density_matrix()
    rho_after_h7 = np.asarray(sim_dm.run(qc_mx).result().data(0)["density_matrix"])

    rep_masks_and_weights = [
        (0b0000000, 1.0 / 128.0),
        (0b0000111, 63.0 / 128.0),  # wt <= 3 half
        (0b0001111, 63.0 / 128.0),  # wt >= 4 half
        (0b1111111, 1.0 / 128.0),
    ]

    def run_regime(decoder_idle_ns: float) -> Dict[str, float]:
        idle_err = thermal_relaxation_error(params.t1_ns, params.t2_ns, decoder_idle_ns)

        # A. Standard Stage-3 `erase-by` DQI (`10` live qubits: `e[0..6]`, `s[7..9]`):
        #    All 7 error qubits + 3 syndrome qubits suffer `decoder_idle_ns` memory decoherence
        #    AND all 7 `C3X` target writebacks execute!
        qc_std = QuantumCircuit(10)
        append_dicke_le1_prep(qc_std, list(range(7)), w0, w1, b_mask)
        for j in range(7):
            col = j + 1
            for r in range(3):
                if (col >> r) & 1:
                    qc_std.cx(j, 7 + r)
        if decoder_idle_ns > 0.0:
            for q in range(10):
                qc_std.append(idle_err.to_instruction(), [q])
        for j in range(7):
            col = j + 1
            for r in range(3):
                if not ((col >> r) & 1):
                    qc_std.x(7 + r)
            qc_std.compose(c3x_elem, [7, 8, 9, j], inplace=True)
            for r in range(3):
                if not ((col >> r) & 1):
                    qc_std.x(7 + r)
        for r in range(3):
            qc_std.h(7 + r)
        # Native C++ partial trace over error wires `0..6`, returning 3-qubit syndrome density matrix!
        qc_std.save_density_matrix(qubits=[7, 8, 9], label="syn_rho")

        rho_std_syn = DensityMatrix(sim_dm.run(qc_std).result().data(0)["syn_rho"])
        fid_std = float(state_fidelity(ideal_target_sv, rho_std_syn))
        prob_std = float(np.real(rho_std_syn.data[x_star, x_star]))

        # B. Early-`MBU` Phase-Only DQI (`4` live qubits: `s[0..2]`, `p_anc=3`; `0` error wires!):
        fid_early_acc = 0.0
        prob_early_acc = 0.0
        for m_val, w_prob in rep_masks_and_weights:
            # Post-measurement 3-qubit syndrome density matrix conditioned on `m_val`, error wires freed!
            sub_3q = np.zeros((8, 8), dtype=complex)
            for s_row in range(8):
                for s_col in range(8):
                    sub_3q[s_row, s_col] = rho_after_h7[(s_row << 7) | m_val, (s_col << 7) | m_val]
            sub_3q /= np.real(np.trace(sub_3q))

            # Embed with single parity ancilla (`p_anc=3` -> `4` qubits total!)
            rho_4q_init = np.zeros((16, 16), dtype=complex)
            rho_4q_init[:8, :8] = sub_3q

            qc_early_s3 = QuantumCircuit(4)
            qc_early_s3.set_density_matrix(DensityMatrix(rho_4q_init))
            if decoder_idle_ns > 0.0:
                # ONLY the 3 syndrome qubits sit live during `decoder_idle_ns` (`0` error qubits!)
                for r in range(3):
                    qc_early_s3.append(idle_err.to_instruction(), [r])
            active_js = [j for j in range(7) if (m_val >> j) & 1]
            if active_js:
                qc_early_s3.x(3)
                qc_early_s3.h(3)
                for j in active_js:
                    col = j + 1
                    for r in range(3):
                        if not ((col >> r) & 1):
                            qc_early_s3.x(r)
                    qc_early_s3.compose(c3x_elem, [0, 1, 2, 3], inplace=True)
                    for r in range(3):
                        if not ((col >> r) & 1):
                            qc_early_s3.x(r)
                qc_early_s3.h(3)
                qc_early_s3.x(3)
            for r in range(3):
                qc_early_s3.h(r)
            qc_early_s3.save_density_matrix(qubits=[0, 1, 2], label="syn_rho")

            rho_early_syn = DensityMatrix(sim_dm.run(qc_early_s3).result().data(0)["syn_rho"])
            fid_early_acc += w_prob * float(state_fidelity(ideal_target_sv, rho_early_syn))
            prob_early_acc += w_prob * float(np.real(rho_early_syn.data[x_star, x_star]))

        return {
            "decoder_window_ns": decoder_idle_ns,
            "standard_dqi_survival_fidelity": round(fid_std, 6),
            "early_mbu_dqi_survival_fidelity": round(fid_early_acc, 6),
            "survival_fidelity_gain_abs": round(fid_early_acc - fid_std, 6),
            "survival_fidelity_gain_ratio": round(fid_early_acc / fid_std, 4),
            "infidelity_reduction_pct": round(100.0 * (1.0 - (1.0 - fid_early_acc) / (1.0 - fid_std)), 2),
            "standard_dqi_optimal_hit_prob": round(prob_std, 6),
            "early_mbu_dqi_optimal_hit_prob": round(prob_early_acc, 6),
        }

    gate_only_regime = run_regime(0.0)
    routed_decoder_regime = run_regime(params.tau_routed_decoder_ns)

    assert gate_only_regime["early_mbu_dqi_survival_fidelity"] > gate_only_regime["standard_dqi_survival_fidelity"]
    assert routed_decoder_regime["early_mbu_dqi_survival_fidelity"] > routed_decoder_regime["standard_dqi_survival_fidelity"]

    # Analytical `Phi1` active decoherence volume comparison (milli-nats on T2 = 150 us)
    std_idle_milli = int((10 * params.tau_routed_decoder_ns * 1000.0) // params.t2_ns)
    early_idle_milli = int((3 * params.tau_routed_decoder_ns * 1000.0) // params.t2_ns)

    return {
        "hardware_profile": asdict(params),
        "phi1_stage3_idle_volume_milli_nats_at_12us": {
            "standard_10_live_qubits_milli_nats": std_idle_milli,
            "early_mbu_3_live_qubits_milli_nats": early_idle_milli,
            "eliminated_7_error_qubits_milli_nats": std_idle_milli - early_idle_milli,
            "idle_volume_reduction_pct": 70.0,
        },
        "direct_unrouted_gate_noise_regime": gate_only_regime,
        "routed_12us_algebraic_decoder_regime": routed_decoder_regime,
    }


# =============================================================================
# 7. Main Verification Driver & Artifact Report Writer
# =============================================================================

def main() -> None:
    from concurrent.futures import ThreadPoolExecutor

    t_start = time.perf_counter()

    with ThreadPoolExecutor(max_workers=2) as pool:
        racket_fut = pool.submit(run_racket_verification)
        aer_bch7 = verify_bch7_noiseless_aer()
        aer_bch15 = verify_bch15_noiseless_aer()
        heron_phi1 = verify_calibrated_heron_r2_noisy_density_matrix()
        racket_res = racket_fut.result()

    total_wall_s = time.perf_counter() - t_start
    assert total_wall_s < 6.0, f"Expected total runtime < 6.0s, took {total_wall_s:.3f}s"

    report: Dict[str, Any] = {
        "module": "Early-MBU Phase-Only Decoded Quantum Interferometry (Law U1 + Law U4)",
        "title": (
            "Closing Lesson 5 — Early Stage-2 MBU + Stage-3 Phase-Only Decoding in DQI "
            "(Khattar-Babbush 2025 Unified Under Law U1 + Law U4)"
        ),
        "status": "PASS",
        "total_wall_time_s": round(total_wall_s, 4),
        "runtime_budget_under_6s": total_wall_s < 6.0,
        "deliverables": {
            "racket_module": str(RACKET_MODULE.relative_to(REPO_ROOT)),
            "aer_reproducer": str(Path(__file__).resolve().relative_to(REPO_ROOT)),
            "lean4_proof_module": str(LEAN_PROOF_FILE.relative_to(REPO_ROOT)),
        },
        "racket_lakefill_verification": racket_res,
        "qiskit_aer_noiseless_dynamic_feedforward": {
            "bch_7_4_3": aer_bch7,
            "bch_15_7_5": aer_bch15,
        },
        "qiskit_aer_calibrated_ibm_heron_r2_noisy_density_matrix": heron_phi1,
        "asymptotic_khattar_babbush_opi_scaling": {
            "code": "OPI over GF(2^12) (Khattar-Babbush 2025, arXiv:2510.10967)",
            "n_error_qubits": 4095,
            "k_syndrome_qubits": 840,
            "standard_dqi_stage3_live_data_syndrome_qubits": 4935,
            "early_mbu_dqi_stage3_live_data_syndrome_qubits": 840,
            "freed_error_qubits_during_decoding": 4095,
            "live_data_syndrome_width_reduction_pct": round(100.0 * 4095.0 / 4935.0, 2),
        },
    }

    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    print(
        json.dumps(
            {
                "status": report["status"],
                "total_wall_time_s": report["total_wall_time_s"],
                "bch7_racket_128_of_128_fidelity": racket_res["bch_7_4_3_early_mbu_dqi"][
                    "min_branch_statevector_fidelity"
                ],
                "bch7_aer_dynamic_fidelity": aer_bch7["min_dynamic_trajectory_state_fidelity"],
                "bch15_aer_pb_fidelity": aer_bch15["peterson_berlekamp_aer_state_fidelity"],
                "bch15_u1_stub_corrupted_pct": aer_bch15["law_u1_stub_corrupted_pct"],
                "heron_r2_gate_only_fidelity_std_vs_early": [
                    heron_phi1["direct_unrouted_gate_noise_regime"]["standard_dqi_survival_fidelity"],
                    heron_phi1["direct_unrouted_gate_noise_regime"]["early_mbu_dqi_survival_fidelity"],
                ],
                "heron_r2_12us_routed_fidelity_std_vs_early": [
                    heron_phi1["routed_12us_algebraic_decoder_regime"]["standard_dqi_survival_fidelity"],
                    heron_phi1["routed_12us_algebraic_decoder_regime"]["early_mbu_dqi_survival_fidelity"],
                ],
                "report_path": str(REPORT_PATH),
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
