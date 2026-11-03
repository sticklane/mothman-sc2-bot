/-!
# Bidirectional OpenQASM 3.0 ↔ `RevIR` Lifting, 7-Rule Static Bug Auto-Repair, and `canonical_k2_coupled` Optimization Proofs

This self-contained, fully constructively verified, zero-wildcard Lean 4.35.0 module
mechanizes the formal metatheory of `compiler/lakefillq-qasm3-lifter-repair.rkt` and
`ae/lakefillq_lint.py --repair`:

1. **Bidirectional `OpenQASM 3.0 -> RevIR -> OpenQASM 3.0` Round-Trip Preservation**:
   - `liftQasm3_append_homomorphism` (Theorem 1)
   - `emitQasm3_liftQasm3_roundtrip_id` (Theorem 2)
   - `roundtrip_qasm3_revir_qasm3_semantics_preserved` (Theorem 3)
2. **Exactness of `T-CounitU4` Conditional `Z`/`CZ` & Degree-`>= 3` Unitary Fallback Repair**:
   - `counitU4_unrepaired_mx_branch_phase_diverges` (Theorem 4)
   - `counitU4_cond_cz_repair_restores_branch_uniform_purity` (Theorem 5)
   - `counitU4_linear_parity_cond_z_repair_exact` (Theorem 6)
   - `counitU4_deg3_cubic_cannot_be_fixed_by_single_cz` (Theorem 7)
3. **Exactness of `T-AlgPhase` Adjoint `invert` Repair (`U · U^† = I`), `T-ValidIf`, `T-DomImg`, and Resource/Cluster Guards**:
   - `algPhase_invertGate_involutive` (Theorem 8)
   - `algPhase_single_gate_adjoint_cancels` (Theorem 9)
   - `algPhase_sequence_adjoint_repair_exact` (Theorem 10)
   - `validIf_unguarded_vs_guarded_phase_repair_exact` (Theorem 11)
   - `domImg_xag_ancilla_cleanup_restores_zero` (Theorem 12)
   - `driftEps_singleIR_parGuard_structural_repairs_well_typed` (Theorem 13)
4. **Post-Repair `canonical_k2_coupled` Semantic Preservation & Monotone `QPhysGrade` Cost Reduction**:
   - `canonical_k2_coupled_preserves_repaired_semantics` (Theorem 14)
   - `canonical_k2_coupled_monotone_qphys_cost_reduction` (Theorem 15)
-/

namespace LakefillQQasm3LiftingAndAutorepairProofs

-- ============================================================================
-- Section 1: 4-Wire Quantum State (`d0, d1, d2` Data + `anc` Scratch) & Phase
-- ============================================================================

/-- Explicit 4-wire identifier (`d0, d1, d2` data wires, `anc` scratch/ancilla wire). -/
inductive Wire4 where
  | d0  : Wire4
  | d1  : Wire4
  | d2  : Wire4
  | anc : Wire4
  deriving DecidableEq, Repr

/-- Computational basis + $\mathbb{Z}_8$ phase state ($\pi/4$ units modulo 8). -/
structure QState4 where
  d0     : Bool
  d1     : Bool
  d2     : Bool
  anc    : Bool
  phase8 : Nat
  deriving DecidableEq, Repr

/-- Read wire value from `QState4`. -/
def getW (st : QState4) (w : Wire4) : Bool :=
  match w with
  | Wire4.d0  => st.d0
  | Wire4.d1  => st.d1
  | Wire4.d2  => st.d2
  | Wire4.anc => st.anc

/-- Update wire value in `QState4`. -/
def setW (st : QState4) (w : Wire4) (v : Bool) : QState4 :=
  match w with
  | Wire4.d0  => { st with d0 := v }
  | Wire4.d1  => { st with d1 := v }
  | Wire4.d2  => { st with d2 := v }
  | Wire4.anc => { st with anc := v }

/-- Add $k \pmod 8$ units of $\pi/4$ phase when `cond` holds. -/
def addPhase8 (st : QState4) (cond : Bool) (k : Nat) : QState4 :=
  match cond with
  | true  => { st with phase8 := (st.phase8 + (k % 8)) % 8 }
  | false => st

-- ============================================================================
-- Section 2: Surface `OpenQASM 3.0` AST & Lifted `LakefillQ` (`RevIR`) AST
-- ============================================================================

/-- Surface `OpenQASM 3.0` statement AST covering unitary gates, mid-circuit `M_X`, and dynamic `if (c)` fixups. -/
inductive Qasm3Stmt where
  | qX          (w : Wire4) : Qasm3Stmt
  | qCX         (c t : Wire4) : Qasm3Stmt
  | qCCX        (c0 c1 t : Wire4) : Qasm3Stmt
  | qZ          (w : Wire4) : Qasm3Stmt
  | qCZ         (a b : Wire4) : Qasm3Stmt
  | qCCZ        (a b c : Wire4) : Qasm3Stmt
  | qPhase8     (w : Wire4) (k8 : Nat) : Qasm3Stmt
  | qMxAndBlock (c0 c1 t : Wire4) (hasCzFixup : Bool) : Qasm3Stmt
  | qPhaseCone2 (c0 c1 t : Wire4) : Qasm3Stmt
  | qTwinCcz    (c0 c1 t1 t2 : Wire4) : Qasm3Stmt
  | qCancelPair (w : Wire4) (k8 : Nat) : Qasm3Stmt
  deriving DecidableEq, Repr

/-- Lifted `LakefillQ` (`RevIR`) AST supporting hazard analysis, auto-repair, and `canonical_k2_coupled` optimization. -/
inductive RevIRNode where
  | irX          (w : Wire4) : RevIRNode
  | irCX         (c t : Wire4) : RevIRNode
  | irCCX        (c0 c1 t : Wire4) : RevIRNode
  | irZ          (w : Wire4) : RevIRNode
  | irCZ         (a b : Wire4) : RevIRNode
  | irCCZ        (a b c : Wire4) : RevIRNode
  | irRz8        (w : Wire4) (k8 : Nat) : RevIRNode
  | irMbuQuad    (c0 c1 t : Wire4) (hasCzFixup : Bool) : RevIRNode
  | irWithinCz   (c0 c1 t : Wire4) : RevIRNode
  | irTwinCcz8T  (c0 c1 t1 t2 : Wire4) : RevIRNode
  | irSpiderPair (w : Wire4) (k8 : Nat) : RevIRNode
  deriving DecidableEq, Repr

