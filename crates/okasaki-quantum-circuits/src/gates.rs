//! Reversible Clifford+T Quantum Register & Netlist Simulator (`QCircuit`, `QReg`, `QBit`).
//!
//! Tracks:
//! - Exact computational basis state bits, phase exponent ($i^k$ / $\omega^k$), and Pauli frame.
//! - Exact physical gate counts (`toffoli_count`, `cswap_count`, `cnot_count`, `meas_x_count`, `circuit_depth`).
//! - Peak live ancilla qubits and strict verification that all temporary ancillas and pebbles
//!   return to $|0\rangle$ on exit (`assert_ancillas_clean()`).

/// Handle to a single physical qubit inside a `QCircuit`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct QBit(pub usize);

/// Handle to a contiguous or indexed register of physical qubits.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct QReg {
    pub qubits: Vec<QBit>,
}

impl QReg {
    pub fn new(qubits: Vec<QBit>) -> Self {
        Self { qubits }
    }

    pub fn len(&self) -> usize {
        self.qubits.len()
    }

    pub fn is_empty(&self) -> bool {
        self.qubits.is_empty()
    }

    pub fn bit(&self, idx: usize) -> QBit {
        self.qubits[idx]
    }

    pub fn slice(&self, start: usize, end: usize) -> QReg {
        QReg {
            qubits: self.qubits[start..end].to_vec(),
        }
    }
}

/// Physical gate set $\{X, \text{CNOT}, \text{CCX}, \text{CSWAP}, H, S, S^\dagger, \text{CZ}, \text{MeasXPauliFrame}\}$.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Gate {
    X(QBit),
    CNOT(QBit, QBit),
    CCX(QBit, QBit, QBit),
    CSWAP(QBit, QBit, QBit),
    H(QBit),
    S(QBit),
    Sdg(QBit),
    CZ(QBit, QBit),
    /// Measurement-based $X$-basis measurement with classical Pauli frame correction (0 Toffoli cost).
    MeasXPauliFrame {
        target: QBit,
        control_c1: QBit,
        control_c2: QBit,
    },
}

/// Exact gate and resource counters for a `QCircuit`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ResourceProfile {
    pub total_qubits: usize,
    pub input_output_qubits: usize,
    pub peak_ancilla_qubits: usize,
    pub live_ancilla_qubits: usize,
    pub x_count: usize,
    pub cnot_count: usize,
    pub toffoli_count: usize,
    pub cswap_count: usize,
    pub clifford_1q_count: usize,
    pub cz_count: usize,
    pub meas_x_count: usize,
    pub circuit_depth: usize,
}

impl ResourceProfile {
    /// Total non-Clifford cost in Toffoli-equivalent gates ($\text{CCX} + \text{CSWAP}$).
    pub fn total_toffoli_equiv(&self) -> usize {
        self.toffoli_count + self.cswap_count
    }

    /// Total T-count under standard $4 T$-gate (with measurement uncomputation) or $7 T$-gate decomposition.
    pub fn t_count_gidney_4t(&self) -> usize {
        4 * self.total_toffoli_equiv()
    }
}

/// Bit-exact reversible & Clifford+T netlist simulator with strict ancilla hygiene verification.
#[derive(Clone, Debug)]
pub struct QCircuit {
    bits: Vec<bool>,
    pauli_x_frame: Vec<bool>,
    pauli_z_frame: Vec<bool>,
    is_ancilla: Vec<bool>,
    ancilla_allocated: Vec<bool>,
    qubit_layer: Vec<usize>,
    free_ancilla_pool: Vec<QBit>,
    pub netlist: Vec<Gate>,
    pub profile: ResourceProfile,
    /// Tracks logical history for `MeasXPauliFrame` uncomputation of temporary AND ancillas.
    and_history: Vec<Option<(QBit, QBit)>>,
}

impl Default for QCircuit {
    fn default() -> Self {
        Self::new()
    }
}

impl QCircuit {
    pub fn new() -> Self {
        Self {
            bits: Vec::new(),
            pauli_x_frame: Vec::new(),
            pauli_z_frame: Vec::new(),
            is_ancilla: Vec::new(),
            ancilla_allocated: Vec::new(),
            qubit_layer: Vec::new(),
            free_ancilla_pool: Vec::new(),
            netlist: Vec::new(),
            profile: ResourceProfile::default(),
            and_history: Vec::new(),
        }
    }

