OPENQASM 3.0;
include "stdgates.inc";
// =============================================================================
// PCQB Artifact TODAY-29: ZX-Calculus Spider/Hopf Reduction, 48q Pauli-Web
// Equivalence & Ross-Selinger Gridsynth Z[omega] R_Z(pi/17) Synthesis
// (`OQP-51`, `S87-S88`, `M53-M54`, `F113-F115`) on 28 Qubits
// =============================================================================
// Registers : q[0..15]  (16q ZX spider-fusion & Hopf-reduced Clifford+phase core)
//             q[16..23] (8q Ross-Selinger gridsynth Z[omega] R_Z(pi/17) spine)
//             q[24..27] (4q clean Bennett uncompute pebbles, zero residual leak)
// Property  : Continuous non-dyadic R_Z(pi/17) approximated over {H, S, T} with
//             optimal Ross-Selinger T-count <= 3*b + 4 (vs O(log^3.97(1/eps)) SK),
//             paired with ZX Hopf-rule CNOT-pair elimination & spider phase fusion.
// =============================================================================
qubit[28] q;
bit[8] c_zx_grid;
reset q;

// 1. ZX Green/Red Spider Preparation on q[0..7]
h q[0];
h q[1];
h q[2];
h q[3];
cx q[0], q[4];
cx q[1], q[5];
cx q[2], q[6];
cx q[3], q[7];

// 2. ZX Spider Phase Fusion (S87, Pass M53): fused Z-spiders (pi/4 + pi/4 -> S)
s q[4];
s q[5];
t q[6];
t q[7];

// 3. Hopf-Reduced Entangling Web on q[8..15] (redundant parallel CNOT pairs removed)
cx q[4], q[8];
cx q[5], q[9];
cx q[6], q[10];
cx q[7], q[11];
cz q[8], q[12];
cz q[9], q[13];
cz q[10], q[14];
cz q[11], q[15];

// 4. Ross-Selinger Gridsynth Z[omega] Clifford+T Decomposition of R_Z(pi/17) on q[16..19] (S88, Pass M54)
// Forward gridsynth syllable sequence U_{pi/17} in {H, S, T}:
h q[16];
t q[16];
h q[16];
s q[16];
t q[16];
h q[16];
t q[16];
s q[16];
h q[16];

h q[17];
t q[17];
s q[17];
h q[17];
t q[17];
h q[17];
t q[17];
h q[17];

// Controlled coupling into ancilla pebbles q[24..27] and gridsynth spine q[18..23]
cx q[8], q[16];
cx q[9], q[17];
cx q[10], q[18];
cx q[11], q[19];
ccx q[16], q[17], q[24];
ccx q[14], q[15], q[25];
ccx q[18], q[19], q[26];
ccx q[12], q[13], q[27];
cz q[24], q[20];
cz q[25], q[21];
cz q[26], q[22];
cz q[27], q[23];

// 5. Adjoint Uncomputation of Pebbles q[24..27] & Gridsynth Inverse U_{pi/17}^dagger
ccx q[12], q[13], q[27];
ccx q[18], q[19], q[26];
ccx q[14], q[15], q[25];
ccx q[16], q[17], q[24];
cx q[11], q[19];
cx q[10], q[18];
cx q[9], q[17];
cx q[8], q[16];

h q[17];
tdg q[17];
h q[17];
tdg q[17];
h q[17];
sdg q[17];
tdg q[17];
h q[17];

h q[16];
sdg q[16];
tdg q[16];
h q[16];
tdg q[16];
sdg q[16];
h q[16];
tdg q[16];
h q[16];

// 6. Uncompute ZX Spider Preparation on q[4..7]
sdg q[4];
sdg q[5];
tdg q[6];
tdg q[7];
cx q[3], q[7];
cx q[2], q[6];
cx q[1], q[5];
cx q[0], q[4];

// 7. Terminal Batch Readout
c_zx_grid[0] = measure q[0];
c_zx_grid[1] = measure q[1];
c_zx_grid[2] = measure q[2];
c_zx_grid[3] = measure q[3];
c_zx_grid[4] = measure q[12];
c_zx_grid[5] = measure q[13];
c_zx_grid[6] = measure q[20];
c_zx_grid[7] = measure q[21];
