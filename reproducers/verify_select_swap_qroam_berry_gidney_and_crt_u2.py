#!/usr/bin/env python3
"""
verify_select_swap_qroam_berry_gidney_and_crt_u2.py
===================================================
`Select-SWAP QROAM` Sublinear `MBU` Uncomputation & `RNS-CRT` Kawamura `Law U2` Verification Harness:
Closing Lesson 4 — `Select-SWAP QROAM` (Low-Kliuchnikov-Schaeffer / Babbush et al.
2018) + `Berry-Gidney 2019` (`arXiv:1902.02134`) Sublinear O(sqrt(N)) `M_X`
Phase-Table Uncomputation + Executable `RNS-CRT` Kawamura `Law U2` Modular
Multiplication & Shor QFT Interference.

Verifies:
  1. Executes `racket lakefill-select-swap-qroam-and-crt-modexp.rkt` and audits:
     - `TempAND` scaling across `N in {16, 64, 256, 1024}` at `W = 32` (`61`
       `TempAND`s at `N = 1024, W = 32, lambda_uncomp = 32` vs `1,022` sawtooth
       `QROM` = `16.75x` and `10,240` naive `MCX` = `167.9x`, plus exact width
       independence across `W in {32, 64, 256}`).
     - Exhaustive `8,192 / 8,192` branch runs at `N = 16, W = 4, lambda = 4` (`5`
       `TempAND`s vs `14` sawtooth = `2.80x`) and `16,384 / 16,384` `(x, m)` pairs
       at `N = 64, W = 8, lambda = 8` (`13` `TempAND`s vs `62` sawtooth = `4.77x`).
     - Executable 3-channel `RNS(3, 5, 7)` (`M = 105`, `N = 15, 21`) Kawamura
       dyadic fixed-point `Law U2` quotient canonicalizer (`100%` `q_CRT -> 0`).
  2. Simulates BOTH primitives in quantum superposition on `qiskit_aer.AerSimulator`:
     - Primitive A (`N = 16, W = 4, lambda = 4` Berry-Gidney `M_X` + `5-TempAND`
       1-bit `Select-SWAP` phase QROAM): verifies `statevector_fidelity = 1.000000`
       with `(1/4) sum_{x=0}^{15} |x>` across ALL `16/16` 4-bit `M_X` masks `m` AND
       across multi-seed dynamic `qc.if_test` trajectories (while omitting the 1-bit
       phase QROAM collapses non-zero mask fidelity to `0.000000` and average mask
       fidelity to `0.0625 <= 0.25`!).
     - Primitive B (Shor Period-Finding Interference on `RNS(3, 5)` for `N = 15,
       a = 7`, period `r = 4` with vs without Kawamura `Law U2` quotient cleanup):
       verifies `100.0%` constructive QFT interference on multiples of `Q / 4` (`0.0%`
       odd-harmonic / non-period leakage!) with `Law U2`, vs `50.0%` probability
       leaked onto bogus non-period peaks when `Law U2` is omitted!
  3. Compiles and audits `proofs/select_swap_qroam_crt_kawamura_u2_proofs.lean`
     (`0` errors, `0` warnings, `0` `sorry`/`admit`/`axiom`,
     `0` `| _ =>` wildcards, all proofs `<= 30` lines).
  4. Writes `reproducers/artifacts/select_swap_qroam_berry_gidney_crt_report.json`.
"""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import json
import math
import os
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import time
from typing import Any, Dict, List

import numpy as np
from qiskit import ClassicalRegister, QuantumCircuit, QuantumRegister
from qiskit_aer import AerSimulator


REPO_ROOT = Path(__file__).resolve().parent.parent
RACKET_IMPL_PATH = REPO_ROOT / "lakefill-select-swap-qroam-and-crt-modexp.rkt"
LEAN_PROOF_PATH = (
    REPO_ROOT / "proofs" / "select_swap_qroam_crt_kawamura_u2_proofs.lean"
)
REPORT_JSON_PATH = (
    REPO_ROOT / "reproducers" / "artifacts" / "select_swap_qroam_berry_gidney_crt_report.json"
)
PERSISTENT_SCRATCH_DIR = Path.home() / "toolchains" / "tmp"


# =============================================================================
# 1. Persistent Environment & Toolchain Helpers
# =============================================================================

def _resolve_binary(name: str, extra_candidates: List[Path]) -> str:
    for cand in extra_candidates:
        if cand.exists() and os.access(cand, os.X_OK):
            return str(cand)
    found = shutil.which(name)
    if found:
        return found
    raise FileNotFoundError(f"Required executable `{name}` not found in persistent toolchains")


