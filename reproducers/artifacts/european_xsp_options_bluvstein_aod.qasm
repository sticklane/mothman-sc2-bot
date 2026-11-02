OPENQASM 3.0;
include "stdgates.inc";
qubit[10] q;
bit[21] m;
ry(2.168202743440) q[0];
ry(1.183199640140) q[1];
cx q[0], q[1];
ry(-1.183199640140) q[1];
cx q[0], q[1];
cx q[1], q[0];
ry(1.150261991511) q[2];
cx q[1], q[2];
ry(-1.150261991511) q[2];
cx q[1], q[2];
cx q[2], q[1];
ry(1.107148717794) q[3];
cx q[2], q[3];
ry(-1.107148717794) q[3];
cx q[2], q[3];
cx q[3], q[2];
ry(1.047197551197) q[4];
cx q[3], q[4];
ry(-1.047197551197) q[4];
cx q[3], q[4];
cx q[4], q[3];
ry(0.955316618125) q[5];
cx q[4], q[5];
ry(-0.955316618125) q[5];
cx q[4], q[5];
cx q[5], q[4];
ry(0.785398163397) q[6];
cx q[5], q[6];
ry(-0.785398163397) q[6];
cx q[5], q[6];
cx q[6], q[5];
z q[2];
z q[3];
z q[5];
cx q[0], q[7];
cx q[1], q[8];
cx q[2], q[7];
cx q[2], q[8];
cx q[3], q[9];
cx q[4], q[7];
cx q[4], q[9];
cx q[5], q[8];
cx q[5], q[9];
cx q[6], q[7];
cx q[6], q[8];
cx q[6], q[9];
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
x q[8];
x q[9];
ccx q[7], q[8], q[0];
ccx q[0], q[9], q[1];
x q[8];
x q[9];
if (m[0] == 1) { z q[1]; }
x q[9];
x q[8];
h q[1];
m[7] = measure q[1];
if (m[7] == 1) { cz q[0], q[9]; }
reset q[1];
h q[0];
m[8] = measure q[0];
if (m[8] == 1) { cz q[7], q[8]; }
reset q[0];
x q[9];
x q[8];
x q[7];
x q[9];
ccx q[7], q[8], q[0];
ccx q[0], q[9], q[1];
x q[7];
x q[9];
if (m[1] == 1) { z q[1]; }
x q[9];
x q[7];
h q[1];
m[9] = measure q[1];
if (m[9] == 1) { cz q[0], q[9]; }
reset q[1];
h q[0];
m[10] = measure q[0];
if (m[10] == 1) { cz q[7], q[8]; }
reset q[0];
x q[9];
x q[7];
x q[9];
ccx q[7], q[8], q[0];
ccx q[0], q[9], q[1];
x q[9];
if (m[2] == 1) { z q[1]; }
x q[9];
h q[1];
m[11] = measure q[1];
if (m[11] == 1) { cz q[0], q[9]; }
reset q[1];
h q[0];
m[12] = measure q[0];
if (m[12] == 1) { cz q[7], q[8]; }
reset q[0];
x q[9];
x q[7];
x q[8];
ccx q[7], q[8], q[0];
ccx q[0], q[9], q[1];
x q[7];
x q[8];
if (m[3] == 1) { z q[1]; }
x q[8];
x q[7];
h q[1];
m[13] = measure q[1];
if (m[13] == 1) { cz q[0], q[9]; }
reset q[1];
h q[0];
m[14] = measure q[0];
if (m[14] == 1) { cz q[7], q[8]; }
reset q[0];
x q[8];
x q[7];
x q[8];
ccx q[7], q[8], q[0];
ccx q[0], q[9], q[1];
x q[8];
if (m[4] == 1) { z q[1]; }
x q[8];
h q[1];
m[15] = measure q[1];
if (m[15] == 1) { cz q[0], q[9]; }
reset q[1];
h q[0];
m[16] = measure q[0];
if (m[16] == 1) { cz q[7], q[8]; }
reset q[0];
x q[8];
x q[7];
ccx q[7], q[8], q[0];
ccx q[0], q[9], q[1];
x q[7];
if (m[5] == 1) { z q[1]; }
x q[7];
h q[1];
m[17] = measure q[1];
if (m[17] == 1) { cz q[0], q[9]; }
reset q[1];
h q[0];
m[18] = measure q[0];
if (m[18] == 1) { cz q[7], q[8]; }
reset q[0];
x q[7];
ccx q[7], q[8], q[0];
ccx q[0], q[9], q[1];
if (m[6] == 1) { z q[1]; }
h q[1];
m[19] = measure q[1];
if (m[19] == 1) { cz q[0], q[9]; }
reset q[1];
h q[0];
m[20] = measure q[0];
if (m[20] == 1) { cz q[7], q[8]; }
reset q[0];
h q[7];
h q[8];
h q[9];
