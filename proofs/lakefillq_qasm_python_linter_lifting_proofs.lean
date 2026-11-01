/-
  LakefillQ Static Bug-Linter & Convex Cluster Sizer: Formal Lifting & Detector Proofs
  =====================================================================================
  Mechanizes the formal foundations of `ae/lakefillq_lint.py` under `LakefillQ`'s
  single unified typing judgment (`Gamma_in |- t : Q_e(A) -| Gamma_out`) and its
  seven projected static rules:
    1. `T-DomImg`     — Read-only input wire preservation & domain-image injectivity
    2. `T-BorrowZ`    — Borrowed `ConstZ` control-wire computational-basis purity
    3. `T-PhaseClean` — Bennet ancilla & relative-phase uncomputation cleanliness
    4. `T-CounitU4`   — `Law U4` modal counit (`M_X + CZ`) & cross-QPU cat-disentanglement
    5. `T-SubNorm`    — Block-encoding subnormalization `alpha >= alpha_req`
    6. `T-QubitCap`   — Single-QPU capacity guard `q_allocated <= Q_cap`
    7. `T-ParGuard`   — Convex `M*` multi-QPU cluster sizing & `M* = 1` fallback
-/

namespace LakefillQQasmPythonLinterLifting

/-- Seven projected static rules of `Gamma_in |- t : Q_e(A) -| Gamma_out`. -/
inductive RuleId where
  | tDomImg     : RuleId
  | tBorrowZ    : RuleId
  | tPhaseClean : RuleId
  | tCounitU4   : RuleId
  | tSubNorm    : RuleId
  | tQubitCap   : RuleId
  | tParGuard   : RuleId
  deriving DecidableEq, Repr

/-- Surface OpenQASM 3.0 / Qiskit gate AST supported by the static lifter. -/
inductive QasmGate where
  | qX               (tgt : Nat) : QasmGate
  | qCX              (ctrl tgt : Nat) : QasmGate
  | qCCX             (c0 c1 tgt : Nat) : QasmGate
  | qH               (tgt : Nat) : QasmGate
  | qZ               (tgt : Nat) : QasmGate
  | qCZ              (c0 c1 : Nat) : QasmGate
  | qRot             (tgt : Nat) (nonBasis : Bool) : QasmGate
  | qMeasX           (tgt : Nat) (hasCzFixup : Bool) (c0 c1 : Nat) : QasmGate
  | qMeasZ           (tgt : Nat) : QasmGate
  | qReset           (tgt : Nat) : QasmGate
  | qRemoteCompute   (ctrlLocal ctrlRemote tgtRemote : Nat) : QasmGate
  | qRemoteUncompute (ctrlLocal ctrlRemote tgtRemote : Nat) : QasmGate
  deriving DecidableEq, Repr

/-- Lifted `LakefillQ` reversible & modal measurement IR (`LiftedRevIR`). -/
inductive LiftedRevIR where
  | irToggle             (tgt : Nat) : LiftedRevIR
  | irXor                (ctrl tgt : Nat) : LiftedRevIR
  | irToffoli            (c0 c1 tgt : Nat) : LiftedRevIR
  | irSuperposeH         (tgt : Nat) : LiftedRevIR
  | irPhaseZ             (tgt : Nat) : LiftedRevIR
  | irPhaseCZ            (c0 c1 : Nat) : LiftedRevIR
  | irAnalogRot          (tgt : Nat) (nonBasis : Bool) : LiftedRevIR
  | irTempAndMx          (tgt : Nat) (hasCzFixup : Bool) (c0 c1 : Nat) : LiftedRevIR
  | irCollapseZ          (tgt : Nat) : LiftedRevIR
  | irResetZero          (tgt : Nat) : LiftedRevIR
  | irRemoteComputeAnd   (ctrlLocal ctrlRemote tgtRemote : Nat) : LiftedRevIR
  | irRemoteUncomputeAnd (ctrlLocal ctrlRemote tgtRemote : Nat) : LiftedRevIR
  | irLawU4LocalMxFixup  (ctrlLocal ctrlRemote tgtRemote : Nat) : LiftedRevIR
  deriving DecidableEq, Repr

/-- Structured violation diagnostics emitted by the 7-rule static analyzer. -/
inductive LintViolation where
  | vDomImgReadonlyMutated      (wire : Nat) : LintViolation
  | vBorrowZBasisPolluted       (wire : Nat) : LintViolation
  | vPhaseCleanDirtyAncilla     (wire : Nat) : LintViolation
  | vCounitU4MissingFixupRemote (wire : Nat) : LintViolation
  | vSubNormAlphaOverflow       (alphaDecl alphaReq : Nat) : LintViolation
  | vQubitCapExceeded           (allocated qCap : Nat) : LintViolation
  | vParGuardSuboptimalM        (requestedM optimalM : Nat) : LintViolation
  deriving DecidableEq, Repr

/-- Maps every `LintViolation` constructor to its projected `RuleId`. -/
def violationRule (v : LintViolation) : RuleId :=
  match v with
  | LintViolation.vDomImgReadonlyMutated _      => RuleId.tDomImg
  | LintViolation.vBorrowZBasisPolluted _       => RuleId.tBorrowZ
  | LintViolation.vPhaseCleanDirtyAncilla _     => RuleId.tPhaseClean
  | LintViolation.vCounitU4MissingFixupRemote _ => RuleId.tCounitU4
  | LintViolation.vSubNormAlphaOverflow _ _     => RuleId.tSubNorm
  | LintViolation.vQubitCapExceeded _ _         => RuleId.tQubitCap
  | LintViolation.vParGuardSuboptimalM _ _      => RuleId.tParGuard

/-- Lifts a single `QasmGate` into `LiftedRevIR`. -/
def liftQasmGate (g : QasmGate) : LiftedRevIR :=
  match g with
  | QasmGate.qX tgt                      => LiftedRevIR.irToggle tgt
  | QasmGate.qCX ctrl tgt                => LiftedRevIR.irXor ctrl tgt
  | QasmGate.qCCX c0 c1 tgt              => LiftedRevIR.irToffoli c0 c1 tgt
  | QasmGate.qH tgt                      => LiftedRevIR.irSuperposeH tgt
  | QasmGate.qZ tgt                      => LiftedRevIR.irPhaseZ tgt
  | QasmGate.qCZ c0 c1                   => LiftedRevIR.irPhaseCZ c0 c1
  | QasmGate.qRot tgt nonBasis           => LiftedRevIR.irAnalogRot tgt nonBasis
  | QasmGate.qMeasX tgt fix c0 c1        => LiftedRevIR.irTempAndMx tgt fix c0 c1
  | QasmGate.qMeasZ tgt                  => LiftedRevIR.irCollapseZ tgt
  | QasmGate.qReset tgt                  => LiftedRevIR.irResetZero tgt
  | QasmGate.qRemoteCompute cL cR tR     => LiftedRevIR.irRemoteComputeAnd cL cR tR
  | QasmGate.qRemoteUncompute cL cR tR   => LiftedRevIR.irRemoteUncomputeAnd cL cR tR

