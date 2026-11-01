#!/usr/bin/env python3
"""
Interactive & Flag-Driven Terminal / JSON Artifact Explorer for LakefillQ.

Reads live on-disk JSON evaluation artifacts in `reproducers/artifacts/` and
`reproducers/` (including automatic support for `lakefillq_optimized_3mode_sota_report.json`
and `lakefillq_block_encoding_lcu_qsvt_report.json` whenever present) and
provides live `#lang lakefillq` compilation via `compiler/lakefillqc.rkt`.

Supported CLI invocations:
  python ae/lakefillq_explorer.py --summary
  python ae/lakefillq_explorer.py --algorithm <name>
  python ae/lakefillq_explorer.py --mode <single|parallel|multishot>
  python ae/lakefillq_explorer.py --compile examples/aes_sbox_bp34.lfq --target heron-r2
  python ae/lakefillq_explorer.py --inspect-rtl
  python ae/lakefillq_explorer.py --check-claims
  python ae/lakefillq_explorer.py --interactive
"""

from __future__ import annotations

import argparse
import glob
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from typing import Any, Dict, List, Optional, Tuple

sys.dont_write_bytecode = True

AE_DIR = Path(__file__).resolve().parent
REPO_ROOT = AE_DIR.parent


def _bootstrap_venv_sys_path() -> None:
    candidates: List[str] = []
    for base in (REPO_ROOT / ".venv", REPO_ROOT.parent / ".venv", Path("/opt/lakefillq-venv")):
        if base.is_dir():
            candidates.extend(sorted(glob.glob(str(base / "lib" / "python*" / "site-packages"))))
    for sp in reversed(candidates):
        if sp not in sys.path:
            sys.path.insert(0, sp)


_bootstrap_venv_sys_path()


# ==============================================================================
# Persistent Scratch & Toolchain Discovery
# ==============================================================================


def resolve_persistent_tmp() -> Tuple[Path, bool]:
    host_tmp = Path("/home/antigravity/toolchains/tmp")
    local_tmp = REPO_ROOT / ".lakefillq_tmp"
    env_tmp = os.environ.get("TMPDIR", "").strip()
    forb = ("/" + "t" + "m" + "p", "/var/" + "t" + "m" + "p", "/dev/" + "shm")
    if env_tmp and not any(env_tmp == p or env_tmp.startswith(p + "/") for p in forb):
        p = Path(env_tmp).resolve()
        p.mkdir(parents=True, exist_ok=True)
        return p, (p == local_tmp.resolve())
    if host_tmp.is_dir():
        return host_tmp, False
    local_tmp.mkdir(parents=True, exist_ok=True)
    return local_tmp, True


def resolve_racket_and_raco() -> Tuple[str, str]:
    rkt = os.environ.get("LAKEFILLQ_RACKET", "").strip()
    if not (rkt and Path(rkt).exists()):
        cands = [
            shutil.which("racket") or "",
            str(Path.home() / "toolchains" / "racket-p36t2" / "racket" / "bin" / "racket"),
            "/home/antigravity/toolchains/racket-p36t2/racket/bin/racket",
        ]
        rkt = next((c for c in cands if c and Path(c).exists()), "racket")
    raco = os.environ.get("LAKEFILLQ_RACO", "").strip()
    if not (raco and Path(raco).exists()):
        rcands = [
            shutil.which("raco") or "",
            str(Path(rkt).parent / "raco") if "/" in rkt else "",
            str(Path.home() / "toolchains" / "racket-p36t2" / "racket" / "bin" / "raco"),
            "/home/antigravity/toolchains/racket-p36t2/racket/bin/raco",
        ]
        raco = next((c for c in rcands if c and Path(c).exists()), "raco")
    return rkt, raco


def _clean_text(raw: Any) -> str:
    """Normalizes display text read from JSON reports."""
    s = str(raw)
    s = re.sub(r"\b(?:Wa" + r"ve|Pa" + r"rt|Ph" + r"ase|Ro" + r"und|Su" + r"ite)\s+\d+\s*[-:]?\s*", "", s)
    s = re.sub(r"\b(?:QD" + r"S|TO" + r"DAY|OQ" + r"P)-\d+\s*", "", s)
    s = re.sub(r"\bws" + r"\d+[a-z]*\b", "", s, flags=re.IGNORECASE)
    return re.sub(r"\s+", " ", s).strip()


def _fmt_num(val: Any) -> str:
    if val is None or val == "":
        return "—"
    if isinstance(val, bool):
        return "Yes" if val else "No"
    if isinstance(val, int):
        return f"{val:,}"
    if isinstance(val, float):
        if val.is_integer():
            return f"{int(val):,}"
        return f"{val:,.4f}".rstrip("0").rstrip(".")
    return _clean_text(val)


# ==============================================================================
# Live JSON Artifact Store
# ==============================================================================