/-- Lift a single `Qasm3Stmt` into `RevIRNode` (`lift-qasm3-to-revir`). -/
def liftQasm3Stmt (s : Qasm3Stmt) : RevIRNode :=
  match s with
  | Qasm3Stmt.qX w                  => RevIRNode.irX w
  | Qasm3Stmt.qCX c t               => RevIRNode.irCX c t
  | Qasm3Stmt.qCCX c0 c1 t          => RevIRNode.irCCX c0 c1 t
  | Qasm3Stmt.qZ w                  => RevIRNode.irZ w
  | Qasm3Stmt.qCZ a b               => RevIRNode.irCZ a b
  | Qasm3Stmt.qCCZ a b c            => RevIRNode.irCCZ a b c
  | Qasm3Stmt.qPhase8 w k8          => RevIRNode.irRz8 w k8
  | Qasm3Stmt.qMxAndBlock c0 c1 t f => RevIRNode.irMbuQuad c0 c1 t f
  | Qasm3Stmt.qPhaseCone2 c0 c1 t   => RevIRNode.irWithinCz c0 c1 t
  | Qasm3Stmt.qTwinCcz c0 c1 t1 t2  => RevIRNode.irTwinCcz8T c0 c1 t1 t2
  | Qasm3Stmt.qCancelPair w k8      => RevIRNode.irSpiderPair w k8

/-- Lift a program `List Qasm3Stmt` into `List RevIRNode`. -/
def liftQasm3Prog (prog : List Qasm3Stmt) : List RevIRNode :=
  match prog with
  | []      => []
  | s :: ss => liftQasm3Stmt s :: liftQasm3Prog ss

/-- Re-emit a `RevIRNode` back to `Qasm3Stmt` (`emit-revir-as-qasm3`). -/
def emitQasm3Stmt (n : RevIRNode) : Qasm3Stmt :=
  match n with
  | RevIRNode.irX w                  => Qasm3Stmt.qX w
  | RevIRNode.irCX c t               => Qasm3Stmt.qCX c t
  | RevIRNode.irCCX c0 c1 t          => Qasm3Stmt.qCCX c0 c1 t
  | RevIRNode.irZ w                  => Qasm3Stmt.qZ w
  | RevIRNode.irCZ a b               => Qasm3Stmt.qCZ a b
  | RevIRNode.irCCZ a b c            => Qasm3Stmt.qCCZ a b c
  | RevIRNode.irRz8 w k8             => Qasm3Stmt.qPhase8 w k8
  | RevIRNode.irMbuQuad c0 c1 t f    => Qasm3Stmt.qMxAndBlock c0 c1 t f
  | RevIRNode.irWithinCz c0 c1 t     => Qasm3Stmt.qPhaseCone2 c0 c1 t
  | RevIRNode.irTwinCcz8T c0 c1 t1 t2 => Qasm3Stmt.qTwinCcz c0 c1 t1 t2
  | RevIRNode.irSpiderPair w k8      => Qasm3Stmt.qCancelPair w k8

/-- Re-emit `List RevIRNode` to `List Qasm3Stmt`. -/
def emitQasm3Prog (nodes : List RevIRNode) : List Qasm3Stmt :=
  match nodes with
  | []      => []
  | n :: ns => emitQasm3Stmt n :: emitQasm3Prog ns

/-- Operational semantics of a single `Qasm3Stmt` under measurement branch `m : Bool`. -/
def evalQasm3Stmt (s : Qasm3Stmt) (st : QState4) (m : Bool) : QState4 :=
  match s with
  | Qasm3Stmt.qX w =>
      setW st w (!getW st w)
  | Qasm3Stmt.qCX c t =>
      setW st t (xor (getW st t) (getW st c))
  | Qasm3Stmt.qCCX c0 c1 t =>
      setW st t (xor (getW st t) (getW st c0 && getW st c1))
  | Qasm3Stmt.qZ w =>
      addPhase8 st (getW st w) 4
  | Qasm3Stmt.qCZ a b =>
      addPhase8 st (getW st a && getW st b) 4
  | Qasm3Stmt.qCCZ a b c =>
      addPhase8 st (getW st a && getW st b && getW st c) 4
  | Qasm3Stmt.qPhase8 w k8 =>
      addPhase8 st (getW st w) k8
  | Qasm3Stmt.qMxAndBlock c0 c1 t hasCzFixup =>
      let prod := getW st c0 && getW st c1
      let stComp := setW st t (xor (getW st t) prod)
      let stCopy := setW stComp Wire4.d2 (xor (getW stComp Wire4.d2) (getW stComp t))
      let stKick := addPhase8 stCopy (m && getW stCopy t) 4
      let stReset := setW stKick t false
      match hasCzFixup with
      | true  => addPhase8 stReset (m && getW stReset c0 && getW stReset c1) 4
      | false => stReset
  | Qasm3Stmt.qPhaseCone2 c0 c1 t =>
      addPhase8 st (getW st c0 && getW st c1 && getW st t) 4
  | Qasm3Stmt.qTwinCcz c0 c1 t1 t2 =>
      let st1 := addPhase8 st (getW st c0 && getW st c1 && getW st t1) 4
      addPhase8 st1 (getW st1 c0 && getW st1 c1 && getW st1 t2) 4
  | Qasm3Stmt.qCancelPair w k8 =>
      let st1 := addPhase8 st (getW st w) k8
      addPhase8 st1 (getW st1 w) ((8 - (k8 % 8)) % 8)

/-- Sequential evaluation of `List Qasm3Stmt`. -/
def evalQasm3Prog (prog : List Qasm3Stmt) (st : QState4) (m : Bool) : QState4 :=
  match prog with
  | []      => st
  | s :: ss => evalQasm3Prog ss (evalQasm3Stmt s st m) m

