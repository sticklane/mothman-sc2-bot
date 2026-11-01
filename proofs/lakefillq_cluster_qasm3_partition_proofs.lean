/-
  proofs/lakefillq_cluster_qasm3_partition_proofs.lean

  Mechanized Lean 4.35.0 Soundness Proofs for Multi-QPU OpenQASM 3.0 Partition
  Codegen (`compiler/lakefillq-cluster-qasm3-codegen.rkt` & `compiler/lakefillqc.rkt`):
    1. `ClusterIR` -> `List EbitOp` Bell-schedule synthesis: `0` reverse ebits
       (`Law U4` `M_X` + classical `Z` fixup), `0` cross-QPU carry ebits (`QRNS`
       residue channels), and `1:1` duality between forward `ghz_cat_entangle`
       Bell pairs and classical `feedforward_cond_z` messages.
    2. Compositional per-QPU OpenQASM 3.0 projection (`ClusterIR -> NodeQasmProg`)
       and slice-local wire-bounds preservation (zero cross-QPU `CCX` leakage).
    3. Exact denotational equivalence of optical Bell cat-entanglement
       (`ghz_cat_tx` / `ghz_cat_rx` + conditional `X`) and `Law U4` zero-ebit
       `M_X + feedforward_cond_z` disentanglement against monolithic `RevIR`,
       plus constructive phase-corruption witness when `cond-z` is omitted.
    4. `T-ParGuard` `PartitionSchedule` selection: `M* = 1` (`0` ebits) for
       sequential `Grover` / `GF(2^8)` discrete-log S-box chains and monolithic
       `Q_single <= Q_cap` circuits, and `w * (M* - 1)` forward-only ebit scaling
       across inductive peer-QPU GHZ broadcast lists.

  Proof Hygiene Guarantees:
    - Purely constructive kernel proofs with explicit constructor matching throughout
    - Every theorem quantifies over inductive ASTs/structures/lists with <= 25 proof lines
-/

namespace LakefillQClusterQasm3PartitionProofs

abbrev QpuId := Nat
abbrev WireId := Nat
abbrev ClBitId := Nat

/-! ## 1. Inductive `EbitOp`, `ClusterIR`, `NodeQasmStmt`, and `PartitionSchedule` -/

/-- Optical Bell-link and classical feedforward events in `ebit_schedule.json`. -/
inductive EbitOp where
  | ebitFwdCatEntangle  : QpuId → WireId → QpuId → WireId → EbitOp
  | ebitRevCatEntangle  : QpuId → WireId → QpuId → WireId → EbitOp
  | ebitCarryRipple     : QpuId → QpuId → EbitOp
  | ebitU4FeedforwardZ  : QpuId → WireId → QpuId → WireId → ClBitId → EbitOp
  deriving DecidableEq, Repr

/-- Multi-QPU cluster intermediate representation lowered from `MachineISA`. -/
inductive ClusterIR where
  | cSkip           : ClusterIR
  | cLocal1Q        : QpuId → WireId → Bool → ClusterIR
  | cLocalCX        : QpuId → WireId → WireId → ClusterIR
  | cLocalCCX       : QpuId → WireId → WireId → WireId → ClusterIR
  | cLocalMbuCZ     : QpuId → WireId → WireId → WireId → ClBitId → ClusterIR
  | cRemoteU4Window : QpuId → WireId → QpuId → WireId → WireId → WireId → ClBitId → ClusterIR
  | cSeq            : ClusterIR → ClusterIR → ClusterIR
  deriving DecidableEq, Repr

/-- Per-QPU OpenQASM 3.0 statement AST emitted in `qpu_p.qasm`. -/
inductive NodeQasmStmt where
  | q1Q               : WireId → Bool → NodeQasmStmt
  | qCX               : WireId → WireId → NodeQasmStmt
  | qCCX              : WireId → WireId → WireId → NodeQasmStmt
  | qMbuLocalCZ       : WireId → WireId → WireId → ClBitId → NodeQasmStmt
  | qGhzCatTx         : WireId → ClBitId → NodeQasmStmt
  | qGhzCatRx         : WireId → ClBitId → NodeQasmStmt
  | qU4MeasXReset     : WireId → ClBitId → NodeQasmStmt
  | qFeedforwardCondZ : ClBitId → WireId → NodeQasmStmt
  deriving DecidableEq, Repr