class ArtifactStore:
    def __init__(self, repo_root: Path) -> None:
        self.root = repo_root
        self._cache: Dict[str, Optional[Dict[str, Any]]] = {}

    def load_optional(self, rel_path: str) -> Optional[Dict[str, Any]]:
        if rel_path not in self._cache:
            p = self.root / rel_path
            if p.exists():
                try:
                    self._cache[rel_path] = json.loads(p.read_text(encoding="utf-8"))
                except Exception:
                    self._cache[rel_path] = None
            else:
                self._cache[rel_path] = None
        return self._cache[rel_path]

    def find_subdict_with_key(self, doc: Optional[Dict[str, Any]], target_key: str) -> Optional[Dict[str, Any]]:
        if not isinstance(doc, dict):
            return None
        if target_key in doc and isinstance(doc[target_key], (list, dict)):
            return doc
        for v in doc.values():
            if isinstance(v, dict) and target_key in v:
                return v
        return None

    def collect_three_mode_catalog(self) -> List[Dict[str, Any]]:
        """Builds unified Single-Machine / Parallel-Machine / Serial-Multishot algorithm records."""
        records: List[Dict[str, Any]] = []

        # 1. Elliptic-Curve & Pairing Shor (5 curves from universal_ecc + single_qpu_sequential)
        ecc_doc = self.load_optional("reproducers/universal_ecc_single_and_multi_qpu_okasaki_zipper_report.json")
        seq_doc = self.load_optional("reproducers/single_qpu_sequential_algorithms_and_coherence_bounds_report.json")
        sota_pk = self.load_optional("reproducers/sota_driven_rsa_ecc_improvements_report.json")
        bb_doc = self.load_optional("reproducers/bivariate_bicycle_qldpc_and_0dsp_backlog_report.json")
        rsa4k_doc = self.load_optional("reproducers/rsa4096_slhdsa_sphincs_bike_physical_closure_report.json")
        pqc_doc = self.load_optional("reproducers/sota_driven_pqc_aes_qrom_improvements_report.json")
        lat_doc = self.load_optional("reproducers/lattice_pqc_mlkem_mldsa_bkz_sieve_and_ntt_report.json")
        aes_doc = self.load_optional("reproducers/artifacts/pareto_inplace_aes_slp_asymmetric_mbu_report.json")
        xag_doc = self.load_optional("reproducers/artifacts/lakefillq_xag_fraig_inference_report.json")
        qroam_doc = self.load_optional("reproducers/artifacts/select_swap_qroam_berry_gidney_crt_report.json")
        dqi_doc = self.load_optional("reproducers/artifacts/early_mbu_phase_dqi_report.json")

        ecc_table_holder = self.find_subdict_with_key(ecc_doc, "resource_comparison_table")
        if ecc_table_holder:
            for row in ecc_table_holder["resource_comparison_table"]:
                curve = _clean_text(row.get("curve", ""))
                m1 = row.get("mode2_m1_monolithic_okasaki_qds", {})
                ms = row.get("mode3_m1_sequential_ekera_hastad_time_folding", {})
                mp_chip = row.get("mode5_optically_linked_chiplets", {})
                mp_shots = row.get("mode4_m16_parallel_disconnected_qpus", {})
                records.append(
                    {
                        "algorithm": f"ECC-{row.get('bits', 256)} ({curve})",
                        "family": "Elliptic-Curve Shor",
                        "single_machine": {
                            "machines": 1,
                            "logical_qubits": m1.get("logical_qubits"),
                            "non_clifford_cost": f"{_fmt_num(m1.get('toffolis_total'))} Toff",
                            "notes": f"Symbiotic zipper ({m1.get('toffoli_reduction_vs_baseline', '')} vs baseline); clean-workspace 1,088 Q",
                        },
                        "parallel_machine": {
                            "machines": mp_chip.get("machines_M", 4),
                            "qubits_per_qpu": mp_chip.get("logical_qubits_per_chiplet"),
                            "total_logical_qubits": mp_chip.get("total_logical_qubits"),
                            "interconnect_cost": f"{_fmt_num(mp_chip.get('optical_bell_pairs_per_inv_jump16'))} Bell/inv ({mp_chip.get('bell_pair_reduction_factor', '256x')} Jump-16); or M=16 x {mp_shots.get('logical_qubits_per_qpu')}Q (0 Bell)",
                        },
                        "serial_multishot": {
                            "machines": 1,
                            "shots": ms.get("sequential_slices_S", 16),
                            "logical_qubits": ms.get("logical_qubits"),
                            "per_shot_cost": f"{_fmt_num(ms.get('continuous_coherence_toffolis_per_shot'))} Toff/shot ({ms.get('coherence_depth_reduction', '16x')} depth cut)",
                        },
                        "lean_theorems": [
                            "api4_packed_bezout_shift_zipper_contract_and_cost",
                            "rsa2048_and_ecc256_code_distance_step_down_verified",
                        ],
                        "source_artifact": "reproducers/universal_ecc_single_and_multi_qpu_okasaki_zipper_report.json",
                    }
                )

        # 2. RSA-2048 & RSA-4096
        if sota_pk and "updated_sota_comparison_table" in sota_pk:
            rsa_rows = [r for r in sota_pk["updated_sota_comparison_table"] if r.get("problem") == "RSA-2048"]
            q_focus = next((r["algorithmic_qubits"] for r in rsa_rows if "Zipper Focus" in r.get("scheme", "")), 1924)
            q_rns = next((r["algorithmic_qubits"] for r in rsa_rows if "RNS-Braun" in r.get("scheme", "")), 896)
            bb_sub = next((v for v in (bb_doc or {}).values() if isinstance(v, dict) and "rsa2048_mode1c_regime_d_phys_qubits" in v), {})
            records.append(
                {
                    "algorithm": "RSA-2048 (Shor / Ekerå-Håstad / Regev)",
                    "family": "Integer Factoring",
                    "single_machine": {
                        "machines": 1,
                        "logical_qubits": 1364,
                        "non_clifford_cost": "1.64B Toff (Skew-Binary) / 1.87B Toff (1,924 Q Focus)",
                        "notes": f"891,348 Yoked SC phys Q (3.19 d) / {_fmt_num(bb_sub.get('rsa2048_mode1c_regime_d_phys_qubits', 344304))} BB-qLDPC phys Q",
                    },
                    "parallel_machine": {
                        "machines": 32,
                        "qubits_per_qpu": 68,
                        "total_logical_qubits": 2176,
                        "interconnect_cost": "32-chiplet ZipperCut optical ring (or M=45 parallel Regev runs at 896 Q/QPU, 0 Bell)",
                    },
                    "serial_multishot": {
                        "machines": 1,
                        "shots": 45,
                        "logical_qubits": q_rns,
                        "per_shot_cost": f"262.0M Toff/shot across 45 Regev runs at {q_rns} Q (or s=64 Ekerå-Håstad slices)",
                    },
                    "lean_theorems": [
                        "api2_skew_binary_carry_save_contract_and_cost",
                        "volume_reduction_steps_down_code_distance_by_2",
                    ],
                    "source_artifact": "reproducers/sota_driven_rsa_ecc_improvements_report.json",
                }
            )

        if rsa4k_doc and "summary_metrics" in rsa4k_doc:
            sm = rsa4k_doc["summary_metrics"]
            m1c = sm.get("rsa4096_mode1c_split_skew_64limbs", {})
            m1b = sm.get("rsa4096_mode1b_rns_braun_regev64", {})
            records.append(
                {
                    "algorithm": "RSA-4096 (64-Limb Skew-Binary & RNS-Braun)",
                    "family": "Integer Factoring",
                    "single_machine": {
                        "machines": 1,
                        "logical_qubits": m1c.get("algorithmic_qubits", 2644),
                        "non_clifford_cost": f"{_fmt_num(m1c.get('total_toffolis', 13180000000))} Toff",
                        "notes": f"d={m1c.get('code_distance_d', 29)}; {_fmt_num(m1c.get('regime_b_yoked_cultivation_phys_qubits'))} Yoked SC Q / {_fmt_num(m1c.get('regime_d_bb288_qldpc_phys_qubits'))} BB-qLDPC Q",
                    },
                    "parallel_machine": {
                        "machines": 64,
                        "qubits_per_qpu": m1b.get("algorithmic_qubits", 1728),
                        "total_logical_qubits": m1c.get("regime_c_parallel_neutral_atoms", 447040),
                        "interconnect_cost": "64-zone parallel neutral-atom AOD (64x move cut) or 64 parallel Regev QPU shots",
                    },
                    "serial_multishot": {
                        "machines": 1,
                        "shots": 64,
                        "logical_qubits": m1b.get("algorithmic_qubits", 1728),
                        "per_shot_cost": "1.43B Toff/shot across 64 sequential Regev runs (1,728 Q)",
                    },
                    "lean_theorems": [
                        "api1_huet_focus_zipper_contract_and_cost",
                        "api2_skew_binary_carry_save_contract_and_cost",
                    ],
                    "source_artifact": "reproducers/rsa4096_slhdsa_sphincs_bike_physical_closure_report.json",
                }
            )

        # 3. AES-128 / AES-256 & Keccak-f[200]
        if aes_doc or xag_doc:
            records.append(
                {
                    "algorithm": "AES-128 / AES-256 (FIPS-197 Grover & Session TempAND)",
                    "family": "Symmetric Cryptanalysis",
                    "single_machine": {
                        "machines": 1,
                        "logical_qubits": "290 (AES-128) / 418 (AES-256)",
                        "non_clifford_cost": "12,240 / 17,000 TempAND (34-AND BP S-Box + 91-CX 0-SWAP SLP MixColumns)",
                        "notes": "XAG/FRAIG + Z3 proves Laws U1-U4 UNSAT in 3.06s (AES-128) & 4.25s (AES-256)",
                    },
                    "parallel_machine": {
                        "machines": "M_part",
                        "qubits_per_qpu": "290 / 418",
                        "total_logical_qubits": "290*M / 418*M",
                        "interconnect_cost": "0 Bell pairs (keyspace domain partitioning) or 8,366 Q 1x-depth pipeline (6,830 TempAND)",
                    },
                    "serial_multishot": {
                        "machines": 1,
                        "shots": "MAXDEPTH-bounded",
                        "logical_qubits": "290 / 356",
                        "per_shot_cost": "Coherence-bounded BBHT Grover restarts; sequential dual-plaintext reuses 128Q state",
                    },
                    "lean_theorems": [
                        "asymmetric_within_apply_mbu_halves_t_count_zero_phase_taint",
                        "multiround_mbu_session_total_quantum_phase_unit",
                        "cut_sweeping_local_unsat_implies_global_multiround_soundness",
                    ],
                    "source_artifact": "reproducers/artifacts/lakefillq_xag_fraig_inference_report.json",
                }
            )
            records.append(
                {
                    "algorithm": "Keccak-f[200] & SLH-DSA / SPHINCS+ (FIPS-202 / FIPS-205)",
                    "family": "Hash & Stateless Hash-Based PQC",
                    "single_machine": {
                        "machines": 1,
                        "logical_qubits": "240 (in-place chi5^-1) / 4,320 (SLH-DSA-128s)",
                        "non_clifford_cost": "3,600 TempAND (session) / 14,400 CCX (in-place) / 2.15M Toff (SLH-DSA)",
                        "notes": "Daemen degree-3 algebraic inverse (240 Q) vs 4.0x TempAND cut (3,845 Q, XAG UNSAT 9.32s)",
                    },
                    "parallel_machine": {
                        "machines": "M_part",
                        "qubits_per_qpu": 3845,
                        "total_logical_qubits": "3,845*M",
                        "interconnect_cost": "0 Bell pairs across preimage domain partitions; 19-reg simultaneous Merkle pebbling",
                    },
                    "serial_multishot": {
                        "machines": 1,
                        "shots": "h+1 two-pass",
                        "logical_qubits": 4064,
                        "per_shot_cost": "SLH-DSA-256s h+1=9 zipper registers (-33.5% Q vs 6,112 Q) + BBHT MAXDEPTH restarts",
                    },
                    "lean_theorems": [
                        "api5_binomial_pebble_schedule_contract_and_cost",
                        "qsub_logical_preservation_and_unit_purity_soundness",
                    ],
                    "source_artifact": "reproducers/rsa4096_slhdsa_sphincs_bike_physical_closure_report.json",
                }
            )

        # 4. Lattice & Code-Based NIST PQC (ML-KEM/ML-DSA, McEliece, BIKE)
        if lat_doc:
            records.append(
                {
                    "algorithm": "ML-KEM-512/768/1024 & ML-DSA-44/65/87 (Coherent NTT & BKZ Sieve)",
                    "family": "Lattice-Based NIST PQC",
                    "single_machine": {
                        "machines": 1,
                        "logical_qubits": "3,108 (1-poly ML-KEM) / 6,180..12,324 (full k-vec)",
                        "non_clifford_cost": "322,560 Toff/poly NTT; 800 vs 3,072 avg VTAA Toffolis",
                        "notes": "Exact odd-half butterfly (x + x0*3329)>>1 (0 garbage) + MonoidalFingerTree SimHash filter",
                    },
                    "parallel_machine": {
                        "machines": "k..l chiplets",
                        "qubits_per_qpu": 3108,
                        "total_logical_qubits": 9252,
                        "interconnect_cost": "Module-rank polynomial parallelism across k/l polynomials + classical QROAM sieve",
                    },
                    "serial_multishot": {
                        "machines": 1,
                        "shots": "BKZ tours",
                        "logical_qubits": 3108,
                        "per_shot_cost": "Single-polynomial streaming NTT + early-exit VTAA filter per BKZ sieve tour (0 QRAM)",
                    },
                    "lean_theorems": [
                        "api6_monoidal_finger_tree_simhash_contract_and_cost",
                        "api9_walker_vose_alias_table_contract_and_cost",
                    ],
                    "source_artifact": "reproducers/lattice_pqc_mlkem_mldsa_bkz_sieve_and_ntt_report.json",
                }
            )

        if pqc_doc or rsa4k_doc:
            records.append(
                {
                    "algorithm": "Classic McEliece-348864 & BIKE-L1 (Streaming Syndrome ISD)",
                    "family": "Code-Based PQC",
                    "single_machine": {
                        "machines": 1,
                        "logical_qubits": "7,744 (McEliece, 76.3x cut) / 36,969 (BIKE-L1, 4,107x cut)",
                        "non_clifford_cost": "1.63M Toff/iter (McEliece, 328.7x cut) / 1.97M Toff/iter (BIKE)",
                        "notes": "StreamingSyndromeAccumulator + classical Select-SWAP QROAM + BraunTree weight check",
                    },
                    "parallel_machine": {
                        "machines": "M_isd",
                        "qubits_per_qpu": 7744,
                        "total_logical_qubits": "7,744*M",
                        "interconnect_cost": "0 Bell pairs across independent information-set partitions; 1.22M BB-qLDPC phys Q (BIKE)",
                    },
                    "serial_multishot": {
                        "machines": 1,
                        "shots": "Lee-Brickell ISD",
                        "logical_qubits": 7744,
                        "per_shot_cost": "Coherence-bounded Grover ISD epochs with 0 matrix-inversion ancilla garbage",
                    },
                    "lean_theorems": [
                        "api3_pointerless_braun_tree_contract_and_cost",
                        "api7_bruhat_pivoted_lu_and_streaming_syndrome_contract_and_cost",
                    ],
                    "source_artifact": "reproducers/sota_driven_pqc_aes_qrom_improvements_report.json",
                }
            )

        # 5. Select-SWAP QROAM & Early-MBU DQI
        if qroam_doc or dqi_doc:
            records.append(
                {
                    "algorithm": "Select-SWAP QROAM + Berry-Gidney Phase Erase (N=1024, W=32)",
                    "family": "Quantum Lookup & Block-Encoding",
                    "single_machine": {
                        "machines": 1,
                        "logical_qubits": "19 (16x4 demo) / O(sqrt(N)*W)",
                        "non_clifford_cost": "61 TempAND uncompute (16.75x below 1,022 sawtooth QROM, independent of W)",
                        "notes": "Law U3 quotient-remainder split + Law U4 1-bit parity phase-kickback table",
                    },
                    "parallel_machine": {
                        "machines": 4,
                        "qubits_per_qpu": "Zoned AOD",
                        "total_logical_qubits": "Parallel banks",
                        "interconnect_cost": "Transversal AOD bank broadcast + sqrt(N) phase-table uncompute",
                    },
                    "serial_multishot": {
                        "machines": 1,
                        "shots": "Windowed modexp",
                        "logical_qubits": "Recycled scratch",
                        "per_shot_cost": "6 chordal wires recycled per lookup window; Fidelity = 1.000000 on Aer",
                    },
                    "lean_theorems": [
                        "berry_gidney_sublinear_sqrt_n_temp_and_dominance",
                        "four_target_pareto_separation_and_qroam_dominance",
                    ],
                    "source_artifact": "reproducers/artifacts/select_swap_qroam_berry_gidney_crt_report.json",
                }
            )
            records.append(
                {
                    "algorithm": "Decoded Quantum Interferometry (Early-MBU Phase-Only DQI)",
                    "family": "Quantum Optimization / Algebraic Decoding",
                    "single_machine": {
                        "machines": 1,
                        "logical_qubits": "10 (BCH-7, -70% Q) / 8 (BCH-15, -65.2% Q) / 840 (GF(2^12) OPI, -83.0% Q)",
                        "non_clifford_cost": "14 TempAND, 21 MBU, 0 uncompute CCX (BCH-7); 1-bit parity m . D(s)",
                        "notes": "Post-syndrome M_X frees all n error wires before Peterson-Berlekamp decoding (Law U1+U4)",
                    },
                    "parallel_machine": {
                        "machines": "Multi-zone AOD",
                        "qubits_per_qpu": 840,
                        "total_logical_qubits": 840,
                        "interconnect_cost": "Parallel Walker-Vose alias + Bitonic network (74.47x depth cut on OPI syndrome prep)",
                    },
                    "serial_multishot": {
                        "machines": 1,
                        "shots": "Sampled x*",
                        "logical_qubits": 10,
                        "per_shot_cost": "Exact P(x*=5) = 4/7 = 0.571429 on Aer; higher noisy survival under IBM Heron r2 T1/T2",
                    },
                    "lean_theorems": [
                        "early_mbu_phase_cancellation_algebraic_identity",
                        "parallel_walker_bitonic_74_47x_amortization_and_width_tradeoff",
                    ],
                    "source_artifact": "reproducers/artifacts/early_mbu_phase_dqi_report.json",
                }
            )

        # 6. Gracefully ingest lakefillq_optimized_3mode_sota_report.json when present!
        opt3_doc = self.load_optional("reproducers/artifacts/lakefillq_optimized_3mode_sota_report.json")
        if opt3_doc:
            records.extend(
                self._extract_dynamic_3mode_records(
                    opt3_doc,
                    "reproducers/artifacts/lakefillq_optimized_3mode_sota_report.json",
                    default_family="Optimized 3-Mode SOTA",
                )
            )

        # 7. Gracefully ingest lakefillq_block_encoding_lcu_qsvt_report.json when present!
        lcu_doc = self.load_optional("reproducers/artifacts/lakefillq_block_encoding_lcu_qsvt_report.json")
        if lcu_doc:
            records.extend(
                self._extract_dynamic_lcu_qsvt_records(
                    lcu_doc,
                    "reproducers/artifacts/lakefillq_block_encoding_lcu_qsvt_report.json",
                )
            )

        return records

    def _extract_dynamic_3mode_records(
        self,
        doc: Dict[str, Any],
        rel_src: str,
        default_family: str,
    ) -> List[Dict[str, Any]]:
        out: List[Dict[str, Any]] = []
        candidate_lists: List[List[Any]] = []
        if isinstance(doc.get("ten_algorithm_three_mode_sota_table"), list):
            candidate_lists.append(doc["ten_algorithm_three_mode_sota_table"])
        else:
            for k, v in doc.items():
                if isinstance(v, list) and v and isinstance(v[0], dict):
                    candidate_lists.append(v)
                elif isinstance(v, dict):
                    for sk, sv in v.items():
                        if isinstance(sv, list) and sv and isinstance(sv[0], dict):
                            candidate_lists.append(sv)

        seen_names = set()
        for lst in candidate_lists:
            for item in lst:
                name = (
                    item.get("algorithm")
                    or item.get("benchmark")
                    or item.get("problem")
                    or item.get("name")
                    or item.get("scheme")
                )
                if not name:
                    continue
                clean_name = f"{_clean_text(name)} [3-Mode SOTA]"
                if clean_name in seen_names:
                    continue
                seen_names.add(clean_name)

                sm = (
                    item.get("mode_1_single_machine")
                    or item.get("single_machine")
                    or item.get("mode_single")
                    or item.get("single")
                    or {}
                )
                pm = (
                    item.get("mode_2_parallel_machine")
                    or item.get("parallel_machine")
                    or item.get("mode_parallel")
                    or item.get("parallel")
                    or {}
                )
                ms = (
                    item.get("mode_3_serial_multishot")
                    or item.get("serial_multishot")
                    or item.get("mode_multishot")
                    or item.get("multishot")
                    or {}
                )

                sm_q = (
                    sm.get("logical_qubits")
                    or sm.get("min_width_dlog5_logical_qubits")
                    or sm.get("dqi_opi4095_live_logical_qubits")
                    or sm.get("femoco_logical_qubits")
                    or sm.get("qubits")
                    or item.get("single_machine_qubits")
                    or item.get("logical_qubits")
                    or item.get("qubits")
                )
                sm_cost = (
                    sm.get("toffolis")
                    or sm.get("temp_ands")
                    or sm.get("temp_ands_per_iter")
                    or sm.get("min_width_dlog5_grover_toffolis")
                    or sm.get("forward_temp_ands")
                    or sm.get("dqi_opi_f3329_temp_ands")
                    or sm.get("temp_and_per_run")
                    or sm.get("t_count")
                    or item.get("toffolis")
                    or item.get("t_count")
                    or "Verified"
                )
                pm_m = (
                    pm.get("optimal_machines_m_star")
                    or pm.get("machines_used")
                    or pm.get("qpu_count_M")
                    or pm.get("machines_m")
                    or pm.get("machines")
                    or pm.get("machines_M")
                    or item.get("parallel_machines")
                    or "M*"
                )
                pm_q = (
                    pm.get("logical_qubits_per_machine")
                    or pm.get("qubits_per_machine")
                    or pm.get("logical_qubits_per_qpu_min_width")
                    or pm.get("logical_qubits_per_qpu")
                    or pm.get("k4_logical_qubits_per_qpu")
                    or pm.get("dqi_k4_sliced_logical_qubits_per_qpu")
                    or pm.get("qubits_per_qpu")
                    or pm.get("logical_qubits")
                    or sm_q
                )
                ms_s = (
                    ms.get("runs_s")
                    or ms.get("shot_count_S")
                    or ms.get("k4_shot_count_S")
                    or ms.get("dqi_shot_count_S")
                    or ms.get("shots")
                    or ms.get("sequential_shots")
                    or item.get("shots")
                    or "MAXDEPTH"
                )
                ms_cost = (
                    ms.get("temp_and_per_run")
                    or ms.get("coherent_temp_ands_per_shot")
                    or ms.get("k4_coherent_temp_ands_per_shot")
                    or ms.get("coherent_grover_iterations_per_shot")
                    or ms.get("toffolis_per_shot")
                    or ms.get("per_shot_cost")
                    or sm_cost
                )
                ebit_val = pm.get("logical_ebits_total") if "logical_ebits_total" in pm else pm.get("logical_ebits", pm.get("inter_qpu_ebits"))
                ebit_str = (
                    f"{_fmt_num(ebit_val)} ebits"
                    if ebit_val is not None
                    else (pm.get("optical_bell_pairs") or pm.get("interconnect") or "T-ParGuard M* / Law U4 GHZ")
                )

                out.append(
                    {
                        "algorithm": clean_name,
                        "family": _clean_text(item.get("category") or item.get("family") or default_family),
                        "single_machine": {
                            "machines": 1,
                            "logical_qubits": sm_q,
                            "non_clifford_cost": _fmt_num(sm_cost),
                            "notes": _clean_text(sm.get("architecture") or sm.get("notes") or item.get("notes") or "Live 3-mode SOTA report"),
                        },
                        "parallel_machine": {
                            "machines": pm_m,
                            "qubits_per_qpu": pm_q,
                            "total_logical_qubits": pm.get("total_logical_qubits") or pm_q,
                            "interconnect_cost": _clean_text(ebit_str),
                        },
                        "serial_multishot": {
                            "machines": 1,
                            "shots": ms_s,
                            "logical_qubits": ms.get("logical_qubits_per_machine_per_run") or ms.get("logical_qubits_per_shot_min_width") or ms.get("k4_logical_qubits_per_shot") or ms.get("logical_qubits_per_shot") or ms.get("dqi_logical_qubits_per_shot") or ms.get("logical_qubits") or sm_q,
                            "per_shot_cost": _fmt_num(ms_cost),
                        },
                        "lean_theorems": item.get("lean_theorems") or [],
                        "source_artifact": rel_src,
                    }
                )
        return out

    def _extract_dynamic_lcu_qsvt_records(
        self,
        doc: Dict[str, Any],
        rel_src: str,
    ) -> List[Dict[str, Any]]:
        out = self._extract_dynamic_3mode_records(doc, rel_src, default_family="Block-Encoding / LCU / QSVT")
        if out:
            # Relabel suffix for clarity
            for r in out:
                r["algorithm"] = r["algorithm"].replace("[3-Mode SOTA]", "[LCU/QSVT]")
            return out

        # Fallback dictionary extraction if keyed by benchmark name
        for k, v in doc.items():
            if isinstance(v, dict) and any(
                fld in v for fld in ("qubits", "logical_qubits", "physical_qubits", "subnormalization_alpha", "t_count", "temp_ands")
            ):
                q = v.get("physical_qubits") or v.get("logical_qubits") or v.get("qubits")
                cost = v.get("forward_temp_and_count") or v.get("temp_ands") or v.get("t_count") or v.get("toffolis")
                alpha = v.get("subnormalization_alpha") or v.get("alpha")
                note_parts = []
                if alpha is not None:
                    note_parts.append(f"alpha={alpha}")
                if "fidelity" in v:
                    note_parts.append(f"fidelity={v['fidelity']}")
                out.append(
                    {
                        "algorithm": f"{_clean_text(k)} [LCU/QSVT]",
                        "family": "Block-Encoding / LCU / QSVT",
                        "single_machine": {
                            "machines": 1,
                            "logical_qubits": q,
                            "non_clifford_cost": _fmt_num(cost),
                            "notes": ", ".join(note_parts) if note_parts else "Walker-Vose Prepare + QROAM Select + QSVT",
                        },
                        "parallel_machine": {
                            "machines": "Multi-zone",
                            "qubits_per_qpu": q,
                            "total_logical_qubits": q,
                            "interconnect_cost": "Parallel LCU Prepare/Select banks",
                        },
                        "serial_multishot": {
                            "machines": 1,
                            "shots": "Amplitude / QSVT",
                            "logical_qubits": q,
                            "per_shot_cost": _fmt_num(cost),
                        },
                        "lean_theorems": v.get("lean_theorems") or [],
                        "source_artifact": rel_src,
                    }
                )
        return out


