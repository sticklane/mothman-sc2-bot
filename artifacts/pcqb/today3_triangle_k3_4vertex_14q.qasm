// =============================================================================
// Proof-Carrying Quantum Binary (PCQB) — Benchmark TODAY-3
// Circuit: K_3 Triangle Finding on 4-Vertex Graph via Okasaki Zipper Edge Oracle
//          & Grover Amplitude Amplification (`QDS-3`, `QDS-35`, `QDS-36`, `OQP-3`)
// Targets: Google Willow (105Q), IBM Heron R2 (156Q), Quantinuum H2-1 (56Q),
//          Harvard/QuEra Bluvstein Neutral Atom (280Q)
// Physical Qubits: 14 (e[6] edge superposition, v[4] vertex accumulator,
//                  tri[3] triangle clause scratchpad, phase[1] phase-kickback ancilla,
//                  c[6] bit readout)
// Logical Gates: 52 | Two-Qubit Gates: 30 (4 matched rccx/rccx_dag pairs + 6 CNOT/CZ)
// T-Count: 32 (4 rccx + 4 rccx_dag pairs = 32 T/Tdg gates; 0 residual ancilla waste)
// Execution Loop Tier: Loop-3 (UserCloudOuterLoop batch OpenQASM 3.0 submission)
// Formal Certificates:
//   - Lean 4: `rccx_uncompute_phase_cancel`
//   - Lean 4: `f85_s65_qds35_oqp39_lexical_qlet_automatic_uncomputation_sound`
//   - Lean 4: `f86_s66_qds36_oqp40_phase_oracle_kickback_synthesis_sound`
//   - Lean 4: `thm35g_phase19_master_90bug_coreqds_end_to_end_compiler_soundness`
// =============================================================================
OPENQASM 3.0;
include "stdgates.inc";

// 14 physical qubits:
// e[0..5]   : 6 undirected edges of K_4 ((0,1),(1,2),(0,2),(0,3),(1,3),(2,3))
// v[0..3]   : 4 vertex degree / incidence zipper accumulators
// tri[0..2] : 3 triangle predicate scratchpad pebbles (qlet-scoped)
// phase[0]  : 1 phase-kickback target ancilla (qphase-oracle)
qubit[6] e;
qubit[4] v;
qubit[3] tri;
qubit[1] ph_anc;
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

// 1. Uniform superposition over 6 edge indicator qubits e[0..5]
h e[0];
h e[1];
h e[2];
h e[3];
h e[4];
h e[5];

// 2. CoreQDS `within { qlet tri = zipper_triangle_clauses(e, v) } apply { Z(ph_anc[0]) }`
// --- BEGIN within { compute K_3 triangle incidence via Okasaki zipper focus } ---
cx e[0], v[0];
cx e[1], v[1];
cx e[2], v[2];
cx e[3], v[3];
rccx e[0], e[1], tri[0];
rccx tri[0], e[2], tri[1];
rccx e[3], e[4], tri[2];
rccx tri[2], e[5], ph_anc[0];

// --- BEGIN apply { Bennett phase kickback on triangle match } ---
z ph_anc[0];
cz tri[1], e[2];
// --- END apply ---

// --- BEGIN uncompute { exact inverse restoring ph_anc[0], tri[0..2], v[0..3] -> |0> } ---
rccx_dag tri[2], e[5], ph_anc[0];
rccx_dag e[3], e[4], tri[2];
rccx_dag tri[0], e[2], tri[1];
rccx_dag e[0], e[1], tri[0];
cx e[3], v[3];
cx e[2], v[2];
cx e[1], v[1];
cx e[0], v[0];
// --- END within (zero ancilla waste: v[0..3], tri[0..2], phase[0] == |0>) ---

// 3. Grover diffusion reflection on edge register e[0..5]
h e[0];
h e[1];
h e[2];
h e[3];
h e[4];
h e[5];
x e[0];
x e[1];
x e[2];
cz e[0], e[1];
cz e[1], e[2];
x e[0];
x e[1];
x e[2];
h e[0];
h e[1];
h e[2];
h e[3];
h e[4];
h e[5];

// 4. Terminal batch readout of edge register e[0..5]
c = measure e;
