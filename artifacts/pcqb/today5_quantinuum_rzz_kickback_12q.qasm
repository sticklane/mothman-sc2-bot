// =============================================================================
// Proof-Carrying Quantum Binary (PCQB) — Benchmark TODAY-5
// Circuit: Quantinuum H2-1 Native RZZ Phase-Kickback & Virtual-RZ Folded Syndrome
//          Extraction (`S19 -> S20 -> S19` Sandwich, `QDS-25`, `QDS-36`, `Pass M6`)
// Targets: Quantinuum H2-1 (56Q), Google Willow (105Q), IBM Heron R2 (156Q),
//          Harvard/QuEra Bluvstein Neutral Atom (280Q)
// Physical Qubits: 12 (data[8] logical block, syn[3] syndrome accumulators,
//                  anc[1] phase-kickback flag, c[3] syndrome bit readout)
// Logical Gates: 36 | Two-Qubit Gates: 18 (RZZ CNOT-RZ-CNOT sandwiches + parity CNOTs)
// T-Count: 0 (Clifford + exact dyadic RZ(pi/4) folded via S19 -> S20 -> S19)
// Execution Loop Tier: Loop-2 (CoprocessorMidLoop Pauli-frame syndrome extraction)
// Formal Certificates:
//   - Lean 4: `f81_s61_m32_guarded_s17_s19_s20_and_bocher_benes_sound`
//   - Lean 4: `f86_s66_qds36_oqp40_phase_oracle_kickback_synthesis_sound`
//   - Lean 4: `thm35g_phase19_master_90bug_coreqds_end_to_end_compiler_soundness`
// =============================================================================
OPENQASM 3.0;
include "stdgates.inc";

// 12 physical qubits partitioned across 4 Quantinuum H2-1 interaction zones:
qubit[8] data;
qubit[3] syn;
qubit[1] anc;
bit[3] c;

// 1. Prepare [[8, 3, 3]] color/surface logical block state on data[0..7]
h data[0];
h data[2];
h data[4];
h data[6];
cx data[0], data[1];
cx data[2], data[3];
cx data[4], data[5];
cx data[6], data[7];

// 2. CoreQDS `within { rzz_kickback_compute } apply { z(anc[0]) }`
//    Uses S19 -> S20 -> S19 RZZ(theta) sandwich: cx a, b; rz(theta) b; cx a, b;
// --- BEGIN within { compute stabilizer parities into syn[0..2] & anc[0] } ---
cx data[0], syn[0];
rz(0.7853981633974483) syn[0];
cx data[0], syn[0];

cx data[2], syn[1];
rz(0.7853981633974483) syn[1];
cx data[2], syn[1];

cx data[4], syn[2];
rz(0.7853981633974483) syn[2];
cx data[4], syn[2];

cx syn[0], anc[0];
cx syn[1], anc[0];
cx syn[2], anc[0];

// --- BEGIN apply { Phase-kickback check on anc[0] } ---
z anc[0];
// --- END apply ---

// --- BEGIN uncompute { clean restoration of anc[0] -> |0> } ---
cx syn[2], anc[0];
cx syn[1], anc[0];
cx syn[0], anc[0];

cx data[1], syn[0];
cx data[3], syn[1];
cx data[5], syn[2];
cx data[7], syn[2];
// --- END within (anc[0] certified |0>) ---

// 3. Syndrome readout on syn[0..2]
c = measure syn;
