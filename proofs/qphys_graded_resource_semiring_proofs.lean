/-!
# Unifying `P1–P5` into the 3-Rule Physical Resource Semiring `QPhysGrade` (`Φ1–Φ3`)

This self-contained, zero-`sorry`, zero-`axiom`, zero-warning Lean 4.35.0 module formalizes
the unification of the 5 –35 hardware side-conditions (`P1–P5`) into a single ordered
physical-effect resource semiring / graded monad `QPhysGrade` governed by **3 orthogonal
physical typing rules (`Φ1`, `Φ2`, `Φ3`)** (`Theorems 53A–53G`):

1. **`Φ1` (`checkPhi1LindbladGrade` — Compositional Lindblad Decoherence Action Grade $\nu$)**:
   Unifies `P1` (active circuit $T_1/T_2$ idle action + 2Q depolarizing gate infidelity),
   `P2` (mid-circuit `MBU` spectator measurement/reset latency excess, discharged by `XY4`
   dynamical decoupling or unitary demotion), and `P3` (planar/heavy-hex coupling SWAP routing
   overhead) into a single additive Lindblad action budget $\nu_{\text{eff}}(g) \le 693 \approx 1000 \ln 2$,
   with sequential additivity $\nu(e_1 ; e_2) = \nu(e_1) + \nu(e_2)$, parallel max-duration +
   sum-gate-infidelity composition `qphysPar`, and `qphysMultishot` per-shot reset.
2. **`Φ2` (`checkPhi2ExclusionDisjoint` — Hardware Interaction-Graph Spatial Disjointness $\chi$)**:
   Unifies `P4` (wire overlap, superconducting `ZZ` coupler collision $d_{\text{edge}} < 2$, and
   neutral-atom Rydberg blockade overlap $d_{\text{atom}} < r_b$) into a single exclusion-neighborhood
   collision count $\chi(g) = \lvert N_{G_{\text{hw}}}(\mathrm{supp}(e_1)) \cap \mathrm{supp}(e_2) \rvert = 0$.
3. **`Φ3` (`checkPhi3FaultExponent` — Fault-Distance & Exact-Angle Monotonicity $\delta_{\text{fault}}$)**:
   Unifies `P5` (zig-zag vs. hook-aligned stabilizer CNOT distance $d_{\text{eff}} \ge d_{\text{target}}$
   and exact $\mathbb{Z}[1/2^k]$ dyadic vs. `Float64` angle precision) into a single monotone
   fault-suppression exponent grade $\delta_{\text{fault}}(e_1 ; e_2) = \min(\delta_{\text{fault}}(e_1), \delta_{\text{fault}}(e_2))$.
-/

namespace Phase36QPhysGradedResourceSemiringUnificationProofs

-- ============================================================================
-- === Module: PHASE 36 TRACK 1 — UNIFYING `P1–P5` INTO THE 3-RULE PHYSICAL ===
--          RESOURCE SEMIRING `QPhysGrade` (`Φ1–Φ3`, `Theorems 53A–53G`, `Verification Module`)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Section 1: Baseline Hardware Side-Conditions `P1–P5` & Lowering Witness
-- ----------------------------------------------------------------------------

/-- Effective fault distance under hook-aligned vs. zig-zag syndrome CNOT schedules (`effectiveHookCodeDistance`). -/
def effectiveHookCodeDistance (d : Nat) (hookAlignedWithLogical : Bool) : Nat :=
  if hookAlignedWithLogical then (d + 1) / 2 else d

/-- Scaled active decoherence volume $V_{\text{milli}}$ (`computeScaledActiveDecoherenceVolumeMilli` — `P1`). -/
def computeScaledActiveDecoherenceVolumeMilli
    (nQubits circTimeNs t2Ns n2QGates p2QPerMil : Nat) : Nat :=
  if t2Ns == 0 then 999999
  else (nQubits * circTimeNs * 1000) / t2Ns + n2QGates * p2QPerMil

/-- Physical hardware guard `P1` (`checkP1ActiveVolumeBelowBqpCliff`). -/
def checkP1ActiveVolumeBelowBqpCliff
    (nQubits circTimeNs t2Ns n2QGates p2QPerMil : Nat) : Bool :=
  (t2Ns > 0) && (computeScaledActiveDecoherenceVolumeMilli nQubits circTimeNs t2Ns n2QGates p2QPerMil <= 693)

/-- Physical hardware guard `P2` (`checkP2RedexMbuSpectatorCoherenceSafe`). -/
def checkP2RedexMbuSpectatorCoherenceSafe
    (nSpectators tMeasResetNs unitaryEquivBudgetNs : Nat) (hasXy4DdEcho : Bool) : Bool :=
  hasXy4DdEcho || ((2 + nSpectators) * tMeasResetNs <= unitaryEquivBudgetNs)

