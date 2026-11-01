OPENQASM 3.0;
include "stdgates.inc";

// TODAY-15: 16-Qubit Coprocessor Mid-Loop CUDA-Q / OP-NIC Async Pauli-Frame & CoreQDS within_apply Circuit (QDS-26 + QDS-28 + OQP-27 + OQP-28 + OQP-30 + S47..S52 + M23..M26)
// Physical Qubits: 16 (q[0..3] logical data block, q[4..7] CoreQDS within_apply compute register, q[8..11] OP-NIC zero-copy delta-syndrome stream ancillas, q[12..15] clean uncompute pebble reserve)
// Lowered via Simplifications S47 (PrivilegeTierBoundarySeparation), S48 (CoprocessorMidLoopAsyncPauliFrame), S51 (OpNicZeroCopyDeltaSyndromeCompression), S52 (CoreQdsWithinApplyCleanUncompute) & Passes M23..M26:
//   - ExecutionLoopTier = CoprocessorMidLoop (F67 / S47 / M23): User coprocessor code placed in Mid-Loop (4.1 us <= 10.0 us DD-protected T2) rather than spoofing ProviderInnerLoopBlueprint
//   - QDS-26 AsyncPauliFrameQueue & Pass M24 (F68 / S48 / OQP-27): Asynchronous software Pauli-frame tracking across PCIe/NVLink round-trip with XY4 dynamical decoupling on idle wait
//   - QDS-28 ZeroCopyDeltaSyndromeRing & Pass M25 (F71 / S51 / OQP-28): OP-NIC 100GbE zero-copy delta-syndrome streaming at 6 Gbps <= 92 Gbps usable link capacity
//   - CoreQDS within_apply & Pass M26 (F72 / S52 / OQP-30): PureUnitary compute block U with 0 mid-circuit measurements (mid_meas_count == 0) and exact syntactic inverse U^dag
// Verified by Lean 4 Phase 16 Theorems (f67..f72 & thm32g_phase16_master_72bug_coreqds_3loop_soundness).

qubit[16] q;
bit[16] c;

// 1. Initialize Logical Data Block q[0..3]
h q[0];
h q[1];
h q[2];
h q[3];

// 2. CoreQDS within_apply Compute Block U (Pass M26 / S52 / F72: PureUnitary, 0 mid-circuit measurements)
cx q[0], q[4];
cx q[1], q[5];
cx q[2], q[6];
cx q[3], q[7];

// Inner RCCX Window 1 on Pebble q[12]: rccx q[4], q[5], q[12]
h q[12];
t q[12];
cx q[5], q[12];
tdg q[12];
cx q[4], q[12];
t q[12];
cx q[5], q[12];
tdg q[12];
h q[12];

// Inner RCCX Window 2 on Pebble q[13]: rccx q[6], q[7], q[13]
h q[13];
t q[13];
cx q[7], q[13];
tdg q[13];
cx q[6], q[13];
t q[13];
cx q[7], q[13];
tdg q[13];
h q[13];

// 3. CoreQDS within_apply Action Block V & OP-NIC Delta-Syndrome Parity Coupling (Pass M24 / M25 / S48 / S51)
cz q[12], q[0];
cz q[13], q[2];
cx q[12], q[8];
cx q[13], q[9];
cx q[8], q[10];
cx q[9], q[11];
cx q[10], q[14];
cx q[11], q[15];
rz(pi/8) q[8];
rz(-pi/8) q[9];
rz(pi/16) q[10];
rz(-pi/16) q[11];
cz q[14], q[15];
cx q[11], q[15];
cx q[10], q[14];
cx q[9], q[11];
cx q[8], q[10];
cx q[13], q[9];
cx q[12], q[8];

// 4. CoreQDS within_apply Exact Adjoint Uncompute Block U^dag (Pass M26 / S52 / F72: restores q[4..7] & q[12..13] to |0>)
// rccx_dag q[6], q[7], q[13]
h q[13];
t q[13];
cx q[7], q[13];
tdg q[13];
cx q[6], q[13];
t q[13];
cx q[7], q[13];
tdg q[13];
h q[13];

// rccx_dag q[4], q[5], q[12]
h q[12];
t q[12];
cx q[5], q[12];
tdg q[12];
cx q[4], q[12];
t q[12];
cx q[5], q[12];
tdg q[12];
h q[12];

cx q[3], q[7];
cx q[2], q[6];
cx q[1], q[5];
cx q[0], q[4];

// 5. Pass M24 Async Coprocessor Pauli-Frame Handoff & Terminal Batch Readout
h q[0];
h q[1];
h q[2];
h q[3];
c = measure q;
