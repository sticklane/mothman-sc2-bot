// =============================================================================
// lakefillq_0dsp_braun_uf_decoder.x
// =============================================================================
// Google XLS DSLX Multiplierless (0-DSP) Hardware Specification for LakefillQ
// QPhysGrade Grade Phi1 Inner Fast-Feedback Syndrome Decoder Core (500 MHz)
//
// Strictly 0-DSP combinational datapath primitives:
//   bitwise (&, |, ^, !), shifts (<<, >>), ternary/conditional muxes (if/else),
//   concatenations (++), slices, and ripple/LUT adders (+).
//   Zero hardware multipliers, dividers, or modulo units anywhere in this file.
//
// Subblocks:
//   1. lakefillq_braun_popcount16 & lakefillq_braun_popcount24:
//      Balanced pointerless BraunTree adder networks computing exact syndrome
//      Hamming weight in ceil(log2(16)) = 4 and ceil(log2(24)) = 5 levels.
//   2. lakefillq_ingress_xor_bypass24:
//      Computes delta_syn = cur_syn ^ prev_syn, optional zero-bridge cyclic
//      torus wire permutation for [[144, 12, 12]] Bivariate Bicycle AutDEC
//      alignment, and zero_defect_bypass (1 clock = 2.0 ns fast bypass).
//   3. lakefillq_uf_half_edge_grow12, lakefillq_sv_hook_step12, and
//      lakefillq_sv_pointer_jump_parity12:
//      Fixed-depth Delfosse-Nickerson half-edge growth + Shiloach-Vishkin
//      parallel min-neighbor hooking and pointer jumping (root[v] -> root[root[v]])
//      with BraunTree XOR cluster_odd and OR boundary_hit reducers.
//   4. lakefillq_bfs_seed_init12, lakefillq_bfs_forest_step12,
//      lakefillq_peel_level_step12, and lakefillq_peel_boundary_egress12:
//      Fixed-depth spanning-forest orientation and deterministic leaf-to-root
//      peeling emitting physical corrections and logical pauli_frame_flip.
// =============================================================================

// -----------------------------------------------------------------------------
// Helper muxes and 4-bit unsigned comparators (0-DSP LUT6 primitives)
// -----------------------------------------------------------------------------
pub fn bit_mux12(vec12: u12, idx: u4) -> u1 {
    let b01: u1 = if idx[0:1] == u1:1 { vec12[1:2] } else { vec12[0:1] };
    let b23: u1 = if idx[0:1] == u1:1 { vec12[3:4] } else { vec12[2:3] };
    let b45: u1 = if idx[0:1] == u1:1 { vec12[5:6] } else { vec12[4:5] };
    let b67: u1 = if idx[0:1] == u1:1 { vec12[7:8] } else { vec12[6:7] };
    let b89: u1 = if idx[0:1] == u1:1 { vec12[9:10] } else { vec12[8:9] };
    let b1011: u1 = if idx[0:1] == u1:1 { vec12[11:12] } else { vec12[10:11] };
    let q0: u1 = if idx[1:2] == u1:1 { b23 } else { b01 };
    let q1: u1 = if idx[1:2] == u1:1 { b67 } else { b45 };
    let q2: u1 = if idx[1:2] == u1:1 { b1011 } else { b89 };
    let h0: u1 = if idx[2:3] == u1:1 { q1 } else { q0 };
    let h1: u1 = if idx[2:3] == u1:1 { u1:0 } else { q2 };
    if idx[3:4] == u1:1 { h1 } else { h0 }
}

pub fn mux12_u4(
    v0: u4, v1: u4, v2: u4, v3: u4, v4: u4, v5: u4,
    v6: u4, v7: u4, v8: u4, v9: u4, v10: u4, v11: u4,
    idx: u4
) -> u4 {
    let m01: u4 = if idx[0:1] == u1:1 { v1 } else { v0 };
    let m23: u4 = if idx[0:1] == u1:1 { v3 } else { v2 };
    let m45: u4 = if idx[0:1] == u1:1 { v5 } else { v4 };
    let m67: u4 = if idx[0:1] == u1:1 { v7 } else { v6 };
    let m89: u4 = if idx[0:1] == u1:1 { v9 } else { v8 };
    let m1011: u4 = if idx[0:1] == u1:1 { v11 } else { v10 };
    let q0: u4 = if idx[1:2] == u1:1 { m23 } else { m01 };
    let q1: u4 = if idx[1:2] == u1:1 { m67 } else { m45 };
    let q2: u4 = if idx[1:2] == u1:1 { m1011 } else { m89 };
    let h0: u4 = if idx[2:3] == u1:1 { q1 } else { q0 };
    let h1: u4 = if idx[2:3] == u1:1 { idx } else { q2 };
    if idx[3:4] == u1:1 { h1 } else { h0 }
}

pub fn onehot12_u4(r: u4) -> u12 {
    let b11: u1 = if r == u4:11 { u1:1 } else { u1:0 };
    let b10: u1 = if r == u4:10 { u1:1 } else { u1:0 };
    let b9: u1 = if r == u4:9 { u1:1 } else { u1:0 };
    let b8: u1 = if r == u4:8 { u1:1 } else { u1:0 };
    let b7: u1 = if r == u4:7 { u1:1 } else { u1:0 };
    let b6: u1 = if r == u4:6 { u1:1 } else { u1:0 };
    let b5: u1 = if r == u4:5 { u1:1 } else { u1:0 };
    let b4: u1 = if r == u4:4 { u1:1 } else { u1:0 };
    let b3: u1 = if r == u4:3 { u1:1 } else { u1:0 };
    let b2: u1 = if r == u4:2 { u1:1 } else { u1:0 };
    let b1: u1 = if r == u4:1 { u1:1 } else { u1:0 };
    let b0: u1 = if r == u4:0 { u1:1 } else { u1:0 };
    b11 ++ b10 ++ b9 ++ b8 ++ b7 ++ b6 ++ b5 ++ b4 ++ b3 ++ b2 ++ b1 ++ b0
}

pub fn ffs12_u4(m: u12) -> u4 {
    let has_0_1: u1 = m[0:1] | m[1:2];
    let i01: u4 = if m[0:1] == u1:1 { u4:0 } else { u4:1 };
    let has_2_3: u1 = m[2:3] | m[3:4];
    let i23: u4 = if m[2:3] == u1:1 { u4:2 } else { u4:3 };
    let has_4_5: u1 = m[4:5] | m[5:6];
    let i45: u4 = if m[4:5] == u1:1 { u4:4 } else { u4:5 };
    let has_6_7: u1 = m[6:7] | m[7:8];
    let i67: u4 = if m[6:7] == u1:1 { u4:6 } else { u4:7 };
    let has_8_9: u1 = m[8:9] | m[9:10];
    let i89: u4 = if m[8:9] == u1:1 { u4:8 } else { u4:9 };
    let i1011: u4 = if m[10:11] == u1:1 { u4:10 } else { u4:11 };

    let has_0_3: u1 = has_0_1 | has_2_3;
    let i03: u4 = if has_0_1 == u1:1 { i01 } else { i23 };
    let has_4_7: u1 = has_4_5 | has_6_7;
    let i47: u4 = if has_4_5 == u1:1 { i45 } else { i67 };
    let i811: u4 = if has_8_9 == u1:1 { i89 } else { i1011 };

    let has_0_7: u1 = has_0_3 | has_4_7;
    let i07: u4 = if has_0_3 == u1:1 { i03 } else { i47 };
    if has_0_7 == u1:1 { i07 } else { i811 }
}

pub fn braun_or12_u12(
    x0: u12, x1: u12, x2: u12, x3: u12, x4: u12, x5: u12,
    x6: u12, x7: u12, x8: u12, x9: u12, x10: u12, x11: u12
) -> u12 {
    let o01: u12 = x0 | x1;
    let o23: u12 = x2 | x3;
    let o45: u12 = x4 | x5;
    let o67: u12 = x6 | x7;
    let o89: u12 = x8 | x9;
    let o1011: u12 = x10 | x11;
    let o03: u12 = o01 | o23;
    let o47: u12 = o45 | o67;
    let o811: u12 = o89 | o1011;
    let o07: u12 = o03 | o47;
    o07 | o811
}

// -----------------------------------------------------------------------------
// 1. Pointerless BraunTree Popcount Reducers (16-bit & 24-bit, 0-DSP)
// -----------------------------------------------------------------------------
pub fn lakefillq_braun_popcount16(syn16: u16) -> u5 {
    // Level 1: 8 balanced 2-bit leaf pair ripple sums
    let l1_0: u2 = (u1:0 ++ syn16[0:1]) + (u1:0 ++ syn16[1:2]);
    let l1_1: u2 = (u1:0 ++ syn16[2:3]) + (u1:0 ++ syn16[3:4]);
    let l1_2: u2 = (u1:0 ++ syn16[4:5]) + (u1:0 ++ syn16[5:6]);
    let l1_3: u2 = (u1:0 ++ syn16[6:7]) + (u1:0 ++ syn16[7:8]);
    let l1_4: u2 = (u1:0 ++ syn16[8:9]) + (u1:0 ++ syn16[9:10]);
    let l1_5: u2 = (u1:0 ++ syn16[10:11]) + (u1:0 ++ syn16[11:12]);
    let l1_6: u2 = (u1:0 ++ syn16[12:13]) + (u1:0 ++ syn16[13:14]);
    let l1_7: u2 = (u1:0 ++ syn16[14:15]) + (u1:0 ++ syn16[15:16]);

    // Level 2: 4 balanced 3-bit sums
    let l2_0: u3 = (u1:0 ++ l1_0) + (u1:0 ++ l1_1);
    let l2_1: u3 = (u1:0 ++ l1_2) + (u1:0 ++ l1_3);
    let l2_2: u3 = (u1:0 ++ l1_4) + (u1:0 ++ l1_5);
    let l2_3: u3 = (u1:0 ++ l1_6) + (u1:0 ++ l1_7);

    // Level 3: 2 balanced 4-bit sums
    let l3_0: u4 = (u1:0 ++ l2_0) + (u1:0 ++ l2_1);
    let l3_1: u4 = (u1:0 ++ l2_2) + (u1:0 ++ l2_3);

    // Level 4: 1 balanced 5-bit BraunTree root sum
    (u1:0 ++ l3_0) + (u1:0 ++ l3_1)
}