/-- Lifts an OpenQASM / Qiskit gate sequence into `List LiftedRevIR`. -/
def liftQasmCircuit (cs : List QasmGate) : List LiftedRevIR :=
  match cs with
  | []      => []
  | g :: gs => liftQasmGate g :: liftQasmCircuit gs

/-- Computational Z-basis state mapping wire index to `Bool`. -/
abbrev BasisState := Nat → Bool

/-- Functional wire update on `BasisState`. -/
def updWire (st : BasisState) (w : Nat) (val : Bool) : BasisState :=
  fun q => if q == w then val else st q

/-- Surface `QasmGate` computational Z-basis transition semantics. -/
def evalQasmGateBasis (g : QasmGate) (st : BasisState) : BasisState :=
  match g with
  | QasmGate.qX tgt                    => updWire st tgt (!st tgt)
  | QasmGate.qCX ctrl tgt              => updWire st tgt (xor (st tgt) (st ctrl))
  | QasmGate.qCCX c0 c1 tgt            => updWire st tgt (xor (st tgt) (st c0 && st c1))
  | QasmGate.qH _                      => st
  | QasmGate.qZ _                      => st
  | QasmGate.qCZ _ _                   => st
  | QasmGate.qRot _ _                  => st
  | QasmGate.qMeasX tgt _ _ _          => updWire st tgt false
  | QasmGate.qMeasZ _                  => st
  | QasmGate.qReset tgt                => updWire st tgt false
  | QasmGate.qRemoteCompute cL cR tR   => updWire st tR (xor (st tR) (st cL && st cR))
  | QasmGate.qRemoteUncompute cL cR tR => updWire st tR (xor (st tR) (st cL && st cR))

/-- Sequential computational Z-basis evaluation of `List QasmGate`. -/
def evalQasmCircuitBasis (cs : List QasmGate) (st : BasisState) : BasisState :=
  match cs with
  | []      => st
  | g :: gs => evalQasmCircuitBasis gs (evalQasmGateBasis g st)

/-- Lifted `LiftedRevIR` computational Z-basis transition semantics. -/
def evalRevIRBasis (ir : LiftedRevIR) (st : BasisState) : BasisState :=
  match ir with
  | LiftedRevIR.irToggle tgt                    => updWire st tgt (!st tgt)
  | LiftedRevIR.irXor ctrl tgt                  => updWire st tgt (xor (st tgt) (st ctrl))
  | LiftedRevIR.irToffoli c0 c1 tgt             => updWire st tgt (xor (st tgt) (st c0 && st c1))
  | LiftedRevIR.irSuperposeH _                  => st
  | LiftedRevIR.irPhaseZ _                      => st
  | LiftedRevIR.irPhaseCZ _ _                   => st
  | LiftedRevIR.irAnalogRot _ _                 => st
  | LiftedRevIR.irTempAndMx tgt _ _ _           => updWire st tgt false
  | LiftedRevIR.irCollapseZ _                   => st
  | LiftedRevIR.irResetZero tgt                 => updWire st tgt false
  | LiftedRevIR.irRemoteComputeAnd cL cR tR     => updWire st tR (xor (st tR) (st cL && st cR))
  | LiftedRevIR.irRemoteUncomputeAnd cL cR tR   => updWire st tR (xor (st tR) (st cL && st cR))
  | LiftedRevIR.irLawU4LocalMxFixup _ _ tR      => updWire st tR false

/-- Sequential computational Z-basis evaluation of `List LiftedRevIR`. -/
def evalRevIRCircuitBasis (irs : List LiftedRevIR) (st : BasisState) : BasisState :=
  match irs with
  | []        => st
  | ir :: rem => evalRevIRCircuitBasis rem (evalRevIRBasis ir st)

/-- Cross-QPU Bell ebit cost of a surface `QasmGate`. -/
def qasmGateEbits (g : QasmGate) : Nat :=
  match g with
  | QasmGate.qX _                    => 0
  | QasmGate.qCX _ _                 => 0
  | QasmGate.qCCX _ _ _              => 0
  | QasmGate.qH _                    => 0
  | QasmGate.qZ _                    => 0
  | QasmGate.qCZ _ _                 => 0
  | QasmGate.qRot _ _                => 0
  | QasmGate.qMeasX _ _ _ _          => 0
  | QasmGate.qMeasZ _                => 0
  | QasmGate.qReset _                => 0
  | QasmGate.qRemoteCompute _ _ _    => 1
  | QasmGate.qRemoteUncompute _ _ _  => 1

/-- Total Bell ebit cost across `List QasmGate`. -/
def qasmCircuitEbits (cs : List QasmGate) : Nat :=
  match cs with
  | []      => 0
  | g :: gs => qasmGateEbits g + qasmCircuitEbits gs

/-- Cross-QPU Bell ebit cost of a `LiftedRevIR` node (`Law U4` local `M_X` costs `0` ebits). -/
def revIREbits (ir : LiftedRevIR) : Nat :=
  match ir with
  | LiftedRevIR.irToggle _                    => 0
  | LiftedRevIR.irXor _ _                     => 0
  | LiftedRevIR.irToffoli _ _ _               => 0
  | LiftedRevIR.irSuperposeH _                => 0
  | LiftedRevIR.irPhaseZ _                    => 0
  | LiftedRevIR.irPhaseCZ _ _                 => 0
  | LiftedRevIR.irAnalogRot _ _               => 0
  | LiftedRevIR.irTempAndMx _ _ _ _           => 0
  | LiftedRevIR.irCollapseZ _                 => 0
  | LiftedRevIR.irResetZero _                 => 0
  | LiftedRevIR.irRemoteComputeAnd _ _ _      => 1
  | LiftedRevIR.irRemoteUncomputeAnd _ _ _    => 1
  | LiftedRevIR.irLawU4LocalMxFixup _ _ _     => 0

/-- Total Bell ebit cost across `List LiftedRevIR`. -/
def revIRCircuitEbits (irs : List LiftedRevIR) : Nat :=
  match irs with
  | []        => 0
  | ir :: rem => revIREbits ir + revIRCircuitEbits rem

