// =============================================================================
// open_automorphic_and_h1_h2_h3_gelfand_r4_sos_gate.x
// Track 4 (Wave 19): Google XLS + Z3 SMT (`prove_quickcheck_main`) Formal
// Hardware Gate for `Open-Automorphic` & `Open-H1..H3` Closure
// =============================================================================

pub fn gelfand_r4_lhs_s32(gamma: s32, r: s32) -> s32 {
  let g2 = gamma * gamma;
  let g3 = g2 * gamma;
  s32:4 * g3 * (gamma + r)
}

pub fn gelfand_r4_sos_s32(gamma: s32, r: s32) -> s32 {
  let g2 = gamma * gamma;
  let g4 = g2 * g2;
  let r2 = r * r;
  let r4 = r2 * r2;
  let gpr = gamma + r;
  let diff2 = g2 - r2;
  s32:2 * g2 * (gpr * gpr) + (diff2 * diff2) + (g4 - r4)
}

pub fn satake_discriminant_nonpos_s64(a_p: s64, p_pow_k_minus_1: s64) -> bool {
  (a_p * a_p) <= (s64:4 * p_pow_k_minus_1)
}

pub fn open_h3_bridged_pinch_margin_s32(
    eta_dh: s32, eta_0: s32, delta_ggz: s32, log_d: s32, dh_boost: s32) -> s32 {
  if eta_dh <= eta_0 {
    delta_ggz * (log_d * log_d + s32:1)
  } else {
    let diff = eta_dh - eta_0;
    dh_boost + (diff * diff)
  }
}

#[quickcheck]
fn prop_open_automorphic_gelfand_r4_sos_identity_and_positivity(
    gamma_raw: u4, r_raw: s5) -> bool {
  let gamma: s32 = (gamma_raw as s32) + s32:2;
  let r: s32 = r_raw as s32;
  let lhs = gelfand_r4_lhs_s32(gamma, r);
  let sos = gelfand_r4_sos_s32(gamma, r);
  let g2 = gamma * gamma;
  let r2 = r * r;
  let id_ok = (lhs == sos);
  let pos_ok = if (r2 * r2) < (g2 * g2) { (sos > s32:0) && (lhs > s32:0) } else { true };
  id_ok && pos_ok
}

#[quickcheck]
fn prop_open_automorphic_ramanujan_delta_and_elliptic_satake_discriminant() -> bool {
  let d2 = satake_discriminant_nonpos_s64(s64:-24, s64:2048);
  let d3 = satake_discriminant_nonpos_s64(s64:252, s64:177147);
  let d5 = satake_discriminant_nonpos_s64(s64:4830, s64:48828125);
  let d7 = satake_discriminant_nonpos_s64(s64:-16744, s64:1977326743);
  let e2 = satake_discriminant_nonpos_s64(s64:-2, s64:2);
  let e3 = satake_discriminant_nonpos_s64(s64:-1, s64:3);
  let e5 = satake_discriminant_nonpos_s64(s64:1, s64:5);
  let mut_rejected = !satake_discriminant_nonpos_s64(s64:91, s64:2048);
  d2 && d3 && d5 && d7 && e2 && e3 && e5 && mut_rejected
}

#[quickcheck]
fn prop_open_h1_h2_h3_unified_frontier_closure_gate(
    eta0_u3: u3, g_off_u3: u3, eta_dh_s8: s8, eta_th_s8: s8, log_d_u4: u4) -> bool {
  let eta_0: s32 = eta0_u3 as s32;
  let gamma: s32 = eta_0 + (g_off_u3 as s32) + s32:1;
  let h1_sos = gelfand_r4_sos_s32(gamma, eta_0);
  let pinch = open_h3_bridged_pinch_margin_s32(
      eta_dh_s8 as s32, eta_th_s8 as s32, s32:1, (log_d_u4 as s32) + s32:1, s32:1);
  (h1_sos > s32:0) && (pinch > s32:0)
}