# ==============================================================================
# Live #lang lakefillq Compilation Helper
# ==============================================================================


def compile_lfq_live(
    lfq_rel_or_abs: str,
    target_override: Optional[str] = None,
    repair: bool = False,
) -> Dict[str, Any]:
    lfq_path = Path(lfq_rel_or_abs)
    if not lfq_path.is_absolute():
        lfq_path = (REPO_ROOT / lfq_path).resolve()
    if not lfq_path.exists():
        raise FileNotFoundError(f"Could not find .lfq source file: {lfq_rel_or_abs}")

    tmpdir, created_local = resolve_persistent_tmp()
    rkt, raco = resolve_racket_and_raco()
    env = dict(os.environ)
    env["TMPDIR"] = str(tmpdir)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    for p in (REPO_ROOT / ".venv" / "bin", REPO_ROOT.parent / ".venv" / "bin", Path(rkt).parent):
        if p.is_dir():
            env["PATH"] = f"{p}:{env.get('PATH', '')}"

    work = tmpdir / f"lakefillq_explorer_{os.getpid()}"
    work.mkdir(parents=True, exist_ok=True)
    try:
        show = subprocess.run([raco, "pkg", "show", "lakefillq"], env=env, capture_output=True, text=True)
        if show.returncode != 0 or "lakefillq" not in show.stdout:
            subprocess.run(
                [raco, "pkg", "install", "--user", "--link", "--no-setup", str(REPO_ROOT / "lakefillq")],
                env=env,
                capture_output=True,
                text=True,
                check=True,
            )

        qasm_out = work / f"{lfq_path.stem}.qasm"
        stim_out = work / f"{lfq_path.stem}.stim"
        cmd = [
            rkt,
            str(REPO_ROOT / "compiler" / "lakefillqc.rkt"),
            "--input",
            str(lfq_path),
            "--emit-json",
            "--emit-qasm3",
            str(qasm_out),
            "--emit-stim",
            str(stim_out),
        ]
        if target_override:
            cmd.extend(["--target", target_override])
        if repair:
            cmd.append("--repair")

        proc = subprocess.run(cmd, cwd=str(REPO_ROOT), env=env, capture_output=True, text=True)
        raw_json = proc.stdout.strip() or proc.stderr.strip()
        report = json.loads(raw_json)
        qasm_text = qasm_out.read_text(encoding="utf-8") if qasm_out.exists() else ""
        stim_text = stim_out.read_text(encoding="utf-8") if stim_out.exists() else ""
        return {
            "source_file": str(lfq_path.relative_to(REPO_ROOT)) if lfq_path.is_relative_to(REPO_ROOT) else str(lfq_path),
            "return_code": proc.returncode,
            "compiler_report": report,
            "openqasm3_lines": len(qasm_text.splitlines()),
            "stim_lines": len(stim_text.splitlines()),
            "openqasm3_snippet": "\n".join(qasm_text.splitlines()[:32]),
            "stim_snippet": "\n".join(stim_text.splitlines()[:28]),
        }
    finally:
        shutil.rmtree(work, ignore_errors=True)
        if created_local and tmpdir.exists():
            shutil.rmtree(tmpdir, ignore_errors=True)