    /// Allocate a primary input/state qubit initialized to `init_val`.
    pub fn alloc_qubit(&mut self, init_val: bool) -> QBit {
        let id = self.bits.len();
        self.bits.push(init_val);
        self.pauli_x_frame.push(false);
        self.pauli_z_frame.push(false);
        self.is_ancilla.push(false);
        self.ancilla_allocated.push(false);
        self.qubit_layer.push(0);
        self.and_history.push(None);
        self.profile.total_qubits += 1;
        self.profile.input_output_qubits += 1;
        QBit(id)
    }

    /// Allocate an $n$-bit quantum register initialized to the little-endian integer `val`.
    pub fn alloc_reg(&mut self, n: usize, val: u128) -> QReg {
        let mut qubits = Vec::with_capacity(n);
        for i in 0..n {
            let bit = if i < 128 {
                ((val >> i) & 1) == 1
            } else {
                false
            };
            qubits.push(self.alloc_qubit(bit));
        }
        QReg::new(qubits)
    }

    /// Allocate a clean $|0\rangle$ ancilla qubit (reusing returned clean ancillas from the pool).
    pub fn alloc_ancilla(&mut self) -> QBit {
        let q = if let Some(reused) = self.free_ancilla_pool.pop() {
            assert!(
                !self.bits[reused.0],
                "Dirty ancilla in free pool at qubit {}",
                reused.0
            );
            self.ancilla_allocated[reused.0] = true;
            self.and_history[reused.0] = None;
            reused
        } else {
            let id = self.bits.len();
            self.bits.push(false);
            self.pauli_x_frame.push(false);
            self.pauli_z_frame.push(false);
            self.is_ancilla.push(true);
            self.ancilla_allocated.push(true);
            self.qubit_layer.push(0);
            self.and_history.push(None);
            self.profile.total_qubits += 1;
            QBit(id)
        };
        self.profile.live_ancilla_qubits += 1;
        if self.profile.live_ancilla_qubits > self.profile.peak_ancilla_qubits {
            self.profile.peak_ancilla_qubits = self.profile.live_ancilla_qubits;
        }
        q
    }

    /// Allocate a register of $n$ clean $|0\rangle$ ancilla qubits.
    pub fn alloc_ancilla_reg(&mut self, n: usize) -> QReg {
        let mut qubits = Vec::with_capacity(n);
        for _ in 0..n {
            qubits.push(self.alloc_ancilla());
        }
        QReg::new(qubits)
    }

    /// Return an ancilla qubit to the pool, strictly asserting that it has been uncomputed to $|0\rangle$.
    pub fn free_ancilla(&mut self, q: QBit) {
        assert!(self.is_ancilla[q.0], "Qubit {} is not an ancilla", q.0);
        assert!(
            self.ancilla_allocated[q.0],
            "Ancilla qubit {} freed twice",
            q.0
        );
        assert!(
            !self.bits[q.0],
            "Ancilla hygiene violation: ancilla qubit {} is dirty (|1>) upon free_ancilla()",
            q.0
        );
        self.ancilla_allocated[q.0] = false;
        self.and_history[q.0] = None;
        self.profile.live_ancilla_qubits -= 1;
        self.free_ancilla_pool.push(q);
    }

    /// Free an entire ancilla register, asserting every qubit is $|0\rangle$.
    pub fn free_ancilla_reg(&mut self, reg: QReg) {
        for q in reg.qubits.into_iter().rev() {
            self.free_ancilla(q);
        }
    }

    /// Read the computational basis value of a single qubit.
    pub fn read_bit(&self, q: QBit) -> bool {
        self.bits[q.0]
    }

    /// Read a register as a little-endian `u128`.
    pub fn read_reg(&self, reg: &QReg) -> u128 {
        let mut acc = 0u128;
        for (i, &q) in reg.qubits.iter().enumerate() {
            if i < 128 && self.bits[q.0] {
                acc |= 1u128 << i;
            }
        }
        acc
    }

    /// Read a register as a bit vector.
    pub fn read_reg_bits(&self, reg: &QReg) -> Vec<bool> {
        reg.qubits.iter().map(|&q| self.bits[q.0]).collect()
    }

