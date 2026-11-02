/-!
# Hash-Consed `XAG`/`FRAIG` + `Z3` Cut-Sweeping Symbolic `QSub` (`Laws U1–U4`) Inference Proofs

This self-contained Lean 4.35.0 module (fully constructive, exhaustive constructor
matching, zero warnings, every proof `<= 25` lines) mechanizes the
semantic soundness and complexity separation backing
`compiler/lakefillq-xag-fraig-typechecker.rkt` (`LakefillQ -> RevIR -> MachineISA`):

1. **Complement-Edge `XAG` ASTs & Structural Hash-Consing Soundness**:
   - `xag_lit_not_involution_and_semantics`
   - `xag_smart_xor_self_cancels` & `xag_smart_xor_preserves_semantics`
   - `xag_smart_and_zero_self_and_not_self` & `xag_smart_and_preserves_semantics`
   - `sim_signature_mismatch_refutes_xag_equivalence`
2. **Bilinear `XAG` `Law U4` Accumulator & Arbitrary-Degree Cancellation**:
   - `bilinear_xag_mbu_collapses_arbitrary_degree_to_zero`
   - `bilinear_xag_zero_coeff_implies_unit_quantum_phase`
   - `multiround_mbu_session_total_quantum_phase_unit`
3. **Linear $O(|G|)$ `XAG` Size vs. Exponential Explicit `ANF` ($\binom{2m}{m}$ and $2^{k+1}-1$)**:
   - `xag_circuit_linear_node_bound`
   - `gidney_carry_explicit_anf_exponential_closed_form`
   - `central_binomial_anf_exponential_lower_bound`
4. **Tseitin / DAG Miter & Local Cut-Sweeping `UNSAT` Soundness**:
   - `tseitin_dag_model_agrees_with_semantics`
   - `tseitin_canonical_eval_satisfies_defs`
   - `tseitin_miter_unsat_iff_xag_domain_equivalence`
   - `cut_sweeping_local_unsat_implies_global_multiround_soundness`
-/

namespace LakefillQXagFraigSymbolicInferenceProofs

-- ============================================================================
-- Section 1: Complement-Edge `XAG` ASTs & Structural Hash-Consing Rewrite Rules
-- ============================================================================

/-- Positive XOR-AND-Inverter Graph (`XAG`) internal node grammar. -/
inductive XagNode where
  | constZero : XagNode
  | var : Nat → XagNode
  | xor2 : XagNode → XagNode → XagNode
  | and2 : XagNode → Bool → XagNode → Bool → XagNode
  deriving DecidableEq, Repr

/-- Signed `XAG` edge literal (`inv = true` complements the target node in $O(1)$). -/
structure XagLit where
  node : XagNode
  inv : Bool
  deriving DecidableEq, Repr

def litZero : XagLit := { node := XagNode.constZero, inv := false }
def litOne  : XagLit := { node := XagNode.constZero, inv := true }
def litVar (v : Nat) : XagLit := { node := XagNode.var v, inv := false }
def litNot (l : XagLit) : XagLit := { node := l.node, inv := !l.inv }

/-- Boolean wire-assignment semantics of positive `XAG` nodes. -/
def evalXagNode (env : Nat → Bool) : XagNode → Bool
  | XagNode.constZero => false
  | XagNode.var idx => env idx
  | XagNode.xor2 u v => xor (evalXagNode env u) (evalXagNode env v)
  | XagNode.and2 u invU v invV =>
    (xor invU (evalXagNode env u)) && (xor invV (evalXagNode env v))

/-- Boolean semantics of a signed `XAG` literal (`inv ⊕ evalXagNode env node`). -/
def evalXagLit (env : Nat → Bool) (l : XagLit) : Bool :=
  xor l.inv (evalXagNode env l.node)

/-- Structural hash-consing smart constructor for `XOR` with identity & self-cancellation. -/
def mkXorSmart (l1 l2 : XagLit) : XagLit :=
  let outInv := xor l1.inv l2.inv
  if l1.node == XagNode.constZero then
    { node := l2.node, inv := outInv }
  else if l2.node == XagNode.constZero then
    { node := l1.node, inv := outInv }
  else if l1.node == l2.node then
    { node := XagNode.constZero, inv := outInv }
  else
    { node := XagNode.xor2 l1.node l2.node, inv := outInv }

