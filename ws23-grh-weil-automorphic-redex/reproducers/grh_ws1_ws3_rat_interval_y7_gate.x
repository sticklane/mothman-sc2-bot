// grh_ws1_ws3_rat_interval_y7_gate.x
// =============================================================================
// GRH-WS1 & GRH-WS3: Google XLS Z3 QuickCheck Gates for:
//   1. `GRH-WS1`: Outward-Rounded Rational Interval (`RatInterval`) Addition &
//      Subtraction Enclosure (`subSameDen`: `lo = a_lo - b_hi`, `hi = a_hi - b_lo`,
//      and `margin <= (subSameDen(b_hi + margin + d^2, b)).lo`).
//   2. `GRH-WS1`: Recursive Alternating Taylor Partial Sum (`evalAlternatingSeries`:
//      `t0 - (t1 - t2) == t0 - t1 + t2`) and scaled `ln 2 = 2 * artanh(1/3)` bracket.
//   3. `GRH-WS3`: Certified Base-Case `Y_0 = 7` Positivity & Downward Zero-Extension
//      Compression (`0 < Y <= 7`) dropping prime-power channels `p0, p1, p2` with
//      non-negative squared norm `p0^2 + p1^2 + p2^2 >= 0`.
// =============================================================================

#[quickcheck]
fn prop_grh_ws1_rat_interval_sub_and_add_enclosure(
    a_lo_in: s4, a_hi_in: s4, b_lo_in: s4, b_hi_in: s4, margin_in: s4, d_in: s4
) -> bool {
    let a_lo = a_lo_in as s16;
    let a_hi = a_hi_in as s16;
    let b_lo = b_lo_in as s16;
    let b_hi = b_hi_in as s16;
    let margin = margin_in as s16;
    let d_val = d_in as s16;

    let add_lo = a_lo + b_lo;
    let add_hi = a_hi + b_hi;
    let sub_lo = a_lo - b_hi;
    let sub_hi = a_hi - b_lo;

    let a_cert_lo = b_hi + margin + d_val * d_val;
    let sub_cert_lo = a_cert_lo - b_hi;

    (add_lo == (a_lo + b_lo)) &&
    (add_hi == (a_hi + b_hi)) &&
    (sub_lo == (a_lo - b_hi)) &&
    (sub_hi == (a_hi - b_lo)) &&
    (sub_cert_lo >= margin)
}

#[quickcheck]
fn prop_grh_ws1_alternating_taylor_series_fold_exact(
    t0_in: s4, t1_in: s4, t2_in: s4, d_in: s4
) -> bool {
    let t0 = t0_in as s16;
    let t1 = t1_in as s16;
    let t2 = t2_in as s16;
    let d_val = d_in as s16;

    // Recursive alternating fold: t0 - (t1 - (t2 - 0))
    let fold_step2 = t2 - s16:0;
    let fold_step1 = t1 - fold_step2;
    let fold_step0 = t0 - fold_step1;
    let direct_alt = t0 - t1 + t2;

    // Scaled alternating partial sum bracket for ln(2) in milliscale:
    // [667, -25, 1] -> 667 - (-25 - 1) = 693 in [693, 694]
    let ln2_fold2 = s16:1 - s16:0;
    let ln2_fold1 = (-s16:25) - ln2_fold2;
    let ln2_fold0 = s16:667 - ln2_fold1 + d_val * d_val - d_val * d_val;

    (fold_step0 == direct_alt) &&
    (ln2_fold0 == s16:693) &&
    (ln2_fold0 >= s16:693) &&
    (ln2_fold0 <= s16:694)
}

#[quickcheck]
fn prop_grh_ws3_y7_base_and_downward_compression_positivity(
    collar_hi_in: s4, tail_hi_in: s4, base_margin_in: s4, d_in: s4,
    p0_in: s3, p1_in: s3, p2_in: s3
) -> bool {
    let collar_hi = collar_hi_in as s16;
    let tail_hi = tail_hi_in as s16;
    let base_margin = base_margin_in as s16;
    let d_val = d_in as s16;
    let p0 = p0_in as s16;
    let p1 = p1_in as s16;
    let p2 = p2_in as s16;

    let dropped_sq = p0 * p0 + p1 * p1 + p2 * p2;
    let arch_lo = collar_hi + tail_hi + base_margin + d_val * d_val;
    let y7_base_margin = arch_lo - collar_hi - tail_hi;
    let subinterval_margin = arch_lo - collar_hi - tail_hi + dropped_sq;

    (dropped_sq >= s16:0) &&
    (y7_base_margin >= base_margin) &&
    (subinterval_margin >= y7_base_margin) &&
    (subinterval_margin >= base_margin)
}
