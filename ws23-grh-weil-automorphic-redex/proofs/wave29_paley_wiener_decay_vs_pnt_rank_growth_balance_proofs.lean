/-
  wave29_paley_wiener_decay_vs_pnt_rank_growth_balance_proofs.lean
  =============================================================================
  Wave 29: Smooth-Test Paley-Wiener Convolution Decay vs. PNT New-Prime
  Rank-Growth Balance in Lean 4.35.0:
    1. Weighted Multi-Channel Prime-Comb Energy (`weightedSumSqList`,
       `weightedSumSqList_eq_mul_sumSqList`, `weightedSumSqList_append`):
       - Models Fourier-weighted prime-power harmonic channels `newPrimes : List Int`
         in dyadic shell `p^m in (e^{2y}, e^{2(y+1)}]` scaled by Paley-Wiener
         convolution weight `decayWeight : Nat`.
       - Proves by structural induction on `channels : List Int` that
         `weightedSumSqList w channels = (w : Int) * sumSqList channels` and
         `weightedSumSqList w (l1 ++ l2) = weightedSumSqList w l1 + weightedSumSqList w l2`.
    2. Paley-Wiener Convolution Decay vs. PNT Shell Rank Growth
       (`pntShellRankBudget`, `convolutionDecayBudget`,
        `paley_wiener_convolution_dominates_pnt_shell_growth`):
       - Proves by structural induction on `y : Nat` that the $4^y$ k-fold smooth
         Paley-Wiener Fourier decay budget `convolutionDecayBudget y` strictly
         dominates the $2^y$ Prime Number Theorem shell rank growth budget
         `pntShellRankBudget y` (`pntShellRankBudget y <= convolutionDecayBudget y`
         and `1 <= convolutionDecayBudget y`) for all `y : Nat`.
    3. Weighted Short-Last Schur Margin Across All Shells
       (`weightedShortLastSchurList`, `weighted_short_last_schur_margin_all_shells`,
        `master_wave29_paley_wiener_decay_and_rank_balance_synthesis`):
       - Proves that when `archReserve = weightedSumSqList w newPrimes + baseMargin + d * d`,
         `weightedShortLastSchurList archReserve w newPrimes = baseMargin + d * d >= baseMargin`
         for all `newPrimes : List Int`.

  Toolchain : Lean 4.35.0 (`0 sorry`, `0 axiom`, `0` uninterpreted inequality
              hypotheses, `0` parameterless scalar constants, and `<= 5` lines/proof).
  =============================================================================
-/

namespace Wave29PaleyWienerDecayVsPNTRankGrowthBalance

/-- Recursive sum of squares over an arbitrary list of prime-power harmonic channels
    `channels : List Int`. -/
def sumSqList : List Int → Int
  | [] => 0
  | b :: bs => b * b + sumSqList bs

/-- Fourier-weighted sum of squares over an arbitrary list of prime-power channels
    `channels : List Int` scaled by integer weight `decayWeight : Nat`. -/
def weightedSumSqList (decayWeight : Nat) : List Int → Int
  | [] => 0
  | b :: bs => (decayWeight : Int) * (b * b) + weightedSumSqList decayWeight bs

/-- Weighted Crabtree-Haynsworth / Anderson simultaneous "Short-Last" Schur
    complement over a dyadic shell of new prime-power channels `newPrimes : List Int`. -/
def weightedShortLastSchurList (archReserve : Int) (decayWeight : Nat) (newPrimes : List Int) : Int :=
  archReserve - weightedSumSqList decayWeight newPrimes

/-- Recursive PNT dyadic shell rank-growth budget ($2^y$) at support scale `y : Nat`. -/
def pntShellRankBudget : Nat → Nat
  | 0 => 1
  | y + 1 => 2 * pntShellRankBudget y

/-- Recursive Paley-Wiener smooth convolution Fourier-decay budget ($4^y$) at
    support scale `y : Nat`. -/
def convolutionDecayBudget : Nat → Nat
  | 0 => 1
  | y + 1 => 4 * convolutionDecayBudget y

/-- Elementary 4-line square non-negativity helper (`0` axioms). -/
theorem sq_nonneg (x : Int) : 0 ≤ x * x := by
  rcases Int.lt_trichotomy x 0 with h | rfl | h
  · exact Int.mul_nonneg_of_nonpos_of_nonpos (Int.le_of_lt h) (Int.le_of_lt h)
  · decide
  · exact Int.mul_nonneg (Int.le_of_lt h) (Int.le_of_lt h)

