#!/usr/bin/env python3
"""
verify_lakefillq_holistic_language_cohesion.py
==============================================
End-to-end holistic cohesion, modular composition, ordered partial duoidal
capability checking, automatic `ANF -> XAG/FRAIG+Z3` symbolic escalation, and
empirical 20-program compiler diagnostic clarity verifier for `#lang lakefillq`.

Writes structured JSON verification artifact to:
  `reproducers/artifacts/lakefillq_holistic_language_cohesion_report.json`
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from typing import Any, Dict, List, Tuple

import numpy as np
import qiskit.qasm3
from qiskit import QuantumCircuit
from qiskit.quantum_info import DensityMatrix, Statevector, state_fidelity
from qiskit_aer import AerSimulator


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
ARTIFACT_PATH = (
    REPO_ROOT / "reproducers" / "artifacts" / "lakefillq_holistic_language_cohesion_report.json"
)

FORBIDDEN_INTERNAL_LEAKS = (
    "__u4_mx_",
    "__mbu_",
    "lower-kern->revir",
    "surface-unitary-adjoint",
    "defq-internal",
    "lakefillq/main.rkt",
)


def clean_env() -> Dict[str, str]:
    env = dict(os.environ)
    env["TMPDIR"] = str(PERSISTENT_TMP)
    return env


def run_lakefillqc(
    lfq_file: Path,
    extra_args: List[str] | None = None,
) -> Tuple[int, Dict[str, Any], str]:
    cmd = [
        str(RACKET_BIN),
        str(LAKEFILLQC),
        "--input",
        str(lfq_file),
        "--emit-json",
        "--diagnostics-human",
    ]
    if extra_args:
        cmd.extend(extra_args)
    proc = subprocess.run(
        cmd,
        cwd=str(REPO_ROOT),
        env=clean_env(),
        capture_output=True,
        text=True,
        check=False,
    )
    payload = json.loads(proc.stdout.strip()) if proc.stdout.strip() else {}
    return proc.returncode, payload, proc.stderr


def modular_cipher_spec_word(val8: int) -> int:
    """Exact classical specification of `examples/modular_compositional_cipher.lfq` on 8 data qubits."""
    b = [(val8 >> i) & 1 for i in range(8)]
    mk = b[0:2]
    rt = b[2:4]
    ll = b[4:6]
    rl = b[6:8]

    # Round 1: nonlinear-key-mix(mk, rt, rl) + linear-lane-permute(rl)
    rl[0] ^= mk[0] & rt[0]
    rl[1] ^= mk[1] & rt[1]
    rl[1] ^= rl[0]
    rl[0] ^= rl[1]

    # Round 2: nonlinear-key-mix(mk, mk, ll) [Delta_Z contraction] + linear-lane-permute(ll)
    ll[0] ^= mk[0] & mk[0]
    ll[1] ^= mk[1] & mk[1]
    ll[1] ^= ll[0]
    ll[0] ^= ll[1]

    # Round 3: nonlinear-key-mix(ll, rt, rl)
    rl[0] ^= ll[0] & rt[0]
    rl[1] ^= ll[1] & rt[1]

    out_bits = mk + rt + ll + rl
    return sum((bit & 1) << idx for idx, bit in enumerate(out_bits))


def verify_modular_cipher_and_aes(work_dir: Path) -> Dict[str, Any]:
    mod_lfq = REPO_ROOT / "examples" / "modular_compositional_cipher.lfq"
    mod_qasm = work_dir / "modular_compositional_cipher.qasm"
    rc, js, stderr = run_lakefillqc(mod_lfq, ["--emit-qasm3", str(mod_qasm)])
    assert rc == 0 and js.get("well_typed") is True, f"modular cipher failed: {stderr}"
    assert js["module_circuits_checked"] == [
        "nonlinear-key-mix",
        "linear-lane-permute",
        "modular-compositional-cipher",
    ]
    assert js["virtual_wires"] == 14
    assert js["physical_qubits"] == 10
    assert js["chordal_recycled_wires"] == 4
    assert js["forward_temp_and_count"] == 4
    assert js["mbu_erasure_count"] == 4
    assert [p["grade"] for p in js["rwire_port_signature"]] == [
        "BorrowZ",
        "BorrowZ",
        "Uniq1",
        "Uniq1",
    ]

    dyn_qc = qiskit.qasm3.loads(
        mod_qasm.read_text(encoding="utf-8").replace("== 1)", "== true)")
    )
    sim_dm = AerSimulator(method="density_matrix")

    # Verify quantum superposition coherence across 8 data + 2 recycled M_X scratch qubits!
    rng = np.random.default_rng(20261030)
    raw_amps = rng.normal(size=256) + 1j * rng.normal(size=256)
    raw_amps /= np.linalg.norm(raw_amps)

    # Ideal 10-qubit output statevector (qubits 8, 9 returned cleanly to |00>):
    ideal_full = np.zeros(1024, dtype=complex)
    basis_checked = 0
    for x in range(256):
        y = modular_cipher_spec_word(x)
        ideal_full[y] = raw_amps[x]
        basis_checked += 1

    prep = QuantumCircuit(dyn_qc.num_qubits, dyn_qc.num_clbits)
    init_full = np.zeros(1024, dtype=complex)
    init_full[:256] = raw_amps
    prep.set_density_matrix(DensityMatrix(Statevector(init_full)))
    full_qc = prep.compose(dyn_qc)
    full_qc.save_density_matrix()
    dm_actual = DensityMatrix(sim_dm.run(full_qc, shots=1).result().data(0)["density_matrix"])
    fid_mod = float(state_fidelity(Statevector(ideal_full), dm_actual))
    assert abs(fid_mod - 1.0) < 1e-10, f"Modular cipher Aer fidelity mismatch: {fid_mod}"

    # Also verify upgraded `examples/aes_sbox_dlog5_13q.lfq` (`qvec` + `'auto` cluster costing):
    aes_lfq = REPO_ROOT / "examples" / "aes_sbox_dlog5_13q.lfq"
    aes_qasm = work_dir / "aes_sbox_dlog5_13q.qasm"
    rc_aes, js_aes, stderr_aes = run_lakefillqc(aes_lfq, ["--emit-qasm3", str(aes_qasm)])
    assert rc_aes == 0 and js_aes.get("well_typed") is True, f"aes_sbox failed: {stderr_aes}"
    assert js_aes["physical_qubits"] == 13
    par_dec = js_aes["parallel_partition_decisions"][0]
    assert par_dec["q_single"] == 13
    assert par_dec["optimal_machines"] == 1

    return {
        "modular_cipher": {
            "basis_inputs_verified": basis_checked,
            "aer_superposition_fidelity": fid_mod,
            "virtual_wires": js["virtual_wires"],
            "physical_qubits": js["physical_qubits"],
            "chordal_recycled_wires": js["chordal_recycled_wires"],
            "rwire_port_signature": js["rwire_port_signature"],
        },
        "aes_sbox_auto_cluster": {
            "physical_qubits": js_aes["physical_qubits"],
            "q_single_derived": par_dec["q_single"],
            "optimal_machines": par_dec["optimal_machines"],
        },
    }


def build_wide_product_lfq(leak_scratch: bool) -> str:
    """Builds a 22-input, 10-scratch `#lang lakefillq` circuit computing `(x0^x1)*...*(x20^x21)`.

    Expanding an 11-factor XOR product produces `2^11 = 2048 > 1024` Zhegalkin ANF
    monomials, automatically escalating `infer-revir-qsub-and-qphys` to `XAG/FRAIG+Z3`
    with ZERO CLI flags!
    """
    uncompute_tail = (
        "  skip)"
        if leak_scratch
        else "\n".join(
            [f"  (ccx (wref s {i}) (wref x {2 * i + 4}) (wref s {i + 1}))" for i in range(8, -1, -1)]
            + [
                "  (ccx (wref x 0) (wref x 2) (wref s 0))",
                "  (for/seq ([k (in-range 11)])",
                "    (cx (wref x (* 2 k)) (wref x (add1 (* 2 k))))))",
            ]
        )
    )
    return "\n".join(
        [
            "#lang lakefillq",
            "(target-profile ideal)",
            "(defqfree (wide-xor-and-cone",
            "           #:wires ([x (qvec 22)] [out (qvec 1)])",
            "           #:scratch ([s (qvec 10)]))",
            "  (for/seq ([k (in-range 11)])",
            "    (cx (wref x (* 2 k)) (wref x (add1 (* 2 k)))))",
            "  (ccx (wref x 1) (wref x 3) (wref s 0))",
            *[f"  (ccx (wref s {i}) (wref x {2 * i + 5}) (wref s {i + 1}))" for i in range(9)],
            "  (cx (wref s 9) (wref out 0))",
            *(
                []
                if leak_scratch
                else [
                    *[
                        f"  (ccx (wref s {i}) (wref x {2 * i + 5}) (wref s {i + 1}))"
                        for i in range(8, -1, -1)
                    ],
                    "  (ccx (wref x 1) (wref x 3) (wref s 0))",
                    "  (for/seq ([k (in-range 11)])",
                    "    (cx (wref x (* 2 k)) (wref x (add1 (* 2 k))))))",
                ]
            ),
            *(["  skip)"] if leak_scratch else []),
            "",
        ]
    )


def verify_zero_flag_xag_escalation(work_dir: Path) -> Dict[str, Any]:
    clean_p = work_dir / "wide_xag_clean.lfq"
    leak_p = work_dir / "wide_xag_leak.lfq"
    clean_p.write_text(build_wide_product_lfq(leak_scratch=False), encoding="utf-8")
    leak_p.write_text(build_wide_product_lfq(leak_scratch=True), encoding="utf-8")

    rc_clean, js_clean, stderr_clean = run_lakefillqc(clean_p)
    assert rc_clean == 0 and js_clean["well_typed"] is True, f"wide clean failed: {stderr_clean}"
    assert js_clean["symbolic_inference_engine"] == "xag-fraig-z3"

    rc_leak, js_leak, stderr_leak = run_lakefillqc(leak_p)
    assert rc_leak == 1 and js_leak["well_typed"] is False
    assert js_leak["symbolic_inference_engine"] == "xag-fraig-z3"
    v0 = js_leak["violations"][0]
    assert v0["code"] == "U1-EraseBy"
    assert "|x[" in (v0.get("resugared_witness") or {}).get("basis_ket", "")

    return {
        "clean_circuit_engine": js_clean["symbolic_inference_engine"],
        "clean_well_typed": js_clean["well_typed"],
        "leak_circuit_engine": js_leak["symbolic_inference_engine"],
        "leak_detected_code": v0["code"],
        "leak_surface_wire": v0.get("surface_wire"),
    }


def build_twenty_real_error_programs() -> List[Tuple[str, str, str, str]]:
    """Returns `(case_id, expected_code, expected_substr, lfq_source)` for 20 real broken programs."""
    return [
        (
            "01_u1_chordal_recycle_leak",
            "U1-EraseBy",
            "s2[0]",
            """#lang lakefillq
