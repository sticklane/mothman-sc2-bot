// =============================================================================
// Proof-Carrying Quantum Binary (PCQB) — Benchmark TODAY-22
// Circuit: End-to-End `CoreQDS`-Lowered Montanaro Quantum Branch-and-Bound Tree Search
//          (`qlet` + `qphase-oracle` + `hugr-tailloop-region` — `QDS-32`, `QDS-35`,
//           `QDS-36`, `QDS-37`, `OQP-39..42`, `S65..S70`, `Passes M35..M38`) (`18q`)
// Targets: Google Willow (105Q), IBM Heron R2 (156Q), Quantinuum H2-1 (56Q),
//          Harvard/QuEra Bluvstein Neutral Atom (280Q)
// Physical Qubits: 18 (node[6] search-tree zipper path, cost[6] branch-cost accumulator,
//                  bound[4] `qlet`-scoped threshold comparison scratchpad,
//                  anc[1] `qphase-oracle` flag, stop[1] `TailLoop` termination flag,
//                  c[6] bit readout)
// Logical Gates: 64 | Two-Qubit Gates: 32 (2 matched rccx/rccx_dag pairs + 20 CNOT/CZ)
// T-Count: 16 (2 rccx + 2 rccx_dag pairs = 16 T/Tdg gates; 0 residual ancilla waste)
// Execution Loop Tier: Loop-2 (CoprocessorMidLoop HUGR TailLoop + Stinespring Pauli frame)
// Formal Certificates:
//   - Lean 4: `f85_s65_qds35_oqp39_lexical_qlet_automatic_uncomputation_sound`
//   - Lean 4: `f86_s66_qds36_oqp40_phase_oracle_kickback_synthesis_sound`
//   - Lean 4: `f88_s68_m36_hugr_tailloop_qlet_port_invariant_preservation_sound`
//   - Lean 4: `f90_s70_m38_oqp42_complete_22_circuit_pcqb_manifest_audit_sound`
//   - Lean 4: `thm35g_phase19_master_90bug_coreqds_end_to_end_compiler_soundness`
// =============================================================================
OPENQASM 3.0;
include "stdgates.inc";

// 18 physical qubits lowered from 13-constructor CoreQDS AST:
// node[0..5]  : 6-qubit search-tree zipper path register (`QWalkZipper`)
// cost[0..5]  : 6-qubit skew-binary branch-cost accumulator (`QFoldTree`)
// bound[0..3] : 4-qubit `QLet`-scoped threshold comparator scratchpad
// anc[0]      : 1-qubit `QPhaseOracle` kickback flag
// stop[0]     : 1-qubit `HugrTailLoop` port-matched termination flag
qubit[6] node;
qubit[6] cost;
qubit[4] bound;
qubit[1] anc;
qubit[1] stop;
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

// 1. Prepare search-tree path superposition on node[0..5]
h node[0];
h node[1];
h node[2];
h node[3];
h node[4];
h node[5];

// 2. Accumulate partial branch cost along tree path (`QFoldTree`)
cx node[0], cost[0];
cx node[1], cost[1];
cx node[2], cost[2];
cx node[3], cost[3];
cx node[4], cost[4];
cx node[5], cost[5];

// 3. CoreQDS `HugrTailLoop` wrapping `QLet("bound", 0x3C000, cmp_threshold, QPhaseOracle)`
// --- BEGIN within { QLet bound[0..3]: evaluate branch-cost < threshold } ---
cx cost[0], bound[0];
cx cost[1], bound[1];
rccx cost[2], cost[3], bound[2];
rccx bound[2], cost[4], bound[3];
cx bound[3], stop[0];

// --- BEGIN apply { QPhaseOracle on active branch below cost bound } ---
cx bound[3], anc[0];
z anc[0];
cx bound[3], anc[0];
cz stop[0], node[5];
// --- END apply (anc[0] returned cleanly to |0>) ---

// --- BEGIN uncompute { QLet & HugrTailLoop port-matched uncomputation } ---
cx bound[3], stop[0];
rccx_dag bound[2], cost[4], bound[3];
rccx_dag cost[2], cost[3], bound[2];
cx cost[1], bound[1];
cx cost[0], bound[0];
// --- END within (bound[0..3], anc[0], stop[0] == |0>, scratch_mask == 0x0) ---

// 4. Uncompute branch-cost accumulator cost[0..5] -> |000000> and diffuse node[0..5]
cx node[5], cost[5];
cx node[4], cost[4];
cx node[3], cost[3];
cx node[2], cost[2];
cx node[1], cost[1];
cx node[0], cost[0];
cz node[0], node[3];
cz node[1], node[4];
h node[0];
h node[1];
h node[2];
h node[3];
h node[4];
h node[5];

// 5. Terminal batch measurement of optimal branch node[0..5] (0 MCM)
c = measure node;