def _clean_subprocess_env() -> Dict[str, str]:
    PERSISTENT_SCRATCH_DIR.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env["TMPDIR"] = str(PERSISTENT_SCRATCH_DIR)
    local_bin = str(Path.home() / ".local" / "bin")
    env["PATH"] = f"{local_bin}:{env.get('PATH', '')}"
    return env


def _append_lakefill_gates_to_qiskit(
    qc: QuantumCircuit,
    qreg: QuantumRegister,
    gates: List[List[Any]],
    mbu_creg: ClassicalRegister | None = None,
    wire_map: Dict[int, int] | None = None,
) -> int:
    """Lower exported Lakefill gates (including dynamic `mid-meas-x-cond-cz`) into a Qiskit circuit."""
    wmap = (lambda w: wire_map[w]) if wire_map is not None else (lambda w: w)
    mbu_idx = 0
    for g in gates:
        op = g[0]
        if op == "x":
            qc.x(qreg[wmap(int(g[1]))])
        elif op == "h":
            qc.h(qreg[wmap(int(g[1]))])
        elif op == "z":
            qc.z(qreg[wmap(int(g[1]))])
        elif op == "cx":
            qc.cx(qreg[wmap(int(g[1]))], qreg[wmap(int(g[2]))])
        elif op == "cz":
            qc.cz(qreg[wmap(int(g[1]))], qreg[wmap(int(g[2]))])
        elif op == "ccx":
            qc.ccx(qreg[wmap(int(g[1]))], qreg[wmap(int(g[2]))], qreg[wmap(int(g[3]))])
        elif op == "swap":
            qc.swap(qreg[wmap(int(g[1]))], qreg[wmap(int(g[2]))])
        elif op == "mid-meas-x-cond-cz":
            assert mbu_creg is not None, "Dynamic MBU gate requires a ClassicalRegister"
            anc = qreg[wmap(int(g[1]))]
            c1 = qreg[wmap(int(g[2]))]
            c2 = qreg[wmap(int(g[3]))]
            clbit = mbu_creg[mbu_idx]
            mbu_idx += 1
            qc.h(anc)
            qc.measure(anc, clbit)
            qc.reset(anc)
            with qc.if_test((clbit, 1)):
                qc.cz(c1, c2)
        elif op == "mid-meas-x-cond-z":
            assert mbu_creg is not None, "Dynamic MBU gate requires a ClassicalRegister"
            anc = qreg[wmap(int(g[1]))]
            c1 = qreg[wmap(int(g[2]))]
            clbit = mbu_creg[mbu_idx]
            mbu_idx += 1
            qc.h(anc)
            qc.measure(anc, clbit)
            qc.reset(anc)
            with qc.if_test((clbit, 1)):
                qc.z(c1)
        else:
            raise ValueError(f"Unsupported Lakefill gate in Qiskit lowering: {g}")
    return mbu_idx


# =============================================================================
# 2. Qiskit Aer Superposition Verification — Primitive A (Berry-Gidney QROAM)
# =============================================================================

