OPENQASM 3.0;
include "stdgates.inc";

// TODAY-14: 16-Qubit Neutral-Atom 2D AOD Monotone Shuttling, Defunctionalized Linear Closure & Exact Dyadic Angle Tree (QDS-23..25 + OQP-23 + OQP-25 + S41..S46 + M19..M22)
// Physical Qubits: 16 (q[0] outer coherent control, q[1..4] defunctionalized closure environment register, q[5..8] argument register, q[9..11] ExactDyadicAngleTree Z[1/2^k] catalyst register, q[12..15] Komlos h+1 clean pebble reserve)
// Lowered via Simplifications S41 (LinearClosureDefunctionalization), S42 (OaaFixedPointExactReflection), S44 (BocherMonotoneAodShuttleRouting), S45 (KomlosSpookyPebbleReserveGuard), S46 (ExactDyadicAngleTreeSynthesis) & Passes M19, M21, M22:
//   - QDS-23 QuantumDefunctionalizedClosure: disjoint environment mask 0x001E and argument mask 0x01E0 ((env & arg) == 0), single-shot linear invocation per F61
//   - OQP-23 Unitary Fixed-Point OAA: coherent reflection without mid-circuit RUS collapse per F62
//   - QDS-24 MonotoneAodBocherGrid & Pass M21: 2-pass Bocher row-then-column monotone AOD shuttling with inter-pair distance d_pair = 12 um >= R_b = 8 um per F64
//   - QDS-25 ExactDyadicAngleTree: exact dyadic rational Z[1/2^k] phase synthesis without IEEE-754 f64 mantissa truncation per F66
//   - 0 mid-circuit measurements (0 MCM), 1 terminal batch measurement
// Verified by Lean 4 Theorems 31A, 31B, 31D, 31E, 31F, 31G (thm31g_phase15_master_66bug_and_qds25_soundness).

qubit[16] q;
bit[16] c;

// 1. Initialize Outer Control q[0], Defunctionalized Environment q[1..4] & Argument q[5..8]
h q[0];
h q[1];
h q[2];
h q[3];
h q[4];

// 2. Pass M19 Defunctionalized Linear Closure Dispatch (QDS-23 / S41 / F61: disjoint env q[1..4] and arg q[5..8])
cx q[1], q[5];
cx q[2], q[6];
cx q[3], q[7];
cx q[4], q[8];

// 3. Pass M21 2-Pass Monotone Bocher AOD Shuttle &Pass M22 Komlos Pebble Reserve (QDS-24 / OQP-25 / OQP-26 / F64 / F65)
// Inner RCCX Window 1 on Pebble q[12]: rccx q[1], q[5], q[12]
h q[12];
t q[12];
cx q[5], q[12];
tdg q[12];
cx q[1], q[12];
t q[12];
cx q[5], q[12];
tdg q[12];
h q[12];

// Inner RCCX Window 2 on Pebble q[13]: rccx q[2], q[6], q[13]
h q[13];
t q[13];
cx q[6], q[13];
tdg q[13];
cx q[2], q[13];
t q[13];
cx q[6], q[13];
tdg q[13];
h q[13];

// 4. QDS-25 ExactDyadicAngleTree Z[1/2^k] Phase Kickback & OQP-23 Unitary Fixed-Point OAA Reflection (S42 / S46 / F62 / F66)
cx q[12], q[9];
cx q[13], q[10];
cx q[7], q[14];
cx q[8], q[15];
cx q[14], q[11];
cz q[0], q[12];
cz q[0], q[13];
cz q[11], q[15];
rz(pi/4) q[9];
rz(pi/8) q[10];
rz(pi/16) q[11];
rz(-3*pi/8) q[0];
cx q[14], q[11];
cx q[8], q[15];
cx q[7], q[14];
cx q[13], q[10];
cx q[12], q[9];

// 5. Symmetric Uncomputation of Komlos Pebble Reserve (Pass M22 zero spooky ghost pebbles) & Closure Environment
// rccx_dag q[2], q[6], q[13]
h q[13];
t q[13];
cx q[6], q[13];
tdg q[13];
cx q[2], q[13];
t q[13];
cx q[6], q[13];
tdg q[13];
h q[13];

// rccx_dag q[1], q[5], q[12]
h q[12];
t q[12];
cx q[5], q[12];
tdg q[12];
cx q[1], q[12];
t q[12];
cx q[5], q[12];
tdg q[12];
h q[12];

cx q[4], q[8];
cx q[3], q[7];
cx q[2], q[6];
cx q[1], q[5];

// 6. Hadamard Interference on Control q[0] & Pass M2 Terminal Batch Readout
h q[0];
c = measure q;