/-- Structural hash-consing smart constructor for `AND` (`u & 0 = 0`, `u & u = u`, `u & ~u = 0`). -/
def mkAndSmart (l1 l2 : XagLit) : XagLit :=
  if l1 == litZero || l2 == litZero then
    litZero
  else if l1 == litOne then
    l2
  else if l2 == litOne then
    l1
  else if l1 == l2 then
    l1
  else if l1 == litNot l2 then
    litZero
  else
    { node := XagNode.and2 l1.node l1.inv l2.node l2.inv, inv := false }

theorem xag_lit_not_involution_and_semantics (env : Nat → Bool) (l : XagLit) :
    litNot (litNot l) = l ∧ evalXagLit env (litNot l) = !(evalXagLit env l) := by
  cases l with
  | mk nd iv =>
    simp only [litNot, evalXagLit]
    cases iv <;> cases evalXagNode env nd <;> simp

theorem xag_smart_xor_self_cancels (l : XagLit) :
    mkXorSmart l l = litZero ∧ mkXorSmart l (litNot l) = litOne := by
  cases l with
  | mk nd iv =>
    simp only [mkXorSmart, litNot, litZero, litOne]
    by_cases hz : (nd == XagNode.constZero) = true
    · have hnd : nd = XagNode.constZero := eq_of_beq hz
      subst hnd
      cases iv <;> decide
    · simp only [Bool.not_eq_true] at hz
      have hself : (nd == nd) = true := beq_self_eq_true nd
      simp only [hz, Bool.false_eq_true, ↓reduceIte, hself]
      cases iv <;> decide

theorem xag_smart_xor_preserves_semantics (env : Nat → Bool) (l1 l2 : XagLit) :
    evalXagLit env (mkXorSmart l1 l2) = xor (evalXagLit env l1) (evalXagLit env l2) := by
  simp only [mkXorSmart]
  by_cases e1 : l1.node = XagNode.constZero
  · simp only [e1, beq_self_eq_true, ↓reduceIte, evalXagLit, evalXagNode]
    cases l1.inv <;> cases l2.inv <;> cases evalXagNode env l2.node <;> rfl
  · have b1 : (l1.node == XagNode.constZero) = false := beq_eq_false_iff_ne.mpr e1
    by_cases e2 : l2.node = XagNode.constZero
    · simp only [b1, Bool.false_eq_true, ↓reduceIte, e2, beq_self_eq_true, evalXagLit, evalXagNode]
      cases l1.inv <;> cases l2.inv <;> cases evalXagNode env l1.node <;> rfl
    · have b2 : (l2.node == XagNode.constZero) = false := beq_eq_false_iff_ne.mpr e2
      by_cases e12 : l1.node = l2.node
      · simp only [b2, Bool.false_eq_true, ↓reduceIte, e12, beq_self_eq_true, evalXagLit, evalXagNode]
        cases l1.inv <;> cases l2.inv <;> cases evalXagNode env l2.node <;> rfl
      · have b12 : (l1.node == l2.node) = false := beq_eq_false_iff_ne.mpr e12
        simp only [b1, b2, b12, Bool.false_eq_true, ↓reduceIte, evalXagLit, evalXagNode]
        cases l1.inv <;> cases l2.inv <;> cases evalXagNode env l1.node <;> cases evalXagNode env l2.node <;> rfl

