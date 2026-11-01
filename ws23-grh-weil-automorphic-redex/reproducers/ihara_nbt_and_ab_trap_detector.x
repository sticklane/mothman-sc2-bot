// ============================================================================
// ihara_nbt_and_ab_trap_detector.x
// ============================================================================
// Hardware-Verified 0-DSP XLS DSLX Datapath for Track Next-3
// (`ws04-stage8-aes-sphincs-qldpc`, `ws12-symbolic-z3-rtl-iscas85-equiv`,
//  and `ws16-alphaqubit-okasaki-0dsp-decoder`):
//
//   1. 0-DSP Hashimoto Non-Backtracking 3-Term Chebyshev Recurrence Step:
//        m^{(t+1)} = A_sum - (d - 1) * m^{(t-1)}
//      for (3, 6)-biregular Bivariate Bicycle qLDPC Tanner graphs:
//        - Variable-node degree d_v = 3 (q_1 = d_v - 1 = 2):
//            m_v^{(t+1)} = A_sum - (m_prev << 1)
//        - Check-node degree d_c = 6 (q_2 = d_c - 1 = 5):
//            m_c^{(t+1)} = A_sum - ((m_prev << 2) + m_prev)
//      Realized with 0 DSP multipliers (pure bit-shifts and additions/subtractions).
//
//   2. Hardware A = B Weight-2 Twin-Column Syndrome Trap Detector:
//      Tests whether column i of left circulant block A (`syn_left`) and
//      column i of right circulant block B (`syn_right`) collide in F_2:
//        syn_xor = syn_left ^ syn_right
//        is_wt2_trap = (syn_xor == 0)
//      Certifies in 1 clock cycle whether the weight-2 paired error (e_i, e_i)
//      lies in ker(H) (`H (e_i, e_i)^T = A e_i ^ B e_i = 0`).
// ============================================================================

// 0-DSP Hashimoto Non-Backtracking step for variable nodes of degree d_v = 3 (d_v - 1 = 2):
//   m^{(t+1)} = a_sum - 2 * m^{(t-1)} = a_sum - (m_prev << 1)
pub fn hashimoto_nbt_var_deg3_step(a_sum: s16, m_prev: s16) -> s16 {
    let echo_deg3: s16 = m_prev << u32:1;
    a_sum - echo_deg3
}

// 0-DSP Hashimoto Non-Backtracking step for check nodes of degree d_c = 6 (d_c - 1 = 5):
//   m^{(t+1)} = a_sum - 5 * m^{(t-1)} = a_sum - ((m_prev << 2) + m_prev)
pub fn hashimoto_nbt_check_deg6_step(a_sum: s16, m_prev: s16) -> s16 {
    let echo_deg6: s16 = (m_prev << u32:2) + m_prev;
    a_sum - echo_deg6
}

// Hardware A = B twin-column weight-2 syndrome trap detector over F_2^16:
//   Returns (syn_xor, is_wt2_trap) where is_wt2_trap == 1 iff (syn_left ^ syn_right) == 0.
pub fn ab_twin_column_trap_detector(syn_left: u16, syn_right: u16) -> (u16, u1) {
    let syn_xor: u16 = syn_left ^ syn_right;
    let is_wt2_trap: u1 = if syn_xor == u16:0 { u1:1 } else { u1:0 };
    (syn_xor, is_wt2_trap)
}

// Top-level 64-bit input hardware entry point combining:
//   - 0-DSP Variable-Node (d_v = 3) Hashimoto Non-Backtracking Chebyshev recurrence
//   - 0-DSP Check-Node (d_c = 6) Hashimoto Non-Backtracking Chebyshev recurrence
//   - Hardware A = B Weight-2 Twin-Column Syndrome Trap Detector
pub fn ihara_nbt_and_ab_trap_detector_top(
    a_sum: s16,
    m_prev: s16,
    syn_left: u16,
    syn_right: u16
) -> (s16, s16, u16, u1) {
    let m_next_var: s16 = hashimoto_nbt_var_deg3_step(a_sum, m_prev);
    let m_next_chk: s16 = hashimoto_nbt_check_deg6_step(a_sum, m_prev);
    let (syn_xor, is_wt2_trap) = ab_twin_column_trap_detector(syn_left, syn_right);
    (m_next_var, m_next_chk, syn_xor, is_wt2_trap)
}

#[quickcheck]
fn prop_hashimoto_nbt_backtracking_echo_cancellation(clean_sig: s16, m_prev: s16) -> bool {
    let a_sum_var: s16 = clean_sig + (m_prev << u32:1);
    let a_sum_chk: s16 = clean_sig + ((m_prev << u32:2) + m_prev);
    let out_var: s16 = hashimoto_nbt_var_deg3_step(a_sum_var, m_prev);
    let out_chk: s16 = hashimoto_nbt_check_deg6_step(a_sum_chk, m_prev);
    (out_var == clean_sig) && (out_chk == clean_sig)
}

#[quickcheck]
fn prop_ab_twin_column_trap_detector_sound_and_complete(col_a: u16, delta: u16) -> bool {
    let (xor_same, trap_same) = ab_twin_column_trap_detector(col_a, col_a);
    let col_b: u16 = col_a ^ delta;
    let (xor_diff, trap_diff) = ab_twin_column_trap_detector(col_a, col_b);
    let same_ok: bool = (xor_same == u16:0) && (trap_same == u1:1);
    let iff_ok: bool = (trap_diff == u1:1) == (delta == u16:0);
    same_ok && (xor_diff == delta) && iff_ok
}

#[quickcheck]
fn prop_ihara_nbt_and_ab_trap_top_exact(
    a_sum: s16,
    m_prev: s16,
    syn_left: u16,
    syn_right: u16
) -> bool {
    let (m_v, m_c, sx, trap) = ihara_nbt_and_ab_trap_detector_top(a_sum, m_prev, syn_left, syn_right);
    let exp_v: s16 = a_sum - (m_prev + m_prev);
    let exp_c: s16 = a_sum - ((m_prev << u32:2) + m_prev);
    let exp_sx: u16 = syn_left ^ syn_right;
    let exp_trap: u1 = if syn_left == syn_right { u1:1 } else { u1:0 };
    (m_v == exp_v) && (m_c == exp_c) && (sx == exp_sx) && (trap == exp_trap)
}