/-- **Theorem 1 (`liftQasmCircuit_append`)**:
    `liftQasmCircuit` is an exact list homomorphism over `List QasmGate` concatenation. -/
theorem liftQasmCircuit_append (c1 c2 : List QasmGate) :
    liftQasmCircuit (c1 ++ c2) = liftQasmCircuit c1 ++ liftQasmCircuit c2 := by
  induction c1 with
  | nil => rfl
  | cons g gs ih =>
    simp only [List.cons_append, liftQasmCircuit, ih]

/-- **Theorem 2 (`liftQasmGate_basis_sound`)**:
    Single-gate lifting preserves computational Z-basis transition semantics for every `QasmGate`. -/
theorem liftQasmGate_basis_sound (g : QasmGate) (st : BasisState) :
    evalRevIRBasis (liftQasmGate g) st = evalQasmGateBasis g st := by
  cases g with
  | qX tgt => rfl
  | qCX ctrl tgt => rfl
  | qCCX c0 c1 tgt => rfl
  | qH tgt => rfl
  | qZ tgt => rfl
  | qCZ c0 c1 => rfl
  | qRot tgt nonBasis => rfl
  | qMeasX tgt fix c0 c1 => rfl
  | qMeasZ tgt => rfl
  | qReset tgt => rfl
  | qRemoteCompute cL cR tR => rfl
  | qRemoteUncompute cL cR tR => rfl

/-- **Theorem 3 (`liftQasmCircuit_basis_sound`)**:
    Circuit-wide lifting from `List QasmGate` to `List LiftedRevIR` preserves computational
    Z-basis semantics across arbitrary initial states. -/
theorem liftQasmCircuit_basis_sound (cs : List QasmGate) (st : BasisState) :
    evalRevIRCircuitBasis (liftQasmCircuit cs) st = evalQasmCircuitBasis cs st := by
  induction cs generalizing st with
  | nil => rfl
  | cons g gs ih =>
    simp only [liftQasmCircuit, evalRevIRCircuitBasis, evalQasmCircuitBasis]
    rw [liftQasmGate_basis_sound]
    exact ih (evalQasmGateBasis g st)

/-- **Theorem 4 (`liftQasmCircuit_ebits_preserved`)**:
    Lifting `List QasmGate` to `List LiftedRevIR` preserves exact cross-QPU Bell ebit counts. -/
theorem liftQasmCircuit_ebits_preserved (cs : List QasmGate) :
    revIRCircuitEbits (liftQasmCircuit cs) = qasmCircuitEbits cs := by
  induction cs with
  | nil => rfl
  | cons g gs ih =>
    cases g <;> simp only [liftQasmCircuit, liftQasmGate, revIRCircuitEbits, qasmCircuitEbits,
      revIREbits, qasmGateEbits, ih]

/-! ## Static Detectors for the Seven Projected `LakefillQ` Rules -/

/-- Specification context for `LakefillQ`'s 7 static rules. -/
structure LintContext where
  readonlyWire      : Nat
  borrowedZWire     : Nat
  ancillaWire       : Nat
  alphaDeclared     : Nat
  alphaRequired     : Nat
  allocatedQubits   : Nat
  qCap              : Nat
  requestedMachines : Nat
  optimalMachines   : Nat
  deriving DecidableEq, Repr

/-- Rule 1 (`T-DomImg`) per-node detector: checks whether wire `w` is a mutation target. -/
def mutatesWireIR (w : Nat) (ir : LiftedRevIR) : Bool :=
  match ir with
  | LiftedRevIR.irToggle tgt                    => tgt == w
  | LiftedRevIR.irXor _ tgt                     => tgt == w
  | LiftedRevIR.irToffoli _ _ tgt               => tgt == w
  | LiftedRevIR.irSuperposeH tgt                => tgt == w
  | LiftedRevIR.irPhaseZ _                      => false
  | LiftedRevIR.irPhaseCZ _ _                   => false
  | LiftedRevIR.irAnalogRot tgt _               => tgt == w
  | LiftedRevIR.irTempAndMx tgt _ _ _           => tgt == w
  | LiftedRevIR.irCollapseZ tgt                 => tgt == w
  | LiftedRevIR.irResetZero tgt                 => tgt == w
  | LiftedRevIR.irRemoteComputeAnd _ _ tR       => tR == w
  | LiftedRevIR.irRemoteUncomputeAnd _ _ tR     => tR == w
  | LiftedRevIR.irLawU4LocalMxFixup _ _ tR      => tR == w

/-- Rule 1 (`T-DomImg`) circuit-wide read-only wire mutation detector. -/
def mutatesWireList (w : Nat) (irs : List LiftedRevIR) : Bool :=
  match irs with
  | []        => false
  | ir :: rem => mutatesWireIR w ir || mutatesWireList w rem

/-- Rule 2 (`T-BorrowZ`) per-node detector: checks basis-polluting gates on borrowed `ConstZ` wire `w`. -/
def pollutesBorrowZIR (w : Nat) (ir : LiftedRevIR) : Bool :=
  match ir with
  | LiftedRevIR.irToggle _                      => false
  | LiftedRevIR.irXor _ _                       => false
  | LiftedRevIR.irToffoli _ _ _                 => false
  | LiftedRevIR.irSuperposeH tgt                => tgt == w
  | LiftedRevIR.irPhaseZ _                      => false
  | LiftedRevIR.irPhaseCZ _ _                   => false
  | LiftedRevIR.irAnalogRot tgt nonBasis        => (tgt == w) && nonBasis
  | LiftedRevIR.irTempAndMx tgt _ _ _           => tgt == w
  | LiftedRevIR.irCollapseZ tgt                 => tgt == w
  | LiftedRevIR.irResetZero tgt                 => tgt == w
  | LiftedRevIR.irRemoteComputeAnd _ _ _        => false
  | LiftedRevIR.irRemoteUncomputeAnd _ _ _      => false
  | LiftedRevIR.irLawU4LocalMxFixup _ _ _       => false

/-- Rule 2 (`T-BorrowZ`) circuit-wide detector on borrowed `ConstZ` wire `w`. -/
def pollutesBorrowZList (w : Nat) (irs : List LiftedRevIR) : Bool :=
  match irs with
  | []        => false
  | ir :: rem => pollutesBorrowZIR w ir || pollutesBorrowZList w rem

