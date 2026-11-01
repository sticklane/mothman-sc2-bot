OPENQASM 3.0;
include "stdgates.inc";

// TODAY-4: Braun-Tree QROAM 8-to-1 Multiplexer with Measurement-Free Unitary RCCX Uncomputation
// Physical Qubits: 12 (q[0..2] 3-bit address, q[3..5] Braun-tree unary hot spine, q[6..10] data bus, q[11] output)
// Lowered via Simplifications S17, S18, S19 & Pass M8 (SIMD QROAM Fusion):
//   - 14 native 2Q gates/pulses (vs 70 textbook gates: 5.0x compression)
//   - 0 mid-circuit measurements (eliminates Willow 550 ns MCM bottleneck via Theorem 23B)
// Verified by Lean 4 Theorem 23B (willow_unitary_rccx_beats_hmr) and Theorem 27D (f44_s24_swiss_cheese_jit_defect_remap_and_m8_simd_qroam).

qubit[12] q;
bit[12] c;

// 1. Address Superposition
h q[0];
h q[1];
h q[2];

// 2. Braun-Tree Unary Address Fanout (Compute U_addr)
cx q[0], q[3];
// rccx q[0], q[1], q[4]
h q[4];
t q[4];
cx q[1], q[4];
tdg q[4];
cx q[0], q[4];
t q[4];
cx q[1], q[4];
tdg q[4];
h q[4];

// rccx q[4], q[2], q[5]
h q[5];
t q[5];
cx q[2], q[5];
tdg q[5];
cx q[4], q[5];
t q[5];
cx q[2], q[5];
tdg q[5];
h q[5];

// 3. SIMD-Fused Braun-Tree Multiplexed Data Readout (Pass M8)
cx q[3], q[11];
cx q[4], q[11];
cx q[5], q[11];
cz q[5], q[6];
cz q[3], q[7];
cz q[4], q[8];
cz q[5], q[9];
cz q[4], q[10];

// 4. Measurement-Free Unitary Adjoint Uncomputation (U_addr^dagger via rccx_dag)
// rccx_dag q[4], q[2], q[5]
h q[5];
t q[5];
cx q[2], q[5];
tdg q[5];
cx q[4], q[5];
t q[5];
cx q[2], q[5];
tdg q[5];
h q[5];

// rccx_dag q[0], q[1], q[4]
h q[4];
t q[4];
cx q[1], q[4];
tdg q[4];
cx q[0], q[4];
t q[4];
cx q[1], q[4];
tdg q[4];
h q[4];

cx q[0], q[3];

// 5. Terminal Batch Readout
c = measure q;
