/-!
# Automatic Wire-Level `U1–U4 + QPhysGrade + QuRA Width` Inference & Symbolic ANF Soundness Proofs

This self-contained, zero-`sorry`, zero-`axiom`, zero-`native_decide`, zero-wildcard,
zero-warning Lean 4.35.0 module mechanizes the algebraic and operational soundness
theorems backing `lakefill-wire-level-symbolic-typechecker.rkt`:

1. **`symbolic_f2_anf_gate_evaluation_soundness`**:
   Canonical $\mathbb{F}_2[x_0, \dots, x_{n-1}]$ Algebraic Normal Form (`AnfPoly`) gate
   transformer `evalGateAnf` agrees bit-for-bit with concrete wire semantics
   `evalConcreteCircuit` across arbitrary sequences of `x`, `cx`, `ccx`, and `swap`.
2. **`automatic_u1_anf_zero_implies_clean_scratch_and_refutes_bch_hamming_stub`**:
   Automatic `Law U1` zero-polynomial check (`evalGateAnf cs (initSymState n) w = anfZero`)
   guarantees concrete scratch wire `= false` across all inputs, and explicitly refutes
   the `wt <= 1` Hamming decoder stub on `BCH(15, 7, 5)` weight-2 input `e = e_0 + e_1` (`mask = 3`).
3. **`automatic_u2_history_independence_implies_identical_post_state`**:
   Automatic `Law U2` history-independence ANF check (`anfFreeOfVar qVar` + zero quotient
   ANF) guarantees identical post-canonicalization concrete wire state across all
   history/quotient-equivalent input pairs `(x, q_1) ~ (x, q_2)`.
4. **`automatic_u3_boolean_partition_iff_unique_active_branch`**:
   Automatic `Law U3` Boolean partition check (`orAllAnf = true ∧ pairwiseDisjointAnf = true`)
   holds if and only if every input activates a unique branch (`countActiveBranches = 1`).
5. **`automatic_u4_bilinear_phase_polynomial_cancellation_zero_kickback`**:
   Automatic `Law U4` bilinear $\mathbb{F}_2$ phase-polynomial cancellation (`anfXor taint fixup = anfZero`)
   implies exact zero phase kickback across all `(m, env)` outcomes, including both standard
   `TempAND + cond-cz` and negated-control `TempAND + (cond-z ; cond-cz)`.
6. **`qura_mid_meas_x_live_wire_recycling_strictly_reduces_peak_width`**:
   `QuRA`-style live-wire recycling via `mid-meas-x` strictly reduces peak logical qubit
   width (`peakWidthRecycled < peakWidthUnrecycled`) across sequential `TempAND` sessions.
7. **`wire_level_symbolic_type_inference_module_closure`**:
   Master module closure uniting all wire-level symbolic inference theorems and `verifyWireLevelSymbolicInferenceModuleSanity () = true`.
-/

namespace WireLevelSymbolicTypeInferenceProofs

-- ============================================================================
-- Section 1: Canonical Multilinear F_2 Algebraic Normal Form (`AnfPoly`)
-- ============================================================================

/-- A multilinear monomial $\prod_{v \in m} x_v$ represented as a sorted duplicate-free `List Nat`. -/
abbrev Monomial := List Nat

/-- Canonical multilinear polynomial $\bigoplus_{m \in p} \prod_{v \in m} x_v$ over $\mathbb{F}_2$. -/
abbrev AnfPoly := List Monomial

def anfZero : AnfPoly := []
def anfOne  : AnfPoly := [[]]
def anfVar (v : Nat) : AnfPoly := [[v]]

/-- Evaluate a monomial $\prod_{v \in m} x_v$ under Boolean wire assignment `env`. -/
def evalMono (env : Nat → Bool) : Monomial → Bool
  | [] => true
  | v :: vs => env v && evalMono env vs

/-- Evaluate an ANF polynomial $\bigoplus_{m \in p} m(x)$ over $\mathbb{F}_2$. -/
def evalAnf (env : Nat → Bool) : AnfPoly → Bool
  | [] => false
  | m :: ms => xor (evalMono env m) (evalAnf env ms)

/-- Insert variable `v` into sorted monomial `m` enforcing Boolean idempotence $x_v^2 = x_v$. -/
def insertVarMono (v : Nat) : Monomial → Monomial
  | [] => [v]
  | h :: t =>
    if v == h then h :: t
    else if v < h then v :: h :: t
    else h :: insertVarMono v t

/-- Multiply two monomials in $\mathbb{F}_2[x_0, \dots, x_{n-1}] / \langle x_i^2 - x_i \rangle$. -/
def mulMono : Monomial → Monomial → Monomial
  | [], m2 => m2
  | v :: vs, m2 => insertVarMono v (mulMono vs m2)