/-- Rule 3 (`T-PhaseClean`) ancilla cleanliness detector on witness state `probeSt`. -/
def leavesDirtyAncilla (w : Nat) (probeSt : BasisState) (irs : List LiftedRevIR) : Bool :=
  evalRevIRCircuitBasis irs probeSt w

/-- Rule 4 (`T-CounitU4`) per-node detector: catches uncompensated `M_X` or remote cat-uncompute. -/
def hasCounitU4HazardIR (ir : LiftedRevIR) : Option Nat :=
  match ir with
  | LiftedRevIR.irToggle _                      => none
  | LiftedRevIR.irXor _ _                       => none
  | LiftedRevIR.irToffoli _ _ _                 => none
  | LiftedRevIR.irSuperposeH _                  => none
  | LiftedRevIR.irPhaseZ _                      => none
  | LiftedRevIR.irPhaseCZ _ _                   => none
  | LiftedRevIR.irAnalogRot _ _                 => none
  | LiftedRevIR.irTempAndMx tgt hasFix _ _      =>
      match hasFix with
      | true  => none
      | false => some tgt
  | LiftedRevIR.irCollapseZ _                   => none
  | LiftedRevIR.irResetZero _                   => none
  | LiftedRevIR.irRemoteComputeAnd _ _ _        => none
  | LiftedRevIR.irRemoteUncomputeAnd _ _ tR     => some tR
  | LiftedRevIR.irLawU4LocalMxFixup _ _ _       => none

/-- Rule 4 (`T-CounitU4`) circuit-wide detector returning the first offending target wire if any. -/
def findCounitU4HazardList (irs : List LiftedRevIR) : Option Nat :=
  match irs with
  | []        => none
  | ir :: rem =>
      match hasCounitU4HazardIR ir with
      | some w => some w
      | none   => findCounitU4HazardList rem

/-- Unified 7-rule static linter over `LintContext`, witness `BasisState`, and `List LiftedRevIR`. -/
def lintRevIR (ctx : LintContext) (probeSt : BasisState) (irs : List LiftedRevIR) :
    List LintViolation :=
  let r1 := if mutatesWireList ctx.readonlyWire irs then
              [LintViolation.vDomImgReadonlyMutated ctx.readonlyWire] else []
  let r2 := if pollutesBorrowZList ctx.borrowedZWire irs then
              [LintViolation.vBorrowZBasisPolluted ctx.borrowedZWire] else []
  let r3 := if leavesDirtyAncilla ctx.ancillaWire probeSt irs then
              [LintViolation.vPhaseCleanDirtyAncilla ctx.ancillaWire] else []
  let r4 := match findCounitU4HazardList irs with
            | some w => [LintViolation.vCounitU4MissingFixupRemote w]
            | none   => []
  let r5 := if decide (ctx.alphaDeclared < ctx.alphaRequired) then
              [LintViolation.vSubNormAlphaOverflow ctx.alphaDeclared ctx.alphaRequired] else []
  let r6 := if decide (ctx.qCap < ctx.allocatedQubits) then
              [LintViolation.vQubitCapExceeded ctx.allocatedQubits ctx.qCap] else []
  let r7 := if decide (ctx.requestedMachines != ctx.optimalMachines) then
              [LintViolation.vParGuardSuboptimalM ctx.requestedMachines ctx.optimalMachines] else []
  r1 ++ r2 ++ r3 ++ r4 ++ r5 ++ r6 ++ r7

/-- Helper lemma: single `LiftedRevIR` step preserves wire `w` if `mutatesWireIR w ir = false`. -/
theorem evalRevIRBasis_preserves_unmutated (ir : LiftedRevIR) (st : BasisState) (w : Nat)
    (h : mutatesWireIR w ir = false) :
    evalRevIRBasis ir st w = st w := by
  cases ir with
  | irSuperposeH _ | irPhaseZ _ | irPhaseCZ _ _ | irAnalogRot _ _ | irCollapseZ _ => rfl
  | irToggle t | irXor _ t | irToffoli _ _ t | irTempAndMx t _ _ _
  | irResetZero t | irRemoteComputeAnd _ _ t | irRemoteUncomputeAnd _ _ t
  | irLawU4LocalMxFixup _ _ t =>
    simp only [mutatesWireIR, beq_eq_false_iff_ne] at h
    have hw : (w == t) = false := beq_eq_false_iff_ne.mpr (Ne.symm h)
    simp only [evalRevIRBasis, updWire, hw]; rfl

/-- **Theorem 5 (`readonly_wire_preserved_when_unmutated`)**:
    Rule 1 (`T-DomImg`) semantic soundness: whenever `mutatesWireList w irs = false`,
    executing `irs` preserves `st w` across every input basis state `st`. -/
theorem readonly_wire_preserved_when_unmutated (irs : List LiftedRevIR) (st : BasisState) (w : Nat)
    (h : mutatesWireList w irs = false) :
    evalRevIRCircuitBasis irs st w = st w := by
  induction irs generalizing st with
  | nil => rfl
  | cons ir rem ih =>
    simp only [mutatesWireList, Bool.or_eq_false_iff] at h
    simp only [evalRevIRCircuitBasis]
    rw [ih (evalRevIRBasis ir st) h.2]
    exact evalRevIRBasis_preserves_unmutated ir st w h.1

/-- Inductive violation witness predicate covering all 7 `LakefillQ` projected rules. -/
inductive RuleHazardWitness : RuleId → LintContext → BasisState → List LiftedRevIR → Prop where
  | wDomImg (ctx : LintContext) (st : BasisState) (irs : List LiftedRevIR)
      (h : mutatesWireList ctx.readonlyWire irs = true) :
      RuleHazardWitness RuleId.tDomImg ctx st irs
  | wBorrowZ (ctx : LintContext) (st : BasisState) (irs : List LiftedRevIR)
      (h : pollutesBorrowZList ctx.borrowedZWire irs = true) :
      RuleHazardWitness RuleId.tBorrowZ ctx st irs
  | wPhaseClean (ctx : LintContext) (st : BasisState) (irs : List LiftedRevIR)
      (h : leavesDirtyAncilla ctx.ancillaWire st irs = true) :
      RuleHazardWitness RuleId.tPhaseClean ctx st irs
  | wCounitU4 (ctx : LintContext) (st : BasisState) (irs : List LiftedRevIR) (w : Nat)
      (h : findCounitU4HazardList irs = some w) :
      RuleHazardWitness RuleId.tCounitU4 ctx st irs
  | wSubNorm (ctx : LintContext) (st : BasisState) (irs : List LiftedRevIR)
      (h : ctx.alphaDeclared < ctx.alphaRequired) :
      RuleHazardWitness RuleId.tSubNorm ctx st irs
  | wQubitCap (ctx : LintContext) (st : BasisState) (irs : List LiftedRevIR)
      (h : ctx.qCap < ctx.allocatedQubits) :
      RuleHazardWitness RuleId.tQubitCap ctx st irs
  | wParGuard (ctx : LintContext) (st : BasisState) (irs : List LiftedRevIR)
      (h : ctx.requestedMachines ≠ ctx.optimalMachines) :
      RuleHazardWitness RuleId.tParGuard ctx st irs

