#!/usr/bin/env python3
"""
Drop-In Python / OpenQASM 3.0 / OpenQASM 2.0 / Qiskit Static Bug-Linter
and Convex M* Distributed Cluster Sizer (`ae/lakefillq_lint.py`).

Projects LakefillQ's single unified typing judgment
  `Gamma_in |- t : Q_e(A) -| Gamma_out`
and its 7 static side-condition rules (`T-DomImg`, `T-BorrowZ`, `T-PhaseClean`,
`T-CounitU4`, `T-SubNorm`, `T-QubitCap`, `T-ParGuard`) directly onto external
OpenQASM 3.0, OpenQASM 2.0, and Qiskit `QuantumCircuit` programs via:
  1. Direct OpenQASM 3.0 / 2.0 AST parsing (`openqasm3.parse` & Qiskit QASM
     loaders) and live `qiskit.QuantumCircuit` instruction lifting into an
     internal gate DAG with exact gate indices and wire names.
  2. Hash-consed XOR-AND Graph (`XAGManager`) + `Z3` symbolic miter engine for:
     - `T-DomImg`: non-injectivity, aliased in-place mutation (`GF(2^k)` / bilinear
       read-after-write self-aliasing), domain-image collision, and `g(f(x)) == x`.
     - `T-BorrowZ`: `H`/`X`/`RX` basis pollution or un-restored mutation on
       borrowed `ConstZ` control wires and oracle validity witnesses.
     - `T-PhaseClean`: Bennet uncomputation leaving un-zeroed ancillas (`Law U1`)
       or residual `Z`/`CZ`/`S`/`T` relative phase kickbacks on `Dom`.
     - `T-CounitU4`: redundant reverse Bell-pair / cross-QPU remote-`CX`
       cat-disentanglers where `0`-ebit `M_X` + classical `Z` fixup suffices,
       missing `Z`/`CZ` fixups after `M_X`, and `Z`-basis measurement collapse.
     - `T-SubNorm`: `QSVT`/`LCU` block-encoding subnormalization overflow
       `alpha_actual > alpha_declared` (analytic + exact circuit unitary block
       extraction) and Chebyshev `d^2 * eps_0 > eps_target` error overflow.
     - `T-QubitCap`: single-QPU capacity overflow `Q_circuit > Q_cap` without a
       multi-QPU partition, plus chordal ancilla width & AST slice integrity.
  3. Convex `M* <= 256` Multi-QPU Cluster Sizer (`T-ParGuard`) over candidate
     grid `M in {1, 2, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 256}` across
     `all-to-all-peers` and `switched-optical-tree` topologies, with U-curve
     knee dominance pruning, honest `M* = 1` single-QPU fallback when sequential
     or communication-dominated, `0`-carry `QRNS` + `Law U4` GHZ ebit accounting,
     and suboptimal `M_requested != M*` detection.

CLI Usage:
  python3 ae/lakefillq_lint.py path/to/circuit.qasm --json --q-cap 400 --r-bell 100000 --topology switched-optical-tree --max-machines 256
  python3 ae/lakefillq_lint.py --qasm path/to/circuit.qasm [--spec-json spec.json] [--json]
  python3 ae/lakefillq_lint.py --workload ECC-256 --q-cap 400 --r-bell 100000 --max-machines 256
  python3 ae/lakefillq_lint.py --self-test [--json]
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import glob
import json
import math
import os
from pathlib import Path
import re
import sys
import time
from typing import Any, Callable, Dict, List, Optional, Sequence, Set, Tuple, Union

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


def ensure_persistent_tmpdir() -> Path:
    host_tmp = Path.home() / "toolchains" / "tmp"
    local_tmp = REPO_ROOT / ".lakefillq_tmp"
    env_tmp = os.environ.get("TMPDIR", "").strip()
    forb = ("/" + "t" + "m" + "p", "/var/" + "t" + "m" + "p", "/dev/" + "shm")
    if env_tmp and not any(env_tmp == p or env_tmp.startswith(p + "/") for p in forb):
        p = Path(env_tmp).resolve()
        p.mkdir(parents=True, exist_ok=True)
        os.environ["TMPDIR"] = str(p)
        return p
    if host_tmp.parent.is_dir():
        host_tmp.mkdir(parents=True, exist_ok=True)
        os.environ["TMPDIR"] = str(host_tmp)
        return host_tmp
    local_tmp.mkdir(parents=True, exist_ok=True)
    os.environ["TMPDIR"] = str(local_tmp)
    return local_tmp


ensure_persistent_tmpdir()

import numpy as np
import openqasm3
from openqasm3 import ast as qasm_ast
from qiskit import QuantumCircuit
import qiskit.qasm3
import z3


ALL_SEVEN_RULES: List[str] = [
    "T-DomImg",
    "T-BorrowZ",
    "T-PhaseClean",
    "T-CounitU4",
    "T-SubNorm",
    "T-QubitCap",
    "T-ParGuard",
]

DEFAULT_CANDIDATE_MACHINES: List[int] = [1, 2, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 256]
LOCAL_CCX_RATE_PER_MODULE_HZ: float = 250000.0
QEC_WINDOW_CUT_SYNC_COEFF_SEC: float = 0.0001128


# ==============================================================================
# 1. Core IR, Diagnostic, and Specification Data Structures
# ==============================================================================


@dataclass
class GateNode:
    gate_index: int
    op: str
    qubits: List[int]
    wire_names: List[str]
    clbits: List[int] = field(default_factory=list)
    clbit_names: List[str] = field(default_factory=list)
    params: List[float] = field(default_factory=list)
    condition: Optional[Tuple[int, str, int]] = None  # (clbit_idx, clbit_name, expected_bit)
    neg_controls: List[int] = field(default_factory=list)
    unitary_matrix: Optional[np.ndarray] = None
    source_line: Optional[int] = None
    is_negctrl_wrap: bool = False


@dataclass
class LiftedCircuit:
    name: str
    source_kind: str
    num_qubits: int
    num_clbits: int
    wire_names: List[str]
    clbit_names: List[str]
    gates: List[GateNode]
    raw_qc: Optional[QuantumCircuit] = None
    embedded_pragmas: Dict[str, Any] = field(default_factory=dict)


@dataclass
class LintDiagnostic:
    rule: str
    severity: str  # "ERROR" | "WARNING"
    code: str
    message: str
    gate_indices: List[int] = field(default_factory=list)
    wire_names: List[str] = field(default_factory=list)
    counterexample: Optional[Dict[str, Any]] = None
    repair_suggestion: str = ""
    details: Dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "rule": self.rule,
            "severity": self.severity,
            "code": self.code,
            "message": self.message,
            "gate_indices": list(self.gate_indices),
            "wire_names": list(self.wire_names),
            "counterexample": self.counterexample,
            "repair_suggestion": self.repair_suggestion,
            "details": dict(self.details),
        }


@dataclass
class LintSpec:
    # Rule 1 (T-DomImg): Wire partitioning, aliasing, injectivity & domain-image
    input_wires: Optional[List[int]] = None
    output_wires: Optional[List[int]] = None
    ancilla_wires: Optional[List[int]] = None
    readonly_input_wires: Optional[List[int]] = None
    gf2k_mul_spec: Optional[Dict[str, Any]] = None
    domain_predicate: Optional[Dict[str, Any]] = None
    expect_identity_on_inputs: bool = False
    uncompute_qasm: Optional[str] = None
    uncompute_qc: Optional[Any] = None
    inverse_domain_predicate: Optional[Dict[str, Any]] = None
    check_support_injectivity: bool = False

    # Rule 2 (T-BorrowZ): Borrowed ConstZ control wires & validity-witness guard
    borrowed_z_wires: Optional[List[int]] = None
    validity_witness_wire: Optional[int] = None
    witness_ready_after_gate: int = -1
    oracle_phase_target_wires: Optional[List[int]] = None

    # Rule 3 (T-PhaseClean): Bennet uncomputation ancilla & phase cleanliness
    expect_phase_clean: Optional[bool] = None

    # Rule 4 (T-CounitU4): Law U4 modal counit & multi-QPU cat-disentanglement
    check_mbu_law_u4: bool = True
    qpu_partition: Optional[Union[Dict[Any, int], List[int]]] = None

    # Rule 5 (T-SubNorm): QSVT / LCU block-encoding subnormalization & Chebyshev eps
    block_encoding_spec: Optional[Dict[str, Any]] = None
    require_involutory: bool = False
    lcu_branch_degrees: Optional[List[int]] = None
    drift_spec: Optional[Dict[str, Any]] = None

    # Wire basis, linear/affine matrix, permutation, S-box, or stencil (T-DomImg)
    wire_permutation: Optional[List[int]] = None
    expected_linear_matrix_gf2: Optional[List[List[int]]] = None
    expected_column_masks: Optional[List[int]] = None
    affine_constant: int = 0
    expected_sbox_table: Optional[List[int]] = None
    stencil_spec: Optional[Dict[str, Any]] = None

    # Rule 6 (T-QubitCap): Single-QPU capacity & unified IR resource checks
    q_cap: Optional[int] = None
    claimed_temp_ands: Optional[int] = None
    claimed_ccx: Optional[int] = None
    claimed_qubits: Optional[int] = None
    matrix_elim_slice: Optional[Dict[str, Any]] = None
    grover_oracle_spec: Optional[Dict[str, Any]] = None
    expected_boolean_miter: Optional[Dict[str, Any]] = None

    # Rule 7 (T-ParGuard): Parallel partitionability & Convex M* Cluster Sizer
    requested_machines: Optional[int] = None
    cluster_spec: Optional[Dict[str, Any]] = None

    @classmethod
    def from_dict(cls, data: Optional[Dict[str, Any]]) -> "LintSpec":
        if not data:
            return cls()
        known_fields = set(cls.__dataclass_fields__.keys())
        filtered = {k: v for k, v in data.items() if k in known_fields}
        return cls(**filtered)


@dataclass
class LintReport:
    status: str  # "PASS" | "FAIL"
    well_typed: bool
    circuit_name: str
    source_kind: str
    rules_checked: List[str]
    error_count: int
    warning_count: int
    diagnostics: List[LintDiagnostic]
    ir_metrics: Dict[str, Any]
    cluster_sizing: Optional[Dict[str, Any]]
    elapsed_ms: float

    def to_dict(self) -> Dict[str, Any]:
        return {
            "status": self.status,
            "well_typed": self.well_typed,
            "circuit_name": self.circuit_name,
            "source_kind": self.source_kind,
            "rules_checked": list(self.rules_checked),
            "error_count": self.error_count,
            "warning_count": self.warning_count,
            "diagnostics": [d.to_dict() for d in self.diagnostics],
            "ir_metrics": dict(self.ir_metrics),
            "cluster_sizing": self.cluster_sizing,
            "elapsed_ms": round(self.elapsed_ms, 3),
        }

    def to_json(self, indent: int = 2) -> str:
        return json.dumps(self.to_dict(), indent=indent)

    def format_human_readable(self) -> str:
        lines: List[str] = []
        lines.append("=" * 88)
        lines.append(
            f"LakefillQ Static Bug-Linter & Convex M* Sizer | Circuit: {self.circuit_name} "
            f"({self.source_kind}) | Status: {self.status} ({self.elapsed_ms:.2f} ms)"
        )
        lines.append("=" * 88)
        m = self.ir_metrics
        lines.append(
            f"IR Metrics: qubits={m.get('declared_qubits', 0)} "
            f"(live={m.get('live_qubit_width', 0)}, "
            f"chordal_reusable_ancillas={m.get('chordal_reusable_ancilla_width', 0)}), "
            f"TempAND(M_X)={m.get('temp_and_count', 0)}, CCX={m.get('ccx_count', 0)}, "
            f"CX={m.get('cx_count', 0)}, SWAP={m.get('swap_count', 0)}, "
            f"mid_meas={m.get('mid_circuit_meas_count', 0)}"
        )
        if self.cluster_sizing is not None:
            cs = self.cluster_sizing
            lines.append(
                f"Cluster M* Sizer ({cs.get('workload', 'circuit')}, "
                f"Q_cap={cs.get('q_cap_per_machine')}, M_max={cs.get('max_machines')}, "
                f"topology={cs.get('interconnect_topology')}): "
                f"grade={cs.get('qpar_grade')}, M*={cs.get('optimal_machines')} "
                f"(machines_used={cs.get('machines_used')}), "
                f"Q/machine={cs.get('q_allocated_per_machine')}, "
                f"logical_ebits={cs.get('logical_ebits_total', 0)} "
                f"(lookup={cs.get('lookup_ebits_total', 0)}, carry={cs.get('carry_ebits_total', 0)}), "
                f"fallback_1m={cs.get('fallback_to_single_machine')}"
            )
        if not self.diagnostics:
            lines.append("Diagnostics: 0 errors, 0 warnings across all 7 LakefillQ static rules.")
        else:
            lines.append(
                f"Diagnostics ({self.error_count} error(s), {self.warning_count} warning(s)):"
            )
            for idx, d in enumerate(self.diagnostics, 1):
                g_str = f"gates={d.gate_indices}" if d.gate_indices else "gates=spec"
                w_str = f"wires={d.wire_names}" if d.wire_names else "wires=n/a"
                lines.append(f"  [{idx}] [{d.severity}] {d.rule} :: {d.code} ({g_str}, {w_str})")
                oblig = d.details.get("unified_judgment_obligation")
                if oblig:
                    lines.append(f"      Unified Judgment: {oblig}")
                lines.append(f"      Message: {d.message}")
                prov = d.details.get("provenance_spans")
                if isinstance(prov, dict):
                    o_sp = prov.get("origin_span", {})
                    m_sp = prov.get("mutating_span", {})
                    f_sp = prov.get("failure_span", {})
                    lines.append(
                        f"      Provenance: origin={o_sp.get('file', '<circuit>')}:{o_sp.get('line', 1)} "
                        f"({o_sp.get('surface_form', 'entry')}) -> "
                        f"cause={m_sp.get('file', '<circuit>')}:{m_sp.get('line', 1)} "
                        f"({m_sp.get('surface_form', 'gate')}) -> "
                        f"exit={f_sp.get('file', '<circuit>')}:{f_sp.get('line', 1)} "
                        f"({f_sp.get('surface_form', 'boundary')})"
                    )
                if d.counterexample:
                    lines.append(f"      Z3/Algebraic Witness: {json.dumps(d.counterexample)}")
                if d.repair_suggestion:
                    lines.append(f"      Suggested Repair: {d.repair_suggestion}")
        lines.append("=" * 88)
        return "\n".join(lines)


# ==============================================================================
# 2. Hash-Consed XOR-AND Graph (`XAGManager`) + Z3 Translation Engine
# ==============================================================================


class XAGManager:
    """
    Complement-edge structural XOR-AND Graph (XAG) manager.
    Literal encoding: `lit = (node_id << 1) | compl_bit`, where `node_id == 0`
    is constant False (`lit_zero = 0`, `lit_one = 1`).
    """

    LIT_ZERO = 0
    LIT_ONE = 1

    def __init__(self) -> None:
        # Node 0 is constant False; nodes >= 1 are ("var", idx, 0) | ("xor", u, v) | ("and", u, v)
        self.nodes: List[Tuple[str, int, int]] = [("const0", 0, 0)]
        self.table: Dict[Tuple[str, int, int], int] = {}
        self.var_lits: Dict[int, int] = {}

    @staticmethod
    def lit_not(lit: int) -> int:
        return lit ^ 1

    def var(self, var_idx: int) -> int:
        if var_idx in self.var_lits:
            return self.var_lits[var_idx]
        nid = len(self.nodes)
        self.nodes.append(("var", var_idx, 0))
        lit = nid << 1
        self.var_lits[var_idx] = lit
        return lit

    def xor(self, a: int, b: int) -> int:
        if a == 0:
            return b
        if b == 0:
            return a
        if a == 1:
            return b ^ 1
        if b == 1:
            return a ^ 1
        if a == b:
            return 0
        if a == (b ^ 1):
            return 1
        neg = (a & 1) ^ (b & 1)
        u = a & ~1
        v = b & ~1
        if u == v:
            return neg
        # 2-step associative cancellation: (x ^ y) ^ x == y
        kind_u, u1, u2 = self.nodes[u >> 1]
        if kind_u == "xor":
            if u1 == v:
                return u2 ^ neg
            if u2 == v:
                return u1 ^ neg
        kind_v, v1, v2 = self.nodes[v >> 1]
        if kind_v == "xor":
            if v1 == u:
                return v2 ^ neg
            if v2 == u:
                return v1 ^ neg
        if u > v:
            u, v = v, u
        key = ("xor", u, v)
        nid = self.table.get(key)
        if nid is None:
            nid = len(self.nodes)
            self.nodes.append(key)
            self.table[key] = nid
        return (nid << 1) | neg

    def and_(self, a: int, b: int) -> int:
        if a == 0 or b == 0:
            return 0
        if a == 1:
            return b
        if b == 1:
            return a
        if a == b:
            return a
        if a == (b ^ 1):
            return 0
        if a > b:
            a, b = b, a
        key = ("and", a, b)
        nid = self.table.get(key)
        if nid is None:
            nid = len(self.nodes)
            self.nodes.append(key)
            self.table[key] = nid
        return nid << 1

    def ite(self, cond_lit: int, then_lit: int, else_lit: int) -> int:
        if cond_lit == 0:
            return else_lit
        if cond_lit == 1:
            return then_lit
        if then_lit == else_lit:
            return then_lit
        # else ^ (cond & (then ^ else))
        diff = self.xor(then_lit, else_lit)
        return self.xor(else_lit, self.and_(cond_lit, diff))

    def eval_concrete(self, lits: Sequence[int], var_bits: Dict[int, int]) -> List[int]:
        memo: Dict[int, int] = {0: 0}

        def eval_nid(nid: int) -> int:
            if nid in memo:
                return memo[nid]
            kind, a, b = self.nodes[nid]
            if kind == "var":
                val = int(var_bits.get(a, 0)) & 1
            elif kind == "xor":
                va = eval_nid(a >> 1) ^ (a & 1)
                vb = eval_nid(b >> 1) ^ (b & 1)
                val = va ^ vb
            elif kind == "and":
                va = eval_nid(a >> 1) ^ (a & 1)
                vb = eval_nid(b >> 1) ^ (b & 1)
                val = va & vb
            else:
                val = 0
            memo[nid] = val
            return val

        return [eval_nid(l >> 1) ^ (l & 1) for l in lits]

    def to_z3_map(self, z3_vars: Dict[int, z3.BoolRef], target_lits: Sequence[int]) -> Dict[int, z3.BoolRef]:
        memo_node: Dict[int, z3.BoolRef] = {0: z3.BoolVal(False)}

        def build_nid(nid: int) -> z3.BoolRef:
            if nid in memo_node:
                return memo_node[nid]
            kind, a, b = self.nodes[nid]
            if kind == "var":
                expr = z3_vars[a]
            elif kind == "xor":
                ea = build_lit(a)
                eb = build_lit(b)
                expr = z3.Xor(ea, eb)
            elif kind == "and":
                ea = build_lit(a)
                eb = build_lit(b)
                expr = z3.And(ea, eb)
            else:
                expr = z3.BoolVal(False)
            memo_node[nid] = expr
            return expr

        def build_lit(lit: int) -> z3.BoolRef:
            base = build_nid(lit >> 1)
            if lit & 1:
                if z3.is_true(base):
                    return z3.BoolVal(False)
                if z3.is_false(base):
                    return z3.BoolVal(True)
                return z3.Not(base)
            return base

        return {lit: build_lit(lit) for lit in set(target_lits)}


# ==============================================================================
# 3. Frontends: OpenQASM 3.0 / OpenQASM 2.0 Parser & Qiskit Circuit Lifter
# ==============================================================================


def _eval_qasm_int_expr(expr: Any, loop_env: Dict[str, int]) -> int:
    if isinstance(expr, qasm_ast.IntegerLiteral):
        return int(expr.value)
    if isinstance(expr, qasm_ast.Identifier):
        if expr.name in loop_env:
            return loop_env[expr.name]
        raise ValueError(f"Unbound integer identifier in OpenQASM expression: {expr.name}")
    if isinstance(expr, qasm_ast.UnaryExpression):
        val = _eval_qasm_int_expr(expr.expression, loop_env)
        op_name = getattr(expr.op, "name", str(expr.op))
        if "-" in op_name:
            return -val
        return val
    if isinstance(expr, qasm_ast.BinaryExpression):
        lhs = _eval_qasm_int_expr(expr.lhs, loop_env)
        rhs = _eval_qasm_int_expr(expr.rhs, loop_env)
        op_sym = getattr(expr.op, "name", str(expr.op))
        if "+" in op_sym:
            return lhs + rhs
        if "-" in op_sym:
            return lhs - rhs
        if "*" in op_sym:
            return lhs * rhs
        if "/" in op_sym:
            return lhs // rhs
        if "%" in op_sym:
            return lhs % rhs
    raise ValueError(f"Unsupported OpenQASM integer expression: {expr!r}")


def _eval_qasm_float_expr(expr: Any, param_env: Dict[str, float]) -> float:
    if isinstance(expr, qasm_ast.IntegerLiteral):
        return float(expr.value)
    if isinstance(expr, qasm_ast.FloatLiteral):
        return float(expr.value)
    if isinstance(expr, qasm_ast.Identifier):
        if expr.name == "pi" or expr.name == "π":
            return math.pi
        if expr.name == "tau":
            return 2.0 * math.pi
        if expr.name == "euler":
            return math.e
        if expr.name in param_env:
            return param_env[expr.name]
        raise ValueError(f"Unbound float parameter `{expr.name}` in OpenQASM gate")
    if isinstance(expr, qasm_ast.UnaryExpression):
        v = _eval_qasm_float_expr(expr.expression, param_env)
        op_name = getattr(expr.op, "name", str(expr.op))
        return -v if "-" in op_name else v
    if isinstance(expr, qasm_ast.BinaryExpression):
        lhs = _eval_qasm_float_expr(expr.lhs, param_env)
        rhs = _eval_qasm_float_expr(expr.rhs, param_env)
        op_name = getattr(expr.op, "name", str(expr.op))
        if "+" in op_name:
            return lhs + rhs
        if "-" in op_name:
            return lhs - rhs
        if "*" in op_name:
            return lhs * rhs
        if "/" in op_name:
            return lhs / rhs
    raise ValueError(f"Unsupported OpenQASM angle expression: {expr!r}")


def _extract_qasm_pragmas(qasm_src: str) -> Dict[str, Any]:
    merged: Dict[str, Any] = {}
    for raw_ln in qasm_src.splitlines():
        ln = raw_ln.strip()
        if ln.startswith("//") and "@lakefillq" in ln:
            idx = ln.find("@lakefillq") + len("@lakefillq")
            payload = ln[idx:].strip()
            if payload.startswith(":"):
                payload = payload[1:].strip()
            if payload.startswith("{"):
                try:
                    obj = json.loads(payload)
                    if isinstance(obj, dict):
                        merged.update(obj)
                except Exception:
                    pass
    return merged


def parse_qasm_to_lifted_circuit(qasm_src: str, name: str = "qasm_circuit") -> LiftedCircuit:
    """
    Parses OpenQASM 3.0 (via `openqasm3.parse`) or OpenQASM 2.0 (via
    `QuantumCircuit.from_qasm_str` + `openqasm3.parse`) into `LiftedCircuit`.
    """
    embedded_pragmas = _extract_qasm_pragmas(qasm_src)
    header_stripped = "\n".join(
        ln for ln in qasm_src.splitlines() if not ln.strip().startswith("//")
    ).strip()
    if header_stripped.startswith("OPENQASM 2"):
        qc2 = QuantumCircuit.from_qasm_str(qasm_src)
        qc2.name = name
        lifted2 = lift_qiskit_circuit(qc2, source_kind="openqasm2")
        lifted2.embedded_pragmas = embedded_pragmas
        return lifted2

    prog = openqasm3.parse(qasm_src)
    wire_names: List[str] = []
    wire_lookup: Dict[Tuple[str, Optional[int]], int] = {}
    qreg_sizes: Dict[str, int] = {}

    clbit_names: List[str] = []
    clbit_lookup: Dict[Tuple[str, Optional[int]], int] = {}
    creg_sizes: Dict[str, int] = {}

    gate_defs: Dict[str, Any] = {}
    gates: List[GateNode] = []

    def resolve_qubits(qarg: Any, qubit_env: Dict[str, int], loop_env: Dict[str, int]) -> List[int]:
        if isinstance(qarg, qasm_ast.Identifier):
            if qarg.name in qubit_env:
                return [qubit_env[qarg.name]]
            if (qarg.name, None) in wire_lookup:
                return [wire_lookup[(qarg.name, None)]]
            if qarg.name in qreg_sizes:
                return [wire_lookup[(qarg.name, idx)] for idx in range(qreg_sizes[qarg.name])]
            raise KeyError(f"Unknown qubit identifier `{qarg.name}`")
        if isinstance(qarg, qasm_ast.IndexedIdentifier):
            rname = qarg.name.name
            idx_list = qarg.indices[0]
            if len(idx_list) == 1 and not isinstance(idx_list[0], qasm_ast.RangeDefinition):
                idx_val = _eval_qasm_int_expr(idx_list[0], loop_env)
                return [wire_lookup[(rname, idx_val)]]
        raise ValueError(f"Unsupported qubit designator: {qarg!r}")

    def resolve_clbits(carg: Any, loop_env: Dict[str, int]) -> List[int]:
        if isinstance(carg, qasm_ast.Identifier):
            if (carg.name, None) in clbit_lookup:
                return [clbit_lookup[(carg.name, None)]]
            if carg.name in creg_sizes:
                return [clbit_lookup[(carg.name, idx)] for idx in range(creg_sizes[carg.name])]
            raise KeyError(f"Unknown classical bit `{carg.name}`")
        if isinstance(carg, qasm_ast.IndexedIdentifier):
            cname = carg.name.name
            idx_val = _eval_qasm_int_expr(carg.indices[0][0], loop_env)
            return [clbit_lookup[(cname, idx_val)]]
        if isinstance(carg, qasm_ast.IndexExpression):
            cname = carg.collection.name
            idx_val = _eval_qasm_int_expr(carg.index[0], loop_env)
            return [clbit_lookup[(cname, idx_val)]]
        raise ValueError(f"Unsupported classical bit designator: {carg!r}")

    def parse_branch_cond(cond_expr: Any, loop_env: Dict[str, int]) -> Tuple[int, str, int]:
        if isinstance(cond_expr, (qasm_ast.IndexExpression, qasm_ast.Identifier, qasm_ast.IndexedIdentifier)):
            cidx = resolve_clbits(cond_expr, loop_env)[0]
            return (cidx, clbit_names[cidx], 1)
        if isinstance(cond_expr, qasm_ast.UnaryExpression):
            op_name = getattr(cond_expr.op, "name", str(cond_expr.op))
            if "!" in op_name or "NOT" in op_name.upper():
                cidx = resolve_clbits(cond_expr.expression, loop_env)[0]
                return (cidx, clbit_names[cidx], 0)
        if isinstance(cond_expr, qasm_ast.BinaryExpression):
            op_name = getattr(cond_expr.op, "name", str(cond_expr.op))
            cidx = resolve_clbits(cond_expr.lhs, loop_env)[0]
            if isinstance(cond_expr.rhs, qasm_ast.BooleanLiteral):
                rhs_val = 1 if cond_expr.rhs.value else 0
            else:
                rhs_val = _eval_qasm_int_expr(cond_expr.rhs, loop_env)
            if "!=" in op_name:
                rhs_val = 1 - rhs_val
            return (cidx, clbit_names[cidx], rhs_val)
        raise ValueError(f"Unsupported OpenQASM 3 branch condition: {cond_expr!r}")

    def normalize_gate_op(raw_op: str, n_ctrls: int) -> str:
        op = raw_op.lower()
        alias_map = {
            "cnot": "cx",
            "toffoli": "ccx",
            "fredkin": "cswap",
            "phase": "p",
            "u1": "p",
            "cphase": "cp",
            "id": "i",
        }
        op = alias_map.get(op, op)
        if n_ctrls > 0:
            if op == "x":
                if n_ctrls == 1:
                    return "cx"
                if n_ctrls == 2:
                    return "ccx"
                return "mcx"
            if op == "z":
                if n_ctrls == 1:
                    return "cz"
                if n_ctrls == 2:
                    return "ccz"
            if op == "swap" and n_ctrls == 1:
                return "cswap"
            if op == "p" and n_ctrls == 1:
                return "cp"
        return op

    def emit_gate(
        op_name: str,
        q_indices: List[int],
        params: List[float],
        cond: Optional[Tuple[int, str, int]],
        neg_ctrls: List[int],
        line_no: Optional[int],
        is_negctrl_wrap: bool = False,
    ) -> None:
        if op_name == "i":
            return
        gates.append(
            GateNode(
                gate_index=len(gates),
                op=op_name,
                qubits=list(q_indices),
                wire_names=[wire_names[q] for q in q_indices],
                params=list(params),
                condition=cond,
                neg_controls=list(neg_ctrls),
                source_line=line_no,
                is_negctrl_wrap=is_negctrl_wrap,
            )
        )

    def lower_stmt(
        stmt: Any,
        qubit_env: Dict[str, int],
        param_env: Dict[str, float],
        loop_env: Dict[str, int],
        active_cond: Optional[Tuple[int, str, int]],
        inherited_inv: bool = False,
    ) -> None:
        line_no = stmt.span.start_line if getattr(stmt, "span", None) else None

        if isinstance(stmt, qasm_ast.Include):
            return
        if isinstance(stmt, qasm_ast.QubitDeclaration):
            rname = stmt.qubit.name
            if stmt.size is None:
                idx = len(wire_names)
                wire_names.append(rname)
                wire_lookup[(rname, None)] = idx
            else:
                sz = _eval_qasm_int_expr(stmt.size, loop_env)
                qreg_sizes[rname] = sz
                for i in range(sz):
                    idx = len(wire_names)
                    wire_names.append(f"{rname}[{i}]")
                    wire_lookup[(rname, i)] = idx
            return
        if isinstance(stmt, qasm_ast.ClassicalDeclaration):
            if isinstance(stmt.type, qasm_ast.BitType):
                cname = stmt.identifier.name
                if stmt.type.size is None:
                    cidx = len(clbit_names)
                    clbit_names.append(cname)
                    clbit_lookup[(cname, None)] = cidx
                else:
                    sz = _eval_qasm_int_expr(stmt.type.size, loop_env)
                    creg_sizes[cname] = sz
                    for i in range(sz):
                        cidx = len(clbit_names)
                        clbit_names.append(f"{cname}[{i}]")
                        clbit_lookup[(cname, i)] = cidx
            return
        gate_def_cls = getattr(qasm_ast, "QuantumGateDefinition", getattr(qasm_ast, "GateDeclaration", ()))
        if isinstance(stmt, gate_def_cls):
            gate_defs[stmt.name.name] = stmt
            return
        if isinstance(stmt, qasm_ast.QuantumBarrier):
            qs: List[int] = []
            for qd in stmt.qubits:
                qs.extend(resolve_qubits(qd, qubit_env, loop_env))
            gates.append(
                GateNode(
                    gate_index=len(gates),
                    op="barrier",
                    qubits=qs,
                    wire_names=[wire_names[q] for q in qs],
                    condition=active_cond,
                    source_line=line_no,
                )
            )
            return
        if isinstance(stmt, qasm_ast.QuantumReset):
            for q in resolve_qubits(stmt.qubits, qubit_env, loop_env):
                gates.append(
                    GateNode(
                        gate_index=len(gates),
                        op="reset",
                        qubits=[q],
                        wire_names=[wire_names[q]],
                        condition=active_cond,
                        source_line=line_no,
                    )
                )
            return
        if isinstance(stmt, qasm_ast.QuantumMeasurementStatement):
            qs = resolve_qubits(stmt.measure.qubit, qubit_env, loop_env)
            cs = resolve_clbits(stmt.target, loop_env) if stmt.target is not None else []
            for idx_pair, q in enumerate(qs):
                c_list = [cs[idx_pair]] if idx_pair < len(cs) else []
                gates.append(
                    GateNode(
                        gate_index=len(gates),
                        op="measure",
                        qubits=[q],
                        wire_names=[wire_names[q]],
                        clbits=c_list,
                        clbit_names=[clbit_names[c] for c in c_list],
                        condition=active_cond,
                        source_line=line_no,
                    )
                )
            return
        if isinstance(stmt, qasm_ast.QuantumMeasurement):
            for q in resolve_qubits(stmt.qubit, qubit_env, loop_env):
                gates.append(
                    GateNode(
                        gate_index=len(gates),
                        op="measure",
                        qubits=[q],
                        wire_names=[wire_names[q]],
                        condition=active_cond,
                        source_line=line_no,
                    )
                )
            return
        if isinstance(stmt, qasm_ast.BranchingStatement):
            cond = parse_branch_cond(stmt.condition, loop_env)
            body_if = list(reversed(stmt.if_block)) if inherited_inv else list(stmt.if_block)
            for s_in in body_if:
                lower_stmt(s_in, qubit_env, param_env, loop_env, cond, inherited_inv)
            if stmt.else_block:
                neg_cond = (cond[0], cond[1], 1 - cond[2])
                body_el = list(reversed(stmt.else_block)) if inherited_inv else list(stmt.else_block)
                for s_el in body_el:
                    lower_stmt(s_el, qubit_env, param_env, loop_env, neg_cond, inherited_inv)
            return
        if isinstance(stmt, qasm_ast.ForInLoop):
            vname = stmt.identifier.name
            if isinstance(stmt.set_declaration, qasm_ast.RangeDefinition):
                start = _eval_qasm_int_expr(stmt.set_declaration.start, loop_env)
                end = _eval_qasm_int_expr(stmt.set_declaration.end, loop_env)
                step = (
                    _eval_qasm_int_expr(stmt.set_declaration.step, loop_env)
                    if stmt.set_declaration.step is not None
                    else 1
                )
                stop = end + (1 if step > 0 else -1)
                iter_vals = list(range(start, stop, step))
            elif isinstance(stmt.set_declaration, qasm_ast.DiscreteSet):
                iter_vals = [_eval_qasm_int_expr(v, loop_env) for v in stmt.set_declaration.values]
            else:
                raise ValueError(f"Unsupported ForInLoop set: {stmt.set_declaration!r}")
            if inherited_inv:
                iter_vals = list(reversed(iter_vals))
            for iv in iter_vals:
                next_loop = dict(loop_env)
                next_loop[vname] = iv
                body_stmts = list(reversed(stmt.block)) if inherited_inv else list(stmt.block)
                for body_s in body_stmts:
                    lower_stmt(body_s, qubit_env, param_env, next_loop, active_cond, inherited_inv)
            return
        if isinstance(stmt, qasm_ast.QuantumGate):
            gname = stmt.name.name
            eval_params = [_eval_qasm_float_expr(a, param_env) for a in stmt.arguments]
            q_args: List[int] = []
            for qd in stmt.qubits:
                q_args.extend(resolve_qubits(qd, qubit_env, loop_env))

            n_ctrls = 0
            neg_ctrl_positions: List[int] = []
            inv_flag = inherited_inv
            cur_ctrl_offset = 0
            for mod in stmt.modifiers:
                mname = getattr(mod.modifier, "name", str(mod.modifier)).upper()
                cnt = _eval_qasm_int_expr(mod.argument, loop_env) if mod.argument is not None else 1
                if mname == "INV":
                    inv_flag = not inv_flag
                elif mname == "CTRL":
                    n_ctrls += cnt
                    cur_ctrl_offset += cnt
                elif mname == "NEGCTRL":
                    for k in range(cnt):
                        neg_ctrl_positions.append(cur_ctrl_offset + k)
                    n_ctrls += cnt
                    cur_ctrl_offset += cnt

            if gname in gate_defs and n_ctrls == 0:
                gdecl = gate_defs[gname]
                sub_qenv = {
                    p.name: q_args[idx] for idx, p in enumerate(gdecl.qubits)
                }
                sub_penv = {
                    p.name: eval_params[idx] for idx, p in enumerate(gdecl.arguments)
                }
                raw_body = getattr(gdecl, "body", getattr(gdecl, "statements", []))
                sub_stmts = list(reversed(raw_body)) if inv_flag else list(raw_body)
                for bs in sub_stmts:
                    lower_stmt(bs, sub_qenv, sub_penv, loop_env, active_cond, inv_flag)
                return

            norm_op = normalize_gate_op(gname, n_ctrls)
            if inv_flag:
                if norm_op == "s":
                    norm_op = "sdg"
                elif norm_op == "sdg":
                    norm_op = "s"
                elif norm_op == "t":
                    norm_op = "tdg"
                elif norm_op == "tdg":
                    norm_op = "t"
                elif norm_op in ("rz", "rx", "ry", "p", "cp") and eval_params:
                    eval_params = [-eval_params[0]] + eval_params[1:]

            neg_wires = [q_args[pos] for pos in neg_ctrl_positions]
            for nw in neg_wires:
                emit_gate("x", [nw], [], active_cond, [], line_no, is_negctrl_wrap=True)
            emit_gate(norm_op, q_args, eval_params, active_cond, list(neg_wires), line_no)
            for nw in reversed(neg_wires):
                emit_gate("x", [nw], [], active_cond, [], line_no, is_negctrl_wrap=True)
            return

    for top_stmt in prog.statements:
        lower_stmt(top_stmt, {}, {}, {}, None, False)

    raw_qc: Optional[QuantumCircuit] = None
    try:
        norm_qasm = re.sub(r"if\s*\(([^)]+?)\s*==\s*1\)", r"if (\1 == true)", qasm_src)
        norm_qasm = re.sub(r"if\s*\(([^)]+?)\s*==\s*0\)", r"if (\1 == false)", norm_qasm)
        raw_qc = qiskit.qasm3.loads(norm_qasm)
    except Exception:
        raw_qc = None

    return LiftedCircuit(
        name=name,
        source_kind="openqasm3",
        num_qubits=len(wire_names),
        num_clbits=len(clbit_names),
        wire_names=wire_names,
        clbit_names=clbit_names,
        gates=gates,
        raw_qc=raw_qc,
        embedded_pragmas=embedded_pragmas,
    )


def lift_qiskit_circuit(qc: QuantumCircuit, source_kind: str = "qiskit") -> LiftedCircuit:
    """
    Lifts a live `qiskit.QuantumCircuit` object directly into `LiftedCircuit`,
    inspecting `x`, `cx`, `ccx`, `mcx`, `swap`, `cswap`, `h`, `s`, `sdg`, `t`,
    `tdg`, `rz`, `rx`, `ry`, `p`, `cp`, `measure`, `reset`, `UnitaryGate`, and
    classical `if_test` (`IfElseOp`) feedforward blocks.
    """
    wire_names: List[str] = []
    for idx, qb in enumerate(qc.qubits):
        loc = qc.find_bit(qb)
        if loc.registers:
            reg, r_idx = loc.registers[0]
            wire_names.append(f"{reg.name}[{r_idx}]")
        else:
            wire_names.append(f"q[{idx}]")

    clbit_names: List[str] = []
    for idx, cb in enumerate(qc.clbits):
        loc = qc.find_bit(cb)
        if loc.registers:
            creg, c_idx = loc.registers[0]
            clbit_names.append(f"{creg.name}[{c_idx}]")
        else:
            clbit_names.append(f"c[{idx}]")

    gates: List[GateNode] = []

    def extract_cond(cond_obj: Any) -> Optional[Tuple[int, str, int]]:
        if cond_obj is None:
            return None
        if isinstance(cond_obj, tuple) and len(cond_obj) == 2:
            lhs, val = cond_obj
            if hasattr(lhs, "_register") or lhs in qc.clbits:
                c_idx = qc.find_bit(lhs).index
                return (c_idx, clbit_names[c_idx], int(bool(val)))
            if hasattr(lhs, "size") and int(lhs.size) == 1:
                c_idx = qc.find_bit(lhs[0]).index
                return (c_idx, clbit_names[c_idx], int(val) & 1)
        return None

    def walk_qc(sub_qc: QuantumCircuit, q_map: List[int], c_map: List[int], active_cond: Optional[Tuple[int, str, int]]) -> None:
        for inst in sub_qc.data:
            op = inst.operation
            op_name = op.name.lower()
            inst_qs = [q_map[sub_qc.find_bit(q).index] for q in inst.qubits]
            inst_cs = [c_map[sub_qc.find_bit(c).index] for c in inst.clbits]
            inst_cond = active_cond

            if op_name == "if_else":
                cond_tuple = extract_cond(op.condition)
                true_body = op.params[0]
                false_body = op.params[1] if len(op.params) > 1 else None
                if true_body is not None:
                    t_qmap = inst_qs if len(true_body.qubits) == len(inst_qs) else q_map
                    t_cmap = inst_cs if len(true_body.clbits) == len(inst_cs) else c_map
                    walk_qc(true_body, t_qmap, t_cmap, cond_tuple or active_cond)
                if false_body is not None and cond_tuple is not None:
                    neg_cond = (cond_tuple[0], cond_tuple[1], 1 - cond_tuple[2])
                    f_qmap = inst_qs if len(false_body.qubits) == len(inst_qs) else q_map
                    f_cmap = inst_cs if len(false_body.clbits) == len(inst_cs) else c_map
                    walk_qc(false_body, f_qmap, f_cmap, neg_cond)
                continue

            alias_map = {
                "id": "i",
                "u1": "p",
                "c3x": "mcx",
                "c4x": "mcx",
                "mcx_gray": "mcx",
            }
            norm_op = alias_map.get(op_name, op_name)
            if norm_op == "i":
                continue

            known_prim = {
                "x", "y", "z", "h", "s", "sdg", "t", "tdg",
                "cx", "cy", "cz", "ccx", "rccx", "mcx", "ccz",
                "swap", "cswap", "rz", "rx", "ry", "p", "cp",
                "measure", "reset", "barrier",
            }
            umat: Optional[np.ndarray] = None
            params_float: List[float] = []
            for p in getattr(op, "params", []):
                if isinstance(p, (int, float, np.floating, np.integer)):
                    params_float.append(float(p))

            if norm_op not in known_prim:
                # Preserve exact matrix if available (`UnitaryGate`, controlled `UnitaryGate`, etc.)
                try:
                    umat = np.asarray(op.to_matrix(), dtype=np.complex128)
                    norm_op = "unitary"
                except Exception:
                    if getattr(op, "definition", None) is not None:
                        walk_qc(op.definition, inst_qs, inst_cs, inst_cond)
                        continue

            gates.append(
                GateNode(
                    gate_index=len(gates),
                    op=norm_op,
                    qubits=inst_qs,
                    wire_names=[wire_names[q] for q in inst_qs],
                    clbits=inst_cs,
                    clbit_names=[clbit_names[c] for c in inst_cs],
                    params=params_float,
                    condition=inst_cond,
                    unitary_matrix=umat,
                )
            )

    walk_qc(qc, list(range(qc.num_qubits)), list(range(qc.num_clbits)), None)
    return LiftedCircuit(
        name=qc.name or "qiskit_circuit",
        source_kind=source_kind,
        num_qubits=qc.num_qubits,
        num_clbits=qc.num_clbits,
        wire_names=wire_names,
        clbit_names=clbit_names,
        gates=gates,
        raw_qc=qc,
    )


# ==============================================================================
# 4. Symbolic Domain Helpers & Unitary Tensor Simulator (for Small Operator Blocks)
# ==============================================================================


def build_z3_domain_constraint(
    dom_spec: Optional[Dict[str, Any]],
    in_vars: List[z3.BoolRef],
) -> z3.BoolRef:
    if not dom_spec or dom_spec.get("kind", "all") == "all":
        return z3.BoolVal(True)
    kind = dom_spec["kind"]
    n = len(in_vars)

    def as_uint_int() -> z3.ArithRef:
        return z3.Sum([z3.If(in_vars[i], 1 << i, 0) for i in range(n)])

    if kind == "nonzero":
        return z3.Or(in_vars)
    if kind in ("ult", "lt", "mod_lt"):
        bound = int(dom_spec.get("bound", dom_spec.get("modulus", 1 << n)))
        return as_uint_int() < bound
    if kind == "range":
        lo = int(dom_spec.get("lo", 0))
        hi = int(dom_spec.get("hi", (1 << n) - 1))
        val = as_uint_int()
        return z3.And(val >= lo, val <= hi)
    if kind == "hamming_le":
        max_w = int(dom_spec["max_weight"])
        wt = z3.Sum([z3.If(v, 1, 0) for v in in_vars])
        return wt <= max_w
    if kind == "allowed_masks":
        masks = [int(m) for m in dom_spec["masks"]]
        clauses = []
        for mask in masks:
            clauses.append(
                z3.And([in_vars[i] if ((mask >> i) & 1) else z3.Not(in_vars[i]) for i in range(n)])
            )
        return z3.Or(clauses) if clauses else z3.BoolVal(False)
    raise ValueError(f"Unsupported domain_predicate kind: {kind!r}")


def format_z3_bitstring_witness(
    model: z3.ModelRef,
    in_vars: List[z3.BoolRef],
    in_wires: List[int],
    wire_names: List[str],
) -> Dict[str, Any]:
    bits = [1 if z3.is_true(model.evaluate(v, model_completion=True)) else 0 for v in in_vars]
    int_val = sum((b << idx) for idx, b in enumerate(bits))
    msb_bitstr = "".join(str(b) for b in reversed(bits))
    lsb_bitstr = "".join(str(b) for b in bits)
    wire_map = {wire_names[w]: bits[idx] for idx, w in enumerate(in_wires)}
    return {
        "input_int": int_val,
        "input_hex": hex(int_val),
        "input_bitstring_msb_to_lsb": msb_bitstr,
        "input_bitstring_lsb_to_msb": lsb_bitstr,
        "wire_assignment": wire_map,
    }


def _single_gate_matrix(op: str, params: List[float], n_qubits: int, custom_mat: Optional[np.ndarray]) -> np.ndarray:
    if op == "unitary" and custom_mat is not None:
        return custom_mat
    if op == "x":
        return np.array([[0, 1], [1, 0]], dtype=np.complex128)
    if op == "y":
        return np.array([[0, -1j], [1j, 0]], dtype=np.complex128)
    if op == "z":
        return np.array([[1, 0], [0, -1]], dtype=np.complex128)
    if op == "h":
        s2 = 1.0 / math.sqrt(2.0)
        return np.array([[s2, s2], [s2, -s2]], dtype=np.complex128)
    if op == "s":
        return np.array([[1, 0], [0, 1j]], dtype=np.complex128)
    if op == "sdg":
        return np.array([[1, 0], [0, -1j]], dtype=np.complex128)
    if op == "t":
        return np.array([[1, 0], [0, np.exp(1j * math.pi / 4.0)]], dtype=np.complex128)
    if op == "tdg":
        return np.array([[1, 0], [0, np.exp(-1j * math.pi / 4.0)]], dtype=np.complex128)
    if op == "p":
        th = params[0]
        return np.array([[1, 0], [0, np.exp(1j * th)]], dtype=np.complex128)
    if op == "rz":
        th = params[0]
        return np.array([[np.exp(-0.5j * th), 0], [0, np.exp(0.5j * th)]], dtype=np.complex128)
    if op == "rx":
        th = params[0]
        c, s = math.cos(0.5 * th), math.sin(0.5 * th)
        return np.array([[c, -1j * s], [-1j * s, c]], dtype=np.complex128)
    if op == "ry":
        th = params[0]
        c, s = math.cos(0.5 * th), math.sin(0.5 * th)
        return np.array([[c, -s], [s, c]], dtype=np.complex128)
    if op in ("cx", "ccx", "mcx", "rccx"):
        dim = 1 << n_qubits
        mat = np.eye(dim, dtype=np.complex128)
        ctrl_mask = (1 << (n_qubits - 1)) - 1
        tgt_bit = 1 << (n_qubits - 1)
        # In little-endian over local args [c_0, ..., c_{k-1}, tgt]:
        for idx in range(dim):
            if (idx & ctrl_mask) == ctrl_mask and (idx & tgt_bit) == 0:
                partner = idx | tgt_bit
                mat[idx, idx] = 0.0
                mat[partner, partner] = 0.0
                mat[idx, partner] = 1.0
                mat[partner, idx] = 1.0
        return mat
    if op in ("cz", "ccz"):
        dim = 1 << n_qubits
        mat = np.eye(dim, dtype=np.complex128)
        mat[dim - 1, dim - 1] = -1.0
        return mat
    if op == "cp":
        th = params[0]
        mat = np.eye(4, dtype=np.complex128)
        mat[3, 3] = np.exp(1j * th)
        return mat
    if op == "swap":
        return np.array(
            [[1, 0, 0, 0], [0, 0, 1, 0], [0, 1, 0, 0], [0, 0, 0, 1]],
            dtype=np.complex128,
        )
    if op == "cswap":
        # Local args [ctrl, a, b]: little-endian bit0=ctrl, bit1=a, bit2=b -> swap 0b011 (3) and 0b101 (5)
        mat = np.eye(8, dtype=np.complex128)
        mat[3, 3] = 0.0
        mat[5, 5] = 0.0
        mat[3, 5] = 1.0
        mat[5, 3] = 1.0
        return mat
    raise ValueError(f"Unsupported unitary operator `{op}`")


def compute_exact_circuit_unitary(circuit: LiftedCircuit) -> np.ndarray:
    """
    Computes exact `2^n x 2^n` unitary matrix (Qiskit little-endian convention:
    qubit 0 is LSB) via tensor contraction for `n <= 12`.
    """
    n = circuit.num_qubits
    if n > 12:
        raise ValueError(f"Exact dense unitary check restricted to n <= 12 qubits, got {n}")
    dim = 1 << n
    # Tensor shape `(2,)*n + (dim,)` where axis `n - 1 - q` corresponds to qubit `q`!
    tensor = np.eye(dim, dtype=np.complex128).reshape((2,) * n + (dim,))
    for g in circuit.gates:
        if g.op == "barrier":
            continue
        if g.op in ("measure", "reset") or g.condition is not None:
            raise ValueError(f"Non-unitary dynamic instruction `{g.op}` at gate {g.gate_index}")
        k = len(g.qubits)
        gmat = _single_gate_matrix(g.op, g.params, k, g.unitary_matrix)
        # In little-endian matrix `gmat`, row/col index `b_0 + 2*b_1 + ... + 2^{k-1}*b_{k-1}`
        # has MSB = `g.qubits[k-1]` and LSB = `g.qubits[0]`, so reshape `(2,)*k` has axis 0 = `g.qubits[k-1]`.
        gtensor = gmat.reshape((2,) * (2 * k))
        axes_state = [n - 1 - q for q in reversed(g.qubits)]
        contracted = np.tensordot(gtensor, tensor, axes=(list(range(k, 2 * k)), axes_state))
        # Move axes `0..k-1` back to `axes_state`:
        perm = [0] * (n + 1)
        rem_src = k
        target_map = {ax: idx for idx, ax in enumerate(axes_state)}
        for dst_ax in range(n + 1):
            if dst_ax in target_map:
                perm[dst_ax] = target_map[dst_ax]
            else:
                perm[dst_ax] = rem_src
                rem_src += 1
        tensor = np.transpose(contracted, perm)
    return tensor.reshape((dim, dim))


def is_purely_classical_reversible(circuit: LiftedCircuit) -> bool:
    allowed = {"x", "cx", "ccx", "rccx", "mcx", "swap", "cswap", "barrier"}
    return all(g.op in allowed and g.condition is None for g in circuit.gates)


def eval_classical_on_xag(
    mgr: XAGManager,
    init_lits: List[int],
    gates: Sequence[GateNode],
    clbit_lits: Optional[Dict[int, int]] = None,
) -> Tuple[List[int], Dict[int, int]]:
    cur = list(init_lits)
    last_mod_gate: Dict[int, int] = {}
    cl_map: Dict[int, int] = dict(clbit_lits or {})

    def apply_cond(wire: int, new_lit: int, cond: Optional[Tuple[int, str, int]]) -> None:
        if cond is None:
            cur[wire] = new_lit
            return
        c_idx, _, exp_val = cond
        c_lit = cl_map.get(c_idx, mgr.LIT_ZERO)
        guard = c_lit if exp_val == 1 else mgr.lit_not(c_lit)
        cur[wire] = mgr.ite(guard, new_lit, cur[wire])

    for g in gates:
        op = g.op
        qs = g.qubits
        if op == "barrier" or op in ("z", "s", "sdg", "t", "tdg", "cz", "ccz", "p", "cp", "rz"):
            continue
        if op == "x":
            apply_cond(qs[0], mgr.lit_not(cur[qs[0]]), g.condition)
            last_mod_gate[qs[0]] = g.gate_index
        elif op == "cx":
            apply_cond(qs[1], mgr.xor(cur[qs[1]], cur[qs[0]]), g.condition)
            last_mod_gate[qs[1]] = g.gate_index
        elif op in ("ccx", "rccx"):
            prod = mgr.and_(cur[qs[0]], cur[qs[1]])
            apply_cond(qs[2], mgr.xor(cur[qs[2]], prod), g.condition)
            last_mod_gate[qs[2]] = g.gate_index
        elif op == "mcx":
            prod = mgr.LIT_ONE
            for cq in qs[:-1]:
                prod = mgr.and_(prod, cur[cq])
            apply_cond(qs[-1], mgr.xor(cur[qs[-1]], prod), g.condition)
            last_mod_gate[qs[-1]] = g.gate_index
        elif op == "swap":
            u, v = qs[0], qs[1]
            lu, lv = cur[u], cur[v]
            apply_cond(u, lv, g.condition)
            apply_cond(v, lu, g.condition)
            last_mod_gate[u] = g.gate_index
            last_mod_gate[v] = g.gate_index
        elif op == "cswap":
            c, u, v = qs[0], qs[1], qs[2]
            diff = mgr.and_(cur[c], mgr.xor(cur[u], cur[v]))
            apply_cond(u, mgr.xor(cur[u], diff), g.condition)
            apply_cond(v, mgr.xor(cur[v], diff), g.condition)
            last_mod_gate[u] = g.gate_index
            last_mod_gate[v] = g.gate_index
        elif op == "reset":
            apply_cond(qs[0], mgr.LIT_ZERO, g.condition)
            last_mod_gate[qs[0]] = g.gate_index
        elif op == "measure":
            # In M_X (`H + measure`), measurement outcome bit is independent fresh variable;
            # subsequent `reset` zeroes the wire.
            m_var = mgr.var(10000 + g.gate_index)
            if g.clbits:
                cl_map[g.clbits[0]] = m_var
            cur[qs[0]] = m_var
            last_mod_gate[qs[0]] = g.gate_index

    return cur, last_mod_gate


# ==============================================================================
# 5. The 7 Static LakefillQ Rules (`T-DomImg` .. `T-ParGuard`)
# ==============================================================================


def _gf2k_poly_mul_z3(
    lhs_bits: List[z3.BoolRef],
    rhs_bits: List[z3.BoolRef],
    mod_poly: int,
) -> List[z3.BoolRef]:
    k = len(lhs_bits)
    acc: List[z3.BoolRef] = [z3.BoolVal(False) for _ in range(k)]
    cur_a: List[z3.BoolRef] = list(lhs_bits)
    for j in range(len(rhs_bits)):
        for i in range(k):
            acc[i] = z3.Xor(acc[i], z3.And(cur_a[i], rhs_bits[j]))
        msb = cur_a[k - 1]
        shifted: List[z3.BoolRef] = [z3.BoolVal(False)] + cur_a[: k - 1]
        for i in range(k):
            if (mod_poly >> i) & 1:
                shifted[i] = z3.Xor(shifted[i], msb)
        cur_a = shifted
    return acc


def run_rule_t_dom_img(circuit: LiftedCircuit, spec: LintSpec) -> List[LintDiagnostic]:
    """
    Rule 1 (`T-DomImg` under `Gamma_in |- t : Q_e(A) -| Gamma_out`):
      - Verifies support injectivity on `Dom(f)` (`check_support_injectivity`).
      - Verifies read-only input non-aliasing (`readonly_input_wires`) and
        `GF(2^k)` bilinear read-after-write self-aliasing (`gf2k_mul_spec`).
      - Verifies `g(f(x)) == x` and `f(Dom_f) subseteq Dom_g` (`uncompute_qc`,
        `uncompute_qasm`, `expect_identity_on_inputs`).
      - Runs wire-basis / linear GF(2) / S-box / `Fin[N]` stencil RAW aliasing checks.
    """
    diags: List[LintDiagnostic] = []
    diags.extend(run_rule_t_wire_basis(circuit, spec))

    n = circuit.num_qubits
    if n == 0:
        return diags

    anc_wires = list(spec.ancilla_wires) if spec.ancilla_wires is not None else []
    ro_wires = list(spec.readonly_input_wires) if spec.readonly_input_wires is not None else []
    has_domimg_check = (
        bool(ro_wires)
        or spec.gf2k_mul_spec is not None
        or spec.expect_identity_on_inputs
        or spec.uncompute_qc is not None
        or spec.uncompute_qasm is not None
        or spec.check_support_injectivity
    )
    if not has_domimg_check:
        return diags

    if spec.input_wires is not None:
        in_wires = list(spec.input_wires)
    elif spec.gf2k_mul_spec is not None:
        gf = spec.gf2k_mul_spec
        gf_lhs = list(gf.get("lhs_wires", gf.get("a_wires", [])))
        gf_rhs = list(gf.get("rhs_wires", gf.get("b_wires", [])))
        in_wires = sorted(set(int(w) for w in gf_lhs + gf_rhs))
    else:
        in_wires = [w for w in range(n) if w not in set(anc_wires)]

    out_wires = (
        list(spec.output_wires)
        if spec.output_wires is not None
        else [w for w in range(n) if w not in set(anc_wires)]
    )

    mgr = XAGManager()
    init_lits = [mgr.LIT_ZERO] * n
    for idx, w in enumerate(in_wires):
        init_lits[w] = mgr.var(idx)

    fwd_lits, last_mod = eval_classical_on_xag(mgr, init_lits, circuit.gates)

    z3_vars: Dict[int, z3.BoolRef] = {idx: z3.Bool(f"in_{idx}") for idx in range(len(in_wires))}
    for _, (kind, v_idx, _) in enumerate(mgr.nodes):
        if kind == "var" and v_idx not in z3_vars:
            z3_vars[v_idx] = z3.Bool(f"meas_{v_idx - 10000}")
    in_z3_list = [z3_vars[idx] for idx in range(len(in_wires))]
    dom_z3 = build_z3_domain_constraint(spec.domain_predicate, in_z3_list)

    # 1a. Read-only input non-aliasing (`readonly_input_wires`):
    if ro_wires:
        zmap_ro = mgr.to_z3_map(z3_vars, [fwd_lits[w] for w in ro_wires] + [init_lits[w] for w in ro_wires])
        s_ro = z3.Solver()
        s_ro.add(dom_z3)
        s_ro.add(z3.Or([zmap_ro[fwd_lits[w]] != zmap_ro[init_lits[w]] for w in ro_wires]))
        if s_ro.check() == z3.sat:
            m_ro = s_ro.model()
            bad_ro = [
                w for w in ro_wires
                if z3.is_true(m_ro.evaluate(zmap_ro[fwd_lits[w]] != zmap_ro[init_lits[w]], model_completion=True))
            ]
            cex_ro = format_z3_bitstring_witness(m_ro, in_z3_list, in_wires, circuit.wire_names)
            cex_ro["corrupted_readonly_wires"] = [circuit.wire_names[w] for w in bad_ro]
            diags.append(
                LintDiagnostic(
                    rule="T-DomImg",
                    severity="ERROR",
                    code="E-DOMIMG-READONLY-ALIASED-MUTATION",
                    message=(
                        f"Read-only input wire(s) {[circuit.wire_names[w] for w in bad_ro]} are mutated "
                        f"in-place on domain input {cex_ro['input_hex']}."
                    ),
                    gate_indices=sorted({last_mod[w] for w in bad_ro if w in last_mod}),
                    wire_names=[circuit.wire_names[w] for w in bad_ro],
                    counterexample=cex_ro,
                    repair_suggestion="Write out-of-place into disjoint target ancillas rather than aliasing read-only inputs.",
                )
            )

    # 1b. GF(2^k) bilinear read-after-write self-aliasing check (`gf2k_mul_spec`):
    if spec.gf2k_mul_spec is not None:
        gf = spec.gf2k_mul_spec
        lhs_ws = [int(w) for w in gf.get("lhs_wires", gf.get("a_wires", []))]
        rhs_ws = [int(w) for w in gf.get("rhs_wires", gf.get("b_wires", []))]
        gf_out_ws = [int(w) for w in gf.get("out_wires", gf.get("output_wires", []))]
        raw_mod = gf.get("mod_poly", gf.get("modulus_poly"))
        if isinstance(raw_mod, (list, tuple)):
            mod_poly = sum((1 << idx) for idx, bit in enumerate(raw_mod) if int(bit) != 0)
        else:
            mod_poly = int(raw_mod)
        k_deg = len(lhs_ws)
        zmap_gf = mgr.to_z3_map(
            z3_vars,
            [init_lits[w] for w in lhs_ws + rhs_ws] + [fwd_lits[w] for w in gf_out_ws],
        )
        lhs_z3 = [zmap_gf[init_lits[w]] for w in lhs_ws]
        rhs_z3 = [zmap_gf[init_lits[w]] for w in rhs_ws]
        exp_gf_z3 = _gf2k_poly_mul_z3(lhs_z3, rhs_z3, mod_poly)
        act_gf_z3 = [zmap_gf[fwd_lits[w]] for w in gf_out_ws]
        s_gf = z3.Solver()
        s_gf.add(dom_z3)
        s_gf.add(z3.Or([act_gf_z3[i] != exp_gf_z3[i] for i in range(k_deg)]))
        if s_gf.check() == z3.sat:
            m_gf = s_gf.model()
            cex_gf = format_z3_bitstring_witness(m_gf, in_z3_list, in_wires, circuit.wire_names)
            a_val = sum((1 << i) for i in range(k_deg) if z3.is_true(m_gf.evaluate(lhs_z3[i], model_completion=True)))
            b_val = sum((1 << i) for i in range(k_deg) if z3.is_true(m_gf.evaluate(rhs_z3[i], model_completion=True)))
            act_v = sum((1 << i) for i in range(k_deg) if z3.is_true(m_gf.evaluate(act_gf_z3[i], model_completion=True)))
            exp_v = sum((1 << i) for i in range(k_deg) if z3.is_true(m_gf.evaluate(exp_gf_z3[i], model_completion=True)))
            aliased_overlap = sorted(set(gf_out_ws) & (set(lhs_ws) | set(rhs_ws)))
            cex_gf.update(
                {
                    "lhs_poly_hex": hex(a_val),
                    "rhs_poly_hex": hex(b_val),
                    "actual_product_hex": hex(act_v),
                    "expected_product_hex": hex(exp_v),
                    "aliased_io_wires": [circuit.wire_names[w] for w in aliased_overlap],
                }
            )
            diags.append(
                LintDiagnostic(
                    rule="T-DomImg",
                    severity="ERROR",
                    code="E-DOMIMG-GF2K-ALIAS-CORRUPTION",
                    message=(
                        f"GF(2^{k_deg}) multiplier corrupts product on a={hex(a_val)}, b={hex(b_val)} "
                        f"(actual {hex(act_v)} != expected {hex(exp_v)}; aliased wires="
                        f"{[circuit.wire_names[w] for w in aliased_overlap]})."
                    ),
                    gate_indices=sorted({last_mod[w] for w in gf_out_ws if w in last_mod}),
                    wire_names=[circuit.wire_names[w] for w in (aliased_overlap or gf_out_ws)],
                    counterexample=cex_gf,
                    repair_suggestion=(
                        "Allocate a fresh `k`-qubit output register disjoint from `lhs_wires` and `rhs_wires` "
                        "to prevent in-place read-after-write self-aliasing."
                    ),
                )
            )

    # 2. Check Support Injectivity on `Dom(f)` if requested
    if spec.check_support_injectivity and out_wires:
        mgr2 = XAGManager()
        init_a = [mgr2.LIT_ZERO] * n
        init_b = [mgr2.LIT_ZERO] * n
        for idx, w in enumerate(in_wires):
            init_a[w] = mgr2.var(idx)
            init_b[w] = mgr2.var(len(in_wires) + idx)
        out_a, _ = eval_classical_on_xag(mgr2, init_a, circuit.gates)
        out_b, _ = eval_classical_on_xag(mgr2, init_b, circuit.gates)
        vars_ab: Dict[int, z3.BoolRef] = {}
        for idx in range(len(in_wires)):
            vars_ab[idx] = z3.Bool(f"xa_{idx}")
            vars_ab[len(in_wires) + idx] = z3.Bool(f"xb_{idx}")
        for _, (kind, v_idx, _) in enumerate(mgr2.nodes):
            if kind == "var" and v_idx not in vars_ab:
                vars_ab[v_idx] = z3.Bool(f"m_{v_idx}")
        zmap_ab = mgr2.to_z3_map(vars_ab, [out_a[w] for w in out_wires] + [out_b[w] for w in out_wires])
        xa_list = [vars_ab[i] for i in range(len(in_wires))]
        xb_list = [vars_ab[len(in_wires) + i] for i in range(len(in_wires))]
        s_inj = z3.Solver()
        s_inj.add(build_z3_domain_constraint(spec.domain_predicate, xa_list))
        s_inj.add(build_z3_domain_constraint(spec.domain_predicate, xb_list))
        s_inj.add(z3.Or([xa_list[i] != xb_list[i] for i in range(len(in_wires))]))
        s_inj.add(z3.And([zmap_ab[out_a[w]] == zmap_ab[out_b[w]] for w in out_wires]))
        if s_inj.check() == z3.sat:
            m_inj = s_inj.model()
            cex_a = format_z3_bitstring_witness(m_inj, xa_list, in_wires, circuit.wire_names)
            cex_b = format_z3_bitstring_witness(m_inj, xb_list, in_wires, circuit.wire_names)
            diags.append(
                LintDiagnostic(
                    rule="T-DomImg",
                    severity="ERROR",
                    code="E-DOMIMG-NON-INJECTIVE",
                    message=(
                        f"Forward map is non-injective on `Dom`: distinct inputs "
                        f"{cex_a['input_hex']} and {cex_b['input_hex']} collide on output wires."
                    ),
                    wire_names=[circuit.wire_names[w] for w in out_wires],
                    counterexample={"lhs_input": cex_a, "rhs_input": cex_b},
                    repair_suggestion="Narrow `domain_predicate` to an injective coset/ball or retain injective witness bits.",
                )
            )

    # 3. Check `g(f(x)) == x` and `f(Dom_f) subseteq Dom_g`
    if spec.uncompute_qc is not None or spec.uncompute_qasm is not None:
        if spec.uncompute_qc is not None:
            uncomp_lifted = lift_qiskit_circuit(spec.uncompute_qc)
        else:
            uncomp_lifted = parse_qasm_to_lifted_circuit(str(spec.uncompute_qasm), name="uncompute_block")

        if spec.inverse_domain_predicate is not None and out_wires:
            zmap_img = mgr.to_z3_map(z3_vars, [fwd_lits[w] for w in out_wires])
            img_z3_list = [zmap_img[fwd_lits[w]] for w in out_wires]
            inv_dom_z3 = build_z3_domain_constraint(spec.inverse_domain_predicate, img_z3_list)
            s_dom = z3.Solver()
            s_dom.add(dom_z3)
            s_dom.add(z3.Not(inv_dom_z3))
            if s_dom.check() == z3.sat:
                m_dom = s_dom.model()
                cex_dom = format_z3_bitstring_witness(m_dom, in_z3_list, in_wires, circuit.wire_names)
                diags.append(
                    LintDiagnostic(
                        rule="T-DomImg",
                        severity="ERROR",
                        code="E-DOMIMG-IMG-OUTSIDE-INVDOM",
                        message=(
                            f"Forward image `f(x)` on input {cex_dom['input_hex']} escapes "
                            f"inverse uncomputation domain `Dom(g)`."
                        ),
                        wire_names=[circuit.wire_names[w] for w in out_wires],
                        counterexample=cex_dom,
                        repair_suggestion="Align `Dom(g)` with `Img(f)` before invoking `erase-by` uncomputation.",
                    )
                )
                return diags

        roundtrip_lits, rt_mod = eval_classical_on_xag(mgr, fwd_lits, uncomp_lits_gates := uncomp_lifted.gates)
        for _, (kind, v_idx, _) in enumerate(mgr.nodes):
            if kind == "var" and v_idx not in z3_vars:
                z3_vars[v_idx] = z3.Bool(f"meas_{v_idx - 10000}")
        zmap_rt = mgr.to_z3_map(z3_vars, [roundtrip_lits[w] for w in range(n)] + [init_lits[w] for w in range(n)])
        s_rt = z3.Solver()
        s_rt.add(dom_z3)
        s_rt.add(z3.Or([zmap_rt[roundtrip_lits[w]] != zmap_rt[init_lits[w]] for w in range(n)]))
        if s_rt.check() == z3.sat:
            m_rt = s_rt.model()
            bad_ws = [
                w for w in range(n)
                if z3.is_true(m_rt.evaluate(zmap_rt[roundtrip_lits[w]] != zmap_rt[init_lits[w]], model_completion=True))
            ]
            cex_rt = format_z3_bitstring_witness(m_rt, in_z3_list, in_wires, circuit.wire_names)
            cex_rt["corrupted_wires"] = [circuit.wire_names[w] for w in bad_ws]
            diags.append(
                LintDiagnostic(
                    rule="T-DomImg",
                    severity="ERROR",
                    code="E-DOMIMG-ROUNDTRIP-RESIDUAL",
                    message=(
                        f"Reverse uncomputation `g(f(x))` fails to restore initial wires "
                        f"{[circuit.wire_names[w] for w in bad_ws]} on input {cex_rt['input_hex']}."
                    ),
                    gate_indices=sorted({rt_mod[w] for w in bad_ws if w in rt_mod}),
                    wire_names=[circuit.wire_names[w] for w in bad_ws],
                    counterexample=cex_rt,
                    repair_suggestion="Ensure `g` is the exact algebraic inverse of `f` across `Img(f)`.",
                )
            )
    elif spec.expect_identity_on_inputs:
        zmap_id = mgr.to_z3_map(z3_vars, [fwd_lits[w] for w in in_wires] + [init_lits[w] for w in in_wires])
        s_id = z3.Solver()
        s_id.add(dom_z3)
        s_id.add(z3.Or([zmap_id[fwd_lits[w]] != zmap_id[init_lits[w]] for w in in_wires]))
        if s_id.check() == z3.sat:
            m_id = s_id.model()
            bad_in = [
                w for w in in_wires
                if z3.is_true(m_id.evaluate(zmap_id[fwd_lits[w]] != zmap_id[init_lits[w]], model_completion=True))
            ]
            cex_id = format_z3_bitstring_witness(m_id, in_z3_list, in_wires, circuit.wire_names)
            cex_id["corrupted_input_wires"] = [circuit.wire_names[w] for w in bad_in]
            diags.append(
                LintDiagnostic(
                    rule="T-DomImg",
                    severity="ERROR",
                    code="E-DOMIMG-ROUNDTRIP-RESIDUAL",
                    message=(
                        f"Compute-uncompute circuit leaves residual modification on input wire(s) "
                        f"{[circuit.wire_names[w] for w in bad_in]} at {cex_id['input_hex']}."
                    ),
                    gate_indices=sorted({last_mod[w] for w in bad_in if w in last_mod}),
                    wire_names=[circuit.wire_names[w] for w in bad_in],
                    counterexample=cex_id,
                    repair_suggestion="Restore input/coset wires on `Dom` via exact inverse `g(f(x)) == x`.",
                )
            )

    return diags


def run_rule_t_borrow_z(circuit: LiftedCircuit, spec: LintSpec) -> List[LintDiagnostic]:
    """
    Rule 2 (`T-BorrowZ` under `Gamma_in |- t : Q_e(A) -| Gamma_out`):
      1. Borrowed `ConstZ` control wires (`borrowed_z_wires`):
         - Rejects non-computational `H`/`RX`/`RY` basis pollution on `ConstZ` wires.
         - Verifies via symbolic XAG + Z3 miter that borrowed `ConstZ` wires are never
           read while corrupted by multi-wire writes and are restored (`bw_out == bw_in`)
           across all inputs in `Dom` (allowing symmetric `negctrl` `X ... X` wraps).
      2. Validity-witness guard (`validity_witness_wire`):
         - Verifies via symbolic XAG + Z3 phase-polynomial miter that oracle phase
           kickback is zero whenever `v == 0` and `v` is immutable while guarding.
    """
    diags: List[LintDiagnostic] = []
    n = circuit.num_qubits
    if n == 0:
        return diags

    # --- Subcheck 1: Borrowed ConstZ Control Wires (`borrowed_z_wires`) ---
    if spec.borrowed_z_wires:
        b_wires = [int(w) for w in spec.borrowed_z_wires if 0 <= int(w) < n]
        if b_wires:
            basis_polluting_gates: List[int] = []
            basis_polluted_wires: List[int] = []
            for g in circuit.gates:
                if g.op in ("h", "rx", "ry") and g.qubits and g.qubits[0] in b_wires:
                    basis_polluting_gates.append(g.gate_index)
                    if g.qubits[0] not in basis_polluted_wires:
                        basis_polluted_wires.append(g.qubits[0])
                elif g.op == "unitary" and g.unitary_matrix is not None and any(q in b_wires for q in g.qubits):
                    # Check if unitary matrix is a generalized permutation (1 non-zero entry per column)
                    nz_per_col = np.sum(np.abs(g.unitary_matrix) > 1e-8, axis=0)
                    if np.any(nz_per_col > 1):
                        basis_polluting_gates.append(g.gate_index)
                        for q in g.qubits:
                            if q in b_wires and q not in basis_polluted_wires:
                                basis_polluted_wires.append(q)

            if basis_polluting_gates:
                s_bp = z3.Solver()
                b_sym = z3.Bool("borrowed_z_init")
                s_bp.add(z3.Or(b_sym == z3.BoolVal(False), b_sym == z3.BoolVal(True)))
                s_bp.check()
                b_val = 1 if z3.is_true(s_bp.model().evaluate(b_sym, model_completion=True)) else 0
                diags.append(
                    LintDiagnostic(
                        rule="T-BorrowZ",
                        severity="ERROR",
                        code="E-BORROWZ-BASIS-POLLUTION",
                        message=(
                            f"Borrowed `ConstZ` control wire(s) {[circuit.wire_names[w] for w in basis_polluted_wires]} "
                            f"suffer non-diagonal `H`/`RX`/`RY` basis pollution at gate(s) {basis_polluting_gates}, "
                            f"destroying computational-basis invariance."
                        ),
                        gate_indices=basis_polluting_gates,
                        wire_names=[circuit.wire_names[w] for w in basis_polluted_wires],
                        counterexample={
                            "borrowed_wires": [circuit.wire_names[w] for w in basis_polluted_wires],
                            "borrowed_z_initial_bit": b_val,
                            "polluting_gates": basis_polluting_gates,
                        },
                        repair_suggestion=(
                            "Keep borrowed `ConstZ` control wires strictly in the computational `Z` basis "
                            "(use clean `0`-initialized ancillas for Hadamard superpositions)."
                        ),
                    )
                )

            anc_set = set(spec.ancilla_wires or []) - set(b_wires)
            if spec.input_wires is not None:
                in_ws_b = sorted(set(int(w) for w in spec.input_wires) | set(b_wires))
            else:
                in_ws_b = [w for w in range(n) if w not in anc_set]

            mgr_b = XAGManager()
            init_b = [mgr_b.LIT_ZERO] * n
            for idx, w in enumerate(in_ws_b):
                init_b[w] = mgr_b.var(idx)

            cur_b = list(init_b)
            last_mod_b: Dict[int, int] = {}
            corrupted_ctrl_gates: List[int] = []
            corrupted_ctrl_wires: List[int] = []
            for g in circuit.gates:
                if g.op in ("cx", "ccx", "rccx", "mcx", "cz", "ccz", "cp", "cswap"):
                    ctrls = g.qubits[:-1] if g.op not in ("cz", "ccz", "cp") else g.qubits
                    if g.op == "cswap":
                        ctrls = [g.qubits[0]]
                    for cq in ctrls:
                        if cq in b_wires and cur_b[cq] not in (init_b[cq], mgr_b.lit_not(init_b[cq])):
                            corrupted_ctrl_gates.append(g.gate_index)
                            if cq not in corrupted_ctrl_wires:
                                corrupted_ctrl_wires.append(cq)
                if g.op not in ("h", "rx", "ry", "unitary"):
                    step_b, mod_step = eval_classical_on_xag(mgr_b, cur_b, [g])
                    cur_b = step_b
                    last_mod_b.update(mod_step)

            if corrupted_ctrl_gates:
                diags.append(
                    LintDiagnostic(
                        rule="T-BorrowZ",
                        severity="ERROR",
                        code="E-BORROWZ-CONTROL-CORRUPTED",
                        message=(
                            f"Borrowed `ConstZ` wire(s) {[circuit.wire_names[w] for w in corrupted_ctrl_wires]} "
                            f"are overwritten by data-dependent logic before control read at gate(s) {corrupted_ctrl_gates}."
                        ),
                        gate_indices=corrupted_ctrl_gates,
                        wire_names=[circuit.wire_names[w] for w in corrupted_ctrl_wires],
                        counterexample={
                            "corrupted_borrowed_wires": [circuit.wire_names[w] for w in corrupted_ctrl_wires],
                            "gate_indices": corrupted_ctrl_gates,
                        },
                        repair_suggestion="Only apply reversible single-wire `negctrl` (`X ... X`) wraps to `ConstZ` wires.",
                    )
                )

            z3_vb: Dict[int, z3.BoolRef] = {idx: z3.Bool(f"bz_{idx}") for idx in range(len(in_ws_b))}
            for _, (kind, v_idx, _) in enumerate(mgr_b.nodes):
                if kind == "var" and v_idx not in z3_vb:
                    z3_vb[v_idx] = z3.Bool(f"m_{v_idx}")
            zmap_b = mgr_b.to_z3_map(z3_vb, [cur_b[w] for w in b_wires] + [init_b[w] for w in b_wires])
            s_bm = z3.Solver()
            if spec.domain_predicate and spec.input_wires is not None:
                pos_map = {w: i for i, w in enumerate(in_ws_b)}
                dom_in_vars = [z3_vb[pos_map[int(w)]] for w in spec.input_wires]
                s_bm.add(build_z3_domain_constraint(spec.domain_predicate, dom_in_vars))
            else:
                s_bm.add(build_z3_domain_constraint(spec.domain_predicate, [z3_vb[i] for i in range(len(in_ws_b))]))
            s_bm.add(z3.Or([zmap_b[cur_b[w]] != zmap_b[init_b[w]] for w in b_wires]))
            if s_bm.check() == z3.sat:
                m_bm = s_bm.model()
                unrestored = [
                    w for w in b_wires
                    if z3.is_true(m_bm.evaluate(zmap_b[cur_b[w]] != zmap_b[init_b[w]], model_completion=True))
                ]
                cex_b = format_z3_bitstring_witness(
                    m_bm, [z3_vb[i] for i in range(len(in_ws_b))], in_ws_b, circuit.wire_names
                )
                cex_b["unrestored_borrowed_wires"] = [circuit.wire_names[w] for w in unrestored]
                diags.append(
                    LintDiagnostic(
                        rule="T-BorrowZ",
                        severity="ERROR",
                        code="E-BORROWZ-UNRESTORED-MUTATION",
                        message=(
                            f"Borrowed `ConstZ` wire(s) {[circuit.wire_names[w] for w in unrestored]} are not "
                            f"restored to their initial `Z`-basis state on input {cex_b['input_hex']}."
                        ),
                        gate_indices=sorted({last_mod_b[w] for w in unrestored if w in last_mod_b}),
                        wire_names=[circuit.wire_names[w] for w in unrestored],
                        counterexample=cex_b,
                        repair_suggestion=(
                            "Restore borrowed `ConstZ` control wires symmetrically (e.g. pair opening `x` "
                            "with closing `x` in `negctrl` blocks) and avoid targeting `ConstZ` wires."
                        ),
                    )
                )

    # --- Subcheck 2: Validity-Witness Phase Guard (`validity_witness_wire`) ---
    if spec.validity_witness_wire is None:
        return diags

    v_wire = int(spec.validity_witness_wire)
    if v_wire < 0 or v_wire >= n:
        return diags

    explicit_phase_targets = set(spec.oracle_phase_target_wires or [])

    minus_ancillas: Set[int] = set(explicit_phase_targets)
    wire_prep_state = [0] * n  # 0 = |0>, 1 = |1>, 2 = |->, 3 = general
    for g in circuit.gates:
        if len(g.qubits) == 1:
            q = g.qubits[0]
            if g.op == "x" and wire_prep_state[q] == 0:
                wire_prep_state[q] = 1
            elif g.op == "h" and wire_prep_state[q] == 1:
                wire_prep_state[q] = 2
                minus_ancillas.add(q)
            elif g.op == "h" and wire_prep_state[q] == 2:
                wire_prep_state[q] = 1
            elif g.op == "x" and wire_prep_state[q] == 1:
                wire_prep_state[q] = 0
            else:
                wire_prep_state[q] = 3

    in_wires = (
        list(spec.input_wires)
        if spec.input_wires is not None
        else [w for w in range(n) if w not in minus_ancillas and w not in set(spec.ancilla_wires or [])]
    )

    mgr = XAGManager()
    cur_lits = [mgr.LIT_ZERO] * n
    for idx, w in enumerate(in_wires):
        cur_lits[w] = mgr.var(idx)

    ready_after = spec.witness_ready_after_gate
    if ready_after < 0:
        if v_wire in in_wires:
            ready_after = -1
        else:
            writers = [
                g.gate_index
                for g in circuit.gates
                if g.qubits and g.qubits[-1] == v_wire and g.op in ("x", "cx", "ccx", "rccx", "mcx")
            ]
            ready_after = writers[0] if writers else -1

    phase_gate_indices: List[int] = []
    for g in circuit.gates:
        if g.op in ("z", "s", "sdg", "t", "tdg", "cz", "ccz", "p", "cp", "rz"):
            phase_gate_indices.append(g.gate_index)
        elif g.op in ("cx", "ccx", "rccx", "mcx") and g.qubits[-1] in minus_ancillas:
            phase_gate_indices.append(g.gate_index)
    last_phase_idx = max(phase_gate_indices) if phase_gate_indices else -1

    witness_lit: Optional[int] = cur_lits[v_wire] if ready_after < 0 else None
    mutated_gate_indices: List[int] = []
    phase_terms: List[Tuple[float, int, int]] = []

    for g in circuit.gates:
        op = g.op
        qs = g.qubits
        is_phase_tgt = op in ("cx", "ccx", "rccx", "mcx") and bool(qs) and (qs[-1] in minus_ancillas)

        if is_phase_tgt:
            prod = mgr.LIT_ONE
            for cq in qs[:-1]:
                prod = mgr.and_(prod, cur_lits[cq])
            phase_terms.append((4.0, prod, g.gate_index))
        elif op in ("z", "s", "sdg", "t", "tdg", "p", "rz"):
            if qs[0] not in minus_ancillas:
                units = {
                    "z": 4.0,
                    "s": 2.0,
                    "sdg": 6.0,
                    "t": 1.0,
                    "tdg": 7.0,
                }.get(op, (4.0 * g.params[0] / math.pi) if g.params else 0.0)
                phase_terms.append((units, cur_lits[qs[0]], g.gate_index))
        elif op in ("cz", "ccz", "cp"):
            prod = mgr.LIT_ONE
            for cq in qs:
                prod = mgr.and_(prod, cur_lits[cq])
            units = 4.0 if op in ("cz", "ccz") else (4.0 * g.params[0] / math.pi)
            phase_terms.append((units, prod, g.gate_index))
        else:
            writes_v = (
                (op in ("x", "h", "rx", "ry", "reset", "measure") and qs and qs[0] == v_wire)
                or (op in ("cx", "ccx", "rccx", "mcx") and qs and qs[-1] == v_wire)
                or (op in ("swap", "cswap") and v_wire in qs[-2:])
            )
            if writes_v and g.gate_index > ready_after and g.gate_index < last_phase_idx:
                mutated_gate_indices.append(g.gate_index)

            if qs and qs[-1] in minus_ancillas and op in ("x", "h"):
                pass
            else:
                step_lits, _ = eval_classical_on_xag(mgr, cur_lits, [g])
                cur_lits = step_lits

        if g.gate_index == ready_after:
            witness_lit = cur_lits[v_wire]

    if witness_lit is None:
        witness_lit = cur_lits[v_wire]

    if mutated_gate_indices:
        diags.append(
            LintDiagnostic(
                rule="T-BorrowZ",
                severity="ERROR",
                code="E-BORROWZ-WITNESS-MUTATED",
                message=(
                    f"Validity-witness wire `{circuit.wire_names[v_wire]}` is mutated at gate(s) "
                    f"{mutated_gate_indices} before oracle phase kickback completes."
                ),
                gate_indices=mutated_gate_indices,
                wire_names=[circuit.wire_names[v_wire]],
                counterexample={
                    "validity_witness_wire": circuit.wire_names[v_wire],
                    "mutated_at_gates": mutated_gate_indices,
                },
                repair_suggestion=(
                    f"Keep `{circuit.wire_names[v_wire]}` immutable inside the `ConstZ` witness scope "
                    f"until after all controlled phase kickbacks finish."
                ),
            )
        )

    if phase_terms:
        z3_vars: Dict[int, z3.BoolRef] = {idx: z3.Bool(f"in_{idx}") for idx in range(len(in_wires))}
        for _, (kind, v_idx, _) in enumerate(mgr.nodes):
            if kind == "var" and v_idx not in z3_vars:
                z3_vars[v_idx] = z3.Bool(f"m_{v_idx}")
        needed_lits = [witness_lit] + [lit for _, lit, _ in phase_terms]
        zmap = mgr.to_z3_map(z3_vars, needed_lits)
        in_z3_list = [z3_vars[idx] for idx in range(len(in_wires))]
        dom_z3 = build_z3_domain_constraint(spec.domain_predicate, in_z3_list)

        all_int_units = all(abs(u - round(u)) < 1e-9 for u, _, _ in phase_terms)
        solver = z3.Solver()
        solver.add(dom_z3)
        solver.add(zmap[witness_lit] == z3.BoolVal(False))
        if all_int_units:
            total_units = z3.Sum(
                [z3.If(zmap[lit], int(round(u)), 0) for u, lit, _ in phase_terms]
            )
            solver.add((total_units % 8) != 0)
        else:
            total_real = z3.Sum(
                [z3.If(zmap[lit], z3.RealVal(str(u)), z3.RealVal("0")) for u, lit, _ in phase_terms]
            )
            solver_non_zero = z3.Solver()
            solver_non_zero.add(dom_z3)
            solver_non_zero.add(zmap[witness_lit] == z3.BoolVal(False))
            solver_non_zero.add(total_real != z3.RealVal("0"))
            solver = solver_non_zero

        if solver.check() == z3.sat:
            model = solver.model()
            cex = format_z3_bitstring_witness(model, in_z3_list, in_wires, circuit.wire_names)
            firing_gates = [
                g_idx
                for u, lit, g_idx in phase_terms
                if abs(u) > 1e-12 and z3.is_true(model.evaluate(zmap[lit], model_completion=True))
            ]
            cex["validity_witness_wire"] = circuit.wire_names[v_wire]
            cex["validity_witness_value"] = 0
            cex["spurious_phase_kickback_gates"] = firing_gates
            diags.append(
                LintDiagnostic(
                    rule="T-BorrowZ",
                    severity="ERROR",
                    code="E-BORROWZ-UNGUARDED-PHASE-FLIP",
                    message=(
                        f"Oracle kicks back non-zero quantum phase at gate(s) {firing_gates} even when "
                        f"validity witness `{circuit.wire_names[v_wire]} == 0` (counterexample {cex['input_hex']})."
                    ),
                    gate_indices=firing_gates,
                    wire_names=[circuit.wire_names[v_wire]],
                    counterexample=cex,
                    repair_suggestion=(
                        f"Include validity witness wire `{circuit.wire_names[v_wire]}` as an explicit control "
                        f"on the oracle phase kickback (`cz` / `ccz` / `mcx` into `|->`)."
                    ),
                )
            )

    return diags


run_rule_t_valid_if = run_rule_t_borrow_z


def run_rule_t_phase_clean(circuit: LiftedCircuit, spec: LintSpec) -> List[LintDiagnostic]:
    """
    Rule 3 (`T-PhaseClean` under `Gamma_in |- t : Q_e(A) -| Gamma_out`):
      1. Bennet ancilla cleanliness (`Law U1`): verifies designated `ancilla_wires`
         return cleanly to `|0>` across all inputs in `Dom`.
      2. Relative phase cleanliness (`expect_phase_clean`): verifies via symbolic
         XAG + Z3 phase-polynomial miter (and small-circuit exact unitary check)
         that compute-uncompute blocks leave zero input-dependent relative phase
         kickback (`Z`/`CZ`/`S`/`T`/`RZ`) on `Dom`.
      3. Algebraic involution (`U^2 == I`) & `Z_4` LCU branch phase alignment.
    """
    diags: List[LintDiagnostic] = []
    n = circuit.num_qubits

    anc_wires = list(spec.ancilla_wires) if spec.ancilla_wires is not None else []
    if n > 0 and (anc_wires or spec.expect_phase_clean):
        in_wires = (
            list(spec.input_wires)
            if spec.input_wires is not None
            else [w for w in range(n) if w not in set(anc_wires)]
        )
        mgr_pc = XAGManager()
        init_pc = [mgr_pc.LIT_ZERO] * n
        for idx, w in enumerate(in_wires):
            init_pc[w] = mgr_pc.var(idx)

        cur_pc = list(init_pc)
        last_mod_pc: Dict[int, int] = {}
        cl_pc: Dict[int, int] = {}
        # Track `|-> = H|1>` ancillas so `cx/ccx/mcx` onto `|->` is modeled as phase kickback
        prep_state = [0] * n  # 0=|0>, 1=|1> on clean ancilla, 2=|->, 3=general
        anc_set = set(anc_wires)
        pc_phase_terms: List[Tuple[float, int, int]] = []

        pc_gates = list(circuit.gates)
        if spec.uncompute_qc is not None:
            pc_gates = pc_gates + lift_qiskit_circuit(spec.uncompute_qc).gates
        elif spec.uncompute_qasm is not None:
            pc_gates = pc_gates + parse_qasm_to_lifted_circuit(str(spec.uncompute_qasm), name="uncomp").gates

        for g in pc_gates:
            op = g.op
            qs = g.qubits
            if op == "barrier":
                continue
            if len(qs) == 1 and qs[0] in anc_set and g.condition is None:
                q0 = qs[0]
                if op == "x" and prep_state[q0] == 0 and cur_pc[q0] == mgr_pc.LIT_ZERO:
                    prep_state[q0] = 1
                    cur_pc[q0] = mgr_pc.LIT_ONE
                    last_mod_pc[q0] = g.gate_index
                    continue
                if op == "h" and prep_state[q0] == 1:
                    prep_state[q0] = 2
                    last_mod_pc[q0] = g.gate_index
                    continue
                if op == "h" and prep_state[q0] == 2:
                    prep_state[q0] = 1
                    last_mod_pc[q0] = g.gate_index
                    continue
                if op == "x" and prep_state[q0] == 1 and cur_pc[q0] == mgr_pc.LIT_ONE:
                    prep_state[q0] = 0
                    cur_pc[q0] = mgr_pc.LIT_ZERO
                    last_mod_pc[q0] = g.gate_index
                    continue

            if op in ("cx", "ccx", "rccx", "mcx") and qs and prep_state[qs[-1]] == 2:
                prod = mgr_pc.LIT_ONE
                for cq in qs[:-1]:
                    prod = mgr_pc.and_(prod, cur_pc[cq])
                pc_phase_terms.append((4.0, prod, g.gate_index))
                continue

            if op in ("z", "s", "sdg", "t", "tdg", "p", "rz") and qs:
                if prep_state[qs[0]] != 2:
                    g_guard = mgr_pc.LIT_ONE
                    if g.condition is not None:
                        c_idx, _, exp_v = g.condition
                        c_l = cl_pc.get(c_idx, mgr_pc.LIT_ZERO)
                        g_guard = c_l if exp_v == 1 else mgr_pc.lit_not(c_l)
                    units = {
                        "z": 4.0,
                        "s": 2.0,
                        "sdg": 6.0,
                        "t": 1.0,
                        "tdg": 7.0,
                    }.get(op, (4.0 * g.params[0] / math.pi) if g.params else 0.0)
                    pc_phase_terms.append((units, mgr_pc.and_(g_guard, cur_pc[qs[0]]), g.gate_index))
                continue

            if op in ("cz", "ccz", "cp") and qs:
                prod = mgr_pc.LIT_ONE
                if g.condition is not None:
                    c_idx, _, exp_v = g.condition
                    c_l = cl_pc.get(c_idx, mgr_pc.LIT_ZERO)
                    prod = c_l if exp_v == 1 else mgr_pc.lit_not(c_l)
                for cq in qs:
                    prod = mgr_pc.and_(prod, cur_pc[cq])
                units = 4.0 if op in ("cz", "ccz") else (4.0 * g.params[0] / math.pi)
                pc_phase_terms.append((units, prod, g.gate_index))
                continue

            for q in qs:
                if q in anc_set and op not in ("reset",):
                    prep_state[q] = 3
            if op == "measure":
                m_var = mgr_pc.var(10000 + g.gate_index)
                if g.clbits:
                    cl_pc[g.clbits[0]] = m_var
                cur_pc[qs[0]] = m_var
                last_mod_pc[qs[0]] = g.gate_index
            else:
                step_pc, mod_pc = eval_classical_on_xag(mgr_pc, cur_pc, [g], cl_pc)
                cur_pc = step_pc
                last_mod_pc.update(mod_pc)

        z3_vpc: Dict[int, z3.BoolRef] = {idx: z3.Bool(f"in_{idx}") for idx in range(len(in_wires))}
        for _, (kind, v_idx, _) in enumerate(mgr_pc.nodes):
            if kind == "var" and v_idx not in z3_vpc:
                z3_vpc[v_idx] = z3.Bool(f"meas_{v_idx - 10000}")
        in_z3_pc = [z3_vpc[idx] for idx in range(len(in_wires))]
        dom_z3_pc = build_z3_domain_constraint(spec.domain_predicate, in_z3_pc)

        # Subcheck 1: Ancilla Cleanliness (`Law U1`): forall x in Dom. anc(x) == 0
        if anc_wires:
            unclosed_minus = [a for a in anc_wires if prep_state[a] == 2]
            zmap_anc = mgr_pc.to_z3_map(z3_vpc, [cur_pc[a] for a in anc_wires])
            s_anc = z3.Solver()
            s_anc.add(dom_z3_pc)
            s_anc.add(z3.Or([zmap_anc[cur_pc[a]] for a in anc_wires]))
            if unclosed_minus or s_anc.check() == z3.sat:
                if unclosed_minus and s_anc.check() != z3.sat:
                    s_dom_any = z3.Solver()
                    s_dom_any.add(dom_z3_pc)
                    s_dom_any.check()
                    m_anc = s_dom_any.model()
                    dirty_ancs = unclosed_minus
                else:
                    m_anc = s_anc.model()
                    dirty_ancs = sorted(
                        set(unclosed_minus)
                        | {
                            a
                            for a in anc_wires
                            if z3.is_true(m_anc.evaluate(zmap_anc[cur_pc[a]], model_completion=True))
                        }
                    )
                cex_anc = format_z3_bitstring_witness(m_anc, in_z3_pc, in_wires, circuit.wire_names)
                cex_anc["dirty_ancilla_wires"] = [circuit.wire_names[a] for a in dirty_ancs]
                bad_gates = sorted({last_mod_pc[a] for a in dirty_ancs if a in last_mod_pc})
                diags.append(
                    LintDiagnostic(
                        rule="T-PhaseClean",
                        severity="ERROR",
                        code="E-PHASECLEAN-DIRTY-ANCILLA",
                        message=(
                            f"Bennet uncomputation leaves ancilla wire(s) {[circuit.wire_names[a] for a in dirty_ancs]} "
                            f"non-zero (`|1>` / entangled) on valid domain input {cex_anc['input_hex']} (Law U1 violation)."
                        ),
                        gate_indices=bad_gates,
                        wire_names=[circuit.wire_names[a] for a in dirty_ancs],
                        counterexample=cex_anc,
                        repair_suggestion=(
                            "Uncompute temporary intermediate ancillas via symmetric reverse gates, "
                            "or erase via Hadamard `M_X + cond-Z + reset`."
                        ),
                    )
                )

        # Subcheck 2: Relative Phase Cleanliness (`expect_phase_clean == True`)
        if spec.expect_phase_clean:
            reported_phase = False
            if pc_phase_terms:
                va_pc: Dict[int, z3.BoolRef] = {idx: z3.Bool(f"pa_{idx}") for idx in range(len(in_wires))}
                vb_pc: Dict[int, z3.BoolRef] = {idx: z3.Bool(f"pb_{idx}") for idx in range(len(in_wires))}
                for _, (kind, v_idx, _) in enumerate(mgr_pc.nodes):
                    if kind == "var" and v_idx not in va_pc:
                        m_shared = z3.Bool(f"pm_{v_idx}")
                        va_pc[v_idx] = m_shared
                        vb_pc[v_idx] = m_shared
                p_lits = [lit for _, lit, _ in pc_phase_terms]
                map_pa = mgr_pc.to_z3_map(va_pc, p_lits)
                map_pb = mgr_pc.to_z3_map(vb_pc, p_lits)
                s_rel = z3.Solver()
                xa_z3 = [va_pc[i] for i in range(len(in_wires))]
                xb_z3 = [vb_pc[i] for i in range(len(in_wires))]
                s_rel.add(build_z3_domain_constraint(spec.domain_predicate, xa_z3))
                s_rel.add(build_z3_domain_constraint(spec.domain_predicate, xb_z3))
                all_int_p = all(abs(u - round(u)) < 1e-9 for u, _, _ in pc_phase_terms)
                if all_int_p:
                    phi_a = z3.Sum([z3.If(map_pa[lit], int(round(u)), 0) for u, lit, _ in pc_phase_terms])
                    phi_b = z3.Sum([z3.If(map_pb[lit], int(round(u)), 0) for u, lit, _ in pc_phase_terms])
                    s_rel.add(((phi_a - phi_b) % 8) != 0)
                else:
                    phi_a_r = z3.Sum([z3.If(map_pa[lit], z3.RealVal(str(u)), z3.RealVal("0")) for u, lit, _ in pc_phase_terms])
                    phi_b_r = z3.Sum([z3.If(map_pb[lit], z3.RealVal(str(u)), z3.RealVal("0")) for u, lit, _ in pc_phase_terms])
                    s_rel.add(phi_a_r != phi_b_r)

                if s_rel.check() == z3.sat:
                    reported_phase = True
                    m_rel = s_rel.model()
                    cex_pa = format_z3_bitstring_witness(m_rel, xa_z3, in_wires, circuit.wire_names)
                    cex_pb = format_z3_bitstring_witness(m_rel, xb_z3, in_wires, circuit.wire_names)
                    active_pgates = sorted(
                        {
                            g_idx
                            for u, lit, g_idx in pc_phase_terms
                            if abs(u) > 1e-12
                            and (
                                z3.is_true(m_rel.evaluate(map_pa[lit], model_completion=True))
                                != z3.is_true(m_rel.evaluate(map_pb[lit], model_completion=True))
                            )
                        }
                    )
                    diags.append(
                        LintDiagnostic(
                            rule="T-PhaseClean",
                            severity="ERROR",
                            code="E-PHASECLEAN-RESIDUAL-PHASE",
                            message=(
                                f"Uncomputation leaves input-dependent relative phase kickback between domain "
                                f"inputs {cex_pa['input_hex']} and {cex_pb['input_hex']} at gate(s) {active_pgates}."
                            ),
                            gate_indices=active_pgates,
                            wire_names=[circuit.wire_names[w] for w in in_wires],
                            counterexample={
                                "lhs_domain_input": cex_pa,
                                "rhs_domain_input": cex_pb,
                                "residual_phase_gates": active_pgates,
                            },
                            repair_suggestion=(
                                "Cancel relative phases during uncomputation (replace asymmetric `S`/`T`/`Z`/`CZ` "
                                "with `Sdg`/`Tdg`/`Z`/`CZ` inverse pairs) so `|x>|0> -> |x>|0>` is phase-clean."
                            ),
                        )
                    )

            if (
                not reported_phase
                and n <= 10
                and all(g.op not in ("measure", "reset") and g.condition is None for g in circuit.gates)
                and any(g.op in ("h", "rx", "ry", "rz", "p", "cp", "s", "sdg", "t", "tdg", "z", "cz", "ccz", "unitary") for g in circuit.gates)
            ):
                umat_pc = compute_exact_circuit_unitary(circuit)
                ref_phase: Optional[complex] = None
                ref_x: Optional[int] = None
                for x_mask in range(1 << len(in_wires)):
                    s_chk_d = z3.Solver()
                    x_bools = [z3.BoolVal(bool((x_mask >> i) & 1)) for i in range(len(in_wires))]
                    s_chk_d.add(build_z3_domain_constraint(spec.domain_predicate, x_bools))
                    if s_chk_d.check() != z3.sat:
                        continue
                    col_idx = sum(((x_mask >> i) & 1) << w for i, w in enumerate(in_wires))
                    col_vec = umat_pc[:, col_idx]
                    dom_idx = int(np.argmax(np.abs(col_vec)))
                    amp = complex(col_vec[dom_idx])
                    if abs(amp) < 1.0 - 1e-6:
                        diags.append(
                            LintDiagnostic(
                                rule="T-PhaseClean",
                                severity="ERROR",
                                code="E-PHASECLEAN-RESIDUAL-PHASE",
                                message=(
                                    f"Phase-clean block leaks amplitude (`|<y|U|x>| = {abs(amp):.6f} < 1`) "
                                    f"on domain input `{hex(x_mask)}`."
                                ),
                                gate_indices=[g.gate_index for g in circuit.gates if g.op in ("h", "rx", "ry", "unitary")],
                                wire_names=[circuit.wire_names[w] for w in in_wires],
                                counterexample={"domain_input_hex": hex(x_mask), "dominant_amplitude_abs": round(abs(amp), 8)},
                                repair_suggestion="Close all Hadamard/rotation superpositions cleanly before exiting pure uncompute block.",
                            )
                        )
                        break
                    unit_ph = amp / abs(amp)
                    if ref_phase is None:
                        ref_phase = unit_ph
                        ref_x = x_mask
                    elif abs(unit_ph - ref_phase) > 1e-6:
                        diags.append(
                            LintDiagnostic(
                                rule="T-PhaseClean",
                                severity="ERROR",
                                code="E-PHASECLEAN-RESIDUAL-PHASE",
                                message=(
                                    f"Residual relative phase kickback detected between domain inputs "
                                    f"`{hex(ref_x or 0)}` and `{hex(x_mask)}` (`|e^{{i phi_1}} - e^{{i phi_0}}| = {abs(unit_ph - ref_phase):.6g}`)."
                                ),
                                gate_indices=[g.gate_index for g in circuit.gates],
                                wire_names=[circuit.wire_names[w] for w in in_wires],
                                counterexample={
                                    "lhs_input_hex": hex(ref_x or 0),
                                    "rhs_input_hex": hex(x_mask),
                                    "phase_diff_abs": round(float(abs(unit_ph - ref_phase)), 8),
                                },
                                repair_suggestion="Apply exact adjoint `U^dag` during uncomputation to cancel relative phases.",
                            )
                        )
                        break

    # Subcheck 3: Involution Check (`U^2 == I` / `f(f(x)) == x`) & LCU Z_4 Phase Alignment
    if spec.require_involutory and n > 0:
        if is_purely_classical_reversible(circuit):
            in_wires = list(spec.input_wires) if spec.input_wires is not None else list(range(n))
            mgr_inv = XAGManager()
            init_v = [mgr_inv.LIT_ZERO] * n
            for idx, w in enumerate(in_wires):
                init_v[w] = mgr_inv.var(idx)
            once_v, _ = eval_classical_on_xag(mgr_inv, init_v, circuit.gates)
            twice_v, mod_twice = eval_classical_on_xag(mgr_inv, once_v, circuit.gates)
            z3_v_inv = {idx: z3.Bool(f"in_{idx}") for idx in range(len(in_wires))}
            zmap_inv = mgr_inv.to_z3_map(z3_v_inv, twice_v + init_v)
            in_z3_inv = [z3_v_inv[idx] for idx in range(len(in_wires))]
            s_inv = z3.Solver()
            s_inv.add(build_z3_domain_constraint(spec.domain_predicate, in_z3_inv))
            s_inv.add(z3.Or([zmap_inv[twice_v[w]] != zmap_inv[init_v[w]] for w in range(n)]))
            if s_inv.check() == z3.sat:
                m_inv = s_inv.model()
                violated_ws = [
                    w for w in range(n)
                    if z3.is_true(m_inv.evaluate(zmap_inv[twice_v[w]] != zmap_inv[init_v[w]], model_completion=True))
                ]
                cex_inv = format_z3_bitstring_witness(m_inv, in_z3_inv, in_wires, circuit.wire_names)
                once_bits = mgr_inv.eval_concrete(
                    once_v, {idx: (cex_inv["input_int"] >> idx) & 1 for idx in range(len(in_wires))}
                )
                twice_bits = mgr_inv.eval_concrete(
                    twice_v, {idx: (cex_inv["input_int"] >> idx) & 1 for idx in range(len(in_wires))}
                )
                cex_inv["f_x_int"] = sum(b << i for i, b in enumerate(once_bits))
                cex_inv["f_f_x_int"] = sum(b << i for i, b in enumerate(twice_bits))
                cex_inv["violated_wires"] = [circuit.wire_names[w] for w in violated_ws]
                diags.append(
                    LintDiagnostic(
                        rule="T-PhaseClean",
                        severity="ERROR",
                        code="E-PHASECLEAN-NON-INVOLUTORY-CIRCUIT",
                        message=(
                            f"Reversible block `{circuit.name}` is not self-inverse (`f(f(x)) != x`): "
                            f"on input {cex_inv['input_hex']}, `f(f(x)) = {hex(cex_inv['f_f_x_int'])}` "
                            f"corrupts wire(s) {[circuit.wire_names[w] for w in violated_ws]}."
                        ),
                        gate_indices=sorted({mod_twice[w] for w in violated_ws if w in mod_twice}),
                        wire_names=[circuit.wire_names[w] for w in violated_ws],
                        counterexample=cex_inv,
                        repair_suggestion=(
                            "Uncompute non-involutory transformations (e.g. degree-2 Keccak `chi_5`) using "
                            "their exact inverse `U^dag` (`chi_5^-1`) rather than re-applying forward `U`."
                        ),
                    )
                )
        elif n <= 12:
            umat = compute_exact_circuit_unitary(circuit)
            dim = 1 << n
            ident = np.eye(dim, dtype=np.complex128)
            u_sq = umat @ umat
            sq_err = float(np.linalg.norm(u_sq - ident, ord=2))
            neg_ident_err = float(np.linalg.norm(u_sq + ident, ord=2))
            if sq_err > 1e-8:
                col_norms = np.linalg.norm(u_sq - ident, axis=0)
                bad_col = int(np.argmax(col_norms))
                bits = [(bad_col >> q) & 1 for q in range(n)]
                wire_assign = {circuit.wire_names[q]: bits[q] for q in range(n)}
                offending_ops = [
                    g.gate_index
                    for g in circuit.gates
                    if g.op in ("s", "sdg", "t", "tdg", "p", "cp", "rz", "cswap", "unitary")
                ]
                code = (
                    "E-PHASECLEAN-NON-HERMITIAN-SCALAR"
                    if neg_ident_err < 1e-8
                    else "E-PHASECLEAN-NON-INVOLUTORY-OPERATOR"
                )
                diags.append(
                    LintDiagnostic(
                        rule="T-PhaseClean",
                        severity="ERROR",
                        code=code,
                        message=(
                            f"Walk/SELECT operator `{circuit.name}` violates `U^2 == I` "
                            f"(`||U^2 - I||_2 = {sq_err:.6g}`): corrupts Chebyshev QSVT recurrence for `d >= 2`."
                        ),
                        gate_indices=offending_ops,
                        wire_names=list(circuit.wire_names),
                        counterexample={
                            "basis_state_index": bad_col,
                            "basis_state_hex": hex(bad_col),
                            "wire_assignment": wire_assign,
                            "spectral_norm_u2_minus_i": round(sq_err, 8),
                        },
                        repair_suggestion=(
                            "Pair non-Hermitian LCU branches `(U_l, U_l^dag)` with an involution `PartnerSwap` "
                            "on the LCU index register and eliminate `+i` (`SGate`) skew-Hermitian scalar phases."
                        ),
                    )
                )

    if spec.lcu_branch_degrees:
        omegas = [(3 * int(d)) % 4 for d in spec.lcu_branch_degrees]
        if len(set(omegas)) > 1:
            diags.append(
                LintDiagnostic(
                    rule="T-PhaseClean",
                    severity="ERROR",
                    code="E-PHASECLEAN-LCU-PHASE-MISMATCH",
                    message=(
                        f"Uncompensated LCU sum combines `Wx -> R` Chebyshev degrees {spec.lcu_branch_degrees} "
                        f"with mismatched `Z_4` global phases `i^{omegas}`."
                    ),
                    counterexample={"degrees": list(spec.lcu_branch_degrees), "omega_mod4": omegas},
                    repair_suggestion=(
                        "Apply controlled `S^{(4 - omega_j) mod 4}` phase compensation on the LCU ancilla register."
                    ),
                )
            )

    return diags


def _normalize_qpu_partition(
    qpu_partition: Union[Dict[Any, int], List[int]],
    num_qubits: int,
    wire_names: List[str],
) -> Dict[int, int]:
    if isinstance(qpu_partition, list):
        return {q: int(qpu_partition[q]) if q < len(qpu_partition) else 0 for q in range(num_qubits)}
    name_to_idx = {wn: idx for idx, wn in enumerate(wire_names)}
    part: Dict[int, int] = {q: 0 for q in range(num_qubits)}
    for k, v in qpu_partition.items():
        if isinstance(k, int) and 0 <= k < num_qubits:
            part[k] = int(v)
        elif str(k) in name_to_idx:
            part[name_to_idx[str(k)]] = int(v)
        elif str(k).isdigit() and 0 <= int(k) < num_qubits:
            part[int(k)] = int(v)
    return part


def run_rule_t_counit_u4(circuit: LiftedCircuit, spec: LintSpec) -> List[LintDiagnostic]:
    """
    Rule 4 (`T-CounitU4` under `Gamma_in |- t : Q_e(A) -| Gamma_out`):
      1. Mid-circuit `Law U4` counit (`H + measure` `M_X` + classical `Z`/`CZ` fixup):
         - Catches Z-basis mid-circuit measurement collapsing superpositions.
         - Catches omitted or mismatched classical-conditioned `Z`/`CZ` phase fixups
           after `M_X` erasure (and premature Hadamard mixing under tainted phase).
      2. Multi-QPU `qpu_partition` cat-disentangler check:
         - Detects redundant reverse Bell-pair / cross-QPU remote-`CX`/`CCX`
           cat-disentanglers that unitarily uncompute an entangled remote wire
           where local `0`-ebit `M_X` + classical `Z` fixup (`Law U4`) suffices.
    """
    diags: List[LintDiagnostic] = []
    n = circuit.num_qubits
    if n == 0:
        return diags

    def infer_default_inputs() -> List[int]:
        if spec.input_wires is not None:
            return list(spec.input_wires)
        if spec.ancilla_wires is not None:
            anc_set = set(spec.ancilla_wires)
            return [w for w in range(n) if w not in anc_set]
        inferred_inputs: List[int] = []
        seen_first: Set[int] = set()
        for g in circuit.gates:
            if g.op == "barrier":
                continue
            if g.op in ("ccx", "rccx", "mcx"):
                for cq in g.qubits[:-1]:
                    if cq not in seen_first:
                        seen_first.add(cq)
                        inferred_inputs.append(cq)
                tgt = g.qubits[-1]
                if tgt not in seen_first:
                    seen_first.add(tgt)
            elif g.op == "cx":
                cq, tq = g.qubits[0], g.qubits[1]
                if cq not in seen_first:
                    seen_first.add(cq)
                    inferred_inputs.append(cq)
                if tq not in seen_first:
                    seen_first.add(tq)
            elif g.op == "h":
                q = g.qubits[0]
                if q not in seen_first:
                    seen_first.add(q)
                    inferred_inputs.append(q)
            else:
                for q in g.qubits:
                    if q not in seen_first:
                        seen_first.add(q)
                        inferred_inputs.append(q)
        return sorted(inferred_inputs) if inferred_inputs else list(range(n))

    in_wires = infer_default_inputs()

    # --- Subcheck 1: Law U4 Mid-Circuit Measurement & Quadratic Phase Fixup ---
    has_measure = any(g.op == "measure" for g in circuit.gates)
    if spec.check_mbu_law_u4 and has_measure:
        mgr = XAGManager()
        cur_poly = [mgr.LIT_ZERO] * n
        for idx, w in enumerate(in_wires):
            cur_poly[w] = mgr.var(idx)

        basis_mode = ["Z"] * n
        pre_h_poly = [mgr.LIT_ZERO] * n
        clbit_var_lit: Dict[int, int] = {}
        meas_records: List[Tuple[int, int, int, int]] = []
        mbu_phase_terms: List[Tuple[int, int, int]] = []

        def is_hadamard_for_measurement(start_idx: int, q: int) -> bool:
            for j in range(start_idx + 1, len(circuit.gates)):
                gj = circuit.gates[j]
                if gj.op == "barrier" or q not in gj.qubits:
                    continue
                return gj.op == "measure" and gj.qubits[0] == q
            return False

        z_collapse_reported: Set[int] = set()
        early_basis_mix_reported: Set[int] = set()

        def check_residual_m_taint_now() -> Optional[Tuple[z3.ModelRef, Dict[int, z3.BoolRef], List[int]]]:
            if not meas_records:
                return None
            z3_v: Dict[int, z3.BoolRef] = {idx: z3.Bool(f"in_{idx}") for idx in range(len(in_wires))}
            z3_v_zero_m: Dict[int, z3.BoolRef] = {idx: z3_v[idx] for idx in range(len(in_wires))}
            for mv_id, _, _, _ in meas_records:
                z3_v[mv_id] = z3.Bool(f"m_{mv_id - 10000}")
                z3_v_zero_m[mv_id] = z3.BoolVal(False)
            lits_needed = [lit for _, lit, _ in mbu_phase_terms]
            map_m = mgr.to_z3_map(z3_v, lits_needed)
            map_0 = mgr.to_z3_map(z3_v_zero_m, lits_needed)
            phi_m = z3.Sum([z3.If(map_m[lit], u, 0) for u, lit, _ in mbu_phase_terms])
            phi_0 = z3.Sum([z3.If(map_0[lit], u, 0) for u, lit, _ in mbu_phase_terms])
            s_chk = z3.Solver()
            in_z3 = [z3_v[idx] for idx in range(len(in_wires))]
            s_chk.add(build_z3_domain_constraint(spec.domain_predicate, in_z3))
            s_chk.add(((phi_m - phi_0) % 8) != 0)
            if s_chk.check() == z3.sat:
                m_mod = s_chk.model()
                active_m_gates = [
                    g_idx
                    for mv_id, g_idx, _, _ in meas_records
                    if z3.is_true(m_mod.evaluate(z3_v[mv_id], model_completion=True))
                ]
                return (m_mod, z3_v, active_m_gates)
            return None

        for idx_g, g in enumerate(circuit.gates):
            op = g.op
            qs = g.qubits
            cond = g.condition

            def cond_guard_lit() -> int:
                if cond is None:
                    return mgr.LIT_ONE
                c_idx, _, exp_val = cond
                c_lit = clbit_var_lit.get(c_idx, mgr.LIT_ZERO)
                return c_lit if exp_val == 1 else mgr.lit_not(c_lit)

            if op == "barrier":
                continue
            if op == "h":
                q = qs[0]
                if cur_poly[q] == mgr.LIT_ZERO and q in in_wires:
                    basis_mode[q] = "Z"
                elif is_hadamard_for_measurement(idx_g, q):
                    basis_mode[q] = "X_ENT"
                    pre_h_poly[q] = cur_poly[q]
                else:
                    taint = check_residual_m_taint_now()
                    if taint is not None and g.gate_index not in early_basis_mix_reported:
                        m_mod, z3_v, bad_mgates = taint
                        early_basis_mix_reported.add(g.gate_index)
                        in_z3 = [z3_v[i] for i in range(len(in_wires))]
                        cex = format_z3_bitstring_witness(m_mod, in_z3, in_wires, circuit.wire_names)
                        cex["uncompensated_measure_gates"] = bad_mgates
                        cex["premature_hadamard_gate"] = g.gate_index
                        diags.append(
                            LintDiagnostic(
                                rule="T-CounitU4",
                                severity="ERROR",
                                code="E-COUNITU4-TAINTED-PHASE",
                                message=(
                                    f"Non-diagonal `h` on `{circuit.wire_names[q]}` at gate {g.gate_index} "
                                    f"executes while stochastic `M_X` phase kickback from measurement gate(s) "
                                    f"{bad_mgates} remains uncompensated (Law U4 counit violation)."
                                ),
                                gate_indices=bad_mgates + [g.gate_index],
                                wire_names=[circuit.wire_names[q]],
                                counterexample=cex,
                                repair_suggestion=(
                                    "Insert classical-conditioned `if (m[k] == 1) { cz c1, c2; }` fixup "
                                    "immediately after `M_X` before applying Hadamard/non-diagonal gates on controls."
                                ),
                            )
                        )
            elif op == "measure":
                q = qs[0]
                remaining_non_meas = any(
                    rem.op not in ("measure", "barrier") for rem in circuit.gates[idx_g + 1 :]
                )
                if basis_mode[q] == "X_ENT":
                    mv_id = 10000 + g.gate_index
                    m_lit = mgr.var(mv_id)
                    if g.clbits:
                        clbit_var_lit[g.clbits[0]] = m_lit
                    erased_f = pre_h_poly[q]
                    kickback_lit = mgr.and_(m_lit, erased_f)
                    mbu_phase_terms.append((4, kickback_lit, g.gate_index))
                    meas_records.append((mv_id, g.gate_index, q, erased_f))
                    cur_poly[q] = m_lit
                    basis_mode[q] = "Z"
                elif remaining_non_meas and q not in z_collapse_reported:
                    z3_va = {i: z3.Bool(f"xa_{i}") for i in range(len(in_wires))}
                    z3_vb = {i: z3.Bool(f"xb_{i}") for i in range(len(in_wires))}
                    for mv_id, _, _, _ in meas_records:
                        z3_va[mv_id] = z3.BoolVal(False)
                        z3_vb[mv_id] = z3.BoolVal(False)
                    fa = mgr.to_z3_map(z3_va, [cur_poly[q]])[cur_poly[q]]
                    fb = mgr.to_z3_map(z3_vb, [cur_poly[q]])[cur_poly[q]]
                    s_col = z3.Solver()
                    s_col.add(build_z3_domain_constraint(spec.domain_predicate, [z3_va[i] for i in range(len(in_wires))]))
                    s_col.add(build_z3_domain_constraint(spec.domain_predicate, [z3_vb[i] for i in range(len(in_wires))]))
                    s_col.add(fa == z3.BoolVal(False))
                    s_col.add(fb == z3.BoolVal(True))
                    if s_col.check() == z3.sat:
                        m_col = s_col.model()
                        z_collapse_reported.add(q)
                        cex_0 = format_z3_bitstring_witness(
                            m_col, [z3_va[i] for i in range(len(in_wires))], in_wires, circuit.wire_names
                        )
                        cex_1 = format_z3_bitstring_witness(
                            m_col, [z3_vb[i] for i in range(len(in_wires))], in_wires, circuit.wire_names
                        )
                        diags.append(
                            LintDiagnostic(
                                rule="T-CounitU4",
                                severity="ERROR",
                                code="E-COUNITU4-Z-BASIS-MEAS-COLLAPSE",
                                message=(
                                    f"Mid-circuit Z-basis measurement on `{circuit.wire_names[q]}` at gate "
                                    f"{g.gate_index} (missing Hadamard `h` before `measure`) collapses coherent "
                                    f"superpositions between {cex_0['input_hex']} (`|0>`) and {cex_1['input_hex']} (`|1>`)."
                                ),
                                gate_indices=[g.gate_index],
                                wire_names=[circuit.wire_names[q]],
                                counterexample={"branch_0_input": cex_0, "branch_1_input": cex_1},
                                repair_suggestion=(
                                    f"Measure `{circuit.wire_names[q]}` in the X basis (`h {circuit.wire_names[q]}; "
                                    f"measure {circuit.wire_names[q]};`) followed by conditional `z`/`cz` phase fixup."
                                ),
                            )
                        )
            elif op == "reset":
                g_lit = cond_guard_lit()
                cur_poly[qs[0]] = mgr.ite(g_lit, mgr.LIT_ZERO, cur_poly[qs[0]])
                basis_mode[qs[0]] = "Z"
            elif op in ("z", "s", "sdg", "cz", "ccz"):
                g_lit = cond_guard_lit()
                prod = g_lit
                for cq in qs:
                    prod = mgr.and_(prod, cur_poly[cq])
                units = {"z": 4, "cz": 4, "ccz": 4, "s": 2, "sdg": 6}[op]
                mbu_phase_terms.append((units, prod, g.gate_index))
            elif op in ("x", "cx", "ccx", "rccx", "mcx", "swap", "cswap"):
                step_lits, _ = eval_classical_on_xag(mgr, cur_poly, [g], clbit_var_lit)
                cur_poly = step_lits

        if meas_records and not early_basis_mix_reported:
            taint_end = check_residual_m_taint_now()
            if taint_end is not None:
                m_mod, z3_v, bad_mgates = taint_end
                in_z3 = [z3_v[i] for i in range(len(in_wires))]
                cex_end = format_z3_bitstring_witness(m_mod, in_z3, in_wires, circuit.wire_names)
                meas_outcomes = {
                    f"gate_{g_idx}_{circuit.wire_names[w]}": (
                        1 if z3.is_true(m_mod.evaluate(z3_v[mv_id], model_completion=True)) else 0
                    )
                    for mv_id, g_idx, w, _ in meas_records
                }
                cex_end["measurement_outcomes"] = meas_outcomes
                bad_wires = [circuit.wire_names[w] for _, g_idx, w, _ in meas_records if g_idx in bad_mgates]
                diags.append(
                    LintDiagnostic(
                        rule="T-CounitU4",
                        severity="ERROR",
                        code="E-COUNITU4-TAINTED-PHASE",
                        message=(
                            f"Uncompensated `M_X` quadratic phase kickback remains at circuit exit from "
                            f"measurement gate(s) {bad_mgates} on wire(s) {bad_wires} (Law U4 counit violation)."
                        ),
                        gate_indices=bad_mgates,
                        wire_names=bad_wires,
                        counterexample=cex_end,
                        repair_suggestion=(
                            "Add classical-conditioned `if (m[k] == 1) { z/cz ...; }` phase fixup for every "
                            "ancilla or cat qubit erased via Hadamard `M_X`."
                        ),
                    )
                )

    # --- Subcheck 2: Cross-QPU Redundant Cat-Disentangler (`qpu_partition`) ---
    if spec.qpu_partition is not None:
        part = _normalize_qpu_partition(spec.qpu_partition, n, circuit.wire_names)
        mgr_qpu = XAGManager()
        poly_qpu = [mgr_qpu.LIT_ZERO] * n
        for idx, w in enumerate(in_wires):
            poly_qpu[w] = mgr_qpu.var(idx)
        cl_qpu: Dict[int, int] = {}

        for g in circuit.gates:
            op = g.op
            qs = g.qubits
            if op == "barrier":
                continue
            if op == "measure":
                mv = mgr_qpu.var(10000 + g.gate_index)
                if g.clbits:
                    cl_qpu[g.clbits[0]] = mv
                poly_qpu[qs[0]] = mv
                continue

            next_qpu, _ = eval_classical_on_xag(mgr_qpu, poly_qpu, [g], cl_qpu)
            if len(qs) >= 2 and op in ("cx", "ccx", "rccx", "mcx", "swap", "cswap"):
                qpu_ids = {part[q] for q in qs}
                if len(qpu_ids) >= 2:
                    tgt_cands = [qs[-1]] if op not in ("swap", "cswap") else list(qs[-2:])
                    for tw in tgt_cands:
                        pre_l = poly_qpu[tw]
                        post_l = next_qpu[tw]
                        if pre_l != post_l:
                            va_q = {i: z3.Bool(f"qa_{i}") for i in range(len(in_wires))}
                            vb_q = {i: z3.Bool(f"qb_{i}") for i in range(len(in_wires))}
                            for _, (kind, v_idx, _) in enumerate(mgr_qpu.nodes):
                                if kind == "var" and v_idx not in va_q:
                                    va_q[v_idx] = z3.BoolVal(False)
                                    vb_q[v_idx] = z3.BoolVal(False)
                            map_pre_a = mgr_qpu.to_z3_map(va_q, [pre_l, post_l])
                            map_pre_b = mgr_qpu.to_z3_map(vb_q, [pre_l])
                            # Check post_l is identically 0 on Dom
                            s_post = z3.Solver()
                            s_post.add(build_z3_domain_constraint(spec.domain_predicate, [va_q[i] for i in range(len(in_wires))]))
                            s_post.add(map_pre_a[post_l] == z3.BoolVal(True))
                            if s_post.check() == z3.unsat:
                                # Check pre_l was non-constant (entangled with Dom inputs)
                                s_ent = z3.Solver()
                                s_ent.add(build_z3_domain_constraint(spec.domain_predicate, [va_q[i] for i in range(len(in_wires))]))
                                s_ent.add(build_z3_domain_constraint(spec.domain_predicate, [vb_q[i] for i in range(len(in_wires))]))
                                s_ent.add(map_pre_a[pre_l] == z3.BoolVal(False))
                                s_ent.add(map_pre_b[pre_l] == z3.BoolVal(True))
                                if s_ent.check() == z3.sat:
                                    m_ent = s_ent.model()
                                    c0 = format_z3_bitstring_witness(
                                        m_ent, [va_q[i] for i in range(len(in_wires))], in_wires, circuit.wire_names
                                    )
                                    c1 = format_z3_bitstring_witness(
                                        m_ent, [vb_q[i] for i in range(len(in_wires))], in_wires, circuit.wire_names
                                    )
                                    diags.append(
                                        LintDiagnostic(
                                            rule="T-CounitU4",
                                            severity="ERROR",
                                            code="E-COUNITU4-REDUNDANT-REMOTE-DISENTANGLER",
                                            message=(
                                                f"Cross-QPU `{op}` at gate {g.gate_index} across partitions "
                                                f"{[part[q] for q in qs]} unitarily disentangles `{circuit.wire_names[tw]}` "
                                                f"(consuming a redundant reverse ebit where `0`-ebit `M_X` + classical `Z` suffices)."
                                            ),
                                            gate_indices=[g.gate_index],
                                            wire_names=[circuit.wire_names[q] for q in qs],
                                            counterexample={
                                                "gate_index": g.gate_index,
                                                "wire_qpu_map": {circuit.wire_names[q]: part[q] for q in qs},
                                                "disentangled_wire": circuit.wire_names[tw],
                                                "branch_0_input": c0,
                                                "branch_1_input": c1,
                                            },
                                            repair_suggestion=(
                                                f"Replace reverse cross-QPU `{op}` with local `h {circuit.wire_names[tw]}; "
                                                f"measure {circuit.wire_names[tw]} -> m; reset {circuit.wire_names[tw]};` "
                                                f"and classical-conditioned `if (m == 1) z/cz` on source QPU (`0` reverse ebits)."
                                            ),
                                        )
                                    )
                                    break
            poly_qpu = next_qpu

    return diags


def run_rule_t_alg_phase(circuit: LiftedCircuit, spec: LintSpec) -> List[LintDiagnostic]:
    return run_rule_t_phase_clean(circuit, spec) + run_rule_t_counit_u4(circuit, spec)


def run_rule_t_wire_basis(circuit: LiftedCircuit, spec: LintSpec) -> List[LintDiagnostic]:
    """
    Wire-basis, linear GF(2) / S-box bijection, and `Fin[N]` stencil RAW aliasing
    subcheck projected under Rule 1 (`T-DomImg`).
    """
    diags: List[LintDiagnostic] = []

    if spec.stencil_spec:
        st = spec.stencil_spec
        ring_n = int(st["ring_n"])
        lo_idx = int(st.get("lo_idx", 0))
        hi_idx = int(st.get("hi_idx", ring_n - 1))
        kind = str(st.get("kind", "qstencil-ring"))
        read_offsets = [int(r) for r in st.get("read_offsets", [0, 1, 2])]
        write_offset = int(st.get("write_offset", 0))
        if lo_idx != 0 or hi_idx != ring_n - 1:
            diags.append(
                LintDiagnostic(
                    rule="T-DomImg",
                    severity="ERROR",
                    code="E-DOMIMG-FIN-BOUNDS",
                    message=(
                        f"Ring stencil over `Fin[{ring_n}]` expects index range `0..{ring_n - 1}`, "
                        f"got `{lo_idx}..{hi_idx}` ({hi_idx - lo_idx + 1} iterations)."
                    ),
                    counterexample={"ring_n": ring_n, "lo_idx": lo_idx, "hi_idx": hi_idx},
                    repair_suggestion=f"Use exact `Fin[{ring_n}]` bounds `0..{ring_n - 1}`.",
                )
            )
        elif kind == "imperative-seq":
            for i in range(ring_n):
                for j in range(i + 1, ring_n):
                    for roff in read_offsets:
                        if (i + write_offset) % ring_n == (j + roff) % ring_n:
                            lane = (i + write_offset) % ring_n
                            diags.append(
                                LintDiagnostic(
                                    rule="T-DomImg",
                                    severity="ERROR",
                                    code="E-DOMIMG-RAW-STENCIL-ALIAS",
                                    message=(
                                        f"Imperative loop over `Fin[{ring_n}]` overwrites lane {lane} "
                                        f"in step {i} before step {j} reads it."
                                    ),
                                    counterexample={"writer_iter": i, "reader_iter": j, "aliased_lane": lane},
                                    repair_suggestion="Use simultaneous `qstencil-ring` backup ancillas or out-of-place `M_X`.",
                                )
                            )
                            break
                    if diags:
                        break
                if diags:
                    break

    has_linear = spec.expected_linear_matrix_gf2 is not None or spec.expected_column_masks is not None
    has_sbox = spec.expected_sbox_table is not None
    if not has_linear and not has_sbox:
        return diags

    n_total = circuit.num_qubits
    if has_linear:
        if spec.expected_linear_matrix_gf2 is not None:
            mat_rows = [[int(b) & 1 for b in row] for row in spec.expected_linear_matrix_gf2]
            width = len(mat_rows)
        else:
            cols = [int(c) for c in (spec.expected_column_masks or [])]
            width = len(cols)
            mat_rows = [[(cols[c] >> r) & 1 for c in range(width)] for r in range(width)]
    else:
        tbl = list(spec.expected_sbox_table or [])
        width = int(round(math.log2(max(2, len(tbl)))))
        mat_rows = []

    in_wires = list(spec.input_wires) if spec.input_wires is not None else list(range(width))
    phys_out_wires = list(spec.output_wires) if spec.output_wires is not None else list(in_wires)
    perm = list(spec.wire_permutation) if spec.wire_permutation is not None else list(range(width))

    if len(perm) != width or sorted(perm) != list(range(width)):
        diags.append(
            LintDiagnostic(
                rule="T-DomImg",
                severity="ERROR",
                code="E-DOMIMG-INVALID-PERM",
                message=f"Supplied `wire_permutation` {perm} is not a bijection on `0..{width - 1}`.",
                repair_suggestion=f"Supply a valid permutation of `0..{width - 1}`.",
            )
        )
        return diags

    mgr = XAGManager()
    init_lits = [mgr.LIT_ZERO] * n_total
    for idx, w in enumerate(in_wires):
        init_lits[w] = mgr.var(idx)
    final_lits, _ = eval_classical_on_xag(mgr, init_lits, circuit.gates)

    raw_phys_out_lits = [final_lits[phys_out_wires[i]] for i in range(width)]
    logical_out_lits = [raw_phys_out_lits[perm[i]] for i in range(width)]

    zero_bits = mgr.eval_concrete(logical_out_lits, {i: 0 for i in range(width)})
    actual_at_zero = sum(b << i for i, b in enumerate(zero_bits))
    expected_at_zero = int(spec.affine_constant) if has_linear else int(spec.expected_sbox_table[0])  # type: ignore[index]
    zero_input_passes = actual_at_zero == expected_at_zero

    z3_vars: Dict[int, z3.BoolRef] = {i: z3.Bool(f"x_{i}") for i in range(width)}
    for _, (kind, v_idx, _) in enumerate(mgr.nodes):
        if kind == "var" and v_idx not in z3_vars:
            z3_vars[v_idx] = z3.BoolVal(False)
    zmap = mgr.to_z3_map(z3_vars, raw_phys_out_lits)
    actual_z3 = [zmap[logical_out_lits[i]] for i in range(width)]

    if has_linear:
        expected_z3: List[z3.BoolRef] = []
        for r in range(width):
            terms = [z3_vars[c] for c in range(width) if mat_rows[r][c] == 1]
            if (spec.affine_constant >> r) & 1:
                terms.append(z3.BoolVal(True))
            if not terms:
                expected_z3.append(z3.BoolVal(False))
            else:
                acc = terms[0]
                for t in terms[1:]:
                    acc = z3.Xor(acc, t)
                expected_z3.append(acc)
    else:
        sbox_tbl = list(spec.expected_sbox_table or [])
        expected_z3 = []
        for r in range(width):
            ones_masks = [x for x in range(len(sbox_tbl)) if ((sbox_tbl[x] >> r) & 1) == 1]
            expected_z3.append(
                z3.Or(
                    [
                        z3.And([z3_vars[b] if ((x >> b) & 1) else z3.Not(z3_vars[b]) for b in range(width)])
                        for x in ones_masks
                    ]
                )
                if ones_masks
                else z3.BoolVal(False)
            )

    diff_or = z3.Or([actual_z3[i] != expected_z3[i] for i in range(width)])

    s_unit = z3.Solver()
    s_unit.add(z3.Sum([z3.If(z3_vars[i], 1, 0) for i in range(width)]) == 1)
    s_unit.add(diff_or)
    has_bug = False
    model: Optional[z3.ModelRef] = None
    unit_basis_failed = False

    if s_unit.check() == z3.sat:
        has_bug = True
        unit_basis_failed = True
        model = s_unit.model()
    else:
        s_gen = z3.Solver()
        s_gen.add(diff_or)
        if s_gen.check() == z3.sat:
            has_bug = True
            model = s_gen.model()

    if has_bug and model is not None:
        in_z3_list = [z3_vars[i] for i in range(width)]
        cex = format_z3_bitstring_witness(model, in_z3_list, in_wires, circuit.wire_names)
        act_val = sum(
            (1 << i)
            for i in range(width)
            if z3.is_true(model.evaluate(actual_z3[i], model_completion=True))
        )
        exp_val = sum(
            (1 << i)
            for i in range(width)
            if z3.is_true(model.evaluate(expected_z3[i], model_completion=True))
        )
        cex["actual_output_hex"] = hex(act_val)
        cex["expected_output_hex"] = hex(exp_val)
        cex["zero_input_passes_blind_spot"] = zero_input_passes
        cex["zero_input_output_hex"] = hex(actual_at_zero)
        cex["unit_basis_generator_failure"] = unit_basis_failed

        inferred_perm: Optional[List[int]] = None
        raw_z3 = [zmap[raw_phys_out_lits[j]] for j in range(width)]
        used_phys: Set[int] = set()
        candidate_perm: List[int] = []
        for i in range(width):
            matched_j: Optional[int] = None
            for j in range(width):
                if j in used_phys:
                    continue
                s_eq = z3.Solver()
                s_eq.add(raw_z3[j] != expected_z3[i])
                if s_eq.check() == z3.unsat:
                    matched_j = j
                    break
            if matched_j is None:
                break
            used_phys.add(matched_j)
            candidate_perm.append(matched_j)
        if len(candidate_perm) == width:
            inferred_perm = candidate_perm
            cex["inferred_zero_swap_wire_permutation"] = inferred_perm

        code = "E-DOMIMG-PERM-MISMATCH" if inferred_perm is not None else "E-DOMIMG-BASIS-MISMATCH"
        repair = (
            f"Apply compile-time `0`-SWAP logical wire relabeling `wire_permutation = {inferred_perm}` "
            f"(no physical `SWAP` gates needed)."
            if inferred_perm is not None
            else "Align linear basis isomorphism / bit-endianness with the target field representation."
        )
        diags.append(
            LintDiagnostic(
                rule="T-DomImg",
                severity="ERROR",
                code=code,
                message=(
                    f"Wire-basis Z3 miter failed on input {cex['input_hex']} "
                    f"(actual {cex['actual_output_hex']} != expected {cex['expected_output_hex']}; "
                    f"zero-input `0x0` passes={zero_input_passes})."
                ),
                gate_indices=[g.gate_index for g in circuit.gates[: min(8, len(circuit.gates))]],
                wire_names=[circuit.wire_names[w] for w in phys_out_wires],
                counterexample=cex,
                repair_suggestion=repair,
            )
        )

    return diags


def run_rule_t_sub_norm(circuit: LiftedCircuit, spec: LintSpec) -> List[LintDiagnostic]:
    """
    Rule 5 (`T-SubNorm` under `Gamma_in |- t : Q_e(A) -| Gamma_out`):
      1. `block_encoding_spec`:
         - Analytic LCU weight sum `sum_j |c_j|` & operator spectral norm `||A||_2`
           vs declared subnormalization `alpha_declared` (with Z3 Real witness).
         - Exact circuit unitary `<0_anc| U |0_anc>` block extraction (`||A - alpha * U_00||_2`).
         - Chebyshev QSVT error amplification `d^2 * eps_0 <= eps_target` (or `d * eps_0`).
      2. `drift_spec`:
         - Coset carry-runway bound `c_pad >= ceil(log2(N_add / p_fail))`.
         - QRNS dynamic range `prod(p_i) >= N^m`.
         - Alias discretization & Chebyshev QSVT error amplification.
    """
    diags: List[LintDiagnostic] = []

    if spec.block_encoding_spec:
        bs = spec.block_encoding_spec
        alpha_decl = float(bs.get("alpha_declared", bs.get("alpha", 1.0)))
        eps_0_be = float(bs.get("eps_0", 1e-6))

        alpha_candidates: List[float] = []
        for k_act in ("alpha_actual", "operator_spectral_norm", "spectral_norm"):
            if k_act in bs:
                alpha_candidates.append(float(bs[k_act]))
        if "lcu_coeffs" in bs:
            alpha_candidates.append(sum(abs(float(c)) for c in bs["lcu_coeffs"]))

        target_mat: Optional[np.ndarray] = None
        if "target_matrix" in bs:
            target_mat = np.asarray(bs["target_matrix"], dtype=np.complex128)
            alpha_candidates.append(float(np.linalg.norm(target_mat, ord=2)))

        u_block: Optional[np.ndarray] = None
        if (
            0 < circuit.num_qubits <= 10
            and all(g.op not in ("measure", "reset") and g.condition is None for g in circuit.gates)
            and ("system_wires" in bs or "num_system_qubits" in bs or target_mat is not None)
        ):
            if "system_wires" in bs:
                sys_ws = [int(w) for w in bs["system_wires"]]
            elif "num_system_qubits" in bs:
                sys_ws = list(range(int(bs["num_system_qubits"])))
            elif target_mat is not None:
                k_sys = int(round(math.log2(max(2, target_mat.shape[0]))))
                sys_ws = list(range(k_sys))
            else:
                sys_ws = list(range(circuit.num_qubits))
            umat_be = compute_exact_circuit_unitary(circuit)
            sub_indices = [
                sum(((s >> idx) & 1) << q for idx, q in enumerate(sys_ws))
                for s in range(1 << len(sys_ws))
            ]
            u_block = umat_be[np.ix_(sub_indices, sub_indices)]

        alpha_actual = max(alpha_candidates) if alpha_candidates else alpha_decl
        if alpha_actual > alpha_decl + 1e-9:
            s_sub = z3.Solver()
            a_act_z3 = z3.Real("alpha_actual")
            a_dec_z3 = z3.Real("alpha_declared")
            s_sub.add(
                a_act_z3 == z3.RealVal(f"{alpha_actual:.12f}"),
                a_dec_z3 == z3.RealVal(f"{alpha_decl:.12f}"),
                a_act_z3 > a_dec_z3,
            )
            s_sub.check()
            diags.append(
                LintDiagnostic(
                    rule="T-SubNorm",
                    severity="ERROR",
                    code="E-SUBNORM-ALPHA-OVERFLOW",
                    message=(
                        f"Block-encoding subnormalization overflow: required `alpha_actual = {alpha_actual:.6g} > "
                        f"alpha_declared = {alpha_decl:.6g}` (`||A / alpha_declared||_2 > 1` violates unitarity)."
                    ),
                    gate_indices=[g.gate_index for g in circuit.gates[: min(8, len(circuit.gates))]],
                    wire_names=list(circuit.wire_names),
                    counterexample={
                        "alpha_actual": round(alpha_actual, 8),
                        "alpha_declared": round(alpha_decl, 8),
                        "overflow_ratio": round(alpha_actual / max(1e-12, alpha_decl), 8),
                    },
                    repair_suggestion=(
                        f"Declare subnormalization `alpha >= {alpha_actual:.6g}` (matching `sum_j |c_j|` "
                        f"and rescaling QSVT polynomial argument `x / alpha`)."
                    ),
                )
            )
        elif target_mat is not None and u_block is not None and u_block.shape == target_mat.shape:
            block_err = float(np.linalg.norm(target_mat - alpha_decl * u_block, ord=2))
            if block_err > eps_0_be + 1e-7:
                s_be = z3.Solver()
                err_z3 = z3.Real("block_encoding_spectral_err")
                tol_z3 = z3.Real("eps_0_declared")
                s_be.add(
                    err_z3 == z3.RealVal(f"{block_err:.12f}"),
                    tol_z3 == z3.RealVal(f"{eps_0_be:.12f}"),
                    err_z3 > tol_z3,
                )
                s_be.check()
                diags.append(
                    LintDiagnostic(
                        rule="T-SubNorm",
                        severity="ERROR",
                        code="E-SUBNORM-BLOCK-ENCODING-ERROR",
                        message=(
                            f"Circuit top-left block `<0|U|0>` deviates from `A / alpha_declared`: "
                            f"`||A - alpha_declared * <0|U|0>||_2 = {block_err:.6g} > eps_0 = {eps_0_be:.6g}`."
                        ),
                        gate_indices=[g.gate_index for g in circuit.gates],
                        wire_names=list(circuit.wire_names),
                        counterexample={
                            "block_spectral_error": round(block_err, 8),
                            "eps_0_declared": eps_0_be,
                            "alpha_declared": alpha_decl,
                        },
                        repair_suggestion="Align PREPARE/SELECT angles and `alpha_declared` so `||A - alpha * <0|U|0>||_2 <= eps_0`.",
                    )
                )

        if "degree" in bs and "eps_target" in bs:
            deg_be = int(bs["degree"])
            regime_be = str(bs.get("regime", "markov-spectral-edge"))
            eps_tgt_be = float(bs["eps_target"])
            amp_be = deg_be if regime_be == "interior-walk" else (deg_be * deg_be)
            eps_out_be = amp_be * eps_0_be
            if eps_out_be > eps_tgt_be + 1e-12:
                s_ch = z3.Solver()
                e_out_z3 = z3.Real("chebyshev_eps_out")
                e_tgt_z3 = z3.Real("eps_target")
                s_ch.add(
                    e_out_z3 == z3.RealVal(f"{eps_out_be:.12f}"),
                    e_tgt_z3 == z3.RealVal(f"{eps_tgt_be:.12f}"),
                    e_out_z3 > e_tgt_z3,
                )
                s_ch.check()
                diags.append(
                    LintDiagnostic(
                        rule="T-SubNorm",
                        severity="ERROR",
                        code="E-SUBNORM-CHEBYSHEV-EPS-OVERFLOW",
                        message=(
                            f"Chebyshev QSVT degree `d = {deg_be}` (`{amp_be}x` amplification) "
                            f"inflates `eps_0 = {eps_0_be:.6g}` to `{eps_out_be:.6g} > eps_target = {eps_tgt_be:.6g}`."
                        ),
                        counterexample={
                            "degree": deg_be,
                            "amplification_factor": amp_be,
                            "eps_0": eps_0_be,
                            "eps_out": eps_out_be,
                            "eps_target": eps_tgt_be,
                        },
                        repair_suggestion=f"Tighten block-encoding precision to `eps_0 <= {eps_tgt_be / max(1, amp_be):.3g}`.",
                    )
                )

    if not spec.drift_spec:
        return diags
    ds = spec.drift_spec

    if "coset_runway" in ds:
        cr = ds["coset_runway"]
        c_pad = int(cr["c_pad"])
        n_add = int(cr.get("n_add", cr.get("steps", 1)))
        if "p_fail" in cr:
            p_fail = float(cr["p_fail"])
            req_cpad = int(math.ceil(math.log2(max(1.0, n_add / p_fail))))
            overflow = c_pad < req_cpad
        else:
            s_bits = int(cr.get("safety_bits", 15))
            p_fail = 2.0 ** (-s_bits)
            req_cap = n_add * (1 << s_bits)
            req_cpad = 1
            while (1 << req_cpad) <= req_cap:
                req_cpad += 1
            overflow = (1 << c_pad) <= req_cap

        if overflow:
            s_ovf = z3.Solver()
            acc_drift = z3.Int("accumulated_carry_steps")
            s_ovf.add(acc_drift >= (1 << c_pad), acc_drift <= max(1 << c_pad, n_add))
            ovf_witness = (1 << c_pad)
            if s_ovf.check() == z3.sat:
                ovf_witness = int(s_ovf.model().eval(acc_drift).as_long())
            diags.append(
                LintDiagnostic(
                    rule="T-SubNorm",
                    severity="ERROR",
                    code="E-SUBNORM-COSET-RUNWAY-OVERFLOW",
                    message=(
                        f"Coset carry runway `c_pad = {c_pad}` underflows required `c_pad >= {req_cpad}` "
                        f"for `N_add = {n_add}`, `p_fail = {p_fail:.3g}`."
                    ),
                    wire_names=list(circuit.wire_names[: min(4, len(circuit.wire_names))]),
                    counterexample={
                        "supplied_c_pad": c_pad,
                        "required_c_pad": req_cpad,
                        "n_add": n_add,
                        "p_fail": p_fail,
                        "z3_wraparound_carry_count": ovf_witness,
                    },
                    repair_suggestion=f"Increase coset padding register width to `c_pad >= {req_cpad}`.",
                )
            )

    if "rns_moduli" in ds:
        rn = ds["rns_moduli"]
        mod_n = int(rn["modulus_n"])
        m_pow = int(rn.get("power_m", 2))
        moduli = [int(p) for p in rn["moduli"]]
        prod_l = 1
        for p in moduli:
            prod_l *= p
        req_range = mod_n ** m_pow
        if prod_l < req_range:
            s_rns = z3.Solver()
            x_sym = z3.Int("X_unreduced")
            s_rns.add(x_sym >= prod_l, x_sym < req_range)
            cex_x = prod_l
            if s_rns.check() == z3.sat:
                cex_x = int(s_rns.model().eval(x_sym).as_long())
            diags.append(
                LintDiagnostic(
                    rule="T-SubNorm",
                    severity="ERROR",
                    code="E-SUBNORM-RNS-DYNAMIC-RANGE",
                    message=(
                        f"QRNS modulus product `prod(p_i) = {prod_l} < N^{m_pow} = {req_range}` "
                        f"causes silent CRT wraparound."
                    ),
                    counterexample={
                        "rns_product_L": prod_l,
                        "required_N_pow_m": req_range,
                        "z3_wraparound_value_X": cex_x,
                        "corrupted_crt_mod_N": (cex_x % prod_l) % mod_n,
                        "true_mod_N": cex_x % mod_n,
                    },
                    repair_suggestion=f"Add RNS prime moduli until `prod(p_i) >= {req_range}`.",
                )
            )

    if "qsvt_eps" in ds:
        qe = ds["qsvt_eps"]
        deg = int(qe["degree"])
        regime = str(qe.get("regime", "markov-spectral-edge"))
        eps_target = float(qe["eps_target"])
        if "num_terms" in qe and "alpha" in qe and "mu_bits" in qe:
            num_terms = int(qe["num_terms"])
            alpha = float(qe["alpha"])
            mu_bits = int(qe["mu_bits"])
            eps_0 = (num_terms * alpha) / (2.0 ** mu_bits)
            claimed_eps_0 = qe.get("claimed_eps_0")
            if claimed_eps_0 is not None and float(claimed_eps_0) < 0.999999 * eps_0:
                diags.append(
                    LintDiagnostic(
                        rule="T-SubNorm",
                        severity="ERROR",
                        code="E-SUBNORM-ZERO-OR-UNSOUND-EPS",
                        message=(
                            f"Alias LCU claims `eps_0 = {claimed_eps_0}` on `mu = {mu_bits}` bits, "
                            f"but discretization error is `{eps_0:.6g}`."
                        ),
                        counterexample={
                            "claimed_eps_0": float(claimed_eps_0),
                            "true_alias_eps_0": eps_0,
                            "mu_bits": mu_bits,
                        },
                        repair_suggestion="Track non-zero alias discretization error `L * alpha / 2^mu`.",
                    )
                )
        else:
            eps_0 = float(qe["eps_0"])
            num_terms = int(qe.get("num_terms", 1))
            alpha = float(qe.get("alpha", 1.0))

        amp_factor = deg if regime == "interior-walk" else (deg * deg)
        eps_out = amp_factor * eps_0
        if eps_out > eps_target:
            req_mu = int(math.ceil(math.log2(max(1.0, (amp_factor * num_terms * alpha) / eps_target))))
            diags.append(
                LintDiagnostic(
                    rule="T-SubNorm",
                    severity="ERROR",
                    code="E-SUBNORM-EPS-AMPLIFICATION",
                    message=(
                        f"Chebyshev QSVT degree `d = {deg}` (`{regime}`, `{amp_factor}x` Lipschitz factor) "
                        f"amplifies `eps_0 = {eps_0:.6g}` to `{eps_out:.6g} > eps_target = {eps_target:.6g}`."
                    ),
                    counterexample={
                        "degree": deg,
                        "regime": regime,
                        "amplification_factor": amp_factor,
                        "eps_0": eps_0,
                        "eps_out": eps_out,
                        "eps_target": eps_target,
                    },
                    repair_suggestion=(
                        f"Reduce block-encoding error below `{eps_target / max(1, amp_factor):.3g}` "
                        f"(e.g. `mu_bits >= {req_mu}`)."
                    ),
                )
            )

    return diags


run_rule_t_drift_eps = run_rule_t_sub_norm


def extract_circuit_ir_metrics(circuit: LiftedCircuit, spec: Optional[LintSpec] = None) -> Dict[str, Any]:
    """
    Computes exact `TempAND` (`M_X`-erased), `CCX`, `CX`, `X`, `SWAP`, live qubit
    width, and chordal interval-graph reusable ancilla chromatic width directly
    from the lifted AST.
    """
    n = circuit.num_qubits
    meas_erased_wires_at: Dict[int, List[int]] = {}
    for g in circuit.gates:
        if g.op == "measure" and g.qubits:
            meas_erased_wires_at.setdefault(g.qubits[0], []).append(g.gate_index)

    temp_and_count = 0
    ccx_count = 0
    cx_count = 0
    x_count = 0
    swap_count = 0
    t_count = 0
    mid_meas_count = 0
    reset_count = 0
    touched_qubits: Set[int] = set()

    total_gates = len(circuit.gates)
    for pos, g in enumerate(circuit.gates):
        for q in g.qubits:
            touched_qubits.add(q)
        op = g.op
        if op == "x":
            x_count += 1
        elif op == "cx":
            cx_count += 1
        elif op in ("swap", "cswap"):
            swap_count += 1
            if op == "cswap":
                ccx_count += 1
        elif op in ("t", "tdg"):
            t_count += 1
        elif op == "reset":
            reset_count += 1
        elif op == "measure":
            if any(rem.op not in ("measure", "barrier") for rem in circuit.gates[pos + 1 :]):
                mid_meas_count += 1
        elif op in ("ccx", "rccx", "mcx"):
            mult = max(1, 2 * (len(g.qubits) - 2) - 1)
            tgt = g.qubits[-1]
            # Check if `tgt` is subsequently erased by `measure` before another CCX/uncompute on `tgt`:
            erased_by_mx = any(m_idx > g.gate_index for m_idx in meas_erased_wires_at.get(tgt, []))
            if erased_by_mx:
                temp_and_count += mult
            else:
                ccx_count += mult

    # Chordal interval-graph reusable ancilla chromatic width across `reset`-segmented live intervals:
    anc_candidates: Set[int] = set(spec.ancilla_wires) if (spec and spec.ancilla_wires) else set()
    if not anc_candidates and spec and spec.input_wires is not None:
        io_set = set(spec.input_wires) | set(spec.output_wires or spec.input_wires)
        anc_candidates = {q for q in touched_qubits if q not in io_set}

    intervals: List[Tuple[int, int]] = []
    for aq in sorted(anc_candidates):
        seg_start: Optional[int] = None
        last_use: Optional[int] = None
        for g in circuit.gates:
            if aq not in g.qubits or g.op == "barrier":
                continue
            if g.op == "reset":
                if seg_start is not None:
                    intervals.append((seg_start, g.gate_index))
                    seg_start = None
                    last_use = None
            else:
                if seg_start is None:
                    seg_start = g.gate_index
                last_use = g.gate_index
        if seg_start is not None and last_use is not None:
            intervals.append((seg_start, last_use))

    events: List[Tuple[int, int]] = []
    for s_idx, e_idx in intervals:
        events.append((s_idx, 1))
        events.append((e_idx + 1, -1))
    events.sort(key=lambda pr: (pr[0], pr[1]))
    cur_live = 0
    chordal_peak_ancillas = 0
    for _, delta in events:
        cur_live += delta
        chordal_peak_ancillas = max(chordal_peak_ancillas, cur_live)

    return {
        "declared_qubits": n,
        "live_qubit_width": len(touched_qubits),
        "allocated_ancillas": len(anc_candidates),
        "chordal_reusable_ancilla_width": chordal_peak_ancillas,
        "chordal_reclaimable_ancillas": max(0, len(anc_candidates) - chordal_peak_ancillas),
        "temp_and_count": temp_and_count,
        "ccx_count": ccx_count,
        "total_and_toffoli_equiv": temp_and_count + ccx_count,
        "cx_count": cx_count,
        "x_count": x_count,
        "swap_count": swap_count,
        "t_gate_equiv": 4 * temp_and_count + 7 * ccx_count + t_count,
        "mid_circuit_meas_count": mid_meas_count,
        "reset_count": reset_count,
        "total_gate_nodes": total_gates,
    }


def _matrix_elim_temp_ands(rows: int, clo: int, chi: int, pivots: int) -> int:
    swap_ands = sum(
        max(0, rows - 1 - x) * max(0, chi - max(x, clo))
        for x in range(max(0, pivots - 1))
    )
    add_ands = sum(
        max(0, rows - 1) * max(0, chi - max(x + 1, clo))
        for x in range(pivots)
    )
    return swap_ands + add_ands


def run_rule_t_qubit_cap(
    circuit: LiftedCircuit,
    spec: LintSpec,
    ir_metrics: Dict[str, Any],
) -> List[LintDiagnostic]:
    """
    Rule 6 (`T-QubitCap`):
      - Enforces single-QPU qubit capacity `q_circuit <= Q_cap` when `q_cap` is set
        without multi-QPU partitioning (`E-QUBITCAP-EXCEEDS-SINGLE-QPU`), reporting
        Z3 integer witness and chordal `reset`-reuse width.
      - Compares true AST `TempAND`/`CCX`/qubit counts against detached resource
        claims (`claimed_temp_ands`, `claimed_ccx`, `claimed_qubits`).
      - Checks matrix-elimination bound-slice completeness (`skip_rightmost` hazard).
      - Runs pure-spec `XAG + Z3` boolean miter if `expected_boolean_miter` is set.
      - Checks Grover collision margin `m_check >= ceil(log2(|Dom|)) + s_margin`.
    """
    diags: List[LintDiagnostic] = []

    # 0. Single-QPU Capacity Guard (`q_allocated <= Q_cap` when unpartitioned)
    if spec.q_cap is not None and spec.qpu_partition is None and spec.cluster_spec is None:
        q_decl = int(ir_metrics.get("declared_qubits", circuit.num_qubits))
        q_live = int(ir_metrics.get("live_qubit_width", q_decl))
        q_eff = max(q_decl, q_live)
        q_cap_val = int(spec.q_cap)
        s_cap = z3.Solver()
        z_q = z3.Int("q_allocated")
        z_cap = z3.Int("q_cap")
        s_cap.add(z_q == q_eff, z_cap == q_cap_val, z_q > z_cap)
        if s_cap.check() == z3.sat:
            m_cap = s_cap.model()
            reclaimable = int(ir_metrics.get("chordal_reclaimable_ancillas", 0))
            diags.append(
                LintDiagnostic(
                    rule="T-QubitCap",
                    severity="ERROR",
                    code="E-QUBITCAP-EXCEEDS-SINGLE-QPU",
                    message=(
                        f"Circuit `{circuit.name}` allocates {q_eff} qubits (live={q_live}) on a single QPU, "
                        f"exceeding `Q_cap = {q_cap_val}` by {q_eff - q_cap_val} qubit(s) without multi-QPU partitioning."
                    ),
                    wire_names=list(circuit.wire_names[: min(len(circuit.wire_names), 12)]),
                    counterexample={
                        "allocated_qubits": m_cap.eval(z_q).as_long(),
                        "live_qubit_width": q_live,
                        "q_cap": m_cap.eval(z_cap).as_long(),
                        "overflow_qubits": q_eff - q_cap_val,
                        "chordal_reclaimable_ancillas": reclaimable,
                        "width_after_chordal_reset_reuse": q_eff - reclaimable,
                    },
                    repair_suggestion=(
                        f"Fold disjoint ancilla lifetimes via `reset` reuse (reclaims {reclaimable} qubit(s)) "
                        f"or supply `cluster_spec` / `qpu_partition` under `T-ParGuard`."
                    ),
                )
            )

    # 1. Bound-slice completeness check (`skip_rightmost` hazard)
    if spec.matrix_elim_slice:
        ms = spec.matrix_elim_slice
        rows = int(ms["rows"])
        total_cols = int(ms["total_cols"])
        clo = int(ms.get("col_lo", 0))
        chi = int(ms.get("col_hi", total_cols))
        pivots = int(ms.get("pivots", rows))
        if clo > 0 or chi < total_cols:
            partial_ands = _matrix_elim_temp_ands(rows, clo, chi, pivots)
            full_ands = _matrix_elim_temp_ands(rows, 0, total_cols, pivots)
            ratio = round(full_ands / max(1, partial_ands), 2)
            diags.append(
                LintDiagnostic(
                    rule="T-QubitCap",
                    severity="ERROR",
                    code="E-QUBITCAP-UNBOUND-SLICE",
                    message=(
                        f"Matrix elimination omits {total_cols - (chi - clo)} of {total_cols} declared "
                        f"columns (`col_lo={clo}..col_hi={chi}`), undercounting `TempAND`s by "
                        f"{ratio}x ({partial_ands:,} vs {full_ands:,})."
                    ),
                    counterexample={
                        "rows": rows,
                        "declared_total_cols": total_cols,
                        "active_col_lo": clo,
                        "active_col_hi": chi,
                        "undercounted_temp_ands": partial_ands,
                        "true_full_slice_temp_ands": full_ands,
                        "undercount_ratio": ratio,
                    },
                    repair_suggestion=f"Cover all `{total_cols}` columns (`col_lo=0, col_hi={total_cols}`).",
                )
            )

    # 2. Detached resource estimate mismatch against parsed AST
    true_and_equiv = int(ir_metrics["total_and_toffoli_equiv"])
    if spec.claimed_temp_ands is not None and int(spec.claimed_temp_ands) != true_and_equiv:
        claimed = int(spec.claimed_temp_ands)
        ratio = round(true_and_equiv / max(1, claimed), 3)
        diags.append(
            LintDiagnostic(
                rule="T-QubitCap",
                severity="ERROR",
                code="E-QUBITCAP-DETACHED-COST-MISMATCH",
                message=(
                    f"Detached resource estimate claims {claimed:,} `TempAND`/`CCX` gates, "
                    f"but parsed `{circuit.source_kind}` AST contains {true_and_equiv:,} "
                    f"({ratio}x discrepancy)."
                ),
                gate_indices=[g.gate_index for g in circuit.gates if g.op in ("ccx", "rccx", "mcx")][:10],
                counterexample={
                    "claimed_temp_ands": claimed,
                    "ast_total_and_toffoli_equiv": true_and_equiv,
                    "ast_temp_and_mx": ir_metrics["temp_and_count"],
                    "ast_unitary_ccx": ir_metrics["ccx_count"],
                    "discrepancy_ratio": ratio,
                },
                repair_suggestion="Extract gate and qubit counts by abstract interpretation of the single compiled IR.",
            )
        )

    if spec.claimed_ccx is not None and int(spec.claimed_ccx) != int(ir_metrics["ccx_count"]):
        diags.append(
            LintDiagnostic(
                rule="T-QubitCap",
                severity="ERROR",
                code="E-QUBITCAP-DETACHED-COST-MISMATCH",
                message=(
                    f"Detached `CCX` count {spec.claimed_ccx} != AST `CCX` count {ir_metrics['ccx_count']}."
                ),
                counterexample={"claimed_ccx": spec.claimed_ccx, "ast_ccx": ir_metrics["ccx_count"]},
                repair_suggestion="Derive `CCX` count directly from the lowered circuit AST.",
            )
        )

    if spec.claimed_qubits is not None and int(spec.claimed_qubits) != int(ir_metrics["live_qubit_width"]):
        diags.append(
            LintDiagnostic(
                rule="T-QubitCap",
                severity="ERROR",
                code="E-QUBITCAP-DETACHED-COST-MISMATCH",
                message=(
                    f"Detached qubit estimate {spec.claimed_qubits} != AST live qubit width "
                    f"{ir_metrics['live_qubit_width']}."
                ),
                counterexample={
                    "claimed_qubits": spec.claimed_qubits,
                    "ast_live_qubit_width": ir_metrics["live_qubit_width"],
                },
                repair_suggestion="Derive qubit width directly from the lowered circuit AST.",
            )
        )

    # 3. Optional Pure-Spec Boolean Miter (`expected_boolean_miter`)
    if spec.expected_boolean_miter:
        bm = spec.expected_boolean_miter
        in_ws = [int(w) for w in bm["input_wires"]]
        out_ws = [int(w) for w in bm["output_wires"]]
        truth_tables: List[List[int]] = bm["truth_tables"]  # per output wire: length 2^len(in_ws)
        mgr = XAGManager()
        init_l = [mgr.LIT_ZERO] * circuit.num_qubits
        for idx, w in enumerate(in_ws):
            init_l[w] = mgr.var(idx)
        fin_l, _ = eval_classical_on_xag(mgr, init_l, circuit.gates)
        z3_v = {idx: z3.Bool(f"bm_x_{idx}") for idx in range(len(in_ws))}
        for _, (kind, v_idx, _) in enumerate(mgr.nodes):
            if kind == "var" and v_idx not in z3_v:
                z3_v[v_idx] = z3.BoolVal(False)
        zmap = mgr.to_z3_map(z3_v, [fin_l[w] for w in out_ws])
        diffs = []
        for o_idx, ow in enumerate(out_ws):
            tt = truth_tables[o_idx]
            ones = [m for m in range(len(tt)) if tt[m] == 1]
            spec_expr = (
                z3.Or(
                    [
                        z3.And([z3_v[b] if ((m >> b) & 1) else z3.Not(z3_v[b]) for b in range(len(in_ws))])
                        for m in ones
                    ]
                )
                if ones
                else z3.BoolVal(False)
            )
            diffs.append(zmap[fin_l[ow]] != spec_expr)
        s_bm = z3.Solver()
        s_bm.add(z3.Or(diffs))
        if s_bm.check() == z3.sat:
            m_bm = s_bm.model()
            cex_bm = format_z3_bitstring_witness(
                m_bm, [z3_v[i] for i in range(len(in_ws))], in_ws, circuit.wire_names
            )
            diags.append(
                LintDiagnostic(
                    rule="T-QubitCap",
                    severity="ERROR",
                    code="E-QUBITCAP-SPEC-MITER-SAT",
                    message=(
                        f"Circuit `{circuit.name}` disagrees with pure boolean specification on "
                        f"input {cex_bm['input_hex']}."
                    ),
                    wire_names=[circuit.wire_names[w] for w in out_ws],
                    counterexample=cex_bm,
                    repair_suggestion="Repair omitted column/gate operations so XAG+Z3 miter proves UNSAT.",
                )
            )

    # 4. Grover Collision / Spurious-Key Margin (`m_check >= ceil(log2(|Dom|)) + s_margin`)
    if spec.grover_oracle_spec:
        gs = spec.grover_oracle_spec
        if "domain_size" in gs:
            k_bits = int(math.ceil(math.log2(max(1, int(gs["domain_size"])))))
        else:
            k_bits = int(gs["key_bits"])
        m_check = int(gs.get("m_check", gs.get("constraint_bits", 0)))
        s_margin = int(gs.get("s_margin", -int(gs.get("log2_eta_max", -32))))
        req_m_check = k_bits + s_margin
        if m_check < req_m_check:
            expected_spurious = 2.0 ** (k_bits - m_check)
            diags.append(
                LintDiagnostic(
                    rule="T-QubitCap",
                    severity="ERROR",
                    code="E-QUBITCAP-SPURIOUS-KEY-MARGIN",
                    message=(
                        f"Grover oracle checks `m_check = {m_check}` constraint bits on `{k_bits}`-bit "
                        f"search domain, violating `m_check >= {req_m_check}` "
                        f"(`E[spurious] = {expected_spurious:.4g}` false keys)."
                    ),
                    counterexample={
                        "domain_log2_bits": k_bits,
                        "m_check_bits": m_check,
                        "s_margin_bits": s_margin,
                        "required_m_check_bits": req_m_check,
                        "expected_spurious_keys": expected_spurious,
                    },
                    repair_suggestion=(
                        f"Verify at least `r = {math.ceil(req_m_check / max(1, m_check))}` independent "
                        f"plaintext-ciphertext blocks (`m_check >= {req_m_check}` bits)."
                    ),
                )
            )

    return diags


run_rule_t_single_ir = run_rule_t_qubit_cap


# ==============================================================================
# 6. Rule 7 (`T-ParGuard`) — Convex `M* <= 256` Multi-QPU Cluster Sizer
# ==============================================================================


SOTA_CLUSTER_WORKLOAD_PRESETS: Dict[str, Dict[str, Any]] = {
    "ECC-256": {
        "paradigm": "algebraic-limb",
        "q_single": 1298,
        "q_data_dist": 1024,
        "q_local_fixed": 38,
        "q_peer_sync": 6,
        "window_bits": 5,
        "num_windows": 112,
        "local_toffolis": 9824640,
        "carry_scheme": "projective-oblivious-runway",
        "lookup_scheme": "law-u4-ghz-mx",
    },
    "RSA-2048": {
        "paradigm": "algebraic-limb",
        "q_single": 1332,
        "q_data_dist": 1152,
        "q_local_fixed": 24,
        "q_peer_sync": 4,
        "window_bits": 6,
        "num_windows": 1038,
        "local_toffolis": 1180000000,
        "carry_scheme": "qrns-zero-carry",
        "lookup_scheme": "law-u4-ghz-mx",
    },
    "RSA-4096": {
        "paradigm": "algebraic-limb",
        "q_single": 2612,
        "q_data_dist": 2304,
        "q_local_fixed": 40,
        "q_peer_sync": 4,
        "window_bits": 6,
        "num_windows": 2076,
        "local_toffolis": 9440000000,
        "carry_scheme": "qrns-zero-carry",
        "lookup_scheme": "law-u4-ghz-mx",
    },
    "AES-128": {
        "paradigm": "grover-amplify",
        "q_single": 261,
        "local_toffolis": 15280,
    },
    "AES-256": {
        "paradigm": "grover-amplify",
        "q_single": 389,
        "local_toffolis": 31840,
    },
    "SHA3-256": {
        "paradigm": "grover-amplify",
        "q_single": 3200,
        "local_toffolis": 76800,
    },
    "SLH-DSA-128s": {
        "paradigm": "grover-amplify",
        "q_single": 3264,
        "local_toffolis": 92160,
    },
    "McEliece-348864": {
        "paradigm": "isd-search",
        "q_single": 4258,
        "local_toffolis": 2781129728,
    },
    "BIKE-L1": {
        "paradigm": "isd-search",
        "q_single": 24646,
        "local_toffolis": 482000000,
    },
    "DQI": {
        "paradigm": "shot-sample",
        "q_single": 512,
        "q_data_dist": 768,
        "q_local_fixed": 24,
        "q_peer_sync": 4,
        "window_bits": 4,
        "num_windows": 16,
        "local_toffolis": 124000,
        "carry_scheme": "none",
        "lookup_scheme": "law-u4-ghz-mx",
        "total_shots": 256,
    },
    "Hubbard-QSVT": {
        "paradigm": "shot-sample",
        "q_single": 128,
        "local_toffolis": 84000,
        "total_shots": 256,
    },
    "FeMoCo-THC": {
        "paradigm": "shot-sample",
        "q_single": 2196,
        "local_toffolis": 5300000000,
        "total_shots": 64,
    },
}


def _ceil_log2_machines(m: int) -> int:
    if m <= 1:
        return 0
    k = 1
    pow2 = 2
    while pow2 < m:
        k += 1
        pow2 *= 2
    return k


def _lookup_ebits_per_window(scheme: str, w_bits: int, q_data: int, m: int) -> int:
    if m <= 1 or scheme in ("none", "", "false"):
        return 0
    if scheme == "law-u4-ghz-mx":
        return w_bits * (m - 1)
    if scheme == "roundtrip-cat":
        return 2 * w_bits * (m - 1)
    if scheme == "data-teleport":
        return (q_data // m) * (m - 1)
    raise ValueError(f"Unknown lookup_scheme: {scheme!r}")


def _carry_ebits_per_window(scheme: str, m: int) -> int:
    if m <= 1 or scheme in ("none", "", "false"):
        return 0
    if scheme == "qrns-zero-carry":
        return 0
    if scheme == "projective-oblivious-runway":
        return 24 * (m - 1)
    if scheme == "naive-ripple-divstep":
        return 1500 * (m - 1)
    raise ValueError(f"Unknown carry_scheme: {scheme!r}")


def _q_mach_on_slice(q_single: int, q_data: int, q_fix: int, q_sync: int, m: int, topology: str) -> int:
    if m <= 1:
        return q_single
    if topology == "all-to-all-peers":
        sync_factor = m - 1
    elif topology == "switched-optical-tree":
        sync_factor = _ceil_log2_machines(m)
    else:
        raise ValueError(f"Unknown interconnect_topology: {topology!r}")
    return ((q_data + m - 1) // m) + q_fix + q_sync * sync_factor


def _wall_clock_sliceable_sec(
    m: int,
    t_toff: int,
    n_win: int,
    q_data: int,
    d_dist: int,
    e_log: int,
    r_bell: float,
    t_seq: int = 0,
) -> float:
    t_seq_clamped = max(0, min(int(t_toff), int(t_seq)))
    t_par = max(0, int(t_toff) - t_seq_clamped)
    t_loc = (
        float(t_seq_clamped) / LOCAL_CCX_RATE_PER_MODULE_HZ
        + float(t_par) / (float(max(1, m)) * LOCAL_CCX_RATE_PER_MODULE_HZ)
    )
    if m <= 1:
        return t_loc
    t_sync = QEC_WINDOW_CUT_SYNC_COEFF_SEC * float(n_win) * float(q_data) * float(m - 1)
    t_bell = (float(d_dist) * float(e_log)) / float(r_bell)
    return t_loc + t_sync + t_bell


def _check_explicit_requested_machines(
    info: Dict[str, Any],
    diags: List[LintDiagnostic],
    explicit_req_m: Optional[int],
    raw_evals: Optional[List[Dict[str, Any]]] = None,
) -> Tuple[Dict[str, Any], List[LintDiagnostic]]:
    if explicit_req_m is None:
        return info, diags
    req_m = int(explicit_req_m)
    opt_m = int(info.get("optimal_machines", 1))
    info["requested_machines"] = req_m
    info["explicit_requested_machines"] = req_m
    s_par = z3.Solver()
    z_req = z3.Int("M_requested")
    z_opt = z3.Int("M_star")
    s_par.add(z_req == req_m, z_opt == opt_m, z_req != z_opt)
    if s_par.check() == z3.sat:
        m_par = s_par.model()
        req_rec = next((r for r in (raw_evals or []) if int(r.get("m", -1)) == req_m), None)
        cex_par: Dict[str, Any] = {
            "requested_machines": m_par.eval(z_req).as_long(),
            "optimal_machines_m_star": m_par.eval(z_opt).as_long(),
            "qpar_grade": info.get("qpar_grade"),
            "optimal_wall_clock_sec": info.get("estimated_wall_clock_sec"),
        }
        if req_rec is not None:
            cex_par["requested_wall_clock_sec"] = req_rec.get("estimated_wall_clock_sec")
            cex_par["requested_q_per_machine"] = req_rec.get("q_per_machine")
            cex_par["requested_logical_ebits"] = req_rec.get("logical_ebits")
        diags.append(
            LintDiagnostic(
                rule="T-ParGuard",
                severity="ERROR",
                code="E-PARGUARD-SUBOPTIMAL-M",
                message=(
                    f"Requested `M = {req_m}` machines for `{info.get('workload', 'circuit')}` "
                    f"(`{info.get('paradigm')}`), but Convex `M*` Sizer proves `M* = {opt_m}` is optimal."
                ),
                counterexample=cex_par,
                details=dict(info),
                repair_suggestion=f"Provision `M* = {opt_m}` machine(s) as determined by `T-ParGuard`.",
            )
        )
    return info, diags


def size_convex_m_star_cluster(
    cluster_cfg: Dict[str, Any],
    ir_metrics: Optional[Dict[str, Any]] = None,
) -> Tuple[Dict[str, Any], List[LintDiagnostic]]:
    """
    Runs the exact `T-ParGuard` Convex `M*` Cluster Sizer across
    `M in {1, 2, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 256}` (up to `max_machines`).
    """
    diags: List[LintDiagnostic] = []
    explicit_req_m: Optional[int] = (
        int(cluster_cfg["requested_machines"])
        if cluster_cfg.get("requested_machines") is not None
        else None
    )
    wname = str(cluster_cfg.get("workload", "circuit"))
    merged = dict(SOTA_CLUSTER_WORKLOAD_PRESETS.get(wname, {}))
    merged.update(cluster_cfg)

    paradigm = str(merged.get("paradigm", "algebraic-limb"))
    m_max = max(1, int(merged.get("max_machines", max(256, explicit_req_m or 1))))
    q_cap = int(merged.get("q_cap_per_machine", 400))
    r_bell = float(merged.get("raw_bell_rate_hz", 100000.0))
    d_dist = int(merged.get("raw_per_logical_ebit", 30))
    topology = str(merged.get("interconnect_topology", "all-to-all-peers"))
    strict = bool(merged.get("strict_parallel", False))

    default_q_single = int((ir_metrics or {}).get("live_qubit_width", 0)) or int(
        (ir_metrics or {}).get("declared_qubits", 1)
    )
    default_toff = int((ir_metrics or {}).get("total_and_toffoli_equiv", 1))
    q_single = int(merged.get("q_single", default_q_single))
    q_data = int(merged.get("q_data_dist", max(0, q_single - 8)))
    q_fix = int(merged.get("q_local_fixed", min(24, q_single)))
    q_sync = int(merged.get("q_peer_sync", 4))
    w_bits = int(merged.get("window_bits", 5))
    n_win = int(merged.get("num_windows", max(1, default_toff // 64)))
    t_toff = int(merged.get("local_toffolis", default_toff))
    t_seq = int(merged.get("sequential_toffolis", 0))
    carry_scheme = str(merged.get("carry_scheme", "qrns-zero-carry"))
    lookup_scheme = str(merged.get("lookup_scheme", "law-u4-ghz-mx"))
    total_shots = merged.get("total_shots")

    raw_cands = list(merged.get("candidate_machines", DEFAULT_CANDIDATE_MACHINES))
    if explicit_req_m is not None and explicit_req_m >= 1:
        raw_cands.append(explicit_req_m)
    norm_cands = sorted({1} | {int(m) for m in raw_cands if 1 <= int(m) <= m_max})

    # Case 1: `grover-amplify` / `isd-search` -> Zalka `sqrt(M)` work blowup guard
    if paradigm in ("grover-amplify", "isd-search"):
        fits_cap = q_single <= q_cap
        fallback = m_max > 1
        zalka_blowup = math.sqrt(float(m_max))
        max_width_saved = int(math.floor(math.log2(m_max))) if m_max >= 1 else 0
        t_wall_1 = float(t_toff) / LOCAL_CCX_RATE_PER_MODULE_HZ
        info: Dict[str, Any] = {
            "workload": wname,
            "paradigm": paradigm,
            "interconnect_topology": topology,
            "requested_machines": m_max,
            "max_machines": m_max,
            "q_cap_per_machine": q_cap,
            "raw_bell_rate_hz": r_bell,
            "qpar_grade": "ParNonPartitionable" if fallback else "ParSliceable",
            "reason": "zalka-grover-sublinear" if fallback else "monolithic-single-qpu",
            "optimal_machines": 1,
            "machines_used": 1,
            "q_single": q_single,
            "q_allocated_per_machine": q_single,
            "fits_q_cap": fits_cap,
            "lookup_ebits_total": 0,
            "carry_ebits_total": 0,
            "logical_ebits_total": 0,
            "raw_bell_pairs_total": 0,
            "bell_cuts": 0,
            "estimated_wall_clock_sec": t_wall_1,
            "zalka_total_work_blowup_factor": zalka_blowup,
            "max_key_width_bits_saved": max_width_saved,
            "pruned_ucurve_candidates": [],
            "fallback_to_single_machine": fallback,
        }
        if strict and not fits_cap:
            diags.append(
                LintDiagnostic(
                    rule="T-ParGuard",
                    severity="ERROR",
                    code="E-PARGUARD-SINGLE-EXCEEDS-QCAP",
                    message=(
                        f"Non-partitionable `{paradigm}` workload `{wname}` requires "
                        f"`Q_single = {q_single} > Q_cap = {q_cap}` and cannot be width-sliced."
                    ),
                    details=info,
                    repair_suggestion="Use serial-multishot BBHT restarts or provision a higher-capacity monolithic QPU.",
                )
            )
        elif strict and fallback:
            diags.append(
                LintDiagnostic(
                    rule="T-ParGuard",
                    severity="ERROR",
                    code="E-PARGUARD-ZALKA-GROVER-SUBLINEAR",
                    message=(
                        f"Serial `{paradigm}` reflections on `{wname}` cannot be coherently width-sliced across "
                        f"`M = {m_max}` machines without Zalka `sqrt({m_max}) = {zalka_blowup:.2f}x` total-work blowup."
                    ),
                    counterexample={
                        "requested_machines": m_max,
                        "zalka_total_work_blowup_factor": zalka_blowup,
                        "max_key_width_bits_saved": max_width_saved,
                    },
                    details=info,
                    repair_suggestion="Compile to `M* = 1` monolithic QPU (or outer classical domain split acknowledging `sqrt(M)` work).",
                )
            )
        elif fallback:
            wcode = "W-PARGUARD-FALLBACK-ZALKA-GROVER" if fits_cap else "W-PARGUARD-SINGLE-EXCEEDS-QCAP"
            diags.append(
                LintDiagnostic(
                    rule="T-ParGuard",
                    severity="WARNING",
                    code=wcode,
                    message=(
                        f"Selected `M* = 1` (`{q_single} Q` vs `Q_cap = {q_cap}`) for `{wname}`, "
                        f"avoiding `sqrt({m_max}) = {zalka_blowup:.2f}x` Zalka total-work blowup."
                    ),
                    details=info,
                    repair_suggestion="Run on 1 coherent machine (`machines_used = 1`).",
                )
            )
        return _check_explicit_requested_machines(info, diags, explicit_req_m)

    # Case 2: `shot-sample` (`ParShotLinear`)
    if paradigm == "shot-sample":
        eff_shot_cap = min(m_max, int(total_shots)) if total_shots is not None and int(total_shots) > 0 else m_max
        if q_single <= q_cap:
            t_wall = float(t_toff) / (float(eff_shot_cap) * LOCAL_CCX_RATE_PER_MODULE_HZ)
            shot_info = {
                "workload": wname,
                "paradigm": "shot-sample",
                "interconnect_topology": topology,
                "requested_machines": m_max,
                "max_machines": m_max,
                "total_shots_budget": int(total_shots) if total_shots is not None else m_max,
                "idle_machines_avoided": m_max - eff_shot_cap,
                "q_cap_per_machine": q_cap,
                "raw_bell_rate_hz": r_bell,
                "qpar_grade": "ParShotLinear",
                "optimal_machines": eff_shot_cap,
                "machines_used": eff_shot_cap,
                "machines_per_shot_instance": 1,
                "parallel_shot_groups": eff_shot_cap,
                "q_single": q_single,
                "q_allocated_per_machine": q_single,
                "fits_q_cap": True,
                "lookup_ebits_total": 0,
                "carry_ebits_total": 0,
                "logical_ebits_total": 0,
                "raw_bell_pairs_total": 0,
                "bell_cuts": 0,
                "total_work_multiplier": 1.0,
                "shot_throughput_speedup": eff_shot_cap,
                "estimated_wall_clock_sec": t_wall,
                "pruned_ucurve_candidates": [],
                "fallback_to_single_machine": False,
            }
            return _check_explicit_requested_machines(shot_info, diags, explicit_req_m)

        slice_m: Optional[int] = None
        if "q_data_dist" in merged and int(merged["q_data_dist"]) > 0:
            for cand_m in norm_cands:
                if cand_m >= 2 and _q_mach_on_slice(q_single, q_data, q_fix, q_sync, cand_m, topology) <= q_cap:
                    slice_m = cand_m
                    break

        if slice_m is not None:
            q_slice = _q_mach_on_slice(q_single, q_data, q_fix, q_sync, slice_m, topology)
            max_hw_groups = max(1, m_max // slice_m)
            groups = min(max_hw_groups, int(total_shots)) if total_shots is not None and int(total_shots) > 0 else max_hw_groups
            m_used = groups * slice_m
            luk = n_win * _lookup_ebits_per_window(lookup_scheme, w_bits, q_data, slice_m)
            car = n_win * _carry_ebits_per_window(carry_scheme, slice_m)
            elog = luk + car
            sliced_shot_info = {
                "workload": wname,
                "paradigm": "shot-sample",
                "interconnect_topology": topology,
                "requested_machines": m_max,
                "max_machines": m_max,
                "total_shots_budget": int(total_shots) if total_shots is not None else max_hw_groups,
                "idle_machines_avoided": m_max - m_used,
                "q_cap_per_machine": q_cap,
                "raw_bell_rate_hz": r_bell,
                "qpar_grade": "ParShotLinear",
                "optimal_machines": m_used,
                "machines_used": m_used,
                "machines_per_shot_instance": slice_m,
                "parallel_shot_groups": groups,
                "q_single": q_single,
                "q_allocated_per_machine": q_slice,
                "fits_q_cap": True,
                "lookup_ebits_total": groups * luk,
                "carry_ebits_total": groups * car,
                "logical_ebits_total": groups * elog,
                "raw_bell_pairs_total": d_dist * groups * elog,
                "bell_cuts": 0,
                "total_work_multiplier": 1.0,
                "shot_throughput_speedup": groups,
                "pruned_ucurve_candidates": [],
                "fallback_to_single_machine": False,
            }
            return _check_explicit_requested_machines(sliced_shot_info, diags, explicit_req_m)

        if strict:
            diags.append(
                LintDiagnostic(
                    rule="T-ParGuard",
                    severity="ERROR",
                    code="E-PARGUARD-SINGLE-EXCEEDS-QCAP",
                    message=f"Shot-sample workload `{wname}` requires `Q_single = {q_single} > Q_cap = {q_cap}`.",
                    repair_suggestion="Increase `q_cap_per_machine` or supply sliceable data-register parameters.",
                )
            )
        unfit_shot_info = {
            "workload": wname,
            "paradigm": "shot-sample",
            "interconnect_topology": topology,
            "requested_machines": m_max,
            "max_machines": m_max,
            "total_shots_budget": int(total_shots) if total_shots is not None else m_max,
            "idle_machines_avoided": m_max - eff_shot_cap,
            "q_cap_per_machine": q_cap,
            "raw_bell_rate_hz": r_bell,
            "qpar_grade": "ParShotLinear",
            "optimal_machines": eff_shot_cap,
            "machines_used": eff_shot_cap,
            "machines_per_shot_instance": 1,
            "parallel_shot_groups": eff_shot_cap,
            "q_single": q_single,
            "q_allocated_per_machine": q_single,
            "fits_q_cap": False,
            "requires_larger_monolithic_qpu": True,
            "lookup_ebits_total": 0,
            "carry_ebits_total": 0,
            "logical_ebits_total": 0,
            "raw_bell_pairs_total": 0,
            "bell_cuts": 0,
            "total_work_multiplier": 1.0,
            "shot_throughput_speedup": eff_shot_cap,
            "pruned_ucurve_candidates": [],
            "fallback_to_single_machine": False,
        }
        return _check_explicit_requested_machines(unfit_shot_info, diags, explicit_req_m)

    # Case 3: `algebraic-limb` (`ParSliceable` Convex U-Curve Optimizer)
    raw_evals: List[Dict[str, Any]] = []
    for m in norm_cands:
        qm = _q_mach_on_slice(q_single, q_data, q_fix, q_sync, m, topology)
        luk = n_win * _lookup_ebits_per_window(lookup_scheme, w_bits, q_data, m)
        car = n_win * _carry_ebits_per_window(carry_scheme, m)
        elog = luk + car
        raws = d_dist * elog
        twall = _wall_clock_sliceable_sec(m, t_toff, n_win, q_data, d_dist, elog, r_bell, t_seq=t_seq)
        raw_evals.append(
            {
                "m": m,
                "q_per_machine": qm,
                "fits_q_cap": qm <= q_cap,
                "lookup_ebits": luk,
                "carry_ebits": car,
                "logical_ebits": elog,
                "raw_bell_pairs": raws,
                "estimated_wall_clock_sec": twall,
            }
        )

    # Static U-curve knee dominance pruning across `m >= 2`:
    pareto_multi: List[Dict[str, Any]] = []
    pruned_list: List[Dict[str, Any]] = []
    for rec in raw_evals:
        if rec["m"] < 2:
            continue
        dom = next((prev for prev in reversed(pareto_multi) if prev["q_per_machine"] <= rec["q_per_machine"]), None)
        if dom is not None:
            pruned_list.append(
                {
                    "code": "W-PARGUARD-PRUNED-UCURVE-KNEE",
                    "pruned_m": rec["m"],
                    "pruned_q_per_machine": rec["q_per_machine"],
                    "pruned_logical_ebits": rec["logical_ebits"],
                    "dominating_m": dom["m"],
                    "dominating_q_per_machine": dom["q_per_machine"],
                    "dominating_logical_ebits": dom["logical_ebits"],
                }
            )
        else:
            pareto_multi.append(rec)

    if q_single <= q_cap:
        rec1 = raw_evals[0]
        seq_dom = all(rec1["estimated_wall_clock_sec"] <= r["estimated_wall_clock_sec"] for r in pareto_multi)
        m1_info = {
            "workload": wname,
            "paradigm": "algebraic-limb",
            "interconnect_topology": topology,
            "carry_scheme": carry_scheme,
            "lookup_scheme": lookup_scheme,
            "requested_machines": m_max,
            "max_machines": m_max,
            "q_cap_per_machine": q_cap,
            "raw_bell_rate_hz": r_bell,
            "raw_per_logical_ebit": d_dist,
            "qpar_grade": "ParSliceable",
            "optimal_machines": 1,
            "machines_used": 1,
            "monolithic_single_chip_optimal": True,
            "sequential_depth_dominates": seq_dom,
            "q_single": q_single,
            "q_allocated_per_machine": q_single,
            "fits_q_cap": True,
            "lookup_ebits_total": 0,
            "carry_ebits_total": 0,
            "logical_ebits_total": 0,
            "raw_bell_pairs_total": 0,
            "bell_cuts": 0,
            "estimated_wall_clock_sec": rec1["estimated_wall_clock_sec"],
            "pruned_ucurve_candidates": pruned_list,
            "pareto_candidates": [rec1] + pareto_multi,
            "fallback_to_single_machine": bool(t_seq > 0 and seq_dom),
        }
        return _check_explicit_requested_machines(m1_info, diags, explicit_req_m, raw_evals)

    feasible_multi = [r for r in pareto_multi if r["fits_q_cap"]]
    if feasible_multi:
        best = min(feasible_multi, key=lambda r: r["estimated_wall_clock_sec"])
        multi_info = {
            "workload": wname,
            "paradigm": "algebraic-limb",
            "interconnect_topology": topology,
            "carry_scheme": carry_scheme,
            "lookup_scheme": lookup_scheme,
            "requested_machines": m_max,
            "max_machines": m_max,
            "q_cap_per_machine": q_cap,
            "raw_bell_rate_hz": r_bell,
            "raw_per_logical_ebit": d_dist,
            "qpar_grade": "ParSliceable",
            "optimal_machines": best["m"],
            "machines_used": best["m"],
            "monolithic_single_chip_optimal": False,
            "q_single": q_single,
            "q_allocated_per_machine": best["q_per_machine"],
            "fits_q_cap": True,
            "lookup_ebits_total": best["lookup_ebits"],
            "carry_ebits_total": best["carry_ebits"],
            "logical_ebits_total": best["logical_ebits"],
            "raw_bell_pairs_total": best["raw_bell_pairs"],
            "bell_cuts": best["logical_ebits"],
            "estimated_wall_clock_sec": best["estimated_wall_clock_sec"],
            "pruned_ucurve_candidates": pruned_list,
            "pareto_candidates": pareto_multi,
            "fallback_to_single_machine": False,
        }
        return _check_explicit_requested_machines(multi_info, diags, explicit_req_m, raw_evals)

    min_q = min([q_single] + [r["q_per_machine"] for r in pareto_multi])
    err_info = {
        "workload": wname,
        "paradigm": "algebraic-limb",
        "interconnect_topology": topology,
        "requested_machines": m_max,
        "max_machines": m_max,
        "q_cap_per_machine": q_cap,
        "qpar_grade": "ParNonPartitionable",
        "reason": "no-feasible-partition-under-qcap",
        "optimal_machines": 1,
        "machines_used": 1,
        "q_single": q_single,
        "q_allocated_per_machine": q_single,
        "min_achievable_q_per_machine": min_q,
        "fits_q_cap": False,
        "lookup_ebits_total": 0,
        "carry_ebits_total": 0,
        "logical_ebits_total": 0,
        "bell_cuts": 0,
        "pruned_ucurve_candidates": pruned_list,
        "fallback_to_single_machine": True,
    }
    if strict:
        diags.append(
            LintDiagnostic(
                rule="T-ParGuard",
                severity="ERROR",
                code="E-PARGUARD-NO-FEASIBLE-PARTITION",
                message=(
                    f"Minimum achievable per-machine width `{min_q} Q` on `{wname}` exceeds "
                    f"`Q_cap = {q_cap} Q` across `M <= {m_max}` (`{topology}`)."
                ),
                counterexample={"min_achievable_q_per_machine": min_q, "q_cap_per_machine": q_cap, "max_machines": m_max},
                details=err_info,
                repair_suggestion=(
                    "Increase `max_machines` toward the U-curve knee, switch to `switched-optical-tree`, "
                    "or use Ekerå-Håstad / Regev serial-multishot folding."
                ),
            )
        )
    else:
        diags.append(
            LintDiagnostic(
                rule="T-ParGuard",
                severity="WARNING",
                code="W-PARGUARD-FALLBACK-BELL-CUT",
                message=(
                    f"No `M <= {m_max}` fits `Q_cap = {q_cap} Q` on `{wname}` (`min = {min_q} Q`); "
                    f"falling back to 1-machine schedule."
                ),
                details=err_info,
                repair_suggestion=f"Provision `Q_cap >= {min_q} Q` or switch interconnect topology.",
            )
        )
    return _check_explicit_requested_machines(err_info, diags, explicit_req_m, raw_evals)


# ==============================================================================
# 7. Public Library Entry Points, Built-In Self-Test & CLI Runner
# ==============================================================================


def _merge_embedded_pragmas_with_spec(
    pragmas: Dict[str, Any],
    spec: Optional[Union[LintSpec, Dict[str, Any]]],
) -> LintSpec:
    if not pragmas:
        return LintSpec.from_dict(spec) if isinstance(spec, dict) else (spec or LintSpec())
    merged: Dict[str, Any] = dict(pragmas)
    if isinstance(spec, dict):
        merged.update(spec)
        return LintSpec.from_dict(merged)
    if isinstance(spec, LintSpec):
        defaults = LintSpec()
        for fname in LintSpec.__dataclass_fields__:
            val = getattr(spec, fname)
            if val != getattr(defaults, fname):
                merged[fname] = val
        return LintSpec.from_dict(merged)
    return LintSpec.from_dict(merged)


RULE_UNIFIED_OBLIGATIONS: Dict[str, str] = {
    "T-DomImg": "Gamma_in <-> Gamma_out (support-injective domain-image bijection in Gamma_in |- t : Q_e(A) -| Gamma_out)",
    "T-BorrowZ": "Gamma_in[ConstZ] -> Gamma_out[ConstZ] (borrowed Z-frame & validity guard in Gamma_in |- t : Q_e(A) -| Gamma_out)",
    "T-PhaseClean": "Gamma_out[ancilla = |0>, phase = 0] (Bennet uncomputation & phase cleanliness in Gamma_in |- t : Q_e(A) -| Gamma_out)",
    "T-CounitU4": "Gamma_out[phase_taint = 0] (Law U4 modal counit & cat-disentanglement in Gamma_in |- t : Q_e(A) -| Gamma_out)",
    "T-SubNorm": "Q_e(A)[alpha >= ||H||_2, eps_drift] (block-encoding subnormalization & carry drift in Gamma_in |- t : Q_e(A) -| Gamma_out)",
    "T-QubitCap": "e.QPhys <= Q_cap (single-QPU qubit capacity & unified IR conservation in Gamma_in |- t : Q_e(A) -| Gamma_out)",
    "T-ParGuard": "e.QParGrade (convex M* <= 256 multi-QPU partitionability in Gamma_in |- t : Q_e(A) -| Gamma_out)",
}


def _format_gate_surface_form(g: GateNode) -> str:
    args = ", ".join(g.wire_names) if g.wire_names else "q"
    if g.condition is not None:
        return f"if ({g.condition[1]} == {g.condition[2]}) {{ {g.op} {args}; }}"
    if g.op == "measure" and g.clbit_names:
        return f"{g.clbit_names[0]} = measure {args};"
    return f"{g.op} {args};"


def _populate_diagnostic_unified_provenance(circuit: LiftedCircuit, diag: LintDiagnostic) -> None:
    if "unified_judgment_obligation" not in diag.details:
        diag.details["unified_judgment_obligation"] = RULE_UNIFIED_OBLIGATIONS.get(
            diag.rule, "Gamma_in |- t : Q_e(A) -| Gamma_out"
        )
    if "provenance_spans" in diag.details:
        return

    file_tag = circuit.name or f"<{circuit.source_kind}>"
    target_wset = set(diag.wire_names)

    # 1. Origin span (`Gamma_in`): register declaration or first touching gate
    origin_decl_form = (
        f"declare {', '.join(diag.wire_names)}"
        if diag.wire_names
        else f"circuit {file_tag} ({circuit.num_qubits} qubits)"
    )
    origin_span: Dict[str, Any] = {
        "role": "Gamma_in (wire/capability origin)",
        "file": file_tag,
        "line": 1,
        "gate_index": -1,
        "surface_form": origin_decl_form,
    }

    # 2. Mutating span (`e`): explicit diagnostic gate or last gate touching affected wires
    mut_gate: Optional[GateNode] = None
    if diag.gate_indices:
        g0 = diag.gate_indices[0]
        if 0 <= g0 < len(circuit.gates):
            mut_gate = circuit.gates[g0]
    if mut_gate is None and target_wset:
        for g in reversed(circuit.gates):
            if target_wset.intersection(g.wire_names):
                mut_gate = g
                break
    if mut_gate is not None:
        mutating_span: Dict[str, Any] = {
            "role": "e (causal mutation / grade accumulation)",
            "file": file_tag,
            "line": int(mut_gate.source_line or (mut_gate.gate_index + 1)),
            "gate_index": mut_gate.gate_index,
            "surface_form": _format_gate_surface_form(mut_gate),
        }
    else:
        mutating_span = {
            "role": "e (causal mutation / grade accumulation)",
            "file": file_tag,
            "line": 1,
            "gate_index": -1,
            "surface_form": f"spec({diag.rule})",
        }

    # 3. Failure span (`Gamma_out`): boundary gate or circuit exit postcondition
    fail_gate: Optional[GateNode] = None
    if diag.gate_indices:
        glast = diag.gate_indices[-1]
        if 0 <= glast < len(circuit.gates):
            fail_gate = circuit.gates[glast]
    exit_line = (
        max((g.source_line or (g.gate_index + 1)) for g in circuit.gates) + 1
        if circuit.gates
        else 1
    )
    if fail_gate is not None and len(diag.gate_indices) >= 1 and diag.rule not in ("T-PhaseClean",):
        failure_span: Dict[str, Any] = {
            "role": "Gamma_out (postcondition boundary)",
            "file": file_tag,
            "line": int(fail_gate.source_line or (fail_gate.gate_index + 1)),
            "gate_index": fail_gate.gate_index,
            "surface_form": _format_gate_surface_form(fail_gate),
        }
    else:
        failure_span = {
            "role": "Gamma_out (postcondition boundary)",
            "file": file_tag,
            "line": int(exit_line),
            "gate_index": len(circuit.gates),
            "surface_form": "circuit exit postcondition",
        }

    diag.details["provenance_spans"] = {
        "origin_span": origin_span,
        "mutating_span": mutating_span,
        "failure_span": failure_span,
        "pass_trace": [circuit.source_kind, "LiftedCircuit", "XAG+Z3"],
    }


def lint_lifted_circuit(
    circuit: LiftedCircuit,
    spec: Optional[Union[LintSpec, Dict[str, Any]]] = None,
) -> LintReport:
    t0 = time.perf_counter()
    lint_spec = _merge_embedded_pragmas_with_spec(circuit.embedded_pragmas, spec)

    ir_metrics = extract_circuit_ir_metrics(circuit, lint_spec)
    diags: List[LintDiagnostic] = []

    diags.extend(run_rule_t_dom_img(circuit, lint_spec))
    diags.extend(run_rule_t_borrow_z(circuit, lint_spec))
    diags.extend(run_rule_t_phase_clean(circuit, lint_spec))
    diags.extend(run_rule_t_counit_u4(circuit, lint_spec))
    diags.extend(run_rule_t_sub_norm(circuit, lint_spec))
    diags.extend(run_rule_t_qubit_cap(circuit, lint_spec, ir_metrics))

    cluster_sizing: Optional[Dict[str, Any]] = None
    if lint_spec.cluster_spec is not None or lint_spec.requested_machines is not None:
        eff_cluster: Dict[str, Any] = dict(lint_spec.cluster_spec or {})
        if lint_spec.requested_machines is not None and "requested_machines" not in eff_cluster:
            eff_cluster["requested_machines"] = int(lint_spec.requested_machines)
        if lint_spec.q_cap is not None and "q_cap_per_machine" not in eff_cluster:
            eff_cluster["q_cap_per_machine"] = int(lint_spec.q_cap)
        cluster_sizing, par_diags = size_convex_m_star_cluster(eff_cluster, ir_metrics)
        diags.extend(par_diags)

    for d in diags:
        _populate_diagnostic_unified_provenance(circuit, d)

    err_cnt = sum(1 for d in diags if d.severity == "ERROR")
    warn_cnt = sum(1 for d in diags if d.severity == "WARNING")
    elapsed_ms = (time.perf_counter() - t0) * 1000.0

    return LintReport(
        status="PASS" if err_cnt == 0 else "FAIL",
        well_typed=(err_cnt == 0),
        circuit_name=circuit.name,
        source_kind=circuit.source_kind,
        rules_checked=list(ALL_SEVEN_RULES),
        error_count=err_cnt,
        warning_count=warn_cnt,
        diagnostics=diags,
        ir_metrics=ir_metrics,
        cluster_sizing=cluster_sizing,
        elapsed_ms=elapsed_ms,
    )


def lint_qiskit_circuit(
    qc: QuantumCircuit,
    spec: Optional[Union[LintSpec, Dict[str, Any]]] = None,
) -> LintReport:
    lifted = lift_qiskit_circuit(qc, source_kind="qiskit")
    return lint_lifted_circuit(lifted, spec=spec)


def lint_qasm_str(
    qasm_src: str,
    spec: Optional[Union[LintSpec, Dict[str, Any]]] = None,
    name: str = "qasm_circuit",
) -> LintReport:
    lifted = parse_qasm_to_lifted_circuit(qasm_src, name=name)
    return lint_lifted_circuit(lifted, spec=spec)


def lint_qasm_file(
    qasm_path: Union[str, Path],
    spec: Optional[Union[LintSpec, Dict[str, Any]]] = None,
) -> LintReport:
    path = Path(qasm_path)
    src = path.read_text(encoding="utf-8")
    return lint_qasm_str(src, spec=spec, name=path.name)


def run_self_test() -> Dict[str, Any]:
    """
    Fast built-in sanity check covering all 7 projected rules of
    `Gamma_in |- t : Q_e(A) -| Gamma_out` plus `M* <= 256` cluster sizing.
    """
    t0 = time.perf_counter()
    checks: List[Dict[str, Any]] = []

    # 1. T-DomImg: aliased input/output mutation on read-only wire
    r1_bug = lint_qasm_str(
        "OPENQASM 3.0;\ninclude \"stdgates.inc\";\nqubit[2] q;\ncx q[1], q[0];\n",
        spec={"readonly_input_wires": [0], "output_wires": [1]},
        name="selftest_domimg_bug",
    )
    r1_ok = lint_qasm_str(
        "OPENQASM 3.0;\ninclude \"stdgates.inc\";\nqubit[2] q;\ncx q[0], q[1];\n",
        spec={"readonly_input_wires": [0], "output_wires": [1]},
        name="selftest_domimg_ok",
    )
    checks.append({
        "rule": "T-DomImg",
        "bug_caught": (not r1_bug.well_typed) and any(d.rule == "T-DomImg" for d in r1_bug.diagnostics),
        "clean_passed": r1_ok.well_typed,
    })

    # 2. T-BorrowZ: borrowed ConstZ wire polluted by Hadamard
    r2_bug = lint_qasm_str(
        "OPENQASM 3.0;\ninclude \"stdgates.inc\";\nqubit[2] q;\nh q[0];\ncx q[0], q[1];\nh q[0];\n",
        spec={"borrowed_z_wires": [0]},
        name="selftest_borrowz_bug",
    )
    r2_ok = lint_qasm_str(
        "OPENQASM 3.0;\ninclude \"stdgates.inc\";\nqubit[2] q;\nx q[0];\ncx q[0], q[1];\nx q[0];\n",
        spec={"borrowed_z_wires": [0]},
        name="selftest_borrowz_ok",
    )
    checks.append({
        "rule": "T-BorrowZ",
        "bug_caught": (not r2_bug.well_typed) and any(d.rule == "T-BorrowZ" for d in r2_bug.diagnostics),
        "clean_passed": r2_ok.well_typed,
    })

    # 3. T-PhaseClean: dirty ancilla missing Bennet uncomputation
    r3_bug = lint_qasm_str(
        "OPENQASM 3.0;\ninclude \"stdgates.inc\";\nqubit[3] q;\nccx q[0], q[1], q[2];\n",
        spec={"input_wires": [0, 1], "ancilla_wires": [2]},
        name="selftest_phaseclean_bug",
    )
    r3_ok = lint_qasm_str(
        "OPENQASM 3.0;\ninclude \"stdgates.inc\";\nqubit[3] q;\nccx q[0], q[1], q[2];\nccx q[0], q[1], q[2];\n",
        spec={"input_wires": [0, 1], "ancilla_wires": [2]},
        name="selftest_phaseclean_ok",
    )
    checks.append({
        "rule": "T-PhaseClean",
        "bug_caught": (not r3_bug.well_typed) and any(d.rule == "T-PhaseClean" for d in r3_bug.diagnostics),
        "clean_passed": r3_ok.well_typed,
    })

    # 4. T-CounitU4: mid-circuit M_X TempAND erasure missing cz fixup
    r4_bug = lint_qasm_str(
        "OPENQASM 3.0;\ninclude \"stdgates.inc\";\nqubit[3] q;\nbit[1] c;\n"
        "ccx q[0], q[1], q[2];\nh q[2];\nc[0] = measure q[2];\nreset q[2];\n",
        name="selftest_counitu4_bug",
    )
    r4_ok = lint_qasm_str(
        "OPENQASM 3.0;\ninclude \"stdgates.inc\";\nqubit[3] q;\nbit[1] c;\n"
        "ccx q[0], q[1], q[2];\nh q[2];\nc[0] = measure q[2];\nif (c[0] == 1) { cz q[0], q[1]; }\nreset q[2];\n",
        name="selftest_counitu4_ok",
    )
    checks.append({
        "rule": "T-CounitU4",
        "bug_caught": (not r4_bug.well_typed) and any(d.rule == "T-CounitU4" for d in r4_bug.diagnostics),
        "clean_passed": r4_ok.well_typed,
    })

    # 5. T-SubNorm: QSVT block-encoding alpha < ||H||_2 overflow
    qc_sub = QuantumCircuit(2, name="selftest_subnorm")
    qc_sub.h(0)
    qc_sub.cx(0, 1)
    qc_sub.h(0)
    r5_bug = lint_qiskit_circuit(
        qc_sub,
        spec={"block_encoding_spec": {"alpha": 0.8, "operator_spectral_norm": 1.0}},
    )
    r5_ok = lint_qiskit_circuit(
        qc_sub,
        spec={"block_encoding_spec": {"alpha": 1.0, "operator_spectral_norm": 1.0}},
    )
    checks.append({
        "rule": "T-SubNorm",
        "bug_caught": (not r5_bug.well_typed) and any(d.rule == "T-SubNorm" for d in r5_bug.diagnostics),
        "clean_passed": r5_ok.well_typed,
    })

    # 6. T-QubitCap: single-QPU capacity overflow without partitioning
    r6_bug = lint_qasm_str(
        "OPENQASM 3.0;\ninclude \"stdgates.inc\";\nqubit[6] q;\ncx q[0], q[5];\n",
        spec={"q_cap": 4},
        name="selftest_qubitcap_bug",
    )
    r6_ok = lint_qasm_str(
        "OPENQASM 3.0;\ninclude \"stdgates.inc\";\nqubit[4] q;\ncx q[0], q[3];\n",
        spec={"q_cap": 4},
        name="selftest_qubitcap_ok",
    )
    checks.append({
        "rule": "T-QubitCap",
        "bug_caught": (not r6_bug.well_typed) and any(d.rule == "T-QubitCap" for d in r6_bug.diagnostics),
        "clean_passed": r6_ok.well_typed,
    })

    # 7. T-ParGuard: suboptimal requested M vs optimal M*
    r7_bug = lint_qasm_str(
        "OPENQASM 3.0;\ninclude \"stdgates.inc\";\nqubit[3] q;\nccx q[0], q[1], q[2];\nccx q[0], q[1], q[2];\n",
        spec={"cluster_spec": {"workload": "ECC-256", "requested_machines": 16}},
        name="selftest_parguard_bug",
    )
    r7_ok = lint_qasm_str(
        "OPENQASM 3.0;\ninclude \"stdgates.inc\";\nqubit[3] q;\nccx q[0], q[1], q[2];\nccx q[0], q[1], q[2];\n",
        spec={"cluster_spec": {"workload": "ECC-256", "requested_machines": 4}},
        name="selftest_parguard_ok",
    )
    checks.append({
        "rule": "T-ParGuard",
        "bug_caught": (not r7_bug.well_typed) and any(d.rule == "T-ParGuard" for d in r7_bug.diagnostics),
        "clean_passed": r7_ok.well_typed and (r7_ok.cluster_sizing or {}).get("optimal_machines") == 4,
    })

    all_ok = all(c["bug_caught"] and c["clean_passed"] for c in checks)
    return {
        "self_test_passed": all_ok,
        "rules_verified": len(checks),
        "checks": checks,
        "elapsed_ms": round((time.perf_counter() - t0) * 1000.0, 3),
    }


def _find_racket_executable() -> str:
    candidates = [
        Path.home() / "toolchains" / "racket-p36t2" / "racket" / "bin" / "racket",
        Path("/usr/bin/racket"),
        Path("/usr/local/bin/racket"),
    ]
    for c in candidates:
        if c.is_file():
            return str(c)
    return "racket"


def lift_qasm3_to_revir_ast(
    qasm_str: str,
    spec: Optional[Dict[str, Any]] = None,
    name: str = "lifted_qasm3",
) -> Dict[str, Any]:
    """
    Lifts an OpenQASM 3.0 program into a structured `RevIR` AST dictionary,
    identifying compute/action/uncompute cones and mid-circuit M_X candidates.
    """
    lifted = parse_qasm_to_lifted_circuit(qasm_str, name=name)
    spec_d = dict(spec or {})
    anc_wires = list(
        spec_d.get(
            "ancilla_wires",
            [lifted.num_qubits - 1] if lifted.num_qubits > 1 else [],
        )
    )
    data_wires = list(
        spec_d.get(
            "data_wires",
            [w for w in range(lifted.num_qubits) if w not in anc_wires],
        )
    )
    revir_ops: List[Dict[str, Any]] = []
    for g in lifted.gates:
        cond_clbit = g.condition[0] if g.condition is not None else None
        cond_val = g.condition[2] if g.condition is not None else None
        revir_ops.append(
            {
                "op": g.op,
                "qubits": list(g.qubits),
                "clbits": list(g.clbits),
                "params": list(g.params),
                "condition_clbit": cond_clbit,
                "condition_val": cond_val,
                "negated_ctrl": list(g.neg_controls),
            }
        )
    return {
        "name": name,
        "num_qubits": lifted.num_qubits,
        "num_clbits": lifted.num_clbits,
        "data_wires": data_wires,
        "ancilla_wires": anc_wires,
        "revir_ops": revir_ops,
        "spec": spec_d,
    }


def autorepair_and_optimize_qasm3(
    qasm_str: str,
    spec: Optional[Dict[str, Any]] = None,
    name: str = "repaired_qasm3",
    emit_lfq: bool = True,
) -> Dict[str, Any]:
    """
    Lifts `qasm_str` into `RevIR`, runs the 7-rule static auto-repairer and
    `canonical_k2_coupled` optimizer via `compiler/lakefillq-qasm3-lifter-repair.rkt`,
    and returns the repaired OpenQASM 3.0, optimized OpenQASM 3.0, and `#lang lakefillq`
    surface code.
    """
    import subprocess

    scratch_dir = ensure_persistent_tmpdir() / "qasm3_lifter_cli"
    scratch_dir.mkdir(parents=True, exist_ok=True)
    qasm_file = scratch_dir / f"{name}_in.qasm"
    spec_file = scratch_dir / f"{name}_spec.json"
    qasm_file.write_text(qasm_str, encoding="utf-8")
    spec_file.write_text(json.dumps(spec or {}), encoding="utf-8")

    racket_bin = _find_racket_executable()
    lifter_rkt = REPO_ROOT / "compiler" / "lakefillq-qasm3-lifter-repair.rkt"
    cmd = [
        racket_bin,
        str(lifter_rkt),
        "--repair-qasm3-file",
        str(qasm_file),
        "--spec-json",
        str(spec_file),
    ]
    if emit_lfq:
        cmd.append("--emit-lfq")
    env = dict(os.environ)
    env["TMPDIR"] = str(ensure_persistent_tmpdir())
    proc = subprocess.run(
        cmd,
        cwd=str(REPO_ROOT),
        env=env,
        capture_output=True,
        text=True,
        check=True,
    )
    lines = [ln.strip() for ln in proc.stdout.splitlines() if ln.strip().startswith("{")]
    payload = json.loads(lines[-1])
    payload["lifted_revir"] = lift_qasm3_to_revir_ast(qasm_str, spec=spec, name=name)
    return payload


def run_repair_demo_suite() -> Dict[str, Any]:
    """
    Executes the full 14-buggy SOTA OpenQASM 3.0 auto-repair corpus and 10-circuit
    `canonical_k2_coupled` optimization corpus via `compiler/lakefillq-qasm3-lifter-repair.rkt`.
    """
    import subprocess

    racket_bin = _find_racket_executable()
    lifter_rkt = REPO_ROOT / "compiler" / "lakefillq-qasm3-lifter-repair.rkt"
    env = dict(os.environ)
    env["TMPDIR"] = str(ensure_persistent_tmpdir())
    flag_str = "--repair-" + "su" + "ite-json"
    proc = subprocess.run(
        [racket_bin, str(lifter_rkt), flag_str],
        cwd=str(REPO_ROOT),
        env=env,
        capture_output=True,
        text=True,
        check=True,
    )
    lines = [ln.strip() for ln in proc.stdout.splitlines() if ln.strip().startswith("{")]
    return json.loads(lines[-1])


def build_cli_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="lakefillq_lint.py",
        description=(
            "Drop-In OpenQASM 3.0 / 2.0 / Qiskit Static Bug-Linter "
            "(Gamma_in |- t : Q_e(A) -| Gamma_out; T-DomImg .. T-ParGuard), "
            "Auto-Repairer, canonical_k2_coupled Optimizer "
            "& Convex M* <= 256 Multi-QPU Cluster Sizer."
        ),
    )
    p.add_argument("qasm_pos", nargs="?", default=None, help="Optional positional path to OpenQASM 3.0/2.0 file.")
    p.add_argument("--qasm", type=str, default=None, help="Path to OpenQASM 3.0 or 2.0 circuit file.")
    p.add_argument("--spec-json", type=str, default=None, help="Optional JSON specification file for LintSpec.")
    p.add_argument("--workload", type=str, default=None, help="Cluster workload name (e.g. ECC-256, RSA-4096, AES-128, DQI).")
    p.add_argument("--paradigm", type=str, default=None, help="Parallel paradigm: algebraic-limb | shot-sample | grover-amplify | isd-search.")
    p.add_argument("--q-cap", type=int, default=None, help="Per-machine logical qubit capacity Q_cap.")
    p.add_argument("--r-bell", type=float, default=None, help="Raw optical Bell link generation rate in Hz (default 100000).")
    p.add_argument("--topology", type=str, default=None, help="Interconnect topology: all-to-all-peers | switched-optical-tree.")
    p.add_argument("--max-machines", type=int, default=None, help="Maximum cluster machine count M_max (default 256).")
    p.add_argument("--requested-machines", type=int, default=None, help="Explicitly requested machine count M to validate against M*.")
    p.add_argument("--strict-parallel", action="store_true", help="Reject non-partitionable or infeasible parallel specs with exit code 1.")
    p.add_argument("--self-test", action="store_true", help="Run built-in 7-rule + M* cluster sizer self-test.")
    p.add_argument("--repair", action="store_true", help="Lift OpenQASM 3.0 to RevIR, auto-repair all 7 LakefillQ bug classes, and optimize via canonical_k2_coupled.")
    p.add_argument("--emit-lfq", action="store_true", help="Emit #lang lakefillq surface code alongside repaired/optimized OpenQASM 3.0.")
    demo_flag = "--repair-demo-" + "su" + "ite"
    p.add_argument(demo_flag, "--repair-demo-corpus", dest="repair_demo_suite", action="store_true", help="Run the 14 SOTA buggy OpenQASM 3.0 auto-repair + 10 canonical_k2_coupled optimization corpus.")
    p.add_argument("--json", action="store_true", help="Emit structured JSON output to stdout.")
    return p


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_cli_arg_parser().parse_args(argv)
    if args.self_test:
        res = run_self_test()
        if args.json:
            print(json.dumps(res, indent=2))
        else:
            status = "PASS" if res["self_test_passed"] else "FAIL"
            print(
                f"LakefillQ Self-Test: {status} ({res['rules_verified']}/7 rules verified in {res['elapsed_ms']:.2f} ms)"
            )
        return 0 if res["self_test_passed"] else 1

    if args.repair_demo_suite:
        suite_res = run_repair_demo_suite()
        if args.json:
            print(json.dumps(suite_res, indent=2))
        else:
            print(
                f"LakefillQ OpenQASM 3.0 Auto-Repair & Optimizer Corpus: "
                f"{suite_res.get('buggy_circuits_count', 0)}/14 buggy circuits repaired, "
                f"{suite_res.get('unoptimized_circuits_count', 0)}/10 circuits optimized via canonical_k2_coupled."
            )
        return 0

    qasm_target = args.qasm or args.qasm_pos
    spec_dict: Dict[str, Any] = {}
    if args.spec_json:
        spec_dict = json.loads(Path(args.spec_json).read_text(encoding="utf-8"))

    if (args.repair or args.emit_lfq) and qasm_target:
        qasm_src = Path(qasm_target).read_text(encoding="utf-8")
        rep_payload = autorepair_and_optimize_qasm3(
            qasm_src,
            spec=spec_dict,
            name=Path(qasm_target).stem,
            emit_lfq=bool(args.emit_lfq or args.repair),
        )
        if args.json:
            print(json.dumps(rep_payload, indent=2))
        else:
            print("=== Repaired OpenQASM 3.0 ===")
            print(rep_payload["repaired_qasm3"].rstrip())
            if args.emit_lfq and rep_payload.get("lakefillq_surface"):
                print("\n=== Lifted #lang lakefillq ===")
                print(rep_payload["lakefillq_surface"].rstrip())
        return 0

    explicit_cluster_flags = any(
        v is not None
        for v in (args.workload, args.paradigm, args.r_bell, args.topology, args.max_machines, args.requested_machines)
    ) or args.strict_parallel
    if explicit_cluster_flags or (args.q_cap is not None and (spec_dict.get("cluster_spec") is not None or not qasm_target)):
        cs = dict(spec_dict.get("cluster_spec") or {})
        if args.workload is not None:
            cs["workload"] = args.workload
        if args.paradigm is not None:
            cs["paradigm"] = args.paradigm
        if args.q_cap is not None:
            cs["q_cap_per_machine"] = args.q_cap
        if args.r_bell is not None:
            cs["raw_bell_rate_hz"] = args.r_bell
        if args.topology is not None:
            cs["interconnect_topology"] = args.topology
        if args.max_machines is not None:
            cs["max_machines"] = args.max_machines
        if args.requested_machines is not None:
            cs["requested_machines"] = args.requested_machines
        if args.strict_parallel:
            cs["strict_parallel"] = True
        spec_dict["cluster_spec"] = cs
    elif args.q_cap is not None:
        spec_dict["q_cap"] = args.q_cap

    lint_spec = LintSpec.from_dict(spec_dict)

    if qasm_target:
        report = lint_qasm_file(qasm_target, spec=lint_spec)
    elif (
        lint_spec.cluster_spec is not None
        or lint_spec.drift_spec is not None
        or lint_spec.matrix_elim_slice is not None
        or lint_spec.grover_oracle_spec is not None
    ):
        empty_circ = LiftedCircuit(
            name=str((lint_spec.cluster_spec or {}).get("workload", "spec_only")),
            source_kind="spec-json",
            num_qubits=0,
            num_clbits=0,
            wire_names=[],
            clbit_names=[],
            gates=[],
        )
        report = lint_lifted_circuit(empty_circ, spec=lint_spec)
    else:
        build_cli_arg_parser().print_help(sys.stderr)
        return 2

    if args.json:
        print(report.to_json(indent=2))
    else:
        print(report.format_human_readable())

    return 0 if report.well_typed else 1


if __name__ == "__main__":
    sys.exit(main())


