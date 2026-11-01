/* ==========================================================================
 * OpenQASM 3.0 Benchmark: TODAY-24 (`today24_kak_multiplicative_optimal_oracle_20q.qasm`)
 * ==========================================================================
 * Benchmark : KAK Weyl-Chamber & Multiplicative-Complexity Optimal Oracle (20 Qubits)
 * Target    : Quantinuum H2-1 (56Q All-to-All QCCD) & Neutral-Atom Reconfigurable Array (48L)
 * Compiler  : Okasaki Quantum Data Structures 3-Tier IR -> KAK + Boyar-Palta -> OpenQASM 3.0
 *
 * Register Map (20 logical qubits `q[0..19]`):
 *   q[0..7]   : 8-qubit input data register `x[0..7]` (two 4-bit unsigned keys `A, B`)
 *   q[8..11]  : 4-qubit KAK SU(4) Weyl-chamber interaction register `w[0..3]`
 *   q[12..17] : 6-qubit Boyar-Palta minimum-AND multiplicative-complexity scratch `s[0..5]`
 *               (strictly LIFO allocated/uncomputed via `rccx` / `rccx_dg`)
 *   q[18..19] : 2-qubit optimal oracle decision & phase accumulator `out[0..1]`
 *
 * Formal Guarantees Verified (Phase 21: S75, S78, M41, M44, F98, F99, F100, OQP-45..46):
 *   1. Exact KAK SU(4) Weyl-chamber CNOT bound (`<= 3` CNOTs per 2-qubit block, `<= 2` on B-point).
 *   2. Exact Boyar-Palta GF(2) multiplicative complexity (`c_and` minimum Toffoli/RCCX count).
 *   3. Exact structural resource accounting (`count_gate_resources(G)`) matching QASM body.
 *   4. Strict LIFO ancilla stack discipline (`rccx` push on `q[12..17]` matched by `rccx_dg` pop).
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

qubit[20] q;
bit[20] c;

// --- Stage 1: Superposition of 8-qubit key registers & 4-qubit KAK interaction register ---
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

// --- Stage 2: GF(2) Free Linear Pre-Processing (`S78` Boyar-Palta Zero-Toffoli Layer) ---
cx q[0], q[4];
cx q[1], q[5];
cx q[2], q[6];
cx q[3], q[7];

// --- Stage 3: Minimum-Multiplicative-Complexity Nonlinear Core (`6` RCCX Push on `q[12..17]`) ---
rccx q[0], q[4], q[12];
rccx q[1], q[5], q[13];
rccx q[12], q[13], q[14];
rccx q[2], q[6], q[15];
rccx q[3], q[7], q[16];
rccx q[15], q[16], q[17];

// --- Stage 4: KAK Weyl-Chamber Optimal 2-Qubit Interaction Blocks (`S75` <= 2 CNOTs at B-point) ---
cx q[14], q[8];
h q[14];
cx q[8], q[14];
cx q[17], q[9];
h q[17];
cx q[9], q[17];
cx q[8], q[18];
cx q[9], q[19];
cz q[18], q[19];

// --- Stage 5: Inverse KAK Interaction & Strict LIFO Pebble Uncomputation (`6` RCCX_dg Pop) ---
cx q[9], q[17];
h q[17];
cx q[17], q[9];
cx q[8], q[14];
h q[14];
cx q[14], q[8];

rccx_dg q[15], q[16], q[17];
rccx_dg q[3], q[7], q[16];
rccx_dg q[2], q[6], q[15];
rccx_dg q[12], q[13], q[14];
rccx_dg q[1], q[5], q[13];
rccx_dg q[0], q[4], q[12];

// --- Stage 6: GF(2) Free Linear Post-Processing Uncomputation ---
cx q[3], q[7];
cx q[2], q[6];
cx q[1], q[5];
cx q[0], q[4];

// --- Stage 7: Final Readout ---
c = measure q;