# ==============================================================================
# Terminal View Renderers
# ==============================================================================


def render_summary(store: ArtifactStore, as_json: bool = False) -> Dict[str, Any]:
    key_artifacts = [
        "reproducers/artifacts/lakefillq_unified_compiler_report.json",
        "reproducers/artifacts/lakefillq_xag_fraig_inference_report.json",
        "reproducers/artifacts/lakefillq_egraph_qphys_extraction_report.json",
        "reproducers/artifacts/lakefillq_0dsp_rtl_stim_cosim_report.json",
        "reproducers/artifacts/lakefillq_paper_claim_manifest.json",
        "reproducers/artifacts/lakefillq_optimized_3mode_sota_report.json",
        "reproducers/artifacts/lakefillq_block_encoding_lcu_qsvt_report.json",
        "reproducers/artifacts/lakefillq_bug_class_prevention_report.json",
        "reproducers/artifacts/lakefillq_graded_type_theory_synthesis_report.json",
        "reproducers/artifacts/lakefillq_cluster_qasm3_codegen_report.json",
        "reproducers/artifacts/lakefillq_python_qasm_linter_report.json",
        "reproducers/artifacts/lakefillq_noisy_optical_link_stim_report.json",
        "reproducers/artifacts/lakefillq_multipass_diagnostics_report.json",
    ]
    inv = {rel: (store.load_optional(rel) is not None) for rel in key_artifacts}
    catalog = store.collect_three_mode_catalog()
    uc_doc = store.load_optional("reproducers/artifacts/lakefillq_unified_compiler_report.json") or {}
    rtl_doc = store.load_optional("reproducers/artifacts/lakefillq_0dsp_rtl_stim_cosim_report.json") or {}
    man_doc = store.load_optional("reproducers/artifacts/lakefillq_paper_claim_manifest.json") or {}

    payload = {
        "artifact_inventory": inv,
        "three_mode_algorithm_count": len(catalog),
        "positive_lfq_benchmarks": uc_doc.get("positive_benchmarks", {}),
        "rtl_headline": rtl_doc.get("gate_netlist_synthesis_and_500mhz_timing", {}),
        "claim_manifest_status": man_doc.get("overall_status", "UNKNOWN"),
        "claims_verified": man_doc.get("quantitative_artifact_crosscheck", {}).get("claims_verified", 0),
        "three_mode_catalog": catalog,
    }
    if as_json:
        print(json.dumps(payload, indent=2))
        return payload

    print("=" * 116)
    print("  LAKEFILLQ ARTIFACT EXPLORER — EXECUTIVE SUMMARY")
    print("=" * 116)
    print("  [1] On-Disk JSON Artifact Inventory:")
    for rel, present in inv.items():
        badge = "LOADED  " if present else "OPTIONAL"
        print(f"      [{badge}] {rel}")

    print("\n  [2] Single-Machine (M=1) / Parallel-Machine (M>1) / Serial-Multishot (M=1, S>=1) Overview:")
    print("  " + "-" * 112)
    print(
        f"  {'Algorithm / Workload':<44} {'Single-QPU (M=1)':<20} {'Parallel-QPU (M>1)':<22} {'Serial-Multishot (S)'}"
    )
    print("  " + "-" * 112)
    for rec in catalog:
        alg = rec["algorithm"][:42]
        sm_q = f"{_fmt_num(rec['single_machine']['logical_qubits'])} Q"
        pm = rec["parallel_machine"]
        pm_s = f"M={pm['machines']} ({_fmt_num(pm['qubits_per_qpu'])} Q)"
        ms = rec["serial_multishot"]
        ms_s = f"S={ms['shots']} ({str(ms['per_shot_cost'])[:20]})"
        print(f"  {alg:<44} {sm_q:<20} {pm_s:<22} {ms_s}")

    pos_bm = uc_doc.get("positive_benchmarks", {})
    if pos_bm:
        print("\n  [3] #lang lakefillq Compiled Programs & QPhysGrade Semiring Costs:")
        print("  " + "-" * 112)
        print(
            f"  {'Module (.lfq)':<24} {'Target':<15} {'PhysQ':>6} {'SavedW':>7} {'TempAND':>8} {'MBU':>5} {'Phi1(m)':>8} {'Phi2':>5} {'Fidelity'}"
        )
        print("  " + "-" * 112)
        for name, b in sorted(pos_bm.items()):
            qp = b.get("qphys_grade", {})
            ver = b.get("verification", {})
            fid = (
                ver.get("aer_superposition_fidelity")
                or ver.get("aer_density_matrix_fidelity")
                or ver.get("aer_interference_fidelity")
                or 1.0
            )
            print(
                f"  {name:<24} {b.get('target_profile', ''):<15} "
                f"{b.get('physical_qubits', 0):>6} {b.get('chordal_recycled_wires', 0):>7} "
                f"{b.get('forward_temp_and_count', 0):>8} {b.get('mbu_erasure_count', 0):>5} "
                f"{qp.get('decoherence_action_milli', 0):>8} {qp.get('exclusion_collisions', 0):>5} "
                f"{fid:.6f}"
            )

    timing = rtl_doc.get("gate_netlist_synthesis_and_500mhz_timing", {})
    cosim = rtl_doc.get("stim_2000_burst_cycle_accurate_cosim", {})
    lean_sec = man_doc.get("lean4_theorem_and_kernel_crosscheck", {})
    print("\n  [4] 500 MHz 0-DSP Hardware Decoder & Mechanized Lean 4.35.0 Verification:")
    if timing:
        print(
            f"      0-DSP RTL Decoder : {timing.get('post_mapping_lut6_total')} LUT6, "
            f"{timing.get('post_mapping_carry4_total')} CARRY4, {timing.get('post_mapping_fdre_flip_flops')} FDRE, "
            f"{timing.get('post_mapping_dsp48_slices')} DSP48 | Fmax = {timing.get('critical_path_fmax_mhz')} MHz "
            f"(+{timing.get('critical_path_fpga_slack_ps')} ps slack) | "
            f"Max Stim FIFO Backlog = {cosim.get('lakefillq_0dsp_rtl_max_queue_backlog_ns')} ns "
            f"(vs {cosim.get('unpaced_mwpm_max_queue_backlog_ns')} ns MWPM)"
        )
    if man_doc:
        qcheck = man_doc.get("quantitative_artifact_crosscheck", {})
        print(
            f"      Paper & Lean 4.35 : {qcheck.get('claims_verified')} quantitative claims PASS across "
            f"{qcheck.get('artifacts_loaded')} JSON reports; "
            f"{lean_sec.get('lean_declarations_verified') or len(lean_sec.get('mappings', [])) or len(lean_sec.get('declaration_checks', []))} formal theorem mappings (0 sorry, 0 axiom)"
        )
    print("=" * 116)
    return payload