pub fn lakefillq_braun_popcount24(syn24: u24) -> u5 {
    let wt_lo16: u5 = lakefillq_braun_popcount16(syn24[0:16]);
    let h1_0: u2 = (u1:0 ++ syn24[16:17]) + (u1:0 ++ syn24[17:18]);
    let h1_1: u2 = (u1:0 ++ syn24[18:19]) + (u1:0 ++ syn24[19:20]);
    let h1_2: u2 = (u1:0 ++ syn24[20:21]) + (u1:0 ++ syn24[21:22]);
    let h1_3: u2 = (u1:0 ++ syn24[22:23]) + (u1:0 ++ syn24[23:24]);
    let h2_0: u3 = (u1:0 ++ h1_0) + (u1:0 ++ h1_1);
    let h2_1: u3 = (u1:0 ++ h1_2) + (u1:0 ++ h1_3);
    let wt_hi8: u4 = (u1:0 ++ h2_0) + (u1:0 ++ h2_1);
    wt_lo16 + (u1:0 ++ wt_hi8)
}

pub fn lakefillq_ingress_xor_bypass24(
    cur_syn: u24,
    prev_syn: u24,
    autdec_shift_sel: u2
) -> (u24, u5, u1) {
    let raw_delta: u24 = cur_syn ^ prev_syn;
    let delta_syn: u24 =
        if autdec_shift_sel == u2:0 {
            raw_delta
        } else if autdec_shift_sel == u2:1 {
            raw_delta[0:6] ++ raw_delta[6:24]
        } else if autdec_shift_sel == u2:2 {
            raw_delta[0:12] ++ raw_delta[12:24]
        } else {
            raw_delta[0:3] ++ raw_delta[3:24]
        };
    let defect_weight: u5 = lakefillq_braun_popcount24(delta_syn);
    let zero_defect_bypass: u1 = if defect_weight == u5:0 { u1:1 } else { u1:0 };
    (delta_syn, defect_weight, zero_defect_bypass)
}

// -----------------------------------------------------------------------------
// 2. Delfosse-Nickerson Half-Edge Growth + Shiloach-Vishkin Hook & Pointer Jump
// -----------------------------------------------------------------------------
pub fn sat2_edge_inc(cur2: u2, a: u1, b: u1) -> u2 {
    let inc2: u2 = (u1:0 ++ a) + (u1:0 ++ b);
    let sum3: u3 = (u1:0 ++ cur2) + (u1:0 ++ inc2);
    if sum3 >= u3:2 { u2:2 } else { sum3[0:2] }
}

pub fn sat2_bnd_inc(cur2: u2, a: u1) -> u2 {
    let sum3: u3 = (u1:0 ++ cur2) + (u2:0 ++ a);
    if sum3 >= u3:2 { u2:2 } else { sum3[0:2] }
}

pub fn lakefillq_uf_half_edge_grow12(
    root_vec: u48,
    cluster_odd: u12,
    boundary_hit: u12,
    elen_vec: u30,
    blen_vec: u12
) -> (u30, u12, u15, u12) {
    let r0: u4 = root_vec[0:4];
    let r1: u4 = root_vec[4:8];
    let r2: u4 = root_vec[8:12];
    let r3: u4 = root_vec[12:16];
    let r4: u4 = root_vec[16:20];
    let r5: u4 = root_vec[20:24];
    let r6: u4 = root_vec[24:28];
    let r7: u4 = root_vec[28:32];
    let r8: u4 = root_vec[32:36];
    let r9: u4 = root_vec[36:40];
    let r10: u4 = root_vec[40:44];
    let r11: u4 = root_vec[44:48];

    let a0: u1 = bit_mux12(cluster_odd, r0) & (!bit_mux12(boundary_hit, r0));
    let a1: u1 = bit_mux12(cluster_odd, r1) & (!bit_mux12(boundary_hit, r1));
    let a2: u1 = bit_mux12(cluster_odd, r2) & (!bit_mux12(boundary_hit, r2));
    let a3: u1 = bit_mux12(cluster_odd, r3) & (!bit_mux12(boundary_hit, r3));
    let a4: u1 = bit_mux12(cluster_odd, r4) & (!bit_mux12(boundary_hit, r4));
    let a5: u1 = bit_mux12(cluster_odd, r5) & (!bit_mux12(boundary_hit, r5));
    let a6: u1 = bit_mux12(cluster_odd, r6) & (!bit_mux12(boundary_hit, r6));
    let a7: u1 = bit_mux12(cluster_odd, r7) & (!bit_mux12(boundary_hit, r7));
    let a8: u1 = bit_mux12(cluster_odd, r8) & (!bit_mux12(boundary_hit, r8));
    let a9: u1 = bit_mux12(cluster_odd, r9) & (!bit_mux12(boundary_hit, r9));
    let a10: u1 = bit_mux12(cluster_odd, r10) & (!bit_mux12(boundary_hit, r10));
    let a11: u1 = bit_mux12(cluster_odd, r11) & (!bit_mux12(boundary_hit, r11));

    // 15 interior edges on d=5 rotated surface code lattice
    let ne0: u2 = sat2_edge_inc(elen_vec[0:2], a0, a8);
    let ne1: u2 = sat2_edge_inc(elen_vec[2:4], a0, a2);
    let ne2: u2 = sat2_edge_inc(elen_vec[4:6], a1, a2);
    let ne3: u2 = sat2_edge_inc(elen_vec[6:8], a1, a3);
    let ne4: u2 = sat2_edge_inc(elen_vec[8:10], a3, a10);
    let ne5: u2 = sat2_edge_inc(elen_vec[10:12], a4, a8);
    let ne6: u2 = sat2_edge_inc(elen_vec[12:14], a2, a4);
    let ne7: u2 = sat2_edge_inc(elen_vec[14:16], a2, a5);
    let ne8: u2 = sat2_edge_inc(elen_vec[16:18], a3, a5);
    let ne9: u2 = sat2_edge_inc(elen_vec[18:20], a3, a11);
    let ne10: u2 = sat2_edge_inc(elen_vec[20:22], a4, a9);
    let ne11: u2 = sat2_edge_inc(elen_vec[22:24], a4, a6);
    let ne12: u2 = sat2_edge_inc(elen_vec[24:26], a5, a6);
    let ne13: u2 = sat2_edge_inc(elen_vec[26:28], a5, a7);
    let ne14: u2 = sat2_edge_inc(elen_vec[28:30], a7, a11);

    // 6 boundary half-edge counters at vertices {0, 1, 6, 7, 9, 10}
    let nb0: u2 = sat2_bnd_inc(blen_vec[0:2], a0);
    let nb1: u2 = sat2_bnd_inc(blen_vec[2:4], a1);
    let nb2: u2 = sat2_bnd_inc(blen_vec[4:6], a6);
    let nb3: u2 = sat2_bnd_inc(blen_vec[6:8], a7);
    let nb4: u2 = sat2_bnd_inc(blen_vec[8:10], a9);
    let nb5: u2 = sat2_bnd_inc(blen_vec[10:12], a10);

    let f0: u1 = if ne0 == u2:2 { u1:1 } else { u1:0 };
    let f1: u1 = if ne1 == u2:2 { u1:1 } else { u1:0 };
    let f2: u1 = if ne2 == u2:2 { u1:1 } else { u1:0 };
    let f3: u1 = if ne3 == u2:2 { u1:1 } else { u1:0 };
    let f4: u1 = if ne4 == u2:2 { u1:1 } else { u1:0 };
    let f5: u1 = if ne5 == u2:2 { u1:1 } else { u1:0 };
    let f6: u1 = if ne6 == u2:2 { u1:1 } else { u1:0 };
    let f7: u1 = if ne7 == u2:2 { u1:1 } else { u1:0 };
    let f8: u1 = if ne8 == u2:2 { u1:1 } else { u1:0 };
    let f9: u1 = if ne9 == u2:2 { u1:1 } else { u1:0 };
    let f10: u1 = if ne10 == u2:2 { u1:1 } else { u1:0 };
    let f11: u1 = if ne11 == u2:2 { u1:1 } else { u1:0 };
    let f12: u1 = if ne12 == u2:2 { u1:1 } else { u1:0 };
    let f13: u1 = if ne13 == u2:2 { u1:1 } else { u1:0 };
    let f14: u1 = if ne14 == u2:2 { u1:1 } else { u1:0 };

    let elen_next: u30 =
        ne14 ++ ne13 ++ ne12 ++ ne11 ++ ne10 ++ ne9 ++ ne8 ++ ne7 ++
        ne6 ++ ne5 ++ ne4 ++ ne3 ++ ne2 ++ ne1 ++ ne0;
    let blen_next: u12 = nb5 ++ nb4 ++ nb3 ++ nb2 ++ nb1 ++ nb0;
    let full_edge: u15 =
        f14 ++ f13 ++ f12 ++ f11 ++ f10 ++ f9 ++ f8 ++ f7 ++
        f6 ++ f5 ++ f4 ++ f3 ++ f2 ++ f1 ++ f0;
    let active_mask: u12 =
        a11 ++ a10 ++ a9 ++ a8 ++ a7 ++ a6 ++ a5 ++ a4 ++ a3 ++ a2 ++ a1 ++ a0;
    (elen_next, blen_next, full_edge, active_mask)
}

