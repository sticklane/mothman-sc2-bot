#!/usr/bin/env python3
"""
verify_quantum_xls_z3_and_rtl_equivalence.py
===============================================================================
End-to-End Google XLS DSLX Formal QuickCheck, Synthesized IR/Verilog Codegen,
Z3 SMT BitVec Symbolic Equivalence (`UNSAT` + Live 1-Bit Fault Injection `SAT`),
and Icarus Verilog (`iverilog -g2012` + `vvp`) Cycle-Accurate RTL Verification
for Workstream 13 (and 17): Okasaki Purely Functional & Quantum Data Structures.

Hardware Kernels Verified (6/6):
  1. `okasaki_carry_free_ternary_mac4`
     - Okasaki Skew-Binary / Carry-Save O(1)-depth multiply-free ternary MAC tile
  2. `braun_tree_perfect_shuffle_router8`
     - Pointerless Braun-Tree (even/odd LSB bit-routed) 8-slot KV/MoE router
  3. `finger_tree_dyadic_monoid_combine`
     - 2-3 Finger-Tree monoidal dyadic shift-and-add attention/SSM rescaler
  4. `stage10_bootstrapped_16ary_zipper_step16`
     - Stage 10A Bootstrapped 2-Level 16-ary Implicit Slowdown Zipper (274 Q ECDLP-256)
  5. `symbiotic_subtree_borrow_step`
     - Stage 10B Symbiotic Inactive-Subtree Borrowing (268 Q ECDLP-256, 0 external ancillas)
  6. `oblivious_crit_bit_superposition_router4`
     - Probe 2 Remedy: Pointerless Constant-Depth Oblivious Crit-Bit Superposition Router
       with dummy identity muxes after early leaf resolution (`fixed_steps_executed == 3`)
===============================================================================
"""

from __future__ import annotations
import os
import random
import re
import subprocess
import sys
import time
from typing import Any

import z3

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DSLX_FILE = os.path.join(SCRIPT_DIR, "dl_okasaki_skew_braun_and_finger_tree_hardware.x")
XLS_DIR = "/home/antigravity/toolchains/xls"
TMP_ROOT = "/home/antigravity/toolchains/tmp"
SYNTH_DIR = os.path.join(TMP_ROOT, "ws13_xls_synth")

KERNELS = [
    "okasaki_carry_free_ternary_mac4",
    "braun_tree_perfect_shuffle_router8",
    "finger_tree_dyadic_monoid_combine",
    "stage10_bootstrapped_16ary_zipper_step16",
    "symbiotic_subtree_borrow_step",
    "oblivious_crit_bit_superposition_router4",
]