/-- Extra physical `CX` gates from planar/heavy-hex SWAP routing (`extraPhysicalCxFromCouplingDist` — `P3`). -/
def extraPhysicalCxFromCouplingDist (couplingDistD : Nat) : Nat :=
  if couplingDistD <= 1 then 0 else 6 * (couplingDistD - 1)

/-- Physical hardware guard `P3` (`checkP3RedexCommutationRoutingCostSafe`). -/
def checkP3RedexCommutationRoutingCostSafe
    (couplingDistD abstractGatesSaved : Nat) : Bool :=
  (couplingDistD >= 1) && (extraPhysicalCxFromCouplingDist couplingDistD <= abstractGatesSaved)

/-- Physical hardware guard `P4` (`checkP4RedexParallelCrosstalkAndBlockadeSafe`). -/
def checkP4RedexParallelCrosstalkAndBlockadeSafe
    (logicalWiresDisjoint : Bool) (couplingGraphDist interPairUm blockadeRadiusUm : Nat) : Bool :=
  logicalWiresDisjoint && (couplingGraphDist >= 2) && (interPairUm >= blockadeRadiusUm)

/-- Physical hardware guard `P5` (`checkP5CircuitFuzzerHookAndDyadicSafe`). -/
def checkP5CircuitFuzzerHookAndDyadicSafe
    (codeDistD : Nat) (hookAligned usesFloat64Angles : Bool) (dyadicExpK : Nat) : Bool :=
  (codeDistD >= 3) &&
  (!hookAligned) &&
  (effectiveHookCodeDistance codeDistD hookAligned == codeDistD) &&
  ((!usesFloat64Angles) || (dyadicExpK < 53))

/-- Hardware-Indexed Physical Lowering Witness (`QSubPhysicalLoweringWitness`). -/
structure QSubPhysicalLoweringWitness where
  logicalQSubWellTyped : Bool
  nQubits              : Nat
  circTimeNs           : Nat
  t2Ns                 : Nat
  n2QGates             : Nat
  p2QPerMil            : Nat
  nSpectators          : Nat
  tMeasResetNs         : Nat
  unitaryBudgetNs      : Nat
  hasXy4DdEcho         : Bool
  couplingDistD        : Nat
  abstractGatesSaved   : Nat
  logicalWiresDisjoint : Bool
  interPairGraphDist   : Nat
  interPairUm          : Nat
  blockadeRadiusUm     : Nat
  codeDistD            : Nat
  hookAligned          : Bool
  usesFloat64Angles    : Bool
  dyadicExpK           : Nat
  deriving DecidableEq, Repr

/-- 5-rule physical lowering soundness checker (`checkQSubPhysicalLoweringSound`). -/
def checkQSubPhysicalLoweringSound (w : QSubPhysicalLoweringWitness) : Bool :=
  w.logicalQSubWellTyped &&
  checkP1ActiveVolumeBelowBqpCliff w.nQubits w.circTimeNs w.t2Ns w.n2QGates w.p2QPerMil &&
  checkP2RedexMbuSpectatorCoherenceSafe w.nSpectators w.tMeasResetNs w.unitaryBudgetNs w.hasXy4DdEcho &&
  checkP3RedexCommutationRoutingCostSafe w.couplingDistD w.abstractGatesSaved &&
  checkP4RedexParallelCrosstalkAndBlockadeSafe w.logicalWiresDisjoint w.interPairGraphDist w.interPairUm w.blockadeRadiusUm &&
  checkP5CircuitFuzzerHookAndDyadicSafe w.codeDistD w.hookAligned w.usesFloat64Angles w.dyadicExpK

-- ----------------------------------------------------------------------------
-- Section 2: Ordered Physical-Effect Resource Semiring `QPhysGrade` & Rules `Φ1–Φ3`
-- ----------------------------------------------------------------------------

/-- Extended tropical minimum on `Option Nat` where `none` denotes $\top = +\infty$ (identity circuit `skip`). -/
def minFaultDist (a b : Option Nat) : Option Nat :=
  match a, b with
  | none, y => y
  | x, none => x
  | some d1, some d2 => some (Nat.min d1 d2)

/-- **Physical-Effect Resource Grade (`QPhysGrade`)**:
    Captures the 3 orthogonal physical effect dimensions of a lowered quantum term:
    - `Φ1` ($\nu$): `idleDecoherenceMilli`, `gateInfidelityMilli`, `mbuExcessNs`, `routingExcessCx`,
    - `Φ2` ($\chi$): `exclusionCollisions` ($\lvert N_{G_{\text{hw}}}(\mathrm{supp}(e_1)) \cap \mathrm{supp}(e_2) \rvert$),
    - `Φ3` ($\delta_{\text{fault}}$): `effFaultDist` (monotone min-grade) against `reqTargetDist`. -/
