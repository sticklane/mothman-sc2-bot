OPENQASM 3.0;
include "stdgates.inc";

// ============================================================================
// PCQB Benchmark TODAY-31: Graph-Like ZX Local-Complementation, Pivot Reduction,
//                          gflow Circuit Extraction & Gidney-style Magic-State
//                          Cultivation + Litinski GoSC Volume Scheduling (26 Qubits)
// ============================================================================
// Target Architectures: Google Willow (105Q), IBM Heron R2 (156Q),
//                       Quantinuum H2-1 (56Q), Bluvstein Neutral Atom (280Q)
// Associated Problem:   OQP-53 (ZX LC/Pivot + gflow Extraction + Magic-State Cultivation)
// Associated Rules:     S91 (ZX Local-Complementation, Pivot & gflow Extraction),
//                       S92 (Gidney Magic-State Cultivation & Litinski GoSC Scheduling)
// Associated Passes:    Pass M57 (ZX LC/Pivot & gflow Extractor),
//                       Pass M58 (Magic-State Cultivation & GoSC Volume Scheduler)
// Associated Proofs:    F119 (ZX LC & Pivot Graph-State Soundness),
//                       F120 (Causal gflow DAG & Gaussian Frontier Extraction),
//                       F121 (Magic-State Cultivation 5x Volume Reduction vs 15-to-1)
// Register Layout:      q[0..7]   = Graph-like ZX frontier data & gflow extracted spine
//                       q[8..15]  = Cultivated d=3..5 color-code T-patch magic-state bank
//                       q[16..21] = Litinski Game-of-Surface-Codes (GoSC) fast routing bus
//                       q[22..25] = Mid-circuit cultivation syndrome & post-selection checks
// ============================================================================

qubit[26] q;
bit[4] c_cult;
bit[8] c_gflow;

reset q;

// Stage 1: Prepare graph-like ZX cluster state on q[0..7] (H + CZ adjacency)
h q[0];
h q[1];
h q[2];
h q[3];
h q[4];
h q[5];
h q[6];
h q[7];
cz q[0], q[1];
cz q[1], q[2];
cz q[2], q[3];
cz q[3], q[4];
cz q[4], q[5];
cz q[5], q[6];
cz q[6], q[7];
cz q[0], q[4];
cz q[1], q[5];
cz q[2], q[6];
cz q[3], q[7];

// Stage 2: Local-Complementation (LC) at Clifford spider q[2] (phase pi/2)
// and Pivot reduction along internal edge (q[3], q[4]) (S91, Pass M57, F119)
s q[1];
s q[3];
s q[6];
cz q[1], q[3];
cz q[1], q[6];
cz q[3], q[6];
h q[3];
h q[4];
cz q[2], q[5];
cz q[2], q[7];
cz q[1], q[4];
h q[3];
h q[4];

// Stage 3: Gidney-style Magic-State Cultivation on q[8..15] with syndrome check q[22..25] (S92, Pass M58, F121)
h q[8];
h q[9];
h q[10];
h q[11];
t q[8];
t q[9];
t q[10];
t q[11];
cx q[8], q[12];
cx q[9], q[13];
cx q[10], q[14];
cx q[11], q[15];
cx q[12], q[22];
cx q[13], q[23];
cx q[14], q[24];
cx q[15], q[25];
c_cult[0] = measure q[22];
c_cult[1] = measure q[23];
c_cult[2] = measure q[24];
c_cult[3] = measure q[25];
reset q[22];
reset q[23];
reset q[24];
reset q[25];

// Stage 4: Litinski GoSC fast-block magic-state injection via routing bus q[16..21]
// and causal gflow GF(2) frontier extraction back to unitary circuit (Pass M57, F120)
cx q[8], q[16];
cx q[9], q[17];
cx q[10], q[18];
cx q[11], q[19];
cx q[12], q[20];
cx q[13], q[21];
cx q[16], q[0];
cx q[17], q[1];
cx q[18], q[2];
cx q[19], q[3];
cx q[20], q[4];
cx q[21], q[5];
s q[0];
s q[1];
s q[2];
s q[3];
s q[4];
s q[5];
cx q[21], q[5];
cx q[20], q[4];
cx q[19], q[3];
cx q[18], q[2];
cx q[17], q[1];
cx q[16], q[0];
cx q[13], q[21];
cx q[12], q[20];
cx q[11], q[19];
cx q[10], q[18];
cx q[9], q[17];
cx q[8], q[16];
cx q[11], q[15];
cx q[10], q[14];
cx q[9], q[13];
cx q[8], q[12];

// Stage 5: Terminal gflow extracted output register measurement
c_gflow[0] = measure q[0];
c_gflow[1] = measure q[1];
c_gflow[2] = measure q[2];
c_gflow[3] = measure q[3];
c_gflow[4] = measure q[4];
c_gflow[5] = measure q[5];
c_gflow[6] = measure q[6];
c_gflow[7] = measure q[7];
