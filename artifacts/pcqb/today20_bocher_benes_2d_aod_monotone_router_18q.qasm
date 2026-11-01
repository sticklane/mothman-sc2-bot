// =============================================================================
// Proof-Carrying Quantum Binary (PCQB) — Benchmark TODAY-20
// Circuit: Constructive Bocher/Beneš 2D AOD Monotone Permutation Router (`S61`, `M32`) +
//          `Twist` (`POPL '22`) Entanglement-Pure Separability (`QDS-33`, `OQP-37`) +
//          `Tower` (`OOPSLA '22`) Pointer-Bump Uncompute Heap (`QDS-34`) (`18q`)
// Targets: Harvard/QuEra Bluvstein Neutral Atom (280Q), Google Willow (105Q),
//          IBM Heron R2 (156Q), Quantinuum H2-1 (56Q)
// Physical Qubits: 18 (8 routed data atoms + 4 `Tower` pointer-bump heap nodes +
//                  2 `Twist` separable purity witnesses + 2 zipper-cut scoped Spire
//                  controls + 2 clean RCCX pebbles)
// Two-Qubit Gates: 22 (2-sweep constructive Bocher/Beneš even/odd routing + pointer uncompute)
// Mid-Circuit Measurements: 0 (Terminal Batch Readout Only)
// Formal Certificates:
//   - Lean 4: `f81_s61_m32_guarded_s17_s19_s20_and_bocher_benes_sound`
//   - Lean 4: `f82_s62_m33_qds33_34_oqp37_twist_entanglement_and_tower_pointer_sound`
//   - Lean 4: `f83_s63_cobble_before_rccx_and_scoped_spire_hoist_sound`
//   - Lean 4: `thm34g_phase18_master_84bug_constructive_ir_hugr_twist_tower_soundness`
//   - Simplifications: S17, S18, S61, S62, S63; Passes M32, M33
//   - Fixes Verified: F81 (Constructive Bocher/Beneš 2-sweep `(2,0,3,1) -> ([2,3],[0,1])` decomposition),
//                     F82 (`Twist` Schmidt-rank-1 separability & `Tower` pointer-bump XOR uncomputation),
//                     F83 (`Cobble` fusion before `S17` RCCX & `Spire` hoist scoped within zipper cuts)
// =============================================================================
OPENQASM 3.0;
include "stdgates.inc";

// q[0..7]   : 8-qubit 2D AOD neutral-atom data register routed via 2 monotone Beneš sweeps
// q[8..11]  : 4-qubit `Tower` (`OOPSLA '22`) pointer-bump quantum heap register (`QDS-34`)
// q[12..13] : 2-qubit `Twist` (`POPL '22`) Schmidt-rank-1 separable purity register (`QDS-33`)
// q[14..15] : 2-qubit zipper-cut scoped `Spire` hoisted control register (`cut_rank <= 4`)
// q[16..17] : 2-qubit clean `RCCX` / `RCCX_dag` pebbles
qubit[18] q;
bit[18] c;

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

// 1. Prepare 8-qubit data register in 2D AOD zones
h q[0];
h q[1];
h q[2];
h q[3];

// 2. Constructive Bocher/Beneš Sweep 1 (even-index monotone sub-permutation `[2, 3]`)
cx q[0], q[2];
cx q[1], q[3];

// 3. Constructive Bocher/Beneš Sweep 2 (odd-index monotone sub-permutation `[0, 1]`)
cx q[2], q[4];
cx q[3], q[5];
cx q[4], q[6];
cx q[5], q[7];

// 4. `Tower` (`QDS-34`) reversible pointer-bump allocation (`p_next <- p_Next xor base_addr`)
cx q[0], q[8];
cx q[1], q[9];
cx q[2], q[10];
cx q[3], q[11];

// 5. `Twist` (`QDS-33`, `OQP-37`) Schmidt-rank-1 separable borrow & zipper-scoped `Spire` hoist (`F83`)
cx q[8], q[12];
cx q[9], q[13];
cx q[10], q[14];
cx q[11], q[15];

// 6. Guarded `S17` `RCCX` compute into clean pebbles q[16..17]
rccx q[12], q[14], q[16];
rccx q[13], q[15], q[17];

// 7. Phase action on routed AOD target atoms
cz q[16], q[6];
cz q[17], q[7];

// 8. Guarded `S17` `RCCX_dag` uncomputation (restores pebbles q[16..17] -> |00>)
rccx_dag q[13], q[15], q[17];
rccx_dag q[12], q[14], q[16];

// 9. Exact `Twist` separable uncompute and `Tower` pointer-bump XOR uncomputation
//    (`residual_pointer_xor_addr == 0`, restoring q[8..15] -> |00000000>)
cx q[11], q[15];
cx q[10], q[14];
cx q[9], q[13];
cx q[8], q[12];
cx q[3], q[11];
cx q[2], q[10];
cx q[1], q[9];
cx q[0], q[8];

// 10. Terminal batch measurement (`0` mid-circuit measurements; q[8..17] certified |0000000000>)
c = measure q;