structure QPhysGrade where
  idleDecoherenceMilli : Nat
  gateInfidelityMilli  : Nat
  mbuExcessNs          : Nat
  routingExcessCx      : Nat
  exclusionCollisions  : Nat
  effFaultDist         : Option Nat
  reqTargetDist        : Nat
  deriving DecidableEq, Repr

/-- Identity element `qphysZero` of sequential composition (`skip` / identity morphism). -/
def qphysZero : QPhysGrade :=
  { idleDecoherenceMilli := 0
  , gateInfidelityMilli  := 0
  , mbuExcessNs          := 0
  , routingExcessCx      := 0
  , exclusionCollisions  := 0
  , effFaultDist         := none
  , reqTargetDist        := 0 }

/-- Sequential composition `qphysSeq` ($e_1 ; e_2$): sums Lindblad & collision actions, takes $\min$ of $\delta_{\text{fault}}$. -/
def qphysSeq (g1 g2 : QPhysGrade) : QPhysGrade :=
  { idleDecoherenceMilli := g1.idleDecoherenceMilli + g2.idleDecoherenceMilli
  , gateInfidelityMilli  := g1.gateInfidelityMilli + g2.gateInfidelityMilli
  , mbuExcessNs          := g1.mbuExcessNs + g2.mbuExcessNs
  , routingExcessCx      := g1.routingExcessCx + g2.routingExcessCx
  , exclusionCollisions  := g1.exclusionCollisions + g2.exclusionCollisions
  , effFaultDist         := minFaultDist g1.effFaultDist g2.effFaultDist
  , reqTargetDist        := Nat.max g1.reqTargetDist g2.reqTargetDist }

/-- Branch-choice join `qphysJoin` ($e_1 \oplus e_2$ for `match-part`): upper bound on action, $\min$ on $\delta_{\text{fault}}$. -/
def qphysJoin (g1 g2 : QPhysGrade) : QPhysGrade :=
  { idleDecoherenceMilli := Nat.max g1.idleDecoherenceMilli g2.idleDecoherenceMilli
  , gateInfidelityMilli  := Nat.max g1.gateInfidelityMilli g2.gateInfidelityMilli
  , mbuExcessNs          := Nat.max g1.mbuExcessNs g2.mbuExcessNs
  , routingExcessCx      := Nat.max g1.routingExcessCx g2.routingExcessCx
  , exclusionCollisions  := Nat.max g1.exclusionCollisions g2.exclusionCollisions
  , effFaultDist         := minFaultDist g1.effFaultDist g2.effFaultDist
  , reqTargetDist        := Nat.max g1.reqTargetDist g2.reqTargetDist }

/-- Parallel tensor composition `qphysPar` ($e_1 \otimes_{\parallel} e_2$):
    max-duration idle decoherence + sum-gate-infidelity + hardware exclusion-neighborhood cross-collisions. -/
def qphysPar (crossExclusionHits : Nat) (g1 g2 : QPhysGrade) : QPhysGrade :=
  { idleDecoherenceMilli := Nat.max g1.idleDecoherenceMilli g2.idleDecoherenceMilli
  , gateInfidelityMilli  := g1.gateInfidelityMilli + g2.gateInfidelityMilli
  , mbuExcessNs          := Nat.max g1.mbuExcessNs g2.mbuExcessNs
  , routingExcessCx      := g1.routingExcessCx + g2.routingExcessCx
  , exclusionCollisions  := g1.exclusionCollisions + g2.exclusionCollisions + crossExclusionHits
  , effFaultDist         := minFaultDist g1.effFaultDist g2.effFaultDist
  , reqTargetDist        := Nat.max g1.reqTargetDist g2.reqTargetDist }

/-- Multi-shot / Kralovic checkpoint reset `qphysMultishot` (`multishot(K)`):
    divides coherent active decoherence action across `shotsK >= 1` independent reset epochs. -/
def qphysMultishot (shotsK : Nat) (g : QPhysGrade) : QPhysGrade :=
  if shotsK <= 1 then g
  else
    { g with
      idleDecoherenceMilli := g.idleDecoherenceMilli / shotsK
      gateInfidelityMilli  := g.gateInfidelityMilli / shotsK }

/-- Active circuit decoherence volume $\nu_{\text{vol}}(g) = \nu_{\text{idle}}(g) + \nu_{\text{gate}}(g)$. -/
def activeVolMilli (g : QPhysGrade) : Nat :=
  g.idleDecoherenceMilli + g.gateInfidelityMilli

/-- Total effective Lindblad decoherence action $\nu_{\text{eff}}(g)$ unifying `P1`, `P2`, and `P3`. -/
def effectiveLindbladActionMilli (g : QPhysGrade) : Nat :=
  activeVolMilli g + 700 * (g.mbuExcessNs + g.routingExcessCx)