/-- **Theorem 6 (`detector_complete_all_seven_rules`)**:
    Static detector completeness: every `RuleHazardWitness` across all 7 `LakefillQ` rules
    produces a concrete `LintViolation` in `lintRevIR` tagged with that exact `RuleId`. -/
theorem detector_complete_all_seven_rules
    (r : RuleId) (ctx : LintContext) (probeSt : BasisState) (irs : List LiftedRevIR)
    (hw : RuleHazardWitness r ctx probeSt irs) :
    ∃ v ∈ lintRevIR ctx probeSt irs, violationRule v = r := by
  cases hw with
  | wDomImg _ _ _ h =>
    refine ⟨LintViolation.vDomImgReadonlyMutated ctx.readonlyWire, ?_, rfl⟩
    simp [lintRevIR, h]
  | wBorrowZ _ _ _ h =>
    refine ⟨LintViolation.vBorrowZBasisPolluted ctx.borrowedZWire, ?_, rfl⟩
    simp [lintRevIR, h]
  | wPhaseClean _ _ _ h =>
    refine ⟨LintViolation.vPhaseCleanDirtyAncilla ctx.ancillaWire, ?_, rfl⟩
    simp [lintRevIR, h]
  | wCounitU4 _ _ _ w h =>
    refine ⟨LintViolation.vCounitU4MissingFixupRemote w, ?_, rfl⟩
    simp [lintRevIR, h]
  | wSubNorm _ _ _ h =>
    refine ⟨LintViolation.vSubNormAlphaOverflow ctx.alphaDeclared ctx.alphaRequired, ?_, rfl⟩
    simp [lintRevIR, h]
  | wQubitCap _ _ _ h =>
    refine ⟨LintViolation.vQubitCapExceeded ctx.allocatedQubits ctx.qCap, ?_, rfl⟩
    simp [lintRevIR, h]
  | wParGuard _ _ _ h =>
    refine ⟨LintViolation.vParGuardSuboptimalM ctx.requestedMachines ctx.optimalMachines, ?_, rfl⟩
    simp [lintRevIR, bne_iff_ne, h]

/-- **Theorem 7 (`detector_sound_clean_implies_all_seven_invariants`)**:
    Unified static soundness: when `lintRevIR ctx probeSt irs = []`, all 7 projected `LakefillQ`
    safety invariants hold simultaneously on `(ctx, probeSt, irs)`. -/
theorem detector_sound_clean_implies_all_seven_invariants
    (ctx : LintContext) (probeSt : BasisState) (irs : List LiftedRevIR)
    (hclean : lintRevIR ctx probeSt irs = []) :
    mutatesWireList ctx.readonlyWire irs = false ∧
    pollutesBorrowZList ctx.borrowedZWire irs = false ∧
    leavesDirtyAncilla ctx.ancillaWire probeSt irs = false ∧
    findCounitU4HazardList irs = none ∧
    ctx.alphaRequired ≤ ctx.alphaDeclared ∧
    ctx.allocatedQubits ≤ ctx.qCap ∧
    ctx.requestedMachines = ctx.optimalMachines := by
  dsimp only [lintRevIR] at hclean
  simp only [List.append_eq_nil_iff] at hclean
  rcases hclean with ⟨⟨⟨⟨⟨⟨h1, h2⟩, h3⟩, h4⟩, h5⟩, h6⟩, h7⟩
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · cases hm : mutatesWireList ctx.readonlyWire irs <;> simp_all
  · cases hb : pollutesBorrowZList ctx.borrowedZWire irs <;> simp_all
  · cases hp : leavesDirtyAncilla ctx.ancillaWire probeSt irs <;> simp_all
  · cases hc : findCounitU4HazardList irs <;> simp_all
  · by_cases ha : ctx.alphaDeclared < ctx.alphaRequired <;> simp_all
  · by_cases hq : ctx.qCap < ctx.allocatedQubits <;> simp_all
  · by_cases hm : ctx.requestedMachines = ctx.optimalMachines <;> simp_all [bne_iff_ne]

/-! ## Bennet Symmetric Uncomputation (`Law U1`) & `Law U4` Counit Rewrite Soundness -/

/-- Pure classical reversible fragment (`X`, `CX`, `CCX`) with distinct control/target wires. -/
inductive PureClassicalGate where
  | pNot     (tgt : Nat) : PureClassicalGate
  | pXor     (ctrl tgt : Nat) (hne : ctrl ≠ tgt) : PureClassicalGate
  | pToffoli (c0 c1 tgt : Nat) (h0 : c0 ≠ tgt) (h1 : c1 ≠ tgt) : PureClassicalGate

/-- Lifts a `PureClassicalGate` to `LiftedRevIR`. -/
def liftPureGate (g : PureClassicalGate) : LiftedRevIR :=
  match g with
  | PureClassicalGate.pNot tgt             => LiftedRevIR.irToggle tgt
  | PureClassicalGate.pXor ctrl tgt _      => LiftedRevIR.irXor ctrl tgt
  | PureClassicalGate.pToffoli c0 c1 tgt _ _ => LiftedRevIR.irToffoli c0 c1 tgt

/-- Forward Bennet compute pass over `List PureClassicalGate`. -/
def liftPureForward (gs : List PureClassicalGate) : List LiftedRevIR :=
  match gs with
  | []      => []
  | g :: rem => liftPureGate g :: liftPureForward rem

/-- Reverse Bennet uncompute pass over `List PureClassicalGate`. -/
def liftPureReverse (gs : List PureClassicalGate) : List LiftedRevIR :=
  match gs with
  | []      => []
  | g :: rem => liftPureReverse rem ++ [liftPureGate g]