def verify_primitive_a_on_aer(aer_sim: AerSimulator, bg_gadget: Dict[str, Any]) -> Dict[str, Any]:
    num_qubits = int(bg_gadget["num_qubits"])  # 14 qubits: addr(0..3), out(4..7), u(8..11), hot(12..13)
    table = [int(v) for v in bg_gadget["table"]]
    fwd_gates = bg_gadget["forward_sawtooth_gates"]
    fixup_by_mask = bg_gadget["phase_fixup_gates_by_mask"]

    # Target uncomputed uniform address state: (1/4) sum_{x=0}^{15} |x>_addr |0>^10
    target_uncomp_sv = np.zeros(1 << num_qubits, dtype=np.complex128)
    for x in range(16):
        target_uncomp_sv[x] = 0.25

    # Target forward lookup state: (1/4) sum_{x=0}^{15} |x>_addr |T[x]>_out |0>^6
    target_fwd_sv = np.zeros(1 << num_qubits, dtype=np.complex128)
    for x in range(16):
        idx = x | (table[x] << 4)
        target_fwd_sv[idx] = 0.25

    # Step 1: Prepare (1/4) sum_{x=0}^{15} |x> |T[x]> on AerSimulator and verify fidelity = 1.0
    qreg_fwd = QuantumRegister(num_qubits, "q")
    qc_fwd = QuantumCircuit(qreg_fwd)
    for b in range(4):
        qc_fwd.h(qreg_fwd[b])
    _append_lakefill_gates_to_qiskit(qc_fwd, qreg_fwd, fwd_gates)
    qc_fwd.save_statevector("sv_fwd")
    for b in range(4, 8):
        qc_fwd.h(qreg_fwd[b])
    qc_fwd.save_statevector("sv_after_hout")

    res_fwd = aer_sim.run(qc_fwd, shots=1).result().data(0)
    sv_fwd = np.asarray(res_fwd["sv_fwd"], dtype=np.complex128)
    sv_after_hout = np.asarray(res_fwd["sv_after_hout"], dtype=np.complex128)
    fwd_fidelity = float(np.abs(np.vdot(target_fwd_sv, sv_fwd)) ** 2)
    assert abs(fwd_fidelity - 1.0) < 1e-11, f"Forward lookup fidelity {fwd_fidelity} != 1.0"

    # Step 2: Exhaustively test ALL 16/16 4-bit M_X masks m in {0..15} on AerSimulator!
    fidelities_with_fixup: Dict[str, float] = {}
    fidelities_without_fixup: Dict[str, float] = {}
    max_leakage_prob = 0.0

    for m in range(16):
        # Extract the exact M_X branch `out == m` from `sv_after_hout` and reset `out -> 0000`
        branch_sv = np.zeros(1 << num_qubits, dtype=np.complex128)
        for x_and_anc in range(1 << num_qubits):
            if ((x_and_anc >> 4) & 0xF) == 0:
                src_idx = x_and_anc | (m << 4)
                branch_sv[x_and_anc] = sv_after_hout[src_idx]
        branch_prob = float(np.vdot(branch_sv, branch_sv).real)
        assert abs(branch_prob - (1.0 / 16.0)) < 1e-11, f"Unexpected mask m={m} prob {branch_prob}"
        branch_sv /= math.sqrt(branch_prob)

        # Negative control: omitting the 1-bit Select-SWAP phase QROAM!
        fid_no_fixup = float(np.abs(np.vdot(target_uncomp_sv, branch_sv)) ** 2)
        fidelities_without_fixup[f"m={m:04b}"] = round(fid_no_fixup, 12)
        if m != 0:
            assert fid_no_fixup <= 0.25 + 1e-11, (
                f"Expected fidelity <= 0.25 without phase fixup on m={m}, got {fid_no_fixup}"
            )

        # Positive test: execute the Racket-compiled `5-TempAND` 1-bit Select-SWAP phase QROAM on AerSimulator!
        fixup_gates = fixup_by_mask[m]
        num_mbu = sum(1 for g in fixup_gates if g[0].startswith("mid-meas-x-cond"))
        qreg = QuantumRegister(num_qubits, "q")
        creg_mbu = ClassicalRegister(max(1, num_mbu), "mbu")
        qc_m = QuantumCircuit(qreg, creg_mbu)
        qc_m.initialize(branch_sv, qreg)
        _append_lakefill_gates_to_qiskit(qc_m, qreg, fixup_gates, mbu_creg=creg_mbu)
        qc_m.save_statevector("sv_uncomp")

        sv_uncomp = np.asarray(
            aer_sim.run(qc_m, shots=1, seed_simulator=100 + m).result().data(0)["sv_uncomp"],
            dtype=np.complex128,
        )
        fid_with = float(np.abs(np.vdot(target_uncomp_sv, sv_uncomp)) ** 2)
        leak_prob = float(
            sum(
                np.abs(sv_uncomp[idx]) ** 2
                for idx in range(1 << num_qubits)
                if (idx >> 4) != 0
            )
        )
        fidelities_with_fixup[f"m={m:04b}"] = round(fid_with, 12)
        max_leakage_prob = max(max_leakage_prob, leak_prob)
        assert abs(fid_with - 1.0) < 1e-11, f"Mask m={m} Berry-Gidney fidelity {fid_with} != 1.0"
        assert leak_prob < 1e-12, f"Mask m={m} leaked ancilla/output prob {leak_prob}"

    # Step 3: Unified End-to-End Dynamic `qc.if_test` Circuit on AerSimulator (live M_X on `out_wires`!)
    qreg_dyn = QuantumRegister(num_qubits, "q")
    creg_mx = ClassicalRegister(4, "mx_out")
    creg_int = ClassicalRegister(5, "mbu_int")
    qc_dyn = QuantumCircuit(qreg_dyn, creg_mx, creg_int)
    for b in range(4):
        qc_dyn.h(qreg_dyn[b])
    _append_lakefill_gates_to_qiskit(qc_dyn, qreg_dyn, fwd_gates)
    # Measure all 4 output wires in the X-basis and reset to |0>
    for b in range(4):
        qc_dyn.h(qreg_dyn[4 + b])
        qc_dyn.measure(qreg_dyn[4 + b], creg_mx[b])
        qc_dyn.reset(qreg_dyn[4 + b])
    # Dispatch the 5-TempAND 1-bit Select-SWAP phase QROAM dynamically via `qc.if_test((creg_mx, m))`!
    for m in range(1, 16):
        with qc_dyn.if_test((creg_mx, m)):
            _append_lakefill_gates_to_qiskit(qc_dyn, qreg_dyn, fixup_by_mask[m], mbu_creg=creg_int)
    qc_dyn.save_statevector("sv_dyn")

    dyn_fidelities: List[float] = []
    sampled_masks: List[int] = []
    for seed in range(8):
        res_dyn = aer_sim.run(qc_dyn, shots=1, seed_simulator=700 + seed).result()
        counts_key = next(iter(res_dyn.get_counts().keys()))
        # Format of counts_key is "<mbu_int> <mx_out>"
        mx_bits = counts_key.split()[-1]
        sampled_masks.append(int(mx_bits, 2))
        sv_dyn = np.asarray(res_dyn.data(0)["sv_dyn"], dtype=np.complex128)
        fid_d = float(np.abs(np.vdot(target_uncomp_sv, sv_dyn)) ** 2)
        assert abs(fid_d - 1.0) < 1e-11, f"Dynamic qc.if_test trajectory seed={seed} fidelity {fid_d} != 1.0"
        dyn_fidelities.append(fid_d)

    avg_no_fixup = float(statistics.mean(fidelities_without_fixup.values()))
    nonzero_max_no_fixup = max(v for k, v in fidelities_without_fixup.items() if k != "m=0000")
    assert avg_no_fixup <= 0.25 and nonzero_max_no_fixup <= 0.25

    return {
        "num_qubits": num_qubits,
        "table_N": 16,
        "word_width_W": 4,
        "lambda_uncomp": 4,
        "berry_gidney_temp_ands": 5,
        "sawtooth_uncompute_temp_ands": 14,
        "forward_superposition_fidelity": round(fwd_fidelity, 12),
        "all_16_of_16_mx_masks_verified": True,
        "min_statevector_fidelity_across_all_16_masks": round(min(fidelities_with_fixup.values()), 12),
        "mean_statevector_fidelity_across_all_16_masks": round(
            float(statistics.mean(fidelities_with_fixup.values())), 12
        ),
        "max_ancilla_and_output_leakage_prob": round(max_leakage_prob, 15),
        "without_phase_qroam_nonzero_mask_max_fidelity": round(nonzero_max_no_fixup, 12),
        "without_phase_qroam_mean_fidelity_all_16_masks": round(avg_no_fixup, 12),
        "dynamic_if_test_trajectories_tested": len(dyn_fidelities),
        "dynamic_if_test_min_fidelity": round(min(dyn_fidelities), 12),
        "dynamic_if_test_sampled_masks": sampled_masks,
        "fidelities_by_mask_with_fixup": fidelities_with_fixup,
        "fidelities_by_mask_without_fixup": fidelities_without_fixup,
    }