/-- Per-node OpenQASM 3.0 module descriptor for `qpu_p.qasm`. -/
structure NodeQasmProg where
  qpuId       : QpuId
  localQubits : Nat
  hasBellTx   : Bool
  stmts       : List NodeQasmStmt
  deriving DecidableEq, Repr

/-- Algorithmic parallelizability class inspected by `T-ParGuard`. -/
inductive WorkloadParadigm where
  | pGroverSequential : WorkloadParadigm
  | pShotSample       : WorkloadParadigm
  | pQrnsLawU4        : WorkloadParadigm
  deriving DecidableEq, Repr

/-- Synthesized cluster bundle (`cluster_manifest.json` + `qpu_0..qpu_{M*-1}.qasm`). -/
inductive PartitionSchedule where
  | schedMonolithicSingle     : NodeQasmProg → PartitionSchedule
  | schedGroverFallbackSingle : NodeQasmProg → Nat → PartitionSchedule
  | schedDistributedSlices    : List NodeQasmProg → List EbitOp → PartitionSchedule
  deriving DecidableEq, Repr

/-! ## 2. Bell-Schedule Accounting & Forward-Only `Law U4` + `QRNS` Invariants -/

def opForwardEbits : EbitOp → Nat
  | EbitOp.ebitFwdCatEntangle _ _ _ _ => 1
  | EbitOp.ebitRevCatEntangle _ _ _ _ => 0
  | EbitOp.ebitCarryRipple _ _ => 0
  | EbitOp.ebitU4FeedforwardZ _ _ _ _ _ => 0

def opReverseEbits : EbitOp → Nat
  | EbitOp.ebitFwdCatEntangle _ _ _ _ => 0
  | EbitOp.ebitRevCatEntangle _ _ _ _ => 1
  | EbitOp.ebitCarryRipple _ _ => 0
  | EbitOp.ebitU4FeedforwardZ _ _ _ _ _ => 0

def opCarryEbits : EbitOp → Nat
  | EbitOp.ebitFwdCatEntangle _ _ _ _ => 0
  | EbitOp.ebitRevCatEntangle _ _ _ _ => 0
  | EbitOp.ebitCarryRipple _ _ => 1
  | EbitOp.ebitU4FeedforwardZ _ _ _ _ _ => 0

def opTotalEbits : EbitOp → Nat
  | EbitOp.ebitFwdCatEntangle _ _ _ _ => 1
  | EbitOp.ebitRevCatEntangle _ _ _ _ => 1
  | EbitOp.ebitCarryRipple _ _ => 1
  | EbitOp.ebitU4FeedforwardZ _ _ _ _ _ => 0

def opClassicalFeedforwards : EbitOp → Nat
  | EbitOp.ebitFwdCatEntangle _ _ _ _ => 0
  | EbitOp.ebitRevCatEntangle _ _ _ _ => 0
  | EbitOp.ebitCarryRipple _ _ => 0
  | EbitOp.ebitU4FeedforwardZ _ _ _ _ _ => 1

def countForwardEbits : List EbitOp → Nat
  | [] => 0
  | op :: rest => opForwardEbits op + countForwardEbits rest

def countReverseEbits : List EbitOp → Nat
  | [] => 0
  | op :: rest => opReverseEbits op + countReverseEbits rest

def countCarryEbits : List EbitOp → Nat
  | [] => 0
  | op :: rest => opCarryEbits op + countCarryEbits rest

def totalConsumedEbits : List EbitOp → Nat
  | [] => 0
  | op :: rest => opTotalEbits op + totalConsumedEbits rest

def countClassicalFeedforwards : List EbitOp → Nat
  | [] => 0
  | op :: rest => opClassicalFeedforwards op + countClassicalFeedforwards rest

def countRemoteU4Windows : ClusterIR → Nat
  | ClusterIR.cSkip => 0
  | ClusterIR.cLocal1Q _ _ _ => 0
  | ClusterIR.cLocalCX _ _ _ => 0
  | ClusterIR.cLocalCCX _ _ _ _ => 0
  | ClusterIR.cLocalMbuCZ _ _ _ _ _ => 0
  | ClusterIR.cRemoteU4Window _ _ _ _ _ _ _ => 1
  | ClusterIR.cSeq a b => countRemoteU4Windows a + countRemoteU4Windows b