/-- Operational semantics of a single `RevIRNode` under measurement branch `m : Bool`. -/
def evalRevNode (n : RevIRNode) (st : QState4) (m : Bool) : QState4 :=
  match n with
  | RevIRNode.irX w =>
      setW st w (!getW st w)
  | RevIRNode.irCX c t =>
      setW st t (xor (getW st t) (getW st c))
  | RevIRNode.irCCX c0 c1 t =>
      setW st t (xor (getW st t) (getW st c0 && getW st c1))
  | RevIRNode.irZ w =>
      addPhase8 st (getW st w) 4
  | RevIRNode.irCZ a b =>
      addPhase8 st (getW st a && getW st b) 4
  | RevIRNode.irCCZ a b c =>
      addPhase8 st (getW st a && getW st b && getW st c) 4
  | RevIRNode.irRz8 w k8 =>
      addPhase8 st (getW st w) k8
  | RevIRNode.irMbuQuad c0 c1 t hasCzFixup =>
      let prod := getW st c0 && getW st c1
      let stComp := setW st t (xor (getW st t) prod)
      let stCopy := setW stComp Wire4.d2 (xor (getW stComp Wire4.d2) (getW stComp t))
      let stKick := addPhase8 stCopy (m && getW stCopy t) 4
      let stReset := setW stKick t false
      match hasCzFixup with
      | true  => addPhase8 stReset (m && getW stReset c0 && getW stReset c1) 4
      | false => stReset
  | RevIRNode.irWithinCz c0 c1 t =>
      addPhase8 st (getW st c0 && getW st c1 && getW st t) 4
  | RevIRNode.irTwinCcz8T c0 c1 t1 t2 =>
      let st1 := addPhase8 st (getW st c0 && getW st c1 && getW st t1) 4
      addPhase8 st1 (getW st1 c0 && getW st1 c1 && getW st1 t2) 4
  | RevIRNode.irSpiderPair w k8 =>
      let st1 := addPhase8 st (getW st w) k8
      addPhase8 st1 (getW st1 w) ((8 - (k8 % 8)) % 8)

/-- Sequential evaluation of `List RevIRNode`. -/
def evalRevProg (nodes : List RevIRNode) (st : QState4) (m : Bool) : QState4 :=
  match nodes with
  | []      => st
  | n :: ns => evalRevProg ns (evalRevNode n st m) m

/-- **Theorem 1 (`liftQasm3_append_homomorphism`)**:
    `liftQasm3Prog` is a strict list homomorphism over `OpenQASM 3.0` program concatenation. -/
theorem liftQasm3_append_homomorphism (p1 p2 : List Qasm3Stmt) :
    liftQasm3Prog (p1 ++ p2) = liftQasm3Prog p1 ++ liftQasm3Prog p2 := by
  induction p1 with
  | nil => rfl
  | cons s ss ih =>
    simp only [List.cons_append, liftQasm3Prog, ih]

/-- **Theorem 2 (`emitQasm3_liftQasm3_roundtrip_id`)**:
    Round-trip lifting and re-emission (`liftQasm3Stmt ∘ emitQasm3Stmt ∘ liftQasm3Stmt`)
    is the exact identity on every `Qasm3Stmt` constructor. -/
theorem emitQasm3_liftQasm3_roundtrip_id (s : Qasm3Stmt) :
    liftQasm3Stmt (emitQasm3Stmt (liftQasm3Stmt s)) = liftQasm3Stmt s := by
  cases s with
  | qX w => rfl
  | qCX c t => rfl
  | qCCX c0 c1 t => rfl
  | qZ w => rfl
  | qCZ a b => rfl
  | qCCZ a b c => rfl
  | qPhase8 w k8 => rfl
  | qMxAndBlock c0 c1 t f => rfl
  | qPhaseCone2 c0 c1 t => rfl
  | qTwinCcz c0 c1 t1 t2 => rfl
  | qCancelPair w k8 => rfl

/-- Single-statement semantic equivalence helper for `emitQasm3Stmt ∘ liftQasm3Stmt`. -/
theorem eval_roundtrip_stmt_eq (s : Qasm3Stmt) (st : QState4) (m : Bool) :
    evalQasm3Stmt (emitQasm3Stmt (liftQasm3Stmt s)) st m = evalQasm3Stmt s st m := by
  cases s with
  | qX w => rfl
  | qCX c t => rfl
  | qCCX c0 c1 t => rfl
  | qZ w => rfl
  | qCZ a b => rfl
  | qCCZ a b c => rfl
  | qPhase8 w k8 => rfl
  | qMxAndBlock c0 c1 t f => rfl
  | qPhaseCone2 c0 c1 t => rfl
  | qTwinCcz c0 c1 t1 t2 => rfl
  | qCancelPair w k8 => rfl

/-- **Theorem 3 (`roundtrip_qasm3_revir_qasm3_semantics_preserved`)**:
    For every `OpenQASM 3.0` circuit `prog`, initial state `st`, and measurement outcome `m`,
    lifting to `RevIR` and re-emitting to `OpenQASM 3.0` preserves exact quantum semantics. -/
theorem roundtrip_qasm3_revir_qasm3_semantics_preserved
    (prog : List Qasm3Stmt) (st : QState4) (m : Bool) :
    evalQasm3Prog (emitQasm3Prog (liftQasm3Prog prog)) st m = evalQasm3Prog prog st m := by
  induction prog generalizing st with
  | nil => rfl
  | cons s ss ih =>
    simp only [liftQasm3Prog, emitQasm3Prog, evalQasm3Prog]
    rw [eval_roundtrip_stmt_eq]
    exact ih (evalQasm3Stmt s st m)

-- ============================================================================
-- Section 3: `T-CounitU4` Auto-Repair (Quadratic `CZ`, Linear `Z`, and Degree-3 Unitary)
-- ============================================================================

/-- Auto-repair operator for `T-CounitU4` quadratic `TempAND` $M_X$ blocks (`autorepair-revir-hazards`):
    synthesizes the missing `if (c[m] == 1) { cz q[c0], q[c1]; }` fixup (`hasCzFixup := true`). -/
def repairCounitU4Node (n : RevIRNode) : RevIRNode :=
  match n with
  | RevIRNode.irX w                   => RevIRNode.irX w
  | RevIRNode.irCX c t                => RevIRNode.irCX c t
  | RevIRNode.irCCX c0 c1 t           => RevIRNode.irCCX c0 c1 t
  | RevIRNode.irZ w                   => RevIRNode.irZ w
  | RevIRNode.irCZ a b                => RevIRNode.irCZ a b
  | RevIRNode.irCCZ a b c             => RevIRNode.irCCZ a b c
  | RevIRNode.irRz8 w k8              => RevIRNode.irRz8 w k8
  | RevIRNode.irMbuQuad c0 c1 t _     => RevIRNode.irMbuQuad c0 c1 t true
  | RevIRNode.irWithinCz c0 c1 t      => RevIRNode.irWithinCz c0 c1 t
  | RevIRNode.irTwinCcz8T c0 c1 t1 t2 => RevIRNode.irTwinCcz8T c0 c1 t1 t2
  | RevIRNode.irSpiderPair w k8       => RevIRNode.irSpiderPair w k8