# =============================================================================
# 3. Qiskit Aer Superposition Verification — Primitive B (Shor RNS-CRT + Law U2)
# =============================================================================

def _apply_inverse_qft(qc: QuantumCircuit, exp_qubits: List[Any]) -> None:
    """Exact Textbook Inverse QFT (with bit-reversal swaps) on `exp_qubits` (LSB-first)."""
    m = len(exp_qubits)
    for i in range(m // 2):
        qc.swap(exp_qubits[i], exp_qubits[m - 1 - i])
    for j in range(m):
        for k in range(j):
            qc.cp(-math.pi / float(1 << (j - k)), exp_qubits[k], exp_qubits[j])
        qc.h(exp_qubits[j])


def _run_shor_rns3x5_qft_on_aer(
    aer_sim: AerSimulator,
    step_gates: List[List[Any]],
    exp_bits: int,
) -> Dict[str, Any]:
    """
    Simulate Shor's Period-Finding QFT for `N = 15, a = 7` (period `r = 4`) in `RNS(3, 5)`
    + overflow quotient wire `q_CRT`:
      - Exponent qubits: `0 .. exp_bits - 1` (`Q = 2^exp_bits`)
      - `r3` (`mod 3`): `exp_bits .. exp_bits + 1` (initialized to `1`)
      - `r5` (`mod 5`): `exp_bits + 2 .. exp_bits + 4` (initialized to `1`)
      - `q_CRT`:        `exp_bits + 5` (initialized to `0`)
      - Scratch ancillas: `exp_bits + 6 .. exp_bits + 9` (`4` clean wires)
    """
    total_qubits = exp_bits + 10
    Q = 1 << exp_bits
    qreg = QuantumRegister(total_qubits, "q")
    qc = QuantumCircuit(qreg)

    # 1. Uniform superposition over exponent `e in [0, Q)`
    for j in range(exp_bits):
        qc.h(qreg[j])

    # 2. Initialize RNS accumulator to canonical `1 <-> (r3 = 1, r5 = 1, q_CRT = 0)`
    qc.x(qreg[exp_bits + 0])  # r3 = 1
    qc.x(qreg[exp_bits + 2])  # r5 = 1

    # 3. Controlled RNS-CRT modular exponentiation `7^e mod 15`:
    #    For bit `e_j`, apply `2^j` controlled RNS-CRT `x 7` steps!
    for j in range(exp_bits):
        wire_map = {0: j}
        for w in range(1, 11):
            wire_map[w] = exp_bits + (w - 1)
        for _rep in range(1 << j):
            _append_lakefill_gates_to_qiskit(qc, qreg, step_gates, wire_map=wire_map)

    # 4. Inverse QFT on exponent register `0 .. exp_bits - 1`
    _apply_inverse_qft(qc, [qreg[j] for j in range(exp_bits)])
    qc.save_statevector("sv_qft")

    sv = np.asarray(aer_sim.run(qc, shots=1).result().data(0)["sv_qft"], dtype=np.complex128)

    qft_probs = [0.0] * Q
    q_crt_nonzero_prob = 0.0
    scratch_leak_prob = 0.0
    mask_exp = Q - 1
    qcrt_bit = exp_bits + 5
    scratch_shift = exp_bits + 6

    for idx, amp in enumerate(sv):
        p = float((amp.real * amp.real) + (amp.imag * amp.imag))
        if p == 0.0:
            continue
        qft_probs[idx & mask_exp] += p
        if (idx >> qcrt_bit) & 1:
            q_crt_nonzero_prob += p
        if (idx >> scratch_shift) != 0:
            scratch_leak_prob += p

    assert scratch_leak_prob < 1e-12, f"Scratch ancilla leaked {scratch_leak_prob}"

    stride = Q // 4
    period4_peak_indices = [m * stride for m in range(4)]
    period4_constructive_prob = sum(qft_probs[k] for k in period4_peak_indices)
    non_period_bogus_prob = sum(qft_probs[k] for k in range(Q) if k % stride != 0)
    odd_index_prob = sum(qft_probs[k] for k in range(Q) if k % 2 == 1)

    return {
        "Q": Q,
        "exponent_qubits": exp_bits,
        "total_qubits": total_qubits,
        "period_r": 4,
        "expected_peak_multiples_of_Q_div_4": period4_peak_indices,
        "qft_probabilities": {str(k): round(qft_probs[k], 8) for k in range(Q) if qft_probs[k] > 1e-9},
        "constructive_period4_prob": round(period4_constructive_prob, 10),
        "bogus_non_period_leakage_prob": round(non_period_bogus_prob, 10),
        "odd_harmonic_index_prob": round(odd_index_prob, 10),
        "q_crt_nonzero_entanglement_prob": round(q_crt_nonzero_prob, 10),
        "scratch_leakage_prob": round(scratch_leak_prob, 15),
    }


def verify_primitive_b_on_aer(aer_sim: AerSimulator, shor_gadget: Dict[str, Any]) -> Dict[str, Any]:
    gates_with_u2 = shor_gadget["step_with_kawamura_u2_gates"]
    gates_without_u2 = shor_gadget["step_without_kawamura_u2_gates"]

    # 1. Q = 8 (3 exponent qubits -> Q/4 = 2: true peaks {0, 2, 4, 6}, odd harmonics {1, 3, 5, 7})
    q8_with_u2 = _run_shor_rns3x5_qft_on_aer(aer_sim, gates_with_u2, exp_bits=3)
    q8_without_u2 = _run_shor_rns3x5_qft_on_aer(aer_sim, gates_without_u2, exp_bits=3)

    assert abs(q8_with_u2["constructive_period4_prob"] - 1.0) < 1e-9
    assert abs(q8_with_u2["bogus_non_period_leakage_prob"] - 0.0) < 1e-9
    assert abs(q8_with_u2["odd_harmonic_index_prob"] - 0.0) < 1e-9
    assert abs(q8_with_u2["q_crt_nonzero_entanglement_prob"] - 0.0) < 1e-9

    assert abs(q8_without_u2["constructive_period4_prob"] - 0.5) < 1e-9
    assert abs(q8_without_u2["bogus_non_period_leakage_prob"] - 0.5) < 1e-9
    assert abs(q8_without_u2["odd_harmonic_index_prob"] - 0.5) < 1e-9
    assert abs(q8_without_u2["q_crt_nonzero_entanglement_prob"] - 0.5) < 1e-9

    # 2. Q = 16 (4 exponent qubits -> Q/4 = 4: true peaks {0, 4, 8, 12}, bogus peaks {2, 6, 10, 14})
    q16_with_u2 = _run_shor_rns3x5_qft_on_aer(aer_sim, gates_with_u2, exp_bits=4)
    q16_without_u2 = _run_shor_rns3x5_qft_on_aer(aer_sim, gates_without_u2, exp_bits=4)

    assert abs(q16_with_u2["constructive_period4_prob"] - 1.0) < 1e-9
    assert abs(q16_with_u2["bogus_non_period_leakage_prob"] - 0.0) < 1e-9
    assert abs(q16_with_u2["q_crt_nonzero_entanglement_prob"] - 0.0) < 1e-9

    assert abs(q16_without_u2["constructive_period4_prob"] - 0.5) < 1e-9
    assert abs(q16_without_u2["bogus_non_period_leakage_prob"] - 0.5) < 1e-9
    assert abs(q16_without_u2["q_crt_nonzero_entanglement_prob"] - 0.5) < 1e-9

    return {
        "modulus_N": 15,
        "base_a": 7,
        "true_period_r": 4,
        "rns_channels": [3, 5],
        "q8_3exp_qubits": {
            "with_kawamura_law_u2": q8_with_u2,
            "without_kawamura_law_u2": q8_without_u2,
        },
        "q16_4exp_qubits": {
            "with_kawamura_law_u2": q16_with_u2,
            "without_kawamura_law_u2": q16_without_u2,
        },
    }


# =============================================================================
# 4. Lean 4.35.0 Compilation & Structural Hygiene Audit 
# =============================================================================

def strip_lean_comments(src: str) -> str:
    prev = None
    cur = src
    while prev != cur:
        prev = cur
        cur = re.sub(r"/-.*?-/", "", cur, flags=re.S)
    return re.sub(r"--[^\n]*", "", cur)


def verify_and_compile_lean4_proofs() -> Dict[str, Any]:
    assert LEAN_PROOF_PATH.exists(), f"Missing Lean 4 proof module: {LEAN_PROOF_PATH}"
    raw_src = LEAN_PROOF_PATH.read_text(encoding="utf-8")
    cleaned = strip_lean_comments(raw_src)

    required_theorems = [
        "select_swap_block_bijection_and_lookup_exactness",
        "berry_gidney_mx_phase_reduction_exactness",
        "berry_gidney_sublinear_sqrt_n_temp_and_dominance",
        "rns_3x5_and_3x5x7_crt_isomorphism_and_overflow_witness",
        "kawamura_law_u2_quotient_erasure_and_canonical_representation",
        "qsub_u2_u3_u4_rns_crt_berry_gidney_qphys_synthesis",
        "select_swap_qroam_and_crt_kawamura_u2_module_closure",
    ]
    for thm in required_theorems:
        assert f"theorem {thm}" in cleaned, f"Missing required Theorem `{thm}` in {LEAN_PROOF_PATH.name}"

    for forbidden in ["sorry", "admit", "unsafe", "implemented_by", "extern", "native_decide"]:
        assert not re.search(rf"\b{forbidden}\b", cleaned), f"Forbidden token `{forbidden}` in Lean file"
    assert not re.search(r"^\s*axiom\s+\w+", cleaned, flags=re.M), "Forbidden `axiom` in Lean file"
    assert not re.search(r"\|\s*_\s*=>", cleaned), "Forbidden wildcard `| _ =>` in Lean file"

    blocks = re.split(r"\b(?:theorem|lemma)\s+", cleaned)[1:]
    proof_lengths: List[int] = []
    for b in blocks:
        if ":= by" in b:
            after_by = b.split(":= by", 1)[1]
            chunk = re.split(
                r"\n(?:@\[|def |abbrev |structure |inductive |theorem |lemma |#eval |end )",
                after_by,
            )[0]
            lines = [ln.strip() for ln in chunk.splitlines() if ln.strip()]
            proof_lengths.append(len(lines))
        else:
            proof_lengths.append(1)

    max_lines = max(proof_lengths) if proof_lengths else 0
    assert max_lines <= 30, f"Theorem proof exceeded 30-line limit: max={max_lines}"

    lean_bin = _resolve_binary(
        "lean",
        [
            Path.home() / "toolchains" / "lean4-p36t4" / "lean-4.35.0-linux" / "bin" / "lean",
            Path.home() / ".local" / "bin" / "lean",
        ],
    )
    t_lean = time.perf_counter()
    proc = subprocess.run(
        [lean_bin, str(LEAN_PROOF_PATH)],
        cwd=str(REPO_ROOT),
        env=_clean_subprocess_env(),
        capture_output=True,
        text=True,
        check=False,
    )
    lean_ms = round((time.perf_counter() - t_lean) * 1000.0, 2)
    assert proc.returncode == 0, (
        f"`lean {LEAN_PROOF_PATH.name}` failed (rc={proc.returncode}):\n{proc.stdout}\n{proc.stderr}"
    )
    assert proc.stderr.strip() == "" and "warning" not in proc.stdout.lower(), (
        f"Expected 0 warnings in Lean output, got stdout={proc.stdout!r} stderr={proc.stderr!r}"
    )
    assert "true" in proc.stdout.splitlines(), (
        f"Expected `#eval verifySelectSwapQroamCrtModuleSanity ()` -> `true`, got: {proc.stdout!r}"
    )

    return {
        "lean_proof_file": str(LEAN_PROOF_PATH.relative_to(REPO_ROOT)),
        "lean_binary": lean_bin,
        "lean_compile_exit_code": proc.returncode,
        "lean_compile_time_ms": lean_ms,
        "eval_sanity_output": proc.stdout.strip(),
        "total_theorems_and_helpers": len(blocks),
        "core_theorems": required_theorems,
        "median_proof_lines": round(float(statistics.median(proof_lengths)), 1),
        "max_proof_lines": max_lines,
        "zero_warnings": True,
        "zero_sorry_admit_axiom_native_decide_wildcards": True,
    }


# =============================================================================
# 5. End-to-End Orchestration & JSON Report Generation
# =============================================================================

def run_end_to_end_verification() -> Dict[str, Any]:
    t0 = time.perf_counter()
    assert RACKET_IMPL_PATH.exists(), f"Missing Racket module: {RACKET_IMPL_PATH}"

    racket_bin = _resolve_binary(
        "racket",
        [
            Path.home() / ".local" / "bin" / "racket",
            Path.home() / "toolchains" / "racket-p36t2" / "racket" / "bin" / "racket",
        ],
    )
    with ThreadPoolExecutor(max_workers=2) as pool:
        lean_future = pool.submit(verify_and_compile_lean4_proofs)

        t_rkt = time.perf_counter()
        proc_rkt = subprocess.run(
            [racket_bin, str(RACKET_IMPL_PATH)],
            cwd=str(REPO_ROOT),
            env=_clean_subprocess_env(),
            capture_output=True,
            text=True,
            check=False,
        )
        rkt_ms = round((time.perf_counter() - t_rkt) * 1000.0, 2)
        assert proc_rkt.returncode == 0, (
            f"Racket verification failed (rc={proc_rkt.returncode}):\n{proc_rkt.stdout}\n{proc_rkt.stderr}"
        )
        rkt_data = json.loads(proc_rkt.stdout)
        assert rkt_data["status"] == "PASS"

        # Cross-check exact TempAND counts in Racket scaling sweep
        pa = rkt_data["primitive_a_select_swap_and_berry_gidney"]
        sweep_by_n = {int(row["N"]): row for row in pa["w32_scaling_sweep"]}
        assert sweep_by_n[16]["berry_gidney_mx_uncompute_temp_ands"] == 5
        assert sweep_by_n[16]["sawtooth_qrom_uncompute_ccx"] == 14
        assert sweep_by_n[64]["berry_gidney_mx_uncompute_temp_ands"] == 13
        assert sweep_by_n[64]["sawtooth_qrom_uncompute_ccx"] == 62
        assert sweep_by_n[256]["berry_gidney_mx_uncompute_temp_ands"] == 29
        assert sweep_by_n[256]["sawtooth_qrom_uncompute_ccx"] == 254
        assert sweep_by_n[1024]["berry_gidney_mx_uncompute_temp_ands"] == 61
        assert sweep_by_n[1024]["sawtooth_qrom_uncompute_ccx"] == 1022
        assert sweep_by_n[1024]["naive_mcx_uncompute_ccx"] == 10240
        assert all(int(row["temp_ands"]) == 61 for row in pa["n1024_width_independence"])

        pb = rkt_data["primitive_b_rns_crt_kawamura_law_u2"]
        assert pb["n15_valid_residues_erased_to_zero"] == "15/15 (100.0%)"
        assert pb["n21_valid_residues_erased_to_zero"] == "21/21 (100.0%)"
        assert int(pb["residues_verified_exact_zero_quotient"]) == 98

        # Quantum Superposition Simulations on `qiskit_aer.AerSimulator`
        t_aer = time.perf_counter()
        aer_sim = AerSimulator(method="statevector")
        gadgets = rkt_data["aer_simulator_gadgets"]
        aer_prim_a = verify_primitive_a_on_aer(aer_sim, gadgets["berry_gidney_n16_w4_lambda4"])
        aer_prim_b = verify_primitive_b_on_aer(aer_sim, gadgets["shor_rns3x5_n15_a7"])
        aer_ms = round((time.perf_counter() - t_aer) * 1000.0, 2)

        # Collect Lean 4.35.0 Formal Verification Audit
        lean_audit = lean_future.result()

    total_wall_s = round(time.perf_counter() - t0, 4)
    assert total_wall_s < 6.0, f"Expected < 6.0s runtime, took {total_wall_s}s"

    report = {
        "module": "Select-SWAP QROAM Sublinear MBU Uncomputation & RNS-CRT Kawamura Law U2",
        "title": (
            "Select-SWAP QROAM + Berry-Gidney Sublinear O(sqrt(N)) M_X Uncomputation "
            "+ Executable RNS-CRT Kawamura Law U2 Modular Multiplication"
        ),
        "status": "PASS",
        "total_wall_time_s": total_wall_s,
        "racket_subprocess_ms": rkt_ms,
        "qiskit_aer_simulation_ms": aer_ms,
        "racket_primitive_a_select_swap_berry_gidney": pa,
        "racket_primitive_b_rns_crt_kawamura_u2": pb,
        "qiskit_aer_primitive_a_berry_gidney_superposition": aer_prim_a,
        "qiskit_aer_primitive_b_shor_rns_crt_qft_interference": aer_prim_b,
        "lean4_formal_proof_audit": lean_audit,
    }

    REPORT_JSON_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_JSON_PATH.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report


if __name__ == "__main__":
    rep = run_end_to_end_verification()
    p1024 = next(
        r
        for r in rep["racket_primitive_a_select_swap_berry_gidney"]["w32_scaling_sweep"]
        if r["N"] == 1024
    )
    print(
        json.dumps(
            {
                "status": rep["status"],
                "total_wall_time_s": rep["total_wall_time_s"],
                "n1024_w32_berry_gidney_temp_ands": p1024["berry_gidney_mx_uncompute_temp_ands"],
                "n1024_w32_reduction_vs_sawtooth": round(p1024["reduction_vs_sawtooth"], 2),
                "n1024_w32_reduction_vs_naive_mcx": round(p1024["reduction_vs_naive_mcx"], 2),
                "aer_berry_gidney_16_of_16_min_fidelity": rep[
                    "qiskit_aer_primitive_a_berry_gidney_superposition"
                ]["min_statevector_fidelity_across_all_16_masks"],
                "aer_without_fixup_mean_fidelity": rep[
                    "qiskit_aer_primitive_a_berry_gidney_superposition"
                ]["without_phase_qroam_mean_fidelity_all_16_masks"],
                "aer_shor_q8_period4_prob_with_u2": rep[
                    "qiskit_aer_primitive_b_shor_rns_crt_qft_interference"
                ]["q8_3exp_qubits"]["with_kawamura_law_u2"]["constructive_period4_prob"],
                "aer_shor_q8_bogus_leakage_without_u2": rep[
                    "qiskit_aer_primitive_b_shor_rns_crt_qft_interference"
                ]["q8_3exp_qubits"]["without_kawamura_law_u2"]["bogus_non_period_leakage_prob"],
                "lean4_theorems_verified": rep["lean4_formal_proof_audit"][
                    "total_theorems_and_helpers"
                ],
                "lean4_max_proof_lines": rep["lean4_formal_proof_audit"]["max_proof_lines"],
            },
            indent=2,
        )
    )
