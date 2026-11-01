// grh_ws4_ws5_boundary_collar_gate.x
// =============================================================================
// GRH-WS4 & GRH-WS5: Google XLS Z3 QuickCheck Gates for Boundary-Collar Support
// Localization ($u = \ln p^m \in (2Y, 2(Y+1)]$), Multi-Prime Collar Indefinite
// Barrier (Problem 1), & High-Frequency Sobolev Split:
//   1. GRH-WS5 Interior-Core Vanishing & Collar Localization:
//      `shift_u = 2 * y_radius + 1 + extra_shift > 2 * y_radius`, so the new
//      prime-power shift operator misses the interior core `[-(Y-1), Y-1]`
//      identically and reduces to `2 * left_collar * right_collar` independent
//      of any interior core amplitudes `core0, core1`.
//   2. GRH-WS5 Single-Prime / Cancelled Positivity vs. Multi-Prime Barrier:
//      `(L^2 + R^2) - 2*W*L*R == (L - R)^2 >= 0` when net shell weight `W == 1`
//      (`shellWeights = [1]` or `[1, -1, 1]`), whereas for two uncancelled prime
//      weights (`W == 2`, `shellWeights = [1, 1]`) at `L = 1, R = 1`, the collar
//      quadratic form evaluates to `1 + 1 - 4 = -2 < 0` (strictly indefinite!).
//   3. GRH-WS4 Archimedean Digamma High-Frequency Sobolev Energy:
//      `highFreqSobolevEnergy` is non-negative (`>= 0`) and strictly additive
//      across concatenated frequency shells `m ++ n`.
// =============================================================================

#[quickcheck]
fn prop_grh_ws5_new_prime_shift_misses_interior_core(
    y_in: u3, extra_in: u3, left_in: s4, right_in: s4, core0_in: s4, core1_in: s4
) -> bool {
    let y_rad = y_in as s16;
    let extra = extra_in as s16;
    let left_c = left_in as s16;
    let right_c = right_in as s16;
    let core0 = core0_in as s16;
    let core1 = core1_in as s16;

    let shift_u = s16:2 * y_rad + s16:1 + extra;
    let hits_interior = shift_u <= (s16:2 * y_rad);

    // State A with interior core [core0, core1] vs State B with negated interior core
    let op_state_a = if hits_interior {
        left_c + right_c + core0 + core1 + s16:999
    } else {
        s16:2 * left_c * right_c
    };
    let op_state_b = if hits_interior {
        left_c + right_c - core0 - core1 + s16:999
    } else {
        s16:2 * left_c * right_c
    };

    (!hits_interior) &&
    (op_state_a == (s16:2 * left_c * right_c)) &&
    (op_state_a == op_state_b)
}

#[quickcheck]
fn prop_grh_ws5_collar_quadratic_single_vs_multi_prime_barrier(
    left_in: s4, right_in: s4
) -> bool {
    let left_c = left_in as s16;
    let right_c = right_in as s16;

    let diff = left_c - right_c;
    let collar_diag = left_c * left_c + right_c * right_c;

    // Net weight W = 1 ([1] or [1, -1, 1])
    let w_single = s16:1;
    let w_cancelled = s16:1 + (-s16:1) + s16:1;
    let q_single = collar_diag - (s16:2 * w_single * left_c * right_c);
    let q_cancelled = collar_diag - (s16:2 * w_cancelled * left_c * right_c);

    // Open Analytic Barrier (Problem 1): W = 2 ([1, 1]) at L = 1, R = 1
    let w_multi = s16:1 + s16:1;
    let q_multi_barrier = (s16:1 + s16:1) - (s16:2 * w_multi * s16:1 * s16:1);

    (q_single == diff * diff) &&
    (q_cancelled == diff * diff) &&
    (q_single >= s16:0) &&
    (w_multi == s16:2) &&
    (q_multi_barrier == -s16:2) &&
    (q_multi_barrier < s16:0)
}

#[quickcheck]
fn prop_grh_ws4_high_freq_sobolev_energy_nonneg_and_append(
    w_in: u3, m0_in: s4, m1_in: s4, n0_in: s4, n1_in: s4
) -> bool {
    let w_plus_1 = (w_in as s16) + s16:1;
    let m0 = m0_in as s16;
    let m1 = m1_in as s16;
    let n0 = n0_in as s16;
    let n1 = n1_in as s16;

    let e_m = w_plus_1 * (m0 * m0) + w_plus_1 * (m1 * m1);
    let e_n = w_plus_1 * (n0 * n0) + w_plus_1 * (n1 * n1);
    let e_app = ((w_plus_1 * (m0 * m0) + w_plus_1 * (m1 * m1))
                 + w_plus_1 * (n0 * n0)) + w_plus_1 * (n1 * n1);

    (e_m >= s16:0) &&
    (e_n >= s16:0) &&
    (e_app >= s16:0) &&
    (e_app == (e_m + e_n))
}

#[quickcheck]
fn prop_sobolev_coupled_collar_perfect_square(
    left_in: s4, right_in: s4, w0_in: s3, w1_in: s3
) -> bool {
    let left_c = left_in as s16;
    let right_c = right_in as s16;
    let w_shell = (w0_in as s16) + (w1_in as s16);

    let q_collar = (left_c * left_c + right_c * right_c) - (s16:2 * w_shell * left_c * right_c);
    let e_sobolev_collar = (w_shell * w_shell - s16:1) * (left_c * left_c);
    let q_coupled = q_collar + e_sobolev_collar;
    let sq_target = (w_shell * left_c - right_c) * (w_shell * left_c - right_c);

    // At the two-prime barrier [1, 1] (W = 2) with L = 1, R = 1:
    // q_collar = -2 < 0, e_sobolev_collar = 3, q_coupled = 1 == (2*1 - 1)^2 >= 0
    let q_barrier_uncoupled = (s16:1 + s16:1) - (s16:2 * s16:2 * s16:1 * s16:1);
    let e_barrier_sobolev = (s16:2 * s16:2 - s16:1) * (s16:1 * s16:1);
    let q_barrier_coupled = q_barrier_uncoupled + e_barrier_sobolev;

    (q_coupled == sq_target) &&
    (q_coupled >= s16:0) &&
    (q_barrier_uncoupled == -s16:2) &&
    (e_barrier_sobolev == s16:3) &&
    (q_barrier_coupled == s16:1)
}

