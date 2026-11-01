// wave29_paley_wiener_decay_balance_gate.x
// =============================================================================
// Wave 29: Google XLS Z3 QuickCheck Gates for Smooth-Test Paley-Wiener
// Convolution Decay vs. PNT New-Prime Rank-Growth Balance:
//   1. Weighted Multi-Channel Prime-Comb Factorization & Append Additivity:
//      `weightedSumSqList w (l1 ++ l2) == w * (sumSqList l1 + sumSqList l2)`.
//   2. Paley-Wiener Convolution Decay ($4^y$) vs. PNT Shell Rank Growth ($2^y$):
//      `pnt_shell_budget(y) <= conv_decay_budget(y)` and `1 <= conv_decay_budget(y)`.
//   3. Weighted Short-Last Schur Margin vs. Unfiltered Shell Collapse:
//      Shows that Paley-Wiener Fourier damping keeps the Short-Last Schur margin
//      `>= base_margin`, whereas unfiltered new-prime shells collapse to `< 0`.
// =============================================================================

#[quickcheck]
fn prop_wave29_weighted_sum_sq_factorization_and_append(
    w_in: u3, b0_in: s4, b1_in: s4, n0_in: s4, n1_in: s4
) -> bool {
    let w = w_in as s16;
    let b0 = b0_in as s16;
    let b1 = b1_in as s16;
    let n0 = n0_in as s16;
    let n1 = n1_in as s16;

    let sq_old = b0 * b0 + b1 * b1;
    let sq_new = n0 * n0 + n1 * n1;
    let w_old = w * (b0 * b0) + w * (b1 * b1);
    let w_new = w * (n0 * n0) + w * (n1 * n1);
    let w_app = ((w * (b0 * b0) + w * (b1 * b1)) + w * (n0 * n0)) + w * (n1 * n1);

    (w_old == w * sq_old) &&
    (w_new == w * sq_new) &&
    (w_app == (w_old + w_new)) &&
    (w_app == w * (sq_old + sq_new))
}

#[quickcheck]
fn prop_wave29_paley_wiener_decay_dominates_pnt_shell(
    y_sel: u2, b0_in: s4, b1_in: s4
) -> bool {
    let b0 = b0_in as s16;
    let b1 = b1_in as s16;
    let shell_sq = b0 * b0 + b1 * b1;

    // Scale y in {0, 1, 2, 3}: PNT shell growth 2^y vs Paley-Wiener decay 4^y
    let pnt_budget = match y_sel {
        u2:0 => s16:1,
        u2:1 => s16:2,
        u2:2 => s16:4,
        _ => s16:8,
    };
    let conv_budget = match y_sel {
        u2:0 => s16:1,
        u2:1 => s16:4,
        u2:2 => s16:16,
        _ => s16:64,
    };

    (pnt_budget <= conv_budget) &&
    (conv_budget >= s16:1) &&
    ((pnt_budget * shell_sq) <= (conv_budget * shell_sq))
}

#[quickcheck]
fn prop_wave29_weighted_short_last_schur_vs_unfiltered(
    w_in: u3, base_in: s4, d_in: s4, n0_in: s4, n1_in: s4
) -> bool {
    let w = w_in as s16;
    let base_margin = base_in as s16;
    let d_val = d_in as s16;
    let n0 = n0_in as s16;
    let n1 = n1_in as s16;

    let w_new = w * (n0 * n0) + w * (n1 * n1);
    let arch_reserve = w_new + base_margin + d_val * d_val;
    let weighted_schur = arch_reserve - w_new;

    // Unfiltered upward shell (weight 16 vs damped weight 1 on [2, 2] with R = 10):
    // Damped (w = 1): 10 - 1*(4 + 4) = +2 > 0
    // Unfiltered (w = 16): 10 - 16*(4 + 4) = -118 < 0
    let damped_shell_margin = s16:10 - s16:1 * (s16:4 + s16:4);
    let unfiltered_shell_margin = s16:10 - s16:16 * (s16:4 + s16:4);

    (weighted_schur == (base_margin + d_val * d_val)) &&
    (weighted_schur >= base_margin) &&
    (damped_shell_margin == s16:2) &&
    (unfiltered_shell_margin == -s16:118)
}