/-- **Physical Typing Rule `Φ1` (`checkPhi1LindbladGrade`)**:
    Unified Lindblad decoherence action $\nu_{\text{eff}}(g) \le 693 \approx 1000 \ln 2$. -/
def checkPhi1LindbladGrade (g : QPhysGrade) : Bool :=
  effectiveLindbladActionMilli g <= 693

/-- **Physical Typing Rule `Φ2` (`checkPhi2ExclusionDisjoint`)**:
    Hardware exclusion-neighborhood disjointness $\chi(g) = \lvert N_{G_{\text{hw}}}(\mathrm{supp}(e_1)) \cap \mathrm{supp}(e_2) \rvert = 0$. -/
def checkPhi2ExclusionDisjoint (g : QPhysGrade) : Bool :=
  g.exclusionCollisions == 0

/-- **Physical Typing Rule `Φ3` (`checkPhi3FaultExponent`)**:
    Monotone fault-suppression exponent $\delta_{\text{fault}}(g) \ge \max(3, d_{\text{target}}(g))$. -/
def checkPhi3FaultExponent (g : QPhysGrade) : Bool :=
  match g.effFaultDist with
  | none => g.reqTargetDist == 0
  | some dEff => (dEff >= 3) && (dEff >= g.reqTargetDist)

/-- Unified 3-rule `QPhysGrade` physical soundness predicate (`checkQPhysGradeAll3`). -/
def checkQPhysGradeAll3 (g : QPhysGrade) : Bool :=
  checkPhi1LindbladGrade g && checkPhi2ExclusionDisjoint g && checkPhi3FaultExponent g

/-- Exact dyadic vs. IEEE-754 `Float64` angle precision check (`dyadicPrecisionExact`). -/
def dyadicPrecisionExact (usesFloat64Angles : Bool) (dyadicExpK : Nat) : Bool :=
  (!usesFloat64Angles) || (dyadicExpK < 53)

/-- Gate-level fault-suppression distance combining hook schedule and dyadic precision (`computeGateFaultDistance`). -/
def computeGateFaultDistance
    (codeDistD : Nat) (hookAligned usesFloat64Angles : Bool) (dyadicExpK : Nat) : Nat :=
  if dyadicPrecisionExact usesFloat64Angles dyadicExpK then
    effectiveHookCodeDistance codeDistD hookAligned
  else
    0

/-- Canonical grade extraction functor `extractQPhysGrade : QSubPhysicalLoweringWitness → QPhysGrade`. -/
def extractQPhysGrade (w : QSubPhysicalLoweringWitness) : QPhysGrade :=
  let idleVol := if w.t2Ns == 0 then 999999 else (w.nQubits * w.circTimeNs * 1000) / w.t2Ns
  let gateVol := if w.t2Ns == 0 then 0 else w.n2QGates * w.p2QPerMil
  let mbuExc  := if w.hasXy4DdEcho then 0 else (2 + w.nSpectators) * w.tMeasResetNs - w.unitaryBudgetNs
  let rtExc   := (if w.couplingDistD == 0 then 1 else 0) +
                 (extraPhysicalCxFromCouplingDist w.couplingDistD - w.abstractGatesSaved)
  let exclHit := (if w.logicalWiresDisjoint then 0 else 1) +
                 (2 - w.interPairGraphDist) +
                 (w.blockadeRadiusUm - w.interPairUm)
  let dEff    := computeGateFaultDistance w.codeDistD w.hookAligned w.usesFloat64Angles w.dyadicExpK
  { idleDecoherenceMilli := idleVol
  , gateInfidelityMilli  := gateVol
  , mbuExcessNs          := mbuExc
  , routingExcessCx      := rtExc
  , exclusionCollisions  := exclHit
  , effFaultDist         := some dEff
  , reqTargetDist        := Nat.max 3 w.codeDistD }

-- ----------------------------------------------------------------------------
-- Section 3: Inductive Lakefill S-Expression AST & Graded Type Inference
-- ----------------------------------------------------------------------------

/-- Lakefill S-expression quantum circuit AST (`QPhysLakefillTerm`) graded by `QPhysGrade`. -/
inductive QPhysLakefillTerm where
  | skipTerm          : QPhysLakefillTerm
  | cxGate            : Nat → Nat → Nat → QPhysLakefillTerm
  | rzDyadicGate      : Bool → Nat → Nat → QPhysLakefillTerm
  | midMeasXCondZ     : Nat → Nat → Nat → Bool → QPhysLakefillTerm
  | syndromePlaquette : Nat → Bool → Nat → QPhysLakefillTerm
  | seqTerm           : QPhysLakefillTerm → QPhysLakefillTerm → QPhysLakefillTerm
  | parTensor         : Nat → QPhysLakefillTerm → QPhysLakefillTerm → QPhysLakefillTerm
  | withinApply       : QPhysLakefillTerm → QPhysLakefillTerm → QPhysLakefillTerm
  | multishotReset    : Nat → QPhysLakefillTerm → QPhysLakefillTerm
  deriving DecidableEq, Repr