pub fn lakefillq_sv_hook_step12(root_vec: u48, full_edge: u15) -> u48 {
    let r0: u4 = root_vec[0:4];
    let r1: u4 = root_vec[4:8];
    let r2: u4 = root_vec[8:12];
    let r3: u4 = root_vec[12:16];
    let r4: u4 = root_vec[16:20];
    let r5: u4 = root_vec[20:24];
    let r6: u4 = root_vec[24:28];
    let r7: u4 = root_vec[28:32];
    let r8: u4 = root_vec[32:36];
    let r9: u4 = root_vec[36:40];
    let r10: u4 = root_vec[40:44];
    let r11: u4 = root_vec[44:48];

    let oh0: u12 = onehot12_u4(r0);
    let oh1: u12 = onehot12_u4(r1);
    let oh2: u12 = onehot12_u4(r2);
    let oh3: u12 = onehot12_u4(r3);
    let oh4: u12 = onehot12_u4(r4);
    let oh5: u12 = onehot12_u4(r5);
    let oh6: u12 = onehot12_u4(r6);
    let oh7: u12 = onehot12_u4(r7);
    let oh8: u12 = onehot12_u4(r8);
    let oh9: u12 = onehot12_u4(r9);
    let oh10: u12 = onehot12_u4(r10);
    let oh11: u12 = onehot12_u4(r11);

    let nm0: u12 = oh0 | ((if full_edge[0:1] == u1:1 { oh8 } else { u12:0 }) | (if full_edge[1:2] == u1:1 { oh2 } else { u12:0 }));
    let nm1: u12 = oh1 | ((if full_edge[2:3] == u1:1 { oh2 } else { u12:0 }) | (if full_edge[3:4] == u1:1 { oh3 } else { u12:0 }));
    let nm2: u12 = (oh2 | (if full_edge[1:2] == u1:1 { oh0 } else { u12:0 })) | ((if full_edge[2:3] == u1:1 { oh1 } else { u12:0 }) | ((if full_edge[6:7] == u1:1 { oh4 } else { u12:0 }) | (if full_edge[7:8] == u1:1 { oh5 } else { u12:0 })));
    let nm3: u12 = (oh3 | (if full_edge[3:4] == u1:1 { oh1 } else { u12:0 })) | ((if full_edge[4:5] == u1:1 { oh10 } else { u12:0 }) | ((if full_edge[8:9] == u1:1 { oh5 } else { u12:0 }) | (if full_edge[9:10] == u1:1 { oh11 } else { u12:0 })));
    let nm4: u12 = (oh4 | (if full_edge[5:6] == u1:1 { oh8 } else { u12:0 })) | ((if full_edge[6:7] == u1:1 { oh2 } else { u12:0 }) | ((if full_edge[10:11] == u1:1 { oh9 } else { u12:0 }) | (if full_edge[11:12] == u1:1 { oh6 } else { u12:0 })));
    let nm5: u12 = (oh5 | (if full_edge[7:8] == u1:1 { oh2 } else { u12:0 })) | ((if full_edge[8:9] == u1:1 { oh3 } else { u12:0 }) | ((if full_edge[12:13] == u1:1 { oh6 } else { u12:0 }) | (if full_edge[13:14] == u1:1 { oh7 } else { u12:0 })));
    let nm6: u12 = oh6 | ((if full_edge[11:12] == u1:1 { oh4 } else { u12:0 }) | (if full_edge[12:13] == u1:1 { oh5 } else { u12:0 }));
    let nm7: u12 = oh7 | ((if full_edge[13:14] == u1:1 { oh5 } else { u12:0 }) | (if full_edge[14:15] == u1:1 { oh11 } else { u12:0 }));
    let nm8: u12 = oh8 | ((if full_edge[0:1] == u1:1 { oh0 } else { u12:0 }) | (if full_edge[5:6] == u1:1 { oh4 } else { u12:0 }));
    let nm9: u12 = oh9 | (if full_edge[10:11] == u1:1 { oh4 } else { u12:0 });
    let nm10: u12 = oh10 | (if full_edge[4:5] == u1:1 { oh3 } else { u12:0 });
    let nm11: u12 = oh11 | ((if full_edge[9:10] == u1:1 { oh3 } else { u12:0 }) | (if full_edge[14:15] == u1:1 { oh7 } else { u12:0 }));

    let cm0: u12 = braun_or12_u12(if oh0[0:1] == u1:1 { nm0 } else { u12:1 }, if oh1[0:1] == u1:1 { nm1 } else { u12:0 }, if oh2[0:1] == u1:1 { nm2 } else { u12:0 }, if oh3[0:1] == u1:1 { nm3 } else { u12:0 }, if oh4[0:1] == u1:1 { nm4 } else { u12:0 }, if oh5[0:1] == u1:1 { nm5 } else { u12:0 }, if oh6[0:1] == u1:1 { nm6 } else { u12:0 }, if oh7[0:1] == u1:1 { nm7 } else { u12:0 }, if oh8[0:1] == u1:1 { nm8 } else { u12:0 }, if oh9[0:1] == u1:1 { nm9 } else { u12:0 }, if oh10[0:1] == u1:1 { nm10 } else { u12:0 }, if oh11[0:1] == u1:1 { nm11 } else { u12:0 });
    let cm1: u12 = braun_or12_u12(if oh0[1:2] == u1:1 { nm0 } else { u12:2 }, if oh1[1:2] == u1:1 { nm1 } else { u12:0 }, if oh2[1:2] == u1:1 { nm2 } else { u12:0 }, if oh3[1:2] == u1:1 { nm3 } else { u12:0 }, if oh4[1:2] == u1:1 { nm4 } else { u12:0 }, if oh5[1:2] == u1:1 { nm5 } else { u12:0 }, if oh6[1:2] == u1:1 { nm6 } else { u12:0 }, if oh7[1:2] == u1:1 { nm7 } else { u12:0 }, if oh8[1:2] == u1:1 { nm8 } else { u12:0 }, if oh9[1:2] == u1:1 { nm9 } else { u12:0 }, if oh10[1:2] == u1:1 { nm10 } else { u12:0 }, if oh11[1:2] == u1:1 { nm11 } else { u12:0 });
    let cm2: u12 = braun_or12_u12(if oh0[2:3] == u1:1 { nm0 } else { u12:4 }, if oh1[2:3] == u1:1 { nm1 } else { u12:0 }, if oh2[2:3] == u1:1 { nm2 } else { u12:0 }, if oh3[2:3] == u1:1 { nm3 } else { u12:0 }, if oh4[2:3] == u1:1 { nm4 } else { u12:0 }, if oh5[2:3] == u1:1 { nm5 } else { u12:0 }, if oh6[2:3] == u1:1 { nm6 } else { u12:0 }, if oh7[2:3] == u1:1 { nm7 } else { u12:0 }, if oh8[2:3] == u1:1 { nm8 } else { u12:0 }, if oh9[2:3] == u1:1 { nm9 } else { u12:0 }, if oh10[2:3] == u1:1 { nm10 } else { u12:0 }, if oh11[2:3] == u1:1 { nm11 } else { u12:0 });
    let cm3: u12 = braun_or12_u12(if oh0[3:4] == u1:1 { nm0 } else { u12:8 }, if oh1[3:4] == u1:1 { nm1 } else { u12:0 }, if oh2[3:4] == u1:1 { nm2 } else { u12:0 }, if oh3[3:4] == u1:1 { nm3 } else { u12:0 }, if oh4[3:4] == u1:1 { nm4 } else { u12:0 }, if oh5[3:4] == u1:1 { nm5 } else { u12:0 }, if oh6[3:4] == u1:1 { nm6 } else { u12:0 }, if oh7[3:4] == u1:1 { nm7 } else { u12:0 }, if oh8[3:4] == u1:1 { nm8 } else { u12:0 }, if oh9[3:4] == u1:1 { nm9 } else { u12:0 }, if oh10[3:4] == u1:1 { nm10 } else { u12:0 }, if oh11[3:4] == u1:1 { nm11 } else { u12:0 });
    let cm4: u12 = braun_or12_u12(if oh0[4:5] == u1:1 { nm0 } else { u12:16 }, if oh1[4:5] == u1:1 { nm1 } else { u12:0 }, if oh2[4:5] == u1:1 { nm2 } else { u12:0 }, if oh3[4:5] == u1:1 { nm3 } else { u12:0 }, if oh4[4:5] == u1:1 { nm4 } else { u12:0 }, if oh5[4:5] == u1:1 { nm5 } else { u12:0 }, if oh6[4:5] == u1:1 { nm6 } else { u12:0 }, if oh7[4:5] == u1:1 { nm7 } else { u12:0 }, if oh8[4:5] == u1:1 { nm8 } else { u12:0 }, if oh9[4:5] == u1:1 { nm9 } else { u12:0 }, if oh10[4:5] == u1:1 { nm10 } else { u12:0 }, if oh11[4:5] == u1:1 { nm11 } else { u12:0 });
    let cm5: u12 = braun_or12_u12(if oh0[5:6] == u1:1 { nm0 } else { u12:32 }, if oh1[5:6] == u1:1 { nm1 } else { u12:0 }, if oh2[5:6] == u1:1 { nm2 } else { u12:0 }, if oh3[5:6] == u1:1 { nm3 } else { u12:0 }, if oh4[5:6] == u1:1 { nm4 } else { u12:0 }, if oh5[5:6] == u1:1 { nm5 } else { u12:0 }, if oh6[5:6] == u1:1 { nm6 } else { u12:0 }, if oh7[5:6] == u1:1 { nm7 } else { u12:0 }, if oh8[5:6] == u1:1 { nm8 } else { u12:0 }, if oh9[5:6] == u1:1 { nm9 } else { u12:0 }, if oh10[5:6] == u1:1 { nm10 } else { u12:0 }, if oh11[5:6] == u1:1 { nm11 } else { u12:0 });
    let cm6: u12 = braun_or12_u12(if oh0[6:7] == u1:1 { nm0 } else { u12:64 }, if oh1[6:7] == u1:1 { nm1 } else { u12:0 }, if oh2[6:7] == u1:1 { nm2 } else { u12:0 }, if oh3[6:7] == u1:1 { nm3 } else { u12:0 }, if oh4[6:7] == u1:1 { nm4 } else { u12:0 }, if oh5[6:7] == u1:1 { nm5 } else { u12:0 }, if oh6[6:7] == u1:1 { nm6 } else { u12:0 }, if oh7[6:7] == u1:1 { nm7 } else { u12:0 }, if oh8[6:7] == u1:1 { nm8 } else { u12:0 }, if oh9[6:7] == u1:1 { nm9 } else { u12:0 }, if oh10[6:7] == u1:1 { nm10 } else { u12:0 }, if oh11[6:7] == u1:1 { nm11 } else { u12:0 });
    let cm7: u12 = braun_or12_u12(if oh0[7:8] == u1:1 { nm0 } else { u12:128 }, if oh1[7:8] == u1:1 { nm1 } else { u12:0 }, if oh2[7:8] == u1:1 { nm2 } else { u12:0 }, if oh3[7:8] == u1:1 { nm3 } else { u12:0 }, if oh4[7:8] == u1:1 { nm4 } else { u12:0 }, if oh5[7:8] == u1:1 { nm5 } else { u12:0 }, if oh6[7:8] == u1:1 { nm6 } else { u12:0 }, if oh7[7:8] == u1:1 { nm7 } else { u12:0 }, if oh8[7:8] == u1:1 { nm8 } else { u12:0 }, if oh9[7:8] == u1:1 { nm9 } else { u12:0 }, if oh10[7:8] == u1:1 { nm10 } else { u12:0 }, if oh11[7:8] == u1:1 { nm11 } else { u12:0 });
    let cm8: u12 = braun_or12_u12(if oh0[8:9] == u1:1 { nm0 } else { u12:256 }, if oh1[8:9] == u1:1 { nm1 } else { u12:0 }, if oh2[8:9] == u1:1 { nm2 } else { u12:0 }, if oh3[8:9] == u1:1 { nm3 } else { u12:0 }, if oh4[8:9] == u1:1 { nm4 } else { u12:0 }, if oh5[8:9] == u1:1 { nm5 } else { u12:0 }, if oh6[8:9] == u1:1 { nm6 } else { u12:0 }, if oh7[8:9] == u1:1 { nm7 } else { u12:0 }, if oh8[8:9] == u1:1 { nm8 } else { u12:0 }, if oh9[8:9] == u1:1 { nm9 } else { u12:0 }, if oh10[8:9] == u1:1 { nm10 } else { u12:0 }, if oh11[8:9] == u1:1 { nm11 } else { u12:0 });
    let cm9: u12 = braun_or12_u12(if oh0[9:10] == u1:1 { nm0 } else { u12:512 }, if oh1[9:10] == u1:1 { nm1 } else { u12:0 }, if oh2[9:10] == u1:1 { nm2 } else { u12:0 }, if oh3[9:10] == u1:1 { nm3 } else { u12:0 }, if oh4[9:10] == u1:1 { nm4 } else { u12:0 }, if oh5[9:10] == u1:1 { nm5 } else { u12:0 }, if oh6[9:10] == u1:1 { nm6 } else { u12:0 }, if oh7[9:10] == u1:1 { nm7 } else { u12:0 }, if oh8[9:10] == u1:1 { nm8 } else { u12:0 }, if oh9[9:10] == u1:1 { nm9 } else { u12:0 }, if oh10[9:10] == u1:1 { nm10 } else { u12:0 }, if oh11[9:10] == u1:1 { nm11 } else { u12:0 });
    let cm10: u12 = braun_or12_u12(if oh0[10:11] == u1:1 { nm0 } else { u12:1024 }, if oh1[10:11] == u1:1 { nm1 } else { u12:0 }, if oh2[10:11] == u1:1 { nm2 } else { u12:0 }, if oh3[10:11] == u1:1 { nm3 } else { u12:0 }, if oh4[10:11] == u1:1 { nm4 } else { u12:0 }, if oh5[10:11] == u1:1 { nm5 } else { u12:0 }, if oh6[10:11] == u1:1 { nm6 } else { u12:0 }, if oh7[10:11] == u1:1 { nm7 } else { u12:0 }, if oh8[10:11] == u1:1 { nm8 } else { u12:0 }, if oh9[10:11] == u1:1 { nm9 } else { u12:0 }, if oh10[10:11] == u1:1 { nm10 } else { u12:0 }, if oh11[10:11] == u1:1 { nm11 } else { u12:0 });
    let cm11: u12 = braun_or12_u12(if oh0[11:12] == u1:1 { nm0 } else { u12:2048 }, if oh1[11:12] == u1:1 { nm1 } else { u12:0 }, if oh2[11:12] == u1:1 { nm2 } else { u12:0 }, if oh3[11:12] == u1:1 { nm3 } else { u12:0 }, if oh4[11:12] == u1:1 { nm4 } else { u12:0 }, if oh5[11:12] == u1:1 { nm5 } else { u12:0 }, if oh6[11:12] == u1:1 { nm6 } else { u12:0 }, if oh7[11:12] == u1:1 { nm7 } else { u12:0 }, if oh8[11:12] == u1:1 { nm8 } else { u12:0 }, if oh9[11:12] == u1:1 { nm9 } else { u12:0 }, if oh10[11:12] == u1:1 { nm10 } else { u12:0 }, if oh11[11:12] == u1:1 { nm11 } else { u12:0 });

    let hk0: u4 = ffs12_u4(cm0 | u12:1);
    let hk1: u4 = ffs12_u4(cm1 | u12:2);
    let hk2: u4 = ffs12_u4(cm2 | u12:4);
    let hk3: u4 = ffs12_u4(cm3 | u12:8);
    let hk4: u4 = ffs12_u4(cm4 | u12:16);
    let hk5: u4 = ffs12_u4(cm5 | u12:32);
    let hk6: u4 = ffs12_u4(cm6 | u12:64);
    let hk7: u4 = ffs12_u4(cm7 | u12:128);
    let hk8: u4 = ffs12_u4(cm8 | u12:256);
    let hk9: u4 = ffs12_u4(cm9 | u12:512);
    let hk10: u4 = ffs12_u4(cm10 | u12:1024);
    let hk11: u4 = ffs12_u4(cm11 | u12:2048);

    let nr0: u4 = mux12_u4(hk0, hk1, hk2, hk3, hk4, hk5, hk6, hk7, hk8, hk9, hk10, hk11, r0);
    let nr1: u4 = mux12_u4(hk0, hk1, hk2, hk3, hk4, hk5, hk6, hk7, hk8, hk9, hk10, hk11, r1);
    let nr2: u4 = mux12_u4(hk0, hk1, hk2, hk3, hk4, hk5, hk6, hk7, hk8, hk9, hk10, hk11, r2);
    let nr3: u4 = mux12_u4(hk0, hk1, hk2, hk3, hk4, hk5, hk6, hk7, hk8, hk9, hk10, hk11, r3);
    let nr4: u4 = mux12_u4(hk0, hk1, hk2, hk3, hk4, hk5, hk6, hk7, hk8, hk9, hk10, hk11, r4);
    let nr5: u4 = mux12_u4(hk0, hk1, hk2, hk3, hk4, hk5, hk6, hk7, hk8, hk9, hk10, hk11, r5);
    let nr6: u4 = mux12_u4(hk0, hk1, hk2, hk3, hk4, hk5, hk6, hk7, hk8, hk9, hk10, hk11, r6);
    let nr7: u4 = mux12_u4(hk0, hk1, hk2, hk3, hk4, hk5, hk6, hk7, hk8, hk9, hk10, hk11, r7);
    let nr8: u4 = mux12_u4(hk0, hk1, hk2, hk3, hk4, hk5, hk6, hk7, hk8, hk9, hk10, hk11, r8);
    let nr9: u4 = mux12_u4(hk0, hk1, hk2, hk3, hk4, hk5, hk6, hk7, hk8, hk9, hk10, hk11, r9);
    let nr10: u4 = mux12_u4(hk0, hk1, hk2, hk3, hk4, hk5, hk6, hk7, hk8, hk9, hk10, hk11, r10);
    let nr11: u4 = mux12_u4(hk0, hk1, hk2, hk3, hk4, hk5, hk6, hk7, hk8, hk9, hk10, hk11, r11);

    nr11 ++ nr10 ++ nr9 ++ nr8 ++ nr7 ++ nr6 ++ nr5 ++ nr4 ++ nr3 ++ nr2 ++ nr1 ++ nr0
}