/-- Toggle presence of monomial `m` in ANF polynomial `ps` enforcing $m \oplus m = 0$. -/
def toggleMono (m : Monomial) : AnfPoly → AnfPoly
  | [] => [m]
  | h :: t =>
    if m == h then t
    else h :: toggleMono m t

/-- Canonical $\mathbb{F}_2$ polynomial addition `anfXor` ($p \oplus q$). -/
def anfXor : AnfPoly → AnfPoly → AnfPoly
  | [], q => q
  | m :: ms, q => toggleMono m (anfXor ms q)

/-- Canonical $\mathbb{F}_2$ negation `anfNot` ($1 \oplus p$). -/
def anfNot (p : AnfPoly) : AnfPoly :=
  anfXor anfOne p

/-- Distribute monomial `m` across ANF polynomial `q`. -/
def anfMulMono (m : Monomial) : AnfPoly → AnfPoly
  | [] => []
  | h :: t => toggleMono (mulMono m h) (anfMulMono m t)

/-- Canonical $\mathbb{F}_2$ multilinear multiplication `anfAnd` ($p \cdot q$). -/
def anfAnd : AnfPoly → AnfPoly → AnfPoly
  | [], _q => []
  | m :: ms, q => anfXor (anfMulMono m q) (anfAnd ms q)

theorem evalMono_insertVar (env : Nat → Bool) (v : Nat) (m : Monomial) :
    evalMono env (insertVarMono v m) = (env v && evalMono env m) := by
  induction m with
  | nil =>
    simp only [insertVarMono, evalMono]
  | cons h t ih =>
    simp only [insertVarMono]
    by_cases heq : (v == h) = true
    · have hv : v = h := eq_of_beq heq
      subst hv
      simp only [heq, ↓reduceIte, evalMono]
      cases env v <;> cases evalMono env t <;> rfl
    · simp only [Bool.not_eq_true] at heq
      simp only [heq, Bool.false_eq_true, ↓reduceIte]
      by_cases hlt : v < h
      · simp only [hlt, ↓reduceIte, evalMono]
      · simp only [hlt, ↓reduceIte, evalMono, ih]
        cases env v <;> cases env h <;> cases evalMono env t <;> rfl

theorem evalMono_mulMono (env : Nat → Bool) (m1 m2 : Monomial) :
    evalMono env (mulMono m1 m2) = (evalMono env m1 && evalMono env m2) := by
  induction m1 with
  | nil =>
    simp [mulMono, evalMono]
  | cons v vs ih =>
    simp only [mulMono, evalMono, evalMono_insertVar, ih]
    cases env v <;> cases evalMono env vs <;> cases evalMono env m2 <;> rfl

theorem evalAnf_toggleMono (env : Nat → Bool) (m : Monomial) (ps : AnfPoly) :
    evalAnf env (toggleMono m ps) = xor (evalMono env m) (evalAnf env ps) := by
  induction ps with
  | nil =>
    simp [toggleMono, evalAnf]
  | cons h t ih =>
    simp only [toggleMono]
    by_cases heq : (m == h) = true
    · have hm : m = h := eq_of_beq heq
      subst hm
      simp only [heq, ↓reduceIte, evalAnf]
      cases evalMono env m <;> cases evalAnf env t <;> rfl
    · simp only [Bool.not_eq_true] at heq
      simp only [heq, Bool.false_eq_true, ↓reduceIte, evalAnf, ih]
      cases evalMono env m <;> cases evalMono env h <;> cases evalAnf env t <;> rfl

theorem evalAnf_xor (env : Nat → Bool) (p q : AnfPoly) :
    evalAnf env (anfXor p q) = xor (evalAnf env p) (evalAnf env q) := by
  induction p with
  | nil =>
    simp [anfXor, evalAnf]
  | cons m ms ih =>
    simp only [anfXor, evalAnf, evalAnf_toggleMono, ih]
    cases evalMono env m <;> cases evalAnf env ms <;> cases evalAnf env q <;> rfl

theorem evalAnf_not (env : Nat → Bool) (p : AnfPoly) :
    evalAnf env (anfNot p) = !(evalAnf env p) := by
  simp only [anfNot, evalAnf_xor, anfOne, evalAnf, evalMono]
  cases evalAnf env p <;> rfl

theorem evalAnf_mulMono (env : Nat → Bool) (m : Monomial) (q : AnfPoly) :
    evalAnf env (anfMulMono m q) = (evalMono env m && evalAnf env q) := by
  induction q with
  | nil =>
    cases evalMono env m <;> rfl
  | cons h t ih =>
    simp only [anfMulMono, evalAnf_toggleMono, evalMono_mulMono, evalAnf, ih]
    cases evalMono env m <;> cases evalMono env h <;> cases evalAnf env t <;> rfl