/-- Compositional bidirectional grade synthesis `inferLakefillQPhysGrade` over `QPhysLakefillTerm`. -/
def inferLakefillQPhysGrade : QPhysLakefillTerm → QPhysGrade
  | .skipTerm => qphysZero
  | .cxGate idleMilli p2Q routingDeficit =>
      { idleDecoherenceMilli := idleMilli
      , gateInfidelityMilli  := p2Q
      , mbuExcessNs          := 0
      , routingExcessCx      := routingDeficit
      , exclusionCollisions  := 0
      , effFaultDist         := none
      , reqTargetDist        := 0 }
  | .rzDyadicGate usesFloat64 expK codeDist =>
      { idleDecoherenceMilli := 2
      , gateInfidelityMilli  := 0
      , mbuExcessNs          := 0
      , routingExcessCx      := 0
      , exclusionCollisions  := 0
      , effFaultDist         := some (computeGateFaultDistance codeDist false usesFloat64 expK)
      , reqTargetDist        := Nat.max 3 codeDist }
  | .midMeasXCondZ nSpec tMeas budgetNs hasXy4 =>
      { idleDecoherenceMilli := 8
      , gateInfidelityMilli  := 3
      , mbuExcessNs          := if hasXy4 then 0 else (2 + nSpec) * tMeas - budgetNs
      , routingExcessCx      := 0
      , exclusionCollisions  := 0
      , effFaultDist         := none
      , reqTargetDist        := 0 }
  | .syndromePlaquette codeDist hookAligned p2QSum =>
      { idleDecoherenceMilli := 12
      , gateInfidelityMilli  := p2QSum
      , mbuExcessNs          := 0
      , routingExcessCx      := 0
      , exclusionCollisions  := 0
      , effFaultDist         := some (effectiveHookCodeDistance codeDist hookAligned)
      , reqTargetDist        := Nat.max 3 codeDist }
  | .seqTerm e1 e2 =>
      qphysSeq (inferLakefillQPhysGrade e1) (inferLakefillQPhysGrade e2)
  | .parTensor crossHits e1 e2 =>
      qphysPar crossHits (inferLakefillQPhysGrade e1) (inferLakefillQPhysGrade e2)
  | .withinApply uCompute bBody =>
      let gU := inferLakefillQPhysGrade uCompute
      let gB := inferLakefillQPhysGrade bBody
      qphysSeq gU (qphysSeq gB gU)
  | .multishotReset shotsK body =>
      qphysMultishot shotsK (inferLakefillQPhysGrade body)

-- ----------------------------------------------------------------------------
-- Section 4: Mechanized Theorems `53A–53G` (`<= 30` Lines Per Proof)
-- ----------------------------------------------------------------------------

/-- Helper lemma: `minFaultDist` is associative with two-sided identity `none`. -/
theorem minFaultDist_monoid_laws_helper (a b c : Option Nat) :
    minFaultDist (minFaultDist a b) c = minFaultDist a (minFaultDist b c) ∧
    minFaultDist none a = a ∧
    minFaultDist a none = a := by
  refine ⟨?_, rfl, ?_⟩
  · cases a <;> cases b <;> cases c <;> simp [minFaultDist, Nat.min_assoc]
  · cases a <;> rfl

/-- **Theorem 53A (`qphys_grade_seq_associative_and_identity` — Semiring Monoid & Additivity Laws)**:
    Proves universally over all `g g1 g2 g3 : QPhysGrade` that `(QPhysGrade, qphysSeq, qphysZero)`
    forms an exact monoid (associativity + left/right identity `qphysZero`) and that the unified
    Lindblad action `effectiveLindbladActionMilli` is strictly additive across `qphysSeq`. -/
theorem qphys_grade_seq_associative_and_identity (g g1 g2 g3 : QPhysGrade) :
    qphysSeq (qphysSeq g1 g2) g3 = qphysSeq g1 (qphysSeq g2 g3) ∧
    qphysSeq qphysZero g = g ∧
    qphysSeq g qphysZero = g ∧
    effectiveLindbladActionMilli (qphysSeq g1 g2) =
      effectiveLindbladActionMilli g1 + effectiveLindbladActionMilli g2 := by
  refine ⟨?_, ?_, ?_, ?_⟩
  · cases g1; cases g2; cases g3
    simp [qphysSeq, Nat.add_assoc, Nat.max_assoc, (minFaultDist_monoid_laws_helper _ _ _).1]
  · cases g
    simp [qphysSeq, qphysZero, minFaultDist]
  · obtain ⟨_, _, _, _, _, effD, _⟩ := g
    cases effD <;> simp [qphysSeq, qphysZero, minFaultDist]
  · dsimp [effectiveLindbladActionMilli, activeVolMilli, qphysSeq]
    omega

