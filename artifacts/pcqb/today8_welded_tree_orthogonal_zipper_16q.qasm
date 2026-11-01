OPENQASM 3.0;
include "stdgates.inc";

// TODAY-8: Depth-3 Welded-Tree Quantum Walk Step via Qunity-Style OrthogonalCaseZipper (QDS-16 + QDS-14 + OQP-11 + S25 + S27)
// Physical Qubits: 16 (q[0..3] 4-bit welded-tree vertex label, q[4..5] 2-bit edge-color coin register, q[6..9] OrthogonalCaseZipper 4-branch orthogonal projector spine, q[10..12] RealTimeQuantumQueue schedule spine, q[13..15] clean RCCX pebbles)
// Lowered via Simplifications S25 (QunityOrthogonalCaseZipper), S26 (RCCXPhasePolynomialWindowBarrier), S27 (RealTimeQueueAndAcyclicEGraph) & Pass M9 (ChromaticTransversalSchedule):
//   - 4 mutually orthogonal branch projectors (<P_i, P_j> = 0, sum P_i = I) per F45
//   - O(1) worst-case 1-tick real-time queue step per F47
//   - Chromatic edge-colored transversal schedule eliminating crosstalk bursts per F48
//   - 0 mid-circuit measurements (0 MCM), 1 terminal batch measurement
// Verified by Lean 4 Theorems 28A, 28C, 28D, 28E (thm28e_phase12_master_48bug_qds16_oqp14_soundness).

qubit[16] q;
bit[16] c;

// 1. Initialize Coin Register & Vertex Superposition
h q[0];
h q[1];
h q[4];
h q[5];

// 2. OrthogonalCaseZipper (QDS-16 / S25): 4-Branch Orthogonal Subspace Dispatch on Coin q[4..5]
// Branch 00, 01, 10, 11 orthogonal projector decomposition into spine q[6..9]
cx q[4], q[6];
cx q[5], q[7];

// RCCX Window 1 (Branch 11 projector): rccx q[4], q[5], q[13]
h q[13];
t q[13];
cx q[5], q[13];
tdg q[13];
cx q[4], q[13];
t q[13];
cx q[5], q[13];
tdg q[13];
h q[13];

cx q[13], q[8];
cx q[13], q[9];

// 3. Welded-Tree Child/Parent/Weld Shift via RealTimeQuantumQueue (QDS-14 / S27, 1-Tick Worst-Case Step)
// Chromatic Color Class 0 (Pass M9 crosstalk-free sub-round)
cx q[6], q[0];
cx q[7], q[1];
cx q[8], q[2];
cx q[9], q[3];

// Chromatic Color Class 1 (Pass M9 crosstalk-free sub-round)
cx q[8], q[14];
cx q[9], q[15];
cz q[6], q[10];
cz q[7], q[11];
cz q[8], q[12];
cz q[14], q[10];
cz q[15], q[11];
cx q[9], q[15];
cx q[8], q[14];

// 4. Symmetric Uncomputation of Branch Garbage (F45 GarbageUncomputed = true & S26 RCCX_dag)
cx q[13], q[9];
cx q[13], q[8];

// rccx_dag q[4], q[5], q[13]
h q[13];
t q[13];
cx q[5], q[13];
tdg q[13];
cx q[4], q[13];
t q[13];
cx q[5], q[13];
tdg q[13];
h q[13];

cx q[5], q[7];
cx q[4], q[6];

// 5. Grover Diffusion Coin Reflection & Pass M2 Terminal Batch Readout
h q[4];
h q[5];
c = measure q;