pub fn cluster_xor_for_id(
    jr0: u4, jr1: u4, jr2: u4, jr3: u4, jr4: u4, jr5: u4,
    jr6: u4, jr7: u4, jr8: u4, jr9: u4, jr10: u4, jr11: u4,
    syn12: u12, target: u4
) -> u1 {
    let t0: u1 = if jr0 == target { syn12[0:1] } else { u1:0 };
    let t1: u1 = if jr1 == target { syn12[1:2] } else { u1:0 };
    let t2: u1 = if jr2 == target { syn12[2:3] } else { u1:0 };
    let t3: u1 = if jr3 == target { syn12[3:4] } else { u1:0 };
    let t4: u1 = if jr4 == target { syn12[4:5] } else { u1:0 };
    let t5: u1 = if jr5 == target { syn12[5:6] } else { u1:0 };
    let t6: u1 = if jr6 == target { syn12[6:7] } else { u1:0 };
    let t7: u1 = if jr7 == target { syn12[7:8] } else { u1:0 };
    let t8: u1 = if jr8 == target { syn12[8:9] } else { u1:0 };
    let t9: u1 = if jr9 == target { syn12[9:10] } else { u1:0 };
    let t10: u1 = if jr10 == target { syn12[10:11] } else { u1:0 };
    let t11: u1 = if jr11 == target { syn12[11:12] } else { u1:0 };
    ((t0 ^ t1) ^ (t2 ^ t3)) ^ ((t4 ^ t5) ^ (t6 ^ t7)) ^ ((t8 ^ t9) ^ (t10 ^ t11))
}

pub fn cluster_bhit_for_id(
    jr0: u4, jr1: u4, jr6: u4, jr7: u4, jr9: u4, jr10: u4,
    bf0: u1, bf1: u1, bf2: u1, bf3: u1, bf4: u1, bf5: u1,
    target: u4
) -> u1 {
    let h0: u1 = if jr0 == target { bf0 } else { u1:0 };
    let h1: u1 = if jr1 == target { bf1 } else { u1:0 };
    let h2: u1 = if jr6 == target { bf2 } else { u1:0 };
    let h3: u1 = if jr7 == target { bf3 } else { u1:0 };
    let h4: u1 = if jr9 == target { bf4 } else { u1:0 };
    let h5: u1 = if jr10 == target { bf5 } else { u1:0 };
    (h0 | h1 | h2) | (h3 | h4 | h5)
}

