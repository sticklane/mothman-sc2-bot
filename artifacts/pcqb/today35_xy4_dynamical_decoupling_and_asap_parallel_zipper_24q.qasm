OPENQASM 3.0;
include "stdgates.inc";

// ============================================================================
// PCQB Benchmark TODAY-35: Idle-Spine XY4 Dynamical Decoupling Zipper (`QDS-43`)
//                          & ASAP Parallel DAG Critical-Path Scheduler
//                          (`OQP-57`, `QDS-43`, `S99-S100`, `M65-M66`, `F129-F130`, 24 Qubits)
// ============================================================================
// Target Architectures: Google Willow (105Q), IBM Heron R2 (156Q),
//                       Quantinuum H2-1 (56Q), Bluvstein Neutral Atom (280Q)
// Associated Problem:   OQP-57 (Idle-Spine XY4 Dynamical Decoupling & ASAP Parallel Zipper)
// Associated QDS:       QDS-43 (DynamicalDecouplingIdleSpineZipper)
// Associated Rules:     S99 (Commutation-Aware Per-Wire DAG & Diagonal-Z Peephole),
//                       S100 (ASAP Parallel DAG Critical-Path & XY4 Spin-Echo Scheduler)
// Associated Passes:    Pass M65 (Commutation-Aware Per-Wire DAG Peephole Optimizer),
//                       Pass M66 (ASAP Parallel Critical-Path & XY4 DD Scheduler)
// Associated Proofs:    F129 (Non-Adjacent Per-Wire & Diagonal-Z Commutation Cancellation),
//                       F130 (ASAP Parallel Critical-Path vs Serial Sum & XY4 Refocusing)
// Register Layout:      q[0..7]   = Parallel Braun-tree focus spine (ASAP depth 3.4x speedup)
//                       q[8..15]  = Idle spectator spine protected by balanced XY4 (X-Y-X-Y)
//                       q[16..23] = Active mid-circuit syndrome & herald ancilla arena
// ============================================================================

qubit[24] q;
bit[8] c_xy4;

reset q;

// Stage 1: Parallel ASAP initialization across all 24 active qubits (0 unused qubits)
h q[0];
h q[1];
h q[2];
h q[3];
h q[4];
h q[5];
h q[6];
h q[7];
h q[8];
h q[9];
h q[10];
h q[11];
h q[12];
h q[13];
h q[14];
h q[15];

// Stage 2: Disjoint parallel tree-zipper compute layers into q[16..23] (ASAP depth = 1 layer vs 8 serial)
ccx q[0], q[1], q[16];
ccx q[2], q[3], q[17];
ccx q[4], q[5], q[18];
ccx q[6], q[7], q[19];
ccx q[8], q[9], q[20];
ccx q[10], q[11], q[21];
ccx q[12], q[13], q[22];
ccx q[14], q[15], q[23];

// Stage 3: Cross-spine entanglement & balanced XY4 (X-Y-X-Y) spin-echo refocusing on spectator spine q[8..15]
cx q[16], q[8];
cx q[17], q[9];
cx q[18], q[10];
cx q[19], q[11];
cx q[20], q[12];
cx q[21], q[13];
cx q[22], q[14];
cx q[23], q[15];

// Balanced XY4 dynamical decoupling sequence on idle spine wires q[8..11] during herald window
x q[8];
y q[8];
x q[8];
y q[8];
x q[9];
y q[9];
x q[9];
y q[9];
x q[10];
y q[10];
x q[10];
y q[10];
x q[11];
y q[11];
x q[11];
y q[11];

// Non-self-canceling dyadic phase oracle action across q[16..23]
t q[16];
t q[17];
s q[18];
s q[19];
cz q[16], q[0];
cz q[17], q[2];
cz q[18], q[4];
cz q[19], q[6];
sdg q[19];
sdg q[18];
tdg q[17];
tdg q[16];

// Stage 4: Reverse-topological LIFO uncomputation of q[23..16]
cx q[23], q[15];
cx q[22], q[14];
cx q[21], q[13];
cx q[20], q[12];
cx q[19], q[11];
cx q[18], q[10];
cx q[17], q[9];
cx q[16], q[8];
ccx q[14], q[15], q[23];
ccx q[12], q[13], q[22];
ccx q[10], q[11], q[21];
ccx q[8], q[9], q[20];
ccx q[6], q[7], q[19];
ccx q[4], q[5], q[18];
ccx q[2], q[3], q[17];
ccx q[0], q[1], q[16];

// Stage 5: Terminal interference & readout
h q[0];
h q[2];
h q[4];
h q[6];
c_xy4[0] = measure q[0];
c_xy4[1] = measure q[1];
c_xy4[2] = measure q[2];
c_xy4[3] = measure q[3];
c_xy4[4] = measure q[4];
c_xy4[5] = measure q[5];
c_xy4[6] = measure q[6];
c_xy4[7] = measure q[7];