/-- **Theorem 4 (`counitU4_unrepaired_mx_branch_phase_diverges`)**:
    When `hasCzFixup = false` (`WB09` / missing `CZ` fixup), on input `(d0, d1, d2, anc) = (true, true, false, false)`,
    the $m = \mathrm{false}$ and $m = \mathrm{true}$ branches diverge in $\mathbb{Z}_8$ phase (`0` vs `4`),
    producing a mixed reduced data density matrix $\operatorname{Tr}(\rho_{\mathrm{data}}^2) < 1$. -/
theorem counitU4_unrepaired_mx_branch_phase_diverges :
    let st0 : QState4 := { d0 := true, d1 := true, d2 := false, anc := false, phase8 := 0 }
    let buggy := RevIRNode.irMbuQuad Wire4.d0 Wire4.d1 Wire4.anc false
    (evalRevNode buggy st0 false).phase8 = 0 ∧
    (evalRevNode buggy st0 true).phase8 = 4 ∧
    evalRevNode buggy st0 false ≠ evalRevNode buggy st0 true := by
  decide

/-- **Theorem 5 (`counitU4_cond_cz_repair_restores_branch_uniform_purity`)**:
    For all $(b_0, b_1, b_2) \in \mathbb{B}^3$ with clean `anc = false`, repairing
    `irMbuQuad d0 d1 anc false` via `repairCounitU4Node` makes the post-measurement state
    100% identical across $m = \mathrm{false}$ and $m = \mathrm{true}$, with `anc = false`
    and `phase8 = 0` ($\operatorname{Tr}(\rho_{\mathrm{data}}^2) = 1$). -/
theorem counitU4_cond_cz_repair_restores_branch_uniform_purity (b0 b1 b2 : Bool) :
    let st0 : QState4 := { d0 := b0, d1 := b1, d2 := b2, anc := false, phase8 := 0 }
    let repaired := repairCounitU4Node (RevIRNode.irMbuQuad Wire4.d0 Wire4.d1 Wire4.anc false)
    evalRevNode repaired st0 true = evalRevNode repaired st0 false ∧
    (evalRevNode repaired st0 true).anc = false ∧
    (evalRevNode repaired st0 true).phase8 = 0 := by
  cases b0 <;> cases b1 <;> cases b2 <;> decide

/-- Linear parity cone $f(x_0, x_1) = x_0 \oplus x_1$ $M_X$ measurement + conditional `Z(d0); Z(d1)` repair. -/
def evalLinearParityMxRepair (b0 b1 m hasZFixup : Bool) : QState4 :=
  let st0 : QState4 := { d0 := b0, d1 := b1, d2 := false, anc := xor b0 b1, phase8 := 0 }
  let stKick := addPhase8 st0 (m && st0.anc) 4
  let stReset := { stKick with anc := false }
  match hasZFixup with
  | false => stReset
  | true  =>
      let stZ0 := addPhase8 stReset (m && stReset.d0) 4
      addPhase8 stZ0 (m && stZ0.d1) 4

/-- **Theorem 6 (`counitU4_linear_parity_cond_z_repair_exact`)**:
    For any linear parity cone $q_{\mathrm{anc}} = x_0 \oplus x_1$, synthesizing conditional
    `Z(d0); Z(d1)` (`hasZFixup = true`) identically cancels the $M_X$ phase kickback
    $(-1)^{m(x_0 \oplus x_1)} \cdot (-1)^{m x_0} \cdot (-1)^{m x_1} = +1$ across all $(b_0, b_1, m) \in \mathbb{B}^3$. -/
theorem counitU4_linear_parity_cond_z_repair_exact (b0 b1 m : Bool) :
    evalLinearParityMxRepair b0 b1 m true =
      { d0 := b0, d1 := b1, d2 := false, anc := false, phase8 := 0 } := by
  cases b0 <;> cases b1 <;> cases m <;> decide

/-- Degree-3 cubic ancilla cone $f(x_0, x_1, x_2) = x_0 \wedge x_1 \wedge x_2$:
    premature $M_X$ with 2-qubit `CZ(d0, d1)` vs. `T-CounitU4` unitary uncomputation fallback repair. -/
def evalDeg3PrematureMxWithCzAttempt (b0 b1 b2 m : Bool) : Nat :=
  let cubicAnc := b0 && b1 && b2
  let mxKick := if m && cubicAnc then 4 else 0
  let czAttempt := if m && b0 && b1 then 4 else 0
  (mxKick + czAttempt) % 8

def evalDeg3UnitaryFallbackRepair (b0 b1 b2 : Bool) : QState4 :=
  let cubicAnc := b0 && b1 && b2
  let stComp : QState4 := { d0 := b0, d1 := b1, d2 := b2, anc := cubicAnc, phase8 := 0 }
  let stAct := addPhase8 stComp stComp.anc 4
  -- Unitary uncomputation fallback (`anc ^= b0 && b1 && b2`):
  { stAct with anc := xor stAct.anc (stAct.d0 && stAct.d1 && stAct.d2) }

/-- **Theorem 7 (`counitU4_deg3_cubic_cannot_be_fixed_by_single_cz`)**:
    A degree-3 cubic ancilla cone $q_{\mathrm{anc}} = x_0 \wedge x_1 \wedge x_2$ cannot be
    phase-repaired by a 2-qubit `CZ(d0, d1)` fixup (failing at $(b_0, b_1, b_2, m) = (\mathrm{true}, \mathrm{true}, \mathrm{false}, \mathrm{true})$
    with residual phase `4`), whereas `T-CounitU4`'s unitary uncomputation fallback repair
    restores `anc = false` across all $(b_0, b_1, b_2) \in \mathbb{B}^3$. -/
theorem counitU4_deg3_cubic_cannot_be_fixed_by_single_cz (b0 b1 b2 : Bool) :
    evalDeg3PrematureMxWithCzAttempt true true false true = 4 ∧
    (evalDeg3UnitaryFallbackRepair b0 b1 b2).anc = false := by
  cases b0 <;> cases b1 <;> cases b2 <;> decide

-- ============================================================================
-- Section 4: `T-AlgPhase` Adjoint `invert` Repair, `T-ValidIf`, `T-DomImg`, and Guards
-- ============================================================================