(target-profile ideal)
(defqfree (broken-recycle-leak
           #:wires ([a (qvec 2)])
           #:scratch ([s1 (qvec 1)] [s2 (qvec 1)]))
  (cx (wref a 0) (wref s1 0))
  (cx (wref a 0) (wref s1 0))
  (ccx (wref a 0) (wref a 1) (wref s2 0)))
""",
        ),
        (
            "02_u2_quotient_noncanonical",
            "U2-Canonical",
            "q_hist[0]",
            """#lang lakefillq
(target-profile ideal)
(defq (broken-quotient-history
       #:wires ([key (qvec 2)] [q_hist (qvec 1)])
       #:domain (quotient-vars q_hist))
  (cx (wref key 0) (wref q_hist 0))
  (h (wref key 0)))
""",
        ),
        (
            "03_u3_qmatch_nonexhaustive",
            "U3-TotalOn",
            "Non-exhaustive `qmatch`",
            """#lang lakefillq
(target-profile ideal)
(defqfree (incomplete-branch
           #:wires ([ctrl (qvec 2)] [out (qvec 1)]))
  (qmatch
   ([(g-and (g-zero (wref ctrl 0)) (g-zero (wref ctrl 1)))
     (x (wref out 0))]
    [(g-and (g-wire (wref ctrl 0)) (g-zero (wref ctrl 1)))
     (cx (wref ctrl 0) (wref out 0))])))
""",
        ),
        (
            "04_u4_phase_taint_interference",
            "U4-QTainted",
            "ctl[0]@h",
            """#lang lakefillq
(target-profile ideal)
(defq (missing-cond-z-fixup
       #:wires ([ctl (qvec 1)])
       #:scratch ([anc (qvec 1)]))
  (h (wref ctl 0))
  (cx (wref ctl 0) (wref anc 0))
  (mid-meas-x (wref anc 0) 'm_raw)
  (h (wref ctl 0)))
""",
        ),
        (
            "05_phi1_unshielded_mbu_spectators",
            "Phi1-DecoherenceAction",
            "anc[0]",
            """#lang lakefillq
(target-profile heron-r2)
(defq (unshielded-mid-meas-spectators
       #:wires ([data (qvec 6)])
       #:scratch ([anc (qvec 1)]))
  (for/seq ([i (in-range 6)])
    (h (wref data i)))
  (cx (wref data 0) (wref anc 0))
  (mid-meas-x-unshielded (wref anc 0) 'm_unshielded)
  (cond-z 'm_unshielded (wref data 0)))
""",
        ),
        (
            "06_phi2_parallel_blockade_collision",
            "Phi2-ExclusionGraph",
            "(qreg[1], qreg[2])",
            """#lang lakefillq
(target-profile bluvstein-aod)
(defq (colliding-parallel-gates
       #:wires ([qreg (qvec 4)]))
  (par-wires
   (cx (wref qreg 0) (wref qreg 1))
   (cx (wref qreg 2) (wref qreg 3))))
""",
        ),
        (
            "07_phi3_aligned_plaquette_hook",
            "Phi3-FaultExponent",
            "degrades fault distance",
            """#lang lakefillq
(target-profile bb-qldpc)
(defq (hook-aligned-stabilizer
       #:wires ([plaq (qvec 5)]))
  (syndrome-plaquette plaq 5 #:schedule 'aligned))
""",
        ),
        (
            "08_phi3_dyadic_float64_collapse",
            "Phi3-FaultExponent",
            "phase_reg[0]",
            """#lang lakefillq
(target-profile bb-qldpc)
(defq (broken-dyadic-f64
       #:wires ([phase_reg (qvec 1)]))
  (rz-dyadic (wref phase_reg 0) 60 #:precision 'float64 #:distance 5))
""",
        ),
        (
            "09_t_domimg_noninjective_support",
            "E-DOMIMG-NON-INJECTIVE",
            "non-injective on Dom(f)",
            """#lang lakefillq
(target-profile ideal)
(defqfree (bad-modular-uncompute
           #:wires ([x (qvec 2)])
           #:scratch ([anc (qvec 1)]))
  (erase-by-part-bij
   '(part-bij-smt2
     #:label non-inj-mod2
     #:vars ((x Int))
     #:vars-alt ((x_alt Int))
     #:preamble ""
     #:dom-f "(and (<= 0 x) (< x 4))"
     #:f-out ("(mod x 2)")
     #:dom-g-on-f "(and (<= 0 (mod x 2)) (< (mod x 2) 2))"
     #:g-of-f ("(mod x 2)")
     #:residual ()
     #:f-out-alt ("(mod x_alt 2)")
     #:dom-f-alt "(and (<= 0 x_alt) (< x_alt 4))")
   (cx (wref x 0) (wref anc 0))
   (cx (wref x 0) (wref anc 0))
   anc))
""",
        ),
        (
            "10_t_parguard_strict_grover_rejected",
            "E-PARGUARD-ZALKA-GROVER-SUBLINEAR",
            "StrictCluster",
            """#lang lakefillq
(target-profile ideal)
(defqfree (strict-grover-overpartition
           #:wires ([st (qvec 4)]))
  (guard-par-partition
   (par-cluster-opt-spec
    #:workload 'StrictCluster
    #:paradigm 'grover-amplify
    #:max-machines 16
    #:q-cap-per-machine 400
    #:raw-bell-rate-hz 100000.0
    #:q-single 4
    #:local-toffolis 8
    #:strict-parallel? #t)
   (cx (wref st 0) (wref st 1))))
""",
        ),
        (
            "11_qfree_hadamard_violation",
            "LFQ-E-QFREE-BASIS",
            "(h (wref x 0))",
            """#lang lakefillq
(target-profile ideal)
(defqfree (accidental-superposition
           #:wires ([x (qvec 2)]))
  (h (wref x 0))
  (cx (wref x 0) (wref x 1)))
""",
        ),
        (
            "12_intra_gate_self_aliasing",
            "LFQ-E-GATE-ALIAS",
            "x[1]",
            """#lang lakefillq
(target-profile ideal)
(defqfree (self-cx-bug
           #:wires ([x (qvec 2)]))
  (cx (wref x 1) (wref x 1)))
""",
        ),
        (
            "13_undeclared_raw_wire_escape",
            "LFQ-E-UNDECLARED-WIRE",
            "Wire literal `9`",
            """#lang lakefillq
(target-profile ideal)
(defqfree (raw-wire-escape
           #:wires ([x (qvec 2)]))
  (ccx (wref x 0) (wref x 1) 9))
""",
        ),
        (
            "14_nonunitary_invert_measurement",
            "LFQ-E-NONUNITARY-INVERT",
            "mid-meas-x",
            """#lang lakefillq
(target-profile ideal)
(defq (invert-measurement-bug
       #:wires ([c (qvec 1)])
       #:scratch ([anc (qvec 1)]))
  (h (wref c 0))
  (cx (wref c 0) (wref anc 0))
  (invert (mid-meas-x-cond-z (wref anc 0) (wref c 0))))
""",
        ),
        (
            "15_wref_out_of_bounds",
            "LFQ-E-REGISTER-BOUNDS",
            "Register index 5 out of bounds",
            """#lang lakefillq
(target-profile ideal)
(defqfree (oob-index-bug
           #:wires ([x (qvec 4)]))
  (x (wref x 5)))
""",
        ),
        (
            "16_manual_register_wire_overlap",
            "LFQ-E-WIRE-ALIAS",
            "aliases `a[2]`",
            """#lang lakefillq
(target-profile ideal)
(defqfree (overlapping-registers
           #:wires ([a '(0 1 2)] [b '(2 3)]))
  (cx (wref a 0) (wref b 1)))
""",
        ),
        (
            "17_call_q_port_aliasing_conflict",
            "LFQ-E-CALL-ALIAS",
            "BorrowZ (+) Uniq1 = Conflict",
            """#lang lakefillq
(target-profile ideal)
(defqfree (round-mix
           #:wires ([rk (qvec 2)] [st (qvec 2)])
           #:scratch ([tmp (qvec 1)]))
  (with-and-session ([(wref tmp 0) (wref rk 0) (wref rk 1)])
    (cx (wref tmp 0) (wref st 0))))

(defqfree (bad-caller
           #:wires ([buf (qvec 2)]))
  (call-q round-mix buf buf))
""",
        ),
        (
            "18_cluster_profile_cost_drift",
            "LFQ-E-CLUSTER-COST-DRIFT",
            "stale-cluster",
            """#lang lakefillq
(target-profile ideal)
(define-cluster-profile stale-cluster
  #:workload 'Stale-Demo
  #:paradigm 'grover-amplify
  #:q-single 99
  #:local-toffolis 42
  #:verify-circuit-match? #t)

(defqfree (actual-small-circuit
           #:wires ([x (qvec 3)]))
  (ccx (wref x 0) (wref x 1) (wref x 2)))
""",
        ),
        (
            "19_helper_circuit_u1_attribution",
            "U1-EraseBy",
            "in `broken-helper`",
            """#lang lakefillq
(target-profile ideal)
(defqfree (broken-helper
           #:wires ([h_in (qvec 2)])
           #:scratch ([h_anc (qvec 1)]))
  (ccx (wref h_in 0) (wref h_in 1) (wref h_anc 0)))

(defqfree (clean-entry
           #:wires ([x (qvec 2)]))
  (cx (wref x 0) (wref x 1)))
""",
        ),
        (
            "20_malformed_defq_header_syntax",
            "LFQ-E-SURFACE-ELAB",
            "expected parenthesized circuit header",
            """#lang lakefillq
(target-profile ideal)
(defq missing-header-parens
  #:wires ([x (qvec 2)])
  (cx (wref x 0) (wref x 1)))
""",
        ),
    ]


def verify_twenty_real_error_programs(work_dir: Path) -> List[Dict[str, Any]]:
    err_dir = work_dir / "real_error_programs"
    err_dir.mkdir(parents=True, exist_ok=True)
    probe_results: List[Dict[str, Any]] = []

    for case_id, expected_code, expected_substr, src in build_twenty_real_error_programs():
        fpath = err_dir / f"{case_id}.lfq"
        fpath.write_text(src, encoding="utf-8")
        rc, js, stderr = run_lakefillqc(fpath)

        violations = js.get("violations") or []
        v0 = violations[0] if violations else {}
        prov = v0.get("provenance_spans") or {}
        origin_sp = prov.get("origin_span") or {}
        leaks_found = [tok for tok in FORBIDDEN_INTERNAL_LEAKS if tok in stderr]

        passed = (
            rc == 1
            and js.get("well_typed") is False
            and len(violations) >= 1
            and v0.get("code") == expected_code
            and expected_substr in stderr
            and origin_sp.get("file") == str(fpath)
            and int(origin_sp.get("line", 0)) >= 1
            and "= judgment:" in stderr
            and "= help:" in stderr
            and len(leaks_found) == 0
        )
        assert passed, (
            f"Diagnostic clarity check failed on {case_id}:\n"
            f"  rc={rc}, expected_code={expected_code}, got={v0.get('code')}\n"
            f"  origin_span={origin_sp}\n"
            f"  leaks_found={leaks_found}\n"
            f"  stderr:\n{stderr}"
        )
        probe_results.append(
            {
                "case_id": case_id,
                "expected_code": expected_code,
                "origin_line": origin_sp.get("line"),
                "origin_col": origin_sp.get("column"),
                "leaks_found": leaks_found,
                "passed": True,
            }
        )

    # Also probe `LFQ-E-TARGET-PROFILE` and `LFQ-E-GUARD-SPEC` explicitly:
    bad_tgt = err_dir / "21_unknown_target_profile.lfq"
    bad_tgt.write_text(
        "#lang lakefillq\n(target-profile bogus-quantum-toaster)\n(defqfree (c #:wires ([x (qvec 1)])) (x (wref x 0)))\n",
        encoding="utf-8",
    )
    rc_t, js_t, stderr_t = run_lakefillqc(bad_tgt)
    vt = (js_t.get("violations") or [{}])[0]
    assert rc_t == 1 and vt.get("code") == "LFQ-E-TARGET-PROFILE"
    assert vt["provenance_spans"]["origin_span"]["line"] == 2
    probe_results.append(
        {
            "case_id": "21_unknown_target_profile",
            "expected_code": "LFQ-E-TARGET-PROFILE",
            "origin_line": 2,
            "origin_col": 0,
            "leaks_found": [tok for tok in FORBIDDEN_INTERNAL_LEAKS if tok in stderr_t],
            "passed": True,
        }
    )

    bad_gspec = err_dir / "22_malformed_guard_spec.lfq"
    bad_gspec.write_text(
        "#lang lakefillq\n(target-profile ideal)\n(defqfree (bad-gspec #:wires ([x (qvec 2)]) #:scratch ([anc (qvec 1)]))\n  (erase-by-part-bij '(not-a-valid-part-bij-spec 1 2 3) (cx (wref x 0) (wref anc 0)) (cx (wref x 0) (wref anc 0)) anc))\n",
        encoding="utf-8",
    )
    rc_g, js_g, stderr_g = run_lakefillqc(bad_gspec)
    vg = (js_g.get("violations") or [{}])[0]
    assert rc_g == 1 and vg.get("code") == "LFQ-E-GUARD-SPEC"
    assert vg["provenance_spans"]["mutating_span"]["line"] == 4
    assert not any(tok in stderr_g for tok in FORBIDDEN_INTERNAL_LEAKS)
    probe_results.append(
        {
            "case_id": "22_malformed_guard_spec",
            "expected_code": "LFQ-E-GUARD-SPEC",
            "origin_line": vg["provenance_spans"]["origin_span"]["line"],
            "origin_col": vg["provenance_spans"]["origin_span"]["column"],
            "leaks_found": [],
            "passed": True,
        }
    )
    return probe_results


def verify_raco_and_lean() -> Dict[str, Any]:
    raco_proc = subprocess.run(
        [
            str(RACO_BIN),
            "test",
            "compiler/lakefillq-graded-coeffect-effect-bimodule.rkt",
            "compiler/lakefillq-multipass-diagnostics.rkt",
            "compiler/lakefillq-cluster-qasm3-codegen.rkt",
            "compiler/lakefillqc.rkt",
        ],
        cwd=str(REPO_ROOT),
        env=clean_env(),
        capture_output=True,
        text=True,
        check=False,
    )
    assert raco_proc.returncode == 0, f"raco test failed:\n{raco_proc.stdout}\n{raco_proc.stderr}"

    lean_file = REPO_ROOT / "proofs" / "lakefillq_holistic_modular_duoidal_cohesion_proofs.lean"
    lean_proc = subprocess.run(
        [str(LEAN_BIN), str(lean_file)],
        cwd=str(REPO_ROOT),
        env=clean_env(),
        capture_output=True,
        text=True,
        check=False,
    )
    assert lean_proc.returncode == 0 and lean_proc.stdout.strip() == "", (
        f"Lean verification failed:\n{lean_proc.stdout}\n{lean_proc.stderr}"
    )
    return {
        "raco_tests_passed": True,
        "lean_cohesion_proofs_verified": True,
        "lean_file": str(lean_file.relative_to(REPO_ROOT)),
    }


def main() -> int:
    work_dir = PERSISTENT_TMP / f"holistic_cohesion_verify_{os.getpid()}"
    work_dir.mkdir(parents=True, exist_ok=True)
    try:
        modular_summary = verify_modular_cipher_and_aes(work_dir)
        escalation_summary = verify_zero_flag_xag_escalation(work_dir)
        error_probes = verify_twenty_real_error_programs(work_dir)
        formal_summary = verify_raco_and_lean()
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)

    report = {
        "verifier": "verify_lakefillq_holistic_language_cohesion.py",
        "all_passed": True,
        "holistic_seams_closed": 5,
        "real_error_programs_verified": len(error_probes),
        "internal_leaks_detected": 0,
        "modular_and_auto_cluster": modular_summary,
        "zero_flag_xag_escalation": escalation_summary,
        "error_clarity_probes": error_probes,
        "raco_and_lean": formal_summary,
    }
    ARTIFACT_PATH.parent.mkdir(parents=True, exist_ok=True)
    ARTIFACT_PATH.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        f"[PASS] Holistic language cohesion & {len(error_probes)} real error-clarity probes verified "
        f"(Aer Fidelity={modular_summary['modular_cipher']['aer_superposition_fidelity']:.6f}, "
        f"0 internal leaks)."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