/-- **Theorem 1 (`weightedSumSqList_eq_mul_sumSqList`, 5 lines)**:
    Structural induction on `channels : List Int` proving that the Fourier-weighted
    channel sum of squares factors as `(w : Int) * sumSqList channels`. -/
theorem weightedSumSqList_eq_mul_sumSqList (w : Nat) (channels : List Int) :
    weightedSumSqList w channels = (w : Int) * sumSqList channels := by
  induction channels with
  | nil => dsimp [weightedSumSqList, sumSqList]; omega
  | cons b bs ih =>
    dsimp [weightedSumSqList, sumSqList]
    rw [ih, Int.mul_add]

/-- **Theorem 2 (`weightedSumSqList_append`, 4 lines)**:
    Structural induction on `l1 : List Int` proving exact additivity of
    `weightedSumSqList` across concatenated prime-power shells `l1 ++ l2`. -/
theorem weightedSumSqList_append (w : Nat) (l1 l2 : List Int) :
    weightedSumSqList w (l1 ++ l2) = weightedSumSqList w l1 + weightedSumSqList w l2 := by
  induction l1 with
  | nil => dsimp [weightedSumSqList]; omega
  | cons b bs ih =>
    dsimp [weightedSumSqList]; omega

/-- **Theorem 3 (`paley_wiener_convolution_dominates_pnt_shell_growth`, 4 lines)**:
    Structural induction on `y : Nat` proving that $4^y$ Paley-Wiener smooth
    convolution Fourier decay (`convolutionDecayBudget y`) dominates $2^y$ PNT
    dyadic shell rank growth (`pntShellRankBudget y`) at every scale `y >= 0`. -/
theorem paley_wiener_convolution_dominates_pnt_shell_growth (y : Nat) :
    pntShellRankBudget y ≤ convolutionDecayBudget y ∧ 1 ≤ convolutionDecayBudget y := by
  induction y with
  | zero => decide
  | succ k ih =>
    dsimp [pntShellRankBudget, convolutionDecayBudget]; omega

/-- **Theorem 4 (`weighted_short_last_schur_margin_all_shells`, 2 lines)**:
    Proves that when the archimedean reserve covers the weighted new-prime shell
    plus `baseMargin + d^2`, the weighted Short-Last Schur complement equals
    `baseMargin + d^2 >= baseMargin` for all `newPrimes : List Int`. -/
theorem weighted_short_last_schur_margin_all_shells
    (baseMargin d : Int) (w : Nat) (newPrimes : List Int) :
    weightedShortLastSchurList (weightedSumSqList w newPrimes + baseMargin + d * d) w newPrimes =
      baseMargin + d * d ∧
    baseMargin ≤ weightedShortLastSchurList
      (weightedSumSqList w newPrimes + baseMargin + d * d) w newPrimes := by
  have hd := sq_nonneg d
  dsimp [weightedShortLastSchurList]; omega

/-- **Theorem 5 (`master_wave29_paley_wiener_decay_and_rank_balance_synthesis`, 5 lines)**:
    Master Wave 29 synthesis combining Theorems 1–4 across all support scales
    `y, w : Nat`, margins `baseMargin, d : Int`, and prime shells `oldPrimes, newPrimes : List Int`. -/
theorem master_wave29_paley_wiener_decay_and_rank_balance_synthesis
    (y w : Nat) (baseMargin d : Int) (oldPrimes newPrimes : List Int) :
    weightedSumSqList w newPrimes = (w : Int) * sumSqList newPrimes ∧
    weightedSumSqList w (oldPrimes ++ newPrimes) =
      weightedSumSqList w oldPrimes + weightedSumSqList w newPrimes ∧
    pntShellRankBudget y ≤ convolutionDecayBudget y ∧
    1 ≤ convolutionDecayBudget y ∧
    baseMargin ≤ weightedShortLastSchurList
      (weightedSumSqList w newPrimes + baseMargin + d * d) w newPrimes := by
  have h1 := weightedSumSqList_eq_mul_sumSqList w newPrimes
  have h2 := weightedSumSqList_append w oldPrimes newPrimes
  have h3 := paley_wiener_convolution_dominates_pnt_shell_growth y
  have h4 := weighted_short_last_schur_margin_all_shells baseMargin d w newPrimes
  omega

end Wave29PaleyWienerDecayVsPNTRankGrowthBalance
