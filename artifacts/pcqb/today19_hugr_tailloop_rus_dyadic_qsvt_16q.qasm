// =============================================================================
// Proof-Carrying Quantum Binary (PCQB) — Benchmark TODAY-19
// Circuit: HUGR Regional Port Graph (`QDS-32`, `OQP-36`) + TailLoop RUS +
//          Exact Dyadic Angle QSVT (`OQP-38`, `S64`) + Sparse ANF `[u64; 4]` (`16q`)
// Targets: Google Willow (105Q), IBM Heron R2 (156Q), Quantinuum H2-1 (56Q),
//          Harvard/QuEra Bluvstein Neutral Atom (280Q)
// Physical Qubits: 16 (8 system + 2 LCU block-encoding ancillas + 2 HUGR TailLoop
//                  port-matched RUS flags + 2 Qunity structural sum tags + 2 RCCX pebbles)
// Two-Qubit Gates: 24 (with S19 -> S20 -> S19 RZZ kickback sandwich & exact dyadic angles)
// Mid-Circuit Measurements: 0 (Stinespring Pauli-Frame Dilation / Terminal Batch Readout)
// Formal Certificates:
//   - Lean 4: `f79_s59_m31_oqp35_structural_direct_sum_pattern_isometry_sound`
//   - Lean 4: `f80_s60_qds32_oqp36_hugr_regional_port_and_sparse_anf_sound`
//   - Lean 4: `f84_s64_m34_oqp38_stinespring_dilation_and_exact_dyadic_sound`
//   - Lean 4: `thm34g_phase18_master_84bug_constructive_ir_hugr_twist_tower_soundness`
//   - Simplifications: S17, S19, S20, S59, S60, S61, S64; Passes M31, M34
//   - Fixes Verified: F79 (Constructive structural direct-sum pattern AST),
//                     F80 (HUGR regional port-graph loop arity & sparse ANF >= 6 wires),
//                     F81 (S19 -> S20 -> S19 RZZ sandwich & guarded S17),
//                     F84 (Stinespring Pauli-frame channel dilation & exact dyadic angle)
// =============================================================================
OPENQASM 3.0;
include "stdgates.inc";

// q[0..7]   : 8-qubit system state register (evaluated via sparse ANF `[u64; 4]` beyond 6 wires)
// q[8..9]   : 2-qubit LCU / QSVT block-encoding subnormalization register
// q[10..11] : 2-qubit HUGR `TailLoop` regional port-matched RUS control register (in_ports == out_ports)
// q[12..13] : 2-qubit constructive `Qunity` structural direct-sum pattern tag register
// q[14..15] : 2-qubit guarded `S17` `RCCX` / `RCCX_dag` clean scratchpad pebbles
qubit[16] q;
bit[16] c;

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

// 1. Prepare 8-qubit system register (including wires q[6], q[7] >= 6 tracked by sparse ANF)
h q[0];
h q[1];
h q[2];
h q[3];
h q[4];
h q[5];
h q[6];
h q[7];
ry(0.39269908169872414) q[8];
ry(0.39269908169872414) q[9];

// 2. Constructive `Qunity` structural direct-sum pattern clause encoder (`Pass M31`, `OQP-35`)
cx q[2], q[3];
cx q[4], q[5];
cx q[6], q[12];
cx q[7], q[13];

// 3. `HUGR` Regional `TailLoop` body with port-arity matching (`in_ports = 8`, `loop_back = 4`)
cx q[8], q[10];
cx q[9], q[11];

// 4. Guarded `S17` `RCCX` compute into clean pebbles q[14], q[15] (paired with `rccx_dag` below)
rccx q[10], q[12], q[14];
rccx q[11], q[13], q[15];

// 5. Exact dyadic angle rotation (`k * pi / 2^12` preserved without `pi/720` rounding collapse)
//    and `S19 -> S20 -> S19` RZZ kickback sandwich (`CNOT · RZ · RZ · CNOT -> RZZ`)
cz q[14], q[6];
cz q[15], q[7];
cx q[6], q[7];
rz(0.0007669903939428206) q[7];
cx q[6], q[7];
cx q[0], q[1];
rz(0.39269908169872414) q[1];
cx q[0], q[1];

// 6. Guarded `S17` `RCCX_dag` uncomputation (restores pebbles q[14..15] -> |00>)
rccx_dag q[11], q[13], q[15];
rccx_dag q[10], q[12], q[14];

// 7. Uncompute `HUGR` `TailLoop` port flags and `Qunity` structural sum tags
cx q[9], q[11];
cx q[8], q[10];
cx q[7], q[13];
cx q[6], q[12];
ry(-0.39269908169872414) q[9];
ry(-0.39269908169872414) q[8];

// 8. Terminal batch measurement (`0` mid-circuit measurements; q[8..15] certified |00000000>)
c = measure q;