theorem evalAnf_and (env : Nat → Bool) (p q : AnfPoly) :
    evalAnf env (anfAnd p q) = (evalAnf env p && evalAnf env q) := by
  induction p with
  | nil =>
    rfl
  | cons m ms ih =>
    simp only [anfAnd, evalAnf, evalAnf_xor, evalAnf_mulMono, ih]
    cases evalMono env m <;> cases evalAnf env ms <;> cases evalAnf env q <;> rfl

-- ============================================================================
-- Section 2: Wire-Level Reversible Gate Semantics
-- ============================================================================

/-- Raw wire-level reversible gate primitives (`x`, `cx`, `ccx`, `swap`). -/
inductive WireRevGate where
  | x (w : Nat)
  | cx (c t : Nat)
  | ccx (c1 c2 t : Nat)
  | swap (a b : Nat)
  deriving DecidableEq, Repr

/-- Concrete single-gate wire state transition (`stepConcreteGate`). -/
def stepConcreteGate (g : WireRevGate) (st : Nat → Bool) (u : Nat) : Bool :=
  match g with
  | WireRevGate.x w =>
    if u == w then !(st w) else st u
  | WireRevGate.cx c t =>
    if u == t then xor (st t) (st c) else st u
  | WireRevGate.ccx c1 c2 t =>
    if u == t then xor (st t) (st c1 && st c2) else st u
  | WireRevGate.swap a b =>
    if u == a then st b else if u == b then st a else st u

/-- Concrete sequential reversible circuit evaluator (`evalConcreteCircuit`). -/
def evalConcreteCircuit : List WireRevGate → (Nat → Bool) → (Nat → Bool)
  | [], st => st
  | g :: gs, st => evalConcreteCircuit gs (stepConcreteGate g st)

/-- Symbolic ANF single-gate transformer (`stepGateAnf`). -/
def stepGateAnf (g : WireRevGate) (sym : Nat → AnfPoly) (u : Nat) : AnfPoly :=
  match g with
  | WireRevGate.x w =>
    if u == w then anfNot (sym w) else sym u
  | WireRevGate.cx c t =>
    if u == t then anfXor (sym t) (sym c) else sym u
  | WireRevGate.ccx c1 c2 t =>
    if u == t then anfXor (sym t) (anfAnd (sym c1) (sym c2)) else sym u
  | WireRevGate.swap a b =>
    if u == a then sym b else if u == b then sym a else sym u

/-- Symbolic ANF sequential circuit evaluator (`evalGateAnf`). -/
def evalGateAnf : List WireRevGate → (Nat → AnfPoly) → (Nat → AnfPoly)
  | [], sym => sym
  | g :: gs, sym => evalGateAnf gs (stepGateAnf g sym)

theorem stepGateAnf_sound (g : WireRevGate) (env : Nat → Bool) (sym : Nat → AnfPoly) (u : Nat) :
    evalAnf env (stepGateAnf g sym u) =
      stepConcreteGate g (fun k => evalAnf env (sym k)) u := by
  cases g with
  | x w =>
    simp only [stepGateAnf, stepConcreteGate]
    cases u == w <;> simp [evalAnf_not]
  | cx c t =>
    simp only [stepGateAnf, stepConcreteGate]
    cases u == t <;> simp [evalAnf_xor]
  | ccx c1 c2 t =>
    simp only [stepGateAnf, stepConcreteGate]
    cases u == t <;> simp [evalAnf_xor, evalAnf_and]
  | swap a b =>
    simp only [stepGateAnf, stepConcreteGate]
    cases u == a <;> cases u == b <;> rfl

/-- **`symbolic_f2_anf_gate_evaluation_soundness`**:
    Symbolic $\mathbb{F}_2$ ANF evaluation `evalGateAnf` agrees bit-for-bit with concrete
    wire execution `evalConcreteCircuit` across all sequences of `x`, `cx`, `ccx`, and `swap`. -/
theorem symbolic_f2_anf_gate_evaluation_soundness
    (cs : List WireRevGate) (env : Nat → Bool) (sym : Nat → AnfPoly) (w : Nat) :
    evalAnf env (evalGateAnf cs sym w) =
      evalConcreteCircuit cs (fun k => evalAnf env (sym k)) w := by
  induction cs generalizing sym with
  | nil =>
    rfl
  | cons g gs ih =>
    simp only [evalGateAnf, evalConcreteCircuit]
    rw [ih (stepGateAnf g sym)]
    have hfun : (fun k => evalAnf env (stepGateAnf g sym k)) =
        stepConcreteGate g (fun k => evalAnf env (sym k)) := by
      funext k
      exact stepGateAnf_sound g env sym k
    rw [hfun]

-- ============================================================================
-- Section 3: Automatic Law U1 & BCH(15, 7, 5) Hamming Stub Refutation (core theorems)
-- ============================================================================

/-- Initial symbolic wire environment: `0..numInputs-1` hold `x_u`, scratch wires `>= numInputs` hold `0`. -/
def initSymState (numInputs u : Nat) : AnfPoly :=
  if u < numInputs then anfVar u else anfZero

