import Std.Tactic.BVDecide

/-!
# Early-Measurement `MBU` + Phase-Only Decoding in Decoded Quantum Interferometry (`Khattar–Babbush 2025` Unified Under `Law U1 + Law U4`)

This self-contained, kernel-complete, postulate-free, zero-warning Lean 4.35.0 module
mechanizes the algebraic and decoherence-volume theorems backing `lakefill-early-mbu-phase-dqi.rkt` and
`reproducers/verify_early_mbu_phase_dqi_bch7_bch15_on_aer.py`:

1. **`early_mbu_phase_cancellation_algebraic_identity`**:
   Algebraic identity of Early-`MBU` phase cancellation: for any syndrome map `H`,
   decoder `D`, error `e`, and $X$-measurement mask `m`, if `D (H e) = e` (`Law U1`),
   then `(m &&& e).xorParity = (m &&& D (H e)).xorParity` and
   `xor (m &&& e).xorParity (m &&& D (H e)).xorParity = false` (`Law U4` taint erased!).
2. **`bch7_4_3_exhaustive_1024_pairs_early_mbu_phase_exact`**:
   `BCH(7, 4, 3)` exhaustive verification across all `8` weight-$\le 1$ errors $\times$
   all `128` masks `m : BitVec 7` (`1,024` pairs): exact phase cancellation
   `(m &&& e).xorParity == (m &&& decode7 (syn7 e)).xorParity` and universal `BitVec 7` soundness.
3. **`bch15_7_5_peterson_berlekamp_121_exact_vs_stub_105_corrupted`**:
   `BCH(15, 7, 5)` Peterson–Berlekamp Early-`MBU` exactness across all `121` weight-$\le 2$
   masks (`all121Bch15EarlyMbuPhaseExact () = true`) and all `m : BitVec 15`, whereas the
   `Law U1`-violating `wt<=1` Hamming stub succeeds on `16 / 121` and fails on `105 / 121`
   weight-2 errors.
4. **`law_u4_necessity_nonzero_error_flips_64_of_128_signs`**:
   `Law U4` necessity: for EVERY non-zero error `e ≠ 0#7`, omitting the phase fixup leaves
   `exactly half` (`64 / 128` on `7` bits) of $X$-measurement masks `m` with flipped `-1`
   sign (`countSignFlipsBch7 e = 64`, `signedPhaseSumBch7 e = 0`), averaging destructive
   Walsh-Hadamard interference to `0`!
5. **`early_mbu_live_qubit_and_phi1_decoherence_volume_reduction`**:
   Live-qubit & `Φ1` active-decoherence volume reduction of Early-`MBU` `DQI`: `k_synd` live
   wires vs `n + k_synd` during decoder window $\tau_{\text{dec}}$, proving strict volume
   reduction `kSynd * tauDec < (nErr + kSynd) * tauDec` whenever `0 < nErr` and `0 < tauDec`.
6. **`khattar_babbush_opi_4095_840_asymptotic_space_savings`**:
   Asymptotic space savings on `Khattar–Babbush 2025` OPI over $\mathbb{F}_{2^{12}}$
   (`n = 2^12 - 1 = 4095`, `k_synd = 12 * 70 = 840`): `840 < 4935`, freeing `4,095`
   data/error qubits throughout Berlekamp–Massey / Extended Euclidean decoding.
7. **`early_mbu_phase_only_dqi_module_closure`**:
   Master module closure uniting all Early-MBU Phase-Only DQI theorems + `verifyEarlyMbuPhaseOnlyDqiModuleSanity () = true`.
-/

/-- $\mathbb{F}_2$ XOR parity of all bits of `v : BitVec w` (`BitVec.xorParity`). -/
def BitVec.xorParity {w : Nat} (v : BitVec w) : Bool :=
  (List.range w).foldl (fun acc i => xor acc (v.getLsbD i)) false

namespace EarlyMbuPhaseOnlyDqiProofs

set_option maxRecDepth 200000
set_option maxHeartbeats 800000

-- ============================================================================
-- Section 1: Algebraic Identity of Early-`MBU` Phase Cancellation
-- ============================================================================

/-- Post-Stage-3 state of Early-`MBU` Phase-Only `DQI` on a single basis error `e`
    and $X$-measurement outcome mask `m` (`EarlyMbuStage3Result`). -/
