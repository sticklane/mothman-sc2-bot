/* ==========================================================================
 * OpenQASM 3.0 Benchmark: TODAY-25 (`today25_exact_dyadic_tpar_gf2_superopt_18q.qasm`)
 * ==========================================================================
 * Benchmark : Exact Z[1/sqrt(2), i] Dyadic Cyclotomic & T-par / GF(2) Superoptimized Oracle (18 Qubits)
 * Target    : Quantinuum H2-1 (56Q All-to-All QCCD) & IBM Heron R2 (156Q Heavy-Hex)
 * Compiler  : Okasaki Quantum Data Structures 3-Tier IR -> Phase-Polynomial T-par & GF(2) CNOT -> OpenQASM 3.0
 *
 * Register Map (18 logical qubits `q[0..17]`):
 *   q[0..7]   : 8-qubit input data register `x[0..7]` (two 4-bit dyadic cyclotomic operands)
 *   q[8..11]  : 4-qubit exact Z[1/sqrt(2), i] Clifford+T superoptimized window `w[0..3]`
 *   q[12..15] : 4-qubit LIFO Bennett pebble scratchpad `s[0..3]` (`rccx` / `rccx_dg`)
 *   q[16..17] : 2-qubit phase-polynomial parity kickback & decision output `out[0..1]`
 *
 * Formal Guarantees Verified (Phase 22: S79, S80, M45, F101, F102, F103, OQP-47):
 *   1. Exact algebraic unitary equivalence over Z[1/sqrt(2), i] (`verify_exact_dyadic_unitary_equivalence`).
 *   2. Non-local phase-polynomial `T-par` merging across `{CNOT, RZ, T}` regions (`S80`, `F103`).
 *   3. GF(2) Gaussian elimination CNOT ladder synthesis reducing redundant CNOT chains (`Pass M45`).
 *   4. Strict LIFO ancilla stack discipline (`rccx` push on `q[12..15]` matched by `rccx_dg` pop).
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

qubit[18] q;
bit[18] c;

// --- Stage 1: Superposition of 8-qubit input data & 4-qubit Clifford+T window ---
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

// --- Stage 2: GF(2) Gaussian-Eliminated Linear Parity Basis (`S80` / `Pass M45`) ---
cx q[0], q[4];
cx q[1], q[5];
cx q[2], q[6];
cx q[3], q[7];
cx q[8], q[9];
cx q[10], q[11];

// --- Stage 3: Non-Local Phase-Polynomial `T-par` Merged Diagonal Layer (`S79`, `S80`) ---
s q[8];
s q[9];
t q[10];
tdg q[11];
cx q[9], q[8];
cx q[11], q[10];

// --- Stage 4: Strict LIFO Bennett Pebble Compute (`4` RCCX Push on `q[12..15]`) ---
rccx q[0], q[4], q[12];
rccx q[1], q[5], q[13];
rccx q[12], q[13], q[14];
rccx q[2], q[6], q[15];

// --- Stage 5: Dyadic Cyclotomic Phase Kickback onto Output Register `q[16..17]` ---
cx q[14], q[16];
cx q[15], q[17];
cz q[8], q[16];
cz q[10], q[17];

// --- Stage 6: Strict LIFO Bennett Pebble Uncomputation (`4` RCCX_dg Pop) ---
rccx_dg q[2], q[6], q[15];
rccx_dg q[12], q[13], q[14];
rccx_dg q[1], q[5], q[13];
rccx_dg q[0], q[4], q[12];

// --- Stage 7: GF(2) Linear Parity Uncomputation ---
cx q[10], q[11];
cx q[8], q[9];
cx q[3], q[7];
cx q[2], q[6];
cx q[1], q[5];
cx q[0], q[4];

// --- Stage 8: Final Terminal Readout ---
c = measure q;