/-- Initial concrete wire environment: `0..numInputs-1` hold `env u`, scratch wires `>= numInputs` hold `false`. -/
def initConcreteState (env : Nat → Bool) (numInputs u : Nat) : Bool :=
  if u < numInputs then env u else false

theorem initSymState_sound (env : Nat → Bool) (numInputs u : Nat) :
    evalAnf env (initSymState numInputs u) = initConcreteState env numInputs u := by
  simp only [initSymState, initConcreteState]
  by_cases hlt : u < numInputs
  · simp only [hlt, ↓reduceIte, anfVar, evalAnf, evalMono]
    cases env u <;> rfl
  · simp only [hlt, ↓reduceIte, anfZero, evalAnf]

/-- Multiplication in $\mathbb{F}_{2^4} = \mathbb{F}_2[\alpha]/(\alpha^4 + \alpha + 1)$ (`bchGf16Step`, `bchGf16Mul`). -/
def bchGf16Step (x : Nat) : Nat :=
  let sh := (x <<< 1) &&& 0xF
  if (x &&& 0x8) != 0 then Nat.xor sh 0x3 else sh

def bchGf16Mul (a b : Nat) : Nat :=
  let t0 := a &&& 0xF
  let t1 := bchGf16Step t0
  let t2 := bchGf16Step t1
  let t3 := bchGf16Step t2
  let sel (k v : Nat) := if ((b >>> k) &&& 1) == 1 then v else 0
  Nat.xor (Nat.xor (sel 0 t0) (sel 1 t1)) (Nat.xor (sel 2 t2) (sel 3 t3))

def bchGf16Pow : Nat → Nat → Nat
  | _a, 0 => 1
  | a, k + 1 => bchGf16Mul a (bchGf16Pow a k)

/-- Primary `BCH(15, 7, 5)` syndrome $S_1(e) = \bigoplus_{i=0}^{14} e_i \alpha^i \in \mathbb{F}_{2^4}$. -/
def bch15SyndromeS1Aux (mask15 : Nat) : Nat → Nat
  | 0 => 0
  | k + 1 =>
    let term := if ((mask15 >>> k) &&& 1) == 1 then bchGf16Pow 2 k else 0
    Nat.xor term (bch15SyndromeS1Aux mask15 k)

def bch15SyndromeS1 (mask15 : Nat) : Nat :=
  bch15SyndromeS1Aux mask15 15

/-- Hamming `wt <= 1` decoder stub (`Lambda(a^{-i}) = 1 ^ S_1 * a^{-i} == 0`) residual mask on `e`. -/
def bch15HammingStubFlipMaskAux (s1 : Nat) : Nat → Nat
  | 0 => 0
  | k + 1 =>
    let xInv := bchGf16Pow 2 (15 - (k % 15))
    let rootHit := if Nat.xor 1 (bchGf16Mul s1 xInv) == 0 then (1 <<< k) else 0
    rootHit ||| bch15HammingStubFlipMaskAux s1 k

def bch15HammingWt1StubResidual (mask15 : Nat) : Nat :=
  Nat.xor mask15 (bch15HammingStubFlipMaskAux (bch15SyndromeS1 mask15) 15)

/-- **`automatic_u1_anf_zero_implies_clean_scratch_and_refutes_bch_hamming_stub`**:
    (1) Whenever symbolic ANF erasure reduces wire `w` to `anfZero` (`[]`), the concrete wire
    is strictly `false` (`|0>`) across all input assignments `env`, AND
    (2) On `BCH(15, 7, 5)`, the `wt <= 1` Hamming stub erases weight-1 errors (`mask = 1`)
    but leaves non-zero residual garbage on minimal weight-2 error `mask = 3` (`e = e_0 + e_1`). -/
theorem automatic_u1_anf_zero_implies_clean_scratch_and_refutes_bch_hamming_stub
    (cs : List WireRevGate) (env : Nat → Bool) (numInputs w : Nat)
    (hZero : evalGateAnf cs (initSymState numInputs) w = anfZero) :
    evalConcreteCircuit cs (initConcreteState env numInputs) w = false ∧
      bch15HammingWt1StubResidual 1 = 0 ∧
      bch15HammingWt1StubResidual 3 ≠ 0 := by
  refine ⟨?_, ?_, ?_⟩
  · have hSound :=
      symbolic_f2_anf_gate_evaluation_soundness cs env (initSymState numInputs) w
    have hInit : (fun k => evalAnf env (initSymState numInputs k)) = initConcreteState env numInputs := by
      funext k
      exact initSymState_sound env numInputs k
    rw [hInit, hZero] at hSound
    exact hSound.symm
  · decide
  · decide

-- ============================================================================
-- Section 4: Automatic Law U2 History/Quotient Independence (core theorems)
-- ============================================================================

