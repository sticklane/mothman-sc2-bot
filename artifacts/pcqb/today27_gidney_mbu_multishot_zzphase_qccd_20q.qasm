OPENQASM 3.0;
include "stdgates.inc";
// =============================================================================
// PCQB Artifact TODAY-27: Gidney Measurement-Based Uncomputation (MBU) +
// Native Trapped-Ion QCCD RZZ(theta) Phase-Kickback Circuit (`OQP-49`, `QDS-39`,
// `S83-S85`, `M49-M51`, `F108-F110`) on 20 Qubits
// =============================================================================
// Architecture : Quantinuum H2-1 / Helios Trapped-Ion QCCD (4 Zones, All-to-All)
// Native ISA   : rzz(theta), rz(theta), h, cx, cz, mid-circuit measure + reset
// Key Property : Every temporary AND-elbow ancilla q[16..19] is uncomputed via
//                Gidney X-basis measurement + conditional CZ phase fixup + reset
//                (0 uncomputation T-gates; 50% T-gate reduction: 4T vs 8T per elbow)
// =============================================================================
qubit[20] q;
bit[4] mbu_syn;
bit[8] c_out;

gate rzz(theta) a, b {
  cx a, b;
  rz(theta) b;
  cx a, b;
}

reset q;

// 1. Initialize 8 data & query wires q[0..7] into uniform superposition
h q[0];
h q[1];
h q[2];
h q[3];
h q[4];
h q[5];
h q[6];
h q[7];

// 2. Forward compute 4 relative-phase Toffoli (RCCX) AND-elbows into q[16..19] (4T each)
h q[16];
t q[16];
cx q[0], q[16];
tdg q[16];
cx q[1], q[16];
t q[16];
cx q[0], q[16];
tdg q[16];
h q[16];

h q[17];
t q[17];
cx q[2], q[17];
tdg q[17];
cx q[3], q[17];
t q[17];
cx q[2], q[17];
tdg q[17];
h q[17];

h q[18];
t q[18];
cx q[4], q[18];
tdg q[18];
cx q[5], q[18];
t q[18];
cx q[4], q[18];
tdg q[18];
h q[18];

h q[19];
t q[19];
cx q[6], q[19];
tdg q[19];
cx q[7], q[19];
t q[19];
cx q[6], q[19];
tdg q[19];
h q[19];

// 3. Native Trapped-Ion QCCD RZZ(theta) two-qubit phase-polynomial interactions (Pass M51 / S85)
rzz(0.7853981633974483) q[16], q[8];
rzz(0.7853981633974483) q[17], q[9];
rzz(0.7853981633974483) q[18], q[10];
rzz(0.7853981633974483) q[19], q[11];
cx q[8], q[12];
cx q[9], q[13];
cx q[10], q[14];
cx q[11], q[15];

// 4. Gidney Measurement-Based Uncomputation (MBU) on q[16..19] (Pass M49 / S83: 0 T-gates!)
h q[16];
h q[17];
h q[18];
h q[19];
mbu_syn[0] = measure q[16];
mbu_syn[1] = measure q[17];
mbu_syn[2] = measure q[18];
mbu_syn[3] = measure q[19];
if (mbu_syn[0] == true) { cz q[0], q[1]; }
if (mbu_syn[1] == true) { cz q[2], q[3]; }
if (mbu_syn[2] == true) { cz q[4], q[5]; }
if (mbu_syn[3] == true) { cz q[6], q[7]; }
reset q[16];
reset q[17];
reset q[18];
reset q[19];

// 5. Terminal readout of output spine registers q[8..15]
c_out[0] = measure q[8];
c_out[1] = measure q[9];
c_out[2] = measure q[10];
c_out[3] = measure q[11];
c_out[4] = measure q[12];
c_out[5] = measure q[13];
c_out[6] = measure q[14];
c_out[7] = measure q[15];
