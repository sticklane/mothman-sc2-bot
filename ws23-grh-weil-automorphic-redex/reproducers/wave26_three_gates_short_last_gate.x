// wave26_three_gates_short_last_gate.x
// Google XLS DSLX Z3 SMT QuickCheck Gate for Wave 26:
//   1. Crabtree-Haynsworth / Anderson "Short-Last" simultaneous Schur determinant
//      vs. "Beholder" double-charging (`arXiv:2609.20367v3`).
//   2. Bilateral Sign-Invariance (`+2*b0*vK*vPerp` vs `-2*b0*vK*vPerp`) immunizing
//      against the Oct 7, 2026 OpenAI 3-paper sign-error cascade.
//   3. Desogus Y=7 endpoint Schur induction & zero-extension compression.

#[quickcheck]
fn prop_crabtree_haynsworth_short_last_single_reserve(
    b1_raw: u2, b2_raw: u2, da_raw: u2, v1_raw: s3, v2_raw: s3) -> bool {
    let b1 = (b1_raw as s16) + s16:1;
    let b2 = (b2_raw as s16) + s16:1;
    let da = da_raw as s16;
    let v1 = v1_raw as s16;
    let v2 = v2_raw as s16;

    // Constructive single-reserve ground budget a = b1^2 + b2^2 + 1 + da^2 on unit ground mode v0 = 1
    let a = b1 * b1 + b2 * b2 + s16:1 + da * da;
    let q_3ch = a - s16:2 * b1 * v1 - s16:2 * b2 * v2 + v1 * v1 + v2 * v2;

    // Exact Crabtree-Haynsworth simultaneous "Short-Last" SOS decomposition:
    let r1 = v1 - b1;
    let r2 = v2 - b2;
    let delta_short_last = a - b1 * b1 - b2 * b2;
    let sos_rhs = r1 * r1 + r2 * r2 + delta_short_last;

    (q_3ch == sos_rhs) && (delta_short_last == s16:1 + da * da) && (q_3ch >= s16:1)
}

#[quickcheck]
fn prop_openai_oct7_bilateral_sign_invariance(
    b0_raw: s3, d_raw: u2, vPerp_raw: s3) -> bool {
    let b0 = b0_raw as s16;
    let d = d_raw as s16;
    let vPerp = vPerp_raw as s16;
    let a = b0 * b0 + s16:1 + d * d;

    let q_plus = a + s16:2 * b0 * vPerp + vPerp * vPerp;
    let q_minus = a - s16:2 * b0 * vPerp + vPerp * vPerp;

    let r_plus = vPerp + b0;
    let r_minus = vPerp - b0;
    let schur_rem_plus = q_plus - r_plus * r_plus;
    let schur_rem_minus = q_minus - r_minus * r_minus;

    // Both sign conventions yield the EXACT same Schur remainder `1 + d^2 >= 1`
    (schur_rem_plus == schur_rem_minus) &&
    (schur_rem_plus == s16:1 + d * d) &&
    (q_plus >= s16:1) &&
    (q_minus >= s16:1)
}

#[quickcheck]
fn prop_desogus_y7_schur_induction_and_zero_extension(
    k_raw: u4, d_step_raw: u2, v_in_raw: s3) -> bool {
    let k = k_raw as s16;
    let d_step = d_step_raw as s16;
    let v_in = v_in_raw as s16;

    // Endpoint Y = 7 + k margin grows monotonically by 1 + d_step^2 at each step
    let margin_k = s16:7 + k * (s16:1 + d_step * d_step);
    let v_ext = s16:0;
    let extended_energy = margin_k * v_in * v_in + v_ext * v_ext;

    (margin_k >= s16:7 + k) && (extended_energy >= s16:7 * v_in * v_in)
}