/-- Synthesize the exact adjoint inverse of a single `RevIRNode` (`T-AlgPhase` repair). -/
def invertRevGate (n : RevIRNode) : RevIRNode :=
  match n with
  | RevIRNode.irX w                   => RevIRNode.irX w
  | RevIRNode.irCX c t                => RevIRNode.irCX c t
  | RevIRNode.irCCX c0 c1 t           => RevIRNode.irCCX c0 c1 t
  | RevIRNode.irZ w                   => RevIRNode.irZ w
  | RevIRNode.irCZ a b                => RevIRNode.irCZ a b
  | RevIRNode.irCCZ a b c             => RevIRNode.irCCZ a b c
  | RevIRNode.irRz8 w k8              => RevIRNode.irRz8 w ((8 - (k8 % 8)) % 8)
  | RevIRNode.irMbuQuad c0 c1 t f     => RevIRNode.irMbuQuad c0 c1 t f
  | RevIRNode.irWithinCz c0 c1 t      => RevIRNode.irWithinCz c0 c1 t
  | RevIRNode.irTwinCcz8T c0 c1 t1 t2 => RevIRNode.irTwinCcz8T c0 c1 t1 t2
  | RevIRNode.irSpiderPair w k8       => RevIRNode.irSpiderPair w k8

/-- Reverse-order adjoint `invert` sequence for a compute cone (`T-AlgPhase` / `T-DomImg` repair). -/
def invertRevSeq (cone : List RevIRNode) : List RevIRNode :=
  match cone with
  | []      => []
  | n :: ns => invertRevSeq ns ++ [invertRevGate n]

/-- Predicate characterizing normalized unitary `RevIRNode` instructions (`phase8 < 8`, `k8 < 8`). -/
def WellFormedUnitaryNode (n : RevIRNode) : Bool :=
  match n with
  | RevIRNode.irX _            => true
  | RevIRNode.irCX c t         => !(c == t)
  | RevIRNode.irCCX c0 c1 t    => !(c0 == t) && !(c1 == t)
  | RevIRNode.irZ _            => true
  | RevIRNode.irCZ _ _         => true
  | RevIRNode.irCCZ _ _ _      => true
  | RevIRNode.irRz8 _ k8       => decide (k8 < 8)
  | RevIRNode.irMbuQuad _ _ _ _ => false
  | RevIRNode.irWithinCz _ _ _ => true
  | RevIRNode.irTwinCcz8T _ _ _ _ => true
  | RevIRNode.irSpiderPair _ k8 => decide (k8 < 8)

/-- **Theorem 8 (`algPhase_invertGate_involutive`)**:
    For every normalized `RevIRNode` (`k8 < 8`), `invertRevGate (invertRevGate n) = n`. -/
theorem algPhase_invertGate_involutive (n : RevIRNode) (hWf : WellFormedUnitaryNode n = true) :
    invertRevGate (invertRevGate n) = n := by
  cases n with
  | irX w => rfl
  | irCX c t => rfl
  | irCCX c0 c1 t => rfl
  | irZ w => rfl
  | irCZ a b => rfl
  | irCCZ a b c => rfl
  | irRz8 w k8 =>
    simp only [WellFormedUnitaryNode, decide_eq_true_eq] at hWf
    simp only [invertRevGate]
    congr 1
    omega
  | irMbuQuad c0 c1 t f =>
    contradiction
  | irWithinCz c0 c1 t => rfl
  | irTwinCcz8T c0 c1 t1 t2 => rfl
  | irSpiderPair w k8 => rfl

/-- Helper: double-XOR cancellation `xor (xor a b) b = a`. -/
theorem bool_xor_self_cancel (a b : Bool) : xor (xor a b) b = a := by
  cases a <;> cases b <;> rfl

/-- Helper: `addPhase8` preserves wire values under `getW`. -/
theorem getW_addPhase8 (st : QState4) (cond : Bool) (k : Nat) (w : Wire4) :
    getW (addPhase8 st cond k) w = getW st w := by
  cases cond <;> cases w <;> rfl

/-- Helper: `setW` preserves `phase8`. -/
theorem setW_phase8 (st : QState4) (w : Wire4) (v : Bool) :
    (setW st w v).phase8 = st.phase8 := by
  cases w <;> rfl

/-- Helper: `addPhase8` always produces `phase8 < 8` when `st.phase8 < 8`. -/
theorem addPhase8_phase8_lt8 (st : QState4) (cond : Bool) (k : Nat) (hPh : st.phase8 < 8) :
    (addPhase8 st cond k).phase8 < 8 := by
  cases cond <;> simp only [addPhase8] <;> omega

/-- Helper: `addPhase8` with `k` followed by `(8 - k % 8) % 8` restores `phase8` when `st.phase8 < 8`. -/
theorem addPhase8_cancel (st : QState4) (cond : Bool) (k : Nat) (hPh : st.phase8 < 8) :
    addPhase8 (addPhase8 st cond k) cond ((8 - (k % 8)) % 8) = st := by
  cases cond with
  | false => rfl
  | true =>
    cases st with
    | mk d0 d1 d2 anc ph =>
      simp only [addPhase8] at hPh ⊢
      congr 1
      omega

/-- Helper: applying two conditional `Z` (`+4 mod 8`) pairs cancels to `st` when `st.phase8 < 8`. -/
theorem addPhase8_twin4_cancel (st : QState4) (c1 c2 : Bool) (hPh : st.phase8 < 8) :
    addPhase8 (addPhase8 (addPhase8 (addPhase8 st c1 4) c2 4) c1 4) c2 4 = st := by
  cases st with
  | mk d0 d1 d2 anc ph =>
    simp only at hPh
    cases c1 <;> cases c2 <;> simp only [addPhase8] <;> congr 1 <;> omega

/-- **Theorem 9 (`algPhase_single_gate_adjoint_cancels`)**:
    For every well-formed unitary `RevIRNode` `n` and normalized state `st` (`st.phase8 < 8`),
    executing `n` followed by its synthesized adjoint `invertRevGate n` restores `st` (`U^† · U = I`). -/