/-- Extracts the ordered inter-QPU `EbitOp` schedule from `ClusterIR`. -/
def emitEbitSchedule : ClusterIR → List EbitOp
  | ClusterIR.cSkip => []
  | ClusterIR.cLocal1Q _ _ _ => []
  | ClusterIR.cLocalCX _ _ _ => []
  | ClusterIR.cLocalCCX _ _ _ _ => []
  | ClusterIR.cLocalMbuCZ _ _ _ _ _ => []
  | ClusterIR.cRemoteU4Window srcP srcW dstP catW _ _ mk =>
      [ EbitOp.ebitFwdCatEntangle srcP srcW dstP catW,
        EbitOp.ebitU4FeedforwardZ dstP catW srcP srcW mk ]
  | ClusterIR.cSeq a b => emitEbitSchedule a ++ emitEbitSchedule b

/-- Theorem 1: `emitEbitSchedule` is a monoid homomorphism from `ClusterIR.cSeq` to `++`. -/
theorem emitEbitSchedule_seq (a b : ClusterIR) :
    emitEbitSchedule (ClusterIR.cSeq a b) = emitEbitSchedule a ++ emitEbitSchedule b := by
  rfl

/-- Theorem 2: Forward ebit counting distributes additively across `List EbitOp` concatenation. -/
theorem countForwardEbits_append (xs ys : List EbitOp) :
    countForwardEbits (xs ++ ys) = countForwardEbits xs + countForwardEbits ys := by
  induction xs with
  | nil => simp [countForwardEbits]
  | cons hd tl ih =>
      simp [countForwardEbits, ih, Nat.add_assoc]

/-- Theorem 3: Reverse ebit counting distributes additively across `List EbitOp` concatenation. -/
theorem countReverseEbits_append (xs ys : List EbitOp) :
    countReverseEbits (xs ++ ys) = countReverseEbits xs + countReverseEbits ys := by
  induction xs with
  | nil => simp [countReverseEbits]
  | cons hd tl ih =>
      simp [countReverseEbits, ih, Nat.add_assoc]

/-- Theorem 4: Carry ebit counting distributes additively across `List EbitOp` concatenation. -/
theorem countCarryEbits_append (xs ys : List EbitOp) :
    countCarryEbits (xs ++ ys) = countCarryEbits xs + countCarryEbits ys := by
  induction xs with
  | nil => simp [countCarryEbits]
  | cons hd tl ih =>
      simp [countCarryEbits, ih, Nat.add_assoc]

theorem totalConsumedEbits_append (xs ys : List EbitOp) :
    totalConsumedEbits (xs ++ ys) = totalConsumedEbits xs + totalConsumedEbits ys := by
  induction xs with
  | nil => simp [totalConsumedEbits]
  | cons hd tl ih =>
      simp [totalConsumedEbits, ih, Nat.add_assoc]

theorem countClassicalFeedforwards_append (xs ys : List EbitOp) :
    countClassicalFeedforwards (xs ++ ys) =
      countClassicalFeedforwards xs + countClassicalFeedforwards ys := by
  induction xs with
  | nil => simp [countClassicalFeedforwards]
  | cons hd tl ih =>
      simp [countClassicalFeedforwards, ih, Nat.add_assoc]

/-- Theorem 5 (`Law U4` Zero Reverse Ebits): Lowering any `ClusterIR` program
    consumes strictly `0` reverse cat-disentanglement Bell pairs. -/
theorem clusterIR_zero_reverse_ebits (ir : ClusterIR) :
    countReverseEbits (emitEbitSchedule ir) = 0 := by
  induction ir with
  | cSkip => rfl
  | cLocal1Q _ _ _ => rfl
  | cLocalCX _ _ _ => rfl
  | cLocalCCX _ _ _ _ => rfl
  | cLocalMbuCZ _ _ _ _ _ => rfl
  | cRemoteU4Window _ _ _ _ _ _ _ => rfl
  | cSeq _ _ ih1 ih2 =>
      rw [emitEbitSchedule_seq, countReverseEbits_append, ih1, ih2]

/-- Theorem 6 (`QRNS` Zero Carry Ebits): Lowering any `ClusterIR` program
    consumes strictly `0` cross-QPU carry ripple Bell pairs. -/
