OPENQASM 3.0;
include "stdgates.inc";

// ============================================================================
// PCQB Benchmark TODAY-34: Short-Last Multi-Channel Reserve Guard (`QDS-42`),
//                          Bilateral Phase-Octant Invariance & 672-Cell Matrix
//                          (`OQP-56`, `QDS-42`, `S97-S98`, `M63-M64`, `F127-F130`, 26 Qubits)
// ============================================================================
// Target Architectures: Google Willow (105Q), IBM Heron R2 (156Q),
//                       Quantinuum H2-1 (56Q), Bluvstein Neutral Atom (280Q)
// Associated Problem:   OQP-56 (Short-Last Multi-Channel Reserve + Bilateral Phase Octant)
// Associated QDS:       QDS-42 (Short-Last Multi-Channel Reserve-Guarded Quantum Deque)
// Associated Rules:     S97 (Short-Last Multi-Channel Reserve Guard & Komlos h+1 Bound),
//                       S98 (Bilateral Phase-Octant & KAK Weyl Chamber Invariance)
// Associated Passes:    Pass M63 (Short-Last Multi-Channel Reserve Auditor),
//                       Pass M64 (Bilateral Phase-Octant Invariance Checker)
// Associated Proofs:    F127 (Short-Last Multi-Channel Reserve Guard Soundness),
//                       F128 (Bilateral Phase-Octant Z/8Z Invariance Soundness),
//                       F129 (Complete 672-Cell 56 OQPs x 12 Targets Matrix Soundness),
//                       F130 (Complete 34/34 PCQB Bundle & Phase 27 Master Closure)
// Register Layout:      q[0..7]   = Multi-channel priority-sorted worklist spine (QDS-42)
//                       q[8..15]  = Bilateral Z/8Z phase-octant & Weyl-chamber register
//                       q[16..21] = Short-last reserve-guarded pebble pool (h+1 <= R_pool)
//                       q[22..25] = Bilateral phase-octant syndrome & invariant witnesses
// ============================================================================

qubit[26] q;
bit[8] c_reserve;

reset q;

// Stage 1: Prepare multi-channel worklist spine q[0..7] in short-last order (tau_1 >= ... >= tau_k)
h q[0];
h q[1];
h q[2];
h q[3];
h q[4];
h q[5];
h q[6];
h q[7];

// Stage 2: Short-last multi-channel pebble allocation into reserve pool q[16..21] (Pass M63, QDS-42)
ccx q[0], q[1], q[16];
ccx q[2], q[3], q[17];
ccx q[4], q[5], q[18];
ccx q[6], q[7], q[19];
ccx q[16], q[17], q[20];
ccx q[18], q[19], q[21];

// Stage 3: Bilateral Z/8Z phase-octant transform across q[8..15] and witness wires q[22..25] (Pass M64)
cx q[16], q[8];
cx q[17], q[9];
cx q[18], q[10];
cx q[19], q[11];
cx q[20], q[12];
cx q[21], q[13];
cx q[12], q[14];
cx q[13], q[15];
cx q[14], q[22];
cx q[15], q[23];
cx q[20], q[24];
cx q[21], q[25];

// Bilateral phase-octant rotation sum = 0 (mod 8): (+1 + 1 + 2 + 4 = 8 == 0 mod 8)
t q[8];
t q[9];
s q[10];
z q[11];
cz q[22], q[8];
cz q[23], q[9];
cz q[24], q[10];
cz q[25], q[11];
z q[11];
sdg q[10];
tdg q[9];
tdg q[8];

// Stage 4: Strict reverse-topological LIFO uncomputation of witness & reserve pool wires
cx q[21], q[25];
cx q[20], q[24];
cx q[15], q[23];
cx q[14], q[22];
cx q[13], q[15];
cx q[12], q[14];
cx q[21], q[13];
cx q[20], q[12];
cx q[19], q[11];
cx q[18], q[10];
cx q[17], q[9];
cx q[16], q[8];
ccx q[18], q[19], q[21];
ccx q[16], q[17], q[20];
ccx q[6], q[7], q[19];
ccx q[4], q[5], q[18];
ccx q[2], q[3], q[17];
ccx q[0], q[1], q[16];

// Stage 5: Interference & terminal readout
h q[0];
h q[1];
h q[2];
h q[3];
c_reserve[0] = measure q[0];
c_reserve[1] = measure q[1];
c_reserve[2] = measure q[2];
c_reserve[3] = measure q[3];
c_reserve[4] = measure q[4];
c_reserve[5] = measure q[5];
c_reserve[6] = measure q[6];
c_reserve[7] = measure q[7];