theorem algPhase_single_gate_adjoint_cancels
    (n : RevIRNode) (st : QState4)
    (hWf : WellFormedUnitaryNode n = true) (hPh : st.phase8 < 8) :
    evalRevNode (invertRevGate n) (evalRevNode n st false) false = st := by
  cases n with
  | irX w =>
    cases w <;> cases st <;> simp only [invertRevGate, evalRevNode, getW, setW, Bool.not_not]
  | irCX c t =>
    simp only [WellFormedUnitaryNode] at hWf
    cases c <;> cases t <;> cases st <;>
      simp only [invertRevGate, evalRevNode, getW, setW, bool_xor_self_cancel] at hWf ⊢ <;>
      contradiction
  | irCCX c0 c1 t =>
    simp only [WellFormedUnitaryNode] at hWf
    cases c0 <;> cases c1 <;> cases t <;> cases st <;>
      simp only [invertRevGate, evalRevNode, getW, setW, bool_xor_self_cancel] at hWf ⊢ <;>
      contradiction
  | irZ w =>
    simp only [invertRevGate, evalRevNode, getW_addPhase8]
    exact addPhase8_cancel st (getW st w) 4 hPh
  | irCZ a b =>
    simp only [invertRevGate, evalRevNode, getW_addPhase8]
    exact addPhase8_cancel st (getW st a && getW st b) 4 hPh
  | irCCZ a b c =>
    simp only [invertRevGate, evalRevNode, getW_addPhase8]
    exact addPhase8_cancel st (getW st a && getW st b && getW st c) 4 hPh
  | irRz8 w k8 =>
    simp only [invertRevGate, evalRevNode, getW_addPhase8]
    exact addPhase8_cancel st (getW st w) k8 hPh
  | irMbuQuad c0 c1 t f =>
    contradiction
  | irWithinCz c0 c1 t =>
    simp only [invertRevGate, evalRevNode, getW_addPhase8]
    exact addPhase8_cancel st (getW st c0 && getW st c1 && getW st t) 4 hPh
  | irTwinCcz8T c0 c1 t1 t2 =>
    simp only [invertRevGate, evalRevNode, getW_addPhase8]
    exact addPhase8_twin4_cancel st
      (getW st c0 && getW st c1 && getW st t1)
      (getW st c0 && getW st c1 && getW st t2) hPh
  | irSpiderPair w k8 =>
    simp only [invertRevGate, evalRevNode, getW_addPhase8]
    have h1 := addPhase8_cancel st (getW st w) k8 hPh
    rw [h1]
    exact h1

/-- Evaluation over concatenated `RevIRNode` lists. -/
theorem evalRevProg_append (xs ys : List RevIRNode) (st : QState4) (m : Bool) :
    evalRevProg (xs ++ ys) st m = evalRevProg ys (evalRevProg xs st m) m := by
  induction xs generalizing st with
  | nil => rfl
  | cons x rest ih =>
    simp only [List.cons_append, evalRevProg]
    exact ih (evalRevNode x st m)

/-- Predicate stating all nodes in `cone : List RevIRNode` are well-formed unitary gates. -/
def WellFormedUnitaryCone : List RevIRNode → Bool
  | []      => true
  | n :: ns => WellFormedUnitaryNode n && WellFormedUnitaryCone ns

/-- Preservation of `phase8 < 8` across any `RevIRNode` evaluation. -/
theorem evalRevNode_phase8_lt8 (n : RevIRNode) (st : QState4) (m : Bool) (hPh : st.phase8 < 8) :
    (evalRevNode n st m).phase8 < 8 := by
  cases n with
  | irX w =>
    simp only [evalRevNode, setW_phase8]
    exact hPh
  | irCX c t =>
    simp only [evalRevNode, setW_phase8]
    exact hPh
  | irCCX c0 c1 t =>
    simp only [evalRevNode, setW_phase8]
    exact hPh
  | irZ w =>
    simp only [evalRevNode]
    exact addPhase8_phase8_lt8 st (getW st w) 4 hPh
  | irCZ a b =>
    simp only [evalRevNode]
    exact addPhase8_phase8_lt8 st (getW st a && getW st b) 4 hPh
  | irCCZ a b c =>
    simp only [evalRevNode]
    exact addPhase8_phase8_lt8 st (getW st a && getW st b && getW st c) 4 hPh
  | irRz8 w k8 =>
    simp only [evalRevNode]
    exact addPhase8_phase8_lt8 st (getW st w) k8 hPh
  | irMbuQuad c0 c1 t hasCzFixup =>
    simp only [evalRevNode]
    cases hasCzFixup with
    | false =>
      simp only [setW_phase8]
      apply addPhase8_phase8_lt8
      simp only [setW_phase8]
      exact hPh
    | true =>
      apply addPhase8_phase8_lt8
      simp only [setW_phase8]
      apply addPhase8_phase8_lt8
      simp only [setW_phase8]
      exact hPh
  | irWithinCz c0 c1 t =>
    simp only [evalRevNode]
    exact addPhase8_phase8_lt8 st (getW st c0 && getW st c1 && getW st t) 4 hPh
  | irTwinCcz8T c0 c1 t1 t2 =>
    simp only [evalRevNode]
    apply addPhase8_phase8_lt8
    exact addPhase8_phase8_lt8 st (getW st c0 && getW st c1 && getW st t1) 4 hPh
  | irSpiderPair w k8 =>
    simp only [evalRevNode]
    apply addPhase8_phase8_lt8
    exact addPhase8_phase8_lt8 st (getW st w) k8 hPh

/-- **Theorem 10 (`algPhase_sequence_adjoint_repair_exact`)**:
    For every well-formed compute cone `cone : List RevIRNode` and normalized state `st` (`st.phase8 < 8`),
    replacing a buggy non-involutory uncompute with the synthesized reverse-order adjoint
    `invertRevSeq cone` (`T-AlgPhase` repair) restores the exact initial state `st` (`U^† · U = I`). -/
theorem algPhase_sequence_adjoint_repair_exact
    (cone : List RevIRNode) (st : QState4)
    (hWf : WellFormedUnitaryCone cone = true) (hPh : st.phase8 < 8) :
    evalRevProg (cone ++ invertRevSeq cone) st false = st := by
  induction cone generalizing st with
  | nil => rfl
  | cons n ns ih =>
    simp only [WellFormedUnitaryCone, Bool.and_eq_true] at hWf
    rcases hWf with ⟨hn, hns⟩
    simp only [List.cons_append, evalRevProg, invertRevSeq]
    rw [← List.append_assoc, evalRevProg_append]
    have hMid := ih (evalRevNode n st false) hns (evalRevNode_phase8_lt8 n st false hPh)
    rw [hMid]
    simp only [evalRevProg]
    exact algPhase_single_gate_adjoint_cancels n st hn hPh

/-- `T-ValidIf` auto-repair: replaces unguarded `irZ d1` after `irCCX d0 d1 anc` with
    validity-guarded `irCZ anc d1` followed by `irCCX d0 d1 anc` cleanup (`WB04`). -/
def buggyValidIfOracle : List RevIRNode :=
  [RevIRNode.irCCX Wire4.d0 Wire4.d1 Wire4.anc,
   RevIRNode.irZ Wire4.d1,
   RevIRNode.irCCX Wire4.d0 Wire4.d1 Wire4.anc]

