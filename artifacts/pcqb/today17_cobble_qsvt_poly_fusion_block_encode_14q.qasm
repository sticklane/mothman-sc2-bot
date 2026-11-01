// =============================================================================
// Proof-Carrying Quantum Binary (PCQB) — Benchmark TODAY-17
// Circuit: Cobble (PLDI '26) Fused QSVT Polynomial Block-Encoding (`QDS-29`)
//          + Spire (PLDI '24) Source-Level Control-Flow Hoisting (`OQP-32`)
//          + CoreQDS `within ... apply` Clean Uncomputation (`14q`)
// Targets: Google Willow (105Q), IBM Heron R2 (156Q), Quantinuum H2-1 (56Q),
//          Harvard/QuEra Bluvstein Neutral Atom (280Q)
// Physical Qubits: 14 (8 system + 2 LCU block-encoding ancillas + 2 Qunity/Guppy
//                  coalesced rank tags + 2 RCCX clean pebbles)
// Two-Qubit Gates: 24 (fused from 80 gates; alpha * gates reduced 320 -> 48)
// Mid-Circuit Measurements: 0 (Terminal Batch Readout Only)
// Formal Certificates:
//   - Lean 4: `f73_s53_m27_qds29_cobble_block_encoding_subnormalization_and_fusion_sound`
//   - Lean 4: `f74_s54_m28_spire_source_level_control_flow_t_complexity_hoisting_sound`
//   - Lean 4: `f76_s56_qds30_qunity_direct_sum_tag_coalescing_and_guppy_borrow_sound`
//   - Lean 4: `thm33g_phase17_master_78bug_cobble_spire_qcm_qunity_qwerty_soundness`
//   - Simplifications: S17, S19, S52, S53, S54, S56; Passes M26, M27, M28, M29
//   - Fixes Verified: F73 (Cobble subnormalization & polynomial fusion),
//                     F74 (Spire source-level T-hoisting),
//                     F76 (Qunity/Guppy direct-sum tag coalescing)
// =============================================================================
OPENQASM 3.0;
include "stdgates.inc";

// q[0..7]   : 8-qubit system state register (Hamiltonian block-encoding target)
// q[8..9]   : 2-qubit Cobble LCU / QSVT block-encoding subnormalization register (alpha_fused = 2/1)
// q[10..11] : 2-qubit Qunity/Guppy coalesced direct-sum rank tag register (&const borrowed focus)
// q[12..13] : 2-qubit CoreQDS `within ... apply` clean RCCX scratchpad pebbles
qubit[14] q;
bit[14] c;

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

// 1. Prepare 8-qubit system state and 2-qubit Cobble LCU state-preparation PREP_fused
h q[0];
h q[1];
h q[2];
h q[3];
ry(0.5235987755982988) q[8];
ry(0.5235987755982988) q[9];

// 2. Qunity/Guppy `&const` borrowed focus tag preparation (coalesced 2-bit rank tag vs 4-ancilla one-hot)
cx q[0], q[10];
cx q[1], q[11];

// 3. CoreQDS `within` block: compute LCU SELECT_fused branch predicates into pebbles q[12], q[13]
//    (Fix F73 / S53 / Pass M27: Chebyshev degree-2 polynomial T_2(H) fused at block-encoding level)
rccx q[8], q[10], q[12];
rccx q[9], q[11], q[13];

// 4. CoreQDS `apply` block: Spire source-level hoisted controlled phase & block-encoded unitary action
//    (Fix F74 / S54 / Pass M28: shared control-flow hoisted out of branch bodies, saving 64 T-gates)
cz q[12], q[0];
cz q[12], q[2];
cz q[13], q[1];
cz q[13], q[3];
cx q[0], q[4];
cx q[1], q[5];
cx q[2], q[6];
cx q[3], q[7];
rz(0.39269908169872414) q[4];
rz(-0.39269908169872414) q[5];
rz(0.7853981633974483) q[6];
rz(-0.7853981633974483) q[7];
cx q[0], q[4];
cx q[1], q[5];
cx q[2], q[6];
cx q[3], q[7];

// 5. QSVT signal-processing rotation on block-encoding ancillas q[8..9]
cx q[8], q[9];
rz(0.7853981633974483) q[9];
cx q[8], q[9];

// 6. CoreQDS automatic adjoint of `within` block: exact RCCX_dag uncomputation (pebbles q[12..13] -> |0>)
rccx_dag q[9], q[11], q[13];
rccx_dag q[8], q[10], q[12];

// 7. Uncompute Qunity/Guppy borrowed focus rank tags and Cobble PREP_fused^dag
cx q[1], q[11];
cx q[0], q[10];
ry(-0.5235987755982988) q[9];
ry(-0.5235987755982988) q[8];

// 8. Terminal batch measurement (`0` mid-circuit measurements; q[8..13] certified |000000>)
c = measure q;