pub fn lakefillq_sv_pointer_jump_parity12(
    root_vec: u48,
    syn12: u12,
    blen_vec: u12
) -> (u48, u12, u12) {
    let r0: u4 = root_vec[0:4];
    let r1: u4 = root_vec[4:8];
    let r2: u4 = root_vec[8:12];
    let r3: u4 = root_vec[12:16];
    let r4: u4 = root_vec[16:20];
    let r5: u4 = root_vec[20:24];
    let r6: u4 = root_vec[24:28];
    let r7: u4 = root_vec[28:32];
    let r8: u4 = root_vec[32:36];
    let r9: u4 = root_vec[36:40];
    let r10: u4 = root_vec[40:44];
    let r11: u4 = root_vec[44:48];

    // Synchronous Shiloach-Vishkin pointer jump: root_jump[v] = root[root[v]]
    let jr0: u4 = mux12_u4(r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r0);
    let jr1: u4 = mux12_u4(r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r1);
    let jr2: u4 = mux12_u4(r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r2);
    let jr3: u4 = mux12_u4(r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r3);
    let jr4: u4 = mux12_u4(r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r4);
    let jr5: u4 = mux12_u4(r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r5);
    let jr6: u4 = mux12_u4(r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r6);
    let jr7: u4 = mux12_u4(r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r7);
    let jr8: u4 = mux12_u4(r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r8);
    let jr9: u4 = mux12_u4(r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r9);
    let jr10: u4 = mux12_u4(r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r10);
    let jr11: u4 = mux12_u4(r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r11);

    let root_jump: u48 =
        jr11 ++ jr10 ++ jr9 ++ jr8 ++ jr7 ++ jr6 ++ jr5 ++ jr4 ++ jr3 ++ jr2 ++ jr1 ++ jr0;

    let od0: u1 = cluster_xor_for_id(jr0, jr1, jr2, jr3, jr4, jr5, jr6, jr7, jr8, jr9, jr10, jr11, syn12, u4:0);
    let od1: u1 = cluster_xor_for_id(jr0, jr1, jr2, jr3, jr4, jr5, jr6, jr7, jr8, jr9, jr10, jr11, syn12, u4:1);
    let od2: u1 = cluster_xor_for_id(jr0, jr1, jr2, jr3, jr4, jr5, jr6, jr7, jr8, jr9, jr10, jr11, syn12, u4:2);
    let od3: u1 = cluster_xor_for_id(jr0, jr1, jr2, jr3, jr4, jr5, jr6, jr7, jr8, jr9, jr10, jr11, syn12, u4:3);
    let od4: u1 = cluster_xor_for_id(jr0, jr1, jr2, jr3, jr4, jr5, jr6, jr7, jr8, jr9, jr10, jr11, syn12, u4:4);
    let od5: u1 = cluster_xor_for_id(jr0, jr1, jr2, jr3, jr4, jr5, jr6, jr7, jr8, jr9, jr10, jr11, syn12, u4:5);
    let od6: u1 = cluster_xor_for_id(jr0, jr1, jr2, jr3, jr4, jr5, jr6, jr7, jr8, jr9, jr10, jr11, syn12, u4:6);
    let od7: u1 = cluster_xor_for_id(jr0, jr1, jr2, jr3, jr4, jr5, jr6, jr7, jr8, jr9, jr10, jr11, syn12, u4:7);
    let od8: u1 = cluster_xor_for_id(jr0, jr1, jr2, jr3, jr4, jr5, jr6, jr7, jr8, jr9, jr10, jr11, syn12, u4:8);
    let od9: u1 = cluster_xor_for_id(jr0, jr1, jr2, jr3, jr4, jr5, jr6, jr7, jr8, jr9, jr10, jr11, syn12, u4:9);
    let od10: u1 = cluster_xor_for_id(jr0, jr1, jr2, jr3, jr4, jr5, jr6, jr7, jr8, jr9, jr10, jr11, syn12, u4:10);
    let od11: u1 = cluster_xor_for_id(jr0, jr1, jr2, jr3, jr4, jr5, jr6, jr7, jr8, jr9, jr10, jr11, syn12, u4:11);

    let bf0: u1 = if blen_vec[0:2] == u2:2 { u1:1 } else { u1:0 };
    let bf1: u1 = if blen_vec[2:4] == u2:2 { u1:1 } else { u1:0 };
    let bf2: u1 = if blen_vec[4:6] == u2:2 { u1:1 } else { u1:0 };
    let bf3: u1 = if blen_vec[6:8] == u2:2 { u1:1 } else { u1:0 };
    let bf4: u1 = if blen_vec[8:10] == u2:2 { u1:1 } else { u1:0 };
    let bf5: u1 = if blen_vec[10:12] == u2:2 { u1:1 } else { u1:0 };

    let bh0: u1 = cluster_bhit_for_id(jr0, jr1, jr6, jr7, jr9, jr10, bf0, bf1, bf2, bf3, bf4, bf5, u4:0);
    let bh1: u1 = cluster_bhit_for_id(jr0, jr1, jr6, jr7, jr9, jr10, bf0, bf1, bf2, bf3, bf4, bf5, u4:1);
    let bh2: u1 = cluster_bhit_for_id(jr0, jr1, jr6, jr7, jr9, jr10, bf0, bf1, bf2, bf3, bf4, bf5, u4:2);
    let bh3: u1 = cluster_bhit_for_id(jr0, jr1, jr6, jr7, jr9, jr10, bf0, bf1, bf2, bf3, bf4, bf5, u4:3);
    let bh4: u1 = cluster_bhit_for_id(jr0, jr1, jr6, jr7, jr9, jr10, bf0, bf1, bf2, bf3, bf4, bf5, u4:4);
    let bh5: u1 = cluster_bhit_for_id(jr0, jr1, jr6, jr7, jr9, jr10, bf0, bf1, bf2, bf3, bf4, bf5, u4:5);
    let bh6: u1 = cluster_bhit_for_id(jr0, jr1, jr6, jr7, jr9, jr10, bf0, bf1, bf2, bf3, bf4, bf5, u4:6);
    let bh7: u1 = cluster_bhit_for_id(jr0, jr1, jr6, jr7, jr9, jr10, bf0, bf1, bf2, bf3, bf4, bf5, u4:7);
    let bh8: u1 = cluster_bhit_for_id(jr0, jr1, jr6, jr7, jr9, jr10, bf0, bf1, bf2, bf3, bf4, bf5, u4:8);
    let bh9: u1 = cluster_bhit_for_id(jr0, jr1, jr6, jr7, jr9, jr10, bf0, bf1, bf2, bf3, bf4, bf5, u4:9);
    let bh10: u1 = cluster_bhit_for_id(jr0, jr1, jr6, jr7, jr9, jr10, bf0, bf1, bf2, bf3, bf4, bf5, u4:10);
    let bh11: u1 = cluster_bhit_for_id(jr0, jr1, jr6, jr7, jr9, jr10, bf0, bf1, bf2, bf3, bf4, bf5, u4:11);

    let cluster_odd: u12 = od11 ++ od10 ++ od9 ++ od8 ++ od7 ++ od6 ++ od5 ++ od4 ++ od3 ++ od2 ++ od1 ++ od0;
    let boundary_hit: u12 = bh11 ++ bh10 ++ bh9 ++ bh8 ++ bh7 ++ bh6 ++ bh5 ++ bh4 ++ bh3 ++ bh2 ++ bh1 ++ bh0;
    (root_jump, cluster_odd, boundary_hit)
}

// -----------------------------------------------------------------------------
// 3. Spanning-Forest Orientation & Leaf-to-Root Peeling (0-DSP)
// -----------------------------------------------------------------------------
pub fn seed_for_cluster(
    r0: u4, r1: u4, r6: u4, r7: u4, r9: u4, r10: u4,
    bf0: u1, bf1: u1, bf2: u1, bf3: u1, bf4: u1, bf5: u1,
    cid: u4
) -> u4 {
    if (r0 == cid) & (bf0 == u1:1) {
        u4:0
    } else if (r1 == cid) & (bf1 == u1:1) {
        u4:1
    } else if (r6 == cid) & (bf2 == u1:1) {
        u4:6
    } else if (r7 == cid) & (bf3 == u1:1) {
        u4:7
    } else if (r9 == cid) & (bf4 == u1:1) {
        u4:9
    } else if (r10 == cid) & (bf5 == u1:1) {
        u4:10
    } else {
        cid
    }
}