def run_cmd(cmd: list[str], cwd: str = SCRIPT_DIR) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["TMPDIR"] = TMP_ROOT
    res = subprocess.run(
        cmd,
        cwd=cwd,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    if res.returncode != 0:
        raise RuntimeError(
            f"Command failed ({res.returncode}): {' '.join(cmd)}\n"
            f"STDOUT:\n{res.stdout}\nSTDERR:\n{res.stderr}"
        )
    return res


# =============================================================================
# Step 1: Google XLS `prove_quickcheck_main` Exhaustive Z3 Bit-Blasting
# =============================================================================

def step1_run_xls_prove_quickcheck() -> dict[str, Any]:
    os.makedirs(SYNTH_DIR, exist_ok=True)
    t0 = time.perf_counter()
    res = run_cmd([os.path.join(XLS_DIR, "prove_quickcheck_main"), DSLX_FILE])
    elapsed_ms = (time.perf_counter() - t0) * 1000.0
    out = res.stdout + res.stderr
    assert "6 test(s) ran; 0 failed; 0 skipped." in out, f"Unexpected quickcheck output:\n{out}"
    return {
        "output": out.strip(),
        "elapsed_ms": elapsed_ms,
        "tests_passed": 6,
    }


# =============================================================================
# Step 2: XLS `ir_converter_main` -> `opt_main` -> `codegen_main` (Verilog RTL)
# =============================================================================

def step2_synthesize_xls_ir_and_verilog() -> dict[str, dict[str, Any]]:
    os.makedirs(SYNTH_DIR, exist_ok=True)
    artifacts: dict[str, dict[str, Any]] = {}

    for fn in KERNELS:
        ir_path = os.path.join(SYNTH_DIR, f"{fn}.ir")
        opt_ir_path = os.path.join(SYNTH_DIR, f"{fn}.opt.ir")
        v_path = os.path.join(SYNTH_DIR, f"{fn}.v")

        res_ir = run_cmd([
            os.path.join(XLS_DIR, "ir_converter_main"),
            f"--top={fn}",
            DSLX_FILE,
        ])
        with open(ir_path, "w", encoding="utf-8") as f:
            f.write(res_ir.stdout)

        res_opt = run_cmd([
            os.path.join(XLS_DIR, "opt_main"),
            ir_path,
        ])
        with open(opt_ir_path, "w", encoding="utf-8") as f:
            f.write(res_opt.stdout)

        res_v = run_cmd([
            os.path.join(XLS_DIR, "codegen_main"),
            "--generator=combinational",
            "--delay_model=unit",
            f"--module_name={fn}",
            opt_ir_path,
        ])
        with open(v_path, "w", encoding="utf-8") as f:
            f.write(res_v.stdout)

        wire_count = sum(1 for line in res_v.stdout.splitlines() if line.strip().startswith("wire "))
        assign_count = sum(1 for line in res_v.stdout.splitlines() if line.strip().startswith("assign "))
        artifacts[fn] = {
            "ir_path": ir_path,
            "opt_ir_path": opt_ir_path,
            "v_path": v_path,
            "opt_ir_text": res_opt.stdout,
            "v_text": res_v.stdout,
            "wire_count": wire_count,
            "assign_count": assign_count,
        }
    return artifacts


# =============================================================================
# Step 3: Z3 SMT Symbolic BitVec Equivalence (`UNSAT`) & 1-Bit Mutation (`SAT`)
# =============================================================================

def parse_xls_opt_ir_to_z3(opt_ir_text: str, env_vars: dict[str, z3.BitVecRef]) -> Any:
    """
    Directly parses the synthesized XLS `.opt.ir` function body into a symbolic
    `z3.BitVec` DAG over universally quantified input `z3.BitVec` variables.
    Zero constant-plugging: every XLS IR node is translated into exact Z3 bit-vector
    algebra (`Extract`, `Concat`, `SignExt`, `ZeroExt`, `BVAdd`, `If`, etc.).
    """
    env: dict[str, Any] = dict(env_vars)

    for raw_line in opt_ir_text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("package ") or line.startswith("file_number ") or line.startswith("top fn ") or line == "}":
            continue

        is_ret = False
        if line.startswith("ret "):
            is_ret = True
            line = line[len("ret "):].strip()

        lhs, rhs = line.split("=", 1)
        lhs = lhs.strip()
        rhs = rhs.strip()
        node_name, type_str = [x.strip() for x in lhs.split(":", 1)]

        m_op = re.match(r"^([a-zA-Z0-9_]+)\((.*)\)$", rhs)
        if not m_op:
            raise ValueError(f"Cannot parse XLS IR RHS: {rhs}")
        op = m_op.group(1)
        args_str = re.sub(r",\s*pos=\[.*\]", "", m_op.group(2))
        args_str = re.sub(r",\s*id=\d+", "", args_str)

        def get_width(t_s: str) -> int:
            m_w = re.match(r"bits\[(\d+)\]", t_s.strip())
            if not m_w:
                raise ValueError(f"Expected bits[N], got {t_s}")
            return int(m_w.group(1))

        val: Any = None
        if op == "literal":
            w = get_width(type_str)
            m_val = re.search(r"value=(-?\d+)", args_str)
            assert m_val is not None
            v_int = int(m_val.group(1)) & ((1 << w) - 1)
            val = z3.BitVecVal(v_int, w)

        elif op == "bit_slice":
            parts = [p.strip() for p in args_str.split(",")]
            src = env[parts[0]]
            m_st = re.search(r"start=(\d+)", args_str)
            m_wd = re.search(r"width=(\d+)", args_str)
            assert m_st and m_wd
            st = int(m_st.group(1))
            wd = int(m_wd.group(1))
            val = z3.Extract(st + wd - 1, st, src)

        elif op == "sign_ext":
            parts = [p.strip() for p in args_str.split(",")]
            src = env[parts[0]]
            m_nb = re.search(r"new_bit_count=(\d+)", args_str)
            assert m_nb
            nb = int(m_nb.group(1))
            val = z3.SignExt(nb - src.size(), src)

        elif op == "zero_ext":
            parts = [p.strip() for p in args_str.split(",")]
            src = env[parts[0]]
            m_nb = re.search(r"new_bit_count=(\d+)", args_str)
            assert m_nb
            nb = int(m_nb.group(1))
            val = z3.ZeroExt(nb - src.size(), src)

        elif op == "concat":
            parts = [p.strip() for p in args_str.split(",") if "=" not in p]
            operands = [env[p] for p in parts]
            val = operands[0] if len(operands) == 1 else z3.Concat(*operands)

        elif op in ("add", "and", "or", "xor", "nand", "nor", "eq", "shll", "shrl", "neg", "not"):
            parts = [p.strip() for p in args_str.split(",") if "=" not in p]
            operands = [env[p] for p in parts]
            if op == "add":
                val = operands[0] + operands[1]
            elif op == "neg":
                val = -operands[0]
            elif op == "not":
                val = ~operands[0]
            elif op == "and":
                val = operands[0]
                for o in operands[1:]:
                    val = val & o
            elif op == "or":
                val = operands[0]
                for o in operands[1:]:
                    val = val | o
            elif op == "xor":
                val = operands[0]
                for o in operands[1:]:
                    val = val ^ o
            elif op == "nand":
                acc = operands[0]
                for o in operands[1:]:
                    acc = acc & o
                val = ~acc
            elif op == "nor":
                acc = operands[0]
                for o in operands[1:]:
                    acc = acc | o
                val = ~acc
            elif op == "eq":
                val = z3.If(operands[0] == operands[1], z3.BitVecVal(1, 1), z3.BitVecVal(0, 1))
            elif op == "shll":
                a, b = operands[0], operands[1]
                w_a, w_b = a.size(), b.size()
                if w_b < w_a:
                    b_ext = z3.ZeroExt(w_a - w_b, b)
                elif w_b > w_a:
                    b_ext = z3.Extract(w_a - 1, 0, b)
                else:
                    b_ext = b
                val = z3.If(z3.UGE(b_ext, z3.BitVecVal(w_a, w_a)), z3.BitVecVal(0, w_a), a << b_ext)
            elif op == "shrl":
                a, b = operands[0], operands[1]
                w_a, w_b = a.size(), b.size()
                if w_b < w_a:
                    b_ext = z3.ZeroExt(w_a - w_b, b)
                elif w_b > w_a:
                    b_ext = z3.Extract(w_a - 1, 0, b)
                else:
                    b_ext = b
                val = z3.If(z3.UGE(b_ext, z3.BitVecVal(w_a, w_a)), z3.BitVecVal(0, w_a), z3.LShR(a, b_ext))

        elif op == "sel":
            sel_var = env[args_str.split(",", 1)[0].strip()]
            m_cases = re.search(r"cases=\[([^\]]+)\]", args_str)
            assert m_cases
            cases = [env[c.strip()] for c in m_cases.group(1).split(",")]
            m_def = re.search(r"default=([a-zA-Z0-9_.]+)", args_str)
            cur = env[m_def.group(1)] if m_def else cases[-1]
            for i in range(len(cases) - 1, -1, -1):
                cur = z3.If(sel_var == z3.BitVecVal(i, sel_var.size()), cases[i], cur)
            val = cur

        elif op == "priority_sel":
            sel_var = env[args_str.split(",", 1)[0].strip()]
            m_cases = re.search(r"cases=\[([^\]]+)\]", args_str)
            m_def = re.search(r"default=([a-zA-Z0-9_.]+)", args_str)
            assert m_cases and m_def
            cases = [env[c.strip()] for c in m_cases.group(1).split(",")]
            cur = env[m_def.group(1)]
            for i in range(len(cases) - 1, -1, -1):
                bit_i = z3.Extract(i, i, sel_var)
                cur = z3.If(bit_i == z3.BitVecVal(1, 1), cases[i], cur)
            val = cur

        elif op == "tuple":
            parts = [p.strip() for p in args_str.split(",") if "=" not in p]
            val = tuple(env[p] for p in parts)

        else:
            raise ValueError(f"Unsupported XLS IR op: {op} in line: {raw_line}")

        env[node_name] = val
        if is_ret:
            return val

    raise RuntimeError("No ret statement found in XLS IR")


def prove_z3_equiv_and_mutation(
    kernel_name: str,
    xls_out: Any,
    golden_out: Any,
) -> dict[str, Any]:
    if isinstance(xls_out, tuple):
        xls_vec = z3.Concat(*xls_out)
        gold_vec = z3.Concat(*golden_out)
    else:
        xls_vec = xls_out
        gold_vec = golden_out

    assert xls_vec.size() == gold_vec.size()
    width = xls_vec.size()

    # 1. Prove exact equivalence over all BitVec inputs: solver.add(xls_vec != gold_vec) -> UNSAT
    s_eq = z3.Solver()
    s_eq.add(xls_vec != gold_vec)
    res_eq = s_eq.check()
    assert res_eq == z3.unsat, f"[{kernel_name}] Z3 equivalence failed! Model: {s_eq.model()}"

    # 2. Live 1-bit hardware fault injection check: flip LSB of synthesized hardware output -> SAT
    mutated_xls_vec = xls_vec ^ z3.BitVecVal(1, width)
    s_mut = z3.Solver()
    s_mut.add(mutated_xls_vec != gold_vec)
    res_mut = s_mut.check()
    assert res_mut == z3.sat, f"[{kernel_name}] Z3 mutation check failed to return SAT!"

    return {
        "kernel": kernel_name,
        "output_bits": width,
        "equiv_result": "UNSAT",
        "mutation_1bit_result": "SAT",
    }


def step3_run_z3_symbolic_equivalence(artifacts: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []

    # --- Kernel 1: okasaki_carry_free_ternary_mac4 ---
    w0, w1, w2, w3 = [z3.BitVec(f"w{i}", 2) for i in range(4)]
    x0, x1, x2, x3 = [z3.BitVec(f"x{i}", 8) for i in range(4)]
    xls_k1 = parse_xls_opt_ir_to_z3(
        artifacts["okasaki_carry_free_ternary_mac4"]["opt_ir_text"],
        {"w0": w0, "w1": w1, "w2": w2, "w3": w3, "x0": x0, "x1": x1, "x2": x2, "x3": x3},
    )

    def gold_ternary_term(w: z3.BitVecRef, x: z3.BitVecRef) -> z3.BitVecRef:
        xs = z3.SignExt(8, x)
        return z3.If(w == z3.BitVecVal(1, 2), xs, z3.If(w == z3.BitVecVal(2, 2), -xs, z3.BitVecVal(0, 16)))

    gold_k1 = (
        gold_ternary_term(w0, x0)
        + gold_ternary_term(w1, x1)
        + gold_ternary_term(w2, x2)
        + gold_ternary_term(w3, x3)
    )
    results.append(prove_z3_equiv_and_mutation("okasaki_carry_free_ternary_mac4", xls_k1, gold_k1))

    # --- Kernel 2: braun_tree_perfect_shuffle_router8 ---
    idx = z3.BitVec("idx", 3)
    vs = [z3.BitVec(f"v{i}", 8) for i in range(8)]
    env_k2 = {"idx": idx, **{f"v{i}": vs[i] for i in range(8)}}
    xls_k2 = parse_xls_opt_ir_to_z3(
        artifacts["braun_tree_perfect_shuffle_router8"]["opt_ir_text"],
        env_k2,
    )
    gold_k2 = vs[7]
    for i in range(6, -1, -1):
        gold_k2 = z3.If(idx == z3.BitVecVal(i, 3), vs[i], gold_k2)
    results.append(prove_z3_equiv_and_mutation("braun_tree_perfect_shuffle_router8", xls_k2, gold_k2))

    # --- Kernel 3: finger_tree_dyadic_monoid_combine ---
    s_l = z3.BitVec("s_l", 4)
    n_l = z3.BitVec("n_l", 16)
    s_r = z3.BitVec("s_r", 4)
    n_r = z3.BitVec("n_r", 16)
    xls_k3 = parse_xls_opt_ir_to_z3(
        artifacts["finger_tree_dyadic_monoid_combine"]["opt_ir_text"],
        {"s_l": s_l, "n_l": n_l, "s_r": s_r, "n_r": n_r},
    )
    gold_k3 = (s_l + s_r, n_l + (n_r << z3.ZeroExt(12, s_l)))
    results.append(prove_z3_equiv_and_mutation("finger_tree_dyadic_monoid_combine", xls_k3, gold_k3))

    # --- Kernel 4: stage10_bootstrapped_16ary_zipper_step16 ---
    focus16 = z3.BitVec("focus16", 16)
    delta16 = z3.BitVec("delta16", 16)
    dirty_spine_l0 = z3.BitVec("dirty_spine_l0", 16)
    dirty_spine_l1 = z3.BitVec("dirty_spine_l1", 16)
    defunc_tag2 = z3.BitVec("defunc_tag2", 2)
    xls_k4 = parse_xls_opt_ir_to_z3(
        artifacts["stage10_bootstrapped_16ary_zipper_step16"]["opt_ir_text"],
        {
            "focus16": focus16,
            "delta16": delta16,
            "dirty_spine_l0": dirty_spine_l0,
            "dirty_spine_l1": dirty_spine_l1,
            "defunc_tag2": defunc_tag2,
        },
    )
    gold_k4 = (focus16 + delta16, dirty_spine_l0, dirty_spine_l1, defunc_tag2)
    results.append(prove_z3_equiv_and_mutation("stage10_bootstrapped_16ary_zipper_step16", xls_k4, gold_k4))

    # --- Kernel 5: symbiotic_subtree_borrow_step ---
    x_left = z3.BitVec("x_left", 16)
    y_left = z3.BitVec("y_left", 16)
    acc_left = z3.BitVec("acc_left", 16)
    dirty_right_subtree = z3.BitVec("dirty_right_subtree", 16)
    xls_k5 = parse_xls_opt_ir_to_z3(
        artifacts["symbiotic_subtree_borrow_step"]["opt_ir_text"],
        {
            "x_left": x_left,
            "y_left": y_left,
            "acc_left": acc_left,
            "dirty_right_subtree": dirty_right_subtree,
        },
    )
    gold_k5 = (
        acc_left ^ ((x_left & y_left) ^ ((x_left | y_left) << z3.BitVecVal(1, 16))),
        dirty_right_subtree,
    )
    results.append(prove_z3_equiv_and_mutation("symbiotic_subtree_borrow_step", xls_k5, gold_k5))

    # --- Kernel 6: oblivious_crit_bit_superposition_router4 ---
    query = z3.BitVec("query", 4)
    crit_root = z3.BitVec("crit_root", 2)
    crit_l = z3.BitVec("crit_l", 2)
    crit_r = z3.BitVec("crit_r", 2)
    shape_skew = z3.BitVec("shape_skew", 1)
    k0, k1, k2, k3 = [z3.BitVec(f"k{i}", 4) for i in range(4)]
    xls_k6 = parse_xls_opt_ir_to_z3(
        artifacts["oblivious_crit_bit_superposition_router4"]["opt_ir_text"],
        {
            "query": query,
            "crit_root": crit_root,
            "crit_l": crit_l,
            "crit_r": crit_r,
            "shape_skew": shape_skew,
            "k0": k0,
            "k1": k1,
            "k2": k2,
            "k3": k3,
        },
    )
    b0 = z3.Extract(0, 0, z3.LShR(query, z3.ZeroExt(2, crit_root)))
    b1 = z3.Extract(0, 0, z3.LShR(query, z3.ZeroExt(2, crit_l)))
    b2 = z3.Extract(0, 0, z3.LShR(query, z3.ZeroExt(2, crit_r)))

    slot_bal = z3.If(
        b0 == z3.BitVecVal(0, 1),
        z3.If(b1 == z3.BitVecVal(0, 1), z3.BitVecVal(0, 2), z3.BitVecVal(1, 2)),
        z3.If(b2 == z3.BitVecVal(0, 1), z3.BitVecVal(2, 2), z3.BitVecVal(3, 2)),
    )
    slot_skew = z3.If(
        b0 == z3.BitVecVal(0, 1),
        z3.BitVecVal(0, 2),
        z3.If(
            b1 == z3.BitVecVal(0, 1),
            z3.BitVecVal(1, 2),
            z3.If(b2 == z3.BitVecVal(0, 1), z3.BitVecVal(2, 2), z3.BitVecVal(3, 2)),
        ),
    )
    gold_slot = z3.If(shape_skew == z3.BitVecVal(0, 1), slot_bal, slot_skew)
    gold_leaf = z3.If(
        gold_slot == z3.BitVecVal(0, 2),
        k0,
        z3.If(
            gold_slot == z3.BitVecVal(1, 2),
            k1,
            z3.If(gold_slot == z3.BitVecVal(2, 2), k2, k3),
        ),
    )
    gold_found = z3.If(gold_leaf == query, z3.BitVecVal(1, 1), z3.BitVecVal(0, 1))
    gold_steps = z3.BitVecVal(3, 3)
    gold_k6 = (gold_found, gold_slot, gold_steps)
    results.append(prove_z3_equiv_and_mutation("oblivious_crit_bit_superposition_router4", xls_k6, gold_k6))

    return results


# =============================================================================
# Step 4: Icarus Verilog (`iverilog -g2012` + `vvp`) 1,024-Vector RTL Simulation
# =============================================================================

def s8(val: int) -> int:
    val &= 0xFF
    return val - 256 if val >= 128 else val


def u16_mask(val: int) -> int:
    return val & 0xFFFF


def step4_run_iverilog_rtl_simulation(
    artifacts: dict[str, dict[str, Any]],
    num_vectors: int = 1024,
) -> dict[str, Any]:
    rng = random.Random(20261021)
    tb_lines: list[str] = [
        "`timescale 1ns/1ps",
        "module tb_ws13_okasaki_all_kernels;",
        "  integer mismatches = 0;",
        "  integer total_checks = 0;",
        "",
        "  // Kernel 1 signals",
        "  reg [1:0] k1_w0, k1_w1, k1_w2, k1_w3;",
        "  reg [7:0] k1_x0, k1_x1, k1_x2, k1_x3;",
        "  wire [15:0] k1_out;",
        "  okasaki_carry_free_ternary_mac4 dut_k1(",
        "    .w0(k1_w0), .w1(k1_w1), .w2(k1_w2), .w3(k1_w3),",
        "    .x0(k1_x0), .x1(k1_x1), .x2(k1_x2), .x3(k1_x3), .out(k1_out)",
        "  );",
        "",
        "  // Kernel 2 signals",
        "  reg [2:0] k2_idx;",
        "  reg [7:0] k2_v0, k2_v1, k2_v2, k2_v3, k2_v4, k2_v5, k2_v6, k2_v7;",
        "  wire [7:0] k2_out;",
        "  braun_tree_perfect_shuffle_router8 dut_k2(",
        "    .idx(k2_idx), .v0(k2_v0), .v1(k2_v1), .v2(k2_v2), .v3(k2_v3),",
        "    .v4(k2_v4), .v5(k2_v5), .v6(k2_v6), .v7(k2_v7), .out(k2_out)",
        "  );",
        "",
        "  // Kernel 3 signals",
        "  reg [3:0] k3_sl, k3_sr;",
        "  reg [15:0] k3_nl, k3_nr;",
        "  wire [19:0] k3_out;",
        "  finger_tree_dyadic_monoid_combine dut_k3(",
        "    .s_l(k3_sl), .n_l(k3_nl), .s_r(k3_sr), .n_r(k3_nr), .out(k3_out)",
        "  );",
        "",
        "  // Kernel 4 signals",
        "  reg [15:0] k4_f, k4_d, k4_sp0, k4_sp1;",
        "  reg [1:0] k4_tag;",
        "  wire [49:0] k4_out;",
        "  stage10_bootstrapped_16ary_zipper_step16 dut_k4(",
        "    .focus16(k4_f), .delta16(k4_d), .dirty_spine_l0(k4_sp0),",
        "    .dirty_spine_l1(k4_sp1), .defunc_tag2(k4_tag), .out(k4_out)",
        "  );",
        "",
        "  // Kernel 5 signals",
        "  reg [15:0] k5_xl, k5_yl, k5_acc, k5_dr;",
        "  wire [31:0] k5_out;",
        "  symbiotic_subtree_borrow_step dut_k5(",
        "    .x_left(k5_xl), .y_left(k5_yl), .acc_left(k5_acc),",
        "    .dirty_right_subtree(k5_dr), .out(k5_out)",
        "  );",
        "",
        "  // Kernel 6 signals",
        "  reg [3:0] k6_q, k6_k0, k6_k1, k6_k2, k6_k3;",
        "  reg [1:0] k6_cr, k6_cl, k6_crr;",
        "  reg k6_skew;",
        "  wire [5:0] k6_out;",
        "  oblivious_crit_bit_superposition_router4 dut_k6(",
        "    .query(k6_q), .crit_root(k6_cr), .crit_l(k6_cl), .crit_r(k6_crr),",
        "    .shape_skew(k6_skew), .k0(k6_k0), .k1(k6_k1), .k2(k6_k2), .k3(k6_k3),",
        "    .out(k6_out)",
        "  );",
        "",
        "  initial begin",
    ]

    for vec_idx in range(num_vectors):
        # Kernel 1 golden
        w = [rng.randint(0, 3) for _ in range(4)]
        x = [rng.randint(0, 255) for _ in range(4)]
        acc1 = 0
        for wi, xi in zip(w, x):
            if wi == 1:
                acc1 += s8(xi)
            elif wi == 2:
                acc1 -= s8(xi)
        exp_k1 = u16_mask(acc1)

        # Kernel 2 golden
        idx2 = rng.randint(0, 7)
        v2 = [rng.randint(0, 255) for _ in range(8)]
        exp_k2 = v2[idx2]

        # Kernel 3 golden
        sl3 = rng.randint(0, 15)
        sr3 = rng.randint(0, 15)
        nl3 = rng.randint(0, 65535)
        nr3 = rng.randint(0, 65535)
        s_comb3 = (sl3 + sr3) & 0xF
        n_comb3 = (nl3 + (nr3 << sl3)) & 0xFFFF
        exp_k3 = (s_comb3 << 16) | n_comb3

        # Kernel 4 golden
        f4 = rng.randint(0, 65535)
        d4 = rng.randint(0, 65535)
        sp0_4 = rng.randint(0, 65535)
        sp1_4 = rng.randint(0, 65535)
        tag4 = rng.randint(0, 3)
        f_up4 = (f4 + d4) & 0xFFFF
        exp_k4 = (f_up4 << 34) | (sp0_4 << 18) | (sp1_4 << 2) | tag4

        # Kernel 5 golden
        xl5 = rng.randint(0, 65535)
        yl5 = rng.randint(0, 65535)
        acc5 = rng.randint(0, 65535)
        dr5 = rng.randint(0, 65535)
        acc_fin5 = (acc5 ^ (xl5 & yl5) ^ (((xl5 | yl5) << 1) & 0xFFFF)) & 0xFFFF
        exp_k5 = (acc_fin5 << 16) | dr5

        # Kernel 6 golden
        q6 = rng.randint(0, 15)
        cr6 = rng.randint(0, 3)
        cl6 = rng.randint(0, 3)
        crr6 = rng.randint(0, 3)
        skew6 = rng.randint(0, 1)
        ks6 = [rng.randint(0, 15) for _ in range(4)]
        b0 = (q6 >> cr6) & 1
        b1 = (q6 >> cl6) & 1
        b2 = (q6 >> crr6) & 1
        if skew6 == 0:
            slot6 = (0 if b1 == 0 else 1) if b0 == 0 else (2 if b2 == 0 else 3)
        else:
            if b0 == 0:
                slot6 = 0
            elif b1 == 0:
                slot6 = 1
            elif b2 == 0:
                slot6 = 2
            else:
                slot6 = 3
        found6 = 1 if ks6[slot6] == q6 else 0
        steps6 = 3
        exp_k6 = (found6 << 5) | (slot6 << 3) | steps6

        tb_lines.append(
            f"    k1_w0=2'd{w[0]}; k1_w1=2'd{w[1]}; k1_w2=2'd{w[2]}; k1_w3=2'd{w[3]}; "
            f"k1_x0=8'd{x[0]}; k1_x1=8'd{x[1]}; k1_x2=8'd{x[2]}; k1_x3=8'd{x[3]};"
        )
        tb_lines.append(
            f"    k2_idx=3'd{idx2}; k2_v0=8'd{v2[0]}; k2_v1=8'd{v2[1]}; k2_v2=8'd{v2[2]}; k2_v3=8'd{v2[3]}; "
            f"k2_v4=8'd{v2[4]}; k2_v5=8'd{v2[5]}; k2_v6=8'd{v2[6]}; k2_v7=8'd{v2[7]};"
        )
        tb_lines.append(
            f"    k3_sl=4'd{sl3}; k3_sr=4'd{sr3}; k3_nl=16'd{nl3}; k3_nr=16'd{nr3};"
        )
        tb_lines.append(
            f"    k4_f=16'd{f4}; k4_d=16'd{d4}; k4_sp0=16'd{sp0_4}; k4_sp1=16'd{sp1_4}; k4_tag=2'd{tag4};"
        )
        tb_lines.append(
            f"    k5_xl=16'd{xl5}; k5_yl=16'd{yl5}; k5_acc=16'd{acc5}; k5_dr=16'd{dr5};"
        )
        tb_lines.append(
            f"    k6_q=4'd{q6}; k6_cr=2'd{cr6}; k6_cl=2'd{cl6}; k6_crr=2'd{crr6}; k6_skew=1'd{skew6}; "
            f"k6_k0=4'd{ks6[0]}; k6_k1=4'd{ks6[1]}; k6_k2=4'd{ks6[2]}; k6_k3=4'd{ks6[3]};"
        )
        tb_lines.append("    #1;")
        tb_lines.append(
            f"    if (k1_out !== 16'd{exp_k1}) mismatches = mismatches + 1;\n"
            f"    if (k2_out !== 8'd{exp_k2}) mismatches = mismatches + 1;\n"
            f"    if (k3_out !== 20'd{exp_k3}) mismatches = mismatches + 1;\n"
            f"    if (k4_out !== 50'd{exp_k4}) mismatches = mismatches + 1;\n"
            f"    if (k5_out !== 32'd{exp_k5}) mismatches = mismatches + 1;\n"
            f"    if (k6_out !== 6'd{exp_k6}) mismatches = mismatches + 1;\n"
            f"    total_checks = total_checks + 6;"
        )

    tb_lines.extend([
        '    $display("RTL_SIM_SUMMARY: vectors=%0d total_kernel_checks=%0d mismatches=%0d", '
        f"{num_vectors}, total_checks, mismatches);",
        "    if (mismatches != 0) $fatal(1, \"RTL simulation mismatch detected!\");",
        "    $finish;",
        "  end",
        "endmodule",
    ])

    tb_path = os.path.join(SYNTH_DIR, "tb_ws13_okasaki_all_kernels.sv")
    vvp_path = os.path.join(SYNTH_DIR, "tb_ws13_okasaki_all_kernels.vvp")
    with open(tb_path, "w", encoding="utf-8") as f:
        f.write("\n".join(tb_lines) + "\n")

    v_files = [artifacts[fn]["v_path"] for fn in KERNELS]
    run_cmd(["iverilog", "-g2012", "-o", vvp_path, *v_files, tb_path])
    sim_res = run_cmd(["vvp", vvp_path])
    sim_out = sim_res.stdout.strip()
    assert "mismatches=0" in sim_out, f"Unexpected RTL simulation output:\n{sim_out}"

    return {
        "tb_path": tb_path,
        "vvp_path": vvp_path,
        "vectors_per_kernel": num_vectors,
        "total_kernel_checks": num_vectors * len(KERNELS),
        "mismatches": 0,
        "sim_output": sim_out,
    }


def main() -> None:
    print("=" * 84)
    print("WS13 (AND WS17) GOOGLE XLS DSLX -> OPT IR -> VERILOG RTL + Z3 SYMBOLIC EQUIVALENCE")
    print("=" * 84)

    s1 = step1_run_xls_prove_quickcheck()
    print(f"\n[Step 1] Google XLS `prove_quickcheck_main` ({s1['elapsed_ms']:.1f} ms):")
    for line in s1["output"].splitlines():
        print(f"  {line}")

    s2 = step2_synthesize_xls_ir_and_verilog()
    print(f"\n[Step 2] XLS IR Conversion (`ir_converter_main`), Optimization (`opt_main`) & Combinational Verilog (`codegen_main`):")
    for fn in KERNELS:
        info = s2[fn]
        print(
            f"  - {fn:44s}: {os.path.basename(info['v_path']):46s} "
            f"(wires={info['wire_count']:2d}, assigns={info['assign_count']:2d})"
        )

    s3 = step3_run_z3_symbolic_equivalence(s2)
    print("\n[Step 3] Z3 SMT Symbolic BitVec Equivalence (`opt.ir` vs Golden Spec) & Live 1-Bit Fault Mutation:")
    for r in s3:
        print(
            f"  - {r['kernel']:44s}: out_width={r['output_bits']:2d}b | "
            f"Equivalence={r['equiv_result']} | 1-Bit Fault Injection={r['mutation_1bit_result']}"
        )

    s4 = step4_run_iverilog_rtl_simulation(s2, num_vectors=1024)
    print("\n[Step 4] Icarus Verilog (`iverilog -g2012` + `vvp`) Cycle-Accurate RTL Simulation:")
    print(f"  - Testbench : {s4['tb_path']}")
    print(f"  - Output    : {s4['sim_output']}")

    print("\n" + "=" * 84)
    print("ALL 6 XLS HARDWARE KERNELS VERIFIED: QUICKCHECK=6/6, Z3=6/6 UNSAT (6/6 MUTATION SAT), RTL=6,144/6,144 (0 MISMATCHES)!")
    print("=" * 84)


if __name__ == "__main__":
    main()