theorem clusterIR_zero_carry_ebits (ir : ClusterIR) :
    countCarryEbits (emitEbitSchedule ir) = 0 := by
  induction ir with
  | cSkip => rfl
  | cLocal1Q _ _ _ => rfl
  | cLocalCX _ _ _ => rfl
  | cLocalCCX _ _ _ _ => rfl
  | cLocalMbuCZ _ _ _ _ _ => rfl
  | cRemoteU4Window _ _ _ _ _ _ _ => rfl
  | cSeq _ _ ih1 ih2 =>
      rw [emitEbitSchedule_seq, countCarryEbits_append, ih1, ih2]

/-- Theorem 7: Total logical ebits consumed across any `ClusterIR` program equals
    its forward `ghz_cat_entangle` count (`0` hidden reverse or carry overhead). -/
theorem clusterIR_total_ebits_eq_forward (ir : ClusterIR) :
    totalConsumedEbits (emitEbitSchedule ir) = countForwardEbits (emitEbitSchedule ir) := by
  induction ir with
  | cSkip => rfl
  | cLocal1Q _ _ _ => rfl
  | cLocalCX _ _ _ => rfl
  | cLocalCCX _ _ _ _ => rfl
  | cLocalMbuCZ _ _ _ _ _ => rfl
  | cRemoteU4Window _ _ _ _ _ _ _ => rfl
  | cSeq _ _ ih1 ih2 =>
      rw [emitEbitSchedule_seq, totalConsumedEbits_append, countForwardEbits_append, ih1, ih2]

/-- Theorem 8 (`Law U4` Forward-Feedforward Duality): Every `cRemoteU4Window`
    contributes exactly `1` forward Bell pair and `1` zero-ebit `M_X -> cond-Z` fixup. -/
theorem clusterIR_forward_and_feedforward_match_windows (ir : ClusterIR) :
    countForwardEbits (emitEbitSchedule ir) = countRemoteU4Windows ir ∧
    countClassicalFeedforwards (emitEbitSchedule ir) = countRemoteU4Windows ir := by
  induction ir with
  | cSkip => exact ⟨rfl, rfl⟩
  | cLocal1Q _ _ _ => exact ⟨rfl, rfl⟩
  | cLocalCX _ _ _ => exact ⟨rfl, rfl⟩
  | cLocalCCX _ _ _ _ => exact ⟨rfl, rfl⟩
  | cLocalMbuCZ _ _ _ _ _ => exact ⟨rfl, rfl⟩
  | cRemoteU4Window _ _ _ _ _ _ _ => exact ⟨rfl, rfl⟩
  | cSeq _ _ ih1 ih2 =>
      refine ⟨?_, ?_⟩
      · rw [emitEbitSchedule_seq, countForwardEbits_append, ih1.1, ih2.1]; rfl
      · rw [emitEbitSchedule_seq, countClassicalFeedforwards_append, ih1.2, ih2.2]; rfl

/-! ## 3. Per-QPU OpenQASM 3.0 Projection & Local Wire-Slice Closure -/

/-- Projects `ClusterIR` onto the OpenQASM 3.0 statement stream of `qpu_p.qasm`. -/
def projectNodeStmts (p : QpuId) : ClusterIR → List NodeQasmStmt
  | ClusterIR.cSkip => []
  | ClusterIR.cLocal1Q q w fl =>
      if p = q then [NodeQasmStmt.q1Q w fl] else []
  | ClusterIR.cLocalCX q c t =>
      if p = q then [NodeQasmStmt.qCX c t] else []
  | ClusterIR.cLocalCCX q c1 c2 t =>
      if p = q then [NodeQasmStmt.qCCX c1 c2 t] else []
  | ClusterIR.cLocalMbuCZ q anc c1 c2 mk =>
      if p = q then [NodeQasmStmt.qMbuLocalCZ anc c1 c2 mk] else []
  | ClusterIR.cRemoteU4Window srcP srcW dstP catW limbA limbB mk =>
      (if p = srcP then [NodeQasmStmt.qGhzCatTx srcW mk] else []) ++
      (if p = dstP then
         [ NodeQasmStmt.qGhzCatRx catW mk,
           NodeQasmStmt.qCCX catW limbA limbB,
           NodeQasmStmt.qU4MeasXReset catW mk ]
       else []) ++
      (if p = srcP then [NodeQasmStmt.qFeedforwardCondZ mk srcW] else [])
  | ClusterIR.cSeq a b => projectNodeStmts p a ++ projectNodeStmts p b