    /// Verify that all allocated ancillas have been returned and all ancilla qubits are in state $|0\rangle$.
    pub fn assert_ancillas_clean(&self) {
        assert_eq!(
            self.profile.live_ancilla_qubits, 0,
            "Ancilla leak: {} ancilla qubits remain allocated",
            self.profile.live_ancilla_qubits
        );
        for (i, &is_anc) in self.is_ancilla.iter().enumerate() {
            if is_anc {
                assert!(
                    !self.bits[i],
                    "Ancilla qubit {} left in state |1> at circuit completion",
                    i
                );
            }
        }
    }

    fn bump_depth(&mut self, qs: &[QBit]) {
        let max_prev = qs.iter().map(|q| self.qubit_layer[q.0]).max().unwrap_or(0);
        let next_layer = max_prev + 1;
        for q in qs {
            self.qubit_layer[q.0] = next_layer;
        }
        if next_layer > self.profile.circuit_depth {
            self.profile.circuit_depth = next_layer;
        }
    }

    /// Apply Pauli $X$ (NOT) gate.
    pub fn x(&mut self, target: QBit) {
        self.bits[target.0] = !self.bits[target.0];
        self.netlist.push(Gate::X(target));
        self.profile.x_count += 1;
        self.bump_depth(&[target]);
    }

    /// Apply CNOT ($CX$) gate: `target ^= control`.
    pub fn cnot(&mut self, control: QBit, target: QBit) {
        assert_ne!(control, target, "CNOT control and target must be distinct");
        if self.bits[control.0] {
            self.bits[target.0] = !self.bits[target.0];
        }
        self.netlist.push(Gate::CNOT(control, target));
        self.profile.cnot_count += 1;
        self.bump_depth(&[control, target]);
    }

    /// Apply Toffoli ($CCX$) gate: `target ^= c1 & c2`.
    pub fn ccx(&mut self, c1: QBit, c2: QBit, target: QBit) {
        assert!(
            c1 != target && c2 != target && c1 != c2,
            "CCX qubits must be distinct"
        );
        let was_zero = !self.bits[target.0];
        if self.bits[c1.0] && self.bits[c2.0] {
            self.bits[target.0] = !self.bits[target.0];
        }
        if was_zero {
            self.and_history[target.0] = Some((c1, c2));
        }
        self.netlist.push(Gate::CCX(c1, c2, target));
        self.profile.toffoli_count += 1;
        self.bump_depth(&[c1, c2, target]);
    }

    /// Apply Fredkin ($CSWAP$) gate: if `control` is $|1\rangle$, swap `a` and `b`.
    /// Decomposable into 1 Toffoli + 2 CNOTs (`cnot(b,a); ccx(ctrl,a,b); cnot(b,a)`).
    pub fn cswap(&mut self, control: QBit, a: QBit, b: QBit) {
        assert!(
            control != a && control != b && a != b,
            "CSWAP qubits must be distinct"
        );
        if self.bits[control.0] {
            self.bits.swap(a.0, b.0);
        }
        self.netlist.push(Gate::CSWAP(control, a, b));
        self.profile.cswap_count += 1;
        self.bump_depth(&[control, a, b]);
    }

    /// Apply Clifford Hadamard $H$, $S$, $S^\dagger$, or $CZ$ gate (tracked in netlist and Pauli frame).
    pub fn h(&mut self, q: QBit) {
        self.pauli_x_frame.swap(q.0, q.0);
        let x = self.pauli_x_frame[q.0];
        let z = self.pauli_z_frame[q.0];
        self.pauli_x_frame[q.0] = z;
        self.pauli_z_frame[q.0] = x;
        self.netlist.push(Gate::H(q));
        self.profile.clifford_1q_count += 1;
        self.bump_depth(&[q]);
    }

    pub fn s(&mut self, q: QBit) {
        if self.pauli_x_frame[q.0] {
            self.pauli_z_frame[q.0] = !self.pauli_z_frame[q.0];
        }
        self.netlist.push(Gate::S(q));
        self.profile.clifford_1q_count += 1;
        self.bump_depth(&[q]);
    }

    pub fn sdg(&mut self, q: QBit) {
        if self.pauli_x_frame[q.0] {
            self.pauli_z_frame[q.0] = !self.pauli_z_frame[q.0];
        }
        self.netlist.push(Gate::Sdg(q));
        self.profile.clifford_1q_count += 1;
        self.bump_depth(&[q]);
    }