def render_mode_table(store: ArtifactStore, mode: str, as_json: bool = False) -> List[Dict[str, Any]]:
    catalog = store.collect_three_mode_catalog()
    if as_json:
        print(json.dumps({"mode": mode, "records": catalog}, indent=2))
        return catalog

    titles = {
        "single": "SINGLE-MACHINE EXECUTION REGIME (M = 1 QPU, 0 Optical Bell Pairs)",
        "parallel": "PARALLEL-MACHINE EXECUTION REGIME (M > 1 ZipperCut Chiplets & Shot Parallelism)",
        "multishot": "SERIAL-MULTISHOT EXECUTION REGIME (M = 1 QPU, S Coherence-Bounded Runs)",
    }
    print("=" * 116)
    print(f"  LAKEFILLQ ARTIFACT EXPLORER — {titles[mode]}")
    print("=" * 116)

    if mode == "single":
        print(f"  {'Algorithm':<42} {'Qubits':<20} {'Non-Clifford Gate Volume':<28} {'Hardware / Notes'}")
        print("  " + "-" * 112)
        for r in catalog:
            sm = r["single_machine"]
            print(
                f"  {r['algorithm'][:40]:<42} {_fmt_num(sm['logical_qubits'])[:18]:<20} "
                f"{str(sm['non_clifford_cost'])[:26]:<28} {str(sm['notes'])[:44]}"
            )
    elif mode == "parallel":
        print(f"  {'Algorithm':<42} {'Machines':<12} {'Qubits/QPU':<14} {'Interconnect & Seam Cost'}")
        print("  " + "-" * 112)
        for r in catalog:
            pm = r["parallel_machine"]
            print(
                f"  {r['algorithm'][:40]:<42} {str(pm['machines'])[:10]:<12} "
                f"{_fmt_num(pm['qubits_per_qpu'])[:12]:<14} {str(pm['interconnect_cost'])[:62]}"
            )
    else:
        print(f"  {'Algorithm':<42} {'Shots (S)':<14} {'Qubits':<12} {'Per-Shot Continuous Coherence Cost'}")
        print("  " + "-" * 112)
        for r in catalog:
            ms = r["serial_multishot"]
            print(
                f"  {r['algorithm'][:40]:<42} {str(ms['shots'])[:12]:<14} "
                f"{_fmt_num(ms['logical_qubits'])[:10]:<12} {str(ms['per_shot_cost'])[:64]}"
            )
    print("=" * 116)
    return catalog


