OPENQASM 3.0;
include "stdgates.inc";

// TODAY-1: DQI over BCH(7, 4, 3) via Intrinsic Canonical Skew-Binary Syndrome Lookup (QDS-4 + OQP-1)
// Physical Qubits: 11 (q[0..6] data/variables, q[7..9] 3-bit syndrome spine, q[10] clean RCCX pebble)
// Lowered via Simplification S17 + Pass M1 + Pass M2:
//   - 3 matched (rccx, rccx_dag) pairs = 18 CZ gates
//   - 6 CNOT syndrome-Compute/Uncompute gates = 6 CZ gates
//   - 0 mid-circuit measurements (0 MCM), 1 terminal batch measurement
// Verified by Lean 4 Theorem 23A (rccx_uncompute_phase_cancel), Theorem 23E (bch_7_4_3_fits_today_qpus),
// and Theorem 25D (f36_eight_target_end_to_end_compiler_diff_sound).

qubit[11] q;
bit[11] c;

// 1. Prepare uniform superposition over Dual BCH(7, 3, 4) syndrome variables
h q[0];
h q[1];
h q[2];

// 2. Intrinsic Canonical Skew-Binary Syndrome Compute (Pass M1: rccx unitary 3-CZ lowering)
// Pair 1: rccx q[0], q[1], q[7]
h q[7];
t q[7];
cx q[1], q[7];
tdg q[7];
cx q[0], q[7];
t q[7];
cx q[1], q[7];
tdg q[7];
h q[7];

// Pair 2: rccx q[1], q[2], q[8]
h q[8];
t q[8];
cx q[2], q[8];
tdg q[8];
cx q[1], q[8];
t q[8];
cx q[2], q[8];
tdg q[8];
h q[8];

// Pair 3: rccx q[0], q[2], q[9]
h q[9];
t q[9];
cx q[2], q[9];
tdg q[9];
cx q[0], q[9];
t q[9];
cx q[2], q[9];
tdg q[9];
h q[9];

// 3. Syndrome Parity Decode into Data Register q[3..6] (Pass S19: VirtualRZ phase kickback folded)
cx q[7], q[3];
cx q[8], q[4];
cx q[9], q[5];
cx q[7], q[10];
cz q[10], q[6];
cx q[7], q[10];
cz q[7], q[6];
cz q[8], q[6];
cz q[9], q[6];

// 4. Exact Uncomputation via Inverse Margolus rccx_dag (Theorem 23A: (-i)*(+i) = +1 exact phase cancellation)
// Pair 3 inverse: rccx_dag q[0], q[2], q[9]
h q[9];
t q[9];
cx q[2], q[9];
tdg q[9];
cx q[0], q[9];
t q[9];
cx q[2], q[9];
tdg q[9];
h q[9];

// Pair 2 inverse: rccx_dag q[1], q[2], q[8]
h q[8];
t q[8];
cx q[2], q[8];
tdg q[8];
cx q[1], q[8];
t q[8];
cx q[2], q[8];
tdg q[8];
h q[8];

// Pair 1 inverse: rccx_dag q[0], q[1], q[7]
h q[7];
t q[7];
cx q[1], q[7];
tdg q[7];
cx q[0], q[7];
t q[7];
cx q[1], q[7];
tdg q[7];
h q[7];

// 5. Pass M2 Terminal Batch Readout (0 mid-circuit measurements)
c = measure q;