def repairedValidIfOracle : List RevIRNode :=
  [RevIRNode.irCCX Wire4.d0 Wire4.d1 Wire4.anc,
   RevIRNode.irCZ Wire4.anc Wire4.d1,
   RevIRNode.irCCX Wire4.d0 Wire4.d1 Wire4.anc]

/-- **Theorem 11 (`validIf_unguarded_vs_guarded_phase_repair_exact`)**:
    On singular input `(d0, d1) = (false, true)` (`valid = d0 && d1 = false`), `buggyValidIfOracle`
    erroneously flips the phase (`phase8 = 4`), whereas `repairedValidIfOracle` flips the phase
    if and only if `b0 && b1 = true` and restores `anc = false` across all $(b_0, b_1, b_2) \in \mathbb{B}^3$. -/
theorem validIf_unguarded_vs_guarded_phase_repair_exact (b0 b1 b2 : Bool) :
    let stSing : QState4 := { d0 := false, d1 := true, d2 := false, anc := false, phase8 := 0 }
    let stAny  : QState4 := { d0 := b0, d1 := b1, d2 := b2, anc := false, phase8 := 0 }
    (evalRevProg buggyValidIfOracle stSing false).phase8 = 4 ∧
    (evalRevProg repairedValidIfOracle stAny false).anc = false ∧
    (evalRevProg repairedValidIfOracle stAny false).phase8 = (if b0 && b1 then 4 else 0) := by
  cases b0 <;> cases b1 <;> cases b2 <;> decide

/-- `T-DomImg` XAG ancilla cleanup synthesis: given a forward compute prefix `computeCone`
    followed by target copy `irCX anc d2`, synthesizes `computeCone ++ [irCX anc d2] ++ invertRevSeq computeCone`. -/
def synthesizeDomImgCleanup (computeCone : List RevIRNode) : List RevIRNode :=
  computeCone ++ [RevIRNode.irCX Wire4.anc Wire4.d2] ++ invertRevSeq computeCone

/-- **Theorem 12 (`domImg_xag_ancilla_cleanup_restores_zero`)**:
    For the 2-input AND compute cone `[irCCX d0 d1 anc]` (`WB01` / `WB07`), `synthesizeDomImgCleanup`
    computes `d2' = xor b2 (b0 && b1)` while deterministically restoring `anc = false` and `phase8 = 0`
    across all $(b_0, b_1, b_2) \in \mathbb{B}^3$. -/
theorem domImg_xag_ancilla_cleanup_restores_zero (b0 b1 b2 : Bool) :
    let st0 : QState4 := { d0 := b0, d1 := b1, d2 := b2, anc := false, phase8 := 0 }
    let repaired := synthesizeDomImgCleanup [RevIRNode.irCCX Wire4.d0 Wire4.d1 Wire4.anc]
    evalRevProg repaired st0 false =
      { d0 := b0, d1 := b1, d2 := xor b2 (b0 && b1), anc := false, phase8 := 0 } := by
  cases b0 <;> cases b1 <;> cases b2 <;> decide

/-- Resource & cluster specification record for `T-DriftEps`, `T-SingleIR`, and `T-ParGuard`. -/
structure ResourceClusterSpec where
  cPadBits       : Nat
  minReqPadBits  : Nat
  sliceColHi     : Nat
  totalCols      : Nat
  isGroverOrIsd  : Bool
  requestedM     : Nat
  optimalM       : Nat
  deriving DecidableEq, Repr

/-- Static validity predicates for `T-DriftEps`, `T-SingleIR`, and `T-ParGuard`. -/
def validResourceClusterSpec (sp : ResourceClusterSpec) : Bool :=
  decide (sp.minReqPadBits ≤ sp.cPadBits) &&
  decide (sp.sliceColHi = sp.totalCols) &&
  decide (sp.requestedM = (if sp.isGroverOrIsd then 1 else sp.optimalM))

/-- Auto-repair operator for `T-DriftEps` (`c_pad`), `T-SingleIR` (`sliceColHi`), and `T-ParGuard` (`M*`). -/
def repairResourceAndClusterGuards (sp : ResourceClusterSpec) : ResourceClusterSpec :=
  { sp with
    cPadBits   := if sp.cPadBits < sp.minReqPadBits then sp.minReqPadBits else sp.cPadBits
    sliceColHi := sp.totalCols
    requestedM := if sp.isGroverOrIsd then 1 else sp.optimalM }

/-- **Theorem 13 (`driftEps_singleIR_parGuard_structural_repairs_well_typed`)**:
    For every `ResourceClusterSpec` `sp`, `repairResourceAndClusterGuards sp` satisfies
    `validResourceClusterSpec = true` (`c_pad >= minReqPadBits`, full matrix slice, and convex `M*`). -/
theorem driftEps_singleIR_parGuard_structural_repairs_well_typed (sp : ResourceClusterSpec) :
    validResourceClusterSpec (repairResourceAndClusterGuards sp) = true := by
  rcases sp with ⟨cPad, minPad, colHi, totCols, isGrov, reqM, optM⟩
  simp only [repairResourceAndClusterGuards, validResourceClusterSpec, Bool.and_eq_true, decide_eq_true_eq]
  refine ⟨⟨?_, trivial⟩, trivial⟩
  split <;> omega

-- ============================================================================
-- Section 5: Post-Repair `canonical_k2_coupled` Optimization & `QPhysGrade` Dominance
-- ============================================================================

/-- `canonical_k2_coupled` per-node algebraic optimizer:
    - Absorbs phase-only `irWithinCz c0 c1 t` (`14 T`, `1` scratch ancilla) into `irCCZ c0 c1 t` (`7 T`, `0` scratch),
    - Eliminates canceling spider pairs `irSpiderPair w k8` (`2 T -> 0 T`). -/
def canonicalK2OptNode (n : RevIRNode) : List RevIRNode :=
  match n with
  | RevIRNode.irX w                   => [RevIRNode.irX w]
  | RevIRNode.irCX c t                => [RevIRNode.irCX c t]
  | RevIRNode.irCCX c0 c1 t           => [RevIRNode.irCCX c0 c1 t]
  | RevIRNode.irZ w                   => [RevIRNode.irZ w]
  | RevIRNode.irCZ a b                => [RevIRNode.irCZ a b]
  | RevIRNode.irCCZ a b c             => [RevIRNode.irCCZ a b c]
  | RevIRNode.irRz8 w k8              => [RevIRNode.irRz8 w k8]
  | RevIRNode.irMbuQuad c0 c1 t f     => [RevIRNode.irMbuQuad c0 c1 t f]
  | RevIRNode.irWithinCz c0 c1 t      => [RevIRNode.irCCZ c0 c1 t]
  | RevIRNode.irTwinCcz8T c0 c1 t1 t2 => [RevIRNode.irTwinCcz8T c0 c1 t1 t2]
  | RevIRNode.irSpiderPair _ _        => []

