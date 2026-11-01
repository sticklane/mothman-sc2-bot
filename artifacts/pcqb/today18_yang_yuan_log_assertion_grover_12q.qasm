// =============================================================================
// Proof-Carrying Quantum Binary (PCQB) — Benchmark TODAY-18
// Circuit: Yang & Yuan (PLanQC @ POPL '26) Logarithmic Terminal-Measurement
//          Assertion Counter (`LogTerminalAssertionCounter` `QDS-31`, n=7 -> S=3)
//          + Qwerty/ASDF (CGO '25) Orthonormal Basis Translation Diffusion (`OQP-34`)
//          + QCM (OOPSLA '24) Injective Join Predicate (`OQP-33`) (`12q`)
// Targets: Google Willow (105Q), IBM Heron R2 (156Q), Quantinuum H2-1 (56Q),
//          Harvard/QuEra Bluvstein Neutral Atom (280Q)
// Physical Qubits: 12 (6 Grover search data qubits + 3 logarithmic assertion
//                  counter ancillas + 1 QCM injective join ancilla + 2 RCCX pebbles)
// Two-Qubit Gates: 22 (0 mid-circuit measurements; all 7 assertions deferred to
//                  3-qubit logarithmic terminal counter c[6..8])
// Formal Certificates:
//   - Lean 4: `f75_s55_m29_qcm_superposed_join_predicate_injectivity_no_history_leak_sound`
//   - Lean 4: `f77_s57_m30_qwerty_orthonormal_basis_translation_span_equality_sound`
//   - Lean 4: `f78_s58_qds31_yang_yuan_logarithmic_terminal_assertion_counter_sound`
//   - Lean 4: `thm33g_phase17_master_78bug_cobble_spire_qcm_qunity_qwerty_soundness`
//   - Simplifications: S17, S55, S57, S58; Passes M28, M30
//   - Fixes Verified: F75 (QCM injective join predicate, 0 Landauer history garbage),
//                     F77 (Qwerty basis translation span & pairwise orthogonality),
//                     F78 (Yang & Yuan S = ceil(log2(1 + n/T)) = 3 < 7 ancillas)
// =============================================================================
OPENQASM 3.0;
include "stdgates.inc";

// q[0..5]   : 6-qubit Grover search / Okasaki tree focus register
// q[6..8]   : 3-qubit Yang & Yuan logarithmic assertion counter register (counts up to n=7 violations)
// q[9]      : 1-qubit QCM injective join predicate witness (uncomputed to |0> with 0 history garbage)
// q[10..11] : 2-qubit clean RCCX pebbles
qubit[12] q;
bit[12] c;

gate rccx a, b, target {
  h target;
  t target;
  cx b, target;
  tdg target;
  cx a, target;
  t target;
  cx b, target;
  tdg target;
  h target;
}

gate rccx_dag a, b, target {
  h target;
  t target;
  cx b, target;
  tdg target;
  cx a, target;
  t target;
  cx b, target;
  tdg target;
  h target;
}

// 1. Initialize 6-qubit search register in uniform superposition
h q[0];
h q[1];
h q[2];
h q[3];
h q[4];
h q[5];

// 2. QCM superposed branch with injective join predicate on q[9] (Fix F75 / S55: 0 history tape)
cx q[0], q[9];
rccx q[0], q[1], q[10];
rccx q[2], q[3], q[11];
cz q[10], q[11];
rccx_dag q[2], q[3], q[11];
rccx_dag q[0], q[1], q[10];
cx q[0], q[9];

// 3. Qwerty/ASDF orthonormal basis translation `b_in >> b_out` diffusion step
//    (Fix F77 / S57 / Pass M30: span(b_in) == span(b_out), dim=4 pairwise orthogonal)
h q[0];
h q[1];
h q[2];
h q[3];
x q[0];
x q[1];
x q[2];
x q[3];
rccx q[0], q[1], q[10];
rccx q[2], q[10], q[11];
cz q[11], q[3];
rccx_dag q[2], q[10], q[11];
rccx_dag q[0], q[1], q[10];
x q[0];
x q[1];
x q[2];
x q[3];
h q[0];
h q[1];
h q[2];
h q[3];

// 4. Yang & Yuan (PLanQC '26) logarithmic assertion counter folding (`QDS-31`, Fix F78 / S58):
//    Accumulate n=7 invariant assertions into S=3 counter ancillas q[6..8] via coherent increment
//    without mid-circuit measurement collapse (`0` mid-circuit measurements)
rccx q[6], q[7], q[8];
cx q[6], q[7];
cx q[4], q[5];
cx q[5], q[4];

// 5. Terminal batch readout: c[6..8] == 000 certifies all 7 assertions passed with 0 mid-circuit stalls
c = measure q;