pub fn lakefillq_bfs_seed_init12(root_vec: u48, blen_vec: u12) -> u12 {
    let r0: u4 = root_vec[0:4];
    let r1: u4 = root_vec[4:8];
    let r2: u4 = root_vec[8:12];
    let r3: u4 = root_vec[12:16];
    let r4: u4 = root_vec[16:20];
    let r5: u4 = root_vec[20:24];
    let r6: u4 = root_vec[24:28];
    let r7: u4 = root_vec[28:32];
    let r8: u4 = root_vec[32:36];
    let r9: u4 = root_vec[36:40];
    let r10: u4 = root_vec[40:44];
    let r11: u4 = root_vec[44:48];

    let bf0: u1 = if blen_vec[0:2] == u2:2 { u1:1 } else { u1:0 };
    let bf1: u1 = if blen_vec[2:4] == u2:2 { u1:1 } else { u1:0 };
    let bf2: u1 = if blen_vec[4:6] == u2:2 { u1:1 } else { u1:0 };
    let bf3: u1 = if blen_vec[6:8] == u2:2 { u1:1 } else { u1:0 };
    let bf4: u1 = if blen_vec[8:10] == u2:2 { u1:1 } else { u1:0 };
    let bf5: u1 = if blen_vec[10:12] == u2:2 { u1:1 } else { u1:0 };

    let sd0: u4 = seed_for_cluster(r0, r1, r6, r7, r9, r10, bf0, bf1, bf2, bf3, bf4, bf5, u4:0);
    let sd1: u4 = seed_for_cluster(r0, r1, r6, r7, r9, r10, bf0, bf1, bf2, bf3, bf4, bf5, u4:1);
    let sd2: u4 = seed_for_cluster(r0, r1, r6, r7, r9, r10, bf0, bf1, bf2, bf3, bf4, bf5, u4:2);
    let sd3: u4 = seed_for_cluster(r0, r1, r6, r7, r9, r10, bf0, bf1, bf2, bf3, bf4, bf5, u4:3);
    let sd4: u4 = seed_for_cluster(r0, r1, r6, r7, r9, r10, bf0, bf1, bf2, bf3, bf4, bf5, u4:4);
    let sd5: u4 = seed_for_cluster(r0, r1, r6, r7, r9, r10, bf0, bf1, bf2, bf3, bf4, bf5, u4:5);
    let sd6: u4 = seed_for_cluster(r0, r1, r6, r7, r9, r10, bf0, bf1, bf2, bf3, bf4, bf5, u4:6);
    let sd7: u4 = seed_for_cluster(r0, r1, r6, r7, r9, r10, bf0, bf1, bf2, bf3, bf4, bf5, u4:7);
    let sd8: u4 = seed_for_cluster(r0, r1, r6, r7, r9, r10, bf0, bf1, bf2, bf3, bf4, bf5, u4:8);
    let sd9: u4 = seed_for_cluster(r0, r1, r6, r7, r9, r10, bf0, bf1, bf2, bf3, bf4, bf5, u4:9);
    let sd10: u4 = seed_for_cluster(r0, r1, r6, r7, r9, r10, bf0, bf1, bf2, bf3, bf4, bf5, u4:10);
    let sd11: u4 = seed_for_cluster(r0, r1, r6, r7, r9, r10, bf0, bf1, bf2, bf3, bf4, bf5, u4:11);

    let v0: u1 = if mux12_u4(sd0, sd1, sd2, sd3, sd4, sd5, sd6, sd7, sd8, sd9, sd10, sd11, r0) == u4:0 { u1:1 } else { u1:0 };
    let v1: u1 = if mux12_u4(sd0, sd1, sd2, sd3, sd4, sd5, sd6, sd7, sd8, sd9, sd10, sd11, r1) == u4:1 { u1:1 } else { u1:0 };
    let v2: u1 = if mux12_u4(sd0, sd1, sd2, sd3, sd4, sd5, sd6, sd7, sd8, sd9, sd10, sd11, r2) == u4:2 { u1:1 } else { u1:0 };
    let v3: u1 = if mux12_u4(sd0, sd1, sd2, sd3, sd4, sd5, sd6, sd7, sd8, sd9, sd10, sd11, r3) == u4:3 { u1:1 } else { u1:0 };
    let v4: u1 = if mux12_u4(sd0, sd1, sd2, sd3, sd4, sd5, sd6, sd7, sd8, sd9, sd10, sd11, r4) == u4:4 { u1:1 } else { u1:0 };
    let v5: u1 = if mux12_u4(sd0, sd1, sd2, sd3, sd4, sd5, sd6, sd7, sd8, sd9, sd10, sd11, r5) == u4:5 { u1:1 } else { u1:0 };
    let v6: u1 = if mux12_u4(sd0, sd1, sd2, sd3, sd4, sd5, sd6, sd7, sd8, sd9, sd10, sd11, r6) == u4:6 { u1:1 } else { u1:0 };
    let v7: u1 = if mux12_u4(sd0, sd1, sd2, sd3, sd4, sd5, sd6, sd7, sd8, sd9, sd10, sd11, r7) == u4:7 { u1:1 } else { u1:0 };
    let v8: u1 = if mux12_u4(sd0, sd1, sd2, sd3, sd4, sd5, sd6, sd7, sd8, sd9, sd10, sd11, r8) == u4:8 { u1:1 } else { u1:0 };
    let v9: u1 = if mux12_u4(sd0, sd1, sd2, sd3, sd4, sd5, sd6, sd7, sd8, sd9, sd10, sd11, r9) == u4:9 { u1:1 } else { u1:0 };
    let v10: u1 = if mux12_u4(sd0, sd1, sd2, sd3, sd4, sd5, sd6, sd7, sd8, sd9, sd10, sd11, r10) == u4:10 { u1:1 } else { u1:0 };
    let v11: u1 = if mux12_u4(sd0, sd1, sd2, sd3, sd4, sd5, sd6, sd7, sd8, sd9, sd10, sd11, r11) == u4:11 { u1:1 } else { u1:0 };

    v11 ++ v10 ++ v9 ++ v8 ++ v7 ++ v6 ++ v5 ++ v4 ++ v3 ++ v2 ++ v1 ++ v0
}

pub fn bfs_vertex_deg2(
    vis_self: u1, cur_pe: u4, cur_pv: u4, cur_lv: u3, cur_lvl: u3,
    c0: u1, e0: u4, nb0: u4,
    c1: u1, e1: u4, nb1: u4
) -> (u1, u4, u4, u3) {
    if vis_self == u1:1 {
        (u1:1, cur_pe, cur_pv, cur_lv)
    } else if c0 == u1:1 {
        (u1:1, e0, nb0, cur_lvl)
    } else if c1 == u1:1 {
        (u1:1, e1, nb1, cur_lvl)
    } else {
        (u1:0, cur_pe, cur_pv, cur_lv)
    }
}

pub fn bfs_vertex_deg4(
    vis_self: u1, cur_pe: u4, cur_pv: u4, cur_lv: u3, cur_lvl: u3,
    c0: u1, e0: u4, nb0: u4,
    c1: u1, e1: u4, nb1: u4,
    c2: u1, e2: u4, nb2: u4,
    c3: u1, e3: u4, nb3: u4
) -> (u1, u4, u4, u3) {
    if vis_self == u1:1 {
        (u1:1, cur_pe, cur_pv, cur_lv)
    } else if c0 == u1:1 {
        (u1:1, e0, nb0, cur_lvl)
    } else if c1 == u1:1 {
        (u1:1, e1, nb1, cur_lvl)
    } else if c2 == u1:1 {
        (u1:1, e2, nb2, cur_lvl)
    } else if c3 == u1:1 {
        (u1:1, e3, nb3, cur_lvl)
    } else {
        (u1:0, cur_pe, cur_pv, cur_lv)
    }
}

pub fn lakefillq_bfs_forest_step12(
    vis: u12,
    pe_vec: u48,
    pv_vec: u48,
    lv_vec: u36,
    full_edge: u15,
    cur_lvl: u3
) -> (u12, u48, u48, u36) {
    let (nv0, npe0, npv0, nlv0) = bfs_vertex_deg2(vis[0:1], pe_vec[0:4], pv_vec[0:4], lv_vec[0:3], cur_lvl, full_edge[0:1] & vis[8:9], u4:0, u4:8, full_edge[1:2] & vis[2:3], u4:1, u4:2);
    let (nv1, npe1, npv1, nlv1) = bfs_vertex_deg2(vis[1:2], pe_vec[4:8], pv_vec[4:8], lv_vec[3:6], cur_lvl, full_edge[2:3] & vis[2:3], u4:2, u4:2, full_edge[3:4] & vis[3:4], u4:3, u4:3);
    let (nv2, npe2, npv2, nlv2) = bfs_vertex_deg4(vis[2:3], pe_vec[8:12], pv_vec[8:12], lv_vec[6:9], cur_lvl, full_edge[1:2] & vis[0:1], u4:1, u4:0, full_edge[2:3] & vis[1:2], u4:2, u4:1, full_edge[6:7] & vis[4:5], u4:6, u4:4, full_edge[7:8] & vis[5:6], u4:7, u4:5);
    let (nv3, npe3, npv3, nlv3) = bfs_vertex_deg4(vis[3:4], pe_vec[12:16], pv_vec[12:16], lv_vec[9:12], cur_lvl, full_edge[3:4] & vis[1:2], u4:3, u4:1, full_edge[4:5] & vis[10:11], u4:4, u4:10, full_edge[8:9] & vis[5:6], u4:8, u4:5, full_edge[9:10] & vis[11:12], u4:9, u4:11);
    let (nv4, npe4, npv4, nlv4) = bfs_vertex_deg4(vis[4:5], pe_vec[16:20], pv_vec[16:20], lv_vec[12:15], cur_lvl, full_edge[5:6] & vis[8:9], u4:5, u4:8, full_edge[6:7] & vis[2:3], u4:6, u4:2, full_edge[10:11] & vis[9:10], u4:10, u4:9, full_edge[11:12] & vis[6:7], u4:11, u4:6);
    let (nv5, npe5, npv5, nlv5) = bfs_vertex_deg4(vis[5:6], pe_vec[20:24], pv_vec[20:24], lv_vec[15:18], cur_lvl, full_edge[7:8] & vis[2:3], u4:7, u4:2, full_edge[8:9] & vis[3:4], u4:8, u4:3, full_edge[12:13] & vis[6:7], u4:12, u4:6, full_edge[13:14] & vis[7:8], u4:13, u4:7);
    let (nv6, npe6, npv6, nlv6) = bfs_vertex_deg2(vis[6:7], pe_vec[24:28], pv_vec[24:28], lv_vec[18:21], cur_lvl, full_edge[11:12] & vis[4:5], u4:11, u4:4, full_edge[12:13] & vis[5:6], u4:12, u4:5);
    let (nv7, npe7, npv7, nlv7) = bfs_vertex_deg2(vis[7:8], pe_vec[28:32], pv_vec[28:32], lv_vec[21:24], cur_lvl, full_edge[13:14] & vis[5:6], u4:13, u4:5, full_edge[14:15] & vis[11:12], u4:14, u4:11);
    let (nv8, npe8, npv8, nlv8) = bfs_vertex_deg2(vis[8:9], pe_vec[32:36], pv_vec[32:36], lv_vec[24:27], cur_lvl, full_edge[0:1] & vis[0:1], u4:0, u4:0, full_edge[5:6] & vis[4:5], u4:5, u4:4);
    let (nv9, npe9, npv9, nlv9) = bfs_vertex_deg2(vis[9:10], pe_vec[36:40], pv_vec[36:40], lv_vec[27:30], cur_lvl, full_edge[10:11] & vis[4:5], u4:10, u4:4, u1:0, u4:0, u4:9);
    let (nv10, npe10, npv10, nlv10) = bfs_vertex_deg2(vis[10:11], pe_vec[40:44], pv_vec[40:44], lv_vec[30:33], cur_lvl, full_edge[4:5] & vis[3:4], u4:4, u4:3, u1:0, u4:0, u4:10);
    let (nv11, npe11, npv11, nlv11) = bfs_vertex_deg2(vis[11:12], pe_vec[44:48], pv_vec[44:48], lv_vec[33:36], cur_lvl, full_edge[9:10] & vis[3:4], u4:9, u4:3, full_edge[14:15] & vis[7:8], u4:14, u4:7);

    let vis_next: u12 = nv11 ++ nv10 ++ nv9 ++ nv8 ++ nv7 ++ nv6 ++ nv5 ++ nv4 ++ nv3 ++ nv2 ++ nv1 ++ nv0;
    let pe_next: u48 = npe11 ++ npe10 ++ npe9 ++ npe8 ++ npe7 ++ npe6 ++ npe5 ++ npe4 ++ npe3 ++ npe2 ++ npe1 ++ npe0;
    let pv_next: u48 = npv11 ++ npv10 ++ npv9 ++ npv8 ++ npv7 ++ npv6 ++ npv5 ++ npv4 ++ npv3 ++ npv2 ++ npv1 ++ npv0;
    let lv_next: u36 = nlv11 ++ nlv10 ++ nlv9 ++ nlv8 ++ nlv7 ++ nlv6 ++ nlv5 ++ nlv4 ++ nlv3 ++ nlv2 ++ nlv1 ++ nlv0;
    (vis_next, pe_next, pv_next, lv_next)
}