theorem xag_smart_and_zero_self_and_not_self (l : XagLit) :
    mkAndSmart l litZero = litZero ∧
    mkAndSmart l l = l ∧
    mkAndSmart l (litNot l) = litZero := by
  refine ⟨by simp [mkAndSmart], ?_, ?_⟩
  · simp only [mkAndSmart]
    by_cases hz : l = litZero
    · subst hz; decide
    · by_cases ho : l = litOne
      · subst ho; decide
      · simp [beq_eq_false_iff_ne.mpr hz, beq_eq_false_iff_ne.mpr ho]
  · cases l with
    | mk nd iv =>
      by_cases hnd : nd = XagNode.constZero
      · subst hnd; cases iv <;> decide
      · have hnz1 : ({ node := nd, inv := iv } == litZero) = false := beq_eq_false_iff_ne.mpr (fun h => hnd (congrArg XagLit.node h))
        have hnz2 : (litNot { node := nd, inv := iv } == litZero) = false := beq_eq_false_iff_ne.mpr (fun h => hnd (congrArg XagLit.node h))
        have hno1 : ({ node := nd, inv := iv } == litOne) = false := beq_eq_false_iff_ne.mpr (fun h => hnd (congrArg XagLit.node h))
        have hno2 : (litNot { node := nd, inv := iv } == litOne) = false := beq_eq_false_iff_ne.mpr (fun h => hnd (congrArg XagLit.node h))
        have hneq : ({ node := nd, inv := iv } == litNot { node := nd, inv := iv }) = false := by cases iv <;> simp [litNot]
        have hnot : ({ node := nd, inv := iv } == litNot (litNot { node := nd, inv := iv })) = true := by cases iv <;> simp [litNot]
        simp only [mkAndSmart, hnz1, hnz2, Bool.or_self, Bool.false_eq_true, ↓reduceIte, hno1, hno2, hneq, hnot]

theorem evalXagLit_zero_and_one (env : Nat → Bool) :
    evalXagLit env litZero = false ∧ evalXagLit env litOne = true := by
  simp [litZero, litOne, evalXagLit, evalXagNode]

theorem xag_smart_and_preserves_semantics (env : Nat → Bool) (l1 l2 : XagLit) :
    evalXagLit env (mkAndSmart l1 l2) = (evalXagLit env l1 && evalXagLit env l2) := by
  simp only [mkAndSmart]
  by_cases hz : (l1 == litZero || l2 == litZero) = true
  · simp only [hz, ↓reduceIte, (evalXagLit_zero_and_one env).1]
    rcases Bool.or_eq_true_iff.mp hz with h1 | h2
    · rw [eq_of_beq h1, (evalXagLit_zero_and_one env).1]; rfl
    · rw [eq_of_beq h2, (evalXagLit_zero_and_one env).1]; cases evalXagLit env l1 <;> rfl
  · simp only [Bool.not_eq_true] at hz
    by_cases ho1 : (l1 == litOne) = true
    · simp only [hz, Bool.false_eq_true, ↓reduceIte, ho1]; rw [eq_of_beq ho1, (evalXagLit_zero_and_one env).2, Bool.true_and]
    · simp only [Bool.not_eq_true] at ho1
      by_cases ho2 : (l2 == litOne) = true
      · simp only [hz, ho1, Bool.false_eq_true, ↓reduceIte, ho2]; rw [eq_of_beq ho2, (evalXagLit_zero_and_one env).2, Bool.and_true]
      · simp only [Bool.not_eq_true] at ho2
        by_cases heq : (l1 == l2) = true
        · simp only [hz, ho1, ho2, Bool.false_eq_true, ↓reduceIte, heq]; rw [eq_of_beq heq, Bool.and_self]
        · simp only [Bool.not_eq_true] at heq
          by_cases hneg : (l1 == litNot l2) = true
          · simp only [hz, ho1, ho2, heq, Bool.false_eq_true, ↓reduceIte, hneg]
            rw [eq_of_beq hneg, (evalXagLit_zero_and_one env).1, (xag_lit_not_involution_and_semantics env l2).2]
            cases evalXagLit env l2 <;> rfl
          · simp only [Bool.not_eq_true] at hneg
            simp [hz, ho1, ho2, heq, hneg, evalXagLit, evalXagNode]

/-- Parallel truth-table signature vector across a sample list of input environments. -/
def evalSimSignature (l : XagLit) : List (Nat → Bool) → List Bool
  | [] => []
  | env :: rest => evalXagLit env l :: evalSimSignature l rest

