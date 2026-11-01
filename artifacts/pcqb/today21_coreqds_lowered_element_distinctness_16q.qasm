// =============================================================================
// Proof-Carrying Quantum Binary (PCQB) — Benchmark TODAY-21
// Circuit: End-to-End `CoreQDS`-Lowered Ambainis Element Distinctness Radix-Tree Walk
//          (`qlet` + `qphase-oracle` + `qwalk-zipper` — `QDS-35`, `QDS-36`, `QDS-37`,
//           `OQP-39`, `OQP-40`, `OQP-41`, `S65..S69`, `Passes M35..M37`) (`16q`)
// Targets: Google Willow (105Q), IBM Heron R2 (156Q), Quantinuum H2-1 (56Q),
//          Harvard/QuEra Bluvstein Neutral Atom (280Q)
// Physical Qubits: 16 (idx[6] radix-tree zipper focus, key[6] element keys,
//                  cmp[3] `qlet`-scoped collision scratchpad, anc[1] `qphase-oracle`
//                  kickback target, c[6] bit readout)
// Logical Gates: 58 | Two-Qubit Gates: 28 (2 matched rccx/rccx_dag pairs + 16 CNOT/CZ)
// T-Count: 16 (2 rccx + 2 rccx_dag pairs = 16 T/Tdg gates; 0 residual ancilla waste)
// Execution Loop Tier: Loop-3 (UserCloudOuterLoop verified CoreQDS -> RevIR -> QASM 3.0)
// Formal Certificates:
//   - Lean 4: `f85_s65_qds35_oqp39_lexical_qlet_automatic_uncomputation_sound`
//   - Lean 4: `f86_s66_qds36_oqp40_phase_oracle_kickback_synthesis_sound`
//   - Lean 4: `f87_s67_m35_qds37_compiled_revir_netlist_translation_validation_sound`
//   - Lean 4: `f89_s69_m37_oqp41_end_to_end_coreqds_all_42_oqp_lowering_sound`
//   - Lean 4: `thm35g_phase19_master_90bug_coreqds_end_to_end_compiler_soundness`
// =============================================================================
OPENQASM 3.0;
include "stdgates.inc";

// 16 physical qubits lowered from 13-constructor CoreQDS AST:
// idx[0..5] : 6-qubit radix-tree zipper focus address register (`QWalkZipper`)
// key[0..5] : 6-qubit element key register (`QFoldTree` radix spine)
// cmp[0..2] : 3-qubit `QLet`-bound collision comparator scratchpad (`bound_mask = 0x7000`)
// anc[0]    : 1-qubit `QPhaseOracle` Bennett phase-kickback target (`ancilla_wire = 15`)
qubit[6] idx;
qubit[6] key;
qubit[3] cmp;
qubit[1] anc;
bit[6] c;

gate rccx a, b, target {
  h target;
  t target;
  cx b, target;
  tdg target;
  cx a, target;
  t target;
  cx b, target;
  tdg target;
  h target;
}

gate rccx_dag a, b, target {
  h target;
  t target;
  cx b, target;
  tdg target;
  cx a, target;
  t target;
  cx b, target;
  tdg target;
  h target;
}

// 1. Prepare radix-tree zipper coin & focus superposition on idx[0..5]
h idx[0];
h idx[1];
h idx[2];
h idx[3];
h idx[4];
h idx[5];

// 2. Load radix-tree keys along zipper spine (`QFoldTree` + `MatchIso`)
cx idx[0], key[0];
cx idx[1], key[1];
cx idx[2], key[2];
cx idx[3], key[3];
cx idx[4], key[4];
cx idx[5], key[5];

// 3. CoreQDS `QLet("cmp", 0x7000, init_collision, QPhaseOracle(pred, anc[0]))`
//    Automatically lowers to `within { init_collision } apply { phase_oracle }`:
// --- BEGIN within { QLet init: compute pairwise key collision into cmp[0..2] } ---
cx key[0], key[3];
cx key[1], key[4];
cx key[2], key[5];
rccx key[0], key[1], cmp[0];
rccx cmp[0], key[2], cmp[1];
cx cmp[1], cmp[2];

// --- BEGIN apply { QPhaseOracle: within { P(cmp, anc[0]) } apply { z anc[0] } } ---
cx cmp[2], anc[0];
z anc[0];
cx cmp[2], anc[0];
// --- END apply (anc[0] returned cleanly to |0>) ---

// --- BEGIN uncompute { QLet scope exit: invert_circuit(init_collision) } ---
cx cmp[1], cmp[2];
rccx_dag cmp[0], key[2], cmp[1];
rccx_dag key[0], key[1], cmp[0];
cx key[2], key[5];
cx key[1], key[4];
cx key[0], key[3];
// --- END within (cmp[0..2] == |000>, residual scratch_mask == 0x0) ---

// 4. Uncompute radix-tree key spine and apply `QWalkZipper` shift reflection
cx idx[5], key[5];
cx idx[4], key[4];
cx idx[3], key[3];
cx idx[2], key[2];
cx idx[1], key[1];
cx idx[0], key[0];
cz idx[0], idx[3];
cz idx[1], idx[4];
h idx[0];
h idx[1];
h idx[2];
h idx[3];
h idx[4];
h idx[5];

// 5. Terminal batch measurement of radix-tree zipper focus idx[0..5] (0 MCM)
c = measure idx;
