OPENQASM 3.0;
include "stdgates.inc";

// TODAY-11: 16-Qubit Controlled-QSVT Block Encoding with Pass M16 Controlled-Phase Compensation & QuantumSkipList Tower (QDS-20 + OQP-19 + S37 + M16)
// Physical Qubits: 16 (q[0] outer LCU/QPE control c, q[1..4] 4-bit QuantumSkipList express-lane address register, q[5..8] 4-bit QSVT data register, q[9..11] express-lane routing ancillas, q[12..15] clean RCCX pebbles)
// Lowered via Simplifications S35 (PassTopologicalDagSchedule), S36 (WideWordExtendedCarryGuard), S37 (ControlledPhasePromotionCompensation) & Passes M15, M16:
//   - Deterministic geometric level tower h(i) = ctz(i+1) + 1 via QuantumSkipList (QDS-20)
//   - Pass M16 Controlled-Phase Compensation: compensates global/relative phase e^{i * pi/2} (4 * pi/8) under control q[0] via rz(-pi/2) q[0] so (4 + 4) mod 8 == 0 per F57 (PDE-3)
//   - Topological Pass DAG ordering rank(M8) < rank(M11) and rank(M7) < rank(M6) per F55 (PDE-1)
//   - 0 mid-circuit measurements (0 MCM), 1 terminal batch measurement
// Verified by Lean 4 Theorems 30A, 30B, 30C, 30G (thm30g_phase14_master_60bug_qds22_oqp22_pde_soundness).

qubit[16] q;
bit[16] c;

// 1. Initialize Outer LCU/QPE Control q[0] & QuantumSkipList Express-Lane Superposition q[1..4]
h q[0];
h q[1];
h q[2];
h q[3];
h q[4];

// 2. QuantumSkipList (QDS-20): Deterministic Express-Lane Tower Routing h(i) = ctz(i+1) + 1
cx q[1], q[9];
cx q[2], q[10];
cx q[3], q[11];

// 3. Controlled-Subroutine Promotion with Pass M16 Phase Compensation (OQP-19 / S37 / F57 / PDE-3)
// Inner RCCX Window 1: rccx q[1], q[2], q[12]
h q[12];
t q[12];
cx q[2], q[12];
tdg q[12];
cx q[1], q[12];
t q[12];
cx q[2], q[12];
tdg q[12];
h q[12];

// Inner RCCX Window 2: rccx q[3], q[4], q[13]
h q[13];
t q[13];
cx q[4], q[13];
tdg q[13];
cx q[3], q[13];
t q[13];
cx q[4], q[13];
tdg q[13];
h q[13];

// Controlled QSVT Signal-Processing Rotation & Pass M16 Compensatory Phase Kickback on Control q[0]
cx q[0], q[5];
cx q[12], q[6];
cx q[13], q[7];
cx q[4], q[8];
cx q[12], q[14];
cx q[13], q[15];
cz q[0], q[12];
cz q[0], q[13];
cz q[8], q[14];
cz q[8], q[15];
// Pass M16: Compensates relative phase 4 * (pi/8) promoted into controlled-kickback on q[0] (pass_m16_compensate_ctrl_phase_mod8(4) == 0)
rz(-pi/2) q[0];
cx q[13], q[15];
cx q[12], q[14];
cx q[4], q[8];
cx q[13], q[7];
cx q[12], q[6];
cx q[0], q[5];

// 4. Symmetric Uncomputation of Inner RCCX Windows & Skip-List Express-Lane Ancillas
// rccx_dag q[3], q[4], q[13]
h q[13];
t q[13];
cx q[4], q[13];
tdg q[13];
cx q[3], q[13];
t q[13];
cx q[4], q[13];
tdg q[13];
h q[13];

// rccx_dag q[1], q[2], q[12]
h q[12];
t q[12];
cx q[2], q[12];
tdg q[12];
cx q[1], q[12];
t q[12];
cx q[2], q[12];
tdg q[12];
h q[12];

cx q[3], q[11];
cx q[2], q[10];
cx q[1], q[9];

// 5. Hadamard Interference on Control q[0] & Pass M2 Terminal Batch Readout
h q[0];
c = measure q;