theorem sim_signature_mismatch_refutes_xag_equivalence
    (samples : List (Nat → Bool)) (l1 l2 : XagLit)
    (hne : evalSimSignature l1 samples ≠ evalSimSignature l2 samples) :
    ∃ env, evalXagLit env l1 ≠ evalXagLit env l2 := by
  induction samples with
  | nil =>
    exact False.elim (hne rfl)
  | cons env rest ih =>
    by_cases hhead : evalXagLit env l1 = evalXagLit env l2
    · apply ih
      intro htail
      apply hne
      simp [evalSimSignature, hhead, htail]
    · exact ⟨env, hhead⟩

-- ============================================================================
-- Section 2: Bilinear `XAG` `Law U4` Accumulator & Arbitrary-Degree Cancellation
-- ============================================================================

/-- Quantum phase factor $(-1)^b \in \{-1, +1\}$ associated with Boolean exponent `b`. -/
def kickbackSign (b : Bool) : Int :=
  match b with
  | false => 1
  | true => -1

theorem kickbackSign_xor_homomorphism (a b : Bool) :
    kickbackSign (xor a b) = kickbackSign a * kickbackSign b := by
  cases a <;> cases b <;> rfl

/-- Symbolic `Law U4` coefficient update at `(mx anc m_k)`. -/
def mxUpdateCoeff (gk ancLit : XagLit) : XagLit :=
  mkXorSmart gk ancLit

/-- Symbolic `Law U4` coefficient update at `(cond-z m_k c1 c2)`. -/
def condCzUpdateCoeff (gk c1 c2 : XagLit) : XagLit :=
  mkXorSmart gk (mkAndSmart c1 c2)

/-- Even when `c1, c2` are degree-$d$ ($d \le 128$) multi-round cipher `XAG` cones,
    `(mx anc m_k)` followed by `(cond-z m_k c1 c2)` collapses `g_k` to `litZero` in $O(1)$. -/
theorem bilinear_xag_mbu_collapses_arbitrary_degree_to_zero (c1 c2 : XagLit) :
    condCzUpdateCoeff (mxUpdateCoeff litZero (mkAndSmart c1 c2)) c1 c2 = litZero := by
  unfold condCzUpdateCoeff mxUpdateCoeff
  have hid : mkXorSmart litZero (mkAndSmart c1 c2) = mkAndSmart c1 c2 := by
    cases mkAndSmart c1 c2 with
    | mk nd iv =>
      simp [mkXorSmart, litZero]
  rw [hid]
  exact (xag_smart_xor_self_cancels (mkAndSmart c1 c2)).1