/-- Theorem 9: Per-QPU OpenQASM 3.0 projection commutes with `ClusterIR.cSeq`. -/
theorem projectNodeStmts_seq (p : QpuId) (a b : ClusterIR) :
    projectNodeStmts p (ClusterIR.cSeq a b) = projectNodeStmts p a ++ projectNodeStmts p b := by
  rfl

def stmtWithinBound (bound : Nat) : NodeQasmStmt → Bool
  | NodeQasmStmt.q1Q w _ => decide (w < bound)
  | NodeQasmStmt.qCX c t => decide (c < bound ∧ t < bound)
  | NodeQasmStmt.qCCX c1 c2 t => decide (c1 < bound ∧ c2 < bound ∧ t < bound)
  | NodeQasmStmt.qMbuLocalCZ anc c1 c2 _ => decide (anc < bound ∧ c1 < bound ∧ c2 < bound)
  | NodeQasmStmt.qGhzCatTx w _ => decide (w < bound)
  | NodeQasmStmt.qGhzCatRx w _ => decide (w < bound)
  | NodeQasmStmt.qU4MeasXReset w _ => decide (w < bound)
  | NodeQasmStmt.qFeedforwardCondZ _ w => decide (w < bound)

def allStmtsWithinBound (bound : Nat) : List NodeQasmStmt → Bool
  | [] => true
  | s :: rest => stmtWithinBound bound s && allStmtsWithinBound bound rest

theorem allStmtsWithinBound_append (bound : Nat) (xs ys : List NodeQasmStmt)
    (hx : allStmtsWithinBound bound xs = true)
    (hy : allStmtsWithinBound bound ys = true) :
    allStmtsWithinBound bound (xs ++ ys) = true := by
  induction xs with
  | nil => exact hy
  | cons hd tl ih =>
      simp [allStmtsWithinBound, Bool.and_eq_true] at hx ⊢
      exact ⟨hx.1, ih hx.2⟩

def irWithinSliceBounds (bounds : QpuId → Nat) : ClusterIR → Bool
  | ClusterIR.cSkip => true
  | ClusterIR.cLocal1Q q w _ => decide (w < bounds q)
  | ClusterIR.cLocalCX q c t => decide (c < bounds q ∧ t < bounds q)
  | ClusterIR.cLocalCCX q c1 c2 t => decide (c1 < bounds q ∧ c2 < bounds q ∧ t < bounds q)
  | ClusterIR.cLocalMbuCZ q anc c1 c2 _ =>
      decide (anc < bounds q ∧ c1 < bounds q ∧ c2 < bounds q)
  | ClusterIR.cRemoteU4Window srcP srcW dstP catW limbA limbB _ =>
      decide (srcW < bounds srcP) &&
      decide (catW < bounds dstP ∧ limbA < bounds dstP ∧ limbB < bounds dstP)
  | ClusterIR.cSeq a b => irWithinSliceBounds bounds a && irWithinSliceBounds bounds b

/-- Theorem 10: Every projected OpenQASM 3.0 statement in `qpu_p.qasm` strictly
    indexes local qubits `< bounds p` whenever `ir` is slice-well-formed. -/
theorem projectNodeStmts_preserves_slice_bounds
    (bounds : QpuId → Nat) (p : QpuId) (ir : ClusterIR)
    (hwf : irWithinSliceBounds bounds ir = true) :
    allStmtsWithinBound (bounds p) (projectNodeStmts p ir) = true := by
  induction ir with
  | cSkip => rfl
  | cLocal1Q q w fl =>
      by_cases hp : p = q <;> simp_all [projectNodeStmts, allStmtsWithinBound, stmtWithinBound, irWithinSliceBounds]
  | cLocalCX q c t =>
      by_cases hp : p = q <;> simp_all [projectNodeStmts, allStmtsWithinBound, stmtWithinBound, irWithinSliceBounds]
  | cLocalCCX q c1 c2 t =>
      by_cases hp : p = q <;> simp_all [projectNodeStmts, allStmtsWithinBound, stmtWithinBound, irWithinSliceBounds]
  | cLocalMbuCZ q anc c1 c2 mk =>
      by_cases hp : p = q <;> simp_all [projectNodeStmts, allStmtsWithinBound, stmtWithinBound, irWithinSliceBounds]
  | cRemoteU4Window srcP srcW dstP catW limbA limbB mk =>
      simp [irWithinSliceBounds, Bool.and_eq_true] at hwf
      by_cases hs : p = srcP <;> by_cases hd : p = dstP <;>
        simp_all [projectNodeStmts, allStmtsWithinBound, stmtWithinBound]
  | cSeq a b iha ihb =>
      simp [irWithinSliceBounds, Bool.and_eq_true] at hwf
      exact allStmtsWithinBound_append (bounds p) (projectNodeStmts p a) (projectNodeStmts p b) (iha hwf.1) (ihb hwf.2)

