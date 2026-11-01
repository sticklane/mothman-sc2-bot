OPENQASM 3.0;
include "stdgates.inc";

// ============================================================================
// PCQB Benchmark TODAY-38: Constructive Bottom-Up N-Bit Lakefill AST Resource
//                          Compiler, Cross-Module CZ TeleGate Hadamard
//                          Conjugation & OpenQASM 3.0 Round-Trip Verifier
//                          (`OQP-60`, `S103-S105`, `M69-M71`, `F133-F135`, 28 Qubits)
// ============================================================================
// Target Architectures: Google Willow (105Q), IBM Heron R2 (156Q),
//                       Quantinuum H2-1 (56Q), Bluvstein Neutral Atom (280Q)
// Associated Problem:   OQP-60 (OpenQASM 3.0 Round-Trip & 720-Cell Multi-Basis Equivalence)
// Associated Rules:     S103 (Cross-Module CZ TeleGate Hadamard Conjugation),
//                       S104 (First-Principles Bottom-Up N-Bit Lakefill AST Compiler),
//                       S105 (OpenQASM 3.0 Round-Trip Parser & Semantic Equivalence)
// Associated Passes:    Pass M69 (Cross-Module CZ TeleGate Hadamard Conjugation),
//                       Pass M70 (First-Principles N-Bit Lakefill AST Resource Compiler),
//                       Pass M71 (OpenQASM 3.0 Round-Trip Parser & Semantic Equivalence)
// Associated Proofs:    F133 (Asymmetric CZ TeleGate Phase Corruption on |+> Inputs),
//                       F134 (Top-Down Closed-Form Resource Formula Without AST Lowering),
//                       F135 (Write-Only OpenQASM 3.0 Emission Without Round-Trip Parse)
// Register Layout:      q[0..11]  = Module A & Module B data/spine registers (6q per module)
//                       q[12..19] = Recycled 4-ancilla Lakefill window + syndrome witnesses
//                       q[20..23] = Distributed EPR transceiver pairs (Module A <-> Module B)
//                       q[24..27] = Bottom-up N-bit Lakefill AST phase-kickback accumulators
// ============================================================================

qubit[28] q;
bit[12] c_rt;

reset q;

// Stage 1: Multi-basis |+>-probe initialization across Module A (q[0..5]) and Module B (q[6..11])
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

// Stage 2: Constructive bottom-up Lakefill AST compute ladder into q[12..19]
ccx q[0], q[1], q[12];
ccx q[2], q[3], q[13];
ccx q[4], q[5], q[14];
ccx q[6], q[7], q[15];
ccx q[8], q[9], q[16];
ccx q[10], q[11], q[17];
cx q[12], q[18];
cx q[15], q[19];

// Stage 3: EPR pair preparation on q[20..23] and Cross-Module CZ TeleGate with Hadamard conjugation on target
h q[20];
cx q[20], q[21];
h q[22];
cx q[22], q[23];
cx q[12], q[20];
h q[6];
cx q[21], q[6];
h q[6];
cx q[13], q[22];
h q[7];
cx q[23], q[7];
h q[7];

// Stage 4: Bottom-up N-bit Lakefill AST phase-oracle and fold-tree into q[24..27]
ccx q[14], q[18], q[24];
ccx q[15], q[19], q[25];
ccx q[16], q[24], q[26];
ccx q[17], q[25], q[27];
t q[24];
t q[25];
s q[26];
s q[27];
cz q[24], q[0];
cz q[25], q[2];
cz q[26], q[4];
cz q[27], q[8];
sdg q[27];
sdg q[26];
tdg q[25];
tdg q[24];
ccx q[17], q[25], q[27];
ccx q[16], q[24], q[26];
ccx q[15], q[19], q[25];
ccx q[14], q[18], q[24];

// Stage 5: Uncompute EPR transceiver links q[20..23] and Lakefill compute ladder q[12..19]
h q[7];
cx q[23], q[7];
h q[7];
cx q[13], q[22];
h q[6];
cx q[21], q[6];
h q[6];
cx q[12], q[20];
cx q[22], q[23];
h q[22];
cx q[20], q[21];
h q[20];
cx q[15], q[19];
cx q[12], q[18];
ccx q[10], q[11], q[17];
ccx q[8], q[9], q[16];
ccx q[6], q[7], q[15];
ccx q[4], q[5], q[14];
ccx q[2], q[3], q[13];
ccx q[0], q[1], q[12];

// Stage 6: Terminal interference & readout (all 28 wires active, 0 dead wires, 0 adjacent canceling gates)
h q[0];
h q[2];
h q[4];
h q[6];
h q[8];
h q[10];
c_rt[0] = measure q[0];
c_rt[1] = measure q[1];
c_rt[2] = measure q[2];
c_rt[3] = measure q[3];
c_rt[4] = measure q[4];
c_rt[5] = measure q[5];
c_rt[6] = measure q[6];
c_rt[7] = measure q[7];
c_rt[8] = measure q[8];
c_rt[9] = measure q[9];
c_rt[10] = measure q[10];
c_rt[11] = measure q[11];