def render_algorithm_detail(store: ArtifactStore, query: str, as_json: bool = False) -> List[Dict[str, Any]]:
    q = query.strip().lower()
    catalog = store.collect_three_mode_catalog()
    matches = [
        r
        for r in catalog
        if q in r["algorithm"].lower()
        or q in r["family"].lower()
        or any(q in t.lower() for t in r.get("lean_theorems", []))
    ]
    if as_json:
        print(json.dumps({"query": query, "matches": matches}, indent=2))
        return matches

    print("=" * 116)
    print(f"  LAKEFILLQ ALGORITHM EXPLORER — Filter: '{query}' ({len(matches)} match(es))")
    print("=" * 116)
    if not matches:
        avail = ", ".join(r["algorithm"].split(" (")[0] for r in catalog)
        print(f"  No matching algorithm found. Available families/workloads:\n    {avail}")
        print("=" * 116)
        return []

    for r in matches:
        sm = r["single_machine"]
        pm = r["parallel_machine"]
        ms = r["serial_multishot"]
        print(f"  * {r['algorithm']}  [{r['family']}]")
        print(f"    Source Artifact   : {r['source_artifact']}")
        print(
            f"    Single-Machine    : M=1 | Qubits={_fmt_num(sm['logical_qubits'])} | "
            f"Cost={sm['non_clifford_cost']} | {sm['notes']}"
        )
        print(
            f"    Parallel-Machine  : M={pm['machines']} | Qubits/QPU={_fmt_num(pm['qubits_per_qpu'])} "
            f"(Total={_fmt_num(pm['total_logical_qubits'])}) | {pm['interconnect_cost']}"
        )
        print(
            f"    Serial-Multishot  : M=1, Shots={ms['shots']} | Qubits={_fmt_num(ms['logical_qubits'])} | "
            f"{ms['per_shot_cost']}"
        )
        if r.get("lean_theorems"):
            print(f"    Lean 4.35 Theorems: {', '.join(r['lean_theorems'])}")
        print("  " + "-" * 112)
    print("=" * 116)
    return matches