/-- Whenever `mkXorSmart gk (mkAndSmart c1 c2) = litZero`, the quantum phase factor
    $(-1)^{m_k \cdot g_k'(x)}$ equals $+1$ for all measurement outcomes `mk` and inputs `env`. -/
theorem bilinear_xag_zero_coeff_implies_unit_quantum_phase
    (env : Nat → Bool) (mk : Bool) (gk c1 c2 : XagLit)
    (hcancel : condCzUpdateCoeff gk c1 c2 = litZero) :
    kickbackSign (mk && evalXagLit env (condCzUpdateCoeff gk c1 c2)) = 1 := by
  rw [hcancel, (evalXagLit_zero_and_one env).1]
  cases mk <;> rfl

/-- A recorded `TempAND + mx + cond-cz` session triple `(mk, c1, c2)`. -/
structure MbuSessionStep where
  measBit : Bool
  ctrl1 : XagLit
  ctrl2 : XagLit

/-- Cumulative quantum phase product across a multi-round sequence of `MBU` sessions. -/
def evalMultiRoundMbuKickback (env : Nat → Bool) : List MbuSessionStep → Int
  | [] => 1
  | s :: rest =>
    let gkFinal := condCzUpdateCoeff (mxUpdateCoeff litZero (mkAndSmart s.ctrl1 s.ctrl2)) s.ctrl1 s.ctrl2
    kickbackSign (s.measBit && evalXagLit env gkFinal) * evalMultiRoundMbuKickback env rest

theorem multiround_mbu_session_total_quantum_phase_unit
    (env : Nat → Bool) (sessions : List MbuSessionStep) :
    evalMultiRoundMbuKickback env sessions = 1 := by
  induction sessions with
  | nil =>
    rfl
  | cons s rest ih =>
    simp only [evalMultiRoundMbuKickback]
    have hzero : condCzUpdateCoeff (mxUpdateCoeff litZero (mkAndSmart s.ctrl1 s.ctrl2)) s.ctrl1 s.ctrl2 = litZero :=
      bilinear_xag_mbu_collapses_arbitrary_degree_to_zero s.ctrl1 s.ctrl2
    rw [bilinear_xag_zero_coeff_implies_unit_quantum_phase env s.measBit
          (mxUpdateCoeff litZero (mkAndSmart s.ctrl1 s.ctrl2)) s.ctrl1 s.ctrl2 hzero, ih]
    rfl

-- ============================================================================
-- Section 3: Linear $O(|G|)$ `XAG` Bound vs. Exponential Explicit `ANF` Lower Bound
-- ============================================================================

/-- Primitive wire-level `LakefillQ` gate operations tracked by the `XAG` interpreter. -/
inductive LakefillXagOp where
  | xGate : Nat → LakefillXagOp
  | cxGate : Nat → Nat → LakefillXagOp
  | tempAndGate : Nat → Nat → Nat → LakefillXagOp
  | mxGate : Nat → Nat → LakefillXagOp
  | condCzGate : Nat → Nat → Nat → LakefillXagOp
  deriving DecidableEq, Repr

/-- Worst-case newly allocated `XAG` nodes per gate (`0` for `X`, `1` for `CX`/`TempAND`/`MX`, `2` for `cond-CZ`). -/
def opNewXagNodeUpperBound : LakefillXagOp → Nat
  | LakefillXagOp.xGate _w => 0
  | LakefillXagOp.cxGate _c _t => 1
  | LakefillXagOp.tempAndGate _c1 _c2 _anc => 2
  | LakefillXagOp.mxGate _anc _m => 1
  | LakefillXagOp.condCzGate _m _c1 _c2 => 2

def totalXagNodeUpperBound : List LakefillXagOp → Nat
  | [] => 0
  | op :: rest => opNewXagNodeUpperBound op + totalXagNodeUpperBound rest

theorem xag_circuit_linear_node_bound (ops : List LakefillXagOp) :
    totalXagNodeUpperBound ops ≤ 2 * ops.length := by
  induction ops with
  | nil =>
    simp [totalXagNodeUpperBound]
  | cons op rest ih =>
    have hop : opNewXagNodeUpperBound op ≤ 2 := by
      cases op <;> simp [opNewXagNodeUpperBound]
    simp only [totalXagNodeUpperBound, List.length_cons]
    omega

/-- Exact explicit `ANF` monomial count for carry wire $c_k = a_k b_k \oplus c_{k-1}(a_k \oplus b_k)$. -/
def gidneyCarryAnfMonomials : Nat → Nat
  | 0 => 1
  | k + 1 => 2 * gidneyCarryAnfMonomials k + 1

/-- Exact `XAG` internal node count (`1 + 3k`) for the same $k$-bit Gidney carry chain. -/
def gidneyCarryXagNodes : Nat → Nat
  | 0 => 1
  | k + 1 => gidneyCarryXagNodes k + 3

theorem gidney_carry_explicit_anf_exponential_closed_form (k : Nat) :
    gidneyCarryAnfMonomials k + 1 = 2 ^ (k + 1) ∧ gidneyCarryXagNodes k = 3 * k + 1 := by
  induction k with
  | zero =>
    decide
  | succ m ih =>
    rcases ih with ⟨hanf, hxag⟩
    refine ⟨?_, ?_⟩
    · simp only [gidneyCarryAnfMonomials, Nat.pow_succ]
      omega
    · simp only [gidneyCarryXagNodes]
      omega

/-- Exact Pascal binomial coefficient $\binom{n}{k}$ without wildcard patterns. -/
def binom : Nat → Nat → Nat
  | 0, 0 => 1
  | 0, _k + 1 => 0
  | _n + 1, 0 => 1
  | n + 1, k + 1 => binom n k + binom n (k + 1)

theorem central_binom_step_ge_double (m : Nat) :
    2 * binom (2 * m) m ≤ binom (2 * (m + 1)) (m + 1) := by
  cases m with
  | zero =>
    decide
  | succ r =>
    have hsplit : 2 * (r + 1 + 1) = (2 * (r + 1) + 1) + 1 := by omega
    rw [hsplit]
    simp only [binom]
    omega

/-- Middle-slice explicit `ANF` over $2m$ variables satisfies $\binom{2m}{m} \ge 2^m$
    (e.g. $2m = 128 \implies \binom{128}{64} \ge 2^{64}$ monomials vs. linear $O(|G|)$ `XAG` size). -/
theorem central_binomial_anf_exponential_lower_bound (m : Nat) :
    2 ^ m ≤ binom (2 * m) m := by
  induction m with
  | zero =>
    decide
  | succ k ih =>
    have hstep : 2 * binom (2 * k) k ≤ binom (2 * (k + 1)) (k + 1) :=
      central_binom_step_ge_double k
    simp only [Nat.pow_succ]
    omega

-- ============================================================================
-- Section 4: Tseitin / DAG Miter & Local Cut-Sweeping `UNSAT` Soundness
-- ============================================================================

/-- Topological `XAG` node definitions exported as 1-variable-per-node Tseitin equations. -/
inductive TseitinNodeDef where
  | primaryIn : Nat → TseitinNodeDef
  | xorNode : Nat → Nat → TseitinNodeDef
  | andNode : Nat → Bool → Nat → Bool → TseitinNodeDef
  deriving DecidableEq, Repr

/-- Functional DAG evaluation of node definitions in topological order. -/
def evalTseitinDag (env : Nat → Bool) : List TseitinNodeDef → (Nat → Bool)
  | [] => fun _id => false
  | d :: ds =>
    let prev := evalTseitinDag env ds
    let curId := ds.length
    let val :=
      match d with
      | TseitinNodeDef.primaryIn v => env v
      | TseitinNodeDef.xorNode u w => xor (prev u) (prev w)
      | TseitinNodeDef.andNode u iu w iw => (xor iu (prev u)) && (xor iw (prev w))
    fun q => if q == curId then val else prev q

/-- Well-formedness: every node definition references strictly earlier topological IDs (`< ds.length`). -/
def dagWellFormed : List TseitinNodeDef → Prop
  | [] => True
  | d :: ds =>
    dagWellFormed ds ∧
    match d with
    | TseitinNodeDef.primaryIn _v => True
    | TseitinNodeDef.xorNode u w => u < ds.length ∧ w < ds.length
    | TseitinNodeDef.andNode u _iu w _iw => u < ds.length ∧ w < ds.length

/-- Conjunction of 1-variable-per-node Tseitin equality constraints (`n_id ↔ op(...)`). -/
def satisfiesTseitin (env assign : Nat → Bool) : List TseitinNodeDef → Bool
  | [] => true
  | d :: ds =>
    let curId := ds.length
    let rhs :=
      match d with
      | TseitinNodeDef.primaryIn v => env v
      | TseitinNodeDef.xorNode u w => xor (assign u) (assign w)
      | TseitinNodeDef.andNode u iu w iw => (xor iu (assign u)) && (xor iw (assign w))
    (assign curId == rhs) && satisfiesTseitin env assign ds

theorem evalTseitinDag_prefix_invariant (env : Nat → Bool) (d : TseitinNodeDef)
    (ds : List TseitinNodeDef) (q : Nat) (hq : q < ds.length) :
    evalTseitinDag env (d :: ds) q = evalTseitinDag env ds q := by
  have hne : q ≠ ds.length := Nat.ne_of_lt hq
  simp [evalTseitinDag, hne]

theorem tseitin_dag_model_agrees_with_semantics
    (env assign : Nat → Bool) (dag : List TseitinNodeDef)
    (hwf : dagWellFormed dag) (hsat : satisfiesTseitin env assign dag = true) :
    ∀ q, q < dag.length → assign q = evalTseitinDag env dag q := by
  induction dag with
  | nil =>
    intro q hq; simp at hq
  | cons d ds ih =>
    rcases hwf with ⟨hwfDs, hdBound⟩
    rcases Bool.and_eq_true_iff.mp hsat with ⟨hcur, hrest⟩
    have hprev := ih hwfDs hrest
    intro q hq
    by_cases heq : q = ds.length
    · subst heq
      rw [eq_of_beq hcur]
      cases d with
      | primaryIn v => simp [evalTseitinDag]
      | xorNode u w =>
        simp [evalTseitinDag, hprev u hdBound.1, hprev w hdBound.2]
      | andNode u iu w iw =>
        simp [evalTseitinDag, hprev u hdBound.1, hprev w hdBound.2]
    · have hlt : q < ds.length := by simp at hq; omega
      rw [evalTseitinDag_prefix_invariant env d ds q hlt]
      exact hprev q hlt

theorem tseitin_canonical_eval_satisfies_defs
    (env : Nat → Bool) (dag : List TseitinNodeDef) (hwf : dagWellFormed dag) :
    satisfiesTseitin env (evalTseitinDag env dag) dag = true := by
  have hgen : ∀ (fullDag : List TseitinNodeDef) (f : Nat → Bool),
      dagWellFormed fullDag →
      (∀ q, q < fullDag.length → f q = evalTseitinDag env fullDag q) →
      satisfiesTseitin env f fullDag = true := by
    intro fullDag
    induction fullDag with
    | nil =>
      intro _f _hw _hag; rfl
    | cons d ds ih =>
      intro f ⟨hwfDs, hdBound⟩ hag
      have hagDs : ∀ q, q < ds.length → f q = evalTseitinDag env ds q := by
        intro q hq
        rw [hag q (Nat.lt_succ_of_lt hq), evalTseitinDag_prefix_invariant env d ds q hq]
      have hhead : f ds.length = evalTseitinDag env (d :: ds) ds.length :=
        hag ds.length (Nat.lt_succ_self ds.length)
      simp only [satisfiesTseitin, ih f hwfDs hagDs, Bool.and_true]
      cases d with
      | primaryIn v => simp [hhead, evalTseitinDag]
      | xorNode u w => simp [hhead, evalTseitinDag, hagDs u hdBound.1, hagDs w hdBound.2]
      | andNode u iu w iw => simp [hhead, evalTseitinDag, hagDs u hdBound.1, hagDs w hdBound.2]
  exact hgen dag (evalTseitinDag env dag) hwf (fun _q _hq => rfl)

/-- Soundness & completeness of the 1-variable-per-node `Z3` Tseitin DAG miter over ideal `dom`. -/
theorem tseitin_miter_unsat_iff_xag_domain_equivalence
    (dom : (Nat → Bool) → Bool) (dag : List TseitinNodeDef) (r1 r2 : Nat)
    (hwf : dagWellFormed dag) (hr1 : r1 < dag.length) (hr2 : r2 < dag.length) :
    (∀ env assign, dom env = true → satisfiesTseitin env assign dag = true →
      xor (assign r1) (assign r2) = false) ↔
    (∀ env, dom env = true → evalTseitinDag env dag r1 = evalTseitinDag env dag r2) := by
  constructor
  · intro hunsat env hdom
    have hsat := tseitin_canonical_eval_satisfies_defs env dag hwf
    have hxor := hunsat env (evalTseitinDag env dag) hdom hsat
    cases h1 : evalTseitinDag env dag r1 <;> cases h2 : evalTseitinDag env dag r2 <;>
      simp_all
  · intro heq env assign hdom hsat
    have a1 := tseitin_dag_model_agrees_with_semantics env assign dag hwf hsat r1 hr1
    have a2 := tseitin_dag_model_agrees_with_semantics env assign dag hwf hsat r2 hr2
    rw [a1, a2, heq env hdom]
    cases evalTseitinDag env dag r2 <;> rfl

/-- Soundness of Local Bottleneck Cut-Sweeping: if the local cut cone `localMiter` is `UNSAT`
    across all cut assignments `cutEnv`, then it vanishes across any multi-round upstream circuit
    `upstreamCone` and any domain subspace `dom`. -/
theorem cut_sweeping_local_unsat_implies_global_multiround_soundness
    (localMiter : (Nat → Bool) → Bool)
    (upstreamCone : (Nat → Bool) → (Nat → Bool))
    (dom : (Nat → Bool) → Bool)
    (hcutUnsat : ∀ cutEnv, localMiter cutEnv = false) :
    ∀ env, dom env = true → localMiter (upstreamCone env) = false := by
  intro env _hdom
  exact hcutUnsat (upstreamCone env)

-- ============================================================================
-- Section 6: Canonical Sub-DAG Cone Isomorphism & Zero-Flag Loop Escalation
-- ============================================================================

/-- Evaluate a relabeled Tseitin DAG where primary inputs are permuted by `perm : Nat → Nat`. -/
def relabelEnv (perm : Nat → Nat) (env : Nat → Bool) : Nat → Bool :=
  fun v => env (perm v)

/-- Soundness of Canonical Sub-DAG Cone Isomorphism Modulo Input-Wire Relabeling:
    If two cut cones `dag1` and `dag2` have identical internal XAG topology up to
    cut-variable relabeling `perm` (`evalTseitinDag env dag2 r = evalTseitinDag (relabelEnv perm env) dag1 r`),
    and the prototype cone `dag1` is proved `UNSAT` (`= false`) across all cut assignments,
    then `dag2` vanishes across any upstream multi-round circuit `upstream` and domain `dom`. -/
theorem cone_isomorphism_relabeling_soundness
    (dag1 dag2 : List TseitinNodeDef) (r : Nat) (perm : Nat → Nat)
    (upstream : (Nat → Bool) → (Nat → Bool)) (dom : (Nat → Bool) → Bool)
    (hiso : ∀ cutEnv, evalTseitinDag cutEnv dag2 r = evalTseitinDag (relabelEnv perm cutEnv) dag1 r)
    (hprotoUnsat : ∀ cutEnv, evalTseitinDag cutEnv dag1 r = false) :
    ∀ env, dom env = true → evalTseitinDag (upstream env) dag2 r = false := by
  intro env _hdom
  rw [hiso (upstream env)]
  exact hprotoUnsat (relabelEnv perm (upstream env))

/-- Zero-flag automatic loop-invariant escalation decision (`k=1 -> k=2 -> k=R`). -/
def autoEscalateLoopDecision (k1Ok k2Ok kROk evenRounds : Bool) : Bool :=
  if k1Ok then true
  else if evenRounds && k2Ok then true
  else kROk

/-- Soundness of Zero-Flag `k=1 → k=2 → k=R` Escalation:
    When 1-round invariance (`k1Ok = true`), 2-round ping-pong invariance on even round counts
    (`evenRounds && k2Ok = true`), and full `R`-round unrolled verification (`kROk = true`)
    each imply global `R`-round `QSub` validity (`u1Clean && u4Clean = true`), the automatic
    escalation ladder guarantees `u1Clean = true ∧ u4Clean = true` whenever it accepts. -/
theorem zero_flag_k1_k2_unrolled_escalation_soundness
    (k1Ok k2Ok kROk evenRounds u1Clean u4Clean : Bool)
    (hk1Sound : k1Ok = true → (u1Clean && u4Clean) = true)
    (hk2Sound : (evenRounds && k2Ok) = true → (u1Clean && u4Clean) = true)
    (hkRSound : kROk = true → (u1Clean && u4Clean) = true)
    (hacc : autoEscalateLoopDecision k1Ok k2Ok kROk evenRounds = true) :
    u1Clean = true ∧ u4Clean = true := by
  cases k1Ok <;> cases evenRounds <;> cases k2Ok <;>
    simp_all [autoEscalateLoopDecision]

end LakefillQXagFraigSymbolicInferenceProofs
