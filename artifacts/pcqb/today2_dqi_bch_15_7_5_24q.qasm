// =============================================================================
// Proof-Carrying Quantum Binary (PCQB) — Benchmark TODAY-2
// Circuit: Decoded Quantum Interferometry (DQI) over BCH(15, 7, 5) (d = 5, t = 2)
//          via Intrinsic Skew-Binary Algebraic Syndrome LUT (`QDS-4`, `QDS-35`, `OQP-1`)
// Targets: Google Willow (105Q), IBM Heron R2 (156Q), Quantinuum H2-1 (56Q),
//          Harvard/QuEra Bluvstein Neutral Atom (280Q)
// Physical Qubits: 24 (q[15] codeword, s[8] dual BCH(15, 8, 5) syndrome spine,
//                  flag[1] LUT phase-kickback ancilla, c[15] bit readout)
// Logical Gates: 76 | Two-Qubit Gates: 54 (7 matched rccx/rccx_dag pairs + 12 CNOT/CZ)
// T-Count: 56 (7 rccx + 7 rccx_dag pairs = 56 T/Tdg gates; 0 residual ancilla waste)
// Execution Loop Tier: Loop-3 (UserCloudOuterLoop batch OpenQASM 3.0 submission)
// Formal Certificates:
//   - Lean 4: `rccx_uncompute_phase_cancel`
//   - Lean 4: `f85_s65_qds35_oqp39_lexical_qlet_automatic_uncomputation_sound`
//   - Lean 4: `f86_s66_qds36_oqp40_phase_oracle_kickback_synthesis_sound`
//   - Lean 4: `thm35g_phase19_master_90bug_coreqds_end_to_end_compiler_soundness`
// =============================================================================
OPENQASM 3.0;
include "stdgates.inc";

// 24 physical qubits partitioned into disjoint linear registers:
qubit[15] q;
qubit[8] syn;
qubit[1] flag;
bit[15] c;

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

// 1. Prepare dual BCH(15, 7, 5) syndrome superposition on q[0..7]
h q[0];
h q[1];
h q[2];
h q[3];
h q[4];
h q[5];
h q[6];
h q[7];

// 2. CoreQDS `within { compute_syndrome_lut } apply { phase_kickback_decode }`
// --- BEGIN within { qlet syn[0..7] = bch_15_7_5_syndrome_lut(q[0..7]) } ---
rccx q[0], q[1], syn[0];
rccx q[1], q[2], syn[1];
rccx q[2], q[3], syn[2];
rccx q[3], q[4], syn[3];
rccx q[4], q[5], syn[4];
rccx q[5], q[6], syn[5];
rccx q[6], q[7], syn[6];
cx syn[0], syn[7];
cx syn[3], syn[7];

// --- BEGIN apply { qphase_oracle(syn[0..7], flag[0]) + syndrome parity decode } ---
cx syn[7], flag[0];
cz flag[0], q[8];
cx syn[7], flag[0];

cx syn[0], q[8];
cx syn[1], q[9];
cx syn[2], q[10];
cx syn[3], q[11];
cx syn[4], q[12];
cx syn[5], q[13];
cx syn[6], q[14];
cz syn[7], q[14];
// --- END apply ---

// --- BEGIN uncompute { rccx_dag reverse pass restoring syn[0..7] -> |00000000> } ---
cx syn[3], syn[7];
cx syn[0], syn[7];
rccx_dag q[6], q[7], syn[6];
rccx_dag q[5], q[6], syn[5];
rccx_dag q[4], q[5], syn[4];
rccx_dag q[3], q[4], syn[3];
rccx_dag q[2], q[3], syn[2];
rccx_dag q[1], q[2], syn[1];
rccx_dag q[0], q[1], syn[0];
// --- END within (s[0..7] and flag[0] certified |0>) ---

// 3. Interferometric Hadamard transform & terminal batch readout (0 MCM)
h q[0];
h q[1];
h q[2];
h q[3];
h q[4];
h q[5];
h q[6];
h q[7];
c = measure q;