structure EarlyMbuStage3Result (k : Nat) where
  syndromeOut        : BitVec k
  parityAncResidual  : Bool
  residualPhaseTaint : Bool
  deriving DecidableEq, Repr

/-- Operational semantics of Early-`MBU` Phase-Only Stage 3:
    1. Stage 2 prepares `s = synMap e`; early `M_X` kicks phase taint `(m &&& e).xorParity`
       and releases all `n` error wires (`0` live error wires!).
    2. Stage 3 `(within-apply (compute-parity m (decMap s) -> p_anc) (z p_anc))` computes
       `p_anc = (m &&& decMap s).xorParity`, kicks phase `p_anc`, and uncomputes `p_anc -> false`. -/
def evalEarlyMbuPhaseStage3 {n k : Nat}
    (synMap : BitVec n → BitVec k)
    (decMap : BitVec k → BitVec n)
    (e m : BitVec n) : EarlyMbuStage3Result k :=
  let s := synMap e
  let mxTaint := (m &&& e).xorParity
  let pComputed := (m &&& decMap s).xorParity
  let taintAfterZ := xor mxTaint pComputed
  let pRestored := xor pComputed (m &&& decMap s).xorParity
  { syndromeOut        := s
  , parityAncResidual  := pRestored
  , residualPhaseTaint := taintAfterZ }

/-- **`early_mbu_phase_cancellation_algebraic_identity`**:
    For any syndrome map `synMap`, algebraic decoder `decMap`, error `e`, and $X$-measurement
    mask `m`, if `decMap (synMap e) = e` (`Law U1` left-inverse on $S_{\le t}$), then
    `(m &&& e).xorParity = (m &&& decMap (synMap e)).xorParity` and their $\mathbb{F}_2$ sum
    vanishes (`xor ... = false`), erasing `Law U4` taint `QTainted[m, e]` to `QClean` (`false`)
    and restoring `p_anc` to `false` while holding `0` live error qubits. -/
theorem early_mbu_phase_cancellation_algebraic_identity
    {n k : Nat} (synMap : BitVec n → BitVec k) (decMap : BitVec k → BitVec n)
    (e m : BitVec n) (hU1 : decMap (synMap e) = e) :
    (m &&& e).xorParity = (m &&& decMap (synMap e)).xorParity ∧
    xor (m &&& e).xorParity (m &&& decMap (synMap e)).xorParity = false ∧
    evalEarlyMbuPhaseStage3 synMap decMap e m = ⟨synMap e, false, false⟩ := by
  unfold evalEarlyMbuPhaseStage3
  dsimp only
  rw [hU1]
  cases (m &&& e).xorParity
  · exact ⟨rfl, rfl, rfl⟩
  · exact ⟨rfl, rfl, rfl⟩

-- ============================================================================
-- Section 2: `BCH(7, 4, 3)` Exhaustive `8 × 128 = 1,024` Verification
-- ============================================================================

/-- Parity-check map $H \in \mathbb{F}_2^{3 \times 7}$ for `BCH(7, 4, 3)` with columns `1..7` (`syn7`). -/
def syn7 (e : BitVec 7) : BitVec 3 :=
  let n := e.toNat
  let b (i : Nat) := ((n >>> i) &&& 1) == 1
  let s0 := xor (xor (b 0) (b 2)) (xor (b 4) (b 6))
  let s1 := xor (xor (b 1) (b 2)) (xor (b 5) (b 6))
  let s2 := xor (xor (b 3) (b 4)) (xor (b 5) (b 6))
  let v := (if s0 then 1 else 0) ||| (if s1 then 2 else 0) ||| (if s2 then 4 else 0)
  BitVec.ofNat 3 v

/-- Bounded-distance weight-$\le 1$ syndrome decoder for `BCH(7, 4, 3)` (`decode7`). -/
def decode7 (s : BitVec 3) : BitVec 7 :=
  if s.toNat == 0 then 0#7 else BitVec.ofNat 7 (1 <<< (s.toNat - 1))