/-- Helper lemma: active decoherence volume in `extractQPhysGrade` matches `P1` universally. -/
theorem extract_active_vol_eq_p1_vol_helper (w : QSubPhysicalLoweringWitness) :
    activeVolMilli (extractQPhysGrade w) =
      computeScaledActiveDecoherenceVolumeMilli w.nQubits w.circTimeNs w.t2Ns w.n2QGates w.p2QPerMil := by
  unfold activeVolMilli extractQPhysGrade computeScaledActiveDecoherenceVolumeMilli
  cases hT2 : (w.t2Ns == 0) <;> simp

/-- **Theorem 53B (`qphys_phi1_lindblad_grade_iff_p1_p2_p3` — Unified `Φ1` Lindblad Grade ↔ `P1 ∧ P2 ∧ P3`)**:
    Proves universally over all `w : QSubPhysicalLoweringWitness` that `checkPhi1LindbladGrade` on
    `extractQPhysGrade w` is bidirectionally equivalent to the conjunction of `P1`, `P2`, and `P3`. -/
theorem qphys_phi1_lindblad_grade_iff_p1_p2_p3 (w : QSubPhysicalLoweringWitness) :
    (checkPhi1LindbladGrade (extractQPhysGrade w) = true ↔
      (checkP1ActiveVolumeBelowBqpCliff w.nQubits w.circTimeNs w.t2Ns w.n2QGates w.p2QPerMil = true ∧
       checkP2RedexMbuSpectatorCoherenceSafe w.nSpectators w.tMeasResetNs w.unitaryBudgetNs w.hasXy4DdEcho = true ∧
       checkP3RedexCommutationRoutingCostSafe w.couplingDistD w.abstractGatesSaved = true)) := by
  have hVol := extract_active_vol_eq_p1_vol_helper w
  obtain ⟨_, nQ, cT, t2, n2Q, p2Q, nSpec, tM, uBud, xy4, dCoup, gSaved, _, _, _, _, _, _, _, _⟩ := w
  unfold checkPhi1LindbladGrade effectiveLindbladActionMilli
    checkP1ActiveVolumeBelowBqpCliff checkP2RedexMbuSpectatorCoherenceSafe
    checkP3RedexCommutationRoutingCostSafe
  rw [hVol]
  cases t2 with
  | zero =>
      simp [extractQPhysGrade, computeScaledActiveDecoherenceVolumeMilli]; omega
  | succ t2Pred =>
      dsimp only [extractQPhysGrade, extraPhysicalCxFromCouplingDist]
      by_cases hD0 : dCoup = 0 <;> by_cases hD1 : dCoup ≤ 1 <;> cases xy4 <;>
        simp [hD0, hD1] <;> omega

/-- **Theorem 53C (`qphys_phi2_exclusion_graph_iff_p4` — Unified `Φ2` Exclusion Graph ↔ `P4`)**:
    Proves universally over all `w : QSubPhysicalLoweringWitness` that `checkPhi2ExclusionDisjoint`
    ($\chi = 0$) is bidirectionally equivalent to `P4` parallel crosstalk and Rydberg blockade safety. -/
theorem qphys_phi2_exclusion_graph_iff_p4 (w : QSubPhysicalLoweringWitness) :
    (checkPhi2ExclusionDisjoint (extractQPhysGrade w) = true ↔
      checkP4RedexParallelCrosstalkAndBlockadeSafe
        w.logicalWiresDisjoint w.interPairGraphDist w.interPairUm w.blockadeRadiusUm = true) := by
  unfold checkPhi2ExclusionDisjoint extractQPhysGrade checkP4RedexParallelCrosstalkAndBlockadeSafe
  cases w.logicalWiresDisjoint <;> simp <;> omega

/-- **Theorem 53D (`qphys_phi3_fault_exponent_iff_p5` — Unified `Φ3` Fault-Exponent Grade ↔ `P5`)**:
    Proves universally over all `w : QSubPhysicalLoweringWitness` that `checkPhi3FaultExponent`
    ($\delta_{\text{fault}} \ge \max(3, d_{\text{target}})$) is bidirectionally equivalent to `P5`
    hook-distance preservation and exact dyadic rotation synthesis. -/