/-- Single `PureClassicalGate` is involutory on every wire `q` of `BasisState`. -/
theorem liftPureGate_involutive (g : PureClassicalGate) (st : BasisState) (q : Nat) :
    evalRevIRBasis (liftPureGate g) (evalRevIRBasis (liftPureGate g) st) q = st q := by
  cases g with
  | pNot tgt =>
    by_cases hq : q = tgt <;> simp [liftPureGate, evalRevIRBasis, updWire, hq]
  | pXor ctrl tgt hne =>
    have hct : (ctrl == tgt) = false := beq_eq_false_iff_ne.mpr hne
    by_cases hq : q = tgt <;> simp [liftPureGate, evalRevIRBasis, updWire, hq, hct]
  | pToffoli c0 c1 tgt h0 h1 =>
    have hc0 : (c0 == tgt) = false := beq_eq_false_iff_ne.mpr h0
    have hc1 : (c1 == tgt) = false := beq_eq_false_iff_ne.mpr h1
    by_cases hq : q = tgt <;> simp [liftPureGate, evalRevIRBasis, updWire, hq, hc0, hc1]

/-- Sequential evaluation distributes over `List LiftedRevIR` concatenation. -/
theorem evalRevIRCircuitBasis_append (xs ys : List LiftedRevIR) (st : BasisState) :
    evalRevIRCircuitBasis (xs ++ ys) st = evalRevIRCircuitBasis ys (evalRevIRCircuitBasis xs st) := by
  induction xs generalizing st with
  | nil => rfl
  | cons x rem ih =>
    simp only [List.cons_append, evalRevIRCircuitBasis]
    exact ih (evalRevIRBasis x st)

/-- **Theorem 8 (`bennet_compute_uncompute_restores_all_wires`)**:
    Symmetric Bennet compute-then-uncompute (`liftPureForward gs ++ liftPureReverse gs`)
    restores every input and ancilla wire `q` to its exact initial basis value `st q`. -/
theorem bennet_compute_uncompute_restores_all_wires
    (gs : List PureClassicalGate) (st : BasisState) (q : Nat) :
    evalRevIRCircuitBasis (liftPureForward gs ++ liftPureReverse gs) st q = st q := by
  induction gs generalizing st q with
  | nil => rfl
  | cons g rem ih =>
    simp only [liftPureForward, liftPureReverse, List.cons_append]
    rw [evalRevIRCircuitBasis, ← List.append_assoc, evalRevIRCircuitBasis_append]
    have hmid : evalRevIRCircuitBasis (liftPureForward rem ++ liftPureReverse rem)
        (evalRevIRBasis (liftPureGate g) st) = evalRevIRBasis (liftPureGate g) st := by
      funext w; exact ih (evalRevIRBasis (liftPureGate g) st) w
    rw [hmid]
    exact liftPureGate_involutive g st q

/-- Counts redundant cross-QPU `irRemoteUncomputeAnd` operations in `List LiftedRevIR`. -/
def countRemoteUncompute (irs : List LiftedRevIR) : Nat :=
  match irs with
  | []        => 0
  | ir :: rem =>
      match ir with
      | LiftedRevIR.irToggle _                    => countRemoteUncompute rem
      | LiftedRevIR.irXor _ _                     => countRemoteUncompute rem
      | LiftedRevIR.irToffoli _ _ _               => countRemoteUncompute rem
      | LiftedRevIR.irSuperposeH _                => countRemoteUncompute rem
      | LiftedRevIR.irPhaseZ _                    => countRemoteUncompute rem
      | LiftedRevIR.irPhaseCZ _ _                 => countRemoteUncompute rem
      | LiftedRevIR.irAnalogRot _ _               => countRemoteUncompute rem
      | LiftedRevIR.irTempAndMx _ _ _ _           => countRemoteUncompute rem
      | LiftedRevIR.irCollapseZ _                 => countRemoteUncompute rem
      | LiftedRevIR.irResetZero _                 => countRemoteUncompute rem
      | LiftedRevIR.irRemoteComputeAnd _ _ _      => countRemoteUncompute rem
      | LiftedRevIR.irRemoteUncomputeAnd _ _ _    => 1 + countRemoteUncompute rem
      | LiftedRevIR.irLawU4LocalMxFixup _ _ _     => countRemoteUncompute rem

/-- Rewrites every cross-QPU `irRemoteUncomputeAnd` into zero-ebit `irLawU4LocalMxFixup`. -/
def rewriteRemoteUncomputeToLawU4 (irs : List LiftedRevIR) : List LiftedRevIR :=
  match irs with
  | []        => []
  | ir :: rem =>
      let head' :=
        match ir with
        | LiftedRevIR.irToggle tgt                  => LiftedRevIR.irToggle tgt
        | LiftedRevIR.irXor ctrl tgt                => LiftedRevIR.irXor ctrl tgt
        | LiftedRevIR.irToffoli c0 c1 tgt           => LiftedRevIR.irToffoli c0 c1 tgt
        | LiftedRevIR.irSuperposeH tgt              => LiftedRevIR.irSuperposeH tgt
        | LiftedRevIR.irPhaseZ tgt                  => LiftedRevIR.irPhaseZ tgt
        | LiftedRevIR.irPhaseCZ c0 c1               => LiftedRevIR.irPhaseCZ c0 c1
        | LiftedRevIR.irAnalogRot tgt nb            => LiftedRevIR.irAnalogRot tgt nb
        | LiftedRevIR.irTempAndMx tgt fx c0 c1      => LiftedRevIR.irTempAndMx tgt fx c0 c1
        | LiftedRevIR.irCollapseZ tgt               => LiftedRevIR.irCollapseZ tgt
        | LiftedRevIR.irResetZero tgt               => LiftedRevIR.irResetZero tgt
        | LiftedRevIR.irRemoteComputeAnd cL cR tR   => LiftedRevIR.irRemoteComputeAnd cL cR tR
        | LiftedRevIR.irRemoteUncomputeAnd cL cR tR => LiftedRevIR.irLawU4LocalMxFixup cL cR tR
        | LiftedRevIR.irLawU4LocalMxFixup cL cR tR  => LiftedRevIR.irLawU4LocalMxFixup cL cR tR
      head' :: rewriteRemoteUncomputeToLawU4 rem

/-- **Theorem 9 (`law_u4_rewrite_eliminates_remote_uncompute`)**:
    Applying `rewriteRemoteUncomputeToLawU4` eliminates 100% of cross-QPU `irRemoteUncomputeAnd` nodes. -/
theorem law_u4_rewrite_eliminates_remote_uncompute (irs : List LiftedRevIR) :
    countRemoteUncompute (rewriteRemoteUncomputeToLawU4 irs) = 0 := by
  induction irs with
  | nil => rfl
  | cons ir rem ih =>
    cases ir <;> simp only [rewriteRemoteUncomputeToLawU4, countRemoteUncompute, ih]

