OPENQASM 3.0;
include "stdgates.inc";
qubit[19] q;
bit[60] m;
ry(2.372799104599) q[0];
ry(1.309638915892) q[1];
cx q[0], q[1];
ry(-1.309638915892) q[1];
cx q[0], q[1];
cx q[1], q[0];
ry(1.300246563816) q[2];
cx q[1], q[2];
ry(-1.300246563816) q[2];
cx q[1], q[2];
cx q[2], q[1];
ry(1.289761425292) q[3];
cx q[2], q[3];
ry(-1.289761425292) q[3];
cx q[2], q[3];
cx q[3], q[2];
ry(1.277953555066) q[4];
cx q[3], q[4];
ry(-1.277953555066) q[4];
cx q[3], q[4];
cx q[4], q[3];
ry(1.264518957625) q[5];
cx q[4], q[5];
ry(-1.264518957625) q[5];
cx q[4], q[5];
cx q[5], q[4];
ry(1.249045772398) q[6];
cx q[5], q[6];
ry(-1.249045772398) q[6];
cx q[5], q[6];
cx q[6], q[5];
ry(1.230959417341) q[7];
cx q[6], q[7];
ry(-1.230959417341) q[7];
cx q[6], q[7];
cx q[7], q[6];
ry(1.209429202888) q[8];
cx q[7], q[8];
ry(-1.209429202888) q[8];
cx q[7], q[8];
cx q[8], q[7];
ry(1.183199640140) q[9];
cx q[8], q[9];
ry(-1.183199640140) q[9];
cx q[8], q[9];
cx q[9], q[8];
ry(1.150261991511) q[10];
cx q[9], q[10];
ry(-1.150261991511) q[10];
cx q[9], q[10];
cx q[10], q[9];
ry(1.107148717794) q[11];
cx q[10], q[11];
ry(-1.107148717794) q[11];
cx q[10], q[11];
cx q[11], q[10];
ry(1.047197551197) q[12];
cx q[11], q[12];
ry(-1.047197551197) q[12];
cx q[11], q[12];
cx q[12], q[11];
ry(0.955316618125) q[13];
cx q[12], q[13];
ry(-0.955316618125) q[13];
cx q[12], q[13];
cx q[13], q[12];
ry(0.785398163397) q[14];
cx q[13], q[14];
ry(-0.785398163397) q[14];
cx q[13], q[14];
cx q[14], q[13];
z q[0];
z q[2];
z q[4];
z q[6];
z q[8];
z q[10];
z q[12];
z q[14];
cx q[0], q[15];
cx q[1], q[16];
cx q[2], q[15];
cx q[2], q[16];
cx q[3], q[17];
cx q[4], q[15];
cx q[4], q[17];
cx q[5], q[16];
cx q[5], q[17];
cx q[6], q[15];
cx q[6], q[16];
cx q[6], q[17];
cx q[7], q[18];
cx q[8], q[15];
cx q[8], q[18];
cx q[9], q[16];
cx q[9], q[18];
cx q[10], q[15];
cx q[10], q[16];
cx q[10], q[18];
cx q[11], q[17];
cx q[11], q[18];
cx q[12], q[15];
cx q[12], q[17];
cx q[12], q[18];
cx q[13], q[16];
cx q[13], q[17];
cx q[13], q[18];
cx q[14], q[15];
cx q[14], q[16];
cx q[14], q[17];
cx q[14], q[18];
h q[0];
m[0] = measure q[0];
reset q[0];
h q[1];
m[1] = measure q[1];
reset q[1];
h q[2];
m[2] = measure q[2];
reset q[2];
h q[3];
m[3] = measure q[3];
reset q[3];
h q[4];
m[4] = measure q[4];
reset q[4];
h q[5];
m[5] = measure q[5];
reset q[5];
h q[6];
m[6] = measure q[6];
reset q[6];
h q[7];
m[7] = measure q[7];
reset q[7];
h q[8];
m[8] = measure q[8];
reset q[8];
h q[9];
m[9] = measure q[9];
reset q[9];
h q[10];
m[10] = measure q[10];
reset q[10];
h q[11];
m[11] = measure q[11];
reset q[11];
h q[12];
m[12] = measure q[12];
reset q[12];
h q[13];
m[13] = measure q[13];
reset q[13];
h q[14];
m[14] = measure q[14];
reset q[14];
x q[16];
x q[17];
x q[18];
ccx q[15], q[16], q[0];
ccx q[17], q[18], q[1];
ccx q[0], q[1], q[2];
x q[16];
x q[17];
x q[18];
if (m[0] == 1) { z q[2]; }
x q[18];
x q[17];
x q[16];
h q[2];
m[15] = measure q[2];
if (m[15] == 1) { cz q[0], q[1]; }
reset q[2];
h q[1];
m[16] = measure q[1];
if (m[16] == 1) { cz q[17], q[18]; }
reset q[1];
h q[0];
m[17] = measure q[0];
if (m[17] == 1) { cz q[15], q[16]; }
reset q[0];
x q[18];
x q[17];
x q[16];
x q[15];
x q[17];
x q[18];
ccx q[15], q[16], q[0];
ccx q[17], q[18], q[1];
ccx q[0], q[1], q[2];
x q[15];
x q[17];
x q[18];
if (m[1] == 1) { z q[2]; }
x q[18];
x q[17];
x q[15];
h q[2];
m[18] = measure q[2];
if (m[18] == 1) { cz q[0], q[1]; }
reset q[2];
h q[1];
m[19] = measure q[1];
if (m[19] == 1) { cz q[17], q[18]; }
reset q[1];
h q[0];
m[20] = measure q[0];
if (m[20] == 1) { cz q[15], q[16]; }
reset q[0];
x q[18];
x q[17];
x q[15];
x q[17];
x q[18];
ccx q[15], q[16], q[0];
ccx q[17], q[18], q[1];
ccx q[0], q[1], q[2];
x q[17];
x q[18];
if (m[2] == 1) { z q[2]; }
x q[18];
x q[17];
h q[2];
m[21] = measure q[2];
if (m[21] == 1) { cz q[0], q[1]; }
reset q[2];
h q[1];
m[22] = measure q[1];
if (m[22] == 1) { cz q[17], q[18]; }
reset q[1];
h q[0];
m[23] = measure q[0];
if (m[23] == 1) { cz q[15], q[16]; }
reset q[0];
x q[18];
x q[17];
x q[15];
x q[16];
x q[18];
ccx q[15], q[16], q[0];
ccx q[17], q[18], q[1];
ccx q[0], q[1], q[2];
x q[15];
x q[16];
x q[18];
if (m[3] == 1) { z q[2]; }
x q[18];
x q[16];
x q[15];
h q[2];
m[24] = measure q[2];
if (m[24] == 1) { cz q[0], q[1]; }
reset q[2];
h q[1];
m[25] = measure q[1];
if (m[25] == 1) { cz q[17], q[18]; }
reset q[1];
h q[0];
m[26] = measure q[0];
if (m[26] == 1) { cz q[15], q[16]; }
reset q[0];
x q[18];
x q[16];
x q[15];
x q[16];
x q[18];
ccx q[15], q[16], q[0];
ccx q[17], q[18], q[1];
ccx q[0], q[1], q[2];
x q[16];
x q[18];
if (m[4] == 1) { z q[2]; }
x q[18];
x q[16];
h q[2];
m[27] = measure q[2];
if (m[27] == 1) { cz q[0], q[1]; }
reset q[2];
h q[1];
m[28] = measure q[1];
if (m[28] == 1) { cz q[17], q[18]; }
reset q[1];
h q[0];
m[29] = measure q[0];
if (m[29] == 1) { cz q[15], q[16]; }
reset q[0];
x q[18];
x q[16];
x q[15];
x q[18];
ccx q[15], q[16], q[0];
ccx q[17], q[18], q[1];
ccx q[0], q[1], q[2];
x q[15];
x q[18];
if (m[5] == 1) { z q[2]; }
x q[18];
x q[15];
h q[2];
m[30] = measure q[2];
if (m[30] == 1) { cz q[0], q[1]; }
reset q[2];
h q[1];
m[31] = measure q[1];
if (m[31] == 1) { cz q[17], q[18]; }
reset q[1];
h q[0];
m[32] = measure q[0];
if (m[32] == 1) { cz q[15], q[16]; }
reset q[0];
x q[18];
x q[15];
x q[18];
ccx q[15], q[16], q[0];
ccx q[17], q[18], q[1];
ccx q[0], q[1], q[2];
x q[18];
if (m[6] == 1) { z q[2]; }
x q[18];
h q[2];
m[33] = measure q[2];
if (m[33] == 1) { cz q[0], q[1]; }
reset q[2];
h q[1];
m[34] = measure q[1];
if (m[34] == 1) { cz q[17], q[18]; }
reset q[1];
h q[0];
m[35] = measure q[0];
if (m[35] == 1) { cz q[15], q[16]; }
reset q[0];
x q[18];
x q[15];
x q[16];
x q[17];
ccx q[15], q[16], q[0];
ccx q[17], q[18], q[1];
ccx q[0], q[1], q[2];
x q[15];
x q[16];
x q[17];
if (m[7] == 1) { z q[2]; }
x q[17];
x q[16];
x q[15];
h q[2];
m[36] = measure q[2];
if (m[36] == 1) { cz q[0], q[1]; }
reset q[2];
h q[1];
m[37] = measure q[1];
if (m[37] == 1) { cz q[17], q[18]; }
reset q[1];
h q[0];
m[38] = measure q[0];
if (m[38] == 1) { cz q[15], q[16]; }
reset q[0];
x q[17];
x q[16];
x q[15];
x q[16];
x q[17];
ccx q[15], q[16], q[0];
ccx q[17], q[18], q[1];
ccx q[0], q[1], q[2];
x q[16];
x q[17];
if (m[8] == 1) { z q[2]; }
x q[17];
x q[16];
h q[2];
m[39] = measure q[2];
if (m[39] == 1) { cz q[0], q[1]; }
reset q[2];
h q[1];
m[40] = measure q[1];
if (m[40] == 1) { cz q[17], q[18]; }
reset q[1];
h q[0];
m[41] = measure q[0];
if (m[41] == 1) { cz q[15], q[16]; }
reset q[0];
x q[17];
x q[16];
x q[15];
x q[17];
ccx q[15], q[16], q[0];
ccx q[17], q[18], q[1];
ccx q[0], q[1], q[2];
x q[15];
x q[17];
if (m[9] == 1) { z q[2]; }
x q[17];
x q[15];
h q[2];
m[42] = measure q[2];
if (m[42] == 1) { cz q[0], q[1]; }
reset q[2];
h q[1];
m[43] = measure q[1];
if (m[43] == 1) { cz q[17], q[18]; }
reset q[1];
h q[0];
m[44] = measure q[0];
if (m[44] == 1) { cz q[15], q[16]; }
reset q[0];
x q[17];
x q[15];
x q[17];
ccx q[15], q[16], q[0];
ccx q[17], q[18], q[1];
ccx q[0], q[1], q[2];
x q[17];
if (m[10] == 1) { z q[2]; }
x q[17];
h q[2];
m[45] = measure q[2];
if (m[45] == 1) { cz q[0], q[1]; }
reset q[2];
h q[1];
m[46] = measure q[1];
if (m[46] == 1) { cz q[17], q[18]; }
reset q[1];
h q[0];
m[47] = measure q[0];
if (m[47] == 1) { cz q[15], q[16]; }
reset q[0];
x q[17];
x q[15];
x q[16];
ccx q[15], q[16], q[0];
ccx q[17], q[18], q[1];
ccx q[0], q[1], q[2];
x q[15];
x q[16];
if (m[11] == 1) { z q[2]; }
x q[16];
x q[15];
h q[2];
m[48] = measure q[2];
if (m[48] == 1) { cz q[0], q[1]; }
reset q[2];
h q[1];
m[49] = measure q[1];
if (m[49] == 1) { cz q[17], q[18]; }
reset q[1];
h q[0];
m[50] = measure q[0];
if (m[50] == 1) { cz q[15], q[16]; }
reset q[0];
x q[16];
x q[15];
x q[16];
ccx q[15], q[16], q[0];
ccx q[17], q[18], q[1];
ccx q[0], q[1], q[2];
x q[16];
if (m[12] == 1) { z q[2]; }
x q[16];
h q[2];
m[51] = measure q[2];
if (m[51] == 1) { cz q[0], q[1]; }
reset q[2];
h q[1];
m[52] = measure q[1];
if (m[52] == 1) { cz q[17], q[18]; }
reset q[1];
h q[0];
m[53] = measure q[0];
if (m[53] == 1) { cz q[15], q[16]; }
reset q[0];
x q[16];
x q[15];
ccx q[15], q[16], q[0];
ccx q[17], q[18], q[1];
ccx q[0], q[1], q[2];
x q[15];
if (m[13] == 1) { z q[2]; }
x q[15];
h q[2];
m[54] = measure q[2];
if (m[54] == 1) { cz q[0], q[1]; }
reset q[2];
h q[1];
m[55] = measure q[1];
if (m[55] == 1) { cz q[17], q[18]; }
reset q[1];
h q[0];
m[56] = measure q[0];
if (m[56] == 1) { cz q[15], q[16]; }
reset q[0];
x q[15];
ccx q[15], q[16], q[0];
ccx q[17], q[18], q[1];
ccx q[0], q[1], q[2];
if (m[14] == 1) { z q[2]; }
h q[2];
m[57] = measure q[2];
if (m[57] == 1) { cz q[0], q[1]; }
reset q[2];
h q[1];
m[58] = measure q[1];
if (m[58] == 1) { cz q[17], q[18]; }
reset q[1];
h q[0];
m[59] = measure q[0];
if (m[59] == 1) { cz q[15], q[16]; }
reset q[0];
h q[15];
h q[16];
h q[17];
h q[18];