theorem qphys_phi3_fault_exponent_iff_p5 (w : QSubPhysicalLoweringWitness) :
    (checkPhi3FaultExponent (extractQPhysGrade w) = true ↔
      checkP5CircuitFuzzerHookAndDyadicSafe
        w.codeDistD w.hookAligned w.usesFloat64Angles w.dyadicExpK = true) := by
  unfold checkPhi3FaultExponent extractQPhysGrade computeGateFaultDistance
    dyadicPrecisionExact checkP5CircuitFuzzerHookAndDyadicSafe
  by_cases hExp : w.dyadicExpK < 53 <;> by_cases hD : 3 ≤ w.codeDistD <;>
    cases w.hookAligned <;> cases w.usesFloat64Angles <;>
    simp [effectiveHookCodeDistance, Nat.max_def, hExp, hD] <;> omega

/-- **Theorem 53E (`qphys_3rule_semiring_iff_all5_p1_to_p5_sound` — Master 3-Rule ↔ 5-Rule Equivalence)**:
    Proves universally over all `w : QSubPhysicalLoweringWitness` that logical `QSub` well-typedness
    plus the 3-rule `QPhysGrade` judgment (`Φ1 ∧ Φ2 ∧ Φ3`) holds if and only if the full 5-rule hardware lowering checker `checkQSubPhysicalLoweringSound w` accepts `w`. -/
theorem qphys_3rule_semiring_iff_all5_p1_to_p5_sound (w : QSubPhysicalLoweringWitness) :
    ((w.logicalQSubWellTyped = true ∧ checkQPhysGradeAll3 (extractQPhysGrade w) = true) ↔
      checkQSubPhysicalLoweringSound w = true) ∧
    (w.logicalQSubWellTyped && checkQPhysGradeAll3 (extractQPhysGrade w)) =
      checkQSubPhysicalLoweringSound w := by
  have hiff :
      (w.logicalQSubWellTyped = true ∧ checkQPhysGradeAll3 (extractQPhysGrade w) = true) ↔
        checkQSubPhysicalLoweringSound w = true := by
    unfold checkQPhysGradeAll3 checkQSubPhysicalLoweringSound
    simp only [Bool.and_eq_true, qphys_phi1_lindblad_grade_iff_p1_p2_p3 w,
               qphys_phi2_exclusion_graph_iff_p4 w, qphys_phi3_fault_exponent_iff_p5 w, and_assoc]
  refine ⟨hiff, Bool.eq_iff_iff.mpr ?_⟩
  simp only [Bool.and_eq_true]
  exact hiff

/-- Baseline valid physical lowering witness (`validQPhysWitness`): satisfies all of `Φ1`, `Φ2`, `Φ3`. -/
def validQPhysWitness : QSubPhysicalLoweringWitness :=
  { logicalQSubWellTyped := true
  , nQubits              := 6
  , circTimeNs           := 2208
  , t2Ns                 := 80000
  , n2QGates             := 40
  , p2QPerMil            := 3
  , nSpectators          := 4
  , tMeasResetNs         := 650
  , unitaryBudgetNs      := 1500
  , hasXy4DdEcho         := true
  , couplingDistD        := 1
  , abstractGatesSaved   := 2
  , logicalWiresDisjoint := true
  , interPairGraphDist   := 2
  , interPairUm          := 12
  , blockadeRadiusUm     := 8
  , codeDistD            := 5
  , hookAligned          := false
  , usesFloat64Angles    := false
  , dyadicExpK           := 64 }

/-- Separation witness 1 (`sepPhi1FailWitness`): fails `Φ1` only ($\nu_{\text{eff}} > 693$), passes `Φ2` & `Φ3`. -/
def sepPhi1FailWitness : QSubPhysicalLoweringWitness :=
  { validQPhysWitness with circTimeNs := 9600, n2QGates := 120, hasXy4DdEcho := false }

/-- Separation witness 2 (`sepPhi2FailWitness`): fails `Φ2` only (coupler $d_G = 1 < 2$), passes `Φ1` & `Φ3`. -/
def sepPhi2FailWitness : QSubPhysicalLoweringWitness :=
  { validQPhysWitness with interPairGraphDist := 1, interPairUm := 4 }

/-- Separation witness 3 (`sepPhi3FailWitness`): fails `Φ3` only (hook-aligned $d_{\text{eff}} = 3 < 5$), passes `Φ1` & `Φ2`. -/
def sepPhi3FailWitness : QSubPhysicalLoweringWitness :=
  { validQPhysWitness with hookAligned := true }

/-- **Theorem 53F (`qphys_phi1_phi2_phi3_strict_independence_witnesses` — Strict 3-Rule Minimality)**:
    Exhibits 3 orthogonal separation witnesses proving that none of `Φ1`, `Φ2`, or `Φ3` is redundant:
    each witness satisfies 2 of the 3 `QPhysGrade` rules while failing the 3rd, and is rejected by
    `checkQSubPhysicalLoweringSound`. -/