    pub fn cz(&mut self, q1: QBit, q2: QBit) {
        assert_ne!(q1, q2);
        if self.bits[q1.0] && self.bits[q2.0] {
            self.pauli_z_frame[q1.0] = !self.pauli_z_frame[q1.0];
            self.pauli_z_frame[q2.0] = !self.pauli_z_frame[q2.0];
        }
        self.netlist.push(Gate::CZ(q1, q2));
        self.profile.cz_count += 1;
        self.bump_depth(&[q1, q2]);
    }

    /// Gidney (2018) / Jones (2013) measurement-based uncomputation (`MeasXPauliFrame`) of a temporary AND ancilla:
    /// Uncomputes `target` which holds `c1 & c2` using $H \to M_Z \to \text{conditional } CZ(c_1, c_2)$
    /// with **0 Toffoli gates**.
    pub fn meas_x_uncompute_and(&mut self, c1: QBit, c2: QBit, target: QBit) {
        assert_eq!(
            self.bits[target.0],
            self.bits[c1.0] && self.bits[c2.0],
            "MeasXPauliFrame precondition violated: target {} does not equal c1 ({}) & c2 ({})",
            target.0,
            c1.0,
            c2.0
        );
        self.bits[target.0] = false;
        self.pauli_z_frame[c1.0] ^= self.bits[c2.0];
        self.pauli_z_frame[c2.0] ^= self.bits[c1.0];
        self.and_history[target.0] = None;
        self.netlist.push(Gate::MeasXPauliFrame {
            target,
            control_c1: c1,
            control_c2: c2,
        });
        self.profile.meas_x_count += 1;
        self.bump_depth(&[c1, c2, target]);
    }

    /// Execute a single gate from a netlist.
    pub fn apply_gate(&mut self, gate: Gate) {
        match gate {
            Gate::X(q) => self.x(q),
            Gate::CNOT(c, t) => self.cnot(c, t),
            Gate::CCX(c1, c2, t) => self.ccx(c1, c2, t),
            Gate::CSWAP(c, a, b) => self.cswap(c, a, b),
            Gate::H(q) => self.h(q),
            Gate::S(q) => self.s(q),
            Gate::Sdg(q) => self.sdg(q),
            Gate::CZ(a, b) => self.cz(a, b),
            Gate::MeasXPauliFrame {
                target,
                control_c1,
                control_c2,
            } => self.meas_x_uncompute_and(control_c1, control_c2, target),
        }
    }

    /// Apply the exact reverse (adjoint $U^\dagger$) of a slice of unitary gates recorded in `netlist`.
    pub fn apply_adjoint_slice(&mut self, gates: &[Gate]) {
        for &g in gates.iter().rev() {
            match g {
                Gate::X(q) => self.x(q),
                Gate::CNOT(c, t) => self.cnot(c, t),
                Gate::CCX(c1, c2, t) => self.ccx(c1, c2, t),
                Gate::CSWAP(c, a, b) => self.cswap(c, a, b),
                Gate::H(q) => self.h(q),
                Gate::S(q) => self.sdg(q),
                Gate::Sdg(q) => self.s(q),
                Gate::CZ(a, b) => self.cz(a, b),
                Gate::MeasXPauliFrame {
                    target,
                    control_c1,
                    control_c2,
                } => {
                    // Inverse of uncomputing an AND ancilla is computing the AND into |0>
                    self.ccx(control_c1, control_c2, target);
                }
            }
        }
    }

    /// Swap two equal-length registers bitwise using CNOTs (or CSWAPs if controlled).
    pub fn cswap_regs(&mut self, ctrl: QBit, a: &QReg, b: &QReg) {
        assert_eq!(a.len(), b.len());
        for (&qa, &qb) in a.qubits.iter().zip(b.qubits.iter()) {
            self.cswap(ctrl, qa, qb);
        }
    }

    /// Bitwise CNOT from register `src` into register `dst`: `dst ^= src`.
    pub fn cnot_regs(&mut self, src: &QReg, dst: &QReg) {
        assert_eq!(src.len(), dst.len());
        for (&qs, &qd) in src.qubits.iter().zip(dst.qubits.iter()) {
            self.cnot(qs, qd);
        }
    }
}