pub fn lakefillq_peel_level_step12(
    rem_syn: u12,
    corr: u25,
    pe_vec: u48,
    pv_vec: u48,
    lv_vec: u36,
    cur_lvl: u3
) -> (u12, u25) {
    let pa0: u1 = (if lv_vec[0:3] == cur_lvl { u1:1 } else { u1:0 }) & rem_syn[0:1];
    let pa1: u1 = (if lv_vec[3:6] == cur_lvl { u1:1 } else { u1:0 }) & rem_syn[1:2];
    let pa2: u1 = (if lv_vec[6:9] == cur_lvl { u1:1 } else { u1:0 }) & rem_syn[2:3];
    let pa3: u1 = (if lv_vec[9:12] == cur_lvl { u1:1 } else { u1:0 }) & rem_syn[3:4];
    let pa4: u1 = (if lv_vec[12:15] == cur_lvl { u1:1 } else { u1:0 }) & rem_syn[4:5];
    let pa5: u1 = (if lv_vec[15:18] == cur_lvl { u1:1 } else { u1:0 }) & rem_syn[5:6];
    let pa6: u1 = (if lv_vec[18:21] == cur_lvl { u1:1 } else { u1:0 }) & rem_syn[6:7];
    let pa7: u1 = (if lv_vec[21:24] == cur_lvl { u1:1 } else { u1:0 }) & rem_syn[7:8];
    let pa8: u1 = (if lv_vec[24:27] == cur_lvl { u1:1 } else { u1:0 }) & rem_syn[8:9];
    let pa9: u1 = (if lv_vec[27:30] == cur_lvl { u1:1 } else { u1:0 }) & rem_syn[9:10];
    let pa10: u1 = (if lv_vec[30:33] == cur_lvl { u1:1 } else { u1:0 }) & rem_syn[10:11];
    let pa11: u1 = (if lv_vec[33:36] == cur_lvl { u1:1 } else { u1:0 }) & rem_syn[11:12];

    let ef0: u1 = (pa0 & (if pe_vec[0:4] == u4:0 { u1:1 } else { u1:0 })) | (pa8 & (if pe_vec[32:36] == u4:0 { u1:1 } else { u1:0 }));
    let ef1: u1 = (pa0 & (if pe_vec[0:4] == u4:1 { u1:1 } else { u1:0 })) | (pa2 & (if pe_vec[8:12] == u4:1 { u1:1 } else { u1:0 }));
    let ef2: u1 = (pa1 & (if pe_vec[4:8] == u4:2 { u1:1 } else { u1:0 })) | (pa2 & (if pe_vec[8:12] == u4:2 { u1:1 } else { u1:0 }));
    let ef3: u1 = (pa1 & (if pe_vec[4:8] == u4:3 { u1:1 } else { u1:0 })) | (pa3 & (if pe_vec[12:16] == u4:3 { u1:1 } else { u1:0 }));
    let ef4: u1 = (pa3 & (if pe_vec[12:16] == u4:4 { u1:1 } else { u1:0 })) | (pa10 & (if pe_vec[40:44] == u4:4 { u1:1 } else { u1:0 }));
    let ef5: u1 = (pa4 & (if pe_vec[16:20] == u4:5 { u1:1 } else { u1:0 })) | (pa8 & (if pe_vec[32:36] == u4:5 { u1:1 } else { u1:0 }));
    let ef6: u1 = (pa2 & (if pe_vec[8:12] == u4:6 { u1:1 } else { u1:0 })) | (pa4 & (if pe_vec[16:20] == u4:6 { u1:1 } else { u1:0 }));
    let ef7: u1 = (pa2 & (if pe_vec[8:12] == u4:7 { u1:1 } else { u1:0 })) | (pa5 & (if pe_vec[20:24] == u4:7 { u1:1 } else { u1:0 }));
    let ef8: u1 = (pa3 & (if pe_vec[12:16] == u4:8 { u1:1 } else { u1:0 })) | (pa5 & (if pe_vec[20:24] == u4:8 { u1:1 } else { u1:0 }));
    let ef9: u1 = (pa3 & (if pe_vec[12:16] == u4:9 { u1:1 } else { u1:0 })) | (pa11 & (if pe_vec[44:48] == u4:9 { u1:1 } else { u1:0 }));
    let ef10: u1 = (pa4 & (if pe_vec[16:20] == u4:10 { u1:1 } else { u1:0 })) | (pa9 & (if pe_vec[36:40] == u4:10 { u1:1 } else { u1:0 }));
    let ef11: u1 = (pa4 & (if pe_vec[16:20] == u4:11 { u1:1 } else { u1:0 })) | (pa6 & (if pe_vec[24:28] == u4:11 { u1:1 } else { u1:0 }));
    let ef12: u1 = (pa5 & (if pe_vec[20:24] == u4:12 { u1:1 } else { u1:0 })) | (pa6 & (if pe_vec[24:28] == u4:12 { u1:1 } else { u1:0 }));
    let ef13: u1 = (pa5 & (if pe_vec[20:24] == u4:13 { u1:1 } else { u1:0 })) | (pa7 & (if pe_vec[28:32] == u4:13 { u1:1 } else { u1:0 }));
    let ef14: u1 = (pa7 & (if pe_vec[28:32] == u4:14 { u1:1 } else { u1:0 })) | (pa11 & (if pe_vec[44:48] == u4:14 { u1:1 } else { u1:0 }));

    // Degree <= 4 local parent syndrome parity propagation
    let ns0: u1 = rem_syn[0:1] ^ pa0 ^ (pa8 & (if pv_vec[32:36] == u4:0 { u1:1 } else { u1:0 })) ^ (pa2 & (if pv_vec[8:12] == u4:0 { u1:1 } else { u1:0 }));
    let ns1: u1 = rem_syn[1:2] ^ pa1 ^ (pa2 & (if pv_vec[8:12] == u4:1 { u1:1 } else { u1:0 })) ^ (pa3 & (if pv_vec[12:16] == u4:1 { u1:1 } else { u1:0 }));
    let ns2: u1 = rem_syn[2:3] ^ pa2 ^ (pa0 & (if pv_vec[0:4] == u4:2 { u1:1 } else { u1:0 })) ^ (pa1 & (if pv_vec[4:8] == u4:2 { u1:1 } else { u1:0 })) ^ (pa4 & (if pv_vec[16:20] == u4:2 { u1:1 } else { u1:0 })) ^ (pa5 & (if pv_vec[20:24] == u4:2 { u1:1 } else { u1:0 }));
    let ns3: u1 = rem_syn[3:4] ^ pa3 ^ (pa1 & (if pv_vec[4:8] == u4:3 { u1:1 } else { u1:0 })) ^ (pa10 & (if pv_vec[40:44] == u4:3 { u1:1 } else { u1:0 })) ^ (pa5 & (if pv_vec[20:24] == u4:3 { u1:1 } else { u1:0 })) ^ (pa11 & (if pv_vec[44:48] == u4:3 { u1:1 } else { u1:0 }));
    let ns4: u1 = rem_syn[4:5] ^ pa4 ^ (pa8 & (if pv_vec[32:36] == u4:4 { u1:1 } else { u1:0 })) ^ (pa2 & (if pv_vec[8:12] == u4:4 { u1:1 } else { u1:0 })) ^ (pa9 & (if pv_vec[36:40] == u4:4 { u1:1 } else { u1:0 })) ^ (pa6 & (if pv_vec[24:28] == u4:4 { u1:1 } else { u1:0 }));
    let ns5: u1 = rem_syn[5:6] ^ pa5 ^ (pa2 & (if pv_vec[8:12] == u4:5 { u1:1 } else { u1:0 })) ^ (pa3 & (if pv_vec[12:16] == u4:5 { u1:1 } else { u1:0 })) ^ (pa6 & (if pv_vec[24:28] == u4:5 { u1:1 } else { u1:0 })) ^ (pa7 & (if pv_vec[28:32] == u4:5 { u1:1 } else { u1:0 }));
    let ns6: u1 = rem_syn[6:7] ^ pa6 ^ (pa4 & (if pv_vec[16:20] == u4:6 { u1:1 } else { u1:0 })) ^ (pa5 & (if pv_vec[20:24] == u4:6 { u1:1 } else { u1:0 }));
    let ns7: u1 = rem_syn[7:8] ^ pa7 ^ (pa5 & (if pv_vec[20:24] == u4:7 { u1:1 } else { u1:0 })) ^ (pa11 & (if pv_vec[44:48] == u4:7 { u1:1 } else { u1:0 }));
    let ns8: u1 = rem_syn[8:9] ^ pa8 ^ (pa0 & (if pv_vec[0:4] == u4:8 { u1:1 } else { u1:0 })) ^ (pa4 & (if pv_vec[16:20] == u4:8 { u1:1 } else { u1:0 }));
    let ns9: u1 = rem_syn[9:10] ^ pa9 ^ (pa4 & (if pv_vec[16:20] == u4:9 { u1:1 } else { u1:0 }));
    let ns10: u1 = rem_syn[10:11] ^ pa10 ^ (pa3 & (if pv_vec[12:16] == u4:10 { u1:1 } else { u1:0 }));
    let ns11: u1 = rem_syn[11:12] ^ pa11 ^ (pa3 & (if pv_vec[12:16] == u4:11 { u1:1 } else { u1:0 })) ^ (pa7 & (if pv_vec[28:32] == u4:11 { u1:1 } else { u1:0 }));

    let rem_syn_next: u12 = ns11 ++ ns10 ++ ns9 ++ ns8 ++ ns7 ++ ns6 ++ ns5 ++ ns4 ++ ns3 ++ ns2 ++ ns1 ++ ns0;
    let corr_mid15: u15 =
        (corr[19:20] ^ ef14) ++ (corr[18:19] ^ ef13) ++ (corr[17:18] ^ ef12) ++
        (corr[16:17] ^ ef11) ++ (corr[15:16] ^ ef10) ++ (corr[14:15] ^ ef9) ++
        (corr[13:14] ^ ef8) ++ (corr[12:13] ^ ef7) ++ (corr[11:12] ^ ef6) ++
        (corr[10:11] ^ ef5) ++ (corr[9:10] ^ ef4) ++ (corr[8:9] ^ ef3) ++
        (corr[7:8] ^ ef2) ++ (corr[6:7] ^ ef1) ++ (corr[5:6] ^ ef0);
    let corr_next: u25 = corr[20:25] ++ corr_mid15 ++ corr[0:5];
    (rem_syn_next, corr_next)
}