theorem qphys_phi1_phi2_phi3_strict_independence_witnesses :
    (checkPhi1LindbladGrade (extractQPhysGrade sepPhi1FailWitness) = false ∧
     checkPhi2ExclusionDisjoint (extractQPhysGrade sepPhi1FailWitness) = true ∧
     checkPhi3FaultExponent (extractQPhysGrade sepPhi1FailWitness) = true ∧
     checkQSubPhysicalLoweringSound sepPhi1FailWitness = false) ∧
    (checkPhi1LindbladGrade (extractQPhysGrade sepPhi2FailWitness) = true ∧
     checkPhi2ExclusionDisjoint (extractQPhysGrade sepPhi2FailWitness) = false ∧
     checkPhi3FaultExponent (extractQPhysGrade sepPhi2FailWitness) = true ∧
     checkQSubPhysicalLoweringSound sepPhi2FailWitness = false) ∧
    (checkPhi1LindbladGrade (extractQPhysGrade sepPhi3FailWitness) = true ∧
     checkPhi2ExclusionDisjoint (extractQPhysGrade sepPhi3FailWitness) = true ∧
     checkPhi3FaultExponent (extractQPhysGrade sepPhi3FailWitness) = false ∧
     checkQSubPhysicalLoweringSound sepPhi3FailWitness = false) := by
  decide

/-- Executable (`Module`) sanity suite (`verifyPhase36QPhysSemiringSanity`). -/
def verifyPhase36QPhysSemiringSanity (_ : Unit := ()) : Bool :=
  let gValid := extractQPhysGrade validQPhysWitness
  let unpebbledChain : QPhysLakefillTerm :=
    .seqTerm (.cxGate 380 40 0) (.seqTerm (.cxGate 380 40 0) (.syndromePlaquette 5 false 15))
  let multishotRepaired : QPhysLakefillTerm := .multishotReset 4 unpebbledChain
  let parSafe : QPhysLakefillTerm :=
    .parTensor 0 (.syndromePlaquette 5 false 12) (.rzDyadicGate false 64 5)
  let parCollide : QPhysLakefillTerm :=
    .parTensor 1 (.syndromePlaquette 5 false 12) (.rzDyadicGate false 64 5)
  checkQPhysGradeAll3 gValid &&
  checkQSubPhysicalLoweringSound validQPhysWitness &&
  (qphysSeq qphysZero gValid == gValid) &&
  (qphysSeq gValid qphysZero == gValid) &&
  !(checkPhi1LindbladGrade (inferLakefillQPhysGrade unpebbledChain)) &&
  checkQPhysGradeAll3 (inferLakefillQPhysGrade multishotRepaired) &&
  checkQPhysGradeAll3 (inferLakefillQPhysGrade parSafe) &&
  !(checkPhi2ExclusionDisjoint (inferLakefillQPhysGrade parCollide)) &&
  !(checkPhi1LindbladGrade (extractQPhysGrade sepPhi1FailWitness)) &&
  !(checkPhi2ExclusionDisjoint (extractQPhysGrade sepPhi2FailWitness)) &&
  !(checkPhi3FaultExponent (extractQPhysGrade sepPhi3FailWitness))

/-- **Theorem 53G (`phase36_qphys_semiring_unification_master_closure` — Master Closure `53A–53G`)**:
    Master closure theorem certifying monoid identity & sequential additivity (`53A`), exact 3-rule
    vs. 5-rule bidirectional soundness equivalence (`53B–53E`), 3-way rule independence (`53F`),
    Lakefill `multishotReset` Lindblad volume restoration, and `verifyPhase36QPhysSemiringSanity () = true`. -/
theorem phase36_qphys_semiring_unification_master_closure
    (g1 g2 : QPhysGrade) (w : QSubPhysicalLoweringWitness) :
    qphysSeq qphysZero g1 = g1 ∧
    qphysSeq g1 qphysZero = g1 ∧
    effectiveLindbladActionMilli (qphysSeq g1 g2) =
      effectiveLindbladActionMilli g1 + effectiveLindbladActionMilli g2 ∧
    (w.logicalQSubWellTyped && checkQPhysGradeAll3 (extractQPhysGrade w)) =
      checkQSubPhysicalLoweringSound w ∧
    checkQPhysGradeAll3 (extractQPhysGrade validQPhysWitness) = true ∧
    verifyPhase36QPhysSemiringSanity () = true := by
  exact ⟨(qphys_grade_seq_associative_and_identity g1 g1 g2 g2).2.1,
         (qphys_grade_seq_associative_and_identity g1 g1 g2 g2).2.2.1,
         (qphys_grade_seq_associative_and_identity g1 g1 g2 g2).2.2.2,
         (qphys_3rule_semiring_iff_all5_p1_to_p5_sound w).2,
         by decide,
         by decide⟩

#eval verifyPhase36QPhysSemiringSanity ()

end Phase36QPhysGradedResourceSemiringUnificationProofs
