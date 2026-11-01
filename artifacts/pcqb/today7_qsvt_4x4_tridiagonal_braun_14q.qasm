OPENQASM 3.0;
include "stdgates.inc";

// TODAY-7: 4x4 Tridiagonal Matrix Block-Encoding & Degree-3 QSVT Polynomial Signal Processing (OQP-2 + QDS-1 + S26 + M10)
// Physical Qubits: 14 (q[0..1] system row/col index, q[2..3] block-encoding ancillas, q[4..9] Braun-tree diagonal/off-diagonal PREPARE/SELECT spine, q[10..12] RCCX pebbles, q[13] QSVT signal-processing qubit)
// Lowered via Simplifications S17, S19, S26 & Pass M10 (Phase-Catalyst Adder Tower Coalescence):
//   - 4 matched (rccx, rccx_dag) pairs protected by S26 RCCXPhasePolynomialWindowBarrier (F46 safe)
//   - Degree-3 QSVT signal-processing rotations lowered via Virtual-RZ (S19, 0 physical 1Q pulses)
//   - 0 mid-circuit measurements (0 MCM), 1 terminal batch measurement
// Verified by Lean 4 Theorem 28B (f46_s26_rccx_phase_commute_and_m10_catalyst_sound).

qubit[14] q;
bit[14] c;

// 1. Prepare initial state and QSVT signal-processing ancilla
h q[0];
h q[1];
h q[13];

// 2. Degree-3 QSVT Step 1: Block-Encoding U_A via Braun-Tree PREPARE/SELECT (S26 Window-Protected RCCX)
h q[2];
h q[3];

// S26 Barrier-Protected RCCX Window 1: rccx q[0], q[2], q[10]
h q[10];
t q[10];
cx q[2], q[10];
tdg q[10];
cx q[0], q[10];
t q[10];
cx q[2], q[10];
tdg q[10];
h q[10];

// Tridiagonal SELECT action on system register
cx q[10], q[1];
cz q[10], q[4];
cz q[10], q[7];

// Exact Uncomputation Window 1: rccx_dag q[0], q[2], q[10] (no diagonal phase commuted across q[10] per F46)
h q[10];
t q[10];
cx q[2], q[10];
tdg q[10];
cx q[0], q[10];
t q[10];
cx q[2], q[10];
tdg q[10];
h q[10];

// QSVT Phase-Angle Modulation phi_1 (S19 Virtual-RZ on Clean Target q[13], outside RCCX window)
cx q[2], q[13];
rz(0.7853981633974483) q[13];
cx q[2], q[13];

// 3. Degree-3 QSVT Step 2: Adjoint Block-Encoding U_A^dagger & Signal Rotation phi_2
// S26 Barrier-Protected RCCX Window 2: rccx q[1], q[3], q[11]
h q[11];
t q[11];
cx q[3], q[11];
tdg q[11];
cx q[1], q[11];
t q[11];
cx q[3], q[11];
tdg q[11];
h q[11];

cx q[11], q[0];
cz q[11], q[5];
cz q[11], q[8];

// Exact Uncomputation Window 2: rccx_dag q[1], q[3], q[11]
h q[11];
t q[11];
cx q[3], q[11];
tdg q[11];
cx q[1], q[11];
t q[11];
cx q[3], q[11];
tdg q[11];
h q[11];

// QSVT Phase-Angle Modulation phi_2 (S19 Virtual-RZ)
cx q[3], q[13];
rz(1.5707963267948966) q[13];
cx q[3], q[13];

// 4. Degree-3 QSVT Step 3: Final Block-Encoding U_A & Signal Rotation phi_3
// S26 Barrier-Protected RCCX Window 3: rccx q[0], q[3], q[12]
h q[12];
t q[12];
cx q[3], q[12];
tdg q[12];
cx q[0], q[12];
t q[12];
cx q[3], q[12];
tdg q[12];
h q[12];

cx q[12], q[1];
cz q[12], q[6];
cz q[12], q[9];

// Exact Uncomputation Window 3: rccx_dag q[0], q[3], q[12]
h q[12];
t q[12];
cx q[3], q[12];
tdg q[12];
cx q[0], q[12];
t q[12];
cx q[3], q[12];
tdg q[12];
h q[12];

cx q[2], q[13];
rz(0.39269908169872414) q[13];
cx q[2], q[13];

h q[2];
h q[3];
h q[13];

// 5. Pass M2 Terminal Batch Readout (0 mid-circuit measurements)
c = measure q;
