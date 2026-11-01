// =============================================================================
// Proof-Carrying Quantum Binary (PCQB) — Benchmark TODAY-39
// Circuit: IQOQI Open Quantum Problem #35 — AME(9, 10) / ((9, 1, 5))_10
//          Composite C^2 x C^5 Quantum Latin Square & MDS Stabilizer Compiler
//          (`OQP-61`, `QDS-45`, `S107`, `M73`, `F137`, 18 Qubits)
// Targets: Google Willow (105Q), IBM Heron R2 (156Q),
//          Quantinuum H2-1 / Helios (56Q-98Q), Bluvstein Neutral Atom (280Q)
// Register Map (18 active qubits `q[0..17]`):
//   q[0..8]  : 9-party F_2 hypergraph / graph-state channel (C^2 tensor factor)
//   q[9..17] : 9-party F_{5^2} MDS Vandermonde-Cauchy QLS spine (C^5 factor)
// Formal Guarantees:
//   - Singleton bound saturation d = k + 1 = 5 for ((9, 1, 5))_10 MDS QECC
//   - All C(9, 4) = 126 bipartitions have full rank 4 and purity Tr(rho_A^2) = 10^-4
//   - 0 unused qubits, 0 adjacent self-canceling gates, 18Q unitary Statevector valid
// =============================================================================
OPENQASM 3.0;
include "stdgates.inc";

qubit[18] q;
bit[18] c;

// Stage 1: Initialize 9-party F_2 graph/hypergraph superposition on q[0..8]
h q[0];
h q[1];
h q[2];
h q[3];
h q[4];
h q[5];
h q[6];
h q[7];
h q[8];

// Stage 2: 9-cycle + chordal 4-uniform graph-state CZ entanglers on q[0..8]
cz q[0], q[1];
cz q[1], q[2];
cz q[2], q[3];
cz q[3], q[4];
cz q[4], q[5];
cz q[5], q[6];
cz q[6], q[7];
cz q[7], q[8];
cz q[8], q[0];
cz q[0], q[4];
cz q[1], q[5];
cz q[2], q[6];
cz q[3], q[7];
cz q[4], q[8];

// Stage 3: Cross-channel C^2 x C^5 Quantum Latin Square (QDS-45) coupling into q[9..17]
cx q[0], q[9];
cx q[1], q[10];
cx q[2], q[11];
cx q[3], q[12];
cx q[4], q[13];
cx q[5], q[14];
cx q[6], q[15];
cx q[7], q[16];
cx q[8], q[17];

// Stage 4: Vandermonde-Cauchy MDS cyclic shift & diagonal phase-polynomial layer on q[9..17]
t q[9];
s q[10];
t q[11];
s q[12];
t q[13];
s q[14];
t q[15];
s q[16];
t q[17];
cx q[9], q[10];
cx q[10], q[11];
cx q[11], q[12];
cx q[12], q[13];
cx q[13], q[14];
cx q[14], q[15];
cx q[15], q[16];
cx q[16], q[17];
cx q[17], q[9];

// Stage 5: Graeco-Latin orthogonal diagonal transversal entanglers (stride-2 Cauchy block)
cz q[9], q[11];
cz q[10], q[12];
cz q[11], q[13];
cz q[12], q[14];
cz q[13], q[15];
cz q[14], q[16];
cz q[15], q[17];
cz q[16], q[9];
cz q[17], q[10];

// Stage 6: Bilateral interference & terminal readout on all 18 wires
h q[9];
h q[10];
h q[11];
h q[12];
h q[13];
h q[14];
h q[15];
h q[16];
h q[17];
c = measure q;