/-- Check whether monomial `m` contains no occurrence of non-canonical variable `qVar`. -/
def monoFreeOfVar (qVar : Nat) : Monomial → Bool
  | [] => true
  | v :: vs => !(v == qVar) && monoFreeOfVar qVar vs

/-- Symbolic Law U2 check: ANF polynomial `p` has zero dependence on `qVar` ($\partial p / \partial x_{qVar} = 0$). -/
def anfFreeOfVar (qVar : Nat) : AnfPoly → Bool
  | [] => true
  | m :: ms => monoFreeOfVar qVar m && anfFreeOfVar qVar ms

theorem evalMono_eq_of_free (qVar : Nat) (m : Monomial) (env1 env2 : Nat → Bool)
    (hFree : monoFreeOfVar qVar m = true)
    (hAgree : ∀ v, v ≠ qVar → env1 v = env2 v) :
    evalMono env1 m = evalMono env2 m := by
  induction m with
  | nil =>
    rfl
  | cons v vs ih =>
    simp only [monoFreeOfVar, Bool.and_eq_true, Bool.not_eq_true'] at hFree
    have hvNe : v ≠ qVar := by
      intro hEq
      subst hEq
      simp at hFree
    simp only [evalMono, hAgree v hvNe, ih hFree.2]

theorem evalAnf_eq_of_free (qVar : Nat) (p : AnfPoly) (env1 env2 : Nat → Bool)
    (hFree : anfFreeOfVar qVar p = true)
    (hAgree : ∀ v, v ≠ qVar → env1 v = env2 v) :
    evalAnf env1 p = evalAnf env2 p := by
  induction p with
  | nil =>
    rfl
  | cons m ms ih =>
    simp only [anfFreeOfVar, Bool.and_eq_true] at hFree
    simp only [evalAnf, evalMono_eq_of_free qVar m env1 env2 hFree.1 hAgree, ih hFree.2]

/-- **`automatic_u2_history_independence_implies_identical_post_state`**:
    Whenever `anfFreeOfVar qVar` holds on post-cleanup wire `w` and quotient wire `qWire`
    reduces to `anfZero`, any two history/quotient-equivalent inputs `env1 ~ env2` agreeing
    outside `qVar` yield identical concrete post-cleanup state on `w` and `false` on `qWire`. -/
theorem automatic_u2_history_independence_implies_identical_post_state
    (cleanupCs : List WireRevGate) (env1 env2 : Nat → Bool) (numInputs qVar w qWire : Nat)
    (hAgree : ∀ v, v ≠ qVar → env1 v = env2 v)
    (hFree : anfFreeOfVar qVar (evalGateAnf cleanupCs (initSymState numInputs) w) = true)
    (hQuotZero : evalGateAnf cleanupCs (initSymState numInputs) qWire = anfZero) :
    evalConcreteCircuit cleanupCs (initConcreteState env1 numInputs) w =
      evalConcreteCircuit cleanupCs (initConcreteState env2 numInputs) w ∧
    evalConcreteCircuit cleanupCs (initConcreteState env1 numInputs) qWire = false := by
  have h1 := symbolic_f2_anf_gate_evaluation_soundness cleanupCs env1 (initSymState numInputs) w
  have h2 := symbolic_f2_anf_gate_evaluation_soundness cleanupCs env2 (initSymState numInputs) w
  have hi1 : (fun k => evalAnf env1 (initSymState numInputs k)) = initConcreteState env1 numInputs := by
    funext k; exact initSymState_sound env1 numInputs k
  have hi2 : (fun k => evalAnf env2 (initSymState numInputs k)) = initConcreteState env2 numInputs := by
    funext k; exact initSymState_sound env2 numInputs k
  rw [hi1] at h1
  rw [hi2] at h2
  refine ⟨?_, ?_⟩
  · rw [← h1, ← h2]
    exact evalAnf_eq_of_free qVar (evalGateAnf cleanupCs (initSymState numInputs) w) env1 env2 hFree hAgree
  · exact (automatic_u1_anf_zero_implies_clean_scratch_and_refutes_bch_hamming_stub
      cleanupCs env1 numInputs qWire hQuotZero).1

-- ============================================================================
-- Section 5: Automatic Law U3 Orthogonal Partition Check (core theorems)
-- ============================================================================

def orAllAnf (env : Nat → Bool) : List AnfPoly → Bool
  | [] => false
  | p :: ps => evalAnf env p || orAllAnf env ps

def noneActiveAnf (env : Nat → Bool) : List AnfPoly → Bool
  | [] => true
  | p :: ps => !(evalAnf env p) && noneActiveAnf env ps

def pairwiseDisjointAnf (env : Nat → Bool) : List AnfPoly → Bool
  | [] => true
  | p :: ps =>
    (if evalAnf env p then noneActiveAnf env ps else true) &&
      pairwiseDisjointAnf env ps

def countActiveBranches (env : Nat → Bool) : List AnfPoly → Nat
  | [] => 0
  | p :: ps => (if evalAnf env p then 1 else 0) + countActiveBranches env ps

theorem noneActive_iff_count_zero (env : Nat → Bool) (ps : List AnfPoly) :
    noneActiveAnf env ps = true ↔ countActiveBranches env ps = 0 := by
  induction ps with
  | nil =>
    simp [noneActiveAnf, countActiveBranches]
  | cons p rest ih =>
    simp only [noneActiveAnf, countActiveBranches]
    cases evalAnf env p
    · simp [ih]
    · simp

theorem pairwiseDisjoint_of_count_zero (env : Nat → Bool) (ps : List AnfPoly)
    (hZero : countActiveBranches env ps = 0) :
    pairwiseDisjointAnf env ps = true := by
  induction ps with
  | nil =>
    rfl
  | cons q qs ih =>
    simp only [countActiveBranches] at hZero
    cases hq : evalAnf env q
    · simp [hq] at hZero
      simp [pairwiseDisjointAnf, hq, ih hZero]
    · simp [hq] at hZero

/-- **`automatic_u3_boolean_partition_iff_unique_active_branch`**:
    Automatic `U3` Boolean partition check (`orAllAnf env preds = true ∧ pairwiseDisjointAnf env preds = true`)
    holds if and only if exactly one branch is active (`countActiveBranches env preds = 1`). -/
theorem automatic_u3_boolean_partition_iff_unique_active_branch
    (env : Nat → Bool) (preds : List AnfPoly) :
    (orAllAnf env preds = true ∧ pairwiseDisjointAnf env preds = true) ↔
      countActiveBranches env preds = 1 := by
  induction preds with
  | nil =>
    simp [orAllAnf, pairwiseDisjointAnf, countActiveBranches]
  | cons p ps ih =>
    simp only [orAllAnf, pairwiseDisjointAnf, countActiveBranches]
    cases hp : evalAnf env p
    · simp [ih]
    · simp only [Bool.true_or, ↓reduceIte, Bool.and_eq_true, true_and]
      constructor
      · intro hPair
        have hZero : countActiveBranches env ps = 0 :=
          (noneActive_iff_count_zero env ps).mp hPair.1
        omega
      · intro hOne
        have hZero : countActiveBranches env ps = 0 := by omega
        exact ⟨(noneActive_iff_count_zero env ps).mpr hZero,
               pairwiseDisjoint_of_count_zero env ps hZero⟩

-- ============================================================================
-- Section 6: Automatic Law U4 Bilinear Phase-Polynomial Cancellation (core theorems)
-- ============================================================================

/-- Net $\mathbb{F}_2$ phase exponent $m \cdot T(x) \oplus m \cdot F(x)$ after classical feed-forward fixup. -/
def phaseKickbackAfterFixup (m : Bool) (env : Nat → Bool) (taintPoly fixupPoly : AnfPoly) : Bool :=
  xor (m && evalAnf env taintPoly) (m && evalAnf env fixupPoly)

/-- **`automatic_u4_bilinear_phase_polynomial_cancellation_zero_kickback`**:
    (1) Whenever symbolic phase cancellation reduces `anfXor taintPoly fixupPoly` to `anfZero`,
    residual phase kickback is identically `false` across all `(m, env)` outcomes, AND
    (2) Both standard `TempAND + cond-cz` and negated-control `TempAND + (cond-z ; cond-cz)`
    produce exact zero phase kickback across all `(m, c1, c2 : Bool)`. -/
theorem automatic_u4_bilinear_phase_polynomial_cancellation_zero_kickback
    (m c1 c2 : Bool) (env : Nat → Bool) (taintPoly fixupPoly : AnfPoly)
    (hCancel : anfXor taintPoly fixupPoly = anfZero) :
    phaseKickbackAfterFixup m env taintPoly fixupPoly = false ∧
      xor (m && (c1 && c2)) (m && (c1 && c2)) = false ∧
      xor (m && (c1 && !c2)) (xor (m && c1) (m && (c1 && c2))) = false := by
  refine ⟨?_, ?_, ?_⟩
  · have hEval : evalAnf env (anfXor taintPoly fixupPoly) = false := by
      rw [hCancel]
      rfl
    rw [evalAnf_xor] at hEval
    unfold phaseKickbackAfterFixup
    cases ht : evalAnf env taintPoly <;> cases hf : evalAnf env fixupPoly <;>
      cases m <;> simp_all
  · cases m <;> cases c1 <;> cases c2 <;> rfl
  · cases m <;> cases c1 <;> cases c2 <;> rfl

-- ============================================================================
-- Section 7: `QuRA` Live-Wire Recycling via `mid-meas-x` Peak-Width Theorem
-- ============================================================================

/-- Operational width state `(liveWires, peakWires)` during sequential `TempAND` sessions. -/
structure WidthTracker where
  liveWires : Nat
  peakWires : Nat
  deriving DecidableEq, Repr

/-- Step one `TempAND` session of `m` ancillas WITH `mid-meas-x` freeing (`stepRecycledSession`). -/
def stepRecycledSession (m : Nat) (st : WidthTracker) : WidthTracker :=
  let afterAlloc := st.liveWires + m
  let newPeak := if st.peakWires ≤ afterAlloc then afterAlloc else st.peakWires
  { liveWires := st.liveWires, peakWires := newPeak }

/-- Step one `TempAND` session of `m` ancillas WITHOUT freeing (`stepUnrecycledSession`). -/
def stepUnrecycledSession (m : Nat) (st : WidthTracker) : WidthTracker :=
  let afterAlloc := st.liveWires + m
  let newPeak := if st.peakWires ≤ afterAlloc then afterAlloc else st.peakWires
  { liveWires := afterAlloc, peakWires := newPeak }

def runRecycledSessions (m : Nat) : Nat → WidthTracker → WidthTracker
  | 0, st => st
  | k + 1, st => runRecycledSessions m k (stepRecycledSession m st)

def runUnrecycledSessions (m : Nat) : Nat → WidthTracker → WidthTracker
  | 0, st => st
  | k + 1, st => runUnrecycledSessions m k (stepUnrecycledSession m st)

def peakWidthRecycled (nData m k : Nat) : Nat :=
  (runRecycledSessions m k { liveWires := nData, peakWires := nData }).peakWires

def peakWidthUnrecycled (nData m k : Nat) : Nat :=
  (runUnrecycledSessions m k { liveWires := nData, peakWires := nData }).peakWires

theorem runRecycledSessions_inv (m k live pk : Nat) (hBound : pk ≤ live + m) :
    (runRecycledSessions m (k + 1) { liveWires := live, peakWires := pk }).peakWires = live + m := by
  induction k generalizing pk with
  | zero =>
    simp [runRecycledSessions, stepRecycledSession, hBound]
  | succ k' ih =>
    rw [runRecycledSessions]
    simp only [stepRecycledSession, hBound, ↓reduceIte]
    exact ih (live + m) (Nat.le_refl (live + m))

theorem runUnrecycledSessions_inv (m k live pk : Nat) (hPk : pk ≤ live) :
    (runUnrecycledSessions m (k + 1) { liveWires := live, peakWires := pk }).peakWires =
      live + (k + 1) * m := by
  induction k generalizing live pk with
  | zero =>
    have hLe : pk ≤ live + m := by omega
    simp [runUnrecycledSessions, stepUnrecycledSession, hLe]
  | succ k' ih =>
    have hLe : pk ≤ live + m := by omega
    rw [runUnrecycledSessions]
    simp only [stepUnrecycledSession, hLe, ↓reduceIte]
    rw [ih (live + m) (live + m) (Nat.le_refl (live + m))]
    have hMul : (k' + 1 + 1) * m = (k' + 1) * m + 1 * m := Nat.add_mul (k' + 1) 1 m
    rw [hMul, Nat.one_mul]
    omega

/-- **`qura_mid_meas_x_live_wire_recycling_strictly_reduces_peak_width`**:
    Across `k + 2 >= 2` sequential `TempAND` sessions of `m + 1 >= 1` ancillas each,
    `mid-meas-x` wire recycling strictly reduces peak qubit width (`peakWidthRecycled < peakWidthUnrecycled`),
    saving `(k + 1) * (m + 1)` logical qubits. -/
theorem qura_mid_meas_x_live_wire_recycling_strictly_reduces_peak_width
    (nData m k : Nat) :
    peakWidthRecycled nData (m + 1) (k + 2) < peakWidthUnrecycled nData (m + 1) (k + 2) ∧
      peakWidthUnrecycled nData (m + 1) (k + 2) - peakWidthRecycled nData (m + 1) (k + 2) =
        (k + 1) * (m + 1) := by
  have hRec : peakWidthRecycled nData (m + 1) (k + 2) = nData + (m + 1) :=
    runRecycledSessions_inv (m + 1) (k + 1) nData nData (by omega)
  have hUnrec : peakWidthUnrecycled nData (m + 1) (k + 2) = nData + (k + 2) * (m + 1) :=
    runUnrecycledSessions_inv (m + 1) (k + 1) nData nData (Nat.le_refl nData)
  have hExpand : (k + 2) * (m + 1) = (k + 1) * (m + 1) + (m + 1) := by
    change ((k + 1) + 1) * (m + 1) = (k + 1) * (m + 1) + (m + 1)
    rw [Nat.add_mul, Nat.one_mul]
  rw [hRec, hUnrec, hExpand]
  have hPos : 0 < (k + 1) * (m + 1) := Nat.mul_pos (Nat.succ_pos k) (Nat.succ_pos m)
  omega

-- ============================================================================
-- Section 8: Executable Sanity Suite & Master Closure core theorems
-- ============================================================================

/-- Executable module sanity suite verifying symbolic ANF evaluation, `U1` erasure + `BCH(15,7,5)`
    Hamming stub refutation, `U2` history independence, `U3` 4-way partition vs 3-way chord bug,
    `U4` algebraic `cond-z + cond-cz` cancellation to `[]`, and `QuRA` peak-width reduction. -/
def verifyWireLevelSymbolicInferenceModuleSanity (_u : Unit := ()) : Bool :=
  -- 1. Symbolic ANF Bennett `within-apply` (`ccx 0 1 2 ; cx 2 3 ; ccx 0 1 2`) erases scratch wire 2 to `[]`!
  let bennettCs := [WireRevGate.ccx 0 1 2, WireRevGate.cx 2 3, WireRevGate.ccx 0 1 2]
  let symAfter := evalGateAnf bennettCs (initSymState 2)
  let u1Clean := (symAfter 2 == anfZero) && (symAfter 3 == [[0, 1]])
  -- 2. BCH(15,7,5) Hamming wt<=1 stub erases wt=0,1 (`0, 1, 2`) and fails on minimal wt=2 (`mask = 3`)!
  let bchCheck :=
    (bch15HammingWt1StubResidual 0 == 0) &&
    (bch15HammingWt1StubResidual 1 == 0) &&
    (bch15HammingWt1StubResidual 2 == 0) &&
    (bch15HammingWt1StubResidual 3 != 0)
  -- 3. Law U2 history-variable check (`qVar = 1` erased by canonicalizer vs left uncleaned):
  let canonOkCs := [WireRevGate.cx 1 2, WireRevGate.cx 0 2, WireRevGate.cx 1 2]
  let u2Check :=
    anfFreeOfVar 1 (evalGateAnf canonOkCs (initSymState 2) 2) &&
    !(anfFreeOfVar 1 (evalGateAnf [WireRevGate.cx 1 2] (initSymState 2) 2))
  -- 4. Law U3 4-way partition vs 3-way missing branch on 2-bit locus:
  let p00 := anfAnd (anfNot (anfVar 0)) (anfNot (anfVar 1))
  let p01 := anfAnd (anfVar 0) (anfNot (anfVar 1))
  let p10 := anfAnd (anfNot (anfVar 0)) (anfVar 1)
  let p11 := anfAnd (anfVar 0) (anfVar 1)
  let env11 : Nat → Bool := fun i => i == 0 || i == 1
  let u3Check :=
    (countActiveBranches env11 [p00, p01, p10, p11] == 1) &&
    (countActiveBranches env11 [p00, p01, p10] == 0)
  -- 5. Law U4 algebraic negated `TempAND` `x0 * (1 ^ x1)` cancelled by `x0 ^ (x0 * x1)` to `[]`!
  let negTempAnd := anfAnd (anfVar 0) (anfNot (anfVar 1))
  let algFixup := anfXor (anfVar 0) (anfAnd (anfVar 0) (anfVar 1))
  let u4Check := (anfXor negTempAnd algFixup == anfZero)
  -- 6. QuRA width recycling (`BP34` Stage-3 `9`-wire reuse and sequential `GF(2^4)` `7`-AND sessions):
  let quraCheck :=
    (peakWidthRecycled 34 9 2 == 43) &&
    (peakWidthUnrecycled 34 9 2 == 52) &&
    (peakWidthRecycled 8 7 2 == 15) &&
    (peakWidthUnrecycled 8 7 2 == 22)
  u1Clean && bchCheck && u2Check && u3Check && u4Check && quraCheck

/-- **`wire_level_symbolic_type_inference_module_closure`**:
    Master module closure uniting all wire-level symbolic inference theorems and `verifyWireLevelSymbolicInferenceModuleSanity () = true`. -/
theorem wire_level_symbolic_type_inference_module_closure
    (cs : List WireRevGate) (env : Nat → Bool) (nData m k : Nat) :
    evalAnf env (evalGateAnf cs (initSymState nData) 0) =
      evalConcreteCircuit cs (initConcreteState env nData) 0 ∧
    bch15HammingWt1StubResidual 3 ≠ 0 ∧
    peakWidthRecycled nData (m + 1) (k + 2) < peakWidthUnrecycled nData (m + 1) (k + 2) ∧
    verifyWireLevelSymbolicInferenceModuleSanity () = true := by
  refine ⟨?_, ?_, ?_, ?_⟩
  · have h57a := symbolic_f2_anf_gate_evaluation_soundness cs env (initSymState nData) 0
    have hInit : (fun u => evalAnf env (initSymState nData u)) = initConcreteState env nData := by
      funext u; exact initSymState_sound env nData u
    rw [hInit] at h57a
    exact h57a
  · decide
  · exact (qura_mid_meas_x_live_wire_recycling_strictly_reduces_peak_width nData m k).1
  · decide

end WireLevelSymbolicTypeInferenceProofs