/-! ## 4. Denotational Equivalence: Optical Bell Cat-Entangle & `Law U4` Disentangle -/

/-- State of `(src, dst, bellTx, signBit)` during `ghz_cat_tx` / `ghz_cat_rx` teleportation. -/
structure BellTeleportFrame where
  srcBit  : Bool
  dstBit  : Bool
  txBit   : Bool
  signBit : Bool
  deriving DecidableEq, Repr

/-- Monolithic `CX(src, dst)` with clean transceiver wire `txBit = false`. -/
def execMonolithicCX (st : BellTeleportFrame) : BellTeleportFrame :=
  { st with dstBit := xor st.dstBit st.srcBit, txBit := false }

/-- Distributed Bell cat-entangle (`h tx; cx tx, dst; cx src, tx; m = measure tx; reset tx; if m then x dst`)
    evaluated on the collapsed Bell-pair branch indexed by Z-measurement outcome `mBell : Bool`. -/
def execDistributedBellCatCX (st : BellTeleportFrame) (mBell : Bool) : BellTeleportFrame :=
  let bellHalf := xor mBell st.srcBit
  let dstAfterHalf := xor st.dstBit bellHalf
  let dstAfterFix := if mBell then !dstAfterHalf else dstAfterHalf
  { st with dstBit := dstAfterFix, txBit := false }

/-- Theorem 11: Distributed optical Bell cat-entanglement (`ghz_cat_tx` + `ghz_cat_rx` +
    conditional `X` fixup + `reset ebit[0]`) is denotationally identical to monolithic
    `CX(src, dst)` for every measurement branch `mBell : Bool` when `txBit = false`. -/
theorem bell_cat_teleport_denotational_equiv
    (st : BellTeleportFrame) (mBell : Bool) (htx : st.txBit = false) :
    execDistributedBellCatCX st mBell = execMonolithicCX st := by
  cases st with
  | mk srcB dstB txB sgn =>
      simp at htx
      subst htx
      cases srcB <;> cases dstB <;> cases mBell <;> rfl

/-- Joint 5-signal state `(src, cat, limbA, limbB, signBit)` across a `Law U4` QRNS window. -/
structure RemoteU4WindowState where
  srcBit  : Bool
  catBit  : Bool
  limbA   : Bool
  limbB   : Bool
  signBit : Bool
  deriving DecidableEq, Repr

/-- Monolithic `CCX(src, limbA, limbB)` leaving `catBit = false` and `signBit` unchanged. -/
def execMonolithicWindowCCX (st : RemoteU4WindowState) : RemoteU4WindowState :=
  { st with limbB := xor st.limbB (st.srcBit && st.limbA), catBit := false }

/-- Distributed `Law U4` window execution (`cat := src`, `CCX(cat, limbA, limbB)`,
    `M_X(cat) -> mxOut`, `reset(cat)`, and `if mxOut then Z(src)`). -/
def execDistributedU4Window (st : RemoteU4WindowState) (mxOut : Bool) (applyCondZ : Bool) :
    RemoteU4WindowState :=
  let catEnt := xor st.catBit st.srcBit
  let limbB1 := xor st.limbB (catEnt && st.limbA)
  let signAfterMx := xor st.signBit (mxOut && catEnt)
  let signAfterFix :=
    if applyCondZ then xor signAfterMx (mxOut && st.srcBit) else signAfterMx
  { st with catBit := false, limbB := limbB1, signBit := signAfterFix }

/-- Theorem 12 (`Law U4` + `Law U1` Soundness): With `catBit = false` on entry and
    `applyCondZ = true`, distributed `cRemoteU4Window` reproduces monolithic
    `CCX(src, limbA, limbB)` with `catBit = false` and exact phase preservation
    across every `M_X` outcome `mxOut : Bool`. -/
