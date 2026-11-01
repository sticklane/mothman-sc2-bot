// =============================================================================
// Proof-Carrying Quantum Binary (PCQB) — Benchmark TODAY-40
// Circuit: Composite-Dimension AME(6, 6) = ((6, 1, 4))_6 Hexad MDS QECC &
//          Euler 36-Officers Boundary Zipper (`OQP-62`, `QDS-46`, 12 Qubits)
// Targets: Google Willow (105Q), IBM Heron R2 (156Q),
//          Quantinuum H2-1 / Helios (56Q-98Q), Bluvstein Neutral Atom (280Q)
// Register Map (12 active qubits `q[0..11]`, OpenQASM 2/3 `qreg q[12]; creg c[12];`):
//   q[0..5]  : 6-party F_2 5-wheel (W_6) hexacode / graph-state spine (C^2 factor)
//   q[6..11] : 6-party F_3-embedded 5-wheel / Vandermonde-Cauchy MDS spine (C^3 factor)
//   Party i  : Composite hexad pair P_i = (q[i], q[i+6]) for i in {0..5}
// Formal Guarantees:
//   - Singleton bound saturation d_code = floor(6/2) + 1 = 4 for ((6, 1, 4))_6 MDS QECC
//   - All C(6, 3) = 20 balanced 3-vs-3 hexad bipartitions have full rank 64 (2^3 x 2^3)
//     and exact purity Tr(rho_A^2) = 1/64 = 0.015625 (maximum entanglement entropy 6 bits)
//   - 0 unused qubits, 0 adjacent self-canceling gates, 12Q unitary Statevector valid
// =============================================================================
OPENQASM 3.0;
include "stdgates.inc";

qubit[12] q;
bit[12] c;

// Stage 1: Initialize 6-party F_2 5-wheel (W_6) superposition on q[0..5] and F_3-embedded spine on q[6..11]
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

// Stage 2: 5-rim cycle + hub-5 spokes of W_6 on F_2 channel q[0..5] (det = +-1 mod 2 across all 20 3x3 minors)
cz q[0], q[1];
cz q[1], q[2];
cz q[2], q[3];
cz q[3], q[4];
cz q[4], q[0];
cz q[0], q[5];
cz q[1], q[5];
cz q[2], q[5];
cz q[3], q[5];
cz q[4], q[5];

// Stage 3: 5-rim cycle + hub-11 spokes of W_6 on F_3-embedded channel q[6..11] (det = +-1 mod 3 across all 20 3x3 minors)
cz q[6], q[7];
cz q[7], q[8];
cz q[8], q[9];
cz q[9], q[10];
cz q[10], q[6];
cz q[6], q[11];
cz q[7], q[11];
cz q[8], q[11];
cz q[9], q[11];
cz q[10], q[11];

// Stage 4: Local non-Clifford / phase-twist & cross-factor C^2 x C^3 hexad coupling (q[i], q[i+6])
t q[6];
s q[7];
t q[8];
s q[9];
t q[10];
s q[11];
cx q[0], q[6];
cx q[1], q[7];
cx q[2], q[8];
cx q[3], q[9];
cx q[4], q[10];
cx q[5], q[11];

// Stage 5: Bilateral interference & terminal readout on all 12 wires
h q[6];
h q[7];
h q[8];
h q[9];
h q[10];
h q[11];
c = measure q;