/-- All $\binom{7}{0} + \binom{7}{1} = 8$ error patterns of weight $\le 1$ in `BitVec 7` (`all8Bch7WeightLe1Errors`). -/
def all8Bch7WeightLe1Errors : List (BitVec 7) :=
  [0#7] ++ (List.range 7).map (fun j => BitVec.ofNat 7 (1 <<< j))

/-- Fast unrolled 7-bit XOR parity (`xorParity7`), proven equivalent to `BitVec.xorParity` below. -/
def xorParity7 (v : BitVec 7) : Bool :=
  let n := v.toNat
  let n1 := Nat.xor n (n >>> 4)
  let n2 := Nat.xor n1 (n1 >>> 2)
  ((Nat.xor n2 (n2 >>> 1)) &&& 1) == 1

/-- Helper lemma: `xorParity7 v = v.xorParity` for all `v : BitVec 7` (`xorParity7_eq_helper`). -/
theorem xorParity7_eq_helper (v : BitVec 7) : xorParity7 v = v.xorParity := by
  revert v
  decide

/-- All $2^7 = 128$ $X$-measurement outcome masks `m : BitVec 7` (`all128Masks7`). -/
def all128Masks7 : List (BitVec 7) :=
  (List.range 128).map (fun mNat => BitVec.ofNat 7 mNat)

/-- Exhaustive verifier over all `8 × 128 = 1,024` `(e, m)` pairs of `BCH(7, 4, 3)` (`checkAll1024Bch7EarlyMbuPairs`). -/
def checkAll1024Bch7EarlyMbuPairs (_u : Unit := ()) : Bool :=
  all8Bch7WeightLe1Errors.all (fun e =>
    let d := decode7 (syn7 e)
    all128Masks7.all (fun m =>
      let p1 := xorParity7 (m &&& e)
      let p2 := xorParity7 (m &&& d)
      (p1 == p2) && (xor p1 p2 == false)))

/-- Boolean check of `decode7 (syn7 e) == e` across all 8 weight-$\le 1$ errors (`checkAll8Bch7DecodeExact`). -/
def checkAll8Bch7DecodeExact (_u : Unit := ()) : Bool :=
  all8Bch7WeightLe1Errors.all (fun e => decode7 (syn7 e) == e)

/-- Helper lemma certifying `decode7 (syn7 e) = e` for all 8 weight-$\le 1$ errors (`bch7_decode_syn_helper`). -/
theorem bch7_decode_syn_helper :
    ∀ e ∈ all8Bch7WeightLe1Errors, decode7 (syn7 e) = e := by
  have hAll : checkAll8Bch7DecodeExact () = true := by decide
  intro e hMem
  exact eq_of_beq (List.all_eq_true.mp hAll e hMem)

/-- **`bch7_4_3_exhaustive_1024_pairs_early_mbu_phase_exact`**:
    Certifies `BCH(7, 4, 3)` Early-`MBU` Phase-Only `DQI` across all `8 × 128 = 1,024`
    `(e, m)` pairs (`checkAll1024Bch7EarlyMbuPairs () = true`) and universally for every
    `m : BitVec 7` and `e ∈ all8Bch7WeightLe1Errors`. -/
theorem bch7_4_3_exhaustive_1024_pairs_early_mbu_phase_exact (m : BitVec 7) :
    all8Bch7WeightLe1Errors.length * all128Masks7.length = 1024 ∧
    checkAll1024Bch7EarlyMbuPairs () = true ∧
    ∀ e ∈ all8Bch7WeightLe1Errors,
      (m &&& e).xorParity = (m &&& decode7 (syn7 e)).xorParity ∧
      xor (m &&& e).xorParity (m &&& decode7 (syn7 e)).xorParity = false := by
  refine ⟨by decide, by decide, ?_⟩
  intro e hMem
  have hDec : decode7 (syn7 e) = e := bch7_decode_syn_helper e hMem
  have h59a := early_mbu_phase_cancellation_algebraic_identity syn7 decode7 e m hDec
  exact ⟨h59a.1, h59a.2.1⟩

-- ============================================================================
-- Section 3: `BCH(15, 7, 5)` Peterson–Berlekamp `121 / 121` Exactness vs Stub
-- ============================================================================

/-- Multiply by primitive root $\alpha$ (`2`) in $\mathbb{F}_2[\alpha]/(\alpha^4 + \alpha + 1)$ (`gf16PolyStep`). -/
def gf16PolyStep (x : Nat) : Nat :=
  let sh := (x <<< 1) &&& 0xF
  if (x &&& 8) != 0 then Nat.xor sh 3 else sh

/-- Polynomial-basis multiplication in $\mathbb{F}_{2^4} = \mathbb{F}_2[\alpha]/(\alpha^4 + \alpha + 1)$ (`gf16PolyMul`). -/
def gf16PolyMul (a b : Nat) : Nat :=
  let x0 := a &&& 0xF
  let x1 := gf16PolyStep x0
  let x2 := gf16PolyStep x1
  let x3 := gf16PolyStep x2
  let t0 := if (b &&& 1) == 1 then x0 else 0
  let t1 := if ((b >>> 1) &&& 1) == 1 then x1 else 0
  let t2 := if ((b >>> 2) &&& 1) == 1 then x2 else 0
  let t3 := if ((b >>> 3) &&& 1) == 1 then x3 else 0
  Nat.xor (Nat.xor t0 t1) (Nat.xor t2 t3)

/-- Totalized inverse $a^{14}$ (`0^-1 = 0`) in $\mathbb{F}_{2^4}$ (`gf16PolyInv`). -/
def gf16PolyInv (a : Nat) : Nat :=
  let a2 := gf16PolyMul a a
  let a4 := gf16PolyMul a2 a2
  let a8 := gf16PolyMul a4 a4
  gf16PolyMul a2 (gf16PolyMul a4 a8)

/-- Power $\alpha^{k \bmod 15}$ in $\mathbb{F}_{2^4}^\times$ (`gf16AlphaPow`). -/
def gf16AlphaPow (k : Nat) : Nat :=
  let e := k % 15
  let r0 := if (e &&& 1) == 1 then 2 else 1
  let r1 := if ((e >>> 1) &&& 1) == 1 then gf16PolyMul r0 4 else r0
  let r2 := if ((e >>> 2) &&& 1) == 1 then gf16PolyMul r1 3 else r1
  if ((e >>> 3) &&& 1) == 1 then gf16PolyMul r2 5 else r2

/-- Fast `Nat` syndrome calculation $(S_1 | (S_3 \ll 4))$ on 15-bit error mask (`syn15Nat`). -/
def syn15Nat (eMask : Nat) : Nat :=
  let (s1, s3) := (List.range 15).foldl (fun (a1, a3) i =>
    if ((eMask >>> i) &&& 1) == 1 then
      (Nat.xor a1 (gf16AlphaPow i), Nat.xor a3 (gf16AlphaPow (3 * i)))
    else (a1, a3)) (0, 0)
  s1 ||| (s3 <<< 4)

/-- Fast `Nat` Peterson–Berlekamp + Chien decoder on 8-bit syndrome (`decode15PBNat`). -/
def decode15PBNat (raw : Nat) : Nat :=
  let s1 := raw &&& 0xF
  let s3 := (raw >>> 4) &&& 0xF
  let s1Sq := gf16PolyMul s1 s1
  let num := Nat.xor s3 (gf16PolyMul s1Sq s1)
  let sigma2 := gf16PolyMul num (gf16PolyInv s1)
  (List.range 15).foldl (fun acc i =>
    let xInv := gf16AlphaPow (15 - (i % 15))
    let xInvSq := gf16PolyMul xInv xInv
    let lam := Nat.xor 1 (Nat.xor (gf16PolyMul s1 xInv) (gf16PolyMul sigma2 xInvSq))
    if lam == 0 then acc ||| (1 <<< i) else acc) 0

/-- Syndrome map $H : \text{BitVec } 15 \to \text{BitVec } 8$ packing $(S_1, S_3)$ (`syn15`). -/
def syn15 (e : BitVec 15) : BitVec 8 :=
  BitVec.ofNat 8 (syn15Nat e.toNat)

/-- Branchless Peterson–Berlekamp + Chien bounded-distance decoder for `BCH(15, 7, 5)` (`decode15PB`). -/
def decode15PB (syn : BitVec 8) : BitVec 15 :=
  BitVec.ofNat 15 (decode15PBNat syn.toNat)

/-- Incomplete `Law U1`-violating weight-1 Hamming stub decoder (`decode15Wt1StubNat`). -/
def decode15Wt1StubNat (raw : Nat) : Nat :=
  let s1 := raw &&& 0xF
  if s1 == 0 then 0
  else
    (List.range 15).foldl (fun acc i =>
      if gf16AlphaPow i == s1 then acc ||| (1 <<< i) else acc) 0

/-- All $\binom{15}{0} + \binom{15}{1} + \binom{15}{2} = 1 + 15 + 105 = 121$ weight-$\le 2$
    15-bit error masks (`all121WeightLe2NatMasks`). -/
def all121WeightLe2NatMasks : List Nat :=
  [0] ++
  ((List.range 15).map (fun i => 1 <<< i)) ++
  ((List.range 15).foldl (fun acc i =>
    acc ++ ((List.range i).map (fun j => (1 <<< i) ||| (1 <<< j)))) [])

/-- Corresponding list of 121 `BitVec 15` weight-$\le 2$ errors (`all121Bch15WeightLe2Errors`). -/
def all121Bch15WeightLe2Errors : List (BitVec 15) :=
  all121WeightLe2NatMasks.map (BitVec.ofNat 15)

/-- Executable exactness check across all 121 weight-$\le 2$ `BCH(15, 7, 5)` errors (`all121Bch15EarlyMbuPhaseExact`). -/
def all121Bch15EarlyMbuPhaseExact (_u : Unit := ()) : Bool :=
  all121Bch15WeightLe2Errors.all (fun e => decode15PB (syn15 e) == e)

/-- Counts how many of the 121 weight-$\le 2$ errors are corrupted by `decode15Wt1StubNat` (`countBch15Wt1StubCorrupted`). -/
def countBch15Wt1StubCorrupted (_u : Unit := ()) : Nat :=
  (all121WeightLe2NatMasks.filter (fun e => decode15Wt1StubNat (syn15Nat e) != e)).length

/-- Helper lemma certifying `decode15PB (syn15 e) = e` for all 121 weight-$\le 2$ errors (`bch15_pb_decode_syn_helper`). -/
theorem bch15_pb_decode_syn_helper :
    ∀ e ∈ all121Bch15WeightLe2Errors, decode15PB (syn15 e) = e := by
  have hAll : all121Bch15EarlyMbuPhaseExact () = true := by decide
  intro e hMem
  exact eq_of_beq (List.all_eq_true.mp hAll e hMem)

/-- **`bch15_7_5_peterson_berlekamp_121_exact_vs_stub_105_corrupted`**:
    Proves that `BCH(15, 7, 5)` Peterson–Berlekamp Early-`MBU` decoding achieves exact phase
    cancellation across `121 / 121` weight-$\le 2$ errors and ALL $2^{15}$ masks `m : BitVec 15`
    (`all121Bch15EarlyMbuPhaseExact () = true`), whereas the `Law U1`-violating `wt<=1` stub
    corrupts `105 / 121` (`86.78%`) weight-2 errors (`121 - 105 = 16` exact). -/
theorem bch15_7_5_peterson_berlekamp_121_exact_vs_stub_105_corrupted
    (m : BitVec 15) :
    all121Bch15WeightLe2Errors.length = 121 ∧
    all121Bch15EarlyMbuPhaseExact () = true ∧
    countBch15Wt1StubCorrupted () = 105 ∧
    ∀ e ∈ all121Bch15WeightLe2Errors,
      (m &&& e).xorParity = (m &&& decode15PB (syn15 e)).xorParity ∧
      xor (m &&& e).xorParity (m &&& decode15PB (syn15 e)).xorParity = false := by
  refine ⟨by decide, by decide, by decide, ?_⟩
  intro e hMem
  have hDec : decode15PB (syn15 e) = e := bch15_pb_decode_syn_helper e hMem
  have h59a := early_mbu_phase_cancellation_algebraic_identity syn15 decode15PB e m hDec
  exact ⟨h59a.1, h59a.2.1⟩

-- ============================================================================
-- Section 4: `Law U4` Necessity — Non-Zero Error Flips `64 / 128` Signs
-- ============================================================================

/-- Counts how many of the $2^7 = 128$ $X$-measurement masks `m : BitVec 7` induce a `-1`
    phase flip (`xorParity7 (m &&& e) = true`) when `Law U4` fixup is omitted (`countSignFlipsBch7`). -/
def countSignFlipsBch7 (e : BitVec 7) : Nat :=
  let eNat := e.toNat
  ((List.range 128).filter (fun mNat =>
    let v := mNat &&& eNat
    let v1 := Nat.xor v (v >>> 4)
    let v2 := Nat.xor v1 (v1 >>> 2)
    ((Nat.xor v2 (v2 >>> 1)) &&& 1) == 1)).length

/-- Signed character sum $\sum_{m \in \{0,1\}^7} (-1)^{m \cdot e}$ (`signedPhaseSumBch7`). -/
def signedPhaseSumBch7 (e : BitVec 7) : Int :=
  let eNat := e.toNat
  (List.range 128).foldl (fun acc mNat =>
    let v := mNat &&& eNat
    let v1 := Nat.xor v (v >>> 4)
    let v2 := Nat.xor v1 (v1 >>> 2)
    acc + (if ((Nat.xor v2 (v2 >>> 1)) &&& 1) == 1 then (-1 : Int) else 1)) 0

/-- Helper checking all 127 non-zero `BitVec 7` error patterns (`checkAll127NonZeroFlips64`). -/
def checkAll127NonZeroFlips64 (_u : Unit := ()) : Bool :=
  (List.range 128).all (fun k =>
    let e := BitVec.ofNat 7 k
    (e == 0#7) || ((countSignFlipsBch7 e == 64) && (signedPhaseSumBch7 e == 0)))

/-- **`law_u4_necessity_nonzero_error_flips_64_of_128_signs`**:
    Proves `Law U4` necessity: for EVERY non-zero 7-bit error `e ≠ 0#7` (including all 7
    non-zero `BCH(7, 4, 3)` weight-1 errors), omitting the `(-1)^{m \cdot D(s)}` phase fixup
    flips the sign on `exactly half` (`64 / 128`) of $X$-measurement masks `m`, driving the
    signed interference sum $\sum_m (-1)^{m \cdot e}$ to `0`! -/
theorem law_u4_necessity_nonzero_error_flips_64_of_128_signs
    (e : BitVec 7) (hNonZero : e ≠ 0#7) :
    countSignFlipsBch7 e = 64 ∧
    signedPhaseSumBch7 e = 0 ∧
    countSignFlipsBch7 0#7 = 0 ∧
    checkAll127NonZeroFlips64 () = true := by
  have hAll : checkAll127NonZeroFlips64 () = true := by decide
  have hMem : e.toNat ∈ List.range 128 := List.mem_range.mpr e.isLt
  have hEq : BitVec.ofNat 7 e.toNat = e :=
    BitVec.eq_of_toNat_eq (by simp)
  have hRow := List.all_eq_true.mp hAll e.toNat hMem
  dsimp only at hRow
  rw [hEq] at hRow
  have hNeBool : (e == 0#7) = false := beq_false_of_ne hNonZero
  rw [hNeBool, Bool.false_or, Bool.and_eq_true] at hRow
  exact ⟨eq_of_beq hRow.1, eq_of_beq hRow.2, by decide, hAll⟩

-- ============================================================================
-- Section 5: Live-Qubit & `Φ1` Active-Decoherence Volume Reduction (59E & 59F)
-- ============================================================================

/-- Stage-3 live data/syndrome wire count for Standard `erase-by` `DQI` (`dqiStandardLiveWires`). -/
def dqiStandardLiveWires (nErr kSynd : Nat) : Nat :=
  nErr + kSynd

/-- Stage-3 live data/syndrome wire count for Early-`MBU` Phase-Only `DQI` (`dqiEarlyMbuLiveWires`). -/
def dqiEarlyMbuLiveWires (_nErr kSynd : Nat) : Nat :=
  kSynd

/-- Stage-3 active qubit-cycle decoherence volume (`Φ1`) for Standard `DQI` (`dqiStandardDecoderVolume`). -/
def dqiStandardDecoderVolume (nErr kSynd tauDec : Nat) : Nat :=
  (nErr + kSynd) * tauDec

/-- Stage-3 active qubit-cycle decoherence volume (`Φ1`) for Early-`MBU` `DQI` (`dqiEarlyMbuDecoderVolume`). -/
def dqiEarlyMbuDecoderVolume (_nErr kSynd tauDec : Nat) : Nat :=
  kSynd * tauDec

/-- **`early_mbu_live_qubit_and_phi1_decoherence_volume_reduction`**:
    Proves that releasing all `nErr` error wires via Stage-2 `M_X` before Stage-3 decoding
    strictly reduces live qubit width (`kSynd < nErr + kSynd`) and `Φ1` active decoherence
    volume (`kSynd * tauDec < (nErr + kSynd) * tauDec`, saving exactly `nErr * tauDec`
    qubit-cycles) whenever `0 < nErr` and `0 < tauDec`. -/
theorem early_mbu_live_qubit_and_phi1_decoherence_volume_reduction
    (nErr kSynd tauDec : Nat) (hPosN : 0 < nErr) (hPosTau : 0 < tauDec) :
    dqiEarlyMbuLiveWires nErr kSynd < dqiStandardLiveWires nErr kSynd ∧
    dqiEarlyMbuDecoderVolume nErr kSynd tauDec < dqiStandardDecoderVolume nErr kSynd tauDec ∧
    dqiStandardDecoderVolume nErr kSynd tauDec - dqiEarlyMbuDecoderVolume nErr kSynd tauDec =
      nErr * tauDec ∧
    dqiEarlyMbuLiveWires 7 3 = 3 ∧ dqiStandardLiveWires 7 3 = 10 ∧
    dqiEarlyMbuLiveWires 15 8 = 8 ∧ dqiStandardLiveWires 15 8 = 23 := by
  unfold dqiEarlyMbuLiveWires dqiStandardLiveWires dqiEarlyMbuDecoderVolume dqiStandardDecoderVolume
  have hLtWires : kSynd < nErr + kSynd := by omega
  have hLtVol : kSynd * tauDec < (nErr + kSynd) * tauDec :=
    Nat.mul_lt_mul_of_pos_right hLtWires hPosTau
  have hDiff : (nErr + kSynd) * tauDec - kSynd * tauDec = nErr * tauDec := by
    rw [Nat.add_mul, Nat.add_sub_cancel]
  exact ⟨hLtWires, hLtVol, hDiff, rfl, rfl, rfl, rfl⟩

/-- Parametric Reed–Solomon / OPI `DQI` code profile over $\mathbb{F}_{2^m}$ (`OpiDqiProfile`). -/
structure OpiDqiProfile where
  fieldDegree   : Nat
  paritySymbols : Nat
  nErrorWires   : Nat
  kSyndWires    : Nat
  deriving DecidableEq, Repr

/-- Constructs the primitive $\mathbb{F}_{2^m}$ Optimal Polynomial Intersection (`OPI`) profile
    with blocklength $n = 2^m - 1$ and binary syndrome width $k_{\text{synd}} = m \cdot r$ (`mkOpiDqiProfile`). -/
def mkOpiDqiProfile (fieldDegree paritySymbols : Nat) : OpiDqiProfile :=
  { fieldDegree   := fieldDegree
  , paritySymbols := paritySymbols
  , nErrorWires   := (1 <<< fieldDegree) - 1
  , kSyndWires    := fieldDegree * paritySymbols }

/-- **`khattar_babbush_opi_4095_840_asymptotic_space_savings`**:
    Certifies the asymptotic Stage-3 live-qubit savings on the `Khattar–Babbush 2025` OPI
    benchmark over $\mathbb{F}_{2^{12}}$ (`fieldDegree = 12`, `paritySymbols = 70` $\implies$
    `n = 4095`, `k_synd = 840`): live data/syndrome qubits during Berlekamp–Massey / Extended
    Euclidean decoding drop from `4,935` to `840` (`840 < 4935`), saving `4,095` logical qubits
    and `4095 * tauDec` active decoherence volume for all `tauDec > 0`. -/
theorem khattar_babbush_opi_4095_840_asymptotic_space_savings
    (tauDec : Nat) (hPosTau : 0 < tauDec) :
    let kb := mkOpiDqiProfile 12 70
    kb.nErrorWires = 4095 ∧
    kb.kSyndWires = 840 ∧
    dqiEarlyMbuLiveWires kb.nErrorWires kb.kSyndWires = 840 ∧
    dqiStandardLiveWires kb.nErrorWires kb.kSyndWires = 4935 ∧
    dqiEarlyMbuLiveWires kb.nErrorWires kb.kSyndWires <
      dqiStandardLiveWires kb.nErrorWires kb.kSyndWires ∧
    dqiStandardLiveWires kb.nErrorWires kb.kSyndWires -
      dqiEarlyMbuLiveWires kb.nErrorWires kb.kSyndWires = 4095 ∧
    dqiEarlyMbuDecoderVolume kb.nErrorWires kb.kSyndWires tauDec <
      dqiStandardDecoderVolume kb.nErrorWires kb.kSyndWires tauDec := by
  dsimp only
  have h59e :=
    early_mbu_live_qubit_and_phi1_decoherence_volume_reduction 4095 840 tauDec
      (by decide) hPosTau
  refine ⟨by decide, by decide, by decide, by decide, by decide, by decide, ?_⟩
  simpa [mkOpiDqiProfile] using h59e.2.1

-- ============================================================================
-- Section 6: Master Module Closure & Executable Sanity Suite
-- ============================================================================

/-- Consolidated executable sanity checker for Early-MBU Phase-Only DQI (`verifyEarlyMbuPhaseOnlyDqiModuleSanity`). -/
def verifyEarlyMbuPhaseOnlyDqiModuleSanity (_u : Unit := ()) : Bool :=
  let kb := mkOpiDqiProfile 12 70
  checkAll1024Bch7EarlyMbuPairs () &&
  all121Bch15EarlyMbuPhaseExact () &&
  (countBch15Wt1StubCorrupted () == 105) &&
  checkAll127NonZeroFlips64 () &&
  (dqiEarlyMbuLiveWires 7 3 == 3) &&
  (dqiStandardLiveWires 7 3 == 10) &&
  (dqiEarlyMbuLiveWires 15 8 == 8) &&
  (dqiStandardLiveWires 15 8 == 23) &&
  (kb.nErrorWires == 4095) &&
  (kb.kSyndWires == 840) &&
  (dqiEarlyMbuLiveWires kb.nErrorWires kb.kSyndWires <
    dqiStandardLiveWires kb.nErrorWires kb.kSyndWires)

/-- **`early_mbu_phase_only_dqi_module_closure`**:
    Unites all Early-MBU Phase-Only DQI theorems and certifies `verifyEarlyMbuPhaseOnlyDqiModuleSanity () = true`. -/
theorem early_mbu_phase_only_dqi_module_closure
    (m7 : BitVec 7) (m15 : BitVec 15) (eNonZero : BitVec 7)
    (hNonZero : eNonZero ≠ 0#7) (tauDec : Nat) (hPosTau : 0 < tauDec) :
    checkAll1024Bch7EarlyMbuPairs () = true ∧
    all121Bch15EarlyMbuPhaseExact () = true ∧
    countBch15Wt1StubCorrupted () = 105 ∧
    countSignFlipsBch7 eNonZero = 64 ∧
    (∀ e ∈ all8Bch7WeightLe1Errors,
      xor (m7 &&& e).xorParity (m7 &&& decode7 (syn7 e)).xorParity = false) ∧
    (∀ e ∈ all121Bch15WeightLe2Errors,
      xor (m15 &&& e).xorParity (m15 &&& decode15PB (syn15 e)).xorParity = false) ∧
    dqiEarlyMbuDecoderVolume 4095 840 tauDec < dqiStandardDecoderVolume 4095 840 tauDec ∧
    verifyEarlyMbuPhaseOnlyDqiModuleSanity () = true := by
  have h59b := bch7_4_3_exhaustive_1024_pairs_early_mbu_phase_exact m7
  have h59c := bch15_7_5_peterson_berlekamp_121_exact_vs_stub_105_corrupted m15
  have h59d := law_u4_necessity_nonzero_error_flips_64_of_128_signs eNonZero hNonZero
  have h59f := khattar_babbush_opi_4095_840_asymptotic_space_savings tauDec hPosTau
  refine ⟨h59b.2.1, h59c.2.1, h59c.2.2.1, h59d.1,
          fun e he => (h59b.2.2 e he).2,
          fun e he => (h59c.2.2.2 e he).2,
          ?_, ?_⟩
  · simpa [mkOpiDqiProfile] using h59f.2.2.2.2.2.2
  · unfold verifyEarlyMbuPhaseOnlyDqiModuleSanity
    rw [h59b.2.1, h59c.2.1, h59c.2.2.1, h59d.2.2.2]
    decide

#eval verifyEarlyMbuPhaseOnlyDqiModuleSanity ()

end EarlyMbuPhaseOnlyDqiProofs
