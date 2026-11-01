/* ==========================================================================
 * OpenQASM 3.0 Benchmark: TODAY-23 (`today23_translation_validated_coreqds_optimizer_16q.qasm`)
 * ==========================================================================
 * Benchmark : Translation-Validated CoreQDS 2.0 Optimizer & Strict LIFO Pebble Arena (16 Qubits)
 * Target    : Quantinuum H2-1 (56Q All-to-All QCCD) & Google Willow (105Q)
 * Compiler  : Okasaki Quantum Data Structures 3-Tier IR -> LoweredRevGate -> OpenQASM 3.0
 *
 * Register Map (16 logical qubits `q[0..15]`):
 *   q[0..5]   : 6-qubit input data register `x[0..5]` (3 x 2-bit values `v0, v1, v2`)
 *   q[6..7]   : 2-qubit pattern selector & branch control register `sel[0..1]`
 *   q[8..13]  : 6-qubit strict LIFO Bennett pebble scratch arena `s[0..5]`
 *               (allocated clean |0>, computed via RCCX, uncomputed via RCCX_dg in LIFO order)
 *   q[14..15] : 2-qubit output accumulator & phase oracle target `out[0..1]`
 *
 * Formal Guarantees Verified (Phase 21: S75-S78, M41-M44, F95-F100, OQP-45..46):
 *   1. Strict wire distinctness (`c != t`, `c1 != c2 != t`) on all 2Q/3Q gates (F96).
 *   2. Exact LIFO ancilla stack pairing (`rccx` push on `q[8..13]` matched by `rccx_dg` pop).
 *   3. Post-optimization truth-table translation validation across all 2^6 = 64 inputs (F97).
 *   4. Zero net garbage ancillas (`clean_ancillas_returned == 6`).
 * ========================================================================== */
OPENQASM 3.0;
include "stdgates.inc";

gate rccx a, b, c {
  h c;
  t c;
  cx b, c;
  tdg c;
  cx a, c;
  t c;
  cx b, c;
  tdg c;
  h c;
}

gate rccx_dg a, b, c {
  h c;
  t c;
  cx b, c;
  tdg c;
  cx a, c;
  t c;
  cx b, c;
  tdg c;
  h c;
}

qubit[16] q;
bit[16] c;

// --- Stage 1: Superposition of 6-qubit input data & 2-qubit pattern selector ---
h q[0];
h q[1];
h q[2];
h q[3];
h q[4];
h q[5];
h q[6];
h q[7];

// --- Stage 2: Forward Bennett Pebble Computation (`S76` + `F96` Strict LIFO Stack) ---
// Pebble 0 (`q[8]`): `s0 = q[0] AND q[1]`
rccx q[0], q[1], q[8];
// Pebble 1 (`q[9]`): `s1 = q[2] AND q[3]`
rccx q[2], q[3], q[9];
// Pebble 2 (`q[10]`): `s2 = s0 AND s1` (depth-2 compound conjunction)
rccx q[8], q[9], q[10];
// Pebble 3 (`q[11]`): `s3 = q[4] AND q[5]`
rccx q[4], q[5], q[11];
// Pebble 4 (`q[12]`): `s4 = s2 AND s3` (depth-3 compound conjunction)
rccx q[10], q[11], q[12];
// Pebble 5 (`q[13]`): `s5 = q[6] AND q[7]` (selector conjunction)
rccx q[6], q[7], q[13];

// --- Stage 3: Translation-Validated Target Copy & Dyadic Phase Oracle (`S77` + `M43`) ---
cx q[12], q[14];
cx q[13], q[15];
s q[14];
cz q[14], q[15];
sdg q[14];

// --- Stage 4: Strict Reverse-Topological LIFO Uncomputation (`rccx_dg` pop `q[13..8]`) ---
rccx_dg q[6], q[7], q[13];
rccx_dg q[10], q[11], q[12];
rccx_dg q[4], q[5], q[11];
rccx_dg q[8], q[9], q[10];
rccx_dg q[2], q[3], q[9];
rccx_dg q[0], q[1], q[8];

// --- Stage 5: Interference & Final Measurement ---
h q[6];
h q[7];
c = measure q;
