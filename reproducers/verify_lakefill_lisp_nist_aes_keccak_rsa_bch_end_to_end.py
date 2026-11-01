#!/usr/bin/env python3
"""
verify_lakefill_lisp_nist_aes_keccak_rsa_bch_end_to_end.py
==========================================================
Phase 36 (Track 2 — Part 54, Suite 147) End-to-End Verification Harness:
Executable `#lang racket` Lakefill Lisp Cryptographic Implementations,
NIST FIPS-197 / FIPS-202 Cross-Verification, Qiskit Aer & Stim Quantum
Superposition Simulation, and Lean 4.35.0 Proof Audit (`Theorems 54A–54G`).

Verifies:
  1. Executes `racket lakefill-core-cryptography-implementations.rkt` and parses
     the compiled reversible gate counts, NIST vector outputs, OpenQASM 3.0
     lowering, and exported quantum gadgets.
  2. Independently computes NIST FIPS-197 Appendix C.1 (`AES-128`), C.2 (`AES-192`),
     and C.3 (`AES-256`) ciphertexts and NIST FIPS-202 `Keccak-f[200]` 18-round
     permutations in pure Python, verifying bit-exact agreement, zero ancilla
     leakage, exact `invert-circuit` roundtrips, and Grover phase-oracle signs.
  3. Simulates exported Lakefill Lisp reversible circuits in genuine quantum
     superposition:
       - `gf16_tower_inv_12q` on `qiskit_aer.AerSimulator(method="statevector")`
         over uniform 16-element superposition (`fidelity = 1.0`, `leakage = 0.0`).
       - `keccak_chi5_inplace_15q` on `qiskit_aer.AerSimulator(method="statevector")`
         over uniform 32-row superposition (`fidelity = 1.0`, `leakage = 0.0`).
       - `gidney_adder_mbu_11q` on `qiskit_aer.AerSimulator(method="statevector")`
         over uniform 256-pair `H^8` superposition with dynamic mid-circuit `M_X`
         measurement and `if_test` `CZ` phase fixup across 16 stochastic trajectories
         (`fidelity = 1.0`, `leakage = 0.0`, plus negative control without `CZ`).
       - `clifford_mbu_stim_3q` and 64-qubit Choi-Bell `aes_mixcolumns_clifford_32q`
         on `stim.TableauSimulator` (`fidelity = 1.0`, `64/64` Bell disentanglement).
  4. Compiles and audits `proofs/lakefill_nist_aes_keccak_rsa_bch_proofs.lean`
     (`Theorems 54A–54G`, `<= 25` lines per proof, `0` `sorry`/`admit`/`axiom`).
  5. Emits `reproducers/artifacts/lakefill_lisp_nist_cryptography_report.json`.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import time
from typing import Any, Dict, List, Tuple

import numpy as np
from qiskit import ClassicalRegister, QuantumCircuit, QuantumRegister
from qiskit.quantum_info import partial_trace, purity
from qiskit_aer import AerSimulator
import stim


REPO_ROOT = Path(__file__).resolve().parent.parent
RACKET_IMPL_PATH = REPO_ROOT / "lakefill-core-cryptography-implementations.rkt"
LEAN_PROOF_PATH = REPO_ROOT / "proofs" / "lakefill_nist_aes_keccak_rsa_bch_proofs.lean"
REPORT_JSON_PATH = REPO_ROOT / "reproducers" / "artifacts" / "lakefill_lisp_nist_cryptography_report.json"
PERSISTENT_SCRATCH_DIR = Path.home() / "toolchains" / "tmp"


# =============================================================================
# 1. Toolchain Resolution & Persistent Scratch Setup
# =============================================================================

def _resolve_binary(name: str, extra_candidates: List[Path]) -> str:
    found = shutil.which(name)
    if found:
        return found
    for cand in extra_candidates:
        if cand.exists() and os.access(cand, os.X_OK):
            return str(cand)
    raise FileNotFoundError(f"Required executable `{name}` not found in PATH or persistent toolchains")


def _clean_subprocess_env() -> Dict[str, str]:
    PERSISTENT_SCRATCH_DIR.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env["TMPDIR"] = str(PERSISTENT_SCRATCH_DIR)
    local_bin = str(Path.home() / ".local" / "bin")
    env["PATH"] = f"{local_bin}:{env.get('PATH', '')}"
    return env


# =============================================================================
# 2. Independent Pure-Python NIST FIPS-197 (AES) & FIPS-202 (Keccak-f[200])
# =============================================================================

def _gf256_aes_mul(a: int, b: int) -> int:
    res = 0
    cur = a & 0xFF
    for i in range(8):
        if (b >> i) & 1:
            res ^= cur
        hi = cur & 0x80
        cur = (cur << 1) & 0xFF
        if hi:
            cur ^= 0x1B
    return res


def _gf256_aes_inv(a: int) -> int:
    if a == 0:
        return 0
    # x^254 in GF(2^8)
    acc = 1
    base = a & 0xFF
    exp = 254
    while exp > 0:
        if exp & 1:
            acc = _gf256_aes_mul(acc, base)
        base = _gf256_aes_mul(base, base)
        exp >>= 1
    return acc


def _aes_sbox_byte_ref(x: int) -> int:
    inv = _gf256_aes_inv(x & 0xFF)
    rot = lambda v, k: ((v << k) | (v >> (8 - k))) & 0xFF
    return inv ^ rot(inv, 1) ^ rot(inv, 2) ^ rot(inv, 3) ^ rot(inv, 4) ^ 0x63


AES_SBOX_REF = [_aes_sbox_byte_ref(i) for i in range(256)]


def python_nist_aes_encrypt_block(pt: bytes, key: bytes) -> bytes:
    nk = len(key) // 4
    nr = {4: 10, 6: 12, 8: 14}[nk]
    total_words = 4 * (nr + 1)
    w: List[List[int]] = [list(key[4 * i : 4 * i + 4]) for i in range(nk)]
    rcon = 1
    for i in range(nk, total_words):
        temp = list(w[i - 1])
        if i % nk == 0:
            temp = [AES_SBOX_REF[b] for b in (temp[1:] + temp[:1])]
            temp[0] ^= rcon
            rcon = _gf256_aes_mul(rcon, 2)
        elif nk == 8 and i % nk == 4:
            temp = [AES_SBOX_REF[b] for b in temp]
        w.append([w[i - nk][j] ^ temp[j] for j in range(4)])

    state = [b for b in pt]

    def add_round_key(rnd: int) -> None:
        for col in range(4):
            rk_word = w[4 * rnd + col]
            for row in range(4):
                state[4 * col + row] ^= rk_word[row]

    add_round_key(0)
    for rnd in range(1, nr + 1):
        # SubBytes
        for idx in range(16):
            state[idx] = AES_SBOX_REF[state[idx]]
        # ShiftRows
        orig = list(state)
        for row in range(4):
            for col in range(4):
                state[4 * col + row] = orig[4 * ((col + row) % 4) + row]
        # MixColumns (all rounds except final)
        if rnd < nr:
            for col in range(4):
                s0, s1, s2, s3 = state[4 * col : 4 * col + 4]
                state[4 * col + 0] = _gf256_aes_mul(2, s0) ^ _gf256_aes_mul(3, s1) ^ s2 ^ s3
                state[4 * col + 1] = s0 ^ _gf256_aes_mul(2, s1) ^ _gf256_aes_mul(3, s2) ^ s3
                state[4 * col + 2] = s0 ^ s1 ^ _gf256_aes_mul(2, s2) ^ _gf256_aes_mul(3, s3)
                state[4 * col + 3] = _gf256_aes_mul(3, s0) ^ s1 ^ s2 ^ _gf256_aes_mul(2, s3)
        add_round_key(rnd)

    return bytes(state)


def python_nist_keccak_f200(block25: bytes) -> bytes:
    """Independent NIST FIPS-202 Section 3.2 `Keccak-f[200]` (`w = 8`, `18` rounds)."""
    assert len(block25) == 25
    lanes = [[block25[5 * y + x] for y in range(5)] for x in range(5)]
    rot8 = lambda v, r: ((v << (r % 8)) | (v >> ((8 - (r % 8)) % 8))) & 0xFF

    rho_offsets = [
        [0, 36, 3, 41, 18],
        [1, 44, 10, 45, 2],
        [62, 6, 43, 15, 61],
        [28, 55, 25, 21, 56],
        [27, 20, 39, 8, 14],
    ]
    rc_18 = [
        0x01, 0x82, 0x8A, 0x00, 0x8B, 0x01, 0x81, 0x09, 0x8A,
        0x88, 0x09, 0x0A, 0x8B, 0x8B, 0x89, 0x03, 0x02, 0x80,
    ]

    for rnd in range(18):
        # theta
        c = [lanes[x][0] ^ lanes[x][1] ^ lanes[x][2] ^ lanes[x][3] ^ lanes[x][4] for x in range(5)]
        d = [c[(x - 1) % 5] ^ rot8(c[(x + 1) % 5], 1) for x in range(5)]
        for x in range(5):
            for y in range(5):
                lanes[x][y] ^= d[x]
        # rho & pi
        b_lanes = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                b_lanes[y][(2 * x + 3 * y) % 5] = rot8(lanes[x][y], rho_offsets[x][y])
        # chi
        for x in range(5):
            for y in range(5):
                lanes[x][y] = b_lanes[x][y] ^ ((~b_lanes[(x + 1) % 5][y] & 0xFF) & b_lanes[(x + 2) % 5][y])
        # iota
        lanes[0][0] ^= rc_18[rnd]

    return bytes(lanes[x][y] for y in range(5) for x in range(5))


# =============================================================================
# 3. Quantum Superposition Simulators (`Qiskit Aer` + `Stim`)
# =============================================================================

def _apply_lakefill_unitary_gates_qiskit(qc: QuantumCircuit, gates: List[List[Any]]) -> None:
    for g in gates:
        op = g[0]
        if op == "x":
            qc.x(int(g[1]))
        elif op == "cx":
            qc.cx(int(g[1]), int(g[2]))
        elif op == "ccx":
            qc.ccx(int(g[1]), int(g[2]), int(g[3]))
        elif op == "swap":
            qc.swap(int(g[1]), int(g[2]))
        elif op == "h":
            qc.h(int(g[1]))
        elif op == "z":
            qc.z(int(g[1]))
        elif op == "cz":
            qc.cz(int(g[1]), int(g[2]))
        elif op == "ccz":
            c1, c2, t = int(g[1]), int(g[2]), int(g[3])
            qc.h(t)
            qc.ccx(c1, c2, t)
            qc.h(t)
        else:
            raise ValueError(f"Unexpected unitary gate op: {g}")


def _gf4_mul(a: int, b: int) -> int:
    a0, a1 = a & 1, (a >> 1) & 1
    b0, b1 = b & 1, (b >> 1) & 1
    return ((a0 & b0) ^ (a1 & b1)) | ((((a0 & b1) ^ (a1 & b0) ^ (a1 & b1))) << 1)


def _gf16_tower_inv_ref(x: int) -> int:
    xl, xh = x & 3, (x >> 2) & 3
    cl = xl ^ xh
    usq = ((xh >> 1) & 1) | ((xh & 1) << 1)
    d = _gf4_mul(xl, cl) ^ usq
    dinv = ((d & 1) ^ ((d >> 1) & 1)) | (((d >> 1) & 1) << 1)
    return _gf4_mul(cl, dinv) | (_gf4_mul(xh, dinv) << 2)


def _keccak_chi5_ref(a: int) -> int:
    out = 0
    for x in range(5):
        ax = (a >> x) & 1
        ax1 = (a >> ((x + 1) % 5)) & 1
        ax2 = (a >> ((x + 2) % 5)) & 1
        out |= (ax ^ ((1 - ax1) & ax2)) << x
    return out


def verify_quantum_superposition_gadgets(gadgets: Dict[str, Any]) -> Dict[str, Any]:
    aer_sim = AerSimulator(method="statevector")

    # -------------------------------------------------------------------------
    # A. `gf16_tower_inv_12q` on Qiskit Aer (12 qubits, 16-state superposition)
    # -------------------------------------------------------------------------
    g_gf16 = gadgets["gf16_tower_inv_12q"]
    qc_gf16 = QuantumCircuit(12)
    for q in range(4):
        qc_gf16.h(q)
    _apply_lakefill_unitary_gates_qiskit(qc_gf16, g_gf16["gates"])
    qc_gf16.save_statevector()
    sv_gf16_obj = aer_sim.run(qc_gf16).result().get_statevector(qc_gf16)
    sv_gf16 = np.asarray(sv_gf16_obj, dtype=np.complex128)

    target_gf16 = np.zeros(1 << 12, dtype=np.complex128)
    for x in range(16):
        inv_x = _gf16_tower_inv_ref(x)
        target_gf16[x | (inv_x << 4)] = 0.25
    fid_gf16 = float(np.abs(np.vdot(target_gf16, sv_gf16)) ** 2)
    leak_gf16 = float(np.sum(np.abs(sv_gf16[1 << 8 :]) ** 2))
    rho_gf16_data = partial_trace(sv_gf16_obj, [8, 9, 10, 11])
    pur_gf16 = float(np.real(purity(rho_gf16_data)))
    assert abs(fid_gf16 - 1.0) < 1e-11, f"GF(2^4) tower inv fidelity {fid_gf16} != 1.0"
    assert leak_gf16 < 1e-12, f"GF(2^4) tower inv ancilla leakage {leak_gf16}"
    assert abs(pur_gf16 - 1.0) < 1e-11, f"GF(2^4) data purity {pur_gf16} != 1.0"

    # -------------------------------------------------------------------------
    # B. `keccak_chi5_inplace_15q` on Qiskit Aer (15 qubits, 32-row superpos)
    # -------------------------------------------------------------------------
    g_chi5 = gadgets["keccak_chi5_inplace_15q"]
    qc_chi5 = QuantumCircuit(15)
    for q in range(5):
        qc_chi5.h(q)
    _apply_lakefill_unitary_gates_qiskit(qc_chi5, g_chi5["gates"])
    qc_chi5.save_statevector()
    sv_chi5_obj = aer_sim.run(qc_chi5).result().get_statevector(qc_chi5)
    sv_chi5 = np.asarray(sv_chi5_obj, dtype=np.complex128)

    target_chi5 = np.zeros(1 << 15, dtype=np.complex128)
    amp32 = 1.0 / np.sqrt(32.0)
    for a in range(32):
        target_chi5[_keccak_chi5_ref(a)] = amp32
    fid_chi5 = float(np.abs(np.vdot(target_chi5, sv_chi5)) ** 2)
    leak_chi5 = float(np.sum(np.abs(sv_chi5[1 << 5 :]) ** 2))
    rho_chi5_data = partial_trace(sv_chi5_obj, list(range(5, 15)))
    pur_chi5 = float(np.real(purity(rho_chi5_data)))
    assert abs(fid_chi5 - 1.0) < 1e-11, f"Keccak chi_5 fidelity {fid_chi5} != 1.0"
    assert leak_chi5 < 1e-12, f"Keccak chi_5 scratch-plane leakage {leak_chi5}"
    assert abs(pur_chi5 - 1.0) < 1e-11, f"Keccak chi_5 data purity {pur_chi5} != 1.0"

    # -------------------------------------------------------------------------
    # C. `gidney_adder_mbu_11q` on Qiskit Aer Dynamic Feed-Forward Statevector
    # -------------------------------------------------------------------------
    g_gidney = gadgets["gidney_adder_mbu_11q"]

    def build_gidney_dynamic_qc(include_cz_fixup: bool) -> QuantumCircuit:
        qr = QuantumRegister(11, "q")
        cr = ClassicalRegister(3, "m")
        qc = QuantumCircuit(qr, cr)
        for q in range(8):
            qc.h(q)
        m_idx = 0
        for g in g_gidney["gates"]:
            op = g[0]
            if op == "ccx":
                qc.ccx(int(g[1]), int(g[2]), int(g[3]))
            elif op == "cx":
                qc.cx(int(g[1]), int(g[2]))
            elif op == "mid-meas-x-cond-cz":
                anc, c1, c2 = int(g[1]), int(g[2]), int(g[3])
                qc.h(anc)
                qc.measure(anc, cr[m_idx])
                with qc.if_test((cr[m_idx], 1)):
                    qc.x(anc)
                    if include_cz_fixup:
                        qc.cz(c1, c2)
                m_idx += 1
            else:
                raise ValueError(f"Unexpected Gidney gate: {g}")
        qc.save_statevector()
        return qc

    target_gidney = np.zeros(1 << 11, dtype=np.complex128)
    for a in range(16):
        for b in range(16):
            s = (a + b) & 0xF
            target_gidney[a | (s << 4)] = 1.0 / 16.0

    qc_gidney_ok = build_gidney_dynamic_qc(include_cz_fixup=True)
    gidney_fidelities: List[float] = []
    gidney_leakages: List[float] = []
    observed_masks: set[str] = set()
    for seed in range(16):
        res_g = aer_sim.run(qc_gidney_ok, shots=1, seed_simulator=1000 + seed).result()
        counts_g = res_g.get_counts(qc_gidney_ok)
        observed_masks.update(counts_g.keys())
        sv_g = np.asarray(res_g.get_statevector(qc_gidney_ok), dtype=np.complex128)
        gidney_fidelities.append(float(np.abs(np.vdot(target_gidney, sv_g)) ** 2))
        gidney_leakages.append(float(np.sum(np.abs(sv_g[1 << 8 :]) ** 2)))

    assert min(gidney_fidelities) > 1.0 - 1e-11, f"Gidney MBU fidelity drop: {gidney_fidelities}"
    assert max(gidney_leakages) < 1e-12, f"Gidney MBU ancilla leakage: {gidney_leakages}"
    assert len(observed_masks) >= 4, f"Expected multiple M_X masks, saw {observed_masks}"

    # Negative control: omit `cz` phase fixup -> any nonzero measurement mask corrupts phase!
    qc_gidney_broken = build_gidney_dynamic_qc(include_cz_fixup=False)
    broken_min_fidelity = 1.0
    for seed in range(16):
        res_b = aer_sim.run(qc_gidney_broken, shots=1, seed_simulator=2000 + seed).result()
        sv_b = np.asarray(res_b.get_statevector(qc_gidney_broken), dtype=np.complex128)
        broken_min_fidelity = min(broken_min_fidelity, float(np.abs(np.vdot(target_gidney, sv_b)) ** 2))
    assert broken_min_fidelity < 0.7, f"Expected phase-taint fidelity collapse without CZ, got {broken_min_fidelity}"

    # -------------------------------------------------------------------------
    # D. `clifford_mbu_stim_3q` & 64-Qubit Choi `aes_mixcolumns_clifford_32q` on Stim
    # -------------------------------------------------------------------------
    g_stim_mbu = gadgets["clifford_mbu_stim_3q"]
    target_stim_3q = np.array([0.5, 0.5, 0.5, 0.5, 0.0, 0.0, 0.0, 0.0], dtype=np.complex128)
    stim_branch_fidelities: Dict[str, float] = {}
    stim_no_fixup_m1_fidelity = 1.0

    for desired in [False, True]:
        for with_fixup in ([True, False] if desired else [True]):
            ts = stim.TableauSimulator()
            ts.h(0)
            ts.h(1)
            for g in g_stim_mbu["gates"]:
                op = g[0]
                if op == "cx":
                    ts.cnot(int(g[1]), int(g[2]))
                elif op == "mid-meas-x-cond-z":
                    anc, ctrl = int(g[1]), int(g[2])
                    ts.h(anc)
                    ts.postselect_z(anc, desired_value=desired)
                    if desired:
                        ts.x(anc)
                        if with_fixup:
                            ts.z(ctrl)
                else:
                    raise ValueError(f"Unexpected Stim MBU gate: {g}")
            sv_s = np.asarray(ts.state_vector(endian="little"), dtype=np.complex128)
            fid_s = float(np.abs(np.vdot(target_stim_3q, sv_s)) ** 2)
            if with_fixup:
                stim_branch_fidelities[f"m={int(desired)}"] = fid_s
                assert abs(fid_s - 1.0) < 1e-11, f"Stim MBU fidelity {fid_s} != 1.0"
            else:
                stim_no_fixup_m1_fidelity = fid_s
                assert fid_s < 1e-11, f"Expected orthogonal phase taint on m=1 without Z fixup, got {fid_s}"

    # 64-Qubit Choi-Jamiolkowski Bell entanglement test for 32-qubit AES MixColumns in Stim!
    g_mix32 = gadgets["aes_mixcolumns_clifford_32q"]
    ts_choi = stim.TableauSimulator()
    for q in range(32):
        ts_choi.h(q)
        ts_choi.cnot(q, 32 + q)

    def apply_stim_clifford_gates(sim: stim.TableauSimulator, gate_list: List[List[Any]]) -> None:
        for g in gate_list:
            if g[0] == "cx":
                sim.cnot(int(g[1]), int(g[2]))
            elif g[0] == "swap":
                sim.swap(int(g[1]), int(g[2]))
            else:
                raise ValueError(f"Unexpected Clifford MixColumns gate: {g}")

    apply_stim_clifford_gates(ts_choi, g_mix32["gates"])
    # Also verify exact 32-bit column transformation on a concrete basis state in Stim (`0xdb135345 -> 0x8e4da1bc`? Let's check FIPS-197 `[db 13 53 45]` -> `[8e 4d a1 bc]`!)
    ts_vec = stim.TableauSimulator()
    fips_in_bytes = [0xDB, 0x13, 0x53, 0x45]
    for byte_idx, val in enumerate(fips_in_bytes):
        for bit in range(8):
            if (val >> bit) & 1:
                ts_vec.x(8 * byte_idx + bit)
    apply_stim_clifford_gates(ts_vec, g_mix32["gates"])
    out_bits = [int(ts_vec.measure(i)) for i in range(32)]
    stim_mixcol_out_bytes = [
        sum(out_bits[8 * byte_idx + bit] << bit for bit in range(8)) for byte_idx in range(4)
    ]
    assert stim_mixcol_out_bytes == [0x8E, 0x4D, 0xA1, 0xBC], (
        f"Stim MixColumns FIPS-197 mismatch: got {[hex(b) for b in stim_mixcol_out_bytes]}"
    )

    # Uncompute 64-qubit Choi state via syntactic `invert-circuit` (reversed self-inverse `cx`/`swap` list)
    apply_stim_clifford_gates(ts_choi, list(reversed(g_mix32["gates"])))
    for q in range(32):
        ts_choi.cnot(q, 32 + q)
        ts_choi.h(q)
    choi_zero_restored = sum(1 for q in range(64) if ts_choi.peek_z(q) == 1)
    assert choi_zero_restored == 64, f"Expected 64/64 Choi-Bell qubits restored to |0>, got {choi_zero_restored}"

    return {
        "qiskit_aer_gf16_tower_inv_12q": {
            "num_qubits": 12,
            "superposition_basis_terms": 16,
            "gate_count": len(g_gf16["gates"]),
            "statevector_fidelity": round(fid_gf16, 12),
            "ancilla_leakage_prob": round(leak_gf16, 15),
            "reduced_data_purity_tr_rho2": round(pur_gf16, 12),
        },
        "qiskit_aer_keccak_chi5_inplace_15q": {
            "num_qubits": 15,
            "superposition_basis_terms": 32,
            "gate_count": len(g_chi5["gates"]),
            "statevector_fidelity": round(fid_chi5, 12),
            "ancilla_leakage_prob": round(leak_chi5, 15),
            "reduced_data_purity_tr_rho2": round(pur_chi5, 12),
        },
        "qiskit_aer_gidney_mbu_adder_11q": {
            "num_qubits": 11,
            "superposition_basis_terms": 256,
            "toffoli_count": 3,
            "dynamic_mbu_measurements": 3,
            "stochastic_trajectories_tested": 16,
            "distinct_mx_masks_sampled": sorted(observed_masks),
            "min_statevector_fidelity": round(min(gidney_fidelities), 12),
            "max_ancilla_leakage_prob": round(max(gidney_leakages), 15),
            "negative_control_without_cz_min_fidelity": round(broken_min_fidelity, 6),
        },
        "stim_tableau_superposition_checks": {
            "clifford_mbu_3q_branch_fidelities": stim_branch_fidelities,
            "clifford_mbu_3q_no_fixup_m1_fidelity": round(stim_no_fixup_m1_fidelity, 12),
            "aes_mixcolumns_32q_gate_count": len(g_mix32["gates"]),
            "aes_mixcolumns_fips197_db135345_hex": "".join(f"{b:02x}" for b in stim_mixcol_out_bytes),
            "aes_mixcolumns_64q_choi_bell_qubits_restored": f"{choi_zero_restored}/64",
        },
    }


# =============================================================================
# 4. Lean 4.35.0 Proof Compilation & Structural Hygiene Audit
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
        "theorem_54a_boyar_peralta_gf256_tower_involution_and_within_apply_zero_ancilla",
        "theorem_54b_maximov_aes_mixcolumns_cx_network_bitvec32_invertibility",
        "theorem_54c_aes256_14round_within_apply_grover_oracle_zero_ancilla_restoration",
        "theorem_54d_keccak_chi_step_ccx_within_apply_scratch_plane_bijection_and_uncompute",
        "theorem_54e_gidney_temp_and_mbu_mx_cond_z_preserves_coherent_sum_zero_taint",
        "theorem_54f_bch_15_7_5_121_of_121_peterson_berlekamp_lakefill_uncomputation_exactness",
        "phase36_lakefill_lisp_nist_cryptography_master_closure",
    ]
    for thm in required_theorems:
        assert f"theorem {thm}" in cleaned, f"Missing required Theorem `{thm}` in {LEAN_PROOF_PATH.name}"

    for forbidden in ["sorry", "admit", "unsafe", "implemented_by", "extern"]:
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
    assert max_lines <= 25, f"Theorem proof exceeded 25-line limit: max={max_lines}"

    lean_bin = _resolve_binary(
        "lean",
        [
            Path.home() / ".local" / "bin" / "lean",
            Path.home() / "toolchains" / "lean4-p36t2" / "lean-4.35.0-linux" / "bin" / "lean",
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
    assert "true" in proc.stdout.splitlines(), (
        f"Expected `#eval verifyPhase36LakefillLispNistSanity ()` -> `true`, got: {proc.stdout!r}"
    )

    return {
        "lean_proof_file": str(LEAN_PROOF_PATH.relative_to(REPO_ROOT)),
        "lean_compile_exit_code": proc.returncode,
        "lean_compile_time_ms": lean_ms,
        "eval_sanity_output": proc.stdout.strip(),
        "total_theorems_and_helpers": len(blocks),
        "core_theorems_54a_to_54g": required_theorems,
        "median_proof_lines": round(float(statistics.median(proof_lengths)), 1),
        "max_proof_lines": max_lines,
        "zero_sorry_admit_axiom": True,
    }


# =============================================================================
# 5. End-to-End Orchestration & JSON Artifact Generation
# =============================================================================

def run_end_to_end_verification() -> Dict[str, Any]:
    t0 = time.perf_counter()
    assert RACKET_IMPL_PATH.exists(), f"Missing Racket file: {RACKET_IMPL_PATH}"

    racket_bin = _resolve_binary(
        "racket",
        [
            Path.home() / ".local" / "bin" / "racket",
            Path.home() / "toolchains" / "racket-p36t2" / "racket" / "bin" / "racket",
        ],
    )
    proc_rkt = subprocess.run(
        [racket_bin, str(RACKET_IMPL_PATH)],
        cwd=str(REPO_ROOT),
        env=_clean_subprocess_env(),
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc_rkt.returncode == 0, (
        f"Racket verification failed (rc={proc_rkt.returncode}):\n{proc_rkt.stdout}\n{proc_rkt.stderr}"
    )
    rkt_data = json.loads(proc_rkt.stdout)
    assert rkt_data["status"] == "PASS"

    # Cross-verify NIST FIPS-197 C.1 / C.2 / C.3 against independent Python AES
    expected_fips197 = {
        128: (
            "00112233445566778899aabbccddeeff",
            "000102030405060708090a0b0c0d0e0f",
            "69c4e0d86a7b0430d8cdb78070b4c55a",
        ),
        192: (
            "00112233445566778899aabbccddeeff",
            "000102030405060708090a0b0c0d0e0f1011121314151617",
            "dda97ca4864cdfe06eaf70a0ec0d7191",
        ),
        256: (
            "00112233445566778899aabbccddeeff",
            "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
            "8ea2b7ca516745bfeafc49904b496089",
        ),
    }
    by_bits = {int(entry["key_bits"]): entry for entry in rkt_data["nist_fips197_vectors"]}
    for kbits, (pt_hex, key_hex, exp_ct_hex) in expected_fips197.items():
        py_ct_hex = python_nist_aes_encrypt_block(
            bytes.fromhex(pt_hex), bytes.fromhex(key_hex)
        ).hex()
        assert py_ct_hex == exp_ct_hex, f"Python AES-{kbits} mismatch: {py_ct_hex}"
        entry = by_bits[kbits]
        assert entry["ciphertext_hex"] == py_ct_hex, f"Racket AES-{kbits} mismatch: {entry}"
        assert entry["nist_fips197_exact_match"] is True
        assert entry["inverse_decryption_exact"] is True
        assert entry["ancilla_leakage_bits"] == 0
        assert entry["grover_oracle_phase_hit"] == -1
        assert entry["grover_oracle_phase_miss"] == 1

    # Cross-verify NIST FIPS-202 18-round `Keccak-f[200]`
    py_keccak_zero_hex = python_nist_keccak_f200(bytes(25)).hex()
    k_entry = rkt_data["keccak_f200_reversible"]
    assert k_entry["zero_block_output_hex"] == py_keccak_zero_hex, (
        f"Keccak-f[200] mismatch: Racket={k_entry['zero_block_output_hex']} vs Python={py_keccak_zero_hex}"
    )
    assert k_entry["ancilla_leakage_bits"] == 0
    assert k_entry["inverse_circuit_roundtrip_exact"] is True

    # Verify Gidney MBU & BCH(15, 7, 5) metrics
    g_entry = rkt_data["gidney_mbu_arithmetic"]
    assert g_entry["gidney_4bit_toffoli_count"] == 3
    assert g_entry["gidney_4bit_mbu_count"] == 3
    assert g_entry["exhaustive_256_pairs_x_8_mbu_branches_verified"] is True
    assert g_entry["modular_adder_mod13_169_pairs_verified"] is True
    assert g_entry["schoolbook_multiplier_4bit_256_pairs_verified"] is True

    bch_entry = rkt_data["bch_15_7_5_dqi_syndrome_uncompute"]
    assert bch_entry["weight_le_2_masks_tested"] == 121
    assert bch_entry["weight_le_2_masks_uncomputed"] == 121
    assert bch_entry["syndrome_restored_to"] == "00000000"
    assert bch_entry["ancilla_leakage_bits"] == 0

    # Quantum superposition verification (`Qiskit Aer` + `Stim`)
    quantum_superpos_report = verify_quantum_superposition_gadgets(
        rkt_data["exported_quantum_gadgets"]
    )

    # Lean 4.35.0 compilation & proof audit
    lean_report = verify_and_compile_lean4_proofs()

    total_ms = round((time.perf_counter() - t0) * 1000.0, 2)
    qasm_sha256 = hashlib.sha256(
        g_entry["gidney_4bit_openqasm3"].encode("utf-8")
    ).hexdigest()

    report: Dict[str, Any] = {
        "phase": "Phase 36 (Track 2 — Part 54, Suite 147)",
        "title": "Executable #lang racket Lakefill Lisp Cryptographic Implementations, Quantum Superposition Simulation & Lean 4 Soundness Proofs",
        "all_checks_passed": True,
        "total_runtime_ms": total_ms,
        "racket_lakefill_module": {
            "path": str(RACKET_IMPL_PATH.relative_to(REPO_ROOT)),
            "racket_version": rkt_data["racket_version"],
            "racket_wall_time_ms": float(rkt_data["wall_time_ms"]),
            "aes_sbox_boyar_peralta_tower": rkt_data["aes_sbox_boyar_peralta_tower"],
            "nist_fips197_vectors": rkt_data["nist_fips197_vectors"],
            "keccak_f200_reversible": k_entry,
            "gidney_mbu_arithmetic": {
                k: v for k, v in g_entry.items() if k != "gidney_4bit_openqasm3"
            }
            | {"gidney_4bit_openqasm3_sha256": qasm_sha256},
            "bch_15_7_5_dqi_syndrome_uncompute": bch_entry,
        },
        "quantum_superposition_verification": quantum_superpos_report,
        "lean4_formal_proofs": lean_report,
    }

    REPORT_JSON_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_JSON_PATH.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report


def main() -> None:
    report = run_end_to_end_verification()
    rkt = report["racket_lakefill_module"]
    qsup = report["quantum_superposition_verification"]
    lean = report["lean4_formal_proofs"]
    vecs = {v["key_bits"]: v for v in rkt["nist_fips197_vectors"]}

    print("=" * 96)
    print("  PHASE 36 (PART 54 / SUITE 147): LAKEFILL LISP NIST CRYPTOGRAPHY & QUANTUM VERIFICATION")
    print("=" * 96)
    print(f"  Racket Lakefill Module          : {rkt['path']} (Racket v{rkt['racket_version']}, {rkt['racket_wall_time_ms']:.2f} ms)")
    print(f"  AES-128 (FIPS-197 C.1)          : {vecs[128]['ciphertext_hex']} ({vecs[128]['encrypt_gate_counts']['total_physical_gates']} gates, 0 leakage)")
    print(f"  AES-192 (FIPS-197 C.2)          : {vecs[192]['ciphertext_hex']} ({vecs[192]['encrypt_gate_counts']['total_physical_gates']} gates, 0 leakage)")
    print(f"  AES-256 (FIPS-197 C.3)          : {vecs[256]['ciphertext_hex']} ({vecs[256]['encrypt_gate_counts']['total_physical_gates']} gates, 0 leakage)")
    print(f"  Keccak-f[200] (18-Round)        : {rkt['keccak_f200_reversible']['zero_block_output_hex']} ({rkt['keccak_f200_reversible']['gate_counts']['total_physical_gates']} gates)")
    print(
        f"  Gidney MBU Adder (Qiskit Aer)   : fidelity={qsup['qiskit_aer_gidney_mbu_adder_11q']['min_statevector_fidelity']:.12f} "
        f"(3 CCX, 0 uncompute CCX, no-CZ control={qsup['qiskit_aer_gidney_mbu_adder_11q']['negative_control_without_cz_min_fidelity']:.4f})"
    )
    print(
        f"  GF(2^4) & Keccak-chi5 (Aer)     : gf16_fid={qsup['qiskit_aer_gf16_tower_inv_12q']['statevector_fidelity']:.12f}, "
        f"chi5_fid={qsup['qiskit_aer_keccak_chi5_inplace_15q']['statevector_fidelity']:.12f}"
    )
    print(
        f"  Stim Tableau MBU & 64q Choi     : {qsup['stim_tableau_superposition_checks']['clifford_mbu_3q_branch_fidelities']}, "
        f"Choi restored={qsup['stim_tableau_superposition_checks']['aes_mixcolumns_64q_choi_bell_qubits_restored']}"
    )
    print(
        f"  BCH(15, 7, 5) DQI Erasure       : {rkt['bch_15_7_5_dqi_syndrome_uncompute']['weight_le_2_masks_uncomputed']}/121 syndromes -> 00000000 "
        f"({rkt['bch_15_7_5_dqi_syndrome_uncompute']['gate_counts']['total_physical_gates']} gates)"
    )
    print(
        f"  Lean 4.35.0 Proofs (54A-54G)    : {lean['lean_proof_file']} (exit={lean['lean_compile_exit_code']}, "
        f"max_lines={lean['max_proof_lines']}, {lean['lean_compile_time_ms']:.2f} ms)"
    )
    print(f"  Artifact Report Written         : {REPORT_JSON_PATH.relative_to(REPO_ROOT)}")
    print(f"  STATUS                          : PASS in {report['total_runtime_ms']:.2f} ms")
    print("=" * 96)


if __name__ == "__main__":
    main()