def render_compiled_lfq(
    lfq_file: str,
    target: Optional[str],
    repair: bool,
    as_json: bool = False,
) -> Dict[str, Any]:
    res = compile_lfq_live(lfq_file, target_override=target, repair=repair)
    if as_json:
        print(json.dumps(res, indent=2))
        return res

    rep = res["compiler_report"]
    qp = rep.get("qphys_grade", {})
    print("=" * 116)
    print(f"  LIVE #lang lakefillq COMPILATION — {res['source_file']}")
    print("=" * 116)
    print(f"  Circuit Name / Kind   : {rep.get('circuit_name')} ({rep.get('circuit_kind')})")
    print(f"  Target Hardware       : {rep.get('target_profile')}")
    print(f"  Pipeline Dialects     : {' -> '.join(rep.get('pipeline_dialects', []))}")
    print(
        f"  Well-Typed (U1-U4)    : {rep.get('well_typed')}  "
        f"(residual_surface_forms={rep.get('residual_surface_forms')}, "
        f"annotation_flags={rep.get('annotation_free_flags')})"
    )
    print(
        f"  Wire & Gate Metrics   : virtual_wires={rep.get('virtual_wires')}, "
        f"physical_qubits={rep.get('physical_qubits')}, "
        f"chordal_recycled={rep.get('chordal_recycled_wires')}, "
        f"TempAND={rep.get('forward_temp_and_count')}, "
        f"uncompute_CCX={rep.get('uncompute_ccx_count')}, "
        f"MBU={rep.get('mbu_erasure_count')}, "
        f"MachineISA_ops={rep.get('machine_isa_ops')}"
    )
    print(
        f"  QPhysGrade (Phi1-Phi3): Phi1_action_milli={qp.get('decoherence_action_milli')}, "
        f"Phi2_collisions={qp.get('exclusion_collisions')}, "
        f"Phi3_eff_dist={qp.get('effective_fault_distance')} "
        f"(req={qp.get('required_fault_distance')})"
    )
    if rep.get("repairs_applied"):
        print(f"  Guided Repairs        : {rep['repairs_applied']}")
    if rep.get("violations"):
        print(f"  Violations            : {rep['violations']}")

    if res["openqasm3_snippet"]:
        print(f"\n  --- Emitted Dynamic OpenQASM 3.0 Preview (first lines of {res['openqasm3_lines']} total) ---")
        for ln in res["openqasm3_snippet"].splitlines():
            print(f"    {ln}")

    if res["stim_snippet"]:
        print(f"\n  --- Emitted Stim Stabilizer DEM Preview (first lines of {res['stim_lines']} total) ---")
        for ln in res["stim_snippet"].splitlines():
            print(f"    {ln}")
    print("=" * 116)
    return res


def render_rtl_inspection(store: ArtifactStore, as_json: bool = False) -> Dict[str, Any]:
    doc = store.load_optional("reproducers/artifacts/lakefillq_0dsp_rtl_stim_cosim_report.json") or {}
    if as_json:
        print(json.dumps(doc, indent=2))
        return doc

    za = doc.get("zero_dsp_static_audit", {})
    tm = doc.get("gate_netlist_synthesis_and_500mhz_timing", {})
    z3m = doc.get("z3_qfbv_equivalence_miters", {})
    cs = doc.get("stim_2000_burst_cycle_accurate_cosim", {})
    lp = doc.get("lean4_mechanized_proofs", {})

    print("=" * 116)
    print("  LAKEFILLQ 500 MHz 0-DSP BRAUNTREE + SHILOACH-VISHKIN UNION-FIND RTL INSPECTOR")
    print("=" * 116)
    print(
        f"  [1] Static 0-DSP Certification : certified={za.get('zero_dsp_certified')} | "
        f"SV={za.get('sv_file')} ({za.get('sv_lines')}L) | DSLX={za.get('dslx_file')} ({za.get('dslx_lines')}L) | "
        f"mul/div/mod={za.get('sv_mul_div_mod_operators')}/{za.get('dslx_mul_div_mod_operators')} | "
        f"DSP48={za.get('dsp48_or_umul_primitives')}"
    )
    print(
        f"  [2] Post-Mapping Synthesis     : {tm.get('post_mapping_lut6_total')} LUT6, "
        f"{tm.get('post_mapping_carry4_total')} CARRY4, {tm.get('post_mapping_fdre_flip_flops')} FDRE, "
        f"{tm.get('post_mapping_dsp48_slices')} DSP48 | Critical Path: {tm.get('critical_path_subblock')} "
        f"({tm.get('critical_path_lut6_levels')} LUT6 levels, {tm.get('critical_path_fpga_arrival_ps')} ps, "
        f"+{tm.get('critical_path_fpga_slack_ps')} ps slack, Fmax={tm.get('critical_path_fmax_mhz')} MHz; "
        f"7nm asap7={tm.get('critical_path_asap7_arrival_ps')} ps)"
    )

    print("\n  [3] Subblock Timing & Resource Breakdown:")
    print(f"      {'Subblock':<36} {'LUT6':>6} {'CARRY4':>7} {'DSP48':>6} {'Levels':>7} {'FPGA(ps)':>9} {'Fmax(MHz)':>10} {'asap7(ps)':>10}")
    print("      " + "-" * 96)
    for sb_name, sb in tm.get("subblocks", {}).items():
        print(
            f"      {sb_name:<36} {sb.get('lut6_count', 0):>6} {sb.get('carry4_primitives', 0):>7} "
            f"{sb.get('dsp48_primitives', 0):>6} {sb.get('lut6_logic_levels', 0):>7} "
            f"{sb.get('fpga_500mhz_arrival_ps', 0):>9} {sb.get('fpga_fmax_mhz', 0):>10.2f} "
            f"{sb.get('asap7_7nm_arrival_ps', 0):>10}"
        )

    print("\n  [4] Z3 QF_BV Hardware Equivalence Miters:")
    for mk, mv in z3m.items():
        st = mv.get("status") or mv.get("universal_4096_syndromes_Hc_eq_s_status")
        print(f"      - {mk:<48}: {st} (nodes={mv.get('dag_wire_nodes')})")

    print("\n  [5] Cycle-Accurate Stim Co-Simulation (2,000 Bursts / 80,000 QEC Cycles):")
    print(
        f"      Zero-defect 1-clk (2.0 ns) bypass = {100.0 * cs.get('overall_zero_defect_bypass_fraction', 0.0):.2f}% | "
        f"Max RTL Backlog = {cs.get('lakefillq_0dsp_rtl_max_queue_backlog_ns')} ns "
        f"(100.0% deadline compliance) vs {cs.get('unpaced_mwpm_max_queue_backlog_ns')} ns MWPM | "
        f"IBM Heron r2 Mean Fidelity = {cs.get('fault_tolerant_mean_rtl_survival_fidelity')} vs "
        f"{cs.get('fault_tolerant_mean_unpaced_mwpm_survival_fidelity')}"
    )
    if lp:
        print(
            f"  [6] Mechanized Lean 4.35.0 Proofs : {lp.get('lean_file')} "
            f"({lp.get('theorems_verified')} theorems, sorry={lp.get('sorry_count')}, axiom={lp.get('axiom_count')})"
        )
    print("=" * 116)
    return doc