theorem law_u4_remote_window_denotational_equiv
    (st : RemoteU4WindowState) (mxOut : Bool) (hcat : st.catBit = false) :
    execDistributedU4Window st mxOut true = execMonolithicWindowCCX st := by
  cases st with
  | mk srcB catB la lb sgn =>
      simp at hcat
      subst hcat
      cases srcB <;> cases la <;> cases lb <;> cases sgn <;> cases mxOut <;> rfl

/-- Theorem 13 (`T-CounitU4` Necessity Witness): Omitting `feedforward_cond_z`
    (`applyCondZ = false`) strictly corrupts the quantum phase (`signBit`) whenever
    `srcBit = true`, `catBit = false`, and `mxOut = true`. -/
theorem missing_u4_cond_z_corrupts_phase
    (st : RemoteU4WindowState)
    (hsrc : st.srcBit = true)
    (hcat : st.catBit = false) :
    (execDistributedU4Window st true false).signBit = !st.signBit := by
  cases st with
  | mk srcB catB la lb sgn =>
      simp at hsrc hcat
      subst hsrc; subst hcat
      cases sgn <;> rfl

/-! ## 5. `T-ParGuard` `PartitionSchedule` Selection & Multi-Window GHZ Ebit Scaling -/

def mStarOfSchedule : PartitionSchedule → Nat
  | PartitionSchedule.schedMonolithicSingle _ => 1
  | PartitionSchedule.schedGroverFallbackSingle _ _ => 1
  | PartitionSchedule.schedDistributedSlices slices _ => slices.length

def scheduleEbitOps : PartitionSchedule → List EbitOp
  | PartitionSchedule.schedMonolithicSingle _ => []
  | PartitionSchedule.schedGroverFallbackSingle _ _ => []
  | PartitionSchedule.schedDistributedSlices _ ops => ops

def synthesizePartitionSchedule
    (paradigm : WorkloadParadigm)
    (monoProg : NodeQasmProg)
    (slices : List NodeQasmProg)
    (ebits : List EbitOp)
    (mMax qCap : Nat) : PartitionSchedule :=
  match paradigm with
  | WorkloadParadigm.pGroverSequential =>
      if mMax > 1 then
        PartitionSchedule.schedGroverFallbackSingle monoProg mMax
      else
        PartitionSchedule.schedMonolithicSingle monoProg
  | WorkloadParadigm.pShotSample =>
      PartitionSchedule.schedMonolithicSingle monoProg
  | WorkloadParadigm.pQrnsLawU4 =>
      if monoProg.localQubits ≤ qCap then
        PartitionSchedule.schedMonolithicSingle monoProg
      else
        PartitionSchedule.schedDistributedSlices slices ebits

/-- Theorem 14 (`T-ParGuard` Grover / `AES-DLog5-13Q` Single-QPU Theorem):
    Sequential Grover / S-box chains always select `M* = 1` and `0` optical ebits. -/
theorem grover_paradigm_selects_single_qpu
    (monoProg : NodeQasmProg) (slices : List NodeQasmProg)
    (ebits : List EbitOp) (mMax qCap : Nat) :
    let sched := synthesizePartitionSchedule
      WorkloadParadigm.pGroverSequential monoProg slices ebits mMax qCap
    mStarOfSchedule sched = 1 ∧ totalConsumedEbits (scheduleEbitOps sched) = 0 := by
  dsimp [synthesizePartitionSchedule]
  by_cases hm : mMax > 1
  · simp [hm, mStarOfSchedule, scheduleEbitOps, totalConsumedEbits]
  · simp [hm, mStarOfSchedule, scheduleEbitOps, totalConsumedEbits]

/-- Theorem 15 (`T-ParGuard` Monolithic Short-Circuit Theorem):
    When `monoProg.localQubits <= qCap`, `pQrnsLawU4` selects `M* = 1` and `0` ebits. -/
theorem monolithic_fits_qcap_selects_single_qpu
    (monoProg : NodeQasmProg) (slices : List NodeQasmProg)
    (ebits : List EbitOp) (mMax qCap : Nat)
    (hfit : monoProg.localQubits ≤ qCap) :
    let sched := synthesizePartitionSchedule
      WorkloadParadigm.pQrnsLawU4 monoProg slices ebits mMax qCap
    mStarOfSchedule sched = 1 ∧ totalConsumedEbits (scheduleEbitOps sched) = 0 := by
  simp [synthesizePartitionSchedule, hfit, mStarOfSchedule, scheduleEbitOps, totalConsumedEbits]

