OPENQASM 3.0;
include "stdgates.inc";

// ============================================================================
// PCQB Benchmark TODAY-37: Physical Coherent Z-Detuning Noise Channel for XY4
//                          Dynamical Decoupling + QDS-44 Live-Range Chordal
//                          Ancilla-Recycling Zipper (`QDS-43`, `QDS-44`, `OQP-59`,
//                          `S106`, `M72`, `F136`, 24 Qubits)
// ============================================================================
// Target Architectures: Google Willow (105Q), IBM Heron R2 (156Q),
//                       Quantinuum H2-1 (56Q), Bluvstein Neutral Atom (280Q)
// Associated Problems:  OQP-57 (XY4 Dynamical Decoupling Idle-Spine Zipper),
//                       OQP-59 (Live-Range Chordal Ancilla-Recycling Zipper)
// Associated QDS:       QDS-43 (DynamicalDecouplingIdleSpineZipper),
//                       QDS-44 (LiveRangeChordalAncillaRecyclingZipper)
// Associated Rules:     S106 (Physical Coherent-Detuning Noise Channel & Chordal Recycling)
// Associated Passes:    Pass M72 (Noisy XY4 Channel & Chordal Ancilla Recycling Pass)
// Associated Proofs:    F136 (Unprotected Z-Detuning Decay & Unrecycled Ancilla Blowup)
// Register Layout:      q[0..11]  = 12 data & spine wires across 3 sequential within_apply windows
//                       q[12..15] = 4 recycled clean ancilla pebbles (reused 3x across windows, peak 4 vs 12)
//                       q[16..19] = 4 idle spectator wires protected by balanced 4-pulse XY4 sequence
//                       q[20..23] = 4 phase-kickback & syndrome verification witnesses
// ============================================================================

qubit[24] q;
bit[12] c_out;

reset q;

// Stage 1: Initialize 12 data wires q[0..11] and 4 spectator wires q[16..19] in |+>
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
h q[16];
h q[17];
h q[18];
h q[19];

// Stage 2: Window 1 of QDS-44 LiveRangeChordalAncillaRecyclingZipper on q[0..3] using ancillas q[12..15]
ccx q[0], q[1], q[12];
ccx q[2], q[3], q[13];
ccx q[0], q[2], q[14];
ccx q[1], q[3], q[15];
cx q[12], q[20];
cx q[13], q[21];
cz q[14], q[0];
cz q[15], q[1];
ccx q[1], q[3], q[15];
ccx q[0], q[2], q[14];
ccx q[2], q[3], q[13];
ccx q[0], q[1], q[12];

// Stage 3: First half of QDS-43 balanced 4-pulse XY4 dynamical decoupling on idle spectators q[16..19]
x q[16];
x q[17];
x q[18];
x q[19];
y q[16];
y q[17];
y q[18];
y q[19];

// Stage 4: Window 2 of QDS-44 recycling the SAME 4 clean ancillas q[12..15] on data q[4..7]
ccx q[4], q[5], q[12];
ccx q[6], q[7], q[13];
ccx q[4], q[6], q[14];
ccx q[5], q[7], q[15];
cx q[14], q[22];
cx q[15], q[23];
cz q[12], q[4];
cz q[13], q[5];
ccx q[5], q[7], q[15];
ccx q[4], q[6], q[14];
ccx q[6], q[7], q[13];
ccx q[4], q[5], q[12];

// Stage 5: Second half of QDS-43 balanced 4-pulse XY4 dynamical decoupling on idle spectators q[16..19]
x q[16];
x q[17];
x q[18];
x q[19];
y q[16];
y q[17];
y q[18];
y q[19];

// Stage 6: Window 3 of QDS-44 recycling the SAME 4 clean ancillas q[12..15] on data q[8..11]
ccx q[8], q[9], q[12];
ccx q[10], q[11], q[13];
ccx q[8], q[10], q[14];
ccx q[9], q[11], q[15];
t q[20];
t q[21];
s q[22];
s q[23];
cz q[20], q[8];
cz q[21], q[9];
cz q[22], q[10];
cz q[23], q[11];
sdg q[23];
sdg q[22];
tdg q[21];
tdg q[20];
ccx q[9], q[11], q[15];
ccx q[8], q[10], q[14];
ccx q[10], q[11], q[13];
ccx q[8], q[9], q[12];

// Stage 7: Uncompute witness register q[20..23] using Window 1 & 2 re-evaluation on recycled q[12..15]
ccx q[4], q[6], q[14];
ccx q[5], q[7], q[15];
cx q[15], q[23];
cx q[14], q[22];
ccx q[5], q[7], q[15];
ccx q[4], q[6], q[14];
ccx q[0], q[1], q[12];
ccx q[2], q[3], q[13];
cx q[13], q[21];
cx q[12], q[20];
ccx q[2], q[3], q[13];
ccx q[0], q[1], q[12];

// Stage 8: Terminal interference on data & refocused spectators (0 dead qubits, 0 self-canceling pairs)
h q[16];
h q[17];
h q[18];
h q[19];
c_out[0] = measure q[0];
c_out[1] = measure q[1];
c_out[2] = measure q[2];
c_out[3] = measure q[3];
c_out[4] = measure q[4];
c_out[5] = measure q[5];
c_out[6] = measure q[6];
c_out[7] = measure q[7];
c_out[8] = measure q[16];
c_out[9] = measure q[17];
c_out[10] = measure q[18];
c_out[11] = measure q[19];