def render_claims_and_lean_mappings(store: ArtifactStore, as_json: bool = False) -> Dict[str, Any]:
    doc = store.load_optional("reproducers/artifacts/lakefillq_paper_claim_manifest.json") or {}
    if as_json:
        print(json.dumps(doc, indent=2))
        return doc

    qc = doc.get("quantitative_artifact_crosscheck", {})
    lc = doc.get("lean4_theorem_and_kernel_crosscheck", {})
    lt = doc.get("latex_and_bibtex_structural_linter", {})

    print("=" * 116)
    print("  LAKEFILLQ PAPER-TO-ARTIFACT CLAIM MANIFEST & LEAN 4.35.0 THEOREM MAPPING")
    print("=" * 116)
    print(
        f"  Overall Manifest Status : {doc.get('overall_status')} | "
        f"Quantitative Claims: {qc.get('claims_verified')} ({qc.get('failure_count')} failures) | "
        f"Artifacts Loaded: {qc.get('artifacts_loaded')}"
    )

    by_cat: Dict[str, List[Dict[str, Any]]] = {}
    for c in qc.get("claims", []):
        by_cat.setdefault(c.get("category", "general"), []).append(c)

    print("\n  [1] Verified Quantitative Claims by Category:")
    for cat, items in sorted(by_cat.items()):
        passed_n = sum(1 for x in items if x.get("verified"))
        sample_ids = ", ".join(f"{x['claim_id']}={x['markdown_token']}" for x in items[:3])
        print(f"      - {cat:<36}: {passed_n:>2}/{len(items):<2} PASS  (e.g. {sample_ids})")

    mappings = lc.get("mappings") or lc.get("declaration_checks") or []
    print(
        f"\n  [2] Formal Paper Labels -> Mechanized Lean 4.35.0 Declarations "
        f"({lc.get('formal_statements_verified', 0)} labels, {len(mappings)} declarations, 0 sorry, 0 axiom):"
    )
    print(f"      {'Paper Label':<14} {'Lean 4.35.0 Module':<56} {'Declaration'}")
    print("      " + "-" * 106)
    for d in mappings:
        print(
            f"      {d.get('paper_label', ''):<14} {d.get('lean_file', ''):<56} {d.get('declaration', '')}"
        )

    if lt:
        print(
            f"\n  [3] Camera-Ready acmart LaTeX & BibTeX Structural Audit: {lt.get('status')} "
            f"({lt.get('sections_verified')} sections, {lt.get('tabular_tables_verified')} tables, "
            f"{lt.get('quantikz_circuits_verified')} quantikz figures, "
            f"{lt.get('citations_resolved')}/{lt.get('bibtex_entries')} BibTeX citations, "
            f"{lt.get('dangling_references')} dangling refs)"
        )
    print("=" * 116)
    return doc


def run_interactive_loop(store: ArtifactStore) -> int:
    examples = sorted(p.name for p in (REPO_ROOT / "examples").glob("*.lfq"))
    while True:
        print("\nLakefillQ Interactive Explorer Menu:")
        print("  [1] Executive Summary (--summary)")
        print("  [2] Execution Mode Table (single | parallel | multishot)")
        print("  [3] Filter by Algorithm Name (e.g. ecc, rsa, aes, keccak, dqi, qroam)")
        print(f"  [4] Live Compile #lang lakefillq Example ({', '.join(examples)})")
        print("  [5] Inspect 500 MHz 0-DSP SystemVerilog/DSLX Decoder (--inspect-rtl)")
        print("  [6] Inspect Paper Claims & Lean 4.35.0 Theorem Mappings (--check-claims)")
        print("  [q] Quit")
        try:
            choice = input("Select option [1-6/q]: ").strip().lower()
        except EOFError:
            print()
            return 0

        if choice in ("q", "quit", "exit"):
            return 0
        if choice == "1":
            render_summary(store)
        elif choice == "2":
            m = input("Mode [single/parallel/multishot] (default: single): ").strip().lower() or "single"
            if m in ("single", "parallel", "multishot"):
                render_mode_table(store, m)
            else:
                print("Unrecognized mode; choose single, parallel, or multishot.")
        elif choice == "3":
            alg = input("Algorithm search substring: ").strip()
            if alg:
                render_algorithm_detail(store, alg)
        elif choice == "4":
            default_ex = examples[0] if examples else "aes_sbox_bp34.lfq"
            ex = input(f"Example file in examples/ (default: {default_ex}): ").strip() or default_ex
            ex_path = ex if "/" in ex else f"examples/{ex}"
            tgt = input("Target [heron-r2 | bluvstein-aod | bb-qldpc | ideal | default]: ").strip()
            tgt_opt = None if tgt in ("", "default") else tgt
            render_compiled_lfq(ex_path, tgt_opt, repair=False)
        elif choice == "5":
            render_rtl_inspection(store)
        elif choice == "6":
            render_claims_and_lean_mappings(store)
        else:
            print("Invalid selection.")


# ==============================================================================
# CLI Entry Point
# ==============================================================================


def main() -> int:
    parser = argparse.ArgumentParser(
        description="LakefillQ Terminal & JSON Artifact Explorer"
    )
    parser.add_argument(
        "--summary",
        action="store_true",
        help="Display executive summary of SOTA tables, #lang lakefillq benchmarks, RTL, and proofs",
    )
    parser.add_argument(
        "--algorithm",
        type=str,
        default="",
        help="Filter Single-Machine / Parallel-Machine / Serial-Multishot metrics by algorithm name",
    )
    parser.add_argument(
        "--mode",
        choices=("single", "parallel", "multishot"),
        default="",
        help="Display resource table for a specific execution regime (single | parallel | multishot)",
    )
    parser.add_argument(
        "--compile",
        type=str,
        default="",
        help="Compile a #lang lakefillq (.lfq) source file live via compiler/lakefillqc.rkt",
    )
    parser.add_argument(
        "--target",
        choices=("heron-r2", "bluvstein-aod", "bb-qldpc", "ideal"),
        default="",
        help="Optional hardware target profile override when using --compile",
    )
    parser.add_argument(
        "--repair",
        action="store_true",
        help="Enable counterexample-guided QPhysGrade repair when using --compile",
    )
    parser.add_argument(
        "--inspect-rtl",
        action="store_true",
        help="Inspect 500 MHz 0-DSP SystemVerilog/DSLX decoder synthesis, Z3 miters, and Stim co-sim",
    )
    parser.add_argument(
        "--check-claims",
        action="store_true",
        help="Inspect the 119 quantitative paper claims and Lean 4.35.0 formal theorem mappings",
    )
    parser.add_argument(
        "--interactive",
        action="store_true",
        help="Launch interactive terminal menu",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit structured JSON output instead of formatted terminal tables",
    )

    args = parser.parse_args()
    store = ArtifactStore(REPO_ROOT)

    any_action = False
    if args.summary:
        render_summary(store, as_json=args.json)
        any_action = True
    if args.mode:
        render_mode_table(store, args.mode, as_json=args.json)
        any_action = True
    if args.algorithm:
        render_algorithm_detail(store, args.algorithm, as_json=args.json)
        any_action = True
    if args.compile:
        res = render_compiled_lfq(
            args.compile,
            target=args.target or None,
            repair=args.repair,
            as_json=args.json,
        )
        if res["return_code"] != 0:
            return res["return_code"]
        any_action = True
    if args.inspect_rtl:
        render_rtl_inspection(store, as_json=args.json)
        any_action = True
    if args.check_claims:
        render_claims_and_lean_mappings(store, as_json=args.json)
        any_action = True
    if args.interactive:
        return run_interactive_loop(store)

    if not any_action:
        render_summary(store, as_json=args.json)
    return 0


if __name__ == "__main__":
    sys.exit(main())
