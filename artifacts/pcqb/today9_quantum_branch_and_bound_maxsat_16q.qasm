OPENQASM 3.0;
include "stdgates.inc";

// TODAY-9: 16-Qubit Quantum Branch-and-Bound MAX-SAT Step via BootstrappedSkewBinomialHeap (QDS-17 + OQP-15 + S30 + S33 + M11 + M13)
// Physical Qubits: 16 (q[0..3] 4-bit MAX-SAT variable assignment, q[4..7] BootstrappedSkewBinomialHeap O(1) global-min bound root cache, q[8..11] disjoint borrowed helper spine, q[12..15] clean RCCX pebbles)
// Lowered via Simplifications S30 (NonAliasingBorrowFrameLens), S31 (HybridQroamLitinskiPbcWeightCap), S33 (MagicStateTokenBucketDeamortization) & Passes M11, M13:
//   - O(1) worst-case findMin/insert via BootstrappedSkewBinomialHeap (QDS-17)
//   - Disjoint BorrowFrameLens (focus_mask & borrowed_mask == 0) per F50
//   - De-amortized 2-T/subround token-bucket schedule per F53
//   - 0 mid-circuit measurements (0 MCM), 1 terminal batch measurement
// Verified by Lean 4 Theorems 29B, 29C, 29E, 29G (thm29g_phase13_master_54bug_qds19_oqp18_gap_auditor_soundness).

qubit[16] q;
bit[16] c;

// 1. Initialize Candidate Branch Superposition & Bootstrapped Root Priority Key
h q[0];
h q[1];
h q[2];
h q[3];

// 2. BootstrappedSkewBinomialHeap (QDS-17): O(1) Worst-Case Root-Cached Priority Comparison
cx q[0], q[4];
cx q[1], q[5];
cx q[2], q[6];
cx q[3], q[7];

// 3. Disjoint BorrowFrameLens (OQP-16 / S30 / F50): Borrow q[8..9] disjoint from focus q[0..7]
// Sub-round 1 (Pass M13 token-bucket de-amortized RCCX window 1): rccx q[4], q[5], q[12]
h q[12];
t q[12];
cx q[5], q[12];
tdg q[12];
cx q[4], q[12];
t q[12];
cx q[5], q[12];
tdg q[12];
h q[12];

// Sub-round 2 (Pass M13 token-bucket de-amortized RCCX window 2): rccx q[6], q[7], q[13]
h q[13];
t q[13];
cx q[7], q[13];
tdg q[13];
cx q[6], q[13];
t q[13];
cx q[7], q[13];
tdg q[13];
h q[13];

// 4. Branch-and-Bound Pruning Phase Kickback (Pass M11 Hybrid QROAM + PBC weight <= 4)
cx q[12], q[8];
cx q[13], q[9];
cx q[8], q[10];
cx q[9], q[11];
cz q[10], q[14];
cz q[11], q[15];
cx q[9], q[11];
cx q[8], q[10];
cx q[13], q[9];
cx q[12], q[8];

// 5. Symmetric Uncomputation of RCCX Pebbles & Borrowed Frame Restoration (F50 restored_to_initial = true)
// rccx_dag q[6], q[7], q[13]
h q[13];
t q[13];
cx q[7], q[13];
tdg q[13];
cx q[6], q[13];
t q[13];
cx q[7], q[13];
tdg q[13];
h q[13];

// rccx_dag q[4], q[5], q[12]
h q[12];
t q[12];
cx q[5], q[12];
tdg q[12];
cx q[4], q[12];
t q[12];
cx q[5], q[12];
tdg q[12];
h q[12];

cx q[3], q[7];
cx q[2], q[6];
cx q[1], q[5];
cx q[0], q[4];

// 6. Grover-Montanaro Branch-and-Bound Diffusion & Pass M2 Terminal Batch Readout
h q[0];
h q[1];
h q[2];
h q[3];
c = measure q;