/-- **Theorem 10 (`law_u4_rewrite_exact_ebit_savings`)**:
    `rewriteRemoteUncomputeToLawU4` reduces total cross-QPU Bell ebit consumption by
    `countRemoteUncompute irs`. -/
theorem law_u4_rewrite_exact_ebit_savings (irs : List LiftedRevIR) :
    revIRCircuitEbits (rewriteRemoteUncomputeToLawU4 irs) + countRemoteUncompute irs =
      revIRCircuitEbits irs := by
  induction irs with
  | nil => rfl
  | cons ir rem ih =>
    cases ir <;> simp only [rewriteRemoteUncomputeToLawU4, revIRCircuitEbits, revIREbits,
      countRemoteUncompute] <;> omega

/-- **Theorem 11 (`law_u4_pair_preserves_clean_ancilla_basis_semantics`)**:
    For any remote `TempAND` pair initialized on clean ancilla `st tR = false` (`cL ≠ tR`, `cR ≠ tR`),
    replacing `irRemoteUncomputeAnd` with `irLawU4LocalMxFixup` yields identical Z-basis states
    across any continuation `rest : List LiftedRevIR` while saving 1 cross-QPU Bell ebit. -/
theorem law_u4_pair_preserves_clean_ancilla_basis_semantics
    (cL cR tR : Nat) (rest : List LiftedRevIR) (st : BasisState)
    (hcL : cL ≠ tR) (hcR : cR ≠ tR) (hclean : st tR = false) :
    evalRevIRCircuitBasis
      (LiftedRevIR.irRemoteComputeAnd cL cR tR :: LiftedRevIR.irLawU4LocalMxFixup cL cR tR :: rest) st =
    evalRevIRCircuitBasis
      (LiftedRevIR.irRemoteComputeAnd cL cR tR :: LiftedRevIR.irRemoteUncomputeAnd cL cR tR :: rest) st ∧
    revIRCircuitEbits
      (LiftedRevIR.irRemoteComputeAnd cL cR tR :: LiftedRevIR.irLawU4LocalMxFixup cL cR tR :: rest) + 1 =
    revIRCircuitEbits
      (LiftedRevIR.irRemoteComputeAnd cL cR tR :: LiftedRevIR.irRemoteUncomputeAnd cL cR tR :: rest) := by
  refine ⟨?_, ?_⟩
  · simp only [evalRevIRCircuitBasis, evalRevIRBasis]
    congr 1; funext q
    have bL : (cL == tR) = false := beq_eq_false_iff_ne.mpr hcL
    have bR : (cR == tR) = false := beq_eq_false_iff_ne.mpr hcR
    by_cases hq : q = tR <;> simp [updWire, hq, bL, bR, hclean]
  · simp only [revIRCircuitEbits, revIREbits]; omega

/-- Counts uncompensated `M_X` quadratic phase taints in `List LiftedRevIR`. -/
def countUncompensatedPhaseTaint (irs : List LiftedRevIR) : Nat :=
  match irs with
  | []        => 0
  | ir :: rem =>
      match ir with
      | LiftedRevIR.irToggle _                    => countUncompensatedPhaseTaint rem
      | LiftedRevIR.irXor _ _                     => countUncompensatedPhaseTaint rem
      | LiftedRevIR.irToffoli _ _ _               => countUncompensatedPhaseTaint rem
      | LiftedRevIR.irSuperposeH _                => countUncompensatedPhaseTaint rem
      | LiftedRevIR.irPhaseZ _                    => countUncompensatedPhaseTaint rem
      | LiftedRevIR.irPhaseCZ _ _                 => countUncompensatedPhaseTaint rem
      | LiftedRevIR.irAnalogRot _ _               => countUncompensatedPhaseTaint rem
      | LiftedRevIR.irTempAndMx _ hasFix _ _      =>
          match hasFix with
          | true  => countUncompensatedPhaseTaint rem
          | false => 1 + countUncompensatedPhaseTaint rem
      | LiftedRevIR.irCollapseZ _                 => countUncompensatedPhaseTaint rem
      | LiftedRevIR.irResetZero _                 => countUncompensatedPhaseTaint rem
      | LiftedRevIR.irRemoteComputeAnd _ _ _      => countUncompensatedPhaseTaint rem
      | LiftedRevIR.irRemoteUncomputeAnd _ _ _    => countUncompensatedPhaseTaint rem
      | LiftedRevIR.irLawU4LocalMxFixup _ _ _     => countUncompensatedPhaseTaint rem

/-- **Theorem 12 (`law_u4_rewrite_preserves_zero_phase_taint_and_clears_counit_detector`)**:
    Whenever `irs` has zero uncompensated `M_X` phase taints, `rewriteRemoteUncomputeToLawU4 irs`
    introduces zero phase taints AND satisfies `findCounitU4HazardList (...) = none`. -/
theorem law_u4_rewrite_preserves_zero_phase_taint_and_clears_counit_detector
    (irs : List LiftedRevIR) (htaint : countUncompensatedPhaseTaint irs = 0) :
    countUncompensatedPhaseTaint (rewriteRemoteUncomputeToLawU4 irs) = 0 ∧
    findCounitU4HazardList (rewriteRemoteUncomputeToLawU4 irs) = none := by
  induction irs with
  | nil => exact ⟨rfl, rfl⟩
  | cons ir rem ih =>
    cases ir with
    | irTempAndMx tgt hasFix c0 c1 =>
      cases hasFix with
      | false => simp [countUncompensatedPhaseTaint] at htaint
      | true =>
        simp only [countUncompensatedPhaseTaint] at htaint
        simpa [rewriteRemoteUncomputeToLawU4, countUncompensatedPhaseTaint,
          findCounitU4HazardList, hasCounitU4HazardIR] using ih htaint
    | irToggle t | irXor c t | irToffoli c0 c1 t | irSuperposeH t | irPhaseZ t
    | irPhaseCZ c0 c1 | irAnalogRot t nb | irCollapseZ t | irResetZero t
    | irRemoteComputeAnd cL cR tR | irRemoteUncomputeAnd cL cR tR | irLawU4LocalMxFixup cL cR tR =>
      simp only [countUncompensatedPhaseTaint] at htaint
      simpa [rewriteRemoteUncomputeToLawU4, countUncompensatedPhaseTaint,
        findCounitU4HazardList, hasCounitU4HazardIR] using ih htaint

/-! ## Rule 7 (`T-ParGuard`): `M* = 1` Fallback Optimality When Sequential Depth Dominates -/