pub fn lakefillq_peel_boundary_egress12(rem_syn: u12, corr: u25) -> (u12, u25, u1) {
    let q0: u1 = corr[0:1] ^ rem_syn[0:1];
    let q1: u1 = corr[1:2];
    let q2: u1 = corr[2:3] ^ rem_syn[1:2];
    let q3: u1 = corr[3:4];
    let q4: u1 = corr[4:5] ^ rem_syn[10:11];
    let q20: u1 = corr[20:21] ^ rem_syn[9:10];
    let q21: u1 = corr[21:22] ^ rem_syn[6:7];
    let q22: u1 = corr[22:23];
    let q23: u1 = corr[23:24] ^ rem_syn[7:8];
    let q24: u1 = corr[24:25];

    let corr_final: u25 =
        q24 ++ q23 ++ q22 ++ q21 ++ q20 ++ corr[5:20] ++ q4 ++ q3 ++ q2 ++ q1 ++ q0;
    let residual_syn: u12 =
        rem_syn[11:12] ++ u1:0 ++ u1:0 ++ rem_syn[8:9] ++ u1:0 ++ u1:0 ++
        rem_syn[5:6] ++ rem_syn[4:5] ++ rem_syn[3:4] ++ rem_syn[2:3] ++ u1:0 ++ u1:0;
    let logical_flip: u1 = (q0 ^ q1) ^ (q2 ^ q3) ^ q4;
    (residual_syn, corr_final, logical_flip)
}

// -----------------------------------------------------------------------------
// 4. Deterministic Unrolled 12-Check Lane & Dual-Basis Top Core (0-DSP)
// -----------------------------------------------------------------------------
pub fn lakefillq_decode_lane12_0dsp(syn12: u12) -> (u25, u12, u1) {
    let root_id: u48 =
        u4:11 ++ u4:10 ++ u4:9 ++ u4:8 ++ u4:7 ++ u4:6 ++
        u4:5 ++ u4:4 ++ u4:3 ++ u4:2 ++ u4:1 ++ u4:0;
    if syn12 == u12:0 {
        (u25:0, u12:0, u1:0)
    } else {
        // Growth round 0
        let (el0, bl0, fe0, _am0) = lakefillq_uf_half_edge_grow12(root_id, syn12, u12:0, u30:0, u12:0);
        let rt0a: u48 = lakefillq_sv_hook_step12(root_id, fe0);
        let rt0b: u48 = lakefillq_sv_hook_step12(rt0a, fe0);
        let rt0c: u48 = lakefillq_sv_hook_step12(rt0b, fe0);
        let (rt0, od0, bh0) = lakefillq_sv_pointer_jump_parity12(rt0c, syn12, bl0);

        // Growth round 1
        let (el1, bl1, fe1, _am1) = lakefillq_uf_half_edge_grow12(rt0, od0, bh0, el0, bl0);
        let rt1a: u48 = lakefillq_sv_hook_step12(rt0, fe1);
        let rt1b: u48 = lakefillq_sv_hook_step12(rt1a, fe1);
        let rt1c: u48 = lakefillq_sv_hook_step12(rt1b, fe1);
        let (rt1, od1, bh1) = lakefillq_sv_pointer_jump_parity12(rt1c, syn12, bl1);

        // Growth round 2
        let (el2, bl2, fe2, _am2) = lakefillq_uf_half_edge_grow12(rt1, od1, bh1, el1, bl1);
        let rt2a: u48 = lakefillq_sv_hook_step12(rt1, fe2);
        let rt2b: u48 = lakefillq_sv_hook_step12(rt2a, fe2);
        let rt2c: u48 = lakefillq_sv_hook_step12(rt2b, fe2);
        let (rt2, od2, bh2) = lakefillq_sv_pointer_jump_parity12(rt2c, syn12, bl2);

        // Growth round 3
        let (_el3, bl3, fe3, _am3) = lakefillq_uf_half_edge_grow12(rt2, od2, bh2, el2, bl2);
        let rt3a: u48 = lakefillq_sv_hook_step12(rt2, fe3);
        let rt3b: u48 = lakefillq_sv_hook_step12(rt3a, fe3);
        let rt3c: u48 = lakefillq_sv_hook_step12(rt3b, fe3);
        let (rt3, _od3, _bh3) = lakefillq_sv_pointer_jump_parity12(rt3c, syn12, bl3);

        // Spanning-forest orientation (seed + 7 deterministic levels)
        let vis0: u12 = lakefillq_bfs_seed_init12(rt3, bl3);
        let (vis1, pe1, pv1, lv1) = lakefillq_bfs_forest_step12(vis0, u48:0, root_id, u36:0, fe3, u3:1);
        let (vis2, pe2, pv2, lv2) = lakefillq_bfs_forest_step12(vis1, pe1, pv1, lv1, fe3, u3:2);
        let (vis3, pe3, pv3, lv3) = lakefillq_bfs_forest_step12(vis2, pe2, pv2, lv2, fe3, u3:3);
        let (vis4, pe4, pv4, lv4) = lakefillq_bfs_forest_step12(vis3, pe3, pv3, lv3, fe3, u3:4);
        let (vis5, pe5, pv5, lv5) = lakefillq_bfs_forest_step12(vis4, pe4, pv4, lv4, fe3, u3:5);
        let (vis6, pe6, pv6, lv6) = lakefillq_bfs_forest_step12(vis5, pe5, pv5, lv5, fe3, u3:6);
        let (_vis7, pe7, pv7, lv7) = lakefillq_bfs_forest_step12(vis6, pe6, pv6, lv6, fe3, u3:7);

        // Leaf-to-root peeling (levels 7 down to 1 + boundary egress)
        let (rs6, cr6) = lakefillq_peel_level_step12(syn12, u25:0, pe7, pv7, lv7, u3:7);
        let (rs5, cr5) = lakefillq_peel_level_step12(rs6, cr6, pe7, pv7, lv7, u3:6);
        let (rs4, cr4) = lakefillq_peel_level_step12(rs5, cr5, pe7, pv7, lv7, u3:5);
        let (rs3, cr3) = lakefillq_peel_level_step12(rs4, cr4, pe7, pv7, lv7, u3:4);
        let (rs2, cr2) = lakefillq_peel_level_step12(rs3, cr3, pe7, pv7, lv7, u3:3);
        let (rs1, cr1) = lakefillq_peel_level_step12(rs2, cr2, pe7, pv7, lv7, u3:2);
        let (rs0, cr0) = lakefillq_peel_level_step12(rs1, cr1, pe7, pv7, lv7, u3:1);
        let (res_syn, corr_final, log_flip) = lakefillq_peel_boundary_egress12(rs0, cr0);
        (corr_final, res_syn, log_flip)
    }
}

pub fn lakefillq_0dsp_braun_uf_decoder_top(
    cur_syn: u24,
    prev_syn: u24,
    prev_pauli_frame: u2,
    autdec_shift_sel: u2
) -> (u2, u25, u25, u5, u1, u6) {
    let (delta_syn, defect_weight, zero_defect_bypass) =
        lakefillq_ingress_xor_bypass24(cur_syn, prev_syn, autdec_shift_sel);
    if zero_defect_bypass == u1:1 {
        (prev_pauli_frame, u25:0, u25:0, defect_weight, u1:1, u6:1)
    } else {
        let (corr_z, _res_z, flip_z) = lakefillq_decode_lane12_0dsp(delta_syn[0:12]);
        let (corr_x, _res_x, flip_x) = lakefillq_decode_lane12_0dsp(delta_syn[12:24]);
        let pauli_frame_flip: u2 = prev_pauli_frame ^ (flip_x ++ flip_z);
        (pauli_frame_flip, corr_z, corr_x, defect_weight, u1:0, u6:37)
    }
}
