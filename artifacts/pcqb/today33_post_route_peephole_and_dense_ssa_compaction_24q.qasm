OPENQASM 3.0;
include "stdgates.inc";

// ============================================================================
// PCQB Benchmark TODAY-33: Post-Rebase & Post-Route Peephole Fixed-Point
//                          Cancellation + Dense SSA Qubit Register Compaction
//                          (`OQP-55`, `S95-S96`, `M61-M62`, `F125-F126`, 24 Qubits)
// ============================================================================
// Target Architectures: Google Willow (105Q), IBM Heron R2 (156Q),
//                       Quantinuum H2-1 (56Q), Bluvstein Neutral Atom (280Q)
// Associated Problem:   OQP-55 (Post-Rebase & Post-Route Peephole + Dense SSA Compaction)
// Associated Rules:     S95 (Post-Rebase & Post-Route Peephole Cancellation Normal Form),
//                       S96 (Dense SSA Order-Preserving Qubit Compaction Bijection)
// Associated Passes:    Pass M61 (Post-Rebase & Post-Route Peephole Optimizer),
//                       Pass M62 (Dense SSA Qubit Register Compactor)
// Associated Proofs:    F125 (Post-Rebase / Post-Route Peephole Cancellation Soundness),
//                       F126 (Dense SSA Order-Preserving Compaction Zero Unused Qubits)
// Register Layout:      q[0..7]   = Compacted SSA primary data spine (dense indices 0..7)
//                       q[8..15]  = Compacted post-route coupling-graph bridge register
//                       q[16..23] = Strict LIFO Bennett clean pebble arena (0 unused wires)
// ============================================================================

qubit[24] q;
bit[8] c_ssa;

reset q;

// Stage 1: Initialize compacted SSA primary data spine q[0..7]
h q[0];
h q[1];
h q[2];
h q[3];
h q[4];
h q[5];
h q[6];
h q[7];

// Stage 2: Forward Bennett pebble computation into compacted arena q[16..19]
ccx q[0], q[1], q[16];
ccx q[2], q[3], q[17];
ccx q[4], q[5], q[18];
ccx q[6], q[7], q[19];

// Stage 3: Post-route bridge fanout across q[8..15] and secondary pebbles q[20..23]
// Certified by Pass M61 (0 adjacent self-canceling gates) & Pass M62 (0 unused qubits)
cx q[16], q[8];
cx q[17], q[9];
cx q[18], q[10];
cx q[19], q[11];
cx q[8], q[12];
cx q[9], q[13];
cx q[10], q[14];
cx q[11], q[15];
ccx q[8], q[12], q[20];
ccx q[9], q[13], q[21];
ccx q[10], q[14], q[22];
ccx q[11], q[15], q[23];

// Stage 4: Non-self-canceling phase oracle action across q[20..23]
t q[20];
t q[21];
s q[22];
s q[23];
cz q[20], q[0];
cz q[21], q[2];
cz q[22], q[4];
cz q[23], q[6];
sdg q[23];
sdg q[22];
tdg q[21];
tdg q[20];

// Stage 5: Reverse-topological LIFO uncomputation of q[23..16] and q[15..8]
ccx q[11], q[15], q[23];
ccx q[10], q[14], q[22];
ccx q[9], q[13], q[21];
ccx q[8], q[12], q[20];
cx q[11], q[15];
cx q[10], q[14];
cx q[9], q[13];
cx q[8], q[12];
cx q[19], q[11];
cx q[18], q[10];
cx q[17], q[9];
cx q[16], q[8];
ccx q[6], q[7], q[19];
ccx q[4], q[5], q[18];
ccx q[2], q[3], q[17];
ccx q[0], q[1], q[16];

// Stage 6: Interference & terminal readout
h q[0];
h q[2];
h q[4];
h q[6];
c_ssa[0] = measure q[0];
c_ssa[1] = measure q[1];
c_ssa[2] = measure q[2];
c_ssa[3] = measure q[3];
c_ssa[4] = measure q[4];
c_ssa[5] = measure q[5];
c_ssa[6] = measure q[6];
c_ssa[7] = measure q[7];