/-- Discrete wall-clock cost parameters for `T-ParGuard` multi-QPU cluster sizing. -/
structure ClusterWorkload where
  seqSteps     : Nat
  parSteps     : Nat
  peerSyncCost : Nat
  peerEbitCost : Nat
  deriving DecidableEq, Repr

/-- Wall-clock ticks at candidate machine count `m` (`m <= 1` executes monolithically with 0 cuts). -/
def wallClockTicks (w : ClusterWorkload) (m : Nat) : Nat :=
  match m with
  | 0     => w.seqSteps + w.parSteps
  | 1     => w.seqSteps + w.parSteps
  | k + 2 => w.seqSteps + w.parSteps / (k + 2) + (k + 1) * (w.peerSyncCost + w.peerEbitCost)

/-- Recursive minimum-wall-clock machine selector seeded with accumulator `bestM`. -/
def selectOptimalMachineFrom (bestM : Nat) (w : ClusterWorkload) (cands : List Nat) : Nat :=
  match cands with
  | []      => bestM
  | m :: ms =>
      let nextBest := if decide (wallClockTicks w m < wallClockTicks w bestM) then m else bestM
      selectOptimalMachineFrom nextBest w ms

/-- **Theorem 13 (`wall_clock_m_one_optimal_when_seq_or_comm_dominates`)**:
    Whenever parallelizable work `w.parSteps` does not exceed single-cut sync + Bell ebit overhead
    (`w.parSteps <= w.peerSyncCost + w.peerEbitCost`, including purely sequential `w.parSteps = 0`),
    monolithic `M = 1` achieves less-or-equal wall-clock time than every `m : Nat`. -/
theorem wall_clock_m_one_optimal_when_seq_or_comm_dominates
    (w : ClusterWorkload) (m : Nat)
    (hdom : w.parSteps ≤ w.peerSyncCost + w.peerEbitCost) :
    wallClockTicks w 1 ≤ wallClockTicks w m := by
  cases m with
  | zero => simp only [wallClockTicks]; exact Nat.le_refl _
  | succ n =>
    cases n with
    | zero => simp only [wallClockTicks]; exact Nat.le_refl _
    | succ k =>
      simp only [wallClockTicks]
      have hmul : w.peerSyncCost + w.peerEbitCost ≤ (k + 1) * (w.peerSyncCost + w.peerEbitCost) := by
        simpa [Nat.one_mul] using Nat.mul_le_mul_right (w.peerSyncCost + w.peerEbitCost) (Nat.succ_pos k)
      have hpar : w.parSteps ≤ (k + 1) * (w.peerSyncCost + w.peerEbitCost) := Nat.le_trans hdom hmul
      have hdiv : 0 ≤ w.parSteps / (k + 2) := Nat.zero_le _
      omega

/-- **Theorem 14 (`sizer_selects_m_star_eq_one_over_candidate_list`)**:
    Over any candidate machine list `cands : List Nat` (`e.g. [1, 2, 4, ..., 256]`), when sequential
    depth / cut overhead dominates (`w.parSteps <= w.peerSyncCost + w.peerEbitCost`), the recursive
    cluster sizer seeded at `1` selects `M* = 1` and beats or ties every `m ∈ cands`. -/
theorem sizer_selects_m_star_eq_one_over_candidate_list
    (w : ClusterWorkload) (cands : List Nat)
    (hdom : w.parSteps ≤ w.peerSyncCost + w.peerEbitCost) :
    selectOptimalMachineFrom 1 w cands = 1 ∧
    ∀ m ∈ cands, wallClockTicks w (selectOptimalMachineFrom 1 w cands) ≤ wallClockTicks w m := by
  have hsel : selectOptimalMachineFrom 1 w cands = 1 := by
    induction cands with
    | nil => rfl
    | cons m ms ih =>
      have hm := wall_clock_m_one_optimal_when_seq_or_comm_dominates w m hdom
      have hnotlt : ¬ (wallClockTicks w m < wallClockTicks w 1) := Nat.not_lt.mpr hm
      simpa [selectOptimalMachineFrom, hnotlt] using ih
  refine ⟨hsel, ?_⟩
  intro m _
  rw [hsel]
  exact wall_clock_m_one_optimal_when_seq_or_comm_dominates w m hdom

/-- **Theorem 15 (`end_to_end_lifted_qasm_clean_lint_guarantees`)**:
    End-to-end guarantee for `ae/lakefillq_lint.py`: if an OpenQASM / Qiskit program `cs : List QasmGate`
    lifts to `liftQasmCircuit cs` with zero lint violations (`lintRevIR ctx probeSt (liftQasmCircuit cs) = []`),
    then on the surface OpenQASM semantics itself:
      1. Read-only input wire `ctx.readonlyWire` is preserved bit-exact across `cs`.
      2. Ancilla wire `ctx.ancillaWire` returns cleanly to `false` (`|0>`).
      3. Subnormalization `alphaRequired <= alphaDeclared`, capacity `allocatedQubits <= qCap`,
         and cluster optimality `requestedMachines = optimalMachines` all hold. -/
theorem end_to_end_lifted_qasm_clean_lint_guarantees
    (cs : List QasmGate) (ctx : LintContext) (probeSt : BasisState)
    (hclean : lintRevIR ctx probeSt (liftQasmCircuit cs) = []) :
    evalQasmCircuitBasis cs probeSt ctx.readonlyWire = probeSt ctx.readonlyWire ∧
    evalQasmCircuitBasis cs probeSt ctx.ancillaWire = false ∧
    ctx.alphaRequired ≤ ctx.alphaDeclared ∧
    ctx.allocatedQubits ≤ ctx.qCap ∧
    ctx.requestedMachines = ctx.optimalMachines := by
  have h7 := detector_sound_clean_implies_all_seven_invariants ctx probeSt (liftQasmCircuit cs) hclean
  have hro := readonly_wire_preserved_when_unmutated (liftQasmCircuit cs) probeSt ctx.readonlyWire h7.1
  rw [liftQasmCircuit_basis_sound] at hro
  have hanc : evalQasmCircuitBasis cs probeSt ctx.ancillaWire = false := by
    have h3 := h7.2.2.1
    dsimp only [leavesDirtyAncilla] at h3
    rw [liftQasmCircuit_basis_sound] at h3
    exact h3
  exact ⟨hro, hanc, h7.2.2.2.2.1, h7.2.2.2.2.2.1, h7.2.2.2.2.2.2⟩

end LakefillQQasmPythonLinterLifting