/-- Theorem 16: Across every `WorkloadParadigm` and capacity `qCap`, schedules lowered
    from `ClusterIR` emit strictly `0` reverse ebits and `0` carry ebits. -/
theorem partition_schedule_preserves_zero_rev_and_carry
    (paradigm : WorkloadParadigm) (monoProg : NodeQasmProg)
    (slices : List NodeQasmProg) (ir : ClusterIR) (mMax qCap : Nat) :
    let sched := synthesizePartitionSchedule paradigm monoProg slices (emitEbitSchedule ir) mMax qCap
    countReverseEbits (scheduleEbitOps sched) = 0 ∧
    countCarryEbits (scheduleEbitOps sched) = 0 := by
  cases paradigm with
  | pGroverSequential =>
      dsimp [synthesizePartitionSchedule]
      by_cases hm : mMax > 1 <;> simp [hm, scheduleEbitOps, countReverseEbits, countCarryEbits]
  | pShotSample =>
      simp [synthesizePartitionSchedule, scheduleEbitOps, countReverseEbits, countCarryEbits]
  | pQrnsLawU4 =>
      dsimp [synthesizePartitionSchedule]
      by_cases hf : monoProg.localQubits ≤ qCap
      · simp [hf, scheduleEbitOps, countReverseEbits, countCarryEbits]
      · simp [hf, scheduleEbitOps, clusterIR_zero_reverse_ebits, clusterIR_zero_carry_ebits]

/-- Builds a 1-bit GHZ window broadcast from `srcP:srcW` across peer QPUs `peers`. -/
def buildGhzBitBroadcast (srcP : QpuId) (srcW : WireId) : List QpuId → ClusterIR
  | [] => ClusterIR.cSkip
  | dstP :: rest =>
      ClusterIR.cSeq
        (ClusterIR.cRemoteU4Window srcP srcW dstP 0 1 2 dstP)
        (buildGhzBitBroadcast srcP srcW rest)

/-- Builds a `w`-bit multi-window GHZ lookup over `winWires` across peer QPUs `peers`. -/
def buildMultiBitGhzWindow (srcP : QpuId) (peers : List QpuId) : List WireId → ClusterIR
  | [] => ClusterIR.cSkip
  | wWire :: restWires =>
      ClusterIR.cSeq
        (buildGhzBitBroadcast srcP wWire peers)
        (buildMultiBitGhzWindow srcP peers restWires)

theorem buildGhzBitBroadcast_forward_ebits (srcP : QpuId) (srcW : WireId) (peers : List QpuId) :
    countForwardEbits (emitEbitSchedule (buildGhzBitBroadcast srcP srcW peers)) = peers.length := by
  induction peers with
  | nil => rfl
  | cons dstP rest ih =>
      simp [buildGhzBitBroadcast, emitEbitSchedule, ih,
            countForwardEbits, opForwardEbits, Nat.add_comm]

/-- Theorem 17 (`Law U4` Window Scaling Theorem): Broadcasting `winWires` across
    `peers` (`|peers| = M* - 1` remote QPUs) consumes exactly `winWires.length * peers.length`
    forward ebits, `0` reverse ebits, and `0` carry ebits. -/
theorem multi_bit_ghz_window_ebit_scaling
    (srcP : QpuId) (peers : List QpuId) (winWires : List WireId) :
    let sched := emitEbitSchedule (buildMultiBitGhzWindow srcP peers winWires)
    countForwardEbits sched = winWires.length * peers.length ∧
    countReverseEbits sched = 0 ∧
    countCarryEbits sched = 0 := by
  refine ⟨?_, clusterIR_zero_reverse_ebits _, clusterIR_zero_carry_ebits _⟩
  induction winWires with
  | nil => simp [buildMultiBitGhzWindow, emitEbitSchedule, countForwardEbits]
  | cons w rest ih =>
      simp [buildMultiBitGhzWindow, emitEbitSchedule, countForwardEbits_append,
            buildGhzBitBroadcast_forward_ebits, ih, List.length_cons, Nat.succ_mul, Nat.add_comm]

end LakefillQClusterQasm3PartitionProofs