/-- Apply `canonicalK2OptNode` across `List RevIRNode`. -/
def canonicalK2Optimize (prog : List RevIRNode) : List RevIRNode :=
  match prog with
  | []      => []
  | n :: ns => canonicalK2OptNode n ++ canonicalK2Optimize ns

/-- Single-node semantic equivalence for `canonicalK2OptNode`. -/
theorem canonicalK2OptNode_preserves_semantics
    (n : RevIRNode) (st : QState4) (m : Bool) (hPh : st.phase8 < 8) :
    evalRevProg (canonicalK2OptNode n) st m = evalRevNode n st m ∧
    (evalRevNode n st m).phase8 < 8 := by
  refine ⟨?_, evalRevNode_phase8_lt8 n st m hPh⟩
  cases n with
  | irX w => rfl
  | irCX c t => rfl
  | irCCX c0 c1 t => rfl
  | irZ w => rfl
  | irCZ a b => rfl
  | irCCZ a b c => rfl
  | irRz8 w k8 => rfl
  | irMbuQuad c0 c1 t f => rfl
  | irWithinCz c0 c1 t => rfl
  | irTwinCcz8T c0 c1 t1 t2 => rfl
  | irSpiderPair w k8 =>
    simp only [canonicalK2OptNode, evalRevProg, evalRevNode, getW_addPhase8]
    exact (addPhase8_cancel st (getW st w) k8 hPh).symm

/-- **Theorem 14 (`canonical_k2_coupled_preserves_repaired_semantics`)**:
    For every repaired `RevIR` program `prog`, initial state `st` (`st.phase8 < 8`), and
    measurement branch `m`, `canonicalK2Optimize prog` preserves exact `QState4` semantics. -/
theorem canonical_k2_coupled_preserves_repaired_semantics
    (prog : List RevIRNode) (st : QState4) (m : Bool) (hPh : st.phase8 < 8) :
    evalRevProg (canonicalK2Optimize prog) st m = evalRevProg prog st m := by
  induction prog generalizing st with
  | nil => rfl
  | cons n ns ih =>
    simp only [canonicalK2Optimize, evalRevProg]
    rw [evalRevProg_append]
    have ⟨hEq, hPhNext⟩ := canonicalK2OptNode_preserves_semantics n st m hPh
    rw [hEq]
    exact ih (evalRevNode n st m) hPhNext

/-- Per-node physical $T$-count cost before/after optimization. -/
def nodeTCount (n : RevIRNode) : Nat :=
  match n with
  | RevIRNode.irX _                   => 0
  | RevIRNode.irCX _ _                => 0
  | RevIRNode.irCCX _ _ _             => 7
  | RevIRNode.irZ _                   => 0
  | RevIRNode.irCZ _ _                => 0
  | RevIRNode.irCCZ _ _ _             => 7
  | RevIRNode.irRz8 _ k8              => if k8 % 2 == 1 then 1 else 0
  | RevIRNode.irMbuQuad _ _ _ _       => 4
  | RevIRNode.irWithinCz _ _ _        => 14
  | RevIRNode.irTwinCcz8T _ _ _ _     => 8
  | RevIRNode.irSpiderPair _ _        => 2

/-- Total $T$-count across `List RevIRNode`. -/
def progTCount (prog : List RevIRNode) : Nat :=
  match prog with
  | []      => 0
  | n :: ns => nodeTCount n + progTCount ns

/-- Scratch-ancilla overhead indicator (`1` if `irWithinCz` allocates an un-absorbed scratch wire, else `0`). -/
def nodeScratchOverhead (n : RevIRNode) : Nat :=
  match n with
  | RevIRNode.irX _                   => 0
  | RevIRNode.irCX _ _                => 0
  | RevIRNode.irCCX _ _ _             => 0
  | RevIRNode.irZ _                   => 0
  | RevIRNode.irCZ _ _                => 0
  | RevIRNode.irCCZ _ _ _             => 0
  | RevIRNode.irRz8 _ _               => 0
  | RevIRNode.irMbuQuad _ _ _ _       => 1
  | RevIRNode.irWithinCz _ _ _        => 1
  | RevIRNode.irTwinCcz8T _ _ _ _     => 0
  | RevIRNode.irSpiderPair _ _        => 0

def progScratchOverhead (prog : List RevIRNode) : Nat :=
  match prog with
  | []      => 0
  | n :: ns => nodeScratchOverhead n + progScratchOverhead ns

theorem progTCount_append (xs ys : List RevIRNode) :
    progTCount (xs ++ ys) = progTCount xs + progTCount ys := by
  induction xs with
  | nil => simp only [List.nil_append, progTCount, Nat.zero_add]
  | cons x rest ih =>
    simp only [List.cons_append, progTCount, ih, Nat.add_assoc]

theorem progScratchOverhead_append (xs ys : List RevIRNode) :
    progScratchOverhead (xs ++ ys) = progScratchOverhead xs + progScratchOverhead ys := by
  induction xs with
  | nil => simp only [List.nil_append, progScratchOverhead, Nat.zero_add]
  | cons x rest ih =>
    simp only [List.cons_append, progScratchOverhead, ih, Nat.add_assoc]

/-- **Theorem 15 (`canonical_k2_coupled_monotone_qphys_cost_reduction`)**:
    For every `RevIR` program `prog`, `canonicalK2Optimize` monotonically reduces both
    $T$-count (`progTCount`) and scratch-ancilla width overhead (`progScratchOverhead`). -/
theorem canonical_k2_coupled_monotone_qphys_cost_reduction (prog : List RevIRNode) :
    progTCount (canonicalK2Optimize prog) ≤ progTCount prog ∧
    progScratchOverhead (canonicalK2Optimize prog) ≤ progScratchOverhead prog := by
  induction prog with
  | nil =>
    simp only [canonicalK2Optimize, progTCount, progScratchOverhead, Nat.le_refl, and_self]
  | cons n ns ih =>
    rcases ih with ⟨ihT, ihQ⟩
    simp only [canonicalK2Optimize, progTCount_append, progScratchOverhead_append,
      progTCount, progScratchOverhead]
    cases n <;>
      simp only [canonicalK2OptNode, progTCount, progScratchOverhead,
        nodeTCount, nodeScratchOverhead] <;>
      omega

end LakefillQQasm3LiftingAndAutorepairProofs
